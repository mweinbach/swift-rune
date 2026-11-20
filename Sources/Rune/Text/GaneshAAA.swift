// Port of upstream `crates/rune/src/text/aaa/{mod.rs, edge.rs, blit.rs}`:
// Skia's 16.16 fixed-point analytic anti-aliasing scan converter.

import Foundation

internal enum GAAARule: Equatable, Sendable {
    case nonZero
    case evenOdd
}

private typealias Fixed = Int32
private typealias FDot6 = Int32

private let aaaOne: Fixed = 1 << 16
private let aaaMax: Int32 = Int32.max
private let aaaMin: Int32 = Int32.min
private let aaaAccuracy: Int32 = 2
private let aaaMaxCoeffShift: Int32 = 6

@inline(__always) private func fdot6ToFixed(_ x: FDot6) -> Fixed { x &<< 10 }
@inline(__always) private func fixedToFDot6(_ x: Fixed) -> FDot6 { x >> 10 }
@inline(__always) private func fdot6Round(_ x: FDot6) -> Int32 { (x &+ 32) >> 6 }
@inline(__always) private func fixedMul(_ a: Fixed, _ b: Fixed) -> Fixed { Int32(truncatingIfNeeded: (Int64(a) * Int64(b)) >> 16) }
@inline(__always) private func fixedDiv(_ a: Int32, _ b: Int32) -> Fixed {
    let v = (Int64(a) << 16) / Int64(b)
    return Int32(min(Int64(aaaMax), max(Int64(aaaMin), v)))
}
@inline(__always) private func fdot6Div(_ a: FDot6, _ b: FDot6) -> Fixed {
    Int32(Int16(truncatingIfNeeded: a)) == a ? ((a &<< 16) / b) : fixedDiv(a, b)
}
@inline(__always) private func ceilToInt(_ x: Fixed) -> Int32 { Int32(truncatingIfNeeded: (Int64(x) + 0xFFFF) >> 16) }
@inline(__always) private func floorToInt(_ x: Fixed) -> Int32 { x >> 16 }
@inline(__always) private func ceilToFixed(_ x: Fixed) -> Fixed { Int32(truncatingIfNeeded: Int64(x) + 0xFFFF) & ~0xFFFF }
@inline(__always) private func floorToFixed(_ x: Fixed) -> Fixed { x & ~0xFFFF }
@inline(__always) private func roundToFixed(_ x: Fixed) -> Fixed { (x &+ 0x8000) & ~0xFFFF }
@inline(__always) private func satAdd(_ a: Int32, _ b: Int32) -> Int32 {
    let s = Int64(a) + Int64(b)
    return Int32(min(Int64(aaaMax), max(Int64(aaaMin), s)))
}
@inline(__always) private func satSub(_ a: Int32, _ b: Int32) -> Int32 {
    let s = Int64(a) - Int64(b)
    return Int32(min(Int64(aaaMax), max(Int64(aaaMin), s)))
}
@inline(__always) private func clampToI32(_ x: Float) -> Int32 {
    if x.isNaN { return 0 }
    if x >= Float(Int32.max) { return Int32.max }
    if x <= Float(Int32.min) { return Int32.min }
    return Int32(x)
}
@inline(__always) private func toFDot6(_ x: Float, _ shift: Int32) -> FDot6 {
    clampToI32(x * Float(1 << (6 + shift)))
}
@inline(__always) private func snapY(_ y: Fixed) -> Fixed {
    let u = UInt32(bitPattern: y) &+ UInt32(bitPattern: aaaOne >> (aaaAccuracy + 1))
    let s = Int(16 - aaaAccuracy)
    return Int32(bitPattern: (u >> s) << s)
}
@inline(__always) private func quickInverse(_ x: FDot6) -> Fixed { x == 0 ? 0 : (1 << 22) / x }
@inline(__always) private func quickDiv(_ a: FDot6, _ b: FDot6) -> Fixed {
    let absA = a.magnitude, absB = b.magnitude
    if absB >= 8 && absB < 1024 && absA < (1 << 12) {
        return (a &* quickInverse(b)) >> 6
    }
    return fdot6Div(a, b)
}

private enum GEdgeKind { case line, quad, cubic }

private struct GEdge {
    var next: Int = 0
    var prev: Int = 0
    var x: Fixed = 0
    var dx: Fixed = 0
    var upperX: Fixed = 0
    var y: Fixed = 0
    var upperY: Fixed = 0
    var lowerY: Fixed = 0
    var dy: Fixed = 0
    var kind: GEdgeKind = .line
    var curveCount: Int32 = 0
    var curveShift: Int32 = 0
    var winding: Int32 = 1
    var qx: Fixed = 0
    var qy: Fixed = 0
    var qdx: Fixed = 0
    var qdy: Fixed = 0
    var qddx: Fixed = 0
    var qddy: Fixed = 0
    var qdddx: Fixed = 0
    var qdddy: Fixed = 0
    var lastX: Fixed = 0
    var lastY: Fixed = 0
    var snappedX: Fixed = 0
    var snappedY: Fixed = 0
    var toFixedShift: Int32 = 0

    static func sentinel(_ at: Int32) -> GEdge {
        var e = GEdge()
        e.x = at; e.upperX = at; e.upperY = at; e.lowerY = at; e.dy = aaaMax
        return e
    }

    mutating func setLine(_ p0: GPoint, _ p1: GPoint) -> Bool {
        @inline(__always) func fx(_ v: Float) -> Fixed { toFDot6(v, aaaAccuracy) &<< (10 - aaaAccuracy) }
        var x0 = fx(p0.x), y0 = snapY(fx(p0.y)), x1 = fx(p1.x), y1 = snapY(fx(p1.y))
        var winding: Int32 = 1
        if y0 > y1 {
            swap(&x0, &x1); swap(&y0, &y1); winding = -1
        }
        let dy = fixedToFDot6(y1 &- y0)
        if dy == 0 { return false }
        let dx = fixedToFDot6(x1 &- x0)
        let slope = quickDiv(dx, dy)
        let absSlope = Int32(truncatingIfNeeded: slope.magnitude)
        self.x = x0; self.dx = slope; self.upperX = x0
        self.y = y0; self.upperY = y0; self.lowerY = y1
        if dx == 0 || slope == 0 {
            self.dy = aaaMax
        } else if absSlope < 1024 {
            self.dy = quickInverse(absSlope)
        } else {
            self.dy = Int32(truncatingIfNeeded: quickDiv(dy, dx).magnitude)
        }
        self.kind = .line; self.curveCount = 0; self.winding = winding; self.curveShift = 0
        return true
    }

