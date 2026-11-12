import Foundation
import RuneMotion
#if canImport(simd)
import simd
#endif

/// 2D vector path builder supporting lines, quadratic & cubic Béziers, circular arcs,
/// ear-clipping concave triangulation, and fractional arc-length stroke trimming (`drawn` / `trimmed`).
public struct VectorPath: Sendable, Equatable {
    public enum Command: Sendable, Equatable {
        case moveTo(Vec2)
        case lineTo(Vec2)
        case quadTo(control: Vec2, to: Vec2)
        case cubicTo(c1: Vec2, c2: Vec2, to: Vec2)
        case close
    }

    public private(set) var commands: [Command] = []

    public init() {}

    public mutating func moveTo(_ x: Float, _ y: Float) {
        commands.append(.moveTo(Vec2(x, y)))
    }

    public mutating func lineTo(_ x: Float, _ y: Float) {
        commands.append(.lineTo(Vec2(x, y)))
    }

    public mutating func quadTo(cx: Float, cy: Float, x: Float, y: Float) {
        commands.append(.quadTo(control: Vec2(cx, cy), to: Vec2(x, y)))
    }

    public mutating func cubicTo(c1x: Float, c1y: Float, c2x: Float, c2y: Float, x: Float, y: Float) {
        commands.append(.cubicTo(c1: Vec2(c1x, c1y), c2: Vec2(c2x, c2y), to: Vec2(x, y)))
    }

    public mutating func arc(center: Vec2, radius: Float, startAngle: Float, endAngle: Float, clockwise: Bool = true) {
        var delta = endAngle - startAngle
        if abs(delta) > 1e-6 {
            if clockwise && delta < 0 {
                delta += 2.0 * .pi
            } else if !clockwise && delta > 0 {
                delta -= 2.0 * .pi
            }
        }
        let steps = max(4, Int(ceilf(abs(delta) / (.pi / 12.0))))
        let needsMove: Bool
        if let last = commands.last {
            if case .close = last {
                needsMove = true
            } else {
                needsMove = false
            }
        } else {
            needsMove = true
        }
        for i in 0...steps {
            let t = Float(i) / Float(steps)
            let ang = startAngle + delta * t
            let px = center.x + cosf(ang) * radius
            let py = center.y + sinf(ang) * radius
            if i == 0 && needsMove {
                moveTo(px, py)
            } else {
                lineTo(px, py)
            }
        }
    }

    public mutating func rect(x: Float, y: Float, width: Float, height: Float) {
        moveTo(x, y)
        lineTo(x + width, y)
        lineTo(x + width, y + height)
        lineTo(x, y + height)
        close()
    }

    public mutating func roundedRect(x: Float, y: Float, width: Float, height: Float, radius: Float) {
        let r = min(max(0, radius), min(width, height) * 0.5)
        if r <= 1e-4 {
            rect(x: x, y: y, width: width, height: height)
            return
        }
        let k: Float = 0.5522847498 * r
        moveTo(x + r, y)
        lineTo(x + width - r, y)
        cubicTo(c1x: x + width - r + k, c1y: y, c2x: x + width, c2y: y + r - k, x: x + width, y: y + r)
        lineTo(x + width, y + height - r)
        cubicTo(c1x: x + width, c1y: y + height - r + k, c2x: x + width - r + k, c2y: y + height, x: x + width - r, y: y + height)
        lineTo(x + r, y + height)
        cubicTo(c1x: x + r - k, c1y: y + height, c2x: x, c2y: y + height - r + k, x: x, y: y + height - r)
        lineTo(x, y + r)
        cubicTo(c1x: x, c1y: y + r - k, c2x: x + r - k, c2y: y, x: x + r, y: y)
        close()
    }

    public mutating func circle(cx: Float, cy: Float, radius: Float) {
        let k: Float = 0.5522847498 * radius
        moveTo(cx, cy - radius)
        cubicTo(c1x: cx + k, c1y: cy - radius, c2x: cx + radius, c2y: cy - k, x: cx + radius, y: cy)
        cubicTo(c1x: cx + radius, c1y: cy + k, c2x: cx + k, c2y: cy + radius, x: cx, y: cy + radius)
        cubicTo(c1x: cx - k, c1y: cy + radius, c2x: cx - radius, c2y: cy + k, x: cx - radius, y: cy)
        cubicTo(c1x: cx - radius, c1y: cy - k, c2x: cx - k, c2y: cy - radius, x: cx, y: cy - radius)
        close()
    }

    public mutating func close() {
        commands.append(.close)
    }

    public struct Subpath: Sendable, Equatable {
        public var points: [Vec2]
        public var isClosed: Bool
    }

