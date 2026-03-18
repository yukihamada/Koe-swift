import SwiftUI
import AVFoundation
import Accelerate

// MARK: - Audio Engine Manager

/// Shared audio engine that provides real-time mic data to all tools.
/// Manages its own AVAudioEngine, independent from RecordingManager.
@MainActor
final class AudioToolsEngine: ObservableObject {
    static let shared = AudioToolsEngine()

    // Raw samples ring buffer (~2 seconds at 44100)
    @Published var waveformSamples: [Float] = Array(repeating: 0, count: 88200)
    @Published var currentRMS: Float = 0
    @Published var peakRMS: Float = 0
    @Published var splDB: Float = 0
    @Published var peakDB: Float = 0
    @Published var spectrumBars: [Float] = Array(repeating: 0, count: 64)
    @Published var peakFrequency: Float = 0
    @Published var detectedPitch: Float = 0
    @Published var detectedNote: String = "--"
    @Published var centsDeviation: Float = 0
    @Published var bpm: Int = 0
    @Published var isRunning = false

    private var audioEngine: AVAudioEngine?
    private let sampleRate: Float = 44100
    private let bufferSize: AVAudioFrameCount = 4096

    // FFT setup
    private var fftSetup: vDSP_DFT_Setup?
    private let fftSize = 4096

    // BPM detection
    private var onsetTimes: [TimeInterval] = []
    private var lastOnsetTime: TimeInterval = 0
    private var lastOnsetStrength: Float = 0
    // Onset detection state (accessed only on main actor via processBuffer dispatch)
    private var previousSpectralFlux: Float = 0
    private var previousMagnitudes: [Float] = []

    // Effects
    private var reverb: AVAudioUnitReverb?
    private var delay: AVAudioUnitDelay?
    private var timePitch: AVAudioUnitTimePitch?
    private var playerNode: AVAudioPlayerNode?
    @Published var reverbEnabled = false { didSet { updateEffectChain() } }
    @Published var delayEnabled = false { didSet { updateEffectChain() } }
    @Published var pitchShiftEnabled = false { didSet { updateEffectChain() } }
    @Published var reverbWetDry: Float = 50 { didSet { reverb?.wetDryMix = reverbWetDry } }
    @Published var delayTime: Float = 0.3 { didSet { delay?.delayTime = TimeInterval(delayTime) } }
    @Published var delayFeedback: Float = 50 { didSet { delay?.feedback = delayFeedback } }
    @Published var pitchShiftSemitones: Float = 0 { didSet { timePitch?.pitch = pitchShiftSemitones * 100 } }
    @Published var monitoringEnabled = false { didSet { updateEffectChain() } }

    // Tap tempo
    @Published var tapTempoBPM: Int = 0
    private var tapTimes: [TimeInterval] = []

