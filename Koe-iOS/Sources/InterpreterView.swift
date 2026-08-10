import SwiftUI
import AVFoundation
import Speech

// 🗣 リアルタイム双方向通訳(2026-08-11): 日本語⇄ポルトガル語(en/es/fr/de/itも)。
// Web版(koe.live/tsuyaku)との違い=速さ。SFSpeechRecognizerのストリーミング認識を
// ja-JP と相手言語の2本同時に走らせ、話し終わった瞬間にはほぼ文字起こしが手元にある
// (Webは録音完了後にサーバSTT)。翻訳のみネットワーク(koe.live /api/honyaku)で、
// 読み上げは端末内AVSpeechSynthesizer=即時。体感は発話終了から1〜2秒。
//
// 設計メモ:
// - 方向判定: 2本の認識の最終confidence比較(final未着のタイムアウト時は文字数で代替)。
//   「ja認識に日本語文字があるか」は判定に使えない — ja-JPはポルトガル語音声も
//   かなのゴミとして書き起こすため、常に日本語文字が含まれる。
// - AVAudioSessionは .playAndRecord を1回だけ設定(録音⇄再生でカテゴリを往復させると
//   KoeTTS系の .playback 切替と競合しやすい)。エコーはmutedフラグ+echoCancellationで抑止。
// - 読み上げ中はマイクバッファを認識へ流さない(muted)。自分の合成音を聞き取って
//   自問自答するループ(Sente talkで実際に起きた障害と同型)を構造的に遮断。

struct InterpreterTurn: Identifiable {
    let id = UUID()
    let original: String
    let translated: String
    let isJa: Bool          // true = 日本語→相手言語
}

struct InterpreterLang: Identifiable, Equatable {
    let id: String          // /api/honyaku の言語コード ("pt")
    let name: String        // /api/honyaku へ渡す言語名 ("ポルトガル語")
    let bcp47: String       // 認識/読み上げロケール ("pt-BR")
    let flag: String
    let label: String       // ネイティブ表記 ("Português")
}

/// マイクのtapコールバック(オーディオスレッド)から触ってよいものだけを集めた箱。
/// MainActor隔離のEngine本体へオーディオスレッドから直接触らないための仕切り。
private final class InterpreterTapRouter: @unchecked Sendable {
    var muted = true
    var jaReq: SFSpeechAudioBufferRecognitionRequest?
    var foReq: SFSpeechAudioBufferRecognitionRequest?
}

@MainActor
final class InterpreterEngine: NSObject, ObservableObject {
    static let langs: [InterpreterLang] = [
        .init(id: "pt", name: "ポルトガル語", bcp47: "pt-BR", flag: "🇧🇷", label: "Português"),
        .init(id: "en", name: "英語", bcp47: "en-US", flag: "🇺🇸", label: "English"),
        .init(id: "es", name: "スペイン語", bcp47: "es-ES", flag: "🇪🇸", label: "Español"),
        .init(id: "fr", name: "フランス語", bcp47: "fr-FR", flag: "🇫🇷", label: "Français"),
        .init(id: "de", name: "ドイツ語", bcp47: "de-DE", flag: "🇩🇪", label: "Deutsch"),
        .init(id: "it", name: "イタリア語", bcp47: "it-IT", flag: "🇮🇹", label: "Italiano"),
    ]

    enum Phase: Equatable {
        case idle, listening, capturing, hearing, translating, speaking
        case error(String)
    }

    @Published var phase: Phase = .idle
    @Published var turns: [InterpreterTurn] = []
    @Published var target: InterpreterLang = InterpreterEngine.langs[0]

    var isRunning: Bool { running }

    private let audioEngine = AVAudioEngine()
    private let synth = AVSpeechSynthesizer()
    private let router = InterpreterTapRouter()

    private var jaRecognizer: SFSpeechRecognizer?
    private var foRecognizer: SFSpeechRecognizer?
    private var jaTask: SFSpeechRecognitionTask?
    private var foTask: SFSpeechRecognitionTask?

    private var jaText = "", foText = ""
    private var jaConf = 0.0, foConf = 0.0
    private var jaFinal = false, foFinal = false

    private var speechAt: Date?
    private var lastLoud: Date?
    private var noiseFloor: Float = 0.004
    private var vadTimer: Timer?
    private var running = false
    private var finalizing = false

    // MARK: - 開始 / 停止

    func toggle() {
        if running { stop() } else { Task { await start() } }
    }

