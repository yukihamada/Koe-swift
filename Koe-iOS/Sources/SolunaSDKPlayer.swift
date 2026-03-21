import Foundation
import AVFoundation
#if os(iOS)
import UIKit
#endif

// MARK: - SolunaSDKPlayer
// Pure-Swift relay audio receiver for Koe's Soluna radio feature.
// Pipeline: UDP recv -> S24-in-S32LE decode -> SPSC ring buffer -> AVAudioSourceNode

@MainActor
final class SolunaSDKPlayer: ObservableObject {
    static let shared = SolunaSDKPlayer()

    // MARK: - Published State

    @Published var isActive = false
    @Published var peerCount = 0
    @Published var channel = "soluna"
    @Published var relayConnected = false
    @Published var isReceivingAudio = false
    @Published var isMicMonitoring = false

    @Published var ledR: UInt8 = 0
    @Published var ledG: UInt8 = 0
    @Published var ledB: UInt8 = 0
    @Published var ledPattern: UInt8 = 0
    @Published var ledSpeed: UInt8 = 128
    @Published var ledIntensity: UInt8 = 200

    @Published var listenMinutes: Double = 0
    @Published var fanRankBadge: String = "\u{1F331}"
    @Published var debugInfo: String = ""

    // MARK: - Channel Definitions

    struct ChannelDef: Identifiable, Hashable {
        let id: String
        let name: String
        let emoji: String
        let colorHex: String
    }

    static let radioChannels: [ChannelDef] = [
        ChannelDef(id: "bjj",    name: "BJJ",    emoji: "\u{1F94B}", colorHex: "#E53E3E"),
        ChannelDef(id: "soluna", name: "Soluna",  emoji: "\u{1F300}", colorHex: "#ED8936"),
        ChannelDef(id: "jazz",   name: "Jazz",    emoji: "\u{1F3B7}", colorHex: "#D69E2E"),
        ChannelDef(id: "chill",  name: "Chill",   emoji: "\u{1F305}", colorHex: "#38B2AC"),
        ChannelDef(id: "lofi",   name: "Lo-Fi",   emoji: "\u{1F4FB}", colorHex: "#805AD5"),
        ChannelDef(id: "dance",  name: "Dance",   emoji: "\u{1F483}", colorHex: "#D53F8C"),
        ChannelDef(id: "yuki",   name: "Yuki",    emoji: "\u{2744}\u{FE0F}",  colorHex: "#63B3ED"),
    ]

    static let sdkVersion = "2.0.0"

    // MARK: - Audio Engine

    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private let playbackFormat: AVAudioFormat

    // MARK: - Ring Buffer (lock-free SPSC, 4s @ 48kHz mono)

    private let ringCapacity = 192_000
    private let ringBuffer: UnsafeMutablePointer<Float>
    private var writePos: Int64 = 0
    private var readPos: Int64 = 0
    private let prefillThreshold = 4800

    // Pre-allocated buffers (no malloc on RT/recv threads)
    private let scratchBuffer: UnsafeMutablePointer<Float>
    private let scratchCapacity = 4096
    private let decodeBuffer: UnsafeMutablePointer<Float>
    private let decodeCapacity = 256

    // MARK: - Relay

    private var udpSocket: Int32 = -1
    private var relayAddr = sockaddr_in()
    private let relayHost = "relay.solun.art"
    private let running = KoeAtomicFlag()
    private let firstPacketReceived = KoeAtomicFlag()
    private let recvQueue = DispatchQueue(label: "com.koe.soluna.recv", qos: .userInteractive)
    private var heartbeatSource: DispatchSourceTimer?
    private var _packetsAtomic: Int64 = 0

    // MARK: - Timers

    private var statusTimer: Timer?
    private var listenTimer: Timer?

    // MARK: - Device

    private var deviceName: String

    // MARK: - Init

    private init() {
        playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!
        ringBuffer = .allocate(capacity: ringCapacity)
        ringBuffer.initialize(repeating: 0, count: ringCapacity)
        scratchBuffer = .allocate(capacity: scratchCapacity)
        decodeBuffer = .allocate(capacity: decodeCapacity)

        #if os(iOS)
        deviceName = UIDevice.current.name
        #else
        deviceName = Host.current().localizedName ?? "Koe"
        #endif
    }

