import Foundation

/// Visibility / IntersectionObserver parity helpers (`crates/rune/src/runtime/visible.rs`).
enum VisibleGeometry {
    /// Whether `rect` (`[x, y, w, h]`) counts as on screen in a window `view` points big:
    /// at least half of `rect`'s area shows, or `rect` covers at least half the window.
    static func onScreen(_ rect: [Float], view: (Float, Float)) -> Bool {
        guard rect.count == 4 else { return false }
        let w = min(rect[0] + rect[2], view.0) - max(rect[0], 0)
        let h = min(rect[1] + rect[3], view.1) - max(rect[1], 0)
        if w <= 0 || h <= 0 { return false }
        let need = 0.5 * min(rect[2] * rect[3], view.0 * view.1)
        return w * h >= need
    }
}

extension El {
    /// Called with `true` when this element comes on screen and `false` when it leaves
    /// (50% of element area or 50% of viewport area visible). Starts off-screen.
    public func onVisible(_ handler: @escaping (inout State, Bool, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onVisible = handler
        return copy
    }
}
