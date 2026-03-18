import SwiftUI
import AVFoundation
import Accelerate

// MARK: - Conversation Translation Mode
// Split-screen view for two people speaking different languages.
// Top half: Person A (blue tint), Bottom half: Person B (orange tint).
// Tap a half to record that person; whisper.cpp transcribes + translates.

struct ConversationView: View {
    @StateObject private var vm = ConversationViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Person A -- top half (blue)
                personPanel(
                    person: .a,
                    tint: .blue,
                    height: geo.size.height / 2
                )

                Divider().background(Color.white.opacity(0.2))

                // Person B -- bottom half (orange)
                personPanel(
                    person: .b,
                    tint: .orange,
                    height: geo.size.height / 2
                )
            }
        }
        .background(Color.black)
        .overlay(alignment: .top) { headerBar }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            VStack(spacing: 2) {
                Text("会話翻訳")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                if vm.isProcessing {
                    Text("認識中…")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer()
            languageSwapButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var languageSwapButton: some View {
        Button {
            withAnimation(.spring(response: 0.3)) { vm.swapLanguages() }
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: - Person Panel

    private func personPanel(person: ConversationPerson, tint: Color, height: CGFloat) -> some View {
        let isActive = vm.activePerson == person && vm.isRecording
        let entry = person == .a ? vm.personAEntry : vm.personBEntry
        let langLabel = person == .a ? vm.languageALabel : vm.languageBLabel

        return Button {
            vm.toggleRecording(for: person)
        } label: {
            ZStack {
                // Background tint
                tint.opacity(isActive ? 0.15 : 0.05)

                VStack(spacing: 12) {
                    // Language label
                    Text(langLabel)
                        .font(.caption)
                        .foregroundStyle(tint.opacity(0.8))
                        .padding(.top, 40)

                    Spacer()

                    if let entry {
                        // Original text (large)
                        Text(entry.original)
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)

                        // Translation (smaller, dimmer)
                        if !entry.translation.isEmpty {
                            Text(entry.translation)
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.6))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                    } else {
                        Text("タップして話す")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.3))
                    }

                    Spacer()

                    // Recording indicator
                    if isActive {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 10, height: 10)
                            Text("録音中…")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .padding(.bottom, 16)
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.title3)
                            .foregroundStyle(tint.opacity(0.4))
                            .padding(.bottom, 16)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: isActive)
    }
}

// MARK: - Data Types

enum ConversationPerson { case a, b }

struct ConversationEntry {
    let original: String
    let translation: String
}

// MARK: - ViewModel

@MainActor
final class ConversationViewModel: ObservableObject {
    @Published var personAEntry: ConversationEntry?
    @Published var personBEntry: ConversationEntry?
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var activePerson: ConversationPerson?

    // Language codes (whisper format: "ja", "en", etc.)
    @Published var languageA = "ja"
    @Published var languageB = "en"

    var languageALabel: String { languageDisplayName(languageA) }
    var languageBLabel: String { languageDisplayName(languageB) }

    private var audioEngine = AVAudioEngine()
    private let samplesLock = NSLock()
    private var pcmSamples: [Float] = []
    private var silenceStart: Date?
    private var silenceTimer: Timer?
    private let silenceThreshold: Float = 0.01
    private let silenceDuration: TimeInterval = 2.0

    private var useWhisper: Bool { WhisperContext.shared.isLoaded }

    // MARK: - Public

    func swapLanguages() {
        let tmp = languageA
        languageA = languageB
        languageB = tmp
    }

    func toggleRecording(for person: ConversationPerson) {
        if isRecording {
            stopRecording()
        } else {
            startRecording(for: person)
        }
    }

    // MARK: - Recording

    private func startRecording(for person: ConversationPerson) {
        guard useWhisper else { return } // Requires whisper.cpp for translate

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch { return }

        samplesLock.lock()
        pcmSamples.removeAll(keepingCapacity: true)
        pcmSamples.reserveCapacity(16000 * 30)
        samplesLock.unlock()

        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 16000, channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else { return }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // RMS for silence detection
            if let ch = buffer.floatChannelData?[0] {
                var rms: Float = 0
                vDSP_rmsqv(ch, 1, &rms, vDSP_Length(buffer.frameLength))
                DispatchQueue.main.async {
                    if rms < self.silenceThreshold {
                        if self.silenceStart == nil { self.silenceStart = Date() }
                    } else {
                        self.silenceStart = nil
                    }
                }
            }

            // Resample to 16kHz mono
            let ratio = 16000.0 / hwFormat.sampleRate
            let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return }

            converter.convert(to: outBuf, error: nil) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if let data = outBuf.floatChannelData?[0] {
                let count = Int(outBuf.frameLength)
                self.samplesLock.lock()
                self.pcmSamples.append(contentsOf: UnsafeBufferPointer(start: data, count: count))
                self.samplesLock.unlock()
            }
        }

        audioEngine.prepare()
        do { try audioEngine.start() } catch { return }

        activePerson = person
        isRecording = true
        silenceStart = nil

        // Auto-stop on silence
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.samplesLock.lock()
                let count = self.pcmSamples.count
                self.samplesLock.unlock()
                guard count > 16000 else { return }

                if let start = self.silenceStart, Date().timeIntervalSince(start) >= self.silenceDuration {
                    self.stopRecording()
                }
            }
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        silenceTimer?.invalidate()
        silenceTimer = nil
        silenceStart = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false

        samplesLock.lock()
        let samples = pcmSamples
        pcmSamples.removeAll(keepingCapacity: true)
        samplesLock.unlock()

        guard samples.count > 4000, let person = activePerson else { return }

        let sourceLang = person == .a ? languageA : languageB
        isProcessing = true

        // Step 1: Transcribe in source language
        WhisperContext.shared.transcribeBuffer(samples: samples, language: sourceLang, translate: false) { [weak self] original in
            guard let self, let original, !original.isEmpty else {
                self?.isProcessing = false
                return
            }

            // Step 2: Translate via whisper (whisper translate outputs English)
            // If source is already English, skip translation pass.
            if sourceLang == "en" {
                let entry = ConversationEntry(original: original, translation: "")
                if person == .a { self.personAEntry = entry }
                else { self.personBEntry = entry }
                self.isProcessing = false
            } else {
                WhisperContext.shared.transcribeBuffer(samples: samples, language: sourceLang, translate: true) { [weak self] translated in
                    guard let self else { return }
                    let entry = ConversationEntry(
                        original: original,
                        translation: translated ?? ""
                    )
                    if person == .a { self.personAEntry = entry }
                    else { self.personBEntry = entry }
                    self.isProcessing = false
                }
            }
        }
    }

    // MARK: - Helpers

    private func languageDisplayName(_ code: String) -> String {
        switch code {
        case "ja": return "日本語"
        case "en": return "English"
        case "zh": return "中文"
        case "ko": return "한국어"
        case "es": return "Espanol"
        case "fr": return "Francais"
        case "de": return "Deutsch"
        default: return code.uppercased()
        }
    }
}
