import SwiftUI

struct MeetingView: View {
    @StateObject private var meeting = MeetingManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // Timer
            HStack {
                Image(systemName: meeting.isRecording ? "record.circle" : "stop.circle")
                    .foregroundStyle(meeting.isRecording ? .red : .secondary)
                Text(formatTime(meeting.elapsedTime))
                    .font(.title2.monospacedDigit())
                Spacer()
                Text("\(meeting.entries.count) segments")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            // Transcript
            if meeting.entries.isEmpty && !meeting.isRecording {
                ContentUnavailableView(L10n.meetingNotes, systemImage: "doc.text", description: Text(L10n.meetingEmpty))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(meeting.entries) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    let mins = Int(entry.timestamp) / 60
                                    let secs = Int(entry.timestamp) % 60
                                    Text(String(format: "%02d:%02d", mins, secs))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 40)
                                    Text(entry.text)
                                        .font(.subheadline)
                                }
                                .id(entry.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: meeting.entries.count) { _, _ in
                        if let last = meeting.entries.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }

            // Summary
            if !meeting.summary.isEmpty {
                Divider()
                ScrollView {
                    Text(meeting.summary)
                        .font(.subheadline)
                        .padding()
                }
                .frame(maxHeight: 200)
                .background(.ultraThinMaterial)
            }

            if meeting.isSummarizing {
                HStack {
                    ProgressView()
                    Text(L10n.generatingSummary)
                        .font(.caption)
                }
                .padding(8)
            }

            Divider()

            // Controls
            HStack(spacing: 20) {
                if meeting.isRecording {
                    Button {
                        meeting.stopMeeting()
                    } label: {
                        Label(L10n.stop, systemImage: "stop.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(.red, in: Capsule())
                    }
                } else {
                    Button {
                        meeting.startMeeting()
                    } label: {
                        Label(L10n.startRecording, systemImage: "record.circle")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(.red, in: Capsule())
                    }
                }

                if !meeting.entries.isEmpty && !meeting.isRecording {
                    ShareLink(item: meeting.summary.isEmpty ? meeting.fullTranscript : "\(meeting.summary)\n\n---\n\n\(meeting.fullTranscript)") {
                        Label(L10n.share, systemImage: "square.and.arrow.up")
                    }
                }
            }
            .padding()
        }
        .navigationTitle(L10n.meetingNotes)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let mins = Int(t) / 60
        let secs = Int(t) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}
