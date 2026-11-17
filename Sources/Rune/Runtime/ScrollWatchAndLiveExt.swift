import Foundation
import RuneMotion

// MARK: - scrollWatchState (`crates/rune/src/runtime/scroll/watch.rs`)

/// Scroll callback context available during `El.onScrollOffset` execution
/// (`rune::runtime::scroll::watch::ScrollWatchState`).
public struct ScrollWatchState: Sendable, Equatable {
    public var active: Bool
    public var scrolled: Bool
    public var instant: Bool
    public var now: Double

    public init(active: Bool = false, scrolled: Bool = false, instant: Bool = false, now: Double = 0.0) {
        self.active = active
        self.scrolled = scrolled
        self.instant = instant
        self.now = now
    }
}

internal enum ScrollWatchTLS {
    @TaskLocal static var current = ScrollWatchState()
}

/// Returns whether the caller is currently inside an `onScrollOffset` notification and whether
/// a user/direct scroll caused the offset change since the last notification.
public func scrollWatchState() -> ScrollWatchState {
    ScrollWatchTLS.current
}

// MARK: - Per-Runtime Parity State (LiveWake + Scroll By-Hand Tracking)

private final class ParityRuntimeSlot: @unchecked Sendable {
    weak var runtimeRef: AnyObject?
    var movedByHandPaths: Set<String> = []
    var handGlidingPaths: Set<String> = []
    var lastReportedOffsets: [String: Vec2] = [:]
    var lastScrollHandlerTokens: [String: UInt64] = [:]

    init(runtime: AnyObject) {
        self.runtimeRef = runtime
    }
}

private enum ScrollOffsetTokenAllocator {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var counter: UInt64 = 1

    static func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let out = counter
        counter &+= 1
        if counter == 0 { counter = 1 }
        return out
    }
}

@usableFromInline
internal func allocateScrollOffsetHandlerToken() -> UInt64 {
    ScrollOffsetTokenAllocator.next()
}

private final class ParityRuntimeSideTable: @unchecked Sendable {
    static let shared = ParityRuntimeSideTable()
    private let lock = NSLock()
    private var slots: [ObjectIdentifier: ParityRuntimeSlot] = [:]

    func slot(for runtime: AnyObject) -> ParityRuntimeSlot {
        let key = ObjectIdentifier(runtime)
        lock.lock()
        defer { lock.unlock() }
        if slots.count > 64 {
            slots = slots.filter { $0.value.runtimeRef != nil }
        }
        if let existing = slots[key], existing.runtimeRef === runtime {
            return existing
        }
        let created = ParityRuntimeSlot(runtime: runtime)
        slots[key] = created
        return created
    }
}

internal extension Runtime {
    /// Marks `path` as moved by user/direct scroll since the last `onScrollOffset` delivery.
    func markScrollMovedByHand(path: String) {
        let slot = ParityRuntimeSideTable.shared.slot(for: self)
        slot.movedByHandPaths.insert(path)
    }

    /// Marks `path` as actively running a hand-initiated glide (`scrollPage` / hand `offsets`).
    func markScrollHandGliding(path: String) {
        let slot = ParityRuntimeSideTable.shared.slot(for: self)
        slot.handGlidingPaths.insert(path)
    }

    /// Clears `path` from the active hand-initiated glide set.
    func clearScrollHandGliding(path: String) {
        let slot = ParityRuntimeSideTable.shared.slot(for: self)
        slot.handGlidingPaths.remove(path)
    }

    /// Clears all active hand-initiated glide paths.
    func clearAllScrollHandGliding() {
        let slot = ParityRuntimeSideTable.shared.slot(for: self)
        slot.handGlidingPaths.removeAll(keepingCapacity: true)
    }

    /// Returns whether `path` is actively running a hand-initiated glide.
    func isScrollHandGliding(path: String) -> Bool {
        let slot = ParityRuntimeSideTable.shared.slot(for: self)
        return slot.handGlidingPaths.contains(path)
    }

    /// Returns `true` when `token` differs from the previously notified scroll handler on `path`
    /// (`watch.rs::new_handler`).
    func consumeNewScrollOffsetHandlerToken(path: String, token: UInt64) -> Bool {
        guard token != 0 else { return false }
        let slot = ParityRuntimeSideTable.shared.slot(for: self)
        if slot.lastScrollHandlerTokens[path] != token {
            slot.lastScrollHandlerTokens[path] = token
            return true
        }
        return false
    }

    /// Invokes `handler(pos)` under `scrollWatchState()` indicating `active = true`, whether
    /// `path` moved by hand since the previous delivery, whether the commit was instant/settled,
    /// and the current scene animation clock `now`.
    func dispatchScrollOffsetWithWatch(
        path: String,
        pos: ScrollPos,
        instant: Bool = false,
        now: Double = 0.0,
        handler: (ScrollPos) -> Void
    ) {
        let slot = ParityRuntimeSideTable.shared.slot(for: self)
        let byHand = slot.movedByHandPaths.remove(path) != nil
        let prev = slot.lastReportedOffsets[path]
        slot.lastReportedOffsets[path] = pos.offset
        let scrolled = byHand && prev.map {
            abs($0.x - pos.offset.x) > 0.01 || abs($0.y - pos.offset.y) > 0.01
        } ?? false
        ScrollWatchTLS.$current.withValue(ScrollWatchState(active: true, scrolled: scrolled, instant: instant, now: now)) {
            handler(pos)
        }
    }
}
