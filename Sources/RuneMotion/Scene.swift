import Foundation

/// Width-leads ratio for the X axis spring (native morph: `width_vd = 0.78 * vd`).
public let WIDTH_LEAD: Float = 0.78

/// Lifecycle phase of a scene node.
public enum ScenePhase: Sendable, Hashable {
    case entering
    case present
    /// Removed by the app; still drawn until its exit settles. `generation` guards against stale exits.
    case exiting(generation: UInt32)
}

/// Whether an insert is part of the first build (no animation) or a later change.
public enum Mount: Sendable, Hashable {
    case initial
    case animated
}

/// Coordinate space layout motion is tracked in.
public enum Travel: Sendable, Hashable, Codable {
    /// Edges animate in parent space; an unchanged child rides its parent 1:1.
    case parent
    /// The node travels one straight screen-space path from where it was seen to where it lands.
    case screen
}

/// How a frame change animates: per-axis curves, directional edge lead, and travel space.
public struct LayoutAnim: Sendable, Hashable {
    private final class Storage: @unchecked Sendable {
        var x: Anim<Float>
        var y: Anim<Float>
        var leadCurve: Anim<Float>?
        var trailCurve: Anim<Float>?
        var travel: Travel

        init(
            x: Anim<Float>,
            y: Anim<Float>,
            leadCurve: Anim<Float>?,
            trailCurve: Anim<Float>?,
            travel: Travel
        ) {
            self.x = x
            self.y = y
            self.leadCurve = leadCurve
            self.trailCurve = trailCurve
            self.travel = travel
        }

        func clone() -> Storage {
            Storage(x: x, y: y, leadCurve: leadCurve, trailCurve: trailCurve, travel: travel)
        }
    }

    private var storage: Storage

    public var x: Anim<Float> {
        get { storage.x }
        set {
            if !isKnownUniquelyReferenced(&storage) { storage = storage.clone() }
            storage.x = newValue
        }
    }

    public var y: Anim<Float> {
        get { storage.y }
        set {
            if !isKnownUniquelyReferenced(&storage) { storage = storage.clone() }
            storage.y = newValue
        }
    }

    public var leadCurve: Anim<Float>? {
        get { storage.leadCurve }
        set {
            if !isKnownUniquelyReferenced(&storage) { storage = storage.clone() }
            storage.leadCurve = newValue
        }
    }

    public var trailCurve: Anim<Float>? {
        get { storage.trailCurve }
        set {
            if !isKnownUniquelyReferenced(&storage) { storage = storage.clone() }
            storage.trailCurve = newValue
        }
    }

    public var travel: Travel {
        get { storage.travel }
        set {
            if !isKnownUniquelyReferenced(&storage) { storage = storage.clone() }
            storage.travel = newValue
        }
    }

    public static let instant = LayoutAnim(x: .instant, y: .instant)

    public static func == (lhs: LayoutAnim, rhs: LayoutAnim) -> Bool {
        lhs.storage === rhs.storage || (
            lhs.storage.x == rhs.storage.x &&
            lhs.storage.y == rhs.storage.y &&
            lhs.storage.leadCurve == rhs.storage.leadCurve &&
            lhs.storage.trailCurve == rhs.storage.trailCurve &&
            lhs.storage.travel == rhs.storage.travel
        )
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(storage.x)
        hasher.combine(storage.y)
        hasher.combine(storage.leadCurve)
        hasher.combine(storage.trailCurve)
        hasher.combine(storage.travel)
    }

    public var lead: (Anim<Float>, Anim<Float>)? {
        get {
            if let l = storage.leadCurve, let t = storage.trailCurve { return (l, t) }
            return nil
        }
        set {
            if !isKnownUniquelyReferenced(&storage) { storage = storage.clone() }
            storage.leadCurve = newValue?.0
            storage.trailCurve = newValue?.1
        }
    }

    public init(
        x: Anim<Float>,
        y: Anim<Float>? = nil,
        lead: (Anim<Float>, Anim<Float>)? = nil,
        travel: Travel = .parent
    ) {
        self.storage = Storage(
            x: x,
            y: y ?? x,
            leadCurve: lead?.0,
            trailCurve: lead?.1,
            travel: travel
        )
    }

    public init(_ spring: Spring) {
        let a = Anim<Float>(curve: Curve.from(spring))
        self.storage = Storage(x: a, y: a, leadCurve: nil, trailCurve: nil, travel: .parent)
    }

    public init(_ pair: SpringPair) {
        let a = Anim<Float>(curve: Curve.from(pair.enter))
        self.storage = Storage(x: a, y: a, leadCurve: nil, trailCurve: nil, travel: .parent)
    }

    /// Legacy compatibility initializer used by `Runtime` and existing tests.
    public init(
        spring: Spring = MotionTokens.SETTLE,
        leadingSpring: Spring? = nil,
        widthScale: Float? = nil,
        travel: Travel = .parent
    ) {
        let sx = widthScale.map { spring.withDuration(spring.duration * $0) } ?? spring
        self.storage = Storage(
            x: Anim(curve: Curve.from(sx)),
            y: Anim(curve: Curve.from(spring)),
            leadCurve: leadingSpring.map { Anim(curve: Curve.from($0)) },
            trailCurve: leadingSpring.map { _ in Anim(curve: Curve.from(spring)) },
            travel: travel
        )
    }

    public static func axes(_ x: Anim<Float>, _ y: Anim<Float>) -> LayoutAnim {
        LayoutAnim(x: x, y: y)
    }

    public static func axes(_ x: Spring, _ y: Spring) -> LayoutAnim {
        LayoutAnim(x: Anim(curve: Curve.from(x)), y: Anim(curve: Curve.from(y)))
    }

    /// Width settles at `0.78 * duration` ahead of height.
    public func widthLeads() -> LayoutAnim {
        var copy = self
        if case let .spring(s) = copy.x.curve {
            copy.x.curve = .spring(s.withDuration(s.duration * WIDTH_LEAD))
        }
        return copy
    }

    /// Static legacy factory matching `widthLeads()`.
    public static func widthLeads(_ spring: Spring = MotionTokens.SETTLE) -> LayoutAnim {
        LayoutAnim(spring: spring, widthScale: WIDTH_LEAD)
    }

    public func lead(_ lead: Anim<Float>, _ trail: Anim<Float>) -> LayoutAnim {
        var copy = self
        copy.leadCurve = lead
        copy.trailCurve = trail
        return copy
    }

    public func lead(_ lead: Spring, _ trail: Spring) -> LayoutAnim {
        self.lead(Anim(curve: Curve.from(lead)), Anim(curve: Curve.from(trail)))
    }

    public static func lead(lead: Spring = MotionTokens.LEAD, trail: Spring = MotionTokens.SETTLE) -> LayoutAnim {
        LayoutAnim(spring: trail, leadingSpring: lead)
    }

    public func screen() -> LayoutAnim {
        var copy = self
        copy.travel = .screen
        return copy
    }

    public func withTravel(_ travel: Travel) -> LayoutAnim {
        var copy = self
        copy.travel = travel
        return copy
    }
}

/// Kept out of each node's inline storage because few elements override the blur curve.
package final class BlurMotion: Sendable, Equatable {
    package let animation: Anim<Blur>

    package init(_ animation: Anim<Blur>) { self.animation = animation }

    package static func == (lhs: BlurMotion, rhs: BlurMotion) -> Bool {
        lhs === rhs || lhs.animation == rhs.animation
    }
}

/// Declarative motion specification for a scene node.
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
    package var launchLayout: LaunchLayoutUpdate?
    public var styleSpring: Spring?
    public var colorSpring: Spring?
    public var animateOffset: Bool
    public var cornerSpring: Spring? = nil
    public var paintSpring: Spring?
    public var offsetAnim: Anim<Vec2>?
    public var opacityAnim: Anim<Float>?
    public var scaleAnim: Anim<Vec2>?
    public var rotateAnim: Anim<Float>?
    package var blurMotion: BlurMotion?
    public var iconTurn: Float
    public var transition: Transition?
    public var snapMount: Bool
    public var enterDelay: Float

    /// Layout frame in parent space when used with `Scene.insert` (alias for `rect`).
    public var frame: MotionRect {
        get { rect }
        set { rect = newValue }
    }

    /// Retained-mode upstream constructor (`NodeSpec::new(frame)`).
    public init(_ frame: MotionRect) {
        self.id = NodeId(0)
        self.parent = nil
        self.rect = frame
        self.opacity = 1.0
        self.scale = Vec2(1, 1)
        self.rotate = 0
        self.offset = .zero
        self.corners = .all(0)
        self.blur = 0
        self.fill = nil
        self.border = nil
        self.layoutAnim = nil
        self.styleSpring = nil
        self.colorSpring = nil
        self.animateOffset = true
        self.paintSpring = nil
        self.offsetAnim = nil
        self.opacityAnim = nil
        self.scaleAnim = nil
        self.rotateAnim = nil
        self.iconTurn = 0
        self.transition = .opacity
        self.snapMount = false
        self.enterDelay = 0
    }

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
        colorSpring: Spring? = nil,
        animateOffset: Bool = true,
        paintSpring: Spring? = nil,
        offsetAnim: Anim<Vec2>? = nil,
        opacityAnim: Anim<Float>? = nil,
        scaleAnim: Anim<Vec2>? = nil,
        rotateAnim: Anim<Float>? = nil,
        iconTurn: Float = 0,
        transition: Transition? = nil,
        snapMount: Bool = false,
        enterDelay: Float = 0
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
        self.colorSpring = colorSpring
        self.animateOffset = animateOffset
        self.paintSpring = paintSpring
        self.offsetAnim = offsetAnim
        self.opacityAnim = opacityAnim
        self.scaleAnim = scaleAnim
        self.rotateAnim = rotateAnim
        self.iconTurn = iconTurn
        self.transition = transition
        self.snapMount = snapMount
        self.enterDelay = enterDelay
    }

    public func parent(_ parent: NodeId) -> NodeSpec {
        var c = self; c.parent = parent; return c
    }
    public func opacity(_ opacity: Float) -> NodeSpec {
        var c = self; c.opacity = opacity; return c
    }
    public func radius(_ radius: Corners) -> NodeSpec {
        var c = self; c.corners = radius; return c
    }
    public func radius(_ uniform: Float) -> NodeSpec {
        var c = self; c.corners = .all(uniform); return c
    }
    public func fill(_ color: MotionColor) -> NodeSpec {
        var c = self; c.fill = color; return c
    }
    public func transition(_ transition: Transition) -> NodeSpec {
        var c = self; c.transition = transition; return c
    }
}

/// Soft SDF clip in the node's own coordinates.
public struct Mask: Sendable, Hashable {
    public var inset: Sides
    public var feather: Sides

    public static let zero = Mask(inset: .zeroValue, feather: .zeroValue)

    public init(inset: Sides = .zeroValue, feather: Sides = .zeroValue) {
        self.inset = inset
        self.feather = feather
    }

