import Foundation

/// Coordinate frame in which layout motion (`animateLayout`) travels.
public enum Travel: Sendable, Hashable, Codable {
    /// Moves only when the node's position relative to its parent changes; rides parent motion 1:1.
    case parent
    /// Animates across screen space when moved between parents (shared-element / active-tab pill).
    case screen
}

/// Per-node layout animation configuration, including directional leading/trailing edge springs
/// and width-leads-height choreography.
public struct LayoutAnim: Sendable, Hashable {
    public var spring: Spring
    public var leadingSpring: Spring?
    public var widthScale: Float?
    public var travel: Travel

    public init(
        spring: Spring = MotionTokens.SETTLE,
        leadingSpring: Spring? = nil,
        widthScale: Float? = nil,
        travel: Travel = .parent
    ) {
        self.spring = spring
        self.leadingSpring = leadingSpring
        self.widthScale = widthScale
        self.travel = travel
    }

    /// Width settles at `0.78 * duration` ahead of height (classic macOS/iOS card expansion feel).
    public static func widthLeads(_ spring: Spring = MotionTokens.SETTLE) -> LayoutAnim {
        LayoutAnim(spring: spring, widthScale: 0.78)
    }

    /// Advancing edges move on `lead`, trailing edges follow on `trail`.
    public static func lead(lead: Spring = MotionTokens.LEAD, trail: Spring = MotionTokens.SETTLE) -> LayoutAnim {
        LayoutAnim(spring: trail, leadingSpring: lead)
    }

    public func withTravel(_ travel: Travel) -> LayoutAnim {
        var copy = self
        copy.travel = travel
        return copy
    }
}

/// Declarative motion specification committed per element on each layout pass.
public struct NodeSpec: Sendable, Equatable {
    public var id: NodeId
    public var parent: NodeId?
    public var rect: MotionRect
    public var opacity: Float
    public var scale: Vec2
    public var rotate: Float
    public var offset: Vec2
    public var corners: Corners
    public var blur: Float
    public var fill: MotionColor?
    public var border: MotionColor?
    public var layoutAnim: LayoutAnim?
    public var styleSpring: Spring?
    public var transition: Transition?

    public init(
        id: NodeId,
        parent: NodeId? = nil,
        rect: MotionRect,
        opacity: Float = 1.0,
        scale: Vec2 = Vec2(1, 1),
        rotate: Float = 0,
        offset: Vec2 = .zero,
        corners: Corners = .all(0),
        blur: Float = 0,
        fill: MotionColor? = nil,
        border: MotionColor? = nil,
        layoutAnim: LayoutAnim? = nil,
        styleSpring: Spring? = nil,
        transition: Transition? = nil
    ) {
        self.id = id
        self.parent = parent
        self.rect = rect
        self.opacity = opacity
        self.scale = scale
        self.rotate = rotate
        self.offset = offset
        self.corners = corners
        self.blur = blur
        self.fill = fill
        self.border = border
        self.layoutAnim = layoutAnim
        self.styleSpring = styleSpring
        self.transition = transition
    }
}

/// Sampled presentation state for a single mounted or exiting node on the current frame.
public struct Presented: Sendable, Equatable {
    public var id: NodeId
    public var parent: NodeId?
    /// Presented rectangle snapped to 1/64 device pixel (includes transition & offset translation).
    public var rect: MotionRect
    /// Unsnapped layout target rectangle.
    public var targetRect: MotionRect
    /// Optional directional reveal clip rectangle.
    public var revealClip: MotionRect?
    public var opacity: Float
    public var scale: Vec2
    public var rotate: Float
    public var corners: Corners
    public var blur: Float
    public var fill: MotionColor?
    public var border: MotionColor?
    public var presence: Float
    public var isExiting: Bool
    public var isMoving: Bool

    public init(
        id: NodeId,
        parent: NodeId?,
        rect: MotionRect,
        targetRect: MotionRect,
        revealClip: MotionRect?,
        opacity: Float,
        scale: Vec2,
        rotate: Float,
        corners: Corners,
        blur: Float,
        fill: MotionColor?,
        border: MotionColor?,
        presence: Float,
        isExiting: Bool,
        isMoving: Bool
    ) {
        self.id = id
        self.parent = parent
        self.rect = rect
        self.targetRect = targetRect
        self.revealClip = revealClip
        self.opacity = opacity
        self.scale = scale
        self.rotate = rotate
        self.corners = corners
        self.blur = blur
        self.fill = fill
        self.border = border
        self.presence = presence
        self.isExiting = isExiting
        self.isMoving = isMoving
    }
}

