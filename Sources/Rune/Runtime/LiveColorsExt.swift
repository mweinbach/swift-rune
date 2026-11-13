import Foundation
import RuneMotion

extension El {
    /// Shorthand outer outline (`El::outline(width, offset, color)`).
    public func outline(_ width: Float, _ offset: Float, _ color: Color) -> Self {
        focusRing(width, offset: offset, color)
    }

    /// Shorthand drop shadow (`El::shadow(offsetY, blur, color)`).
    public func shadow(_ offsetY: Float, _ blur: Float, _ color: Color) -> Self {
        shadow(Shadow(x: 0, y: offsetY, blur: blur, spread: 0, color: color, inset: false))
    }
}

internal extension Runtime {
    static func liveColorProp(for target: BoundLiveProperty.Target) -> Prop<MotionColor> {
        switch target {
        case .fill: return Props.FILL
        case .textColor: return Props.TEXT_COLOR
        case .borderColor: return Props.BORDER
        case .shadowColor: return Props.SHADOW_COLOR
        case .gradientTop: return Props.GRADIENT_TOP
        case .gradientBottom: return Props.GRADIENT_BOTTOM
        default: return Props.FILL
        }
    }

    func snapLiveColorTrack(nid: NodeId, target: BoundLiveProperty.Target, lanes: MotionLanes) {
        let c = Color.decodeLiveLanes(lanes)
        liveFillTargets[nid] = c
        liveStore.snap(nid, Self.liveColorProp(for: target), to: c.motionColor)
    }

    func animateLiveColorTrack(
        nid: NodeId,
        target: BoundLiveProperty.Target,
        lanes: MotionLanes,
        spring: Spring,
        at now: Double
    ) {
        let c = Color.decodeLiveLanes(lanes)
        liveFillTargets[nid] = c
        liveStore.set(nid, Self.liveColorProp(for: target), to: c.motionColor, anim: .spring(spring), at: now)
    }

    func resolveLiveBoundColor(
        path: String,
        el: El<State>,
        target: BoundLiveProperty.Target,
        fallback: Color
    ) -> Color {
        guard el.liveBindings.contains(where: { $0.target == target }) else {
            return fallback
        }
        let lnid = NodeId.hash("live:\(path):\(target)")
        let prop = Self.liveColorProp(for: target)
        if !liveStore.isMoving(lnid, prop), let exact = liveFillTargets[lnid] {
            return exact
        }
        if let mc = liveStore.get(lnid, prop) {
            return Color(mc)
        }
        return fallback
    }

    func hasUnconsumedLiveBindingChanges() -> Bool {
        for node in flatNodes {
            if let lt = node.el.liveText, lt.sequence != liveTextSeenSeq[node.path] {
                return true
            }
            for b in node.el.liveBindings {
                let lk = LiveKey(path: node.path, target: b.target)
                if liveSeenSeq[lk] != b.source.readSnapshot().seq {
                    return true
                }
            }
        }
        return false
    }
}
