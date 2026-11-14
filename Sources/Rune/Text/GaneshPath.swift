// Port of upstream `tiny-skia-path` subset (`path_geometry`, `stroker`, `Path`, `PathBuilder`)
// plus `svg_path` (`blink_number` + conic `arc_to`) needed for `#828` Ganesh icon rasterization.

import Foundation

internal enum GaneshConstants {
    static let scalarNearlyZero: Float = 1.0 / Float(1 << 12)
    static let scalarRoot2Over2: Float = 0.707106781
    static let quadRecursiveLimit = 3
    static let conicRecursiveLimit = 2
    static let recursiveLimits: [Int32] = [5 * 3, 26 * 3, 11 * 3, 11 * 3]
}

// MARK: - Scalar & NormalizedF32 helpers

@inline(__always)
internal func gBound(_ x: Float, _ minVal: Float, _ maxVal: Float) -> Float {
    // Matches `SkTPin`: min(maxVal, x) then max(minVal, ...); for NaN Swift `min`/`max` propagates non-NaN second arg or first?
    // Explicit NaN-safe matches Rust `max.min(self).max(min)`:
    // In Rust `max.min(NaN)` == `max`, `max.max(min)` == `max`.
    if x.isNaN { return maxVal }
    return Swift.max(minVal, Swift.min(maxVal, x))
}

@inline(__always)
internal func gScalarIsNearlyZero(_ x: Float, tolerance: Float = GaneshConstants.scalarNearlyZero) -> Bool {
    abs(x) <= tolerance
}

@inline(__always)
internal func gScalarIsNearlyEqual(_ a: Float, _ b: Float) -> Bool {
    abs(a - b) <= GaneshConstants.scalarNearlyZero
}

@inline(__always)
internal func gSetPointLength(x inX: Float, y inY: Float, length: Float) -> (point: GPoint, ok: Bool) {
    let xx = Double(inX)
    let yy = Double(inY)
    let dmag = (xx * xx + yy * yy).squareRoot()
    let dscale = Double(length) / dmag
    let x = Float(xx * dscale)
    let y = Float(yy * dscale)
    if !x.isFinite || !y.isFinite || (x == 0 && y == 0) {
        return (.zero, false)
    }
    return (GPoint(x: x, y: y), true)
}

internal struct GPoint: Equatable, Hashable, Sendable {
    var x: Float
    var y: Float

    static let zero = GPoint(x: 0, y: 0)

    init(x: Float = 0, y: Float = 0) {
        self.x = x
        self.y = y
    }

    @inline(__always) var isZero: Bool { x == 0 && y == 0 }
    @inline(__always) var isFinite: Bool { (x * y).isFinite }
    @inline(__always) var canNormalize: Bool { x.isFinite && y.isFinite && (x != 0 || y != 0) }
    @inline(__always) var lengthSqd: Float { dot(self) }

    var length: Float {
        let mag2 = x * x + y * y
        if mag2.isFinite {
            return mag2.squareRoot()
        }
        let xx = Double(x), yy = Double(y)
        return Float((xx * xx + yy * yy).squareRoot())
    }

    @inline(__always) func dot(_ o: GPoint) -> Float { x * o.x + y * o.y }
    @inline(__always) func cross(_ o: GPoint) -> Float { x * o.y - y * o.x }

    @inline(__always) func distanceToSqd(_ pt: GPoint) -> Float {
        let dx = x - pt.x
        let dy = y - pt.y
        return dx * dx + dy * dy
    }

    @inline(__always) func scaled(_ s: Float) -> GPoint {
        GPoint(x: x * s, y: y * s)
    }

    @inline(__always) mutating func scale(_ s: Float) {
        x *= s
        y *= s
    }

    @inline(__always) mutating func rotateCW() {
        let oldX = x
        x = -y
        y = oldX
    }

    @inline(__always) mutating func rotateCCW() {
        let oldY = y
        y = -x
        x = oldY
    }

    /// `SkPointPriv::MakeOrthog`: `side == 1` turns `(x, y)` to `(-y, x)`, else `(y, -x)`.
    @inline(__always) func orthog(_ side: Int32) -> GPoint {
        side == 1 ? GPoint(x: -y, y: x) : GPoint(x: y, y: -x)
    }

    mutating func setLength(_ length: Float) -> Bool {
        let (pt, ok) = gSetPointLength(x: x, y: y, length: length)
        self = pt
        return ok
    }

    mutating func normalize() -> Bool {
        setLength(1.0)
    }

    mutating func setNormalize(_ nx: Float, _ ny: Float) -> Bool {
        let (pt, ok) = gSetPointLength(x: nx, y: ny, length: 1.0)
        self = pt
        return ok
    }

    func almostEqual(_ other: GPoint) -> Bool {
        !(self - other).canNormalize
    }

    func equalsWithinTolerance(_ other: GPoint, _ tolerance: Float) -> Bool {
        gScalarIsNearlyZero(x - other.x, tolerance: tolerance) &&
        gScalarIsNearlyZero(y - other.y, tolerance: tolerance)
    }

    static prefix func - (v: GPoint) -> GPoint { GPoint(x: -v.x, y: -v.y) }
    static func + (a: GPoint, b: GPoint) -> GPoint { GPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: GPoint, b: GPoint) -> GPoint { GPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: GPoint, s: Float) -> GPoint { GPoint(x: a.x * s, y: a.y * s) }
}

// MARK: - 2D Affine Transform (matches both `swash::zeno::Transform` and `tiny_skia_path::Transform`)

internal struct GTransform: Equatable, Sendable {
    // Using tiny-skia-path / swash column-vector convention:
    // x' = x * xx + y * yx + tx
    // y' = x * xy + y * yy + ty
    var xx: Float // sx
    var xy: Float // ky
    var yx: Float // kx
    var yy: Float // sy
    var tx: Float
    var ty: Float

    static let identity = GTransform(xx: 1, xy: 0, yx: 0, yy: 1, tx: 0, ty: 0)

    init(xx: Float = 1, xy: Float = 0, yx: Float = 0, yy: Float = 1, tx: Float = 0, ty: Float = 0) {
        self.xx = xx
        self.xy = xy
        self.yx = yx
        self.yy = yy
        self.tx = tx
        self.ty = ty
    }

    static func translation(_ tx: Float, _ ty: Float) -> GTransform {
        GTransform(xx: 1, xy: 0, yx: 0, yy: 1, tx: tx, ty: ty)
    }

    static func scale(_ sx: Float, _ sy: Float) -> GTransform {
        GTransform(xx: sx, xy: 0, yx: 0, yy: sy, tx: 0, ty: 0)
    }

    static func fromSinCos(_ sinV: Float, _ cosV: Float) -> GTransform {
        GTransform(xx: cosV, xy: sinV, yx: -sinV, yy: cosV, tx: 0, ty: 0)
    }

    var isIdentity: Bool { self == .identity }
    var hasScale: Bool { xx != 1 || yy != 1 }
    var hasSkew: Bool { yx != 0 || xy != 0 }
    var hasTranslate: Bool { tx != 0 || ty != 0 }
    var isTranslate: Bool { !hasScale && !hasSkew && hasTranslate }
    var isScaleTranslate: Bool { (hasScale || hasTranslate) && !hasSkew }

    func transformPoint(_ p: GPoint) -> GPoint {
        if isIdentity { return p }
        if isTranslate { return GPoint(x: p.x + tx, y: p.y + ty) }
        if isScaleTranslate { return GPoint(x: p.x * xx + tx, y: p.y * yy + ty) }
        return GPoint(
            x: p.x * xx + p.y * yx + tx,
            y: p.x * xy + p.y * yy + ty
        )
    }

    func mapPoints(_ points: inout [GPoint]) {
        guard !points.isEmpty else { return }
        if isIdentity { return }
        if isTranslate {
            for i in points.indices {
                points[i].x += tx
                points[i].y += ty
            }
        } else if isScaleTranslate {
            for i in points.indices {
                points[i].x = points[i].x * xx + tx
                points[i].y = points[i].y * yy + ty
            }
        } else {
            for i in points.indices {
                let p = points[i]
                points[i].x = p.x * xx + p.y * yx + tx
                points[i].y = p.x * xy + p.y * yy + ty
            }
        }
    }

    func preScale(_ sx: Float, _ sy: Float) -> GTransform {
        GTransform.concat(self, .scale(sx, sy))
    }

    func postTranslate(_ dx: Float, _ dy: Float) -> GTransform {
        GTransform.concat(.translation(dx, dy), self)
    }

    func postConcat(_ other: GTransform) -> GTransform {
        GTransform.concat(other, self)
    }

    /// `a` then `b` (`a` is applied to points first, then `b`? Wait: matches `tiny_skia_path::concat(a, b)` where `a` multiplies `b` on the left, i.e., `b` then `a` in column vector notation; `then(a, b)` in `icon.rs` is `concat(b, a)`!)
    static func concat(_ a: GTransform, _ b: GTransform) -> GTransform {
        if a.isIdentity { return b }
        if b.isIdentity { return a }
        if !a.hasSkew && !b.hasSkew {
            return GTransform(
                xx: a.xx * b.xx,
                xy: 0,
                yx: 0,
                yy: a.yy * b.yy,
                tx: a.xx * b.tx + a.tx,
                ty: a.yy * b.ty + a.ty
            )
        }
        @inline(__always) func mulAddMul(_ p: Float, _ q: Float, _ r: Float, _ s: Float) -> Float {
            Float(Double(p) * Double(q) + Double(r) * Double(s))
        }
        return GTransform(
            xx: mulAddMul(a.xx, b.xx, a.yx, b.xy),
            xy: mulAddMul(a.xy, b.xx, a.yy, b.xy),
            yx: mulAddMul(a.xx, b.yx, a.yx, b.yy),
            yy: mulAddMul(a.xy, b.yx, a.yy, b.yy),
            tx: mulAddMul(a.xx, b.tx, a.yx, b.ty) + a.tx,
            ty: mulAddMul(a.xy, b.tx, a.yy, b.ty) + a.ty
        )
    }

    /// `icon.rs`'s `then(a, b)`: apply `a` first, then `b`.
    static func then(_ a: GTransform, _ b: GTransform) -> GTransform {
        GTransform(
            xx: a.xx * b.xx + a.xy * b.yx,
            xy: a.xx * b.xy + a.xy * b.yy,
            yx: a.yx * b.xx + a.yy * b.yx,
            yy: a.yx * b.xy + a.yy * b.yy,
            tx: a.tx * b.xx + a.ty * b.yx + b.tx,
            ty: a.tx * b.xy + a.ty * b.yy + b.ty
        )
    }
}

internal struct GRect: Equatable, Sendable {
    var left: Float
    var top: Float
    var right: Float
    var bottom: Float

    var width: Float { right - left }
    var height: Float { bottom - top }

    static func fromLTRB(_ l: Float, _ t: Float, _ r: Float, _ b: Float) -> GRect? {
        guard l.isFinite, t.isFinite, r.isFinite, b.isFinite, l <= r, t <= b else { return nil }
        guard (r - l).isFinite, (b - t).isFinite else { return nil }
        return GRect(left: l, top: t, right: r, bottom: b)
    }

    static func fromPoints(_ points: [GPoint]) -> GRect? {
        guard let first = points.first, first.x.isFinite, first.y.isFinite else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points.dropFirst() {
            guard p.x.isFinite, p.y.isFinite else { return nil }
            minX = min(minX, p.x)
            minY = min(minY, p.y)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
        }
        return fromLTRB(minX, minY, maxX, maxY)
    }
}

// MARK: - Path Elements & Path / PathBuilder

internal enum GEl: Equatable, Sendable {
    case move(GPoint)
    case line(GPoint)
    case quad(GPoint, GPoint)
    case cubic(GPoint, GPoint, GPoint)
    case conic(GPoint, GPoint, Float)
    case close

    var points: [GPoint] {
        switch self {
        case .move(let a), .line(let a): return [a]
        case .quad(let a, let b), .conic(let a, let b, _): return [a, b]
        case .cubic(let a, let b, let c): return [a, b, c]
        case .close: return []
        }
    }
}

internal enum GVerb: Equatable, Sendable {
    case move
    case line
    case quad
    case cubic
    case conic
    case close
}

internal enum GSegment: Equatable, Sendable {
    case moveTo(GPoint)
    case lineTo(GPoint)
    case quadTo(GPoint, GPoint)
    case cubicTo(GPoint, GPoint, GPoint)
    case conicTo(GPoint, GPoint, Float)
    case close
}

internal enum GPathDirection: Sendable {
    case cw
    case ccw
}

