import Foundation

/// Fixed-lane scalar conversion for values interpolated by `RuneMotion`.
///
/// Maximum lane count in `RuneMotion` is 16 (`maxLanes`); common UI types use 1..5 lanes
/// stored inline with zero heap allocation.
public struct MotionLanes: Sendable, Hashable {
    public static let maxLanes = 16

    public var l0: Float
    public var l1: Float
    public var l2: Float
    public var l3: Float
    public var l4: Float
    public var l5: Float = 0
    public var l6: Float = 0
    public var l7: Float = 0
    public var l8: Float = 0
    public var l9: Float = 0
    public var l10: Float = 0
    public var l11: Float = 0
    public var l12: Float = 0
    public var l13: Float = 0
    public var l14: Float = 0
    public var l15: Float = 0

    @inlinable
    public init(_ l0: Float = 0, _ l1: Float = 0, _ l2: Float = 0, _ l3: Float = 0, _ l4: Float = 0) {
        self.l0 = l0
        self.l1 = l1
        self.l2 = l2
        self.l3 = l3
        self.l4 = l4
    }

    @inlinable
    public subscript(index: Int) -> Float {
        get {
            switch index {
            case 0: return l0
            case 1: return l1
            case 2: return l2
            case 3: return l3
            case 4: return l4
            case 5: return l5
            case 6: return l6
            case 7: return l7
            case 8: return l8
            case 9: return l9
            case 10: return l10
            case 11: return l11
            case 12: return l12
            case 13: return l13
            case 14: return l14
            case 15: return l15
            default: return 0
            }
        }
        set {
            switch index {
            case 0: l0 = newValue
            case 1: l1 = newValue
            case 2: l2 = newValue
            case 3: l3 = newValue
            case 4: l4 = newValue
            case 5: l5 = newValue
            case 6: l6 = newValue
            case 7: l7 = newValue
            case 8: l8 = newValue
            case 9: l9 = newValue
            case 10: l10 = newValue
            case 11: l11 = newValue
            case 12: l12 = newValue
            case 13: l13 = newValue
            case 14: l14 = newValue
            case 15: l15 = newValue
            default: break
            }
        }
    }

    public static let zero = MotionLanes()
}

public protocol Animatable: Sendable, Equatable {
    static var laneCount: Int { get }
    static var zeroValue: Self { get }
    func toLanes() -> MotionLanes
    static func fromLanes(_ lanes: MotionLanes) -> Self
}

extension Animatable {
    @inlinable
    public func adding(_ other: Self) -> Self {
        let a = toLanes()
        let b = other.toLanes()
        var out = MotionLanes()
        for i in 0..<Self.laneCount { out[i] = a[i] + b[i] }
        return Self.fromLanes(out)
    }

    @inlinable
    public func subtracting(_ other: Self) -> Self {
        let a = toLanes()
        let b = other.toLanes()
        var out = MotionLanes()
        for i in 0..<Self.laneCount { out[i] = a[i] - b[i] }
        return Self.fromLanes(out)
    }

    @inlinable
    public func scaled(by k: Float) -> Self {
        let a = toLanes()
        var out = MotionLanes()
        for i in 0..<Self.laneCount { out[i] = a[i] * k }
        return Self.fromLanes(out)
    }

    @inlinable
    public func distance(to other: Self) -> Float {
        let a = toLanes()
        let b = other.toLanes()
        var sum: Float = 0
        for i in 0..<Self.laneCount {
            let d = a[i] - b[i]
            sum += d * d
        }
        return sqrtf(sum)
    }

    @inlinable
    public func lerped(to other: Self, t: Float) -> Self {
        let a = toLanes()
        let b = other.toLanes()
        var out = MotionLanes()
        for i in 0..<Self.laneCount { out[i] = a[i] + (b[i] - a[i]) * t }
        return Self.fromLanes(out)
    }
}

extension Float: Animatable {
    public static let laneCount = 1
    public static let zeroValue: Float = 0

    @inlinable
    public func toLanes() -> MotionLanes { MotionLanes(self) }

    @inlinable
    public static func fromLanes(_ lanes: MotionLanes) -> Float { lanes.l0 }
}

/// 2D vector in logical points.
public struct Vec2: Animatable, Hashable {
    public var x: Float
    public var y: Float

