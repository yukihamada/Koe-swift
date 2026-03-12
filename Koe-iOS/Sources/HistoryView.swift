import SwiftUI

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var recorder: RecordingManager

    var body: some View {
        NavigationStack {
            Group {
                if recorder.history.isEmpty {
                    ContentUnavailableView(
                        "履歴がありません",
                        systemImage: "clock",
                        description: Text("音声入力するとここに表示されます")
                    )
                } else {
                    List(recorder.history) { item in
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
                }
            }
            .navigationTitle("履歴")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !recorder.history.isEmpty {
                        Button("全削除", role: .destructive) {
                            recorder.clearHistory()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}