    mutating func updateLine(x0 inX0: Fixed, y0 inY0: Fixed, x1 inX1: Fixed, y1 inY1: Fixed, slope: Fixed) -> Bool {
        var x0 = inX0, y0 = inY0, x1 = inX1, y1 = inY1
        if y0 > y1 {
            swap(&x0, &x1); swap(&y0, &y1); winding = -winding
        }
        let dx = fixedToFDot6(x1 &- x0)
        let dy = fixedToFDot6(y1 &- y0)
        if dy == 0 { return false }
        let absSlope = Int32(truncatingIfNeeded: fixedToFDot6(slope).magnitude)
        self.x = x0; self.dx = slope; self.upperX = x0
        self.y = y0; self.upperY = y0; self.lowerY = y1
        if dx == 0 || slope == 0 {
            self.dy = aaaMax
        } else if absSlope < 1024 {
            self.dy = quickInverse(absSlope)
        } else {
            self.dy = Int32(truncatingIfNeeded: quickDiv(dy, dx).magnitude)
        }
        return true
    }

    mutating func setQuad(_ pts: ArraySlice<GPoint>) -> Bool {
        let base = pts.startIndex
        @inline(__always) func f(_ v: Float) -> FDot6 { toFDot6(v, aaaAccuracy) }
        var x0 = f(pts[base].x), y0 = f(pts[base].y)
        let x1 = f(pts[base + 1].x), y1 = f(pts[base + 1].y)
        var x2 = f(pts[base + 2].x), y2 = f(pts[base + 2].y)
        var winding: Int32 = 1
        if y0 > y2 {
            swap(&x0, &x2); swap(&y0, &y2); winding = -1
        }
        if fdot6Round(y0) == fdot6Round(y2) { return false }
        var shift = diffToShift(((x1 &<< 1) &- x0 &- x2) >> 2, ((y1 &<< 1) &- y0 &- y2) >> 2, aaaAccuracy)
        shift = shift == 0 ? 1 : min(shift, aaaMaxCoeffShift)
        self.winding = winding; self.kind = .quad
        self.curveCount = 1 << shift; self.curveShift = shift - 1
        @inline(__always) func div2(_ v: FDot6) -> Fixed { v &<< (16 - 6 - 1) }
        let ax = div2(x0 &- x1 &- x1 &+ x2), bx = fdot6ToFixed(x1 &- x0)
        qx = fdot6ToFixed(x0); qdx = bx &+ (ax >> shift); qddx = ax >> (shift - 1)
        let ay = div2(y0 &- y1 &- y1 &+ y2), by = fdot6ToFixed(y1 &- y0)
        qy = fdot6ToFixed(y0); qdy = by &+ (ay >> shift); qddy = ay >> (shift - 1)
        lastX = fdot6ToFixed(x2); lastY = fdot6ToFixed(y2)
        qx >>= aaaAccuracy; qy >>= aaaAccuracy
        qdx >>= aaaAccuracy; qdy >>= aaaAccuracy
        qddx >>= aaaAccuracy; qddy >>= aaaAccuracy
        lastX >>= aaaAccuracy; lastY >>= aaaAccuracy
        qy = snapY(qy); lastY = snapY(lastY)
        snappedX = qx; snappedY = qy
        return updateQuad()
    }

    mutating func updateQuad() -> Bool {
        var success = false
        var count = curveCount
        var oldx = qx, oldy = qy
        var dx = qdx, dy = qdy
        var newx: Fixed = 0, newy: Fixed = 0, newSX: Fixed = 0, newSY: Fixed = 0
        let shift = curveShift
        repeat {
            let slope: Fixed
            count -= 1
            if count > 0 {
                newx = oldx &+ (dx >> shift)
                newy = oldy &+ (dy >> shift)
                if Int64((dy >> shift).magnitude) >= Int64(aaaOne * 2) && (Int64(dy.magnitude) << 6) > Int64(dx.magnitude) {
                    let diffY = fixedToFDot6(newy &- snappedY)
                    slope = diffY != 0 ? quickDiv(fixedToFDot6(newx &- snappedX), diffY) : aaaMax
                    newSY = min(lastY, roundToFixed(newy))
                    newSX = newx &- fixedMul(slope, newy &- newSY)
                } else {
                    newSY = min(lastY, snapY(newy))
                    newSX = newx
                    let diffY = fixedToFDot6(newSY &- snappedY)
                    slope = diffY != 0 ? quickDiv(fixedToFDot6(newx &- snappedX), diffY) : aaaMax
                }
                dx &+= qddx
                dy &+= qddy
            } else {
                newx = lastX; newy = lastY
                newSY = newy; newSX = newx
                let diffY = fixedToFDot6(newy &- snappedY)
                slope = diffY != 0 ? quickDiv(fixedToFDot6(newx &- snappedX), diffY) : aaaMax
            }
            if slope < aaaMax {
                success = updateLine(x0: snappedX, y0: snappedY, x1: newSX, y1: newSY, slope: slope)
            }
            oldx = newx; oldy = newy
        } while count > 0 && !success
        qx = newx; qy = newy; qdx = dx; qdy = dy
        snappedX = newSX; snappedY = newSY; curveCount = count
        return success
    }

