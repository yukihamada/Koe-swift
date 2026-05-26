use log::{info, warn};

/// テキストをアクティブウィンドウに貼り付け
/// 1. 起動時のフォアグラウンドウィンドウ HWND を記録
/// 2. クリップボードの現在の内容を保存
/// 3. 認識結果をクリップボードにセット
/// 4. SendInput 直前に再度フォアグラウンドを確認、変化していれば中止（W-04）
/// 5. Ctrl+V をシミュレート
/// 6. 120ms後に元のクリップボード内容を復元
pub fn paste_text(text: &str) {
    info!("Pasting: '{}'", text);

    // W-04: capture the foreground window at entry; we will refuse to paste
    // if focus has moved by the time we are ready to SendInput.
    let start_hwnd = current_foreground_hwnd();

    let mut clipboard = match arboard::Clipboard::new() {
        Ok(c) => c,
        Err(e) => {
            log::error!("Clipboard error: {}", e);
            return;
        }
    };

    // クリップボードの現在の内容を保存
    let prev_text = clipboard.get_text().ok();

    // 認識結果をセット
    if let Err(e) = clipboard.set_text(text) {
        log::error!("Failed to set clipboard: {}", e);
        return;
    }

    // 少し待ってからCtrl+Vシミュレート（クリップボード反映待ち）
    std::thread::sleep(std::time::Duration::from_millis(30));

    // W-04: re-check foreground; bail out if it changed (e.g. user Alt-Tabbed
    // to a password manager / different field) — restore clipboard first.
    let current_hwnd = current_foreground_hwnd();
    if current_hwnd != start_hwnd {
        warn!(
            "Foreground window changed during paste (start={:?}, now={:?}); aborting SendInput",
            start_hwnd, current_hwnd
        );
        if let Some(prev) = prev_text {
            let _ = clipboard.set_text(prev);
        }
        return;
    }

    simulate_paste();

    // 120ms後にクリップボード復元
    std::thread::sleep(std::time::Duration::from_millis(120));
    if let Some(prev) = prev_text {
        let _ = clipboard.set_text(prev);
    }
}

/// Returns an opaque identifier for the current foreground window.
/// Returns `None` on non-Windows targets or if the API call fails.
///
/// `HWND` in `windows` crate 0.58 is `pub struct HWND(pub *mut c_void)`,
/// so we compare via `is_null()` and store as `usize` (PartialEq-friendly,
/// no raw-pointer Send/Sync issues if we ever pass it across threads).
#[cfg(target_os = "windows")]
fn current_foreground_hwnd() -> Option<usize> {
    use windows::Win32::UI::WindowsAndMessaging::GetForegroundWindow;
    let hwnd = unsafe { GetForegroundWindow() };
    if hwnd.0.is_null() {
        None
    } else {
        Some(hwnd.0 as usize)
    }
}

#[cfg(not(target_os = "windows"))]
fn current_foreground_hwnd() -> Option<usize> {
    None
}

/// Ctrl+V キー入力をシミュレート
#[cfg(target_os = "windows")]
fn simulate_paste() {
    use std::mem;
    use windows::Win32::UI::Input::KeyboardAndMouse::*;

    let inputs = vec![
        make_key_input(VK_CONTROL, false),
        make_key_input(VIRTUAL_KEY(0x56), false), // V down
        make_key_input(VIRTUAL_KEY(0x56), true),  // V up
        make_key_input(VK_CONTROL, true),
    ];

    unsafe {
        SendInput(&inputs, mem::size_of::<INPUT>() as i32);
    }
}

#[cfg(target_os = "windows")]
fn make_key_input(vk: windows::Win32::UI::Input::KeyboardAndMouse::VIRTUAL_KEY, key_up: bool) -> windows::Win32::UI::Input::KeyboardAndMouse::INPUT {
    use windows::Win32::UI::Input::KeyboardAndMouse::*;

    let flags = if key_up {
        KEYEVENTF_KEYUP
    } else {
        KEYBD_EVENT_FLAGS(0)
    };

    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: vk,
                wScan: 0,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    }
}

#[cfg(not(target_os = "windows"))]
fn simulate_paste() {
    info!("Paste simulation (non-Windows): skipped");
}
