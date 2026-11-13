import Foundation

// MARK: - Sticky Math (`crates/rune/src/runtime/scroll/sticky.rs`)

internal enum StickyMath {
    static let shadowRamp: Float = 8.0

    struct FrameBounds: Sendable, Equatable {
        var bandTop: Float
        var bandBottom: Float
        var boxTop: Float
        var boxBottom: Float
        var bandLeft: Float
        var bandRight: Float
        var boxLeft: Float
        var boxRight: Float

        static let unbounded = FrameBounds(
            bandTop: -.infinity, bandBottom: .infinity,
            boxTop: -.infinity, boxBottom: .infinity,
            bandLeft: -.infinity, bandRight: .infinity,
            boxLeft: -.infinity, boxRight: .infinity
        )
    }

    /// Computes `[dx, dy]` shift for a single sticky node (`sticky::shift`).
    static func shift(
        edge: StickyEdge,
        inset: Float,
        tail: Bool = false,
        elemRect: (top: Float, bottom: Float, left: Float, right: Float),
        frame: FrameBounds
    ) -> Float {
        let effInset: Float
        if tail, case .top = edge {
            effInset = inset - (elemRect.bottom - elemRect.top)
        } else {
            effInset = inset
        }
        let d: Float
        switch edge {
        case .left:
            d = max(0.0, min(frame.bandLeft + effInset - elemRect.left, frame.boxRight - elemRect.right))
        case .top:
            d = max(0.0, min(frame.bandTop + effInset - elemRect.top, frame.boxBottom - elemRect.bottom))
        case .bottom:
            d = min(0.0, max(frame.bandBottom - effInset - elemRect.bottom, frame.boxTop - elemRect.top))
        }
        return d.isFinite ? d : 0.0
    }

    static func stuckShadowFactor(shift: Float) -> Float {
        let mag = abs(shift)
        guard mag > 0 else { return 0 }
        return min(1.0, mag / shadowRamp)
    }

    static func stuckFadeFactor(nextSiblingTop: Float, currentDrawnTop: Float, lead: Float, span: Float) -> Float {
        guard span > 0 else {
            return nextSiblingTop - currentDrawnTop >= lead ? 1.0 : 0.0
        }
        return ((nextSiblingTop - currentDrawnTop - lead) / span).clamped(to: 0.0...1.0)
    }

    static func stuckRevealFactor(parentShift: Float, span: Float) -> Float {
        guard parentShift > 0 else { return 0.0 }
        return min(1.0, parentShift / max(1e-3, span))
    }
}

// MARK: - Scroll Edge & Reveal Math (`crates/rune/src/runtime/scroll/edge.rs`)

internal enum ScrollEdgeMath {
    static let fadeInExtent: Double = 15.0

    /// Packed `(width, offset)` for an edge with `strength` in `0...1` on a smoothstep ramp.
    static func partial(width: Float, strength: Float) -> (width: Float, offset: Float) {
        if strength <= 0.0 || width <= 0.0 { return (0.0, 0.0) }
        if strength >= 1.0 { return (width, 0.0) }
        let clamped = Double((2.0 * strength - 1.0).clamped(to: -1.0...1.0))
        let offset = Float(0.5 - sin(asin(clamped) / 3.0)).clamped(to: 0.0...0.995)
        return (width / (1.0 - offset), offset)
    }

    /// Packed `(width, offset)` on a linear ramp.
    static func partialLinear(width: Float, strength: Float) -> (width: Float, offset: Float) {
        if strength <= 0.0 || width <= 0.0 { return (0.0, 0.0) }
        if strength >= 1.0 { return (width, 0.0) }
        let offset = min(0.995, 1.0 - strength)
        return (width / (1.0 - offset), offset)
    }

    static func edgeRamp(style: ScrollFadeStyle, width: Float, hidden: Double, scale: Float) -> (width: Float, offset: Float) {
        if style.feather {
            let w = min(width, Float(max(0.0, hidden)) * scale)
            return (style.linear ? -w : w, 0.0)
        }
        let full = style.fullAt > 0.0 ? Double(style.fullAt) : fadeInExtent
        let strength = Float((hidden / full).clamped(to: 0.0...1.0))
        if !style.linear {
            return partial(width: width, strength: strength)
        }
        let (w, o) = partialLinear(width: width, strength: strength)
        return (-w, o)
    }

    /// Minimal scroll offset that places `[top, top + height)` in `[offset, offset + viewport)` with `margin`.
    static func reveal(offset: Double, top: Double, height: Double, viewport: Double, margin: Double) -> Double {
        let clampedMargin = min(margin, max(0.0, (viewport - height) / 2.0))
        let start = top - clampedMargin
        let end = top + height + clampedMargin
        if start <= offset && end >= offset + viewport {
            return offset
        } else if start < offset {
            return start
        } else if end > offset + viewport {
            return end - viewport
        } else {
            return offset
        }
    }
}