internal struct GPath: Equatable, Sendable {
    var verbs: [GVerb]
    var points: [GPoint]
    var weights: [Float]
    var bounds: GRect

    func transform(_ ts: GTransform) -> GPath? {
        if ts.isIdentity { return self }
        var pts = points
        ts.mapPoints(&pts)
        guard let b = GRect.fromPoints(pts) else { return nil }
        return GPath(verbs: verbs, points: pts, weights: weights, bounds: b)
    }

    func stroke(_ stroke: GStroke, resolutionScale: Float) -> GPath? {
        var stroker = GPathStroker()
        return stroker.stroke(self, stroke: stroke, resolutionScale: resolutionScale)
    }

    func makeSegmentsIterator(autoClose: Bool = false) -> GPathSegmentsIter {
        GPathSegmentsIter(path: self, isAutoClose: autoClose)
    }
}

internal struct GPathSegmentsIter {
    let path: GPath
    var verbIndex: Int = 0
    var pointsIndex: Int = 0
    var weightIndex: Int = 0
    var isAutoClose: Bool = false
    var lastMoveTo: GPoint = .zero
    var lastPoint: GPoint = .zero

    mutating func next() -> GSegment? {
        guard verbIndex < path.verbs.count else { return nil }
        let verb = path.verbs[verbIndex]
        verbIndex += 1
        switch verb {
        case .move:
            pointsIndex += 1
            lastMoveTo = path.points[pointsIndex - 1]
            lastPoint = lastMoveTo
            return .moveTo(lastMoveTo)
        case .line:
            pointsIndex += 1
            lastPoint = path.points[pointsIndex - 1]
            return .lineTo(lastPoint)
        case .quad:
            pointsIndex += 2
            lastPoint = path.points[pointsIndex - 1]
            return .quadTo(path.points[pointsIndex - 2], lastPoint)
        case .cubic:
            pointsIndex += 3
            lastPoint = path.points[pointsIndex - 1]
            return .cubicTo(path.points[pointsIndex - 3], path.points[pointsIndex - 2], lastPoint)
        case .conic:
            pointsIndex += 2
            weightIndex += 1
            lastPoint = path.points[pointsIndex - 1]
            return .conicTo(path.points[pointsIndex - 2], lastPoint, path.weights[weightIndex - 1])
        case .close:
            let seg: GSegment
            if isAutoClose && lastPoint != lastMoveTo {
                verbIndex -= 1
                seg = .lineTo(lastMoveTo)
            } else {
                seg = .close
            }
            lastPoint = lastMoveTo
            return seg
        }
    }

    func hasValidTangent() -> Bool {
        var iter = self
        while let segment = iter.next() {
            switch segment {
            case .moveTo:
                return false
            case .lineTo(let p):
                if iter.lastPoint == p { continue }
                return true
            case .quadTo(let p1, let p2), .conicTo(let p1, let p2, _):
                if iter.lastPoint == p1 && iter.lastPoint == p2 { continue }
                return true
            case .cubicTo(let p1, let p2, let p3):
                if iter.lastPoint == p1 && iter.lastPoint == p2 && iter.lastPoint == p3 { continue }
                return true
            case .close:
                return false
            }
        }
        return false
    }
}

internal struct GPathBuilder {
    var verbs: [GVerb] = []
    var points: [GPoint] = []
    var weights: [Float] = []
    var keepConics: Bool = false
    var lastMoveToIndex: Int = 0
    var moveToRequired: Bool = true
    var conicTolerance: Float = 0

    var isEmpty: Bool { verbs.isEmpty }
    var lastPoint: GPoint? { points.last }

    mutating func clear() {
        verbs.removeAll(keepingCapacity: true)
        points.removeAll(keepingCapacity: true)
        weights.removeAll(keepingCapacity: true)
        lastMoveToIndex = 0
        moveToRequired = true
    }

    mutating func reserve(verbs vCap: Int, points pCap: Int) {
        verbs.reserveCapacity(vCap)
        points.reserveCapacity(pCap)
    }

    mutating func moveTo(_ x: Float, _ y: Float) {
        if verbs.last == .move {
            points[points.count - 1] = GPoint(x: x, y: y)
        } else {
            lastMoveToIndex = points.count
            moveToRequired = false
            verbs.append(.move)
            points.append(GPoint(x: x, y: y))
        }
    }

    private mutating func injectMoveToIfNeeded() {
        if moveToRequired {
            if lastMoveToIndex < points.count {
                let p = points[lastMoveToIndex]
                moveTo(p.x, p.y)
            } else {
                moveTo(0, 0)
            }
        }
    }

    mutating func lineTo(_ x: Float, _ y: Float) {
        injectMoveToIfNeeded()
        verbs.append(.line)
        points.append(GPoint(x: x, y: y))
    }

    mutating func quadTo(_ x1: Float, _ y1: Float, _ x: Float, _ y: Float) {
        injectMoveToIfNeeded()
        verbs.append(.quad)
        points.append(GPoint(x: x1, y: y1))
        points.append(GPoint(x: x, y: y))
    }

    mutating func conicTo(_ x1: Float, _ y1: Float, _ x: Float, _ y: Float, _ weight: Float) {
        if !(weight > 0) {
            lineTo(x, y)
        } else if !weight.isFinite {
            lineTo(x1, y1)
            lineTo(x, y)
        } else if weight == 1 {
            quadTo(x1, y1, x, y)
        } else if keepConics {
            injectMoveToIfNeeded()
            verbs.append(.conic)
            points.append(GPoint(x: x1, y: y1))
            points.append(GPoint(x: x, y: y))
            weights.append(weight)
        } else {
            injectMoveToIfNeeded()
            let last = points.last!
            let tol = conicTolerance > 0 ? conicTolerance : 0.25
            if let quadder = GAutoConicToQuads.compute(last, GPoint(x: x1, y: y1), GPoint(x: x, y: y), weight: weight, tolerance: tol) {
                var offset = 1
                for _ in 0..<quadder.len {
                    let pt1 = quadder.points[offset]
                    let pt2 = quadder.points[offset + 1]
                    quadTo(pt1.x, pt1.y, pt2.x, pt2.y)
                    offset += 2
                }
            }
        }
    }

    mutating func cubicTo(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float, _ x: Float, _ y: Float) {
        injectMoveToIfNeeded()
        verbs.append(.cubic)
        points.append(GPoint(x: x1, y: y1))
        points.append(GPoint(x: x2, y: y2))
        points.append(GPoint(x: x, y: y))
    }

    mutating func close() {
        if !verbs.isEmpty && verbs.last != .close {
            verbs.append(.close)
        }
        moveToRequired = true
    }

    mutating func setLastPoint(_ pt: GPoint) {
        if points.isEmpty {
            moveTo(pt.x, pt.y)
        } else {
            points[points.count - 1] = pt
        }
    }

    func isZeroLengthSincePoint(_ startPtIndex: Int) -> Bool {
        let count = points.count - startPtIndex
        if count < 2 { return true }
        let first = points[startPtIndex]
        for i in 1..<count where first != points[startPtIndex + i] {
            return false
        }
        return true
    }

    mutating func pushOval(_ oval: GRect) {
        let cx = oval.left * 0.5 + oval.right * 0.5
        let cy = oval.top * 0.5 + oval.bottom * 0.5
        let ovalPts = [
            GPoint(x: cx, y: oval.bottom),
            GPoint(x: oval.left, y: cy),
            GPoint(x: cx, y: oval.top),
            GPoint(x: oval.right, y: cy),
        ]
        let rectPts = [
            GPoint(x: oval.right, y: oval.bottom),
            GPoint(x: oval.left, y: oval.bottom),
            GPoint(x: oval.left, y: oval.top),
            GPoint(x: oval.right, y: oval.top),
        ]
        let w = GaneshConstants.scalarRoot2Over2
        moveTo(ovalPts[3].x, ovalPts[3].y)
        for i in 0..<4 {
            conicTo(rectPts[i].x, rectPts[i].y, ovalPts[i].x, ovalPts[i].y, w)
        }
        close()
    }

    mutating func pushCircle(x: Float, y: Float, r: Float) {
        if let rect = GRect.fromLTRB(x - r, y - r, x + r, y + r), rect.width > 0, rect.height > 0 {
            pushOval(rect)
        }
    }

    mutating func pushPathBuilder(_ other: GPathBuilder) {
        guard !other.isEmpty else { return }
        if lastMoveToIndex != 0 {
            lastMoveToIndex = points.count + other.lastMoveToIndex
        }
        verbs.append(contentsOf: other.verbs)
        points.append(contentsOf: other.points)
        weights.append(contentsOf: other.weights)
    }

    mutating func reversePathTo(_ other: GPathBuilder) {
        guard !other.isEmpty else { return }
        var ptsOff = other.points.count - 1
        for verb in other.verbs.reversed() {
            switch verb {
            case .move:
                return
            case .line:
                let pt = other.points[ptsOff - 1]
                ptsOff -= 1
                lineTo(pt.x, pt.y)
            case .quad:
                let pt1 = other.points[ptsOff - 1]
                let pt2 = other.points[ptsOff - 2]
                ptsOff -= 2
                quadTo(pt1.x, pt1.y, pt2.x, pt2.y)
            case .cubic:
                let pt1 = other.points[ptsOff - 1]
                let pt2 = other.points[ptsOff - 2]
                let pt3 = other.points[ptsOff - 3]
                ptsOff -= 3
                cubicTo(pt1.x, pt1.y, pt2.x, pt2.y, pt3.x, pt3.y)
            case .conic:
                let pt1 = other.points[ptsOff - 1]
                let pt2 = other.points[ptsOff - 2]
                ptsOff -= 2
                quadTo(pt1.x, pt1.y, pt2.x, pt2.y)
            case .close:
                break
            }
        }
    }

    func finish() -> GPath? {
        guard !isEmpty, verbs.count > 1, let b = GRect.fromPoints(points) else { return nil }
        return GPath(verbs: verbs, points: points, weights: weights, bounds: b)
    }
}

// MARK: - Path Geometry (`path_geometry.rs`)

internal enum GPathGeometry {
    @inline(__always)
    static func validUnitDivide(_ inNumer: Float, _ inDenom: Float) -> Float? {
        var numer = inNumer
        var denom = inDenom
        if numer < 0 {
            numer = -numer
            denom = -denom
        }
        if denom == 0 || numer == 0 || numer >= denom {
            return nil
        }
        let r = numer / denom
        return (r > 0 && r < 1 && r.isFinite) ? r : nil
    }

    static func findUnitQuadRoots(a: Float, b: Float, c: Float, roots: inout [Float]) -> Int {
        if a == 0 {
            if let r = validUnitDivide(-c, b) {
                roots[0] = r
                return 1
            }
            return 0
        }
        var dr = Double(b) * Double(b) - 4.0 * Double(a) * Double(c)
        if dr < 0 { return 0 }
        dr = dr.squareRoot()
        let r = Float(dr)
        if !r.isFinite { return 0 }
        let q: Float = b < 0 ? -(b - r) * 0.5 : -(b + r) * 0.5
        var offset = 0
        if let root0 = validUnitDivide(q, a) {
            roots[offset] = root0
            offset += 1
        }
        if let root1 = validUnitDivide(c, q) {
            roots[offset] = root1
            offset += 1
        }
        if offset == 2 {
            if roots[0] > roots[1] {
                roots.swapAt(0, 1)
            } else if roots[0] == roots[1] {
                offset -= 1
            }
        }
        return offset
    }

    static func chopQuadAt(_ src: [GPoint], _ base: Int, t: Float) -> (GPoint, GPoint, GPoint, GPoint, GPoint) {
        let p0 = src[base], p1 = src[base + 1], p2 = src[base + 2]
        let p01 = p0 + (p1 - p0) * t
        let p12 = p1 + (p2 - p1) * t
        let mid = p01 + (p12 - p01) * t
        return (p0, p01, mid, p12, p2)
    }

    static func chopCubicAt2(_ src: (GPoint, GPoint, GPoint, GPoint), t: Float) -> (GPoint, GPoint, GPoint, GPoint, GPoint, GPoint, GPoint) {
        let ab = src.0 + (src.1 - src.0) * t
        let bc = src.1 + (src.2 - src.1) * t
        let cd = src.2 + (src.3 - src.2) * t
        let abc = ab + (bc - ab) * t
        let bcd = bc + (cd - bc) * t
        let abcd = abc + (bcd - abc) * t
        return (src.0, ab, abc, abcd, bcd, cd, src.3)
    }

