import Foundation

public extension Notification.Name {
    /// Posted whenever the user picks a new value for the `koe_language` setting.
    /// Subscribers (e.g. WakeWordDetector) rebuild any locale-bound resources.
    static let koeLanguageDidChange = Notification.Name("koeLanguageDidChange")
}

/// Shared UserDefaults accessor backed by the App Group `group.com.yuki.koe`.
///
/// Use `UserDefaults.koeShared` for any preference that has to round-trip between
/// the host app and its extensions (keyboard, share, widget). Per-target private
/// keys should continue to use `UserDefaults.standard`.
public extension UserDefaults {
    static let koeShared: UserDefaults = {
        return UserDefaults(suiteName: "group.com.yuki.koe") ?? .standard
    }()
}

/// One-shot migration for v2.10.0 regression: `koe_language` moved from
/// `UserDefaults.standard` to `.koeShared`. Existing users would otherwise
/// see their language reset to the default ("ja-JP") because the new store
/// has no value yet. Idempotent — guarded by a flag in the shared store.
public func migrateKoeLanguageIfNeeded() {
    let migratedFlagKey = "koe_language_migrated_v2_10_1"
    let shared = UserDefaults.koeShared
    if shared.bool(forKey: migratedFlagKey) { return }
    if let legacy = UserDefaults.standard.string(forKey: "koe_language"),
       shared.string(forKey: "koe_language") == nil {
        shared.set(legacy, forKey: "koe_language")
    }
    shared.set(true, forKey: migratedFlagKey)
}
