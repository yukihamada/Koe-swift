import AppKit
import WebKit

/// 💬 Koe メッセージ (Web) — koe.live/app（統合Webアプリ：メッセンジャー / 受信箱 / 焚き火 /
/// 設定(BYOK) / 通話）を、ネイティブ Koe.app の中からウィンドウで開く。
/// ネイティブのディクテーション・常時録音・データ保全は従来どおり別動線で温存（wrap & augment）。
/// 録音は Web の getUserMedia を使うため、マイク取得を grant する（audio-input entitlement と対）。
final class KoeWebWindow: NSObject, NSWindowDelegate, WKUIDelegate {
    static let shared = KoeWebWindow()

    private var window: NSWindow?
    private var webView: WKWebView?
    private static let appURL = URL(string: "https://koe.live/app")!

    func show() {
        if window == nil { build() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 760), configuration: cfg)
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.load(URLRequest(url: Self.appURL))
        self.webView = wv

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        w.title = "💬 Koe メッセージ"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = wv
        w.center()
        self.window = w
    }

    // Web アプリ内の録音(getUserMedia)を許可する。
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }
}
