import AVFoundation
import Foundation

/// openWakeWord を Python サブプロセス経由で実行するウェイクワードエンジン
/// pip install openwakeword が必要
class OWWEngine {
    static let shared = OWWEngine()

    var onDetected: (() -> Void)?
    private(set) var isRunning = false
    private(set) var lastError: String = ""
    private(set) var isReady = false   // Python プロセスが "READY" を返した後

    private var process: Process?
    private var audioEngine: AVAudioEngine?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var targetFmt: AVAudioFormat?

    private static let targetRate: Double = 16000

    // MARK: - Python path (venv 優先)

    static var pythonPath: String {
        // 専用 venv が使える場合はそちらを優先
        let venv = OWWSetupManager.venvPython
        if FileManager.default.isExecutableFile(atPath: venv) { return venv }
        // フォールバック: システム Python
        for path in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/usr/bin/python3"
    }

    // MARK: - Script path (bundle Resources or source tree dev fallback)

    private static var scriptPath: String {
        if let p = Bundle.main.path(forResource: "oww_detector", ofType: "py") { return p }
        // 開発時: ソースツリーの Resources/ を参照
        let url = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()          // Sources/Koe/
            .deletingLastPathComponent()          // Sources/
            .deletingLastPathComponent()          // project root
            .appendingPathComponent("Resources/oww_detector.py")
        return url.path
    }

    // MARK: - Start

    func start() {
        guard !isRunning else { return }
        let python = Self.pythonPath
        let script = Self.scriptPath
        guard FileManager.default.fileExists(atPath: script) else {
            lastError = "oww_detector.py が見つかりません (\(script))"
            klog("OWWEngine: \(lastError)")
            return
        }

        let proc   = Process()
        let stdin  = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.launchPath     = python
        proc.arguments      = [script]
        proc.standardInput  = stdin
        proc.standardOutput = stdout
        proc.standardError  = stderr

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.isReady   = false
            }
            klog("OWWEngine: process terminated")
        }

        do { try proc.run() } catch {
            lastError = "起動失敗: \(error)"
            klog("OWWEngine: \(lastError)")
            return
        }

        process    = proc
        stdinPipe  = stdin
        stdoutPipe = stdout
        isRunning  = true
        isReady    = false
        lastError  = ""

        // Config JSON を1行目として送る
        let s = AppSettings.shared
        var cfg: [String: Any] = ["threshold": s.owwThreshold]
        if !s.owwModelName.isEmpty { cfg["models"] = [s.owwModelName] }
        if !s.owwCustomModelPath.isEmpty { cfg["custom_model_paths"] = [s.owwCustomModelPath] }
        if let json = try? JSONSerialization.data(withJSONObject: cfg),
           let line = String(data: json, encoding: .utf8) {
            stdin.fileHandleForWriting.write((line + "\n").data(using: .utf8)!)
        }

        // stdout 監視
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for rawLine in text.components(separatedBy: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                if line == "READY" {
                    klog("OWWEngine: ready ✓")
                    DispatchQueue.main.async { self.isReady = true }
                } else if line.hasPrefix("DETECTED:") {
                    klog("OWWEngine: \(line)")
                    DispatchQueue.main.async {
                        self.stop()
                        self.onDetected?()
                    }
                } else if line.hasPrefix("ERROR:") {
                    let msg = String(line.dropFirst(6))
                    klog("OWWEngine error: \(msg)")
                    DispatchQueue.main.async { self.lastError = msg }
                }
            }
        }

        startAudio()
        klog("OWWEngine: started (python=\(python), model=\(s.owwModelName), threshold=\(s.owwThreshold))")
    }

    // MARK: - Stop

    func stop() {
        guard isRunning else { return }
        isRunning = false
        isReady   = false
        stopAudio()
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe?.fileHandleForWriting.close()
        process?.terminate()
        process   = nil
        stdinPipe = nil
        stdoutPipe = nil
        klog("OWWEngine: stopped")
    }

    // MARK: - Audio

    private func startAudio() {
        let engine = AVAudioEngine()
        audioEngine = engine
        let node   = engine.inputNode
        let natFmt = node.outputFormat(forBus: 0)
        if targetFmt == nil {
            targetFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: Self.targetRate,
                                      channels: 1, interleaved: false)
        }
        guard let tgtFmt = targetFmt,
              let conv   = AVAudioConverter(from: natFmt, to: tgtFmt) else { return }

        node.installTap(onBus: 0, bufferSize: 4096, format: natFmt) { [weak self] buf, _ in
            guard let self, self.isRunning else { return }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * Self.targetRate / buf.format.sampleRate + 1)
            guard let out = AVAudioPCMBuffer(pcmFormat: tgtFmt, frameCapacity: cap) else { return }
            var done = false
            conv.convert(to: out, error: nil) { _, st in
                if done { st.pointee = .noDataNow; return buf }
                done = true; st.pointee = .haveData; return buf
            }
            if let ch = out.floatChannelData?[0] {
                let samples = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
                let data    = samples.withUnsafeBytes { Data($0) }
                try? self.stdinPipe?.fileHandleForWriting.write(contentsOf: data)
            }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            klog("OWWEngine: audio error \(error)")
            isRunning = false
        }
    }

    private func stopAudio() {
        if let e = audioEngine {
            if e.isRunning { e.stop() }
            e.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
    }

    // MARK: - Available pre-trained models

    static let pretrainedModels: [(id: String, label: String)] = [
        ("hey_jarvis",    "Hey Jarvis"),
        ("alexa",         "Alexa"),
        ("hey_mycroft",   "Hey Mycroft"),
        ("hey_rhasspy",   "Hey Rhasspy"),
        ("computer",      "Computer"),
        ("current_time",  "What time is it?"),
    ]
}