// MARK: - Ongoing Keep & Reveal Request State Machine (`crates/rune/src/runtime/scroll/requests.rs`)

internal struct ScrollKeepHold: Equatable, Sendable {
    var path: String
    var inset: Float
}

internal struct ScrollKeep: Equatable, Sendable {
    var path: String
    var viewport: String
    var was: Float
    var virtualRow: (listPath: String, rowKey: String, yInRow: Float)?
    var hold: ScrollKeepHold?

    static func == (lhs: ScrollKeep, rhs: ScrollKeep) -> Bool {
        lhs.path == rhs.path
            && lhs.viewport == rhs.viewport
            && lhs.was == rhs.was
            && lhs.virtualRow?.listPath == rhs.virtualRow?.listPath
            && lhs.virtualRow?.rowKey == rhs.virtualRow?.rowKey
            && lhs.virtualRow?.yInRow == rhs.virtualRow?.yInRow
            && lhs.hold == rhs.hold
    }
}

internal struct ScrollRevealTarget: Equatable, Sendable {
    var scope: String?
    var key: String
    var viewport: String
    var center: Bool
    var atEnd: Bool
}

internal enum ScrollShownState: Equatable, Sendable {
    case unmounted
    case loose
    case free
    case pinned(Float)
}

internal enum ScrollRequestEffect: Equatable, Sendable {
    case rest
    case move(Double)
}

internal struct ScrollRequestsState: Sendable {
    var keeps: [ScrollKeep] = []
    var reveals: [ScrollRevealTarget] = []

    var isEmpty: Bool { keeps.isEmpty && reveals.isEmpty }
    var hasKeeps: Bool { !keeps.isEmpty }

    func owns(_ viewportPath: String) -> Bool {
        keeps.contains(where: { $0.viewport == viewportPath })
            || reveals.contains(where: { $0.viewport == viewportPath })
    }

    mutating func takeKeeps() -> [ScrollKeep] {
        let out = keeps
        keeps.removeAll(keepingCapacity: true)
        return out
    }

    mutating func restoreKeeps(_ saved: [ScrollKeep]) {
        keeps = saved
    }

    mutating func arriveCapture(_ k: ScrollKeep) {
        keeps.removeAll { $0.viewport == k.viewport }
        reveals.removeAll { $0.viewport == k.viewport }
        keeps.append(k)
    }

    mutating func arriveFoldAnchor(_ k: ScrollKeep) {
        keeps.removeAll { $0.viewport == k.viewport }
        keeps.append(k)
    }

    mutating func arriveReveal(_ r: ScrollRevealTarget) {
        reveals.removeAll { $0.viewport == r.viewport }
        reveals.append(r)
    }

    mutating func stepPlace(
        first: Bool,
        scope: String?,
        key: String,
        viewport: String,
        center: Bool,
        atEnd: Bool,
        from: Double,
        to: Double
    ) -> ScrollRequestEffect? {
        if first {
            arriveReveal(ScrollRevealTarget(scope: scope, key: key, viewport: viewport, center: center, atEnd: atEnd))
        } else if let idx = reveals.firstIndex(where: { $0.viewport == viewport }) {
            reveals[idx].atEnd = reveals[idx].atEnd || atEnd
        }
        if abs(to - from) < 0.5 {
            return first ? .rest : nil
        } else {
            return .move(to)
        }
    }

    mutating func stepNewTail(viewport: String, key: String) {
        for i in reveals.indices where reveals[i].viewport == viewport && reveals[i].atEnd {
            reveals[i].scope = nil
            reveals[i].key = key
        }
    }

    mutating func stepCancel() {
        keeps.removeAll()
        reveals.removeAll()
    }

    mutating func stepDestination() {
        reveals.removeAll()
    }

    mutating func stepFoldOpens(viewport: String, end: Int, indexOfPath: (String) -> Int?) {
        keeps.removeAll { k in
            guard k.viewport == viewport else { return false }
            guard let idx = indexOfPath(k.path) else { return false }
            return idx < end
        }
    }

    mutating func stepEndTakesOver(givingHeaders: Set<String>, isPinned: (String) -> Bool) {
        keeps.removeAll { k in
            guard let hold = k.hold else { return false }
            return givingHeaders.contains(hold.path) && isPinned(k.viewport)
        }
    }

    mutating func stepEndClamps(shown: (ScrollKeep) -> ScrollShownState) {
        keeps.removeAll { k in
            switch shown(k) {
            case .loose:
                return true
            case .pinned(let top) where top > k.was + 0.5:
                return true
            default:
                return false
            }
        }
    }

    mutating func stepFinish(
        gliding: (String) -> Bool,
        animating: (String) -> Bool,
        mounted: (ScrollRevealTarget) -> Bool
    ) {
        keeps.removeAll { !animating($0.viewport) }
        reveals.removeAll { r in
            !(gliding(r.viewport) || (animating(r.viewport) && mounted(r)))
        }
    }
}
