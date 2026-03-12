import UIKit
import AVFoundation
import Speech

class KeyboardViewController: UIInputViewController {

    private var recordButton: UIButton!
    private var statusLabel: UILabel!
    private var resultLabel: UILabel!
    private var nextKeyboardButton: UIButton!

    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isRecording = false

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    private func setupUI() {
        guard let inputView = self.inputView else { return }
        inputView.translatesAutoresizingMaskIntoConstraints = false

        let container = UIStackView()
        container.axis = .vertical
        container.spacing = 6
        container.alignment = .center
        container.translatesAutoresizingMaskIntoConstraints = false
        inputView.addSubview(container)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: inputView.topAnchor, constant: 8),
            container.bottomAnchor.constraint(equalTo: inputView.bottomAnchor, constant: -8),
            container.leadingAnchor.constraint(equalTo: inputView.leadingAnchor, constant: 12),
            container.trailingAnchor.constraint(equalTo: inputView.trailingAnchor, constant: -12),
        ])

        // Status label
        statusLabel = UILabel()
        statusLabel.text = "Koe - 声で入力"
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        container.addArrangedSubview(statusLabel)

        // Result preview
        resultLabel = UILabel()
        resultLabel.text = ""
        resultLabel.font = .systemFont(ofSize: 15)
        resultLabel.textColor = .label
        resultLabel.textAlignment = .center
        resultLabel.numberOfLines = 2
        resultLabel.adjustsFontSizeToFitWidth = true
        container.addArrangedSubview(resultLabel)

        // Button row
        let buttonRow = UIStackView()
        buttonRow.axis = .horizontal
        buttonRow.spacing = 12
        buttonRow.distribution = .fillEqually
        container.addArrangedSubview(buttonRow)

        // Next keyboard button
        nextKeyboardButton = UIButton(type: .system)
        nextKeyboardButton.setImage(UIImage(systemName: "globe"), for: .normal)
        nextKeyboardButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        nextKeyboardButton.tintColor = .secondaryLabel
        buttonRow.addArrangedSubview(nextKeyboardButton)

        // Record button
        recordButton = UIButton(type: .system)
        updateRecordButton()
        recordButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)
        recordButton.layer.cornerRadius = 25
        recordButton.clipsToBounds = true
        NSLayoutConstraint.activate([
            recordButton.widthAnchor.constraint(equalToConstant: 50),
            recordButton.heightAnchor.constraint(equalToConstant: 50),
        ])
        buttonRow.addArrangedSubview(recordButton)

        // Dismiss button
        let dismissButton = UIButton(type: .system)
        dismissButton.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        dismissButton.addTarget(self, action: #selector(dismissKbd), for: .touchUpInside)
        dismissButton.tintColor = .secondaryLabel
        buttonRow.addArrangedSubview(dismissButton)

        // Set keyboard height
        let heightConstraint = inputView.heightAnchor.constraint(equalToConstant: 160)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true
    }

    private func updateRecordButton() {
        if isRecording {
            recordButton.setImage(UIImage(systemName: "stop.fill"), for: .normal)
            recordButton.tintColor = .white
            recordButton.backgroundColor = .systemRed
        } else {
            recordButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
            recordButton.tintColor = .white
            recordButton.backgroundColor = .systemBlue
        }
    }

    @objc private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    @objc private func dismissKbd() {
        self.dismissKeyboard()
    }

    // MARK: - Recording with Apple Speech

    private func startRecording() {
        let locale = Locale(identifier: UserDefaults.standard.string(forKey: "koe_language") ?? "ja-JP")
        guard let speechRecognizer = SFSpeechRecognizer(locale: locale),
              speechRecognizer.isAvailable else {
            statusLabel.text = "音声認識が利用できません"
            return
        }

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self, status == .authorized else {
                    self?.statusLabel.text = "権限がありません"
                    return
                }
                self.beginRecognition(speechRecognizer)
            }
        }
    }

    private func beginRecognition(_ speechRecognizer: SFSpeechRecognizer) {
        recognitionTask?.cancel()
        recognitionTask = nil

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            statusLabel.text = "オーディオエラー"
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true
        if speechRecognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
        }

        let inputNode = audioEngine.inputNode
        let fmt = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.resultLabel.text = text
                }
                if result.isFinal {
                    DispatchQueue.main.async {
                        self.insertText(text)
                        self.stopRecording()
                    }
                }
            }
            if error != nil {
                DispatchQueue.main.async { self.stopRecording() }
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            statusLabel.text = "録音開始エラー"
            return
        }

        isRecording = true
        updateRecordButton()
        statusLabel.text = "録音中…"
        resultLabel.text = ""
    }

    private func insertText(_ text: String) {
        self.textDocumentProxy.insertText(text)
    }

    private func stopRecording() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask = nil
        recognitionRequest = nil
        isRecording = false
        updateRecordButton()
        statusLabel.text = "Koe - 声で入力"

        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }
}
