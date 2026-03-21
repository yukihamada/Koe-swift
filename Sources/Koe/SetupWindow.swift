import AppKit
import Foundation

/// 初回起動セットアップウィンドウ。
/// おしゃれなオンボーディング + モデルDL + 権限許可をワンストップでガイド。
class SetupWindow: NSObject {
    private var window: NSWindow!
    private var contentView: NSView!
    private var completion: (() -> Void)?

    // Onboarding page
    private var onboardingView: NSView!

    // Setup page
    private var setupView: NSView!
    private var stepIndicators: [NSView] = []
    private var stepLabels: [NSTextField] = []
    private var statusLabel: NSTextField!
    private var progressBar: NSProgressIndicator!
    private var detailLabel: NSTextField!
    private var actionButton: NSButton!
    private var modelPopup: NSPopUpButton!

    private var currentStep = 0
    private var selectedModel: WhisperModel = ModelDownloader.defaultModel
    private var showLLMStep: Bool = false  // Apple Silicon + >=8GB RAM

    func show(completion: @escaping () -> Void) {
        self.completion = completion

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 540),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.backgroundColor = .windowBackgroundColor

        contentView = NSView(frame: window.contentView!.bounds)
        contentView.wantsLayer = true
        window.contentView = contentView

        showOnboarding()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Page 1: Onboarding

    // Luxury color constants
    private static let goldColor = NSColor(red: 0.78, green: 0.68, blue: 0.50, alpha: 1.0)
    private static let champagneColor = NSColor(red: 0.90, green: 0.84, blue: 0.72, alpha: 1.0)
    private static let deepCharcoal = NSColor(red: 0.10, green: 0.09, blue: 0.08, alpha: 1.0)

    private func showOnboarding() {
        onboardingView = NSView(frame: contentView.bounds)
        onboardingView.wantsLayer = true

        let w = contentView.bounds.width

        // Large app icon — elegant thin weight
        let iconLabel = NSTextField(labelWithString: "声")
        iconLabel.font = .systemFont(ofSize: 72, weight: .ultraLight)
        iconLabel.textColor = .labelColor
        iconLabel.alignment = .center
        iconLabel.frame = NSRect(x: 0, y: 420, width: w, height: 90)
        onboardingView.addSubview(iconLabel)

        // App name — refined lettering
        let appName = NSTextField(labelWithString: "Koe")
        appName.font = .systemFont(ofSize: 36, weight: .thin)
        appName.textColor = .labelColor
        appName.alignment = .center
        appName.frame = NSRect(x: 0, y: 385, width: w, height: 44)
        onboardingView.addSubview(appName)

        // Tagline
        let taglineText = ArchUtil.isAppleSilicon
            ? L10n.taglineAppleSilicon
            : L10n.taglineIntel
        let tagline = NSTextField(labelWithString: taglineText)
        tagline.font = .systemFont(ofSize: 14, weight: .light)
        tagline.textColor = .secondaryLabelColor
        tagline.alignment = .center
        tagline.frame = NSRect(x: 0, y: 360, width: w, height: 22)
        onboardingView.addSubview(tagline)

        // Feature cards
        let features: [(String, String, String)]
        features = ArchUtil.isAppleSilicon ? L10n.featuresAppleSilicon : L10n.featuresIntel

        for (i, feature) in features.enumerated() {
            let y = CGFloat(260 - i * 65)
            let card = createFeatureCard(
                icon: feature.0,
                title: feature.1,
                desc: feature.2,
                frame: NSRect(x: 40, y: y, width: w - 80, height: 55)
            )
            onboardingView.addSubview(card)
        }

        // Start button — luxe dark with gold text
        let startBtn = NSButton(frame: NSRect(x: (w - 220) / 2, y: 20, width: 220, height: 44))
        startBtn.bezelStyle = .rounded
        startBtn.title = L10n.startSetup
        startBtn.font = .systemFont(ofSize: 14, weight: .medium)
        startBtn.target = self
        startBtn.action = #selector(onStartSetup)
        startBtn.keyEquivalent = "\r"
        startBtn.contentTintColor = Self.champagneColor
        startBtn.wantsLayer = true
        startBtn.layer?.backgroundColor = Self.deepCharcoal.cgColor
        startBtn.layer?.cornerRadius = 12
        startBtn.layer?.borderWidth = 0.5
        startBtn.layer?.borderColor = Self.goldColor.withAlphaComponent(0.3).cgColor
        onboardingView.addSubview(startBtn)

        contentView.addSubview(onboardingView)
    }

