import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main
private enum DictationSegmenterTests {
    static let rate = DictationSegmenter.sampleRate

    static func speech(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { Float(sin(Double($0) * 0.05)) * 0.1 }
    }

    static func silence(_ seconds: Double) -> [Float] {
        Array(repeating: 0.0005, count: Int(seconds * Double(rate)))
    }

    /// Feeds audio in 1024-sample callbacks like the microphone tap.
    static func run(_ audio: [Float]) -> [DictationSegment] {
        var segmenter = DictationSegmenter()
        var segments: [DictationSegment] = []
        var offset = 0
        while offset < audio.count {
            let end = min(audio.count, offset + 1024)
            segments += segmenter.append(Array(audio[offset..<end]))
            offset = end
        }
        if let tail = segmenter.finish() { segments.append(tail) }
        return segments
    }

    static func main() {
        let short = speech(3) + silence(1) + speech(3)
        expect(run(short).count == 1, "a short dictation stays whole despite a pause")

        let paused = speech(9) + silence(1) + speech(5)
        let pausedSegments = run(paused)
        expect(pausedSegments.count == 2, "a pause after the minimum length starts a new piece")
        expect(abs(pausedSegments[0].duration - 9.3) < 0.05, "the cut lands inside the pause")
        expect(pausedSegments[1].index == 1 && abs(pausedSegments[1].start - pausedSegments[0].duration) < 0.001,
               "pieces are numbered and timed consecutively")
        expect(pausedSegments.flatMap(\.samples) == paused, "pieces reproduce the input exactly")

        let brief = speech(9) + silence(0.3) + speech(5)
        expect(run(brief).count == 1, "a breath shorter than the pause length does not cut")

        var unbroken = speech(40)
        let dip = Int(28.0 * Double(rate))
        for index in dip..<(dip + 320) { unbroken[index] = 0 }
        let forced = run(unbroken)
        expect(forced.count == 2, "speech without pauses is cut at the maximum length")
        expect(abs(forced[0].duration - 28.02) < 0.05, "a forced cut uses the quietest recent moment")
        expect(forced.flatMap(\.samples) == unbroken, "forced cuts keep every sample")

        let quiet = silence(20)
        expect(run(quiet).count == 1, "silence alone is never cut into pieces")

        let long = (0..<6).flatMap { _ in speech(10) + silence(0.8) }
        let longSegments = run(long)
        expect(longSegments.count == 7, "a long dictation is cut at each qualifying pause")
        expect(longSegments.dropLast().allSatisfy { $0.voicedSeconds > 9 && $0.voicedSeconds < 10.5 },
               "each piece reports its voiced time")
        expect(longSegments.last?.voicedSeconds == 0, "trailing silence is reported as unvoiced")

        expect(DictationTranscriptJoiner.join(["Hello there. ", "", " How are you?"]) == "Hello there. How are you?",
               "pieces join with single spaces and skip empty text")
        expect(DictationTranscriptJoiner.join(["to keep their little heads", "From falling in the snow."])
               == "to keep their little heads from falling in the snow.",
               "a sentence continued across a pause is not capitalized mid-sentence")
        expect(DictationTranscriptJoiner.join(["We should ship it.", "The tests pass."])
               == "We should ship it. The tests pass.", "a new sentence keeps its capital")
        expect(DictationTranscriptJoiner.join(["we switched to", "Parakeet today", "I think"])
               == "we switched to Parakeet today I think", "names and I are never lowercased")

        var assembled: [Result<String, Error>] = []
        let pieces = DictationPieces(profile: .parakeetMetal)
        pieces.onComplete = { assembled.append($0) }
        pieces.record(index: 1, result: .success("second"))
        pieces.record(index: 0, result: .success("first"))
        expect(assembled.isEmpty, "nothing is assembled before recording stops")
        pieces.expectedCount = 3
        pieces.completeIfReady()
        expect(assembled.isEmpty, "assembly waits for the last piece")
        pieces.record(index: 2, result: .success("third"))
        expect(assembled.count == 1 && (try? assembled[0].get()) == "first second third",
               "pieces finishing out of order assemble in spoken order, exactly once")
        pieces.record(index: 2, result: .success("again"))
        expect(assembled.count == 1, "a completed dictation never reports twice")

        var failed: [Result<String, Error>] = []
        let failing = DictationPieces(profile: .parakeetMetal)
        failing.record(index: 0, result: .failure(NSError(domain: "test", code: 1)))
        failing.expectedCount = 2
        failing.onComplete = { failed.append($0) }
        failing.completeIfReady()
        expect(failed.count == 1 && (try? failed[0].get()) == nil, "any failed piece fails the assembly")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("luxit-segmenter-test.wav")
        try? DictationWAV.write([0, 0.5, -1, 2, .nan], sampleRate: rate, to: url)
        let wav = (try? Data(contentsOf: url)) ?? Data()
        try? FileManager.default.removeItem(at: url)
        let pcm = wav.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        expect(wav.count == 54 && String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF",
               "WAV output has a 44-byte header and 16-bit samples")
        expect(pcm == [0, 16383, -32767, 32767, 0], "WAV samples are clamped and non-finite values are silenced")

        print("DictationSegmenterTests passed")
    }
}
