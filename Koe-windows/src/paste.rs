use log::info;

/// テキストをアクティブウィンドウに貼り付け
/// 1. クリップボードの現在の内容を保存
/// 2. 認識結果をクリップボードにセット
/// 3. Ctrl+V をシミュレート
/// 4. 120ms後に元のクリップボード内容を復元
pub fn paste_text(text: &str) {
    info!("Pasting: '{}'", text);

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
    simulate_paste();

    // 120ms後にクリップボード復元
    std::thread::sleep(std::time::Duration::from_millis(120));
    if let Some(prev) = prev_text {
        let _ = clipboard.set_text(prev);
    }
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
