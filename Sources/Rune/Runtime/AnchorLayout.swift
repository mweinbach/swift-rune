import Foundation
import RuneMotion

/// One edge-fade clip scope (`clipFade`, `clipFadeLinear`, or `scrollEdgeFade`).
/// Positive `widths` use smoothstep (`partial`); negative `widths` use linear (`partialLinear`).
struct EdgeFadeSpec {
    var rect: MotionRect
    var widths: SIMD4<Float>
    var strengths: SIMD4<Float>
    /// Precomputed `(offsetLeft, offsetTop, offsetRight, offsetBottom)` from `ScrollEdgeMath.edgeRamp`.
    /// When set, `widths` holds the signed effective ramp widths directly.
    var packedOffsets: SIMD4<Float>? = nil
    /// Enclosing scroll path if emitted by `.scrollFade` (used to interact with `sticky*` / `belowSticky`).
    var scrollPath: String? = nil
    var belowSticky: Bool = false
}

/// Re-solves `LayoutEngine` once when any `.anchoredFit(...)` overlay fits on neither side
/// of its anchor and must be bounded to the larger side's available room (`anchor.rs:120-148`),
/// and provides zoomed anchor attachment + multi-edge scroll fade helpers.
enum AnchorLayoutHelper {
    struct PlacedAnchor {
        var key: String?
        var target: MotionRect
        var zoomedTarget: MotionRect
        var scale: Float
    }

    struct AncestorScaleStep {
        var rect: MotionRect
        var scale: Float
        var origin: Vec2
        var resetsAncestors: Bool
    }

    /// Computes where a layout rect `t` draws after composing ancestor `.scale` pivots (`anchor.rs:186-212`).
    static func zoomedRect(_ t: MotionRect, chain: [AncestorScaleStep]) -> MotionRect {
        var k: Float = 1.0
        var from = Vec2.zero
        var to = Vec2.zero
        for step in chain {
            if step.resetsAncestors {
                k = 1.0
                from = .zero
                to = .zero
            }
            if abs(step.scale - 1.0) <= 1e-5 { continue }
            let pivot = Vec2(
                step.rect.x + step.origin.x * step.rect.width,
                step.rect.y + step.origin.y * step.rect.height
            )
            to = Vec2(to.x + (pivot.x - from.x) * k, to.y + (pivot.y - from.y) * k)
            from = pivot
            k *= step.scale
        }
        return MotionRect(
            left: to.x + (t.left - from.x) * k,
            top: to.y + (t.top - from.y) * k,
            right: to.x + (t.right - from.x) * k,
            bottom: to.y + (t.bottom - from.y) * k
        )
    }

    /// The point on drawn box `d = [x0, y0, x1, y1]` facing its anchor `t` (`anchor.rs:219-233`).
    static func attachPoint(_ anchor: Anchor, trigger t: [Float], box d: [Float]) -> Vec2 {
        func along(_ lo: Float, _ hi: Float) -> Float {
            switch anchor.align {
            case .start: return lo
            case .center: return (lo + hi) * 0.5
            case .end: return hi
            }
        }
        func facing(_ lo: Float, _ hi: Float, _ tLo: Float, _ tHi: Float) -> Float {
            (lo + hi > tLo + tHi) ? lo : hi
        }
        switch anchor.side {
        case .top, .bottom:
            return Vec2(along(d[0], d[2]), facing(d[1], d[3], t[1], t[3]))
        case .left, .right:
            return Vec2(facing(d[0], d[2], t[0], t[2]), along(d[1], d[3]))
        }
    }

    /// Computes unscaled layout origin `(unx, uny)`, zoomed target size/position `(ax, ay)`,
    /// scale factor `zoom`, and normalized attach pivot for an anchored overlay (`anchor.rs:240-273`).
    static func zoomedPlacement(
        anchor: Anchor,
        triggerZoomed: MotionRect,
        anchorScale: Float,
        localSize: Vec2,
        overlayOwnScale: Vec2,
        viewport: Vec2
    ) -> (unscaledOrigin: Vec2, zoom: Float, attachNorm: Vec2) {
        let zoom = (!anchor.unscaled && overlayOwnScale == Vec2(1, 1)) ? max(0.001, anchorScale) : 1.0
        var zoomedAnchor = anchor
        zoomedAnchor.gap = anchor.gap * zoom
        let w = localSize.x * zoom
        let h = localSize.y * zoom
        let trigger = [triggerZoomed.left, triggerZoomed.top, triggerZoomed.right, triggerZoomed.bottom]
        let (ax, ay) = anchorPosition(zoomedAnchor, trigger: trigger, size: (w, h), viewport: (viewport.x, viewport.y))
        if abs(zoom - 1.0) <= 1e-5 {
            return (Vec2(ax, ay), 1.0, Vec2(0.5, 0.5))
        }
        let pivot = attachPoint(zoomedAnchor, trigger: trigger, box: [ax, ay, ax + w, ay + h])
        let unx = pivot.x + (ax - pivot.x) / zoom
        let uny = pivot.y + (ay - pivot.y) / zoom
        let normX = w > 1e-4 ? (pivot.x - ax) / w : 0.5
        let normY = h > 1e-4 ? (pivot.y - ay) / h : 0.5
        return (Vec2(unx, uny), zoom, Vec2(normX, normY))
    }

