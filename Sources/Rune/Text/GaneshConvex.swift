// Port of upstream `crates/rune/src/text/convex/{mod.rs, geom.rs, raster.rs, fill.rs, hair.rs, tess.rs}`:
// Skia Ganesh's convex fill (`AAConvexPathRenderer`), hairlines (`AAHairLinePathRenderer`),
// convex stroke tessellation (`GrAAConvexTessellator`), and D3D11-style subpixel triangle rasterizer.

import Foundation
#if os(Android)
import Android
#endif

internal enum GaneshConvex {

    // MARK: - Geom (`geom.rs`)

    @inline(__always) static func nearlyZero(_ x: Float) -> Bool { abs(x) <= 1.0 / 4096.0 }
    @inline(__always) static func nearlyEqual(_ a: Float, _ b: Float) -> Bool { nearlyZero(a - b) }
    @inline(__always) static func midpoint(_ a: GPoint, _ b: GPoint) -> GPoint {
        GPoint(x: Float((Double(a.x) + Double(b.x)) * 0.5), y: Float((Double(a.y) + Double(b.y)) * 0.5))
    }

    static func nextlog2(_ x: Float) -> UInt32 {
        if x <= 1.0 || x.isNaN { return 0 }
        let bits = x.bitPattern &+ ((1 << 23) - 1)
        return UInt32(max(0, Int32((bits >> 23) & 0xFF) - 127))
    }

    static func nextlog16(_ x: Float) -> UInt32 { (nextlog2(x) + 3) >> 2 }

    static func quadraticLog2(precision: Float, _ p0: GPoint, _ p1: GPoint, _ p2: GPoint) -> UInt32 {
        let v = p1 * -2.0 + p0 + p2
        return nextlog16((v.x * v.x + v.y * v.y) * (0.0625 * (precision * precision)))
    }

    static func cubicLog2(precision: Float, _ p0: GPoint, _ p1: GPoint, _ p2: GPoint, _ p3: GPoint) -> UInt32 {
        let a = p1 * -2.0 + p0 + p2
        let b = p2 * -2.0 + p1 + p3
        return nextlog16(max(a.x * a.x + a.y * a.y, b.x * b.x + b.y * b.y) * (0.5625 * (precision * precision)))
    }

    static func maxVertices(_ log2: UInt32) -> UInt32 { 1 << min(log2, 10) }

    static func distanceToSegmentSqd(_ pt: GPoint, _ a: GPoint, _ b: GPoint) -> Float {
        let u = b - a, v = pt - a
        let uLen = u.dot(u), uDotV = u.dot(v)
        if uDotV <= 0 { return v.dot(v) }
        if uDotV > uLen { return b.distanceToSqd(pt) }
        let det = u.cross(v)
        let t = det / uLen * det
        return t.isFinite ? t : v.dot(v)
    }

    static func quadraticPoints(_ p0: GPoint, _ p1: GPoint, _ p2: GPoint, tolSqd: Float, out: inout [GPoint], left: UInt32) {
        if left < 2 || distanceToSegmentSqd(p1, p0, p2) < tolSqd {
            out.append(p2)
            return
        }
        let q0 = midpoint(p0, p1), q1 = midpoint(p1, p2)
        let r = midpoint(q0, q1)
        quadraticPoints(p0, q0, r, tolSqd: tolSqd, out: &out, left: left >> 1)
        quadraticPoints(r, q1, p2, tolSqd: tolSqd, out: &out, left: left >> 1)
    }

    static func cubicPoints(_ p0: GPoint, _ p1: GPoint, _ p2: GPoint, _ p3: GPoint, tolSqd: Float, out: inout [GPoint], left: UInt32) {
        if left < 2 || (distanceToSegmentSqd(p1, p0, p3) < tolSqd && distanceToSegmentSqd(p2, p0, p3) < tolSqd) {
            out.append(p3)
            return
        }
        let q0 = midpoint(p0, p1), q1 = midpoint(p1, p2), q2 = midpoint(p2, p3)
        let r0 = midpoint(q0, q1), r1 = midpoint(q1, q2)
        let s = midpoint(r0, r1)
        cubicPoints(p0, q0, r0, s, tolSqd: tolSqd, out: &out, left: left >> 1)
        cubicPoints(s, r1, q2, p3, tolSqd: tolSqd, out: &out, left: left >> 1)
    }

    // MARK: - Path helpers (`convex.rs`)

    static func oval(center: GPoint, radii: GPoint) -> [GEl] {
        let l = center.x - radii.x, t = center.y - radii.y
        let r = center.x + radii.x, b = center.y + radii.y
        let w = GaneshConstants.scalarRoot2Over2
        let cx = l * 0.5 + r * 0.5, cy = t * 0.5 + b * 0.5
        return [
            .move(GPoint(x: r, y: cy)),
            .conic(GPoint(x: r, y: b), GPoint(x: cx, y: b), w),
            .conic(GPoint(x: l, y: b), GPoint(x: l, y: cy), w),
            .conic(GPoint(x: l, y: t), GPoint(x: cx, y: t), w),
            .conic(GPoint(x: r, y: t), GPoint(x: r, y: cy), w),
            .close,
        ]
    }

    static func conicQuads(_ p0: GPoint, _ p1: GPoint, _ p2: GPoint, weight w: Float) -> [GPoint] {
        guard let q = GAutoConicToQuads.compute(p0, p1, p2, weight: w, tolerance: 0.25) else { return [p1, p2] }
        let count = 2 * Int(q.len)
        return Array(q.points[1..<(1 + count)])
    }

    static func closedConvex(_ path: [GEl]) -> Bool {
        var moves = 0, firstClose: Int? = nil
        for (idx, c) in path.enumerated() {
            if case .move = c { moves += 1 }
            else if case .close = c, firstClose == nil { firstClose = idx }
        }
        return moves == 1 && firstClose == path.count - 1 && direction(path) != nil
    }

    private struct Convexicator {
        var firstPt: GPoint = .zero
        var firstVec: GPoint = .zero
        var lastPt: GPoint = .zero
        var lastVec: GPoint = .zero
        var expected: Int32? = nil
        var firstDir: Int32 = 0
        var reversals: Int32 = 0

        mutating func setMove(_ pt: GPoint) {
            firstPt = pt; lastPt = pt; expected = nil
        }

        mutating func addPt(_ pt: GPoint) -> Bool {
            if lastPt == pt { return true }
            if firstPt == lastPt && expected == nil && lastVec == .zero {
                lastVec = pt - lastPt
                firstVec = lastVec
            } else if !addVec(pt - lastPt) {
                return false
            }
            lastPt = pt
            return true
        }

        mutating func close() -> Bool {
            let f = firstPt, v = firstVec
            return addPt(f) && addVec(v)
        }

        mutating func addVec(_ v: GPoint) -> Bool {
            let cross = lastVec.cross(v)
            guard cross.isFinite else { return false }
            if cross == 0 {
                if lastVec.dot(v) < 0 {
                    lastVec = v
                    reversals += 1
                    return reversals < 3
                }
                return true
            }
            let dir: Int32 = cross > 0 ? 1 : -1
            if let e = expected {
                if e != dir {
                    firstDir = 0
                    return false
                }
            } else {
                expected = dir
                firstDir = dir
            }
            lastVec = v
            return true
        }
    }

    private static func concaveBySign(_ points: [GPoint]) -> Bool {
        guard points.count > 3 else { return false }
        var dxes = 0, dyes = 0, lastSX = 2, lastSY = 2
        var cur = points[0]
        func step(_ q: GPoint) -> Bool {
            let v = q - cur
            if v.x != 0 || v.y != 0 {
                if !v.x.isFinite || !v.y.isFinite { return true }
                let sx = v.x < 0 ? 1 : 0, sy = v.y < 0 ? 1 : 0
                if sx != lastSX { dxes += 1 }
                if sy != lastSY { dyes += 1 }
                if dxes > 3 || dyes > 3 { return true }
                lastSX = sx; lastSY = sy
            }
            cur = q
            return false
        }
        for q in points.dropFirst() where step(q) { return true }
        return step(points[0])
    }

