import Foundation
import CoreAudio

/// Output volume, mute and output device through CoreAudio (public HAL API).
enum Audio {
    struct Device: Identifiable, Hashable { let id: AudioDeviceID; let name: String }

    private static func addr(_ sel: AudioObjectPropertySelector,
                             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: element)
    }

    static var defaultOutput: AudioDeviceID {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
        return id
    }

    static func setDefaultOutput(_ id: AudioDeviceID) {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        var dev = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
        // Keep system sounds on the same device, as Windows does.
        var b = addr(kAudioHardwarePropertyDefaultSystemOutputDevice)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &b, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
    }

    static func outputDevices() -> [Device] {
        var a = addr(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
        return ids.compactMap { id in
            var sa = addr(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
            var ssize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &ssize)
            guard ssize > 0 else { return nil }
            return Device(id: id, name: name(id))
        }
    }

    static func name(_ id: AudioDeviceID) -> String {
        var a = addr(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &name) == noErr, let n = name else { return "Unknown" }
        return n.takeRetainedValue() as String
    }

    /// Main element if the device has one, else left/right channels (e.g. some USB and HDMI devices).
    private static func volumeElements(_ id: AudioDeviceID) -> [AudioObjectPropertyElement] {
        var main = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(id, &main) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter { ch in
            var a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, ch)
            return AudioObjectHasProperty(id, &a)
        }
    }

    static func canSetVolume(_ id: AudioDeviceID = defaultOutput) -> Bool {
        guard let el = volumeElements(id).first else { return false }
        var a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, el)
        var settable: DarwinBoolean = false
        AudioObjectIsPropertySettable(id, &a, &settable)
        return settable.boolValue
    }

    static func volume(_ id: AudioDeviceID = defaultOutput) -> Float {
        let els = volumeElements(id)
        guard !els.isEmpty else { return 1 }
        var total: Float = 0
        for el in els {
            var a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, el)
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v)
            total += v
        }
        return total / Float(els.count)
    }

    static func setVolume(_ v: Float, _ id: AudioDeviceID = defaultOutput) {
        var val = Float32(min(max(v, 0), 1))
        for el in volumeElements(id) {
            var a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, el)
            AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &val)
        }
        if val > 0 && isMuted(id) { setMuted(false, id) }
    }

    static func isMuted(_ id: AudioDeviceID = defaultOutput) -> Bool {
        var a = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(id, &a) else { return false }
        var m: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, &m)
        return m != 0
    }

    static func setMuted(_ muted: Bool, _ id: AudioDeviceID = defaultOutput) {
        var a = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var m: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
    }

    /// Calls `handler` on the main queue when the default device, its volume or mute changes.
    private static var deviceListeners: [AudioDeviceID] = []
    static func observe(_ handler: @escaping @Sendable () -> Void) {
        var def = addr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &def, .main) { _, _ in
            listenToDevice(defaultOutput, handler)
            handler()
        }
        var list = addr(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &list, .main) { _, _ in handler() }
        listenToDevice(defaultOutput, handler)
    }

    private static func listenToDevice(_ id: AudioDeviceID, _ handler: @escaping @Sendable () -> Void) {
        guard !deviceListeners.contains(id) else { return }
        deviceListeners.append(id)
        for el in volumeElements(id) {
            var a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, el)
            AudioObjectAddPropertyListenerBlock(id, &a, .main) { _, _ in handler() }
        }
        var m = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        AudioObjectAddPropertyListenerBlock(id, &m, .main) { _, _ in handler() }
    }
}
