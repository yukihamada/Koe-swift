import Foundation

/// 軽量ローカライズヘルパー。システム言語 or AppSettings.shared.language に基づく。
enum L10n {
    /// 現在の2文字言語プレフィックス
    static var lang: String {
        let appLang = AppSettings.shared.language
        let code = appLang.isEmpty ? (Locale.preferredLanguages.first ?? "en") : appLang
        return code.components(separatedBy: "-").first ?? "en"
    }

    // MARK: - Onboarding

    static var taglineAppleSilicon: String {
        switch lang {
        case "ja": return "Mac で最も速い日本語音声入力"
        case "zh": return "Mac 上最快的语音输入"
        case "ko": return "Mac에서 가장 빠른 음성 입력"
        default:   return "The fastest voice input on Mac"
        }
    }

    static var taglineIntel: String {
        switch lang {
        case "ja": return "Mac で快適な日本語音声入力"
        case "zh": return "Mac 上舒适的语音输入"
        case "ko": return "Mac에서 편리한 음성 입력"
        default:   return "Comfortable voice input on Mac"
        }
    }

    static var startSetup: String {
        switch lang {
        case "ja": return "セットアップを始める"
        case "zh": return "开始设置"
        case "ko": return "설정 시작"
        default:   return "Start Setup"
        }
    }

    static var setupTitle: String {
        switch lang {
        case "ja": return "セットアップ"
        case "zh": return "设置"
        case "ko": return "설정"
        default:   return "Setup"
        }
    }

    static func stepsToComplete(_ n: Int) -> String {
        switch lang {
        case "ja": return "\(n)ステップで完了します"
        case "zh": return "\(n)个步骤即可完成"
        case "ko": return "\(n)단계로 완료됩니다"
        default:   return "\(n) steps to complete"
        }
    }

    // MARK: - Setup steps

    static var stepVoiceModel: String {
        switch lang {
        case "ja": return "音声認識モデル"
        case "zh": return "语音识别模型"
        case "ko": return "음성인식 모델"
        default:   return "Speech Recognition Model"
        }
    }

    static var stepAIModel: String {
        switch lang {
        case "ja": return "AI後処理モデル"
        case "zh": return "AI后处理模型"
        case "ko": return "AI 후처리 모델"
        default:   return "AI Post-processing Model"
        }
    }

    static var stepMicrophone: String {
        switch lang {
        case "ja": return "マイク権限"
        case "zh": return "麦克风权限"
        case "ko": return "마이크 권한"
        default:   return "Microphone Permission"
        }
    }

    static var stepAccessibility: String {
        switch lang {
        case "ja": return "アクセシビリティ権限"
        case "zh": return "辅助功能权限"
        case "ko": return "접근성 권한"
        default:   return "Accessibility Permission"
        }
    }

    static var stepDone: String {
        switch lang {
        case "ja": return "完了"
        case "zh": return "完成"
        case "ko": return "완료"
        default:   return "Done"
        }
    }

    // MARK: - Model download

    static var modelSelectLabel: String {
        switch lang {
        case "ja": return "モデル選択:"
        case "zh": return "选择模型:"
        case "ko": return "모델 선택:"
        default:   return "Select Model:"
        }
    }

    static var setupStart: String {
        switch lang {
        case "ja": return "セットアップ開始"
        case "zh": return "开始设置"
        case "ko": return "설정 시작"
        default:   return "Start Setup"
        }
    }

    static var downloadingModel: String {
        switch lang {
        case "ja": return "音声認識モデルをダウンロード中..."
        case "zh": return "正在下载语音识别模型..."
        case "ko": return "음성인식 모델 다운로드 중..."
        default:   return "Downloading speech recognition model..."
        }
    }

    static var modelDownloadComplete: String {
        switch lang {
        case "ja": return "モデルダウンロード完了"
        case "zh": return "模型下载完成"
        case "ko": return "모델 다운로드 완료"
        default:   return "Model download complete"
        }
    }

    static var modelAlreadyDownloaded: String {
        switch lang {
        case "ja": return "モデルは既にダウンロード済み"
        case "zh": return "模型已下载"
        case "ko": return "모델이 이미 다운로드됨"
        default:   return "Model already downloaded"
        }
    }

    static var downloadFailed: String {
        switch lang {
        case "ja": return "ダウンロード失敗"
        case "zh": return "下载失败"
        case "ko": return "다운로드 실패"
        default:   return "Download failed"
        }
    }

    static var retry: String {
        switch lang {
        case "ja": return "リトライ"
        case "zh": return "重试"
        case "ko": return "재시도"
        default:   return "Retry"
        }
    }

