import Foundation
import RuneMotion

// MARK: - Slice 2 Runtime State & Wiring (Scroll Core, WheelLock, Touch, Nudge, PixelHold, ScrollMode, Tx Actions)

/// Host touch phase (`crates/rune/src/runtime/input/touch.rs::TouchPhase`).
public enum TouchPhase: Sendable, Equatable {
    case started
    case moved
    case ended
    case cancelled
}

/// Consolidated runtime state for Slice 2 parity features (kept out of `Runtime.swift` body).
internal final class Slice2RuntimeState {
    struct TouchFinger: Equatable {
        var id: UInt64
        var origin: Vec2
        var last: Float
        var at: Double
        var velocity: Float
        var mode: Mode

        enum Mode: Equatable {
            case pending(scroll: NodeId?)
            case drag
            case pan(scroll: NodeId, horizontal: Bool)

            var scroll: NodeId? {
                switch self {
                case .pending(let id): return id
                case .pan(let id, _): return id
                case .drag: return nil
                }
            }

            var horizontal: Bool {
                if case .pan(_, let h) = self { return h }
                return false
            }
        }
    }

    var wheelLock = WheelLock()
    var touchScroll: TouchScroll? = nil
    var touchFinger: TouchFinger? = nil
    var touchOverscrollX: [String: Float] = [:]
    var touchOverscrollY: [String: Float] = [:]

    var scrollModes: [String: ScrollMode] = [:]
    var scrollSlacks: [String: ScrollSlack] = [:]
    var scrollHeldByPath: [String: Bool] = [:]
    var scrollExtraYByPath: [String: Float] = [:]
    var growthGrownByScrollPath: [String: Float] = [:]
    var scrollLastSlackTickAt: Double? = nil
    var scrollWatches: [String: ScrollWatch.Watch] = [:]
    var scrollNudges: [String: ScrollNudge] = [:]
    var pixelHolds: [String: PixelHold] = [:]
    var scrollHorizontalVelocities: [String: Float] = [:]
    var growthStackOrders: [NodeId: [NodeId]] = [:]
    var growthRowReorder: [NodeId: VirtualRowReorder] = [:]
    var virtualSelectionHosts: [String: VirtualListSelectionHost] = [:]
    var virtualSelectionAnchorState = VirtualSelectionAnchorState()
    var unclampedBottomByPath: [String: Float] = [:]
    var foldHeaderByGrowthKey: [String: String] = [:]
    var growthScrollByKey: [String: String] = [:]
    var growthRowPathByKey: [String: String] = [:]
    var virtualFillWantsDraw: Bool = false

    var tracingEnabled: Bool = false
    var traceEvents: [String] = []
    var traceChannels: [(name: String, kind: String, value: Float)] = []
    var assistiveTechnologyActive: Bool = false

    var dragRepeatFiringNow: Bool = false

    var currentInputTime: Double? = nil
    var currentKeyRepeat: Bool = false
    var currentPhysicalKey: PhysicalKeyCode? = nil
    var currentKeyBase: Character? = nil
    var currentMods: Mods = .none
    var currentByKeys: Bool = false

    var announcements: [(text: String, politeness: LiveRegionPoliteness)] = []
    var toggleMaximizedRequested: Bool = false
    var toggleFullScreenRequested: Bool = false
    var lastShellRequest: Shell? = nil
    var customFontFamilies: (sans: String, mono: String)? = nil
    var pendingTxFocusVisible: Bool? = nil
    var lastPressedPhysicalKey: PhysicalKeyCode? = nil
    var lastPressedKeyBase: Character? = nil
}

internal func slice2DefaultKeyBase(for code: PhysicalKeyCode, fallbackKey: KeyEvent? = nil) -> Character? {
    if let fk = fallbackKey, case .text(let s) = fk.key, s.count == 1 {
        return s.first
    }
    switch code {
    case .keyA: return "a"; case .keyB: return "b"; case .keyC: return "c"; case .keyD: return "d"
    case .keyE: return "e"; case .keyF: return "f"; case .keyG: return "g"; case .keyH: return "h"
    case .keyI: return "i"; case .keyJ: return "j"; case .keyK: return "k"; case .keyL: return "l"
    case .keyM: return "m"; case .keyN: return "n"; case .keyO: return "o"; case .keyP: return "p"
    case .keyQ: return "q"; case .keyR: return "r"; case .keyS: return "s"; case .keyT: return "t"
    case .keyU: return "u"; case .keyV: return "v"; case .keyW: return "w"; case .keyX: return "x"
    case .keyY: return "y"; case .keyZ: return "z"
    case .digit0: return "0"; case .digit1: return "1"; case .digit2: return "2"; case .digit3: return "3"
    case .digit4: return "4"; case .digit5: return "5"; case .digit6: return "6"; case .digit7: return "7"
    case .digit8: return "8"; case .digit9: return "9"
    case .space: return " "
    case .minus: return "-"; case .equal: return "="; case .bracketLeft: return "["; case .bracketRight: return "]"
    case .backslash: return "\\"; case .semicolon: return ";"; case .quote: return "'"; case .backquote: return "`"
    case .comma: return ","; case .period: return "."; case .slash: return "/"
    default: return nil
    }
}

private enum Slice2ScrollConstants {
    static let touchSlop: Float = 8.0
    static let touchFlingHold: Double = 0.1
    static let scrollDecay: Float = 2.002
}

extension Runtime {
    // MARK: - El/Cx Queries (`scrollAtBottom`, `isTouchActive`, `lastWheelLock`, etc.)

    /// Returns whether the scrolled container matching `key` is within `tolerance` points of its bottom (`Runtime::scroll_at_bottom`).
    public func scrollAtBottom(forKey key: String, tolerance: Float = 1.0) -> Bool? {
        if let idx = flatNodes.firstIndex(where: {
            !$0.el.layout.scrollAxes.isEmpty && selectsElementSelector(key, path: $0.path, key: $0.key)
        }) {
            let path = flatNodes[idx].path
            let cur = scrollOffsets[path]?.y ?? 0
            let maxExt = scrollMaxExtents[path]?.y ?? 0
            return max(0, maxExt - cur) <= tolerance
        }
        return nil
    }

    /// Whether a finger is currently down (`Runtime::touching`).
    public var isTouching: Bool {
        slice2State.touchFinger != nil
    }

