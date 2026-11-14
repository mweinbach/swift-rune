import Foundation
import RuneMotion

// MARK: - Wheel Lock (`scroll/x.rs` + `input/gesture.rs`)

internal enum WheelOwner: Equatable {
    case unpicked
    case handler(String)
    case vertical
    case horizontal(String)

    var isHorizontalAxis: Bool? {
        switch self {
        case .vertical: return false
        case .horizontal: return true
        case .unpicked, .handler: return nil
        }
    }
}

internal enum WheelGestureKind: Equatable {
    case unphased
    case phased
    case momentum
}

internal enum WheelPhaseState: Equatable {
    case unphased(at: Double?)
    case phased(at: Double)
    case momentum(at: Double)
    case ended(at: Double, from: WheelGestureKind)

    var isPhased: Bool {
        switch self {
        case .unphased, .ended(_, .unphased): return false
        case .phased, .momentum, .ended(_, .phased), .ended(_, .momentum): return true
        }
    }

    var isMomentum: Bool {
        switch self {
        case .momentum, .ended(_, .momentum): return true
        default: return false
        }
    }

    var at: Double? {
        switch self {
        case .unphased(let t): return t
        case .phased(let t), .momentum(let t), .ended(let t, _): return t
        }
    }

    var endedAt: Double? {
        if case .ended(let t, _) = self { return t }
        return nil
    }

    func moving(to now: Double) -> WheelPhaseState {
        switch self {
        case .unphased: return .unphased(at: now)
        case .phased: return .phased(at: now)
        case .momentum: return .momentum(at: now)
        case .ended: return self
        }
    }
}

internal struct WheelLock {
    private static let wheelIdle: Double = 0.1
    private static let phasedIdle: Double = 1.0
    private static let momentumGap: Double = 0.05

    var owner: WheelOwner = .unpicked
    var phase: WheelPhaseState = .unphased(at: nil)

    mutating func restart() {
        owner = .unpicked
        phase = .unphased(at: nil)
    }

    mutating func began(at now: Double) {
        let active: Bool
        switch owner {
        case .unpicked: active = false
        case .handler, .vertical, .horizontal: active = true
        }
        let isMom = !phase.isMomentum && active && phase.endedAt.map { now - $0 <= Self.momentumGap } == true
        if !isMom {
            restart()
        }
        phase = isMom ? .momentum(at: now) : .phased(at: now)
    }

    mutating func deltaArrived(at now: Double, dx: Float, dy: Float) {
        let phased = phase.isPhased
        let idle = phased ? Self.phasedIdle : Self.wheelIdle
        let flipped: Bool
        if !phased, let h = owner.isHorizontalAxis {
            flipped = h ? (dx == 0) : (dy == 0)
        } else {
            flipped = false
        }
        let stale = phase.endedAt != nil
            || phase.at.map { now - $0 > idle } ?? true
            || flipped
        if stale {
            restart()
        }
        phase = phase.moving(to: now)
    }

    mutating func ended(at now: Double) {
        let kind: WheelGestureKind
        switch phase {
        case .unphased: kind = .unphased
        case .phased: kind = .phased
        case .momentum: kind = .momentum
        case .ended(_, let from): kind = from
        }
        phase = .ended(at: now, from: kind)
    }

    mutating func lost() {
        restart()
    }

    func keepsAxis(dx: Float, dy: Float) -> Bool? {
        guard let h = owner.isHorizontalAxis else { return nil }
        if phase.isPhased || (h ? dx != 0 : dy != 0) {
            return h
        }
        return nil
    }

    mutating func repick(acrossPath: String?) -> Bool {
        if let p = acrossPath {
            owner = .horizontal(p)
            return true
        } else {
            owner = .vertical
            return false
        }
    }
}

// MARK: - Touch State (`input/touch.rs`)

internal enum TouchMode: Equatable {
    case pending(scrollPath: String?)
    case drag
    case pan(scrollPath: String, horizontal: Bool, originOffset: Float)

    var isPan: Bool {
        if case .pan = self { return true }
        return false
    }

    var isHorizontal: Bool {
        if case .pan(_, let h, _) = self { return h }
        return false
    }
}

internal struct TouchFinger {
    var id: UInt64
    var origin: Vec2
    var lastAlong: Float
    var lastAt: Double
    var velocity: Float
    var mode: TouchMode
}

internal struct TouchInputState {
    static let touchSlop: Float = 8.0
    static let flingHold: Double = 0.1
    var finger: TouchFinger? = nil
}

// MARK: - Runtime Canvas Gesture, Wheel Lock & Touch

