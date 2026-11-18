// Used by scripts/capture-sensor-logs.sh. Prints a line whenever a camera or microphone device's "running somewhere" state changes.
import CoreAudio
import CoreMediaIO
import Foundation

func stamp() -> String {
    ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
}

func cmioDevices() -> [CMIOObjectID] {
    var addr = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == 0 else { return [] }
    var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &ids) == 0 else { return [] }
    return ids
}

func cmioString(_ id: CMIOObjectID, _ sel: Int) -> String {
    var addr = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(sel), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var value: Unmanaged<CFString>?
    var used: UInt32 = 0
    let status = CMIOObjectGetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &value)
    return status == 0 ? (value?.takeRetainedValue() as String? ?? "?") : "err\(status)"
}

func cmioRunning(_ id: CMIOObjectID) -> String {
    var addr = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
    var value: UInt32 = 0
    var used: UInt32 = 0
    let status = CMIOObjectGetPropertyData(id, &addr, 0, nil, 4, &used, &value)
    return status == 0 ? (value != 0 ? "on" : "off") : "err\(status)"
}

func audioInputDevices() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.filter { id in
        var streams = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var streamsSize: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamsSize) == noErr && streamsSize > 0
    }
}

func audioName(_ id: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? (value?.takeRetainedValue() as String? ?? "?") : "?"
}

func audioRunning(_ id: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size: UInt32 = 4
    let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
    return status == noErr ? (value != 0 ? "on" : "off") : "err\(status)"
}

// Without this, CoreMediaIO hides screen-capture and Continuity Camera ("DAL") devices.
var allow: UInt32 = 1
var allowAddr = CMIOObjectPropertyAddress(
    mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
    mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
_ = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &allowAddr, 0, nil, 4, &allow)
setvbuf(stdout, nil, _IOLBF, 0)

var last: [String: String] = [:]
print("\(stamp()) probe started pid=\(getpid())")
while true {
    var now: [String: String] = [:]
    for id in cmioDevices() {
        now["camera \(id) \(cmioString(id, kCMIOObjectPropertyName)) [\(cmioString(id, kCMIODevicePropertyModelUID))]"] = cmioRunning(id)
    }
    for id in audioInputDevices() { now["mic \(id) \(audioName(id))"] = audioRunning(id) }
    for (key, value) in now where last[key] != value { print("\(stamp()) \(key) = \(value)") }
    for key in last.keys where now[key] == nil { print("\(stamp()) \(key) removed") }
    last = now
    Thread.sleep(forTimeInterval: 0.25)
}