/// Output of `Scene.frame(at:)`: presented nodes (in tree + exiting order) and animation status.
public struct FrameOutput: Sendable {
    public var nodes: [Presented]
    public var byId: [NodeId: Presented]
    public var isAnimating: Bool

    public init(nodes: [Presented], byId: [NodeId: Presented], isAnimating: Bool) {
        self.nodes = nodes
        self.byId = byId
        self.isAnimating = isAnimating
    }
}

/// Declarative motion coordinator sitting between Flexbox layout and the GPU/CPU renderer.
///
/// Handles:
/// - Independent 4-edge (`[left, top, right, bottom]`) layout morphing (`animateLayout`).
/// - Parent-shift cancellation (`Travel.parent`) vs cross-parent shared-element flight (`Travel.screen`).
/// - Directional leading/trailing edge springs and width-leads-height choreography.
/// - Enter & exit presence transitions (`Transition`), keeping unmounted nodes alive until
///   their exit transition settles and smoothly reviving nodes that remount mid-exit!
public struct Scene: Sendable {
    private struct Entry: Sendable {
        var spec: NodeSpec
        var isExiting: Bool
        /// Last committed parent target origin `(left, top)` for `Travel.parent` shift cancellation.
        var lastParentOrigin: Vec2
        /// Order index from the most recent commit so exiting nodes paint near their former siblings.
        var orderIndex: Int
    }

    private static let EDGE_LEFT = Prop<Float>(id: PropId(101), propClass: .spatial, name: "rect.left")
    private static let EDGE_TOP = Prop<Float>(id: PropId(102), propClass: .spatial, name: "rect.top")
    private static let EDGE_RIGHT = Prop<Float>(id: PropId(103), propClass: .spatial, name: "rect.right")
    private static let EDGE_BOTTOM = Prop<Float>(id: PropId(104), propClass: .spatial, name: "rect.bottom")

    public var store: AnimationStore
    private var entries: [NodeId: Entry] = [:]
    private var hasCommittedOnce: Bool = false

    public init(pixelScale: Float = 2.0, reducedMotion: Bool = false) {
        self.store = AnimationStore(pixelScale: pixelScale, reducedMotion: reducedMotion)
    }

    public var pixelScale: Float {
        get { store.pixelScale }
        set { store.pixelScale = newValue }
    }

    public var reducedMotion: Bool {
        get { store.reducedMotion }
        set { store.reducedMotion = newValue }
    }

    public var isAnimating: Bool {
        store.isAnimating
    }

