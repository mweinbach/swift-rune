import Foundation
import RuneMotion

// MARK: - scrollWatchState (`crates/rune/src/runtime/scroll/watch.rs`)

/// Scroll callback context available during `El.onScrollOffset` execution
/// (`rune::runtime::scroll::watch::ScrollWatchState`).
public struct ScrollWatchState: Sendable, Equatable {
    public var active: Bool
    public var scrolled: Bool

    public init(active: Bool = false, scrolled: Bool = false) {
        self.active = active
        self.scrolled = scrolled
    }
}

private enum ScrollWatchTLS {
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
    var lastReportedOffsets: [String: Vec2] = [:]

    init(runtime: AnyObject) {
        self.runtimeRef = runtime
    }
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

    /// Invokes `handler(pos)` under `scrollWatchState()` indicating `active = true` and whether
    /// `path` moved by hand since the previous delivery.
    func dispatchScrollOffsetWithWatch(
        path: String,
        pos: ScrollPos,
        handler: (ScrollPos) -> Void
    ) {
        let slot = ParityRuntimeSideTable.shared.slot(for: self)
        let byHand = slot.movedByHandPaths.remove(path) != nil
        let prev = slot.lastReportedOffsets[path]
        slot.lastReportedOffsets[path] = pos.offset
        let scrolled = byHand && prev.map {
            abs($0.x - pos.offset.x) > 0.01 || abs($0.y - pos.offset.y) > 0.01
        } ?? false
        ScrollWatchTLS.$current.withValue(ScrollWatchState(active: true, scrolled: scrolled)) {
            handler(pos)
        }
    }
}