    static func direction(_ path: [GEl]) -> Int32? {
        let allPoints = path.flatMap(\.points)
        if concaveBySign(allPoints) { return nil }
        var state = Convexicator()
        var contours = 0
        var needsClose = false
        for cmd in path {
            let pts: [GPoint]
            switch cmd {
            case .move(let a):
                if contours == 1 {
                    guard state.close() else { return nil }
                    needsClose = false
                    contours += 1
                } else if contours == 0 {
                    state.setMove(a)
                }
                continue
            case .close:
                if contours >= 2 { return nil }
                if contours == 1 {
                    guard state.close() else { return nil }
                    needsClose = false
                    contours += 1
                }
                continue
            default:
                pts = cmd.points
            }
            if contours == 0 {
                contours = 1; needsClose = true
            } else if contours != 1 {
                return nil
            }
            for q in pts {
                if !state.addPt(q) { return nil }
            }
        }
        if needsClose && !state.close() { return nil }
        if state.firstDir == 0 && state.reversals >= 3 { return nil }
        return state.firstDir
    }

    // MARK: - Rasterizer (`raster.rs`)

    static func gradient(pts: [(Float, Float)], tri: (Int, Int, Int), _ a: (Int) -> Float, origin: (Float, Float)) -> (Float, Float) {
        let i0 = tri.0, i1 = tri.1, i2 = tri.2
        let p0x = Double(((pts[i0].0 - origin.0) * 256.0).rounded()) / 256.0
        let p0y = Double(((pts[i0].1 - origin.1) * 256.0).rounded()) / 256.0
        let p1x = Double(((pts[i1].0 - origin.0) * 256.0).rounded()) / 256.0
        let p1y = Double(((pts[i1].1 - origin.1) * 256.0).rounded()) / 256.0
        let p2x = Double(((pts[i2].0 - origin.0) * 256.0).rounded()) / 256.0
        let p2y = Double(((pts[i2].1 - origin.1) * 256.0).rounded()) / 256.0
        let det = (p1x - p0x) * (p2y - p0y) - (p2x - p0x) * (p1y - p0y)
        if det == 0 { return (0, 0) }
        let v0 = Double(a(i0)), v1 = Double(a(i1)), v2 = Double(a(i2))
        let dx = ((v1 - v0) * (p2y - p0y) - (v2 - v0) * (p1y - p0y)) / det
        let dy = ((v2 - v0) * (p1x - p0x) - (v1 - v0) * (p2x - p0x)) / det
        return (Float(dx), Float(dy))
    }

    static func rasterize(
        pts: [(Float, Float)],
        indices: [Int],
        origin: (Float, Float),
        px: Int,
        out: inout [UInt8],
        shade: ((Int, Int, Int), (Double, Double, Double)) -> Float
    ) {
        guard px > 0 else { return }
        var acc = [Float](repeating: 0, count: px * px)
        // Fixed point, 8 bits of subpixel; guard extreme coordinates before integer conversion so
        // hostile geometry can never overflow fixed-point edge math.
        let maxDevCoord: Float = 32_768.0
        @inline(__always) func snap(_ i: Int) -> (Int64, Int64)? {
            let x = pts[i].0 - origin.0
            let y = pts[i].1 - origin.1
            if !(x.isFinite && y.isFinite) || abs(x) > maxDevCoord || abs(y) > maxDevCoord {
                return nil
            }
            return (Int64((x * 256.0).rounded()), Int64((y * 256.0).rounded()))
        }
        // Coordinates are bounded to +/-32768 * 256 (+/-2^23), so edge deltas are <= 2^24 and
        // signed 64-bit cross products stay < 2^50 (well within Int64 without overflow).
        @inline(__always) func edge(_ a: (Int64, Int64), _ b: (Int64, Int64), _ p: (Int64, Int64)) -> Int64 {
            (b.0 - a.0) * (p.1 - a.1) - (b.1 - a.1) * (p.0 - a.0)
        }
        @inline(__always) func inside(_ w: Int64, _ a: (Int64, Int64), _ b: (Int64, Int64)) -> Bool {
            let dx = b.0 - a.0, dy = b.1 - a.1
            return w > 0 || (w == 0 && ((dy == 0 && dx > 0) || dy < 0))
        }
        let triEnd = indices.count - (indices.count % 3)
        for ti in stride(from: 0, to: triEnd, by: 3) {
            var i0 = indices[ti], i1 = indices[ti + 1], i2 = indices[ti + 2]
            guard var a = snap(i0), var b = snap(i1), let c = snap(i2) else { continue }
            var area = edge(a, b, c)
            if area == 0 { continue }
            if area < 0 {
                swap(&a, &b)
                swap(&i0, &i1)
                area = -area
            }
            let x0 = Int(max(0, min(a.0, min(b.0, c.0)) >> 8))
            let x1 = Int(min(Int64(px - 1), (max(a.0, max(b.0, c.0)) >> 8) + 1))
            let y0 = Int(max(0, min(a.1, min(b.1, c.1)) >> 8))
            let y1 = Int(min(Int64(px - 1), (max(a.1, max(b.1, c.1)) >> 8) + 1))
            guard y0 <= y1 && x0 <= x1 else { continue }
            let areaD = Double(area)
            for y in y0...y1 {
                for x in x0...x1 {
                    let p = (Int64(x) * 256 + 128, Int64(y) * 256 + 128)
                    let wa = edge(b, c, p), wb = edge(c, a, p), wc = edge(a, b, p)
                    guard inside(wa, b, c) && inside(wb, c, a) && inside(wc, a, b) else { continue }
                    let cov = gBound(shade((i0, i1, i2), (Double(wa) / areaD, Double(wb) / areaD, Double(wc) / areaD)), 0, 1)
                    let idx = y * px + x
                    acc[idx] = cov + acc[idx] * (1.0 - cov)
                }
            }
        }
        for i in 0..<(px * px) {
            out[i] = UInt8((gBound(acc[i], 0, 1) * 255.0).rounded())
        }
    }

    static func fillTriangles(_ mesh: TessMesh, origin: (Float, Float), px: Int, out: inout [UInt8]) {
        let pts = mesh.pts.map { ($0.x, $0.y) }
        rasterize(pts: pts, indices: mesh.indices, origin: origin, px: px, out: &out) { tri, w in
            Float(w.0 * Double(mesh.coverage[tri.0]) + w.1 * Double(mesh.coverage[tri.1]) + w.2 * Double(mesh.coverage[tri.2]))
        }
    }

    static func fillQuadEdges(_ mesh: EdgeMesh, origin: (Float, Float), px: Int, out: inout [UInt8]) {
        let pts = mesh.verts.map { $0.pos }
        rasterize(pts: pts, indices: mesh.indices, origin: origin, px: px, out: &out) { tri, w in
            let v0 = mesh.verts[tri.0].edge, v1 = mesh.verts[tri.1].edge, v2 = mesh.verts[tri.2].edge
            let e0 = Float(w.0 * Double(v0.0) + w.1 * Double(v1.0) + w.2 * Double(v2.0))
            let e1 = Float(w.0 * Double(v0.1) + w.1 * Double(v1.1) + w.2 * Double(v2.1))
            let e2 = Float(w.0 * Double(v0.2) + w.1 * Double(v1.2) + w.2 * Double(v2.2))
            let e3 = Float(w.0 * Double(v0.3) + w.1 * Double(v1.3) + w.2 * Double(v2.3))
            if e2 > 0 && e3 > 0 {
                return min(min(e2, e3) + 0.5, 1.0)
            }
            let du = gradient(pts: pts, tri: tri, { mesh.verts[$0].edge.0 }, origin: origin)
            let dv = gradient(pts: pts, tri: tri, { mesh.verts[$0].edge.1 }, origin: origin)
            let gx = 2.0 * e0 * du.0 - dv.0
            let gy = 2.0 * e0 * du.1 - dv.1
            let f = e0 * e0 - e1
            let gm = max(hypot(gx, gy), 1e-6)
            return gBound(0.5 - f / gm, 0, 1)
        }
    }

    // MARK: - Convex Fill (`fill.rs`)

    struct EdgeVert {
        var pos: (Float, Float)
        var edge: (Float, Float, Float, Float)
    }

    struct EdgeMesh {
        var verts: [EdgeVert]
        var indices: [Int]
    }

    private struct FillSegment {
        var quad: Bool = false
        var p0: GPoint = .zero
        var p1: GPoint = .zero
        var n0: GPoint = .zero
        var n1: GPoint = .zero
        var mid: GPoint = .zero

        var count: Int { quad ? 2 : 1 }
        var end: GPoint { quad ? p1 : p0 }
        var endNorm: GPoint { quad ? n1 : n0 }
        func pt(_ idx: Int) -> GPoint { idx == 0 ? p0 : p1 }
        func norm(_ idx: Int) -> GPoint { idx == 0 ? n0 : n1 }
        mutating func setNorm(_ idx: Int, _ v: GPoint) { if idx == 0 { n0 = v } else { n1 = v } }
    }