    static func findQuadMaxCurvature(_ src0: GPoint, _ src1: GPoint, _ src2: GPoint) -> Float {
        let ax = src1.x - src0.x
        let ay = src1.y - src0.y
        let bx = src0.x - src1.x - src1.x + src2.x
        let by = src0.y - src1.y - src1.y + src2.y
        var numer = -(ax * bx + ay * by)
        var denom = bx * bx + by * by
        if denom < 0 {
            numer = -numer
            denom = -denom
        }
        if numer <= 0 { return 0 }
        if numer >= denom { return 1 }
        return numer / denom
    }

    static func evalQuadAt(_ src0: GPoint, _ src1: GPoint, _ src2: GPoint, t: Float) -> GPoint {
        let b = (src1 - src0) * 2.0
        let a = src2 - src1 * 2.0 + src0
        return (a * t + b) * t + src0
    }

    static func evalQuadTangentAt(_ src0: GPoint, _ src1: GPoint, _ src2: GPoint, t: Float) -> GPoint {
        if (t == 0 && src0 == src1) || (t == 1 && src1 == src2) {
            return src2 - src0
        }
        let b = src1 - src0
        let a = src2 - src1 - b
        let r = a * t + b
        return r + r
    }

    private static func formulateF1DotF2(_ s0: Float, _ s1: Float, _ s2: Float, _ s3: Float) -> (Float, Float, Float, Float) {
        let a = s1 - s0
        let b = s2 - 2.0 * s1 + s0
        let c = s3 + 3.0 * (s1 - s2) - s0
        return (c * c, 3.0 * b * c, 2.0 * b * b + c * a, a * b)
    }

    private static func solveCubicPoly(_ c0: Float, _ c1: Float, _ c2: Float, _ c3: Float, tValues: inout [Float]) -> Int {
        if gScalarIsNearlyZero(c0) {
            return findUnitQuadRoots(a: c1, b: c2, c: c3, roots: &tValues)
        }
        let inva = 1.0 / c0
        let a = c1 * inva
        let b = c2 * inva
        let c = c3 * inva
        let q = (a * a - b * 3.0) / 9.0
        let r = (2.0 * a * a * a - 9.0 * a * b + 27.0 * c) / 54.0
        let q3 = q * q * q
        let r2MinusQ3 = r * r - q3
        let adiv3 = a / 3.0
        if r2MinusQ3 < 0 {
            let theta = acos(gBound(r / q3.squareRoot(), -1.0, 1.0))
            let neg2RootQ = -2.0 * q.squareRoot()
            let pi: Float = 3.14159265
            tValues[0] = gBound(neg2RootQ * cos(theta / 3.0) - adiv3, 0, 1)
            tValues[1] = gBound(neg2RootQ * cos((theta + 2.0 * pi) / 3.0) - adiv3, 0, 1)
            tValues[2] = gBound(neg2RootQ * cos((theta - 2.0 * pi) / 3.0) - adiv3, 0, 1)
            if tValues[0] > tValues[1] { tValues.swapAt(0, 1) }
            if tValues[1] > tValues[2] { tValues.swapAt(1, 2) }
            if tValues[0] > tValues[1] { tValues.swapAt(0, 1) }
            var len = 3
            if tValues[1] == tValues[2] { len = 2 }
            if tValues[0] == tValues[1] { len = 1 }
            return len
        } else {
            var bigA = abs(r) + r2MinusQ3.squareRoot()
            bigA = powf(bigA, 0.3333333)
            if r > 0 { bigA = -bigA }
            if bigA != 0 { bigA += q / bigA }
            tValues[0] = gBound(bigA - adiv3, 0, 1)
            return 1
        }
    }

    static func findCubicMaxCurvature(_ p0: GPoint, _ p1: GPoint, _ p2: GPoint, _ p3: GPoint) -> [Float] {
        let cx = formulateF1DotF2(p0.x, p1.x, p2.x, p3.x)
        let cy = formulateF1DotF2(p0.y, p1.y, p2.y, p3.y)
        var tValues = [Float](repeating: 0, count: 3)
        let len = solveCubicPoly(cx.0 + cy.0, cx.1 + cy.1, cx.2 + cy.2, cx.3 + cy.3, tValues: &tValues)
        return Array(tValues[0..<len])
    }

    static func evalCubicPosAt(_ p0: GPoint, _ p1: GPoint, _ p2: GPoint, _ p3: GPoint, t: Float) -> GPoint {
        let a = p3 + (p1 - p2) * 3.0 - p0
        let b = (p2 - (p1 + p1) + p0) * 3.0
        let c = (p1 - p0) * 3.0
        return ((a * t + b) * t + c) * t + p0
    }

    static func evalCubicDerivative(_ p0: GPoint, _ p1: GPoint, _ p2: GPoint, _ p3: GPoint, t: Float) -> GPoint {
        let a = p3 + (p1 - p2) * 3.0 - p0
        let b = (p2 - (p1 + p1) + p0) * 2.0
        let c = p1 - p0
        return (a * t + b) * t + c
    }

    static func evalCubicTangentAt(_ p0: GPoint, _ p1: GPoint, _ p2: GPoint, _ p3: GPoint, t: Float) -> GPoint {
        if (t == 0 && p0 == p1) || (t == 1 && p2 == p3) {
            var tangent = t == 0 ? (p2 - p0) : (p3 - p1)
            if tangent.isZero { tangent = p3 - p0 }
            return tangent
        }
        return evalCubicDerivative(p0, p1, p2, p3, t: t)
    }

    static func findCubicInflections(_ p0: GPoint, _ p1: GPoint, _ p2: GPoint, _ p3: GPoint) -> [Float] {
        let ax = p1.x - p0.x, ay = p1.y - p0.y
        let bx = p2.x - 2.0 * p1.x + p0.x, by = p2.y - 2.0 * p1.y + p0.y
        let cx = p3.x + 3.0 * (p1.x - p2.x) - p0.x, cy = p3.y + 3.0 * (p1.y - p2.y) - p0.y
        var ts = [Float](repeating: 0, count: 3)
        let len = findUnitQuadRoots(a: bx * cy - by * cx, b: ax * cy - ay * cx, c: ax * by - ay * bx, roots: &ts)
        return Array(ts[0..<len])
    }

    static func findCubicCusp(_ p0: GPoint, _ p1: GPoint, _ p2: GPoint, _ p3: GPoint) -> Float? {
        if p0 == p1 || p2 == p3 { return nil }
        let src = [p0, p1, p2, p3]
        func onSameSide(_ testIdx: Int, _ lineIdx: Int) -> Bool {
            let origin = src[lineIdx]
            let line = src[lineIdx + 1] - origin
            let c0 = line.cross(src[testIdx] - origin)
            let c1 = line.cross(src[testIdx + 1] - origin)
            return c0 * c1 >= 0
        }
        if onSameSide(0, 2) || onSameSide(2, 0) { return nil }
        let precision = (p1.distanceToSqd(p0) + p2.distanceToSqd(p1) + p3.distanceToSqd(p2)) * 1e-8
        for t in findCubicMaxCurvature(p0, p1, p2, p3) {
            if t <= 0 || t >= 1 { continue }
            let dPt = evalCubicDerivative(p0, p1, p2, p3, t: t)
            if dPt.lengthSqd < precision {
                return gBound(t, Float.ulpOfOne, 1.0 - Float.ulpOfOne)
            }
        }
        return nil
    }
}

internal struct GConic {
    var points: (GPoint, GPoint, GPoint)
    var weight: Float

    func computeQuadPow2(tolerance: Float) -> UInt8? {
        guard tolerance >= 0, tolerance.isFinite, points.0.isFinite, points.1.isFinite, points.2.isFinite else {
            return nil
        }
        let a = weight - 1.0
        let k = a / (4.0 * (2.0 + a))
        let x = k * (points.0.x - 2.0 * points.1.x + points.2.x)
        let y = k * (points.0.y - 2.0 * points.1.y + points.2.y)
        var error = (x * x + y * y).squareRoot()
        var pow2: UInt8 = 0
        for _ in 0..<4 {
            if error <= tolerance { break }
            error *= 0.25
            pow2 += 1
        }
        return pow2
    }

    func chop() -> (GConic, GConic) {
        let scale = 1.0 / (1.0 + weight)
        let newW = (0.5 + weight * 0.5).squareRoot()
        let p0 = points.0, p1 = points.1, p2 = points.2
        let wp1 = p1 * weight
        var mPt = (p0 + wp1 * 2.0 + p2) * scale * 0.5
        if !mPt.isFinite {
            let wd = Double(weight)
            let w2 = wd * 2.0
            let scaleHalf = 1.0 / (1.0 + wd) * 0.5
            mPt = GPoint(
                x: Float((Double(p0.x) + w2 * Double(p1.x) + Double(p2.x)) * scaleHalf),
                y: Float((Double(p0.y) + w2 * Double(p1.y) + Double(p2.y)) * scaleHalf)
            )
        }
        let c0 = GConic(points: (p0, (p0 + wp1) * scale, mPt), weight: newW)
        let c1 = GConic(points: (mPt, (wp1 + p2) * scale, p2), weight: newW)
        return (c0, c1)
    }

    private static func between(_ a: Float, _ b: Float, _ c: Float) -> Bool {
        (a - b) * (c - b) <= 0
    }

    private static func subdivide(_ src: GConic, points: inout [GPoint], offset: inout Int, level: UInt8) {
        if level == 0 {
            points[offset] = src.points.1
            points[offset + 1] = src.points.2
            offset += 2
            return
        }
        var dst = src.chop()
        let startY = src.points.0.y
        let endY = src.points.2.y
        if between(startY, src.points.1.y, endY) {
            let midY = dst.0.points.2.y
            if !between(startY, midY, endY) {
                let closerY = abs(midY - startY) < abs(midY - endY) ? startY : endY
                dst.0.points.2.y = closerY
                dst.1.points.0.y = closerY
            }
            if !between(startY, dst.0.points.1.y, dst.0.points.2.y) {
                dst.0.points.1.y = startY
            }
            if !between(dst.1.points.0.y, dst.1.points.1.y, endY) {
                dst.1.points.1.y = endY
            }
        }
        subdivide(dst.0, points: &points, offset: &offset, level: level - 1)
        subdivide(dst.1, points: &points, offset: &offset, level: level - 1)
    }

    func chopIntoQuadsPow2(_ pow2: UInt8, points: inout [GPoint]) -> UInt8 {
        points[0] = self.points.0
        var offset = 1
        GConic.subdivide(self, points: &points, offset: &offset, level: pow2)
        let quadCount = 1 << Int(pow2)
        let ptCount = 2 * quadCount + 1
        if points[0..<ptCount].contains(where: { !$0.isFinite }) {
            for i in 1..<(ptCount - 1) {
                points[i] = self.points.1
            }
        }
        return UInt8(quadCount)
    }

    static func buildUnitArc(
        uStart: GPoint,
        uStop: GPoint,
        dir: GPathDirection,
        userTransform: GTransform
    ) -> [GConic] {
        let x = uStart.dot(uStop)
        var y = uStart.cross(uStop)
        let absY = abs(y)
        if absY <= GaneshConstants.scalarNearlyZero && x > 0 && ((y >= 0 && dir == .cw) || (y <= 0 && dir == .ccw)) {
            return []
        }
        if dir == .ccw { y = -y }
        var quadrant = 0
        if y == 0 {
            quadrant = 2
        } else if x == 0 {
            quadrant = y > 0 ? 1 : 3
        } else {
            if y < 0 { quadrant += 2 }
            if (x < 0) != (y < 0) { quadrant += 1 }
        }
        let quadrantPoints: [GPoint] = [
            GPoint(x: 1, y: 0), GPoint(x: 1, y: 1),
            GPoint(x: 0, y: 1), GPoint(x: -1, y: 1),
            GPoint(x: -1, y: 0), GPoint(x: -1, y: -1),
            GPoint(x: 0, y: -1), GPoint(x: 1, y: -1),
        ]
        var dst: [GConic] = []
        dst.reserveCapacity(5)
        for i in 0..<quadrant {
            dst.append(GConic(
                points: (quadrantPoints[i * 2], quadrantPoints[i * 2 + 1], quadrantPoints[i * 2 + 2]),
                weight: GaneshConstants.scalarRoot2Over2
            ))
        }
        let finalPt = GPoint(x: x, y: y)
        let lastQ = quadrantPoints[quadrant * 2]
        let dot = lastQ.dot(finalPt)
        if dot < 1.0 {
            var offCurve = GPoint(x: lastQ.x + x, y: lastQ.y + y)
            let cosHalf = ((1.0 + dot) * 0.5).squareRoot()
            _ = offCurve.setLength(1.0 / cosHalf)
            if !lastQ.almostEqual(offCurve) {
                dst.append(GConic(points: (lastQ, offCurve, finalPt), weight: cosHalf))
            }
        }
        var ts = GTransform.fromSinCos(uStart.y, uStart.x)
        if dir == .ccw { ts = ts.preScale(1, -1) }
        ts = ts.postConcat(userTransform)
        for i in dst.indices {
            dst[i].points.0 = ts.transformPoint(dst[i].points.0)
            dst[i].points.1 = ts.transformPoint(dst[i].points.1)
            dst[i].points.2 = ts.transformPoint(dst[i].points.2)
        }
        return dst
    }
}

