import AppKit
import SwiftUI
import Combine

/// 議事録モード中のリアルタイム文字起こしウィンドウ
class MeetingLiveWindow {
    private var window: NSWindow?
    private let model = MeetingLiveModel()
    private var cancellables: [AnyCancellable] = []

    func show() {
        if window != nil { window?.makeKeyAndOrderFront(nil); return }

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let w: CGFloat = 400, h: CGFloat = 500
        let rect = CGRect(
            x: screen.visibleFrame.maxX - w - 20,
            y: screen.visibleFrame.minY + 60,
            width: w, height: h
        )
        let win = NSWindow(contentRect: rect,
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "Koe 議事録 — リアルタイム"
        win.minSize = NSSize(width: 300, height: 200)
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.contentView = NSHostingView(rootView: MeetingLiveView(model: model))
        win.makeKeyAndOrderFront(nil)
        window = win

        // MeetingModeの統計を監視
        MeetingMode.shared.$entryCount
            .receive(on: RunLoop.main)
            .sink { [weak self] c in self?.model.entryCount = c }
            .store(in: &cancellables)
        MeetingMode.shared.$charCount
            .receive(on: RunLoop.main)
            .sink { [weak self] c in self?.model.charCount = c }
            .store(in: &cancellables)
    }

    func hide() {
        window?.orderOut(nil)
    }

    func appendText(_ text: String, speaker: Int? = nil) {
        let entry = LiveEntry(text: text, speaker: speaker, timestamp: Date(), isImportant: false)
        model.entries.append(entry)
        // 自動スクロール
        model.scrollToBottom += 1
    }

    func markImportant() {
        guard !model.entries.isEmpty else { return }
        model.entries[model.entries.count - 1].isImportant = true
        klog("MeetingLive: marked last entry as important")
    }

    func updateStreamingText(_ text: String) {
        model.streamingText = text
    }
}

// MARK: - Model

struct LiveEntry: Identifiable {
    let id = UUID()
    let text: String
    let speaker: Int?
    let timestamp: Date
    var isImportant: Bool
}

class MeetingLiveModel: ObservableObject {
    @Published var entries: [LiveEntry] = []
    @Published var streamingText = ""  // Apple Speechのリアルタイム仮テキスト
    @Published var entryCount = 0
    @Published var charCount = 0
    @Published var scrollToBottom = 0
    @Published var searchQuery = ""

    var filteredEntries: [LiveEntry] {
        guard !searchQuery.isEmpty else { return entries }
        return entries.filter { $0.text.localizedCaseInsensitiveContains(searchQuery) }
    }

    var importantEntries: [LiveEntry] {
        entries.filter { $0.isImportant }
    }
}

// MARK: - View

struct MeetingLiveView: View {
    @ObservedObject var model: MeetingLiveModel
    @State private var showImportantOnly = false
    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let startDate = Date()

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(formatDuration(elapsed))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(model.entryCount)発言 / \(model.charCount)文字")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Toggle("★のみ", isOn: $showImportantOnly)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // 検索
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("検索...", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider()

            // テキスト一覧
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        let display = showImportantOnly ? model.importantEntries : model.filteredEntries
                        ForEach(display) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                Text(timeFormatter.string(from: entry.timestamp))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 55, alignment: .leading)

                                if let sp = entry.speaker {
                                    Text("話者\(sp + 1)")
                                        .font(.system(size: 9, weight: .medium))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(speakerColor(sp).opacity(0.2))
                                        .cornerRadius(3)
                                }

                                Text(entry.text)
                                    .font(.system(size: 12))
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                if entry.isImportant {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(.yellow)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 2)
                            .background(entry.isImportant ? Color.yellow.opacity(0.05) : Color.clear)
                            .id(entry.id)
                        }

                        // ストリーミング仮テキスト
                        if !model.streamingText.isEmpty {
                            HStack(alignment: .top, spacing: 6) {
                                Text("...")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.orange)
                                    .frame(width: 55, alignment: .leading)
                                Text(model.streamingText)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .italic()
                            }
                            .padding(.horizontal, 12)
                            .id("streaming")
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: model.scrollToBottom) { _ in
                    if let last = model.entries.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .onReceive(timer) { _ in
            elapsed = Date().timeIntervalSince(startDate)
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func speakerColor(_ index: Int) -> Color {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan]
        return colors[index % colors.count]
    }
}
