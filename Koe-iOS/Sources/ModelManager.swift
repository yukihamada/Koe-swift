import Foundation
import Combine

/// iOS 用モデルダウンロード・管理。Mac 版と同じ HuggingFace モデルを使用。
@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    struct WhisperModel: Identifiable {
        let id: String
        let name: String
        let description: String
        let fileName: String
        let url: String
        let sizeMB: Int
        let isDefault: Bool
    }

    /// 利用可能なモデル一覧 (Mac 版と同一)
    static let availableModels: [WhisperModel] = [
        WhisperModel(
            id: "kotoba-v2-q5",
            name: "Kotoba v2.0 Q5 (推奨)",
            description: "日本語特化・高精度",
            fileName: "ggml-kotoba-whisper-v2.0-q5_0.bin",
            url: "https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0-ggml/resolve/main/ggml-kotoba-whisper-v2.0-q5_0.bin",
            sizeMB: 538,
            isDefault: true
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
            id: "large-v3-turbo",
            name: "Large V3 Turbo",
            description: "多言語対応・高速",
            fileName: "ggml-large-v3-turbo.bin",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
            sizeMB: 1500,
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

    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var downloadStatus = ""
    @Published var isModelReady = false

    private var downloadTask: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    var modelDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("whisper-models")
    }

    var currentModel: WhisperModel {
        let savedID = UserDefaults.standard.string(forKey: "selectedModelID") ?? ""
        return Self.availableModels.first { $0.id == savedID }
            ?? Self.availableModels.first { $0.isDefault }!
    }

    var modelPath: String {
        modelDir.appendingPathComponent(currentModel.fileName).path
    }

    init() {
        isModelReady = FileManager.default.fileExists(atPath: modelPath)
    }

    func isDownloaded(_ model: WhisperModel) -> Bool {
        FileManager.default.fileExists(atPath: modelDir.appendingPathComponent(model.fileName).path)
    }

    func selectModel(_ model: WhisperModel) {
        UserDefaults.standard.set(model.id, forKey: "selectedModelID")
        isModelReady = isDownloaded(model)
    }

    func deleteModel(_ model: WhisperModel) {
        let path = modelDir.appendingPathComponent(model.fileName)
        try? FileManager.default.removeItem(at: path)
        if model.id == currentModel.id {
            isModelReady = false
        }
    }

    func download(_ model: WhisperModel) {
        guard !isDownloading else { return }

        try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        isDownloading = true
        downloadProgress = 0
        downloadStatus = "ダウンロード準備中..."

        let url = URL(string: model.url)!
        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isDownloading = false
                self.observation = nil

                if let error {
                    self.downloadStatus = "エラー: \(error.localizedDescription)"
                    return
                }
                guard let tempURL else {
                    self.downloadStatus = "ダウンロード失敗"
                    return
                }

                let dest = self.modelDir.appendingPathComponent(model.fileName)
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                    self.selectModel(model)
                    self.isModelReady = true
                    self.downloadStatus = "ロード中…"
                    print("[Koe] Model downloaded: \(model.name)")
                    // ダウンロード完了後に自動ロード
                    self.loadWhisperModel { ok in
                        self.downloadStatus = ok ? "" : "ロード失敗"
                    }
                } catch {
                    self.downloadStatus = "保存エラー: \(error.localizedDescription)"
                }
            }
        }

        observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.downloadProgress = progress.fractionCompleted
                let doneMB = Int(Double(progress.completedUnitCount) / 1_000_000)
                self?.downloadStatus = "\(doneMB) / \(model.sizeMB) MB"
            }
        }

        downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        observation = nil
        isDownloading = false
        downloadStatus = ""
    }

    /// モデルをロードして whisper.cpp を準備
    func loadWhisperModel(completion: @escaping (Bool) -> Void) {
        guard isModelReady else { completion(false); return }
        WhisperContext.shared.loadModel(path: modelPath, completion: completion)
    }
}