    private init() {
        fftSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)
    }

    func start() {
        guard !isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setPreferredSampleRate(Double(sampleRate))
            try session.setActive(true)
        } catch {
            print("AudioSession error: \(error)")
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Setup effect nodes
        let reverbNode = AVAudioUnitReverb()
        reverbNode.loadFactoryPreset(.mediumHall)
        reverbNode.wetDryMix = reverbWetDry

        let delayNode = AVAudioUnitDelay()
        delayNode.delayTime = TimeInterval(delayTime)
        delayNode.feedback = delayFeedback
        delayNode.wetDryMix = 50

        let timePitchNode = AVAudioUnitTimePitch()
        timePitchNode.pitch = pitchShiftSemitones * 100

        engine.attach(reverbNode)
        engine.attach(delayNode)
        engine.attach(timePitchNode)

        self.reverb = reverbNode
        self.delay = delayNode
        self.timePitch = timePitchNode
        self.audioEngine = engine

        // Install tap for analysis
        let tapFormat = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)
            ?? inputFormat

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: tapFormat) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))

            // Heavy DSP on background
            var rms: Float = 0
            vDSP_rmsqv(samples, 1, &rms, vDSP_Length(frameCount))
            let dbFS = 20 * log10(max(rms, 1e-10))
            let splApprox = max(0, dbFS + 90)
            let spectrumResult = AudioToolsEngine.computeSpectrum(samples: samples)
            let pitch = PitchDetector.detectPitch(samples: samples, sampleRate: 44100)

            DispatchQueue.main.async {
                self?.handleProcessedBuffer(
                    samples: samples, rms: rms, splApprox: splApprox,
                    spectrumResult: spectrumResult, pitch: pitch, frameCount: frameCount
                )
            }
        }

        do {
            try engine.start()
            isRunning = true
        } catch {
            print("AudioEngine start error: \(error)")
        }
    }

    func stop() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRunning = false
        reverb = nil
        delay = nil
        timePitch = nil
    }

    // MARK: - Effect Chain

    private func updateEffectChain() {
        guard let engine = audioEngine, engine.isRunning,
              let reverbNode = reverb, let delayNode = delay, let pitchNode = timePitch else { return }

        let mainMixer = engine.mainMixerNode
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Disconnect existing effect connections (not the tap)
        engine.disconnectNodeOutput(reverbNode)
        engine.disconnectNodeOutput(delayNode)
        engine.disconnectNodeOutput(pitchNode)

        if monitoringEnabled && (reverbEnabled || delayEnabled || pitchShiftEnabled) {
            // Build chain: input -> [effects] -> mainMixer
            var chain: [AVAudioNode] = [inputNode]
            if reverbEnabled { chain.append(reverbNode) }
            if delayEnabled { chain.append(delayNode) }
            if pitchShiftEnabled { chain.append(pitchNode) }
            chain.append(mainMixer)

            for i in 0..<chain.count - 1 {
                let from = chain[i]
                let to = chain[i + 1]
                if from !== inputNode {
                    engine.connect(from, to: to, format: inputFormat)
                }
            }
            mainMixer.outputVolume = 1.0
        } else {
            mainMixer.outputVolume = 0.0
        }
    }

    // MARK: - Buffer Processing (called on main actor)

    private func handleProcessedBuffer(
        samples: [Float], rms: Float, splApprox: Float,
        spectrumResult: SpectrumResult, pitch: Float?, frameCount: Int
    ) {
        currentRMS = rms
        splDB = splApprox
        if splApprox > peakDB { peakDB = splApprox }
        if rms > peakRMS { peakRMS = rms }

        // Update waveform ring buffer
        let drop = min(frameCount, waveformSamples.count)
        waveformSamples.removeFirst(drop)
        waveformSamples.append(contentsOf: samples.prefix(drop))

        // Spectrum
        spectrumBars = spectrumResult.bars
        peakFrequency = spectrumResult.peakFreq

        // Pitch / Tuner
        if let hz = pitch {
            detectedPitch = hz
            detectedNote = PitchDetector.hzToNoteName(hz)
            let midi = 69.0 + 12.0 * log2(Double(hz) / 440.0)
            let nearestMidi = round(midi)
            centsDeviation = Float((midi - nearestMidi) * 100)
        }

        // BPM onset detection (runs on main actor, can access properties)
        let onsetDetected = detectOnset(magnitudes: spectrumResult.magnitudes)
        if onsetDetected {
            let now = Date.timeIntervalSinceReferenceDate
            onsetTimes.append(now)
            onsetTimes = onsetTimes.filter { now - $0 < 10 }
            if onsetTimes.count >= 4 {
                let intervals = zip(onsetTimes.dropFirst(), onsetTimes).map { $0 - $1 }
                let filtered = intervals.filter { $0 > 0.25 && $0 < 2.0 }
                if !filtered.isEmpty {
                    let avgInterval = filtered.reduce(0, +) / Double(filtered.count)
                    bpm = Int(60.0 / avgInterval)
                }
            }
        }
    }

    // MARK: - FFT / Spectrum

    struct SpectrumResult {
        let bars: [Float]
        let peakFreq: Float
        let magnitudes: [Float]
    }

    static func computeSpectrum(samples: [Float]) -> SpectrumResult {
        let n = min(samples.count, 4096)
        guard n >= 512 else {
            return SpectrumResult(bars: Array(repeating: 0, count: 64), peakFreq: 0, magnitudes: [])
        }

        // Window
        var windowed = [Float](repeating: 0, count: n)
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

        // FFT using vDSP
        let halfN = n / 2
        var realIn = [Float](repeating: 0, count: halfN)
        var imagIn = [Float](repeating: 0, count: halfN)
        var realOut = [Float](repeating: 0, count: halfN)
        var imagOut = [Float](repeating: 0, count: halfN)

        // De-interleave
        for i in 0..<halfN {
            realIn[i] = windowed[2 * i]
            imagIn[i] = windowed[2 * i + 1]
        }

        guard let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD) else {
            return SpectrumResult(bars: Array(repeating: 0, count: 64), peakFreq: 0, magnitudes: [])
        }
        defer { vDSP_DFT_DestroySetup(setup) }

        vDSP_DFT_Execute(setup, realIn, imagIn, &realOut, &imagOut)

        // Magnitudes
        var magnitudes = [Float](repeating: 0, count: halfN)
        var splitComplex = DSPSplitComplex(realp: &realOut, imagp: &imagOut)
        vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfN))

        // Convert to dB
        var one: Float = 1e-10
        vDSP_vsadd(magnitudes, 1, &one, &magnitudes, 1, vDSP_Length(halfN))
        var dbMagnitudes = [Float](repeating: 0, count: halfN)
        var count = Int32(halfN)
        vvlog10f(&dbMagnitudes, magnitudes, &count)
        var twenty: Float = 20
        vDSP_vsmul(dbMagnitudes, 1, &twenty, &dbMagnitudes, 1, vDSP_Length(halfN))

        // Find peak frequency
        var peakMag: Float = 0
        var peakIdx: vDSP_Length = 0
        vDSP_maxvi(magnitudes, 1, &peakMag, &peakIdx, vDSP_Length(halfN))
        let freqResolution = 44100.0 / Float(n)
        let peakFreq = Float(peakIdx) * freqResolution

        // Map to 64 bars on log scale (20Hz - 20kHz)
        let barCount = 64
        var bars = [Float](repeating: 0, count: barCount)
        let logMin = log10(20.0)
        let logMax = log10(20000.0)

        let logRange = logMax - logMin
        for i in 0..<barCount {
            let ratioLow = Double(i) / Double(barCount)
            let ratioHigh = Double(i + 1) / Double(barCount)
            let logFreqLow = logMin + logRange * ratioLow
            let logFreqHigh = logMin + logRange * ratioHigh
            let freqLow = Float(pow(10, logFreqLow))
            let freqHigh = Float(pow(10, logFreqHigh))
            let binLow = max(1, Int(freqLow / freqResolution))
            let binHigh = min(halfN - 1, Int(freqHigh / freqResolution))

            if binLow <= binHigh && binLow < halfN {
                var maxVal: Float = -120
                for bin in binLow...binHigh {
                    if dbMagnitudes[bin] > maxVal { maxVal = dbMagnitudes[bin] }
                }
                // Normalize: -80dB..0dB -> 0..1
                bars[i] = max(0, min(1, (maxVal + 80) / 80))
            }
        }

        return SpectrumResult(bars: bars, peakFreq: peakFreq, magnitudes: magnitudes)
    }

    // MARK: - Onset Detection for BPM

    private func detectOnset(magnitudes: [Float]) -> Bool {
        guard !magnitudes.isEmpty else { return false }

        // Spectral flux
        var flux: Float = 0
        if !previousMagnitudes.isEmpty {
            let count = min(magnitudes.count, previousMagnitudes.count)
            for i in 0..<count {
                let diff = magnitudes[i] - previousMagnitudes[i]
                if diff > 0 { flux += diff }
            }
        }

        let isOnset = flux > previousSpectralFlux * 1.5 && flux > 1000

        previousMagnitudes = magnitudes
        previousSpectralFlux = flux

        return isOnset
    }

    // MARK: - Tap Tempo

    func tapTempo() {
        let now = Date.timeIntervalSinceReferenceDate
        tapTimes.append(now)
        tapTimes = tapTimes.filter { now - $0 < 5 }
        if tapTimes.count >= 2 {
            let intervals = zip(tapTimes.dropFirst(), tapTimes).map { $0 - $1 }
            let avg = intervals.reduce(0, +) / Double(intervals.count)
            if avg > 0 { tapTempoBPM = Int(60.0 / avg) }
        }
    }

    func resetPeak() {
        peakDB = splDB
        peakRMS = currentRMS
    }
}

