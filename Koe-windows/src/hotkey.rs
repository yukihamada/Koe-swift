use log::info;
use std::sync::{Arc, Mutex};

use global_hotkey::{
    hotkey::{Code, HotKey, Modifiers},
    GlobalHotKeyManager,
};

use crate::audio::Recorder;
use crate::SharedState;

/// グローバルホットキーの管理
pub struct HotkeyManager {
    _manager: GlobalHotKeyManager,
    hotkey_id: u32,
}

impl HotkeyManager {
    /// ホットキーを登録 (デフォルト: Ctrl+Alt+V)
    pub fn new() -> Result<(Self, u32), String> {
        let manager = GlobalHotKeyManager::new()
            .map_err(|e| format!("Failed to create hotkey manager: {}", e))?;

        let hotkey = HotKey::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::KeyV);
        let id = hotkey.id();

        manager
            .register(hotkey)
            .map_err(|e| format!("Failed to register hotkey Ctrl+Alt+V: {}", e))?;

        info!("Hotkey registered: Ctrl+Alt+V (id={})", id);

        Ok((
            Self {
                _manager: manager,
                hotkey_id: id,
            },
            id,
        ))
    }
}

/// ホットキーイベントを処理 (Toggle方式)
/// Recorder はメインスレッドに残し、バッファだけ別スレッドに渡す
pub fn handle_hotkey_event(shared: &Arc<Mutex<SharedState>>, recorder: &mut Recorder) {
    let is_recording = {
        let s = shared.lock().unwrap();
        s.recording
    };

    if is_recording {
        // 録音停止 → 認識開始
        info!("Hotkey: stop recording & recognize");
        shared.lock().unwrap().recording = false;

        // メインスレッドで録音停止 & WAV保存
        let wav_path = recorder.stop();

        // 認識はバックグラウンドスレッドで
        let shared_clone = shared.clone();
        std::thread::spawn(move || {
            recognize_and_paste(shared_clone, wav_path);
        });
    } else {
        let s = shared.lock().unwrap();
        if s.recognizing {
            info!("Hotkey: ignored (recognizing)");
            return;
        }
        drop(s);

        // メインスレッドで録音開始
        info!("Hotkey: start recording");
        if let Err(e) = recorder.start() {
            log::error!("Failed to start recording: {}", e);
            return;
        }
        shared.lock().unwrap().recording = true;
    }
}

/// 文字起こし → 貼り付け（バックグラウンドスレッドで実行）
fn recognize_and_paste(shared: Arc<Mutex<SharedState>>, wav_path: Option<std::path::PathBuf>) {
    shared.lock().unwrap().recognizing = true;

    let Some(wav_path) = wav_path else {
        shared.lock().unwrap().recognizing = false;
        info!("No audio recorded");
        return;
    };

    // 文字起こし
    let result = {
        let s = shared.lock().unwrap();
        let lang = s.config.lang_code();
        let prompt = if lang == "ja" || lang == "auto" {
            "Windows音声入力"
        } else {
            "Windows voice input"
        };

        match &s.whisper {
            Some(engine) => engine.transcribe(&wav_path, lang, prompt),
            None => {
                log::error!("Whisper engine not loaded");
                Err("No engine".into())
            }
        }
    };

    match result {
        Ok(text) if !text.is_empty() => {
            info!("Result: '{}'", text);
            crate::paste::paste_text(&text);
        }
        Ok(_) => info!("Empty transcription, skipped"),
        Err(e) => log::error!("Transcription error: {}", e),
    }

    shared.lock().unwrap().recognizing = false;
    info!("Recognition complete");
}
