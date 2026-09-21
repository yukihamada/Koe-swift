import SwiftUI
import AppKit
import AVFoundation

/// Koe 全体の「Lux(ウォーム・ラグジュアリー)」ブランドトークン。
/// SettingsWindowController.swift の private `Lux` / OverlayWindow.swift の recRed と同じ値を
/// このファイル内で再定義(private enum は file-scope のため共有できない。値は必ず揃えること)。
private enum RecLux {
    static let gold      = Color(red: 0.78, green: 0.68, blue: 0.50)
    static let champagne = Color(red: 0.90, green: 0.84, blue: 0.72)
    static let charcoal  = Color(red: 0.10, green: 0.09, blue: 0.08)
    static let recRed    = Color(red: 0.95, green: 0.42, blue: 0.34)
    static let amber     = Color(red: 0.85, green: 0.55, blue: 0.40)
}

/// 録音中の一時状態(実際の録音処理は VoiceMemoRecorder が持つ。ここは UI 用の薄い ObservableObject)。
final class VoiceRecorderViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var elapsed: TimeInterval = 0
    @Published var level: Float = 0
    @Published var selectedID: UUID?
    @Published var searchText = ""
    @Published var showFavoritesOnly = false

    private var uiTimer: Timer?
    private var player: AVAudioPlayer?
    private var playbackTimer: Timer?
    @Published var isPlaying = false
    @Published var playbackProgress: Double = 0  // 0.0-1.0
    @Published var playingRecordID: UUID?

    // リネーム/削除ダイアログ用
    @Published var renamingRecord: VoiceMemoRecord?
    @Published var renameText: String = ""
    @Published var deletingRecord: VoiceMemoRecord?

    func beginRename(_ record: VoiceMemoRecord) {
        renameText = record.title.isEmpty ? record.displayTitle : record.title
        renamingRecord = record
    }

    func commitRename() {
        guard let record = renamingRecord else { return }
        let newTitle = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        VoiceMemoLibrary.shared.update(id: record.id) { $0.title = newTitle }
        renamingRecord = nil
    }

    func confirmDelete(_ record: VoiceMemoRecord) {
        deletingRecord = record
    }

    @Published var speakingRecordID: UUID?
    @Published var speakErrorRecordID: UUID?
    @Published var speakErrorMessage: String?

    func speakSummary(_ record: VoiceMemoRecord) {
        guard speakingRecordID == nil else { return }
        speakingRecordID = record.id
        speakErrorMessage = nil
        M5SpeakClient.shared.speak(record) { [weak self] outcome in
            guard let self else { return }
            self.speakingRecordID = nil
            switch outcome {
            case .playedM5:
                break
            case .playedFallbackVoice:
                self.speakErrorRecordID = record.id
                self.speakErrorMessage = "m5サーバに接続できないため標準音声で再生しました"
            case .failed(let msg):
                self.speakErrorRecordID = record.id
                self.speakErrorMessage = msg
            }
        }
    }

    @Published var sharingRecordID: UUID?
    @Published var shareErrorRecordID: UUID?
    @Published var shareErrorMessage: String?

    func shareToTakibi(_ record: VoiceMemoRecord) {
        guard sharingRecordID == nil else { return }
        sharingRecordID = record.id
        shareErrorMessage = nil
        VoiceMemoShare.shared.postToTakibi(record) { [weak self] outcome in
            guard let self else { return }
            self.sharingRecordID = nil
            switch outcome {
            case .success(let logID):
                VoiceMemoLibrary.shared.updateAndSaveNow(id: record.id) { $0.takibiLogID = logID ?? "posted" }
            case .failure(let msg):
                self.shareErrorRecordID = record.id
                self.shareErrorMessage = msg
            }
        }
    }

    @Published var checkingVoiceRecordID: UUID?
    @Published var uploadingRecordID: UUID?
    @Published var uploadErrorRecordID: UUID?
    @Published var uploadErrorMessage: String?

    /// 🎙→📻: まず声を照合し、本人ならそのままラジオへ。違う声なら無断登録せず案内する。
    func uploadToRadio(_ record: VoiceMemoRecord) {
        guard checkingVoiceRecordID == nil, uploadingRecordID == nil else { return }
        uploadErrorMessage = nil
        checkingVoiceRecordID = record.id
        RadioUploader.shared.checkVoice(record) { [weak self] result in
            guard let self else { return }
            self.checkingVoiceRecordID = nil
            switch result {
            case .isYuki:
                self.uploadingRecordID = record.id
                RadioUploader.shared.uploadToRoom(record) { [weak self] outcome in
                    guard let self else { return }
                    self.uploadingRecordID = nil
                    switch outcome {
                    case .success:
                        VoiceMemoLibrary.shared.updateAndSaveNow(id: record.id) { $0.radioUploaded = true }
                    case .failure(let msg):
                        self.uploadErrorRecordID = record.id
                        self.uploadErrorMessage = msg
                    }
                }
            case .notYuki:
                RadioUploader.shared.promptEnrollIfNeeded()
            case .checkFailed(let msg):
                self.uploadErrorRecordID = record.id
                self.uploadErrorMessage = msg
            }
        }
    }

    func performDelete() {
        guard let record = deletingRecord else { return }
        if playingRecordID == record.id { stopPlayback() }
        if selectedID == record.id { selectedID = nil }
        VoiceMemoLibrary.shared.delete(id: record.id)
        deletingRecord = nil
    }

    private var lastToggleAt: Date?

    /// 実機検証で極短時間の二重発火(クリック起因のイベント重複)を観測したための防御。
    /// 通常のクリック間隔(数百ms以上)には影響しない。
    func toggleRecording() {
        let now = Date()
        if let last = lastToggleAt, now.timeIntervalSince(last) < 1.0 { return }
        lastToggleAt = now
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard let id = VoiceMemoRecorder.shared.start() else { return }
        isRecording = true
        isPaused = false
        elapsed = 0
        selectedID = id
        uiTimer?.invalidate()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsed = VoiceMemoRecorder.shared.elapsed()
            self.level = VoiceMemoRecorder.shared.currentLevel()
        }
    }

    private func stopRecording() {
        uiTimer?.invalidate()
        uiTimer = nil
        _ = VoiceMemoRecorder.shared.stop()
        isRecording = false
        isPaused = false
        elapsed = 0
        level = 0
    }

    func togglePause() {
        guard isRecording else { return }
        if isPaused {
            VoiceMemoRecorder.shared.resume()
        } else {
            VoiceMemoRecorder.shared.pause()
        }
        isPaused.toggle()
    }

    func stopIfRecording() {
        guard isRecording else { return }
        stopRecording()
    }

    func play(_ record: VoiceMemoRecord) {
        stopPlayback()
        guard let p = try? AVAudioPlayer(contentsOf: record.fileURL) else {
            klog("VoiceRecorder: playback failed for \(record.fileName)")
            return
        }
        player = p
        p.play()
        isPlaying = true
        playingRecordID = record.id
        playbackProgress = 0
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let pl = self.player else { return }
            if pl.duration > 0 { self.playbackProgress = pl.currentTime / pl.duration }
            if !pl.isPlaying { self.stopPlayback() }
        }
    }

    func seek(_ record: VoiceMemoRecord, to ratio: Double) {
        if playingRecordID != record.id || player == nil {
            play(record)
        }
        guard let p = player else { return }
        p.currentTime = ratio * p.duration
        playbackProgress = ratio
    }

    func stopPlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        player?.stop()
        player = nil
        isPlaying = false
        playbackProgress = 0
        playingRecordID = nil
    }
}

