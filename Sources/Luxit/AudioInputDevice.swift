import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

enum AudioInputTransport: Equatable {
    case builtIn
    case bluetooth
    case other
}

struct AudioInputDevice: Equatable {
    let id: AudioDeviceID
    let name: String
    let transport: AudioInputTransport
}

enum AudioInputPolicy {
    static func preferredDevice(
        defaultDevice: AudioInputDevice,
        availableDevices: [AudioInputDevice]
    ) -> AudioInputDevice {
        guard defaultDevice.transport == .bluetooth else {
            return defaultDevice
        }
        return availableDevices.first {
            $0.transport == .builtIn
        } ?? defaultDevice
    }
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
    static func preferredDevice() throws -> AudioInputDevice {
        let defaultDevice = try currentDevice()
        guard defaultDevice.transport == .bluetooth else {
            return defaultDevice
        }
        return AudioInputPolicy.preferredDevice(
            defaultDevice: defaultDevice,
            availableDevices: inputDevices()
        )
    }

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
            name: deviceName(for: deviceID) ?? "System microphone",
            transport: deviceTransport(for: deviceID)
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

    private static func deviceTransport(
        for deviceID: AudioDeviceID
    ) -> AudioInputTransport {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &transport
        )
        guard status == noErr else { return .other }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeBluetooth:
            return .bluetooth
        default:
            return .other
        }
    }

    private static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var deviceIDs = [AudioDeviceID](
            repeating: AudioDeviceID(kAudioObjectUnknown),
            count: count
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceIDs
        ) == noErr else {
            return []
        }

        return deviceIDs.compactMap { deviceID in
            guard supportsInput(deviceID) else { return nil }
            return AudioInputDevice(
                id: deviceID,
                name: deviceName(for: deviceID) ?? "Microphone",
                transport: deviceTransport(for: deviceID)
            )
        }
    }

    private static func supportsInput(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &size
        ) == noErr && size >= MemoryLayout<AudioStreamID>.size
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
