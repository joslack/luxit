import CoreAudio
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum AudioInputDeviceTests {
    static func main() {
        var tracker = AudioInputRouteTracker()
        expect(
            !tracker.requiresEngineReplacement(for: AudioDeviceID(41)),
            "an unprepared engine should be usable for the first route"
        )

        tracker.markPrepared(for: AudioDeviceID(41))
        expect(
            !tracker.requiresEngineReplacement(for: AudioDeviceID(41)),
            "the warm engine should remain while the input is unchanged"
        )
        expect(
            tracker.requiresEngineReplacement(for: AudioDeviceID(99)),
            "the engine should be replaced after the default input changes"
        )

        tracker.invalidate()
        expect(
            tracker.preparedDeviceID == nil,
            "invalidating a route should clear the prepared device"
        )

        print("Audio input route tests passed")
    }
}
