import Foundation

/// ハンズフリー継続会話セッション。
///
/// wake で一度起こすと「会話モード」に入り、以降は沈黙でターンが確定するたびに
/// 認識テキストを分類（停止語 / コマンド / 雑談）してルーティングし、再ウェイク無しで
/// 次ターンの録音を自動アームする。停止語または無活動タイムアウトで終了して wake 待受へ戻る。
///
/// 録音・VAD・認識の本体は AppDelegate に残し、本クラスは「いつ次ターンを始めるか」
/// 「停止語か」「コマンドか雑談か」の判断だけを持つ（疎結合）。
final class ConversationSession {
    static let shared = ConversationSession()
    private init() {}

    private(set) var isActive = false
    private var lastActivity = Date()
    private var timeoutTimer: Timer?
    private var nextTurnScheduled = false
    /// 破壊的コマンドの実行待ち（次ターンの「はい/やめて」で確定）。
    private var pendingConfirmation: (() -> Void)?
    /// このセッションで実際に何か（コマンド/口述）が起きたか＝wake が本物だったか。
    private var productive = false
    /// 連続して空振りした wake の回数（OWW しきい値の自動微調整に使う・誤爆対策）。
    private static var unproductiveWakes = 0

    // MARK: ライフサイクル

    /// wake 検出時（conversationModeEnabled 時のみ呼ばれる）。
    func handleWakeDetected() {
        guard AppSettings.shared.conversationModeEnabled else {
            AppDelegate.shared?.beginSessionTurn()
            return
        }
        if isActive { return }
        // 常時 wake 検出器を止めてマイクを解放（各ターンは startRecording の実績ある経路を使う）
        WakeWordDetector.shared.stop()
        isActive = true
        nextTurnScheduled = false
        pendingConfirmation = nil
        productive = false
        SoundFeedback.shared.play(.wake)
        noteActivity()
        startTimeoutWatch()
        if AppSettings.shared.numberOverlayAlwaysOn { NumberOverlayController.shared.show() }
        if AppSettings.shared.gestureEnabled { GestureEngine.shared.start() }
        AppDelegate.shared?.showSessionHud("🎙 音声モード — 話してください（「おわり」で終了）")
        klog("ConversationSession: started")
        AppDelegate.shared?.beginSessionTurn()
    }

    func endSession(reason: String) {
        guard isActive else { return }
        isActive = false
        nextTurnScheduled = false
        pendingConfirmation = nil
        timeoutTimer?.invalidate(); timeoutTimer = nil
        NumberOverlayController.shared.hide()
        GestureEngine.shared.stop()
        TTSService.shared.stop()
        SoundFeedback.shared.play(.sessionEnd)
        adjustWakeThreshold()
        klog("ConversationSession: ended (\(reason), productive=\(productive))")
        AppDelegate.shared?.restartWakeAfterSession()
    }

    /// openWakeWord 使用時、連続して空振りした wake が続いたらしきい値を少し上げる（誤爆抑制）。
    /// 実りのある wake が来たらカウンタをリセット。自動で下げはしない（発振防止）。
    private func adjustWakeThreshold() {
        guard AppSettings.shared.wakeWordEngineType == .openWakeWord else { return }
        if productive {
            Self.unproductiveWakes = 0
            return
        }
        Self.unproductiveWakes += 1
        if Self.unproductiveWakes >= 3 {
            let newT = min(0.7, AppSettings.shared.owwThreshold + 0.05)
            if abs(newT - AppSettings.shared.owwThreshold) > 0.001 {
                AppSettings.shared.owwThreshold = newT
                klog("ConversationSession: 空振り wake 連続 → owwThreshold を \(newT) へ上げる")
            }
            Self.unproductiveWakes = 0
        }
    }

    func noteActivity() { lastActivity = Date() }

    // MARK: ジェスチャー入口（GestureEngine から）

