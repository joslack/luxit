import AVFoundation
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main
private enum DictationAudioTests {
    static func buffer(channels: Int, active: Int, interleaved: Bool = false,
                       amplitude: Float = 0.1, frames: Int = 24_000) -> AVAudioPCMBuffer {
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   interleaved: interleaved, channelLayout: layout)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<channels {
            for frame in 0..<frames {
                buffer.floatChannelData![channel][frame * buffer.stride] = channel == active
                    ? amplitude * sin(Float(frame) * 2 * .pi * 440 / 48_000) : 0
            }
        }
        return buffer
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("luxit-channel-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Exercise the actual CAF -> afconvert -> PCM16 backend boundary. The
        // previous implicit conversion produced silence for discrete layouts.
        for count in 1...3 {
            for active in 0..<count {
                let input = buffer(channels: count, active: active)
                var metrics = DictationAudioMetrics()
                expect(metrics.append(input) == active, "visualization must find signal beyond channel zero")
                expect(metrics.selectedChannel == active, "transcription selects the channel containing signal")
                expect(abs(metrics.peakLevel - 0.07071) < 0.0001, "levels come from the selected channel")
                expect(abs(metrics.voicedSeconds - 0.5) < 0.0001, "speech on any input channel survives the silence gate")

                let caf = root.appendingPathComponent("\(count)-\(active).caf")
                let wav = root.appendingPathComponent("\(count)-\(active).wav")
                do {
                    let file = try AVAudioFile(forWriting: caf, settings: input.format.settings)
                    try file.write(from: input)
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
                process.arguments = DictationAudioConversion.arguments(input: caf, output: wav,
                                                                       channel: metrics.selectedChannel!)
                try process.run()
                process.waitUntilExit()
                expect(process.terminationStatus == 0, "conversion must accept discrete microphone layouts")
                let file = try AVAudioFile(forReading: wav)
                expect(file.processingFormat.sampleRate == 16_000 && file.processingFormat.channelCount == 1,
                       "backend input is 16 kHz mono")
                expect(abs(Double(file.length) - 8_000) <= 1, "resampling retains the entire utterance")
                let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
                try file.read(into: output)
                var converted = DictationAudioMetrics()
                _ = converted.append(output)
                expect(abs(converted.peakLevel - metrics.peakLevel) < 0.0001,
                       "conversion preserves signal strength, including channels one and two")

                var interleaved = DictationAudioMetrics()
                expect(interleaved.append(buffer(channels: count, active: active, interleaved: true)) == active,
                       "interleaved buffers use their stride rather than adjacent channel samples")
                expect(abs(interleaved.peakLevel - metrics.peakLevel) < 0.00001, "interleaving cannot change measured levels")
            }
        }

        var silence = DictationAudioMetrics()
        expect(silence.selectedChannel == nil && silence.peakLevel == 0, "no callbacks cannot invent speech")
        _ = silence.append(buffer(channels: 3, active: 2, amplitude: 0))
        expect(silence.peakLevel == 0 && silence.voicedSeconds == 0, "silent channels remain silent")
        expect(silence.selectedChannel == 0, "ties use a stable channel")
        let empty = buffer(channels: 3, active: 2, frames: 1)
        empty.frameLength = 0
        expect(silence.append(empty) == nil, "empty callbacks do not update metrics")

        var utterance = DictationAudioMetrics()
        for _ in 0..<10 { _ = utterance.append(buffer(channels: 3, active: 2, amplitude: 0.03)) }
        _ = utterance.append(buffer(channels: 3, active: 0, amplitude: 0.08))
        expect(utterance.selectedChannel == 2, "a brief click cannot replace the channel carrying sustained speech")
        expect(abs(utterance.voicedSeconds - 5) < 0.0001, "statistics match the channel sent to transcription")
        expect(utterance.append(buffer(channels: 2, active: 0)) == nil, "a changed layout cannot corrupt an existing file's metrics")
        let quiet = RecordedAudio(url: root, duration: 2, channel: 0, peakLevel: 0.001, voicedSeconds: 0)
        expect(!quiet.isEmptyOrTooShort, "quiet speech must reach the backend's speech detector")
        expect(RecordedAudio(url: root, duration: 2, channel: 0, peakLevel: 0, voicedSeconds: 0).isEmptyOrTooShort,
               "a disconnected or silent microphone does not enqueue empty audio")
        expect(RecordedAudio(url: root, duration: 0.1, channel: 0, peakLevel: 0.1, voicedSeconds: 0.1).isEmptyOrTooShort,
               "accidental very short presses remain ignored")
        print("Dictation audio channel and conversion tests passed")
    }
}