    static var intelNoModelNeeded: String {
        switch lang {
        case "ja": return "Intel Mac — モデルダウンロード不要"
        case "zh": return "Intel Mac — 无需下载模型"
        case "ko": return "Intel Mac — 모델 다운로드 불필요"
        default:   return "Intel Mac — No model download needed"
        }
    }

    static var intelUseApple: String {
        switch lang {
        case "ja": return "Apple オンデバイス認識を使用します"
        case "zh": return "使用 Apple 设备端识别"
        case "ko": return "Apple 온디바이스 인식을 사용합니다"
        default:   return "Using Apple on-device recognition"
        }
    }

    // MARK: - LLM step

    static var llmModelSkipped: String {
        switch lang {
        case "ja": return "AI後処理モデル — スキップ"
        case "zh": return "AI后处理模型 — 跳过"
        case "ko": return "AI 후처리 모델 — 건너뜀"
        default:   return "AI post-processing model — Skipped"
        }
    }

    static var llmAlreadyDownloaded: String {
        switch lang {
        case "ja": return "AI後処理モデルは既にダウンロード済み"
        case "zh": return "AI后处理模型已下载"
        case "ko": return "AI 후처리 모델이 이미 다운로드됨"
        default:   return "AI post-processing model already downloaded"
        }
    }

    static var llmLocalAI: String {
        switch lang {
        case "ja": return "ローカルAI後処理モデル"
        case "zh": return "本地AI后处理模型"
        case "ko": return "로컬 AI 후처리 모델"
        default:   return "Local AI post-processing model"
        }
    }

    static var llmOfflineCapable: String {
        switch lang {
        case "ja": return "完全オフラインAI後処理が可能になります"
        case "zh": return "支持完全离线AI后处理"
        case "ko": return "완전 오프라인 AI 후처리가 가능합니다"
        default:   return "Enables fully offline AI post-processing"
        }
    }

    static var llmDownloading: String {
        switch lang {
        case "ja": return "AI後処理モデルをダウンロード中..."
        case "zh": return "正在下载AI后处理模型..."
        case "ko": return "AI 후처리 모델 다운로드 중..."
        default:   return "Downloading AI post-processing model..."
        }
    }

    static var llmDownloadComplete: String {
        switch lang {
        case "ja": return "AI後処理モデル ダウンロード完了"
        case "zh": return "AI后处理模型下载完成"
        case "ko": return "AI 후처리 모델 다운로드 완료"
        default:   return "AI post-processing model download complete"
        }
    }

    static var llmDownloadFailed: String {
        switch lang {
        case "ja": return "ダウンロード失敗（後から設定で再試行可能）"
        case "zh": return "下载失败（稍后可在设置中重试）"
        case "ko": return "다운로드 실패 (나중에 설정에서 재시도 가능)"
        default:   return "Download failed (retry later in Settings)"
        }
    }

    static var download: String {
        switch lang {
        case "ja": return "ダウンロード"
        case "zh": return "下载"
        case "ko": return "다운로드"
        default:   return "Download"
        }
    }

    static var skip: String {
        switch lang {
        case "ja": return "スキップ"
        case "zh": return "跳过"
        case "ko": return "건너뛰기"
        default:   return "Skip"
        }
    }

    static var skipAvailableLater: String {
        switch lang {
        case "ja": return "設定からいつでもダウンロードできます"
        case "zh": return "可随时在设置中下载"
        case "ko": return "설정에서 언제든 다운로드할 수 있습니다"
        default:   return "Available for download anytime in Settings"
        }
    }

    // MARK: - Microphone

    static var micRequestAccess: String {
        switch lang {
        case "ja": return "マイクへのアクセスを許可してください"
        case "zh": return "请允许访问麦克风"
        case "ko": return "마이크 접근을 허용해주세요"
        default:   return "Please allow microphone access"
        }
    }

    static var micNeeded: String {
        switch lang {
        case "ja": return "音声入力に必要です"
        case "zh": return "语音输入需要此权限"
        case "ko": return "음성 입력에 필요합니다"
        default:   return "Required for voice input"
        }
    }

    static var micOK: String {
        switch lang {
        case "ja": return "マイク権限 OK"
        case "zh": return "麦克风权限 OK"
        case "ko": return "마이크 권한 OK"
        default:   return "Microphone permission OK"
        }
    }

    static var micRequired: String {
        switch lang {
        case "ja": return "マイク権限が必要です"
        case "zh": return "需要麦克风权限"
        case "ko": return "마이크 권한이 필요합니다"
        default:   return "Microphone permission required"
        }
    }

