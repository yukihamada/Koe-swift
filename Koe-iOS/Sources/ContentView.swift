import SwiftUI

enum AppTab: Int, CaseIterable {
    case koe = 0
    case soluna = 1
    case memory = 2
    case conversation = 3
}

struct ContentView: View {
    @StateObject private var recorder = RecordingManager()
    @StateObject private var modelManager = ModelManager.shared
    @ObservedObject private var whisper = WhisperContext.shared
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var selectedTab: AppTab = .koe

    var body: some View {
        TabView(selection: $selectedTab) {
            koeView
                .tabItem {
                    Label("Koe", systemImage: "mic.fill")
                }
                .tag(AppTab.koe)

            SolunaView()
                .tabItem {
                    Label("Soluna", systemImage: "dot.radiowaves.left.and.right")
                }
                .tag(AppTab.soluna)

            SoundMemoryView()
                .tabItem {
                    Label("Memory", systemImage: "brain.head.profile")
                }
                .tag(AppTab.memory)

            ConversationView()
                .tabItem {
                    Label("翻訳", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(AppTab.conversation)
        }
        .tint(.orange)
    }

    private var koeView: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Engine badge (top)
                engineBadge
                    .padding(.top, 8)

                Spacer(minLength: 12)

                // Recognized text (scrollable, expands)
                if !recorder.recognizedText.isEmpty {
                    VStack(spacing: 8) {
                        ScrollView {
                            Text(recorder.recognizedText)
                                .font(.title3)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(16)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 200)

                        // Action buttons
                        HStack(spacing: 16) {
                            Button {
                                UIPasteboard.general.string = recorder.recognizedText
                                withAnimation { recorder.statusText = "コピーしました" }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                    recorder.statusText = recorder.isRecording ? "録音中…" : "タップして録音"
                                }
                            } label: {
                                Label("コピー", systemImage: "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            ShareLink(item: recorder.recognizedText) {
                                Label("共有", systemImage: "square.and.arrow.up")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16)
                }

                Spacer(minLength: 12)

                // Status
                Text(recorder.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)

                // Download banner or progress (compact)
                if !modelManager.isModelReady && !modelManager.isDownloading {
                    compactDownloadBanner
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
                if modelManager.isDownloading {
                    VStack(spacing: 4) {
                        ProgressView(value: modelManager.downloadProgress)
                        HStack {
                            Text(modelManager.downloadStatus).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button("中止") { modelManager.cancelDownload() }.font(.caption2)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }

                // Record button
                RecordButton(isRecording: recorder.isRecording, level: recorder.audioLevel) {
                    if recorder.isRecording { recorder.stopRecording() }
                    else { recorder.startRecording() }
                }
                .padding(.bottom, 4)

                Text(recorder.isRecording ? "タップで停止" : "")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(height: 16)

                Spacer().frame(height: 16)
            }
            .navigationTitle("Koe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHistory = true } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showHistory) {
                HistoryView(recorder: recorder)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .onAppear {
                recorder.requestPermissions()
                if modelManager.isModelReady && !whisper.isLoaded && !whisper.isLoading {
                    modelManager.loadWhisperModel { _ in }
                }
            }
        }
    }

    // MARK: - Engine Badge

    @ViewBuilder
    private var engineBadge: some View {
        if whisper.isLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("whisper.cpp ロード中…")
                    .font(.caption2)
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(.orange.opacity(0.1), in: Capsule())
        } else if whisper.isLoaded {
            Label("whisper.cpp + Metal", systemImage: "cpu")
                .font(.caption2)
                .foregroundStyle(.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(.green.opacity(0.1), in: Capsule())
        } else if modelManager.isModelReady {
            Button {
                modelManager.loadWhisperModel { _ in }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                    Text("whisper.cpp をロード")
                }
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(.orange.opacity(0.1), in: Capsule())
            }
        } else {
            Label("Apple Speech", systemImage: "waveform")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(.secondary.opacity(0.1), in: Capsule())
        }
    }

    // MARK: - Compact Download Banner

    private var compactDownloadBanner: some View {
        Button {
            modelManager.download(modelManager.currentModel)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("whisper.cpp モデルをDL")
                        .font(.caption.bold())
                    Text("\(modelManager.currentModel.name) (\(modelManager.currentModel.sizeMB)MB)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Record Button

struct RecordButton: View {
    let isRecording: Bool
    let level: Float
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRecording {
                    Circle()
                        .stroke(Color.red.opacity(0.3), lineWidth: 3)
                        .frame(width: 88 + CGFloat(level) * 40,
                               height: 88 + CGFloat(level) * 40)
                        .animation(.easeInOut(duration: 0.1), value: level)
                }
                Circle()
                    .stroke(isRecording ? Color.red : Color.accentColor, lineWidth: 3)
                    .frame(width: 72, height: 72)
                if isRecording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red)
                        .frame(width: 28, height: 28)
                } else {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 60, height: 60)
                        .overlay {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.white)
                        }
                }
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact, trigger: isRecording)
    }
}
