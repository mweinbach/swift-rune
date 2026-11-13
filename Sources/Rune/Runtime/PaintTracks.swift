import Foundation
import RuneMotion

internal struct PaintTrackBaseline: Sendable {
    var textColor: Color?
    var shadowColor: Color?
    var gradientTop: Color?
    var gradientBottom: Color?
    var outlineColor: Color?
    var shadowGeos: [Sides] = []
}

extension Runtime {
    /// Commits pending state/transaction updates synchronously (`Runtime::commit`).
    public func commit(_ tx: Tx = Tx(), at now: Double? = nil) {
        let t = now ?? currentTime
        applyTx(tx, at: t, markDirtyIfNotLiveOnly: false)
        if needsCommit {
            needsCommit = false
            commitTree(at: t, cut: false)
        }
    }

    /// Samples an active or settled color property on `scene.store`, falling back to `fallback`
    /// when untracked or settled within `1e-3` (`Runtime::color`).
    public func color(_ id: NodeId, _ prop: Prop<MotionColor>, fallback: Color) -> Color {
        guard let mc = scene.store.get(id, prop) else {
            return fallback
        }
        let settledMatch = !scene.store.isMoving(id, prop)
            && abs(mc.r - fallback.r) < 1e-3
            && abs(mc.g - fallback.g) < 1e-3
            && abs(mc.b - fallback.b) < 1e-3
            && abs(mc.a - fallback.a) < 1e-3
        if settledMatch || mc == fallback.motionColor {
            return fallback
        }
        return Color(mc)
    }

    /// Whether a `MotionTrace` or trace channels are currently active (`Runtime::tracing`).
    public var tracing: Bool {
        traceChannels != nil || scene.isTracing
    }
}

internal extension Runtime {
    static func authoredGradientStops(for el: El<State>) -> (top: Color, bottom: Color)? {
        if let lg = el.runtimeExtras[RenderExtrasKey.linearGradient] as? RenderLinearGradientSpec,
           let first = lg.stops.first?.color,
           let last = lg.stops.last?.color {
            return (first, last)
        }
        if let grad = el.gradient {
            switch grad {
            case let .linear(top, bottom, _):
                return (top, bottom)
            case let .radial(inner, outer):
                return (inner, outer)
            }
        }
        return nil
    }

    func commitExtraPaintTracks(
        nodes: [FlatNode],
        specs: [NodeSpec],
        cut: Bool
    ) {
        let count = min(nodes.count, specs.count)
        for i in 0..<count {
            let nid = nodes[i].nodeId
            let el = nodes[i].el
            let grad = Self.authoredGradientStops(for: el)
            let nextGeos = el.shadows.map { Sides(top: $0.x, right: $0.y, bottom: $0.blur, left: $0.spread) }
            let next = PaintTrackBaseline(
                textColor: el.textColor,
                shadowColor: el.shadows.first?.color,
                gradientTop: grad?.top,
                gradientBottom: grad?.bottom,
                outlineColor: el.focusRingColor,
                shadowGeos: nextGeos
            )
            let colorSp: Spring? = cut ? nil : specs[i].colorSpring
            let styleSp: Spring? = cut ? nil : specs[i].styleSpring
            let textSp: Spring? = colorSp.map {
                Spring(duration: max(0.1, $0.duration * 0.5), bounce: $0.bounce)
            }

            if !cut, let prev = paintTrackBaselines[nid] {
                syncPaintColorChannel(
                    id: nid,
                    prop: Props.TEXT_COLOR,
                    prev: prev.textColor,
                    next: next.textColor,
                    spring: textSp
                )
                syncPaintColorChannel(
                    id: nid,
                    prop: Props.SHADOW_COLOR,
                    prev: prev.shadowColor,
                    next: next.shadowColor,
                    spring: colorSp
                )
                syncPaintColorChannel(
                    id: nid,
                    prop: Props.GRADIENT_TOP,
                    prev: prev.gradientTop,
                    next: next.gradientTop,
                    spring: colorSp
                )
                syncPaintColorChannel(
                    id: nid,
                    prop: Props.GRADIENT_BOTTOM,
                    prev: prev.gradientBottom,
                    next: next.gradientBottom,
                    spring: colorSp
                )
                syncPaintColorChannel(
                    id: nid,
                    prop: Props.OUTLINE_COLOR,
                    prev: prev.outlineColor,
                    next: next.outlineColor,
                    spring: colorSp
                )
                syncShadowGeoChannels(
                    id: nid,
                    prev: prev.shadowGeos,
                    next: nextGeos,
                    spring: styleSp
                )
            } else if cut {
                for (shIdx, geo) in nextGeos.enumerated() {
                    let shKey = Self.shadowGeoTrackId(nid, index: shIdx)
                    if scene.store.has(shKey, Props.SHADOW_GEO) {
                        scene.store.set(shKey, Props.SHADOW_GEO, geo)
                    }
                }
                if let prev = paintTrackBaselines[nid], prev.shadowGeos.count > nextGeos.count {
                    for shIdx in nextGeos.count..<prev.shadowGeos.count {
                        scene.store.removeNode(Self.shadowGeoTrackId(nid, index: shIdx))
                    }
                }
            }
            paintTrackBaselines[nid] = next
        }
        for (id, prev) in paintTrackBaselines where !scene.hasNode(id) {
            for shIdx in prev.shadowGeos.indices {
                scene.store.removeNode(Self.shadowGeoTrackId(id, index: shIdx))
            }
        }
        paintTrackBaselines = paintTrackBaselines.filter { scene.hasNode($0.key) }
    }

