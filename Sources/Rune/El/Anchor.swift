import Foundation
import RuneMotion

/// Which side of its anchor an `El.anchored` overlay sits on (`crates/rune/src/el/anchor.rs`).
public enum Side: String, Sendable, Hashable, Codable {
    case top
    case bottom
    case left
    case right
}

/// Alignment along the anchored edge (`crates/rune/src/el.rs`).
public enum Align: String, Sendable, Hashable, Codable {
    case start
    case center
    case end
}

/// Configuration for `El.anchored`, `El.anchoredFit`, and `El.above`.
public struct Anchor: Sendable, Equatable, Codable {
    public var key: String
    public var side: Side
    public var align: Align
    public var gap: Float
    /// `El.anchoredFit`: bound length along side axis to available room.
    public var fit: Bool
    /// `El.anchoredUnscaled`: keep overlay at window scale instead of anchor's zoom.
    public var unscaled: Bool
    /// `El.anchoredRound`: round placed coordinates to whole points.
    public var round: Bool

    public init(
        key: String,
        side: Side,
        align: Align = .start,
        gap: Float = 0,
        fit: Bool = false,
        unscaled: Bool = false,
        round: Bool = false
    ) {
        self.key = key
        self.side = side
        self.align = align
        self.gap = gap
        self.fit = fit
        self.unscaled = unscaled
        self.round = round
    }
}

private let anchorMargin: Float = 8.0

/// Computes `[x, y]` for an anchored overlay of `size` beside `trigger` (`[x0, y0, x1, y1]`)
/// inside `viewport` (`(w, h)`), flipping sides/alignment when overflowing and keeping 8 pt margin.
/// Matches `crates/rune/src/runtime/anchor.rs:21-60`.
public func anchorPosition(
    _ anchor: Anchor,
    trigger t: [Float],
    size: (Float, Float),
    viewport vp: (Float, Float)
) -> (Float, Float) {
    precondition(t.count >= 4, "anchor trigger rect must have 4 components [x0, y0, x1, y1]")
    let (w, h) = size
    let margin = anchorMargin

    func along(_ lo: Float, _ hi: Float, _ len: Float) -> Float {
        switch anchor.align {
        case .start: return lo
        case .center: return (lo + hi - len) * 0.5
        case .end: return hi - len
        }
    }

    var x: Float
    var y: Float
    switch anchor.side {
    case .top:
        x = along(t[0], t[2], w)
        y = t[1] - h - anchor.gap
    case .bottom:
        x = along(t[0], t[2], w)
        y = t[3] + anchor.gap
    case .left:
        x = t[0] - w - anchor.gap
        y = along(t[1], t[3], h)
    case .right:
        x = t[2] + anchor.gap
        y = along(t[1], t[3], h)
    }

    // Flip side when opposite side fits.
    switch anchor.side {
    case .bottom where y + h > vp.1 - margin && t[1] - h - anchor.gap >= margin:
        y = t[1] - h - anchor.gap
    case .top where y < margin && t[3] + anchor.gap + h <= vp.1 - margin:
        y = t[3] + anchor.gap
    case .right where x + w > vp.0 - margin && t[0] - w - anchor.gap >= margin:
        x = t[0] - w - anchor.gap
    case .left where x < margin && t[2] + anchor.gap + w <= vp.0 - margin:
        x = t[2] + anchor.gap
    default:
        break
    }

    // Flip cross-axis alignment when it overflows and the opposite alignment fits, then clamp inside margin.
    let vertical = (anchor.side == .top || anchor.side == .bottom)
    let lo = vertical ? t[0] : t[1]
    let hi = vertical ? t[2] : t[3]
    let len = vertical ? w : h
    let room = vertical ? vp.0 : vp.1
    var pos = vertical ? x : y

    switch anchor.align {
    case .end where pos < margin && lo + len <= room - margin:
        pos = lo
    case .start where pos + len > room - margin && hi - len >= margin:
        pos = hi - len
    default:
        break
    }
    pos = min(max(pos, margin), max(margin, room - len - margin))

    if vertical {
        x = pos
        y = max(y, margin)
    } else {
        y = pos
        x = max(x, margin)
    }

    if anchor.round {
        return ((x + 0.5).rounded(.down), (y + 0.5).rounded(.down))
    }
    return (x, y)
}

/// Computes the longest length allowed for an `anchoredFit` overlay `length` long beside `trigger`
/// (`[x0, y0, x1, y1]`) when it fits on neither side, or `nil` if it fits.
/// Matches `crates/rune/src/runtime/anchor.rs:65-75`.
public func anchorFitBound(
    _ anchor: Anchor,
    trigger t: [Float],
    length: Float,
    viewport vp: (Float, Float)
) -> Float? {
    precondition(t.count >= 4, "anchor trigger rect must have 4 components [x0, y0, x1, y1]")
    let before: Float
    let after: Float
    switch anchor.side {
    case .top, .bottom:
        before = t[1] - anchor.gap - anchorMargin
        after = vp.1 - anchorMargin - (t[3] + anchor.gap)
    case .left, .right:
        before = t[0] - anchor.gap - anchorMargin
        after = vp.0 - anchorMargin - (t[2] + anchor.gap)
    }
    let own = (anchor.side == .top || anchor.side == .left) ? before : after
    let other = (anchor.side == .top || anchor.side == .left) ? after : before
    if length <= own || length <= other {
        return nil
    }
    return max(0, (max(own, other) - 0.5).rounded(.down))
}

/// Pure anchor placement helper returning `[x0, y0, x1, y1]` (`crates/rune/src/el/anchor.rs:92-96`).
public func anchorRect(
    _ trigger: [Float],
    size: (Float, Float),
    side: Side,
    align: Align,
    gap: Float,
    window: (Float, Float)
) -> [Float] {
    let a = Anchor(key: "", side: side, align: align, gap: gap)
    let (x, y) = anchorPosition(a, trigger: trigger, size: size, viewport: window)
    return [x, y, x + size.0, y + size.1]
}

/// `MotionRect` / `Vec2` convenience overload matching Rune Swift geometry types.
public func anchorRect(
    trigger: MotionRect,
    size: Vec2,
    side: Side,
    align: Align,
    gap: Float,
    window: Vec2
) -> MotionRect {
    let r = anchorRect(
        [trigger.left, trigger.top, trigger.right, trigger.bottom],
        size: (size.x, size.y),
        side: side,
        align: align,
        gap: gap,
        window: (window.x, window.y)
    )
    return MotionRect(left: r[0], top: r[1], right: r[2], bottom: r[3])
}
