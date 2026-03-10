/// オーバーレイウィンドウ（録音状態の表示）
///
/// Windows版では Win32 API でトップモストの小さなウィンドウを表示。
/// macOS版の SwiftUI OverlayWindow に対応。
///
/// TODO: 本格的なオーバーレイUI実装
/// 現在はコンソールログで状態表示（MVP）

use log::info;

pub enum OverlayState {
    Recording,
    Recognizing,
    Hidden,
}

pub struct Overlay {
    state: OverlayState,
}

impl Overlay {
    pub fn new() -> Self {
        Self {
            state: OverlayState::Hidden,
        }
    }

    pub fn show_recording(&mut self) {
        self.state = OverlayState::Recording;
        info!("🔴 Recording...");
        // TODO: Win32 overlay window with waveform
    }

    pub fn show_recognizing(&mut self) {
        self.state = OverlayState::Recognizing;
        info!("🔵 Recognizing...");
    }

    pub fn hide(&mut self) {
        self.state = OverlayState::Hidden;
    }
}
