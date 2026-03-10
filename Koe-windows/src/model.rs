use crate::config::{self, Config, WhisperModel};
use log::{error, info};
use std::path::PathBuf;

/// モデルが存在するか確認し、なければダウンロード
pub fn ensure_model(config: &Config) -> Option<PathBuf> {
    let model = config::available_models()
        .into_iter()
        .find(|m| m.id == config.model_id)
        .unwrap_or_else(config::default_model);

    let model_dir = Config::model_dir();
    let _ = std::fs::create_dir_all(&model_dir);
    let model_path = model_dir.join(&model.file_name);

    if model_path.exists() {
        info!("Model found: {}", model_path.display());
        return Some(model_path);
    }

    info!("Model not found, downloading: {} ({}MB)", model.name, model.size_mb);

    match download_model(&model, &model_path) {
        Ok(_) => {
            info!("Model downloaded: {}", model_path.display());
            Some(model_path)
        }
        Err(e) => {
            error!("Download failed: {}", e);
            None
        }
    }
}

/// 指定モデルのパスを取得（ダウンロード済みかチェック）
pub fn model_path(model: &WhisperModel) -> PathBuf {
    Config::model_dir().join(&model.file_name)
}

/// モデルがダウンロード済みか
pub fn is_downloaded(model: &WhisperModel) -> bool {
    model_path(model).exists()
}

/// HuggingFaceからモデルをダウンロード
fn download_model(model: &WhisperModel, dest: &PathBuf) -> Result<(), String> {
    use indicatif::{ProgressBar, ProgressStyle};
    use std::io::Write;

    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(3600))
        .build()
        .map_err(|e| format!("HTTP client error: {}", e))?;

    let resp = client
        .get(&model.url)
        .send()
        .map_err(|e| format!("Download request failed: {}", e))?;

    if !resp.status().is_success() {
        return Err(format!("HTTP {}", resp.status()));
    }

    let total_size = resp.content_length().unwrap_or(model.size_mb * 1_000_000);

    let pb = ProgressBar::new(total_size);
    pb.set_style(
        ProgressStyle::default_bar()
            .template("{msg} [{bar:40.cyan/blue}] {bytes}/{total_bytes} ({eta})")
            .unwrap()
            .progress_chars("█▉▊▋▌▍▎▏ "),
    );
    pb.set_message(format!("Downloading {}", model.name));

    // 一時ファイルに書き込み（途中で失敗しても壊れないように）
    let tmp_path = dest.with_extension("tmp");
    let mut file = std::fs::File::create(&tmp_path)
        .map_err(|e| format!("Failed to create temp file: {}", e))?;

    let mut downloaded: u64 = 0;
    let mut reader = resp;

    loop {
        let mut buf = vec![0u8; 65536];
        match std::io::Read::read(&mut reader, &mut buf) {
            Ok(0) => break,
            Ok(n) => {
                file.write_all(&buf[..n])
                    .map_err(|e| format!("Write error: {}", e))?;
                downloaded += n as u64;
                pb.set_position(downloaded);
            }
            Err(e) => {
                let _ = std::fs::remove_file(&tmp_path);
                return Err(format!("Read error: {}", e));
            }
        }
    }

    file.flush().map_err(|e| format!("Flush error: {}", e))?;
    drop(file);

    // 完了後にリネーム
    std::fs::rename(&tmp_path, dest)
        .map_err(|e| format!("Rename error: {}", e))?;

    pb.finish_with_message(format!("✓ {} downloaded", model.name));
    Ok(())
}
