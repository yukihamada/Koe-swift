import SwiftUI
import UIKit

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
                                    Label(L10n.screenStatus, systemImage: "eye")
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
                                    Text(L10n.analyzingScreen)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(16)
                            }

                            // Suggestion chips
                            if !macBridge.suggestions.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(L10n.nextAction, systemImage: "sparkles")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.orange)

                                    VStack(spacing: 6) {
                                        ForEach(macBridge.suggestions, id: \.self) { suggestion in
                                            Button {
                                                MacBridge.shared.sendText(suggestion)
                                                let gen = UIImpactFeedbackGenerator(style: .light)
                                                gen.impactOccurred()
                                            } label: {
                                                Text(suggestion)
                                                    .font(.body)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .padding(.horizontal, 14)
                                                    .padding(.vertical, 10)
                                                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                                                    .foregroundStyle(.white)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                                .padding(16)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                            }

                            // Quick actions
                            VStack(alignment: .leading, spacing: 8) {
                                Label(L10n.operations, systemImage: "hand.tap")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.orange)

                                LazyVGrid(columns: [
                                    GridItem(.flexible()),
                                    GridItem(.flexible()),
                                ], spacing: 8) {
                                    actionButton(L10n.copyAction, command: "copy")
                                    actionButton(L10n.pasteAction, command: "paste")
                                    actionButton(L10n.undoAction, command: "undo")
                                    actionButton(L10n.switchTab, command: "nextTab")
                                    actionButton(L10n.closeWindow, command: "closeWindow")
                                    actionButton(L10n.spacePlay, command: "space")
                                }
                            }
                            .padding(16)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

                            // Active app info
                            if !macBridge.activeAppName.isEmpty {
                                HStack {
                                    Text(L10n.active)
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
                        Text(L10n.macDisconnectedMessage)
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
