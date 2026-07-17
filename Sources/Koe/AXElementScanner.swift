import AppKit
import ApplicationServices
import Vision

// MARK: - 共有モデル

/// 要素の出どころ。
enum ElementSource {
    case accessibility
    case ocr
}

/// 画面上のクリック可能要素（採番前）。
struct ScannedElement {
    /// グローバル画面座標（top-left origin・points）。AX/CGEvent と同じ座標系。
    let frame: CGRect
    let label: String?
    let source: ElementSource
    /// a11y 由来なら AXPress を直接撃てる。
    let axElement: AXUIElement?

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
}

/// 番号オーバーレイに表示するターゲット（採番済み）。
struct OverlayTarget {
    let number: Int
    let frame: CGRect          // グローバル画面座標（top-left origin・points）
    let label: String?
    let source: ElementSource
    let axElement: AXUIElement?

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
}

// MARK: - AXElementScanner

/// 前面アプリの Accessibility ツリーを再帰列挙して、クリック可能な要素を取り出す。
/// OCR はフォールバック（a11y 非対応アプリ / Web 内要素）。
final class AXElementScanner {
    static let shared = AXElementScanner()
    private init() {}

    // 暴走防止の上限（a11y ツリーは時に巨大・循環し得る）
    private let maxDepth = 12
    private let maxNodes = 500
    private let scanTimeout: TimeInterval = 0.4
    private let minSize: CGFloat = 8

    /// アクション可能とみなすロール。
    private let actionableRoles: Set<String> = [
        kAXButtonRole, "AXLink", kAXTextFieldRole, kAXTextAreaRole,
        kAXCheckBoxRole, kAXRadioButtonRole, kAXMenuItemRole, kAXMenuButtonRole,
        kAXPopUpButtonRole, kAXTabGroupRole, kAXComboBoxRole, kAXDisclosureTriangleRole,
        kAXSliderRole, kAXIncrementorRole,
    ]

    // MARK: a11y 列挙

    /// 前面アプリの要素を列挙（バックグラウンドキューから呼ぶこと。AX は重い）。
    func scanAccessibility() -> [ScannedElement] {
        guard AXIsProcessTrusted() else {
            klog("AXScanner: アクセシビリティ権限なし")
            return []
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return [] }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)

        var out: [ScannedElement] = []
        var nodeCount = 0
        let deadline = Date().addingTimeInterval(scanTimeout)
        let screenBounds = unionScreenBounds()

        recurse(appEl, depth: 0, nodeCount: &nodeCount, deadline: deadline,
                screenBounds: screenBounds, out: &out)
        klog("AXScanner: \(out.count) actionable elements (\(nodeCount) nodes scanned)")
        return out
    }

    private func recurse(_ element: AXUIElement, depth: Int, nodeCount: inout Int,
                         deadline: Date, screenBounds: CGRect, out: inout [ScannedElement]) {
        if depth > maxDepth || nodeCount >= maxNodes || Date() > deadline { return }
        nodeCount += 1

        let role = stringAttr(element, kAXRoleAttribute as CFString)

        // 非表示・パスワード入力欄はスキップ（機密保護）
        if boolAttr(element, "AXHidden" as CFString) == true { return }
        if role == "AXSecureTextField" { return }

        if let role, isActionable(element, role: role),
           let frame = frameAttr(element), frame.width >= minSize, frame.height >= minSize,
           frame.intersects(screenBounds) {
            let label = bestLabel(element)
            out.append(ScannedElement(frame: frame, label: label,
                                      source: .accessibility, axElement: element))
        }

        // 子へ
        guard let children = childrenAttr(element) else { return }
        for child in children {
            if nodeCount >= maxNodes || Date() > deadline { return }
            recurse(child, depth: depth + 1, nodeCount: &nodeCount, deadline: deadline,
                    screenBounds: screenBounds, out: &out)
        }
    }

    private func isActionable(_ element: AXUIElement, role: String) -> Bool {
        if actionableRoles.contains(role) { return true }
        // ロールに無くても AXPress を持つ要素は採用
        var names: CFArray?
        if AXUIElementCopyActionNames(element, &names) == .success,
           let arr = names as? [String], arr.contains(kAXPressAction as String) {
            return true
        }
        return false
    }

    // MARK: AX 属性ヘルパー

    private func stringAttr(_ el: AXUIElement, _ attr: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &value) == .success else { return nil }
        return value as? String
    }

    private func boolAttr(_ el: AXUIElement, _ attr: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &value) == .success else { return nil }
        return value as? Bool
    }

    private func childrenAttr(_ el: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &value) == .success
        else { return nil }
        return value as? [AXUIElement]
    }

    /// グローバル画面座標（top-left origin・points）でフレームを取得。
    private func frameAttr(_ el: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }

        guard CFGetTypeID(posValue!) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue!) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// 表示用ラベル（title → description のみ）。
    /// kAXValue はテキスト入力欄の中身＝機密になり得るので使わない。
    private func bestLabel(_ el: AXUIElement) -> String? {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let s = stringAttr(el, attr as CFString),
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String(s.prefix(40))
            }
        }
        return nil
    }

    // MARK: 画面範囲

    /// 全スクリーンを内包する矩形（top-left origin・points）。
    /// AX/CGEvent はメインディスプレイ左上を原点とする top-left 座標系。
    func unionScreenBounds() -> CGRect {
        guard let main = NSScreen.screens.first else { return .zero }
        let mainHeight = main.frame.height
        var union = CGRect.zero
        for screen in NSScreen.screens {
            // NSScreen は bottom-left。top-left へ変換。
            let f = screen.frame
            let topLeft = CGRect(x: f.origin.x,
                                 y: mainHeight - f.origin.y - f.height,
                                 width: f.width, height: f.height)
            union = union.isEmpty ? topLeft : union.union(topLeft)
        }
        return union
    }
}

