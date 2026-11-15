import Foundation
import RuneMotion

// MARK: - Scroll viewport under a point (`runtime/input/pointer.rs` `scroll_at` / `scroll_at_axis`)

extension Runtime {
    /// Whether the viewport at `path` has anything to scroll on `axis`: upstream's
    /// `scrolls.get(&id).is_some_and(|st| if horizontal { st.x.max } else { st.max } > 0.0)`.
    /// A viewport whose content fits on that axis is passed over by the wheel, a trackpad, a
    /// touch drag and Page Up/Down for the one around it, as Chromium skips a scroller with
    /// nothing to scroll (#1021, `5dabf425`).
    internal func scrollHasRoom(_ path: String, axis: ScrollAxes) -> Bool {
        guard let maxExt = scrollMaxExtents[path] else { return false }
        return (axis == .horizontal ? maxExt.x : maxExt.y) > 0
    }

    /// `Runtime::scroll_at_axis`: the innermost scroll viewport at (x, y) that moves on the
    /// horizontal axis or the vertical, passing over one whose content fits on that axis: a list
    /// of sections, each its own viewport as tall as its rows, scrolls from over any row.
    internal func scrollAtAxis(_ x: Float, _ y: Float, horizontal: Bool) -> String? {
        scrollContainerAt(at: Vec2(x, y), axis: horizontal ? .horizontal : .vertical)
    }

    /// `Runtime::scroll_at`: the innermost vertical scroll viewport at (x, y) with something to scroll.
    internal func scrollAt(_ x: Float, _ y: Float) -> String? {
        scrollAtAxis(x, y, horizontal: false)
    }
}
