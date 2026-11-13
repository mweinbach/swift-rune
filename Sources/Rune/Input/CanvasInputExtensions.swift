import Foundation
import RuneMotion

// MARK: - Gesture & Extra-Button Event Payloads (crates/rune/src/input/canvas_input.rs)

/// Trackpad pinch-to-magnify gesture event (`rune::Magnify`).
public struct MagnifyEvent: Sendable, Equatable {
    public var delta: Float
    public var phase: GesturePhase
    public var window: Vec2
    public var local: Vec2
    public var mods: Mods

    public init(
        delta: Float,
        phase: GesturePhase = .changed,
        window: Vec2,
        local: Vec2 = .zero,
        mods: Mods = .none
    ) {
        self.delta = delta
        self.phase = phase
        self.window = window
        self.local = local
        self.mods = mods
    }

    /// Returns a copy with updated `local` coordinates (`MagnifyEvent::at`).
    public func at(_ x: Float, _ y: Float) -> MagnifyEvent {
        var copy = self
        copy.local = Vec2(x, y)
        return copy
    }
}

/// Trackpad two-finger rotation gesture event (`rune::Rotate`).
public struct RotateEvent: Sendable, Equatable {
    public var deltaDegrees: Float
    public var phase: GesturePhase
    public var window: Vec2
    public var local: Vec2
    public var mods: Mods

    public init(
        deltaDegrees: Float,
        phase: GesturePhase = .changed,
        window: Vec2,
        local: Vec2 = .zero,
        mods: Mods = .none
    ) {
        self.deltaDegrees = deltaDegrees
        self.phase = phase
        self.window = window
        self.local = local
        self.mods = mods
    }

    /// Returns a copy with updated `local` coordinates (`RotateEvent::at`).
    public func at(_ x: Float, _ y: Float) -> RotateEvent {
        var copy = self
        copy.local = Vec2(x, y)
        return copy
    }
}

/// Double-tap smart-magnify event (`NSEvent.smartMagnify(with:)`).
public struct SmartMagnifyEvent: Sendable, Equatable {
    public var window: Vec2
    public var local: Vec2
    public var mods: Mods

    public init(window: Vec2, local: Vec2 = .zero, mods: Mods = .none) {
        self.window = window
        self.local = local
        self.mods = mods
    }

    /// Returns a copy with updated `local` coordinates.
    public func at(_ x: Float, _ y: Float) -> SmartMagnifyEvent {
        var copy = self
        copy.local = Vec2(x, y)
        return copy
    }
}

/// Non-primary pointer button press/release event (`rune::PointerButton` for middle/back/forward/etc.).
public struct PointerButtonEvent: Sendable, Equatable {
    public var button: PointerButton
    public var pressed: Bool
    public var window: Vec2
    public var local: Vec2
    public var clicks: Int
    public var mods: Mods

    public init(
        button: PointerButton,
        pressed: Bool,
        window: Vec2,
        local: Vec2 = .zero,
        clicks: Int = 1,
        mods: Mods = .none
    ) {
        self.button = button
        self.pressed = pressed
        self.window = window
        self.local = local
        self.clicks = clicks
        self.mods = mods
    }
}

// MARK: - Key-Path Matching Helpers (tests/key_paths.rs)

/// Matches key-path queries (`exact`, `parent/child`, or `*` segment wildcard) against element paths and keys.
public enum KeyPathMatcher {
    /// Returns `true` if `candidate` matches `pattern`.
    /// Supports exact match, suffix segment match, or `/` path glob with `*` wildcards.
    public static func matches(_ candidate: String, pattern: String) -> Bool {
        if candidate == pattern { return true }
        let patSegs = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let candSegs = candidate.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if patSegs.count == candSegs.count {
            return zip(patSegs, candSegs).allSatisfy { p, c in p == "*" || p == c }
        }
        return false
    }
}

// MARK: - El & Tx Canvas Input Builders

private enum CanvasInputExtraKey {
    static let onMagnify = "canvas.onMagnify"
    static let onRotate = "canvas.onRotate"
    static let onSmartMagnify = "canvas.onSmartMagnify"
    static let pointerButtons = "canvas.pointerButtons"
    static let onKeyUp = "canvas.onKeyUp"
    static let pointerButton = "canvas.tx.button"
    static let scrollIntoViewKeyPath = "canvas.tx.scrollIntoViewKeyPath"
}

extension El {
    /// Registers a pinch-magnify handler returning `true` to consume the gesture (`El::on_magnify`).
    public func onMagnify(_ handler: @escaping (inout State, MagnifyEvent, inout Tx) -> Bool) -> Self {
        var copy = self
        copy.runtimeExtras[CanvasInputExtraKey.onMagnify] = handler
        return copy
    }

