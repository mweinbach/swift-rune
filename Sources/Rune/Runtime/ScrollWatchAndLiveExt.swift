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
    var liveWake: LiveWake?
    var liveWaker: Waker?
    var liveSubscriptions: [LiveSubscription] = []
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

public extension Runtime {
    /// Installs a `Waker` for coalesced `Live` updates (`Runtime::set_live_waker`).
    func setLiveWaker(_ waker: Waker) {
        let slot = ParityRuntimeSideTable.shared.slot(for: self)
        for sub in slot.liveSubscriptions {
            sub.isActive = false
        }
        slot.liveSubscriptions.removeAll(keepingCapacity: true)
        slot.liveWaker = waker
        slot.liveWake = LiveWake { [weak waker] in
            waker?.wake()
        }
        slot.liveWake?.visible(liveVisible)
        refreshParityLiveSubscriptions()
    }

    /// Installs a closure wake callback for coalesced `Live` updates (`Runtime::set_live_waker`).
    func setLiveWaker(_ callback: @escaping @Sendable () -> Void) {
        setLiveWaker(Waker(callback))
    }

    /// Whether a visible `Live` notification is pending on this runtime's live wake
    /// (`Runtime::live_pending`).
    var livePending: Bool {
        let slot = ParityRuntimeSideTable.shared.slot(for: self)
        return slot.liveWake?.isVisiblePending ?? false
    }
}

internal extension Runtime {
    /// Re-subscribes active `Live` bindings and `LiveText` nodes to the installed `LiveWake`.
    func refreshParityLiveSubscriptions() {
        let slot = ParityRuntimeSideTable.shared.slot(for: self)
        guard let wake = slot.liveWake else { return }
        for sub in slot.liveSubscriptions {
            sub.isActive = false
        }
        slot.liveSubscriptions.removeAll(keepingCapacity: true)
        for node in flatNodes {
            if let lt = node.el.liveText {
                slot.liveSubscriptions.append(lt.subscribe(wake))
            }
            for b in node.el.liveBindings {
                slot.liveSubscriptions.append(b.source.subscribe(wake))
            }
            if let px = node.el.pixelsPayload {
                slot.liveSubscriptions.append(px.subscribe(wake))
            }
        }
    }

    /// Updates `LiveWake` visibility gating from `Runtime.setLiveVisible(_:at:)`.
    func setParityLiveWakeVisible(_ visible: Bool) {
        let slot = ParityRuntimeSideTable.shared.slot(for: self)
        slot.liveWake?.visible(visible)
    }

    /// Clears any pending visible latch on the installed `LiveWake` when a frame samples `Live` values.
    @discardableResult
    func takeParityLivePending() -> Bool {
        let slot = ParityRuntimeSideTable.shared.slot(for: self)
        return slot.liveWake?.takeVisible() ?? false
    }

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
