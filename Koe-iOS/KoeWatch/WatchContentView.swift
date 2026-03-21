import SwiftUI

struct WatchContentView: View {
    @StateObject private var sessionManager = WatchSessionManager.shared

    var body: some View {
        VStack(spacing: 12) {
            // Connection status
            HStack(spacing: 6) {
                Circle()
                    .fill(sessionManager.isReachable ? .green : .gray)
                    .frame(width: 8, height: 8)
                Text(sessionManager.isReachable ? "iPhoneに接続中" : "未接続")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Last recognized text
            if !sessionManager.lastTranscription.isEmpty {
                Text(sessionManager.lastTranscription)
                    .font(.body)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            Spacer()

            // Record button
            Button {
                sessionManager.toggleRecording()
            } label: {
                ZStack {
                    Circle()
                        .fill(sessionManager.isRecording ? Color.red : Color.orange)
                        .frame(width: 64, height: 64)

                    if sessionManager.isRecording {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.white)
                            .frame(width: 22, height: 22)
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)

            // Status text
            Text(sessionManager.statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 8)
        .onAppear {
            sessionManager.activate()
        }
    }
}