    /// Commits a freshly laid-out list of `NodeSpec`s at timestamp `now`.
    /// When `initialCut` is true (e.g. initial mount or explicit `settle()`), everything lands without enter springs.
    public mutating func commit(_ specs: [NodeSpec], at now: Double, initialCut: Bool = false) {
        store.sample(at: now)
        let cut = initialCut || !hasCommittedOnce
        hasCommittedOnce = true

        // Map of new parent target origins `(left, top)` for `Travel.parent`.
        var newOrigins: [NodeId: Vec2] = [:]
        newOrigins.reserveCapacity(specs.count)
        for s in specs {
            newOrigins[s.id] = Vec2(s.rect.left, s.rect.top)
        }

        var seen = Set<NodeId>(minimumCapacity: specs.count)

        for (index, spec) in specs.enumerated() {
            seen.insert(spec.id)
            let parentOrigin = spec.parent.flatMap { newOrigins[$0] } ?? .zero

            if var existing = entries[spec.id] {
                let wasExiting = existing.isExiting
                let oldParentOrigin = existing.lastParentOrigin
                let parentDelta = Vec2(parentOrigin.x - oldParentOrigin.x, parentOrigin.y - oldParentOrigin.y)

                // If `Travel.parent` (or no layout anim) and parent stayed the same, shift edges by parentDelta first
                // so the node rides its moving parent 1:1 without exciting its own spring!
                let travel = spec.layoutAnim?.travel ?? .parent
                if travel == .parent, existing.spec.parent == spec.parent, (parentDelta.x != 0 || parentDelta.y != 0) {
                    store.shift(spec.id, Self.EDGE_LEFT, by: MotionLanes(parentDelta.x))
                    store.shift(spec.id, Self.EDGE_RIGHT, by: MotionLanes(parentDelta.x))
                    store.shift(spec.id, Self.EDGE_TOP, by: MotionLanes(parentDelta.y))
                    store.shift(spec.id, Self.EDGE_BOTTOM, by: MotionLanes(parentDelta.y))
                }

                // Update 4 edges
                if cut || spec.layoutAnim == nil {
                    store.snap(spec.id, Self.EDGE_LEFT, to: spec.rect.left)
                    store.snap(spec.id, Self.EDGE_TOP, to: spec.rect.top)
                    store.snap(spec.id, Self.EDGE_RIGHT, to: spec.rect.right)
                    store.snap(spec.id, Self.EDGE_BOTTOM, to: spec.rect.bottom)
                } else if let la = spec.layoutAnim {
                    animateEdges(id: spec.id, target: spec.rect, layout: la, at: now)
                }

                // Update visual style tracks
                let styleCurve: Curve = (!cut && spec.styleSpring != nil) ? .spring(spec.styleSpring!) : .instant
                applyStyle(spec: spec, curve: styleCurve, at: now)

                // Revive if it was mid-exit!
                if wasExiting {
                    let enterSpring = spec.transition?.insertion.spring ?? spec.styleSpring ?? MotionTokens.SETTLE
                    let curve: Curve = cut ? .instant : .spring(enterSpring)
                    store.set(spec.id, Props.PRESENCE, to: 1.0, anim: Anim(curve: curve), at: now)
                }

                existing.spec = spec
                existing.isExiting = false
                existing.lastParentOrigin = parentOrigin
                existing.orderIndex = index
                entries[spec.id] = existing
            } else {
                // Brand new node
                store.snap(spec.id, Self.EDGE_LEFT, to: spec.rect.left)
                store.snap(spec.id, Self.EDGE_TOP, to: spec.rect.top)
                store.snap(spec.id, Self.EDGE_RIGHT, to: spec.rect.right)
                store.snap(spec.id, Self.EDGE_BOTTOM, to: spec.rect.bottom)
                applyStyle(spec: spec, curve: .instant, at: now, initialSnap: true)

                if !cut, let trans = spec.transition {
                    store.snap(spec.id, Props.PRESENCE, to: 0.0)
                    let sp = trans.insertion.spring ?? spec.styleSpring ?? MotionTokens.SETTLE
                    store.set(spec.id, Props.PRESENCE, to: 1.0, anim: Anim(curve: .spring(sp)), at: now)
                } else {
                    store.snap(spec.id, Props.PRESENCE, to: 1.0)
                }

                entries[spec.id] = Entry(
                    spec: spec,
                    isExiting: false,
                    lastParentOrigin: parentOrigin,
                    orderIndex: index
                )
            }
        }

        // Handle unmounted nodes: start exit transition or remove immediately.
        var toRemove: [NodeId] = []
        for (id, var entry) in entries where !seen.contains(id) {
            if cut {
                toRemove.append(id)
                continue
            }
            if !entry.isExiting {
                if let trans = entry.spec.transition {
                    entry.isExiting = true
                    let exitSpring = trans.removal.spring
                        ?? entry.spec.styleSpring?.scaledDuration(0.8)
                        ?? MotionTokens.SETTLE_PAIR.exit
                    store.set(id, Props.PRESENCE, to: 0.0, anim: Anim(curve: .spring(exitSpring)), at: now)
                    entries[id] = entry
                } else {
                    toRemove.append(id)
                }
            } else {
                let p = store.get(id, Props.PRESENCE) ?? 0.0
                if !store.isMoving(id, Props.PRESENCE) && p <= 1e-3 {
                    toRemove.append(id)
                }
            }
        }
        for id in toRemove {
            entries.removeValue(forKey: id)
            store.removeNode(id)
        }
    }

