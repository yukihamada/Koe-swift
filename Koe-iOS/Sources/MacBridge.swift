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
    @Published var activeAppName: String = ""
    @Published var activeAppBundleID: String = ""
    @Published var screenImage: UIImage?
    @Published var screenContext: String = ""
    @Published var suggestions: [String] = []

    /// Set to a peer when PIN entry is needed; observe this to show PIN alert
    @Published var pendingPINPeer: MCPeerID?
    /// The PIN advertised by the Mac (from discoveryInfo), shown as hint if desired
    @Published var pendingPINHint: String = ""

    private let serviceType = "koe-bridge"
    private let myPeerID = MCPeerID(displayName: UIDevice.current.name)
    private var session: MCSession?
    private var browser: MCNearbyServiceBrowser?

    /// Paired Mac display names persisted for auto-reconnect without PIN
    private var pairedMacNames: Set<String> = {
        let saved = UserDefaults.standard.stringArray(forKey: "koe_paired_macs") ?? []
        return Set(saved)
    }()

    /// Temporarily stores discoveryInfo PIN per peer for use during invitation
    private var discoveredPINs: [MCPeerID: String] = [:]

    private override init() {
        super.init()
    }

    private func savePairedMacs() {
        UserDefaults.standard.set(Array(pairedMacNames), forKey: "koe_paired_macs")
    }

    func startBrowsing() {
        // 既存のセッション・ブラウザを停止してリソースリークを防止
        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        session?.delegate = nil
        session?.disconnect()

        let session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session

        let browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        browser.delegate = self
        self.browser = browser
        browser.startBrowsingForPeers()
    }

    /// Connect to a peer, sending PIN as context data
    func connect(to peer: MCPeerID, pin: String? = nil) {
        guard let browser, let session else { return }
        var contextData: Data? = nil
        if let pin {
            let context: [String: String] = ["pin": pin]
            contextData = try? JSONSerialization.data(withJSONObject: context)
        }
        browser.invitePeer(peer, to: session, withContext: contextData, timeout: 10)
    }

    /// Called from UI after user enters the PIN displayed on Mac
    func submitPIN(_ pin: String) {
        guard let peer = pendingPINPeer else { return }
        connect(to: peer, pin: pin)
        // Mark as paired (Mac will reject if PIN is wrong; on next successful
        // connection the peer stays in the set for auto-reconnect)
        pairedMacNames.insert(peer.displayName)
        savePairedMacs()
        pendingPINPeer = nil
        pendingPINHint = ""
    }

    /// Cancel pending PIN entry
    func cancelPINEntry() {
        pendingPINPeer = nil
        pendingPINHint = ""
    }

    /// Clear all paired devices (useful for settings / debug)
    func clearPairedDevices() {
        pairedMacNames.removeAll()
        savePairedMacs()
    }

    /// テキストをMacに送信（認識完了後）
    func sendText(_ text: String) {
        guard let session, !session.connectedPeers.isEmpty else { return }
        let msg = ["type": "text", "text": text]
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    /// ストリーミングテキスト（部分認識結果）をMacに送信
    func sendStreamingText(_ text: String) {
        guard let session, !session.connectedPeers.isEmpty else { return }
        let msg = ["type": "streaming_text", "text": text]
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    /// Macのエージェントモードをトグル
    func sendToggleAgent(enabled: Bool) {
        guard let session, !session.connectedPeers.isEmpty else { return }
        let msg: [String: Any] = ["type": "toggle_agent", "enabled": enabled]
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    /// MacにBackspaceを送信（文字数分）
    func sendBackspace(count: Int = 1) {
        guard let session, !session.connectedPeers.isEmpty else { return }
        let msg: [String: Any] = ["type": "backspace", "count": count]
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    /// MacにEnterキーを送信
    func sendEnter() {
        guard let session, !session.connectedPeers.isEmpty else { return }
        let msg = ["type": "enter"]
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

    /// Macにコマンドを送信（undo, selectAll, tab等）
    func sendCommand(_ command: String) {
        guard let session, !session.connectedPeers.isEmpty else { return }
        let msg = ["type": "command", "command": command]
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    /// Send mouse move delta to Mac
    func sendMouseMove(dx: CGFloat, dy: CGFloat) {
        guard let session, !session.connectedPeers.isEmpty else { return }
        let msg: [String: Any] = ["type": "mouse_move", "dx": dx, "dy": dy]
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .unreliable)
    }

    /// Send mouse click coordinates to Mac (normalized 0-1)
    func sendMouseClick(x: CGFloat, y: CGFloat) {
        guard let session, !session.connectedPeers.isEmpty else { return }
        let msg: [String: Any] = ["type": "mouse_click", "x": x, "y": y]
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
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
            let wasConnected = self.isConnected
            self.isConnected = !session.connectedPeers.isEmpty
            if state == .connected {
                print("MacBridge: connected to \(peerID.displayName)")
            } else if state == .notConnected && wasConnected {
                print("MacBridge: disconnected from \(peerID.displayName), will retry in 3s")
                // 切断時に3秒後に再接続を試行
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, !self.isConnected else { return }
                    if let peer = self.nearbyMacs.first(where: { $0.displayName == peerID.displayName }) {
                        let pin = self.discoveredPINs[peer]
                        self.connect(to: peer, pin: pin)
                    }
                }
            }
        }
    }
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer: MCPeerID) {
        // Screen frame: 4-byte "SCRN" magic + JPEG
        if data.count > 4, data[0] == 0x53, data[1] == 0x43, data[2] == 0x52, data[3] == 0x4E {
            let jpegData = data.subdata(in: 4..<data.count)
            if let image = UIImage(data: jpegData) {
                Task { @MainActor in
                    self.screenImage = image
                }
            }
            return
        }
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
            } else if type == "active_app" {
                if let name = json["name"] as? String {
                    self.activeAppName = name
                }
                if let bundleID = json["bundleID"] as? String {
                    self.activeAppBundleID = bundleID
                }
            } else if type == "screen_context" {
                if let text = json["text"] as? String {
                    self.screenContext = text
                }
            } else if type == "suggestions" {
                if let items = json["items"] as? [String] {
                    self.suggestions = items
                    print("MacBridge: received \(items.count) suggestions: \(items)")
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
        let pin = info?["pin"]
        Task { @MainActor in
            if !self.nearbyMacs.contains(peerID) {
                self.nearbyMacs.append(peerID)
            }
            // Store the advertised PIN for this peer
            if let pin {
                self.discoveredPINs[peerID] = pin
            }

            // Skip if already connected
            if self.isConnected {
                return
            }

            // Previously paired devices auto-connect without PIN
            if self.pairedMacNames.contains(peerID.displayName) {
                print("MacBridge: auto-connecting to paired Mac '\(peerID.displayName)'")
                self.connect(to: peerID, pin: pin)
            } else {
                // New device: prompt user for PIN
                print("MacBridge: new Mac '\(peerID.displayName)' found, requesting PIN")
                self.pendingPINPeer = peerID
                self.pendingPINHint = pin ?? ""
            }
        }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.nearbyMacs.removeAll { $0 == peerID }
            self.discoveredPINs.removeValue(forKey: peerID)
        }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser,
                             didNotStartBrowsingForPeers error: Error) {}
}
