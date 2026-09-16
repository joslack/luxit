import AVFoundation
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main enum RecordingSessionTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("luxit-session-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        func append(_ session: RecordingSession, source: RecordingAudioSource = .microphone,
                    seconds: Double, start: Double, speech: Bool, amplitude: Float = 0.1) throws {
            let samples = [Float](repeating: amplitude, count: Int(seconds * 16_000))
            try samples.withUnsafeBufferPointer {
                _ = try session.append(source: source, samples: $0.baseAddress!, count: $0.count, start: start, speech: speech)
            }
        }
        let session = try RecordingSession(root: root)
        try append(session, seconds: 2, start: 0, speech: true)
        try append(session, seconds: 0.6, start: 2, speech: false, amplitude: 0)
        expect(session.snapshot.pending.isEmpty, "A short hesitation doesn't cut a phrase")
        try append(session, seconds: 0.1, start: 2.6, speech: false, amplitude: 0)
        expect(session.snapshot.pending.count == 1, "A natural pause publishes a chunk before Stop")
        let first = session.snapshot.pending[0]
        expect(abs(first.duration - 2.7) < 0.001 && first.source == .microphone, "Chunk preserves its source and capture time")
        try append(session, source: .computer, seconds: 1, start: 0.5, speech: true, amplitude: 0.2)
        try session.flush()
        expect(session.snapshot.pending.count == 2 && !session.snapshot.stopped, "Pause seals both tracks without ending the session")
        let wav = try session.makeWAV(chunk: first)
        let file = try AVAudioFile(forReading: wav)
        expect(file.length == 43200 && file.processingFormat.sampleRate == 16000, "Bounded chunks become valid backend PCM input")
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 43200)!
        try file.read(into: buffer)
        expect(abs(buffer.floatChannelData![0][100] - 0.1) < 0.001 && buffer.floatChannelData![0][40000] == 0,
               "Segmentation does not alter recorded speech or trailing silence")
        try session.complete(chunkID: first.id, text: "A quiet synthetic sentence.")
        let history = TranscriptHistory(url: root.appendingPathComponent("history.json"))
        try history.append(session.snapshot.entry(state: .recording))
        try history.append(session.snapshot.entry(state: .processing))
        expect(history.entries.count == 1 && history.entries[0].segments?.first?.source == .microphone,
               "Live updates replace one history entry and retain source labels")
        session.removeCompletedAudio(chunk: first)
        expect(!FileManager.default.fileExists(atPath: session.directory.appendingPathComponent(first.filename).path),
               "Successfully saved chunks release their audio")
        try session.finish(duration: 3)
        let recovered = try RecordingSession(recovering: session.directory)
        expect(recovered.snapshot.pending.count == 1 && recovered.snapshot.chunks.first?.text != nil,
               "Recovery retries only unfinished audio and keeps already completed text")
        let other = recovered.snapshot.pending[0]
        try recovered.complete(chunkID: other.id, text: "Another person on the computer.")
        expect(recovered.snapshot.complete && recovered.snapshot.entry(state: .complete).segments?.count == 2,
               "Sources remain separate after all chunks finish")

        let gapped = try RecordingSession(root: root)
        try append(gapped, seconds: 0.5, start: 0, speech: true)
        try append(gapped, seconds: 0.5, start: 0.525, speech: true)
        try gapped.finish(duration: 1.025)
        let gapChunk = gapped.snapshot.pending[0]
        expect(abs(gapChunk.duration - 1.025) < 0.001, "Small timestamp gaps are preserved instead of squeezing the audio timeline")
        let gapWAV = try AVAudioFile(forReading: gapped.makeWAV(chunk: gapChunk))
        let gapBuffer = AVAudioPCMBuffer(pcmFormat: gapWAV.processingFormat, frameCapacity: 17000)!
        try gapWAV.read(into: gapBuffer)
        expect(gapBuffer.floatChannelData![0][8100] == 0 && gapBuffer.floatChannelData![0][8500] > 0.09,
               "Timestamp gaps contain silence while resumed speech keeps its original gain")

        var interrupted: RecordingSession? = try RecordingSession(root: root)
        let interruptedDirectory = interrupted!.directory
        try append(interrupted!, seconds: 1.25, start: 4, speech: true)
        interrupted = nil // No finish; simulates process exit before the pause.
        let resumed = try RecordingSession(recovering: interruptedDirectory)
        expect(resumed.snapshot.stopped && resumed.snapshot.pending.count == 1 &&
               abs(resumed.snapshot.pending[0].duration - 1.25) < 0.001 && resumed.snapshot.pending[0].start == 4,
               "An interrupted open chunk recovers from actual PCM bytes with its original timestamp")
        _ = try resumed.makeWAV(chunk: resumed.snapshot.pending[0])
        _ = try resumed.makeWAV(chunk: resumed.snapshot.pending[0])
        expect(resumed.snapshot.pending.count == 1, "Preparing or retrying inference cannot consume an uncommitted chunk")

        let long = try RecordingSession(root: root)
        for second in 0..<2700 { try append(long, seconds: 1, start: Double(second), speech: true) }
        try long.finish(duration: 2700)
        let chunks = long.snapshot.pending
        expect(chunks.count > 100 && chunks.allSatisfy { $0.duration <= 25.001 },
               "A 45-minute uninterrupted conversation never creates an unbounded inference job")
        expect(abs(chunks.reduce(0) { $0 + $1.duration - $1.overlap } - 2700) < 0.001,
               "Every captured sample is retained exactly once outside intentional boundary overlap")
        expect(chunks.dropFirst().allSatisfy { abs($0.overlap - 0.8) < 0.001 },
               "Forced boundaries retain context to avoid clipped words")
        for (left, right) in zip(chunks, chunks.dropFirst()) {
            expect(abs(left.start + left.duration - right.start - right.overlap) < 0.001,
                   "Long recordings maintain a continuous timeline")
        }
        let recoveredLong = try RecordingSession(recovering: long.directory)
        expect(recoveredLong.snapshot.pending == chunks, "Long-session backlog survives restart without reordering or loss")
        expect(TranscriptStitcher.removingOverlap(previous: "We should ship by Friday.", next: "by Friday, then rest.") == "then rest.",
               "Overlapping words reconcile despite punctuation differences")
        expect(TranscriptStitcher.removingOverlap(previous: "Yes", next: "Yes, definitely.") == "Yes, definitely.",
               "A short repeated answer is not mistaken for duplicate context")
        let labeled = try RecordingSession(root: root, detectSpeakers: true)
        try append(labeled, seconds: 2, start: 0, speech: true)
        try labeled.finish(duration: 2)
        let labeledChunk = labeled.snapshot.pending[0]
        try labeled.complete(chunkID: labeledChunk.id, text: "First person.", words: [
            TranscriptionWord(text: "First", start: 0, end: 0.5),
            TranscriptionWord(text: "person.", start: 0.5, end: 1)])
        labeled.removeCompletedAudio(chunk: labeledChunk)
        expect(!labeled.snapshot.complete && FileManager.default.fileExists(atPath: labeled.directory.appendingPathComponent(labeledChunk.filename).path),
               "Text is available while speaker processing retains audio for recovery")
        let labelRecovery = try RecordingSession(recovering: labeled.directory)
        expect(labelRecovery.snapshot.chunks[0].words?.count == 2 && labelRecovery.snapshot.speakerState == .pending,
               "Timing and pending speaker analysis survive restart")
        try labelRecovery.updateSpeakers(turns: [SpeakerTurn(source: .microphone, speaker: 1, start: 0, end: 2)], state: .complete)
        let labeledEntry = labelRecovery.snapshot.entry(state: .complete)
        expect(labelRecovery.snapshot.complete && labeledEntry.segments?.first?.speakerSpans?.first?.speaker == 1,
               "Final labels make the recording complete and align to its original words")
        expect(labeledEntry.displayText.contains("Speaker 2") && labeledEntry.displayText.contains("First person."),
               "Copied transcripts include speaker labels and all original words")
        try labelRecovery.updateSpeakers(turns: [], state: .unavailable)
        expect(labelRecovery.snapshot.complete && labelRecovery.snapshot.entry(state: .complete).segments?.first?.text == "First person.",
               "Speaker failure does not block or erase transcription")

        let attributes = try FileManager.default.attributesOfItem(atPath: interruptedDirectory.appendingPathComponent("session.json").path)
        expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Recording metadata stays private")
        print("RecordingSessionTests passed (including 45-minute capture and interruption recovery)")
    }
}