    /// Evaluates the scene at timestamp `now` and returns presented geometry/visuals for all
    /// mounted and still-exiting nodes.
    public mutating func frame(at now: Double) -> FrameOutput {
        store.sample(at: now)

        // Prune any exiting nodes whose presence track finished settling at 0 on this sample.
        var finishedExits: [NodeId] = []
        for (id, entry) in entries where entry.isExiting {
            let p = store.get(id, Props.PRESENCE) ?? 0.0
            if !store.isMoving(id, Props.PRESENCE) && p <= 1e-3 {
                finishedExits.append(id)
            }
        }
        for id in finishedExits {
            entries.removeValue(forKey: id)
            store.removeNode(id)
        }

        let sortedEntries = entries.values.sorted { a, b in
            if a.orderIndex != b.orderIndex { return a.orderIndex < b.orderIndex }
            return a.spec.id.rawValue < b.spec.id.rawValue
        }

        // First compute presented parent deltas so exiting children ride moving parents naturally.
        var nodes: [Presented] = []
        nodes.reserveCapacity(sortedEntries.count)
        var byId: [NodeId: Presented] = [:]
        byId.reserveCapacity(sortedEntries.count)

        for entry in sortedEntries {
            let id = entry.spec.id
            let left = store.get(id, Self.EDGE_LEFT) ?? entry.spec.rect.left
            let top = store.get(id, Self.EDGE_TOP) ?? entry.spec.rect.top
            let right = store.get(id, Self.EDGE_RIGHT) ?? entry.spec.rect.right
            let bottom = store.get(id, Self.EDGE_BOTTOM) ?? entry.spec.rect.bottom
            var rawRect = MotionRect(left: left, top: top, right: max(left, right), bottom: max(top, bottom))

            let baseOpacity = store.get(id, Props.OPACITY) ?? entry.spec.opacity
            let baseScale = store.get(id, Props.SCALE) ?? entry.spec.scale
            let baseRotate = store.get(id, Props.ROTATE) ?? entry.spec.rotate
            let baseOffset = store.get(id, Props.OFFSET) ?? entry.spec.offset
            let corners = store.get(id, Props.CORNERS) ?? entry.spec.corners
            let baseBlur = (store.get(id, Props.BLUR) ?? Blur(entry.spec.blur)).radius
            let fill = entry.spec.fill != nil ? (store.get(id, Props.FILL) ?? entry.spec.fill) : nil
            let border = entry.spec.border != nil ? (store.get(id, Props.BORDER) ?? entry.spec.border) : nil
            let presence = store.get(id, Props.PRESENCE) ?? 1.0

            var transOpacity: Float = 1.0
            var transScale = Vec2(1, 1)
            var transOffset = Vec2.zero
            var transBlur: Float = 0.0
            var revealClip: MotionRect? = nil

            if let trans = entry.spec.transition {
                let activeEffect = entry.isExiting ? trans.removal : trans.insertion
                if entry.isExiting || presence < 0.9999 || store.isMoving(id, Props.PRESENCE) {
                    let size = Vec2(rawRect.width, rawRect.height)
                    let eval = activeEffect.evaluate(presence: presence, size: size)
                    transOpacity = eval.opacity
                    transScale = eval.scale
                    transOffset = eval.offset
                    transBlur = eval.blur
                    if let rev = activeEffect.reveal {
                        revealClip = snapRect(rev.clipRect(for: rawRect, presence: presence), pixelScale: store.pixelScale)
                    }
                }
            }

            let totalOffset = Vec2(baseOffset.x + transOffset.x, baseOffset.y + transOffset.y)
            rawRect = rawRect.offsetBy(totalOffset)
            let snapped = snapRect(rawRect, pixelScale: store.pixelScale)

            let moving =
                store.isMoving(id, Self.EDGE_LEFT) ||
                store.isMoving(id, Self.EDGE_TOP) ||
                store.isMoving(id, Self.EDGE_RIGHT) ||
                store.isMoving(id, Self.EDGE_BOTTOM) ||
                store.isMoving(id, Props.OPACITY) ||
                store.isMoving(id, Props.SCALE) ||
                store.isMoving(id, Props.OFFSET) ||
                store.isMoving(id, Props.ROTATE) ||
                store.isMoving(id, Props.BLUR) ||
                store.isMoving(id, Props.PRESENCE) ||
                store.isMoving(id, Props.FILL) ||
                store.isMoving(id, Props.BORDER) ||
                store.isMoving(id, Props.CORNERS)

            let presented = Presented(
                id: id,
                parent: entry.spec.parent,
                rect: snapped,
                targetRect: entry.spec.rect,
                revealClip: revealClip,
                opacity: (baseOpacity * transOpacity).clamped(to: 0...1),
                scale: Vec2(baseScale.x * transScale.x, baseScale.y * transScale.y),
                rotate: baseRotate,
                corners: corners,
                blur: baseBlur + transBlur,
                fill: fill,
                border: border,
                presence: presence,
                isExiting: entry.isExiting,
                isMoving: moving
            )
            nodes.append(presented)
            byId[id] = presented
        }

        return FrameOutput(nodes: nodes, byId: byId, isAnimating: store.isAnimating)
    }