// MARK: - OCRElementProvider（フォールバック）

/// 画面キャプチャ + Vision OCR でテキスト要素を矩形付きで拾う。a11y が薄いアプリ向け。
final class OCRElementProvider {
    static let shared = OCRElementProvider()
    private init() {}

    /// 前面ディスプレイをキャプチャして OCR 要素を返す（バックグラウンドから同期呼び出し）。
    func scan() -> [ScannedElement] {
        guard CGPreflightScreenCaptureAccess() else {
            klog("OCRProvider: 画面収録権限なし")
            return []
        }
        guard let screen = NSScreen.main else { return [] }
        let displayHeightPt = screen.frame.height
        let displayWidthPt = screen.frame.width

        let tmp = "/tmp/koe_ocr_scan.png"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-x", tmp]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run(); proc.waitUntilExit() } catch { return [] }
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        guard let provider = CGDataProvider(url: URL(fileURLWithPath: tmp) as CFURL),
              let image = CGImage(pngDataProviderSource: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent)
        else { return [] }

        var results: [ScannedElement] = []
        let sema = DispatchSemaphore(value: 0)
        let request = VNRecognizeTextRequest { req, _ in
            defer { sema.signal() }
            guard let observations = req.results as? [VNRecognizedTextObservation] else { return }
            for obs in observations {
                guard let cand = obs.topCandidates(1).first else { continue }
                // Vision: bottom-left・正規化 → top-left・points（論理座標）へ
                let box = obs.boundingBox
                let x = box.minX * displayWidthPt
                let w = box.width * displayWidthPt
                let h = box.height * displayHeightPt
                let yTop = (1 - box.maxY) * displayHeightPt
                let frame = CGRect(x: x, y: yTop, width: w, height: h)
                results.append(ScannedElement(frame: frame, label: cand.string,
                                              source: .ocr, axElement: nil))
            }
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja", "en"]
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        _ = sema.wait(timeout: .now() + 3)
        klog("OCRProvider: \(results.count) text elements")
        return results
    }
}

// MARK: - ElementMerger

/// a11y を主・OCR を補完として統合し、重複を除去して読み順に採番する。
enum ElementMerger {
    /// `mode`: "a11yFirst" | "ocrFirst" | "a11yOnly"
    static func merge(a11y: [ScannedElement], ocr: [ScannedElement], mode: String) -> [OverlayTarget] {
        var combined: [ScannedElement]
        switch mode {
        case "a11yOnly":
            combined = a11y
        case "ocrFirst":
            combined = ocr + dedupAgainst(a11y, existing: ocr)
        default: // a11yFirst
            // a11y を主に、a11y フレームに内包されない OCR だけ補完
            combined = a11y + dedupAgainst(ocr, existing: a11y)
        }

        // 読み順: y 昇順 → x 昇順（同一行は左から）。行の括りは緩く 12pt。
        combined.sort { lhs, rhs in
            if abs(lhs.frame.minY - rhs.frame.minY) > 12 { return lhs.frame.minY < rhs.frame.minY }
            return lhs.frame.minX < rhs.frame.minX
        }

        return combined.enumerated().map { idx, el in
            OverlayTarget(number: idx + 1, frame: el.frame, label: el.label,
                          source: el.source, axElement: el.axElement)
        }
    }

    /// `candidates` のうち `existing` のどれかと重複するものを除いて返す。
    private static func dedupAgainst(_ candidates: [ScannedElement],
                                     existing: [ScannedElement]) -> [ScannedElement] {
        candidates.filter { cand in
            !existing.contains { ex in
                ex.frame.contains(cand.center) ||
                hypot(ex.center.x - cand.center.x, ex.center.y - cand.center.y) < 20
            }
        }
    }
}
