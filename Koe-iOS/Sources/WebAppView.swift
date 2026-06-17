import SwiftUI
import WebKit

/// koe.live/app（統合Webアプリ＝メッセンジャー/受信箱/焚き火/設定BYOK/通話）をアプリ内に埋め込む。
/// 録音(getUserMedia)はマイク権限を grant して動かす。ネイティブのディクテーション/Whisper等は別タブで温存。
struct WebAppView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.uiDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKUIDelegate {
        @available(iOS 15.0, *)
        func webView(_ webView: WKWebView,
                     requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.grant)
        }
    }
}

struct WebAppScreen: View {
    private let appURL = URL(string: "https://koe.live/app")!
    var body: some View {
        WebAppView(url: appURL)
            .ignoresSafeArea(edges: .bottom)
    }
}
