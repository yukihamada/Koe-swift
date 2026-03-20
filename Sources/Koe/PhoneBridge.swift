import Foundation
import MultipeerConnectivity

/// iPhone から接続を受け付ける Mac 側の MultipeerConnectivity ブリッジ
final class PhoneBridge: NSObject {
    static let shared = PhoneBridge()

    private let serviceType = "koe-bridge"
    private let myPeerID = MCPeerID(displayName: Host.current().localizedName ?? "Mac")
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?

    /// テキストを受信したときのコールバック（AppDelegate が設定）
    var onTextReceived: ((String) -> Void)?

    private override init() {
        super.init()
    }

    func start() {
        let session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session

        let advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: serviceType)
        advertiser.delegate = self
        self.advertiser = advertiser
        advertiser.startAdvertisingPeer()
        klog("PhoneBridge: advertising as \(myPeerID.displayName)")
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        session?.disconnect()
    }
}

extension PhoneBridge: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let stateStr = state == .connected ? "connected" : state == .connecting ? "connecting" : "notConnected"
        klog("PhoneBridge: \(peerID.displayName) \(stateStr)")
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // テキストメッセージ
        if let msg = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           msg["type"] == "text", let text = msg["text"] {
            klog("PhoneBridge: received text from iPhone: \(text)")
            DispatchQueue.main.async { self.onTextReceived?(text) }
            return
        }

        // Whisperリクエスト: ヘッダーJSON + 0xFFFFFFFF + PCMデータ
        if let separatorRange = data.range(of: Data([0xFF, 0xFF, 0xFF, 0xFF])) {
            let headerData = data[data.startIndex..<separatorRange.lowerBound]
            let pcmData = data[separatorRange.upperBound...]

            guard let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
                  header["type"] as? String == "whisper_request" else {
                klog("PhoneBridge: invalid whisper request header")
                return
            }

            let doTranslate = header["translate"] as? Bool ?? false
            let sampleCount = pcmData.count / 4  // Float32 = 4 bytes

            klog("PhoneBridge: whisper request from \(peerID.displayName), \(sampleCount) samples, translate=\(doTranslate)")

            // PCMバイト → [Float]
            let samples: [Float] = pcmData.withUnsafeBytes { raw in
                let buf = raw.bindMemory(to: Float.self)
                return Array(buf)
            }

            guard samples.count > 4000 else {
                klog("PhoneBridge: too short (\(samples.count) samples), skipping")
                return
            }

            let whisper = WhisperContext.shared

            // Step 1: 原文の文字起こし
            whisper.transcribeBuffer(samples: samples, completion: { [weak self] (text: String?) in
                let resultText = text ?? ""

                let sendResult = { (translated: String) in
                    let response: [String: Any] = [
                        "type": "whisper_result",
                        "text": resultText,
                        "translated": translated
                    ]
                    if let responseData = try? JSONSerialization.data(withJSONObject: response) {
                        try? session.send(responseData, toPeers: [peerID], with: .reliable)
                        klog("PhoneBridge: sent result to \(peerID.displayName): \(resultText.prefix(50))...")
                    }
                }

                if doTranslate {
                    whisper.transcribeBuffer(samples: samples, completion: { (translated: String?) in
                        sendResult(translated ?? "")
                    })
                } else {
                    sendResult("")
                }
            })
            return
        }

        // その他のデータ
        klog("PhoneBridge: received \(data.count) bytes from \(peerID.displayName)")
    }

    func session(_ session: MCSession, didReceive stream: InputStream,
                 withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension PhoneBridge: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        klog("PhoneBridge: invitation from \(peerID.displayName) — accepting")
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        klog("PhoneBridge: failed to start advertising: \(error)")
    }
}
