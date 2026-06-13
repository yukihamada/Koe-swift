import AppKit

/// マウスクリックの CGEvent 送出を一元化（AgentMode に散在していた重複を集約）。
enum ClickSynthesizer {
    /// グローバル画面座標（top-left origin・points）を左クリック。
    static func click(at point: CGPoint) {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left)
        else { return }
        down.post(tap: .cghidEventTap)
        usleep(50_000)
        up.post(tap: .cghidEventTap)
    }
}

/// スクロールホイールの CGEvent 送出。
enum ScrollSynthesizer {
    enum Direction { case up, down, left, right }

    /// 指定方向に `lines` 行スクロール。
    static func scroll(_ direction: Direction, lines: Int32 = 5) {
        let dy: Int32
        let dx: Int32
        switch direction {
        case .up:    dy =  lines; dx = 0
        case .down:  dy = -lines; dx = 0
        case .left:  dy = 0; dx =  lines
        case .right: dy = 0; dx = -lines
        }
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                  wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        else { return }
        event.post(tap: .cghidEventTap)
    }
}