    mutating func setCubic(_ pts: ArraySlice<GPoint>) -> Bool {
        let base = pts.startIndex
        @inline(__always) func f(_ v: Float) -> FDot6 { toFDot6(v, aaaAccuracy) }
        var x0 = f(pts[base].x), y0 = f(pts[base].y)
        var x1 = f(pts[base + 1].x), y1 = f(pts[base + 1].y)
        var x2 = f(pts[base + 2].x), y2 = f(pts[base + 2].y)
        var x3 = f(pts[base + 3].x), y3 = f(pts[base + 3].y)
        var winding: Int32 = 1
        if y0 > y3 {
            swap(&x0, &x3); swap(&x1, &x2); swap(&y0, &y3); swap(&y1, &y2); winding = -1
        }
        if fdot6Round(y0) == fdot6Round(y3) { return false }
        func delta(_ a: Int32, _ b: Int32, _ c: Int32, _ d: Int32) -> Int32 {
            let one = ((a &* 8 &- b &* 15 &+ 6 &* c &+ d) &* 19) >> 9
            let two = ((a &+ 6 &* b &- c &* 15 &+ d &* 8) &* 19) >> 9
            return max(Int32(truncatingIfNeeded: one.magnitude), Int32(truncatingIfNeeded: two.magnitude))
        }
        let shift = min(diffToShift(delta(x0, x1, x2, x3), delta(y0, y1, y2, y3), 2) + 1, aaaMaxCoeffShift)
        var up: Int32 = 6, down: Int32 = shift + 6 - 10
        if down < 0 { down = 0; up = 10 - shift }
        self.winding = winding; self.kind = .cubic
        self.curveCount = (-1) &<< shift; self.curveShift = shift; self.toFixedShift = down
        func coeffs(_ p0: Int32, _ p1: Int32, _ p2: Int32, _ p3: Int32) -> (Fixed, Fixed, Fixed, Fixed, Fixed) {
            let b = (3 &* (p1 &- p0)) &<< up
            let c = (3 &* (p0 &- p1 &- p1 &+ p2)) &<< up
            let d = (p3 &+ 3 &* (p1 &- p2) &- p0) &<< up
            let first = b &+ (c >> shift) &+ (d >> (2 * shift))
            let second = Int32(truncatingIfNeeded: 2 * Int64(c) + ((3 * Int64(d)) >> (shift - 1)))
            let third = Int32(truncatingIfNeeded: (3 * Int64(d)) >> (shift - 1))
            return (fdot6ToFixed(p0), first, second, third, fdot6ToFixed(p3))
        }
        (qx, qdx, qddx, qdddx, lastX) = coeffs(x0, x1, x2, x3)
        (qy, qdy, qddy, qdddy, lastY) = coeffs(y0, y1, y2, y3)
        qx >>= aaaAccuracy; qy >>= aaaAccuracy
        qdx >>= aaaAccuracy; qdy >>= aaaAccuracy
        qddx >>= aaaAccuracy; qddy >>= aaaAccuracy
        qdddx >>= aaaAccuracy; qdddy >>= aaaAccuracy
        lastX >>= aaaAccuracy; lastY >>= aaaAccuracy
        qy = snapY(qy); snappedY = qy; lastY = snapY(lastY)
        return updateCubic()
    }

    mutating func updateCubic() -> Bool {
        var success = false
        var count = curveCount
        var oldx = qx, oldy = qy
        var newx: Fixed = 0, newy: Fixed = 0
        let ddshift = curveShift, dshift = toFixedShift
        repeat {
            count += 1
            if count < 0 {
                newx = oldx &+ (qdx >> dshift)
                qdx = qdx &+ (qddx >> ddshift)
                qddx = qddx &+ qdddx
                newy = oldy &+ (qdy >> dshift)
                qdy = qdy &+ (qddy >> ddshift)
                qddy = qddy &+ qdddy
            } else {
                newx = lastX; newy = lastY
            }
            if newy < oldy { newy = oldy }
            var newSY = snapY(newy)
            if lastY < newSY {
                newSY = lastY
                count = 0
            }
            let diffY = fixedToFDot6(newSY &- snappedY)
            let slope = diffY == 0 ? aaaMax : fdot6Div(fixedToFDot6(newx &- oldx), diffY)
            success = updateLine(x0: oldx, y0: snappedY, x1: newx, y1: newSY, slope: slope)
            oldx = newx; oldy = newy; snappedY = newSY
        } while count < 0 && !success
        qx = newx; qy = newy; curveCount = count
        return success
    }

    mutating func update() -> Bool {
        if curveCount < 0 { return updateCubic() }
        if curveCount > 0 { return updateQuad() }
        return false
    }

    mutating func keepContinuous() {
        if curveCount < 0 {
            qx = x; snappedY = y
        } else {
            snappedX = x; snappedY = y
        }
    }

    mutating func goY(_ y: Fixed) {
        if y == self.y &+ aaaOne {
            self.x = satAdd(self.x, self.dx)
            self.y = y
        } else if y != self.y {
            let v = Int64(upperX) + ((Int64(dx) * (Int64(y) - Int64(upperY))) >> 16)
            self.x = Int32(min(Int64(aaaMax), max(Int64(aaaMin), v)))
            self.y = y
        }
    }

    mutating func goYShift(_ y: Fixed, _ shift: Int32) {
        self.y = y
        self.x = satAdd(self.x, self.dx >> shift)
    }
}

private func diffToShift(_ dx: FDot6, _ dy: FDot6, _ shiftAA: Int32) -> Int32 {
    let adx = abs(dx), ady = abs(dy)
    let dist = adx > ady ? (adx + (ady >> 1)) : (ady + (adx >> 1))
    let d2 = (dist + (1 << (2 + shiftAA))) >> (3 + shiftAA)
    return Int32(32 - UInt32(bitPattern: d2).leadingZeroBitCount) >> 1
}

private enum GCombine { case no, partial, total }

