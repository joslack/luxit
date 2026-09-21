import AVFoundation
import Foundation

/// A separate, CPU-only speech-analysis branch. Its level conditioning never
/// changes the audio saved for transcription. The existing local Silero
/// model is optional; there is no download or network fallback.
final class VoiceActivityAnalyzer {
    typealias Handler = (Float, [Float], Float?) -> Void
    static let modelURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/EdgeWhisper/Models/ggml-silero-v6.2.0.bin")
    private let queue = DispatchQueue(label: "com.joslack.luxit.voice-animation", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: (samples: [Float], rate: Double, generation: Int)?
    private var running = false
    private var generation = 0
    private var handler: Handler?
    private var processedGeneration = -1
    private let processor: VoiceActivityProcessor

    init(modelURL: URL = VoiceActivityAnalyzer.modelURL) {
        processor = VoiceActivityProcessor(modelURL: modelURL)
        queue.async { [processor] in processor.prepare() }
    }

    func start(handler: @escaping Handler) {
        lock.lock()
        generation += 1
        pending = nil
        self.handler = handler
        lock.unlock()
    }

    func stop() {
        lock.lock()
        generation += 1
        pending = nil
        handler = nil
        lock.unlock()
    }

    func reset() {
        lock.lock()
        generation += 1
        pending = nil
        lock.unlock()
    }

    func submit(samples: UnsafePointer<Float>, count: Int, sampleRate: Double, stride: Int = 1) {
        guard count > 0, stride > 0, sampleRate.isFinite, sampleRate >= 8_000 else { return }
        // Bound both retained audio and queued work, even if an input device
        // delivers a very large callback or the computer stalls temporarily.
        let kept = min(count, Int(sampleRate / 4))
        let copy: [Float]
        if stride == 1 {
            copy = Array(UnsafeBufferPointer(start: samples + count - kept, count: kept))
        } else {
            copy = (count - kept..<count).map { samples[$0 * stride] }
        }
        lock.lock()
        guard handler != nil else { lock.unlock(); return }
        pending = (copy, sampleRate, generation)
        let schedule = !running
        running = true
        lock.unlock()
        if schedule { queue.async { [self] in drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let input = pending else {
                running = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            if processedGeneration != input.generation {
                processor.reset()
                processedGeneration = input.generation
            }
            let frames = processor.process(samples: input.samples, sampleRate: input.rate)
            let loudestSpeech = frames.max {
                $0.level * ($0.voiceProbability ?? 1) < $1.level * ($1.voiceProbability ?? 1)
            }
            lock.lock()
            // Serialize delivery with stop/start so a previous recording can
            // never inject a late level into the next listening cloud.
            if input.generation == generation, let handler, let frame = loudestSpeech {
                handler(frame.level, frame.spectrum, frame.voiceProbability)
            }
            lock.unlock()
        }
    }
}

/// Serial-queue owned, and also exercised directly with local audio fixtures.
final class VoiceActivityProcessor {
    struct Frame {
        let level: Float
        let spectrum: [Float]
        let voiceProbability: Float?
    }
    private let modelURL: URL
    private var context: UnsafeMutableRawPointer?
    private var prepared = false
    private var converter: AVAudioConverter?
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private let spectrum = LogSpectrumAnalyzer(fftSize: 512)
    private var buffered: [Float] = []
    private var detectorPeak: Float = 0

    init(modelURL: URL) { self.modelURL = modelURL }
    deinit { luxit_voice_activity_free(context) }

    func prepare() {
        guard !prepared else { return }
        prepared = true
        if FileManager.default.fileExists(atPath: modelURL.path) {
            context = luxit_voice_activity_create(modelURL.path)
        }
    }

    func reset() {
        luxit_voice_activity_reset(context)
        buffered.removeAll(keepingCapacity: true)
        detectorPeak = 0
        converter = nil
    }

    func process(samples: [Float], sampleRate: Double) -> [Frame] {
        guard !samples.isEmpty, sampleRate.isFinite, sampleRate >= 8_000 else { return [] }
        prepare()
        guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return [] }
        input.frameLength = input.frameCapacity
        input.floatChannelData![0].update(from: samples, count: samples.count)
        if converter?.inputFormat != inputFormat {
            reset()
            converter = AVAudioConverter(from: inputFormat, to: format)
        }
        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(samples.count) * 16_000 / sampleRate)) + 64) else { return [] }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        guard error == nil, status != .error, let data = output.floatChannelData?[0] else { return [] }
        buffered.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
        var frames: [Frame] = []
        var offset = 0
        while offset + 512 <= buffered.count {
            let frame: Frame = buffered.withUnsafeBufferPointer { buffer in
                let samples = buffer.baseAddress! + offset
                var energy: Float = 0
                for i in 0..<512 { energy += samples[i] * samples[i] }
                let rms = sqrt(energy / 512)
                // The detector expects an audible speech signal. Normalize its
                // private analysis copy, with a strict gain cap, so quiet voices
                // are not rejected merely for being quiet. Return original RMS
                // and spectrum; capture buffers are never changed.
                // Hold recent speech peaks so gain doesn't pump up and down
                // between consonants or amplify every gap between syllables.
                detectorPeak = max(rms, detectorPeak * 0.98)
                let gain = min(Float(32), max(1, 0.012 / max(0.0001, detectorPeak)))
                let analysis = (0..<512).map { max(-1, min(1, samples[$0] * gain)) }
                let probability = analysis.withUnsafeBufferPointer {
                    luxit_voice_activity_probability(context, $0.baseAddress!, 512)
                }
                return Frame(level: rms,
                             spectrum: spectrum?.process(samples: samples, frameCount: 512, sampleRate: 16_000) ?? [],
                             voiceProbability: probability.isFinite && probability >= 0 ? min(1, probability) : nil)
            }
            frames.append(frame)
            offset += 512
        }
        buffered.removeFirst(offset)
        return frames
    }
}