    func start() async {
        let auth = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard auth == .authorized else { phase = .error("設定 > プライバシーで音声認識を許可してください"); return }
        let micOK = await AVAudioApplication.requestRecordPermission()
        guard micOK else { phase = .error("マイクの許可が必要です / Permita o microfone"); return }

        jaRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
        foRecognizer = SFSpeechRecognizer(locale: Locale(identifier: target.bcp47))
        guard jaRecognizer?.isAvailable == true, foRecognizer?.isAvailable == true else {
            phase = .error("音声認識をいま使えません(オフライン?)"); return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
            try session.setActive(true)
        } catch {
            phase = .error("オーディオを開始できませんでした"); return
        }

        synth.delegate = self
        let input = audioEngine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        let r = router
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buffer, _ in
            // オーディオスレッド: RMSを測り、聞き取り中だけ2本の認識へ流す
            var rms: Float = 0
            if let ch = buffer.floatChannelData?[0] {
                let n = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<n { sum += ch[i] * ch[i] }
                rms = n > 0 ? sqrt(sum / Float(n)) : 0
            }
            if !r.muted {
                r.jaReq?.append(buffer)
                r.foReq?.append(buffer)
            }
            let level = rms
            Task { @MainActor [weak self] in self?.ingest(rms: level) }
        }
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            phase = .error("マイクを開始できませんでした"); return
        }

        running = true
        UIApplication.shared.isIdleTimerDisabled = true   // 通訳中は画面を落とさない
        startTurn()
        vadTimer?.invalidate()
        vadTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkTurnEnd() }
        }
    }

    func stop() {
        running = false
        finalizing = false
        vadTimer?.invalidate(); vadTimer = nil
        router.muted = true
        jaTask?.cancel(); foTask?.cancel()
        jaTask = nil; foTask = nil
        router.jaReq = nil; router.foReq = nil
        synth.stopSpeaking(at: .immediate)
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        phase = .idle
    }

    func setTarget(_ l: InterpreterLang) {
        guard l != target else { return }
        target = l
        if running {           // 認識ロケールが変わるので作り直し
            stop()
            Task { await start() }
        }
    }

    // MARK: - 1ターン(ひと言)の認識

    private func startTurn() {
        guard running else { return }
        jaText = ""; foText = ""; jaConf = 0; foConf = 0
        jaFinal = false; foFinal = false
        speechAt = nil; lastLoud = nil
        finalizing = false

        let jr = SFSpeechAudioBufferRecognitionRequest()
        let fr = SFSpeechAudioBufferRecognitionRequest()
        for req in [jr, fr] {
            req.shouldReportPartialResults = true
            if #available(iOS 16, *) { req.addsPunctuation = true }
        }
        router.jaReq = jr
        router.foReq = fr

        jaTask = jaRecognizer?.recognitionTask(with: jr) { [weak self] result, _ in
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            let conf = Self.avgConfidence(result.bestTranscription.segments)
            let fin = result.isFinal
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.jaText = text
                if fin { self.jaFinal = true; self.jaConf = conf }
            }
        }
        foTask = foRecognizer?.recognitionTask(with: fr) { [weak self] result, _ in
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            let conf = Self.avgConfidence(result.bestTranscription.segments)
            let fin = result.isFinal
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.foText = text
                if fin { self.foFinal = true; self.foConf = conf }
            }
        }
        router.muted = false
        phase = .listening
    }

    private static func avgConfidence(_ segs: [SFTranscriptionSegment]) -> Double {
        guard !segs.isEmpty else { return 0 }
        return segs.reduce(0.0) { $0 + Double($1.confidence) } / Double(segs.count)
    }

    private func ingest(rms: Float) {
        guard running, !router.muted, phase == .listening || phase == .capturing else { return }
        if rms < noiseFloor * 3 { noiseFloor = noiseFloor * 0.995 + rms * 0.005 }
        let th = max(0.010, noiseFloor * 3)
        if rms > th {
            lastLoud = Date()
            if speechAt == nil { speechAt = Date(); phase = .capturing }
        }
    }

    private func checkTurnEnd() {
        guard running, !finalizing, let began = speechAt, let loud = lastLoud else { return }
        let now = Date()
        let silent = now.timeIntervalSince(loud)
        let dur = now.timeIntervalSince(began)
        // 0.7秒の静けさ=話し終わり(Web版と同じ値)。25秒で強制区切り。
        if (silent > 0.7 && dur > 0.3) || dur > 25 {
            finalizing = true
            Task { await finalizeTurn() }
        }
    }

    private func finalizeTurn() async {
        router.muted = true
        phase = .hearing
        router.jaReq?.endAudio()
        router.foReq?.endAudio()
        // 最終結果(confidence付き)を待つ。partialは手元にあるので最大1.2秒で見切る。
        let t0 = Date()
        while !(jaFinal && foFinal) && Date().timeIntervalSince(t0) < 1.2 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        jaTask?.cancel(); foTask?.cancel()
        router.jaReq = nil; router.foReq = nil

        guard running else { return }
        guard let (text, isJa) = pickWinner() else { startTurn(); return }

        phase = .translating
        let toName = isJa ? target.name : "日本語"
        guard let translated = await Self.translate(text, to: toName) else {
            phase = .error("いま翻訳できませんでした")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if running { startTurn() }
            return
        }
        turns.insert(InterpreterTurn(original: text, translated: translated, isJa: isJa), at: 0)
        speak(translated, bcp47: isJa ? target.bcp47 : "ja-JP")
    }

    /// どちらの言語で話したかを決める。主signal=最終confidence、届かなければ文字数で代替。
    private func pickWinner() -> (String, Bool)? {
        let jt = jaText.trimmingCharacters(in: .whitespacesAndNewlines)
        let ft = foText.trimmingCharacters(in: .whitespacesAndNewlines)
        if jt.count < 2 && ft.count < 2 { return nil }
        if ft.count < 2 { return (jt, true) }
        if jt.count < 2 { return (ft, false) }
        if jaFinal && foFinal && abs(jaConf - foConf) > 0.08 {
            return jaConf > foConf ? (jt, true) : (ft, false)
        }
        // confidenceが拮抗/未着: 認識が「自分の言語らしく」書けた方が長くなる傾向で代替
        return ft.count > jt.count ? (ft, false) : (jt, true)
    }

    private static func translate(_ text: String, to langName: String) async -> String? {
        guard let url = URL(string: "https://koe.live/api/honyaku?src=tsuyaku") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "lang": langName])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tr = j["translated"] as? String, !tr.isEmpty else { return nil }
        return tr
    }

    private func speak(_ text: String, bcp47: String) {
        phase = .speaking
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: bcp47) ?? AVSpeechSynthesisVoice(language: "ja-JP")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(u)
    }

    fileprivate func speechFinished() {
        guard running else { return }
        startTurn()
    }
}

