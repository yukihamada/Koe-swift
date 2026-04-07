import Foundation
import AVFoundation
import Accelerate
#if os(iOS)
import UIKit
#endif

/// Soluna Audio Player — Uses the proven C++ AudioReceiverBridge (same as standalone Soluna app).
@MainActor
final class SolunaManager: ObservableObject {
    static let shared = SolunaManager()

    // MARK: - Published State

    @Published var isActive = false
    @Published var peerCount = 0
    @Published var channel = "soluna"
    @Published var relayConnected = false
    @Published var isReceivingAudio = false
    @Published var isMicMonitoring = false

    // LED sync state
    @Published var ledR: UInt8 = 0
    @Published var ledG: UInt8 = 0
    @Published var ledB: UInt8 = 0
    @Published var ledPattern: UInt8 = 0
    @Published var ledSpeed: UInt8 = 128
    @Published var ledIntensity: UInt8 = 200

    // Fan rank tracking
    @Published var listenMinutes: Double = 0
    @Published var fanRankBadge: String = "🌱"

    // Debug stats
    @Published var debugInfo: String = ""

    // C++ audio receiver (same as standalone Soluna app)
    private var receiver: SolunaAudioReceiver?
    private var statusTimer: Timer?
    private var listenTimer: Timer?
    private var micEngine: AVAudioEngine?
    @Published var micLevel: Float = 0

    private var deviceName: String

    static let sdkVersion = "1.1.0"

    // MARK: - Channel Definitions

    struct ChannelDef: Identifiable, Hashable {
        let id: String
        let name: String
        let emoji: String
        let colorHex: String
    }

    static let radioChannels: [ChannelDef] = [
        ChannelDef(id: "bjj",    name: "BJJ",    emoji: "🥋", colorHex: "#E53E3E"),
        ChannelDef(id: "soluna", name: "Soluna",  emoji: "🌀", colorHex: "#ED8936"),
        ChannelDef(id: "jazz",   name: "Jazz",    emoji: "🎷", colorHex: "#D69E2E"),
        ChannelDef(id: "chill",  name: "Chill",   emoji: "🌅", colorHex: "#38B2AC"),
        ChannelDef(id: "lofi",   name: "Lo-Fi",   emoji: "📻", colorHex: "#805AD5"),
        ChannelDef(id: "dance",  name: "Dance",   emoji: "💃", colorHex: "#D53F8C"),
        ChannelDef(id: "yuki",   name: "Yuki",    emoji: "❄️",  colorHex: "#63B3ED"),
    ]

    private init() {
        #if os(iOS)
        deviceName = UIDevice.current.name
        #else
        deviceName = Host.current().localizedName ?? "Koe"
        #endif
    }

    // MARK: - Start / Stop

    func start(channel: String = "soluna") {
        guard !isActive else { return }
        self.channel = channel
        isActive = true

        #if os(iOS)
        // Configure audio session for playback
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.defaultToSpeaker])
            try session.setPreferredSampleRate(48000)
            try session.setActive(true)
            NSLog("[Soluna] Session rate=%.0f", session.sampleRate)
        } catch {
            NSLog("[Soluna] AudioSession error: %@", error.localizedDescription)
        }
        #endif

        // Create C++ receiver (same as standalone Soluna app)
        let rx = SolunaAudioReceiver(multicastGroup: "239.42.42.1", port: 4242, channels: 2)
        rx.volume = 1.0
        rx.networkDisabled = true  // relay only, skip multicast
        receiver = rx

        // Start audio output
        rx.start()

        // Connect to WAN relay
        rx.connect(toRelay: "relay.solun.art", port: 5100,
                   group: channel, password: "", deviceId: deviceName)
        relayConnected = true

        // Poll status
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let rx = self.receiver else { return }
                let state = rx.state
                let peak = rx.outputPeakLevel
                self.isReceivingAudio = state == .receiving && peak > 0.001
                self.debugInfo = "state:\(state.rawValue) peak:\(String(format:"%.3f",peak))"
            }
        }

        startListenTimer()
        NSLog("[Soluna] Started with C++ bridge, channel=%@", channel)
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        isReceivingAudio = false

        statusTimer?.invalidate()
        statusTimer = nil
        stopListenTimer()

        receiver?.stop()
        receiver = nil
        relayConnected = false

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    func setChannel(_ name: String) {
        let wasActive = isActive
        if wasActive { stop() }
        channel = name
        if wasActive { start(channel: name) }
    }

    // MARK: - Mic Monitoring (Karaoke Mode)

    func toggleMicMonitoring() {
        isMicMonitoring ? stopMicMonitoring() : startMicMonitoring()
    }

    private func startMicMonitoring() {
        let engine = AVAudioEngine()
        let input  = engine.inputNode
        let fmt    = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            guard let ch = buf.floatChannelData?[0] else { return }
            var rms: Float = 0
            vDSP_rmsqv(ch, 1, &rms, vDSP_Length(buf.frameLength))
            Task { @MainActor [weak self] in self?.micLevel = min(rms * 5, 1.0) }
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
            try AVAudioSession.sharedInstance().setActive(true)
            engine.prepare()
            try engine.start()
            micEngine = engine
            isMicMonitoring = true
        } catch {
            print("SolunaManager: mic start error \(error)")
        }
    }

    private func stopMicMonitoring() {
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
        micLevel = 0
        isMicMonitoring = false
    }

    // MARK: - Listen Timer & Fan Rank

    private func startListenTimer() {
        listenTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.listenMinutes += 1
                self.updateFanRank()
            }
        }
    }

    private func stopListenTimer() {
        listenTimer?.invalidate()
        listenTimer = nil
    }

    private func updateFanRank() {
        switch listenMinutes {
        case ..<30:   fanRankBadge = "🌱"
        case ..<120:  fanRankBadge = "⭐"
        case ..<600:  fanRankBadge = "🔥"
        default:      fanRankBadge = "👑"
        }
    }
}
