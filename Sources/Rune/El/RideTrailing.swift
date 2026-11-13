import Foundation

/// Aligns a trailing child to its animating container's right/trailing edge while in motion
/// (`crates/rune/src/el/ride_trailing.rs`).
public extension El {
    /// Slides with its parent's trailing edge while the parent is resizing (for example, a button
    /// or badge sitting at the right side of an expanding container).
    ///
    /// - Hook for `Runtime.commitTree`: call `scene.setRideTrailing(nid, el.isRideTrailing)` right
    ///   after `scene.commit(...)`.
    func rideTrailing() -> Self {
        var copy = self
        copy.runtimeExtras[Self.rideTrailingExtraKey] = true
        return copy
    }
}

internal extension El {
    static var rideTrailingExtraKey: String { "rune.rideTrailing" }

    var isRideTrailing: Bool {
        (runtimeExtras[Self.rideTrailingExtraKey] as? Bool) ?? false
    }
}
