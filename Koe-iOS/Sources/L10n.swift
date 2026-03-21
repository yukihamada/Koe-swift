import Foundation

/// Lightweight localization helper for Koe iOS.
/// Switches based on the system locale's primary language code.
enum L10n {
    /// Current 2-letter language prefix (e.g. "ja", "en", "zh", "ko")
    static var lang: String {
        let code = Locale.preferredLanguages.first ?? "en"
        return code.components(separatedBy: "-").first ?? "en"
    }

    // MARK: - ContentView

    static var connectedToMac: String {
        switch lang {
        case "ja": return "Macに接続中"
        case "zh": return "已连接到Mac"
        case "ko": return "Mac에 연결됨"
        default:   return "Connected to Mac"
        }
    }

    static var translateMode: String {
        switch lang {
        case "ja": return "翻訳モード"
        case "zh": return "翻译模式"
        case "ko": return "번역 모드"
        default:   return "Translate Mode"
        }
    }

    static var nextAction: String {
        switch lang {
        case "ja": return "次のアクション"
        case "zh": return "下一步操作"
        case "ko": return "다음 작업"
        default:   return "Next Action"
        }
    }

    static var phrases: String {
        switch lang {
        case "ja": return "定型文"
        case "zh": return "常用语"
        case "ko": return "정형문"
        default:   return "Phrases"
        }
    }

    static var trackpad: String {
        switch lang {
        case "ja": return "トラックパッド"
        case "zh": return "触控板"
        case "ko": return "트랙패드"
        default:   return "Trackpad"
        }
    }

    static var click: String {
        switch lang {
        case "ja": return "クリック"
        case "zh": return "点击"
        case "ko": return "클릭"
        default:   return "Click"
        }
    }

    static var rightClick: String {
        switch lang {
        case "ja": return "右クリック"
        case "zh": return "右键"
        case "ko": return "우클릭"
        default:   return "Right Click"
        }
    }

    static var scrollUp: String {
        switch lang {
        case "ja": return "↑スクロール"
        case "zh": return "↑滚动"
        case "ko": return "↑스크롤"
        default:   return "↑Scroll"
        }
    }

    static var scrollDown: String {
        switch lang {
        case "ja": return "↓スクロール"
        case "zh": return "↓滚动"
        case "ko": return "↓스크롤"
        default:   return "↓Scroll"
        }
    }

    static var prevTab: String {
        switch lang {
        case "ja": return "← 前のタブ"
        case "zh": return "← 上一标签"
        case "ko": return "← 이전 탭"
        default:   return "← Prev Tab"
        }
    }

    static var nextTab: String {
        switch lang {
        case "ja": return "次のタブ →"
        case "zh": return "下一标签 →"
        case "ko": return "다음 탭 →"
        default:   return "Next Tab →"
        }
    }

    static var swipeToSwitchTabs: String {
        switch lang {
        case "ja": return "← スワイプでタブ切替 →"
        case "zh": return "← 滑动切换标签 →"
        case "ko": return "← 스와이프로 탭 전환 →"
        default:   return "← Swipe to switch tabs →"
        }
    }

    static var appSwitch: String {
        switch lang {
        case "ja": return "⌘Tab アプリ切替"
        case "zh": return "⌘Tab 切换应用"
        case "ko": return "⌘Tab 앱 전환"
        default:   return "⌘Tab App Switch"
        }
    }

    static var wakeWordHint: String {
        switch lang {
        case "ja": return "「ヘイこえ」で録音開始"
        case "zh": return "说\"嘿Koe\"开始录音"
        case "ko": return "\"헤이 코에\"로 녹음 시작"
        default:   return "Say \"Hey Koe\" to start recording"
        }
    }

    static var downloadHighAccuracyModel: String {
        switch lang {
        case "ja": return "高精度モデルをダウンロード"
        case "zh": return "下载高精度模型"
        case "ko": return "고정밀 모델 다운로드"
        default:   return "Download high-accuracy model"
        }
    }

    static var cancel: String {
        switch lang {
        case "ja": return "中止"
        case "zh": return "取消"
        case "ko": return "취소"
        default:   return "Cancel"
        }
    }

    // MARK: - Mac Promo Banner

