import Foundation

/// Packed 9-lane visual look at one endpoint of a transition:
/// `[0] opacity, [1] scale, [2] offset.x, [3] offset.y, [4] frac.x, [5] frac.y, [6] blur, [7] hidden, [8] draw`.
internal typealias Fx = (Float, Float, Float, Float, Float, Float, Float, Float, Float)

internal let fxIdentity: Fx = (1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0)

@inline(__always)
internal func fxOf(_ e: TransitionEffect) -> Fx {
    (
        e.zeroOpacity ?? 1.0,
        (e.zeroScale.x + e.zeroScale.y) * 0.5,
        e.pointOffset.x,
        e.pointOffset.y,
        e.relativeOffset.x,
        e.relativeOffset.y,
        e.zeroBlur,
        e.reveal != nil ? 1.0 : 0.0,
        e.draw
    )
}

@inline(__always)
internal func fxAt(_ f: Fx, _ k: Int) -> Float {
    switch k {
    case 0: return f.0
    case 1: return f.1
    case 2: return f.2
    case 3: return f.3
    case 4: return f.4
    case 5: return f.5
    case 6: return f.6
    case 7: return f.7
    case 8: return f.8
    default: return 0.0
    }
}

@inline(__always)
internal func fxSet(_ f: inout Fx, _ k: Int, _ v: Float) {
    switch k {
    case 0: f.0 = v
    case 1: f.1 = v
    case 2: f.2 = v
    case 3: f.3 = v
    case 4: f.4 = v
    case 5: f.5 = v
    case 6: f.6 = v
    case 7: f.7 = v
    case 8: f.8 = v
    default: break
    }
}

@inline(__always)
internal func lerpFx(_ a: Fx, _ b: Fx, _ p: Float) -> Fx {
    let q = 1.0 - p
    return (
        a.0 * q + b.0 * p,
        a.1 * q + b.1 * p,
        a.2 * q + b.2 * p,
        a.3 * q + b.3 * p,
        a.4 * q + b.4 * p,
        a.5 * q + b.5 * p,
        a.6 * q + b.6 * p,
        a.7 * q + b.7 * p,
        a.8 * q + b.8 * p
    )
}

internal enum PresenceState: Sendable {
    case entering(at0: Fx, at1: Fx)
    case present(at0: Fx, at1: Fx)
    case exiting(at0: Fx, at1: Fx)

    @inline(__always)
    func `public`(_ generation: UInt32) -> ScenePhase {
        switch self {
        case .entering: return .entering
        case .present: return .present
        case .exiting: return .exiting(generation: generation)
        }
    }

    @inline(__always)
    var isPresent: Bool {
        if case .present = self { return true }
        return false
    }

    @inline(__always)
    var isEntering: Bool {
        if case .entering = self { return true }
        return false
    }

    @inline(__always)
    var isExiting: Bool {
        if case .exiting = self { return true }
        return false
    }

    @inline(__always)
    var isResting: Bool {
        if case .present = self { return true }
        return false
    }

    @inline(__always)
    var pair: (Fx, Fx) {
        switch self {
        case let .entering(a, b), let .present(a, b), let .exiting(a, b):
            return (a, b)
        }
    }

    mutating func setPair(_ at0: Fx, _ at1: Fx) {
        switch self {
        case .entering: self = .entering(at0: at0, at1: at1)
        case .present: self = .present(at0: at0, at1: at1)
        case .exiting: self = .exiting(at0: at0, at1: at1)
        }
    }
}

internal enum PhaseEvent {
    case mount(transition: Transition, animate: Bool, delay: Float)
    case revive(transition: Transition, p: Float)
    case land(transition: Transition)
    case appear(transition: Transition)
    case fadeIn(transition: Transition)
    case exit(transition: Transition, p: Float)
    case settle
    case faded(p: Float)
}

internal enum PhaseAct {
    case land(Float)
    case landIfNeeded(Float)
    case ensure
    case run(target: Float, spring: Spring, delay: Float)
    case dirty
    case anchor(Vec2)
    case reveal(Reveal?)
    case retire
    case unmount
    case intent(seconds: Float)
}

