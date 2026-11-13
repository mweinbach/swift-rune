import Foundation

/// Edge direction for slide/move/push/reveal transitions.
public enum MotionEdge: Sendable, Hashable, Codable {
    case top
    case bottom
    case leading
    case trailing

    @inlinable
    public var opposite: MotionEdge {
        switch self {
        case .top: return .bottom
        case .bottom: return .top
        case .leading: return .trailing
        case .trailing: return .leading
        }
    }

    /// Unit direction vector pointing toward this edge (`top = (0,-1)`, `bottom = (0,1)`, etc.).
    @inlinable
    public var unitVector: Vec2 {
        switch self {
        case .top: return Vec2(0, -1)
        case .bottom: return Vec2(0, 1)
        case .leading: return Vec2(-1, 0)
        case .trailing: return Vec2(1, 0)
        }
    }
}

/// Clip reveal specification for unrolling popovers, menus, and disclosures.
public struct Reveal: Sendable, Hashable, Codable {
    public var edge: MotionEdge
    public var feather: Float

    public init(edge: MotionEdge, feather: Float = 24.0) {
        self.edge = edge
        self.feather = feather
    }

    /// Computes clipped `[left, top, right, bottom]` at `presence in [0, 1]` for `rect`.
    public func clipRect(for rect: MotionRect, presence: Float) -> MotionRect {
        let p = presence.clamped(to: 0...1)
        let w = rect.width
        let h = rect.height
        switch edge {
        case .top:
            return MotionRect(left: rect.left, top: rect.top, right: rect.right, bottom: rect.top + h * p)
        case .bottom:
            return MotionRect(left: rect.left, top: rect.bottom - h * p, right: rect.right, bottom: rect.bottom)
        case .leading:
            return MotionRect(left: rect.left, top: rect.top, right: rect.left + w * p, bottom: rect.bottom)
        case .trailing:
            return MotionRect(left: rect.right - w * p, top: rect.top, right: rect.right, bottom: rect.bottom)
        }
    }
}

/// Composable visual state at `presence == 0` (the unmounted endpoint of an enter/exit transition).
public struct TransitionEffect: Sendable, Hashable {
    /// Opacity when unmounted (`nil` means opacity is unaffected, i.e., `1.0`).
    public var zeroOpacity: Float?
    /// Uniform/2D scale when unmounted (`(1, 1)` means no scale change).
    public var zeroScale: Vec2
    /// Translation in multiples of the node's `(width, height)` when unmounted.
    public var relativeOffset: Vec2
    /// Translation in fixed points when unmounted.
    public var pointOffset: Vec2
    /// Blur radius in points when unmounted.
    public var zeroBlur: Float
    /// Optional directional clip reveal.
    public var reveal: Reveal?
    /// Optional spring override for this direction.
    public var spring: Spring?
    /// Scale anchor in unit coordinates (0.5, 0.5 = center).
    public var anchor: Vec2
    /// Lets `zeroScale` go down to `0.5` instead of `0.9` in `kitRules`.
    public var smallScale: Bool
    /// How much of the node's own shape is drawn when absent (1.0 = whole).
    public var draw: Float

    public init(
        zeroOpacity: Float? = nil,
        zeroScale: Vec2 = Vec2(1, 1),
        relativeOffset: Vec2 = .zero,
        pointOffset: Vec2 = .zero,
        zeroBlur: Float = 0,
        reveal: Reveal? = nil,
        spring: Spring? = nil,
        anchor: Vec2 = Vec2(0.5, 0.5),
        smallScale: Bool = false,
        draw: Float = 1.0
    ) {
        self.zeroOpacity = zeroOpacity
        self.zeroScale = zeroScale
        self.relativeOffset = relativeOffset
        self.pointOffset = pointOffset
        self.zeroBlur = zeroBlur
        self.reveal = reveal
        self.spring = spring
        self.anchor = anchor
        self.smallScale = smallScale
        self.draw = draw
    }

    public static let identity = TransitionEffect()

    public var travels: Bool {
        pointOffset != .zero || relativeOffset != .zero
    }

    public var showsNothing: Bool {
        zeroOpacity == nil &&
            zeroScale == Vec2(1, 1) &&
            relativeOffset == .zero &&
            pointOffset == .zero &&
            zeroBlur == 0 &&
            reveal == nil &&
            draw == 1.0
    }