    static var macPromoTitle: String {
        switch lang {
        case "ja": return "Mac版と連携するともっと便利に"
        case "zh": return "搭配Mac版使用更方便"
        case "ko": return "Mac 버전과 연동하면 더 편리해요"
        default:   return "Even better with the Mac app"
        }
    }

    static var macPromoSubtitle: String {
        switch lang {
        case "ja": return "声でMac操作・画面AI・トラックパッド・定型文入力"
        case "zh": return "语音操控Mac·屏幕AI·触控板·常用语输入"
        case "ko": return "음성으로 Mac 조작·화면 AI·트랙패드·정형문 입력"
        default:   return "Voice Mac control, Screen AI, Trackpad, Phrase input"
        }
    }

    static var downloadMacFree: String {
        switch lang {
        case "ja": return "Mac版を無料ダウンロード →"
        case "zh": return "免费下载Mac版 →"
        case "ko": return "Mac 버전 무료 다운로드 →"
        default:   return "Download Mac app for free →"
        }
    }

    // MARK: - PIN Connection Alert

    static var connectToMac: String {
        switch lang {
        case "ja": return "Macに接続"
        case "zh": return "连接到Mac"
        case "ko": return "Mac에 연결"
        default:   return "Connect to Mac"
        }
    }

    static var enterPIN: String {
        switch lang {
        case "ja": return "PINを入力"
        case "zh": return "输入PIN码"
        case "ko": return "PIN 입력"
        default:   return "Enter PIN"
        }
    }

    static var connect: String {
        switch lang {
        case "ja": return "接続"
        case "zh": return "连接"
        case "ko": return "연결"
        default:   return "Connect"
        }
    }

    static var cancelAction: String {
        switch lang {
        case "ja": return "キャンセル"
        case "zh": return "取消"
        case "ko": return "취소"
        default:   return "Cancel"
        }
    }

    static var pinPrompt: String {
        switch lang {
        case "ja": return "Macのメニューバーに表示されているPINを入力してください"
        case "zh": return "请输入Mac菜单栏显示的PIN码"
        case "ko": return "Mac 메뉴바에 표시된 PIN을 입력해주세요"
        default:   return "Enter the PIN shown in the Mac menu bar"
        }
    }

    // MARK: - MoreView

    static var alwaysListening: String {
        switch lang {
        case "ja": return "常時リスニング"
        case "zh": return "持续监听"
        case "ko": return "항상 듣기"
        default:   return "Always Listening"
        }
    }

    static var voiceAssistant: String {
        switch lang {
        case "ja": return "音声アシスタント"
        case "zh": return "语音助手"
        case "ko": return "음성 어시스턴트"
        default:   return "Voice Assistant"
        }
    }

    static var alwaysListeningFooter: String {
        switch lang {
        case "ja": return "「ヘイこえ」と言うと自動で録音を開始します。アプリがフォアグラウンドの時のみ動作します。"
        case "zh": return "说\"嘿Koe\"自动开始录音。仅在应用处于前台时有效。"
        case "ko": return "\"헤이 코에\"라고 말하면 자동으로 녹음을 시작합니다. 앱이 포그라운드일 때만 동작합니다."
        default:   return "Say \"Hey Koe\" to automatically start recording. Only works when the app is in the foreground."
        }
    }

    static var macScreenContext: String {
        switch lang {
        case "ja": return "Mac画面コンテキスト"
        case "zh": return "Mac屏幕上下文"
        case "ko": return "Mac 화면 컨텍스트"
        default:   return "Mac Screen Context"
        }
    }

    static var macLink: String {
        switch lang {
        case "ja": return "Mac連携"
        case "zh": return "Mac联动"
        case "ko": return "Mac 연동"
        default:   return "Mac Integration"
        }
    }

    static var macScreenContextFooter: String {
        switch lang {
        case "ja": return "画面をOCRで読み取り、状況要約と次のアクション提案を表示します"
        case "zh": return "通过OCR读取屏幕，显示情况摘要和下一步操作建议"
        case "ko": return "화면을 OCR로 읽어 상황 요약과 다음 작업 제안을 표시합니다"
        default:   return "Reads the screen via OCR and shows a summary with suggested next actions"
        }
    }