    /// Registers a two-finger rotation handler returning `true` to consume (`El::on_rotate`).
    public func onRotate(_ handler: @escaping (inout State, RotateEvent, inout Tx) -> Bool) -> Self {
        var copy = self
        copy.runtimeExtras[CanvasInputExtraKey.onRotate] = handler
        return copy
    }

    /// Registers a double-tap smart-magnify handler returning `true` to consume (`El::on_smart_magnify`).
    public func onSmartMagnify(_ handler: @escaping (inout State, SmartMagnifyEvent, inout Tx) -> Bool) -> Self {
        var copy = self
        copy.runtimeExtras[CanvasInputExtraKey.onSmartMagnify] = handler
        return copy
    }

    /// Registers an extra pointer-button handler (primary/secondary/middle/back/forward) (`El::pointer_buttons`).
    public func pointerButtons(_ handler: @escaping (inout State, PointerButtonEvent, inout Tx) -> Bool) -> Self {
        var copy = self
        copy.runtimeExtras[CanvasInputExtraKey.pointerButtons] = handler
        return copy
    }

    /// Registers a key-release handler dispatched along the focused element -> ancestor chain (`El::on_key_up`).
    public func onKeyUp(_ handler: @escaping (inout State, KeyEvent, inout Tx) -> Bool) -> Self {
        var copy = self
        copy.runtimeExtras[CanvasInputExtraKey.onKeyUp] = handler
        return copy
    }
}

extension Tx {
    /// The pointer button associated with the active button dispatch (`Tx::button`).
    public var button: PointerButton? {
        runtimeActions[CanvasInputExtraKey.pointerButton] as? PointerButton
    }

    internal mutating func setPointerButton(_ button: PointerButton?) {
        if let button {
            runtimeActions[CanvasInputExtraKey.pointerButton] = button
        } else {
            runtimeActions.removeValue(forKey: CanvasInputExtraKey.pointerButton)
        }
    }

    /// Requests scrolling ancestor containers to reveal an element addressed by slash-delimited `keyPath` (`tests/key_paths.rs`).
    public mutating func scrollIntoViewKeyPath(_ keyPath: String) {
        var list = (runtimeActions[CanvasInputExtraKey.scrollIntoViewKeyPath] as? [String]) ?? []
        list.append(keyPath)
        runtimeActions[CanvasInputExtraKey.scrollIntoViewKeyPath] = list
    }
}

// MARK: - Runtime Dispatch (Gestures, Pointer Buttons, KeyUp, KeyPath Scroll)

extension Runtime {
    private func canvasIntersect(_ a: MotionRect, _ b: MotionRect) -> MotionRect {
        let minX = max(a.x, b.x)
        let minY = max(a.y, b.y)
        let maxX = min(a.x + a.width, b.x + b.width)
        let maxY = min(a.y + a.height, b.y + b.height)
        return MotionRect.fromXYWH(minX, minY, max(0, maxX - minX), max(0, maxY - minY))
    }

    private func canvasContains(_ rect: MotionRect, _ point: Vec2) -> Bool {
        point.x >= rect.x && point.x < rect.x + rect.width &&
            point.y >= rect.y && point.y < rect.y + rect.height
    }

    private func canvasHitNode(
        at point: Vec2,
        matching: (FlatNode) -> Bool
    ) -> (node: FlatNode, rect: MotionRect, local: Vec2)? {
        let sorted = flatNodes.indices.sorted { a, b in
            let za = flatNodes[a].zOrder
            let zb = flatNodes[b].zOrder
            if za != zb { return za < zb }
            return a < b
        }

        var blockerPath: String? = nil
        for idx in sorted.reversed() {
            let node = flatNodes[idx]
            if node.effectiveInert || node.el.opacity <= 0.001 { continue }
            let infoRect = presentedRectByPath[node.path] ?? node.targetRect
            let hitBox = canvasIntersect(node.clipRect, infoRect)
            guard canvasContains(hitBox, point) else { continue }
            if let blocker = blockerPath, !blocker.hasPrefix(node.path + "/") {
                continue
            }
            if matching(node) {
                return (node, infoRect, Vec2(point.x - infoRect.x, point.y - infoRect.y))
            }
            let hasVis = node.el.background.a > 0.001 || node.el.gradient != nil ||
                (node.el.borderWidth > 0 && node.el.borderColor.a > 0.001) ||
                node.el.imagePayload != nil || node.el.backdropBlur >= 0.5 || !node.el.shapes.isEmpty
            if blockerPath == nil && (hasVis || node.el.explicitHit || node.el.isModal) {
                blockerPath = node.path
            }
        }
        return nil
    }

