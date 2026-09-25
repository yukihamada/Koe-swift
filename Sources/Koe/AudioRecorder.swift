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

/// 1 `start(sessionID:onUnexpectedStop:)` 呼び出しにつき 1 つ生成する
/// immutable な context。「どの recorder のものか」(`backend`)・「どの
/// セッションか」(`sessionID`)・「その想定外停止ハンドラ」(`onUnexpectedStop`)
/// を生成時に一度だけ結び付ける。
///
/// **2026-09-26 round-7 review**: 以前は `handleUnexpectedStop(_:)` が
/// `recorder === activeSessionRecorder` (identity) を判定した*後*で、
/// 別の独立した mutable プロパティ `onUnexpectedStop` を改めて読んでいた —
/// 2つの更新の間の隙間に別セッションへの rebind が挟まると、識別は古い
/// セッションのものと一致するのに実際に呼ばれるのは新しいセッションの
/// closure、という誤発火 (TOCTOU) が構造的に起こり得た。
///
/// **2026-09-26 round-8 review**: round-7 の修正は `RecordingContext` を
/// `recorder` プロパティの setter (= `prepare()` が呼ばれた時だけ) で
/// 作っていた。しかし `start()` は `recorder == nil` の時しか `prepare()`
/// を呼ばない — 既に prepare 済みの recorder を再利用するパスでは
/// `recorder` に再代入が起きないため、`currentContext` が **前のセッション
/// の onUnexpectedStop を焼き込んだまま** 据え置かれてしまう。結果、後の
/// セッションの想定外停止が前のセッションのハンドラに配送される (または
/// 前のセッションの sessionID=nil のハンドラのまま固まる) というバグが
/// あった。
///
/// 修正: `RecordingContext` の生成場所を `prepare()`/`recorder` セッターから
/// `start(sessionID:onUnexpectedStop:)` 自身に移した。`start()` は
/// **実際に `.record()` を呼おうとしている recorder インスタンスに対して、
/// recorder が新規に prepare() されたか既存のものを再利用したかに関わらず
/// 毎回必ず新しい `RecordingContext` を作り直す** ——
/// これにより「呼ばれたセッションの sessionID/onUnexpectedStop」と「実際に
/// 使われる recorder インスタンス」が常に同じ `start()` 呼び出しの中で
/// アトミックに結び付けられ、古いセッションの登録が生き残る余地がなくなる。
private final class RecordingContext {
    let sessionID: UUID
    let backend: AudioRecordingBackend
    let onUnexpectedStop: (UUID, AudioRecorder.Reason) -> Void

    init(sessionID: UUID, backend: AudioRecordingBackend, onUnexpectedStop: @escaping (UUID, AudioRecorder.Reason) -> Void) {
        self.sessionID = sessionID
        self.backend = backend
        self.onUnexpectedStop = onUnexpectedStop
    }
}

