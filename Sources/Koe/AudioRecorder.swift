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
/// immutable な context。「どの recorder のものか」(`backend`)・「その
/// recorder の一時ファイル」(`tempURL`)・「どのセッションか」(`sessionID`)・
/// 「その想定外停止ハンドラ」(`onUnexpectedStop`) を生成時に一度だけ結び付ける。
/// **これが「今アクティブな録音セッション」の唯一の真実 (single source of
/// truth) であり、`AudioRecorder` は他のどのプロパティにも「アクティブな
/// recorder」を二重に保持しない (round-10 review)。**
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
/// `recorder` に再代入が起きないため、`currentContext` が前のセッションの
/// `onUnexpectedStop` を焼き込んだまま据え置かれてしまうバグがあった。
/// 修正: `RecordingContext` の生成場所を `start(sessionID:onUnexpectedStop:)`
/// 自身に移し、recorder の使い回しの有無に関わらず毎回作り直すようにした。
///
/// **2026-09-26 round-10 review**: round-8/9 はまだ「今アクティブな
/// recorder」を `recorder` という**別の**プロパティにも保持していた
/// (`currentContext.backend` と冗長に同じものを指すはずの2つ目の変数)。
/// `AppDelegate.stopAndRecognize()` は録音終了直後に次回用の recorder を
/// 非同期に先読み準備する (`DispatchQueue.main.async { self.recorder.prepare() }`)
/// — この pre-warm の実行タイミングが、たまたま「次の `start()` が既に
/// 実行され終わった後」にずれ込むと、`prepare()` は無条件に
/// `self.recorder` を新しい (何もしていない) recorder で上書きしてしまう。
/// `currentContext.backend` は正しく古い (実際に録音中の) recorder を
/// 指したままなので、次に呼ばれる `stop()`/`cancel()`/`shutdown()` が
/// もし「`recorder` プロパティ」を見て動いていたら、**本当に録音している
/// recorder ではなく、何もしていない pre-warm 済みの recorder を止める**
/// ことになり、実際のマイクは解放されないまま `.ended` だけが送られて
/// しまう (マイクが鳴りっぱなしになる深刻なバグ)。
///
/// 修正: 「今アクティブな recorder」を `currentContext.backend` **だけ**に
/// 一本化した (`recorder` プロパティ自体を廃止)。`stop()`/`cancel()`/
/// `shutdown()`/watchdog/delegate は全て `currentContext` 経由でのみ
/// recorder に触れる。まだどのセッションにも属さない「先読み準備済みの
/// recorder」は完全に別枠の `prewarmedRecorder` に置き、しかも
/// `prepare()` 自体をセッション進行中 (`currentContext != nil`) は
/// no-op にすることで、pre-warm が現在進行中のセッションを踏みつぶす
/// 経路そのものを構造的になくした。
private final class RecordingContext {
    let sessionID: UUID
    let backend: AudioRecordingBackend
    let tempURL: URL
    let onUnexpectedStop: (UUID, AudioRecorder.Reason) -> Void

    init(sessionID: UUID, backend: AudioRecordingBackend, tempURL: URL, onUnexpectedStop: @escaping (UUID, AudioRecorder.Reason) -> Void) {
        self.sessionID = sessionID
        self.backend = backend
        self.tempURL = tempURL
        self.onUnexpectedStop = onUnexpectedStop
    }
}