    public var isNone: Bool {
        inset == .zeroValue && feather == .zeroValue
    }

    /// Upstream `[left, top, right, bottom]` edge arrays for tests & shaders.
    public var insetEdges: [Float] { [inset.left, inset.top, inset.right, inset.bottom] }
    public var featherEdges: [Float] { [feather.left, feather.top, feather.right, feather.bottom] }
}

/// Everything the renderer needs to draw one node on a frame.
public struct Presented: Sendable, Equatable {
    public var id: NodeId
    public var parent: NodeId?
    public var rect: MotionRect
    public var targetRect: MotionRect
    public var revealClip: MotionRect?
    public var opacity: Float
    public var transform: Transform2D
    public var anchor: Vec2
    public var blur: Float
    public var corners: Corners
    public var fill: MotionColor?
    public var border: MotionColor?
    public var mask: Mask
    public var phase: ScenePhase
    public var inFlow: Bool
    public var flags: UInt32
    public var draw: Float
    public var presence: Float
    public var isMoving: Bool

    public var node: NodeId { id }
    public var radius: Corners { corners }
    public var fillColor: MotionColor { fill ?? .zeroValue }
    public var scale: Vec2 { transform.sx == transform.sy ? Vec2(transform.sx, transform.sy) : Vec2(transform.sx, transform.sy) }
    public var rotate: Float { transform.rot }
    public var isExiting: Bool {
        if case .exiting = phase { return true }
        return false
    }

    public func affine() -> [Float] {
        transform.toAffine(anchor: anchor)
    }

    public init(
        id: NodeId,
        parent: NodeId?,
        rect: MotionRect,
        targetRect: MotionRect,
        revealClip: MotionRect?,
        opacity: Float,
        transform: Transform2D,
        anchor: Vec2,
        blur: Float,
        corners: Corners,
        fill: MotionColor?,
        border: MotionColor?,
        mask: Mask,
        phase: ScenePhase,
        inFlow: Bool,
        flags: UInt32,
        draw: Float,
        presence: Float,
        isMoving: Bool
    ) {
        self.id = id
        self.parent = parent
        self.rect = rect
        self.targetRect = targetRect
        self.revealClip = revealClip
        self.opacity = opacity
        self.transform = transform
        self.anchor = anchor
        self.blur = blur
        self.corners = corners
        self.fill = fill
        self.border = border
        self.mask = mask
        self.phase = phase
        self.inFlow = inFlow
        self.flags = flags
        self.draw = draw
        self.presence = presence
        self.isMoving = isMoving
    }

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
        self.init(
            id: id,
            parent: parent,
            rect: rect,
            targetRect: targetRect,
            revealClip: revealClip,
            opacity: opacity,
            transform: Transform2D(tx: 0, ty: 0, sx: scale.x, sy: scale.y, rot: rotate),
            anchor: Vec2(0.5, 0.5),
            blur: blur,
            corners: corners,
            fill: fill,
            border: border,
            mask: .zero,
            phase: isExiting ? .exiting(generation: 1) : .present,
            inFlow: !isExiting,
            flags: isMoving ? TraceFlags.animated : 0,
            draw: 1.0,
            presence: presence,
            isMoving: isMoving
        )
    }
}

/// Describes the starting snapshot for a cross-parent matched-geometry (`flightId` / `matched`) transfer.
public struct MatchedFlightStart: Sendable {
    public var fromId: NodeId?
    public var startRect: MotionRect
    package var startVelocity: (Float, Float, Float, Float) = (0, 0, 0, 0)
    public var startCorners: Corners?
    public var startFill: MotionColor?
    public var startOpacity: Float?
    public var spring: Spring

    public init(
        fromId: NodeId? = nil,
        startRect: MotionRect,
        startCorners: Corners? = nil,
        startFill: MotionColor? = nil,
        startOpacity: Float? = nil,
        spring: Spring = MotionTokens.REFLOW
    ) {
        self.fromId = fromId
        self.startRect = startRect
        self.startCorners = startCorners
        self.startFill = startFill
        self.startOpacity = startOpacity
        self.spring = spring
    }
}

/// Ordered poses are stored once. The small index can span frames with the same tree order.
private final class OrderedScenePoses: @unchecked Sendable {
    let nodes: [Presented]
    let positions: [NodeId: UInt32]
    // Public dictionary access retains its native type and materializes one shared copy on demand.
    private let dictionaryLock = NSLock()
    private var materialized: [NodeId: Presented]?

    init(nodes: [Presented], positions: [NodeId: UInt32]) {
        self.nodes = nodes
        self.positions = positions
    }

    func dictionary() -> [NodeId: Presented] {
        dictionaryLock.withLock {
            if let materialized { return materialized }
            var result = Dictionary<NodeId, Presented>(minimumCapacity: nodes.count)
            for node in nodes { result[node.id] = node }
            materialized = result
            return result
        }
    }
}

/// Read-only keyed access for renderers. Explicit keyed poses take precedence for authored frames.
package struct FramePoseIndex: Sendable {
    fileprivate var keyed: [NodeId: Presented]
    fileprivate var ordered: OrderedScenePoses?

    package init(_ keyed: [NodeId: Presented]) {
        self.keyed = keyed
    }

    fileprivate init(_ ordered: OrderedScenePoses) {
        self.keyed = [:]
        self.ordered = ordered
    }

    package var count: Int { ordered?.nodes.count ?? keyed.count }

    package subscript(id: NodeId) -> Presented? {
        guard let ordered else { return keyed[id] }
        guard let position = ordered.positions[id] else { return nil }
        return ordered.nodes[Int(position)]
    }

    fileprivate mutating func expandDictionary() {
        guard let ordered else { return }
        keyed = ordered.dictionary()
        self.ordered = nil
    }
}

/// Output of one scene frame.
public struct FrameOutput: Sendable {
    /// Nodes whose presented values changed this frame, parents before children.
    public var changed: [Presented]
    /// Nodes whose exit settled this frame.
    public var exited: [NodeId]
    /// Events emitted by the store during this frame's tick.
    public var events: [MotionEvent]
    /// Whether any track (not frozen) is still running.
    public var animating: Bool

    /// Full snapshot for declarative callers using `commit(...)` + `frame(at:)`.
    public var nodes: [Presented]
    package private(set) var poseIndex: FramePoseIndex
    public var byId: [NodeId: Presented] {
        get { poseIndex.ordered?.dictionary() ?? poseIndex.keyed }
        set { poseIndex = FramePoseIndex(newValue) }
        _modify {
            poseIndex.expandDictionary()
            yield &poseIndex.keyed
        }
    }
    public var isAnimating: Bool { animating }

    public init(
        changed: [Presented],
        exited: [NodeId],
        events: [MotionEvent],
        animating: Bool,
        nodes: [Presented] = [],
        byId: [NodeId: Presented] = [:]
    ) {
        self.changed = changed
        self.exited = exited
        self.events = events
        self.animating = animating
        self.nodes = nodes
        self.poseIndex = FramePoseIndex(byId)
    }
}

private extension FrameOutput {
    mutating func expandPoseDictionary() {
        poseIndex.expandDictionary()
    }

    mutating func include(_ snapshot: OrderedScenePoses) {
        nodes = snapshot.nodes
        poseIndex = FramePoseIndex(snapshot)
    }
}

package enum LaunchLayoutUpdate: Equatable, Sendable {
    case projectEndpoint
    case reaim
}

internal struct ScreenPath: Sendable {
    var start: MotionRect
    var endLocal: MotionRect
    var origin: Vec2
}

/// The rate of the projected endpoint between frames. A launch retarget inherits
/// this part of its drawn velocity in addition to the rate of its travel spring.
internal struct LaunchEndpoint: Sendable {
    var at: Double
    var edges: SIMD4<Float>
    var velocity = SIMD4<Float>.zero

    init(at: Double, rect: MotionRect) {
        self.at = at
        edges = SIMD4(rect.left, rect.top, rect.right, rect.bottom)
    }

    mutating func sample(at now: Double, rect: MotionRect) {
        let next = SIMD4(rect.left, rect.top, rect.right, rect.bottom)
        if now > at { velocity = (next - edges) / Float(now - at) }
        at = now
        edges = next
    }
}

internal struct SceneDual: Sendable {
    var x: Float = 0
    var v: Float = 0

    static func c(_ x: Float) -> SceneDual { SceneDual(x: x, v: 0) }
    func add(_ o: SceneDual) -> SceneDual { SceneDual(x: x + o.x, v: v + o.v) }
    func sub(_ o: SceneDual) -> SceneDual { SceneDual(x: x - o.x, v: v - o.v) }
    func mul(_ o: SceneDual) -> SceneDual { SceneDual(x: x * o.x, v: v * o.x + x * o.v) }
}

internal struct SceneRest: Sendable {
    var rect: MotionRect = .zero
    var origin: Vec2 = .zero
    var moving: Bool = false
}

/// The render thread's animated retained-mode scene tree, with a declarative `commit` adapter.
public struct Scene: Sendable {
    internal static let noneIdx: UInt32 = UInt32.max
    internal static let maxTrackSlots: Int = 21

    /// Most mounted nodes never animate. Allocate property slots on the first track.
    internal struct NodeTracks: Sendable {
        private(set) var entries: [TrackId?] = []

        subscript(_ property: Int) -> TrackId? {
            get { property < entries.count ? entries[property] : nil }
            set {
                guard property < Scene.maxTrackSlots else { return }
                if entries.isEmpty {
                    guard newValue != nil else { return }
                    entries = Array(repeating: nil, count: Scene.maxTrackSlots)
                }
                entries[property] = newValue
            }
        }
    }

    internal struct Node: Sendable {
        var id: NodeId
        var parent: UInt32
        var firstChild: UInt32
        var lastChild: UInt32
        var nextSibling: UInt32
        var prevSibling: UInt32
        var alive: Bool
        var frame: MotionRect
        var opacity: Float
        var baseScale2D: Vec2
        var baseRotate: Float
        var baseOffset: Vec2
        var baseBlur: Float
        var radius: Corners
        var fill: MotionColor
        var border: MotionColor
        var hasFill: Bool
        var hasBorder: Bool
        var transition: Transition
        var compatHadTransition: Bool
        var presence: PresenceState
        var generation: UInt32
        var anchor: Vec2
        var reveal: Reveal?
        var path: ScreenPath?
        var rideTrailing: Bool
        var tracks: NodeTracks
        var dirty: Bool
        var world: MotionRect
        var origin: Vec2
        var last: Presented?

        mutating func phaseStep(_ event: PhaseEvent) -> [PhaseAct] {
            stepPhase(state: &presence, generation: &generation, event: event)
        }
    }

