import Foundation
import Network
import AVFoundation
import Accelerate
import Combine
#if os(iOS)
import UIKit
#endif

/// Soluna P2P Audio Mesh — iPhoneをCOINデバイスとして動作させる
///
/// プロトコル: SL (Soluna Protocol) — ESP32完全互換
/// パケット: [magic 2B][device_hash 4B][seq 4B][channel_hash 4B][ntp_ms 4B][flags 1B][audio ADPCM]
/// ヘッダ: 19 bytes
/// 圧縮: IMA-ADPCM 4:1 (16bit PCM → 4bit)
/// マルチキャスト: 239.42.42.1:4242 (音声) / 239.42.42.1:4243 (LED)
@MainActor
final class SolunaManager: ObservableObject {
    static let shared = SolunaManager()

    // Public state
    @Published var isActive = false
    @Published var peerCount = 0
    @Published var channel = "soluna"
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
    private let audioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let captureFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    // Jitter buffer
    private let jitterLock = NSLock()
    private var jitterBuffer: [[UInt8]] = []
    private let maxJitterSlots = 8

    // Protocol constants (must match ESP32)
    private let headerSize = 19
    private let maxAudioPerPacket = 512  // ADPCM bytes = 1024 PCM samples

    // Flags (must match ESP32)
    private let FLAG_ADPCM: UInt8     = 0x01
    private let FLAG_ENCRYPTED: UInt8 = 0x02
    private let FLAG_HEARTBEAT: UInt8 = 0x04
    private let FLAG_CHIRP: UInt8     = 0x08
    private let FLAG_GOSSIP: UInt8    = 0x10

    // Sequence tracking
    private var txSequence: UInt32 = 0
    private var deviceHash: UInt32
    private var knownPeers: [UInt32: Date] = [:]

    // ADPCM state
    private var encodeState = ADPCMState()
    private var decodeStates: [UInt32: ADPCMState] = [:]
    private let decodeLock = NSLock()
    private let peerLock = NSLock()

    // Multicast addresses (must match ESP32)
    private let multicastAddr = "239.42.42.1"
    private let audioPort: UInt16 = 4242
    private let ledPort: UInt16 = 4243

    // Timers
    private var heartbeatTimer: Timer?
    private var peerCleanupTimer: Timer?

    private init() {
        #if os(iOS)
        let deviceID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #else
        let deviceID = Host.current().localizedName ?? UUID().uuidString
        #endif
        deviceHash = SolunaManager.fnv1aHash(Array(deviceID.utf8))
    }

    // MARK: - Start / Stop