internal struct GAutoConicToQuads {
    var points: [GPoint]
    var len: UInt8

    static func compute(_ pt0: GPoint, _ pt1: GPoint, _ pt2: GPoint, weight: Float, tolerance: Float) -> GAutoConicToQuads? {
        let conic = GConic(points: (pt0, pt1, pt2), weight: weight)
        guard let pow2 = conic.computeQuadPow2(tolerance: tolerance) else { return nil }
        var pts = [GPoint](repeating: .zero, count: 64)
        let len = conic.chopIntoQuadsPow2(pow2, points: &pts)
        return GAutoConicToQuads(points: pts, len: len)
    }
}

// MARK: - PathStroker (`stroker.rs`)

internal enum GLineCap: Equatable, Sendable {
    case butt, round, square
}

internal enum GLineJoin: Equatable, Sendable {
    case miter, miterClip, round, bevel
}

internal struct GStroke: Equatable, Sendable {
    var width: Float = 1.0
    var miterLimit: Float = 4.0
    var lineCap: GLineCap = .butt
    var lineJoin: GLineJoin = .miter
}

private enum GReductionType: Int, Comparable {
    case point = 0
    case line = 1
    case quad = 2
    case degenerate = 3
    case degenerate2 = 4
    case degenerate3 = 5

    static func < (lhs: GReductionType, rhs: GReductionType) -> Bool { lhs.rawValue < rhs.rawValue }
}

private enum GStrokeType: Int32 {
    case outer = 1
    case inner = -1
}

private enum GResultType {
    case split, degenerate, quad
}

private enum GIntersectRayType {
    case ctrlPt, resultType
}

private enum GAngleType {
    case nearly180, sharp, shallow, nearlyLine
}

private struct GQuadConstruct {
    var quad: (GPoint, GPoint, GPoint) = (.zero, .zero, .zero)
    var tangentStart: GPoint = .zero
    var tangentEnd: GPoint = .zero
    var startT: Float = 0
    var midT: Float = 0
    var endT: Float = 0
    var startSet: Bool = false
    var endSet: Bool = false
    var oppositeTangents: Bool = false

    @discardableResult
    mutating func initRange(_ start: Float, _ end: Float) -> Bool {
        startT = start
        midT = gBound((start + end) * 0.5, 0, 1)
        endT = end
        startSet = false
        endSet = false
        return startT < midT && midT < endT
    }

    mutating func initWithStart(_ parent: GQuadConstruct) -> Bool {
        guard initRange(parent.startT, parent.midT) else { return false }
        quad.0 = parent.quad.0
        tangentStart = parent.tangentStart
        startSet = true
        return true
    }

    mutating func initWithEnd(_ parent: GQuadConstruct) -> Bool {
        guard initRange(parent.midT, parent.endT) else { return false }
        quad.2 = parent.quad.2
        tangentEnd = parent.tangentEnd
        endSet = true
        return true
    }
}

internal struct GPathStroker {
    private var radius: Float = 0
    private var invMiterLimit: Float = 0
    private var resScale: Float = 1
    private var invResScale: Float = 1
    private var invResScaleSquared: Float = 1

    private var firstNormal: GPoint = .zero
    private var prevNormal: GPoint = .zero
    private var firstUnitNormal: GPoint = .zero
    private var prevUnitNormal: GPoint = .zero

    private var firstPt: GPoint = .zero
    private var prevPt: GPoint = .zero
    private var firstOuterPt: GPoint = .zero
    private var firstOuterPtIndexInContour: Int = 0
    private var segmentCount: Int32 = -1
    private var prevIsLine: Bool = false

    private var capMode: GLineCap = .butt
    private var joinMode: GLineJoin = .miter

    private var inner = GPathBuilder()
    private var outer = GPathBuilder()
    private var cusper = GPathBuilder()

    private var strokeType: GStrokeType = .outer
    private var recursionDepth: Int32 = 0
    private var foundTangents: Bool = false
    private var joinCompleted: Bool = false

    static func computeResolutionScale(_ ts: GTransform) -> Float {
        let sx = GPoint(x: ts.xx, y: ts.yx).length
        let sy = GPoint(x: ts.xy, y: ts.yy).length
        if sx.isFinite && sy.isFinite {
            let s = max(sx, sy)
            if s > 0 { return s }
        }
        return 1.0
    }

    mutating func stroke(_ path: GPath, stroke: GStroke, resolutionScale: Float) -> GPath? {
        guard stroke.width.isFinite, stroke.width > 0 else { return nil }
        return strokeInner(
            path,
            width: stroke.width,
            miterLimit: stroke.miterLimit,
            lineCap: stroke.lineCap,
            lineJoin: stroke.lineJoin,
            resScale: resolutionScale
        )
    }

    private mutating func strokeInner(
        _ path: GPath,
        width: Float,
        miterLimit: Float,
        lineCap: GLineCap,
        lineJoin inJoin: GLineJoin,
        resScale: Float
    ) -> GPath? {
        var lineJoin = inJoin
        var invMiterLimit: Float = 0
        if lineJoin == .miter {
            if miterLimit <= 1.0 {
                lineJoin = .bevel
            } else {
                invMiterLimit = 1.0 / miterLimit
            }
        }
        if lineJoin == .miterClip {
            invMiterLimit = 1.0 / miterLimit
        }

        self.resScale = resScale
        self.invResScale = 1.0 / (resScale * 4.0)
        self.invResScaleSquared = invResScale * invResScale
        let conicTol = 0.25 / resScale
        inner.conicTolerance = conicTol
        outer.conicTolerance = conicTol
        cusper.conicTolerance = conicTol

        radius = width * 0.5
        self.invMiterLimit = invMiterLimit
        firstNormal = .zero
        prevNormal = .zero
        firstUnitNormal = .zero
        prevUnitNormal = .zero
        firstPt = .zero
        prevPt = .zero
        firstOuterPt = .zero
        firstOuterPtIndexInContour = 0
        segmentCount = -1
        prevIsLine = false
        capMode = lineCap
        joinMode = lineJoin

        inner.clear()
        inner.reserve(verbs: path.verbs.count, points: path.points.count)
        outer.clear()
        outer.reserve(verbs: path.verbs.count * 3, points: path.points.count * 3)
        cusper.clear()

        strokeType = .outer
        recursionDepth = 0
        foundTangents = false
        joinCompleted = false

        var lastSegmentIsLine = false
        var iter = path.makeSegmentsIterator(autoClose: true)
        while let seg = iter.next() {
            switch seg {
            case .moveTo(let p):
                moveTo(p)
            case .lineTo(let p):
                lineTo(p, iter: iter)
                lastSegmentIsLine = true
            case .quadTo(let p1, let p2):
                quadTo(p1, p2)
                lastSegmentIsLine = false
            case .cubicTo(let p1, let p2, let p3):
                cubicTo(p1, p2, p3)
                lastSegmentIsLine = false
            case .conicTo(let p1, let p2, let w):
                conicTo(p1, p2, weight: w)
                lastSegmentIsLine = false
            case .close:
                if lineCap != .butt {
                    if segmentCount == 0 {
                        lineTo(firstPt, iter: nil)
                        lastSegmentIsLine = true
                        continue
                    }
                    if inner.isZeroLengthSincePoint(0) && outer.isZeroLengthSincePoint(firstOuterPtIndexInContour) {
                        lastSegmentIsLine = true
                        continue
                    }
                }
                finishContour(close: true, currIsLine: lastSegmentIsLine)
            }
        }
        return finish(isLine: lastSegmentIsLine)
    }

    private mutating func moveTo(_ p: GPoint) {
        if segmentCount > 0 {
            finishContour(close: false, currIsLine: false)
        }
        segmentCount = 0
        firstPt = p
        prevPt = p
        joinCompleted = false
    }

    private mutating func lineTo(_ p: GPoint, iter: GPathSegmentsIter?) {
        let teeny = prevPt.equalsWithinTolerance(p, GaneshConstants.scalarNearlyZero * invResScale)
        if capMode == .butt && teeny { return }
        if teeny && (joinCompleted || iter?.hasValidTangent() == true) { return }
        var normal = GPoint.zero
        var unitNormal = GPoint.zero
        guard preJoinTo(p, currIsLine: true, normal: &normal, unitNormal: &unitNormal) else { return }
        outer.lineTo(p.x + normal.x, p.y + normal.y)
        inner.lineTo(p.x - normal.x, p.y - normal.y)
        postJoinTo(p, normal: normal, unitNormal: unitNormal)
    }

    private mutating func quadTo(_ p1: GPoint, _ p2: GPoint) {
        let quad = (prevPt, p1, p2)
        let (reduction, rType) = checkQuadLinear(quad)
        if rType == .point || rType == .line {
            lineTo(p2, iter: nil)
            return
        }
        if rType == .degenerate {
            lineTo(reduction, iter: nil)
            let saved = joinMode
            joinMode = .round
            lineTo(p2, iter: nil)
            joinMode = saved
            return
        }
        var normalAB = GPoint.zero, unitAB = GPoint.zero
        var normalBC = GPoint.zero, unitBC = GPoint.zero
        guard preJoinTo(p1, currIsLine: false, normal: &normalAB, unitNormal: &unitAB) else {
            lineTo(p2, iter: nil)
            return
        }
        var qp = GQuadConstruct()
        initQuad(.outer, 0, 1, &qp)
        _ = quadStroke(quad, &qp)
        initQuad(.inner, 0, 1, &qp)
        _ = quadStroke(quad, &qp)
        if !setNormalUnitNormal(quad.1, quad.2, scale: resScale, radius: radius, normal: &normalBC, unitNormal: &unitBC) {
            normalBC = normalAB
            unitBC = unitAB
        }
        postJoinTo(p2, normal: normalBC, unitNormal: unitBC)
    }

    private mutating func conicTo(_ p1: GPoint, _ p2: GPoint, weight: Float) {
        let conic = (prevPt, p1, p2)
        let (reduction, rType) = checkConicLinear(conic, weight: weight)
        if rType == .point || rType == .line {
            lineTo(p2, iter: nil)
            return
        }
        if rType == .degenerate {
            lineTo(reduction, iter: nil)
            let saved = joinMode
            joinMode = .round
            lineTo(p2, iter: nil)
            joinMode = saved
            return
        }
        var normalAB = GPoint.zero, unitAB = GPoint.zero
        var normalBC = GPoint.zero, unitBC = GPoint.zero
        guard preJoinTo(p1, currIsLine: false, normal: &normalAB, unitNormal: &unitAB) else {
            lineTo(p2, iter: nil)
            return
        }
        var qp = GQuadConstruct()
        initQuad(.outer, 0, 1, &qp)
        _ = conicStroke(conic, weight: weight, quadPoints: &qp)
        initQuad(.inner, 0, 1, &qp)
        _ = conicStroke(conic, weight: weight, quadPoints: &qp)
        if !setNormalUnitNormal(conic.1, conic.2, scale: resScale, radius: radius, normal: &normalBC, unitNormal: &unitBC) {
            normalBC = normalAB
            unitBC = unitAB
        }
        postJoinTo(p2, normal: normalBC, unitNormal: unitBC)
    }

    private mutating func conicStroke(_ conic: (GPoint, GPoint, GPoint), weight: Float, quadPoints: inout GQuadConstruct) -> Bool {
        let res = compareQuadConic(conic, weight: weight, quadPoints: &quadPoints)
        if res == .quad {
            if strokeType == .outer {
                outer.quadTo(quadPoints.quad.1.x, quadPoints.quad.1.y, quadPoints.quad.2.x, quadPoints.quad.2.y)
            } else {
                inner.quadTo(quadPoints.quad.1.x, quadPoints.quad.1.y, quadPoints.quad.2.x, quadPoints.quad.2.y)
            }
            return true
        }
        if res == .degenerate {
            addDegenerateLine(quadPoints)
            return true
        }
        guard quadPoints.quad.2.x.isFinite && quadPoints.quad.2.y.isFinite else { return false }
        recursionDepth += 1
        if recursionDepth > GaneshConstants.recursiveLimits[GaneshConstants.conicRecursiveLimit] {
            addDegenerateLine(quadPoints)
            recursionDepth -= 1
            return true
        }
        var half = GQuadConstruct()
        if !half.initWithStart(quadPoints) {
            addDegenerateLine(quadPoints)
            recursionDepth -= 1
            return true
        }
        if !conicStroke(conic, weight: weight, quadPoints: &half) { return false }
        if !half.initWithEnd(quadPoints) {
            addDegenerateLine(quadPoints)
            recursionDepth -= 1
            return true
        }
        if !conicStroke(conic, weight: weight, quadPoints: &half) { return false }
        recursionDepth -= 1
        return true
    }

