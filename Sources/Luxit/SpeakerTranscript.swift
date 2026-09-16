import Foundation

struct TranscriptionWord: Codable, Equatable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

struct TranscriptionResult {
    let text: String
    var words: [TranscriptionWord]? = nil
}

struct SpeakerTurn: Codable, Equatable {
    let source: RecordingAudioSource
    let speaker: Int
    let start: TimeInterval
    let end: TimeInterval
}

enum SpeakerAnalysisState: String, Codable {
    case pending, complete, unavailable
}

struct SpeakerTextSpan: Codable, Equatable {
    var text: String
    let speaker: Int?
}

enum SpeakerAlignment {
    static func normalized(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Text is authoritative. Timing extraction or alignment failure must never
    /// drop a word, and uncertain/overlapping activity must not invent a person.
    static func spans(text: String, words: [TranscriptionWord], turns: [SpeakerTurn],
                      source: RecordingAudioSource, offset: TimeInterval) -> [SpeakerTextSpan]? {
        guard !words.isEmpty, normalized(words.map(\.text).joined(separator: " ")) == normalized(text),
              words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }) else { return nil }
        let begin = offset + (words.map(\.start).min() ?? 0)
        let end = offset + (words.map { max($0.end, $0.start + 0.08) }.max() ?? 0)
        let nearby = turns.filter {
            $0.source == source && $0.speaker >= 0 && $0.speaker < 4 &&
            $0.start.isFinite && $0.end.isFinite && $0.start < end && $0.end > begin
        }
        var spans: [SpeakerTextSpan] = []
        for word in words {
            let begin = offset + word.start
            let end = max(offset + word.end, begin + 0.08)
            var scores: [Int: Double] = [:]
            for turn in nearby {
                scores[turn.speaker, default: 0] += max(0, min(end, turn.end) - max(begin, turn.start))
            }
            let ranked = scores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            let best = ranked.first
            let second = ranked.dropFirst().first?.value ?? 0
            let speaker = best != nil && best!.value >= (end - begin) * 0.6 && second < (end - begin) * 0.25
                ? best!.key : nil
            if spans.last?.speaker == speaker, !spans.isEmpty {
                spans[spans.count - 1].text += " " + word.text
            } else { spans.append(SpeakerTextSpan(text: word.text, speaker: speaker)) }
        }
        return spans
    }

    /// Parakeet's raw pieces contain a UTF-8 word-boundary marker. Accumulate
    /// bytes before decoding so a multi-byte character split across tokens is
    /// preserved. A failed round trip leaves the ordinary transcript usable.
    static func words(tokens: [(bytes: Data, start: Double, end: Double, beginsWord: Bool)],
                      text: String) -> [TranscriptionWord]? {
        var chunks: [(bytes: Data, start: Double, end: Double)] = []
        for token in tokens {
            if token.beginsWord || chunks.isEmpty {
                chunks.append((token.bytes, token.start, token.end))
            } else {
                chunks[chunks.count - 1].bytes.append(token.bytes)
                chunks[chunks.count - 1].end = max(chunks[chunks.count - 1].end, token.end)
            }
        }
        let words = chunks.map { chunk in
            TranscriptionWord(text: String(decoding: chunk.bytes, as: UTF8.self)
                .replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespacesAndNewlines),
                              start: chunk.start, end: chunk.end)
        }.filter { !$0.text.isEmpty }
        guard normalized(words.map(\.text).joined(separator: " ")) == normalized(text) else { return nil }
        return words
    }
}