    func start(channel: String = "default") {
        guard !isActive else { return }
        self.channel = channel
        isActive = true

        // Reset ADPCM states on start
        encodeState = ADPCMState()
        decodeStates.removeAll()

        configureAudioSession()
        startAudioEngine()
        startReceiving()
        startLEDReceiver()
        startHeartbeat()

        // Peer cleanup timer
        peerCleanupTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
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

        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        peerCleanupTimer?.invalidate()
        peerCleanupTimer = nil

        jitterLock.lock()
        jitterBuffer.removeAll()
        jitterLock.unlock()

        knownPeers.removeAll()
        decodeStates.removeAll()
        peerCount = 0

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

    // MARK: - Audio Session

    private func configureAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setPreferredIOBufferDuration(0.005)  // 5ms
            try session.setPreferredSampleRate(16000)
            try session.setActive(true)
        } catch {
            print("[Soluna] Audio session error: \(error)")
        }
        #endif
    }

    // MARK: - Audio Engine (Capture + Playback)

    private func startAudioEngine() {
        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: audioFormat)

        // Mic capture -> resample to 16kHz -> ADPCM encode -> send
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

            // Float32 -> Int16 PCM bytes (little-endian)
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

    // MARK: - Send Audio (19-byte SL header + ADPCM, ESP32 compatible)

    private func sendAudioPacket(_ pcm: [UInt8]) {
        // ADPCM encode: PCM -> 4:1 compression
        let adpcm = ADPCMCodec.encode(pcm: pcm, state: &encodeState)
        guard !adpcm.isEmpty else { return }

        // Build 19-byte header
        var packet = [UInt8]()
        packet.reserveCapacity(headerSize + adpcm.count)

        // [0-1] Magic: "SL"
        packet.append(0x53)
        packet.append(0x4C)

        // [2-5] Device hash (u32 LE)
        packet.append(contentsOf: withUnsafeBytes(of: deviceHash.littleEndian) { Array($0) })

        // [6-9] Sequence (u32 LE)
        let seq = txSequence
        txSequence &+= 1
        packet.append(contentsOf: withUnsafeBytes(of: seq.littleEndian) { Array($0) })

        // [10-13] Channel hash (u32 LE)
        let chHash = SolunaManager.fnv1aHash(Array(channel.utf8))
        packet.append(contentsOf: withUnsafeBytes(of: chHash.littleEndian) { Array($0) })

        // [14-17] NTP timestamp ms (u32 LE)
        let ts = ntpNowMs()
        packet.append(contentsOf: withUnsafeBytes(of: ts.littleEndian) { Array($0) })

        // [18] Flags
        packet.append(FLAG_ADPCM)

        // Audio payload (ADPCM compressed)
        packet.append(contentsOf: adpcm)

        let data = Data(packet)

        if audioConnection == nil {
            let host = NWEndpoint.Host(multicastAddr)
            let port = NWEndpoint.Port(integerLiteral: audioPort)
            audioConnection = NWConnection(host: host, port: port, using: .udp)
            audioConnection?.start(queue: .global(qos: .userInteractive))
        }
        audioConnection?.send(content: data, completion: .contentProcessed({ _ in }))
    }

    // MARK: - Heartbeat (every 5 seconds, FLAG_HEARTBEAT)

    private func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self, self.isActive else { return }
            self.sendHeartbeat()
        }
        // Send initial heartbeat immediately
        sendHeartbeat()
    }

    private func sendHeartbeat() {
        let myHash = deviceHash
        let chHash = SolunaManager.fnv1aHash(Array(channel.utf8))
        let ts = ntpNowMs()

        var packet = [UInt8]()
        packet.reserveCapacity(19)
        packet.append(0x53); packet.append(0x4C)
        packet.append(contentsOf: withUnsafeBytes(of: myHash.littleEndian) { Array($0) })
        packet.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) })
        packet.append(contentsOf: withUnsafeBytes(of: chHash.littleEndian) { Array($0) })
        packet.append(contentsOf: withUnsafeBytes(of: ts.littleEndian) { Array($0) })
        packet.append(FLAG_HEARTBEAT)

        audioConnection?.send(content: Data(packet), completion: .contentProcessed({ _ in }))
    }

    // MARK: - Receive Audio

    private func startReceiving() {
        guard let multicast = try? NWMulticastGroup(for: [
            .hostPort(host: NWEndpoint.Host(multicastAddr), port: NWEndpoint.Port(integerLiteral: audioPort))
        ]) else { return }

        guard let group = try? NWConnectionGroup(with: multicast, using: .udp) else {
            print("[Soluna] Failed to create audio multicast group")
            return
        }

        // Capture MainActor values for use in receive handler
        let myDeviceHash = self.deviceHash
        let myChannelHash = SolunaManager.fnv1aHash(Array(self.channel.utf8))
        let hdrSize = self.headerSize
        let flagADPCM = self.FLAG_ADPCM
        let flagHB = self.FLAG_HEARTBEAT
        let flagChirp = self.FLAG_CHIRP
        let maxSlots = self.maxJitterSlots

        group.setReceiveHandler(maximumMessageSize: 2048, rejectOversizedMessages: true) { [weak self] message, content, isComplete in
            guard let self, let data = content, data.count >= hdrSize else { return }

            guard data[0] == 0x53, data[1] == 0x4C else { return }

            let senderHash = data.subdata(in: 2..<6).withUnsafeBytes { $0.load(as: UInt32.self) }
            let chHash = data.subdata(in: 10..<14).withUnsafeBytes { $0.load(as: UInt32.self) }
            let flags = data[18]

            guard senderHash != myDeviceHash else { return }
            guard chHash == myChannelHash else { return }

            let now = Date()
            self.peerLock.lock()
            self.knownPeers[senderHash] = now
            let count = self.knownPeers.count
            self.peerLock.unlock()

            Task { @MainActor in
                self.peerCount = count
            }

            if flags & flagHB != 0 { return }
            if flags & flagChirp != 0 { return }

            let audioData = Array(data[hdrSize...])
            guard !audioData.isEmpty else { return }

            var pcmBytes: [UInt8]
            self.decodeLock.lock()
            if flags & flagADPCM != 0 {
                var state = self.decodeStates[senderHash] ?? ADPCMState()
                pcmBytes = ADPCMCodec.decode(adpcm: audioData, state: &state)
                self.decodeStates[senderHash] = state
            } else {
                pcmBytes = audioData
            }
            self.decodeLock.unlock()

            guard !pcmBytes.isEmpty else { return }

            self.jitterLock.lock()
            if self.jitterBuffer.count >= maxSlots {
                self.jitterBuffer.removeFirst()
            }
            self.jitterBuffer.append(pcmBytes)
            self.jitterLock.unlock()

            Task { @MainActor in
                self.isReceivingAudio = true
                self.playFromJitter()
            }
        }

        group.start(queue: .global(qos: .userInteractive))
        audioListener = group
    }

    private func playFromJitter() {
        jitterLock.lock()
        guard jitterBuffer.count >= 2 else { jitterLock.unlock(); return }
        let chunk = jitterBuffer.removeFirst()
        jitterLock.unlock()

        let sampleCount = chunk.count / 2
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(sampleCount))
        else { return }
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
            .hostPort(host: NWEndpoint.Host(multicastAddr), port: NWEndpoint.Port(integerLiteral: ledPort))
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
        knownPeers = knownPeers.filter { now.timeIntervalSince($0.value) < 10 }
        peerCount = knownPeers.count
        // Clean up decode states for expired peers
        let activeHashes = Set(knownPeers.keys)
        decodeStates = decodeStates.filter { activeHashes.contains($0.key) }
    }

    // MARK: - NTP Timestamp

    /// NTP-compatible timestamp in milliseconds (u32, wraps)
    /// iOS syncs time via NTP automatically, so Date() is already NTP-aligned
    private func ntpNowMs() -> UInt32 {
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        return UInt32(ms & 0xFFFFFFFF)
    }

    // MARK: - FNV-1a Hash (must match ESP32)

    static func fnv1aHash(_ data: [UInt8]) -> UInt32 {
        var h: UInt32 = 0x811c9dc5
        for byte in data {
            h ^= UInt32(byte)
            h = h &* 0x01000193
        }
        return h
    }

    /// Convenience for string hashing
    private func fnv1a(_ str: String) -> UInt32 {
        SolunaManager.fnv1aHash(Array(str.utf8))
    }
}

