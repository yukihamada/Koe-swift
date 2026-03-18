import SwiftUI
import AVFoundation

/// SwiftUI view for the Sound Memory feature.
/// Toggle capture, view bookmarks, search transcriptions, play audio clips.
struct SoundMemoryView: View {
    @StateObject private var memory = SoundMemory.shared
    @State private var searchQuery = ""
    @State private var bookmarkLabel = ""
    @State private var showBookmarkAlert = false
    @State private var playingSegmentID: UUID?

    @StateObject private var player = AudioPlayer()

    var body: some View {
        NavigationView {
            List {
                // MARK: - Privacy banner
                if !memory.isEnabled {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "lock.shield.fill")
                                    .font(.title2)
                                    .foregroundColor(.green)
                                Text("音声はこのデバイスだけに保存されます")
                                    .font(.subheadline.bold())
                            }
                            Text("ダウンロード・録音されたデータはすべてローカルに残ります。あなたが「送信」するまで、一切外部には出ません。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack(spacing: 6) {
                                Image(systemName: "airplane")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                Text("試しに機内モードでお試しください。オフラインでも完全に動作します。")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // MARK: - Control section
                Section {
                    Toggle("Sound Memory", isOn: Binding(
                        get: { memory.isEnabled },
                        set: { newValue in
                            if newValue { memory.startCapture() }
                            else { memory.stopCapture() }
                        }
                    ))

                    if memory.isEnabled {
                        HStack {
                            Image(systemName: "waveform")
                                .foregroundColor(.red)
                            Text("Recording...")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(formatDuration(memory.todayDuration))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        HStack {
                            Text("Today")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(formatDuration(memory.todayDuration))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Capture")
                } footer: {
                    if !memory.isEnabled {
                        Text("ONにすると周囲の音声を自動で録音・文字起こしします。データは7日で自動削除されます。")
                    }
                }

                // MARK: - Bookmark button
                if memory.isEnabled {
                    Section {
                        Button {
                            showBookmarkAlert = true
                        } label: {
                            Label("Add Bookmark", systemImage: "bookmark.fill")
                        }
                    }
                }

                // MARK: - Search
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search transcriptions...", text: $searchQuery)
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Search")
                }

                // MARK: - Search results or recent segments
                if !searchQuery.isEmpty {
                    let results = memory.search(query: searchQuery)
                    Section {
                        if results.isEmpty {
                            Text("No results")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(results) { segment in
                                segmentRow(segment)
                            }
                        }
                    } header: {
                        Text("Results (\(memory.search(query: searchQuery).count))")
                    }
                } else {
                    // Bookmarks
                    if !memory.bookmarks.isEmpty {
                        Section {
                            ForEach(memory.bookmarks.prefix(20)) { bm in
                                HStack {
                                    Image(systemName: "bookmark.fill")
                                        .foregroundColor(.orange)
                                    VStack(alignment: .leading) {
                                        Text(bm.label)
                                            .font(.subheadline)
                                        Text(timeFormatter.string(from: bm.timestamp))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        } header: {
                            Text("Bookmarks")
                        }
                    }

                    // Recent segments
                    Section {
                        if memory.segments.isEmpty {
                            Text("No recordings yet")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(memory.segments.prefix(50)) { segment in
                                segmentRow(segment)
                            }
                        }
                    } header: {
                        Text("Recent")
                    }
                }

                // MARK: - Mac auto-send
                if memory.isEnabled {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "macbook.and.iphone")
                                .font(.title3)
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Macに自動送信")
                                    .font(.subheadline.bold())
                                if MacBridge.shared.isConnected {
                                    Text("Mac接続中 — テキストが自動で入力されます")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                } else {
                                    Text("同じWiFiでKoe macOS版を起動すると自動接続します")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    } header: {
                        Text("Mac連携")
                    } footer: {
                        Text("録音テキストは送信するまでiPhoneから出ません。Mac連携もローカルネットワーク内のみで動作します。")
                    }
                }

                // MARK: - Storage management
                Section {
                    Button(role: .destructive) {
                        memory.deleteOldData()
                    } label: {
                        Label("Delete Old Data (>7 days)", systemImage: "trash")
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("\(memory.segments.count) segments stored")
                }
            }
            .navigationTitle("Sound Memory")
            .alert("Bookmark", isPresented: $showBookmarkAlert) {
                TextField("Label (optional)", text: $bookmarkLabel)
                Button("Save") {
                    memory.addBookmark(label: bookmarkLabel)
                    bookmarkLabel = ""
                }
                Button("Cancel", role: .cancel) {
                    bookmarkLabel = ""
                }
            } message: {
                Text("Mark this moment")
            }
        }
    }

    // MARK: - Segment row

    @ViewBuilder
    private func segmentRow(_ segment: SoundMemory.MemorySegment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(timeFormatter.string(from: segment.timestamp))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(formatDuration(segment.duration))
                    .font(.caption2)
                    .foregroundColor(.secondary)

                // Play button
                Button {
                    togglePlayback(segment)
                } label: {
                    Image(systemName: playingSegmentID == segment.id ? "stop.circle.fill" : "play.circle.fill")
                        .font(.title3)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }

            if !segment.text.isEmpty {
                Text(segment.text)
                    .font(.subheadline)
                    .lineLimit(3)
            } else {
                Text("(no transcription)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .italic()
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Playback

    private func togglePlayback(_ segment: SoundMemory.MemorySegment) {
        if playingSegmentID == segment.id {
            player.stop()
            playingSegmentID = nil
        } else {
            let url = memory.audioURL(for: segment)
            player.play(url: url) {
                playingSegmentID = nil
            }
            playingSegmentID = segment.id
        }
    }

    // MARK: - Formatters

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 {
            return String(format: "%dh %02dm", h, m)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }

    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }
}

// MARK: - Simple audio player wrapper

@MainActor
final class AudioPlayer: ObservableObject {
    private var avPlayer: AVAudioPlayer?
    private var completion: (() -> Void)?
    private var delegate: PlayerDelegate?

    func play(url: URL, onFinish: @escaping () -> Void) {
        stop()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)

            avPlayer = try AVAudioPlayer(contentsOf: url)
            completion = onFinish
            delegate = PlayerDelegate { [weak self] in
                self?.completion?()
                self?.completion = nil
            }
            avPlayer?.delegate = delegate
            avPlayer?.play()
        } catch {
            print("[SoundMemory] Playback error: \(error)")
            onFinish()
        }
    }

    func stop() {
        avPlayer?.stop()
        avPlayer = nil
        completion?()
        completion = nil
    }
}

private class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.onFinish() }
    }
}

#Preview {
    SoundMemoryView()
}
