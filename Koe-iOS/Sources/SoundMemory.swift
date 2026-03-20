import Foundation
import AVFoundation
import Accelerate

/// Sound Memory: continuous background audio capture with Whisper transcription.
/// Records 30-second AAC segments, transcribes each via WhisperContext, and stores
/// text + audio locally for up to 7 days.
@MainActor
final class SoundMemory: ObservableObject {
    static let shared = SoundMemory()

    // MARK: - Published state

    @Published var isEnabled = false
    @Published var segments: [MemorySegment] = []
    @Published var bookmarks: [Bookmark] = []
    @Published var todayDuration: TimeInterval = 0

    // MARK: - Types

    struct MemorySegment: Identifiable, Codable {
        let id: UUID
        let timestamp: Date
        let text: String
        let audioFileURL: String   // relative path from storageDir
        let duration: TimeInterval
    }

    struct Bookmark: Identifiable, Codable {
        let id: UUID
        let timestamp: Date
        let label: String
    }

    // MARK: - Configuration

    private let maxStorageDays = 7
    private let segmentDuration: TimeInterval = 30

    // MARK: - Storage

    private let storageDir: URL
    private let segmentsFile: URL

    // MARK: - Audio capture (separate engine from RecordingManager)

    private var audioEngine: AVAudioEngine?
    private var currentFileWriter: AVAudioFile?
    private var currentSegmentStart: Date?
    private var segmentTimer: Timer?
    private var currentSegmentURL: URL?

    // PCM buffer for Whisper (accumulated per segment)
    private var pcmSamples: [Float] = []
    private let samplesLock = NSLock()

    // MARK: - Init

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        storageDir = docs.appendingPathComponent("SoundMemory", isDirectory: true)
        segmentsFile = storageDir.appendingPathComponent("segments.json")
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        loadData()
        updateTodayDuration()

