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

    private func showOnboarding() {
        onboardingView = NSView(frame: contentView.bounds)
        onboardingView.wantsLayer = true

        let w = contentView.bounds.width

        // Large app icon
        let iconLabel = NSTextField(labelWithString: "声")
        iconLabel.font = .systemFont(ofSize: 72, weight: .bold)
        iconLabel.textColor = .labelColor
        iconLabel.alignment = .center
        iconLabel.frame = NSRect(x: 0, y: 420, width: w, height: 90)
        onboardingView.addSubview(iconLabel)

        // App name
        let appName = NSTextField(labelWithString: "Koe")
        appName.font = .systemFont(ofSize: 36, weight: .bold)
        appName.textColor = .labelColor
        appName.alignment = .center
        appName.frame = NSRect(x: 0, y: 385, width: w, height: 44)
        onboardingView.addSubview(appName)

        // Tagline
        let tagline = NSTextField(labelWithString: "Mac で最も速い日本語音声入力")
        tagline.font = .systemFont(ofSize: 16)
        tagline.textColor = .secondaryLabelColor
        tagline.alignment = .center
        tagline.frame = NSRect(x: 0, y: 360, width: w, height: 22)
        onboardingView.addSubview(tagline)

        // Feature cards
        let features: [(String, String, String)] = [
            ("bolt.fill", "0.5秒以内に認識", "whisper.cpp + Metal GPU で超高速変換"),
            ("lock.shield.fill", "完全ローカル処理", "音声データは一切クラウドへ送信しません"),
            ("mic.fill", "ハンズフリー対応", "ウェイクワード「ヘイこえ」で起動"),
            ("app.badge.fill", "アプリ別最適化", "アプリごとにプロンプトや言語を切替"),
        ]

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

        // Start button
        let startBtn = NSButton(frame: NSRect(x: (w - 200) / 2, y: 20, width: 200, height: 44))
        startBtn.bezelStyle = .rounded
        startBtn.title = "セットアップを始める"
        startBtn.font = .systemFont(ofSize: 15, weight: .semibold)
        startBtn.target = self
        startBtn.action = #selector(onStartSetup)
        startBtn.keyEquivalent = "\r"
        startBtn.contentTintColor = .white
        startBtn.wantsLayer = true
        startBtn.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        startBtn.layer?.cornerRadius = 10
        onboardingView.addSubview(startBtn)

        contentView.addSubview(onboardingView)
    }

    private func createFeatureCard(icon: String, title: String, desc: String, frame: NSRect) -> NSView {
        let card = NSView(frame: frame)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = 10

        let iconView = NSImageView(frame: NSRect(x: 16, y: 14, width: 26, height: 26))
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = .controlAccentColor
        card.addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.frame = NSRect(x: 52, y: 28, width: frame.width - 68, height: 20)
        card.addSubview(titleLabel)

        let descLabel = NSTextField(labelWithString: desc)
        descLabel.font = .systemFont(ofSize: 12)
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
        icon.font = .systemFont(ofSize: 36, weight: .bold)
        icon.frame = NSRect(x: 30, y: 460, width: 50, height: 44)
        setupView.addSubview(icon)

        let title = NSTextField(labelWithString: "セットアップ")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.frame = NSRect(x: 85, y: 468, width: 300, height: 32)
        setupView.addSubview(title)

        let subtitle = NSTextField(labelWithString: "3ステップで完了します")
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
        let steps = ["音声認識モデル", "マイク権限", "アクセシビリティ権限", "完了"]
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
        let modelLabel = NSTextField(labelWithString: "モデル選択:")
        modelLabel.font = .systemFont(ofSize: 12, weight: .medium)
        modelLabel.textColor = .secondaryLabelColor
        modelLabel.frame = NSRect(x: 30, y: 195, width: 80, height: 18)
        setupView.addSubview(modelLabel)

        modelPopup = NSPopUpButton(frame: NSRect(x: 110, y: 191, width: w - 140, height: 26))
        modelPopup.font = .systemFont(ofSize: 12)
        modelPopup.target = self
        modelPopup.action = #selector(onModelChanged)
        for model in ModelDownloader.availableModels {
            let title = "\(model.name) — \(model.description) (\(model.sizeMB)MB)"
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
        actionButton.title = "セットアップ開始"
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
                dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            } else if i == index && active {
                dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            } else {
                dot.layer?.backgroundColor = NSColor.separatorColor.cgColor
            }
        }
        for (i, label) in stepLabels.enumerated() {
            if i < index {
                label.textColor = .labelColor
                label.font = .systemFont(ofSize: 14)
            } else if i == index {
                label.textColor = .labelColor
                label.font = .systemFont(ofSize: 14, weight: .semibold)
            } else {
                label.textColor = .secondaryLabelColor
                label.font = .systemFont(ofSize: 14)
            }
        }
    }

    // MARK: - Step 1: Model Download

    private func runStep1_Model() {
        setStep(0)
        actionButton.isHidden = true

        if ModelDownloader.shared.isDownloaded(selectedModel) {
            ModelDownloader.shared.selectModel(selectedModel)
            statusLabel.stringValue = "モデルは既にダウンロード済み"
            detailLabel.stringValue = selectedModel.name
            modelPopup.isEnabled = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.runStep2_Microphone()
            }
            return
        }

        statusLabel.stringValue = "音声認識モデルをダウンロード中..."
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
                    self.statusLabel.stringValue = "ダウンロード失敗"
                    self.detailLabel.stringValue = error.localizedDescription
                    self.actionButton.title = "リトライ"
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
                    self.statusLabel.stringValue = "モデルダウンロード完了"
                    self.detailLabel.stringValue = model.name
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.runStep2_Microphone()
                    }
                } catch {
                    self.statusLabel.stringValue = "保存に失敗: \(error.localizedDescription)"
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

    // MARK: - Step 2: Microphone

    private func runStep2_Microphone() {
        setStep(1)
        statusLabel.stringValue = "マイクへのアクセスを許可してください"
        detailLabel.stringValue = "音声入力に必要です"
        actionButton.isHidden = true

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    self?.statusLabel.stringValue = "マイク権限 OK"
                    self?.detailLabel.stringValue = ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self?.runStep3_Accessibility()
                    }
                } else {
                    self?.statusLabel.stringValue = "マイク権限が必要です"
                    self?.detailLabel.stringValue = "システム設定 → プライバシーとセキュリティ → マイク"
                    self?.actionButton.title = "システム設定を開く"
                    self?.actionButton.isHidden = false
                }
            }
        }
    }

    // MARK: - Step 3: Accessibility

    private func runStep3_Accessibility() {
        setStep(2)
        let trusted = AXIsProcessTrusted()
        if trusted {
            statusLabel.stringValue = "アクセシビリティ権限 OK"
            detailLabel.stringValue = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.runStep4_Done()
            }
            return
        }

        statusLabel.stringValue = "アクセシビリティ権限を許可してください"
        detailLabel.stringValue = "テキスト入力に必要です。ダイアログが表示されます。"

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        pollAccessibility()
    }

    private func pollAccessibility() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if AXIsProcessTrusted() {
                self?.statusLabel.stringValue = "アクセシビリティ権限 OK"
                self?.detailLabel.stringValue = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self?.runStep4_Done()
                }
            } else {
                self?.pollAccessibility()
            }
        }
    }

    // MARK: - Step 4: Done

    private func runStep4_Done() {
        setStep(3)

        statusLabel.stringValue = "セットアップ完了！"
        detailLabel.stringValue = ""

        // Show usage guide in status card area
        let usageGuide = "⌥⌘V を長押し → 話す → 離すと変換\nトグルモードなら2回押しで録音開始/停止"
        detailLabel.stringValue = usageGuide
        detailLabel.maximumNumberOfLines = 2

        actionButton.title = "始める"
        actionButton.isHidden = false
        actionButton.wantsLayer = true
        actionButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        actionButton.contentTintColor = .white
        actionButton.layer?.cornerRadius = 8
    }

    @objc private func onAction() {
        switch currentStep {
        case 0:
            runStep1_Model()
        case 1:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        case 2:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        case 3:
            window.close()
            completion?()
        default:
            break
        }
    }
}

import AVFoundation
