import AppKit

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main enum RecordingPresenceTests {
    static func main() {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = item.button!
        let existingPanels = Set(NSApp.windows.filter { $0 is NSPanel }.map(ObjectIdentifier.init))
        let length = item.length
        let controller = RecordingPresenceController(item: item)
        let dot = button.subviews.first { $0.identifier?.rawValue == "LuxitRecordingDot" }!
        for state: RecordingPresence in [.idle, .starting, .recording, .paused, .recording, .finishing, .processing, .idle] {
            controller.update(state, defaultSymbol: "mic.circle.fill", detail: "State: \(state)")
            expect(dot.isHidden == (state != .recording), "Only active capture displays the recording dot")
            expect(button.image != nil && button.image?.isTemplate == true,
                "The icon remains legible in light and dark menu bars")
            expect(item.length == length && button.title.isEmpty,
                "Recording does not expand the menu item or add status text")
            expect(button.toolTip == "Luxit — State: \(state)", "Each state has a readable tooltip")
        }
        let pausedSymbol = RecordingPresence.paused.symbol
        expect(pausedSymbol != RecordingPresence.recording.symbol && pausedSymbol != nil,
            "Pausing changes the icon without depending on color")
        item.isVisible = false
        controller.update(.recording, defaultSymbol: "mic.circle.fill", detail: "Recording")
        expect(!item.isVisible, "Hidden items stay in the user's chosen menu-bar configuration")
        expect(Set(NSApp.windows.filter { $0 is NSPanel }.map(ObjectIdentifier.init)) == existingPanels,
            "Recording never creates an overlay, even when the menu item is hidden")
        expect(dot.hitTest(.zero) == nil, "The recording mark cannot intercept clicks on Luxit's menu")
        print("RecordingPresenceTests passed (icon-only states, pause, compact width, no hidden-item overlay)")
    }
}