    static var micOpenSettings: String {
        switch lang {
        case "ja": return "システム設定 → プライバシーとセキュリティ → マイク"
        case "zh": return "系统设置 → 隐私与安全 → 麦克风"
        case "ko": return "시스템 설정 → 개인정보 보호 → 마이크"
        default:   return "System Settings → Privacy & Security → Microphone"
        }
    }

    // MARK: - Accessibility

    static var accessibilityOK: String {
        switch lang {
        case "ja": return "アクセシビリティ権限 OK"
        case "zh": return "辅助功能权限 OK"
        case "ko": return "접근성 권한 OK"
        default:   return "Accessibility permission OK"
        }
    }

    static var accessibilityRequest: String {
        switch lang {
        case "ja": return "アクセシビリティ権限を許可してください"
        case "zh": return "请允许辅助功能权限"
        case "ko": return "접근성 권한을 허용해주세요"
        default:   return "Please allow accessibility permission"
        }
    }

    static var accessibilityNeeded: String {
        switch lang {
        case "ja": return "テキスト入力に必要です。ダイアログが表示されます。"
        case "zh": return "文本输入需要此权限。将显示对话框。"
        case "ko": return "텍스트 입력에 필요합니다. 대화상자가 표시됩니다."
        default:   return "Required for text input. A dialog will appear."
        }
    }

    // MARK: - Done

    static var setupComplete: String {
        switch lang {
        case "ja": return "セットアップ完了！"
        case "zh": return "设置完成！"
        case "ko": return "설정 완료!"
        default:   return "Setup complete!"
        }
    }

    static var usageGuide: String {
        switch lang {
        case "ja": return "⌥⌘V を長押し → 話す → 離すと変換\nトグルモードなら2回押しで録音開始/停止"
        case "zh": return "长按 ⌥⌘V → 说话 → 松开即转换\n切换模式下按两次开始/停止录音"
        case "ko": return "⌥⌘V 길게 누르기 → 말하기 → 놓으면 변환\n토글 모드에서는 두 번 눌러 녹음 시작/중지"
        default:   return "Hold ⌥⌘V → Speak → Release to convert\nIn toggle mode, press twice to start/stop"
        }
    }

    static var letsGo: String {
        switch lang {
        case "ja": return "始める"
        case "zh": return "开始"
        case "ko": return "시작"
        default:   return "Let's Go"
        }
    }

    // MARK: - Tutorial (Post-Setup Guide)

    static var tutorialTitle: String {
        switch lang {
        case "ja": return "使い方ガイド"
        case "zh": return "使用指南"
        case "ko": return "사용 가이드"
        default:   return "How to Use"
        }
    }

    static var tutorialReady: String {
        switch lang {
        case "ja": return "準備完了！さっそく使ってみましょう"
        case "zh": return "准备就绪！让我们开始吧"
        case "ko": return "준비 완료! 바로 사용해 보세요"
        default:   return "All set! Let's get started"
        }
    }

    /// チュートリアルの機能カード: (SF Symbol, タイトル, 説明, ショートカット or ヒント)
    static var tutorialCards: [(icon: String, title: String, desc: String, shortcut: String)] {
        switch lang {
        case "ja": return [
            ("mic.fill", "音声入力", "どのアプリでも声でテキスト入力", "⌥⌘V 長押し"),
            ("doc.text.fill", "議事録モード", "会議の音声を自動で文字起こし・整形", "⌥⌘M"),
            ("globe", "20以上の言語", "日本語・英語・中国語など幅広く対応", "設定で切替"),
            ("gearshape.fill", "カスタマイズ", "ショートカット・言語・アプリ別設定", "メニューバーから"),
        ]
        case "zh": return [
            ("mic.fill", "语音输入", "在任何应用中用声音输入文字", "长按 ⌥⌘V"),
            ("doc.text.fill", "会议记录模式", "自动转录和整理会议音频", "⌥⌘M"),
            ("globe", "20+种语言", "支持日语、英语、中文等多种语言", "在设置中切换"),
            ("gearshape.fill", "自定义", "快捷键、语言、按应用设置", "从菜单栏"),
        ]
        case "ko": return [
            ("mic.fill", "음성 입력", "모든 앱에서 음성으로 텍스트 입력", "⌥⌘V 길게 누르기"),
            ("doc.text.fill", "회의록 모드", "회의 음성을 자동 전사 및 정리", "⌥⌘M"),
            ("globe", "20개 이상의 언어", "일본어, 영어, 중국어 등 폭넓게 지원", "설정에서 전환"),
            ("gearshape.fill", "사용자 설정", "단축키, 언어, 앱별 설정", "메뉴바에서"),
        ]
        default: return [
            ("mic.fill", "Voice Input", "Type with your voice in any app", "Hold ⌥⌘V"),
            ("doc.text.fill", "Meeting Notes", "Auto-transcribe & format meetings", "⌥⌘M"),
            ("globe", "20+ Languages", "Japanese, English, Chinese and more", "Switch in Settings"),
            ("gearshape.fill", "Customize", "Shortcuts, languages, per-app settings", "From menu bar"),
        ]
        }
    }

