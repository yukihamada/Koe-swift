import Foundation
import Network
import AVFoundation
import Accelerate
import Combine

/// Soluna P2P Audio Mesh — iPhoneをCOINデバイスとして動作させる
///
/// プロトコル: OSTP (OpenSonic Transport Protocol) — RTPベース
/// マルチキャスト: 239.69.0.1:5004 (音声) / 239.42.42.1:4243 (LED)
/// 互換: OpenSonicデバイス、Koe ESP32デバイス
@MainActor
final class SolunaManager: ObservableObject {
    static let shared = SolunaManager()

    // Public state
    @Published var isActive = false
    @Published var peerCount = 0
    @Published var channel = "default"
    @Published var ledR: UInt8 = 0
    @Published var ledG: UInt8 = 0
    @Published var ledB: UInt8 = 0
    @Published var ledPattern: UInt8 = 0  // 0=off,1=solid,2=pulse,3=rainbow...
    @Published var ledSpeed: UInt8 = 128
    @Published var ledIntensity: UInt8 = 200
    @Published var isReceivingAudio = false

    // Network
    private var audioConnection: NWConnection?
    private var audioListener: NWConnectionGroup?
    private var ledListener: NWConnectionGroup?

    // Audio
    private var audioEngine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private let audioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true)!
    private let captureFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    // Jitter buffer
    private let jitterLock = NSLock()
    private var jitterBuffer: [[UInt8]] = []
    private let maxJitterSlots = 8

    // Sequence tracking
    private var txSequence: UInt16 = 0
    private var txSSRC: UInt32
    private var knownSSRCs: Set<UInt32> = []
    private var peerLastSeen: [UInt32: Date] = [:]

    // Multicast addresses
    private let audioMulticast = "239.69.0.1"
    private let audioPort: UInt16 = 5004
    private let ledMulticast = "239.42.42.1"
    private let ledPort: UInt16 = 4243

    private init() {
        txSSRC = UInt32.random(in: 1...UInt32.max)
    }

    // MARK: - Start / Stop

    func start(channel: String = "default") {
        guard !isActive else { return }
        self.channel = channel
        isActive = true

        configureAudioSession()
        startAudioEngine()
        startReceiving()
        startLEDReceiver()

        // Peer cleanup timer
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.cleanupPeers() }
        }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        isReceivingAudio = false

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        playerNode.stop()

        audioConnection?.cancel()
        audioListener?.cancel()
        ledListener?.cancel()
        audioConnection = nil
        audioListener = nil
        ledListener = nil

        jitterLock.lock()
        jitterBuffer.removeAll()
        jitterLock.unlock()

        knownSSRCs.removeAll()
        peerLastSeen.removeAll()
        peerCount = 0

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func setChannel(_ name: String) {
        let wasActive = isActive
        if wasActive { stop() }
        channel = name
        if wasActive { start(channel: name) }
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setPreferredIOBufferDuration(0.005)  // 5ms
            try session.setActive(true)
        } catch {
            print("[Soluna] Audio session error: \(error)")
        }
    }

    // MARK: - Audio Engine (Capture + Playback)

    private func startAudioEngine() {
        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: audioFormat)

        // Mic capture → send
        guard let converter = AVAudioConverter(from: hwFormat, to: captureFormat) else {
            print("[Soluna] Cannot create audio converter")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            guard let self, self.isActive else { return }

            // Resample to 16kHz mono
            let ratio = 16000.0 / hwFormat.sampleRate
            let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: self.captureFormat, frameCapacity: outFrames) else { return }

            converter.convert(to: outBuf, error: nil) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            // Float32 → Int16
            guard let floatData = outBuf.floatChannelData?[0] else { return }
            let count = Int(outBuf.frameLength)
            var pcmBytes = [UInt8](repeating: 0, count: count * 2)
            for i in 0..<count {
                let sample = Int16(max(-32768, min(32767, floatData[i] * 32767)))
                pcmBytes[i * 2] = UInt8(sample & 0xFF)
                pcmBytes[i * 2 + 1] = UInt8((sample >> 8) & 0xFF)
            }

            self.sendAudioPacket(pcmBytes)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("[Soluna] Engine start error: \(error)")
        }
    }

    // MARK: - Send Audio (Simple Soluna Protocol for ESP32 compat)

    private func sendAudioPacket(_ pcm: [UInt8]) {
        guard pcm.count <= 1024 else { return }

        // SL header (14 bytes) — compatible with Koe ESP32 firmware
        var packet = [UInt8]()
        packet.append(0x53)  // 'S'
        packet.append(0x4C)  // 'L'
        let seq = txSequence
        txSequence &+= 1
        packet.append(contentsOf: withUnsafeBytes(of: UInt32(seq).littleEndian) { Array($0) })
        let chHash = fnv1a(channel)
        packet.append(contentsOf: withUnsafeBytes(of: chHash.littleEndian) { Array($0) })
        let ts = UInt32(Date().timeIntervalSince1970 * 1000) & 0xFFFFFFFF
        packet.append(contentsOf: withUnsafeBytes(of: ts.littleEndian) { Array($0) })
        packet.append(contentsOf: pcm)

        let data = Data(packet)

        // Send to both multicast groups (OSTP and simple SL)
        if audioConnection == nil {
            let host = NWEndpoint.Host(audioMulticast)
            let port = NWEndpoint.Port(integerLiteral: 4242)  // SL protocol port
            audioConnection = NWConnection(host: host, port: port, using: .udp)
            audioConnection?.start(queue: .global(qos: .userInteractive))
        }
        audioConnection?.send(content: data, completion: .contentProcessed({ _ in }))
    }

    // MARK: - Receive Audio

    private func startReceiving() {
        guard let multicast = try? NWMulticastGroup(for: [
            .hostPort(host: NWEndpoint.Host(audioMulticast), port: NWEndpoint.Port(integerLiteral: 4242))
        ]) else { return }

        guard let group = try? NWConnectionGroup(with: multicast, using: .udp) else {
            print("[Soluna] Failed to create audio multicast group")
            return
        }

        group.setReceiveHandler(maximumMessageSize: 2048, rejectOversizedMessages: true) { [weak self] message, content, isComplete in
            guard let self, let data = content, data.count > 14 else { return }

            // Parse SL header
            guard data[0] == 0x53, data[1] == 0x4C else { return }

            let chHash = data.subdata(in: 6..<10).withUnsafeBytes { $0.load(as: UInt32.self) }
            let expectedHash = self.fnv1a(self.channel)
            guard chHash == expectedHash else { return }

            let audio = Array(data[14...])
            guard !audio.isEmpty else { return }

            self.jitterLock.lock()
            if self.jitterBuffer.count >= self.maxJitterSlots {
                self.jitterBuffer.removeFirst()
            }
            self.jitterBuffer.append(audio)
            self.jitterLock.unlock()

            Task { @MainActor in
                self.isReceivingAudio = true
            }

            self.playFromJitter()
        }

        group.start(queue: .global(qos: .userInteractive))
        audioListener = group
    }

    private func playFromJitter() {
        jitterLock.lock()
        guard jitterBuffer.count >= 2 else { jitterLock.unlock(); return }
        let chunk = jitterBuffer.removeFirst()
        jitterLock.unlock()

        // Int16 bytes → AVAudioPCMBuffer
        let sampleCount = chunk.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(sampleCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        if let channelData = buffer.int16ChannelData?[0] {
            for i in 0..<sampleCount {
                channelData[i] = Int16(chunk[i * 2]) | (Int16(chunk[i * 2 + 1]) << 8)
            }
        }

        if !playerNode.isPlaying {
            playerNode.play()
        }
        playerNode.scheduleBuffer(buffer)
    }

    // MARK: - LED Receiver

    private func startLEDReceiver() {
        guard let multicast = try? NWMulticastGroup(for: [
            .hostPort(host: NWEndpoint.Host(ledMulticast), port: NWEndpoint.Port(integerLiteral: ledPort))
        ]) else { return }

        guard let group = try? NWConnectionGroup(with: multicast, using: .udp) else {
            print("[Soluna] LED multicast error")
            return
        }

        group.setReceiveHandler(maximumMessageSize: 64, rejectOversizedMessages: true) { [weak self] message, content, isComplete in
            guard let self, let data = content, data.count >= 12 else { return }
            guard data[0] == 0x4C, data[1] == 0x45 else { return }  // "LE"

            let pattern = data[6]
            let r = data[7]
            let g = data[8]
            let b = data[9]
            let speed = data[10]
            let intensity = data[11]

            Task { @MainActor in
                self.ledPattern = pattern
                self.ledR = r
                self.ledG = g
                self.ledB = b
                self.ledSpeed = speed
                self.ledIntensity = intensity
            }
        }

        group.start(queue: .global(qos: .userInteractive))
        ledListener = group
    }

    // MARK: - Peer Management

    private func cleanupPeers() {
        let now = Date()
        peerLastSeen = peerLastSeen.filter { now.timeIntervalSince($0.value) < 30 }
        peerCount = peerLastSeen.count
    }

    // MARK: - Utility

    private func fnv1a(_ str: String) -> UInt32 {
        var h: UInt32 = 0x811c9dc5
        for byte in str.utf8 {
            h ^= UInt32(byte)
            h = h &* 0x01000193
        }
        return h
    }
}
