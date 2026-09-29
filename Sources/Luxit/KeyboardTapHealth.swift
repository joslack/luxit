import Foundation

/// Pure decision logic for the keyboard-tap watchdog.
///
/// An event tap can stop delivering events without any callback: macOS may
/// disable it after a slow callback, a privacy change can leave it enabled
/// but deaf, and wake/login transitions occasionally invalidate it. The
/// watchdog compares the tap's own view of key-downs against the HID system's
/// last hardware key-down; if hardware typing happened that the tap never
/// saw, the tap is rebuilt. Secure Event Input legitimately hides key-downs
/// from every tap, so it is reported rather than "repaired".
enum KeyboardTapHealth {
    struct Observation: Equatable {
        var sessionActive = true
        var tapExists: Bool
        var tapEnabled: Bool
        var secureInputActive: Bool
        /// Seconds since the tap was created.
        var tapAge: TimeInterval
        /// Seconds since the HID system last saw a hardware key-down.
        var secondsSinceHardwareKeyDown: TimeInterval
        /// Seconds since the tap last observed any key-down; nil if never.
        var secondsSinceTapKeyDown: TimeInterval?
    }

    enum Verdict: Equatable {
        case healthy
        case secureInputBlocked
        case recreate(Reason)
    }

    enum Reason: String, Equatable {
        case missing
        case disabled
        case deaf
    }

    /// Time allowed for a hardware key-down to reach the tap before its
    /// absence counts as deafness.
    static let deliveryGrace: TimeInterval = 1.0
    /// Tolerance between the HID-system clock and the tap's uptime stamps.
    static let clockSlack: TimeInterval = 0.5

    static func evaluate(_ observation: Observation) -> Verdict {
        // Another login session owns the keyboard; nothing here is broken.
        guard observation.sessionActive else { return .healthy }
        guard observation.tapExists else { return .recreate(.missing) }
        guard observation.tapEnabled else { return .recreate(.disabled) }
        if observation.secureInputActive { return .secureInputBlocked }

        let hardware = observation.secondsSinceHardwareKeyDown
        let typedSinceCreation = hardware.isFinite &&
            hardware + deliveryGrace < observation.tapAge
        guard typedSinceCreation, hardware >= deliveryGrace else { return .healthy }
        let tapSawIt = observation.secondsSinceTapKeyDown.map {
            $0 <= hardware + clockSlack
        } ?? false
        return tapSawIt ? .healthy : .recreate(.deaf)
    }
}
