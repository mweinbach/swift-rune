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

/// Stroke cap and joint style for vector shapes.
public enum LineCap: Sendable, Equatable, Hashable {
    /// Segments end at their points.
    case butt
    /// Half-discs past each end; also rounds every joint of a polyline.
    case round
}

/// A path built from lines and Bézier curves, flattened to polylines for `Shape`.
public struct Path: Sendable, Equatable {
    public struct Subpath: Sendable, Equatable {
        public var points: [Vec2]
        public var closed: Bool

        public init(points: [Vec2], closed: Bool) {
            self.points = points
            self.closed = closed
        }
    }

    /// Flattening tolerance, in points: curves stay within this of their true position.
    public static let tolerance: Float = 0.1

    public private(set) var subpaths: [Subpath] = []

    public init() {}

    public static func new() -> Path {
        Path()
    }

    private func lastPoint() -> Vec2 {
        subpaths.last?.points.last ?? .zero
    }

    private mutating func appendPoint(_ p: Vec2) {
        if subpaths.last?.closed != false {
            let start = lastPoint()
            subpaths.append(Subpath(points: [start, p], closed: false))
        } else {
            subpaths[subpaths.count - 1].points.append(p)
        }
    }

    private mutating func ensureCurrentPoints() -> Int {
        if subpaths.last?.closed != false {
            let start = lastPoint()
            subpaths.append(Subpath(points: [start], closed: false))
        }
        return subpaths.count - 1
    }

    public func moveTo(_ p: Vec2) -> Path {
        var copy = self
        if let last = copy.subpaths.last, last.points.count == 1 && !last.closed {
            copy.subpaths[copy.subpaths.count - 1].points[0] = p
        } else {
            copy.subpaths.append(Subpath(points: [p], closed: false))
        }
        return copy
    }

    public func moveTo(_ p: [Float]) -> Path {
        precondition(p.count >= 2, "Path.moveTo requires at least 2 coordinates")
        return moveTo(Vec2(p[0], p[1]))
    }

    public func moveTo(_ x: Float, _ y: Float) -> Path {
        moveTo(Vec2(x, y))
    }

    public func lineTo(_ p: Vec2) -> Path {
        var copy = self
        copy.appendPoint(p)
        return copy
    }

    public func lineTo(_ p: [Float]) -> Path {
        precondition(p.count >= 2, "Path.lineTo requires at least 2 coordinates")
        return lineTo(Vec2(p[0], p[1]))
    }

    public func lineTo(_ x: Float, _ y: Float) -> Path {
        lineTo(Vec2(x, y))
    }

    public func quadTo(_ c: Vec2, _ p: Vec2) -> Path {
        var copy = self
        let a = copy.lastPoint()
        let len = Self.dist(a, c) + Self.dist(c, p)
        let n = Self.segments(len)
        let idx = copy.ensureCurrentPoints()
        for i in 1...n {
            let t = Float(i) / Float(n)
            let u = 1.0 - t
            copy.subpaths[idx].points.append(Vec2(
                u * u * a.x + 2.0 * u * t * c.x + t * t * p.x,
                u * u * a.y + 2.0 * u * t * c.y + t * t * p.y
            ))
        }
        return copy
    }

    public func quadTo(_ c: [Float], _ p: [Float]) -> Path {
        precondition(c.count >= 2 && p.count >= 2, "Path.quadTo requires 2-element points")
        return quadTo(Vec2(c[0], c[1]), Vec2(p[0], p[1]))
    }

    public func cubicTo(_ c1: Vec2, _ c2: Vec2, _ p: Vec2) -> Path {
        var copy = self
        let a = copy.lastPoint()
        let len = Self.dist(a, c1) + Self.dist(c1, c2) + Self.dist(c2, p)
        let n = Self.segments(len)
        let idx = copy.ensureCurrentPoints()
        for i in 1...n {
            let t = Float(i) / Float(n)
            let u = 1.0 - t
            let b0 = u * u * u
            let b1 = 3.0 * u * u * t
            let b2 = 3.0 * u * t * t
            let b3 = t * t * t
            copy.subpaths[idx].points.append(Vec2(
                b0 * a.x + b1 * c1.x + b2 * c2.x + b3 * p.x,
                b0 * a.y + b1 * c1.y + b2 * c2.y + b3 * p.y
            ))
        }
        return copy
    }