    internal var isTouchScrollActive: Bool {
        slice2State.touchScroll != nil
    }

    internal func isTouchOwning(path: String, horizontal: Bool) -> Bool {
        guard let t = slice2State.touchScroll,
              t.horizontal == horizontal,
              let ownerPath = nodePath(forId: t.id) else {
            return false
        }
        return ownerPath == path
    }

    // MARK: - Hover Nudge (`ScrollNudge`) Wiring

    internal func armScrollNudge(forPath path: String, at now: Double) {
        var nudge = slice2State.scrollNudges[path] ?? ScrollNudge()
        _ = nudge.arm(now: now)
        slice2State.scrollNudges[path] = nudge
    }

    internal func stepScrollNudges(at now: Double) {
        guard !slice2State.scrollNudges.isEmpty else { return }
        var expired: [String] = []
        for path in slice2State.scrollNudges.keys {
            var nudge = slice2State.scrollNudges[path]!
            nudge.tick(now: now)
            if nudge.due() == nil {
                expired.append(path)
            } else {
                slice2State.scrollNudges[path] = nudge
            }
        }
        for path in expired {
            slice2State.scrollNudges.removeValue(forKey: path)
        }
    }

    internal func isHoverHeldByNudge(at now: Double) -> Bool {
        slice2State.scrollNudges.values.contains { $0.holdAt(now: now) }
    }

    internal func cancelActiveScrollHolds(forPath path: String) {
        slice2State.scrollNudges.removeValue(forKey: path)
    }

    // MARK: - PixelHold & ScrollMode Helpers

    internal func resolveDrawnScrollOffset(for path: String, exact: Vec2, scale: Float, stickBottom: Bool) -> Vec2 {
        let hold = slice2State.pixelHolds[path] ?? .unseen
        let (drawnY, nextHold) = hold.draw(exact: exact.y, offset: exact.y, pinned: stickBottom && wasPinnedToBottom.contains(path), scale: scale)
        slice2State.pixelHolds[path] = nextHold
        return Vec2(exact.x, drawnY)
    }

    internal func updateScrollMode(forPath path: String, event: ScrollMode.Event) {
        var mode = slice2State.scrollModes[path] ?? .default
        _ = ScrollMode.step(&mode, event)
        slice2State.scrollModes[path] = mode
    }

    // MARK: - Horizontal & Phased Wheel Locking (`runtime/scroll/x.rs`)

    /// Delivers a 2D wheel/trackpad delta `(dx, dy)` in points (`Runtime::wheel_xy`).
    public func wheelXY(_ x: Float, _ y: Float, dx: Float, dy: Float, at now: Double? = nil) {
        guard dx != 0 || dy != 0 else { return }
        let clock = now ?? currentClockForScrollInput()
        performWheelEvent(WheelEvent(dx: dx, dy: dy, precise: true, phase: .changed, mods: .none), at: Vec2(x, y), now: clock)
    }

    /// Marks the beginning of a trackpad wheel gesture (`Runtime::wheel_began`).
    public func wheelBegan(at now: Double? = nil) {
        let clock = now ?? currentClockForScrollInput()
        let gesture = slice2State.wheelLock.gesture
        let active = slice2State.wheelLock.runGesture == gesture && slice2State.wheelLock.owner != .unpicked
        slice2State.wheelLock.began(now: clock, active: active, queued: false, anyQueued: false)
    }

    /// Marks the end/cancel of a trackpad wheel gesture (`Runtime::wheel_ended`).
    public func wheelEnded(at now: Double? = nil) {
        let clock = now ?? currentClockForScrollInput()
        slice2State.wheelLock.endedAt(clock)
    }

    /// Marks lost pointer/focus so a wheel gesture in progress resets cleanly (`Runtime::wheel_lost`).
    public func wheelLost() {
        slice2State.wheelLock.lost(queued: false)
    }

    /// Converts a platform `MouseScrollDelta` into points using display scale & Shift turning, then dispatches wheel scrolling.
    public func wheel(
        _ delta: MouseScrollDelta,
        at pos: Vec2,
        scale: Float? = nil,
        shift: Bool = false,
        phase: GesturePhase? = nil,
        now: Double? = nil
    ) {
        let effScale = max(1.0, scale ?? self.pixelScale)
        let (dx, dy) = wheelDelta(delta, scale: effScale, shift: shift && WheelLock.shiftTurnsWheel)
        let evPhase = phase ?? .changed
        let mods = Mods(shift: shift)
        let clock = now ?? currentClockForScrollInput()
        performWheelEvent(WheelEvent(dx: dx, dy: dy, precise: {
            if case .pixelDelta = delta { return true }
            return false
        }(), phase: evPhase, mods: mods), at: pos, now: clock)
    }

    /// Starts an inertial fling along `(vx, vy)` on whichever axis `wheelXY` would pick (`Runtime::fling_xy`).
    public func flingXY(vx: Float, vy: Float, at pos: Vec2, now: Double? = nil) {
        let clock = now ?? currentClockForScrollInput()
        if abs(vx) <= abs(vy) || scrollNodeAt(pos, horizontal: true) == nil {
            fling(vx: 0, vy: vy, at: pos, now: clock)
            return
        }
        releaseHoverHold()
        dismissHelp(at: clock)
        guard let idx = scrollNodeAt(pos, horizontal: true) else { return }
        let path = flatNodes[idx].path
        let nid = NodeId.hash("scroll:" + path)
        let cur = scrollOffsets[path] ?? .zero
        scrollGlidingPaths.remove(path)
        directScrolledPaths.insert(path)
        scrollRequestsState.stepCancel()
        scrollStore.snap(nid, Props.SCROLL, to: cur)
        let towardX = scrollFlow(at: idx) == .rtl ? vx : -vx
        _ = scrollStore.fling(nid, Props.SCROLL, from: cur, velocity: Velocity(Vec2(towardX, 0)), decay: .IOS_NORMAL, at: cxSettings.scaledTime(at: clock))
        slice2State.scrollHorizontalVelocities[path] = towardX
        updateScrollMode(forPath: path, event: .coast(moving: vx != 0))
        if vx != 0 {
            cancelPressedOnScrollIfNeeded(scrollNodeIndex: idx, at: clock)
        }
    }

