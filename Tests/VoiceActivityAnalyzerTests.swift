import AVFoundation
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main
private enum VoiceActivityAnalyzerTests {
    static func main() throws {
        let analyzer = VoiceActivityAnalyzer(modelURL: URL(fileURLWithPath: "/no-luxit-test-model"))
        let delivered = DispatchSemaphore(value: 0)
        var interleavedLevel: Float = -1
        analyzer.start { level, _, _ in interleavedLevel = level; delivered.signal() }
        let interleaved = (0..<(1024 * 3)).map { Float($0 % 3 == 2 ? 0.02 : 0.5) }
        interleaved.withUnsafeBufferPointer {
            analyzer.submit(samples: $0.baseAddress! + 2, count: 1024, sampleRate: 16_000, stride: 3)
        }
        expect(delivered.wait(timeout: .now() + 5) == .success, "interleaved microphone audio reaches visualization")
        analyzer.stop()
        expect(abs(interleavedLevel - 0.02) < 0.0001, "visualization analyzes only the selected channel in interleaved input")

        let absent = VoiceActivityProcessor(modelURL: URL(fileURLWithPath: "/no-luxit-test-model"))
        let fallback = absent.process(samples: [Float](repeating: 0, count: 1024), sampleRate: 16_000)
        expect(!fallback.isEmpty && fallback.allSatisfy { $0.voiceProbability == nil },
               "an absent optional model leaves visualization's spectral fallback available")
        expect(absent.process(samples: [], sampleRate: 16_000).isEmpty, "empty buffers are harmless")

        let url = VoiceActivityAnalyzer.modelURL
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        guard FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: fixture.path) else {
            print("VoiceActivityAnalyzerTests: optional local model/packaged JFK fixture unavailable; real-audio checks skipped")
            return
        }
        let file = try AVAudioFile(forReading: fixture)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        expect(buffer.format.sampleRate == 16_000, "the packaged reference has the expected sample rate")
        let speech = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let rms = sqrt(speech.reduce(Float.zero) { $0 + $1 * $1 } / Float(speech.count))
        let quietSpeech = speech.map { $0 * 0.012 / rms }
        var seed: UInt64 = 8129
        var lowpass: Float = 0
        let noise: [Float] = (0..<speech.count).map { i in
            seed = seed &* 6364136223846793005 &+ 1
            let white = Float((seed >> 32) & 0xffff) / 32768 - 1
            lowpass += (white - lowpass) * 0.12
            return lowpass * 0.045 + 0.010 * sin(Float(i) * 2 * .pi * 80 / 16_000)
        }
        let mixed = zip(quietSpeech, noise).map(+)
        let processor = VoiceActivityProcessor(modelURL: url)
        processor.prepare()
        func analyze(_ samples: [Float]) -> [VoiceActivityProcessor.Frame] {
            var frames: [VoiceActivityProcessor.Frame] = []
            for offset in stride(from: 0, to: samples.count, by: 1600) {
                frames += processor.process(samples: Array(samples[offset..<min(samples.count, offset + 1600)]), sampleRate: 16_000)
            }
            return frames
        }
        func fraction(_ frames: [VoiceActivityProcessor.Frame]) -> Float {
            Float(frames.filter { ($0.voiceProbability ?? 0) > 0.5 }.count) / Float(max(1, frames.count))
        }
        let noiseFrames = analyze(noise)
        let noisySpeechFrames = analyze(mixed)
        processor.reset()
        let cleanFrames = analyze(quietSpeech)
        let noiseFraction = fraction(noiseFrames)
        let noisySpeechFraction = fraction(noisySpeechFrames)
        let cleanFraction = fraction(cleanFrames)
        print(String(format: "Voice activity: fan %.1f%%, quiet speech %.1f%%, speech + fan %.1f%% accepted", noiseFraction * 100, cleanFraction * 100, noisySpeechFraction * 100))
        expect(noiseFraction < 0.05, "fan/rumble should rarely be classified as speech")
        expect(cleanFraction > 0.60, "quiet continuous speech remains visibly active")
        expect(noisySpeechFraction > 0.50, "speech remains active over the tested fan background")
        processor.reset()
        let repeated = analyze(quietSpeech)
        expect(zip(cleanFrames, repeated).allSatisfy { abs(($0.voiceProbability ?? 0) - ($1.voiceProbability ?? 0)) < 0.0001 },
               "a new recording resets recurrent voice state")
        processor.reset()
        let veryQuiet = analyze(speech.map { $0 * 0.0008 / rms })
        let veryQuietFraction = fraction(veryQuiet)
        print(String(format: "Very quiet speech: %.1f%% accepted", veryQuietFraction * 100))
        expect(veryQuietFraction > 0.45, "very quiet speech still reaches the animation's speech-presence response")
        processor.reset()
        let silence = processor.process(samples: [Float](repeating: 0, count: 4096), sampleRate: 48_000)
        expect(silence.count >= 2 && silence.allSatisfy { $0.level == 0 },
               "a device format change resamples and resets safely")
        print("VoiceActivityAnalyzerTests passed")
    }
}