    public var store: AnimationStore
    internal var nodes: [Node] = []
    internal var rests: [SceneRest] = []
    private var free: [UInt32] = []
    internal var index: [UInt64: UInt32] = [:]
    private var rootHead: UInt32 = Scene.noneIdx
    private var rootTail: UInt32 = Scene.noneIdx
    internal var order: [UInt32] = []
    internal var orderDirty: Bool = false
    private var snapshot: OrderedScenePoses?
    private var snapshotPositions: [NodeId: UInt32]?
    internal var out: [Presented] = []
    internal var late: [Presented] = []
    internal var exitedCarry = Carry<NodeId>()
    internal var toRemove: [UInt32] = []
    internal var travelling: [UInt32] = []
    internal var launchEndpoints: [NodeId: LaunchEndpoint] = [:]
    internal var trace: MotionTrace? = nil
    internal var intents: [(NodeId, UInt32, Float)] = []
    internal var keep: Bool = false
    private var hasCommittedOnce: Bool = false

    public init(pixelScale: Float = 2.0, reducedMotion: Bool = false) {
        var s = AnimationStore()
        s.setPixelScale(pixelScale)
        s.setReducedMotion(reducedMotion)
        self.store = s
    }

    public var pixelScale: Float {
        get { store.pixelScale }
        set { setPixelScale(newValue) }
    }

    public var reducedMotion: Bool {
        get { store.reducedMotion }
        set { setReducedMotion(newValue) }
    }

    public var isAnimating: Bool { store.running }
    public var now: Double { store.now }
    public var count: Int { index.count }
    public var isEmpty: Bool { index.isEmpty }

    public mutating func keepFlights(_ on: Bool) {
        keep = on
    }

    internal func inFlightTo<T: Animatable>(_ id: NodeId, _ prop: Prop<T>, _ value: T) -> Bool {
        guard keep, store.isAnimating(id, prop), let to = store.target(id, prop) else {
            return false
        }
        let a = to.toLanes()
        let b = value.toLanes()
        for k in 0..<T.laneCount {
            if abs(a[k] - b[k]) > 1e-3 { return false }
        }
        return true
    }

    public mutating func setTime(_ t: Double) {
        store.setTime(t)
    }

    public mutating func setTimeScale(_ id: NodeId, _ scale: Float) {
        store.setNodeTimeScale(id, scale)
    }

    public mutating func setPixelScale(_ s: Float) {
        let prev = store.pixelScale
        store.setPixelScale(s)
        if store.pixelScale != prev {
            for i in nodes.indices where nodes[i].alive {
                nodes[i].dirty = true
            }
        }
    }

    public mutating func setReducedMotion(_ on: Bool) {
        store.setReducedMotion(on)
        for i in nodes.indices where nodes[i].alive {
            nodes[i].dirty = true
        }
    }

    public mutating func setTrace(_ trace: MotionTrace?) {
        self.trace = trace
        for i in nodes.indices where nodes[i].alive {
            nodes[i].dirty = true
        }
    }

    public var isTracing: Bool { trace != nil }

    public mutating func traceName(_ id: NodeId, _ name: String?) {
        if trace?.name(id, name) == true, let i = slot(id) {
            nodes[i].dirty = true
        }
    }

    public mutating func traceNamespace(_ id: NodeId, _ ns: (String, String)?) {
        if trace?.namespace(id, ns) == true, let i = slot(id) {
            nodes[i].dirty = true
        }
    }

    public mutating func traceEvent(_ event: String) {
        trace?.event(event)
    }

    public mutating func traceChannel(_ name: String, kind: TraceChannels.Kind, value: Float) {
        trace?.channel(name, kind: kind, value: value)
    }

    public mutating func takeTrace() -> MotionTrace? {
        defer { trace = nil }
        return trace
    }

    public func contains(_ id: NodeId) -> Bool {
        index[id.rawValue] != nil
    }

    public func phase(_ id: NodeId) -> ScenePhase? {
        guard let i = slot(id) else { return nil }
        return nodes[i].presence.public(nodes[i].generation)
    }

    public func presented(_ id: NodeId) -> Presented? {
        guard let i = slot(id) else { return nil }
        return nodes[i].last
    }

    public func rest(_ id: NodeId) -> MotionRect? {
        guard let i = slot(id) else { return nil }
        let r = rests[i]
        return r.moving ? snapRect(r.rect, pixelScale: store.pixelScale) : nil
    }

    public func world(_ id: NodeId) -> MotionRect? {
        guard let i = slot(id) else { return nil }
        return snapRect(nodes[i].world, pixelScale: store.pixelScale)
    }

    public func hasNode(_ id: NodeId) -> Bool {
        guard let i = slot(id) else { return false }
        return nodes[i].alive
    }

    public func isExiting(_ id: NodeId) -> Bool {
        guard let i = slot(id), nodes[i].alive else { return false }
        return nodes[i].presence.isExiting
    }

    public func currentRect(_ id: NodeId) -> MotionRect? {
        guard let i = slot(id), nodes[i].alive else { return nil }
        let (w, _) = exactWorld(i)
        return MotionRect.fromEdges(w.0, w.1, w.2, w.3)
    }

    /// Screen-space velocities of the four edges before a matched node transfers to its successor.
    package func frameVelocity(_ id: NodeId) -> (Float, Float, Float, Float) {
        guard let i = slot(id) else { return (0, 0, 0, 0) }
        return exactWorld(i).1
    }

    public func isEdgeAnimating(_ id: NodeId) -> Bool {
        guard let i = slot(id), nodes[i].alive else { return false }
        if nodes[i].path != nil { return true }
        if let tid = nodes[i].tracks[Int(Props.FRAME.id.rawValue)], store.isActive(tid) {
            return true
        }
        if let tid = nodes[i].tracks[Int(Props.TRAVEL.id.rawValue)], store.isActive(tid) {
            return true
        }
        return false
    }

    internal func slot(_ id: NodeId) -> Int? {
        index[id.rawValue].map(Int.init)
    }

    internal func sample(_ t: TrackId) -> ([Float], [Float])? {
        var x = [Float](repeating: 0, count: MotionLanes.maxLanes)
        var v = [Float](repeating: 0, count: MotionLanes.maxLanes)
        guard store.sampleExact(t, x: &x, v: &v) else { return nil }
        return (x, v)
    }

    // MARK: - Layout

    public mutating func setFrame(_ id: NodeId, _ frame: MotionRect, _ anim: LayoutAnim) {
        setFrameDrawn(id, frame, anim, drawnOffset: .zero, drawnVelocity: .zero)
    }

    public mutating func setFrame(_ id: NodeId, _ frame: MotionRect, _ spring: Spring) {
        setFrame(id, frame, LayoutAnim(spring))
    }

    internal mutating func setFrameDrawn(
        _ id: NodeId,
        _ frame: MotionRect,
        _ anim: LayoutAnim,
        drawnOffset: Vec2,
        drawnVelocity: Vec2,
        forceScreenRetarget: Bool = false
    ) {
        guard let i = slot(id) else { return }
        let old = nodes[i].frame
        if old == frame && nodes[i].path == nil && nodes[i].tracks[Int(Props.FRAME.id.rawValue)] == nil {
            return
        }
        if frame.width != old.width {
            rebaseTrailing(i, dw: frame.width - old.width)
        }
        let hadPath = nodes[i].path != nil
        if anim == .instant && !hadPath && inFlightTo(id, Props.FRAME, frame) {
            return
        }
        if anim == .instant && (hadPath || store.isAnimating(id, Props.FRAME)) {
            endPath(i)
            nodes[i].frame = frame
            trackSet(i, Props.FRAME, frame)
            nodes[i].dirty = true
            return
        }
        if old == frame && !hadPath {
            return
        }
        let secs = anim.x.curve.logicalDuration
        intent(id, TraceIntent.position | TraceIntent.size, secs)

        if anim.travel == .screen && !store.reducedMotion {
            let destOrigin = parentTargetOrigin(i)
            if !forceScreenRetarget, let path = nodes[i].path,
               nodes[i].frame == frame,
               path.endLocal == frame,
               abs(path.origin.x - destOrigin.x) < 1e-4,
               abs(path.origin.y - destOrigin.y) < 1e-4 {
                return
            }
            let curPos: (Float, Float, Float, Float)
            let curVel: (Float, Float, Float, Float)
            if let path = nodes[i].path {
                let e = pathDual(i, path: path, origin: path.origin)
                curPos = (e.0.x, e.1.x, e.2.x, e.3.x)
                if forceScreenRetarget, let motion = launchEndpoints[id], let travel = get(id, Props.TRAVEL) {
                    curVel = (e.0.v + travel.x * motion.velocity[0], e.1.v + travel.y * motion.velocity[1],
                              e.2.v + travel.x * motion.velocity[2], e.3.v + travel.y * motion.velocity[3])
                } else {
                    curVel = (e.0.v, e.1.v, e.2.v, e.3.v)
                }
            } else {
                (curPos, curVel) = exactWorld(i)
            }
            let start = MotionRect.fromEdges(
                curPos.0 + drawnOffset.x,
                curPos.1 + drawnOffset.y,
                curPos.2 + drawnOffset.x,
                curPos.3 + drawnOffset.y
            )
            let vel = (
                curVel.0 + drawnVelocity.x,
                curVel.1 + drawnVelocity.y,
                curVel.2 + drawnVelocity.x,
                curVel.3 + drawnVelocity.y
            )
            nodes[i].frame = frame
            startPath(i, start: start, velocity: vel, anim: anim)
            return
        }

        if hadPath {
            let (w, wv) = exactWorld(i)
            let (po, pv) = parentOriginExact(i)
            let trail = trailDual(i)
            let px = po.x + trail.x
            let py = po.y
            let pvx = pv.x + trail.v
            let pvy = pv.y
            let local = MotionRect.fromEdges(w.0 - px, w.1 - py, w.2 - px, w.3 - py)
            let lv = MotionLanes(w.0 - px == w.0 - px ? wv.0 - pvx : 0, wv.1 - pvy, wv.2 - pvx, wv.3 - pvy)
            endPath(i)
            trackSet(i, Props.FRAME, local)
            if let tid = nodes[i].tracks[Int(Props.FRAME.id.rawValue)] {
                let smooth = Anim<MotionRect>(curve: .spring(MotionTokens.SMOOTH))
                store.animateRaw(
                    tid.indexInt,
                    targets: local.toLanes(),
                    count: 4,
                    curve: smooth.curve,
                    blend: smooth.blend,
                    delay: smooth.delay,
                    velocityRule: .inherit,
                    token: 0,
                    laneVelocities: lv
                )
            }
        } else if nodes[i].tracks[Int(Props.FRAME.id.rawValue)] == nil {
            trackSet(i, Props.FRAME, old)
        }

        nodes[i].frame = frame
        guard let tid = nodes[i].tracks[Int(Props.FRAME.id.rawValue)] else { return }
        let ti = tid.indexInt
        let cur = store.laneTargets4(ti)
        let e = frame.edges
        let eArr = [e.0, e.1, e.2, e.3]
        var curArr = [cur.0, cur.1, cur.2, cur.3]

        if let (lead, trail) = anim.lead {
            for axis in 0..<2 {
                let a = axis
                let b = axis + 2
                let (sa, sb) = (eArr[a] + eArr[b] > curArr[a] + curArr[b]) ? (trail, lead) : (lead, trail)
                var tgA = MotionLanes(curArr[0], curArr[1], curArr[2], curArr[3])
                tgA[a] = eArr[a]
                _ = store.animateRaw(
                    ti, targets: tgA, count: 4, curve: sa.curve, blend: sa.blend,
                    delay: sa.delay, velocityRule: sa.velocityRule, token: sa.token, laneVelocities: nil
                )
                curArr[a] = eArr[a]

                var tgB = MotionLanes(curArr[0], curArr[1], curArr[2], curArr[3])
                tgB[b] = eArr[b]
                _ = store.animateRaw(
                    ti, targets: tgB, count: 4, curve: sb.curve, blend: sb.blend,
                    delay: sb.delay, velocityRule: sb.velocityRule, token: sb.token, laneVelocities: nil
                )
                curArr[b] = eArr[b]
            }
            _ = cur
        } else {
            // X edges on the X curve, Y edges on the Y curve; unchanged lanes are skipped.
            let tgX = MotionLanes(e.0, cur.1, e.2, cur.3)
            _ = store.animateRaw(
                ti, targets: tgX, count: 4, curve: anim.x.curve, blend: anim.x.blend,
                delay: anim.x.delay, velocityRule: anim.x.velocityRule, token: anim.x.token, laneVelocities: nil
            )
            let tgY = MotionLanes(e.0, e.1, e.2, e.3)
            _ = store.animateRaw(
                ti, targets: tgY, count: 4, curve: anim.y.curve, blend: anim.y.blend,
                delay: anim.y.delay, velocityRule: anim.y.velocityRule, token: anim.y.token, laneVelocities: nil
            )
        }
        nodes[i].dirty = true
    }

