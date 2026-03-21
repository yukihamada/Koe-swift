import SwiftUI

struct MoreView: View {
    @StateObject private var modelManager = ModelManager.shared
    @ObservedObject private var macBridge = MacBridge.shared
    @AppStorage("koe_screen_context") private var screenContextEnabled = false
    @AppStorage("koe_phrase_palette") private var phrasePaletteEnabled = false
    @AppStorage("koe_watch_enabled") private var watchEnabled = false
    @AppStorage("koe_always_listening") private var alwaysListening = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: - 音声アシスタント
                Section {
                    Toggle(L10n.alwaysListening, isOn: $alwaysListening)
                } header: {
                    Label(L10n.voiceAssistant, systemImage: "ear")
                } footer: {
                    Text(L10n.alwaysListeningFooter)
                }

                // MARK: - Mac連携
                if macBridge.isConnected {
                    Section {
                        Toggle(L10n.macScreenContext, isOn: $screenContextEnabled)
                    } header: {
                        Label(L10n.macLink, systemImage: "desktopcomputer")
                    } footer: {
                        Text(L10n.macScreenContextFooter)
                    }
                }

                // MARK: - 定型文パレット
                Section {
                    Toggle(L10n.phrasePalette, isOn: $phrasePaletteEnabled)
                    if phrasePaletteEnabled {
                        NavigationLink {
                            PhrasePaletteView()
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L10n.managePhrases)
                                    Text(L10n.managePhrasesSubtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "text.bubble")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                } header: {
                    Label(L10n.phrases, systemImage: "text.bubble")
                } footer: {
                    Text(L10n.phraseFooter)
                }

                // MARK: - 機能
                Section {
                    NavigationLink {
                        MeetingView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.meetingNotes)
                                Text(L10n.meetingNotesSubtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.orange)
                        }
                    }

                    NavigationLink {
                        ConversationView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.faceToFaceTranslation)
                                Text(L10n.faceToFaceSubtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .foregroundStyle(.blue)
                        }
                    }

                    NavigationLink {
                        AudioToolsView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.audioTools)
                                Text(L10n.audioToolsSubtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "waveform")
                                .foregroundStyle(.purple)
                        }
                    }
                } header: {
                    Label(L10n.features, systemImage: "square.grid.2x2")
                }

                // MARK: - Apple Watch
                Section {
                    Toggle(L10n.appleWatch, isOn: $watchEnabled)
                        .onChange(of: watchEnabled) { _, enabled in
                            if enabled {
                                WatchRelay.shared.start()
                            }
                        }
                } header: {
                    Label("Apple Watch", systemImage: "applewatch")
                } footer: {
                    Text(L10n.appleWatchFooter)
                }

                // MARK: - 実験的
                Section {
                    NavigationLink {
                        SolunaView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Soluna")
                                Text(L10n.p2pAudioNetwork)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .foregroundStyle(.cyan)
                        }
                    }

                    NavigationLink {
                        SoundMemoryView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sound Memory")
                                Text(L10n.soundPatternRecognition)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "brain.head.profile")
                                .foregroundStyle(.pink)
                        }
                    }
                } header: {
                    Label(L10n.experimental, systemImage: "flask")
                }

                // MARK: - Feedback
                Section {
                    NavigationLink {
                        FeedbackHistoryView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Feedback History")
                                Text("\(FeedbackManager.shared.entries.count) entries")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.bubble")
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Label("Feedback", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                }

                // MARK: - About
                Section {
                    LabeledContent(L10n.version,
                        value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                    Link(destination: URL(string: "https://app.koe.live")!) {
                        Label(L10n.website, systemImage: "globe")
                    }
                }
            }
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}
