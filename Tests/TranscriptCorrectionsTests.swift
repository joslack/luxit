import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main enum TranscriptCorrectionsTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("corrections.json")
        let store = TranscriptCorrections(url: url)
        func correct(_ text: String) -> String { store.apply(TranscriptionResult(text: text)).text }
        expect(correct("Luke sit") == "Luke sit", "No dictionary is enabled by default")

        try store.save([TextCorrection(from: "Luke sit", to: "Luxit"),
                        TextCorrection(from: "underwrite", to: "UnderWrite"),
                        TextCorrection(from: "a.b", to: "$5\\literal")])
        expect(correct("LUKE   SIT, Luke\nsit!") == "Luxit, Luxit!", "Case and whitespace variants share one phrase rule")
        expect(correct("underwriter preunderwrite underwrite2 underwrite_name underwrite") ==
               "underwriter preunderwrite underwrite2 underwrite_name UnderWrite", "Only whole words change")
        expect(correct("a.b axb") == "$5\\literal axb", "Simple rules escape regex and replacement syntax")
        expect(correct("éLuke sit Luke sité 🙂 Luke sit") == "éLuke sit Luke sité 🙂 Luxit", "Unicode boundaries and surrogate pairs survive")
        let restarted = TranscriptCorrections(url: url)
        expect(restarted.apply(TranscriptionResult(text: "Luke sit")).text == "Luxit", "Saved rules survive restart")

        try store.save([TextCorrection(from: #"Luke\s+(sit|set)"#, to: "Luxit", isPattern: true),
                        TextCorrection(from: #"(item|items)\s+(\d+)"#, to: "$2 $1", isPattern: true)])
        expect(correct("Luke sit, Luke set; items 12.") == "Luxit, Luxit; 12 items.", "Alternatives and captured groups work in one pattern")
        expect(correct("preLuke set item 2suffix") == "preLuke set item 2suffix", "Pattern alternatives also respect word boundaries")
        try store.save([TextCorrection(from: #"Luke(?=\s+sit)"#, to: "Luxit", isPattern: true)])
        expect(correct("Luke sit Luke set") == "Luxit sit Luke set", "Lookahead retains contextual text")
        try store.save([TextCorrection(from: #"(?=Luke)"#, to: "insert", isPattern: true)])
        expect(correct("Luke") == "Luke", "Zero-width patterns cannot invent inserted words")

        try store.save([TextCorrection(from: "Luke sit", to: "Luxit"), TextCorrection(from: "Luxit", to: "Luxit Pro")])
        expect(correct("Luke sit") == "Luxit Pro", "Rules use the visible file/list order")
        let durable = try Data(contentsOf: url)
        for rule in [TextCorrection(from: " ", to: "x"), TextCorrection(from: "x", to: " "),
                     TextCorrection(from: "(", to: "x", isPattern: true),
                     TextCorrection(from: "(x)", to: "$2", isPattern: true)] {
            do { try store.save([rule]); fatalError("Invalid rules must reject Save") }
            catch { }
            expect(tryData(url) == durable, "Failed validation preserves the saved file")
        }

        try Data("{broken".utf8).write(to: url, options: .atomic)
        expect(correct("Luke sit") == "Luxit Pro" && store.error != nil, "Malformed external edits retain the last valid rules and report an error")
        try Data(#"{"replacements":[{"from":"Luke sit","to":"Luxit New"}]}"#.utf8).write(to: url, options: .atomic)
        expect(correct("Luke sit") == "Luxit New" && store.error == nil, "External edits reload without a restart; missing pattern flag means literal")
        try FileManager.default.removeItem(at: url)
        expect(correct("Luke sit") == "Luke sit", "Deleting the rule file disables corrections")

        try store.save([TextCorrection(from: "Luke sit", to: "Luxit")])
        let input = TranscriptionResult(text: "Luke sit works. Yes!", words: [
            TranscriptionWord(text: "Luke", start: 0, end: 0.3),
            TranscriptionWord(text: "sit", start: 0.3, end: 0.6),
            TranscriptionWord(text: "works.", start: 0.6, end: 0.9),
            TranscriptionWord(text: "Yes!", start: 1.1, end: 1.4)
        ])
        let output = store.apply(input)
        expect(output.text == "Luxit works. Yes!", "Phrase correction joins words without losing the rest")
        expect(output.words?.first == TranscriptionWord(text: "Luxit", start: 0, end: 0.6), "Replacement inherits the original phrase's actual interval")
        expect(output.words?.last == input.words?.last, "Unchanged words retain their own timing")
        let turns = [SpeakerTurn(source: .microphone, speaker: 0, start: 0, end: 0.9),
                     SpeakerTurn(source: .microphone, speaker: 1, start: 1.1, end: 1.4)]
        let snapshot = RecordingSessionSnapshot(id: UUID(), createdAt: Date(), duration: 1.4, stopped: true,
            speakerState: .complete, speakerTurns: turns, chunks: [
                RecordingChunk(source: .microphone, start: 0, duration: 1.4, sealed: true, text: output.text, words: output.words)
            ])
        let entry = snapshot.entry(state: .complete)
        expect(entry.segments?.first?.speakerSpans == [SpeakerTextSpan(text: "Luxit works.", speaker: 0),
                                                      SpeakerTextSpan(text: "Yes!", speaker: 1)],
               "Recording journal, transcript and speaker spans use the same corrected words")
        let history = TranscriptHistory(url: directory.appendingPathComponent("history.json"))
        try history.append(entry)
        expect(TranscriptHistory(url: directory.appendingPathComponent("history.json")).entries.first?.displayText == entry.displayText,
               "Corrected text and labels survive history persistence")

        let crossing = SpeakerAlignment.spans(text: output.text, words: output.words!, turns: [
            SpeakerTurn(source: .microphone, speaker: 0, start: 0, end: 0.3),
            SpeakerTurn(source: .microphone, speaker: 1, start: 0.3, end: 1.4)
        ], source: .microphone, offset: 0)
        expect(crossing?.first?.speaker == nil, "A correction across two speakers stays uncertain instead of inventing identity")
        let badTiming = store.apply(TranscriptionResult(text: input.text, words: [TranscriptionWord(text: "mismatch", start: 0, end: 1)]))
        expect(badTiming.text == output.text && badTiming.words == nil, "Timing mismatch never discards corrected transcript words")
        try store.save([TextCorrection(from: "Luxit", to: "Luxit Pro 🙂")])
        let expanded = store.apply(output)
        expect(expanded.words?.map(\.text).joined(separator: " ") == expanded.text, "Expanded Unicode replacements still round-trip for speaker alignment")

        try store.save([TextCorrection(from: #"(a+)+b"#, to: "x", isPattern: true)])
        let pathological = String(repeating: "a", count: 20_000)
        let started = Date()
        expect(correct(pathological) == pathological && store.error != nil, "Pathological regex stops and preserves the original transcript")
        expect(Date().timeIntervalSince(started) < 2, "A bad pattern cannot hang the UI or recorder")
        print("TranscriptCorrectionsTests passed (phrases, patterns, caching, persistence, speaker timing, regex timeout)")
    }

    private static func tryData(_ url: URL) -> Data? { try? Data(contentsOf: url) }
}
