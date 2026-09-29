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
///
/// When Caps Lock is remapped to F19 it becomes an ordinary key, so holding it
/// produces autorepeat key-downs (after ~225 ms, then every ~30 ms with fast
/// key-repeat settings). Only the initial key-down is a press; treating each
/// repeat as a toggle turned one long press into dozens of start/stop cycles
/// that could end in a silent, unattended recording.
struct CapsLockEventClassifier {
    static let capsLockKeyCode: Int64 = 57
    static let remappedCapsLockKeyCode: Int64 = 80 // F19

    static func classify(
        type: CGEventType,
        keyCode: Int64,
        isAutorepeat: Bool = false
    ) -> CapsLockEventDisposition {
        if keyCode == remappedCapsLockKeyCode {
            return type == .keyDown && !isAutorepeat ? .toggleAndConsume : .consume
        }
        if keyCode == capsLockKeyCode {
            return type == .flagsChanged ? .toggleAndConsume : .consume
        }
        return .passThrough
    }
}
