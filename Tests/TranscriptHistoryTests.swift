import Foundation
import CoreGraphics

private func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

@main
enum TranscriptHistoryTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.json")
        let store = TranscriptHistory(url: url)
        let first = TranscriptEntry(createdAt: Date(timeIntervalSince1970: 1), duration: 4,
                                    source: .dictation, text: "A synthetic dictation.")
        let second = TranscriptEntry(createdAt: Date(timeIntervalSince1970: 2), duration: 8,
                                     source: .recording, text: "A synthetic recording.")
        try store.append(second)
        try store.append(first) // Transcriptions may finish in a different order.
        expect(store.entries == [second, first], "History uses recording order, not completion order")
        let reloaded = TranscriptHistory(url: url)
        expect(reloaded.entries == [second, first], "History survives relaunch with full metadata")
        try reloaded.delete(id: second.id)
        expect(TranscriptHistory(url: url).entries == [first], "Deletion persists")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Transcripts are owner-readable only")
        let legacy = "[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"createdAt\":0,\"duration\":1,\"source\":\"dictation\",\"text\":\"Older transcript\"}]"
        let oldEntries = try JSONDecoder().decode([TranscriptEntry].self, from: Data(legacy.utf8))
        expect(oldEntries.first?.text == "Older transcript" && oldEntries.first?.segments == nil,
               "Existing history remains readable after adding live transcript segments")
        let computer = TranscriptSegment(id: UUID(), start: 2, source: .computer, text: "Please send the draft today.", duration: 3)
        let echo = TranscriptSegment(id: UUID(), start: 2.1, source: .microphone, text: "Please send the draft today!", duration: 3)
        let original = [computer, echo]
        let merged = TranscriptSegment.coalescingSources(original)
        expect(merged.count == 1 && merged[0].additionalSource == .microphone,
               "Matching simultaneous paragraphs appear once with both sources credited")
        var entry = TranscriptEntry(createdAt: Date(), duration: 5, source: .recording,
                                    text: "", segments: original, recordingState: .recording)
        try store.append(entry)
        expect(TranscriptHistory(url: url).entries.first?.segments == original && entry.displaySegments?.count == 1,
               "Presentation merging preserves both original captures on disk")
        let reply = TranscriptSegment(id: UUID(), start: 5.2, source: .microphone, text: computer.text, duration: 3)
        expect(TranscriptSegment.coalescingSources([computer, reply]).count == 2,
               "A person repeating the same words later is kept")
        let unique = TranscriptSegment(id: UUID(), start: 2.1, source: .microphone, text: "Please send the draft tomorrow.", duration: 3)
        expect(TranscriptSegment.coalescingSources([computer, unique]).count == 2,
               "Different words in overlapping speech are never removed")
        let yes = TranscriptSegment(id: UUID(), start: 2, source: .computer, text: "Yes", duration: 1)
        let agreement = TranscriptSegment(id: UUID(), start: 2.1, source: .microphone, text: "Yes", duration: 1)
        expect(TranscriptSegment.coalescingSources([yes, agreement]).count == 2,
               "Short individual answers aren't treated as playback duplicates")
        let longPlayback = TranscriptSegment(id: UUID(), start: 10, source: .computer,
            text: "First open the settings. Then select the microphone. Finally start the recording.", duration: 9)
        let middleEcho = TranscriptSegment(id: UUID(), start: 13.2, source: .microphone,
            text: "Then select the microphone.", duration: 2.8)
        expect(TranscriptSegment.coalescingSources([longPlayback, middleEcho]).count == 1,
               "A shorter microphone echo inside a longer playback paragraph appears once")
        let playbackA = TranscriptSegment(id: UUID(), start: 20, source: .computer,
            text: "Please open the settings.", duration: 2)
        let playbackB = TranscriptSegment(id: UUID(), start: 22.2, source: .computer,
            text: "Then select the microphone.", duration: 2)
        let joinedEcho = TranscriptSegment(id: UUID(), start: 20.3, source: .microphone,
            text: "Please open the settings, then select the microphone!", duration: 4)
        let splitMerged = TranscriptSegment.coalescingSources([playbackB, joinedEcho, playbackA])
        expect(splitMerged.count == 2 && splitMerged.allSatisfy { $0.additionalSource == .microphone },
               "One microphone paragraph can match consecutive computer chunks even out of order")
        let interruption = TranscriptSegment(id: UUID(), start: 13.2, source: .microphone,
            text: "Then select the microphone. Wait, use the other one.", duration: 3)
        expect(TranscriptSegment.coalescingSources([longPlayback, interruption]).count == 2,
               "Speech over playback is kept in full when it contains additional words")
        let correction = TranscriptSegment(id: UUID(), start: 13.2, source: .microphone,
            text: "Then select the speakers.", duration: 2.8)
        expect(TranscriptSegment.coalescingSources([longPlayback, correction]).count == 2,
               "Similar words with a different meaning must never be fuzzy-deduplicated")
        let lateRepeat = TranscriptSegment(id: UUID(), start: 18.8, source: .microphone,
            text: middleEcho.text, duration: 3)
        expect(TranscriptSegment.coalescingSources([longPlayback, lateRepeat]).count == 2,
               "A later repetition with only a small time overlap remains visible")
        let legacySegments = "[{\"id\":\"00000000-0000-0000-0000-000000000002\",\"start\":0,\"source\":\"microphone\",\"text\":\"Older paragraph\"}]"
        entry.segments = try JSONDecoder().decode([TranscriptSegment].self, from: Data(legacySegments.utf8))
        expect(entry.displaySegments?.first?.text == "Older paragraph", "Older paragraphs without duration remain readable")
        let damaged = Data("unreadable history".utf8)
        try damaged.write(to: url)
        let broken = TranscriptHistory(url: url)
        expect(broken.error != nil, "Unreadable history is surfaced")
        do { try broken.append(first); fatalError("Must not overwrite damaged history") } catch {}
        let remaining = try Data(contentsOf: url)
        expect(remaining == damaged, "Corrupt history remains available for recovery")

        var timeline = RecordingTimeline(startedAt: 100)
        expect(timeline.position(at: 99) == nil, "Pre-start samples are dropped")
        timeline.pause(at: 103)
        expect(timeline.duration(at: 120) == 3, "Paused clock freezes")
        expect(timeline.position(at: 104) == nil, "Paused samples are dropped")
        timeline.resume(at: 113)
        expect(timeline.position(at: 104) == nil, "Late callbacks inside a pause remain excluded")
        expect(timeline.position(at: 114) == 4, "Tracks share the same compressed timeline")
        timeline.pause(at: 115)
        timeline.resume(at: 117)
        expect(timeline.duration(at: 120) == 8, "Multiple pauses remove only paused time")

        expect(TranscriptPanelLayout.size == CGSize(width: 560, height: 340),
               "The panel keeps a compact footprint")
        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 900),
                       CGRect(x: -1600, y: 200, width: 1600, height: 900),
                       CGRect(x: 0, y: 0, width: 600, height: 400)] {
            let frame = TranscriptPanelLayout.frame(in: screen)
            expect(frame.midX == screen.midX, "Panel is horizontally centered on its display")
            expect(frame.maxY == screen.maxY, "Panel attaches directly to the top visible edge")
            expect(screen.contains(frame), "Panel fits small and offset displays")
        }
        print("TranscriptHistoryTests passed")
    }
}
