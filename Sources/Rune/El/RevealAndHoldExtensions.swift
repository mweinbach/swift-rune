import Foundation

extension El {
    /// Streams newly appended words onto the screen with a `seconds`-long per-word fade (`El::reveal`).
    /// Words chain in reading order across sibling/sequential texts while fading.
    public func reveal(_ seconds: Float) -> Self {
        var copy = self
        copy.revealDuration = seconds.isFinite ? max(0.0, seconds) : 0.0
        return copy
    }

    /// Holds an animated width change's contents at their landing layout and slides them from
    /// where they were drawn (`El::hold_landing_width`). Kept as a no-op helper here so
    /// `ElCloseoutBuilders.holdLandingWidth(_:)` handles both `.holdLandingWidth()` and `.holdLandingWidth(Bool)`.
}
