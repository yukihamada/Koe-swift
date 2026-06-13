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
            // OWW 環境が ready でない、または起動に失敗した場合は
            // MFCC テンプレートがあれば自動フォールバックする（Python 環境破損で無反応にしない）。
            if OWWSetupManager.shared.state == .ready {
                let engine = OWWEngine.shared
                engine.onDetected = { [weak self] in self?.onDetected?() }
                engine.start()
                isRunning = engine.isRunning
                if engine.isRunning { return }
                klog("WakeWordDetector: OWWEngine 起動失敗 — \(engine.lastError) → MFCC へフォールバック")
            } else {
                klog("WakeWordDetector: OWW 未準備 (state=\(OWWSetupManager.shared.state)) → MFCC へフォールバック")
            }
            OWWEngine.shared.stop()
            startMFCCFallback()

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

    /// OWW が使えない時の MFCC への自動フォールバック起動。
    private func startMFCCFallback() {
        let engine = WakeWordEngine.shared
        guard engine.isReady else {
            klog("WakeWordDetector: MFCC フォールバック不可（テンプレート不足 have \(engine.templates.count)）— wake 無効")
            isRunning = false
            return
        }
        engine.onDetected = { [weak self] in self?.onDetected?() }
        engine.start()
        isRunning = true
        klog("WakeWordDetector: MFCC フォールバックで起動")
    }

    func stop() {
        WakeWordEngine.shared.stop()
        OWWEngine.shared.stop()
        isRunning = false
    }
#endif
}
