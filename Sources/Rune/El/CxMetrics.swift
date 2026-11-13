import Foundation
import RuneMotion

/// Scroll metric accessors on `Cx` mirroring `crates/rune/src/runtime/cx.rs`
/// and `runtime/scroll/bottom.rs`.
public extension Cx {
    /// Whether the scroll viewport keyed `key` is at or within `tolerance` points of its bottom,
    /// or `nil` when `key` is not mounted (`crates/rune/src/runtime/scroll/bottom.rs:332`).
    func scrollAtBottom(of key: String, tolerance: Float = 1.0) -> Bool? {
        guard layoutRect(of: key) != nil else { return nil }
        let offset = scrollOffset(of: key)
        let maxScroll = scrollMax(of: key)
        let eps = max(0, tolerance.isFinite ? tolerance : 0)
        return offset.y >= maxScroll.y - eps
    }

    /// Normalized `[0, 1]` scroll progress along X and Y (`0` when an axis is not scrollable).
    func scrollProgress(of key: String) -> Vec2 {
        let offset = scrollOffset(of: key)
        let maxScroll = scrollMax(of: key)
        let px = maxScroll.x > 0 ? (offset.x / maxScroll.x).clamped(to: 0...1) : 0
        let py = maxScroll.y > 0 ? (offset.y / maxScroll.y).clamped(to: 0...1) : 0
        return Vec2(px, py)
    }

    /// Remaining scrollable points `[maxX - offsetX, maxY - offsetY]`, clamped at `>= 0`.
    func scrollRemaining(of key: String) -> Vec2 {
        let offset = scrollOffset(of: key)
        let maxScroll = scrollMax(of: key)
        return Vec2(max(0, maxScroll.x - offset.x), max(0, maxScroll.y - offset.y))
    }

    /// Whether `key` currently has horizontal and/or vertical overflow beyond its viewport (`max > 0.5`).
    func canScroll(of key: String) -> (horizontal: Bool, vertical: Bool) {
        let maxScroll = scrollMax(of: key)
        return (maxScroll.x > 0.5, maxScroll.y > 0.5)
    }
}