    public static let laneCount = 2
    public static let zeroValue = Vec2(0, 0)
    public static let zero = Vec2(0, 0)

    @inlinable
    public init(_ x: Float = 0, _ y: Float = 0) {
        self.x = x
        self.y = y
    }

    @inlinable
    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }

    @inlinable
    public func toLanes() -> MotionLanes { MotionLanes(x, y) }

    @inlinable
    public static func fromLanes(_ lanes: MotionLanes) -> Vec2 { Vec2(lanes.l0, lanes.l1) }
}

/// Rectangle animated via **four independent edges** `[left, top, right, bottom]` so stationary
/// edges never jiggle when an opposite edge moves or resizes.
public struct MotionRect: Animatable, Hashable {
    public var left: Float
    public var top: Float
    public var right: Float
    public var bottom: Float

    public static let laneCount = 4
    public static let zeroValue = MotionRect(left: 0, top: 0, right: 0, bottom: 0)
    public static let zero = zeroValue

    @inlinable
    public init(left: Float, top: Float, right: Float, bottom: Float) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    @inlinable
    public static func fromXYWH(_ x: Float, _ y: Float, _ w: Float, _ h: Float) -> MotionRect {
        MotionRect(left: x, top: y, right: x + w, bottom: y + h)
    }

    @inlinable
    public static func fromXYWH(_ r: [Float]) -> MotionRect {
        guard r.count >= 4 else { return .zero }
        return fromXYWH(r[0], r[1], r[2], r[3])
    }

    @inlinable
    public var x: Float { left }
    @inlinable
    public var y: Float { top }
    @inlinable
    public var width: Float { max(0, right - left) }
    @inlinable
    public var height: Float { max(0, bottom - top) }
    @inlinable
    public var center: Vec2 { Vec2((left + right) * 0.5, (top + bottom) * 0.5) }
    @inlinable
    public var origin: Vec2 { Vec2(left, top) }
    @inlinable
    public var size: Vec2 { Vec2(width, height) }

    @inlinable
    public var xywh: [Float] { [left, top, max(0, right - left), max(0, bottom - top)] }

    @inlinable
    public var edges: (Float, Float, Float, Float) { (left, top, right, bottom) }

    @inlinable
    public static func fromEdges(_ left: Float, _ top: Float, _ right: Float, _ bottom: Float) -> MotionRect {
        MotionRect(left: left, top: top, right: right, bottom: bottom)
    }

    @inlinable
    public func translated(_ d: Vec2) -> MotionRect {
        MotionRect(left: left + d.x, top: top + d.y, right: right + d.x, bottom: bottom + d.y)
    }

    @inlinable
    public func offsetBy(_ d: Vec2) -> MotionRect {
        MotionRect(left: left + d.x, top: top + d.y, right: right + d.x, bottom: bottom + d.y)
    }

    @inlinable
    public func inflated(by m: Float) -> MotionRect {
        MotionRect(left: left - m, top: top - m, right: right + m, bottom: bottom + m)
    }

    @inlinable
    public func union(_ other: MotionRect) -> MotionRect {
        MotionRect(
            left: min(left, other.left),
            top: min(top, other.top),
            right: max(right, other.right),
            bottom: max(bottom, other.bottom)
        )
    }

    @inlinable
    public static func fromPoints(_ a: Vec2, _ b: Vec2) -> MotionRect {
        MotionRect(
            left: min(a.x, b.x),
            top: min(a.y, b.y),
            right: max(a.x, b.x),
            bottom: max(a.y, b.y)
        )
    }

    @inlinable
    public func toLanes() -> MotionLanes {
        MotionLanes(left, top, right, bottom)
    }

    @inlinable
    public static func fromLanes(_ lanes: MotionLanes) -> MotionRect {
        MotionRect(left: lanes.l0, top: lanes.l1, right: lanes.l2, bottom: lanes.l3)
    }
}

/// Snaps a rectangle to 1/64th of a device pixel at presentation time, never mutating live springs.
@inlinable
public func snapRect(_ r: MotionRect, pixelScale: Float) -> MotionRect {
    let q = max(pixelScale, 0.001) * 64.0
    let snap: (Float) -> Float = { ( $0 * q ).rounded() / q }
    return MotionRect(
        left: snap(r.left),
        top: snap(r.top),
        right: snap(r.right),
        bottom: snap(r.bottom)
    )
}

