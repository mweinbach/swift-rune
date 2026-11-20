import Foundation

/// Bounded layer planning matching `rune::render::layers` and `Instance::layer_bounds`
/// (upstream `crates/rune-ref/src/layer.rs`).
enum OracleLayer {
    /// Maximum offscreen dimension for a cached subtree (`layers::MAX_CACHE_DIM`).
    private static let maxCacheDim: Float = 4096.0

    struct LayerCtx: Sendable {
        var viewport: (UInt32, UInt32)
        var limit: [Float]
        var free: Bool
        var frame: [Float]

        static func root(_ viewport: (UInt32, UInt32)) -> LayerCtx {
            LayerCtx(
                viewport: viewport,
                limit: oracleNoClip,
                free: false,
                frame: [0.0, 0.0, 0.0, 0.0]
            )
        }

        func inlineChild(_ clip: [Float]) -> LayerCtx {
            if free {
                return LayerCtx(
                    viewport: viewport,
                    limit: limit,
                    free: free,
                    frame: [
                        max(frame[0], clip[0]),
                        max(frame[1], clip[1]),
                        min(frame[2], clip[2]),
                        min(frame[3], clip[3]),
                    ]
                )
            } else {
                return LayerCtx(
                    viewport: viewport,
                    limit: [
                        max(clip[0], limit[0]),
                        max(clip[1], limit[1]),
                        min(clip[2], limit[2]),
                        min(clip[3], limit[3]),
                    ],
                    free: free,
                    frame: frame
                )
            }
        }
    }

    struct PlannedScope: Sendable {
        var childCtx: LayerCtx
        /// Integer-aligned target edges `[x0, y0, x1, y1]` in device pixels.
        var target: (Int32, Int32, Int32, Int32)
        /// Edges propagated to an enclosing uncached parent (after any turn).
        var outer: [Float]
        var visible: Bool
    }

    static func findLayerClose(_ primitives: [OraclePrimitive], start: Int, end: Int) -> Int {
        var depth = 1
        var close = start + 1
        while close < end && depth > 0 {
            if primitives[close].params[1] == 8.0 {
                depth += 1
            } else if primitives[close].params[1] == 9.0 {
                depth -= 1
            }
            if depth > 0 {
                close += 1
            }
        }
        return close
    }

    /// Whether a layer's clip matches a hardware scissor (`layers/plan.rs` `is_scissor_clip`).
    static func isScissorClip(_ clip: [Float], _ fade: [Float]) -> Bool {
        clip == oracleNoClip
            || (fade == [0.0, 0.0, 0.0, 0.0] && clip.allSatisfy { abs($0 - roundf($0)) < 1e-3 })
    }

    /// Upright bounds of edges `r` (`[x0, y0, x1, y1]`) turned `angle` radians clockwise about `p`.
    static func turnedBounds(_ r: [Float], angle: Float, pivot p: (Float, Float)) -> [Float] {
        let sn = sinf(angle)
        let c = cosf(angle)
        var out: [Float] = [.infinity, .infinity, -.infinity, -.infinity]
        let corners: [(Float, Float)] = [
            (r[0], r[1]),
            (r[2], r[1]),
            (r[0], r[3]),
            (r[2], r[3]),
        ]
        for (x, y) in corners {
            let dx = x - p.0
            let dy = y - p.1
            let qx = p.0 + c * dx - sn * dy
            let qy = p.1 + sn * dx + c * dy
            out = [min(out[0], qx), min(out[1], qy), max(out[2], qx), max(out[3], qy)]
        }
        return out
    }

    private static func unionBounds(_ a: inout [Float], _ b: [Float]) {
        if b[2] <= b[0] || b[3] <= b[1] {
            return
        }
        a[0] = min(a[0], b[0])
        a[1] = min(a[1], b[1])
        a[2] = max(a[2], b[2])
        a[3] = max(a[3], b[3])
    }

    private static func clampBand(_ rect: [Float], _ uv: [Float], _ b: [Float]) -> [Float] {
        let x0 = max(b[0], rect[0] + uv[0])
        let y0 = max(b[1], rect[1] + uv[1])
        let x1 = max(min(b[2], rect[0] - uv[2]), x0)
        let y1 = max(min(b[3], rect[1] + uv[3]), y0)
        return [x0, y0, x1, y1]
    }

    @inline(__always)
    private static func satInt32(_ x: Float) -> Int32 {
        if x.isNaN { return 0 }
        if x <= Float(Int32.min) { return Int32.min }
        if x >= Float(Int32.max) { return Int32.max }
        return Int32(x)
    }