    private func compareQuadConic(_ conic: (GPoint, GPoint, GPoint), weight: Float, quadPoints: inout GQuadConstruct) -> GResultType {
        if !quadPoints.startSet {
            var start = GPoint.zero
            var tStart = quadPoints.tangentStart
            var q0 = quadPoints.quad.0
            conicPerpRay(conic, weight: weight, t: quadPoints.startT, tp: &start, onP: &q0, tangent: &tStart)
            quadPoints.quad.0 = q0
            quadPoints.tangentStart = tStart
            quadPoints.startSet = true
        }
        if !quadPoints.endSet {
            var end = GPoint.zero
            var tEnd = quadPoints.tangentEnd
            var q2 = quadPoints.quad.2
            conicPerpRay(conic, weight: weight, t: quadPoints.endT, tp: &end, onP: &q2, tangent: &tEnd)
            quadPoints.quad.2 = q2
            quadPoints.tangentEnd = tEnd
            quadPoints.endSet = true
        }
        let res = intersectRay(.ctrlPt, &quadPoints)
        if res != .quad { return res }
        var ray0 = GPoint.zero, ray1 = GPoint.zero
        conicPerpRay(conic, weight: weight, t: quadPoints.midT, tp: &ray1, onP: &ray0)
        return strokeCloseEnough(quadPoints.quad, ray: (ray0, ray1), quadPoints: quadPoints)
    }

    private func conicPerpRay(_ conic: (GPoint, GPoint, GPoint), weight: Float, t: Float, tp: inout GPoint, onP: inout GPoint, tangent: inout GPoint) {
        tp = conicEval(conic, weight: weight, t: t)
        var dxy = conicEvalTangent(conic, weight: weight, t: t)
        if dxy.isZero { dxy = conic.2 - conic.0 }
        setRayPoints(tp, dxy: &dxy, onP: &onP, tangent: &tangent)
    }

    private func conicPerpRay(_ conic: (GPoint, GPoint, GPoint), weight: Float, t: Float, tp: inout GPoint, onP: inout GPoint) {
        tp = conicEval(conic, weight: weight, t: t)
        var dxy = conicEvalTangent(conic, weight: weight, t: t)
        if dxy.isZero { dxy = conic.2 - conic.0 }
        var unused = GPoint.zero
        setRayPoints(tp, dxy: &dxy, onP: &onP, tangent: &unused, writeTangent: false)
    }

    private mutating func cubicTo(_ pt1: GPoint, _ pt2: GPoint, _ pt3: GPoint) {
        let cubic = (prevPt, pt1, pt2, pt3)
        var reduction = [GPoint.zero, .zero, .zero]
        var tangentPt = GPoint.zero
        let rType = checkCubicLinear(cubic, reduction: &reduction, tangentPt: &tangentPt)
        if rType == .point || rType == .line {
            lineTo(pt3, iter: nil)
            return
        }
        if rType >= .degenerate && rType <= .degenerate3 {
            lineTo(reduction[0], iter: nil)
            let saved = joinMode
            joinMode = .round
            if rType >= .degenerate2 { lineTo(reduction[1], iter: nil) }
            if rType == .degenerate3 { lineTo(reduction[2], iter: nil) }
            lineTo(pt3, iter: nil)
            joinMode = saved
            return
        }
        var normalAB = GPoint.zero, unitAB = GPoint.zero
        var normalCD = GPoint.zero, unitCD = GPoint.zero
        guard preJoinTo(tangentPt, currIsLine: false, normal: &normalAB, unitNormal: &unitAB) else {
            lineTo(pt3, iter: nil)
            return
        }
        let inflections = GPathGeometry.findCubicInflections(cubic.0, cubic.1, cubic.2, cubic.3)
        var lastT: Float = 0
        for index in 0...inflections.count {
            let nextT = index < inflections.count ? gBound(inflections[index], 0, 1) : 1.0
            var qp = GQuadConstruct()
            initQuad(.outer, lastT, nextT, &qp)
            _ = cubicStroke(cubic, &qp)
            initQuad(.inner, lastT, nextT, &qp)
            _ = cubicStroke(cubic, &qp)
            lastT = nextT
        }
        if let cusp = GPathGeometry.findCubicCusp(cubic.0, cubic.1, cubic.2, cubic.3) {
            let loc = GPathGeometry.evalCubicPosAt(cubic.0, cubic.1, cubic.2, cubic.3, t: gBound(cusp, 0, 1))
            cusper.pushCircle(x: loc.x, y: loc.y, r: radius)
        }
        setCubicEndNormal(cubic, normalAB: normalAB, unitNormalAB: unitAB, normalCD: &normalCD, unitNormalCD: &unitCD)
        postJoinTo(pt3, normal: normalCD, unitNormal: unitCD)
    }

    private mutating func cubicStroke(_ cubic: (GPoint, GPoint, GPoint, GPoint), _ quadPoints: inout GQuadConstruct) -> Bool {
        if !foundTangents {
            let res = tangentsMeet(cubic, &quadPoints)
            if res != .quad {
                let ok = pointsWithinDist(quadPoints.quad.0, quadPoints.quad.2, limit: invResScale)
                if (res == .degenerate || ok) && cubicMidOnLine(cubic, &quadPoints) {
                    addDegenerateLine(quadPoints)
                    return true
                }
            } else {
                foundTangents = true
            }
        }
        if foundTangents {
            let res = compareQuadCubic(cubic, &quadPoints)
            if res == .quad {
                let s = quadPoints.quad
                if strokeType == .outer {
                    outer.quadTo(s.1.x, s.1.y, s.2.x, s.2.y)
                } else {
                    inner.quadTo(s.1.x, s.1.y, s.2.x, s.2.y)
                }
                return true
            }
            if res == .degenerate && !quadPoints.oppositeTangents {
                addDegenerateLine(quadPoints)
                return true
            }
        }
        guard quadPoints.quad.2.x.isFinite else { return false }
        recursionDepth += 1
        if recursionDepth > GaneshConstants.recursiveLimits[foundTangents ? 1 : 0] {
            addDegenerateLine(quadPoints)
            recursionDepth -= 1
            return true
        }
        var half = GQuadConstruct()
        if !half.initWithStart(quadPoints) {
            addDegenerateLine(quadPoints)
            recursionDepth -= 1
            return true
        }
        if !cubicStroke(cubic, &half) { return false }
        if !half.initWithEnd(quadPoints) {
            addDegenerateLine(quadPoints)
            recursionDepth -= 1
            return true
        }
        if !cubicStroke(cubic, &half) { return false }
        recursionDepth -= 1
        return true
    }

    private func cubicMidOnLine(_ cubic: (GPoint, GPoint, GPoint, GPoint), _ quadPoints: inout GQuadConstruct) -> Bool {
        var strokeMid = GPoint.zero
        var cubicMidPt = GPoint.zero
        var unused = GPoint.zero
        cubicPerpRay(cubic, t: quadPoints.midT, tPt: &cubicMidPt, onPt: &strokeMid, tangent: &unused, writeTangent: false)
        return ptToLine(strokeMid, quadPoints.quad.0, quadPoints.quad.2) < invResScaleSquared
    }

    private func cubicPerpRay(
        _ cubic: (GPoint, GPoint, GPoint, GPoint),
        t: Float,
        tPt: inout GPoint,
        onPt: inout GPoint,
        tangent: inout GPoint,
        writeTangent: Bool = true
    ) {
        tPt = GPathGeometry.evalCubicPosAt(cubic.0, cubic.1, cubic.2, cubic.3, t: t)
        var dxy = GPathGeometry.evalCubicTangentAt(cubic.0, cubic.1, cubic.2, cubic.3, t: t)
        if dxy.x == 0 && dxy.y == 0 {
            var c0 = cubic.0, c3 = cubic.3
            if gScalarIsNearlyZero(t) {
                dxy = cubic.2 - cubic.0
            } else if gScalarIsNearlyZero(1.0 - t) {
                dxy = cubic.3 - cubic.1
            } else {
                let chopped = GPathGeometry.chopCubicAt2(cubic, t: gBound(t, Float.ulpOfOne, 1.0 - Float.ulpOfOne))
                dxy = chopped.3 - chopped.2
                if dxy.x == 0 && dxy.y == 0 {
                    dxy = chopped.3 - chopped.1
                    c0 = chopped.0
                    c3 = chopped.3
                }
            }
            if dxy.x == 0 && dxy.y == 0 { dxy = c3 - c0 }
        }
        setRayPoints(tPt, dxy: &dxy, onP: &onPt, tangent: &tangent, writeTangent: writeTangent)
    }

    private func setCubicEndNormal(
        _ cubic: (GPoint, GPoint, GPoint, GPoint),
        normalAB: GPoint,
        unitNormalAB: GPoint,
        normalCD: inout GPoint,
        unitNormalCD: inout GPoint
    ) {
        var ab = cubic.1 - cubic.0
        var cd = cubic.3 - cubic.2
        var degenAB = !ab.canNormalize
        var degenCD = !cd.canNormalize
        if degenAB && degenCD {
            normalCD = normalAB; unitNormalCD = unitNormalAB; return
        }
        if degenAB {
            ab = cubic.2 - cubic.0
            degenAB = !ab.canNormalize
        }
        if degenCD {
            cd = cubic.3 - cubic.1
            degenCD = !cd.canNormalize
        }
        if degenAB || degenCD {
            normalCD = normalAB; unitNormalCD = unitNormalAB; return
        }
        _ = setNormalUnitNormal2(cd, radius: radius, normal: &normalCD, unitNormal: &unitNormalCD)
    }

    private func compareQuadCubic(_ cubic: (GPoint, GPoint, GPoint, GPoint), _ quadPoints: inout GQuadConstruct) -> GResultType {
        cubicQuadEnds(cubic, &quadPoints)
        let res = intersectRay(.ctrlPt, &quadPoints)
        if res != .quad { return res }
        var ray0 = GPoint.zero, ray1 = GPoint.zero, unused = GPoint.zero
        cubicPerpRay(cubic, t: quadPoints.midT, tPt: &ray1, onPt: &ray0, tangent: &unused, writeTangent: false)
        return strokeCloseEnough(quadPoints.quad, ray: (ray0, ray1), quadPoints: quadPoints)
    }

    private func cubicQuadEnds(_ cubic: (GPoint, GPoint, GPoint, GPoint), _ quadPoints: inout GQuadConstruct) {
        if !quadPoints.startSet {
            var unused = GPoint.zero
            var q0 = quadPoints.quad.0, t0 = quadPoints.tangentStart
            cubicPerpRay(cubic, t: quadPoints.startT, tPt: &unused, onPt: &q0, tangent: &t0)
            quadPoints.quad.0 = q0; quadPoints.tangentStart = t0; quadPoints.startSet = true
        }
        if !quadPoints.endSet {
            var unused = GPoint.zero
            var q2 = quadPoints.quad.2, t2 = quadPoints.tangentEnd
            cubicPerpRay(cubic, t: quadPoints.endT, tPt: &unused, onPt: &q2, tangent: &t2)
            quadPoints.quad.2 = q2; quadPoints.tangentEnd = t2; quadPoints.endSet = true
        }
    }

    private mutating func finishContour(close: Bool, currIsLine: Bool) {
        if segmentCount > 0 {
            if close {
                applyJoin(
                    beforeUnitNormal: prevUnitNormal,
                    pivot: prevPt,
                    afterUnitNormal: firstUnitNormal,
                    prevIsLine: prevIsLine,
                    currIsLine: currIsLine
                )
                outer.close()
                let pt = inner.lastPoint ?? .zero
                outer.moveTo(pt.x, pt.y)
                outer.reversePathTo(inner)
                outer.close()
            } else {
                let pt = inner.lastPoint ?? .zero
                applyCap(pivot: prevPt, normal: prevNormal, stop: pt, hasOtherPath: currIsLine)
                outer.reversePathTo(inner)
                applyCap(pivot: firstPt, normal: -firstNormal, stop: firstOuterPt, hasOtherPath: prevIsLine)
                outer.close()
            }
            if !cusper.isEmpty {
                outer.pushPathBuilder(cusper)
                cusper.clear()
            }
        }
        inner.clear()
        segmentCount = -1
        firstOuterPtIndexInContour = outer.points.count
    }