private func combineVertical(_ edge: GEdge, _ last: inout GEdge) -> GCombine {
    @inline(__always) func close(_ a: Fixed, _ b: Fixed) -> Bool { abs(a - b) < 0x100 }
    if last.kind != .line || last.dx != 0 || edge.x != last.x { return .no }
    if edge.winding == last.winding {
        if edge.lowerY == last.upperY {
            last.upperY = edge.upperY; last.y = last.upperY; return .partial
        }
        if close(edge.upperY, last.lowerY) {
            last.lowerY = edge.lowerY; return .partial
        }
        return .no
    }
    if close(edge.upperY, last.upperY) {
        if close(edge.lowerY, last.lowerY) { return .total }
        if edge.lowerY < last.lowerY {
            last.upperY = edge.lowerY; last.y = last.upperY; return .partial
        }
        last.upperY = last.lowerY; last.y = last.upperY
        last.lowerY = edge.lowerY; last.winding = edge.winding
        return .partial
    }
    if close(edge.lowerY, last.lowerY) {
        if edge.upperY > last.upperY {
            last.lowerY = edge.upperY; return .partial
        }
        last.lowerY = last.upperY; last.upperY = edge.upperY
        last.y = last.upperY; last.winding = edge.winding
        return .partial
    }
    return .no
}

private func chopQuadAtYEtrema(_ src: [GPoint], _ dst: inout [GPoint]) -> Int {
    let a = src[0].y
    var b = src[1].y
    let c = src[2].y
    let ab = a - b
    var bc = b - c
    if ab < 0 { bc = -bc }
    if ab == 0 || bc < 0 {
        if let t = GPathGeometry.validUnitDivide(a - b, a - b - b + c) {
            let chopped = GPathGeometry.chopQuadAt(src, 0, t: t)
            dst[0] = chopped.0; dst[1] = chopped.1; dst[2] = chopped.2; dst[3] = chopped.3; dst[4] = chopped.4
            dst[1].y = dst[2].y
            dst[3].y = dst[2].y
            return 1
        }
        b = abs(a - b) < abs(b - c) ? a : c
    }
    dst[0] = GPoint(x: src[0].x, y: a)
    dst[1] = GPoint(x: src[1].x, y: b)
    dst[2] = GPoint(x: src[2].x, y: c)
    return 0
}

private func chopCubicAtYEtrema(_ src: (GPoint, GPoint, GPoint, GPoint), _ dst: inout [GPoint]) -> Int {
    var ts = [Float](repeating: 0, count: 3)
    let roots = GPathGeometry.findUnitQuadRoots(
        a: src.3.y - src.0.y + 3.0 * (src.1.y - src.2.y),
        b: 2.0 * (src.0.y - src.1.y - src.1.y + src.2.y),
        c: src.1.y - src.0.y,
        roots: &ts
    )
    if roots == 0 {
        dst[0] = src.0; dst[1] = src.1; dst[2] = src.2; dst[3] = src.3
        return 0
    }
    var t = ts[0]
    var tmp = src
    var off = 0
    for i in 0..<roots {
        let ch = GPathGeometry.chopCubicAt2(tmp, t: t)
        dst[off] = ch.0; dst[off + 1] = ch.1; dst[off + 2] = ch.2; dst[off + 3] = ch.3
        dst[off + 4] = ch.4; dst[off + 5] = ch.5; dst[off + 6] = ch.6
        if i == roots - 1 { break }
        off += 3
        tmp = (dst[off], dst[off + 1], dst[off + 2], dst[off + 3])
        if let nextT = GPathGeometry.validUnitDivide(ts[i + 1] - ts[i], 1.0 - ts[i]) {
            t = nextT
        } else {
            dst[off + 4] = tmp.3; dst[off + 5] = tmp.3; dst[off + 6] = tmp.3
            break
        }
    }
    dst[2].y = dst[3].y
    dst[4].y = dst[3].y
    if roots == 2 {
        dst[5].y = dst[6].y
        dst[7].y = dst[6].y
    }
    return roots
}

private func buildEdges(_ path: GPath) -> [GEdge] {
    var list = [GEdge.sentinel(aaaMin), GEdge.sentinel(aaaMax)]
    func addLine(_ a: GPoint, _ b: GPoint) {
        var e = GEdge()
        guard e.setLine(a, b) else { return }
        if e.dx == 0 && e.kind == .line && list.count > 2 {
            let lastIdx = list.count - 1
            switch combineVertical(e, &list[lastIdx]) {
            case .total: list.removeLast()
            case .partial: break
            case .no: list.append(e)
            }
        } else {
            list.append(e)
        }
    }
    var quadMono = [GPoint](repeating: .zero, count: 5)
    func addQuad(_ p0: GPoint, _ p1: GPoint, _ p2: GPoint) {
        let n = chopQuadAtYEtrema([p0, p1, p2], &quadMono)
        for i in 0...n {
            var e = GEdge()
            if e.setQuad(quadMono[(i * 2)..<(i * 2 + 3)]) { list.append(e) }
        }
    }
    var cubicMono = [GPoint](repeating: .zero, count: 10)
    func addCubic(_ p0: GPoint, _ p1: GPoint, _ p2: GPoint, _ p3: GPoint) {
        let n = chopCubicAtYEtrema((p0, p1, p2, p3), &cubicMono)
        for i in 0...n {
            var e = GEdge()
            if e.setCubic(cubicMono[(i * 3)..<(i * 3 + 4)]) { list.append(e) }
        }
    }
    let pts = path.points
    var i = 0, weight = 0, start = GPoint.zero, last = GPoint.zero, open = false
    for verb in path.verbs {
        switch verb {
        case .move:
            if open { addLine(last, start) }
            start = pts[i]; last = start; i += 1; open = false
        case .line:
            addLine(last, pts[i]); last = pts[i]; i += 1; open = true
        case .quad:
            addQuad(last, pts[i], pts[i + 1]); last = pts[i + 1]; i += 2; open = true
        case .cubic:
            addCubic(last, pts[i], pts[i + 1], pts[i + 2]); last = pts[i + 2]; i += 3; open = true
        case .conic:
            let w = path.weights[weight]; weight += 1
            if let q = GAutoConicToQuads.compute(last, pts[i], pts[i + 1], weight: w, tolerance: 0.25) {
                for k in 0..<Int(q.len) {
                    addQuad(q.points[2 * k], q.points[2 * k + 1], q.points[2 * k + 2])
                }
            }
            last = pts[i + 1]; i += 2; open = true
        case .close:
            if open { addLine(last, start) }
            last = start; open = false
        }
    }
    if open { addLine(last, start) }
    return list
}

// MARK: - AAA Mask & Blitter (`aaa/blit.rs`)