/// Four corner radii `[topLeft, topRight, bottomRight, bottomLeft]`. Negative values encode
/// Apple continuous (squircle) corners in Rune's renderer.
public struct Corners: Animatable, Hashable {
    public var topLeft: Float
    public var topRight: Float
    public var bottomRight: Float
    public var bottomLeft: Float

    public static let laneCount = 4
    public static let zeroValue = Corners.all(0)

    @inlinable
    public init(_ topLeft: Float, _ topRight: Float, _ bottomRight: Float, _ bottomLeft: Float) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    @inlinable
    public static func all(_ r: Float) -> Corners {
        Corners(r, r, r, r)
    }

    @inlinable
    public var array: [Float] { [topLeft, topRight, bottomRight, bottomLeft] }

    @inlinable
    public var maxMagnitude: Float {
        max(abs(topLeft), abs(topRight), abs(bottomRight), abs(bottomLeft))
    }

    @inlinable
    public func toLanes() -> MotionLanes {
        MotionLanes(topLeft, topRight, bottomRight, bottomLeft)
    }

    @inlinable
    public static func fromLanes(_ lanes: MotionLanes) -> Corners {
        Corners(lanes.l0, lanes.l1, lanes.l2, lanes.l3)
    }
}

/// Four side widths/insets `[top, right, bottom, left]`.
public struct Sides: Animatable, Hashable {
    public var top: Float
    public var right: Float
    public var bottom: Float
    public var left: Float

    public static let laneCount = 4
    public static let zeroValue = Sides.all(0)

    @inlinable
    public init(top: Float, right: Float, bottom: Float, left: Float) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    @inlinable
    public static func all(_ v: Float) -> Sides {
        Sides(top: v, right: v, bottom: v, left: v)
    }

    /// Constructs `Sides` from Rust's `[left, top, right, bottom]` edge order (`value.rs::Sides`).
    @inlinable
    public static func fromEdges(left: Float, top: Float, right: Float, bottom: Float) -> Sides {
        Sides(top: top, right: right, bottom: bottom, left: left)
    }

    /// Returns edges in Rust `[left, top, right, bottom]` order.
    @inlinable
    public var edges: [Float] { [left, top, right, bottom] }

    @inlinable
    public func toLanes() -> MotionLanes {
        MotionLanes(left, top, right, bottom)
    }

    @inlinable
    public static func fromLanes(_ lanes: MotionLanes) -> Sides {
        Sides(top: lanes.l1, right: lanes.l2, bottom: lanes.l3, left: lanes.l0)
    }
}

/// Gaussian blur radius in logical points. Clamped >= 0 on readback so spring undershoot never yields negative blur.
public struct Blur: Animatable, Hashable {
    public var radius: Float

    public static let laneCount = 1
    public static let zeroValue = Blur(0)

    @inlinable
    public init(_ radius: Float = 0) {
        self.radius = max(0, radius)
    }

    @inlinable
    public func toLanes() -> MotionLanes { MotionLanes(radius) }

    @inlinable
    public static func fromLanes(_ lanes: MotionLanes) -> Blur { Blur(max(0, lanes.l0)) }
}

/// 2D decomposed transform `[tx, ty, sx, sy, rotRadians]`.
public struct Transform2D: Animatable, Hashable {
    public var tx: Float
    public var ty: Float
    public var sx: Float
    public var sy: Float
    public var rot: Float

    public static let laneCount = 5
    public static let zeroValue = Transform2D.identity
    public static let identity = Transform2D(tx: 0, ty: 0, sx: 1, sy: 1, rot: 0)

    @inlinable
    public init(tx: Float = 0, ty: Float = 0, sx: Float = 1, sy: Float = 1, rot: Float = 0) {
        self.tx = tx
        self.ty = ty
        self.sx = sx
        self.sy = sy
        self.rot = rot
    }