    private mutating func preJoinTo(_ p: GPoint, currIsLine: Bool, normal: inout GPoint, unitNormal: inout GPoint) -> Bool {
        let normalSet = setNormalUnitNormal(prevPt, p, scale: resScale, radius: radius, normal: &normal, unitNormal: &unitNormal)
        if !normalSet {
            if capMode == .butt { return false }
            normal = GPoint(x: radius, y: 0)
            unitNormal = GPoint(x: 1, y: 0)
        }
        if segmentCount == 0 {
            firstNormal = normal
            firstUnitNormal = unitNormal
            firstOuterPt = GPoint(x: prevPt.x + normal.x, y: prevPt.y + normal.y)
            outer.moveTo(firstOuterPt.x, firstOuterPt.y)
            inner.moveTo(prevPt.x - normal.x, prevPt.y - normal.y)
        } else {
            applyJoin(
                beforeUnitNormal: prevUnitNormal,
                pivot: prevPt,
                afterUnitNormal: unitNormal,
                prevIsLine: prevIsLine,
                currIsLine: currIsLine
            )
        }
        prevIsLine = currIsLine
        return true
    }

    private mutating func postJoinTo(_ p: GPoint, normal: GPoint, unitNormal: GPoint) {
        joinCompleted = true
        prevPt = p
        prevUnitNormal = unitNormal
        prevNormal = normal
        segmentCount += 1
    }

    private mutating func initQuad(_ type: GStrokeType, _ start: Float, _ end: Float, _ qp: inout GQuadConstruct) {
        strokeType = type
        foundTangents = false
        _ = qp.initRange(start, end)
    }

    private mutating func quadStroke(_ quad: (GPoint, GPoint, GPoint), _ quadPoints: inout GQuadConstruct) -> Bool {
        let res = compareQuadQuad(quad, &quadPoints)
        if res == .quad {
            if strokeType == .outer {
                outer.quadTo(quadPoints.quad.1.x, quadPoints.quad.1.y, quadPoints.quad.2.x, quadPoints.quad.2.y)
            } else {
                inner.quadTo(quadPoints.quad.1.x, quadPoints.quad.1.y, quadPoints.quad.2.x, quadPoints.quad.2.y)
            }
            return true
        }
        if res == .degenerate {
            addDegenerateLine(quadPoints)
            return true
        }
        guard quadPoints.quad.2.x.isFinite && quadPoints.quad.2.y.isFinite else { return false }
        recursionDepth += 1
        if recursionDepth > GaneshConstants.recursiveLimits[GaneshConstants.quadRecursiveLimit] {
            addDegenerateLine(quadPoints)
            recursionDepth -= 1
            return true
        }
        var half = GQuadConstruct()
        if !half.initWithStart(quadPoints) {
            addDegenerateLine(quadPoints)
            recursionDepth -= 1
            return true
        }
        if !quadStroke(quad, &half) { return false }
        if !half.initWithEnd(quadPoints) {
            addDegenerateLine(quadPoints)
            recursionDepth -= 1
            return true
        }
        if !quadStroke(quad, &half) { return false }
        recursionDepth -= 1
        return true
    }

    private func compareQuadQuad(_ quad: (GPoint, GPoint, GPoint), _ quadPoints: inout GQuadConstruct) -> GResultType {
        if !quadPoints.startSet {
            var unused = GPoint.zero
            var q0 = quadPoints.quad.0, t0 = quadPoints.tangentStart
            quadPerpRay(quad, t: quadPoints.startT, tp: &unused, onP: &q0, tangent: &t0)
            quadPoints.quad.0 = q0; quadPoints.tangentStart = t0; quadPoints.startSet = true
        }
        if !quadPoints.endSet {
            var unused = GPoint.zero
            var q2 = quadPoints.quad.2, t2 = quadPoints.tangentEnd
            quadPerpRay(quad, t: quadPoints.endT, tp: &unused, onP: &q2, tangent: &t2)
            quadPoints.quad.2 = q2; quadPoints.tangentEnd = t2; quadPoints.endSet = true
        }
        let res = intersectRay(.ctrlPt, &quadPoints)
        if res != .quad { return res }
        var ray0 = GPoint.zero, ray1 = GPoint.zero, unused = GPoint.zero
        quadPerpRay(quad, t: quadPoints.midT, tp: &ray1, onP: &ray0, tangent: &unused, writeTangent: false)
        return strokeCloseEnough(quadPoints.quad, ray: (ray0, ray1), quadPoints: quadPoints)
    }

    private func setRayPoints(_ tp: GPoint, dxy: inout GPoint, onP: inout GPoint, tangent: inout GPoint, writeTangent: Bool = true) {
        if !dxy.setLength(radius) {
            dxy = GPoint(x: radius, y: 0)
        }
        let axisFlip = Float(strokeType.rawValue)
        onP.x = tp.x + axisFlip * dxy.y
        onP.y = tp.y - axisFlip * dxy.x
        if writeTangent { tangent = dxy }
    }

    private func quadPerpRay(_ quad: (GPoint, GPoint, GPoint), t: Float, tp: inout GPoint, onP: inout GPoint, tangent: inout GPoint, writeTangent: Bool = true) {
        tp = GPathGeometry.evalQuadAt(quad.0, quad.1, quad.2, t: t)
        var dxy = GPathGeometry.evalQuadTangentAt(quad.0, quad.1, quad.2, t: t)
        if dxy.isZero { dxy = quad.2 - quad.0 }
        setRayPoints(tp, dxy: &dxy, onP: &onP, tangent: &tangent, writeTangent: writeTangent)
    }

    private mutating func addDegenerateLine(_ qp: GQuadConstruct) {
        if strokeType == .outer {
            outer.lineTo(qp.quad.2.x, qp.quad.2.y)
        } else {
            inner.lineTo(qp.quad.2.x, qp.quad.2.y)
        }
    }

    private func strokeCloseEnough(_ stroke: (GPoint, GPoint, GPoint), ray: (GPoint, GPoint), quadPoints: GQuadConstruct) -> GResultType {
        let strokeMid = GPathGeometry.evalQuadAt(stroke.0, stroke.1, stroke.2, t: 0.5)
        if pointsWithinDist(ray.0, strokeMid, limit: invResScale) {
            return sharpAngle(quadPoints.quad) ? .split : .quad
        }
        if !ptInQuadBounds(stroke, pt: ray.0, invResScale: invResScale) { return .split }
        var roots = [Float](repeating: 0, count: 3)
        let rootCount = intersectQuadRay(line: ray, quad: stroke, roots: &roots)
        if rootCount != 1 { return .split }
        let tRoot = gBound(roots[0], 0, 1)
        let quadPt = GPathGeometry.evalQuadAt(stroke.0, stroke.1, stroke.2, t: tRoot)
        let error = invResScale * (1.0 - abs(roots[0] - 0.5) * 2.0)
        if pointsWithinDist(ray.0, quadPt, limit: error) {
            return sharpAngle(quadPoints.quad) ? .split : .quad
        }
        return .split
    }

    private func intersectRay(_ type: GIntersectRayType, _ qp: inout GQuadConstruct) -> GResultType {
        let start = qp.quad.0
        let end = qp.quad.2
        let aLen = qp.tangentStart
        let bLen = qp.tangentEnd
        let denom = aLen.cross(bLen)
        if denom == 0 || !denom.isFinite {
            qp.oppositeTangents = aLen.dot(bLen) < 0
            return .degenerate
        }
        qp.oppositeTangents = false
        let ab0 = start - end
        var numerA = bLen.cross(ab0)
        let numerB = aLen.cross(ab0)
        if (numerA >= 0) == (numerB >= 0) {
            let dist1 = ptToTangentLine(start, lineStart: end, tangent: qp.tangentEnd)
            let dist2 = ptToTangentLine(end, lineStart: start, tangent: qp.tangentStart)
            return max(dist1, dist2) <= invResScaleSquared ? .degenerate : .split
        }
        numerA /= denom
        if numerA > numerA - 1.0 {
            if type == .ctrlPt {
                qp.quad.1.x = start.x + qp.tangentStart.x * numerA
                qp.quad.1.y = start.y + qp.tangentStart.y * numerA
            }
            return .quad
        }
        qp.oppositeTangents = aLen.dot(bLen) < 0
        return .degenerate
    }

    private func tangentsMeet(_ cubic: (GPoint, GPoint, GPoint, GPoint), _ qp: inout GQuadConstruct) -> GResultType {
        cubicQuadEnds(cubic, &qp)
        return intersectRay(.resultType, &qp)
    }

    private mutating func finish(isLine: Bool) -> GPath? {
        finishContour(close: false, currIsLine: isLine)
        let result = outer.finish()
        outer = GPathBuilder()
        return result
    }

    // MARK: Caps & Joins

    private mutating func applyCap(pivot: GPoint, normal: GPoint, stop: GPoint, hasOtherPath: Bool) {
        switch capMode {
        case .butt:
            outer.lineTo(stop.x, stop.y)
        case .round:
            var parallel = normal
            parallel.rotateCW()
            let projectedCenter = pivot + parallel
            let c1 = projectedCenter + normal
            let c2 = projectedCenter - normal
            outer.conicTo(c1.x, c1.y, projectedCenter.x, projectedCenter.y, GaneshConstants.scalarRoot2Over2)
            outer.conicTo(c2.x, c2.y, stop.x, stop.y, GaneshConstants.scalarRoot2Over2)
        case .square:
            var parallel = normal
            parallel.rotateCW()
            if hasOtherPath {
                outer.setLastPoint(GPoint(x: pivot.x + normal.x + parallel.x, y: pivot.y + normal.y + parallel.y))
                outer.lineTo(pivot.x - normal.x + parallel.x, pivot.y - normal.y + parallel.y)
            } else {
                outer.lineTo(pivot.x + normal.x + parallel.x, pivot.y + normal.y + parallel.y)
                outer.lineTo(pivot.x - normal.x + parallel.x, pivot.y - normal.y + parallel.y)
                outer.lineTo(stop.x, stop.y)
            }
        }
    }

    private mutating func applyJoin(
        beforeUnitNormal: GPoint,
        pivot: GPoint,
        afterUnitNormal: GPoint,
        prevIsLine: Bool,
        currIsLine: Bool
    ) {
        let isCW = beforeUnitNormal.x * afterUnitNormal.y > beforeUnitNormal.y * afterUnitNormal.x
        let handleInnerJoin: (GPoint, GPoint, inout GPathBuilder) -> Void = { pivot, after, innerBuilder in
            innerBuilder.lineTo(pivot.x, pivot.y)
            innerBuilder.lineTo(pivot.x - after.x, pivot.y - after.y)
        }

        switch joinMode {
        case .bevel:
            var after = afterUnitNormal.scaled(radius)
            if !isCW {
                after = -after
            }
            if isCW {
                outer.lineTo(pivot.x + after.x, pivot.y + after.y)
                handleInnerJoin(pivot, after, &inner)
            } else {
                // `after` already negated
                inner.lineTo(pivot.x + after.x, pivot.y + after.y)
                handleInnerJoin(pivot, after, &outer)
            }
        case .round:
            let dotProd = beforeUnitNormal.dot(afterUnitNormal)
            if dotToAngleType(dotProd) == .nearlyLine { return }
            var before = beforeUnitNormal
            var after = afterUnitNormal
            var dir: GPathDirection = .cw
            if !isCW {
                before = -before
                after = -after
                dir = .ccw
            }
            let ts = GTransform(xx: radius, xy: 0, yx: 0, yy: radius, tx: pivot.x, ty: pivot.y)
            let conics = GConic.buildUnitArc(uStart: before, uStop: after, dir: dir, userTransform: ts)
            if !conics.isEmpty {
                if isCW {
                    for c in conics { outer.conicTo(c.points.1.x, c.points.1.y, c.points.2.x, c.points.2.y, c.weight) }
                    after.scale(radius)
                    handleInnerJoin(pivot, after, &inner)
                } else {
                    for c in conics { inner.conicTo(c.points.1.x, c.points.1.y, c.points.2.x, c.points.2.y, c.weight) }
                    after.scale(radius)
                    handleInnerJoin(pivot, after, &outer)
                }
            }
        case .miter, .miterClip:
            let miterClip = (joinMode == .miterClip)
            miterJoinInner(
                beforeUnitNormal: beforeUnitNormal,
                pivot: pivot,
                afterUnitNormal: afterUnitNormal,
                miterClip: miterClip,
                prevIsLine: prevIsLine,
                currIsLine: currIsLine
            )
        }
    }

