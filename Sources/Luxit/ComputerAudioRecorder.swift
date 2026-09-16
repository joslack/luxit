import AVFoundation
import CoreMedia
import ScreenCaptureKit

struct ComputerRecording {
    let duration: TimeInterval
}

private func recordingError(_ message: String) -> NSError {
    NSError(domain: "Luxit.Recording", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

/// Serial queue owns the timeline, converters and files. Only audio outputs are
/// registered with ScreenCaptureKit; no screen frames are received or saved.
final class ComputerAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "com.joslack.luxit.computer-audio", qos: .userInitiated)
    private var stream: SCStream?
    private var directory: URL?
    private var tracks: [SCStreamOutputType: CapturedAudioTrack] = [:]
    private var timeline: RecordingTimeline?
    private var levels: [SCStreamOutputType: Float] = [:]
    private var failure: Error?
    private var acceptingAudio = false
    private(set) var microphoneName: String?
    var onLevel: ((Float) -> Void)?
    var onAudio: ((SCStreamOutputType, UnsafePointer<Float>, Int, Double) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onChunksReady: (() -> Void)?
    var classifySpeech: ((SCStreamOutputType, UnsafePointer<Float>, Int) -> Bool)?
    private var session: RecordingSession?

    static func captureConfiguration(microphoneID: String) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.microphoneCaptureDeviceID = microphoneID
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        return configuration
    }

    func start(session: RecordingSession, completion: @escaping (Result<Void, Error>) -> Void) {
        Task { @MainActor in
            do {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw recordingError("Allow Microphone access in System Settings → Privacy & Security.")
                }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    throw recordingError("No display is available for computer audio capture.")
                }
                let microphone = try SystemAudioInput.preferredDevice()
                let configuration = Self.captureConfiguration(
                    microphoneID: try SystemAudioInput.captureDeviceID(for: microphone))
                microphoneName = microphone.name
                let capture = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                                       configuration: configuration, delegate: self)
                try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                try capture.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("luxit-recording-\(UUID())")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                directory = folder
                self.session = session
                try queue.sync {
                    tracks[.audio] = try CapturedAudioTrack(url: folder.appendingPathComponent("computer.caf"), storesAudio: false)
                    tracks[.microphone] = try CapturedAudioTrack(url: folder.appendingPathComponent("microphone.caf"), storesAudio: false)
                    for (type, track) in tracks {
                        track.onAudio = { [weak self, session] samples, count, start in
                            guard let self else { return }
                            self.onAudio?(type, samples, count, 16_000)
                            let speech = self.classifySpeech?(type, samples, count) ?? true
                            if try session.append(source: type == .microphone ? .microphone : .computer,
                                                  samples: samples, count: count, start: start, speech: speech) {
                                DispatchQueue.main.async { [weak self] in self?.onChunksReady?() }
                            }
                        }
                    }
                    failure = nil
                    levels.removeAll()
                    timeline = RecordingTimeline(startedAt: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
                    acceptingAudio = true
                }
                stream = capture
                try await capture.startCapture()
                if let error = queue.sync(execute: { failure }) { throw error }
                completion(.success(()))
            } catch {
                if let capture = self.stream { try? await capture.stopCapture() }
                self.stream = nil
                cleanup()
                completion(.failure(error))
            }
        }
    }

    func setPaused(_ paused: Bool) {
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        queue.sync {
            if paused {
                timeline?.pause(at: now)
                do { try session?.flush() }
                catch { failure = error; DispatchQueue.main.async { [weak self] in self?.onFailure?(error) } }
                DispatchQueue.main.async { [weak self] in self?.onChunksReady?() }
            } else { timeline?.resume(at: now) }
        }
    }

    var duration: TimeInterval {
        queue.sync { timeline?.duration(at: CMClockGetTime(CMClockGetHostTimeClock()).seconds) ?? 0 }
    }

    func stop(completion: @escaping (Result<ComputerRecording, Error>) -> Void) {
        guard let capture = stream else {
            completion(.failure(recordingError("No recording is active.")))
            return
        }
        stream = nil
        let seconds = duration
        queue.sync { acceptingAudio = false }
        capture.stopCapture { [self] stopError in
            queue.async { [self] in
                let result: Result<ComputerRecording, Error>
                do {
                    // Seal durable chunks even if capture was interrupted.
                    try session?.finish(duration: seconds)
                    tracks.removeAll()
                    if let directory { try? FileManager.default.removeItem(at: directory) }
                    self.directory = nil
                    if let failure { throw failure }
                    if let stopError { throw stopError }
                    result = .success(ComputerRecording(duration: seconds))
                } catch {
                    tracks.removeAll()
                    if let directory { try? FileManager.default.removeItem(at: directory) }
                    self.directory = nil
                    result = .failure(error)
                }
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    private func cleanup() {
        queue.sync {
            acceptingAudio = false
            tracks.removeAll()
            timeline = nil
            if let directory { try? FileManager.default.removeItem(at: directory) }
            directory = nil
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard acceptingAudio, failure == nil, let timeline, let track = tracks[type],
              sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        do {
            let level = try track.append(sampleBuffer, timeline: timeline)
            levels[type] = level
            onLevel?(levels.values.max() ?? 0)
        } catch {
            failure = error
            DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self, acceptingAudio else { return }
            failure = error
            DispatchQueue.main.async { self.onFailure?(error) }
        }
    }
}

final class CapturedAudioTrack {
    let url: URL
    var onAudio: ((UnsafePointer<Float>, Int, TimeInterval) throws -> Void)?
    private let file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var writtenFrames: AVAudioFramePosition = 0
    private let format = SessionAudioMixer.format

    init(url: URL, storesAudio: Bool = true) throws {
        self.url = url
        file = storesAudio ? try AVAudioFile(forWriting: url, settings: format.settings) : nil
    }

    func append(_ sample: CMSampleBuffer, timeline: RecordingTimeline) throws -> Float {
        guard let description = sample.formatDescription,
              let inputFormat = AVAudioFormat(cmAudioFormatDescription: description) as AVAudioFormat?,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(sample.numSamples))
        else { throw recordingError("Unsupported captured audio format.") }
        input.frameLength = input.frameCapacity
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(sample.numSamples),
                                                         into: input.mutableAudioBufferList) == noErr else {
            throw recordingError("Could not read captured audio.")
        }
        if converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: format)
        }
        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / inputFormat.sampleRate)) + 64)
        else { throw recordingError("Could not convert captured audio.") }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard status != .error, let samples = output.floatChannelData?[0] else {
            throw recordingError("Audio conversion failed.")
        }
        let timestamp = sample.presentationTimeStamp.seconds
        guard timestamp.isFinite else { return 0 }
        var sum: Float = 0
        // Split only at pause boundaries. Using each sample's timestamp also
        // drops delayed callbacks belonging to a paused interval.
        var index = 0
        while index < Int(output.frameLength) {
            guard let position = timeline.position(at: timestamp + Double(index) / format.sampleRate) else {
                index += 1
                continue
            }
            let start = index
            var end = index + 1
            while end < Int(output.frameLength),
                  timeline.position(at: timestamp + Double(end) / format.sampleRate) != nil { end += 1 }
            let destination = AVAudioFramePosition((position * format.sampleRate).rounded())
            try pad(to: destination)
            let skip = Int(max(0, writtenFrames - destination))
            let count = end - start - skip
            if count > 0, let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) {
                chunk.frameLength = chunk.frameCapacity
                chunk.floatChannelData![0].update(from: samples + start + skip, count: count)
                try file?.write(from: chunk)
                try onAudio?(chunk.floatChannelData![0], count, Double(writtenFrames) / format.sampleRate)
                writtenFrames += Int64(count)
                for frame in start + skip..<end { sum += samples[frame] * samples[frame] }
            }
            index = end
        }
        return sqrt(sum / Float(max(1, output.frameLength)))
    }

    private func pad(to frame: AVAudioFramePosition) throws {
        guard frame > writtenFrames else { return }
        guard let file else { writtenFrames = frame; return }
        let zeros = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        zeros.floatChannelData![0].initialize(repeating: 0, count: 4096)
        while writtenFrames < frame {
            zeros.frameLength = AVAudioFrameCount(min(4096, frame - writtenFrames))
            try file.write(from: zeros)
            writtenFrames += Int64(zeros.frameLength)
        }
    }
}

enum SessionAudioMixer {
    static let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    /// Mix bounded blocks, preserving alignment and silence in either track.
    static func mix(urls: [URL], output: URL, duration: TimeInterval) throws {
        let inputs = try urls.map { try AVAudioFile(forReading: $0) }
        let destination = try AVAudioFile(forWriting: output, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        let total = AVAudioFramePosition(max(0, duration) * format.sampleRate)
        var position: AVAudioFramePosition = 0
        while position < total {
            let count = AVAudioFrameCount(min(4096, total - position))
            buffer.frameLength = count
            let samples = buffer.floatChannelData![0]
            samples.initialize(repeating: 0, count: Int(count))
            for input in inputs where input.framePosition < input.length {
                try input.read(into: scratch, frameCount: count)
                for index in 0..<Int(scratch.frameLength) {
                    samples[index] += scratch.floatChannelData![0][index]
                }
            }
            for index in 0..<Int(count) { samples[index] = max(-1, min(1, samples[index])) }
            try destination.write(from: buffer)
            position += Int64(count)
        }
    }
}
