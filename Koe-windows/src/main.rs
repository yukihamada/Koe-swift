// コンソールウィンドウ非表示 (Windows)
#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

mod audio;
mod config;
mod hotkey;
mod model;
mod overlay;
mod paste;
mod transcribe;
mod tray;

use log::info;
use std::sync::{Arc, Mutex};

/// スレッド間で共有する状態（Send + Sync）
pub struct SharedState {
    pub config: config::Config,
    pub recording: bool,
    pub recognizing: bool,
    pub whisper: Option<transcribe::WhisperEngine>,
    pub buffer: audio::RecordingBuffer,
}

fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .format_timestamp_millis()
        .init();

    info!("Koe for Windows v{}", env!("CARGO_PKG_VERSION"));

    let config = config::Config::load();
    info!("Config loaded: lang={}, model={}", config.language, config.model_id);

    let buffer = audio::RecordingBuffer::new();

    let shared = Arc::new(Mutex::new(SharedState {
        config: config.clone(),
        recording: false,
        recognizing: false,
        whisper: None,
        buffer: buffer.clone(),
    }));

    // モデルの確認・ダウンロード
    let model_path = model::ensure_model(&config);

    // Whisperエンジン初期化
    if let Some(path) = &model_path {
        info!("Loading whisper model: {}", path.display());
        match transcribe::WhisperEngine::new(path) {
            Ok(engine) => {
                info!("Whisper model loaded successfully");
                shared.lock().unwrap().whisper = Some(engine);
            }
            Err(e) => {
                log::error!("Failed to load whisper model: {}", e);
            }
        }
    }

    // Recorder はメインスレッドで保持（cpal::Stream は Send ではない）
    let recorder = audio::Recorder::new();

    // メインイベントループ（トレイ + ホットキー）
    tray::run(shared, recorder);
}
