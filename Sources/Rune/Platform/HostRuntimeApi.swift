// Host-facing runtime APIs: native chrome insets (`runtime/input/titlebar.rs`
// `set_chrome_insets` / `chrome_insets`) and the drag-out geometry a host starts an OS drag
// with (`runtime/drag_out_host.rs` `take_drag_out`, `runtime/input/pointer.rs`
// `start_drag_out`).

import Foundation
import RuneMotion

// MARK: - Chrome insets (`runtime/input/titlebar.rs:207-218`)

extension Runtime {
    /// What `Cx::chromeInsets()` reports, in window points. Native windows set it from their
    /// controls whenever they may have moved (resize, scale change, full screen, a new
    /// `Cx::set_titlebar` / `titlebar_height`); a change re-runs the view
    /// (`Runtime::set_chrome_insets`).
    public func setChromeInsets(_ insets: ChromeInsets) {
        let changed = insets != windowChromeInsets()
        cxSettings.hostChromeInsets = insets
        if changed {
            markNeedsCommit()
        }
    }

    /// The chrome insets in window points, before the view's zoom (`Runtime::chrome_insets`).
    /// Deliberate naming deviation: Swift's `chromeInsets()` keeps its existing meaning (the
    /// zoomed view points `Cx::chrome_insets` reads), so upstream's getter lives here:
    /// what the host last set with `setChromeInsets(_:)`, else what a run without a window
    /// derives from `App::titlebar` (`Runtime::headless_chrome`).
    public func windowChromeInsets() -> ChromeInsets {
        if let host = cxSettings.hostChromeInsets { return host }
        let base = effectiveTitlebar()
        let rawH = base?.height ?? 0.0
        let rawLeading = cxSettings.titlebarInset > 0 ? cxSettings.titlebarInset : (base?.insetLeading ?? 0.0)
        let rawTrailing = base?.insetTrailing ?? 0.0
        return ChromeInsets(leading: rawLeading, trailing: rawTrailing, top: rawH)
    }

    /// Whether a commit since the last call set a different `Cx::set_titlebar` /
    /// `Cx::titlebar_height`; the shell then re-syncs its chrome (traffic lights, band height,
    /// `setChromeInsets`) (`Runtime::take_titlebar_changed`).
    public func takeTitlebarChanged() -> Bool {
        defer { cxSettings.titlebarSetChanged = false }
        return cxSettings.titlebarSetChanged
    }
}

// MARK: - Drag-out geometry (`runtime/input/pointer.rs:166-188`)

extension Runtime {
    /// The clip a node's drawn rect is cut to for a drag-out's visible `rect`
    /// (`pointer.rs:178` `screen_clip_of_parent(n.parent)`): the drawn screen clip its parent
    /// passed down at the last paint, `nil` (`NO_CLIP`) when nothing clips it. Before the node
    /// has painted, its ancestors' layout clip stands in.
    internal func dragOutParentClip(path: String) -> MotionRect? {
        if let geom = hitGeometryByPath[path] { return geom.parentScreenClip }
        guard let idx = nodeByPath[path], flatNodes.indices.contains(idx) else { return nil }
        var cur = flatNodes[idx].parentIndex
        while let p = cur, flatNodes.indices.contains(p) {
            let el = flatNodes[p].el
            if el.layout.clipOverflow || el.clipRadius != nil || el.clipCorners != nil || el.clipFade != nil {
                return flatNodes[idx].clipRect
            }
            cur = flatNodes[p].parentIndex
        }
        return nil
    }

    /// `turn.rs::screen_clip_of`: a parent under a turn clips its children on screen to its
    /// outer clip cut to the bounding box of its turned local clip; otherwise to its inherited
    /// clip. `nil` is `NO_CLIP`.
    internal static func screenClipOfParent(
        inheritedClip: MotionRect?,
        ancestorTurn: Turn?,
        outerTurnClip: MotionRect?,
        localTurnClip: MotionRect?
    ) -> MotionRect? {
        guard let turn = ancestorTurn else { return inheritedClip }
        let ic = localTurnClip.map { turn.bbox($0) }
        switch (outerTurnClip, ic) {
        case let (oc?, ic?): return intersectRects(oc, ic)
        case let (oc?, nil): return oc
        case let (nil, ic?): return ic
        case (nil, nil): return nil
        }
    }

    /// The element's visible drawn rect: `bounds` cut to its parent's clip, empty sides
    /// clamped to zero (`start_drag_out`'s `rect`).
    internal static func dragOutVisibleRect(bounds r: MotionRect, clip: MotionRect?) -> MotionRect {
        guard let clip else { return r }
        let x0 = max(r.left, clip.left)
        let y0 = max(r.top, clip.top)
        let w = max(min(r.right, clip.right) - x0, 0)
        let h = max(min(r.bottom, clip.bottom) - y0, 0)
        return .fromXYWH(x0, y0, w, h)
    }
}

extension DragOutStart {
    /// The start with its rects and press in the points of a view zoomed `k` times taken to
    /// window points (`take_drag_out`: `rect`, `bounds` and `press` times `zoom()`).
    public func zoomed(_ k: Float) -> DragOutStart {
        var out = self
        out.rect = .fromXYWH(rect.x * k, rect.y * k, rect.width * k, rect.height * k)
        out.bounds = .fromXYWH(bounds.x * k, bounds.y * k, bounds.width * k, bounds.height * k)
        out.press = Vec2(press.x * k, press.y * k)
        return out
    }
}
