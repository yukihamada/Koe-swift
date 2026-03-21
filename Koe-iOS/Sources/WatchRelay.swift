import Foundation
import WatchConnectivity

/// Relays messages between Apple Watch and Mac.
/// Watch -> iPhone (WatchConnectivity) -> Mac (MultipeerConnectivity via MacBridge)
@MainActor
final class WatchRelay: NSObject, ObservableObject {
    static let shared = WatchRelay()

    @Published var isWatchConnected = false

    private var wcSession: WCSession?
    private var started = false

    private override init() {
        super.init()
    }

    /// Activate WatchConnectivity session. Only starts if WCSession is supported (iPhone with paired Watch).
    func start() {
        guard !started else { return }
        guard WCSession.isSupported() else { return }

        let session = WCSession.default
        session.delegate = self
        session.activate()
        wcSession = session
        started = true
    }

    /// Send transcription result back to Watch
    func sendTranscriptionToWatch(_ text: String) {
        guard let session = wcSession, session.isReachable else { return }
        session.sendMessage(["transcription": text], replyHandler: nil, errorHandler: nil)
    }

    /// Send status update to Watch
    func sendStatusToWatch(_ status: String) {
        guard let session = wcSession, session.isReachable else { return }
        session.sendMessage(["status": status], replyHandler: nil, errorHandler: nil)
    }
}

// MARK: - WCSessionDelegate

extension WatchRelay: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            isWatchConnected = session.isPaired && session.isWatchAppInstalled
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor in
            isWatchConnected = false
        }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate for session transfer scenarios
        Task { @MainActor in
            isWatchConnected = false
            session.activate()
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            isWatchConnected = session.isPaired && session.isWatchAppInstalled
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            isWatchConnected = session.isReachable
        }
    }

    /// Receive messages from Watch
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            guard let command = message["command"] as? String else { return }

            switch command {
            case "startRecording":
                // Future: trigger RecordingManager.shared.startRecording()
                sendStatusToWatch("録音中...")

            case "stopRecording":
                // Future: trigger RecordingManager.shared.stopRecording()
                sendStatusToWatch("処理中...")

            case "sendText":
                // Relay text to Mac via MacBridge
                if let text = message["text"] as? String {
                    MacBridge.shared.sendText(text)
                    sendStatusToWatch("Macに送信しました")
                }

            default:
                break
            }
        }
    }
}
