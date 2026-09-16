import AVFoundation
import Foundation
import CoreMedia
import CoreAudio

@main
enum ComputerAudioRecorderTests {
    static func main() throws {
        // Reproduce a Bluetooth system default while dictation prefers the
        // built-in mic. Record must pin that same mic in ScreenCaptureKit.
        let airPods = AudioInputDevice(id: 99, name: "AirPods", transport: .bluetooth)
        let builtIn = AudioInputDevice(id: 41, name: "Built-in microphone", transport: .builtIn)
        let usb = AudioInputDevice(id: 120, name: "USB microphone", transport: .other)
        let ids: [AudioDeviceID: String] = [99: "bluetooth-input", 41: "built-in-input", 120: "usb-input"]
        for (systemDefault, expected) in [(airPods, builtIn), (usb, usb), (builtIn, builtIn)] {
            let preferred = AudioInputPolicy.preferredDevice(defaultDevice: systemDefault,
                                                            availableDevices: [airPods, builtIn, usb])
            let configuration = ComputerAudioRecorder.captureConfiguration(microphoneID: ids[preferred.id]!)
            precondition(configuration.microphoneCaptureDeviceID == ids[expected.id],
                         "Record pins the same microphone as Caps Lock instead of using ScreenCaptureKit's default")
            precondition(configuration.capturesAudio && configuration.captureMicrophone,
                         "Pinning the microphone preserves both recording sources")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let mic = folder.appendingPathComponent("mic.caf")
        let computer = folder.appendingPathComponent("computer.caf")
        let output = folder.appendingPathComponent("mixed.caf")
        try write(mic, samples: Array(repeating: 0.25, count: 16000))
        try write(computer, samples: Array(repeating: 0, count: 8000) + Array(repeating: 0.9, count: 16000))
        try SessionAudioMixer.mix(urls: [mic, computer], output: output, duration: 2)
        let file = try AVAudioFile(forReading: output)
        let buffer = AVAudioPCMBuffer(pcmFormat: SessionAudioMixer.format, frameCapacity: 32000)!
        try file.read(into: buffer)
        precondition(file.length == 32000, "Output keeps recording duration including silence")
        let data = buffer.floatChannelData![0]
        precondition(abs(data[100] - 0.25) < 0.001, "Microphone remains at its original gain")
        precondition(data[9000] == 1, "Overlapping sources are mixed without clipping overflow")
        precondition(abs(data[20000] - 0.9) < 0.001, "Computer audio outlasts the microphone track")
        precondition(data[30000] == 0, "Missing trailing audio is padded with silence")
        try captureBuffers(in: folder)
        try finalCaptureBuffers(in: folder)
        print("ComputerAudioRecorderTests passed")
    }

    private static func finalCaptureBuffers(in folder: URL) throws {
        let url = folder.appendingPathComponent("last-word.caf")
        var track: CapturedAudioTrack? = try CapturedAudioTrack(url: url)
        var timeline = RecordingTimeline(startedAt: 100)
        _ = try track!.append(sample(at: 100, rate: 16000, channels: 1, frames: 3200, value: 0.2), timeline: timeline)
        timeline.pause(at: 100.35) // Stop requested before the last callback arrives.
        _ = try track!.append(sample(at: 100.2, rate: 16000, channels: 1, frames: 3200, value: 0.4), timeline: timeline)
        track = nil
        let file = try AVAudioFile(forReading: url)
        precondition(abs(file.length - 5600) <= 1, "Drain audio captured before Stop, while excluding samples after Stop")
        let buffer = AVAudioPCMBuffer(pcmFormat: SessionAudioMixer.format, frameCapacity: 5601)!
        try file.read(into: buffer)
        precondition(abs(buffer.floatChannelData![0][5500] - 0.4) < 0.001,
                     "The tail of a word survives a delayed final capture callback")
    }

    private static func captureBuffers(in folder: URL) throws {
        let url = folder.appendingPathComponent("capture.caf")
        var track: CapturedAudioTrack? = try CapturedAudioTrack(url: url)
        var timeline = RecordingTimeline(startedAt: 100)
        timeline.pause(at: 100.1)
        timeline.resume(at: 100.2)
        // 48 kHz stereo matches computer audio. A buffer straddles pause;
        // a delayed buffer from inside the pause must contribute no audio.
        _ = try track!.append(sample(at: 100, rate: 48000, channels: 2, frames: 9600, value: 0.2), timeline: timeline)
        _ = try track!.append(sample(at: 100.1, rate: 48000, channels: 2, frames: 4800, value: 0.8), timeline: timeline)
        _ = try track!.append(sample(at: 100.2, rate: 48000, channels: 2, frames: 4800, value: 0.2), timeline: timeline)
        // Native microphone route changes may also change sample format.
        _ = try track!.append(sample(at: 100.3, rate: 16000, channels: 1, frames: 1600, value: 0.3), timeline: timeline)
        track = nil
        let file = try AVAudioFile(forReading: url)
        precondition(abs(file.length - 4800) < 64, "Pause is removed and format changes preserve the shared timeline")
        let buffer = AVAudioPCMBuffer(pcmFormat: SessionAudioMixer.format, frameCapacity: 6000)!
        try file.read(into: buffer)
        let data = buffer.floatChannelData![0]
        precondition(abs(data[400] - 0.2) < 0.01, "Stereo audio is resampled to mono")
        precondition(abs(data[2100] - 0.2) < 0.01, "Late paused audio cannot leak into the resumed track")
        precondition(abs(data[3800] - 0.3) < 0.01, "Microphone format changes are converted correctly")
    }

    private static func sample(at time: Double, rate: Double, channels: AVAudioChannelCount,
                               frames: AVAudioFrameCount, value: Float) throws -> CMSampleBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        pcm.frameLength = frames
        for channel in 0..<Int(channels) {
            pcm.floatChannelData![channel].initialize(repeating: value, count: Int(frames))
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
                                       presentationTimeStamp: CMTime(seconds: time, preferredTimescale: Int32(rate)),
                                       decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        precondition(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: Int(frames), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result) == noErr)
        let sample = result!
        precondition(CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr)
        precondition(CMSampleBufferSetDataReady(sample) == noErr)
        return sample
    }

    private static func write(_ url: URL, samples: [Float]) throws {
        let file = try AVAudioFile(forWriting: url, settings: SessionAudioMixer.format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: SessionAudioMixer.format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }
}