    static var phrasePalette: String {
        switch lang {
        case "ja": return "定型文パレット"
        case "zh": return "常用语面板"
        case "ko": return "정형문 팔레트"
        default:   return "Phrase Palette"
        }
    }

    static var managePhrases: String {
        switch lang {
        case "ja": return "定型文を管理"
        case "zh": return "管理常用语"
        case "ko": return "정형문 관리"
        default:   return "Manage Phrases"
        }
    }

    static var managePhrasesSubtitle: String {
        switch lang {
        case "ja": return "よく使うフレーズを登録してワンタップ送信"
        case "zh": return "注册常用短语，一键发送"
        case "ko": return "자주 쓰는 문구를 등록하고 한 번에 전송"
        default:   return "Register frequently used phrases for one-tap sending"
        }
    }

    static var phraseFooter: String {
        switch lang {
        case "ja": return "Mac接続時に定型文チップを表示し、タップで即送信します"
        case "zh": return "连接Mac时显示常用语标签，点击即可发送"
        case "ko": return "Mac 연결 시 정형문 칩을 표시하고, 탭하면 바로 전송합니다"
        default:   return "Shows phrase chips when connected to Mac, tap to send instantly"
        }
    }

    static var meetingNotes: String {
        switch lang {
        case "ja": return "議事録"
        case "zh": return "会议记录"
        case "ko": return "회의록"
        default:   return "Meeting Notes"
        }
    }

    static var meetingNotesSubtitle: String {
        switch lang {
        case "ja": return "会議を自動で文字起こし・話者分離"
        case "zh": return "自动转录会议，支持说话人分离"
        case "ko": return "회의를 자동 전사·화자 분리"
        default:   return "Auto-transcribe meetings with speaker separation"
        }
    }

    static var faceToFaceTranslation: String {
        switch lang {
        case "ja": return "対面翻訳"
        case "zh": return "面对面翻译"
        case "ko": return "대면 번역"
        default:   return "Face-to-Face Translation"
        }
    }

    static var faceToFaceSubtitle: String {
        switch lang {
        case "ja": return "2人で交互に話してリアルタイム翻訳"
        case "zh": return "两人交替说话，实时翻译"
        case "ko": return "두 사람이 번갈아 말하며 실시간 번역"
        default:   return "Two people take turns speaking with real-time translation"
        }
    }

    static var audioTools: String {
        switch lang {
        case "ja": return "オーディオツール"
        case "zh": return "音频工具"
        case "ko": return "오디오 도구"
        default:   return "Audio Tools"
        }
    }

    static var audioToolsSubtitle: String {
        switch lang {
        case "ja": return "録音・再生・波形表示"
        case "zh": return "录音·播放·波形显示"
        case "ko": return "녹음·재생·파형 표시"
        default:   return "Record, play, and view waveforms"
        }
    }

    static var features: String {
        switch lang {
        case "ja": return "機能"
        case "zh": return "功能"
        case "ko": return "기능"
        default:   return "Features"
        }
    }

    static var appleWatch: String {
        switch lang {
        case "ja": return "Apple Watch連携"
        case "zh": return "Apple Watch联动"
        case "ko": return "Apple Watch 연동"
        default:   return "Apple Watch Integration"
        }
    }

    static var appleWatchFooter: String {
        switch lang {
        case "ja": return "Apple Watchから音声入力してMacにテキストを送信します。Watch側にKoeアプリのインストールが必要です。"
        case "zh": return "从Apple Watch语音输入并将文本发送到Mac。需要在Watch上安装Koe应用。"
        case "ko": return "Apple Watch에서 음성 입력하여 Mac에 텍스트를 전송합니다. Watch에 Koe 앱 설치가 필요합니다."
        default:   return "Voice input from Apple Watch sends text to Mac. Requires Koe app installed on Watch."
        }
    }

    static var p2pAudioNetwork: String {
        switch lang {
        case "ja": return "P2P音声ネットワーク"
        case "zh": return "P2P音频网络"
        case "ko": return "P2P 오디오 네트워크"
        default:   return "P2P Audio Network"
        }
    }

    static var soundPatternRecognition: String {
        switch lang {
        case "ja": return "音の記憶・パターン認識"
        case "zh": return "声音记忆·模式识别"
        case "ko": return "소리 기억·패턴 인식"
        default:   return "Sound Memory & Pattern Recognition"
        }
    }

