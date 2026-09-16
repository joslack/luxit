import AppKit

enum TranscriptContent {
    static func make(entry: TranscriptEntry, paused: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let caption: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        func append(_ text: String, _ attributes: [NSAttributedString.Key: Any]) {
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        guard let segments = entry.displaySegments else {
            append(entry.text, body)
            return result
        }
        let colors: [NSColor] = [.systemCyan, .systemPurple, .systemMint, .systemOrange]
        for segment in segments {
            append("\(TranscriptSegment.timestamp(segment.start)) · \(segment.sourceTitle)\n", caption)
            if let spans = segment.speakerSpans, !spans.isEmpty {
                var previousSpeaker: Int?
                for (index, span) in spans.enumerated() {
                    if index > 0 { append(" ", body) }
                    if let speaker = span.speaker {
                        if speaker != previousSpeaker {
                            var marker = caption
                            marker[.foregroundColor] = colors[max(0, speaker) % colors.count]
                            append("[Speaker \(speaker + 1)] ", marker)
                        }
                        previousSpeaker = speaker
                        append(span.text, body)
                    } else {
                        // A gap in attribution is not evidence of a new person.
                        // Preserve the uncertainty without inserting a turn marker
                        // or assigning these words to either neighboring speaker.
                        var uncertain = body
                        uncertain[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                        uncertain[.underlineColor] = NSColor.tertiaryLabelColor
                        uncertain[.toolTip] = "Speaker unassigned. A pause or overlapping voices can make attribution uncertain; this does not indicate a speaker change."
                        append(span.text, uncertain)
                    }
                }
            } else { append(segment.text, body) }
            append("\n\n", body)
        }
        if entry.recordingState?.inProgress == true {
            append(paused ? "Recording paused." : (entry.recordingState == .recording
                ? "Listening… New paragraphs appear at pauses." : "Finishing the remaining audio…"), caption)
        } else if segments.isEmpty {
            append(entry.recordingState == .failed ? "Audio is saved. Retry to finish the transcript." : "No speech detected.", body)
        }
        return result
    }
}

/// TextKit owns the document's height and scroll position. SwiftUI's lazy stack
/// and animated scroll-to-bottom can repeatedly invalidate each other's layout
/// when speaker labels change the heights of earlier paragraphs.
final class TranscriptScrollView: NSScrollView {
    let transcript = NSTextView(frame: .zero)
    var onFollowingChanged: ((Bool) -> Void)?
    private(set) var following = false
    private var initialized = false
    private var followRevision = 0
    private var measuredWidth: CGFloat = 0
    private var measuring = false
    private var observers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.drawsBackground = false
        transcript.isVerticallyResizable = true
        transcript.isHorizontallyResizable = false
        transcript.textContainerInset = NSSize(width: 0, height: 4)
        transcript.textContainer?.lineFragmentPadding = 0
        transcript.textContainer?.widthTracksTextView = true
        transcript.autoresizingMask = [.width]
        documentView = transcript
        for name in [NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                guard let self else { return }
                let atBottom = self.transcript.frame.height - self.documentVisibleRect.maxY < 48
                guard atBottom != self.following else { return }
                self.following = atBottom
                self.onFollowingChanged?(atBottom)
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    func update(_ text: NSAttributedString, initiallyFollowing: Bool, followRevision: Int) {
        if !initialized { following = initiallyFollowing; initialized = true }
        if followRevision != self.followRevision { following = true; self.followRevision = followRevision }
        let previousOrigin = contentView.bounds.origin
        if let storage = transcript.textStorage, !storage.isEqual(to: text) {
            let selection = transcript.selectedRange()
            storage.setAttributedString(text)
            transcript.setSelectedRange(NSRange(location: min(selection.location, text.length),
                length: min(selection.length, max(0, text.length - selection.location))))
            measureDocument()
        }
        if following { scrollToLatest() }
        else { contentView.scroll(to: previousOrigin); reflectScrolledClipView(contentView) }
    }

    override func layout() {
        super.layout()
        guard abs(contentSize.width - measuredWidth) > 0.5 else { return }
        measureDocument()
        if following { scrollToLatest() }
    }

    private func measureDocument() {
        guard !measuring, let container = transcript.textContainer, let manager = transcript.layoutManager else { return }
        measuring = true
        defer { measuring = false }
        measuredWidth = max(1, contentSize.width)
        transcript.setFrameSize(NSSize(width: measuredWidth, height: transcript.frame.height))
        container.containerSize = NSSize(width: measuredWidth, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let height = max(contentSize.height, ceil(manager.usedRect(for: container).height) + 8)
        transcript.setFrameSize(NSSize(width: measuredWidth, height: height))
    }

    private func scrollToLatest() {
        contentView.scroll(to: NSPoint(x: 0, y: max(0, transcript.frame.height - contentSize.height)))
        reflectScrolledClipView(contentView)
    }
}