    /// Device-pixel bounds `[x0, y0, x1, y1]` a non-scope primitive contributes to an enclosing
    /// uncached layer (`instance.rs` `layer_bounds_non_scope`).
    private static func primitiveLayerBounds(_ p: OraclePrimitive) -> [Float] {
        let kind = UInt32(p.params[1])
        let b: [Float]
        if kind == 2 {
            if p.params[0] != 0.0 {
                let sn = sinf(p.params[0])
                let cs = cosf(p.params[0])
                let w = abs(cs) * p.rect[2] + abs(sn) * p.rect[3]
                let h = abs(sn) * p.rect[2] + abs(cs) * p.rect[3]
                let x0 = p.rect[0] + (p.rect[2] - w) * 0.5
                let y0 = p.rect[1] + (p.rect[3] - h) * 0.5
                b = [x0, y0, x0 + w, y0 + h]
            } else {
                b = [p.rect[0], p.rect[1], p.rect[0] + p.rect[2], p.rect[1] + p.rect[3]]
            }
        } else {
            let grow: Float = switch kind {
            case 1: 1.0 + p.params[2] * 3.0
            case 3, 5, 6: 1.0
            case 12: 1.0 + p.params[2]
            default: 1.0 + p.params[2] * 2.0
            }
            let grown: [Float] = [
                p.rect[0] - grow,
                p.rect[1] - grow,
                p.rect[0] + p.rect[2] + grow,
                p.rect[1] + p.rect[3] + grow,
            ]
            if kind <= 1 && p.uv[2] < 0.0 {
                b = clampBand(p.rect, p.uv, grown)
            } else {
                b = grown
            }
        }
        return [
            max(b[0], p.clip[0]),
            max(b[1], p.clip[1]),
            min(b[2], p.clip[2]),
            min(b[3], p.clip[3]),
        ]
    }

    /// Plans a layer scope at `start` (`close` is its matching kind 9) matching `layers.rs`.
    static func planScope(
        _ primitives: [OraclePrimitive],
        start: Int,
        close: Int,
        parent: LayerCtx
    ) -> PlannedScope {
        let p = primitives[start]
        let turn: (Float, (Float, Float))? = p.turn.flatMap { t in
            t[0] != 0.0 ? (t[0], (t[1], t[2])) : nil
        }
        let free = turn != nil || parent.free
        let frame: [Float]
        if free {
            let outer: [Float] = if parent.free {
                parent.frame
            } else {
                [0.0, 0.0, Float(parent.viewport.0), Float(parent.viewport.1)]
            }
            let shown: [Float] = [
                max(outer[0], p.clip[0]),
                max(outer[1], p.clip[1]),
                min(outer[2], p.clip[2]),
                min(outer[3], p.clip[3]),
            ]
            if let (angle, pivot) = turn, shown[2] > shown[0] && shown[3] > shown[1] {
                frame = turnedBounds(shown, angle: -angle, pivot: pivot)
            } else {
                frame = shown
            }
        } else {
            frame = [0.0, 0.0, 0.0, 0.0]
        }

        let limit = parent.free ? oracleNoClip : parent.limit
        let childLimit: [Float] = if free {
            oracleNoClip
        } else {
            [
                max(p.clip[0], limit[0]),
                max(p.clip[1], limit[1]),
                min(p.clip[2], limit[2]),
                min(p.clip[3], limit[3]),
            ]
        }
        let childCtx = LayerCtx(
            viewport: parent.viewport,
            limit: childLimit,
            free: free,
            frame: frame
        )

        let cached = p.params[3] == 1.0
        var edges: [Float] = [p.rect[0], p.rect[1], p.rect[0] + p.rect[2], p.rect[1] + p.rect[3]]
        if !cached {
            var cursor = start + 1
            while cursor < close {
                let child = primitives[cursor]
                if child.params[1] == 8.0 {
                    let subClose = findLayerClose(primitives, start: cursor, end: close)
                    let sub = planScope(primitives, start: cursor, close: subClose, parent: childCtx)
                    unionBounds(&edges, sub.outer)
                    cursor = subClose + 1
                } else if child.params[1] == 9.0 {
                    cursor += 1
                } else {
                    unionBounds(&edges, primitiveLayerBounds(child))
                    cursor += 1
                }
            }
        }

        let vis: [Float]
        if free {
            vis = [
                floorf(max(edges[0], frame[0])),
                floorf(max(edges[1], frame[1])),
                ceilf(min(edges[2], frame[2])),
                ceilf(min(edges[3], frame[3])),
            ]
        } else {
            vis = [
                floorf(max(max(edges[0], max(p.clip[0], limit[0])), 0.0)),
                floorf(max(max(edges[1], max(p.clip[1], limit[1])), 0.0)),
                ceilf(min(min(edges[2], min(p.clip[2], limit[2])), Float(parent.viewport.0))),
                ceilf(min(min(edges[3], min(p.clip[3], limit[3])), Float(parent.viewport.1))),
            ]
        }

        var visible = true
        let targetEdges: [Float]
        if cached {
            if vis[2] <= vis[0] || vis[3] <= vis[1] {
                visible = false
            }
            let full: [Float] = [floorf(edges[0]), floorf(edges[1]), ceilf(edges[2]), ceilf(edges[3])]
            if full[2] - full[0] <= maxCacheDim && full[3] - full[1] <= maxCacheDim {
                targetEdges = full
            } else {
                targetEdges = vis
            }
        } else {
            targetEdges = vis
        }
        if targetEdges[2] <= targetEdges[0] || targetEdges[3] <= targetEdges[1] {
            visible = false
        }

        let outer: [Float]
        if let (angle, pivot) = turn, targetEdges[2] > targetEdges[0] && targetEdges[3] > targetEdges[1] {
            outer = turnedBounds(targetEdges, angle: angle, pivot: pivot)
        } else {
            outer = targetEdges
        }

        return PlannedScope(
            childCtx: childCtx,
            target: (
                satInt32(targetEdges[0]),
                satInt32(targetEdges[1]),
                satInt32(targetEdges[2]),
                satInt32(targetEdges[3])
            ),
            outer: outer,
            visible: visible
        )
    }
}
