import Foundation
import IOKit.hid

/// Observes keyboard services, not keystrokes. Independent devices prevent the
/// manager from opening keyboards or scheduling their input-report queues.
final class KeyboardDeviceMonitor {
    var onChange: (() -> Void)?
    private var manager: IOHIDManager?

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOHIDManagerOptions.independentDevices.rawValue
        )
        self.manager = manager
        let context = Unmanaged.passUnretained(self).toOpaque()
        let changed: IOHIDDeviceCallback = { context, result, _, _ in
            guard result == kIOReturnSuccess, let context else { return }
            let owner = Unmanaged<KeyboardDeviceMonitor>.fromOpaque(context).takeUnretainedValue()
            owner.onChange?()
        }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, changed, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, changed, context)
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard
        ] as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        self.manager = nil
    }

    deinit { stop() }
}
