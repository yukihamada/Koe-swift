import AppKit
import SwiftUI
import ApplicationServices

// MARK: - 1 スクリーン分のバッジ配置

/// スクリーン内の SwiftUI（top-left）座標に置く番号バッジ。
struct PlacedBadge: Identifiable {
    let id: Int          // 通し番号
    let position: CGPoint // スクリーン内 top-left 座標（バッジ中心）
    let size: CGSize      // 対象要素のサイズ（枠表示用）
}

final class NumberOverlayModel: ObservableObject {
    @Published var badges: [PlacedBadge] = []
}

// MARK: - SwiftUI ビュー

struct NumberOverlayView: View {
    @ObservedObject var model: NumberOverlayModel

    private let bg   = Color(red: 0.07, green: 0.07, blue: 0.08)
    private let gold = Color(red: 0.82, green: 0.72, blue: 0.52)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(model.badges) { badge in
                // 対象要素の枠（視認補助）
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(gold.opacity(0.55), lineWidth: 1.5)
                    .frame(width: max(badge.size.width, 14), height: max(badge.size.height, 14))
                    .position(badge.position)
                // 番号バッジ（要素左上寄り）
                Text("\(badge.id)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(gold)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4).fill(bg.opacity(0.92))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(gold.opacity(0.5), lineWidth: 1))
                    .position(x: badge.position.x - max(badge.size.width, 14) / 2 + 8,
                              y: badge.position.y - max(badge.size.height, 14) / 2 - 2)
            }
        }
    }
}

// MARK: - 1 スクリーン分の透明パネル

final class NumberOverlayWindow: NSPanel {
    let model = NumberOverlayModel()

    init(screenFrame: CGRect) {
        super.init(contentRect: screenFrame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true   // バッジ自身はクリック対象ではない（常にクリックスルー）
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let hosting = NSHostingView(rootView: NumberOverlayView(model: model))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = CGColor.clear
        contentView = hosting
    }

    // borderless でもキーになれるように（実際は使わないが念のため）
    override var canBecomeKey: Bool { false }
}

// MARK: - コントローラ

/// 番号オーバーレイの統合管理。スクリーンごとにウィンドウを持ち、全画面通しで採番する。
final class NumberOverlayController {
    static let shared = NumberOverlayController()
    private init() {}

    private var windows: [NumberOverlayWindow] = []   // NSScreen.screens と同順
    private(set) var targets: [Int: OverlayTarget] = [:]
    private(set) var isVisible = false
    private var autoHideTimer: Timer?

    // MARK: 表示 / 更新

    /// 前面アプリをスキャンして番号オーバーレイを表示・更新する。
    func show() {
        guard AppSettings.shared.numberOverlayEnabled else { return }
        refresh()
    }

    /// 再スキャンしてバッジを描き直す（表示中でなくても表示する）。
    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let mode = AppSettings.shared.elementScanMode
            var a11y: [ScannedElement] = []
            var ocr: [ScannedElement] = []
            if mode != "ocrFirst" {
                a11y = AXElementScanner.shared.scanAccessibility()
            }
            // a11y が薄い / OCR 優先 / a11yOnly でない場合は OCR も
            if mode == "ocrFirst" || (mode == "a11yFirst" && a11y.isEmpty) {
                ocr = OCRElementProvider.shared.scan()
            } else if mode == "a11yFirst" {
                ocr = OCRElementProvider.shared.scan()
            }
            let merged = ElementMerger.merge(a11y: a11y, ocr: ocr, mode: mode)
            DispatchQueue.main.async { self.present(merged) }
        }
    }

    /// 表示中の時だけ再スキャン（スクロール後などの追従用）。
    func refreshIfVisible() {
        if isVisible { refresh() }
    }

    private func present(_ merged: [OverlayTarget]) {
        rebuildWindowsIfNeeded()
        targets = Dictionary(uniqueKeysWithValues: merged.map { ($0.number, $0) })

        // スクリーンごとにバッジを振り分け
        let screens = NSScreen.screens
        let mainHeight = screens.first?.frame.height ?? 0
        var perScreen: [[PlacedBadge]] = Array(repeating: [], count: windows.count)

        for target in merged {
            // 対象が属するスクリーンを特定（グローバル top-left の中心で判定）
            for (i, screen) in screens.enumerated() where i < windows.count {
                let topLeft = screenTopLeftRect(screen, mainHeight: mainHeight)
                if topLeft.contains(target.center) {
                    // スクリーン内 SwiftUI（top-left）座標へ
                    let x = target.center.x - topLeft.minX
                    let y = target.center.y - topLeft.minY
                    perScreen[i].append(PlacedBadge(id: target.number,
                                                    position: CGPoint(x: x, y: y),
                                                    size: target.frame.size))
                    break
                }
            }
        }

        for (i, window) in windows.enumerated() {
            window.model.badges = perScreen[i]
            window.orderFrontRegardless()
        }
        isVisible = true
        scheduleAutoHide()
        klog("NumberOverlay: \(merged.count) targets across \(windows.count) screens")
    }

    // MARK: 消去

    func hide() {
        autoHideTimer?.invalidate(); autoHideTimer = nil
        for window in windows { window.orderOut(nil); window.model.badges = [] }
        targets = [:]
        isVisible = false
    }

    // MARK: クリック

    /// 番号 N の要素をクリック（a11y は AXPress 優先、なければ座標クリック）。
    /// 成否を返す。
    @discardableResult
    func click(number: Int) -> Bool {
        guard let target = targets[number] else {
            klog("NumberOverlay: #\(number) は見つかりません（targets=\(targets.count)）")
            return false
        }
        var pressed = false
        if let el = target.axElement {
            if AXUIElementPerformAction(el, kAXPressAction as CFString) == .success {
                pressed = true
                klog("NumberOverlay: #\(number) AXPress '\(target.label ?? "")'")
            }
        }
        if !pressed {
            ClickSynthesizer.click(at: target.center)
            klog("NumberOverlay: #\(number) click at (\(Int(target.center.x)),\(Int(target.center.y)))")
        }
        if AppSettings.shared.numberOverlayAutoHideAfterClick {
            hide()
        } else {
            refreshIfVisible()
        }
        return true
    }

    // MARK: ウィンドウ管理

    /// スクリーン構成に合わせてウィンドウ群を作り直す。
    private func rebuildWindowsIfNeeded() {
        let screens = NSScreen.screens
        if windows.count == screens.count {
            // フレームだけ更新
            for (i, screen) in screens.enumerated() { windows[i].setFrame(screen.frame, display: false) }
            return
        }
        for window in windows { window.orderOut(nil) }
        windows = screens.map { NumberOverlayWindow(screenFrame: $0.frame) }
    }

    /// スクリーン構成変更時に呼ぶ（didChangeScreenParameters）。
    func handleScreenChange() {
        let wasVisible = isVisible
        for window in windows { window.orderOut(nil) }
        windows = []
        if wasVisible { refresh() }
    }

    // MARK: 座標ヘルパー

    /// スクリーンのグローバル top-left 矩形（origin=メインディスプレイ左上, y down）。
    private func screenTopLeftRect(_ screen: NSScreen, mainHeight: CGFloat) -> CGRect {
        let f = screen.frame
        return CGRect(x: f.origin.x,
                      y: mainHeight - f.origin.y - f.height,
                      width: f.width, height: f.height)
    }

    private func scheduleAutoHide() {
        autoHideTimer?.invalidate()
        // 無操作で 8 秒後に自動で消す
        autoHideTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }
}