extension Runtime {
    private func nodeContainsGesturePoint(_ idx: Int, _ windowPos: Vec2) -> Bool {
        let node = flatNodes[idx]
        if let geom = hitGeometryByPath[node.path] {
            if geom.isExiting || geom.opacity <= 0.001 { return false }
            return geom.contains(windowPos)
        }
        if node.el.opacity <= 0.001 { return false }
        let r = presentedRectByPath[node.path] ?? node.targetRect
        return halfOpenContains(intersectRects(node.clipRect, r), windowPos)
    }

    private func wheelGestureStartIndex(at windowPos: Vec2) -> Int? {
        let hitIdx = hitTest(at: windowPos, predicate: { _ in true }).flatMap { nodeByPath[$0.node.path] }
        let scrollIdx = flatNodes.indices.reversed().first { i in
            let n = flatNodes[i]
            guard !n.el.layout.scrollAxes.isEmpty, !n.effectiveInert else { return false }
            if activeModalPath != nil && !modalMemberPaths.contains(n.path) { return false }
            return nodeContainsGesturePoint(i, windowPos)
        }
        if let h = hitIdx, let s = scrollIdx {
            var p = flatNodes[s].parentIndex
            while let cur = p {
                if cur == h { return s }
                p = flatNodes[cur].parentIndex
            }
            return h
        }
        return hitIdx ?? scrollIdx
    }

    private func scrollContainerAt(at pos: Vec2, axis: ScrollAxes) -> String? {
        guard let (hitNode, _) = hitTest(at: pos, ignoreBlockers: true, predicate: {
            $0.el.layout.scrollAxes.contains(axis) && !self.subtreeExiting($0.index)
        }) else {
            return nil
        }
        var walkIdx: Int? = hitNode.index
        while let i = walkIdx {
            let n = flatNodes[i]
            if !n.effectiveInert && n.el.layout.scrollAxes.contains(axis) && !subtreeExiting(i) {
                return n.path
            }
            walkIdx = n.parentIndex
        }
        return nil
    }

    private func subtreeExiting(_ idx: Int) -> Bool {
        var cur: Int? = idx
        while let i = cur, flatNodes.indices.contains(i) {
            if case .exiting = scene.phase(flatNodes[i].nodeId) { return true }
            cur = flatNodes[i].parentIndex
        }
        return false
    }

    /// A wheel or trackpad scroll at window point (`ev.x`, `ev.y`), with its modifiers and phase
    /// (`Runtime::wheel_event`, `runtime/input/gesture.rs:25`). The innermost `onWheel` handler
    /// there hears it first, up to the nearest scroll view; what none takes scrolls as
    /// `wheelXY` does.
    public func wheelEvent(_ ev: WheelEvent, now: Double) {
        dispatchLockedWheel(ev, at: Vec2(ev.x, ev.y), now: now)
    }

    /// A wheel or trackpad delta in points on both axes at window point (x, y), positive moving
    /// content right and down (`Runtime::wheel_xy`, `runtime/scroll/x.rs`). The gesture's first
    /// delta picks the axis and the rest keeps it; without phases a pause of 0.1 s ends a gesture.
    /// An `onWheel` handler under the pointer hears it first.
    public func wheelXY(_ x: Float, _ y: Float, _ dx: Float, _ dy: Float, now: Double) {
        if dx == 0 && dy == 0 { return }
        // `WheelEvent::new(dx, dy).at(x, y)`: the derived default leaves `precise` false.
        wheelEvent(WheelEvent(dx: dx, dy: dy, precise: false, x: x, y: y), now: now)
    }

    /// The platform began a trackpad gesture (`Runtime::wheel_began`): its first delta picks the
    /// axis afresh, unless it is the momentum of one that just ended.
    public func wheelBegan(now: Double) {
        inputMachines.wheelLock.began(at: now)
    }

    /// The platform ended a trackpad gesture (`Runtime::wheel_ended`).
    public func wheelEnded(now: Double) {
        inputMachines.wheelLock.ended(at: now)
    }