    static var experimental: String {
        switch lang {
        case "ja": return "実験的"
        case "zh": return "实验性"
        case "ko": return "실험적"
        default:   return "Experimental"
        }
    }

    static var version: String {
        switch lang {
        case "ja": return "バージョン"
        case "zh": return "版本"
        case "ko": return "버전"
        default:   return "Version"
        }
    }

    static var website: String {
        switch lang {
        case "ja": return "Webサイト"
        case "zh": return "网站"
        case "ko": return "웹사이트"
        default:   return "Website"
        }
    }

    static var officialSite: String {
        switch lang {
        case "ja": return "公式サイト"
        case "zh": return "官方网站"
        case "ko": return "공식 사이트"
        default:   return "Official Site"
        }
    }

    // MARK: - MacScreenView

    static var screenStatus: String {
        switch lang {
        case "ja": return "画面の状況"
        case "zh": return "屏幕状态"
        case "ko": return "화면 상태"
        default:   return "Screen Status"
        }
    }

    static var analyzingScreen: String {
        switch lang {
        case "ja": return "画面を解析中..."
        case "zh": return "正在分析屏幕..."
        case "ko": return "화면 분석 중..."
        default:   return "Analyzing screen..."
        }
    }

    static var operations: String {
        switch lang {
        case "ja": return "操作"
        case "zh": return "操作"
        case "ko": return "조작"
        default:   return "Actions"
        }
    }

    static var active: String {
        switch lang {
        case "ja": return "アクティブ:"
        case "zh": return "活动:"
        case "ko": return "활성:"
        default:   return "Active:"
        }
    }

    static var macDisconnectedMessage: String {
        switch lang {
        case "ja": return "Macに接続すると\n画面の状況が表示されます"
        case "zh": return "连接Mac后\n将显示屏幕状态"
        case "ko": return "Mac에 연결하면\n화면 상태가 표시됩니다"
        default:   return "Connect to Mac to\nview screen status"
        }
    }

    static var copyAction: String {
        switch lang {
        case "ja": return "⌘C コピー"
        case "zh": return "⌘C 复制"
        case "ko": return "⌘C 복사"
        default:   return "⌘C Copy"
        }
    }

    static var pasteAction: String {
        switch lang {
        case "ja": return "⌘V ペースト"
        case "zh": return "⌘V 粘贴"
        case "ko": return "⌘V 붙여넣기"
        default:   return "⌘V Paste"
        }
    }

    static var undoAction: String {
        switch lang {
        case "ja": return "⌘Z 取消"
        case "zh": return "⌘Z 撤销"
        case "ko": return "⌘Z 실행취소"
        default:   return "⌘Z Undo"
        }
    }

    static var switchTab: String {
        switch lang {
        case "ja": return "⌘Tab 切替"
        case "zh": return "⌘Tab 切换"
        case "ko": return "⌘Tab 전환"
        default:   return "⌘Tab Switch"
        }
    }

    static var closeWindow: String {
        switch lang {
        case "ja": return "⌘W 閉じる"
        case "zh": return "⌘W 关闭"
        case "ko": return "⌘W 닫기"
        default:   return "⌘W Close"
        }
    }

    static var spacePlay: String {
        switch lang {
        case "ja": return "Space 再生"
        case "zh": return "Space 播放"
        case "ko": return "Space 재생"
        default:   return "Space Play"
        }
    }

    // MARK: - SettingsView

    static var settings: String {
        switch lang {
        case "ja": return "設定"
        case "zh": return "设置"
        case "ko": return "설정"
        default:   return "Settings"
        }
    }

    static var done: String {
        switch lang {
        case "ja": return "完了"
        case "zh": return "完成"
        case "ko": return "완료"
        default:   return "Done"
        }
    }

    static var language: String {
        switch lang {
        case "ja": return "言語"
        case "zh": return "语言"
        case "ko": return "언어"
        default:   return "Language"
        }
    }

    static var aiTextCorrection: String {
        switch lang {
        case "ja": return "AI文章補正"
        case "zh": return "AI文本校正"
        case "ko": return "AI 문장 보정"
        default:   return "AI Text Correction"
        }
    }

