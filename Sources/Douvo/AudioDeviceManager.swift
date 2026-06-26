import AudioToolbox
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDeviceManager {
    /// All audio devices that expose at least one input channel.
    static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &ids) == noErr else {
            return []
        }

        return ids.compactMap { id in
            guard hasInputChannels(id),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = deviceName(id) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices().first { $0.uid == uid }?.id
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return false
        }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, buffer) == noErr else {
            return false
        }

        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        for audioBuffer in list where audioBuffer.mNumberChannels > 0 {
            return true
        }
        return false
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioDevicePropertyDeviceNameCFString)
            ?? stringProperty(id, kAudioObjectPropertyName)
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, pointer)
        }

        guard status == noErr, let result = value else { return nil }
        return result as String
    }
}

enum AudioDeviceStore {
    private static let key = "selectedInputDeviceUID"

    /// nil means "follow the system default input device".
    static func selectedUID() -> String? {
        UserDefaults.standard.string(forKey: key)
    }

    static func setSelectedUID(_ uid: String?) {
        if let uid {
            UserDefaults.standard.set(uid, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        AppLog.info("Selected input device uid=\(uid ?? "<system default>")")
    }
}