    internal func dispatchLockedWheel(_ event: WheelEvent, at pos: Vec2?, now: Double) {
        releaseHoverHold()
        let targetPos = pos ?? pointerPosition
        if let pos { pointerPosition = pos }

        if event.phase == .began {
            inputMachines.wheelLock.began(at: now)
        }
        let moved = event.dx != 0 || event.dy != 0
        if moved {
            dismissHelp(at: now)
            inputMachines.wheelLock.deltaArrived(at: now, dx: event.dx, dy: event.dy)
        }
        if moved || event.phase != .changed {
            var ev = event
            // `WheelEvent { momentum: self.wheel_lock.momentum(), ..ev }`: the lock alone says
            // whether a delta is momentum, whatever the caller passed.
            ev.momentum = inputMachines.wheelLock.phase.isMomentum
            var handled = false
            switch inputMachines.wheelLock.owner {
            case .handler(let ownerPath):
                if let idx = nodeByPath[ownerPath],
                   !flatNodes[idx].effectiveInert,
                   !subtreeExiting(idx),
                   let onWheel = flatNodes[idx].el.handlers.onWheel {
                    let local = wheelLocalPoint(for: flatNodes[idx], at: targetPos)
                    var localEv = ev
                    localEv.x = local.x
                    localEv.y = local.y
                    var tx = makeTx(at: now, mods: ev.mods)
                    let took = Tx.took(onWheel(&state, localEv, &tx), &tx)
                    applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
                    _ = took
                    handled = true
                } else {
                    inputMachines.wheelLock.owner = .unpicked
                }
            case .unpicked:
                if let startIdx = wheelGestureStartIndex(at: targetPos) {
                    var walkIdx: Int? = startIdx
                    while let i = walkIdx, i < flatNodes.count {
                        let node = flatNodes[i]
                        if node.effectiveInert || subtreeExiting(i) { break }
                        if let onWheel = node.el.handlers.onWheel {
                            let local = wheelLocalPoint(for: node, at: targetPos)
                            var localEv = ev
                            localEv.x = local.x
                            localEv.y = local.y
                            var tx = makeTx(at: now, mods: ev.mods)
                            let took = Tx.took(onWheel(&state, localEv, &tx), &tx)
                            applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
                            if took {
                                inputMachines.wheelLock.owner = .handler(node.path)
                                handled = true
                                break
                            }
                        }
                        if !node.el.layout.scrollAxes.isEmpty || node.el.isModal { break }
                        walkIdx = node.parentIndex
                    }
                }
            case .vertical, .horizontal:
                break
            }

            if !handled && moved {
                wheelScrollLocked(dx: ev.dx, dy: ev.dy, at: targetPos, now: now)
            }
        }
        if event.phase == .ended || event.phase == .cancelled {
            inputMachines.wheelLock.ended(at: now)
        }
    }

    private func wheelLocalPoint(for node: FlatNode, at windowPos: Vec2) -> Vec2 {
        if let geom = hitGeometryByPath[node.path], let lp = geom.unturnedLocalPoint(for: windowPos) {
            let scale = max(1e-4, node.inheritedScale)
            return Vec2((lp.x - geom.rect.x) / scale, (lp.y - geom.rect.y) / scale)
        }
        let rect = presentedRectByPath[node.path] ?? node.targetRect
        let scale = max(1e-4, node.inheritedScale)
        return Vec2((windowPos.x - rect.x) / scale, (windowPos.y - rect.y) / scale)
    }

