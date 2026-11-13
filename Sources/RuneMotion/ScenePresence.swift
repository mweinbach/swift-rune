import Foundation

extension Scene {
    // MARK: - Presence & Tree Lifecycle

    /// Keyed node enters, lands (`Mount.initial`), or revives if exiting.
    /// When `spec.parent` sits inside a newly entering subtree (`opacity < 0.5`), the child
    /// rides that parent unless a `delay` was requested (via `insertDelayed`).
    public mutating func insert(_ id: NodeId, _ spec: NodeSpec, _ mount: Mount) {
        insertDelayed(id, spec, mount, delay: 0.0)
    }

    /// Inserts with a delayed start (held at the insertion effect for `delay` seconds before moving).
    public mutating func insertDelayed(_ id: NodeId, _ spec: NodeSpec, _ mount: Mount, delay: Float) {
        let transition = spec.transition ?? .none
        if let existing = slot(id) {
            // Ensure parent linkage stays up-to-date if reparented in compat commit or callers.
            let oldParentId = nodes[existing].parent == Self.noneIdx ? nil : nodes[Int(nodes[existing].parent)].id
            if oldParentId != spec.parent {
                reparentSlot(existing, to: spec.parent)
            }
            nodes[existing].transition = transition
            let exiting = nodes[existing].presence.isExiting
            if exiting && mount == .initial {
                let acts = nodes[existing].phaseStep(.land(transition: transition))
                applyPhaseActs(existing, acts)
                setFrame(id, spec.frame, LayoutAnim.instant)
                return
            }
            if exiting {
                let p = presenceNow(id)
                let acts = nodes[existing].phaseStep(.revive(transition: transition, p: p))
                applyPhaseActs(existing, acts)
            }
            if nodes[existing].frame != spec.frame && nodes[existing].path == nil {
                setFrame(id, spec.frame, LayoutAnim(MotionTokens.REFLOW))
            }
            return
        }

        let parentIdx = spec.parent.flatMap { slot($0) }.map(UInt32.init) ?? Self.noneIdx
        let i = allocNodeSlot(id: id, parent: parentIdx, spec: spec)
        linkNodeSlot(i, parent: parentIdx)

        let ins = transition.insertion.kitRules(removal: false)
        let reduced = store.reducedMotion
        let plain = delay <= 0.0 && transition.insertion == Transition.opacity.insertion
        let ridesParent = !reduced && hasEnteringAncestorBelowHalf(parentIdx, plain: plain)
        let shouldAnimate: Bool
        if mount == .animated {
            if reduced {
                shouldAnimate = !transition.isNone
            } else {
                shouldAnimate = !ins.showsNothing && !ridesParent
            }
        } else {
            shouldAnimate = false
        }

        let clampedDelay = delay.isFinite ? max(0.0, delay) : 0.0
        let acts = nodes[i].phaseStep(.mount(transition: transition, animate: shouldAnimate, delay: clampedDelay))
        applyPhaseActs(i, acts)
    }

    public mutating func setTransition(_ id: NodeId, _ transition: Transition) {
        guard let i = slot(id) else { return }
        if !nodes[i].presence.isExiting {
            nodes[i].transition = transition
        }
    }

    /// Keyed node leaves; stays mounted and drawn until its exit settles (or fades invisible).
    public mutating func remove(_ id: NodeId) {
        guard let i = slot(id) else { return }
        if !nodes[i].alive || nodes[i].presence.isExiting { return }
        let p = presenceNow(id)
        let acts = nodes[i].phaseStep(.exit(transition: nodes[i].transition, p: p))
        applyPhaseActs(i, acts)
    }

    /// Removes a node and its subtree immediately without running an exit transition, reporting them in `exited`.
    public mutating func unmount(_ id: NodeId) {
        guard let i = slot(id), nodes[i].alive else { return }
        removeNow(i)
    }

    /// Lands an entering node at rest immediately (`enter_now`).
    public mutating func enterNow(_ id: NodeId) {
        guard let i = slot(id), nodes[i].presence.isEntering else { return }
        let acts = nodes[i].phaseStep(.land(transition: nodes[i].transition))
        applyPhaseActs(i, acts)
    }

    /// Lands an entrance only if it is still waiting at the start (`p < 1e-3`).
    public mutating func landWaiting(_ id: NodeId) {
        guard let i = slot(id) else { return }
        let p = presenceNow(id)
        let acts = nodes[i].phaseStep(.appear(transition: nodes[i].transition, p: p))
        applyPhaseActs(i, acts)
    }

    /// Re-runs an already present node's entrance from `0 -> 1`.
    public mutating func reenter(_ id: NodeId) {
        guard let i = slot(id), nodes[i].alive, nodes[i].presence.isPresent else { return }
        let acts = nodes[i].phaseStep(.fadeIn(transition: nodes[i].transition))
        applyPhaseActs(i, acts)
    }

    // MARK: - Internal Presence Helpers

    internal func presentNow(_ i: Int) {
        // Not used mutatingly on external callers directly; PhaseEvent.land handles it.
    }

    internal mutating func triggerPresentNow(_ i: Int) {
        let acts = nodes[i].phaseStep(.land(transition: nodes[i].transition))
        applyPhaseActs(i, acts)
    }

    internal func presenceNow(_ id: NodeId) -> Float {
        guard let i = slot(id), let tid = nodes[i].tracks[Int(Props.PRESENCE.id.rawValue)] else {
            return 1.0
        }
        return store.valuesOf(tid)?.first ?? 1.0
    }

    private func hasEnteringAncestorBelowHalf(_ startParent: UInt32, plain: Bool) -> Bool {
        var p = startParent
        while p != Self.noneIdx {
            let pi = Int(p)
            switch nodes[pi].presence {
            case .present:
                if plain {
                    p = nodes[pi].parent
                } else {
                    return false
                }
            case .entering:
                let pv: Float
                if let tid = nodes[pi].tracks[Int(Props.PRESENCE.id.rawValue)],
                   let vals = store.valuesOf(tid), let first = vals.first {
                    pv = first
                } else {
                    pv = 1.0
                }
                return pv < 0.5
            case .exiting:
                return true
            }
        }
        return false
    }

    internal mutating func applyPhaseActs(_ i: Int, _ acts: [PhaseAct]) {
        let id = nodes[i].id
        for act in acts {
            switch act {
            case let .anchor(a):
                nodes[i].anchor = a
            case let .reveal(rv):
                nodes[i].reveal = rv
            case let .land(v):
                trackSet(i, Props.PRESENCE, v)
            case let .landIfNeeded(v):
                if hasTrack(i, Props.PRESENCE) || nodes[i].tracks[Int(Props.PRESENCE.id.rawValue)] != nil {
                    trackSet(i, Props.PRESENCE, v)
                }
            case .ensure:
                if !hasTrack(i, Props.PRESENCE) && nodes[i].tracks[Int(Props.PRESENCE.id.rawValue)] == nil {
                    trackSet(i, Props.PRESENCE, 1.0)
                }
            case let .run(target, spring, delay):
                let curve: Curve = store.reducedMotion && !nodes[i].transition.isNone
                    ? .REDUCED_FADE
                    : .spring(spring)
                let anim = Anim<Float>(curve: curve, delay: delay)
                trackAnimate(i, Props.PRESENCE, target, anim)
            case .dirty:
                nodes[i].dirty = true
            case .retire:
                toRemove.append(UInt32(i))
            case .unmount:
                removeNow(i)
                return
            case let .intent(seconds):
                intent(id, TraceIntent.transition | TraceIntent.opacity, seconds)
            }
        }
    }
}