        // 前回ONだった場合、自動で再開
        if UserDefaults.standard.bool(forKey: "koe_sound_memory_enabled") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.startCapture()
            }
        }
    }

    // MARK: - Public API

    func startCapture() {
        guard !isEnabled else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("[SoundMemory] Audio session error: \(error)")
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        // Converter: hardware format -> 16kHz mono Float32 (for Whisper)
        guard let whisperFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: 16000, channels: 1,
                                                interleaved: false),
              let converter = AVAudioConverter(from: hwFormat, to: whisperFormat) else {
            print("[SoundMemory] Failed to create audio converter")
            return
        }

        samplesLock.lock()
        pcmSamples.removeAll(keepingCapacity: true)
        pcmSamples.reserveCapacity(16000 * Int(segmentDuration))
        samplesLock.unlock()

        // Start first AAC file
        beginNewSegmentFile()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Write AAC to file
            if let writer = self.currentFileWriter {
                try? writer.write(from: buffer)
            }

            // Also collect 16kHz PCM for Whisper
            let ratio = 16000.0 / hwFormat.sampleRate
            let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: whisperFormat, frameCapacity: outFrames) else { return }

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

        engine.prepare()
        do {
            try engine.start()
        } catch {
            print("[SoundMemory] Engine start error: \(error)")
            return
        }

        audioEngine = engine
        isEnabled = true
        UserDefaults.standard.set(true, forKey: "koe_sound_memory_enabled")

        // Timer to finalize segments every 30 seconds
        segmentTimer = Timer.scheduledTimer(withTimeInterval: segmentDuration, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.finalizeCurrentSegment()
            }
        }

        print("[SoundMemory] Capture started")
    }

    func stopCapture() {
        guard isEnabled else { return }

        segmentTimer?.invalidate()
        segmentTimer = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        // Finalize last segment
        finalizeCurrentSegment()

        isEnabled = false
        UserDefaults.standard.set(false, forKey: "koe_sound_memory_enabled")
        print("[SoundMemory] Capture stopped")
    }

    func addBookmark(label: String = "") {
        let bm = Bookmark(
            id: UUID(),
            timestamp: Date(),
            label: label.isEmpty ? dateFormatter.string(from: Date()) : label
        )
        bookmarks.insert(bm, at: 0)
        saveData()
    }

    func search(query: String) -> [MemorySegment] {
        guard !query.isEmpty else { return [] }
        return segments.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    func getSegments(for date: Date) -> [MemorySegment] {
        let cal = Calendar.current
        return segments.filter { cal.isDate($0.timestamp, inSameDayAs: date) }
    }

    func deleteOldData() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -maxStorageDays, to: Date()) ?? Date()

        // Remove old segments and their audio files
        let old = segments.filter { $0.timestamp < cutoff }
        for seg in old {
            let fileURL = storageDir.appendingPathComponent(seg.audioFileURL)
            try? FileManager.default.removeItem(at: fileURL)
        }
        segments.removeAll { $0.timestamp < cutoff }
        bookmarks.removeAll { $0.timestamp < cutoff }

        // Remove empty date directories
        if let contents = try? FileManager.default.contentsOfDirectory(at: storageDir, includingPropertiesForKeys: nil) {
            for dir in contents where dir.hasDirectoryPath {
                let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                if items.isEmpty {
                    try? FileManager.default.removeItem(at: dir)
                }
            }
        }

        saveData()
        updateTodayDuration()
    }

    /// Returns the full URL for a segment's audio file.
    func audioURL(for segment: MemorySegment) -> URL {
        storageDir.appendingPathComponent(segment.audioFileURL)
    }

    // MARK: - Private: Segment lifecycle

    private func beginNewSegmentFile() {
        let now = Date()
        let dayDir = dayDirectoryURL(for: now)
        try? FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

        let filename = "\(fileFormatter.string(from: now)).m4a"
        let fileURL = dayDir.appendingPathComponent(filename)

        // AAC compressed output format (~128kbps)
        guard let outputFormat = AVAudioFormat(
            settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128000
            ]
        ) else {
            print("[SoundMemory] Failed to create AAC format")
            return
        }

        do {
            let hwFormat = audioEngine?.inputNode.outputFormat(forBus: 0)
                ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
            currentFileWriter = try AVAudioFile(forWriting: fileURL, settings: hwFormat.settings)
            currentSegmentURL = fileURL
            currentSegmentStart = now
        } catch {
            print("[SoundMemory] Failed to create audio file: \(error)")
        }
    }

    private func finalizeCurrentSegment() {
        guard let segmentURL = currentSegmentURL,
              let startTime = currentSegmentStart else { return }

        let duration = Date().timeIntervalSince(startTime)

        // Close current file
        currentFileWriter = nil

        // Grab PCM samples for transcription
        samplesLock.lock()
        let samples = pcmSamples
        pcmSamples.removeAll(keepingCapacity: true)
        samplesLock.unlock()

        // Compute relative path for storage
        let relativePath = segmentURL.path.replacingOccurrences(of: storageDir.path + "/", with: "")

        // Start next segment immediately (don't miss audio)
        if isEnabled {
            beginNewSegmentFile()
        }

        // Skip very short segments
        guard samples.count > 8000 else { return }  // < 0.5s

        // Transcribe on background queue
        let lang = UserDefaults.standard.string(forKey: "koe_language") ?? "ja-JP"
        let whisperLang = lang == "auto" ? "auto" : (lang.components(separatedBy: "-").first ?? "ja")

        WhisperContext.shared.transcribeBuffer(samples: samples, language: whisperLang) { [weak self] text in
            guard let self else { return }
            let transcription = text ?? ""

            let segment = MemorySegment(
                id: UUID(),
                timestamp: startTime,
                text: transcription,
                audioFileURL: relativePath,
                duration: duration
            )

            self.segments.insert(segment, at: 0)

            // Keep segments manageable in memory (last 7 days handled by deleteOldData)
            if self.segments.count > 20000 {
                self.segments = Array(self.segments.prefix(20000))
            }

            self.updateTodayDuration()
            self.saveData()
        }
    }

    // MARK: - Persistence (JSON file)

    private struct StorageData: Codable {
        var segments: [MemorySegment]
        var bookmarks: [Bookmark]
    }

    private func saveData() {
        let data = StorageData(segments: segments, bookmarks: bookmarks)
        do {
            let json = try JSONEncoder().encode(data)
            try json.write(to: segmentsFile, options: .atomic)
        } catch {
            print("[SoundMemory] Save error: \(error)")
        }
    }

    private func loadData() {
        guard let json = try? Data(contentsOf: segmentsFile),
              let data = try? JSONDecoder().decode(StorageData.self, from: json) else { return }
        segments = data.segments
        bookmarks = data.bookmarks
    }

    private func updateTodayDuration() {
        let today = Date()
        todayDuration = getSegments(for: today).reduce(0) { $0 + $1.duration }
    }

    // MARK: - Helpers

    private func dayDirectoryURL(for date: Date) -> URL {
        storageDir.appendingPathComponent(dayFormatter.string(from: date), isDirectory: true)
    }

    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private let fileFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        return f
    }()

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()
}
