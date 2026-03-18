import Foundation
import MultipeerConnectivity
import Combine
import UIKit

@MainActor
final class MacBridge: NSObject, ObservableObject {
    static let shared = MacBridge()

    @Published var isConnected = false
    @Published var nearbyMacs: [MCPeerID] = []
    @Published var remoteTranscription = ""
    @Published var remoteTranslation = ""
    @Published var useRemoteWhisper: Bool = UserDefaults.standard.bool(forKey: "koe_remote_whisper")

    private let serviceType = "koe-bridge"
    private let myPeerID = MCPeerID(displayName: UIDevice.current.name)
    private var session: MCSession?
    private var browser: MCNearbyServiceBrowser?

    private override init() {
        super.init()
    }

    func startBrowsing() {
        // 既存のセッション・ブラウザを停止してリソースリークを防止
        browser?.stopBrowsingForPeers()
        session?.disconnect()

        let session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session

        let browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        browser.delegate = self
        self.browser = browser
        browser.startBrowsingForPeers()
    }

    func connect(to peer: MCPeerID) {
        guard let browser, let session else { return }
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 10)
    }

    /// テキストをMacに送信（認識完了後）
    func sendText(_ text: String) {
        guard let session, !session.connectedPeers.isEmpty else { return }
        let msg = ["type": "text", "text": text]
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    /// PCM音声データをMacに送信してWhisper認識を依頼
    /// 注意: 呼び出し側が送信サンプル数を制限すること (最大30秒分程度)
    func sendAudioForTranscription(_ samples: [Float], translate: Bool = false) {
        guard useRemoteWhisper, let session, !session.connectedPeers.isEmpty else { return }
        guard !samples.isEmpty else { return }
        let header: [String: Any] = ["type": "whisper_request", "translate": translate, "count": samples.count]
        guard let headerData = try? JSONSerialization.data(withJSONObject: header) else { return }

        // ヘッダー(JSON) + セパレータ(0xFF x4) + PCMデータ
        var packet = headerData
        packet.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF] as [UInt8])
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            let byteCount = buf.count * MemoryLayout<Float>.size
            base.withMemoryRebound(to: UInt8.self, capacity: byteCount) { bytePtr in
                packet.append(UnsafeBufferPointer(start: bytePtr, count: byteCount))
            }
        }
        try? session.send(packet, toPeers: session.connectedPeers, with: .reliable)
    }

    /// PCM音声データをMacにストリーミング送信（テキスト送信用、従来互換）
    func sendAudio(_ samples: Data) {
        guard let session, !session.connectedPeers.isEmpty else { return }
        try? session.send(samples, toPeers: session.connectedPeers, with: .unreliable)
    }

    func disconnect() {
        session?.disconnect()
        browser?.stopBrowsingForPeers()
    }
}

extension MacBridge: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID,
                             didChange state: MCSessionState) {
        Task { @MainActor in
            self.isConnected = !session.connectedPeers.isEmpty
        }
    }
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer: MCPeerID) {
        // MacからのWhisper認識結果を受信
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        Task { @MainActor in
            if type == "whisper_result" {
                if let text = json["text"] as? String {
                    self.remoteTranscription = text
                }
                if let translated = json["translated"] as? String {
                    self.remoteTranslation = translated
                }
            }
        }
    }
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream,
                             withName: String, fromPeer: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName: String,
                             fromPeer: MCPeerID, with: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName: String,
                             fromPeer: MCPeerID, at: URL?, withError: Error?) {}
}

extension MacBridge: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        // Macが見つかったら自動接続を試みる
        Task { @MainActor in
            if !self.nearbyMacs.contains(peerID) {
                self.nearbyMacs.append(peerID)
            }
            self.connect(to: peerID)
        }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.nearbyMacs.removeAll { $0 == peerID }
        }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser,
                             didNotStartBrowsingForPeers error: Error) {}
}
