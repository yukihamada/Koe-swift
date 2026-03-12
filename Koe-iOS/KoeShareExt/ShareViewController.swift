import UIKit
import AVFoundation
import Speech

class ShareViewController: UIViewController {

    private var recordButton: UIButton!
    private var statusLabel: UILabel!
    private var resultTextView: UITextView!
    private var insertButton: UIButton!

    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isRecording = false
    private var recognizedText = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
    }

    private func setupUI() {
        let titleLabel = UILabel()
        titleLabel.text = "Koe - 声で入力"
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        statusLabel = UILabel()
        statusLabel.text = "マイクボタンを押して録音"
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        resultTextView = UITextView()
        resultTextView.font = .systemFont(ofSize: 16)
        resultTextView.isEditable = true
        resultTextView.layer.cornerRadius = 12
        resultTextView.layer.borderColor = UIColor.separator.cgColor
        resultTextView.layer.borderWidth = 1
        resultTextView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        resultTextView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(resultTextView)

        recordButton = UIButton(type: .system)
        recordButton.setImage(UIImage(systemName: "mic.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 56)), for: .normal)
        recordButton.tintColor = .systemBlue
        recordButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(recordButton)

        let buttonStack = UIStackView()
        buttonStack.axis = .horizontal
        buttonStack.spacing = 12
        buttonStack.distribution = .fillEqually
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttonStack)

        let copyButton = UIButton(type: .system)
        copyButton.setTitle("コピー", for: .normal)
        copyButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        copyButton.backgroundColor = .systemGray5
        copyButton.layer.cornerRadius = 10
        copyButton.addTarget(self, action: #selector(copyText), for: .touchUpInside)
        buttonStack.addArrangedSubview(copyButton)

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("閉じる", for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        closeButton.backgroundColor = .systemGray5
        closeButton.layer.cornerRadius = 10
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        buttonStack.addArrangedSubview(closeButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            resultTextView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            resultTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            resultTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            resultTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),

            recordButton.topAnchor.constraint(equalTo: resultTextView.bottomAnchor, constant: 16),
            recordButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            buttonStack.topAnchor.constraint(equalTo: recordButton.bottomAnchor, constant: 16),
            buttonStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            buttonStack.heightAnchor.constraint(equalToConstant: 44),
            buttonStack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    @objc private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    @objc private func copyText() {
        let text = resultTextView.text ?? ""
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        statusLabel.text = "コピーしました"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.statusLabel.text = "マイクボタンを押して録音"
        }
    }

    @objc private func close() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    // MARK: - Recording

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
                    self.resultTextView.text = text
                    self.recognizedText = text
                }
                if result.isFinal {
                    DispatchQueue.main.async { self.stopRecording() }
                }
            }
            if error != nil {
                DispatchQueue.main.async { self.stopRecording() }
            }
        }

        audioEngine.prepare()
        do { try audioEngine.start() } catch {
            statusLabel.text = "録音開始エラー"
            return
        }

        isRecording = true
        recordButton.setImage(UIImage(systemName: "stop.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 56)), for: .normal)
        recordButton.tintColor = .systemRed
        statusLabel.text = "録音中…"
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
        recordButton.setImage(UIImage(systemName: "mic.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 56)), for: .normal)
        recordButton.tintColor = .systemBlue
        statusLabel.text = "マイクボタンを押して録音"

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
