import AVFoundation
import CoreAudio

/// マイクの指向性を制御して周囲のノイズを低減。
/// macOS のビルトインマイクは複数のカプセルを持ち、
/// Core Audio API で指向性パターン（前方集中）を設定できる。
/// iPhoneは AVAudioSession.setPreferredInputOrientation で制御。
enum MicrophoneConfig {

    /// デフォルト入力デバイスの指向性を前方（画面側）に設定。
    /// MacBook の内蔵マイクで効果大。外部マイクの場合は何もしない。
    static func setFrontFacing() {
        #if os(macOS)
        guard let deviceID = defaultInputDevice() else { return }

        // データソース一覧を取得
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSources,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return }

        let count = Int(size) / MemoryLayout<UInt32>.size
        var sources = [UInt32](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sources) == noErr else { return }

        // 指向性パターンを取得して設定 (可能なら)
        var patternAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSourceNameForIDCFString,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        // macOS ではビルトインマイクの場合、VoiceProcessingIO 経由で
        // 自動的にビームフォーミングが適用される。
        // ここでは明示的にフロントマイクを優先選択する。
        for source in sources {
            var sourceID = source
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            var name: Unmanaged<CFString>?
            patternAddress.mSelector = kAudioDevicePropertyDataSourceNameForIDCFString

            if AudioObjectGetPropertyData(deviceID, &patternAddress, UInt32(MemoryLayout<UInt32>.size), &sourceID, &nameSize, &name) == noErr,
               let cfName = name?.takeRetainedValue() as String? {
                let lower = cfName.lowercased()
                // "front" / "internal" / "built-in" を優先
                if lower.contains("front") || lower.contains("内蔵") {
                    var selectedSource = source
                    var setAddress = AudioObjectPropertyAddress(
                        mSelector: kAudioDevicePropertyDataSource,
                        mScope: kAudioObjectPropertyScopeInput,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    AudioObjectSetPropertyData(deviceID, &setAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &selectedSource)
                    klog("MicrophoneConfig: selected front-facing source '\(cfName)'")
                    return
                }
            }
        }
        klog("MicrophoneConfig: no front-facing source found, using default")
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