internal func stepPhase(
    state: inout PresenceState,
    generation: inout UInt32,
    event: PhaseEvent
) -> [PhaseAct] {
    var acts: [PhaseAct] = []
    switch event {
    case let .mount(transition, animate, delay):
        let ins = transition.insertion.kitRules(removal: false)
        let at0 = fxOf(ins)
        generation = 0
        acts.append(.anchor(ins.anchor))
        acts.append(.reveal(ins.reveal))
        if animate {
            state = .entering(at0: at0, at1: fxIdentity)
            acts.append(.land(0.0))
            let sp = transition.enterSpring
            acts.append(.run(target: 1.0, spring: sp, delay: delay))
            acts.append(.intent(seconds: Curve.spring(sp).logicalDuration))
        } else {
            state = .present(at0: at0, at1: fxIdentity)
            acts.append(.landIfNeeded(1.0))
        }
        acts.append(.dirty)

    case let .revive(transition, p):
        let (_, old1) = state.pair
        let old0 = state.pair.0
        generation &+= 1
        let at0: Fx
        if p <= 0.001 {
            at0 = fxOf(transition.insertion.kitRules(removal: false))
        } else {
            let cur = lerpFx(old0, old1, p)
            let q = max(1.0 - p, 1e-3)
            var solved = fxIdentity
            for k in 0..<8 {
                fxSet(&solved, k, (fxAt(cur, k) - fxAt(fxIdentity, k) * p) / q)
            }
            fxSet(&solved, 8, old0.8)
            at0 = solved
        }
        state = .entering(at0: at0, at1: fxIdentity)
        let sp = transition.enterSpring
        acts.append(.run(target: 1.0, spring: sp, delay: 0.0))
        acts.append(.dirty)
        acts.append(.intent(seconds: Curve.spring(sp).logicalDuration))

    case let .land(transition):
        let ins = transition.insertion.kitRules(removal: false)
        generation &+= 1
        state = .present(at0: fxOf(ins), at1: fxIdentity)
        acts.append(.anchor(ins.anchor))
        acts.append(.reveal(ins.reveal))
        acts.append(.land(1.0))
        acts.append(.dirty)

    case .appear:
        let (_, at1) = state.pair
        state = .present(at0: fxIdentity, at1: at1)
        acts.append(.land(1.0))
        acts.append(.dirty)

    case let .fadeIn(transition):
        let (at0, at1) = state.pair
        state = .entering(at0: at0, at1: at1)
        acts.append(.land(0.0))
        let sp = transition.enterSpring
        acts.append(.run(target: 1.0, spring: sp, delay: 0.0))
        acts.append(.dirty)

    case let .exit(transition, p):
        if case .exiting = state {
            return []
        }
        let (old0, old1) = state.pair
        let unplayed = p < 1e-3
        if unplayed && lerpFx(old0, old1, p).0 < 1.0 / 512.0 {
            acts.append(.unmount)
            return acts
        }
        let rem = transition.removal.kitRules(removal: true)
        let target = fxOf(rem)
        generation &+= 1
        let new1: Fx
        if p >= 0.999 {
            new1 = fxIdentity
        } else if unplayed {
            new1 = lerpFx(old0, old1, p)
        } else {
            let cur = lerpFx(old0, old1, p)
            var solved = old1
            let denom = max(p, 1e-3)
            for k in 0..<8 {
                fxSet(&solved, k, fxAt(target, k) + (fxAt(cur, k) - fxAt(target, k)) / denom)
            }
            new1 = solved
        }
        state = .exiting(at0: target, at1: new1)
        if rem.zeroScale != Vec2(1, 1) {
            acts.append(.anchor(rem.anchor))
        }
        if rem.reveal != nil {
            acts.append(.reveal(rem.reveal))
        }
        acts.append(.ensure)
        if unplayed {
            acts.append(.land(1.0))
        }
        let sp = transition.exitSpring
        acts.append(.run(target: 0.0, spring: sp, delay: 0.0))
        acts.append(.dirty)
        acts.append(.intent(seconds: Curve.spring(sp).logicalDuration))

    case .settle:
        switch state {
        case let .entering(at0, at1):
            state = .present(at0: at0, at1: at1)
        case .exiting:
            acts.append(.retire)
        case .present:
            break
        }

    case let .faded(p):
        if case let .exiting(at0, at1) = state {
            if lerpFx(at0, at1, p).0 < 1.0 / 255.0 {
                acts.append(.retire)
            }
        }
    }
    return acts
}
