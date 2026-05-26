import Foundation
import AppKit
import CryptoKit

/// 利用可能なモデル定義
struct WhisperModel {
    let id: String
    let name: String
    let description: String
    let fileName: String
    let url: String
    let sizeMB: Int
    let isDefault: Bool
    /// 対応言語コード（空=多言語対応）。"ja", "zh", "ko" などの2文字コード。
    let targetLanguages: [String]
    /// 期待される SHA256 (16進小文字)。nil なら検証スキップ。
    /// HuggingFace の LFS oid (`/api/models/<repo>/tree/main` の `.lfs.oid`) を貼る。
    let expectedSHA256: String?

    init(id: String, name: String, description: String, fileName: String, url: String, sizeMB: Int, isDefault: Bool, targetLanguages: [String] = [], expectedSHA256: String? = nil) {
        self.id = id; self.name = name; self.description = description
        self.fileName = fileName; self.url = url; self.sizeMB = sizeMB
        self.isDefault = isDefault; self.targetLanguages = targetLanguages
        self.expectedSHA256 = expectedSHA256
    }

    /// 後方互換: isJapaneseOnly
    var isJapaneseOnly: Bool { targetLanguages == ["ja"] }

    var displayString: String {
        "\(name) (\(sizeMB)MB)"
    }

    /// この言語コードに対応しているか
    func supportsLanguage(_ langCode: String) -> Bool {
        if targetLanguages.isEmpty { return true } // 多言語モデル
        let prefix = langCode.components(separatedBy: "-").first ?? langCode
        return targetLanguages.contains(prefix) || langCode == "auto"
    }
}

/// whisper モデルを HuggingFace からダウンロードする。
class ModelDownloader {
    static let shared = ModelDownloader()

    /// 利用可能なモデル一覧
    static let availableModels: [WhisperModel] = [
        // ── 日本語特化 ──
        WhisperModel(
            id: "kotoba-v2-q5",
            name: "Kotoba v2.0 Q5",
            description: "日本語特化・高精度・軽量",
            fileName: "ggml-kotoba-whisper-v2.0-q5_0.bin",
            url: "https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0-ggml/resolve/main/ggml-kotoba-whisper-v2.0-q5_0.bin",
            sizeMB: 538,
            isDefault: false,
            targetLanguages: ["ja"],
            expectedSHA256: "4a3b92192b5d3578ff854a5876213e2e27af0c2d357492c2d14271e82c303658"
        ),
        WhisperModel(
            id: "kotoba-v2-full",
            name: "Kotoba v2.0 Full",
            description: "日本語特化・最高精度",
            fileName: "ggml-kotoba-whisper-v2.0.bin",
            url: "https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0-ggml/resolve/main/ggml-kotoba-whisper-v2.0.bin",
            sizeMB: 1520,
            isDefault: false,
            targetLanguages: ["ja"],
            expectedSHA256: "eff70a8a236e731abba774ba71e1f6d0fce53302137208c32207e694e0bf4546"
        ),
        // ── 中国語特化 (Belle) ──
        WhisperModel(
            id: "belle-zh-turbo",
            name: "Belle 中文 Turbo",
            description: "中国語特化・24-64%精度向上",
            fileName: "ggml-belle-whisper-large-v3-turbo-zh.bin",
            url: "https://huggingface.co/BELLE-2/Belle-whisper-large-v3-turbo-zh-ggml/resolve/main/ggml-model.bin",
            sizeMB: 1620,
            isDefault: false,
            targetLanguages: ["zh"],
            expectedSHA256: "2a3bba5bfdb4d4da3d9949a83b405711727ca1941d4d5810895e077eb3cb4d99"
        ),
        // ── 韓国語特化 ──
        // 旧 URL `ggml-model.bin` は upstream リポジトリに存在せず 404 を返していたため、
        // 同リポジトリの実ファイル名 `whisper-medium-korean.bin` に差し替え。
        WhisperModel(
            id: "korean-medium",
            name: "Korean Medium",
            description: "한국어특화・WER 16%",
            fileName: "ggml-whisper-medium-korean.bin",
            url: "https://huggingface.co/royshilkrot/whisper-medium-korean-ggml/resolve/main/whisper-medium-korean.bin",
            sizeMB: 1500,
            isDefault: false,
            targetLanguages: ["ko"],
            expectedSHA256: "7e7c0e7b758d175874e80819838bad724c786869835cd0008725b7fc7978768e"
        ),
        // ── フランス語特化 (Q5量子化あり) ──
        WhisperModel(
            id: "french-large-v3-q5",
            name: "French Large V3 Q5",
            description: "Français特化・高精度・軽量",
            fileName: "ggml-whisper-large-v3-french-q5_0.bin",
            url: "https://huggingface.co/bofenghuang/whisper-large-v3-french/resolve/main/ggml-model-q5_0.bin",
            sizeMB: 1080,
            isDefault: false,
            targetLanguages: ["fr"],
            expectedSHA256: "d8da7cb6cdadfac47829abf46fe8cd36fcfef06db5601bfd8acbcd40579010a5"
        ),
        // ── イタリア語特化 (蒸留+Q5、超軽量) ──
        WhisperModel(
            id: "italian-distil-q5",
            name: "Italian Distil Q5",
            description: "Italiano特化・高速・軽量",
            fileName: "ggml-whisper-distil-it-q5_0.bin",
            url: "https://huggingface.co/bofenghuang/whisper-large-v3-distil-it-v0.2/resolve/main/ggml-model-q5_0.bin",
            sizeMB: 400,
            isDefault: false,
            targetLanguages: ["it"],
            expectedSHA256: "78859adfcac034b046ee4a7851e6765ee8830207e3b92e1ea02102678376e9cf"
        ),
        // ── 多言語汎用 ──
        WhisperModel(
            id: "large-v3-turbo",
            name: "Large V3 Turbo",
            description: "多言語対応・高速",
            fileName: "ggml-large-v3-turbo.bin",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
            sizeMB: 1500,
            isDefault: false,
            expectedSHA256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
        ),
        WhisperModel(
            id: "large-v3-turbo-q5",
            name: "Large V3 Turbo Q5 (推奨)",
            description: "多言語対応・高速・軽量",
            fileName: "ggml-large-v3-turbo-q5_0.bin",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin",
            sizeMB: 547,
            isDefault: true,
            expectedSHA256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
        ),
        WhisperModel(
            id: "medium",
            name: "Medium",
            description: "多言語対応・バランス型",
            fileName: "ggml-medium.bin",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin",
            sizeMB: 1500,
            isDefault: false,
            expectedSHA256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208"
        ),
    ]

