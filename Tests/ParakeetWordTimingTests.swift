import AVFoundation
import Foundation

@main enum ParakeetWordTimingTests {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4 else { fatalError("Expected local model, runtime, and public WAV fixture") }
        guard let context = ew_parakeet_load(args[1], args[2], 0, -1) else { fatalError(String(cString: ew_whisper_last_error())) }
        defer { ew_parakeet_free(context) }
        guard let pointer = ew_parakeet_transcribe(context, args[3], "", 2) else { fatalError(String(cString: ew_whisper_last_error())) }
        let transcript = String(cString: pointer)
        ew_whisper_string_free(pointer)
        guard let words = ParakeetWordTiming.read(context: context, text: transcript), words.count > 5 else {
            fatalError("Actual backend token timing must round-trip the normal transcript")
        }
        guard words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }),
              words.last!.end > 5, words.last!.end < 20 else { fatalError("Backend token time units must be seconds") }
        guard ParakeetWordTiming.read(context: context, text: "") == nil else {
            fatalError("A silence/VAD skip must not expose stale tokens from the last decode")
        }
        try testQuietSpeech(context: context, fixture: URL(fileURLWithPath: args[3]))
        print("ParakeetWordTimingTests passed (real backend, transcript round trip, timestamp units, silence fallback)")
    }

    private static func testQuietSpeech(context: UnsafeMutableRawPointer, fixture: URL) throws {
        let vad = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/EdgeWhisper/Models/ggml-silero-v6.2.0.bin")
        guard FileManager.default.fileExists(atPath: vad.path) else { fatalError("Quiet-speech regression requires the installed local VAD model") }
        let file = try AVAudioFile(forReading: fixture)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        let count = Int(buffer.frameLength)
        let original = Array(UnsafeBufferPointer(start: samples, count: count))
        // Match the duration of a 1024-frame microphone callback at 48 kHz.
        var peakRMS: Float = 0
        for offset in stride(from: 0, to: count, by: 341) {
            let end = min(count, offset + 341)
            let energy = original[offset..<end].reduce(Float.zero) { $0 + $1 * $1 }
            peakRMS = max(peakRMS, sqrt(energy / Float(end - offset)))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("luxit-quiet-speech-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for kind in ["quiet", "silence", "fan"] {
            var seed: UInt64 = 8129
            var lowpass: Float = 0
            for i in 0..<count {
                seed = seed &* 6364136223846793005 &+ 1
                let white = Float((seed >> 32) & 0xffff) / 32768 - 1
                lowpass += (white - lowpass) * 0.12
                switch kind {
                case "quiet": samples[i] = original[i] * 0.006 / peakRMS
                case "fan": samples[i] = lowpass * 0.004 + 0.001 * sin(Float(i) * 2 * .pi * 80 / 16_000)
                default: samples[i] = 0
                }
            }
            let wav = root.appendingPathComponent("\(kind).wav")
            do {
                let output = try AVAudioFile(forWriting: wav, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
                try output.write(from: buffer)
            }
            guard let pointer = ew_parakeet_transcribe(context, wav.path, vad.path, 2) else {
                fatalError(String(cString: ew_whisper_last_error()))
            }
            let text = String(cString: pointer)
            ew_whisper_string_free(pointer)
            if kind == "quiet" {
                guard text.lowercased().contains("country"), text.split(separator: " ").count > 10 else {
                    fatalError("Real quiet speech rejected by the old volume gate must still transcribe")
                }
            } else {
                guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    fatalError("The backend speech detector must reject \(kind) without the old volume gate")
                }
                guard ParakeetWordTiming.read(context: context, text: text) == nil else {
                    fatalError("Rejected noise must not expose tokens from quiet speech")
                }
            }
        }
        print("Quiet-speech regression passed (public fixture at low volume, silence and synthetic fan rejected)")
    }
}
