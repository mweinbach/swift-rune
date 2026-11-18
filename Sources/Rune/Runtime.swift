import Foundation
#if os(Android)
import Android
#endif
import RuneMotion
import RuneRef
#if canImport(simd)
import simd
#endif

/// Child arrays are immutable snapshots during flattening. Referencing an element in its
/// existing array avoids a second allocation and copy of the declarative tree per flat node.
internal struct FlatElement<State> {
    private var siblings: ContiguousArray<El<State>>
    private var index: Int

    init(_ siblings: ContiguousArray<El<State>>, at index: Int) {
        self.siblings = siblings
        self.index = index
    }

    init(_ element: El<State>) { self.init([element], at: 0) }

    @inline(__always) var value: El<State> {
        _read {
            // The native buffer's span borrows the slot without copying its large element.
            yield siblings.span[index]
        }
        _modify {
            detachFromSiblings()
            yield &siblings[index]
        }
    }

    var hasSiblings: Bool { siblings.count > 1 }

    mutating func detachFromSiblings() {
        if hasSiblings {
            siblings = [siblings[index]]
            index = 0
        }
    }
}

private struct FlightCoverTransform {
    var targetOrigin: Vec2
    var presentedOrigin: Vec2
    var scale: Float
}

internal enum PaintScaleMotion: Int, Comparable {
    case still = 0
    case live = 1
    case moving = 2

    static func < (lhs: PaintScaleMotion, rhs: PaintScaleMotion) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    func raster(sc: Float, rest: Float) -> Float {
        let k: Float
        switch self {
        case .still: k = sc
        case .live: k = powf(2.0, (log2(max(1e-4, sc)) * 4.0).rounded() * 0.25)
        case .moving: k = rest
        }
        return (k >= 1.0 / 16.0 && k <= 4.0) ? k : 1.0
    }
}

internal struct PresentedTransform {
    var dx: Float = 0
    var dy: Float = 0
    var anchor: Vec2 = .zero
    var anchorTo: Vec2 = .zero
    var scale: Vec2 = Vec2(1, 1)
    var stillScale: Float = 1
    static let identity = PresentedTransform()
}

/// Trace namespace metadata `(className, host)` attached via `El.traceNamespace`.
public struct TraceNamespace: Sendable, Equatable {
    public var className: String
    public var host: String

    public init(className: String, host: String) {
        self.className = className
        self.host = host
    }
}

/// Reasons the last frame reported `isAnimating == true`, mirroring `rune::runtime::AnimSource`.
public enum AnimSource {
    public static let tracks: UInt32 = 1 << 0
    public static let growth: UInt32 = 1 << 1
    public static let scroll: UInt32 = 1 << 2
    public static let reveal: UInt32 = 1 << 3
    public static let loop: UInt32 = 1 << 4
    public static let scaleSettle: UInt32 = 1 << 5
    public static let video: UInt32 = 1 << 6
    public static let textFlight: UInt32 = 1 << 7
    public static let live: UInt32 = 1 << 8
    public static let virtualFill: UInt32 = 1 << 9
    /// A long paste's waiting paragraphs being shaped a few a frame (`TEXT_FILL`, `text_fill.rs`).
    public static let textFill: UInt32 = 1 << 10

    private static let allNames: [String] = [
        "tracks", "growth", "scroll", "reveal", "loop",
        "scale-settle", "video", "text-flight", "live", "virtual-fill", "text-fill",
    ]

    public static func names(_ bits: UInt32) -> [String] {
        var out: [String] = []
        for (i, name) in allNames.enumerated() where (bits & (1 << UInt32(i))) != 0 {
            out.append(name)
        }
        return out
    }
}

/// The renderer already has these three boxes. Keep them inline until a reader needs arrays.
internal enum ElementInfoGeometry: Sendable, Equatable {
    case boxes(rect: MotionRect, target: MotionRect, visible: MotionRect)
    case arrays(rect: [Float], target: [Float], visible: [Float])

    var rect: [Float] {
        switch self {
        case .boxes(let value, _, _): value.xywh
        case .arrays(let value, _, _): value
        }
    }

    var target: [Float] {
        switch self {
        case .boxes(_, let value, _): value.xywh
        case .arrays(_, let value, _): value
        }
    }

    var visible: [Float] {
        switch self {
        case .boxes(_, _, let value): value.xywh
        case .arrays(_, _, let value): value
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        if case let .boxes(a, b, c) = lhs, case let .boxes(x, y, z) = rhs {
            // Reversed edges expose zero width or height in the public geometry.
            func equalBox(_ a: MotionRect, _ b: MotionRect) -> Bool {
                a.origin == b.origin && a.size == b.size
            }
            return equalBox(a, x) && equalBox(b, y) && equalBox(c, z)
        }
        return lhs.rect == rhs.rect && lhs.target == rhs.target && lhs.visible == rhs.visible
    }
}

/// Snapshot of a mounted or exiting UI element exposed to tests, accessibility, and `--tree` JSON.
public struct ElementInfo: Sendable, Equatable {
    public var path: String
    public var key: String?
    public var parentIndex: Int?
    public var role: ElementRole
    internal var geometry: ElementInfoGeometry
    /// Presented `[x, y, width, height]` in logical window points.
    public var rect: [Float] {
        get { geometry.rect }
        set { geometry = .arrays(rect: newValue, target: target, visible: visible) }
    }
    /// Unsnapped layout target `[x, y, width, height]` in logical window points.
    public var target: [Float] {
        get { geometry.target }
        set { geometry = .arrays(rect: rect, target: newValue, visible: visible) }
    }
    /// The committed layout box before scrolling or growth reveal, as reported by the headless tree.
    internal var committedLayoutTarget: MotionRect? = nil
    /// Visible clipped `[x, y, width, height]` in logical window points.
    public var visible: [Float] {
        get { geometry.visible }
        set { geometry = .arrays(rect: rect, target: target, visible: newValue) }
    }
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
    /// The active modal or one of its window controls is reachable through this inert ancestor.
    internal var modalAncestor: Bool = false
    public var moving: Bool
    public var exiting: Bool
    public var hover: Float
    public var press: Float
    public var scrolled: [Float]
    internal var carriedScrolled: [Float] = [0, 0]
    public var caret: [Float]?
    public var secure: Bool = false
    public var disabled: Bool = false
    public var checked: A11yChecked? = nil
    public var a11yValue: String? = nil
    public var a11yDescription: String? = nil
    public var a11yHidden: Bool = false
    public var stuck: Float = 0.0
    public var traceName: String? = nil
    public var traceNamespace: TraceNamespace? = nil
    public var virtualExtent: Bool = false
    public var editRange: [Int]? = nil
    public var loopPhase: Double? = nil
    public var revealing: Bool = false
    public var inGrowingRow: Bool = false
    public var scrolling: Bool = false
    public var liveIntent: UInt32 = 0
    public var shapeKey: UInt64? = nil
    public var drawnText: String? = nil
    public var elision: TextElision? = nil
    /// What the assistive tree reads of the element's editor and stepper (`a11y/node.rs:31,231-240`).
    public var a11yInput: ElementA11yInput? = nil

    /// Synthetic text ranges share their owner's layout coordinate system.
    internal func committedTextTarget(_ box: MotionRect) -> MotionRect {
        guard let committedLayoutTarget else { return box }
        return box.translated(Vec2(committedLayoutTarget.x - target[0], committedLayoutTarget.y - target[1]))
    }

    public static func stub(_ key: String) -> ElementInfo {
        ElementInfo(
            path: "/0/@\(key)",
            key: key,
            parentIndex: 0,
            role: .group,
            geometry: .boxes(rect: .zero, target: .zero, visible: .zero),
            opacity: 1.0,
            scale: 1.0,
            blur: 0.0,
            radius: 0.0,
            fill: .transparent,
            textColor: nil,
            text: nil,
            label: nil,
            help: nil,
            selected: nil,
            expanded: nil,
            level: nil,
            itemSelected: false,
            focusable: false,
            focused: false,
            focusVisible: false,
            inert: false,
            moving: false,
            exiting: false,
            hover: 0.0,
            press: 0.0,
            scrolled: [0, 0],
            caret: nil
        )
    }
}

/// Retained stateful coordinator driving declarative `El<State>` views, layout, `Scene` motion,
/// hit-testing, pointer/drag/scroll/keyboard/text-edit routing, and primitive generation.
public final class Runtime<State> {
    public typealias ViewFn = (State, inout Cx<State>) -> El<State>
    public typealias KeyHandlerFn = (inout State, KeyEvent, inout Tx) -> Bool

    internal struct FlatNode {
        var index: Int
        var parentIndex: Int?
        var path: String
        var key: String?
        var nodeId: NodeId
        var localRect: MotionRect
        var targetRect: MotionRect
        var effectiveInert: Bool
        var element: FlatElement<State>
        var unscrolledRect: MotionRect
        var committedLayoutTarget: MotionRect
        var zoomedTargetRect: MotionRect
        var staticBounds: SIMD4<Float>
        var contentSize: Vec2
        var clipRect: MotionRect
        var scrollShift: Vec2
        var localSize: Vec2
        var zOrder: Int
        var paintTraits: NativePaintTraits
        var inheritedScale: Float
        var enclosingScrollIndex: Int?
        var enclosingVScrollIndex: Int?
        var enclosingHScrollIndex: Int?
        var flow: Flow
        var mirroredInRtl: Bool
        private(set) var cold: [FlatNodeCold] = []

        @inline(__always) var el: El<State> {
            _read { yield element.value }
            _modify {
                defer { paintTraits = NativePaintTraits(element.value, inScrollViewport: enclosingScrollIndex != nil) }
                yield &element.value
            }
        }
        var staticRect: [Float] {
            [staticBounds.x, staticBounds.y, staticBounds.z, staticBounds.w]
        }
        var growthRowProjectionY: Float { cold.first?.growthRowProjectionY ?? 0 }
        var growthContentShiftY: Float { cold.first?.growthContentShiftY ?? 0 }
        var virtualWindowSnapOriginY: Float { cold.first?.virtualWindowSnapOriginY ?? 0 }
        var anchorAttachNorm: Vec2? { cold.first?.anchorAttachNorm }
        var ownClipFade: EdgeFadeSpec? {
            get { cold.first?.ownClipFade }
            set {
                if newValue == nil && cold.first?.ownClipFade == nil { return }
                if cold.isEmpty { cold = [FlatNodeCold()] }
                cold[0].ownClipFade = newValue
                if newValue == nil && cold[0].isEmpty { cold = [] }
            }
        }
        var elided: TextElision? { cold.first?.elided }
        var isSticky: Bool { paintTraits.contains(.sticky) }

        var activeClipFades: [EdgeFadeSpec] {
            get { cold.first?.activeClipFades ?? [] }
            set {
                if newValue.isEmpty && (cold.first?.activeClipFades.isEmpty ?? true) { return }
                if cold.isEmpty { cold = [FlatNodeCold()] }
                cold[0].activeClipFades = newValue
                if newValue.isEmpty && cold[0].isEmpty { cold = [] }
            }
        }
        var ownScrollFade: EdgeFadeSpec? {
            get { cold.first?.ownScrollFade }
            set {
                if newValue == nil && cold.first?.ownScrollFade == nil { return }
                if cold.isEmpty { cold = [FlatNodeCold()] }
                cold[0].ownScrollFade = newValue
                if newValue == nil && cold[0].isEmpty { cold = [] }
            }
        }

        init(
            index: Int, parentIndex: Int?, path: String, key: String?, nodeId: NodeId, element: FlatElement<State>,
            localRect: MotionRect, unscrolledRect: MotionRect, targetRect: MotionRect, committedLayoutTarget: MotionRect? = nil,
            growthRowProjectionY: Float = 0, growthContentShiftY: Float = 0, virtualWindowSnapOriginY: Float = 0,
            zoomedTargetRect: MotionRect, staticBounds: SIMD4<Float>, contentSize: Vec2, clipRect: MotionRect,
            scrollShift: Vec2, localSize: Vec2? = nil, effectiveInert: Bool, zOrder: Int, inheritedScale: Float = 1,
            anchorAttachNorm: Vec2? = nil, activeClipFades: [EdgeFadeSpec] = [],
            ownScrollFade: EdgeFadeSpec? = nil, ownClipFade: EdgeFadeSpec? = nil, enclosingScrollIndex: Int? = nil,
            enclosingVScrollIndex: Int? = nil, enclosingHScrollIndex: Int? = nil, flow: Flow = .ltr,
            mirroredInRtl: Bool = false, elided: TextElision? = nil
        ) {
            self.index = index
            self.parentIndex = parentIndex
            self.path = path
            self.key = key
            self.nodeId = nodeId
            self.element = element
            self.paintTraits = NativePaintTraits(element.value, inScrollViewport: enclosingScrollIndex != nil)
            self.localRect = localRect
            self.unscrolledRect = unscrolledRect
            self.targetRect = targetRect
            self.committedLayoutTarget = committedLayoutTarget ?? targetRect
            self.zoomedTargetRect = zoomedTargetRect
            self.staticBounds = staticBounds
            self.contentSize = contentSize
            self.clipRect = clipRect
            self.scrollShift = scrollShift
            self.localSize = localSize ?? Vec2(localRect.width, localRect.height)
            self.effectiveInert = effectiveInert
            self.zOrder = zOrder
            self.inheritedScale = inheritedScale
            self.enclosingScrollIndex = enclosingScrollIndex
            self.enclosingVScrollIndex = enclosingVScrollIndex
            self.enclosingHScrollIndex = enclosingHScrollIndex
            self.flow = flow
            self.mirroredInRtl = mirroredInRtl
            if growthRowProjectionY != 0 || growthContentShiftY != 0 || virtualWindowSnapOriginY != 0
                || anchorAttachNorm != nil || !activeClipFades.isEmpty || ownScrollFade != nil || ownClipFade != nil || elided != nil {
                cold = [FlatNodeCold(growthRowProjectionY: growthRowProjectionY, growthContentShiftY: growthContentShiftY,
                                     virtualWindowSnapOriginY: virtualWindowSnapOriginY, anchorAttachNorm: anchorAttachNorm,
                                     activeClipFades: activeClipFades, ownScrollFade: ownScrollFade, ownClipFade: ownClipFade,
                                     elided: elided)]
            }
        }
    }

    private struct StaticInh {
        var scale: Vec2 = Vec2(1, 1)
        var anchor: SIMD2<Float> = .zero
        var anchorTo: SIMD2<Float> = .zero
        var offset: Vec2 = .zero
    }

    private struct WalkItem {
        var element: FlatElement<State>
        var memoPaths: FlatMemoPaths<State>? = nil
        var virtualRow: CachedVirtualRow?
        var memoSlot = 0
        var resolvedId: NodeId? = nil
        var solved: LayoutEngine.ResultNode
        var resolvedKey: String?
        var path: String
        var parentIdx: Int?
        var parentOrigin: Vec2
        var parentUnscrolledOrigin: Vec2
        var parentScroll: Vec2
        var parentScale: Float
        var scaleChain: [AnchorLayoutHelper.AncestorScaleStep]
        var inheritedClip: MotionRect
        var inheritedInert: Bool
        var inheritedZ: Int
        var inInstantSubtree: Bool
        var inheritedClipFades: [EdgeFadeSpec]
        var enclosingScrollIndex: Int?
        var enclosingVScrollIndex: Int?
        var enclosingHScrollIndex: Int?
        var staticInh: StaticInh
        var rowLayout: ParityRowLayout = .free
        var parentHasGrowth: Bool = false
        var parentUnderFold: Bool = false
        var parentNewlyMounted: Bool = false
        var inheritedStyleSpring: Spring? = nil
        var parentFlow: Flow = .ltr
        var parentDirected: Bool = false
        var foldHeaderPath: String? = nil
        var foldHeaderLift: Float = 0
        var growthPlacementShiftY: Float = 0
        var naturalLayout: LayoutEngine.ResultNode? = nil
    }

    private static func retainedRowInputs(_ item: borrowing WalkItem, frame: FlatMemoFrame) -> FlatMemoContext? {
        guard item.memoPaths == nil, item.naturalLayout == nil, item.parentScale == 1, item.parentScroll == .zero,
              item.scaleChain.isEmpty, item.staticInh.scale == Vec2(1, 1),
              item.staticInh.anchor == item.staticInh.anchorTo, item.staticInh.offset == .zero,
              item.foldHeaderPath == nil, item.growthPlacementShiftY == 0 else { return nil }
        return FlatMemoContext(frame: frame, flow: item.parentFlow, directed: item.parentDirected,
            inert: item.inheritedInert, z: item.inheritedZ, instant: item.inInstantSubtree,
            row: item.rowLayout, underFold: item.parentUnderFold, styleSpring: item.inheritedStyleSpring)
    }

    private struct PaintInh {
        var opacity: Float = 1.0
        var scale: Vec2 = Vec2(1, 1)
        var anchor: SIMD2<Float> = .zero
        var anchorTo: SIMD2<Float> = .zero
        var offsetDelta: Vec2 = .zero
        var fullDelta: Vec2 = .zero
        var restOffset: Vec2 = .zero
        var snap: PixelSnap.Inherit = PixelSnap.Inherit()
        var rowGlideY: Float = 0
        var scaleMotion: PaintScaleMotion = .still
        var stillScale: Float = 1.0
        var parentDrawnWidth: Float? = nil
        var parentTargetWidth: Float? = nil
        var parentMoving: Bool = false
        var rectSpringing: Bool = false
        var clip: MotionRect? = nil
        var inCache: Bool = false
        var reportedTurnClip: Int? = nil
    }

    private struct LiftedFlightSubtree {
        var node: Presented
        var inh: PaintInh
        var isFlight: Bool
        var treeInfoOffset: Int?
        var ancestorOpacity: Float
        var logicalOpacity: Float
        var ancestorBlur: Float
        var inheritedExiting: Bool
        var ancestorTurn: Turn?
        var outerTurnClip: MotionRect?
        var localTurnClip: MotionRect?
        var parentPath: String?
        var nearestGroupHovered: Bool
        var nearestGroupHoverFrac: Float
        var nearestPressColor: Color? = nil
        var nearestPressFrac: Float = 0.0
        var parentStickyShift: Vec2
        var parentStickyMag: Float
    }

    internal struct DragSession {
        var path: String
        var key: String?
        var startWindow: Vec2
        var lastWindow: Vec2
        var startLocal: Vec2
        var startElementOrigin: Vec2
        var startScale: Vec2
        var elementSize: Vec2
        var clicks: Int
        var button: PointerButton
        var mods: Mods
        var isTextSelectionDrag: Bool
        var movedBeyondSlop: Bool = false
        var textSelectionOrigin: (Int, Int)? = nil
        var stateSnapshotBeforeDrag: State
    }

    private struct EmitStepInput {
        let p: Presented
        let inh: PaintInh
        let ancestorOpacity: Float
        let logicalOpacity: Float
        let ancestorBlur: Float
        let inheritedExiting: Bool
        let ancestorTurn: Turn?
        let outerTurnClip: MotionRect?
        let localTurnClip: MotionRect?
        let parentPath: String?
        let nearestGroupHovered: Bool
        let nearestGroupHoverFrac: Float
        var nearestPressColor: Color? = nil
        var nearestPressFrac: Float = 0.0
        let flightCover: FlightCoverTransform?
        let flightClipOverride: MotionRect?
        let emitLiftedNow: Bool
        let parentStickyShift: Vec2
        let parentStickyMag: Float
        let kidsFadeOpacity: Float
    }

    private struct EmitNodeExit {
        let layerEndCount: Int
        let devClip: SIMD4<Float>
    }

    private enum EmitWorkItem {
        case enter(EmitStepInput)
        case exit(EmitNodeExit)
    }

    internal func placedPixels(_ pixels: Pixels, at time: Double, visible: Bool, box: SIMD4<Float>,
                               fit: SurfaceFit?, place: SurfacePlace) -> (region: ImageAtlasRegion, sample: PixelsPresentation)? {
        guard let sample = imagePlayback.sample(pixels, at: time) else { return nil }
        if visible {
            shownPixelIDs.insert(pixels.id)
            if liveVisible, let next = sample.nextDeadline, cxSettings.viewTimeScale > 0 {
                let due = currentTime + max(0, next - time) / Double(cxSettings.viewTimeScale)
                nextImageWake = min(nextImageWake ?? due, due)
            }
        }
        let fullRect = fit.map { place.imageRect(forNode: box, imageSize: (sample.width, sample.height), fit: $0) } ?? box
        return (imagePacker.insert(sample, for: pixels.id, drawnSize: SIMD2(fullRect.z, fullRect.w)), sample)
    }

    internal func beginPixelPaint() {
        imagePacker.beginPaint()
        shownPixelIDs.removeAll(keepingCapacity: true)
        nextImageWake = nil
    }

    internal func finishPixelPaint() {
        imagePlayback.retain(shownPixelIDs)
        imagePacker.finishPixelPaint()
    }

    internal func colorGlyphImage(_ glyph: PositionedGlyph) -> (region: ImageAtlasRegion, pixelSize: SIMD2<Int>)? {
        guard let entry = textSystem.colorGlyph(for: glyph) else { return nil }
        return (imagePacker.insert(entry), entry.pixelSize)
    }

    public var state: State
    public var view: ViewFn
    public var globalOnKey: KeyHandlerFn?

    public var viewport: Vec2 {
        didSet {
            if !cxSettings.isApplyingZoom {
                cxSettings.zoomState.window = viewport
            }
            if viewport != oldValue && !suppressViewportCommitFlag {
                needsCommit = true
                pendingResizeRelayout = true
                commitWhyPending |= CommitWhy.relayout
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
                commitWhyPending |= CommitWhy.relayout
                stateUnchangedSinceBuild = false
                pendingResizeRelayout = false
            pendingGrowthRelayout = false
            }
        }
    }
    public var systemDark: Bool {
        didSet {
            if systemDark != oldValue {
                needsCommit = true
                commitWhyPending |= CommitWhy.dirty
                stateUnchangedSinceBuild = false
                pendingResizeRelayout = false
            pendingGrowthRelayout = false
            }
        }
    }
    private var isApplyingEffectiveReducedMotion = false
    public var reducedMotion: Bool {
        didSet {
            scene.reducedMotion = reducedMotion
            scrollStore.reducedMotion = reducedMotion
            liveStore.reducedMotion = reducedMotion
            if !isApplyingEffectiveReducedMotion {
                cxSettings.hostReducedMotion = reducedMotion
            }
            if reducedMotion != oldValue {
                needsCommit = true
                commitWhyPending |= CommitWhy.dirty
                stateUnchangedSinceBuild = false
                pendingResizeRelayout = false
            pendingGrowthRelayout = false
            }
        }
    }
    public var srgbBlend: Bool = true
    /// Enables native AppKit material views when backed by a transparent window; headless runs default to `false`.
    public var nativeMaterials: Bool = false
    public var windowFocused: Bool = true {
        didSet {
            // frame.rs:77-81: a focus change marks the state dirty only when a selection takes
            // its active or inactive pair (`windowFocusRepaintsSelection`).
            if windowFocused != oldValue, windowFocusRepaintsSelection {
                needsCommit = true
                commitWhyPending |= CommitWhy.dirty
                stateUnchangedSinceBuild = false
                pendingResizeRelayout = false
            pendingGrowthRelayout = false
            }
        }
    }
    public var clearColor: Color = Color(r: 0, g: 0, b: 0, a: 1)

    public let textSystem: TextSystem
    public let waker: Waker
    public internal(set) var scene: Scene
    internal var scrollStore: AnimationStore
    internal var liveStore: AnimationStore
    internal var pixelSnapGlides = PixelSnap.Glides()
    internal var labelDrawCommit = -1
    internal var labelDraws: [NodeId: RetainedLabelDraws] = [:]

    public internal(set) var currentTime: Double = 0.0
    public internal(set) var isAnimating: Bool = false
    public internal(set) var surfaces: [SurfaceDraw] = []
    private var videoSignature: UInt64 = 0
    private var nextVideoWake: Double?
    private var lastVideoSnapshots: [String: VideoSnapshot] = [:]
    public private(set) var viewCommitCount: Int = 0
    public private(set) var viewCallCount: Int = 0
    public private(set) var keyWarnings: [String] = []
    public let perfWatch = PerfWarn.Watch()
    public var interactionTracker: InteractionTracker { perfWatch.interaction }
    internal var frameInstantScrollKey: String? = nil
    internal var frameHadCommitted: Bool = false
    internal var frameHadInputSinceLastFrame: Bool = false
    /// Input since the last frame changed the model (`CommitWhy::INPUT`, #970).
    internal var frameInputCauseSinceLastFrame: Bool = false
    internal var frameHadLiveWake: Bool = false
    internal var frameHadScrollSinceLastFrame: Bool = false
    public var windowTitle: String? = nil
    public private(set) var quitRequested: Bool = false
    public var fontSmoothing: FontSmoothing = .systemDefault {
        didSet {
            guard fontSmoothing != oldValue else { return }
            textSystem.smoothing = fontSmoothing == .systemDefault ? .platformDefault : fontSmoothing
            dirtyCommit(at: currentTime)
        }
    }

    public func setFontSmoothing(_ smoothing: FontSmoothing) {
        fontSmoothing = smoothing
    }
    public var tabVisitsControls: Bool = false
    public var poll: ((inout State, Double, inout Tx) -> Bool)? = nil
    public var onFocus: ((inout State, Bool, inout Tx) -> Void)? = nil
    public var onModifiers: ((inout State, Mods, inout Tx) -> Void)? = nil
    public var onVisibility: ((inout State, Bool, inout Tx) -> Void)? = nil
    public var onRest: ((inout State, inout Tx) -> Bool)? = nil
    public var onIme: ((inout State, Ime, inout Tx) -> Bool)? = nil
    public var onClose: ((inout State, inout Tx) -> Bool)? = nil
    public var onQuit: ((inout State, inout Tx) -> Void)? = nil
    public var turnScope: ((inout State, (inout State) -> Void) -> Void)? = nil
    public var onReopen: ((inout State, Bool, inout Tx) -> Bool)? = nil
    public var onOpenUrl: ((inout State, String, inout Tx) -> Void)? = nil
    public private(set) var closeWindowRequested: Bool = false
    public var minimizeRequested: Bool { minimizeState.field }
    public private(set) var relaunchRequested: Bool = false
    public internal(set) var wakeDeadlines: [Double] = []
    internal var pendingUpdateWakes: [(scheduledAt: Double, delay: Double)] = []
    internal var pendingFrameWakes: [(scheduledAt: Double, delay: Double)] = []
    internal var insideFramePollOrInput: Bool = false
    public var wallStart: Double? = nil
    public var timerWake = TimerWake()
    public var surfaceMeter: SurfaceMeter? = nil
    public internal(set) var hasDissolve: Bool = false
    public internal(set) var dissolveScratch: [Bool] = []
    public internal(set) var nextWakeDeadline: Double? {
        get {
            var best = wakeDeadlines.first
            for entry in pendingUpdateWakes {
                let d = entry.scheduledAt + entry.delay
                best = best.map { min($0, d) } ?? d
            }
            for entry in pendingFrameWakes {
                let d = entry.scheduledAt + entry.delay
                best = best.map { min($0, d) } ?? d
            }
            return best
        }
        set {
            if let due = newValue {
                if insideFramePollOrInput {
                    pendingFrameWakes.append((scheduledAt: due, delay: 0.0))
                } else {
                    pendingUpdateWakes.append((scheduledAt: due, delay: 0.0))
                }
            } else {
                wakeDeadlines.removeAll(keepingCapacity: true)
                pendingUpdateWakes.removeAll(keepingCapacity: true)
                pendingFrameWakes.removeAll(keepingCapacity: true)
            }
        }
    }
    public var helpDelay: Double = 0.5
    public internal(set) var imeArea: [Float]? = nil
    internal var inputMachines = RuntimeInputMachines()
    public var nativeHelp: Bool = false
    public var clipboard = ClipboardContent("")
    public var richClipboard = RichClipboardPayload()
    /// Pending clipboard copy text requested via `Tx.copyText(...)`, `Cmd+C`/`Cmd+X`, or selectable `Cmd+C`, consumed once by `takeCopyRequest()` (`Runtime::copy_request`).
    public var copyRequest: String? = nil
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
    public internal(set) var playgroundRequests: [PlaygroundTxRequest] = []
    internal var playgroundLiveStorage: AnyObject? = nil
    public var shortcutRegistry: ShortcutRegistry? = nil
    public internal(set) var imeReset: Bool = false

    internal private(set) var textPreparation: WindowTextPreparation?
    public let runtimeId: UInt64
    public var fitHeight: Bool = false
    public var windowResting: Bool = false
    internal var fitWindowState = FitWindowState()
    public var pendingWindowFrame: WindowFrameRequest? = nil
    internal var userResizeNeedsCut: Bool = false
    private var activeResizeSnap: Bool = false
    private var activeExplicitSnap: Bool = false
    internal var suppressViewportCommitFlag: Bool = false
    internal var lastCommitMotionSpring: Spring? = nil
    internal var lastScaledAnimNow: Double = 0.0

    internal var popupQueue: PopupQueueState = .closed
    internal var popupNeedsLayout: Bool = false
    internal var runtimeFileDialogState: RuntimeFileDialogState = .closed
    internal var nextFileDialogId: UInt64 = 1
    internal var pendingFileDialogAnswers: [((inout Any, FileDialogResult, inout Tx) -> Void, FileDialogResult)] = []
    internal enum PendingHiddenDropStep {
        case drag(urls: [URL], point: Vec2?, at: Double)
        case dragTo(point: Vec2, at: Double)
        case leave(at: Double)
        case drop(urls: [URL], point: Vec2?, at: Double)
    }

    public private(set) var commitCount: UInt64 = 0
    public var liveVisible: Bool { liveLane.visible }
    public internal(set) var minimizeState: WindowMinimize = .none
    internal var pendingDropHoverChanged: Bool = false
    internal var pendingHiddenDrops: [PendingHiddenDropStep] = []
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
    /// Whether standalone physical modifier transitions (`ModifierKey`) are tracked and dispatched (`keys.rs`).
    public var modifierKeysEnabled: Bool {
        get { inputMachines.modifierKeys.enabled }
        set { setModifierKeys(newValue) }
    }
    internal var heldModifierKeys: [ModifierKey] = []
    public var traceChannels: [String: (kind: TraceChannels.Kind, value: Float)]? = nil {
        didSet {
            scene.store.auditRetargets(traceChannels != nil)
        }
    }
    public var traceEvents: [String] = []
    public internal(set) var animSources: UInt32 = 0
    internal var currentPhysicalKey: PhysicalKeyCode? = nil
    internal var currentKeyBase: Character? = nil
    internal var currentKeyRepeat: Bool = false

    public var hasPendingInput: Bool {
        !pendingFileDialogAnswers.isEmpty
            || pendingDropMovePoint != nil
            || pendingDropHoverChanged
            || !pendingHiddenDrops.isEmpty
            || !popupQueue.isEmpty
            || dragEndsPending
    }

    // Input & focus state
    public internal(set) var pointerPosition: Vec2 = Vec2(-10000, -10000)
    public internal(set) var hoveredPath: String? = nil
    private let hoverReadDependency = HoverReadDependency()
    public internal(set) var hoveredKey: String? = nil {
        didSet {
            if oldValue != nil || hoveredKey != nil, !matchesAuthoredKey(oldValue, hoveredKey), hoverReadDependency.changed(in: memo) {
                dirtyCommit(at: currentTime, why: CommitWhy.read, inputChange: false)
            }
        }
    }
    internal var hoveredCallbackPaths: [String] = []
    private var pendingPaintHovers: [(path: String?, priorSentKeys: Int)] = []
    public internal(set) var pressedPath: String? = nil
    private var activatedOnPointerDown = false
    private var pressedByTouch = false
    public internal(set) var pressedKey: String? = nil
    /// Button of the held press (`capture::Held::button`). Single store shared with the Slice 4
    /// input machines (`inputMachines.pressedButton`) so both pointer paths agree.
    internal var pressedButton: PointerButton {
        get { inputMachines.pressedButton }
        set { inputMachines.pressedButton = newValue }
    }
    internal var pressedPointerInside: Bool = false
    public internal(set) var pressedTint: (path: String, button: PointerButton)? = nil
    internal var lastPressTargetById: [NodeId: Float] = [:]
    internal var pressScaleTrackOwners: Set<NodeId> = []
    public internal(set) var focusedPath: String? = nil {
        didSet {
            if focusedPath != oldValue { syncFocusedEditLineMode() }
        }
    }

    private func syncFocusedEditLineMode() {
        guard let path = focusedPath, let index = nodeByPath[path], flatNodes.indices.contains(index) else { return }
        let el = flatNodes[index].el
        if el.hasEditAccess { el.handlers.syncEditLineMode(in: &state) }
    }
    public internal(set) var focusedKey: String? = nil
    public internal(set) var focusVisible: Bool = false
    internal var hoveredHighlightActive: Bool = false
    internal var linkBoxesByPath: [String: [TextLinkBox]] = [:]
    internal var focusedLinkIndex: Int? = nil
    internal var hoveredLink: TextLinkTarget? = nil
    internal var pressedLink: TextLinkTarget? = nil
    private var webFocusTabStartPath: String? = nil
    /// Focus modality (`focus_machine::Modality::Keyboard`): kept in `inputMachines.focusMachine`.
    internal var focusKeyboard: Bool {
        get { inputMachines.focusMachine.focusKeyboard }
        set { inputMachines.focusMachine.focusKeyboard = newValue }
    }
    /// The focus the gesture/commit underway took away (`Focus::None { blurred }`): one state with
    /// `inputMachines.focusMachine.blurredFocusPath`, which also drives focus-return scoping.
    internal var blurredFocusPath: String? {
        get { inputMachines.focusMachine.blurredFocusPath }
        set { inputMachines.focusMachine.blurredFocusPath = newValue }
    }
    /// Whether a lost focus may hand off to a neighbour once its element leaves (`Focus::None { handoff }`).
    internal var focusHandoff: Bool {
        get { inputMachines.focusMachine.focusHandoff }
        set { inputMachines.focusMachine.focusHandoff = newValue }
    }
    // A provisional memo-geometry pass publishes a layout but never dispatches interaction changes.
    // Keep the last delivered tree until focus and hover can reconcile against the final pass.
    private var interactionTreeBeforeSettle: (nodes: [FlatNode], byPath: [String: Int])?
    internal var tabStartFocusPath: String? { webFocusTabStartPath }
    /// Focus landed on an element (`Focus::On`): Tab no longer starts from a remembered point.
    internal func clearTabStartFocusPath() { webFocusTabStartPath = nil }
    internal var dirChord: DirChord = .idle
    private var lastPinnedGlyphMask: UInt32 = 0
    public private(set) var lastKeyDiagnostics: [DuplicateKeyWarning] = []
    internal var renamedSiblingKeys: [String: KeyDiagnostics.Rename] = [:]

    internal var lastClickTime: Double = -10.0
    private var lastClickPos: Vec2 = Vec2(-10000, -10000)
    internal var clickCount: Int = 0
    internal var activeDrag: DragSession? = nil
    internal var primaryPointerHeld: Bool = false
    internal var secondaryPointerHeld: Bool = false
    internal var hasActivePointerDrag: Bool { activeDrag != nil || armedDragOut != nil }
    /// Whether either the primary or secondary pointer button is currently held (`Runtime::pointer_captured`).
    /// A started drag-out hands the pointer to the OS session, so it no longer captures
    /// (`pointer.rs:89`: press, secondary, or press tint only).
    public var pointerCaptured: Bool {
        primaryPointerHeld || secondaryPointerHeld || activeDrag != nil || armedDragOut != nil
    }

    // Scroll state keyed by element path
    internal var scrollOffsets: [String: Vec2] = [:]
    internal var scrollMaxExtents: [String: Vec2] = [:]
    internal var scrollViewportSizes: [String: Vec2] = [:]
    internal var scrollContentSizes: [String: Vec2] = [:]
    internal var wasPinnedToBottom: Set<String> = []
    private var autofocusAppliedPaths: Set<String> = []

    // Increment 4 parity state (`TxCommit`, `ScrollRequests`, `VirtualFill`, `GrowthStack`, `Sticky`)
    internal var pendingCommitKind: TxCommit = .animate
    internal var pendingCommitMotion: MotionSource? = nil
    internal var pendingColorMotionSpring: Spring? = nil
    internal var pendingFollowEdge: Bool = false
    internal var pendingUnprompted: Bool = false
    internal var pendingAskedMotion: Bool = false
    internal var frameCommittedFromInput: Bool = false
    /// When true, commits without frame input or explicit `tx.animated()`/`tx.motion(...)` land unprompted (`motion_needs_cause`).
    public var motionNeedsCause: Bool = false
    internal var pendingScrollReveals: [ScrollRevealRequest] = []
    /// A jump whose new virtual window must measure before its final placement.
    internal var virtualRevealLandings: [ScrollRevealRequest] = []
    internal var pendingScrollBottoms: [(key: String, animated: Bool)] = []
    internal var pendingScrollPages: [(key: String, pages: Int)] = []
    internal var pendingScrollOffsets: [ScrollOffsetRequest] = []
    internal var scrollKeyLandings = ScrollKeyLandings()
    internal var pendingKeepOnScreenKeys: [String] = []
    internal var pendingCaretFollow: Bool = false
    internal var scrollRequestsState = ScrollRequestsState()
    internal var scrollGlidingPaths: Set<String> = []
    internal var directScrolledPaths: Set<String> = []
    internal var virtualLists: [String: RuntimeVirtualListState] = [:]
    private var singleVirtualPath: String?
    internal var activeVirtualPaths: Set<String> = [] {
        didSet { singleVirtualPath = activeVirtualPaths.count == 1 ? activeVirtualPaths.first : nil }
    }

    internal func isActiveVirtualPath(_ path: String) -> Bool {
        if let singleVirtualPath { return singleVirtualPath == path }
        return activeVirtualPaths.contains(path)
    }
    internal var virtualFill = VirtualFillStateMachine()
    internal var virtualFillWantsDraw: Bool = false
    internal var virtualFillLastScrollOffsets: [String: Vec2] = [:]
    private var lastHoverScrollOffsets: [String: Vec2] = [:]
    internal typealias RuntimeGrowthEntry = Rune.RuntimeGrowthEntry
    internal var nodeTextLayouts: [NodeId: RetainedLayoutCoordinator.TextLayoutRecord] = [:]
    /// The device rows of each field with waiting paragraphs its last paint showed (`text_fill`).
    internal var textRows: [NodeId: (Float, Float)] = [:]
    internal var prevNodeTextLayoutsForCommit: [NodeId: (shapeKey: TextShapeKey, isInput: Bool)]? = nil
    internal var exitingTextLayouts: [NodeId: RetainedLayoutCoordinator.TextLayoutRecord] = [:]
    internal var growthRows: [String: RuntimeGrowthEntry] = [:]
    internal var growthStacks: [String: RuntimeGrowthStackState] = [:]
    internal var foldHeaders: [String: String] = [:]
    internal var lastGrowthStepTime: Double? = nil
    internal var pendingGrowthStepNow: Double? = nil
    internal var atBottomStates: [NodeId: Bool] = [:]
    internal var farFromBottomStates: [NodeId: Bool] = [:]
    internal var lastScrollOffsetReports: [String: ScrollPos] = [:]
    internal var scrollMovedByHand: Set<String> = []
    internal var pendingScrollJumpPaths: Set<String> = []
    internal var lastScrollObserverOffsets: [String: Vec2] = [:]
    internal var lastScrollHandlerTokens: [String: UInt64] = [:]
    internal var stuckShiftsByPath: [String: Vec2] = [:]
    internal var isDispatchingHover: Bool = false
    internal var suppressSelectionEffectsFromHoverCommit: Bool = false
    internal var lastVirtualFillWanted: Bool = false
    internal var lastVirtualFillMissing: Int = 0
    internal var lastVirtualFillMoved: Bool = false
    internal var lastFocusSelectedPaths: Set<String> = []
    internal var lastRevealSelectedPaths: Set<String> = []
    internal var currentCommitInstant: Bool = false
    internal var currentFrameCommitInstant: Bool = false
    internal var loopRuntime = LoopRuntime()
    internal var loopClock = LoopClock()
    internal var elSliceRenderState = ElSliceRenderState()
    internal var wordRevealStore = WordRevealStore()
    private var timeScaledNodeIds: Set<NodeId> = []
    private var sceneRideTrailingIds: Set<NodeId> = []
    internal var selectionState = RuntimeSelectionState()
    internal var nativeInspection: NativeFrameInspection?
    internal var lastPoseNodes: [PoseNodeSnapshot] = []
    internal var lastMotionElements: [MotionElement] = []
    internal var frameMovedScrollPaths: Set<String> = []
    internal var frameLandingHoldIds: Set<NodeId> = []
    internal var shadowTrackCounts: [NodeId: Int] = [:]
    public var events: [String] = []
    public var recordEvents: Bool = true
    public var assistiveTechnology: Bool = false
    public var isTracing: Bool = false {
        didSet {
            if isTracing && traceChannels == nil {
                traceChannels = [:]
            }
        }
    }
    public internal(set) var lastAnnouncement: (text: String, politeness: LiveRegionPoliteness)? = nil
    /// `Tx::announce`'s window live region (`Runtime::announcement`): words, politeness, count, when.
    public internal(set) var a11yAnnouncement = AccessibilityAnnouncement()
    public internal(set) var toggleMaximizedRequested: Bool = false
    public internal(set) var toggleFullScreenRequested: Bool = false
    public internal(set) var imeCursorArea: [Float]? = nil
    /// Whether the active `El.imeCursor` caret asks for Option as Alt on macOS (`El::ime_option_as_alt`).
    public internal(set) var imeOptionAsAlt: Bool = false
    public internal(set) var noWindowDragRects: [MotionRect] = []
    internal var activeByKeys: Bool = false
    internal var pendingSentKeys: [KeyEvent] = []
    /// Arrival stamps of host-dispatched input and queued sent keys (`Tx.inputWaiting`).
    internal var queuedInputArrivals = QueuedInputArrivals()
    /// How many handler transactions have been applied, so `hostInput` can tell input that ran a handler.
    internal var inputHandlerRuns: UInt64 = 0
    internal struct MatchedSeenSnapshot {
        var id: NodeId
        var path: String
        var rect: MotionRect
        var corners: Corners
        var fill: MotionColor?
        var opacity: Float
    }
    internal var seenMatchedByFlightId: [String: MatchedSeenSnapshot] = [:]
    private var committedMatchedByFlightId: [String: MatchedSeenSnapshot] = [:]
    internal var activeFlightIds: Set<NodeId> = []
    internal var launchedFlightIds: Set<NodeId> = []
    internal var launchScrollById: [NodeId: LaunchScroll] = [:]
    internal var unclippedMatchedFlightIds: Set<NodeId> = []
    private struct PendingFlightRequest {
        var source: String
        var destination: String
        var sourceNodeId: NodeId?
        var sourceRect: MotionRect?
        var sourceTextRect: MotionRect?
        var sourceLayout: TextLayoutBox?
        var sourceClip: MotionRect?
        var sourceCorners: Corners?
        var sourceFill: MotionColor?
        var sourceText: String?
        var sourceSpans: [TextSpan]?
        var sourceTextStyle: TextStyle?
        var sourceTextColor: Color?
        var motionSpring: Spring?
        var remainingAttempts: Int = 2
    }
    internal struct ActiveTextFlight {
        var targetNodeId: NodeId
        var state: TextFlightState
        var sourceLayout: TextLayoutBox?
        var sourceClip: MotionRect
        var sourceText: String?
        var sourceSpans: [TextSpan]?
        var sourceTextStyle: TextStyle
        var sourceTextColor: Color?
    }
    private var pendingTextFlights: [PendingFlightRequest] = []
    private var pendingLaunches: [PendingFlightRequest] = []
    private var pendingUnclippedFlights: Bool = false
    internal var activeTextFlights: [ActiveTextFlight] = []
    internal var lastViewReadScroll: Bool = false
    private var isCommittingTree = false

    // A copied Cx keeps its live metric lookups. A read made between runtime turns must
    // not make a previously scroll-independent view rebuild on the next wheel event.
    private func noteScrollMetricRead() {
        if !lastViewReadScroll && (isCommittingTree || RuntimeIdScope.current != nil || MemoScope.activeCache != nil) {
            lastViewReadScroll = true
        }
    }
    private struct FocusReturnEntry {
        var ownerPath: String
        var scopePath: String
        var isModal: Bool
        var returnPath: String?
        var returnKey: String?
        var prevFocusVisible: Bool
    }
    private var focusReturnStack: [FocusReturnEntry] = []
    private var syncedEditFocusedPaths: Set<String> = []
    private var pendingTxFocusKey: String? = nil
    /// `Tx.focusWhenShown` asked since the last commit: the key and whether its ring shows.
    internal var pendingFocusWhenShown: (key: String, ring: Bool)? = nil
    /// `Tx::focus_when_shown` still waiting for its element (`Runtime::focus_owed`): the key and
    /// whether its ring shows. Dropped by the user's own key or press, or by another focus ask.
    internal var focusOwed: (key: String, ring: Bool)? = nil
    /// A resting poll changed the model but hasn't committed its tree yet (`Tx::polled_change`).
    internal var polledChange: Bool = false
    /// Input entry points being dispatched (`beginInputDispatch`), observer callbacks running
    /// inside them that upstream counts as DIRTY (`on_selection_change`), and whether a handler of
    /// the input being dispatched changed the model (`if r { why |= CommitWhy::INPUT }`).
    internal var inputDispatchDepth: Int = 0
    internal var inputObserverDepth: Int = 0
    internal var inputDispatchChanged: Bool = false
    /// The poll split of the input being dispatched turned a pending `Tx.focusWhenShown` into an
    /// owed one: upstream drops `focus_owed` before that split, so this input's press keeps it.
    internal var focusOwedFromSplit: Bool = false
    private var pendingTxFocusVisible: Bool? = nil
    private var pendingTxBlurRequested: Bool = false
    internal var kitHooks = KitRuntimeHooksState()
    internal var modalMemberPaths: Set<String> = []
    internal var modalAncestorPaths: Set<String> = []
    internal var activeModalPath: String? = nil
    private var viewHelpLook: HelpLook? = nil
    private var helpState = HelpRuntimeState()
    internal var isTooltipWaiting: Bool {
        if case .waiting = helpState.tipState { return true }
        return false
    }
    internal var boundClipboard: Clipboard? = nil
    internal var clipboardRouting = ClipboardRoutingState()
    internal var inheritedHoverCurvesByPath: [String: (enter: Anim<Float>, exit: Anim<Float>)] = [:]
    internal var anchorHoverWithinByKey: [String: (enter: Anim<Float>, exit: Anim<Float>)] = [:]
    internal var unseenPresence = UnseenPresenceState()
    internal var activePaintedLoopsAnimating: Bool = false
    internal var activePaintedLoopWake: Double? = nil
    internal var cyclePaint = CyclePaint()
    internal var hasOtherPaintDeadline: Bool { nextImageWake != nil || nextVideoWake != nil }
    internal var explicitSettleRequested: Bool = false
    private var activeSettleLoops: Bool = false
    internal var hoverCurvesById: [NodeId: (enter: Anim<Float>, exit: Anim<Float>)] = [:]
    internal var lastHoverTargetById: [NodeId: Float] = [:]
    internal var pressedKeyFocusPath: String? = nil
    private var pictureAspects: [(id: NodeId, pixels: Pixels, ratio: Float)] = []
    internal var pixelsAspectSnapIds: Set<NodeId> = []
    private var pictureOnlyRelayout = false
    /// `hover.rs::HoverHold` (`Runtime/HoverHold.swift`).
    internal var hoverHold = HoverHold()
    /// Per scroll viewport path: the hover hold an app's instant scroll armed (`ScrollState::nudge`).
    internal var scrollNudges: [String: ScrollNudge] = [:]
    /// Per scroll viewport path: where an offset request's glides were sent (`ScrollOffsetRequests.swift`).
    internal var scrollOffsetAims: [String: ScrollOffsetAims] = [:]
    /// The node ids the last build drew, in order (`Runtime::built_ids`): hover tracks retarget
    /// only against geometry built for these nodes.
    internal var builtHoverIds: [NodeId] = []
    internal var hoverOrderMatchesPaint = false
    internal var hoverWithinPaths: [String] = []
    internal var hoverDelays = HoverDelays()
    internal var hoverPaused: Bool = false
    internal var slice2State = Slice2RuntimeState()
    private var lastScrollTickTime: Double? = nil

    // Live property tracking `(path, target) -> lastSeenSequence`
    internal struct LiveKey: Hashable {
        var path: String
        var target: BoundLiveProperty.Target
        var id: NodeId { NodeId.hash("live:\(path):\(target)") }
    }
    private var liveSeenSeq: [LiveKey: (sourceId: UInt64, sequence: UInt64)] = [:]
    private struct LiveTweenStart {
        weak var source: LiveSource?
        let time: Double
    }
    private var liveTweenStarts: [UInt64: LiveTweenStart] = [:]
    private var livePulseRelease: [LiveKey: (releaseAt: Double, rest: MotionLanes, spring: Spring)] = [:]
    internal var liveColorTargets: [NodeId: Color] = [:]
    private var customLiveWaker: Waker? = nil
    internal let liveLane: LiveLane
    internal var liveSubscriptions: [LiveSubscription] = []
    /// Live labels and positions can change without a view commit.
    internal private(set) var accessibilityLiveRevision: UInt64 = 0

    internal struct VirtualInputEntry {
        var path: String
        var key: String?
        var rowKey: String
        var el: El<State>
    }
    internal var virtualInputs: [String: VirtualInputEntry] = [:]

    internal var flatNodes: [FlatNode] = []
    internal var nativePaintTopology: NativePaintTopology?
    private var alternatePaintTopology: NativePaintTopology?
    internal var paintHitScopes: [RenderHitScope] = []
    internal var paintGlyphFixups: [GlyphUVFixup] = []
    internal var lastPaintInstanceCount = 0
    internal var spareElementReports: [NativeElementReport<State>] = []
    internal var spareFlatNodes: [FlatNode] = []
    internal var replayedFlatMemoNodes: Int { flatMemoPaths.values.reduce(0) { $0 + $1.replayedNodes } }
    internal var replayedVirtualFlatRoots: Int { flatMemoPaths.values.count(where: \.replayedRowRoot) }
    private var flatMemoPaths: [NodeId: FlatMemoPaths<State>] = [:]
    internal var nodeByPath: [String: Int] = [:]
    internal var nodeIndexById: [NodeId: Int] = [:]

    /// Resolve the ID against the current mounted tree, including in-place scroll and live changes.
    @inline(__always)
    internal func mountedNode(_ id: NodeId) -> FlatNode? {
        guard let index = nodeIndexById[id] else { return nil }
        return flatNodes[index]
    }
    /// The last mounted state of nodes removed from the current tree, retained until their exit finishes.
    internal var exitingSnapshots: [NodeId: FlatNode] = [:]
    private var materializedElements: [ElementInfo] = []
    internal var nativeElementReports: [NativeElementReport<State>]?
    internal var lastElements: [ElementInfo] {
        get {
            materializeElementReports()
            return materializedElements
        }
        set {
            nativeElementReports = nil
            materializedElements = newValue
        }
        _modify {
            materializeElementReports()
            yield &materializedElements
        }
    }

    private func materializeElementReports() {
        guard let reports = nativeElementReports else { return }
        let poses = nativeInspection?.rawPoseByPath ?? [:]
        materializedElements = NativeElementReport.materialize(reports, poses: poses)
        nativeElementReports = nil
    }

    internal func publishElementReports(_ reports: [NativeElementReport<State>]) {
        materializedElements = []
        var previous = nativeElementReports
        nativeElementReports = reports
        if var previous = previous.take(), previous.capacity / 4 <= max(64, reports.count) {
            // Keep only the allocation. Departed elements may own user callbacks.
            previous.removeAll(keepingCapacity: true)
            spareElementReports = previous
        }
    }
    internal var accessibilityProjectionCache: AccessibilityProjectionCache?
    internal var presentedRectByPath = FrameGeometry<MotionRect>()
    internal var presentedScales = PresentedScales()
    internal var pickCandidates = RepeatedPickCandidates()
    internal var hitGeometryByPath = FrameGeometry<HitGeometry>() {
        didSet { pickCandidates = RepeatedPickCandidates() }
    }
    internal var paintOrderPaths: [String] = [] {
        didSet { pickCandidates = RepeatedPickCandidates() }
    }
    /// Atlas-space coverage adjustments collected only while a motion gate is recording.
    internal var motionRasterGlyphs: MotionGateRasterGlyphs?
    internal var imagePacker = ImageAtlasPacker()
    private var imagePlayback = ImagePlayback()
    private var shownPixelIDs: Set<UInt64> = []
    internal var fieldSpelling = FieldSpelling()
    private var nextImageWake: Double?
    internal let residentCacheTracker = ResidentLayerTracker()
    internal var retainedLayout = RetainedLayoutCoordinator()
    #if DEBUG
    internal private(set) var fixedVirtualLayoutRetries = 0
    #endif
    internal var needsCommit: Bool = true
    internal var virtualFillNeedsCommit: Bool = false
    internal var forceInitialSettle: Bool = true
    internal var lastWasSettled: Bool = false
    private var activeExplicitSettleCut: Bool = false
    internal var pendingEventTime: Double? = nil

    /// Whether the most recently presented frame included a settling cut (`Runtime::settled`).
    public var settled: Bool { lastWasSettled }

    /// Current animation time scale for the view (`Runtime::time_scale`).
    public var timeScale: Float { cxSettings.viewTimeScale }
    private var prevRevealedSecureIds: Set<NodeId> = []
    private var lastSecureMaskInfo: [NodeId: (count: Int, multiline: Bool)] = [:]

    internal func recordEvent(_ entry: String) {
        events.append(entry)
        if events.count > 512 {
            events.removeFirst(events.count - 512)
        }
    }

    private func retainDepartingSnapshots(_ pass: MeasurePassResult) {
        let liveNodes = pass.indexById
        for nid in exitingSnapshots.keys where liveNodes[nid] != nil {
            exitingSnapshots.removeValue(forKey: nid)
        }
        // Replayed descendants are known to still be present. Their previous order may
        // differ from the new order when a keyed subtree moves.
        var retained = pass.reusedFlatRanges.map(\.previous)
        if !retained.indices.dropFirst().allSatisfy({ retained[$0 - 1].lowerBound < retained[$0].lowerBound }) {
            retained.sort { $0.lowerBound < $1.lowerBound }
        }
        var rangeIndex = 0
        var cursor = 0
        while cursor < flatNodes.count {
            if rangeIndex < retained.count, cursor == retained[rangeIndex].lowerBound {
                cursor = retained[rangeIndex].upperBound
                rangeIndex += 1
                continue
            }
            let i = cursor
            cursor += 1
            let nid = flatNodes[i].nodeId
            guard liveNodes[nid] == nil else { continue }
            var snap = flatNodes[i]
            // An exit may outlive this commit. Keep its own subtree and release unrelated siblings.
            if snap.element.hasSiblings {
                snap.element.detachFromSiblings()
            }
            let prevInfo = lastSecureMaskInfo.removeValue(forKey: nid)
            // An exiting node's edit accessor may point at state that no longer exists (a deleted
            // row's `\.rows[i]`, `pointer_hit.rs:111`): never read it. Every live secure node recorded
            // its mask in `lastSecureMaskInfo` on its last commit, so `prevInfo` covers `TextEdit.isSecure`.
            let isSec = snap.el.isSecure || prevInfo != nil
            if isSec {
                exitingTextLayouts.removeValue(forKey: nid)
                snap.el.isRevealed = false
                snap.el.liveText = nil
                snap.el.richSpans = nil
                snap.el.handlers.editLens = nil
                if let prevInfo {
                    snap.el.plainText = prevInfo.multiline
                        ? TextEdit.multilineSecureMask
                        : String(repeating: "•", count: prevInfo.count)
                } else if let raw = snap.el.plainText {
                    snap.el.plainText = raw.isEmpty ? "" : TextEdit.multilineSecureMask
                } else {
                    snap.el.plainText = TextEdit.multilineSecureMask
                }
            }
            exitingSnapshots[nid] = snap
        }
    }

    // Layout read, feedback circuit breaker, and layout/drawn/visible reporting state
    private enum LayoutQueueKind: Equatable {
        case layout
        case screenLayout
        case drawnLayout
        case visible
        case visibleRows
    }
    private struct PendingLayoutAction {
        var kind: LayoutQueueKind
        var nodePath: String
        var rect: [Float]
        var visible: Bool
        var external: Bool
        var rows: Range<Int> = 0..<0
    }
    public private(set) var windowOrigin: Vec2 = .zero
    private var windowPixels: (Int32, Int32)?
    internal var documentPage: RuntimeDocumentPage?
    private var pendingLayoutActions: [PendingLayoutAction] = []
    private var pendingLayoutFeedbackRan: Bool = false
    private var pendingExternalLayoutActionRan: Bool = false
    internal var layoutSeen = LayoutSeenState()
    private var layoutKeyIndex = LayoutKeyIndex()
    private(set) var layoutCommitGen: UInt64 = 0
    private var layoutFeedback = LayoutFeedback.initial
    internal var hasExternalDirtyCommit: Bool = true
    internal var scrollMovedSinceLastFrame: Bool = false
    internal struct LayoutObservers {
        var laidOut: [Int] = []
        var drawn: [Int] = []
        var drawnRect: [Int] = []
        var visible: [Int] = []
        var visibleRows: [Int] = []
        var scrollReports: [Int] = []
        var scrollAnchors: [Int] = []
        var bottomViewports: [Int] = []
        var bottomChildren: [Int: [Int]] = [:]
        var liveSources: [Int] = []
        var focusRequests: [Int] = []
        var focusSelected: [Int] = []
        var revealSelected: [Int] = []
        var focusReturns: [Int] = []
        var focusFollowsSelection: [Int] = []
        var autofocus: [Int] = []
        var selectionChanges: [Int] = []
        var hoverTracks: [Int] = []
        var pressColors: [Int] = []
        var pressScales: [Int] = []
        var hoverGroups: [Int] = []
        var hoverChanges: [Int] = []
        var kitHoverDelays: [Int] = []
        var hasHoverCurves = false
        var inputPills: [Int] = []
        var groupOpacity: [Int] = []
        var rideTrailing: Set<NodeId> = []
        var matchedFlights: [Int] = []
        var heldLandingWidths: [Int] = []
        var wordReveals: [Int] = []
        var filterContainers: [Int] = []
        var growthStacks: [Int] = []
        var extraCommitColors: [Int] = []
        var hasTimeScales = false
        var hasShadows = false
        var hasChildExits = false

        var authored: [LayoutObserverTraits] = []
    }
    internal private(set) var layoutObservers = LayoutObservers()
    private var layoutFired: [NodeId: [Float]] = [:]
    private var screenFired: [NodeId: [Float]] = [:]
    private var drawnFired: [NodeId: (drawn: [Float], laid: [Float])] = [:]
    private var visibleFired: [NodeId: Bool] = [:]
    internal var drawnRectByPath = FrameGeometry<MotionRect>()
    internal var rectSpringingById: [NodeId: Bool] = [:]
    internal var lastCommittedSpecs: [NodeSpec] = []
    internal var lastFrameOutput: FrameOutput? = nil
    public internal(set) var liveOnlyEvents: UInt64 = 0
    public var liveOnlySkips: UInt64 { liveOnlyEvents }
    public internal(set) var liveChecks: UInt64 = 0
    public var commitWhy: UInt16 = 0
    /// `CommitWhy` bits asked for since the last commit, which `commitFor` takes (`CommitWatch.swift`).
    internal var commitWhyPending: UInt16 = CommitWhy.dirty  // a new runtime starts dirty (`dirty: true`)
    public internal(set) var liveOnlyWarnings: [String] = []
    internal var liveOnlyCheckEnabled: Bool = true
    internal var lastLiveCommitClock: Double = -.infinity
    internal var pendingLiveOnlyCheck: (handler: String, before: LiveOnlyViewPrint)? = nil
    internal var checkingLiveOnly: Bool = false
    internal var stateUnchangedSinceBuild: Bool = false
    internal var pendingResizeRelayout: Bool = false
    internal var pendingGrowthRelayout: Bool = false
    internal var resizeReadMovedFlag: Bool = false
    internal var hasActiveExitingNodes: Bool = false
    internal var cachedResizeBuild: ResizeCachedViewBuild<State>? = nil
    internal var virtualSelectionSources: [String: VirtualSelectionSource] = [:]
    internal var lastViewMemoEnvHash: UInt64 = MemoScope.currentEnvironmentHash()
    internal var lastViewOnlyMemoIds: Set<String> = []
    private var spareMotionSpecs: [NodeSpec] = []

    public convenience init(
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
        self.init(state: state, viewport: viewport, pixelScale: pixelScale, systemDark: systemDark,
                  reducedMotion: reducedMotion, textSystem: textSystem, waker: waker, onKey: onKey,
                  runtimeId: RuntimeIdScope.nextId(), view: view)
        textPreparation = WindowTextPreparation(id: runtimeId, stateType: State.self)
        textSystem.initializeWindowFontFamilies()
        if !MediaPlaybackGate.isEnabled {
            Recorder.headlessReset()
            VideoHeadless.reset()
            HeadlessClock.set(0.0)
        }
    }

    /// Creates the layout and scene state without initializing process-wide window services.
    /// A speculative measurement borrows the window's existing text system and runtime ID.
    internal init(
        state: State, viewport: Vec2, pixelScale: Float, systemDark: Bool, reducedMotion: Bool,
        textSystem: TextSystem, waker: Waker, onKey: KeyHandlerFn?, runtimeId: UInt64,
        view: @escaping ViewFn
    ) {
        self.state = state
        self.view = view
        self.globalOnKey = onKey
        self.runtimeId = runtimeId
        self.viewport = viewport
        self.pixelScale = max(pixelScale, 0.5)
        self.systemDark = systemDark
        self.reducedMotion = reducedMotion
        self.textSystem = textSystem
        self.waker = waker
        let defaultWaker = waker
        self.liveLane = LiveLane(waker: LiveWake { [weak defaultWaker] in defaultWaker?.wake() })
        self.scene = Scene(pixelScale: pixelScale, reducedMotion: reducedMotion)
        self.scrollStore = AnimationStore(pixelScale: pixelScale, reducedMotion: reducedMotion)
        self.liveStore = AnimationStore(pixelScale: pixelScale, reducedMotion: reducedMotion)
        self.cxSettings = RuntimeShellSettings(viewport: viewport, pixelScale: pixelScale, reducedMotion: reducedMotion)
    }

    deinit {
        for sub in liveSubscriptions {
            sub.isActive = false
        }
    }

    public func elements() -> [ElementInfo] {
        if nativeInspection?.hasInheritedFlags == true { materializeNativeInspection(motionElements: false) }
        if nativeInspection?.a11yMaterialized == false {
            for i in lastElements.indices { completeNativeAccessibilityRecord(&lastElements[i]) }
            nativeInspection?.a11yMaterialized = true
        }
        return lastElements
    }

    public func element(byKey key: String) -> ElementInfo? {
        if nativeInspection?.hasInheritedFlags == true { materializeNativeInspection(motionElements: false) }
        guard var info = firstReportedElement(where: { !$0.exiting && selectsElementSelector(key, path: $0.path, key: $0.key) })
            ?? firstReportedElement(where: { selectsElementSelector(key, path: $0.path, key: $0.key) }) else { return nil }
        if nativeInspection?.a11yMaterialized == false { completeNativeAccessibilityRecord(&info) }
        return info
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
        return firstReportedElement(where: { $0.path == path })?.secure ?? false
    }

    /// Centre of the first non-exiting element matching `key` (or slash-path like `"slider/knob"`),
    /// in logical window points. Matches `crates/rune/src/runtime/elements.rs:389`.
    public func find(_ key: String) -> Vec2? {
        guard let el = firstReportedElement(where: { !$0.exiting && selectsElementSelector(key, path: $0.path, key: $0.key) }),
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
            guard let found = firstReportedElement(where: { selectsElementSelector(within, path: $0.path, key: $0.key) }) else {
                return nil
            }
            scopePath = found.path
        } else {
            scopePath = nil
        }

        let pt = Vec2(x, y)
        let paths = pickCandidates.paths(at: pt, viewport: viewport, order: paintOrderPaths, geometry: hitGeometryByPath)
        for path in paths.reversed() {
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
                ?? firstReportedElement(where: { $0.path == path })?.key
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
        guard let el = firstReportedElement(where: { selectsElementSelector(key, path: $0.path, key: $0.key) }),
              let geom = hitGeometryByPath[el.path],
              !geom.isExiting,
              (pick.includeTransparent || geom.opacity > 0.001) else {
            return false
        }
        return geom.contains(Vec2(x, y))
    }

    public func markNeedsCommit(settle: Bool = false, external: Bool = true) {
        needsCommit = true
        if external {
            hasExternalDirtyCommit = true
            stateUnchangedSinceBuild = false
            pendingResizeRelayout = false
            pendingGrowthRelayout = false
        }
        commitWhyPending |= CommitWhy.dirty
        pendingEventTime = nil
        if settle {
            forceInitialSettle = true
            explicitSettleRequested = true
        }
    }

    /// Whether a layout/view re-evaluation commit is currently pending.
    public var hasPendingCommit: Bool { needsCommit || textSystem.windowFontFamiliesBehind }

    /// Whether any deferred layout or paint observer callbacks await the next frame.
    public var hasPendingActions: Bool { !pendingLayoutActions.isEmpty || !pendingPaintHovers.isEmpty }

    /// Supplies the native content origin in physical desktop pixels for drag reports.
    public func setWindowPixels(_ origin: (Int32, Int32)?) {
        windowPixels = origin
    }

    internal func screenPixels(at point: Vec2) -> (Int32, Int32)? {
        guard let (x, y) = windowPixels else { return nil }
        func pixel(_ coordinate: Float, origin: Int32) -> Int32 {
            let offset = (coordinate * inputScale()).rounded()
            let value = Double(origin) + (offset.isNaN ? 0 : Double(offset))
            return Int32(max(Double(Int32.min), min(Double(Int32.max), value)))
        }
        return (pixel(point.x, origin: x), pixel(point.y, origin: y))
    }

    /// Host window content origin in global screen points. Reopens layout feedback and queues
    /// `onScreenLayout` without forcing a relayout; returns `true` when any handler queued.
    @discardableResult
    public func setWindowOrigin(_ origin: Vec2) -> Bool {
        guard windowOrigin != origin else { return false }
        windowOrigin = origin
        layoutFeedback.step(.reopened)
        return reportLayoutAndScreen(reportLocal: false, reportScreen: true)
    }

    /// The root's world rect includes the browser canvas's document translation.
    internal var rootPixelSnap: PixelSnap.Inherit {
        var snap = PixelSnap.Inherit()
        if let page = documentPage { snap.scroll(1, by: -page.top) }
        return snap
    }

    /// Presented hit-test boxes in logical window points for non-inert `.hit()` elements.
    public func overlayInteractiveRegions() -> [MotionRect] {
        var regions: [MotionRect] = []
        let zoom = zoom()
        for node in flatNodes {
            if node.effectiveInert || !node.el.isHit { continue }
            let infoRect = presentedRectByPath[node.path] ?? node.targetRect
            let hitBox = intersectRects(node.clipRect, infoRect)
            if hitBox.width > 0 && hitBox.height > 0 {
                regions.append(zoom == 1 ? hitBox : hitBox.scaled(by: zoom))
            }
        }
        return regions
    }

    /// True when the primary hit target at `point` is a bare `.windowDrag()` region with no
    /// interactive press/double-press/drag/dragOut/textbox behavior (`titlebar::bare_drag_region`).
    public func isBareTitlebarDragRegion(at point: Vec2) -> Bool {
        guard let hit = hitTest(at: point, predicate: { node in
            let h = node.el.handlers
            return node.el.isWindowDrag ||
                node.el.explicitHit ||
                node.el.isModal ||
                node.el.pressBg != nil ||
                node.el.pressScaleFactor != nil ||
                node.el.pressFocusesBelow ||
                self.nodeTakesFocus(node.el) ||
                h.onClick != nil ||
                h.onClickPress != nil ||
                h.onBackgroundPress != nil ||
                h.onDoubleClick != nil ||
                h.onSecondaryClick != nil ||
                h.onPointerDown != nil ||
                h.onDrag != nil ||
                h.dragOut != nil ||
                node.el.attachedDragOutItem != nil ||
                h.editLens != nil ||
                node.el.role == .textInput ||
                node.el.runtimeExtra("dragOut") != nil
        }) else { return false }
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
            node.el.runtimeExtra("dragOut") == nil &&
            node.el.role != .textInput
    }

    /// Earliest future wall-clock timestamp when an active `enterDelay`, tooltip wait, or `looping`/`cycle` animation needs a frame.
    public func nextWakeDeadline(after now: Double) -> Double? {
        nextWakeDeadline(after: now, includePaint: true)
    }

    internal func nextWakeDeadline(after now: Double, includePaint: Bool, includeLoops: Bool = true) -> Double? {
        var best: Double?
        if includePaint {
            best = nextVideoWake.map { max($0, now) }
            if slice2State.autoscroll.wantsFrame { best = min(best ?? now, now) }
            if let spellingWake = fieldSpelling.watch?.wakeAt {
                best = min(best ?? .infinity, max(now, spellingWake))
            }
            if liveVisible, cxSettings.viewTimeScale > 0, let due = nextImageWake {
                best = min(best ?? .infinity, max(now, due))
            }
        }
        if let storeWake = scene.store.waitingUntil() {
            let scale = Double(cxSettings.viewTimeScale)
            if scale > 0 {
                let scaledNow = cxSettings.scaledTime(at: now)
                let wallWake = now + max(0.0, storeWake - scaledNow) / scale
                if wallWake > now {
                    best = best.map { min($0, wallWake) } ?? wallWake
                }
            }
        }
        if case .waiting(_, let since) = helpState.tipState {
            let due = since + currentHelpDelays().open
            if due > now {
                best = best.map { min($0, due) } ?? due
            }
        }
        if let hoverDue = hoverDelays.nextDue(), hoverDue > now {
            best = best.map { min($0, hoverDue) } ?? hoverDue
        }
        if let nudgeDue = scrollNudgeWakeDeadline(after: now) {
            best = best.map { min($0, nudgeDue) } ?? nudgeDue
        }
        if includeLoops, let loopWake = nextLoopWakeDeadline(after: now) {
            best = best.map { min($0, loopWake) } ?? loopWake
        }
        if let fillDue = virtualFill.armedWake?.due, fillDue > now {
            best = best.map { min($0, fillDue) } ?? fillDue
        }
        if let edgeWake = nextSelectableEdgeScrollWakeDeadline(after: now) {
            best = best.map { min($0, edgeWake) } ?? edgeWake
        }
        if let pgDue = playgroundNextWakeDeadline(after: now) {
            best = best.map { min($0, pgDue) } ?? pgDue
        }
        if let explicit = self.nextWakeDeadline, explicit >= now {
            best = best.map { min($0, explicit) } ?? explicit
        }
        if let kitDue = kitNextWakeDeadline(after: now) {
            best = best.map { min($0, kitDue) } ?? kitDue
        }
        return best
    }

    @inline(__always)
    internal func dirtyCommit(
        at now: Double,
        external: Bool = true,
        clearLiveCheck: Bool = true,
        why: UInt16 = CommitWhy.dirty,
        inputChange: Bool = true
    ) {
        if clearLiveCheck {
            pendingLiveOnlyCheck = nil
        }
        commitWhyPending |= why
        needsCommit = true
        if external {
            // A state change inside an input entry point is that input's (`r`, #970); a press's
            // own visuals and selection drags (`inputChange: false`) are not.
            if inputChange { noteHandlerChange() }
            hasExternalDirtyCommit = true
            stateUnchangedSinceBuild = false
            pendingResizeRelayout = false
            pendingGrowthRelayout = false
        }
        pendingEventTime = now
    }

    /// Evaluates view + layout (if dirty), steps `Scene` & `Live` animations at `now`,
    /// updates `elements()`, and emits the complete `RefScene` primitive stream!
    @discardableResult
    public func frame(at now: Double) -> RefScene {
        RuntimeIdScope.$current.withValue(runtimeId) {
            Theme.withBlend(srgbBlend) {
                frameWithBlendScope(at: wallClock() ?? now)
            }
        }
    }

    internal func runFrameSplit(catchUp: Double, dt: Double, hostDelta: Double) -> Bool {
        let elapsed = max(0.0, hostDelta)
        if wallStart == nil {
            let target = currentTime + elapsed
            if nextTimerStepDeadline(before: target) != nil {
                var remainingCatchUp = max(0.0, catchUp)
                while let at = nextTimerStepDeadline(before: target) {
                    let step = max(0.0, at - currentTime)
                    let old = min(step, remainingCatchUp)
                    remainingCatchUp -= old
                    _ = runSingleFrameSplitPass(at: at, catchUp: old, dt: step - old, hostDelta: step)
                }
                let finalStep = max(0.0, target - currentTime)
                let finalOld = min(finalStep, remainingCatchUp)
                return runSingleFrameSplitPass(
                    at: target,
                    catchUp: finalOld,
                    dt: finalStep - finalOld,
                    hostDelta: finalStep
                )
            }
        }
        return runSingleFrameSplitPass(
            at: wallClock() ?? (currentTime + elapsed),
            catchUp: catchUp,
            dt: dt,
            hostDelta: hostDelta
        )
    }

    private func runSingleFrameSplitPass(
        at now: Double,
        catchUp: Double,
        dt: Double,
        hostDelta: Double
    ) -> Bool {
        _ = RuntimeIdScope.$current.withValue(runtimeId) {
            Theme.withBlend(srgbBlend) {
                frameWithBlendScope(
                    at: now,
                    split: (catchUp: catchUp, dt: dt, hostDelta: hostDelta)
                )
            }
        }
        return isAnimating
    }

    internal func delayStartedTracks(_ ids: inout [TrackId], by secs: Double) {
        scene.store.delay(&ids, by: secs)
    }

    private func frameWithBlendScope(
        at now: Double,
        split: (catchUp: Double, dt: Double, hostDelta: Double)? = nil
    ) -> RefScene {
        lastWasSettled = false
        let wasQuiet = !frameHadInputSinceLastFrame && !isAnimating
        let timer = beginFrameTimers(at: now)
        let pendingDue = pendingUpdateWakes.contains { ($0.scheduledAt + $0.delay) <= now }
        let dueTimer = timer.due || pendingDue
        let wasLive = frameHadLiveWake
        // The input cause is input that changed the model (`if r { why |= INPUT }`), not any
        // input's arrival; arrival alone only ends the frame's quiet.
        frameCommittedFromInput = frameInputCauseSinceLastFrame
        frameInputCauseSinceLastFrame = false
        frameHadInputSinceLastFrame = false
        // A new frame, a new queue: an ask the last one's split made owed is owed like any other.
        focusOwedFromSplit = false
        frameHadLiveWake = false
        frameHadCommitted = false
        frameInstantScrollKey = nil
        perfWatch.idle.begins(quiet: wasQuiet, timer: dueTimer, live: wasLive)
        let interactionStart = interactionFrameBegins()

        flushPendingKeysLost(at: now)
        let splitStep: (catchUpAnimNow: Double, dt: Double)?
        if let split {
            let scale = Double(cxSettings.viewTimeScale)
            let catchUpAnimNow = lastScaledAnimNow + max(0.0, split.catchUp) * scale
            if split.catchUp > 0.0 {
                scene.setTime(catchUpAnimNow)
                scrollStore.sample(at: catchUpAnimNow)
                liveStore.sample(at: catchUpAnimNow)
            }
            cxSettings.setSplitAnchor(hostTime: now, animTime: catchUpAnimNow)
            lastScaledAnimNow = catchUpAnimNow
            pendingEventTime = nil
            splitStep = (catchUpAnimNow: catchUpAnimNow, dt: split.dt)
        } else {
            splitStep = nil
        }

        let frameStartShapedCount = textSystem.shapedCallCount
        var (frameOut, animNow) = stepToFrameOutputScaled(
            at: now,
            splitStep: splitStep,
            skipFramePoll: timer.alreadyPolled
        )
        var sceneOut = measureRuntimePhase(.paint) {
            buildRefScene(frameOut: frameOut, now: animNow, startShapedCount: frameStartShapedCount)
        }
        if cxSettings.caretReadByView,
           let nextCaret = currentFocusedCaret(),
           cxSettings.lastCommittedCaret?.keyPath != nextCaret.keyPath || cxSettings.lastCommittedCaret?.rect != nextCaret.rect {
            needsCommit = true
            // frame.rs:632: a moved caret the view reads marks the state dirty.
            commitWhyPending |= CommitWhy.dirty
            (frameOut, animNow) = stepToFrameOutputScaled(at: now)
            sceneOut = measureRuntimePhase(.paint) {
                buildRefScene(frameOut: frameOut, now: animNow)
            }
        }
        if frameHadCommitted {
            textSystem.pruneUnusedElisions()
        }
        for _ in 0..<3 {
            if !followKeeps(frameOut: &frameOut, at: animNow) { break }
            sceneOut = measureRuntimePhase(.paint) {
                buildRefScene(frameOut: frameOut, now: animNow)
            }
        }
        lastFrameOutput = frameOut
        frameMovedScrollPaths.removeAll(keepingCapacity: true)
        frameLandingHoldIds.removeAll(keepingCapacity: true)
        finishKeeps(cut: false)
        finishPostFrameHooks(at: now)
        if rewindRecorder != nil {
            captureRewindFrame(at: now)
        }
        let wasScrolling = frameHadScrollSinceLastFrame || scrollMovedSinceLastFrame || scrollStore.isAnimating
        frameHadScrollSinceLastFrame = false
        perfWatch.meter.frameEnds(scrolling: wasScrolling, committed: frameHadCommitted, instantKey: frameInstantScrollKey)
        if PerfWarn.isEnabled {
            perfWatch.idle.observeFrame(
                clock: now,
                animating: isAnimating,
                drawn: makeIdleDrawnSnapshot(sceneOut),
                windowName: windowTitle
            )
        }
        if let interactionStart { interactionBuilt(shapedSince: interactionStart) }
        return sceneOut
    }

    internal func finishSurfaceVideoPaint(_ paint: SurfaceVideoPaint) {
        videoSignature = paint.signature
        lastVideoSnapshots = paint.snapshots
        nextVideoWake = paint.nextWake
        if paint.active {
            animSources |= AnimSource.video
        } else {
            animSources &= ~AnimSource.video
        }
    }

    internal func finishPostFrameHooks(at now: Double) {
        defer { notePrimarySelection() }
        let wroteDrawn = writeDrawnRects()
        _ = reportLayoutAndScreen(reportLocal: true, reportScreen: true)
        _ = reportDrawn()
        _ = reportVisible()
        let (postFeedback, postExternal) = drainLayoutActions(at: now)
        let reportedRows = reportVirtualVisibleRows()
        pendingLayoutFeedbackRan = pendingLayoutFeedbackRan || postFeedback
        pendingExternalLayoutActionRan = pendingExternalLayoutActionRan || postExternal
        let scaleSettleMoving = hasMovingScaleSettle
        if (pixelSnapGlides.isEasing || scaleSettleMoving) && cxSettings.viewTimeScale > 0.0 {
            animSources |= AnimSource.scaleSettle
        } else {
            animSources &= ~AnimSource.scaleSettle
        }
        if fillText() { animSources |= AnimSource.textFill }
        isAnimating = reportedRows || animSources != 0 || ((pixelSnapGlides.isEasing || wroteDrawn || scaleSettleMoving) && cxSettings.viewTimeScale > 0.0)
        if !isAnimating {
            animSources = 0
        }
        if layoutFeedback.isOpen && memo.hasInvalidatedReads(computing: { currentMemoGeometry() }) {
            needsCommit = true
            commitWhyPending |= CommitWhy.read
            resizeReadMovedFlag = true
        }
        if cxSettings.caretReadByView,
           let nextCaret = currentFocusedCaret(),
           cxSettings.lastCommittedCaret?.keyPath != nextCaret.keyPath || cxSettings.lastCommittedCaret?.rect != nextCaret.rect {
            needsCommit = true
            commitWhyPending |= CommitWhy.dirty
            resizeReadMovedFlag = true
        }
        if cxSettings.selectionRectsReadByView,
           SelectionRectsMath.boxesMoved(cxSettings.lastCommittedSelectionRects, computeSelectionBoxes()) {
            needsCommit = true
            // layout_read.rs:446: moved selection rects the view reads mark the state dirty.
            commitWhyPending |= CommitWhy.dirty
        }
    }

    private func makeIdleDrawnSnapshot(_ scene: RefScene) -> IdleMeter.DrawnSnapshot {
        var data: [UInt8] = []
        data.reserveCapacity(32 + scene.primitives.count * 32)
        func appendBits(_ f: Float) {
            var bits = f.bitPattern
            for _ in 0..<4 {
                data.append(UInt8(bits & 0xFF))
                bits >>= 8
            }
        }
        func appendVec4(_ v: SIMD4<Float>) {
            appendBits(v.x); appendBits(v.y); appendBits(v.z); appendBits(v.w)
        }
        appendBits(Float(scene.width))
        appendBits(Float(scene.height))
        appendVec4(scene.clearColor)
        for p in scene.primitives {
            appendVec4(p.rect)
            appendVec4(p.fill)
            appendVec4(p.border)
            appendVec4(p.params)
            appendVec4(p.uv)
            appendVec4(p.clip)
        }
        let glyphBytes = scene.glyphPages.isEmpty ? scene.glyphs.texels.count : scene.glyphPages.reduce(0) { $0 + $1.texels.count }
        var surfaceKey: UInt64 = UInt64(glyphBytes) &* 0x9e37_79b9_7f4a_7c15
        surfaceKey ^= UInt64(imagePacker.revision) &* 0xbf58_476d_1ce4_e5b9
        return IdleMeter.DrawnSnapshot(
            instances: data,
            surfaceKey: surfaceKey,
            opaque: !surfaces.isEmpty || !lastVideoSnapshots.isEmpty
        )
    }

    internal func interactionFrameBegins() -> Int? {
        guard InteractionGate.isOn else { return nil }
        let nowNs = RuneExecutionContext.uptimeNanoseconds
        let queued = queuedInputWaiting || hasPendingInput
        let cpuMs = queued ? PerfWarn.threadCpuMs() : nil
        if let finished = perfWatch.interaction.frameBegins(queued: queued, nowNs: nowNs, cpuMs: cpuMs) {
            handleInteractionFinished(finished)
        }
        return textSystem.shapedCount
    }

    internal func interactionBuilt(shapedSince start: Int) {
        let nowNs = RuneExecutionContext.uptimeNanoseconds
        let cpuMs = perfWatch.interaction.isPhaseCollectionActive ? PerfWarn.threadCpuMs() : nil
        if let slowFrame = perfWatch.interaction.built(
            shaped: UInt32(clamping: max(0, textSystem.shapedCount - start)),
            nodes: flatNodes.count,
            nowNs: nowNs,
            cpuMs: cpuMs,
            stacks: nil
        ) {
            InteractionTracker.slowFrameReports.append(slowFrame)
        }
    }

    /// Closes the measured interaction when the native presenter accepts a frame.
    /// A display-link target is a prediction. A drawable's observed presentation is traced separately.
    internal func interactionSubmitted(at submitted: Double? = nil, target: Double? = nil) {
        guard InteractionGate.isOn else { return }
        func nanoseconds(_ seconds: Double) -> UInt64? {
            UInt64(exactly: (seconds * 1_000_000_000).rounded())
        }
        interactionPresented(submittedNs: submitted.flatMap(nanoseconds) ?? RuneExecutionContext.uptimeNanoseconds,
                             presentsAtNs: target.flatMap(nanoseconds))
    }

    public func interactionPresented(
        submittedNs: UInt64 = RuneExecutionContext.uptimeNanoseconds,
        presentsAtNs: UInt64? = nil,
        slowMs: Double = InteractionTracker.defaultSlowMs,
        overloaded: Bool = false
    ) {
        guard InteractionGate.isOn else { return }
        if let finished = perfWatch.interaction.finish(
            submittedNs: submittedNs,
            presentsAtNs: presentsAtNs,
            slowMs: slowMs,
            overloaded: overloaded
        ) {
            handleInteractionFinished(finished)
        }
    }

    private func handleInteractionFinished(_ f: InteractionTracker.Finished) {
        if f.slow {
            let report = SlowInteractionReport(
                route: f.timed.note.route.text,
                control: f.timed.note.control.text,
                action: f.timed.note.action,
                arrivedNs: f.timed.arrivedNs,
                frameStartNs: f.timed.frameStartNs,
                builtNs: f.builtNs,
                submittedNs: f.submittedNs,
                presentNs: f.presentNs,
                handlerMs: f.timed.handlerMs,
                phases: f.phases,
                why: f.timed.why,
                commits: f.timed.commits,
                shaped: f.shaped,
                nodes: flatNodes.count,
                reused: 0,
                rebuilt: [],
                cpuMs: f.cpuMs,
                cause: f.cause ?? .queued,
                stacks: f.stacks
            )
            InteractionTracker.slowReports.append(report)
        }
        if let rollup = perfWatch.interaction.takeRollupIfDue(nowNs: f.presentNs, force: false) {
            InteractionTracker.rollupReports.append(rollup)
        }
    }

    private func interactionNote(action: String, rank: UInt8, path: String?) -> InteractionNote? {
        guard InteractionGate.isOn else { return nil }
        let names = perfWatch.interaction.names
        let control = path.map { names.control(path: $0) } ?? names.fixed("window")
        let route = names.route(page: nil, modal: nil)
        return InteractionNote(route: route, control: control, action: action, rank: rank)
    }

    internal func stepToFrameOutput(at now: Double) -> FrameOutput {
        stepToFrameOutputScaled(at: now).frameOut
    }

    @inline(never)
    private func preparePreCommitHooks(at now: Double, skipFramePoll: Bool = false) -> (
        ranLayoutFeedback: Bool,
        ranExternalLayoutAction: Bool,
        growthMoving: Bool,
        isInitiallyScrolling: Bool
    ) {
        currentTime = now
        // Each queued action runs with its own input's arrival time; nothing else has one (`frame.rs`).
        if !MediaPlaybackGate.isEnabled {
            HeadlessClock.set(now)
            Recorder.headlessFrame(clock: now)
            VideoHeadless.frame(at: now)
        }
        scrollStore.pixelScale = pixelScale
        liveStore.pixelScale = pixelScale
        insideFramePollOrInput = true
        fireMiddleAutoscroll(at: now)
        fireTouchHold(at: now)
        if !skipFramePoll {
            commitInputApartFromFramePoll(at: now, polls: poll != nil)
            if runPoll(at: now) { framePollChanged() }
        }
        frameTookDispatchedInput()
        dispatchPendingPaintHover(at: now)
        flushPlatformFrameWork(at: now)
        pollPlaygroundIfNeeded(at: now)
        applyPlaygroundIfNeeded(at: now)
        flushPendingPasteRequests(at: now)
        _ = reportVirtualVisibleRows()
        let (drainedFeedback, drainedExternal) = drainLayoutActions(at: now)
        let ranLayoutFeedback = pendingLayoutFeedbackRan || drainedFeedback
        let ranExternalLayoutAction = pendingExternalLayoutActionRan || drainedExternal
        pendingLayoutFeedbackRan = false
        pendingExternalLayoutActionRan = false

        if let attempt = virtualFill.wake(at: now) {
            if virtualFill.step(.due(attempt: attempt, now: now)) == .draw {
                needsCommit = true
                commitWhyPending |= CommitWhy.virtual
            }
        }
        stepKitDragRepeatOnFrame(at: now)
        stepKitHoverDelaysOnFrame(at: now)
        fireHoverDelays(at: now)
        flushPendingSentKeys(at: now)
        insideFramePollOrInput = false
        promotePendingWakes(at: now)

        for picture in pictureAspects {
            let size = picture.pixels.size
            let ratio = size.height > 0 ? Float(size.width) / Float(size.height) : 0
            if ratio != picture.ratio {
                pixelsAspectSnapIds.insert(picture.id)
                needsCommit = true
                commitWhyPending |= CommitWhy.relayout
            }
        }

        _ = stepSelectableEdgeScroll(at: now)
        let growthMoving = needsCommit ? false : advanceGrowthRows(at: now, headers: foldHeaders)
        let isInitiallyScrolling = scrollMovedSinceLastFrame || scrollStore.isAnimating
        if isInitiallyScrolling {
            layoutFeedback.step(.reopened)
        }
        return (ranLayoutFeedback, ranExternalLayoutAction, growthMoving, isInitiallyScrolling)
    }

    @inline(never)
    private func prepareAndCommitFrame(
        at now: Double,
        splitStep: (catchUpAnimNow: Double, dt: Double)? = nil,
        skipFramePoll: Bool = false
    ) -> (animNow: Double, prevAnimNow: Double, growthMoving: Bool) {
        let outerArrival = InputTime.swapArrival(nil)
        defer { InputTime.swapArrival(outerArrival) }
        let pre = preparePreCommitHooks(at: now, skipFramePoll: skipFramePoll)
        let ranLayoutFeedback = pre.ranLayoutFeedback
        let ranExternalLayoutAction = pre.ranExternalLayoutAction
        var growthMoving = pre.growthMoving
        let isInitiallyScrolling = pre.isInitiallyScrolling
        var didCommitThisFrame = false
        if needsCommit {
            let other = hasExternalDirtyCommit || ranExternalLayoutAction
            let feedback = ranLayoutFeedback
            if other || isInitiallyScrolling {
                layoutFeedback.step(.reopened)
            } else {
                layoutFeedback.step(.commit(feedback: feedback, other: other))
            }
            let commitAt = min(pendingEventTime ?? now, now)
            pendingEventTime = nil
            let shouldCut = forceInitialSettle
            let resizeSnap = userResizeNeedsCut
            userResizeNeedsCut = false
            needsCommit = false
            hasExternalDirtyCommit = false
            popupNeedsLayout = false
            forceInitialSettle = false
            let peekAnim = cxSettings.scaledTime(at: now)
            let holdNow = fitWindowState.frameHolds()
            let leadDt = (!holdNow && cxSettings.viewTimeScale > 0)
                ? max(0.0, peekAnim - lastScaledAnimNow) / Double(cxSettings.viewTimeScale)
                : 0.0
            elSliceRenderState.loopCatchUp.keepLoopsOnClock(
                hostNow: now,
                animNow: lastScaledAnimNow,
                leadDt: leadDt,
                timeScale: cxSettings.viewTimeScale,
                scene: scene,
                tracks: &loopRuntime.tracks
            )
            kitHooks.frameGrowthStepDt = 0
            pendingGrowthStepNow = now
            defer { pendingGrowthStepNow = nil }
            let why = takeFrameCommitWhy(settle: explicitSettleRequested, layout: ranLayoutFeedback, read: false)
            // A decode on its own reflows siblings at once. With an input or state change,
            // only the pictures that acquired a new aspect land at their measured size.
            pictureOnlyRelayout = !pixelsAspectSnapIds.isEmpty && why == CommitWhy.relayout && !other
            commitFor(why: why, at: commitAt, cut: shouldCut, resizeSnap: resizeSnap)
            pictureOnlyRelayout = false
            pixelsAspectSnapIds.removeAll(keepingCapacity: true)
            kitHooks.frameGrowthStepDt = 0
            reconcileDropHoverAfterCommit(at: now)
            flushHiddenDropSteps(at: now)
            _ = laidSelectableEdgeScroll(at: now)
            if needsCommit {
                // Landing a `scrollKeyTo` jump mounts virtual rows there; each landing re-commit
                // places it again from the new layout before the frame draws (`scroll_to_offsets`).
                // The first is the follow-up the main commit left pending (`commitFollowUp`).
                var recommits = 0
                repeat {
                    commitFollowUp(at: now)
                    _ = laidSelectableEdgeScroll(at: now)
                    recommits += 1
                } while needsCommit && ((scrollKeyLandings.awaiting && recommits < ScrollKeyLanding.maxRounds)
                    || (!virtualRevealLandings.isEmpty && recommits < 8))
                virtualRevealLandings.removeAll(keepingCapacity: true)
                needsCommit = false
                // What the follow-up commits left pending is dropped with them (upstream commits
                // it next frame): no cause outlives the commit it was for.
                commitWhyPending = 0
                hasExternalDirtyCommit = false
                popupNeedsLayout = false
            }
            growthMoving = !slice2State.liveContentSlides.slides.isEmpty || growthRows.values.contains { $0.track.moving }
                || growthStacks.values.contains { !$0.pendingHeights.isEmpty || !$0.closing.isEmpty || !$0.runs.isEmpty }
            didCommitThisFrame = true
        }
        if didCommitThisFrame {
            RuntimeMidFrameHook.current?()
        }
        if virtualFillNeedsCommit || virtualFillWantsDraw {
            virtualFillNeedsCommit = false
            virtualFillWantsDraw = false
            needsCommit = true
            commitWhyPending |= CommitWhy.virtual
        }

        // Advance scaled animation clock after any initial commit so `cx.timeScale(...)` takes effect on this frame
        let prevAnimNow = lastScaledAnimNow
        let nextAnimNow: Double
        if let splitStep {
            nextAnimNow = splitStep.catchUpAnimNow + max(0.0, splitStep.dt) * Double(cxSettings.viewTimeScale)
            cxSettings.setSplitAnchor(hostTime: now, animTime: nextAnimNow)
        } else {
            nextAnimNow = cxSettings.advanceClock(to: now)
        }
        let holdMotion = fitWindowState.frameHolds()
        let animNow = holdMotion ? prevAnimNow : nextAnimNow
        if !holdMotion {
            lastScaledAnimNow = animNow
        }
        syncMotionLoopClock(to: now, animNow: animNow)

        // Sample inertial scroll decay tracks and re-position scrolled rects without running views
        followShrinkingScrollEnds(at: prevAnimNow)
        followScrollOffsetAims(animNow: animNow)
        let scrollDt: Float = {
            let prev = lastScrollTickTime ?? now
            lastScrollTickTime = now
            return Float(max(0.0, min(0.1, now - prev)))
        }()
        let touchMoved = stepTouchScrollFrame(at: animNow, dt: scrollDt)
        scrollStore.sample(at: animNow)
        if !pendingScrollJumpPaths.isEmpty {
            scrollMovedByHand.formUnion(pendingScrollJumpPaths)
            pendingScrollJumpPaths.removeAll(keepingCapacity: true)
        }
        if scrollStore.isAnimating {
            var anyScrollMoved = false
            for (path, maxExt) in scrollMaxExtents {
                if isTouchOwning(path: path, horizontal: false) || isTouchOwning(path: path, horizontal: true) {
                    continue
                }
                let nid = NodeId.hash("scroll:" + path)
                if var cur = scrollStore.get(nid, Props.SCROLL) {
                    var wasGliding = false
                    if scrollGlidingPaths.contains(path), let landed = landScrollGlideLanes(path: path) {
                        // Upstream `offset.rs::glide_axis` (`LAND = 0.1`, `|v| < 40 * LAND`) lands
                        // each axis of a glide at its exact end on its own.
                        cur = landed.value
                        if landed.over {
                            scrollGlidingPaths.remove(path)
                            scrollOffsetAims.removeValue(forKey: path)
                            wasGliding = true
                        }
                    }
                    let clamped = Vec2(
                        cur.x.clamped(to: 0...maxExt.x),
                        cur.y.clamped(to: 0...maxExt.y)
                    )
                    if scrollOffsets[path] != clamped {
                        scrollOffsets[path] = clamped
                        frameMovedScrollPaths.insert(path)
                        if !wasGliding && !scrollGlidingPaths.contains(path) {
                            markScrollMovedByHand(path: path)
                        }
                        anyScrollMoved = true
                    }
                    if !scrollGlidingPaths.contains(path) || clamped != cur {
                        if maxExt.y > 0.5 && (maxExt.y - clamped.y) <= 1.0 {
                            if let nodeIdx = nodeByPath[path], flatNodes[nodeIdx].el.layout.stickBottom {
                                wasPinnedToBottom.insert(path)
                            }
                        } else if !scrollGlidingPaths.contains(path) {
                            wasPinnedToBottom.remove(path)
                        }
                    }
                    // Stop fling immediately if clamped against boundary
                    if clamped != cur {
                        scrollStore.snap(nid, Props.SCROLL, to: clamped)
                    }
                }
            }
            if anyScrollMoved {
                scrollMovedSinceLastFrame = true
                if scrollRequiresCommit {
                    commitFor(why: scrollCommitWhy, at: now, cut: false)
                } else {
                    updateScrollPositions(at: now)
                }
            }
        } else if !scrollGlidingPaths.isEmpty {
            for path in scrollGlidingPaths {
                let maxExt = scrollMaxExtents[path] ?? .zero
                let cur = scrollOffsets[path] ?? .zero
                if maxExt.y > 0.5 && (maxExt.y - cur.y) <= 1.0,
                   let nodeIdx = nodeByPath[path], flatNodes[nodeIdx].el.layout.stickBottom {
                    wasPinnedToBottom.insert(path)
                }
            }
            scrollGlidingPaths.removeAll(keepingCapacity: true)
            if !needsCommit {
                directScrolledPaths.removeAll(keepingCapacity: true)
            }
        } else if !needsCommit && !directScrolledPaths.isEmpty && !scrollStore.isAnimating {
            directScrolledPaths.removeAll(keepingCapacity: true)
        }
        let isScrolling = isInitiallyScrolling || scrollMovedSinceLastFrame || touchMoved || scrollStore.isAnimating
        if isScrolling {
            frameHadScrollSinceLastFrame = true
            layoutFeedback.step(.reopened)
        }
        if layoutReadsMoved() {
            let other = hasExternalDirtyCommit || ranExternalLayoutAction
            if other || isScrolling {
                layoutFeedback.step(.reopened)
            } else {
                layoutFeedback.step(.commit(feedback: true, other: false))
            }
            hasExternalDirtyCommit = false
            commitFor(why: CommitWhy.read, at: now, cut: false)
        }
        if virtualFillNeedsCommit {
            virtualFillNeedsCommit = false
            needsCommit = true
            commitWhyPending |= CommitWhy.virtual
        }
        scrollMovedSinceLastFrame = false
        return (animNow, prevAnimNow, growthMoving)
    }

    internal func stepToFrameOutputScaled(
        at now: Double,
        splitStep: (catchUpAnimNow: Double, dt: Double)? = nil,
        skipFramePoll: Bool = false
    ) -> (frameOut: FrameOutput, animNow: Double) {
        // Clear the wake before poll, input, or layout can sample a published value.
        // Any subsequent publication remains pending for the next frame.
        let liveWoke = liveLane.take()
        if textSystem.followWindowFontFamilies() {
            invalidateFontFamilyLayout(at: now)
        }
        let (animNow, prevAnimNow, growthMoving) = prepareAndCommitFrame(
            at: now,
            splitStep: splitStep,
            skipFramePoll: skipFramePoll
        )

        // Sample Scene & Live property bindings using scaled animation clock
        elSliceRenderState.loopCatchUp.loopsStepped(hostNow: currentTime, animEnd: animNow)
        if !fitWindowState.frameHolds() {
            scene.setTime(animNow)
        }
        syncLoopOffsetsToScene(animNow: animNow)
        // A stationary pointer re-hit after layout: no pointer event asked for that hover
        // (`paint/build.rs`: `observe_since`), so what it changes is never input (#970).
        _ = asInputObserver { refreshHoverAndSyncTracks(at: animNow, wallNow: now, cut: false) }
        endUnseenExits(on: &scene)
        placeTailHandoffFrames()
        // Keep the old pose index for launch and join comparisons while letting the
        // scene refill its changed-pose buffer in place.
        lastFrameOutput?.changed = []
        var frameOut = scene.frameForRendering(at: animNow)
        presentLaunchedRowHeights(in: &frameOut)
        slice2State.frameGrowthSnapOffsetsY.removeAll(keepingCapacity: true)
        if !slice2State.liveContentSlides.slides.isEmpty {
            applyRowShifts(Dictionary(uniqueKeysWithValues: slice2State.liveContentSlides.shifts), in: &frameOut)
        }
        placeJoinedRows(in: &frameOut)
        landGroupFadesAfterFrame()
        wordRevealStore.tick { [scene, animNow] id in
            scene.store.nodeTimeScale(id) != 1.0 ? scene.store.nodeTime(id) : animNow
        }
        let slackMoving = stepScrollSlacks(frameOut: frameOut, at: now)
        tellScrollOffsetsAfterSceneFrame(at: animNow, instant: currentFrameCommitInstant)
        currentFrameCommitInstant = false
        let liveActive: Bool
        if liveLane.latchBegin(can: liveWoke || liveLane.pending(), hasSubs: !liveSubscriptions.isEmpty) {
            liveActive = updateLiveBindings(at: animNow, launchAt: prevAnimNow)
            liveLane.latchEnd(active: liveActive)
        } else {
            liveActive = false
        }
        liveStore.sample(at: animNow)

        activeTextFlights.removeAll { flight in
            flight.state.isSettled(at: animNow, reducedMotion: reducedMotion)
                || !frameOut.nodes.contains { $0.id == flight.targetNodeId && !$0.isExiting }
        }

        let activeWordReveals = wordRevealStore.hasActiveFades { scene.store.nodeTimeScale($0) }
        if !shadowTrackCounts.isEmpty {
            for (nid, prevCount) in shadowTrackCounts where frameOut.poseIndex[nid] == nil {
                for k in 0..<prevCount {
                    liveStore.remove(nid, Self.shadowGeomProp(k))
                    liveStore.remove(nid, Self.shadowColorProp(k))
                }
                shadowTrackCounts.removeValue(forKey: nid)
            }
        }
        // Tracks only holding for delayed starts (`enterDelay`) draw nothing new until wake:
        // keep `isAnimating == false` and clear `AnimSource.tracks` so the host sleeps until `nextWakeDeadline`.
        let tracksAnimating = frameOut.isAnimating && scene.store.waitingUntil() == nil
        let rawAnimating = tracksAnimating
            || scrollStore.isAnimating
            || isTouchScrollActive
            || liveStore.isAnimating
            || liveActive
            || growthMoving
            || slackMoving
            || growthRows.values.contains { $0.track.moving }
            || growthStacks.values.contains { !$0.pendingHeights.isEmpty || !$0.closing.isEmpty || !$0.runs.isEmpty }
            || kitHooks.growthStacks.values.contains { !$0.closing.isEmpty }
            || virtualFill.isFilling
            || tooltipFading(at: now)
            || hasActiveSelectableEdgeScroll
            || !activeTextFlights.isEmpty
            || hasMovingScaleSettle
            || activeWordReveals
        var sources: UInt32 = 0
        if tracksAnimating || tooltipFading(at: now) { sources |= AnimSource.tracks }
        if growthMoving || slackMoving || growthRows.values.contains(where: { $0.track.moving }) || growthStacks.values.contains(where: { !$0.pendingHeights.isEmpty || !$0.closing.isEmpty || !$0.runs.isEmpty }) || kitHooks.growthStacks.values.contains(where: { !$0.closing.isEmpty }) { sources |= AnimSource.growth }
        if scrollStore.isAnimating || isTouchScrollActive || hasActiveSelectableEdgeScroll { sources |= AnimSource.scroll }
        if activeWordReveals { sources |= AnimSource.reveal }
        if liveStore.isAnimating || liveActive { sources |= AnimSource.live }
        if virtualFill.isFilling { sources |= AnimSource.virtualFill }
        if !activeTextFlights.isEmpty { sources |= AnimSource.textFlight }
        if hasMovingScaleSettle { sources |= AnimSource.scaleSettle }
        if lastVideoSnapshots.values.contains(where: { if case .playing = $0.state { return true }; return false }) {
            sources |= AnimSource.video
        }
        isAnimating = rawAnimating && cxSettings.viewTimeScale > 0.0
        animSources = isAnimating ? sources : 0

        // Prune snapshots of exiting nodes that have finished exiting
        hasActiveExitingNodes = frameOut.nodes.contains(where: \.isExiting)
        let finishedExitedIds = exitingSnapshots.keys.filter { frameOut.poseIndex[$0] == nil }
        wordRevealStore.prune(exitedIds: finishedExitedIds)
        for id in finishedExitedIds {
            exitingSnapshots.removeValue(forKey: id)
            elSliceRenderState.groupRestIds.remove(id)
            atBottomStates.removeValue(forKey: id)
            farFromBottomStates.removeValue(forKey: id)
        }
        if !finishedExitedIds.isEmpty {
            let keep = liveLane.dirty
            rebuildLiveSubscriptionsIncludingExiting()
            liveLane.pruned(keep)
        }
        for id in exitingTextLayouts.keys where frameOut.poseIndex[id] == nil {
            exitingTextLayouts.removeValue(forKey: id)
        }
        pruneScaleSettles()
        activeFlightIds = activeFlightIds.filter {
            frameOut.poseIndex[$0] != nil && (scene.isEdgeAnimating($0) || scene.hasEnteringAncestor($0))
        }
        launchedFlightIds = launchedFlightIds.filter {
            frameOut.poseIndex[$0] != nil && (scene.isEdgeAnimating($0) || scene.hasEnteringAncestor($0))
        }
        if !launchScrollById.isEmpty {
            launchScrollById = launchScrollById.filter { launchedFlightIds.contains($0.key) }
        }
        unclippedMatchedFlightIds = unclippedMatchedFlightIds.filter {
            frameOut.poseIndex[$0] != nil && (scene.isEdgeAnimating($0) || scene.hasEnteringAncestor($0))
        }
        lastFrameOutput = frameOut

        return (frameOut, animNow)
    }

    // MARK: - View Commit, Reconciliation & Layout

    internal func currentMemoGeometry(nodes: [FlatNode]? = nil) -> MemoGeometry {
        var transientIndex = LayoutKeyIndex()
        return MemoGeometry(resolve: { [self] query in
            let selector: String
            switch query {
            case .layout(let key): selector = key
            case .window(let key): selector = LayoutReadConstants.windowKey(key)
            case .caret(let key):
                let caret = if let nodes { focusedCaretInfo(in: nodes) } else { currentFocusedCaret() }
                guard let values = caretRectForKey(caret, key: key) else { return nil }
                return MotionRect.fromXYWH(values[0], values[1], values[2], values[3])
            }

            // A memo can read a geometry key for the first time during a settle or virtual-row
            // pass. Use the same selector, mark union and scroll coordinates as an ordinary Cx.
            let source = nodes ?? flatNodes
            let index: LayoutKeyIndex?
            if nodes == nil {
                layoutKeyIndex.prepare(nodes: source, stamp: layoutCommitGen, lookups: 1, selector: selector,
                                       keyOf: { $0.key }, highlightKeysOf: { $0.el.textHighlights?.compactMap(\.key) ?? [] })
                index = layoutKeyIndex.indexIfValid(nodes: source, stamp: layoutCommitGen)
            } else {
                transientIndex.prepare(nodes: source, stamp: layoutCommitGen, lookups: 1, selector: selector,
                                       keyOf: { $0.key }, highlightKeysOf: { $0.el.textHighlights?.compactMap(\.key) ?? [] })
                index = transientIndex.indexIfValid(nodes: source, stamp: layoutCommitGen)
            }
            guard let rect = rectForRead(key: selector, nodes: source, index: index) else { return nil }
            return MotionRect.fromXYWH(rect[0], rect[1], rect[2], rect[3])
        }, selection: { [self] in computeSelectionBoxes(in: nodes) })
    }

    internal func flushPendingCommitIfNeeded(at now: Double, routed: Bool = true) {
        // frame.rs:563: only when a handler or poll ran, or the state is dirty (`ran || dirty`).
        if needsCommit, commitWhyPending & (CommitWhy.input | CommitWhy.poll | CommitWhy.dirty) != 0 {
            // A routed event (key, physical key, IME, paste) sees the state an earlier handler
            // left before it routes (`frame.rs`'s `ROUTE` commit). Swift dispatches events at
            // once rather than queueing them for the frame, so a key release doesn't take it:
            // `live_only_tests.rs:152` (LiveOnlyFullParityTests) updates state, sends a live-only
            // key release, and wants the update's commit inside the next frame, which a commit
            // at the release would take out of it. File steps don't either: upstream holds a
            // stale one to the next frame (`hold_files`) rather than committing before it.
            needsCommit = false
            commitFor(why: routed ? CommitWhy.route : 0, at: now, cut: forceInitialSettle)
            forceInitialSettle = false
        }
    }

    internal func anchoredOverlayHasScaleTrack(_ el: El<State>, nodeId: NodeId) -> Bool {
        el.scale != Vec2(1, 1)
            || el.liveBindings.contains(where: { $0.target == .scale })
            || scene.store.has(nodeId, Props.SCALE)
            || scene.store.has(nodeId, Props.UNIFORM_SCALE)
    }

    @inline(never)
    internal func commitTree(at now: Double, cut: Bool, resizeSnap: Bool = false) {
        // Whatever a poll changed lands in this commit (`why & CommitWhy::POLL` is spent).
        polledChange = false
        let wasCommitting = isCommittingTree
        isCommittingTree = true
        defer { isCommittingTree = wasCommitting }
        let prevResizeSnap = activeResizeSnap
        let prevExplicitSnap = activeExplicitSnap
        let prevExplicitSettleCut = activeExplicitSettleCut
        activeResizeSnap = resizeSnap
        activeExplicitSettleCut = explicitSettleRequested
        explicitSettleRequested = false
        defer {
            activeResizeSnap = prevResizeSnap
            activeExplicitSnap = prevExplicitSnap
            activeExplicitSettleCut = prevExplicitSettleCut
        }
        let budget = CommitBudget.Commit.start()
        defer { budget.end(why: perfWatch.cause) }
        measureRuntimePhase(.commit) {
            textSystem.beginElisionCommit()
            let commitAskedMotion = pendingAskedMotion
            pendingAskedMotion = false
            let isUnprompted = pendingUnprompted || (motionNeedsCause && !frameCommittedFromInput && !commitAskedMotion)
            pendingUnprompted = false
            let rawCommitKind: TxCommit = isUnprompted ? pendingCommitKind.withoutInput() : pendingCommitKind
            slice2State.activeLiveTail = slice2State.pendingLiveTail
            slice2State.pendingLiveTail = LiveTailRequests()
            defer {
                slice2State.activeLiveTail = LiveTailRequests()
                slice2State.liveTailWindows.removeAll(keepingCapacity: true)
            }
            activeExplicitSnap = rawCommitKind.snaps
            // `apply.rs`: an instant commit's changes land at once, by design.
            if rawCommitKind.snaps && commitCount > 0 {
                commitWhy |= CommitWhy.instant
            }
            let explicitSettle = rawCommitKind == .settle
            let explicitInstant = rawCommitKind == .instant || rawCommitKind == .unprompted
            let commitKind: TxCommit = resizeSnap
                ? TxCommit(snaps: true, lands: rawCommitKind.lands)
                : rawCommitKind
            pendingCommitKind = .animate
            let commitMotion = pendingCommitMotion
            pendingCommitMotion = nil
            let commitColorSpring = pendingColorMotionSpring
            pendingColorMotionSpring = nil
            let commitFollowEdge = pendingFollowEdge
            pendingFollowEdge = false
            let commitCut = cut || explicitSettle
            if commitCut || commitKind.lands {
                lastWasSettled = true
            }
            currentCommitInstant = commitCut || explicitInstant
            if currentCommitInstant {
                currentFrameCommitInstant = true
            }
            defer { currentCommitInstant = false }
            let prevSettleLoops = activeSettleLoops
            activeSettleLoops = activeExplicitSettleCut || explicitSettle || commitKind.lands || reducedMotion
            defer { activeSettleLoops = prevSettleLoops }

            if commitCut {
                activeFlightIds.removeAll()
                launchedFlightIds.removeAll()
                launchScrollById.removeAll()
                unclippedMatchedFlightIds.removeAll()
            }
            let sincePass = memo.nextPass()
            let liveCheck = pendingLiveOnlyCheck
            pendingLiveOnlyCheck = nil
            checkingLiveOnly = (liveCheck != nil)
            defer { checkingLiveOnly = false }
            var didRunView = false
            MemoSnapshot.enter {
                // A zoom or memo geometry change can request one fresh measurement. Finish the
                // previous pass before retrying so its layout and apply frames leave the stack.
                for settlePass in 0...1 {
                    let result = commitTreePass(
                        at: now,
                        cut: cut,
                        settlePass: settlePass,
                        commitKind: commitKind,
                        commitMotion: commitMotion,
                        commitColorSpring: commitColorSpring,
                        commitFollowEdge: commitFollowEdge,
                        commitCut: commitCut,
                        didRunView: &didRunView
                    )
                    if result == .applied { break }
                }
            }
            if didRunView {
                memo.keepSince(sincePass)
            }
            lastLiveCommitClock = now
            compareLiveOnlyCheck(liveCheck)
            commitCount &+= 1
            frameHadCommitted = true
        }
    }

    private func currentFocusedCaret() -> (keyPath: String, rect: [Float])? {
        if let fk = focusedKey, let el = firstReportedElement(where: { matchesAuthoredKey($0.key, fk) }), let c = el.caret {
            return (el.path, c)
        }
        if let fp = focusedPath, let el = firstReportedElement(where: { $0.path == fp }), let c = el.caret {
            return (el.path, c)
        }
        return nil
    }

    internal var scrollRequiresCommit: Bool {
        virtualListsNeedWindowUpdate() || lastViewReadScroll
    }

    internal struct PendingFoldOpen {
        var viewport: String
        var foldPrefix: String
        var giving: Bool
        var pinned: Bool
    }

    internal final class MeasurePassResult {
        var viewRootEl: El<State>
        var expandedRootEl: El<State>
        var nodes: [FlatNode]
        var byPath: [String: Int]
        let indexById: [NodeId: Int]

        @inline(__always)
        func node(_ id: NodeId) -> FlatNode? {
            guard let index = indexById[id] else { return nil }
            return nodes[index]
        }
        var specs: [NodeSpec]
        var loopSpecs: [(id: NodeId, spec: LoopSpec)]
        var ancestorInstants: [Bool]
        var warnings: [String]
        var reads: [LayoutReadEntry]
        var virtualExpansion: VirtualExpansionContext
        var rootBackground: Color?
        var rootHeight: Float
        var helpLook: HelpLook?
        var viewportRead: Bool
        var effectiveReducedMotion: Bool?
        var measuredGrowthRows: [String: RuntimeGrowthEntry]?
        var measuredGrowthStacks: [String: RuntimeGrowthStackState]?
        var isVirtualRemount = false
        var reusedFlatRanges: [(current: Range<Int>, previous: Range<Int>)] = []
        fileprivate var appliedMemoSpans: [(span: MemoFlatSpan<State>, start: Int)] = []
        var naturalJoinedRowTargets: [NodeId: MotionRect] = [:]
        var naturalLaunchTargets: [NodeId: MotionRect] = [:]
        var foldOpens: [PendingFoldOpen] = []
        var scrollCuts: [(viewport: String, cut: Float)] = []
        var foldHeaderUpdates: [(foldKey: String, headerPath: String)] = []
        var textLayouts: [NodeId: RetainedLayoutCoordinator.TextLayoutRecord]

        init(
            viewRootEl: El<State>,
            expandedRootEl: El<State>,
            nodes: [FlatNode],
            byPath: [String: Int],
            indexById: [NodeId: Int],
            specs: [NodeSpec],
            loopSpecs: [(id: NodeId, spec: LoopSpec)],
            ancestorInstants: [Bool],
            warnings: [String],
            reads: [LayoutReadEntry],
            virtualExpansion: VirtualExpansionContext,
            rootBackground: Color?,
            rootHeight: Float,
            helpLook: HelpLook?,
            viewportRead: Bool = false,
            effectiveReducedMotion: Bool? = nil,
            measuredGrowthRows: [String: RuntimeGrowthEntry]? = nil,
            measuredGrowthStacks: [String: RuntimeGrowthStackState]? = nil,
            foldOpens: [PendingFoldOpen] = [],
            scrollCuts: [(viewport: String, cut: Float)] = [],
            foldHeaderUpdates: [(foldKey: String, headerPath: String)] = [],
            textLayouts: [NodeId: RetainedLayoutCoordinator.TextLayoutRecord] = [:]
        ) {
            self.viewRootEl = viewRootEl
            self.expandedRootEl = expandedRootEl
            self.nodes = nodes
            self.byPath = byPath
            self.indexById = indexById
            self.specs = specs
            self.loopSpecs = loopSpecs
            self.ancestorInstants = ancestorInstants
            self.warnings = warnings
            self.reads = reads
            self.virtualExpansion = virtualExpansion
            self.rootBackground = rootBackground
            self.rootHeight = rootHeight
            self.helpLook = helpLook
            self.viewportRead = viewportRead
            self.effectiveReducedMotion = effectiveReducedMotion
            self.measuredGrowthRows = measuredGrowthRows
            self.measuredGrowthStacks = measuredGrowthStacks
            self.foldOpens = foldOpens
            self.scrollCuts = scrollCuts
            self.foldHeaderUpdates = foldHeaderUpdates
            self.textLayouts = textLayouts
        }
    }

    @inline(__always)
    private static func computeStaticTransform(
        baseRect: MotionRect,
        el: El<State>,
        inh: StaticInh
    ) -> (bounds: SIMD4<Float>, childInh: StaticInh) {
        let off = Vec2(inh.offset.x + el.offset.x, inh.offset.y + el.offset.y)
        let rawRect = baseRect.offsetBy(off)
        let scaleVec = Vec2(inh.scale.x * el.scale.x, inh.scale.y * el.scale.y)
        let hasOwnScale = abs(el.scale.x - 1.0) > 1e-5 || abs(el.scale.y - 1.0) > 1e-5
        let origin = el.scaleOrigin
        let centre = SIMD2<Float>(
            rawRect.left + origin.x * rawRect.width,
            rawRect.top + origin.y * rawRect.height
        )
        let centreTo = SIMD2<Float>(
            inh.anchorTo.x + (centre.x - inh.anchor.x) * inh.scale.x,
            inh.anchorTo.y + (centre.y - inh.anchor.y) * inh.scale.y
        )
        let (anchor, anchorTo) = hasOwnScale ? (centre, centreTo) : (inh.anchor, inh.anchorTo)
        let scaledRect: MotionRect
        if abs(scaleVec.x - 1.0) > 1e-5 || abs(scaleVec.y - 1.0) > 1e-5 || anchor != anchorTo {
            scaledRect = MotionRect(
                left: anchorTo.x + (rawRect.left - anchor.x) * scaleVec.x,
                top: anchorTo.y + (rawRect.top - anchor.y) * scaleVec.y,
                right: anchorTo.x + (rawRect.right - anchor.x) * scaleVec.x,
                bottom: anchorTo.y + (rawRect.bottom - anchor.y) * scaleVec.y
            )
        } else {
            scaledRect = rawRect
        }
        let childInh = StaticInh(scale: scaleVec, anchor: anchor, anchorTo: anchorTo, offset: off)
        return (SIMD4(scaledRect.left, scaledRect.top, scaledRect.width, scaledRect.height), childInh)
    }

    @inline(never)
    private func makeViewCx(
        focusedCaret: (keyPath: String, rect: [Float])?,
        memoNodes: [FlatNode]? = nil,
        collector: LayoutReadCollector,
        layoutSource: Runtime<State>
    ) -> (cx: Cx<State>, envHash: UInt64) {
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
                self.noteScrollMetricRead()
                if let match = self.flatNodes.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) }) {
                    return self.scrollOffsets[match.path] ?? .zero
                }
                return .zero
            },
            scrollMaxLookup: { [weak self] key in
                guard let self else { return .zero }
                self.noteScrollMetricRead()
                if let match = self.flatNodes.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) }) {
                    return self.scrollMaxExtents[match.path] ?? .zero
                }
                return .zero
            },
            viewportSizeLookup: { [weak self] key in
                guard let self else { return .zero }
                self.noteScrollMetricRead()
                if let match = self.flatNodes.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) }) {
                    return self.scrollViewportSizes[match.path] ?? Vec2(match.targetRect.width, match.targetRect.height)
                }
                return .zero
            },
            contentSizeLookup: { [weak self] key in
                guard let self else { return .zero }
                self.noteScrollMetricRead()
                if let match = self.flatNodes.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) }) {
                    return self.scrollContentSizes[match.path] ?? match.contentSize
                }
                return .zero
            },
            layoutRectLookup: { [weak layoutSource] key in
                layoutSource?.flatNodes.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) })?.targetRect
            },
            layoutCollector: collector
        )
        cx.hoverReadDependency = hoverReadDependency
        cx.envState.titlebarInset = cxSettings.titlebarInset / cxSettings.zoomState.k
        cx.envState.chrome = chromeInsets()
        cx.envState.systemAccent = cxSettings.systemAccent
        cx.envState.systemContrast = cxSettings.systemContrast
        cx.envState.systemIncreasedContrast = cxSettings.systemIncreasedContrast
        cx.envState.systemScrollBars = cxSettings.scrollBarsState
        cx.envState.systemReducedMotion = cxSettings.hostReducedMotion
        cx.envState.safeAreaInsets = cxSettings.safeAreaInsets
        cx.envState.primaryPointer = cxSettings.primaryPointer
        cx.envState.zoom = 1.0
        cx.envState.caret = focusedCaret
        cx.envState.selectionRects = computeSelectionBoxes(in: memoNodes)
        let envHash = MemoScope.environmentHash(
            systemDark: systemDark,
            pixelScale: pixelScale,
            reducedMotion: cxSettings.hostReducedMotion,
            srgbBlend: srgbBlend,
            accent: cx.accent(),
            focusColor: cx.focusColor(),
            chromeInsets: [cx.envState.chrome.leading, cx.envState.chrome.trailing, cx.envState.chrome.top, cxSettings.scrollBarsState.bars.hashValue.signum() == 0 ? 0 : Float(cxSettings.scrollBarsState.isOverlay ? 1 : 2)],
            scrollerOverlay: cxSettings.scrollBarsState.isOverlay,
            hoverNone: cx.hoverNone(),
            touchControls: cx.touchControls(),
            safeAreaInsets: cxSettings.safeAreaInsets
        )
        return (cx, envHash)
    }

    @inline(never)
    private func runViewPass(
        at now: Double,
        focusedCaret: (keyPath: String, rect: [Float])?,
        allowZoomSettle: Bool,
        memoNodes: [FlatNode]?,
        collector: LayoutReadCollector,
        preparingFor window: Runtime<State>?
    ) -> (rootEl: El<State>, helpLook: HelpLook?, effectiveReducedMotion: Bool)? {
        viewCallCount += 1
        lastViewReadScroll = false
        var (cx, envHash) = makeViewCx(focusedCaret: focusedCaret, memoNodes: memoNodes,
                                       collector: collector, layoutSource: window ?? self)
        lastViewMemoEnvHash = envHash
        let viewTouchedBox = MemoScope.TouchedIdsBox()
        let rootEl = SystemScrollBarsScope.$current.withValue(cxSettings.scrollBarsState) {
            MemoScope.enterCollectingTouched(
                cache: memo,
                envHash: envHash,
                geometry: currentMemoGeometry(nodes: memoNodes),
                touchedIdsOut: viewTouchedBox
            ) {
                measureRuntimePhase(.view) {
                    TextMeasure.withLentSystem(textSystem) { buildPlaygroundViewIfAttached(cx: &cx) }
                }
            }
        }
        lastViewOnlyMemoIds = viewTouchedBox.ids
        cxSettings.viewDefaults = cx.envState.defaults
        let passHelpLook = cx.helpLook ?? cx.envState.defaults.help
        cxSettings.captionColor = cx.envState.captionColor
        if cx.envState.titlebar != cxSettings.titlebarOverride { cxSettings.titlebarSetChanged = true }
        cxSettings.titlebarOverride = cx.envState.titlebar
        if let base = kitHooks.titlebar.headlessWindowsTitlebar {
            syncWindowsCaption(TitlebarCaption(height: cx.envState.titlebar.over(base).height))
        }
        cxSettings.caretReadByView = cx.envState.reads.caretRead
        cxSettings.selectionRectsReadByView = cx.envState.reads.selectionRectsRead
        selectionState.lastCommittedMarkedTexts = cx.envState.markedTexts
        let effReducedMotion = cx.envState.reducedMotionOverride ?? cxSettings.hostReducedMotion
        cxSettings.setTimeScale(cx.envState.timeScale, at: now)
        if window == nil && cx.envState.zoom != cxSettings.zoomState.k {
            cxSettings.zoomState.k = cx.envState.zoom
            let (zVp, zScale) = cxSettings.zoomState.view()
            // The commit underway applies the view's zoom: no commit, and no cause, is left.
            let why = commitWhyPending
            cxSettings.isApplyingZoom = true
            viewport = zVp
            pixelScale = zScale
            cxSettings.isApplyingZoom = false
            needsCommit = false
            commitWhyPending = why
            if allowZoomSettle {
                return nil
            }
        }
        if var caption = kitHooks.titlebar.caption {
            let titlebar = cx.envState.titlebar
            caption.height = titlebar.height ?? titlebar.titlebar?.height ?? caption.height
            let symbol = cx.envState.captionColor ?? (systemDark ? Color.white : .black)
            let frame = caption.frame(around: rootEl, symbol: symbol, scale: pixelScale,
                                      zoom: cxSettings.zoomState.k, fitHeight: fitHeight)
            return (frame, passHelpLook, effReducedMotion)
        }
        return (rootEl, passHelpLook, effReducedMotion)
    }

    internal func measurePass(
        at now: Double,
        cut: Bool,
        commitKind: TxCommit,
        commitMotion: MotionSource?,
        commitColorSpring: Spring?,
        commitCut: Bool,
        prevMountedIds: Dictionary<NodeId, Int>.Keys,
        focusedCaret: (keyPath: String, rect: [Float])?,
        allowZoomSettle: Bool,
        memoNodes: [FlatNode]? = nil,
        allowRebuildRegionRowReuse: Bool = true,
        preparingFor window: Runtime<State>? = nil
    ) -> MeasurePassResult? {
        let collector = LayoutReadCollector(rects: layoutSeen.rects)
        guard let viewPass = runViewPass(
            at: now,
            focusedCaret: focusedCaret,
            allowZoomSettle: allowZoomSettle,
            memoNodes: memoNodes,
            collector: collector,
            preparingFor: window
        ) else {
            return nil
        }
        let hadVirtuals = !activeVirtualPaths.isEmpty
        let savedVirtuals = hadVirtuals ? virtualLists : [:]
        let savedScrollOffsets = hadVirtuals ? scrollOffsets : [:]
        let savedScrollMaxExtents = hadVirtuals ? scrollMaxExtents : [:]
        let savedScrollViewportSizes = hadVirtuals ? scrollViewportSizes : [:]
        let savedScrollContentSizes = hadVirtuals ? scrollContentSizes : [:]
        let savedWasPinned = hadVirtuals ? wasPinnedToBottom : []
        let savedGrowthRows = growthRows
        let savedGrowthStacks = growthStacks
        // A full view has replaced the source tree. Keep only the mounted indexed rows
        // eligible for memo reuse. The resize snapshot also owns the old offscreen rows.
        let previousRows = allowRebuildRegionRowReuse ? cachedResizeBuild?.virtualRowCache : nil
        if !virtualSelectionSources.isEmpty { cachedResizeBuild = nil }
        var result = buildMeasureResult(
            rootEl: viewPass.rootEl,
            remountRowCache: previousRows,
            rowReuseMode: allowRebuildRegionRowReuse ? .rebuildRegion : .none,
            passHelpLook: viewPass.helpLook,
            collector: collector,
            at: now,
            cut: cut,
            commitKind: commitKind,
            commitMotion: commitMotion,
            commitColorSpring: commitColorSpring,
            commitCut: commitCut,
            prevMountedIds: prevMountedIds,
            effectiveReducedMotion: viewPass.effectiveReducedMotion
        )
        if hadVirtuals && prepareVirtualRemeasureAfterFullPass(
            result,
            savedVirtuals: savedVirtuals,
            savedScrollOffsets: savedScrollOffsets,
            savedScrollMaxExtents: savedScrollMaxExtents,
            savedScrollViewportSizes: savedScrollViewportSizes,
            savedScrollContentSizes: savedScrollContentSizes,
            savedWasPinned: savedWasPinned,
            savedGrowthRows: savedGrowthRows
        ) {
            growthStacks = savedGrowthStacks
            result = buildMeasureResult(
                rootEl: viewPass.rootEl,
                retryingVirtualWindow: true,
                passHelpLook: viewPass.helpLook,
                collector: collector,
                at: now,
                cut: cut,
                commitKind: commitKind,
                commitMotion: commitMotion,
                commitColorSpring: commitColorSpring,
                commitCut: commitCut,
                prevMountedIds: prevMountedIds,
                effectiveReducedMotion: viewPass.effectiveReducedMotion
            )
        }
        result.viewRootEl = viewPass.rootEl
        result.effectiveReducedMotion = viewPass.effectiveReducedMotion
        result.measuredGrowthRows = growthRows
        result.measuredGrowthStacks = growthStacks
        growthRows = savedGrowthRows
        growthStacks = savedGrowthStacks
        return result
    }

    /// A fixed-width, zero-gap column can retain the geometry of its published virtual rows.
    /// All entering rows and its outer tree still participate in the current layout solve.
    private func fixedVirtualRowLayout(in root: El<State>, expansion: VirtualExpansionContext, rebuilding: Bool) -> FixedVirtualRowLayout? {
        guard expansion.listMeta.count == 1, let list = expansion.listMeta.first, list.indexed,
              let rows = expansion.builtVirtualRows[list.listPath], !rows.isEmpty,
              let oldList = nodeByPath[list.listPath], flatNodes[oldList].flow == .ltr else { return nil }
        var chain: [Int] = []
        var parent: Int? = oldList
        while let index = parent {
            // On this path every containing width is externally specified. Grids and
            // intrinsic/flex row ancestors must see the actual children's contributions.
            let layout = flatNodes[index].el.layout
            guard layout.displayMode == .flex, layout.direction == .column,
                  !layout.wrap, !layout.wrapReverse, layout.alignItems == .stretch,
                  layout.alignSelf == nil || layout.alignSelf == .stretch,
                  layout.width == .fraction(1) || layout.width == .points(flatNodes[index].localSize.x) else {
                return nil
            }
            if flatNodes[index].parentIndex != nil { chain.append(index) }
            parent = flatNodes[index].parentIndex
        }
        let width = flatNodes[oldList].localSize.x
        guard width.isFinite, width > 0 else { return nil }
        var listIndices: [Int] = []
        var ancestors: [El<State>] = []
        var source = root
        var listPath = flatNodes[0].path
        var listId = flatNodes[0].nodeId
        // A full view may have replaced any ancestor of the list. Its current keyed
        // path, writing direction and externally determined flex width must still agree.
        func sameContainer(_ authored: borrowing El<State>, _ previous: borrowing FlatNode) -> Bool {
            authored.storageKeyId == previous.el.storageKeyId && authored.layout == previous.el.layout &&
                previous.flow == .ltr && (authored.explicitDir == nil || authored.explicitDir == .ltr) &&
                authored.explicitDir == previous.el.explicitDir && authored.isUnmirrored == previous.el.isUnmirrored &&
                !authored.hasEditLens && authored.anchor == nil && previous.el.anchor == nil &&
                authored.layout.sticky == nil && authored.growthSpec == nil && authored.foldGlideSpec == nil
        }
        var previousParent = 0
        for previousIndex in chain.reversed() {
            if rebuilding && !sameContainer(source, flatNodes[previousParent]) { return nil }
            let path = flatNodes[previousIndex].path
            let children = FlatChildPaths(source.children, count: source.children.count, parent: listPath, parentId: listId)
            guard let index = children.addresses.firstIndex(where: { $0.path == path }) else { return nil }
            listIndices.append(index)
            ancestors.append(source)
            source = source.children[index]
            listPath = path
            listId = children.addresses[index].id
            previousParent = previousIndex
        }
        if rebuilding && !sameContainer(source, flatNodes[oldList]) { return nil }
        let style = source.layout
        guard style.displayMode == .flex, style.direction == .column, !style.wrap, !style.wrapReverse,
              style.justifyContent == .start, style.alignItems == .stretch, style.padding == .all(0),
              style.margin == .all(0), style.border == .all(0), !style.borderLayout, style.scrollAxes.isEmpty,
              style.rowGap == 0, style.height == .auto,
              (style.width == .points(width) || (style.width == .fraction(1) && style.minWidth == .points(width))),
              source.anchor == nil, source.explicitDir == nil,
              !layoutObservers.authored.contains(where: { $0.contains(.secureOrEditable) || $0.contains(.liveSource) }) else {
            return nil
        }

        // The solver also rounds the placeholder. Above 2^23 an odd integral Float
        // plus 0.5 can round to the next even integer before the floor operation.
        let wholeRows = style.isWholeRowsColumn
        let maximumGroupHeight = wholeRows ? 8_388_608 : FixedVirtualRowLayout.maximumExactHeight
        var compact: [El<State>] = []
        var groups: [(position: Int, saved: [LayoutEngine.ResultNode])] = []
        var boxes: [NodeId: RetainedLayoutCoordinator.TextLayoutRecord] = [:]
        var saved: [LayoutEngine.ResultNode] = []
        var height: Float = 0
        var retainedNodeCount = 0
        func flush() {
            guard !saved.isEmpty else { return }
            let substitute = El<State>(direction: .column).wFull().h(height).shrink(0)
            groups.append((compact.count, saved))
            compact.append(substitute)
            saved = []
            height = 0
        }
        func retain(_ row: borrowing El<State>) -> Bool {
            guard case .points(let authoredHeight) = row.layout.height else { return false }
            let h = wholeRows ? LayoutStyle.wholeRowLength(authoredHeight) : authoredHeight
            guard let key = row.storageKeyId, let entry = rows[key],
                  let context = entry.layoutRootMemo, let paths = flatMemoPaths[listId.child("@" + key)],
                  let retained = paths.rowRoot,
                  (!rebuilding || (entry.memoizedRootOwner != nil && entry.reads.isEmpty &&
                                    entry.trackedReads.isEmpty && context.matches(row.children))),
                  (paths.owner === context && retained.source === entry.rootIdentity) ||
                    (rebuilding && (entry.layoutProjection != nil || retained.layoutProjection != nil) &&
                     (entry.layoutProjection?.children ?? context) === (retained.layoutProjection?.children ?? paths.owner) &&
                     (entry.layoutProjection?.owner ?? entry.rootIdentity) === (retained.layoutProjection?.owner ?? retained.source)),
                  let span = paths.span, let previous = span.appliedRange(at: layoutCommitGen),
                  previous.lowerBound > 0, row.explicitDir == nil,
                  span.context.frame.scale == pixelScale, span.context.frame.fontEpoch == textSystem.currentFontEpoch,
                  span.context.frame.language == textSystem.language, span.context.frame.smoothing == textSystem.smoothing,
                  h > 0, h.rounded() == h, h <= maximumGroupHeight - height,
                  row.layout.width == .fraction(1), row.layout.flexShrink == 0, row.layout.flexGrow == 0,
                  row.layout.margin == .all(0), row.layout.padding == .all(0), row.layout.border == .all(0),
                  !row.layout.isAbsolute, row.layout.sticky == nil, row.layout.pinLeft == nil, row.layout.pinRight == nil,
                  row.layout.pinTop == nil, row.layout.pinBottom == nil, row.layout.aspectFit == nil,
                  row.layout.scrollAxes.isEmpty, row.anchor == nil, row.layout.flexBasis == .auto, row.layout.minWidth == .auto,
                  row.layout.minHeight == .auto, row.layout.maxWidth == .auto,
                  row.layout.maxHeight == .auto else { return false }
            let previousRoot = flatNodes[previous.lowerBound - 1]
            guard previousRoot.nodeId == retained.node.nodeId, previousRoot.flow == .ltr,
                  previousRoot.el.memoLayoutChildren === paths.owner, previousRoot.el.layout == row.layout,
                  previousRoot.localRect.x == 0, previousRoot.localSize == Vec2(width, h),
                  previousRoot.contentSize.x <= width, previousRoot.contentSize.y <= h else { return false }
            let layout = ComputedLayout(localRect: previousRoot.localRect, localSize: previousRoot.localSize,
                                        contentSize: previousRoot.contentSize)
            saved.append(.init(layout: layout, children: span.children))
            retainedNodeCount += 1 + span.nodes.count
            for node in span.nodes {
                if let text = nodeTextLayouts[node.nodeId] { boxes[node.nodeId] = text }
            }
            height += h
            return true
        }
        for index in source.children.indices {
            let child = source.children[index]
            // No retained sibling in the compressed solver may acquire a different
            // positional ID. Entering editable/live rows also need a single ordinary solve.
            guard child.storageKeyId != nil, !child.hasEditLens, !child.isSecure, child.liveText == nil, child.liveBindings.isEmpty,
                  child.memoLayoutChildren?.traits.contains(.mutableLayout) != true else { return nil }
            // Leave both edge children available to supply the column's intrinsic baseline.
            if index == 0 || index + 1 == source.children.count || !retain(source.children[index]) {
                flush()
                compact.append(source.children[index])
            }
        }
        flush()
        guard groups.contains(where: { $0.saved.count >= 4 }) else { return nil }
        var compressed = source
        compressed.children = compact
        for (ancestor, index) in zip(ancestors, listIndices).reversed() {
            var parent = ancestor
            parent.children[index] = compressed
            compressed = parent
        }
        return FixedVirtualRowLayout(source: compressed, listIndices: listIndices, groups: groups, boxes: boxes, width: width,
                                     additionalNodeCount: retainedNodeCount - groups.count)
    }

    private func releaseKeptLayoutsBeforeCommit(liveIds: Set<NodeId>) {
        if prevNodeTextLayoutsForCommit == nil {
            var prevKeys: [NodeId: (shapeKey: TextShapeKey, isInput: Bool)] = [:]
            prevKeys.reserveCapacity(nodeTextLayouts.count)
            for (nid, rec) in nodeTextLayouts {
                prevKeys[nid] = (rec.box.shapeKey, rec.isInput)
            }
            prevNodeTextLayoutsForCommit = prevKeys
        }
        for (nid, rec) in nodeTextLayouts where !liveIds.contains(nid) {
            if exitingTextLayouts[nid] == nil {
                exitingTextLayouts[nid] = rec
            }
        }
        nodeTextLayouts.removeAll(keepingCapacity: true)
    }

    @inline(never)
    internal func buildMeasureResult(
        rootEl authoredRoot: El<State>,
        retryingVirtualWindow: Bool = false,
        expandedContextOverride: VirtualExpansionContext? = nil,
        remountRowCache: [String: [String: CachedVirtualRow]]? = nil,
        rowReuseMode: VirtualRowReuseMode = .none,
        memoGeometryOverride: MemoGeometry? = nil,
        passHelpLook: HelpLook?,
        collector: LayoutReadCollector,
        at now: Double,
        cut: Bool,
        commitKind: TxCommit,
        commitMotion: MotionSource?,
        commitColorSpring: Spring?,
        commitCut: Bool,
        prevMountedIds: Dictionary<NodeId, Int>.Keys,
        isResizeRelayout: Bool = false,
        effectiveReducedMotion: Bool? = nil,
        onRemountFallback: (() throws -> Void)? = nil
    ) rethrows -> MeasurePassResult {
        let reducedMotion = effectiveReducedMotion ?? self.reducedMotion
        var authoredRenames: [KeyDiagnostics.Rename] = []
        let authored = expandedContextOverride == nil
            ? KeyDiagnostics.repair(authoredRoot, at: nil) { authoredRenames.append($0) }
            : (tree: authoredRoot, warnings: [])
        let rootEl = authored.tree
        let rootBg: Color? = rootEl.background.a >= 0.999 ? rootEl.background : nil

        let isReorderPermitted = !commitCut && !commitKind.snaps && !commitKind.lands && !reducedMotion
        let savedVirtualLists = virtualLists
        let savedScrollOffsets = scrollOffsets
        let savedPinnedBottom = wasPinnedToBottom
        var virtualPass = retryingVirtualWindow ? 1 : 0
        var expandedRoot: El<State>
        var layoutRoot: El<State>
        var virtualExpansion: VirtualExpansionContext
        var solvedRoot: LayoutEngine.ResultNode
        let textLayoutCollector = RetainedLayoutCoordinator.TextLayoutCollector()
        var restoredNodeCount = 0
        var hasGrowth = false
        // A view or retained row may share all its child buffers with the last frame. Only
        // detach paths to inputs whose pills actually need to be resolved for this pass.
        // A speculative solve may retry. Current input and live-text measurements must run once.
        var mutableMeasurements = false
        func resolveInputPills(in root: El<State>, checkMeasurements: Bool) -> El<State> {
            typealias Frame = (el: El<State>, next: Int, end: Int, changed: Bool)
            func visit(_ el: El<State>) -> Frame {
                var frame: Frame = (el, 0, el.children.count, false)
                if checkMeasurements && (el.hasEditLens || el.isSecure || el.liveText != nil) { mutableMeasurements = true }
                if el.growthSpec != nil || el.foldGlideSpec != nil { hasGrowth = true }
                if (el.pillStyleLookup != nil || el.pillIconLookup != nil || el.pillColorsSpec != nil),
                   let editLens = el.handlers.editLens {
                    ElDisplayResolver.preResolveInputPills(el: &frame.el, edit: editLens.get(state))
                    frame.changed = true
                }
                if let memo = el.memoLayoutChildren, memo.matches(el.children) {
                    if checkMeasurements && memo.traits.contains(.mutableLayout) { mutableMeasurements = true }
                    if memo.traits.contains(.growth) { hasGrowth = true }
                    if !memo.traits.contains(.inputPills) { frame.end = 0 }
                }
                return frame
            }
            var ancestors: [Frame] = []
            var frame = visit(root)
            while true {
                if frame.next < frame.end {
                    let child = frame.el.children[frame.next]
                    frame.next += 1
                    ancestors.append(frame)
                    frame = visit(child)
                } else {
                    guard var parent = ancestors.popLast() else { return frame.el }
                    if frame.changed {
                        parent.el.children[parent.next - 1] = frame.el
                        parent.changed = true
                    }
                    frame = parent
                }
            }
        }
        repeat {
            if virtualPass == 0, let override = expandedContextOverride {
                (expandedRoot, virtualExpansion) = (rootEl, override)
            } else {
                (expandedRoot, virtualExpansion) = TextMeasure.withLentSystem(textSystem) {
                    expandVirtualSubtrees(
                        in: rootEl,
                        remountRowCache: remountRowCache,
                        rowReuseMode: rowReuseMode,
                        memoGeometry: memoGeometryOverride ?? currentMemoGeometry(),
                        memoEnvHash: lastViewMemoEnvHash,
                        memoPass: memo.currentPass,
                        isReorderPermitted: isReorderPermitted,
                        lands: activeExplicitSettleCut || commitKind.lands,
                        bypassBudget: activeExplicitSettleCut || commitKind.lands || virtualPass > 0,
                        forceAll: virtualPass >= 8
                    )
                }
            }
            // A prepared remount encountered a nested entering row. Its partial tree must
            // never reach layout, which would release retained layouts and retarget row motion.
            if virtualExpansion.remountHitNestedVirtual { try onRemountFallback?() }
            hasGrowth = false
            mutableMeasurements = false
            let mayReuseFullLayout = rowReuseMode != .remount && expandedContextOverride == nil && !cut &&
                !activeResizeSnap && prevNodeTextLayoutsForCommit == nil && virtualExpansion.listMeta.count == 1 &&
                virtualExpansion.listMeta[0].indexed
            layoutRoot = resolveInputPills(in: expandedRoot, checkMeasurements: mayReuseFullLayout)
            textLayoutCollector.map.removeAll(keepingCapacity: true)
            textLayoutCollector.liveIds.removeAll(keepingCapacity: true)
            restoredNodeCount = 0
            solvedRoot = measureRuntimePhase(.layout) {
                // Remeasurements run after the first solve releases the prior text records.
                if expandedContextOverride == nil, !cut, !activeResizeSnap, (rowReuseMode == .remount || (mayReuseFullLayout && !hasGrowth && !mutableMeasurements)),
                   prevNodeTextLayoutsForCommit == nil,
                   let splice = fixedVirtualRowLayout(in: layoutRoot, expansion: virtualExpansion, rebuilding: rowReuseMode != .remount) {
                    var result = retainedLayout.compute(root: splice.source, state: state, viewport: viewport,
                        pixelScale: pixelScale, textSystem: textSystem, fitHeight: fitHeight, textLayouts: textLayoutCollector,
                        virtualRows: virtualExpansion.builtVirtualRows)
                    if splice.restore(&result) {
                        restoredNodeCount = splice.additionalNodeCount
                        // Publish the same live-ID set as an ordinary solve only after
                        // validation. A fallback still owns every previous/exiting text box.
                        releaseKeptLayoutsBeforeCommit(liveIds: textLayoutCollector.liveIds.union(splice.boxes.keys))
                        textLayoutCollector.map.merge(splice.boxes) { current, _ in current }
                        return result
                    }
                    #if DEBUG
                    fixedVirtualLayoutRetries &+= 1
                    #endif
                    textLayoutCollector.map.removeAll(keepingCapacity: true)
                    textLayoutCollector.liveIds.removeAll(keepingCapacity: true)
                }
                return retainedLayout.compute(
                    root: layoutRoot,
                    state: state,
                    viewport: viewport,
                    pixelScale: pixelScale,
                    textSystem: textSystem,
                    fitHeight: fitHeight,
                    textLayouts: textLayoutCollector,
                    virtualRows: expandedContextOverride == nil ? virtualExpansion.builtVirtualRows : [:],
                    onLiveIdsReady: { [weak self] ids in self?.releaseKeptLayoutsBeforeCommit(liveIds: ids) }
                )
            }
            let needsRetry = measureVirtualsFromSolved(
                expandedRoot: layoutRoot,
                solvedRoot: solvedRoot,
                expansion: virtualExpansion,
                lands: commitKind.lands
            )
            // A retained resize has only mounted children. Validate its window after flattening;
            // a moved window must restart from the view's original row source.
            if expandedContextOverride != nil || !needsRetry || virtualPass >= 8 { break }
            virtualPass += 1
            // Keep newly measured row heights while restoring prior commit's anchor & window for retry.
            for (path, cur) in virtualLists {
                if var prior = savedVirtualLists[path] {
                    prior.measuredByKey = cur.measuredByKey
                    virtualLists[path] = prior
                }
            }
            scrollOffsets = savedScrollOffsets
            wasPinnedToBottom = savedPinnedBottom
        } while true
        let acceptsLiveTail = commitKind == .unprompted && !cut && !reducedMotion && !isResizeRelayout
            && !activeResizeSnap && !slice2State.activeLiveTail.inkByStack.isEmpty
        var naturalJoinedRowTargets: [NodeId: MotionRect] = [:]
        if acceptsLiveTail || !slice2State.joinedRowSeams.isEmpty {
            naturalJoinedRowTargets = prepareLiveTails(root: layoutRoot, solved: solvedRoot, expansion: virtualExpansion,
                                                       previousLists: savedVirtualLists, now: now, acceptsRequests: acceptsLiveTail)
        }
        let growthCapture = updateGrowthRowsPostLayout(
            rootResult: solvedRoot,
            rootEl: layoutRoot,
            hasGrowth: hasGrowth,
            cut: cut,
            snaps: commitKind.snaps,
            lands: commitKind.lands,
            isRelayoutPass: isResizeRelayout,
            reducedMotionOverride: reducedMotion,
            at: now
        )
        var effectiveFoldHeaders = foldHeaders
        for upd in growthCapture.foldHeaderUpdates {
            effectiveFoldHeaders[upd.foldKey] = upd.headerPath
        }
        let growthStepNow = pendingGrowthStepNow ?? now
        let steppedAfterRetarget = (lastGrowthStepTime != growthStepNow && !cut && !commitKind.lands && !reducedMotion)
            ? advanceGrowthRows(at: growthStepNow, headers: effectiveFoldHeaders, markRelayoutDirty: false)
            : false
        placeTailHandoffRows()
        let needsGrowthClamp = growthCapture.needsClampedRelayout || steppedAfterRetarget || growthRows.values.contains { entry in
            let t = entry.track
            return (t.moving && (abs(t.h - t.target) > 1e-4 || t.isShuttingFold))
                || (t.streaming && (t.h < entry.naturalHeight - 0.1 || entry.withheld > 0.01))
        }
        let naturalRoot = needsGrowthClamp ? solvedRoot : nil
        if needsGrowthClamp {
            restoredNodeCount = 0
            layoutRoot = applyGrowthConstraints(in: layoutRoot)
            textLayoutCollector.map.removeAll(keepingCapacity: true)
            textLayoutCollector.liveIds.removeAll(keepingCapacity: true)
            solvedRoot = measureRuntimePhase(.layout) {
                retainedLayout.compute(
                    root: layoutRoot,
                    state: state,
                    viewport: viewport,
                    pixelScale: pixelScale,
                    textSystem: textSystem,
                    textLayouts: textLayoutCollector
                )
            }
        }

        // Flatten tree, assign unique structural/keyed paths, clamp scroll offsets, and collect NodeSpecs
        virtualExpansion.keyDiagnostics.insert(contentsOf: authored.warnings, at: 0)
        virtualExpansion.keyRenames.insert(contentsOf: authoredRenames, at: 0)
        lastKeyDiagnostics = virtualExpansion.keyDiagnostics
        let renames = virtualExpansion.keyRenames
        renamedSiblingKeys.removeAll(keepingCapacity: true)
        for rename in renames { renamedSiblingKeys[rename.path] = rename }
        inheritedHoverCurvesByPath.removeAll(keepingCapacity: true)
        var newFlat: [FlatNode] = []
        swap(&newFlat, &spareFlatNodes)
        newFlat.removeAll(keepingCapacity: true)
        var anchorStickyShifts: [Int: Vec2] = [:]
        var newByPath: [String: Int] = [:]
        var newIndices: [NodeId: Int] = [:]
        var specs: [NodeSpec] = []
        var loopSpecs: [(id: NodeId, spec: LoopSpec)] = []
        var ancestorInstants: [Bool] = []
        var warnings = renames.map(\.warning)
        var nextMemoPaths: [NodeId: FlatMemoPaths<State>] = [:]
        // The solver sees one placeholder per retained row group. Reserve for the restored
        // rows too so one extra mounted node does not double the flat and spec buffers.
        let count = textLayoutCollector.liveIds.count + restoredNodeCount
        // A preceding remount releases its old motion specifications after publishing the new ones.
        // Drop a substantially larger allocation when the window or the view changes.
        if rowReuseMode == .remount, spareMotionSpecs.capacity / 2 <= count {
            swap(&specs, &spareMotionSpecs)
        }
        spareMotionSpecs = []
        newFlat.reserveCapacity(count)
        newByPath.reserveCapacity(count)
        newIndices.reserveCapacity(count)
        specs.reserveCapacity(count)
        ancestorInstants.reserveCapacity(count)
        if rowReuseMode == .remount {
            nextMemoPaths.reserveCapacity(flatMemoPaths.count)
        }
        var flatCaptures: [FlatMemoCapture<State>] = []
        var appliedMemoSpans: [(span: MemoFlatSpan<State>, start: Int)] = []
        var reusedFlatRanges: [(current: Range<Int>, previous: Range<Int>)] = []
        // An entry records what a newly mounted descendant's scale animation becomes on replay.
        // Its first frame still uses the authored mount animation and any entrance delay.
        var mountedScales: [Int: Anim<Vec2>?] = [:]
        let flatFrame = FlatMemoFrame(commit: commitKind, cut: commitCut, motion: commitMotion,
            colorSpring: commitColorSpring, reducedMotion: reducedMotion, scale: pixelScale,
            fontEpoch: textSystem.currentFontEpoch, language: textSystem.language, smoothing: textSystem.smoothing)
        let canReplayFlat = !activeResizeSnap && !pendingResizeRelayout && !pictureOnlyRelayout &&
            pixelsAspectSnapIds.isEmpty && activeFlightIds.isEmpty && launchedFlightIds.isEmpty &&
            pendingLaunches.isEmpty && !scrollRequestsState.keeps.contains { $0.hold != nil }
        let checkFrameTracks = (commitKind.snaps || commitKind.lands) && scene.store.activeTrackCount > 0 &&
            scene.store.hasTracks(for: Props.FRAME)
        func stableForFlatReplay(_ id: NodeId) -> Bool {
            prevMountedIds.contains(id) &&
                (!checkFrameTracks || !scene.store.isAnimating(id, Props.FRAME))
        }
        var naturalLaunchTargets: [NodeId: MotionRect] = [:]
        let measureLaunches = !launchedFlightIds.isEmpty || !pendingLaunches.isEmpty
        let fullWindowClip = MotionRect.fromXYWH(0, 0, viewport.x, viewport.y)

        let rootResolvedKey: String? = layoutRoot.storageKeyId
        let rootPath: String = rootResolvedKey.map { "/@\($0)" } ?? "/0"
        var walkStack: [WalkItem] = [
            WalkItem(
                element: FlatElement(layoutRoot),
                solved: solvedRoot,
                resolvedKey: rootResolvedKey,
                path: rootPath,
                parentIdx: nil,
                parentOrigin: .zero,
                parentUnscrolledOrigin: .zero,
                parentScroll: .zero,
                parentScale: 1.0,
                scaleChain: [],
                inheritedClip: fullWindowClip,
                inheritedInert: false,
                inheritedZ: 0,
                inInstantSubtree: false,
                inheritedClipFades: [],
                enclosingScrollIndex: nil,
                enclosingVScrollIndex: nil,
                enclosingHScrollIndex: nil,
                staticInh: StaticInh(),
                parentFlow: .ltr,
                parentDirected: false,
                naturalLayout: naturalRoot
            )
        ]

        // A virtual row can enter a client VM while this pass measures its layout.
        // Reserve the per-node flattening workspace only after those builders return.
        while let item = walkStack.popLast() {
            if let row = item.virtualRow, (rowReuseMode == .remount || row.memoizedRootOwner != nil),
               replayVirtualRow(item, row) { continue }
            appendMeasuredNode(item, authored: item.element.value)
        }

        @inline(never)
        func replayVirtualRow(_ item: borrowing WalkItem, _ row: CachedVirtualRow) -> Bool {
            guard let nid = item.resolvedId, let paths = flatMemoPaths[nid], let root = paths.rowRoot,
                  root.source === row.rootIdentity, root.parentHasGrowth == item.parentHasGrowth,
                  let span = paths.span, let parent = item.parentIdx,
                  root.motion.parent == newFlat[parent].nodeId, root.node.path == item.path,
                  (root.node.enclosingScrollIndex == nil) == (item.enclosingScrollIndex == nil),
                  let context = Self.retainedRowInputs(item, frame: flatFrame), root.inherited == context,
                  span.context == root.childContext, span.specs.first?.parent == nid,
                  stableForFlatReplay(nid),
                  root.node.localSize == item.solved.layout.localSize, root.node.contentSize == item.solved.layout.contentSize,
                  root.node.localRect.width == item.solved.layout.localRect.width,
                  root.node.localRect.height == item.solved.layout.localRect.height,
                  MemoFlatSpan<State>.equalLayouts(span.children, item.solved.children) else { return false }
            // A growth stack can remain mounted after its rows settle. Only a moving
            // track can change this root's child slide between otherwise identical passes.
            if !growthRows.isEmpty, growthRows["growth:" + item.path]?.track.moving == true { return false }
            let previous = span.appliedRange(at: layoutCommitGen)
            guard (!checkFrameTracks && previous != nil) || span.nodes.allSatisfy({ stableForFlatReplay($0.nodeId) }) else { return false }

            let index = newFlat.count
            let clip = root.append(to: &newFlat, specs: &specs, instants: &ancestorInstants, parent: parent,
                localRect: item.solved.layout.localRect, origin: item.parentOrigin, unscrolled: item.parentUnscrolledOrigin,
                clip: item.inheritedClip, fades: item.inheritedClipFades, enclosing: item.enclosingScrollIndex,
                vertical: item.enclosingVScrollIndex, horizontal: item.enclosingHScrollIndex)
            newByPath[item.path] = index
            newIndices[nid] = index
            let start = index + 1
            // The translated row itself still reconciles its scene frame and observers.
            if let previous { reusedFlatRanges.append((start..<(start + span.nodes.count), previous)) }
            appliedMemoSpans.append((span, start))
            span.append(to: &newFlat, byPath: &newByPath, byId: &newIndices, specs: &specs,
                instants: &ancestorInstants, root: index, clip: clip, fades: item.inheritedClipFades,
                enclosing: item.enclosingScrollIndex, vertical: item.enclosingVScrollIndex, horizontal: item.enclosingHScrollIndex)
            paths.replayedNodes = span.nodes.count
            paths.replayedRowRoot = true
            nextMemoPaths[nid] = paths
            return true
        }

        #if DEBUG
        @inline(never)
        #else
        @inline(__always)
        #endif
        func appendMeasuredNode(_ item: WalkItem, authored: borrowing El<State>) {
            let parentFlow: Flow = authored.isUnmirrored ? .ltr : item.parentFlow
            let (flow, mirror) = stepDirection(parent: parentFlow, el: authored, state: state)
            let directed = authored.explicitDir != nil || authored.isUnmirrored || item.parentDirected
            let directText = directed && !authored.textDirByParagraph
            let directParagraphs = directed && !directText && authored.hasEditLens
            let hasIsolates = !authored.isolatesSpec.isEmpty
            if mirror || directText || directParagraphs || hasIsolates {
                var adjusted = copy authored
                if mirror { mirrorElVisual(&adjusted) }
                if directText { adjusted.textStyle.direction = flow.textFlow }
                if directParagraphs { adjusted.textStyle.byParagraphStart = flow.textFlow }
                if hasIsolates { adjusted = adjusted.applyingIsolates() }
                if mirror, let anchor = adjusted.anchor { adjusted.anchor = mirrorAnchor(anchor) }
                appendResolvedNode(item, element: FlatElement(adjusted), el: adjusted,
                                   nodeFlow: flow, nodeDirected: directed, mirrorDir: mirror)
            } else {
                appendResolvedNode(item, element: item.element, el: authored,
                                   nodeFlow: flow, nodeDirected: directed, mirrorDir: mirror)
            }
        }

        // Keep the common authored element borrowed from its immutable sibling buffer.
        // A directional override above owns the adjusted element for the same call.
        @inline(never)
        func appendResolvedNode(_ item: WalkItem, element: FlatElement<State>, el: borrowing El<State>,
                                nodeFlow: Flow, nodeDirected: Bool, mirrorDir: Bool) {
            let solved = item.solved
            let resolvedKey = item.resolvedKey
            let path = item.path
            let parentIdx = item.parentIdx
            let parentOrigin = item.parentOrigin
            let parentUnscrolledOrigin = item.parentUnscrolledOrigin
            let parentScroll = item.parentScroll
            let parentScale = item.parentScale
            let scaleChain = item.scaleChain
            let inheritedClip = item.inheritedClip
            let inheritedInert = item.inheritedInert
            let inheritedZ = item.inheritedZ
            let inInstantSubtree = item.inInstantSubtree
            let inheritedClipFades = item.inheritedClipFades
            let staticInh = item.staticInh

            let nid = item.resolvedId ?? (el.layoutAnim?.travel == .screen
                ? resolvedKey.map { NodeId.hash("screen:@" + $0) } : nil) ?? NodeId.hash(path)
            let childCount = min(el.children.count, solved.children.count)
            // Screen travel changes this node's scene identity; descendants keep the authored path.
            let pathId = childCount > 0 && resolvedKey != nil && el.layoutAnim?.travel == .screen ? NodeId.hash(path) : nid
            var memoPaths = item.memoPaths
            if memoPaths == nil, childCount > 0, let owner = el.memoLayoutChildren,
               owner.matches(el.children), owner.traits.isDisjoint(with: [.virtual, .growth, .inputPills]) {
                if let old = flatMemoPaths[pathId], old.owner === owner {
                    memoPaths = old
                } else {
                    memoPaths = FlatMemoPaths(owner)
                }
                memoPaths?.replayedNodes = 0
                memoPaths?.replayedRowRoot = false
                memoPaths?.rowRoot = nil
                nextMemoPaths[pathId] = memoPaths
            }
            let memoSlot = item.memoPaths == nil ? 0 : item.memoSlot
            let childPaths = childCount == 0 ? FlatChildPaths() :
                memoPaths?.children(at: memoSlot, source: el.children, parent: path, parentId: pathId)
                    ?? FlatChildPaths(el.children, count: childCount, parent: path, parentId: pathId)
            for duplicate in childPaths.duplicates where duplicate.index < childCount {
                warnings.append(duplicate.warning)
            }
            let (closingChildShiftsY, closingStackExtraH): ([Float]?, Float) = {
                guard el.growthSpec != nil, let stack = growthStacks[path], !stack.closing.isEmpty else {
                    return (nil, 0)
                }
                let childGKeys: [String?] = (0..<childCount).map { cIdx in
                    let cEl = el.children[cIdx]
                    if cEl.keyId == "__v_top_spacer" || cEl.keyId == "__v_bot_spacer" {
                        return nil
                    }
                    return cEl.foldGlideSpec != nil ? "fold:\(childPaths.addresses[cIdx].path)" : "growth:\(childPaths.addresses[cIdx].path)"
                }
                return stack.closingLayoutAdjustments(survivingKeys: childGKeys, growthRows: growthRows)
            }()

            let rawLocalRect = solved.layout.localRect
            // A launch re-aims when layout moves its destination or a containing row.
            // Intermediate growth clamps and scrolling change only its projected endpoint.
            let naturalLocalRect = item.naturalLayout?.layout.localRect ?? rawLocalRect
            if measureLaunches {
                naturalLaunchTargets[nid] = naturalLocalRect
            }
            // The committed tree uses natural layout, before the viewport and growth tracks project it.
            let parentLayoutOrigin = parentIdx.map { newFlat[$0].committedLayoutTarget.origin } ?? .zero
            var committedLayoutTarget = naturalLocalRect.translated(parentLayoutOrigin)
            let localRect = closingStackExtraH > 0
                ? MotionRect.fromXYWH(rawLocalRect.x, rawLocalRect.y, rawLocalRect.width, rawLocalRect.height + closingStackExtraH)
                : rawLocalRect
            let hdrRestore: Float = (item.foldHeaderPath == path) ? item.foldHeaderLift : 0
            // The layout solver bakes a stack's current row heights into the next row's top.
            // Paint inherits the ancestors' displacements separately.
            let rowProjectionY = item.parentHasGrowth ? localRect.y - naturalLocalRect.y : 0
            let growthContentShiftY = item.growthPlacementShiftY + hdrRestore
            // A top spacer inside the stack supplies the mounted children's stationary snap origin.
            let virtualWindowSnapOriginY: Float
            if el.growthSpec != nil, el.virtualEstimate != nil, let spacer = el.children.first,
               spacer.keyId == "__v_top_spacer", case let .points(height) = spacer.layout.height {
                virtualWindowSnapOriginY = Snap.grid(height + virtualGapY(el.layout), scale: pixelScale)
            } else {
                virtualWindowSnapOriginY = 0
            }
            let nextFoldHeaderPath: String? = (item.foldHeaderPath == path) ? nil : item.foldHeaderPath
            let nextFoldHeaderLift: Float = (item.foldHeaderPath == path) ? 0 : item.foldHeaderLift
            let unscrolledX = parentUnscrolledOrigin.x + localRect.x
            let unscrolledY = parentUnscrolledOrigin.y + localRect.y + growthContentShiftY
            let unscrolledRect = MotionRect.fromXYWH(unscrolledX, unscrolledY, localRect.width, localRect.height)

            var worldX = parentOrigin.x + localRect.x - parentScroll.x
            var worldY = parentOrigin.y + localRect.y - parentScroll.y + growthContentShiftY
            var anchorScaleFactor: Float = 1.0
            var anchorAttachNorm: Vec2? = nil

            if let a = el.anchor {
                if let anchorFlat = newFlat.first(where: { $0.key == a.key }) {
                    let aSticky = stickyShiftForAnchor(anchorFlat.index, in: newFlat, cache: &anchorStickyShifts)
                    // The anchor is placed against its scrolled, sticky trigger in unscaled layout coordinates.
                    var trigger = anchorFlat.committedLayoutTarget.translated(aSticky)
                    var ancestor = anchorFlat.parentIndex
                    while let i = ancestor {
                        let offset = newFlat[i].scrollShift
                        trigger = trigger.translated(Vec2(-offset.x, -offset.y))
                        ancestor = newFlat[i].parentIndex
                    }
                    let (x, y) = anchorPosition(a, trigger: [trigger.left, trigger.top, trigger.right, trigger.bottom],
                                                size: (naturalLocalRect.width, naturalLocalRect.height), viewport: (viewport.x, viewport.y))
                    committedLayoutTarget = .fromXYWH(x, y, naturalLocalRect.width, naturalLocalRect.height)
                    let aParentScale = anchorFlat.parentIndex.map { newFlat[$0].inheritedScale } ?? 1.0
                    let triggerZoomed = (aSticky == .zero)
                        ? anchorFlat.zoomedTargetRect
                        : anchorFlat.zoomedTargetRect.offsetBy(Vec2(aSticky.x * aParentScale, aSticky.y * aParentScale))
                    let placement = AnchorLayoutHelper.zoomedPlacement(
                        anchor: a,
                        triggerZoomed: triggerZoomed,
                        anchorScale: aParentScale,
                        localSize: Vec2(localRect.width, localRect.height),
                        overlayOwnScale: el.scale,
                        hasScaleTrack: anchoredOverlayHasScaleTrack(el, nodeId: nid),
                        viewport: viewport
                    )
                    worldX = placement.unscaledOrigin.x
                    worldY = placement.unscaledOrigin.y
                    anchorScaleFactor = placement.zoom
                    if abs(placement.zoom - 1.0) > 1e-5 {
                        anchorAttachNorm = placement.attachNorm
                    }
                }
            }
            // Sticky push-out is evaluated at paint time in `buildRefScene` using presented rects.
            if parentIdx == nil, let page = documentPage {
                worldY -= page.top
            }
            let targetRect = MotionRect.fromXYWH(worldX, worldY, localRect.width, localRect.height)
            let zoomedTargetRect = AnchorLayoutHelper.zoomedRect(targetRect, chain: scaleChain)
            let nodeInheritedScale = (el.anchor == nil ? parentScale : anchorScaleFactor) * el.scale.x
            var childScaleChain = scaleChain
            if el.anchor != nil || el.scale.x != 1 {
                childScaleChain.append(AnchorLayoutHelper.AncestorScaleStep(
                    rect: targetRect,
                    scale: (el.anchor != nil) ? nodeInheritedScale : el.scale.x,
                    origin: (el.anchor != nil) ? .zero : el.origin,
                    resetsAncestors: el.anchor != nil
                ))
            }

            // Update scroll bounds for scrollable containers
            var ownScroll = Vec2.zero
            var scrollFadeInfo: EdgeFadeSpec? = nil
            if !el.layout.scrollAxes.isEmpty {
                scrollViewportSizes[path] = Vec2(targetRect.width, targetRect.height)
                scrollContentSizes[path] = solved.layout.contentSize
                let maxSX = el.layout.scrollAxes.contains(.horizontal)
                    ? max(0, solved.layout.contentSize.x - targetRect.width)
                    : 0
                let maxSY: Float
                if el.layout.scrollAxes.contains(.vertical) {
                    let growthChild = el.children.firstIndex { $0.growthSpec != nil }
                    let natural = item.naturalLayout?.layout ?? solved.layout
                    maxSY = growthScrollMaximum(
                        path: path, stackPath: growthChild.map { childPaths.addresses[$0].path },
                        stackBottom: growthChild.map { solved.children[$0].layout.localRect.bottom } ?? 0,
                        viewportHeight: targetRect.height,
                        measured: max(0, solved.layout.contentSize.y - targetRect.height),
                        natural: max(0, natural.contentSize.y - natural.localRect.height)
                    )
                } else {
                    maxSY = 0
                }
                let oldMax = scrollMaxExtents[path] ?? .zero
                scrollMaxExtents[path] = Vec2(maxSX, maxSY)

                var curScroll = scrollOffsets[path] ?? .zero
                if el.layout.stickBottom {
                    let firstMount = !wasPinnedToBottom.contains(path) && scrollOffsets[path] == nil
                    let wasAtBottom = activeExplicitSettleCut || commitKind.lands || firstMount ||
                        wasPinnedToBottom.contains(path) || (oldMax.y - curScroll.y <= 2.0)
                    if wasAtBottom {
                        let jumped = abs(curScroll.y - maxSY) > 0.5 && !firstMount
                        curScroll.y = maxSY
                        let nid = NodeId.hash("scroll:" + path)
                        if scrollStore.get(nid, Props.SCROLL) != nil {
                            scrollStore.snap(nid, Props.SCROLL, to: Vec2(curScroll.x, maxSY))
                        }
                        if jumped {
                            armScrollNudge(path: path, at: now)
                        }
                        wasPinnedToBottom.insert(path)
                    }
                    let existingSlack = slice2State.scrollSlacks[path]
                    if existingSlack == nil
                        || cut
                        || commitKind.lands
                        || commitKind.snaps
                        || existingSlack?.window.0 != viewport.x
                        || existingSlack?.window.1 != viewport.y {
                        slice2State.scrollSlacks[path] = ScrollSlack.landed(window: (viewport.x, viewport.y))
                        slice2State.scrollExtraYByPath[path] = 0
                    }
                }
                curScroll = Vec2(
                    isTouchOwning(path: path, horizontal: true) ? curScroll.x : curScroll.x.clamped(to: 0...maxSX),
                    isTouchOwning(path: path, horizontal: false) ? curScroll.y : curScroll.y.clamped(to: 0...maxSY)
                )
                scrollOffsets[path] = curScroll
                ownScroll = Vec2(nodeFlow == .rtl ? -curScroll.x : curScroll.x, curScroll.y)

                if el.scrollEdgeFadeWidth > 0 || el.scrollFadeStyle.end != nil {
                    let dummyNode = FlatNode(
                        index: 0,
                        parentIndex: parentIdx,
                        path: path,
                        key: el.authoredByteExactKey ?? resolvedKey,
                        nodeId: nid,
                        element: element,
                        localRect: localRect,
                        unscrolledRect: unscrolledRect,
                        targetRect: targetRect,
                        zoomedTargetRect: zoomedTargetRect,
                        staticBounds: SIMD4(targetRect.x, targetRect.y, targetRect.width, targetRect.height),
                        contentSize: solved.layout.contentSize,
                        clipRect: inheritedClip,
                        scrollShift: curScroll,
                        localSize: solved.layout.localSize,
                        effectiveInert: false,
                        zOrder: 0,
                        flow: nodeFlow
                    )
                    scrollFadeInfo = computeScrollFadeSpec(for: dummyNode)
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
            let (staticBounds, childStaticInh) = Self.computeStaticTransform(
                baseRect: unscrolledRect,
                el: el,
                inh: staticInh
            )

            let ownClipFadeSpec: EdgeFadeSpec? = el.clipFade.map { cf in
                EdgeFadeSpec(
                    rect: intersectRects(inheritedClip, targetRect),
                    widths: cf,
                    strengths: SIMD4<Float>(repeating: 1.0),
                    growthRow: el.growthReveal == nil ? nil : nid,
                    authoredFade: el.growthReveal?.authoredFade
                )
            }
            var childClipFades = inheritedClipFades
            if let sf = scrollFadeInfo {
                childClipFades.append(sf)
            }
            if let cfSpec = ownClipFadeSpec {
                childClipFades.append(cfSpec)
            }

            var flatElement = element
            if el.hasEditLens, !el.isSecure, let edit = el.handlers.editLens?.get(state), edit.isSecure {
                flatElement.value.isSecure = true
                flatElement.value.runtimeExtras[El<State>.selectableExtraKey] = false
            }

            var nodeElided: TextElision? = nil
            if el.children.isEmpty,
               !el.hasEditLens,
               !el.isTruncateFadeEnabled,
               el.advanceInRun == nil,
               (el.textStyle.maxLines > 0 || el.textStyle.wrap == .ellipsis),
               (el.richSpans != nil || el.liveText != nil || el.plainText != nil) {
                let resolvedText = ElDisplayResolver.resolveText(
                    el: el,
                    rawText: el.liveText?.get() ?? el.plainText,
                    isSecure: el.isSecure
                )
                let innerW = max(0, localRect.width - el.layout.padding.left - el.layout.padding.right)
                nodeElided = resolvedText.shape(
                    using: textSystem,
                    maxWidth: innerW,
                    pixelScale: pixelScale,
                    emitGlyphs: false
                ).elided
            }

            let myIndex = newFlat.count
            let flat = FlatNode(
                index: myIndex,
                parentIndex: parentIdx,
                path: path,
                key: el.authoredByteExactKey ?? resolvedKey,
                nodeId: nid,
                element: flatElement,
                localRect: localRect,
                unscrolledRect: unscrolledRect,
                targetRect: targetRect,
                committedLayoutTarget: committedLayoutTarget,
                growthRowProjectionY: rowProjectionY,
                growthContentShiftY: growthContentShiftY,
                virtualWindowSnapOriginY: virtualWindowSnapOriginY,
                zoomedTargetRect: zoomedTargetRect,
                staticBounds: staticBounds,
                contentSize: solved.layout.contentSize,
                clipRect: inheritedClip,
                scrollShift: ownScroll,
                localSize: solved.layout.localSize,
                effectiveInert: effectiveInert,
                zOrder: ownZ,
                inheritedScale: nodeInheritedScale,
                anchorAttachNorm: anchorAttachNorm,
                activeClipFades: inheritedClipFades,
                ownScrollFade: scrollFadeInfo,
                ownClipFade: ownClipFadeSpec,
                enclosingScrollIndex: item.enclosingScrollIndex,
                enclosingVScrollIndex: item.enclosingVScrollIndex,
                enclosingHScrollIndex: item.enclosingHScrollIndex,
                flow: nodeFlow,
                mirroredInRtl: mirrorDir && el.mirrorInRtl,
                elided: nodeElided
            )
            newFlat.append(flat)
            newByPath[path] = myIndex
            newIndices[nid] = myIndex

            // Compute interactive press / pressScale adjustments on target spec
            let isPressed = isNodePressedVisually(path: path, effectiveInert: effectiveInert)

            var effectiveFill = el.background
            if isPressed, let pBg = el.pressBg {
                effectiveFill = blendColorOver(bottom: effectiveFill, top: pBg, srgb: srgbBlend)
            }

            let effectiveScale = el.scale

            let ancestorInstant = inInstantSubtree && !el.hasAnimatedChanges
            let childInstant = ancestorInstant || el.hasInstantChanges
            let selfInstantLayoutOrStyle = childInstant || commitKind.snaps || commitCut || reducedMotion
            let selfInstantStyle = childInstant || commitKind.snaps || commitCut

            let parentNid = parentIdx.map { newFlat[$0].nodeId }
            let nodeStyleSpring = el.styleSpring ?? item.inheritedStyleSpring
            // Provide a subtle default interactive spring when pressScale / press is used;
            // keep animated style curves active under `reducedMotion` so `AnimationStore`
            // maps `.color`/`.opacity` to `REDUCED_FADE` while cutting `.shape`/`.blur`/`.scale`.
            var styleSp: Spring?
            if selfInstantStyle {
                styleSp = el.pressBg != nil && !commitKind.snaps && !commitCut && !reducedMotion
                    ? MotionTokens.INSTANT
                    : nil
            } else {
                styleSp = nodeStyleSpring
                    ?? commitColorSpring
                    ?? commitMotion?.spring
                    ?? (el.pressBg != nil ? MotionTokens.INSTANT : nil)
            }
            let paintSp: Spring? = (selfInstantStyle || reducedMotion)
                ? nil
                : (nodeStyleSpring ?? commitColorSpring ?? commitMotion?.spring)
            let colorSp: Spring? = selfInstantStyle
                ? nil
                : (paintSp ?? commitColorSpring ?? nodeStyleSpring ?? commitMotion?.spring ?? MotionTokens.DEFAULT)
            let keepsFlights = !activeResizeSnap && commitKind.snaps && !commitKind.lands && viewCommitCount > 1 && !cut && !reducedMotion
            func isRunningSameSceneFrame() -> Bool {
                guard checkFrameTracks, self.scene.hasNode(nid),
                      self.scene.store.isAnimating(nid, Props.FRAME),
                      let curTarget = self.scene.store.target(nid, Props.FRAME) else {
                    return false
                }
                let parentOriginRect = parentIdx.map { newFlat[$0].targetRect }
                let localTarget = parentOriginRect.map {
                    MotionRect.fromEdges(
                        targetRect.left - $0.x,
                        targetRect.top - $0.y,
                        targetRect.right - $0.x,
                        targetRect.bottom - $0.y
                    )
                } ?? targetRect
                return abs(curTarget.x - localTarget.x) < 0.1
                    && abs(curTarget.y - localTarget.y) < 0.1
                    && abs(curTarget.width - localTarget.width) < 0.1
                    && abs(curTarget.height - localTarget.height) < 0.1
            }
            let growth = growthRows.isEmpty ? nil : growthRows[(el.foldGlideSpec == nil ? "growth:" : "fold:") + path]
            let hasGrowthSlide = growth?.contentSlide != nil
            let isRunningFlight = !hasGrowthSlide && (activeFlightIds.contains(nid) || launchedFlightIds.contains(nid))
            // A launch chooses its travel after checking whether it can land this commit.
            let needsFlightLayout = isRunningFlight && !launchedFlightIds.contains(nid)
            let followsWindow = pendingResizeRelayout && !isRunningFlight && !scene.store.isAnimating(nid, Props.FRAME)
            var layoutAnimSpec: LayoutAnim?
            let isStackContainer = (el.growthSpec != nil) || (el.virtualEstimate != nil)
            let (selfInRow, childInRow) = ParityLayoutAnimation.resolveRowLayout(
                parentInRow: item.rowLayout,
                hasAbove: el.anchor != nil,
                hasAnimateLayout: el.layoutAnim != nil,
                isStackContainer: isStackContainer
            )
            if commitCut || reducedMotion || followsWindow {
                layoutAnimSpec = nil
            } else if selfInstantLayoutOrStyle {
                layoutAnimSpec = (keepsFlights && isRunningSameSceneFrame()) ? .instant : nil
            } else if commitKind.lands, el.layoutAnim != nil, isRunningSameSceneFrame() {
                layoutAnimSpec = .instant
            } else if selfInRow == .horizontal || item.parentHasGrowth {
                let resolved = ParityLayoutAnimation.resolveNodeLayoutAnim(
                    inRow: selfInRow,
                    explicitLayoutAnim: el.layoutAnim,
                    nodeSpring: el.styleSpring ?? MotionTokens.SETTLE,
                    parentHasGrowth: item.parentHasGrowth,
                    isInstant: false,
                    isSameSceneFrame: false,
                    commitLands: false
                )
                layoutAnimSpec = (el.layoutAnim != nil || selfInRow == .horizontal) ? resolved : nil
            } else if selfInRow == .snaps {
                layoutAnimSpec = el.layoutAnim != nil ? .instant : nil
            } else if el.layoutAnim == nil, commitMotion == nil, !needsFlightLayout, el.virtualEstimate == nil {
                // Ordinary layout changes spring on the inherited element motion.
                // Virtual containers, explicit transactions and flights own their placement.
                layoutAnimSpec = LayoutAnim(spring: nodeStyleSpring ?? MotionTokens.DEFAULT)
                // Scrolling changes a direct child's scene coordinates without changing its
                // layout in the viewport. Let the viewport own that movement.
                if let parentNid, let previousParent = mountedNode(parentNid),
                   previousParent.scrollShift != parentScroll, let previous = mountedNode(nid) {
                    if previousParent.scrollShift.x != parentScroll.x,
                       previous.localRect.left == localRect.left, previous.localRect.width == localRect.width {
                        layoutAnimSpec?.x = .instant
                    }
                    // The rows of a growth stack already interpolate its changing height.
                    if previousParent.scrollShift.y != parentScroll.y,
                       previous.localRect.top == localRect.top,
                       previous.localRect.height == localRect.height || el.growthSpec != nil {
                        layoutAnimSpec?.y = .instant
                    }
                }
            } else {
                layoutAnimSpec = el.layoutAnim
            }
            if !selfInstantLayoutOrStyle, !followsWindow, layoutAnimSpec == nil, let cm = commitMotion {
                layoutAnimSpec = LayoutAnim(x: cm.anim, y: cm.anim)
            }
            // Growth lays out row frames as their heights change. A row already sliding to its
            // authored offset keeps that spring through those layout passes.
            var offsetAnim = el.offsetMotionAnim
            if item.parentHasGrowth && !commitKind.lands && offsetAnim == nil {
                offsetAnim = .spring(styleSp ?? MotionTokens.SETTLE)
            }
            if layoutAnimSpec == nil && !selfInstantLayoutOrStyle && !commitCut && !reducedMotion && !commitKind.lands && needsFlightLayout {
                layoutAnimSpec = LayoutAnim(spring: el.flightSpring ?? el.styleSpring ?? MotionTokens.SETTLE, travel: .screen)
            }
            if el.isWidthLeads && !selfInstantLayoutOrStyle && !followsWindow {
                if let la = layoutAnimSpec {
                    layoutAnimSpec = la.widthLeads()
                } else {
                    layoutAnimSpec = .widthLeads(styleSp ?? MotionTokens.SETTLE)
                }
            }
            if pictureOnlyRelayout || pixelsAspectSnapIds.contains(nid) {
                layoutAnimSpec = nil
            }
            let isFreshMount = !prevMountedIds.contains(nid)
            let captureMount = isFreshMount && rowReuseMode == .remount && canReplayFlat &&
                !commitKind.lands && (item.memoPaths != nil || item.virtualRow != nil) &&
                (!checkFrameTracks || !scene.store.isAnimating(nid, Props.FRAME))
            let authoredScaleAnim = selfInstantLayoutOrStyle ? nil : el.scaleMotionAnim
            var specScaleAnim = authoredScaleAnim
            if specScaleAnim == nil && styleSp == nil && !selfInstantLayoutOrStyle && !commitKind.lands &&
                (!isFreshMount || captureMount) {
                let scaleCurve: Curve
                if let laCurve = layoutAnimSpec?.x.curve, laCurve.logicalDuration > 0 {
                    scaleCurve = laCurve
                } else if let cmCurve = commitMotion?.anim.curve, cmCurve.logicalDuration > 0 {
                    scaleCurve = cmCurve
                } else {
                    scaleCurve = Curve.from(MotionTokens.DEFAULT)
                }
                specScaleAnim = Anim<Vec2>(curve: scaleCurve)
            }
            if captureMount {
                mountedScales.updateValue(specScaleAnim, forKey: myIndex)
                specScaleAnim = authoredScaleAnim
            }
            let specTransition: Transition?
            if ancestorInstant {
                specTransition = nil
            } else if let t = el.transition {
                specTransition = t
            } else if (reducedMotion && item.parentHasGrowth) || item.parentUnderFold || el.foldGlideSpec != nil {
                specTransition = Transition.opacity
            } else if el.flightId != nil {
                specTransition = Transition(insertion: .identity, removal: TransitionEffect(zeroOpacity: 0))
            } else if el.enterDelay > 0 {
                specTransition = Transition.opacity
            } else {
                specTransition = nil
            }
            let specSnapMount: Bool = commitCut || commitKind.snaps || (ancestorInstant && childInstant) || (reducedMotion && specTransition == nil)
            let specEnterDelay: Float = (el.enterDelay > 0 && viewCommitCount > 1 && !cut && !commitKind.snaps && !commitKind.lands && !ancestorInstant && isFreshMount) ? el.enterDelay : 0
            ancestorInstants.append(ancestorInstant)

            if let ls = el.loopingSpec {
                loopSpecs.append((id: nid, spec: ls))
            }

            specs.append(NodeSpec(
                id: nid,
                parent: parentNid,
                rect: targetRect,
                opacity: el.opacity,
                scale: effectiveScale,
                rotate: el.rotate,
                offset: el.offset,
                corners: el.corners,
                blur: el.blur,
                fill: effectiveFill.motionColor,
                border: ((el.runtimeExtra(RenderExtrasKey.borderGradient) as? RenderBorderGradientSpec)?.top ?? el.borderColor).motionColor,
                layoutAnim: layoutAnimSpec,
                styleSpring: styleSp,
                colorSpring: colorSp,
                animateOffset: (el.styleSpring != nil || commitMotion != nil || el.layoutAnim != nil),
                paintSpring: paintSp,
                offsetAnim: selfInstantLayoutOrStyle ? nil : offsetAnim,
                opacityAnim: (selfInstantStyle ? nil : el.opacityMotionAnim) ?? (selfInstantLayoutOrStyle ? nil : el.kitOpacityAnim),
                scaleAnim: specScaleAnim,
                rotateAnim: selfInstantLayoutOrStyle ? nil : el.rotateMotionAnim,
                iconTurn: el.iconRotation,
                transition: specTransition,
                snapMount: specSnapMount,
                enterDelay: specEnterDelay
            ))
            if !selfInstantLayoutOrStyle, let blurMotion = el.blurMotionOverride {
                specs[specs.count - 1].blurMotion = blurMotion
            }

            guard childCount > 0 else { return }
            let growthSlideY: Float = {
                guard let gEntry = growth,
                      gEntry.track.moving,
                      let slide = gEntry.contentSlide,
                      abs(slide.was) > 0.01 else {
                    return 0
                }
                let left = gEntry.track.target - gEntry.track.h
                guard left * slide.was > 0 else { return 0 }
                return slide.dy * min(1, max(0, left / slide.was))
            }()

            let foldChildLift: Float = {
                guard el.foldGlideSpec != nil, let gEntry = growth else { return 0 }
                let landedShut = gEntry.track.isShut && !gEntry.track.moving
                if landedShut && !foldRowHoldsExiting(rowPath: path) {
                    return 0
                }
                return gEntry.track.currentLift()
            }()
            let childFoldHeaderPath: String? = (foldChildLift > 0) ? effectiveFoldHeaders["fold:\(path)"] : nextFoldHeaderPath
            let childFoldHeaderLift: Float = (foldChildLift > 0) ? foldChildLift : nextFoldHeaderLift

            let childLayouts = el.layout.usesNaturalGrowthContents ? item.naturalLayout?.children ?? solved.children : solved.children
            if item.memoPaths == nil, let memoPaths, canReplayFlat, memoPaths.allowsSpan,
               !memoPaths.owner.duplicateSiblings, memoPaths.owner.traits.isDisjoint(with: [.mutableLayout, .duplicateKeys]),
               item.naturalLayout == nil, el.layout.scrollAxes.isEmpty, el.growthSpec == nil, el.foldGlideSpec == nil,
               childFoldHeaderPath == nil, growthSlideY == 0, foldChildLift == 0, childScaleChain.isEmpty,
               childStaticInh.scale == Vec2(1, 1), childStaticInh.anchor == childStaticInh.anchorTo,
               childStaticInh.offset == .zero {
                let context = FlatMemoContext(frame: flatFrame, flow: nodeFlow, directed: nodeDirected,
                    inert: effectiveInert, z: ownZ, instant: childInstant, row: childInRow,
                    underFold: item.parentUnderFold, styleSpring: nodeStyleSpring)
                if let source = item.virtualRow, (captureMount || stableForFlatReplay(nid)),
                   let inherited = Self.retainedRowInputs(item, frame: flatFrame),
                   el.anchor == nil, el.scale == Vec2(1, 1), el.offset == .zero, el.rotate == 0,
                   el.loopingSpec == nil, el.clipFade == nil, el.pressBg == nil, el.flightId == nil {
                    var motion = specs[myIndex]
                    if let scale = mountedScales[myIndex] {
                        motion.scaleAnim = scale
                        motion.enterDelay = 0
                    }
                    memoPaths.rowRoot = MemoFlatRowRoot(source: source, inherited: inherited, childContext: context,
                        node: flat, motion: motion, instant: ancestorInstant, parentHasGrowth: item.parentHasGrowth)
                }
                if let span = memoPaths.span, span.context == context, span.specs.first?.parent == nid,
                   MemoFlatSpan<State>.equalLayouts(span.children, childLayouts),
                   ((!checkFrameTracks && span.appliedRange(at: layoutCommitGen) != nil) ||
                    span.nodes.allSatisfy({ stableForFlatReplay($0.nodeId) })) {
                    let start = newFlat.count
                    if let previous = span.appliedRange(at: layoutCommitGen) {
                        reusedFlatRanges.append((start..<(start + span.nodes.count), previous))
                    }
                    appliedMemoSpans.append((span, start))
                    span.append(to: &newFlat, byPath: &newByPath, byId: &newIndices, specs: &specs,
                        instants: &ancestorInstants, root: myIndex,
                        clip: childClip, fades: childClipFades, enclosing: item.enclosingScrollIndex,
                        vertical: item.enclosingVScrollIndex, horizontal: item.enclosingHScrollIndex)
                    memoPaths.replayedNodes = span.nodes.count
                    return
                }
                flatCaptures.append(FlatMemoCapture(owner: memoPaths, root: myIndex,
                                                    children: childLayouts, context: context))
            }
            // An indexed virtual source owns the exact root value. A public memo only
            // guarantees the child buffer and may return a differently styled root.
            let virtualRows = canReplayFlat && expandedContextOverride == nil &&
                el.virtualEstimate != nil && el.layout.scrollAxes.isEmpty ? virtualExpansion.builtVirtualRows[path] : nil
            let siblings = ContiguousArray(el.children)
            for cIdx in (0..<childCount).reversed() {
                let address = childPaths.addresses[cIdx]
                let row = virtualRows.flatMap { rows in address.key.flatMap { rows[$0] } }
                walkStack.append(WalkItem(
                    element: FlatElement(siblings, at: cIdx),
                    memoPaths: memoPaths, virtualRow: row?.layoutRootMemo == nil ? nil : row,
                    memoSlot: childPaths.firstChildSlot + cIdx,
                    resolvedId: childPaths.addresses[cIdx].id,
                    solved: childLayouts[cIdx],
                    resolvedKey: childPaths.addresses[cIdx].key,
                    path: childPaths.addresses[cIdx].path,
                    parentIdx: myIndex,
                    parentOrigin: Vec2(worldX, worldY),
                    parentUnscrolledOrigin: Vec2(unscrolledX, unscrolledY),
                    parentScroll: ownScroll,
                    parentScale: nodeInheritedScale,
                    scaleChain: childScaleChain,
                    inheritedClip: childClip,
                    inheritedInert: effectiveInert,
                    inheritedZ: ownZ,
                    inInstantSubtree: childInstant,
                    inheritedClipFades: childClipFades,
                    enclosingScrollIndex: !el.layout.scrollAxes.isEmpty ? myIndex : item.enclosingScrollIndex,
                    enclosingVScrollIndex: el.layout.scrollAxes.contains(.vertical) ? myIndex : item.enclosingVScrollIndex,
                    enclosingHScrollIndex: el.layout.scrollAxes.contains(.horizontal) ? myIndex : item.enclosingHScrollIndex,
                    staticInh: childStaticInh,
                    rowLayout: childInRow,
                    parentHasGrowth: el.growthSpec != nil,
                    parentUnderFold: item.parentUnderFold || el.foldGlideSpec != nil,
                    parentNewlyMounted: isFreshMount,
                    inheritedStyleSpring: nodeStyleSpring,
                    parentFlow: nodeFlow,
                    parentDirected: nodeDirected,
                    foldHeaderPath: childFoldHeaderPath,
                    foldHeaderLift: childFoldHeaderLift,
                    growthPlacementShiftY: growthSlideY - foldChildLift + (closingChildShiftsY?[cIdx] ?? 0),
                    naturalLayout: item.naturalLayout?.children[cIdx]
                ))
            }
        }

        for capture in flatCaptures {
            capture.owner.span = MemoFlatSpan(capture, flat: newFlat, specs: specs,
                                               instants: ancestorInstants, mountedScales: mountedScales,
                                               stable: stableForFlatReplay)
            if let span = capture.owner.span, span.matchesCaptureSpecs {
                appliedMemoSpans.append((span, capture.root + 1))
            }
        }
        flatMemoPaths = nextMemoPaths

        #if DEBUG
        LayoutDiagnostics.checkCollapsedScrolls(nodes: newFlat)
        #endif

        let pass = MeasurePassResult(
            viewRootEl: rootEl,
            expandedRootEl: expandedRoot,
            nodes: newFlat,
            byPath: newByPath,
            indexById: newIndices,
            specs: specs,
            loopSpecs: loopSpecs,
            ancestorInstants: ancestorInstants,
            warnings: warnings,
            reads: collector.reads,
            virtualExpansion: virtualExpansion,
            rootBackground: rootBg,
            rootHeight: solvedRoot.layout.localRect.height,
            helpLook: passHelpLook,
            viewportRead: collector.viewportRead,
            foldOpens: growthCapture.foldOpens,
            scrollCuts: growthCapture.scrollCuts,
            foldHeaderUpdates: growthCapture.foldHeaderUpdates,
            textLayouts: textLayoutCollector.map
        )
        pass.reusedFlatRanges = reusedFlatRanges
        pass.appliedMemoSpans = appliedMemoSpans
        pass.naturalJoinedRowTargets = naturalJoinedRowTargets
        pass.naturalLaunchTargets = naturalLaunchTargets
        return pass
    }

    private func rectForRead(key: String, nodes: [FlatNode], index: LayoutKeyIndex?) -> [Float]? {
        let (cleanKey, scrolled) = LayoutReadConstants.stripWindowPrefix(key)
        if let idx = LayoutKeyIndex.firstMatch(
            selector: cleanKey,
            index: index,
            nodes: nodes,
            keyOf: { $0.key },
            parentOf: { $0.parentIndex }
        ) {
            let r = scrolled ? nodes[idx].targetRect : nodes[idx].unscrolledRect
            let sz = nodes[idx].localSize
            return [r.left, r.top, sz.x, sz.y]
        }
        return highlightTarget(selector: cleanKey, nodes: nodes, index: index, scrolled: scrolled)
    }

    private func highlightBoxes(
        node: FlatNode,
        boxRect: MotionRect,
        scale: Vec2 = Vec2(1, 1)
    ) -> [(highlightIndex: Int, rect: MotionRect)] {
        let el = node.el
        guard let hls = el.textHighlights, !hls.isEmpty else { return [] }
        guard !el.isSecure else { return [] }
        let padL = el.layout.padding.left * scale.x
        let padT = el.layout.padding.top * scale.y
        let padR = el.layout.padding.right * scale.x
        let innerW = max(0, boxRect.width - padL - padR)
        let content: String
        let shaped: ShapedText
        if let edit = el.handlers.editLens?.get(state) {
            guard !edit.isSecure else { return [] }
            let resolved = ElDisplayResolver.resolveInput(el: el, edit: edit, innerWidth: innerW / max(1e-4, scale.x), pxScale: pixelScale)
            guard !resolved.showingPlaceholder else { return [] }
            content = resolved.renderedString
            shaped = textSystem.layoutInput(
                text: content, spans: resolved.spans, pills: resolved.pills, style: resolved.style,
                maxWidth: resolved.maxWidthForShape, pixelScale: pixelScale, emitGlyphs: false,
                countAsRebreak: false, request: Self.paragraphRequest(field: node.nodeId, el: el, edit: edit, resolved: resolved)
            ).shaped
        } else {
            content = el.liveText?.get() ?? el.plainText ?? el.richSpans?.map(\.text).joined() ?? ""
            guard !content.isEmpty else { return [] }
            let wrapWidth = (innerW / max(1e-4, scale.x)) + 0.5
            shaped = textSystem.shape(text: content, spans: el.richSpans, style: el.textStyle, maxWidth: wrapWidth, pixelScale: pixelScale, emitGlyphs: false)
        }
        let ox = boxRect.x + padL
        let oy = boxRect.y + padT
        let utf8Len = content.utf8.count
        let drawnLen = (shaped.elided != nil ? shaped.drawnText : content).utf8.count
        var out: [(Int, MotionRect)] = []
        for (k, hl) in hls.enumerated() {
            let aOrig = max(0, min(hl.byteRange.lowerBound, utf8Len))
            let bOrig = max(aOrig, min(hl.byteRange.upperBound, utf8Len))
            guard aOrig < bOrig else { continue }
            let mappedRange: Range<Int>
            if let elided = shaped.elided {
                mappedRange = elided.mark(aOrig, bOrig, isLink: false)
            } else {
                mappedRange = aOrig..<bOrig
            }
            let a = max(0, min(mappedRange.lowerBound, drawnLen))
            let b = max(a, min(mappedRange.upperBound, drawnLen))
            guard a < b else { continue }
            for r in textSystem.selectionRects(in: shaped, utf8Range: a..<b, pixelScale: pixelScale) where r.z > 0 {
                let x = ox + r.x * scale.x
                let y = oy + r.y * scale.y
                let w = r.z * scale.x
                let h = r.w * scale.y
                out.append((k, MotionRect.fromXYWH(x, y, w, h)))
            }
        }
        return out
    }

    /// Text marks use the same glyph rectangles in the reference scene and the native frame.
    internal func highlightElementInfos(
        node: FlatNode, owner: ElementInfo, ownerIndex: Int, rect: MotionRect,
        scaleVec: Vec2, visibleRect: MotionRect
    ) -> [ElementInfo] {
        guard let hls = node.el.textHighlights, !hls.isEmpty, !owner.secure else { return [] }
        let edit = node.el.handlers.editLens?.get(state)
        guard !node.el.isSecure, edit?.isSecure != true,
              let text = edit?.text ?? node.el.liveText?.get() ?? node.el.plainText ?? node.el.richSpans?.map(\.text).joined(),
              !text.isEmpty else { return [] }
        var marks: [ElementInfo] = []
        let drawnBoxes = highlightBoxes(node: node, boxRect: rect, scale: scaleVec)
        let targetBoxes = highlightBoxes(node: node, boxRect: node.targetRect)
        var drawnUnions = [MotionRect?](repeating: nil, count: hls.count)
        var targetUnions = [MotionRect?](repeating: nil, count: hls.count)
        for (k, r) in drawnBoxes {
            drawnUnions[k] = drawnUnions[k].map {
                MotionRect(left: min($0.left, r.left), top: min($0.top, r.top), right: max($0.right, r.right), bottom: max($0.bottom, r.bottom))
            } ?? r
        }
        for (k, r) in targetBoxes {
            targetUnions[k] = targetUnions[k].map {
                MotionRect(left: min($0.left, r.left), top: min($0.top, r.top), right: max($0.right, r.right), bottom: max($0.bottom, r.bottom))
            } ?? r
        }
        let txtUtf8 = Array(text.utf8)
        for (k, hl) in hls.enumerated() {
            guard let r = drawnUnions[k] else { continue }
            let t = targetUnions[k] ?? r
            let vis = intersectRects(r, visibleRect)
            let a = max(0, min(hl.byteRange.lowerBound, txtUtf8.count))
            let b = max(a, min(hl.byteRange.upperBound, txtUtf8.count))
            let words = (a < b) ? String(decoding: txtUtf8[a..<b], as: UTF8.self) : nil
            let markPath = "\(owner.path)#mark-\(k)"
            marks.append(ElementInfo(
                path: markPath,
                key: hl.key,
                parentIndex: ownerIndex,
                role: .mark,
                geometry: .boxes(rect: r, target: t, visible: vis),
                committedLayoutTarget: owner.committedTextTarget(t),
                opacity: owner.opacity,
                scale: scaleVec.x,
                blur: owner.blur,
                radius: 4.0,
                fill: hl.bg,
                textColor: node.el.textColor ?? cxSettings.viewDefaults.foreground,
                text: words,
                label: words,
                help: owner.help,
                selected: nil,
                expanded: nil,
                level: nil,
                itemSelected: false,
                focusable: false,
                focused: false,
                focusVisible: false,
                inert: owner.inert,
                moving: owner.moving,
                exiting: owner.exiting,
                hover: 0,
                press: 0,
                scrolled: owner.scrolled,
                carriedScrolled: owner.carriedScrolled,
                caret: nil,
                secure: owner.secure,
                disabled: node.el.a11yDisabled,
                checked: node.el.a11yChecked,
                a11yValue: node.el.a11yValue,
                a11yDescription: node.el.a11yDescription,
                a11yHidden: node.el.isA11yHidden,
                stuck: 0
            ))
        }
        return marks
    }

    internal func highlightTargetWithNode(
        selector: String,
        scrolled: Bool = true,
        including accepts: (Int) -> Bool = { _ in true }
    ) -> (nodeIndex: Int, rect: MotionRect)? {
        let candidates = LayoutKeyIndex.markedCandidates(selector: selector, index: layoutKeyIndex.indexIfValid(nodes: flatNodes, stamp: layoutCommitGen), nodes: flatNodes)
            ?? Array(flatNodes.indices)
        var union: MotionRect? = nil
        var ownerIdx: Int? = nil
        for i in candidates where accepts(i) {
            let n = flatNodes[i]
            guard let hls = n.el.textHighlights, !hls.isEmpty else { continue }
            let matches: [Bool] = hls.map { hl in
                guard let hkey = hl.key else { return false }
                return LayoutKeyIndex.selectsUnder(
                    selector: selector,
                    nodeIndex: i,
                    nodes: flatNodes,
                    keyOf: { $0.key },
                    parentOf: { $0.parentIndex },
                    highlightKey: hkey
                )
            }
            guard matches.contains(true) else { continue }
            let baseRect = scrolled ? n.targetRect : n.unscrolledRect
            for (k, r) in highlightBoxes(node: n, boxRect: baseRect) where matches[k] {
                if let u = union {
                    union = MotionRect(
                        left: min(u.left, r.left),
                        top: min(u.top, r.top),
                        right: max(u.right, r.right),
                        bottom: max(u.bottom, r.bottom)
                    )
                } else {
                    ownerIdx = i
                    union = r
                }
            }
        }
        guard let ownerIdx, let union else { return nil }
        return (ownerIdx, union)
    }

    private func highlightTarget(
        selector: String,
        nodes: [FlatNode],
        index: LayoutKeyIndex?,
        scrolled: Bool
    ) -> [Float]? {
        let candidates = LayoutKeyIndex.markedCandidates(selector: selector, index: index, nodes: nodes)
            ?? Array(nodes.indices)
        var union: MotionRect? = nil
        for i in candidates {
            let n = nodes[i]
            guard let hls = n.el.textHighlights, !hls.isEmpty else { continue }
            let matches: [Bool] = hls.map { hl in
                guard let hkey = hl.key else { return false }
                return LayoutKeyIndex.selectsUnder(
                    selector: selector,
                    nodeIndex: i,
                    nodes: nodes,
                    keyOf: { $0.key },
                    parentOf: { $0.parentIndex },
                    highlightKey: hkey
                )
            }
            guard matches.contains(true) else { continue }
            let baseRect = scrolled ? n.targetRect : n.unscrolledRect
            for (k, r) in highlightBoxes(node: n, boxRect: baseRect) where matches[k] {
                if let u = union {
                    union = MotionRect(
                        left: min(u.left, r.left),
                        top: min(u.top, r.top),
                        right: max(u.right, r.right),
                        bottom: max(u.bottom, r.bottom)
                    )
                } else {
                    union = r
                }
            }
        }
        return union.map { LayoutReadConstants.rectArray($0) }
    }

    private func refreshLayoutSeen() {
        guard !layoutSeen.isEmpty else { return }
        layoutKeyIndex.prepare(
            nodes: flatNodes,
            stamp: layoutCommitGen,
            lookups: layoutSeen.reads.count,
            selector: layoutSeen.reads.first?.key,
            keyOf: { $0.key },
            highlightKeysOf: { $0.el.textHighlights?.compactMap(\.key) ?? [] }
        )
        let idx = layoutKeyIndex.indexIfValid(nodes: flatNodes, stamp: layoutCommitGen)
        var nextRects: [String: [Float]?] = [:]
        for r in layoutSeen.reads {
            if nextRects.index(forKey: r.key) == nil {
                nextRects[r.key] = rectForRead(key: r.key, nodes: flatNodes, index: idx)
            }
        }
        layoutSeen.rects = nextRects
    }

    internal func evaluateLayoutMoved(reads: [LayoutReadEntry], nodes: [FlatNode], force: Bool) -> Bool {
        guard !reads.isEmpty else { return false }
        var passIndex = LayoutKeyIndex()
        let activeIdx: LayoutKeyIndex?
        if reads.count > LayoutReadConstants.scanReads {
            passIndex.build(
                nodes: nodes,
                keyOf: { $0.key },
                highlightKeysOf: { $0.el.textHighlights?.compactMap(\.key) ?? [] }
            )
            activeIdx = passIndex
        } else {
            activeIdx = nil
        }
        var anyMoved = false
        var measured: [String: [Float]?] = [:]
        for entry in reads {
            let cur: [Float]?
            if let cached = measured[entry.key] {
                cur = cached
            } else {
                cur = rectForRead(key: entry.key, nodes: nodes, index: activeIdx)
                measured[entry.key] = cur
            }
            let prev = layoutSeen.rects[entry.key] ?? nil
            if entry.moved(prev, cur) {
                anyMoved = true
            }
        }
        if anyMoved || force {
            for (k, v) in measured {
                layoutSeen.rects[k] = v
            }
        }
        return anyMoved
    }

    private func layoutReadsMoved() -> Bool {
        guard layoutFeedback.isOpen, !layoutSeen.isEmpty else { return false }
        layoutKeyIndex.prepare(
            nodes: flatNodes,
            stamp: layoutCommitGen,
            lookups: layoutSeen.reads.count,
            selector: layoutSeen.reads.first?.key,
            keyOf: { $0.key },
            highlightKeysOf: { $0.el.textHighlights?.compactMap(\.key) ?? [] }
        )
        let idx = layoutKeyIndex.indexIfValid(nodes: flatNodes, stamp: layoutCommitGen)
        for entry in layoutSeen.reads {
            let cur = rectForRead(key: entry.key, nodes: flatNodes, index: idx)
            let prev = layoutSeen.rects[entry.key] ?? nil
            if entry.moved(prev, cur) {
                perfWatch.meter.read(key: entry.key)
                return true
            }
        }
        return false
    }

    internal enum CommitPassResult { case applied, needsSettle }

    private func commitTreePass(
        at now: Double,
        cut: Bool,
        settlePass: Int,
        commitKind: TxCommit,
        commitMotion: MotionSource?,
        commitColorSpring: Spring?,
        commitFollowEdge: Bool,
        commitCut: Bool,
        didRunView: inout Bool
    ) -> CommitPassResult {
        viewCommitCount += 1
        if settlePass == 0 {
            CommitGenerationStore.increment()
            captureKeepAnchorsBeforeCommit()
            if layoutReadsMoved() {
                resizeReadMovedFlag = true
            }
            refreshLayoutSeen()
        }
        let focusedCaret = currentFocusedCaret()
        cxSettings.lastCommittedCaret = focusedCaret
        let prevMountedIds = nodeIndexById.keys

        let plannedKind: ResizeCommitKind = (settlePass == 0 && !activeExplicitSettleCut && !commitKind.lands)
            ? nextCommitKind()
            : .rebuild

        if plannedKind == .remount,
           let remountPass = tryVirtualRemountPass(
               at: now,
               cut: cut,
               commitKind: commitKind,
               commitMotion: commitMotion,
               commitColorSpring: commitColorSpring,
               commitCut: commitCut,
               prevMountedIds: prevMountedIds
           ) {
            return applyMeasurePass(
                remountPass,
                at: now,
                cut: cut,
                settlePass: settlePass,
                commitKind: commitKind,
                commitMotion: commitMotion,
                commitColorSpring: commitColorSpring,
                commitFollowEdge: commitFollowEdge,
                commitCut: commitCut,
                prevMountedIds: prevMountedIds
            )
        }

        if plannedKind == .relayout,
           let relayoutPass = tryRelayoutPass(
               at: now,
               cut: cut,
               commitKind: commitKind,
               commitMotion: commitMotion,
               commitColorSpring: commitColorSpring,
               commitCut: commitCut,
               prevMountedIds: prevMountedIds
           ) {
            pendingResizeRelayout = false
            pendingGrowthRelayout = false
            resizeReadMovedFlag = false
            return applyMeasurePass(
                relayoutPass,
                at: now,
                cut: cut,
                settlePass: settlePass,
                commitKind: commitKind,
                commitMotion: commitMotion,
                commitColorSpring: commitColorSpring,
                commitFollowEdge: commitFollowEdge,
                commitCut: commitCut,
                prevMountedIds: prevMountedIds
            )
        }

        didRunView = true
        guard var pass = measurePass(
            at: now,
            cut: cut,
            commitKind: commitKind,
            commitMotion: commitMotion,
            commitColorSpring: commitColorSpring,
            commitCut: commitCut,
            prevMountedIds: prevMountedIds,
            focusedCaret: focusedCaret,
            allowZoomSettle: settlePass == 0,
            allowRebuildRegionRowReuse: settlePass == 0
        ) else {
            return .needsSettle
        }
        var retryCaret = focusedCaret
        let initialCaretMoved = cxSettings.caretReadByView && caretMoved(from: retryCaret, in: pass.nodes)
        let prevSelectionBoxes = cxSettings.selectionRectsReadByView ? computeSelectionBoxes(in: flatNodes) : []
        if (!pass.reads.isEmpty && evaluateLayoutMoved(reads: pass.reads, nodes: pass.nodes, force: false))
            || initialCaretMoved
            || (cxSettings.selectionRectsReadByView && SelectionRectsMath.boxesMoved(prevSelectionBoxes, computeSelectionBoxes(in: pass.nodes))) {
            for extra in 0..<LayoutReadConstants.passes {
                if cxSettings.caretReadByView, let nextC = focusedCaretInfo(in: pass.nodes) {
                    retryCaret = nextC
                    cxSettings.lastCommittedCaret = nextC
                }
                let iterPrevBoxes = cxSettings.selectionRectsReadByView ? computeSelectionBoxes(in: pass.nodes) : []
                if let nextPass = measurePass(
                    at: now,
                    cut: cut,
                    commitKind: commitKind,
                    commitMotion: commitMotion,
                    commitColorSpring: commitColorSpring,
                    commitCut: commitCut,
                    prevMountedIds: prevMountedIds,
                    focusedCaret: retryCaret,
                    allowZoomSettle: false,
                    memoNodes: pass.nodes,
                    allowRebuildRegionRowReuse: false
                ) {
                    pass = nextPass
                }
                let isLast = (extra + 1 == LayoutReadConstants.passes)
                let readsStillMoved = !pass.reads.isEmpty && evaluateLayoutMoved(reads: pass.reads, nodes: pass.nodes, force: isLast)
                let caretStillMoved = cxSettings.caretReadByView && caretMoved(from: retryCaret, in: pass.nodes)
                let selStillMoving = cxSettings.selectionRectsReadByView && SelectionRectsMath.boxesMoved(iterPrevBoxes, computeSelectionBoxes(in: pass.nodes))
                if !readsStillMoved && !caretStillMoved && !selStillMoving {
                    break
                }
            }
        }

        cachedResizeBuild = ResizeCachedViewBuild(
            viewRootEl: pass.viewRootEl,
            expandedRootEl: pass.expandedRootEl,
            virtualExpansion: pass.virtualExpansion,
            helpLook: pass.helpLook,
            env: currentResizeBuildEnv(),
            fitHeight: fitHeight,
            reusable: Self.isTreeReusableForRelayout(pass.expandedRootEl),
            reads: pass.reads,
            caretRead: cxSettings.caretReadByView,
            viewport: viewport,
            viewportRead: pass.viewportRead
        )
        cachedResizeBuild?.memoEnvHash = lastViewMemoEnvHash
        cachedResizeBuild?.viewOnlyMemoIds = lastViewOnlyMemoIds
        cachedResizeBuild?.virtualRowCache = pass.virtualExpansion.builtVirtualRows
        stateUnchangedSinceBuild = true
        pendingResizeRelayout = false
        pendingGrowthRelayout = false
        resizeReadMovedFlag = false

        return applyMeasurePass(
            pass,
            at: now,
            cut: cut,
            settlePass: settlePass,
            commitKind: commitKind,
            commitMotion: commitMotion,
            commitColorSpring: commitColorSpring,
            commitFollowEdge: commitFollowEdge,
            commitCut: commitCut,
            prevMountedIds: prevMountedIds
        )
    }

    @inline(never)
    internal func applyMeasurePass(
        _ pass: MeasurePassResult,
        at now: Double,
        cut: Bool,
        settlePass: Int,
        commitKind: TxCommit,
        commitMotion: MotionSource?,
        commitColorSpring: Spring?,
        commitFollowEdge: Bool,
        commitCut: Bool,
        prevMountedIds: Dictionary<NodeId, Int>.Keys
    ) -> CommitPassResult {
        if let measuredGrowth = pass.measuredGrowthRows {
            growthRows = measuredGrowth
        }
        if let measuredStacks = pass.measuredGrowthStacks {
            growthStacks = measuredStacks
        }
        for upd in pass.foldHeaderUpdates {
            foldHeaders[upd.foldKey] = upd.headerPath
        }
        for (gKey, var entry) in growthRows {
            let landedShut = entry.track.isShut && !entry.track.moving
            if landedShut && !foldRowHoldsExiting(rowPath: String(gKey.dropFirst(5))) {
                entry.track.forgetFolded()
                growthRows[gKey] = entry
            }
        }
        foldHeaders = foldHeaders.filter { gKey, _ in
            guard let entry = growthRows[gKey] else { return false }
            let landedShut = entry.track.isShut && !entry.track.moving
            return (entry.track.currentLift() > 0 && (!landedShut || foldRowHoldsExiting(rowPath: String(gKey.dropFirst(5))))) || entry.track.isShuttingFold
        }
        for sc in pass.scrollCuts where sc.cut > 0 {
            let nid = NodeId.hash("scroll:\(sc.viewport)")
            let cur = scrollOffsets[sc.viewport] ?? .zero
            if scrollGlidingPaths.contains(sc.viewport),
               let tgt = scrollStore.target(nid, Props.SCROLL) {
                let shiftedTarget = Vec2(tgt.x, max(0, tgt.y - sc.cut))
                scrollStore.snap(nid, Props.SCROLL, to: cur)
                scrollStore.set(nid, Props.SCROLL, to: shiftedTarget, anim: .spring(Growth.spring), at: cxSettings.scaledTime(at: now))
            } else {
                scrollStore.snap(nid, Props.SCROLL, to: cur)
            }
        }
        if let effRM = pass.effectiveReducedMotion, effRM != self.reducedMotion {
            // The commit underway already built with it: no commit, and no cause, is left.
            let why = commitWhyPending
            isApplyingEffectiveReducedMotion = true
            self.reducedMotion = effRM
            isApplyingEffectiveReducedMotion = false
            self.needsCommit = false
            commitWhyPending = why
        }
        // Keep seen layout rects aligned with final pass keys
        var finalSeen: [String: [Float]?] = [:]
        if !pass.reads.isEmpty {
            _ = evaluateLayoutMoved(reads: pass.reads, nodes: pass.nodes, force: true)
            for entry in pass.reads {
                finalSeen[entry.key] = layoutSeen.rects[entry.key] ?? nil
            }
        }
        layoutSeen.reads = pass.reads
        layoutSeen.rects = finalSeen

        viewHelpLook = pass.helpLook
        virtualSelectionSources = pass.virtualExpansion.selectionSources
        if let bg = pass.rootBackground {
            clearColor = bg
        }

        let prevFocusedPath = focusedPath
        let prevFocusedKey = focusedKey
        let prevFocusVisible = focusVisible

        var roles: [LayoutObserverTraits] = []
        roles.reserveCapacity(pass.nodes.count)
        pass.nodes.withUnsafeBufferPointer { nodes in
            var cursor = 0
            for span in pass.reusedFlatRanges {
                for i in cursor..<span.current.lowerBound {
                    roles.append(LayoutObserverTraits(nodes[i].el))
                }
                roles.append(contentsOf: layoutObservers.authored[span.previous])
                cursor = span.current.upperBound
            }
            for i in cursor..<nodes.count { roles.append(LayoutObserverTraits(nodes[i].el)) }
        }

        // Apply modal inertness: if any mounted subtree is `.modal(...)`, elements outside the topmost modal
        // (and its anchored portal popovers) become inert!
        var newModalMembers: Set<String> = []
        modalAncestorPaths.removeAll(keepingCapacity: true)
        var newActiveModalPath: String? = nil
        if let modalRootIdx = roles.indices.last(where: { roles[$0].contains(.focusReturn) && pass.nodes[$0].el.isModal }) {
            let modalPrefix = pass.nodes[modalRootIdx].path
            newActiveModalPath = modalPrefix
            var memberIndices = Set<Int>()
            for i in modalRootIdx..<pass.nodes.count {
                let p = pass.nodes[i].path
                if p == modalPrefix || p.hasPrefix(modalPrefix + "/") {
                    memberIndices.insert(i)
                }
            }
            if kitHooks.titlebar.caption != nil, pass.nodes.first?.key == TitlebarCaption.frameKey,
               let strip = pass.nodes.first(where: { $0.parentIndex == 0 && $0.key == TitlebarCaption.buttonsKey }) {
                // Caption controls remain reachable while the application holds a modal.
                for i in strip.index..<pass.nodes.count {
                    let path = pass.nodes[i].path
                    if path == strip.path || path.hasPrefix(strip.path + "/") { memberIndices.insert(i) }
                }
            }
            var addedAnchored = true
            while addedAnchored {
                addedAnchored = false
                for i in 0..<pass.nodes.count where !memberIndices.contains(i) {
                    if let ak = pass.nodes[i].el.anchor?.key,
                       memberIndices.contains(where: { pass.nodes[$0].key == ak }) {
                        let portalPrefix = pass.nodes[i].path
                        for j in i..<pass.nodes.count {
                            let pj = pass.nodes[j].path
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
                newModalMembers.insert(pass.nodes[i].path)
                var parent = pass.nodes[i].parentIndex
                while let p = parent, !memberIndices.contains(p),
                      modalAncestorPaths.insert(pass.nodes[p].path).inserted {
                    parent = pass.nodes[p].parentIndex
                }
            }
            for i in 0..<pass.nodes.count where !memberIndices.contains(i) {
                pass.nodes[i].effectiveInert = true
            }
        }
        modalMemberPaths = newModalMembers
        activeModalPath = newActiveModalPath

        var specs = pass.specs

        retainDepartingSnapshots(pass)
        var nowRevealedSecureIds: Set<NodeId> = []
        var concealedSecureIndices: [Int] = []
        var observers = LayoutObservers()
        var sameHoverOrder = pass.nodes.count == builtHoverIds.count
        pictureAspects.removeAll(keepingCapacity: true)
        func collect(_ node: borrowing FlatNode, traits: LayoutObserverTraits, at i: Int) {
            if traits.contains(.pictureAspect), let pixels = node.el.pixelsPayload {
                let size = pixels.size
                let ratio = size.height > 0 ? Float(size.width) / Float(size.height) : 0
                pictureAspects.append((node.nodeId, pixels, ratio))
            }
            observers.register(traits, at: i, id: node.nodeId, inert: node.effectiveInert)
            if sameHoverOrder && node.nodeId != builtHoverIds[i] { sameHoverOrder = false }
            if !observers.bottomViewports.isEmpty, let parent = node.parentIndex {
                observers.bottomChildren[parent]?.append(i)
            }
            guard traits.contains(.secureOrEditable) else {
                if !lastSecureMaskInfo.isEmpty { lastSecureMaskInfo.removeValue(forKey: node.nodeId) }
                return
            }
            let edit = node.el.handlers.editLens?.get(state)
            let isSec = node.el.isSecure || (edit?.isSecure == true)
            let isRev = node.el.revealedOverride ?? (edit?.isRevealed ?? false)
            if isSec {
                if let edit {
                    lastSecureMaskInfo[node.nodeId] = (edit.text.count, edit.multiline)
                } else {
                    let len = (node.el.liveText?.get() ?? node.el.plainText ?? node.el.richSpans?.map(\.text).joined())?.count ?? 0
                    lastSecureMaskInfo[node.nodeId] = (len, len > 0)
                }
            } else if !lastSecureMaskInfo.isEmpty {
                lastSecureMaskInfo.removeValue(forKey: node.nodeId)
            }
            if isSec && isRev {
                nowRevealedSecureIds.insert(node.nodeId)
            } else if isSec && prevRevealedSecureIds.contains(node.nodeId) {
                concealedSecureIndices.append(i)
            }
        }
        observers.authored = roles
        pass.nodes.withUnsafeBufferPointer { nodes in
            for i in roles.indices {
                let traits = roles[i]
                if traits.bits == 0 && !sameHoverOrder && observers.bottomViewports.isEmpty && lastSecureMaskInfo.isEmpty {
                    continue
                }
                collect(nodes[i], traits: traits, at: i)
            }
        }

        let childExitOverrides = observers.hasChildExits
            ? collectChildExitOverrides(prevNodes: flatNodes, newPass: pass, cut: cut) : []

        var prevFlatNodesSnapshot: [FlatNode] = []
        swap(&prevFlatNodesSnapshot, &flatNodes)
        flatNodes = pass.nodes
        let previousIndexById = nodeIndexById
        nodeIndexById = pass.indexById
        let previousByPath = nodeByPath
        hoverOrderMatchesPaint = sameHoverOrder
        // An indexed window can alternate between two mounted sizes as rows enter and
        // leave. The renderer still verifies every presented edge and paint modifier.
        if pass.reusedFlatRanges.isEmpty {
            alternatePaintTopology = nil
        } else if let current = nativePaintTopology, !current.parentSlots.isEmpty,
                  current.parentSlots.count != pass.nodes.count {
            let alternate = alternatePaintTopology
            alternatePaintTopology = current
            if let alternate, alternate.parentSlots.count == pass.nodes.count {
                nativePaintTopology = alternate
            }
        }
        nativePaintTopology?.currentCommit = false
        layoutObservers = observers
        nodeByPath = pass.byPath
        accessibilityProjectionCache?.committed(reusing: pass.reusedFlatRanges)
        layoutCommitGen &+= 1
        for (span, start) in pass.appliedMemoSpans {
            span.markApplied(start: start, generation: layoutCommitGen)
        }
        layoutKeyIndex.invalidate()

        let prevKeys = prevNodeTextLayoutsForCommit ?? [:]
        prevNodeTextLayoutsForCommit = nil
        for nid in exitingTextLayouts.keys where pass.indexById[nid] != nil {
            exitingTextLayouts.removeValue(forKey: nid)
        }
        nodeTextLayouts = pass.textLayouts
        var activeShapeKeys: Set<TextShapeKey>?
        func activeKeys() -> Set<TextShapeKey> {
            if let activeShapeKeys { return activeShapeKeys }
            var keys = Set<TextShapeKey>()
            for record in nodeTextLayouts.values { keys.insert(record.box.shapeKey) }
            for record in exitingTextLayouts.values { keys.insert(record.box.shapeKey) }
            activeShapeKeys = keys
            return keys
        }
        for (nid, prev) in prevKeys {
            guard let cur = nodeTextLayouts[nid], cur.box.shapeKey != prev.shapeKey else { continue }
            guard !activeKeys().contains(prev.shapeKey) else { continue }
            let kind = TextLayoutRebreak.edited(was: prev.shapeKey.authText, now: cur.box.shapeKey.authText)
            if cur.isInput || prev.isInput || kind.isEdit { textSystem.supersede(prev.shapeKey) }
        }
        // Every commit advances the text cache clock, including remounts without edited labels.
        if let activeShapeKeys {
            textSystem.endCommit(activeKeys: activeShapeKeys)
        } else {
            textSystem.endCommit(mounted: nodeTextLayouts.values, exiting: exitingTextLayouts.values)
        }
        let allWarnings = pass.virtualExpansion.warnings + pass.warnings
        if !allWarnings.isEmpty {
            keyWarnings = allWarnings
        }

        if settlePass == 0 && memo.hasInvalidatedReads(computing: { currentMemoGeometry() }) {
            if prevFocusedPath != nil || blurredFocusPath != nil || webFocusTabStartPath != nil ||
                !hoverWithinPaths.isEmpty || !hoverDelays.isEmpty {
                interactionTreeBeforeSettle = (prevFlatNodesSnapshot, previousByPath)
            } else {
                spareFlatNodes = []
                swap(&spareFlatNodes, &prevFlatNodesSnapshot)
                spareFlatNodes.removeAll(keepingCapacity: true)
            }
            return .needsSettle
        }

        finishApplyMeasurePass(
            pass,
            specs: &specs,
            prevFocusedPath: prevFocusedPath,
            prevFocusedKey: prevFocusedKey,
            prevFocusVisible: prevFocusVisible,
            prevFlatNodesSnapshot: &prevFlatNodesSnapshot,
            previousByPath: previousByPath,
            previousIndexById: previousIndexById,
            childExitOverrides: childExitOverrides,
            at: now,
            cut: cut,
            commitKind: commitKind,
            commitMotion: commitMotion,
            commitColorSpring: commitColorSpring,
            commitFollowEdge: commitFollowEdge,
            commitCut: commitCut,
            prevMountedIds: prevMountedIds,
            nowRevealedSecureIds: nowRevealedSecureIds,
            concealedSecureIndices: concealedSecureIndices
        )
        return .applied
    }

    @inline(never)
    private func finishApplyMeasurePass(
        _ pass: MeasurePassResult,
        specs: inout [NodeSpec],
        prevFocusedPath: String?,
        prevFocusedKey: String?,
        prevFocusVisible: Bool,
        prevFlatNodesSnapshot: inout [FlatNode],
        previousByPath: [String: Int],
        previousIndexById: [NodeId: Int],
        childExitOverrides: [(childId: NodeId, parentEl: El<State>)],
        at now: Double,
        cut: Bool,
        commitKind: TxCommit,
        commitMotion: MotionSource?,
        commitColorSpring: Spring?,
        commitFollowEdge: Bool,
        commitCut: Bool,
        prevMountedIds: Dictionary<NodeId, Int>.Keys,
        nowRevealedSecureIds: Set<NodeId>,
        concealedSecureIndices: [Int]
    ) {
        for i in layoutObservers.inputPills {
            if let editLens = flatNodes[i].el.handlers.editLens {
                ElDisplayResolver.preResolveInputPills(el: &flatNodes[i].el, edit: editLens.get(state))
            }
        }

        virtualInputs = pass.virtualExpansion.virtualInputs
        // Release the interaction snapshot before recycling the old flat-node buffer below.
        do {
            let previousNodes = interactionTreeBeforeSettle?.nodes ?? prevFlatNodesSnapshot
            let previousPaths = interactionTreeBeforeSettle?.byPath ?? previousByPath
            interactionTreeBeforeSettle = nil
            reconcilePrunedHoverWithin(prevNodes: previousNodes, prevByPath: previousPaths, newByPath: pass.byPath, cut: cut, at: now)

            // Reconcile focus: keep focused key/path if still focusable & non-inert; sync TextEdit.focused; handle modal/focusReturn, autofocus & fallback.
            reconcileFocusAfterCommit(
                prevFocusedPath: prevFocusedPath,
                prevFocusedKey: prevFocusedKey,
                prevFocusVisible: prevFocusVisible,
                prevNodes: previousNodes,
                prevByPath: previousPaths
            )
            if focusedPath == prevFocusedPath { syncFocusedEditLineMode() }
            syncFollows()
            if let prevPath = prevFocusedPath, prevPath != focusedPath {
                let prevNode = previousPaths[prevPath].map { previousNodes[$0] }.flatMap { $0.path == prevPath ? $0 : nil }
                // Focus moved by the commit, not by input: `DIRTY`.
                handleKitFocusTransition(prevNode: prevNode, newPath: focusedPath, at: now, why: CommitWhy.dirty)
            }
        }
        settleKitHoverDelays(at: pointerPosition, now: now)
        reconcilePlaygroundAfterCommit(at: now)

        rebuildHoverCurves(for: pass.nodes)
        if cut || viewCommitCount == 1 {
            hoverHold = HoverHold()
            syncHoverTracks(at: lastScaledAnimNow, cut: true, held: false)
        }

        // Resolve cross-parent matched-geometry (`flightId` / `matched`) flights against last-seen rects.
        var matchedStarts: [NodeId: MatchedFlightStart] = [:]
        var newCommittedMatched: [String: MatchedSeenSnapshot] = [:]
        var matchedRootPaths: [String] = []
        let isFreshOrExiting: (NodeId) -> Bool = { nid in
            guard self.scene.hasNode(nid) else { return true }
            if case .exiting = self.scene.phase(nid) { return true }
            return false
        }
        for i in layoutObservers.matchedFlights {
            let node = pass.nodes[i]
            guard let fid = node.el.flightId else { continue }
            let nid = node.nodeId
            if newCommittedMatched[fid] != nil {
                keyWarnings.append("duplicate matched id \"\(fid)\": the last element in tree order is matched; give each element its own id")
            }
            newCommittedMatched[fid] = MatchedSeenSnapshot(
                id: nid,
                path: node.path,
                rect: node.targetRect,
                corners: node.el.corners,
                fill: node.el.background.motionColor,
                opacity: node.el.opacity
            )
            if !cut, !reducedMotion, isFreshOrExiting(nid),
               let prev = seenMatchedByFlightId[fid] ?? committedMatchedByFlightId[fid],
               prev.id != nid {
                let matchedSpring: Spring = {
                    if let commitMotion { return commitMotion.spring }
                    if let f = node.el.flightSpring { return f }
                    if case .spring(let sp) = node.el.layoutAnim?.x.curve { return sp }
                    return node.el.styleSpring ?? MotionTokens.REFLOW
                }()
                var start = MatchedFlightStart(
                    fromId: prev.id,
                    startRect: prev.rect,
                    startCorners: prev.corners,
                    startFill: prev.fill,
                    startOpacity: prev.opacity,
                    spring: matchedSpring
                )
                start.startVelocity = scene.frameVelocity(prev.id)
                matchedStarts[nid] = start
                matchedRootPaths.append(node.path)
                activeFlightIds.insert(nid)
                if pendingUnclippedFlights {
                    unclippedMatchedFlightIds.insert(nid)
                } else {
                    unclippedMatchedFlightIds.remove(nid)
                }
            }
        }
        if !matchedRootPaths.isEmpty {
            for i in 0..<specs.count {
                let p = pass.nodes[i].path
                if matchedRootPaths.contains(where: { p.hasPrefix($0 + "/") }) {
                    specs[i].transition = nil
                }
            }
        }
        committedMatchedByFlightId = newCommittedMatched
        var extraMatchedRemovedIds: [NodeId] = []
        if commitCut {
            seenMatchedByFlightId = newCommittedMatched
            for (fid, snap) in newCommittedMatched {
                matchedFlightRegistry.recordPrevious(flightId: fid, rect: snap.rect)
            }
            pendingLaunches.removeAll()
            pendingTextFlights.removeAll()
            pendingUnclippedFlights = false
            activeTextFlights.removeAll()
            launchedFlightIds.removeAll()
            launchScrollById.removeAll()
            unclippedMatchedFlightIds.removeAll()
        } else if reducedMotion || forceInitialSettle {
            pendingLaunches.removeAll()
            pendingTextFlights.removeAll()
            pendingUnclippedFlights = false
        } else {
            let scaledNow = cxSettings.scaledTime(at: now)
            if !pendingLaunches.isEmpty {
                let launches = pendingLaunches
                pendingLaunches.removeAll()
                var deferredLaunches: [PendingFlightRequest] = []
                for var req in launches {
                    guard let srcTextOriginRect = req.sourceTextRect ?? req.sourceRect else { continue }
                    guard let dstNode = findNodeForFlightSelector(req.destination, in: pass.nodes) else {
                        if req.remainingAttempts > 1 {
                            req.remainingAttempts -= 1
                            deferredLaunches.append(req)
                        }
                        continue
                    }
                    guard isFreshOrExiting(dstNode.nodeId) else { continue }
                    let firstTextOff = firstTextDescendantOffset(under: dstNode, in: pass.nodes)
                    // A launch captures the source in window coordinates. Its scene path
                    // is evaluated before the destination parent's still paint transform.
                    var source = Vec2(srcTextOriginRect.x, srcTextOriginRect.y)
                    var parent = dstNode.parentIndex
                    while let index = parent {
                        let ancestor = pass.nodes[index]
                        if presentedScales.motion(for: ancestor.nodeId) == .still,
                           let drawn = presentedRectByPath[ancestor.path],
                           let scale = presentedScales[ancestor.path], scale.x > 0, scale.y > 0,
                           let sceneRect = lastFrameOutput?.poseIndex[ancestor.nodeId]?.rect {
                            source = Vec2(sceneRect.x + (source.x - drawn.x) / scale.x,
                                          sceneRect.y + (source.y - drawn.y) / scale.y)
                            break
                        }
                        parent = ancestor.parentIndex
                    }
                    let startRect = MotionRect.fromXYWH(
                        source.x - firstTextOff.x,
                        source.y - firstTextOff.y,
                        dstNode.targetRect.width,
                        pass.naturalLaunchTargets[dstNode.nodeId]?.height ?? dstNode.targetRect.height
                    )
                    if let supersededId = matchedStarts[dstNode.nodeId]?.fromId,
                       supersededId != req.sourceNodeId,
                       !pass.nodes.contains(where: { $0.nodeId == supersededId }) {
                        extraMatchedRemovedIds.append(supersededId)
                    }
                    matchedStarts[dstNode.nodeId] = MatchedFlightStart(
                        fromId: req.sourceNodeId ?? dstNode.nodeId,
                        startRect: startRect,
                        startCorners: dstNode.el.corners,
                        startFill: dstNode.el.background.motionColor,
                        startOpacity: 1.0,
                        spring: req.motionSpring ?? dstNode.el.flightSpring ?? MotionTokens.REFLOW
                    )
                    let p = dstNode.path
                    for i in 0..<specs.count where pass.nodes[i].path.hasPrefix(p + "/") {
                        specs[i].transition = nil
                    }
                    activeFlightIds.insert(dstNode.nodeId)
                    launchedFlightIds.insert(dstNode.nodeId)
                    launchScrollById[dstNode.nodeId] = LaunchScroll(launchTakeoffScroll(for: dstNode, in: pass.nodes))
                }
                if !deferredLaunches.isEmpty {
                    pendingLaunches.append(contentsOf: deferredLaunches)
                }
            }
            if !pendingTextFlights.isEmpty {
                let flights = pendingTextFlights
                pendingTextFlights.removeAll()
                var deferredFlights: [PendingFlightRequest] = []
                for var req in flights {
                    let sourceText = req.sourceLayout?.authText ?? req.sourceText ?? ""
                    guard !sourceText.isEmpty || req.sourceSpans?.contains(where: { !$0.text.isEmpty }) == true else { continue }
                    guard let srcRect = req.sourceTextRect ?? req.sourceRect,
                          srcRect.width > 0, srcRect.height > 0,
                          let srcClip = req.sourceClip, srcClip.width > 0, srcClip.height > 0 else { continue }
                    guard let dstNode = findNodeForFlightSelector(req.destination, in: pass.nodes) else {
                        if req.remainingAttempts > 1 {
                            req.remainingAttempts -= 1
                            deferredFlights.append(req)
                        }
                        continue
                    }
                    if dstNode.el.isSecure || (dstNode.el.handlers.editLens?.get(state).isSecure == true) {
                        continue
                    }
                    if let srcId = req.sourceNodeId,
                       let srcSnap = pass.node(srcId) ?? exitingSnapshots[srcId],
                       (srcSnap.el.isSecure || (srcSnap.el.handlers.editLens?.get(state).isSecure == true)) {
                        continue
                    }
                    let dstExtent = laidOutTextExtent(for: dstNode, rect: dstNode.targetRect, in: pass.nodes)
                    var tf = TextFlightState(
                        sourceKey: req.source,
                        targetKey: req.destination,
                        source: srcRect,
                        born: scaledNow,
                        unclipped: true,
                        spring: req.motionSpring
                    )
                    _ = tf.measure(target: dstExtent, now: scaledNow, reducedMotion: reducedMotion)
                    activeTextFlights.removeAll { $0.targetNodeId == dstNode.nodeId }
                    activeTextFlights.append(ActiveTextFlight(
                        targetNodeId: dstNode.nodeId,
                        state: tf,
                        sourceLayout: req.sourceLayout,
                        sourceClip: srcClip,
                        sourceText: req.sourceText,
                        sourceSpans: req.sourceSpans,
                        sourceTextStyle: req.sourceTextStyle ?? dstNode.el.textStyle,
                        sourceTextColor: req.sourceTextColor
                    ))
                }
                if !deferredFlights.isEmpty {
                    pendingTextFlights.append(contentsOf: deferredFlights)
                }
            }
            pendingUnclippedFlights = false
        }

        checkFocusAndRevealSelected()
        let preScrollOffsets = scrollOffsets
        processScrollRequestsAndCallbacks(
            at: now,
            cut: commitCut,
            followEdge: commitFollowEdge,
            snaps: commitKind.snaps
        )
        if selectionState.pendingFollowCaret {
            selectionState.pendingFollowCaret = false
            followCaretIfNeeded()
        }
        var changedScrollDeltas: [String: Vec2] = [:]
        for (sPath, newOff) in scrollOffsets {
            let oldOff = preScrollOffsets[sPath] ?? .zero
            if abs(newOff.x - oldOff.x) > 1e-4 || abs(newOff.y - oldOff.y) > 1e-4 {
                changedScrollDeltas[sPath] = Vec2(newOff.x - oldOff.x, newOff.y - oldOff.y)
            }
        }
        if !changedScrollDeltas.isEmpty {
            shiftFlatAndSpecsForScrollDeltas(changedScrollDeltas, specs: &specs)
        }
        for open in pass.foldOpens {
            guard let j = pass.byPath[open.foldPrefix] else { continue }
            var end = j + 1
            while end < pass.nodes.count, let p = pass.nodes[end].parentIndex, p >= j {
                end += 1
            }
            scrollRequestsState.stepFoldOpens(viewport: open.viewport, end: end) { candidatePath in
                pass.byPath[candidatePath]
            }
            if !open.pinned,
               end < pass.nodes.count,
               pass.nodes[end].path == open.viewport || pass.nodes[end].path.hasPrefix(open.viewport + "/") {
                let below = pass.nodes[end]
                if let belowDrawn = presentedRectByPath[below.path] ?? flatNodes.first(where: { $0.nodeId == below.nodeId })?.targetRect,
                   let vpDrawn = presentedRectByPath[open.viewport] ?? flatNodes.first(where: { $0.path == open.viewport })?.targetRect {
                    scrollRequestsState.arriveFoldAnchor(ScrollKeep(
                        path: below.path,
                        viewport: open.viewport,
                        was: belowDrawn.top - vpDrawn.top,
                        virtualRow: nil,
                        hold: nil
                    ))
                }
            }
        }
        let keepDeltas = applyKeepCompensation(at: now, cut: commitCut, specs: &specs)
        directScrolledPaths.removeAll(keepingCapacity: true)
        if !keepDeltas.isEmpty {
            for (kPath, kd) in keepDeltas {
                let prev = changedScrollDeltas[kPath] ?? .zero
                changedScrollDeltas[kPath] = Vec2(prev.x + kd.x, prev.y + kd.y)
            }
        }
        let keepsFlights = !activeResizeSnap && commitKind.snaps && !commitKind.lands && viewCommitCount > 1 && !cut && !reducedMotion
        scene.keepFlights(keepsFlights)
        let unseenOmittedToUnmount = applyUnseenPresenceBeforeCommit(
            prevNodes: prevFlatNodesSnapshot,
            previousIndexById: previousIndexById,
            specs: &specs,
            cut: commitCut,
            on: &scene,
            activeFlightIds: activeFlightIds.subtracting(extraMatchedRemovedIds)
        )
        if !extraMatchedRemovedIds.isEmpty {
            let extraSet = Set(extraMatchedRemovedIds)
            let filteredOverrides = childExitOverrides.filter { !extraSet.contains($0.childId) }
            applyChildExitHooks(filteredOverrides, matchedStarts: matchedStarts, to: &scene)
            for extraId in extraMatchedRemovedIds {
                scene.unmount(extraId)
            }
            activeFlightIds.subtract(extraSet)
            launchedFlightIds.subtract(extraSet)
            for id in extraSet { launchScrollById.removeValue(forKey: id) }
            unclippedMatchedFlightIds.subtract(extraSet)
        } else {
            applyChildExitHooks(childExitOverrides, matchedStarts: matchedStarts, to: &scene)
        }
        let reorderedSlides = prepareGrowthRowReorderSlides(
            specs: &specs,
            colorSpring: commitColorSpring,
            nodes: pass.nodes,
            instant: commitKind.snaps,
            lands: commitKind.lands,
            relayout: activeResizeSnap,
            commitCut: commitCut,
            concealing: !concealedSecureIndices.isEmpty,
            ancestorInstants: pass.ancestorInstants,
            naturalTargets: pass.naturalJoinedRowTargets
        )
        let rideTrailing = layoutObservers.rideTrailing
        for id in sceneRideTrailingIds where pass.indexById[id] != nil && !rideTrailing.contains(id) {
            scene.setRideTrailing(id, false)
        }
        for id in rideTrailing { scene.setRideTrailing(id, true) }
        var pendingBorderBottoms: [(id: NodeId, seed: MotionColor?, target: MotionColor, spring: Spring?)] = []
        var pendingRadialStops: [(id: NodeId, index: Int, target: MotionColor, spring: Spring?)] = []
        var pendingTextColors: [(id: NodeId, seed: MotionColor?, target: MotionColor, spring: Spring?)] = []
        var pendingShadowColors: [(id: NodeId, index: Int, seed: MotionColor?, target: MotionColor, spring: Spring?)] = []
        let commitDefaultViewFg = cxSettings.viewDefaults.textForeground
        let mayHaveTextTracks = scene.store.hasTracks(for: Props.TEXT_COLOR)
        let mayHaveBottomTracks = scene.store.hasTracks(for: Props.BORDER_BOTTOM)
        let needsExistingTracks = mayHaveTextTracks || mayHaveBottomTracks
        var rangeIndex = 0
        var effectIndex = 0
        var colorIndex = 0
        let colorCount = min(specs.count, pass.nodes.count)
        while colorIndex < colorCount {
            let i = colorIndex
            colorIndex += 1
            if !needsExistingTracks {
                while effectIndex < layoutObservers.extraCommitColors.count, layoutObservers.extraCommitColors[effectIndex] < i {
                    effectIndex += 1
                }
                let nextEffect = effectIndex < layoutObservers.extraCommitColors.count
                    ? layoutObservers.extraCommitColors[effectIndex] : colorCount
                if i < nextEffect {
                    while rangeIndex < pass.reusedFlatRanges.count, pass.reusedFlatRanges[rangeIndex].current.upperBound <= i {
                        rangeIndex += 1
                    }
                    // Replayed immutable descendants have the same authored ink. Gradients,
                    // shadows and existing tracks still receive their ordinary reconciliation.
                    if rangeIndex < pass.reusedFlatRanges.count, pass.reusedFlatRanges[rangeIndex].current.contains(i) {
                        colorIndex = min(nextEffect, pass.reusedFlatRanges[rangeIndex].current.upperBound)
                        continue
                    }
                    if previousIndexById[pass.nodes[i].nodeId] == nil { continue }
                }
            }
            let node = pass.nodes[i]
            let nid = node.nodeId
            let wasPresent = scene.contains(nid)
            let csp = !commitCut && !reducedMotion && wasPresent ? specs[i].colorSpring : nil
            let prevIndex = previousIndexById[nid]
            let hasTextOrIcon = node.el.textColor != nil
                || node.el.richSpans != nil
                || node.el.plainText != nil
                || node.el.liveText != nil
                || node.el.hasEditLens
                || node.el.iconPayload != nil
            if hasTextOrIcon {
                let targetTextCol = (node.el.textColor ?? commitDefaultViewFg).motionColor
                let hadTextTrack = mayHaveTextTracks && scene.store.has(nid, Props.TEXT_COLOR)
                if (hadTextTrack || csp != nil), let prevIndex {
                    let prevEl = prevFlatNodesSnapshot[prevIndex].el
                    let hadText = prevEl.textColor != nil || prevEl.richSpans != nil || prevEl.plainText != nil
                        || prevEl.liveText != nil || prevEl.hasEditLens || prevEl.iconPayload != nil
                    if hadText {
                        let prevTextCol = (prevEl.textColor ?? commitDefaultViewFg).motionColor
                        if hadTextTrack || targetTextCol != prevTextCol {
                            let seed: MotionColor? = (!hadTextTrack && wasPresent) ? prevTextCol : nil
                            pendingTextColors.append((id: nid, seed: seed, target: targetTextCol, spring: csp))
                        }
                    } else if hadTextTrack {
                        pendingTextColors.append((id: nid, seed: nil, target: targetTextCol, spring: csp))
                    }
                } else if hadTextTrack {
                    pendingTextColors.append((id: nid, seed: nil, target: targetTextCol, spring: csp))
                }
            }
            for (si, sh) in node.el.shadows.prefix(shadowColorProps.count).enumerated() {
                let prop = shadowColorProps[si]
                let hadShTrack = scene.store.has(nid, prop)
                let prevShCol: MotionColor? = prevIndex.flatMap { index in
                    let previous = prevFlatNodesSnapshot[index].el.shadows
                    return si < previous.count ? previous[si].color.motionColor : nil
                }
                let targetShCol = sh.color.motionColor
                if hadShTrack || (csp != nil && prevShCol != nil && targetShCol != prevShCol!) {
                    let seed: MotionColor? = (!hadShTrack && wasPresent) ? prevShCol : nil
                    pendingShadowColors.append((id: nid, index: si, seed: seed, target: targetShCol, spring: csp))
                }
            }
            if let rGrad = node.el.runtimeExtra(RenderExtrasKey.radialGradient) as? RenderRadialGradientSpec {
                for (si, stop) in rGrad.stops.prefix(16).enumerated() {
                    pendingRadialStops.append((id: nid, index: si, target: stop.color.motionColor, spring: csp))
                }
            }
            let bGrad = node.el.runtimeExtra(RenderExtrasKey.borderGradient) as? RenderBorderGradientSpec
            let bw = bGrad?.width ?? node.el.borderWidth
            guard bw > 0 else { continue }
            let hadBottom = mayHaveBottomTracks && scene.store.has(nid, Props.BORDER_BOTTOM)
            guard bGrad != nil || hadBottom else { continue }
            let seed: MotionColor? = (bGrad != nil && !hadBottom && wasPresent)
                ? (scene.get(nid, Props.BORDER) ?? prevIndex.map { prevFlatNodesSnapshot[$0].el.borderColor.motionColor } ?? node.el.borderColor.motionColor)
                : nil
            let target = (bGrad?.bottom ?? node.el.borderColor).motionColor
            pendingBorderBottoms.append((id: nid, seed: seed, target: target, spring: csp))
        }
        if !commitCut && !commitKind.snaps && !reducedMotion {
            var previouslyDrawn: Set<NodeId>?
            for i in layoutObservers.heldLandingWidths {
                let n = pass.nodes[i]
                guard scene.hasNode(n.nodeId),
                      let drawn = scene.get(n.nodeId, Props.FRAME) else { continue }
                let was = scene.store.target(n.nodeId, Props.FRAME) ?? drawn
                guard abs(was.width - n.localRect.width) >= 0.5 else { continue }
                var end = i + 1
                while end < pass.nodes.count {
                    let pIdx = pass.nodes[end].parentIndex ?? -1
                    if pIdx < i { break }
                    end += 1
                }
                if previouslyDrawn == nil {
                    previouslyDrawn = previouslyDrawnLandingSubtrees(prevFlatNodesSnapshot)
                }
                var anchorIdx: Int?
                for c in (i + 1)..<end where pass.nodes[c].parentIndex == i {
                    let cId = pass.nodes[c].nodeId
                    guard scene.hasNode(cId), !scene.isExiting(cId) else { continue }
                    if previouslyDrawn?.contains(cId) == true {
                        anchorIdx = c
                        break
                    }
                    if anchorIdx == nil { anchorIdx = c }
                }
                let jump = anchorIdx.flatMap { c in
                    scene.get(pass.nodes[c].nodeId, Props.FRAME).map { $0.x - pass.nodes[c].localRect.x }
                } ?? 0.0
                let layoutSpringX: Spring? = if case .spring(let sp) = specs[i].layoutAnim?.x.curve { sp } else { nil }
                let glideSp = layoutSpringX ?? specs[i].styleSpring ?? commitMotion?.spring ?? MotionTokens.SETTLE
                for j in i..<end {
                    specs[j].layoutAnim = .instant
                    if !slice2State.joinedRowSeams.isEmpty, pass.nodes[j].el.growthSpec != nil {
                        slice2State.joinedRowSeams.removeValue(forKey: pass.nodes[j].nodeId)
                    }
                }
                scene.set(n.nodeId, Props.OFFSET, Vec2((drawn.x - n.localRect.x) + jump, specs[i].offset.y))
                frameLandingHoldIds.insert(n.nodeId)
                if specs[i].offsetAnim == nil && specs[i].styleSpring == nil {
                    specs[i].styleSpring = glideSp
                }
            }
        }
        let preGroupSnapshot = capturePreCommitGroupSnapshot()
        if !commitCut && !commitKind.snaps && !commitKind.lands && !reducedMotion {
            seedVirtualRowLayoutOffsets(nodes: pass.nodes, specs: &specs)
        }
        // An opted-in poll is delivered before this frame ticks its scene, just as
        // the growth track already steps from the prior drawn frame to this one.
        let eventTime = cxSettings.scaledTime(at: now)
        let scaledCommitNow = slice2State.liveTailWindows.isEmpty ? eventTime : min(lastScaledAnimNow, eventTime)
        prevRevealedSecureIds = nowRevealedSecureIds
        var concealSnapIndices: Set<Int> = []
        if !concealedSecureIndices.isEmpty {
            var scrollSnapRoots: Set<Int> = []
            for cIdx in concealedSecureIndices {
                var walk: Int? = cIdx
                while let cur = walk {
                    concealSnapIndices.insert(cur)
                    if !pass.nodes[cur].el.layout.scrollAxes.isEmpty {
                        scrollSnapRoots.insert(cur)
                    }
                    walk = pass.nodes[cur].parentIndex
                }
            }
            for i in pass.nodes.indices {
                if let p = pass.nodes[i].parentIndex, concealSnapIndices.contains(p) || scrollSnapRoots.contains(p) {
                    concealSnapIndices.insert(i)
                }
            }
            for j in concealSnapIndices {
                if j < specs.count {
                    specs[j].layoutAnim = nil
                    specs[j].transition = nil
                }
                let node = pass.nodes[j]
                if !node.el.layout.scrollAxes.isEmpty {
                    let cur = scrollOffsets[node.path] ?? .zero
                    scrollStore.snap(NodeId.hash("scroll:" + node.path), Props.SCROLL, to: cur)
                }
            }
        }
        if !launchScrollById.isEmpty {
            // Decide against the previous layout before this commit moves the destination.
            let near = 0.25 / max(pixelScale, 1)
            let readyToLand = launchedFlightIds.filter { id in
                guard let lead = scene.pathLead(id) else { return false }
                let position = lead[0], speed = lead[1]
                return max(abs(position.x), abs(position.y)) <= near
                    && max(abs(speed.x), abs(speed.y)) / 60 <= near
            }
            scene.setTime(scaledCommitNow)
            let slidingRows = Set(reorderedSlides.map(\.id))
            for id in launchedFlightIds {
                guard let node = pass.node(id), let target = pass.naturalLaunchTargets[id],
                      var launch = launchScrollById[id] else { continue }
                let i = node.index
                let was = launch.layoutTarget
                var ancestorSlid = false
                var parent = node.parentIndex
                while let p = parent {
                    let ancestor = pass.nodes[p]
                    if let origin = pass.naturalLaunchTargets[ancestor.nodeId]?.origin {
                        if let old = launch.ancestorOrigins[ancestor.nodeId], let anim = specs[p].layoutAnim,
                           (anim.x != .instant && origin.x != old.x) || (anim.y != .instant && origin.y != old.y) {
                            ancestorSlid = true
                        }
                        launch.ancestorOrigins[ancestor.nodeId] = origin
                    }
                    if slidingRows.contains(ancestor.nodeId) { ancestorSlid = true }
                    parent = ancestor.parentIndex
                }
                launch.layoutTarget = target
                launchScrollById[id] = launch
                let instantLayout = commitKind.snaps || node.el.hasInstantChanges || pass.ancestorInstants[i]
                let retainsFlight = !instantLayout || (keepsFlights && was == target && !node.el.hasInstantChanges)
                if !commitCut && !commitKind.lands && !reducedMotion && !concealSnapIndices.contains(i) &&
                    (matchedStarts[id] != nil || retainsFlight) {
                    let reaim = was != nil && matchedStarts[id] == nil && (was != target || ancestorSlid)
                    if reaim && readyToLand.contains(id) {
                        scene.landPath(id)
                        activeFlightIds.remove(id)
                        launchedFlightIds.remove(id)
                        launchScrollById.removeValue(forKey: id)
                        continue
                    }
                    // Growth reveals the natural box at paint time. Its mask must not resize the spring.
                    specs[i].rect.bottom = specs[i].rect.top + target.height
                    if reaim {
                        foldLaunchScroll(id)
                        let spring = node.el.styleSpring ?? specs[i].styleSpring ?? MotionTokens.DEFAULT
                        let layout = specs[i].layoutAnim ?? LayoutAnim(spring: spring)
                        specs[i].layoutAnim = layout.x == .instant || layout.y == .instant
                            ? LayoutAnim(spring: spring, travel: .screen) : layout.screen()
                        specs[i].launchLayout = .reaim
                    } else {
                        specs[i].launchLayout = .projectEndpoint
                    }
                }
            }
        }
        // Retained scroll placement starts from the geometry actually submitted to the scene.
        if pass.isVirtualRemount {
            swap(&lastCommittedSpecs, &spareMotionSpecs)
        }
        lastCommittedSpecs = specs
        spareMotionSpecs.removeAll(keepingCapacity: spareMotionSpecs.capacity / 2 <= specs.count)
        measureRuntimePhase(.apply) {
            scene.commit(
                specs,
                at: scaledCommitNow,
                initialCut: commitCut,
                snapMounts: commitKind.snaps,
                snapOmittedNonExiting: activeExplicitSnap,
                matchedStarts: matchedStarts,
                unmountNewOmissions: activeExplicitSnap || commitCut,
                animatedExitParents: slice2State.liveTailExitParents,
                landWaitingNodes: commitKind.lands,
                snapNewMounts: commitKind.snaps || commitCut,
                retainingUnchanged: pass.isVirtualRemount
            )
        }
        syncMotionLoops(specs: pass.loopSpecs, at: now, cut: activeSettleLoops)
        setGroupRestAfterCommit(
            nodes: pass.nodes,
            preState: preGroupSnapshot,
            cut: commitCut,
            snaps: commitKind.snaps,
            specs: specs,
            ancestorInstants: pass.ancestorInstants
        )
        if layoutObservers.hasShadows || !shadowTrackCounts.isEmpty {
            syncShadowTracks(
                nodes: pass.nodes,
                prevNodes: prevFlatNodesSnapshot,
                specs: specs,
                at: scaledCommitNow,
                cut: commitCut,
                lands: commitKind.lands,
                prevMountedIds: prevMountedIds
            )
        }
        rebuildLiveSubscriptionsIncludingExiting()
        if !concealSnapIndices.isEmpty {
            for j in concealSnapIndices where j < pass.nodes.count {
                pixelSnapGlides.remove(id: pass.nodes[j].nodeId)
            }
        }
        // A reused node keeps its live-binding latches, which a landing commit drops so live tracks snap (`726ccc36`).
        if commitKind.lands || commitCut {
            for i in layoutObservers.liveSources {
                let n = pass.nodes[i]
                for b in n.el.liveBindings {
                    liveSeenSeq.removeValue(forKey: LiveKey(path: n.path, target: b.target))
                }
            }
        }
        if scene.isTracing {
            var resolvedNS = [(String, String)?](repeating: nil, count: pass.nodes.count)
            for i in pass.nodes.indices {
                let n = pass.nodes[i]
                let ns = n.el.traceNamespaceValue ?? n.parentIndex.flatMap { resolvedNS[$0] }
                resolvedNS[i] = ns
                scene.traceName(n.nodeId, n.el.traceNameValue ?? n.key)
                scene.traceNamespace(n.nodeId, ns)
            }
        }
        let nodeTimeScales: [Float]
        if layoutObservers.hasTimeScales || !timeScaledNodeIds.isEmpty {
            nodeTimeScales = ShellSliceRenderHelpers.propagateTimeScales(
                nodes: pass.nodes,
                exitingSnapshots: exitingSnapshots,
                scene: &scene,
                trackedIds: &timeScaledNodeIds,
                wordRevealStore: &wordRevealStore,
                loopTracks: &loopRuntime.tracks
            )
        } else {
            nodeTimeScales = []
        }
        let commitScaledNow = cxSettings.scaledTime(at: now)
        let revealEntries: [WordRevealCommitEntry] = layoutObservers.wordReveals.compactMap { i in
            let n = pass.nodes[i]
            guard let fade = n.el.elRevealWordFade, fade >= 0 else { return nil }
            let txt = n.el.liveText?.get()
                ?? n.el.plainText
                ?? n.el.richSpans?.map(\.text).joined()
                ?? ""
            let nodeScale = i < nodeTimeScales.count ? nodeTimeScales[i] : 1.0
            let isScaled = nodeScale != 1.0
            let t = isScaled ? scene.store.nodeTime(n.nodeId) : commitScaledNow
            return WordRevealCommitEntry(
                id: n.nodeId,
                parentId: n.parentIndex.map { pass.nodes[$0].nodeId },
                text: txt,
                fade: fade,
                nodeTime: t,
                timeScaled: isScaled
            )
        }
        if !revealEntries.isEmpty || !wordRevealStore.phases.isEmpty {
            let presentIds = Set(pass.nodes.map(\.nodeId))
            let exitingIds: Set<NodeId> = (commitCut || commitKind.snaps) ? [] : Set(exitingSnapshots.keys)
            let retainIds = presentIds.union(exitingIds)
            wordRevealStore.commit(
                entries: revealEntries,
                presentIds: presentIds,
                retainIds: retainIds,
                prevMountedIds: prevMountedIds,
                cut: commitCut,
                instant: commitCut || commitKind.snaps,
                reducedMotion: reducedMotion
            )
            if wordRevealStore.hasActiveFades(timeScaleOf: { scene.store.nodeTimeScale($0) }) {
                isAnimating = true
            }
        }
        for item in pendingBorderBottoms {
            if let seed = item.seed {
                scene.set(item.id, Props.BORDER_BOTTOM, seed)
            }
            if let csp = item.spring {
                scene.animate(item.id, Props.BORDER_BOTTOM, to: item.target, anim: Anim(curve: Curve.from(csp)))
            } else {
                scene.set(item.id, Props.BORDER_BOTTOM, item.target)
            }
        }
        for rs in pendingRadialStops {
            let prop = radialStopProps[rs.index]
            if let csp = rs.spring {
                scene.animate(rs.id, prop, to: rs.target, anim: Anim(curve: Curve.from(csp)))
            } else {
                scene.set(rs.id, prop, rs.target)
            }
        }
        for item in pendingTextColors {
            if let seed = item.seed {
                scene.set(item.id, Props.TEXT_COLOR, seed)
            }
            if let csp = item.spring {
                scene.animate(item.id, Props.TEXT_COLOR, to: item.target, anim: Anim(curve: Curve.from(csp)))
            } else {
                scene.set(item.id, Props.TEXT_COLOR, item.target)
            }
        }
        for item in pendingShadowColors {
            let prop = shadowColorProps[item.index]
            if let seed = item.seed {
                scene.set(item.id, prop, seed)
            }
            if let csp = item.spring {
                scene.animate(item.id, prop, to: item.target, anim: Anim(curve: Curve.from(csp)))
            } else {
                scene.set(item.id, prop, item.target)
            }
        }
        unmountOmittedUnseenNodes(unseenOmittedToUnmount, on: &scene)
        syncClosingGrowthFrames(on: &scene)
        commitGrowthRowReorderSlides(reorderedSlides, at: cxSettings.scaledTime(at: now))
        scene.keepFlights(false)
        if applyUnseenPresenceAfterCommit(specs: specs, cut: commitCut, to: &scene) {
            isAnimating = true
        }
        // A measurement retry spends its overscan budget against the last applied window.
        for list in pass.virtualExpansion.listMeta {
            virtualLists[list.listPath]?.lastMountedSnapshot = list.mounted
        }
        updateVirtualVisibleRowsOnScroll()
        stepVirtualFillAfterCommit(now: now)
        if pass.virtualExpansion.anyVirtualList && !changedScrollDeltas.isEmpty && anyVirtualListNeedsWindow() {
            needsCommit = true
            commitWhyPending |= CommitWhy.virtual
        } else {
            virtualRevealLandings.removeAll(keepingCapacity: true)
        }
        finishScrollKeyLandings(anyVirtualList: pass.virtualExpansion.anyVirtualList)
        if !needsCommit && scrollGlidingPaths.isEmpty && scrollRequestsState.isEmpty {
            pendingTxFocusKey = nil
        }
        // Exiting slots keep their authored alignment until they disappear or re-enter.
        if !sceneRideTrailingIds.isEmpty {
            sceneRideTrailingIds = sceneRideTrailingIds.filter { pass.indexById[$0] == nil && scene.contains($0) }
        }
        for id in rideTrailing { scene.setRideTrailing(id, true) }
        sceneRideTrailingIds.formUnion(rideTrailing)
        finalizeSelectionAfterCommit(at: now)
        cxSettings.lastCommittedSelectionRects = computeSelectionBoxes()
        if fitHeight {
            let natH = max(1.0, ceil(pass.rootHeight * cxSettings.zoomState.k * pixelScale) / pixelScale)
            if fitWindowState.ask(height: natH, current: viewport.y) {
                let jump = cut || (viewCommitCount <= 1) || reducedMotion
                if !jump && windowResting {
                    fitWindowState.hold = .asked
                }
                let req = WindowFrameRequest(
                    size: (viewport.x, natH),
                    animate: !jump,
                    spring: jump ? nil : (lastCommitMotionSpring ?? MotionTokens.DEFAULT),
                    center: false
                )
                pendingWindowFrame = pendingWindowFrame?.merged(with: req) ?? req
            }
        }
        spareFlatNodes = []
        swap(&spareFlatNodes, &prevFlatNodesSnapshot)
        spareFlatNodes.removeAll(keepingCapacity: true)
        lastCommitMotionSpring = nil
    }

    @inline(never)
    private func seedVirtualRowLayoutOffsets(nodes: [FlatNode], specs: inout [NodeSpec]) {
        for i in nodes.indices where i < specs.count {
            let n = nodes[i]
            guard let pIdx = n.parentIndex, pIdx >= 0, pIdx < nodes.count else { continue }
            let parentEl = nodes[pIdx].el
            guard parentEl.virtualEstimate != nil,
                  parentEl.growthSpec == nil,
                  parentEl.foldGlideSpec == nil,
                  let explicitLayout = n.el.layoutAnim,
                  !n.el.hasInstantChanges,
                  let resolvedLa = specs[i].layoutAnim else { continue }
            if case .instant = resolvedLa.y.curve {} else { continue }
            if case .instant = explicitLayout.y.curve { continue }
            guard scene.hasNode(n.nodeId),
                  !scene.isExiting(n.nodeId),
                  let prevFrame = scene.get(n.nodeId, Props.FRAME) else { continue }
            let dy = prevFrame.y - n.localRect.y
            guard abs(dy) > 0.5 else { continue }
            let curOffset = scene.get(n.nodeId, Props.OFFSET) ?? .zero
            scene.set(n.nodeId, Props.OFFSET, Vec2(curOffset.x, curOffset.y + dy))
            if specs[i].offsetAnim == nil {
                specs[i].offsetAnim = Anim<Vec2>(
                    curve: explicitLayout.y.curve,
                    delay: explicitLayout.y.delay
                )
            }
        }
    }

    private func findNodeForFlightSelector(_ selector: String, in nodes: [FlatNode]) -> FlatNode? {
        nodes.first { FlightSelector.selects(selector, path: $0.path, key: $0.key) }
    }

    private func firstTextDescendantOffset(under root: FlatNode, in nodes: [FlatNode]) -> Vec2 {
        if root.el.plainText != nil || root.el.richSpans != nil {
            return Vec2(root.el.layout.padding.left, root.el.layout.padding.top)
        }
        let prefix = root.path + "/"
        if let desc = nodes.first(where: { $0.path.hasPrefix(prefix) && ($0.el.plainText != nil || $0.el.richSpans != nil) }) {
            return Vec2(
                (desc.targetRect.x + desc.el.layout.padding.left) - root.targetRect.x,
                (desc.targetRect.y + desc.el.layout.padding.top) - root.targetRect.y
            )
        }
        return .zero
    }

    /// A flight lands on the text as painted after this frame's scrolling and growth.
    internal func measureTextFlightDestinations(in drawnRects: FrameGeometry<MotionRect>, at now: Double) {
        for index in activeTextFlights.indices {
            guard let node = mountedNode(activeTextFlights[index].targetNodeId),
                  let rect = drawnRects[node.path] else { continue }
            let target = laidOutTextExtent(for: node, rect: rect)
            var flight = activeTextFlights[index].state
            flight.measure(target: target, now: now, reducedMotion: reducedMotion)
            // Land residual sizes before snapping both edges so translation cannot change a settled size.
            let scale = max(pixelScale, 0.5)
            let quantum = 1 / (64 * scale)
            var presented = flight.presented
            if abs(presented.width - target.width) < quantum {
                presented.right = presented.left + target.width
            }
            if abs(presented.height - target.height) < quantum {
                presented.bottom = presented.top + target.height
            }
            flight.presented = Snap.rect(presented, scale: scale)
            activeTextFlights[index].state = flight
        }
    }

    private func laidOutTextExtent(for node: FlatNode, rect: MotionRect, in nodes: [FlatNode]? = nil) -> MotionRect {
        let searchNodes = nodes ?? flatNodes
        let textNode: FlatNode
        let textBoxRect: MotionRect
        if node.el.plainText != nil || node.el.richSpans != nil {
            textNode = node
            textBoxRect = rect
        } else if let desc = searchNodes.first(where: {
            $0.path.hasPrefix(node.path + "/") && ($0.el.plainText != nil || $0.el.richSpans != nil)
        }) {
            textNode = desc
            textBoxRect = MotionRect.fromXYWH(
                rect.x + (desc.targetRect.x - node.targetRect.x),
                rect.y + (desc.targetRect.y - node.targetRect.y),
                desc.targetRect.width,
                desc.targetRect.height
            )
        } else {
            return rect
        }

        let padL = textNode.el.layout.padding.left
        let padT = textNode.el.layout.padding.top
        let padR = textNode.el.layout.padding.right
        let padB = textNode.el.layout.padding.bottom
        let innerW = max(0, textBoxRect.width - padL - padR)
        let innerH = max(0, textBoxRect.height - padT - padB)
        let shaped = textSystem.shape(
            text: textNode.el.plainText ?? "",
            spans: textNode.el.richSpans,
            style: textNode.el.textStyle,
            maxWidth: innerW > 0 ? innerW + 0.5 : nil,
            pixelScale: pixelScale,
            emitGlyphs: false
        )
        let extentW = innerW > 0 ? min(innerW, shaped.size.x) : shaped.size.x
        let extentH = innerH > 0 ? min(innerH, shaped.size.y) : shaped.size.y
        return MotionRect.fromXYWH(
            textBoxRect.x + padL,
            textBoxRect.y + padT,
            max(1, extentW),
            max(1, extentH)
        )
    }

    private func makePendingFlightRequest(source: String, destination: String, motionSpring: Spring? = nil) -> PendingFlightRequest {
        let srcNode = findNodeForFlightSelector(source, in: flatNodes)
        let srcLastEl = firstReportedElement(where: { !$0.exiting && FlightSelector.selects(source, path: $0.path, key: $0.key) })
        let srcRect = srcLastEl.map { MotionRect.fromXYWH($0.rect) }
            ?? srcNode.map { scene.currentRect($0.nodeId) ?? $0.targetRect }
        let sourceLayout = srcNode.flatMap { node -> TextLayoutBox? in
            guard !node.el.isSecure, srcLastEl?.secure != true,
                  node.el.handlers.editLens != nil else { return nil }
            return nodeTextLayouts[node.nodeId]?.box
        }
        let srcTextRect: MotionRect? = {
            if let srcNode, let srcRect {
                if let sourceLayout {
                    let pad = srcNode.el.layout.padding
                    let innerWidth = max(0, srcRect.width - pad.left - pad.right)
                    let innerHeight = max(0, srcRect.height - pad.top - pad.bottom)
                    let bounds = sourceLayout.shaped.lineExtent(scale: sourceLayout.pixelScale)
                    let scroll = inputScroll[srcNode.path] ?? 0
                    return MotionRect.fromXYWH(
                        srcRect.x + pad.left + bounds.lowerBound - scroll, srcRect.y + pad.top,
                        max(0, min(innerWidth - bounds.lowerBound, bounds.upperBound - bounds.lowerBound)),
                        min(innerHeight, sourceLayout.shaped.size.y)
                    )
                }
                return laidOutTextExtent(for: srcNode, rect: srcRect, in: flatNodes)
            }
            return srcRect
        }()
        return PendingFlightRequest(
            source: source,
            destination: destination,
            sourceNodeId: srcNode?.nodeId,
            sourceRect: srcRect,
            sourceTextRect: srcTextRect,
            sourceLayout: sourceLayout,
            sourceClip: srcTextRect.map { extent in
                let clip = srcLastEl.map { MotionRect.fromXYWH($0.visible) } ?? srcNode?.clipRect ?? extent
                return intersectRects(intersectRects(extent, clip), MotionRect.fromXYWH(0, 0, viewport.x, viewport.y))
            },
            sourceCorners: srcNode?.el.corners,
            sourceFill: srcNode?.el.background.motionColor,
            sourceText: srcNode?.el.plainText ?? srcLastEl?.text,
            sourceSpans: srcNode?.el.richSpans,
            sourceTextStyle: srcNode?.el.textStyle,
            sourceTextColor: srcNode?.el.textColor ?? srcLastEl?.textColor,
            motionSpring: motionSpring
        )
    }

    internal func nodeTakesFocus(_ el: El<State>) -> Bool {
        nodeTakesFocus(el, webFocus: cxSettings.viewDefaults.webFocus)
    }

    internal func nodeTakesFocus(_ el: El<State>, webFocus: Bool) -> Bool {
        if el.a11yDisabled { return false }
        if el.focusable { return true }
        let pressableRoles: Set<ElementRole> = [
            .button, .tab, .checkbox, .switchControl, .radio, .menuItem, .listItem,
        ]
        return webFocus &&
            !el.focusOptOut &&
            (el.handlers.onClick != nil || el.handlers.onClickPress != nil || el.handlers.onPointerDown != nil) &&
            pressableRoles.contains(el.role)
    }

    internal func updateScrollPositions(at now: Double) {
        guard !flatNodes.isEmpty else { return }
        let fullWindowClip = MotionRect.fromXYWH(0, 0, viewport.x, viewport.y)
        var childClips = [MotionRect](repeating: fullWindowClip, count: flatNodes.count)
        var childClipFades = [[EdgeFadeSpec]](repeating: [], count: flatNodes.count)
        var shifts: [(sticky: Vec2, world: Vec2)] = []
        shifts.reserveCapacity(flatNodes.count)

        for i in flatNodes.indices {
            let parentIdx = flatNodes[i].parentIndex
            let parentOrigin: Vec2
            let parentScroll: Vec2
            let inheritedClip: MotionRect
            let inheritedClipFades: [EdgeFadeSpec]
            if let p = parentIdx {
                parentOrigin = flatNodes[p].targetRect.origin
                parentScroll = flatNodes[p].scrollShift
                inheritedClip = childClips[p]
                inheritedClipFades = childClipFades[p]
            } else {
                parentOrigin = .zero
                parentScroll = .zero
                inheritedClip = fullWindowClip
                inheritedClipFades = []
            }

            let lr = flatNodes[i].localRect
            var worldX = parentOrigin.x + lr.x - parentScroll.x
            var worldY = parentOrigin.y + lr.y - parentScroll.y + flatNodes[i].growthContentShiftY
            if let a = flatNodes[i].el.anchor,
               let anchorFlat = flatNodes.first(where: { $0.key == a.key }) {
                let aSticky = anchorFlat.index < shifts.count ? shifts[anchorFlat.index].sticky : .zero
                let aParentScale = anchorFlat.parentIndex.map { flatNodes[$0].inheritedScale } ?? 1.0
                let triggerZoomed = (aSticky == .zero)
                    ? anchorFlat.zoomedTargetRect
                    : anchorFlat.zoomedTargetRect.offsetBy(Vec2(aSticky.x * aParentScale, aSticky.y * aParentScale))
                let placement = AnchorLayoutHelper.zoomedPlacement(
                    anchor: a,
                    triggerZoomed: triggerZoomed,
                    anchorScale: aParentScale,
                    localSize: flatNodes[i].localSize,
                    overlayOwnScale: flatNodes[i].el.scale,
                    hasScaleTrack: anchoredOverlayHasScaleTrack(flatNodes[i].el, nodeId: flatNodes[i].nodeId),
                    viewport: viewport
                )
                worldX = placement.unscaledOrigin.x
                worldY = placement.unscaledOrigin.y
            }
            if parentIdx == nil, let page = documentPage {
                worldY -= page.top
            }
            let oldTarget = flatNodes[i].targetRect
            let newTarget = MotionRect.fromXYWH(worldX, worldY, flatNodes[i].localSize.x, flatNodes[i].localSize.y)
            flatNodes[i].targetRect = newTarget
            let parentScale = parentIdx.map { flatNodes[$0].inheritedScale } ?? 1.0
            let worldDelta = Vec2(newTarget.x - oldTarget.x, newTarget.y - oldTarget.y)
            let zoomedDelta = Vec2(worldDelta.x * parentScale, worldDelta.y * parentScale)
            if zoomedDelta != .zero {
                flatNodes[i].zoomedTargetRect = flatNodes[i].zoomedTargetRect.offsetBy(zoomedDelta)
            }
            let parentScrollSticky: Vec2 = (flatNodes[i].el.anchor != nil && !flatNodes[i].isSticky)
                ? .zero
                : (parentIdx.map { shifts[$0].sticky } ?? .zero)
            let myScrollSticky = computeStickyShift(
                nodeIndex: i,
                parentStickyShift: parentScrollSticky,
                nodes: flatNodes,
                rectOf: { $0.targetRect }
            ).shift
            shifts.append((sticky: myScrollSticky, world: worldDelta))
            flatNodes[i].clipRect = inheritedClip
            flatNodes[i].activeClipFades = inheritedClipFades
            var scrollFadeInfo: EdgeFadeSpec? = nil
            if !flatNodes[i].el.layout.scrollAxes.isEmpty {
                let path = flatNodes[i].path
                let maxExt = scrollMaxExtents[path] ?? .zero
                let rawScroll = scrollOffsets[path] ?? .zero
                let clampedX = isTouchOwning(path: path, horizontal: true) ? rawScroll.x : rawScroll.x.clamped(to: 0...maxExt.x)
                let clampedY = isTouchOwning(path: path, horizontal: false) ? rawScroll.y : rawScroll.y.clamped(to: 0...maxExt.y)
                let clamped = Vec2(clampedX, clampedY)
                scrollOffsets[path] = clamped
                flatNodes[i].scrollShift = Vec2(flatNodes[i].flow == .rtl ? -clamped.x : clamped.x, clamped.y)
                dispatchScrollOffsetObserverIfChanged(for: flatNodes[i], at: cxSettings.scaledTime(at: now), instant: false)
                if flatNodes[i].el.scrollEdgeFadeWidth > 0 || flatNodes[i].el.scrollFadeStyle.end != nil {
                    scrollFadeInfo = computeScrollFadeSpec(for: flatNodes[i])
                }
            } else {
                flatNodes[i].scrollShift = .zero
            }
            flatNodes[i].ownScrollFade = scrollFadeInfo
            var nodeChildFades = inheritedClipFades
            if let sf = scrollFadeInfo {
                nodeChildFades.append(sf)
            }
            if let cf = flatNodes[i].el.clipFade {
                nodeChildFades.append(
                    EdgeFadeSpec(
                        rect: intersectRects(inheritedClip, newTarget),
                        widths: cf,
                        strengths: SIMD4<Float>(repeating: 1.0),
                        growthRow: flatNodes[i].el.growthReveal == nil ? nil : flatNodes[i].nodeId,
                        authoredFade: flatNodes[i].el.growthReveal?.authoredFade
                    )
                )
            }
            childClipFades[i] = nodeChildFades
            let el = flatNodes[i].el
            childClips[i] = (el.layout.clipOverflow || el.clipRadius != nil || el.clipCorners != nil || el.clipFade != nil)
                ? intersectRects(inheritedClip, newTarget)
                : inheritedClip
            let nid = flatNodes[i].nodeId
            let parentDelta = parentIdx.map { shifts[$0].world } ?? .zero
            let localDelta = Vec2(worldDelta.x - parentDelta.x, worldDelta.y - parentDelta.y)
            scene.translateFrame(nid, by: localDelta, screenDelta: worldDelta, carryTakeoff: !launchedFlightIds.contains(nid))

            if i < lastCommittedSpecs.count {
                lastCommittedSpecs[i].rect = newTarget
            }
        }
        dispatchScrollCallbacks(at: now)
        updateVirtualVisibleRowsOnScroll()
        directScrolledPaths.removeAll(keepingCapacity: true)
    }

    private func drainLayoutActions(at now: Double) -> (ranFeedback: Bool, ranExternal: Bool) {
        guard !pendingLayoutActions.isEmpty else { return (false, false) }
        let batch = pendingLayoutActions
        pendingLayoutActions.removeAll(keepingCapacity: true)
        var ranFeedback = false
        var ranExternal = false
        for action in batch {
            guard let idx = nodeByPath[action.nodePath], idx < flatNodes.count else { continue }
            let handlers = flatNodes[idx].el.handlers
            var tx = Tx()
            var dispatched = false
            switch action.kind {
            case .layout:
                if let cb = handlers.onLayout {
                    dispatchScoped(&tx) { s, t in cb(&s, action.rect, &t) }
                    dispatched = true
                }
            case .screenLayout:
                if let cb = handlers.onScreenLayout {
                    dispatchScoped(&tx) { s, t in cb(&s, action.rect, &t) }
                    dispatched = true
                }
            case .drawnLayout:
                if let cb = handlers.onDrawnLayout {
                    dispatchScoped(&tx) { s, t in cb(&s, action.rect, &t) }
                    dispatched = true
                }
            case .visibleRows:
                if let cb = handlers.onVisibleRows {
                    dispatchScoped(&tx) { s, _ in dispatched = cb(&s, action.rows) }
                    if dispatched { stateUnchangedSinceBuild = false }
                }
            case .visible:
                if let cb = handlers.onVisible {
                    dispatchScoped(&tx) { s, t in cb(&s, action.visible, &t) }
                    dispatched = true
                }
            }
            guard dispatched else { continue }
            let didRequestCommit = !tx.liveOnlyRequested
            applyTx(tx, at: now, markDirtyIfNotLiveOnly: true, external: action.external)
            if didRequestCommit {
                let handlerName: String
                switch action.kind {
                case .layout: handlerName = "on_layout"
                case .screenLayout: handlerName = "on_screen_layout"
                case .drawnLayout: handlerName = "on_drawn_layout"
                case .visible: handlerName = "on_visible"
                case .visibleRows: handlerName = "on_visible_rows"
                }
                perfWatch.meter.handler(name: handlerName, path: action.nodePath)
                if action.external {
                    ranExternal = true
                } else {
                    ranFeedback = true
                }
            }
        }
        return (ranFeedback, ranExternal)
    }

    private func dispatchScoped(_ tx: inout Tx, _ body: (inout State, inout Tx) -> Void) {
        if let scope = turnScope {
            scope(&state) { s in body(&s, &tx) }
        } else {
            body(&state, &tx)
        }
    }

    /// Coalesce scroll input before the commit, then queue any range changed by the new layout.
    private func reportVirtualVisibleRows() -> Bool {
        var queued = false
        for index in layoutObservers.visibleRows {
            let path = flatNodes[index].path
            guard !subtreeExiting(index), let list = virtualLists[path] else { continue }
            let (prefix, total) = list.computeOffsets(estimated: flatNodes[index].el.effectiveVirtualEstimate)
            let scroll = scrollOffsets[list.scrollPath]?.y ?? 0
            let pinned = wasPinnedToBottom.contains(list.scrollPath)
                && nodeByPath[list.scrollPath].map { flatNodes[$0].el.layout.stickBottom } == true
            let at = list.at(scroll, pinned: pinned, total: total)
            let range = list.visibleRange(offset: at.offset, viewport: list.viewport,
                                          prefix: prefix, count: list.lastKeys.count, pinned: at.pinned)
            guard list.reportedVisibleRange != range else { continue }
            virtualLists[path]?.reportedVisibleRange = range
            enqueueLayoutAction(PendingLayoutAction(kind: .visibleRows, nodePath: path,
                rect: [], visible: false, external: false, rows: range))
            queued = true
        }
        return queued
    }

    private func enqueueLayoutAction(_ action: PendingLayoutAction) {
        pendingLayoutActions.removeAll { $0.kind == action.kind && $0.nodePath == action.nodePath }
        pendingLayoutActions.append(action)
    }

    @discardableResult
    private func writeDrawnRects() -> Bool {
        var wrote = false
        for index in layoutObservers.drawnRect {
            let node = flatNodes[index]
            guard let updater = node.el.handlers.drawnRectUpdate,
                  let drawn = drawnRectByPath[node.path] else { continue }
            if updater(drawn) {
                wrote = true
            }
        }
        return wrote
    }

    @discardableResult
    private func reportLayoutAndScreen(reportLocal: Bool, reportScreen: Bool) -> Bool {
        let quiet = !layoutFeedback.isOpen
        var queued = false
        var nextLocal: [NodeId: [Float]] = reportLocal ? [:] : layoutFired
        var nextScreen: [NodeId: [Float]] = reportScreen ? [:] : screenFired

        for index in layoutObservers.laidOut {
            let node = flatNodes[index]
            let handlers = node.el.handlers
            if reportLocal, handlers.onLayout != nil {
                let rectArr = LayoutReadConstants.rectArray(node.targetRect)
                let prev = layoutFired[node.nodeId]
                if LayoutReadConstants.rectsMoved(prev, rectArr) {
                    nextLocal[node.nodeId] = rectArr
                    if !quiet {
                        enqueueLayoutAction(PendingLayoutAction(
                            kind: .layout,
                            nodePath: node.path,
                            rect: rectArr,
                            visible: false,
                            external: false
                        ))
                        queued = true
                    }
                } else if let prev {
                    nextLocal[node.nodeId] = prev
                }
            }
            if reportScreen, handlers.onScreenLayout != nil {
                let r = node.targetRect
                let k = cxSettings.zoomState.k
                let rectArr: [Float] = [
                    r.left * k + windowOrigin.x,
                    r.top * k + windowOrigin.y,
                    r.width * k,
                    r.height * k
                ]
                let prev = screenFired[node.nodeId]
                if LayoutReadConstants.rectsMoved(prev, rectArr) {
                    nextScreen[node.nodeId] = rectArr
                    if !quiet {
                        enqueueLayoutAction(PendingLayoutAction(
                            kind: .screenLayout,
                            nodePath: node.path,
                            rect: rectArr,
                            visible: false,
                            external: false
                        ))
                        queued = true
                    }
                } else if let prev {
                    nextScreen[node.nodeId] = prev
                }
            }
        }

        if reportLocal { layoutFired = nextLocal }
        if reportScreen { screenFired = nextScreen }
        return queued
    }

    @discardableResult
    private func reportDrawn() -> Bool {
        let quiet = !layoutFeedback.isOpen
        let last = drawnFired
        var next: [NodeId: (drawn: [Float], laid: [Float])] = [:]
        var queued = false

        for index in layoutObservers.drawn {
            let node = flatNodes[index]
            guard node.el.handlers.onDrawnLayout != nil,
                  let drawnRect = drawnRectByPath[node.path] else { continue }
            let nid = node.nodeId
            if rectSpringingById[nid] == true {
                if let old = last[nid] { next[nid] = old }
                continue
            }
            let drawn = LayoutReadConstants.rectArray(drawnRect)
            let old = last[nid]
            if let old, !LayoutReadConstants.rectsMoved(old.drawn, drawn) {
                next[nid] = old
                continue
            }
            // Rust's static_layout fingerprints authored rotation and pivot changes along
            // the ancestry to distinguish layout feedback from a live or scrolled move.
            var laid = node.staticRect
            var turn: Float = 0
            var ancestor: Int? = index
            while let i = ancestor {
                let element = flatNodes[i].el
                turn += element.rotate + (element.origin.x - 0.5) + (element.origin.y - 0.5)
                ancestor = flatNodes[i].parentIndex
            }
            laid[0] += turn
            laid[1] += turn
            let external = old.map { !LayoutReadConstants.rectsMoved($0.laid, laid) } ?? false
            if quiet && !external {
                next[nid] = (drawn, laid)
                continue
            }
            next[nid] = (drawn, laid)
            enqueueLayoutAction(PendingLayoutAction(
                kind: .drawnLayout,
                nodePath: node.path,
                rect: drawn,
                visible: false,
                external: external
            ))
            queued = true
        }
        drawnFired = next
        return queued
    }

    @discardableResult
    private func reportVisible() -> Bool {
        var next: [NodeId: Bool] = [:]
        var queued = false
        let window = pageWindow
        let viewSize = (viewport.x, window.height)
        for index in layoutObservers.visible {
            let node = flatNodes[index]
            guard let drawnRect = drawnRectByPath[node.path] else { continue }
            let nowVisible = VisibleGeometry.onScreen([drawnRect.x, drawnRect.y - window.start, drawnRect.width, drawnRect.height], view: viewSize)
            let prev = visibleFired[node.nodeId] ?? false
            next[node.nodeId] = nowVisible
            if nowVisible != prev {
                enqueueLayoutAction(PendingLayoutAction(
                    kind: .visible,
                    nodePath: node.path,
                    rect: [],
                    visible: nowVisible,
                    external: true
                ))
                queued = true
            }
        }
        visibleFired = next
        return queued
    }

    internal func canFocusIndex(_ idx: Int) -> Bool {
        guard idx >= 0 && idx < flatNodes.count else { return false }
        if playgroundLive?.pressing == true && !isNodeUnder(idx, predicate: Self.isPlaygroundStageKey) {
            return false
        }
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
                ?? members.first(where: { flatNodes[$0].el.itemSelected || flatNodes[$0].el.isFocusSelected })
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

    private func isOffscreenVirtualFocusedPath(_ fp: String) -> Bool {
        for vPath in activeVirtualPaths {
            guard fp.hasPrefix(vPath + "/"),
                  let vState = virtualLists[vPath] else { continue }
            if vState.rowPlaces.row(containing: fp, below: vPath) != nil {
                if let mPath = activeModalPath {
                    return vPath == mPath || vPath.hasPrefix(mPath + "/")
                }
                return true
            }
        }
        return false
    }

    private func reconcileFocusAfterCommit(
        prevFocusedPath: String?,
        prevFocusedKey: String?,
        prevFocusVisible: Bool,
        prevNodes: [FlatNode],
        prevByPath: [String: Int]
    ) {
        let txBlur = pendingTxBlurRequested
        let txFocusKey = pendingTxFocusKey
        let txFocusVisible = pendingTxFocusVisible ?? slice2State.pendingTxFocusVisible
        pendingTxBlurRequested = false
        pendingTxFocusKey = nil
        pendingTxFocusVisible = nil
        // `asked = focus_request.take().or(owed)`: a `Tx.focusWhenShown` asked now, or one owed.
        let whenShown = takeFocusWhenShown(otherAsk: txFocusKey != nil)
        slice2State.pendingTxFocusVisible = nil

        // Detect newly requested `.focused(true)` on non-inert mounted focusable nodes.
        var requestedFocusIdx: Int? = nil
        var nextSyncedRequests: Set<String> = []
        for i in layoutObservers.focusRequests {
            let path = flatNodes[i].path
            nextSyncedRequests.insert(path)
            if requestedFocusIdx == nil && !syncedEditFocusedPaths.contains(path) {
                requestedFocusIdx = i
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
        var openedModalThisCommit = false
        for i in layoutObservers.focusReturns {
            let node = flatNodes[i]
            if !focusReturnStack.contains(where: { $0.ownerPath == node.path }) {
                if node.el.isModal { openedModalThisCommit = true }
                let zeroSentinel = !node.el.isModal && node.el.focusReturnKey != nil && node.targetRect.width == 0 && node.targetRect.height == 0
                let scope = zeroSentinel ? (node.parentIndex.map { flatNodes[$0].path } ?? node.path) : node.path
                focusReturnStack.append(FocusReturnEntry(
                    ownerPath: node.path,
                    scopePath: scope,
                    isModal: node.el.isModal,
                    returnPath: node.el.focusReturnKey == nil ? prevFocusedPath : nil,
                    returnKey: node.el.focusReturnKey ?? prevFocusedKey,
                    prevFocusVisible: prevFocusVisible
                ))
            }
        }
        if txBlur {
            inputMachines.focusMachine.blurredFocusPath = nil
        }
        var openedModalHasMenuOrListbox = false
        if openedModalThisCommit, let mPath = activeModalPath, let mIdx = nodeByPath[mPath] {
            let mPrefix = flatNodes[mIdx].path + "/"
            let hasMenuOrListbox = flatNodes.contains { n in
                (n.path == flatNodes[mIdx].path || n.path.hasPrefix(mPrefix)) &&
                n.el.focusGroup &&
                (n.el.role == .menu || n.el.role == .listbox)
            }
            openedModalHasMenuOrListbox = hasMenuOrListbox
            if hasMenuOrListbox && inputMachines.focusMachine.lastPressedWasPointer {
                inputMachines.focusMachine.openedModalKind = .pointerMenu
                inputMachines.focusMachine.highlightHidden = true
            } else {
                inputMachines.focusMachine.openedModalKind = .dialog
                inputMachines.focusMachine.highlightHidden = false
            }
            inputMachines.focusMachine.highlightedPath = nil
            inputMachines.focusMachine.hoveredHighlight = false
        } else if activeModalPath == nil && poppedReturns.isEmpty {
            inputMachines.focusMachine.resetForModalClose()
        }

        // A focused text link exposes its own id as focusedKey. Reconcile the owning
        // text element by its key, then restore the link within it after the layout commit.
        let focusedOwnerKey: String?
        if focusedLinkIndex != nil, let path = focusedPath {
            focusedOwnerKey = prevByPath[path].flatMap { prevNodes[$0].path == path ? prevNodes[$0].key : nil }
        } else {
            focusedOwnerKey = focusedKey
        }
        var nextIdx: Int? = nil
        if txBlur, let shown = whenShown {
            // A blur lands before the commit; `sync_requested_focus` runs after the latched blur,
            // where a newly requested text field still wins over the asked focus
            // (`requested.find(newly_requested)` before `asked`), and a `Tx.focusWhenShown` whose
            // element shows in it resolves otherwise.
            if let rIdx = requestedFocusIdx, canFocusIndex(rIdx) {
                nextIdx = rIdx
                focusVisible = false
            } else {
                nextIdx = shown.index
                focusVisible = shown.ring
                hoveredHighlightActive = false
            }
        } else if txBlur {
            nextIdx = nil
        } else if let fk = txFocusKey,
                  let idx = flatNodes.firstIndex(where: { matchesAuthoredKey($0.key, fk) && canFocusIndex($0.index) }) {
            nextIdx = idx
            if let vis = txFocusVisible {
                focusVisible = vis
            }
        } else if let fk = txFocusKey,
                  (!pendingScrollReveals.isEmpty || !scrollRequestsState.isEmpty || virtualLists.values.contains(where: { $0.rowPlaces.index(ofAuthoredKey: fk) != nil })) {
            // Virtual row may mount on the second commit pass right after post-layout scrollIntoView runs.
            pendingTxFocusKey = fk
        } else if let rIdx = requestedFocusIdx, canFocusIndex(rIdx) {
            nextIdx = rIdx
            focusVisible = false
        } else if let shown = whenShown {
            nextIdx = shown.index
            focusVisible = shown.ring
            hoveredHighlightActive = false
        } else if let fp = focusedPath,
                  let idx = nodeByPath[fp],
                  canFocusIndex(idx),
                  focusedOwnerKey.map({ matchesAuthoredKey(flatNodes[idx].key, $0) }) ?? true {
            nextIdx = idx
        } else if let fp = focusedPath,
                  virtualInputs[fp] != nil {
            // Keep offscreen focused virtual row in `virtualInputs` instead of matching a newly scrolled-in row sharing `focusedKey`.
            nextIdx = nil
        } else if let fk = focusedOwnerKey,
                  let idx = flatNodes.firstIndex(where: { matchesAuthoredKey($0.key, fk) && canFocusIndex($0.index) }) {
            nextIdx = idx
        }

        // Follow app selection changes (`focus_follows`) when focused inside a `focusGroup` (`focus.rs:1400`).
        var nextSelectedByGroup: [String: String] = [:]
        for i in layoutObservers.focusFollowsSelection {
            let gNode = flatNodes[i]
            let prefix = gNode.path + "/"
            if let selIdx = layoutObservers.focusSelected.first(where: { i in
                i != gNode.index && (flatNodes[i].path == gNode.path || flatNodes[i].path.hasPrefix(prefix)) && canFocusIndex(i)
            }) {
                let selPath = flatNodes[selIdx].path
                nextSelectedByGroup[gNode.path] = selPath
                if let cur = nextIdx,
                   findFocusGroupAncestor(of: cur) == gNode.index,
                   let prevSel = inputMachines.focusMachine.lastFocusSelectedByGroup[gNode.path],
                   prevSel != selPath,
                   flatNodes[cur].path != selPath {
                    nextIdx = selIdx
                }
            }
        }
        inputMachines.focusMachine.lastFocusSelectedByGroup = nextSelectedByGroup

        if !txBlur && nextIdx == nil {
            for ret in poppedReturns.reversed() {
                if !ret.isModal {
                    let prior = prevFocusedPath ?? inputMachines.focusMachine.blurredFocusPath
                    let inScope = prior.map { p in
                        p == ret.scopePath || ret.scopePath.isEmpty || p.hasPrefix(ret.scopePath + "/")
                    } ?? false
                    if !inScope { continue }
                }
                if let rk = ret.returnKey,
                   let idx = flatNodes.firstIndex(where: { matchesAuthoredKey($0.key, rk) && canFocusIndex($0.index) }) {
                    nextIdx = idx
                    if inputMachines.focusMachine.openedModalKind == .pointerMenu {
                        focusVisible = false
                    }
                    break
                }
                if let rp = ret.returnPath,
                   let idx = nodeByPath[rp],
                   canFocusIndex(idx) {
                    nextIdx = idx
                    if inputMachines.focusMachine.openedModalKind == .pointerMenu {
                        focusVisible = false
                    }
                    break
                }
            }
        }
        if activeModalPath == nil && !poppedReturns.isEmpty {
            inputMachines.focusMachine.resetForModalClose()
        }

        if txFocusKey == nil && nextIdx == nil {
            for i in layoutObservers.autofocus where canFocusIndex(i) {
                if autofocusAppliedPaths.insert(flatNodes[i].path).inserted {
                    nextIdx = i
                    break
                }
            }
        }

        if !txBlur && nextIdx == nil {
            let allowsVirtual: (String) -> Bool = { path in
                guard let modal = self.activeModalPath else { return true }
                return path == modal || path.hasPrefix(modal + "/")
            }
            if let fk = txFocusKey,
               let v = virtualInputs.values.first(where: { matchesAuthoredKey($0.key, fk) && allowsVirtual($0.path) }) {
                assignFocusPath(v.path, keyboard: focusKeyboard)
                focusedKey = v.key
                if prevFocusedPath != focusedPath { imeReset = true }
                return
            }
            if let fp = focusedPath, let v = virtualInputs[fp], allowsVirtual(v.path) {
                assignFocusPath(v.path, keyboard: focusKeyboard)
                focusedKey = v.key
                if prevFocusedPath != focusedPath { imeReset = true }
                return
            }
            if let fk = focusedKey,
               let v = virtualInputs.values.first(where: { matchesAuthoredKey($0.key, fk) && allowsVirtual($0.path) }) {
                assignFocusPath(v.path, keyboard: focusKeyboard)
                focusedKey = v.key
                if prevFocusedPath != focusedPath { imeReset = true }
                return
            }
        }

        if !txBlur && nextIdx == nil && activeModalPath != nil && (prevFocusedPath != nil || !poppedReturns.isEmpty || cxSettings.viewDefaults.webFocus || (openedModalThisCommit && !openedModalHasMenuOrListbox)) {
            nextIdx = tabOrderIndices().first
        }

        if !txBlur && nextIdx == nil {
            if let fallbackIdx = focusFallback(prevNodes: prevNodes, prevByPath: prevByPath, prevFocusedPath: prevFocusedPath) {
                nextIdx = fallbackIdx
                focusVisible = focusKeyboard
            }
        }

        if let pendingVis = kitHooks.pendingTxFocusVisible {
            kitHooks.pendingTxFocusVisible = nil
            if txFocusKey != nil {
                focusVisible = pendingVis
            }
        }
        let keptOffscreenVirtual: Bool
        let nextPath: String?
        if let idx = nextIdx {
            nextPath = flatNodes[idx].path
            keptOffscreenVirtual = false
        } else if !txBlur, let fp = prevFocusedPath, isOffscreenVirtualFocusedPath(fp) {
            nextPath = fp
            keptOffscreenVirtual = true
        } else {
            nextPath = nil
            keptOffscreenVirtual = false
        }
        if nextIdx != nil {
            // Focus landed on an element (`FocusEvent::Set { path: Some }`): no Tab start or hand-off survives.
            focusHandoff = false
            webFocusTabStartPath = nil
            if txFocusKey != nil, let vis = txFocusVisible {
                focusKeyboard = vis
            } else if let shown = whenShown, shown.index == nextIdx {
                focusKeyboard = shown.ring
            } else if requestedFocusIdx == nextIdx && requestedFocusIdx != nil && txFocusKey == nil {
                focusKeyboard = false
            }
        }
        if prevFocusedPath != nextPath {
            // Focus moved by the commit (`sync_requested_focus`), not by input: `DIRTY`.
            finishPreeditIfNeeded(forPath: prevFocusedPath, at: currentTime, why: CommitWhy.dirty)
            imeReset = true
            hoveredHighlightActive = false
        }
        assignFocusPath(nextPath, keyboard: focusKeyboard)
        focusedKey = keptOffscreenVirtual ? prevFocusedKey : nextIdx.flatMap { flatNodes[$0].key }
        if nextPath != nil || !pressing() {
            inputMachines.focusMachine.blurredFocusPath = nil
        }
        if let chk = inputMachines.focusMachine.pendingPhysicalFocusCheck {
            if focusedPath != chk.beforeFocus {
                inputMachines.focusMachine.suppressedRepeatPhysicalKeys.insert(chk.code)
                if let k = chk.key {
                    inputMachines.focusMachine.suppressedRepeatKey = k
                }
            }
            inputMachines.focusMachine.pendingPhysicalFocusCheck = nil
        }
        syncFocusedLinkIndex()
    }

    /// Focus fallback when the control holding focus (or recently blurred by Escape) leaves the tree (`focus.rs::focus_fallback`).
    private func focusFallback(prevNodes: [FlatNode], prevByPath: [String: Int], prevFocusedPath: String?) -> Int? {
        let gone: String?
        if let fp = prevFocusedPath {
            gone = fp
        } else if focusKeyboard {
            gone = blurredFocusPath ?? webFocusTabStartPath
        } else {
            gone = nil
        }
        guard let gone else { return nil }
        if prevFocusedPath == nil && !focusHandoff { return nil }
        // The control that held focus is still in the tree (e.g. blurred/collapsed while staying): hand nothing on.
        if nodeByPath[gone] != nil { return nil }

        // An offscreen virtual field has no previous slot. A moved stub retains its old slot
        // but loses its path, so only that case climbs the new tree (`r384`, `#842`).
        guard let at = prevByPath[gone] else { return nil }
        let atNode = prevNodes[at]
        guard atNode.path == gone else {
            return atNode.path.isEmpty ? fallbackInNew(gone: gone) : nil
        }
        if prevFocusedPath == nil && !(atNode.el.handlers.editLens != nil || atNode.el.role == .textInput) {
            return nil
        }
        if let modalPrefix = activeModalPath,
           (atNode.path == modalPrefix || atNode.path.hasPrefix(modalPrefix + "/")) {
            return nil
        }

        let atNew: (Int) -> Int? = { i in
            let n = prevNodes[i]
            if !n.path.isEmpty {
                return self.nodeByPath[n.path]
            }
            return self.nodeIndexById[n.nodeId]
        }
        let shown: (Int) -> Bool = { j in
            let r = self.flatNodes[j].targetRect
            return r.width > 0 && r.height > 0 && self.canFocusIndex(j)
        }
        let survivor: (Int) -> Int? = { i in
            guard let j = atNew(i), shown(j) else { return nil }
            return j
        }
        let within: (Int, Int) -> Bool = { j, s in
            let p: String
            let root: String
            if let pj = atNew(j), let rs = atNew(s) {
                p = self.flatNodes[pj].path
                root = self.flatNodes[rs].path
            } else {
                p = prevNodes[j].path
                root = prevNodes[s].path
            }
            return root.isEmpty || (p.count > root.count && p.hasPrefix(root + "/"))
        }

        var scope = prevNodes[at].parentIndex
        while let s = scope {
            if atNew(s) != nil {
                let end = ((s + 1)..<prevNodes.count).first(where: { !within($0, s) }) ?? prevNodes.count
                if let j = ((at + 1)..<end).lazy.compactMap(survivor).first
                    ?? ((s + 1)..<at).reversed().lazy.compactMap(survivor).first
                    ?? survivor(s) {
                    return j
                }
            }
            scope = prevNodes[s].parentIndex
        }
        return nil
    }

    /// Climbs `gone` in `flatNodes` when the old tree held only a pathless moved stub (`#842`).
    internal func fallbackInNew(gone: String) -> Int? {
        guard activeModalPath == nil, nodeByPath[gone] == nil else { return nil }
        let can: (Int) -> Bool = { j in
            let r = self.flatNodes[j].targetRect
            return r.width > 0 && r.height > 0 && self.canFocusIndex(j)
        }
        var p = Substring(gone)
        while let slash = p.lastIndex(of: "/") {
            p = p[..<slash]
            let prefix = String(p)
            guard let j = nodeByPath[prefix] else { continue }
            let childPrefix = prefix + "/"
            if can(j) { return j }
            var idx = j + 1
            while idx < flatNodes.count && flatNodes[idx].path.hasPrefix(childPrefix) {
                if can(idx) { return idx }
                idx += 1
            }
            return nil
        }
        return nil
    }

    internal func isFocusWithin(_ path: String) -> Bool {
        guard let fp = focusedPath else { return false }
        return fp == path || fp.hasPrefix(path + "/")
    }

    internal func highlightRowIndex(for idx: Int) -> Int? {
        var cur: Int? = idx
        while let i = cur, flatNodes.indices.contains(i) {
            let el = flatNodes[i].el
            if nodeTakesFocus(el) {
                return (el.focusHighlightColor != nil && canFocusIndex(i)) ? i : nil
            }
            cur = flatNodes[i].parentIndex
        }
        return nil
    }

    internal func isHighlightVisible(at idx: Int) -> Bool {
        guard flatNodes.indices.contains(idx),
              !flatNodes[idx].effectiveInert,
              focusedPath == flatNodes[idx].path else {
            return false
        }
        return focusVisible || (flatNodes[idx].el.focusHighlightColor != nil && hoveredHighlightActive)
    }

    /// Mirrors `focus.rs::sync_follows`: in a `.focusGroup().focusFollows()`, keeps focus on the selected item.
    private func syncFollows() {
        guard let fp = focusedPath,
              let fIdx = nodeByPath[fp],
              flatNodes.indices.contains(fIdx) else { return }
        let focused = flatNodes[fIdx]
        guard focused.el.handlers.editLens == nil,
              !(focused.el.isFocusSelected || focused.el.itemSelected),
              let gIdx = findFocusGroupAncestor(of: fIdx),
              gIdx != fIdx,
              flatNodes[gIdx].el.isFocusFollowsSelection else { return }
        guard let selectedIdx = flatNodes.indices.first(where: { j in
            j != gIdx &&
            findFocusGroupAncestor(of: j) == gIdx &&
            (flatNodes[j].el.isFocusSelected || flatNodes[j].el.itemSelected) &&
            canFocusIndex(j)
        }) else { return }
        focusedPath = flatNodes[selectedIdx].path
        focusedKey = flatNodes[selectedIdx].key
        focusedLinkIndex = nil
        imeReset = true
    }

    // MARK: - Live Property Evaluation

    /// Free the tracks of removed bindings after their last painted exit disappears.
    internal func pruneLiveBindingTracks(keeping keys: Set<LiveKey>) {
        for key in liveSeenSeq.keys where !keys.contains(key) {
            liveStore.removeNode(key.id)
            liveColorTargets.removeValue(forKey: key.id)
            livePulseRelease.removeValue(forKey: key)
            liveSeenSeq.removeValue(forKey: key)
        }
        // A tween may return with another element or key. Its first attachment survives
        // while the handle lives, independently for each runtime using that handle.
        liveTweenStarts = liveTweenStarts.filter { $0.value.source != nil }
    }

    @discardableResult
    internal func attachLiveTween(_ source: LiveSource) -> Double {
        if let start = liveTweenStarts[source.id] { return start.time }
        liveTweenStarts[source.id] = LiveTweenStart(source: source, time: currentTime)
        return currentTime
    }

    private func updateLiveBindings(at now: Double, launchAt: Double) -> Bool {
        var anyTweenOrPulsePending = false
        for index in layoutObservers.liveSources {
            var node = flatNodes[index]
            if let source = node.el.liveText {
                let text = source.get()
                if text != node.el.plainText {
                    accessibilityLiveRevision &+= 1
                    node.el.plainText = text
                    flatNodes[index] = node
                }
            }
            for b in node.el.liveBindings {
                let lk = LiveKey(path: node.path, target: b.target)
                let nid = lk.id

                // Linear render-time Tween
                if let lin = b.source.linearSpec {
                    let objId = b.source.id
                    let tStart = attachLiveTween(b.source)
                    let snap = b.source.readSnapshot()
                    liveSeenSeq[lk] = (objId, snap.seq)
                    let dur = lin.duration
                    let u = dur <= 0 ? 1.0 : ((currentTime - tStart) / dur).clamped(to: 0...1)
                    if u < 1.0 { anyTweenOrPulsePending = true }
                    var out = MotionLanes()
                    for lane in 0..<4 {
                        out[lane] = lin.from[lane] + (snap.lanes[lane] - lin.from[lane]) * Float(u)
                    }
                    snapLiveTrack(nid: nid, target: b.target, lanes: out)
                    continue
                }

                let snap = b.source.readSnapshot()
                if liveSeenSeq[lk]?.sourceId != b.source.id {
                    liveSeenSeq[lk] = (b.source.id, snap.seq)
                    livePulseRelease.removeValue(forKey: lk)
                    snapLiveTrack(nid: nid, target: b.target, lanes: snap.lanes)
                    continue
                }

                // Release any expired pulse hold
                if let pulse = livePulseRelease[lk], now >= pulse.releaseAt {
                    livePulseRelease.removeValue(forKey: lk)
                    let releaseStart = min(now, max(pulse.releaseAt, launchAt))
                    animateLiveTrack(nid: nid, target: b.target, lanes: pulse.rest, spring: pulse.spring, at: releaseStart)
                } else if livePulseRelease[lk] != nil {
                    anyTweenOrPulsePending = true
                }

                guard liveSeenSeq[lk]?.sequence != snap.seq else { continue }
                liveSeenSeq[lk] = (b.source.id, snap.seq)
                if b.target == .scale || b.target == .rect || b.target == .offset {
                    accessibilityLiveRevision &+= 1
                }

                switch snap.op {
                case .snap(let lanes):
                    livePulseRelease.removeValue(forKey: lk)
                    snapLiveTrack(nid: nid, target: b.target, lanes: lanes)

                case .set(let lanes):
                    livePulseRelease.removeValue(forKey: lk)
                    if let enter = b.spring {
                        let current: Float? = switch b.target {
                        case .opacity: liveStore.get(nid, Props.OPACITY)
                        case .scale: liveStore.get(nid, Props.SCALE)?.x
                        case .blur: liveStore.get(nid, Props.BLUR)?.radius
                        default: nil
                        }
                        let spring = current.map { lanes.l0 < $0 } == true ? (b.restSpring ?? enter) : enter
                        animateLiveTrack(nid: nid, target: b.target, lanes: lanes, spring: spring, at: launchAt)
                    } else if b.target == .opacity, let anim = node.el.opacityMotionAnim {
                        liveStore.set(nid, Props.OPACITY, to: lanes.l0, anim: reducedMotion ? .instant : anim, at: launchAt)
                    } else {
                        snapLiveTrack(nid: nid, target: b.target, lanes: lanes)
                    }

                case let .pulse(active, rest, holdSeconds):
                    if let sp = b.spring {
                        animateLiveTrack(nid: nid, target: b.target, lanes: active, spring: sp, at: launchAt)
                        let leave = b.restSpring ?? sp
                        livePulseRelease[lk] = (launchAt + holdSeconds, rest, leave)
                        anyTweenOrPulsePending = true
                    } else {
                        snapLiveTrack(nid: nid, target: b.target, lanes: rest)
                    }
                }
            }
        }
        for (id, var node) in exitingSnapshots where nodeIndexById[id] == nil {
            if let source = node.el.liveText {
                let text = source.get()
                if text != node.el.plainText {
                    node.el.plainText = text
                    exitingSnapshots[id] = node
                }
            }
        }
        return anyTweenOrPulsePending
    }

    /// A settled channel retains the authored color, including its original sRGB components.
    internal func presentedLiveColor(_ id: NodeId) -> Color? {
        if !liveStore.isMoving(id, Props.FILL), let target = liveColorTargets[id] { return target }
        return liveStore.get(id, Props.FILL).map(Color.init)
    }

    private func snapLiveTrack(nid: NodeId, target: BoundLiveProperty.Target, lanes: MotionLanes) {
        switch target {
        case .opacity: liveStore.snap(nid, Props.OPACITY, to: lanes.l0)
        case .scale: liveStore.snap(nid, Props.SCALE, to: Vec2(lanes.l0, lanes.l0))
        case .blur: liveStore.snap(nid, Props.BLUR, to: Blur(lanes.l0))
        case .offset, .trim: liveStore.snap(nid, Props.OFFSET, to: Vec2(lanes.l0, lanes.l1))
        case .fill, .textColor, .borderColor, .shadowColor, .gradientTop, .gradientBottom:
            let c = Color.decodeLiveLanes(lanes)
            liveColorTargets[nid] = c
            liveStore.snap(nid, Props.FILL, to: c.motionColor)
        case .rect: liveStore.snap(nid, Props.RECT, to: MotionRect.fromLanes(lanes))
        }
    }

    private func animateLiveTrack(nid: NodeId, target: BoundLiveProperty.Target, lanes: MotionLanes, spring: Spring, at now: Double) {
        switch target {
        case .opacity: liveStore.set(nid, Props.OPACITY, to: lanes.l0, anim: .spring(spring), at: now)
        case .scale: liveStore.set(nid, Props.SCALE, to: Vec2(lanes.l0, lanes.l0), anim: .spring(spring), at: now)
        case .blur: liveStore.set(nid, Props.BLUR, to: Blur(lanes.l0), anim: .spring(spring), at: now)
        case .offset, .trim: liveStore.set(nid, Props.OFFSET, to: Vec2(lanes.l0, lanes.l1), anim: .spring(spring), at: now)
        case .fill, .textColor, .borderColor, .shadowColor, .gradientTop, .gradientBottom:
            let c = Color.decodeLiveLanes(lanes)
            liveColorTargets[nid] = c
            liveStore.set(nid, Props.FILL, to: c.motionColor, anim: .spring(spring), at: now)
        case .rect: liveStore.set(nid, Props.RECT, to: MotionRect.fromLanes(lanes), anim: .spring(spring), at: now)
        }
    }

    private func focusOwnerIndex(of idx: Int) -> Int? {
        var cur: Int? = idx
        while let i = cur, flatNodes.indices.contains(i) {
            if canFocusIndex(i) { return i }
            cur = flatNodes[i].parentIndex
        }
        return nil
    }

    private func hasChildRingOverride(forOwner ownerIdx: Int, ownerPath: String) -> Bool {
        guard flatNodes.indices.contains(ownerIdx), flatNodes[ownerIdx].path == ownerPath else { return false }
        let prefix = ownerPath + "/"
        for j in (ownerIdx + 1)..<flatNodes.count {
            let p = flatNodes[j].path
            if !p.hasPrefix(prefix) { break }
            let jel = flatNodes[j].el
            if (jel.focusRingColor != nil || jel.noFocusRing) && focusOwnerIndex(of: j) == ownerIdx {
                return true
            }
        }
        return false
    }

    internal func resolvedFocusRingOverlay(
        el: El<State>,
        snapIndex: Int,
        snapPath: String,
        isExiting: Bool,
        effectiveInert: Bool,
        isFocused: Bool,
        forceFocusRings: Bool,
        defaultRingOutline: Outline?,
        devRect: SIMD4<Float>,
        devRadii: SIMD4<Float>,
        pxScale: Float
    ) -> (rect: SIMD4<Float>, radii: SIMD4<Float>, color: Color, widthPx: Float)? {
        guard !el.noFocusRing else { return nil }
        if !forceFocusRings && el.focusWithinRing == nil {
            guard focusVisible || (isFocused && el.role == .textInput),
                  isFocused || (focusedPath != nil && el.focusRingColor != nil) else { return nil }
        }
        let suppressedByListOrMenuGroup: Bool = {
            guard el.focusRingColor == nil,
                  flatNodes.indices.contains(snapIndex),
                  flatNodes[snapIndex].path == snapPath,
                  let gIdx = findFocusGroupAncestor(of: snapIndex),
                  flatNodes.indices.contains(gIdx) else { return false }
            let role = flatNodes[gIdx].el.role
            return role == .listbox || role == .list || role == .tree || role == .grid || role == .menu
        }()
        let suppressesDefaultRing = el.focusHighlightColor != nil ||
            (el.focusRingColor == nil && (el.handlers.editLens != nil || el.role == .textInput || hasActiveTextLinks(el) || suppressedByListOrMenuGroup))
        let ownerIsFocused: Bool = {
            if isFocused { return true }
            guard !isExiting, !effectiveInert, el.focusRingColor != nil, !el.noFocusRing,
                  !nodeTakesFocus(el),
                  flatNodes.indices.contains(snapIndex),
                  flatNodes[snapIndex].path == snapPath,
                  let fp = focusedPath,
                  let ownerIdx = focusOwnerIndex(of: snapIndex) else { return false }
            return flatNodes[ownerIdx].path == fp
        }()
        let defaultSuppressedByChild = isFocused && el.focusRingColor == nil &&
            !isExiting && hasChildRingOverride(forOwner: snapIndex, ownerPath: snapPath)
        let forcedRing = forceFocusRings && nodeTakesFocus(el) && !suppressesDefaultRing &&
            (isExiting || !hasChildRingOverride(forOwner: snapIndex, ownerPath: snapPath))
        let keyboardRing = ownerIsFocused && !defaultSuppressedByChild && !suppressesDefaultRing &&
            (focusVisible || (isFocused && el.role == .textInput))
        let shouldShow = !el.noFocusRing && (forcedRing || keyboardRing)
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
            return (ringRect, ringRadii, ringCol, ringW)
        }
        guard !isExiting, !effectiveInert, !el.noFocusRing,
              let within = el.focusWithinRing,
              let fp = focusedPath,
              (fp == snapPath || fp.hasPrefix(snapPath + "/")) else {
            return nil
        }
        let off = within.offset * pxScale
        let ringW = within.width * pxScale
        let ringRect = SIMD4<Float>(devRect.x - off, devRect.y - off, devRect.z + off * 2.0, devRect.w + off * 2.0)
        let ringRadii = SIMD4<Float>(
            devRadii.x >= 0 ? devRadii.x + off : devRadii.x - off,
            devRadii.y >= 0 ? devRadii.y + off : devRadii.y - off,
            devRadii.z >= 0 ? devRadii.z + off : devRadii.z - off,
            devRadii.w >= 0 ? devRadii.w + off : devRadii.w - off
        )
        return (ringRect, ringRadii, within.color, ringW)
    }

    private func emitFocusRingIfNeeded(
        el: El<State>,
        snapIndex: Int,
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
        guard let overlay = resolvedFocusRingOverlay(
            el: el,
            snapIndex: snapIndex,
            snapPath: snapPath,
            isExiting: isExiting,
            effectiveInert: effectiveInert,
            isFocused: isFocused,
            forceFocusRings: forceFocusRings,
            defaultRingOutline: defaultRingOutline,
            devRect: devRect,
            devRadii: devRadii,
            pxScale: pxScale
        ) else {
            return
        }
        let clipAll = SIMD4<Float>(0, 0, Float(devW), Float(devH))
        primitives.append(.roundedRect(
            rect: overlay.rect,
            radii: overlay.radii,
            fill: .zero,
            borderColor: overlay.color.scaleAlpha(localAlpha).simd4(srgb: srgbBlend),
            borderWidth: overlay.widthPx,
            clip: clipAll
        ))
    }

    // MARK: - Primitive Emission & ElementInfo Snapshot

    internal func refreshDissolvePrepass<Node>(
        nodes: [Node],
        nodeId: (Node) -> NodeId,
        isDissolve: (Node) -> Bool,
        childIds: (NodeId) -> [NodeId],
        ownOpacity: (NodeId) -> Float
    ) -> Set<NodeId> {
        hasDissolve = nodes.contains(where: isDissolve)
        guard hasDissolve else {
            dissolveScratch.removeAll(keepingCapacity: true)
            return []
        }
        var scratch = [Bool](repeating: false, count: nodes.count)
        var parents: Set<NodeId> = []
        for (idx, node) in nodes.enumerated() where isDissolve(node) {
            let nid = nodeId(node)
            let hasMid = childIds(nid).contains { cid in
                let pOp = ownOpacity(cid)
                return pOp > 0.001 && pOp < 1.0
            }
            if hasMid {
                parents.insert(nid)
                scratch[idx] = true
            }
        }
        dissolveScratch = scratch
        return parents
    }

    internal func isLinearTweenActive(_ source: LiveSource) -> Bool {
        guard let lin = source.linearSpec, lin.duration > 0 else { return false }
        guard let start = liveTweenStarts[source.id] else { return true }
        return currentTime - start.time < lin.duration
    }

    private func resolvePaintTextLayout(
        snapId: NodeId,
        isInput: Bool,
        isExiting: Bool,
        text: String,
        spans: [TextSpan]?,
        pills: [PillChip],
        style: TextStyle,
        wrapWidth: Float?,
        pxScale: Float,
        glidePx: Vec2,
        isSecure: Bool,
        pretty: Bool = false,
        paragraphs: ParagraphRequest? = nil,
        rasterWindow: TextRasterWindow? = nil
    ) -> TextLayoutBox {
        let keep: TextKeep = isSecure ? .secret : (glidePx == .zero ? .cached : .owned)
        if isSecure {
            return textSystem.layoutKeyed(
                text: text,
                spans: spans,
                pills: pills,
                style: style,
                maxWidth: wrapWidth,
                pixelScale: pxScale,
                emitGlyphs: true,
                glidePx: glidePx,
                keep: .secret,
                countAsRebreak: false,
                pretty: pretty
            )
        }
        let targetAuth = spans.map { $0.map(\.text).joined() } ?? text
        let targetScale = max(pxScale, 1.0)
        func retainGlyphs(_ box: TextLayoutBox) -> Bool {
            guard box.hasGlyphs, box.rasterWindow == nil else { return false }
            #if canImport(CoreText) && canImport(CoreGraphics)
            let geometry = box.cachedGeometry
            if !geometry.shaped.glyphPlacementsAreResident(in: textSystem.glyphAtlas)
                || (box.shaped.glyphPlacements !== geometry.shaped.glyphPlacements
                    && !box.shaped.glyphPlacementsAreResident(in: textSystem.glyphAtlas)) {
                textSystem.glyphCache.forget(shapeKey: box.shapeKey)
                return false
            }
            #elseif canImport(CRuneDesktopText)
            if let resets = box.desktopAtlasResets, !textSystem.glyphAtlas.retainPages(box.desktopPages, since: resets) {
                textSystem.glyphCache.forget(shapeKey: box.shapeKey)
                return false
            }
            #endif
            return true
        }
        if isExiting, let exiting = exitingTextLayouts[snapId]?.box {
            if glidePx == .zero, exiting.shapeKey.usesSmoothing(textSystem.smoothing), retainGlyphs(exiting) {
                return exiting
            }
            let filled = textSystem.layoutKeyed(
                text: text,
                spans: spans,
                pills: pills,
                style: style,
                maxWidth: exiting.maxWidth,
                pixelScale: pxScale,
                emitGlyphs: true,
                glidePx: glidePx,
                keep: glidePx == .zero ? .cached : .owned,
                countAsRebreak: false,
                pretty: pretty
            )
            if glidePx == .zero {
                exitingTextLayouts[snapId]?.box = filled
            }
            return filled
        }
        if !isExiting, glidePx == .zero, let live = nodeTextLayouts[snapId]?.box {
            // A layout measured greedy is not reused for pretty paint (or vice versa, `#882`).
            let matchesPretty = live.shapeKey.pretty == TextShapeKey.layoutPretty(pretty, style: style)
            let matchesText = HistoryText.sameBytes(live.authText, targetAuth) && live.pills == pills
                && live.style == style && abs(live.pixelScale - targetScale) < 0.01 && matchesPretty
                && (live.paragraphs == nil || paragraphs != nil) && live.shapeKey.matchesLayoutSpans(spans)
            let matchesWidth: Bool = {
                guard let ww = wrapWidth else {
                    return live.maxWidth == nil
                }
                guard let mw = live.maxWidth else {
                    return false
                }
                return abs(mw - ww) <= 0.75
            }()
            if matchesText && matchesWidth && live.shapeKey.usesSmoothing(textSystem.smoothing) {
                if let laid = live.paragraphs, laid.waiting, let request = paragraphs, !request.highlights.isEmpty {
                    let prepared = textSystem.prepareHighlights(request.highlights, in: laid, field: request.field)
                    if prepared !== laid {
                        let box = textSystem.paragraphBox(prepared, text: live.authText, spans: spans, style: style, pixelScale: pxScale)
                        nodeTextLayouts[snapId] = RetainedLayoutCoordinator.TextLayoutRecord(box: box, isInput: true)
                        return box
                    }
                }
                if let rasterWindow, live.paragraphs == nil, live.shaped.lineCount > 1,
                   rasterWindow.lowerY > 0 || rasterWindow.upperY < live.shaped.size.y {
                    return textSystem.layoutKeyed(text: text, spans: spans, pills: pills, style: style,
                                                  maxWidth: live.maxWidth, pixelScale: pxScale, emitGlyphs: true,
                                                  glidePx: .zero, keep: .cached, countAsRebreak: false,
                                                  pretty: pretty, rasterWindow: rasterWindow)
                }
                if retainGlyphs(live) {
                    let painted = textSystem.presentedLayout(live, spans: spans)
                    if painted !== live { nodeTextLayouts[snapId]?.box = painted }
                    return painted
                }
                let filled = textSystem.layoutKeyed(
                    text: text,
                    spans: spans,
                    pills: pills,
                    style: style,
                    maxWidth: live.maxWidth,
                    pixelScale: pxScale,
                    emitGlyphs: true,
                    glidePx: .zero,
                    keep: .cached,
                    countAsRebreak: false,
                    pretty: pretty
                )
                nodeTextLayouts[snapId] = RetainedLayoutCoordinator.TextLayoutRecord(box: filled, isInput: isInput)
                return filled
            }
        }
        let box = paragraphs != nil
            ? textSystem.layoutInput(
                text: text,
                spans: spans,
                pills: pills,
                style: style,
                maxWidth: wrapWidth,
                pixelScale: pxScale,
                emitGlyphs: true,
                keep: keep,
                countAsRebreak: false,
                request: paragraphs,
                rasterWindow: rasterWindow
            )
            : textSystem.layoutKeyed(
                text: text,
                spans: spans,
                pills: pills,
                style: style,
                maxWidth: wrapWidth,
                pixelScale: pxScale,
                emitGlyphs: true,
                glidePx: glidePx,
                keep: keep,
                countAsRebreak: false,
                pretty: pretty,
                rasterWindow: rasterWindow
            )
        if box.rasterWindow == nil, !isExiting && (glidePx == .zero || box.paragraphs != nil) {
            nodeTextLayouts[snapId] = RetainedLayoutCoordinator.TextLayoutRecord(box: box, isInput: isInput)
        }
        return box
    }

    /// Color glyph bitmaps share the image atlas. Only coverage glyphs use the foreground RGB.
    internal func referenceTextPrimitive(
        _ source: PositionedGlyph, rect sourceRect: SIMD4<Float>, ink: SIMD4<Float>, clip: SIMD4<Float>, turn: Float = 0,
        forceScaled: Bool = false, nativeLCD: Bool = false
    ) -> (primitive: Primitive, page: UInt16) {
        let glyph: PositionedGlyph, rect: SIMD4<Float>
        if source.usesInkDilation {
            (glyph, rect) = textSystem.glyphAtlas.outlineInk(source, rect: sourceRect, ink: ink, encoded: srgbBlend)
        } else {
            (glyph, rect) = (source, sourceRect)
        }
        if let image = colorGlyphImage(glyph) {
            return (.image(rect: rect, uv: image.region.edges, tint: SIMD4(1, 1, 1, ink.w), clip: clip, turn: turn, page: image.region.page), 0)
        }
        if nativeLCD, !forceScaled, turn == 0,
           let sample = textSystem.lcdMask(for: glyph, rect: rect, ink: ink, encoded: srgbBlend) {
            var primitive = Primitive.glyph(rect: rect, uv: sample.uv, color: ink, gamma: 1, clip: clip, nativeSize: true)
            primitive.radii.x = 1
            return (primitive, sample.page)
        }
        let sample = textSystem.glyphMask(for: glyph, ink: ink, encoded: srgbBlend)
        let uv = sample.uv
        let atlas = textSystem.glyphAtlas.pagePixelSize
        let width = max(1, (uv.z - uv.x) * Float(atlas.x))
        let height = max(1, (uv.w - uv.y) * Float(atlas.y))
        let nativeSize = !forceScaled && abs(width - rect.z) <= 0.5 && abs(height - rect.w) <= 0.5
        return (.glyph(rect: rect, uv: uv, color: ink, gamma: sample.gamma,
                       clip: clip, turn: turn, nativeSize: nativeSize), sample.page)
    }

    private func buildRefScene(frameOut: FrameOutput, now: Double, startShapedCount: UInt64? = nil) -> RefScene {
        cyclePaint.begin()
        beginPixelPaint()
        defer { finishPixelPaint() }
        let paintMotion = PaintMotionTracks(store: scene.store)
        var carriedScrollCache = makeCarriedScrollCache()
        let baselineShapedCount = startShapedCount ?? textSystem.shapedCallCount
        beginPaintGlyphFrame(pinnedMask: lastPinnedGlyphMask)
        textSystem.glyphCache.beginFrame()
        var glyphPageEntries: [(index: Int, page: UInt16)] = []
        var usedGlyphMask: UInt32 = 0
        func recordGlyphPage(_ index: Int, _ page: UInt16) {
            if page != 0 { glyphPageEntries.append((index, page)) }
            usedGlyphMask |= UInt32(1) << min(UInt32(page), 31)
        }

        var labelRasters = TextBoxGeometry.ScaledLabelRasters()
        func textPrimitive(_ glyph: PositionedGlyph, rect: SIMD4<Float>, ink: SIMD4<Float>,
                           clip: SIMD4<Float>, turn: Float = 0, forceScaled: Bool = false, at index: Int) -> Primitive {
            let (primitive, page) = referenceTextPrimitive(glyph, rect: rect, ink: ink, clip: clip, turn: turn, forceScaled: forceScaled)
            if primitive.kind == .glyph { recordGlyphPage(index, page) }
            return primitive
        }

        let pxScale = pixelScale
        let devW = max(1, Int((viewport.x * pxScale).rounded()))
        let devH = max(1, Int((viewport.y * pxScale).rounded()))
        let defaultViewFg = cxSettings.viewDefaults.textForeground
        let defaultRingOutline = cxSettings.viewDefaults.focusRing
            ?? Outline(width: 2.0, offset: 3.0, color: cxSettings.systemAccent.focus(dark: systemDark))
        let forceFocusRings = cxSettings.viewDefaults.forceFocusRings
        stuckShiftsByPath.removeAll(keepingCapacity: true)
        activePaintedLoopsAnimating = false
        activePaintedLoopWake = nil
        imeArea = nil
        let activeSelectionRanges = computeActiveSelectionRangesByPath()
        pixelSnapGlides.beginFrame(t: now, size: SIMD2<Float>(Float(devW), Float(devH)))
        clearPressRestingHits()

        // Precompute raw (unscaled) rect, own scale, opacity, and tree links for `frameOut.nodes`
        var ownById = Dictionary<NodeId, OwnPaintPresentation>(minimumCapacity: frameOut.nodes.count)
        var presentedRectById: [NodeId: MotionRect] = [:]
        var presentedScaleById: [NodeId: Vec2] = [:]
        let nodeByFrameId = frameOut.paintNodesById
        var childrenByParent: [NodeId: [Presented]] = [:]
        var rootNodes: [Presented] = []

        var hasAnchors = false
        var hasStickyNodes = false
        var hasTraceNamespace = false
        for n in flatNodes {
            if n.el.anchor != nil { hasAnchors = true }
            if n.isSticky { hasStickyNodes = true }
            if n.el.traceNamespaceValue != nil { hasTraceNamespace = true }
        }
        var anchorByKey: [String: FlatNode] = [:]
        if hasAnchors || exitingSnapshots.values.contains(where: { $0.el.anchor != nil }) {
            for n in flatNodes {
                if let k = n.key { anchorByKey[k] = n }
            }
            for p in frameOut.nodes {
                if let snap = mountedNode(p.id) ?? exitingSnapshots[p.id], let k = snap.key, anchorByKey[k] == nil {
                    anchorByKey[k] = snap
                }
            }
        }

        // Compute own raw presented rect, inherited presented rect, opacity, scale, and rotation (applying Live & Loop tracks on top of Scene)
        var presentedInhById: [NodeId: PresentedTransform] = [:]
        var nodeScaleMotionById = Dictionary<NodeId, PaintScaleMotion>(minimumCapacity: frameOut.nodes.count)
        var ownLoopOffsetById: [NodeId: Vec2] = [:]
        var liveMovedById: Set<NodeId> = []
        var liveSpatialSpringingById: Set<NodeId> = []
        var stickyOwnLiveOffsetById: [NodeId: Vec2] = [:]
        var anchorBaseRectById: [NodeId: MotionRect] = [:]
        var hasZOrder = false
        for p in frameOut.nodes {
            guard let snap = mountedNode(p.id) ?? exitingSnapshots[p.id] else { continue }
            if snap.zOrder != 0 { hasZOrder = true }
            var baseRect = p.rect
            if p.isExiting {
                let gKey = snap.el.foldGlideSpec != nil ? "fold:\(snap.path)" : "growth:\(snap.path)"
                if let gEntry = growthRows[gKey] {
                    baseRect = MotionRect.fromXYWH(baseRect.x, baseRect.y, baseRect.width, max(0, gEntry.track.h))
                } else if snap.el.foldGlideSpec != nil {
                    baseRect = MotionRect.fromXYWH(baseRect.x, baseRect.y, baseRect.width, 0)
                }
            }
            var preLoopOp = p.opacity
            var loopOp: Float = 1.0
            var ownSc = p.scale
            var rot = p.rotate
            var ownDelta = Vec2.zero
            var hasLiveTransform = false
            var hasLiveSpatialSpring = false
            var hasLiveRect = false

            let loopNow = scene.store.nodeTime(p.id)
            if let ls = sampleLoopPresentation(id: p.id, nodeSize: baseRect.size, at: loopNow, wallNow: currentTime) {
                loopOp = ls.opacity
                rot += ls.rotation
                ownSc.x *= ls.scale
                ownSc.y *= ls.scale
                ownLoopOffsetById[p.id] = ls.offset
            }

            for b in snap.el.liveBindings {
                let lnid = NodeId.hash("live:\(snap.path):\(b.target)")
                switch b.target {
                case .opacity:
                    if let v = liveStore.get(lnid, Props.OPACITY) { preLoopOp = v }
                case .scale:
                    if let v = liveStore.get(lnid, Props.SCALE) {
                        ownSc = Vec2(p.scale.x * max(0, v.x), p.scale.y * max(0, v.y))
                        hasLiveTransform = true
                        if liveStore.isMoving(lnid, Props.SCALE) || isLinearTweenActive(b.source) {
                            hasLiveSpatialSpring = true
                        }
                    }
                case .offset:
                    if let v = liveStore.get(lnid, Props.OFFSET) {
                        ownDelta.x += v.x
                        ownDelta.y += v.y
                        hasLiveTransform = true
                        if liveStore.isMoving(lnid, Props.OFFSET) || isLinearTweenActive(b.source) {
                            hasLiveSpatialSpring = true
                        }
                    }
                case .rect:
                    if let v = liveStore.get(lnid, Props.RECT) {
                        baseRect = v
                        hasLiveTransform = true
                        hasLiveRect = true
                        if liveStore.isMoving(lnid, Props.RECT) || isLinearTweenActive(b.source) {
                            hasLiveSpatialSpring = true
                        }
                    }
                case .blur, .fill, .trim, .textColor, .borderColor, .shadowColor, .gradientTop, .gradientBottom:
                    break
                }
            }
            let pressSc = snap.el.pressScaleFactor == nil ? 1 : pressScaleValue(for: p.id)
            ownSc = Vec2(ownSc.x * pressSc, ownSc.y * pressSc)
            let op = preLoopOp * loopOp


            let pinh: PresentedTransform
            if let a = snap.el.anchor, let anchorNode = anchorByKey[a.key] {
                let anchorRect = presentedRectById[anchorNode.nodeId]
                    ?? presentedRectByPath[anchorNode.path]
                    ?? anchorNode.zoomedTargetRect
                let anchorParentId = nodeByFrameId[anchorNode.nodeId]?.parent
                    ?? anchorNode.parentIndex.flatMap { flatNodes.indices.contains($0) ? flatNodes[$0].nodeId : nil }
                let anchorZoom: Float = anchorParentId.flatMap { presentedScaleById[$0]?.x }
                    ?? anchorNode.parentIndex.flatMap { flatNodes.indices.contains($0) ? flatNodes[$0].inheritedScale : nil }
                    ?? 1.0
                let anchorBase = hasLiveRect ? baseRect : (scene.world(p.id) ?? baseRect)
                anchorBaseRectById[p.id] = anchorBase
                pinh = AnchorLayoutHelper.anchoredPaintTransform(
                    anchor: a,
                    baseRect: anchorBase,
                    ownElScale: snap.el.scale,
                    hasScaleTrack: anchoredOverlayHasScaleTrack(snap.el, nodeId: p.id),
                    anchorDrawnRect: anchorRect,
                    anchorInheritedZoom: anchorZoom,
                    viewport: viewport
                )
            } else {
                pinh = (snap.el.anchor == nil ? p.parent.flatMap { presentedInhById[$0] } : nil) ?? .identity
            }
            let sc = Vec2(pinh.scale.x * ownSc.x, pinh.scale.y * ownSc.y)
            let norm = snap.anchorAttachNorm ?? snap.el.origin
            let pivot = Vec2(baseRect.x + baseRect.width * norm.x, baseRect.y + baseRect.height * norm.y)
            let ownDx = pinh.dx + ownDelta.x
            let ownDy = pinh.dy + ownDelta.y
            let centre = Vec2(pivot.x + ownDx, pivot.y + ownDy)
            let centreTo = Vec2(
                pinh.anchorTo.x + (centre.x - pinh.anchor.x) * pinh.scale.x,
                pinh.anchorTo.y + (centre.y - pinh.anchor.y) * pinh.scale.y
            )
            let hasOwnScale = abs(ownSc.x - 1.0) > 1e-5 || abs(ownSc.y - 1.0) > 1e-5
            let (anchor, anchorTo) = hasOwnScale ? (centre, centreTo) : (pinh.anchor, pinh.anchorTo)
            let extraScrollY: Float = snap.el.layout.scrollAxes.contains(.vertical) ? (slice2State.scrollExtraYByPath[snap.path] ?? 0) : 0
            presentedInhById[p.id] = PresentedTransform(
                dx: ownDx,
                dy: ownDy - extraScrollY,
                anchor: anchor,
                anchorTo: anchorTo,
                scale: sc
            )

            let shifted = baseRect.offsetBy(Vec2(ownDx, ownDy))
            let preRect: MotionRect
            if abs(sc.x - 1.0) > 1e-5 || abs(sc.y - 1.0) > 1e-5 || anchor != anchorTo {
                preRect = MotionRect(
                    left: anchorTo.x + (shifted.left - anchor.x) * sc.x,
                    top: anchorTo.y + (shifted.top - anchor.y) * sc.y,
                    right: anchorTo.x + (shifted.right - anchor.x) * sc.x,
                    bottom: anchorTo.y + (shifted.bottom - anchor.y) * sc.y
                )
            } else {
                preRect = shifted
            }
            presentedRectById[p.id] = preRect
            if ownDelta != .zero {
                stickyOwnLiveOffsetById[p.id] = Vec2(ownDelta.x * pinh.scale.x, ownDelta.y * pinh.scale.y)
            }
            if hasLiveTransform { liveMovedById.insert(p.id) }
            if hasLiveSpatialSpring { liveSpatialSpringingById.insert(p.id) }
            ownById[p.id] = OwnPaintPresentation(rect: baseRect.offsetBy(ownDelta), scale: ownSc,
                                                  opacity: op.clamped(to: 0...1),
                                                  preLoopOpacity: preLoopOp.clamped(to: 0...1), rotation: rot)
            presentedScaleById[p.id] = sc

            if let pid = p.parent, nodeByFrameId[pid] != nil {
                childrenByParent[pid, default: []].append(p)
            } else {
                rootNodes.append(p)
            }
        }

        // Precompute `hoverAlone` & `hoverGroupShared` active state from pointer / keyboard focus
        let isGroupHovered = makeGroupHoverPredicate(presentedRectById: presentedRectById)

        func sortByZOrder(_ nodes: [Presented]) -> [Presented] {
            guard nodes.count > 1, hasZOrder || hasStickyNodes else { return nodes }
            return nodes.enumerated().sorted { a, b in
                let na = mountedNode(a.element.id) ?? exitingSnapshots[a.element.id]
                let nb = mountedNode(b.element.id) ?? exitingSnapshots[b.element.id]
                let za = na?.zOrder ?? 0
                let zb = nb?.zOrder ?? 0
                if za != zb { return za < zb }
                if hasStickyNodes {
                    func stickyRank(_ n: FlatNode?) -> Int {
                        guard let n else { return 0 }
                        if n.el.anchor != nil || n.el.isModal { return 2 }
                        if n.isSticky { return 1 }
                        return 0
                    }
                    let ra = stickyRank(na)
                    let rb = stickyRank(nb)
                    if ra != rb { return ra < rb }
                }
                return a.offset < b.offset
            }.map(\.element)
        }

        _ = refreshDissolvePrepass(
            nodes: frameOut.nodes,
            nodeId: \.id,
            isDissolve: { (mountedNode($0.id) ?? exitingSnapshots[$0.id])?.el.isDissolve ?? false },
            childIds: { nid in (childrenByParent[nid] ?? []).map(\.id) },
            ownOpacity: { nid in ownById[nid]?.opacity ?? nodeByFrameId[nid]?.opacity ?? 1.0 }
        )

        let needsStickyPlacement = hasStickyNodes || scrollRequestsState.keeps.contains { $0.hold != nil }
        var preStickyById: [NodeId: (shift: Vec2, parentShiftMag: Float)] = [:]
        var preStickyRectById: [NodeId: MotionRect] = [:]
        if needsStickyPlacement {
            var preStickyShifts = [Vec2](repeating: .zero, count: flatNodes.count)
            preStickyById.reserveCapacity(flatNodes.count)
            preStickyRectById.reserveCapacity(flatNodes.count)
            for i in flatNodes.indices {
                let node = flatNodes[i]
                let nid = node.nodeId
                if node.el.anchor != nil && !node.isSticky {
                    preStickyById[nid] = (.zero, 0)
                    preStickyRectById[nid] = presentedRectById[nid] ?? node.targetRect
                    continue
                }
                let parentS = node.parentIndex.map { preStickyShifts[$0] } ?? .zero
                let computed = computePaintStickyShift(
                    nodeIndex: i,
                    parentStickyShift: parentS,
                    presentedRectByNodeId: presentedRectById,
                    ownLiveOffset: stickyOwnLiveOffsetById[nid] ?? .zero
                )
                preStickyShifts[i] = computed.shift
                preStickyById[nid] = computed
                let base = presentedRectById[nid] ?? node.targetRect
                preStickyRectById[nid] = computed.shift == .zero ? base : base.offsetBy(computed.shift)
            }
        }

        var primitives: [Primitive] = []
        var backdropBlurCount = 0
        primitives.reserveCapacity(frameOut.nodes.count * 2)
        var infos: [ElementInfo] = []
        // As in turn.rs, a rotated branch keeps its window-space outer clip separate
        // from rectangles accumulated in that branch's own coordinates.
        var reportedTurnClips: [(outer: MotionRect?, local: MotionRect?)] = []
        infos.reserveCapacity(frameOut.nodes.count)
        var rawPoseByPath: [String: RawPoseNodeData] = [:]
        let movingGrowthPaths = movingGrowthPaintPaths()
        var hasInheritedPose = !frameLandingHoldIds.isEmpty
        var parentPathForInfo: [PaintElementKey: String] = [:]
        parentPathForInfo.reserveCapacity(frameOut.nodes.count)
        let windowRect = MotionRect.fromXYWH(0, 0, viewport.x, viewport.y)
        var newRectByPath = Dictionary<String, MotionRect>(minimumCapacity: frameOut.nodes.count)
        var newScaleByPath = Dictionary<String, Vec2>(minimumCapacity: frameOut.nodes.count)
        var newTurnByPath: [String: Turn] = [:]
        var newHitGeometries = FrameGeometry<HitGeometry>(minimumCapacity: frameOut.nodes.count)
        var newPaintOrder: [String] = []
        newPaintOrder.reserveCapacity(frameOut.nodes.count)
        var newHelpHits: [HelpHitRecord] = []
        var nextImeCursorArea: [Float]? = nil
        var nextImeOptionAsAlt: Bool = false
        var nextNoWindowDragRects: [MotionRect] = []
        var newInteractiveHits: [HelpInteractiveHitRecord] = []
        var newLinkBoxes: [String: [TextLinkBox]] = [:]
        var builtSurfaces: [SurfaceDraw] = []
        var surfaceVideo = SurfaceVideoPaint()
        var newDrawnRectByPath = Dictionary<String, MotionRect>(minimumCapacity: frameOut.nodes.count)
        var newRectSpringingById = Dictionary<NodeId, Bool>(minimumCapacity: frameOut.nodes.count)
        kitHooks.unseenPresence.beginFrame()

        let flyingRootIds: Set<NodeId> = Set(frameOut.nodes.compactMap { p in
            guard let snap = mountedNode(p.id), !p.isExiting else {
                return nil
            }
            if activeFlightIds.contains(p.id)
                || launchedFlightIds.contains(p.id)
                || unclippedMatchedFlightIds.contains(p.id) {
                return p.id
            }
            if snap.el.flightId != nil && scene.isEdgeAnimating(p.id) {
                return p.id
            }
            return nil
        })
        var liftedFlights: [LiftedFlightSubtree] = []
        var newSeenMatched: [String: MatchedSeenSnapshot] = [:]

        @inline(never)
        func emitNodeEnter(_ input: EmitStepInput) -> (children: [EmitStepInput], exit: EmitNodeExit) {
            let p = input.p
            let ancestorOpacity = input.ancestorOpacity
            let logicalAncestorOpacity = input.logicalOpacity
            let nodeExiting = p.isExiting || input.inheritedExiting
            let ancestorTurn = input.ancestorTurn
            let outerTurnClip = input.outerTurnClip
            let localTurnClip = input.localTurnClip
            let parentPath = input.parentPath
            let nearestGroupHovered = input.nearestGroupHovered
            let nearestGroupHoverFrac = input.nearestGroupHoverFrac
            let flightCover = input.flightCover
            let flightClipOverride = input.flightClipOverride
            let emitLiftedNow = input.emitLiftedNow
            let emptyExit = EmitNodeExit(layerEndCount: 0, devClip: .zero)
            guard let snap = mountedNode(p.id) ?? exitingSnapshots[p.id] else { return ([], emptyExit) }
            let el = presentedGrowthElement(snap)
            let inh: PaintInh
            let resolvedAnchor = el.anchor.flatMap { anchorByKey[$0.key] }
            if let a = el.anchor, let anchorNode = resolvedAnchor {
                let anchorRect = newRectByPath[anchorNode.path]
                    ?? presentedRectById[anchorNode.nodeId]
                    ?? presentedRectByPath[anchorNode.path]
                    ?? anchorNode.zoomedTargetRect
                let anchorParentId = nodeByFrameId[anchorNode.nodeId]?.parent
                    ?? anchorNode.parentIndex.flatMap { flatNodes.indices.contains($0) ? flatNodes[$0].nodeId : nil }
                let anchorParentPath = anchorParentId.flatMap { (mountedNode($0) ?? exitingSnapshots[$0])?.path }
                let anchorZoom: Float = anchorParentPath.flatMap { newScaleByPath[$0]?.x }
                    ?? anchorParentId.flatMap { presentedScaleById[$0]?.x }
                    ?? anchorNode.parentIndex.flatMap { flatNodes.indices.contains($0) ? flatNodes[$0].inheritedScale : nil }
                    ?? 1.0
                let pinh = AnchorLayoutHelper.anchoredPaintTransform(
                    anchor: a,
                    baseRect: anchorBaseRectById[p.id] ?? p.rect,
                    ownElScale: el.scale,
                    hasScaleTrack: anchoredOverlayHasScaleTrack(el, nodeId: p.id),
                    anchorDrawnRect: anchorRect,
                    anchorInheritedZoom: anchorZoom,
                    viewport: viewport
                )
                let anchorScaleActive = abs(pinh.scale.x - 1.0) > 1e-5 || abs(pinh.scale.y - 1.0) > 1e-5
                let anchorMotion: PaintScaleMotion = anchorScaleActive
                    ? (anchorParentId.flatMap { aid -> PaintScaleMotion? in
                        if let cached = nodeScaleMotionById[aid] { return cached }
                        let parentMoving = scene.store.isAnimating(aid, Props.SCALE)
                            || scene.store.isAnimating(aid, Props.UNIFORM_SCALE)
                            || scene.store.isAnimating(aid, Props.PRESENCE)
                            || scene.store.isAnimating(aid, Props.PRESS_SCALE)
                        return parentMoving ? .moving : .still
                    } ?? .still)
                    : .still
                let effScaleMotion = max(input.inh.scaleMotion, anchorMotion)
                var modified = PaintInh()
                modified.opacity = input.inh.opacity
                modified.scale = pinh.scale
                modified.anchor = SIMD2<Float>(pinh.anchor.x, pinh.anchor.y)
                modified.anchorTo = SIMD2<Float>(pinh.anchorTo.x, pinh.anchorTo.y)
                modified.snap = input.inh.snap
                modified.snap.placeAtAnchor()
                modified.offsetDelta = Vec2(pinh.dx, pinh.dy)
                modified.fullDelta = Vec2(pinh.dx, pinh.dy)
                modified.scaleMotion = effScaleMotion
                modified.stillScale = (anchorScaleActive && effScaleMotion == .still) ? pinh.scale.x : 1.0
                inh = modified
            } else {
                inh = input.inh
            }
            let isFlight = flyingRootIds.contains(p.id)
            if !emitLiftedNow && (isFlight || el.isRaised) {
                liftedFlights.append(LiftedFlightSubtree(
                    node: p,
                    inh: inh,
                    isFlight: isFlight,
                    treeInfoOffset: isFlight ? nil : infos.count,
                    ancestorOpacity: ancestorOpacity,
                    logicalOpacity: logicalAncestorOpacity,
                    ancestorBlur: input.ancestorBlur,
                    inheritedExiting: nodeExiting,
                    ancestorTurn: ancestorTurn,
                    outerTurnClip: outerTurnClip,
                    localTurnClip: localTurnClip,
                    parentPath: parentPath,
                    nearestGroupHovered: nearestGroupHovered,
                    nearestGroupHoverFrac: nearestGroupHoverFrac,
                    nearestPressColor: input.nearestPressColor,
                    nearestPressFrac: input.nearestPressFrac,
                    parentStickyShift: input.parentStickyShift,
                    parentStickyMag: input.parentStickyMag
                ))
                return ([], emptyExit)
            }
            let textFlightTarget = activeTextFlights.first(where: { $0.targetNodeId == p.id })
            let textFlightSource = textFlightTarget == nil
                ? activeTextFlights.first(where: { FlightSelector.selects($0.state.sourceKey, path: snap.path, key: snap.key) })
                : nil
            let own = ownById[p.id]
            let ownRaw = own?.rect ?? p.rect
            let appliedDelta = (el.layoutAnim?.travel == .screen) ? inh.offsetDelta : inh.fullDelta
            let rawRect = ownRaw.offsetBy(appliedDelta)
            var trailingMoved = false
            if el.isRideTrailing, let dw = inh.parentDrawnWidth, let tw = inh.parentTargetWidth {
                let shift = dw - tw
                if abs(shift) * pxScale > 1.0 / 32.0 {
                    // `SceneTrailing.swift` already applies the parent width delta to `p.rect`.
                    trailingMoved = inh.parentMoving
                }
            }

            let ownSc = own?.scale ?? Vec2(1, 1)
            let rawScaleVec = Vec2(inh.scale.x * ownSc.x, inh.scale.y * ownSc.y)
            let origin = (el.runtimeExtra("scaleOrigin") != nil)
                ? el.scaleOrigin
                : (snap.anchorAttachNorm ?? el.origin)
            let centre = SIMD2<Float>(
                rawRect.left + origin.x * rawRect.width,
                rawRect.top + origin.y * rawRect.height
            )
            let centreTo = SIMD2<Float>(
                inh.anchorTo.x + (centre.x - inh.anchor.x) * inh.scale.x,
                inh.anchorTo.y + (centre.y - inh.anchor.y) * inh.scale.y
            )
            let hasOwnScale = abs(ownSc.x - 1.0) > 1e-5 || abs(ownSc.y - 1.0) > 1e-5
            let (anchor, anchorTo) = hasOwnScale ? (centre, centreTo) : (inh.anchor, inh.anchorTo)

            var scaledRawRect: MotionRect
            if abs(rawScaleVec.x - 1.0) > 1e-5 || abs(rawScaleVec.y - 1.0) > 1e-5 || anchor != anchorTo {
                scaledRawRect = MotionRect(
                    left: anchorTo.x + (rawRect.left - anchor.x) * rawScaleVec.x,
                    top: anchorTo.y + (rawRect.top - anchor.y) * rawScaleVec.y,
                    right: anchorTo.x + (rawRect.right - anchor.x) * rawScaleVec.x,
                    bottom: anchorTo.y + (rawRect.bottom - anchor.y) * rawScaleVec.y
                )
            } else {
                scaledRawRect = rawRect
            }

            // Land sub-1/32 px size residuals before snapping edges (`build.rs:396`).
            if abs(rawScaleVec.x - 1.0) <= 1e-5 {
                let tw = PixelSnap.snapPx(snap.targetRect.width, scale: pxScale) / pxScale
                if abs(scaledRawRect.width - tw) * pxScale < 1.0 / 32.0 {
                    scaledRawRect = MotionRect(left: scaledRawRect.left, top: scaledRawRect.top, right: scaledRawRect.left + tw, bottom: scaledRawRect.bottom)
                }
            }
            if !p.isExiting && abs(rawScaleVec.y - 1.0) <= 1e-5 {
                let th = PixelSnap.snapPx(snap.targetRect.height, scale: pxScale) / pxScale
                if abs(scaledRawRect.height - th) * pxScale < 1.0 / 32.0 {
                    scaledRawRect = MotionRect(left: scaledRawRect.left, top: scaledRawRect.top, right: scaledRawRect.right, bottom: scaledRawRect.top + th)
                }
            }
            let ownOp = own?.opacity ?? p.opacity
            let preLoopOwnOp = own?.preLoopOpacity ?? ownOp
            let groupFactor = resolveGroupOpacityFactor(
                nodeId: p.id, group: el.groupOpacity, nodePath: snap.path,
                inheritedGroupFrac: nearestGroupHoverFrac, sampledRest: scene.get(p.id, Props.GROUP_REST)
            )
            let departingText = textFlightSource.map {
                $0.state.alphas(target: $0.state.destination, now: now, reducedMotion: reducedMotion).source > 0
            } ?? false
            let revealFactor: Float = {
                guard let span = el.stickyConfig?.reveal else { return 1.0 }
                return StickyMath.stuckRevealFactor(parentShift: input.parentStickyMag, span: span)
            }()
            let alpha = (ownOp * ancestorOpacity * groupFactor * input.kidsFadeOpacity * revealFactor).clamped(to: 0...1)
            let logicalAlpha = (ownOp * logicalAncestorOpacity * groupFactor * input.kidsFadeOpacity * revealFactor).clamped(to: 0...1)
            let baseLogicalAlpha = (preLoopOwnOp * logicalAncestorOpacity * groupFactor * input.kidsFadeOpacity * revealFactor).clamped(to: 0...1)
            var rect: MotionRect
            let scaleVec: Vec2
            if let fc = flightCover {
                rect = MotionRect.fromXYWH(
                    fc.presentedOrigin.x + (scaledRawRect.x - fc.targetOrigin.x) * fc.scale,
                    fc.presentedOrigin.y + (scaledRawRect.y - fc.targetOrigin.y) * fc.scale,
                    scaledRawRect.width * fc.scale,
                    scaledRawRect.height * fc.scale
                )
                scaleVec = Vec2(rawScaleVec.x * fc.scale, rawScaleVec.y * fc.scale)
            } else {
                rect = scaledRawRect
                scaleVec = rawScaleVec
            }
            let (stickyShift, stickyMag): (Vec2, Float) = {
                if !needsStickyPlacement || (el.anchor != nil && !snap.isSticky) {
                    return (.zero, 0)
                }
                if !p.isExiting && snap.index < flatNodes.count && flatNodes[snap.index].nodeId == snap.nodeId {
                    return preStickyById[snap.nodeId] ?? computePaintStickyShift(
                        nodeIndex: snap.index,
                        parentStickyShift: input.parentStickyShift,
                        presentedRectByNodeId: presentedRectById,
                        ownLiveOffset: stickyOwnLiveOffsetById[p.id] ?? .zero
                    )
                }
                return (input.parentStickyShift, input.parentStickyMag)
            }()
            if needsStickyPlacement, let a = el.anchor,
               !snap.isSticky,
               let aNode = flatNodes.first(where: { $0.key == a.key }) {
                let aShift = preStickyById[aNode.nodeId]?.shift ?? stuckShiftsByPath[aNode.path] ?? .zero
                if aShift != .zero, let aPres = preStickyRectById[aNode.nodeId] ?? presentedRectById[aNode.nodeId] {
                    let aParentScale = aNode.parentIndex.flatMap { flatNodes.indices.contains($0) ? flatNodes[$0].inheritedScale : nil } ?? 1.0
                    let placement = AnchorLayoutHelper.zoomedPlacement(
                        anchor: a,
                        triggerZoomed: aPres,
                        anchorScale: aParentScale,
                        localSize: Vec2(rect.width, rect.height),
                        overlayOwnScale: el.scale,
                        hasScaleTrack: anchoredOverlayHasScaleTrack(el, nodeId: p.id),
                        viewport: viewport
                    )
                    rect = MotionRect.fromXYWH(placement.unscaledOrigin.x, placement.unscaledOrigin.y, rect.width, rect.height)
                }
            } else if stickyShift != .zero {
                rect = MotionRect.fromXYWH(
                    rect.x + stickyShift.x,
                    rect.y + stickyShift.y,
                    rect.width,
                    rect.height
                )
            }
            stuckShiftsByPath[snap.path] = stickyShift
            presentedRectById[p.id] = rect
            presentedScaleById[p.id] = scaleVec
            let effRotate = own?.rotation ?? p.rotate

            let ownHasTurn = abs(effRotate) > 1e-6
            let nodeTurn: Turn?
            if ownHasTurn {
                let pivot = Vec2(rect.x + rect.width * el.origin.x, rect.y + rect.height * el.origin.y)
                let localTurn = Turn.about(pivot, radians: effRotate)
                nodeTurn = ancestorTurn.map { $0.after(localTurn) } ?? localTurn
            } else {
                nodeTurn = ancestorTurn
            }

            let parentWindowClip: MotionRect = flightClipOverride
                ?? inh.clip.map { intersectRects(MotionRect.fromXYWH(0, 0, viewport.x, viewport.y), $0) }
                ?? snap.clipRect
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
            if let t = nodeTurn {
                newTurnByPath[snap.path] = t
            }
            newPaintOrder.append(snap.path)
            let ownSpatialMoving =
                paintMotion.spatial.contains(p.id) ||
                liveSpatialSpringingById.contains(p.id) ||
                (!el.layout.scrollAxes.isEmpty && scrollStore.isMoving(NodeId.hash("scroll:" + snap.path), Props.SCROLL))
            let nodeRectSpringing = inh.rectSpringing || ownSpatialMoving
            let drawnRect = nodeTurn?.bbox(rect) ?? rect
            if !p.isExiting {
                newDrawnRectByPath[snap.path] = drawnRect
                newRectSpringingById[p.id] = nodeRectSpringing
            }

            var fillColor: Color
            if let pf = p.fill {
                let isPressedNode = isNodePressedVisually(path: snap.path, effectiveInert: snap.effectiveInert || p.isExiting)
                let effFill = (isPressedNode ? el.pressBg.map { blendColorOver(bottom: el.background, top: $0, srgb: srgbBlend) } : nil) ?? el.background
                let settledMatch = !scene.store.isMoving(p.id, Props.FILL)
                    && abs(pf.r - effFill.r) < 1e-3
                    && abs(pf.g - effFill.g) < 1e-3
                    && abs(pf.b - effFill.b) < 1e-3
                    && abs(pf.a - effFill.a) < 1e-3
                fillColor = (settledMatch || pf == effFill.motionColor) ? effFill : Color(pf)
            } else {
                fillColor = el.background
            }
            var borderColor: Color
            if let pb = p.border {
                let settledBorder = !scene.store.isMoving(p.id, Props.BORDER) && !scene.store.isMoving(p.id, Props.BORDER_BOTTOM)
                    && abs(pb.r - el.borderColor.r) < 1e-3
                    && abs(pb.g - el.borderColor.g) < 1e-3
                    && abs(pb.b - el.borderColor.b) < 1e-3
                    && abs(pb.a - el.borderColor.a) < 1e-3
                borderColor = (settledBorder || pb == el.borderColor.motionColor) ? el.borderColor : Color(pb)
            } else {
                borderColor = el.borderColor
            }
            var liveTextColor: Color? = nil
            var liveShadowColor: Color? = nil
            var liveGradientTop: Color? = nil
            var liveGradientBottom: Color? = nil
            let sceneTextColor: Color? = scene.store.get(p.id, Props.TEXT_COLOR).map { st in
                if let targetText = el.textColor,
                   !scene.store.isMoving(p.id, Props.TEXT_COLOR),
                   abs(st.r - targetText.r) < 1e-3,
                   abs(st.g - targetText.g) < 1e-3,
                   abs(st.b - targetText.b) < 1e-3,
                   abs(st.a - targetText.a) < 1e-3 {
                    return targetText
                }
                return Color(st)
            }
            var blurPt = p.blur
            var liveTrim: Vec2? = nil
            for b in el.liveBindings {
                let lnid = NodeId.hash("live:\(snap.path):\(b.target)")
                if b.target == .fill {
                    fillColor = presentedLiveColor(lnid) ?? fillColor
                } else if b.target == .textColor {
                    liveTextColor = presentedLiveColor(lnid)
                } else if b.target == .borderColor {
                    borderColor = presentedLiveColor(lnid) ?? borderColor
                } else if b.target == .shadowColor {
                    liveShadowColor = presentedLiveColor(lnid)
                } else if b.target == .gradientTop {
                    liveGradientTop = presentedLiveColor(lnid)
                } else if b.target == .gradientBottom {
                    liveGradientBottom = presentedLiveColor(lnid)
                } else if b.target == .blur, let bl = liveStore.get(lnid, Props.BLUR) {
                    blurPt = bl.radius
                } else if b.target == .trim, let tr = liveStore.get(lnid, Props.OFFSET) {
                    liveTrim = tr
                }
            }

            var visClip = flightClipOverride
                ?? inh.clip.map { intersectRects(snap.clipRect, $0) }
                ?? snap.clipRect
            if let rev = p.revealClip {
                visClip = intersectRects(visClip, rev)
            }
            let visibleRect = intersectRects(visClip, rect)
            if el.pressScaleFactor != nil {
                let pressSc = pressScaleValue(for: p.id)
                let restingRect: MotionRect
                if abs(pressSc - 1.0) > 1e-5 {
                    restingRect = MotionRect(
                        left: anchorTo.x + (rect.left - anchorTo.x) / pressSc,
                        top: anchorTo.y + (rect.top - anchorTo.y) / pressSc,
                        right: anchorTo.x + (rect.right - anchorTo.x) / pressSc,
                        bottom: anchorTo.y + (rect.bottom - anchorTo.y) / pressSc
                    )
                } else {
                    restingRect = rect
                }
                recordPressRestingHit(path: snap.path, rect: restingRect, clip: visClip, turn: p.rotate)
            }

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
            let isPressed = isNodePressedVisually(path: snap.path, effectiveInert: snap.effectiveInert || p.isExiting)
            let (effPressColor, effPressFrac): (Color?, Float) = {
                if let pc = el.pressColor {
                    let frac = (liveStore.get(Self.pressTrackId(p.id), Self.pressProp) ?? (isPressed ? 1.0 : 0.0)).clamped(to: 0...1)
                    return (pc, frac)
                }
                return (input.nearestPressColor, input.nearestPressFrac)
            }()
            let flatFocusWithin = el.focusWithinFlat && !snap.effectiveInert && !p.isExiting && isFocusWithin(snap.path)
            let hoverFrac: Float = {
                if flatFocusWithin { return 0.0 }
                if lastHoverTargetById[p.id] != nil {
                    return (liveStore.get(Self.hoverTrackId(p.id), Self.hoverProp) ?? 0).clamped(to: 0...1)
                }
                if el.isHoverGroup || el.hoverGroupShare != nil {
                    return (!p.isExiting && isGroupHovered(snap)) ? 1.0 : 0.0
                }
                return isHovered ? 1.0 : 0.0
            }()
            if !flatFocusWithin, !(isPressed && el.pressBg != nil), let hBg = el.hoverBg, hoverFrac > 0.0005 {
                fillColor = blendColorOver(bottom: fillColor, top: hBg.scaleAlpha(hoverFrac), srgb: srgbBlend)
            }
            let carriedScrolled = carriedScroll(for: snap, scale: { newScaleByPath[$0] }, cache: &carriedScrollCache) { newTurnByPath[$0] }
            let scrolled: Vec2 = {
                if !el.layout.scrollAxes.isEmpty {
                    let offset = scrollOffsets[snap.path] ?? .zero
                    return Vec2(offset.x, offset.y + (slice2State.scrollExtraYByPath[snap.path] ?? 0))
                }
                return carriedScrolled
            }()

            // Compute resting rect for PixelSnap motion tracking (`build.rs:435-445`)
            let ownRestOff = Vec2(ownRaw.left - p.rect.left, ownRaw.top - p.rect.top)
            let nodeRestOffset = Vec2(inh.restOffset.x + el.offset.x + ownRestOff.x, inh.restOffset.y + el.offset.y + ownRestOff.y)
            let rawRestRect = snap.targetRect.offsetBy(nodeRestOffset)

            let loopSlideMoving = loopRuntime.isSlideActive(id: p.id, nodeTime: scene.store.nodeTime(p.id), reducedMotion: reducedMotion)
            let nodeMoving = p.isMoving || inh.parentMoving || trailingMoved || liveMovedById.contains(p.id) || loopSlideMoving
            let rExact = PixelSnap.edgesPx(rect, scale: pxScale)
            let rawEdgesPx = PixelSnap.edgesPx(rawRect, scale: pxScale)
            let ownStickyDelta = (el.anchor != nil && !snap.isSticky)
                ? SIMD2<Float>.zero
                : SIMD2<Float>(stickyShift.x - input.parentStickyShift.x, stickyShift.y - input.parentStickyShift.y)
            var boxSnap = inh.snap
            var rowGlideY = inh.rowGlideY
            // A detached anchor has already established a new translation for its subtree.
            if resolvedAnchor == nil {
                let dy = growthSnapOffsetY(for: snap)
                boxSnap.grow(dy)
                if el.growthSpec == nil { rowGlideY += dy }
            }
            boxSnap.scroll(0, by: ownStickyDelta.x)
            boxSnap.scroll(1, by: ownStickyDelta.y)
            let rigidPx = boxSnap.rigid * pxScale
            let canSnap = !inh.snap.off && el.isPixelSnapEnabled && abs(p.rotate) < 1e-6
            let filterMargin = (input.ancestorBlur + blurPt * scaleVec.x) * pxScale * 3.0 + 2.0
            let snaps = canSnap && (el.isolatedLayer || (
                max(rExact[2], rExact[0]) >= max(visClip.left * pxScale, 0) - filterMargin
                && rExact[0] <= min(visClip.right * pxScale, Float(devW)) + filterMargin
                && max(rExact[3], rExact[1]) >= max(visClip.top * pxScale, 0) - filterMargin
                && rExact[1] <= min(visClip.bottom * pxScale, Float(devH)) + filterMargin
            ))
            let unscaled = abs(scaleVec.x - 1.0) <= 1e-5 && abs(scaleVec.y - 1.0) <= 1e-5 && anchor == anchorTo
            let ownScaleSpringMoving = paintMotion.unheldScale.contains(p.id)
                && scene.store.nodeTimeScale(p.id) > 0
            let ownLiveScaleMoving = el.liveBindings.contains(where: { b in
                b.target == .scale
                    && (liveStore.isMoving(NodeId.hash("live:\(snap.path):\(b.target)"), Props.SCALE) || isLinearTweenActive(b.source))
            })
            let ownSequenceScaleMoving: Bool = {
                guard let entry = loopRuntime.entries[p.id],
                      case .sequence = entry.kind,
                      let track = loopRuntime.tracks[p.id] else { return false }
                return scene.store.nodeTimeScale(p.id) > 0 && track.isActive(at: scene.store.nodeTime(p.id))
            }()
            let nodeScaleMotion = textScaleMotion(
                node: p.id, local: ownSc.x, world: scaleVec.x, inherited: inh.scaleMotion,
                live: el.liveBindings.contains(where: { $0.target == .scale }), anchored: el.anchor != nil,
                animating: ownScaleSpringMoving || ownLiveScaleMoving || ownSequenceScaleMoving, at: now)
            nodeScaleMotionById[p.id] = nodeScaleMotion
            let textRasterScale = nodeScaleMotion.raster(sc: scaleVec.x, rest: inh.stillScale)
            let isAnchoredOverlay = el.anchor != nil
            let isGrowthRow = growthRows["growth:\(snap.path)"] != nil || growthRows["fold:\(snap.path)"] != nil
            let opensSnapLayer = hasOwnScale || (isAnchoredOverlay && !unscaled)
            let snapLayer = (canSnap && opensSnapLayer)
                ? pixelSnapGlides.layer(id: p.id, r: rExact, unscaled: rawEdgesPx, rigid: rigidPx, cached: el.isolatedLayer)
                : inh.snap.layer
            let steps = inh.snap.steps || el.motionSnapsEnabled
            let restForMotion: MotionRect?
            if !snaps || !nodeMoving || steps {
                restForMotion = nil
            } else if rowGlideY != 0 {
                // A growth row's fractional projection already travels in rigid. Only a real
                // scene track contributes a further glide to the box it carries.
                restForMotion = scene.rest(p.id)
            } else {
                restForMotion = rawRestRect
            }
            let gliding = snaps && (restForMotion != nil || !unscaled)
            let (snappedEdgesPx, snapRest): (SIMD4<Float>, PixelSnap.Parent?)
            if !snaps {
                (snappedEdgesPx, snapRest) = (rExact, nil)
            } else if restForMotion == nil && unscaled {
                (snappedEdgesPx, snapRest) = pixelSnapGlides.atRest(id: p.id, r: rExact, rigid: rigidPx, parent: inh.snap.parent)
            } else {
                let mot = PixelSnap.motion(rect: rawRect, rest: restForMotion, scale: pxScale, anchored: isAnchoredOverlay, growthRow: isGrowthRow)
                let rawArg = unscaled ? rExact : rawEdgesPx
                let avgScale = (scaleVec.x + scaleVec.y) * 0.5
                (snappedEdgesPx, snapRest) = pixelSnapGlides.snapped(
                    id: p.id,
                    motion: mot,
                    r: rExact,
                    unscaled: rawArg,
                    rigid: rigidPx,
                    layer: snapLayer,
                    scale: avgScale,
                    parent: inh.snap.parent
                )
            }
            // An `El.offset` here or above: its text moves with its box (`Inherit::shifted`, #963).
            let snapShifted = inh.snap.shifted || el.offset.x != 0 || el.offset.y != 0
            // Its exact resting place against its snapped one, inside its containment's own rounding
            // (`LeafBox::exact_off`, #935).
            let textExactOffPx = TextBoxGeometry.leafExactOff(rest: snapRest, rigid: boxSnap.steady * pxScale, containPx: boxSnap.contain * pxScale, shifted: snapShifted)

            var caretOut: [Float]? = nil
            var textTruncated = false
            let editValue: TextEdit? = el.handlers.editLens.map { lens in
                var e = lens.get(state)
                if el.isSecure {
                    e.isSecure = true
                    if let rev = el.revealedOverride { e.isRevealed = rev }
                }
                return e
            }
            let nodeIsSecure = el.isSecure || (editValue?.isSecure ?? false)
            let rawTextValue: String? = editValue?.text ?? el.plainText
            // Never expose secure plaintext (hidden or revealed) in ElementInfo / --tree snapshots.
            let elementTextValue: String? = nodeIsSecure ? nil : rawTextValue
            var elementDrawnText: String? = nil
            var elementElision: TextElision? = nil
            let paintedLabelValue: String? = {
                guard let raw = el.plainText else { return nil }
                if nodeIsSecure && !el.isRevealed && !raw.isEmpty && !(p.isExiting && el.role == .textInput) {
                    return "••••••••••••"
                }
                return raw
            }()

            let totalShapePieces = el.shapes.reduce(0) { $0 + $1.pieceCount }
            let layerOp = el.elLayerOpacity
            let paintAlphaTotal = (alpha * layerOp).clamped(to: 0...1)
            let hasChildren = !(childrenByParent[p.id]?.isEmpty ?? true)
            let ownPaints = ShellSliceRenderHelpers.countOwnPaints(
                el,
                hasText: paintedLabelValue != nil || el.richSpans != nil,
                totalShapePieces: totalShapePieces
            )
            let ownPaintOpacity = ownOp * groupFactor * layerOp
            let opacityNeedsLayer = alpha > 0.001 && ownPaintOpacity > 0.001 && ownPaintOpacity < 1
                && (hasChildren || totalShapePieces > 1 || (el.iconPayload != nil && fillColor.a > 0.001)
                    || (layerOp < 1 && ownPaints >= 2))
            let useLayer = blurPt >= 0.5 || el.isolatedLayer || opacityNeedsLayer
            let devClip = SIMD4<Float>(
                visClip.left * pxScale,
                visClip.top * pxScale,
                visClip.width * pxScale,
                visClip.height * pxScale
            )
            let resolvedNodeShadows = resolvedShadows(for: p.id, authored: el.shadows)
            let paintMargin = resolvedNodeShadows.reduce(filterMargin) {
                max($0, ($1.blur * 3.0 + max($1.spread, 0) + max(abs($1.x), abs($1.y))) * pxScale + 2.0)
            }
            let effBlur = input.ancestorBlur + blurPt * scaleVec.x
            let isActiveFlight = activeFlightIds.contains(p.id)
                || launchedFlightIds.contains(p.id)
                || unclippedMatchedFlightIds.contains(p.id)
                || (el.flightId != nil && scene.isEdgeAnimating(p.id))
            let onScreenForEmit = el.isolatedLayer || isActiveFlight || (
                max(rExact[2], rExact[0]) >= max(visClip.left * pxScale, 0) - paintMargin
                && rExact[0] <= min(visClip.right * pxScale, Float(devW)) + paintMargin
                && max(rExact[3], rExact[1]) >= max(visClip.top * pxScale, 0) - paintMargin
                && rExact[1] <= min(visClip.bottom * pxScale, Float(devH)) + paintMargin
            )
            let shouldEmit = logicalAlpha > 0.001 && alpha > 0.001 && visClip.width > 0 && visClip.height > 0 && onScreenForEmit
            let surfaceVisible = shouldEmit && visibleRect.width > 0 && visibleRect.height > 0
            let geometricallyInView = isNodeInViewForUnseen(el: el, isActiveFlight: isActiveFlight, visibleRect: visibleRect)
            kitHooks.unseenPresence.recordFrameNode(
                p, visible: visClip.width > 0 && visClip.height > 0 && onScreenForEmit,
                inView: logicalAlpha >= (1.0 / 512.0) && geometricallyInView,
                geometricallyInView: geometricallyInView,
                inhOpacity: p.isExiting ? (el.opacity * ancestorOpacity * groupFactor).clamped(to: 0...1) : alpha,
                drawn: drawnRect,
                ownStickyShift: Vec2(ownStickyDelta.x, ownStickyDelta.y)
            )
            if liveVisible && !reducedMotion && !nodeExiting && baseLogicalAlpha >= (1.0 / 255.0),
               let track = loopRuntime.tracks[p.id] {
                let loopOff = ownLoopOffsetById[p.id] ?? .zero
                let homeRect: MotionRect = {
                    switch track.spec.kind {
                    case .slide, .slideEased:
                        return MotionRect.fromXYWH(rect.x - loopOff.x, rect.y - loopOff.y, rect.width, rect.height)
                    default:
                        return rect
                    }
                }()
                let homePx = PixelSnap.edgesPx(homeRect, scale: pxScale)
                let loopVis: Bool = {
                    if let t = nodeTurn {
                        guard effectiveHitClip.width > 0 && effectiveHitClip.height > 0
                                && effectiveOuterClip.width > 0 && effectiveOuterClip.height > 0 else {
                            return false
                        }
                        let sh = t.bbox(homeRect)
                        let shPx = PixelSnap.edgesPx(sh, scale: pxScale)
                        let lcPx = PixelSnap.edgesPx(effectiveHitClip, scale: pxScale)
                        let ocPx = PixelSnap.edgesPx(effectiveOuterClip, scale: pxScale)
                        return homePx[2] > lcPx[0] - filterMargin && homePx[0] < lcPx[2] + filterMargin
                            && homePx[3] > lcPx[1] - filterMargin && homePx[1] < lcPx[3] + filterMargin
                            && shPx[2] > max(ocPx[0], -filterMargin) && shPx[0] < min(ocPx[2], Float(devW) + filterMargin)
                            && shPx[3] > max(ocPx[1], -filterMargin) && shPx[1] < min(ocPx[3], Float(devH) + filterMargin)
                    } else {
                        guard visClip.width > 0 && visClip.height > 0 else { return false }
                        let clipPx = PixelSnap.edgesPx(visClip, scale: pxScale)
                        return homePx[2] > max(clipPx[0], -filterMargin) && homePx[0] < min(clipPx[2], Float(devW) + filterMargin)
                            && homePx[3] > max(clipPx[1], -filterMargin) && homePx[1] < min(clipPx[3], Float(devH) + filterMargin)
                    }
                }()
                if loopVis {
                    schedulePaintedLoop(track, id: p.id)
                }
            }

            let devRect = SIMD4<Float>(
                snappedEdgesPx[0],
                snappedEdgesPx[1],
                max(0, snappedEdgesPx[2] - snappedEdgesPx[0]),
                max(0, snappedEdgesPx[3] - snappedEdgesPx[1])
            )

            let activeFadeEdges: [(fade: SIMD4<Float>, origin: SIMD2<Float>)] = {
                guard !snap.activeClipFades.isEmpty else { return [] }
                let effectiveFades: [EdgeFadeSpec]
                if let stickyEdge = el.stickyConfig?.edge {
                    effectiveFades = snap.activeClipFades.map { spec in
                        guard spec.scrollPath != nil, !spec.belowSticky else { return spec }
                        var copy = spec
                        switch stickyEdge {
                        case .left: copy.widths.x = 0
                        case .top: copy.widths.y = 0
                        case .bottom: copy.widths.w = 0
                        }
                        return copy
                    }
                } else {
                    effectiveFades = snap.activeClipFades
                }
                let primRect = SIMD4<Float>(rect.x * pxScale, rect.y * pxScale, rect.width * pxScale, rect.height * pxScale)
                return AnchorLayoutHelper.edgeFadeEdges(
                    specs: slice2State.joinedRowsWithoutRevealMask.isEmpty ? effectiveFades : effectiveFades.compactMap { fade in
                        guard let id = fade.growthRow, slice2State.joinedRowsWithoutRevealMask.contains(id) else { return fade }
                        guard let authored = fade.authoredFade else { return nil }
                        var restored = fade
                        restored.widths = authored
                        return restored
                    },
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
                surfaceVideo.snapshot(surf, path: snap.path)
                if !surfaceVisible { surfaceVideo.unpulled(surf) }
            }

            let continuousCorners = (el.runtimeExtra(RenderExtrasKey.continuousCorners) as? Bool) == true
            if shouldEmit {
                if fillColor.a <= 0, let material = el.attachedSystemMaterial {
                    let tint = MaterialMath.fallbackFill(material: material, dark: systemDark)
                    fillColor = Color(r: tint.x, g: tint.y, b: tint.z, a: tint.w)
                }
                let devRadii = SIMD4<Float>(
                    p.corners.topLeft * pxScale * flightScale,
                    p.corners.topRight * pxScale * flightScale,
                    p.corners.bottomRight * pxScale * flightScale,
                    p.corners.bottomLeft * pxScale * flightScale
                ).withContinuousCorners(continuousCorners)

                // Sample the parent target before opening this element’s opacity or filter layers.
                let backdropOpacity = paintAlphaTotal * el.elPaintAlpha
                if el.backdropBlur > 0, backdropBlurCount < MAX_BACKDROP_BLURS, backdropOpacity > 0.001 {
                    backdropBlurCount += 1
                    primitives.append(Primitive(
                        rect: devRect,
                        radii: devRadii,
                        fill: SIMD4(0, 0, 0, backdropOpacity),
                        params: SIMD4<Float>(el.backdropBlur * scaleVec.x * pxScale, Float(PrimitiveKind.backdropBlur.rawValue), 0, scaleVec.x * pxScale),
                        clip: devClip
                    ))
                }

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
                        opacity: paintAlphaTotal,
                        blurRadius: blurPt * pxScale,
                        clip: devClip,
                        turn: effRotate
                    ))
                }
                let localAlpha: Float = ((useLayer ? 1.0 : paintAlphaTotal) * el.elPaintAlpha).clamped(to: 0...1)

                // 1. Outer drop shadows
                let stuckShadowFactor = (el.stickyConfig != nil) ? StickyMath.stuckShadowFactor(shift: stickyMag) : 0.0
                if !flatFocusWithin {
                    for (sIdx, sh) in resolvedNodeShadows.enumerated() where !sh.inset {
                        let sceneShColor: Color? = sIdx < shadowColorProps.count ? scene.store.get(p.id, shadowColorProps[sIdx]).map { sc in
                            let settled = !scene.store.isMoving(p.id, shadowColorProps[sIdx])
                                && abs(sc.r - sh.color.r) < 1e-3
                                && abs(sc.g - sh.color.g) < 1e-3
                                && abs(sc.b - sh.color.b) < 1e-3
                                && abs(sc.a - sh.color.a) < 1e-3
                            return (settled || sc == sh.color.motionColor) ? sh.color : Color(sc)
                        } : nil
                        let shColor = (sIdx == 0 ? liveShadowColor : nil) ?? sceneShColor ?? sh.color
                        guard shColor.a > 0.001 else { continue }
                        let sc = shColor.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
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
                }
                if stuckShadowFactor > 0.001, let stuckShadows = el.stickyConfig?.shadows {
                    for sh in stuckShadows where !sh.inset && sh.color.a > 0.001 {
                        let sc = sh.color.scaleAlpha(localAlpha * stuckShadowFactor).simd4(srgb: srgbBlend)
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
                }

                // 2. Box background / gradient / solid border
                let highlightActive = isFocused && (focusVisible || (el.focusHighlightColor != nil && hoveredHighlightActive))
                let activeFocusFill = highlightActive ? (el.focusFillColor ?? el.focusHighlightColor) : nil
                let hasFill = fillColor.a > 0.0005 || (activeFocusFill != nil)
                let hasSolidBorder = el.dashedBorder == nil && borderColor.a > 0.0005 && (el.borderWidth > 0 || el.borderSides != nil)

                if let grad = el.gradient {
                    switch grad {
                    case let .linear(topC, botC, angle):
                        primitives.append(.linearGradient(
                            rect: devRect,
                            radii: devRadii,
                            topColor: (liveGradientTop ?? topC).scaleAlpha(localAlpha).simd4(srgb: srgbBlend),
                            bottomColor: (liveGradientBottom ?? botC).scaleAlpha(localAlpha).simd4(srgb: srgbBlend),
                            angleRadians: angle,
                            clip: devClip,
                            turn: useLayer ? 0 : p.rotate
                        ))
                    case let .radial(inC, outC):
                        primitives.append(.radialGradient(
                            rect: devRect,
                            radii: devRadii,
                            innerColor: (liveGradientTop ?? inC).scaleAlpha(localAlpha).simd4(srgb: srgbBlend),
                            outerColor: (liveGradientBottom ?? outC).scaleAlpha(localAlpha).simd4(srgb: srgbBlend),
                            clip: devClip
                        ))
                    }
                }

                let highlightedMenu = isHighlightedMenuNode(snap, isFocused: isFocused)
                let effectiveFocusFill = activeFocusFill ?? (highlightedMenu ? el.focusHighlightColor : nil)
                let effectiveBoxFill = effectiveFocusFill ?? fillColor
                // Kept out of `emitNodeEnter`'s frame (`@inline(never)`) so the text path's stack stays
                // under the 512 KB test thread in debug builds.
                @inline(never) func emitSurfacePayloadSection() {
                    if let (surf, fit) = el.surfacePayload, surfaceVisible {
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
                        surfaceVideo.pull(surf, at: now, wallTime: currentTime, waker: waker)
                        builtSurfaces.append(SurfaceDraw(
                            surface: surf.placed(el.surfacePlace),
                            fit: fit,
                            beforeInstance: UInt32(primitives.count),
                            rect: devRect,
                            radii: devRadii,
                            clip: SIMD4<Float>(devClip.x, devClip.y, devClip.x + devClip.z, devClip.y + devClip.w),
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
                        let borderScale = (scaleVec.x + scaleVec.y) * 0.5
                        let sidePx = el.borderSides.map { s in
                            SIMD4<Float>(
                                snapBorderWidthPx(s.top, scale: pxScale) * borderScale,
                                snapBorderWidthPx(s.right, scale: pxScale) * borderScale,
                                snapBorderWidthPx(s.bottom, scale: pxScale) * borderScale,
                                snapBorderWidthPx(s.left, scale: pxScale) * borderScale
                            )
                        }
                        let bwPx = el.borderWidth > 0 ? snapBorderWidthPx(el.borderWidth, scale: pxScale) * borderScale : 0
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
                    } else if let hl = effectiveFocusFill {
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
                }
                emitSurfacePayloadSection()

                // 3. Dashed border ring
                if let dash = el.dashedBorder, borderColor.a > 0.0005 {
                    let borderScale = (scaleVec.x + scaleVec.y) * 0.5
                    primitives.append(.dashedRing(
                        rect: devRect,
                        radii: devRadii,
                        color: borderColor.scaleAlpha(localAlpha).simd4(srgb: srgbBlend),
                        borderWidth: snapBorderWidthPx(el.borderWidth, scale: pxScale) * borderScale,
                        dashLength: dash.dash * pxScale,
                        gapLength: dash.gap * pxScale,
                        phase: dash.phase * pxScale,
                        clip: devClip
                    ))
                }

                // 4. Inset shadows
                if !flatFocusWithin {
                    for (sIdx, sh) in resolvedNodeShadows.enumerated() where sh.inset {
                        let sceneShColor: Color? = sIdx < shadowColorProps.count ? scene.store.get(p.id, shadowColorProps[sIdx]).map { sc in
                            let settled = !scene.store.isMoving(p.id, shadowColorProps[sIdx])
                                && abs(sc.r - sh.color.r) < 1e-3
                                && abs(sc.g - sh.color.g) < 1e-3
                                && abs(sc.b - sh.color.b) < 1e-3
                                && abs(sc.a - sh.color.a) < 1e-3
                            return (settled || sc == sh.color.motionColor) ? sh.color : Color(sc)
                        } : nil
                        let shColor = (sIdx == 0 ? liveShadowColor : nil) ?? sceneShColor ?? sh.color
                        guard shColor.a > 0.001 else { continue }
                        primitives.append(.insetShadow(
                            rect: devRect,
                            radii: devRadii,
                            color: shColor.scaleAlpha(localAlpha).simd4(srgb: srgbBlend),
                            blur: sh.blur * pxScale,
                            spread: sh.spread * pxScale,
                            offset: SIMD2<Float>(sh.x * pxScale, sh.y * pxScale),
                            clip: devClip
                        ))
                    }
                }
                if stuckShadowFactor > 0.001, let stuckShadows = el.stickyConfig?.shadows {
                    for sh in stuckShadows where sh.inset && sh.color.a > 0.001 {
                        primitives.append(.insetShadow(
                            rect: devRect,
                            radii: devRadii,
                            color: sh.color.scaleAlpha(localAlpha * stuckShadowFactor).simd4(srgb: srgbBlend),
                            blur: sh.blur * pxScale,
                            spread: sh.spread * pxScale,
                            offset: SIMD2<Float>(sh.x * pxScale, sh.y * pxScale),
                            clip: devClip
                        ))
                    }
                }

                // 5. Image payload
                // Kept out of `emitNodeEnter`'s frame (`@inline(never)`) so the text path's stack stays
                // under the 512 KB test thread in debug builds.
                @inline(never) func emitImagePayloadSection() {
                    if let img = el.imagePayload {
                        let region = imagePacker.insert(img)
                        let tint = (el.textColor ?? .white).scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                        primitives.append(.image(
                            rect: devRect,
                            radii: devRadii,
                            uv: region.edges,
                            tint: tint,
                            clip: devClip,
                            turn: useLayer ? 0 : p.rotate,
                            page: region.page
                        ))
                    } else if let px = el.pixelsPayload {
                        if let (region, sz) = placedPixels(px, at: now, visible: surfaceVisible && paintAlphaTotal > 0.001,
                                                       box: devRect, fit: el.pixelsFitMode, place: el.surfacePlace) {
                            let fitted = Runtime.fittedPixelsGeometry(
                                box: devRect,
                                uv: region.edges,
                                imageWidth: Float(sz.width),
                                imageHeight: Float(sz.height),
                                fit: el.pixelsFitMode,
                                place: el.surfacePlace,
                                pixelScale: pxScale
                            )
                            let maxR = min(fitted.rect.z, fitted.rect.w) * 0.5
                            let fittedRadii: SIMD4<Float> = el.pixelsFitMode != nil
                                ? SIMD4<Float>(min(devRadii.x, maxR), min(devRadii.y, maxR), min(devRadii.z, maxR), min(devRadii.w, maxR))
                                : devRadii
                            let tint = Color.white.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                            primitives.append(.image(
                                rect: fitted.rect,
                                radii: fittedRadii,
                                uv: fitted.uv,
                                tint: tint,
                                clip: devClip,
                                turn: useLayer ? 0 : p.rotate,
                                sourceTexelBounds: fitted.uv == region.edges ? .zero : region.edges,
                                page: region.page
                            ))
                        }
                    }
                }
                emitImagePayloadSection()

                let avgScale = (scaleVec.x + scaleVec.y) * 0.5
                let wExact = max(0, rExact[2] - rExact[0])
                let hExact = max(0, rExact[3] - rExact[1])
                let exactSide = min(wExact, hExact)
                let boxGliding = gliding || (snapRest?.left != nil && snapRest!.left != .zero)

                // 6. SVG Icon payload
                // Kept out of `emitNodeEnter`'s frame (`@inline(never)`) so the text path's stack stays
                // under the 512 KB test thread in debug builds.
                @inline(never) func emitIconPayloadSection() {
                    if let (svg, _) = el.iconPayload {
                        let baseIconColor = (nearestGroupHovered ? el.groupColor : nil) ?? liveTextColor ?? sceneTextColor ?? el.textColor ?? defaultViewFg
                        let resolvedColor = applyPressColor(effPressColor, to: baseIconColor, frac: effPressFrac)
                        let animIconTurn = scene.get(p.id, Props.ICON_TURN) ?? el.iconRotation
                        let effGlyphTurn = (useLayer ? 0 : effRotate) + animIconTurn
                        let tint = resolvedColor.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                        let tk = (flightCover != nil) ? Float(1.0) : avgScale
                        let raster = (flightCover != nil) ? Float(1.0) : nodeScaleMotion.raster(sc: avgScale, rest: inh.stillScale)
                        let zoom = tk / max(1e-4, raster)
                        let rawSide = max(0, min(rawRect.width, rawRect.height)) * pxScale
                        let snapU: Float = (flightCover == nil && abs(rawSide - rawSide.rounded()) < 1.0 / 512.0)
                            ? max(0, min(1, 1.0 - abs(avgScale - 1.0) * 32.0))
                            : 0.0
                        let drawn = exactSide + (min(devRect.z, devRect.w) - exactSide) * snapU
                        let px: Int = (flightCover == nil && nodeScaleMotion != .still)
                            ? max(1, Int((rawSide * raster).rounded()))
                            : max(1, Int((drawn / max(1e-4, zoom)).rounded()))
                        let posX = devRect.x + (devRect.z - drawn) * 0.5
                        let posY = devRect.y + (devRect.w - drawn) * 0.5
                        let iconResting = (flightCover == nil)
                            && (nodeScaleMotion == .still)
                            && !boxGliding
                            && abs(effGlyphTurn) <= 1e-6
                            && abs(avgScale - 1.0) < 1e-5
                        if drawn > 1e-4,
                           let colorDecoded = textSystem.colorIcons.rasterize(
                               svg,
                               pixelSize: px,
                               currentColor: resolvedColor,
                               oneColor: el.isIconOneColor ? resolvedColor : nil,
                               mirrored: snap.mirroredInRtl
                           ),
                           let baseMip = colorDecoded.mips.first {
                            let atlas = RGBA8Atlas(width: Int(baseMip.width), height: Int(baseMip.height), texels: [UInt8](baseMip.rgba))
                            let region = imagePacker.insert(atlas)
                            primitives.append(attachFade(.image(
                                rect: SIMD4<Float>(posX, posY, drawn, drawn),
                                radii: .zero,
                                uv: region.edges,
                                tint: Color.white.scaleAlpha(localAlpha).simd4(srgb: srgbBlend),
                                clip: devClip,
                                turn: effGlyphTurn,
                                page: region.page
                            )))
                        } else if iconResting && exactSide > 1e-4 {
                            let canvas = max(1, Int(ceil(exactSide - 1.0 / 64.0)))
                            let containPx = inh.snap.contain * pxScale
                            let atX = PixelSnap.onGrid(rExact[0] + (wExact - exactSide) * 0.5, contain: containPx.x)
                            let atY = PixelSnap.onGrid(rExact[1] + (hExact - exactSide) * 0.5, contain: containPx.y)
                            let entry = textSystem.glyphAtlas.rasterizeIcon(svg, pixelSize: canvas, drawnSize: exactSide, mirrored: snap.mirroredInRtl)
                            let primIdx = primitives.count
                            primitives.append(attachFade(.glyph(
                                rect: SIMD4<Float>(atX, atY, Float(canvas), Float(canvas)),
                                uv: entry.uv,
                                color: tint,
                                gamma: 1.0,
                                clip: devClip,
                                turn: effGlyphTurn
                            )))
                            recordGlyphPage(primIdx, entry.page)
                        } else if drawn > 1e-4 {
                            let entry = textSystem.glyphAtlas.rasterizeIcon(svg, pixelSize: px, mirrored: snap.mirroredInRtl)
                            let pxF = Float(max(1, entry.pixelSize.x))
                            let nearWhole: (Float) -> Bool = { abs($0 - $0.rounded()) < 1.0 / 512.0 }
                            let quadRect: SIMD4<Float>
                            let quadUV: SIMD4<Float>
                            if abs(effGlyphTurn) <= 1e-6 && nearWhole(posX) && nearWhole(posY) && abs(drawn - pxF) < 1.0 / 512.0 {
                                quadRect = SIMD4<Float>(posX.rounded(), posY.rounded(), pxF, pxF)
                                quadUV = entry.uv
                            } else {
                                let t = drawn / pxF
                                let du = (entry.uv.z - entry.uv.x) / pxF
                                let dv = (entry.uv.w - entry.uv.y) / pxF
                                quadRect = SIMD4<Float>(posX - t, posY - t, drawn + 2.0 * t, drawn + 2.0 * t)
                                quadUV = SIMD4<Float>(entry.uv.x - du, entry.uv.y - dv, entry.uv.z + du, entry.uv.w + dv)
                            }
                            let primIdx = primitives.count
                            primitives.append(attachFade(.glyph(
                                rect: quadRect,
                                uv: quadUV,
                                color: tint,
                                gamma: 1.0,
                                clip: devClip,
                                turn: effGlyphTurn
                            )))
                            recordGlyphPage(primIdx, entry.page)
                        }
                    }
                }
                emitIconPayloadSection()

                // 7. Vector Canvas Shapes (triangles & segments)
                let shapeStill = (flightCover == nil)
                    && (nodeScaleMotion == .still)
                    && !boxGliding
                    && abs(avgScale - 1.0) < 1e-5
                let shapeContainPx = inh.snap.contain * pxScale
                let shapeAt = shapeStill
                    ? SIMD2<Float>(
                        PixelSnap.onGrid(rExact[0], contain: shapeContainPx.x),
                        PixelSnap.onGrid(rExact[1], contain: shapeContainPx.y)
                    )
                    : SIMD2<Float>(devRect.x + (devRect.z - wExact) * 0.5, devRect.y + (devRect.w - hExact) * 0.5)
                let drawFrac = p.draw.clamped(to: 0...1)
                let baseTrim = (el.runtimeExtra(RenderExtrasKey.shapeTrim) as? Vec2) ?? liveTrim
                for shape in el.shapes {
                    let effectiveShape: Shape
                    if let t = baseTrim {
                        effectiveShape = shape.trimmed(start: t.x, end: t.x + (t.y - t.x) * drawFrac)
                    } else if drawFrac < 1.0 {
                        effectiveShape = shape.drawn(drawFrac)
                    } else {
                        effectiveShape = shape
                    }
                    let origin: SIMD2<Float>
                    let k: SIMD2<Float>
                    if let vb = effectiveShape.viewBox, vb.x > 0, vb.y > 0 {
                        origin = SIMD2<Float>(devRect.x, devRect.y)
                        k = SIMD2<Float>(devRect.z / vb.x, devRect.w / vb.y)
                    } else {
                        origin = shapeAt
                        k = SIMD2<Float>(scaleVec.x * pxScale, scaleVec.y * pxScale)
                    }
                    let kPx = scaleVec.x * pxScale
                    let transformPoint = { (pt: Vec2) -> SIMD2<Float> in
                        SIMD2<Float>(origin.x + pt.x * k.x, origin.y + pt.y * k.y)
                    }

                    for op in effectiveShape.ops {
                        switch op {
                        case let .fill(points, col):
                            let c4 = applyPressColor(effPressColor, to: col, frac: effPressFrac).scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                            if c4.w <= 0.0005 { continue }
                            for (indices, aaMask) in Shape.triangulate(points) {
                                let v0 = transformPoint(points[indices[0]])
                                let v1 = transformPoint(points[indices[1]])
                                let v2 = transformPoint(points[indices[2]])
                                primitives.append(.triangle(v0: v0, v1: v1, v2: v2, aaMask: aaMask, color: c4, clip: devClip))
                            }
                        case let .stroke(points, closed, width, cap, col):
                            let c4 = applyPressColor(effPressColor, to: col, frac: effPressFrac).scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
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

                // 7b. TerminalGrid (`terminalGridPayload`)
                // Kept out of `emitNodeEnter`'s frame (`@inline(never)`) so the text path's stack stays
                // under the 512 KB test thread in debug builds.
                @inline(never) func emitTerminalGridSection() {
                    if let grid = el.terminalGridPayload {
                        let gPadL = el.layout.padding.left * scaleVec.x
                        let gPadT = el.layout.padding.top * scaleVec.y
                        let defaultGridColor = liveTextColor ?? el.textColor ?? defaultViewFg
                        if abs(scaleVec.x - 1.0) < 1e-4 && abs(scaleVec.y - 1.0) < 1e-4 {
                            let padLx = gPadL * pxScale
                            let padTy = gPadT * pxScale
                            let gridDevRect = SIMD4<Float>(devRect.x + padLx, devRect.y + padTy, max(0, devRect.z - padLx), max(0, devRect.w - padTy))
                            let gridExact = SIMD4<Float>(rExact.x + padLx, rExact.y + padTy, rExact.z, rExact.w)
                            var gridGlyphCount = 0
                            paintTerminalGrid(
                                grid,
                                devRect: gridDevRect,
                                exactRectPx: gridExact,
                                devClip: devClip,
                                localAlpha: localAlpha,
                                defaultColor: defaultGridColor,
                                effRotate: effRotate,
                                useLayer: useLayer,
                                primitives: &primitives,
                                glyphPageEntries: &glyphPageEntries,
                                usedGlyphMask: &usedGlyphMask,
                                glyphCount: &gridGlyphCount
                            )
                        } else {
                        let baseX = rect.x + gPadL
                        let baseY = rect.y + gPadT
                        let cellW = grid.cellSize.x * scaleVec.x
                        let cellH = grid.cellSize.y * scaleVec.y
                        for (rowIdx, row) in grid.rows.enumerated() {
                            let rowY = baseY + Float(rowIdx) * cellH
                            for fill in row.fills {
                                let fw = Float(max(0, fill.endColumn - fill.startColumn)) * cellW
                                guard fw > 0 else { continue }
                                let fx = baseX + Float(fill.startColumn) * cellW
                                primitives.append(.roundedRect(
                                    rect: SIMD4<Float>(fx * pxScale, rowY * pxScale, fw * pxScale, cellH * pxScale),
                                    fill: fill.color.scaleAlpha(localAlpha).simd4(srgb: srgbBlend),
                                    clip: devClip
                                ))
                            }
                            if !row.text.isEmpty || !row.spans.isEmpty {
                                let shaped = textSystem.shape(
                                    text: row.text,
                                    spans: row.spans.isEmpty ? nil : row.spans,
                                    style: row.style,
                                    maxWidth: nil,
                                    pixelScale: pxScale,
                                    emitGlyphs: true
                                )
                                for g in shaped.glyphs {
                                    let gc = (g.color ?? defaultGridColor).scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                                    let rect = SIMD4<Float>(
                                        (baseX + g.rect.x * scaleVec.x) * pxScale,
                                        (rowY + g.rect.y * scaleVec.y) * pxScale,
                                        g.rect.z * scaleVec.x * pxScale,
                                        g.rect.w * scaleVec.y * pxScale
                                    )
                                    primitives.append(textPrimitive(g, rect: rect, ink: gc, clip: devClip, at: primitives.count))
                                }
                            }
                            for cell in row.cells where !cell.text.isEmpty {
                                let shaped = textSystem.shape(
                                    text: cell.text,
                                    spans: nil,
                                    style: cell.style,
                                    maxWidth: nil,
                                    pixelScale: pxScale,
                                    emitGlyphs: true
                                )
                                let cx = baseX + Float(cell.column) * cellW
                                for g in shaped.glyphs {
                                    let gc = cell.color.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                                    let rect = SIMD4<Float>(
                                        (cx + g.rect.x * scaleVec.x) * pxScale,
                                        (rowY + g.rect.y * scaleVec.y) * pxScale,
                                        g.rect.z * scaleVec.x * pxScale,
                                        g.rect.w * scaleVec.y * pxScale
                                    )
                                    primitives.append(textPrimitive(g, rect: rect, ink: gc, clip: devClip, at: primitives.count))
                                }
                            }
                            if let overlay = row.overlayShape {
                                for op in overlay.ops {
                                    switch op {
                                    case let .fill(points, col):
                                        let c4 = col.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                                        if c4.w <= 0.0005 { continue }
                                        for (indices, aaMask) in Shape.triangulate(points) {
                                            let p0 = points[indices[0]], p1 = points[indices[1]], p2 = points[indices[2]]
                                            primitives.append(.triangle(
                                                v0: SIMD2<Float>((baseX + p0.x * scaleVec.x) * pxScale, (rowY + p0.y * scaleVec.y) * pxScale),
                                                v1: SIMD2<Float>((baseX + p1.x * scaleVec.x) * pxScale, (rowY + p1.y * scaleVec.y) * pxScale),
                                                v2: SIMD2<Float>((baseX + p2.x * scaleVec.x) * pxScale, (rowY + p2.y * scaleVec.y) * pxScale),
                                                aaMask: aaMask,
                                                color: c4,
                                                clip: devClip
                                            ))
                                        }
                                    case let .stroke(points, closed, width, cap, col):
                                        let c4 = col.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                                        if c4.w <= 0.0005 { continue }
                                        let strokeW = width * min(scaleVec.x, scaleVec.y) * pxScale
                                        let roundCap = (cap == .round)
                                        let n = points.count
                                        let count = closed ? n : max(0, n - 1)
                                        for idx in 0..<count {
                                            let a = points[idx], b = points[(idx + 1) % n]
                                            primitives.append(.segment(
                                                from: SIMD2<Float>((baseX + a.x * scaleVec.x) * pxScale, (rowY + a.y * scaleVec.y) * pxScale),
                                                to: SIMD2<Float>((baseX + b.x * scaleVec.x) * pxScale, (rowY + b.y * scaleVec.y) * pxScale),
                                                width: strokeW,
                                                color: c4,
                                                roundCap: roundCap,
                                                clip: devClip
                                            ))
                                        }
                                    }
                                }
                            }
                        }
                        }
                    }
                }
                emitTerminalGridSection()

                // 8. Text / Rich Text / TextInput
                // Text lays out from its box's place moved by how far its exact resting box sits from its
                // snapped one (inside its paint containment), as Blink paints a text fragment from its exact
                // place; a gliding box carries its rest's offset, so a glide's last frame places glyphs as the
                // resting frame after it. A field keeps its snapped box, which its caret and selection share
                // (`content.rs`, #935).
                let textRestsExact = TextBoxGeometry.restsExact(
                    isInput: editValue != nil,
                    scaleStill: nodeScaleMotion == .still && abs(textRasterScale - 1.0) < 1e-5,
                    scale: SIMD2<Float>(scaleVec.x, scaleVec.y)
                )
                let filterTextGlyphs = nodeScaleMotion != .still ||
                    abs(scaleVec.x - textRasterScale) > 1e-4 || abs(scaleVec.y - textRasterScale) > 1e-4
                let textShiftPx: SIMD2<Float> = textRestsExact ? textExactOffPx : .zero
                let snappedOriginX = (snappedEdgesPx[0] + textShiftPx.x) / pxScale
                let snappedOriginY = (snappedEdgesPx[1] + textShiftPx.y) / pxScale
                let padL = el.layout.padding.left * scaleVec.x
                let padT = el.layout.padding.top * scaleVec.y
                let innerW = max(0, (snappedEdgesPx[2] - snappedEdgesPx[0]) / pxScale - (el.layout.padding.left + el.layout.padding.right) * scaleVec.x)
                let textOriginX = snappedOriginX + padL
                let textOriginY = snappedOriginY + padT
                // A gliding box's text lays out from its nearest whole pixel and glides the remainder (`content.rs:221-236`).
                let isGliding = gliding && flightCover == nil && abs(scaleVec.x - 1.0) <= 1e-5 && abs(scaleVec.y - 1.0) <= 1e-5
                let glidePx: Vec2 = isGliding
                    ? Vec2(PixelSnap.textGlide(snappedEdgesPx[0]), PixelSnap.textGlide(snappedEdgesPx[1]))
                    : .zero
                let glideOffPx: Vec2 = isGliding
                    ? Vec2(
                        snappedEdgesPx[0] - snappedEdgesPx[0].rounded(.toNearestOrAwayFromZero),
                        snappedEdgesPx[1] - snappedEdgesPx[1].rounded(.toNearestOrAwayFromZero)
                    )
                    : .zero
                let restOriginX = textOriginX - glideOffPx.x / pxScale
                let restOriginY = textOriginY - glideOffPx.y / pxScale
                func rasterWindow(for clip: SIMD4<Float>) -> TextRasterWindow? {
                    TextRasterWindow.paint(top: clip.y, bottom: clip.y + clip.w, viewport: Float(devH),
                                           origin: restOriginY * pxScale, scale: scaleVec.y * pxScale,
                                           margin: filterMargin, transformed: nodeTurn != nil || flightCover != nil ||
                                            inh.inCache || ((el.runtimeExtra(RenderExtrasKey.cacheEnabled) as? Bool) ?? false))
                }
                let baseDefaultTextColor = (nearestGroupHovered ? el.groupColor : nil) ?? liveTextColor ?? sceneTextColor ?? el.textColor ?? defaultViewFg
                let defaultTextColor = applyPressColor(effPressColor, to: baseDefaultTextColor, frac: effPressFrac)

                if let edit = editValue {
                    // Kept out of `emitNodeEnter`'s frame (`@inline(never)`): debug builds give every
                    // temporary its own slot, and the deep text-shaping path below overflowed the
                    // 512 KB test-thread stack.
                    @inline(never) func emitEditInputSection(_ edit: TextEdit) {
                        // A field lays out again at its layout width, as it measured (`relayout::lay_out_text`, #948).
                        let resolvedInput = ElDisplayResolver.resolveInput(
                            el: el,
                            edit: edit,
                            innerWidth: max(0, snap.targetRect.width - el.layout.padding.left - el.layout.padding.right),
                            pxScale: pxScale
                        )
                        let showingPlaceholder = resolvedInput.showingPlaceholder
                        let renderedStr = resolvedInput.renderedString
                        let textCol = showingPlaceholder
                            ? (el.placeholderColor ?? defaultViewFg.alpha(0.4))
                            : defaultTextColor

                        let inputClip = intersectRects(visClip, rect)
                        let devInputClip = SIMD4<Float>(
                            inputClip.x * pxScale,
                            inputClip.y * pxScale,
                            inputClip.width * pxScale,
                            inputClip.height * pxScale
                        )
                        let window = rasterWindow(for: devInputClip)
                        let layout = resolvePaintTextLayout(
                            snapId: snap.nodeId,
                            isInput: true,
                            isExiting: p.isExiting,
                            text: renderedStr,
                            spans: resolvedInput.spans,
                            pills: resolvedInput.pills,
                            style: resolvedInput.style,
                            wrapWidth: resolvedInput.maxWidthForShape,
                            pxScale: pxScale,
                            glidePx: glidePx,
                            isSecure: resolvedInput.isSecure,
                            paragraphs: Self.paragraphRequest(field: snap.nodeId, el: el, edit: edit, resolved: resolvedInput),
                            rasterWindow: window
                        )
                        let inputBox = prepareVisibleParagraphs(in: layout, field: snap.nodeId, window: window)
                        let shaped = inputBox.shaped
                        if !nodeIsSecure {
                            elementDrawnText = shaped.drawnText
                            elementElision = shaped.elided
                        }
                        let inputScrollX = computeSingleLineScroll(
                            path: snap.path,
                            edit: edit,
                            shaped: shaped,
                            isFocused: isFocused,
                            showingPlaceholder: showingPlaceholder,
                            innerWidthPt: innerW / max(1e-4, scaleVec.x),
                            pixelScale: pxScale
                        )
                        let inputTextOriginX = textOriginX - inputScrollX * scaleVec.x
                        let inputRestOriginX = restOriginX - inputScrollX * scaleVec.x

                        if resolvedInput.style.hasBlockInsets {
                            RichTextFieldRender.emitBlockDecorations(
                                blocks: resolvedInput.blocks, softBreaks: edit.softBreaks,
                                richStyle: resolvedInput.richStyle, displayText: showingPlaceholder ? "" : renderedStr, shaped: shaped,
                                textSystem: textSystem, font: showingPlaceholder ? el.textStyle : resolvedInput.style, textColor: defaultTextColor,
                                innerW: innerW, textOriginX: inputRestOriginX, textOriginY: restOriginY,
                                scaleVec: scaleVec, pxScale: pxScale, shapingScale: pxScale,
                                rect: { box, radius, color in
                                    var rect = box
                                    rect.x += glidePx.x
                                    rect.y += glidePx.y
                                    primitives.append(.roundedRect(rect: rect, radii: SIMD4(repeating: radius),
                                                                   fill: color.scaleAlpha(localAlpha).simd4(srgb: srgbBlend), clip: devInputClip))
                                },
                                glyph: { box, glyph, color in
                                    var rect = box
                                    rect.x += glidePx.x
                                    rect.y += glidePx.y
                                    primitives.append(textPrimitive(glyph, rect: rect,
                                        ink: color.scaleAlpha(localAlpha).simd4(srgb: srgbBlend), clip: devInputClip,
                                        forceScaled: filterTextGlyphs, at: primitives.count))
                                }
                            )
                        }

                        // Selection highlight
                        if isFocused && edit.hasSelection && edit.preedit == nil && !showingPlaceholder {
                            let displayRange = resolvedInput.selectionRange(for: edit)
                            let baseSelCol = el.fieldSelectionColor(foreground: defaultViewFg, active: windowFocused)
                            let selCol = baseSelCol.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                            let lineRects = textSystem.selectionRects(
                                in: shaped,
                                utf8Range: displayRange,
                                pixelScale: pxScale
                            )
                            if !lineRects.isEmpty {
                                for r in lineRects {
                                    primitives.append(.roundedRect(
                                        // Its edges on the device grid (`selectable::push_field_selection` -> `text_marks::pixel_rect`, #935).
                                        rect: TextBoxGeometry.pixelRect(
                                            origin: SIMD2<Float>(inputRestOriginX, restOriginY),
                                            box: SIMD4<Float>(r.x, r.y, max(2.0, r.z), r.w),
                                            k: SIMD2<Float>(1, 1),
                                            pxScale: pxScale
                                        ),
                                        radii: SIMD4<Float>(repeating: 2.0 * pxScale),
                                        fill: selCol,
                                        clip: devInputClip
                                    ))
                                }
                            } else {
                                let cStart = textSystem.caretRect(in: shaped, utf8Offset: displayRange.lowerBound, pixelScale: pxScale)
                                let cEnd = textSystem.caretRect(in: shaped, utf8Offset: displayRange.upperBound, pixelScale: pxScale)
                                if abs(cStart.y - cEnd.y) < 1.0 {
                                    let sx = min(cStart.x, cEnd.x)
                                    let sw = max(2.0, abs(cEnd.x - cStart.x))
                                    primitives.append(.roundedRect(
                                        rect: SIMD4<Float>(
                                            (inputRestOriginX + sx) * pxScale,
                                            (restOriginY + cStart.y) * pxScale,
                                            sw * pxScale,
                                            cStart.w * pxScale
                                        ),
                                        radii: SIMD4<Float>(repeating: 2.0 * pxScale),
                                        fill: selCol,
                                        clip: devInputClip
                                    ))
                                } else {
                                    primitives.append(.roundedRect(
                                        rect: SIMD4<Float>(
                                            (inputRestOriginX + cStart.x) * pxScale,
                                            (restOriginY + cStart.y) * pxScale,
                                            max(4, innerW - cStart.x) * pxScale,
                                            cStart.w * pxScale
                                        ),
                                        radii: SIMD4<Float>(repeating: 2.0 * pxScale),
                                        fill: selCol,
                                        clip: devInputClip
                                    ))
                                    primitives.append(.roundedRect(
                                        rect: SIMD4<Float>(
                                            inputRestOriginX * pxScale,
                                            (restOriginY + cEnd.y) * pxScale,
                                            max(4, cEnd.x) * pxScale,
                                            cEnd.w * pxScale
                                        ),
                                        radii: SIMD4<Float>(repeating: 2.0 * pxScale),
                                        fill: selCol,
                                        clip: devInputClip
                                    ))
                                }
                            }
                        }

                        if resolvedInput.isRich {
                            textSystem.emitTextDecorationsAndPills(
                                shaped: shaped,
                                textOriginX: inputRestOriginX,
                                textOriginY: restOriginY,
                                scaleVec: scaleVec,
                                pxScale: pxScale,
                                defaultTextColor: textCol,
                                localAlpha: localAlpha,
                                srgbBlend: srgbBlend,
                                devClip: devInputClip,
                                rot: useLayer ? 0 : effRotate,
                                insertImage: { imagePacker.insert($0) },
                                into: &primitives
                            )
                        }

                        if el.spellcheck && !resolvedInput.isSecure && !departingText && !p.isExiting {
                            let color = FieldSpelling.color.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                            fieldSpelling.paint(edit: edit, focusedPath: isFocused ? snap.path : nil,
                                now: currentTime, box: inputBox, system: textSystem,
                                origin: Vec2(inputTextOriginX, textOriginY), scale: scaleVec, pixels: pxScale,
                                clip: SIMD4(devInputClip.x, devInputClip.y, devInputClip.x + devInputClip.z, devInputClip.y + devInputClip.w),
                                rotated: nodeTurn != nil) { marker, radius in
                                    primitives.append(attachFade(.roundedRect(
                                        rect: marker, radii: SIMD4(repeating: radius), fill: color, clip: devInputClip,
                                        turn: useLayer ? 0 : effRotate
                                    )))
                                }
                        } else if isFocused {
                            fieldSpelling.watch = nil
                        }
                        let fieldMarks = showingPlaceholder || resolvedInput.isSecure ? [] : el.textHighlights ?? []
                        for quad in TextHighlightPainter.fieldQuads(
                            marks: fieldMarks, box: inputBox, system: textSystem,
                            origin: Vec2(inputRestOriginX, restOriginY), transform: scaleVec, pixelScale: pxScale
                        ) {
                            primitives.append(attachFade(.roundedRect(
                                rect: quad.rect, radii: SIMD4(repeating: quad.cornerRadius),
                                fill: quad.bg.scaleAlpha(localAlpha).simd4(srgb: srgbBlend),
                                borderColor: quad.ring?.color.scaleAlpha(localAlpha).simd4(srgb: srgbBlend) ?? .zero,
                                borderWidth: quad.ring?.width ?? 0, clip: devInputClip, turn: useLayer ? 0 : effRotate
                            )))
                        }
                        // Text glyphs
                        let inputInCache = inh.inCache || ((el.runtimeExtra(RenderExtrasKey.cacheEnabled) as? Bool) ?? false)
                        let inputRotated = nodeTurn != nil
                        let inputShownY0 = (!inputRotated && !inputInCache) ? max(devInputClip.y, -filterMargin) : devInputClip.y
                        let inputShownY1 = (!inputRotated && !inputInCache) ? min(devInputClip.y + devInputClip.w, Float(devH) + filterMargin) : (devInputClip.y + devInputClip.w)
                        let inputBasePt = resolvedInput.style.lineHeight ?? resolvedInput.style.size
                        let inputSpanPt = resolvedInput.spans?.compactMap(\.size).max() ?? 0
                        let inputEmPt = max(max(resolvedInput.style.size, inputBasePt), inputSpanPt)
                        // Under a turn (own or inherited) the upright clip doesn't bound the glyphs: upstream drops
                        // the clip inside a turned layer (`pinh.clip = NO_CLIP`), so no band.
                        let (inBandTop, inBandBot): (Float, Float) = (!inputRotated && abs(scaleVec.y) > 1e-4)
                            ? (
                                (devInputClip.y / pxScale - restOriginY) / scaleVec.y - 2.0,
                                ((devInputClip.y + devInputClip.w) / pxScale - restOriginY) / scaleVec.y + 2.0
                            )
                            : (-Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
                        let visibleInputGlyphs: ArraySlice<PositionedGlyph>
                        if let pl = inputBox.paragraphs {
                            // A by-paragraph field draws the paragraphs that meet the rows it shows
                            // (`flow.pieces_in`), in its layout's device px; a field with paragraphs
                            // still waiting notes those rows for the fill (`text_rows`).
                            let ls = pl.scale
                            let rowPad = 2.0 * inputEmPt * ls + 2.0 / max(1e-4, pxScale)
                            let rows: (Float, Float) = (!inputRotated && abs(scaleVec.y) > 1e-4)
                                ? (
                                    ((devInputClip.y / pxScale - restOriginY) / scaleVec.y) * ls - rowPad,
                                    (((devInputClip.y + devInputClip.w) / pxScale - restOriginY) / scaleVec.y) * ls + rowPad
                                )
                                : (-Float.infinity, Float.infinity)
                            if pl.waiting { textRows[snap.nodeId] = rows }
                            visibleInputGlyphs = pl.glyphs(top: rows.0, bottom: rows.1, using: textSystem, inks: inputBox.spanInks)[...]
                        } else if inputBox.rasterWindow != nil {
                            visibleInputGlyphs = shaped.glyphs[...]
                        } else {
                            visibleInputGlyphs = textSystem.glyphCache.glyphsInBandCached(
                                key: GlyphReplayKey(shapeKey: inputBox.shapeKey, spans: inputBox.spans,
                                                    maxWidth: inputBox.maxWidth, glidePx: glidePx, scopedInkBucket: inputBox.shaped.scopedInkBucket),
                                keep: resolvedInput.isSecure ? .secret : (glidePx == .zero ? .cached : .owned),
                                bandTopPt: inBandTop,
                                bandBottomPt: inBandBot,
                                sinceAtlasResets: textSystem.glyphAtlas.resets
                            ) {
                                (shaped.glyphs, shaped.lineGlyphRanges, shaped.bandLineHeight)
                            }
                        }
                        for g in visibleInputGlyphs {
                            let gy = (restOriginY + g.rect.y * scaleVec.y) * pxScale
                            let gh = g.rect.w * scaleVec.y * pxScale
                            let gx = (inputRestOriginX + g.rect.x * scaleVec.x) * pxScale
                            let gw = g.rect.z * scaleVec.x * pxScale
                            if !inputRotated && (gy + gh < inputShownY0 || gy > inputShownY1 ||
                                                 gx + gw < devInputClip.x || gx > devInputClip.x + devInputClip.z) { continue }
                            let baseGlyphColor = g.color.map { applyPressColor(effPressColor, to: $0, frac: effPressFrac) } ?? textCol
                            let ink = fieldMarks.last { $0.fg != nil && $0.byteRange.contains(g.utf8Offset) }?.fg ?? baseGlyphColor
                            guard textFlightTarget == nil, !showingPlaceholder || !departingText else { continue }
                            let gc = ink.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                            let rect = SIMD4<Float>(gx, gy, gw, gh)
                            primitives.append(textPrimitive(g, rect: rect, ink: gc, clip: devInputClip,
                                                            forceScaled: filterTextGlyphs, at: primitives.count))
                        }

                        // Caret bar when focused & window focused
                        if isFocused {
                            let byteOff = displayCaretByteOffset(for: edit, showingPlaceholder: showingPlaceholder)
                            let cRect = textSystem.caretRect(in: shaped, utf8Offset: byteOff, upstream: edit.caretAffinity == .upstream, pixelScale: pxScale)
                            let caretXPt: Float
                            if isGliding {
                                let cxPx = (inputTextOriginX + cRect.x) * pxScale
                                caretXPt = ((cxPx - glidePx.x).rounded(.toNearestOrAwayFromZero) + glidePx.x) / pxScale
                            } else {
                                caretXPt = inputTextOriginX + cRect.x
                            }
                            let worldCaret = [caretXPt, textOriginY + cRect.y, cRect.z, cRect.w]
                            caretOut = worldCaret
                            if windowFocused {
                                let cc = (el.caretColor ?? defaultViewFg)
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
                    }
                    emitEditInputSection(edit)
                } else if el.richSpans != nil || paintedLabelValue != nil || el.advanceInRun != nil {
                    var resolvedText = ElDisplayResolver.resolveText(
                        el: el,
                        rawText: paintedLabelValue,
                        isSecure: nodeIsSecure
                    )
                    if p.isExiting && el.role == .textInput, let paintedLabelValue {
                        resolvedText.displayedText = paintedLabelValue
                    }
                    let raster = textFlightTarget == nil ? labelRasters.raster(scale: textRasterScale, still: nodeScaleMotion == .still) : nil
                    let shapeScale = raster == nil ? textRasterScale * pxScale : pxScale
                    let inkMode = resolvedText.style.fontSmoothing == .systemDefault ? textSystem.smoothing : resolvedText.style.fontSmoothing
                    let isClampedOrEllipsis = resolvedText.style.maxLines > 0 || resolvedText.style.wrap == .ellipsis
                    // A wrapping text lays out again at its layout width, `w * scale + FIT_SLACK` device px, as it
                    // measured (`relayout::lay_out_text`, #948).
                    let wrapWidth = TextBoxGeometry.wrapWidth(max(0, snap.targetRect.width - el.layout.padding.left - el.layout.padding.right), scale: shapeScale)!
                    let labelBox: TextLayoutBox?
                    var shaped: ShapedText
                    if resolvedText.truncateFade || resolvedText.advanceRun != nil || isClampedOrEllipsis {
                        labelBox = nil
                        shaped = GlyphAtlas.withBaseInk(defaultTextColor, mode: inkMode) {
                            resolvedText.shape(
                                using: textSystem,
                                maxWidth: wrapWidth,
                                pixelScale: shapeScale,
                                emitGlyphs: true,
                                glidePx: glidePx
                            )
                        }
                    } else {
                        let hasSpans = (resolvedText.spans?.isEmpty == false)
                        let shapeMaxW: Float? = (resolvedText.style.wrap == .noWrap && resolvedText.style.maxLines == 0) ? nil : wrapWidth
                        let box = GlyphAtlas.withBaseInk(defaultTextColor, mode: inkMode) {
                            resolvePaintTextLayout(
                                snapId: snap.nodeId,
                                isInput: false,
                                isExiting: p.isExiting,
                                text: hasSpans ? "" : resolvedText.displayedText,
                                spans: resolvedText.spans,
                                pills: resolvedText.pills,
                                style: resolvedText.style,
                                wrapWidth: shapeMaxW,
                                pxScale: shapeScale,
                                glidePx: glidePx,
                                isSecure: resolvedText.isSecure,
                                pretty: resolvedText.pretty,
                                rasterWindow: rasterWindow(for: devClip)
                            )
                        }
                        labelBox = box
                        shaped = box.shaped
                    }
                    let offsetX = TextBoxGeometry.inlineOffset(align: el.textStyle.align,
                        wrap: resolvedText.truncateFade ? .noWrap : resolvedText.style.wrap, shaped: shaped,
                        innerWidth: innerW, textScale: scaleVec.x, pixelScale: pxScale)
                    let labelX = textOriginX + offsetX
                    let labelRestX = restOriginX + offsetX
                    #if canImport(CRuneDesktopText) && !canImport(CoreText)
                    let placedNativeGlyphs = textRestsExact && (shaped.desktopRestingText?.place(
                        &shaped, at: labelRestX * pxScale, atlas: textSystem.glyphAtlas
                    ) ?? false)
                    #else
                    let placedNativeGlyphs = false
                    #endif
                    let elided = shaped.elided
                    if !nodeIsSecure {
                        elementDrawnText = shaped.drawnText
                        elementElision = elided
                    }
                    let innerH = max(0, (snappedEdgesPx[3] - snappedEdgesPx[1]) / pxScale - (el.layout.padding.top + el.layout.padding.bottom) * scaleVec.y)
                    let exactInnerWPx = max(0, (rExact[2] - rExact[0]) - (el.layout.padding.left + el.layout.padding.right) * scaleVec.x * pxScale)
                    let layoutInnerW = max(0, snap.targetRect.width - el.layout.padding.left - el.layout.padding.right)
                    let fadeRes = resolvedText.truncateFade
                        ? ElDisplayResolver.truncateFadeParams(
                            el: el,
                            shaped: shaped,
                            innerW: innerW,
                            innerH: innerH,
                            exactInnerWPx: exactInnerWPx,
                            layoutInnerW: layoutInnerW,
                            scaleVec: scaleVec,
                            pxScale: pxScale,
                            textOriginX: textOriginX,
                            textOriginY: textOriginY,
                            baseClipPx: devClip
                        )
                        : nil
                    if el.isHelpWhenTruncated {
                        // Node::text_cut uses the painted elision or the fade layout's full width.
                        // Wrapping a whole label onto more lines does not remove any of its text.
                        textTruncated = shaped.wasTruncated || shaped.elided != nil
                            || (resolvedText.truncateFade && resolvedText.advanceRun == nil
                                && shaped.size.x * pxScale > layoutInnerW * pxScale + 0.5)
                    }
                    let selPaintInk = emitSelectableHighlightIfNeeded(
                        snap: snap, el: el, isExiting: p.isExiting, activeSelectionRanges: activeSelectionRanges,
                        textOriginX: labelRestX, textOriginY: restOriginY, scaleVec: scaleVec, pxScale: pxScale,
                        localAlpha: localAlpha, shaped: shaped,
                        emitMark: { rect, fill in
                            primitives.append(.roundedRect(rect: rect, radii: .zero, fill: fill, clip: devClip,
                                                           turn: useLayer ? 0 : effRotate))
                        },
                        emitHighlight: { rect, fill, radius, reach in
                            SelectionRunExtender.appendHighlight(into: &primitives, rect: rect, fill: fill, radius: radius,
                                clip: devClip, fade: .zero, turn: useLayer ? 0 : effRotate, reach: reach)
                        }
                    )
                    let linkInks = recordAndEmitTextLinks(
                        snap: snap,
                        el: el,
                        text: resolvedText.displayedText,
                        authoredText: resolvedText.authoredText,
                        caseMap: resolvedText.caseMap,
                        shaped: shaped,
                        elided: elided,
                        textOriginX: labelX,
                        textOriginY: textOriginY,
                        scaleVec: scaleVec,
                        pxScale: pxScale,
                        shapeScale: shapeScale,
                        localAlpha: localAlpha,
                        defaultTextColor: defaultTextColor,
                        isFocused: isFocused,
                        isExiting: p.isExiting,
                        shouldEmit: shouldEmit,
                        visClip: visClip,
                        linkBoxes: &newLinkBoxes,
                        recordHit: { link, index, edges in
                            if let words = link.help, !words.isEmpty {
                                newHelpHits.append(HelpHitRecord(
                                    path: snap.path, key: link.id, rect: edges, seq: newInteractiveHits.count,
                                    text: runeHelpWords(words), side: el.helpSide, linkIndex: index
                                ))
                            }
                            newInteractiveHits.append(HelpInteractiveHitRecord(path: snap.path, rect: edges))
                        },
                        emitRect: { rect, radius, fill, border, width in
                            primitives.append(.roundedRect(
                                rect: rect, radii: SIMD4(repeating: radius),
                                fill: fill.scaleAlpha(localAlpha).simd4(srgb: srgbBlend),
                                borderColor: border.scaleAlpha(localAlpha).simd4(srgb: srgbBlend),
                                borderWidth: width, clip: devClip, turn: useLayer ? 0 : effRotate
                            ))
                        }
                    )
                    // Laid out from its exact place, its baselines round once where they land, as Skia
                    // rounds a text blob; its decorations round against them (`content.rs`, #935).
                    let roundedBaselines: [Float] = textRestsExact
                        ? TextBoxGeometry.roundedBaselines(originYPx: restOriginY * pxScale, shaped: shaped)
                        : []
                    textSystem.emitTextDecorationsAndPills(
                        shaped: shaped,
                        textOriginX: labelX,
                        textOriginY: textOriginY,
                        scaleVec: scaleVec,
                        pxScale: pxScale,
                        defaultTextColor: defaultTextColor,
                        localAlpha: localAlpha,
                        srgbBlend: srgbBlend,
                        devClip: devClip,
                        rot: useLayer ? 0 : effRotate,
                        spanRadius: el.elSpanRadius,
                        roundedBaselines: roundedBaselines,
                        glideOffPx: SIMD2<Float>(glideOffPx.x, glideOffPx.y),
                        insertImage: { imagePacker.insert($0) },
                        into: &primitives
                    )
                    if !el.elStrikes.isEmpty, let txt = paintedLabelValue {
                        let strikeQuads = ShellSliceRenderHelpers.strikeQuads(
                            strikes: el.elStrikes,
                            richSpans: el.richSpans,
                            text: txt,
                            shaped: shaped,
                            textSystem: textSystem,
                            styleSize: el.textStyle.size,
                            defaultTextColor: defaultTextColor,
                            textOriginX: labelX,
                            textOriginY: textOriginY,
                            scaleVec: scaleVec,
                            pxScale: pxScale,
                            localAlpha: localAlpha,
                            srgbBlend: srgbBlend
                        )
                        for sq in strikeQuads {
                            primitives.append(attachFade(.roundedRect(
                                rect: sq.rect,
                                radii: .zero,
                                fill: sq.color,
                                clip: devClip,
                                turn: useLayer ? 0 : effRotate
                            )))
                        }
                    }
                    var highlightInks: [TextLinkInkRange] = []
                    var combinedHighlights = el.textHighlights ?? []
                    let ringHls = ElDisplayResolver.spanRingHighlights(spanRings: resolvedText.spanRings, spans: resolvedText.spans)
                    if !ringHls.isEmpty {
                        combinedHighlights.append(contentsOf: ringHls)
                    }
                    let drawnHighlightText = elided != nil ? shaped.drawnText : resolvedText.displayedText
                    if let elided, !combinedHighlights.isEmpty {
                        combinedHighlights = elided.mapHighlights(
                            combinedHighlights,
                            contentLength: resolvedText.displayedText.utf8.count
                        )
                    }
                    if !combinedHighlights.isEmpty && !drawnHighlightText.isEmpty {
                        let txtLen = drawnHighlightText.utf8.count
                        for h in combinedHighlights {
                            guard let fg = h.fg else { continue }
                            let a = min(h.byteRange.lowerBound, txtLen)
                            let b = min(h.byteRange.upperBound, txtLen)
                            guard a < b else { continue }
                            let rects = textSystem.selectionRects(in: shaped, utf8Range: a..<b, pixelScale: pxScale)
                            if !rects.isEmpty {
                                highlightInks.append(TextLinkInkRange(color: fg, rects: rects))
                            }
                        }
                        let quads = TextHighlightPainter.quads(
                            highlights: combinedHighlights,
                            in: drawnHighlightText,
                            shaped: shaped,
                            textSystem: textSystem,
                            pixelScale: pxScale,
                            origin: .zero
                        )
                        for q in quads {
                            let hlRect = SIMD4<Float>(
                                labelRestX * pxScale + q.rect.x * scaleVec.x,
                                restOriginY * pxScale + q.rect.y * scaleVec.y,
                                q.rect.z * scaleVec.x,
                                q.rect.w * scaleVec.y
                            )
                            let bgColor = q.bg.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                            if bgColor.w > 0.0005 {
                                primitives.append(attachFade(.roundedRect(
                                    rect: hlRect,
                                    radii: SIMD4<Float>(repeating: q.cornerRadius * scaleVec.x),
                                    fill: bgColor,
                                    clip: devClip,
                                    turn: useLayer ? 0 : effRotate
                                )))
                            }
                            if let ring = q.ring, ring.width > 0 {
                                let ringColor = ring.color.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                                if ringColor.w > 0.0005 {
                                    primitives.append(attachFade(.roundedRect(
                                        rect: hlRect,
                                        radii: SIMD4<Float>(repeating: q.cornerRadius * scaleVec.x),
                                        fill: .zero,
                                        borderColor: ringColor,
                                        borderWidth: ring.width * scaleVec.x,
                                        clip: devClip,
                                        turn: useLayer ? 0 : effRotate
                                    )))
                                }
                            }
                        }
                    }
                    let glyphAlpha: Float = textFlightTarget == nil ? localAlpha : 0
                    let glyphClip = fadeRes?.glyphClip ?? devClip
                    if glyphAlpha > 0.0005 {
                        let wrapTruncateLayer = (fadeRes?.isTruncated == true && fadeRes?.refFade != .zero && !activeFadeEdges.isEmpty)
                        if wrapTruncateLayer, let fRes = fadeRes {
                            primitives.append(.layerBegin(
                                rect: glyphClip,
                                opacity: 1.0,
                                clip: glyphClip,
                                fade: fRes.refFade,
                                fadeOrigin: fRes.refFadeOrigin,
                                turn: useLayer ? 0 : effRotate
                            ))
                        }
                        let revealClock = scene.store.nodeTimeScale(p.id) != 1.0 ? scene.store.nodeTime(p.id) : lastScaledAnimNow
                        let wordFadeMask = ((el.elRevealWordFade ?? -1) >= 0)
                            ? wordRevealStore.mask(
                                for: p.id,
                                text: paintedLabelValue ?? "",
                                shaped: shaped,
                                textSystem: textSystem,
                                pixelScale: pxScale,
                                now: revealClock
                            )
                            : nil
                        let textInCache = inh.inCache || ((el.runtimeExtra(RenderExtrasKey.cacheEnabled) as? Bool) ?? false)
                        let textRotated = nodeTurn != nil
                        let textShownY0 = (!textRotated && !textInCache) ? max(glyphClip.y, -filterMargin) : glyphClip.y
                        let textShownY1 = (!textRotated && !textInCache) ? min(glyphClip.y + glyphClip.w, Float(devH) + filterMargin) : (glyphClip.y + glyphClip.w)
                        let glyphsToEmit: ArraySlice<PositionedGlyph>
                        if let labelBox, labelBox.rasterWindow == nil, !wrapTruncateLayer {
                            let (lblBandTop, lblBandBot): (Float, Float) = (!textRotated && abs(scaleVec.y) > 1e-4)
                                ? (
                                    (devClip.y / pxScale - restOriginY) / scaleVec.y - 2.0,
                                    ((devClip.y + devClip.w) / pxScale - restOriginY) / scaleVec.y + 2.0
                                )
                                : (-Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
                            glyphsToEmit = textSystem.glyphCache.glyphsInBandCached(
                                key: GlyphReplayKey(shapeKey: labelBox.shapeKey, spans: labelBox.spans,
                                                    maxWidth: labelBox.maxWidth, glidePx: glidePx, scopedInkBucket: labelBox.shaped.scopedInkBucket),
                                keep: resolvedText.isSecure ? .secret : (glidePx == .zero && !placedNativeGlyphs ? .cached : .owned),
                                bandTopPt: lblBandTop,
                                bandBottomPt: lblBandBot,
                                sinceAtlasResets: textSystem.glyphAtlas.resets
                            ) {
                                (shaped.glyphs, shaped.lineGlyphRanges, shaped.bandLineHeight)
                            }
                        } else {
                            glyphsToEmit = shaped.glyphs[...]
                        }
                        let placements = TextBoxGeometry.GlyphPlacementBatch(shaped: shaped, atlas: textSystem.glyphAtlas,
                                                                             exact: textRestsExact || raster != nil)
                        defer { placements?.finish() }
                        var baselineLine = 0
                        for gi in glyphsToEmit.indices {
                            let inkGlyph = glyphsToEmit[gi]
                            let (g, placement) = TextBoxGeometry.paintGlyph(
                                inkGlyph, index: gi, shaped: shaped, origin: SIMD2<Float>(labelRestX, restOriginY) * pxScale,
                                scale: SIMD2<Float>(scaleVec.x, scaleVec.y), pixelScale: pxScale,
                                restsExact: textRestsExact, baselines: roundedBaselines, line: &baselineLine, atlas: textSystem.glyphAtlas,
                                raster: raster, placements: placements
                            )
                            let gx = placement.x, gy = placement.y, gh = placement.w
                            if !textRotated && (gy + gh < textShownY0 || gy > textShownY1 ||
                                                gx + placement.z < glyphClip.x || gx > glyphClip.x + glyphClip.z) { continue }
                            let wordAlpha = wordFadeMask?.alpha(for: inkGlyph) ?? 1.0
                            let effGlyphAlpha = glyphAlpha * wordAlpha
                            if effGlyphAlpha <= 0.0005 { continue }
                            let baseGlyphColor = g.color.map { applyPressColor(effPressColor, to: $0, frac: effPressFrac) } ?? defaultTextColor
                            let gc = (selPaintInk?.color(for: inkGlyph) ?? linkInkColor(for: inkGlyph, ranges: highlightInks) ?? linkInkColor(for: inkGlyph, ranges: linkInks) ?? baseGlyphColor).scaleAlpha(effGlyphAlpha).simd4(srgb: srgbBlend)
                            let rect = placement
                            var prim = attachFade(textPrimitive(g, rect: rect, ink: gc, clip: glyphClip,
                                                               turn: useLayer ? 0 : effRotate, forceScaled: filterTextGlyphs,
                                                               at: primitives.count))
                            if let fRes = fadeRes, fRes.isTruncated, fRes.refFade != .zero, activeFadeEdges.isEmpty {
                                prim.fade = fRes.refFade
                                prim.fadeOrigin = fRes.refFadeOrigin
                            }
                            primitives.append(prim)
                        }
                        if wrapTruncateLayer {
                            primitives.append(.layerEnd(clip: glyphClip))
                        }
                    }
                }

                // 9. Focus ring & focus-within ring when keyboard-focus-visible (or forced by Cx::forceFocusRings / focused textInput), else El.outline
                let primsBeforeFocus = primitives.count
                if !hasActiveTextLinks(el) {
                    emitFocusRingIfNeeded(
                        el: el,
                        snapIndex: snap.index,
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
                if primitives.count == primsBeforeFocus, let ol = el.elOutline, localAlpha > 0.0005 {
                    let avgOutlineScale = (scaleVec.x + scaleVec.y) * 0.5
                    if let og = ShellSliceRenderHelpers.resolvedOutlineGeometry(
                        outline: ol,
                        devRect: devRect,
                        devRadii: devRadii,
                        pxScale: pxScale,
                        avgScale: avgOutlineScale
                    ) {
                        primitives.append(attachFade(.roundedRect(
                            rect: og.rect,
                            radii: og.radii,
                            fill: .zero,
                            borderColor: ol.color.scaleAlpha(localAlpha).simd4(srgb: srgbBlend),
                            borderWidth: og.widthPx,
                            clip: devClip,
                            turn: useLayer ? 0 : effRotate
                        )))
                    }
                }
            }

            let hasVisualBlocker = el.blocksHits(fill: fillColor, border: borderColor)
            let isInteractiveBlocker = el.blocksInteractiveHits
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
                if !snap.effectiveInert && (isInteractiveBlocker || el.hoverBg != nil || el.pressBg != nil ||
                   el.focusable || el.isHoverGroup || el.isHoverAlone) {
                    newInteractiveHits.append(HelpInteractiveHitRecord(
                        path: snap.path,
                        rect: hitRect4
                    ))
                }
            }

            newHitGeometries[snap.path] = HitGeometry(
                paintOrder: newPaintOrder.count - 1,
                rect: rect,
                clipRect: effectiveHitClip,
                outerClip: effectiveOuterClip,
                turn: nodeTurn,
                opacity: logicalAlpha,
                isExiting: nodeExiting,
                hasVisualBlocker: hasVisualBlocker,
                isInteractiveBlocker: isInteractiveBlocker,
                parentScreenClip: Self.screenClipOfParent(inheritedClip: flightClipOverride ?? inh.clip, ancestorTurn: ancestorTurn, outerTurnClip: outerTurnClip, localTurnClip: localTurnClip)
            )

            var nodeEditRange: [Int]? = nil
            if let lens = el.handlers.editLens {
                let r = lens.get(state).selectedUTF8Range
                nodeEditRange = [r.lowerBound, r.upperBound]
            }
            if let c = caretOut, isFocused, !nodeIsSecure, !snap.effectiveInert, !p.isExiting,
               visibleRect.width > 0, visibleRect.height > 0 {
                imeArea = c
            } else if isFocused && !nodeIsSecure && el.handlers.editLens != nil,
                      !snap.effectiveInert, !p.isExiting,
                      visibleRect.width > 0, visibleRect.height > 0 {
                imeArea = rect.xywh
            } else if el.isImeCursor, imeArea == nil, !snap.effectiveInert, !p.isExiting {
                imeArea = rect.xywh
            }
            let spatialMoving = p.isMoving || liveSpatialSpringingById.contains(p.id) || trailingMoved
            let growing = !movingGrowthPaths.isEmpty && movingGrowthPaths.contains(snap.path)
            let inFlight = textFlightTarget != nil || textFlightSource != nil
            var pose: RawPoseNodeData?
            if needsPaintPose(snap, el: el, rotation: effRotate, shadows: resolvedNodeShadows, growing: growing, inFlight: inFlight) {
                pose = inspectPaintedNode(
                    snap, el: el, rotation: effRotate, scale: scaleVec.x, shadows: resolvedNodeShadows, liveShadowColor: liveShadowColor,
                    spatialMoving: spatialMoving, flightTarget: textFlightTarget != nil, inFlight: inFlight, growthMoving: growing
                )
                rawPoseByPath[snap.path] = pose
                if let pose, pose.ownScrolling || pose.ownGrowingRow || pose.ownMotionLive
                    || pose.ownLiveIntent != 0 || pose.instantHoverGroupRule { hasInheritedPose = true }
            }
            let enclosingVScrollMoving: Bool = !p.isExiting && (snap.enclosingVScrollIndex.flatMap { idx -> Bool? in
                guard flatNodes.indices.contains(idx) else { return nil }
                let vp = flatNodes[idx].path
                return slice2State.scrollSlacks[vp]?.moving == true || scrollGlidingPaths.contains(vp)
            } == true)
            let infoMoving = (pose?.ownMoving ?? spatialMoving)
                    || (el.layout.scrollAxes.contains(.vertical) && (slice2State.scrollSlacks[snap.path]?.moving == true || scrollGlidingPaths.contains(snap.path)))
                    || enclosingVScrollMoving
            if infoMoving { hasInheritedPose = true }
            if let parentPath {
                parentPathForInfo[PaintElementKey(path: snap.path, exiting: nodeExiting)] = parentPath
            }
            let inheritedReportClip = input.inh.reportedTurnClip.map { reportedTurnClips[$0] }
            let parentReportClip: MotionRect?
            let infoVisible: MotionRect
            if nodeTurn != nil {
                parentReportClip = flightClipOverride ?? Self.screenClipOfParent(
                    inheritedClip: input.inh.clip, ancestorTurn: ancestorTurn,
                    outerTurnClip: inheritedReportClip?.outer, localTurnClip: inheritedReportClip?.local
                )
                infoVisible = parentReportClip.map { intersectRects(drawnRect, $0) } ?? drawnRect
            } else {
                parentReportClip = nil
                infoVisible = visibleRect
            }
            infos.append(ElementInfo(
                path: snap.path,
                key: snap.key,
                parentIndex: snap.parentIndex,
                role: el.role,
                geometry: .boxes(rect: drawnRect, target: snap.targetRect, visible: infoVisible),
                committedLayoutTarget: snap.committedLayoutTarget,
                opacity: logicalAlpha,
                scale: scaleVec.x,
                blur: effBlur,
                radius: p.corners.maxMagnitude,
                fill: fillColor,
                textColor: liveTextColor ?? sceneTextColor ?? el.textColor ?? (elementTextValue != nil ? cxSettings.viewDefaults.foreground : nil),
                text: elementTextValue,
                label: el.a11yLabel,
                help: resolvedRawHelp.map(runeHelpWords),
                selected: nodeIsSecure ? nil : (selectableSelectedSlice(snap, range: activeSelectionRanges[snap.path]) ?? el.a11ySelected),
                expanded: el.a11yExpanded,
                level: el.a11yLevel,
                itemSelected: el.itemSelected,
                focusable: nodeTakesFocus(el),
                focused: isFocused,
                focusVisible: (isFocused && focusVisible) || (forceFocusRings && nodeTakesFocus(el)),
                inert: snap.effectiveInert || nodeExiting,
                modalAncestor: activeModalPath != nil && modalAncestorPaths.contains(snap.path),
                moving: infoMoving,
                exiting: nodeExiting,
                hover: nodeExiting ? 0.0 : hoverFrac,
                press: isPressed ? 1.0 : 0.0,
                scrolled: [scrolled.x, scrolled.y],
                carriedScrolled: [carriedScrolled.x, carriedScrolled.y],
                caret: caretOut,
                secure: nodeIsSecure,
                disabled: el.a11yDisabled,
                checked: el.a11yChecked,
                a11yValue: el.a11yValue,
                a11yDescription: el.a11yDescription,
                a11yHidden: el.isA11yHidden,
                stuck: abs(stickyShift.y) >= abs(stickyShift.x) ? stickyShift.y : stickyShift.x,
                traceName: el.traceNameValue,
                traceNamespace: {
                    if let own = el.traceNamespaceValue {
                        return TraceNamespace(className: own.className, host: own.host)
                    }
                    guard hasTraceNamespace else { return nil }
                    var cur = snap.parentIndex
                    while let pIdx = cur, flatNodes.indices.contains(pIdx) {
                        if let anc = flatNodes[pIdx].el.traceNamespaceValue {
                            return TraceNamespace(className: anc.className, host: anc.host)
                        }
                        cur = flatNodes[pIdx].parentIndex
                    }
                    return nil
                }(),
                virtualExtent: pose?.virtualExtent ?? false,
                editRange: nodeEditRange,
                loopPhase: pose?.loopPhase,
                revealing: pose?.revealing ?? false,
                inGrowingRow: pose?.ownGrowingRow ?? false,
                scrolling: false,
                liveIntent: pose?.ownLiveIntent ?? 0,
                shapeKey: (!nodeIsSecure && (paintedLabelValue != nil || el.richSpans != nil))
                    ? TextShapeKey.compute(
                        text: paintedLabelValue ?? "",
                        spans: el.richSpans,
                        pills: el.pillChips,
                        style: el.textStyle,
                        pixelScale: pxScale,
                        wrapAnywhere: (el.runtimeExtra("htmlWrapAnywhere") as? Bool) ?? false
                    )
                    : nil,
                drawnText: elementDrawnText,
                elision: elementElision
            ))
            infos[infos.count - 1].a11yInput = ElementA11yInput(el, edit: editValue, modalMember: activeModalPath == nil ? nil : modalMemberPaths.contains(snap.path))
            if shouldEmit && !nodeExiting && !snap.effectiveInert {
                if el.isImeCursor && !hasFocusedTextInput && nextImeCursorArea == nil {
                    nextImeCursorArea = rect.xywh
                    nextImeOptionAsAlt = el.isImeOptionAsAlt
                }
                if el.noWindowDrag {
                    nextNoWindowDragRects.append(visibleRect)
                }
            }
            if el.textHighlights != nil, snap.index < flatNodes.count {
                let ownerIndex = infos.count - 1
                let marks = highlightElementInfos(node: flatNodes[snap.index], owner: infos[ownerIndex], ownerIndex: ownerIndex,
                                                 rect: rect, scaleVec: scaleVec, visibleRect: visibleRect)
                for mark in marks {
                    parentPathForInfo[PaintElementKey(path: mark.path, exiting: mark.exiting)] = snap.path
                }
                infos.append(contentsOf: marks)
            }

            let ownClipCorners: Corners? = el.clipCorners
                ?? el.clipRadius.map { r in el.corners.maxMagnitude > 0.001 ? p.corners : Corners(r, r, r, r) }
                ?? (el.layout.clipOverflow && p.corners.maxMagnitude > 0.001 ? p.corners : nil)
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
                ).withContinuousCorners(continuousCorners)
                primitives.append(.layerBegin(
                    rect: devRectClip,
                    radii: clipR,
                    opacity: 1.0,
                    clip: devClip,
                    turn: useLayer ? 0 : effRotate
                ))
            }

            let childAncestorOp: Float = ((shouldEmit && useLayer) ? 1.0 : paintAlphaTotal).clamped(to: 0...1)
            let nextOuterClip: MotionRect? = (nodeTurn != nil) ? effectiveOuterClip : nil
            let nextGroupHovered = (el.isHoverGroup || el.hoverBg != nil || el.hoverGroupShare != nil)
                ? isGroupHovered(snap)
                : nearestGroupHovered
            let nextGroupHoverFrac = (el.isHoverGroup || el.hoverBg != nil || el.hoverGroupShare != nil)
                ? hoverFrac
                : nearestGroupHoverFrac
            var childSteps: [EmitStepInput] = []
            if let children = childrenByParent[p.id] {
                let firstChildFade: Float = {
                    guard let fadeSpec = el.stickyConfig?.fade,
                          case .top = el.stickyConfig?.edge,
                          stickyShift.y > 0.01,
                          let pId = snap.parentIndex.map({ flatNodes[$0].nodeId }),
                          let siblings = childrenByParent[pId],
                          let mySibIdx = siblings.firstIndex(where: { $0.id == p.id }) else {
                        return 1.0
                    }
                    for nextIdx in (mySibIdx + 1)..<siblings.count {
                        let sib = siblings[nextIdx]
                        if sib.isExiting { continue }
                        guard let sibFlat = mountedNode(sib.id),
                              case .top = sibFlat.el.stickyConfig?.edge else {
                            continue
                        }
                        if let sibRect = presentedRectById[sib.id] {
                            return StickyMath.stuckFadeFactor(
                                nextSiblingTop: sibRect.top,
                                currentDrawnTop: rect.top,
                                lead: fadeSpec.lead,
                                span: fadeSpec.span
                            )
                        }
                    }
                    return 1.0
                }()
                let firstTreeChildId = children.first?.id
                let extraScrollY: Float = el.layout.scrollAxes.contains(.vertical) ? (slice2State.scrollExtraYByPath[snap.path] ?? 0) : 0
                var childSnap = boxSnap
                if let o = el.paintContain {
                    childSnap.containAt(SIMD2<Float>(o.x, o.y))
                }
                childSnap.scroll(1, by: snap.virtualWindowSnapOriginY)
                childSnap.scroll(0, by: -snap.scrollShift.x)
                childSnap.scroll(1, by: -(snap.scrollShift.y + extraScrollY))
                childSnap.off = boxSnap.off || !el.isPixelSnapEnabled || abs(p.rotate) >= 1e-6
                childSnap.steps = steps
                childSnap.shifted = snapShifted
                let opensFlightCover = flightCover == nil && childFlightCover != nil
                childSnap.layer = opensFlightCover ? 0 : snapLayer
                let paintsFrame = PixelSnap.frames(el, effectiveFill: fillColor, effectiveBorder: borderColor)
                childSnap.parent = (!opensFlightCover && childSnap.rigid == boxSnap.rigid && paintsFrame) ? snapRest : nil

                let childClip: MotionRect?
                let clipsChildren = el.layout.clipOverflow || el.clipRadius != nil || el.clipCorners != nil || el.clipFade != nil
                if clipsChildren {
                    let snappedPt = MotionRect(
                        left: snappedEdgesPx[0] / pxScale,
                        top: snappedEdgesPx[1] / pxScale,
                        right: snappedEdgesPx[2] / pxScale,
                        bottom: snappedEdgesPx[3] / pxScale
                    )
                    childClip = inh.clip.map { intersectRects($0, snappedPt) } ?? snappedPt
                } else {
                    childClip = inh.clip
                }

                let ownAnchorShift = (el.anchor != nil && !snap.isSticky)
                    ? Vec2(rect.x - scaledRawRect.x, rect.y - scaledRawRect.y)
                    : .zero
                let ownLiveOff = Vec2(ownRaw.left - p.rect.left, ownRaw.top - p.rect.top)
                let childOffsetDelta = Vec2(
                    inh.offsetDelta.x + ownLiveOff.x + ownAnchorShift.x,
                    inh.offsetDelta.y + ownLiveOff.y + ownAnchorShift.y - extraScrollY
                )
                let childFullDelta = Vec2(
                    inh.fullDelta.x + ownLiveOff.x + ownAnchorShift.x,
                    inh.fullDelta.y + ownLiveOff.y + ownAnchorShift.y - extraScrollY
                )
                let childScaleMotion: PaintScaleMotion = (childFlightCover != nil) ? .moving : nodeScaleMotion
                let childStillScale: Float = (childScaleMotion == .still) ? ((scaleVec.x + scaleVec.y) * 0.5) : inh.stillScale
                let childInCache = inh.inCache || ((el.runtimeExtra(RenderExtrasKey.cacheEnabled) as? Bool) ?? false)
                var reportedTurnClip = input.inh.reportedTurnClip
                if nodeTurn != nil && (ownHasTurn || clipsChildren) {
                    let outer = ownHasTurn ? parentReportClip : inheritedReportClip?.outer
                    let local = ownHasTurn ? nil : inheritedReportClip?.local
                    let clipped = clipsChildren ? (local.map { intersectRects($0, rect) } ?? rect) : local
                    reportedTurnClip = reportedTurnClips.count
                    reportedTurnClips.append((outer, clipped))
                }
                let childInh = PaintInh(
                    opacity: childAncestorOp,
                    scale: rawScaleVec,
                    anchor: anchor,
                    anchorTo: anchorTo,
                    offsetDelta: childOffsetDelta,
                    fullDelta: childFullDelta,
                    restOffset: nodeRestOffset,
                    snap: childSnap,
                    rowGlideY: rowGlideY,
                    scaleMotion: childScaleMotion,
                    stillScale: childStillScale,
                    parentDrawnWidth: rect.width,
                    parentTargetWidth: snap.targetRect.width,
                    parentMoving: nodeMoving,
                    rectSpringing: nodeRectSpringing,
                    clip: childClip,
                    inCache: childInCache,
                    reportedTurnClip: reportedTurnClip
                )
                let sorted = sortByZOrder(children)
                childSteps.reserveCapacity(sorted.count)
                for child in sorted {
                    childSteps.append(EmitStepInput(
                        p: child,
                        inh: childInh,
                        ancestorOpacity: childAncestorOp,
                        logicalOpacity: logicalAlpha,
                        ancestorBlur: effBlur,
                        inheritedExiting: nodeExiting,
                        ancestorTurn: nodeTurn,
                        outerTurnClip: nextOuterClip,
                        localTurnClip: childLocalTurnClip,
                        parentPath: snap.path,
                        nearestGroupHovered: nextGroupHovered,
                        nearestGroupHoverFrac: nextGroupHoverFrac,
                        nearestPressColor: effPressColor,
                        nearestPressFrac: effPressFrac,
                        flightCover: childFlightCover,
                        flightClipOverride: childFlightClip,
                        emitLiftedNow: emitLiftedNow,
                        parentStickyShift: stickyShift,
                        parentStickyMag: stickyMag,
                        kidsFadeOpacity: (child.id == firstTreeChildId) ? firstChildFade : 1.0
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
            inh: PaintInh,
            ancestorOpacity: Float,
            logicalOpacity: Float,
            ancestorBlur: Float,
            inheritedExiting: Bool,
            ancestorTurn: Turn?,
            outerTurnClip: MotionRect?,
            localTurnClip: MotionRect?,
            parentPath: String?,
            nearestGroupHovered: Bool,
            nearestGroupHoverFrac: Float,
            nearestPressColor: Color? = nil,
            nearestPressFrac: Float = 0.0,
            parentStickyShift: Vec2 = .zero,
            parentStickyMag: Float = 0,
            flightCover: FlightCoverTransform? = nil,
            flightClipOverride: MotionRect? = nil,
            emitLiftedNow: Bool = false
        ) {
            var workStack: [EmitWorkItem] = [
                .enter(EmitStepInput(
                    p: p,
                    inh: inh,
                    ancestorOpacity: ancestorOpacity,
                    logicalOpacity: logicalOpacity,
                    ancestorBlur: ancestorBlur,
                    inheritedExiting: inheritedExiting,
                    ancestorTurn: ancestorTurn,
                    outerTurnClip: outerTurnClip,
                    localTurnClip: localTurnClip,
                    parentPath: parentPath,
                    nearestGroupHovered: nearestGroupHovered,
                    nearestGroupHoverFrac: nearestGroupHoverFrac,
                    nearestPressColor: nearestPressColor,
                    nearestPressFrac: nearestPressFrac,
                    flightCover: flightCover,
                    flightClipOverride: flightClipOverride,
                    emitLiftedNow: emitLiftedNow,
                    parentStickyShift: parentStickyShift,
                    parentStickyMag: parentStickyMag,
                    kidsFadeOpacity: 1.0
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
                inh: PaintInh(snap: rootPixelSnap),
                ancestorOpacity: 1.0,
                logicalOpacity: 1.0,
                ancestorBlur: 0.0,
                inheritedExiting: false,
                ancestorTurn: nil,
                outerTurnClip: nil,
                localTurnClip: nil,
                parentPath: nil,
                nearestGroupHovered: false,
                nearestGroupHoverFrac: 0.0
            )
        }
        var raisedInfoPatches: [(offset: Int, items: [ElementInfo])] = []
        for lifted in liftedFlights {
            let isUnclippedFlight = lifted.isFlight && (
                launchedFlightIds.contains(lifted.node.id)
                    || unclippedMatchedFlightIds.contains(lifted.node.id)
            )
            var liftedInh = lifted.inh
            if isUnclippedFlight {
                liftedInh.clip = nil
                liftedInh.reportedTurnClip = nil
            }
            if lifted.isFlight && scene.hasEnteringAncestor(lifted.node.id) {
                liftedInh.scale = Vec2(1, 1)
                liftedInh.anchor = .zero
                liftedInh.anchorTo = .zero
            }
            let infoStart = infos.count
            emitSubtree(
                lifted.node,
                inh: liftedInh,
                ancestorOpacity: lifted.isFlight ? 1.0 : lifted.ancestorOpacity,
                logicalOpacity: lifted.isFlight ? 1.0 : lifted.logicalOpacity,
                ancestorBlur: lifted.ancestorBlur,
                inheritedExiting: lifted.inheritedExiting,
                ancestorTurn: lifted.ancestorTurn,
                outerTurnClip: lifted.outerTurnClip,
                localTurnClip: lifted.localTurnClip,
                parentPath: lifted.parentPath,
                nearestGroupHovered: lifted.nearestGroupHovered,
                nearestGroupHoverFrac: lifted.nearestGroupHoverFrac,
                nearestPressColor: lifted.nearestPressColor,
                nearestPressFrac: lifted.nearestPressFrac,
                parentStickyShift: lifted.parentStickyShift,
                parentStickyMag: lifted.parentStickyMag,
                flightCover: nil,
                flightClipOverride: isUnclippedFlight ? windowRect : nil,
                emitLiftedNow: true
            )
            if let insertAt = lifted.treeInfoOffset, infos.count > infoStart {
                let raisedItems = Array(infos[infoStart...])
                infos.removeSubrange(infoStart...)
                raisedInfoPatches.append((offset: insertAt, items: raisedItems))
            }
        }
        if !raisedInfoPatches.isEmpty {
            // Splice lifted `raise()` ElementInfo subtrees back at their authored DFS offsets.
            var merged: [ElementInfo] = []
            merged.reserveCapacity(infos.count + raisedInfoPatches.reduce(0) { $0 + $1.items.count })
            var cursor = 0
            for patch in raisedInfoPatches {
                let clamped = min(max(cursor, patch.offset), infos.count)
                if clamped > cursor {
                    merged.append(contentsOf: infos[cursor..<clamped])
                    cursor = clamped
                }
                merged.append(contentsOf: patch.items)
            }
            if cursor < infos.count {
                merged.append(contentsOf: infos[cursor...])
            }
            infos = merged
        }
        seenMatchedByFlightId = newSeenMatched
        let inspectedElementCount = infos.count
        let drawnSnapshot = FrameGeometry(byPath: newDrawnRectByPath)
        measureTextFlightDestinations(in: drawnSnapshot, at: now)

        if !activeTextFlights.isEmpty {
            forEachTextFlightGlyph(at: now) { glyph, deviceRect, ink, clip in
                primitives.append(textPrimitive(glyph, rect: deviceRect, ink: ink, clip: clip,
                                                forceScaled: true, at: primitives.count))
            }
            for entry in activeTextFlights {
                let (srcAlpha, _) = entry.state.alphas(
                    target: entry.state.destination,
                    now: now,
                    reducedMotion: reducedMotion
                )
                let presentedRect = entry.state.presented
                let targetSnap = mountedNode(entry.targetNodeId)
                let targetLeaf = entry.state.targetKey
                    .split(separator: "/")
                    .last
                    .map(String.init)
                    ?? entry.state.targetKey
                let flightText = entry.sourceText ?? targetSnap?.el.plainText ?? ""
                let flightColor = entry.sourceTextColor
                    ?? targetSnap?.el.textColor
                    ?? defaultViewFg
                infos.append(ElementInfo(
                    path: "flight-source/\(targetLeaf)",
                    key: nil,
                    parentIndex: nil,
                    role: .text,
                    geometry: .boxes(rect: presentedRect, target: entry.state.destination, visible: presentedRect),
                    opacity: srcAlpha,
                    scale: 1.0,
                    blur: 0,
                    radius: 0,
                    fill: .transparent,
                    textColor: flightColor,
                    text: flightText,
                    label: nil,
                    help: nil,
                    selected: nil,
                    expanded: nil,
                    level: nil,
                    itemSelected: false,
                    focusable: false,
                    focused: false,
                    focusVisible: false,
                    inert: true,
                    moving: true,
                    exiting: false,
                    hover: 0,
                    press: 0,
                    scrolled: [0, 0],
                    caret: nil,
                    secure: false,
                    disabled: false,
                    checked: nil,
                    a11yValue: nil,
                    a11yDescription: nil,
                    a11yHidden: true
                ))
            }
        }

        var idxByPathAndExit: [PaintElementKey: Int] = [:]
        idxByPathAndExit.reserveCapacity(infos.count)
        for (idx, info) in infos.enumerated() {
            idxByPathAndExit[PaintElementKey(path: info.path, exiting: info.exiting)] = idx
        }
        for idx in infos.indices {
            if infos[idx].path.hasPrefix("flight-source/") {
                infos[idx].parentIndex = nil
                continue
            }
            if let pPath = parentPathForInfo[PaintElementKey(path: infos[idx].path, exiting: infos[idx].exiting)] {
                let resolved = idxByPathAndExit[PaintElementKey(path: pPath, exiting: infos[idx].exiting)]
                    ?? idxByPathAndExit[PaintElementKey(path: pPath, exiting: !infos[idx].exiting)]
                infos[idx].parentIndex = (resolved != idx) ? resolved : nil
            } else if infos[idx].parentIndex == idx {
                infos[idx].parentIndex = nil
            }
        }
        linkBoxesByPath = newLinkBoxes
        appendLinkElements(to: &infos)
        lastElements = infos
        nativeInspection = NativeFrameInspection(
            rawPoseByPath: rawPoseByPath, landingHolds: frameLandingHoldIds,
            elementCount: inspectedElementCount, hasInheritedFlags: hasInheritedPose
        )
        landUnseenEntrances(on: &scene)
        endUnseenExits(on: &scene)
        if hasActiveMotionLoops(at: currentTime) {
            isAnimating = true
            animSources |= AnimSource.loop
        }
        imeCursorArea = nextImeCursorArea
        imeOptionAsAlt = nextImeOptionAsAlt
        noWindowDragRects = nextNoWindowDragRects
        presentedRectByPath = FrameGeometry(byPath: newRectByPath)
        presentedScales = PresentedScales(scaleByPath: newScaleByPath, motionById: nodeScaleMotionById)
        hitGeometryByPath = newHitGeometries
        paintOrderPaths = newPaintOrder
        drawnRectByPath = drawnSnapshot
        rectSpringingById = newRectSpringingById
        publishHoverOrder()
        // A hold draws nothing while it waits: its wake asks for the one frame that ends it.
        stepScrollNudges(at: currentTime)
        refreshHoverAfterPaint()
        kitHooks.unseenPresence.recordPostBuildFilterSeen(nodes: flatNodes)
        helpState.hits = newHelpHits
        helpState.interactiveHits = newInteractiveHits
        updateHelp(at: now, primitives: &primitives, recordGlyphPage: recordGlyphPage)
        surfaces = builtSurfaces
        finishSurfaceVideoPaint(surfaceVideo)
        _ = now
        lastPinnedGlyphMask = usedGlyphMask
        let glyphAtlases = textSystem.glyphAtlas.atlases
        for item in glyphPageEntries where item.index < primitives.count {
            primitives[item.index].params.x = Float(item.page)
        }

        // A later image can grow a shelf. Resolve UVs against the completed page table.
        let firstImageAtlas = imagePacker.atlas
        let imagePages = imagePacker.pageCount > 1 ? imagePacker.atlases : []
        func dimensions(_ atlas: RGBA8Atlas) -> SIMD4<Float> {
            let w = Float(atlas.width), h = Float(atlas.height)
            return SIMD4(w, h, w, h)
        }
        let firstSize = dimensions(firstImageAtlas)
        let imageSizes = imagePages.map(dimensions)
        var totalGlyphs = 0
        for i in primitives.indices {
            switch primitives[i].kind {
            case .glyph:
                totalGlyphs += 1
            case .image:
                let page = primitives[i].imagePage
                primitives[i].uv /= imageSizes.indices.contains(page) ? imageSizes[page] : firstSize
            default:
                break
            }
        }
        let shapedDelta = UInt32(truncatingIfNeeded: min(UInt64(UInt32.max), textSystem.shapedCallCount &- baselineShapedCount))
        FrameStatsSidecar.set(self, glyphs: totalGlyphs, shaped: shapedDelta)

        return RefScene(
            width: devW,
            height: devH,
            srgbBlend: srgbBlend,
            clearColor: clearColor.simd4(srgb: srgbBlend),
            glyphs: glyphAtlases[0],
            glyphPages: glyphAtlases.count > 1 ? glyphAtlases : [],
            images: firstImageAtlas,
            imagePages: imagePages,
            primitives: primitives
        )
    }

    internal func refreshHoverAfterPaint() {
        guard scrollOffsets != lastHoverScrollOffsets || frameHadCommitted || hoverHold.held || layoutMoving() else { return }
        lastHoverScrollOffsets = scrollOffsets
        guard activeDrag == nil, pointerPosition.x >= 0, pointerPosition.y >= 0,
              pointerPosition.x < viewport.x, pointerPosition.y < viewport.y else { return }
        let previous = hoveredPath
        let link = hoveredLink
        let wasHeld = hoverHold.held
        let retargeted = asInputObserver {
            refreshHoverAndSyncTracks(at: cxSettings.scaledTime(at: currentTime), wallNow: currentTime,
                                     cut: false, dispatchPolicy: .onHoldRelease)
        }
        if !hoverHold.held && pressedPath == nil, previous != hoveredPath {
            if updateMenuHoverHighlight(hoveredPath: hoveredPath) {
                suppressSelectionEffectsFromHoverCommit = true
                dirtyCommit(at: currentTime, inputChange: false)
            }
            if hasHoverVisualInChain(previous) || hasHoverVisualInChain(hoveredPath) {
                animSources |= AnimSource.live
            }
        }
        // A sent key ahead of this observer can mount a new handler before delivery.
        // An ordinary pending model update commits after the observer has run.
        if !wasHeld, previous != hoveredPath,
           !pendingSentKeys.isEmpty || !pendingPaintHovers.isEmpty || hoverCallbackPaths(to: hoveredPath) != hoveredCallbackPaths {
            pendingPaintHovers.append((hoveredPath, pendingSentKeys.count))
        }
        // A hover group can retarget even when the primary hit stays put.
        if retargeted || !pendingPaintHovers.isEmpty || hoveredLink != link || helpTargetChanges(at: pointerPosition) {
            animSources |= AnimSource.live
        }
        settleKitHoverDelays(at: pointerPosition, now: currentTime)
    }

    // MARK: - Pointer, Drag, Wheel & Keyboard Event Dispatch

    /// Hit-tests `(x, y)` in logical window points against presented non-exiting, non-inert elements.
    public func hitTestElement(at point: Vec2) -> ElementInfo? {
        guard let hit = hitTest(at: point) else { return nil }
        return elements().first(where: { $0.path == hit.node.path })
    }

    internal func hitTest(at point: Vec2, ignoreBlockers: Bool = false, predicate: ((FlatNode) -> Bool)? = nil) -> (node: FlatNode, rect: MotionRect)? {
        guard let detailed = hitTestDetailed(at: point, ignoreBlockers: ignoreBlockers, predicate: predicate) else { return nil }
        return (detailed.node, detailed.rect)
    }

    internal func hitTestDetailed(
        at point: Vec2,
        ignoreBlockers: Bool = false,
        canRepaintDuringQuery: Bool = false,
        predicate: ((FlatNode) -> Bool)? = nil
    ) -> (node: FlatNode, rect: MotionRect, localPoint: Vec2)? {
        let orderedPaths: [String]
        if !paintOrderPaths.isEmpty {
            orderedPaths = canRepaintDuringQuery ? paintOrderPaths :
                pickCandidates.inputPaths(at: point, order: paintOrderPaths, geometry: hitGeometryByPath)
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
                if hasActiveTextLinks(node.el) && !node.el.isSelectable && linkIndex(atPath: path, at: point) == nil {
                    continue
                }

                if !ignoreBlockers, let blocker = firstBlockerPath, !blocker.hasPrefix(path + "/") {
                    continue
                }
                if predicate == nil || predicate!(node) {
                    return (node, geom.rect, Vec2(localWindowPt.x - geom.rect.x, localWindowPt.y - geom.rect.y))
                }
                if !ignoreBlockers && firstBlockerPath == nil && (geom.hasVisualBlocker || geom.isInteractiveBlocker) {
                    firstBlockerPath = path
                }
            } else {
                if node.el.opacity <= 0.001 { continue }
                let infoRect = presentedRectByPath[path] ?? node.targetRect
                let hitBox = intersectRects(node.clipRect, infoRect)
                guard halfOpenContains(hitBox, point) else { continue }
                if hasActiveTextLinks(node.el) && !node.el.isSelectable && linkIndex(atPath: path, at: point) == nil {
                    continue
                }
                if !ignoreBlockers, let blocker = firstBlockerPath, !blocker.hasPrefix(path + "/") {
                    continue
                }
                if predicate == nil || predicate!(node) {
                    return (node, infoRect, Vec2(point.x - infoRect.x, point.y - infoRect.y))
                }
                let hasVis = node.el.background.a > 0.001 || node.el.gradient != nil ||
                    (node.el.borderWidth > 0 && node.el.borderColor.a > 0.001) ||
                    node.el.imagePayload != nil || node.el.pixelsPayload != nil || node.el.backdropBlur >= 0.5 || !node.el.shapes.isEmpty
                if !ignoreBlockers && firstBlockerPath == nil && (hasVis || node.el.explicitHit || node.el.isModal) {
                    firstBlockerPath = path
                }
            }
        }
        return nil
    }

    internal func hitTestAll(
        at point: Vec2,
        predicate: (FlatNode) -> Bool
    ) -> [(node: FlatNode, rect: MotionRect, localPoint: Vec2)] {
        let orderedPaths: [String]
        if !paintOrderPaths.isEmpty {
            orderedPaths = pickCandidates.inputPaths(at: point, order: paintOrderPaths, geometry: hitGeometryByPath)
        } else {
            let sortedIndices = flatNodes.indices.sorted { a, b in
                let za = flatNodes[a].zOrder
                let zb = flatNodes[b].zOrder
                if za != zb { return za < zb }
                return a < b
            }
            orderedPaths = sortedIndices.map { flatNodes[$0].path }
        }

        var firstBlockerPath: String? = nil
        var matches: [(node: FlatNode, rect: MotionRect, localPoint: Vec2)] = []

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
                if predicate(node) {
                    let sc = presentedScales[path] ?? Vec2(1, 1)
                    let sx = abs(sc.x) > 1e-6 ? sc.x : 1.0
                    let sy = abs(sc.y) > 1e-6 ? sc.y : 1.0
                    matches.append((node, geom.rect, Vec2((localWindowPt.x - geom.rect.x) / sx, (localWindowPt.y - geom.rect.y) / sy)))
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
                if predicate(node) {
                    let sc = presentedScales[path] ?? Vec2(1, 1)
                    let sx = abs(sc.x) > 1e-6 ? sc.x : 1.0
                    let sy = abs(sc.y) > 1e-6 ? sc.y : 1.0
                    matches.append((node, infoRect, Vec2((point.x - infoRect.x) / sx, (point.y - infoRect.y) / sy)))
                }
                let hasVis = node.el.background.a > 0.001 || node.el.gradient != nil ||
                    (node.el.borderWidth > 0 && node.el.borderColor.a > 0.001) ||
                    node.el.imagePayload != nil || node.el.pixelsPayload != nil || node.el.backdropBlur >= 0.5 || !node.el.shapes.isEmpty
                if firstBlockerPath == nil && (hasVis || node.el.explicitHit || node.el.isModal) {
                    firstBlockerPath = path
                }
            }
        }
        return matches
    }

    // MARK: - Internal Platform Input Bridges

    internal func dropTargetHitTest(at point: Vec2, for urls: [URL]) -> (path: String, key: String?, rect: MotionRect, spec: DropSpec<State>)? {
        // The app's URL filter can change the presented geometry before testing a lower target.
        guard let hit = hitTestDetailed(at: point, canRepaintDuringQuery: true, predicate: { node in
            guard let spec = node.el.handlers.drop else { return false }
            let (accepted, rejected) = spec.split(urls)
            return !accepted.isEmpty || (!rejected.isEmpty && spec.claimsRejects)
        }),
              let spec = hit.node.el.handlers.drop else {
            return nil
        }
        return (hit.node.path, hit.node.key, hit.rect, spec)
    }

    internal func rootDropTarget(for urls: [URL]) -> (path: String, key: String?, rect: MotionRect, spec: DropSpec<State>)? {
        let rootIdx: Int?
        if let mPath = activeModalPath, let mIdx = nodeByPath[mPath] {
            rootIdx = mIdx
        } else if !flatNodes.isEmpty {
            rootIdx = playgroundAppRootNodeIndex()
        } else {
            rootIdx = nil
        }
        guard let idx = rootIdx, flatNodes.indices.contains(idx) else { return nil }
        let node = flatNodes[idx]
        guard !node.effectiveInert, let spec = node.el.handlers.drop else { return nil }
        let (accepted, rejected) = spec.split(urls)
        guard !accepted.isEmpty || (!rejected.isEmpty && spec.claimsRejects) else { return nil }
        let rect = presentedRectByPath[node.path] ?? node.targetRect
        return (node.path, node.key, rect, spec)
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
            node = flatNodes.first(where: { matchesAuthoredKey($0.key, key) })
        }
        guard let matched = node, !matched.effectiveInert else { return nil }
        return presentedRectByPath[matched.path] ?? matched.targetRect
    }

    internal func releasePointerForPopup(at now: Double) {
        primaryPointerHeld = false
        secondaryPointerHeld = false
        armedDragOut = nil
        activeDrag = nil
        pressedPath = nil
        pressedKey = nil
        syncPressScale(at: cxSettings.scaledTime(at: now), cut: false)
        pressedLink = nil
        pointerExit(at: now)
    }

    internal func releasePointerForDragOut(at now: Double) {
        primaryPointerHeld = false
        secondaryPointerHeld = false
        activeDrag = nil
        pressedPath = nil
        pressedKey = nil
        syncPressScale(at: cxSettings.scaledTime(at: now), cut: false)
        pressedLink = nil
        hoveredLink = nil
        // `start_drag_out`: `drop_press()` then `pointer_leave()`, which, with nothing captured,
        // forgets the pointer (`pointer = None`) until the next move.
        pointerPosition = Vec2(-10000, -10000)
        if hoveredPath != nil {
            hoveredPath = nil
            hoveredKey = nil
        }
        if !hoveredCallbackPaths.isEmpty {
            isDispatchingHover = true
            dispatchHoverCallbacks(to: nil, at: now)
            isDispatchingHover = false
        }
        dirtyCommit(at: now, why: CommitWhy.input)
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

    private func hoverCallbackPaths(to newPath: String?) -> [String] {
        var desired: [String] = []
        if let path = newPath, var cur = nodeByPath[path] {
            var chain: [String] = []
            while flatNodes.indices.contains(cur) {
                let node = flatNodes[cur]
                if node.effectiveInert { break }
                if !node.el.hasKitHoverDelays && node.el.handlers.onHover != nil {
                    chain.append(node.path)
                }
                if node.el.isHoverAlone { break }
                guard let p = node.parentIndex else { break }
                cur = p
            }
            desired = chain.reversed()
        }
        return desired
    }

    /// Fresh paint can move an authored hover under a stationary pointer. Deliver it
    /// with the next actions, before input that arrived after that paint.
    internal func dispatchPendingPaintHover(at now: Double) {
        guard !pendingPaintHovers.isEmpty else { return }
        let actions = pendingPaintHovers
        pendingPaintHovers = []
        var keysRun = 0
        for action in actions {
            if action.priorSentKeys > keysRun {
                flushPendingSentKeys(at: now, prefix: action.priorSentKeys - keysRun)
                keysRun = action.priorSentKeys
            }
            let route = hoverCallbackPaths(to: action.path)
            guard route != hoveredCallbackPaths else { continue }
            asInputObserver {
                let previous = isDispatchingHover
                isDispatchingHover = true
                defer { isDispatchingHover = previous }
                InputTime.withArrival(nil) {
                    let (ran, allLiveOnly) = dispatchHoverCallbacks(route, at: now, fromPaint: true)
                    if ran && !allLiveOnly { suppressSelectionEffectsFromHoverCommit = true }
                }
            }
        }
    }

    @discardableResult
    internal func dispatchHoverCallbacks(to newPath: String?, at now: Double) -> (ranAny: Bool, allLiveOnly: Bool) {
        dispatchHoverCallbacks(hoverCallbackPaths(to: newPath), at: now)
    }

    @discardableResult
    private func dispatchHoverCallbacks(_ desired: [String], at now: Double, fromPaint: Bool = false) -> (ranAny: Bool, allLiveOnly: Bool) {
        let oldSet = Set(hoveredCallbackPaths)
        let newSet = Set(desired)
        let exited = hoveredCallbackPaths.reversed().filter { !newSet.contains($0) }
        let entered = desired.filter { !oldSet.contains($0) }
        hoveredCallbackPaths = desired
        var ranAny = false
        var allLiveOnly = true
        func dispatch(_ path: String, inside: Bool) {
            guard let idx = nodeByPath[path], !flatNodes[idx].el.hasKitHoverDelays,
                  let cb = flatNodes[idx].el.handlers.onHover else { return }
            var tx = makeTx(at: now)
            if fromPaint {
                tx.eventInputTime = nil
                tx.runtimeActions[Tx.inputTimeKey] = nil
            }
            cb(&state, inside, &tx)
            if !tx.liveOnlyRequested { perfWatch.meter.handler(name: "on_hover", path: path) }
            ranAny = true
            allLiveOnly = allLiveOnly && tx.liveOnlyRequested
            applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested, liveOnlyLabel: "onHover",
                    why: fromPaint ? CommitWhy.dirty : CommitWhy.input, countAsInput: !fromPaint)
        }
        for path in exited { dispatch(path, inside: false) }
        for path in entered { dispatch(path, inside: true) }
        return (ranAny, allLiveOnly)
    }

    public func pointerExit(at now: Double) {
        dispatchPendingPaintHover(at: now)
        wheelLost()
        hoverHold = HoverHold()
        pointerPosition = Vec2(-10000, -10000)
        if hoveredLink != nil {
            hoveredLink = nil
            dirtyCommit(at: now, why: CommitWhy.input)
        }
        if helpState.tipState != .idle {
            dirtyCommit(at: now, why: CommitWhy.input)
        }
        var exitedHover = false
        if let old = hoveredPath {
            hoveredPath = nil
            hoveredKey = nil
            if hoverVisualNeedsCommit(oldPath: old, newPath: nil) {
                exitedHover = true
            }
        }
        if updateMenuHoverHighlight(hoveredPath: nil) {
            exitedHover = true
        }
        if !hoveredCallbackPaths.isEmpty {
            isDispatchingHover = true
            let (ranAnyHover, hoverAllLiveOnly) = dispatchHoverCallbacks(to: nil, at: now)
            isDispatchingHover = false
            if ranAnyHover && !hoverAllLiveOnly {
                exitedHover = true
            }
        }
        if exitedHover {
            dirtyCommit(at: now, why: CommitWhy.input)
        }
        settleKitHoverDelays(at: pointerPosition, now: now)
        syncHoverTracks(at: cxSettings.scaledTime(at: now), cut: false, held: false)
        applyHoverWithin([], held: false, at: now)
    }

    /// `hover.rs::update_interaction`'s `down`: the element is allowed (`focus.rs::allowed`: not
    /// inert, not behind a modal) and holds the captured press (the primary press, else the
    /// secondary capture) with the pointer inside, or a middle/secondary button's tint over it.
    internal func isNodePressedVisually(path: String, effectiveInert: Bool, restingContains: Bool? = nil) -> Bool {
        guard !effectiveInert else { return false }
        if activeModalPath != nil && !modalMemberPaths.contains(path) { return false }
        if let pressed = pressedPath {
            if pressed == path && pressedPointerInside { return true }
        } else if case .held(let captured, _, _) = inputMachines.secondaryCapture, captured == path,
                  restingContains ?? pressRestingContains(path: path, at: pointerPosition) {
            return true
        }
        if pressedTint?.path == path {
            return restingContains ?? pressRestingContains(path: path, at: pointerPosition)
        }
        return false
    }

    internal func isNodePressedVisually(_ node: FlatNode, restingContains: Bool) -> Bool {
        isNodePressedVisually(path: node.path, effectiveInert: node.effectiveInert, restingContains: restingContains)
    }

    internal func applyPressColor(_ pressColor: Color?, to base: Color, frac: Float) -> Color {
        guard let pressColor, frac > 0.0005 else { return base }
        return base.mix(with: pressColor, t: frac)
    }

    internal func primaryPressHitPredicate(_ node: FlatNode) -> Bool {
        let h = node.el.handlers
        return h.onClick != nil || h.onClickPress != nil || h.onBackgroundPress != nil || h.onDoubleClick != nil ||
            h.onPointerDown != nil || h.onDrag != nil || h.dragOut != nil ||
            node.el.attachedDragOutItem != nil || h.editLens != nil ||
            nodeTakesFocus(node.el) || node.el.pressBg != nil || node.el.pressColor != nil || node.el.pressScaleFactor != nil ||
            node.el.isModal || node.el.pressFocusesBelow || (node.el.role == .button && node.el.explicitHit)
    }

    internal func tintDown(at pos: Vec2, button: PointerButton, at now: Double) {
        if pressedPath != nil && pressedButton == .primary { return }
        if let (target, _, _) = hitTestDetailed(at: pos, predicate: primaryPressHitPredicate) {
            pressedTint = (path: target.path, button: button)
            syncPressScale(at: cxSettings.scaledTime(at: now), cut: false)
            if nodeHasPressVisuals(target) {
                dirtyCommit(at: now, why: CommitWhy.input)
            }
        } else {
            pressedTint = nil
            syncPressScale(at: cxSettings.scaledTime(at: now), cut: false)
        }
    }

    public func cancelPointerForTouchHold(at now: Double) {
        armedDragOut = nil
        endKitPressRepeat()
        cancelKitHoverAndRepeatOnPress()
        _ = cancelActiveDrag(at: nil, time: now)
        primaryPointerHeld = false
        pressedPath = nil
        pressedKey = nil
        pressedButton = .primary
        pressedPointerInside = false
        pressedTint = nil
        pressedLink = nil
        syncPressScale(at: cxSettings.scaledTime(at: now), cut: false)
        dirtyCommit(at: now)
    }

    public func pointerMove(to pos: Vec2, mods: Mods = .none, at now: Double) {
        let inputMark = beginInputDispatch(at: now)
        defer { endInputDispatch(inputMark) }
        let prevMods = slice2State.currentMods
        let prevTime = slice2State.currentInputTime
        slice2State.currentMods = mods
        slice2State.currentInputTime = now
        defer {
            slice2State.currentMods = prevMods
            slice2State.currentInputTime = prevTime
        }
        if slice2State.autoscroll.move(to: pos, at: now) { wakeAt(now) }
        let moved = pos != pointerPosition
        // A drag reads the field's layout where it goes (`reads_text_layout`).
        if moved && primaryPointerHeld && !textRows.isEmpty { fillTextNear() }
        if moved {
            hoverPaused = false
            releaseHoverHold()
            resetKitHoverHoldOnPointerMove()
            if var pair = inputMachines.currentDoubleClickPair {
                if !PressRun.withinSlop(pair.downPoint, pos) {
                    pair.moved = true
                }
                inputMachines.currentDoubleClickPair = pair
            }
            if let rPath = pressedPath, let idx = nodeByPath[rPath] {
                let rect = presentedRectByPath[rPath] ?? flatNodes[idx].targetRect
                inputMachines.pressedStillInside = hitGeometryByPath[rPath]?.contains(pos) ?? halfOpenContains(rect, pos)
            }
        }
        let prevPos = pointerPosition
        pointerPosition = pos
        if moved && (pressedPath != nil || pressedTint != nil) {
            let prevPressedInside = pressedPointerInside
            if let pPath = pressedPath {
                pressedPointerInside = pressRestingContains(path: pPath, at: pos)
            }
            let pressedChanged = pressedPath != nil && pressedPointerInside != prevPressedInside
            let tintChanged: Bool = {
                guard let tint = pressedTint else { return false }
                return pressRestingContains(path: tint.path, at: pos) != pressRestingContains(path: tint.path, at: prevPos)
            }()
            if pressedChanged || tintChanged {
                syncPressScale(at: cxSettings.scaledTime(at: now), cut: false)
                let pVisual = pressedChanged && (pressedPath.flatMap { nodeByPath[$0] }.map { nodeHasPressVisuals(flatNodes[$0]) } ?? false)
                let tVisual = tintChanged && (pressedTint.flatMap { nodeByPath[$0.path] }.map { nodeHasPressVisuals(flatNodes[$0]) } ?? false)
                if pVisual || tVisual {
                    dirtyCommit(at: now, why: CommitWhy.input)
                }
            }
        }

        let moveHits = hitTestAll(at: pos, predicate: { $0.el.handlers.onPointerMove != nil })
        var moveDispatched = false
        var moveAllLiveOnly = true
        for moveHit in moveHits {
            if let onMove = moveHit.node.el.handlers.onPointerMove {
                let press = PointerPress(
                    window: pos,
                    local: moveHit.localPoint,
                    elementSize: Vec2(moveHit.rect.width, moveHit.rect.height),
                    button: .primary,
                    mods: mods,
                    clicks: 0
                )
                var tx = makeTx(at: now)
                onMove(&state, press, &tx)
                moveDispatched = true
                if !tx.liveOnlyRequested {
                    moveAllLiveOnly = false
                }
                applyTx(tx, at: now, liveOnlyLabel: "onPointerMove")
            }
        }

        if checkArmedDragOutMove(to: pos, at: now) {
            return
        }

        if handleSelectablePointerMove(to: pos, mods: mods, at: now) {
            return
        }

        // Active drag capture takes priority over hover
        if var drag = activeDrag {
            if !drag.movedBeyondSlop,
               !PressRun.withinSlop(drag.startWindow, pos) {
                drag.movedBeyondSlop = true
            }
            drag.lastWindow = pos
            drag.mods = mods
            activeDrag = drag
            if let idx = nodeByPath[drag.path] {
                let node = flatNodes[idx]
                if drag.isTextSelectionDrag, let editLens = node.el.handlers.editLens {
                    var edit = editLens.get(state)
                    let stateRevealed = edit.isRevealed
                    if node.el.isSecure {
                        edit.isSecure = true
                        if let revealed = node.el.revealedOverride { edit.isRevealed = revealed }
                    }
                    if !edit.isHiddenMultiline {
                        let isSecure = edit.isSecure || node.el.isSecure
                        let hit = textCaretHit(node: node, windowPos: pos, edit: edit)
                        let offset = hit.utf8Offset
                        if !isSecure, drag.clicks == 2, let origin = drag.textSelectionOrigin {
                            let unit = edit.wordUnitRange(atUTF8Offset: offset)
                            let ext = SelectionMath.extendSelection(origin: origin, at: unit)
                            edit.setCursor(utf8Offset: ext.anchor, extendSelection: false)
                            edit.setCursor(utf8Offset: ext.focus, extendSelection: true)
                        } else if !isSecure, drag.clicks >= 3, edit.multiline, let origin = drag.textSelectionOrigin {
                            let unit = edit.hardLineParagraphRange(atUTF8Offset: offset)
                            let ext = SelectionMath.extendSelection(origin: origin, at: unit)
                            edit.setCursor(utf8Offset: ext.anchor, extendSelection: false)
                            edit.setCursor(utf8Offset: ext.focus, extendSelection: true)
                        } else {
                            edit.setCursor(hit, extendSelection: true)
                        }
                    } else {
                        let end = edit.text.utf8.count
                        edit.setCursor(utf8Offset: end, extendSelection: false)
                    }
                    edit.isRevealed = stateRevealed
                    editLens.set(&state, edit)
                    pendingCommitKind = pendingCommitKind.instant()
                    dirtyCommit(at: now, why: CommitWhy.input)
                } else if let onDrag = node.el.handlers.onDrag {
                    let sx = abs(drag.startScale.x) > 1e-6 ? drag.startScale.x : 1.0
                    let sy = abs(drag.startScale.y) > 1e-6 ? drag.startScale.y : 1.0
                    let d = Drag(
                        window: pos,
                        local: Vec2((pos.x - drag.startElementOrigin.x) / sx, (pos.y - drag.startElementOrigin.y) / sy),
                        delta: Vec2(pos.x - drag.startWindow.x, pos.y - drag.startWindow.y),
                        startLocal: drag.startLocal,
                        size: drag.elementSize,
                        clicks: drag.clicks,
                        mods: mods,
                        phase: .move,
                        screen: screenPixels(at: pos)
                    )
                    var tx = makeTx(at: now, button: drag.button)
                    onDrag(&state, d, &tx)
                    if !tx.askedMotion && !tx.liveOnlyRequested { tx.instant() }
                    applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested, liveOnlyLabel: "onDrag")
                    armKitDragRepeatIfRequested(path: drag.path, now: now)
                }
            }
            return
        }

        _ = refreshHover(
            at: now,
            isPointerEvent: true,
            moveDispatched: moveDispatched,
            moveAllLiveOnly: moveAllLiveOnly
        )
    }

    private func hasHoverVisualInChain(_ path: String?) -> Bool {
        var idxOpt = path.flatMap { nodeByPath[$0] }
        while let idx = idxOpt {
            let el = flatNodes[idx].el
            if el.hoverBg != nil || el.isHoverGroup || el.isHoverAlone || el.hoverGroupShare != nil {
                return true
            }
            idxOpt = flatNodes[idx].parentIndex
        }
        return false
    }

    @discardableResult
    private func refreshHover(
        at now: Double,
        isPointerEvent: Bool,
        updateHoverHighlight: Bool = true,
        moveDispatched: Bool = false,
        moveAllLiveOnly: Bool = true
    ) -> Bool {
        let pos = pointerPosition
        let hit: (node: FlatNode, rect: MotionRect)?
        if let pp = pressedPath {
            if pressRestingContains(path: pp, at: pos),
               let pIdx = nodeByPath[pp],
               flatNodes.indices.contains(pIdx),
               !flatNodes[pIdx].effectiveInert {
                let pNode = flatNodes[pIdx]
                hit = (pNode, presentedRectByPath[pp] ?? pNode.targetRect)
            } else {
                hit = nil
            }
        } else {
            hit = hitTest(at: pos) { node in
                Self.hoverHitPredicate(node) || self.hasActiveTextLinks(node.el)
            }
        }

        let newHoveredLink: TextLinkTarget? = {
            guard let hitNode = hit?.node,
                  self.hasActiveTextLinks(hitNode.el),
                  let linkIdx = self.linkIndex(atPath: hitNode.path, at: pos) else {
                return nil
            }
            return TextLinkTarget(path: hitNode.path, key: hitNode.key, linkIndex: linkIdx)
        }()
        let linkChanged = (newHoveredLink != hoveredLink)

        if !hoverHold.held && pressedPath == nil {
            if linkChanged {
                hoveredLink = newHoveredLink
            }
            let newPath = hit?.node.path
            let newKey = hit?.node.key
            var changed = false
            let oldPath = hoveredPath
            if newPath != hoveredPath {
                hoveredPath = newPath
                hoveredKey = newKey
                let menuHoverChanged = updateMenuHoverHighlight(hoveredPath: newPath)
                if isPointerEvent {
                    isDispatchingHover = true
                    let (ranAnyHover, hoverAllLiveOnly) = dispatchHoverCallbacks(to: newPath, at: now)
                    isDispatchingHover = false
                    let hoverNeedsCommit = (ranAnyHover && !hoverAllLiveOnly)
                        || (moveDispatched && !moveAllLiveOnly)
                        || linkChanged
                        || helpTargetChanges(at: pos)
                        || menuHoverChanged
                    if hoverNeedsCommit {
                        suppressSelectionEffectsFromHoverCommit = true
                        dirtyCommit(at: now, why: isPointerEvent ? CommitWhy.input : CommitWhy.dirty, inputChange: false)
                        changed = true
                    }
                } else if linkChanged || menuHoverChanged || hasHoverVisualInChain(oldPath) || hasHoverVisualInChain(newPath) || helpTargetChanges(at: pos) {
                    suppressSelectionEffectsFromHoverCommit = true
                    dirtyCommit(at: now, why: isPointerEvent ? CommitWhy.input : CommitWhy.dirty, inputChange: false)
                    changed = true
                }
            } else if linkChanged || helpTargetChanges(at: pos) {
                dirtyCommit(at: now, why: isPointerEvent ? CommitWhy.input : CommitWhy.dirty, inputChange: false)
                changed = true
            }
            syncHoverTracks(at: cxSettings.scaledTime(at: now), cut: false, held: false)
            if let within = computeHoverWithin() {
                applyHoverWithin(within.inside, held: false, at: now)
            }
            let focusedIsInput = focusedPath.flatMap { focusedInputElement(at: $0) }
                .map { $0.handlers.editLens != nil || $0.role == .textInput } ?? false
            if isPointerEvent && updateHoverHighlight && !focusedIsInput {
                if let rIdx = hit.flatMap({ highlightRowIndex(for: $0.node.index) }) {
                    let rNode = flatNodes[rIdx]
                    if focusedPath != rNode.path || !hoveredHighlightActive {
                        focusedPath = rNode.path
                        focusedKey = rNode.key
                        hoveredHighlightActive = true
                        dirtyCommit(at: now, why: isPointerEvent ? CommitWhy.input : CommitWhy.dirty)
                        changed = true
                    }
                } else if hoveredHighlightActive {
                    hoveredHighlightActive = false
                    dirtyCommit(at: now, why: isPointerEvent ? CommitWhy.input : CommitWhy.dirty)
                    changed = true
                }
            }
            settleKitHoverDelays(at: pos, now: now)
            return changed
        } else {
            if pressedPath != nil {
                syncPressScale(at: cxSettings.scaledTime(at: now), cut: false)
            }
            if helpTargetChanges(at: pos) {
                dirtyCommit(at: now, why: isPointerEvent ? CommitWhy.input : CommitWhy.dirty, inputChange: false)
            }
        }
        settleKitHoverDelays(at: pos, now: now)
        return false
    }

    /// Dispatches both supported click callback signatures with the original pointer event.
    /// Returns whether all invoked callbacks requested a live-only update.
    internal func dispatchPointerClick(_ node: FlatNode, press: PointerPress, at now: Double, touchTap: Bool = false) -> Bool? {
        let handlers = node.el.handlers
        guard handlers.hasPress else { return nil }
        logInputEvent("press \(node.path)")
        dropOwedFocus(keepingSplit: true)
        let mods = press.mods == .none ? nil : press.mods
        var liveOnly = true
        if let callback = handlers.onClick {
            var tx = makeTx(at: now, button: press.button, mods: mods)
            tx.pressWasTouchTap = touchTap
            callback(&state, &tx)
            liveOnly = tx.liveOnlyRequested
            applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
        }
        if let callback = handlers.onClickPress {
            var tx = makeTx(at: now, button: press.button, mods: mods)
            tx.pressWasTouchTap = touchTap
            callback(&state, press, &tx)
            liveOnly = liveOnly && tx.liveOnlyRequested
            applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
        }
        if let background = handlers.onBackgroundPress {
            var tx = makeTx(at: now, button: press.button, mods: mods)
            tx.pressWasTouchTap = touchTap
            background(&state, press, &tx)
            liveOnly = liveOnly && tx.liveOnlyRequested
            applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
        }
        return liveOnly
    }

    public func pointerDown(at pos: Vec2, button: PointerButton = .primary, mods: Mods = .none, at now: Double) {
        pressDown(at: pos, button: button, mods: mods, at: now, mouse: true)
    }

    internal func pressDown(at pos: Vec2, button: PointerButton = .primary, mods: Mods = .none, at now: Double, mouse: Bool) {
        let inputMark = noteInput(at: now)
        let focusBeforePress = focusedPath
        defer {
            // A press that moved focus ran an input action (`Action::FocusControl`, `Action::Blur`)
            // that changed something (`r`).
            if focusedPath != focusBeforePress { noteHandlerChange() }
            endInputDispatch(inputMark)
        }
        if mouse && slice2State.autoscroll.press(button) {
            pointerPosition = pos
            return
        }
        if !textRows.isEmpty { fillTextNear() }
        let prevMods = slice2State.currentMods
        let prevTime = slice2State.currentInputTime
        slice2State.currentMods = mods
        slice2State.currentInputTime = now
        defer {
            slice2State.currentMods = prevMods
            slice2State.currentInputTime = prevTime
        }
        releaseHoverHold()
        if button != .secondary {
            primaryPointerHeld = true
            kitHooks.titlebar.action = nil
            cancelKitHoverAndRepeatOnPress()
            endKitPressRepeat()
            pressHoverDelays()
            hoverPaused = true
        }
        suppressSelectionEffectsFromHoverCommit = false
        pointerPosition = pos
        focusVisible = false
        hoveredHighlightActive = false
        inputMachines.focusMachine.lastPressedWasPointer = true
        // Every press dismisses the tooltip, a press on its own trigger too (`press_help` is gone, #1013).
        dismissHelp(at: now)

        if button != .primary {
            inputMachines.pressClicks.clear()
            clickCount = 1
            lastClickTime = -.infinity
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
                    var tx = makeTx(at: now)
                    dismiss(&state, &tx)
                    applyTx(tx, at: now)
                }
                return
            }
        }

        if button == .secondary {
            secondaryPointerHeld = true
            tintDown(at: pos, button: .secondary, at: now)
            if let (node, rect, local) = hitTestDetailed(at: pos, predicate: {
                $0.el.handlers.onSecondaryClick != nil ||
                $0.el.handlers.editLens != nil ||
                ($0.el.handlers.onLinkSecondary != nil && self.hasActiveTextLinks($0.el) && self.linkIndex(atPath: $0.path, at: pos) != nil)
            }) {
                recordSecondaryTitlebarDown(at: pos, captured: true)
                if self.hasActiveTextLinks(node.el),
                   let linkIdx = self.linkIndex(atPath: node.path, at: pos),
                   dispatchLinkDown(node: node, linkIdx: linkIdx, at: pos, button: .secondary, mods: mods, at: now) {
                    return
                }
                if let onSecondary = node.el.handlers.onSecondaryClick {
                    let press = PointerPress(
                        window: pos,
                        local: local,
                        elementSize: Vec2(rect.width, rect.height),
                        button: .secondary,
                        mods: mods,
                        clicks: 1
                    )
                    var tx = makeTx(at: now, button: .secondary)
                    logEvent("secondary press \(node.path)")
                    onSecondary(&state, press, &tx)
                    applyTx(tx, at: now)
                    return
                }
                if node.el.handlers.editLens != nil {
                    logEvent("secondary press \(node.path)")
                    _ = openFieldMenu(node: node, at: pos, fromPointer: true, at: now)
                    return
                }
                return
            } else {
                let captured = isSecondaryTextOrInputHit(at: pos)
                if let (hitNode, _, _) = hitTestDetailed(at: pos, predicate: { _ in true }) {
                    logEvent("secondary press \(hitNode.path)")
                }
                handleSelectableSecondaryClick(at: pos, at: now)
                recordSecondaryTitlebarDown(at: pos, captured: captured)
            }
            return
        }

        if button != .primary && pressedPath != nil {
            pointerPosition = pos
            return
        }
        if button == .primary && pressedPath != nil && pressedButton != .primary {
            pointerPosition = pos
            return
        }
        if button == .middle {
            tintDown(at: pos, button: .middle, at: now)
            #if os(Linux)
            if mouse && primaryPasteDown(at: pos, now: now) { return }
            #endif
        }

        playgroundPointerDown(at: pos, at: now)
        var interactiveHit = hitTestDetailed(at: pos) { node in
            let h = node.el.handlers
            if button != .primary {
                let optedIn = h.pointerButtons?.contains(button) == true
                    && (h.onClick != nil || h.onClickPress != nil || h.onBackgroundPress != nil || h.onPointerDown != nil || h.onDrag != nil)
                if optedIn { return true }
                guard button == .middle else { return false }
                if h.onLink != nil && self.hasActiveTextLinks(node.el) && self.linkIndex(atPath: node.path, at: pos) != nil {
                    return true
                }
                return h.onMiddlePress != nil
            }
            return self.primaryPressHitPredicate(node) || node.el.isSelectable
        }

        if button == .primary, let text = interactiveHit?.node, text.el.isSelectable,
           !primaryPressHitPredicate(text), !(hasActiveTextLinks(text.el) && linkIndex(atPath: text.path, at: pos) != nil) {
            let receiver = selectablePressReceiver(text, handles: primaryPressHitPredicate)
            if receiver.index != text.index, let hit = hitTestDetailed(at: pos, predicate: { $0.index == receiver.index }) {
                interactiveHit = hit
            }
        }

        guard let (node, rect, rawLocal) = interactiveHit else {
            #if os(Windows) || os(Linux)
            if mouse && button == .middle { startMiddleAutoscroll(at: pos, now: now) }
            #endif
            if button == .primary {
                recordTitlebarPressOnMiss(at: pos, button: button, now: now)
                inputMachines.pressClicks.clear()
                inputMachines.firstDoubleClick = nil
                inputMachines.currentDoubleClickPair = nil
                if cxSettings.viewDefaults.webFocus, let bgHit = hitTest(at: pos, predicate: { _ in true }) {
                    webFocusTabStartPath = bgHit.node.path
                }
                handleSelectablePointerDown(at: pos, button: button, mods: mods, hitInteractiveNode: nil, at: now)
                if let prevFp = focusedPath {
                    let prevNode = nodeByPath[prevFp].map { flatNodes[$0] }
                    handleKitFocusTransition(prevNode: prevNode, newPath: nil, at: now)
                    finishPreeditIfNeeded(forPath: prevFp, at: now)
                    focusedPath = nil
                    focusedKey = nil
                    inputMachines.focusMachine.highlightedPath = nil
                    inputMachines.focusMachine.hoveredHighlight = false
                    focusKeyboard = false
                    blurredFocusPath = prevFp
                    focusHandoff = false
                    imeReset = true
                    dirtyCommit(at: now, why: CommitWhy.input)
                }
            }
            return
        }

        if hasActiveTextLinks(node.el), let linkIdx = linkIndex(atPath: node.path, at: pos) {
            if button == .primary {
                handleSelectablePointerDown(at: pos, button: button, mods: mods, hitInteractiveNode: node, at: now)
            }
            if dispatchLinkDown(node: node, linkIdx: linkIdx, at: pos, button: button, mods: mods, at: now) {
                return
            }
        }

        let optedButton = (button == .primary) || (node.el.handlers.pointerButtons?.contains(button) == true)
        let preservesSel = preservesTextSelectionInChain(node)
        let preservesFocus = preservesFocusOnPressInChain(node) || node.el.preservesFocusOnPress
        let inEditSubtree = isInsideEditLensSubtree(node)
        let onLink = hasActiveTextLinks(node.el)
        if button == .primary {
            let pendingPair = inputMachines.firstDoubleClick
            inputMachines.firstDoubleClick = nil
            // Shift+click extends a field's selection and never starts a multiclick (`selection/click.rs:154`).
            let clicks = shiftClickCount(node: node, mods: mods) ?? inputMachines.pressClicks.press(path: node.path, at: now, point: pos, interval: doubleClickInterval)
            clickCount = Int(clicks)
            lastClickTime = now
            lastClickPos = pos
            let isSecond = node.el.handlers.onDoubleClick != nil && pendingPair.map {
                $0.path == node.path && PressRun.follows(then: $0.at, was: $0.point, now: now, point: pos, interval: doubleClickInterval)
            } == true
            inputMachines.currentDoubleClickPair = (downAt: now, downPoint: pos, isSecond: isSecond, moved: false, left: false)
            inputMachines.pressedWindowPoint = pos
            inputMachines.pressedStillInside = true
        } else {
            inputMachines.pressedWindowPoint = pos
            inputMachines.pressedStillInside = true
        }
        if button == .primary {
            handleSelectablePointerDown(at: pos, button: button, mods: mods, hitInteractiveNode: node, at: now)
        }
        pressedPath = node.path
        activatedOnPointerDown = false
        pressedByTouch = !mouse
        pressedKey = node.key
        pressedButton = button
        pressedPointerInside = true
        syncPressScale(at: cxSettings.scaledTime(at: now), cut: false)
        // `inputMachines.pressedButton` is the same store as `pressedButton` (set above).
        if optedButton && cxSettings.viewDefaults.webFocus && !preservesSel && !preservesFocus {
            webFocusTabStartPath = node.path
        }
        let isTextBox = node.el.handlers.editLens != nil
        // A press in a text field (`Action::Focus`) takes over from a `Tx.focusWhenShown` still waiting.
        if optedButton && isTextBox { dropOwedFocus(keepingSplit: true) }
        var downFocusChanged = false
        if optedButton {
            if node.el.pressFocusesBelow {
                if let belowNode = scrollRegionBelow(node: node, at: pos) {
                    if focusedPath != belowNode.path {
                        let prevNode = focusedPath.flatMap { nodeByPath[$0] }.map { flatNodes[$0] }
                        handleKitFocusTransition(prevNode: prevNode, newPath: belowNode.path, at: now)
                        finishPreeditIfNeeded(forPath: focusedPath, at: now)
                        imeReset = true
                        downFocusChanged = true
                    }
                    assignFocusPath(belowNode.path, keyboard: false)
                    focusedKey = belowNode.key
                    inputMachines.focusMachine.highlightedPath = nil
                    inputMachines.focusMachine.hoveredHighlight = false
                    focusKeyboard = false
                    blurredFocusPath = nil
                    focusHandoff = false
                    webFocusTabStartPath = nil
                } else if let prevFp = focusedPath {
                    let prevNode = nodeByPath[prevFp].map { flatNodes[$0] }
                    handleKitFocusTransition(prevNode: prevNode, newPath: nil, at: now)
                    finishPreeditIfNeeded(forPath: prevFp, at: now)
                    focusedPath = nil
                    focusedKey = nil
                    inputMachines.focusMachine.highlightedPath = nil
                    inputMachines.focusMachine.hoveredHighlight = false
                    focusKeyboard = false
                    blurredFocusPath = prevFp
                    focusHandoff = false
                    imeReset = true
                    downFocusChanged = true
                }
            } else {
                let focusableTarget: FlatNode? = {
                    if isTextBox || (!preservesFocus && nodeTakesFocus(node.el)) { return node }
                    guard !preservesSel && !preservesFocus && !onLink && !inEditSubtree else { return nil }
                    var pIdx = node.parentIndex
                    while let i = pIdx, i < flatNodes.count {
                        let cand = flatNodes[i]
                        if cand.effectiveInert { return nil }
                        if nodeTakesFocus(cand.el) { return cand }
                        if cand.el.isModal { return nil }
                        pIdx = cand.parentIndex
                    }
                    return nil
                }()
                if !preservesSel && !onLink, let target = focusableTarget {
                    if focusedPath != target.path {
                        let prevNode = focusedPath.flatMap { nodeByPath[$0] }.map { flatNodes[$0] }
                        handleKitFocusTransition(prevNode: prevNode, newPath: target.path, at: now)
                        finishPreeditIfNeeded(forPath: focusedPath, at: now)
                        imeReset = true
                        downFocusChanged = true
                    }
                    assignFocusPath(target.path, keyboard: false)
                    focusedKey = target.key
                    inputMachines.focusMachine.highlightedPath = nil
                    inputMachines.focusMachine.hoveredHighlight = false
                    focusKeyboard = false
                    blurredFocusPath = nil
                    focusHandoff = false
                    webFocusTabStartPath = nil
                } else if !onLink && !inEditSubtree && !preservesFocus && !isTextBox {
                    if let prevFp = focusedPath {
                        let prevNode = nodeByPath[prevFp].map { flatNodes[$0] }
                        handleKitFocusTransition(prevNode: prevNode, newPath: nil, at: now)
                        finishPreeditIfNeeded(forPath: prevFp, at: now)
                        focusedPath = nil
                        focusedKey = nil
                        inputMachines.focusMachine.highlightedPath = nil
                        inputMachines.focusMachine.hoveredHighlight = false
                        focusKeyboard = false
                        blurredFocusPath = prevFp
                        focusHandoff = false
                        imeReset = true
                        downFocusChanged = true
                    }
                }
            }
        }

        let sc = presentedScales[node.path] ?? Vec2(1, 1)
        let safeSc = Vec2(abs(sc.x) > 1e-6 ? sc.x : 1.0, abs(sc.y) > 1e-6 ? sc.y : 1.0)
        let local = Vec2(rawLocal.x / safeSc.x, rawLocal.y / safeSc.y)
        let elemSize = Vec2(node.targetRect.width, node.targetRect.height)
        let press = PointerPress(
            window: pos,
            local: local,
            elementSize: elemSize,
            button: button,
            mods: mods,
            clicks: clickCount
        )

        var downRanHandler = false
        var downAllLiveOnly = true

        if optedButton, let onDown = node.el.handlers.onPointerDown {
            var tx = makeTx(at: now, button: button, mods: mods == .none ? nil : mods)
            onDown(&state, press, &tx)
            downRanHandler = true
            downAllLiveOnly = downAllLiveOnly && tx.liveOnlyRequested
            applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
        }

        // TextInput caret placement / double-click word selection / drag selection
        if optedButton, let editLens = node.el.handlers.editLens {
            let snapshot = state
            var edit = editLens.get(state)
            let stateRevealed = edit.isRevealed
            if node.el.isSecure {
                edit.isSecure = true
                if let revealed = node.el.revealedOverride { edit.isRevealed = revealed }
            }
            let textSelOrigin: (Int, Int)?
            if edit.isHiddenMultiline {
                textSelOrigin = nil
                if clickCount >= 3 {
                    edit.selectAll()
                } else {
                    edit.setCursor(utf8Offset: edit.text.utf8.count, extendSelection: false)
                }
            } else {
                let isSecure = edit.isSecure || node.el.isSecure
                let hit = textCaretHit(node: node, windowPos: pos, edit: edit)
                let offset = hit.utf8Offset
                if clickCount >= 3 {
                    if isSecure {
                        edit.selectAll()
                        textSelOrigin = nil
                    } else if edit.multiline {
                        let origin = edit.hardLineParagraphRange(atUTF8Offset: offset)
                        edit.selectHardLine(atUTF8Offset: offset)
                        textSelOrigin = origin
                    } else {
                        edit.selectAll()
                        textSelOrigin = nil
                    }
                } else if clickCount == 2 {
                    if isSecure {
                        edit.selectAll()
                        textSelOrigin = nil
                    } else {
                        let origin = edit.wordUnitRange(atUTF8Offset: offset)
                        edit.selectWord(atUTF8Offset: offset)
                        textSelOrigin = origin
                    }
                } else {
                    edit.setCursor(hit, extendSelection: mods.shift || inputMachines.currentMods.shift)
                    textSelOrigin = nil
                }
            }
            edit.isRevealed = stateRevealed
            editLens.set(&state, edit)
            activeDrag = DragSession(
                path: node.path,
                key: node.key,
                startWindow: pos,
                lastWindow: pos,
                startLocal: local,
                startElementOrigin: Vec2(rect.x, rect.y),
                startScale: safeSc,
                elementSize: elemSize,
                clicks: clickCount,
                button: button,
                mods: mods,
                isTextSelectionDrag: true,
                textSelectionOrigin: textSelOrigin,
                stateSnapshotBeforeDrag: snapshot
            )
            dirtyCommit(at: now, why: CommitWhy.input, inputChange: false)
            return
        }

        let hasDragOut = optedButton && inputMachines.osDragSupported && (node.el.handlers.dragOut != nil || node.el.attachedDragOutItem != nil)
        if button == .primary && hasDragOut {
            let threshold = node.el.handlers.dragThreshold ?? DragItem.defaultThreshold
            armedDragOut = (path: node.path, key: node.key, startWindow: pos, bounds: rect, threshold: threshold)
        } else {
            armedDragOut = nil
        }

        if optedButton && node.el.handlers.onDrag != nil && !hasDragOut {
            let snapshot = state
            activeDrag = DragSession(
                path: node.path,
                key: node.key,
                startWindow: pos,
                lastWindow: pos,
                startLocal: local,
                startElementOrigin: Vec2(rect.x, rect.y),
                startScale: safeSc,
                elementSize: elemSize,
                clicks: clickCount,
                button: button,
                mods: mods,
                isTextSelectionDrag: false,
                stateSnapshotBeforeDrag: snapshot
            )
            // Deliver initial drag at delta 0 so sliders jump/latch under pointer immediately!
            var tx = makeTx(at: now, button: button)
            node.el.handlers.onDrag?(
                &state,
                Drag(
                    window: pos,
                    local: local,
                    delta: .zero,
                    startLocal: local,
                    size: elemSize,
                    clicks: clickCount,
                    mods: mods,
                    phase: .down,
                    screen: screenPixels(at: pos)
                ),
                &tx
            )
            downRanHandler = true
            downAllLiveOnly = downAllLiveOnly && tx.liveOnlyRequested
            applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
            armKitDragRepeatIfRequested(path: node.path, now: now)
        }

        if mouse && button == .primary && node.el.handlers.pressOnDown,
           let liveOnly = dispatchPointerClick(node, press: press, at: now) {
            activatedOnPointerDown = true
            downRanHandler = true
            downAllLiveOnly = downAllLiveOnly && liveOnly
        }

        // Passive selectable text holds the pointer to preserve its hover ancestors during a
        // drag. Selection painting and any subscribed views are invalidated by the selection runtime.
        let passiveSelection = button == .primary && node.el.isSelectable && !primaryPressHitPredicate(node)
        if downFocusChanged || nodeHasPressVisuals(node) || !downAllLiveOnly || (!downRanHandler && !passiveSelection) {
            dirtyCommit(at: now, why: CommitWhy.input, inputChange: false)
        }
    }

    public func pointerUp(at pos: Vec2, button: PointerButton = .primary, mods: Mods = .none, at now: Double) {
        let inputMark = noteInput(at: now)
        // The release queued a press (`Action::Press`), an input action whatever it changes.
        var releaseQueuedPress = false
        defer { endInputDispatch(inputMark, queuedAction: releaseQueuedPress) }
        let pointerMovedAtUp = (pos != pointerPosition)
        let prevMods = slice2State.currentMods
        let prevTime = slice2State.currentInputTime
        slice2State.currentMods = mods
        slice2State.currentInputTime = now
        defer {
            slice2State.currentMods = prevMods
            slice2State.currentInputTime = prevTime
        }
        pointerPosition = pos
        let releasedTintPath = (pressedTint?.button == button) ? pressedTint?.path : nil
        if pressedTint?.button == button {
            pressedTint = nil
        }
        let hadTintPressVisual = releasedTintPath.flatMap { nodeByPath[$0] }.map { nodeHasPressVisuals(flatNodes[$0]) } ?? false
        if button == .secondary {
            secondaryPointerHeld = false
            recordSecondaryTitlebarUp(at: pos)
        } else if pressedPath == nil || button == pressedButton {
            primaryPointerHeld = false
            armedDragOut = nil
            endKitPressRepeat()
        }
        if slice2State.autoscroll.release(button) { return }
        #if os(Linux)
        if button == .primary { clipboardRouting.primary.pending = true }
        #endif
        if pressedPath != nil && button != pressedButton {
            syncPressScale(at: cxSettings.scaledTime(at: now), cut: false)
            if hadTintPressVisual {
                dirtyCommit(at: now, why: CommitWhy.input, inputChange: false)
            }
            return
        }
        let releasedPath = pressedPath
        let alreadyActivated = releasedPath != nil && activatedOnPointerDown
        let touchTap = releasedPath != nil && pressedByTouch
        activatedOnPointerDown = false
        pressedByTouch = false
        let notePath = releasedPath
        let startedNs = InteractionGate.isOn ? RuneExecutionContext.uptimeNanoseconds : 0
        let wasPressedInside = pressedPointerInside
        pressedPath = nil
        pressedKey = nil
        pressedButton = .primary
        pressedPointerInside = false
        if let within = computeHoverWithin() {
            applyHoverWithin(within.inside, held: false, at: now)
        }
        syncPressScale(at: cxSettings.scaledTime(at: now), cut: false)
        var pairInfo = inputMachines.currentDoubleClickPair
        inputMachines.currentDoubleClickPair = nil
        if pointerMovedAtUp, var p = pairInfo {
            if !PressRun.withinSlop(p.downPoint, pos) {
                p.moved = true
            }
            pairInfo = p
        }
        let suppressedClickFromSelDrag = (button == .primary) ? handleSelectablePointerUp(at: pos, button: button, at: now) : false
        let hadPressVisual = hadTintPressVisual || (releasedPath.flatMap { nodeByPath[$0] }.map { nodeHasPressVisuals(flatNodes[$0]) } ?? false)
        var upRanHandler = alreadyActivated
        var upAllLiveOnly = true
        if cxSettings.selectionRectsReadByView {
            dirtyCommit(at: now, why: CommitWhy.input, inputChange: false)
        }

        defer {
            if inputMachines.pressedLeft {
                leaveAfterRelease(at: now)
            } else if pointerPosition.x > -9000 && pointerPosition.y > -9000 {
                _ = refreshHover(at: now, isPointerEvent: true, updateHoverHighlight: false)
            }
        }
        var draggedPastThreshold = suppressedClickFromSelDrag
        var hadActiveDrag = false
        if let drag = activeDrag {
            hadActiveDrag = !drag.isTextSelectionDrag
            activeDrag = nil
            draggedPastThreshold = suppressedClickFromSelDrag || (!drag.isTextSelectionDrag &&
                (drag.movedBeyondSlop || !PressRun.withinSlop(drag.startWindow, pos)))
            if drag.button == .primary && draggedPastThreshold {
                clickCount = 0
                lastClickTime = -.infinity
            }
            if !drag.isTextSelectionDrag, let idx = nodeByPath[drag.path] {
                let node = flatNodes[idx]
                let sx = abs(drag.startScale.x) > 1e-6 ? drag.startScale.x : 1.0
                let sy = abs(drag.startScale.y) > 1e-6 ? drag.startScale.y : 1.0
                let local = Vec2((pos.x - drag.startElementOrigin.x) / sx, (pos.y - drag.startElementOrigin.y) / sy)
                let delta = Vec2(pos.x - drag.startWindow.x, pos.y - drag.startWindow.y)
                if let onDrag = node.el.handlers.onDrag {
                    if pointerMovedAtUp {
                        let moveDrag = Drag(
                            window: pos,
                            local: local,
                            delta: delta,
                            startLocal: drag.startLocal,
                            size: drag.elementSize,
                            clicks: drag.clicks,
                            mods: mods,
                            phase: .move,
                            screen: screenPixels(at: pos)
                        )
                        var tx = makeTx(at: now, button: drag.button)
                        onDrag(&state, moveDrag, &tx)
                        if !tx.askedMotion { tx.instant() }
                        upRanHandler = true
                        upAllLiveOnly = upAllLiveOnly && tx.liveOnlyRequested
                        applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
                    }
                    if node.el.handlers.onDragEnd == nil {
                        let upDrag = Drag(
                            window: pos,
                            local: local,
                            delta: delta,
                            startLocal: drag.startLocal,
                            size: drag.elementSize,
                            clicks: drag.clicks,
                            mods: mods,
                            phase: .up,
                            screen: screenPixels(at: pos)
                        )
                        var tx = makeTx(at: now, button: drag.button)
                        onDrag(&state, upDrag, &tx)
                        upRanHandler = true
                        upAllLiveOnly = upAllLiveOnly && tx.liveOnlyRequested
                        applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
                    }
                }
                if let onEnd = node.el.handlers.onDragEnd {
                    var tx = makeTx(at: now, button: drag.button)
                    onEnd(&state, false, &tx)
                    upRanHandler = true
                    upAllLiveOnly = upAllLiveOnly && tx.liveOnlyRequested
                    applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
                }
            }
        }

        if dispatchLinkUp(at: pos, button: button, mods: mods, suppressed: suppressedClickFromSelDrag, at: now) {
            dirtyCommit(at: now, why: CommitWhy.input, inputChange: false)
            return
        }

        guard let rPath = releasedPath, let idx = nodeByPath[rPath] else {
            if suppressedClickFromSelDrag || hadPressVisual || !upRanHandler || !upAllLiveOnly {
                dirtyCommit(at: now, why: CommitWhy.input, inputChange: false)
            }
            return
        }
        let node = flatNodes[idx]
        let rect = presentedRectByPath[rPath] ?? node.targetRect
        let insideNow: Bool
        if node.el.pressScaleFactor != nil {
            insideNow = pressRestingContains(path: rPath, at: pos)
        } else {
            insideNow = hitGeometryByPath[rPath]?.contains(pos) ?? halfOpenContains(rect, pos)
        }
        let inside = pointerMovedAtUp ? insideNow : (wasPressedInside && inputMachines.pressedStillInside)
        let movedOutsideSlop = (pairInfo?.moved ?? false) || (inputMachines.pressedWindowPoint.map { !PressRun.withinSlop($0, pos) } ?? false)
        if movedOutsideSlop || (draggedPastThreshold && hadActiveDrag) {
            inputMachines.pressClicks.clear()
        }
        if button == .primary,
           let p = pairInfo,
           !p.isSecond,
           inside,
           !movedOutsideSlop,
           (now - p.downAt) <= doubleClickInterval,
           node.el.handlers.onDoubleClick != nil {
            inputMachines.firstDoubleClick = FirstDoubleClick(path: rPath, at: p.downAt, point: p.downPoint)
        }
        let unturnedLocal = hitGeometryByPath[rPath]?.turn?.unturn(pos) ?? pos
        let press = PointerPress(
            window: pos,
            local: Vec2(unturnedLocal.x - rect.x, unturnedLocal.y - rect.y),
            elementSize: Vec2(rect.width, rect.height),
            button: button,
            mods: mods,
            clicks: button == .primary ? clickCount : 1
        )

        let effMods: Mods? = (mods == .none) ? nil : mods
        let allowsButton = button == .primary || (button != .secondary && (node.el.handlers.pointerButtons?.contains(button) ?? false))

        if allowsButton, let onUp = node.el.handlers.onPointerUp {
            var tx = makeTx(at: now, button: button, mods: effMods)
            onUp(&state, press, &tx)
            upRanHandler = true
            upAllLiveOnly = upAllLiveOnly && tx.liveOnlyRequested
            applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
        }

        // Fire click / double-click only if pointer released inside the pressed element (or didn't move when element moved out from under it) and not dragged!
        if inside && allowsButton && !suppressedClickFromSelDrag {
            if !alreadyActivated, let liveOnly = dispatchPointerClick(node, press: press, at: now, touchTap: touchTap) {
                releaseQueuedPress = true
                upRanHandler = true
                upAllLiveOnly = upAllLiveOnly && liveOnly
            }
            let clickInTime = pairInfo.map { (now - $0.downAt) <= doubleClickInterval } ?? true
            if button == .primary && (pairInfo?.isSecond == true) && !movedOutsideSlop && clickInTime,
               let onDbl = node.el.handlers.onDoubleClick {
                logInputEvent("double press \(rPath)")
                var tx = makeTx(at: now, button: button, mods: effMods)
                onDbl(&state, &tx)
                upRanHandler = true
                upAllLiveOnly = upAllLiveOnly && tx.liveOnlyRequested
                applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
            }
            if InteractionGate.isOn {
                let action = (button == .primary && (pairInfo?.isSecond == true) && !movedOutsideSlop && clickInTime && node.el.handlers.onDoubleClick != nil)
                    ? "on_double_press"
                    : "on_press"
                if let note = interactionNote(action: action, rank: 3, path: notePath) {
                    let endedNs = RuneExecutionContext.uptimeNanoseconds
                    let handlerMs = Double(endedNs >= startedNs ? endedNs - startedNs : 0) / 1_000_000.0
                    perfWatch.interaction.noted(note: note, arrivedNs: startedNs, startedNs: startedNs, handlerMs: handlerMs)
                }
            }
        } else if inside && button == .middle && !allowsButton && !suppressedClickFromSelDrag,
                  let onMiddle = node.el.handlers.onMiddlePress {
            logEvent("middle press \(node.path)")
            var tx = makeTx(at: now, button: .middle, mods: effMods)
            onMiddle(&state, &tx)
            upRanHandler = true
            upAllLiveOnly = upAllLiveOnly && tx.liveOnlyRequested
            applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
            if InteractionGate.isOn {
                if let note = interactionNote(action: "on_middle_press", rank: 3, path: notePath) {
                    let endedNs = RuneExecutionContext.uptimeNanoseconds
                    let handlerMs = Double(endedNs >= startedNs ? endedNs - startedNs : 0) / 1_000_000.0
                    perfWatch.interaction.noted(note: note, arrivedNs: startedNs, startedNs: startedNs, handlerMs: handlerMs)
                }
            }
        }

        let passiveSelection = button == .primary && node.el.isSelectable && !primaryPressHitPredicate(node)
        if hadPressVisual || !upAllLiveOnly || ((suppressedClickFromSelDrag || !upRanHandler) && !passiveSelection) {
            dirtyCommit(at: now, why: CommitWhy.input, inputChange: false)
        }
    }

    /// Routes wheel / trackpad scroll deltas through `WheelLock` to `onWheel` or scrollable ancestors (`gesture.rs`, `scroll/x.rs`).
    public func wheel(_ event: WheelEvent, at pos: Vec2? = nil, now: Double) {
        let inputMark = beginInputDispatch(at: now)
        defer { endInputDispatch(inputMark, queuedAction: true) }
        dispatchLockedWheel(event, at: pos, now: now)
    }

    /// Starts an inertial scroll `Decay` fling (`vx`, `vy` in points/sec) on the scroll container under `pos`.
    public func fling(vx: Float = 0, vy: Float, at pos: Vec2? = nil, now: Double) {
        releaseHoverHold()
        dismissHelp(at: now)
        let targetPos = pos ?? pointerPosition
        // `fling_xy` / `fling`: the target comes from `scroll_at_axis` / `scroll_at`, skipping a
        // viewport with nothing to scroll on that axis (#1021).
        guard let (path, horizontal) = flingTarget(at: targetPos, vx: vx, vy: vy),
              let scrollIdx = nodeByPath[path] else {
            return
        }
        if !horizontal && vy != 0 {
            logEvent(String(format: "fling %.0f", vy))
        }
        if horizontal && vx != 0 {
            logEvent(String(format: "fling-x %.0f", vx))
        }
        let nid = NodeId.hash("scroll:" + path)
        let cur = scrollOffsets[path] ?? .zero
        scrollGlidingPaths.remove(path)
        markScrollMovedByHand(path: path)
        if scrollRequiresCommit {
            directScrolledPaths.insert(path)
        } else {
            directScrolledPaths.remove(path)
        }
        scrollRequestsState.stepCancel()
        scrollStore.snap(nid, Props.SCROLL, to: cur)
        cancelPressedOnScrollIfNeeded(scrollNodeIndex: scrollIdx, at: now)
        // Upstream `pointer.rs` `fling` & `scroll/x.rs` `fling_xy`: positive velocity moves content down/right
        // (reduces scroll offset), on the one axis picked; `st.x.toward` mirrors it right to left.
        let velocity: Vec2
        if horizontal {
            let signVx = flatNodes[scrollIdx].flow == .rtl ? -vx : vx
            velocity = Vec2(-signVx, 0)
        } else {
            velocity = Vec2(0, -vy)
        }
        _ = scrollStore.fling(nid, Props.SCROLL, from: cur, velocity: Velocity(velocity), decay: .IOS_NORMAL, at: cxSettings.scaledTime(at: now))
    }

    /// Routes keyboard `KeyEvent` through active drag cancel (`Escape`), focused `TextEdit`,
    /// ancestor `onKey` handlers, `Tab` / arrow focus traversal, and app-level `globalOnKey`.
    private static func modifierKey(for code: PhysicalKeyCode) -> ModifierKey? {
        switch code {
        case .shiftLeft: return .shiftLeft
        case .shiftRight: return .shiftRight
        case .controlLeft: return .controlLeft
        case .controlRight: return .controlRight
        case .altLeft: return .altLeft
        case .altRight: return .altRight
        case .superLeft: return .superLeft
        case .superRight: return .superRight
        case .fn: return .fn
        default: return nil
        }
    }

    /// `Runtime::physical_with_fallback` convenience alias.
    @discardableResult
    public func physicalWithFallback(_ event: PhysicalInput, fallback: KeyEvent? = nil, at now: Double) -> Bool {
        physicalInput(event, fallbackKey: fallback, at: now)
    }

    @discardableResult
    public func physicalInput(_ event: PhysicalInput, fallbackKey: KeyEvent? = nil, baseChar: Character? = nil, at now: Double) -> Bool {
        dispatchPendingPaintHover(at: now)
        let prevCode = currentPhysicalKey
        let prevBase = currentKeyBase
        let prevRepeat = currentKeyRepeat
        defer {
            currentPhysicalKey = prevCode
            currentKeyBase = prevBase
            currentKeyRepeat = prevRepeat
        }
        if case .key(let code, _, _, let isRepeat) = event {
            currentPhysicalKey = code
            currentKeyBase = baseChar
            currentKeyRepeat = isRepeat
        }
        return physicalWithFallback(event, fallbackKey: fallbackKey, at: now)
    }

    internal func dispatchPhysicalInputOnly(_ event: PhysicalInput, at now: Double, why: UInt16) -> Bool {
        let prevPhys = slice2State.currentPhysicalKey
        let prevRep = slice2State.currentKeyRepeat
        let prevMods = slice2State.currentMods
        let prevSliceBase = slice2State.currentKeyBase
        let prevTime = slice2State.currentInputTime
        slice2State.currentInputTime = now
        if case .key(let physCode, let mods, let pressed, let isRepeat) = event {
            slice2State.currentPhysicalKey = physCode
            slice2State.currentKeyRepeat = isRepeat
            slice2State.currentMods = mods
            if pressed {
                let base: Character? = currentKeyBase ?? slice2DefaultKeyBase(for: physCode)
                slice2State.lastPressedPhysicalKey = physCode
                slice2State.lastPressedKeyBase = base
                slice2State.currentKeyBase = base
            } else {
                slice2State.lastPressedPhysicalKey = nil
                slice2State.lastPressedKeyBase = nil
                slice2State.currentKeyBase = currentKeyBase
            }
        } else if case .focusLost = event {
            slice2State.lastPressedPhysicalKey = nil
            slice2State.lastPressedKeyBase = nil
        }
        defer {
            slice2State.currentPhysicalKey = prevPhys
            slice2State.currentKeyRepeat = prevRep
            slice2State.currentMods = prevMods
            slice2State.currentKeyBase = prevSliceBase
            slice2State.currentInputTime = prevTime
        }
        if case .focusLost = event {
            dirChord = .idle
        }
        let prevByKeys = activeByKeys
        if case .key(_, _, let pressed, _) = event {
            activeByKeys = pressed
        }
        defer {
            activeByKeys = prevByKeys
        }
        if case .key(let code, _, true, _) = event, code == .escape, cancelActiveDrag(at: nil, time: now) {
            return true
        }

        // Dispatch along focused -> ancestor chain (stopping at inert / modal boundary)
        if let fPath = focusedPath, let fIdx = nodeByPath[fPath] {
            var walkIdx: Int? = fIdx
            while let curIdx = walkIdx {
                if flatNodes[curIdx].effectiveInert { break }
                if let onPhys = flatNodes[curIdx].el.handlers.onPhysicalInput {
                    let physCode: PhysicalKeyCode? = {
                        if case .key(let c, _, _, _) = event { return c }
                        return nil
                    }()
                    let physRepeat: Bool = {
                        if case .key(_, _, _, let r) = event { return r }
                        return false
                    }()
                    var tx = makeTx(at: now, physicalKey: physCode, isRepeat: physRepeat)
                    let taken = onPhys(&state, event, &tx)
                    _ = Tx.took(taken, &tx)
                    if taken {
                        applyTx(tx, at: now, markDirtyIfNotLiveOnly: true, liveOnlyLabel: "onPhysicalInput", why: why)
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
                    var tx = makeTx(at: now)
                    let taken = onPhys(&state, event, &tx)
                    _ = Tx.took(taken, &tx)
                    if taken {
                        applyTx(tx, at: now, markDirtyIfNotLiveOnly: true, liveOnlyLabel: "onPhysicalInput", why: why)
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Synthesizes key-up modifier events for all currently held modifier keys (`overlay::hide` / blur).
    public func releaseHeldModifiers(at now: Double = 0.0) {
        let modEvents = inputMachines.modifierKeys.apply(.focusLost, consumed: false)
        for ev in modEvents {
            _ = routeModifierKey(ev, at: now)
        }
        guard !heldModifierKeys.isEmpty else { return }
        let held = heldModifierKeys
        heldModifierKeys.removeAll(keepingCapacity: true)
        for modKey in held {
            let kev = KeyEvent(key: .modifier(modKey, pressed: false), mods: .none)
            _ = keyDown(kev, isRepeat: false, at: now)
        }
    }

    @discardableResult
    public func keyDown(_ ev: KeyEvent, isRepeat: Bool = false, at now: Double) -> Bool {
        dispatchPendingPaintHover(at: now)
        if slice2State.autoscroll.key() { return true }
        // The user's own key takes over from a `Tx.focusWhenShown` still waiting; a playground
        // step's press for the stage (`Action::Key { stage: true }`) doesn't. As upstream
        // (frame.rs:565), before this key's commit boundary resolves an ask not yet committed.
        if playgroundLive?.pressing != true { dropOwedFocus() }
        currentTime = now
        let inputMark = noteInput(at: now, routed: true)
        defer { endInputDispatch(inputMark, queuedAction: true) }
        flushPendingCommitIfNeeded(at: now)
        return routeKeyDown(ev, isRepeat: isRepeat, at: now)
    }

    /// The logical key route is shared by a standalone key action and a physical action's fallback.
    internal func routeKeyDown(_ ev: KeyEvent, isRepeat: Bool = false, at now: Double) -> Bool {
        // A caret key or a shortcut reads the field's layout where it lands: a long paste's
        // paragraphs still waiting there are shaped first. Typing at the caret needs none.
        if !textRows.isEmpty && Self.readsTextLayout(ev) { fillTextNear() }
        recordEvent(hasSecureFocus ? "key-down [redacted]" : "key-down \(ev.key)")
        let prevKitByKeys = kitHooks.isDispatchingByKeys
        let prevByKeys = activeByKeys
        let prevRepeat = currentKeyRepeat
        kitHooks.isDispatchingByKeys = true
        activeByKeys = true
        currentKeyRepeat = isRepeat
        let prevKitKeyRepeat = kitHooks.isKeyRepeat
        kitHooks.isKeyRepeat = isRepeat
        let prevSliceRepeat = slice2State.currentKeyRepeat
        let prevMods = slice2State.currentMods
        let prevTime = slice2State.currentInputTime
        let prevSliceByKeys = slice2State.currentByKeys
        let prevPhys = slice2State.currentPhysicalKey
        let prevBase = slice2State.currentKeyBase
        slice2State.currentKeyRepeat = isRepeat
        slice2State.currentMods = ev.mods
        slice2State.currentInputTime = now
        slice2State.currentByKeys = true
        let fromActivePhysical = (currentPhysicalKey != nil)
        slice2State.currentPhysicalKey = fromActivePhysical ? currentPhysicalKey : slice2State.lastPressedPhysicalKey
        slice2State.currentKeyBase = fromActivePhysical ? currentKeyBase : slice2State.lastPressedKeyBase
        defer {
            kitHooks.isDispatchingByKeys = prevKitByKeys
            activeByKeys = prevByKeys
            currentKeyRepeat = prevRepeat
            kitHooks.isKeyRepeat = prevKitKeyRepeat
            slice2State.currentKeyRepeat = prevSliceRepeat
            slice2State.currentMods = prevMods
            slice2State.currentInputTime = prevTime
            slice2State.currentByKeys = prevSliceByKeys
            slice2State.currentPhysicalKey = prevPhys
            slice2State.currentKeyBase = prevBase
        }
        suppressSelectionEffectsFromHoverCommit = false
        let isFocusedSecure = focusedPath.flatMap { nodeByPath[$0] }.map { flatNodes[$0].el.isSecure && !flatNodes[$0].el.isRevealed } ?? false
        if isFocusedSecure {
            logEvent("key [redacted]")
        } else {
            logEvent("key \(ev.key)")
        }
        inputMachines.focusMachine.lastPressedWasPointer = false
        if isRepeat {
            if inputMachines.focusMachine.suppressedRepeatKey == ev.key {
                return true
            }
        } else {
            inputMachines.focusMachine.suppressedRepeatKey = nil
        }
        let physKey = inputMachines.activePhysicalKey
        dismissHelp(at: now)
        // 1. Escape cancels an in-progress drag (`DragPhase.up`, `isCancelled = true`)
        if ev.key == .escape, cancelActiveDrag(at: nil, time: now) {
            return true
        }
        if !isRepeat {
            pressedKeyFocusPath = focusedPath
        }
        let composingNow = isAnyImeComposing
        inputMachines.keyReleases.down(composing: composingNow, repeat: isRepeat) { focusedPath }
        if (ev.key == .enter || ev.key == .escape) && composingNow {
            inputMachines.keyReleases.imeTookKey()
            return true
        }

        if playgroundNav(ev, isRepeat: isRepeat, at: now) {
            return true
        }

        let appFirst = (focusedPath == nil)
        if appFirst && ev.key == .enter && ev.mods == .none, tryDefaultButtonReturn(at: now, isRepeat: isRepeat) {
            return true
        }
        if appFirst && activeModalPath == nil && playgroundLive == nil,
           let globalOnKey {
            var tx = makeTx(at: now, physicalKey: physKey, isRepeat: isRepeat)
            let taken = globalOnKey(&state, ev, &tx)
            let consumed = Tx.took(taken, &tx)
            applyTx(tx, at: now, markDirtyIfNotLiveOnly: consumed, liveOnlyLabel: "onKey")
            if consumed {
                return true
            }
        }

        // 2. Focused element & ancestor chain
        if let fPath = focusedPath,
           nodeByPath[fPath] == nil,
           let vInput = virtualInputs[fPath],
           applyFocusedTextEditKey(ev, el: vInput.el, layout: nil, at: now) {
            return true
        }
        if let fPath = focusedPath, let fIdx = nodeByPath[fPath] {
            let fNode = flatNodes[fIdx]

            // Upstream `keys.rs:238-246` & `on_key_tests.rs:81-90`: a focused text field keeps its keys;
            // ancestor `onKey` handlers must not preempt typing, navigation, or editing inside it.
            if fNode.el.handlers.editLens == nil {
                var walkIdx: Int? = fIdx
                while let curIdx = walkIdx {
                    if flatNodes[curIdx].effectiveInert { break }
                    if let onKey = flatNodes[curIdx].el.handlers.onKey {
                        var tx = makeTx(at: now, physicalKey: physKey, isRepeat: isRepeat)
                        if onKey(&state, ev, &tx) {
                            inputMachines.pressClicks.clear()
                            selectionState.clearClicks()
                            applyTx(tx, at: now, liveOnlyLabel: "onKey")
                            return true
                        }
                    }
                    if flatNodes[curIdx].el.isModal { break }
                    walkIdx = flatNodes[curIdx].parentIndex
                }
            }

            // Focused TextInput editing (`on_input_key` runs before `TextEdit.handleKey`)
            if let editLens = fNode.el.handlers.editLens {
                inputMachines.pressClicks.clear()
                selectionState.clearClicks()
                if let onInputKey = fNode.el.handlers.onInputKey {
                    var tx = makeTx(at: now, physicalKey: physKey, isRepeat: isRepeat)
                    let handled = onInputKey(&state, ev, &tx)
                    if Tx.took(handled, &tx) {
                        applyTx(tx, at: now, markDirtyIfNotLiveOnly: true)
                        return true
                    }
                    applyTx(tx, at: now, markDirtyIfNotLiveOnly: false)
                }
                if ev.mods == .none, (ev.key == .arrowDown || ev.key == .arrowUp || ev.key == .enter),
                   findSearchFollowsGroup(forFocusedIndex: fIdx) != nil,
                   handleMenuOrGroupNavigation(ev, focusedIndex: fIdx, isRepeat: isRepeat, at: now) {
                    return true
                }
                if ev.mods.primaryCommand, (ev.key == .command("v") || ev.key == .text("v") || ev.key == .text("V")) {
                    if pasteClipboardNow(at: now) {
                        return true
                    }
                }
                var edit = editLens.get(state)
                let stateRevealed = edit.isRevealed
                if fNode.el.isSecure {
                    edit.isSecure = true
                    if let rev = fNode.el.revealedOverride { edit.isRevealed = rev }
                }
                // Upstream `secure_text.rs:536,558`: copy/cut on secure text input stay blocked even when revealed.
                if edit.isSecure && ev.mods.primaryCommand &&
                    (ev.key == .command("c") || ev.key == .text("c") || ev.key == .text("C") ||
                     ev.key == .command("x") || ev.key == .text("x") || ev.key == .text("X")) {
                    return true
                }
                let isCopyOrCut = ev.mods.primaryCommand &&
                    (ev.key == .command("c") || ev.key == .text("c") || ev.key == .text("C") ||
                     ev.key == .command("x") || ev.key == .text("x") || ev.key == .text("X"))
                let preCopyHTML: String? = (isCopyOrCut && edit.isRichEnabled && !edit.isSecure && edit.hasSelection)
                    ? {
                        let html = edit.toHTML(range: edit.selectedUTF8Range)
                        return html.isEmpty ? nil : html
                    }()
                    : nil
                var editLayout: ShapedText? = nil
                let binding = ev.controlBinding
                let horizontal = ev.key == .arrowLeft || ev.key == .arrowRight ||
                    binding == "a" || binding == "e" || binding == "b" || binding == "f"
                let vertical = edit.multiline && (
                    ((ev.key == .arrowUp || ev.key == .arrowDown) && !ev.mods.isTextLineCommand) ||
                    binding == "p" || binding == "n"
                )
                let visualHomeEnd = edit.multiline && !KeyPlatform.current.isMac && !ev.mods.ctrl &&
                    (ev.key == .home || ev.key == .end)
                if (!edit.isSecure || edit.isRevealed) && (horizontal || vertical || visualHomeEnd) {
                    let pad = fNode.el.layout.padding
                    let innerW = max(0, fNode.targetRect.width - pad.left - pad.right)
                    let resolvedInput = ElDisplayResolver.resolveInput(el: fNode.el, edit: edit, innerWidth: innerW, pxScale: pixelScale)
                    if let request = Self.paragraphRequest(field: fNode.nodeId, el: fNode.el, edit: edit, resolved: resolvedInput) {
                        editLayout = textSystem.layoutInput(
                            text: resolvedInput.renderedString,
                            spans: resolvedInput.spans,
                            pills: resolvedInput.pills,
                            style: resolvedInput.style,
                            maxWidth: resolvedInput.maxWidthForShape,
                            pixelScale: pixelScale,
                            emitGlyphs: false,
                            request: request
                        ).shaped
                    } else {
                        editLayout = textSystem.shape(
                            text: resolvedInput.renderedString,
                            spans: resolvedInput.spans,
                            pills: resolvedInput.pills,
                            style: resolvedInput.style,
                            maxWidth: resolvedInput.maxWidthForShape,
                            pixelScale: pixelScale,
                            emitGlyphs: false,
                            bypassCache: edit.isSecure
                        )
                    }
                }
                let prevEdit = edit
                let outcome = edit.handleKey(ev, layout: editLayout, textSystem: textSystem, pixelScale: pixelScale)
                edit.isRevealed = stateRevealed
                switch outcome {
                case .ignored:
                    if edit.didRequestBlur && activeModalPath == nil {
                        if !isRepeat {
                            inputMachines.focusMachine.suppressedRepeatKey = ev.key
                            let prevFp = focusedPath
                            blurredFocusPath = prevFp
                            webFocusTabStartPath = prevFp
                            focusHandoff = true
                            focusedPath = nil
                            focusedKey = nil
                            syncedEditFocusedPaths.removeAll()
                            dirtyCommit(at: now, why: CommitWhy.input)
                        }
                        return true
                    }
                    break
                case .navigation:
                    editLens.set(&state, edit)
                    pendingCaretFollow = true
                    selectionState.pendingFollowCaret = true
                    dirtyCommit(at: now, why: CommitWhy.input)
                    return true
                case .modified:
                    selectionState.pendingFollowCaret = true
                    deliverInputEdit(el: fNode.el, previousEdit: prevEdit, newEdit: edit, editLens: editLens, at: now)
                    return true
                case .submit:
                    if isRepeat { return true }
                    editLens.set(&state, edit)
                    selectionState.pendingFollowCaret = true
                    if let onSubmit = fNode.el.handlers.onTextSubmit {
                        var tx = makeTx(at: now)
                        tx.animated()
                        onSubmit(&state, edit.text, &tx)
                        applyTx(tx, at: now)
                        dirtyCommit(at: now, why: CommitWhy.input)
                        return true
                    }
                    // Without `onTextSubmit`, let Return fall through to `.defaultButton()` if one exists.
                case .copy(let copied):
                    selectionState.pendingFollowCaret = true
                    recordCopy(ClipboardContent(copied, html: preCopyHTML))
                    if edit.text != prevEdit.text {
                        deliverInputEdit(el: fNode.el, previousEdit: prevEdit, newEdit: edit, editLens: editLens, at: now)
                    } else {
                        editLens.set(&state, edit)
                        if fNode.el.handlers.onTextChange != nil || fNode.el.handlers.onInputChange != nil {
                            var tx = makeTx(at: now)
                            _ = fNode.el.handlers.onInputChange?(&state, edit.text, &tx)
                            fNode.el.handlers.onTextChange?(&state, edit.text, &tx)
                            applyTx(tx, at: now)
                        }
                        dirtyCommit(at: now, why: CommitWhy.input)
                    }
                    return true
                }
            }

            if handleFocusedStepKey(ev, node: fNode, at: now) {
                return true
            }

            if handleMenuOrGroupNavigation(ev, focusedIndex: fIdx, isRepeat: isRepeat, at: now) {
                return true
            }

            // Space/Enter/ContextMenu activates focused text links first, then buttons/rows (`takesReturn`).
            let isSpaceKey = (ev.key == .space || ev.key == .text(" "))
            let pressesOnSpace = isSpaceKey && (fNode.el.handlers.hasPress || !isPageableScroller(fIdx))
            if ev.mods == .none && (pressesOnSpace || ev.key == .enter) && !isRepeat {
                if activateFocusedLink(at: now) {
                    return true
                }
            }
            if ((ev.mods == .none && ev.key == .contextMenu) || (ev.mods == Mods(shift: true) && ev.key == .f(10))) && !isRepeat {
                if activateFocusedLinkSecondary(at: now) {
                    return true
                }
                let r = presentedRectByPath[fNode.path] ?? fNode.targetRect
                let anchorPos = Vec2(r.x, r.y + r.height)
                if fNode.el.handlers.onSecondaryClick == nil && fNode.el.handlers.editLens != nil {
                    if openFieldMenu(node: fNode, at: anchorPos, fromPointer: false, at: now) {
                        return true
                    }
                }
                var curIdx: Int? = fIdx
                while let ci = curIdx, flatNodes.indices.contains(ci), !flatNodes[ci].effectiveInert {
                    if let onSecondary = flatNodes[ci].el.handlers.onSecondaryClick {
                        let cr = presentedRectByPath[flatNodes[ci].path] ?? flatNodes[ci].targetRect
                        let press = PointerPress(
                            window: anchorPos,
                            local: Vec2(anchorPos.x - cr.x, anchorPos.y - cr.y),
                            elementSize: Vec2(cr.width, cr.height),
                            button: .secondary,
                            mods: .none,
                            clicks: 1
                        )
                        var tx = makeTx(at: now, button: .secondary)
                        onSecondary(&state, press, &tx)
                        applyTx(tx, at: now)
                        return true
                    }
                    if flatNodes[ci].el.isModal { break }
                    curIdx = flatNodes[ci].parentIndex
                }
            }
            // Space activates non-input focused controls; Enter activates rows/links (`takesReturn`) or falls back when no `.defaultButton()` exists.
            let takesReturn = fNode.el.role == .listItem || fNode.el.role == .option ||
                fNode.el.role == .treeItem || fNode.el.role == .menuItem ||
                fNode.el.role == .link || fNode.el.role == .row ||
                fNode.el.role == .gridCell || fNode.el.focusHighlightColor != nil
            if fNode.el.handlers.editLens == nil && ev.mods == .none &&
               (pressesOnSpace || (ev.key == .enter && (takesReturn || defaultButtonNode() == nil))) {
                if isRepeat { return true }
                if invokeKeyboardPress(fNode, at: now) { return true }
            }
        } else if handleUnfocusedMenuNavigation(ev, isRepeat: isRepeat, at: now) {
            return true
        }

        // 2b. Unhandled Escape inside an active modal blurs focus and dismisses the innermost modal
        // (blocking key repeat so held Escape never cascades through stacked modals).
        if ev.key == .escape, let mPath = activeModalPath, let mIdx = nodeByPath[mPath] {
            if isRepeat {
                return true
            }
            inputMachines.focusMachine.suppressedRepeatKey = ev.key
            focusedPath = nil
            focusedKey = nil
            syncedEditFocusedPaths.removeAll()
            if let dismiss = flatNodes[mIdx].el.handlers.modalDismiss {
                var tx = makeTx(at: now)
                dismiss(&state, &tx)
                applyTx(tx, at: now)
            }
            dirtyCommit(at: now, why: CommitWhy.input)
            return true
        }

        // 2c. Non-editor `Cmd+V` falls through to active modal / root `onPaste` when unhandled by focused `onKey`.
        if ev.mods.primaryCommand, (ev.key == .command("v") || ev.key == .text("v") || ev.key == .text("V")) {
            if pasteClipboardNow(at: now) {
                return true
            }
        }

        // 3. Tab / Shift+Tab focus ring traversal (trapped inside `.modal()` automatically via `effectiveInert`!)
        if ev.key == .tab && !ev.mods.ctrl && !ev.mods.alt && !ev.mods.cmd {
            if advanceTabFocus(backward: ev.mods.shift) {
                hoveredHighlightActive = false
                focusVisible = true
                dirtyCommit(at: now, why: CommitWhy.input)
                return true
            }
            if activeModalPath != nil {
                return true
            }
        }

        // 3b. Default button activation on unmodified Return when no control consumed it
        if !appFirst && ev.key == .enter && ev.mods == .none,
           tryDefaultButtonReturn(at: now, isRepeat: isRepeat) {
            return true
        }

        if contextMenuKey(ev, at: now) {
            return true
        }

        if dispatchContextMenuKey(
            ev,
            at: now,
            drawnRectByPath: drawnRectByPath,
            presentedRectByPath: presentedRectByPath
        ) {
            return true
        }

        // 4. Root / global `onKey` handler (unhandled keys bubble to `globalOnKey`; ShortcutRegistry stays gated under modal)
        if activeModalPath == nil, let live = playgroundLive {
            if !live.typing(appState: state), let handled = playgroundAppKey(ev, at: now), handled {
                return true
            }
        } else if !appFirst && playgroundLive == nil, let globalOnKey {
            var tx = makeTx(at: now, physicalKey: physKey, isRepeat: isRepeat)
            let taken = globalOnKey(&state, ev, &tx)
            let consumed = Tx.took(taken, &tx)
            applyTx(tx, at: now, markDirtyIfNotLiveOnly: consumed, liveOnlyLabel: "onKey")
            if consumed {
                return true
            }
        }

        // 5. Shortcut registry dispatch (only when no active modal blocks global shortcuts)
        if activeModalPath == nil, let registry = shortcutRegistry {
            let result = registry.dispatch(ev)
            if result != .unhandled {
                dirtyCommit(at: now, why: CommitWhy.input)
                return true
            }
        }

        // 6. Selectable-text `Cmd+A` / `Cmd+C` fallback
        if handleSelectableKeyDown(ev, at: now) {
            return true
        }

        if pageScroll(ev, at: now) {
            return true
        }

        if playgroundKey(ev, at: now) {
            return true
        }

        return false
    }

    private func isPageableScroller(_ idx: Int) -> Bool {
        let node = flatNodes[idx]
        return node.el.layout.scrollAxes.contains(.vertical)
            && (scrollMaxExtents[node.path]?.y ?? 0) > 0.5
            && hoverAllowed(idx)
            && !subtreeExiting(idx)
    }

    /// Unclaimed arrows and Space scroll a focused scroller. Page keys can also target a
    /// focused descendant, the scroll view under the pointer, or another overflowing view.
    private func pageScroll(_ ev: KeyEvent, at now: Double) -> Bool {
        guard !ev.mods.cmd, !ev.mods.alt, !ev.mods.ctrl else { return false }
        let targetIdx: Int
        let focusedScrollerKey: Bool
        switch ev.key {
        case .arrowUp, .arrowDown, .space, .text(" "):
            guard !ev.mods.shift || ev.key == .space || ev.key == .text(" "),
                  let path = focusedPath, let idx = nodeByPath[path],
                  isPageableScroller(idx) else { return false }
            targetIdx = idx
            focusedScrollerKey = true
        case .pageUp, .pageDown, .home, .end:
            let staged = playgroundLive?.pressing == true
            func pageable(_ idx: Int) -> Bool {
                isPageableScroller(idx) && (!staged || isNodeUnder(idx, predicate: { Self.isPlaygroundStageKey($0) }))
            }
            func around(_ idx: Int) -> Int? {
                var cur: Int? = idx
                while let i = cur {
                    if pageable(i) { return i }
                    cur = flatNodes[i].parentIndex
                }
                return nil
            }

            // A virtualized field can keep focus after its own node has been unmounted.
            var focusedIdx: Int?
            var path = focusedPath
            while let candidate = path {
                if let idx = nodeByPath[candidate] { focusedIdx = idx; break }
                path = candidate.lastIndex(of: "/").map { String(candidate[..<$0]) }
            }
            let hoveredIdx = scrollAt(pointerPosition.x, pointerPosition.y).flatMap { nodeByPath[$0] }
            guard let idx = focusedIdx.flatMap(around) ?? hoveredIdx.flatMap(around)
                ?? flatNodes.indices.first(where: pageable) else { return false }
            targetIdx = idx
            focusedScrollerKey = false
        default:
            return false
        }

        let node = flatNodes[targetIdx]
        let path = node.path
        let maxY = scrollMaxExtents[path]?.y ?? 0
        let viewportH = scrollViewportSizes[path]?.y ?? node.targetRect.height
        let page = max(0.0, viewportH * 0.9)
        let cur = scrollOffsets[path] ?? .zero
        let targetY: Float
        switch ev.key {
        case .arrowUp: targetY = cur.y - 40
        case .arrowDown: targetY = cur.y + 40
        case .space, .text(" "): targetY = ev.mods.shift ? cur.y - page : cur.y + page
        case .pageUp: targetY = cur.y - page
        case .pageDown: targetY = cur.y + page
        case .home: targetY = 0
        default: targetY = maxY
        }
        releaseHoverHold()
        scrollRequestsState.stepCancel()
        let offset = targetY.clamped(to: 0...maxY)
        applyScrollOffsetRequest(path: path, x: nil, y: offset, glide: nil, cut: true,
                                 animNow: lastScaledAnimNow, holdHover: false)
        // keys.rs::page_to puts only the vertical lane at rest. A previous touch fling
        // must no longer advance it on the next frame. A horizontal glide keeps going.
        updateScrollMode(forPath: path, event: .moved)
        let pinned = node.el.layout.stickBottom && offset >= maxY - 0.5
        updateScrollMode(forPath: path, event: pinned ? .pin : .rest)
        if pinned { wasPinnedToBottom.insert(path) } else { wasPinnedToBottom.remove(path) }
        if case .coasting(node.nodeId, horizontal: false) = slice2State.touchScroll {
            slice2State.touchScroll = nil
        }
        slice2State.touchOverscrollY.removeValue(forKey: path)
        markScrollMovedByHand(path: path)
        directScrolledPaths.insert(path)
        pendingCommitKind = pendingCommitKind.instant()
        logInputEvent("\(focusedScrollerKey ? "scroll" : "page") \(ev.key)")
        dirtyCommit(at: now, why: CommitWhy.input)
        return true
    }

    public func paste(_ content: ClipboardContent, at now: Double) {
        let inputMark = beginInputDispatch(at: now, routed: true)
        defer { endInputDispatch(inputMark, queuedAction: true) }
        flushPendingCommitIfNeeded(at: now)
        deliverPaste(content, at: now)
    }

    // MARK: - JSON Element Tree Snapshot (`--tree`)

    public func treeJSON(realTime: Double? = nil) -> [String: Any] {
        func r2(_ v: Float) -> Double {
            (Double(v) * 100.0).rounded() / 100.0
        }

        let els: [[String: Any]] = elements().map { e in
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
            let target = e.committedLayoutTarget?.xywh ?? e.target
            if zip(e.rect, target).contains(where: { abs($0 - $1) > 0.01 }) {
                obj["target"] = target.map(r2)
            }
            if e.moving { obj["moving"] = true }
            if e.exiting { obj["exiting"] = true }
            if e.hover > 0.001 { obj["hover"] = r2(e.hover) }
            if e.press > 0.001 { obj["press"] = r2(e.press) }
            if abs(e.stuck) > 0.01 { obj["stuck"] = r2(e.stuck) }
            if let caret = e.caret { obj["caret"] = caret.map(r2) }
            if let er = e.editRange { obj["selection"] = er }
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
        if let area = imeArea, area.count == 4 {
            out["imeArea"] = area.map(r2)
        }
        if let (preText, preCursor) = focusedPreedit() {
            var preObj: [String: Any] = ["text": preText]
            if let preCursor { preObj["cursor"] = preCursor }
            out["preedit"] = preObj
        }
        if let tip = helpTooltip() {
            out["tooltip"] = [
                "text": tip.text,
                "rect": [r2(tip.rect.x), r2(tip.rect.y), r2(tip.rect.z), r2(tip.rect.w)],
            ]
        }
        out["accessibility"] = AccessibilityDump.dictionary(from: accessibilitySnapshot(), isRoot: true)
        return out
    }

    /// Active open preedit composition on the focused input element, if any (`Runtime::focused_preedit`).
    public func focusedPreedit() -> (text: String, cursor: [Int]?)? {
        guard let fp = focusedPath,
              let idx = nodeByPath[fp],
              !flatNodes[idx].effectiveInert,
              let editLens = flatNodes[idx].el.handlers.editLens else {
            return nil
        }
        let edit = editLens.get(state)
        guard !edit.isSecure, let pre = edit.preedit else { return nil }
        return (pre.text, pre.cursor.map { [$0.lowerBound, $0.upperBound] })
    }

    /// Perceived luminance of an opaque root background, matching `Runtime::backdrop_dark`.
    public func backdropDark() -> Bool? {
        guard !flatNodes.isEmpty else { return nil }
        let c = flatNodes[0].el.background
        guard c.a > 0.5 else { return nil }
        return (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) < 0.25
    }

    /// Attaches or detaches a `MotionTrace` on the underlying scene (`Runtime::scene_mut().set_trace`).
    public func setTrace(_ trace: MotionTrace?) {
        scene.setTrace(trace)
    }

    /// Detaches and returns the active `MotionTrace` from the underlying scene, if any.
    public func takeTrace() -> MotionTrace? {
        scene.takeTrace()
    }

    /// Audits retarget velocity continuity in the scene store (`Runtime::scene_mut().store_mut().audit_retargets(_:)`).
    public func auditRetargets(_ enabled: Bool) {
        scene.store.auditRetargets(enabled)
    }

    /// Consumes and resets accumulated retarget audit counters from the scene store (`take_retarget_audit`).
    public func takeRetargetAudit() -> RetargetAudit {
        scene.store.takeRetargetAudit()
    }

    /// Appends a trace marker directly when tracing is active (`Runtime::trace_event`).
    public func traceEvent(_ event: String) {
        if traceChannels != nil {
            traceEvents.append(event)
        }
        scene.traceEvent(event)
    }

    /// Records a scalar trace channel directly when tracing is active (`Runtime::trace_channel`).
    public func traceChannel(_ name: String, kind: TraceChannels.Kind, value: Float) {
        if traceChannels != nil {
            traceChannels?[name] = (kind, value)
        }
        scene.traceChannel(name, kind: kind, value: value)
    }

    /// Layout & visual goal snapshots per element path for trace retarget detection (`Runtime::trace_goals`).
    public func traceGoals() -> [(path: String, goal: [Float])] {
        flatNodes.map { node in
            (
                node.path,
                [
                    node.localRect.x,
                    node.localRect.y,
                    node.localRect.width,
                    node.localRect.height,
                    node.el.offset.x,
                    node.el.offset.y,
                    node.el.scale.x,
                ]
            )
        }
    }

    /// Tracks sampled in the last frame step (`Runtime::touched_tracks`).
    public func touchedTracks() -> [(path: String, prop: String, active: Bool)] {
        var seen = Set<String>()
        var out: [(path: String, prop: String, active: Bool)] = []
        let sceneTracks = scene.store.touchedTracks().map { (track, node, prop) in
            (path: mountedNode(node)?.path ?? "node:\(node.rawValue)", prop: PropTraceName.name(prop), active: scene.store.isActive(track))
        }
        for (path, propName, active) in sceneTracks + liveTouchedTracks() {
            let dedupKey = "\(path)\u{0}\(propName)\u{0}\(active ? 1 : 0)"
            if seen.insert(dedupKey).inserted {
                out.append((path, propName, active))
            }
        }
        for (nodeId, g) in growthRows where g.track.mask > 0.01 {
            guard let match = flatNodes.first(where: { $0.path == nodeId }) else { continue }
            let dedupKey = "\(match.path)\u{0}mask\u{0}1"
            if seen.insert(dedupKey).inserted {
                out.append((match.path, "mask", true))
            }
        }
        out.sort { ($0.path, $0.prop, $0.active ? 1 : 0) < ($1.path, $1.prop, $1.active ? 1 : 0) }
        return out
    }

    /// Leaf element paths with no painted content or interactivity (`Runtime::blank_leaves`).
    public func blankLeaves() -> Set<String> {
        var hasChild = Set<Int>()
        for n in flatNodes {
            if let p = n.parentIndex {
                hasChild.insert(p)
            }
        }
        var blanks = Set<String>()
        for (idx, n) in flatNodes.enumerated() where !hasChild.contains(idx) {
            let el = n.el
            let hasBorder = el.borderWidth > 0 && el.borderColor.a > 0
            let hasSurface = el.surfacePayload != nil || el.iconPayload != nil || el.imagePayload != nil
                || el.pixelsPayload != nil || el.gradient != nil || !el.shapes.isEmpty
            let isVisual = el.plainText != nil || el.handlers.editLens != nil || el.focusable
                || el.background.a > 0 || hasBorder || !el.shadows.isEmpty || hasSurface
            if !isVisual {
                blanks.insert(n.path)
            }
        }
        return blanks
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
        _ = receiveFileDrop(phase, at: now)
    }

    /// Returns the result of routing this phase to a native drop destination.
    internal func receiveFileDrop(_ phase: FileDropPhase, at now: Double) -> Bool {
        currentTime = now
        fileDropState.handle(phase)
        flightRecorder.record(kind: "fileDrop", at: now)
        let accepted = routeFileDropPhase(phase, at: now)
        if let handler = onFileDrop {
            var tx = makeTx(at: now)
            handler(&state, phase, &tx)
            applyTx(tx, at: now)
            if !tx.liveOnlyRequested {
                dirtyCommit(at: now, why: CommitWhy.input)
            }
            if case .exited = phase { return false }
            return true
        }
        return accepted
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
        rewind.recordFrame(at: now, viewport: viewport) { tape in
            let window = MotionRect.fromXYWH(0, 0, viewport.x, viewport.y)
            var exitIDs: [String: NodeId] = [:]
            for (id, snapshot) in exitingSnapshots { exitIDs[snapshot.path] = id }
            for info in lastElements {
                guard let name = info.traceName ?? info.key, let hit = hitGeometryByPath[info.path] else { continue }
                let r = info.rect
                let rect = MotionRect.fromXYWH(r[0], r[1], r[2], r[3])
                let clip = hit.parentScreenClip.map { intersectRects($0, window) } ?? window
                let node = nodeByPath[info.path].map { flatNodes[$0] }
                let effect = node?.el.runtimeExtra(RenderExtrasKey.effectSpec) as? RenderEffectSpec
                let margin = 2 / max(0.5, pixelScale) + info.blur * 3 + (effect?.bleed ?? 0) * info.scale
                guard clip.width > 0, clip.height > 0,
                      rect.right >= clip.left - margin, rect.left <= clip.right + margin,
                      rect.bottom >= clip.top - margin, rect.top <= clip.bottom + margin else { continue }
                let id = (info.exiting ? exitIDs[info.path] : nil) ?? node?.nodeId ?? NodeId.hash(info.path)
                tape.sample(nodeID: id.rawValue, name: name, q: RewindTape.quantize(rect: rect, opacity: info.opacity))
            }
        }
    }

    // MARK: - Private Helpers

    internal func runPickReads(_ tx: inout Tx) {
        while !tx.pickReads.isEmpty {
            let batch = tx.pickReads
            tx.pickReads.removeAll(keepingCapacity: true)
            for read in batch {
                let picked = elementAtWithin(read.within, x: read.x, y: read.y, pick: read.pick)
                var stateBox: Any = state
                if read.invoke(&stateBox, picked, &tx), let updated = stateBox as? State {
                    state = updated
                }
            }
        }
    }

    internal func applyTx(
        _ tx: Tx,
        at now: Double,
        markDirtyIfNotLiveOnly: Bool = true,
        external: Bool = true,
        liveOnlyLabel: String = "handler",
        why: UInt16 = CommitWhy.input,
        runPicks: Bool = true,
        countAsInput: Bool = true
    ) {
        claimPreparedText(from: tx)
        if countAsInput { inputHandlerRuns &+= 1 }
        var resolvedTx = tx
        if runPicks {
            runPickReads(&resolvedTx)
        }
        applyTxResolved(
            resolvedTx,
            at: now,
            markDirtyIfNotLiveOnly: markDirtyIfNotLiveOnly,
            external: external,
            liveOnlyLabel: liveOnlyLabel,
            why: why
        )
    }

    private func applyTxResolved(
        _ tx: Tx,
        at now: Double,
        markDirtyIfNotLiveOnly: Bool = true,
        external: Bool = true,
        liveOnlyLabel: String = "handler",
        why: UInt16 = CommitWhy.input
    ) {
        if let cb = tx.clipboardWrite {
            recordCopy(cb)
        }
        if let rich = tx.runtimeActions["richClipboardWrite"] as? RichClipboardPayload {
            recordCopy(rich.content, rich: rich)
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
            let clip = (pressedPath ?? hoveredPath).flatMap { dragOutParentClip(path: $0) }
            pendingDragOutStart = DragOutStart(item: drag, rect: Self.dragOutVisibleRect(bounds: bounds, clip: clip), bounds: bounds, press: pointerPosition, key: key)
        }
        if let actions = tx.runtimeActions["erasedActions"] as? [ErasedRuntimeAction] {
            for action in actions {
                switch action {
                case .popup(let req):
                    if let claimed = req.take() {
                        enqueuePopupRequest(claimed)
                        if !tx.liveOnlyRequested {
                            popupNeedsLayout = true
                        }
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
        var mutableTx = tx
        latchPlaygroundRequests(from: &mutableTx)
        if let title = tx.windowTitle {
            windowTitle = title
        }
        if let srgb = tx.srgbBlendRequest, srgb != srgbBlend {
            srgbBlend = srgb
            pendingColorMotionSpring = pendingColorMotionSpring ?? Spring.none
            dirtyCommit(at: now, why: why == 0 ? CommitWhy.dirty : why)
        }
        if let smoothing = tx.fontSmoothingRequest, smoothing != fontSmoothing {
            fontSmoothing = smoothing
            dirtyCommit(at: now, why: why == 0 ? CommitWhy.dirty : why)
        }
        if tx.isCloseWindowRequested {
            closeWindowRequested = true
        }
        if tx.isMinimizeRequested {
            _ = minimizeStep(.asked)
        }
        if tx.isRelaunchRequested {
            relaunchRequested = true
        }
        let wakeDelays = tx.wakeAfterSecondsList
        if !wakeDelays.isEmpty {
            if insideFramePollOrInput {
                for delay in wakeDelays {
                    pendingFrameWakes.append((scheduledAt: now, delay: delay))
                }
            } else {
                for delay in wakeDelays {
                    pendingUpdateWakes.append((scheduledAt: now, delay: delay))
                }
            }
        }
        if tx.quitRequested {
            quitRequested = true
        }
        for ev in tx.traceEvents {
            traceEvent(ev)
        }
        for (name, kind, value) in tx.traceChannels {
            traceChannel(name, kind: kind, value: value)
        }
        if (tx.runtimeActions["relaunchRequested"] as? Bool) == true {
            relaunchRequested = true
            quitRequested = true
        }
        if let dragRepeatDelay = tx.runtimeActions["dragRepeatAfter"] as? Double {
            kitHooks.requestedDragRepeatDelay = dragRepeatDelay
        }
        if let (sans, mono) = tx.runtimeActions["fontFamilies"] as? (String, String) {
            setFontFamilies(sans, mono)
        }
        var blurDroppedFocus = false
        if tx.blurFocusRequested {
            blurDroppedFocus = (focusedPath != nil || focusedKey != nil)
            if let prevFp = focusedPath {
                let prevNode = nodeByPath[prevFp].map { flatNodes[$0] }
                handleKitFocusTransition(prevNode: prevNode, newPath: nil, at: now, why: why == 0 ? CommitWhy.dirty : why)
                webFocusTabStartPath = prevFp
            }
            // `Tx::blur` = `Set { None }` + `Dropped` + `Settled`: Tab starts after it, nothing hands on,
            // and no blurred focus survives (cleared below via the shared focus-machine state).
            focusHandoff = false
            hoveredHighlightActive = false
            pendingTxBlurRequested = true
            pendingTxFocusKey = nil
            kitHooks.pendingTxFocusVisible = nil
            pendingTxFocusVisible = nil
            inputMachines.focusMachine.blurredFocusPath = nil
            focusedPath = nil
            focusedKey = nil
            syncedEditFocusedPaths.removeAll()
        } else if let fk = tx.requestedFocusKey, !tx.focusAskedWhenShown {
            pendingFocusWhenShown = nil
            hoveredHighlightActive = false
            let matchedNode = flatNodes.first(where: { matchesAuthoredKey($0.key, fk) })
            if let prevFp = focusedPath, matchedNode?.path != prevFp {
                let prevNode = nodeByPath[prevFp].map { flatNodes[$0] }
                handleKitFocusTransition(prevNode: prevNode, newPath: matchedNode?.path, at: now, why: why == 0 ? CommitWhy.dirty : why)
            }
            pendingTxBlurRequested = false
            pendingTxFocusKey = fk
            kitHooks.pendingTxFocusVisible = tx.requestedFocusVisible
            pendingTxFocusVisible = tx.focusAskedByReturn ? tx.requestedFocusVisible : nil
            focusVisible = tx.requestedFocusVisible
            focusKeyboard = tx.requestedFocusVisible
            blurredFocusPath = nil
            focusHandoff = false
            webFocusTabStartPath = nil
            focusedKey = fk
            if let match = matchedNode {
                assignFocusPath(match.path, keyboard: tx.requestedFocusVisible)
            }
        }
        if let fk = tx.requestedFocusKey, tx.focusAskedWhenShown {
            // `Tx.focusWhenShown`, latched apart from `Tx.blur` as upstream's `focus_to` is: the
            // next commit resolves it against the tree it builds (`sync_requested_focus`).
            pendingTxFocusKey = nil
            kitHooks.pendingTxFocusVisible = nil
            pendingTxFocusVisible = nil
            pendingFocusWhenShown = (fk, tx.requestedFocusVisible)
        }
        for prefix in tx.invalidateMemoPrefixes {
            MemoCache.shared.invalidateByPrefix(prefix)
        }
        if !tx.liveOnlyRequested {
            slice2State.pendingLiveTail.merge(tx.liveTail)
            pendingCommitKind = pendingCommitKind.merge(tx.commitKind)
            if tx.askedMotion {
                pendingAskedMotion = true
            }
            if tx.unprompted {
                pendingUnprompted = true
            }
            if let m = tx.motionSource {
                pendingCommitMotion = m
            }
            if let cm = tx.colorMotionSpring {
                pendingColorMotionSpring = cm
            }
            if tx.followEdgeRequested {
                pendingFollowEdge = true
            }
        }
        if !tx.scrollRevealRequests.isEmpty {
            pendingScrollReveals.append(contentsOf: tx.scrollRevealRequests)
        }
        if !tx.scrollBottomRequests.isEmpty {
            pendingScrollBottoms.append(contentsOf: tx.scrollBottomRequests)
        }
        if !tx.scrollPageRequests.isEmpty {
            pendingScrollPages.append(contentsOf: tx.scrollPageRequests)
        }
        if !tx.keepOnScreenKeys.isEmpty {
            pendingKeepOnScreenKeys.append(contentsOf: tx.keepOnScreenKeys)
        }
        let nonOffsetCommitRequests = (!tx.liveOnlyRequested && tx.followEdgeRequested)
            || tx.pasteRequested
            || !tx.clipboardReads.isEmpty
            || !tx.scrollRevealRequests.isEmpty
            || !tx.scrollBottomRequests.isEmpty
            || !tx.scrollPageRequests.isEmpty
            || !tx.keepOnScreenKeys.isEmpty
            || !tx.invalidateMemoPrefixes.isEmpty
            || (!tx.liveOnlyRequested && tx.commitKind.lands)
        let allowFastLiveScroll = tx.liveOnlyRequested && activeVirtualPaths.isEmpty && !lastViewReadScroll
        let canFastApplyOffsets = !tx.scrollOffsetRequests.isEmpty
            && tx.scrollOffsetRequests.allSatisfy { !$0.anchor }
            && (!markDirtyIfNotLiveOnly || tx.liveOnlyRequested)
            && !tx.isForceCommitRequested
            && !nonOffsetCommitRequests
            && !flatNodes.isEmpty
            && ((!scrollRequiresCommit && virtualLists.isEmpty) || allowFastLiveScroll)
        if canFastApplyOffsets {
            // The same per-request path a committing frame takes (`offset.rs::scroll_to_offsets`
            // + `apply_jumps`): glide or jump per axis, the long-trip cut, and the hover hold a
            // moving jump arms.
            var anySnapped = false
            let animNow = cxSettings.scaledTime(at: now)
            for req in tx.scrollOffsetRequests {
                guard let index = scrollViewportForOffset(key: req.key, x: req.x, y: req.y) else { continue }
                let path = flatNodes[index].path
                let cur = scrollOffsets[path] ?? .zero
                applyScrollOffsetRequest(path: path, x: req.x, y: req.y, glide: req.glide, cut: false, animNow: animNow, recordJump: true)
                if scrollOffsets[path] != cur {
                    frameMovedScrollPaths.insert(path)
                    anySnapped = true
                }
                scrollMovedSinceLastFrame = true
            }
            if anySnapped {
                updateScrollPositions(at: now)
            }
        } else if !tx.scrollOffsetRequests.isEmpty {
            pendingScrollOffsets.append(contentsOf: tx.scrollOffsetRequests)
        }
        if tx.commitKind == .settle {
            forceInitialSettle = true
        }
        if !tx.textFlights.isEmpty {
            let springOverride = tx.motionSpringRequest
            var scheduled = false
            for (src, dst) in tx.textFlights {
                if let srcNode = findNodeForFlightSelector(src, in: flatNodes),
                   (srcNode.el.isSecure || (srcNode.el.handlers.editLens?.get(state).isSecure == true)) {
                    continue
                }
                if let dstNode = findNodeForFlightSelector(dst, in: flatNodes),
                   (dstNode.el.isSecure || (dstNode.el.handlers.editLens?.get(state).isSecure == true)) {
                    continue
                }
                pendingTextFlights.append(makePendingFlightRequest(source: src, destination: dst, motionSpring: springOverride))
                scheduled = true
            }
            if scheduled {
                dirtyCommit(at: now, external: external, why: why)
            }
        }
        if !tx.launches.isEmpty {
            let springOverride = tx.motionSpringRequest
            for (src, dst) in tx.launches {
                pendingLaunches.append(makePendingFlightRequest(source: src, destination: dst, motionSpring: springOverride))
            }
            dirtyCommit(at: now, external: external, why: why)
        }
        if tx.unclippedFlightsRequested {
            pendingUnclippedFlights = true
        }
        applySelectionTx(tx, at: now)
        if let springOverride = tx.motionSpringRequest {
            lastCommitMotionSpring = springOverride
        }
        if let wf = tx.runtimeActions["windowFrameRequest"] as? WindowFrameRequest {
            let shouldSnap = !wf.animate || tx.settleRequested || reducedMotion
            let resolvedSpring: Spring? = shouldSnap ? nil : (tx.motionSpringRequest ?? MotionTokens.DEFAULT)
            let resolved = WindowFrameRequest(
                size: wf.size,
                animate: !shouldSnap && wf.animate,
                spring: resolvedSpring,
                center: wf.center
            )
            pendingWindowFrame = pendingWindowFrame?.merged(with: resolved) ?? resolved
        }
        latchClipboardRequests(tx)
        if !tx.sentKeys.isEmpty {
            pendingSentKeys.append(contentsOf: tx.sentKeys)
            queuedInputArrivals.sentKeys.append(contentsOf: repeatElement(InputTime.arrival(), count: tx.sentKeys.count))
        }
        if tx.toggleMaximizedRequested {
            toggleMaximizedRequested = true
        }
        if tx.toggleFullScreenRequested {
            toggleFullScreenRequested = true
        }
        if let ann = tx.announcement {
            lastAnnouncement = ann
            a11yAnnouncement.say(ann.text, politeness: ann.politeness)
        }
        processTxSlice2Actions(&mutableTx, at: now)
        // A latched focus ask schedules a commit (`latch_requests`: `focus_to` sets `dirty`), so a
        // `Tx.focusWhenShown` from a poll or handler that changed nothing still resolves.
        let latchedFocusWhenShown = tx.requestedFocusKey != nil && tx.focusAskedWhenShown
        let hasCommitRequests = nonOffsetCommitRequests || (!canFastApplyOffsets && !tx.scrollOffsetRequests.isEmpty) || blurDroppedFocus || latchedFocusWhenShown
        if tx.liveOnlyRequested {
            liveLane.set()
            if recordLiveOnlySkip(handler: liveOnlyLabel, at: now) {
                dirtyCommit(at: now, external: external, clearLiveCheck: false, why: why)
            }
        } else if markDirtyIfNotLiveOnly || tx.isForceCommitRequested || hasCommitRequests {
            noteHandlerChange()
            // A commit something asked for without a cause of its own (a poll that changed
            // nothing yet asked for a scroll) is a state change outside a handler.
            dirtyCommit(at: now, external: external, why: why == 0 ? CommitWhy.dirty : why)
        }
    }

    /// Updates viewport and scale from a user/host window resize, landing running motion (`set_viewport`).
    public func setViewport(_ newViewport: Vec2, pixelScale newScale: Float? = nil) {
        let targetScale = newScale ?? cxSettings.zoomState.windowScale
        cxSettings.zoomState.window = newViewport
        cxSettings.zoomState.windowScale = max(targetScale, 0.5)
        let (viewVP, viewScale) = cxSettings.zoomState.view()
        if fitHeight && !isPageMode && windowResting && fitWindowState.resized(to: viewVP.y, current: viewport.y) {
            needsCommit = true
            commitWhyPending |= CommitWhy.relayout
            userResizeNeedsCut = false
        }
        if fitHeight && viewVP.x == viewport.x && viewScale == pixelScale {
            let bandResized = isPageMode && viewport.y != viewVP.y
            suppressViewportCommitFlag = true
            viewport = viewVP
            suppressViewportCommitFlag = false
            if bandResized { updateScrollPositions(at: currentTime) }
            return
        }
        if viewVP != viewport || viewScale != pixelScale {
            let vpChanged = viewVP != viewport
            cxSettings.isApplyingZoom = true
            viewport = viewVP
            pixelScale = viewScale
            cxSettings.isApplyingZoom = false
            userResizeNeedsCut = true
            needsCommit = true
            commitWhyPending |= CommitWhy.relayout
            if vpChanged {
                pendingResizeRelayout = true
            }
        }
    }

    /// Advances viewport for one step of the window's own resize animation without cutting springs (`step_viewport`).
    public func stepViewport(_ newViewport: Vec2, pixelScale newScale: Float? = nil) {
        let targetScale = newScale ?? cxSettings.zoomState.windowScale
        cxSettings.zoomState.window = newViewport
        cxSettings.zoomState.windowScale = max(targetScale, 0.5)
        let (viewVP, viewScale) = cxSettings.zoomState.view()
        if fitHeight && viewVP.x == viewport.x && viewScale == pixelScale {
            let bandResized = isPageMode && viewport.y != viewVP.y
            suppressViewportCommitFlag = true
            viewport = viewVP
            suppressViewportCommitFlag = false
            if bandResized { updateScrollPositions(at: currentTime) }
            return
        }
        if viewVP != viewport || viewScale != pixelScale {
            let vpChanged = viewVP != viewport
            cxSettings.isApplyingZoom = true
            viewport = viewVP
            pixelScale = viewScale
            cxSettings.isApplyingZoom = false
            needsCommit = true
            commitWhyPending |= CommitWhy.relayout
            if vpChanged {
                pendingResizeRelayout = true
            }
        }
    }

    /// Whether a `Tx.resizeWindow` / `centerWindow` request is queued.
    public var hasPendingWindowFrame: Bool {
        pendingWindowFrame != nil
    }

    /// Consumes whether the last frame held motion for a fitting window resize (`FitWindow::take_held`).
    public func takeFitWindowHeld() -> Bool {
        fitWindowState.takeHeld()
    }

    /// Consumes and clears the latest pending window frame request (`Tx::resize_window` / `center_window`).
    public func takeWindowFrameRequest() -> WindowFrameRequest? {
        _ = fitWindowState.takeHeld()
        defer { pendingWindowFrame = nil }
        return pendingWindowFrame
    }

    /// Measures natural root content height at the current width without committing (`Runtime::content_height`).
    public func contentHeight() -> Float {
        RuntimeIdScope.$current.withValue(runtimeId) {
            var cx = Cx<State>(
                viewport: viewport,
                pixelScale: pixelScale,
                systemDark: systemDark,
                reducedMotion: reducedMotion,
                windowFocused: windowFocused,
                focusedKey: focusedKey,
                hoveredKey: hoveredKey,
                pressedKey: pressedKey,
                waker: waker,
                helpLook: viewHelpLook
            )
            cx.envState.safeAreaInsets = cxSettings.safeAreaInsets
            let rootEl = TextMeasure.withLentSystem(textSystem) { view(state, &cx) }
            let measured = retainedLayout.compute(
                root: rootEl,
                state: state,
                viewport: viewport,
                pixelScale: pixelScale,
                textSystem: textSystem,
                fitHeight: true
            )
            let h = measured.layout.localRect.height
            let scale = max(cxSettings.zoomState.windowScale, 0.5)
            return max(1.0, ceil((h * cxSettings.zoomState.k) * scale) / scale)
        }
    }

    // MARK: - App Shell Lifecycle & State Update Helpers

    /// True when the view tree needs a rebuild before the next frame (`Runtime::stale`).
    public var isStale: Bool { hasPendingCommit }

    /// Runs `poll(state, now, tx)` when attached. Only dirties the commit if `poll` returns `true`
    /// or `tx.commit()` was explicitly called.
    @discardableResult
    public func runPoll(at now: Double) -> Bool {
        RuntimeIdScope.$current.withValue(runtimeId) {
            guard let pollFn = poll else { return false }
            var tx = makeTx(at: now)
            tx.isInputWaiting = queuedInputWaiting
            let changed: Bool = PerfWarn.Stall.timed("poll") {
                if let scope = turnScope {
                    var res = false
                    scope(&state) { s in
                        res = pollFn(&s, now, &tx)
                    }
                    return res
                } else {
                    return pollFn(&state, now, &tx)
                }
            }
            _ = perfWatch.idle.polled(changed)
            let shouldDirty = changed || tx.isForceCommitRequested
            // frame.rs:530-533: `POLL` (and the meter's poll) only when the poll said it changed
            // the model; a commit it asked for without that is a request like any other (`DIRTY`).
            if changed {
                perfWatch.meter.poll()
            }
            applyTx(tx, at: now, markDirtyIfNotLiveOnly: shouldDirty, why: changed ? CommitWhy.poll : (shouldDirty ? CommitWhy.dirty : 0))
            return changed
        }
    }

    /// Mutates state via `body`, always rebuilding unless `tx.liveOnlyRequested` is true.
    public func update(at now: Double? = nil, _ body: (_ state: inout State, _ tx: inout Tx) -> Void) {
        RuntimeIdScope.$current.withValue(runtimeId) {
            suppressSelectionEffectsFromHoverCommit = false
            let t = now ?? currentTime
            var tx = makeTx(at: t)
            if let scope = turnScope {
                scope(&state) { s in body(&s, &tx) }
            } else {
                body(&state, &tx)
            }
            applyTx(tx, at: t, markDirtyIfNotLiveOnly: true, why: CommitWhy.dirty)
        }
    }

    /// Conditionally mutates state via `body`. Only dirties commit when `body` returns `true`
    /// or `tx.commit()` was explicitly called; side-effect requests (`wakeAfter`, `copy`, `quit`,
    /// etc.) still apply without forcing a rebuild (`app.rs:1240-1251`).
    @discardableResult
    public func updateIf(at now: Double? = nil, _ body: (_ state: inout State, _ tx: inout Tx) -> Bool) -> Bool {
        updateIfInner(at: now, ordered: false, body).stale
    }

    /// `updateIf` for a window drain (`Runtime::update_if_ordered`): a minimize it asked for comes
    /// back as its order instead of immediately latching `minimizeStep(.asked)`, unless a pick
    /// callback put back or replaced `tx` (which discards it). A minimize asked inside a pick
    /// callback itself still latches normally.
    internal func updateIfOrdered(
        at now: Double? = nil,
        _ body: (_ state: inout State, _ tx: inout Tx) -> Bool
    ) -> (stale: Bool, minimizeOrder: UInt64?) {
        updateIfInner(at: now, ordered: true, body)
    }

    private func updateIfInner(
        at now: Double? = nil,
        ordered: Bool,
        _ body: (_ state: inout State, _ tx: inout Tx) -> Bool
    ) -> (stale: Bool, minimizeOrder: UInt64?) {
        RuntimeIdScope.$current.withValue(runtimeId) {
            suppressSelectionEffectsFromHoverCommit = false
            let t = now ?? currentTime
            var tx = makeTx(at: t)
            let changed: Bool
            if let scope = turnScope {
                var res = false
                scope(&state) { s in res = body(&s, &tx) }
                changed = res
            } else {
                changed = body(&state, &tx)
            }
            let hadFocusBeforeUpdate = (focusedPath != nil || focusedKey != nil)
            let prevNeedsCommit = needsCommit
            let survivedMinimize: UInt64?
            if ordered {
                let asked = tx.minimizeOrder
                runPickReads(&tx)
                if let asked, tx.minimizeOrder == asked {
                    survivedMinimize = asked
                    tx.minimizeOrder = nil
                } else {
                    survivedMinimize = nil
                }
            } else {
                runPickReads(&tx)
                survivedMinimize = nil
            }
            let shouldDirty = changed || tx.isForceCommitRequested
            applyTx(
                tx,
                at: t,
                markDirtyIfNotLiveOnly: shouldDirty,
                why: shouldDirty ? CommitWhy.dirty : 0,
                runPicks: false
            )
            let txHasFrameWork = !tx.scrollRevealRequests.isEmpty
                || !tx.scrollBottomRequests.isEmpty
                || !tx.scrollPageRequests.isEmpty
                || !tx.scrollOffsetRequests.isEmpty
                || !tx.keepOnScreenKeys.isEmpty
                || !tx.textFlights.isEmpty
                || !tx.launches.isEmpty
                || !tx.invalidateMemoPrefixes.isEmpty
                || tx.followEdgeRequested
                || tx.requestedFocusKey != nil
                || tx.liveOnlyRequested
                || tx.isForceCommitRequested
                || tx.runtimeActions["windowFrameRequest"] != nil
                || tx.srgbBlendRequest.map { $0 != srgbBlend } == true
                || tx.fontSmoothingRequest.map { $0 != fontSmoothing } == true
                || (needsCommit && !prevNeedsCommit)
            let stale = changed || txHasFrameWork || (tx.blurFocusRequested && hadFocusBeforeUpdate)
            return (stale, survivedMinimize)
        }
    }

    internal func applyHookTx(_ tx: Tx, at now: Double) {
        applyTx(tx, at: now, markDirtyIfNotLiveOnly: true)
    }

    /// Gives back unused text, image and rewind storage, then runs the application’s rest hook.
    public func rest(at now: Double? = nil) {
        textSystem.rest()
        imagePacker.rest()
        rewindRecorder?.rest()
        guard let onRest else { return }
        let deadline = nextWakeDeadline
        if updateIf(at: now, onRest) || nextWakeDeadline != deadline { waker.wake() }
    }

    /// Sets `srgbBlend` and dirties the tree if changed.
    public func setSrgbBlend(_ enabled: Bool, at now: Double? = nil) {
        guard srgbBlend != enabled else { return }
        srgbBlend = enabled
        pendingColorMotionSpring = pendingColorMotionSpring ?? Spring.none
        dirtyCommit(at: now ?? currentTime)
    }

    /// Connects or replaces the waker notified when bound `Live`, `LiveText`, or `Pixels` sources publish (`Runtime::set_live_waker`).
    public func setLiveWaker(_ waker: Waker) {
        customLiveWaker = waker
        liveLane.waker.replaceCallback(dirty: liveLane.dirty) { [weak waker] in waker?.wake() }
    }

    /// Connects or replaces a closure wake callback for coalesced `Live` updates (`Runtime::set_live_waker`).
    public func setLiveWaker(_ callback: @escaping @Sendable () -> Void) {
        setLiveWaker(Waker(callback))
    }

    /// Clears any pending visible latch on the installed `LiveWake`.
    @discardableResult
    internal func takeParityLivePending() -> Bool {
        guard liveLane.visible else { return false }
        let took = liveLane.take()
        let had = liveLane.dirty
        liveLane.subscribed(false)
        return took || had
    }

    /// True when the window is visible and a subscribed `Live` / `LiveText` / `Pixels` source
    /// has pending work for the next frame (`Runtime::live_pending`).
    public var livePending: Bool {
        liveLane.pending()
    }
    internal var hasPendingHiddenWork: Bool {
        needsCommit
            || !pendingScrollBottoms.isEmpty
            || !pendingScrollReveals.isEmpty
            || !pendingTextFlights.isEmpty
            || !pendingLaunches.isEmpty
    }

    /// Runs `poll` while the window is hidden (`Runtime::poll_hidden`), returning `true` if
    /// the view or pending scroll/flight state became out of date.
    @discardableResult
    public func pollHidden(at now: Double) -> Bool {
        currentTime = now
        if timerWake.isAsked && (wakeDeadlines.first.map { $0 > now } ?? true) {
            cancelTimerFrame()
            return hasPendingHiddenWork
        }
        let changed = pollAlone(at: now)
        schedulePendingWakes(from: now)
        return changed || hasPendingHiddenWork
    }

    internal func focusedInputElement(at path: String) -> El<State>? {
        if let idx = nodeByPath[path], idx < flatNodes.count {
            return flatNodes[idx].el
        }
        return virtualInputs[path]?.el
    }

    internal func applyFocusedTextEditKey(_ ev: KeyEvent, el: El<State>, layout: ShapedText?, at now: Double) -> Bool {
        guard let editLens = el.handlers.editLens else { return false }
        var edit = editLens.get(state)
        let stateRevealed = edit.isRevealed
        if el.isSecure {
            edit.isSecure = true
            if let rev = el.revealedOverride { edit.isRevealed = rev }
        }
        let isCopyOrCut = ev.mods.primaryCommand &&
            (ev.key == .command("c") || ev.key == .text("c") || ev.key == .text("C") ||
             ev.key == .command("x") || ev.key == .text("x") || ev.key == .text("X"))
        let preCopyHTML: String? = (isCopyOrCut && edit.isRichEnabled && !edit.isSecure && edit.hasSelection)
            ? {
                let html = edit.toHTML(range: edit.selectedUTF8Range)
                return html.isEmpty ? nil : html
            }()
            : nil
        let outcome = edit.handleKey(ev, layout: layout, textSystem: textSystem, pixelScale: pixelScale)
        edit.isRevealed = stateRevealed
        switch outcome {
        case .ignored:
            return false
        case .navigation:
            editLens.set(&state, edit)
            dirtyCommit(at: now, why: CommitWhy.input)
            return true
        case .modified:
            editLens.set(&state, edit)
            var tx = makeTx(at: now)
            if el.layoutAnim == nil {
                tx.instant()
            }
            if let onChange = el.handlers.onTextChange {
                onChange(&state, edit.text, &tx)
            }
            applyTx(tx, at: now)
            dirtyCommit(at: now, why: CommitWhy.input)
            return true
        case .submit:
            editLens.set(&state, edit)
            if let onSubmit = el.handlers.onTextSubmit {
                var tx = makeTx(at: now)
                tx.animated()
                onSubmit(&state, edit.text, &tx)
                applyTx(tx, at: now)
                dirtyCommit(at: now, why: CommitWhy.input)
                return true
            }
            return false
        case .copy(let copied):
            editLens.set(&state, edit)
            recordCopy(ClipboardContent(copied, html: preCopyHTML))
            if let onChange = el.handlers.onTextChange {
                var tx = makeTx(at: now)
                onChange(&state, edit.text, &tx)
                applyTx(tx, at: now)
            }
            dirtyCommit(at: now, why: CommitWhy.input)
            return true
        }
    }

    /// Delivers a window focus transition to `onFocus`, deduplicating redundant transitions and
    /// leaving the runtime un-staled when `onFocus` is unset (`app.rs:973-992`).
    @discardableResult
    internal func cancelActiveDragOnBlur(at now: Double) -> Bool {
        guard let drag = activeDrag else { return false }
        state = drag.stateSnapshotBeforeDrag
        activeDrag = nil
        pressedPath = nil
        pressedKey = nil
        if let idx = nodeByPath[drag.path], let onEnd = flatNodes[idx].el.handlers.onDragEnd {
            var tx = makeTx(at: now)
            onEnd(&state, true, &tx)
            applyTx(tx, at: now)
        }
        dirtyCommit(at: now)
        return true
    }

    public func dispatchFocus(_ focused: Bool, at now: Double? = nil) {
        guard windowFocused != focused else { return }
        let t = now ?? currentTime
        let prevStale = needsCommit
        let prevWhy = commitWhyPending
        let previousCommits = commitCount
        // frame.rs:77-81: only a selection's active/inactive pair makes the change itself dirty.
        let repaints = windowFocusRepaintsSelection
        let wasBlurred = !windowFocused
        if focused && wasBlurred {
            hoverPaused = false
            kitHooks.hoverHoldAfterActionUntilMove = false
        }
        windowFocused = focused
        kitHooks.windowFocused = focused
        var handledFocus = false
        var cancelOrHoverDirty = false
        func resetInputMachinesOnBlur() {
            if cancelActiveDrag(at: nil, time: t) { cancelOrHoverDirty = true }
            inputMachines.secondaryCapture = .up
            inputMachines.pressClicks.clear()
            selectionState.clearClicks()
            inputMachines.firstDoubleClick = nil
            inputMachines.keyReleases.lost()
            wheelLost()
            inputMachines.currentMods = .none
            inputMachines.pendingKeysLost = false
            inputMachines.pendingKeysLostTime = nil
            if cancelPointerForFocusLoss(at: t) { cancelOrHoverDirty = true }
        }
        if let hook = onFocus {
            handledFocus = true
            if !playgroundDispatchFocus(focused, hook: hook, at: t) {
                update(at: t) { s, tx in hook(&s, focused, &tx) }
            }
        }
        if !focused { resetInputMachinesOnBlur() }
        if deliverWindowFocusTransition(focused, at: t) { handledFocus = true }
        if !focused {
            let hadDelayedHover = !hoverDelays.isEmpty
            endHoverDelays(at: t)
            if hadDelayedHover { cancelOrHoverDirty = true }
            if endKitHoverDelays(at: t) { cancelOrHoverDirty = true }
            hoverPaused = true
            kitHooks.hoverHoldAfterActionUntilMove = true
        }
        if !handledFocus && !cancelOrHoverDirty && !repaints && commitCount == previousCommits {
            // Nothing ran and nothing is dirty (frame.rs:90-92 queues no `WindowFocus`): the
            // commit and its causes stay as they were.
            needsCommit = prevStale
            commitWhyPending = prevWhy
        }
    }

    /// Consumes and clears the pending IME composition reset flag (`Runtime::ime_reset`).
    public func consumeImeReset() -> Bool {
        let was = imeReset
        imeReset = false
        return was
    }

    /// Whether the currently focused element accepts text/IME input.
    public var hasFocusedTextInput: Bool {
        guard let fp = focusedPath,
              let idx = nodeByPath[fp],
              !flatNodes[idx].effectiveInert else {
            return false
        }
        let el = flatNodes[idx].el
        return el.handlers.editLens != nil || el.role == .textInput
    }

    /// Whether the currently focused element requires secure keyboard input (`Runtime::has_secure_focus`).
    public var hasSecureFocus: Bool {
        guard let fp = focusedPath else { return false }
        return elementIsSecure(fp)
    }

    /// Returns a reconversion/surrounding text snapshot for the focused non-secure `TextEdit` (`Runtime::ime_text`).
    public func focusedImeSnapshot(maxContextBytes: Int = 1024) -> ImeText? {
        guard let fp = focusedPath else { return nil }
        if let idx = nodeByPath[fp], flatNodes[idx].effectiveInert { return nil }
        guard let el = focusedInputElement(at: fp),
              let editLens = el.handlers.editLens else {
            return nil
        }
        var edit = editLens.get(state)
        if el.isSecure {
            edit.isSecure = true
        }
        return edit.imeTextSnapshot(maxContextBytes: maxContextBytes)
    }

    /// Whether either a non-secure focused `textInput` or an active `imeCursor` holds IME (`ime_allowed`).
    public var hasImeTarget: Bool {
        !hasSecureFocus && (hasFocusedTextInput || imeCursorArea != nil)
    }

    /// Effective Option-as-Alt flag while IME is held by an `imeCursor` (`Runtime.ime_option_as_alt`).
    public var effectiveImeOptionAsAlt: Bool {
        !hasSecureFocus && !hasFocusedTextInput && imeCursorArea != nil && imeOptionAsAlt
    }

    /// Returns the focused input caret rect in window coordinates, if available.
    public func focusedCaretRect() -> MotionRect? {
        if let c = (currentFocusedCaret() ?? cxSettings.lastCommittedCaret)?.rect,
           c.count >= 4 {
            return MotionRect.fromXYWH(c[0], c[1], c[2], c[3])
        }
        if let a = imeArea, a.count >= 4 {
            return MotionRect.fromXYWH(a[0], a[1], a[2], a[3])
        }
        if let c = imeCursorArea, c.count >= 4 {
            return MotionRect.fromXYWH(c[0], c[1], c[2], c[3])
        }
        return nil
    }

    /// Commits any open preedit composition on focus loss or window deactivation (`Runtime::finish_composition`).
    @discardableResult
    public func finishComposition(at now: Double? = nil) -> Bool {
        let t = now ?? currentTime
        // `Action::FinishIme` is routed (frame.rs:573): a change an earlier handler or the state
        // left commits before it, so the composition finishes on the tree that shows it. Before
        // the first commit there is no tree yet: the first frame builds one before anything it
        // queued runs (frame.rs:547), so a blur before then waits for it.
        if commitCount > 0 {
            commitPolledChangeApart(at: t, routed: true)
            flushPendingCommitIfNeeded(at: t)
            focusOwedFromSplit = false
        }
        imeReset = true
        // It isn't input (`ActionQueue::push`, action.rs:89: `FinishIme` is `input: false`; the
        // window's focus loss that asks for it carries no arrival time): its change commits for
        // `DIRTY` (frame.rs: `why |= if input { INPUT } else { DIRTY }`).
        if finishAppImeComposition(at: t, why: CommitWhy.dirty) {
            return true
        }
        guard let fp = focusedPath,
              let el = focusedInputElement(at: fp),
              let editLens = el.handlers.editLens else {
            _ = dispatchIme(.cancel, at: t)
            return false
        }
        let prevEdit = editLens.get(state)
        var edit = prevEdit
        if let activePreedit = edit.preedit?.text, edit.finishPreedit() {
            deliverInputEdit(el: el, previousEdit: prevEdit, newEdit: edit, editLens: editLens, at: t, why: CommitWhy.dirty)
            _ = dispatchIme(.commit(activePreedit), at: t)
            return true
        }
        return false
    }

    /// Applies an AppKit/OS `ImeEvent` to the focused `TextEdit` and forwards to `onIme` (`Runtime::ime`).
    @discardableResult
    public func dispatchImeEvent(_ event: ImeEvent, at now: Double? = nil) -> Bool {
        dispatchImeEvent(event, recordReleaseGuard: true, at: now)
    }

    @discardableResult
    internal func dispatchImeEvent(_ event: ImeEvent, recordReleaseGuard: Bool, at now: Double? = nil) -> Bool {
        let t = now ?? currentTime
        let inputMark = noteInput(at: t, routed: true)
        defer { endInputDispatch(inputMark, queuedAction: true) }
        let imeStartNs = InteractionGate.isOn ? RuneExecutionContext.uptimeNanoseconds : 0
        flushPendingCommitIfNeeded(at: t)
        let shellIme: Ime
        switch event {
        case .preedit(let str, let cursorUTF8, let clauses):
            shellIme = .preedit(ImePreedit(text: str, cursorUTF8: cursorUTF8, clauses: clauses))
        case .commit(let str):
            shellIme = .commit(str)
        case .select(let range):
            shellIme = .select(range)
        case .enabled:
            shellIme = .enabled
        case .disabled:
            shellIme = .disabled
        }
        let appHandlesOnly = inputMachines.appIme.isComposing || (shellIme == .enabled || shellIme == .disabled) || !hasFocusedTextInput
        let activeIme: Bool = {
            if isAnyImeComposing { return true }
            switch event {
            case .preedit(let s, _, _), .commit(let s): return !s.isEmpty
            case .select, .enabled, .disabled: return false
            }
        }()
        if appHandlesOnly {
            let ran = dispatchAppIme(shellIme, at: t)
            if recordReleaseGuard && ran && activeIme { inputMachines.keyReleases.imeTookKey() }
            return ran
        }
        let handledByEdit = applyImeToFocusedField(event, at: t)
        if case .select = event { return handledByEdit }
        let handledByHook: Bool
        if let hook = onIme {
            var tx = makeTx(at: t)
            handledByHook = Tx.took(hook(&state, shellIme, &tx), &tx)
            applyTx(tx, at: t, markDirtyIfNotLiveOnly: handledByHook)
        } else {
            handledByHook = false
        }
        let ran = handledByEdit || handledByHook
        if recordReleaseGuard && ran && activeIme { inputMachines.keyReleases.imeTookKey() }
        if InteractionGate.isOn,
           let note = interactionNote(action: "key_edit", rank: 3, path: focusedPath) {
            let endedNs = RuneExecutionContext.uptimeNanoseconds
            let handlerMs = Double(endedNs >= imeStartNs ? endedNs - imeStartNs : 0) / 1_000_000.0
            perfWatch.interaction.noted(note: note, arrivedNs: imeStartNs, startedNs: imeStartNs, handlerMs: handlerMs)
        }
        return ran
    }

    internal func applyImeToFocusedField(_ event: ImeEvent, at t: Double) -> Bool {
        var handledByEdit = false
        if let fp = focusedPath,
           nodeByPath[fp].map({ !flatNodes[$0].effectiveInert }) ?? true,
           let el = focusedInputElement(at: fp),
           let editLens = el.handlers.editLens {
            let prevEdit = editLens.get(state)
            var edit = prevEdit
            let stateRevealed = edit.isRevealed
            if el.isSecure {
                edit.isSecure = true
                if let rev = el.revealedOverride { edit.isRevealed = rev }
            }
            let outcome = edit.applyIme(event)
            edit.isRevealed = stateRevealed
            switch outcome {
            case .ignored:
                break
            case .navigation:
                editLens.set(&state, edit)
                pendingCaretFollow = true
                selectionState.pendingFollowCaret = true
                dirtyCommit(at: t, why: CommitWhy.input)
                handledByEdit = true
            case .modified:
                selectionState.pendingFollowCaret = true
                deliverInputEdit(el: el, previousEdit: prevEdit, newEdit: edit, editLens: editLens, at: t)
                handledByEdit = true
            case .submit, .copy:
                editLens.set(&state, edit)
                selectionState.pendingFollowCaret = true
                dirtyCommit(at: t, why: CommitWhy.input)
                handledByEdit = true
            }
        }
        return handledByEdit
    }

    /// Resolves the pointer cursor shape under the current pointer / press target (`Runtime::cursor`).
    public func currentCursor() -> Cursor {
        if let cursor = slice2State.autoscroll.cursor { return cursor }
        guard pointerPosition.x >= 0,
              pointerPosition.y >= 0,
              pointerPosition.x < viewport.x,
              pointerPosition.y < viewport.y else {
            return .default
        }

        var curIdx: Int?
        if let tp = pressedPath, let idx = nodeByPath[tp], !flatNodes[idx].effectiveInert {
            curIdx = idx
        } else if let held = heldHover(), let idx = held {
            // Moving layout holds hover: the cursor stays with what the pointer was over.
            curIdx = idx
        } else if let hp = hoveredPath, let idx = hoverLive(hp) {
            curIdx = idx
        } else if let hit = hitTest(at: pointerPosition, predicate: { _ in true }) {
            curIdx = nodeByPath[hit.node.path]
        }
        guard var idx = curIdx else { return .default }

        if let linkCur = linkCursor(atPath: flatNodes[idx].path, at: pointerPosition) {
            return linkCur
        }

        let leafEl = flatNodes[idx].el
        if leafEl.attachedCursor == nil {
            if leafEl.handlers.editLens != nil || leafEl.role == ElementRole.textInput || leafEl.isSelectable {
                return .text
            }
            if leafEl.role == ElementRole.link || leafEl.a11yHref != nil {
                return .pointer
            }
        }
        while true {
            if let c = flatNodes[idx].el.attachedCursor {
                return c
            }
            guard let parent = flatNodes[idx].parentIndex else {
                return .default
            }
            idx = parent
        }
    }

    /// Native help tooltip hit regions (`Runtime::help_regions`).
    public func helpRegionsList() -> [(MotionRect, String)] {
        helpState.regions.map { (MotionRect.fromXYWH($0.rect.x, $0.rect.y, $0.rect.z, $0.rect.w), $0.text) }
    }

    public func dispatchModifiers(_ mods: Mods, at now: Double? = nil) {
        inputMachines.currentMods = mods
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

    /// Updates host live visibility (`Runtime::set_live_visible`), gating `Live` wakes and notifying `onVisibility` after first commit.
    public func setLiveVisible(_ visible: Bool, at now: Double? = nil) {
        let wasVisible = liveVisible
        let changed = (visible != wasVisible)
        let wokeFromLiveWake = liveLane.setVisible(visible)
        if !wokeFromLiveWake && visible && !wasVisible && liveLane.dirty {
            (customLiveWaker ?? waker).wake()
        }
        if changed && commitCount > 0 {
            dispatchVisibility(visible, at: now)
        }
    }

    /// Executes a hidden or covered wake (`Runtime::hidden_wake`): flushes queued input on a zero-advance frame
    /// or runs `poll` without building the view tree, returning whether the drawn frame is invalidated.
    @discardableResult
    public func hiddenWake(at now: Double? = nil) -> Bool {
        let t = now ?? nowClock()
        if hasPendingInput {
            let prevCommits = commitCount
            _ = frame(at: t)
            if hasPendingInput {
                _ = frame(at: t)
            }
            return commitCount != prevCommits
        }
        if let explicit = now {
            return pollHidden(at: explicit)
        }
        return pollHidden()
    }

    /// Snaps all in-flight transitions and reveals before the next frame (`Runtime::settle_all`).
    public func settleAll() {
        forceInitialSettle = true
        explicitSettleRequested = true
        needsCommit = true
        // `settle_all` sets `settle` and `dirty`: the frame commits for both.
        commitWhyPending |= CommitWhy.dirty
    }

    /// Advances the app-requested minimize latch (`window/minimize.rs::Runtime::minimize_step`).
    @discardableResult
    public func minimizeStep(_ event: MinimizeEvent) -> Bool {
        var next = minimizeState
        let effects = WindowMinimize.step(&next, event: event)
        minimizeState = next
        return effects.contains(.minimize)
    }

    /// Executes one shell minimize step, taking any ready minimize ask (`minimize::shell_take`).
    @discardableResult
    public func shellTakeMinimize() -> Bool {
        minimizeStep(.taken)
    }

    /// Clears a latched minimize request when the shell declines or ignores it (`Runtime::ignore_minimize`).
    public func ignoreMinimize(_ reason: String = "") {
        _ = reason
        _ = minimizeStep(.lost)
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

    /// Updates the window's screen origin in points (for `onScreenLayout` reporting) and drains queued screen-layout callbacks immediately.
    public func setWindowOrigin(_ origin: Vec2, at now: Double?) {
        if setWindowOrigin(origin) {
            _ = drainLayoutActions(at: now ?? currentTime)
        }
    }

    public func clearShellRequests() {
        closeWindowRequested = false
        _ = minimizeStep(.lost)
        relaunchRequested = false
        toggleMaximizedRequested = false
        toggleFullScreenRequested = false
        nextWakeDeadline = nil
    }

    internal func flushPendingSentKeys(at now: Double, prefix: Int? = nil) {
        guard !pendingSentKeys.isEmpty else { return }
        let count = min(prefix ?? pendingSentKeys.count, pendingSentKeys.count)
        let queued = pendingSentKeys.prefix(count)
        let stamps = queuedInputArrivals.sentKeys.prefix(count)
        pendingSentKeys.removeFirst(count)
        queuedInputArrivals.sentKeys.removeFirst(stamps.count)
        let savedPhys = slice2State.lastPressedPhysicalKey
        let savedBase = slice2State.lastPressedKeyBase
        slice2State.lastPressedPhysicalKey = nil
        slice2State.lastPressedKeyBase = nil
        defer {
            slice2State.lastPressedPhysicalKey = savedPhys
            slice2State.lastPressedKeyBase = savedBase
        }
        for (i, ev) in queued.enumerated() {
            // Each runs under the stamp of the input that sent it, so what it sends keeps it.
            InputTime.withArrival(i < stamps.count ? stamps[i] : nil) {
                _ = keyDown(ev, isRepeat: false, at: now)
            }
        }
    }

    internal func deliverInputEdit(
        el: El<State>,
        previousEdit: TextEdit,
        newEdit: TextEdit,
        editLens: (get: (State) -> TextEdit, set: (inout State, TextEdit) -> Void),
        at now: Double,
        why: UInt16 = CommitWhy.input
    ) {
        editLens.set(&state, newEdit)
        pendingCaretFollow = true
        var tx = makeTx(at: now)
        if !el.animateEditLayoutEnabled {
            tx.instant()
        } else if tx.motionSource == nil && !tx.commitKind.snaps && el.layoutAnim == nil {
            tx.motionSource = .spring(el.styleSpring ?? MotionTokens.DEFAULT)
        }
        // Non-key callbacks (`onInputChange`) never inherit the key handler's physical key (`physical.rs:499`).
        tx.physicalKeyValue = nil
        tx.keyBaseValue = nil
        tx.keyRepeatValue = false
        if let onInputChange = el.handlers.onInputChange {
            let rejected = onInputChange(&state, newEdit.text, &tx)
            if rejected {
                editLens.set(&state, previousEdit)
                applyTx(tx, at: now, why: why)
                dirtyCommit(at: now, why: why)
                return
            }
        }
        if let onChange = el.handlers.onTextChange {
            let currentText = editLens.get(state).text
            onChange(&state, currentText, &tx)
        }
        applyTx(tx, at: now, why: why)
        dirtyCommit(at: now, why: why)
    }

    private func scrollRegionBelow(node overlay: FlatNode, at point: Vec2) -> FlatNode? {
        let orderedPaths: [String]
        if !paintOrderPaths.isEmpty {
            orderedPaths = paintOrderPaths
        } else {
            orderedPaths = flatNodes.indices.sorted { a, b in
                let za = flatNodes[a].zOrder
                let zb = flatNodes[b].zOrder
                if za != zb { return za < zb }
                return a < b
            }.map { flatNodes[$0].path }
        }
        var underIdx: Int? = nil
        for path in orderedPaths.reversed() {
            if path == overlay.path || path.hasPrefix(overlay.path + "/") { continue }
            guard let idx = nodeByPath[path], idx < flatNodes.count else { continue }
            let candidate = flatNodes[idx]
            if candidate.effectiveInert { continue }
            if let geom = hitGeometryByPath[path] {
                if geom.isExiting || geom.opacity <= 0.001 { continue }
                guard geom.contains(point) else { continue }
                underIdx = idx
                break
            } else {
                if candidate.el.opacity <= 0.001 { continue }
                let infoRect = presentedRectByPath[path] ?? candidate.targetRect
                let hitBox = intersectRects(candidate.clipRect, infoRect)
                guard halfOpenContains(hitBox, point) else { continue }
                underIdx = idx
                break
            }
        }
        var walkIdx = underIdx
        while let cur = walkIdx, cur < flatNodes.count {
            let candidate = flatNodes[cur]
            if !candidate.el.layout.scrollAxes.isEmpty && canFocusIndex(cur) {
                return candidate
            }
            walkIdx = candidate.parentIndex
        }
        return nil
    }

    private func advanceTabFocus(backward: Bool) -> Bool {
        if linkTab(backward: backward) {
            return true
        }
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
        } else if let curPath = focusedPath,
                  let outsideIdx = nodeByPath[curPath] {
            nextIdx = backward
                ? (candidateIndices.last(where: { $0 < outsideIdx }) ?? candidateIndices.last!)
                : (candidateIndices.first(where: { $0 > outsideIdx }) ?? candidateIndices.first!)
        } else if cxSettings.viewDefaults.webFocus,
                  let startPath = webFocusTabStartPath,
                  let startIdx = flatNodes.firstIndex(where: { $0.path == startPath }) {
            nextIdx = backward
                ? (candidateIndices.last(where: { $0 < startIdx }) ?? candidateIndices.last!)
                : (candidateIndices.first(where: { $0 > startIdx }) ?? candidateIndices.first!)
        } else {
            nextIdx = backward ? candidateIndices.last! : candidateIndices.first!
        }
        if focusedPath != flatNodes[nextIdx].path {
            finishPreeditIfNeeded(forPath: focusedPath, at: currentTime)
        }
        assignFocusPath(flatNodes[nextIdx].path, keyboard: true)
        focusedKey = flatNodes[nextIdx].key
        inputMachines.focusMachine.highlightedPath = nil
        inputMachines.focusMachine.hoveredHighlight = false
        focusKeyboard = true
        blurredFocusPath = nil
        focusHandoff = false
        webFocusTabStartPath = nil
        if hasActiveTextLinks(flatNodes[nextIdx].el) {
            let links = flatNodes[nextIdx].el.textLinks
            let k = backward ? max(0, links.count - 1) : 0
            focusedLinkIndex = k
            focusedKey = links[k].id
        } else {
            focusedLinkIndex = nil
        }
        return true
    }

    private func defaultButtonNode() -> FlatNode? {
        for idx in flatNodes.indices.reversed() {
            let node = flatNodes[idx]
            guard node.el.isDefaultButton, node.el.hasAuthoredHandlers, node.el.handlers.hasPress,
                  !node.effectiveInert, !node.el.a11yDisabled, !subtreeExiting(idx),
                  node.targetRect.width > 0, node.targetRect.height > 0 else { continue }
            var ancestor: Int? = idx
            while let i = ancestor, flatNodes[i].el.opacity > 0 {
                ancestor = flatNodes[i].parentIndex
            }
            if ancestor == nil { return node }
        }
        return nil
    }

    private func playgroundIsTyping() -> Bool {
        playgroundLive?.typing(appState: state) == true
    }

    private func tryDefaultButtonReturn(at now: Double, isRepeat: Bool) -> Bool {
        guard let defNode = defaultButtonNode() else { return false }
        if isRepeat { return true }
        return invokeKeyboardPress(defNode, at: now)
    }

    internal func findFocusGroupAncestor(of idx: Int) -> Int? {
        var cur: Int? = idx
        while let i = cur {
            if flatNodes[i].el.focusGroup {
                return i
            }
            cur = flatNodes[i].parentIndex
        }
        return nil
    }

    private func focusGroupMembers(groupIndex: Int, excludeEditable: Bool = false) -> [Int] {

        let prefix = flatNodes[groupIndex].path + "/"
        return flatNodes.indices.filter { i in
            (flatNodes[i].path == flatNodes[groupIndex].path || flatNodes[i].path.hasPrefix(prefix)) &&
            canFocusIndex(i) &&
            (!excludeEditable || flatNodes[i].el.handlers.editLens == nil)
        }
    }

    private func activateFocusGroupMember(
        groupIndex: Int,
        members: [Int],
        curIdx: Int,
        targetPos: Int,
        at now: Double
    ) {
        let nextNode = flatNodes[members[targetPos]]
        assignFocusPath(nextNode.path, keyboard: true)
        focusedKey = nextNode.key
        focusKeyboard = true
        blurredFocusPath = nil
        focusHandoff = false
        webFocusTabStartPath = nil
        focusedLinkIndex = nil
        hoveredHighlightActive = false
        focusVisible = true
        pendingScrollReveals.append(.intoView(scope: nil, key: nextNode.key ?? nextNode.path))

        let follows = nextNode.el.role == .radio || nextNode.el.role == .tab || flatNodes[groupIndex].el.isFocusFollowsSelection
        if follows && members[targetPos] != members[curIdx] {
            _ = invokeKeyboardPress(nextNode, at: now)
        }
    }

    private func handleFocusGroupKey(_ ev: KeyEvent, focusedIndex fIdx: Int, at now: Double) -> Bool {
        guard flatNodes[fIdx].el.handlers.editLens == nil,
              !ev.mods.cmd, !ev.mods.ctrl, !ev.mods.alt,
              let groupIdx = findFocusGroupAncestor(of: fIdx) else {
            return false
        }
        let groupNode = flatNodes[groupIdx]
        if ev.mods == .none {
            let isRtl = groupNode.flow == .rtl
            var nav: (forward: Bool, jump: Int?)? = nil
            switch ev.key {
            case .home: nav = (true, 0)
            case .end: nav = (false, -1)
            case .arrowDown: nav = (true, nil)
            case .arrowUp: nav = (false, nil)
            case .arrowRight: nav = (!isRtl, nil)
            case .arrowLeft: nav = (isRtl, nil)
            default: break
            }
            if let nav {
                kitHooks.typeSelectBuffer = ""
                if moveFocusInGroup(groupIndex: groupIdx, forward: nav.forward, jumpEndpoint: nav.jump, at: now) {
                    dirtyCommit(at: now, why: CommitWhy.input)
                    return true
                }
                return false
            }
        }
        let groupRole = groupNode.el.role
        let typeSelectAllowed = (groupRole == .menu || groupRole == .listbox || groupRole == .list || groupRole == .tree || groupRole == .tabList)
        guard typeSelectAllowed, case .text(let typed) = ev.key else { return false }
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let members = focusGroupMembers(groupIndex: groupIdx, excludeEditable: true)
        guard !members.isEmpty,
              let curPath = focusedPath,
              let curIdx = members.firstIndex(where: { flatNodes[$0].path == curPath }) else {
            return false
        }
        if now - kitHooks.typeSelectLastTime > 0.8 {
            kitHooks.typeSelectBuffer = ""
        }
        kitHooks.typeSelectLastTime = now
        kitHooks.typeSelectBuffer += typed.lowercased()
        guard let first = kitHooks.typeSelectBuffer.first else { return false }
        let cycle = kitHooks.typeSelectBuffer.allSatisfy { $0 == first }
        let matchPrefix = cycle ? String(first) : kitHooks.typeSelectBuffer
        let order = (0..<members.count).map { k in
            cycle ? (curIdx + 1 + k) % members.count : k
        }
        guard let targetPos = order.first(where: { idx in
            let el = flatNodes[members[idx]].el
            let label = (el.a11yLabel ?? el.plainText ?? "").lowercased()
            return label.hasPrefix(matchPrefix)
        }) else {
            return false
        }
        activateFocusGroupMember(groupIndex: groupIdx, members: members, curIdx: curIdx, targetPos: targetPos, at: now)
        dirtyCommit(at: now, why: CommitWhy.input)
        return true
    }

    private func moveFocusInGroup(
        groupIndex: Int,
        forward: Bool,
        jumpEndpoint: Int? = nil,
        at now: Double
    ) -> Bool {
        let members = focusGroupMembers(groupIndex: groupIndex)
        guard !members.isEmpty,
              let curPath = focusedPath,
              let curIdx = members.firstIndex(where: { flatNodes[$0].path == curPath }) else {
            return false
        }
        let nextPos: Int
        if let jump = jumpEndpoint {
            nextPos = jump < 0 ? (members.count - 1) : 0
        } else if members.count > 1 {
            let groupRole = flatNodes[groupIndex].el.role
            if groupRole == .list || groupRole == .listbox || groupRole == .tree || groupRole == .grid {
                nextPos = forward ? min(curIdx + 1, members.count - 1) : max(curIdx - 1, 0)
            } else {
                nextPos = forward
                    ? (curIdx + 1) % members.count
                    : (curIdx - 1 + members.count) % members.count
            }
        } else {
            return false
        }
        activateFocusGroupMember(groupIndex: groupIndex, members: members, curIdx: curIdx, targetPos: nextPos, at: now)
        return true
    }

    internal func textHitOffset(node: FlatNode, windowPos: Vec2, edit: TextEdit) -> Int {
        textCaretHit(node: node, windowPos: windowPos, edit: edit).utf8Offset
    }

    internal func textCaretHit(node: FlatNode, windowPos: Vec2, edit: TextEdit) -> TextCursorMove {
        var resolvedEdit = edit
        if node.el.isSecure {
            resolvedEdit.isSecure = true
            if let rev = node.el.revealedOverride { resolvedEdit.isRevealed = rev }
        }
        guard !resolvedEdit.text.isEmpty else { return TextCursorMove(utf8Offset: 0) }
        if resolvedEdit.isHiddenMultiline { return TextCursorMove(utf8Offset: resolvedEdit.text.utf8.count) }
        let rect = presentedRectByPath[node.path] ?? node.targetRect
        let sc = presentedScales[node.path] ?? Vec2(1, 1)
        let innerW = max(0, rect.width - (node.el.layout.padding.left + node.el.layout.padding.right) * sc.x)
        let resolvedInput = ElDisplayResolver.resolveInput(
            el: node.el,
            edit: resolvedEdit,
            innerWidth: innerW / max(0.01, sc.x),
            pxScale: pixelScale
        )
        let shaped: ShapedText
        if let request = Self.paragraphRequest(field: node.nodeId, el: node.el, edit: resolvedEdit, resolved: resolvedInput) {
            shaped = textSystem.layoutInput(
                text: resolvedInput.renderedString,
                spans: resolvedInput.spans,
                pills: resolvedInput.pills,
                style: resolvedInput.style,
                maxWidth: resolvedInput.maxWidthForShape,
                pixelScale: pixelScale,
                emitGlyphs: false,
                request: request
            ).shaped
        } else {
            shaped = textSystem.shape(
                text: resolvedInput.renderedString,
                spans: resolvedInput.spans,
                pills: resolvedInput.pills,
                style: resolvedInput.style,
                maxWidth: resolvedInput.maxWidthForShape,
                pixelScale: pixelScale,
                emitGlyphs: false,
                bypassCache: resolvedEdit.isSecure
            )
        }
        let hScroll = resolvedEdit.multiline ? 0 : (inputMachines.inputScroll[node.path] ?? 0)
        let point = hitGeometryByPath[node.path]?.turn?.unturn(windowPos) ?? windowPos
        let localX = (point.x - (rect.x + node.el.layout.padding.left * sc.x)) / max(0.01, sc.x) + hScroll
        let localY = (point.y - (rect.y + node.el.layout.padding.top * sc.y)) / max(0.01, sc.y)
        let line = shaped.lineIndex(atLocalY: localY, lineCount: shaped.cursorLineCount)
        var hit = textSystem.caretHit(in: shaped, on: line, atX: localX, pixelScale: pixelScale)
        if resolvedEdit.isSecure && !resolvedEdit.isRevealed {
            // The mask draws one bullet per scalar. Editing still lands at a grapheme edge.
            var remaining = hit.utf8Offset / "•".utf8.count
            var byte = 0
            for character in resolvedEdit.text {
                let count = character.unicodeScalars.count
                if remaining < count {
                    if remaining > count - remaining { byte += character.utf8.count }
                    break
                }
                remaining -= count
                byte += character.utf8.count
            }
            hit.utf8Offset = byte
        } else {
            hit.utf8Offset = resolvedEdit.snapToGraphemeBoundary(hit.utf8Offset)
        }
        return hit
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

    internal func dismissHelp(at now: Double) {
        if helpState.tipState.target != nil {
            stepHelpState(event: .dismiss, at: now)
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

    private func updateHelp(at now: Double, primitives: inout [Primitive], recordGlyphPage: (Int, UInt16) -> Void) {
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
        } else if heldHover() != nil {
            // While moving layout holds hover, the tooltip keeps its element, and nothing sliding
            // under the pointer starts a wait (`help.rs::help_over`).
            if let kept = helpState.tipState.target, hoverLive(kept.path) != nil {
                // Kept whenever the element is live, drawn into this frame's hits or not (a glide
                // may carry it out of view); the tip draws from its hit when there is one.
                over = .help(kept)
                underHit = helpState.hits.last(where: { $0.path == kept.path && $0.linkIndex == kept.link })
            } else {
                over = .nothing
                underHit = nil
            }
        } else if let u = helpUnder(point: pointerPosition) {
            let target = HelpTarget(path: u.hit.path, link: u.hit.linkIndex)
            // A press holds the pointer: a drag across other elements starts no tooltip.
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
                    runtime: self,
                    primitives: &primitives,
                    recordGlyphPage: recordGlyphPage
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
                    runtime: self,
                    primitives: &primitives,
                    recordGlyphPage: recordGlyphPage
                )
                helpState.currentTip = (runeHelpWords(drawn.text), tipRect)
                helpState.drawn = drawn
            }
        }
    }
}

@inline(__always)
internal func intersectRects(_ a: MotionRect, _ b: MotionRect) -> MotionRect {
    let l = max(a.left, b.left)
    let t = max(a.top, b.top)
    let r = max(l, min(a.right, b.right))
    let bot = max(t, min(a.bottom, b.bottom))
    return MotionRect(left: l, top: t, right: r, bottom: bot)
}

@inline(__always)
internal func snapBorderWidthPx(_ widthPt: Float, scale: Float) -> Float {
    PixelSnap.lineWidth(widthPt * scale)
}

@inline(__always)
internal func blendColorOver(bottom: Color, top: Color, srgb: Bool = false) -> Color {
    let ta = top.a.clamped(to: 0...1)
    let ba = bottom.a.clamped(to: 0...1)
    let outA = ta + ba * (1.0 - ta)
    if outA <= 1e-5 { return .transparent }
    if srgb {
        let tr = RefShader.linearToSRGB(top.r)
        let tg = RefShader.linearToSRGB(top.g)
        let tb = RefShader.linearToSRGB(top.b)
        let br = RefShader.linearToSRGB(bottom.r)
        let bg = RefShader.linearToSRGB(bottom.g)
        let bb = RefShader.linearToSRGB(bottom.b)
        let sr = (tr * ta + br * ba * (1.0 - ta)) / outA
        let sg = (tg * ta + bg * ba * (1.0 - ta)) / outA
        let sb = (tb * ta + bb * ba * (1.0 - ta)) / outA
        return Color(
            r: RefShader.srgbToLinear(sr),
            g: RefShader.srgbToLinear(sg),
            b: RefShader.srgbToLinear(sb),
            a: outA
        )
    }
    let r = (top.r * ta + bottom.r * ba * (1.0 - ta)) / outA
    let g = (top.g * ta + bottom.g * ba * (1.0 - ta)) / outA
    let b = (top.b * ta + bottom.b * ba * (1.0 - ta)) / outA
    return Color(r: r, g: g, b: b, a: outA)
}


/// Query moving lanes once per paint instead of probing seven store entries per mounted node.
internal struct PaintMotionTracks {
    var spatial: Set<NodeId> = []
    var unheldScale: Set<NodeId> = []

    init(store: AnimationStore) {
        for (id, prop) in store.active() {
            let scales = prop == Props.SCALE.id || prop == Props.UNIFORM_SCALE.id || prop == Props.PRESENCE.id
            if scales || prop == Props.FRAME.id || prop == Props.TRAVEL.id || prop == Props.OFFSET.id || prop == Props.ROTATE.id {
                spatial.insert(id)
            }
            if (scales || prop == Props.PRESS_SCALE.id) && store.isUnheldAnimating(id, prop) {
                unheldScale.insert(id)
            }
        }
    }
}

private struct PaintElementKey: Hashable {
    var path: String
    var exiting: Bool
}

private struct OwnPaintPresentation {
    var rect: MotionRect
    var scale: Vec2
    var opacity: Float
    var preLoopOpacity: Float
    var rotation: Float
}

extension FrameOutput {
    /// Scene publishes this index with its snapshot. Synthesized motion-gate frames supply the nodes alone.
    internal var paintNodesById: FramePoseIndex {
        if poseIndex.count == nodes.count { return poseIndex }
        var index = Dictionary<NodeId, Presented>(minimumCapacity: nodes.count)
        for node in nodes { index[node.id] = node }
        return FramePoseIndex(index)
    }
}
