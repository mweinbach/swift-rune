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

internal struct PresentedTransform {
    var dx: Float = 0
    var dy: Float = 0
    var anchor: Vec2 = .zero
    var anchorTo: Vec2 = .zero
    var scale: Vec2 = Vec2(1, 1)
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

    private static let allNames: [String] = [
        "tracks", "growth", "scroll", "reveal", "loop",
        "scale-settle", "video", "text-flight", "live", "virtual-fill",
    ]

    public static func names(_ bits: UInt32) -> [String] {
        var out: [String] = []
        for (i, name) in allNames.enumerated() where (bits & (1 << UInt32(i))) != 0 {
            out.append(name)
        }
        return out
    }
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

    public static func stub(_ key: String) -> ElementInfo {
        ElementInfo(
            path: "/0/@\(key)",
            key: key,
            parentIndex: 0,
            role: .group,
            rect: [0, 0, 0, 0],
            target: [0, 0, 0, 0],
            visible: [0, 0, 0, 0],
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
        var el: El<State>
        var localRect: MotionRect
        var unscrolledRect: MotionRect
        var targetRect: MotionRect
        var zoomedTargetRect: MotionRect
        var staticRect: [Float]
        var contentSize: Vec2
        var clipRect: MotionRect
        var scrollShift: Vec2
        var effectiveInert: Bool
        var zOrder: Int
        var inheritedScale: Float = 1.0
        var anchorAttachNorm: Vec2? = nil
        var activeClipFades: [EdgeFadeSpec] = []
        var ownScrollFade: EdgeFadeSpec? = nil
        var ownClipFade: EdgeFadeSpec? = nil
        var enclosingScrollIndex: Int? = nil
        var enclosingVScrollIndex: Int? = nil
        var enclosingHScrollIndex: Int? = nil
        var isSticky: Bool { el.stickyConfig?.edge != nil }
    }

    private struct StaticInh {
        var scale: Vec2 = Vec2(1, 1)
        var anchor: SIMD2<Float> = .zero
        var anchorTo: SIMD2<Float> = .zero
        var offset: Vec2 = .zero
    }

    private struct WalkItem {
        var el: El<State>
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
        var parentNewlyMounted: Bool = false
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
        var scaleMotion: PaintScaleMotion = .still
        var stillScale: Float = 1.0
        var parentDrawnWidth: Float? = nil
        var parentTargetWidth: Float? = nil
        var parentMoving: Bool = false
        var rectSpringing: Bool = false
        var clip: MotionRect? = nil
    }

    private enum PaintScaleMotion: Int, Comparable {
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

    internal struct DragSession {
        var path: String
        var key: String?
        var startWindow: Vec2
        var startLocal: Vec2
        var startElementOrigin: Vec2
        var startScale: Vec2
        var elementSize: Vec2
        var clicks: Int
        var button: PointerButton
        var isTextSelectionDrag: Bool
        var movedBeyondSlop: Bool = false
        var stateSnapshotBeforeDrag: State
    }

    private struct EmitStepInput {
        let p: Presented
        let inh: PaintInh
        let ancestorOpacity: Float
        let ancestorTurn: Turn?
        let outerTurnClip: MotionRect?
        let localTurnClip: MotionRect?
        let parentPath: String?
        let nearestGroupHovered: Bool
        let nearestGroupHoverFrac: Float
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

    internal struct ImageAtlasPacker {
        var atlas = RGBA8Atlas(width: 64, height: 64)
        var revision: UInt64 = 1
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
                revision &+= 1
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
            revision &+= 1
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
            if viewport != oldValue && !suppressViewportCommitFlag {
                needsCommit = true
                pendingResizeRelayout = true
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
                stateUnchangedSinceBuild = false
                pendingResizeRelayout = false
            }
        }
    }
    public var systemDark: Bool {
        didSet {
            if systemDark != oldValue {
                needsCommit = true
                stateUnchangedSinceBuild = false
                pendingResizeRelayout = false
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
                stateUnchangedSinceBuild = false
                pendingResizeRelayout = false
            }
        }
    }
    public var srgbBlend: Bool = true
    /// Enables native AppKit material views when backed by a transparent window; headless runs default to `false`.
    public var nativeMaterials: Bool = false
    public var windowFocused: Bool = true {
        didSet {
            if windowFocused != oldValue {
                needsCommit = true
                stateUnchangedSinceBuild = false
                pendingResizeRelayout = false
            }
        }
    }
    public var clearColor: Color = Color(r: 0, g: 0, b: 0, a: 1)

    public let textSystem: TextSystem
    public let waker: Waker
    public private(set) var scene: Scene
    internal var scrollStore: AnimationStore
    internal var liveStore: AnimationStore
    private var pixelSnapGlides = PixelSnap.Glides()

    public internal(set) var currentTime: Double = 0.0
    public private(set) var isAnimating: Bool = false
    public internal(set) var surfaces: [SurfaceDraw] = []
    private var videoSignature: UInt64 = 0
    private var lastVideoSnapshots: [String: VideoSnapshot] = [:]
    public private(set) var viewCommitCount: Int = 0
    public private(set) var viewCallCount: Int = 0
    public private(set) var keyWarnings: [String] = []
    public let perfWatch = PerfWarn.Watch()
    public var interactionTracker: InteractionTracker { perfWatch.interaction }
    internal var frameInstantScrollKey: String? = nil
    internal var frameHadCommitted: Bool = false
    internal var frameHadInputSinceLastFrame: Bool = false
    internal var frameHadLiveWake: Bool = false
    internal var frameHadScrollSinceLastFrame: Bool = false
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
    public internal(set) var nextWakeDeadline: Double? = nil
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
    public internal(set) var playgroundRequests: [PlaygroundTxRequest] = []
    internal var playgroundLiveStorage: AnyObject? = nil
    public var shortcutRegistry: ShortcutRegistry? = nil
    public private(set) var imeReset: Bool = false

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
    private var lastScaledAnimNow: Double = 0.0

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
    public private(set) var liveVisible: Bool = true
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
    public var modifierKeysEnabled: Bool = false
    internal var heldModifierKeys: [ModifierKey] = []
    public var traceChannels: [String: (kind: TraceChannels.Kind, value: Float)]? = nil {
        didSet {
            scene.store.auditRetargets(traceChannels != nil)
        }
    }
    public var traceEvents: [String] = []
    public private(set) var animSources: UInt32 = 0
    public private(set) var imeArea: [Float]? = nil
    internal var currentPhysicalKey: PhysicalKeyCode? = nil
    internal var currentKeyBase: Character? = nil
    internal var currentKeyRepeat: Bool = false

    public var hasPendingInput: Bool {
        !pendingFileDialogAnswers.isEmpty
            || pendingDropMovePoint != nil
            || pendingDropHoverChanged
            || !pendingHiddenDrops.isEmpty
            || !popupQueue.isEmpty
    }

    // Input & focus state
    public internal(set) var pointerPosition: Vec2 = Vec2(-10000, -10000)
    public internal(set) var hoveredPath: String? = nil
    public internal(set) var hoveredKey: String? = nil
    public internal(set) var pressedPath: String? = nil
    public internal(set) var pressedKey: String? = nil
    public internal(set) var focusedPath: String? = nil
    public internal(set) var focusedKey: String? = nil
    public internal(set) var focusVisible: Bool = false
    internal var linkBoxesByPath: [String: [TextLinkBox]] = [:]
    internal var focusedLinkIndex: Int? = nil
    internal var hoveredLink: TextLinkTarget? = nil
    internal var pressedLink: TextLinkTarget? = nil
    private var webFocusTabStartPath: String? = nil
    private var dirChord: DirChord = .idle
    private var lastPinnedGlyphMask: UInt32 = 0
    public private(set) var lastKeyDiagnostics: [DuplicateKeyWarning] = []

    private var lastClickTime: Double = -10.0
    private var lastClickPos: Vec2 = Vec2(-10000, -10000)
    internal var clickCount: Int = 0
    internal var activeDrag: DragSession? = nil
    internal var hasActivePointerDrag: Bool { activeDrag != nil || armedDragOut != nil }

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
    internal var pendingScrollReveals: [ScrollRevealRequest] = []
    internal var pendingScrollBottoms: [(key: String, animated: Bool)] = []
    internal var pendingScrollPages: [(key: String, pages: Int)] = []
    internal var pendingScrollOffsets: [ScrollOffsetRequest] = []
    internal var pendingKeepOnScreenKeys: [String] = []
    internal var scrollRequestsState = ScrollRequestsState()
    internal var scrollGlidingPaths: Set<String> = []
    internal var directScrolledPaths: Set<String> = []
    internal var virtualLists: [String: RuntimeVirtualListState] = [:]
    internal var activeVirtualPaths: Set<String> = []
    internal var virtualFill = VirtualFillStateMachine()
    internal var virtualFillLastScrollOffsets: [String: Vec2] = [:]
    internal struct RuntimeGrowthEntry: Sendable {
        var track: GrowTrack
        var edge: StreamEdge
        var spring: Spring
        var foldLimit: Float
        var lastFirstChildTop: Float? = nil
        var contentSlide: (was: Float, dy: Float)? = nil
    }
    internal var growthRows: [String: RuntimeGrowthEntry] = [:]
    internal var growthSubstepAccumulator: Double = 0
    internal var lastGrowthStepTime: Double? = nil
    internal var atBottomStates: [String: Bool] = [:]
    internal var farFromBottomStates: [String: Bool] = [:]
    internal var lastScrollOffsetReports: [String: ScrollPos] = [:]
    internal var stuckShiftsByPath: [String: Vec2] = [:]
    internal var isDispatchingHover: Bool = false
    internal var suppressRevealFromHoverCommit: Bool = false
    internal var lastVirtualFillWanted: Bool = false
    internal var lastVirtualFillMissing: Int = 0
    internal var lastVirtualFillMoved: Bool = false
    internal var lastFocusSelectedPaths: Set<String> = []
    internal var lastRevealSelectedPaths: Set<String> = []
    internal var loopRuntime = LoopRuntime()
    internal var loopClock = LoopClock()
    internal var selectionState = RuntimeSelectionState()
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
    internal var launchedFlightIds: Set<NodeId> = []
    private var unclippedMatchedFlightIds: Set<NodeId> = []
    private struct PendingFlightRequest {
        var source: String
        var destination: String
        var sourceNodeId: NodeId?
        var sourceRect: MotionRect?
        var sourceTextRect: MotionRect?
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
        var sourceText: String?
        var sourceSpans: [TextSpan]?
        var sourceTextStyle: TextStyle
        var sourceTextColor: Color?
    }
    private var pendingTextFlights: [PendingFlightRequest] = []
    private var pendingLaunches: [PendingFlightRequest] = []
    private var pendingUnclippedFlights: Bool = false
    internal var activeTextFlights: [ActiveTextFlight] = []
    private var lastViewReadScroll: Bool = false
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
    internal var kitHooks = KitRuntimeHooksState()
    internal var modalMemberPaths: Set<String> = []
    internal var activeModalPath: String? = nil
    private var viewHelpLook: HelpLook? = nil
    private var helpState = HelpRuntimeState()
    internal var boundClipboard: Clipboard? = nil
    internal var pendingPasteRequests: Int = 0
    internal var drawnLayoutCache: [UInt64: (drawn: MotionRect, laid: MotionRect)] = [:]
    internal var visibleWatchState: [UInt64: Bool] = [:]
    internal var inheritedHoverCurvesByPath: [String: (enter: Anim<Float>, exit: Anim<Float>)] = [:]
    internal var anchorHoverWithinByKey: [String: (enter: Anim<Float>, exit: Anim<Float>)] = [:]
    internal var unseenPresence = UnseenPresenceState()
    internal var hoverCurvesById: [NodeId: (enter: Anim<Float>, exit: Anim<Float>)] = [:]
    internal var lastHoverTargetById: [NodeId: Float] = [:]
    internal var pressedKeyFocusPath: String? = nil
    internal var lastPixelsSizeByPath: [String: (UInt32, UInt32)] = [:]
    internal var pixelsAspectSnapIds: Set<NodeId> = []
    internal enum HoverHoldState: Equatable {
        case free
        case held
        case released
    }
    internal var hoverHoldState: HoverHoldState = .free

    // Live property tracking `(path, target) -> lastSeenSequence`
    private struct LiveKey: Hashable {
        var path: String
        var target: BoundLiveProperty.Target
    }
    private var liveSeenSeq: [LiveKey: UInt64] = [:]
    private var liveTweenStart: [ObjectIdentifier: Double] = [:]
    private var livePulseRelease: [LiveKey: (releaseAt: Double, rest: MotionLanes, spring: Spring)] = [:]
    private var liveTextSeenSeq: [String: UInt64] = [:]
    internal var liveFillTargets: [NodeId: Color] = [:]

    internal struct VirtualInputEntry {
        var path: String
        var key: String?
        var rowKey: String
        var el: El<State>
    }
    internal var virtualInputs: [String: VirtualInputEntry] = [:]

    internal var flatNodes: [FlatNode] = []
    internal var nodeByPath: [String: Int] = [:]
    internal var nodeById: [NodeId: FlatNode] = [:]
    internal var exitingSnapshots: [NodeId: FlatNode] = [:]
    internal var lastElements: [ElementInfo] = []
    internal var presentedRectByPath: [String: MotionRect] = [:]
    internal var presentedScaleByPath: [String: Vec2] = [:]
    internal var hitGeometryByPath: [String: HitGeometry] = [:]
    internal var paintOrderPaths: [String] = []
    internal var imagePacker = ImageAtlasPacker()
    internal let residentCacheTracker = ResidentLayerTracker()
    internal var retainedLayout = RetainedLayoutCoordinator()
    internal var needsCommit: Bool = true
    internal var virtualFillNeedsCommit: Bool = false
    internal var forceInitialSettle: Bool = true
    private var pendingEventTime: Double? = nil

    // Layout read, feedback circuit breaker, and layout/drawn/visible reporting state
    private enum LayoutQueueKind: Equatable {
        case layout
        case screenLayout
        case drawnLayout
        case visible
    }
    private struct PendingLayoutAction {
        var kind: LayoutQueueKind
        var nodePath: String
        var rect: [Float]
        var visible: Bool
        var external: Bool
    }
    public private(set) var windowOrigin: Vec2 = .zero
    private var pageModeEnabled: Bool = false
    private var pageScrollOffsetY: Float = 0.0
    private var pendingLayoutActions: [PendingLayoutAction] = []
    private var pendingLayoutFeedbackRan: Bool = false
    private var pendingExternalLayoutActionRan: Bool = false
    internal var layoutSeen = LayoutSeenState()
    private var layoutKeyIndex = LayoutKeyIndex()
    private var layoutCommitGen: UInt64 = 0
    private var layoutFeedback = LayoutFeedback.initial
    private var hasExternalDirtyCommit: Bool = true
    private var scrollMovedSinceLastFrame: Bool = false
    private var layoutFired: [NodeId: [Float]] = [:]
    private var screenFired: [NodeId: [Float]] = [:]
    private var drawnFired: [NodeId: (drawn: [Float], laid: [Float])] = [:]
    private var visibleFired: [NodeId: Bool] = [:]
    private var drawnRectByPath: [String: MotionRect] = [:]
    private var rectSpringingById: [NodeId: Bool] = [:]
    private var lastCommittedSpecs: [NodeSpec] = []
    public internal(set) var liveOnlyEvents: UInt64 = 0
    public internal(set) var liveOnlyWarnings: [String] = []
    internal var liveOnlyCheckEnabled: Bool = true
    internal var lastLiveCommitClock: Double = -.infinity
    internal var pendingLiveOnlyCheck: (handler: String, before: LiveOnlyViewPrint)? = nil
    internal var stateUnchangedSinceBuild: Bool = false
    internal var pendingResizeRelayout: Bool = false
    internal var resizeReadMovedFlag: Bool = false
    internal var hasActiveExitingNodes: Bool = false
    internal var cachedResizeBuild: ResizeCachedViewBuild<State>? = nil

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
        self.runtimeId = RuntimeIdScope.nextId()
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

    public func markNeedsCommit(settle: Bool = false, external: Bool = true) {
        needsCommit = true
        if external {
            hasExternalDirtyCommit = true
        }
        pendingEventTime = nil
        if settle {
            forceInitialSettle = true
        }
    }

    /// Whether a layout/view re-evaluation commit is currently pending.
    public var hasPendingCommit: Bool { needsCommit }

    /// Whether any deferred layout/drawn/visible handler callbacks await the next frame.
    public var hasPendingActions: Bool { !pendingLayoutActions.isEmpty }

    /// Host window content origin in global screen points. Reopens layout feedback and queues
    /// `onScreenLayout` without forcing a relayout; returns `true` when any handler queued.
    @discardableResult
    public func setWindowOrigin(_ origin: Vec2) -> Bool {
        guard windowOrigin != origin else { return false }
        windowOrigin = origin
        layoutFeedback.step(.reopened)
        return reportLayoutAndScreen(reportLocal: false, reportScreen: true)
    }

    /// Enables page-level scroll mode and clamps page scroll offset against root content height.
    public func pageMode(_ enabled: Bool = true) {
        pageModeEnabled = enabled
        if !enabled {
            pageScrollOffsetY = 0
        }
    }

    /// Updates page scroll offset in points without triggering a view rebuild.
    public func setPageScroll(_ y: Float, at now: Double? = nil) {
        let contentH = max(flatNodes.first?.contentSize.y ?? 0, flatNodes.first?.targetRect.height ?? 0)
        let maxY = max(0, contentH - viewport.y)
        let clamped = max(0, min(y, maxY))
        guard clamped != pageScrollOffsetY else { return }
        pageScrollOffsetY = clamped
        scrollMovedSinceLastFrame = true
        updateScrollPositions(at: now ?? currentTime)
    }

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
        if let loopWake = nextLoopWakeDeadline(after: now) {
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
    internal func dirtyCommit(at now: Double, external: Bool = true) {
        needsCommit = true
        if external {
            hasExternalDirtyCommit = true
            stateUnchangedSinceBuild = false
            pendingResizeRelayout = false
        }
        pendingEventTime = now
    }

    /// Evaluates view + layout (if dirty), steps `Scene` & `Live` animations at `now`,
    /// updates `elements()`, and emits the complete `RefScene` primitive stream!
    @discardableResult
    public func frame(at now: Double) -> RefScene {
        RuntimeIdScope.$current.withValue(runtimeId) {
            Theme.withBlend(srgbBlend) {
                frameWithBlendScope(at: now)
            }
        }
    }

    private func frameWithBlendScope(at now: Double) -> RefScene {
        let wasQuiet = !frameHadInputSinceLastFrame && !isAnimating
        let dueTimer = nextWakeDeadline.map { now >= $0 } ?? false
        let wasLive = frameHadLiveWake
        frameHadInputSinceLastFrame = false
        frameHadLiveWake = false
        frameHadCommitted = false
        frameInstantScrollKey = nil
        perfWatch.idle.begins(quiet: wasQuiet, timer: dueTimer, live: wasLive)
        if InteractionGate.isOn {
            interactionFrameBegins()
        }

        let (frameOut, animNow) = stepToFrameOutputScaled(at: now)
        let sceneOut = measureFramePhase(.paint) {
            buildRefScene(frameOut: frameOut, now: animNow)
        }
        let wroteDrawn = writeDrawnRects()
        _ = reportLayoutAndScreen(reportLocal: true, reportScreen: true)
        _ = reportDrawn()
        _ = reportVisible()
        let (postFeedback, postExternal) = drainLayoutActions(at: now)
        pendingLayoutFeedbackRan = pendingLayoutFeedbackRan || postFeedback
        pendingExternalLayoutActionRan = pendingExternalLayoutActionRan || postExternal
        isAnimating = isAnimating || ((pixelSnapGlides.isEasing || wroteDrawn) && cxSettings.viewTimeScale > 0.0)
        if pixelSnapGlides.isEasing && cxSettings.viewTimeScale > 0.0 {
            animSources |= AnimSource.scaleSettle
        }
        if !isAnimating {
            animSources = 0
        }
        if layoutFeedback.isOpen && memo.hasInvalidatedReads(against: currentMemoGeometry()) {
            needsCommit = true
            resizeReadMovedFlag = true
        }
        if cxSettings.caretReadByView,
           let nextCaret = currentFocusedCaret(),
           cxSettings.lastCommittedCaret?.keyPath != nextCaret.keyPath || cxSettings.lastCommittedCaret?.rect != nextCaret.rect {
            needsCommit = true
            resizeReadMovedFlag = true
        }
        if rewindRecorder != nil {
            captureRewindFrame(at: now)
        }
        let wasScrolling = frameHadScrollSinceLastFrame || scrollMovedSinceLastFrame || scrollStore.isAnimating
        frameHadScrollSinceLastFrame = false
        perfWatch.meter.frameEnds(scrolling: wasScrolling, committed: frameHadCommitted, instantKey: frameInstantScrollKey)
        if PerfWarn.isEnabled {
            perfWatch.idle.ends(
                clock: now,
                animating: isAnimating,
                drawn: makeIdleDrawnSnapshot(sceneOut),
                windowName: windowTitle
            )
        }
        if InteractionGate.isOn {
            interactionBuilt(sceneOut: sceneOut)
        }
        return sceneOut
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
        var surfaceKey: UInt64 = UInt64(scene.glyphs.texels.count) &* 0x9e37_79b9_7f4a_7c15
        surfaceKey ^= UInt64(imagePacker.revision) &* 0xbf58_476d_1ce4_e5b9
        return IdleMeter.DrawnSnapshot(
            instances: data,
            surfaceKey: surfaceKey,
            opaque: !surfaces.isEmpty || !lastVideoSnapshots.isEmpty
        )
    }

    private func interactionFrameBegins() {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let cpuMs = PerfWarn.threadCpuMs()
        if let finished = perfWatch.interaction.frameBegins(queued: false, nowNs: nowNs, cpuMs: cpuMs) {
            handleInteractionFinished(finished)
        }
    }

    private func interactionBuilt(sceneOut: RefScene) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        let cpuMs = PerfWarn.threadCpuMs()
        if let slowFrame = perfWatch.interaction.built(
            shaped: UInt32(sceneOut.primitives.count),
            nodes: flatNodes.count,
            nowNs: nowNs,
            cpuMs: cpuMs,
            stacks: nil
        ) {
            InteractionTracker.testSlowFrameReports.append(slowFrame)
        }
    }

    public func interactionPresented(
        submittedNs: UInt64 = DispatchTime.now().uptimeNanoseconds,
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
            InteractionTracker.testSlowReports.append(report)
        }
        if let rollup = perfWatch.interaction.takeRollupIfDue(nowNs: f.presentNs, force: false) {
            InteractionTracker.testRollups.append(rollup)
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
    private func prepareAndCommitFrame(at now: Double) -> (animNow: Double, growthMoving: Bool) {
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
        pollPlaygroundIfNeeded(at: now)
        _ = takeParityLivePending()
        applyPlaygroundIfNeeded(at: now)
        flushPendingPasteRequests(at: now)
        let (drainedFeedback, drainedExternal) = drainLayoutActions(at: now)
        let ranLayoutFeedback = pendingLayoutFeedbackRan || drainedFeedback
        let ranExternalLayoutAction = pendingExternalLayoutActionRan || drainedExternal
        pendingLayoutFeedbackRan = false
        pendingExternalLayoutActionRan = false

        if let attempt = virtualFill.wake(at: now) {
            if virtualFill.step(.due(attempt: attempt, now: now)) == .draw {
                needsCommit = true
            }
        }
        stepKitDragRepeatOnFrame(at: now)
        stepKitHoverDelaysOnFrame(at: now)
        let growthMoving = advanceGrowthRows(at: now)

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

        // Check if any async `Pixels` buffer size changed (`aspectRatio == nil`, single auto axis -> snap layout without animation)
        for node in flatNodes {
            guard let px = node.el.pixelsPayload else { continue }
            let l = node.el.layout
            guard l.aspectRatio == nil, (l.width == .auto) != (l.height == .auto) else { continue }
            let sz = px.size
            if let prev = lastPixelsSizeByPath[node.path], prev.0 == sz.width, prev.1 == sz.height {
                continue
            }
            if sz.width > 0 && sz.height > 0 {
                pixelsAspectSnapIds.insert(node.nodeId)
                needsCommit = true
            }
        }

        let didEdgeScroll = stepSelectableEdgeScroll(at: now)
        let isInitiallyScrolling = scrollMovedSinceLastFrame || scrollStore.isAnimating
        if isInitiallyScrolling {
            layoutFeedback.step(.reopened)
        }
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
            commitTree(at: commitAt, cut: shouldCut, resizeSnap: resizeSnap)
            reconcileDropHoverAfterCommit(at: now)
            flushHiddenDropSteps(at: now)
            if didEdgeScroll {
                laidSelectableEdgeScroll(at: now)
            }
            if needsCommit {
                commitTree(at: now, cut: false)
                needsCommit = false
                hasExternalDirtyCommit = false
                popupNeedsLayout = false
            }
        }
        if virtualFillNeedsCommit {
            virtualFillNeedsCommit = false
            needsCommit = true
        }

        // Advance scaled animation clock after any initial commit so `cx.timeScale(...)` takes effect on this frame
        let prevAnimNow = lastScaledAnimNow
        let nextAnimNow = cxSettings.advanceClock(to: now)
        let holdMotion = fitWindowState.frameHolds()
        let animNow = holdMotion ? prevAnimNow : nextAnimNow
        if !holdMotion {
            lastScaledAnimNow = animNow
        }
        syncMotionLoopClock(to: now)

        // Sample inertial scroll decay tracks and re-position scrolled rects without running views
        scrollStore.sample(at: animNow)
        if scrollStore.isAnimating {
            var anyScrollMoved = false
            for (path, maxExt) in scrollMaxExtents {
                let nid = NodeId.hash("scroll:" + path)
                if var cur = scrollStore.get(nid, Props.SCROLL) {
                    if scrollGlidingPaths.contains(path),
                       scrollStore.isMoving(nid, Props.SCROLL),
                       let target = scrollStore.target(nid, Props.SCROLL),
                       let vel = scrollStore.velocity(nid, Props.SCROLL),
                       abs(target.x - cur.x) < 0.1 && abs(vel.x) < 4.0,
                       abs(target.y - cur.y) < 0.1 && abs(vel.y) < 4.0 {
                        // Upstream offset.rs:183 (`LAND = 0.1`, `|v| < 40 * LAND`) lands scroll glides at exact target.
                        cur = target
                        scrollStore.snap(nid, Props.SCROLL, to: target)
                        scrollGlidingPaths.remove(path)
                    }
                    let clamped = Vec2(
                        cur.x.clamped(to: 0...maxExt.x),
                        cur.y.clamped(to: 0...maxExt.y)
                    )
                    if scrollOffsets[path] != clamped {
                        scrollOffsets[path] = clamped
                        if !scrollGlidingPaths.contains(path) {
                            markScrollMovedByHand(path: path)
                        }
                        anyScrollMoved = true
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
                    commitTree(at: now, cut: false)
                } else {
                    updateScrollPositions(at: now)
                }
            }
        } else if !scrollGlidingPaths.isEmpty {
            scrollGlidingPaths.removeAll(keepingCapacity: true)
            if !needsCommit {
                directScrolledPaths.removeAll(keepingCapacity: true)
            }
        } else if !needsCommit && !directScrolledPaths.isEmpty && !scrollStore.isAnimating {
            directScrolledPaths.removeAll(keepingCapacity: true)
        }
        scrollRequestsState.stepFinish(
            gliding: { scrollGlidingPaths.contains($0) },
            animating: { _ in scrollStore.isAnimating },
            mounted: { target in
                flatNodes.contains { selectsElementSelector(target.key, path: $0.path, key: $0.key) }
            }
        )

        let isScrolling = isInitiallyScrolling || scrollMovedSinceLastFrame || scrollStore.isAnimating
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
            commitTree(at: now, cut: false)
        }
        if virtualFillNeedsCommit {
            virtualFillNeedsCommit = false
            needsCommit = true
        }
        scrollMovedSinceLastFrame = false
        return (animNow, growthMoving)
    }

    private func stepToFrameOutputScaled(at now: Double) -> (frameOut: FrameOutput, animNow: Double) {
        let (animNow, growthMoving) = prepareAndCommitFrame(at: now)

        // Sample Scene & Live property bindings using scaled animation clock
        refreshHoverAndSyncTracks(at: animNow, cut: false)
        let frameOut = scene.frame(at: animNow)
        let liveActive = updateLiveBindings(at: animNow)
        liveStore.sample(at: animNow)

        if !activeTextFlights.isEmpty {
            var kept: [ActiveTextFlight] = []
            kept.reserveCapacity(activeTextFlights.count)
            for var entry in activeTextFlights {
                if let p = frameOut.nodes.first(where: { $0.id == entry.targetNodeId && !$0.isExiting }) {
                    let targetExtent = nodeById[p.id].map { laidOutTextExtent(for: $0, rect: p.rect) } ?? p.rect
                    let settled = entry.state.measure(target: targetExtent, now: animNow, reducedMotion: reducedMotion)
                    if !settled {
                        kept.append(entry)
                    }
                }
            }
            activeTextFlights = kept
        }

        let rawAnimating = frameOut.isAnimating
            || scrollStore.isAnimating
            || liveStore.isAnimating
            || liveActive
            || growthMoving
            || growthRows.values.contains { $0.track.moving }
            || virtualFill.isFilling
            || !enterDelays.isEmpty
            || tooltipFading(at: now)
            || hasActiveMotionLoops(at: now)
            || hasActiveSelectableEdgeScroll
            || !activeTextFlights.isEmpty
        var sources: UInt32 = 0
        if frameOut.isAnimating { sources |= AnimSource.tracks }
        if growthMoving || growthRows.values.contains(where: { $0.track.moving }) { sources |= AnimSource.growth }
        if scrollStore.isAnimating { sources |= AnimSource.scroll }
        if !enterDelays.isEmpty { sources |= AnimSource.reveal }
        if liveStore.isAnimating || liveActive { sources |= AnimSource.live }
        if virtualFill.isFilling { sources |= AnimSource.virtualFill }
        if hasActiveMotionLoops(at: now) { sources |= AnimSource.loop }
        if !activeTextFlights.isEmpty { sources |= AnimSource.textFlight }
        if lastVideoSnapshots.values.contains(where: { if case .playing = $0.state { return true }; return false }) {
            sources |= AnimSource.video
        }
        isAnimating = rawAnimating && cxSettings.viewTimeScale > 0.0
        animSources = isAnimating ? sources : 0

        // Prune snapshots of exiting nodes that have finished exiting
        let activeIds = Set(frameOut.nodes.map(\.id))
        hasActiveExitingNodes = frameOut.nodes.contains(where: \.isExiting)
        exitingSnapshots = exitingSnapshots.filter { activeIds.contains($0.key) }
        activeFlightIds = activeFlightIds.filter { activeIds.contains($0) && scene.isEdgeAnimating($0) }
        launchedFlightIds = launchedFlightIds.filter { activeIds.contains($0) && scene.isEdgeAnimating($0) }
        unclippedMatchedFlightIds = unclippedMatchedFlightIds.filter { activeIds.contains($0) && scene.isEdgeAnimating($0) }

        return (frameOut, animNow)
    }

    // MARK: - View Commit, Reconciliation & Layout

    private func currentMemoGeometry(nodes: [FlatNode]? = nil) -> [String: MemoElementGeometry] {
        var caretsByKey: [String: MotionRect] = [:]
        for el in lastElements {
            if let k = el.key, let c = el.caret, c.count >= 4 {
                caretsByKey[k] = MotionRect.fromXYWH(c[0], c[1], c[2], c[3])
            }
        }
        let source = nodes ?? flatNodes
        if nodes != nil,
           let nextCaret = focusedCaretInfo(in: source),
           nextCaret.rect.count >= 4,
           let matchedNode = source.first(where: { $0.path == nextCaret.keyPath }),
           let k = matchedNode.key {
            let c = nextCaret.rect
            caretsByKey[k] = MotionRect.fromXYWH(c[0], c[1], c[2], c[3])
        }
        var out: [String: MemoElementGeometry] = [:]
        out.reserveCapacity(source.count)
        for node in source {
            if let k = node.key {
                out[k] = MemoElementGeometry(
                    rect: node.unscrolledRect,
                    windowRect: node.targetRect,
                    caretRect: caretsByKey[k]
                )
            }
        }
        return out
    }

    private func commitTree(at now: Double, cut: Bool, resizeSnap: Bool = false) {
        let prevResizeSnap = activeResizeSnap
        let prevExplicitSnap = activeExplicitSnap
        activeResizeSnap = resizeSnap
        defer {
            activeResizeSnap = prevResizeSnap
            activeExplicitSnap = prevExplicitSnap
        }
        measureFramePhase(.commit) {
            activeExplicitSnap = pendingCommitKind.snaps
            let explicitSettle = pendingCommitKind == .settle
            let commitKind: TxCommit = resizeSnap
                ? TxCommit(snaps: true, lands: pendingCommitKind.lands)
                : pendingCommitKind
            pendingCommitKind = .animate
            let commitMotion = pendingCommitMotion
            pendingCommitMotion = nil
            let commitColorSpring = pendingColorMotionSpring
            pendingColorMotionSpring = nil
            let commitFollowEdge = pendingFollowEdge
            pendingFollowEdge = false
            let commitCut = cut || explicitSettle

            if commitCut {
                enterDelays.removeAll()
                releasedEnterDelays.removeAll()
                activeFlightIds.removeAll()
                launchedFlightIds.removeAll()
                unclippedMatchedFlightIds.removeAll()
            }
            let sincePass = memo.nextPass()
            let liveCheck = pendingLiveOnlyCheck
            pendingLiveOnlyCheck = nil
            var didRunView = false
            MemoSnapshot.enter {
                commitTreePass(
                    at: now,
                    cut: cut,
                    settlePass: 0,
                    commitKind: commitKind,
                    commitMotion: commitMotion,
                    commitColorSpring: commitColorSpring,
                    commitFollowEdge: commitFollowEdge,
                    commitCut: commitCut,
                    didRunView: &didRunView
                )
            }
            if didRunView {
                memo.keepSince(sincePass)
            }
            lastLiveCommitClock = now
            compareLiveOnlyCheck(liveCheck)
            commitCount &+= 1
            frameHadCommitted = true
            if InteractionGate.isOn {
                perfWatch.interaction.committed(why: 1)
            }
        }
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

    private func hasScrollCallbacks() -> Bool {
        flatNodes.contains {
            $0.el.handlers.onAtBottom != nil
                || $0.el.handlers.onFarFromBottom != nil
        }
    }

    private var scrollRequiresCommit: Bool {
        !activeVirtualPaths.isEmpty || lastViewReadScroll || hasScrollCallbacks()
    }

    internal final class MeasurePassResult {
        var viewRootEl: El<State>
        var expandedRootEl: El<State>
        var nodes: [FlatNode]
        var byPath: [String: Int]
        var byId: [NodeId: FlatNode]
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

        init(
            viewRootEl: El<State>,
            expandedRootEl: El<State>,
            nodes: [FlatNode],
            byPath: [String: Int],
            byId: [NodeId: FlatNode],
            specs: [NodeSpec],
            loopSpecs: [(id: NodeId, spec: LoopSpec)],
            ancestorInstants: [Bool],
            warnings: [String],
            reads: [LayoutReadEntry],
            virtualExpansion: VirtualExpansionContext,
            rootBackground: Color?,
            rootHeight: Float,
            helpLook: HelpLook?,
            viewportRead: Bool = false
        ) {
            self.viewRootEl = viewRootEl
            self.expandedRootEl = expandedRootEl
            self.nodes = nodes
            self.byPath = byPath
            self.byId = byId
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
        }
    }

    @inline(__always)
    private static func rotatedBoundsArray(_ rect: MotionRect, turn: Float) -> [Float] {
        guard abs(turn) >= 1e-6 else {
            return [rect.left, rect.top, rect.width, rect.height]
        }
        let rad = turn * 2.0 * Float.pi
        let c = cosf(rad)
        let s = sinf(rad)
        let cx = rect.left + rect.width * 0.5
        let cy = rect.top + rect.height * 0.5
        let hw = rect.width * 0.5
        let hh = rect.height * 0.5
        let rx = abs(hw * c) + abs(hh * s)
        let ry = abs(hw * s) + abs(hh * c)
        return [cx - rx, cy - ry, rx * 2.0, ry * 2.0]
    }

    @inline(__always)
    private static func computeStaticTransform(
        baseRect: MotionRect,
        el: El<State>,
        inh: StaticInh
    ) -> (bounds: [Float], childInh: StaticInh) {
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
        return (rotatedBoundsArray(scaledRect, turn: el.rotate), childInh)
    }

    @inline(never)
    private func runViewPass(
        at now: Double,
        focusedCaret: (keyPath: String, rect: [Float])?,
        allowZoomSettle: Bool,
        memoNodes: [FlatNode]?,
        collector: LayoutReadCollector
    ) -> (rootEl: El<State>, helpLook: HelpLook?)? {
        viewCallCount += 1
        lastViewReadScroll = false
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
                self.lastViewReadScroll = true
                if let match = self.flatNodes.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) }) {
                    return self.scrollOffsets[match.path] ?? .zero
                }
                return .zero
            },
            scrollMaxLookup: { [weak self] key in
                guard let self else { return .zero }
                self.lastViewReadScroll = true
                if let match = self.flatNodes.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) }) {
                    return self.scrollMaxExtents[match.path] ?? .zero
                }
                return .zero
            },
            viewportSizeLookup: { [weak self] key in
                guard let self else { return .zero }
                self.lastViewReadScroll = true
                if let match = self.flatNodes.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) }) {
                    return self.scrollViewportSizes[match.path] ?? Vec2(match.targetRect.width, match.targetRect.height)
                }
                return .zero
            },
            contentSizeLookup: { [weak self] key in
                guard let self else { return .zero }
                self.lastViewReadScroll = true
                if let match = self.flatNodes.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) }) {
                    return self.scrollContentSizes[match.path] ?? match.contentSize
                }
                return .zero
            },
            layoutRectLookup: { [weak self] key in
                guard let self else { return nil }
                return self.flatNodes.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) })?.targetRect
            },
            layoutCollector: collector
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
            chromeInsets: [cx.envState.chrome.leading, cx.envState.chrome.trailing, cx.envState.chrome.top, cxSettings.scrollBarsState.bars.hashValue.signum() == 0 ? 0 : Float(cxSettings.scrollBarsState.isOverlay ? 1 : 2)],
            scrollerOverlay: cxSettings.scrollBarsState.isOverlay
        )
        let rootEl = SystemScrollBarsScope.$current.withValue(cxSettings.scrollBarsState) {
            MemoScope.enter(
                cache: memo,
                envHash: envHash,
                geometry: currentMemoGeometry(nodes: memoNodes)
            ) {
                measureFramePhase(.view) {
                    buildPlaygroundViewIfAttached(cx: &cx)
                }
            }
        }
        cxSettings.viewDefaults = cx.envState.defaults
        let passHelpLook = cx.helpLook ?? cx.envState.defaults.help
        cxSettings.captionColor = cx.envState.captionColor
        cxSettings.titlebarOverride = cx.envState.titlebar
        cxSettings.caretReadByView = cx.envState.reads.caretRead
        let effReducedMotion = cx.envState.reducedMotionOverride ?? cxSettings.hostReducedMotion
        if effReducedMotion != self.reducedMotion {
            isApplyingEffectiveReducedMotion = true
            self.reducedMotion = effReducedMotion
            isApplyingEffectiveReducedMotion = false
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
            if allowZoomSettle {
                return nil
            }
        }
        return (rootEl, passHelpLook)
    }

    private func measurePass(
        at now: Double,
        cut: Bool,
        commitKind: TxCommit,
        commitMotion: MotionSource?,
        commitColorSpring: Spring?,
        commitCut: Bool,
        prevMountedIds: Set<NodeId>,
        focusedCaret: (keyPath: String, rect: [Float])?,
        allowZoomSettle: Bool,
        memoNodes: [FlatNode]? = nil
    ) -> MeasurePassResult? {
        let collector = LayoutReadCollector(rects: layoutSeen.rects)
        guard let viewPass = runViewPass(
            at: now,
            focusedCaret: focusedCaret,
            allowZoomSettle: allowZoomSettle,
            memoNodes: memoNodes,
            collector: collector
        ) else {
            return nil
        }
        let result = buildMeasureResult(
            rootEl: viewPass.rootEl,
            passHelpLook: viewPass.helpLook,
            collector: collector,
            at: now,
            cut: cut,
            commitKind: commitKind,
            commitMotion: commitMotion,
            commitColorSpring: commitColorSpring,
            commitCut: commitCut,
            prevMountedIds: prevMountedIds
        )
        result.viewRootEl = viewPass.rootEl
        return result
    }

    @inline(never)
    internal func buildMeasureResult(
        rootEl: El<State>,
        expandedContextOverride: VirtualExpansionContext? = nil,
        passHelpLook: HelpLook?,
        collector: LayoutReadCollector,
        at now: Double,
        cut: Bool,
        commitKind: TxCommit,
        commitMotion: MotionSource?,
        commitColorSpring: Spring?,
        commitCut: Bool,
        prevMountedIds: Set<NodeId>
    ) -> MeasurePassResult {
        let rootBg: Color? = rootEl.background.a >= 0.999 ? rootEl.background : nil

        let (expandedRoot, virtualExpansion): (El<State>, VirtualExpansionContext)
        if let override = expandedContextOverride {
            (expandedRoot, virtualExpansion) = (rootEl, override)
        } else {
            (expandedRoot, virtualExpansion) = expandVirtualSubtrees(in: rootEl)
        }
        var layoutRoot = expandedRoot
        var solvedRoot = measureFramePhase(.layout) {
            retainedLayout.compute(
                root: layoutRoot,
                state: state,
                viewport: viewport,
                pixelScale: pixelScale,
                textSystem: textSystem,
                fitHeight: fitHeight
            )
        }
        let growthCapture = updateGrowthRowsPostLayout(
            rootResult: solvedRoot,
            rootEl: layoutRoot,
            cut: cut,
            snaps: commitKind.snaps,
            lands: commitKind.lands,
            at: now
        )
        if growthCapture.needsClampedRelayout {
            layoutRoot = applyGrowthConstraints(in: layoutRoot)
            solvedRoot = measureFramePhase(.layout) {
                retainedLayout.compute(
                    root: layoutRoot,
                    state: state,
                    viewport: viewport,
                    pixelScale: pixelScale,
                    textSystem: textSystem
                )
            }
        }

        // Flatten tree, assign unique structural/keyed paths, clamp scroll offsets, and collect NodeSpecs
        lastKeyDiagnostics = KeyDiagnostics.find(in: layoutRoot)
        inheritedHoverCurvesByPath.removeAll(keepingCapacity: true)
        var newFlat: [FlatNode] = []
        var newByPath: [String: Int] = [:]
        var newById: [NodeId: FlatNode] = [:]
        var specs: [NodeSpec] = []
        var loopSpecs: [(id: NodeId, spec: LoopSpec)] = []
        var ancestorInstants: [Bool] = []
        var warnings: [String] = []
        let fullWindowClip = MotionRect.fromXYWH(0, 0, viewport.x, viewport.y)

        let rootResolvedKey: String? = layoutRoot.keyId
        let rootPath: String = rootResolvedKey.map { "/@\($0)" } ?? "/0"
        var walkStack: [WalkItem] = [
            WalkItem(
                el: layoutRoot,
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
                staticInh: StaticInh()
            )
        ]

        while let item = walkStack.popLast() {
            let el = item.el
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

            let nid: NodeId
            if el.layoutAnim?.travel == .screen, let rk = resolvedKey {
                nid = NodeId.hash("screen:@" + rk)
            } else {
                nid = NodeId.hash(path)
            }

            let localRect = solved.layout.localRect
            let unscrolledX = parentUnscrolledOrigin.x + localRect.x
            let unscrolledY = parentUnscrolledOrigin.y + localRect.y
            let unscrolledRect = MotionRect.fromXYWH(unscrolledX, unscrolledY, localRect.width, localRect.height)

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
            // Sticky push-out is evaluated at paint time in `buildRefScene` using presented rects.
            if parentIdx == nil && pageModeEnabled {
                worldY -= pageScrollOffsetY
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

                if el.scrollEdgeFadeWidth > 0 || el.scrollFadeStyle.end != nil {
                    let dummyNode = FlatNode(
                        index: 0,
                        parentIndex: parentIdx,
                        path: path,
                        key: resolvedKey,
                        nodeId: nid,
                        el: el,
                        localRect: localRect,
                        unscrolledRect: unscrolledRect,
                        targetRect: targetRect,
                        zoomedTargetRect: zoomedTargetRect,
                        staticRect: [targetRect.x, targetRect.y, targetRect.width, targetRect.height],
                        contentSize: solved.layout.contentSize,
                        clipRect: inheritedClip,
                        scrollShift: curScroll,
                        effectiveInert: false,
                        zOrder: 0
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
                    strengths: SIMD4<Float>(repeating: 1.0)
                )
            }
            var childClipFades = inheritedClipFades
            if let sf = scrollFadeInfo {
                childClipFades.append(sf)
            }
            if let cfSpec = ownClipFadeSpec {
                childClipFades.append(cfSpec)
            }

            let myIndex = newFlat.count
            let flat = FlatNode(
                index: myIndex,
                parentIndex: parentIdx,
                path: path,
                key: resolvedKey,
                nodeId: nid,
                el: el,
                localRect: localRect,
                unscrolledRect: unscrolledRect,
                targetRect: targetRect,
                zoomedTargetRect: zoomedTargetRect,
                staticRect: staticBounds,
                contentSize: solved.layout.contentSize,
                clipRect: inheritedClip,
                scrollShift: ownScroll,
                effectiveInert: effectiveInert,
                zOrder: ownZ,
                inheritedScale: nodeInheritedScale,
                anchorAttachNorm: anchorAttachNorm,
                activeClipFades: inheritedClipFades,
                ownScrollFade: scrollFadeInfo,
                ownClipFade: ownClipFadeSpec,
                enclosingScrollIndex: item.enclosingScrollIndex,
                enclosingVScrollIndex: item.enclosingVScrollIndex,
                enclosingHScrollIndex: item.enclosingHScrollIndex
            )
            newFlat.append(flat)
            newByPath[path] = myIndex
            newById[nid] = flat

            // Compute interactive press / pressScale adjustments on target spec
            let isPressed = (pressedPath == path) && !effectiveInert

            var effectiveFill = el.background
            if isPressed, let pBg = el.pressBg {
                effectiveFill = blendColorOver(bottom: effectiveFill, top: pBg, srgb: srgbBlend)
            }

            var effectiveScale = Vec2(el.scale.x * anchorScaleFactor, el.scale.y * anchorScaleFactor)
            if isPressed, let ps = el.pressScaleFactor {
                effectiveScale = Vec2(effectiveScale.x * ps, effectiveScale.y * ps)
            }

            let ancestorInstant = inInstantSubtree && !el.hasAnimatedChanges
            let childInstant = ancestorInstant || el.hasInstantChanges
            let selfInstantLayoutOrStyle = childInstant || commitKind.snaps || commitCut || reducedMotion

            let parentNid = parentIdx.map { newFlat[$0].nodeId }
            // Provide a subtle default interactive spring when pressScale / press is used
            var styleSp: Spring?
            if selfInstantLayoutOrStyle {
                styleSp = el.pressBg != nil && !commitKind.snaps && !commitCut && !reducedMotion
                    ? MotionTokens.INSTANT
                    : nil
            } else {
                styleSp = el.styleSpring
                    ?? commitColorSpring
                    ?? commitMotion?.spring
                    ?? ((el.pressScaleFactor != nil || el.pressBg != nil) ? MotionTokens.INSTANT : nil)
            }
            let keepsFlights = !activeResizeSnap && commitKind.snaps && !commitKind.lands && viewCommitCount > 1 && !cut && !reducedMotion
            func isRunningSameSceneFrame() -> Bool {
                guard self.scene.hasNode(nid),
                      self.scene.store.isAnimating(nid, Props.FRAME),
                      let curTarget = self.scene.store.target(nid, Props.FRAME) else {
                    return false
                }
                let parentOriginRect = parentNid.flatMap { newById[$0]?.targetRect }
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
            var layoutAnimSpec: LayoutAnim?
            let isStackContainer = (el.growthSpec != nil) || (el.virtualEstimate != nil)
            let (selfInRow, childInRow) = ParityLayoutAnimation.resolveRowLayout(
                parentInRow: item.rowLayout,
                hasAbove: el.anchor != nil,
                hasAnimateLayout: el.layoutAnim != nil,
                isStackContainer: isStackContainer
            )
            if commitCut || reducedMotion || pixelsAspectSnapIds.remove(nid) != nil {
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
            } else {
                layoutAnimSpec = el.layoutAnim
            }
            if !selfInstantLayoutOrStyle, layoutAnimSpec == nil, let cm = commitMotion {
                layoutAnimSpec = LayoutAnim(x: cm.anim, y: cm.anim)
            }
            let rowGrowthKey = el.foldGlideSpec != nil ? "fold:\(path)" : "growth:\(path)"
            let hasGrowthSlide = growthRows[rowGrowthKey]?.contentSlide != nil
            let isRunningFlight = !hasGrowthSlide && (activeFlightIds.contains(nid) || launchedFlightIds.contains(nid))
            if layoutAnimSpec == nil && !commitCut && !reducedMotion && !commitKind.lands && isRunningFlight {
                layoutAnimSpec = LayoutAnim(spring: el.flightSpring ?? MotionTokens.SETTLE, travel: .screen)
            }
            var specTransition = (ancestorInstant || reducedMotion) ? nil : el.transition
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
            ancestorInstants.append(ancestorInstant)

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

            let growthSlideY: Float = {
                let gKey = el.foldGlideSpec != nil ? "fold:\(path)" : "growth:\(path)"
                guard let gEntry = growthRows[gKey],
                      gEntry.track.moving,
                      let slide = gEntry.contentSlide,
                      abs(slide.was) > 0.01 else {
                    return 0
                }
                let left = gEntry.track.target - gEntry.track.h
                guard left * slide.was > 0 else { return 0 }
                return slide.dy * min(1, max(0, left / slide.was))
            }()

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
                    parentOrigin: Vec2(worldX, worldY + growthSlideY),
                    parentUnscrolledOrigin: Vec2(unscrolledX, unscrolledY + growthSlideY),
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
                    parentNewlyMounted: isFreshMount
                ))
            }
            walkStack.append(contentsOf: childItems.reversed())
        }

        LayoutDiagnostics.checkCollapsedScrolls(nodes: newFlat)

        return MeasurePassResult(
            viewRootEl: rootEl,
            expandedRootEl: layoutRoot,
            nodes: newFlat,
            byPath: newByPath,
            byId: newById,
            specs: specs,
            loopSpecs: loopSpecs,
            ancestorInstants: ancestorInstants,
            warnings: warnings,
            reads: collector.reads,
            virtualExpansion: virtualExpansion,
            rootBackground: rootBg,
            rootHeight: solvedRoot.layout.localRect.height,
            helpLook: passHelpLook,
            viewportRead: collector.viewportRead
        )
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
            return LayoutReadConstants.rectArray(r)
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
        let content = el.liveText?.get() ?? el.plainText ?? el.richSpans?.map(\.text).joined() ?? ""
        guard !content.isEmpty else { return [] }
        let padL = el.layout.padding.left * scale.x
        let padT = el.layout.padding.top * scale.y
        let padR = el.layout.padding.right * scale.x
        let innerW = max(0, boxRect.width - padL - padR)
        let wrapWidth = (innerW / max(1e-4, scale.x)) + 0.5
        let shaped = textSystem.shape(
            text: content,
            spans: el.richSpans,
            style: el.textStyle,
            maxWidth: wrapWidth,
            pixelScale: pixelScale,
            emitGlyphs: false
        )
        let ox = boxRect.x + padL
        let oy = boxRect.y + padT
        let utf8Len = content.utf8.count
        var out: [(Int, MotionRect)] = []
        for (k, hl) in hls.enumerated() {
            let a = max(0, min(hl.byteRange.lowerBound, utf8Len))
            let b = max(a, min(hl.byteRange.upperBound, utf8Len))
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

    internal func highlightTargetWithNode(
        selector: String,
        scrolled: Bool = true
    ) -> (nodeIndex: Int, rect: MotionRect)? {
        let candidates = LayoutKeyIndex.markedCandidates(selector: selector, index: layoutKeyIndex.indexIfValid(stamp: layoutCommitGen), nodes: flatNodes)
            ?? Array(flatNodes.indices)
        var union: MotionRect? = nil
        var ownerIdx: Int? = nil
        for i in candidates {
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
            if ownerIdx == nil { ownerIdx = i }
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
            keyOf: { $0.key },
            highlightKeysOf: { $0.el.textHighlights?.compactMap(\.key) ?? [] }
        )
        let idx = layoutKeyIndex.indexIfValid(stamp: layoutCommitGen)
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
            keyOf: { $0.key },
            highlightKeysOf: { $0.el.textHighlights?.compactMap(\.key) ?? [] }
        )
        let idx = layoutKeyIndex.indexIfValid(stamp: layoutCommitGen)
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
    ) {
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
        let prevMountedIds = Set(nodeById.keys)

        let plannedKind: ResizeCommitKind = (settlePass == 0)
            ? nextCommitKind()
            : .rebuild

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
            resizeReadMovedFlag = false
            applyMeasurePass(
                relayoutPass,
                at: now,
                cut: cut,
                settlePass: settlePass,
                commitKind: commitKind,
                commitMotion: commitMotion,
                commitColorSpring: commitColorSpring,
                commitFollowEdge: commitFollowEdge,
                commitCut: commitCut,
                prevMountedIds: prevMountedIds,
                didRunView: &didRunView
            )
            return
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
            allowZoomSettle: settlePass == 0
        ) else {
            commitTreePass(
                at: now,
                cut: cut,
                settlePass: 1,
                commitKind: commitKind,
                commitMotion: commitMotion,
                commitColorSpring: commitColorSpring,
                commitFollowEdge: commitFollowEdge,
                commitCut: commitCut,
                didRunView: &didRunView
            )
            return
        }
        var retryCaret = focusedCaret
        let initialCaretMoved = cxSettings.caretReadByView && caretMoved(from: retryCaret, in: pass.nodes)
        if (!pass.reads.isEmpty && evaluateLayoutMoved(reads: pass.reads, nodes: pass.nodes, force: false)) || initialCaretMoved {
            for extra in 0..<LayoutReadConstants.passes {
                if cxSettings.caretReadByView, let nextC = focusedCaretInfo(in: pass.nodes) {
                    retryCaret = nextC
                    cxSettings.lastCommittedCaret = nextC
                }
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
                    memoNodes: pass.nodes
                ) {
                    pass = nextPass
                }
                let isLast = (extra + 1 == LayoutReadConstants.passes)
                let readsStillMoved = !pass.reads.isEmpty && evaluateLayoutMoved(reads: pass.reads, nodes: pass.nodes, force: isLast)
                let caretStillMoved = cxSettings.caretReadByView && caretMoved(from: retryCaret, in: pass.nodes)
                if !readsStillMoved && !caretStillMoved {
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
        stateUnchangedSinceBuild = true
        pendingResizeRelayout = false
        resizeReadMovedFlag = false

        applyMeasurePass(
            pass,
            at: now,
            cut: cut,
            settlePass: settlePass,
            commitKind: commitKind,
            commitMotion: commitMotion,
            commitColorSpring: commitColorSpring,
            commitFollowEdge: commitFollowEdge,
            commitCut: commitCut,
            prevMountedIds: prevMountedIds,
            didRunView: &didRunView
        )
    }

    @inline(never)
    private func applyMeasurePass(
        _ pass: MeasurePassResult,
        at now: Double,
        cut: Bool,
        settlePass: Int,
        commitKind: TxCommit,
        commitMotion: MotionSource?,
        commitColorSpring: Spring?,
        commitFollowEdge: Bool,
        commitCut: Bool,
        prevMountedIds: Set<NodeId>,
        didRunView: inout Bool
    ) {
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
        if let bg = pass.rootBackground {
            clearColor = bg
        }

        let prevFocusedPath = focusedPath
        let prevFocusedKey = focusedKey
        let prevFocusVisible = focusVisible

        // Apply modal inertness: if any mounted subtree is `.modal(...)`, elements outside the topmost modal
        // (and its anchored portal popovers) become inert!
        var newModalMembers: Set<String> = []
        var newActiveModalPath: String? = nil
        if let modalRootIdx = pass.nodes.indices.last(where: { pass.nodes[$0].el.isModal }) {
            let modalPrefix = pass.nodes[modalRootIdx].path
            newActiveModalPath = modalPrefix
            var memberIndices = Set<Int>()
            for i in modalRootIdx..<pass.nodes.count {
                let p = pass.nodes[i].path
                if p == modalPrefix || p.hasPrefix(modalPrefix + "/") {
                    memberIndices.insert(i)
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
            }
            for i in 0..<pass.nodes.count where !memberIndices.contains(i) {
                pass.nodes[i].effectiveInert = true
                pass.byId[pass.nodes[i].nodeId] = pass.nodes[i]
            }
        }
        modalMemberPaths = newModalMembers
        activeModalPath = newActiveModalPath

        var specs = pass.specs
        for i in pass.nodes.indices {
            let node = pass.nodes[i]
            let el = node.el
            let nid = node.nodeId
            let ancestorInstant = i < pass.ancestorInstants.count ? pass.ancestorInstants[i] : false
            let isFreshMount = !prevMountedIds.contains(nid)
            if el.enterDelay > 0 && viewCommitCount > 1 && !cut && !ancestorInstant && isFreshMount && !releasedEnterDelays.contains(nid) && enterDelays[nid] == nil {
                enterDelays[nid] = now + Double(el.enterDelay)
            }
            if let readyAt = enterDelays[nid], now < readyAt {
                let eff = el.transition?.insertion ?? Transition.opacity.insertion
                specs[i].opacity = eff.zeroOpacity ?? 0
                specs[i].scale = Vec2(specs[i].scale.x * eff.zeroScale.x, specs[i].scale.y * eff.zeroScale.y)
                let dx = eff.pointOffset.x + eff.relativeOffset.x * node.targetRect.width
                let dy = eff.pointOffset.y + eff.relativeOffset.y * node.targetRect.height
                specs[i].rect = node.targetRect.offsetBy(Vec2(dx, dy))
                specs[i].blur = max(specs[i].blur, eff.zeroBlur)
                specs[i].transition = nil
                specs[i].layoutAnim = nil
                specs[i].styleSpring = nil
            } else if releasedEnterDelays.remove(nid) != nil {
                let enterSp = el.transition?.insertion.spring ?? el.styleSpring ?? MotionTokens.SETTLE
                specs[i].styleSpring = enterSp
                specs[i].layoutAnim = el.layoutAnim ?? LayoutAnim(spring: enterSp)
            }
        }

        let childExitOverrides = collectChildExitOverrides(prevNodes: flatNodes, newById: pass.byId, cut: cut)
        syncMotionLoops(specs: pass.loopSpecs, at: now, cut: commitCut)

        for node in pass.nodes {
            exitingSnapshots[node.nodeId] = node
            if let lt = node.el.liveText {
                liveTextSeenSeq[node.path] = lt.sequence
            }
            for b in node.el.liveBindings {
                b.source.subscribe(waker)
            }
        }
        refreshParityLiveSubscriptions()

        let prevFlatNodesSnapshot = flatNodes
        flatNodes = pass.nodes
        nodeByPath = pass.byPath
        nodeById = pass.byId
        lastCommittedSpecs = specs
        layoutCommitGen &+= 1
        layoutKeyIndex.invalidate()
        if !pass.warnings.isEmpty {
            keyWarnings = pass.warnings
        }

        if settlePass == 0 && memo.hasInvalidatedReads(against: currentMemoGeometry()) {
            commitTreePass(
                at: now,
                cut: cut,
                settlePass: 1,
                commitKind: commitKind,
                commitMotion: commitMotion,
                commitColorSpring: commitColorSpring,
                commitFollowEdge: commitFollowEdge,
                commitCut: commitCut,
                didRunView: &didRunView
            )
            return
        }

        virtualInputs = pass.virtualExpansion.virtualInputs

        // Reconcile focus: keep focused key/path if still focusable & non-inert; sync TextEdit.focused; handle modal/focusReturn & autofocus.
        reconcileFocusAfterCommit(
            prevFocusedPath: prevFocusedPath,
            prevFocusedKey: prevFocusedKey,
            prevFocusVisible: prevFocusVisible
        )
        if let prevPath = prevFocusedPath, prevPath != focusedPath {
            let prevNode = prevFlatNodesSnapshot.first(where: { $0.path == prevPath })
            handleKitFocusTransition(prevNode: prevNode, newPath: focusedPath, at: now)
        }
        settleKitHoverDelays(at: pointerPosition, now: now)
        reconcilePlaygroundAfterCommit(at: now)

        lastPixelsSizeByPath.removeAll(keepingCapacity: true)
        for node in pass.nodes {
            if let px = node.el.pixelsPayload {
                let sz = px.size
                lastPixelsSizeByPath[node.path] = (sz.width, sz.height)
            }
        }
        rebuildHoverCurves(for: pass.nodes)
        if cut || viewCommitCount == 1 {
            hoverHoldState = .free
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
        for node in pass.nodes {
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
            if !cut, isFreshOrExiting(nid),
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
                    let startRect = MotionRect.fromXYWH(
                        srcTextOriginRect.x - firstTextOff.x,
                        srcTextOriginRect.y - firstTextOff.y,
                        dstNode.targetRect.width,
                        dstNode.targetRect.height
                    )
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
                    guard let srcRect = req.sourceTextRect ?? req.sourceRect else { continue }
                    guard let dstNode = findNodeForFlightSelector(req.destination, in: pass.nodes) else {
                        if req.remainingAttempts > 1 {
                            req.remainingAttempts -= 1
                            deferredFlights.append(req)
                        }
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
        applyChildExitHooks(childExitOverrides, matchedStarts: matchedStarts, to: &scene)
        syncRideTrailingFlags(pass.nodes, on: &scene)
        measureFramePhase(.apply) {
            scene.commit(
                specs,
                at: cxSettings.scaledTime(at: now),
                initialCut: commitCut,
                snapMounts: commitKind.snaps,
                snapOmittedNonExiting: activeExplicitSnap,
                matchedStarts: matchedStarts
            )
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
        scene.keepFlights(false)
        if applyUnseenPresenceAfterCommit(specs: specs, cut: commitCut, to: &scene) {
            isAnimating = true
        }
        recordVirtualMeasurementsAndCallbacks(expansion: pass.virtualExpansion, at: now)
        stepVirtualFillAfterCommit(now: now)
        if pass.virtualExpansion.anyVirtualList && !changedScrollDeltas.isEmpty && anyVirtualListNeedsWindow() {
            needsCommit = true
        }
        syncRideTrailingFlags(pass.nodes, on: &scene)
        finalizeSelectionAfterCommit(at: now)
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
        lastCommitMotionSpring = nil
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
        let srcLastEl = lastElements.first(where: { !$0.exiting && FlightSelector.selects(source, path: $0.path, key: $0.key) })
        let srcRect = srcNode.map { scene.currentRect($0.nodeId) ?? $0.targetRect }
            ?? srcLastEl.flatMap {
                $0.rect.count >= 4 ? MotionRect.fromXYWH($0.rect[0], $0.rect[1], $0.rect[2], $0.rect[3]) : nil
            }
        let srcTextRect: MotionRect? = {
            if let srcNode, let srcRect {
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
        if el.focusable { return true }
        let pressableRoles: Set<ElementRole> = [
            .button, .tab, .checkbox, .switchControl, .radio, .menuItem, .listItem,
        ]
        return cxSettings.viewDefaults.webFocus &&
            !el.focusOptOut &&
            (el.handlers.onClick != nil || el.handlers.onClickPress != nil || el.handlers.onPointerDown != nil) &&
            pressableRoles.contains(el.role)
    }

    private func updateScrollPositions(at now: Double) {
        guard !flatNodes.isEmpty else { return }
        let fullWindowClip = MotionRect.fromXYWH(0, 0, viewport.x, viewport.y)
        var childClips = [MotionRect](repeating: fullWindowClip, count: flatNodes.count)
        var staticInhs = [StaticInh](repeating: StaticInh(), count: flatNodes.count)
        var childClipFades = [[EdgeFadeSpec]](repeating: [], count: flatNodes.count)

        for i in flatNodes.indices {
            let parentIdx = flatNodes[i].parentIndex
            let parentOrigin: Vec2
            let parentScroll: Vec2
            let inheritedClip: MotionRect
            let inheritedStaticInh: StaticInh
            let inheritedClipFades: [EdgeFadeSpec]
            if let p = parentIdx {
                parentOrigin = flatNodes[p].targetRect.origin
                parentScroll = flatNodes[p].scrollShift
                inheritedClip = childClips[p]
                inheritedStaticInh = staticInhs[p]
                inheritedClipFades = childClipFades[p]
            } else {
                parentOrigin = .zero
                parentScroll = .zero
                inheritedClip = fullWindowClip
                inheritedStaticInh = StaticInh()
                inheritedClipFades = []
            }

            let lr = flatNodes[i].localRect
            let worldX = parentOrigin.x + lr.x - parentScroll.x
            var worldY = parentOrigin.y + lr.y - parentScroll.y
            if parentIdx == nil && pageModeEnabled {
                worldY -= pageScrollOffsetY
            }
            let newTarget = MotionRect.fromXYWH(worldX, worldY, lr.width, lr.height)
            flatNodes[i].targetRect = newTarget
            flatNodes[i].clipRect = inheritedClip
            flatNodes[i].activeClipFades = inheritedClipFades
            var scrollFadeInfo: EdgeFadeSpec? = nil
            if !flatNodes[i].el.layout.scrollAxes.isEmpty {
                let maxExt = scrollMaxExtents[flatNodes[i].path] ?? .zero
                let rawScroll = scrollOffsets[flatNodes[i].path] ?? .zero
                let clamped = Vec2(
                    rawScroll.x.clamped(to: 0...maxExt.x),
                    rawScroll.y.clamped(to: 0...maxExt.y)
                )
                scrollOffsets[flatNodes[i].path] = clamped
                flatNodes[i].scrollShift = clamped
                dispatchScrollOffsetObserverIfChanged(for: flatNodes[i], at: now)
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
                        strengths: SIMD4<Float>(repeating: 1.0)
                    )
                )
            }
            childClipFades[i] = nodeChildFades
            let el = flatNodes[i].el
            childClips[i] = (el.layout.clipOverflow || el.clipRadius != nil || el.clipCorners != nil || el.clipFade != nil)
                ? intersectRects(inheritedClip, newTarget)
                : inheritedClip
            let (sb, cInh) = Self.computeStaticTransform(
                baseRect: flatNodes[i].unscrolledRect,
                el: flatNodes[i].el,
                inh: inheritedStaticInh
            )
            flatNodes[i].staticRect = sb
            staticInhs[i] = cInh
            let nid = flatNodes[i].nodeId
            nodeById[nid] = flatNodes[i]
            exitingSnapshots[nid] = flatNodes[i]
            if i < lastCommittedSpecs.count {
                lastCommittedSpecs[i].rect = newTarget
            }
        }
        scene.commit(lastCommittedSpecs, at: now, initialCut: false)
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

    private func enqueueLayoutAction(_ action: PendingLayoutAction) {
        pendingLayoutActions.removeAll { $0.kind == action.kind && $0.nodePath == action.nodePath }
        pendingLayoutActions.append(action)
    }

    @discardableResult
    private func writeDrawnRects() -> Bool {
        var wrote = false
        for node in flatNodes {
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

        for node in flatNodes {
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

        for node in flatNodes {
            guard node.el.handlers.onDrawnLayout != nil,
                  let drawnRect = drawnRectByPath[node.path] else { continue }
            let nid = node.nodeId
            if rectSpringingById[nid] == true {
                if let old = last[nid] { next[nid] = old }
                continue
            }
            let drawn = LayoutReadConstants.rectArray(drawnRect)
            let laid = node.staticRect
            let old = last[nid]
            guard LayoutReadConstants.rectsMoved(old?.drawn, drawn) else {
                next[nid] = old ?? (drawn, laid)
                continue
            }
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
        let viewSize = (viewport.x, viewport.y)
        for node in flatNodes where node.el.handlers.onVisible != nil {
            guard let drawnRect = drawnRectByPath[node.path] else { continue }
            let nowVisible = VisibleGeometry.onScreen(LayoutReadConstants.rectArray(drawnRect), view: viewSize)
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

        if !txBlur && nextIdx == nil {
            let allowsVirtual: (String) -> Bool = { path in
                guard let modal = self.activeModalPath else { return true }
                return path == modal || path.hasPrefix(modal + "/")
            }
            if let fk = txFocusKey ?? focusedKey,
               let v = virtualInputs.values.first(where: { $0.key == fk && allowsVirtual($0.path) }) {
                focusedPath = v.path
                focusedKey = v.key
                if prevFocusedPath != focusedPath { imeReset = true }
                return
            }
            if let fp = focusedPath, let v = virtualInputs[fp], allowsVirtual(v.path) {
                focusedPath = v.path
                focusedKey = v.key
                if prevFocusedPath != focusedPath { imeReset = true }
                return
            }
        }

        if !txBlur && nextIdx == nil && activeModalPath != nil && (prevFocusedPath != nil || !poppedReturns.isEmpty || cxSettings.viewDefaults.webFocus) {
            nextIdx = tabOrderIndices().first
        }

        if let pendingVis = kitHooks.pendingTxFocusVisible {
            kitHooks.pendingTxFocusVisible = nil
            if txFocusKey != nil {
                focusVisible = pendingVis
            }
        }
        focusedPath = nextIdx.map { flatNodes[$0].path }
        focusedKey = nextIdx.flatMap { flatNodes[$0].key }
        if prevFocusedPath != focusedPath {
            imeReset = true
        }
        syncFocusedLinkIndex()
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
        case .fill:
            let c = Color.decodeLiveLanes(lanes)
            liveFillTargets[nid] = c
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
        case .fill:
            let c = Color.decodeLiveLanes(lanes)
            liveFillTargets[nid] = c
            liveStore.set(nid, Props.FILL, to: c.motionColor, anim: .spring(spring), at: now)
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

    @inline(__always)
    private func isLinearTweenActive(_ source: LiveSource, at now: Double) -> Bool {
        guard let lin = source.linearSpec, lin.duration > 0 else { return false }
        guard let tStart = liveTweenStart[ObjectIdentifier(source)] else { return true }
        return (now - tStart) < lin.duration
    }

    private func buildRefScene(frameOut: FrameOutput, now: Double) -> RefScene {
        textSystem.glyphAtlas.beginFrame(pinnedMask: lastPinnedGlyphMask)
        var glyphPageEntries: [(index: Int, page: UInt16)] = []
        var usedGlyphMask: UInt32 = 0
        let pxScale = pixelScale
        let devW = max(1, Int((viewport.x * pxScale).rounded()))
        let devH = max(1, Int((viewport.y * pxScale).rounded()))
        let defaultViewFg = cxSettings.viewDefaults.foreground
        let defaultRingOutline = cxSettings.viewDefaults.focusRing
        let forceFocusRings = cxSettings.viewDefaults.forceFocusRings
        stuckShiftsByPath.removeAll(keepingCapacity: true)
        unseenPresence.beginPaint()
        imeArea = nil
        let activeSelectionRanges = computeActiveSelectionRangesByPath()
        pixelSnapGlides.beginFrame(t: now, size: SIMD2<Float>(Float(devW), Float(devH)))

        // Precompute raw (unscaled) rect, own scale, opacity, and tree links for `frameOut.nodes`
        var rawRectById: [NodeId: MotionRect] = [:]
        var presentedRectById: [NodeId: MotionRect] = [:]
        var presentedScaleById: [NodeId: Vec2] = [:]
        var nodeByFrameId: [NodeId: Presented] = [:]
        var childrenByParent: [NodeId: [Presented]] = [:]
        var rootNodes: [Presented] = []

        for p in frameOut.nodes {
            nodeByFrameId[p.id] = p
        }

        // Compute own raw presented rect, inherited presented rect, opacity, scale, and rotation (applying Live & Loop tracks on top of Scene)
        var presentedInhById: [NodeId: PresentedTransform] = [:]
        var ownOpacityById: [NodeId: Float] = [:]
        var ownScaleById: [NodeId: Vec2] = [:]
        var ownRotateById: [NodeId: Float] = [:]
        var liveMovedById: Set<NodeId> = []
        var liveSpatialSpringingById: Set<NodeId> = []
        for p in frameOut.nodes {
            guard let snap = nodeById[p.id] ?? exitingSnapshots[p.id] else { continue }
            var baseRect = p.rect
            var op = p.opacity
            var ownSc = p.scale
            var rot = p.rotate
            var ownDelta = Vec2.zero
            var hasLiveTransform = false
            var hasLiveSpatialSpring = false

            if let ls = sampleLoopPresentation(id: p.id, nodeSize: baseRect.size, wallNow: currentTime) {
                op *= ls.opacity
                rot += ls.rotation
                ownDelta.x += ls.offset.x
                ownDelta.y += ls.offset.y
            }

            for b in snap.el.liveBindings {
                let lnid = NodeId.hash("live:\(snap.path):\(b.target)")
                switch b.target {
                case .opacity:
                    if let v = liveStore.get(lnid, Props.OPACITY) { op = v.clamped(to: 0...1) }
                case .scale:
                    if let v = liveStore.get(lnid, Props.SCALE) {
                        ownSc = Vec2(p.scale.x * max(0, v.x), p.scale.y * max(0, v.y))
                        hasLiveTransform = true
                        if liveStore.isMoving(lnid, Props.SCALE) || isLinearTweenActive(b.source, at: now) {
                            hasLiveSpatialSpring = true
                        }
                    }
                case .offset:
                    if let v = liveStore.get(lnid, Props.OFFSET) {
                        ownDelta.x += v.x
                        ownDelta.y += v.y
                        hasLiveTransform = true
                        if liveStore.isMoving(lnid, Props.OFFSET) || isLinearTweenActive(b.source, at: now) {
                            hasLiveSpatialSpring = true
                        }
                    }
                case .rect:
                    if let v = liveStore.get(lnid, Props.RECT) {
                        baseRect = v
                        hasLiveTransform = true
                        if liveStore.isMoving(lnid, Props.RECT) || isLinearTweenActive(b.source, at: now) {
                            hasLiveSpatialSpring = true
                        }
                    }
                case .blur, .fill, .trim:
                    break
                }
            }

            let ownRaw = baseRect.offsetBy(ownDelta)
            rawRectById[p.id] = ownRaw

            let pinh: PresentedTransform = (snap.el.anchor == nil ? p.parent.flatMap { presentedInhById[$0] } : nil) ?? .identity
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
            presentedInhById[p.id] = PresentedTransform(
                dx: ownDx,
                dy: ownDy,
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
            if hasLiveTransform { liveMovedById.insert(p.id) }
            if hasLiveSpatialSpring { liveSpatialSpringingById.insert(p.id) }
            ownOpacityById[p.id] = op.clamped(to: 0...1)
            ownScaleById[p.id] = ownSc
            ownRotateById[p.id] = rot
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
            nodes.enumerated().sorted { a, b in
                let na = nodeById[a.element.id] ?? exitingSnapshots[a.element.id]
                let nb = nodeById[b.element.id] ?? exitingSnapshots[b.element.id]
                let za = na?.zOrder ?? 0
                let zb = nb?.zOrder ?? 0
                if za != zb { return za < zb }
                let sa = (na?.isSticky == true) ? 1 : 0
                let sb = (nb?.isSticky == true) ? 1 : 0
                if sa != sb { return sa < sb }
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
        var newLinkBoxes: [String: [TextLinkBox]] = [:]
        var builtSurfaces: [SurfaceDraw] = []
        var videosActive = false
        var newVideoSig: UInt64 = 0
        var newVideoSnaps: [String: VideoSnapshot] = [:]
        var newDrawnRectByPath: [String: MotionRect] = [:]
        var newRectSpringingById: [NodeId: Bool] = [:]

        let flyingRootIds: Set<NodeId> = Set(frameOut.nodes.compactMap { p in
            guard let snap = nodeById[p.id], !p.isExiting else {
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
            let inh = input.inh
            let ancestorOpacity = input.ancestorOpacity
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
            guard let snap = nodeById[p.id] ?? exitingSnapshots[p.id] else { return ([], emptyExit) }
            if !emitLiftedNow && flyingRootIds.contains(p.id) {
                liftedFlights.append(LiftedFlightSubtree(
                    node: p,
                    inh: inh,
                    ancestorOpacity: ancestorOpacity,
                    ancestorTurn: ancestorTurn,
                    outerTurnClip: outerTurnClip,
                    localTurnClip: localTurnClip,
                    parentPath: parentPath,
                    nearestGroupHovered: nearestGroupHovered,
                    nearestGroupHoverFrac: nearestGroupHoverFrac
                ))
                return ([], emptyExit)
            }
            let el = snap.el
            let textFlightTarget = activeTextFlights.first(where: { $0.targetNodeId == p.id })
            let textFlightSource = textFlightTarget == nil
                ? activeTextFlights.first(where: { FlightSelector.selects($0.state.sourceKey, path: snap.path, key: snap.key) })
                : nil
            let ownRaw = rawRectById[p.id] ?? p.rect
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

            let ownSc = ownScaleById[p.id] ?? Vec2(1, 1)
            let rawScaleVec = Vec2(inh.scale.x * ownSc.x, inh.scale.y * ownSc.y)
            let origin = (el.runtimeExtras["scaleOrigin"] != nil)
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
            if abs(rawScaleVec.y - 1.0) <= 1e-5 {
                let th = PixelSnap.snapPx(snap.targetRect.height, scale: pxScale) / pxScale
                if abs(scaledRawRect.height - th) * pxScale < 1.0 / 32.0 {
                    scaledRawRect = MotionRect(left: scaledRawRect.left, top: scaledRawRect.top, right: scaledRawRect.right, bottom: scaledRawRect.top + th)
                }
            }
            let ownOp = ownOpacityById[p.id] ?? p.opacity
            let groupFactor: Float = {
                guard let (restOp, hovOp) = el.groupOpacity else { return 1.0 }
                return restOp + (hovOp - restOp) * nearestGroupHoverFrac
            }()
            let textFlightGlyphAlpha: Float = {
                if let tf = textFlightTarget {
                    return tf.state.alphas(target: tf.state.destination, now: now, reducedMotion: reducedMotion).target
                }
                if let sf = textFlightSource {
                    return sf.state.alphas(target: sf.state.destination, now: now, reducedMotion: reducedMotion).source
                }
                return 1.0
            }()
            let revealFactor: Float = {
                guard let span = el.stickyConfig?.reveal else { return 1.0 }
                return StickyMath.stuckRevealFactor(parentShift: input.parentStickyMag, span: span)
            }()
            let alpha = (ownOp * ancestorOpacity * groupFactor * input.kidsFadeOpacity * revealFactor).clamped(to: 0...1)
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
                if !p.isExiting && snap.index < flatNodes.count && flatNodes[snap.index].nodeId == snap.nodeId {
                    return computePaintStickyShift(
                        nodeIndex: snap.index,
                        parentStickyShift: input.parentStickyShift,
                        presentedRectByNodeId: presentedRectById
                    )
                }
                return (input.parentStickyShift, input.parentStickyMag)
            }()
            if let a = el.anchor,
               !snap.isSticky,
               let aNode = flatNodes.first(where: { $0.key == a.key }) {
                let aShift = stuckShiftsByPath[aNode.path] ?? .zero
                if aShift != .zero, let aPres = presentedRectById[aNode.nodeId] {
                    let placement = AnchorLayoutHelper.zoomedPlacement(
                        anchor: a,
                        triggerZoomed: aPres,
                        anchorScale: aNode.inheritedScale,
                        localSize: Vec2(rect.width, rect.height),
                        overlayOwnScale: el.scale,
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
            let ownSpatialMoving =
                scene.store.isMoving(p.id, Props.FRAME) ||
                scene.store.isMoving(p.id, Props.TRAVEL) ||
                scene.store.isMoving(p.id, Props.SCALE) ||
                scene.store.isMoving(p.id, Props.UNIFORM_SCALE) ||
                scene.store.isMoving(p.id, Props.OFFSET) ||
                scene.store.isMoving(p.id, Props.ROTATE) ||
                scene.store.isMoving(p.id, Props.PRESENCE) ||
                liveSpatialSpringingById.contains(p.id) ||
                (!el.layout.scrollAxes.isEmpty && scrollStore.isMoving(NodeId.hash("scroll:" + snap.path), Props.SCROLL))
            let nodeRectSpringing = inh.rectSpringing || ownSpatialMoving
            if !p.isExiting {
                let drawnArr = Self.rotatedBoundsArray(rect, turn: effRotate)
                newDrawnRectByPath[snap.path] = MotionRect.fromXYWH(drawnArr[0], drawnArr[1], drawnArr[2], drawnArr[3])
                newRectSpringingById[p.id] = nodeRectSpringing
            }

            var fillColor: Color
            if let pf = p.fill {
                let isPressedNode = (pressedPath == snap.path) && !snap.effectiveInert
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
            var blurPt = p.blur
            var liveTrim: Vec2? = nil
            for b in el.liveBindings {
                let lnid = NodeId.hash("live:\(snap.path):\(b.target)")
                if b.target == .fill {
                    if !liveStore.isMoving(lnid, Props.FILL), let exact = liveFillTargets[lnid] {
                        fillColor = exact
                    } else if let mc = liveStore.get(lnid, Props.FILL) {
                        fillColor = Color(mc)
                    }
                } else if b.target == .blur, let bl = liveStore.get(lnid, Props.BLUR) {
                    blurPt = bl.radius
                } else if b.target == .trim, let tr = liveStore.get(lnid, Props.OFFSET) {
                    liveTrim = tr
                }
            }
            let borderColor: Color
            if let pb = p.border {
                let settledBorder = !scene.store.isMoving(p.id, Props.BORDER)
                    && abs(pb.r - el.borderColor.r) < 1e-3
                    && abs(pb.g - el.borderColor.g) < 1e-3
                    && abs(pb.b - el.borderColor.b) < 1e-3
                    && abs(pb.a - el.borderColor.a) < 1e-3
                borderColor = (settledBorder || pb == el.borderColor.motionColor) ? el.borderColor : Color(pb)
            } else {
                borderColor = el.borderColor
            }

            var visClip = flightClipOverride ?? (inh.clip.map { intersectRects(snap.clipRect, $0) } ?? snap.clipRect)
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
            let hoverFrac: Float = {
                if let tracked = liveStore.get(Self.hoverTrackId(p.id), Self.hoverProp) {
                    return tracked.clamped(to: 0...1)
                }
                if el.isHoverGroup || el.hoverGroupShare != nil {
                    return (!p.isExiting && isGroupHovered(snap)) ? 1.0 : 0.0
                }
                return isHovered ? 1.0 : 0.0
            }()
            if !(isPressed && el.pressBg != nil), let hBg = el.hoverBg, hoverFrac > 0.0005 {
                fillColor = blendColorOver(bottom: fillColor, top: hBg.scaleAlpha(hoverFrac), srgb: srgbBlend)
            }
            let carriedScrolled: Vec2 = {
                var sum = Vec2.zero
                var cur = snap.parentIndex
                while let pIdx = cur, flatNodes.indices.contains(pIdx) {
                    let pNode = flatNodes[pIdx]
                    if let off = scrollOffsets[pNode.path] {
                        sum.x += off.x
                        sum.y += off.y
                    }
                    cur = pNode.parentIndex
                }
                return sum
            }()
            let scrolled: Vec2 = {
                if !el.layout.scrollAxes.isEmpty {
                    return scrollOffsets[snap.path] ?? .zero
                }
                return carriedScrolled
            }()

            // Compute resting rect for PixelSnap motion tracking (`build.rs:435-445`)
            let ownRestOff = Vec2(ownRaw.left - p.rect.left, ownRaw.top - p.rect.top)
            let nodeRestOffset = Vec2(inh.restOffset.x + el.offset.x + ownRestOff.x, inh.restOffset.y + el.offset.y + ownRestOff.y)
            let rawRestRect = snap.targetRect.offsetBy(nodeRestOffset)

            let nodeMoving = p.isMoving || inh.parentMoving || trailingMoved || liveMovedById.contains(p.id)
            let rExact = PixelSnap.edgesPx(rect, scale: pxScale)
            let rawEdgesPx = PixelSnap.edgesPx(rawRect, scale: pxScale)
            let ownStickyDelta = SIMD2<Float>(stickyShift.x - input.parentStickyShift.x, stickyShift.y - input.parentStickyShift.y)
            let rigidPt = SIMD2<Float>(inh.snap.rigid.x + ownStickyDelta.x, inh.snap.rigid.y + ownStickyDelta.y)
            let rigidPx = rigidPt * pxScale
            let canSnap = !inh.snap.off && el.isPixelSnapEnabled && abs(p.rotate) < 1e-6
            let filterMargin = blurPt * pxScale * 3.0 + 2.0
            let snaps = canSnap && (el.isolatedLayer || (
                max(rExact[2], rExact[0]) >= max(visClip.left * pxScale, 0) - filterMargin
                && rExact[0] <= min(visClip.right * pxScale, Float(devW)) + filterMargin
                && max(rExact[3], rExact[1]) >= max(visClip.top * pxScale, 0) - filterMargin
                && rExact[1] <= min(visClip.bottom * pxScale, Float(devH)) + filterMargin
            ))
            let unscaled = abs(scaleVec.x - 1.0) <= 1e-5 && abs(scaleVec.y - 1.0) <= 1e-5 && anchor == anchorTo
            let ownScaleSpringMoving = scene.store.isAnimating(p.id, Props.SCALE)
                || scene.store.isAnimating(p.id, Props.UNIFORM_SCALE)
                || scene.store.isAnimating(p.id, Props.PRESENCE)
            let ownLiveScaleMoving = el.liveBindings.contains(where: { b in
                b.target == .scale
                    && (liveStore.isMoving(NodeId.hash("live:\(snap.path):\(b.target)"), Props.SCALE) || isLinearTweenActive(b.source, at: now))
            })
            let nodeScaleMotion: PaintScaleMotion = max(
                inh.scaleMotion,
                ownScaleSpringMoving ? .moving : (ownLiveScaleMoving ? .live : .still)
            )
            let isAnchoredOverlay = el.anchor != nil
            let isGrowthRow = growthRows["growth:\(snap.path)"] != nil || growthRows["fold:\(snap.path)"] != nil
            let opensSnapLayer = hasOwnScale || (isAnchoredOverlay && !unscaled)
            let snapLayer = (canSnap && opensSnapLayer)
                ? pixelSnapGlides.layer(id: p.id, r: rExact, unscaled: rawEdgesPx, rigid: rigidPx, cached: el.isolatedLayer)
                : inh.snap.layer
            let restForMotion: MotionRect? = (snaps && nodeMoving) ? rawRestRect : nil
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
                visClip.left * pxScale,
                visClip.top * pxScale,
                visClip.width * pxScale,
                visClip.height * pxScale
            )
            let paintMargin = el.shadows.reduce(filterMargin) {
                max($0, ($1.blur * 3.0 + max($1.spread, 0) + max(abs($1.x), abs($1.y))) * pxScale + 2.0)
            }
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
            let shouldEmit = alpha > 0.001 && visClip.width > 0 && visClip.height > 0 && onScreenForEmit
            unseenPresence.recordPaintedNode(
                id: p.id,
                inView: isNodeInViewForUnseen(el: el, isActiveFlight: isActiveFlight, visibleRect: visibleRect)
            )

            let devRect = SIMD4<Float>(
                snappedEdgesPx[0],
                snappedEdgesPx[1],
                max(0, snappedEdgesPx[2] - snappedEdgesPx[0]),
                max(0, snappedEdgesPx[3] - snappedEdgesPx[1])
            )

            let activeFadeEdges: [(fade: SIMD4<Float>, origin: SIMD2<Float>)] = {
                guard !snap.activeClipFades.isEmpty else { return [] }
                let effectiveFades: [EdgeFadeSpec]
                if let stickyEdge = el.stickyConfig?.edge, stickyMag > 0.01 {
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
                    specs: effectiveFades,
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
                let stuckShadowFactor = (el.stickyConfig != nil) ? StickyMath.stuckShadowFactor(shift: stickyMag) : 0.0
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
                } else if let px = el.pixelsPayload {
                    let sz = px.size
                    if sz.width > 0 && sz.height > 0 {
                        let atlas = RGBA8Atlas(width: Int(sz.width), height: Int(sz.height), texels: px.rgbaBytes())
                        let normUV = imagePacker.insert(atlas)
                        let fitted = Runtime.fittedPixelsGeometry(
                            box: devRect,
                            uv: normUV,
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
                            turn: useLayer ? 0 : p.rotate
                        ))
                    }
                }

                let avgScale = (scaleVec.x + scaleVec.y) * 0.5
                let wExact = max(0, rExact[2] - rExact[0])
                let hExact = max(0, rExact[3] - rExact[1])
                let exactSide = min(wExact, hExact)
                let boxGliding = gliding || (snapRest?.left != nil && snapRest!.left != .zero)

                // 6. SVG Icon payload
                if let (svg, _) = el.iconPayload {
                    let effGlyphTurn = useLayer ? 0 : effRotate
                    let iconResting = (flightCover == nil)
                        && (nodeScaleMotion == .still)
                        && !boxGliding
                        && abs(effGlyphTurn) <= 1e-6
                        && abs(avgScale - 1.0) < 1e-5
                    let resolvedColor = (nearestGroupHovered ? el.groupColor : nil) ?? el.textColor ?? cxSettings.viewDefaults.foreground ?? .white
                    let tint = resolvedColor.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                    if iconResting && exactSide > 1e-4 {
                        let canvas = max(1, Int(ceil(exactSide - 1.0 / 64.0)))
                        let atX = floor(rExact[0] + (wExact - exactSide) * 0.5 + 0.5)
                        let atY = floor(rExact[1] + (hExact - exactSide) * 0.5 + 0.5)
                        let entry = textSystem.glyphAtlas.rasterizeIcon(svg, pixelSize: canvas, drawnSize: exactSide)
                        let primIdx = primitives.count
                        primitives.append(attachFade(.glyph(
                            rect: SIMD4<Float>(atX, atY, Float(canvas), Float(canvas)),
                            uv: entry.uv,
                            color: tint,
                            gamma: 1.0,
                            clip: devClip,
                            turn: 0
                        )))
                        glyphPageEntries.append((primIdx, entry.page))
                        usedGlyphMask |= UInt32(1) << min(UInt32(entry.page), 31)
                    } else if exactSide > 1e-4 {
                        let tk = (flightCover != nil) ? Float(1.0) : avgScale
                        let raster = (flightCover != nil) ? Float(1.0) : nodeScaleMotion.raster(sc: avgScale, rest: inh.stillScale)
                        let zoom = tk / max(1e-4, raster)
                        let rawSide = max(0, min(rawRect.width, rawRect.height)) * pxScale
                        let snapU: Float = (flightCover == nil && abs(rawSide - rawSide.rounded()) < 1.0 / 512.0)
                            ? max(0, min(1, 1.0 - abs(avgScale - 1.0) * 32.0))
                            : 0.0
                        let drawn = exactSide + (min(devRect.z, devRect.w) - exactSide) * snapU
                        if drawn > 1e-4 {
                            let px: Int = (flightCover == nil && nodeScaleMotion != .still)
                                ? max(1, Int((rawSide * raster).rounded()))
                                : max(1, Int((drawn / max(1e-4, zoom)).rounded()))
                            let posX = devRect.x + (devRect.z - drawn) * 0.5
                            let posY = devRect.y + (devRect.w - drawn) * 0.5
                            let entry = textSystem.glyphAtlas.rasterizeIcon(svg, pixelSize: px)
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
                            glyphPageEntries.append((primIdx, entry.page))
                            usedGlyphMask |= UInt32(1) << min(UInt32(entry.page), 31)
                        }
                    }
                }

                // 7. Vector Canvas Shapes (triangles & segments)
                let shapeStill = (flightCover == nil)
                    && (nodeScaleMotion == .still)
                    && !boxGliding
                    && abs(avgScale - 1.0) < 1e-5
                let shapeAt = shapeStill
                    ? SIMD2<Float>(floor(rExact[0] + 0.5), floor(rExact[1] + 0.5))
                    : SIMD2<Float>(devRect.x + (devRect.z - wExact) * 0.5, devRect.y + (devRect.w - hExact) * 0.5)
                for shape in el.shapes {
                    let effectiveShape = liveTrim.map { shape.trimmed(start: $0.x, end: $0.y) } ?? shape
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
                let snappedOriginX = snappedEdgesPx[0] / pxScale
                let snappedOriginY = snappedEdgesPx[1] / pxScale
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
                    if let fDir = edit.forcedDir { inputStyle.direction = fDir }

                    let shaped = textSystem.shape(
                        text: renderedStr,
                        style: inputStyle,
                        maxWidth: edit.multiline ? innerW : nil,
                        pixelScale: pxScale,
                        emitGlyphs: !renderedStr.isEmpty,
                        glidePx: glidePx
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
                                    (restOriginX + sx) * pxScale,
                                    (restOriginY + cStart.y) * pxScale,
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
                                    (restOriginX + cStart.x) * pxScale,
                                    (restOriginY + cStart.y) * pxScale,
                                    max(4, innerW - cStart.x) * pxScale,
                                    cStart.w * pxScale
                                ),
                                fill: selCol,
                                clip: devInputClip
                            ))
                            primitives.append(.roundedRect(
                                rect: SIMD4<Float>(
                                    restOriginX * pxScale,
                                    (restOriginY + cEnd.y) * pxScale,
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
                        let gc = (g.color ?? textCol).scaleAlpha(localAlpha * textFlightGlyphAlpha).simd4(srgb: srgbBlend)
                        let primIdx = primitives.count
                        primitives.append(.glyph(
                            rect: SIMD4<Float>(
                                (restOriginX + g.rect.x * scaleVec.x) * pxScale,
                                (restOriginY + g.rect.y * scaleVec.y) * pxScale,
                                g.rect.z * scaleVec.x * pxScale,
                                g.rect.w * scaleVec.y * pxScale
                            ),
                            uv: g.uv,
                            color: gc,
                            gamma: systemDark ? 0.88 : 1.05,
                            clip: devInputClip
                        ))
                        glyphPageEntries.append((primIdx, g.atlasPage))
                        usedGlyphMask |= UInt32(1) << min(UInt32(g.atlasPage), 31)
                    }

                    // Caret bar when focused & window focused
                    if isFocused {
                        let byteOff = showingPlaceholder ? 0 : edit.cursor
                        let cRect = textSystem.caretRect(in: shaped, utf8Offset: byteOff, pixelScale: pxScale)
                        let caretXPt: Float
                        if isGliding {
                            let cxPx = (textOriginX + cRect.x) * pxScale
                            caretXPt = ((cxPx - glidePx.x).rounded(.toNearestOrAwayFromZero) + glidePx.x) / pxScale
                        } else {
                            caretXPt = textOriginX + cRect.x
                        }
                        let worldCaret = [caretXPt, textOriginY + cRect.y, cRect.z, cRect.w]
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
                        pills: el.pillChips,
                        style: el.textStyle,
                        maxWidth: wrapWidth,
                        pixelScale: pxScale,
                        emitGlyphs: true,
                        glidePx: glidePx
                    )
                    if el.isHelpWhenTruncated {
                        let naturalSize = textSystem.measure(
                            paintedLabelValue ?? "",
                            style: el.textStyle,
                            maxWidth: nil,
                            pixelScale: pxScale,
                            pills: el.pillChips
                        )
                        if naturalSize.x > wrapWidth + 0.5 || naturalSize.y > rect.height + 0.5 {
                            textTruncated = true
                        }
                    }
                    let selPaintInk = emitSelectableHighlightIfNeeded(
                        snap: snap, el: el, isExiting: p.isExiting, activeSelectionRanges: activeSelectionRanges,
                        textOriginX: restOriginX, textOriginY: restOriginY, scaleVec: scaleVec, pxScale: pxScale,
                        localAlpha: localAlpha, shaped: shaped, devClip: devClip, useLayer: useLayer, effRotate: effRotate,
                        into: &primitives
                    )
                    let linkInks = recordAndEmitTextLinks(
                        snap: snap,
                        el: el,
                        text: paintedLabelValue ?? "",
                        shaped: shaped,
                        textOriginX: textOriginX,
                        textOriginY: textOriginY,
                        scaleVec: scaleVec,
                        pxScale: pxScale,
                        localAlpha: localAlpha,
                        defaultTextColor: defaultTextColor,
                        defaultRingOutline: defaultRingOutline,
                        forceFocusRings: forceFocusRings,
                        isFocused: isFocused,
                        isExiting: p.isExiting,
                        shouldEmit: shouldEmit,
                        visClip: visClip,
                        devClip: devClip,
                        useLayer: useLayer,
                        effRotate: effRotate,
                        into: &primitives,
                        linkBoxes: &newLinkBoxes,
                        helpHits: &newHelpHits,
                        interactiveHits: &newInteractiveHits
                    )
                    textSystem.emitTextDecorationsAndPills(
                        shaped: shaped,
                        textOriginX: textOriginX,
                        textOriginY: textOriginY,
                        scaleVec: scaleVec,
                        pxScale: pxScale,
                        defaultTextColor: defaultTextColor,
                        localAlpha: localAlpha,
                        srgbBlend: srgbBlend,
                        devClip: devClip,
                        rot: useLayer ? 0 : effRotate,
                        insertImage: { imagePacker.insert($0) },
                        into: &primitives
                    )
                    var highlightInks: [TextLinkInkRange] = []
                    if let hls = el.textHighlights, !hls.isEmpty, let txt = paintedLabelValue, !txt.isEmpty {
                        let txtLen = txt.utf8.count
                        for h in hls {
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
                            highlights: hls,
                            in: txt,
                            shaped: shaped,
                            textSystem: textSystem,
                            pixelScale: pxScale,
                            origin: .zero
                        )
                        for q in quads {
                            let hlRect = SIMD4<Float>(
                                restOriginX * pxScale + q.rect.x * scaleVec.x,
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
                    let glyphAlpha = localAlpha * textFlightGlyphAlpha
                    if glyphAlpha > 0.0005 {
                        for g in shaped.glyphs {
                            let gc = (selPaintInk?.color(for: g) ?? linkInkColor(for: g, ranges: highlightInks) ?? linkInkColor(for: g, ranges: linkInks) ?? g.color ?? defaultTextColor).scaleAlpha(glyphAlpha).simd4(srgb: srgbBlend)
                            let primIdx = primitives.count
                            primitives.append(attachFade(.glyph(
                                rect: SIMD4<Float>(
                                    (restOriginX + g.rect.x * scaleVec.x) * pxScale,
                                    (restOriginY + g.rect.y * scaleVec.y) * pxScale,
                                    g.rect.z * scaleVec.x * pxScale,
                                    g.rect.w * scaleVec.y * pxScale
                                ),
                                uv: g.uv,
                                color: gc,
                                gamma: systemDark ? 0.88 : 1.05,
                                clip: devClip,
                                turn: useLayer ? 0 : effRotate
                            )))
                            glyphPageEntries.append((primIdx, g.atlasPage))
                            usedGlyphMask |= UInt32(1) << min(UInt32(g.atlasPage), 31)
                        }
                    }
                }

                // 9. Focus ring & focus-within ring when keyboard-focus-visible (or forced by Cx::forceFocusRings / focused textInput)
                if !hasActiveTextLinks(el) {
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
            }

            let hasVisualBlocker = fillColor.a > 0.001 || el.gradient != nil ||
                (el.borderWidth > 0 && borderColor.a > 0.001) || el.imagePayload != nil || el.pixelsPayload != nil ||
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

            var nodeEditRange: [Int]? = nil
            if let lens = el.handlers.editLens {
                let r = lens.get(state).selectedUTF8Range
                nodeEditRange = [r.lowerBound, r.upperBound]
            }
            if isFocused && !nodeIsSecure && el.handlers.editLens != nil {
                if let caretOut {
                    imeArea = caretOut
                } else {
                    imeArea = rect.xywh
                }
            }
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
                hover: p.isExiting ? 0.0 : hoverFrac,
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
                    var cur = snap.parentIndex
                    while let pIdx = cur, flatNodes.indices.contains(pIdx) {
                        if let anc = flatNodes[pIdx].el.traceNamespaceValue {
                            return TraceNamespace(className: anc.className, host: anc.host)
                        }
                        cur = flatNodes[pIdx].parentIndex
                    }
                    return nil
                }(),
                virtualExtent: false,
                editRange: nodeEditRange
            ))
            if let hls = el.textHighlights, !hls.isEmpty,
               let txt = elementTextValue, !txt.isEmpty,
               snap.index < flatNodes.count {
                let hlNode = flatNodes[snap.index]
                let drawnBoxes = highlightBoxes(node: hlNode, boxRect: rect, scale: scaleVec)
                let targetBoxes = highlightBoxes(node: hlNode, boxRect: snap.targetRect)
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
                let txtUtf8 = Array(txt.utf8)
                for (k, hl) in hls.enumerated() {
                    guard let r = drawnUnions[k] else { continue }
                    let t = targetUnions[k] ?? r
                    let vis = intersectRects(r, visibleRect)
                    let a = max(0, min(hl.byteRange.lowerBound, txtUtf8.count))
                    let b = max(a, min(hl.byteRange.upperBound, txtUtf8.count))
                    let words = (a < b) ? String(decoding: txtUtf8[a..<b], as: UTF8.self) : nil
                    infos.append(ElementInfo(
                        path: "\(snap.path)#mark-\(k)",
                        key: hl.key,
                        parentIndex: snap.index,
                        role: .mark,
                        rect: r.xywh,
                        target: t.xywh,
                        visible: vis.xywh,
                        opacity: alpha,
                        scale: scaleVec.x,
                        blur: blurPt,
                        radius: 4.0,
                        fill: hl.bg,
                        textColor: el.textColor ?? cxSettings.viewDefaults.foreground,
                        text: words,
                        label: words,
                        help: resolvedRawHelp.map(runeHelpWords),
                        selected: nil,
                        expanded: nil,
                        level: nil,
                        itemSelected: false,
                        focusable: false,
                        focused: false,
                        focusVisible: false,
                        inert: snap.effectiveInert,
                        moving: p.isMoving,
                        exiting: p.isExiting,
                        hover: 0,
                        press: 0,
                        scrolled: [scrolled.x, scrolled.y],
                        caret: nil,
                        secure: nodeIsSecure,
                        disabled: el.a11yDisabled,
                        checked: el.a11yChecked,
                        a11yValue: el.a11yValue,
                        a11yDescription: el.a11yDescription,
                        a11yHidden: el.isA11yHidden,
                        stuck: 0
                    ))
                }
            }

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
                        guard let sibFlat = nodeById[sib.id],
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
                var childRigid = rigidPt
                childRigid.x -= snap.scrollShift.x
                childRigid.y -= snap.scrollShift.y
                var childSnap = PixelSnap.Inherit()
                childSnap.off = inh.snap.off || !el.isPixelSnapEnabled || abs(p.rotate) >= 1e-6
                childSnap.rigid = childRigid
                childSnap.layer = snapLayer
                let paintsFrame = PixelSnap.frames(el, effectiveFill: fillColor, effectiveBorder: borderColor)
                childSnap.parent = (childRigid == inh.snap.rigid && paintsFrame) ? snapRest : nil

                let childClip: MotionRect?
                if el.layout.clipOverflow {
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

                let ownLiveOff = Vec2(ownRaw.left - p.rect.left, ownRaw.top - p.rect.top)
                let childOffsetDelta = Vec2(inh.offsetDelta.x + ownLiveOff.x, inh.offsetDelta.y + ownLiveOff.y)
                let childFullDelta = Vec2(inh.fullDelta.x + ownLiveOff.x, inh.fullDelta.y + ownLiveOff.y)
                let childScaleMotion: PaintScaleMotion = (childFlightCover != nil) ? .moving : nodeScaleMotion
                let childStillScale: Float = (childScaleMotion == .still) ? ((scaleVec.x + scaleVec.y) * 0.5) : inh.stillScale
                let childInh = PaintInh(
                    opacity: childAncestorOp,
                    scale: rawScaleVec,
                    anchor: anchor,
                    anchorTo: anchorTo,
                    offsetDelta: childOffsetDelta,
                    fullDelta: childFullDelta,
                    restOffset: nodeRestOffset,
                    snap: childSnap,
                    scaleMotion: childScaleMotion,
                    stillScale: childStillScale,
                    parentDrawnWidth: rect.width,
                    parentTargetWidth: snap.targetRect.width,
                    parentMoving: nodeMoving,
                    rectSpringing: nodeRectSpringing,
                    clip: childClip
                )
                let sorted = sortByZOrder(children)
                childSteps.reserveCapacity(sorted.count)
                for child in sorted {
                    childSteps.append(EmitStepInput(
                        p: child,
                        inh: childInh,
                        ancestorOpacity: childAncestorOp,
                        ancestorTurn: nodeTurn,
                        outerTurnClip: nextOuterClip,
                        localTurnClip: childLocalTurnClip,
                        parentPath: snap.path,
                        nearestGroupHovered: nextGroupHovered,
                        nearestGroupHoverFrac: nextGroupHoverFrac,
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
            ancestorTurn: Turn?,
            outerTurnClip: MotionRect?,
            localTurnClip: MotionRect?,
            parentPath: String?,
            nearestGroupHovered: Bool,
            nearestGroupHoverFrac: Float,
            flightCover: FlightCoverTransform? = nil,
            flightClipOverride: MotionRect? = nil,
            emitLiftedNow: Bool = false
        ) {
            var workStack: [EmitWorkItem] = [
                .enter(EmitStepInput(
                    p: p,
                    inh: inh,
                    ancestorOpacity: ancestorOpacity,
                    ancestorTurn: ancestorTurn,
                    outerTurnClip: outerTurnClip,
                    localTurnClip: localTurnClip,
                    parentPath: parentPath,
                    nearestGroupHovered: nearestGroupHovered,
                    nearestGroupHoverFrac: nearestGroupHoverFrac,
                    flightCover: flightCover,
                    flightClipOverride: flightClipOverride,
                    emitLiftedNow: emitLiftedNow,
                    parentStickyShift: .zero,
                    parentStickyMag: 0,
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
                inh: PaintInh(),
                ancestorOpacity: 1.0,
                ancestorTurn: nil,
                outerTurnClip: nil,
                localTurnClip: nil,
                parentPath: nil,
                nearestGroupHovered: false,
                nearestGroupHoverFrac: 0.0
            )
        }
        for lifted in liftedFlights {
            let isUnclippedFlight = launchedFlightIds.contains(lifted.node.id)
                || unclippedMatchedFlightIds.contains(lifted.node.id)
            var liftedInh = lifted.inh
            if isUnclippedFlight {
                liftedInh.clip = nil
            }
            emitSubtree(
                lifted.node,
                inh: liftedInh,
                ancestorOpacity: lifted.ancestorOpacity,
                ancestorTurn: lifted.ancestorTurn,
                outerTurnClip: lifted.outerTurnClip,
                localTurnClip: lifted.localTurnClip,
                parentPath: lifted.parentPath,
                nearestGroupHovered: lifted.nearestGroupHovered,
                nearestGroupHoverFrac: lifted.nearestGroupHoverFrac,
                flightCover: nil,
                flightClipOverride: isUnclippedFlight ? windowRect : nil,
                emitLiftedNow: true
            )
        }
        seenMatchedByFlightId = newSeenMatched

        if !activeTextFlights.isEmpty {
            let unclippedDevClip = SIMD4<Float>(0, 0, Float(devW), Float(devH))
            for entry in activeTextFlights {
                let (srcAlpha, _) = entry.state.alphas(
                    target: entry.state.destination,
                    now: now,
                    reducedMotion: reducedMotion
                )
                let presentedRect = entry.state.presented
                let targetSnap = nodeById[entry.targetNodeId]
                let targetLeaf = entry.state.targetKey
                    .split(separator: "/")
                    .last
                    .map(String.init)
                    ?? entry.state.targetKey
                let flightText = entry.sourceText ?? targetSnap?.el.plainText ?? ""
                let flightStyle = entry.sourceTextStyle
                let flightColor = entry.sourceTextColor
                    ?? targetSnap?.el.textColor
                    ?? defaultViewFg
                    ?? Tok.theme(dark: systemDark).text
                if srcAlpha > 0.0005 && (!flightText.isEmpty || entry.sourceSpans != nil) {
                    let srcExtent = entry.state.source
                    let shaped = textSystem.shape(
                        text: flightText,
                        spans: entry.sourceSpans,
                        style: flightStyle,
                        maxWidth: srcExtent.width + 0.5,
                        pixelScale: pxScale,
                        emitGlyphs: true
                    )
                    let sx = srcExtent.width > 0.5 ? presentedRect.width / srcExtent.width : 1.0
                    let sy = srcExtent.height > 0.5 ? presentedRect.height / srcExtent.height : 1.0
                    for g in shaped.glyphs {
                        let gc = (g.color ?? flightColor).scaleAlpha(srcAlpha).simd4(srgb: srgbBlend)
                        let primIdx = primitives.count
                        primitives.append(.glyph(
                            rect: SIMD4<Float>(
                                (presentedRect.x + g.rect.x * sx) * pxScale,
                                (presentedRect.y + g.rect.y * sy) * pxScale,
                                g.rect.z * sx * pxScale,
                                g.rect.w * sy * pxScale
                            ),
                            uv: g.uv,
                            color: gc,
                            gamma: systemDark ? 0.88 : 1.05,
                            clip: unclippedDevClip
                        ))
                        glyphPageEntries.append((primIdx, g.atlasPage))
                        usedGlyphMask |= UInt32(1) << min(UInt32(g.atlasPage), 31)
                    }
                }
                infos.append(ElementInfo(
                    path: "flight-source/\(targetLeaf)",
                    key: nil,
                    parentIndex: nil,
                    role: .text,
                    rect: presentedRect.xywh,
                    target: entry.state.destination.xywh,
                    visible: presentedRect.xywh,
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

        linkBoxesByPath = newLinkBoxes
        appendLinkElements(to: &infos)
        lastElements = infos
        landUnseenEntrances(frameNodes: frameOut.nodes, on: &scene)
        presentedRectByPath = newRectByPath
        presentedScaleByPath = newScaleByPath
        hitGeometryByPath = newHitGeometries
        paintOrderPaths = newPaintOrder
        drawnRectByPath = newDrawnRectByPath
        rectSpringingById = newRectSpringingById
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
        lastPinnedGlyphMask = usedGlyphMask
        let pageCount = textSystem.glyphAtlas.pageCount
        if pageCount > 1 {
            let pagesF = Float(pageCount)
            for item in glyphPageEntries where item.index < primitives.count {
                let p = Float(min(Int(item.page), pageCount - 1))
                primitives[item.index].uv.y = (primitives[item.index].uv.y + p) / pagesF
                primitives[item.index].uv.w = (primitives[item.index].uv.w + p) / pagesF
            }
        }

        return RefScene(
            width: devW,
            height: devH,
            srgbBlend: srgbBlend,
            clearColor: clearColor.simd4(srgb: srgbBlend),
            glyphs: textSystem.glyphAtlas.compositedAtlas(),
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

    internal func hitTest(at point: Vec2, ignoreBlockers: Bool = false, predicate: ((FlatNode) -> Bool)? = nil) -> (node: FlatNode, rect: MotionRect)? {
        guard let detailed = hitTestDetailed(at: point, ignoreBlockers: ignoreBlockers, predicate: predicate) else { return nil }
        return (detailed.node, detailed.rect)
    }

    internal func hitTestDetailed(
        at point: Vec2,
        ignoreBlockers: Bool = false,
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

    private func hitTestAll(
        at point: Vec2,
        predicate: (FlatNode) -> Bool
    ) -> [(node: FlatNode, rect: MotionRect, localPoint: Vec2)] {
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
                    matches.append((node, geom.rect, Vec2(localWindowPt.x - geom.rect.x, localWindowPt.y - geom.rect.y)))
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
                    matches.append((node, infoRect, Vec2(point.x - infoRect.x, point.y - infoRect.y)))
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
        pressedLink = nil
        pointerExit(at: now)
    }

    internal func releasePointerForDragOut(at now: Double) {
        activeDrag = nil
        pressedPath = nil
        pressedKey = nil
        pressedLink = nil
        hoveredLink = nil
        if let old = hoveredPath {
            hoveredPath = nil
            hoveredKey = nil
            if let idx = nodeByPath[old], !flatNodes[idx].el.hasKitHoverDelays,
               let cb = flatNodes[idx].el.handlers.onHover {
                var tx = makeTx(at: now)
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
        hoverHoldState = .free
        pointerPosition = Vec2(-10000, -10000)
        if hoveredLink != nil {
            hoveredLink = nil
            dirtyCommit(at: now)
        }
        if helpState.tipState != .idle {
            dirtyCommit(at: now)
        }
        if let old = hoveredPath {
            hoveredPath = nil
            hoveredKey = nil
            if let oldIdx = nodeByPath[old], !flatNodes[oldIdx].el.hasKitHoverDelays,
               let cb = flatNodes[oldIdx].el.handlers.onHover {
                var tx = makeTx(at: now)
                cb(&state, false, &tx)
                applyTx(tx, at: now)
            }
            dirtyCommit(at: now)
        }
        settleKitHoverDelays(at: pointerPosition, now: now)
        syncHoverTracks(at: cxSettings.scaledTime(at: now), cut: false, held: false)
    }

    public func pointerMove(to pos: Vec2, mods: Mods = .none, at now: Double) {
        let moved = pos != pointerPosition
        if moved {
            releaseHoverHold()
            resetKitHoverHoldOnPointerMove()
        }
        pointerPosition = pos

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
        if let drag = activeDrag {
            if !drag.movedBeyondSlop,
               hypotf(pos.x - drag.startWindow.x, pos.y - drag.startWindow.y) > 4.0 {
                activeDrag?.movedBeyondSlop = true
            }
            if let idx = nodeByPath[drag.path] {
                let node = flatNodes[idx]
                if drag.isTextSelectionDrag, let editLens = node.el.handlers.editLens {
                    var edit = editLens.get(state)
                    let offset = textHitOffset(node: node, windowPos: pos, edit: edit)
                    edit.setCursor(utf8Offset: offset, extendSelection: true)
                    editLens.set(&state, edit)
                    pendingCommitKind = pendingCommitKind.instant()
                    dirtyCommit(at: now)
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
                        mods: mods
                    )
                    var tx = makeTx(at: now, button: drag.button)
                    onDrag(&state, d, &tx)
                    if !tx.askedMotion { tx.instant() }
                    applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
                    armKitDragRepeatIfRequested(path: drag.path, windowPos: pos, mods: mods, button: drag.button, now: now)
                }
            }
            return
        }

        let hit = hitTest(at: pos) { node in
            Self.hoverHitPredicate(node) || self.hasActiveTextLinks(node.el)
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

        if hoverHoldState != .held {
            if linkChanged {
                hoveredLink = newHoveredLink
            }
            let newPath = hit?.node.path
            let newKey = hit?.node.key
            if newPath != hoveredPath {
                let oldPath = hoveredPath
                hoveredPath = newPath
                hoveredKey = newKey
                isDispatchingHover = true
                var ranAnyHover = false
                var hoverAllLiveOnly = true
                if let old = oldPath, let oldIdx = nodeByPath[old],
                   !flatNodes[oldIdx].el.hasKitHoverDelays,
                   let cb = flatNodes[oldIdx].el.handlers.onHover {
                    var tx = makeTx(at: now)
                    cb(&state, false, &tx)
                    if !tx.liveOnlyRequested {
                        perfWatch.meter.handler(name: "on_hover", path: old)
                    }
                    ranAnyHover = true
                    hoverAllLiveOnly = hoverAllLiveOnly && tx.liveOnlyRequested
                    applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested, liveOnlyLabel: "onHover")
                }
                if let np = newPath, let newIdx = nodeByPath[np],
                   !flatNodes[newIdx].el.hasKitHoverDelays,
                   let cb = flatNodes[newIdx].el.handlers.onHover {
                    var tx = makeTx(at: now)
                    cb(&state, true, &tx)
                    if !tx.liveOnlyRequested {
                        perfWatch.meter.handler(name: "on_hover", path: np)
                    }
                    ranAnyHover = true
                    hoverAllLiveOnly = hoverAllLiveOnly && tx.liveOnlyRequested
                    applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested, liveOnlyLabel: "onHover")
                }
                isDispatchingHover = false
                if !(ranAnyHover && hoverAllLiveOnly && !hoverVisualNeedsCommit(oldPath: oldPath, newPath: newPath)) {
                    suppressRevealFromHoverCommit = true
                    dirtyCommit(at: now)
                } else if linkChanged || helpTargetChanges(at: pos) {
                    suppressRevealFromHoverCommit = true
                    dirtyCommit(at: now)
                }
            } else if linkChanged || helpTargetChanges(at: pos) {
                dirtyCommit(at: now)
            }
            syncHoverTracks(at: cxSettings.scaledTime(at: now), cut: false, held: false)
        } else if helpTargetChanges(at: pos) {
            dirtyCommit(at: now)
        }
        settleKitHoverDelays(at: pos, now: now)
    }

    public func pointerDown(at pos: Vec2, button: PointerButton = .primary, mods: Mods = .none, at now: Double) {
        frameHadInputSinceLastFrame = true
        releaseHoverHold()
        cancelKitHoverAndRepeatOnPress()
        kitHooks.dragRepeat = nil
        suppressRevealFromHoverCommit = false
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
            if let (node, rect, local) = hitTestDetailed(at: pos, predicate: {
                $0.el.handlers.onSecondaryClick != nil || ($0.el.handlers.onLinkSecondary != nil && self.hasActiveTextLinks($0.el) && self.linkIndex(atPath: $0.path, at: pos) != nil)
            }) {
                if self.hasActiveTextLinks(node.el),
                   let linkIdx = self.linkIndex(atPath: node.path, at: pos),
                   dispatchLinkDown(node: node, linkIdx: linkIdx, at: pos, button: .secondary, mods: mods, at: now) {
                    return
                }
                let press = PointerPress(
                    window: pos,
                    local: local,
                    elementSize: Vec2(rect.width, rect.height),
                    button: .secondary,
                    mods: mods,
                    clicks: 1
                )
                var tx = makeTx(at: now, button: .secondary)
                node.el.handlers.onSecondaryClick?(&state, press, &tx)
                applyTx(tx, at: now)
                return
            } else {
                handleSelectableSecondaryClick(at: pos, at: now)
            }
            return
        }

        playgroundPointerDown(at: pos, at: now)
        let interactiveHit = hitTestDetailed(at: pos) { node in
            let h = node.el.handlers
            if button != .primary {
                guard h.pointerButtons?.contains(button) == true else { return false }
                return h.onClick != nil || h.onClickPress != nil || h.onPointerDown != nil || h.onDrag != nil
            }
            return h.onClick != nil || h.onClickPress != nil || h.onDoubleClick != nil ||
                   h.onPointerDown != nil || h.onDrag != nil || h.dragOut != nil ||
                   node.el.attachedDragOutItem != nil || h.editLens != nil ||
                   self.nodeTakesFocus(node.el) || node.el.pressBg != nil || node.el.pressScaleFactor != nil ||
                   node.el.isModal || (node.el.role == .button && node.el.explicitHit)
        }

        guard let (node, rect, rawLocal) = interactiveHit else {
            recordBareTitlebarPressIfNeeded(at: pos, button: button, now: now)
            if cxSettings.viewDefaults.webFocus, let bgHit = hitTest(at: pos, predicate: { _ in true }) {
                webFocusTabStartPath = bgHit.node.path
            }
            handleSelectablePointerDown(at: pos, button: button, mods: mods, hitInteractiveNode: nil, at: now)
            if let prevFp = focusedPath {
                let prevNode = nodeByPath[prevFp].map { flatNodes[$0] }
                handleKitFocusTransition(prevNode: prevNode, newPath: nil, at: now)
                focusedPath = nil
                focusedKey = nil
                imeReset = true
                dirtyCommit(at: now)
            }
            return
        }
        kitHooks.lastBareTitlebarPress = nil

        if hasActiveTextLinks(node.el), let linkIdx = linkIndex(atPath: node.path, at: pos) {
            handleSelectablePointerDown(at: pos, button: button, mods: mods, hitInteractiveNode: node, at: now)
            if dispatchLinkDown(node: node, linkIdx: linkIdx, at: pos, button: button, mods: mods, at: now) {
                return
            }
        }

        let preservesSel = preservesTextSelectionInChain(node)
        let preservesFocus = preservesFocusOnPressInChain(node)
        let inEditSubtree = isInsideEditLensSubtree(node)
        let onLink = hasActiveTextLinks(node.el)
        handleSelectablePointerDown(at: pos, button: button, mods: mods, hitInteractiveNode: node, at: now)
        pressedPath = node.path
        pressedKey = node.key
        if cxSettings.viewDefaults.webFocus && !preservesSel && !preservesFocus {
            webFocusTabStartPath = node.path
        }
        let isTextBox = node.el.handlers.editLens != nil
        let shouldFocusNode = isTextBox || (!preservesFocus && nodeTakesFocus(node.el))
        var downFocusChanged = false
        if !preservesSel && !onLink && shouldFocusNode {
            if focusedPath != node.path {
                let prevNode = focusedPath.flatMap { nodeByPath[$0] }.map { flatNodes[$0] }
                handleKitFocusTransition(prevNode: prevNode, newPath: node.path, at: now)
                imeReset = true
                downFocusChanged = true
            }
            focusedPath = node.path
            focusedKey = node.key
        } else if !onLink && !inEditSubtree && !preservesFocus && !isTextBox {
            if focusedPath != nil {
                focusedPath = nil
                focusedKey = nil
                imeReset = true
            }
        }

        let sc = presentedScaleByPath[node.path] ?? Vec2(1, 1)
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

        if let onDown = node.el.handlers.onPointerDown {
            var tx = makeTx(at: now, button: button)
            onDown(&state, press, &tx)
            downRanHandler = true
            downAllLiveOnly = downAllLiveOnly && tx.liveOnlyRequested
            applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
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
                startScale: safeSc,
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
                startScale: safeSc,
                elementSize: elemSize,
                clicks: clickCount,
                button: button,
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
                    mods: mods
                ),
                &tx
            )
            downRanHandler = true
            downAllLiveOnly = downAllLiveOnly && tx.liveOnlyRequested
            applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
            armKitDragRepeatIfRequested(path: node.path, windowPos: pos, mods: mods, button: button, now: now)
        }

        let needsPressVisual = downFocusChanged || nodeHasPressVisuals(node) || !downRanHandler || !downAllLiveOnly
        if needsPressVisual {
            dirtyCommit(at: now)
        }
    }

    public func pointerUp(at pos: Vec2, button: PointerButton = .primary, mods: Mods = .none, at now: Double) {
        frameHadInputSinceLastFrame = true
        pointerPosition = pos
        armedDragOut = nil
        kitHooks.dragRepeat = nil
        let releasedPath = pressedPath
        let notePath = releasedPath
        let startedNs = InteractionGate.isOn ? DispatchTime.now().uptimeNanoseconds : 0
        pressedPath = nil
        pressedKey = nil
        let suppressedClickFromSelDrag = handleSelectablePointerUp(at: pos, button: button, at: now)
        let hadPressVisual = releasedPath.flatMap { nodeByPath[$0] }.map { nodeHasPressVisuals(flatNodes[$0]) } ?? false
        var upRanHandler = false
        var upAllLiveOnly = true

        var draggedPastThreshold = suppressedClickFromSelDrag
        if let drag = activeDrag {
            activeDrag = nil
            draggedPastThreshold = suppressedClickFromSelDrag || (!drag.isTextSelectionDrag &&
                (drag.movedBeyondSlop || hypotf(pos.x - drag.startWindow.x, pos.y - drag.startWindow.y) > 4.0))
            if drag.button == .primary && draggedPastThreshold {
                clickCount = 0
                lastClickTime = -.infinity
            }
            if !drag.isTextSelectionDrag, let idx = nodeByPath[drag.path], let onEnd = flatNodes[idx].el.handlers.onDragEnd {
                var tx = makeTx(at: now, button: drag.button)
                onEnd(&state, false, &tx)
                upRanHandler = true
                upAllLiveOnly = upAllLiveOnly && tx.liveOnlyRequested
                applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
            }
        }

        if dispatchLinkUp(at: pos, button: button, mods: mods, suppressed: suppressedClickFromSelDrag, at: now) {
            dirtyCommit(at: now)
            return
        }

        guard let rPath = releasedPath, let idx = nodeByPath[rPath] else {
            if suppressedClickFromSelDrag || hadPressVisual || !upRanHandler || !upAllLiveOnly {
                dirtyCommit(at: now)
            }
            return
        }
        let node = flatNodes[idx]
        let rect = presentedRectByPath[rPath] ?? node.targetRect
        let unturnedLocal = hitGeometryByPath[rPath]?.turn?.unturn(pos) ?? pos
        let press = PointerPress(
            window: pos,
            local: Vec2(unturnedLocal.x - rect.x, unturnedLocal.y - rect.y),
            elementSize: Vec2(rect.width, rect.height),
            button: button,
            mods: mods,
            clicks: button == .primary ? clickCount : 1
        )

        if let onUp = node.el.handlers.onPointerUp {
            var tx = makeTx(at: now, button: button)
            onUp(&state, press, &tx)
            upRanHandler = true
            upAllLiveOnly = upAllLiveOnly && tx.liveOnlyRequested
            applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
        }

        // Fire click / double-click only if pointer released inside the pressed element and not dragged!
        let inside = hitGeometryByPath[rPath]?.contains(pos) ?? halfOpenContains(rect, pos)
        let allowsButton = button == .primary || (button != .secondary && (node.el.handlers.pointerButtons?.contains(button) ?? false))
        if inside && allowsButton && !suppressedClickFromSelDrag && !(draggedPastThreshold && node.el.handlers.onDrag != nil) {
            if button == .primary && clickCount == 2, let onDbl = node.el.handlers.onDoubleClick {
                var tx = makeTx(at: now, button: button)
                onDbl(&state, &tx)
                upRanHandler = true
                upAllLiveOnly = upAllLiveOnly && tx.liveOnlyRequested
                applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
            } else {
                if let onClick = node.el.handlers.onClick {
                    var tx = makeTx(at: now, button: button)
                    onClick(&state, &tx)
                    upRanHandler = true
                    upAllLiveOnly = upAllLiveOnly && tx.liveOnlyRequested
                    applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
                }
                if let onClickP = node.el.handlers.onClickPress {
                    var tx = makeTx(at: now, button: button)
                    onClickP(&state, press, &tx)
                    upRanHandler = true
                    upAllLiveOnly = upAllLiveOnly && tx.liveOnlyRequested
                    applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested)
                }
            }
            if InteractionGate.isOn {
                let action = (button == .primary && clickCount == 2 && node.el.handlers.onDoubleClick != nil)
                    ? "on_double_press"
                    : "on_press"
                if let note = interactionNote(action: action, rank: 3, path: notePath) {
                    let endedNs = DispatchTime.now().uptimeNanoseconds
                    let handlerMs = Double(endedNs >= startedNs ? endedNs - startedNs : 0) / 1_000_000.0
                    perfWatch.interaction.noted(note: note, arrivedNs: startedNs, startedNs: startedNs, handlerMs: handlerMs)
                }
            }
        }

        if suppressedClickFromSelDrag || hadPressVisual || !upRanHandler || !upAllLiveOnly {
            dirtyCommit(at: now)
        }
    }

    /// Recovers a lost primary pointer release (`platform/macos/pointer.rs::pointer_release_lost`).
    /// Cancels an active primary drag at `pos` (preserving click run if within drag slop),
    /// or falls back to `pointerUp`.
    public func pointerReleaseLost(at pos: Vec2, at now: Double = 0.0) {
        if let drag = activeDrag, drag.button == .primary {
            let moved = drag.movedBeyondSlop || hypotf(pos.x - drag.startWindow.x, pos.y - drag.startWindow.y) > 4.0
            activeDrag = nil
            armedDragOut = nil
            pressedPath = nil
            pressedKey = nil
            pointerPosition = pos
            if moved {
                clickCount = 0
                lastClickTime = -.infinity
            }
            if !drag.isTextSelectionDrag,
               let idx = nodeByPath[drag.path],
               let onEnd = flatNodes[idx].el.handlers.onDragEnd {
                var tx = makeTx(at: now, button: .primary)
                onEnd(&state, true, &tx)
                applyTx(tx, at: now)
            }
            dirtyCommit(at: now)
            return
        }
        pointerUp(at: pos, button: .primary, mods: .none, at: now)
    }

    /// Routes wheel / trackpad scroll deltas to custom `onWheel` handlers or the nearest scrollable ancestor.
    public func wheel(_ event: WheelEvent, at pos: Vec2? = nil, now: Double) {
        releaseHoverHold()
        dismissHelp(at: now)
        let targetPos = pos ?? pointerPosition
        if let pos { pointerPosition = pos }

        // Check custom `onWheel` handler first
        if let (customNode, _) = hitTest(at: targetPos, predicate: { $0.el.handlers.onWheel != nil }) {
            var tx = makeTx(at: now)
            let taken = customNode.el.handlers.onWheel?(&state, event, &tx) == true
            Tx.took(taken, &tx)
            if taken {
                applyTx(tx, at: now)
                return
            }
        }

        // Find innermost scrollable container under `targetPos`, chaining up ancestors if at boundary
        // Upstream `scroll_at_axis` ignores non-interactive visual overlay siblings (`drawn_rect.rs`).
        guard let (hitNode, _) = hitTest(at: targetPos, ignoreBlockers: true, predicate: { !$0.el.layout.scrollAxes.isEmpty }) else {
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
                    scrollGlidingPaths.remove(path)
                    markScrollMovedByHand(path: path)
                    scrollRequestsState.stepCancel()
                    scrollMovedSinceLastFrame = true
                    if scrollRequiresCommit {
                        directScrolledPaths.insert(path)
                        pendingCommitKind = pendingCommitKind.instant()
                        dirtyCommit(at: now)
                    } else {
                        directScrolledPaths.remove(path)
                        updateScrollPositions(at: now)
                    }
                    return
                }
            }
            walkIdx = flatNodes[i].parentIndex
        }
    }

    /// Starts an inertial scroll `Decay` fling (`vx`, `vy` in points/sec) on the scroll container under `pos`.
    public func fling(vx: Float = 0, vy: Float, at pos: Vec2? = nil, now: Double) {
        releaseHoverHold()
        dismissHelp(at: now)
        let targetPos = pos ?? pointerPosition
        guard let (scrollNode, _) = hitTest(at: targetPos, ignoreBlockers: true, predicate: { !$0.el.layout.scrollAxes.isEmpty }) else {
            return
        }
        let path = scrollNode.path
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
        // Upstream `pointer.rs:501-509` & `scroll/x.rs:331`: positive velocity moves content down/right (reduces scroll offset).
        _ = scrollStore.fling(nid, Props.SCROLL, from: cur, velocity: Velocity(Vec2(-vx, -vy)), decay: .IOS_NORMAL, at: cxSettings.scaledTime(at: now))
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

    @discardableResult
    public func physicalInput(_ event: PhysicalInput, fallbackKey: KeyEvent? = nil, baseChar: Character? = nil, at now: Double) -> Bool {
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
        currentTime = now
        if needsCommit {
            commitTree(at: now, cut: forceInitialSettle)
            needsCommit = false
            forceInitialSettle = false
        }
        if case .focusLost = event {
            dirChord = .idle
        }

        // Dispatch along focused -> ancestor chain (stopping at inert / modal boundary)
        if let fPath = focusedPath, let fIdx = nodeByPath[fPath] {
            var walkIdx: Int? = fIdx
            while let curIdx = walkIdx {
                if flatNodes[curIdx].effectiveInert { break }
                if let onPhys = flatNodes[curIdx].el.handlers.onPhysicalInput {
                    var tx = makeTx(at: now)
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
                    var tx = makeTx(at: now)
                    if onPhys(&state, event, &tx) {
                        applyTx(tx, at: now)
                        return true
                    }
                }
            }
        }

        if case .key(let physCode, let mods, let pressed, let isRepeat) = event, !isRepeat {
            if let modKey = Self.modifierKey(for: physCode) {
                let (nextChord, flow) = stepDirChord(
                    dirChord,
                    modifier: modKey,
                    pressed: pressed,
                    ctrl: mods.ctrl,
                    shift: mods.shift
                )
                dirChord = nextChord
                if let flow,
                   let fPath = focusedPath,
                   let fEl = focusedInputElement(at: fPath),
                   let editLens = fEl.handlers.editLens {
                    var edit = editLens.get(state)
                    edit.forceDir(flow)
                    editLens.set(&state, edit)
                    dirtyCommit(at: now)
                    return true
                }
                if modifierKeysEnabled {
                    if pressed {
                        if !heldModifierKeys.contains(modKey) {
                            heldModifierKeys.append(modKey)
                        }
                    } else if let idx = heldModifierKeys.firstIndex(of: modKey) {
                        heldModifierKeys.remove(at: idx)
                    }
                    let kev = KeyEvent(key: .modifier(modKey, pressed: pressed), mods: mods)
                    return keyDown(kev, isRepeat: false, at: now)
                }
            } else if pressed {
                dirChord = .idle
            }
        }

        if let fallbackKey {
            if case .key(_, _, let pressed, let isRepeat) = event {
                if !pressed {
                    return keyUp(fallbackKey, at: now)
                }
                return keyDown(fallbackKey, isRepeat: isRepeat, at: now)
            }
            return keyDown(fallbackKey, at: now)
        }
        return false
    }

    /// Synthesizes key-up modifier events for all currently held modifier keys (`overlay::hide` / blur).
    public func releaseHeldModifiers(at now: Double = 0.0) {
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
        frameHadInputSinceLastFrame = true
        let prevByKeys = kitHooks.isDispatchingByKeys
        kitHooks.isDispatchingByKeys = true
        let prevRepeat = currentKeyRepeat
        currentKeyRepeat = isRepeat
        defer {
            kitHooks.isDispatchingByKeys = prevByKeys
            currentKeyRepeat = prevRepeat
        }
        suppressRevealFromHoverCommit = false
        dismissHelp(at: now)
        // 1. Escape cancels an in-progress drag and restores pre-drag state!
        if ev.key == .escape, let drag = activeDrag {
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
        if !isRepeat {
            pressedKeyFocusPath = focusedPath
        }

        if playgroundNav(ev, isRepeat: isRepeat, at: now) {
            return true
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
                        var tx = makeTx(at: now)
                        if onKey(&state, ev, &tx) {
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
                if let onInputKey = fNode.el.handlers.onInputKey {
                    var tx = makeTx(at: now)
                    let handled = onInputKey(&state, ev, &tx)
                    if Tx.took(handled, &tx) {
                        applyTx(tx, at: now, markDirtyIfNotLiveOnly: true)
                        return true
                    }
                    applyTx(tx, at: now, markDirtyIfNotLiveOnly: false)
                }
                if ev.mods.primaryCommand, (ev.key == .command("v") || ev.key == .text("v") || ev.key == .text("V")) {
                    let pasteContent = boundClipboard?.readRich(sanitizeUntrustedHTML: true).content ?? clipboard
                    if deliverPaste(pasteContent, at: now) {
                        return true
                    }
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
                if !edit.isSecure && (ev.key == .arrowLeft || ev.key == .arrowRight) {
                    var inputStyle = fNode.el.textStyle
                    if edit.multiline { inputStyle.wrap = .wrap }
                    if let fDir = edit.forcedDir { inputStyle.direction = fDir }
                    let pad = fNode.el.layout.padding
                    let innerW = max(0, fNode.targetRect.width - pad.left - pad.right)
                    editLayout = textSystem.shape(
                        text: edit.displayString,
                        style: inputStyle,
                        maxWidth: edit.multiline ? innerW : nil,
                        pixelScale: pixelScale,
                        emitGlyphs: false
                    )
                }
                let outcome = edit.handleKey(ev, layout: editLayout)
                switch outcome {
                case .ignored:
                    if edit.didRequestBlur && activeModalPath == nil {
                        if !isRepeat {
                            focusedPath = nil
                            focusedKey = nil
                            syncedEditFocusedPaths.removeAll()
                            dirtyCommit(at: now)
                        }
                        return true
                    }
                    break
                case .navigation:
                    editLens.set(&state, edit)
                    dirtyCommit(at: now)
                    return true
                case .modified:
                    editLens.set(&state, edit)
                    var tx = makeTx(at: now)
                    if fNode.el.layoutAnim == nil {
                        tx.instant()
                    }
                    if let onChange = fNode.el.handlers.onTextChange {
                        onChange(&state, edit.text, &tx)
                    }
                    applyTx(tx, at: now)
                    dirtyCommit(at: now)
                    return true
                case .submit:
                    editLens.set(&state, edit)
                    if let onSubmit = fNode.el.handlers.onTextSubmit {
                        var tx = makeTx(at: now)
                        tx.animated()
                        onSubmit(&state, edit.text, &tx)
                        applyTx(tx, at: now)
                        dirtyCommit(at: now)
                        return true
                    }
                    // Without `onTextSubmit`, let Return fall through to `.defaultButton()` if one exists.
                case .copy(let copied):
                    editLens.set(&state, edit)
                    clipboard = ClipboardContent(copied, html: preCopyHTML)
                    richClipboard = RichClipboardPayload(content: clipboard)
                    if let onChange = fNode.el.handlers.onTextChange {
                        var tx = makeTx(at: now)
                        onChange(&state, edit.text, &tx)
                        applyTx(tx, at: now)
                    }
                    dirtyCommit(at: now)
                    return true
                }
            }

            // Space/Enter/ContextMenu activates focused text links first, then buttons/rows (`takesReturn`).
            if ev.mods == .none && (ev.key == .space || ev.key == .enter) && !isRepeat {
                if activateFocusedLink(at: now) {
                    return true
                }
            }
            if ev.mods == .none && ev.key == .contextMenu && !isRepeat {
                if activateFocusedLinkSecondary(at: now) {
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
                    var tx = makeTx(at: now)
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
                    var tx = makeTx(at: now)
                    onClickPress(&state, press, &tx)
                    applyTx(tx, at: now)
                    return true
                }
            }

            if handleFocusedStepKey(ev, node: fNode, at: now) {
                return true
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
                var tx = makeTx(at: now)
                dismiss(&state, &tx)
                applyTx(tx, at: now)
            }
            dirtyCommit(at: now)
            return true
        }

        // 2c. Non-editor `Cmd+V` falls through to active modal / root `onPaste` when unhandled by focused `onKey`.
        if ev.mods.primaryCommand, (ev.key == .command("v") || ev.key == .text("v") || ev.key == .text("V")) {
            let pasteContent = boundClipboard?.readRich(sanitizeUntrustedHTML: true).content ?? clipboard
            if deliverPaste(pasteContent, at: now) {
                return true
            }
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
                var tx = makeTx(at: now)
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
                var tx = makeTx(at: now)
                onClickPress(&state, press, &tx)
                applyTx(tx, at: now)
                return true
            }
        }

        // 4. Root / global `onKey` handler (unhandled keys bubble to `globalOnKey`; ShortcutRegistry stays gated under modal)
        if activeModalPath == nil, let live = playgroundLive {
            if !live.typing(appState: state), let handled = playgroundAppKey(ev, at: now), handled {
                return true
            }
        } else if playgroundLive == nil, let globalOnKey {
            var tx = makeTx(at: now)
            let taken = globalOnKey(&state, ev, &tx)
            Tx.took(taken, &tx)
            if taken {
                applyTx(tx, at: now, liveOnlyLabel: "onKey")
                return true
            }
        }

        // 5. Shortcut registry dispatch (only when no active modal blocks global shortcuts)
        if activeModalPath == nil, let registry = shortcutRegistry {
            let result = registry.dispatch(ev)
            if result != .unhandled {
                dirtyCommit(at: now)
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

    /// Pages the focused, hovered, or first overflowing vertical scroll container on PageUp/PageDown/Home/End (`keys.rs:116-155`).
    private func pageScroll(_ ev: KeyEvent, at now: Double) -> Bool {
        switch ev.key {
        case .pageUp, .pageDown, .home, .end:
            break
        default:
            return false
        }
        if ev.mods.cmd || ev.mods.alt || ev.mods.ctrl { return false }

        let staged = playgroundLive?.pressing == true
        func pageable(_ idx: Int) -> Bool {
            guard flatNodes.indices.contains(idx) else { return false }
            let node = flatNodes[idx]
            guard node.el.layout.scrollAxes.contains(.vertical),
                  !node.effectiveInert,
                  (scrollMaxExtents[node.path]?.y ?? 0) > 0.5 else {
                return false
            }
            if case .exiting = scene.phase(node.nodeId) { return false }
            if staged && !isNodeUnder(idx, predicate: { Self.isPlaygroundStageKey($0) }) {
                return false
            }
            return true
        }
        func around(_ startIdx: Int) -> Int? {
            var cur: Int? = startIdx
            while let i = cur, flatNodes.indices.contains(i) {
                if pageable(i) { return i }
                cur = flatNodes[i].parentIndex
            }
            return nil
        }

        let focusedIdx: Int? = {
            guard var path = focusedPath else { return nil }
            while true {
                if let idx = nodeByPath[path] { return idx }
                guard let slash = path.lastIndex(of: "/") else { return nil }
                path = String(path[..<slash])
            }
        }()
        let hoveredIdx = hitTest(at: pointerPosition)?.node.index
        guard let targetIdx = focusedIdx.flatMap(around)
            ?? hoveredIdx.flatMap(around)
            ?? flatNodes.indices.first(where: pageable) else {
            return false
        }

        let node = flatNodes[targetIdx]
        let path = node.path
        let maxY = scrollMaxExtents[path]?.y ?? 0
        let viewportH = scrollViewportSizes[path]?.y ?? node.targetRect.height
        let page = max(0.0, viewportH * 0.9)
        var cur = scrollOffsets[path] ?? .zero
        let targetY: Float
        switch ev.key {
        case .pageUp: targetY = cur.y - page
        case .pageDown: targetY = cur.y + page
        case .home: targetY = 0
        default: targetY = maxY
        }
        cur.y = targetY.clamped(to: 0...maxY)
        scrollOffsets[path] = cur
        let nid = NodeId.hash("scroll:" + path)
        scrollStore.snap(nid, Props.SCROLL, to: cur)
        if node.el.layout.stickBottom {
            if maxY - cur.y <= 2.0 { wasPinnedToBottom.insert(path) } else { wasPinnedToBottom.remove(path) }
        }
        dirtyCommit(at: now)
        return true
    }

    public func paste(_ content: ClipboardContent, at now: Double) {
        deliverPaste(content, at: now)
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
        #if os(macOS) && canImport(AppKit)
        out["accessibility"] = AccessibilityDump.dictionary(from: accessibilitySnapshot(), isRoot: true)
        #endif
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
        let builtinNames = [
            "opacity", "frame", "offset", "scale", "rotation", "blur",
            "radius", "fill", "mask", "scroll", "presence", "travel",
        ]
        var seen = Set<String>()
        var out: [(path: String, prop: String, active: Bool)] = []
        for (track, node, prop) in scene.store.touchedTracks() {
            let path = nodeById[node]?.path ?? "node:\(node.rawValue)"
            let propName: String
            let raw = Int(prop.rawValue)
            if raw < builtinNames.count {
                propName = builtinNames[raw]
            } else {
                propName = "prop:\(raw)"
            }
            let active = scene.store.isActive(track)
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
        currentTime = now
        fileDropState.handle(phase)
        flightRecorder.record(kind: "fileDrop", at: now)
        routeFileDropPhase(phase, at: now)
        if let handler = onFileDrop {
            var tx = makeTx(at: now)
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

    internal func applyTx(_ tx: Tx, at now: Double, markDirtyIfNotLiveOnly: Bool = true, external: Bool = true, liveOnlyLabel: String = "handler") {
        if let cb = tx.clipboardWrite {
            clipboard = cb
            richClipboard = RichClipboardPayload(content: cb)
            writeCopyToBoundClipboard(text: cb.text, rich: nil)
        }
        if let rich = tx.runtimeActions["richClipboardWrite"] as? RichClipboardPayload {
            richClipboard = rich
            clipboard = rich.content
            writeCopyToBoundClipboard(text: rich.content.text, rich: rich)
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
        if tx.blurFocusRequested {
            if let prevFp = focusedPath {
                let prevNode = nodeByPath[prevFp].map { flatNodes[$0] }
                handleKitFocusTransition(prevNode: prevNode, newPath: nil, at: now)
            }
            pendingTxBlurRequested = true
            pendingTxFocusKey = nil
            kitHooks.pendingTxFocusVisible = nil
            focusedPath = nil
            focusedKey = nil
            syncedEditFocusedPaths.removeAll()
        } else if let fk = tx.requestedFocusKey {
            let matchedNode = flatNodes.first(where: { $0.key == fk })
            if let prevFp = focusedPath, matchedNode?.path != prevFp {
                let prevNode = nodeByPath[prevFp].map { flatNodes[$0] }
                handleKitFocusTransition(prevNode: prevNode, newPath: matchedNode?.path, at: now)
            }
            pendingTxBlurRequested = false
            pendingTxFocusKey = fk
            kitHooks.pendingTxFocusVisible = tx.requestedFocusVisible
            focusVisible = tx.requestedFocusVisible
            focusedKey = fk
            if let match = matchedNode {
                focusedPath = match.path
            }
        }
        for prefix in tx.invalidateMemoPrefixes {
            MemoCache.shared.invalidateByPrefix(prefix)
        }
        pendingCommitKind = pendingCommitKind.merge(tx.commitKind)
        if let m = tx.motionSource {
            pendingCommitMotion = m
        }
        if let cm = tx.colorMotionSpring {
            pendingColorMotionSpring = cm
        }
        if tx.followEdgeRequested {
            pendingFollowEdge = true
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
        let nonOffsetCommitRequests = tx.followEdgeRequested
            || tx.pasteRequested
            || !tx.scrollRevealRequests.isEmpty
            || !tx.scrollBottomRequests.isEmpty
            || !tx.scrollPageRequests.isEmpty
            || !tx.keepOnScreenKeys.isEmpty
            || !tx.invalidateMemoPrefixes.isEmpty
            || tx.commitKind.lands
        let canFastApplyOffsets = !tx.scrollOffsetRequests.isEmpty
            && tx.scrollOffsetRequests.allSatisfy { !$0.anchor }
            && (!markDirtyIfNotLiveOnly || tx.liveOnlyRequested)
            && !tx.isForceCommitRequested
            && !nonOffsetCommitRequests
            && !flatNodes.isEmpty
            && !scrollRequiresCommit
        if canFastApplyOffsets {
            var anySnapped = false
            for req in tx.scrollOffsetRequests {
                guard let match = flatNodes.first(where: { !$0.el.layout.scrollAxes.isEmpty && selectsElementSelector(req.key, path: $0.path, key: $0.key) }) else {
                    continue
                }
                let path = match.path
                let maxExt = scrollMaxExtents[path] ?? .zero
                let cur = scrollOffsets[path] ?? .zero
                let clamped = Vec2(
                    max(0, min(maxExt.x, req.x ?? cur.x)),
                    max(0, min(maxExt.y, req.y ?? cur.y))
                )
                let nid = NodeId.hash("scroll:" + path)
                if let glide = req.glide, !reducedMotion {
                    if scrollStore.get(nid, Props.SCROLL) == nil {
                        scrollStore.snap(nid, Props.SCROLL, to: cur)
                    }
                    scrollStore.set(nid, Props.SCROLL, to: clamped, anim: .spring(glide), at: cxSettings.scaledTime(at: now))
                    scrollGlidingPaths.insert(path)
                } else {
                    scrollStore.snap(nid, Props.SCROLL, to: clamped)
                    scrollOffsets[path] = clamped
                    scrollGlidingPaths.remove(path)
                    anySnapped = true
                }
                markScrollMovedByHand(path: path)
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
            for (src, dst) in tx.textFlights {
                pendingTextFlights.append(makePendingFlightRequest(source: src, destination: dst, motionSpring: springOverride))
            }
            dirtyCommit(at: now, external: external)
        }
        if !tx.launches.isEmpty {
            let springOverride = tx.motionSpringRequest
            for (src, dst) in tx.launches {
                pendingLaunches.append(makePendingFlightRequest(source: src, destination: dst, motionSpring: springOverride))
            }
            dirtyCommit(at: now, external: external)
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
        if tx.pasteRequested {
            pendingPasteRequests += 1
        }
        let hasCommitRequests = nonOffsetCommitRequests || (!canFastApplyOffsets && !tx.scrollOffsetRequests.isEmpty)
        if tx.liveOnlyRequested {
            if recordLiveOnlySkip(handler: liveOnlyLabel, at: now) {
                dirtyCommit(at: now, external: external)
            }
        } else if markDirtyIfNotLiveOnly || tx.isForceCommitRequested || hasCommitRequests {
            dirtyCommit(at: now, external: external)
        }
    }

    /// Updates viewport and scale from a user/host window resize, landing running motion (`set_viewport`).
    public func setViewport(_ newViewport: Vec2, pixelScale newScale: Float? = nil) {
        let targetScale = newScale ?? cxSettings.zoomState.windowScale
        cxSettings.zoomState.window = newViewport
        cxSettings.zoomState.windowScale = max(targetScale, 0.5)
        let (viewVP, viewScale) = cxSettings.zoomState.view()
        if fitHeight && windowResting && fitWindowState.resized(to: viewVP.y, current: viewport.y) {
            needsCommit = true
            userResizeNeedsCut = false
        }
        if fitHeight && viewVP.x == viewport.x && viewScale == pixelScale {
            suppressViewportCommitFlag = true
            viewport = viewVP
            suppressViewportCommitFlag = false
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
            suppressViewportCommitFlag = true
            viewport = viewVP
            suppressViewportCommitFlag = false
            return
        }
        if viewVP != viewport || viewScale != pixelScale {
            let vpChanged = viewVP != viewport
            cxSettings.isApplyingZoom = true
            viewport = viewVP
            pixelScale = viewScale
            cxSettings.isApplyingZoom = false
            needsCommit = true
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
            let rootEl = view(state, &cx)
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
    public var isStale: Bool { needsCommit }

    /// Runs `poll(state, now, tx)` when attached. Only dirties the commit if `poll` returns `true`
    /// or `tx.commit()` was explicitly called.
    @discardableResult
    public func runPoll(at now: Double) -> Bool {
        RuntimeIdScope.$current.withValue(runtimeId) {
            guard let pollFn = poll else { return false }
            var tx = makeTx(at: now)
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
            if shouldDirty {
                perfWatch.meter.poll()
            }
            applyTx(tx, at: now, markDirtyIfNotLiveOnly: shouldDirty)
            return changed
        }
    }

    /// Mutates state via `body`, always rebuilding unless `tx.liveOnlyRequested` is true.
    public func update(at now: Double? = nil, _ body: (_ state: inout State, _ tx: inout Tx) -> Void) {
        RuntimeIdScope.$current.withValue(runtimeId) {
            suppressRevealFromHoverCommit = false
            let t = now ?? currentTime
            var tx = makeTx(at: t)
            if let scope = turnScope {
                scope(&state) { s in body(&s, &tx) }
            } else {
                body(&state, &tx)
            }
            applyTx(tx, at: t, markDirtyIfNotLiveOnly: true)
        }
    }

    /// Conditionally mutates state via `body`. Only dirties commit when `body` returns `true`
    /// or `tx.commit()` was explicitly called; side-effect requests (`wakeAfter`, `copy`, `quit`,
    /// etc.) still apply without forcing a rebuild (`app.rs:1240-1251`).
    @discardableResult
    public func updateIf(at now: Double? = nil, _ body: (_ state: inout State, _ tx: inout Tx) -> Bool) -> Bool {
        RuntimeIdScope.$current.withValue(runtimeId) {
            suppressRevealFromHoverCommit = false
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
            applyTx(tx, at: t, markDirtyIfNotLiveOnly: changed || tx.isForceCommitRequested)
            return changed
        }
    }

    /// Sets `srgbBlend` and dirties the tree if changed.
    public func setSrgbBlend(_ enabled: Bool, at now: Double? = nil) {
        guard srgbBlend != enabled else { return }
        srgbBlend = enabled
        dirtyCommit(at: now ?? currentTime)
    }

    /// Runs `poll` while the window is hidden (`Runtime::poll_hidden`), returning `true` if
    /// the view or pending scroll/flight state became out of date.
    @discardableResult
    public func pollHidden(at now: Double) -> Bool {
        currentTime = now
        let changed = runPoll(at: now)
        return changed
            || needsCommit
            || !pendingScrollBottoms.isEmpty
            || !pendingScrollReveals.isEmpty
            || !pendingTextFlights.isEmpty
            || !pendingLaunches.isEmpty
    }

    internal func focusedInputElement(at path: String) -> El<State>? {
        if let idx = nodeByPath[path], idx < flatNodes.count {
            return flatNodes[idx].el
        }
        return virtualInputs[path]?.el
    }

    private func applyFocusedTextEditKey(_ ev: KeyEvent, el: El<State>, layout: ShapedText?, at now: Double) -> Bool {
        guard let editLens = el.handlers.editLens else { return false }
        var edit = editLens.get(state)
        if el.isSecure {
            edit.isSecure = true
            if el.isRevealed { edit.isRevealed = true }
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
        let outcome = edit.handleKey(ev, layout: layout)
        switch outcome {
        case .ignored:
            return false
        case .navigation:
            editLens.set(&state, edit)
            dirtyCommit(at: now)
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
            dirtyCommit(at: now)
            return true
        case .submit:
            editLens.set(&state, edit)
            if let onSubmit = el.handlers.onTextSubmit {
                var tx = makeTx(at: now)
                tx.animated()
                onSubmit(&state, edit.text, &tx)
                applyTx(tx, at: now)
                dirtyCommit(at: now)
                return true
            }
            return false
        case .copy(let copied):
            editLens.set(&state, edit)
            clipboard = ClipboardContent(copied, html: preCopyHTML)
            richClipboard = RichClipboardPayload(content: clipboard)
            if let onChange = el.handlers.onTextChange {
                var tx = makeTx(at: now)
                onChange(&state, edit.text, &tx)
                applyTx(tx, at: now)
            }
            dirtyCommit(at: now)
            return true
        }
    }

    /// Delivers a window focus transition to `onFocus`, deduplicating redundant transitions and
    /// leaving the runtime un-staled when `onFocus` is unset (`app.rs:973-992`).
    public func dispatchFocus(_ focused: Bool, at now: Double? = nil) {
        guard windowFocused != focused else { return }
        let t = now ?? currentTime
        let prevStale = needsCommit
        windowFocused = focused
        if !focused {
            finishComposition(at: t)
        }
        if let hook = onFocus {
            if playgroundDispatchFocus(focused, hook: hook, at: t) {
                return
            }
            update(at: t) { s, tx in hook(&s, focused, &tx) }
        } else {
            needsCommit = prevStale
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

    /// Returns the focused input caret rect in window coordinates, if available.
    public func focusedCaretRect() -> MotionRect? {
        guard let c = (currentFocusedCaret() ?? cxSettings.lastCommittedCaret)?.rect,
              c.count >= 4 else {
            return nil
        }
        return MotionRect.fromXYWH(c[0], c[1], c[2], c[3])
    }

    /// Commits any open preedit composition on focus loss or window deactivation (`Runtime::finish_composition`).
    public func finishComposition(at now: Double? = nil) {
        let t = now ?? currentTime
        imeReset = true
        guard let fp = focusedPath,
              let el = focusedInputElement(at: fp),
              let editLens = el.handlers.editLens else {
            _ = dispatchIme(.cancel, at: t)
            return
        }
        var edit = editLens.get(state)
        if let activePreedit = edit.preedit?.text, edit.finishPreedit() {
            editLens.set(&state, edit)
            if let onChange = el.handlers.onTextChange {
                var tx = Tx()
                onChange(&state, edit.text, &tx)
                applyTx(tx, at: t)
            }
            _ = dispatchIme(.commit(activePreedit), at: t)
            dirtyCommit(at: t)
        }
    }

    /// Applies an AppKit/OS `ImeEvent` to the focused `TextEdit` and forwards to `onIme` (`Runtime::ime`).
    @discardableResult
    public func dispatchImeEvent(_ event: ImeEvent, at now: Double? = nil) -> Bool {
        frameHadInputSinceLastFrame = true
        let imeStartNs = InteractionGate.isOn ? DispatchTime.now().uptimeNanoseconds : 0
        let t = now ?? currentTime
        var handledByEdit = false
        if let fp = focusedPath,
           nodeByPath[fp].map({ !flatNodes[$0].effectiveInert }) ?? true,
           let el = focusedInputElement(at: fp),
           let editLens = el.handlers.editLens {
            var edit = editLens.get(state)
            if el.isSecure {
                edit.isSecure = true
                if el.isRevealed { edit.isRevealed = true }
            }
            let outcome = edit.applyIme(event)
            switch outcome {
            case .ignored:
                break
            case .navigation:
                editLens.set(&state, edit)
                dirtyCommit(at: t)
                handledByEdit = true
            case .modified:
                editLens.set(&state, edit)
                if let onChange = el.handlers.onTextChange {
                    var tx = Tx()
                    onChange(&state, edit.text, &tx)
                    applyTx(tx, at: t)
                }
                dirtyCommit(at: t)
                handledByEdit = true
            case .submit, .copy:
                editLens.set(&state, edit)
                dirtyCommit(at: t)
                handledByEdit = true
            }
        }

        let shellIme: Ime
        switch event {
        case .preedit(let str, let cursorUTF8, let clauses):
            shellIme = .preedit(ImePreedit(text: str, cursorUTF8: cursorUTF8, clauses: clauses))
        case .commit(let str):
            shellIme = .commit(str)
        case .select:
            return handledByEdit
        case .enabled:
            shellIme = .enabled
        case .disabled:
            shellIme = .disabled
        }
        let handledByHook = dispatchIme(shellIme, at: t)
        if InteractionGate.isOn,
           let note = interactionNote(action: "key_edit", rank: 3, path: focusedPath) {
            let endedNs = DispatchTime.now().uptimeNanoseconds
            let handlerMs = Double(endedNs >= imeStartNs ? endedNs - imeStartNs : 0) / 1_000_000.0
            perfWatch.interaction.noted(note: note, arrivedNs: imeStartNs, startedNs: imeStartNs, handlerMs: handlerMs)
        }
        return handledByEdit || handledByHook
    }

    /// Resolves the pointer cursor shape under the current pointer / press target (`Runtime::cursor`).
    public func currentCursor() -> Cursor {
        guard pointerPosition.x >= 0,
              pointerPosition.y >= 0,
              pointerPosition.x < viewport.x,
              pointerPosition.y < viewport.y else {
            return .default
        }

        let targetPath = pressedPath ?? hoveredPath
        var curIdx: Int?
        if let tp = targetPath, let idx = nodeByPath[tp], !flatNodes[idx].effectiveInert {
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
            if leafEl.handlers.editLens != nil || leafEl.role == .textInput {
                return .text
            }
            if leafEl.role == .link || leafEl.a11yHref != nil {
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

    /// Updates host live visibility (`Runtime::set_live_visible`), notifying `onVisibility` after first commit.
    public func setLiveVisible(_ visible: Bool, at now: Double? = nil) {
        let changed = (visible != liveVisible)
        liveVisible = visible
        setParityLiveWakeVisible(visible)
        if changed && commitCount > 0 {
            dispatchVisibility(visible, at: now)
        }
    }

    /// Executes a hidden or covered wake (`Runtime::hidden_wake`): flushes queued input on a zero-advance frame
    /// or runs `poll` without building the view tree, returning whether the drawn frame is invalidated.
    @discardableResult
    public func hiddenWake(at now: Double? = nil) -> Bool {
        let t = now ?? currentTime
        if hasPendingInput {
            let prevCommits = commitCount
            _ = frame(at: t)
            if hasPendingInput {
                _ = frame(at: t)
            }
            return commitCount != prevCommits
        }
        let pollChanged = runPoll(at: t)
        return pollChanged || needsCommit
    }

    /// Snaps all in-flight transitions and reveals before the next frame (`Runtime::settle_all`).
    public func settleAll() {
        forceInitialSettle = true
        needsCommit = true
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