    static func collectFitBounds<State>(
        rootEl: El<State>,
        solved: LayoutEngine.ResultNode,
        viewport: Vec2
    ) -> [([Int], Bool, Float)] {
        var boundsToApply: [([Int], Bool, Float)] = [] // (indexPath, vertical, bound)
        var earlier: [PlacedAnchor] = []

        func scan(
            el: El<State>,
            solvedNode: LayoutEngine.ResultNode,
            parentOrigin: Vec2,
            parentScale: Float,
            scaleChain: [AncestorScaleStep],
            indexPath: [Int]
        ) {
            let local = solvedNode.layout.localRect
            var worldX = parentOrigin.x + local.x
            var worldY = parentOrigin.y + local.y
            var anchorScale: Float = 1.0

            if let a = el.anchor,
               let anchorNode = earlier.first(where: { $0.key == a.key }) {
                let placement = zoomedPlacement(
                    anchor: a,
                    triggerZoomed: anchorNode.zoomedTarget,
                    anchorScale: anchorNode.scale,
                    localSize: Vec2(local.width, local.height),
                    overlayOwnScale: el.scale,
                    viewport: viewport
                )
                worldX = placement.unscaledOrigin.x
                worldY = placement.unscaledOrigin.y
                anchorScale = placement.zoom
                if a.fit {
                    let zoom = placement.zoom
                    var zoomedAnchor = a
                    zoomedAnchor.gap = a.gap * zoom
                    let zt = anchorNode.zoomedTarget
                    let trigger = [zt.left, zt.top, zt.right, zt.bottom]
                    let vertical = (a.side == .top || a.side == .bottom)
                    let len = vertical ? local.height : local.width
                    if let bound = anchorFitBound(zoomedAnchor, trigger: trigger, length: len * zoom, viewport: (viewport.x, viewport.y)) {
                        boundsToApply.append((indexPath, vertical, bound / zoom))
                    }
                }
            }

            let ownZoom = (el.anchor == nil ? parentScale : anchorScale) * el.scale.x
            let rect = MotionRect.fromXYWH(worldX, worldY, local.width, local.height)
            let zRect = zoomedRect(rect, chain: scaleChain)
            earlier.append(PlacedAnchor(key: el.keyId, target: rect, zoomedTarget: zRect, scale: ownZoom))

            let step = AncestorScaleStep(
                rect: rect,
                scale: (el.anchor != nil) ? ownZoom : el.scale.x,
                origin: (el.anchor != nil) ? .zero : el.origin,
                resetsAncestors: el.anchor != nil
            )
            let nextChain = scaleChain + [step]
            let count = min(el.children.count, solvedNode.children.count)
            for i in 0..<count {
                scan(
                    el: el.children[i],
                    solvedNode: solvedNode.children[i],
                    parentOrigin: Vec2(worldX, worldY),
                    parentScale: ownZoom,
                    scaleChain: nextChain,
                    indexPath: indexPath + [i]
                )
            }
        }

        scan(el: rootEl, solvedNode: solved, parentOrigin: .zero, parentScale: 1.0, scaleChain: [], indexPath: [])
        return boundsToApply
    }

    static func fitIfNeeded<State>(
        rootEl: El<State>,
        rootInput: inout LayoutInputNode,
        solved: inout LayoutEngine.ResultNode,
        viewport: Vec2
    ) {
        let boundsToApply = collectFitBounds(rootEl: rootEl, solved: solved, viewport: viewport)
        guard !boundsToApply.isEmpty else { return }

        func mutateInput(_ node: inout LayoutInputNode, path: ArraySlice<Int>, vertical: Bool, maxLen: Float) {
            if let first = path.first {
                guard first < node.children.count else { return }
                mutateInput(&node.children[first], path: path.dropFirst(), vertical: vertical, maxLen: maxLen)
            } else {
                if vertical {
                    node.style.maxHeight = .points(maxLen)
                } else {
                    node.style.maxWidth = .points(maxLen)
                }
            }
        }

        for (idxPath, vertical, bound) in boundsToApply {
            mutateInput(&rootInput, path: idxPath[...], vertical: vertical, maxLen: bound)
        }
        solved = LayoutEngine.compute(root: rootInput, viewport: viewport)
    }