private final class AAAMask {
    let w: Int
    let left: Int32
    let top: Int32
    var data: [UInt8]

    init(w: Int, left: Int32, top: Int32, count: Int) {
        self.w = w
        self.left = left
        self.top = top
        self.data = [UInt8](repeating: 0, count: count)
    }

    @inline(__always)
    func index(y: Int32, x: Int32) -> Int? {
        let i = 1 + Int64(y - top) * Int64(w) + Int64(x - left)
        if i >= 0 && i < Int64(data.count) { return Int(i) }
        return nil
    }
}

@inline(__always) private func getPartialAlphaFixed(_ alpha: UInt8, _ partial: Fixed) -> UInt8 {
    UInt8(truncatingIfNeeded: (Int32(alpha) * partial + 0x8000) >> 16)
}
@inline(__always) private func getPartialAlpha(_ alpha: UInt8, _ full: UInt8) -> UInt8 {
    UInt8(truncatingIfNeeded: (Int32(alpha) * Int32(full)) >> 8)
}
@inline(__always) private func fixedToAlpha(_ f: Fixed) -> UInt8 { getPartialAlphaFixed(0xFF, f) }
@inline(__always) private func trapezoidToAlpha(_ l1: Fixed, _ l2: Fixed) -> UInt8 { UInt8(truncatingIfNeeded: ((l1 + l2) / 2) >> 8) }
@inline(__always) private func partialTriangleToAlpha(_ a: Fixed, _ b: Fixed) -> UInt8 {
    let area = (a >> 11) &* (a >> 11) &* (b >> 11)
    return UInt8((area >> 8) & 0xFF)
}
@inline(__always) private func safelyAdd(_ mask: AAAMask, _ y: Int32, _ x: Int32, _ delta: UInt8) {
    if let idx = mask.index(y: y, x: x) {
        mask.data[idx] = UInt8(min(255, Int(mask.data[idx]) + Int(delta)))
    }
}
@inline(__always) private func blitSingleAlpha(_ mask: AAAMask, _ y: Int32, _ x: Int32, _ alpha: UInt8, _ full: UInt8, _ noReal: Bool) {
    if full == 0xFF && !noReal {
        if let idx = mask.index(y: y, x: x) { mask.data[idx] = alpha }
    } else {
        safelyAdd(mask, y, x, getPartialAlpha(alpha, full))
    }
}
@inline(__always) private func blitTwoAlphas(_ mask: AAAMask, _ y: Int32, _ x: Int32, _ a1: UInt8, _ a2: UInt8) {
    safelyAdd(mask, y, x, a1)
    safelyAdd(mask, y, x + 1, a2)
}
@inline(__always) private func blitFullAlpha(_ mask: AAAMask, _ y: Int32, _ x: Int32, _ len: Int32, _ full: UInt8) {
    for i in 0..<len { safelyAdd(mask, y, x + i, full) }
}

private func computeAlphaAboveLine(_ alphas: inout [UInt8], _ base: Int, _ l: Fixed, _ r: Fixed, _ dy: Fixed, _ full: UInt8) {
    let rr = ceilToInt(r)
    if rr == 0 { return }
    if rr == 1 {
        alphas[base] = getPartialAlpha(UInt8(((((rr << 17) - l - r) >> 9) & 0xFF)), full)
        return
    }
    let first = aaaOne - l
    let last = r - ((rr - 1) << 16)
    let firstH = fixedMul(first, dy)
    alphas[base] = UInt8(truncatingIfNeeded: fixedMul(first, firstH) >> 9)
    var alpha16 = satAdd(firstH, dy >> 1)
    for k in 1..<Int(rr - 1) {
        alphas[base + k] = UInt8(truncatingIfNeeded: alpha16 >> 8)
        alpha16 = satAdd(alpha16, dy)
    }
    alphas[base + Int(rr - 1)] = full &- partialTriangleToAlpha(last, dy)
}

private func computeAlphaBelowLine(_ alphas: inout [UInt8], _ base: Int, _ l: Fixed, _ r: Fixed, _ dy: Fixed, _ full: UInt8) {
    let rr = ceilToInt(r)
    if rr == 0 { return }
    if rr == 1 {
        alphas[base] = getPartialAlpha(trapezoidToAlpha(l, r), full)
        return
    }
    let first = aaaOne - l
    let last = r - ((rr - 1) << 16)
    let lastH = fixedMul(last, dy)
    alphas[base + Int(rr - 1)] = UInt8(truncatingIfNeeded: fixedMul(last, lastH) >> 9)
    var alpha16 = satAdd(lastH, dy >> 1)
    if rr > 2 {
        for i in stride(from: Int(rr - 2), through: 1, by: -1) {
            alphas[base + i] = UInt8((alpha16 >> 8) & 0xFF)
            alpha16 = satAdd(alpha16, dy)
        }
    }
    alphas[base] = full &- partialTriangleToAlpha(first, dy)
}