    private func wheelScrollLocked(dx: Float, dy: Float, at targetPos: Vec2, now: Double) {
        let horizontal: Bool
        if let locked = inputMachines.wheelLock.keepsAxis(dx: dx, dy: dy) {
            horizontal = locked
        } else {
            let across: String? = (abs(dx) > abs(dy))
                ? scrollContainerAt(at: targetPos, axis: .horizontal)
                : nil
            horizontal = inputMachines.wheelLock.repick(acrossPath: across)
        }

        if horizontal {
            guard dx != 0 else { return }
            let latchedPath: String? = {
                if case .horizontal(let p) = inputMachines.wheelLock.owner,
                   let idx = nodeByPath[p],
                   !flatNodes[idx].effectiveInert,
                   !subtreeExiting(idx),
                   flatNodes[idx].el.layout.scrollAxes.contains(.horizontal) {
                    return p
                }
                return nil
            }()
            if let path = latchedPath ?? scrollContainerAt(at: targetPos, axis: .horizontal) {
                let maxExt = scrollMaxExtents[path] ?? .zero
                let prev = scrollOffsets[path] ?? .zero
                let isRtl = nodeByPath[path].map { flatNodes[$0].flow == .rtl } ?? false
                let signDx = isRtl ? -dx : dx
                var cur = prev
                cur.x = (cur.x - signDx).clamped(to: 0...maxExt.x)
                if cur != prev {
                    if dx != 0 {
                        logEvent(String(format: "wheel-x %.1f", dx))
                    }
                    applyManualScroll(path: path, to: cur, at: now)
                }
            }
        } else {
            guard dy != 0 else { return }
            guard let (hitNode, _) = hitTest(at: targetPos, ignoreBlockers: true, predicate: {
                $0.el.layout.scrollAxes.contains(.vertical) || !$0.el.layout.scrollAxes.isEmpty
            }) else {
                return
            }
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
                        if dy != 0 {
                            logEvent(String(format: "wheel %.1f", dy))
                        }
                        applyManualScroll(path: path, to: cur, at: now)
                        return
                    }
                }
                walkIdx = flatNodes[i].parentIndex
            }
        }
    }

    private func applyManualScroll(path: String, to cur: Vec2, at now: Double) {
        let nid = NodeId.hash("scroll:" + path)
        scrollOffsets[path] = cur
        // Upstream `pointer.rs::wheel` / `scroll/x.rs::wheel_scroll_for`: a wheel that moved the
        // offset cancels a held press inside this viewport (`scroll_cancels_press`).
        if let scrollIdx = nodeByPath[path] {
            cancelPressedOnScrollIfNeeded(scrollNodeIndex: scrollIdx, at: now)
        }
        frameMovedScrollPaths.insert(path)
        scrollStore.snap(nid, Props.SCROLL, to: cur)
        scrollGlidingPaths.remove(path)
        markScrollMovedByHand(path: path)
        scrollRequestsState.stepCancel()
        scrollMovedSinceLastFrame = true
        if scrollRequiresCommit {
            directScrolledPaths.insert(path)
            pendingCommitKind = pendingCommitKind.instant()
            dirtyCommit(at: now, external: false)
        } else {
            directScrolledPaths.remove(path)
            updateScrollPositions(at: now)
        }
    }

    /// Converts Ctrl+wheel `dy` into a magnification gesture when an `onMagnify` handler sits under `pos` (`gesture.rs:111`).
    @discardableResult
    public func pinchWheel(dy: Float, at pos: Vec2, now: Double = 0) -> Bool {
        guard dy != 0 else { return false }
        guard let startIdx = wheelGestureStartIndex(at: pos) else { return false }
        var walkIdx: Int? = startIdx
        var hasHandler = false
        while let i = walkIdx, i < flatNodes.count {
            let n = flatNodes[i]
            if n.effectiveInert || subtreeExiting(i) { break }
            if n.el.handlers.onMagnify != nil {
                hasHandler = true
                break
            }
            if n.el.isModal { break }
            walkIdx = n.parentIndex
        }
        guard hasHandler else { return false }
        return magnify(MagnifyEvent(delta: -dy / 200.0, x: pos.x, y: pos.y), at: pos, now: now)
    }

    /// Routes mouse button press for primary, secondary (release-captured), and middle/back/forward buttons (`gesture.rs:179`).
    public func buttonDown(at pos: Vec2, button: PointerButton, mods: Mods = .none, at now: Double = 0) {
        switch button {
        case .primary:
            pointerDown(at: pos, button: .primary, mods: mods, at: now)
        case .secondary:
            secondaryDown(at: pos, at: now)
        case .middle, .back, .forward:
            if pressedPath != nil || hasActivePointerDrag { return }
            pointerDown(at: pos, button: button, mods: mods, at: now)
        }
    }

    /// Routes mouse button release for `buttonDown` (`gesture.rs:208`).
    public func buttonUp(at pos: Vec2, button: PointerButton, mods: Mods = .none, at now: Double = 0) {
        switch button {
        case .primary:
            pointerUp(at: pos, button: .primary, mods: mods, at: now)
        case .secondary:
            secondaryUp(at: pos, mods: mods, at: now)
        case .middle, .back, .forward:
            let holdingButton = (activeDrag?.button == button) || (inputMachines.pressedButton == button)
            if holdingButton {
                pointerUp(at: pos, button: button, mods: mods, at: now)
            }
        }
    }

    // MARK: - Touch & Pen Input (`input/touch.rs`)

    /// Whether a touch finger is currently held (`Runtime::touching`).
    public func touching() -> Bool {
        inputMachines.touchState.finger != nil
    }

    /// Delivers a touchscreen/pen event, arbitrating tap vs element drag vs scrollable pan & fling (`input/touch.rs`).
    public func touch(id: UInt64 = 1, phase: TouchPhase, at pos: Vec2, time: Double) {
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

    private func touchDown(id: UInt64, at pos: Vec2, time: Double) {
        guard inputMachines.touchState.finger == nil else { return }
        let verticalScroll = scrollContainerAt(at: pos, axis: .vertical)
        if let vPath = verticalScroll {
            let nid = NodeId.hash("scroll:" + vPath)
            let cur = scrollOffsets[vPath] ?? .zero
            scrollStore.snap(nid, Props.SCROLL, to: cur)
        }
        pointerMove(to: pos, at: time)
        pointerDown(at: pos, at: time)
        inputMachines.touchState.finger = TouchFinger(
            id: id,
            origin: pos,
            lastAlong: 0,
            lastAt: time,
            velocity: 0,
            mode: .pending(scrollPath: verticalScroll)
        )
    }

    private func touchMove(id: UInt64, at pos: Vec2, time: Double) {
        guard var finger = inputMachines.touchState.finger, finger.id == id else { return }
        let dx = pos.x - finger.origin.x
        let dy = pos.y - finger.origin.y
        if case .pending(let verticalScroll) = finger.mode, hypot(dx, dy) > TouchInputState.touchSlop {
            let dragsElement: Bool = {
                guard let p = pressedPath, let idx = nodeByPath[p] else { return false }
                let node = flatNodes[idx]
                return node.el.handlers.onDrag != nil && node.el.handlers.dragOut == nil && node.el.attachedDragOutItem == nil
            }()
            if dragsElement {
                finger.mode = .drag
            } else {
                let horizPath = abs(dx) > abs(dy) ? scrollContainerAt(at: finger.origin, axis: .horizontal) : nil
                if let hPath = horizPath {
                    let originOffset = (scrollOffsets[hPath] ?? .zero).x
                    finger.mode = .pan(scrollPath: hPath, horizontal: true, originOffset: originOffset)
                    cancelPressForTouchPan()
                } else if let vPath = verticalScroll ?? scrollContainerAt(at: finger.origin, axis: .vertical) {
                    let originOffset = (scrollOffsets[vPath] ?? .zero).y
                    finger.mode = .pan(scrollPath: vPath, horizontal: false, originOffset: originOffset)
                    cancelPressForTouchPan()
                } else {
                    finger.mode = .drag
                }
            }
        }

        let along = finger.mode.isHorizontal ? dx : dy
        let dt = time - finger.lastAt
        if dt > 0 {
            finger.velocity = (along - finger.lastAlong) / Float(dt)
        }
        finger.lastAlong = along
        finger.lastAt = time
        inputMachines.touchState.finger = finger

        switch finger.mode {
        case .pan(let scrollPath, let horizontal, let originOffset):
            let maxExt = scrollMaxExtents[scrollPath] ?? .zero
            var cur = scrollOffsets[scrollPath] ?? .zero
            if horizontal {
                cur.x = (originOffset - along).clamped(to: 0...maxExt.x)
            } else {
                cur.y = (originOffset - along).clamped(to: 0...maxExt.y)
            }
            applyManualScroll(path: scrollPath, to: cur, at: time)
        case .drag:
            pointerMove(to: pos, at: time)
        case .pending:
            break
        }
    }

    private func touchUp(id: UInt64, at pos: Vec2, time: Double, cancelled: Bool) {
        guard let finger = inputMachines.touchState.finger, finger.id == id else { return }
        inputMachines.touchState.finger = nil

        if cancelled {
            cancelPointer(at: time)
            return
        }

        let isPan: Bool
        let velocity: Float
        if case .pan(let scrollPath, let horizontal, _) = finger.mode {
            isPan = true
            velocity = (time - finger.lastAt < TouchInputState.flingHold) ? finger.velocity : 0
            if abs(velocity) > 1.0 {
                let nid = NodeId.hash("scroll:" + scrollPath)
                let cur = scrollOffsets[scrollPath] ?? .zero
                scrollGlidingPaths.remove(scrollPath)
                directScrolledPaths.insert(scrollPath)
                markScrollMovedByHand(path: scrollPath)
                scrollRequestsState.stepCancel()
                scrollStore.snap(nid, Props.SCROLL, to: cur)
                let vel = horizontal ? Velocity(Vec2(-velocity, 0)) : Velocity(Vec2(0, -velocity))
                _ = scrollStore.fling(nid, Props.SCROLL, from: cur, velocity: vel, decay: .IOS_NORMAL, at: cxSettings.scaledTime(at: time))
            }
        } else {
            isPan = false
            velocity = 0
            _ = velocity
        }

        if finger.mode == .drag {
            pointerMove(to: pos, at: time)
        }
        pointerUp(at: isPan ? finger.origin : pos, at: time)
        pointerLeave(at: time)
    }

    private func cancelPressForTouchPan() {
        pressedPath = nil
        inputMachines.pressedButton = .primary
        activeDrag = nil
        armedDragOut = nil
        inputMachines.pressedWindowPoint = nil
        inputMachines.pressedStillInside = false
        inputMachines.pressedLeft = false
    }
}