    /// Upstream `partial(width, strength)` (`scroll/edge.rs:11-18`).
    static func partialEdge(width: Float, strength: Float) -> (width: Float, offset: Float) {
        if strength <= 0 || width <= 0 { return (0, 0) }
        if strength >= 1 { return (width, 0) }
        let clampedS = (2.0 * strength - 1.0).clamped(to: -1.0...1.0)
        let offset = (0.5 - sinf(asinf(clampedS) / 3.0)).clamped(to: 0.0...0.995)
        return (width / (1.0 - offset), offset)
    }

    /// Upstream `partial_linear(width, strength)` (`scroll/edge.rs:116-121`).
    static func partialLinearEdge(width: Float, strength: Float) -> (width: Float, offset: Float) {
        if strength <= 0 || width <= 0 { return (0, 0) }
        if strength >= 1 { return (width, 0) }
        let offset = min(0.995, 1.0 - strength)
        return (width / (1.0 - offset), offset)
    }

    /// Returns ALL matching edge fade vectors/origins for `specs` touching `primRectPx`
    /// (`scroll/edge.rs:37-59, 102-121`).
    static func edgeFadeEdges(
        specs: [EdgeFadeSpec],
        primRectPx: SIMD4<Float>,
        pxScale: Float
    ) -> [(fade: SIMD4<Float>, origin: SIMD2<Float>)] {
        guard !specs.isEmpty else { return [] }
        let primTop = primRectPx.y
        let primBot = primRectPx.y + primRectPx.w
        let primLeft = primRectPx.x
        let primRight = primRectPx.x + primRectPx.z

        var out: [(fade: SIMD4<Float>, origin: SIMD2<Float>)] = []
        for spec in specs {
            let clipTopPx = spec.rect.top * pxScale
            let clipBotPx = spec.rect.bottom * pxScale
            let clipLeftPx = spec.rect.left * pxScale
            let clipRightPx = spec.rect.right * pxScale

            func appendEdge(rawWidth: Float, strength: Float, preOffset: Float?, touches: Bool, dir: SIMD2<Float>, baseOrigin: SIMD2<Float>) {
                guard touches, abs(rawWidth) > 0.05 else { return }
                let widthPx = abs(rawWidth) * pxScale
                let (effW, offset): (Float, Float)
                if let preOffset {
                    (effW, offset) = (widthPx, preOffset)
                } else {
                    guard strength > 0, abs(rawWidth) > 0.5 else { return }
                    (effW, offset) = (rawWidth < 0)
                        ? partialLinearEdge(width: widthPx, strength: strength)
                        : partialEdge(width: widthPx, strength: strength)
                }
                guard effW > 0 else { return }
                let shiftedOrigin = baseOrigin - dir * (offset * effW)
                out.append((
                    fade: SIMD4<Float>(dir.x, dir.y, 1.0 / max(1, effW), 0.0),
                    origin: shiftedOrigin
                ))
            }

            // widths = [left, top, right, bottom]; strengths = [left, top, right, bottom]
            let po = spec.packedOffsets
            appendEdge(
                rawWidth: spec.widths.y,
                strength: spec.strengths.y,
                preOffset: po?.y,
                touches: primTop < clipTopPx + abs(spec.widths.y) * pxScale,
                dir: SIMD2<Float>(0, 1),
                baseOrigin: SIMD2<Float>(0, clipTopPx)
            )
            appendEdge(
                rawWidth: spec.widths.w,
                strength: spec.strengths.w,
                preOffset: po?.w,
                touches: primBot > clipBotPx - abs(spec.widths.w) * pxScale,
                dir: SIMD2<Float>(0, -1),
                baseOrigin: SIMD2<Float>(0, clipBotPx)
            )
            appendEdge(
                rawWidth: spec.widths.x,
                strength: spec.strengths.x,
                preOffset: po?.x,
                touches: primLeft < clipLeftPx + abs(spec.widths.x) * pxScale,
                dir: SIMD2<Float>(1, 0),
                baseOrigin: SIMD2<Float>(clipLeftPx, 0)
            )
            appendEdge(
                rawWidth: spec.widths.z,
                strength: spec.strengths.z,
                preOffset: po?.z,
                touches: primRight > clipRightPx - abs(spec.widths.z) * pxScale,
                dir: SIMD2<Float>(-1, 0),
                baseOrigin: SIMD2<Float>(clipRightPx, 0)
            )
        }
        return out
    }
}