    public func cubicTo(_ c1: [Float], _ c2: [Float], _ p: [Float]) -> Path {
        precondition(c1.count >= 2 && c2.count >= 2 && p.count >= 2, "Path.cubicTo requires 2-element points")
        return cubicTo(Vec2(c1[0], c1[1]), Vec2(c2[0], c2[1]), Vec2(p[0], p[1]))
    }

    public func close() -> Path {
        var copy = self
        if !copy.subpaths.isEmpty {
            copy.subpaths[copy.subpaths.count - 1].closed = true
        }
        return copy
    }

    fileprivate static func dist(_ a: Vec2, _ b: Vec2) -> Float {
        hypotf(b.x - a.x, b.y - a.y)
    }

    /// Segments for a curve whose control polygon is `length` long.
    private static func segments(_ length: Float) -> Int {
        let count = ceilf(sqrtf(max(0.0, length) / tolerance) * 0.5)
        return Int(min(256.0, max(1.0, count)))
    }
}

/// A list of strokes and fills, painted in order over the element's fill and under its text.
public struct Shape: Sendable, Equatable {
    /// How many points of line a fill fades in over as `Shape.drawn` reaches it.
    public static let drawRamp: Float = 8.0

    public enum Op: Sendable, Equatable {
        case stroke(points: [Vec2], closed: Bool, width: Float, cap: LineCap, color: Color)
        case fill(points: [Vec2], color: Color)
    }

    public enum Style: Sendable, Equatable {
        case fill(Color)
        case stroke(color: Color, width: Float, roundCap: Bool)
    }

    public private(set) var ops: [Op] = []
    /// Coordinates span this box and stretch to the element's size (stroke widths stay in points).
    public var viewBox: Vec2? = nil
    public var trimStart: Float = 0
    public var trimEnd: Float = 1

    private var legacyPath: VectorPath? = nil
    private var legacyStyle: Style? = nil

    public var path: VectorPath {
        if let legacyPath { return legacyPath }
        var vp = VectorPath()
        for op in ops {
            switch op {
            case let .stroke(points, closed, _, _, _):
                guard let first = points.first else { continue }
                vp.moveTo(first.x, first.y)
                for p in points.dropFirst() {
                    vp.lineTo(p.x, p.y)
                }
                if closed { vp.close() }
            case let .fill(points, _):
                guard let first = points.first else { continue }
                vp.moveTo(first.x, first.y)
                for p in points.dropFirst() {
                    vp.lineTo(p.x, p.y)
                }
                vp.close()
            }
        }
        return vp
    }

    public var style: Style {
        if let legacyStyle { return legacyStyle }
        for op in ops {
            switch op {
            case let .fill(_, color):
                return .fill(color)
            case let .stroke(_, _, width, cap, color):
                return .stroke(color: color, width: width, roundCap: cap == .round)
            }
        }
        return .fill(.transparent)
    }

    public init() {}

    public static func new() -> Shape {
        Shape()
    }