private func blitAAATrapezoidRow(_ mask: AAAMask, _ y: Int32, _ ul: Fixed, _ ur: Fixed, _ ll: Fixed, _ lr: Fixed, _ lDy: Fixed, _ rDy: Fixed, _ full: UInt8, _ noReal: Bool) {
    let l = floorToInt(ul), r = ceilToInt(lr)
    let len = r - l
    if len == 1 {
        blitSingleAlpha(mask, y, l, trapezoidToAlpha(ur - ul, lr - ll), full, noReal)
        return
    }
    if len <= 0 { return }
    let n = Int(len)
    var alphas = [UInt8](repeating: full, count: n + 1)
    var temp = [UInt8](repeating: 0, count: n + 1)
    let uL = floorToInt(ul), lL = ceilToInt(ll)
    if uL + 2 == lL {
        let first = (uL << 16) + aaaOne - ul
        let second = ll - ul - first
        let a1 = full &- partialTriangleToAlpha(first, lDy)
        let a2 = partialTriangleToAlpha(second, lDy)
        alphas[0] = alphas[0] > a1 ? alphas[0] - a1 : 0
        alphas[1] = alphas[1] > a2 ? alphas[1] - a2 : 0
    } else {
        let off = Int(uL - l)
        computeAlphaBelowLine(&temp, off, ul - (uL << 16), ll - (uL << 16), lDy, full)
        for i in uL..<lL {
            let k = Int(i - l)
            alphas[k] = alphas[k] > temp[k] ? alphas[k] - temp[k] : 0
        }
    }
    let uR = floorToInt(ur), lR = ceilToInt(lr)
    if uR + 2 == lR {
        let first = (uR << 16) + aaaOne - ur
        let second = lr - ur - first
        let a1 = partialTriangleToAlpha(first, rDy)
        let a2 = full &- partialTriangleToAlpha(second, rDy)
        alphas[n - 2] = alphas[n - 2] > a1 ? alphas[n - 2] - a1 : 0
        alphas[n - 1] = alphas[n - 1] > a2 ? alphas[n - 1] - a2 : 0
    } else {
        let off = Int(uR - l)
        for i in temp.indices { temp[i] = 0 }
        computeAlphaAboveLine(&temp, off, ur - (uR << 16), lr - (uR << 16), rDy, full)
        for i in uR..<lR {
            let k = Int(i - l)
            alphas[k] = alphas[k] > temp[k] ? alphas[k] - temp[k] : 0
        }
    }
    for i in 0..<n {
        safelyAdd(mask, y, l + Int32(i), alphas[i])
    }
}

private func blitTrapezoidRow(_ mask: AAAMask, _ y: Int32, ul inUL: Fixed, ur inUR: Fixed, ll inLL: Fixed, lr inLR: Fixed, _ lDy: Fixed, _ rDy: Fixed, _ full: UInt8, _ noReal: Bool) {
    var ul = inUL, ur = inUR, ll = inLL, lr = inLR
    if ul > ur { return }
    if ll > lr {
        let a = min(ul, ll), b = max(ul, ll), c = min(ur, lr), d = max(ur, lr)
        let x = Int32((Int64(max(a, c)) + Int64(min(b, d))) / 2)
        ll = x; lr = x
    }
    if ul == ur && ll == lr { return }
    if ul > ll { swap(&ul, &ll) }
    if ur > lr { swap(&ur, &lr) }
    let joinLeft = ceilToFixed(ll)
    let joinRite = floorToFixed(ur)
    if joinLeft <= joinRite {
        if ul < joinLeft {
            let len = ceilToInt(joinLeft - ul)
            if len == 1 {
                blitSingleAlpha(mask, y, ul >> 16, trapezoidToAlpha(joinLeft - ul, joinLeft - ll), full, noReal)
            } else if len == 2 {
                let first = joinLeft - aaaOne - ul
                let second = ll - ul - first
                blitTwoAlphas(mask, y, ul >> 16, partialTriangleToAlpha(first, lDy), full &- partialTriangleToAlpha(second, lDy))
            } else {
                blitAAATrapezoidRow(mask, y, ul, joinLeft, ll, joinLeft, lDy, aaaMax, full, noReal)
            }
        }
        if joinLeft < joinRite {
            blitFullAlpha(mask, y, floorToInt(joinLeft), floorToInt(joinRite - joinLeft), full)
        }
        if lr > joinRite {
            let len = ceilToInt(lr - joinRite)
            if len == 1 {
                blitSingleAlpha(mask, y, joinRite >> 16, trapezoidToAlpha(ur - joinRite, lr - joinRite), full, noReal)
            } else if len == 2 {
                let first = joinRite + aaaOne - ur
                let second = lr - ur - first
                blitTwoAlphas(mask, y, joinRite >> 16, full &- partialTriangleToAlpha(first, rDy), partialTriangleToAlpha(second, rDy))
            } else {
                blitAAATrapezoidRow(mask, y, joinRite, ur, joinRite, lr, aaaMax, rDy, full, noReal)
            }
        }
    } else {
        blitAAATrapezoidRow(mask, y, ul, ur, ll, lr, lDy, rDy, full, noReal)
    }
}

// MARK: - AAA Edge Walking (`aaa.rs`)

internal enum GaneshAAA {
    private static let noneIndex = -1

    static func fillClipped(path: GPath, rule: GAAARule, width: Int, height: Int, out: inout [UInt8]) {
        let bounds = path.bounds
        guard width > 0, height > 0, bounds.right > 0, bounds.bottom > 0,
              bounds.left < Float(width), bounds.top < Float(height) else {
            for i in out.indices { out[i] = 0 }
            return
        }
        if bounds.left >= 0, bounds.top >= 0, bounds.right <= Float(width), bounds.bottom <= Float(height),
           max(bounds.right, bounds.bottom) < 2048 {
            fill(path: path, rule: rule, width: width, height: height, out: &out)
            return
        }
        // The fixed-point edge builder allocates the path's device-space bounds.
        // Intersect outlying contours with the bitmap before passing them to it.
        let clipped = clippedOutline(path, width: width, height: height)
        if let clipped {
            fill(path: clipped, rule: rule, width: width, height: height, out: &out)
        } else {
            for i in out.indices { out[i] = 0 }
        }
    }