    internal func performWheelEvent(_ event: WheelEvent, at pos: Vec2? = nil, now: Double) {
        releaseHoverHold()
        dismissHelp(at: now)
        let targetPos = pos ?? pointerPosition
        if let pos { pointerPosition = pos }

        switch event.phase {
        case .began:
            wheelBegan(at: now)
        case .ended, .cancelled:
            if event.dx != 0 || event.dy != 0 {
                break
            }
            wheelEnded(at: now)
            return
        case .changed:
            break
        }

        if event.dx == 0 && event.dy == 0 {
            if event.phase == .ended || event.phase == .cancelled {
                wheelEnded(at: now)
            }
            return
        }

        slice2State.wheelLock.delta(now: now, dx: event.dx, dy: event.dy, queued: false)
        slice2State.wheelLock.syncGesture(slice2State.wheelLock.gesture)

        // Custom `onWheel` handler runs first with Tx input context.
        if let (customNode, _) = hitTest(at: targetPos, predicate: { $0.el.handlers.onWheel != nil }) {
            var tx = makeTx(at: now)
            tx.runtimeActions[Tx.modsKey] = event.mods
            let taken = customNode.el.handlers.onWheel?(&state, event, &tx) == true
            Tx.took(taken, &tx)
            if taken {
                slice2State.wheelLock.owner = .handler(customNode.path)
                applyTx(tx, at: now)
                if event.phase == .ended || event.phase == .cancelled {
                    wheelEnded(at: now)
                }
                return
            }
        }

        let horizontal: Bool
        if let kept = slice2State.wheelLock.keepsAxis(dx: event.dx, dy: event.dy) {
            horizontal = kept
        } else {
            let across: NodeId? = (abs(event.dx) > abs(event.dy))
                ? scrollNodeAt(targetPos, horizontal: true).map { flatNodes[$0].nodeId }
                : nil
            horizontal = slice2State.wheelLock.repick(across: across)
        }

        if horizontal {
            if event.dx != 0 {
                performWheelHorizontal(dx: event.dx, at: targetPos, now: now)
            }
        } else {
            if event.dy != 0 {
                performWheelVertical(dy: event.dy, at: targetPos, now: now)
            }
        }

        if event.phase == .ended || event.phase == .cancelled {
            wheelEnded(at: now)
        }
    }

    private func performWheelHorizontal(dx: Float, at targetPos: Vec2, now: Double) {
        let latchedIdx: Int? = {
            if case .horizontal(let latchedId) = slice2State.wheelLock.owner,
               let idx = flatNodes.firstIndex(where: { $0.nodeId == latchedId }),
               !flatNodes[idx].effectiveInert,
               flatNodes[idx].el.layout.scrollAxes.contains(.horizontal) {
                return idx
            }
            return nil
        }()
        guard let startIdx = latchedIdx ?? scrollNodeAt(targetPos, horizontal: true) else { return }

        var walkIdx: Int? = startIdx
        while let i = walkIdx {
            let scrollNode = flatNodes[i]
            if !scrollNode.effectiveInert && scrollNode.el.layout.scrollAxes.contains(.horizontal) {
                let path = scrollNode.path
                let maxExt = scrollMaxExtents[path] ?? .zero
                let prev = scrollOffsets[path] ?? .zero
                var cur = prev
                let delta = scrollFlow(at: i) == .rtl ? dx : -dx
                cur.x = (cur.x + delta).clamped(to: 0...maxExt.x)
                if cur != prev {
                    logEvent(String(format: "wheel-x %.1f", dx))
                    commitWheelScrollDelta(path: path, scrollNodeIndex: i, next: cur, at: now)
                    return
                }
            }
            walkIdx = flatNodes[i].parentIndex
        }
    }

    private func performWheelVertical(dy: Float, at targetPos: Vec2, now: Double) {
        guard let hitNode = scrollNodeAt(targetPos, horizontal: false).map({ flatNodes[$0] }) else { return }
        var walkIdx: Int? = hitNode.index
        while let i = walkIdx {
            let scrollNode = flatNodes[i]
            if !scrollNode.effectiveInert && scrollNode.el.layout.scrollAxes.contains(.vertical) {
                let path = scrollNode.path
                let maxExt = scrollMaxExtents[path] ?? .zero
                let prev = scrollOffsets[path] ?? .zero
                var cur = prev
                cur.y = (cur.y - dy).clamped(to: 0...maxExt.y)
                if maxExt.y - cur.y <= 2.0 {
                    wasPinnedToBottom.insert(path)
                } else {
                    wasPinnedToBottom.remove(path)
                }
                if cur != prev {
                    logEvent(String(format: "wheel %.1f", dy))
                    commitWheelScrollDelta(path: path, scrollNodeIndex: i, next: cur, at: now)
                    return
                }
            }
            walkIdx = flatNodes[i].parentIndex
        }
    }

    private func commitWheelScrollDelta(path: String, scrollNodeIndex: Int, next: Vec2, at now: Double) {
        let nid = NodeId.hash("scroll:" + path)
        scrollOffsets[path] = next
        frameMovedScrollPaths.insert(path)
        scrollStore.snap(nid, Props.SCROLL, to: next)
        scrollGlidingPaths.remove(path)
        directScrolledPaths.insert(path)
        markScrollMovedByHand(path: path)
        slice2State.touchOverscrollX.removeValue(forKey: path)
        slice2State.touchOverscrollY.removeValue(forKey: path)
        updateScrollMode(forPath: path, event: .moved)
        scrollRequestsState.stepCancel()
        scrollMovedSinceLastFrame = true
        cancelPressedOnScrollIfNeeded(scrollNodeIndex: scrollNodeIndex, at: now)
        if scrollRequiresCommit {
            pendingCommitKind = pendingCommitKind.instant()
            dirtyCommit(at: now, external: false)
        } else {
            updateScrollPositions(at: now)
        }
    }

    // MARK: - Touch Scrolling (`runtime/input/touch.rs`, `runtime/scroll/touch.rs`)

    /// Unified touch entry point (`Runtime::touch`).
    public func touch(id: UInt64, phase: TouchPhase, at pos: Vec2, time: Double) {
        switch phase {
        case .started:
            touchDown(id: id, at: pos, time: time)
        case .moved:
            touchMove(id: id, at: pos, time: time)
        case .ended:
            touchUp(id: id, at: pos, time: time, cancelled: false)
        case .cancelled:
            touchUp(id: id, at: pos, time: time, cancelled: true)
        }
    }