class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    /// 想定外の録音停止の理由。呼び出し側 (AppDelegate) は現状これを区別
    /// せずにフルリセットするだけだが、型として持たせておくことで将来の
    /// 分岐 (例: エンコードエラーだけ再試行する等) を安全に足せるようにする。
    enum Reason: Equatable {
        case encodeError(String?)
        case finishedUnsuccessfully
        case watchdogSilentStop
        case inputDeviceChangedWhileStopped
    }

    /// **2026-09-26 round-9 review**: `recorder`/`currentContext`/watchdog
    /// タイマーは全て main thread 専属の mutable state とする —
    /// `AVAudioRecorderDelegate` のコールバックは AVFoundation の内部
    /// スレッドから来ることがあり、これらのプロパティを off-main で
    /// 読み書きするとデータ競合になる。以前は `handleUnexpectedStop(_:)`
    /// が呼ばれたスレッドでそのまま identity チェック→stop→クリア→
    /// callback を実行していた — main thread が (別スレッドの) この
    /// メソッドの実行途中に割り込んで `stop()`→`start()` (セッションA終了
    /// →セッションB開始) を行うと、後から実行が再開したこのメソッドが
    /// 「もう存在しない (あるいは既にBに置き換わった)」状態を無条件に
    /// nil で上書きし、Bの登録を握り潰してしまう可能性があった。
    ///
    /// 修正: mutable state を書き換える全ての入口 (delegate コールバック・
    /// watchdog タイマー・CoreAudio/Combine リスナー) は、まず
    /// `dispatchToMain(_:)` で確実に main に乗せてから、実際の状態変更
    /// (`performUnexpectedStopOnMain` 等) を行う。main はシリアルキュー
    /// なので、一度乗ってしまえば他の main 上の操作 (`start()`/`stop()` 等)
    /// と競合する余地がない — 「間に合わなかった」場合は単に、hop が実際に
    /// 実行される時点での最新の `currentContext` を見て判定するだけになる。
    private func dispatchToMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    /// mutable state を書き換えるメソッドの先頭に置く自己文書化アサート。
    /// Release ビルドでは `assert` は no-op になるため、本番の挙動は変えない
    /// — 開発/テスト時に「main 以外から呼ばれた」ことを早期に検知するための
    /// tripwire。
    private func assertMainThreadForMutation(_ function: StaticString = #function) {
        assert(Thread.isMainThread, "AudioRecorder.\(function) must only mutate state on the main thread")
    }

    /// 生の `AVAudioRecorder`。「今のセッションの登録」(`currentContext`) とは
    /// 別軸 — `start()` は `recorder == nil` の時しか `prepare()` を呼ばない
    /// ため、同じインスタンスが複数の `start()` 呼び出しにまたがって再利用
    /// されることがある (round-8 review)。main thread からのみ読み書きする
    /// (round-9 review)。
    private var recorder: AVAudioRecorder?
    /// 「今のセッション」の登録。`start(sessionID:onUnexpectedStop:)` が
    /// 呼ばれる度に必ず新しく作り直す — `recorder` インスタンスの再利用の
    /// 有無に関わらず。
    private var currentContext: RecordingContext?
    var tempURL: URL?

    /// テストが `AVAudioRecorder` のサブクラス (マイクに一切触れない fake) を
    /// 注入できるようにするファクトリ。本番は常にデフォルト実装
    /// (`AVAudioRecorder.init(url:settings:)`) を使う。
    ///
    /// **round-8 review**: これにより「本物の `prepare()`/
    /// `start(sessionID:onUnexpectedStop:)` の経路そのもの」を、マイクに
    /// 一切触れずにテストできる — `setActiveSessionForTesting` のような
    /// 直接注入の抜け道は廃止し、テストは常にこの経路を通る。
    var recorderFactory: (URL, [String: Any]) throws -> AVAudioRecorder = { url, settings in
        try AVAudioRecorder(url: url, settings: settings)
    }

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
        // 2026-09-26 round-9 review: Combine の `.receive(on: DispatchQueue.main)`
        // が既に main へ運んでくれているので、ここは既に main のはず —
        // mutable state (`currentContext` 等) に触れる全ての入口の不変条件を
        // 明示するため assert しておく (詳細は `assertMainThreadForMutation()`)。
        assertMainThreadForMutation()
        guard let context = currentContext else { return }
        if context.backend.isRecording { return }  // 録音中は触らない（次回 start() まで待つ）
        performUnexpectedStopOnMain(context.backend, reason: .inputDeviceChangedWhileStopped)
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
    //
    // **round-8 review**: ここでは `currentContext` に一切触れない —
    // 「どのセッションのものか」の登録は必ず `start(sessionID:onUnexpectedStop:)`
    // 自身が行う。`prepare()` は「使える recorder インスタンスを用意する」
    // だけの責務に限定する。
    func prepare() {
        assertMainThreadForMutation()
        let url = Self.audioDir.appendingPathComponent("rec_\(UUID().uuidString.prefix(8)).wav")
        tempURL = url
        streamingDataOffset = nil
        streamingReadBytes = 0
        guard let r = try? recorderFactory(url, settings) else { return }
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
    ///
    /// `sessionID`/`onUnexpectedStop`: 呼び出し側 (AppDelegate) がこの
    /// セッション専用に用意した識別子とハンドラ。**2026-09-26 round-8
    /// review**: 以前は `onUnexpectedStop` という mutable property に
    /// 事前 bind しておく設計だったため、`start()` が `prepare()` を
    /// スキップして既存の recorder を再利用するパスで、古いセッションの
    /// 登録 (`currentContext`) が更新されずに残るバグがあった。この API
    /// では `start()` 自身が `sessionID`/`onUnexpectedStop` を受け取り、
    /// **実際に `.record()` を呼ぶ recorder インスタンスに対して、それが
    /// 新規 prepare() されたか再利用かに関わらず、必ずその場で新しい
    /// `RecordingContext` を作り直す** — 古い登録が生き残る余地を構造的に
    /// なくす。
    @discardableResult
    func start(sessionID: UUID, onUnexpectedStop: @escaping (UUID, Reason) -> Void) -> Bool {
        assertMainThreadForMutation()
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
            currentContext = RecordingContext(sessionID: sessionID, backend: r2, onUnexpectedStop: onUnexpectedStop)
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
        // round-8 review: `r` が今しがた prepare() された新品か、既存の
        // ものを再利用しているかに関わらず、ここで必ず新しい
        // RecordingContext を作り直す。
        currentContext = RecordingContext(sessionID: sessionID, backend: r, onUnexpectedStop: onUnexpectedStop)
        let ok = r.record()
        if !ok {
            klog("AudioRecorder: record() failed, re-preparing")
            recorder = nil
            currentContext = nil
            prepare()
            guard let r3 = recorder else {
                rollbackFailedStart()
                return false
            }
            currentContext = RecordingContext(sessionID: sessionID, backend: r3, onUnexpectedStop: onUnexpectedStop)
            let retryOk = r3.record()
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
        currentContext = nil
        restoreDefaultInputDevice()
    }

    func stop() -> URL? {
        assertMainThreadForMutation()
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
        currentContext = nil
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
        assertMainThreadForMutation()
        stopWatchdog()
        recorder?.stop()
        recorder = nil
        currentContext = nil
        if let url = tempURL { try? FileManager.default.removeItem(at: url) }
        klog("Recording cancelled")
        // restoreDefaultInputDevice() を先に呼んでから recorder = nil。
        // ここでは pre-prepare せず、次回 start() で applySelectedInputDevice → prepare の順を保証する。
        restoreDefaultInputDevice()
    }

    /// アプリ終了時用: 録音を止めるがファイルは**削除しない**（cancel と違い、
    /// 録音中に終了しても次回起動時に CrashRecovery が rec_*.wav を回収できる）。
    func shutdown() {
        assertMainThreadForMutation()
        stopWatchdog()
        if let r = recorder, r.isRecording {
            r.stop()
            klog("AudioRecorder: shutdown — in-progress recording preserved for recovery")
        }
        recorder = nil
        currentContext = nil
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

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        klog("Encode error: \(error?.localizedDescription ?? "nil")")
        // エンコードエラー発生後もレコーダーが録音中のままな場合があるため、
        // 明示的に stop() してマイクを解放してから .ended を送る（stop → ended
        // の順序を保証する）。
        handleUnexpectedStop(recorder, reason: .encodeError(error?.localizedDescription))
    }

    /// AVAudioRecorderDelegate: 自前の `stop()` 呼び出しでも発火するが、その場合
    /// `flag == true` で届く（`AVAudioRecorder.stop()` は成功として delegate に通知する）。
    /// ここで拾いたいのは `flag == false` — OS都合の中断等、こちらが呼んでいない停止。
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard !flag else { return }
        klog("AudioRecorder: unexpected finish (successfully=false)")
        handleUnexpectedStop(recorder, reason: .finishedUnsuccessfully)
    }

    /// テストが `AudioRecordingBackend` の fake を渡して直接呼べるよう
    /// `private` にしない。
    ///
    /// **identity ガード (2026-09-26 round-3 review)**: `AVAudioRecorderDelegate`
    /// のコールバックや watchdog の tick は、呼ばれた時点で本当に「今の
    /// セッション」の recorder から来たものとは限らない — 例えば
    /// 「セッションA停止 → セッションB開始」の間に挟まって届く、Aの遅延した
    /// 失敗コールバック。ここで identity チェックをせずに進むと、Bがまだ
    /// 録音中なのに `self.recorder = nil` で B を握り潰し、誤って `.ended`
    /// (onUnexpectedStop) を発火してしまう。
    ///
    /// **round-7/round-8 review**: identity チェックと「呼び出す closure」を
    /// `currentContext` という単一の参照から1回だけスナップショットして
    /// 両方に使う (`RecordingContext` のドキュメント参照)。
    ///
    /// **round-9 review**: `AVAudioRecorderDelegate` のコールバックは
    /// AVFoundation の内部スレッドから来ることがあり、以前はこのメソッド
    /// 自体が identity チェック〜クリア〜callback 呼び出しまで全てそのスレッド
    /// 上で実行していた — main thread がその実行の「途中」(identity チェック
    /// は通った後、`self.recorder`/`currentContext` を nil にする前) に
    /// 割り込んで A の `stop()` → B の `start()` を行うと、後から再開した
    /// この off-main の実行が無条件に nil クリアして、既に登録されたはずの
    /// B の `recorder`/`currentContext`/watchdog を握り潰してしまうデータ
    /// 競合があった。
    ///
    /// 修正: このメソッド自身は「main に確実に乗せる」ことだけを行い、
    /// 実際の状態変更 (`performUnexpectedStopOnMain`) は必ず main 上で
    /// 実行する。main はシリアルキューなので、一度そこに乗ってしまえば
    /// `start()`/`stop()` 等の他の mutator と割り込みなく直列に実行される
    /// — 「間に合わなかった」場合でも、実行時点の最新の `currentContext` を
    /// 見て安全に無視するだけになる。
    func handleUnexpectedStop(_ recorder: AudioRecordingBackend, reason: Reason) {
        dispatchToMain { [weak self] in
            self?.performUnexpectedStopOnMain(recorder, reason: reason)
        }
    }

    /// `handleUnexpectedStop(_:reason:)`/`checkWatchdog()`/
    /// `handleInputDeviceChange()` が main に乗った**後**に呼ぶ、実際の
    /// identity チェック・stop・クリア・callback 呼び出し本体。main 以外
    /// から直接呼ばない (`assertMainThreadForMutation()` が tripwire)。
    private func performUnexpectedStopOnMain(_ recorder: AudioRecordingBackend, reason: Reason) {
        assertMainThreadForMutation()
        guard let context = currentContext, context.backend === recorder else {
            klog("AudioRecorder: ignoring unexpected-stop callback from a stale/previous session's recorder")
            return
        }
        stopWatchdog()
        if recorder.isRecording {
            recorder.stop()
        }
        let sessionID = context.sessionID
        let onUnexpectedStop = context.onUnexpectedStop
        self.recorder = nil
        currentContext = nil
        restoreDefaultInputDevice()
        onUnexpectedStop(sessionID, reason)
    }

    /// テスト専用の読み取り専用アクセサ: `start(sessionID:onUnexpectedStop:)`
    /// が内部で実際に使った `AVAudioRecorder` インスタンスを覗き見る。
    /// **round-8 review**: 書き込み用の `setActiveSessionForTesting` は
    /// 廃止した — 「今のセッション」の登録は必ず
    /// `start(sessionID:onUnexpectedStop:)` 経由でのみ行われる (本番と全く
    /// 同じ経路)。これは読み取り専用で、登録には一切関与しない。
    var currentRecorderForTesting: AVAudioRecorder? { recorder }

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
    ///
    /// **round-9 review**: `Timer` は `startWatchdog()` を呼んだスレッドの
    /// run loop 上で発火する契約だが (`start()`/`prepare()` は main 専属な
    /// ので通常は main)、他の入口と同じ不変条件を保つため、ここも念のため
    /// `dispatchToMain` を経由してから `currentContext` を読む。
    func checkWatchdog() {
        dispatchToMain { [weak self] in
            self?.performWatchdogCheckOnMain()
        }
    }

    private func performWatchdogCheckOnMain() {
        assertMainThreadForMutation()
        guard let context = currentContext, !context.backend.isRecording else { return }
        klog("AudioRecorder: watchdog detected recording stopped unexpectedly (device loss / interruption)")
        performUnexpectedStopOnMain(context.backend, reason: .watchdogSilentStop)
    }
}