    static var style: String {
        switch lang {
        case "ja": return "スタイル"
        case "zh": return "风格"
        case "ko": return "스타일"
        default:   return "Style"
        }
    }

    static var styleCorrect: String {
        switch lang {
        case "ja": return "修正"
        case "zh": return "修正"
        case "ko": return "수정"
        default:   return "Correct"
        }
    }

    static var styleEmail: String {
        switch lang {
        case "ja": return "メール"
        case "zh": return "邮件"
        case "ko": return "이메일"
        default:   return "Email"
        }
    }

    static var styleChat: String {
        switch lang {
        case "ja": return "チャット"
        case "zh": return "聊天"
        case "ko": return "채팅"
        default:   return "Chat"
        }
    }

    static var styleTranslate: String {
        switch lang {
        case "ja": return "翻訳 日↔英"
        case "zh": return "翻译 日↔英"
        case "ko": return "번역 일↔영"
        default:   return "Translate JA↔EN"
        }
    }

    static var translateTarget: String {
        switch lang {
        case "ja": return "翻訳先"
        case "zh": return "目标语言"
        case "ko": return "번역 대상"
        default:   return "Target Language"
        }
    }

    static var english: String {
        switch lang {
        case "ja": return "英語"
        case "zh": return "英语"
        case "ko": return "영어"
        default:   return "English"
        }
    }

    static var japanese: String {
        switch lang {
        case "ja": return "日本語"
        case "zh": return "日语"
        case "ko": return "일본어"
        default:   return "Japanese"
        }
    }

    static var chinese: String {
        switch lang {
        case "ja": return "中国語"
        case "zh": return "中文"
        case "ko": return "중국어"
        default:   return "Chinese"
        }
    }

    static var korean: String {
        switch lang {
        case "ja": return "韓国語"
        case "zh": return "韩语"
        case "ko": return "한국어"
        default:   return "Korean"
        }
    }

    static var aiFooter: String {
        switch lang {
        case "ja": return "音声認識後にAIがテキストを整えます"
        case "zh": return "语音识别后AI整理文本"
        case "ko": return "음성 인식 후 AI가 텍스트를 정리합니다"
        default:   return "AI refines text after speech recognition"
        }
    }

    static var autoCopyAfterRecognition: String {
        switch lang {
        case "ja": return "認識後に自動コピー"
        case "zh": return "识别后自动复制"
        case "ko": return "인식 후 자동 복사"
        default:   return "Auto-copy after recognition"
        }
    }

    static var autoSendToMac: String {
        switch lang {
        case "ja": return "Macに自動送信"
        case "zh": return "自动发送到Mac"
        case "ko": return "Mac에 자동 전송"
        default:   return "Auto-send to Mac"
        }
    }

    static var continuousMode: String {
        switch lang {
        case "ja": return "連続認識モード"
        case "zh": return "连续识别模式"
        case "ko": return "연속 인식 모드"
        default:   return "Continuous Recognition Mode"
        }
    }

    static var continuousModeFooter: String {
        switch lang {
        case "ja": return "認識完了後に自動で次の録音を開始します"
        case "zh": return "识别完成后自动开始下一次录音"
        case "ko": return "인식 완료 후 자동으로 다음 녹음을 시작합니다"
        default:   return "Automatically starts next recording after recognition"
        }
    }

    static var connected: String {
        switch lang {
        case "ja": return "接続中"
        case "zh": return "已连接"
        case "ko": return "연결됨"
        default:   return "Connected"
        }
    }

    static var notConnected: String {
        switch lang {
        case "ja": return "未接続"
        case "zh": return "未连接"
        case "ko": return "미연결"
        default:   return "Not connected"
        }
    }

    static var macAutoConnect: String {
        switch lang {
        case "ja": return "同じWiFiのMacでKoeが起動中なら自動接続します"
        case "zh": return "如果同一WiFi下的Mac正在运行Koe，将自动连接"
        case "ko": return "같은 WiFi의 Mac에서 Koe가 실행 중이면 자동 연결됩니다"
        default:   return "Auto-connects when Koe is running on a Mac on the same WiFi"
        }
    }

    static var betaFeatures: String {
        switch lang {
        case "ja": return "ベータ機能"
        case "zh": return "测试功能"
        case "ko": return "베타 기능"
        default:   return "Beta Features"
        }
    }