    internal func parentTargetOrigin(_ i: Int) -> Vec2 {
        var o = Vec2.zero
        var p = nodes[i].parent
        while p != Self.noneIdx {
            let pf = nodes[Int(p)].frame
            o.x += pf.left
            o.y += pf.top
            p = nodes[Int(p)].parent
        }
        return o
    }

    internal func exactWorld(_ i: Int) -> ((Float, Float, Float, Float), (Float, Float, Float, Float)) {
        let e = worldDual(i)
        return ((e.0.x, e.1.x, e.2.x, e.3.x), (e.0.v, e.1.v, e.2.v, e.3.v))
    }

    public func samplingError() -> (samples: Int, maxDevicePxError: Float) {
        var count = 0
        var error: Float = 0
        for slot in order {
            let i = Int(slot)
            guard nodes[i].alive, let p = nodes[i].last else { continue }
            let w = worldDual(i)
            let o = originDual(i)
            let ideal = (o.0.x, o.1.x, o.0.x + w.2.x - w.0.x, o.1.x + w.3.x - w.1.x)
            let shown = p.rect.edges
            error = max(error, abs(shown.0 - ideal.0) * store.pixelScale)
            error = max(error, abs(shown.1 - ideal.1) * store.pixelScale)
            error = max(error, abs(shown.2 - ideal.2) * store.pixelScale)
            error = max(error, abs(shown.3 - ideal.3) * store.pixelScale)
            count += 4
        }
        return (count, error)
    }

    internal func parentOriginExact(_ i: Int) -> (Vec2, Vec2) {
        let p = nodes[i].parent
        if p == Self.noneIdx { return (.zero, .zero) }
        let o = originDual(Int(p))
        return (Vec2(o.0.x, o.1.x), Vec2(o.0.v, o.1.v))
    }

    internal func lanesDual(_ i: Int, _ p: PropId, into out: inout [SceneDual]) {
        let pid = Int(p.rawValue)
        guard let tid = nodes[i].tracks[pid], let (x, v) = sample(tid) else {
            return
        }
        for k in 0..<out.count {
            out[k] = SceneDual(x: x[k], v: v[k])
        }
    }

    internal func worldDual(_ i: Int) -> (SceneDual, SceneDual, SceneDual, SceneDual) {
        if let path = nodes[i].path {
            return pathDual(i, path: path, origin: parentTargetOrigin(i))
        }
        return laidDual(i)
    }

    internal func pathDual(_ i: Int, path: ScreenPath, origin: Vec2) -> (SceneDual, SceneDual, SceneDual, SceneDual) {
        var p = [SceneDual.c(1.0), SceneDual.c(1.0)]
        lanesDual(i, Props.TRAVEL.id, into: &p)
        return startPathDual(start: path.start, end: path.endLocal.translated(origin), progress: (p[0], p[1]))
    }

    internal func originDual(_ i: Int) -> (SceneDual, SceneDual) {
        let w = worldDual(i)
        let base = nodes[i].baseOffset
        var off = [SceneDual.c(base.x), SceneDual.c(base.y)]
        lanesDual(i, Props.OFFSET.id, into: &off)
        var p = [SceneDual.c(1.0)]
        lanesDual(i, Props.PRESENCE.id, into: &p)
        let (at0, at1) = nodes[i].presence.pair
        let oneMinusP = SceneDual.c(1.0).sub(p[0])
        @inline(__always) func fx(_ k: Int) -> SceneDual {
            SceneDual.c(fxAt(at0, k)).mul(oneMinusP).add(SceneDual.c(fxAt(at1, k)).mul(p[0]))
        }
        let sizeX = w.2.sub(w.0)
        let sizeY = w.3.sub(w.1)
        let reduced = store.reducedMotion
        let baseX = w.0.add(off[0])
        let baseY = w.1.add(off[1])
        if reduced {
            return (baseX, baseY)
        }
        return (
            baseX.add(fx(2)).add(fx(4).mul(sizeX)),
            baseY.add(fx(3)).add(fx(5).mul(sizeY))
        )
    }

    // MARK: - Stepping & Presenting a Frame

    public mutating func frameAt(_ t: Double) -> FrameOutput {
        setTime(t)
        return frame()
    }

    public mutating func frame() -> FrameOutput {
        frameImpl(includeSnapshot: false)
    }

    /// Presents what was set or animated since `frame()` without advancing time.
    public mutating func present() {
        if orderDirty {
            rebuildOrder()
        }
        let from = out.count
        presentDirty()
        if trace != nil && out.count > from {
            late.append(contentsOf: out[from...])
        }
    }

    private mutating func frameImpl(includeSnapshot: Bool) -> FrameOutput {
        store.tick()
        exitedCarry.begin()
        toRemove.removeAll(keepingCapacity: true)

        for ev in store.events {
            if case let .settled(_, node, p) = ev, p == Props.PRESENCE.id {
                guard let i = slot(node) else { continue }
                let acts = nodes[i].phaseStep(.settle)
                for act in acts {
                    if case .retire = act {
                        toRemove.append(UInt32(i))
                    }
                }
            }
        }

        var retire = toRemove
        toRemove.removeAll(keepingCapacity: true)
        for (tid, node, p) in store.touchedTracks() where p == Props.PRESENCE.id {
            guard let ui = index[node.rawValue] else { continue }
            let i = Int(ui)
            if !nodes[i].presence.isExiting || retire.contains(ui) { continue }
            guard let vals = store.valuesOf(tid), let pv = vals.first else { continue }
            let acts = nodes[i].phaseStep(.faded(p: pv))
            for act in acts {
                if case .retire = act {
                    retire.append(ui)
                }
            }
        }
        toRemove = retire

        for (tid, node, p) in store.touchedTracks() {
            guard let i = slot(node) else { continue }
            nodes[i].dirty = true
            let pid = Int(p.rawValue)
            nodes[i].tracks[pid] = tid
        }

        // Screen travel checks in start order (travelling), not tree order.
        var k = 0
        while k < travelling.count {
            let i = Int(travelling[k])
            let travelTid = nodes[i].tracks[Int(Props.TRAVEL.id.rawValue)]
            let arrived = travelTid.map { !store.isActive($0) } ?? true
            if arrived && !ancestorMoving(i) {
                let endLocal = nodes[i].path?.endLocal ?? nodes[i].frame
                endPath(i)
                trackSet(i, Props.FRAME, endLocal)
                continue
            }
            let po = parentTargetOrigin(i)
            nodes[i].path?.origin = po
            if !launchEndpoints.isEmpty, let path = nodes[i].path {
                launchEndpoints[nodes[i].id]?.sample(at: store.now, rect: path.endLocal.translated(po))
            }
            k += 1
        }

        if orderDirty {
            rebuildOrder()
        }

        out.removeAll(keepingCapacity: true)
        if !late.isEmpty {
            out.append(contentsOf: late)
            late.removeAll(keepingCapacity: true)
        }
        presentDirty()

        if !toRemove.isEmpty {
            snapshot = nil
            snapshotPositions = nil
        }
        for ui in toRemove {
            let i = Int(ui)
            if nodes[i].alive {
                removeNow(i)
            }
        }
        exitedCarry.end()

        let animating = store.running
        if let trace {
            var flagsMap: [NodeId: UInt32] = [:]
            flagsMap.reserveCapacity(out.count)
            for p in out {
                flagsMap[p.id] = p.flags
            }
            trace.frame(
                at: store.now,
                presented: out,
                gone: exitedCarry.items,
                events: store.events,
                intents: intents,
                flagsByNode: flagsMap
            )
            intents.removeAll(keepingCapacity: true)
        }

        if includeSnapshot, snapshot == nil {
            var snapshotNodes: [Presented] = []
            snapshotNodes.reserveCapacity(order.count)
            for ui in order {
                let i = Int(ui)
                guard nodes[i].alive, let last = nodes[i].last else { continue }
                snapshotNodes.append(last)
            }
            let positions: [NodeId: UInt32]
            if let snapshotPositions, snapshotPositions.count == snapshotNodes.count {
                positions = snapshotPositions
            } else {
                var next = Dictionary<NodeId, UInt32>(minimumCapacity: snapshotNodes.count)
                for i in snapshotNodes.indices { next[snapshotNodes[i].id] = UInt32(i) }
                snapshotPositions = next
                positions = next
            }
            snapshot = OrderedScenePoses(nodes: snapshotNodes, positions: positions)
        }

        var result = FrameOutput(
            changed: out,
            exited: exitedCarry.items,
            events: store.events,
            animating: animating
        )
        if includeSnapshot, let snapshot { result.include(snapshot) }
        return result
    }

    /// Returns the world-space rect for `id` prior to its own `Props.OFFSET` and presence transition offset.
    public func unoffsetWorldRect(for id: NodeId) -> MotionRect? {
        guard let ui = index[id.rawValue] else { return nil }
        let i = Int(ui)
        guard i < nodes.count, nodes[i].alive else { return nil }
        let w = worldDual(i)
        return MotionRect(left: w.0.x, top: w.1.x, right: w.2.x, bottom: w.3.x)
    }

