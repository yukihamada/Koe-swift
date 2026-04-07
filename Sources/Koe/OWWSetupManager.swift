import Foundation

/// openWakeWord 専用 Python venv を ~/Library/Application Support/Koe/oww_venv に自動構築するマネージャー
class OWWSetupManager: ObservableObject {
    static let shared = OWWSetupManager()

    enum State: Equatable {
        case unknown
        case notInstalled
        case installing
        case ready
        case failed(String)

        var isReady: Bool { if case .ready = self { return true }; return false }
    }

    @Published var state: State = .unknown
    @Published var progressMessage: String = ""

    // MARK: - Paths

    private static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Koe")
    }

    static var venvDir: URL { supportDir.appendingPathComponent("oww_venv") }
    static var venvPython: String { venvDir.appendingPathComponent("bin/python3").path }
    static var venvPip: String    { venvDir.appendingPathComponent("bin/pip3").path }

    // MARK: - Check

    /// venv + openWakeWord がインストール済みか確認（非同期）
    func checkInstallation() {
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let python = Self.venvPython
            guard FileManager.default.isExecutableFile(atPath: python) else {
                DispatchQueue.main.async { self.state = .notInstalled }
                return
            }
            // openWakeWord がインポートできるか確認
            let result = self.run(python, args: ["-c", "import openwakeword; print('ok')"])
            DispatchQueue.main.async {
                self.state = result.contains("ok") ? .ready : .notInstalled
            }
        }
    }

    // MARK: - Install

    func install() {
        guard state != .installing else { return }
        state = .installing
        progressMessage = "Python 環境を準備中…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // 1. システム Python3 を探す
            guard let sysPython = self.findSystemPython() else {
                DispatchQueue.main.async {
                    self.state = .failed("Python 3 が見つかりません。Xcode Command Line Tools をインストールしてください。")
                }
                return
            }
            klog("OWWSetup: using system python \(sysPython)")

            // 2. Application Support/Koe/ ディレクトリ作成
            let koeDir = Self.supportDir
            try? FileManager.default.createDirectory(at: koeDir, withIntermediateDirectories: true)

            // 3. venv 作成（既存があればスキップ）
            let venvPath = Self.venvDir.path
            if !FileManager.default.fileExists(atPath: venvPath) {
                self.setProgress("仮想環境を作成中…")
                let out = self.run(sysPython, args: ["-m", "venv", venvPath])
                if !FileManager.default.isExecutableFile(atPath: Self.venvPython) {
                    DispatchQueue.main.async {
                        self.state = .failed("venv 作成失敗: \(out)")
                    }
                    return
                }
            }

            // 4. pip upgrade
            self.setProgress("pip をアップグレード中…")
            _ = self.run(Self.venvPython, args: ["-m", "pip", "install", "--upgrade", "pip", "--quiet"])

            // 5. openWakeWord インストール
            self.setProgress("openWakeWord をインストール中… (初回のみ、数分かかります)")
            let installOut = self.run(Self.venvPython, args: [
                "-m", "pip", "install", "openwakeword", "--quiet"
            ])

            // 6. 確認
            let check = self.run(Self.venvPython, args: ["-c", "import openwakeword; print('ok')"])
            if check.contains("ok") {
                klog("OWWSetup: openWakeWord installed successfully")
                DispatchQueue.main.async {
                    self.state = .ready
                    self.progressMessage = "インストール完了 ✓"
                }
            } else {
                klog("OWWSetup: install failed: \(installOut)")
                DispatchQueue.main.async {
                    self.state = .failed("インストール失敗: \(installOut.suffix(300))")
                }
            }
        }
    }

    // MARK: - Helpers

    private func findSystemPython() -> String? {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // which python3
        let out = run("/usr/bin/which", args: ["python3"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    @discardableResult
    private func run(_ executable: String, args: [String]) -> String {
        let proc = Process()
        proc.launchPath = executable
        proc.arguments  = args
        let pipe = Pipe(); let errPipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = errPipe
        try? proc.run()
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out + err
    }

    private func setProgress(_ msg: String) {
        klog("OWWSetup: \(msg)")
        DispatchQueue.main.async { self.progressMessage = msg }
    }

    // MARK: - カスタムモデル学習

    enum TrainState: Equatable {
        case idle
        case training
        case done(String)   // モデルパス
        case failed(String)
    }

    @Published var trainState: TrainState = .idle
    @Published var trainProgress: String = ""

    static var modelsDir: URL { supportDir.appendingPathComponent("models") }

    /// カスタムウェイクワードを学習して .onnx を生成する
    func trainModel(wakeWordText: String, modelName: String) {
        guard trainState != .training else { return }
        guard state.isReady else {
            trainState = .failed("先に openWakeWord をインストールしてください")
            return
        }
        trainState   = .training
        trainProgress = "学習データを準備中…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let outputDir = Self.modelsDir.path
            try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

            // openwakeword.train モジュールで学習
            self.setTrainProgress("音声サンプルを生成中… (TTS)")
            let out = self.run(Self.venvPython, args: [
                "-m", "openwakeword.train",
                "--training_text", wakeWordText,
                "--model_name", modelName,
                "--output_dir", outputDir,
            ])
            klog("OWWTrain: \(out.suffix(500))")

            let modelPath = "\(outputDir)/\(modelName).onnx"
            if FileManager.default.fileExists(atPath: modelPath) {
                klog("OWWTrain: success → \(modelPath)")
                DispatchQueue.main.async {
                    self.trainState   = .done(modelPath)
                    self.trainProgress = "学習完了 ✓"
                    // 自動的にカスタムモデルパスを設定
                    AppSettings.shared.owwCustomModelPath = modelPath
                }
            } else {
                let errMsg = out.suffix(300)
                klog("OWWTrain: failed — \(errMsg)")
                DispatchQueue.main.async {
                    self.trainState   = .failed("学習失敗: \(errMsg)")
                    self.trainProgress = ""
                }
            }
        }
    }

    private func setTrainProgress(_ msg: String) {
        klog("OWWTrain: \(msg)")
        DispatchQueue.main.async { self.trainProgress = msg }
    }
}
