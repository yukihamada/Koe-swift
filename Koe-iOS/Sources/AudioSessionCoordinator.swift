import Foundation
import AVFoundation

/// Single source of truth for `AVAudioSession` category transitions.
///
/// Several engines (foreground recording, wake-word detection, sound-memory capture,
/// call bridge) used to call `setCategory(_:mode:options:)` directly. When two of
/// them ran concurrently the last writer would clobber the other engine's category,
/// often muting it or invalidating its input format mid-stream.
///
/// The coordinator tracks the set of currently active `Intent`s and applies the
/// widest-compatible category + mode + options for the union. It only invokes
/// `setCategory(_:mode:options:)` when the resulting parameters actually change,
/// so engines that already share a compatible session don't get re-armed.
@MainActor
public final class AudioSessionCoordinator {

    public static let shared = AudioSessionCoordinator()

    public enum Intent: Hashable {
        case record
        case wakeWord
        case soundMemory
        case callBridge
    }

    // MARK: - State

    private var active: Set<Intent> = []
    private var lastApplied: AppliedConfig?

    private struct AppliedConfig: Equatable {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }

    private init() {}

    // MARK: - Public API

    /// Register an intent. If the resulting widest-superset session differs from
    /// the currently applied one, `setCategory(_:mode:options:)` is called and the
    /// session is activated.
    public func acquire(_ intent: Intent) throws {
        active.insert(intent)
        try applyIfNeeded(activate: true)
    }

    /// Drop an intent. The category is recomputed for the remaining active intents
    /// — if any. When the active set becomes empty the session is left configured
    /// as-is (deactivating mid-mix can cause audible glitches for other apps).
    public func release(_ intent: Intent) {
        active.remove(intent)
        // Recompute but don't reactivate; engines that are stopping don't need the
        // session armed. We still call setCategory so subsequent acquire() calls
        // start from a clean baseline.
        try? applyIfNeeded(activate: false)
    }

    // MARK: - Resolution

    private func applyIfNeeded(activate: Bool) throws {
        guard !active.isEmpty else { return }

        let resolved = resolve(active)
        if resolved != lastApplied {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(resolved.category, mode: resolved.mode, options: resolved.options)
            lastApplied = resolved
        }

        if activate {
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        }
    }

    /// Compute the widest-compatible category for the union of active intents.
    ///
    /// Rules (chosen to preserve existing behaviour from each call site):
    /// - Anything that needs playback (`wakeWord`, `callBridge`) forces
    ///   `.playAndRecord`. Pure capture intents fall back to `.record`.
    /// - `.callBridge` wins mode selection (`.voiceChat` for echo cancellation).
    ///   Otherwise `.measurement` keeps latency low for ASR engines.
    /// - Options are unioned. `.defaultToSpeaker` and `.allowBluetooth` only
    ///   apply when we are in `.playAndRecord`; they are illegal on `.record`.
    private func resolve(_ intents: Set<Intent>) -> AppliedConfig {
        let needsPlayback = intents.contains(.wakeWord) || intents.contains(.callBridge)
        let category: AVAudioSession.Category = needsPlayback ? .playAndRecord : .record

        let mode: AVAudioSession.Mode
        if intents.contains(.callBridge) {
            mode = .voiceChat
        } else {
            mode = .measurement
        }

        var options: AVAudioSession.CategoryOptions = [.duckOthers]
        if needsPlayback {
            options.insert(.defaultToSpeaker)
            if intents.contains(.callBridge) {
                options.insert(.allowBluetooth)
            }
        }

        return AppliedConfig(category: category, mode: mode, options: options)
    }
}
