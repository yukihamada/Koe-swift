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
            ("mic.fill", "声で入力", "押して話すだけ。カーソル位置にテキストが入る", "⌥⌘V"),
            ("arrow.right.doc.on.clipboard", "iPhoneから送信", "iPhoneで話した言葉がMacのクリップボードへ", "同じWiFiで自動接続"),
            ("doc.text.fill", "議事録", "会議を自動で文字起こし。話者分離も対応", "⌥⌘M"),
        ]
        case "zh": return [
            ("mic.fill", "语音输入", "按下说话，文字自动输入到光标位置", "⌥⌘V"),
            ("arrow.right.doc.on.clipboard", "从iPhone发送", "iPhone上说的话自动复制到Mac剪贴板", "同WiFi自动连接"),
            ("doc.text.fill", "会议记录", "自动转录会议，支持说话人分离", "⌥⌘M"),
        ]
        case "ko": return [
            ("mic.fill", "음성 입력", "누르고 말하면 커서 위치에 텍스트 입력", "⌥⌘V"),
            ("arrow.right.doc.on.clipboard", "iPhone에서 전송", "iPhone에서 말한 내용이 Mac 클립보드로", "같은 WiFi에서 자동 연결"),
            ("doc.text.fill", "회의록", "회의를 자동 전사. 화자 분리 지원", "⌥⌘M"),
        ]
        default: return [
            ("mic.fill", "Voice Input", "Press and speak. Text appears at cursor", "⌥⌘V"),
            ("arrow.right.doc.on.clipboard", "Send from iPhone", "Speak on iPhone, text goes to Mac clipboard", "Auto-connect on same WiFi"),
            ("doc.text.fill", "Meeting Notes", "Auto-transcribe meetings with speaker labels", "⌥⌘M"),
        ]
        }
    }

    static var tutorialTip: String {
        switch lang {
        case "ja": return "メニューバーの 声 アイコンから設定を変更できます"
        case "zh": return "从菜单栏的 声 图标更改设置"
        case "ko": return "메뉴바의 声 아이콘에서 설정 변경 가능"
        default:   return "Change settings from the 声 icon in the menu bar"
        }
    }

    static var tryNow: String {
        switch lang {
        case "ja": return "始める"
        case "zh": return "开始"
        case "ko": return "시작"
        default:   return "Get Started"
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

    // MARK: - Settings Window

    static var settingsTitle: String {
        switch lang {
        case "ja": return "Koe 設定"
        case "zh": return "Koe 设置"
        case "ko": return "Koe 설정"
        default:   return "Koe Settings"
        }
    }

    // MARK: - Settings Tab Labels

    static var tabGeneral: String {
        switch lang {
        case "ja": return "一般"
        case "zh": return "通用"
        case "ko": return "일반"
        default:   return "General"
        }
    }

    static var tabVoice: String {
        switch lang {
        case "ja": return "音声"
        case "zh": return "语音"
        case "ko": return "음성"
        default:   return "Voice"
        }
    }

    static var tabAI: String {
        switch lang {
        case "ja": return "AI"
        case "zh": return "AI"
        case "ko": return "AI"
        default:   return "AI"
        }
    }

    static var tabAutomation: String {
        switch lang {
        case "ja": return "自動化"
        case "zh": return "自动化"
        case "ko": return "자동화"
        default:   return "Automation"
        }
    }

    static var tabStats: String {
        switch lang {
        case "ja": return "統計"
        case "zh": return "统计"
        case "ko": return "통계"
        default:   return "Statistics"
        }
    }

    static var tabHistory: String {
        switch lang {
        case "ja": return "履歴"
        case "zh": return "历史"
        case "ko": return "기록"
        default:   return "History"
        }
    }

    // MARK: - Settings > General Tab

    static var sectionBasic: String {
        switch lang {
        case "ja": return "基本"
        case "zh": return "基本"
        case "ko": return "기본"
        default:   return "Basic"
        }
    }

    static var labelLanguage: String {
        switch lang {
        case "ja": return "言語"
        case "zh": return "语言"
        case "ko": return "언어"
        default:   return "Language"
        }
    }

    static var labelShortcut: String {
        switch lang {
        case "ja": return "ショートカット"
        case "zh": return "快捷键"
        case "ko": return "단축키"
        default:   return "Shortcut"
        }
    }

    static var labelCustom: String {
        switch lang {
        case "ja": return "カスタム"
        case "zh": return "自定义"
        case "ko": return "사용자 지정"
        default:   return "Custom"
        }
    }

    static var labelPressKey: String {
        switch lang {
        case "ja": return "キーを押して…"
        case "zh": return "请按键..."
        case "ko": return "키를 누르세요..."
        default:   return "Press a key..."
        }
    }

    static var labelRecordingMode: String {
        switch lang {
        case "ja": return "録音モード"
        case "zh": return "录音模式"
        case "ko": return "녹음 모드"
        default:   return "Recording Mode"
        }
    }

    static var sectionBehavior: String {
        switch lang {
        case "ja": return "動作"
        case "zh": return "行为"
        case "ko": return "동작"
        default:   return "Behavior"
        }
    }

    static var toggleLaunchAtLogin: String {
        switch lang {
        case "ja": return "ログイン時に自動起動"
        case "zh": return "登录时自动启动"
        case "ko": return "로그인 시 자동 시작"
        default:   return "Launch at login"
        }
    }

    static var toggleCopyToClipboard: String {
        switch lang {
        case "ja": return "クリップボードにコピー"
        case "zh": return "复制到剪贴板"
        case "ko": return "클립보드에 복사"
        default:   return "Copy to clipboard"
        }
    }

    static var toggleNotifyOnComplete: String {
        switch lang {
        case "ja": return "完了時に通知"
        case "zh": return "完成时通知"
        case "ko": return "완료 시 알림"
        default:   return "Notify on completion"
        }
    }

    static var toggleFloatingButton: String {
        switch lang {
        case "ja": return "フローティングボタン"
        case "zh": return "悬浮按钮"
        case "ko": return "플로팅 버튼"
        default:   return "Floating button"
        }
    }

    static var labelInputMode: String {
        switch lang {
        case "ja": return "入力モード"
        case "zh": return "输入模式"
        case "ko": return "입력 모드"
        default:   return "Input Mode"
        }
    }

    static var inputModeVoice: String {
        switch lang {
        case "ja": return "声入力"
        case "zh": return "语音输入"
        case "ko": return "음성 입력"
        default:   return "Voice Input"
        }
    }

    static var inputModeDirect: String {
        switch lang {
        case "ja": return "直接入力"
        case "zh": return "直接输入"
        case "ko": return "직접 입력"
        default:   return "Direct Input"
        }
    }

    static var toggleCmdIMESwitch: String {
        switch lang {
        case "ja": return "左⌘→英語 / 右⌘→日本語"
        case "zh": return "左⌘→英语 / 右⌘→中文"
        case "ko": return "왼쪽⌘→영어 / 오른쪽⌘→한국어"
        default:   return "Left ⌘→English / Right ⌘→Japanese"
        }
    }

    static var toggleShowNoiseLevel: String {
        switch lang {
        case "ja": return "環境ノイズレベル表示"
        case "zh": return "显示环境噪音等级"
        case "ko": return "환경 소음 레벨 표시"
        default:   return "Show ambient noise level"
        }
    }

    static var sectionOther: String {
        switch lang {
        case "ja": return "その他"
        case "zh": return "其他"
        case "ko": return "기타"
        default:   return "Other"
        }
    }

    static var labelMenuBarLanguages: String {
        switch lang {
        case "ja": return "メニューバーの言語"
        case "zh": return "菜单栏语言"
        case "ko": return "메뉴바 언어"
        default:   return "Menu bar languages"
        }
    }

    static var labelMenuBarLanguagesDesc: String {
        switch lang {
        case "ja": return "チェックした言語がメニューバーに表示されます"
        case "zh": return "勾选的语言将显示在菜单栏中"
        case "ko": return "체크한 언어가 메뉴바에 표시됩니다"
        default:   return "Checked languages appear in the menu bar"
        }
    }

    static var labelPermissions: String {
        switch lang {
        case "ja": return "権限"
        case "zh": return "权限"
        case "ko": return "권한"
        default:   return "Permissions"
        }
    }

    static var labelMicrophone: String {
        switch lang {
        case "ja": return "マイク"
        case "zh": return "麦克风"
        case "ko": return "마이크"
        default:   return "Microphone"
        }
    }

    static var labelAccessibility: String {
        switch lang {
        case "ja": return "アクセシビリティ"
        case "zh": return "辅助功能"
        case "ko": return "접근성"
        default:   return "Accessibility"
        }
    }

    static var labelNotAuthorized: String {
        switch lang {
        case "ja": return "未許可"
        case "zh": return "未授权"
        case "ko": return "미승인"
        default:   return "Not Authorized"
        }
    }

    static var labelOpen: String {
        switch lang {
        case "ja": return "開く"
        case "zh": return "打开"
        case "ko": return "열기"
        default:   return "Open"
        }
    }

    static var labelVersion: String {
        switch lang {
        case "ja": return "バージョン"
        case "zh": return "版本"
        case "ko": return "버전"
        default:   return "Version"
        }
    }

    // MARK: - Settings > Voice Tab

    static var sectionEngine: String {
        switch lang {
        case "ja": return "エンジン"
        case "zh": return "引擎"
        case "ko": return "엔진"
        default:   return "Engine"
        }
    }

    static var labelRecognitionEngine: String {
        switch lang {
        case "ja": return "認識エンジン"
        case "zh": return "识别引擎"
        case "ko": return "인식 엔진"
        default:   return "Recognition Engine"
        }
    }

    static var labelOpenAIAPIKey: String {
        switch lang {
        case "ja": return "OpenAI APIキー"
        case "zh": return "OpenAI API密钥"
        case "ko": return "OpenAI API 키"
        default:   return "OpenAI API Key"
        }
    }

    static var sectionRecognitionTuning: String {
        switch lang {
        case "ja": return "認識チューニング"
        case "zh": return "识别调优"
        case "ko": return "인식 튜닝"
        default:   return "Recognition Tuning"
        }
    }

    static var toggleBeamSearch: String {
        switch lang {
        case "ja": return "高精度モード (Beam Search)"
        case "zh": return "高精度模式 (Beam Search)"
        case "ko": return "고정밀 모드 (Beam Search)"
        default:   return "High Accuracy Mode (Beam Search)"
        }
    }

    static var beamSearchDesc: String {
        switch lang {
        case "ja": return "精度が上がりますが少し遅くなります"
        case "zh": return "精度更高但速度稍慢"
        case "ko": return "정확도가 올라가지만 약간 느려집니다"
        default:   return "More accurate but slightly slower"
        }
    }

    static var toggleUseContext: String {
        switch lang {
        case "ja": return "文脈を引き継ぐ"
        case "zh": return "继承上下文"
        case "ko": return "문맥 이어가기"
        default:   return "Carry over context"
        }
    }

    static var useContextDesc: String {
        switch lang {
        case "ja": return "長い文章で固有名詞や文体が安定します"
        case "zh": return "长文中专有名词和文体更稳定"
        case "ko": return "긴 문장에서 고유명사와 문체가 안정됩니다"
        default:   return "Stabilizes proper nouns and style in long texts"
        }
    }

    static var labelSilenceWait: String {
        switch lang {
        case "ja": return "話し終わりの待ち時間"
        case "zh": return "停顿等待时间"
        case "ko": return "말 끝 대기 시간"
        default:   return "Silence wait time"
        }
    }

    static var silenceFast: String {
        switch lang {
        case "ja": return "速い (1.0s)"
        case "zh": return "快速 (1.0s)"
        case "ko": return "빠름 (1.0s)"
        default:   return "Fast (1.0s)"
        }
    }

    static var silenceNormal: String {
        switch lang {
        case "ja": return "普通 (1.5s)"
        case "zh": return "普通 (1.5s)"
        case "ko": return "보통 (1.5s)"
        default:   return "Normal (1.5s)"
        }
    }

    static var silenceSlow: String {
        switch lang {
        case "ja": return "ゆっくり (2.0s)"
        case "zh": return "慢速 (2.0s)"
        case "ko": return "느림 (2.0s)"
        default:   return "Slow (2.0s)"
        }
    }

    static var silenceLong: String {
        switch lang {
        case "ja": return "長め (3.0s)"
        case "zh": return "较长 (3.0s)"
        case "ko": return "길게 (3.0s)"
        default:   return "Long (3.0s)"
        }
    }

    static var silenceLongest: String {
        switch lang {
        case "ja": return "最長 (5.0s)"
        case "zh": return "最长 (5.0s)"
        case "ko": return "최장 (5.0s)"
        default:   return "Longest (5.0s)"
        }
    }

    static var labelRecognitionVariance: String {
        switch lang {
        case "ja": return "認識のゆらぎ"
        case "zh": return "识别灵活度"
        case "ko": return "인식 변동"
        default:   return "Recognition variance"
        }
    }

    static var varianceSure: String {
        switch lang {
        case "ja": return "確実 (0)"
        case "zh": return "确定 (0)"
        case "ko": return "확실 (0)"
        default:   return "Certain (0)"
        }
    }

    static var varianceFlexible: String {
        switch lang {
        case "ja": return "少し柔軟 (0.2)"
        case "zh": return "稍灵活 (0.2)"
        case "ko": return "약간 유연 (0.2)"
        default:   return "Slightly flexible (0.2)"
        }
    }

    static var varianceVeryFlexible: String {
        switch lang {
        case "ja": return "柔軟 (0.4)"
        case "zh": return "灵活 (0.4)"
        case "ko": return "유연 (0.4)"
        default:   return "Flexible (0.4)"
        }
    }

    static var labelAmbiguity: String {
        switch lang {
        case "ja": return "あいまい判定"
        case "zh": return "模糊判定"
        case "ko": return "모호한 판정"
        default:   return "Ambiguity threshold"
        }
    }

    static var ambiguityStrict: String {
        switch lang {
        case "ja": return "厳しい (2.0)"
        case "zh": return "严格 (2.0)"
        case "ko": return "엄격 (2.0)"
        default:   return "Strict (2.0)"
        }
    }

    static var ambiguityNormal: String {
        switch lang {
        case "ja": return "普通 (2.4)"
        case "zh": return "普通 (2.4)"
        case "ko": return "보통 (2.4)"
        default:   return "Normal (2.4)"
        }
    }

    static var ambiguityLoose: String {
        switch lang {
        case "ja": return "緩い (3.0)"
        case "zh": return "宽松 (3.0)"
        case "ko": return "느슨 (3.0)"
        default:   return "Loose (3.0)"
        }
    }

    static var sectionTextProcessing: String {
        switch lang {
        case "ja": return "テキスト処理"
        case "zh": return "文本处理"
        case "ko": return "텍스트 처리"
        default:   return "Text Processing"
        }
    }

    static var toggleFillerRemoval: String {
        switch lang {
        case "ja": return "フィラー自動除去"
        case "zh": return "自动去除填充词"
        case "ko": return "필러 자동 제거"
        default:   return "Auto-remove fillers"
        }
    }

    static var fillerRemovalDesc: String {
        switch lang {
        case "ja": return "「えー」「あの」「えっと」等の言い淀みを自動的に除去します"
        case "zh": return "自动去除嗯那个等口头禅"
        case "ko": return "'음', '그' 등의 말더듬을 자동으로 제거합니다"
        default:   return "Automatically removes filler words like 'um', 'uh', 'well'"
        }
    }

    static var labelPunctuationStyle: String {
        switch lang {
        case "ja": return "句読点スタイル"
        case "zh": return "标点样式"
        case "ko": return "구두점 스타일"
        default:   return "Punctuation style"
        }
    }

    static var toggleCommandMode: String {
        switch lang {
        case "ja": return "Command Mode"
        case "zh": return "Command Mode"
        case "ko": return "Command Mode"
        default:   return "Command Mode"
        }
    }

    static var commandModeDesc: String {
        switch lang {
        case "ja": return "「丁寧にして」「箇条書きにして」等で選択テキストをAIで書き換え"
        case "zh": return "用语音指令让AI改写选中文本，如改正式列成清单"
        case "ko": return "'정중하게', '목록으로' 등으로 선택 텍스트를 AI로 재작성"
        default:   return "Rewrite selected text with AI using voice commands like 'make polite'"
        }
    }

    static var sectionContext: String {
        switch lang {
        case "ja": return "コンテキスト"
        case "zh": return "上下文"
        case "ko": return "컨텍스트"
        default:   return "Context"
        }
    }

    static var toggleContextAware: String {
        switch lang {
        case "ja": return "コンテキスト認識"
        case "zh": return "上下文感知"
        case "ko": return "컨텍스트 인식"
        default:   return "Context awareness"
        }
    }

    static var toggleAppHint: String {
        switch lang {
        case "ja": return "アプリ別ヒント"
        case "zh": return "按应用提示"
        case "ko": return "앱별 힌트"
        default:   return "Per-app hints"
        }
    }

    static var toggleClipboardContext: String {
        switch lang {
        case "ja": return "クリップボード活用"
        case "zh": return "利用剪贴板"
        case "ko": return "클립보드 활용"
        default:   return "Use clipboard"
        }
    }

    static var labelCustomPrompt: String {
        switch lang {
        case "ja": return "カスタムプロンプト"
        case "zh": return "自定义提示词"
        case "ko": return "사용자 지정 프롬프트"
        default:   return "Custom prompt"
        }
    }

    static var sectionLearningDictionary: String {
        switch lang {
        case "ja": return "学習辞書"
        case "zh": return "学习词典"
        case "ko": return "학습 사전"
        default:   return "Learning Dictionary"
        }
    }

    // MARK: - Settings > AI Tab

    static var sectionLLMPostProcessing: String {
        switch lang {
        case "ja": return "LLM後処理"
        case "zh": return "LLM后处理"
        case "ko": return "LLM 후처리"
        default:   return "LLM Post-processing"
        }
    }

    static var toggleLLMEnabled: String {
        switch lang {
        case "ja": return "LLM後処理を有効にする"
        case "zh": return "启用LLM后处理"
        case "ko": return "LLM 후처리 활성화"
        default:   return "Enable LLM post-processing"
        }
    }

    static var llmEnabledDesc: String {
        switch lang {
        case "ja": return "音声認識後にLLMで誤字修正・句読点追加を行います"
        case "zh": return "语音识别后使用LLM修正错字、添加标点"
        case "ko": return "음성 인식 후 LLM으로 오타 수정 및 구두점 추가"
        default:   return "Uses LLM to fix typos and add punctuation after recognition"
        }
    }

    static var labelProcessingMode: String {
        switch lang {
        case "ja": return "処理モード"
        case "zh": return "处理模式"
        case "ko": return "처리 모드"
        default:   return "Processing mode"
        }
    }

    static var labelProcessingEngine: String {
        switch lang {
        case "ja": return "処理エンジン"
        case "zh": return "处理引擎"
        case "ko": return "처리 엔진"
        default:   return "Processing engine"
        }
    }

    static var engineLocal: String {
        switch lang {
        case "ja": return "ローカル (llama.cpp + Metal GPU)"
        case "zh": return "本地 (llama.cpp + Metal GPU)"
        case "ko": return "로컬 (llama.cpp + Metal GPU)"
        default:   return "Local (llama.cpp + Metal GPU)"
        }
    }

    static var engineCloud: String {
        switch lang {
        case "ja": return "クラウド (API)"
        case "zh": return "云端 (API)"
        case "ko": return "클라우드 (API)"
        default:   return "Cloud (API)"
        }
    }

    static var labelProvider: String {
        switch lang {
        case "ja": return "プロバイダ"
        case "zh": return "提供商"
        case "ko": return "프로바이더"
        default:   return "Provider"
        }
    }

    static var labelAPIKey: String {
        switch lang {
        case "ja": return "APIキー"
        case "zh": return "API密钥"
        case "ko": return "API 키"
        default:   return "API Key"
        }
    }

    static var labelModel: String {
        switch lang {
        case "ja": return "モデル"
        case "zh": return "模型"
        case "ko": return "모델"
        default:   return "Model"
        }
    }

    static var labelBaseURL: String {
        switch lang {
        case "ja": return "ベースURL"
        case "zh": return "基础URL"
        case "ko": return "베이스 URL"
        default:   return "Base URL"
        }
    }

    static var llmCustomPromptEmpty: String {
        switch lang {
        case "ja": return "空欄の場合はデフォルト（誤字修正・句読点追加）が使用されます"
        case "zh": return "留空则使用默认设置（修正错字、添加标点）"
        case "ko": return "비워두면 기본값(오타 수정 및 구두점 추가)이 사용됩니다"
        default:   return "If empty, default (typo fix & punctuation) will be used"
        }
    }

    static var labelClear: String {
        switch lang {
        case "ja": return "クリア"
        case "zh": return "清除"
        case "ko": return "지우기"
        default:   return "Clear"
        }
    }

    static var toggleSuperMode: String {
        switch lang {
        case "ja": return "Super Mode（画面コンテキスト認識）"
        case "zh": return "Super Mode（屏幕上下文识别）"
        case "ko": return "Super Mode (화면 컨텍스트 인식)"
        default:   return "Super Mode (screen context awareness)"
        }
    }

    static var superModeEnabledDesc: String {
        switch lang {
        case "ja": return "アクティブなアプリ名や選択中のテキストをLLMに渡し、文脈に合った出力を生成します。"
        case "zh": return "将活动应用名称和选中文本传递给LLM，生成符合上下文的输出。"
        case "ko": return "활성 앱 이름과 선택된 텍스트를 LLM에 전달하여 문맥에 맞는 출력을 생성합니다."
        default:   return "Sends active app name and selected text to LLM for context-aware output."
        }
    }

    static var superModeDisabledDesc: String {
        switch lang {
        case "ja": return "使用中のアプリや選択テキストに応じてLLMが最適なフォーマットで出力します"
        case "zh": return "LLM根据当前应用和选中文本以最佳格式输出"
        case "ko": return "사용 중인 앱과 선택 텍스트에 따라 LLM이 최적의 형식으로 출력합니다"
        default:   return "LLM outputs in the optimal format based on active app and selected text"
        }
    }

    static var accessibilityNotAuthorizedWarning: String {
        switch lang {
        case "ja": return "アクセシビリティ権限が未許可です"
        case "zh": return "辅助功能权限未授权"
        case "ko": return "접근성 권한이 미승인입니다"
        default:   return "Accessibility permission not authorized"
        }
    }

    // MARK: - Settings > Automation Tab

    static var sectionWakeWord: String {
        switch lang {
        case "ja": return "ウェイクワード"
        case "zh": return "唤醒词"
        case "ko": return "웨이크 워드"
        default:   return "Wake Word"
        }
    }

    static var toggleWakeWord: String {
        switch lang {
        case "ja": return "ウェイクワードで録音開始"
        case "zh": return "用唤醒词开始录音"
        case "ko": return "웨이크 워드로 녹음 시작"
        default:   return "Start recording with wake word"
        }
    }

    static var sectionAgent: String {
        switch lang {
        case "ja": return "エージェント"
        case "zh": return "代理"
        case "ko": return "에이전트"
        default:   return "Agent"
        }
    }

    static var toggleAgentMode: String {
        switch lang {
        case "ja": return "エージェントモード"
        case "zh": return "代理模式"
        case "ko": return "에이전트 모드"
        default:   return "Agent Mode"
        }
    }

    static var agentModeDesc: String {
        switch lang {
        case "ja": return "「Safariを開いて」「5分タイマー」などの音声コマンドを実行"
        case "zh": return "执行语音命令，如打开Safari、5分钟计时器"
        case "ko": return "'Safari 열어줘', '5분 타이머' 등 음성 명령 실행"
        default:   return "Execute voice commands like 'open Safari' or '5-minute timer'"
        }
    }

    static var labelSupportedCommands: String {
        switch lang {
        case "ja": return "対応コマンド"
        case "zh": return "支持的命令"
        case "ko": return "지원 명령"
        default:   return "Supported Commands"
        }
    }

    static var sectionAppIntegration: String {
        switch lang {
        case "ja": return "アプリ連携"
        case "zh": return "应用集成"
        case "ko": return "앱 연동"
        default:   return "App Integration"
        }
    }

    static func appProfilesCount(_ n: Int) -> String {
        switch lang {
        case "ja": return "アプリ別プロファイル (\(n)件)"
        case "zh": return "应用配置文件 (\(n)个)"
        case "ko": return "앱별 프로필 (\(n)건)"
        default:   return "App Profiles (\(n))"
        }
    }

    static var sectionIPhoneIntegration: String {
        switch lang {
        case "ja": return "iPhone連携"
        case "zh": return "iPhone集成"
        case "ko": return "iPhone 연동"
        default:   return "iPhone Integration"
        }
    }

    static var toggleIPhoneLLM: String {
        switch lang {
        case "ja": return "LLM処理を適用"
        case "zh": return "应用LLM处理"
        case "ko": return "LLM 처리 적용"
        default:   return "Apply LLM processing"
        }
    }

    static var labelMode: String {
        switch lang {
        case "ja": return "モード"
        case "zh": return "模式"
        case "ko": return "모드"
        default:   return "Mode"
        }
    }

    static var toggleAutoEnter: String {
        switch lang {
        case "ja": return "入力後に自動Enter"
        case "zh": return "输入后自动回车"
        case "ko": return "입력 후 자동 Enter"
        default:   return "Auto-enter after input"
        }
    }

    static var sectionTextExpansion: String {
        switch lang {
        case "ja": return "テキスト展開"
        case "zh": return "文本扩展"
        case "ko": return "텍스트 확장"
        default:   return "Text Expansion"
        }
    }

    static func textExpansionCount(_ n: Int) -> String {
        switch lang {
        case "ja": return "テキスト展開 (\(n)件)"
        case "zh": return "文本扩展 (\(n)个)"
        case "ko": return "텍스트 확장 (\(n)건)"
        default:   return "Text Expansion (\(n))"
        }
    }

    // MARK: - Settings > Stats Tab

    static var labelTodayChars: String {
        switch lang {
        case "ja": return "今日の文字数"
        case "zh": return "今日字数"
        case "ko": return "오늘 글자 수"
        default:   return "Today's characters"
        }
    }

    static var labelTimeSaved: String {
        switch lang {
        case "ja": return "節約時間"
        case "zh": return "节省时间"
        case "ko": return "절약 시간"
        default:   return "Time saved"
        }
    }

    static var labelSession: String {
        switch lang {
        case "ja": return "セッション"
        case "zh": return "会话"
        case "ko": return "세션"
        default:   return "Sessions"
        }
    }

    static var labelStreak: String {
        switch lang {
        case "ja": return "連続使用"
        case "zh": return "连续使用"
        case "ko": return "연속 사용"
        default:   return "Streak"
        }
    }

    static var labelWeeklyTrend: String {
        switch lang {
        case "ja": return "週間推移"
        case "zh": return "每周趋势"
        case "ko": return "주간 추이"
        default:   return "Weekly Trend"
        }
    }

    static var labelTotalChars: String {
        switch lang {
        case "ja": return "累計文字数"
        case "zh": return "累计字数"
        case "ko": return "누적 글자 수"
        default:   return "Total characters"
        }
    }

    static var labelTotalSessions: String {
        switch lang {
        case "ja": return "累計セッション"
        case "zh": return "累计会话"
        case "ko": return "누적 세션"
        default:   return "Total sessions"
        }
    }

    static var labelTotalTimeSaved: String {
        switch lang {
        case "ja": return "累計節約時間"
        case "zh": return "累计节省时间"
        case "ko": return "누적 절약 시간"
        default:   return "Total time saved"
        }
    }

    static var labelLearnedCorrections: String {
        switch lang {
        case "ja": return "学習済み修正"
        case "zh": return "已学习修正"
        case "ko": return "학습된 수정"
        default:   return "Learned corrections"
        }
    }

    static var labelTotal: String {
        switch lang {
        case "ja": return "累計"
        case "zh": return "累计"
        case "ko": return "누적"
        default:   return "Total"
        }
    }

    static var labelTypingComparison: String {
        switch lang {
        case "ja": return "タイピング比較"
        case "zh": return "打字比较"
        case "ko": return "타이핑 비교"
        default:   return "Typing Comparison"
        }
    }

    static var labelVoice: String {
        switch lang {
        case "ja": return "音声"
        case "zh": return "语音"
        case "ko": return "음성"
        default:   return "Voice"
        }
    }

    static var labelTyping: String {
        switch lang {
        case "ja": return "タイピング"
        case "zh": return "打字"
        case "ko": return "타이핑"
        default:   return "Typing"
        }
    }

    static var labelCharsPerMin: String {
        switch lang {
        case "ja": return "文字/分"
        case "zh": return "字/分"
        case "ko": return "글자/분"
        default:   return "chars/min"
        }
    }

    static var voiceVsTypingDesc: String {
        switch lang {
        case "ja": return "音声入力はタイピングの約1.9倍の速度"
        case "zh": return "语音输入比打字快约1.9倍"
        case "ko": return "음성 입력은 타이핑의 약 1.9배 속도"
        default:   return "Voice input is ~1.9x faster than typing"
        }
    }

    // MARK: - Settings > History Tab

    static var labelSearch: String {
        switch lang {
        case "ja": return "検索"
        case "zh": return "搜索"
        case "ko": return "검색"
        default:   return "Search"
        }
    }

    static var labelNoHistory: String {
        switch lang {
        case "ja": return "履歴はありません"
        case "zh": return "没有历史记录"
        case "ko": return "기록이 없습니다"
        default:   return "No history"
        }
    }

    static var labelNoMatch: String {
        switch lang {
        case "ja": return "一致する項目がありません"
        case "zh": return "没有匹配项"
        case "ko": return "일치하는 항목이 없습니다"
        default:   return "No matching items"
        }
    }

    static var helpShowAll: String {
        switch lang {
        case "ja": return "すべて表示"
        case "zh": return "显示全部"
        case "ko": return "모두 표시"
        default:   return "Show all"
        }
    }

    static var helpFavoritesOnly: String {
        switch lang {
        case "ja": return "お気に入りのみ"
        case "zh": return "仅收藏"
        case "ko": return "즐겨찾기만"
        default:   return "Favorites only"
        }
    }

    static func showingCount(total: Int, filtered: Int) -> String {
        switch lang {
        case "ja": return "\(total)件中 \(filtered)件表示"
        case "zh": return "共\(total)条，显示\(filtered)条"
        case "ko": return "\(total)건 중 \(filtered)건 표시"
        default:   return "Showing \(filtered) of \(total)"
        }
    }

    static var labelExport: String {
        switch lang {
        case "ja": return "エクスポート"
        case "zh": return "导出"
        case "ko": return "내보내기"
        default:   return "Export"
        }
    }

    static var labelClearAll: String {
        switch lang {
        case "ja": return "すべてクリア"
        case "zh": return "全部清除"
        case "ko": return "모두 지우기"
        default:   return "Clear All"
        }
    }

    static var labelCopy: String {
        switch lang {
        case "ja": return "コピー"
        case "zh": return "复制"
        case "ko": return "복사"
        default:   return "Copy"
        }
    }

    static var labelFavorite: String {
        switch lang {
        case "ja": return "お気に入り"
        case "zh": return "收藏"
        case "ko": return "즐겨찾기"
        default:   return "Favorite"
        }
    }

    static var labelUnfavorite: String {
        switch lang {
        case "ja": return "お気に入り解除"
        case "zh": return "取消收藏"
        case "ko": return "즐겨찾기 해제"
        default:   return "Unfavorite"
        }
    }

    static var labelDelete: String {
        switch lang {
        case "ja": return "削除"
        case "zh": return "删除"
        case "ko": return "삭제"
        default:   return "Delete"
        }
    }

    // MARK: - Settings > Persona

    static var labelPresets: String {
        switch lang {
        case "ja": return "プリセット"
        case "zh": return "预设"
        case "ko": return "프리셋"
        default:   return "Presets"
        }
    }

    static var labelAppliedSettings: String {
        switch lang {
        case "ja": return "適用される設定"
        case "zh": return "将应用的设置"
        case "ko": return "적용되는 설정"
        default:   return "Settings to apply"
        }
    }

    static var labelUsageTips: String {
        switch lang {
        case "ja": return "使いこなしヒント"
        case "zh": return "使用技巧"
        case "ko": return "활용 팁"
        default:   return "Usage Tips"
        }
    }

    static var buttonClose: String {
        switch lang {
        case "ja": return "閉じる"
        case "zh": return "关闭"
        case "ko": return "닫기"
        default:   return "Close"
        }
    }

    static var labelApplied: String {
        switch lang {
        case "ja": return "適用しました"
        case "zh": return "已应用"
        case "ko": return "적용됨"
        default:   return "Applied"
        }
    }

    static var buttonApplySettings: String {
        switch lang {
        case "ja": return "この設定を適用"
        case "zh": return "应用此设置"
        case "ko": return "이 설정 적용"
        default:   return "Apply Settings"
        }
    }

    static var personaLabelLanguage: String {
        switch lang {
        case "ja": return "言語"
        case "zh": return "语言"
        case "ko": return "언어"
        default:   return "Language"
        }
    }

    static var personaLabelLLM: String {
        switch lang {
        case "ja": return "LLM後処理"
        case "zh": return "LLM后处理"
        case "ko": return "LLM 후처리"
        default:   return "LLM Post-processing"
        }
    }

    static var personaLabelHighAccuracy: String {
        switch lang {
        case "ja": return "高精度モード"
        case "zh": return "高精度模式"
        case "ko": return "고정밀 모드"
        default:   return "High Accuracy"
        }
    }

    static var personaLabelAgentMode: String {
        switch lang {
        case "ja": return "エージェントモード"
        case "zh": return "代理模式"
        case "ko": return "에이전트 모드"
        default:   return "Agent Mode"
        }
    }

    static var personaLabelWaitTime: String {
        switch lang {
        case "ja": return "待ち時間"
        case "zh": return "等待时间"
        case "ko": return "대기 시간"
        default:   return "Wait Time"
        }
    }

    static var labelEnabled: String {
        switch lang {
        case "ja": return "有効"
        case "zh": return "启用"
        case "ko": return "활성"
        default:   return "Enabled"
        }
    }

    static var labelDisabled: String {
        switch lang {
        case "ja": return "無効"
        case "zh": return "禁用"
        case "ko": return "비활성"
        default:   return "Disabled"
        }
    }

    static func secondsLabel(_ s: Double) -> String {
        switch lang {
        case "ja": return "\(String(format: "%.1f", s))秒"
        case "zh": return "\(String(format: "%.1f", s))秒"
        case "ko": return "\(String(format: "%.1f", s))초"
        default:   return "\(String(format: "%.1f", s))s"
        }
    }

    // MARK: - Menu Items (AppDelegate)

    static var menuOtherLanguages: String {
        switch lang {
        case "ja": return "その他の言語…"
        case "zh": return "其他语言..."
        case "ko": return "기타 언어..."
        default:   return "Other Languages..."
        }
    }

    static func menuLLMLabel(mode: String, isOff: Bool) -> String {
        if isOff {
            switch lang {
            case "ja": return "LLM: オフ"
            case "zh": return "LLM: 关闭"
            case "ko": return "LLM: 꺼짐"
            default:   return "LLM: Off"
            }
        } else {
            return "LLM: \(mode)"
        }
    }

    static var menuTranslation: String {
        switch lang {
        case "ja": return "翻訳"
        case "zh": return "翻译"
        case "ko": return "번역"
        default:   return "Translate"
        }
    }

    static func menuMeetingStop(count: Int) -> String {
        switch lang {
        case "ja": return "議事録停止 (\(count)件)"
        case "zh": return "停止会议记录 (\(count)条)"
        case "ko": return "회의록 중지 (\(count)건)"
        default:   return "Stop Meeting Notes (\(count))"
        }
    }

    static var menuMeetingStart: String {
        switch lang {
        case "ja": return "議事録開始"
        case "zh": return "开始会议记录"
        case "ko": return "회의록 시작"
        default:   return "Start Meeting Notes"
        }
    }

    static var menuFileTranscription: String {
        switch lang {
        case "ja": return "ファイル文字起こし…"
        case "zh": return "文件转录..."
        case "ko": return "파일 전사..."
        default:   return "File Transcription..."
        }
    }

    static var menuSettings: String {
        switch lang {
        case "ja": return "設定…"
        case "zh": return "设置..."
        case "ko": return "설정..."
        default:   return "Settings..."
        }
    }

    static var menuQuit: String {
        switch lang {
        case "ja": return "終了"
        case "zh": return "退出"
        case "ko": return "종료"
        default:   return "Quit"
        }
    }

    // MARK: - AppDelegate Alerts & Dialogs

    static var accessibilityRequiredAlert: String {
        switch lang {
        case "ja": return "IME切替（⌘キー）やテキスト自動入力にはアクセシビリティ権限が必要です。\n\n「システム設定 → プライバシーとセキュリティ → アクセシビリティ」で Koe を有効にしてください。"
        case "zh": return "IME切换（⌘键）和文本自动输入需要辅助功能权限。\n\n请在系统设置 → 隐私与安全 → 辅助功能中启用 Koe。"
        case "ko": return "IME 전환(⌘키)과 텍스트 자동 입력에 접근성 권한이 필요합니다.\n\n'시스템 설정 → 개인정보 보호 → 접근성'에서 Koe를 활성화하세요."
        default:   return "Accessibility permission is required for IME switching (⌘ key) and auto text input.\n\nPlease enable Koe in System Settings → Privacy & Security → Accessibility."
        }
    }

    static var selectTextFirst: String {
        switch lang {
        case "ja": return "テキストを選択してからコマンドを使ってください"
        case "zh": return "请先选择文本再使用命令"
        case "ko": return "텍스트를 선택한 후 명령을 사용하세요"
        default:   return "Please select text before using this command"
        }
    }

    static var fileTranscriptionTitle: String {
        switch lang {
        case "ja": return "文字起こしするファイルを選択"
        case "zh": return "选择要转录的文件"
        case "ko": return "전사할 파일 선택"
        default:   return "Select file to transcribe"
        }
    }

    static var aboutTagline: String {
        switch lang {
        case "ja": return "Mac で最も速い日本語音声入力"
        case "zh": return "Mac 上最快的语音输入"
        case "ko": return "Mac에서 가장 빠른 음성 입력"
        default:   return "The fastest voice input on Mac"
        }
    }

    static var aboutLocalProcessing: String {
        switch lang {
        case "ja": return "完全ローカル処理"
        case "zh": return "完全本地处理"
        case "ko": return "완전 로컬 처리"
        default:   return "Fully local processing"
        }
    }

    // MARK: - Learning Dictionary View

    static func learningCount(_ n: Int) -> String {
        switch lang {
        case "ja": return "\(n) 件の修正から学習中"
        case "zh": return "从 \(n) 条修正中学习"
        case "ko": return "\(n)건의 수정에서 학습 중"
        default:   return "Learning from \(n) corrections"
        }
    }

    static var labelLearnedKeywords: String {
        switch lang {
        case "ja": return "学習済みキーワード:"
        case "zh": return "已学习关键词:"
        case "ko": return "학습된 키워드:"
        default:   return "Learned keywords:"
        }
    }

    static var learningEmptyDesc: String {
        switch lang {
        case "ja": return "音声入力を使うと、修正パターンを自動的に学習して精度が向上します"
        case "zh": return "使用语音输入后，将自动学习修正模式以提高精度"
        case "ko": return "음성 입력을 사용하면 수정 패턴을 자동으로 학습하여 정확도가 향상됩니다"
        default:   return "As you use voice input, correction patterns are learned automatically to improve accuracy"
        }
    }

    static func recentCorrections(_ n: Int) -> String {
        switch lang {
        case "ja": return "最近の修正 (\(n)件)"
        case "zh": return "最近修正 (\(n)条)"
        case "ko": return "최근 수정 (\(n)건)"
        default:   return "Recent corrections (\(n))"
        }
    }

    // MARK: - Whisper / LLM Model Views

    static var labelInUse: String {
        switch lang {
        case "ja": return "使用中"
        case "zh": return "使用中"
        case "ko": return "사용 중"
        default:   return "In Use"
        }
    }

    static var labelNotDownloaded: String {
        switch lang {
        case "ja": return "モデル未ダウンロード"
        case "zh": return "模型未下载"
        case "ko": return "모델 미다운로드"
        default:   return "Model not downloaded"
        }
    }

    static var buttonSelect: String {
        switch lang {
        case "ja": return "選択"
        case "zh": return "选择"
        case "ko": return "선택"
        default:   return "Select"
        }
    }

    static var buttonSelectAndLoad: String {
        switch lang {
        case "ja": return "選択・ロード"
        case "zh": return "选择并加载"
        case "ko": return "선택 및 로드"
        default:   return "Select & Load"
        }
    }

    static var labelSaveLocation: String {
        switch lang {
        case "ja": return "保存先:"
        case "zh": return "保存位置:"
        case "ko": return "저장 위치:"
        default:   return "Location:"
        }
    }

    static var buttonOpenInFinder: String {
        switch lang {
        case "ja": return "Finderで開く"
        case "zh": return "在Finder中打开"
        case "ko": return "Finder에서 열기"
        default:   return "Open in Finder"
        }
    }

    static var buttonUnload: String {
        switch lang {
        case "ja": return "アンロード（メモリ解放）"
        case "zh": return "卸载（释放内存）"
        case "ko": return "언로드 (메모리 해제)"
        default:   return "Unload (free memory)"
        }
    }

    static var toggleMemorySaveMode: String {
        switch lang {
        case "ja": return "メモリ省略モード（LLMを毎回ロード/解放。遅くなるがメモリ節約）"
        case "zh": return "内存节省模式（每次加载/释放LLM，较慢但节省内存）"
        case "ko": return "메모리 절약 모드 (LLM을 매번 로드/해제, 느리지만 메모리 절약)"
        default:   return "Memory save mode (load/unload LLM each time; slower but saves memory)"
        }
    }

    // MARK: - App Profiles

    static var labelNoAppProfiles: String {
        switch lang {
        case "ja": return "アプリ別プロファイルなし"
        case "zh": return "无应用配置文件"
        case "ko": return "앱별 프로필 없음"
        default:   return "No app profiles"
        }
    }

    static var labelAppProfilesDesc: String {
        switch lang {
        case "ja": return "アプリごとにプロンプトや言語を切り替えられます"
        case "zh": return "可以为每个应用切换提示词和语言"
        case "ko": return "앱별로 프롬프트와 언어를 전환할 수 있습니다"
        default:   return "Customize prompts and language per app"
        }
    }

    static var labelNoPrompt: String {
        switch lang {
        case "ja": return "プロンプトなし"
        case "zh": return "无提示词"
        case "ko": return "프롬프트 없음"
        default:   return "No prompt"
        }
    }

    static var buttonAdd: String {
        switch lang {
        case "ja": return "+ 追加"
        case "zh": return "+ 添加"
        case "ko": return "+ 추가"
        default:   return "+ Add"
        }
    }

    static var labelAddProfile: String {
        switch lang {
        case "ja": return "プロファイルを追加"
        case "zh": return "添加配置文件"
        case "ko": return "프로필 추가"
        default:   return "Add Profile"
        }
    }

    static var labelEditProfile: String {
        switch lang {
        case "ja": return "プロファイルを編集"
        case "zh": return "编辑配置文件"
        case "ko": return "프로필 편집"
        default:   return "Edit Profile"
        }
    }

    static var labelTargetApp: String {
        switch lang {
        case "ja": return "対象アプリ"
        case "zh": return "目标应用"
        case "ko": return "대상 앱"
        default:   return "Target App"
        }
    }

    static var labelRunningApps: String {
        switch lang {
        case "ja": return "実行中のアプリ"
        case "zh": return "运行中的应用"
        case "ko": return "실행 중인 앱"
        default:   return "Running apps"
        }
    }

    static var labelSelectApp: String {
        switch lang {
        case "ja": return "選択してください"
        case "zh": return "请选择"
        case "ko": return "선택하세요"
        default:   return "Select..."
        }
    }

    static var labelBundleIDInput: String {
        switch lang {
        case "ja": return "Bundle ID を直接入力"
        case "zh": return "直接输入 Bundle ID"
        case "ko": return "Bundle ID 직접 입력"
        default:   return "Enter Bundle ID directly"
        }
    }

    static var labelLanguageOverride: String {
        switch lang {
        case "ja": return "言語（空欄 = グローバル設定を使用）"
        case "zh": return "语言（空白 = 使用全局设置）"
        case "ko": return "언어 (빈칸 = 전역 설정 사용)"
        default:   return "Language (empty = use global setting)"
        }
    }

    static var labelGlobalSetting: String {
        switch lang {
        case "ja": return "グローバル設定"
        case "zh": return "全局设置"
        case "ko": return "전역 설정"
        default:   return "Global Setting"
        }
    }

    static var labelPromptWhisperHint: String {
        switch lang {
        case "ja": return "プロンプト（Whisper / コンテキストヒント）"
        case "zh": return "提示词（Whisper / 上下文提示）"
        case "ko": return "프롬프트 (Whisper / 컨텍스트 힌트)"
        default:   return "Prompt (Whisper / context hint)"
        }
    }

    static var labelLLMInstruction: String {
        switch lang {
        case "ja": return "LLM後処理指示（空欄 = デフォルトの後処理を使用）"
        case "zh": return "LLM后处理指令（空白 = 使用默认后处理）"
        case "ko": return "LLM 후처리 지시 (빈칸 = 기본 후처리 사용)"
        default:   return "LLM post-processing instruction (empty = use default)"
        }
    }

    static var labelLLMInstructionEmpty: String {
        switch lang {
        case "ja": return "空欄の場合: AI設定タブのデフォルトプロンプト（誤字修正・句読点追加）が適用されます"
        case "zh": return "留空时：将应用AI设置标签的默认提示词（修正错字、添加标点）"
        case "ko": return "비어있는 경우: AI 설정 탭의 기본 프롬프트(오타 수정 및 구두점 추가)가 적용됩니다"
        default:   return "If empty: default prompt from AI settings tab (typo fix & punctuation) will be applied"
        }
    }

    static var buttonCancel: String {
        switch lang {
        case "ja": return "キャンセル"
        case "zh": return "取消"
        case "ko": return "취소"
        default:   return "Cancel"
        }
    }

    static var buttonSave: String {
        switch lang {
        case "ja": return "保存"
        case "zh": return "保存"
        case "ko": return "저장"
        default:   return "Save"
        }
    }

    // MARK: - Text Expansion

    static var labelNoTextExpansions: String {
        switch lang {
        case "ja": return "音声ショートカットなし"
        case "zh": return "无语音快捷方式"
        case "ko": return "음성 단축어 없음"
        default:   return "No voice shortcuts"
        }
    }

    static var labelTextExpansionDesc: String {
        switch lang {
        case "ja": return "「メアド」と言うと展開されるような辞書を作れます"
        case "zh": return "可以创建如说邮箱即展开的词典"
        case "ko": return "'이메일'이라고 말하면 확장되는 사전을 만들 수 있습니다"
        default:   return "Create a dictionary so saying 'email' expands to your address"
        }
    }

    static var labelNoTextExpansionRules: String {
        switch lang {
        case "ja": return "テキスト展開ルールはまだありません"
        case "zh": return "尚无文本扩展规则"
        case "ko": return "텍스트 확장 규칙이 아직 없습니다"
        default:   return "No text expansion rules yet"
        }
    }

    static var labelTrigger: String {
        switch lang {
        case "ja": return "トリガー"
        case "zh": return "触发词"
        case "ko": return "트리거"
        default:   return "Trigger"
        }
    }

    static var labelExpansionText: String {
        switch lang {
        case "ja": return "展開後テキスト"
        case "zh": return "展开后文本"
        case "ko": return "확장 텍스트"
        default:   return "Expanded text"
        }
    }

    static var labelEditAppProfiles: String {
        switch lang {
        case "ja": return "アプリプロファイルを編集…"
        case "zh": return "编辑应用配置文件..."
        case "ko": return "앱 프로필 편집..."
        default:   return "Edit app profiles..."
        }
    }

    // MARK: - Wake Word View

    static func wakeWordTemplatesReady(_ n: Int) -> String {
        switch lang {
        case "ja": return "\(n) テンプレート録音済み — 使用可能"
        case "zh": return "\(n) 个模板已录制 — 可使用"
        case "ko": return "\(n)개 템플릿 녹음 완료 — 사용 가능"
        default:   return "\(n) templates recorded — ready to use"
        }
    }

    static func wakeWordTemplatesProgress(_ done: Int, _ required: Int) -> String {
        switch lang {
        case "ja": return "\(done) / \(required) 録音済み — あと\(required - done)回必要"
        case "zh": return "\(done) / \(required) 已录制 — 还需\(required - done)次"
        case "ko": return "\(done) / \(required) 녹음 완료 — \(required - done)회 더 필요"
        default:   return "\(done) / \(required) recorded — \(required - done) more needed"
        }
    }

    static func wakeWordTemplatesEmpty(_ required: Int) -> String {
        switch lang {
        case "ja": return "テンプレート未登録 — 最低\(required)回録音が必要です"
        case "zh": return "未注册模板 — 至少需要录制\(required)次"
        case "ko": return "템플릿 미등록 — 최소 \(required)회 녹음 필요"
        default:   return "No templates — at least \(required) recordings needed"
        }
    }

    static func wakeWordRecordButton(_ required: Int) -> String {
        switch lang {
        case "ja": return "ウェイクワードを\(required)回録音する"
        case "zh": return "录制唤醒词\(required)次"
        case "ko": return "웨이크 워드를 \(required)회 녹음"
        default:   return "Record wake word \(required) times"
        }
    }

    static var wakeWordRecordMore: String {
        switch lang {
        case "ja": return "追加で録音する"
        case "zh": return "追加录制"
        case "ko": return "추가 녹음"
        default:   return "Record more"
        }
    }

    static func wakeWordCountdownLabel(_ round: Int, _ total: Int, _ secs: Int) -> String {
        switch lang {
        case "ja": return "\(round)/\(total) 回目: \(secs)秒後に録音開始..."
        case "zh": return "第\(round)/\(total)次: \(secs)秒后开始录音..."
        case "ko": return "\(round)/\(total)회: \(secs)초 후 녹음 시작..."
        default:   return "\(round)/\(total): Recording starts in \(secs)s..."
        }
    }

    static func wakeWordRecordingLabel(_ round: Int, _ total: Int) -> String {
        switch lang {
        case "ja": return "\(round)/\(total) 回目: 録音中..."
        case "zh": return "第\(round)/\(total)次: 录音中..."
        case "ko": return "\(round)/\(total)회: 녹음 중..."
        default:   return "\(round)/\(total): Recording..."
        }
    }

    static func wakeWordDone(_ count: Int) -> String {
        switch lang {
        case "ja": return "録音完了！ (\(count)個)"
        case "zh": return "录制完成！(\(count)个)"
        case "ko": return "녹음 완료! (\(count)개)"
        default:   return "Recording complete! (\(count))"
        }
    }

    static var wakeWordNoVoice: String {
        switch lang {
        case "ja": return "音声が検出されませんでした。もう少し大きな声で話してください。"
        case "zh": return "未检测到声音。请大声一些。"
        case "ko": return "음성이 감지되지 않았습니다. 좀 더 크게 말씀해주세요."
        default:   return "No voice detected. Please speak louder."
        }
    }

    static var labelSensitivity: String {
        switch lang {
        case "ja": return "感度"
        case "zh": return "灵敏度"
        case "ko": return "감도"
        default:   return "Sensitivity"
        }
    }

    static var sensitivityStrict: String {
        switch lang {
        case "ja": return "厳しい"
        case "zh": return "严格"
        case "ko": return "엄격"
        default:   return "Strict"
        }
    }

    static var sensitivityLoose: String {
        switch lang {
        case "ja": return "緩い"
        case "zh": return "宽松"
        case "ko": return "느슨"
        default:   return "Loose"
        }
    }

    static var sensitivityDesc: String {
        switch lang {
        case "ja": return "ウェイクワード以外で誤検出する場合は左に。反応しない場合は右に"
        case "zh": return "误检测时向左调。无反应时向右调"
        case "ko": return "오탐지 시 왼쪽으로, 반응 없을 시 오른쪽으로"
        default:   return "Move left to reduce false positives, right if not responding"
        }
    }

    static var wakeWordHelpText: String {
        switch lang {
        case "ja": return "同じウェイクワード（例:「ヘイこえ」）を繰り返し録音します。声のトーンを少し変えると精度が上がります。"
        case "zh": return "重复录制相同唤醒词。稍微改变语调可提高精度。"
        case "ko": return "같은 웨이크 워드를 반복 녹음합니다. 약간 톤을 바꾸면 정확도가 올라갑니다."
        default:   return "Record the same wake word repeatedly. Varying your tone slightly improves accuracy."
        }
    }
}
