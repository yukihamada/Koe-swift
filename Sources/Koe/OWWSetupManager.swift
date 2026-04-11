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

    /// venv + openWakeWord + モデルファイルがインストール済みか確認（非同期）
    func checkInstallation() {
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let python = Self.venvPython
            guard FileManager.default.isExecutableFile(atPath: python) else {
                DispatchQueue.main.async { self.state = .notInstalled }
                return
            }
            // openWakeWord の import + 必須モデルファイル（melspectrogram.onnx）の存在を1発で確認
            let check = self.run(python, args: [
                "-c",
                """
                import openwakeword, os
                mdir = os.path.join(os.path.dirname(openwakeword.__file__), 'resources', 'models')
                ok_import = True
                ok_model  = os.path.exists(os.path.join(mdir, 'melspectrogram.onnx'))
                print('import_ok' if ok_import else 'import_missing')
                print('model_ok' if ok_model else 'model_missing')
                """
            ])
            let importOK = check.contains("import_ok")
            let modelOK  = check.contains("model_ok")

            // import は通るがモデルだけ無い → 自己修復（download_models のみ実行）
            if importOK && !modelOK {
                klog("OWWSetup: models missing, self-healing via download_models()")
                DispatchQueue.main.async { self.progressMessage = "モデルファイルをダウンロード中…" }
                let dl = self.run(python, args: [
                    "-c",
                    "from openwakeword.utils import download_models; download_models(); print('ok')"
                ])
                let healed = dl.contains("ok")
                klog("OWWSetup: self-heal \(healed ? "ok" : "failed: \(dl.suffix(200))")")
                DispatchQueue.main.async {
                    self.state = healed ? .ready : .notInstalled
                    if healed { self.progressMessage = "" }
                }
                return
            }

            DispatchQueue.main.async {
                self.state = (importOK && modelOK) ? .ready : .notInstalled
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

            // 6. import できるか
            let check = self.run(Self.venvPython, args: ["-c", "import openwakeword; print('ok')"])
            guard check.contains("ok") else {
                klog("OWWSetup: install failed: \(installOut)")
                DispatchQueue.main.async {
                    self.state = .failed("インストール失敗: \(installOut.suffix(300))")
                }
                return
            }
            klog("OWWSetup: openWakeWord package installed")

            // 7. プリセットモデル本体をダウンロード（これが無いと Model() がロード失敗する）
            //    既存ファイルは上書きされないので毎回呼んでOK
            self.setProgress("ウェイクワードモデルをダウンロード中… (約13MB)")
            let dlOut = self.run(Self.venvPython, args: [
                "-c",
                "from openwakeword.utils import download_models; download_models(); print('ok')"
            ])
            guard dlOut.contains("ok") else {
                klog("OWWSetup: download_models failed: \(dlOut)")
                DispatchQueue.main.async {
                    self.state = .failed("モデルDL失敗: \(dlOut.suffix(300))")
                }
                return
            }
            klog("OWWSetup: model files downloaded")

            DispatchQueue.main.async {
                self.state = .ready
                self.progressMessage = "インストール完了 ✓"
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

    /// カスタムウェイクワードをクラウドで学習して .onnx をダウンロードする。
    ///
    /// フロー:
    ///   1. POST {endpoint}/v1/wake/train {text, model_name, lang}  → 202 {job_id}
    ///   2. GET  {endpoint}/v1/wake/train/{job_id}                   → {status, progress, onnx_url}
    ///      15秒間隔でポーリング、done/failed になるまで
    ///   3. GET  {onnx_url} → ローカルに保存して AppSettings.owwCustomModelPath に設定
    ///
    /// オンデバイス学習は piper-sample-generator + torch + 数GB の依存を必要とするため
    /// 採用していない。サーバー側 (koe-wake-train) がその重い処理を肩代わりする。
    func trainModel(wakeWordText: String, modelName: String) {
        guard trainState != .training else { return }
        guard state.isReady else {
            trainState = .failed("先に openWakeWord をインストールしてください")
            return
        }

        let endpoint = AppSettings.shared.wakeTrainEndpoint
        guard !endpoint.isEmpty, let base = URL(string: endpoint) else {
            trainState = .failed("カスタム学習サーバーが設定されていません。設定からエンドポイントを指定するか、プリセットのウェイクワードをご利用ください。")
            return
        }

        trainState   = .training
        trainProgress = "学習リクエストを送信中…"

        let outputDir = Self.modelsDir.path
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        let savePath = "\(outputDir)/\(modelName).onnx"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            CloudWakeTrainer(base: base).train(
                text: wakeWordText,
                modelName: modelName,
                savePath: savePath,
                progress: { [weak self] msg in
                    klog("OWWTrain(cloud): \(msg)")
                    DispatchQueue.main.async { self?.trainProgress = msg }
                },
                completion: { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        switch result {
                        case .success(let path):
                            klog("OWWTrain(cloud): success → \(path)")
                            self.trainState   = .done(path)
                            self.trainProgress = "学習完了 ✓"
                            AppSettings.shared.owwCustomModelPath = path
                        case .failure(let err):
                            klog("OWWTrain(cloud): failed — \(err.localizedDescription)")
                            self.trainState   = .failed("学習失敗: \(err.localizedDescription)")
                            self.trainProgress = ""
                        }
                    }
                }
            )
        }
    }

    private func setTrainProgress(_ msg: String) {
        klog("OWWTrain: \(msg)")
        DispatchQueue.main.async { self.trainProgress = msg }
    }
}