    private enum DegenStage { case initial, point, line, nonDegenerate }

    private struct DegenerateChecker {
        static let close: Float = 1.0 / 16.0
        static let closeSqd: Float = (1.0 / 16.0) * (1.0 / 16.0)
        var stage: DegenStage = .initial
        var first: GPoint = .zero
        var normal: GPoint = .zero
        var c: Float = 0

        mutating func add(_ p: GPoint) {
            switch stage {
            case .initial:
                first = p; stage = .point
            case .point:
                if p.distanceToSqd(first) > Self.closeSqd {
                    var n = p - first
                    _ = n.normalize()
                    normal = n.orthog(-1)
                    c = -normal.dot(first)
                    stage = .line
                }
            case .line:
                if abs(normal.dot(p) + c) > Self.close {
                    stage = .nonDegenerate
                }
            case .nonDegenerate:
                break
            }
        }
    }

    static func fill(path: [GEl], ctm: GTransform, dir inDir: Int32) -> EdgeMesh? {
        let dir = (ctm.xx * ctm.yy - ctm.xy * ctm.yx < 0) ? -inDir : inDir
        @inline(__always) func map(_ p: GPoint) -> GPoint { ctm.transformPoint(p) }
        var segs: [FillSegment] = []
        var degenerate = DegenerateChecker()
        var start: GPoint? = nil
        var cur: GPoint? = nil

        func addQuad(_ p0: GPoint, _ p1: GPoint, _ p2: GPoint) {
            if distanceToSegmentSqd(p1, p0, p2) < DegenerateChecker.closeSqd {
                if p0 != p2 { segs.append(FillSegment(p0: p2)) }
            } else {
                segs.append(FillSegment(quad: true, p0: p1, p1: p2))
            }
        }

        for el in path {
            switch el {
            case .move(let p):
                degenerate.add(map(p))
                start = p; cur = p
            case .line(let p):
                if cur != p {
                    let d = map(p)
                    degenerate.add(d)
                    segs.append(FillSegment(p0: d))
                }
                cur = p
            case .quad(let c, let p):
                guard let from = cur else { continue }
                if !(from == c && c == p) {
                    let q0 = map(from), q1 = map(c), q2 = map(p)
                    degenerate.add(q1); degenerate.add(q2)
                    addQuad(q0, q1, q2)
                }
                cur = p
            case .conic(let c, let p, let w):
                guard let from = cur else { continue }
                if !(from == c && c == p) {
                    let q0 = map(from)
                    let q = conicQuads(q0, map(c), map(p), weight: w)
                    var last = q0
                    for idx in stride(from: 0, to: q.count - (q.count % 2), by: 2) {
                        degenerate.add(q[idx]); degenerate.add(q[idx + 1])
                        addQuad(last, q[idx], q[idx + 1])
                        last = q[idx + 1]
                    }
                }
                cur = p
            case .cubic(let c1, let c2, let p):
                guard let from = cur else { continue }
                if !(from == c1 && c1 == c2 && c2 == p) {
                    let q0 = map(from), q1 = map(c1), q2 = map(c2), q3 = map(p)
                    degenerate.add(q1); degenerate.add(q2); degenerate.add(q3)
                    var quads: [GPoint] = []
                    cubicToQuads((q0, q1, q2, q3), dir: dir, quads: &quads)
                    for idx in stride(from: 0, to: quads.count - (quads.count % 3), by: 3) {
                        addQuad(quads[idx], quads[idx + 1], quads[idx + 2])
                    }
                }
                cur = p
            case .close:
                if let s = start, let c = cur, s != c {
                    let d = map(s)
                    degenerate.add(d)
                    segs.append(FillSegment(p0: d))
                }
                cur = start
            }
        }
        guard degenerate.stage == .nonDegenerate else { return nil }
        guard let fan = computeVectors(&segs, dir: dir) else { return nil }
        return createFillVertices(segs, fan: fan)
    }

    private static func centerOfMass(_ segs: [FillSegment]) -> GPoint? {
        let n = segs.count
        guard n > 0 else { return nil }
        var area: Float = 0, center = GPoint.zero, p0 = GPoint.zero
        if n > 2 {
            p0 = segs[0].end
            var pj = segs[1].end - p0
            for i in 1..<(n - 1) {
                let pi = pj
                pj = segs[i + 1].end - p0
                let t = pi.cross(pj)
                area += t
                center.x += (pi.x + pj.x) * t
                center.y += (pi.y + pj.y) * t
            }
        }
        let c: GPoint
        if nearlyZero(area) {
            var sum = GPoint.zero
            for s in segs { sum.x += s.end.x; sum.y += s.end.y }
            c = sum * (1.0 / Float(n))
        } else {
            let inv = 1.0 / (area * 3.0)
            c = center * inv + p0
        }
        return (c.x.isFinite && c.y.isFinite) ? c : nil
    }

    private static func computeVectors(_ segs: inout [FillSegment], dir: Int32) -> GPoint? {
        guard let fan = centerOfMass(segs) else { return nil }
        let n = segs.count
        let side: Int32 = dir == -1 ? 1 : -1
        for a in 0..<n {
            let b = (a + 1) % n
            var prev = segs[a].end
            for p in 0..<segs[b].count {
                var d = segs[b].pt(p) - prev
                _ = d.normalize()
                segs[b].setNorm(p, d.orthog(side))
                prev = segs[b].pt(p)
            }
        }
        for a in 0..<n {
            let b = (a + 1) % n
            var mid = segs[b].norm(0) + segs[a].endNorm
            _ = mid.normalize()
            segs[b].mid = mid
        }
        return fan
    }

    private static func distanceToLine(_ pt: GPoint, _ a: GPoint, _ b: GPoint) -> Float {
        let u = b - a, v = pt - a
        let det = u.cross(v)
        return (det / u.dot(u) * det).squareRoot()
    }

    private static func createFillVertices(_ segs: [FillSegment], fan: GPoint) -> EdgeMesh {
        var verts: [EdgeVert] = []
        var idx: [Int] = []
        @inline(__always) func vert(_ p: GPoint, _ uv: (Float, Float), _ d: (Float, Float)) -> EdgeVert {
            EdgeVert(pos: (p.x, p.y), edge: (uv.0, uv.1, d.0, d.1))
        }
        let neg: (Float, Float) = (-1, -1)
        let n = segs.count
        let big: Float = -Float.greatestFiniteMagnitude / 1_000_000.0
        for a in 0..<n {
            let sa = segs[a], sb = segs[(a + 1) % n]
            var v = verts.count
            let p0 = sa.end
            verts.append(vert(p0, (0, 0), neg))
            verts.append(vert(p0 + sa.endNorm, (0, -1), neg))
            verts.append(vert(p0 + sb.mid, (0, -1), neg))
            verts.append(vert(p0 + sb.norm(0), (0, -1), neg))
            idx.append(contentsOf: [v, v + 2, v + 1, v, v + 3, v + 2])
            v = verts.count
            if !sb.quad {
                let v1 = sa.end, v2 = sb.p0
                let dist = distanceToLine(fan, v1, v2)
                verts.append(vert(fan, (0, dist), neg))
                verts.append(vert(v1, (0, 0), neg))
                verts.append(vert(v2, (0, 0), neg))
                verts.append(vert(v1 + sb.norm(0), (0, -1), neg))
                verts.append(vert(v2 + sb.norm(0), (0, -1), neg))
                idx.append(contentsOf: [v + 3, v + 1, v + 2, v + 4, v + 3, v + 2])
                if n >= 3 { idx.append(contentsOf: [v, v + 2, v + 1]) }
            } else {
                let q = (sa.end, sb.p0, sb.p1)
                let c0 = sb.n0.dot(q.0), c1 = sb.n1.dot(q.2)
                var mid = sb.n0 + sb.n1
                _ = mid.normalize()
                let pos = [fan, q.0, q.2, q.0 + sb.n0, q.2 + sb.n1, q.1 + mid]
                let m = quadUVMatrix(q.0, q.1, q.2)
                @inline(__always) func uv(_ p: GPoint) -> (Float, Float) {
                    (m.0 * p.x + m.1 * p.y + m.2, m.3 * p.x + m.4 * p.y + m.5)
                }
                verts.append(vert(pos[0], uv(pos[0]), (-sb.n0.dot(fan) + c0, -sb.n1.dot(fan) + c1)))
                verts.append(vert(pos[1], uv(pos[1]), (0, -sb.n1.dot(q.0) + c1)))
                verts.append(vert(pos[2], uv(pos[2]), (-sb.n0.dot(q.2) + c0, 0)))
                for p in pos[3...] { verts.append(vert(p, uv(p), (big, big))) }
                idx.append(contentsOf: [v + 3, v + 1, v + 2, v + 4, v + 3, v + 2, v + 5, v + 3, v + 4])
                if n >= 3 { idx.append(contentsOf: [v, v + 2, v + 1]) }
            }
        }
        return EdgeMesh(verts: verts, indices: idx)
    }