    /// Cuts all active tracks immediately to their targets and drops exiting nodes.
    public mutating func settle(at now: Double) {
        let liveSpecs = entries.values
            .filter { !$0.isExiting }
            .sorted { $0.orderIndex < $1.orderIndex }
            .map(\.spec)
        entries.removeAll()
        store.clear()
        hasCommittedOnce = false
        commit(liveSpecs, at: now, initialCut: true)
    }

    private mutating func animateEdges(id: NodeId, target: MotionRect, layout: LayoutAnim, at now: Double) {
        let curL = store.target(id, Self.EDGE_LEFT) ?? target.left
        let curT = store.target(id, Self.EDGE_TOP) ?? target.top
        let curR = store.target(id, Self.EDGE_RIGHT) ?? target.right
        let curB = store.target(id, Self.EDGE_BOTTOM) ?? target.bottom

        let baseHorizontal = layout.widthScale.map { layout.spring.scaledDuration($0) } ?? layout.spring
        let baseVertical = layout.spring

        let spL: Spring
        let spR: Spring
        if let lead = layout.leadingSpring {
            spL = (target.left < curL) ? lead : baseHorizontal
            spR = (target.right > curR) ? lead : baseHorizontal
        } else {
            spL = baseHorizontal
            spR = baseHorizontal
        }

        let spT: Spring
        let spB: Spring
        if let lead = layout.leadingSpring {
            spT = (target.top < curT) ? lead : baseVertical
            spB = (target.bottom > curB) ? lead : baseVertical
        } else {
            spT = baseVertical
            spB = baseVertical
        }

        store.set(id, Self.EDGE_LEFT, to: target.left, anim: .spring(spL), at: now)
        store.set(id, Self.EDGE_TOP, to: target.top, anim: .spring(spT), at: now)
        store.set(id, Self.EDGE_RIGHT, to: target.right, anim: .spring(spR), at: now)
        store.set(id, Self.EDGE_BOTTOM, to: target.bottom, anim: .spring(spB), at: now)
    }

    private mutating func applyStyle(spec: NodeSpec, curve: Curve, at now: Double, initialSnap: Bool = false) {
        if initialSnap || curve == .instant {
            store.snap(spec.id, Props.OPACITY, to: spec.opacity)
            store.snap(spec.id, Props.SCALE, to: spec.scale)
            store.snap(spec.id, Props.ROTATE, to: spec.rotate)
            store.snap(spec.id, Props.OFFSET, to: spec.offset)
            store.snap(spec.id, Props.CORNERS, to: spec.corners)
            store.snap(spec.id, Props.BLUR, to: Blur(spec.blur))
            if let fill = spec.fill { store.snap(spec.id, Props.FILL, to: fill) }
            if let border = spec.border { store.snap(spec.id, Props.BORDER, to: border) }
        } else {
            store.set(spec.id, Props.OPACITY, to: spec.opacity, anim: Anim(curve: curve), at: now)
            store.set(spec.id, Props.SCALE, to: spec.scale, anim: Anim(curve: curve), at: now)
            store.set(spec.id, Props.ROTATE, to: spec.rotate, anim: Anim(curve: curve), at: now)
            store.set(spec.id, Props.OFFSET, to: spec.offset, anim: Anim(curve: curve), at: now)
            store.set(spec.id, Props.CORNERS, to: spec.corners, anim: Anim(curve: curve), at: now)
            store.set(spec.id, Props.BLUR, to: Blur(spec.blur), anim: Anim(curve: curve), at: now)
            if let fill = spec.fill {
                store.set(spec.id, Props.FILL, to: fill, anim: Anim(curve: curve), at: now)
            }
            if let border = spec.border {
                store.set(spec.id, Props.BORDER, to: border, anim: Anim(curve: curve), at: now)
            }
        }
    }
}