    private mutating func miterJoinInner(
        beforeUnitNormal: GPoint,
        pivot: GPoint,
        afterUnitNormal: GPoint,
        miterClip: Bool,
        prevIsLine: Bool,
        currIsLine inCurrIsLine: Bool
    ) {
        var currIsLine = inCurrIsLine
        let dotProd = beforeUnitNormal.dot(afterUnitNormal)
        let angleType = dotToAngleType(dotProd)
        if angleType == .nearlyLine { return }

        var before = beforeUnitNormal
        var after = afterUnitNormal
        var swapped = false

        func emitBluntOrClipped(mid: GPoint, useOuterForOuter: Bool) {
            let afterScaled = after.scaled(radius)
            func emit(_ outB: inout GPathBuilder, _ inB: inout GPathBuilder) {
                if miterClip {
                    var midN = mid
                    _ = midN.normalize()
                    let cosBeta = before.dot(midN)
                    let sinBeta = before.cross(midN)
                    let x = abs(sinBeta) <= GaneshConstants.scalarNearlyZero
                        ? (1.0 / invMiterLimit)
                        : (((1.0 / invMiterLimit) - cosBeta) / sinBeta)
                    let beforeScaled = before.scaled(radius)
                    var beforeTan = beforeScaled; beforeTan.rotateCW()
                    var afterTan = afterScaled; afterTan.rotateCCW()
                    let c1 = pivot + beforeScaled + beforeTan.scaled(x)
                    let c2 = pivot + afterScaled + afterTan.scaled(x)
                    if prevIsLine { outB.setLastPoint(c1) } else { outB.lineTo(c1.x, c1.y) }
                    outB.lineTo(c2.x, c2.y)
                }
                if !currIsLine { outB.lineTo(pivot.x + afterScaled.x, pivot.y + afterScaled.y) }
                inB.lineTo(pivot.x, pivot.y)
                inB.lineTo(pivot.x - afterScaled.x, pivot.y - afterScaled.y)
            }
            if useOuterForOuter { emit(&outer, &inner) } else { emit(&inner, &outer) }
            _ = afterScaled
        }

        func emitMiter(mid: GPoint, useOuterForOuter: Bool) {
            let afterScaled = after.scaled(radius)
            func emit(_ outB: inout GPathBuilder, _ inB: inout GPathBuilder) {
                if prevIsLine {
                    outB.setLastPoint(GPoint(x: pivot.x + mid.x, y: pivot.y + mid.y))
                } else {
                    outB.lineTo(pivot.x + mid.x, pivot.y + mid.y)
                }
                if !currIsLine { outB.lineTo(pivot.x + afterScaled.x, pivot.y + afterScaled.y) }
                inB.lineTo(pivot.x, pivot.y)
                inB.lineTo(pivot.x - afterScaled.x, pivot.y - afterScaled.y)
            }
            if useOuterForOuter { emit(&outer, &inner) } else { emit(&inner, &outer) }
        }

        if angleType == .nearly180 {
            currIsLine = false
            let mid = (after - before).scaled(radius * 0.5)
            emitBluntOrClipped(mid: mid, useOuterForOuter: true)
            return
        }

        let ccw = !(before.x * after.y > before.y * after.x)
        if ccw {
            swapped = true
            before = -before
            after = -after
        }

        if dotProd == 0 && invMiterLimit <= GaneshConstants.scalarRoot2Over2 {
            let mid = (before + after).scaled(radius)
            emitMiter(mid: mid, useOuterForOuter: !swapped)
            return
        }

        var mid: GPoint
        if angleType == .sharp {
            mid = GPoint(x: after.y - before.y, y: before.x - after.x)
            if ccw { mid = -mid }
        } else {
            mid = GPoint(x: before.x + after.x, y: before.y + after.y)
        }

        let sinHalfAngle = ((1.0 + dotProd) * 0.5).squareRoot()
        if sinHalfAngle < invMiterLimit {
            currIsLine = false
            emitBluntOrClipped(mid: mid, useOuterForOuter: !swapped)
            return
        }
        _ = mid.setLength(radius / sinHalfAngle)
        emitMiter(mid: mid, useOuterForOuter: !swapped)
    }

    private func dotToAngleType(_ dot: Float) -> GAngleType {
        if dot >= 0 {
            return gScalarIsNearlyZero(1.0 - dot) ? .nearlyLine : .shallow
        } else {
            return gScalarIsNearlyZero(1.0 + dot) ? .nearly180 : .sharp
        }
    }

    private func setNormalUnitNormal(_ before: GPoint, _ after: GPoint, scale: Float, radius: Float, normal: inout GPoint, unitNormal: inout GPoint) -> Bool {
        guard unitNormal.setNormalize((after.x - before.x) * scale, (after.y - before.y) * scale) else { return false }
        unitNormal.rotateCCW()
        normal = unitNormal.scaled(radius)
        return true
    }

    private func setNormalUnitNormal2(_ vec: GPoint, radius: Float, normal: inout GPoint, unitNormal: inout GPoint) -> Bool {
        guard unitNormal.setNormalize(vec.x, vec.y) else { return false }
        unitNormal.rotateCCW()
        normal = unitNormal.scaled(radius)
        return true
    }

    private func checkQuadLinear(_ quad: (GPoint, GPoint, GPoint)) -> (GPoint, GReductionType) {
        let degenAB = !(quad.1 - quad.0).canNormalize
        let degenBC = !(quad.2 - quad.1).canNormalize
        if degenAB && degenBC { return (.zero, .point) }
        if degenAB || degenBC { return (.zero, .line) }
        if !quadInLine(quad) { return (.zero, .quad) }
        let t = GPathGeometry.findQuadMaxCurvature(quad.0, quad.1, quad.2)
        if t == 0 || t == 1 { return (.zero, .line) }
        return (GPathGeometry.evalQuadAt(quad.0, quad.1, quad.2, t: t), .degenerate)
    }

    private func checkConicLinear(_ conic: (GPoint, GPoint, GPoint), weight: Float) -> (GPoint, GReductionType) {
        let degenAB = !(conic.1 - conic.0).canNormalize
        let degenBC = !(conic.2 - conic.1).canNormalize
        if degenAB && degenBC { return (.zero, .point) }
        if degenAB || degenBC { return (.zero, .line) }
        if !quadInLine(conic) { return (.zero, .quad) }
        let t = GPathGeometry.findQuadMaxCurvature(conic.0, conic.1, conic.2)
        if t == 0 || t.isNaN { return (.zero, .line) }
        return (conicEval(conic, weight: weight, t: t), .degenerate)
    }

    private func conicEval(_ conic: (GPoint, GPoint, GPoint), weight: Float, t: Float) -> GPoint {
        let p0 = conic.0, p1 = conic.1, p2 = conic.2
        let p1w = GPoint(x: p1.x * weight, y: p1.y * weight)
        let a = GPoint(x: p2.x - (p1w.x + p1w.x) + p0.x, y: p2.y - (p1w.y + p1w.y) + p0.y)
        let b = GPoint(x: (p1w.x - p0.x) * 2.0, y: (p1w.y - p0.y) * 2.0)
        let db = (weight - 1.0) * 2.0
        let da = -db
        let numer = GPoint(x: (a.x * t + b.x) * t + p0.x, y: (a.y * t + b.y) * t + p0.y)
        let denom = (da * t + db) * t + 1.0
        return GPoint(x: numer.x / denom, y: numer.y / denom)
    }

    private func conicEvalTangent(_ conic: (GPoint, GPoint, GPoint), weight: Float, t: Float) -> GPoint {
        let p0 = conic.0, p1 = conic.1, p2 = conic.2
        if (t == 0 && p0 == p1) || (t == 1 && p1 == p2) { return p2 - p0 }
        let p20 = p2 - p0, p10 = p1 - p0
        let c = GPoint(x: weight * p10.x, y: weight * p10.y)
        let a = GPoint(x: weight * p20.x - p20.x, y: weight * p20.y - p20.y)
        let b = GPoint(x: p20.x - c.x - c.x, y: p20.y - c.y - c.y)
        return GPoint(x: (a.x * t + b.x) * t + c.x, y: (a.y * t + b.y) * t + c.y)
    }

    private func quadInLine(_ quad: (GPoint, GPoint, GPoint)) -> Bool {
        let pts = [quad.0, quad.1, quad.2]
        var ptMax: Float = -1
        var outer1 = 0, outer2 = 0
        for index in 0..<2 {
            for inner in (index + 1)..<3 {
                let d = pts[inner] - pts[index]
                let testMax = max(abs(d.x), abs(d.y))
                if ptMax < testMax {
                    outer1 = index
                    outer2 = inner
                    ptMax = testMax
                }
            }
        }
        let mid = outer1 ^ outer2 ^ 3
        let lineSlop = ptMax * ptMax * 0.000005
        return ptToLine(pts[mid], pts[outer1], pts[outer2]) <= lineSlop
    }

    private func checkCubicLinear(_ cubic: (GPoint, GPoint, GPoint, GPoint), reduction: inout [GPoint], tangentPt: inout GPoint) -> GReductionType {
        let degenAB = !(cubic.1 - cubic.0).canNormalize
        let degenBC = !(cubic.2 - cubic.1).canNormalize
        let degenCD = !(cubic.3 - cubic.2).canNormalize
        if degenAB && degenBC && degenCD { return .point }
        if (degenAB ? 1 : 0) + (degenBC ? 1 : 0) + (degenCD ? 1 : 0) == 2 { return .line }
        if !cubicInLine(cubic) {
            tangentPt = degenAB ? cubic.2 : cubic.1
            return .quad
        }
        let ts = GPathGeometry.findCubicMaxCurvature(cubic.0, cubic.1, cubic.2, cubic.3)
        var rCount = 0
        for t in ts {
            if t <= 0 || t >= 1 { continue }
            let pt = GPathGeometry.evalCubicPosAt(cubic.0, cubic.1, cubic.2, cubic.3, t: t)
            if pt != cubic.0 && pt != cubic.3 {
                reduction[rCount] = pt
                rCount += 1
            }
        }
        switch rCount {
        case 0: return .line
        case 1: return .degenerate
        case 2: return .degenerate2
        case 3: return .degenerate3
        default: return .line
        }
    }

    private func cubicInLine(_ cubic: (GPoint, GPoint, GPoint, GPoint)) -> Bool {
        let pts = [cubic.0, cubic.1, cubic.2, cubic.3]
        var ptMax: Float = -1
        var outer1 = 0, outer2 = 0
        for index in 0..<3 {
            for inner in (index + 1)..<4 {
                let d = pts[inner] - pts[index]
                let testMax = max(abs(d.x), abs(d.y))
                if ptMax < testMax {
                    outer1 = index
                    outer2 = inner
                    ptMax = testMax
                }
            }
        }
        let mid1 = (1 + (2 >> outer2)) >> outer1
        let mid2 = outer1 ^ outer2 ^ mid1
        let lineSlop = ptMax * ptMax * 0.00001
        return ptToLine(pts[mid1], pts[outer1], pts[outer2]) <= lineSlop &&
               ptToLine(pts[mid2], pts[outer1], pts[outer2]) <= lineSlop
    }

    private func ptToTangentLine(_ pt: GPoint, lineStart: GPoint, tangent: GPoint) -> Float {
        let ab0 = pt - lineStart
        let numer = tangent.dot(ab0)
        let denom = tangent.dot(tangent)
        let t = numer / denom
        if t >= 0 && t <= 1 {
            return GPoint(x: lineStart.x + tangent.x * t, y: lineStart.y + tangent.y * t).distanceToSqd(pt)
        }
        return pt.distanceToSqd(lineStart)
    }

    private func ptToLine(_ pt: GPoint, _ lineStart: GPoint, _ lineEnd: GPoint) -> Float {
        let dxy = lineEnd - lineStart
        let ab0 = pt - lineStart
        let numer = dxy.dot(ab0)
        let denom = dxy.dot(dxy)
        let t = numer / denom
        if t >= 0 && t <= 1 {
            let hit = GPoint(x: lineStart.x * (1.0 - t) + lineEnd.x * t, y: lineStart.y * (1.0 - t) + lineEnd.y * t)
            return hit.distanceToSqd(pt)
        }
        return pt.distanceToSqd(lineStart)
    }

