import AVFoundation
import Combine
import CoreAudio

/// `handleUnexpectedStop` が受け取る最小のインターフェース。テストが
/// `AVAudioRecorder` を経由せず「stop() が onUnexpectedStop より先に呼ばれるか」
/// を直接検証できるように — `AVAudioRecorder` は録音中 (`isRecording == true`)
/// の状態をマイク権限無しで安全に作れないため、fake を挟めるようにする。
protocol AudioRecordingBackend: AnyObject {
    var isRecording: Bool { get }
    func stop()
}
extension AVAudioRecorder: AudioRecordingBackend {}

class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder? {
        didSet { activeSessionRecorder = recorder }
    }
    /// `recorder` の「現在の値」を弱参照で追跡する identity 比較用のポインタ
    /// (上の `didSet` で自動的に同期される)。`handleUnexpectedStop`/
    /// `checkWatchdog` はこれを使って「このコールバックは今のセッションの
    /// recorder から来たものか」を判定する — 型を `AVAudioRecorder?` ではなく
    /// `AnyObject?` にしているのは、テストが `AVAudioRecorder` ではない
    /// `FakeAudioRecordingBackend` を「現在のセッション」として
    /// `setActiveSessionForTesting` 経由で注入できるようにするため。
    private weak var activeSessionRecorder: AnyObject?
    var tempURL: URL?

    private let settings: [String: Any] = [
        AVFormatIDKey:             Int(kAudioFormatLinearPCM),
        AVSampleRateKey:           16000,
        AVNumberOfChannelsKey:     1,
        AVLinearPCMBitDepthKey:    16,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsFloatKey:     false,
    ]

    /// 録音開始時に保存しておく元のシステムデフォルト入力デバイス（stop で復元）
    private var previousDefaultInputDevice: AudioObjectID?
    private var settingObserver: AnyCancellable?

    override init() {
        super.init()
        // 設定変更時はレコーダーを破棄するだけ（次回 start() で新デバイスを反映した状態で再構築）。
        // prepare() でデバイス書き換えはせず、start() の applySelectedInputDevice() → 再生成の順で
        // AVAudioRecorder が選択 UID にバインドされることを保証する。
        settingObserver = AppSettings.shared.$audioInputDeviceUID
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleInputDeviceChange() }
    }

    /// 入力デバイス設定が変わった時の処理。テストが `AppSettings.shared` の
    /// 実 publisher に触らず直接呼べるよう `private` にしない
    /// (`checkWatchdog()`/`handleUnexpectedStop()` と同じ理由)。
    ///
    /// 2026-09-26 round-4 review: 以前は「録音中でなければ `recorder = nil`」
    /// するだけだった。しかし `recorder` が「ロードされてはいるが録音していない」
    /// のは、通常の停止後の残骸だけでなく、**システムがデバイス消失等で無音の
    /// まま停止させていて、watchdog/delegate もまだそれに気づいていない**
    /// ケースでもありうる。単に `recorder = nil` すると、後から来る
    /// watchdog/delegate の identity チェックが「もう nil だから何もしない」
    /// と誤判定し、`.ended` (dictation notification) が永久に飛ばなくなる。
    /// `handleUnexpectedStop()` 経由にすることで、この経路自身がその「最後に
    /// 気づいた者」になり、確実に ended を出してから recorder を握り潰す。
    func handleInputDeviceChange() {
        guard let r = recorder else { return }
        if r.isRecording { return }  // 録音中は触らない（次回 start() まで待つ）
        handleUnexpectedStop(r)
        klog("AudioRecorder: input device changed while recorder was already stopped — routed through handleUnexpectedStop")
    }

    /// アプリ専用ディレクトリ (0700) に音声ファイルを保存。
    /// tmp は OS パージ対象でクラッシュ時に録音が消えるため、Application Support 配下に置く。
    /// 旧 tmp ディレクトリの孤児ファイルは CrashRecovery が回収する。
    static let audioDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.yuki.koe/recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
        return dir
    }()

    /// 旧バージョンの録音置き場 (tmp)。クラッシュ復旧スキャン用に残す。
    static let legacyTmpDir: URL =
        FileManager.default.temporaryDirectory.appendingPathComponent("com.yuki.koe")

    // 事前にバッファを確保してレイテンシをゼロにする
    // ファイル名はセッション毎にユニーク: 前回クラッシュ時の録音を上書き/削除しない
    func prepare() {
        let url = Self.audioDir.appendingPathComponent("rec_\(UUID().uuidString.prefix(8)).wav")
        tempURL = url
        streamingDataOffset = nil
        streamingReadBytes = 0
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else { return }
        r.delegate = self
        r.isMeteringEnabled = true
        r.prepareToRecord()   // オーディオバッファを事前確保
        recorder = r
        klog("AudioRecorder prepared")
    }

    /// マイクの録音が実際に開始できたかを返す。呼び出し側 (AppDelegate) はこれを見て
    /// `isRecording`/dictation `.began` 通知を出すかどうかを決める — record() が
    /// 失敗したのに「録音中」扱いにして `.began` だけ飛ばすと、対になる `.ended` が
    /// 来ないまま Second 側の 120 秒失効待ちになってしまう。
    @discardableResult
    func start() -> Bool {
        // P5 指摘の prepare-order バグ対策: applySelectedInputDevice() で
        // システムデフォルト入力を選択 UID に切り替えてから AVAudioRecorder を生成する。
        // AVAudioRecorder は init 時点のデフォルトにバインドされるため、デバイス切替前に
        // 作成された recorder があれば破棄して再生成する。
        applySelectedInputDevice()
        if recorder == nil {
            prepare()
        }
        guard let r = recorder else {
            klog("AudioRecorder: recorder is nil after prepare, retrying")
            prepare()
            guard let r2 = recorder else {
                klog("AudioRecorder: failed to create recorder")
                rollbackFailedStart()
                return false
            }
            let ok = r2.record()
            klog("Recording started (retry), ok=\(ok) deviceUID=\(AppSettings.shared.audioInputDeviceUID)")
            if ok { startWatchdog() } else { rollbackFailedStart() }
            return ok
        }
        // recorderが前回のセッションから残っている場合、明示的にリセット
        if r.isRecording {
            klog("AudioRecorder: already recording, stopping first")
            r.stop()
        }
        let ok = r.record()
        if !ok {
            klog("AudioRecorder: record() failed, re-preparing")
            recorder = nil
            prepare()
            let retryOk = recorder?.record() ?? false
            klog("Recording started (re-prepare), ok=\(retryOk) deviceUID=\(AppSettings.shared.audioInputDeviceUID)")
            if retryOk { startWatchdog() } else { rollbackFailedStart() }
            return retryOk
        } else {
            klog("Recording started, ok=true deviceUID=\(AppSettings.shared.audioInputDeviceUID)")
            startWatchdog()
            return true
        }
    }

    /// `start()` が最終的に失敗した時の後始末。中途半端に `prepare()` 済みの
    /// recorder を残さず、`applySelectedInputDevice()` で切り替えたデフォルト
    /// 入力デバイスも元に戻す — 録音しないと決まった以上、システムのデフォルト
    /// 入力を切り替えたままにしない。
    private func rollbackFailedStart() {
        recorder = nil
        restoreDefaultInputDevice()
    }

    func stop() -> URL? {
        stopWatchdog()
        // 2026-09-26 round-3 review: 以前はファイル move 失敗時などの早期
        // return が restoreDefaultInputDevice() をスキップしていた —
        // システムのデフォルト入力デバイスを切り替えたままにしてしまう。
        // defer にして、どの exit path でも必ず復元する。
        defer { restoreDefaultInputDevice() }
        guard let r = recorder else {
            klog("AudioRecorder: stop called but recorder is nil")
            return nil
        }
        if r.isRecording {
            r.stop()
        }
        recorder = nil
        guard let src = tempURL else { return nil }
        // 一意なファイル名で保存（議事録モードで次の録音に上書きされないように）
        let id = UUID().uuidString.prefix(8)
        let dest = Self.audioDir.appendingPathComponent("recognize_\(id).wav")
        do {
            // move (rename) — 長時間録音の巨大 WAV をコピーしない & 同一ボリューム内でアトミック
            try FileManager.default.moveItem(at: src, to: dest)
        } catch {
            klog("AudioRecorder: move failed: \(error.localizedDescription)")
            return nil
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
        klog("Recording stopped, size=\(size) bytes -> \(dest.lastPathComponent)")
        // 古い一時ファイルを掃除（議事録モード中は保持、通常時は最新5件以外を削除）
        if !MeetingMode.shared.isActive {
            cleanOldFiles()
        }
        return dest
    }

    /// 古い recognize_*.wav を掃除（最新5件を残す）
    private func cleanOldFiles() {
        let dir = Self.audioDir
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let recFiles = files.filter { $0.lastPathComponent.hasPrefix("recognize_") }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return da > db
            }
        for file in recFiles.dropFirst(5) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func cancel() {
        stopWatchdog()
        recorder?.stop()
        recorder = nil
        if let url = tempURL { try? FileManager.default.removeItem(at: url) }
        klog("Recording cancelled")
        // restoreDefaultInputDevice() を先に呼んでから recorder = nil。
        // ここでは pre-prepare せず、次回 start() で applySelectedInputDevice → prepare の順を保証する。
        restoreDefaultInputDevice()
    }

    /// アプリ終了時用: 録音を止めるがファイルは**削除しない**（cancel と違い、
    /// 録音中に終了しても次回起動時に CrashRecovery が rec_*.wav を回収できる）。
    func shutdown() {
        stopWatchdog()
        if let r = recorder, r.isRecording {
            r.stop()
            klog("AudioRecorder: shutdown — in-progress recording preserved for recovery")
        }
        recorder = nil
        restoreDefaultInputDevice()
    }

    // MARK: - 入力デバイス切り替え

    /// 設定で選ばれた入力デバイスをシステムデフォルトに昇格させる（録音中だけ）。
    /// AVAudioRecorder はデバイス指定 API を持たないため、kAudioHardwarePropertyDefaultInputDevice
    /// を一時的に書き換える。stop / cancel で元に戻す。
    private func applySelectedInputDevice() {
        let uid = AppSettings.shared.audioInputDeviceUID
        guard !uid.isEmpty else { return }  // システムデフォルト → 何もしない
        guard let targetID = AudioDeviceEnumerator.deviceID(forUID: uid) else {
            klog("AudioRecorder: input device UID not found: \(uid)")
            return
        }
        let current = AudioDeviceEnumerator.defaultInputDeviceID()
        if current == targetID { return }  // 既に一致
        previousDefaultInputDevice = current
        let ok = AudioDeviceEnumerator.setDefaultInputDevice(targetID)
        klog("AudioRecorder: switch default input -> \(uid) ok=\(ok)")
    }

    private func restoreDefaultInputDevice() {
        guard let prev = previousDefaultInputDevice else { return }
        previousDefaultInputDevice = nil
        let ok = AudioDeviceEnumerator.setDefaultInputDevice(prev)
        klog("AudioRecorder: restored default input ok=\(ok)")
    }

    func currentLevel() -> Float {
        guard let r = recorder, r.isRecording else { return 0 }
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)
        return max(0, min(1, (db + 55) / 55))
    }

    // MARK: - ストリーミング差分読み（長時間録音対応）

    /// "data" チャンクのデータ開始オフセット（初回に解析してキャッシュ）
    private var streamingDataOffset: UInt64?
    /// これまでに読み取り済みのデータバイト数
    private var streamingReadBytes: Int = 0

    /// 録音中ファイルの「未読分だけ」を読み取り Float32 PCM で返す。
    /// 全ファイル再読込をしないため、録音が何時間続いても 1 フレームのコストは一定。
    func newStreamingSamples() -> [Float]? {
        guard let r = recorder, r.isRecording, let url = tempURL else { return nil }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        if streamingDataOffset == nil {
            // ヘッダー解析は先頭 8KB で十分（Apple は FLLR 充填チャンクを入れるため 44 固定にしない）
            let head = fh.readData(ofLength: 8192)
            guard head.count > 44 else { return nil }
            streamingDataOffset = UInt64(Self.findDataChunk(in: head))
            streamingReadBytes = 0
        }
        guard let dataOffset = streamingDataOffset else { return nil }

        guard (try? fh.seek(toOffset: dataOffset + UInt64(streamingReadBytes))) != nil else { return nil }
        let chunk = fh.readDataToEndOfFile()
        let usable = chunk.count - (chunk.count % 2)  // 16-bit 境界に切り揃え
        guard usable >= 2 else { return nil }
        streamingReadBytes += usable

        let sampleCount = usable / 2
        var samples = [Float](repeating: 0, count: sampleCount)
        chunk.prefix(usable).withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<sampleCount {
                samples[i] = Float(ptr[i]) / 32768.0
            }
        }
        return samples
    }

    /// 録音中の部分WAVファイルを読み取り、Float32 PCMサンプルとして返す。
    /// ストリーミングプレビュー用。録音中でなければnilを返す。
    func currentSamples() -> [Float]? {
        guard let r = recorder, r.isRecording, let url = tempURL else { return nil }
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return nil }

        // WAVヘッダーを正しくパース ("data"チャンクを探す)
        let dataOffset = Self.findDataChunk(in: data)
        guard dataOffset > 0, dataOffset < data.count else { return nil }

        let audioData = data.subdata(in: dataOffset..<data.count)
        let sampleCount = audioData.count / 2  // 16-bit samples

        guard sampleCount > 0 else { return nil }

        var samples = [Float](repeating: 0, count: sampleCount)
        audioData.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<sampleCount {
                samples[i] = Float(ptr[i]) / 32768.0
            }
        }
        return samples
    }

    /// WAVファイル内の "data" チャンクのデータ開始オフセットを返す
    static func findDataChunk(in data: Data) -> Int {
        guard data.count > 12 else { return 44 }
        var offset = 12
        while offset + 8 < data.count {
            let chunkID = data.subdata(in: offset..<offset+4)
            let sizeBytes = data.subdata(in: offset+4..<offset+8)
            let chunkSize = sizeBytes.withUnsafeBytes { $0.load(as: UInt32.self) }
            if chunkID == Data("data".utf8) { return offset + 8 }
            offset += 8 + Int(chunkSize)
            if Int(chunkSize) % 2 != 0 { offset += 1 }
        }
        return 44
    }

    /// `stopAndRecognize()`/`cancelRecording()`/`shutdown()` を経由しない、想定外の
    /// 録音停止（エンコードエラー・OS都合の中断・ウォッチドッグ検出等）を AppDelegate
    /// に伝える。AppDelegate 側はこれで isRecording をリセットし、dictation `.ended`
    /// を送る — でないと Koe が「録音中」のつもりのまま Second が 120 秒間マイクを
    /// 奪えなくなる。
    var onUnexpectedStop: (() -> Void)?

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        klog("Encode error: \(error?.localizedDescription ?? "nil")")
        // エンコードエラー発生後もレコーダーが録音中のままな場合があるため、
        // 明示的に stop() してマイクを解放してから .ended を送る（stop → ended
        // の順序を保証する）。
        handleUnexpectedStop(recorder)
    }

    /// AVAudioRecorderDelegate: 自前の `stop()` 呼び出しでも発火するが、その場合
    /// `flag == true` で届く（`AVAudioRecorder.stop()` は成功として delegate に通知する）。
    /// ここで拾いたいのは `flag == false` — OS都合の中断等、こちらが呼んでいない停止。
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard !flag else { return }
        klog("AudioRecorder: unexpected finish (successfully=false)")
        handleUnexpectedStop(recorder)
    }

    /// テストが `AudioRecordingBackend` の fake を渡して直接呼べるよう
    /// `private` にしない。stop() → onUnexpectedStop の順序はここで保証する
    /// (この2行は同期・単一スレッドで隣接しており、間に非同期の隙間はない)。
    ///
    /// **identity ガード (2026-09-26 round-3 review)**: `AVAudioRecorderDelegate`
    /// のコールバックや watchdog の tick は、呼ばれた時点で本当に「今の
    /// セッション」の recorder から来たものとは限らない — 例えば
    /// 「セッションA停止 → セッションB開始」の間に挟まって届く、Aの遅延した
    /// 失敗コールバック。ここで identity チェックをせずに進むと、Bがまだ
    /// 録音中なのに `self.recorder = nil` で B を握り潰し、誤って `.ended`
    /// (onUnexpectedStop) を発火してしまう。渡された `recorder` が
    /// `activeSessionRecorder` (= 現在の `self.recorder`) と同一でなければ、
    /// 古いセッションのコールバックとして黙って無視する。
    func handleUnexpectedStop(_ recorder: AudioRecordingBackend) {
        guard recorder === activeSessionRecorder else {
            klog("AudioRecorder: ignoring unexpected-stop callback from a stale/previous session's recorder")
            return
        }
        stopWatchdog()
        if recorder.isRecording {
            recorder.stop()
        }
        self.recorder = nil
        restoreDefaultInputDevice()
        onUnexpectedStop?()
    }

    /// テスト専用: identity ガード用の「現在のセッション」を直接注入する。
    /// 本体コードは `recorder` の `didSet` 経由でのみ更新するが (常に
    /// `AVAudioRecorder`)、テストは実マイクなしで動く `FakeAudioRecordingBackend`
    /// を「今のセッション」として扱いたいことがあるため、独立して差し替え
    /// られるようにする。
    func setActiveSessionForTesting(_ session: AnyObject?) {
        activeSessionRecorder = session
    }

    // MARK: - Watchdog (AirPods 切断等、AVAudioRecorderDelegate が発火しない停止の検出)

    /// AirPods 切断など、入力デバイスが消えて録音が止まっても
    /// `AVAudioRecorderDelegate` のどのコールバックも発火しないことがある
    /// (macOS では AVAudioSession の割り込み通知に相当するものが無い)。
    /// `start()` 成功中はこのタイマーで `recorder.isRecording` を定期的に
    /// ポーリングし、こちらが呼んでいないのに false になっていたら「最後の砦」
    /// として拾う。
    private var watchdogTimer: Timer?
    private let watchdogInterval: TimeInterval = 1.0

    private func startWatchdog() {
        stopWatchdog()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            self?.checkWatchdog()
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    /// タイマーが毎秒呼ぶ本体。テストからも直接呼べるよう `private` にしない。
    /// `recorder` が存在するのに `isRecording` が false になっていたら、
    /// システムによる無音の強制停止 (デバイス消失・中断等) とみなして拾う。
    func checkWatchdog() {
        guard let r = recorder, !r.isRecording else { return }
        klog("AudioRecorder: watchdog detected recording stopped unexpectedly (device loss / interruption)")
        handleUnexpectedStop(r)
    }
}
