import SwiftUI

struct MacScreenView: View {
    @ObservedObject private var macBridge = MacBridge.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack(spacing: 8) {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(.orange)
                    Text("Mac")
                        .fontWeight(.medium)
                    if !macBridge.activeAppName.isEmpty {
                        Text(macBridge.activeAppName)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle()
                        .fill(macBridge.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                Divider().opacity(0.3)

                if macBridge.isConnected {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // Screen context from LLM
                            if !macBridge.screenContext.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("画面の状況", systemImage: "eye")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.orange)

                                    Text(macBridge.screenContext)
                                        .font(.body)
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(16)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                            } else {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .tint(.orange)
                                    Text("画面を解析中...")
                                        .foregroundStyle(.secondary)
                                }
                                .padding(16)
                            }

                            // Quick actions
                            VStack(alignment: .leading, spacing: 8) {
                                Label("操作", systemImage: "hand.tap")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.orange)

                                LazyVGrid(columns: [
                                    GridItem(.flexible()),
                                    GridItem(.flexible()),
                                ], spacing: 8) {
                                    actionButton("⌘C コピー", command: "copy")
                                    actionButton("⌘V ペースト", command: "paste")
                                    actionButton("⌘Z 取消", command: "undo")
                                    actionButton("⌘Tab 切替", command: "nextTab")
                                    actionButton("⌘W 閉じる", command: "closeWindow")
                                    actionButton("Space 再生", command: "space")
                                }
                            }
                            .padding(16)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

                            // Active app info
                            if !macBridge.activeAppName.isEmpty {
                                HStack {
                                    Text("アクティブ:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(macBridge.activeAppName)
                                        .font(.caption.weight(.medium))
                                }
                                .padding(.horizontal, 4)
                            }
                        }
                        .padding(20)
                    }
                } else {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 48))
                            .foregroundStyle(.gray)
                        Text("Macに接続すると\n画面の状況が表示されます")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.gray)
                    }
                    Spacer()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func actionButton(_ title: String, command: String) -> some View {
        Button {
            MacBridge.shared.sendCommand(command)
        } label: {
            Text(title)
                .font(.caption.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
        }
    }
}
