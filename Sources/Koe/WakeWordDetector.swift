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

        // App Store版では MFCC+DTW のみサポート
        let engine = WakeWordEngine.shared
        guard engine.isReady else {
            klog("WakeWordDetector: テンプレート不足 (have \(engine.templates.count), need \(WakeWordEngine.minTemplates)) — 設定 > AI で録音してください")
            return
        }
        engine.onDetected = { [weak self] in self?.onDetected?() }
        engine.start()
        isRunning = true
    }
#else
    func start() {
        guard AppSettings.shared.wakeWordEnabled, !isRunning else { return }

        switch AppSettings.shared.wakeWordEngineType {
        case .openWakeWord:
            let engine = OWWEngine.shared
            engine.onDetected = { [weak self] in self?.onDetected?() }
            engine.start()
            isRunning = engine.isRunning

        case .mfccDTW:
            let engine = WakeWordEngine.shared
            guard engine.isReady else {
                klog("WakeWordDetector: テンプレート不足 (have \(engine.templates.count), need \(WakeWordEngine.minTemplates)) — 設定 > AI で録音してください")
                return
            }
            engine.onDetected = { [weak self] in self?.onDetected?() }
            engine.start()
            isRunning = true
        }
    }
#endif

#if MAC_APP_STORE
    func stop() {
        WakeWordEngine.shared.stop()
        isRunning = false
    }
#else
    func stop() {
        WakeWordEngine.shared.stop()
        OWWEngine.shared.stop()
        isRunning = false
    }
#endif
}
