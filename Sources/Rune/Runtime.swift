import Foundation
import RuneMotion
import RuneRef
#if canImport(simd)
import simd
#endif

private struct FlightCoverTransform {
    var targetOrigin: Vec2
    var presentedOrigin: Vec2
    var scale: Float
}

private struct LiftedFlightSubtree {
    var node: Presented
    var ancestorOpacity: Float
    var ancestorTurn: Turn?
    var outerTurnClip: MotionRect?
    var localTurnClip: MotionRect?
    var parentPath: String?
    var nearestGroupHovered: Bool
}

/// Snapshot of a mounted or exiting UI element exposed to tests, accessibility, and `--tree` JSON.
public struct ElementInfo: Sendable, Equatable {
    public var path: String
    public var key: String?
    public var parentIndex: Int?
    public var role: ElementRole
    /// Presented `[x, y, width, height]` in logical window points.
    public var rect: [Float]
    /// Unsnapped layout target `[x, y, width, height]` in logical window points.
    public var target: [Float]
    /// Visible clipped `[x, y, width, height]` in logical window points.
    public var visible: [Float]
    public var opacity: Float
    public var scale: Float
    public var blur: Float
    public var radius: Float
    public var fill: Color
    public var textColor: Color?
    public var text: String?
    public var label: String?
    public var help: String?
    public var selected: String?
    public var expanded: Bool?
    public var level: Int?
    public var itemSelected: Bool
    public var focusable: Bool
    public var focused: Bool
    public var focusVisible: Bool
    public var inert: Bool
    public var moving: Bool
    public var exiting: Bool
    public var hover: Float
    public var press: Float
    public var scrolled: [Float]
    public var caret: [Float]?
    public var secure: Bool = false
    public var disabled: Bool = false
    public var checked: A11yChecked? = nil
    public var a11yValue: String? = nil
    public var a11yDescription: String? = nil
    public var a11yHidden: Bool = false
}

/// Retained stateful coordinator driving declarative `El<State>` views, layout, `Scene` motion,
/// hit-testing, pointer/drag/scroll/keyboard/text-edit routing, and primitive generation.
public final class Runtime<State> {
    public typealias ViewFn = (State, inout Cx<State>) -> El<State>
    public typealias KeyHandlerFn = (inout State, KeyEvent, inout Tx) -> Bool

    private struct FlatNode {
        var index: Int
        var parentIndex: Int?
        var path: String
        var key: String?
        var nodeId: NodeId
        var el: El<State>
        var targetRect: MotionRect
        var zoomedTargetRect: MotionRect
        var contentSize: Vec2
        var clipRect: MotionRect
        var effectiveInert: Bool
        var zOrder: Int
        var inheritedScale: Float = 1.0
        var anchorAttachNorm: Vec2? = nil
        var activeClipFades: [EdgeFadeSpec] = []
    }

    private struct WalkItem {
        var el: El<State>
        var solved: LayoutEngine.ResultNode
        var resolvedKey: String?
        var path: String
        var parentIdx: Int?
        var parentOrigin: Vec2
        var parentScroll: Vec2
        var parentScale: Float
        var scaleChain: [AnchorLayoutHelper.AncestorScaleStep]
        var inheritedClip: MotionRect
        var inheritedInert: Bool
        var inheritedZ: Int
        var inInstantSubtree: Bool
        var inheritedClipFades: [EdgeFadeSpec]
    }

    private struct DragSession {
        var path: String
        var key: String?
        var startWindow: Vec2
        var startLocal: Vec2
        var startElementOrigin: Vec2
        var elementSize: Vec2
        var clicks: Int
        var button: PointerButton
        var isTextSelectionDrag: Bool
        var stateSnapshotBeforeDrag: State
    }

    private struct EmitStepInput {
        let p: Presented
        let ancestorOpacity: Float
        let ancestorTurn: Turn?
        let outerTurnClip: MotionRect?
        let localTurnClip: MotionRect?
        let parentPath: String?
        let nearestGroupHovered: Bool
        let flightCover: FlightCoverTransform?
        let flightClipOverride: MotionRect?
        let emitLiftedNow: Bool
    }

    private struct EmitNodeExit {
        let layerEndCount: Int
        let devClip: SIMD4<Float>
    }

    private enum EmitWorkItem {
        case enter(EmitStepInput)
        case exit(EmitNodeExit)
    }

    private struct ImageAtlasPacker {
        var atlas = RGBA8Atlas(width: 64, height: 64)
        var shelfX: Int = 1
        var shelfY: Int = 1
        var shelfH: Int = 0
        var cache: [Int: SIMD4<Float>] = [:]

        mutating func insert(_ img: RGBA8Atlas) -> SIMD4<Float> {
            var hasher = Hasher()
            hasher.combine(img.width)
            hasher.combine(img.height)
            if img.texels.count <= 256 {
                hasher.combine(img.texels)
            } else {
                hasher.combine(img.texels.prefix(128))
                hasher.combine(img.texels.suffix(128))
            }
            let h = hasher.finalize()
            if let uv = cache[h] { return uv }

            let bw = img.width
            let bh = img.height
            if bw + 2 > atlas.width || shelfY + bh + 2 > atlas.height {
                let newW = max(atlas.width * 2, bw + 4)
                let newH = max(atlas.height * 2, shelfY + bh + 4)
                var grown = RGBA8Atlas(width: newW, height: newH)
                for r in 0..<atlas.height {
                    let srcOff = r * atlas.width * 4
                    let dstOff = r * newW * 4
                    grown.texels.replaceSubrange(dstOff..<(dstOff + atlas.width * 4), with: atlas.texels[srcOff..<(srcOff + atlas.width * 4)])
                }
                let rx = Float(atlas.width) / Float(newW)
                let ry = Float(atlas.height) / Float(newH)
                for (k, var v) in cache {
                    v.x *= rx; v.z *= rx
                    v.y *= ry; v.w *= ry
                    cache[k] = v
                }
                atlas = grown
            }
            if shelfX + bw + 1 >= atlas.width {
                shelfX = 1
                shelfY += shelfH + 1
                shelfH = 0
            }
            if shelfY + bh + 1 >= atlas.height {
                return insert(img)
            }
            for r in 0..<bh {
                let srcOff = r * bw * 4
                let dstOff = ((shelfY + r) * atlas.width + shelfX) * 4
                atlas.texels.replaceSubrange(dstOff..<(dstOff + bw * 4), with: img.texels[srcOff..<(srcOff + bw * 4)])
            }
            let uv = SIMD4<Float>(
                Float(shelfX) / Float(atlas.width),
                Float(shelfY) / Float(atlas.height),
                Float(shelfX + bw) / Float(atlas.width),
                Float(shelfY + bh) / Float(atlas.height)
            )
            shelfX += bw + 1
            shelfH = max(shelfH, bh)
            cache[h] = uv
            return uv
        }
    }

    public var state: State
    public var view: ViewFn
    public var globalOnKey: KeyHandlerFn?

    public var viewport: Vec2 {
        didSet {
            if !cxSettings.isApplyingZoom {
                cxSettings.zoomState.window = viewport
            }
            if viewport != oldValue {
                needsCommit = true
            }
        }
    }
    public var pixelScale: Float {
        didSet {
            if !cxSettings.isApplyingZoom {
                cxSettings.zoomState.windowScale = max(pixelScale, 0.5)
            }
            scene.pixelScale = pixelScale
            if pixelScale != oldValue {
                needsCommit = true
            }
        }
    }
    public var systemDark: Bool {
        didSet {
            if systemDark != oldValue { needsCommit = true }
        }
    }
    public var reducedMotion: Bool {
        didSet {
            scene.reducedMotion = reducedMotion
            scrollStore.reducedMotion = reducedMotion
            liveStore.reducedMotion = reducedMotion
            if reducedMotion != oldValue { needsCommit = true }
        }
    }
    public var srgbBlend: Bool = true
    public var windowFocused: Bool = true {
        didSet {
            if windowFocused != oldValue { needsCommit = true }
        }
    }
    public var clearColor: Color = Color(r: 0, g: 0, b: 0, a: 1)

    public let textSystem: TextSystem
    public let waker: Waker
    public private(set) var scene: Scene
    private var scrollStore: AnimationStore
    private var liveStore: AnimationStore

    public internal(set) var currentTime: Double = 0.0
    public private(set) var isAnimating: Bool = false
    public private(set) var surfaces: [SurfaceDraw] = []
    private var videoSignature: UInt64 = 0
    private var lastVideoSnapshots: [String: VideoSnapshot] = [:]
    public private(set) var viewCommitCount: Int = 0
    public private(set) var keyWarnings: [String] = []
    public var windowTitle: String? = nil
    public private(set) var quitRequested: Bool = false
    public var fontSmoothing: FontSmoothing = .systemDefault
    public var tabVisitsControls: Bool = false
    public var poll: ((inout State, Double, inout Tx) -> Bool)? = nil
    public var onFocus: ((inout State, Bool, inout Tx) -> Void)? = nil
    public var onModifiers: ((inout State, Mods, inout Tx) -> Void)? = nil
    public var onVisibility: ((inout State, Bool, inout Tx) -> Void)? = nil
    public var onIme: ((inout State, Ime, inout Tx) -> Bool)? = nil
    public var onClose: ((inout State, inout Tx) -> Bool)? = nil
    public var onQuit: ((inout State, inout Tx) -> Void)? = nil
    public var turnScope: ((inout State, (inout State) -> Void) -> Void)? = nil
    public var onReopen: ((inout State, Bool, inout Tx) -> Bool)? = nil
    public var onOpenUrl: ((inout State, String, inout Tx) -> Void)? = nil
    public private(set) var closeWindowRequested: Bool = false
    public private(set) var minimizeRequested: Bool = false
    public private(set) var relaunchRequested: Bool = false
    public private(set) var nextWakeDeadline: Double? = nil
    public var helpDelay: Double = 0.5
    public var nativeHelp: Bool = false
    public var clipboard = ClipboardContent("")
    public var richClipboard = RichClipboardPayload()
    public let fileDropState = FileDropState()
    public var onFileDrop: ((inout State, FileDropPhase, inout Tx) -> Void)? = nil
    public var onAppFileDrop: ((inout State, [URL], inout Tx) -> Void)? = nil
    public var nativeOverlay: Bool = false
    public let urlOpener = UrlOpener(headless: true)
    public let flightRecorder = FlightRecorder()
    public let matchedFlightRegistry = MatchedFlightRegistry()
    public var rewindRecorder: RewindRecorder? = nil
    public let memo = MemoCache()
    internal var cxSettings = RuntimeShellSettings()
    public var playgroundHost: PlaygroundHost<State>? = nil
    public private(set) var playgroundRequests: [PlaygroundTxRequest] = []

    internal var popupQueue: PopupQueueState = .closed
    internal var popupNeedsLayout: Bool = false
    internal var runtimeFileDialogState: RuntimeFileDialogState = .closed
    internal var nextFileDialogId: UInt64 = 1
    internal var pendingFileDialogAnswers: [((inout Any, FileDialogResult, inout Tx) -> Void, FileDialogResult)] = []
    internal var dropHoverPath: String? = nil
    internal var dropHoverKey: String? = nil
    internal var dropHoverAccepted: Bool = false
    internal var activeDropHoverEnd: ((inout State, inout Tx) -> Void)? = nil
    internal var draggedFiles: [URL]? = nil
    internal var draggedFilesPoint: Vec2? = nil
    internal var filesHeld: Bool = false
    internal var pendingDropMovePoint: Vec2? = nil
    internal var lastEmittedDropMovePoint: Vec2? = nil
    internal var armedDragOut: (path: String, key: String?, startWindow: Vec2, bounds: MotionRect, threshold: Float)? = nil
    internal var activeDragOut: (path: String, key: String?, onEnd: ((inout State, DragOutcome, inout Tx) -> Void)?)? = nil
    internal var pendingDragOutStart: DragOutStart? = nil

    public var hasPendingInput: Bool {
        !pendingFileDialogAnswers.isEmpty || pendingDropMovePoint != nil || !popupQueue.isEmpty
    }

    // Input & focus state
    public private(set) var pointerPosition: Vec2 = Vec2(-10000, -10000)
    public private(set) var hoveredPath: String? = nil
    public private(set) var hoveredKey: String? = nil
    public private(set) var pressedPath: String? = nil
    public private(set) var pressedKey: String? = nil
    public private(set) var focusedPath: String? = nil
    public private(set) var focusedKey: String? = nil
    public private(set) var focusVisible: Bool = false
    private var webFocusTabStartPath: String? = nil

    private var lastClickTime: Double = -10.0
    private var lastClickPos: Vec2 = Vec2(-10000, -10000)
    private var clickCount: Int = 0
    private var activeDrag: DragSession? = nil

    // Scroll state keyed by element path
    private var scrollOffsets: [String: Vec2] = [:]
    private var scrollMaxExtents: [String: Vec2] = [:]
    private var scrollViewportSizes: [String: Vec2] = [:]
    private var scrollContentSizes: [String: Vec2] = [:]
    private var wasPinnedToBottom: Set<String> = []
    private var autofocusAppliedPaths: Set<String> = []
    private var loopRuntime = LoopRuntime()
    private var enterDelays: [NodeId: Double] = [:]
    private var releasedEnterDelays: Set<NodeId> = []
    private struct MatchedSeenSnapshot {
        var id: NodeId
        var path: String
        var rect: MotionRect
        var corners: Corners
        var fill: MotionColor?
        var opacity: Float
    }
    private var seenMatchedByFlightId: [String: MatchedSeenSnapshot] = [:]
    private var committedMatchedByFlightId: [String: MatchedSeenSnapshot] = [:]
    private var activeFlightIds: Set<NodeId> = []
    private struct FocusReturnEntry {
        var ownerPath: String
        var returnPath: String?
        var returnKey: String?
        var prevFocusVisible: Bool
    }
    private var focusReturnStack: [FocusReturnEntry] = []
    private var syncedEditFocusedPaths: Set<String> = []
    private var pendingTxFocusKey: String? = nil
    private var pendingTxBlurRequested: Bool = false
    private var modalMemberPaths: Set<String> = []
    private var activeModalPath: String? = nil
    private var viewHelpLook: HelpLook? = nil
    private var helpState = HelpRuntimeState()

    // Live property tracking `(path, target) -> lastSeenSequence`
    private struct LiveKey: Hashable {
        var path: String
        var target: BoundLiveProperty.Target
    }
    private var liveSeenSeq: [LiveKey: UInt64] = [:]
    private var liveTweenStart: [ObjectIdentifier: Double] = [:]
    private var livePulseRelease: [LiveKey: (releaseAt: Double, rest: MotionLanes, spring: Spring)] = [:]
    private var liveTextSeenSeq: [String: UInt64] = [:]

    private var flatNodes: [FlatNode] = []
    private var nodeByPath: [String: Int] = [:]
    private var nodeById: [NodeId: FlatNode] = [:]
    private var exitingSnapshots: [NodeId: FlatNode] = [:]
    private var lastElements: [ElementInfo] = []
    private var presentedRectByPath: [String: MotionRect] = [:]
    private var presentedScaleByPath: [String: Vec2] = [:]
    private var hitGeometryByPath: [String: HitGeometry] = [:]
    private var paintOrderPaths: [String] = []
    private var imagePacker = ImageAtlasPacker()
    private var retainedLayout = RetainedLayoutCoordinator()
    internal var needsCommit: Bool = true
    private var forceInitialSettle: Bool = true
    private var pendingEventTime: Double? = nil

    public init(
        state: State,
        viewport: Vec2 = Vec2(800, 600),
        pixelScale: Float = 2.0,
        systemDark: Bool = true,
        reducedMotion: Bool = false,
        textSystem: TextSystem = TextSystem(),
        waker: Waker = Waker(),
        onKey: KeyHandlerFn? = nil,
        view: @escaping ViewFn
    ) {
        self.state = state
        self.view = view
        self.globalOnKey = onKey
        self.viewport = viewport
        self.pixelScale = max(pixelScale, 0.5)
        self.systemDark = systemDark
        self.reducedMotion = reducedMotion
        self.textSystem = textSystem
        self.waker = waker
        self.scene = Scene(pixelScale: pixelScale, reducedMotion: reducedMotion)
        self.scrollStore = AnimationStore(pixelScale: pixelScale, reducedMotion: reducedMotion)
        self.liveStore = AnimationStore(pixelScale: pixelScale, reducedMotion: reducedMotion)
        self.cxSettings = RuntimeShellSettings(viewport: viewport, pixelScale: pixelScale, reducedMotion: reducedMotion)
        if !MediaPlaybackGate.isEnabled {
            Recorder.headlessReset()
            VideoHeadless.reset()
            HeadlessClock.set(0.0)
        }
    }

    public func elements() -> [ElementInfo] {
        lastElements
    }

    public func element(byKey key: String) -> ElementInfo? {
        if let active = lastElements.first(where: { !$0.exiting && selectsElementSelector(key, path: $0.path, key: $0.key) }) {
            return active
        }
        return lastElements.first { selectsElementSelector(key, path: $0.path, key: $0.key) }
    }

    /// Whether an element path contains secure text, hidden or revealed.
    /// Unknown paths return `false`. Matches `crates/rune/src/runtime/elements.rs:189`.
    public func elementIsSecure(_ path: String) -> Bool {
        if let idx = nodeByPath[path] {
            let el = flatNodes[idx].el
            if el.isSecure { return true }
            if let editLens = el.handlers.editLens {
                return editLens.get(state).isSecure
            }
            return false
        }
        return lastElements.first(where: { $0.path == path })?.secure ?? false
    }

    /// Centre of the first non-exiting element matching `key` (or slash-path like `"slider/knob"`),
    /// in logical window points. Matches `crates/rune/src/runtime/elements.rs:389`.
    public func find(_ key: String) -> Vec2? {
        guard let el = lastElements.first(where: { !$0.exiting && selectsElementSelector(key, path: $0.path, key: $0.key) }),
              el.rect.count >= 4 else {
            return nil
        }
        return Vec2(el.rect[0] + el.rect[2] * 0.5, el.rect[1] + el.rect[3] * 0.5)
    }

    /// Topmost element drawn at window point `(x, y)` (skipping exiting and opacity-0 elements).
    public func elementAt(_ x: Float, _ y: Float) -> Picked? {
        elementAtWith(x, y, pick: .default)
    }

    /// Topmost element drawn at window point `(x, y)` with `Pick` options.
    public func elementAtWith(_ x: Float, _ y: Float, pick: Pick) -> Picked? {
        elementAtWithin(nil, x: x, y: y, pick: pick)
    }

    /// Topmost element drawn at window point `(x, y)` restricted to `within` and its descendants.
    public func elementAtIn(_ within: String, x: Float, y: Float) -> Picked? {
        elementAtInWith(within, x: x, y: y, pick: .default)
    }

    /// Topmost element drawn at window point `(x, y)` restricted to `within` and its descendants, with `Pick` options.
    public func elementAtInWith(_ within: String, x: Float, y: Float, pick: Pick) -> Picked? {
        elementAtWithin(within, x: x, y: y, pick: pick)
    }

    private func elementAtWithin(_ within: String?, x: Float, y: Float, pick: Pick) -> Picked? {
        let scopePath: String?
        if let within {
            guard let found = lastElements.first(where: { selectsElementSelector(within, path: $0.path, key: $0.key) }) else {
                return nil
            }
            scopePath = found.path
        } else {
            scopePath = nil
        }

        let pt = Vec2(x, y)
        for path in paintOrderPaths.reversed() {
            if let scopePath, !(path == scopePath || path.hasPrefix(scopePath + "/")) {
                continue
            }
            guard let geom = hitGeometryByPath[path],
                  !geom.isExiting,
                  (pick.includeTransparent || geom.opacity > 0.001),
                  geom.contains(pt) else {
                continue
            }
            let key = nodeByPath[path].flatMap { flatNodes[$0].key }
                ?? lastElements.first(where: { $0.path == path })?.key
            return Picked(path: path, key: key)
        }
        return nil
    }

    /// Whether window point `(x, y)` lies inside the drawn, clipped, and turned box of the element matching `key`.
    public func contains(_ key: String, x: Float, y: Float) -> Bool {
        containsWith(key, x: x, y: y, pick: .default)
    }