    /// Flattens curves adaptively into polyline subpaths within `tolerance` points.
    public func flatten(tolerance: Float = 0.25) -> [Subpath] {
        var out: [Subpath] = []
        var current: [Vec2] = []
        var startPoint = Vec2.zero
        let tol2 = max(tolerance * tolerance, 1e-4)

        func finish(closed: Bool) {
            if current.count >= 2 {
                out.append(Subpath(points: current, isClosed: closed))
            }
            current.removeAll(keepingCapacity: true)
        }

        for cmd in commands {
            switch cmd {
            case .moveTo(let p):
                finish(closed: false)
                current.append(p)
                startPoint = p

            case .lineTo(let p):
                if current.isEmpty {
                    current.append(p)
                    startPoint = p
                } else if hypotf(p.x - current.last!.x, p.y - current.last!.y) > 1e-4 {
                    current.append(p)
                }

            case let .quadTo(c, p2):
                let p0 = current.last ?? startPoint
                if current.isEmpty { current.append(p0) }
                Self.flattenQuad(p0: p0, p1: c, p2: p2, tol2: tol2, depth: 0, into: &current)

            case let .cubicTo(c1, c2, p3):
                let p0 = current.last ?? startPoint
                if current.isEmpty { current.append(p0) }
                Self.flattenCubic(p0: p0, p1: c1, p2: c2, p3: p3, tol2: tol2, depth: 0, into: &current)

            case .close:
                if current.count >= 2, hypotf(current.last!.x - startPoint.x, current.last!.y - startPoint.y) < 1e-3 {
                    current.removeLast()
                }
                finish(closed: true)
            }
        }
        finish(closed: false)
        return out
    }

    private static func flattenQuad(p0: Vec2, p1: Vec2, p2: Vec2, tol2: Float, depth: Int, into pts: inout [Vec2]) {
        if depth >= 10 {
            pts.append(p2)
            return
        }
        let mx = 0.25 * p0.x + 0.5 * p1.x + 0.25 * p2.x
        let my = 0.25 * p0.y + 0.5 * p1.y + 0.25 * p2.y
        let chordX = 0.5 * (p0.x + p2.x)
        let chordY = 0.5 * (p0.y + p2.y)
        let dx = mx - chordX
        let dy = my - chordY
        if dx * dx + dy * dy <= tol2 {
            pts.append(p2)
            return
        }
        let q0 = Vec2(0.5 * (p0.x + p1.x), 0.5 * (p0.y + p1.y))
        let q1 = Vec2(0.5 * (p1.x + p2.x), 0.5 * (p1.y + p2.y))
        let mid = Vec2(0.5 * (q0.x + q1.x), 0.5 * (q0.y + q1.y))
        flattenQuad(p0: p0, p1: q0, p2: mid, tol2: tol2, depth: depth + 1, into: &pts)
        flattenQuad(p0: mid, p1: q1, p2: p2, tol2: tol2, depth: depth + 1, into: &pts)
    }

    private static func flattenCubic(p0: Vec2, p1: Vec2, p2: Vec2, p3: Vec2, tol2: Float, depth: Int, into pts: inout [Vec2]) {
        if depth >= 10 {
            pts.append(p3)
            return
        }
        let ux = 3.0 * p1.x - 2.0 * p0.x - p3.x
        let uy = 3.0 * p1.y - 2.0 * p0.y - p3.y
        let vx = 3.0 * p2.x - 2.0 * p3.x - p0.x
        let vy = 3.0 * p2.y - 2.0 * p3.y - p0.y
        if max(ux * ux, vx * vx) + max(uy * uy, vy * vy) <= 16.0 * tol2 {
            pts.append(p3)
            return
        }
        let p01 = Vec2(0.5 * (p0.x + p1.x), 0.5 * (p0.y + p1.y))
        let p12 = Vec2(0.5 * (p1.x + p2.x), 0.5 * (p1.y + p2.y))
        let p23 = Vec2(0.5 * (p2.x + p3.x), 0.5 * (p2.y + p3.y))
        let p012 = Vec2(0.5 * (p01.x + p12.x), 0.5 * (p01.y + p12.y))
        let p123 = Vec2(0.5 * (p12.x + p23.x), 0.5 * (p12.y + p23.y))
        let mid = Vec2(0.5 * (p012.x + p123.x), 0.5 * (p012.y + p123.y))
        flattenCubic(p0: p0, p1: p01, p2: p012, p3: mid, tol2: tol2, depth: depth + 1, into: &pts)
        flattenCubic(p0: mid, p1: p123, p2: p23, p3: p3, tol2: tol2, depth: depth + 1, into: &pts)
    }

