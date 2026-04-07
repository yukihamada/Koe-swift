import Foundation

/// ウェイクワード検出のファサード
/// AppSettings.wakeWordEngineType に応じて MFCC+DTW か openWakeWord を切り替える
class WakeWordDetector {
    static let shared = WakeWordDetector()

    private(set) var isRunning = false

    var onDetected: (() -> Void)?

#if MAC_APP_STORE
    func start() {
        guard AppSettings.shared.wakeWordEnabled, !isRunning else { return }
        let engine = WakeWordEngine.shared
        guard engine.isReady else {
            klog("WakeWordDetector: テンプレート不足 (have \(engine.templates.count), need \(WakeWordEngine.minTemplates))")
            return
        }
        engine.onDetected = { [weak self] in self?.onDetected?() }
        engine.start()
        isRunning = true
    }
    func stop() { WakeWordEngine.shared.stop(); isRunning = false }
#else
    func start() {
        guard AppSettings.shared.wakeWordEnabled, !isRunning else { return }

        // 切り替え時に両エンジンを確実に停止してから起動
        WakeWordEngine.shared.stop()
        OWWEngine.shared.stop()

        switch AppSettings.shared.wakeWordEngineType {
        case .openWakeWord:
            let engine = OWWEngine.shared
            engine.onDetected = { [weak self] in self?.onDetected?() }
            engine.start()
            isRunning = engine.isRunning
            if !engine.isRunning {
                klog("WakeWordDetector: OWWEngine 起動失敗 — \(engine.lastError)")
            }

        case .mfccDTW:
            let engine = WakeWordEngine.shared
            guard engine.isReady else {
                klog("WakeWordDetector: テンプレート不足 (have \(engine.templates.count), need \(WakeWordEngine.minTemplates))")
                return
            }
            engine.onDetected = { [weak self] in self?.onDetected?() }
            engine.start()
            isRunning = true
        }
    }

    func stop() {
        WakeWordEngine.shared.stop()
        OWWEngine.shared.stop()
        isRunning = false
    }
#endif
}
