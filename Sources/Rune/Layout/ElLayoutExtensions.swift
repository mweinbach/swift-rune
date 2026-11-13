import Foundation
import RuneMotion

extension El {
    /// Allow shrinking below intrinsic content size along the parent's main axis
    /// (CSS `flex-shrink: 1; min-width: 0`).
    public func shrink() -> Self {
        var copy = self
        copy.layout.flexShrink = 1.0
        copy.layout.minWidth = .points(0)
        return copy
    }

    /// Reverse horizontal flex item order (`flex-direction: row-reverse`).
    public func rowReverse() -> Self {
        var copy = self
        copy.layout.direction = .rowReverse
        return copy
    }

    /// Reverse vertical flex item order (`flex-direction: column-reverse`).
    public func colReverse() -> Self {
        var copy = self
        copy.layout.direction = .columnReverse
        return copy
    }

    /// Wrap flex lines in reverse cross-axis order (`flex-wrap: wrap-reverse`).
    public func flexWrapReverse() -> Self {
        var copy = self
        copy.layout.wrap = true
        copy.layout.wrapReverse = true
        return copy
    }

    /// Distribute multi-line flex track lines along the cross axis (`align-content`).
    public func flexAlignContent(_ align: JustifyContent) -> Self {
        var copy = self
        copy.layout.alignContent = align
        return copy
    }

    /// Remove this node from layout (`display: none`).
    public func displayNone(_ hidden: Bool = true) -> Self {
        var copy = self
        copy.layout.displayNone = hidden
        return copy
    }

    /// Use CSS `box-sizing: content-box` instead of the default `border-box`.
    public func contentBox() -> Self {
        var copy = self
        copy.layout.boxSizingBorderBox = false
        return copy
    }

    /// Include this element's border thickness in its layout box room (snapped to device pixels).
    public func borderLayout(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.layout.borderLayout = enabled
        return copy
    }

    /// Reserve `width` logical points for a scroll container's scrollbar gutter.
    public func scrollbarWidth(_ width: Float) -> Self {
        var copy = self
        copy.layout.scrollbarWidth = max(0, width)
        return copy
    }

    /// Override parent cross-axis alignment for this child (`align-self: flex-start`).
    public func selfStart() -> Self { alignSelf(.start) }

    /// Override parent cross-axis alignment for this child (`align-self: center`).
    public func selfCenter() -> Self { alignSelf(.center) }

    /// Override parent cross-axis alignment for this child (`align-self: flex-end`).
    public func selfEnd() -> Self { alignSelf(.end) }

    /// Override parent cross-axis alignment for this child (`align-self: stretch`).
    public func selfStretch() -> Self { alignSelf(.stretch) }

    /// Paint-time whole-pixel snapping (`El::pixel_snap`). On by default.
    public func pixelSnap(_ on: Bool = true) -> Self {
        var copy = self
        copy.runtimeExtras["pixelSnap"] = on
        return copy
    }

    /// Hold trailing position against a widening parent (`El::ride_trailing`).
    public func rideTrailing() -> Self {
        var copy = self
        copy.runtimeExtras["rideTrailing"] = true
        return copy
    }

    var isPixelSnapEnabled: Bool {
        (runtimeExtras["pixelSnap"] as? Bool) ?? true
    }

    var isRideTrailing: Bool {
        (runtimeExtras["rideTrailing"] as? Bool) ?? false
    }

    var scaleOrigin: Vec2 {
        (runtimeExtras["scaleOrigin"] as? Vec2) ?? Vec2(0.5, 0.5)
    }
}
