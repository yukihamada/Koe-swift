import Foundation

/// プロセス内で生成された全インスタンスを弱参照で追跡する汎用レジストリ。
///
/// `WhisperContext`/`LlamaContext` はどちらも `.shared` シングルトン以外に、
/// `SettingsWindowController` の再認識機能 (rerecognizeEntry/batchRerecognize)
/// のように独自の非共有インスタンスを作れる。アプリ終了時に `.shared` だけ
/// `unloadForTermination()` しても、これら非共有インスタンスが保持する
/// Metal-backed context が誰にも free されないまま残り、`__cxa_finalize`
/// 時の `ggml_metal_device_free` abort (2026-09-19 のクラッシュ) が
/// これらのインスタンスについて再発しうる — このレジストリはそれを防ぐため、
/// 生成された全インスタンスを追跡し、終了処理が一括で `unloadForTermination`
/// 相当を呼べるようにする。
///
/// 弱参照のみを保持するため、通常のライフサイクル（インスタンスが解放されれば
/// レジストリからも自然に消える）には影響しない。
final class WeakInstanceRegistry<T: AnyObject> {
    private let lock = NSLock()
    private var boxes: [WeakBox] = []

    private final class WeakBox {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }

    /// 生成時 (init) に自分自身を登録する。呼び出し側は何もする必要がない。
    func register(_ instance: T) {
        lock.lock()
        defer { lock.unlock() }
        boxes.removeAll { $0.value == nil }
        boxes.append(WeakBox(instance))
    }

    /// 現在も生きている全インスタンスのスナップショットを返す。
    func snapshot() -> [T] {
        lock.lock()
        defer { lock.unlock() }
        return boxes.compactMap { $0.value }
    }
}