    static var screenContextFooter: String {
        switch lang {
        case "ja": return "Macの画面をOCRで読み取り、状況要約と次のアクション提案を表示します。Screenタブと提案チップが有効になります。"
        case "zh": return "通过OCR读取Mac屏幕，显示情况摘要和操作建议。启用Screen标签和建议标签。"
        case "ko": return "Mac 화면을 OCR로 읽어 상황 요약과 다음 작업 제안을 표시합니다. Screen 탭과 제안 칩이 활성화됩니다."
        default:   return "Reads the Mac screen via OCR and shows a summary with suggested next actions. Enables the Screen tab and suggestion chips."
        }
    }

    static var silenceAutoStop: String {
        switch lang {
        case "ja": return "無音で自動停止"
        case "zh": return "静音自动停止"
        case "ko": return "무음 자동 정지"
        default:   return "Auto-stop on silence"
        }
    }

    static var offManual: String {
        switch lang {
        case "ja": return "オフ（手動停止）"
        case "zh": return "关闭（手动停止）"
        case "ko": return "끔 (수동 정지)"
        default:   return "Off (manual stop)"
        }
    }

    static var realtimePreview: String {
        switch lang {
        case "ja": return "リアルタイムプレビュー"
        case "zh": return "实时预览"
        case "ko": return "실시간 미리보기"
        default:   return "Real-time Preview"
        }
    }

    static var recording: String {
        switch lang {
        case "ja": return "録音"
        case "zh": return "录音"
        case "ko": return "녹음"
        default:   return "Recording"
        }
    }

    static var streamingPreviewFooter: String {
        switch lang {
        case "ja": return "録音中にApple Speechで仮テキストを表示します。最終結果はWhisperで認識されます。"
        case "zh": return "录音时通过Apple Speech显示临时文本。最终结果由Whisper识别。"
        case "ko": return "녹음 중 Apple Speech로 임시 텍스트를 표시합니다. 최종 결과는 Whisper로 인식됩니다."
        default:   return "Shows provisional text via Apple Speech during recording. Final result is recognized by Whisper."
        }
    }

    static var speechEngine: String {
        switch lang {
        case "ja": return "音声認識エンジン"
        case "zh": return "语音识别引擎"
        case "ko": return "음성인식 엔진"
        default:   return "Speech Recognition Engine"
        }
    }

    static var engine: String {
        switch lang {
        case "ja": return "エンジン"
        case "zh": return "引擎"
        case "ko": return "엔진"
        default:   return "Engine"
        }
    }

    static var ready: String {
        switch lang {
        case "ja": return "準備完了"
        case "zh": return "准备就绪"
        case "ko": return "준비 완료"
        default:   return "Ready"
        }
    }

    // MARK: - History

    static var history: String {
        switch lang {
        case "ja": return "履歴"
        case "zh": return "历史"
        case "ko": return "기록"
        default:   return "History"
        }
    }

    static var historyEmpty: String {
        switch lang {
        case "ja": return "音声入力するとここに表示されます"
        case "zh": return "语音输入后将在此显示"
        case "ko": return "음성 입력하면 여기에 표시됩니다"
        default:   return "Voice input will appear here"
        }
    }

    static var noHistory: String {
        switch lang {
        case "ja": return "履歴がありません"
        case "zh": return "没有历史记录"
        case "ko": return "기록이 없습니다"
        default:   return "No history"
        }
    }

    static func showAll(_ count: Int) -> String {
        switch lang {
        case "ja": return "すべて表示 (\(count)件)"
        case "zh": return "显示全部 (\(count)条)"
        case "ko": return "전체 보기 (\(count)건)"
        default:   return "Show all (\(count))"
        }
    }

    static var deleteAll: String {
        switch lang {
        case "ja": return "全削除"
        case "zh": return "全部删除"
        case "ko": return "전체 삭제"
        default:   return "Delete All"
        }
    }

    static var searchHistory: String {
        switch lang {
        case "ja": return "履歴を検索"
        case "zh": return "搜索历史"
        case "ko": return "기록 검색"
        default:   return "Search history"
        }
    }

    static var close: String {
        switch lang {
        case "ja": return "閉じる"
        case "zh": return "关闭"
        case "ko": return "닫기"
        default:   return "Close"
        }
    }

