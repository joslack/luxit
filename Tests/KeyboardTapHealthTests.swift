import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main
private enum KeyboardTapHealthTests {
    static func observation(
        exists: Bool = true, enabled: Bool = true, secure: Bool = false,
        age: TimeInterval = 60, hardware: TimeInterval, tap: TimeInterval?
    ) -> KeyboardTapHealth.Observation {
        KeyboardTapHealth.Observation(
            tapExists: exists, tapEnabled: enabled, secureInputActive: secure,
            tapAge: age, secondsSinceHardwareKeyDown: hardware, secondsSinceTapKeyDown: tap)
    }

    static func main() {
        typealias Health = KeyboardTapHealth
        expect(Health.evaluate(observation(exists: false, hardware: 5, tap: nil)) == .recreate(.missing),
               "a missing tap is rebuilt")
        expect(Health.evaluate(observation(enabled: false, hardware: 5, tap: 5)) == .recreate(.disabled),
               "a disabled tap is rebuilt")
        expect(Health.evaluate(observation(hardware: 5, tap: 5)) == .healthy,
               "a tap that saw the latest hardware key-down is healthy")
        expect(Health.evaluate(observation(hardware: 5, tap: 5.3)) == .healthy,
               "small clock differences are tolerated")
        expect(Health.evaluate(observation(hardware: 5, tap: 40)) == .recreate(.deaf),
               "hardware typing the tap never saw means the tap is deaf")
        expect(Health.evaluate(observation(hardware: 5, tap: nil)) == .recreate(.deaf),
               "a tap that has never seen typing after hardware typing is deaf")
        expect(Health.evaluate(observation(hardware: 0.2, tap: 40)) == .healthy,
               "a just-typed key gets time to arrive before judging")
        expect(Health.evaluate(observation(age: 3, hardware: 30, tap: nil)) == .healthy,
               "typing before the tap existed says nothing about its health")
        expect(Health.evaluate(observation(hardware: .infinity, tap: nil)) == .healthy,
               "no hardware typing at all is healthy")
        expect(Health.evaluate(observation(secure: true, hardware: 5, tap: 40)) == .secureInputBlocked,
               "Secure Event Input is reported instead of repeatedly rebuilding")
        expect(Health.evaluate(observation(enabled: false, secure: true, hardware: 5, tap: 40)) == .recreate(.disabled),
               "a disabled tap is rebuilt even during Secure Event Input")
        var inactive = observation(exists: false, hardware: 5, tap: nil)
        inactive.sessionActive = false
        expect(Health.evaluate(inactive) == .healthy, "an inactive login session is left alone")

        typealias Stop = DictationAutoStop
        expect(Stop.evaluate(elapsed: 10, trailingSilence: 2) == nil, "normal dictation continues")
        expect(Stop.evaluate(elapsed: 25 * 60, trailingSilence: 5) == nil, "long attended dictation continues")
        expect(Stop.evaluate(elapsed: 200, trailingSilence: Stop.silenceLimit) == .silence,
               "three minutes without voice ends dictation")
        expect(Stop.evaluate(elapsed: Stop.durationLimit, trailingSilence: 0) == .maximumDuration,
               "background speech cannot keep dictation open indefinitely")

        print("KeyboardTapHealthTests passed")
    }
}
