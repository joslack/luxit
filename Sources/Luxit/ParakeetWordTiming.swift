import Foundation

enum ParakeetWordTiming {
    /// Call on the inference queue before another decode can replace context.
    static func read(context: UnsafeMutableRawPointer, text: String) -> [TranscriptionWord]? {
        // A VAD skip leaves old backend tokens in the context.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var count: Int32 = 0
        guard let tokens = ew_parakeet_timed_tokens(context, &count) else { return nil }
        defer { ew_timed_tokens_free(tokens) }
        let pieces = UnsafeBufferPointer(start: tokens, count: Int(count)).compactMap { token
            -> (bytes: Data, start: Double, end: Double, beginsWord: Bool)? in
            guard let text = token.text else { return nil }
            return (Data(bytes: text, count: strlen(text)), token.start, token.end, token.begins_word != 0)
        }
        return SpeakerAlignment.words(tokens: pieces, text: text)
    }
}
