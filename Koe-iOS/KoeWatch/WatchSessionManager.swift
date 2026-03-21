import Foundation
import WatchConnectivity

/// Manages WatchConnectivity session on the Watch side.
/// Sends voice commands/text to iPhone, receives transcription results back.
@MainActor
final class WatchSessionManager: NSObject, ObservableObject {
    static let shared = WatchSessionManager()

    @Published var isReachable = false
    @Published var isRecording = false
    @Published var lastTranscription = ""
    @Published var statusText = "待機中"

    private var wcSession: WCSession?

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else {
            statusText = "WCSession非対応"
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        wcSession = session
    }

    // MARK: - Actions

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard let session = wcSession, session.isReachable else {
            statusText = "iPhoneに接続してください"
            return
        }
        isRecording = true
        statusText = "録音中..."
        lastTranscription = ""

        // Tell iPhone to start recording
        session.sendMessage(["command": "startRecording"], replyHandler: nil) { [weak self] error in
            Task { @MainActor in
                self?.statusText = "送信エラー"
                self?.isRecording = false
            }
        }
    }

    private func stopRecording() {
        isRecording = false
        statusText = "処理中..."

        guard let session = wcSession, session.isReachable else {
            statusText = "iPhoneに接続してください"
            return
        }

        // Tell iPhone to stop recording
        session.sendMessage(["command": "stopRecording"], replyHandler: nil) { [weak self] error in
            Task { @MainActor in
                self?.statusText = "送信エラー"
            }
        }
    }

    /// Send recognized text to iPhone for relay to Mac
    func sendTextToMac(_ text: String) {
        guard let session = wcSession, session.isReachable else { return }
        session.sendMessage(["command": "sendText", "text": text], replyHandler: nil, errorHandler: nil)
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            switch activationState {
            case .activated:
                isReachable = session.isReachable
                statusText = session.isReachable ? "接続済み" : "iPhoneを探しています..."
            case .inactive, .notActivated:
                isReachable = false
                statusText = "未接続"
            @unknown default:
                break
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            isReachable = session.isReachable
            if session.isReachable {
                statusText = "接続済み"
            } else {
                statusText = "iPhoneを探しています..."
                isRecording = false
            }
        }
    }

    /// Receive messages from iPhone (transcription results, status updates)
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            if let transcription = message["transcription"] as? String {
                lastTranscription = transcription
                statusText = "完了"
                isRecording = false
            }
            if let status = message["status"] as? String {
                statusText = status
            }
        }
    }
}