    deinit {
        ringBuffer.deallocate()
        scratchBuffer.deallocate()
        decodeBuffer.deallocate()
    }

    // MARK: - Ring Buffer

    private func ringAvailable() -> Int {
        min(Int(OSAtomicAdd64(0, &writePos) - OSAtomicAdd64(0, &readPos)), ringCapacity)
    }

    private func ringWrite(_ samples: UnsafePointer<Float>, count: Int) {
        let w = Int(OSAtomicAdd64(0, &writePos))
        let cap = ringCapacity
        if ringAvailable() > cap * 9 / 10 { return }
        for i in 0..<count { ringBuffer[(w + i) % cap] = samples[i] }
        OSAtomicAdd64(Int64(count), &writePos)
    }

    private func ringRead(_ dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let n = min(ringAvailable(), count)
        let r = Int(OSAtomicAdd64(0, &readPos))
        let cap = ringCapacity
        for i in 0..<n { dst[i] = ringBuffer[(r + i) % cap] }
        OSAtomicAdd64(Int64(n), &readPos)
        return n
    }

    private func ringFlush() {
        writePos = 0
        readPos = 0
    }

    // MARK: - Start / Stop

    func start(channel: String = "soluna") {
        guard !isActive else { return }
        self.channel = channel
        isActive = true
        _packetsAtomic = 0
        firstPacketReceived.set(false)

        configureAudioSession()
        ringFlush()
        startAudioEngine()
        connectRelay(channel: channel)

        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                let pkts = OSAtomicAdd64(0, &self._packetsAtomic)
                self.isReceivingAudio = self.firstPacketReceived.value
                self.debugInfo = String(format: "pkts:%lld buf:%d", pkts, self.ringAvailable())
            }
        }

        startListenTimer()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        isReceivingAudio = false

        statusTimer?.invalidate()
        statusTimer = nil
        stopListenTimer()

        disconnectRelay()
        stopAudioEngine()

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

    func toggleMicMonitoring() {
        isMicMonitoring.toggle()
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.defaultToSpeaker])
            try session.setPreferredSampleRate(48000)
            try session.setActive(true)
        } catch {
            NSLog("[SolunaSDKPlayer] AudioSession error: %@", error.localizedDescription)
        }
        #endif
    }

    // MARK: - Audio Engine (AVAudioSourceNode pull-based)

    private func startAudioEngine() {
        let engine = AVAudioEngine()
        let scratch = scratchBuffer
        let scratchCap = scratchCapacity

        let node = AVAudioSourceNode(format: playbackFormat) {
            [weak self] _, _, frameCount, bufferList -> OSStatus in
            guard let self else { return noErr }
            let frames = Int(frameCount)
            let ablp = UnsafeMutableAudioBufferListPointer(bufferList)

            let avail = self.ringAvailable()
            if avail < self.prefillThreshold && !self.firstPacketReceived.value {
                for ch in 0..<ablp.count {
                    if let dst = ablp[ch].mData?.assumingMemoryBound(to: Float.self) {
                        memset(dst, 0, frames * MemoryLayout<Float>.size)
                    }
                }
                return noErr
            }

            let readCount = min(frames, scratchCap)
            let got = self.ringRead(scratch, count: readCount)

            for ch in 0..<ablp.count {
                if let dst = ablp[ch].mData?.assumingMemoryBound(to: Float.self) {
                    if got > 0 { memcpy(dst, scratch, got * MemoryLayout<Float>.size) }
                    if got < frames { memset(dst.advanced(by: got), 0, (frames - got) * MemoryLayout<Float>.size) }
                }
            }
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: playbackFormat)

        do {
            try engine.start()
        } catch {
            NSLog("[SolunaSDKPlayer] Engine start error: %@", error.localizedDescription)
            return
        }

        self.audioEngine = engine
        self.sourceNode = node
    }

    private func stopAudioEngine() {
        if let engine = audioEngine, engine.isRunning { engine.stop() }
        if let node = sourceNode, let engine = audioEngine { engine.detach(node) }
        sourceNode = nil
        audioEngine = nil
    }

    // MARK: - UDP Relay

    private func connectRelay(channel: String) {
        let ch = channel
        let devName = deviceName

        recvQueue.async { [weak self] in
            guard let self else { return }

            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_DGRAM
            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(self.relayHost, "5100", &hints, &res) == 0, let addrInfo = res else {
                NSLog("[SolunaSDKPlayer] DNS resolve failed")
                return
            }
            memcpy(&self.relayAddr, addrInfo.pointee.ai_addr, Int(addrInfo.pointee.ai_addrlen))
            freeaddrinfo(res)

            self.udpSocket = socket(AF_INET, SOCK_DGRAM, 0)
            guard self.udpSocket >= 0 else { return }

            var tv = timeval(tv_sec: 0, tv_usec: 5000)
            setsockopt(self.udpSocket, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            self.sendUDP("JOIN:\(ch)::\(devName)\n")

            self.running.set(true)
            DispatchQueue.main.async { self.relayConnected = true }

            // Heartbeat on recv queue
            let hb = DispatchSource.makeTimerSource(queue: self.recvQueue)
            hb.schedule(deadline: .now() + 5, repeating: 5.0)
            hb.setEventHandler { [weak self] in
                guard let self, self.running.value else { return }
                self.sendUDP("HELLO\n")
                self.sendUDP("JOIN:\(ch)::\(devName)\n")
            }
            hb.resume()
            self.heartbeatSource = hb

            self.recvLoop()
        }
    }

    private func disconnectRelay() {
        running.set(false)
        relayConnected = false
        heartbeatSource?.cancel()
        heartbeatSource = nil
        if udpSocket >= 0 { Darwin.close(udpSocket); udpSocket = -1 }
    }

    private func sendUDP(_ msg: String) {
        guard udpSocket >= 0 else { return }
        msg.withCString { ptr in
            withUnsafePointer(to: relayAddr) { addrPtr in
                let sa = UnsafeRawPointer(addrPtr).assumingMemoryBound(to: sockaddr.self)
                _ = sendto(udpSocket, ptr, strlen(ptr), 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    // MARK: - Receive Loop

    private func recvLoop() {
        var buf = [UInt8](repeating: 0, count: 4096)
        var sender = sockaddr_in()
        var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let scale: Float = 1.0 / 8388608.0
        let decodeBuf = decodeBuffer
        let decodeCap = decodeCapacity

        while running.value && udpSocket >= 0 {
            let n = withUnsafeMutablePointer(to: &sender) { sp -> Int in
                sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(udpSocket, &buf, buf.count, 0, sa, &senderLen)
                }
            }
            guard n > 12 else { continue }
            guard (buf[0] & 0xC0) == 0x80 else { continue }
            guard (buf[1] & 0x7F) == 96 else { continue }

            var off = 12
            if buf[0] & 0x10 != 0 && n >= 16 {
                let extLen = (Int(buf[14]) << 8 | Int(buf[15])) * 4
                off = 16 + extLen
                guard off < n else { continue }
            }

            let end = n - 4
            guard end > off else { continue }

            var count = 0
            var i = off
            while i + 3 < end && count < decodeCap {
                let v = Int32(buf[i]) | (Int32(buf[i+1]) << 8) | (Int32(buf[i+2]) << 16) | (Int32(buf[i+3]) << 24)
                decodeBuf[count] = Float(v) * scale
                count += 1
                i += 4
            }

            ringWrite(decodeBuf, count: count)
            OSAtomicIncrement64(&_packetsAtomic)

            if !firstPacketReceived.value {
                firstPacketReceived.set(true)
                DispatchQueue.main.async { [weak self] in
                    self?.isReceivingAudio = true
                }
            }
        }
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
        case ..<30:   fanRankBadge = "\u{1F331}"
        case ..<120:  fanRankBadge = "\u{2B50}"
        case ..<600:  fanRankBadge = "\u{1F525}"
        default:      fanRankBadge = "\u{1F451}"
        }
    }
}

// MARK: - Thread-safe Atomic Flag

private final class KoeAtomicFlag: @unchecked Sendable {
    private var _value = false
    private var lock = os_unfair_lock()

    var value: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _value
    }

    func set(_ newValue: Bool) {
        os_unfair_lock_lock(&lock)
        _value = newValue
        os_unfair_lock_unlock(&lock)
    }
}
