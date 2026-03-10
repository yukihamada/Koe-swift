use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use hound::{SampleFormat, WavSpec, WavWriter};
use log::{error, info};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

/// 録音バッファ（スレッド間で共有可能）
#[derive(Clone)]
pub struct RecordingBuffer {
    samples: Arc<Mutex<Vec<f32>>>,
    recording: Arc<Mutex<bool>>,
}

impl RecordingBuffer {
    pub fn new() -> Self {
        Self {
            samples: Arc::new(Mutex::new(Vec::new())),
            recording: Arc::new(Mutex::new(false)),
        }
    }

    pub fn clear(&self) {
        self.samples.lock().unwrap().clear();
    }

    pub fn set_recording(&self, val: bool) {
        *self.recording.lock().unwrap() = val;
    }

    pub fn is_recording(&self) -> bool {
        *self.recording.lock().unwrap()
    }

    pub fn get_samples(&self) -> Vec<f32> {
        self.samples.lock().unwrap().clone()
    }

    /// 録音中のサンプルをWAVに保存
    pub fn save_wav(&self) -> Option<PathBuf> {
        let samples = self.samples.lock().unwrap().clone();
        if samples.is_empty() {
            info!("No audio recorded");
            return None;
        }

        info!(
            "Recorded {} samples ({:.1}s)",
            samples.len(),
            samples.len() as f64 / 16000.0
        );

        let temp_dir = crate::config::Config::temp_dir();
        let _ = std::fs::create_dir_all(&temp_dir);
        let path = temp_dir.join("recording.wav");

        match write_wav(&path, &samples) {
            Ok(_) => {
                info!("Saved WAV: {}", path.display());
                Some(path)
            }
            Err(e) => {
                error!("Failed to save WAV: {}", e);
                None
            }
        }
    }
}

/// 16kHz mono 16-bit PCM で録音するレコーダー
/// cpal::Stream は Send ではないため、メインスレッドで保持
pub struct Recorder {
    stream: Option<cpal::Stream>,
    pub buffer: RecordingBuffer,
}

impl Recorder {
    pub fn new() -> Self {
        Self {
            stream: None,
            buffer: RecordingBuffer::new(),
        }
    }

    /// 録音開始
    pub fn start(&mut self) -> Result<(), String> {
        let host = cpal::default_host();
        let device = host
            .default_input_device()
            .ok_or("No input device found")?;

        info!("Recording device: {}", device.name().unwrap_or_default());

        let config = cpal::StreamConfig {
            channels: 1,
            sample_rate: cpal::SampleRate(16000),
            buffer_size: cpal::BufferSize::Default,
        };

        self.buffer.clear();
        self.buffer.set_recording(true);

        let samples = self.buffer.samples.clone();
        let recording = self.buffer.recording.clone();

        let stream = device
            .build_input_stream(
                &config,
                move |data: &[f32], _: &cpal::InputCallbackInfo| {
                    if *recording.lock().unwrap() {
                        samples.lock().unwrap().extend_from_slice(data);
                    }
                },
                move |err| {
                    error!("Audio input error: {}", err);
                },
                None,
            )
            .map_err(|e| format!("Failed to build input stream: {}", e))?;

        stream
            .play()
            .map_err(|e| format!("Failed to start recording: {}", e))?;
        self.stream = Some(stream);

        info!("Recording started (16kHz mono)");
        Ok(())
    }

    /// 録音停止、WAVファイルとして保存
    pub fn stop(&mut self) -> Option<PathBuf> {
        self.buffer.set_recording(false);
        self.stream.take(); // ストリーム停止
        self.buffer.save_wav()
    }
}

/// WAVファイルとして保存 (16kHz mono 16-bit PCM)
fn write_wav(path: &PathBuf, samples: &[f32]) -> Result<(), String> {
    let spec = WavSpec {
        channels: 1,
        sample_rate: 16000,
        bits_per_sample: 16,
        sample_format: SampleFormat::Int,
    };

    let mut writer =
        WavWriter::create(path, spec).map_err(|e| format!("WavWriter error: {}", e))?;

    for &sample in samples {
        let s16 = (sample * 32767.0).clamp(-32768.0, 32767.0) as i16;
        writer
            .write_sample(s16)
            .map_err(|e| format!("Write error: {}", e))?;
    }

    writer
        .finalize()
        .map_err(|e| format!("Finalize error: {}", e))?;

    Ok(())
}

/// 音声アクティビティ検出 (VAD)
pub fn has_voice_activity(samples: &[f32]) -> bool {
    let threshold: f32 = 0.01;
    let frame_size = 160; // 10ms @ 16kHz
    let min_frames = 5;

    let mut voice_frames = 0;
    for chunk in samples.chunks(frame_size) {
        if chunk.len() < frame_size {
            break;
        }
        let rms: f32 = (chunk.iter().map(|s| s * s).sum::<f32>() / chunk.len() as f32).sqrt();
        if rms > threshold {
            voice_frames += 1;
        }
    }

    voice_frames >= min_frames
}

/// DSP前処理: プリエンファシス + 正規化
pub fn preprocess(samples: &[f32]) -> Vec<f32> {
    if samples.is_empty() {
        return vec![];
    }

    // 1. プリエンファシス: y[n] = x[n] - 0.97 * x[n-1]
    let alpha = 0.97f32;
    let mut emphasized = Vec::with_capacity(samples.len());
    emphasized.push(samples[0]);
    for i in 1..samples.len() {
        emphasized.push(samples[i] - alpha * samples[i - 1]);
    }

    // 2. ボリューム正規化 (ピーク → 0.9)
    let peak = emphasized
        .iter()
        .map(|s| s.abs())
        .fold(0.0f32, f32::max);

    if peak > 0.001 {
        let gain = (0.9 / peak).min(10.0);
        for s in &mut emphasized {
            *s *= gain;
        }
    }

    emphasized
}
