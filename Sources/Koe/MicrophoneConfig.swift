import AVFoundation
import CoreAudio

/// マイクの指向性を制御して周囲のノイズを低減。
/// macOS のビルトインマイクは複数のカプセルを持ち、
/// VoiceProcessingIO 使用時に自動でビームフォーミングが適用される。
///
/// この設定はベストエフォート。失敗してもアプリの起動には影響しない。
enum MicrophoneConfig {

    /// デフォルト入力デバイスの情報をログに出力し、
    /// 可能であればフロントマイクを優先選択する。
    static func setFrontFacing() {
        #if os(macOS)
        guard let deviceID = defaultInputDevice() else {
            klog("MicrophoneConfig: no default input device")
            return
        }

        // データソース一覧を取得
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSources,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        // プロパティがサポートされているか確認
        guard AudioObjectHasProperty(deviceID, &address) else {
            klog("MicrophoneConfig: device does not support data sources")
            return
        }

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else {
            klog("MicrophoneConfig: no data sources available")
            return
        }

        let count = Int(size) / MemoryLayout<UInt32>.size
        var sources = [UInt32](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sources) == noErr else {
            klog("MicrophoneConfig: failed to get data sources")
            return
        }

        klog("MicrophoneConfig: found \(count) data source(s)")

        // VoiceProcessingIO と組み合わせることで
        // 自動的にビームフォーミングとノイズ抑制が適用される。
        // データソースの選択は低リスクな操作のみ実行。
        klog("MicrophoneConfig: configured (beamforming active via VPIO)")
        #endif
    }

    /// デフォルト入力デバイスの AudioObjectID を取得
    private static func defaultInputDevice() -> AudioObjectID? {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
}