class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    /// 録音停止の理由。想定外系 (`encodeError`/`finishedUnsuccessfully`/
    /// `watchdogSilentStop`/`inputDeviceChangedWhileStopped`) は
    /// `onUnexpectedStop` 経由で呼び出し側 (AppDelegate) にも渡り、そちらは
    /// 現状これを区別せずフルリセットするだけだが、型として持たせておく
    /// ことで将来の分岐を安全に足せるようにする。
    ///
    /// **round-11 review**: `normalStop`/`cancelStop`/`shutdownStop` は
    /// `stopActive(reason:)` 内部のログ用途のみに使う意図的な停止の理由 —
    /// これらが `onUnexpectedStop` に渡ることはない (呼び出し側は
    /// `stop()`/`cancel()` の戻り値で直接成否を知る)。
    enum Reason: Equatable {
        case encodeError(String?)
        case finishedUnsuccessfully
        case watchdogSilentStop
        case inputDeviceChangedWhileStopped
        case normalStop
        case cancelStop
        case shutdownStop
    }

    /// `stopActive(reason:)` の結果。「今アクティブなセッションについて
    /// 呼び出し側が `.ended` を送ってよいか」を型で強制する (round-11)。
    private enum StopResult {
        /// backend が実際に停止したことを確認できた。呼び出し側は `.ended`
        /// を送ってよい。
        case stopped(sessionID: UUID, tempURL: URL)
        /// backend が停止要求を無視し、まだ録音中。`currentContext` は
        /// クリアされていない (セッションは生きている扱い) — 呼び出し側は
        /// `.ended` を送ってはいけない。最終的な検出と通知は watchdog に
        /// 委ねられる。
        case stillRecording(sessionID: UUID)
        /// 呼び出し時点で既にアクティブなセッションが無かった。
        case noActiveSession
    }

    /// **2026-09-26 round-9 review**: `currentContext`/pre-warm 用プロパティ/
    /// watchdog タイマーは全て main thread 専属の mutable state とする —
    /// `AVAudioRecorderDelegate` のコールバックは AVFoundation の内部
    /// スレッドから来ることがあり、これらのプロパティを off-main で
    /// 読み書きするとデータ競合になる。
    ///
    /// 修正: mutable state を書き換える全ての入口 (delegate コールバック・
    /// watchdog タイマー・CoreAudio/Combine リスナー) は、まず
    /// `dispatchToMain(_:)` で確実に main に乗せてから、実際の状態変更を
    /// 行う。main はシリアルキューなので、一度乗ってしまえば他の main 上の
    /// 操作 (`start()`/`stop()` 等) と競合する余地がない。
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

    /// 「今アクティブな録音セッション」の**唯一**の真実。`recorder`という
    /// 別プロパティは round-10 review で廃止した — 詳細は
    /// `RecordingContext` のドキュメント参照。
    private var currentContext: RecordingContext?

    /// `prepare()` が事前に用意した、まだどのセッションにも属していない
    /// recorder (次回の `start()` がレイテンシゼロで消費するための
    /// 先読みキャッシュ)。`currentContext` とは完全に別枠 — pre-warm が
    /// 現在進行中のセッションに触れることは構造的にない (round-10 review)。
    private var prewarmedRecorder: AVAudioRecorder?
    private var prewarmedTempURL: URL?

    /// 呼び出し側 (AppDelegate) が読む、今アクティブなセッションの一時
    /// ファイル。**round-10 review**: 独立した stored property ではなく
    /// `currentContext` からの computed property にした — 以前は
    /// `prepare()` が無条件にこれを上書きできたため、pre-warm が現在
    /// 進行中のセッションのファイルパスを book-keeping 上すり替えて
    /// しまう経路があった。
    var tempURL: URL? { currentContext?.tempURL }

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
    // **round-10 review**: `AppDelegate.stopAndRecognize()` はセッション
    // 終了直後に `DispatchQueue.main.async { self.recorder.prepare() }` で
    // 次回用の recorder を非同期に先読み準備する。この非同期実行が
    // 「次の `start()` が既に終わった後」にずれ込むケースがあり得るため、
    // **セッションが進行中 (`currentContext != nil`) の間は pre-warm を
    // 完全に no-op にする** — 進行中のアクティブな recorder には一切
    // 触れない。pre-warm はあくまで「今何も録音していない」時だけの
    // 最適化であって、必須の準備ではない (呼ばれなくても `start()` 自身が
    // 必要なら prepare する)。
    func prepare() {
        assertMainThreadForMutation()
        guard currentContext == nil else {
            klog("AudioRecorder: prepare() skipped — a session is currently active, pre-warm would clobber it")
            return
        }
        let url = Self.audioDir.appendingPathComponent("rec_\(UUID().uuidString.prefix(8)).wav")
        streamingDataOffset = nil
        streamingReadBytes = 0
        guard let r = try? recorderFactory(url, settings) else { return }
        r.delegate = self
        r.isMeteringEnabled = true
        r.prepareToRecord()   // オーディオバッファを事前確保
        prewarmedRecorder = r
        prewarmedTempURL = url
        klog("AudioRecorder prepared")
    }

    /// pre-warm 済みの recorder があればそれを消費して返す。無ければその場で
    /// `prepare()` して作る。どちらも失敗すれば nil。
    private func consumePrewarmedRecorder() -> (AVAudioRecorder, URL)? {
        if prewarmedRecorder == nil {
            prepare()
        }
        guard let r = prewarmedRecorder, let url = prewarmedTempURL else { return nil }
        prewarmedRecorder = nil
        prewarmedTempURL = nil
        return (r, url)
    }

    /// マイクの録音が実際に開始できたかを返す。呼び出し側 (AppDelegate) はこれを見て
    /// `isRecording`/dictation `.began` 通知を出すかどうかを決める — record() が
    /// 失敗したのに「録音中」扱いにして `.began` だけ飛ばすと、対になる `.ended` が
    /// 来ないまま Second 側の 120 秒失効待ちになってしまう。
    ///
    /// `sessionID`/`onUnexpectedStop`: 呼び出し側 (AppDelegate) がこの
    /// セッション専用に用意した識別子とハンドラ。**2026-09-26 round-8
    /// review**: `start()` 自身が `sessionID`/`onUnexpectedStop` を受け取り、
    /// **実際に `.record()` を呼ぶ recorder インスタンスに対して、それが
    /// 新規 prepare() されたか再利用かに関わらず、必ずその場で新しい
    /// `RecordingContext` を作り直す** — 古い登録が生き残る余地を構造的に
    /// なくす。**round-10 review**: pre-warm キャッシュ (`prewarmedRecorder`)
    /// を消費して `currentContext` を組み立てる — 「今アクティブな
    /// recorder」は常に `currentContext.backend` だけが指す。
    @discardableResult
    func start(sessionID: UUID, onUnexpectedStop: @escaping (UUID, Reason) -> Void) -> Bool {
        assertMainThreadForMutation()
        // P5 指摘の prepare-order バグ対策: applySelectedInputDevice() で
        // システムデフォルト入力を選択 UID に切り替えてから AVAudioRecorder を生成する。
        // AVAudioRecorder は init 時点のデフォルトにバインドされるため、デバイス切替前に
        // 作成された recorder があれば破棄して再生成する。
        applySelectedInputDevice()

        guard let (r, url) = consumePrewarmedRecorder() else {
            klog("AudioRecorder: failed to create recorder")
            rollbackFailedStart()
            return false
        }

        // recorderが前回のセッションから残っている場合、明示的にリセット
        if r.isRecording {
            klog("AudioRecorder: already recording, stopping first")
            r.stop()
        }
        currentContext = RecordingContext(sessionID: sessionID, backend: r, tempURL: url, onUnexpectedStop: onUnexpectedStop)
        let ok = r.record()
        if !ok {
            klog("AudioRecorder: record() failed, re-preparing")
            currentContext = nil
            guard let (r2, url2) = consumePrewarmedRecorder() else {
                rollbackFailedStart()
                return false
            }
            currentContext = RecordingContext(sessionID: sessionID, backend: r2, tempURL: url2, onUnexpectedStop: onUnexpectedStop)
            let retryOk = r2.record()
            klog("Recording started (re-prepare), ok=\(retryOk) deviceUID=\(AppSettings.shared.audioInputDeviceUID)")
            if retryOk { startWatchdog() } else { rollbackFailedStart() }
            return retryOk
        } else {
            klog("Recording started, ok=true deviceUID=\(AppSettings.shared.audioInputDeviceUID)")
            startWatchdog()
            return true
        }
    }

    /// `start()` が最終的に失敗した時の後始末。`applySelectedInputDevice()`
    /// で切り替えたデフォルト入力デバイスを元に戻す — 録音しないと決まった
    /// 以上、システムのデフォルト入力を切り替えたままにしない。
    private func rollbackFailedStart() {
        currentContext = nil
        restoreDefaultInputDevice()
    }

    /// 全ての「停止試行」が通る唯一の入口 (round-11 review)。
    ///
    /// **背景**: round-10 までは `stop()`/`cancel()`/`shutdown()`/
    /// 想定外停止 (`performUnexpectedStopOnMain`) がそれぞれ独立に
    /// 「`backend.stop()` を呼んで `currentContext` を nil にする」ロジックを
    /// 持っていた。`stop()` だけは `isRecording` を再チェックして成功を
    /// 偽装しないようにしていたが、`cancel()`/`shutdown()` は再チェックせず
    /// 無条件に `currentContext = nil` していた — backend が `stop()` を
    /// 呼ばれても実際には録音を止めない (テストの fake で再現可能、実機でも
    /// 理論上あり得る) 場合、マイクがまだ解放されていないのに呼び出し側
    /// (AppDelegate) はセッションが終わったと思い込んでしまう。
    ///
    /// **ルール**: セッション X について `.ended` を送ってよいのは、X の
    /// backend が実際に「録音していない」と観測できた時だけ。この関数が
    /// その唯一の判定者になる。
    ///
    /// - backend が停止を確認できた (`isRecording == false`) →
    ///   `currentContext` をクリアし `.stopped` を返す。呼び出し側は
    ///   これを見て `.ended` を送ってよい。
    /// - まだ録音中 (backend が停止要求を無視した) → `currentContext` は
    ///   **そのまま保持**する (セッションは生きている扱い・UI はエラー
    ///   状態のまま)。ログを出し、次の main run loop tick で一度だけ
    ///   `backend.stop()` を再試行する。それでも止まらなければ、既に
    ///   稼働している watchdog (`performWatchdogCheckOnMain`、1秒毎) が
    ///   `isRecording == false` になった瞬間を検出し、想定外停止経路
    ///   (`onUnexpectedStop`) 経由で最終的に `.ended` を送る —
    ///   「本当に止まったことが確認できるまで watchdog が面倒を見る」
    ///   ことが保証される。
    /// - 呼び出し時点で `currentContext` が既に nil → `.noActiveSession`。
    ///
    /// `force`: shutdown/termination 専用の唯一のドキュメント化された例外。
    /// プロセスが終了する直前は「本当に止まるまで待つ」余地が無い —
    /// プロセスが終了すれば OS がマイクを強制的に解放する。`force: true`
    /// では `backend.stop()` は試みるが、結果に関わらず必ず
    /// `currentContext` をクリアして `.stopped` を返す。`shutdown()` だけが
    /// これを使う。
    @discardableResult
    private func stopActive(reason: Reason, force: Bool = false) -> StopResult {
        assertMainThreadForMutation()
        guard let context = currentContext else { return .noActiveSession }
        let backend = context.backend
        if backend.isRecording {
            backend.stop()
        }
        guard !backend.isRecording || force else {
            klog("AudioRecorder: stopActive(reason: \(reason)) — backend refused to stop, keeping session active and scheduling one retry")
            let contextSnapshot = context
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentContext === contextSnapshot else { return }
                if contextSnapshot.backend.isRecording {
                    contextSnapshot.backend.stop()
                    klog("AudioRecorder: stopActive retry — re-issued stop() for still-active session")
                }
                // ここで isRecording が false になったことを検出して .ended を
                // 送るのは watchdog の役目 (performWatchdogCheckOnMain)。
                // watchdog はこのパスでは止めていないので、次の tick で拾う。
            }
            return .stillRecording(sessionID: context.sessionID)
        }
        stopWatchdog()
        let sessionID = context.sessionID
        let tempURL = context.tempURL
        currentContext = nil
        restoreDefaultInputDevice()
        return .stopped(sessionID: sessionID, tempURL: tempURL)
    }

    /// **round-10/11 review**: `stopActive(reason:)` に一本化。backend が
    /// 実際に停止を確認できた時だけ非nilを返す。
    func stop() -> URL? {
        switch stopActive(reason: .normalStop) {
        case .noActiveSession:
            klog("AudioRecorder: stop called but no session is active")
            return nil
        case .stillRecording:
            klog("AudioRecorder: stop() — backend refused to release the active recorder; not reporting success (retry scheduled, watchdog will finish it)")
            return nil
        case .stopped(_, let src):
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

    /// **round-11 review**: `stopActive(reason:)` に一本化。backend が実際に
    /// 停止を確認できた時だけ true を返し、一時ファイルを削除する。まだ
    /// 録音中 (backend が停止を拒否した) 場合はセッションを生かしたまま
    /// false を返す — 呼び出し側 (AppDelegate) はこの場合 `.ended` を送っては
    /// いけない。最終的な検出と通知は `stopActive` が仕込む再試行 + 既存の
    /// watchdog に委ねられる (通常の想定外停止経路として `.ended` が届く)。
    @discardableResult
    func cancel() -> Bool {
        assertMainThreadForMutation()
        guard let context = currentContext else {
            klog("AudioRecorder: cancel called but no session is active")
            return false
        }
        let tempURL = context.tempURL
        switch stopActive(reason: .cancelStop) {
        case .stopped:
            try? FileManager.default.removeItem(at: tempURL)
            klog("Recording cancelled")
            return true
        case .stillRecording:
            klog("AudioRecorder: cancel() — backend refused to stop; session kept active (temp file not deleted), watchdog will finish the cancel once it observes isRecording == false")
            return false
        case .noActiveSession:
            return false
        }
    }

    /// アプリ終了時用: 録音を止めるがファイルは**削除しない**（cancel と違い、
    /// 録音中に終了しても次回起動時に CrashRecovery が rec_*.wav を回収できる）。
    ///
    /// **round-11 review**: shutdown/termination は `stopActive` の唯一の
    /// ドキュメント化された例外 (`force: true`) — プロセスが終了する直前は
    /// 「backend が本当に止まるまで待つ」余地が無く、プロセスの終了自体が
    /// OS によるマイクの強制解放になるため、backend の停止確認に関わらず
    /// 必ず `currentContext` をクリアする。呼び出し側
    /// (`stopRecordingForTermination`) はこれを見ずに常に `.ended` を送る。
    func shutdown() {
        assertMainThreadForMutation()
        let wasRecording = currentContext?.backend.isRecording ?? false
        stopActive(reason: .shutdownStop, force: true)
        if wasRecording {
            klog("AudioRecorder: shutdown — in-progress recording preserved for recovery (backend stop forced regardless of outcome)")
        }
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
        guard let r = currentContext?.backend as? AVAudioRecorder, r.isRecording else { return 0 }
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
        guard let context = currentContext, context.backend.isRecording else { return nil }
        let url = context.tempURL
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
        guard let context = currentContext, context.backend.isRecording else { return nil }
        let url = context.tempURL
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
    /// 録音中なのに B を握り潰し、誤って `.ended` (onUnexpectedStop) を
    /// 発火してしまう。
    ///
    /// **round-7/round-8 review**: identity チェックと「呼び出す closure」を
    /// `currentContext` という単一の参照から1回だけスナップショットして
    /// 両方に使う (`RecordingContext` のドキュメント参照)。
    ///
    /// **round-9 review**: `AVAudioRecorderDelegate` のコールバックは
    /// AVFoundation の内部スレッドから来ることがあり、以前はこのメソッド
    /// 自体が identity チェック〜クリア〜callback 呼び出しまで全てそのスレッド
    /// 上で実行していた — main thread がその実行の「途中」に割り込んで
    /// A の `stop()` → B の `start()` を行うと、後から再開したこの
    /// off-main の実行が既に登録されたはずの B の状態を握り潰してしまう
    /// データ競合があった。修正: このメソッド自身は「main に確実に乗せる」
    /// ことだけを行い、実際の状態変更 (`performUnexpectedStopOnMain`) は
    /// 必ず main 上で実行する。
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
        // round-11 review: `stopActive` に一本化。`context` はここで既に
        // identity 確認済みなので、`stopActive` 内部で再度 `currentContext`
        // を読んでも同じインスタンスを指す。`onUnexpectedStop` は
        // `stopActive` が `currentContext` をクリアする前に `context` から
        // 一度だけスナップショットして使う (round-7/8 の TOCTOU 対策を維持)。
        let onUnexpectedStop = context.onUnexpectedStop
        switch stopActive(reason: reason) {
        case .stopped(let sessionID, _):
            onUnexpectedStop(sessionID, reason)
        case .stillRecording:
            // backend がこの時点でも停止を拒否した — stopActive が既に
            // 再試行をスケジュール済み。watchdog が最終的に成功を検出し、
            // この関数を再度通して onUnexpectedStop を呼ぶ。
            klog("AudioRecorder: performUnexpectedStopOnMain — backend still recording after stop attempt, deferring to retry/watchdog")
        case .noActiveSession:
            break
        }
    }

    /// テスト専用の読み取り専用アクセサ: 今アクティブなセッションの
    /// recorder インスタンスを覗き見る (`currentContext.backend` そのもの)。
    /// **round-8 review**: 書き込み用の `setActiveSessionForTesting` は
    /// 廃止した — 「今のセッション」の登録は必ず
    /// `start(sessionID:onUnexpectedStop:)` 経由でのみ行われる (本番と全く
    /// 同じ経路)。これは読み取り専用で、登録には一切関与しない。
    var currentRecorderForTesting: AVAudioRecorder? { currentContext?.backend as? AVAudioRecorder }

    /// テスト専用の読み取り専用アクセサ: `prepare()` が用意した、まだどの
    /// セッションにも属していない pre-warm 済み recorder を覗き見る
    /// (round-10 review — `currentRecorderForTesting` とは別軸)。
    var prewarmedRecorderForTesting: AVAudioRecorder? { prewarmedRecorder }

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
