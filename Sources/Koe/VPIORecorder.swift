import AVFoundation
import AudioToolbox
import Accelerate

/// VoiceProcessingIO (VPIO) を使ったエコーキャンセル付きレコーダー。
/// 会議モード・スピーカー使用時に威力を発揮。
/// Apple の VPIO Audio Unit がハードウェアレベルで以下を実行:
///   - AEC (Acoustic Echo Cancellation): スピーカー出力がマイクに回り込む音を除去
///   - NS  (Noise Suppression): 環境ノイズの抑制
///   - AGC (Automatic Gain Control): マイクゲインの自動調整
///
/// 議事録モードやオンライン会議の文字起こしで、相手の声を誤認識しなくなる。
final class VPIORecorder {

    fileprivate var audioUnit: AudioComponentInstance?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false

    /// VPIO Audio Unit をセットアップ
    func prepare() -> Bool {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            klog("VPIO: AudioComponent not found")
            return false
        }
        var unit: AudioComponentInstance?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else {
            klog("VPIO: failed to create AudioUnit")
            return false
        }

        // 入力を有効化 (マイク)
        var enableInput: UInt32 = 1
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input, 1, &enableInput, UInt32(MemoryLayout<UInt32>.size))

        // 出力を無効化 (スピーカーに出さない — 録音専用)
        var disableOutput: UInt32 = 0
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output, 0, &disableOutput, UInt32(MemoryLayout<UInt32>.size))

        // フォーマット設定: 16kHz mono Float32 (Whisper最適)
        var format = AudioStreamBasicDescription(
            mSampleRate: 16000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output, 1, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        // 入力コールバック設定
        var callbackStruct = AURenderCallbackStruct(
            inputProc: vpioInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                             kAudioUnitScope_Global, 0, &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        guard AudioUnitInitialize(unit) == noErr else {
            klog("VPIO: failed to initialize")
            AudioComponentInstanceDispose(unit)
            return false
        }

        audioUnit = unit
        klog("VPIO: prepared (AEC + NS + AGC enabled)")
        return true
    }

    func start() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        guard let unit = audioUnit else { return }
        isRecording = true
        AudioOutputUnitStart(unit)
        klog("VPIO: recording started")
    }

    func stop() -> [Float] {
        guard let unit = audioUnit else { return [] }
        AudioOutputUnitStop(unit)
        isRecording = false
        lock.lock()
        let result = samples
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        klog("VPIO: recording stopped, \(result.count) samples")
        return result
    }

    func cancel() {
        guard let unit = audioUnit else { return }
        AudioOutputUnitStop(unit)
        isRecording = false
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        klog("VPIO: cancelled")
    }

    /// 現在のサンプル数からレベルを推定
    func currentLevel() -> Float {
        lock.lock()
        let count = samples.count
        guard count > 160 else { lock.unlock(); return 0 }
        let tail = Array(samples[(count - 160)...])
        lock.unlock()
        var rms: Float = 0
        vDSP_rmsqv(tail, 1, &rms, vDSP_Length(tail.count))
        return min(1.0, rms * 10) // scale RMS to 0-1 range
    }

    /// 録音中のサンプルバッファを返す（ストリーミングプレビュー用）
    func currentSamples() -> [Float]? {
        lock.lock()
        let result = samples.isEmpty ? nil : Array(samples)
        lock.unlock()
        return result
    }

    fileprivate func appendSamples(_ buffer: UnsafePointer<Float>, count: Int) {
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: buffer, count: count))
        lock.unlock()
    }

    deinit {
        if let unit = audioUnit {
            AudioComponentInstanceDispose(unit)
        }
    }
}

// C-style callback for VPIO input
private func vpioInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let recorder = Unmanaged<VPIORecorder>.fromOpaque(inRefCon).takeUnretainedValue()
    guard recorder.isRecording, let unit = recorder.audioUnit else { return noErr }

    var bufferList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: inNumberFrames * 4,
            mData: nil
        )
    )
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: Int(inNumberFrames))
    bufferList.mBuffers.mData = UnsafeMutableRawPointer(buffer)

    let status = AudioUnitRender(unit, ioActionFlags, inTimeStamp, 1, inNumberFrames, &bufferList)
    if status == noErr {
        recorder.appendSamples(buffer, count: Int(inNumberFrames))
    }
    buffer.deallocate()
    return status
}