    static func quadUVMatrix(_ q0: GPoint, _ q1: GPoint, _ q2: GPoint) -> (Float, Float, Float, Float, Float, Float) {
        let x0 = Double(q0.x), y0 = Double(q0.y), x1 = Double(q1.x), y1 = Double(q1.y), x2 = Double(q2.x), y2 = Double(q2.y)
        let a2 = x1 * y2 - x2 * y1, a5 = x2 * y0 - x0 * y2, a8 = x0 * y1 - x1 * y0
        let det = a2 + a5 + a8
        if !det.isFinite || abs(Float(det)) <= (1.0 / 4096.0) * (1.0 / 4096.0) {
            let pts = [q0, q1, q2]
            let d = [q0.distanceToSqd(q1), q1.distanceToSqd(q2), q2.distanceToSqd(q0)]
            var maxEdge = 0, maxD = d[0]
            for i in 1..<3 where d[i] > maxD { maxD = d[i]; maxEdge = i }
            if maxD > 0 {
                let l = (pts[(maxEdge + 1) % 3] - pts[maxEdge]).orthog(-1)
                return (0, 0, 0, l.x, l.y, -l.dot(pts[maxEdge]))
            }
            return (0, 0, 100, 0, 0, 100)
        }
        let scale = 1.0 / det
        let a3 = y2 - y0, a4 = x0 - x2, a6 = y0 - y1, a7 = x1 - x0
        return (
            Float((0.5 * a3 + a6) * scale),
            Float((0.5 * a4 + a7) * scale),
            Float((0.5 * a5 + a8) * scale),
            Float(a6 * scale),
            Float(a7 * scale),
            Float(a8 * scale)
        )
    }

    static func chopAtInflections(_ p: (GPoint, GPoint, GPoint, GPoint)) -> [(GPoint, GPoint, GPoint, GPoint)] {
        let a = p.1 - p.0
        let b = GPoint(x: p.2.x - 2.0 * p.1.x + p.0.x, y: p.2.y - 2.0 * p.1.y + p.0.y)
        let c = GPoint(x: p.3.x + 3.0 * (p.1.x - p.2.x) - p.0.x, y: p.3.y + 3.0 * (p.1.y - p.2.y) - p.0.y)
        var ts = [Float](repeating: 0, count: 3)
        let count = GPathGeometry.findUnitQuadRoots(a: b.x * c.y - b.y * c.x, b: a.x * c.y - a.y * c.x, c: a.x * b.y - a.y * b.x, roots: &ts)
        if count == 0 { return [p] }
        if count == 1 {
            let d = GPathGeometry.chopCubicAt2(p, t: ts[0])
            return [(d.0, d.1, d.2, d.3), (d.3, d.4, d.5, d.6)]
        }
        let t0 = ts[0], t1 = ts[1]
        if t1 == 1.0 {
            let d = GPathGeometry.chopCubicAt2(p, t: t0)
            return [(d.0, d.1, d.2, d.3), (d.3, d.4, d.5, d.6), (p.3, p.3, p.3, p.3)]
        }
        @inline(__always) func mix(_ u: GPoint, _ v: GPoint, _ t: Float) -> GPoint { (v - u) * t + u }
        let ab0 = mix(p.0, p.1, t0), bc0 = mix(p.1, p.2, t0), cd0 = mix(p.2, p.3, t0)
        let abc0 = mix(ab0, bc0, t0), bcd0 = mix(bc0, cd0, t0)
        let ab1 = mix(p.0, p.1, t1), bc1 = mix(p.1, p.2, t1), cd1 = mix(p.2, p.3, t1)
        let abc1 = mix(ab1, bc1, t1), bcd1 = mix(bc1, cd1, t1)
        let abcd0 = mix(abc0, bcd0, t0), abcd1 = mix(abc1, bcd1, t1)
        let m0 = mix(abc0, bcd0, t1), m1 = mix(abc1, bcd1, t0)
        return [(p.0, ab0, abc0, abcd0), (abcd0, m0, m1, abcd1), (abcd1, bcd1, cd1, p.3)]
    }

    private static func cubicToQuads(_ p: (GPoint, GPoint, GPoint, GPoint), dir: Int32, quads: inout [GPoint]) {
        guard p.0.isFinite && p.1.isFinite && p.2.isFinite && p.3.isFinite else { return }
        for c in chopAtInflections(p) {
            noninflectToQuads(c, tolSqd: 1.0, dir: dir, quads: &quads, sublevel: 0)
        }
    }

    private static func isWithinTangents(_ a: GPoint, _ ab: GPoint, _ dc: GPoint, _ d: GPoint, _ dir: Int32, _ p: GPoint) -> Bool {
        let apAB = (p - a).cross(ab)
        if (dir == 1 && apAB > 0) || (dir != 1 && apAB < 0) { return false }
        let dpDC = (p - d).cross(dc)
        return !((dir == 1 && dpDC < 0) || (dir != 1 && dpDC > 0))
    }

    private static func noninflectToQuads(_ p: (GPoint, GPoint, GPoint, GPoint), tolSqd: Float, dir: Int32, quads: inout [GPoint], sublevel: UInt32) {
        let near: Float = 1.0 / 4096.0
        var ab = p.1 - p.0, dc = p.2 - p.3
        if ab.dot(ab) < near {
            if dc.dot(dc) < near {
                quads.append(contentsOf: [p.0, p.0, p.3]); return
            }
            ab = p.2 - p.0
        }
        if dc.dot(dc) < near { dc = p.1 - p.3 }
        let da = p.0 - p.3
        var doQuads = dc.dot(dc) < near || ab.dot(ab) < near
        if !doQuads {
            var inv = da.dot(da)
            if inv > near {
                inv = 1.0 / inv
                let detAB = ab.cross(da), detDC = dc.cross(da)
                if (detAB * detAB) * inv < tolSqd && (detDC * detDC) * inv < tolSqd { doQuads = true }
            }
        }
        if doQuads {
            let b = p.0 + ab, c = p.3 + dc
            let mid = (b + c) * 0.5
            if da.dot(dc) < 0 || ab.dot(da) > 0 {
                quads.append(contentsOf: [p.0, b, mid, mid, c, p.3])
            } else {
                quads.append(contentsOf: [p.0, mid, p.3])
            }
            return
        }
        let ab15 = ab * 1.5, dc15 = dc * 1.5
        let c0 = p.0 + ab15, c1 = p.3 + dc15
        let dSqd = sublevel > 10 ? 0.0 : c0.distanceToSqd(c1)
        if dSqd < tolSqd {
            var avg = (c0 + c1) * 0.5
            var subdivide = false
            if !isWithinTangents(p.0, ab15, dc15, p.3, dir, avg) {
                let abO = ab15.orthog(-1), z0 = -abO.dot(p.0)
                let dcO = dc15.orthog(-1), z1 = -dcO.dot(p.3)
                avg = GPoint(x: abO.y * z1 - z0 * dcO.y, y: z0 * dcO.x - abO.x * z1)
                let z = 1.0 / (abO.x * dcO.y - abO.y * dcO.x)
                avg = GPoint(x: avg.x * z, y: avg.y * z)
                if sublevel <= 10 {
                    let d0 = c0.distanceToSqd(avg), d1 = c1.distanceToSqd(avg)
                    subdivide = 2.0 * (d0 * d1).squareRoot() + d0 + d1 > tolSqd
                }
            }
            if !subdivide {
                quads.append(contentsOf: [p.0, avg, p.3]); return
            }
        }
        let h = GPathGeometry.chopCubicAt2(p, t: 0.5)
        noninflectToQuads((h.0, h.1, h.2, h.3), tolSqd: tolSqd, dir: dir, quads: &quads, sublevel: sublevel + 1)
        noninflectToQuads((h.3, h.4, h.5, h.6), tolSqd: tolSqd, dir: dir, quads: &quads, sublevel: sublevel + 1)
    }

