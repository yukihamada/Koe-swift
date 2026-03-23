import SwiftUI

struct CallTranscriberView: View {
    @StateObject private var transcriber = CallTranscriber.shared

    var body: some View {
        List {
            // 通話監視セクション
            Section {
                Toggle("通話の自動書き起こし", isOn: Binding(
                    get: { transcriber.autoRecord },
                    set: { transcriber.autoRecord = $0 }
                ))
                .onChange(of: transcriber.autoRecord) { newValue in
                    if newValue && !transcriber.isMonitoring {
                        transcriber.startMonitoring()
                    }
                }

                if transcriber.isMonitoring {
                    HStack {
                        Circle()
                            .fill(transcriber.isCallActive ? .red : .green)
                            .frame(width: 8, height: 8)
                        Text(transcriber.isCallActive ? "通話中" : "待機中")
                            .foregroundColor(.secondary)
                        Spacer()
                        if transcriber.isCallActive {
                            Text(formatDuration(transcriber.callDuration))
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }

                if transcriber.isRecording {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("録音中...")
                            .foregroundColor(.orange)
                    }
                }

                if transcriber.isTranscribing {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("文字起こし中...")
                            .foregroundColor(.blue)
                    }
                }
            } header: {
                Text("通話書き起こし")
            } footer: {
                Text("通話を検出すると自動でマイクから録音し、終了後にWhisperで文字起こしします。スピーカーホンにすると相手の声も拾えます。")
            }

            // 最新の書き起こし
            if !transcriber.transcribedText.isEmpty {
                Section("最新の書き起こし") {
                    Text(transcriber.transcribedText)
                        .font(.body)
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = transcriber.transcribedText
                    } label: {
                        Label("コピー", systemImage: "doc.on.doc")
                    }
                }
            }

            // 通話履歴
            if !transcriber.callHistory.isEmpty {
                Section("通話履歴") {
                    ForEach(transcriber.callHistory) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "phone.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                Text(entry.durationFormatted)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(entry.date, style: .date)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(entry.date, style: .time)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text(entry.text)
                                .font(.subheadline)
                                .lineLimit(3)
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = entry.text
                            } label: {
                                Label("コピー", systemImage: "doc.on.doc")
                            }
                            ShareLink(item: entry.text)
                        }
                    }
                }
            }
        }
        .navigationTitle("通話書き起こし")
        .onAppear {
            if transcriber.autoRecord && !transcriber.isMonitoring {
                transcriber.startMonitoring()
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
