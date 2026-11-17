import Foundation
import RuneMotion

// Wheel lock types (`WheelOwner`, `WheelRun`, `WheelPhaseState`, `WheelLock`) live in `WheelLock.swift`.

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

    /// `pointer.rs` `scroll_at_axis`: the innermost scroll viewport at `pos` that moves on `axis`.
    /// One whose content fits on that axis (`scrollHasRoom`) is passed over for the one around
    /// it, as Chromium skips a scroller with nothing to scroll (#1021).
    internal func scrollContainerAt(at pos: Vec2, axis: ScrollAxes) -> String? {
        guard let (hitNode, _) = hitTest(at: pos, ignoreBlockers: true, predicate: {
            $0.el.layout.scrollAxes.contains(axis) && self.scrollHasRoom($0.path, axis: axis) && !self.subtreeExiting($0.index)
        }) else {
            return nil
        }
        var walkIdx: Int? = hitNode.index
        while let i = walkIdx {
            let n = flatNodes[i]
            if !n.effectiveInert && n.el.layout.scrollAxes.contains(axis) && scrollHasRoom(n.path, axis: axis) && !subtreeExiting(i) {
                return n.path
            }
            walkIdx = n.parentIndex
        }
        return nil
    }

    internal func subtreeExiting(_ idx: Int) -> Bool {
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
        // A wheel is input (`Action::Wheel`): a resting poll's change splits from it (#970).
        let inputMark = beginInputDispatch(at: now)
        defer { endInputDispatch(inputMark, queuedAction: true) }
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

    /// `gesture.rs` `wheel_event`: a wheel or trackpad scroll at `pos`, with its modifiers and
    /// phase. The innermost `onWheel` handler there hears it first, up to the nearest scroll
    /// view; what none takes scrolls on the axis the gesture locked to.
    internal func dispatchLockedWheel(_ event: WheelEvent, at pos: Vec2?, now: Double) {
        releaseHoverHold()
        let targetPos = pos ?? pointerPosition

        if event.phase == .began {
            wheelBegan(now: now)
        }
        let moved = event.dx != 0 || event.dy != 0
        if moved {
            dismissHelp(at: now)
            wheelDeltaArrived(dx: event.dx, dy: event.dy, now: now)
        }
        if moved || event.phase != .changed {
            var ev = event
            // `WheelEvent { momentum: self.wheel_lock.momentum(), ..ev }`: the lock alone says
            // whether a delta is momentum, whatever the caller passed.
            ev.momentum = inputMachines.wheelLock.momentum
            // Each delta carries its own gesture and that gesture's axis policy (r241).
            let gesture = inputMachines.wheelLock.gesture
            let phased = inputMachines.wheelLock.phased
            runWheel(gesture: gesture, ev, phased: phased, at: targetPos, moved: moved, now: now)
        }
        if event.phase == .ended || event.phase == .cancelled {
            wheelEnded(now: now)
        }
    }

    /// `gesture.rs` `run_wheel`: the handler holding the delta's gesture hears it, else each
    /// handler under the pointer until one takes it, else it scrolls. Each delta keeps its own
    /// gesture's owner and axis policy (`WheelLock.ownerOf` / `setOwner`), so one of an older
    /// gesture still reaches the owner its own gesture picked.
    private func runWheel(gesture: AttemptToken, _ ev: WheelEvent, phased: Bool, at targetPos: Vec2, moved: Bool, now: Double) {
        inputMachines.wheelLock.syncGesture(gesture)
        var handled = false
        switch inputMachines.wheelLock.ownerOf(gesture) {
        case .handler(let ownerPath)?:
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
                inputMachines.wheelLock.setOwner(gesture, .unpicked)
            }
        case .unpicked?:
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
                            inputMachines.wheelLock.setOwner(gesture, .handler(node.path))
                            handled = true
                            break
                        }
                    }
                    if !node.el.layout.scrollAxes.isEmpty || node.el.isModal { break }
                    walkIdx = node.parentIndex
                }
            }
        case .vertical?, .horizontal?, nil:
            break
        }

        if !handled && moved {
            wheelScrollLocked(gesture: gesture, dx: ev.dx, dy: ev.dy, phased: phased, at: targetPos, now: now)
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

    /// `scroll/x.rs` `wheel_scroll_for`: scrolls by a delta no `onWheel` handler took, on the
    /// axis `gesture` locked to. `phased` is that delta's own gesture's policy.
    private func wheelScrollLocked(gesture: AttemptToken, dx: Float, dy: Float, phased: Bool, at targetPos: Vec2, now: Double) {
        if dx == 0 && dy == 0 { return }
        inputMachines.wheelLock.syncGesture(gesture)
        let horizontal: Bool
        if let locked = inputMachines.wheelLock.keepsAxis(gesture, dx: dx, dy: dy, phased: phased) {
            horizontal = locked
        } else {
            let across: String? = (abs(dx) > abs(dy))
                ? scrollContainerAt(at: targetPos, axis: .horizontal)
                : nil
            horizontal = inputMachines.wheelLock.repick(gesture, acrossPath: across)
        }

        if horizontal {
            guard dx != 0 else { return }
            let latchedPath: String? = {
                if case .horizontal(let p)? = inputMachines.wheelLock.ownerOf(gesture),
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
        } else if dy != 0 {
            scrollVerticalWheel(dy: dy, at: targetPos, now: now)
        }
    }

    /// A fresh wheel run starts in the innermost eligible viewport with room in its direction.
    private func verticalWheelTarget(dy: Float, at point: Vec2) -> Int? {
        for i in flatNodes.indices.reversed() {
            let node = flatNodes[i]
            guard node.el.layout.scrollAxes.contains(.vertical), hoverAllowed(i), !subtreeExiting(i),
                  let limit = scrollMaxExtents[node.path]?.y else { continue }
            let offset = scrollOffsets[node.path]?.y ?? 0
            if (dy > 0 ? offset > 0 : offset < limit), nodeContainsGesturePoint(i, point) {
                return i
            }
        }
        return nil
    }

    private func scrollVerticalWheel(dy: Float, at point: Vec2, now: Double) {
        let held = inputMachines.wheelLock.verticalTarget(at: now, x: point.x, y: point.y, dy: dy).flatMap { path -> Int? in
            guard let i = nodeByPath[path], !flatNodes[i].el.layout.scrollAxes.isEmpty,
                  hoverAllowed(i), !subtreeExiting(i) else { return nil }
            return i
        }
        guard let i = held ?? verticalWheelTarget(dy: dy, at: point) else {
            inputMachines.wheelLock.endVertical()
            return
        }
        let node = flatNodes[i]
        let path = node.path
        guard let limit = scrollMaxExtents[path]?.y else { return }
        let previous = scrollOffsets[path] ?? .zero
        var current = previous
        current.y = (current.y - dy).clamped(to: 0...limit)
        logEvent(String(format: "wheel %.1f", dy))
        let moved = current != previous
        if moved {
            applyManualScroll(path: path, to: current, at: now)
        } else {
            updateScrollMode(forPath: path, event: .moved)
        }
        let pinned = node.el.layout.stickBottom && current.y >= limit - 0.5
        updateScrollMode(forPath: path, event: pinned ? .pin : .rest)
        if pinned { wasPinnedToBottom.insert(path) } else { wasPinnedToBottom.remove(path) }
        inputMachines.wheelLock.ranVertical(path: path, at: now, x: point.x, y: point.y, dy: dy, moved: moved, continued: held != nil)
    }

    internal func applyManualScroll(path: String, to cur: Vec2, at now: Double) {
        let nid = NodeId.hash("scroll:" + path)
        scrollOffsets[path] = cur
        // Upstream `pointer.rs::wheel` / `scroll/x.rs::wheel_scroll_for`: a wheel that moved the
        // offset cancels a held press inside this viewport (`scroll_cancels_press`).
        if let scrollIdx = nodeByPath[path] {
            cancelPressedOnScrollIfNeeded(scrollNodeIndex: scrollIdx, at: now)
        }
        frameMovedScrollPaths.insert(path)
        slice2State.touchOverscrollX.removeValue(forKey: path)
        slice2State.touchOverscrollY.removeValue(forKey: path)
        updateScrollMode(forPath: path, event: .moved)
        scrollStore.snap(nid, Props.SCROLL, to: cur)
        scrollGlidingPaths.remove(path)
        markScrollMovedByHand(path: path)
        scrollRequestsState.stepCancel()
        scrollMovedSinceLastFrame = true
        if scrollRequiresCommit {
            directScrolledPaths.insert(path)
            pendingCommitKind = pendingCommitKind.instant()
            dirtyCommit(at: now, external: false, why: scrollCommitWhy)
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
            if holdingButton || slice2State.autoscroll.willTakeRelease(button) || (button == .middle && primaryPointerHeld) {
                pointerUp(at: pos, button: button, mods: mods, at: now)
            }
        }
    }

    // MARK: - Touch & Pen Input (`input/touch.rs`)

    /// Whether a touch finger is currently held (`Runtime::touching`).
    public func touching() -> Bool {
        isTouching
    }

    /// Delivers a touchscreen/pen event, arbitrating tap vs element drag vs scrollable pan & fling (`input/touch.rs`).
    public func touch(id: UInt64 = 1, phase: TouchPhase, at pos: Vec2, time: Double) {
        touch(id: id, phase: phase, at: pos, time: time, holdClock: nil)
    }

    /// Event timestamps measure movement. A live host schedules a long press on the clock
    /// its next frame will use, including when the last frame preceded a long idle interval.
    internal func touch(id: UInt64, phase: TouchPhase, at pos: Vec2, time: Double, holdClock: Double?) {
        switch phase {
        case .started:
            touchDown(id: id, at: pos, time: time, holdClock: holdClock)
        case .moved:
            touchMove(id: id, at: pos, time: time)
        case .ended:
            touchUp(id: id, at: pos, time: time, cancelled: false)
        case .cancelled:
            touchUp(id: id, at: pos, time: time, cancelled: true)
        }
    }

}
