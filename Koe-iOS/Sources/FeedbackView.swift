import SwiftUI

struct FeedbackView: View {
    let screenName: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = FeedbackManager.shared
    @State private var feedbackText = ""
    @State private var submitted = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if submitted {
                    thankYouView
                } else {
                    formView
                }
            }
            .padding()
            .navigationTitle("Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    // MARK: - Form

    private var formView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Screen name label
            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Screen: \(screenName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Text input
            TextEditor(text: $feedbackText)
                .frame(minHeight: 120)
                .padding(8)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    Group {
                        if feedbackText.isEmpty {
                            Text("What's on your mind?")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 12)
                                .padding(.top, 16)
                                .allowsHitTesting(false)
                        }
                    },
                    alignment: .topLeading
                )

            // Submit button
            Button {
                guard !feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                manager.submit(screenName: screenName, text: feedbackText.trimmingCharacters(in: .whitespacesAndNewlines))
                withAnimation(.easeInOut(duration: 0.3)) {
                    submitted = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    dismiss()
                }
            } label: {
                Text("Submit")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.gray : Color.orange,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
            }
            .disabled(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Spacer()
        }
    }

    // MARK: - Thank You

    private var thankYouView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: submitted)
            Text("Thank you!")
                .font(.title2.weight(.semibold))
            Text("Your feedback helps improve Koe.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .transition(.scale.combined(with: .opacity))
    }
}

// MARK: - Feedback History View (for MoreView)

struct FeedbackHistoryView: View {
    @ObservedObject private var manager = FeedbackManager.shared
    @State private var showExportSheet = false

    var body: some View {
        List {
            if manager.entries.isEmpty {
                ContentUnavailableView(
                    "No Feedback Yet",
                    systemImage: "bubble.left",
                    description: Text("Your submitted feedback will appear here.")
                )
            } else {
                ForEach(manager.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(entry.screenName)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                                .foregroundStyle(.orange)
                            Spacer()
                            Text(entry.timestamp, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(entry.text)
                            .font(.subheadline)
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { offsets in
                    manager.deleteEntry(at: offsets)
                }
            }
        }
        .navigationTitle("Feedback History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !manager.entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ShareLink(item: manager.exportText()) {
                            Label("Export All", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            manager.clearAll()
                        } label: {
                            Label("Delete All", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }
}
