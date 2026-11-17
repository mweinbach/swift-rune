import Foundation

/// An element found by `Runtime.elementAt` / `elementAtWith` / `elementAtIn`.
/// Matches `crates/rune/src/runtime/elements.rs` `Picked`.
public struct Picked: Sendable, Equatable {
    public let path: String
    public let key: String?

    public init(path: String, key: String?) {
        self.path = path
        self.key = key
    }
}

/// Options for `Runtime.elementAtWith` and `Runtime.containsWith`.
/// Matches `crates/rune/src/runtime/elements.rs` `Pick`.
public struct Pick: Sendable, Equatable {
    public var includeTransparent: Bool

    public init(transparent: Bool = false) {
        self.includeTransparent = transparent
    }

    public static var `default`: Pick { Pick() }

    /// Also find elements whose own or inherited opacity is 0.
    public func transparent(_ on: Bool = true) -> Self {
        var copy = self
        copy.includeTransparent = on
        return copy
    }
}

extension El {
    func blocksHits(fill: Color, border: Color) -> Bool {
        fill.a > 0.001 || gradient != nil || (borderWidth > 0 && border.a > 0.001)
            || imagePayload != nil || pixelsPayload != nil || backdropBlur >= 0.5 || !shapes.isEmpty
    }

    var blocksInteractiveHits: Bool {
        handlers.onClick != nil || handlers.onClickPress != nil || handlers.onDoubleClick != nil
            || handlers.onPointerDown != nil || handlers.onDrag != nil || handlers.onHover != nil
            || handlers.editLens != nil || isModal || explicitHit
    }
}

/// Cached per-frame presented hit-testing geometry for a node in `Runtime`.
struct HitGeometry: Sendable {
    var path: String
    var parentPath: String?
    var rect: MotionRect
    var clipRect: MotionRect
    var outerClip: MotionRect
    var turn: Turn?
    var opacity: Float
    var isExiting: Bool
    var hasVisualBlocker: Bool
    var isInteractiveBlocker: Bool
    /// The drawn screen clip of this node's parent, in view points (`screen_clip_of_parent`):
    /// the inherited paint clip, or under a turn the outer clip cut to the turned local clip's
    /// bounding box; `nil` is `NO_CLIP`.
    var parentScreenClip: MotionRect? = nil

    /// Half-open containment `[left, right) x [top, bottom)` matching `pointer_hit.rs:77`.
    @inline(__always)
    func unturnedLocalPoint(for windowPoint: Vec2) -> Vec2? {
        guard halfOpenContains(outerClip, windowPoint) else { return nil }
        let localPt = turn?.unturn(windowPoint) ?? windowPoint
        let shown = intersectHitRects(clipRect, rect)
        guard halfOpenContains(shown, localPt) else { return nil }
        return localPt
    }

    @inline(__always)
    func contains(_ windowPoint: Vec2) -> Bool {
        unturnedLocalPoint(for: windowPoint) != nil
    }
}

@inline(__always)
func halfOpenContains(_ r: MotionRect, _ p: Vec2) -> Bool {
    r.right > r.left && r.bottom > r.top &&
    p.x >= r.left && p.y >= r.top && p.x < r.right && p.y < r.bottom
}

@inline(__always)
private func intersectHitRects(_ a: MotionRect, _ b: MotionRect) -> MotionRect {
    let l = max(a.left, b.left)
    let t = max(a.top, b.top)
    let r = max(l, min(a.right, b.right))
    let bot = max(t, min(a.bottom, b.bottom))
    return MotionRect(left: l, top: t, right: r, bottom: bot)
}

@inline(__always)
func matchesAuthoredKey(_ key: String?, _ requested: String?) -> Bool {
    guard let key, let requested else { return false }
    return key.utf8.elementsEqual(requested.utf8)
}

/// Matches an element selector (`"knob"` or slash-path `"slider/knob"`) against a node's `path` and `key`,
/// skipping unkeyed structural segments (`0`, `1`, `#0`, etc.) and optional `@` key prefixes.
/// Parity with `crates/rune/src/flight.rs:103` `selects` and `elements.rs:534` `keyed_suffix`.
func selectsElementSelector(_ selector: String, path: String, key: String?) -> Bool {
    if matchesAuthoredKey(key, selector) { return true }
    if !selector.utf8.contains(0x2f) {
        return false
    }
    if path.utf8.elementsEqual(selector.utf8) { return true }
    let encoded = path.utf8.contains(0x7e) && path.contains(VirtualRowKeyEncoding.marker)
    if !encoded {
        let suffix = selector.utf8
        if path.utf8.suffix(suffix.count).elementsEqual(suffix) {
            let prefix = path.utf8.dropLast(suffix.count)
            if prefix.last == 0x2f || (prefix.last == 0x40 && prefix.dropLast().last == 0x2f) { return true }
        }
    }
    let wantParts = VirtualRowKeyEncoding.components(selector, omittingEmpty: false)
    guard !wantParts.isEmpty else { return false }
    let keyedSegments = VirtualRowKeyEncoding.components(path, omittingEmpty: false).compactMap { raw -> String? in
        let seg = String(raw)
        if seg.hasPrefix("@") {
            let component = seg.dropFirst()
            return encoded ? VirtualRowKeyEncoding.authoredComponent(component) : String(component)
        }
        if !seg.isEmpty && seg.allSatisfy(\.isNumber) {
            return nil
        }
        if seg.count > 1 && seg.hasPrefix("#") && seg.dropFirst().allSatisfy(\.isNumber) {
            return nil
        }
        return encoded ? VirtualRowKeyEncoding.authoredComponent(raw) : seg
    }
    guard keyedSegments.count >= wantParts.count else { return false }
    return zip(keyedSegments.suffix(wantParts.count), wantParts).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
}