    private static func clippedOutline(_ path: GPath, width: Int, height: Int) -> GPath? {
        var lines = VectorPath()
        var iter = path.makeSegmentsIterator()
        var last = GPoint.zero
        while let segment = iter.next() {
            switch segment {
            case .moveTo(let p): lines.moveTo(p.x, p.y)
            case .lineTo(let p): lines.lineTo(p.x, p.y)
            case .quadTo(let c, let p): lines.quadTo(cx: c.x, cy: c.y, x: p.x, y: p.y)
            case .cubicTo(let a, let b, let p): lines.cubicTo(c1x: a.x, c1y: a.y, c2x: b.x, c2y: b.y, x: p.x, y: p.y)
            case .conicTo(let c, let p, let weight):
                if let quads = GAutoConicToQuads.compute(last, c, p, weight: weight, tolerance: 0.125) {
                    for i in 0..<Int(quads.len) {
                        let a = quads.points[2 * i + 1], b = quads.points[2 * i + 2]
                        lines.quadTo(cx: a.x, cy: a.y, x: b.x, y: b.y)
                    }
                } else {
                    lines.lineTo(p.x, p.y)
                }
            case .close: lines.close()
            }
            last = iter.lastPoint
        }
        var builder = GPathBuilder()
        for contour in lines.flatten(tolerance: 0.125) {
            var polygon = contour.points.map { SIMD2(Double($0.x), Double($0.y)) }
            for (axis, boundary, lower) in [(0, 0.0, true), (0, Double(width), false),
                                            (1, 0.0, true), (1, Double(height), false)] {
                guard var previous = polygon.last else { break }
                var clipped = [SIMD2<Double>]()
                for point in polygon {
                    let previousInside = lower ? previous[axis] >= boundary : previous[axis] <= boundary
                    let inside = lower ? point[axis] >= boundary : point[axis] <= boundary
                    if inside != previousInside {
                        // Keep the intersection calculation in Double for large SVG coordinates.
                        let other = 1 - axis
                        let a = previous[axis], b = point[axis]
                        let c = previous[other], d = point[other]
                        var hit = point
                        hit[axis] = boundary
                        hit[other] = ((b * c - a * d) + (d - c) * boundary) / (b - a)
                        clipped.append(hit)
                    }
                    if inside { clipped.append(point) }
                    previous = point
                }
                polygon = clipped
            }
            guard polygon.count >= 3, let first = polygon.first else { continue }
            builder.moveTo(Float(first.x), Float(first.y))
            for point in polygon.dropFirst() { builder.lineTo(Float(point.x), Float(point.y)) }
            builder.close()
        }
        return builder.finish()
    }

    static func fill(path: GPath, rule: GAAARule, width w: Int, height h: Int, out: inout [UInt8]) {
        for i in out.indices { out[i] = 0 }
        let b = path.bounds
        let ir = (clampToI32(floorf(b.left)), clampToI32(floorf(b.top)), clampToI32(ceilf(b.right)), clampToI32(ceilf(b.bottom)))
        let clip = (max(ir.0, 0), max(ir.1, 0), min(ir.2, Int32(w)), min(ir.3, Int32(h)))
        guard clip.2 > clip.0 && clip.3 > clip.1 else { return }
        var edges = buildEdges(path)
        guard edges.count > 2 else { return }
        let cw = clip.2 - clip.0, ch = clip.3 - clip.1
        let masked = cw <= 32 && ((cw + 3) & ~3) * ch <= 1024
        let iw = Int64(ir.2) - Int64(ir.0), ih = Int64(ir.3) - Int64(ir.1)
        if iw <= 0 || ih <= 0 || iw > 2048 || ih > 2048 || iw * ih > 1024 * 1024 {
            return
        }
        let mask = AAAMask(w: Int(iw), left: ir.0, top: ir.1, count: Int(iw * ih) + 2)
        sortAndLink(&edges)
        let skipIntersect = path.points.count > Int(ch * 2)
        walkEdges(&edges, rule: rule, mask: mask, startY: ir.1, stopY: ir.3, leftClip: ir.0 << 16, rightClip: ir.2 << 16, skipIntersect: skipIntersect)
        for y in clip.1..<clip.3 {
            for x in clip.0..<clip.2 {
                let a = mask.data[1 + Int(y - ir.1) * Int(iw) + Int(x - ir.0)]
                out[Int(y) * w + Int(x)] = masked ? a : snapAlpha(a)
            }
        }
    }

    @inline(__always)
    private static func snapAlpha(_ a: UInt8) -> UInt8 {
        a > 247 ? 255 : (a < 8 ? 0 : a)
    }

    private static func sortAndLink(_ edges: inout [GEdge]) {
        var order = Array(2..<edges.count)
        order.sort { a, b in
            let ea = edges[a], eb = edges[b]
            if ea.upperY != eb.upperY { return ea.upperY < eb.upperY }
            if ea.x != eb.x { return ea.x < eb.x }
            return ea.dx < eb.dx
        }
        var prev = 0
        for i in order {
            edges[prev].next = i
            edges[i].prev = prev
            prev = i
        }
        edges[prev].next = 1
        edges[1].prev = prev
        edges[0].prev = noneIndex
        edges[1].next = noneIndex
    }

    @inline(__always) private static func removeEdge(_ e: inout [GEdge], _ i: Int) {
        let p = e[i].prev, n = e[i].next
        e[p].next = n
        e[n].prev = p
    }
    @inline(__always) private static func insertEdgeAfter(_ e: inout [GEdge], _ i: Int, after: Int) {
        let n = e[after].next
        e[i].prev = after
        e[i].next = n
        e[n].prev = i
        e[after].next = i
    }
    @inline(__always) private static func hasPrev(_ e: [GEdge], _ i: Int) -> Bool { e[i].prev != noneIndex }

    private static func backwardInsertEdgeBasedOnX(_ e: inout [GEdge], _ i: Int) {
        let x = e[i].x
        var prev = e[i].prev
        while hasPrev(e, prev) && e[prev].x > x { prev = e[prev].prev }
        if e[prev].next != i {
            removeEdge(&e, i)
            insertEdgeAfter(&e, i, after: prev)
        }
    }

    private static func backwardInsertStart(_ e: [GEdge], _ prevIn: Int, _ x: Fixed) -> Int {
        var prev = prevIn
        while hasPrev(e, prev) && e[prev].x > x { prev = e[prev].prev }
        return prev
    }

    @inline(__always) private static func updateNextNextY(_ y: Fixed, _ nextY: Fixed, _ nn: inout Fixed) {
        if y > nextY && y < nn { nn = y }
    }
    @inline(__always) private static func checkIntersection(_ e: [GEdge], _ i: Int, _ nextY: Fixed, _ nn: inout Fixed) {
        let p = e[i].prev
        if hasPrev(e, p) && (e[p].x &+ e[p].dx) > (e[i].x &+ e[i].dx) {
            nn = nextY + (aaaOne >> aaaAccuracy)
        }
    }
    @inline(__always) private static func checkIntersectionFwd(_ e: [GEdge], _ i: Int, _ nextY: Fixed, _ nn: inout Fixed) {
        let n = e[i].next
        if n != noneIndex && e[n].next != noneIndex && (e[i].x &+ e[i].dx) > (e[n].x &+ e[n].dx) {
            nn = nextY + (aaaOne >> aaaAccuracy)
        }
    }