    /// Dispatches a trackpad magnify gesture (`delta`, `phase`) at window coordinates `pos`.
    @discardableResult
    public func magnifyEvent(
        delta: Float,
        phase: GesturePhase = .changed,
        at pos: Vec2,
        mods: Mods = .none,
        at now: Double
    ) -> Bool {
        guard let hit = canvasHitNode(at: pos, matching: { $0.el.runtimeExtras[CanvasInputExtraKey.onMagnify] != nil }),
              let handler = hit.node.el.runtimeExtras[CanvasInputExtraKey.onMagnify] as? (inout State, MagnifyEvent, inout Tx) -> Bool else {
            return false
        }
        var tx = Tx()
        let event = MagnifyEvent(delta: delta, phase: phase, window: pos, local: hit.local, mods: mods)
        let consumed = handler(&state, event, &tx)
        applyTx(tx, at: now)
        return consumed
    }

    /// Dispatches a trackpad rotation gesture (`deltaDegrees`, `phase`) at window coordinates `pos`.
    @discardableResult
    public func rotateEvent(
        deltaDegrees: Float,
        phase: GesturePhase = .changed,
        at pos: Vec2,
        mods: Mods = .none,
        at now: Double
    ) -> Bool {
        guard let hit = canvasHitNode(at: pos, matching: { $0.el.runtimeExtras[CanvasInputExtraKey.onRotate] != nil }),
              let handler = hit.node.el.runtimeExtras[CanvasInputExtraKey.onRotate] as? (inout State, RotateEvent, inout Tx) -> Bool else {
            return false
        }
        var tx = Tx()
        let event = RotateEvent(deltaDegrees: deltaDegrees, phase: phase, window: pos, local: hit.local, mods: mods)
        let consumed = handler(&state, event, &tx)
        applyTx(tx, at: now)
        return consumed
    }

    /// Dispatches a trackpad smart-magnify double-tap at window coordinates `pos`.
    @discardableResult
    public func smartMagnify(
        at pos: Vec2,
        mods: Mods = .none,
        at now: Double
    ) -> Bool {
        guard let hit = canvasHitNode(at: pos, matching: { $0.el.runtimeExtras[CanvasInputExtraKey.onSmartMagnify] != nil }),
              let handler = hit.node.el.runtimeExtras[CanvasInputExtraKey.onSmartMagnify] as? (inout State, SmartMagnifyEvent, inout Tx) -> Bool else {
            return false
        }
        var tx = Tx()
        let event = SmartMagnifyEvent(window: pos, local: hit.local, mods: mods)
        let consumed = handler(&state, event, &tx)
        applyTx(tx, at: now)
        return consumed
    }

    /// Dispatches a pointer button press to `.pointerButtons(...)`, falling back to `pointerDown` for primary/secondary buttons.
    @discardableResult
    public func pointerButtonDown(
        at pos: Vec2,
        button: PointerButton,
        clicks: Int = 1,
        mods: Mods = .none,
        at now: Double
    ) -> Bool {
        if let hit = canvasHitNode(at: pos, matching: { $0.el.runtimeExtras[CanvasInputExtraKey.pointerButtons] != nil }),
           let handler = hit.node.el.runtimeExtras[CanvasInputExtraKey.pointerButtons] as? (inout State, PointerButtonEvent, inout Tx) -> Bool {
            var tx = Tx()
            tx.setPointerButton(button)
            let event = PointerButtonEvent(button: button, pressed: true, window: pos, local: hit.local, clicks: clicks, mods: mods)
            let consumed = handler(&state, event, &tx)
            applyTx(tx, at: now)
            if consumed { return true }
        }
        if button == .primary || button == .secondary {
            pointerDown(at: pos, button: button, mods: mods, at: now)
            return true
        }
        return false
    }

