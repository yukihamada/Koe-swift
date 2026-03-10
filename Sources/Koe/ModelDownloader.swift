import Foundation
import AppKit

/// 利用可能なモデル定義
struct WhisperModel {
    let id: String
    let name: String
    let description: String
    let fileName: String
    let url: String
    let sizeMB: Int
    let isDefault: Bool

    var displayString: String {
        "\(name) (\(sizeMB)MB)"
    }
}

/// whisper モデルを HuggingFace からダウンロードする。
class ModelDownloader {
    static let shared = ModelDownloader()

    /// 利用可能なモデル一覧
    static let availableModels: [WhisperModel] = [
        WhisperModel(
            id: "kotoba-v2-q5",
            name: "Kotoba v2.0 Q5 (推奨)",
            description: "日本語特化・高精度・軽量",
            fileName: "ggml-kotoba-whisper-v2.0-q5_0.bin",
            url: "https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0-ggml/resolve/main/ggml-kotoba-whisper-v2.0-q5_0.bin",
            sizeMB: 538,
            isDefault: true
        ),
        WhisperModel(
            id: "kotoba-v2-full",
            name: "Kotoba v2.0 Full",
            description: "日本語特化・最高精度",
            fileName: "ggml-kotoba-whisper-v2.0.bin",
            url: "https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0-ggml/resolve/main/ggml-kotoba-whisper-v2.0.bin",
            sizeMB: 1520,
            isDefault: false
        ),
        WhisperModel(
            id: "large-v3-turbo",
            name: "Large V3 Turbo",
            description: "多言語対応・高速",
            fileName: "ggml-large-v3-turbo.bin",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
            sizeMB: 1500,
            isDefault: false
        ),
        WhisperModel(
            id: "large-v3-turbo-q5",
            name: "Large V3 Turbo Q5",
            description: "多言語対応・軽量",
            fileName: "ggml-large-v3-turbo-q5_0.bin",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin",
            sizeMB: 547,
            isDefault: false
        ),
        WhisperModel(
            id: "medium",
            name: "Medium",
            description: "多言語対応・バランス型",
            fileName: "ggml-medium.bin",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin",
            sizeMB: 1500,
            isDefault: false
        ),
    ]

    static var defaultModel: WhisperModel {
        availableModels.first { $0.isDefault }!
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
        FileManager.default.fileExists(atPath: modelPath)
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
    func ensureModel(completion: @escaping (Bool) -> Void) {
        if isModelAvailable {
            completion(true)
            return
        }

        let alert = NSAlert()
        alert.messageText = "音声認識モデルのダウンロード"
        alert.informativeText = "初回起動のため、日本語音声認識モデルをダウンロードします。\n\nモデル: \(currentModel.name) (\(currentModel.sizeMB)MB)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "ダウンロード")
        alert.addButton(withTitle: "後で")

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
                    self.showError("ダウンロードに失敗しました: \(error.localizedDescription)")
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
                    klog("ModelDownloader: saved to \(dest.path)")
                    self.selectModel(model)
                    completion(true)
                } catch {
                    klog("ModelDownloader: move error \(error)")
                    self.showError("モデルの保存に失敗しました: \(error.localizedDescription)")
                    completion(false)
                }
            }
        }

        let observer = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] (progress: Progress, _: NSKeyValueObservedChange<Double>) in
            DispatchQueue.main.async {
                self?.progressIndicator?.doubleValue = progress.fractionCompleted * 100
                let mb = Double(progress.completedUnitCount) / 1_000_000
                let total = Double(progress.totalUnitCount) / 1_000_000
                if total > 0 {
                    self?.progressLabel?.stringValue = String(format: "%.0f / %.0f MB", mb, total)
                } else {
                    self?.progressLabel?.stringValue = String(format: "%.0f MB", mb)
                }
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
        window.title = "Koe — モデルダウンロード中"
        window.center()
        window.isReleasedWhenClosed = false

        let view = NSView(frame: window.contentView!.bounds)

        let title = NSTextField(labelWithString: "\(model.name) をダウンロード中...")
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

        let label = NSTextField(labelWithString: "準備中...")
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

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "ダウンロードエラー"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