    private mutating func presentDirty() {
        let firstChange = out.count
        let scale = store.pixelScale
        let reduced = store.reducedMotion
        // Siblings are adjacent in presentation order and share the same target origin.
        var lastParent = Self.noneIdx
        var targetOrigin = Vec2.zero
        for slotIdx in order {
            let i = Int(slotIdx)
            let parent = nodes[i].parent
            let parentDirty = parent != Self.noneIdx && nodes[Int(parent)].dirty
            let own = nodes[i].dirty
            if parentDirty {
                nodes[i].dirty = true
            }
            if nodes[i].dirty {
                if parent != lastParent {
                    targetOrigin = parentTargetOrigin(i)
                    lastParent = parent
                }
                let p = computePresented(i, scale: scale, reduced: reduced, ownDirty: own,
                                         parentDirty: parentDirty, targetOrigin: targetOrigin)
                nodes[i].last = p
                out.append(p)
            }
        }
        if out.count != firstChange {
            snapshot = nil
            for slotIdx in order {
                nodes[Int(slotIdx)].dirty = false
            }
        }
    }

    private func ancestorMoving(_ i: Int) -> Bool {
        let watched: [Int] = [
            Int(Props.FRAME.id.rawValue),
            Int(Props.TRAVEL.id.rawValue),
            Int(Props.OFFSET.id.rawValue),
            Int(Props.PRESENCE.id.rawValue),
            Int(Props.UNIFORM_SCALE.id.rawValue),
            Int(Props.OPACITY.id.rawValue),
            Int(Props.BLUR_SCALAR.id.rawValue),
        ]
        var p = nodes[i].parent
        while p != Self.noneIdx {
            let pn = nodes[Int(p)]
            for pid in watched {
                if let tid = pn.tracks[pid], store.isActive(tid) {
                    return true
                }
            }
            p = pn.parent
        }
        return false
    }

    internal func values(_ i: Int, _ p: PropId) -> ArraySlice<Float>? {
        let pid = Int(p.rawValue)
        guard let tid = nodes[i].tracks[pid] else { return nil }
        return store.valuesOf(tid)
    }

    private func targets4(_ i: Int, _ p: PropId) -> (Float, Float, Float, Float)? {
        let pid = Int(p.rawValue)
        guard let tid = nodes[i].tracks[pid] else { return nil }
        var buf = [Float](repeating: 0, count: 4)
        guard store.targetsOf(tid, into: &buf) else { return nil }
        return (buf[0], buf[1], buf[2], buf[3])
    }

    private func target1(_ i: Int, _ p: PropId) -> Float? {
        let pid = Int(p.rawValue)
        guard let tid = nodes[i].tracks[pid] else { return nil }
        var buf = [Float](repeating: 0, count: 1)
        guard store.targetsOf(tid, into: &buf) else { return nil }
        return buf[0]
    }

    private func restOf(_ i: Int, reduced: Bool, targetOrigin: Vec2) -> MotionRect {
        let n = nodes[i]
        let parent = n.parent
        let world: MotionRect
        if let path = n.path {
            var tp = [Float](repeating: 1.0, count: 2)
            if let tid = n.tracks[Int(Props.TRAVEL.id.rawValue)] {
                _ = store.targetsOf(tid, into: &tp)
            }
            let s = path.start.edges
            let e = path.endLocal.translated(targetOrigin).edges
            world = MotionRect.fromEdges(
                s.0 + (e.0 - s.0) * tp[0],
                s.1 + (e.1 - s.1) * tp[1],
                s.2 + (e.2 - s.2) * tp[0],
                s.3 + (e.3 - s.3) * tp[1]
            )
        } else {
            let origin = (parent == Self.noneIdx) ? Vec2.zero : rests[Int(parent)].origin
            let local: MotionRect
            if let t4 = targets4(i, Props.FRAME.id) {
                local = MotionRect.fromEdges(t4.0, t4.1, t4.2, t4.3)
            } else {
                local = n.frame
            }
            world = local.translated(origin)
        }
        let p = target1(i, Props.PRESENCE.id) ?? 1.0
        let (at0, at1) = n.presence.pair
        var s = lerpFx(at0, at1, p)
        if reduced {
            s = (s.0, 1.0, 0, 0, 0, 0, 0, 0, 1.0)
        }
        let own: Vec2
        if let tid = n.tracks[Int(Props.OFFSET.id.rawValue)] {
            var buf = [Float](repeating: 0, count: 2)
            own = store.targetsOf(tid, into: &buf) ? Vec2(buf[0], buf[1]) : n.baseOffset
        } else {
            own = n.baseOffset
        }
        return world.translated(Vec2(own.x + s.2 + s.4 * world.width, own.y + s.3 + s.5 * world.height))
    }

    private mutating func computePresented(
        _ i: Int,
        scale: Float,
        reduced: Bool,
        ownDirty: Bool,
        parentDirty: Bool,
        targetOrigin: Vec2
    ) -> Presented {
        let parent = nodes[i].parent
        let parentOrigin = (parent == Self.noneIdx) ? Vec2.zero : nodes[Int(parent)].origin
        let n = nodes[i]

        let world: MotionRect
        if let path = n.path {
            let tp: (Float, Float)
            if let vals = values(i, Props.TRAVEL.id), vals.count >= 2 {
                let b = vals.startIndex
                tp = (vals[b], vals[b + 1])
            } else {
                tp = (1.0, 1.0)
            }
            let s = path.start.edges
            let e = path.endLocal.translated(targetOrigin).edges
            world = MotionRect.fromEdges(
                s.0 + (e.0 - s.0) * tp.0,
                s.1 + (e.1 - s.1) * tp.1,
                s.2 + (e.2 - s.2) * tp.0,
                s.3 + (e.3 - s.3) * tp.1
            )
        } else {
            let local: MotionRect
            if let vals = values(i, Props.FRAME.id), vals.count >= 4 {
                let b = vals.startIndex
                local = MotionRect.fromEdges(vals[b], vals[b + 1], vals[b + 2], vals[b + 3])
            } else {
                local = n.frame
            }
            var w = local.translated(parentOrigin)
            if n.rideTrailing && parent != Self.noneIdx {
                let pn = nodes[Int(parent)]
                w = w.translated(Vec2(pn.world.width - pn.frame.width, 0))
            }
            world = w
        }

        let p = values(i, Props.PRESENCE.id)?.first ?? 1.0
        let (at0, at1) = n.presence.pair
        var s = lerpFx(at0, at1, p)
        if reduced {
            s = (s.0, 1.0, 0, 0, 0, 0, 0, 0, 1.0)
        }

        let ownOpacity = values(i, Props.OPACITY.id)?.first ?? n.opacity
        let ownUniformScale = values(i, Props.UNIFORM_SCALE.id)?.first ?? 1.0
        let ownScale2D: Vec2
        if let sv = values(i, Props.SCALE.id), sv.count >= 2 {
            let b = sv.startIndex
            ownScale2D = Vec2(sv[b], sv[b + 1])
        } else {
            ownScale2D = n.baseScale2D
        }
        let ownOffset: Vec2
        if let ov = values(i, Props.OFFSET.id), ov.count >= 2 {
            let b = ov.startIndex
            ownOffset = Vec2(ov[b], ov[b + 1])
        } else {
            ownOffset = n.baseOffset
        }
        let rotation = values(i, Props.ROTATE.id)?.first ?? n.baseRotate
        let ownBlur = values(i, Props.BLUR_SCALAR.id)?.first ?? values(i, Props.BLUR.id)?.first ?? n.baseBlur
        let radius: Corners
        if let rv = values(i, Props.CORNERS.id), rv.count >= 4 {
            let b = rv.startIndex
            radius = Corners(rv[b], rv[b + 1], rv[b + 2], rv[b + 3])
        } else {
            radius = n.radius
        }
        let fill: MotionColor?
        if n.hasFill {
            if let fv = values(i, Props.FILL.id), fv.count >= 4 {
                let b = fv.startIndex
                fill = MotionColor.fromLanes(MotionLanes(fv[b], fv[b + 1], fv[b + 2], fv[b + 3]))
            } else {
                fill = n.fill
            }
        } else if let tid = n.tracks[Int(Props.FILL.id.rawValue)], let fv = store.valuesOf(tid), fv.count >= 4 {
            let b = fv.startIndex
            fill = MotionColor.fromLanes(MotionLanes(fv[b], fv[b + 1], fv[b + 2], fv[b + 3]))
        } else {
            fill = nil
        }
        let border: MotionColor?
        if n.hasBorder {
            if let bv = values(i, Props.BORDER.id), bv.count >= 4 {
                let b = bv.startIndex
                border = MotionColor.fromLanes(MotionLanes(bv[b], bv[b + 1], bv[b + 2], bv[b + 3]))
            } else {
                border = n.border
            }
        } else {
            border = nil
        }

        let ownMask: Sides
        if let mv = values(i, Props.MASK.id), mv.count >= 4 {
            let b = mv.startIndex
            ownMask = Sides(top: mv[b], right: mv[b + 1], bottom: mv[b + 2], left: mv[b + 3])
        } else {
            ownMask = .zeroValue
        }

        let offset = Vec2(
            ownOffset.x + s.2 + s.4 * world.width,
            ownOffset.y + s.3 + s.5 * world.height
        )
        let shown = world.translated(offset)
        let sx = max(0, ownUniformScale * ownScale2D.x * s.1)
        let sy = max(0, ownUniformScale * ownScale2D.y * s.1)
        var blur = max(0, ownBlur + s.6)
        if blur < 1.0 / 64.0 {
            blur = 0.0
        }

        var mask = Mask(inset: ownMask, feather: .zeroValue)
        var revealClip: MotionRect? = nil
        if let rv = n.reveal {
            let hidden = s.7.clamped(to: 0...1)
            if hidden > 0 {
                switch rv.edge {
                case .leading:
                    let d = hidden * shown.width
                    mask.inset.right += d
                    mask.feather.right = rv.feather * min(1.0, d / max(rv.feather, 1e-3))
                case .top:
                    let d = hidden * shown.height
                    mask.inset.bottom += d
                    mask.feather.bottom = rv.feather * min(1.0, d / max(rv.feather, 1e-3))
                case .trailing:
                    let d = hidden * shown.width
                    mask.inset.left += d
                    mask.feather.left = rv.feather * min(1.0, d / max(rv.feather, 1e-3))
                case .bottom:
                    let d = hidden * shown.height
                    mask.inset.top += d
                    mask.feather.top = rv.feather * min(1.0, d / max(rv.feather, 1e-3))
                }
                revealClip = snapRect(rv.clipRect(for: shown, presence: 1.0 - hidden), pixelScale: scale)
            }
        }

        let anchor = Vec2(shown.left + n.anchor.x * shown.width, shown.top + n.anchor.y * shown.height)

        var fl: UInt32 = 0
        var ownBits: UInt32 = 0
        for (k, entry) in n.tracks.entries.enumerated() {
            if let tid = entry, store.isActive(tid) {
                ownBits |= TraceIntent.forProp(PropId(UInt16(k)))
            }
        }
        if n.path != nil {
            ownBits |= TraceIntent.position | TraceIntent.size
        }
        if ownBits != 0 || (ownDirty && !parentDirty) {
            fl |= TraceFlags.animated
        }
        if parentDirty {
            fl |= TraceFlags.ancestorAnimated
            let pb = nodes[Int(parent)].last.map { ($0.flags >> 8) & 0xff | ($0.flags >> 16) & 0xff } ?? 0
            fl |= pb << 16
        }
        fl |= ownBits << 8
        if !mask.isNone { fl |= TraceFlags.clipped }
        if blur > 0 { fl |= TraceFlags.filtered }

        let inFlow = !n.presence.isExiting || !n.transition.popLayout
        let snapped = snapRect(shown, pixelScale: scale)
        let outPresented = Presented(
            id: n.id,
            parent: (parent != Self.noneIdx) ? nodes[Int(parent)].id : nil,
            rect: snapped,
            targetRect: n.frame.translated(targetOrigin),
            revealClip: revealClip,
            opacity: (ownOpacity * s.0).clamped(to: 0...1),
            transform: Transform2D(tx: 0, ty: 0, sx: sx, sy: sy, rot: rotation),
            anchor: anchor,
            blur: blur,
            corners: radius,
            fill: fill,
            border: border,
            mask: mask,
            phase: n.presence.public(n.generation),
            inFlow: inFlow,
            flags: fl,
            draw: s.8.clamped(to: 0...1),
            presence: p,
            isMoving: ownBits != 0
        )

        let parentStill = parent == Self.noneIdx || rests[Int(parent)].origin == nodes[Int(parent)].origin
        let ownStill = [Props.TRAVEL.id, Props.FRAME.id, Props.PRESENCE.id, Props.OFFSET.id].allSatisfy { pid in
            guard let tid = nodes[i].tracks[Int(pid.rawValue)] else { return true }
            return store.isSettled(tid)
        }
        let restRect = (!nodes[i].rideTrailing && parentStill && ownStill) ? shown : restOf(i, reduced: reduced, targetOrigin: targetOrigin)
        nodes[i].world = world
        nodes[i].origin = Vec2(shown.left, shown.top)
        rests[i] = SceneRest(rect: restRect, origin: Vec2(restRect.left, restRect.top), moving: restRect != shown)
        return outPresented
    }