    static var defaultModel: WhisperModel {
        availableModels.first { $0.isDefault }!
    }

    /// 多言語対応用のデフォルトモデル（Large V3 Turbo Q5）
    static var multilingualModel: WhisperModel {
        availableModels.first { $0.id == "large-v3-turbo-q5" }!
    }

    /// 指定言語に最適なモデルを返す。
    /// ユーザーが多言語モデルを選択中なら尊重する。
    static func bestModel(for langCode: String) -> WhisperModel {
        let current = shared.currentModel
        // ユーザーが選んだモデルが多言語対応（targetLanguages空）ならそのまま使う
        if current.targetLanguages.isEmpty { return current }
        // 言語特化モデルを使用中で、その言語に合っているならそのまま
        let prefix = langCode.components(separatedBy: "-").first ?? langCode
        guard prefix != "auto" else { return current }
        if current.targetLanguages.contains(prefix) { return current }
        // 言語が合わない場合のみ切替を提案
        if let specialized = availableModels.first(where: { !$0.targetLanguages.isEmpty && $0.targetLanguages.contains(prefix) }) {
            return specialized
        }
        return multilingualModel
    }

    let modelDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/whisper")

    /// 現在選択されているモデル
    var currentModel: WhisperModel {
        let savedID = UserDefaults.standard.string(forKey: "selectedModelID") ?? ""
        return Self.availableModels.first { $0.id == savedID } ?? Self.defaultModel
    }

    var modelPath: String {
        modelDir.appendingPathComponent(currentModel.fileName).path
    }

    var isModelAvailable: Bool {
        // Intel Mac では whisper.cpp モデルは不要（使えない）ので常に true を返す
        if !ArchUtil.isAppleSilicon { return true }
        return FileManager.default.fileExists(atPath: modelPath)
    }

    /// 指定モデルがダウンロード済みか
    func isDownloaded(_ model: WhisperModel) -> Bool {
        FileManager.default.fileExists(atPath: modelDir.appendingPathComponent(model.fileName).path)
    }

    /// モデル選択を保存
    func selectModel(_ model: WhisperModel) {
        UserDefaults.standard.set(model.id, forKey: "selectedModelID")
        AppSettings.shared.whisperCppModelPath = modelDir.appendingPathComponent(model.fileName).path
    }

    /// モデルのパスを取得
    func path(for model: WhisperModel) -> String {
        modelDir.appendingPathComponent(model.fileName).path
    }

    private var downloadTask: URLSessionDownloadTask?
    private var progressWindow: NSWindow?
    private var progressIndicator: NSProgressIndicator?
    private var progressLabel: NSTextField?