    static var tutorialTip: String {
        switch lang {
        case "ja": return "メニューバーの「声」アイコンからいつでも設定を変更できます"
        case "zh": return "随时可以从菜单栏的\"声\"图标更改设置"
        case "ko": return "메뉴바의 \"声\" 아이콘에서 언제든 설정을 변경할 수 있습니다"
        default:   return "You can change settings anytime from the \"声\" icon in the menu bar"
        }
    }

    static var tryNow: String {
        switch lang {
        case "ja": return "試してみる"
        case "zh": return "立即试用"
        case "ko": return "지금 사용해보기"
        default:   return "Try It Now"
        }
    }

    static var openSystemSettings: String {
        switch lang {
        case "ja": return "システム設定を開く"
        case "zh": return "打开系统设置"
        case "ko": return "시스템 설정 열기"
        default:   return "Open System Settings"
        }
    }

    static var later: String {
        switch lang {
        case "ja": return "後で"
        case "zh": return "稍后"
        case "ko": return "나중에"
        default:   return "Later"
        }
    }

    static var preparing: String {
        switch lang {
        case "ja": return "準備中..."
        case "zh": return "准备中..."
        case "ko": return "준비 중..."
        default:   return "Preparing..."
        }
    }

    static var downloadError: String {
        switch lang {
        case "ja": return "ダウンロードエラー"
        case "zh": return "下载错误"
        case "ko": return "다운로드 오류"
        default:   return "Download Error"
        }
    }

    static var modelDownloadTitle: String {
        switch lang {
        case "ja": return "Koe — モデルダウンロード中"
        case "zh": return "Koe — 正在下载模型"
        case "ko": return "Koe — 모델 다운로드 중"
        default:   return "Koe — Downloading Model"
        }
    }

    // MARK: - Features (Onboarding)

    static var featuresAppleSilicon: [(String, String, String)] {
        switch lang {
        case "ja": return [
            ("bolt.fill", "0.5秒以内に認識", "whisper.cpp + Metal GPU で超高速変換"),
            ("lock.shield.fill", "完全ローカル処理", "音声データは一切クラウドへ送信しません"),
            ("mic.fill", "ハンズフリー対応", "ウェイクワード「ヘイこえ」で起動"),
            ("app.badge.fill", "アプリ別最適化", "アプリごとにプロンプトや言語を切替"),
        ]
        case "zh": return [
            ("bolt.fill", "0.5秒内识别", "whisper.cpp + Metal GPU 超高速转换"),
            ("lock.shield.fill", "完全本地处理", "语音数据绝不上传至云端"),
            ("mic.fill", "免手动操作", "唤醒词启动"),
            ("app.badge.fill", "按应用优化", "每个应用可设置不同提示词和语言"),
        ]
        case "ko": return [
            ("bolt.fill", "0.5초 내 인식", "whisper.cpp + Metal GPU 초고속 변환"),
            ("lock.shield.fill", "완전 로컬 처리", "음성 데이터는 클라우드로 전송되지 않습니다"),
            ("mic.fill", "핸즈프리 지원", "웨이크워드로 시작"),
            ("app.badge.fill", "앱별 최적화", "앱마다 프롬프트와 언어를 전환"),
        ]
        default: return [
            ("bolt.fill", "Recognition in 0.5s", "Ultra-fast with whisper.cpp + Metal GPU"),
            ("lock.shield.fill", "Fully Local", "Voice data never leaves your Mac"),
            ("mic.fill", "Hands-free", "Start with wake word"),
            ("app.badge.fill", "Per-App Settings", "Switch prompts and languages per app"),
        ]
        }
    }

