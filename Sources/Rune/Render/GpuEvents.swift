import Foundation

/// Lifecycle events emitted for GPU startup and first present (`crates/rune/src/render/gpu_events.rs`).
public enum GpuEvent: Sendable, Equatable {
    case starting
    case drew
}

/// Opaque handle returned by `onGpu(_:)` so callers/tests can unregister a listener.
public struct GpuEventListenerToken: Hashable, Sendable {
    fileprivate let id: UInt64
}

/// Global GPU startup/present event bus matching `gpu_events::{on_gpu, starting, presented}`.
public enum GpuEvents {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var pending = false
        var nextID: UInt64 = 1
        var listeners: [(id: UInt64, cb: @Sendable (GpuEvent) -> Void)] = []
    }

    private static let state = State()

    /// Registers a listener for GPU lifecycle events.
    @discardableResult
    public static func onGpu(_ listener: @escaping @Sendable (GpuEvent) -> Void) -> GpuEventListenerToken {
        state.lock.lock()
        let id = state.nextID
        state.nextID &+= 1
        state.listeners.append((id: id, cb: listener))
        state.lock.unlock()
        return GpuEventListenerToken(id: id)
    }

    /// Removes a previously registered listener.
    public static func removeListener(_ token: GpuEventListenerToken) {
        state.lock.lock()
        state.listeners.removeAll { $0.id == token.id }
        state.lock.unlock()
    }

    /// Signals that GPU initialization / warm-up is starting and marks the next present as the first draw.
    public static func starting() {
        state.lock.lock()
        state.pending = true
        let snapshot = state.listeners.map(\.cb)
        state.lock.unlock()
        for cb in snapshot {
            cb(.starting)
        }
    }

    /// Signals that a frame (or warmup clear) was presented; emits `.drew` once per `starting()`.
    public static func presented() {
        state.lock.lock()
        let shouldEmit = state.pending
        state.pending = false
        let snapshot = shouldEmit ? state.listeners.map(\.cb) : []
        state.lock.unlock()
        for cb in snapshot {
            cb(.drew)
        }
    }

    /// Clears pending flag and registered listeners (for deterministic unit tests).
    public static func resetForTesting() {
        state.lock.lock()
        state.pending = false
        state.listeners.removeAll()
        state.lock.unlock()
    }
}

/// Top-level convenience matching `render::on_gpu`.
@discardableResult
public func onGpu(_ listener: @escaping @Sendable (GpuEvent) -> Void) -> GpuEventListenerToken {
    GpuEvents.onGpu(listener)
}
