import Foundation

/// WakeWordDetector: WakeWordEngine (MFCC+DTW) を優先し、
/// テンプレート未登録の場合は何もしない（設定画面で録音を促す）
class WakeWordDetector {
    static let shared = WakeWordDetector()

    private(set) var isRunning = false

    var onDetected: (() -> Void)?

    func start() {
        guard AppSettings.shared.wakeWordEnabled, !isRunning else { return }

        let engine = WakeWordEngine.shared
        guard !engine.templates.isEmpty else {
            klog("WakeWordDetector: テンプレート未登録 — 設定 > AI でウェイクワードを録音してください")
            return
        }

        engine.onDetected = { [weak self] in self?.onDetected?() }
        engine.start()
        isRunning = true
    }

    func stop() {
        WakeWordEngine.shared.stop()
        isRunning = false
    }
}