    private func createFeatureCard(icon: String, title: String, desc: String, frame: NSRect) -> NSView {
        let card = NSView(frame: frame)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = Self.goldColor.withAlphaComponent(0.1).cgColor

        let iconView = NSImageView(frame: NSRect(x: 16, y: 14, width: 26, height: 26))
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .light)
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = Self.goldColor
        card.addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.frame = NSRect(x: 52, y: 28, width: frame.width - 68, height: 20)
        card.addSubview(titleLabel)

        let descLabel = NSTextField(labelWithString: desc)
        descLabel.font = .systemFont(ofSize: 12, weight: .light)
        descLabel.textColor = .secondaryLabelColor
        descLabel.frame = NSRect(x: 52, y: 8, width: frame.width - 68, height: 18)
        card.addSubview(descLabel)

        return card
    }

    @objc private func onStartSetup() {
        onboardingView.removeFromSuperview()
        showSetup()
    }

    // MARK: - Page 2: Setup Steps

    private func showSetup() {
        setupView = NSView(frame: contentView.bounds)
        setupView.wantsLayer = true

        let w = contentView.bounds.width

        // Header
        let headerBg = NSView(frame: NSRect(x: 0, y: 440, width: w, height: 100))
        headerBg.wantsLayer = true
        setupView.addSubview(headerBg)

        let icon = NSTextField(labelWithString: "声")
        icon.font = .systemFont(ofSize: 36, weight: .ultraLight)
        icon.frame = NSRect(x: 30, y: 460, width: 50, height: 44)
        setupView.addSubview(icon)

        let title = NSTextField(labelWithString: L10n.setupTitle)
        title.font = .systemFont(ofSize: 24, weight: .thin)
        title.frame = NSRect(x: 85, y: 468, width: 300, height: 32)
        setupView.addSubview(title)

        // LLMステップを表示するか判定 (Apple Silicon + 8GB以上)
        showLLMStep = ArchUtil.isAppleSilicon && MemoryMonitor.totalMemoryMB >= 8000

        let stepCount = showLLMStep ? 4 : 3
        let subtitle = NSTextField(labelWithString: L10n.stepsToComplete(stepCount))
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 85, y: 448, width: 300, height: 18)
        setupView.addSubview(subtitle)

        // Divider
        let divider = NSView(frame: NSRect(x: 30, y: 438, width: w - 60, height: 1))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        setupView.addSubview(divider)

        // Steps
        var steps = [L10n.stepVoiceModel]
        if showLLMStep { steps.append(L10n.stepAIModel) }
        steps.append(contentsOf: [L10n.stepMicrophone, L10n.stepAccessibility, L10n.stepDone])
        for (i, step) in steps.enumerated() {
            let y = 380 - i * 42

            let dot = NSView(frame: NSRect(x: 40, y: y + 4, width: 14, height: 14))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 7
            dot.layer?.backgroundColor = NSColor.separatorColor.cgColor
            setupView.addSubview(dot)
            stepIndicators.append(dot)

            let label = NSTextField(labelWithString: step)
            label.font = .systemFont(ofSize: 14)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 66, y: y, width: 250, height: 20)
            setupView.addSubview(label)
            stepLabels.append(label)

            if i < steps.count - 1 {
                let line = NSView(frame: NSRect(x: 46, y: y - 24, width: 2, height: 24))
                line.wantsLayer = true
                line.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
                setupView.addSubview(line)
            }
        }

        // Model picker
        let modelLabel = NSTextField(labelWithString: L10n.modelSelectLabel)
        modelLabel.font = .systemFont(ofSize: 12, weight: .medium)
        modelLabel.textColor = .secondaryLabelColor
        modelLabel.frame = NSRect(x: 30, y: 195, width: 80, height: 18)
        setupView.addSubview(modelLabel)

        modelPopup = NSPopUpButton(frame: NSRect(x: 110, y: 191, width: w - 140, height: 26))
        modelPopup.font = .systemFont(ofSize: 12)
        modelPopup.target = self
        modelPopup.action = #selector(onModelChanged)
        for model in ModelDownloader.availableModels {
            let rec = model.isDefault ? " *" : ""
            let title = "\(model.name) — \(model.description) (\(model.sizeMB)MB)\(rec)"
            modelPopup.addItem(withTitle: title)
        }
        if let idx = ModelDownloader.availableModels.firstIndex(where: { $0.isDefault }) {
            modelPopup.selectItem(at: idx)
        }
        setupView.addSubview(modelPopup)

        // Status area (card style)
        let statusCard = NSView(frame: NSRect(x: 30, y: 80, width: w - 60, height: 100))
        statusCard.wantsLayer = true
        statusCard.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        statusCard.layer?.cornerRadius = 10
        setupView.addSubview(statusCard)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.frame = NSRect(x: 16, y: 65, width: statusCard.frame.width - 32, height: 22)
        statusCard.addSubview(statusLabel)

        progressBar = NSProgressIndicator(frame: NSRect(x: 16, y: 40, width: statusCard.frame.width - 32, height: 20))
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.style = .bar
        progressBar.isHidden = true
        statusCard.addSubview(progressBar)

        detailLabel = NSTextField(labelWithString: "")
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.frame = NSRect(x: 16, y: 16, width: statusCard.frame.width - 32, height: 16)
        statusCard.addSubview(detailLabel)

        // Action button
        actionButton = NSButton(frame: NSRect(x: w - 150, y: 30, width: 120, height: 36))
        actionButton.bezelStyle = .rounded
        actionButton.title = L10n.setupStart
        actionButton.font = .systemFont(ofSize: 13, weight: .medium)
        actionButton.target = self
        actionButton.action = #selector(onAction)
        actionButton.keyEquivalent = "\r"
        actionButton.isHidden = true
        setupView.addSubview(actionButton)

        // Version label
        let versionStr = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0"
        let versionLabel = NSTextField(labelWithString: "v\(versionStr)")
        versionLabel.font = .systemFont(ofSize: 10)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.frame = NSRect(x: 30, y: 36, width: 100, height: 14)
        setupView.addSubview(versionLabel)

        contentView.addSubview(setupView)

        // 自動開始
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.runStep1_Model()
        }
    }

    @objc private func onModelChanged() {
        let idx = modelPopup.indexOfSelectedItem
        guard idx >= 0 && idx < ModelDownloader.availableModels.count else { return }
        selectedModel = ModelDownloader.availableModels[idx]
    }

    private func setStep(_ index: Int, active: Bool = true) {
        currentStep = index
        for (i, dot) in stepIndicators.enumerated() {
            if i < index {
                dot.layer?.backgroundColor = Self.goldColor.cgColor
            } else if i == index && active {
                dot.layer?.backgroundColor = Self.goldColor.withAlphaComponent(0.7).cgColor
            } else {
                dot.layer?.backgroundColor = NSColor.separatorColor.cgColor
            }
        }
        for (i, label) in stepLabels.enumerated() {
            if i < index {
                label.textColor = .labelColor
                label.font = .systemFont(ofSize: 14, weight: .light)
            } else if i == index {
                label.textColor = .labelColor
                label.font = .systemFont(ofSize: 14, weight: .medium)
            } else {
                label.textColor = .secondaryLabelColor
                label.font = .systemFont(ofSize: 14, weight: .light)
            }
        }
    }

    /// 次のステップへ進む（LLMステップの有無で分岐）
    private func advanceAfterWhisperModel() {
        if showLLMStep {
            runStepLLM()
        } else {
            runStep2_Microphone()
        }
    }

    // MARK: - Step 1: Model Download

    private func runStep1_Model() {
        setStep(0)
        actionButton.isHidden = true

        // Intel Mac: whisper.cpp モデルは不要 → スキップ
        if !ArchUtil.isAppleSilicon {
            statusLabel.stringValue = L10n.intelNoModelNeeded
            detailLabel.stringValue = L10n.intelUseApple
            modelPopup.isEnabled = false
            modelPopup.isHidden = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.advanceAfterWhisperModel()
            }
            return
        }

        if ModelDownloader.shared.isDownloaded(selectedModel) {
            ModelDownloader.shared.selectModel(selectedModel)
            statusLabel.stringValue = L10n.modelAlreadyDownloaded
            detailLabel.stringValue = selectedModel.name
            modelPopup.isEnabled = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.advanceAfterWhisperModel()
            }
            return
        }

        statusLabel.stringValue = L10n.downloadingModel
        detailLabel.stringValue = "\(selectedModel.name) (\(selectedModel.sizeMB)MB)"
        progressBar.isHidden = false
        progressBar.doubleValue = 0
        modelPopup.isEnabled = false

        startModelDownload()
    }

    private func startModelDownload() {
        let dl = ModelDownloader.shared
        let model = selectedModel
        try? FileManager.default.createDirectory(at: dl.modelDir, withIntermediateDirectories: true)

        let url = URL(string: model.url)!
        let session = URLSession(configuration: .default)

        let task = session.downloadTask(with: url) { [weak self] tempURL, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.statusLabel.stringValue = L10n.downloadFailed
                    self.detailLabel.stringValue = error.localizedDescription
                    self.actionButton.title = L10n.retry
                    self.actionButton.isHidden = false
                    self.modelPopup.isEnabled = true
                    return
                }
                guard let tempURL else { return }
                let dest = dl.modelDir.appendingPathComponent(model.fileName)
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                    dl.selectModel(model)
                    self.progressBar.isHidden = true
                    self.statusLabel.stringValue = L10n.modelDownloadComplete
                    self.detailLabel.stringValue = model.name
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.advanceAfterWhisperModel()
                    }
                } catch {
                    self.statusLabel.stringValue = L10n.saveFailed(error.localizedDescription)
                    self.modelPopup.isEnabled = true
                }
            }
        }

        let observer = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] (progress: Progress, _: NSKeyValueObservedChange<Double>) in
            DispatchQueue.main.async {
                self?.progressBar.doubleValue = progress.fractionCompleted * 100
                let mb = Double(progress.completedUnitCount) / 1_000_000
                let total = Double(progress.totalUnitCount) / 1_000_000
                if total > 0 {
                    self?.detailLabel.stringValue = String(format: "%.0f / %.0f MB", mb, total)
                }
            }
        }
        objc_setAssociatedObject(task, "obs", observer, .OBJC_ASSOCIATION_RETAIN)
        task.resume()
    }

    // MARK: - Step LLM: Local AI Model (Apple Silicon + >=8GB only)

    private func runStepLLM() {
        setStep(1)  // LLMステップは常にindex 1（showLLMStep=true時のみ呼ばれる）
        modelPopup.isHidden = true

        let llama = LlamaContext.shared
        guard let recommended = MemoryMonitor.recommendedLLMModel(),
              let model = LlamaContext.availableModels.first(where: { $0.id == recommended }) else {
            // 推奨モデルなし → スキップ
            statusLabel.stringValue = L10n.llmModelSkipped
            detailLabel.stringValue = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.runStep2_Microphone()
            }
            return
        }

        // 既にダウンロード済み
        if llama.isDownloaded(model) {
            statusLabel.stringValue = L10n.llmAlreadyDownloaded
            detailLabel.stringValue = "\(model.name) — \(L10n.llmOfflineCapable)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.runStep2_Microphone()
            }
            return
        }

        // ダウンロードを提案
        statusLabel.stringValue = L10n.llmLocalAI
        detailLabel.stringValue = "\(model.name) (\(model.sizeMB)MB)\n\(L10n.llmOfflineCapable)"
        detailLabel.maximumNumberOfLines = 2
        progressBar.isHidden = true

        actionButton.title = L10n.download
        actionButton.isHidden = false
        actionButton.wantsLayer = true
        actionButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        actionButton.contentTintColor = .white
        actionButton.layer?.cornerRadius = 8

        // スキップボタンを追加
        let w = contentView.bounds.width
        let skipBtn = NSButton(frame: NSRect(x: w - 280, y: 30, width: 120, height: 36))
        skipBtn.bezelStyle = .rounded
        skipBtn.title = L10n.skip
        skipBtn.font = .systemFont(ofSize: 13)
        skipBtn.tag = 999  // 識別用
        skipBtn.target = self
        skipBtn.action = #selector(onSkipLLM)
        setupView.addSubview(skipBtn)

        // actionButton のアクションを一時差し替え
        actionButton.action = #selector(onDownloadLLM)
    }

    @objc private func onSkipLLM() {
        // スキップボタンを削除
        setupView.subviews.first { $0.tag == 999 }?.removeFromSuperview()
        actionButton.action = #selector(onAction)
        actionButton.isHidden = true
        statusLabel.stringValue = L10n.llmModelSkipped
        detailLabel.stringValue = L10n.skipAvailableLater
        detailLabel.maximumNumberOfLines = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.runStep2_Microphone()
        }
    }

    @objc private func onDownloadLLM() {
        // スキップボタンを削除
        setupView.subviews.first { $0.tag == 999 }?.removeFromSuperview()
        actionButton.isHidden = true

        guard let recommended = MemoryMonitor.recommendedLLMModel(),
              let model = LlamaContext.availableModels.first(where: { $0.id == recommended }) else {
            runStep2_Microphone(); return
        }

        statusLabel.stringValue = L10n.llmDownloading
        detailLabel.stringValue = "\(model.name) (\(model.sizeMB)MB)"
        detailLabel.maximumNumberOfLines = 1
        progressBar.isHidden = false
        progressBar.doubleValue = 0

        LlamaContext.shared.downloadModel(model, progress: { [weak self] pct, detail in
            self?.progressBar.doubleValue = pct
            self?.detailLabel.stringValue = detail
        }) { [weak self] success in
            guard let self else { return }
            self.progressBar.isHidden = true
            if success {
                self.statusLabel.stringValue = L10n.llmDownloadComplete
                self.detailLabel.stringValue = model.name
            } else {
                self.statusLabel.stringValue = L10n.llmDownloadFailed
            }
            self.actionButton.action = #selector(self.onAction)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.runStep2_Microphone()
            }
        }
    }

    // MARK: - Step 2: Microphone

    private func runStep2_Microphone() {
        let micStep = showLLMStep ? 2 : 1
        setStep(micStep)
        statusLabel.stringValue = L10n.micRequestAccess
        detailLabel.stringValue = L10n.micNeeded
        actionButton.isHidden = true

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    self?.statusLabel.stringValue = L10n.micOK
                    self?.detailLabel.stringValue = ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self?.runStep3_Accessibility()
                    }
                } else {
                    self?.statusLabel.stringValue = L10n.micRequired
                    self?.detailLabel.stringValue = L10n.micOpenSettings
                    self?.actionButton.title = L10n.openSystemSettings
                    self?.actionButton.isHidden = false
                }
            }
        }
    }

    // MARK: - Step 3: Accessibility

    private func runStep3_Accessibility() {
        let accStep = showLLMStep ? 3 : 2
        setStep(accStep)
        let trusted = AXIsProcessTrusted()
        if trusted {
            statusLabel.stringValue = L10n.accessibilityOK
            detailLabel.stringValue = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.runStep4_Done()
            }
            return
        }

        statusLabel.stringValue = L10n.accessibilityRequest
        detailLabel.stringValue = L10n.accessibilityNeeded

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        pollAccessibility()
    }

    private func pollAccessibility() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if AXIsProcessTrusted() {
                self?.statusLabel.stringValue = L10n.accessibilityOK
                self?.detailLabel.stringValue = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self?.runStep4_Done()
                }
            } else {
                self?.pollAccessibility()
            }
        }
    }

    // MARK: - Step 4: Done → Tutorial

    private func runStep4_Done() {
        let doneStep = showLLMStep ? 4 : 3
        setStep(doneStep)

        // セットアップ画面を消してチュートリアル画面を表示
        setupView.removeFromSuperview()
        showTutorial()
    }

    // MARK: - Page 3: Tutorial

    private var tutorialView: NSView!

    private func showTutorial() {
        let newSize = NSSize(width: 480, height: 480)
        window.setContentSize(newSize)

        tutorialView = NSView(frame: NSRect(origin: .zero, size: newSize))
        tutorialView.wantsLayer = true

        let w = newSize.width

        // Minimal header
        let title = NSTextField(labelWithString: L10n.tutorialReady)
        title.font = .systemFont(ofSize: 20, weight: .thin)
        title.textColor = .labelColor
        title.alignment = .center
        title.frame = NSRect(x: 0, y: 420, width: w, height: 30)
        tutorialView.addSubview(title)

        // 3 feature cards — clean and spacious
        let cards = L10n.tutorialCards
        for (i, card) in cards.enumerated() {
            let y = CGFloat(310 - i * 90)
            let cardView = createTutorialCard(
                icon: card.icon,
                title: card.title,
                desc: card.desc,
                shortcut: card.shortcut,
                frame: NSRect(x: 40, y: y, width: w - 80, height: 76)
            )
            tutorialView.addSubview(cardView)
        }

        // iPhone app promotion
        let iphoneCard = NSView(frame: NSRect(x: 40, y: 86, width: w - 80, height: 76))
        iphoneCard.wantsLayer = true
        iphoneCard.layer?.backgroundColor = NSColor(red: 1, green: 0.58, blue: 0, alpha: 0.08).cgColor
        iphoneCard.layer?.cornerRadius = 14
        iphoneCard.layer?.borderWidth = 0.5
        iphoneCard.layer?.borderColor = NSColor.orange.withAlphaComponent(0.2).cgColor

        let phoneIcon = NSTextField(labelWithString: "📱")
        phoneIcon.font = .systemFont(ofSize: 28)
        phoneIcon.isBezeled = false; phoneIcon.isEditable = false; phoneIcon.drawsBackground = false
        phoneIcon.frame = NSRect(x: 16, y: 22, width: 36, height: 36)
        iphoneCard.addSubview(phoneIcon)

        let phoneTitle = NSTextField(labelWithString: "iPhoneでもっと便利に")
        phoneTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        phoneTitle.textColor = .labelColor
        phoneTitle.isBezeled = false; phoneTitle.isEditable = false; phoneTitle.drawsBackground = false
        phoneTitle.frame = NSRect(x: 60, y: 44, width: 240, height: 20)
        iphoneCard.addSubview(phoneTitle)

        let phoneDesc = NSTextField(labelWithString: "iPhoneから声でMac操作・画面AI・ハンズフリー入力")
        phoneDesc.font = .systemFont(ofSize: 11)
        phoneDesc.textColor = .secondaryLabelColor
        phoneDesc.isBezeled = false; phoneDesc.isEditable = false; phoneDesc.drawsBackground = false
        phoneDesc.frame = NSRect(x: 60, y: 26, width: 300, height: 16)
        iphoneCard.addSubview(phoneDesc)

        let phoneBtn = NSButton(frame: NSRect(x: 60, y: 4, width: 180, height: 22))
        phoneBtn.bezelStyle = .rounded
        phoneBtn.title = "iPhone版を入手 →"
        phoneBtn.font = .systemFont(ofSize: 11, weight: .medium)
        phoneBtn.target = self
        phoneBtn.action = #selector(openIPhoneApp)
        phoneBtn.isBordered = false
        phoneBtn.contentTintColor = .orange
        iphoneCard.addSubview(phoneBtn)

        tutorialView.addSubview(iphoneCard)

        // Button — minimal
        let tryBtn = NSButton(frame: NSRect(x: (w - 200) / 2, y: 10, width: 200, height: 40))
        tryBtn.bezelStyle = .rounded
        tryBtn.title = L10n.tryNow
        tryBtn.font = .systemFont(ofSize: 14, weight: .medium)
        tryBtn.target = self
        tryBtn.action = #selector(onFinishTutorial)
        tryBtn.keyEquivalent = "\r"
        tryBtn.wantsLayer = true
        tryBtn.layer?.backgroundColor = Self.deepCharcoal.cgColor
        tryBtn.contentTintColor = Self.champagneColor
        tryBtn.layer?.cornerRadius = 10
        tryBtn.layer?.borderWidth = 0.5
        tryBtn.layer?.borderColor = Self.goldColor.withAlphaComponent(0.2).cgColor
        tutorialView.addSubview(tryBtn)

        contentView.addSubview(tutorialView)
    }

    private func createTutorialCard(icon: String, title: String, desc: String, shortcut: String, frame: NSRect) -> NSView {
        let card = NSView(frame: frame)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = 14
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = Self.goldColor.withAlphaComponent(0.1).cgColor

        // Icon circle — gold tinted
        let iconBg = NSView(frame: NSRect(x: 14, y: 22, width: 36, height: 36))
        iconBg.wantsLayer = true
        iconBg.layer?.backgroundColor = Self.goldColor.withAlphaComponent(0.08).cgColor
        iconBg.layer?.cornerRadius = 18
        card.addSubview(iconBg)

        let iconView = NSImageView(frame: NSRect(x: 22, y: 30, width: 20, height: 20))
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .light)
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = Self.goldColor
        card.addSubview(iconView)

        // Title
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.frame = NSRect(x: 62, y: 46, width: frame.width - 78, height: 20)
        card.addSubview(titleLabel)

        // Description
        let descLabel = NSTextField(labelWithString: desc)
        descLabel.font = .systemFont(ofSize: 12, weight: .light)
        descLabel.textColor = .secondaryLabelColor
        descLabel.frame = NSRect(x: 62, y: 28, width: frame.width - 78, height: 16)
        card.addSubview(descLabel)

        // Shortcut badge — gold themed
        let badge = NSTextField(labelWithString: shortcut)
        badge.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        badge.textColor = Self.goldColor
        badge.alignment = .left
        badge.wantsLayer = true
        badge.backgroundColor = Self.goldColor.withAlphaComponent(0.06)
        badge.isBezeled = false
        badge.isEditable = false
        badge.frame = NSRect(x: 62, y: 8, width: frame.width - 78, height: 16)
        card.addSubview(badge)

        return card
    }

    @objc private func onFinishTutorial() {
        window.close()
        completion?()
    }

    @objc private func openIPhoneApp() {
        // TestFlight or App Store URL
        if let url = URL(string: "https://app.koe.live") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func onAction() {
        let micStep = showLLMStep ? 2 : 1
        let accStep = showLLMStep ? 3 : 2

        switch currentStep {
        case 0:
            runStep1_Model()
        case micStep:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        case accStep:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        default:
            break
        }
    }
}

import AVFoundation