    /// Convenience alias for touch start (`Runtime::touch_down`).
    public func touchDown(id: UInt64, at pos: Vec2, time: Double) {
        guard slice2State.touchFinger == nil else { return }
        let vIdx = scrollNodeAt(pos, horizontal: false)
        let vNode = vIdx.map { flatNodes[$0] }
        let acrossNode = scrollNodeAt(pos, horizontal: true).map { flatNodes[$0] }

        let across: (NodeId, Double)? = acrossNode.map { n in
            (n.nodeId, Double((scrollOffsets[n.path]?.x ?? 0)))
        }
        let vertical: (NodeId, Double)? = vNode.map { n in
            (n.nodeId, Double((scrollOffsets[n.path]?.y ?? 0)))
        }
        applyTouchEffects(TouchScrollMachine.step(&slice2State.touchScroll, .down(across: across, vertical: vertical)), at: time)

        pointerMove(to: pos, at: time)
        pointerDown(at: pos, at: time)
        slice2State.touchFinger = Slice2RuntimeState.TouchFinger(
            id: id,
            origin: pos,
            last: 0,
            at: time,
            velocity: 0,
            mode: .pending(scroll: vNode?.nodeId)
        )
    }

    /// Convenience alias for touch move (`Runtime::touch_move`).
    public func touchMove(id: UInt64, at pos: Vec2, time: Double) {
        guard var finger = slice2State.touchFinger, finger.id == id else { return }
        let dx = pos.x - finger.origin.x
        let dy = pos.y - finger.origin.y
        if case .pending(let pendingScroll) = finger.mode, hypot(dx, dy) > Slice2ScrollConstants.touchSlop {
            let origin = finger.origin
            let horizontal = abs(dx) > abs(dy)
            if pressDragsElement() {
                finger.mode = .drag
            } else {
                let across: (NodeId, Double)? = horizontal
                    ? scrollNodeAt(origin, horizontal: true).map { idx in
                        let n = flatNodes[idx]
                        return (n.nodeId, Double(scrollOffsets[n.path]?.x ?? 0))
                    }
                    : nil
                let vert: (NodeId, Double)? = pendingScroll.flatMap { vid in
                    nodePath(forId: vid).map { vPath in (vid, Double(scrollOffsets[vPath]?.y ?? 0)) }
                }
                applyTouchEffects(TouchScrollMachine.step(&slice2State.touchScroll, .pan(horizontal: horizontal, across: across, vertical: vert)), at: time)
                if let (chosenId, _) = across {
                    finger.mode = .pan(scroll: chosenId, horizontal: true)
                } else if let pendingScroll {
                    finger.mode = .pan(scroll: pendingScroll, horizontal: false)
                } else {
                    finger.mode = .drag
                }
            }
        }
        let along = finger.mode.horizontal ? dx : dy
        let dt = time - finger.at
        if dt > 0 {
            finger.velocity = (along - finger.last) / Float(dt)
        }
        finger.last = along
        finger.at = time
        slice2State.touchFinger = finger

        switch finger.mode {
        case .pan(let scrollId, _):
            applyTouchEffects(TouchScrollMachine.step(&slice2State.touchScroll, .move(id: scrollId, d: along)), at: time)
        case .drag:
            pointerMove(to: pos, at: time)
        case .pending:
            break
        }
    }

    /// Convenience alias for touch end/cancel (`Runtime::touch_up`).
    public func touchUp(id: UInt64, at pos: Vec2, time: Double, cancelled: Bool = false) {
        guard let finger = slice2State.touchFinger, finger.id == id else { return }
        slice2State.touchFinger = nil
        let isPan: Bool
        if case .pan = finger.mode { isPan = true } else { isPan = false }
        let velocity: Float = (isPan && !cancelled && (time - finger.at) < Slice2ScrollConstants.touchFlingHold) ? finger.velocity : 0
        applyTouchEffects(TouchScrollMachine.step(&slice2State.touchScroll, .up(id: finger.mode.scroll, velocity: velocity)), at: time)

        if cancelled {
            cancelPointerSession(at: time)
            return
        }
        if case .drag = finger.mode {
            pointerMove(to: pos, at: time)
        }
        let releasePos = isPan ? finger.origin : pos
        pointerUp(at: releasePos, at: time)
        // Upstream leaves no hover under a lifted finger.
        clearHoverAfterTouch(at: time)
    }

    /// Convenience alias for touch cancellation (`Runtime::touch_up(..., cancelled: true)`).
    public func touchCancel(id: UInt64, at pos: Vec2, time: Double) {
        touchUp(id: id, at: pos, time: time, cancelled: true)
    }

    internal func stepTouchScrollFrame(at now: Double, dt: Float) -> Bool {
        guard let active = slice2State.touchScroll,
              let path = nodePath(forId: active.id) else {
            if slice2State.touchScroll != nil && slice2State.touchFinger == nil {
                slice2State.touchScroll = nil
            }
            return false
        }
        let maxExt = scrollMaxExtents[path] ?? .zero
        let overflow = Double(active.horizontal ? maxExt.x : maxExt.y)
        let effects = TouchScrollMachine.step(&slice2State.touchScroll, .tick(id: active.id, horizontal: active.horizontal, overflow: overflow, dt: dt))
        let stillMoving = applyTouchEffects(effects, at: now) ?? false
        return stillMoving
    }