    public init(path: VectorPath, style: Style, trimStart: Float = 0, trimEnd: Float = 1, viewBox: Vec2? = nil) {
        self.legacyPath = path
        self.legacyStyle = style
        self.viewBox = viewBox
        let flat = path.flatten(tolerance: Path.tolerance)
        var builtOps: [Op] = []
        switch style {
        case .fill(let col):
            for sub in flat where sub.points.count >= 3 {
                builtOps.append(.fill(points: sub.points, color: col))
            }
        case let .stroke(col, width, roundCap):
            if width > 0 {
                let cap: LineCap = roundCap ? .round : .butt
                for sub in flat where sub.points.count >= 2 {
                    builtOps.append(.stroke(points: sub.points, closed: sub.isClosed, width: width, cap: cap, color: col))
                }
            }
        }
        self.ops = builtOps
        let s = trimStart.isNaN ? 0.0 : trimStart.clamped(to: 0...1)
        let e = trimEnd.isNaN ? 1.0 : trimEnd.clamped(to: 0...1)
        if s > 0.0 || e < 1.0 {
            self = self.trimmed(start: s, end: e)
            self.legacyPath = path
            self.legacyStyle = style
        } else {
            self.trimStart = s
            self.trimEnd = e
        }
    }

    public static func == (lhs: Shape, rhs: Shape) -> Bool {
        lhs.ops == rhs.ops && lhs.viewBox == rhs.viewBox
    }

    public static func fill(_ path: VectorPath, color: Color) -> Shape {
        Shape(path: path, style: .fill(color))
    }

    public static func stroke(_ path: VectorPath, color: Color, width: Float = 1.5, roundCap: Bool = true) -> Shape {
        Shape(path: path, style: .stroke(color: color, width: width, roundCap: roundCap))
    }

    /// An open polyline through `points`, `width` points wide, with round caps and joints.
    public func stroke(_ points: [Vec2], width: Float, color: Color) -> Shape {
        strokeWith(points, closed: false, width: width, cap: .round, color: color)
    }

    public func stroke(_ points: [[Float]], width: Float, color: Color) -> Shape {
        stroke(points.compactMap { $0.count >= 2 ? Vec2($0[0], $0[1]) : nil }, width: width, color: color)
    }

    /// A polyline; `closed` joins the last point back to the first.
    public func strokeWith(_ points: [Vec2], closed: Bool, width: Float, cap: LineCap, color: Color) -> Shape {
        var copy = self
        if points.count >= 2 && width > 0 {
            copy.ops.append(.stroke(points: points, closed: closed, width: width, cap: cap, color: color))
            copy.legacyPath = nil
        }
        return copy
    }

    public func strokeWith(_ points: [[Float]], closed: Bool, width: Float, cap: LineCap, color: Color) -> Shape {
        strokeWith(points.compactMap { $0.count >= 2 ? Vec2($0[0], $0[1]) : nil }, closed: closed, width: width, cap: cap, color: color)
    }

    /// A straight line from `a` to `b`.
    public func line(_ a: Vec2, _ b: Vec2, width: Float, cap: LineCap, color: Color) -> Shape {
        strokeWith([a, b], closed: false, width: width, cap: cap, color: color)
    }

    public func line(_ a: [Float], _ b: [Float], width: Float, cap: LineCap, color: Color) -> Shape {
        precondition(a.count >= 2 && b.count >= 2, "Shape.line requires 2-element points")
        return line(Vec2(a[0], a[1]), Vec2(b[0], b[1]), width: width, cap: cap, color: color)
    }

    /// The inside of the simple polygon through `points` (either winding; not self-intersecting).
    public func fill(_ points: [Vec2], color: Color) -> Shape {
        var copy = self
        if points.count >= 3 {
            copy.ops.append(.fill(points: points, color: color))
            copy.legacyPath = nil
        }
        return copy
    }

    public func fill(_ points: [[Float]], color: Color) -> Shape {
        fill(points.compactMap { $0.count >= 2 ? Vec2($0[0], $0[1]) : nil }, color: color)
    }

    /// Strokes every subpath of `path`, closed ones back to their start.
    public func strokePath(_ path: Path, width: Float, cap: LineCap, color: Color) -> Shape {
        var copy = self
        for sub in path.subpaths {
            copy = copy.strokeWith(sub.points, closed: sub.closed, width: width, cap: cap, color: color)
        }
        return copy
    }

