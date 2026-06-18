import SwiftUI

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var recorder: RecordingManager
    @ObservedObject private var tts = KoeTTS.shared
    @State private var searchText = ""

    private var filteredHistory: [HistoryItem] {
        recorder.searchHistory(searchText)
    }

    var body: some View {
        NavigationStack {
            Group {
                if recorder.history.isEmpty {
                    ContentUnavailableView(
                        L10n.noHistory,
                        systemImage: "clock",
                        description: Text(L10n.historyEmpty)
                    )
                } else {
                    List(filteredHistory) { item in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.text)
                                    .font(.body)
                                Text(item.date, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            // 本人声で再生
                            Button {
                                Task { await tts.speakInMyVoice(item.text) }
                            } label: {
                                Image(systemName: "person.wave.2.fill")
                                    .font(.system(size: 17))
                                    .foregroundStyle(.orange)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            UIPasteboard.general.string = item.text
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                Task { await tts.speakInMyVoice(item.text) }
                            } label: { Label("本人声", systemImage: "person.wave.2.fill") }
                            .tint(.orange)
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                UIPasteboard.general.string = item.text
                            } label: { Label("コピー", systemImage: "doc.on.doc") }
                            .tint(.blue)
                        }
                    }
                    .searchable(text: $searchText, prompt: L10n.searchHistory)
                }
            }
            .navigationTitle(L10n.history)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !recorder.history.isEmpty {
                        Button(L10n.deleteAll, role: .destructive) {
                            recorder.clearHistory()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.close) { dismiss() }
                }
            }
        }
    }
}