    /// Dispatches a pointer button release to `.pointerButtons(...)`, falling back to `pointerUp` for primary/secondary buttons.
    @discardableResult
    public func pointerButtonUp(
        at pos: Vec2,
        button: PointerButton,
        clicks: Int = 1,
        mods: Mods = .none,
        at now: Double
    ) -> Bool {
        if let hit = canvasHitNode(at: pos, matching: { $0.el.runtimeExtras[CanvasInputExtraKey.pointerButtons] != nil }),
           let handler = hit.node.el.runtimeExtras[CanvasInputExtraKey.pointerButtons] as? (inout State, PointerButtonEvent, inout Tx) -> Bool {
            var tx = Tx()
            tx.setPointerButton(button)
            let event = PointerButtonEvent(button: button, pressed: false, window: pos, local: hit.local, clicks: clicks, mods: mods)
            let consumed = handler(&state, event, &tx)
            applyTx(tx, at: now)
            if consumed { return true }
        }
        if button == .primary || button == .secondary {
            pointerUp(at: pos, button: button, mods: mods, at: now)
            return true
        }
        return false
    }

    /// Routes key release (`keyUp`) along the focused element -> ancestor chain (guarded when IME composition is active).
    @discardableResult
    public func keyUp(
        _ event: KeyEvent,
        imeActive: Bool = false,
        at now: Double
    ) -> Bool {
        guard !imeActive else { return false }
        guard let fPath = focusedPath, let fIdx = flatNodes.firstIndex(where: { $0.path == fPath }) else { return false }

        var walkIdx: Int? = fIdx
        while let curIdx = walkIdx {
            let node = flatNodes[curIdx]
            if node.effectiveInert { break }
            if let handler = node.el.runtimeExtras[CanvasInputExtraKey.onKeyUp] as? (inout State, KeyEvent, inout Tx) -> Bool {
                var tx = Tx()
                let handled = handler(&state, event, &tx)
                applyTx(tx, at: now)
                if handled { return true }
            }
            if node.el.isModal { break }
            walkIdx = node.parentIndex
        }
        return false
    }

    /// Resolves the key sequence path (`a/b/c`) for a mounted `FlatNode` using ancestor element `key` tags.
    public func keyPath(forNodeAt index: Int) -> String? {
        guard index >= 0 && index < flatNodes.count else { return nil }
        var parts: [String] = []
        var cur: Int? = index
        while let idx = cur {
            if let k = flatNodes[idx].key, !k.isEmpty {
                parts.append(k)
            }
            cur = flatNodes[idx].parentIndex
        }
        guard !parts.isEmpty else { return nil }
        return parts.reversed().joined(separator: "/")
    }

    /// Finds the first mounted node matching slash-delimited `keyPath` (supports `*` wildcards) and scrolls
    /// enclosing scroll containers so it becomes visible (`tests/key_paths.rs`).
    @discardableResult
    public func scrollToKeyPath(_ keyPathPattern: String, at now: Double) -> Bool {
        guard let targetIdx = flatNodes.indices.first(where: { idx in
            guard let kp = self.keyPath(forNodeAt: idx) else { return false }
            return KeyPathMatcher.matches(kp, pattern: keyPathPattern)
        }) else {
            return false
        }
        let targetNode = flatNodes[targetIdx]
        let targetRect = targetNode.targetRect

        var moved = false
        var walkIdx = targetNode.parentIndex
        while let idx = walkIdx {
            let scroller = flatNodes[idx]
            if !scroller.el.layout.scrollAxes.isEmpty {
                let sPath = scroller.path
                let vp = scroller.targetRect
                var offset = scrollOffsets[sPath] ?? .zero
                let maxX = max(0, scroller.contentSize.x - vp.width)
                let maxY = max(0, scroller.contentSize.y - vp.height)

                if scroller.el.layout.scrollAxes.contains(.horizontal) {
                    let relLeft = (targetRect.x - vp.x) + offset.x
                    let relRight = relLeft + targetRect.width
                    if relLeft < offset.x {
                        offset.x = relLeft.clamped(to: 0...maxX)
                    } else if relRight > offset.x + vp.width {
                        offset.x = (relRight - vp.width).clamped(to: 0...maxX)
                    }
                }
                if scroller.el.layout.scrollAxes.contains(.vertical) {
                    let relTop = (targetRect.y - vp.y) + offset.y
                    let relBottom = relTop + targetRect.height
                    if relTop < offset.y {
                        offset.y = relTop.clamped(to: 0...maxY)
                    } else if relBottom > offset.y + vp.height {
                        offset.y = (relBottom - vp.height).clamped(to: 0...maxY)
                    }
                }
                if offset != (scrollOffsets[sPath] ?? .zero) {
                    scrollOffsets[sPath] = offset
                    if let sKey = scroller.key {
                        var tx = Tx()
                        tx.scrollTo(sKey, offset: offset, animated: false)
                        applyTx(tx, at: now)
                    }
                    moved = true
                }
            }
            walkIdx = scroller.parentIndex
        }
        if moved {
            dirtyCommit(at: now)
        }
        return true
    }
}
