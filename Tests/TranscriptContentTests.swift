import AppKit

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

private func withPreservedClipboard<T>(_ body: () -> T) -> T {
    let board = NSPasteboard.general
    let saved = (board.pasteboardItems ?? []).map { item in
        item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
    defer {
        board.clearContents()
        let restored = saved.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { board.writeObjects(restored) }
    }
    return body()
}

@main enum TranscriptContentTests {
    static func main() {
        _ = NSApplication.shared
        checkCopyShortcuts()
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
        expect(content.string.contains("[Speaker 1]") && !content.string.contains("[?]"),
            "Uncertainty does not appear as a speaker-switch marker")
        let uncertainRange = (content.string as NSString).range(of: "Second sentence.")
        let attributes = content.attributes(at: uncertainRange.location, effectiveRange: nil)
        expect(attributes[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
            "Unassigned words retain a dotted underline instead of an invented speaker")
        expect((attributes[.toolTip] as? String)?.contains("does not indicate a speaker change") == true,
            "Uncertainty has an explanation on the affected words")
        expect(entry.speakerStatus == "Speakers updating · dotted text is unassigned", "Live status explains the uncertainty styling")

        let pausedSpeech = TranscriptEntry(createdAt: Date(), duration: 3, source: .recording,
            text: "", segments: [TranscriptSegment(id: UUID(), start: 0, source: .microphone,
                text: "Before a pause after. New voice.", speakerSpans: [
                    SpeakerTextSpan(text: "Before", speaker: 0),
                    SpeakerTextSpan(text: "a pause", speaker: nil),
                    SpeakerTextSpan(text: "after.", speaker: 0),
                    SpeakerTextSpan(text: "New voice.", speaker: 1)])], speakerState: .complete)
        let pausedText = TranscriptContent.make(entry: pausedSpeech, paused: false).string
        expect(pausedText.contains("[Speaker 1] Before a pause after. [Speaker 2] New voice."),
            "A gap never repeats the same speaker, but a confirmed change remains visible")
        expect(pausedSpeech.segments?.first?.speakerSpans?[1].speaker == nil,
            "Presentation does not retroactively assign uncertain words")
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
        print("TranscriptContentTests passed (selected copy, select all, focus, long transcript, speaker revisions, scrolling)")
    }

    private static func checkCopyShortcuts() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 160),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let scroll = TranscriptScrollView(frame: panel.contentView!.bounds)
        panel.contentView = scroll
        let archived = TranscriptEntry(createdAt: Date(timeIntervalSince1970: 0), duration: 3,
            source: .dictation, text: "An older transcript: café 🥒 and a second sentence.")
        scroll.update(TranscriptContent.make(entry: archived, paused: false), initiallyFollowing: false, followRevision: 0)
        expect(panel.makeFirstResponder(scroll.transcript), "An archived read-only transcript can receive keyboard focus")
        func key(_ character: String, flags: NSEvent.ModifierFlags = .command) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0)!
        }
        let selection = (archived.text as NSString).range(of: "café 🥒")
        scroll.transcript.setSelectedRange(selection)
        let selectedCopy = withPreservedClipboard { () -> (Bool, String?) in
            NSPasteboard.general.clearContents()
            let handled = panel.performKeyEquivalent(with: key("c"))
            return (handled, NSPasteboard.general.string(forType: .string))
        }
        expect(selectedCopy.0 && selectedCopy.1 == "café 🥒",
            "Command-C through the panel copies only the selected Unicode text without an Edit menu")
        expect(panel.performKeyEquivalent(with: key("a")) &&
            scroll.transcript.selectedRange() == NSRange(location: 0, length: (archived.text as NSString).length),
            "Command-A selects the whole archived transcript")
        let fullCopy = withPreservedClipboard { () -> (Bool, String?) in
            NSPasteboard.general.clearContents()
            let handled = panel.performKeyEquivalent(with: key("C", flags: [.command, .capsLock]))
            return (handled, NSPasteboard.general.string(forType: .string))
        }
        expect(fullCopy.0 && fullCopy.1 == archived.text, "Select-all and copy preserve the complete transcript")
        let unhandled = withPreservedClipboard { () -> Bool in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("unchanged", forType: .string)
            _ = scroll.transcript.performKeyEquivalent(with: key("c", flags: []))
            _ = scroll.transcript.performKeyEquivalent(with: key("c", flags: [.command, .option]))
            panel.makeFirstResponder(nil)
            let stoleCopy = scroll.transcript.performKeyEquivalent(with: key("c"))
            return !stoleCopy && NSPasteboard.general.string(forType: .string) == "unchanged"
        }
        expect(unhandled, "Unfocused transcripts and unrelated shortcuts cannot overwrite the clipboard")
        expect(!scroll.transcript.isEditable && scroll.transcript.string == archived.text,
            "Copy shortcuts never make saved transcripts editable")
    }
}
