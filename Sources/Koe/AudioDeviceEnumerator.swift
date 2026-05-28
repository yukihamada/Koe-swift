import CoreAudio
import Foundation

/// 入力デバイスの列挙とデフォルト入力デバイスの切り替えを行うユーティリティ。
/// AVAudioRecorder はデバイス指定 API を持たないため、録音中だけ
/// kAudioHardwarePropertyDefaultInputDevice を上書きする戦略を採る。
enum AudioDeviceEnumerator {

    struct InputDevice: Hashable {
        let uid: String
        let name: String
        let id: AudioObjectID
    }

    /// 接続中の入力デバイス一覧を返す（入力ストリームを持つものだけ）
    static func listInputDevices() -> [InputDevice] {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }

        var result: [InputDevice] = []
        for devID in ids where hasInputStreams(devID) {
            guard let uid = stringProperty(devID, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(devID, kAudioDevicePropertyDeviceNameCFString) else { continue }
            result.append(InputDevice(uid: uid, name: name, id: devID))
        }
        return result
    }

    /// 指定 UID のデバイス AudioObjectID を解決
    static func deviceID(forUID uid: String) -> AudioObjectID? {
        guard !uid.isEmpty else { return nil }
        return listInputDevices().first(where: { $0.uid == uid })?.id
    }

    /// 現在のデフォルト入力デバイス ID
    static func defaultInputDeviceID() -> AudioObjectID? {
        var devID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID) == noErr,
              devID != kAudioObjectUnknown else { return nil }
        return devID
    }

    /// デフォルト入力デバイスを書き換える
    @discardableResult
    static func setDefaultInputDevice(_ devID: AudioObjectID) -> Bool {
        var id = devID
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &id
        )
        return status == noErr
    }

    /// デバイスの追加・削除を監視（コールバックはメインスレッドで発火）
    static func observeDeviceChanges(_ callback: @escaping () -> Void) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main
        ) { _, _ in callback() }
    }

    // MARK: - Private

    private static func hasInputStreams(_ devID: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(devID, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, bufferList) == noErr else { return false }
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        for buf in abl where buf.mNumberChannels > 0 { return true }
        return false
    }

    private static func stringProperty(_ devID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr in
            AudioObjectGetPropertyData(devID, &addr, 0, nil, &size, UnsafeMutableRawPointer(ptr))
        }
        guard status == noErr else { return nil }
        return cfStr as String
    }

}