struct VoiceRecorderView: View {
    @ObservedObject var model: VoiceRecorderViewModel
    @ObservedObject private var library = VoiceMemoLibrary.shared

    var filteredRecords: [VoiceMemoRecord] {
        var items = library.records
        if model.showFavoritesOnly { items = items.filter { $0.isFavorite } }
        let q = model.searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(q)
                || ($0.transcript?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            RecordBarView(model: model)
            Divider().opacity(0.5)
            HSplitView {
                VoiceMemoListView(model: model, records: filteredRecords)
                    .frame(minWidth: 240, idealWidth: 270, maxWidth: 340)
                VoiceMemoDetailView(model: model)
                    .frame(minWidth: 340)
            }
        }
        .frame(minWidth: 600, minHeight: 440)
        .background(Color(NSColor.windowBackgroundColor))
        .alert("リネーム", isPresented: Binding(
            get: { model.renamingRecord != nil },
            set: { if !$0 { model.renamingRecord = nil } }
        )) {
            TextField("タイトル", text: $model.renameText)
            Button("保存") { model.commitRename() }
            Button("キャンセル", role: .cancel) { model.renamingRecord = nil }
        }
        .alert("この録音を削除しますか?", isPresented: Binding(
            get: { model.deletingRecord != nil },
            set: { if !$0 { model.deletingRecord = nil } }
        )) {
            Button("ゴミ箱に入れる", role: .destructive) { model.performDelete() }
            Button("キャンセル", role: .cancel) { model.deletingRecord = nil }
        } message: {
            Text(model.deletingRecord?.displayTitle ?? "")
        }
    }
}

