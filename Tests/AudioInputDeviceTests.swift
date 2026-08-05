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
        let builtIn = AudioInputDevice(
            id: AudioDeviceID(41),
            name: "MacBook Pro Microphone",
            transport: .builtIn
        )
        let airPods = AudioInputDevice(
            id: AudioDeviceID(99),
            name: "AirPods Pro",
            transport: .bluetooth
        )
        let usb = AudioInputDevice(
            id: AudioDeviceID(120),
            name: "USB Microphone",
            transport: .other
        )
        expect(
            AudioInputPolicy.preferredDevice(
                defaultDevice: airPods,
                availableDevices: [airPods, builtIn]
            ) == builtIn,
            "a Bluetooth default should yield to the built-in microphone"
        )
        expect(
            AudioInputPolicy.preferredDevice(
                defaultDevice: builtIn,
                availableDevices: [airPods, builtIn]
            ) == builtIn,
            "the built-in default should remain selected"
        )
        expect(
            AudioInputPolicy.preferredDevice(
                defaultDevice: usb,
                availableDevices: [usb, builtIn]
            ) == usb,
            "an explicitly selected non-Bluetooth microphone should be respected"
        )
        expect(
            AudioInputPolicy.preferredDevice(
                defaultDevice: airPods,
                availableDevices: [airPods]
            ) == airPods,
            "Bluetooth remains a fallback when no built-in input is available"
        )

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
