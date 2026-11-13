import Foundation
import RuneMotion

/// Re-solves `LayoutEngine` once when any `.anchoredFit(...)` overlay fits on neither side
/// of its anchor and must be bounded to the larger side's available room (`anchor.rs:120-148`).
enum AnchorLayoutHelper {
    struct PlacedAnchor {
        var key: String?
        var target: MotionRect
        var scale: Float
    }

    static func fitIfNeeded<State>(
        rootEl: El<State>,
        rootInput: inout LayoutInputNode,
        solved: inout LayoutEngine.ResultNode,
        viewport: Vec2
    ) {
        var boundsToApply: [([Int], Bool, Float)] = [] // (indexPath, vertical, bound)
        var earlier: [PlacedAnchor] = []

        func scan(
            el: El<State>,
            solvedNode: LayoutEngine.ResultNode,
            parentOrigin: Vec2,
            parentScale: Float,
            indexPath: [Int]
        ) {
            let local = solvedNode.layout.localRect
            var worldX = parentOrigin.x + local.x
            var worldY = parentOrigin.y + local.y
            let ownZoom = (el.anchor == nil || el.anchor?.unscaled == true || el.scale != Vec2(1, 1))
                ? parentScale * el.scale.x
                : parentScale

            if let a = el.anchor,
               let anchorNode = earlier.first(where: { $0.key == a.key }) {
                let zoom = (!a.unscaled && el.scale == Vec2(1, 1)) ? max(0.001, anchorNode.scale) : 1.0
                let t = anchorNode.target
                let trigger = [t.left, t.top, t.right, t.bottom]
                let size = (local.width * zoom, local.height * zoom)
                let (px, py) = anchorPosition(a, trigger: trigger, size: size, viewport: (viewport.x, viewport.y))
                worldX = px
                worldY = py
                if a.fit {
                    let vertical = (a.side == .top || a.side == .bottom)
                    let len = vertical ? local.height : local.width
                    if let bound = anchorFitBound(a, trigger: trigger, length: len * zoom, viewport: (viewport.x, viewport.y)) {
                        boundsToApply.append((indexPath, vertical, bound / zoom))
                    }
                }
            }

            let rect = MotionRect.fromXYWH(worldX, worldY, local.width, local.height)
            earlier.append(PlacedAnchor(key: el.keyId, target: rect, scale: ownZoom))

            let count = min(el.children.count, solvedNode.children.count)
            for i in 0..<count {
                scan(
                    el: el.children[i],
                    solvedNode: solvedNode.children[i],
                    parentOrigin: Vec2(worldX, worldY),
                    parentScale: ownZoom,
                    indexPath: indexPath + [i]
                )
            }
        }

        scan(el: rootEl, solvedNode: solved, parentOrigin: .zero, parentScale: 1.0, indexPath: [])
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

    /// Computes edge fade `(fadeVec4, fadeOriginPt)` for a clip rectangle in device pixels.
    /// `clipFade` holds `(left, top, right, bottom)` fade widths (positive = soft eased, negative = linear).
    /// Returns the edge fade vector + origin matching `Primitive.fade` `[dirX, dirY, invSpan, minAlpha]`.
    static func edgeFadeParams(
        clipRect: MotionRect,
        primRectPx: SIMD4<Float>,
        pxScale: Float,
        left: Float = 0,
        top: Float = 0,
        right: Float = 0,
        bottom: Float = 0,
        minAlphaTop: Float = 0,
        minAlphaBottom: Float = 0,
        minAlphaLeft: Float = 0,
        minAlphaRight: Float = 0
    ) -> (fade: SIMD4<Float>, origin: SIMD2<Float>) {
        let clipTopPx = clipRect.top * pxScale
        let clipBotPx = clipRect.bottom * pxScale
        let clipLeftPx = clipRect.left * pxScale
        let clipRightPx = clipRect.right * pxScale

        let primTop = primRectPx.y
        let primBot = primRectPx.y + primRectPx.w
        let primLeft = primRectPx.x
        let primRight = primRectPx.x + primRectPx.z

        if abs(top) > 0.5, primTop < clipTopPx + abs(top) * pxScale {
            let wPx = abs(top) * pxScale
            return (SIMD4<Float>(0, 1, 1.0 / max(1, wPx), minAlphaTop), SIMD2<Float>(0, clipTopPx))
        }
        if abs(bottom) > 0.5, primBot > clipBotPx - abs(bottom) * pxScale {
            let wPx = abs(bottom) * pxScale
            return (SIMD4<Float>(0, -1, 1.0 / max(1, wPx), minAlphaBottom), SIMD2<Float>(0, clipBotPx))
        }
        if abs(left) > 0.5, primLeft < clipLeftPx + abs(left) * pxScale {
            let wPx = abs(left) * pxScale
            return (SIMD4<Float>(1, 0, 1.0 / max(1, wPx), minAlphaLeft), SIMD2<Float>(clipLeftPx, 0))
        }
        if abs(right) > 0.5, primRight > clipRightPx - abs(right) * pxScale {
            let wPx = abs(right) * pxScale
            return (SIMD4<Float>(-1, 0, 1.0 / max(1, wPx), minAlphaRight), SIMD2<Float>(clipRightPx, 0))
        }
        return (.zero, .zero)
    }
}