    // MARK: - Slot & Intrusive Tree Management

    internal mutating func allocNodeSlot(id: NodeId, parent: UInt32, spec: NodeSpec) -> Int {
        let idx: Int
        if let freeSlot = free.popLast() {
            idx = Int(freeSlot)
        } else {
            idx = nodes.count
            nodes.append(Node(
                id: id, parent: parent,
                firstChild: Self.noneIdx, lastChild: Self.noneIdx,
                nextSibling: Self.noneIdx, prevSibling: Self.noneIdx,
                alive: true, frame: spec.rect, opacity: spec.opacity,
                baseScale2D: spec.scale, baseRotate: spec.rotate, baseOffset: spec.offset,
                baseBlur: spec.blur, radius: spec.corners,
                fill: spec.fill ?? .zeroValue, border: spec.border ?? .zeroValue,
                hasFill: spec.fill != nil, hasBorder: spec.border != nil,
                transition: spec.transition ?? .none,
                compatHadTransition: spec.transition != nil,
                presence: .present(at0: fxIdentity, at1: fxIdentity),
                generation: 0, anchor: Vec2(0.5, 0.5), reveal: nil, path: nil,
                rideTrailing: false,
                tracks: NodeTracks(),
                dirty: true, world: .zero, origin: .zero, last: nil
            ))
            rests.append(SceneRest())
            index[id.rawValue] = UInt32(idx)
            orderDirty = true
            return idx
        }
        nodes[idx] = Node(
            id: id, parent: parent,
            firstChild: Self.noneIdx, lastChild: Self.noneIdx,
            nextSibling: Self.noneIdx, prevSibling: Self.noneIdx,
            alive: true, frame: spec.rect, opacity: spec.opacity,
            baseScale2D: spec.scale, baseRotate: spec.rotate, baseOffset: spec.offset,
            baseBlur: spec.blur, radius: spec.corners,
            fill: spec.fill ?? .zeroValue, border: spec.border ?? .zeroValue,
            hasFill: spec.fill != nil, hasBorder: spec.border != nil,
            transition: spec.transition ?? .none,
            compatHadTransition: spec.transition != nil,
            presence: .present(at0: fxIdentity, at1: fxIdentity),
            generation: 0, anchor: Vec2(0.5, 0.5), reveal: nil, path: nil,
            rideTrailing: false,
            tracks: NodeTracks(),
            dirty: true, world: .zero, origin: .zero, last: nil
        )
        rests[idx] = SceneRest()
        index[id.rawValue] = UInt32(idx)
        orderDirty = true
        return idx
    }

    internal mutating func linkNodeSlot(_ i: Int, parent: UInt32) {
        let ui = UInt32(i)
        nodes[i].parent = parent
        if parent == Self.noneIdx {
            let tail = rootTail
            nodes[i].prevSibling = tail
            nodes[i].nextSibling = Self.noneIdx
            if tail == Self.noneIdx {
                rootHead = ui
            } else {
                nodes[Int(tail)].nextSibling = ui
            }
            rootTail = ui
        } else {
            let pi = Int(parent)
            let tail = nodes[pi].lastChild
            nodes[i].prevSibling = tail
            nodes[i].nextSibling = Self.noneIdx
            if tail == Self.noneIdx {
                nodes[pi].firstChild = ui
            } else {
                nodes[Int(tail)].nextSibling = ui
            }
            nodes[pi].lastChild = ui
        }
        orderDirty = true
    }

    internal mutating func unlinkNodeSlot(_ i: Int) {
        let parent = nodes[i].parent
        let next = nodes[i].nextSibling
        let prev = nodes[i].prevSibling
        if prev == Self.noneIdx {
            if parent == Self.noneIdx { rootHead = next } else { nodes[Int(parent)].firstChild = next }
        } else {
            nodes[Int(prev)].nextSibling = next
        }
        if next == Self.noneIdx {
            if parent == Self.noneIdx { rootTail = prev } else { nodes[Int(parent)].lastChild = prev }
        } else {
            nodes[Int(next)].prevSibling = prev
        }
        nodes[i].nextSibling = Self.noneIdx
        nodes[i].prevSibling = Self.noneIdx
        orderDirty = true
    }

    internal mutating func reparentSlot(_ i: Int, to newParentId: NodeId?) {
        let newParentIdx = newParentId.flatMap { slot($0) }.map(UInt32.init) ?? Self.noneIdx
        if nodes[i].parent == newParentIdx { return }
        unlinkNodeSlot(i)
        linkNodeSlot(i, parent: newParentIdx)
        nodes[i].dirty = true
    }

    /// Re-links `parentIdx`'s children so active seen slots follow `orderedSlots` (preserving any exiting tail).
    private mutating func syncSiblingOrder(parent parentIdx: UInt32, orderedSlots: [Int]) {
        let seenSet = Set(orderedSlots)
        var combined = orderedSlots
        var c = (parentIdx == Self.noneIdx) ? rootHead : nodes[Int(parentIdx)].firstChild
        while c != Self.noneIdx {
            let ci = Int(c)
            if !seenSet.contains(ci) {
                combined.append(ci)
            }
            c = nodes[ci].nextSibling
        }

        let first = combined.first.map(UInt32.init) ?? Self.noneIdx
        let last = combined.last.map(UInt32.init) ?? Self.noneIdx
        if parentIdx == Self.noneIdx {
            rootHead = first
            rootTail = last
        } else {
            nodes[Int(parentIdx)].firstChild = first
            nodes[Int(parentIdx)].lastChild = last
        }
        for (k, ci) in combined.enumerated() {
            nodes[ci].prevSibling = k > 0 ? UInt32(combined[k - 1]) : Self.noneIdx
            nodes[ci].nextSibling = k + 1 < combined.count ? UInt32(combined[k + 1]) : Self.noneIdx
        }
        orderDirty = true
    }

    /// Most commits retain sibling order even when leading virtual rows disappear.
    /// Check the intrusive links first and collect a child array only for a reordered parent.
    private mutating func syncCommittedOrder(
        _ children: [(parent: UInt32, slot: UInt32)], committed: [Bool]
    ) {
        var previous = [UInt32](repeating: Self.noneIdx, count: nodes.count + 1)
        var reordered: [UInt32: [Int]] = [:]
        for (parent, slot) in children {
            let owner = parent == Self.noneIdx ? nodes.count : Int(parent)
            let expected = previous[owner]
            var prior = nodes[Int(slot)].prevSibling
            while prior != expected, prior != Self.noneIdx, !committed[Int(prior)] {
                prior = nodes[Int(prior)].prevSibling
            }
            if prior != expected { reordered[parent] = [] }
            previous[owner] = slot
        }
        if reordered.isEmpty { return }
        for (parent, slot) in children {
            reordered[parent]?.append(Int(slot))
        }
        for (parent, slots) in reordered {
            syncSiblingOrder(parent: parent, orderedSlots: slots)
        }
    }

    internal mutating func removeNow(_ i: Int) {
        var c = nodes[i].firstChild
        while c != Self.noneIdx {
            let next = nodes[Int(c)].nextSibling
            removeNow(Int(c))
            c = next
        }
        let id = nodes[i].id
        unlinkNodeSlot(i)
        travelling.removeAll { Int($0) == i }
        launchEndpoints.removeValue(forKey: id)
        store.removeNode(id)
        index.removeValue(forKey: id.rawValue)
        nodes[i].alive = false
        nodes[i].dirty = false
        nodes[i].firstChild = Self.noneIdx
        nodes[i].lastChild = Self.noneIdx
        nodes[i].last = nil
        free.append(UInt32(i))
        exitedCarry.push(id)
        orderDirty = true
    }

    internal mutating func rebuildOrder() {
        snapshot = nil
        snapshotPositions = nil
        order.removeAll(keepingCapacity: true)
        var r = rootHead
        while r != Self.noneIdx {
            order.append(r)
            r = nodes[Int(r)].nextSibling
        }
        var k = 0
        while k < order.count {
            var c = nodes[Int(order[k])].firstChild
            while c != Self.noneIdx {
                order.append(c)
                c = nodes[Int(c)].nextSibling
            }
            k += 1
        }
        orderDirty = false
    }

    // MARK: - Declarative Compatibility Layer (`Runtime` & `RuneMotionTests`)

