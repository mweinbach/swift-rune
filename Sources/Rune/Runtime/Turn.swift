import Foundation

/// 2D affine transform `[a, b, tx; c, d, ty]` for composed `El.rotate` hit-testing and bounding boxes.
/// Matches `crates/rune/src/runtime/turn.rs`.
public struct Turn: Sendable, Equatable {
    public var a: Float
    public var b: Float
    public var c: Float
    public var d: Float
    public var tx: Float
    public var ty: Float

    public static let identity = Turn(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public init(a: Float, b: Float, c: Float, d: Float, tx: Float, ty: Float) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    /// Clockwise rotation in screen-down (`+y` down) coordinates about `pivot` by `radians`.
    public static func about(_ pivot: Vec2, radians: Float) -> Turn {
        let cosA = cosf(radians)
        let sinA = sinf(radians)
        let tx = pivot.x - cosA * pivot.x + sinA * pivot.y
        let ty = pivot.y - sinA * pivot.x - cosA * pivot.y
        return Turn(a: cosA, b: -sinA, c: sinA, d: cosA, tx: tx, ty: ty)
    }

    /// Composes `self` applied AFTER `inner`: `(self ∘ inner)(p) = self.apply(inner.apply(p))`.
    public func after(_ inner: Turn) -> Turn {
        Turn(
            a: a * inner.a + b * inner.c,
            b: a * inner.b + b * inner.d,
            c: c * inner.a + d * inner.c,
            d: c * inner.b + d * inner.d,
            tx: a * inner.tx + b * inner.ty + tx,
            ty: c * inner.tx + d * inner.ty + ty
        )
    }

    /// Forward-transforms a point into turned space.
    @inline(__always)
    public func apply(_ p: Vec2) -> Vec2 {
        Vec2(a * p.x + b * p.y + tx, c * p.x + d * p.y + ty)
    }

    /// Inverse-transforms a point back from turned space into local space.
    @inline(__always)
    public func unturn(_ p: Vec2) -> Vec2 {
        let det = a * d - b * c
        if abs(det) < 1e-8 { return p }
        let dx = p.x - tx
        let dy = p.y - ty
        return Vec2((d * dx - b * dy) / det, (-c * dx + a * dy) / det)
    }

    /// Axis-aligned bounding box of `rect` after transforming its 4 corners.
    public func bbox(_ rect: MotionRect) -> MotionRect {
        let p0 = apply(Vec2(rect.left, rect.top))
        let p1 = apply(Vec2(rect.right, rect.top))
        let p2 = apply(Vec2(rect.right, rect.bottom))
        let p3 = apply(Vec2(rect.left, rect.bottom))
        return MotionRect(
            left: min(min(p0.x, p1.x), min(p2.x, p3.x)),
            top: min(min(p0.y, p1.y), min(p2.y, p3.y)),
            right: max(max(p0.x, p1.x), max(p2.x, p3.x)),
            bottom: max(max(p0.y, p1.y), max(p2.y, p3.y))
        )
    }
}
