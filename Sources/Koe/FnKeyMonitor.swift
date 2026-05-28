import AppKit
import Carbon.HIToolbox

/// Fn キー専用の低レベル監視。
/// Carbon RegisterEventHotKey は Fn を扱えないため、CGEventTap で flagsChanged / keyDown を直接見る。
///
/// 機能:
/// 1. Fn 単独タップ検出: 他のキーを押さずに Fn を押して離すと録音トグル (または PTT)
/// 2. Fn+letter コンボ: メインショートカットが .function modifier を含む場合に発火
///
/// アクセシビリティ権限が必要。権限がない場合は `start()` が黙って何もしない。
final class FnKeyMonitor {
    static let shared = FnKeyMonitor()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Fn 単独タップ判定の状態機械
    private var fnDown = false                // Fn フラグが現在 ON か
    private var fnUsedAsModifier = false      // Fn 押下中に他キーが押されたか
    private var fnDownAt: Date?               // Fn 押下時刻 (誤検出防止用 — 長押し過剰時は無視)

    /// 単独タップとして許容する最大押下時間 (これより長いと PTT 用途とみなし toggle はしない)
    private let tapMaxDuration: TimeInterval = 0.6

    // コールバック (AppDelegate 側で配線)
    var onFnTap: (() -> Void)?           // 単独タップ (tap_toggle モード)
    var onFnHoldStart: (() -> Void)?     // Fn 押下開始 (hold_ptt モード)
    var onFnHoldEnd: (() -> Void)?       // Fn 解放 (hold_ptt モード)
    var onFnComboShortcut: (() -> Void)? // Fn+設定キー が押された

    /// 現在の動作モード ("tap_toggle" or "hold_ptt")
    var mode: String = "tap_toggle"
    /// Fn+letter コンボの対象 keyCode (なければ nil)
    var comboKeyCode: Int? = nil

    private init() {}

    // MARK: - Public API

    /// CGEventTap を起動する (二重起動は無視)。
    /// アクセシビリティ権限がない場合は false を返して何もしない。
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        guard AXIsProcessTrusted() else {
            klog("FnKeyMonitor: skipped (no accessibility)")
            return false
        }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else {
            klog("FnKeyMonitor: CGEvent.tapCreate failed")
            return false
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.eventTap = tap
        self.runLoopSource = src
        klog("FnKeyMonitor: started (mode=\(mode), combo=\(String(describing: comboKeyCode)))")
        return true
    }

    /// CGEventTap を停止して破棄。
    func stop() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        fnDown = false
        fnUsedAsModifier = false
        fnDownAt = nil
        klog("FnKeyMonitor: stopped")
    }

    /// 設定変更時に再構成する (mode / comboKeyCode を更新)。
    func reconfigure(mode: String, comboKeyCode: Int?) {
        self.mode = mode
        self.comboKeyCode = comboKeyCode
        klog("FnKeyMonitor: reconfigured mode=\(mode) combo=\(String(describing: comboKeyCode))")
    }

    // MARK: - Internal handling

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .flagsChanged:
            handleFlagsChanged(event)
        case .keyDown:
            handleKeyDown(event)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // OS にタップを無効化されたら再有効化
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                klog("FnKeyMonitor: tap re-enabled after \(type.rawValue)")
            }
        default:
            break
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let flags = event.flags
        let fnNowDown = flags.contains(.maskSecondaryFn)

        if fnNowDown && !fnDown {
            // Fn 押下開始
            fnDown = true
            fnUsedAsModifier = false
            fnDownAt = Date()
            if mode == "hold_ptt" {
                DispatchQueue.main.async { [weak self] in self?.onFnHoldStart?() }
            }
        } else if !fnNowDown && fnDown {
            // Fn 解放
            let pressedFor = fnDownAt.map { Date().timeIntervalSince($0) } ?? 0
            fnDown = false
            fnDownAt = nil

            if mode == "hold_ptt" {
                DispatchQueue.main.async { [weak self] in self?.onFnHoldEnd?() }
            } else {
                // tap_toggle: 他キー未使用 かつ 短時間押下 のみ発火
                if !fnUsedAsModifier && pressedFor < tapMaxDuration {
                    DispatchQueue.main.async { [weak self] in self?.onFnTap?() }
                }
            }
            fnUsedAsModifier = false
        }
    }

    private func handleKeyDown(_ event: CGEvent) {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let hasFn = flags.contains(.maskSecondaryFn)

        // Fn 押下中に何かキーが押された → 単独タップではない
        if fnDown {
            fnUsedAsModifier = true
        }

        // Fn+設定キー コンボ判定 (Carbon では発火できないので CGEventTap で扱う)
        if hasFn, let combo = comboKeyCode, combo == keyCode {
            DispatchQueue.main.async { [weak self] in self?.onFnComboShortcut?() }
        }
    }
}