    /// 2x3 column-major affine matrix `[a, b, c, d, tx, ty]` applying this transform about `anchor`.
    @inlinable
    public func toAffine(anchor: Vec2) -> [Float] {
        let (s, c) = MotionMath.sinCos(rot)
        let a = c * sx
        let b = s * sx
        let cc = -s * sy
        let d = c * sy
        let ax = anchor.x + tx - (a * anchor.x + cc * anchor.y)
        let ay = anchor.y + ty - (b * anchor.x + d * anchor.y)
        return [a, b, cc, d, ax, ay]
    }

    @inlinable
    public func toLanes() -> MotionLanes {
        MotionLanes(tx, ty, sx, sy, rot)
    }

    @inlinable
    public static func fromLanes(_ lanes: MotionLanes) -> Transform2D {
        Transform2D(tx: lanes.l0, ty: lanes.l1, sx: lanes.l2, sy: lanes.l3, rot: lanes.l4)
    }
}

/// An sRGB color with straight alpha, interpolated in **premultiplied OKLab**
/// `[L*a, a*a, b*a, a]` so fading to transparent never darkens through black and hue shifts
/// don't cross muddy grey.
public struct MotionColor: Animatable, Hashable {
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float

    public static let laneCount = 4
    public static let zeroValue = MotionColor(r: 0, g: 0, b: 0, a: 0)
    public static let transparent = MotionColor(r: 0, g: 0, b: 0, a: 0)
    public static let black = MotionColor(r: 0, g: 0, b: 0, a: 1)
    public static let white = MotionColor(r: 1, g: 1, b: 1, a: 1)

    @inlinable
    public init(r: Float, g: Float, b: Float, a: Float = 1.0) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// `0xRRGGBB` with alpha 1.
    @inlinable
    public static func hex(_ rgb: UInt32) -> MotionColor {
        MotionColor(
            r: Float((rgb >> 16) & 0xff) / 255.0,
            g: Float((rgb >> 8) & 0xff) / 255.0,
            b: Float(rgb & 0xff) / 255.0,
            a: 1.0
        )
    }

    @inlinable
    public func withAlpha(_ alpha: Float) -> MotionColor {
        MotionColor(r: r, g: g, b: b, a: alpha)
    }

    @inlinable
    public static func srgbDecode(_ c: Float) -> Float {
        c <= 0.040_45 ? (c / 12.92) : powf((c + 0.055) / 1.055, 2.4)
    }

    @inlinable
    public static func srgbEncode(_ c: Float) -> Float {
        c <= 0.003_130_8 ? (c * 12.92) : (1.055 * powf(c, 1.0 / 2.4) - 0.055)
    }

    @inlinable
    public static func linearToOKLab(r: Float, g: Float, b: Float) -> (L: Float, a: Float, b: Float) {
        let rr = max(0, r)
        let gg = max(0, g)
        let bb = max(0, b)
        let l = 0.4122214708 * rr + 0.5363325363 * gg + 0.0514459929 * bb
        let m = 0.2119034982 * rr + 0.6806995451 * gg + 0.1073969566 * bb
        let s = 0.0883024619 * rr + 0.2817188376 * gg + 0.6299787005 * bb
        let l_ = cbrtf(l)
        let m_ = cbrtf(m)
        let s_ = cbrtf(s)
        return (
            L: 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            a: 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            b: 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        )
    }

