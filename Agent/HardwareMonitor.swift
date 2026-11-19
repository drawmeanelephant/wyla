import CoreAudio
import CoreMediaIO
import Synchronization
import WylaCore

/// Watches whether each camera and microphone device is running, for any process. Reading this
/// state needs no camera or microphone permission (see docs/SPEC.md, "Camera and microphone hardware").
final class HardwareMonitor: Sendable {
    private let queue = DispatchQueue(label: "io.github.drawmeanelephant.wyla.hardware")
    private let onChange: @Sendable () -> Void
    private let watchedCameras = Mutex<Set<CMIOObjectID>>([])
    private let watchedMicrophones = Mutex<Set<AudioObjectID>>([])

    /// `onChange` runs when a device is added or removed, or starts or stops running. Call `scan()` then.
    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        // Without this, CoreMediaIO hides Continuity Camera and screen-capture devices.
        var allow: UInt32 = 1
        var address = cmioAddress(kCMIOHardwarePropertyAllowScreenCaptureDevices)
        _ = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, 4, &allow)
        var devices = cmioAddress(kCMIOHardwarePropertyDevices)
        _ = CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &devices, queue) { _, _ in onChange() }
        var audioDevices = audioAddress(kAudioHardwarePropertyDevices)
        _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &audioDevices, queue) { _, _ in onChange() }
    }

    /// The names of the running devices of each sensor. Starts watching devices added since the last scan.
    func scan() -> [Sensor: Set<String>] {
        [.camera: runningCameras(), .microphone: runningMicrophones()]
    }

    private func runningCameras() -> Set<String> {
        var running = Set<String>()
        for device in cmioObjects(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices) {
            var address = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            if watchedCameras.withLock({ $0.insert(device).inserted }) {
                let onChange = onChange
                _ = CMIOObjectAddPropertyListenerBlock(device, &address, queue) { _, _ in onChange() }
            }
            var value: UInt32 = 0
            var used: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &address, 0, nil, 4, &used, &value) == 0, value != 0 {
                running.insert(cmioName(device) ?? "Camera \(device)")
            }
        }
        return running
    }

    /// Input-only devices. A device that also has outputs, such as a headset, runs while it plays
    /// sound, so its running state says nothing about the microphone.
    private func runningMicrophones() -> Set<String> {
        var running = Set<String>()
        for device in audioObjects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        where hasStreams(device, kAudioObjectPropertyScopeInput) && !hasStreams(device, kAudioObjectPropertyScopeOutput) {
            var address = audioAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
            if watchedMicrophones.withLock({ $0.insert(device).inserted }) {
                let onChange = onChange
                _ = AudioObjectAddPropertyListenerBlock(device, &address, queue) { _, _ in onChange() }
            }
            var value: UInt32 = 0
            var size: UInt32 = 4
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, value != 0 {
                running.insert(audioName(device) ?? "Microphone \(device)")
            }
        }
        return running
    }
}

private func cmioAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(selector), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
}

private func cmioObjects(_ object: CMIOObjectID, _ selector: Int) -> [CMIOObjectID] {
    var address = cmioAddress(selector)
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == 0 else { return [] }
    var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &ids) == 0 else { return [] }
    return ids
}

private func cmioName(_ device: CMIOObjectID) -> String? {
    var address = cmioAddress(kCMIOObjectPropertyName)
    var name: Unmanaged<CFString>?
    var used: UInt32 = 0
    let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, &name) == 0 else { return nil }
    return name?.takeRetainedValue() as String?
}

private func audioAddress(_ selector: UInt32, scope: UInt32 = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func audioObjects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
    var address = audioAddress(selector)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

private func hasStreams(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
    var address = audioAddress(kAudioDevicePropertyStreams, scope: scope)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
}

private func audioName(_ device: AudioObjectID) -> String? {
    var address = audioAddress(kAudioObjectPropertyName)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
    return name?.takeRetainedValue() as String?
}
