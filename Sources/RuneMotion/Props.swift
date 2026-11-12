import Foundation

/// Stable node identifier in `AnimationStore` and `Scene` (typically FNV-1a64 of element path/key).
public struct NodeId: Sendable, Hashable, Codable, CustomStringConvertible {
    public var rawValue: UInt64

    @inlinable
    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// Deterministic FNV-1a 64-bit hash of a string path or key.
    @inlinable
    public static func hash(_ path: String) -> NodeId {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 {
            h ^= UInt64(byte)
            h &*= 0x100000001b3
        }
        return NodeId(h)
    }

    @inlinable
    public func child(_ segment: String) -> NodeId {
        var h = rawValue ^ 0x2f
        h &*= 0x100000001b3
        for byte in segment.utf8 {
            h ^= UInt64(byte)
            h &*= 0x100000001b3
        }
        return NodeId(h)
    }

    public var description: String {
        String(format: "NodeId(0x%016llx)", rawValue)
    }
}

/// Property identifier within a node.
public struct PropId: Sendable, Hashable, Codable {
    public var rawValue: UInt16

    @inlinable
    public init(_ rawValue: UInt16) {
        self.rawValue = rawValue
    }
}

/// Semantic class governing perceptual settle thresholds and `prefers-reduced-motion` policy.
public enum PropClass: Sendable, Hashable, Codable {
    case spatial
    case scale
    case rotation
    case opacity
    case color
    case shape
    case blur
    case presence
    case gesture

    /// Returns `(positionEpsilon, velocityEpsilon)` scaled by `pixelScale`.
    @inlinable
    public func settleThresholds(pixelScale: Float) -> (pos: Float, vel: Float) {
        let px = 1.0 / (128.0 * max(pixelScale, 0.5))
        switch self {
        case .spatial, .shape, .blur, .gesture:
            return (px, px * 8.0)
        case .scale:
            return (5e-5, 5e-4)
        case .rotation:
            return (1e-4, 1e-3)
        case .opacity, .presence:
            return (5e-4, 5e-3)
        case .color:
            return (5e-4, 5e-3)
        }
    }

    /// Maps an authored curve when `reducedMotion` is enabled:
    /// spatial/scale/rotation/shape/blur cut instantly; opacity/color/presence cross-fade gently;
    /// direct gesture/scroll flings stay responsive.
    @inlinable
    public func forReducedMotion(_ curve: Curve) -> Curve {
        if case .instant = curve { return curve }
        if case .decay = curve { return curve }
        switch self {
        case .spatial, .scale, .rotation, .shape, .blur:
            return .instant
        case .opacity, .color, .presence:
            return .REDUCED_FADE
        case .gesture:
            return curve
        }
    }
}

/// Strongly typed property key binding an `Animatable` value type, `PropId`, and `PropClass`.
public struct Prop<T: Animatable>: Sendable, Hashable {
    public let id: PropId
    public let propClass: PropClass
    public let name: String

    public init(id: PropId, propClass: PropClass, name: String) {
        self.id = id
        self.propClass = propClass
        self.name = name
    }
}

public enum Props {
    public static let RECT = Prop<MotionRect>(id: PropId(1), propClass: .spatial, name: "rect")
    public static let OFFSET = Prop<Vec2>(id: PropId(2), propClass: .spatial, name: "offset")
    public static let SCALE = Prop<Vec2>(id: PropId(3), propClass: .scale, name: "scale")
    public static let ROTATE = Prop<Float>(id: PropId(4), propClass: .rotation, name: "rotate")
    public static let OPACITY = Prop<Float>(id: PropId(5), propClass: .opacity, name: "opacity")
    public static let FILL = Prop<MotionColor>(id: PropId(6), propClass: .color, name: "fill")
    public static let BORDER = Prop<MotionColor>(id: PropId(7), propClass: .color, name: "border")
    public static let TEXT_COLOR = Prop<MotionColor>(id: PropId(8), propClass: .color, name: "textColor")
    public static let CORNERS = Prop<Corners>(id: PropId(9), propClass: .shape, name: "corners")
    public static let BLUR = Prop<Blur>(id: PropId(10), propClass: .blur, name: "blur")
    public static let PRESENCE = Prop<Float>(id: PropId(11), propClass: .presence, name: "presence")
    public static let SCROLL = Prop<Vec2>(id: PropId(12), propClass: .gesture, name: "scroll")
    public static let HOVER = Prop<Float>(id: PropId(13), propClass: .opacity, name: "hover")
    public static let PRESS = Prop<Float>(id: PropId(14), propClass: .opacity, name: "press")
    public static let FOCUS = Prop<Float>(id: PropId(15), propClass: .opacity, name: "focus")
    public static let SIDES = Prop<Sides>(id: PropId(16), propClass: .shape, name: "sides")
    public static let TRANSFORM = Prop<Transform2D>(id: PropId(17), propClass: .spatial, name: "transform")
    public static let TRAVEL = Prop<Vec2>(id: PropId(18), propClass: .scale, name: "travel")
}