// MARK: - IMA-ADPCM Codec (matches ESP32 implementation exactly)

struct ADPCMState {
    var predicted: Int16 = 0
    var stepIndex: UInt8 = 0
}

enum ADPCMCodec {
    // Step size table (89 entries)
    static let stepTable: [Int16] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
        34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
        157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544,
        598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707,
        1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871,
        5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635,
        13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
    ]

    // Index adjustment table (16 entries)
    static let indexTable: [Int8] = [
        -1, -1, -1, -1, 2, 4, 6, 8,
        -1, -1, -1, -1, 2, 4, 6, 8,
    ]

    /// Encode PCM (little-endian Int16 bytes) to IMA-ADPCM (4:1 compression)
    /// Input: PCM byte array (2 bytes per sample, little-endian)
    /// Output: ADPCM byte array (2 samples per byte, low nibble first)
    static func encode(pcm: [UInt8], state: inout ADPCMState) -> [UInt8] {
        let nSamples = pcm.count / 2
        guard nSamples > 0 else { return [] }
        let outLen = (nSamples + 1) / 2
        var out = [UInt8](repeating: 0, count: outLen)

        var outIdx = 0
        var nibbleHi = false

        var i = 0
        while i + 1 < pcm.count {
            let sample = Int16(bitPattern: UInt16(pcm[i]) | (UInt16(pcm[i + 1]) << 8))
            let step = Int32(stepTable[Int(state.stepIndex)])

            var diff = Int32(sample) - Int32(state.predicted)
            var code: UInt8 = 0
            if diff < 0 {
                code = 8
                diff = -diff
            }

            if diff >= step { code |= 4; diff -= step }
            if diff >= step >> 1 { code |= 2; diff -= step >> 1 }
            if diff >= step >> 2 { code |= 1 }

            // Decode within encoder to track prediction (matches ESP32)
            var delta = step >> 3
            if code & 4 != 0 { delta += step }
            if code & 2 != 0 { delta += step >> 1 }
            if code & 1 != 0 { delta += step >> 2 }
            if code & 8 != 0 { delta = -delta }

            let newPredicted = max(-32768, min(32767, Int32(state.predicted) + delta))
            state.predicted = Int16(newPredicted)

            let newIdx = max(0, min(88, Int8(state.stepIndex) + indexTable[Int(code)]))
            state.stepIndex = UInt8(newIdx)

            if nibbleHi {
                out[outIdx] |= code << 4
                outIdx += 1
            } else {
                out[outIdx] = code & 0x0F
            }
            nibbleHi = !nibbleHi

            i += 2
        }

        return out
    }

    /// Decode IMA-ADPCM to PCM (little-endian Int16 bytes)
    /// Input: ADPCM byte array (2 samples per byte)
    /// Output: PCM byte array (4x larger)
    static func decode(adpcm: [UInt8], state: inout ADPCMState) -> [UInt8] {
        let nSamples = adpcm.count * 2
        var out = [UInt8](repeating: 0, count: nSamples * 2)

        var outIdx = 0
        for byte in adpcm {
            for nibbleIdx in 0..<2 {
                let code: UInt8 = nibbleIdx == 0 ? (byte & 0x0F) : (byte >> 4)
                let step = Int32(stepTable[Int(state.stepIndex)])

                var delta = step >> 3
                if code & 4 != 0 { delta += step }
                if code & 2 != 0 { delta += step >> 1 }
                if code & 1 != 0 { delta += step >> 2 }
                if code & 8 != 0 { delta = -delta }

                let newPredicted = max(-32768, min(32767, Int32(state.predicted) + delta))
                state.predicted = Int16(newPredicted)

                let newIdx = max(0, min(88, Int8(state.stepIndex) + indexTable[Int(code)]))
                state.stepIndex = UInt8(newIdx)

                let leVal = state.predicted.littleEndian
                out[outIdx] = UInt8(UInt16(bitPattern: leVal) & 0xFF)
                out[outIdx + 1] = UInt8(UInt16(bitPattern: leVal) >> 8)
                outIdx += 2
            }
        }

        return out
    }
}
