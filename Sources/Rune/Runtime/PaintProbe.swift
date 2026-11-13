import Foundation
import RuneMotion

extension Runtime {
    /// Captures resolved per-node paint state after animations and live color bindings (`Runtime::paints`).
    public func paints() -> [MotionGateRecording.PaintKey: MotionGatePaint] {
        var out: [MotionGateRecording.PaintKey: MotionGatePaint] = [:]
        out.reserveCapacity(flatNodes.count + exitingSnapshots.count)

        var rankCounter: UInt32 = 0
        func appendPaint(for node: FlatNode, exiting: Bool) {
            let nid = node.nodeId
            let el = node.el

            let pressed = !node.effectiveInert && pressedPath == node.path
            let hoverTrackId = Self.hoverTrackId(nid)
            let hoverFrac = exiting ? 0.0 : (liveStore.get(hoverTrackId, Self.hoverProp) ?? 0.0)
            let hovered = !exiting && (hoverFrac > 0.0005 || (!node.effectiveInert && hoveredPath == node.path))

            var effFill = color(nid, Props.FILL, fallback: el.background)
            effFill = resolveLiveBoundColor(path: node.path, el: el, target: .fill, fallback: effFill)
            if pressed, let pbg = el.pressBg {
                effFill = blendColorOver(bottom: effFill, top: pbg, srgb: srgbBlend)
            } else if let hbg = el.hoverBg {
                let effectiveHover = hoverFrac > 0.0005 ? hoverFrac : (hovered ? 1.0 : 0.0)
                if effectiveHover > 0.0005 {
                    effFill = blendColorOver(bottom: effFill, top: hbg.scaleAlpha(effectiveHover), srgb: srgbBlend)
                }
            }

            let borderCol = resolvedPaintBorderColor(id: nid, path: node.path, el: el)
            let textCol = el.textColor != nil
                ? resolvedPaintTextColor(id: nid, path: node.path, el: el, fallback: el.textColor ?? .transparent)
                : resolveLiveBoundColor(path: node.path, el: el, target: .textColor, fallback: .transparent)
            let shadowCol = el.shadows.first.map {
                resolvedPaintShadowColor(id: nid, path: node.path, el: el, index: 0, authored: $0.color)
            } ?? resolveLiveBoundColor(path: node.path, el: el, target: .shadowColor, fallback: .transparent)

            var gradStart: Color = .transparent
            var gradEnd: Color = .transparent
            if let stops = Self.authoredGradientStops(for: el) {
                let resolved = resolvedPaintGradientColors(
                    id: nid,
                    path: node.path,
                    el: el,
                    top: stops.top,
                    bottom: stops.bottom
                )
                gradStart = resolved.top
                gradEnd = resolved.bottom
            } else if el.liveBindings.contains(where: { $0.target == .gradientTop || $0.target == .gradientBottom }) {
                gradStart = resolveLiveBoundColor(path: node.path, el: el, target: .gradientTop, fallback: .transparent)
                gradEnd = resolveLiveBoundColor(path: node.path, el: el, target: .gradientBottom, fallback: .transparent)
            }
            let outlineCol = el.focusRingColor.map {
                resolvedPaintOutlineColor(id: nid, el: el, fallback: $0)
            } ?? .transparent

            var colors = Array(repeating: Color.transparent, count: MotionGatePaint.colorCount)
            colors[MotionGatePaint.cFill] = effFill
            colors[MotionGatePaint.cBorder] = borderCol
            colors[MotionGatePaint.cText] = textCol
            colors[MotionGatePaint.cShadow] = shadowCol
            colors[MotionGatePaint.cGradient] = gradStart
            colors[MotionGatePaint.cOutline] = outlineCol

            let corners = scene.get(nid, Props.CORNERS) ?? el.corners
            let blurVal = scene.get(nid, Props.BLUR)?.radius ?? el.blur
            var sizes = Array(repeating: Float(0), count: MotionGatePaint.sizeCount)
            sizes[MotionGatePaint.sRadius] = corners.topLeft
            sizes[MotionGatePaint.sBorder] = el.borderWidth
            sizes[MotionGatePaint.sBlur] = blurVal
            sizes[MotionGatePaint.sBackdrop] = el.backdropBlur
            sizes[MotionGatePaint.sShadow] = el.shadows.first?.blur ?? 0

            var totalIntent: UInt16 = (el.runtimeExtras[MotionGateExtraKey.motionIntent] as? UInt16) ?? 0
            var totalInstant = el.hasInstantChanges || ((el.runtimeExtras[MotionGateExtraKey.instantChanges] as? Bool) ?? false)
            var curParentIdx = node.parentIndex
            while let pIdx = curParentIdx, pIdx < flatNodes.count {
                let pEl = flatNodes[pIdx].el
                if let pi = pEl.runtimeExtras[MotionGateExtraKey.motionIntent] as? UInt16 {
                    totalIntent |= pi
                }
                if pEl.hasInstantChanges || ((pEl.runtimeExtras[MotionGateExtraKey.instantChanges] as? Bool) ?? false) {
                    totalInstant = true
                }
                curParentIdx = flatNodes[pIdx].parentIndex
            }
            let ownMotionNone = (el.runtimeExtras[MotionGateExtraKey.ownMotionNone] as? Bool) ?? false
            let ownBlurNone = el.runtimeExtras[MotionGateExtraKey.ownBlurNone] as? Bool
            let atOnce = MotionGatePaintUtils.atOnceBits(motion: ownMotionNone, blur: ownBlurNone)
            let effData = (el.runtimeExtras[RenderExtrasKey.effectSpec] as? RenderEffectSpec)?.data

            rankCounter &+= 1
            let paint = MotionGatePaint(
                colors: colors,
                sizes: sizes,
                gradientEnd: gradEnd,
                effect: effData,
                image: nil,
                rank: rankCounter,
                intent: totalIntent,
                instant: totalInstant,
                atOnce: atOnce,
                pointer: SIMD2<Float>(exiting ? 0 : (hoverFrac > 0 ? hoverFrac : (hovered ? 1 : 0)), pressed ? 1 : 0)
            )
            out[MotionGateRecording.PaintKey(path: node.path, exiting: exiting)] = paint
        }

        for node in flatNodes {
            appendPaint(for: node, exiting: false)
        }
        for (nid, snap) in exitingSnapshots {
            if case .exiting = scene.phase(nid) {
                appendPaint(for: snap, exiting: true)
            }
        }
        return out
    }
}
