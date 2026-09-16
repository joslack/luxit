import AppKit

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main enum TranscriptContentTests {
    static func main() {
        _ = NSApplication.shared
        var entry = TranscriptEntry(createdAt: Date(), duration: 2700, source: .recording,
            text: "", segments: (0..<400).map { i in
                TranscriptSegment(id: UUID(), start: Double(i * 7), source: .microphone,
                    text: "First sentence. Second sentence. Third sentence.", duration: 7,
                    speakerSpans: [SpeakerTextSpan(text: "First sentence.", speaker: i % 4),
                        SpeakerTextSpan(text: "Second sentence.", speaker: nil),
                        SpeakerTextSpan(text: "Third sentence.", speaker: (i + 1) % 4)])
            }, recordingState: .recording, speakerState: .pending)
        let content = TranscriptContent.make(entry: entry, paused: false)
        expect(content.string.components(separatedBy: "First sentence.").count == 401,
            "Long labeled transcripts preserve every paragraph")
        expect(content.string.contains("[Speaker 1]") && content.string.contains("[?] Second sentence."),
            "Known and unclear speakers retain readable labels and words")
        expect(entry.speakerStatus == "Estimated speakers · labels updating", "Live status reflects available labels")
        let scroll = TranscriptScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 160))
        scroll.layoutSubtreeIfNeeded()
        scroll.update(content, initiallyFollowing: true, followRevision: 0)
        expect(scroll.transcript.frame.height > 160 && scroll.documentVisibleRect.minY > 0,
            "A long recording lays out in a bounded viewport and follows its latest text")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        expect(!scroll.following, "Manual scrolling releases following")
        let position = scroll.contentView.bounds.origin.y
        entry.segments![0].speakerSpans![0] = SpeakerTextSpan(text: "First sentence.", speaker: 3)
        entry.segments!.append(TranscriptSegment(id: UUID(), start: 2701, source: .computer, text: "Latest paragraph."))
        scroll.update(TranscriptContent.make(entry: entry, paused: false), initiallyFollowing: true, followRevision: 0)
        expect(abs(scroll.contentView.bounds.origin.y - position) < 1,
            "Appending text and revising earlier speaker labels preserve manual scroll position")
        scroll.update(TranscriptContent.make(entry: entry, paused: false), initiallyFollowing: true, followRevision: 1)
        expect(scroll.following && scroll.transcript.frame.height - scroll.documentVisibleRect.maxY < 2,
            "Latest returns to the bottom after a speaker revision")
        entry.segments = []
        expect(entry.speakerStatus == "Identifying speakers…", "Pending empty labels have visible status")
        entry.speakerState = .complete
        expect(entry.speakerStatus == "Speakers unclear · transcript preserved", "Uncertain results are explicit")
        print("TranscriptContentTests passed (long transcript, speaker revisions, follow, manual scroll)")
    }
}