    @discardableResult
    private func applyTouchEffects(_ effects: Effects<TouchEffect>, at now: Double) -> Bool? {
        var active: Bool? = nil
        for effect in effects {
            switch effect {
            case .halt(let id):
                if let path = nodePath(forId: id) {
                    let nid = NodeId.hash("scroll:" + path)
                    let cur = scrollOffsets[path] ?? .zero
                    scrollGlidingPaths.remove(path)
                    scrollStore.snap(nid, Props.SCROLL, to: cur)
                    updateScrollMode(forPath: path, event: .halt)
                }
            case .stopAcross(let id):
                if let path = nodePath(forId: id) {
                    slice2State.scrollHorizontalVelocities[path] = 0
                    let nid = NodeId.hash("scroll:" + path)
                    let cur = scrollOffsets[path] ?? .zero
                    scrollStore.snap(nid, Props.SCROLL, to: cur)
                }
            case .fling(let id, let horizontal, let velocity):
                guard let path = nodePath(forId: id),
                      let idx = nodeByPath[path] else { continue }
                let clampedV = velocity.clamped(to: -8000...8000)
                if horizontal {
                    let toward = scrollFlow(at: idx) == .rtl ? clampedV : -clampedV
                    slice2State.scrollHorizontalVelocities[path] = toward
                } else {
                    updateScrollMode(forPath: path, event: .coast(moving: clampedV != 0))
                    slice2State.scrollModes[path] = (slice2State.scrollModes[path] ?? .default).toMomentum(-clampedV)
                }
            case .pan(let id, let origin, let horizontal, let d):
                guard let path = nodePath(forId: id),
                      let idx = nodeByPath[path] else { continue }
                let maxExt = scrollMaxExtents[path] ?? .zero
                let maxAxis = Double(horizontal ? maxExt.x : maxExt.y)
                let toward: Double = horizontal
                    ? (scrollFlow(at: idx) == .rtl ? Double(d) : -Double(d))
                    : -Double(d)
                let to = origin + toward
                let edge = min(max(0.0, to), maxAxis)
                let over = to - edge
                let elastic = Float(edge + over * 0.55 / (1.0 + abs(over) * 0.55 / 300.0))
                var cur = scrollOffsets[path] ?? .zero
                if horizontal {
                    cur.x = elastic
                    slice2State.touchOverscrollX[path] = elastic
                } else {
                    cur.y = elastic
                    slice2State.touchOverscrollY[path] = elastic
                    updateScrollMode(forPath: path, event: .moved)
                }
                let nid = NodeId.hash("scroll:" + path)
                scrollOffsets[path] = cur
                scrollStore.snap(nid, Props.SCROLL, to: cur)
                scrollGlidingPaths.remove(path)
                directScrolledPaths.insert(path)
                scrollRequestsState.stepCancel()
                scrollMovedSinceLastFrame = true
                // Cancel any pending tap press because pan won.
                if pressedPath != nil {
                    pressedPath = nil
                    pressedKey = nil
                }
                updateScrollPositionsWithoutClampingTouch(at: now)
            case .hold(let id, _, _):
                if let path = nodePath(forId: id) {
                    updateScrollMode(forPath: path, event: .hold)
                }
                active = false
            case .coast(let id, let horizontal, let overflow, let dt):
                guard let path = nodePath(forId: id) else { continue }
                let maxAxis = max(0.0, overflow)
                var cur = scrollOffsets[path] ?? .zero
                var offset = Double(horizontal ? cur.x : cur.y)
                var v: Float = horizontal
                    ? (slice2State.scrollHorizontalVelocities[path] ?? 0)
                    : (slice2State.scrollModes[path]?.coast() ?? 0)
                if !horizontal {
                    updateScrollMode(forPath: path, event: .coast(moving: abs(v) > 1.0))
                }
                let edge = min(max(0.0, offset), maxAxis)
                if abs(offset - edge) > 1e-4 {
                    (offset, v) = TouchScrollMachine.rebound(offset: offset, velocity: v, target: edge, dt: dt)
                    if abs(offset - edge) < 0.1 && abs(v) < 1.0 {
                        offset = edge
                        v = 0
                    }
                } else if dt > 0 {
                    let decay = exp(-Slice2ScrollConstants.scrollDecay * dt)
                    offset += Double(v * (1.0 - decay) / Slice2ScrollConstants.scrollDecay)
                    v *= decay
                }
                let moving = abs(v) > 1.0 || offset < 0.0 || offset > maxAxis
                if horizontal {
                    slice2State.scrollHorizontalVelocities[path] = v
                    cur.x = Float(offset)
                    if moving { slice2State.touchOverscrollX[path] = cur.x } else { slice2State.touchOverscrollX.removeValue(forKey: path) }
                } else {
                    cur.y = Float(offset)
                    if moving {
                        slice2State.touchOverscrollY[path] = cur.y
                        slice2State.scrollModes[path] = (slice2State.scrollModes[path] ?? .default).toMomentum(v)
                    } else {
                        slice2State.touchOverscrollY.removeValue(forKey: path)
                        updateScrollMode(forPath: path, event: .halt)
                    }
                    if maxAxis - Double(cur.y) <= 2.0 && maxAxis > 0.5 {
                        wasPinnedToBottom.insert(path)
                    } else {
                        wasPinnedToBottom.remove(path)
                    }
                }
                let nid = NodeId.hash("scroll:" + path)
                scrollOffsets[path] = cur
                scrollStore.snap(nid, Props.SCROLL, to: cur)
                scrollMovedSinceLastFrame = true
                updateScrollPositionsWithoutClampingTouch(at: now)
                _ = TouchScrollMachine.step(&slice2State.touchScroll, .settled(moving: moving))
                active = moving
            }
        }
        return active
    }

    private func pressDragsElement() -> Bool {
        guard let pPath = pressedPath, let idx = nodeByPath[pPath] else { return false }
        let el = flatNodes[idx].el
        let dragsOut = el.handlers.dragOut != nil || el.attachedDragOutItem != nil
        return el.handlers.onDrag != nil && !dragsOut
    }

    private func cancelPointerSession(at now: Double) {
        pressedPath = nil
        pressedKey = nil
        armedDragOut = nil
        if let drag = activeDrag {
            activeDrag = nil
            if !drag.isTextSelectionDrag, let idx = nodeByPath[drag.path], let onEnd = flatNodes[idx].el.handlers.onDragEnd {
                var tx = makeTx(at: now, button: drag.button)
                onEnd(&state, true, &tx)
                applyTx(tx, at: now)
            }
        }
        clearHoverAfterTouch(at: now)
    }

    private func clearHoverAfterTouch(at now: Double) {
        pointerPosition = Vec2(-10000, -10000)
        if let old = hoveredPath, let oldIdx = nodeByPath[old], let cb = flatNodes[oldIdx].el.handlers.onHover {
            hoveredPath = nil
            hoveredKey = nil
            var tx = makeTx(at: now)
            cb(&state, false, &tx)
            applyTx(tx, at: now, liveOnlyLabel: "onHover")
        } else {
            hoveredPath = nil
            hoveredKey = nil
        }
        hoveredLink = nil
    }

