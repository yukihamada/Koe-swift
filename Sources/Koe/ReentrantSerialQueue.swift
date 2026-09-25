import Foundation

/// A serial `DispatchQueue` wrapper whose `syncOrInline` is safe to call even
/// from a block already running ON that queue — a plain `queue.sync` in that
/// situation dispatches synchronously onto the queue it is already running
/// on, which deadlocks (or traps, depending on the GCD build). That can
/// happen here if the last strong reference to a `WhisperContext`/
/// `LlamaContext` is released from inside a closure already executing on its
/// own `queue` (e.g. a `generate`/`transcribe` completion), triggering
/// `deinit` → `unload()` while still "on the queue".
///
/// Shared by `WhisperContext` and `LlamaContext`, whose `unload()` needs to:
/// (1) serialize with any in-flight/queued inference or model load (so it
/// doesn't free a `whisper_context*`/`llama_context*` out from under a call
/// still using it), and (2) not deadlock if it happens to already be running
/// on that same queue.
final class ReentrantSerialQueue {
    let queue: DispatchQueue
    private let key = DispatchSpecificKey<Void>()

    init(label: String, qos: DispatchQoS = .userInitiated) {
        queue = DispatchQueue(label: label, qos: qos)
        queue.setSpecific(key: key, value: ())
    }

    func async(_ block: @escaping () -> Void) {
        queue.async(execute: block)
    }

    /// Runs `block` synchronously "on" `queue`: inline, without dispatching,
    /// if the caller is already executing on `queue` (avoiding the
    /// self-`dispatch_sync` deadlock); a normal `queue.sync` otherwise.
    func syncOrInline(_ block: () -> Void) {
        if DispatchQueue.getSpecific(key: key) != nil {
            block()
        } else {
            queue.sync(execute: block)
        }
    }
}
