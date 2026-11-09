import CoreAudio
import Foundation

/// システムの既定の入力デバイス（録音はこのデバイスから録る）。
///
/// デバイス名を読むだけならマイクを開かないので、権限も要らず
/// OS のマイク使用中表示も点かない。
public enum InputDevice {

    /// 既定の入力デバイスの表示名。入力デバイスが 1 つも無ければ nil。
    public static func defaultName() -> String? {
        guard let id = defaultDeviceID() else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func defaultDeviceID() -> AudioObjectID? {
        var address = defaultInputAddress
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    fileprivate static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }
}

/// 既定の入力デバイスの切り替え（AirPods をつないだ等）を通知する。
///
/// システム設定でデバイスを変えても AVFoundation の通知は飛ばないため、
/// CoreAudio のプロパティを直接監視する。
public final class InputDeviceObserver: @unchecked Sendable {
    private var listener: AudioObjectPropertyListenerBlock?

    /// `onChange` は登録直後に 1 回、以降は切り替わるたびにメインスレッドで呼ぶ。
    public init(onChange: @escaping @MainActor (String?) -> Void) {
        let block: AudioObjectPropertyListenerBlock = { [onChange] _, _ in
            let name = InputDevice.defaultName()
            Task { @MainActor in onChange(name) }
        }
        var address = InputDevice.defaultInputAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        // 監視できなくても表示が古くなるだけで録音には響かない。登録できたときだけ外す
        if status == noErr { listener = block }

        let initial = InputDevice.defaultName()
        Task { @MainActor in onChange(initial) }
    }

    deinit {
        guard let listener else { return }
        var address = InputDevice.defaultInputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener)
    }
}
