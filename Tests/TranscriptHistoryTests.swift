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
