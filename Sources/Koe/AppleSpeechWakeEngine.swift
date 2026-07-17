import AVFoundation
import Speech

/// Apple オンデバイス音声認識を常時走らせ、文字起こしの中に合言葉が現れたら起動する wake エンジン。
///
/// MFCC テンプレート方式の欠点（話者依存・雑音に弱い・録音が必要）を解消する：
/// - 話者非依存・雑音に強い（Apple の音響モデル）
/// - 合言葉はテキスト設定のみ（録音不要）
/// - `requiresOnDeviceRecognition = true` で音声は端末外に出ない
///
/// マイク（AVAudioEngine）は**常時走らせ続け**、認識リクエストだけを差し替える。
/// こうしないと無音タイムアウト（No speech detected）でマイクが頻繁に落ち、発声を取りこぼす。
/// 検出時はマイクを手放して録音へ引き継ぐ（MFCC エンジンと同じライフサイクル）。
final class AppleSpeechWakeEngine {
    static let shared = AppleSpeechWakeEngine()

    var onDetected: (() -> Void)?
    private(set) var isRunning = false

    private var recognizer: SFSpeechRecognizer?
    /// マイクは毎セッション フレッシュに生成する（シングルトンで使い回すと VPIO 競合で
    /// 取りこぼす）。MFCC エンジンと同じ作法。
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var refreshTimer: Timer?
    private var onDevice = false
    /// 直近の合言葉判定済み文字列（同じ確定結果で多重発火しない）
    private var firedForTranscript = ""

    private init() {}

    func start() {
        guard !isRunning else { return }
        let lang = AppSettings.shared.language
        let locale = lang == "auto" ? Locale.current : Locale(identifier: lang)
        recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: .current)
        guard let recognizer, recognizer.isAvailable else {
            klog("AppleSpeechWake: recognizer 利用不可")
            return
        }
        onDevice = recognizer.supportsOnDeviceRecognition

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else {
                klog("AppleSpeechWake: 音声認識権限なし (\(status.rawValue))")
                return
            }
            DispatchQueue.main.async { self?.beginSession() }
        }
    }

    private func beginSession() {
        guard !isRunning else { return }
        // --- マイクをフレッシュに生成して起動（以後つなぎっぱなし）---
        let engine = AVAudioEngine()
        audioEngine = engine
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in
            self?.request?.append(buf)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            klog("AppleSpeechWake: audio start error \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            audioEngine = nil
            return
        }
        isRunning = true
        startRecognition()
        // 認識リクエストだけを定期更新（マイクは止めない）
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: true) { [weak self] _ in
            self?.cycleRecognition()
        }
        klog("AppleSpeechWake: started (onDevice=\(onDevice), words=\(AppSettings.shared.wakeWords.joined(separator: "/")))")
    }

    /// 認識リクエスト＋タスクを（再）作成。マイクには触れない。
    private func startRecognition() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if onDevice { req.requiresOnDeviceRecognition = true }
        request = req
        firedForTranscript = ""

        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let t = result.bestTranscription.formattedString
                if !t.isEmpty { klog("AppleSpeechWake: heard '\(t.suffix(40))'") }
                self.handleTranscript(t)
            }
            if error != nil || (result?.isFinal ?? false) {
                // 無音タイムアウト等 → 認識だけ即再開（マイクは継続）
                if self.isRunning { DispatchQueue.main.async { self.cycleRecognition() } }
            }
        }
    }

    private func cycleRecognition() {
        guard isRunning else { return }
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        startRecognition()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        refreshTimer?.invalidate(); refreshTimer = nil
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
        audioEngine = nil
        klog("AppleSpeechWake: stopped")
    }

    // MARK: - 合言葉判定

    private func handleTranscript(_ transcript: String) {
        guard transcript != firedForTranscript else { return }
        let tail = Self.normalize(String(transcript.suffix(24)))
        for phrase in AppSettings.shared.wakeWords {
            let p = Self.normalize(phrase)
            guard !p.isEmpty else { continue }
            if tail.contains(p) {
                firedForTranscript = transcript
                klog("AppleSpeechWake: 合言葉検出 '\(phrase)' in '\(transcript.suffix(30))'")
                DispatchQueue.main.async {
                    self.stop()
                    self.onDetected?()
                }
                return
            }
        }
    }

    /// カナ違い・空白・大小を吸収して比較。
    private static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
        return lowered.applyingTransform(.hiraganaToKatakana, reverse: false) ?? lowered
    }
}
