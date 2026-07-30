import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct AudioInputDevice: Equatable {
    let id: AudioDeviceID
    let name: String
}

struct AudioInputRouteTracker {
    private(set) var preparedDeviceID: AudioDeviceID?

    func requiresEngineReplacement(for deviceID: AudioDeviceID) -> Bool {
        guard let preparedDeviceID else { return false }
        return preparedDeviceID != deviceID
    }

    mutating func markPrepared(for deviceID: AudioDeviceID) {
        preparedDeviceID = deviceID
    }

    mutating func invalidate() {
        preparedDeviceID = nil
    }
}

enum SystemAudioInput {
    static func currentDevice() throws -> AudioInputDevice {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr else {
            throw audioError(
                "Luxit could not read the current system microphone.",
                status: status
            )
        }
        guard deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            throw audioError("No system microphone is selected.")
        }

        return AudioInputDevice(
            id: deviceID,
            name: deviceName(for: deviceID) ?? "System microphone"
        )
    }

    static func bind(
        _ input: AVAudioInputNode,
        to device: AudioInputDevice
    ) throws {
        guard let audioUnit = input.audioUnit else {
            throw audioError("Luxit could not open the system microphone.")
        }

        var deviceID = device.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw audioError(
                "Luxit could not use \(device.name).",
                status: status
            )
        }
    }

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &name
        )
        guard status == noErr, let name else { return nil }
        return name.takeUnretainedValue() as String
    }

    private static func audioError(
        _ description: String,
        status: OSStatus? = nil
    ) -> NSError {
        var userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: description
        ]
        if let status {
            userInfo[NSUnderlyingErrorKey] = NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status)
            )
        }
        return NSError(domain: "Luxit.AudioInput", code: 1, userInfo: userInfo)
    }
}