    /// `contains(_:x:y:)` with `Pick` options.
    public func containsWith(_ key: String, x: Float, y: Float, pick: Pick) -> Bool {
        guard let el = lastElements.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) }),
              let geom = hitGeometryByPath[el.path],
              !geom.isExiting,
              (pick.includeTransparent || geom.opacity > 0.001) else {
            return false
        }
        return geom.contains(Vec2(x, y))
    }

    public func markNeedsCommit(settle: Bool = false) {
        needsCommit = true
        pendingEventTime = nil
        if settle {
            forceInitialSettle = true
        }
    }

    /// Whether a layout/view re-evaluation commit is currently pending.
    public var hasPendingCommit: Bool { needsCommit }

    /// Presented hit-test boxes (in logical points) for non-inert `.hit()` elements, used by `OverlayInput.regions`.
    public func overlayInteractiveRegions() -> [MotionRect] {
        var regions: [MotionRect] = []
        for node in flatNodes {
            if node.effectiveInert || !node.el.isHit { continue }
            let infoRect = presentedRectByPath[node.path] ?? node.targetRect
            let hitBox = intersectRects(node.clipRect, infoRect)
            if hitBox.width > 0 && hitBox.height > 0 {
                regions.append(hitBox)
            }
        }
        return regions
    }

    /// True when the primary hit target at `point` is a bare `.windowDrag()` region with no
    /// interactive press/double-press/drag/dragOut/textbox behavior (`titlebar::bare_drag_region`).
    public func isBareTitlebarDragRegion(at point: Vec2) -> Bool {
        guard let hit = hitTest(at: point) else { return false }
        let node = hit.node
        guard node.el.isWindowDrag else { return false }
        let h = node.el.handlers
        return h.onClick == nil &&
            h.onClickPress == nil &&
            h.onDoubleClick == nil &&
            h.onSecondaryClick == nil &&
            h.onPointerDown == nil &&
            h.onDrag == nil &&
            h.editLens == nil &&
            node.el.runtimeExtras["dragOut"] == nil &&
            node.el.role != .textInput
    }

    /// Earliest future wall-clock timestamp when an active `enterDelay`, tooltip wait, or `looping`/`cycle` animation needs a frame.
    public func nextWakeDeadline(after now: Double) -> Double? {
        var best: Double? = nil
        for readyAt in enterDelays.values where readyAt > now {
            best = best.map { min($0, readyAt) } ?? readyAt
        }
        if case .waiting(_, let since) = helpState.tipState {
            let due = since + currentHelpDelays().open
            if due > now {
                best = best.map { min($0, due) } ?? due
            }
        }
        if let loopInterval = loopRuntime.nextFrameInterval(reducedMotion: reducedMotion) {
            let t = now + loopInterval
            best = best.map { min($0, t) } ?? t
        }
        return best
    }

    @inline(__always)
    internal func dirtyCommit(at now: Double) {
        needsCommit = true
        pendingEventTime = now
    }

    /// Evaluates view + layout (if dirty), steps `Scene` & `Live` animations at `now`,
    /// updates `elements()`, and emits the complete `RefScene` primitive stream!
    @discardableResult
    public func frame(at now: Double) -> RefScene {
        Theme.withBlend(srgbBlend) {
            frameWithBlendScope(at: now)
        }
    }

    private func frameWithBlendScope(at now: Double) -> RefScene {
        currentTime = now
        if !MediaPlaybackGate.isEnabled {
            HeadlessClock.set(now)
            Recorder.headlessFrame(clock: now)
            VideoHeadless.frame(at: now)
        }
        scrollStore.pixelScale = pixelScale
        liveStore.pixelScale = pixelScale
        _ = runPoll(at: now)
        flushPlatformFrameWork(at: now)

        // Release any `enterDelay` elements whose wait window has elapsed
        var releasedAny = false
        for (nid, readyAt) in enterDelays where now >= readyAt {
            enterDelays.removeValue(forKey: nid)
            releasedEnterDelays.insert(nid)
            releasedAny = true
        }
        if releasedAny && !needsCommit {
            commitTree(at: now, cut: false)
        }

        // Check if any `LiveText` changed; if a fixed-box LiveText changed we refresh its text without full commit if possible
        for (_, idx) in nodeByPath {
            if idx < flatNodes.count, let lt = flatNodes[idx].el.liveText {
                let seq = lt.sequence
                if liveTextSeenSeq[flatNodes[idx].path] != seq {
                    liveTextSeenSeq[flatNodes[idx].path] = seq
                    flatNodes[idx].el.plainText = lt.get()
                }
            }
        }

        if needsCommit {
            let commitAt = min(pendingEventTime ?? now, now)
            pendingEventTime = nil
            commitTree(at: commitAt, cut: forceInitialSettle)
            needsCommit = false
            popupNeedsLayout = false
            forceInitialSettle = false
            reconcileDropHoverAfterCommit(at: now)
            if needsCommit {
                commitTree(at: now, cut: false)
                needsCommit = false
                popupNeedsLayout = false
            }
        }

        // Advance scaled animation clock after any initial commit so `cx.timeScale(...)` takes effect on this frame
        let animNow = cxSettings.advanceClock(to: now)

        // Sample inertial scroll decay tracks and re-commit layout positions if scroll is moving
        scrollStore.sample(at: animNow)
        if scrollStore.isAnimating {
            var anyScrollMoved = false
            for (path, maxExt) in scrollMaxExtents {
                let nid = NodeId.hash("scroll:" + path)
                if let cur = scrollStore.get(nid, Props.SCROLL) {
                    let clamped = Vec2(
                        cur.x.clamped(to: 0...maxExt.x),
                        cur.y.clamped(to: 0...maxExt.y)
                    )
                    if scrollOffsets[path] != clamped {
                        scrollOffsets[path] = clamped
                        anyScrollMoved = true
                    }
                    // Stop fling immediately if clamped against boundary
                    if clamped != cur {
                        scrollStore.snap(nid, Props.SCROLL, to: clamped)
                    }
                }
            }
            if anyScrollMoved {
                commitTree(at: now, cut: false)
            }
        }

        // Sample Scene & Live property bindings using scaled animation clock
        let frameOut = scene.frame(at: animNow)
        let liveActive = updateLiveBindings(at: animNow)
        liveStore.sample(at: animNow)

        let rawAnimating = frameOut.isAnimating
            || scrollStore.isAnimating
            || liveStore.isAnimating
            || liveActive
            || !enterDelays.isEmpty
            || tooltipFading(at: now)
            || loopRuntime.hasActiveLoops(at: now, reducedMotion: reducedMotion)
        isAnimating = rawAnimating && cxSettings.viewTimeScale > 0.0

        // Prune snapshots of exiting nodes that have finished exiting
        let activeIds = Set(frameOut.nodes.map(\.id))
        exitingSnapshots = exitingSnapshots.filter { activeIds.contains($0.key) }
        activeFlightIds = activeFlightIds.filter { activeIds.contains($0) && scene.isEdgeAnimating($0) }

        let sceneOut = buildRefScene(frameOut: frameOut, now: animNow)
        if memo.hasInvalidatedReads(against: currentMemoGeometry()) {
            needsCommit = true
        }
        if cxSettings.caretReadByView,
           let nextCaret = currentFocusedCaret(),
           cxSettings.lastCommittedCaret?.keyPath != nextCaret.keyPath || cxSettings.lastCommittedCaret?.rect != nextCaret.rect {
            needsCommit = true
        }
        if rewindRecorder != nil {
            captureRewindFrame(at: now)
        }
        return sceneOut
    }

    // MARK: - View Commit, Reconciliation & Layout

    private func currentMemoGeometry() -> [String: MemoElementGeometry] {
        var caretsByKey: [String: MotionRect] = [:]
        for el in lastElements {
            if let k = el.key, let c = el.caret, c.count >= 4 {
                caretsByKey[k] = MotionRect.fromXYWH(c[0], c[1], c[2], c[3])
            }
        }
        var out: [String: MemoElementGeometry] = [:]
        out.reserveCapacity(flatNodes.count)
        for node in flatNodes {
            if let k = node.key {
                out[k] = MemoElementGeometry(
                    rect: node.targetRect,
                    windowRect: node.targetRect,
                    caretRect: caretsByKey[k]
                )
            }
        }
        return out
    }

    private func commitTree(at now: Double, cut: Bool) {
        if cut {
            enterDelays.removeAll()
            releasedEnterDelays.removeAll()
            activeFlightIds.removeAll()
        }
        let sincePass = memo.nextPass()
        MemoSnapshot.enter {
            commitTreePass(at: now, cut: cut, settlePass: 0)
        }
        memo.keepSince(sincePass)
    }

    private func currentFocusedCaret() -> (keyPath: String, rect: [Float])? {
        if let fk = focusedKey, let el = lastElements.first(where: { $0.key == fk }), let c = el.caret {
            return (el.path, c)
        }
        if let fp = focusedPath, let el = lastElements.first(where: { $0.path == fp }), let c = el.caret {
            return (el.path, c)
        }
        return nil
    }

    private func commitTreePass(at now: Double, cut: Bool, settlePass: Int) {
        viewCommitCount += 1
        if settlePass == 0 {
            CommitGenerationStore.increment()
        }
        let focusedCaret = currentFocusedCaret()
        cxSettings.lastCommittedCaret = focusedCaret
        var cx = Cx<State>(
            viewport: viewport,
            pixelScale: pixelScale,
            systemDark: systemDark,
            reducedMotion: cxSettings.hostReducedMotion,
            windowFocused: windowFocused,
            focusedKey: focusedKey,
            hoveredKey: hoveredKey,
            pressedKey: pressedKey,
            waker: waker,
            scrollLookup: { [weak self] key in
                guard let self else { return .zero }
                if let match = self.flatNodes.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) }) {
                    return self.scrollOffsets[match.path] ?? .zero
                }
                return .zero
            },
            scrollMaxLookup: { [weak self] key in
                guard let self else { return .zero }
                if let match = self.flatNodes.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) }) {
                    return self.scrollMaxExtents[match.path] ?? .zero
                }
                return .zero
            },
            viewportSizeLookup: { [weak self] key in
                guard let self else { return .zero }
                if let match = self.flatNodes.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) }) {
                    return self.scrollViewportSizes[match.path] ?? Vec2(match.targetRect.width, match.targetRect.height)
                }
                return .zero
            },
            contentSizeLookup: { [weak self] key in
                guard let self else { return .zero }
                if let match = self.flatNodes.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) }) {
                    return self.scrollContentSizes[match.path] ?? match.contentSize
                }
                return .zero
            },
            layoutRectLookup: { [weak self] key in
                guard let self else { return nil }
                return self.flatNodes.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) })?.targetRect
            }
        )
        cx.envState.titlebarInset = cxSettings.titlebarInset / cxSettings.zoomState.k
        cx.envState.chrome = chromeInsets()
        cx.envState.systemAccent = cxSettings.systemAccent
        cx.envState.systemContrast = cxSettings.systemContrast
        cx.envState.systemScrollBars = cxSettings.scrollBarsState
        cx.envState.systemReducedMotion = cxSettings.hostReducedMotion
        cx.envState.zoom = 1.0
        cx.envState.caret = focusedCaret
        let envHash = MemoScope.environmentHash(
            systemDark: systemDark,
            pixelScale: pixelScale,
            reducedMotion: cxSettings.hostReducedMotion,
            srgbBlend: srgbBlend,
            accent: cx.accent(),
            focusColor: cx.focusColor(),
            chromeInsets: [cx.envState.chrome.leading, cx.envState.chrome.trailing, cx.envState.chrome.top, cxSettings.scrollBarsState.bars.hashValue.signum() == 0 ? 0 : Float(cxSettings.scrollBarsState.isOverlay ? 1 : 2)]
        )
        let rootEl = SystemScrollBarsScope.$current.withValue(cxSettings.scrollBarsState) {
            MemoScope.enter(
                cache: memo,
                envHash: envHash,
                geometry: currentMemoGeometry()
            ) {
                view(state, &cx)
            }
        }
        cxSettings.viewDefaults = cx.envState.defaults
        viewHelpLook = cx.helpLook ?? cx.envState.defaults.help
        cxSettings.captionColor = cx.envState.captionColor
        cxSettings.titlebarOverride = cx.envState.titlebar
        cxSettings.caretReadByView = cx.envState.reads.caretRead
        let effReducedMotion = cx.envState.reducedMotionOverride ?? cxSettings.hostReducedMotion
        if effReducedMotion != self.reducedMotion {
            self.reducedMotion = effReducedMotion
            self.needsCommit = false
        }
        cxSettings.setTimeScale(cx.envState.timeScale, at: now)
        if cx.envState.zoom != cxSettings.zoomState.k {
            cxSettings.zoomState.k = cx.envState.zoom
            let (zVp, zScale) = cxSettings.zoomState.view()
            cxSettings.isApplyingZoom = true
            viewport = zVp
            pixelScale = zScale
            cxSettings.isApplyingZoom = false
            needsCommit = false
            if settlePass == 0 {
                commitTreePass(at: now, cut: cut, settlePass: 1)
                return
            }
        }
        viewHelpLook = cx.helpLook
        if rootEl.background.a >= 0.999 {
            clearColor = rootEl.background
        }

        let solvedRoot = retainedLayout.compute(
            root: rootEl,
            state: state,
            viewport: viewport,
            pixelScale: pixelScale,
            textSystem: textSystem
        )

        // Flatten tree, assign unique structural/keyed paths, clamp scroll offsets, and collect NodeSpecs
        var newFlat: [FlatNode] = []
        var newByPath: [String: Int] = [:]
        var newById: [NodeId: FlatNode] = [:]
        var specs: [NodeSpec] = []
        var loopSpecs: [(id: NodeId, spec: LoopSpec)] = []
        var warnings: [String] = []
        let prevMountedIds = Set(nodeById.keys)

        let fullWindowClip = MotionRect.fromXYWH(0, 0, viewport.x, viewport.y)

        let rootResolvedKey: String? = rootEl.keyId
        let rootPath: String = rootResolvedKey.map { "/@\($0)" } ?? "/0"
        var walkStack: [WalkItem] = [
            WalkItem(
                el: rootEl,
                solved: solvedRoot,
                resolvedKey: rootResolvedKey,
                path: rootPath,
                parentIdx: nil,
                parentOrigin: .zero,
                parentScroll: .zero,
                parentScale: 1.0,
                scaleChain: [],
                inheritedClip: fullWindowClip,
                inheritedInert: false,
                inheritedZ: 0,
                inInstantSubtree: false,
                inheritedClipFades: []
            )
        ]

        while let item = walkStack.popLast() {
            let el = item.el
            let solved = item.solved
            let resolvedKey = item.resolvedKey
            let path = item.path
            let parentIdx = item.parentIdx
            let parentOrigin = item.parentOrigin
            let parentScroll = item.parentScroll
            let parentScale = item.parentScale
            let scaleChain = item.scaleChain
            let inheritedClip = item.inheritedClip
            let inheritedInert = item.inheritedInert
            let inheritedZ = item.inheritedZ
            let inInstantSubtree = item.inInstantSubtree
            let inheritedClipFades = item.inheritedClipFades

            let nid: NodeId
            if el.layoutAnim?.travel == .screen, let rk = resolvedKey {
                nid = NodeId.hash("screen:@" + rk)
            } else {
                nid = NodeId.hash(path)
            }

            let localRect = solved.layout.localRect
            var worldX = parentOrigin.x + localRect.x - parentScroll.x
            var worldY = parentOrigin.y + localRect.y - parentScroll.y
            var anchorScaleFactor: Float = 1.0
            var anchorAttachNorm: Vec2? = nil

            if let a = el.anchor,
               let anchorFlat = newFlat.first(where: { $0.key == a.key }) {
                let placement = AnchorLayoutHelper.zoomedPlacement(
                    anchor: a,
                    triggerZoomed: anchorFlat.zoomedTargetRect,
                    anchorScale: anchorFlat.inheritedScale,
                    localSize: Vec2(localRect.width, localRect.height),
                    overlayOwnScale: el.scale,
                    viewport: viewport
                )
                worldX = placement.unscaledOrigin.x
                worldY = placement.unscaledOrigin.y
                anchorScaleFactor = placement.zoom
                if abs(placement.zoom - 1.0) > 1e-5 {
                    anchorAttachNorm = placement.attachNorm
                }
            }

            // Apply sticky pinning inside scroll viewport if `.stickyTop` / `.stickyBottom` is set
            if let sticky = el.layout.sticky {
                switch sticky {
                case .top(let pinOffset):
                    let minTop = inheritedClip.top + pinOffset
                    if worldY < minTop { worldY = minTop }
                case .bottom(let pinOffset):
                    let maxBottom = inheritedClip.bottom - pinOffset
                    if worldY + localRect.height > maxBottom {
                        worldY = maxBottom - localRect.height
                    }
                }
            }

            let targetRect = MotionRect.fromXYWH(worldX, worldY, localRect.width, localRect.height)
            let zoomedTargetRect = AnchorLayoutHelper.zoomedRect(targetRect, chain: scaleChain)
            let nodeInheritedScale = (el.anchor == nil ? parentScale : anchorScaleFactor) * el.scale.x
            let childScaleChain = scaleChain + [
                AnchorLayoutHelper.AncestorScaleStep(
                    rect: targetRect,
                    scale: (el.anchor != nil) ? nodeInheritedScale : el.scale.x,
                    origin: (el.anchor != nil) ? .zero : el.origin,
                    resetsAncestors: el.anchor != nil
                )
            ]

            // Update scroll bounds for scrollable containers
            var ownScroll = Vec2.zero
            var scrollFadeInfo: EdgeFadeSpec? = nil
            if !el.layout.scrollAxes.isEmpty {
                scrollViewportSizes[path] = Vec2(targetRect.width, targetRect.height)
                scrollContentSizes[path] = solved.layout.contentSize
                let maxSX = el.layout.scrollAxes.contains(.horizontal)
                    ? max(0, solved.layout.contentSize.x - targetRect.width)
                    : 0
                let maxSY = el.layout.scrollAxes.contains(.vertical)
                    ? max(0, solved.layout.contentSize.y - targetRect.height)
                    : 0
                let oldMax = scrollMaxExtents[path] ?? .zero
                scrollMaxExtents[path] = Vec2(maxSX, maxSY)

                var curScroll = scrollOffsets[path] ?? .zero
                if el.layout.stickBottom {
                    let firstMount = !wasPinnedToBottom.contains(path) && scrollOffsets[path] == nil
                    let wasAtBottom = firstMount || wasPinnedToBottom.contains(path) || (oldMax.y - curScroll.y <= 2.0)
                    if wasAtBottom && maxSY >= oldMax.y {
                        curScroll.y = maxSY
                        wasPinnedToBottom.insert(path)
                    }
                }
                curScroll = Vec2(
                    curScroll.x.clamped(to: 0...maxSX),
                    curScroll.y.clamped(to: 0...maxSY)
                )
                scrollOffsets[path] = curScroll
                ownScroll = curScroll

                if el.scrollEdgeFadeWidth > 0 {
                    let w = el.scrollEdgeFadeWidth
                    let hidTop = curScroll.y
                    let hidBot = max(0, maxSY - curScroll.y)
                    let hidLeft = curScroll.x
                    let hidRight = max(0, maxSX - curScroll.x)
                    let topW: Float = (el.layout.scrollAxes.contains(.vertical) && hidTop > 0.5) ? w : 0
                    let botW: Float = (el.layout.scrollAxes.contains(.vertical) && hidBot > 0.5) ? w : 0
                    let leftW: Float = (el.layout.scrollAxes.contains(.horizontal) && hidLeft > 0.5) ? w : 0
                    let rightW: Float = (el.layout.scrollAxes.contains(.horizontal) && hidRight > 0.5) ? w : 0
                    if topW > 0 || botW > 0 || leftW > 0 || rightW > 0 {
                        let sTop = min(1.0, hidTop / 15.0)
                        let sBot = min(1.0, hidBot / 15.0)
                        let sLeft = min(1.0, hidLeft / 15.0)
                        let sRight = min(1.0, hidRight / 15.0)
                        scrollFadeInfo = EdgeFadeSpec(
                            rect: intersectRects(inheritedClip, targetRect),
                            widths: SIMD4<Float>(leftW, topW, rightW, botW),
                            strengths: SIMD4<Float>(sLeft, sTop, sRight, sBot)
                        )
                    }
                }
            }

            let ownZ = el.zIndex != 0 ? el.zIndex : inheritedZ
            let effectiveInert = inheritedInert || el.isInert

            // Children clip against this node if `clipOverflow`, `clipRadius`, `clipCorners`, or `clipFade` is set
            let childClip: MotionRect
            if el.layout.clipOverflow || el.clipRadius != nil || el.clipCorners != nil || el.clipFade != nil {
                childClip = intersectRects(inheritedClip, targetRect)
            } else {
                childClip = inheritedClip
            }

            var childClipFades = inheritedClipFades
            if let sf = scrollFadeInfo {
                childClipFades.append(sf)
            }
            if let cf = el.clipFade {
                childClipFades.append(
                    EdgeFadeSpec(
                        rect: intersectRects(inheritedClip, targetRect),
                        widths: cf,
                        strengths: SIMD4<Float>(repeating: 1.0)
                    )
                )
            }

            let myIndex = newFlat.count
            let flat = FlatNode(
                index: myIndex,
                parentIndex: parentIdx,
                path: path,
                key: resolvedKey,
                nodeId: nid,
                el: el,
                targetRect: targetRect,
                zoomedTargetRect: zoomedTargetRect,
                contentSize: solved.layout.contentSize,
                clipRect: inheritedClip,
                effectiveInert: effectiveInert,
                zOrder: ownZ,
                inheritedScale: nodeInheritedScale,
                anchorAttachNorm: anchorAttachNorm,
                activeClipFades: inheritedClipFades
            )
            newFlat.append(flat)
            newByPath[path] = myIndex
            newById[nid] = flat
            exitingSnapshots[nid] = flat

            // Subscribe any Live / LiveText handles to our runtime waker
            if let lt = el.liveText {
                lt.subscribe(waker)
                liveTextSeenSeq[path] = lt.sequence
            }
            for b in el.liveBindings {
                b.source.subscribe(waker)
            }

            // Compute interactive hover / press / pressScale adjustments on target spec
            let isHovered = (hoveredPath == path) && !effectiveInert
            let isPressed = (pressedPath == path) && !effectiveInert

            var effectiveFill = el.background
            if isPressed, let pBg = el.pressBg {
                effectiveFill = blendColorOver(bottom: effectiveFill, top: pBg)
            } else if isHovered, let hBg = el.hoverBg {
                effectiveFill = blendColorOver(bottom: effectiveFill, top: hBg)
            }

            var effectiveScale = Vec2(el.scale.x * anchorScaleFactor, el.scale.y * anchorScaleFactor)
            if isPressed, let ps = el.pressScaleFactor {
                effectiveScale = Vec2(effectiveScale.x * ps, effectiveScale.y * ps)
            }

            let ancestorInstant = inInstantSubtree && !el.hasAnimatedChanges
            let childInstant = ancestorInstant || el.hasInstantChanges
            let selfInstantLayoutOrStyle = childInstant

            let parentNid = parentIdx.map { newFlat[$0].nodeId }
            // Provide a subtle default interactive spring when pressScale / hover / press is used
            var styleSp = selfInstantLayoutOrStyle
                ? ((el.hoverBg != nil || el.pressBg != nil) ? MotionTokens.INSTANT : nil)
                : (el.styleSpring ?? ((el.pressScaleFactor != nil || el.hoverBg != nil || el.pressBg != nil) ? MotionTokens.INSTANT : nil))
            var layoutAnimSpec = selfInstantLayoutOrStyle ? nil : el.layoutAnim
            var specTransition = ancestorInstant ? nil : el.transition
            var specRect = targetRect
            var specOpacity = el.opacity
            var specScale = effectiveScale
            var specBlur = el.blur

            let isFreshMount = !prevMountedIds.contains(nid)
            if el.enterDelay > 0 && viewCommitCount > 1 && !cut && !ancestorInstant && isFreshMount && !releasedEnterDelays.contains(nid) && enterDelays[nid] == nil {
                enterDelays[nid] = now + Double(el.enterDelay)
            }
            if let readyAt = enterDelays[nid], now < readyAt {
                let eff = el.transition?.insertion ?? Transition.opacity.insertion
                specOpacity = eff.zeroOpacity ?? 0
                specScale = Vec2(specScale.x * eff.zeroScale.x, specScale.y * eff.zeroScale.y)
                let dx = eff.pointOffset.x + eff.relativeOffset.x * targetRect.width
                let dy = eff.pointOffset.y + eff.relativeOffset.y * targetRect.height
                specRect = targetRect.offsetBy(Vec2(dx, dy))
                specBlur = max(specBlur, eff.zeroBlur)
                specTransition = nil
                layoutAnimSpec = nil
                styleSp = nil
            } else if releasedEnterDelays.remove(nid) != nil {
                let enterSp = el.transition?.insertion.spring ?? el.styleSpring ?? MotionTokens.SETTLE
                styleSp = enterSp
                layoutAnimSpec = el.layoutAnim ?? LayoutAnim(spring: enterSp)
            }

            if let ls = el.loopingSpec {
                loopSpecs.append((id: nid, spec: ls))
            }

            specs.append(NodeSpec(
                id: nid,
                parent: parentNid,
                rect: specRect,
                opacity: specOpacity,
                scale: specScale,
                rotate: el.rotate,
                offset: el.offset,
                corners: el.corners,
                blur: specBlur,
                fill: effectiveFill.motionColor,
                border: el.borderColor.motionColor,
                layoutAnim: layoutAnimSpec,
                styleSpring: styleSp,
                transition: specTransition
            ))

            var childKeysSeen: [String: Int] = [:]
            var childItems: [WalkItem] = []
            childItems.reserveCapacity(min(el.children.count, solved.children.count))
            for (cIdx, childEl) in el.children.enumerated() where cIdx < solved.children.count {
                let childResolvedKey: String?
                let childSegment: String
                if let rawK = childEl.keyId {
                    let count = childKeysSeen[rawK, default: 0]
                    childKeysSeen[rawK] = count + 1
                    if count == 0 {
                        childResolvedKey = rawK
                        childSegment = "@\(rawK)"
                    } else {
                        let dup = "\(rawK)#dup\(count)"
                        childResolvedKey = dup
                        childSegment = "@\(dup)"
                        warnings.append("Duplicate sibling key '\(rawK)' renamed to '\(dup)' under \(path)")
                    }
                } else {
                    childResolvedKey = nil
                    childSegment = "\(cIdx)"
                }
                childItems.append(WalkItem(
                    el: childEl,
                    solved: solved.children[cIdx],
                    resolvedKey: childResolvedKey,
                    path: "\(path)/\(childSegment)",
                    parentIdx: myIndex,
                    parentOrigin: Vec2(worldX, worldY),
                    parentScroll: ownScroll,
                    parentScale: nodeInheritedScale,
                    scaleChain: childScaleChain,
                    inheritedClip: childClip,
                    inheritedInert: effectiveInert,
                    inheritedZ: ownZ,
                    inInstantSubtree: childInstant,
                    inheritedClipFades: childClipFades
                ))
            }
            walkStack.append(contentsOf: childItems.reversed())
        }
        loopRuntime.sync(specs: loopSpecs, at: now, reducedMotion: reducedMotion, cut: cut)
        if cut {
            loopRuntime.settleAll(at: now)
        }

        // Apply modal inertness: if any mounted subtree is `.modal(...)`, elements outside the topmost modal
        // (and its anchored portal popovers) become inert!
        var newModalMembers: Set<String> = []
        var newActiveModalPath: String? = nil
        if let modalRootIdx = newFlat.indices.last(where: { newFlat[$0].el.isModal }) {
            let modalPrefix = newFlat[modalRootIdx].path
            newActiveModalPath = modalPrefix
            var memberIndices = Set<Int>()
            for i in modalRootIdx..<newFlat.count {
                let p = newFlat[i].path
                if p == modalPrefix || p.hasPrefix(modalPrefix + "/") {
                    memberIndices.insert(i)
                }
            }
            var addedAnchored = true
            while addedAnchored {
                addedAnchored = false
                for i in 0..<newFlat.count where !memberIndices.contains(i) {
                    if let ak = newFlat[i].el.anchor?.key,
                       memberIndices.contains(where: { newFlat[$0].key == ak }) {
                        let portalPrefix = newFlat[i].path
                        for j in i..<newFlat.count {
                            let pj = newFlat[j].path
                            if pj == portalPrefix || pj.hasPrefix(portalPrefix + "/") {
                                if memberIndices.insert(j).inserted {
                                    addedAnchored = true
                                }
                            }
                        }
                    }
                }
            }
            for i in memberIndices {
                newModalMembers.insert(newFlat[i].path)
            }
            for i in 0..<newFlat.count where !memberIndices.contains(i) {
                newFlat[i].effectiveInert = true
                let id = newFlat[i].nodeId
                newById[id] = newFlat[i]
                exitingSnapshots[id] = newFlat[i]
            }
        }
        modalMemberPaths = newModalMembers
        activeModalPath = newActiveModalPath

        let prevFocusedPath = focusedPath
        let prevFocusedKey = focusedKey
        let prevFocusVisible = focusVisible

        flatNodes = newFlat
        nodeByPath = newByPath
        nodeById = newById
        if !warnings.isEmpty {
            keyWarnings = warnings
        }

        if settlePass == 0 && memo.hasInvalidatedReads(against: currentMemoGeometry()) {
            commitTreePass(at: now, cut: cut, settlePass: 1)
            return
        }

        // Reconcile focus: keep focused key/path if still focusable & non-inert; sync TextEdit.focused; handle modal/focusReturn & autofocus.
        reconcileFocusAfterCommit(
            prevFocusedPath: prevFocusedPath,
            prevFocusedKey: prevFocusedKey,
            prevFocusVisible: prevFocusVisible
        )

        // Resolve cross-parent matched-geometry (`flightId` / `matched`) flights against last-seen rects.
        var matchedStarts: [NodeId: MatchedFlightStart] = [:]
        var newCommittedMatched: [String: MatchedSeenSnapshot] = [:]
        var matchedRootPaths: [String] = []
        for node in newFlat {
            guard let fid = node.el.flightId else { continue }
            let nid = node.nodeId
            newCommittedMatched[fid] = MatchedSeenSnapshot(
                id: nid,
                path: node.path,
                rect: node.targetRect,
                corners: node.el.corners,
                fill: node.el.background.motionColor,
                opacity: node.el.opacity
            )
            if !cut, !scene.hasNode(nid),
               let prev = seenMatchedByFlightId[fid] ?? committedMatchedByFlightId[fid],
               prev.id != nid {
                matchedStarts[nid] = MatchedFlightStart(
                    fromId: prev.id,
                    startRect: prev.rect,
                    startCorners: prev.corners,
                    startFill: prev.fill,
                    startOpacity: prev.opacity,
                    spring: node.el.flightSpring ?? MotionTokens.SETTLE
                )
                matchedRootPaths.append(node.path)
                activeFlightIds.insert(nid)
            }
        }
        if !matchedRootPaths.isEmpty {
            for i in 0..<specs.count {
                let p = newFlat[i].path
                if matchedRootPaths.contains(where: { p.hasPrefix($0 + "/") }) {
                    specs[i].transition = nil
                }
            }
        }
        committedMatchedByFlightId = newCommittedMatched
        if cut {
            seenMatchedByFlightId = newCommittedMatched
            for (fid, snap) in newCommittedMatched {
                matchedFlightRegistry.recordPrevious(flightId: fid, rect: snap.rect)
            }
        }

        scene.commit(specs, at: cxSettings.scaledTime(at: now), initialCut: cut, matchedStarts: matchedStarts)
    }

    private func nodeTakesFocus(_ el: El<State>) -> Bool {
        if el.focusable { return true }
        let pressableRoles: Set<ElementRole> = [
            .button, .tab, .checkbox, .switchControl, .radio, .menuItem, .listItem,
        ]
        return cxSettings.viewDefaults.webFocus &&
            !el.focusOptOut &&
            (el.handlers.onClick != nil || el.handlers.onClickPress != nil || el.handlers.onPointerDown != nil) &&
            pressableRoles.contains(el.role)
    }

    private func canFocusIndex(_ idx: Int) -> Bool {
        guard idx >= 0 && idx < flatNodes.count else { return false }
        let node = flatNodes[idx]
        guard nodeTakesFocus(node.el) && !node.effectiveInert && !node.el.a11yDisabled else { return false }
        var walk: Int? = idx
        while let cur = walk {
            if flatNodes[cur].el.opacity <= 0.001 || flatNodes[cur].el.isInert {
                return false
            }
            walk = flatNodes[cur].parentIndex
        }
        return true
    }

    private func tabOrderIndices() -> [Int] {
        let all = flatNodes.indices.filter { canFocusIndex($0) && (flatNodes[$0].el.tabIndex ?? 0) >= 0 }
        let collapsed = all.filter { i in
            guard let g = findFocusGroupAncestor(of: i), g != i else { return true }
            let members = all.filter { findFocusGroupAncestor(of: $0) == g && $0 != g }
            let chosen = members.first(where: { flatNodes[$0].path == focusedPath })
                ?? members.first(where: { flatNodes[$0].el.itemSelected })
                ?? members.first
            return chosen == i
        }
        return collapsed.sorted { a, b in
            let ta = flatNodes[a].el.tabIndex ?? 0
            let tb = flatNodes[b].el.tabIndex ?? 0
            let oa = ta > 0 ? ta : Int.max
            let ob = tb > 0 ? tb : Int.max
            if oa != ob { return oa < ob }
            return a < b
        }
    }

    private func reconcileFocusAfterCommit(
        prevFocusedPath: String?,
        prevFocusedKey: String?,
        prevFocusVisible: Bool
    ) {
        let txBlur = pendingTxBlurRequested
        let txFocusKey = pendingTxFocusKey
        pendingTxBlurRequested = false
        pendingTxFocusKey = nil

        // Detect newly requested `.focused(true)` on non-inert mounted focusable nodes.
        var requestedFocusIdx: Int? = nil
        var nextSyncedRequests: Set<String> = []
        for (i, node) in flatNodes.enumerated() where !node.effectiveInert {
            if node.el.isFocusRequested {
                nextSyncedRequests.insert(node.path)
                if !syncedEditFocusedPaths.contains(node.path) && requestedFocusIdx == nil {
                    requestedFocusIdx = i
                }
            }
        }
        syncedEditFocusedPaths = nextSyncedRequests

        // Track `.modal` & `.focusReturn(...)` owners for return-focus restoration when they close.
        var poppedReturns: [FocusReturnEntry] = []
        var keptReturns: [FocusReturnEntry] = []
        for entry in focusReturnStack {
            if let idx = nodeByPath[entry.ownerPath],
               (flatNodes[idx].el.isModal || flatNodes[idx].el.focusReturnKey != nil) {
                keptReturns.append(entry)
            } else {
                poppedReturns.append(entry)
            }
        }
        focusReturnStack = keptReturns
        for node in flatNodes where (node.el.isModal || node.el.focusReturnKey != nil) {
            if !focusReturnStack.contains(where: { $0.ownerPath == node.path }) {
                focusReturnStack.append(FocusReturnEntry(
                    ownerPath: node.path,
                    returnPath: node.el.focusReturnKey == nil ? prevFocusedPath : nil,
                    returnKey: node.el.focusReturnKey ?? prevFocusedKey,
                    prevFocusVisible: prevFocusVisible
                ))
            }
        }

        var nextIdx: Int? = nil
        if txBlur {
            nextIdx = nil
        } else if let fk = txFocusKey,
                  let idx = flatNodes.firstIndex(where: { $0.key == fk && canFocusIndex($0.index) }) {
            nextIdx = idx
        } else if let rIdx = requestedFocusIdx, canFocusIndex(rIdx) {
            nextIdx = rIdx
            focusVisible = false
        } else if let fk = focusedKey,
                  let idx = flatNodes.firstIndex(where: { $0.key == fk && canFocusIndex($0.index) }) {
            nextIdx = idx
        } else if let fp = focusedPath,
                  let idx = nodeByPath[fp],
                  canFocusIndex(idx) {
            nextIdx = idx
        }

        if !txBlur && nextIdx == nil {
            for ret in poppedReturns.reversed() {
                if let rk = ret.returnKey,
                   let idx = flatNodes.firstIndex(where: { $0.key == rk && canFocusIndex($0.index) }) {
                    nextIdx = idx
                    break
                }
                if let rp = ret.returnPath,
                   let idx = nodeByPath[rp],
                   canFocusIndex(idx) {
                    nextIdx = idx
                    break
                }
            }
        }

        if txFocusKey == nil && nextIdx == nil {
            for (i, node) in flatNodes.enumerated() where node.el.autofocus && canFocusIndex(i) {
                if !autofocusAppliedPaths.contains(node.path) {
                    autofocusAppliedPaths.insert(node.path)
                    nextIdx = i
                    break
                }
            }
        }

        if !txBlur && nextIdx == nil && activeModalPath != nil && (prevFocusedPath != nil || !poppedReturns.isEmpty || cxSettings.viewDefaults.webFocus) {
            nextIdx = tabOrderIndices().first
        }

        focusedPath = nextIdx.map { flatNodes[$0].path }
        focusedKey = nextIdx.flatMap { flatNodes[$0].key }
    }

    // MARK: - Live Property Evaluation

    private func updateLiveBindings(at now: Double) -> Bool {
        var anyTweenOrPulsePending = false
        for node in flatNodes where !node.el.liveBindings.isEmpty {
            for b in node.el.liveBindings {
                let lk = LiveKey(path: node.path, target: b.target)
                let nid = NodeId.hash("live:\(node.path):\(b.target)")

                // Linear render-time Tween
                if let lin = b.source.linearSpec {
                    let objId = ObjectIdentifier(b.source)
                    let tStart = liveTweenStart[objId] ?? {
                        liveTweenStart[objId] = now
                        return now
                    }()
                    let snap = b.source.readSnapshot()
                    let dur = lin.duration
                    let u = dur <= 0 ? 1.0 : ((now - tStart) / dur).clamped(to: 0...1)
                    if u < 1.0 { anyTweenOrPulsePending = true }
                    var out = MotionLanes()
                    for lane in 0..<4 {
                        out[lane] = lin.from[lane] + (snap.lanes[lane] - lin.from[lane]) * Float(u)
                    }
                    snapLiveTrack(nid: nid, target: b.target, lanes: out)
                    continue
                }

                // Release any expired pulse hold
                if let pulse = livePulseRelease[lk], now >= pulse.releaseAt {
                    livePulseRelease.removeValue(forKey: lk)
                    animateLiveTrack(nid: nid, target: b.target, lanes: pulse.rest, spring: pulse.spring, at: now)
                } else if livePulseRelease[lk] != nil {
                    anyTweenOrPulsePending = true
                }

                let snap = b.source.readSnapshot()
                if liveSeenSeq[lk] == nil {
                    liveSeenSeq[lk] = snap.seq
                    snapLiveTrack(nid: nid, target: b.target, lanes: snap.lanes)
                    continue
                }
                guard liveSeenSeq[lk] != snap.seq else { continue }
                liveSeenSeq[lk] = snap.seq

                switch snap.op {
                case .snap(let lanes):
                    livePulseRelease.removeValue(forKey: lk)
                    snapLiveTrack(nid: nid, target: b.target, lanes: lanes)

                case .set(let lanes):
                    livePulseRelease.removeValue(forKey: lk)
                    if let sp = b.spring {
                        animateLiveTrack(nid: nid, target: b.target, lanes: lanes, spring: sp, at: now)
                    } else {
                        snapLiveTrack(nid: nid, target: b.target, lanes: lanes)
                    }

                case let .pulse(active, rest, holdSeconds):
                    if let sp = b.spring {
                        animateLiveTrack(nid: nid, target: b.target, lanes: active, spring: sp, at: now)
                        let leave = b.restSpring ?? sp
                        livePulseRelease[lk] = (now + holdSeconds, rest, leave)
                        anyTweenOrPulsePending = true
                    } else {
                        snapLiveTrack(nid: nid, target: b.target, lanes: rest)
                    }
                }
            }
        }
        return anyTweenOrPulsePending
    }

    private func snapLiveTrack(nid: NodeId, target: BoundLiveProperty.Target, lanes: MotionLanes) {
        switch target {
        case .opacity: liveStore.snap(nid, Props.OPACITY, to: lanes.l0)
        case .scale: liveStore.snap(nid, Props.SCALE, to: Vec2(lanes.l0, lanes.l0))
        case .blur: liveStore.snap(nid, Props.BLUR, to: Blur(lanes.l0))
        case .offset, .trim: liveStore.snap(nid, Props.OFFSET, to: Vec2(lanes.l0, lanes.l1))
        case .fill: liveStore.snap(nid, Props.FILL, to: Color.decodeLiveLanes(lanes).motionColor)
        case .rect: liveStore.snap(nid, Props.RECT, to: MotionRect.fromLanes(lanes))
        }
    }

    private func animateLiveTrack(nid: NodeId, target: BoundLiveProperty.Target, lanes: MotionLanes, spring: Spring, at now: Double) {
        switch target {
        case .opacity: liveStore.set(nid, Props.OPACITY, to: lanes.l0, anim: .spring(spring), at: now)
        case .scale: liveStore.set(nid, Props.SCALE, to: Vec2(lanes.l0, lanes.l0), anim: .spring(spring), at: now)
        case .blur: liveStore.set(nid, Props.BLUR, to: Blur(lanes.l0), anim: .spring(spring), at: now)
        case .offset, .trim: liveStore.set(nid, Props.OFFSET, to: Vec2(lanes.l0, lanes.l1), anim: .spring(spring), at: now)
        case .fill: liveStore.set(nid, Props.FILL, to: Color.decodeLiveLanes(lanes).motionColor, anim: .spring(spring), at: now)
        case .rect: liveStore.set(nid, Props.RECT, to: MotionRect.fromLanes(lanes), anim: .spring(spring), at: now)
        }
    }

    private func emitFocusRingIfNeeded(
        el: El<State>,
        snapPath: String,
        isExiting: Bool,
        effectiveInert: Bool,
        isFocused: Bool,
        forceFocusRings: Bool,
        defaultRingOutline: Outline?,
        devRect: SIMD4<Float>,
        devRadii: SIMD4<Float>,
        pxScale: Float,
        localAlpha: Float,
        devW: Int,
        devH: Int,
        into primitives: inout [Primitive]
    ) {
        let clipAll = SIMD4<Float>(0, 0, Float(devW), Float(devH))
        let forcedRing = forceFocusRings && nodeTakesFocus(el)
        let shouldShow = !el.noFocusRing && (forcedRing || (isFocused && (focusVisible || el.role == .textInput)))
        if shouldShow,
           let ringCol = el.focusRingColor ?? defaultRingOutline?.color {
            let rawOff = el.focusRingColor != nil ? el.focusRingOffset : (defaultRingOutline?.offset ?? el.focusRingOffset)
            let rawW = el.focusRingColor != nil ? el.focusRingWidth : (defaultRingOutline?.width ?? el.focusRingWidth)
            let off = rawOff * pxScale
            let ringW = rawW * pxScale
            let ringRect = SIMD4<Float>(devRect.x - off, devRect.y - off, devRect.z + off * 2.0, devRect.w + off * 2.0)
            let ringRadii = SIMD4<Float>(
                devRadii.x >= 0 ? devRadii.x + off : devRadii.x - off,
                devRadii.y >= 0 ? devRadii.y + off : devRadii.y - off,
                devRadii.z >= 0 ? devRadii.z + off : devRadii.z - off,
                devRadii.w >= 0 ? devRadii.w + off : devRadii.w - off
            )
            primitives.append(.roundedRect(
                rect: ringRect,
                radii: ringRadii,
                fill: .zero,
                borderColor: ringCol.scaleAlpha(localAlpha).simd4(srgb: srgbBlend),
                borderWidth: ringW,
                clip: clipAll
            ))
            return
        }
        guard !isExiting, !effectiveInert, focusVisible, !el.noFocusRing, !el.focusWithinFlat,
              let within = el.focusWithinRing,
              let fp = focusedPath,
              (fp == snapPath || fp.hasPrefix(snapPath + "/")) else {
            return
        }
        var suppressed = false
        if let fIdx = nodeByPath[fp] {
            var cur: Int? = fIdx
            while let c = cur {
                if flatNodes[c].path == snapPath { break }
                if flatNodes[c].el.focusWithinFlat || flatNodes[c].el.noFocusRing {
                    suppressed = true
                    break
                }
                cur = flatNodes[c].parentIndex
            }
        }
        guard !suppressed else { return }
        let off = within.offset * pxScale
        let ringW = within.width * pxScale
        let ringRect = SIMD4<Float>(devRect.x - off, devRect.y - off, devRect.z + off * 2.0, devRect.w + off * 2.0)
        let ringRadii = SIMD4<Float>(
            devRadii.x >= 0 ? devRadii.x + off : devRadii.x - off,
            devRadii.y >= 0 ? devRadii.y + off : devRadii.y - off,
            devRadii.z >= 0 ? devRadii.z + off : devRadii.z - off,
            devRadii.w >= 0 ? devRadii.w + off : devRadii.w - off
        )
        primitives.append(.roundedRect(
            rect: ringRect,
            radii: ringRadii,
            fill: .zero,
            borderColor: within.color.scaleAlpha(localAlpha).simd4(srgb: srgbBlend),
            borderWidth: ringW,
            clip: clipAll
        ))
    }

    // MARK: - Primitive Emission & ElementInfo Snapshot

    private func buildRefScene(frameOut: FrameOutput, now: Double) -> RefScene {
        let pxScale = pixelScale
        let devW = max(1, Int((viewport.x * pxScale).rounded()))
        let devH = max(1, Int((viewport.y * pxScale).rounded()))
        let defaultViewFg = cxSettings.viewDefaults.foreground
        let defaultRingOutline = cxSettings.viewDefaults.focusRing
        let forceFocusRings = cxSettings.viewDefaults.forceFocusRings

        // Precompute presented rect, scale, and node lookup for every node in `frameOut.nodes`
        var presentedRectById: [NodeId: MotionRect] = [:]
        var presentedScaleById: [NodeId: Vec2] = [:]
        var nodeByFrameId: [NodeId: Presented] = [:]
        var childrenByParent: [NodeId: [Presented]] = [:]
        var rootNodes: [Presented] = []

        for p in frameOut.nodes {
            nodeByFrameId[p.id] = p
        }

        // Compute own presented rect, opacity, scale, and rotation (applying Live & Loop tracks on top of Scene)
        var ownOpacityById: [NodeId: Float] = [:]
        var ownScaleById: [NodeId: Vec2] = [:]
        var ownRotateById: [NodeId: Float] = [:]
        for p in frameOut.nodes {
            guard let snap = nodeById[p.id] ?? exitingSnapshots[p.id] else { continue }
            var rect = p.rect
            var op = p.opacity
            var sc = p.scale
            var rot = p.rotate

            if let ls = loopRuntime.sample(id: p.id, nodeSize: rect.size, at: now, reducedMotion: reducedMotion) {
                op *= ls.opacity
                rot += ls.rotation
                rect = rect.offsetBy(ls.offset)
            }

            for b in snap.el.liveBindings {
                let lnid = NodeId.hash("live:\(snap.path):\(b.target)")
                switch b.target {
                case .opacity:
                    if let v = liveStore.get(lnid, Props.OPACITY) { op = v.clamped(to: 0...1) }
                case .scale:
                    if let v = liveStore.get(lnid, Props.SCALE) { sc = Vec2(max(0, v.x), max(0, v.y)) }
                case .offset:
                    if let v = liveStore.get(lnid, Props.OFFSET) { rect = rect.offsetBy(v) }
                case .rect:
                    if let v = liveStore.get(lnid, Props.RECT) { rect = v }
                case .blur, .fill, .trim:
                    break
                }
            }

            if abs(sc.x - 1.0) > 1e-4 || abs(sc.y - 1.0) > 1e-4 {
                let norm = snap.anchorAttachNorm ?? snap.el.origin
                let pivot = Vec2(rect.x + rect.width * norm.x, rect.y + rect.height * norm.y)
                rect = MotionRect(
                    left: pivot.x + (rect.left - pivot.x) * sc.x,
                    top: pivot.y + (rect.top - pivot.y) * sc.y,
                    right: pivot.x + (rect.right - pivot.x) * sc.x,
                    bottom: pivot.y + (rect.bottom - pivot.y) * sc.y
                )
            }

            presentedRectById[p.id] = rect
            ownOpacityById[p.id] = op.clamped(to: 0...1)
            ownScaleById[p.id] = sc
            ownRotateById[p.id] = rot
            let parentSc = p.parent.flatMap { presentedScaleById[$0] } ?? Vec2(1, 1)
            presentedScaleById[p.id] = Vec2(sc.x * parentSc.x, sc.y * parentSc.y)

            if let pid = p.parent, nodeByFrameId[pid] != nil {
                childrenByParent[pid, default: []].append(p)
            } else {
                rootNodes.append(p)
            }
        }

        // Precompute `hoverAlone` & `hoverGroupShared` active state from pointer / keyboard focus
        let ptrPos = pointerPosition
        let topmostPtrPath: String? = (ptrPos.x > -9000 && ptrPos.y > -9000 && !hitGeometryByPath.isEmpty)
            ? hitTest(at: ptrPos, predicate: { _ in true })?.node.path
            : nil
        let ptrInside: (FlatNode) -> Bool = { node in
            guard ptrPos.x > -9000, ptrPos.y > -9000 else { return false }
            let insideGeom: Bool
            if let geom = self.hitGeometryByPath[node.path] {
                insideGeom = geom.contains(ptrPos)
            } else {
                let r = presentedRectById[node.nodeId] ?? node.targetRect
                insideGeom = halfOpenContains(intersectRects(node.clipRect, r), ptrPos)
            }
            guard insideGeom else { return false }
            if let top = topmostPtrPath, !(top == node.path || top.hasPrefix(node.path + "/")) {
                return false
            }
            return true
        }
        let alonePath: String? = flatNodes
            .filter { $0.el.isHoverAlone && !$0.effectiveInert && ptrInside($0) }
            .max(by: { $0.path.count < $1.path.count })?.path
        let sharedHoverKeys: Set<String> = Set(flatNodes.compactMap { node -> String? in
            guard let k = node.el.hoverGroupShare, !node.effectiveInert else { return nil }
            let focusIn = focusVisible && (focusedPath == node.path || (focusedPath?.hasPrefix(node.path + "/") ?? false))
            return (ptrInside(node) || focusIn) ? k : nil
        })
        func isGroupHovered(_ node: FlatNode) -> Bool {
            guard !node.effectiveInert else { return false }
            if let alonePath, alonePath != node.path, alonePath.hasPrefix(node.path + "/") {
                return false
            }
            if hoveredPath == node.path || (hoveredPath?.hasPrefix(node.path + "/") ?? false) {
                return true
            }
            if ptrInside(node) {
                return true
            }
            if let share = node.el.hoverGroupShare, sharedHoverKeys.contains(share) {
                return true
            }
            if focusVisible, let fp = focusedPath, (fp == node.path || fp.hasPrefix(node.path + "/")) {
                return true
            }
            return false
        }

        func sortByZOrder(_ nodes: [Presented]) -> [Presented] {
            nodes.enumerated().sorted { a, b in
                let za = (nodeById[a.element.id] ?? exitingSnapshots[a.element.id])?.zOrder ?? 0
                let zb = (nodeById[b.element.id] ?? exitingSnapshots[b.element.id])?.zOrder ?? 0
                if za != zb { return za < zb }
                return a.offset < b.offset
            }.map(\.element)
        }

        var primitives: [Primitive] = []
        primitives.reserveCapacity(frameOut.nodes.count * 2)
        var infos: [ElementInfo] = []
        infos.reserveCapacity(frameOut.nodes.count)
        let windowRect = MotionRect.fromXYWH(0, 0, viewport.x, viewport.y)
        var newRectByPath: [String: MotionRect] = [:]
        var newScaleByPath: [String: Vec2] = [:]
        var newHitGeometries: [String: HitGeometry] = [:]
        var newPaintOrder: [String] = []
        newPaintOrder.reserveCapacity(frameOut.nodes.count)
        var newHelpHits: [HelpHitRecord] = []
        var newInteractiveHits: [HelpInteractiveHitRecord] = []
        var builtSurfaces: [SurfaceDraw] = []
        var videosActive = false
        var newVideoSig: UInt64 = 0
        var newVideoSnaps: [String: VideoSnapshot] = [:]

        let flyingRootIds: Set<NodeId> = Set(frameOut.nodes.compactMap { p in
            guard let snap = nodeById[p.id],
                  snap.el.flightId != nil,
                  (activeFlightIds.contains(p.id) || scene.isEdgeAnimating(p.id)),
                  !p.isExiting else {
                return nil
            }
            return p.id
        })
        var liftedFlights: [LiftedFlightSubtree] = []
        var newSeenMatched: [String: MatchedSeenSnapshot] = [:]

        @inline(never)
        func emitNodeEnter(_ input: EmitStepInput) -> (children: [EmitStepInput], exit: EmitNodeExit) {
            let p = input.p
            let ancestorOpacity = input.ancestorOpacity
            let ancestorTurn = input.ancestorTurn
            let outerTurnClip = input.outerTurnClip
            let localTurnClip = input.localTurnClip
            let parentPath = input.parentPath
            let nearestGroupHovered = input.nearestGroupHovered
            let flightCover = input.flightCover
            let flightClipOverride = input.flightClipOverride
            let emitLiftedNow = input.emitLiftedNow
            let emptyExit = EmitNodeExit(layerEndCount: 0, devClip: .zero)
            guard let snap = nodeById[p.id] ?? exitingSnapshots[p.id] else { return ([], emptyExit) }
            if !emitLiftedNow && flyingRootIds.contains(p.id) {
                liftedFlights.append(LiftedFlightSubtree(
                    node: p,
                    ancestorOpacity: ancestorOpacity,
                    ancestorTurn: ancestorTurn,
                    outerTurnClip: outerTurnClip,
                    localTurnClip: localTurnClip,
                    parentPath: parentPath,
                    nearestGroupHovered: nearestGroupHovered
                ))
                return ([], emptyExit)
            }
            let el = snap.el
            let rawRect = presentedRectById[p.id] ?? p.rect
            let ownOp = ownOpacityById[p.id] ?? p.opacity
            let groupFactor: Float = {
                guard let (restOp, hovOp) = el.groupOpacity else { return 1.0 }
                return nearestGroupHovered ? hovOp : restOp
            }()
            let alpha = (ownOp * ancestorOpacity * groupFactor).clamped(to: 0...1)
            let rawScaleVec = presentedScaleById[p.id] ?? p.scale
            let rect: MotionRect
            let scaleVec: Vec2
            if let fc = flightCover {
                rect = MotionRect.fromXYWH(
                    fc.presentedOrigin.x + (rawRect.x - fc.targetOrigin.x) * fc.scale,
                    fc.presentedOrigin.y + (rawRect.y - fc.targetOrigin.y) * fc.scale,
                    rawRect.width * fc.scale,
                    rawRect.height * fc.scale
                )
                scaleVec = Vec2(rawScaleVec.x * fc.scale, rawScaleVec.y * fc.scale)
            } else {
                rect = rawRect
                scaleVec = rawScaleVec
            }
            let effRotate = ownRotateById[p.id] ?? p.rotate

            let ownHasTurn = abs(effRotate) > 1e-6
            let nodeTurn: Turn?
            if ownHasTurn {
                let pivot = Vec2(rect.x + rect.width * el.origin.x, rect.y + rect.height * el.origin.y)
                let localTurn = Turn.about(pivot, radians: effRotate)
                nodeTurn = ancestorTurn.map { $0.after(localTurn) } ?? localTurn
            } else {
                nodeTurn = ancestorTurn
            }

            let parentWindowClip: MotionRect = {
                if let flightClipOverride { return flightClipOverride }
                if nodeById[p.id] != nil {
                    return snap.parentIndex.flatMap { flatNodes.indices.contains($0) ? flatNodes[$0].clipRect : nil } ?? windowRect
                }
                return snap.clipRect
            }()
            let effectiveOuterClip: MotionRect
            let effectiveHitClip: MotionRect
            let childLocalTurnClip: MotionRect?
            if ownHasTurn {
                let outerBase: MotionRect
                if let outerTurnClip, let localTurnClip, let ancestorTurn {
                    outerBase = intersectRects(outerTurnClip, ancestorTurn.bbox(localTurnClip))
                } else if let outerTurnClip {
                    outerBase = outerTurnClip
                } else {
                    outerBase = parentWindowClip
                }
                effectiveOuterClip = outerBase
                effectiveHitClip = windowRect
                childLocalTurnClip = el.layout.clipOverflow ? rect : windowRect
            } else if let outerTurnClip {
                effectiveOuterClip = outerTurnClip
                effectiveHitClip = localTurnClip ?? windowRect
                childLocalTurnClip = el.layout.clipOverflow ? intersectRects(effectiveHitClip, rect) : effectiveHitClip
            } else {
                effectiveOuterClip = parentWindowClip
                effectiveHitClip = parentWindowClip
                childLocalTurnClip = nil
            }

            newRectByPath[snap.path] = rect
            newScaleByPath[snap.path] = scaleVec
            newPaintOrder.append(snap.path)

            var fillColor = p.fill.map(Color.init) ?? el.background
            var blurPt = p.blur
            var liveTrim: Vec2? = nil
            for b in el.liveBindings {
                let lnid = NodeId.hash("live:\(snap.path):\(b.target)")
                if b.target == .fill, let mc = liveStore.get(lnid, Props.FILL) {
                    fillColor = Color(mc)
                } else if b.target == .blur, let bl = liveStore.get(lnid, Props.BLUR) {
                    blurPt = bl.radius
                } else if b.target == .trim, let tr = liveStore.get(lnid, Props.OFFSET) {
                    liveTrim = tr
                }
            }
            let borderColor = p.border.map(Color.init) ?? el.borderColor

            var visClip = flightClipOverride ?? snap.clipRect
            if let rev = p.revealClip {
                visClip = intersectRects(visClip, rev)
            }
            let visibleRect = intersectRects(visClip, rect)

            if let fid = el.flightId, !p.isExiting {
                newSeenMatched[fid] = MatchedSeenSnapshot(
                    id: p.id,
                    path: snap.path,
                    rect: rect,
                    corners: p.corners,
                    fill: fillColor.motionColor,
                    opacity: alpha
                )
                matchedFlightRegistry.recordPrevious(flightId: fid, rect: rect)
            }

            let flightScale = flightCover?.scale ?? 1.0
            let childFlightCover: FlightCoverTransform?
            if let fc = flightCover {
                childFlightCover = fc
            } else if el.flightId != nil,
                      snap.targetRect.width > 0.5,
                      snap.targetRect.height > 0.5,
                      (abs(rect.width - snap.targetRect.width) > 0.5
                        || abs(rect.height - snap.targetRect.height) > 0.5
                        || flyingRootIds.contains(p.id)) {
                let k: Float = el.isMatchedCrop ? 1.0 : max(rect.width / snap.targetRect.width, rect.height / snap.targetRect.height)
                let ox = (rect.width - snap.targetRect.width * k) * 0.5
                let oy = (rect.height - snap.targetRect.height * k) * 0.5
                childFlightCover = FlightCoverTransform(
                    targetOrigin: Vec2(snap.targetRect.x, snap.targetRect.y),
                    presentedOrigin: Vec2(rect.x + ox, rect.y + oy),
                    scale: k
                )
            } else {
                childFlightCover = nil
            }
            let childFlightClip: MotionRect? = childFlightCover != nil
                ? ((el.layout.clipOverflow || el.clipRadius != nil || el.clipCorners != nil || el.clipFade != nil)
                    ? intersectRects(visClip, rect)
                    : visClip)
                : nil

            let isFocused = (focusedPath == snap.path) && !p.isExiting
            let isHovered = (hoveredPath == snap.path) && !p.isExiting && !snap.effectiveInert
            let isPressed = (pressedPath == snap.path) && !p.isExiting && !snap.effectiveInert
            let scrolled = scrollOffsets[snap.path] ?? .zero

            var caretOut: [Float]? = nil
            var textTruncated = false
            let editValue: TextEdit? = el.handlers.editLens.map { lens in
                var e = lens.get(state)
                if el.isSecure {
                    e.isSecure = true
                    if el.isRevealed { e.isRevealed = true }
                }
                return e
            }
            let nodeIsSecure = el.isSecure || (editValue?.isSecure ?? false)
            let rawTextValue: String? = editValue?.text ?? el.liveText?.get() ?? el.plainText
            // Never expose secure plaintext (hidden or revealed) in ElementInfo / --tree snapshots.
            let elementTextValue: String? = nodeIsSecure ? nil : rawTextValue
            let paintedLabelValue: String? = {
                guard let raw = el.liveText?.get() ?? el.plainText else { return nil }
                if nodeIsSecure && !el.isRevealed && !raw.isEmpty {
                    return "••••••••••••"
                }
                return raw
            }()

            let totalShapePieces = el.shapes.reduce(0) { $0 + $1.pieceCount }
            let useLayer = (blurPt >= 0.5) || el.isolatedLayer || (alpha > 0.001 && alpha < 1.0 && totalShapePieces > 1)
            let devClip = SIMD4<Float>(
                visClip.x * pxScale,
                visClip.y * pxScale,
                visClip.width * pxScale,
                visClip.height * pxScale
            )
            let shouldEmit = alpha > 0.001 && visClip.width > 0 && visClip.height > 0

            let activeFadeEdges: [(fade: SIMD4<Float>, origin: SIMD2<Float>)] = {
                guard !snap.activeClipFades.isEmpty else { return [] }
                let primRect = SIMD4<Float>(rect.x * pxScale, rect.y * pxScale, rect.width * pxScale, rect.height * pxScale)
                return AnchorLayoutHelper.edgeFadeEdges(
                    specs: snap.activeClipFades,
                    primRectPx: primRect,
                    pxScale: pxScale
                )
            }()
            func attachFade(_ prim: Primitive) -> Primitive {
                guard let firstFade = activeFadeEdges.first else { return prim }
                var copy = prim
                copy.fade = firstFade.fade
                copy.fadeOrigin = firstFade.origin
                return copy
            }

            if let (surf, _) = el.surfacePayload {
                if let vsnap = surf.videoSnapshot() {
                    newVideoSnaps[snap.path] = vsnap
                }
                if !shouldEmit {
                    newVideoSig = VideoSignature.foldUnpulled(newVideoSig, surface: surf)
                }
            }

            if shouldEmit {
                let devRect = SIMD4<Float>(
                    rect.x * pxScale,
                    rect.y * pxScale,
                    rect.width * pxScale,
                    rect.height * pxScale
                )
                let devRadii = SIMD4<Float>(
                    p.corners.topLeft * pxScale * flightScale,
                    p.corners.topRight * pxScale * flightScale,
                    p.corners.bottomRight * pxScale * flightScale,
                    p.corners.bottomLeft * pxScale * flightScale
                )

                if activeFadeEdges.count > 1 {
                    for k in 1..<activeFadeEdges.count {
                        primitives.append(.layerBegin(
                            rect: devRect,
                            opacity: 1.0,
                            clip: devClip,
                            fade: activeFadeEdges[k].fade,
                            fadeOrigin: activeFadeEdges[k].origin,
                            turn: effRotate
                        ))
                    }
                }

                if useLayer {
                    primitives.append(.layerBegin(
                        rect: devRect,
                        opacity: alpha,
                        blurRadius: blurPt * pxScale,
                        clip: devClip,
                        turn: effRotate
                    ))
                }
                let localAlpha: Float = useLayer ? 1.0 : alpha

                // 0. Backdrop blur if requested
                if el.backdropBlur >= 0.5 {
                    primitives.append(Primitive(
                        rect: devRect,
                        radii: devRadii,
                        params: SIMD4<Float>(el.backdropBlur * pxScale, Float(PrimitiveKind.backdropBlur.rawValue), 0, 0),
                        clip: devClip
                    ))
                }

                // 1. Outer drop shadows
                for sh in el.shadows where !sh.inset && sh.color.a > 0.001 {
                    let sc = sh.color.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                    primitives.append(.dropShadow(
                        rect: devRect,
                        radii: devRadii,
                        color: sc,
                        blur: sh.blur * pxScale,
                        spread: sh.spread * pxScale,
                        offset: SIMD2<Float>(sh.x * pxScale, sh.y * pxScale),
                        cutoutInner: fillColor.a < 0.999 && sh.blur == 0 && sh.spread > 0,
                        clip: devClip
                    ))
                }

                // 2. Box background / gradient / solid border
                let hasFill = fillColor.a > 0.0005
                let hasSolidBorder = el.dashedBorder == nil && borderColor.a > 0.0005 && (el.borderWidth > 0 || el.borderSides != nil)

                if let grad = el.gradient {
                    switch grad {
                    case let .linear(topC, botC, angle):
                        primitives.append(.linearGradient(
                            rect: devRect,
                            radii: devRadii,
                            topColor: topC.scaleAlpha(localAlpha).simd4(srgb: srgbBlend),
                            bottomColor: botC.scaleAlpha(localAlpha).simd4(srgb: srgbBlend),
                            angleRadians: angle,
                            clip: devClip,
                            turn: useLayer ? 0 : p.rotate
                        ))
                    case let .radial(inC, outC):
                        primitives.append(.radialGradient(
                            rect: devRect,
                            radii: devRadii,
                            innerColor: inC.scaleAlpha(localAlpha).simd4(srgb: srgbBlend),
                            outerColor: outC.scaleAlpha(localAlpha).simd4(srgb: srgbBlend),
                            clip: devClip
                        ))
                    }
                }

                let effectiveBoxFill = ((isFocused && focusVisible ? el.focusHighlightColor : nil) ?? fillColor)
                if let (surf, fit) = el.surfacePayload {
                    if hasFill && el.gradient == nil {
                        primitives.append(attachFade(.roundedRect(
                            rect: devRect,
                            radii: devRadii,
                            fill: effectiveBoxFill.scaleAlpha(localAlpha).simd4(srgb: srgbBlend),
                            borderColor: .zero,
                            borderWidth: 0,
                            borderSides: nil,
                            clip: devClip,
                            turn: useLayer ? 0 : p.rotate
                        )))
                    }
                    let wakeHandle = self.waker
                    if let pulled = surf.pullVideo(clock: now, wake: { wakeHandle.wake() }) {
                        if pulled.active {
                            videosActive = true
                        }
                        newVideoSig = VideoSignature.fold(newVideoSig, generation: pulled.generation, surfaceKey: surf.key)
                    }
                    builtSurfaces.append(SurfaceDraw(
                        surface: surf.placed(el.surfacePlace),
                        fit: fit,
                        beforeInstance: UInt32(primitives.count),
                        rect: devRect,
                        radii: devRadii,
                        clip: devClip,
                        fade: activeFadeEdges.first?.fade ?? .zero,
                        fadeOrigin: activeFadeEdges.first?.origin ?? .zero,
                        opacity: localAlpha
                    ))
                    if hasSolidBorder {
                        let b4 = borderColor.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                        let sidePx = el.borderSides.map { s in
                            SIMD4<Float>(
                                snapBorderWidthPx(s.top, scale: pxScale),
                                snapBorderWidthPx(s.right, scale: pxScale),
                                snapBorderWidthPx(s.bottom, scale: pxScale),
                                snapBorderWidthPx(s.left, scale: pxScale)
                            )
                        }
                        let bwPx = el.borderWidth > 0 ? snapBorderWidthPx(el.borderWidth, scale: pxScale) : 0
                        primitives.append(attachFade(.roundedRect(
                            rect: devRect,
                            radii: devRadii,
                            fill: .zero,
                            borderColor: b4,
                            borderWidth: bwPx,
                            borderSides: sidePx,
                            clip: devClip,
                            turn: useLayer ? 0 : p.rotate
                        )))
                    }
                } else if hasFill || hasSolidBorder {
                    let f4 = (el.gradient == nil ? effectiveBoxFill : .transparent).scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                    let b4 = hasSolidBorder ? borderColor.scaleAlpha(localAlpha).simd4(srgb: srgbBlend) : .zero
                    let sidePx = el.borderSides.map { s in
                        SIMD4<Float>(
                            snapBorderWidthPx(s.top, scale: pxScale),
                            snapBorderWidthPx(s.right, scale: pxScale),
                            snapBorderWidthPx(s.bottom, scale: pxScale),
                            snapBorderWidthPx(s.left, scale: pxScale)
                        )
                    }
                    let bwPx = el.borderWidth > 0 ? snapBorderWidthPx(el.borderWidth, scale: pxScale) : 0
                    primitives.append(attachFade(.roundedRect(
                        rect: devRect,
                        radii: devRadii,
                        fill: f4,
                        borderColor: b4,
                        borderWidth: bwPx,
                        borderSides: sidePx,
                        clip: devClip,
                        turn: useLayer ? 0 : effRotate
                    )))
                } else if isFocused && focusVisible, let hl = el.focusHighlightColor {
                    primitives.append(attachFade(.roundedRect(
                        rect: devRect,
                        radii: devRadii,
                        fill: hl.scaleAlpha(localAlpha).simd4(srgb: srgbBlend),
                        borderColor: .zero,
                        borderWidth: 0,
                        clip: devClip,
                        turn: useLayer ? 0 : effRotate
                    )))
                }

                // 3. Dashed border ring
                if let dash = el.dashedBorder, borderColor.a > 0.0005 {
                    primitives.append(.dashedRing(
                        rect: devRect,
                        radii: devRadii,
                        color: borderColor.scaleAlpha(localAlpha).simd4(srgb: srgbBlend),
                        borderWidth: snapBorderWidthPx(el.borderWidth, scale: pxScale),
                        dashLength: dash.dash * pxScale,
                        gapLength: dash.gap * pxScale,
                        phase: dash.phase * pxScale,
                        clip: devClip
                    ))
                }

                // 4. Inset shadows
                for sh in el.shadows where sh.inset && sh.color.a > 0.001 {
                    primitives.append(.insetShadow(
                        rect: devRect,
                        radii: devRadii,
                        color: sh.color.scaleAlpha(localAlpha).simd4(srgb: srgbBlend),
                        blur: sh.blur * pxScale,
                        spread: sh.spread * pxScale,
                        offset: SIMD2<Float>(sh.x * pxScale, sh.y * pxScale),
                        clip: devClip
                    ))
                }

                // 5. Image payload
                if let img = el.imagePayload {
                    let uv = imagePacker.insert(img)
                    let tint = (el.textColor ?? .white).scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                    primitives.append(.image(
                        rect: devRect,
                        radii: devRadii,
                        uv: uv,
                        tint: tint,
                        clip: devClip,
                        turn: useLayer ? 0 : p.rotate
                    ))
                }

                // 6. SVG Icon payload
                if let (svg, _) = el.iconPayload {
                    let pxSize = max(4, Int((min(rect.width, rect.height) * pxScale).rounded()))
                    let entry = textSystem.glyphAtlas.rasterizeIcon(svg, pixelSize: pxSize)
                    let resolvedColor = (nearestGroupHovered ? el.groupColor : nil) ?? el.textColor ?? cxSettings.viewDefaults.foreground ?? .white
                    let tint = resolvedColor.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                    primitives.append(attachFade(.glyph(
                        rect: devRect,
                        uv: entry.uv,
                        color: tint,
                        gamma: 1.0,
                        clip: devClip,
                        turn: useLayer ? 0 : effRotate
                    )))
                }

                // 7. Vector Canvas Shapes (triangles & segments)
                for shape in el.shapes {
                    let effectiveShape = liveTrim.map { shape.trimmed(start: $0.x, end: $0.y) } ?? shape
                    let origin = SIMD2<Float>(rect.x * pxScale, rect.y * pxScale)
                    let k: SIMD2<Float>
                    if let vb = effectiveShape.viewBox, vb.x > 0, vb.y > 0 {
                        k = SIMD2<Float>((rect.width * pxScale) / vb.x, (rect.height * pxScale) / vb.y)
                    } else {
                        k = SIMD2<Float>(scaleVec.x * pxScale, scaleVec.y * pxScale)
                    }
                    let kPx = scaleVec.x * pxScale
                    let transformPoint = { (pt: Vec2) -> SIMD2<Float> in
                        SIMD2<Float>(origin.x + pt.x * k.x, origin.y + pt.y * k.y)
                    }

                    for op in effectiveShape.ops {
                        switch op {
                        case let .fill(points, col):
                            let c4 = col.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                            if c4.w <= 0.0005 { continue }
                            for (indices, aaMask) in Shape.triangulate(points) {
                                let v0 = transformPoint(points[indices[0]])
                                let v1 = transformPoint(points[indices[1]])
                                let v2 = transformPoint(points[indices[2]])
                                primitives.append(.triangle(v0: v0, v1: v1, v2: v2, aaMask: aaMask, color: c4, clip: devClip))
                            }
                        case let .stroke(points, closed, width, cap, col):
                            let c4 = col.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                            if c4.w <= 0.0005 { continue }
                            let strokeW = width * kPx
                            let roundCap = (cap == .round)
                            let n = points.count
                            let count = closed ? n : (n - 1)
                            for i in 0..<count {
                                let pa = transformPoint(points[i])
                                let pb = transformPoint(points[(i + 1) % n])
                                primitives.append(.segment(
                                    from: pa,
                                    to: pb,
                                    width: strokeW,
                                    color: c4,
                                    roundCap: roundCap,
                                    clip: devClip
                                ))
                            }
                        }
                    }
                }

                // 8. Text / Rich Text / TextInput
                let padL = el.layout.padding.left * scaleVec.x
                let padT = el.layout.padding.top * scaleVec.y
                let innerW = max(0, rect.width - (el.layout.padding.left + el.layout.padding.right) * scaleVec.x)
                let textOriginX = rect.x + padL
                let textOriginY = rect.y + padT
                let defaultTextColor = (nearestGroupHovered ? el.groupColor : nil) ?? el.textColor ?? defaultViewFg ?? Tok.theme(dark: systemDark).text

                if let edit = editValue {
                    let displayStr = edit.displayString
                    let showingPlaceholder = displayStr.isEmpty && (edit.preedit?.text.isEmpty ?? true)
                    let renderedStr = showingPlaceholder ? (el.placeholder ?? "") : displayStr
                    let textCol = showingPlaceholder
                        ? (el.placeholderColor ?? defaultTextColor.alpha(0.45))
                        : defaultTextColor
                    var inputStyle = el.textStyle
                    if edit.multiline { inputStyle.wrap = .wrap }

                    let shaped = textSystem.shape(
                        text: renderedStr,
                        style: inputStyle,
                        maxWidth: edit.multiline ? innerW : nil,
                        pixelScale: pxScale,
                        emitGlyphs: !renderedStr.isEmpty
                    )

                    let inputClip = intersectRects(visClip, rect)
                    let devInputClip = SIMD4<Float>(
                        inputClip.x * pxScale,
                        inputClip.y * pxScale,
                        inputClip.width * pxScale,
                        inputClip.height * pxScale
                    )

                    // Selection highlight
                    if isFocused && edit.hasSelection && !showingPlaceholder {
                        let selRange = edit.selectedUTF8Range
                        let cStart = textSystem.caretRect(in: shaped, utf8Offset: selRange.lowerBound, pixelScale: pxScale)
                        let cEnd = textSystem.caretRect(in: shaped, utf8Offset: selRange.upperBound, pixelScale: pxScale)
                        let selCol = (el.selectionColor ?? Tok.accent(0, dark: systemDark).alpha(0.28))
                            .scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                        if abs(cStart.y - cEnd.y) < 1.0 {
                            let sx = min(cStart.x, cEnd.x)
                            let sw = max(2.0, abs(cEnd.x - cStart.x))
                            primitives.append(.roundedRect(
                                rect: SIMD4<Float>(
                                    (textOriginX + sx) * pxScale,
                                    (textOriginY + cStart.y) * pxScale,
                                    sw * pxScale,
                                    cStart.w * pxScale
                                ),
                                radii: SIMD4<Float>(repeating: 2.0 * pxScale),
                                fill: selCol,
                                clip: devInputClip
                            ))
                        } else {
                            // Multi-line selection highlight: first line to right edge + last line from left edge
                            primitives.append(.roundedRect(
                                rect: SIMD4<Float>(
                                    (textOriginX + cStart.x) * pxScale,
                                    (textOriginY + cStart.y) * pxScale,
                                    max(4, innerW - cStart.x) * pxScale,
                                    cStart.w * pxScale
                                ),
                                fill: selCol,
                                clip: devInputClip
                            ))
                            primitives.append(.roundedRect(
                                rect: SIMD4<Float>(
                                    textOriginX * pxScale,
                                    (textOriginY + cEnd.y) * pxScale,
                                    max(4, cEnd.x) * pxScale,
                                    cEnd.w * pxScale
                                ),
                                fill: selCol,
                                clip: devInputClip
                            ))
                        }
                    }

                    // Text glyphs
                    for g in shaped.glyphs {
                        let gc = (g.color ?? textCol).scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                        primitives.append(.glyph(
                            rect: SIMD4<Float>(
                                (textOriginX + g.rect.x * scaleVec.x) * pxScale,
                                (textOriginY + g.rect.y * scaleVec.y) * pxScale,
                                g.rect.z * scaleVec.x * pxScale,
                                g.rect.w * scaleVec.y * pxScale
                            ),
                            uv: g.uv,
                            color: gc,
                            gamma: systemDark ? 0.88 : 1.05,
                            clip: devInputClip
                        ))
                    }

                    // Caret bar when focused & window focused
                    if isFocused {
                        let byteOff = showingPlaceholder ? 0 : edit.cursor
                        let cRect = textSystem.caretRect(in: shaped, utf8Offset: byteOff, pixelScale: pxScale)
                        let worldCaret = [textOriginX + cRect.x, textOriginY + cRect.y, cRect.z, cRect.w]
                        caretOut = worldCaret
                        if windowFocused {
                            let cc = (el.caretColor ?? Tok.accent(0, dark: systemDark))
                                .scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                            primitives.append(.roundedRect(
                                rect: SIMD4<Float>(
                                    worldCaret[0] * pxScale,
                                    worldCaret[1] * pxScale,
                                    max(1.5 * pxScale, 2.0),
                                    worldCaret[3] * pxScale
                                ),
                                radii: SIMD4<Float>(repeating: 1.0 * pxScale),
                                fill: cc,
                                clip: devInputClip
                            ))
                        }
                    }
                } else if el.richSpans != nil || paintedLabelValue != nil {
                    let wrapWidth = (innerW / max(1e-4, scaleVec.x)) + 0.5
                    let shaped = textSystem.shape(
                        text: paintedLabelValue ?? "",
                        spans: el.richSpans,
                        style: el.textStyle,
                        maxWidth: wrapWidth,
                        pixelScale: pxScale,
                        emitGlyphs: true
                    )
                    if el.isHelpWhenTruncated {
                        let naturalSize = textSystem.measure(
                            paintedLabelValue ?? "",
                            style: el.textStyle,
                            maxWidth: nil,
                            pixelScale: pxScale
                        )
                        if naturalSize.x > wrapWidth + 0.5 || naturalSize.y > rect.height + 0.5 {
                            textTruncated = true
                        }
                    }
                    for g in shaped.glyphs {
                        let gc = (g.color ?? defaultTextColor).scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                        primitives.append(attachFade(.glyph(
                            rect: SIMD4<Float>(
                                (textOriginX + g.rect.x * scaleVec.x) * pxScale,
                                (textOriginY + g.rect.y * scaleVec.y) * pxScale,
                                g.rect.z * scaleVec.x * pxScale,
                                g.rect.w * scaleVec.y * pxScale
                            ),
                            uv: g.uv,
                            color: gc,
                            gamma: systemDark ? 0.88 : 1.05,
                            clip: devClip,
                            turn: useLayer ? 0 : effRotate
                        )))
                    }
                }

                // 9. Focus ring & focus-within ring when keyboard-focus-visible (or forced by Cx::forceFocusRings / focused textInput)
                emitFocusRingIfNeeded(
                    el: el,
                    snapPath: snap.path,
                    isExiting: p.isExiting,
                    effectiveInert: snap.effectiveInert,
                    isFocused: isFocused,
                    forceFocusRings: forceFocusRings,
                    defaultRingOutline: defaultRingOutline,
                    devRect: devRect,
                    devRadii: devRadii,
                    pxScale: pxScale,
                    localAlpha: localAlpha,
                    devW: devW,
                    devH: devH,
                    into: &primitives
                )
            }

            let hasVisualBlocker = fillColor.a > 0.001 || el.gradient != nil ||
                (el.borderWidth > 0 && borderColor.a > 0.001) || el.imagePayload != nil ||
                el.backdropBlur >= 0.5 || !el.shapes.isEmpty
            let hnd = el.handlers
            let isInteractiveBlocker = hnd.onClick != nil || hnd.onClickPress != nil || hnd.onDoubleClick != nil ||
                hnd.onPointerDown != nil || hnd.onDrag != nil || hnd.onHover != nil ||
                hnd.editLens != nil || el.isModal || el.explicitHit
            let resolvedRawHelp: String? = {
                guard let h = el.a11yHelp, !h.isEmpty else { return nil }
                if el.isHelpWhenTruncated && !textTruncated { return nil }
                return h
            }()
            if shouldEmit && !p.isExiting && visibleRect.width > 0 && visibleRect.height > 0 {
                let hitRect4 = SIMD4<Float>(
                    visibleRect.x,
                    visibleRect.y,
                    visibleRect.x + visibleRect.width,
                    visibleRect.y + visibleRect.height
                )
                if let hText = resolvedRawHelp {
                    newHelpHits.append(HelpHitRecord(
                        path: snap.path,
                        key: snap.key,
                        rect: hitRect4,
                        seq: newInteractiveHits.count,
                        text: hText,
                        side: el.helpSide,
                        linkIndex: nil
                    ))
                }
                if isInteractiveBlocker || el.hoverBg != nil || el.pressBg != nil ||
                   el.focusable || el.isHoverGroup || el.isHoverAlone {
                    newInteractiveHits.append(HelpInteractiveHitRecord(
                        path: snap.path,
                        rect: hitRect4
                    ))
                }
            }

            newHitGeometries[snap.path] = HitGeometry(
                path: snap.path,
                parentPath: parentPath,
                rect: rect,
                clipRect: effectiveHitClip,
                outerClip: effectiveOuterClip,
                turn: nodeTurn,
                opacity: alpha,
                isExiting: p.isExiting,
                hasVisualBlocker: hasVisualBlocker,
                isInteractiveBlocker: isInteractiveBlocker
            )

            infos.append(ElementInfo(
                path: snap.path,
                key: snap.key,
                parentIndex: snap.parentIndex,
                role: el.role,
                rect: rect.xywh,
                target: snap.targetRect.xywh,
                visible: visibleRect.xywh,
                opacity: alpha,
                scale: scaleVec.x,
                blur: blurPt,
                radius: p.corners.maxMagnitude,
                fill: fillColor,
                textColor: el.textColor ?? (elementTextValue != nil ? cxSettings.viewDefaults.foreground : nil),
                text: elementTextValue,
                label: el.a11yLabel,
                help: resolvedRawHelp.map(runeHelpWords),
                selected: nodeIsSecure ? nil : el.a11ySelected,
                expanded: el.a11yExpanded,
                level: el.a11yLevel,
                itemSelected: el.itemSelected,
                focusable: nodeTakesFocus(el),
                focused: isFocused,
                focusVisible: (isFocused && focusVisible) || (forceFocusRings && nodeTakesFocus(el)),
                inert: snap.effectiveInert,
                moving: p.isMoving,
                exiting: p.isExiting,
                hover: isHovered ? 1.0 : 0.0,
                press: isPressed ? 1.0 : 0.0,
                scrolled: [scrolled.x, scrolled.y],
                caret: caretOut,
                secure: nodeIsSecure,
                disabled: el.a11yDisabled,
                checked: el.a11yChecked,
                a11yValue: el.a11yValue,
                a11yDescription: el.a11yDescription,
                a11yHidden: el.isA11yHidden
            ))

            let ownClipCorners: Corners? = el.clipCorners ?? el.clipRadius.map { r in
                el.corners.maxMagnitude > 0.001 ? p.corners : Corners(r, r, r, r)
            }
            let hasRoundedClipLayer: Bool = {
                guard shouldEmit,
                      let cc = ownClipCorners,
                      cc.maxMagnitude > 0.01,
                      !(childrenByParent[p.id]?.isEmpty ?? true) else {
                    return false
                }
                let maxR = min(rect.width, rect.height) * 0.5
                return min(cc.maxMagnitude, maxR) > 0.01
            }()
            if hasRoundedClipLayer, let cc = ownClipCorners {
                let devRectClip = SIMD4<Float>(
                    rect.x * pxScale,
                    rect.y * pxScale,
                    rect.width * pxScale,
                    rect.height * pxScale
                )
                let maxR = min(devRectClip.z, devRectClip.w) * 0.5
                let clipR = SIMD4<Float>(
                    min(cc.topLeft * scaleVec.x * pxScale, maxR),
                    min(cc.topRight * scaleVec.x * pxScale, maxR),
                    min(cc.bottomRight * scaleVec.x * pxScale, maxR),
                    min(cc.bottomLeft * scaleVec.x * pxScale, maxR)
                )
                primitives.append(.layerBegin(
                    rect: devRectClip,
                    radii: clipR,
                    opacity: 1.0,
                    clip: devClip,
                    turn: useLayer ? 0 : effRotate
                ))
            }

            let childAncestorOp: Float = (shouldEmit && useLayer) ? 1.0 : alpha
            let nextOuterClip: MotionRect? = (nodeTurn != nil) ? effectiveOuterClip : nil
            let nextGroupHovered = (el.isHoverGroup || el.hoverBg != nil || el.hoverGroupShare != nil)
                ? isGroupHovered(snap)
                : nearestGroupHovered
            var childSteps: [EmitStepInput] = []
            if let children = childrenByParent[p.id] {
                let sorted = sortByZOrder(children)
                childSteps.reserveCapacity(sorted.count)
                for child in sorted {
                    childSteps.append(EmitStepInput(
                        p: child,
                        ancestorOpacity: childAncestorOp,
                        ancestorTurn: nodeTurn,
                        outerTurnClip: nextOuterClip,
                        localTurnClip: childLocalTurnClip,
                        parentPath: snap.path,
                        nearestGroupHovered: nextGroupHovered,
                        flightCover: childFlightCover,
                        flightClipOverride: childFlightClip,
                        emitLiftedNow: emitLiftedNow
                    ))
                }
            }
            var layerEndCount = 0
            if hasRoundedClipLayer {
                layerEndCount += 1
            }
            if shouldEmit && useLayer {
                layerEndCount += 1
            }
            if shouldEmit && activeFadeEdges.count > 1 {
                layerEndCount += activeFadeEdges.count - 1
            }
            return (childSteps, EmitNodeExit(layerEndCount: layerEndCount, devClip: devClip))
        }

        func emitSubtree(
            _ p: Presented,
            ancestorOpacity: Float,
            ancestorTurn: Turn?,
            outerTurnClip: MotionRect?,
            localTurnClip: MotionRect?,
            parentPath: String?,
            nearestGroupHovered: Bool,
            flightCover: FlightCoverTransform? = nil,
            flightClipOverride: MotionRect? = nil,
            emitLiftedNow: Bool = false
        ) {
            var workStack: [EmitWorkItem] = [
                .enter(EmitStepInput(
                    p: p,
                    ancestorOpacity: ancestorOpacity,
                    ancestorTurn: ancestorTurn,
                    outerTurnClip: outerTurnClip,
                    localTurnClip: localTurnClip,
                    parentPath: parentPath,
                    nearestGroupHovered: nearestGroupHovered,
                    flightCover: flightCover,
                    flightClipOverride: flightClipOverride,
                    emitLiftedNow: emitLiftedNow
                ))
            ]
            while let item = workStack.popLast() {
                switch item {
                case .enter(let step):
                    let res = emitNodeEnter(step)
                    if res.exit.layerEndCount > 0 {
                        workStack.append(.exit(res.exit))
                    }
                    for childStep in res.children.reversed() {
                        workStack.append(.enter(childStep))
                    }
                case .exit(let ex):
                    for _ in 0..<ex.layerEndCount {
                        primitives.append(.layerEnd(clip: ex.devClip))
                    }
                }
            }
        }

        for root in sortByZOrder(rootNodes) {
            emitSubtree(
                root,
                ancestorOpacity: 1.0,
                ancestorTurn: nil,
                outerTurnClip: nil,
                localTurnClip: nil,
                parentPath: nil,
                nearestGroupHovered: false
            )
        }
        for lifted in liftedFlights {
            emitSubtree(
                lifted.node,
                ancestorOpacity: lifted.ancestorOpacity,
                ancestorTurn: lifted.ancestorTurn,
                outerTurnClip: lifted.outerTurnClip,
                localTurnClip: lifted.localTurnClip,
                parentPath: lifted.parentPath,
                nearestGroupHovered: lifted.nearestGroupHovered,
                flightCover: nil,
                flightClipOverride: nil,
                emitLiftedNow: true
            )
        }
        seenMatchedByFlightId = newSeenMatched

        lastElements = infos
        presentedRectByPath = newRectByPath
        presentedScaleByPath = newScaleByPath
        hitGeometryByPath = newHitGeometries
        paintOrderPaths = newPaintOrder
        helpState.hits = newHelpHits
        helpState.interactiveHits = newInteractiveHits
        updateHelp(at: now, primitives: &primitives)
        surfaces = builtSurfaces
        videoSignature = newVideoSig
        lastVideoSnapshots = newVideoSnaps
        if videosActive {
            isAnimating = true
        }
        _ = now

        return RefScene(
            width: devW,
            height: devH,
            srgbBlend: srgbBlend,
            clearColor: clearColor.simd4(srgb: srgbBlend),
            glyphs: textSystem.glyphAtlas.atlas,
            images: imagePacker.atlas,
            primitives: primitives
        )
    }

    // MARK: - Pointer, Drag, Wheel & Keyboard Event Dispatch

    /// Hit-tests `(x, y)` in logical window points against presented non-exiting, non-inert elements.
    public func hitTestElement(at point: Vec2) -> ElementInfo? {
        guard let hit = hitTest(at: point) else { return nil }
        return lastElements.first(where: { $0.path == hit.node.path })
    }

    private func hitTest(at point: Vec2, predicate: ((FlatNode) -> Bool)? = nil) -> (node: FlatNode, rect: MotionRect)? {
        guard let detailed = hitTestDetailed(at: point, predicate: predicate) else { return nil }
        return (detailed.node, detailed.rect)
    }

    private func hitTestDetailed(
        at point: Vec2,
        predicate: ((FlatNode) -> Bool)? = nil
    ) -> (node: FlatNode, rect: MotionRect, localPoint: Vec2)? {
        let orderedPaths: [String]
        if !paintOrderPaths.isEmpty {
            orderedPaths = paintOrderPaths
        } else {
            let sortedIndices = flatNodes.indices.sorted { a, b in
                let za = flatNodes[a].zOrder
                let zb = flatNodes[b].zOrder
                if za != zb { return za < zb }
                return a < b
            }
            orderedPaths = sortedIndices.map { flatNodes[$0].path }
        }

        // First non-transparent visual or interactive blocker stops hits on non-ancestor elements beneath it.
        var firstBlockerPath: String? = nil

        for path in orderedPaths.reversed() {
            guard let idx = nodeByPath[path], idx < flatNodes.count else { continue }
            let node = flatNodes[idx]
            if node.effectiveInert { continue }

            let geom = hitGeometryByPath[path]
            if let geom {
                if geom.isExiting || geom.opacity <= 0.001 { continue }
                guard let localWindowPt = geom.unturnedLocalPoint(for: point) else { continue }

                if let blocker = firstBlockerPath, !blocker.hasPrefix(path + "/") {
                    continue
                }
                if predicate == nil || predicate!(node) {
                    return (node, geom.rect, Vec2(localWindowPt.x - geom.rect.x, localWindowPt.y - geom.rect.y))
                }
                if firstBlockerPath == nil && (geom.hasVisualBlocker || geom.isInteractiveBlocker) {
                    firstBlockerPath = path
                }
            } else {
                if node.el.opacity <= 0.001 { continue }
                let infoRect = presentedRectByPath[path] ?? node.targetRect
                let hitBox = intersectRects(node.clipRect, infoRect)
                guard halfOpenContains(hitBox, point) else { continue }
                if let blocker = firstBlockerPath, !blocker.hasPrefix(path + "/") {
                    continue
                }
                if predicate == nil || predicate!(node) {
                    return (node, infoRect, Vec2(point.x - infoRect.x, point.y - infoRect.y))
                }
                let hasVis = node.el.background.a > 0.001 || node.el.gradient != nil ||
                    (node.el.borderWidth > 0 && node.el.borderColor.a > 0.001) ||
                    node.el.imagePayload != nil || node.el.backdropBlur >= 0.5 || !node.el.shapes.isEmpty
                if firstBlockerPath == nil && (hasVis || node.el.explicitHit || node.el.isModal) {
                    firstBlockerPath = path
                }
            }
        }
        return nil
    }

    // MARK: - Internal Platform Input Bridges

    internal func dropTargetHitTest(at point: Vec2, for urls: [URL]) -> (path: String, key: String?, rect: MotionRect, spec: DropSpec<State>)? {
        guard let hit = hitTest(at: point, predicate: { node in
            guard let spec = node.el.handlers.drop else { return false }
            let (accepted, rejected) = spec.split(urls)
            return !accepted.isEmpty || (!rejected.isEmpty && spec.claimsRejects)
        }),
              let spec = hit.node.el.handlers.drop else {
            return nil
        }
        return (hit.node.path, hit.node.key, hit.rect, spec)
    }

    internal func dropTarget(byPath path: String) -> (rect: MotionRect, spec: DropSpec<State>)? {
        guard let idx = nodeByPath[path] else { return nil }
        let node = flatNodes[idx]
        guard !node.effectiveInert, let spec = node.el.handlers.drop else { return nil }
        return (presentedRectByPath[path] ?? node.targetRect, spec)
    }

    internal func dropTargetStillActive(path: String) -> Bool {
        guard let idx = nodeByPath[path] else { return false }
        let node = flatNodes[idx]
        return !node.effectiveInert && node.el.handlers.drop != nil
    }

    internal func anchorRect(forKey key: String) -> MotionRect? {
        let suffix = "/" + key
        let node: FlatNode?
        if key.contains("/") {
            node = flatNodes.first(where: { $0.path == key || $0.path.hasSuffix(suffix) })
        } else {
            node = flatNodes.first(where: { $0.key == key })
        }
        guard let matched = node, !matched.effectiveInert else { return nil }
        return presentedRectByPath[matched.path] ?? matched.targetRect
    }

    internal func releasePointerForPopup(at now: Double) {
        armedDragOut = nil
        activeDrag = nil
        pressedPath = nil
        pressedKey = nil
        pointerExit(at: now)
    }

    internal func releasePointerForDragOut(at now: Double) {
        activeDrag = nil
        pressedPath = nil
        pressedKey = nil
        if let old = hoveredPath {
            hoveredPath = nil
            hoveredKey = nil
            if let idx = nodeByPath[old], let cb = flatNodes[idx].el.handlers.onHover {
                var tx = Tx()
                cb(&state, false, &tx)
                applyTx(tx, at: now)
            }
        }
        dirtyCommit(at: now)
    }

    internal func dragSourceNode(byPath path: String) -> (
        rect: MotionRect?,
        key: String?,
        dragOut: ((State) -> DragItem?)?,
        attachedItem: DragItem?,
        onStart: ((inout State, inout Tx) -> Void)?,
        onEnd: ((inout State, DragOutcome, inout Tx) -> Void)?
    )? {
        guard let idx = nodeByPath[path] else { return nil }
        let node = flatNodes[idx]
        guard !node.effectiveInert else { return nil }
        let h = node.el.handlers
        guard h.dragOut != nil || node.el.attachedDragOutItem != nil else { return nil }
        return (
            presentedRectByPath[path] ?? node.targetRect,
            node.key,
            h.dragOut,
            node.el.attachedDragOutItem,
            h.onDragStart,
            h.onDragOutEnd
        )
    }

    internal func dragOutEndHandler(byPath path: String) -> ((inout State, DragOutcome, inout Tx) -> Void)? {
        guard let idx = nodeByPath[path] else { return nil }
        return flatNodes[idx].el.handlers.onDragOutEnd
    }

    public func pointerExit(at now: Double) {
        pointerPosition = Vec2(-10000, -10000)
        if helpState.tipState != .idle {
            dirtyCommit(at: now)
        }
        if let old = hoveredPath {
            hoveredPath = nil
            hoveredKey = nil
            if let oldIdx = nodeByPath[old], let cb = flatNodes[oldIdx].el.handlers.onHover {
                var tx = Tx()
                cb(&state, false, &tx)
                applyTx(tx, at: now)
            }
            dirtyCommit(at: now)
        }
    }

    public func pointerMove(to pos: Vec2, mods: Mods = .none, at now: Double) {
        pointerPosition = pos

        if checkArmedDragOutMove(to: pos, at: now) {
            return
        }

        // Active drag capture takes priority over hover
        if let drag = activeDrag {
            if let idx = nodeByPath[drag.path] {
                let node = flatNodes[idx]
                if drag.isTextSelectionDrag, let editLens = node.el.handlers.editLens {
                    var edit = editLens.get(state)
                    let offset = textHitOffset(node: node, windowPos: pos, edit: edit)
                    edit.setCursor(utf8Offset: offset, extendSelection: true)
                    editLens.set(&state, edit)
                    dirtyCommit(at: now)
                } else if let onDrag = node.el.handlers.onDrag {
                    let d = Drag(
                        window: pos,
                        local: Vec2(pos.x - drag.startElementOrigin.x, pos.y - drag.startElementOrigin.y),
                        delta: Vec2(pos.x - drag.startWindow.x, pos.y - drag.startWindow.y),
                        startLocal: drag.startLocal,
                        size: drag.elementSize,
                        clicks: drag.clicks,
                        mods: mods
                    )
                    var tx = Tx()
                    onDrag(&state, d, &tx)
                    applyTx(tx, at: now)
                }
            }
            return
        }

        let hit = hitTest(at: pos) { node in
            let h = node.el.handlers
            return node.el.hoverBg != nil || node.el.pressBg != nil ||
                   node.el.isHoverGroup || node.el.isHoverAlone ||
                   h.onHover != nil || h.onClick != nil || h.onClickPress != nil ||
                   h.onDrag != nil || h.editLens != nil || node.el.a11yHelp != nil
        }

        let newPath = hit?.node.path
        let newKey = hit?.node.key
        if newPath != hoveredPath {
            let oldPath = hoveredPath
            hoveredPath = newPath
            hoveredKey = newKey
            if let old = oldPath, let oldIdx = nodeByPath[old], let cb = flatNodes[oldIdx].el.handlers.onHover {
                var tx = Tx()
                cb(&state, false, &tx)
                applyTx(tx, at: now)
            }
            if let np = newPath, let newIdx = nodeByPath[np], let cb = flatNodes[newIdx].el.handlers.onHover {
                var tx = Tx()
                cb(&state, true, &tx)
                applyTx(tx, at: now)
            }
            dirtyCommit(at: now)
        } else if helpTargetChanges(at: pos) {
            dirtyCommit(at: now)
        }

        if let moveHit = hitTest(at: pos, predicate: { $0.el.handlers.onPointerMove != nil }),
           let onMove = moveHit.node.el.handlers.onPointerMove {
            let press = PointerPress(
                window: pos,
                local: Vec2(pos.x - moveHit.rect.x, pos.y - moveHit.rect.y),
                elementSize: Vec2(moveHit.rect.width, moveHit.rect.height),
                button: .primary,
                mods: mods,
                clicks: 0
            )
            var tx = Tx()
            onMove(&state, press, &tx)
            applyTx(tx, at: now)
        }
    }

    public func pointerDown(at pos: Vec2, button: PointerButton = .primary, mods: Mods = .none, at now: Double) {
        pointerPosition = pos
        focusVisible = false
        pressHelp(at: pos, now: now)

        if button == .primary {
            let dt = now - lastClickTime
            let dist = hypotf(pos.x - lastClickPos.x, pos.y - lastClickPos.y)
            if dt <= 0.35 && dist <= 6.0 {
                clickCount += 1
            } else {
                clickCount = 1
            }
            lastClickTime = now
            lastClickPos = pos
        } else {
            clickCount = 1
        }

        // Modal click-outside dismissal & scrim swallow when an active modal is mounted.
        if let mPath = activeModalPath, let mIdx = nodeByPath[mPath] {
            let hitInsideModalMember: Bool = modalMemberPaths.contains { memberPath in
                if let geom = hitGeometryByPath[memberPath] {
                    return geom.contains(pos)
                }
                if let r = presentedRectByPath[memberPath] ?? nodeByPath[memberPath].map({ flatNodes[$0].targetRect }) {
                    return halfOpenContains(r, pos)
                }
                return false
            }
            if !hitInsideModalMember {
                if flatNodes[mIdx].el.modalClickOutside, let dismiss = flatNodes[mIdx].el.handlers.modalDismiss {
                    var tx = Tx()
                    dismiss(&state, &tx)
                    applyTx(tx, at: now)
                }
                return
            }
        }

        if button == .secondary {
            if let (node, rect, local) = hitTestDetailed(at: pos, predicate: { $0.el.handlers.onSecondaryClick != nil }) {
                let press = PointerPress(
                    window: pos,
                    local: local,
                    elementSize: Vec2(rect.width, rect.height),
                    button: .secondary,
                    mods: mods,
                    clicks: 1
                )
                var tx = Tx()
                node.el.handlers.onSecondaryClick?(&state, press, &tx)
                applyTx(tx, at: now)
            }
            return
        }

        let interactiveHit = hitTestDetailed(at: pos) { node in
            let h = node.el.handlers
            return h.onClick != nil || h.onClickPress != nil || h.onDoubleClick != nil ||
                   h.onPointerDown != nil || h.onDrag != nil || h.dragOut != nil ||
                   node.el.attachedDragOutItem != nil || h.editLens != nil ||
                   self.nodeTakesFocus(node.el) || node.el.pressBg != nil || node.el.pressScaleFactor != nil ||
                   node.el.isModal || (node.el.role == .button && node.el.explicitHit)
        }

        guard let (node, rect, local) = interactiveHit else {
            if cxSettings.viewDefaults.webFocus, let bgHit = hitTest(at: pos, predicate: { _ in true }) {
                webFocusTabStartPath = bgHit.node.path
            }
            if focusedPath != nil {
                focusedPath = nil
                focusedKey = nil
                dirtyCommit(at: now)
            }
            return
        }

        pressedPath = node.path
        pressedKey = node.key
        if cxSettings.viewDefaults.webFocus {
            webFocusTabStartPath = node.path
        }
        if nodeTakesFocus(node.el) {
            focusedPath = node.path
            focusedKey = node.key
        }
        dirtyCommit(at: now)

        let elemSize = Vec2(rect.width, rect.height)
        let press = PointerPress(
            window: pos,
            local: local,
            elementSize: elemSize,
            button: button,
            mods: mods,
            clicks: clickCount
        )

        if let onDown = node.el.handlers.onPointerDown {
            var tx = Tx()
            onDown(&state, press, &tx)
            applyTx(tx, at: now)
        }

        // TextInput caret placement / double-click word selection / drag selection
        if let editLens = node.el.handlers.editLens {
            let snapshot = state
            var edit = editLens.get(state)
            let offset = textHitOffset(node: node, windowPos: pos, edit: edit)
            if clickCount >= 3 {
                edit.selectAll()
            } else if clickCount == 2 {
                edit.selectWord(atUTF8Offset: offset)
            } else {
                edit.setCursor(utf8Offset: offset, extendSelection: mods.shift)
            }
            editLens.set(&state, edit)
            activeDrag = DragSession(
                path: node.path,
                key: node.key,
                startWindow: pos,
                startLocal: local,
                startElementOrigin: Vec2(rect.x, rect.y),
                elementSize: elemSize,
                clicks: clickCount,
                button: button,
                isTextSelectionDrag: true,
                stateSnapshotBeforeDrag: snapshot
            )
            dirtyCommit(at: now)
            return
        }

        let hasDragOut = node.el.handlers.dragOut != nil || node.el.attachedDragOutItem != nil
        if button == .primary && hasDragOut {
            let threshold = node.el.handlers.dragThreshold ?? DragItem.defaultThreshold
            armedDragOut = (path: node.path, key: node.key, startWindow: pos, bounds: rect, threshold: threshold)
        } else {
            armedDragOut = nil
        }

        if node.el.handlers.onDrag != nil && !hasDragOut {
            let snapshot = state
            activeDrag = DragSession(
                path: node.path,
                key: node.key,
                startWindow: pos,
                startLocal: local,
                startElementOrigin: Vec2(rect.x, rect.y),
                elementSize: elemSize,
                clicks: clickCount,
                button: button,
                isTextSelectionDrag: false,
                stateSnapshotBeforeDrag: snapshot
            )
            // Deliver initial drag at delta 0 so sliders jump/latch under pointer immediately!
            var tx = Tx()
            node.el.handlers.onDrag?(
                &state,
                Drag(
                    window: pos,
                    local: local,
                    delta: .zero,
                    startLocal: local,
                    size: elemSize,
                    clicks: clickCount,
                    mods: mods
                ),
                &tx
            )
            applyTx(tx, at: now)
        }
    }

    public func pointerUp(at pos: Vec2, button: PointerButton = .primary, mods: Mods = .none, at now: Double) {
        pointerPosition = pos
        armedDragOut = nil
        let releasedPath = pressedPath
        pressedPath = nil
        pressedKey = nil
        dirtyCommit(at: now)

        var draggedPastThreshold = false
        if let drag = activeDrag {
            activeDrag = nil
            draggedPastThreshold = !drag.isTextSelectionDrag &&
                hypot(pos.x - drag.startWindow.x, pos.y - drag.startWindow.y) > 4.0
            if !drag.isTextSelectionDrag, let idx = nodeByPath[drag.path], let onEnd = flatNodes[idx].el.handlers.onDragEnd {
                var tx = Tx()
                onEnd(&state, false, &tx)
                applyTx(tx, at: now)
            }
        }

        guard let rPath = releasedPath, let idx = nodeByPath[rPath] else { return }
        let node = flatNodes[idx]
        let rect = presentedRectByPath[rPath] ?? node.targetRect
        let unturnedLocal = hitGeometryByPath[rPath]?.turn?.unturn(pos) ?? pos
        let press = PointerPress(
            window: pos,
            local: Vec2(unturnedLocal.x - rect.x, unturnedLocal.y - rect.y),
            elementSize: Vec2(rect.width, rect.height),
            button: button,
            mods: mods,
            clicks: clickCount
        )

        if let onUp = node.el.handlers.onPointerUp {
            var tx = Tx()
            onUp(&state, press, &tx)
            applyTx(tx, at: now)
        }

        // Fire click / double-click only if pointer released inside the pressed element and not dragged!
        let inside = hitGeometryByPath[rPath]?.contains(pos) ?? halfOpenContains(rect, pos)
        if inside && button == .primary && !(draggedPastThreshold && node.el.handlers.onDrag != nil) {
            if clickCount == 2, let onDbl = node.el.handlers.onDoubleClick {
                var tx = Tx()
                onDbl(&state, &tx)
                applyTx(tx, at: now)
            } else {
                if let onClick = node.el.handlers.onClick {
                    var tx = Tx()
                    onClick(&state, &tx)
                    applyTx(tx, at: now)
                }
                if let onClickP = node.el.handlers.onClickPress {
                    var tx = Tx()
                    onClickP(&state, press, &tx)
                    applyTx(tx, at: now)
                }
            }
        }
    }

    /// Routes wheel / trackpad scroll deltas to custom `onWheel` handlers or the nearest scrollable ancestor.
    public func wheel(_ event: WheelEvent, at pos: Vec2? = nil, now: Double) {
        dismissHelp(at: now)
        let targetPos = pos ?? pointerPosition
        if let pos { pointerPosition = pos }

        // Check custom `onWheel` handler first
        if let (customNode, _) = hitTest(at: targetPos, predicate: { $0.el.handlers.onWheel != nil }) {
            var tx = Tx()
            if customNode.el.handlers.onWheel?(&state, event, &tx) == true {
                applyTx(tx, at: now)
                return
            }
        }

        // Find innermost scrollable container under `targetPos`, chaining up ancestors if at boundary
        guard let (hitNode, _) = hitTest(at: targetPos) else {
            return
        }
        var walkIdx: Int? = hitNode.index
        while let i = walkIdx {
            let scrollNode = flatNodes[i]
            if !scrollNode.effectiveInert && !scrollNode.el.layout.scrollAxes.isEmpty {
                let path = scrollNode.path
                let maxExt = scrollMaxExtents[path] ?? .zero
                let prev = scrollOffsets[path] ?? .zero
                var cur = prev
                if scrollNode.el.layout.scrollAxes.contains(.horizontal) {
                    cur.x = (cur.x - event.dx).clamped(to: 0...maxExt.x)
                }
                if scrollNode.el.layout.scrollAxes.contains(.vertical) {
                    cur.y = (cur.y - event.dy).clamped(to: 0...maxExt.y)
                    if maxExt.y - cur.y <= 2.0 {
                        wasPinnedToBottom.insert(path)
                    } else {
                        wasPinnedToBottom.remove(path)
                    }
                }
                if cur != prev {
                    let nid = NodeId.hash("scroll:" + path)
                    scrollOffsets[path] = cur
                    scrollStore.snap(nid, Props.SCROLL, to: cur)
                    dirtyCommit(at: now)
                    return
                }
            }
            walkIdx = flatNodes[i].parentIndex
        }
    }

    /// Starts an inertial scroll `Decay` fling (`vx`, `vy` in points/sec) on the scroll container under `pos`.
    public func fling(vx: Float = 0, vy: Float, at pos: Vec2? = nil, now: Double) {
        dismissHelp(at: now)
        let targetPos = pos ?? pointerPosition
        guard let (scrollNode, _) = hitTest(at: targetPos, predicate: { !$0.el.layout.scrollAxes.isEmpty }) else {
            return
        }
        let path = scrollNode.path
        let nid = NodeId.hash("scroll:" + path)
        let cur = scrollOffsets[path] ?? .zero
        scrollStore.snap(nid, Props.SCROLL, to: cur)
        // Upstream `pointer.rs:501-509` & `scroll/x.rs:331`: positive velocity moves content down/right (reduces scroll offset).
        _ = scrollStore.fling(nid, Props.SCROLL, from: cur, velocity: Velocity(Vec2(-vx, -vy)), decay: .IOS_NORMAL, at: cxSettings.scaledTime(at: now))
    }

    /// Routes keyboard `KeyEvent` through active drag cancel (`Escape`), focused `TextEdit`,
    /// ancestor `onKey` handlers, `Tab` / arrow focus traversal, and app-level `globalOnKey`.
    @discardableResult
    public func physicalInput(_ event: PhysicalInput, fallbackKey: KeyEvent? = nil, at now: Double) -> Bool {
        currentTime = now
        if needsCommit {
            commitTree(at: now, cut: forceInitialSettle)
            needsCommit = false
            forceInitialSettle = false
        }

        // Dispatch along focused -> ancestor chain (stopping at inert / modal boundary)
        if let fPath = focusedPath, let fIdx = nodeByPath[fPath] {
            var walkIdx: Int? = fIdx
            while let curIdx = walkIdx {
                if flatNodes[curIdx].effectiveInert { break }
                if let onPhys = flatNodes[curIdx].el.handlers.onPhysicalInput {
                    var tx = Tx()
                    if onPhys(&state, event, &tx) {
                        applyTx(tx, at: now)
                        return true
                    }
                }
                if flatNodes[curIdx].el.isModal { break }
                walkIdx = flatNodes[curIdx].parentIndex
            }
        } else {
            // If no element has focus, dispatch to non-inert physical handlers from innermost/root
            for node in flatNodes.reversed() where !node.effectiveInert {
                if let onPhys = node.el.handlers.onPhysicalInput {
                    var tx = Tx()
                    if onPhys(&state, event, &tx) {
                        applyTx(tx, at: now)
                        return true
                    }
                }
            }
        }

        if let fallbackKey {
            if case .key(_, _, let pressed, let isRepeat) = event {
                if !pressed { return false }
                return keyDown(fallbackKey, isRepeat: isRepeat, at: now)
            }
            return keyDown(fallbackKey, at: now)
        }
        return false
    }

    @discardableResult
    public func keyDown(_ ev: KeyEvent, isRepeat: Bool = false, at now: Double) -> Bool {
        dismissHelp(at: now)
        // 1. Escape cancels an in-progress drag and restores pre-drag state!
        if ev.key == .escape, let drag = activeDrag {
            state = drag.stateSnapshotBeforeDrag
            activeDrag = nil
            pressedPath = nil
            pressedKey = nil
            if let idx = nodeByPath[drag.path], let onEnd = flatNodes[idx].el.handlers.onDragEnd {
                var tx = Tx()
                onEnd(&state, true, &tx)
                applyTx(tx, at: now)
            }
            dirtyCommit(at: now)
            return true
        }

        // 2. Focused element & ancestor chain
        if let fPath = focusedPath, let fIdx = nodeByPath[fPath] {
            let fNode = flatNodes[fIdx]

            // Upstream `keys.rs:238-246` & `on_key_tests.rs:81-90`: a focused text field keeps its keys;
            // ancestor `onKey` handlers must not preempt typing, navigation, or editing inside it.
            if fNode.el.handlers.editLens == nil {
                var walkIdx: Int? = fIdx
                while let curIdx = walkIdx {
                    if flatNodes[curIdx].effectiveInert { break }
                    if let onKey = flatNodes[curIdx].el.handlers.onKey {
                        var tx = Tx()
                        if onKey(&state, ev, &tx) {
                            applyTx(tx, at: now)
                            return true
                        }
                    }
                    if flatNodes[curIdx].el.isModal { break }
                    walkIdx = flatNodes[curIdx].parentIndex
                }
            }

            // Focused TextInput editing
            if let editLens = fNode.el.handlers.editLens {
                if ev.mods.primaryCommand, (ev.key == .command("v") || ev.key == .text("v") || ev.key == .text("V")) {
                    paste(clipboard, at: now)
                    return true
                }
                var edit = editLens.get(state)
                if fNode.el.isSecure {
                    edit.isSecure = true
                    if fNode.el.isRevealed { edit.isRevealed = true }
                }
                // Upstream `secure_text.rs:536,558`: copy/cut on secure text input stay blocked even when revealed.
                if edit.isSecure && ev.mods.primaryCommand &&
                    (ev.key == .command("c") || ev.key == .text("c") || ev.key == .text("C") ||
                     ev.key == .command("x") || ev.key == .text("x") || ev.key == .text("X")) {
                    return true
                }
                let outcome = edit.handleKey(ev)
                switch outcome {
                case .ignored:
                    break
                case .navigation:
                    editLens.set(&state, edit)
                    dirtyCommit(at: now)
                    return true
                case .modified:
                    editLens.set(&state, edit)
                    if let onChange = fNode.el.handlers.onTextChange {
                        var tx = Tx()
                        onChange(&state, edit.text, &tx)
                        applyTx(tx, at: now)
                    }
                    dirtyCommit(at: now)
                    return true
                case .submit:
                    editLens.set(&state, edit)
                    if let onSubmit = fNode.el.handlers.onTextSubmit {
                        var tx = Tx()
                        onSubmit(&state, edit.text, &tx)
                        applyTx(tx, at: now)
                        dirtyCommit(at: now)
                        return true
                    }
                    // Without `onTextSubmit`, let Return fall through to `.defaultButton()` if one exists.
                case .copy(let copied):
                    editLens.set(&state, edit)
                    clipboard = ClipboardContent(copied)
                    if let onChange = fNode.el.handlers.onTextChange {
                        var tx = Tx()
                        onChange(&state, edit.text, &tx)
                        applyTx(tx, at: now)
                    }
                    dirtyCommit(at: now)
                    return true
                }
            }

            // Space activates non-input focused controls; Enter activates rows/links (`takesReturn`) or falls back when no `.defaultButton()` exists.
            let takesReturn = fNode.el.role == .listItem || fNode.el.role == .option ||
                fNode.el.role == .treeItem || fNode.el.role == .menuItem ||
                fNode.el.role == .link || fNode.el.role == .row ||
                fNode.el.role == .gridCell || fNode.el.focusHighlightColor != nil
            if fNode.el.handlers.editLens == nil && ev.mods == .none &&
               (ev.key == .space || (ev.key == .enter && (takesReturn || defaultButtonNode() == nil))) {
                if isRepeat { return true }
                if let onClick = fNode.el.handlers.onClick {
                    focusVisible = true
                    var tx = Tx()
                    onClick(&state, &tx)
                    applyTx(tx, at: now)
                    return true
                }
                if let onClickPress = fNode.el.handlers.onClickPress {
                    focusVisible = true
                    let r = presentedRectByPath[fNode.path] ?? fNode.targetRect
                    let press = PointerPress(
                        window: Vec2(r.x + r.width * 0.5, r.y + r.height * 0.5),
                        local: Vec2(r.width * 0.5, r.height * 0.5),
                        elementSize: Vec2(r.width, r.height),
                        button: .primary,
                        mods: .none,
                        clicks: 1
                    )
                    var tx = Tx()
                    onClickPress(&state, press, &tx)
                    applyTx(tx, at: now)
                    return true
                }
            }

            // Arrow-key roving inside `.focusGroup()` ancestor!
            if ev.mods == .none,
               (ev.key == .arrowRight || ev.key == .arrowDown || ev.key == .arrowLeft || ev.key == .arrowUp),
               let groupIdx = findFocusGroupAncestor(of: fIdx) {
                let forward = (ev.key == .arrowRight || ev.key == .arrowDown)
                if moveFocusInGroup(groupIndex: groupIdx, forward: forward) {
                    focusVisible = true
                    dirtyCommit(at: now)
                    return true
                }
            }
        }

        // 2b. Unhandled Escape inside an active modal blurs focus and dismisses the innermost modal
        // (blocking key repeat so held Escape never cascades through stacked modals).
        if ev.key == .escape, let mPath = activeModalPath, let mIdx = nodeByPath[mPath] {
            if isRepeat {
                return true
            }
            focusedPath = nil
            focusedKey = nil
            syncedEditFocusedPaths.removeAll()
            if let dismiss = flatNodes[mIdx].el.handlers.modalDismiss {
                var tx = Tx()
                dismiss(&state, &tx)
                applyTx(tx, at: now)
            }
            dirtyCommit(at: now)
            return true
        }

        // 3. Tab / Shift+Tab focus ring traversal (trapped inside `.modal()` automatically via `effectiveInert`!)
        if ev.key == .tab && !ev.mods.ctrl && !ev.mods.alt && !ev.mods.cmd {
            if advanceTabFocus(backward: ev.mods.shift) {
                focusVisible = true
                dirtyCommit(at: now)
                return true
            }
        }

        // 3b. Default button activation on unmodified Return when no control consumed it
        if ev.key == .enter && ev.mods == .none && !isRepeat,
           let defNode = defaultButtonNode() {
            if let onClick = defNode.el.handlers.onClick {
                var tx = Tx()
                onClick(&state, &tx)
                applyTx(tx, at: now)
                return true
            }
            if let onClickPress = defNode.el.handlers.onClickPress {
                let r = presentedRectByPath[defNode.path] ?? defNode.targetRect
                let press = PointerPress(
                    window: Vec2(r.x + r.width * 0.5, r.y + r.height * 0.5),
                    local: Vec2(r.width * 0.5, r.height * 0.5),
                    elementSize: Vec2(r.width, r.height),
                    button: .primary,
                    mods: .none,
                    clicks: 1
                )
                var tx = Tx()
                onClickPress(&state, press, &tx)
                applyTx(tx, at: now)
                return true
            }
        }

        // 4. Root / global `onKey` handler (only when no active modal blocks background shortcuts)
        if activeModalPath == nil, let globalOnKey {
            var tx = Tx()
            if globalOnKey(&state, ev, &tx) {
                applyTx(tx, at: now)
                return true
            }
        }

        return false
    }

    public func paste(_ content: ClipboardContent, at now: Double) {
        clipboard = content
        richClipboard = RichClipboardPayload(content: content)
        guard let fPath = focusedPath,
              let fIdx = nodeByPath[fPath],
              let editLens = flatNodes[fIdx].el.handlers.editLens else {
            return
        }
        var edit = editLens.get(state)
        edit.paste(content.text)
        editLens.set(&state, edit)
        if let onChange = flatNodes[fIdx].el.handlers.onTextChange {
            var tx = Tx()
            onChange(&state, edit.text, &tx)
            applyTx(tx, at: now)
        }
        dirtyCommit(at: now)
    }

    // MARK: - JSON Element Tree Snapshot (`--tree`)

    public func treeJSON(realTime: Double? = nil) -> [String: Any] {
        func r2(_ v: Float) -> Double {
            (Double(v) * 100.0).rounded() / 100.0
        }

        let els: [[String: Any]] = lastElements.map { e in
            var obj: [String: Any] = [
                "path": e.path,
                "role": e.role.rawValue,
                "rect": e.rect.map(r2),
                "opacity": (Double(e.opacity) * 1000.0).rounded() / 1000.0,
                "scale": (Double(e.scale) * 10000.0).rounded() / 10000.0,
                "blur": r2(e.blur),
                "focusable": e.focusable,
                "focused": e.focused,
                "focusVisible": e.focusVisible,
                "inert": e.inert,
                "fill": e.fill.hexString(),
            ]
            if let k = e.key { obj["key"] = k }
            if let l = e.label { obj["label"] = l }
            if let t = e.text { obj["text"] = t }
            if let c = e.textColor { obj["color"] = c.hexString() }
            if let h = e.help { obj["help"] = h }
            if let s = e.selected { obj["selected"] = s }
            if let lv = e.level { obj["level"] = lv }
            if let ex = e.expanded { obj["expanded"] = ex }
            if e.itemSelected { obj["itemSelected"] = true }
            if e.secure { obj["secure"] = true }
            if e.disabled { obj["disabled"] = true }
            if let ch = e.checked { obj["checked"] = ch.rawValue }
            if let av = e.a11yValue { obj["a11yValue"] = av }
            if let ad = e.a11yDescription { obj["description"] = ad }
            if e.a11yHidden { obj["a11yHidden"] = true }
            if zip(e.rect, e.target).contains(where: { abs($0 - $1) > 0.01 }) {
                obj["target"] = e.target.map(r2)
            }
            if e.moving { obj["moving"] = true }
            if e.exiting { obj["exiting"] = true }
            if e.hover > 0.001 { obj["hover"] = r2(e.hover) }
            if e.press > 0.001 { obj["press"] = r2(e.press) }
            if let caret = e.caret { obj["caret"] = caret.map(r2) }
            if let v = lastVideoSnapshots[e.path] {
                let (vState, vErr): (String, String?)
                switch v.state {
                case .loading: (vState, vErr) = ("loading", nil)
                case .ready: (vState, vErr) = ("ready", nil)
                case .playing: (vState, vErr) = ("playing", nil)
                case .ended: (vState, vErr) = ("ended", nil)
                case .failed(let msg): (vState, vErr) = ("failed", msg)
                }
                var vObj: [String: Any] = [
                    "kind": v.kind.rawValue,
                    "state": vState,
                    "time": (v.time * 1000.0).rounded() / 1000.0,
                    "rate": v.rate,
                    "looping": v.looping,
                    "muted": v.muted,
                ]
                if let dur = v.duration {
                    vObj["duration"] = (dur * 1000.0).rounded() / 1000.0
                }
                if let sz = v.size {
                    vObj["size"] = [sz.0, sz.1]
                }
                if let vErr {
                    vObj["error"] = vErr
                }
                obj["video"] = vObj
            }
            return obj
        }

        var out: [String: Any] = [
            "t": realTime ?? currentTime,
            "anim_t": currentTime,
            "viewport": [r2(viewport.x), r2(viewport.y)],
            "scale": r2(pixelScale),
            "dark_system": systemDark,
            "reduced_motion": reducedMotion,
            "animating": isAnimating,
            "elements": els,
            "warnings": keyWarnings,
        ]
        if let title = windowTitle {
            out["title"] = title
        }
        if let popup = popupJSONObject() {
            out["popupMenu"] = popup
        }
        if let dialog = fileDialogJSONObject() {
            out["fileDialog"] = dialog
        }
        return out
    }

    /// JSON representation of the currently open or queued popup menu for `--tree`.
    public func popupJSON() -> [String: Any]? {
        popupJSONObject()
    }

    /// JSON representation of the currently requested or showing file dialog for `--tree`.
    public func fileDialogJSON() -> [String: Any]? {
        fileDialogJSONObject()
    }

    public func treeJSONData(pretty: Bool = true, realTime: Double? = nil) throws -> Data {
        let opts: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try JSONSerialization.data(withJSONObject: treeJSON(realTime: realTime), options: opts)
    }

    /// Delivers an inbound OS file-drop event (`entered`, `hovered`, `dropped`, `exited`).
    public func fileDrop(_ phase: FileDropPhase, at now: Double) {
        currentTime = now
        fileDropState.handle(phase)
        flightRecorder.record(kind: "fileDrop", at: now)
        routeFileDropPhase(phase, at: now)
        if let handler = onFileDrop {
            var tx = Tx()
            handler(&state, phase, &tx)
            applyTx(tx, at: now)
            if !tx.liveOnlyRequested {
                dirtyCommit(at: now)
            }
        }
    }

    /// Returns and clears any URL open requests queued in headless mode.
    public func takeUrlRequests() -> [OpenUrlRequest] {
        urlOpener.takeRequests()
    }

    /// Returns and clears queued playground requests recorded via `Tx`.
    public func takePlaygroundRequests() -> [PlaygroundTxRequest] {
        let out = playgroundRequests
        playgroundRequests.removeAll()
        return out
    }

    /// Records the current keyed elements into `rewindRecorder` if attached.
    public func captureRewindFrame(at now: Double) {
        guard let rewind = rewindRecorder else { return }
        rewind.setViewport(viewport)
        let snapshots: [RewindElementSnapshot]
        if !lastElements.isEmpty {
            snapshots = lastElements.compactMap { el -> RewindElementSnapshot? in
                guard let key = el.key, !key.hasPrefix("rewind"), el.rect.count >= 4 else { return nil }
                return RewindElementSnapshot(
                    key: key,
                    rect: MotionRect.fromXYWH(el.rect[0], el.rect[1], el.rect[2], el.rect[3]),
                    opacity: el.opacity
                )
            }
        } else {
            snapshots = flatNodes.compactMap { node -> RewindElementSnapshot? in
                guard let key = node.key, !key.hasPrefix("rewind") else { return nil }
                return RewindElementSnapshot(
                    key: key,
                    rect: node.targetRect,
                    opacity: node.el.opacity
                )
            }
        }
        rewind.recordFrame(at: now, elements: snapshots)
    }

    // MARK: - Private Helpers

    internal func applyTx(_ tx: Tx, at now: Double, markDirtyIfNotLiveOnly: Bool = true) {
        if let cb = tx.clipboardWrite {
            clipboard = cb
            richClipboard = RichClipboardPayload(content: cb)
        }
        if let rich = tx.runtimeActions["richClipboardWrite"] as? RichClipboardPayload {
            richClipboard = rich
            clipboard = rich.content
        }
        if let urls = tx.runtimeActions["openUrlRequests"] as? [OpenUrlRequest] {
            for req in urls {
                _ = try? urlOpener.open(req.url, sameTab: req.sameTab)
            }
        }
        if let drag = tx.runtimeActions["dragOutItem"] as? DragItem {
            fileDropState.recordOutboundDrag(drag)
            let bounds: MotionRect
            let key: String?
            if let path = pressedPath ?? hoveredPath, let idx = nodeByPath[path] {
                bounds = presentedRectByPath[path] ?? flatNodes[idx].targetRect
                key = flatNodes[idx].key
            } else {
                bounds = .fromXYWH(pointerPosition.x, pointerPosition.y, 1, 1)
                key = nil
            }
            pendingDragOutStart = DragOutStart(item: drag, bounds: bounds, press: pointerPosition, key: key)
        }
        if let actions = tx.runtimeActions["erasedActions"] as? [ErasedRuntimeAction] {
            for action in actions {
                switch action {
                case .popup(let req):
                    enqueuePopupRequest(req)
                    if !tx.liveOnlyRequested {
                        popupNeedsLayout = true
                    }
                case .fileDialog(let req):
                    requestFileDialog(req, at: now)
                }
            }
        }
        if let rewind = tx.runtimeActions["rewindRecorder"] as? RewindRecorder {
            rewindRecorder = rewind
            rewind.setViewport(viewport)
        } else if (tx.runtimeActions["detachRewind"] as? Bool) == true {
            rewindRecorder = nil
        }
        if let pgReqs = tx.runtimeActions["playgroundRequests"] as? [PlaygroundTxRequest] {
            playgroundRequests.append(contentsOf: pgReqs)
            if let pg = playgroundHost, pg.isEnabled {
                for req in pgReqs {
                    switch req {
                    case .open:
                        pg.open()
                    case let .openAt(story, variant):
                        do {
                            try pg.openAt(story: story, variant: variant)
                            if let fresh = pg.freshTransform {
                                state = fresh(state)
                            }
                            if let v = pg.currentVariant {
                                v.apply(&state)
                            }
                            dirtyCommit(at: now)
                        } catch {
                            pg.open()
                        }
                    case .close:
                        pg.close()
                    case .replay:
                        var followTx = Tx()
                        pg.replay(on: &state, tx: &followTx)
                        applyTx(followTx, at: now, markDirtyIfNotLiveOnly: markDirtyIfNotLiveOnly)
                    case .trigger(let ch):
                        var followTx = Tx()
                        if pg.fireTrigger(ch, on: &state, tx: &followTx) {
                            applyTx(followTx, at: now, markDirtyIfNotLiveOnly: markDirtyIfNotLiveOnly)
                        }
                    }
                }
            }
        }
        if let title = tx.windowTitle {
            windowTitle = title
        }
        if let srgb = tx.srgbBlendRequest, srgb != srgbBlend {
            srgbBlend = srgb
            dirtyCommit(at: now)
        }
        if let smoothing = tx.fontSmoothingRequest, smoothing != fontSmoothing {
            fontSmoothing = smoothing
            dirtyCommit(at: now)
        }
        if tx.isCloseWindowRequested {
            closeWindowRequested = true
        }
        if tx.isMinimizeRequested {
            minimizeRequested = true
        }
        if tx.isRelaunchRequested {
            relaunchRequested = true
        }
        if let wakeAfter = tx.wakeAfterSeconds {
            let candidate = now + wakeAfter
            nextWakeDeadline = min(nextWakeDeadline ?? candidate, candidate)
        }
        if tx.quitRequested {
            quitRequested = true
        }
        if (tx.runtimeActions["relaunchRequested"] as? Bool) == true {
            relaunchRequested = true
            quitRequested = true
        }
        if tx.blurFocusRequested {
            pendingTxBlurRequested = true
            pendingTxFocusKey = nil
            focusedPath = nil
            focusedKey = nil
            syncedEditFocusedPaths.removeAll()
        } else if let fk = tx.requestedFocusKey {
            pendingTxBlurRequested = false
            pendingTxFocusKey = fk
            focusedKey = fk
            if let match = flatNodes.first(where: { $0.key == fk }) {
                focusedPath = match.path
            }
        }
        for req in tx.scrollToRequests {
            if let match = flatNodes.first(where: { $0.key == req.key }) {
                let maxExt = scrollMaxExtents[match.path] ?? .zero
                let clamped = Vec2(req.offset.x.clamped(to: 0...maxExt.x), req.offset.y.clamped(to: 0...maxExt.y))
                scrollOffsets[match.path] = clamped
                let nid = NodeId.hash("scroll:" + match.path)
                if req.animated {
                    scrollStore.set(nid, Props.SCROLL, to: clamped, anim: .spring(MotionTokens.SETTLE), at: cxSettings.scaledTime(at: now))
                } else {
                    scrollStore.snap(nid, Props.SCROLL, to: clamped)
                }
            }
        }
        if tx.settleRequested {
            forceInitialSettle = true
        }
        if !tx.liveOnlyRequested && (markDirtyIfNotLiveOnly || tx.isForceCommitRequested) {
            dirtyCommit(at: now)
        }
    }

    // MARK: - App Shell Lifecycle & State Update Helpers

    /// True when the view tree needs a rebuild before the next frame (`Runtime::stale`).
    public var isStale: Bool { needsCommit }

    /// Runs `poll(state, now, tx)` when attached. Only dirties the commit if `poll` returns `true`
    /// or `tx.commit()` was explicitly called.
    @discardableResult
    public func runPoll(at now: Double) -> Bool {
        guard let pollFn = poll else { return false }
        var tx = Tx()
        let changed: Bool
        if let scope = turnScope {
            var res = false
            scope(&state) { s in
                res = pollFn(&s, now, &tx)
            }
            changed = res
        } else {
            changed = pollFn(&state, now, &tx)
        }
        let shouldDirty = changed || tx.isForceCommitRequested
        applyTx(tx, at: now, markDirtyIfNotLiveOnly: shouldDirty)
        return changed
    }

    /// Mutates state via `body`, always rebuilding unless `tx.liveOnlyRequested` is true.
    public func update(at now: Double? = nil, _ body: (_ state: inout State, _ tx: inout Tx) -> Void) {
        let t = now ?? currentTime
        var tx = Tx()
        if let scope = turnScope {
            scope(&state) { s in body(&s, &tx) }
        } else {
            body(&state, &tx)
        }
        applyTx(tx, at: t, markDirtyIfNotLiveOnly: true)
    }

    /// Conditionally mutates state via `body`. Only dirties commit when `body` returns `true`
    /// or `tx.commit()` was explicitly called; side-effect requests (`wakeAfter`, `copy`, `quit`,
    /// etc.) still apply without forcing a rebuild (`app.rs:1240-1251`).
    @discardableResult
    public func updateIf(at now: Double? = nil, _ body: (_ state: inout State, _ tx: inout Tx) -> Bool) -> Bool {
        let t = now ?? currentTime
        var tx = Tx()
        let changed: Bool
        if let scope = turnScope {
            var res = false
            scope(&state) { s in res = body(&s, &tx) }
            changed = res
        } else {
            changed = body(&state, &tx)
        }
        applyTx(tx, at: t, markDirtyIfNotLiveOnly: changed || tx.isForceCommitRequested)
        return changed
    }

    /// Sets `srgbBlend` and dirties the tree if changed.
    public func setSrgbBlend(_ enabled: Bool, at now: Double? = nil) {
        guard srgbBlend != enabled else { return }
        srgbBlend = enabled
        dirtyCommit(at: now ?? currentTime)
    }

    /// Delivers a window focus transition to `onFocus`, deduplicating redundant transitions and
    /// leaving the runtime un-staled when `onFocus` is unset (`app.rs:973-992`).
    public func dispatchFocus(_ focused: Bool, at now: Double? = nil) {
        guard windowFocused != focused else { return }
        let t = now ?? currentTime
        let prevStale = needsCommit
        windowFocused = focused
        if let hook = onFocus {
            update(at: t) { s, tx in hook(&s, focused, &tx) }
        } else {
            needsCommit = prevStale
        }
    }

    public func dispatchModifiers(_ mods: Mods, at now: Double? = nil) {
        guard let hook = onModifiers else { return }
        updateIf(at: now) { s, tx in
            hook(&s, mods, &tx)
            return false
        }
    }

    public func dispatchVisibility(_ visible: Bool, at now: Double? = nil) {
        guard let hook = onVisibility else { return }
        update(at: now) { s, tx in hook(&s, visible, &tx) }
    }

    @discardableResult
    public func dispatchIme(_ ime: Ime, at now: Double? = nil) -> Bool {
        guard let hook = onIme else { return false }
        return updateIf(at: now) { s, tx in hook(&s, ime, &tx) }
    }

    /// Runs `onClose`; returns `true` if closing is allowed (defaults to `true` when unset).
    public func dispatchClose(at now: Double? = nil) -> Bool {
        guard let hook = onClose else { return true }
        var allow = true
        updateIf(at: now) { s, tx in
            allow = hook(&s, &tx)
            return true
        }
        return allow
    }

    public func dispatchQuit(at now: Double? = nil) {
        guard let hook = onQuit else { return }
        updateIf(at: now) { s, tx in
            hook(&s, &tx)
            return false
        }
    }

    @discardableResult
    public func dispatchReopen(hasVisibleWindows: Bool, at now: Double? = nil) -> Bool {
        guard let hook = onReopen else { return false }
        var handled = false
        updateIf(at: now) { s, tx in
            handled = hook(&s, hasVisibleWindows, &tx)
            return handled
        }
        return handled
    }

    public func dispatchOpenUrl(_ url: String, at now: Double? = nil) {
        guard let hook = onOpenUrl else { return }
        update(at: now) { s, tx in hook(&s, url, &tx) }
    }

    public func clearShellRequests() {
        closeWindowRequested = false
        minimizeRequested = false
        relaunchRequested = false
        nextWakeDeadline = nil
    }

    private func advanceTabFocus(backward: Bool) -> Bool {
        let restrictToInputsAndLists = !cxSettings.fullKeyboardAccess && !tabVisitsControls
        let candidateIndices = tabOrderIndices().filter { idx in
            guard restrictToInputsAndLists else { return true }
            let node = flatNodes[idx]
            return node.el.handlers.editLens != nil ||
                node.el.role == .textInput ||
                node.el.handlers.onKey != nil ||
                findFocusGroupAncestor(of: idx) != nil
        }
        guard !candidateIndices.isEmpty else { return false }
        let nextIdx: Int
        if let curPath = focusedPath,
           let curPos = candidateIndices.firstIndex(where: { flatNodes[$0].path == curPath }) {
            let nextPos = backward
                ? (curPos - 1 + candidateIndices.count) % candidateIndices.count
                : (curPos + 1) % candidateIndices.count
            nextIdx = candidateIndices[nextPos]
        } else if cxSettings.viewDefaults.webFocus,
                  let startPath = webFocusTabStartPath,
                  let startIdx = flatNodes.firstIndex(where: { $0.path == startPath }) {
            nextIdx = backward
                ? (candidateIndices.last(where: { $0 < startIdx }) ?? candidateIndices.last!)
                : (candidateIndices.first(where: { $0 > startIdx }) ?? candidateIndices.first!)
        } else {
            nextIdx = backward ? candidateIndices.last! : candidateIndices.first!
        }
        focusedPath = flatNodes[nextIdx].path
        focusedKey = flatNodes[nextIdx].key
        return true
    }

    private func defaultButtonNode() -> FlatNode? {
        flatNodes.indices.compactMap { idx -> FlatNode? in
            let node = flatNodes[idx]
            guard node.el.isDefaultButton && !node.effectiveInert && !node.el.a11yDisabled else { return nil }
            guard node.targetRect.width > 0 && node.targetRect.height > 0 else { return nil }
            var walk: Int? = idx
            while let cur = walk {
                if flatNodes[cur].el.opacity <= 0.001 || flatNodes[cur].el.isInert { return nil }
                walk = flatNodes[cur].parentIndex
            }
            return node
        }.first
    }

    private func findFocusGroupAncestor(of idx: Int) -> Int? {
        var cur: Int? = idx
        while let i = cur {
            if flatNodes[i].el.focusGroup {
                return i
            }
            cur = flatNodes[i].parentIndex
        }
        return nil
    }

    private func moveFocusInGroup(groupIndex: Int, forward: Bool) -> Bool {
        let prefix = flatNodes[groupIndex].path + "/"
        let members = flatNodes.indices.filter { i in
            (flatNodes[i].path == flatNodes[groupIndex].path || flatNodes[i].path.hasPrefix(prefix)) &&
            canFocusIndex(i)
        }
        guard members.count > 1,
              let curPath = focusedPath,
              let curIdx = members.firstIndex(where: { flatNodes[$0].path == curPath }) else {
            return false
        }
        let nextPos = forward
            ? (curIdx + 1) % members.count
            : (curIdx - 1 + members.count) % members.count
        let nextNode = flatNodes[members[nextPos]]
        focusedPath = nextNode.path
        focusedKey = nextNode.key
        return true
    }

    private func textHitOffset(node: FlatNode, windowPos: Vec2, edit: TextEdit) -> Int {
        var resolvedEdit = edit
        if node.el.isSecure {
            resolvedEdit.isSecure = true
            if node.el.isRevealed { resolvedEdit.isRevealed = true }
        }
        let rect = presentedRectByPath[node.path] ?? node.targetRect
        let sc = presentedScaleByPath[node.path] ?? Vec2(1, 1)
        let innerW = max(0, rect.width - (node.el.layout.padding.left + node.el.layout.padding.right) * sc.x)
        var hitStyle = node.el.textStyle
        if resolvedEdit.multiline { hitStyle.wrap = .wrap }
        let shaped = textSystem.shape(
            text: resolvedEdit.displayString,
            style: hitStyle,
            maxWidth: resolvedEdit.multiline ? innerW : nil,
            pixelScale: pixelScale,
            emitGlyphs: false
        )
        let localX = (windowPos.x - (rect.x + node.el.layout.padding.left * sc.x)) / max(0.01, sc.x)
        let localY = (windowPos.y - (rect.y + node.el.layout.padding.top * sc.y)) / max(0.01, sc.y)
        let hit = textSystem.hitTestUTF8Offset(in: shaped, localX: localX, localY: localY, pixelScale: pixelScale)
        if resolvedEdit.isSecure {
            // Map bullet index (`•` is 3 UTF-8 bytes) back to underlying grapheme index!
            let charIdx = max(0, hit / 3)
            var byteCount = 0
            for (i, ch) in resolvedEdit.text.enumerated() {
                if i >= charIdx { break }
                byteCount += ch.utf8.count
            }
            return byteCount
        }
        return resolvedEdit.snapToGraphemeBoundary(hit)
    }

    // MARK: - Tooltips (`El.help` + `HelpLook`)

    /// Visible unoccluded help regions `[x0, y0, x1, y1]` + normalized text in paint order for native hosts.
    public func helpRegions() -> [(rect: SIMD4<Float>, text: String)] {
        helpState.regions
    }

    /// Currently shown Rune-drawn tooltip text and frame `[x, y, w, h]` in window points.
    public func helpTooltip() -> (text: String, rect: SIMD4<Float>)? {
        helpState.currentTip
    }

    /// Returns true when moving pointer to `pos` changes the hovered help element (or leaves one).
    public func helpTargetChanges(at pos: Vec2) -> Bool {
        let target = helpState.tipState.target
        if useNativeHelp || (helpState.hits.isEmpty && target == nil) { return false }
        let at = helpAt(point: pos).map { ($0.hit.path, $0.hit.linkIndex) }
        if let at, let target {
            return at.0 != target.path || at.1 != target.link
        }
        return (at != nil) != (target != nil)
    }

    private var useNativeHelp: Bool {
        nativeHelp && viewHelpLook == nil
    }

    private func currentHelpLook() -> HelpLook {
        viewHelpLook ?? HelpLook.system(dark: systemDark)
    }

    private func currentHelpDelays() -> (open: Double, skip: Double) {
        let look = currentHelpLook()
        return (look.delaySeconds ?? helpDelay, look.skipSeconds)
    }

    private func tooltipFading(at now: Double) -> Bool {
        guard !reducedMotion else { return false }
        let look = currentHelpLook()
        if case .open(_, let since) = helpState.tipState, now < since + look.fadeEnter {
            return true
        }
        if let (_, closedAt) = helpState.leaving, now < closedAt + look.fadeExit {
            return true
        }
        return false
    }

    private func dismissHelp(at now: Double) {
        if helpState.tipState.target != nil {
            stepHelpState(event: .dismiss, at: now)
        }
    }

    private func pressHelp(at pos: Vec2, now: Double) {
        let onOpen: Bool
        if case .open(let target, _) = helpState.tipState,
           let at = helpAt(point: pos) {
            onOpen = (at.hit.path == target.path && at.hit.linkIndex == target.link)
        } else {
            onOpen = false
        }
        if !onOpen || viewHelpLook == nil {
            dismissHelp(at: now)
        }
    }

    private func stepHelpState(event: HelpStepEvent, at now: Double) {
        let delays = currentHelpDelays()
        for effect in stepHelpTip(&helpState.tipState, event: event, openDelay: delays.open, skipDelay: delays.skip) {
            switch effect {
            case .wakeAt:
                break
            case .fadeOut:
                helpState.currentTip = nil
                let look = currentHelpLook()
                let fades = look.fadeExit > 0.0 && !reducedMotion
                if fades, let drawn = helpState.drawn {
                    helpState.leaving = (drawn, now)
                } else {
                    helpState.leaving = nil
                }
                helpState.drawn = nil
            }
        }
    }

    private func helpContains(_ hit: HelpHitRecord, point: Vec2) -> Bool {
        if let geom = hitGeometryByPath[hit.path] {
            return geom.contains(point)
        }
        return helpRectContains(hit.rect, point: point)
    }

    private func helpUnder(point: Vec2) -> (hit: HelpHitRecord, nodeIndex: Int, reaches: Bool)? {
        guard let hit = helpState.hits.last(where: { helpContains($0, point: point) }),
              let hIdx = nodeByPath[hit.path] else {
            return nil
        }
        let hNode = flatNodes[hIdx]
        guard !hNode.effectiveInert else {
            return (hit, hIdx, false)
        }
        let prefix = hit.path + "/"
        let covered = helpState.interactiveHits.dropFirst(min(hit.seq, helpState.interactiveHits.count)).contains { inter in
            guard !(inter.path == hit.path || inter.path.hasPrefix(prefix)) else { return false }
            if let geom = hitGeometryByPath[inter.path] {
                return geom.contains(point)
            }
            return helpRectContains(inter.rect, point: point)
        }
        return (hit, hIdx, !covered)
    }

    private func helpAt(point: Vec2) -> (hit: HelpHitRecord, nodeIndex: Int)? {
        guard let u = helpUnder(point: point), u.reaches else { return nil }
        return (u.hit, u.nodeIndex)
    }

    private func unoccludedHelpParts(for hit: HelpHitRecord) -> [SIMD4<Float>] {
        var parts = [hit.rect]
        let prefix = hit.path + "/"
        for inter in helpState.interactiveHits.dropFirst(min(hit.seq, helpState.interactiveHits.count)) {
            guard !(inter.path == hit.path || inter.path.hasPrefix(prefix)) else { continue }
            guard parts.contains(where: { helpRectOverlaps($0, inter.rect) }) else { continue }
            parts = parts.flatMap { helpRectSubtract($0, inter.rect) }
            if parts.isEmpty { break }
        }
        return parts
    }

    private func updateHelp(at now: Double, primitives: inout [Primitive]) {
        helpState.regions.removeAll(keepingCapacity: true)
        if useNativeHelp {
            var regions: [(SIMD4<Float>, String)] = []
            for hit in helpState.hits {
                guard let idx = nodeByPath[hit.path], !flatNodes[idx].effectiveInert else { continue }
                let words = runeHelpWords(hit.text)
                for part in unoccludedHelpParts(for: hit) {
                    regions.append((part, words))
                }
            }
            helpState.regions = regions
            helpState.currentTip = nil
            helpState.tipState = .idle
            helpState.drawn = nil
            helpState.leaving = nil
            return
        }

        let inViewport = pointerPosition.x >= 0 && pointerPosition.x < viewport.x &&
                         pointerPosition.y >= 0 && pointerPosition.y < viewport.y
        let over: HelpOver
        let underHit: HelpHitRecord?
        if !inViewport {
            over = .away
            underHit = nil
        } else if let u = helpUnder(point: pointerPosition) {
            let target = HelpTarget(path: u.hit.path, link: u.hit.linkIndex)
            if activeDrag != nil && helpState.tipState.target != target {
                over = .nothing
                underHit = nil
            } else if u.reaches {
                over = .help(target)
                underHit = u.hit
            } else {
                over = .covered(target)
                underHit = nil
            }
        } else {
            over = .nothing
            underHit = nil
        }

        stepHelpState(event: .frame(over: over, now: now), at: now)
        helpState.currentTip = nil
        let look = currentHelpLook()
        let motion = !reducedMotion

        if let (leavingDrawn, closedAt) = helpState.leaving {
            let t: Float = (motion && look.fadeExit > 0.0) ? Float((now - closedAt) / look.fadeExit) : 1.0
            if t < 1.0 {
                let eased = Easing.easeIn.sample(min(1.0, max(0.0, t)))
                var fadeDrawn = leavingDrawn
                fadeDrawn.alpha = leavingDrawn.alpha * (1.0 - eased)
                fadeDrawn.scale = leavingDrawn.scale + (look.fadeScale - leavingDrawn.scale) * eased
                _ = drawHelpTooltip(
                    fadeDrawn,
                    look: look,
                    viewport: viewport,
                    pixelScale: pixelScale,
                    srgbBlend: srgbBlend,
                    systemDark: systemDark,
                    textSystem: textSystem,
                    primitives: &primitives
                )
            } else {
                helpState.leaving = nil
            }
        }

        helpState.drawn = nil
        if case .open(let target, let since) = helpState.tipState {
            let matchedHit = underHit ?? helpState.hits.last(where: { $0.path == target.path && $0.linkIndex == target.link })
            if let hit = matchedHit, let idx = nodeByPath[hit.path] {
                let anchorBox = presentedRectByPath[hit.path] ?? flatNodes[idx].targetRect
                let anchor4 = SIMD4<Float>(
                    anchorBox.x,
                    anchorBox.y,
                    anchorBox.x + anchorBox.width,
                    anchorBox.y + anchorBox.height
                )
                let t: Float = (motion && look.fadeEnter > 0.0) ? Float((now - since) / look.fadeEnter) : 1.0
                let eased = Easing.easeOut.sample(min(1.0, max(0.0, t)))
                let drawn = HelpDrawnTip(
                    text: hit.text,
                    anchor: anchor4,
                    side: hit.side,
                    alpha: eased,
                    scale: look.fadeScale + (1.0 - look.fadeScale) * eased
                )
                let tipRect = drawHelpTooltip(
                    drawn,
                    look: look,
                    viewport: viewport,
                    pixelScale: pixelScale,
                    srgbBlend: srgbBlend,
                    systemDark: systemDark,
                    textSystem: textSystem,
                    primitives: &primitives
                )
                helpState.currentTip = (runeHelpWords(drawn.text), tipRect)
                helpState.drawn = drawn
            }
        }
    }
}

@inline(__always)
private func intersectRects(_ a: MotionRect, _ b: MotionRect) -> MotionRect {
    let l = max(a.left, b.left)
    let t = max(a.top, b.top)
    let r = max(l, min(a.right, b.right))
    let bot = max(t, min(a.bottom, b.bottom))
    return MotionRect(left: l, top: t, right: r, bottom: bot)
}

@inline(__always)
private func snapBorderWidthPx(_ widthPt: Float, scale: Float) -> Float {
    if widthPt <= 0 { return 0 }
    let raw = widthPt * scale
    return raw < 1.0 ? 1.0 : raw.rounded()
}

@inline(__always)
private func blendColorOver(bottom: Color, top: Color) -> Color {
    let ta = top.a.clamped(to: 0...1)
    let ba = bottom.a.clamped(to: 0...1)
    let outA = ta + ba * (1.0 - ta)
    if outA <= 1e-5 { return .transparent }
    let r = (top.r * ta + bottom.r * ba * (1.0 - ta)) / outA
    let g = (top.g * ta + bottom.g * ba * (1.0 - ta)) / outA
    let b = (top.b * ta + bottom.b * ba * (1.0 - ta)) / outA
    return Color(r: r, g: g, b: b, a: outA)
}
