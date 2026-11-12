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

/// Matches an element selector (`"knob"` or slash-path `"slider/knob"`) against a node's `path` and `key`,
/// skipping unkeyed structural segments (`0`, `1`, `#0`, etc.) and optional `@` key prefixes.
/// Parity with `crates/rune/src/flight.rs:103` `selects` and `elements.rs:534` `keyed_suffix`.
func selectsElementSelector(_ selector: String, path: String, key: String?) -> Bool {
    if !selector.contains("/") {
        return key == selector
    }
    if path == selector || path.hasSuffix("/\(selector)") || path.hasSuffix("/@\(selector)") {
        return true
    }
    let wantParts = selector.split(separator: "/").map(String.init)
    guard !wantParts.isEmpty else { return false }
    let keyedSegments = path.split(separator: "/").compactMap { raw -> String? in
        let seg = String(raw)
        if seg.hasPrefix("@") {
            return String(seg.dropFirst())
        }
        if !seg.isEmpty && seg.allSatisfy(\.isNumber) {
            return nil
        }
        if seg.count > 1 && seg.hasPrefix("#") && seg.dropFirst().allSatisfy(\.isNumber) {
            return nil
        }
        return seg
    }
    guard keyedSegments.count >= wantParts.count else { return false }
    return Array(keyedSegments.suffix(wantParts.count)) == wantParts
}