    /// モデルが存在するか確認し、なければダウンロードしてからコールバック。
    /// Intel Mac では whisper.cpp が動作しないためダウンロードをスキップ。
    func ensureModel(completion: @escaping (Bool) -> Void) {
        // Intel Mac: モデル不要
        if !ArchUtil.isAppleSilicon {
            completion(true)
            return
        }

        if isModelAvailable {
            completion(true)
            return
        }

        let alert = NSAlert()
        alert.messageText = L10n.modelDownloadDialogTitle
        alert.informativeText = L10n.modelDownloadDialogMessage(name: currentModel.name, sizeMB: currentModel.sizeMB)
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.download)
        alert.addButton(withTitle: L10n.later)

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            completion(false); return
        }

        startDownload(model: currentModel, completion: completion)
    }

    /// 指定モデルをダウンロード
    func download(model: WhisperModel, completion: @escaping (Bool) -> Void) {
        startDownload(model: model, completion: completion)
    }

    private func startDownload(model: WhisperModel, completion: @escaping (Bool) -> Void) {
        try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        showProgressWindow(model: model)

        let url = URL(string: model.url)!
        klog("ModelDownloader: starting download \(model.name) from \(url)")

        let session = URLSession(configuration: .default, delegate: nil, delegateQueue: .main)
        let task = session.downloadTask(with: url) { [weak self] tempURL, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.hideProgressWindow()

                if let error {
                    klog("ModelDownloader: error \(error.localizedDescription)")
                    self.showError(L10n.downloadFailedMessage(error.localizedDescription))
                    completion(false)
                    return
                }

                guard let tempURL else {
                    klog("ModelDownloader: no temp file")
                    completion(false)
                    return
                }

                let dest = self.modelDir.appendingPathComponent(model.fileName)
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tempURL, to: dest)

                    if let expected = model.expectedSHA256?.lowercased() {
                        let actual = (try? Self.sha256Hex(of: dest)) ?? ""
                        if actual != expected {
                            klog("ModelDownloader: SHA256 mismatch expected=\(expected) actual=\(actual)")
                            try? FileManager.default.removeItem(at: dest)
                            self.showError("Model integrity check failed. Expected SHA256 \(expected) but got \(actual). File deleted.")
                            completion(false)
                            return
                        }
                        klog("ModelDownloader: SHA256 verified \(actual)")
                    } else {
                        klog("ModelDownloader: no expectedSHA256, skipping verification for \(model.id)")
                    }

                    klog("ModelDownloader: saved to \(dest.path)")
                    self.selectModel(model)
                    completion(true)
                } catch {
                    klog("ModelDownloader: move error \(error)")
                    self.showError(L10n.modelSaveFailed(error.localizedDescription))
                    completion(false)
                }
            }
        }

        let expectedMB = model.sizeMB
        let observer = task.progress.observe(\.completedUnitCount, options: [.new]) { [weak self] (prog: Progress, _: NSKeyValueObservedChange<Int64>) in
            DispatchQueue.main.async {
                let doneMB = Double(prog.completedUnitCount) / 1_000_000
                let totalMB = prog.totalUnitCount > 0 ? Double(prog.totalUnitCount) / 1_000_000 : Double(expectedMB)
                let pct = prog.totalUnitCount > 0
                    ? prog.fractionCompleted * 100
                    : Double(prog.completedUnitCount) / Double(Int64(expectedMB) * 1_000_000) * 100
                let remainMB = totalMB - doneMB
                self?.progressIndicator?.doubleValue = min(pct, 100)
                self?.progressLabel?.stringValue = String(format: "%.0f / %.0f MB (残り %.0f MB)", doneMB, totalMB, max(0, remainMB))
            }
        }
        objc_setAssociatedObject(task, "progressObserver", observer, .OBJC_ASSOCIATION_RETAIN)

        downloadTask = task
        task.resume()
    }

    private func showProgressWindow(model: WhisperModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.modelDownloadTitle
        window.center()
        window.isReleasedWhenClosed = false

        let view = NSView(frame: window.contentView!.bounds)

        let title = NSTextField(labelWithString: L10n.downloadingName(model.name))
        title.frame = NSRect(x: 20, y: 80, width: 360, height: 20)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        view.addSubview(title)

        let progress = NSProgressIndicator(frame: NSRect(x: 20, y: 50, width: 360, height: 20))
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        progress.doubleValue = 0
        progress.style = .bar
        view.addSubview(progress)
        progressIndicator = progress

        let label = NSTextField(labelWithString: L10n.preparing)
        label.frame = NSRect(x: 20, y: 20, width: 360, height: 20)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        view.addSubview(label)
        progressLabel = label

        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        progressWindow = window
    }

    private func hideProgressWindow() {
        progressWindow?.close()
        progressWindow = nil
        progressIndicator = nil
        progressLabel = nil
    }

    /// 大容量 (1.5GB+) でも RAM を爆発させないよう 1MB ずつ読みながら SHA256 を計算する。
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L10n.downloadError
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
