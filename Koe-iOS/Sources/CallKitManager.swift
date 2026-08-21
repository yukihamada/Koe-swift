import Foundation
import UIKit
import PushKit
import CallKit
import UserNotifications
import AVFoundation

/// 📞 CallKit本物の着信画面(応答/拒否ボタン付きの全画面着信)+ VoIP push配線。
/// koe.liveの安全な通話URL機能(/api/call/*)と対になる、2026-07-25本人指示「Call Kit」対応。
///
/// 流れ: サーバがVoIP pushを送る → didReceiveIncomingPushWith で即 CXProvider.reportNewIncomingCall
/// (Appleの規約: VoIP pushを受けたら必ず着信報告すること。これを怠るとプッシュ権限を剥奪されうる) →
/// 応答(CXAnswerCallAction)が押されたら AppState.incomingCallRoomID を立てて、koe.live/t/<room_id> を
/// アプリ内WebView(既存のWebAppView)で開く。実際の音声(WebRTC)はそのページに任せる。
final class AppDelegate: NSObject, UIApplicationDelegate, PKPushRegistryDelegate, CXProviderDelegate {
    private var voipRegistry: PKPushRegistry?
    private let provider: CXProvider
    private let callController = CXCallController()
    /// 個人ビルド専用のブートストラップ・トークン。
    /// ⚠ ソースには埋め込まない(git にシークレットを平置きしない)。
    /// 初回登録時に環境変数 PUSH_SEED_TOKEN を設定するか、plists から履歴削除後に
    /// Info.plist にサーバ配布ワンタイムトークンを入れる(koe-edge側でローテ)。
    static var pushSeedToken: String {
        ProcessInfo.processInfo.environment["PUSH_SEED_TOKEN"] ?? (Bundle.main.object(forInfoDictionaryKey: "PUSH_SEED_TOKEN") as? String) ?? ""
    }
    private static let apiBase = "https://koe.live"

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        if let icon = UIImage(named: "AppIcon") { config.iconTemplateImageData = icon.pngData() }
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 通常のAPNs(声メッセージ通知等)も併せて登録。無くてもVoIP pushの動作には影響しない。
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        let registry = PKPushRegistry(queue: nil)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        voipRegistry = registry
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AppDelegate.registerToken(deviceToken.hexString, type: nil)
    }

    // MARK: - PKPushRegistryDelegate

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        AppDelegate.registerToken(pushCredentials.token.hexString, type: "voip")
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {}

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP else { completion(); return }
        let dict = payload.dictionaryPayload
        let from = (dict["from"] as? String) ?? "だれか"
        let roomId = (dict["room_id"] as? String) ?? ""
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: from)
        update.localizedCallerName = "\(from)さんから(KOE)"
        update.hasVideo = false
        let callUUID = UUID()
        AppDelegate.pendingRoomIDs[callUUID] = roomId
        // 📞 規約: VoIP pushを受け取ったら必ず即座に着信報告する(報告しないとpush権限を剥奪されうる)
        provider.reportNewIncomingCall(with: callUUID, update: update) { _ in
            completion()
        }
    }

    // MARK: - CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {}

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        let roomId = AppDelegate.pendingRoomIDs[action.callUUID] ?? ""
        action.fulfill()
        DispatchQueue.main.async {
            AppState.shared.incomingCallRoomID = roomId.isEmpty ? nil : roomId
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        AppDelegate.pendingRoomIDs.removeValue(forKey: action.callUUID)
        action.fulfill()
        DispatchQueue.main.async {
            AppState.shared.incomingCallRoomID = nil
        }
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {}
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}

    // MARK: - Server registration

    private static var pendingRoomIDs: [UUID: String] = [:]

    private static func registerToken(_ hexToken: String, type: String?) {
        let token = pushSeedToken
        guard !token.isEmpty else { print("KoePush: PUSH_SEED_TOKEN 未設定のため登録をスキップ"); return }
        guard let url = URL(string: apiBase + "/api/push/register") else { return }
        var body: [String: Any] = ["device_token": hexToken, "platform": "ios", "bundle_id": Bundle.main.bundleIdentifier ?? "", "handle": "yuki"]
        if let type { body["type"] = type }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