    public func combined(with other: TransitionEffect) -> TransitionEffect {
        let mergedOpacity: Float?
        switch (zeroOpacity, other.zeroOpacity) {
        case let (a?, b?): mergedOpacity = a * b
        case let (a?, nil): mergedOpacity = a
        case let (nil, b?): mergedOpacity = b
        case (nil, nil): mergedOpacity = nil
        }
        return TransitionEffect(
            zeroOpacity: mergedOpacity,
            zeroScale: Vec2(zeroScale.x * other.zeroScale.x, zeroScale.y * other.zeroScale.y),
            relativeOffset: Vec2(relativeOffset.x + other.relativeOffset.x, relativeOffset.y + other.relativeOffset.y),
            pointOffset: Vec2(pointOffset.x + other.pointOffset.x, pointOffset.y + other.pointOffset.y),
            zeroBlur: max(zeroBlur, other.zeroBlur),
            reveal: reveal ?? other.reveal,
            spring: other.spring ?? spring,
            anchor: zeroScale != Vec2(1, 1) ? anchor : other.anchor,
            smallScale: smallScale || other.smallScale,
            draw: draw * other.draw
        )
    }

    /// Enforces Rune Kit's tasteful motion guardrails on one direction (`insertion` or `removal`):
    /// scale clamped to `[0.9, 1.1]` (or `[0.5, 1.1]` with `smallScale`), blur <= 4.0 (0 when travelling),
    /// opacity clamped to `0...1`, draw clamped to `0...1`, and `removal` always fades to `0.0`.
    public func kitRules(removal: Bool, small: Bool = false) -> TransitionEffect {
        var out = self
        let minScale: Float = (small || out.smallScale) ? Transition.smallScaleFloor : 0.9
        out.zeroScale = Vec2(
            out.zeroScale.x.clamped(to: minScale...1.1),
            out.zeroScale.y.clamped(to: minScale...1.1)
        )
        out.zeroBlur = out.travels ? 0.0 : out.zeroBlur.clamped(to: 0.0...4.0)
        out.zeroOpacity = removal ? 0.0 : out.zeroOpacity.map { $0.clamped(to: 0.0...1.0) }
        out.draw = out.draw.clamped(to: 0.0...1.0)
        return out
    }

    /// Evaluates `(opacityMultiplier, scale, offset, blur, clip)` at `presence` (typically `[0, 1]`,
    /// though bouncy springs may slightly overshoot `1.0`).
    public func evaluate(presence: Float, size: Vec2) -> (opacity: Float, scale: Vec2, offset: Vec2, blur: Float) {
        let t = 1.0 - presence
        let op: Float
        if let z = zeroOpacity {
            op = (z + (1.0 - z) * presence).clamped(to: 0...1)
        } else {
            op = 1.0
        }
        let sx = max(0, zeroScale.x + (1.0 - zeroScale.x) * presence)
        let sy = max(0, zeroScale.y + (1.0 - zeroScale.y) * presence)
        let ox = (relativeOffset.x * size.x + pointOffset.x) * t
        let oy = (relativeOffset.y * size.y + pointOffset.y) * t
        let bl = max(0, zeroBlur * max(0, t))
        return (op, Vec2(sx, sy), Vec2(ox, oy), bl)
    }
}

/// Enter / exit presence transition specification (`insertion` and `removal` effects).
public struct Transition: Sendable, Hashable {
    /// Smallest scale permitted with `.allowSmallScale()`.
    public static let smallScaleFloor: Float = 0.5

    public var insertion: TransitionEffect
    public var removal: TransitionEffect
    public var popLayout: Bool
    public var springs: SpringPair

    public init(
        insertion: TransitionEffect,
        removal: TransitionEffect,
        popLayout: Bool = true,
        springs: SpringPair = MotionTokens.SETTLE_PAIR
    ) {
        self.insertion = insertion
        self.removal = removal
        self.popLayout = popLayout
        self.springs = springs
    }

    public init(
        symmetric effect: TransitionEffect,
        popLayout: Bool = true,
        springs: SpringPair = MotionTokens.SETTLE_PAIR
    ) {
        self.insertion = effect
        self.removal = effect
        self.popLayout = popLayout
        self.springs = springs
    }

    public static let identity = Transition(symmetric: .identity)
    public static let none = Transition(symmetric: .identity, springs: .none)

    public var isNone: Bool {
        springs == .none && insertion.spring == nil && removal.spring == nil &&
            insertion.showsNothing && removal.showsNothing
    }

