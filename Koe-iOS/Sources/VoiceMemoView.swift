import SwiftUI

struct VoiceMemoView: View {
    @ObservedObject var recorder: RecordingManager
    @State private var searchText = ""

    private var filteredHistory: [HistoryItem] {
        if searchText.isEmpty { return recorder.history }
        return recorder.history.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            ForEach(filteredHistory) { item in
                VStack(alignment: .leading, spacing: 4) {
                    highlightedText(item.text, highlight: searchText)
                        .font(.subheadline)
                    Text(item.date, format: .dateTime.month().day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
                .swipeActions {
                    Button {
                        UIPasteboard.general.string = item.text
                    } label: {
                        Label("コピー", systemImage: "doc.on.doc")
                    }
                    .tint(.blue)

                    ShareLink(item: item.text) {
                        Label("共有", systemImage: "square.and.arrow.up")
                    }
                    .tint(.green)
                }
            }
        }
        .searchable(text: $searchText, prompt: "テキストを検索…")
        .navigationTitle("音声メモ検索")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if filteredHistory.isEmpty && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    @ViewBuilder
    private func highlightedText(_ text: String, highlight: String) -> some View {
        if highlight.isEmpty {
            Text(text)
        } else {
            let parts = text.components(separatedBy: highlight)
            if parts.count <= 1 {
                Text(text)
            } else {
                parts.enumerated().reduce(Text("")) { result, item in
                    if item.offset == 0 {
                        return Text(item.element)
                    } else {
                        return result + Text(highlight).bold().foregroundColor(.orange) + Text(item.element)
                    }
                }
            }
        }
    }
}
