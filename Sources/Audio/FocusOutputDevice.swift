import CoreAudio
import Foundation

/// A sound output device as Core Audio names it. The UID stays the same when the device comes
/// back (AirPods reconnecting); the object ID may not.
struct FocusOutputDevice: Equatable {
    let id: AudioObjectID
    let uid: String
}

/// What the engine asks Core Audio at a device change. The checks swap in their own answers.
struct FocusOutputProbe {
    var current: () -> FocusOutputDevice?
    var isConnected: (FocusOutputDevice) -> Bool

    static let system = FocusOutputProbe(current: { defaultOutput() }, isConnected: { connected($0) })

    /// The Mac's current default output device.
    static func defaultOutput() -> FocusOutputDevice? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != AudioObjectID(kAudioObjectUnknown), let uid = uid(of: id) else { return nil }
        return FocusOutputDevice(id: id, uid: uid)
    }

    static func uid(of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let uid = value?.takeRetainedValue() else { return nil }
        return uid as String
    }

    /// False once the device has been unplugged, switched off or taken by another computer or phone.
    static func connected(_ device: FocusOutputDevice) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return false }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return false }
        let listed = ids.contains { uid(of: $0) == device.uid }
        guard listed else { return false }
        var aliveAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                                                      mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 0
        var aliveSize = UInt32(MemoryLayout<UInt32>.size)
        let target = ids.first { uid(of: $0) == device.uid } ?? device.id
        guard AudioObjectGetPropertyData(target, &aliveAddress, 0, nil, &aliveSize, &alive) == noErr else { return false }
        return alive != 0
    }
}