    public struct FillTriangle: Sendable, Equatable {
        public var v0: Vec2
        public var v1: Vec2
        public var v2: Vec2
        /// Bitmask (`bit 0 = edge v0->v1`, `bit 1 = edge v1->v2`, `bit 2 = edge v2->v0`)
        /// marking true outer polygon boundary edges for antialiasing!
        public var aaMask: UInt8
    }

    /// Ear-clips closed (and implicitly closed) subpaths into triangles with outer-edge AA masks.
    public func triangulate(tolerance: Float = 0.25) -> [FillTriangle] {
        var tris: [FillTriangle] = []
        for sub in flatten(tolerance: tolerance) where sub.points.count >= 3 {
            var poly = sub.points
            let n0 = poly.count
            // Compute signed area; ensure positive orientation (`area > 0`)
            var area2: Float = 0
            for i in 0..<n0 {
                let a = poly[i]
                let b = poly[(i + 1) % n0]
                area2 += a.x * b.y - b.x * a.y
            }
            if abs(area2) < 1e-4 { continue }
            if area2 < 0 { poly.reverse() }

            var indices = Array(0..<poly.count)
            // Track whether edge `(indices[k] -> indices[(k+1)%m])` is an original polygon boundary!
            var edgeIsBoundary = Array(repeating: true, count: poly.count)

            var guardCounter = poly.count * poly.count * 2
            while indices.count > 3 && guardCounter > 0 {
                guardCounter -= 1
                var earFound = false
                let m = indices.count
                for i in 0..<m {
                    let prevIdx = (i + m - 1) % m
                    let nextIdx = (i + 1) % m
                    let a = poly[indices[prevIdx]]
                    let b = poly[indices[i]]
                    let c = poly[indices[nextIdx]]
                    let cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
                    if cross <= 1e-6 { continue } // reflex or collinear

                    var containsOther = false
                    for j in 0..<m where j != prevIdx && j != i && j != nextIdx {
                        let p = poly[indices[j]]
                        if Self.pointInTriangle(p, a, b, c) {
                            containsOther = true
                            break
                        }
                    }
                    if containsOther { continue }

                    var mask: UInt8 = 0
                    if edgeIsBoundary[prevIdx] { mask |= 1 << 0 } // a -> b
                    if edgeIsBoundary[i] { mask |= 1 << 1 }       // b -> c
                    // c -> a is a new interior diagonal (`0`), unless m == 3!
                    tris.append(FillTriangle(v0: a, v1: b, v2: c, aaMask: mask))

                    // After removing vertex `i`, edge from `prevIdx` to `nextIdx` becomes the interior diagonal
                    let adjPrev = prevIdx > i ? prevIdx - 1 : prevIdx
                    indices.remove(at: i)
                    edgeIsBoundary.remove(at: i)
                    edgeIsBoundary[adjPrev] = false
                    earFound = true
                    break
                }
                if !earFound {
                    // Drop collinear vertices if any remain, otherwise fall back to a triangle fan.
                    var droppedCollinear = false
                    for i in 0..<m {
                        let prevIdx = (i + m - 1) % m
                        let nextIdx = (i + 1) % m
                        let a = poly[indices[prevIdx]]
                        let b = poly[indices[i]]
                        let c = poly[indices[nextIdx]]
                        let cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
                        if abs(cross) <= 1e-6 {
                            let adjPrev = prevIdx > i ? prevIdx - 1 : prevIdx
                            let keptBoundary = edgeIsBoundary[prevIdx] && edgeIsBoundary[i]
                            indices.remove(at: i)
                            edgeIsBoundary.remove(at: i)
                            edgeIsBoundary[adjPrev] = keptBoundary
                            droppedCollinear = true
                            break
                        }
                    }
                    if !droppedCollinear {
                        // Non-simple polygon fallback: fan over remaining vertices
                        for k in 1..<(indices.count - 1) {
                            var mask: UInt8 = 0
                            if k == 1 && edgeIsBoundary[0] { mask |= 1 << 0 }
                            if edgeIsBoundary[k] { mask |= 1 << 1 }
                            if k == indices.count - 2 && edgeIsBoundary[indices.count - 1] { mask |= 1 << 2 }
                            tris.append(FillTriangle(
                                v0: poly[indices[0]],
                                v1: poly[indices[k]],
                                v2: poly[indices[k + 1]],
                                aaMask: mask
                            ))
                        }
                        indices.removeAll()
                        break
                    }
                }
            }

            if indices.count == 3 {
                var mask: UInt8 = 0
                if edgeIsBoundary[0] { mask |= 1 << 0 }
                if edgeIsBoundary[1] { mask |= 1 << 1 }
                if edgeIsBoundary[2] { mask |= 1 << 2 }
                tris.append(FillTriangle(
                    v0: poly[indices[0]],
                    v1: poly[indices[1]],
                    v2: poly[indices[2]],
                    aaMask: mask
                ))
            }
        }
        return tris
    }