    static func shadowGeoTrackId(_ id: NodeId, index: Int) -> NodeId {
        NodeId(id.rawValue ^ (UInt64(index + 1) &* 0x9E37_79B9_7F4A_7C15))
    }

    private func syncShadowGeoChannels(
        id: NodeId,
        prev: [Sides],
        next: [Sides],
        spring: Spring?
    ) {
        if prev.count > next.count {
            for idx in next.count..<prev.count {
                scene.store.removeNode(Self.shadowGeoTrackId(id, index: idx))
            }
        }
        for (idx, nextGeo) in next.enumerated() {
            let shKey = Self.shadowGeoTrackId(id, index: idx)
            guard idx < prev.count else {
                // Newly mounted / re-added shadow must start at its own geometry, not an older removed track.
                scene.store.removeNode(shKey)
                continue
            }
            let prevGeo = prev[idx]
            if let spring {
                if prevGeo != nextGeo || (scene.store.has(shKey, Props.SHADOW_GEO) && scene.store.target(shKey, Props.SHADOW_GEO) != nextGeo) {
                    if !scene.store.has(shKey, Props.SHADOW_GEO) {
                        scene.store.snap(shKey, Props.SHADOW_GEO, to: prevGeo)
                    }
                    _ = scene.store.animate(
                        shKey,
                        Props.SHADOW_GEO,
                        to: nextGeo,
                        anim: Anim<Sides>(curve: Curve.from(spring))
                    )
                }
            } else if scene.store.has(shKey, Props.SHADOW_GEO) {
                scene.store.set(shKey, Props.SHADOW_GEO, nextGeo)
            }
        }
    }

    private func syncPaintColorChannel(
        id: NodeId,
        prop: Prop<MotionColor>,
        prev: Color?,
        next: Color?,
        spring: Spring?
    ) {
        guard let next else { return }
        if let spring {
            guard let prev else { return }
            if prev != next || (scene.store.has(id, prop) && scene.store.target(id, prop) != next.motionColor) {
                if !scene.store.has(id, prop) {
                    scene.store.snap(id, prop, to: prev.motionColor)
                }
                _ = scene.store.animate(
                    id,
                    prop,
                    to: next.motionColor,
                    anim: Anim<MotionColor>(curve: Curve.from(spring))
                )
            }
        } else if scene.store.has(id, prop) {
            scene.store.set(id, prop, next.motionColor)
        }
    }

    func resolvedPaintBorderColor(id: NodeId, path: String, el: El<State>, presentedBorder: MotionColor? = nil) -> Color {
        let base: Color
        if let pb = presentedBorder {
            let settledMatch = !scene.store.isMoving(id, Props.BORDER)
                && abs(pb.r - el.borderColor.r) < 1e-3
                && abs(pb.g - el.borderColor.g) < 1e-3
                && abs(pb.b - el.borderColor.b) < 1e-3
                && abs(pb.a - el.borderColor.a) < 1e-3
            base = (settledMatch || pb == el.borderColor.motionColor) ? el.borderColor : Color(pb)
        } else {
            base = color(id, Props.BORDER, fallback: el.borderColor)
        }
        return resolveLiveBoundColor(path: path, el: el, target: .borderColor, fallback: base)
    }

    func resolvedPaintTextColor(id: NodeId, path: String, el: El<State>, fallback: Color) -> Color {
        let animCol = el.textColor.map { color(id, Props.TEXT_COLOR, fallback: $0) } ?? fallback
        return resolveLiveBoundColor(path: path, el: el, target: .textColor, fallback: animCol)
    }

    func resolvedPaintShadowColor(id: NodeId, path: String, el: El<State>, index: Int, authored: Color) -> Color {
        guard index == 0 else { return authored }
        let animCol = color(id, Props.SHADOW_COLOR, fallback: authored)
        return resolveLiveBoundColor(path: path, el: el, target: .shadowColor, fallback: animCol)
    }

    func resolvedPaintShadowGeometry(id: NodeId, index: Int, authored: Shadow) -> Shadow {
        let shKey = Self.shadowGeoTrackId(id, index: index)
        guard let geo = scene.store.get(shKey, Props.SHADOW_GEO) else {
            return authored
        }
        let settledMatch = !scene.store.isMoving(shKey, Props.SHADOW_GEO)
            && abs(geo.top - authored.x) < 1e-3
            && abs(geo.right - authored.y) < 1e-3
            && abs(geo.bottom - authored.blur) < 1e-3
            && abs(geo.left - authored.spread) < 1e-3
        if settledMatch {
            return authored
        }
        var out = authored
        out.x = geo.top
        out.y = geo.right
        out.blur = max(0, geo.bottom)
        out.spread = geo.left
        return out
    }

    func resolvedPaintGradientColors(id: NodeId, path: String, el: El<State>, top: Color, bottom: Color) -> (top: Color, bottom: Color) {
        let animTop = color(id, Props.GRADIENT_TOP, fallback: top)
        let animBot = color(id, Props.GRADIENT_BOTTOM, fallback: bottom)
        let finalTop = resolveLiveBoundColor(path: path, el: el, target: .gradientTop, fallback: animTop)
        let finalBot = resolveLiveBoundColor(path: path, el: el, target: .gradientBottom, fallback: animBot)
        return (finalTop, finalBot)
    }

    func resolvedPaintOutlineColor(id: NodeId, el: El<State>, fallback: Color) -> Color {
        if let authored = el.focusRingColor {
            return color(id, Props.OUTLINE_COLOR, fallback: authored)
        }
        return fallback
    }
}