    /// 👍: 確認待ちがあれば承認。無ければ何もしない（カメラ誤検出で勝手に送信しない）。
    func gestureAffirm() {
        noteActivity()
        guard let action = pendingConfirmation else { return }
        pendingConfirmation = nil
        productive = true
        SoundFeedback.shared.play(.turnEnd)
        action()
    }

    /// 👎: 確認待ちを却下。
    func gestureCancel() {
        noteActivity()
        if pendingConfirmation != nil {
            pendingConfirmation = nil
            TTSService.shared.speak("やめました")
        }
    }

    /// 次ターンの録音をアーム（多重スケジュール防止つき＝冪等）。
    func scheduleNextTurn() {
        guard isActive, !nextTurnScheduled else { return }
        nextTurnScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isActive else { return }
            self.nextTurnScheduled = false
            if AppDelegate.shared?.isRecordingPublic == true { return }
            AppDelegate.shared?.beginSessionTurn()
        }
    }

    // MARK: ターン分類

    /// 認識テキストを分類してルーティングする。
    /// 戻り値 true: セッションが消費（コマンド/停止語/雑談無視）。
    /// 戻り値 false: パススルー（呼び出し側で通常のテキスト入力＝口述を行う）。
    func handleTurn(_ text: String) -> Bool {
        noteActivity()
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { AppDelegate.shared?.sessionTurnConsumed(); return true }

        // 確認待ち（はい/やめて）
        if let action = pendingConfirmation {
            pendingConfirmation = nil
            if isAffirmative(t) {
                SoundFeedback.shared.play(.turnEnd)
                action()
            } else {
                TTSService.shared.speak("やめました")
                AppDelegate.shared?.sessionTurnConsumed()
            }
            return true
        }

        // 停止語
        if isStopWord(t) { endSession(reason: "stopword"); AppDelegate.shared?.hideOverlayForSession(); return true }

        // コマンド（高速マッチ: cockpit + system 等）
        if let command = AgentMode.shared.detectCommand(t) {
            productive = true
            if isDestructive(command) {
                SoundFeedback.shared.play(.confirm)
                TTSService.shared.speak("\(command.description) を実行します。よろしいですか")
                pendingConfirmation = { AppDelegate.shared?.executeSessionCommand(command) }
                AppDelegate.shared?.sessionTurnConsumed()
                return true
            }
            AppDelegate.shared?.executeSessionCommand(command)
            return true
        }

        // 非コマンド発話
        if AppSettings.shared.conversationDictationFallback {
            productive = true
            return false  // パススルー → 口述挿入
        }
        // 既定: 雑談/環境音とみなして無視（誤挿入回避）
        klog("ConversationSession: ignored non-command speech '\(t.prefix(30))'")
        AppDelegate.shared?.sessionTurnConsumed()
        return true
    }

    // MARK: 判定ヘルパー

    func isStopWord(_ text: String) -> Bool {
        // 句読点を落とした「丸ごと一致」のみ（「もういいかな」等で誤終了しない）
        let t = Self.stripPunct(text)
        return AppSettings.shared.conversationStopWords.contains { !$0.isEmpty && t == Self.stripPunct($0) }
    }

    private func isAffirmative(_ text: String) -> Bool {
        let yes = ["はい", "うん", "イエス", "yes", "ok", "オーケー", "おっけー", "お願いします", "お願い", "いいよ", "やって"]
        let t = Self.stripPunct(text).lowercased()
        // 発話全体が承認語そのものの時だけ承認（「OKだけど違う」等を弾く）
        return yes.contains { t == $0.lowercased() }
    }

    private static func stripPunct(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。、．，.!?！？　 "))
    }

    private func isDestructive(_ command: AgentCommand) -> Bool {
        switch command {
        case .shellCommand, .sleep, .lockScreen: return true
        default: return false
        }
    }

    // MARK: タイムアウト

    private func startTimeoutWatch() {
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.isActive else { return }
            let idle = Date().timeIntervalSince(self.lastActivity)
            if idle >= AppSettings.shared.conversationSessionTimeoutSec {
                self.endSession(reason: "timeout")
            }
        }
    }
}