    public func strokePath(_ path: VectorPath, width: Float, cap: LineCap, color: Color) -> Shape {
        var copy = self
        for sub in path.flatten(tolerance: Path.tolerance) {
            copy = copy.strokeWith(sub.points, closed: sub.isClosed, width: width, cap: cap, color: color)
        }
        return copy
    }

    /// Fills every subpath of `path` on its own (no holes between subpaths).
    public func fillPath(_ path: Path, color: Color) -> Shape {
        var copy = self
        for sub in path.subpaths {
            copy = copy.fill(sub.points, color: color)
        }
        return copy
    }

    public func fillPath(_ path: VectorPath, color: Color) -> Shape {
        var copy = self
        for sub in path.flatten(tolerance: Path.tolerance) {
            copy = copy.fill(sub.points, color: color)
        }
        return copy
    }

    /// Treats coordinates as spanning `width x height` and stretches them to the element's size;
    /// stroke widths stay in points.
    public func viewBox(_ width: Float, _ height: Float) -> Shape {
        var copy = self
        copy.viewBox = (width.isFinite && height.isFinite && width > 0 && height > 0) ? Vec2(width, height) : nil
        return copy
    }

    public var isEmpty: Bool {
        ops.isEmpty
    }

    public var pieceCount: Int {
        ops.reduce(0) { sum, op in
            switch op {
            case let .stroke(points, closed, _, _, _):
                return sum + (closed ? points.count : max(0, points.count - 1))
            case .fill:
                return sum + 1
            }
        }
    }

    /// Whether it draws more than one piece, so two can overlap (requiring a layer while fading).
    public var overlaps: Bool {
        pieceCount > 1
    }

    /// This shape drawn on to `t` (0 to 1): strokes trace in order along their combined length,
    /// and each fill fades in over the last `Shape.drawRamp` points of line before it.
    public func drawn(_ t: Float) -> Shape {
        trimmed(start: 0.0, end: t.isNaN ? 1.0 : t)
    }

    /// The part of this shape from `start` to `end` (0 to 1) of its strokes' combined length.
    public func trimmed(start: Float, end: Float) -> Shape {
        let s = (start.isNaN ? 0.0 : start).clamped(to: 0...1)
        let t = (end.isNaN ? 1.0 : end).clamped(to: 0...1)
        if s <= 0.0 && t >= 1.0 {
            var copy = self
            copy.trimStart = 0.0
            copy.trimEnd = 1.0
            return copy
        }

        func polyLength(_ points: [Vec2], closed: Bool) -> Float {
            guard points.count >= 2 else { return 0 }
            var total: Float = 0
            for i in 0..<(points.count - 1) {
                total += Path.dist(points[i], points[i + 1])
            }
            if closed && points.count > 2 {
                total += Path.dist(points[points.count - 1], points[0])
            }
            return total
        }

        let total: Float = ops.reduce(0) { acc, op in
            if case let .stroke(points, closed, _, _, _) = op {
                return acc + polyLength(points, closed: closed)
            }
            return acc
        }
        let from = s * total
        let at = t * total
        var done: Float = 0
        var outOps: [Op] = []

        for op in ops {
            switch op {
            case let .stroke(points, closed, width, cap, color):
                let l = polyLength(points, closed: closed)
                let lo = max(from, done)
                let hi = min(at, done + l)
                if lo <= done && hi >= done + l {
                    outOps.append(op)
                } else if hi > lo {
                    var ring = points
                    if closed, let first = points.first {
                        ring.append(first)
                    }
                    let cut = Self.slicePolyline(ring, from: lo - done, to: hi - done)
                    if cut.count >= 2 {
                        outOps.append(.stroke(points: cut, closed: false, width: width, cap: cap, color: color))
                    }
                }
                done += l
            case let .fill(points, color):
                let a: Float
                if total <= 0 {
                    a = t
                } else if done <= 0 {
                    a = 1.0
                } else {
                    let ramp = min(Self.drawRamp, done)
                    a = ((at - (done - ramp)) / ramp).clamped(to: 0...1)
                }
                if a > 0 {
                    outOps.append(.fill(points: points, color: color.scaleAlpha(a)))
                }
            }
        }

        var copy = Shape()
        copy.ops = outOps
        copy.viewBox = viewBox
        copy.trimStart = s
        copy.trimEnd = t
        return copy
    }

