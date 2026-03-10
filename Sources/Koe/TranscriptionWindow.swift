import AppKit

/// ファイル文字起こし結果を表示するウィンドウ。
final class TranscriptionWindow: NSObject {
    private var window: NSWindow?
    private var progressIndicator: NSProgressIndicator!
    private var statusLabel: NSTextField!
    private var textView: NSTextView!
    private var copyButton: NSButton!
    private var saveButton: NSButton!
    private var cancelButton: NSButton!
    private var transcriber: FileTranscriber?
    private var sourceURL: URL?

    func show(fileURL: URL) {
        sourceURL = fileURL

        // Window
        let rect = NSRect(x: 0, y: 0, width: 600, height: 500)
        let w = NSWindow(contentRect: rect,
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "文字起こし — \(fileURL.lastPathComponent)"
        w.minSize = NSSize(width: 400, height: 300)
        w.center()
        w.isReleasedWhenClosed = false
        window = w

        let contentView = NSView(frame: rect)
        w.contentView = contentView

        // Status label
        statusLabel = NSTextField(labelWithString: "準備中…")
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusLabel)

        // Progress bar
        progressIndicator = NSProgressIndicator()
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.doubleValue = 0
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(progressIndicator)

        // Text view in scroll view
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)

        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        // Buttons
        cancelButton = NSButton(title: "キャンセル", target: self, action: #selector(cancelTapped))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cancelButton)

        copyButton = NSButton(title: "コピー", target: self, action: #selector(copyTapped))
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.isEnabled = false
        contentView.addSubview(copyButton)

        saveButton = NSButton(title: "TXTで保存", target: self, action: #selector(saveTapped))
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.isEnabled = false
        contentView.addSubview(saveButton)

        // Layout
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            progressIndicator.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            progressIndicator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            progressIndicator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -12),

            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            cancelButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),

            saveButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            saveButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            copyButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            copyButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
        ])

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Start transcription
        startTranscription(url: fileURL)
    }

    private func startTranscription(url: URL) {
        transcriber = FileTranscriber()
        statusLabel.stringValue = "文字起こし中…"
        progressIndicator.isIndeterminate = false

        transcriber?.transcribe(url: url, progress: { [weak self] completed, total in
            guard let self else { return }
            self.progressIndicator.doubleValue = Double(completed) / Double(total)
            self.statusLabel.stringValue = "文字起こし中… (\(completed)/\(total))"
        }, completion: { [weak self] text, error in
            guard let self else { return }
            self.progressIndicator.doubleValue = 1.0
            self.cancelButton.title = "閉じる"

            if let error {
                self.statusLabel.stringValue = "エラー: \(error)"
                self.textView.string = error
            } else if let text {
                self.statusLabel.stringValue = "完了 (\(text.count)文字)"
                self.textView.string = text
                self.copyButton.isEnabled = true
                self.saveButton.isEnabled = true
            } else {
                self.statusLabel.stringValue = "テキストを検出できませんでした"
            }
        })
    }

    @objc private func cancelTapped() {
        if transcriber != nil && statusLabel.stringValue.contains("中") {
            transcriber?.cancel()
            transcriber = nil
            statusLabel.stringValue = "キャンセルしました"
            cancelButton.title = "閉じる"
        } else {
            window?.close()
        }
    }

    @objc private func copyTapped() {
        let text = textView.string
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusLabel.stringValue = "クリップボードにコピーしました"
    }

    @objc private func saveTapped() {
        let text = textView.string
        guard !text.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let baseName = sourceURL?.deletingPathExtension().lastPathComponent ?? "transcription"
        panel.nameFieldStringValue = "\(baseName)_文字起こし.txt"

        panel.beginSheetModal(for: window!) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                self.statusLabel.stringValue = "保存しました: \(url.lastPathComponent)"
                klog("TranscriptionWindow: saved to \(url.path)")
            } catch {
                self.statusLabel.stringValue = "保存エラー: \(error.localizedDescription)"
            }
        }
    }
}
