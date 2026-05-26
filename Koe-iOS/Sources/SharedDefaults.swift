import Foundation

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