    static var featuresIntel: [(String, String, String)] {
        switch lang {
        case "ja": return [
            ("icloud.fill", "Apple 音声認識", "Intel Mac ではオンデバイス / クラウド認識を使用"),
            ("globe", "OpenAI Whisper API 対応", "API キーを設定すれば高精度な認識も可能"),
            ("mic.fill", "ハンズフリー対応", "ウェイクワード「ヘイこえ」で起動"),
            ("app.badge.fill", "アプリ別最適化", "アプリごとにプロンプトや言語を切替"),
        ]
        case "zh": return [
            ("icloud.fill", "Apple 语音识别", "Intel Mac 使用设备端/云端识别"),
            ("globe", "支持 OpenAI Whisper API", "设置API密钥可获得高精度识别"),
            ("mic.fill", "免手动操作", "唤醒词启动"),
            ("app.badge.fill", "按应用优化", "每个应用可设置不同提示词和语言"),
        ]
        case "ko": return [
            ("icloud.fill", "Apple 음성 인식", "Intel Mac에서는 온디바이스/클라우드 인식 사용"),
            ("globe", "OpenAI Whisper API 지원", "API 키를 설정하면 고정밀 인식 가능"),
            ("mic.fill", "핸즈프리 지원", "웨이크워드로 시작"),
            ("app.badge.fill", "앱별 최적화", "앱마다 프롬프트와 언어를 전환"),
        ]
        default: return [
            ("icloud.fill", "Apple Speech Recognition", "Uses on-device / cloud recognition on Intel Mac"),
            ("globe", "OpenAI Whisper API", "Set API key for high-accuracy recognition"),
            ("mic.fill", "Hands-free", "Start with wake word"),
            ("app.badge.fill", "Per-App Settings", "Switch prompts and languages per app"),
        ]
        }
    }

    // MARK: - Accessibility alert (AppDelegate)

    static var accessibilityAlertTitle: String {
        switch lang {
        case "ja": return "アクセシビリティ権限が必要です"
        case "zh": return "需要辅助功能权限"
        case "ko": return "접근성 권한이 필요합니다"
        default:   return "Accessibility Permission Required"
        }
    }

    static var accessibilityAlertMessage: String {
        switch lang {
        case "ja": return "⌥⌘V ショートカットを使うには、システム設定 → プライバシーとセキュリティ → アクセシビリティ で Koe を許可してください。\n\n許可後にアプリを再起動してください。"
        case "zh": return "要使用 ⌥⌘V 快捷键，请在系统设置 → 隐私与安全 → 辅助功能中允许 Koe。\n\n允许后请重新启动应用。"
        case "ko": return "⌥⌘V 단축키를 사용하려면 시스템 설정 → 개인정보 보호 → 접근성에서 Koe를 허용해주세요.\n\n허용 후 앱을 재시작해주세요."
        default:   return "To use the ⌥⌘V shortcut, please allow Koe in System Settings → Privacy & Security → Accessibility.\n\nRestart the app after granting permission."
        }
    }

    // MARK: - Model download dialog (ensureModel)

    static var modelDownloadDialogTitle: String {
        switch lang {
        case "ja": return "音声認識モデルのダウンロード"
        case "zh": return "下载语音识别模型"
        case "ko": return "음성인식 모델 다운로드"
        default:   return "Download Speech Recognition Model"
        }
    }

    static func modelDownloadDialogMessage(name: String, sizeMB: Int) -> String {
        switch lang {
        case "ja": return "初回起動のため、音声認識モデルをダウンロードします。\n\nモデル: \(name) (\(sizeMB)MB)"
        case "zh": return "首次启动需要下载语音识别模型。\n\n模型: \(name) (\(sizeMB)MB)"
        case "ko": return "첫 실행을 위해 음성인식 모델을 다운로드합니다.\n\n모델: \(name) (\(sizeMB)MB)"
        default:   return "Downloading speech recognition model for first launch.\n\nModel: \(name) (\(sizeMB)MB)"
        }
    }

    static func downloadingName(_ name: String) -> String {
        switch lang {
        case "ja": return "\(name) をダウンロード中..."
        case "zh": return "正在下载 \(name)..."
        case "ko": return "\(name) 다운로드 중..."
        default:   return "Downloading \(name)..."
        }
    }

    static func saveFailed(_ error: String) -> String {
        switch lang {
        case "ja": return "保存に失敗: \(error)"
        case "zh": return "保存失败: \(error)"
        case "ko": return "저장 실패: \(error)"
        default:   return "Save failed: \(error)"
        }
    }

    static func downloadFailedMessage(_ error: String) -> String {
        switch lang {
        case "ja": return "ダウンロードに失敗しました: \(error)"
        case "zh": return "下载失败: \(error)"
        case "ko": return "다운로드 실패: \(error)"
        default:   return "Download failed: \(error)"
        }
    }

    static func modelSaveFailed(_ error: String) -> String {
        switch lang {
        case "ja": return "モデルの保存に失敗しました: \(error)"
        case "zh": return "模型保存失败: \(error)"
        case "ko": return "모델 저장 실패: \(error)"
        default:   return "Failed to save model: \(error)"
        }
    }
}
