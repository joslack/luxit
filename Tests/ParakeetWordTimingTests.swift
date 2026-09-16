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
        print("ParakeetWordTimingTests passed (real backend, transcript round trip, timestamp units, silence fallback)")
    }
}
