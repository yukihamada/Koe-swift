import SwiftUI

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var recorder: RecordingManager
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
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.text)
                                .font(.body)
                            Text(item.date, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            UIPasteboard.general.string = item.text
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