    private func intersectQuadRay(line: (GPoint, GPoint), quad: (GPoint, GPoint, GPoint), roots: inout [Float]) -> Int {
        let vec = line.1 - line.0
        let q = [quad.0, quad.1, quad.2]
        var r = [Float](repeating: 0, count: 3)
        for n in 0..<3 {
            r[n] = (q[n].y - line.0.y) * vec.x - (q[n].x - line.0.x) * vec.y
        }
        var a = r[2]
        var b = r[1]
        let c = r[0]
        a += c - 2.0 * b
        b -= c
        return GPathGeometry.findUnitQuadRoots(a: a, b: 2.0 * b, c: c, roots: &roots)
    }

    private func pointsWithinDist(_ a: GPoint, _ b: GPoint, limit: Float) -> Bool {
        a.distanceToSqd(b) <= limit * limit
    }

    private func sharpAngle(_ quad: (GPoint, GPoint, GPoint)) -> Bool {
        var smaller = quad.1 - quad.0
        var larger = quad.1 - quad.2
        let smallerLen = smaller.lengthSqd
        var largerLen = larger.lengthSqd
        if smallerLen > largerLen {
            swap(&smaller, &larger)
            largerLen = smallerLen
        }
        if !smaller.setLength(largerLen) { return false }
        return smaller.dot(larger) > 0
    }

    private func ptInQuadBounds(_ quad: (GPoint, GPoint, GPoint), pt: GPoint, invResScale: Float) -> Bool {
        let xMin = min(quad.0.x, min(quad.1.x, quad.2.x))
        if pt.x + invResScale < xMin { return false }
        let xMax = max(quad.0.x, max(quad.1.x, quad.2.x))
        if pt.x - invResScale > xMax { return false }
        let yMin = min(quad.0.y, min(quad.1.y, quad.2.y))
        if pt.y + invResScale < yMin { return false }
        let yMax = max(quad.0.y, max(quad.1.y, quad.2.y))
        if pt.y - invResScale > yMax { return false }
        return true
    }
}

// MARK: - SVG Path Grammar (`svg_path.rs`)

internal enum GSVGPathParser {
    private struct Lexer {
        let bytes: [UInt8]
        var i: Int = 0

        var peek: UInt8? { i < bytes.count ? bytes[i] : nil }

        mutating func skipWS() {
            while let b = peek, b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C {
                i += 1
            }
        }

        mutating func skipCommaWS() {
            skipWS()
            if peek == 0x2C { // ','
                i += 1
                skipWS()
            }
        }

        var atNumber: Bool {
            guard let b = peek else { return false }
            return (b >= 0x30 && b <= 0x39) || b == 0x2E || b == 0x2D || b == 0x2B
        }

        mutating func digits() -> Int {
            let start = i
            while let b = peek, b >= 0x30 && b <= 0x39 {
                i += 1
            }
            return i - start
        }

        mutating func number() -> Float? {
            let start = i
            if peek == 0x2D || peek == 0x2B { i += 1 }
            var mantissa = digits()
            if peek == 0x2E {
                i += 1
                mantissa += digits()
            }
            if mantissa == 0 {
                i = start
                return nil
            }
            if peek == 0x65 || peek == 0x45 { // e/E
                let mark = i
                i += 1
                if peek == 0x2D || peek == 0x2B { i += 1 }
                if digits() == 0 { i = mark }
            }
            let v = blinkNumber(bytes[start..<i])
            skipCommaWS()
            return v.isFinite ? v : nil
        }

        mutating func flag() -> Bool? {
            guard let b = peek else { return nil }
            let v: Bool
            if b == 0x30 { v = false } else if b == 0x31 { v = true } else { return nil }
            i += 1
            skipCommaWS()
            return v
        }

        mutating func pair() -> GPoint? {
            guard let x = number(), let y = number() else { return nil }
            return GPoint(x: x, y: y)
        }
    }

    /// Blink `GenericParseNumber`: integer digits summed from right, decimals scaled by running 0.1.
    private static func blinkNumber(_ s: ArraySlice<UInt8>) -> Float {
        var slice = s
        var sign: Float = 1.0
        if let first = slice.first {
            if first == 0x2D { sign = -1.0; slice = slice.dropFirst() }
            else if first == 0x2B { sign = 1.0; slice = slice.dropFirst() }
        }
        let eIdx = slice.firstIndex(where: { $0 == 0x65 || $0 == 0x45 }) ?? slice.endIndex
        let mantissa = slice[..<eIdx]
        let expSlice = slice[eIdx...]
        let dotIdx = mantissa.firstIndex(of: 0x2E) ?? mantissa.endIndex
        var integer: Float = 0, mul: Float = 1
        for c in mantissa[..<dotIdx].reversed() {
            integer += mul * Float(c - 0x30)
            mul *= 10.0
        }
        var decSum: Float = 0, frac: Float = 1
        if dotIdx < mantissa.endIndex {
            for c in mantissa[mantissa.index(after: dotIdx)...] {
                frac *= 0.1
                decSum += Float(c - 0x30) * frac
            }
        }
        let number = (integer + decSum) * sign
        if expSlice.count > 1, let expStr = String(bytes: expSlice.dropFirst(), encoding: .utf8), let exp = Int(expStr), exp != 0 {
            return number * Float(pow(10.0, Double(exp)))
        }
        return number
    }

    private enum CurveKind { case cubic, quad }

    @inline(__always)
    private static func reflect(_ about: GPoint, _ of: GPoint) -> GPoint {
        GPoint(x: 2.0 * about.x - of.x, y: 2.0 * about.y - of.y)
    }

    @inline(__always)
    private static func isASCIIAlpha(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    @inline(__always)
    private static func toUpper(_ b: UInt8) -> UInt8 {
        (b >= 0x61 && b <= 0x7A) ? (b - 32) : b
    }

    static func parse(_ d: String) -> [GEl] {
        var out: [GEl] = []
        var p = Lexer(bytes: Array(d.utf8))
        var cur = GPoint.zero
        var start = GPoint.zero
        var control: (CurveKind, GPoint)? = nil
        var cmd: UInt8 = 0
        p.skipWS()
        while let c = p.peek {
            if isASCIIAlpha(c) {
                if out.isEmpty && c != 0x4D && c != 0x6D { return out }
                cmd = c
                p.i += 1
                p.skipWS()
            } else if !p.atNumber || cmd == 0 || cmd == 0x5A || cmd == 0x7A {
                return out
            }
            let rel = cmd >= 0x61 && cmd <= 0x7A
            let origin = rel ? cur : .zero
            var nextControl: (CurveKind, GPoint)? = nil
            switch toUpper(cmd) {
            case 0x4D: // 'M'
                guard let pt = p.pair() else { return out }
                cur = pt + origin
                start = cur
                out.append(.move(cur))
                cmd = rel ? 0x6C : 0x4C // l / L
            case 0x5A: // 'Z'
                out.append(.close)
                cur = start
            case 0x4C: // 'L'
                guard let pt = p.pair() else { return out }
                cur = pt + origin
                out.append(.line(cur))
            case 0x48: // 'H'
                guard let nx = p.number() else { return out }
                cur.x = nx + origin.x
                out.append(.line(cur))
            case 0x56: // 'V'
                guard let ny = p.number() else { return out }
                cur.y = ny + origin.y
                out.append(.line(cur))
            case 0x43: // 'C'
                guard let c1p = p.pair(), let c2p = p.pair(), let top = p.pair() else { return out }
                let c1 = c1p + origin, c2 = c2p + origin, to = top + origin
                out.append(.cubic(c1, c2, to))
                nextControl = (.cubic, c2)
                cur = to
            case 0x53: // 'S'
                let c1: GPoint
                if case .some((.cubic, let prev)) = control { c1 = reflect(cur, prev) } else { c1 = cur }
                guard let c2p = p.pair(), let top = p.pair() else { return out }
                let c2 = c2p + origin, to = top + origin
                out.append(.cubic(c1, c2, to))
                nextControl = (.cubic, c2)
                cur = to
            case 0x51: // 'Q'
                guard let cp = p.pair(), let top = p.pair() else { return out }
                let c = cp + origin, to = top + origin
                out.append(.quad(c, to))
                nextControl = (.quad, c)
                cur = to
            case 0x54: // 'T'
                let c: GPoint
                if case .some((.quad, let prev)) = control { c = reflect(cur, prev) } else { c = cur }
                guard let top = p.pair() else { return out }
                let to = top + origin
                out.append(.quad(c, to))
                nextControl = (.quad, c)
                cur = to
            case 0x41: // 'A'
                guard let rx = p.number(), let ry = p.number(), let angle = p.number(),
                      let large = p.flag(), let sweep = p.flag(), let top = p.pair() else { return out }
                let to = top + origin
                if rx == 0 || ry == 0 {
                    out.append(.line(to))
                } else if to != cur {
                    arcTo(&out, from: cur, rx: rx, ry: ry, angle: angle, large: large, sweep: sweep, to: to)
                }
                cur = to
            default:
                return out
            }
            control = nextControl
            p.skipCommaWS()
        }
        return out
    }

    /// `SkPath::arcTo` for an SVG arc as conics.
    private static func arcTo(_ out: inout [GEl], from: GPoint, rx inRx: Float, ry inRy: Float, angle: Float, large: Bool, sweep: Bool, to: GPoint) {
        let pi = Float.pi
        func snapToZero(_ x: Float) -> Float { abs(x) <= GaneshConstants.scalarNearlyZero ? 0 : x }
        func rotation(_ deg: Float) -> (Float, Float) {
            let rad = deg * (pi / 180.0)
            return (snapToZero(sinf(rad)), snapToZero(cosf(rad)))
        }
        func rotate(_ deg: Float, _ p: GPoint) -> GPoint {
            let (s, c) = rotation(deg)
            return GPoint(x: c * p.x - s * p.y, y: s * p.x + c * p.y)
        }
        var rx = abs(inRx), ry = abs(inRy)
        let mid = (from - to) * 0.5
        let m = rotate(-angle, mid)
        let sqRx = rx * rx, sqRy = ry * ry, sqX = m.x * m.x, sqY = m.y * m.y
        let radiiScale = sqX / sqRx + sqY / sqRy
        if radiiScale > 1.0 {
            let s = radiiScale.squareRoot()
            rx *= s
            ry *= s
        }
        func toUnit(_ p: GPoint) -> GPoint {
            let r = rotate(-angle, p)
            return GPoint(x: r.x * (1.0 / rx), y: r.y * (1.0 / ry))
        }
        var u0 = toUnit(from), u1 = toUnit(to)
        var delta = u1 - u0
        let d = delta.x * delta.x + delta.y * delta.y
        var scale = max(Float(0), 1.0 / d - 0.25).squareRoot()
        if !sweep != large { scale = -scale }
        delta = delta * scale
        var center = (u0 + u1) * 0.5
        center = GPoint(x: center.x - delta.y, y: center.y + delta.x)
        u0 = u0 - center
        u1 = u1 - center
        let theta1 = atan2f(u0.y, u0.x)
        let theta2 = atan2f(u1.y, u1.x)
        var arc = theta2 - theta1
        if arc < 0 && sweep { arc += pi * 2.0 }
        else if arc > 0 && !sweep { arc -= pi * 2.0 }
        if abs(arc) < pi / (1000.0 * 1000.0) {
            out.append(.line(to))
            return
        }
        func fromUnit(_ p: GPoint) -> GPoint {
            rotate(angle, GPoint(x: p.x * rx, y: p.y * ry))
        }
        let segments = Int(ceil(abs(arc / (2.0 * pi / 3.0))))
        let width = arc / Float(segments)
        let t = tanf(0.5 * width)
        guard t.isFinite else { return }
        let w = (0.5 + cosf(width) * 0.5).squareRoot()
        let isInt: (Float) -> Bool = { $0 == floorf($0) }
        let integers = gScalarIsNearlyZero(pi * 0.5 - abs(width)) && isInt(rx) && isInt(ry) && isInt(to.x) && isInt(to.y)
        var start = theta1
        for _ in 0..<segments {
            let end = start + width
            let sinEnd = snapToZero(sinf(end)), cosEnd = snapToZero(cosf(end))
            let endPt = GPoint(x: cosEnd, y: sinEnd) + center
            let ctrl = GPoint(x: endPt.x + t * sinEnd, y: endPt.y - t * cosEnd)
            var c = fromUnit(ctrl), e = fromUnit(endPt)
            if integers {
                c = GPoint(x: c.x.rounded(), y: c.y.rounded())
                e = GPoint(x: e.x.rounded(), y: e.y.rounded())
            }
            out.append(.conic(c, e, w))
            start = end
        }
        if let lastIdx = out.indices.last, case .conic(let c, _, let cw) = out[lastIdx] {
            out[lastIdx] = .conic(c, to, cw)
        }
    }
}
