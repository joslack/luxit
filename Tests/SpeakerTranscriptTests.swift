import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
@main enum SpeakerTranscriptTests {
    static func main() throws {
        let words = [TranscriptionWord(text: "A", start: 0, end: 0.3),
                     TranscriptionWord(text: "quiet", start: 0.3, end: 0.6),
                     TranscriptionWord(text: "answer.", start: 0.6, end: 1)]
        let turns = [SpeakerTurn(source: .computer, speaker: 0, start: 10, end: 10.6),
                     SpeakerTurn(source: .computer, speaker: 1, start: 10.55, end: 11),
                     SpeakerTurn(source: .microphone, speaker: 3, start: 10, end: 11)]
        let spans = SpeakerAlignment.spans(text: "A quiet answer.", words: words, turns: turns,
                                           source: .computer, offset: 10)!
        expect(spans.map(\.text).joined(separator: " ") == "A quiet answer.", "Every word remains after labeling")
        expect(spans.first?.speaker == 0 && spans.last?.speaker == 1, "Word times use the source's absolute recording timeline")
        let overlap = turns + [SpeakerTurn(source: .computer, speaker: 2, start: 10, end: 11)]
        let unclear = SpeakerAlignment.spans(text: "A quiet answer.", words: words, turns: overlap,
                                             source: .computer, offset: 10)!
        expect(unclear.allSatisfy { $0.speaker == nil }, "Overlapping speakers stay unassigned without losing words")
        expect(SpeakerAlignment.spans(text: "A DIFFERENT answer.", words: words, turns: turns,
                                      source: .computer, offset: 10) == nil, "Mismatched timings cannot replace recognized text")
        expect(SpeakerAlignment.spans(text: "A quiet answer.", words: words, turns: [],
                                      source: .computer, offset: 10)?.first?.text == "A quiet answer.",
               "Missing speaker activity keeps all text")
        let pieces: [(bytes: Data, start: Double, end: Double, beginsWord: Bool)] = [
            (Data("▁caf".utf8), 0, 0.3, true), (Data([0xc3]), 0.3, 0.4, false),
            (Data([0xa9]), 0.4, 0.5, false), (Data("!".utf8), 0.5, 0.5, false)]
        expect(SpeakerAlignment.words(tokens: pieces, text: "café!")?.first?.text == "café!",
               "Token boundaries inside Unicode characters preserve the original transcript")
        expect(SpeakerAlignment.words(tokens: pieces, text: "coffee") == nil, "An extraction mismatch falls back to ordinary text")
        let old = "{\"id\":\"00000000-0000-0000-0000-000000000001\",\"createdAt\":0,\"duration\":1,\"source\":\"recording\",\"text\":\"Old transcript\"}"
        let entry = try JSONDecoder().decode(TranscriptEntry.self, from: Data(old.utf8))
        expect(entry.speakerState == nil && entry.displayText == "Old transcript", "Old history remains readable")
        print("SpeakerTranscriptTests passed")
    }
}