    @inlinable
    public static func oklabToLinear(L: Float, a: Float, b: Float) -> (r: Float, g: Float, b: Float) {
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_
        let m = m_ * m_ * m_
        let s = s_ * s_ * s_
        return (
            r: +4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            g: -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            b: -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    @inlinable
    public func toOKLab() -> (L: Float, a: Float, b: Float) {
        Self.linearToOKLab(r: Self.srgbDecode(r), g: Self.srgbDecode(g), b: Self.srgbDecode(b))
    }

    @inlinable
    public static func fromOKLab(L: Float, a: Float, b: Float, alpha: Float) -> MotionColor {
        let lin = Self.oklabToLinear(L: L, a: a, b: b)
        return MotionColor(
            r: Self.srgbEncode(lin.r.clamped(to: 0...1)),
            g: Self.srgbEncode(lin.g.clamped(to: 0...1)),
            b: Self.srgbEncode(lin.b.clamped(to: 0...1)),
            a: alpha.clamped(to: 0...1)
        )
    }

    public func toLanes() -> MotionLanes {
        let alpha = a.clamped(to: 0...1)
        let lab = toOKLab()
        return MotionLanes(lab.L * alpha, lab.a * alpha, lab.b * alpha, alpha)
    }

    public static func fromLanes(_ lanes: MotionLanes) -> MotionColor {
        let alpha = lanes.l3.clamped(to: 0...1)
        if lanes.l3 <= 1e-6 {
            return MotionColor(r: 0, g: 0, b: 0, a: 0)
        }
        let invA = 1.0 / lanes.l3
        return fromOKLab(L: lanes.l0 * invA, a: lanes.l1 * invA, b: lanes.l2 * invA, alpha: alpha)
    }
}

extension Comparable {
    @inlinable
    public func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension MotionColor {
    /// Static `rgba` constructor matching `value.rs::Color::rgba`.
    @inlinable
    public static func rgba(_ r: Float, _ g: Float, _ b: Float, _ a: Float) -> MotionColor {
        MotionColor(r: r, g: g, b: b, a: a)
    }
}

/// Composite `Animatable` pair (`(A, B)` counterpart; Swift tuples cannot conform to protocols).
public struct AnimatablePair<A: Animatable, B: Animatable>: Animatable, Hashable where A: Hashable, B: Hashable {
    public var first: A
    public var second: B

    public static var laneCount: Int { min(MotionLanes.maxLanes, A.laneCount + B.laneCount) }
    public static var zeroValue: Self { Self(A.zeroValue, B.zeroValue) }

    public init(_ first: A, _ second: B) {
        self.first = first
        self.second = second
    }

    public func toLanes() -> MotionLanes {
        var out = A.zeroValue.toLanes()
        let a = first.toLanes()
        let b = second.toLanes()
        for i in 0..<A.laneCount { out[i] = a[i] }
        let base = A.laneCount
        for j in 0..<B.laneCount where base + j < MotionLanes.maxLanes {
            out[base + j] = b[j]
        }
        return out
    }

    public static func fromLanes(_ lanes: MotionLanes) -> Self {
        var bLanes = MotionLanes()
        let base = A.laneCount
        for j in 0..<B.laneCount where base + j < MotionLanes.maxLanes {
            bLanes[j] = lanes[base + j]
        }
        return Self(A.fromLanes(lanes), B.fromLanes(bLanes))
    }
}

/// Composite `Animatable` triple (`(A, B, C)` counterpart; Swift tuples cannot conform to protocols).
public struct AnimatableTriple<A: Animatable, B: Animatable, C: Animatable>: Animatable, Hashable where A: Hashable, B: Hashable, C: Hashable {
    public var first: A
    public var second: B
    public var third: C

    public static var laneCount: Int { min(MotionLanes.maxLanes, A.laneCount + B.laneCount + C.laneCount) }
    public static var zeroValue: Self { Self(A.zeroValue, B.zeroValue, C.zeroValue) }

    public init(_ first: A, _ second: B, _ third: C) {
        self.first = first
        self.second = second
        self.third = third
    }

    public func toLanes() -> MotionLanes {
        var out = MotionLanes()
        let a = first.toLanes()
        let b = second.toLanes()
        let c = third.toLanes()
        for i in 0..<A.laneCount where i < MotionLanes.maxLanes { out[i] = a[i] }
        let bBase = A.laneCount
        for j in 0..<B.laneCount where bBase + j < MotionLanes.maxLanes { out[bBase + j] = b[j] }
        let cBase = bBase + B.laneCount
        for k in 0..<C.laneCount where cBase + k < MotionLanes.maxLanes { out[cBase + k] = c[k] }
        return out
    }

    public static func fromLanes(_ lanes: MotionLanes) -> Self {
        var bLanes = MotionLanes()
        var cLanes = MotionLanes()
        let bBase = A.laneCount
        for j in 0..<B.laneCount where bBase + j < MotionLanes.maxLanes { bLanes[j] = lanes[bBase + j] }
        let cBase = bBase + B.laneCount
        for k in 0..<C.laneCount where cBase + k < MotionLanes.maxLanes { cLanes[k] = lanes[cBase + k] }
        return Self(A.fromLanes(lanes), B.fromLanes(bLanes), C.fromLanes(cLanes))
    }
}
