import Foundation
import Rune

/// Flattens translucent stroke and arrowhead inks against the fills beneath them
/// so overlapping segments and joints do not double-blend (`rune_mermaid::ink`).
enum InkFlattener {
    private struct Area {
        let at: Int
        let bounds: (Float, Float, Float, Float)
        let points: [Vec2]
        let color: Color
    }

    static func flatten(ops: inout [CanvasOp], traces: inout [HoverTrace], surface: Color) {
        var inks: [Color] = []
        for op in ops {
            if case let .stroke(_, _, _, _, color) = op, isTranslucent(color), !inks.contains(color) {
                inks.append(color)
            }
        }
        for trace in traces {
            for op in trace.ops {
                if case let .stroke(_, _, _, _, color) = op, isTranslucent(color), !inks.contains(color) {
                    inks.append(color)
                }
            }
        }
        guard !inks.isEmpty else { return }

        var areas: [Area] = []
        for (i, op) in ops.enumerated() {
            if case let .fill(points, color) = op, !inks.contains(color) {
                areas.append(Area(at: i, bounds: bounds(of: points), points: points, color: color))
            }
        }

        let n = ops.count
        for i in ops.indices {
            ops[i] = flattenOp(ops[i], at: i, areas: areas, surface: surface, inks: inks)
        }
        for ti in traces.indices {
            for oi in traces[ti].ops.indices {
                traces[ti].ops[oi] = flattenOp(traces[ti].ops[oi], at: n, areas: areas, surface: surface, inks: inks)
            }
        }
    }

    private static func flattenOp(
        _ op: CanvasOp,
        at: Int,
        areas: [Area],
        surface: Color,
        inks: [Color]
    ) -> CanvasOp {
        switch op {
        case let .stroke(points, closed, width, roundCap, color) where isTranslucent(color):
            let p = closed ? centroid(of: points) : midpoint(of: points)
            let own = closed ? points : nil
            let bg = under(p, at: at, own: own, areas: areas, surface: surface)
            return .stroke(points: points, closed: closed, width: width, roundCap: roundCap, color: over(color, bg))
        case let .fill(points, color) where inks.contains(color):
            let bg = under(centroid(of: points), at: at, own: nil, areas: areas, surface: surface)
            return .fill(points: points, color: over(color, bg))
        default:
            return op
        }
    }

    private static func under(
        _ p: Vec2,
        at: Int,
        own: [Vec2]?,
        areas: [Area],
        surface: Color
    ) -> Color {
        var result = surface
        for a in areas {
            if a.at >= at { break }
            if let own, own == a.points { continue }
            if inside(p, bounds: a.bounds, points: a.points) {
                result = over(a.color, result)
            }
        }
        return result
    }

    private static func isTranslucent(_ c: Color) -> Bool {
        c.a > 0.0 && c.a < 1.0
    }

    /// `top` over `bottom`, blended in sRGB-encoded values.
    static func over(_ top: Color, _ bottom: Color) -> Color {
        let a = top.a + bottom.a * (1.0 - top.a)
        if a <= 1e-6 { return .transparent }
        func mixChannel(_ t: Float, _ b: Float) -> Float {
            RefShader.srgbToLinear((RefShader.linearToSRGB(t) * top.a + RefShader.linearToSRGB(b) * bottom.a * (1.0 - top.a)) / a)
        }
        return Color(
            r: mixChannel(top.r, bottom.r),
            g: mixChannel(top.g, bottom.g),
            b: mixChannel(top.b, bottom.b),
            a: a
        )
    }

    private static func bounds(of points: [Vec2]) -> (Float, Float, Float, Float) {
        var x0 = Float.greatestFiniteMagnitude
        var y0 = Float.greatestFiniteMagnitude
        var x1 = -Float.greatestFiniteMagnitude
        var y1 = -Float.greatestFiniteMagnitude
        for p in points {
            x0 = min(x0, p.x)
            y0 = min(y0, p.y)
            x1 = max(x1, p.x)
            y1 = max(y1, p.y)
        }
        return (x0, y0, x1, y1)
    }

    private static func centroid(of points: [Vec2]) -> Vec2 {
        let n = Float(max(points.count, 1))
        var sx: Float = 0
        var sy: Float = 0
        for p in points {
            sx += p.x
            sy += p.y
        }
        return Vec2(sx / n, sy / n)
    }

    private static func midpoint(of points: [Vec2]) -> Vec2 {
        guard !points.isEmpty else { return .zero }
        let i = points.count / 2
        if points.count % 2 == 0 {
            return CanvasMath.lerp(points[i - 1], points[i], 0.5)
        }
        return points[i]
    }

    private static func inside(_ p: Vec2, bounds b: (Float, Float, Float, Float), points: [Vec2]) -> Bool {
        if p.x < b.0 || p.x > b.2 || p.y < b.1 || p.y > b.3 || points.isEmpty {
            return false
        }
        var odd = false
        var j = points.count - 1
        for i in 0..<points.count {
            let a = points[i]
            let c = points[j]
            if (a.y > p.y) != (c.y > p.y),
               p.x < (c.x - a.x) * (p.y - a.y) / (c.y - a.y) + a.x {
                odd.toggle()
            }
            j = i
        }
        return odd
    }
}