    private func updateScrollPositionsWithoutClampingTouch(at now: Double) {
        let savedX = slice2State.touchOverscrollX
        let savedY = slice2State.touchOverscrollY
        for (path, ox) in savedX {
            var c = scrollOffsets[path] ?? .zero
            c.x = ox
            scrollOffsets[path] = c
        }
        for (path, oy) in savedY {
            var c = scrollOffsets[path] ?? .zero
            c.y = oy
            scrollOffsets[path] = c
        }
        updateScrollPositions(at: now)
    }

    // MARK: - Highlight & Virtual Target Lookup

    internal func resolveTextHighlightRevealTarget(scope: String?, key: String) -> (nodeIndex: Int, rect: MotionRect)? {
        for (i, node) in flatNodes.enumerated() {
            if let scope {
                let inScope = node.parentIndex.map { pIdx in
                    let pPath = flatNodes[pIdx].path
                    return selectsElementSelector(scope, path: pPath, key: flatNodes[pIdx].key) || pPath.contains("/@\(scope)")
                } ?? false
                if !inScope { continue }
            }
            guard let hls = node.el.textHighlights,
                  let hl = hls.first(where: { $0.key == key }),
                  let txt = node.el.liveText?.get() ?? node.el.plainText, !txt.isEmpty,
                  let shaped = shapedText(for: node) else {
                continue
            }
            let quads = TextHighlightPainter.quads(
                highlights: [hl],
                in: txt,
                shaped: shaped,
                textSystem: textSystem,
                pixelScale: 1.0,
                origin: .zero
            )
            guard let q = quads.first else { continue }
            var unionX0 = q.rect.x
            var unionY0 = q.rect.y
            var unionX1 = q.rect.x + q.rect.z
            var unionY1 = q.rect.y + q.rect.w
            for more in quads.dropFirst() {
                unionX0 = min(unionX0, more.rect.x)
                unionY0 = min(unionY0, more.rect.y)
                unionX1 = max(unionX1, more.rect.x + more.rect.z)
                unionY1 = max(unionY1, more.rect.y + more.rect.w)
            }
            let padLeft = node.el.layout.padding.left
            let padTop = node.el.layout.padding.top
            let originX = node.targetRect.x + padLeft
            let originY = node.targetRect.y + padTop
            return (i, MotionRect.fromXYWH(originX + unionX0, originY + unionY0, max(0, unionX1 - unionX0), max(0, unionY1 - unionY0)))
        }
        return nil
    }

    internal func shapedText(for node: FlatNode) -> ShapedText? {
        guard let txt = node.el.liveText?.get() ?? node.el.plainText, !txt.isEmpty else { return nil }
        let padW = node.el.layout.padding.left + node.el.layout.padding.right
        let maxW = max(1.0, node.targetRect.width - padW)
        return textSystem.shape(
            text: txt,
            spans: node.el.richSpans,
            pills: node.el.pillChips,
            style: node.el.textStyle,
            maxWidth: maxW,
            pixelScale: 1.0,
            emitGlyphs: false
        )
    }

    internal func resolveVirtualRowBounds(forKey key: String, scope: String?) -> (vIdx: Int, itemTop: Double, itemH: Double, itemLeft: Double, itemW: Double, cur: Vec2)? {
        for (listIdx, node) in flatNodes.enumerated() {
            guard let vState = virtualLists[node.path],
                  let rowIdx = vState.lastKeys.firstIndex(where: {
                      $0 == key || selectsElementSelector(key, path: "\(node.path)/\($0)", key: $0)
                  }) else { continue }
            let candidateVIdx: Int?
            if !node.el.layout.scrollAxes.isEmpty && (scope == nil || selectsElementSelector(scope!, path: node.path, key: node.key)) {
                candidateVIdx = listIdx
            } else {
                var curP = flatNodes[listIdx].parentIndex
                var found: Int? = nil
                while let pi = curP {
                    if !flatNodes[pi].el.layout.scrollAxes.isEmpty {
                        if let scope {
                            if selectsElementSelector(scope, path: flatNodes[pi].path, key: flatNodes[pi].key) {
                                found = pi
                                break
                            }
                        } else {
                            found = pi
                            break
                        }
                    }
                    curP = flatNodes[pi].parentIndex
                }
                candidateVIdx = found
            }
            guard let foundVIdx = candidateVIdx else { continue }
            let est = Float(node.el.virtualEstimate ?? 40)
            let prefixY: Float = (0..<rowIdx).reduce(0) { sum, idx in
                sum + vState.rowHeight(forKey: vState.lastKeys[idx], estimated: est)
            }
            let rowH = vState.rowHeight(forKey: vState.lastKeys[rowIdx], estimated: est)
            let vpNode = flatNodes[foundVIdx]
            let c = scrollOffsets[vpNode.path] ?? .zero
            let top = Double(node.targetRect.top + prefixY - vpNode.targetRect.y) + Double(c.y)
            let left = Double(node.targetRect.left - vpNode.targetRect.x) + Double(c.x)
            return (foundVIdx, top, Double(rowH), left, Double(node.targetRect.width), c)
        }
        return nil
    }

    // MARK: - Horizontal Reveal (`runtime/scroll/x.rs::reveal_row_x`)

    internal func revealRowX(scope: String?, key: String) -> (path: String, nextX: Float)? {
        let target: (idx: Int, x: Float, w: Float)?
        if let tIdx = flatNodes.firstIndex(where: {
            selectsElementSelector(key, path: $0.path, key: $0.key)
                && ($0.parentIndex.map { scope == nil || selectsElementSelector(scope!, path: flatNodes[$0].path, key: flatNodes[$0].key) || flatNodes[$0].path.contains("/@\(scope!)") } ?? true)
        }) {
            target = (tIdx, flatNodes[tIdx].targetRect.x, flatNodes[tIdx].targetRect.width)
        } else if let hl = resolveTextHighlightRevealTarget(scope: scope, key: key) {
            target = (hl.nodeIndex, hl.rect.x, hl.rect.width)
        } else {
            target = nil
        }
        guard let (tIdx, targetX, targetW) = target else { return nil }
        var curP = flatNodes[tIdx].parentIndex
        var foundVIdx: Int? = nil
        while let pi = curP {
            if flatNodes[pi].el.layout.scrollAxes.contains(.horizontal) {
                foundVIdx = pi
                break
            }
            curP = flatNodes[pi].parentIndex
        }
        guard let vIdx = foundVIdx else { return nil }
        let view = flatNodes[vIdx]
        let path = view.path
        let maxX = Double(scrollMaxExtents[path]?.x ?? 0)
        let cur = scrollOffsets[path] ?? .zero
        let vpStart = scrollFlow(at: vIdx) == .rtl
            ? (view.targetRect.right - (targetX + targetW))
            : (targetX - view.targetRect.left)
        let startWithScroll = Double(vpStart) + Double(cur.x)
        let destX = ScrollEdgeMath.reveal(
            offset: Double(cur.x),
            top: startWithScroll,
            height: Double(targetW),
            viewport: Double(view.targetRect.width),
            margin: Double(view.el.scrollMarginPts)
        ).clamped(to: 0...maxX)
        return abs(destX - Double(cur.x)) > 1e-4 ? (path, Float(destX)) : nil
    }