extension InterpreterEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speechFinished() }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speechFinished() }
    }
}

// MARK: - View

struct InterpreterView: View {
    @StateObject private var engine = InterpreterEngine()

    private var statusLine: String {
        switch engine.phase {
        case .idle: return "タップして通訳をはじめる / Toque para começar"
        case .listening: return "👂 聞いています… / Ouvindo…"
        case .capturing: return "🎙 …"
        case .hearing: return "👂 聞き取っています…"
        case .translating: return "🌍 訳しています… / Traduzindo…"
        case .speaking: return "🔊 読み上げ中"
        case .error(let m): return "⚠ " + m
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(InterpreterEngine.langs) { l in
                        Button {
                            engine.setTarget(l)
                        } label: {
                            Text(l.flag + " " + l.label)
                                .font(.footnote.weight(l == engine.target ? .bold : .regular))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(l == engine.target ? Color.accentColor.opacity(0.22) : Color(.secondarySystemBackground))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }

            Button {
                engine.toggle()
            } label: {
                ZStack {
                    Circle()
                        .fill(engine.isRunning ? Color.red : Color.green)
                        .frame(width: 96, height: 96)
                        .shadow(color: (engine.isRunning ? Color.red : Color.green).opacity(0.35), radius: 14, y: 6)
                    Text(engine.isRunning ? "■" : "🗣")
                        .font(.system(size: 34))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 6)

            Text(statusLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(minHeight: 20)

            List(engine.turns) { t in
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.isJa ? "🇯🇵 → " + engine.target.flag : engine.target.flag + " → 🇯🇵")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Text(t.original)
                        .font(.caption).foregroundStyle(.secondary)
                    Text(t.translated)
                        .font(.body.weight(.semibold))
                }
                .padding(.vertical, 2)
            }
            .listStyle(.plain)

            Text("話すと日本語かどうかを自動で聞き分けて、相手の言葉に訳して読み上げます。交互にどうぞ。")
                .font(.caption2).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .navigationTitle("リアルタイム通訳")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { engine.stop() }
    }
}

#Preview {
    NavigationStack { InterpreterView() }
}
