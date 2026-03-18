import WidgetKit
import SwiftUI
import ActivityKit

// MARK: - Shared type (duplicated here; main app has same definition in Sources/)
struct KoeRecordingAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var isRecording: Bool
        var statusText: String
        var audioLevel: Double
    }
    var startTime: Date
}

// MARK: - Simple Launch Widget

struct KoeWidgetEntry: TimelineEntry {
    let date: Date
}

struct KoeWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> KoeWidgetEntry { KoeWidgetEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (KoeWidgetEntry) -> Void) {
        completion(KoeWidgetEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<KoeWidgetEntry>) -> Void) {
        completion(Timeline(entries: [KoeWidgetEntry(date: Date())], policy: .never))
    }
}

struct KoeWidgetEntryView: View {
    var entry: KoeWidgetEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        Link(destination: URL(string: "koe://transcribe")!) {
            ZStack {
                Color.black
                VStack(spacing: 6) {
                    Image(systemName: "mic.circle.fill")
                        .font(.system(size: family == .systemSmall ? 36 : 28))
                        .foregroundStyle(.red)
                    if family != .systemSmall {
                        Text("声で入力")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .containerBackground(.black, for: .widget)
    }
}

@main
struct KoeWidgetBundle: WidgetBundle {
    var body: some Widget {
        KoeLaunchWidget()
        KoeRecordingActivityWidget()
    }
}

struct KoeLaunchWidget: Widget {
    let kind = "KoeLaunchWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: KoeWidgetProvider()) { entry in
            KoeWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Koe 音声入力")
        .description("タップして音声入力を開始")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

// MARK: - Live Activity / Dynamic Island Widget

struct KoeRecordingActivityWidget: Widget {
    let kind = "KoeRecordingActivity"
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: KoeRecordingAttributes.self) { context in
            // Lock screen / banner
            HStack(spacing: 12) {
                Image(systemName: context.state.isRecording ? "mic.fill" : "waveform")
                    .foregroundStyle(context.state.isRecording ? .red : .green)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Koe")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(context.state.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if context.state.isRecording {
                    Text(context.attributes.startTime, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.red)
                }
            }
            .padding()
            .background(.black)
            .activityBackgroundTint(.black)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.red)
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startTime, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            } compactTrailing: {
                Text(context.attributes.startTime, style: .timer)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.red)
            } minimal: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
                    .font(.caption2)
            }
        }
    }
}