    private mutating func applyMatchedFlight(_ i: Int, spec: NodeSpec, match m: MatchedFlightStart) {
        if store.reducedMotion {
            let acts = nodes[i].phaseStep(.fadeIn(transition: spec.transition ?? .opacity))
            applyPhaseActs(i, acts)
            return
        }
        startPath(i, start: m.startRect, velocity: m.startVelocity, anim: LayoutAnim(spring: m.spring, travel: .screen))
        if let sc = m.startCorners {
            trackSet(i, Props.CORNERS, sc)
            trackAnimate(i, Props.CORNERS, spec.corners, Anim<Corners>(curve: Curve.from(m.spring)))
        }
        if let sf = m.startFill, let tf = spec.fill {
            trackSet(i, Props.FILL, sf)
            trackAnimate(i, Props.FILL, tf, Anim<MotionColor>(curve: Curve.from(m.spring)))
        }
        if let so = m.startOpacity {
            trackSet(i, Props.OPACITY, so)
            trackAnimate(i, Props.OPACITY, spec.opacity, Anim<Float>(curve: Curve.from(m.spring)))
        }
    }

    /// Commits a freshly laid-out list of world-space `NodeSpec`s at `now`.
    public mutating func commit(
        _ specs: [NodeSpec],
        at now: Double,
        initialCut: Bool = false,
        snapMounts: Bool = false,
        snapOmittedNonExiting: Bool = false,
        matchedStarts: [NodeId: MatchedFlightStart] = [:],
        unmountNewOmissions: Bool = false,
        animatedExitParents: Set<NodeId> = [],
        landWaitingNodes: Bool = false,
        snapNewMounts: Bool = false
    ) {
        commit(specs, at: now, initialCut: initialCut, snapMounts: snapMounts,
               snapOmittedNonExiting: snapOmittedNonExiting, matchedStarts: matchedStarts,
               unmountNewOmissions: unmountNewOmissions, animatedExitParents: animatedExitParents,
               landWaitingNodes: landWaitingNodes, snapNewMounts: snapNewMounts, retainingUnchanged: false)
    }

    /// A commit may reuse a fully settled slot. Compare the live scene so that
    /// imperative property tracks, reparenting, and in-flight transitions are honored.
    /// Borrow the mounted nodes and tracks for this per-node check during commit and offscreen landing.
    private static func matchesRestingSpec(
        _ index: Int, _ spec: NodeSpec, localFrame: MotionRect, nodes: borrowing [Node], store: borrowing AnimationStore
    ) -> Bool {
        let node = nodes[index]
        guard node.presence.isPresent, node.path == nil, spec.launchLayout == nil,
              node.frame == localFrame, !store.hasTracks(node.id),
              node.tracks.entries.allSatisfy({ $0 == nil }),
              node.opacity == spec.opacity, node.baseScale2D == spec.scale,
              node.baseOffset == spec.offset, node.baseBlur == spec.blur, node.baseRotate == spec.rotate,
              node.radius == spec.corners, spec.iconTurn == 0,
              node.hasFill == (spec.fill != nil), node.hasBorder == (spec.border != nil),
              spec.fill.map({ $0 == node.fill }) ?? true, spec.border.map({ $0 == node.border }) ?? true,
              node.compatHadTransition == (spec.transition != nil),
              node.transition == (spec.transition ?? .none) else { return false }
        let parent = node.parent == Self.noneIdx ? nil : nodes[Int(node.parent)].id
        return parent == spec.parent
    }

    /// An offscreen node is landed after commit. Ordinary settled nodes already hold
    /// these values. An authored animation or a sleeping imperative track still needs
    /// the normal property reconciliation.
    package mutating func landUnseen(_ spec: NodeSpec, localFrame: MotionRect) {
        guard let index = slot(spec.id),
              !Self.matchesRestingSpec(index, spec, localFrame: localFrame, nodes: nodes, store: store) else { return }
        landFrame(spec.id, localFrame)
        if let fill = spec.fill { set(spec.id, Props.FILL, fill) }
        if let border = spec.border { set(spec.id, Props.BORDER, border) }
        set(spec.id, Props.OPACITY, spec.opacity)
        set(spec.id, Props.BLUR, Blur(spec.blur))
        set(spec.id, Props.CORNERS, spec.corners)
        set(spec.id, Props.OFFSET, spec.offset)
        set(spec.id, Props.SCALE, spec.scale)
        set(spec.id, Props.ROTATE, spec.rotate)
    }

