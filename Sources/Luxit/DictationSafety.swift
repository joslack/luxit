import Foundation

/// Why a Caps Lock dictation ended without a second Caps Lock press.
///
/// A dictation that nobody is attending must not keep the microphone open:
/// a missed or phantom toggle once left one recording for four hours. Every
/// automatic stop still transcribes what was captured into history, but it
/// never pastes, because the original cursor may no longer be the target.
enum DictationAutoStop: Equatable {
    case silence
    case maximumDuration
    case sleep
    case screenLocked

    /// No voice on any input channel for this long ends the dictation.
    static let silenceLimit: TimeInterval = 3 * 60
    /// The longest attended dictation observed was about 22 minutes.
    static let durationLimit: TimeInterval = 30 * 60

    static func evaluate(elapsed: TimeInterval, trailingSilence: TimeInterval) -> DictationAutoStop? {
        if elapsed >= durationLimit { return .maximumDuration }
        if trailingSilence >= silenceLimit { return .silence }
        return nil
    }

    var logName: String {
        switch self {
        case .silence: "silence"
        case .maximumDuration: "maximum-duration"
        case .sleep: "sleep"
        case .screenLocked: "screen-locked"
        }
    }

    var statusMessage: String {
        switch self {
        case .silence: "Stopped after 3 minutes of silence — saved to history"
        case .maximumDuration: "Stopped at 30 minutes — saved to history"
        case .sleep: "Stopped for sleep — saved to history"
        case .screenLocked: "Stopped when the screen locked — saved to history"
        }
    }
}