    public var enterSpring: Spring { insertion.spring ?? springs.enter }
    public var exitSpring: Spring { removal.spring ?? springs.exit }

    /// Pure opacity fade (`0 <-> 1`).
    public static let opacity = Transition(symmetric: TransitionEffect(zeroOpacity: 0))

    /// Scale from/to `factor` (combined with fade by default, matching SwiftUI/Rune).
    public static func scale(_ factor: Float = 0.95) -> Transition {
        Transition(symmetric: TransitionEffect(zeroOpacity: 0, zeroScale: Vec2(factor, factor)))
    }

    public static func scale(_ factor: Float, anchor: Vec2) -> Transition {
        Transition(symmetric: TransitionEffect(zeroOpacity: 0, zeroScale: Vec2(factor, factor), anchor: anchor))
    }

    /// Moves in from `edge` and exits back toward `edge` by the element's size.
    public static func move(edge: MotionEdge) -> Transition {
        Transition(symmetric: TransitionEffect(relativeOffset: edge.unitVector))
    }

    /// Translates by fixed `(dx, dy)` points.
    public static func offset(x: Float = 0, y: Float = 0) -> Transition {
        Transition(symmetric: TransitionEffect(pointOffset: Vec2(x, y)))
    }

    /// Slides in from `leading` and exits toward `trailing`.
    public static let slide = Transition(
        insertion: TransitionEffect(relativeOffset: MotionEdge.leading.unitVector),
        removal: TransitionEffect(relativeOffset: MotionEdge.trailing.unitVector)
    )

    /// Pushes in from `edge` with fade and exits out the opposite edge with fade.
    public static func push(from edge: MotionEdge) -> Transition {
        Transition(
            insertion: TransitionEffect(zeroOpacity: 0, relativeOffset: edge.unitVector),
            removal: TransitionEffect(zeroOpacity: 0, relativeOffset: edge.opposite.unitVector)
        )
    }

    /// Blur + subtle scale + fade replacement (`blurReplace`).
    public static func blurReplace(radius: Float = 1.5, scale: Float = 0.96) -> Transition {
        Transition(symmetric: TransitionEffect(zeroOpacity: 0, zeroScale: Vec2(scale, scale), zeroBlur: radius))
    }

    /// Gaussian blur (sigma in points) and fade only.
    public static func blur(sigma: Float) -> Transition {
        Transition(symmetric: TransitionEffect(zeroOpacity: 0, zeroBlur: sigma))
    }

    /// Self-drawing stroke/fill reveal.
    public static let draw = Transition(symmetric: TransitionEffect(draw: 0.0))

    /// Unrolls from `edge` using a layout clip rectangle (24 pt feather).
    public static func reveal(edge: MotionEdge) -> Transition {
        Transition(symmetric: TransitionEffect(reveal: Reveal(edge: edge, feather: 24.0)))
    }

    public static func asymmetric(insertion: Transition, removal: Transition) -> Transition {
        Transition(
            insertion: insertion.insertion,
            removal: removal.removal,
            popLayout: insertion.popLayout,
            springs: insertion.springs
        )
    }

    public func combined(with other: Transition) -> Transition {
        Transition(
            insertion: insertion.combined(with: other.insertion),
            removal: removal.combined(with: other.removal),
            popLayout: popLayout,
            springs: springs
        )
    }

    public func spring(_ spring: Spring) -> Transition {
        var copy = self
        copy.insertion.spring = spring
        copy.removal.spring = spring
        return copy
    }

    public func springs(_ pair: SpringPair) -> Transition {
        var copy = self
        copy.springs = pair
        copy.insertion.spring = nil
        copy.removal.spring = nil
        return copy
    }

    public func allowSmallScale() -> Transition {
        var copy = self
        copy.insertion.smallScale = true
        copy.removal.smallScale = true
        return copy
    }

    public func holdLayout() -> Transition {
        var copy = self
        copy.popLayout = false
        return copy
    }

    /// Applies Rune Kit's tasteful motion guardrails:
    /// clamps scale to `[0.9, 1.1]` (or `[0.5, 1.1]` when `small` is true for tiny glyphs/checks),
    /// caps blur at `4.0` (and `0` when travelling), and ensures removal fades opacity to `0`.
    public func kitRules(small: Bool = false) -> Transition {
        Transition(
            insertion: insertion.kitRules(removal: false, small: small),
            removal: removal.kitRules(removal: true, small: small),
            popLayout: popLayout,
            springs: springs
        )
    }
}
