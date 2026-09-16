import AppKit

enum RecordingPresence: Equatable {
    case idle, starting, recording, paused, finishing, processing

    var symbol: String? {
        switch self {
        case .idle: return nil
        case .starting, .finishing, .processing: return "ellipsis.circle.fill"
        case .recording: return "mic.circle.fill"
        case .paused: return "pause.circle.fill"
        }
    }
}

private final class RecordingDot: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}

/// Recording state belongs to the existing menu item. Keep it static and compact;
/// never add a floating status window when macOS obscures the menu bar.
final class RecordingPresenceController {
    private let item: NSStatusItem
    private let dot = RecordingDot(frame: .zero)
    private var lastSymbol: String?

    init(item: NSStatusItem) {
        self.item = item
        item.behavior = []
        item.isVisible = true
        if let button = item.button {
            dot.identifier = NSUserInterfaceItemIdentifier("LuxitRecordingDot")
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.isHidden = true
            button.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6),
                dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
                dot.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -2)
            ])
        }
    }

    func update(_ state: RecordingPresence, defaultSymbol: String, detail: String) {
        let symbol = state.symbol ?? defaultSymbol
        if lastSymbol != symbol {
            lastSymbol = symbol
            item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Luxit")
            item.button?.image?.isTemplate = true
        }
        dot.isHidden = state != .recording
        let description = "Luxit — \(detail)"
        item.button?.toolTip = description
        item.button?.setAccessibilityLabel(description)
    }
}
