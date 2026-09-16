import AppKit

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main enum RecordingPresenceTests {
    static func main() {
        let bar = CGRect(x: 860, y: 944, width: 652, height: 38)
        let button = CGRect(x: 1100, y: 950, width: 24, height: 24)
        expect(RecordingPresenceLayout.isReachable(frame: button, visible: true, occluded: false, menuBarRegions: [bar]),
            "A visible icon does not create a duplicate badge")
        expect(!RecordingPresenceLayout.isReachable(frame: button, visible: true, occluded: true, menuBarRegions: [bar]),
            "Overflow occlusion triggers the fallback even when isVisible remains true")
        expect(!RecordingPresenceLayout.isReachable(frame: button.offsetBy(dx: -350, dy: 0), visible: true,
            occluded: false, menuBarRegions: [bar]), "An icon behind the camera housing is not reachable")
        expect(!RecordingPresenceLayout.isReachable(frame: button, visible: false, occluded: false, menuBarRegions: [bar]),
            "A hidden menu bar still provides access through the badge")
        expect(!RecordingPresenceLayout.isReachable(frame: .zero, visible: true, occluded: false, menuBarRegions: [.zero]),
            "An unpositioned status item cannot hide the fallback")
        let externalBar = CGRect(x: -1920, y: 1056, width: 1920, height: 24)
        expect(RecordingPresenceLayout.isReachable(frame: CGRect(x: -100, y: 1056, width: 24, height: 24),
            visible: true, occluded: false, menuBarRegions: [bar, externalBar]), "Secondary displays use their own coordinate space")
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let badge = RecordingPresenceLayout.badgeFrame(screen: screen, visibleFrame: screen, safeTop: 38, width: 144)
        expect(badge.maxY <= 944 && badge.midX == screen.midX && badge.height == 26,
            "The quiet fallback remains below the camera housing even with an auto-hidden menu bar")
        let narrow = RecordingPresenceLayout.badgeFrame(screen: CGRect(x: -100, y: 0, width: 100, height: 500),
            visibleFrame: CGRect(x: -100, y: 0, width: 100, height: 476), safeTop: 0, width: 144)
        expect(narrow.minX >= -100 && narrow.maxX <= 0 && narrow.maxY < 476,
            "The badge stays on small or offset displays")
        expect(RecordingPresence.paused.title != RecordingPresence.recording.title &&
            RecordingPresence.paused.symbol != RecordingPresence.recording.symbol,
            "Paused recording is distinct without relying on color")
        expect(RecordingPresence.processing.title == "Luxit · Transcribing" && RecordingPresence.idle.symbol == nil,
            "Final processing cannot be mistaken for an active microphone")
        print("RecordingPresenceTests passed (overflow, notch, hidden menu bar, multiple displays, quiet states)")
    }
}
