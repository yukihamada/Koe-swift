use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// 利用可能なWhisperモデル
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WhisperModel {
    pub id: String,
    pub name: String,
    pub description: String,
    pub file_name: String,
    pub url: String,
    pub size_mb: u64,
    pub is_default: bool,
    pub is_japanese_only: bool,
}

impl WhisperModel {
    pub fn supports_language(&self, lang: &str) -> bool {
        if !self.is_japanese_only {
            return true;
        }
        matches!(lang, "ja" | "ja-JP" | "auto")
    }
}

/// 利用可能なモデル一覧
pub fn available_models() -> Vec<WhisperModel> {
    vec![
        WhisperModel {
            id: "kotoba-v2-q5".into(),
            name: "Kotoba v2.0 Q5 (推奨)".into(),
            description: "日本語特化・高精度・軽量".into(),
            file_name: "ggml-kotoba-whisper-v2.0-q5_0.bin".into(),
            url: "https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0-ggml/resolve/main/ggml-kotoba-whisper-v2.0-q5_0.bin".into(),
            size_mb: 538,
            is_default: true,
            is_japanese_only: true,
        },
        WhisperModel {
            id: "large-v3-turbo-q5".into(),
            name: "Large V3 Turbo Q5".into(),
            description: "多言語対応・軽量".into(),
            file_name: "ggml-large-v3-turbo-q5_0.bin".into(),
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin".into(),
            size_mb: 547,
            is_default: false,
            is_japanese_only: false,
        },
        WhisperModel {
            id: "large-v3-turbo".into(),
            name: "Large V3 Turbo".into(),
            description: "多言語対応・高速".into(),
            file_name: "ggml-large-v3-turbo.bin".into(),
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin".into(),
            size_mb: 1500,
            is_default: false,
            is_japanese_only: false,
        },
        WhisperModel {
            id: "medium".into(),
            name: "Medium".into(),
            description: "多言語対応・バランス型".into(),
            file_name: "ggml-medium.bin".into(),
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin".into(),
            size_mb: 1500,
            is_default: false,
            is_japanese_only: false,
        },
    ]
}

/// デフォルトモデル
pub fn default_model() -> WhisperModel {
    available_models().into_iter().find(|m| m.is_default).unwrap()
}

/// 言語に最適なモデルを返す
pub fn best_model_for(lang: &str) -> WhisperModel {
    let models = available_models();
    // 日本語ならKotobaを推奨
    if lang == "ja" || lang == "ja-JP" {
        return models.into_iter().find(|m| m.id == "kotoba-v2-q5").unwrap();
    }
    // 他言語はLarge V3 Turbo Q5
    models
        .into_iter()
        .find(|m| m.id == "large-v3-turbo-q5")
        .unwrap()
}

/// 対応言語一覧
pub fn supported_languages() -> Vec<(&'static str, &'static str, &'static str)> {
    vec![
        ("🇯🇵", "日本語", "ja"),
        ("🇺🇸", "English", "en"),
        ("🇨🇳", "中文(简体)", "zh"),
        ("🇹🇼", "中文(繁體)", "zh"),
        ("🇰🇷", "한국어", "ko"),
        ("🇪🇸", "Español", "es"),
        ("🇫🇷", "Français", "fr"),
        ("🇩🇪", "Deutsch", "de"),
        ("🇮🇹", "Italiano", "it"),
        ("🇵🇹", "Português", "pt"),
        ("🇷🇺", "Русский", "ru"),
        ("🇮🇳", "हिन्दी", "hi"),
        ("🇹🇭", "ไทย", "th"),
        ("🇻🇳", "Tiếng Việt", "vi"),
        ("🇮🇩", "Indonesia", "id"),
        ("🇳🇱", "Nederlands", "nl"),
        ("🇵🇱", "Polski", "pl"),
        ("🇹🇷", "Türkçe", "tr"),
        ("🇸🇦", "العربية", "ar"),
        ("🌐", "Auto Detect", "auto"),
    ]
}

/// アプリケーション設定
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub language: String,
    pub model_id: String,
    pub hotkey_modifiers: u32, // MOD_ALT | MOD_CONTROL etc.
    pub hotkey_vk: u32,        // Virtual key code
    pub recording_mode: RecordingMode,
    pub llm_enabled: bool,
    pub llm_provider: String,
    pub llm_api_key: String,
    pub llm_base_url: String,
    pub llm_model: String,
    pub llm_mode: String,
    pub auto_copy: bool,
    pub streaming_preview: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum RecordingMode {
    Hold,
    Toggle,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            language: "ja".into(),
            model_id: "kotoba-v2-q5".into(),
            hotkey_modifiers: 0x0001 | 0x0002, // MOD_ALT | MOD_CONTROL
            hotkey_vk: 0x56,                    // 'V' key
            recording_mode: RecordingMode::Hold,
            llm_enabled: true,
            llm_provider: "chatweb".into(),
            llm_api_key: String::new(),
            llm_base_url: "https://api.chatweb.ai".into(),
            llm_model: "auto".into(),
            llm_mode: "correct".into(),
            auto_copy: false,
            streaming_preview: true,
        }
    }
}

impl Config {
    /// 設定ファイルのパス
    pub fn path() -> PathBuf {
        Self::data_dir().join("config.json")
    }

    /// データディレクトリ (%APPDATA%\Koe)
    pub fn data_dir() -> PathBuf {
        dirs::config_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("Koe")
    }

    /// モデル保存ディレクトリ
    pub fn model_dir() -> PathBuf {
        Self::data_dir().join("models")
    }

    /// 一時ファイルディレクトリ
    pub fn temp_dir() -> PathBuf {
        std::env::temp_dir().join("koe")
    }

    /// 設定を読み込み（なければデフォルト）
    pub fn load() -> Self {
        let path = Self::path();
        if path.exists() {
            match std::fs::read_to_string(&path) {
                Ok(s) => match serde_json::from_str(&s) {
                    Ok(c) => return c,
                    Err(e) => log::warn!("Config parse error: {}, using defaults", e),
                },
                Err(e) => log::warn!("Config read error: {}, using defaults", e),
            }
        }
        let config = Self::default();
        let _ = config.save();
        config
    }

    /// 設定を保存
    pub fn save(&self) -> Result<(), std::io::Error> {
        let dir = Self::data_dir();
        std::fs::create_dir_all(&dir)?;
        let json = serde_json::to_string_pretty(self).map_err(|e| {
            std::io::Error::new(std::io::ErrorKind::Other, e)
        })?;
        std::fs::write(Self::path(), json)
    }

    /// 現在の言語の2文字コード
    pub fn lang_code(&self) -> &str {
        if self.language == "auto" {
            "auto"
        } else {
            self.language.split('-').next().unwrap_or("en")
        }
    }
}
