use log::{error, info};
use std::path::Path;
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

/// whisper.cpp ラッパー (CUDA GPU対応)
pub struct WhisperEngine {
    ctx: WhisperContext,
}

unsafe impl Send for WhisperEngine {}
unsafe impl Sync for WhisperEngine {}

impl WhisperEngine {
    /// モデルファイルからエンジンを初期化
    pub fn new(model_path: &Path) -> Result<Self, String> {
        let mut params = WhisperContextParameters::default();
        params.use_gpu(true); // CUDA有効化
        params.flash_attn(true); // Flash Attention

        let ctx = WhisperContext::new_with_params(
            model_path.to_str().ok_or("Invalid model path")?,
            params,
        )
        .map_err(|e| format!("Failed to load whisper model: {}", e))?;

        Ok(Self { ctx })
    }

    /// 音声ファイルを文字起こし
    pub fn transcribe(
        &self,
        audio_path: &Path,
        language: &str,
        prompt: &str,
    ) -> Result<String, String> {
        // WAVファイルを読み込み
        let samples = load_wav(audio_path)?;

        // DSP前処理
        let processed = crate::audio::preprocess(&samples);

        // 音声チェック
        if !crate::audio::has_voice_activity(&processed) {
            info!("No voice detected, skipping transcription");
            return Ok(String::new());
        }

        self.transcribe_samples(&processed, language, prompt)
    }

    /// PCMサンプルから直接文字起こし
    pub fn transcribe_samples(
        &self,
        samples: &[f32],
        language: &str,
        prompt: &str,
    ) -> Result<String, String> {
        let mut state = self
            .ctx
            .create_state()
            .map_err(|e| format!("Failed to create whisper state: {}", e))?;

        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });

        // 言語設定
        if language != "auto" {
            params.set_language(Some(language));
        } else {
            params.set_language(None);
            params.set_detect_language(true);
        }

        // パフォーマンス最適化
        let n_threads = std::thread::available_parallelism()
            .map(|n| (n.get() as i32 - 2).max(1))
            .unwrap_or(4);
        params.set_n_threads(n_threads);
        params.set_temperature(0.0); // 確定的推論
        params.set_no_timestamps(true);
        params.set_suppress_blank(true);
        params.set_single_segment(true);
        params.set_no_context(true); // ハルシネーション防止
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);

        // Initial prompt
        if !prompt.is_empty() {
            params.set_initial_prompt(prompt);
        }

        // 推論実行
        let start = std::time::Instant::now();
        state
            .full(params, samples)
            .map_err(|e| format!("Whisper inference error: {}", e))?;

        let elapsed = start.elapsed();
        info!(
            "Whisper inference: {:.0}ms ({:.1}s audio)",
            elapsed.as_millis(),
            samples.len() as f64 / 16000.0
        );

        // セグメント結合
        let n_segments = state.full_n_segments().map_err(|e| format!("{}", e))?;
        let mut text = String::new();
        for i in 0..n_segments {
            if let Ok(seg) = state.full_get_segment_text(i) {
                text.push_str(&seg);
            }
        }

        let result = text.trim().to_string();
        info!("Transcription: '{}'", result);
        Ok(result)
    }
}

/// WAVファイルを読み込んで f32 PCM に変換
fn load_wav(path: &Path) -> Result<Vec<f32>, String> {
    let reader =
        hound::WavReader::open(path).map_err(|e| format!("Failed to open WAV: {}", e))?;

    let spec = reader.spec();
    info!(
        "WAV: {}Hz {}ch {}bit",
        spec.sample_rate, spec.channels, spec.bits_per_sample
    );

    let samples: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Int => reader
            .into_samples::<i16>()
            .filter_map(|s| s.ok())
            .map(|s| s as f32 / 32768.0)
            .collect(),
        hound::SampleFormat::Float => reader
            .into_samples::<f32>()
            .filter_map(|s| s.ok())
            .collect(),
    };

    // モノラルに変換（ステレオの場合）
    if spec.channels > 1 {
        let mono: Vec<f32> = samples
            .chunks(spec.channels as usize)
            .map(|ch| ch.iter().sum::<f32>() / ch.len() as f32)
            .collect();
        Ok(mono)
    } else {
        Ok(samples)
    }
}
