import Foundation
import RuneMotion

/// What a handler asks of a commit's motion (`crates/rune/src/el/tx.rs`).
public enum TxCommit: String, Sendable, Equatable {
    /// Animate this change; motion an earlier change set going keeps running.
    case animate
    /// Apply this change at once; motion an earlier change set going keeps running.
    case instant
    /// Apply this change at once and land every running track.
    case settle
    /// Land every running track, and still animate this change's own layout (`settle` then `animated`).
    case settleAnimated

    public init(snaps: Bool, lands: Bool) {
        switch (snaps, lands) {
        case (false, false): self = .animate
        case (true, false): self = .instant
        case (true, true): self = .settle
        case (false, true): self = .settleAnimated
        }
    }

    /// True when this change's own layout applies at once instead of moving on its spring.
    public var snaps: Bool {
        self == .instant || self == .settle
    }

    /// True when this change lands every running track (growth, reveals, follow-the-end).
    public var lands: Bool {
        self == .settle || self == .settleAnimated
    }

    public func snap(_ snaps: Bool) -> TxCommit {
        TxCommit(snaps: snaps, lands: lands)
    }

    public func instant() -> TxCommit {
        snap(true)
    }

    public func animated() -> TxCommit {
        snap(false)
    }

    /// Two handlers' intents for one commit: either may snap or land it.
    public func merge(_ other: TxCommit) -> TxCommit {
        TxCommit(snaps: snaps || other.snaps, lands: lands || other.lands)
    }
}

/// The motion a change's layout moves on (`Tx.motion` / `Tx.motionCurve`).
public enum MotionSource: Sendable, Equatable {
    case spring(Spring)
    case curve(anim: Anim<Float>, spring: Spring)

    public static func fromAnim(_ anim: Anim<Float>) -> MotionSource {
        let spring: Spring
        switch anim.curve {
        case .spring(let s):
            spring = s
        default:
            spring = Spring(duration: max(0.01, anim.curve.logicalDuration), bounce: 0.0)
        }
        return .curve(anim: anim, spring: spring)
    }

    public var spring: Spring {
        switch self {
        case .spring(let s), .curve(_, let s):
            return s
        }
    }

    public var anim: Anim<Float> {
        switch self {
        case .spring(let s):
            return Anim(curve: .spring(s))
        case .curve(let anim, _):
            return anim
        }
    }
}

/// Reveal or centering scroll request (`Tx.scrollIntoView`, `Tx.scrollCenter`, etc.).
public struct ScrollRevealRequest: Sendable, Equatable {
    public var scope: String?
    public var key: String
    public var center: Bool
    public var animated: Bool

    public init(scope: String? = nil, key: String, center: Bool = false, animated: Bool = true) {
        self.scope = scope
        self.key = key
        self.center = center
        self.animated = animated
    }

    public static func intoView(scope: String? = nil, key: String) -> ScrollRevealRequest {
        ScrollRevealRequest(scope: scope, key: key, center: false, animated: true)
    }

    public static func center(scope: String? = nil, key: String, animated: Bool = true) -> ScrollRevealRequest {
        ScrollRevealRequest(scope: scope, key: key, center: true, animated: animated)
    }
}

/// Offset or anchored scroll request (`Tx.scrollTo`, `Tx.scrollToX`, `Tx.scrollKeyTo`, etc.).
public struct ScrollOffsetRequest: Sendable, Equatable {
    public var key: String
    public var x: Float?
    public var y: Float?
    public var glide: Spring?
    public var anchor: Bool

    public init(key: String, x: Float? = nil, y: Float? = nil, glide: Spring? = nil, anchor: Bool = false) {
        self.key = key
        self.x = x
        self.y = y
        self.glide = glide
        self.anchor = anchor
    }
}
