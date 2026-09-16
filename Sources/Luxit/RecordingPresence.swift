import AppKit

enum RecordingPresence: Equatable {
    case idle, starting, recording, paused, finishing, processing

    var title: String {
        switch self {
        case .idle: return "Luxit"
        case .starting: return "Luxit · Starting"
        case .recording: return "Luxit · Recording"
        case .paused: return "Luxit · Paused"
        case .finishing: return "Luxit · Finishing"
        case .processing: return "Luxit · Transcribing"
        }
    }

    var symbol: String? {
        switch self {
        case .idle: return nil
        case .starting, .finishing, .processing: return "ellipsis.circle.fill"
        case .recording: return "mic.circle.fill"
        case .paused: return "pause.circle.fill"
        }
    }

    var color: NSColor {
        switch self {
        case .recording: return .systemRed
        case .paused, .starting, .finishing: return .systemOrange
        case .processing: return .secondaryLabelColor
        case .idle: return .labelColor
        }
    }
}

enum RecordingPresenceLayout {
    // isVisible alone also returns true for items hidden by menu-bar overflow.
    // Check window occlusion and the actual button rectangle, including the
    // camera exclusion area. No private menu-bar priority APIs or saved-position
    // overrides: the user's placement remains theirs.
    static func isReachable(frame: CGRect, visible: Bool, occluded: Bool,
                            menuBarRegions: [CGRect]) -> Bool {
        visible && !occluded && frame.width > 0 && frame.height > 0 &&
            menuBarRegions.contains { $0.insetBy(dx: -1, dy: -1).contains(frame) }
    }

    static func badgeFrame(screen: CGRect, visibleFrame: CGRect, safeTop: CGFloat, width: CGFloat) -> CGRect {
        let top = min(visibleFrame.maxY, screen.maxY - safeTop)
        let width = min(width, max(0, screen.width - 16))
        return CGRect(x: screen.midX - width / 2, y: top - 28,
                      width: width, height: 26)
    }
}

private final class RecordingDot: NSView {
    var color: NSColor = .systemRed { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}

/// A quiet status item plus a small escape hatch when macOS hides that item.
/// A low-frequency visibility check does no audio work or animated rendering.
final class RecordingPresenceController: NSObject {
    private let item: NSStatusItem
    private let dot = RecordingDot(frame: .zero)
    private let panel: NSPanel
    private let badge = NSButton(title: "Luxit", target: nil, action: nil)
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var state: RecordingPresence = .idle
    private var lastSymbol: String?
    var transcriptIsVisible: () -> Bool = { false }
    var onOpen: (() -> Void)?

    init(item: NSStatusItem) {
        self.item = item
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()
        item.behavior = []
        item.isVisible = true
        if let button = item.button {
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
        panel.title = "Luxit Recording Status"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        let glass = NSVisualEffectView(frame: .zero)
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 13
        glass.layer?.masksToBounds = true
        panel.contentView = glass
        badge.isBordered = false
        badge.font = .systemFont(ofSize: 11, weight: .medium)
        badge.imagePosition = .imageLeading
        badge.imageScaling = .scaleProportionallyDown
        badge.target = self
        badge.action = #selector(openTranscript)
        badge.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 10),
            badge.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -10),
            badge.topAnchor.constraint(equalTo: glass.topAnchor),
            badge.bottomAnchor.constraint(equalTo: glass.bottomAnchor)
        ])
        for name in [NSApplication.didChangeScreenParametersNotification, NSWindow.didChangeOcclusionStateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Defer until AppKit has settled its window/menu layout.
                DispatchQueue.main.async { self?.refreshVisibility() }
            })
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshVisibility() }
        timer.tolerance = 0.25
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit {
        timer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func update(_ state: RecordingPresence, defaultSymbol: String, detail: String) {
        let changed = self.state != state
        self.state = state
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
        if changed || badge.image == nil {
            badge.title = state.title
            badge.attributedTitle = NSAttributedString(string: state.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9)
            ])
            badge.image = NSImage(systemSymbolName: state == .recording ? "record.circle.fill" : symbol,
                                  accessibilityDescription: nil)
            badge.contentTintColor = state.color
            badge.toolTip = "Open Luxit transcripts and recording controls"
            badge.setAccessibilityLabel(state.title + ". Open recording controls.")
        }
        refreshVisibility()
    }

    func refreshVisibility() {
        guard let screen = NSScreen.screens.first else { panel.orderOut(nil); return }
        let regions = NSScreen.screens.flatMap { screen -> [CGRect] in
            let safeAreas = [screen.auxiliaryTopLeftArea, screen.auxiliaryTopRightArea]
                .compactMap { $0 }.filter { !$0.isEmpty }
            if !safeAreas.isEmpty { return safeAreas }
            let height = max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY)
            return [CGRect(x: screen.frame.minX, y: screen.frame.maxY - height,
                           width: screen.frame.width, height: height)]
        }
        let button = item.button
        let window = button?.window
        let frame = button.map { window?.convertToScreen($0.convert($0.bounds, to: nil)) ?? .zero } ?? .zero
        let reachable = RecordingPresenceLayout.isReachable(frame: frame,
            visible: item.isVisible && window?.isVisible == true,
            occluded: window?.occlusionState.contains(.visible) != true, menuBarRegions: regions)
        guard !reachable, !transcriptIsVisible() else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        let frameForBadge = RecordingPresenceLayout.badgeFrame(screen: screen.frame,
            visibleFrame: screen.visibleFrame, safeTop: screen.safeAreaInsets.top,
            width: max(76, badge.intrinsicContentSize.width + 20))
        if panel.frame != frameForBadge { panel.setFrame(frameForBadge, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    @objc private func openTranscript() {
        // Opening is idempotent so the transcript's outside-click dismissal
        // cannot toggle it closed again on the badge's mouse-up.
        onOpen?()
        refreshVisibility()
    }
}