    // MARK: - Tx Slice 2 Actions & Input Context (`el/tx.rs`)

    internal func populateTxSlice2Context(_ tx: inout Tx, at now: Double) {
        tx.tracingEnabled = tx.tracingEnabled || slice2State.tracingEnabled
        tx.runtimeActions[Tx.tracingKey] = tx.tracingEnabled
        tx.assistiveTechnologyActive = tx.assistiveTechnologyActive || slice2State.assistiveTechnologyActive
        tx.runtimeActions[Tx.assistiveTechnologyKey] = tx.assistiveTechnologyActive
        tx.focusVisibleAtEvent = tx.focusVisibleAtEvent || focusVisible
        tx.runtimeActions["focusVisible"] = tx.focusVisibleAtEvent
        tx.runtimeActions["byKeys"] = kitHooks.isDispatchingByKeys || slice2State.currentByKeys
        tx.keyRepeatValue = tx.keyRepeatValue || slice2State.currentKeyRepeat
        tx.runtimeActions[Tx.keyRepeatKey] = tx.keyRepeatValue
        if let pk = tx.physicalKeyValue ?? slice2State.currentPhysicalKey {
            tx.physicalKeyValue = pk
            tx.runtimeActions[Tx.physicalKeyKey] = pk
        }
        if let kb = tx.keyBaseValue ?? slice2State.currentKeyBase {
            tx.keyBaseValue = kb
            tx.runtimeActions[Tx.keyBaseKey] = kb
        }
        tx.runtimeActions[Tx.modsKey] = slice2State.currentMods
        let resolvedTime = slice2State.currentInputTime ?? tx.eventInputTime ?? now
        tx.eventInputTime = resolvedTime
        tx.runtimeActions[Tx.inputTimeKey] = resolvedTime
        if let fk = focusedKey {
            tx.runtimeActions[Tx.focusedKey] = fk
        }
        if slice2State.dragRepeatFiringNow {
            tx.runtimeActions["dragRepeat"] = true
        }
    }

    internal func processTxSlice2Actions(_ tx: inout Tx, at now: Double, depth: Int = 0) {
        if !tx.erasedPickReads.isEmpty && depth < 4 {
            let reads = tx.erasedPickReads
            tx.runtimeActions.removeValue(forKey: Tx.pickReadsKey)
            for req in reads {
                let picked: Picked? = req.within.map {
                    elementAtInWith($0, x: req.x, y: req.y, pick: req.pick)
                } ?? elementAtWith(req.x, req.y, pick: req.pick)
                var boxed: Any = state
                var followUp = makeTx(at: now)
                req.call(&boxed, picked, &followUp)
                if let typed = boxed as? State {
                    state = typed
                }
                applyTx(followUp, at: now, external: false)
            }
        }

        if tx.blurFocusRequested {
            slice2State.pendingTxFocusVisible = nil
        } else if tx.requestedFocusKey != nil {
            slice2State.pendingTxFocusVisible = tx.requestedFocusVisible
            focusVisible = tx.requestedFocusVisible
        }
        if let shell = tx.shellRequest {
            slice2State.lastShellRequest = max(slice2State.lastShellRequest ?? shell, shell)
        }
        if tx.toggleMaximizedRequested || tx.isToggleMaximizedRequested {
            slice2State.toggleMaximizedRequested.toggle()
        }
        if tx.toggleFullScreenRequested || tx.isToggleFullScreenRequested {
            slice2State.toggleFullScreenRequested.toggle()
        }
        if let ann = tx.announcement ?? tx.announcementRequest {
            slice2State.announcements.append(ann)
        }
        if let ff = tx.fontFamiliesRequest {
            slice2State.customFontFamilies = ff
        }
        if !tx.traceEvents.isEmpty {
            slice2State.traceEvents.append(contentsOf: tx.traceEvents)
        }
        if !tx.traceChannels.isEmpty {
            slice2State.traceChannels.append(contentsOf: tx.traceChannels.map { ($0.name, $0.kind.rawValue, $0.value) })
        }
        if !tx.traceEventsRecorded.isEmpty {
            slice2State.traceEvents.append(contentsOf: tx.traceEventsRecorded)
        }
        if !tx.traceChannelsRecorded.isEmpty {
            slice2State.traceChannels.append(contentsOf: tx.traceChannelsRecorded)
        }
    }

    // MARK: - Private Utilities

    private func scrollNodeAt(_ pos: Vec2, horizontal: Bool) -> Int? {
        hitTest(at: pos, ignoreBlockers: true, predicate: { node in
            horizontal ? node.el.layout.scrollAxes.contains(.horizontal) : node.el.layout.scrollAxes.contains(.vertical)
        })?.node.index
    }

    private func nodePath(forId id: NodeId) -> String? {
        flatNodes.first(where: { $0.nodeId == id })?.path
    }

    private func scrollFlow(at nodeIndex: Int) -> ScrollAxisHelper.Flow {
        if flatNodes[nodeIndex].flow == .rtl {
            return .rtl
        }
        return flatNodes[nodeIndex].el.runtimeExtras["slice2.flow"] as? ScrollAxisHelper.Flow ?? .ltr
    }

    private func currentClockForScrollInput() -> Double {
        slice2State.currentInputTime ?? 0
    }

    internal struct ReorderedRowSlide {
        var id: NodeId
        var jump: Float
        var targetOffset: Vec2
        var spring: Spring
        var prevOff: Vec2
        var prevVel: Vec2?
    }