/// 上部の常設録音バー(待機時/録音中の2状態)。Koe の Lux トーンに合わせて意匠を統一。
struct RecordBarView: View {
    @ObservedObject var model: VoiceRecorderViewModel
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 16) {
            recordButton
                .onAppear { pulse = true }

            if model.isRecording {
                Button(action: { model.togglePause() }) {
                    Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(RecLux.gold)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(RecLux.gold.opacity(0.15)))
                }
                .buttonStyle(.plain)

                Text(formatElapsed(model.elapsed))
                    .font(.system(.title3, design: .monospaced).weight(.medium))
                    .foregroundColor(.primary)
                    .monospacedDigit()

                RecorderWaveformView(level: model.isPaused ? 0 : model.level)
                    .frame(height: 40)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("クリックで録音開始")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                    Text("⌘N — メニューを開いてから押すと最速")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(height: 92)
        .background(
            LinearGradient(
                colors: [RecLux.gold.opacity(0.08), Color.clear],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    private var recordButton: some View {
        Button(action: { model.toggleRecording() }) {
            ZStack {
                if model.isRecording {
                    Circle()
                        .stroke(RecLux.recRed.opacity(0.35), lineWidth: 3)
                        .frame(width: 52, height: 52)
                        .scaleEffect(pulse ? 1.25 : 1.0)
                        .opacity(pulse ? 0 : 0.8)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)
                }
                Circle()
                    .fill(model.isRecording ? RecLux.recRed : RecLux.recRed.opacity(0.92))
                    .frame(width: 44, height: 44)
                    .shadow(color: RecLux.recRed.opacity(0.4), radius: 6, y: 2)
                if model.isRecording {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.white)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

struct VoiceMemoListView: View {
    @ObservedObject var model: VoiceRecorderViewModel
    let records: [VoiceMemoRecord]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                TextField("検索", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                Button(action: { model.showFavoritesOnly.toggle() }) {
                    Image(systemName: model.showFavoritesOnly ? "star.fill" : "star")
                        .font(.system(size: 12))
                        .foregroundColor(model.showFavoritesOnly ? RecLux.gold : .secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.6))
            )
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)

            if records.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 28))
                        .foregroundColor(RecLux.gold.opacity(0.5))
                    Text("録音はまだありません")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                List(records, selection: $model.selectedID) { record in
                    VoiceMemoRowView(record: record, isSelected: model.selectedID == record.id)
                        .tag(record.id)
                        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            Button("リネーム") { model.beginRename(record) }
                            Button(record.isFavorite ? "お気に入り解除" : "お気に入りに追加") {
                                VoiceMemoLibrary.shared.update(id: record.id) { $0.isFavorite.toggle() }
                            }
                            Button("Finder に表示") {
                                NSWorkspace.shared.activateFileViewerSelecting([record.fileURL])
                            }
                            Divider()
                            Button("削除…", role: .destructive) { model.confirmDelete(record) }
                        }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

struct VoiceMemoRowView: View {
    let record: VoiceMemoRecord
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(RecLux.gold.opacity(isSelected ? 0.22 : 0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(RecLux.gold)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(record.displayTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundColor(record.duration < 0 ? RecLux.recRed : .secondary)
            }
            Spacer(minLength: 4)
            transcriptBadge
            Button(action: {
                VoiceMemoLibrary.shared.update(id: record.id) { $0.isFavorite.toggle() }
            }) {
                Image(systemName: record.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundColor(record.isFavorite ? RecLux.gold : .secondary.opacity(0.35))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? RecLux.gold.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? RecLux.gold.opacity(0.35) : Color.clear, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var transcriptBadge: some View {
        switch record.transcriptStatus {
        case .none: EmptyView()
        case .queued: Image(systemName: "clock").font(.system(size: 10)).foregroundColor(.secondary)
        case .running: ProgressView().scaleEffect(0.45)
        case .done: Image(systemName: "text.bubble.fill").font(.system(size: 10)).foregroundColor(RecLux.amber)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundColor(RecLux.recRed)
        }
    }

    private var subtitle: String {
        if record.duration < 0 { return "⚠ 破損" }
        let m = Int(max(0, record.duration)) / 60, s = Int(max(0, record.duration)) % 60
        let time = String(format: "%02d:%02d", m, s)
        guard let location = record.location, !location.isEmpty else { return time }
        return "\(time) ・ \(location)"
    }
}

struct VoiceMemoDetailView: View {
    @ObservedObject var model: VoiceRecorderViewModel
    @ObservedObject private var library = VoiceMemoLibrary.shared

    var selected: VoiceMemoRecord? {
        guard let id = model.selectedID else { return nil }
        return library.record(id: id)
    }

    var body: some View {
        Group {
            if let record = selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        titleRow(record)
                        playbackCard(record)
                        transcriptCard(record)
                        if record.transcript != nil {
                            summaryCard(record)
                        }
                    }
                    .padding(20)
                }
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "mic.circle")
                        .font(.system(size: 40))
                        .foregroundColor(RecLux.gold.opacity(0.35))
                    Text("録音を選択してください")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func titleRow(_ record: VoiceMemoRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.displayTitle)
                    .font(.system(size: 17, weight: .semibold))
                HStack(spacing: 4) {
                    Text(dateString(record.createdAt))
                    if let location = record.location, !location.isEmpty {
                        Text("・")
                        Image(systemName: "location.fill")
                            .font(.system(size: 9))
                        Text(location)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: { model.beginRename(record) }) {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func playbackCard(_ record: VoiceMemoRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button(action: {
                    if model.isPlaying && model.playingRecordID == record.id {
                        model.stopPlayback()
                    } else {
                        model.play(record)
                    }
                }) {
                    Circle()
                        .fill(RecLux.gold)
                        .frame(width: 34, height: 34)
                        .overlay(
                            Image(systemName: (model.isPlaying && model.playingRecordID == record.id) ? "stop.fill" : "play.fill")
                                .font(.system(size: 13))
                                .foregroundColor(.white)
                        )
                }
                .buttonStyle(.plain)

                Text(subtitle(record))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)

                Spacer()
            }

            if let peaks = record.waveformPeaks, !peaks.isEmpty {
                StaticWaveformView(
                    peaks: peaks,
                    progress: model.playingRecordID == record.id ? model.playbackProgress : nil,
                    onSeek: { ratio in model.seek(record, to: ratio) }
                )
                .frame(height: 56)
            } else {
                HStack {
                    Spacer()
                    Text(record.duration < 0 ? "⚠ このファイルは破損しています" : "波形を生成中…")
                        .font(.caption)
                        .foregroundColor(record.duration < 0 ? RecLux.recRed : .secondary)
                    Spacer()
                }
                .frame(height: 56)
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private func transcriptCard(_ record: VoiceMemoRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("文字起こし", systemImage: "text.bubble")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                statusPill(record)
                Button("再文字起こし") { VoiceMemoTranscriptionQueue.shared.retranscribe(record.id) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(RecLux.gold)
                    .disabled({ if case .running = record.transcriptStatus { return true }; return false }())
            }
            if let transcript = record.transcript, !transcript.isEmpty {
                ScrollView {
                    Text(transcript)
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 70, maxHeight: 150)
                HStack {
                    Button("コピー") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcript, forType: .string)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    Spacer()
                }
            } else if case .none = record.transcriptStatus {
                Text("文字起こしはまだありません")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    @ViewBuilder
    private func statusPill(_ record: VoiceMemoRecord) -> some View {
        switch record.transcriptStatus {
        case .running(let p):
            ProgressView(value: p).frame(width: 70)
        case .queued:
            pill(text: "待機中", color: .secondary)
        case .failed(let msg):
            pill(text: "失敗: \(msg)", color: RecLux.recRed)
        default: EmptyView()
        }
    }

    private func pill(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func summaryCard(_ record: VoiceMemoRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("要約", systemImage: "sparkles")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                Button {
                    model.speakSummary(record)
                } label: {
                    HStack(spacing: 5) {
                        if model.speakingRecordID == record.id {
                            ProgressView().scaleEffect(0.5)
                        } else {
                            Image(systemName: "waveform")
                                .font(.system(size: 11))
                        }
                        Text("本人声で聴く").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(RecLux.gold))
                }
                .buttonStyle(.plain)
                .disabled(model.speakingRecordID == record.id)
            }

            if let summary = record.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
            } else {
                Text("要約は生成中です…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if let msg = model.speakErrorMessage, model.speakErrorRecordID == record.id {
                Text(msg).font(.caption).foregroundColor(RecLux.amber)
            }

            Divider().opacity(0.4)

            HStack {
                Button {
                    model.shareToTakibi(record)
                } label: {
                    HStack(spacing: 5) {
                        if model.sharingRecordID == record.id {
                            ProgressView().scaleEffect(0.5)
                        } else if record.takibiLogID != nil {
                            Image(systemName: "checkmark.circle.fill")
                        } else {
                            Image(systemName: "flame")
                        }
                        Text(record.takibiLogID != nil ? "焚き火に投稿済み" : "焚き火に投稿")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(record.takibiLogID != nil ? .secondary : RecLux.amber)
                }
                .buttonStyle(.plain)
                .disabled(model.sharingRecordID == record.id || record.takibiLogID != nil || record.summary == nil)

                Button {
                    model.uploadToRadio(record)
                } label: {
                    HStack(spacing: 5) {
                        if model.checkingVoiceRecordID == record.id {
                            ProgressView().scaleEffect(0.5)
                            Text("声を確認中…").font(.system(size: 11, weight: .medium))
                        } else if model.uploadingRecordID == record.id {
                            ProgressView().scaleEffect(0.5)
                            Text("アップロード中…").font(.system(size: 11, weight: .medium))
                        } else if record.radioUploaded {
                            Image(systemName: "checkmark.circle.fill")
                            Text("ラジオに追加済み").font(.system(size: 11, weight: .medium))
                        } else {
                            Image(systemName: "dot.radiowaves.left.and.right")
                            Text("ラジオにあげる").font(.system(size: 11, weight: .medium))
                        }
                    }
                    .foregroundColor(record.radioUploaded ? .secondary : RecLux.amber)
                }
                .buttonStyle(.plain)
                .disabled(model.checkingVoiceRecordID == record.id || model.uploadingRecordID == record.id || record.radioUploaded)

                Spacer()
                if let msg = model.shareErrorMessage, model.shareErrorRecordID == record.id {
                    Text(msg).font(.caption).foregroundColor(RecLux.amber)
                }
                if let msg = model.uploadErrorMessage, model.uploadErrorRecordID == record.id {
                    Text(msg).font(.caption).foregroundColor(RecLux.amber)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(RecLux.gold.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(RecLux.gold.opacity(0.25), lineWidth: 1)
        )
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    private func subtitle(_ record: VoiceMemoRecord) -> String {
        let m = Int(max(0, record.duration)) / 60, s = Int(max(0, record.duration)) % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f.string(from: date)
    }
}