// MARK: - AudioToolsView

struct AudioToolsView: View {
    @StateObject private var engine = AudioToolsEngine.shared

    @State private var expandedTools: Set<String> = ["spl", "spectrum", "tuner", "waveform", "effects", "bpm"]
    @State private var displayTimer: Timer?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Engine status
                    engineStatusBar

                    // Tool cards
                    splMeterCard
                    spectrumAnalyzerCard
                    tunerCard
                    waveformCard
                    audioEffectsCard
                    bpmDetectorCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Tools")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { engine.start() }
            .onDisappear { engine.stop() }
        }
    }

    // MARK: - Engine Status

    private var engineStatusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(engine.isRunning ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(engine.isRunning ? "マイク入力中" : "停止中")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if engine.isRunning {
                Button("停止") { engine.stop() }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            } else {
                Button("開始") { engine.start() }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Card Helper

    @ViewBuilder
    private func toolCard<Content: View>(
        _ id: String,
        title: String,
        icon: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    if expandedTools.contains(id) {
                        expandedTools.remove(id)
                    } else {
                        expandedTools.insert(id)
                    }
                }
            } label: {
                HStack {
                    Image(systemName: icon)
                        .foregroundStyle(color)
                        .frame(width: 24)
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Image(systemName: expandedTools.contains(id) ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if expandedTools.contains(id) {
                Divider()
                    .padding(.horizontal, 16)
                content()
                    .padding(16)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Tool 1: SPL Meter

    private var splMeterCard: some View {
        toolCard("spl", title: "音圧計 (SPL Meter)", icon: "speaker.wave.3.fill", color: .blue) {
            VStack(spacing: 12) {
                // Large dB display
                Text(String(format: "%.0f", engine.splDB))
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundStyle(splColor(engine.splDB))
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.15), value: Int(engine.splDB))

                Text("dB SPL")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                // Peak
                HStack {
                    Text("Peak:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f dB", engine.peakDB))
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Reset") { engine.resetPeak() }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }

                // Bar graph
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(.systemGray5))

                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                LinearGradient(
                                    colors: [.green, .yellow, .orange, .red],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(0, geo.size.width * CGFloat(min(1, engine.splDB / 120))))
                            .animation(.easeInOut(duration: 0.1), value: engine.splDB)

                        // Peak marker
                        Rectangle()
                            .fill(.red)
                            .frame(width: 2)
                            .offset(x: geo.size.width * CGFloat(min(1, engine.peakDB / 120)))
                    }
                }
                .frame(height: 24)

                // Scale labels
                HStack {
                    Text("0")
                    Spacer()
                    Text("40")
                    Spacer()
                    Text("60")
                    Spacer()
                    Text("80")
                    Spacer()
                    Text("120")
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

                // Reference
                Text("目安: 40dB=図書館, 60dB=会話, 80dB=電車, 100dB=ライブ")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func splColor(_ db: Float) -> Color {
        if db < 60 { return .green }
        if db < 80 { return .yellow }
        return .red
    }

    // MARK: - Tool 2: Spectrum Analyzer

    private var spectrumAnalyzerCard: some View {
        toolCard("spectrum", title: "スペクトラムアナライザ", icon: "waveform.path.ecg", color: .purple) {
            VStack(spacing: 8) {
                // Peak frequency
                HStack {
                    Text("Peak:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatFrequency(engine.peakFrequency))
                        .font(.caption.monospaced())
                    Spacer()
                    Text("20Hz — 20kHz")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Spectrum bars
                GeometryReader { geo in
                    HStack(alignment: .bottom, spacing: 1) {
                        ForEach(0..<64, id: \.self) { i in
                            let value = engine.spectrumBars[i]
                            RoundedRectangle(cornerRadius: 1)
                                .fill(spectrumColor(index: i))
                                .frame(height: max(2, geo.size.height * CGFloat(value)))
                                .animation(.easeOut(duration: 0.08), value: value)
                        }
                    }
                }
                .frame(height: 160)
                .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                .padding(.vertical, 4)

                // Frequency labels
                HStack {
                    Text("20Hz")
                    Spacer()
                    Text("200Hz")
                    Spacer()
                    Text("2kHz")
                    Spacer()
                    Text("20kHz")
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func spectrumColor(index: Int) -> Color {
        let ratio = Float(index) / 63.0
        if ratio < 0.33 { return .green }
        if ratio < 0.66 { return .orange }
        return .red
    }

    private func formatFrequency(_ hz: Float) -> String {
        if hz >= 1000 {
            return String(format: "%.1f kHz", hz / 1000)
        }
        return String(format: "%.0f Hz", hz)
    }

    // MARK: - Tool 3: Tuner

    private var tunerCard: some View {
        toolCard("tuner", title: "チューナー", icon: "tuningfork", color: .green) {
            VStack(spacing: 12) {
                // Note name
                Text(engine.detectedNote)
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(tunerColor)

                // Frequency
                Text(String(format: "%.1f Hz", engine.detectedPitch))
                    .font(.title3.monospaced())
                    .foregroundStyle(.secondary)

                // Cents deviation label
                Text(String(format: "%+.0f cents", engine.centsDeviation))
                    .font(.caption.monospaced())
                    .foregroundStyle(tunerColor)

                // Needle indicator
                GeometryReader { geo in
                    let center = geo.size.width / 2
                    let needleOffset = CGFloat(engine.centsDeviation / 50) * (center - 20)

                    ZStack {
                        // Background scale
                        HStack {
                            Text("-50").font(.system(size: 8))
                            Spacer()
                            Text("0").font(.system(size: 8)).foregroundStyle(.green)
                            Spacer()
                            Text("+50").font(.system(size: 8))
                        }
                        .foregroundStyle(.secondary)

                        // Scale marks
                        ForEach(-5..<6, id: \.self) { mark in
                            let x = center + CGFloat(mark) * (center - 20) / 5
                            Rectangle()
                                .fill(mark == 0 ? Color.green : Color(.systemGray4))
                                .frame(width: mark == 0 ? 2 : 1, height: mark == 0 ? 20 : 12)
                                .position(x: x, y: 25)
                        }

                        // In-tune zone
                        Rectangle()
                            .fill(Color.green.opacity(0.15))
                            .frame(width: CGFloat(5.0 / 50.0) * (center - 20) * 2, height: 30)
                            .position(x: center, y: 25)

                        // Needle
                        VStack(spacing: 0) {
                            Triangle()
                                .fill(tunerColor)
                                .frame(width: 12, height: 10)
                            Rectangle()
                                .fill(tunerColor)
                                .frame(width: 2, height: 20)
                        }
                        .position(x: center + needleOffset, y: 25)
                        .animation(.easeInOut(duration: 0.15), value: engine.centsDeviation)
                    }
                }
                .frame(height: 50)
            }
        }
    }

    private var tunerColor: Color {
        abs(engine.centsDeviation) <= 5 ? .green : (abs(engine.centsDeviation) <= 20 ? .yellow : .red)
    }

    // MARK: - Tool 4: Waveform

    private var waveformCard: some View {
        toolCard("waveform", title: "波形表示", icon: "waveform", color: .cyan) {
            VStack(spacing: 4) {
                // Waveform canvas — show last ~2 seconds
                Canvas { ctx, size in
                    let samples = engine.waveformSamples
                    let count = samples.count
                    let step = max(1, count / Int(size.width))
                    let midY = size.height / 2

                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: midY))

                    for x in 0..<Int(size.width) {
                        let sampleIdx = min(x * step, count - 1)
                        let val = CGFloat(samples[sampleIdx])
                        let y = midY - val * midY * 0.9
                        path.addLine(to: CGPoint(x: CGFloat(x), y: y))
                    }

                    ctx.stroke(path, with: .color(.green), lineWidth: 1)

                    // Center line
                    var centerLine = Path()
                    centerLine.move(to: CGPoint(x: 0, y: midY))
                    centerLine.addLine(to: CGPoint(x: size.width, y: midY))
                    ctx.stroke(centerLine, with: .color(.green.opacity(0.3)), lineWidth: 0.5)
                }
                .frame(height: 160)
                .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))

                HStack {
                    Text("~2 sec")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("リアルタイム")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Tool 5: Audio Effects

    private var audioEffectsCard: some View {
        toolCard("effects", title: "エフェクト", icon: "guitars.fill", color: .orange) {
            VStack(spacing: 16) {
                // Monitor toggle
                Toggle(isOn: $engine.monitoringEnabled) {
                    Label("モニタリング (スピーカー出力)", systemImage: "speaker.wave.2")
                        .font(.subheadline)
                }
                .tint(.orange)

                Divider()

                // Reverb
                VStack(spacing: 8) {
                    Toggle(isOn: $engine.reverbEnabled) {
                        Label("Reverb", systemImage: "waveform.path")
                            .font(.subheadline.bold())
                    }
                    .tint(.blue)

                    if engine.reverbEnabled {
                        HStack {
                            Text("Wet/Dry")
                                .font(.caption)
                                .frame(width: 60, alignment: .leading)
                            Slider(value: $engine.reverbWetDry, in: 0...100)
                            Text(String(format: "%.0f%%", engine.reverbWetDry))
                                .font(.caption.monospaced())
                                .frame(width: 40)
                        }
                    }
                }

                Divider()

                // Delay
                VStack(spacing: 8) {
                    Toggle(isOn: $engine.delayEnabled) {
                        Label("Delay", systemImage: "repeat")
                            .font(.subheadline.bold())
                    }
                    .tint(.purple)

                    if engine.delayEnabled {
                        HStack {
                            Text("Time")
                                .font(.caption)
                                .frame(width: 60, alignment: .leading)
                            Slider(value: $engine.delayTime, in: 0.01...2.0)
                            Text(String(format: "%.2fs", engine.delayTime))
                                .font(.caption.monospaced())
                                .frame(width: 50)
                        }
                        HStack {
                            Text("Feedback")
                                .font(.caption)
                                .frame(width: 60, alignment: .leading)
                            Slider(value: $engine.delayFeedback, in: 0...95)
                            Text(String(format: "%.0f%%", engine.delayFeedback))
                                .font(.caption.monospaced())
                                .frame(width: 50)
                        }
                    }
                }

                Divider()

                // Pitch Shift
                VStack(spacing: 8) {
                    Toggle(isOn: $engine.pitchShiftEnabled) {
                        Label("Pitch Shift", systemImage: "arrow.up.arrow.down")
                            .font(.subheadline.bold())
                    }
                    .tint(.green)

                    if engine.pitchShiftEnabled {
                        HStack {
                            Text("Semitones")
                                .font(.caption)
                                .frame(width: 70, alignment: .leading)
                            Slider(value: $engine.pitchShiftSemitones, in: -12...12, step: 1)
                            Text(String(format: "%+.0f", engine.pitchShiftSemitones))
                                .font(.caption.monospaced())
                                .frame(width: 30)
                        }
                    }
                }

                if !engine.monitoringEnabled && (engine.reverbEnabled || engine.delayEnabled || engine.pitchShiftEnabled) {
                    Text("モニタリングをONにするとスピーカーからエフェクト音が出ます")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    // MARK: - Tool 6: BPM Detector

    private var bpmDetectorCard: some View {
        toolCard("bpm", title: "テンポ検出 (BPM)", icon: "metronome.fill", color: .red) {
            VStack(spacing: 12) {
                // BPM display
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    let displayBPM = engine.tapTempoBPM > 0 ? engine.tapTempoBPM : engine.bpm
                    Text("\(displayBPM)")
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .foregroundStyle(displayBPM > 0 ? .primary : .secondary)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.2), value: displayBPM)
                    Text("BPM")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                // Sources
                HStack(spacing: 20) {
                    VStack {
                        Text("自動検出")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(engine.bpm)")
                            .font(.caption.monospaced().bold())
                    }
                    VStack {
                        Text("タップ")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(engine.tapTempoBPM)")
                            .font(.caption.monospaced().bold())
                    }
                }

                // Beat flash indicator
                HStack(spacing: 8) {
                    ForEach(0..<4, id: \.self) { i in
                        Circle()
                            .fill(beatActive(i) ? Color.red : Color(.systemGray5))
                            .frame(width: 16, height: 16)
                            .animation(.easeOut(duration: 0.1), value: engine.bpm)
                    }
                }

                // Tap tempo button
                Button {
                    engine.tapTempo()
                } label: {
                    Text("TAP")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.red, in: RoundedRectangle(cornerRadius: 12))
                }
                .sensoryFeedback(.impact(weight: .medium), trigger: engine.tapTempoBPM)

                Text("リズムに合わせてタップ (4回以上)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func beatActive(_ index: Int) -> Bool {
        let bpm = engine.tapTempoBPM > 0 ? engine.tapTempoBPM : engine.bpm
        guard bpm > 0 else { return false }
        let beatInterval = 60.0 / Double(bpm)
        let now = Date.timeIntervalSinceReferenceDate
        let phase = now.truncatingRemainder(dividingBy: beatInterval * 4)
        let currentBeat = Int(phase / beatInterval)
        return currentBeat == index
    }
}

// MARK: - Triangle Shape

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Preview

#Preview {
    AudioToolsView()
}