    // MARK: - Hairline Renderer (`hair.rs`)

    private enum HairKind { case line, quad, conic }

    static func hairline(path: [GEl], ctm: GTransform, width: Float, origin: (Float, Float), px: Int, out: inout [UInt8]) {
        let coverage = (gBound(width, 0, 1) * 255.0).rounded() / 255.0
        var lines: [GPoint] = []
        var quads: [GPoint] = []
        var conics: [((GPoint, GPoint, GPoint), Float)] = []
        @inline(__always) func map(_ p: GPoint) -> GPoint { ctm.transformPoint(p) }
        func degenerate(_ p0: GPoint, _ p1: GPoint, _ p2: GPoint) -> Bool {
            let tol: Float = 0.25 * 0.25
            return p0.distanceToSqd(p1) < tol || p1.distanceToSqd(p2) < tol ||
                   distanceToSegmentSqd(p1, p0, p2) < tol || distanceToSegmentSqd(p2, p1, p0) < tol
        }
        @inline(__always) func lineSqd(_ pt: GPoint, _ a: GPoint, _ b: GPoint) -> Float {
            let u = b - a, v = pt - a
            let det = u.cross(v)
            let t = det / u.dot(u) * det
            return t.isFinite ? t : v.dot(v)
        }
        func degenTri(_ p0: GPoint, _ p1: GPoint, _ p2: GPoint) -> Bool {
            let tol: Float = 0.25 * 0.25
            return p0.distanceToSqd(p1) < tol || p1.distanceToSqd(p2) < tol || lineSqd(p1, p0, p2) < tol || lineSqd(p2, p1, p0) < tol
        }
        func addQuad(_ q0: GPoint, _ q1: GPoint, _ q2: GPoint) {
            if degenTri(q0, q1, q2) {
                lines.append(contentsOf: [q0, q1, q1, q2])
            } else {
                quads.append(contentsOf: [q0, q1, q2])
            }
        }
        func splitConic(_ p: (GPoint, GPoint, GPoint), _ w: Float) -> [((GPoint, GPoint, GPoint), Float)] {
            let t = GPathGeometry.findQuadMaxCurvature(p.0, p.1, p.2)
            guard t > 0 && t < 1 else { return [(p, w)] }
            let h0 = (p.0.x, p.0.y, Float(1)), h1 = (p.1.x * w, p.1.y * w, w), h2 = (p.2.x, p.2.y, Float(1))
            @inline(__always) func mixH(_ a: (Float, Float, Float), _ b: (Float, Float, Float)) -> (Float, Float, Float) {
                (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
            }
            let ab = mixH(h0, h1), bc = mixH(h1, h2), abc = mixH(ab, bc)
            @inline(__always) func down(_ a: (Float, Float, Float)) -> GPoint { GPoint(x: a.0 / a.2, y: a.1 / a.2) }
            let root = abc.2.squareRoot()
            let halfA = ((p.0, down(ab), down(abc)), ab.2 / root)
            let halfB = ((down(abc), down(bc), p.2), bc.2 / root)
            if halfA.1.isFinite && halfB.1.isFinite &&
               halfA.0.0.isFinite && halfA.0.1.isFinite && halfA.0.2.isFinite &&
               halfB.0.0.isFinite && halfB.0.1.isFinite && halfB.0.2.isFinite {
                return [halfA, halfB]
            }
            return [(p, w)]
        }
        func chopQuadMax(_ p0: GPoint, _ p1: GPoint, _ p2: GPoint) -> [(GPoint, GPoint, GPoint)] {
            let t = GPathGeometry.findQuadMaxCurvature(p0, p1, p2)
            if t > 0 && t < 1 {
                @inline(__always) func mix(_ a: GPoint, _ b: GPoint) -> GPoint { (b - a) * t + a }
                let ab = mix(p0, p1), bc = mix(p1, p2), abc = mix(ab, bc)
                return [(p0, ab, abc), (abc, bc, p2)]
            }
            return [(p0, p1, p2)]
        }
        func hairCubicToQuads(_ p: (GPoint, GPoint, GPoint, GPoint), _ outQ: inout [GPoint], sublevel: UInt32, first: Bool, last: Bool) {
            let near: Float = 1.0 / 4096.0
            var ab = p.1 - p.0, dc = p.2 - p.3
            if ab.dot(ab) < near {
                if dc.dot(dc) < near { outQ.append(contentsOf: [p.0, p.0, p.3]); return }
                ab = p.2 - p.0
            }
            if dc.dot(dc) < near { dc = p.1 - p.3 }
            let c0 = p.0 + ab * 1.5, c1 = p.3 + dc * 1.5
            let dSqd = sublevel > 10 ? 0.0 : c0.distanceToSqd(c1)
            if dSqd < 1.0 {
                let c = (first == last) ? (c0 + c1) * 0.5 : (first ? c0 : c1)
                outQ.append(contentsOf: [p.0, c, p.3]); return
            }
            @inline(__always) func mix(_ a: GPoint, _ b: GPoint) -> GPoint { (b - a) * 0.5 + a }
            let abm = mix(p.0, p.1), bcm = mix(p.1, p.2), cdm = mix(p.2, p.3)
            let abcm = mix(abm, bcm), bcdm = mix(bcm, cdm), abcdm = mix(abcm, bcdm)
            hairCubicToQuads((p.0, abm, abcm, abcdm), &outQ, sublevel: sublevel + 1, first: first, last: false)
            hairCubicToQuads((abcdm, bcdm, cdm, p.3), &outQ, sublevel: sublevel + 1, first: false, last: last)
        }

        var start = GPoint.zero, cur = GPoint.zero
        for el in path {
            switch el {
            case .move(let p):
                start = p; cur = p
            case .line(let p):
                lines.append(contentsOf: [map(cur), map(p)]); cur = p
            case .quad(let c, let p):
                for q in chopQuadMax(cur, c, p) { addQuad(map(q.0), map(q.1), map(q.2)) }
                cur = p
            case .conic(let c, let p, let w):
                for (q, qw) in splitConic((cur, c, p), w).flatMap({ splitConic($0.0, $0.1) }) {
                    let d = (map(q.0), map(q.1), map(q.2))
                    if degenTri(d.0, d.1, d.2) { lines.append(contentsOf: [d.0, d.1, d.1, d.2]) }
                    else { conics.append((d, qw)) }
                }
                cur = p
            case .cubic(let c1, let c2, let p):
                let d = (map(cur), map(c1), map(c2), map(p))
                for c in chopAtInflections(d) {
                    var q: [GPoint] = []
                    hairCubicToQuads(c, &q, sublevel: 0, first: true, last: true)
                    for idx in stride(from: 0, to: q.count - (q.count % 3), by: 3) {
                        addQuad(q[idx], q[idx + 1], q[idx + 2])
                    }
                }
                cur = p
            case .close:
                if cur != start { lines.append(contentsOf: [map(cur), map(start)]) }
                cur = start
            }
        }
        _ = degenerate

        var pts: [(Float, Float)] = []
        var attr: [(HairKind, (Float, Float, Float))] = []
        var indices: [Int] = []

        func makeLineHex(_ a: GPoint, _ b: GPoint) -> [(GPoint, Float)]? {
            var vec = b - a
            let lenSqd = vec.dot(vec)
            guard vec.setLength(0.5) else { return nil }
            let ortho = GPoint(x: 2.0 * vec.y, y: -2.0 * vec.x)
            let i0: (GPoint, Float), i1: (GPoint, Float)
            if lenSqd >= 1.0 {
                i0 = (a + vec, coverage); i1 = (b - vec, coverage)
            } else {
                let len = lenSqd.squareRoot()
                i0 = (b - vec, coverage * len); i1 = (a + vec, coverage * len)
            }
            return [i0, i1, (a - vec + ortho, 0), (b + vec + ortho, 0), (a - vec - ortho, 0), (b + vec - ortho, 0)]
        }

        func intersectLines(_ pa: GPoint, _ na: GPoint, _ pb: GPoint, _ nb: GPoint) -> GPoint {
            let aw = -na.dot(pa), bw = -nb.dot(pb)
            let wInv = 1.0 / (na.x * nb.y - na.y * nb.x)
            guard wInv.isFinite else { return (pa + pb) * 0.5 + na }
            return GPoint(x: (na.y * bw - aw * nb.y) * wInv, y: (aw * nb.x - na.x * bw) * wInv)
        }

        func bloatQuad(_ a: GPoint, _ b: GPoint, _ c: GPoint) -> [GPoint]? {
            var ab = b - a, cb = b - c
            let ac = c - a
            let abOk = ab.normalize(), cbOk = cb.normalize()
            if !abOk { if !cbOk { return nil }; ab = cb }
            if !cbOk { cb = ab }
            var abN = ab.orthog(-1); if abN.dot(ac) > 0 { abN = -abN }
            var cbN = cb.orthog(-1); if cbN.dot(ac) < 0 { cbN = -cbN }
            let a0 = a + abN, a1 = a - abN, c0 = c + cbN, c1 = c - cbN
            return [a0, a1, intersectLines(a0, abN, c0, cbN), c0, c1]
        }

        for li in stride(from: 0, to: lines.count - (lines.count % 2), by: 2) {
            guard let hex = makeLineHex(lines[li], lines[li + 1]) else { continue }
            let base = pts.count
            for (p, c) in hex {
                pts.append((p.x, p.y)); attr.append((.line, (c, 0, 0)))
            }
            for o in [0, 1, 3, 0, 3, 2, 0, 4, 5, 0, 5, 1, 0, 2, 4, 1, 5, 3] { indices.append(base + o) }
        }
        for qi in stride(from: 0, to: quads.count - (quads.count % 3), by: 3) {
            let q0 = quads[qi], q1 = quads[qi + 1], q2 = quads[qi + 2]
            guard let pent = bloatQuad(q0, q1, q2) else { continue }
            let m = quadUVMatrix(q0, q1, q2)
            let base = pts.count
            for p in pent {
                pts.append((p.x, p.y))
                attr.append((.quad, (m.0 * p.x + m.1 * p.y + m.2, m.3 * p.x + m.4 * p.y + m.5, 0)))
            }
            for o in [0, 1, 2, 2, 4, 3, 1, 4, 2] { indices.append(base + o) }
        }
        for (c, w) in conics {
            guard let pent = bloatQuad(c.0, c.1, c.2) else { continue }
            let w2 = 2.0 * w
            let r0 = (c.2.y - c.0.y, c.0.x - c.2.x, c.2.x * c.0.y - c.0.x * c.2.y)
            let r1 = (w2 * (c.1.y - c.0.y), w2 * (c.0.x - c.1.x), w2 * (c.1.x * c.0.y - c.0.x * c.1.y))
            let r2 = (w2 * (c.2.y - c.1.y), w2 * (c.1.x - c.2.x), w2 * (c.2.x * c.1.y - c.1.x * c.2.y))
            let maxAbs = max(max(abs(r0.0), abs(r0.1), abs(r0.2)), max(max(abs(r1.0), abs(r1.1), abs(r1.2)), max(abs(r2.0), abs(r2.1), abs(r2.2))))
            let sc = 10.0 / maxAbs
            let base = pts.count
            for p in pent {
                pts.append((p.x, p.y))
                let kv = (r0.0 * sc) * p.x + (r0.1 * sc) * p.y + (r0.2 * sc)
                let lv = (r1.0 * sc) * p.x + (r1.1 * sc) * p.y + (r1.2 * sc)
                let mv = (r2.0 * sc) * p.x + (r2.1 * sc) * p.y + (r2.2 * sc)
                attr.append((.conic, (kv, lv, mv)))
            }
            for o in [0, 1, 2, 2, 4, 3, 1, 4, 2] { indices.append(base + o) }
        }
        rasterize(pts: pts, indices: indices, origin: origin, px: px, out: &out) { tri, w in
            let a0 = attr[tri.0].1, a1 = attr[tri.1].1, a2 = attr[tri.2].1
            @inline(__always) func at0() -> Float { Float(w.0 * Double(a0.0) + w.1 * Double(a1.0) + w.2 * Double(a2.0)) }
            @inline(__always) func at1() -> Float { Float(w.0 * Double(a0.1) + w.1 * Double(a1.1) + w.2 * Double(a2.1)) }
            @inline(__always) func at2() -> Float { Float(w.0 * Double(a0.2) + w.1 * Double(a1.2) + w.2 * Double(a2.2)) }
            let f: Float, gx: Float, gy: Float
            switch attr[tri.0].0 {
            case .line:
                return at0()
            case .quad:
                let u = at0(), v = at1()
                let du = gradient(pts: pts, tri: tri, { attr[$0].1.0 }, origin: origin)
                let dv = gradient(pts: pts, tri: tri, { attr[$0].1.1 }, origin: origin)
                f = u * u - v
                gx = 2.0 * u * du.0 - dv.0
                gy = 2.0 * u * du.1 - dv.1
            case .conic:
                let k = at0(), l = at1(), m = at2()
                let dk = gradient(pts: pts, tri: tri, { attr[$0].1.0 }, origin: origin)
                let dl = gradient(pts: pts, tri: tri, { attr[$0].1.1 }, origin: origin)
                let dm = gradient(pts: pts, tri: tri, { attr[$0].1.2 }, origin: origin)
                f = k * k - l * m
                gx = 2.0 * k * dk.0 - l * dm.0 - m * dl.0
                gy = 2.0 * k * dk.1 - l * dm.1 - m * dl.1
            }
            let gm = (gx * gx + gy * gy).squareRoot()
            if gm == 0 { return 0 }
            return max(1.0 - abs(f) / gm, 0) * coverage
        }
    }

    // MARK: - Convex Stroke Tessellator (`tess.rs`)

    struct TessMesh {
        var pts: [GPoint]
        var coverage: [Float]
        var indices: [Int]
    }

    private enum TessCurve { case sharp, indeterminate, smooth }

    private struct RingPt {
        var norm: GPoint = .zero
        var bisector: GPoint = .zero
        var index: Int = 0
        var origEdge: Int = 0
    }

    private struct Candidate {
        var pt: GPoint
        var originating: Int?
        var origEdge: Int
        var needsNew: Bool
    }

    private struct Tess {
        static let aaRadius: Float = 0.5
        static let closeDist: Float = 1.0 / 16.0
        static let closeSqd: Float = (1.0 / 16.0) * (1.0 / 16.0)
        static let curveTolerance: Float = 0.2
        static let roundCapThreshold: Float = 0.8
        static let curveConnectionThreshold: Float = 0.8

        var pts: [GPoint] = []
        var coverage: [Float] = []
        var movable: [Bool] = []
        var curve: [TessCurve] = []
        var norms: [GPoint] = []
        var bisectors: [GPoint] = []
        var side: Int32 = 0
        var indices: [Int] = []
        let join: GLineJoin
        let miterLimit: Float
        var accumError: Float = 0

        @inline(__always) static func duplicate(_ a: GPoint, _ b: GPoint) -> Bool { a.distanceToSqd(b) < closeSqd }

        static func intersect(_ p0: GPoint, _ n0: GPoint, _ p1: GPoint, _ n1: GPoint) -> Float? {
            let v = p1 - p0
            let perpDot = n0.x * n1.y - n0.y * n1.x
            if GaneshConvex.nearlyZero(perpDot) { return nil }
            let t = (v.x * n1.y - v.y * n1.x) / perpDot
            return t.isFinite ? t : nil
        }

        static func perpIntersect(_ p0: GPoint, _ n0: GPoint, _ p1: GPoint, _ perp: GPoint) -> Float? {
            let v = p1 - p0
            let perpDot = n0.dot(perp)
            if GaneshConvex.nearlyZero(perpDot) { return nil }
            let t = v.dot(perp) / perpDot
            return t.isFinite ? t : nil
        }

        static func colinearAndBIsMiddle(_ a: GPoint, _ b: GPoint, _ c: GPoint, accum: inout Float) -> Bool {
            let toC = c - a
            var n = GPoint(x: toC.y, y: -toC.x)
            _ = n.normalize()
            let dist = abs(n.dot(b) - n.dot(a))
            if accum + dist >= closeDist || toC.dot(b - a) <= 0 || toC.dot(c - b) <= 0 { return false }
            accum += dist
            return true
        }

        static func coverageAt(depth: Float, initialDepth: Float, initialCoverage: Float, targetDepth: Float, targetCoverage: Float) -> Float {
            if GaneshConvex.nearlyEqual(initialDepth, targetDepth) { return targetCoverage }
            return gBound((depth - initialDepth) / (targetDepth - initialDepth) * (targetCoverage - initialCoverage) + initialCoverage, 0, 1)
        }

        mutating func addPt(_ pt: GPoint, _ cov: Float, _ mov: Bool, _ crv: TessCurve) -> Int {
            pts.append(pt); coverage.append(cov); movable.append(mov); curve.append(crv)
            return pts.count - 1
        }

        mutating func popLast() {
            pts.removeLast(); coverage.removeLast(); movable.removeLast(); curve.removeLast()
        }

        mutating func popFirstShuffle() {
            let last = pts.count - 1
            pts.swapAt(0, last); coverage.swapAt(0, last); movable.swapAt(0, last); curve.swapAt(0, last)
            popLast()
        }

        mutating func addTri(_ a: Int, _ b: Int, _ c: Int) {
            if a == b || b == c || c == a { return }
            indices.append(contentsOf: [a, b, c])
        }

        mutating func lineTo(_ p: GPoint, _ crv: TessCurve) {
            if let last = pts.last, Self.duplicate(p, last) { return }
            let n = pts.count
            if n >= 2 && Self.colinearAndBIsMiddle(pts[n - 2], pts[n - 1], p, accum: &accumError) {
                popLast()
                if let last = pts.last, Self.duplicate(p, last) { return }
            } else {
                accumError = 0
            }
            _ = addPt(p, 1.0, false, crv)
        }

        mutating func flattened(_ out: [GPoint]) {
            for q in out[..<(out.count - 1)] { lineTo(q, .smooth) }
            lineTo(out[out.count - 1], out.count == 1 ? .sharp : .indeterminate)
        }

        mutating func quadTo(_ p0: GPoint, _ p1: GPoint, _ p2: GPoint) {
            let maxV = GaneshConvex.maxVertices(GaneshConvex.quadraticLog2(precision: 1.0 / Self.curveTolerance, p0, p1, p2))
            var out: [GPoint] = []
            GaneshConvex.quadraticPoints(p0, p1, p2, tolSqd: Self.curveTolerance * Self.curveTolerance, out: &out, left: maxV)
            flattened(out)
        }

        mutating func cubicTo(_ p0: GPoint, _ p1: GPoint, _ p2: GPoint, _ p3: GPoint) {
            let maxV = GaneshConvex.maxVertices(GaneshConvex.cubicLog2(precision: 1.0 / Self.curveTolerance, p0, p1, p2, p3))
            var out: [GPoint] = []
            GaneshConvex.cubicPoints(p0, p1, p2, p3, tolSqd: Self.curveTolerance * Self.curveTolerance, out: &out, left: maxV)
            flattened(out)
        }

        mutating func extract(_ path: [GEl], _ ctm: GTransform) -> [RingPt]? {
            @inline(__always) func map(_ p: GPoint) -> GPoint { ctm.transformPoint(p) }
            var start = GPoint.zero, cur = GPoint.zero, open = false
            for el in path {
                switch el {
                case .move(let p):
                    if open && cur != start { lineTo(start, .sharp) }
                    start = map(p); cur = start; open = false
                case .line(let p):
                    let q = map(p)
                    if q != cur { lineTo(q, .sharp) }
                    cur = q; open = true
                case .quad(let c, let p):
                    let c = map(c), q = map(p)
                    if !(c == cur && q == cur) { quadTo(cur, c, q) }
                    cur = q; open = true
                case .cubic(let c1, let c2, let p):
                    let mc1 = map(c1), mc2 = map(c2), q = map(p)
                    if !(mc1 == cur && mc2 == cur && q == cur) { cubicTo(cur, mc1, mc2, q) }
                    cur = q; open = true
                case .conic(let c, let p, let w):
                    let mc = map(c), q = map(p)
                    if !(mc == cur && q == cur) {
                        let quads = GaneshConvex.conicQuads(cur, mc, q, weight: w)
                        var last = cur
                        let pairCount = quads.count / 2
                        for i in 0..<pairCount {
                            let end = (i == pairCount - 1) ? q : quads[i * 2 + 1]
                            quadTo(last, quads[i * 2], end)
                            last = end
                        }
                    }
                    cur = q; open = true
                case .close:
                    if open && cur != start { lineTo(start, .sharp) }
                    cur = start; open = false
                }
            }
            if open && cur != start { lineTo(start, .sharp) }
            guard pts.count >= 2 else { return nil }
            if Self.duplicate(pts[pts.count - 1], pts[0]) { popLast() }
            accumError = 0
            while pts.count >= 3 {
                let n = pts.count
                if Self.colinearAndBIsMiddle(pts[n - 2], pts[n - 1], pts[0], accum: &accumError) {
                    popLast()
                } else if Self.colinearAndBIsMiddle(pts[n - 1], pts[0], pts[1], accum: &accumError) {
                    popFirstShuffle()
                } else {
                    break
                }
            }
            if pts.count >= 3 {
                computeNormals()
                computeBisectors()
            } else if pts.count == 2 {
                side = -1
                var n0 = (pts[1] - pts[0]).orthog(side)
                _ = n0.normalize()
                norms = [n0, -n0]
                bisectors = [.zero, .zero]
            } else {
                return nil
            }
            return (0..<pts.count).map { RingPt(norm: norms[$0], bisector: bisectors[$0], index: $0, origEdge: $0) }
        }

        mutating func computeNormals() {
            let n = pts.count
            let first = pts[1] - pts[0]
            let last = pts[0] - pts[n - 1]
            side = first.cross(last) > 0 ? 1 : -1
            let s = side
            @inline(__always) func norm(_ v: GPoint) -> GPoint { var o = v.orthog(s); _ = o.normalize(); return o }
            norms = (0..<n).map { i in
                if i == 0 { return norm(first) }
                if i == n - 1 { return norm(last) }
                return norm(pts[i + 1] - pts[i])
            }
        }

        mutating func computeBisectors() {
            let n = norms.count
            bisectors = [GPoint](repeating: .zero, count: n)
            var prev = n - 1
            for cur in 0..<n {
                var b = norms[cur] + norms[prev]
                if !b.normalize() {
                    b = norms[cur].orthog(-side) + norms[prev].orthog(side)
                    _ = b.normalize()
                } else {
                    b = -b
                }
                bisectors[cur] = b
                if curve[prev] == .indeterminate {
                    if curve[cur] == .sharp {
                        curve[prev] = .sharp
                    } else if abs(norms[cur].dot(norms[prev])) > Self.curveConnectionThreshold {
                        curve[prev] = .smooth
                        curve[cur] = .smooth
                    } else {
                        curve[prev] = .sharp
                        curve[cur] = .sharp
                    }
                }
                prev = cur
            }
        }

        func initRing(_ ring: inout [RingPt]) {
            let n = ring.count
            guard n > 0 else { return }
            for cur in 0..<n {
                let next = (cur + 1) % n
                var d = pts[ring[next].index] - pts[ring[cur].index]
                _ = d.normalize()
                ring[cur].norm = d.orthog(side)
            }
            var prev = n - 1
            for cur in 0..<n {
                var b = ring[cur].norm + ring[prev].norm
                if !b.normalize() {
                    b = ring[cur].norm.orthog(-side) + ring[prev].norm.orthog(side)
                    _ = b.normalize()
                } else {
                    b = -b
                }
                ring[cur].bisector = b
                prev = cur
            }
        }

        func depthFromEdge(_ edge: Int, _ p: GPoint) -> Float {
            -norms[edge].dot(p - pts[edge])
        }

        func ptAlongBisector(_ start: Int, _ bisector: GPoint, _ edge: Int, _ depth: Float) -> GPoint? {
            let norm = norms[edge]
            guard let t = Self.perpIntersect(pts[start], bisector, pts[edge], norm) else { return nil }
            let p: GPoint
            if GaneshConvex.nearlyEqual(t, 0) { p = pts[start] }
            else if t < 0 { p = bisector * t + pts[start] }
            else { return nil }
            let t2 = -depth / bisector.dot(norm)
            return bisector * t2 + p
        }

        mutating func outerRing(_ prevRing: [RingPt], outset: Float, coverage: Float, next: inout [RingPt]) {
            let n = prevRing.count
            if n == 0 { return }
            var prev = n - 1
            var lastPerp = Int.max, firstPerp = Int.max
            let outsetSq = outset * outset
            let miterSq = (outset * miterLimit) * (outset * miterLimit)
            for cur in 0..<n {
                let original = prevRing[cur].index
                let normal1 = prevRing[prev].norm
                let perp1 = normal1 * outset + pts[original]
                let normal2 = prevRing[cur].norm
                let perp2 = normal2 * outset + pts[original]
                let crv = curve[original]
                let perp1Idx = addPt(perp1, coverage, false, crv)
                next.append(RingPt(index: perp1Idx, origEdge: original))
                let perp2Idx = Self.duplicate(perp2, pts[perp1Idx]) ? perp1Idx : addPt(perp2, coverage, false, crv)
                if perp2Idx != perp1Idx {
                    if crv == .smooth {
                        if normal1.dot(normal2) < Self.roundCapThreshold {
                            var miter = prevRing[cur].bisector
                            _ = miter.setLength(-outset)
                            miter = miter + pts[original]
                            if !Self.duplicate(miter, pts[perp1Idx]) {
                                let m = addPt(miter, coverage, false, .sharp)
                                next.append(RingPt(index: m, origEdge: original))
                                addTri(original, perp1Idx, m)
                                addTri(original, m, perp2Idx)
                            }
                        } else {
                            addTri(original, perp1Idx, perp2Idx)
                        }
                    } else if join == .miter {
                        var miter = prevRing[cur].bisector
                        let sinHalfSq = max(Float(0), (1.0 + normal1.dot(normal2)) * 0.5)
                        let lengthSq = outsetSq / sinHalfSq
                        if lengthSq > miterSq {
                            addTri(original, perp1Idx, perp2Idx)
                        } else {
                            _ = miter.setLength(-lengthSq.squareRoot())
                            miter = miter + pts[original]
                            if !Self.duplicate(miter, pts[perp1Idx]) {
                                let m = addPt(miter, coverage, false, .sharp)
                                next.append(RingPt(index: m, origEdge: original))
                                addTri(original, perp1Idx, m)
                                addTri(original, m, perp2Idx)
                            } else {
                                addTri(original, perp1Idx, perp2Idx)
                            }
                        }
                    } else {
                        addTri(original, perp1Idx, perp2Idx)
                    }
                    next.append(RingPt(index: perp2Idx, origEdge: original))
                }
                if cur == 0 {
                    firstPerp = perp1Idx
                } else {
                    let prevIdx = prevRing[prev].index
                    addTri(prevIdx, perp1Idx, original)
                    addTri(prevIdx, lastPerp, perp1Idx)
                }
                lastPerp = perp2Idx
                prev = cur
            }
            let last = prevRing[n - 1].index
            addTri(last, firstPerp, prevRing[0].index)
            addTri(last, lastPerp, firstPerp)
        }

        mutating func insetRings(_ first: [RingPt], initialDepth: Float, initialCoverage: Float, targetDepth: Float, targetCoverage: Float) -> [RingPt]? {
            if first.count < 3 { return nil }
            var current = first
            var i = 0
            while i < 8 {
                var next: [RingPt] = []
                let done = insetRing(current, next: &next, initialDepth: initialDepth, initialCoverage: initialCoverage, targetDepth: targetDepth, targetCoverage: targetCoverage, forceNew: i == 0)
                current = next
                if done { break }
                initRing(&current)
                i += 1
            }
            if i == 8 || current.count < 3 { return nil }
            initRing(&current)
            return current
        }

        mutating func insetRing(_ last: [RingPt], next: inout [RingPt], initialDepth: Float, initialCoverage: Float, targetDepth: Float, targetCoverage: Float, forceNew: Bool) -> Bool {
            let n = last.count
            var minDist = Float.greatestFiniteMagnitude
            var minT: Float = 0
            var minEdge = Int.max
            for cur in 0..<n {
                let nx = (cur + 1) % n
                guard let t = Self.intersect(pts[last[cur].index], last[cur].bisector, pts[last[nx].index], last[nx].bisector), t > 0 else { continue }
                let dist = -t * last[cur].norm.dot(last[cur].bisector)
                if minDist > dist { minDist = dist; minT = t; minEdge = cur }
            }
            if minEdge == Int.max { return false }
            let newPt = last[minEdge].bisector * minT + pts[last[minEdge].index]
            var depth = depthFromEdge(last[minEdge].origEdge, newPt)
            var done = false
            if depth >= targetDepth { depth = targetDepth; done = true }

            var cands: [Candidate] = []
            cands.reserveCapacity(n)
            var dst = [Int](repeating: 0, count: n)
            @inline(__always) func along(_ i: Int) -> GPoint? { ptAlongBisector(last[i].index, last[i].bisector, last[i].origEdge, depth) }
            @inline(__always) func fresh(_ i: Int, _ pt: GPoint) -> Candidate {
                Candidate(pt: pt, originating: last[i].index, origEdge: last[i].origEdge, needsNew: !movable[last[i].index])
            }
            @inline(__always) func fusePrior(_ origEdge: Int) {
                let idx = cands.count - 1
                cands[idx].origEdge = origEdge
                cands[idx].originating = nil
                cands[idx].needsNew = true
            }

            guard let p0 = along(0) else { return true }
            cands.append(fresh(0, p0))
            dst[0] = 0
            for cur in 1..<(n - 1) {
                guard let p = along(cur) else { return true }
                if !Self.duplicate(p, cands[cands.count - 1].pt) { cands.append(fresh(cur, p)) }
                else { fusePrior(last[cur].origEdge) }
                dst[cur] = cands.count - 1
            }
            let cur = n - 1
            guard let pLast = along(cur) else { return true }
            let dupPrev = Self.duplicate(pLast, cands[cands.count - 1].pt)
            let dupNext = Self.duplicate(pLast, cands[0].pt)
            switch (dupPrev, dupNext) {
            case (false, false):
                cands.append(fresh(cur, pLast)); dst[cur] = cands.count - 1
            case (true, false):
                fusePrior(last[cur].origEdge); dst[cur] = cands.count - 1
            case (false, true):
                cands[0].originating = nil; cands[0].needsNew = true; dst[cur] = 0
            case (true, true):
                if !Self.duplicate(cands[0].pt, cands[cands.count - 1].pt) {
                    fusePrior(last[cur].origEdge); dst[cur] = cands.count - 1
                } else {
                    if cands.count > 1 { cands.removeLast() }
                    cands[0].originating = nil; cands[0].needsNew = true
                    let target = dst[cur - 1]
                    var i = cur - 1
                    while true {
                        if dst[i] != target { break }
                        dst[i] = 0
                        if i == 0 { break }
                        i -= 1
                    }
                    dst[cur] = 0
                }
            }
            for c in cands {
                let idx: Int
                if let o = c.originating, !(c.needsNew || forceNew) {
                    pts[o] = c.pt; coverage[o] = targetCoverage; idx = o
                } else {
                    let cov = Self.coverageAt(depth: depth, initialDepth: initialDepth, initialCoverage: initialCoverage, targetDepth: targetDepth, targetCoverage: targetCoverage)
                    idx = addPt(c.pt, cov, c.originating != nil, .sharp)
                }
                next.append(RingPt(index: idx, origEdge: c.origEdge))
            }
            for i in dst.indices { dst[i] = next[dst[i]].index }
            for i in 0..<n {
                let nx = (i + 1) % n
                addTri(last[i].index, last[nx].index, dst[nx])
                addTri(last[i].index, dst[nx], dst[i])
            }
            if next.count < 3 { done = true }
            return done
        }
    }

    static func stroke(path: [GEl], ctm: GTransform, width: Float, join: GLineJoin, miterLimit: Float) -> TessMesh? {
        let scale = max(
            (ctm.xx * ctm.xx + ctm.xy * ctm.xy).squareRoot(),
            (ctm.yx * ctm.yx + ctm.yy * ctm.yy).squareRoot()
        )
        var t = Tess(join: join, miterLimit: miterLimit)
        guard let initial = t.extract(path, ctm) else { return nil }
        let w = scale * width
        var outer: [RingPt] = []
        t.outerRing(initial, outset: w * 0.5 - Tess.aaRadius, coverage: 1.0, next: &outer)
        t.initRing(&outer)
        var outerAA: [RingPt] = []
        t.outerRing(outer, outset: Tess.aaRadius * 2.0, coverage: 0.0, next: &outerAA)
        t.bisectors.removeAll()
        if initial.count > 2 {
            let depth = w * 0.5 - Tess.aaRadius
            if let inset = t.insetRings(initial, initialDepth: 0, initialCoverage: 1.0, targetDepth: depth, targetCoverage: 1.0) {
                _ = t.insetRings(inset, initialDepth: depth, initialCoverage: 1.0, targetDepth: depth + Tess.aaRadius * 2.0, targetCoverage: 0.0)
            }
        }
        return TessMesh(pts: t.pts, coverage: t.coverage, indices: t.indices)
    }
}