    internal func prepareGrowthRowReorderSlides(
        specs: inout [NodeSpec],
        nodes: [FlatNode],
        instant: Bool,
        lands: Bool,
        relayout: Bool,
        commitCut: Bool
    ) -> [ReorderedRowSlide] {
        guard specs.count == nodes.count else { return [] }
        let animates = !instant && !lands && !relayout && !commitCut && !reducedMotion
        var seenStacks: Set<NodeId> = []
        var slides: [ReorderedRowSlide] = []
        let rowHeight: (FlatNode) -> Float? = { node in
            let gKey = node.el.foldGlideSpec != nil ? "fold:\(node.path)" : "growth:\(node.path)"
            if let gh = self.growthRows[gKey]?.track.h {
                return gh
            }
            if let sh = self.scene.get(node.nodeId, Props.FRAME)?.height {
                return sh
            }
            return node.targetRect.height
        }

        var childrenByParentIdx: [Int: [Int]] = [:]
        for i in nodes.indices {
            if let pIdx = nodes[i].parentIndex {
                childrenByParentIdx[pIdx, default: []].append(i)
            }
        }

        for sIdx in nodes.indices where nodes[sIdx].el.growthSpec != nil {
            let stackNode = nodes[sIdx]
            let stackId = stackNode.nodeId
            seenStacks.insert(stackId)

            let childIndices = (childrenByParentIdx[sIdx] ?? []).filter { cIdx in
                let k = nodes[cIdx].el.keyId
                return k != "__v_top_spacer" && k != "__v_bot_spacer"
            }
            let newOrder = childIndices.map { nodes[$0].nodeId }
            let oldOrder = slice2State.growthStackOrders[stackId]
            slice2State.growthStackOrders[stackId] = newOrder

            var reorder = slice2State.growthRowReorder[stackId] ?? VirtualRowReorder()
            var nodeByChildId: [NodeId: FlatNode] = [:]
            for cIdx in childIndices {
                nodeByChildId[nodes[cIdx].nodeId] = nodes[cIdx]
            }
            reorder.measure(
                animates: animates && oldOrder != nil,
                old: oldOrder ?? [],
                new: newOrder,
                gap: virtualGapY(stackNode.el.layout),
                height: { nid in
                    if let fn = nodeByChildId[nid] {
                        return rowHeight(fn)
                    }
                    return self.scene.get(nid, Props.FRAME)?.height
                }
            )
            slice2State.growthRowReorder[stackId] = reorder
            guard animates else { continue }

            let (vpTop, vpBottom): (Float, Float) = {
                if let encIdx = !stackNode.el.layout.scrollAxes.isEmpty ? sIdx : stackNode.enclosingVScrollIndex {
                    let r = nodes[encIdx].targetRect
                    return (max(0, r.top), min(viewport.y, r.bottom))
                }
                return (0, viewport.y)
            }()

            for cIdx in childIndices {
                let node = nodes[cIdx]
                let cid = node.nodeId
                let rawJump = reorder.jump(for: cid)
                guard abs(rawJump) > 1.0 / 64.0 else { continue }
                if activeFlightIds.contains(cid) || launchedFlightIds.contains(cid) { continue }
                if node.el.hasInstantChanges || !node.el.liveBindings.isEmpty || node.el.loopingSpec != nil { continue }

                if let la = specs[cIdx].layoutAnim {
                    specs[cIdx].layoutAnim = LayoutAnim(x: la.x, y: .instant, travel: la.travel)
                }

                let h = rowHeight(node) ?? node.targetRect.height
                let newTop = node.targetRect.top
                let oldTop = presentedRectByPath[node.path]?.top ?? (newTop + rawJump)
                let oldVisible = (oldTop + h) > vpTop && oldTop < vpBottom
                let newVisible = (newTop + h) > vpTop && newTop < vpBottom
                if !oldVisible && !newVisible {
                    continue
                }
                var jump = rawJump
                if oldTop > vpBottom && newTop < vpBottom {
                    jump = min(rawJump, vpBottom - newTop)
                } else if (oldTop + h) < vpTop && (newTop + h) > vpTop {
                    jump = max(rawJump, (vpTop - h) - newTop)
                }
                guard abs(jump) > 1.0 / 64.0 else { continue }

                let prevOff = scene.get(cid, Props.OFFSET) ?? .zero
                let prevVel = scene.store.velocity(cid, Props.OFFSET)
                let curve = node.el.layoutAnim?.y.curve ?? node.el.layoutAnim?.x.curve ?? Curve.from(MotionTokens.SETTLE)
                let spring: Spring
                if case .spring(let s) = curve {
                    spring = s
                } else {
                    spring = MotionTokens.SETTLE
                }
                slides.append(ReorderedRowSlide(
                    id: cid,
                    jump: jump,
                    targetOffset: specs[cIdx].offset,
                    spring: spring,
                    prevOff: prevOff,
                    prevVel: prevVel
                ))
            }
        }

        slice2State.growthStackOrders = slice2State.growthStackOrders.filter { seenStacks.contains($0.key) }
        slice2State.growthRowReorder = slice2State.growthRowReorder.filter { seenStacks.contains($0.key) }
        return slides
    }

    internal func commitGrowthRowReorderSlides(_ slides: [ReorderedRowSlide], at scaledNow: Double) {
        guard !slides.isEmpty else { return }
        for s in slides {
            scene.set(s.id, Props.OFFSET, Vec2(s.prevOff.x, s.prevOff.y + s.jump))
            let anim = Anim<Vec2>(curve: Curve.from(s.spring))
            if let v = s.prevVel, (abs(v.x) > 1e-4 || abs(v.y) > 1e-4) {
                scene.store.animateWithVelocity(s.id, Props.OFFSET, to: s.targetOffset, velocity: v, anim: anim)
            } else {
                scene.animate(s.id, Props.OFFSET, to: s.targetOffset, anim: anim)
            }
        }
    }
}

extension El {
    /// Sets horizontal scroll flow direction (`ltr` or `rtl`) (`El::flow` / `types.rs::AxisScroll`).
    public func flow(_ direction: ScrollAxisHelper.Flow) -> Self {
        var copy = self
        copy.runtimeExtras["slice2.flow"] = direction
        return copy
    }
}