    private static func insertNewEdges(_ e: inout [GEdge], _ newIn: Int, _ y: Fixed, _ nn: inout Fixed) {
        var new = newIn
        if e[new].upperY > y {
            updateNextNextY(e[new].upperY, y, &nn)
            return
        }
        let prev = e[new].prev
        if e[prev].x <= e[new].x {
            while e[new].upperY <= y {
                checkIntersection(e, new, y, &nn)
                updateNextNextY(e[new].lowerY, y, &nn)
                new = e[new].next
            }
            updateNextNextY(e[new].upperY, y, &nn)
            return
        }
        var start = backwardInsertStart(e, prev, e[new].x)
        while true {
            let next = e[new].next
            var placed = false
            while true {
                if e[start].next == new {
                    placed = true
                    break
                }
                let after = e[start].next
                if e[after].x >= e[new].x { break }
                start = after
            }
            if !placed {
                removeEdge(&e, new)
                insertEdgeAfter(&e, new, after: start)
            }
            checkIntersection(e, new, y, &nn)
            checkIntersectionFwd(e, new, y, &nn)
            updateNextNextY(e[new].lowerY, y, &nn)
            start = new
            new = next
            if e[new].upperY > y { break }
        }
        updateNextNextY(e[new].upperY, y, &nn)
    }

    private static func edgesTooClose(_ e: [GEdge], _ prev: Int, _ next: Int, _ lowerY: Fixed) -> Bool {
        guard next != noneIndex && prev != noneIndex && e[next].upperY < lowerY else { return false }
        let absDx = Int32(min(Int64(aaaMax), Int64(e[next].dx.magnitude)))
        return satAdd(e[prev].x, aaaOne) >= satSub(e[next].x, absDx)
    }
    private static func edgesTooCloseRite(_ prevRite: Int32, _ ul: Fixed, _ ll: Fixed) -> Bool {
        prevRite > floorToInt(ul) || prevRite > floorToInt(ll)
    }

    private static func walkEdges(_ e: inout [GEdge], rule: GAAARule, mask: AAAMask, startY: Int32, stopY: Int32, leftClip: Fixed, rightClip: Fixed, skipIntersect: Bool) {
        let head = 0
        e[head].x = leftClip; e[head].upperX = leftClip
        e[1].x = rightClip; e[1].upperX = rightClip
        var y = max(e[e[head].next].upperY, startY << 16)
        var nn: Fixed = aaaMax
        do {
            var i = e[head].next
            while e[i].upperY <= y {
                e[i].goY(y)
                updateNextNextY(e[i].lowerY, y, &nn)
                i = e[i].next
            }
            updateNextNextY(e[i].upperY, y, &nn)
        }
        let windingMask: Int32 = rule == .evenOdd ? 1 : -1
        let maxSteps = max(0, (stopY - startY + 2) * 64)
        for _ in 0..<maxSteps {
            var w: Int32 = 0
            var inInterval = false
            var prevX = e[head].x
            var nextY = min(nn, ceilToFixed(y + 1))
            var curr = e[head].next
            var leftE = head
            var left = leftClip
            var leftDy: Fixed = 0
            var prevRite = floorToInt(leftClip)
            nn = aaaMax
            var yShift: Int32 = 0
            if ((nextY - y) & (aaaOne >> 2)) != 0 {
                yShift = 2
                nextY = y + (aaaOne >> 2)
            } else if ((nextY - y) & (aaaOne >> 1)) != 0 {
                yShift = 1
            }
            let fullAlpha = fixedToAlpha(nextY - y)
            let row = floorToInt(y)
            while e[curr].upperY <= y {
                w += e[curr].winding
                let prevIn = inInterval
                inInterval = (w & windingMask) != 0
                let isLeft = inInterval && !prevIn
                let isRite = !inInterval && prevIn
                if isRite {
                    let riteRaw = e[curr].x
                    e[curr].goYShift(nextY, yShift)
                    let nextLeft = max(leftClip, e[leftE].x)
                    let rite = min(rightClip, riteRaw)
                    let nextRite = min(rightClip, e[curr].x)
                    let close = fullAlpha == 0xFF &&
                        (edgesTooCloseRite(prevRite, left, e[leftE].x) || edgesTooClose(e, curr, e[curr].next, nextY))
                    blitTrapezoidRow(mask, row, ul: left, ur: rite, ll: nextLeft, lr: nextRite, leftDy, e[curr].dy, fullAlpha, close)
                    prevRite = ceilToInt(max(rite, e[curr].x))
                } else {
                    if isLeft {
                        left = max(e[curr].x, leftClip)
                        leftDy = e[curr].dy
                        leftE = curr
                    }
                    e[curr].goYShift(nextY, yShift)
                }
                let next = e[curr].next
                while e[curr].lowerY <= nextY {
                    if e[curr].curveCount == 0 { break }
                    e[curr].keepContinuous()
                    if !e[curr].update() { break }
                }
                if e[curr].lowerY <= nextY {
                    removeEdge(&e, curr)
                } else {
                    updateNextNextY(e[curr].lowerY, nextY, &nn)
                    let newX = e[curr].x
                    if newX < prevX {
                        backwardInsertEdgeBasedOnX(&e, curr)
                    } else {
                        prevX = newX
                    }
                    if !skipIntersect {
                        checkIntersection(e, curr, nextY, &nn)
                    }
                }
                curr = next
            }
            if inInterval {
                let close = fullAlpha == 0xFF && edgesTooClose(e, e[leftE].prev, leftE, nextY)
                blitTrapezoidRow(mask, row, ul: left, ur: rightClip, ll: max(leftClip, e[leftE].x), lr: rightClip, leftDy, 0, fullAlpha, close)
            }
            y = nextY
            if y >= (stopY << 16) { break }
            insertNewEdges(&e, curr, y, &nn)
        }
    }
}