    // MARK: - Quick Phrases (Settings)

    static var quickPhrases: String {
        switch lang {
        case "ja": return "定型文（クイックフレーズ）"
        case "zh": return "常用语（快捷短语）"
        case "ko": return "정형문 (빠른 문구)"
        default:   return "Quick Phrases"
        }
    }

    static var quickPhrasesFooter: String {
        switch lang {
        case "ja": return "タップでMacに送信。左スワイプで削除。"
        case "zh": return "点击发送到Mac。左滑删除。"
        case "ko": return "탭하여 Mac에 전송. 왼쪽 스와이프로 삭제."
        default:   return "Tap to send to Mac. Swipe left to delete."
        }
    }

    static var addPhrase: String {
        switch lang {
        case "ja": return "定型文を追加"
        case "zh": return "添加常用语"
        case "ko": return "정형문 추가"
        default:   return "Add Phrase"
        }
    }

    static var enterPhrase: String {
        switch lang {
        case "ja": return "フレーズを入力"
        case "zh": return "输入短语"
        case "ko": return "문구 입력"
        default:   return "Enter phrase"
        }
    }

    static var add: String {
        switch lang {
        case "ja": return "追加"
        case "zh": return "添加"
        case "ko": return "추가"
        default:   return "Add"
        }
    }

    // MARK: - PhrasePaletteView

    static var phrasePaletteTitle: String {
        switch lang {
        case "ja": return "定型文パレット"
        case "zh": return "常用语面板"
        case "ko": return "정형문 팔레트"
        default:   return "Phrase Palette"
        }
    }

    static var noPhrases: String {
        switch lang {
        case "ja": return "定型文はまだありません"
        case "zh": return "还没有常用语"
        case "ko": return "정형문이 아직 없습니다"
        default:   return "No phrases yet"
        }
    }

    static var registeredPhrases: String {
        switch lang {
        case "ja": return "登録済みの定型文"
        case "zh": return "已注册的常用语"
        case "ko": return "등록된 정형문"
        default:   return "Registered Phrases"
        }
    }

    static var phraseEditHint: String {
        switch lang {
        case "ja": return "タップで編集、スワイプで削除、長押しで並び替え"
        case "zh": return "点击编辑，滑动删除，长按排序"
        case "ko": return "탭하여 편집, 스와이프로 삭제, 길게 눌러 정렬"
        default:   return "Tap to edit, swipe to delete, hold to reorder"
        }
    }

    static var save: String {
        switch lang {
        case "ja": return "保存"
        case "zh": return "保存"
        case "ko": return "저장"
        default:   return "Save"
        }
    }

    // MARK: - MeetingView

    static var startRecording: String {
        switch lang {
        case "ja": return "録音開始"
        case "zh": return "开始录音"
        case "ko": return "녹음 시작"
        default:   return "Start Recording"
        }
    }

    static var stop: String {
        switch lang {
        case "ja": return "停止"
        case "zh": return "停止"
        case "ko": return "정지"
        default:   return "Stop"
        }
    }

    static var share: String {
        switch lang {
        case "ja": return "共有"
        case "zh": return "分享"
        case "ko": return "공유"
        default:   return "Share"
        }
    }

    static var meetingEmpty: String {
        switch lang {
        case "ja": return "録音を開始すると文字起こしが表示されます"
        case "zh": return "开始录音后将显示转录文字"
        case "ko": return "녹음을 시작하면 문자 변환이 표시됩니다"
        default:   return "Start recording to see transcription"
        }
    }

    static var generatingSummary: String {
        switch lang {
        case "ja": return "要約を生成中…"
        case "zh": return "正在生成摘要…"
        case "ko": return "요약 생성 중…"
        default:   return "Generating summary…"
        }
    }

    static func downloadModelLabel(_ sizeMB: Int) -> String {
        switch lang {
        case "ja": return "高精度モデルをダウンロード (\(sizeMB)MB)"
        case "zh": return "下载高精度模型 (\(sizeMB)MB)"
        case "ko": return "고정밀 모델 다운로드 (\(sizeMB)MB)"
        default:   return "Download high-accuracy model (\(sizeMB)MB)"
        }
    }
}