    package mutating func commit(
        _ specs: [NodeSpec],
        at now: Double,
        initialCut: Bool = false,
        snapMounts: Bool = false,
        snapOmittedNonExiting: Bool = false,
        matchedStarts: [NodeId: MatchedFlightStart] = [:],
        unmountNewOmissions: Bool = false,
        animatedExitParents: Set<NodeId> = [],
        landWaitingNodes: Bool = false,
        snapNewMounts: Bool = false,
        retainingUnchanged: Bool
    ) {
        setTime(now)
        let cut = initialCut || !hasCommittedOnce
        hasCommittedOnce = true

        // Collect all nodes immediately superseded by a matched-geometry transfer (and their unmounted descendants).
        var matchedRemovedIds = Set<NodeId>(matchedStarts.values.compactMap(\.fromId))
        if !matchedRemovedIds.isEmpty {
            var added = true
            while added {
                added = false
                for n in nodes where n.alive && !matchedRemovedIds.contains(n.id) {
                    if n.parent != Self.noneIdx, matchedRemovedIds.contains(nodes[Int(n.parent)].id) {
                        matchedRemovedIds.insert(n.id)
                        added = true
                    }
                }
            }
        }

        var worldOrigins: [NodeId: Vec2] = [:]
        worldOrigins.reserveCapacity(specs.count)
        for s in specs {
            worldOrigins[s.id] = s.rect.origin
        }

        let canRetain = !cut && trace == nil
        var children: [(parent: UInt32, slot: UInt32)] = []
        children.reserveCapacity(specs.count)
        for spec in specs {
            let parentOrigin = spec.parent.flatMap { worldOrigins[$0] } ?? .zero
            let localFrame = MotionRect.fromEdges(
                spec.rect.left - parentOrigin.x,
                spec.rect.top - parentOrigin.y,
                spec.rect.right - parentOrigin.x,
                spec.rect.bottom - parentOrigin.y
            )
            let existing = slot(spec.id)
            if let existing, canRetain, matchedStarts[spec.id] == nil,
               Self.matchesRestingSpec(existing, spec, localFrame: localFrame, nodes: nodes, store: store) {
                // Ordinary commits publish unchanged nodes too. Virtual remounts only
                // present these nodes when their parent moves.
                if !retainingUnchanged { nodes[existing].dirty = true }
                children.append((nodes[existing].parent, UInt32(existing)))
                continue
            }
            var localSpec = spec
            localSpec.rect = localFrame
            if let existingIdx = existing {
                let wasExiting = nodes[existingIdx].presence.isExiting
                let wasScreenChange = spec.layoutAnim?.travel == .screen
                    && (nodes[existingIdx].parent != (spec.parent.flatMap { slot($0) }.map(UInt32.init) ?? Self.noneIdx))
                let preWorld = wasScreenChange ? exactWorld(existingIdx) : nil

                if let trans = spec.transition {
                    nodes[existingIdx].compatHadTransition = true
                    localSpec.transition = trans
                } else {
                    nodes[existingIdx].compatHadTransition = false
                    localSpec.transition = Transition.none
                }

                // Keep existing frame across `insert` so `insertDelayed` does not start a 0.40s `REFLOW`
                // animation before `setFrame`/`landFrame` below applies `spec.layoutAnim`.
                var insertSpec = localSpec
                insertSpec.frame = nodes[existingIdx].frame
                if wasExiting, !cut, let m = matchedStarts[spec.id] {
                    insert(spec.id, insertSpec, .initial)
                    landFrame(spec.id, localFrame)
                    applyMatchedFlight(existingIdx, spec: spec, match: m)
                } else {
                    insert(spec.id, insertSpec, cut ? .initial : .animated)
                    if cut {
                        enterNow(spec.id)
                    } else if landWaitingNodes {
                        landWaiting(spec.id)
                    }

                    if let (curPos, curVel) = preWorld, let la = spec.layoutAnim, !store.reducedMotion && !cut {
                        nodes[existingIdx].frame = localFrame
                        startPath(
                            existingIdx,
                            start: MotionRect.fromEdges(curPos.0, curPos.1, curPos.2, curPos.3),
                            velocity: curVel,
                            anim: la
                        )
                    } else if !cut, spec.launchLayout == .projectEndpoint, var path = nodes[existingIdx].path {
                        // Scroll and growth can move the destination while the takeoff stays in window space.
                        nodes[existingIdx].frame = localFrame
                        path.endLocal = localFrame
                        path.origin = parentTargetOrigin(existingIdx)
                        nodes[existingIdx].path = path
                    } else if cut || spec.layoutAnim == nil {
                        landFrame(spec.id, localFrame)
                    } else if let la = spec.layoutAnim {
                        setFrameDrawn(spec.id, localFrame, la, drawnOffset: .zero, drawnVelocity: .zero,
                                      forceScreenRetarget: spec.launchLayout == .reaim)
                    }
                }

                // Update visual properties smoothly or immediately
                nodes[existingIdx].hasFill = (spec.fill != nil)
                nodes[existingIdx].hasBorder = (spec.border != nil)
                let matchedExiting = wasExiting && !cut && matchedStarts[spec.id] != nil && !store.reducedMotion
                if !matchedExiting {
                    if !cut, let opAnim = spec.opacityAnim {
                        let rest = store.target(spec.id, Props.OPACITY) ?? get(spec.id, Props.OPACITY)
                        if rest != spec.opacity {
                            animate(spec.id, Props.OPACITY, to: spec.opacity, anim: opAnim)
                        }
                    } else if !cut, let sp = spec.styleSpring {
                        animate(spec.id, Props.OPACITY, to: spec.opacity, anim: Anim<Float>(curve: Curve.from(sp)))
                    } else {
                        set(spec.id, Props.OPACITY, spec.opacity)
                    }

                    if !cut && !store.reducedMotion, let scAnim = spec.scaleAnim {
                        let rest = store.target(spec.id, Props.SCALE) ?? get(spec.id, Props.SCALE)
                        if rest != spec.scale {
                            animate(spec.id, Props.SCALE, to: spec.scale, anim: scAnim)
                        }
                    } else if !cut && !store.reducedMotion, let sp = spec.styleSpring {
                        animate(spec.id, Props.SCALE, to: spec.scale, anim: Anim(curve: Curve.from(sp)))
                    } else {
                        set(spec.id, Props.SCALE, spec.scale)
                    }

                    if !cut && !store.reducedMotion, let rotAnim = spec.rotateAnim {
                        let rest = store.target(spec.id, Props.ROTATE) ?? get(spec.id, Props.ROTATE)
                        if rest != spec.rotate {
                            animate(spec.id, Props.ROTATE, to: spec.rotate, anim: rotAnim)
                        }
                    } else if !cut && !store.reducedMotion, let sp = spec.styleSpring {
                        animate(spec.id, Props.ROTATE, to: spec.rotate, anim: Anim<Float>(curve: Curve.from(sp)))
                    } else {
                        set(spec.id, Props.ROTATE, spec.rotate)
                    }

                    if !cut && !store.reducedMotion, let offAnim = spec.offsetAnim {
                        let rest = store.target(spec.id, Props.OFFSET) ?? get(spec.id, Props.OFFSET)
                        if rest != spec.offset {
                            animate(spec.id, Props.OFFSET, to: spec.offset, anim: offAnim)
                        }
                    } else if !cut && !store.reducedMotion, let sp = spec.styleSpring {
                        if spec.animateOffset {
                            animate(spec.id, Props.OFFSET, to: spec.offset, anim: Anim(curve: Curve.from(sp)))
                        } else if let la = spec.layoutAnim {
                            animate(spec.id, Props.OFFSET, to: spec.offset, anim: Anim(curve: la.x.curve))
                        } else {
                            set(spec.id, Props.OFFSET, spec.offset)
                        }
                    } else {
                        set(spec.id, Props.OFFSET, spec.offset)
                    }

                    if !cut, let sp = spec.cornerSpring ?? spec.styleSpring {
                        animate(spec.id, Props.CORNERS, to: spec.corners, anim: Anim(curve: Curve.from(sp)))
                    } else {
                        set(spec.id, Props.CORNERS, spec.corners)
                    }
                    if !cut, let blur = spec.blurMotion {
                        animate(spec.id, Props.BLUR, to: Blur(spec.blur), anim: blur.animation)
                    } else if !cut, let sp = spec.styleSpring {
                        animate(spec.id, Props.BLUR, to: Blur(spec.blur), anim: Anim(curve: Curve.from(sp)))
                    } else {
                        set(spec.id, Props.BLUR, Blur(spec.blur))
                    }
                    if spec.iconTurn != 0 || store.has(spec.id, Props.ICON_TURN) {
                        if !cut && !store.reducedMotion, let sp = spec.styleSpring ?? spec.paintSpring {
                            if !wasExiting && !store.has(spec.id, Props.ICON_TURN) {
                                set(spec.id, Props.ICON_TURN, 0)
                            }
                            animate(spec.id, Props.ICON_TURN, to: spec.iconTurn, anim: Anim<Float>(curve: Curve.from(sp)))
                        } else {
                            set(spec.id, Props.ICON_TURN, spec.iconTurn)
                        }
                    }
                } else {
                    // Matched start animates opacity/corners/fill from the source snapshot.
                    set(spec.id, Props.SCALE, spec.scale)
                    set(spec.id, Props.ROTATE, spec.rotate)
                    set(spec.id, Props.OFFSET, spec.offset)
                    set(spec.id, Props.BLUR, Blur(spec.blur))
                    if matchedStarts[spec.id]?.startCorners == nil {
                        set(spec.id, Props.CORNERS, spec.corners)
                    }
                    if matchedStarts[spec.id]?.startOpacity == nil {
                        set(spec.id, Props.OPACITY, spec.opacity)
                    }
                    if matchedStarts[spec.id]?.startFill == nil, let fill = spec.fill {
                        set(spec.id, Props.FILL, fill)
                    }
                    if let border = spec.border {
                        set(spec.id, Props.BORDER, border)
                    }
                }
                if !matchedExiting {
                    let fillSpring = !cut ? (spec.paintSpring ?? spec.colorSpring ?? spec.styleSpring) : nil
                    let borderSpring = !cut ? (spec.paintSpring ?? spec.colorSpring ?? spec.styleSpring) : nil
                    if let fill = spec.fill {
                        if let psp = fillSpring {
                            animate(spec.id, Props.FILL, to: fill, anim: Anim<MotionColor>(curve: Curve.from(psp)))
                        } else {
                            set(spec.id, Props.FILL, fill)
                        }
                    }
                    if let border = spec.border {
                        if let bsp = borderSpring {
                            animate(spec.id, Props.BORDER, to: border, anim: Anim<MotionColor>(curve: Curve.from(bsp)))
                        } else {
                            set(spec.id, Props.BORDER, border)
                        }
                    }
                }
                nodes[existingIdx].dirty = true
            } else if !cut, let m = matchedStarts[spec.id] {
                insert(spec.id, localSpec, .initial)
                if let i = slot(spec.id) {
                    nodes[i].compatHadTransition = (spec.transition != nil)
                    if spec.scale != Vec2(1, 1) { nodes[i].baseScale2D = spec.scale }
                    if spec.rotate != 0 { nodes[i].baseRotate = spec.rotate }
                    if spec.offset != .zero { nodes[i].baseOffset = spec.offset }
                    if spec.blur != 0 { nodes[i].baseBlur = spec.blur }
                    if spec.iconTurn != 0 { set(spec.id, Props.ICON_TURN, spec.iconTurn) }
                    if let border = spec.border { nodes[i].border = border; nodes[i].hasBorder = true }
                    applyMatchedFlight(i, spec: spec, match: m)
                }
            } else {
                let mount: Mount = (cut || snapMounts || snapNewMounts || spec.snapMount || spec.transition == nil) ? .initial : .animated
                insertDelayed(spec.id, localSpec, mount, delay: spec.enterDelay)
                if let i = slot(spec.id) {
                    nodes[i].compatHadTransition = (spec.transition != nil)
                    if spec.scale != Vec2(1, 1) { nodes[i].baseScale2D = spec.scale }
                    if spec.rotate != 0 { nodes[i].baseRotate = spec.rotate }
                    if spec.offset != .zero { nodes[i].baseOffset = spec.offset }
                    if spec.blur != 0 { nodes[i].baseBlur = spec.blur }
                    if spec.iconTurn != 0 { set(spec.id, Props.ICON_TURN, spec.iconTurn) }
                    if let border = spec.border { nodes[i].border = border; nodes[i].hasBorder = true }
                }
            }
            if let committedSlot = slot(spec.id) {
                if spec.launchLayout != nil, let path = nodes[committedSlot].path,
                   spec.launchLayout == .reaim || launchEndpoints[spec.id] == nil {
                    launchEndpoints[spec.id] = LaunchEndpoint(at: now, rect: path.endLocal.translated(path.origin))
                }
                children.append((nodes[committedSlot].parent, UInt32(committedSlot)))
            }
        }

        let allPresent = worldOrigins.count == index.count
        var committed = [Bool](repeating: allPresent, count: nodes.count)
        if !allPresent {
            for child in children { committed[Int(child.slot)] = true }
        }
        syncCommittedOrder(children, committed: committed)
        if allPresent { return }

        // Removing an omitted parent can recursively retire other omitted slots.
        let omitted = index.values.filter { !committed[Int($0)] }
        for slot in omitted {
            let i = Int(slot)
            guard nodes[i].alive else { continue }
            let nid = nodes[i].id
            if cut || landWaitingNodes || matchedRemovedIds.contains(nid) {
                unmount(nid)
                continue
            }
            // Keep descendants of an omitted/exiting ancestor mounted in place while the ancestor fades out (upstream apply.rs:748).
            let pIdx = nodes[i].parent
            let parentRemainedPresent = (pIdx == Self.noneIdx) || committed[Int(pIdx)]
            guard parentRemainedPresent else { continue }
            let ridesParent = pIdx != Self.noneIdx && animatedExitParents.contains(nodes[Int(pIdx)].id)
            if !nodes[i].compatHadTransition || ((snapOmittedNonExiting || unmountNewOmissions) && !ridesParent && !nodes[i].presence.isExiting) {
                if !nodes[i].compatHadTransition && !snapOmittedNonExiting && !unmountNewOmissions {
                    // Detach any active transitioning flights under an un-transitioned parent so they fade out rather than popping.
                    var queue: [UInt32] = []
                    var c = nodes[i].firstChild
                    while c != Self.noneIdx {
                        queue.append(c)
                        c = nodes[Int(c)].nextSibling
                    }
                    var qIdx = 0
                    while qIdx < queue.count {
                        let di = Int(queue[qIdx])
                        qIdx += 1
                        guard nodes[di].alive else { continue }
                        if !committed[di] && !matchedRemovedIds.contains(nodes[di].id),
                           nodes[di].path != nil && nodes[di].compatHadTransition {
                            let pw = parentTargetOrigin(di)
                            if var sp = nodes[di].path {
                                sp.endLocal = sp.endLocal.translated(pw)
                                sp.origin = .zero
                                nodes[di].path = sp
                            }
                            nodes[di].frame = nodes[di].frame.translated(pw)
                            reparentSlot(di, to: nil)
                            remove(nodes[di].id)
                            continue
                        }
                        var dc = nodes[di].firstChild
                        while dc != Self.noneIdx {
                            queue.append(dc)
                            dc = nodes[Int(dc)].nextSibling
                        }
                    }
                }
                unmount(nid)
            } else if !nodes[i].presence.isExiting {
                remove(nid)
            }
        }
    }

    /// Evaluates the scene at `now` and populates `nodes`/`byId` snapshots alongside incremental output.
    public mutating func frame(at now: Double) -> FrameOutput {
        var frame = frameForRendering(at: now)
        frame.expandPoseDictionary()
        return frame
    }

    package mutating func frameForRendering(at now: Double) -> FrameOutput {
        setTime(now)
        return frameImpl(includeSnapshot: true)
    }

    /// Cuts all active tracks immediately to their targets and drops exiting nodes.
    public mutating func settle(at now: Double) {
        if orderDirty { rebuildOrder() }
        var liveSpecs: [NodeSpec] = []
        for ui in order {
            let i = Int(ui)
            let n = nodes[i]
            guard n.alive, !n.presence.isExiting else { continue }
            let parentId = (n.parent == Self.noneIdx) ? nil : nodes[Int(n.parent)].id
            let worldRect = n.frame.translated(parentTargetOrigin(i))
            liveSpecs.append(NodeSpec(
                id: n.id,
                parent: parentId,
                rect: worldRect,
                opacity: n.opacity,
                scale: n.baseScale2D,
                rotate: n.baseRotate,
                offset: n.baseOffset,
                corners: n.radius,
                blur: n.baseBlur,
                fill: n.hasFill ? n.fill : nil,
                border: n.hasBorder ? n.border : nil,
                transition: n.compatHadTransition ? n.transition : nil
            ))
        }
        nodes.removeAll(keepingCapacity: true)
        rests.removeAll(keepingCapacity: true)
        free.removeAll(keepingCapacity: true)
        index.removeAll(keepingCapacity: true)
        rootHead = Self.noneIdx
        rootTail = Self.noneIdx
        order.removeAll(keepingCapacity: true)
        orderDirty = false
        snapshot = nil
        snapshotPositions = nil
        travelling.removeAll(keepingCapacity: true)
        launchEndpoints.removeAll(keepingCapacity: true)
        store.clear()
        hasCommittedOnce = false
        commit(liveSpecs, at: now, initialCut: true)
    }
}
