import ApplicationServices

enum CapsLockEventDisposition: Equatable {
    case toggleAndConsume
    case consume
    case passThrough
}

/// Pure, deterministic classification for the global keyboard event tap.
///
/// Caps Lock is a status key on macOS. Apple delivers its physical state
/// changes as `flagsChanged`, not as an ordinary key-down/key-up pair. The
/// classifier intentionally has no clocks, debounce windows, modifier-state
/// latches, polling, or LED synchronization.
struct CapsLockEventClassifier {
    static let capsLockKeyCode: Int64 = 57
    static let remappedCapsLockKeyCode: Int64 = 80 // F19

    static func classify(
        type: CGEventType,
        keyCode: Int64
    ) -> CapsLockEventDisposition {
        if keyCode == remappedCapsLockKeyCode {
            return type == .keyDown ? .toggleAndConsume : .consume
        }
        if keyCode == capsLockKeyCode {
            return type == .flagsChanged ? .toggleAndConsume : .consume
        }
        return .passThrough
    }
}
