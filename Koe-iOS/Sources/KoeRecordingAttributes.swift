import ActivityKit
import Foundation

struct KoeRecordingAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var isRecording: Bool
        var statusText: String
        var audioLevel: Double
    }
    var startTime: Date
}