    private static func slicePolyline(_ points: [Vec2], from: Float, to: Float) -> [Vec2] {
        func lerp(_ a: Vec2, _ b: Vec2, _ at: Float, _ d: Float) -> Vec2 {
            let k: Float = d > 0 ? (at / d).clamped(to: 0...1) : 0
            return Vec2(a.x + (b.x - a.x) * k, a.y + (b.y - a.y) * k)
        }
        var out: [Vec2] = []
        var done: Float = 0
        for i in 0..<max(0, points.count - 1) {
            let a = points[i]
            let b = points[i + 1]
            let d = Path.dist(a, b)
            if out.isEmpty && from < done + d {
                out.append(lerp(a, b, from - done, d))
            }
            if !out.isEmpty {
                if to <= done + d {
                    out.append(lerp(a, b, to - done, d))
                    return out
                }
                out.append(b)
            }
            done += d
        }
        return out
    }

    /// Ear-clips a simple polygon. Each entry holds three vertex indices and a 3-bit boundary edge mask
    /// (bits 0, 1, 2 for edges a->b, b->c, c->a).
    public static func triangulate(_ points: [Vec2]) -> [([Int], UInt8)] {
        let n = points.count
        guard n >= 3 else { return [] }

        var signedArea2: Float = 0
        for i in 0..<n {
            let a = points[i]
            let b = points[(i + 1) % n]
            signedArea2 += a.x * b.y - b.x * a.y
        }
        let ccw = signedArea2 > 0

        func cross(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Float {
            let v = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            return ccw ? v : -v
        }

        func isBoundary(_ i: Int, _ j: Int) -> Bool {
            (i + 1) % n == j || (j + 1) % n == i
        }

        func edgeMask(_ a: Int, _ b: Int, _ c: Int) -> UInt8 {
            let b0: UInt8 = isBoundary(a, b) ? 1 : 0
            let b1: UInt8 = isBoundary(b, c) ? 2 : 0
            let b2: UInt8 = isBoundary(c, a) ? 4 : 0
            return b0 | b1 | b2
        }

        var ring = Array(0..<n)
        var out: [([Int], UInt8)] = []
        out.reserveCapacity(n - 2)
        var misses = 0
        var i = 0

        while ring.count > 3 {
            let m = ring.count
            let idx = i % m
            let ia = ring[(idx + m - 1) % m]
            let ib = ring[idx]
            let ic = ring[(idx + 1) % m]
            let a = points[ia]
            let b = points[ib]
            let c = points[ic]
            let convex = cross(a, b, c) > 0
            let empty = convex && ring.allSatisfy { k in
                k == ia || k == ib || k == ic || {
                    let p = points[k]
                    return !(cross(a, b, p) >= 0 && cross(b, c, p) >= 0 && cross(c, a, p) >= 0)
                }()
            }
            if empty || (misses >= m && cross(a, b, c) == 0) {
                if empty {
                    out.append(([ia, ib, ic], edgeMask(ia, ib, ic)))
                }
                ring.remove(at: idx)
                misses = 0
                i = idx % ring.count
            } else {
                misses += 1
                if misses > 2 * m {
                    for k in 1..<(ring.count - 1) {
                        let x = ring[0], y = ring[k], z = ring[k + 1]
                        out.append(([x, y, z], edgeMask(x, y, z)))
                    }
                    return out
                }
                i = (idx + 1) % m
            }
        }
        let a = ring[0], b = ring[1], c = ring[2]
        out.append(([a, b, c], edgeMask(a, b, c)))
        return out
    }
}
