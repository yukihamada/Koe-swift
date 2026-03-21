import SwiftUI

struct PhrasePaletteView: View {
    @ObservedObject private var manager = PhraseManager.shared
    @State private var newPhrase = ""
    @State private var editingIndex: Int?
    @State private var editingText = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField(L10n.addPhrase, text: $newPhrase)
                        .submitLabel(.done)
                        .onSubmit { addPhrase() }
                    Button {
                        addPhrase()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.orange)
                            .font(.title3)
                    }
                    .disabled(newPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section {
                if manager.phrases.isEmpty {
                    Text(L10n.noPhrases)
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(Array(manager.phrases.enumerated()), id: \.offset) { index, phrase in
                        if editingIndex == index {
                            HStack {
                                TextField(L10n.phrases, text: $editingText)
                                    .submitLabel(.done)
                                    .onSubmit { commitEdit(at: index) }
                                Button(L10n.save) { commitEdit(at: index) }
                                    .foregroundStyle(.orange)
                                    .font(.subheadline.weight(.medium))
                            }
                        } else {
                            Text(phrase)
                                .onTapGesture {
                                    editingIndex = index
                                    editingText = phrase
                                }
                        }
                    }
                    .onDelete { manager.delete(at: $0) }
                    .onMove { manager.move(from: $0, to: $1) }
                }
            } header: {
                Text(L10n.registeredPhrases)
            } footer: {
                if !manager.phrases.isEmpty {
                    Text(L10n.phraseEditHint)
                }
            }
        }
        .navigationTitle(L10n.phrasePaletteTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !manager.phrases.isEmpty {
                EditButton()
            }
        }
    }

    private func addPhrase() {
        manager.add(newPhrase)
        newPhrase = ""
    }

    private func commitEdit(at index: Int) {
        manager.update(at: index, to: editingText)
        editingIndex = nil
        editingText = ""
    }
}