    /// Generates stroke line segments `(from, to)` trimmed to fractional arc-length `[trimStart, trimEnd]` in `[0, 1]`.
    public func strokeSegments(
        trimStart: Float = 0,
        trimEnd: Float = 1,
        tolerance: Float = 0.25
    ) -> [(Vec2, Vec2)] {
        let t0 = (trimStart.isNaN ? 0.0 : trimStart).clamped(to: 0...1)
        let t1 = (trimEnd.isNaN ? 1.0 : trimEnd).clamped(to: 0...1)
        if t1 - t0 <= 1e-5 { return [] }

        var rawSegments: [(Vec2, Vec2, Float)] = []
        var totalLen: Float = 0

        for sub in flatten(tolerance: tolerance) where sub.points.count >= 2 {
            let count = sub.points.count
            let segCount = sub.isClosed ? count : (count - 1)
            for i in 0..<segCount {
                let a = sub.points[i]
                let b = sub.points[(i + 1) % count]
                let len = hypotf(b.x - a.x, b.y - a.y)
                if len > 1e-4 {
                    rawSegments.append((a, b, len))
                    totalLen += len
                }
            }
        }
        if totalLen <= 1e-4 { return [] }

        let startDist = t0 * totalLen
        let endDist = t1 * totalLen
        var cursor: Float = 0
        var out: [(Vec2, Vec2)] = []
        out.reserveCapacity(rawSegments.count)

        for (a, b, len) in rawSegments {
            let nextCursor = cursor + len
            if nextCursor > startDist && cursor < endDist {
                let f0 = max(0.0, (startDist - cursor) / len)
                let f1 = min(1.0, (endDist - cursor) / len)
                let p0 = Vec2(a.x + (b.x - a.x) * f0, a.y + (b.y - a.y) * f0)
                let p1 = Vec2(a.x + (b.x - a.x) * f1, a.y + (b.y - a.y) * f1)
                out.append((p0, p1))
            }
            cursor = nextCursor
        }
        return out
    }

    private static func pointInTriangle(_ p: Vec2, _ a: Vec2, _ b: Vec2, _ c: Vec2) -> Bool {
        let c0 = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
        let c1 = (c.x - b.x) * (p.y - b.y) - (c.y - b.y) * (p.x - b.x)
        let c2 = (a.x - c.x) * (p.y - c.y) - (a.y - c.y) * (p.x - c.x)
        return c0 >= -1e-5 && c1 >= -1e-5 && c2 >= -1e-5
    }
}

/// Painted vector shape (`fill` or `stroke`) for `canvas` / `El.shape(...)`.
public struct Shape: Sendable, Equatable {
    public enum Style: Sendable, Equatable {
        case fill(Color)
        case stroke(color: Color, width: Float, roundCap: Bool)
    }

    public var path: VectorPath
    public var style: Style
    public var trimStart: Float = 0
    public var trimEnd: Float = 1
    public var viewBox: Vec2? = nil

    public init(path: VectorPath, style: Style, trimStart: Float = 0, trimEnd: Float = 1, viewBox: Vec2? = nil) {
        self.path = path
        self.style = style
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.viewBox = viewBox
    }

    public static func fill(_ path: VectorPath, color: Color) -> Shape {
        Shape(path: path, style: .fill(color))
    }

    public static func stroke(_ path: VectorPath, color: Color, width: Float = 1.5, roundCap: Bool = true) -> Shape {
        Shape(path: path, style: .stroke(color: color, width: width, roundCap: roundCap))
    }

    /// Treats coordinates as spanning `width x height` and stretches them to the element's size.
    public func viewBox(_ width: Float, _ height: Float) -> Shape {
        var copy = self
        copy.viewBox = (width.isFinite && height.isFinite && width > 0 && height > 0) ? Vec2(width, height) : nil
        return copy
    }

    /// Draws the first `t in [0, 1]` fraction of a stroked path.
    public func drawn(_ t: Float) -> Shape {
        trimmed(start: 0, end: t.isNaN ? 1.0 : t)
    }

    /// Draws the `[start, end]` arc-length slice of a stroked path.
    public func trimmed(start: Float, end: Float) -> Shape {
        var copy = self
        copy.trimStart = (start.isNaN ? 0.0 : start).clamped(to: 0...1)
        copy.trimEnd = (end.isNaN ? 1.0 : end).clamped(to: 0...1)
        return copy
    }
}
