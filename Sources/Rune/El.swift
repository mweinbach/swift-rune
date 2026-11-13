import Foundation
import RuneMotion
import RuneRef
#if canImport(simd)
import simd
#endif

/// Mouse / pointer button (`rune::PointerButton`).
public enum PointerButton: String, Sendable, Hashable, Codable {
    case primary
    case secondary
    case middle
    case back
    case forward
}

/// Gesture phase (`rune::Phase`).
public enum GesturePhase: String, Sendable, Hashable, Codable {
    case began
    case changed
    case ended
    case cancelled
}

/// Pointer press coordinates in window and element-local space (`rune::PointerPress`).
public struct PointerPress: Sendable, Equatable {
    public var window: Vec2
    public var local: Vec2
    public var elementSize: Vec2
    public var button: PointerButton
    public var mods: Mods
    public var clicks: Int

    public init(
        window: Vec2,
        local: Vec2,
        elementSize: Vec2,
        button: PointerButton = .primary,
        mods: Mods = .none,
        clicks: Int = 1
    ) {
        self.window = window
        self.local = local
        self.elementSize = elementSize
        self.button = button
        self.mods = mods
        self.clicks = clicks
    }
}

/// Drag event payload delivered to `onDrag` (`rune::Drag`).
public struct Drag: Sendable, Equatable {
    /// Current pointer position in window points.
    public var window: Vec2
    /// Current pointer position relative to the dragged element's top-left origin.
    public var local: Vec2
    /// Total displacement `(window - startWindow)` since pointer-down.
    public var delta: Vec2
    /// Initial pointer-down position relative to element origin.
    public var startLocal: Vec2
    /// Dragged element's `(width, height)`.
    public var size: Vec2
    /// Click count on press (`1` = normal drag, `2` = double-click-and-drag word selection).
    public var clicks: Int
    public var mods: Mods

    public init(
        window: Vec2,
        local: Vec2,
        delta: Vec2,
        startLocal: Vec2,
        size: Vec2,
        clicks: Int = 1,
        mods: Mods = .none
    ) {
        self.window = window
        self.local = local
        self.delta = delta
        self.startLocal = startLocal
        self.size = size
        self.clicks = clicks
        self.mods = mods
    }
}

/// Wheel / trackpad scroll event (`rune::WheelEvent`).
public struct WheelEvent: Sendable, Equatable {
    public var dx: Float
    public var dy: Float
    public var precise: Bool
    public var phase: GesturePhase
    public var mods: Mods

    public init(
        dx: Float = 0,
        dy: Float = 0,
        precise: Bool = true,
        phase: GesturePhase = .changed,
        mods: Mods = .none
    ) {
        self.dx = dx
        self.dy = dy
        self.precise = precise
        self.phase = phase
        self.mods = mods
    }
}

/// Transaction handle passed into every event handler (`rune::Tx`).
public struct Tx {
    public internal(set) var liveOnlyRequested: Bool = false
    public internal(set) var settleRequested: Bool = false
    public internal(set) var requestedFocusKey: String? = nil
    public internal(set) var blurFocusRequested: Bool = false
    public internal(set) var clipboardWrite: ClipboardContent? = nil
    public internal(set) var scrollToRequests: [(key: String, offset: Vec2, animated: Bool)] = []
    public internal(set) var windowTitle: String? = nil
    public internal(set) var quitRequested: Bool = false
    public internal(set) var textFlights: [(source: String, destination: String)] = []
    public internal(set) var launches: [(source: String, destination: String)] = []
    public internal(set) var unclippedFlightsRequested: Bool = false
    internal var runtimeActions: [String: Any] = [:]

    public init() {}

    /// Declares that this handler only updated `Live<T>` sources and does NOT need a view rebuild
    /// or layout pass on this frame!
    public mutating func liveOnly() {
        liveOnlyRequested = true
    }

    /// Cuts all animations created by this state commit immediately to rest without springing.
    public mutating func settle() {
        settleRequested = true
    }

    /// Moves keyboard focus to the element with `.key(targetKey)`.
    public mutating func focus(_ targetKey: String) {
        requestedFocusKey = targetKey
        blurFocusRequested = false
    }

    /// Clears keyboard focus.
    public mutating func blur() {
        blurFocusRequested = true
        requestedFocusKey = nil
    }

    /// Copies text to the system / headless clipboard.
    public mutating func copyText(_ text: String) {
        clipboardWrite = ClipboardContent(text)
    }

    /// Scrolls the scroll container `.key(key)` to `offset`.
    public mutating func scrollTo(_ key: String, offset: Vec2, animated: Bool = true) {
        scrollToRequests.append((key, offset, animated))
    }

    public mutating func setTitle(_ title: String) {
        windowTitle = title
    }

    public mutating func quit() {
        quitRequested = true
    }

    public mutating func flyText(_ source: String, to destination: String) {
        textFlights.append((source, destination))
    }

    public mutating func launch(_ source: String, to destination: String) {
        launches.append((source, destination))
    }

    public mutating func unclippedFlights() {
        unclippedFlightsRequested = true
    }
}

/// Read-only view-building context (`rune::Cx`).
public struct Cx<State> {
    public let viewport: Vec2
    public let pixelScale: Float
    public let systemDark: Bool
    public let reducedMotion: Bool
    public let windowFocused: Bool
    public let focusedKey: String?
    public let hoveredKey: String?
    public let pressedKey: String?
    public let waker: Waker
    fileprivate let scrollLookup: (String) -> Vec2
    fileprivate let scrollMaxLookup: (String) -> Vec2
    fileprivate let viewportSizeLookup: (String) -> Vec2
    fileprivate let contentSizeLookup: (String) -> Vec2
    fileprivate let layoutRectLookup: (String) -> MotionRect?

    public init(
        viewport: Vec2,
        pixelScale: Float = 2.0,
        systemDark: Bool = true,
        reducedMotion: Bool = false,
        windowFocused: Bool = true,
        focusedKey: String? = nil,
        hoveredKey: String? = nil,
        pressedKey: String? = nil,
        waker: Waker = Waker(),
        scrollLookup: @escaping (String) -> Vec2 = { _ in .zero },
        scrollMaxLookup: @escaping (String) -> Vec2 = { _ in .zero },
        viewportSizeLookup: @escaping (String) -> Vec2 = { _ in .zero },
        contentSizeLookup: @escaping (String) -> Vec2 = { _ in .zero },
        layoutRectLookup: @escaping (String) -> MotionRect? = { _ in nil }
    ) {
        self.viewport = viewport
        self.pixelScale = pixelScale
        self.systemDark = systemDark
        self.reducedMotion = reducedMotion
        self.windowFocused = windowFocused
        self.focusedKey = focusedKey
        self.hoveredKey = hoveredKey
        self.pressedKey = pressedKey
        self.waker = waker
        self.scrollLookup = scrollLookup
        self.scrollMaxLookup = scrollMaxLookup
        self.viewportSizeLookup = viewportSizeLookup
        self.contentSizeLookup = contentSizeLookup
        self.layoutRectLookup = layoutRectLookup
    }

    public func isFocused(_ key: String) -> Bool {
        focusedKey == key
    }

    public func isHovered(_ key: String) -> Bool {
        hoveredKey == key
    }

    public func isPressed(_ key: String) -> Bool {
        pressedKey == key
    }

    public func scrollOffset(of key: String) -> Vec2 {
        scrollLookup(key)
    }

    public func scrollMax(of key: String) -> Vec2 {
        scrollMaxLookup(key)
    }

    public func viewportSize(of key: String) -> Vec2 {
        viewportSizeLookup(key)
    }

    public func contentSize(of key: String) -> Vec2 {
        contentSizeLookup(key)
    }

    public func layoutRect(of key: String) -> MotionRect? {
        layoutRectLookup(key)
    }

    public func layoutSize(of key: String) -> Vec2? {
        guard let r = layoutRectLookup(key) else { return nil }
        return Vec2(r.width, r.height)
    }

    public func focusColor() -> Color {
        Tok.accent(0, dark: systemDark)
    }
}

/// Accessibility / semantic role tag (`rune::RoleTag`).
public enum ElementRole: String, Sendable, Hashable, Codable {
    case group = "group"
    case text = "text"
    case button = "button"
    case checkbox = "checkbox"
    case switchControl = "switch"
    case radio = "radio"
    case tab = "tab"
    case textInput = "textbox"
    case slider = "slider"
    case progress = "progressbar"
    case listItem = "listitem"
    case heading = "heading"
    case dialog = "dialog"
    case menu = "menu"
    case menuItem = "menuitem"
    case image = "img"
    case icon = "icon"
    case separator = "separator"
    case combobox = "combobox"
    case listbox = "listbox"
    case option = "option"
    case tree = "tree"
    case treeItem = "treeitem"
    case grid = "grid"
    case row = "row"
    case gridCell = "gridcell"
    case columnHeader = "columnheader"
    case radiogroup = "radiogroup"
    case tabList = "tablist"
    case tooltip = "tooltip"
    case alert = "alert"
    case region = "region"
    case main = "main"
    case link = "link"
}

/// Live property binding entry attached to an `El`.
struct BoundLiveProperty: Sendable {
    enum Target: Sendable, Hashable {
        case opacity
        case scale
        case blur
        case offset
        case fill
        case rect
        case trim
    }

    var target: Target
    var source: LiveSource
    var spring: Spring?
    var restSpring: Spring?
}

/// Type-erased event handlers parameterized on app `State`.
public struct ElementHandlers<State> {
    public var onClick: ((inout State, inout Tx) -> Void)?
    public var onClickPress: ((inout State, PointerPress, inout Tx) -> Void)?
    public var onDoubleClick: ((inout State, inout Tx) -> Void)?
    public var onSecondaryClick: ((inout State, PointerPress, inout Tx) -> Void)?
    public var onPointerDown: ((inout State, PointerPress, inout Tx) -> Void)?
    public var onPointerUp: ((inout State, PointerPress, inout Tx) -> Void)?
    public var onPointerMove: ((inout State, PointerPress, inout Tx) -> Void)?
    public var onHover: ((inout State, Bool, inout Tx) -> Void)?
    public var onDrag: ((inout State, Drag, inout Tx) -> Void)?
    public var onDragEnd: ((inout State, Bool, inout Tx) -> Void)?
    public var onKey: ((inout State, KeyEvent, inout Tx) -> Bool)?
    public var onPhysicalInput: ((inout State, PhysicalInput, inout Tx) -> Bool)?
    public var onWheel: ((inout State, WheelEvent, inout Tx) -> Bool)?

    /// Mutable projection into `State` for `textInput` elements!
    public var editLens: (get: (State) -> TextEdit, set: (inout State, TextEdit) -> Void)?
    public var onTextChange: ((inout State, String, inout Tx) -> Void)?
    public var onTextSubmit: ((inout State, String, inout Tx) -> Void)?

    public init() {}
}

struct ElColdData<State> {
    var pixelSnapEnabled: Bool = true
    var clipRadius: Float? = nil
    var clipCorners: Corners? = nil
    var clipFade: SIMD4<Float>? = nil
    var scrollEdgeFadeWidth: Float = 0
    var scrollMarginPts: Float = 0

    var hoverBg: Color? = nil
    var pressBg: Color? = nil
    var pressScaleFactor: Float? = nil
    var isHoverGroup: Bool = false
    var hoverGroupShare: String? = nil
    var isHoverAlone: Bool = false
    var groupOpacity: (rest: Float, hovered: Float)? = nil
    var groupColor: Color? = nil
    var focusRingColor: Color? = nil
    var focusRingOffset: Float = 2.0
    var focusReturnKey: String? = nil

    var a11yLabel: String? = nil
    var a11yHelp: String? = nil
    var a11ySelected: String? = nil
    var a11yExpanded: Bool? = nil
    var a11yLevel: Int? = nil
    var itemSelected: Bool = false
    var a11yDescription: String? = nil
    var a11yValue: String? = nil
    var a11yRange: A11yRange? = nil
    var a11yChecked: A11yChecked? = nil
    var a11yDisabled: Bool = false
    var isA11yHidden: Bool = false
    var a11yActiveDescendant: String? = nil
    var a11yLabelledBy: String? = nil
    var a11yDescribedBy: String? = nil
    var a11yBusy: Bool = false
    var a11yInvalid: Bool = false
    var a11yReadOnly: Bool = false
    var a11ySorted: Bool? = nil
    var a11yLive: LiveRegionPoliteness? = nil
    var a11yPosInSet: (position: Int, size: Int)? = nil
    var a11yShortcutHint: String? = nil
    var a11yHref: String? = nil

    var richSpans: [TextSpan]? = nil
    var liveText: LiveText? = nil
    var placeholder: String? = nil
    var placeholderColor: Color? = nil
    var caretColor: Color? = nil
    var selectionColor: Color? = nil
    var iconPayload: (SVGIcon, Float)? = nil
    var imagePayload: RGBA8Atlas? = nil
    var gradient: Gradient? = nil
    var borderSides: Sides? = nil
    var dashedBorder: (dash: Float, gap: Float, phase: Float)? = nil

    var anchor: Anchor? = nil
    var layoutAnim: LayoutAnim? = nil
    var styleSpring: Spring? = nil
    var transition: Transition? = nil
    var enterDelay: Float = 0
    var hasInstantChanges: Bool = false
    var hasAnimatedChanges: Bool = false
    var loopingSpec: LoopSpec? = nil
    var flightId: String? = nil
    var terminalGridPayload: TerminalGrid? = nil
    var spellcheck: Bool = false
    var liveBindings: [BoundLiveProperty] = []
    var handlers = ElementHandlers<State>()
    var runtimeExtras: [String: Any] = [:]
}

final class ElColdBox<State> {
    var data: ElColdData<State>
    init(_ data: ElColdData<State> = ElColdData<State>()) {
        self.data = data
    }
}

/// Declarative UI element returned from pure view functions `(State, inout Cx<State>) -> El<State>`.
public struct El<State> {
    private var _cold: ElColdBox<State>? = nil

    private mutating func ensureCold() -> ElColdBox<State> {
        if !isKnownUniquelyReferenced(&_cold) {
            _cold = ElColdBox(_cold?.data ?? ElColdData<State>())
        }
        if _cold == nil {
            _cold = ElColdBox(ElColdData<State>())
        }
        return _cold!
    }

    public var keyId: String? = nil
    public var role: ElementRole = .group
    public var layout: LayoutStyle
    public var children: [El<State>] = []

    // Hot content & visual styling
    public var plainText: String? = nil
    public var textStyle: TextStyle = TextStyle()
    public var textColor: Color? = nil
    public var shapes: [Shape] = []
    public var background: Color = .transparent
    public var borderColor: Color = .transparent
    public var borderWidth: Float = 0
    public var corners: Corners = .all(0)
    public var shadows: [Shadow] = []
    public var opacity: Float = 1.0
    public var scale: Vec2 = Vec2(1, 1)
    public var rotate: Float = 0
    public var origin: Vec2 = Vec2(0.5, 0.5)
    public var offset: Vec2 = .zero
    public var blur: Float = 0
    public var backdropBlur: Float = 0
    public var zIndex: Int = 0
    public var isolatedLayer: Bool = false
    public var focusable: Bool = false
    public var autofocus: Bool = false
    public var focusGroup: Bool = false
    public var isModal: Bool = false
    public var isInert: Bool = false
    public var isHit: Bool = false
    public var explicitHit: Bool { get { isHit } set { isHit = newValue } }
    public var isSecure: Bool = false
    public var isRevealed: Bool = false

    // Cold / CoW properties (keeps `El<State>` compact on worker thread stacks)
    public var richSpans: [TextSpan]? { get { _cold?.data.richSpans } set { ensureCold().data.richSpans = newValue } }
    public var liveText: LiveText? { get { _cold?.data.liveText } set { ensureCold().data.liveText = newValue } }
    public var placeholder: String? { get { _cold?.data.placeholder } set { ensureCold().data.placeholder = newValue } }
    public var placeholderColor: Color? { get { _cold?.data.placeholderColor } set { ensureCold().data.placeholderColor = newValue } }
    public var caretColor: Color? { get { _cold?.data.caretColor } set { ensureCold().data.caretColor = newValue } }
    public var selectionColor: Color? { get { _cold?.data.selectionColor } set { ensureCold().data.selectionColor = newValue } }
    public var iconPayload: (SVGIcon, Float)? { get { _cold?.data.iconPayload } set { ensureCold().data.iconPayload = newValue } }
    public var imagePayload: RGBA8Atlas? { get { _cold?.data.imagePayload } set { ensureCold().data.imagePayload = newValue } }
    public var gradient: Gradient? { get { _cold?.data.gradient } set { ensureCold().data.gradient = newValue } }
    public var borderSides: Sides? { get { _cold?.data.borderSides } set { ensureCold().data.borderSides = newValue } }
    public var dashedBorder: (dash: Float, gap: Float, phase: Float)? { get { _cold?.data.dashedBorder } set { ensureCold().data.dashedBorder = newValue } }
    public var pixelSnapEnabled: Bool { get { _cold?.data.pixelSnapEnabled ?? true } set { ensureCold().data.pixelSnapEnabled = newValue } }
    public var clipRadius: Float? { get { _cold?.data.clipRadius } set { ensureCold().data.clipRadius = newValue } }
    public var clipCorners: Corners? { get { _cold?.data.clipCorners } set { ensureCold().data.clipCorners = newValue } }
    public var clipFade: SIMD4<Float>? { get { _cold?.data.clipFade } set { ensureCold().data.clipFade = newValue } }
    public var scrollEdgeFadeWidth: Float { get { _cold?.data.scrollEdgeFadeWidth ?? 0 } set { ensureCold().data.scrollEdgeFadeWidth = newValue } }
    public var scrollMarginPts: Float { get { _cold?.data.scrollMarginPts ?? 0 } set { ensureCold().data.scrollMarginPts = newValue } }
    public var hoverBg: Color? { get { _cold?.data.hoverBg } set { ensureCold().data.hoverBg = newValue } }
    public var pressBg: Color? { get { _cold?.data.pressBg } set { ensureCold().data.pressBg = newValue } }
    public var pressScaleFactor: Float? { get { _cold?.data.pressScaleFactor } set { ensureCold().data.pressScaleFactor = newValue } }
    public var isHoverGroup: Bool { get { _cold?.data.isHoverGroup ?? false } set { ensureCold().data.isHoverGroup = newValue } }
    public var hoverGroupShare: String? { get { _cold?.data.hoverGroupShare } set { ensureCold().data.hoverGroupShare = newValue } }
    public var isHoverAlone: Bool { get { _cold?.data.isHoverAlone ?? false } set { ensureCold().data.isHoverAlone = newValue } }
    public var groupOpacity: (rest: Float, hovered: Float)? { get { _cold?.data.groupOpacity } set { ensureCold().data.groupOpacity = newValue } }
    public var groupColor: Color? { get { _cold?.data.groupColor } set { ensureCold().data.groupColor = newValue } }
    public var focusRingColor: Color? { get { _cold?.data.focusRingColor } set { ensureCold().data.focusRingColor = newValue } }
    public var focusRingOffset: Float { get { _cold?.data.focusRingOffset ?? 2.0 } set { ensureCold().data.focusRingOffset = newValue } }
    public var focusReturnKey: String? { get { _cold?.data.focusReturnKey } set { ensureCold().data.focusReturnKey = newValue } }

    public var a11yLabel: String? { get { _cold?.data.a11yLabel } set { ensureCold().data.a11yLabel = newValue } }
    public var a11yHelp: String? { get { _cold?.data.a11yHelp } set { ensureCold().data.a11yHelp = newValue } }
    public var a11ySelected: String? { get { _cold?.data.a11ySelected } set { ensureCold().data.a11ySelected = newValue } }
    public var a11yExpanded: Bool? { get { _cold?.data.a11yExpanded } set { ensureCold().data.a11yExpanded = newValue } }
    public var a11yLevel: Int? { get { _cold?.data.a11yLevel } set { ensureCold().data.a11yLevel = newValue } }
    public var itemSelected: Bool { get { _cold?.data.itemSelected ?? false } set { ensureCold().data.itemSelected = newValue } }
    public var a11yDescription: String? { get { _cold?.data.a11yDescription } set { ensureCold().data.a11yDescription = newValue } }
    public var a11yValue: String? { get { _cold?.data.a11yValue } set { ensureCold().data.a11yValue = newValue } }
    public var a11yRange: A11yRange? { get { _cold?.data.a11yRange } set { ensureCold().data.a11yRange = newValue } }
    public var a11yChecked: A11yChecked? { get { _cold?.data.a11yChecked } set { ensureCold().data.a11yChecked = newValue } }
    public var a11yDisabled: Bool { get { _cold?.data.a11yDisabled ?? false } set { ensureCold().data.a11yDisabled = newValue } }
    public var isA11yHidden: Bool { get { _cold?.data.isA11yHidden ?? false } set { ensureCold().data.isA11yHidden = newValue } }
    public var a11yActiveDescendant: String? { get { _cold?.data.a11yActiveDescendant } set { ensureCold().data.a11yActiveDescendant = newValue } }
    public var a11yLabelledBy: String? { get { _cold?.data.a11yLabelledBy } set { ensureCold().data.a11yLabelledBy = newValue } }
    public var a11yDescribedBy: String? { get { _cold?.data.a11yDescribedBy } set { ensureCold().data.a11yDescribedBy = newValue } }
    public var a11yBusy: Bool { get { _cold?.data.a11yBusy ?? false } set { ensureCold().data.a11yBusy = newValue } }
    public var a11yInvalid: Bool { get { _cold?.data.a11yInvalid ?? false } set { ensureCold().data.a11yInvalid = newValue } }
    public var a11yReadOnly: Bool { get { _cold?.data.a11yReadOnly ?? false } set { ensureCold().data.a11yReadOnly = newValue } }
    public var a11ySorted: Bool? { get { _cold?.data.a11ySorted } set { ensureCold().data.a11ySorted = newValue } }
    public var a11yLive: LiveRegionPoliteness? { get { _cold?.data.a11yLive } set { ensureCold().data.a11yLive = newValue } }
    public var a11yPosInSet: (position: Int, size: Int)? { get { _cold?.data.a11yPosInSet } set { ensureCold().data.a11yPosInSet = newValue } }
    public var a11yShortcutHint: String? { get { _cold?.data.a11yShortcutHint } set { ensureCold().data.a11yShortcutHint = newValue } }
    public var a11yHref: String? { get { _cold?.data.a11yHref } set { ensureCold().data.a11yHref = newValue } }

    public var anchor: Anchor? { get { _cold?.data.anchor } set { ensureCold().data.anchor = newValue } }
    public var layoutAnim: LayoutAnim? { get { _cold?.data.layoutAnim } set { ensureCold().data.layoutAnim = newValue } }
    public var styleSpring: Spring? { get { _cold?.data.styleSpring } set { ensureCold().data.styleSpring = newValue } }
    public var transition: Transition? { get { _cold?.data.transition } set { ensureCold().data.transition = newValue } }
    public var enterDelay: Float { get { _cold?.data.enterDelay ?? 0 } set { ensureCold().data.enterDelay = newValue } }
    public var hasInstantChanges: Bool { get { _cold?.data.hasInstantChanges ?? false } set { ensureCold().data.hasInstantChanges = newValue } }
    public var hasAnimatedChanges: Bool { get { _cold?.data.hasAnimatedChanges ?? false } set { ensureCold().data.hasAnimatedChanges = newValue } }
    public var loopingSpec: LoopSpec? { get { _cold?.data.loopingSpec } set { ensureCold().data.loopingSpec = newValue } }
    public var flightId: String? { get { _cold?.data.flightId } set { ensureCold().data.flightId = newValue } }
    public var terminalGridPayload: TerminalGrid? { get { _cold?.data.terminalGridPayload } set { ensureCold().data.terminalGridPayload = newValue } }
    public var spellcheck: Bool { get { _cold?.data.spellcheck ?? false } set { ensureCold().data.spellcheck = newValue } }
    var liveBindings: [BoundLiveProperty] { get { _cold?.data.liveBindings ?? [] } set { ensureCold().data.liveBindings = newValue } }
    public var handlers: ElementHandlers<State> {
        get { _cold?.data.handlers ?? ElementHandlers<State>() }
        set { ensureCold().data.handlers = newValue }
    }
    internal var runtimeExtras: [String: Any] {
        get { _cold?.data.runtimeExtras ?? [:] }
        set { ensureCold().data.runtimeExtras = newValue }
    }

    public init(direction: FlexDirection = .row) {
        self.layout = LayoutStyle(direction: direction)
    }

    // MARK: - Identity & Hierarchy

    public func key(_ k: String) -> Self {
        var copy = self
        copy.keyId = k
        return copy
    }

    public func child(_ c: El<State>) -> Self {
        var copy = self
        copy.children.append(c)
        return copy
    }

    public func child(_ c: El<State>?) -> Self {
        guard let c else { return self }
        return child(c)
    }

    public func children<S: Sequence>(_ list: S) -> Self where S.Element == El<State> {
        var copy = self
        copy.children.append(contentsOf: list)
        return copy
    }

    // MARK: - Sizing & Flexbox Modifiers

    public func w(_ v: Float) -> Self {
        var copy = self
        copy.layout.width = .points(v)
        return copy
    }

    public func h(_ v: Float) -> Self {
        var copy = self
        copy.layout.height = .points(v)
        return copy
    }

    public func size(_ w: Float, _ h: Float) -> Self {
        var copy = self
        copy.layout.width = .points(w)
        copy.layout.height = .points(h)
        return copy
    }

    public func square(_ s: Float) -> Self {
        size(s, s)
    }

    public func wFull() -> Self {
        var copy = self
        copy.layout.width = .fraction(1.0)
        return copy
    }

    public func hFull() -> Self {
        var copy = self
        copy.layout.height = .fraction(1.0)
        return copy
    }

    public func sizeFull() -> Self {
        wFull().hFull()
    }

    public func wFrac(_ f: Float) -> Self {
        var copy = self
        copy.layout.width = .fraction(f)
        return copy
    }

    public func hFrac(_ f: Float) -> Self {
        var copy = self
        copy.layout.height = .fraction(f)
        return copy
    }

    public func wAuto() -> Self {
        var copy = self
        copy.layout.width = .auto
        return copy
    }

    public func hAuto() -> Self {
        var copy = self
        copy.layout.height = .auto
        return copy
    }

    public func sizeAuto() -> Self {
        wAuto().hAuto()
    }

    public func minWFrac(_ f: Float) -> Self {
        var copy = self
        copy.layout.minWidth = .fraction(f)
        return copy
    }

    public func minHFrac(_ f: Float) -> Self {
        var copy = self
        copy.layout.minHeight = .fraction(f)
        return copy
    }

    public func maxWFrac(_ f: Float) -> Self {
        var copy = self
        copy.layout.maxWidth = .fraction(f)
        return copy
    }

    public func maxHFrac(_ f: Float) -> Self {
        var copy = self
        copy.layout.maxHeight = .fraction(f)
        return copy
    }

    public func minW(_ v: Float) -> Self {
        var copy = self
        copy.layout.minWidth = .points(v)
        return copy
    }

    public func minH(_ v: Float) -> Self {
        var copy = self
        copy.layout.minHeight = .points(v)
        return copy
    }

    public func maxW(_ v: Float) -> Self {
        var copy = self
        copy.layout.maxWidth = .points(v)
        return copy
    }

    public func maxH(_ v: Float) -> Self {
        var copy = self
        copy.layout.maxHeight = .points(v)
        return copy
    }

    public func grow(_ g: Float = 1.0) -> Self {
        var copy = self
        copy.layout.flexGrow = g
        copy.layout.flexShrink = 1.0
        if copy.layout.flexBasis == .auto {
            copy.layout.flexBasis = .points(0)
        }
        return copy
    }

    public func shrink(_ s: Float) -> Self {
        var copy = self
        copy.layout.flexShrink = s
        return copy
    }

    public func basis(_ pt: Float) -> Self {
        var copy = self
        copy.layout.flexBasis = .points(pt)
        return copy
    }

    public func aspectRatio(_ r: Float) -> Self {
        var copy = self
        copy.layout.aspectRatio = (r.isFinite && r > 0) ? r : nil
        return copy
    }

    public func aspectFit(_ r: Float) -> Self {
        var copy = self
        copy.layout.aspectFit = (r.isFinite && r > 0) ? r : nil
        return copy
    }

    public func flexWrap(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.layout.wrap = enabled
        return copy
    }

    public func gap(_ g: Float) -> Self {
        var copy = self
        copy.layout.rowGap = max(0, g)
        copy.layout.columnGap = max(0, g)
        return copy
    }

    public func rowGap(_ g: Float) -> Self {
        var copy = self
        copy.layout.rowGap = max(0, g)
        return copy
    }

    public func columnGap(_ g: Float) -> Self {
        var copy = self
        copy.layout.columnGap = max(0, g)
        return copy
    }

    // MARK: - Padding & Margin

    public func p(_ all: Float) -> Self {
        var copy = self
        copy.layout.padding = .all(all)
        return copy
    }

    public func px(_ h: Float) -> Self {
        var copy = self
        copy.layout.padding.left = h
        copy.layout.padding.right = h
        return copy
    }

    public func py(_ v: Float) -> Self {
        var copy = self
        copy.layout.padding.top = v
        copy.layout.padding.bottom = v
        return copy
    }

    public func pt(_ v: Float) -> Self { var c = self; c.layout.padding.top = v; return c }
    public func pb(_ v: Float) -> Self { var c = self; c.layout.padding.bottom = v; return c }
    public func pl(_ v: Float) -> Self { var c = self; c.layout.padding.left = v; return c }
    public func pr(_ v: Float) -> Self { var c = self; c.layout.padding.right = v; return c }

    public func m(_ all: Float) -> Self {
        var copy = self
        copy.layout.margin = .all(all)
        return copy
    }

    public func mx(_ h: Float) -> Self { var c = self; c.layout.margin.left = h; c.layout.margin.right = h; return c }
    public func my(_ v: Float) -> Self { var c = self; c.layout.margin.top = v; c.layout.margin.bottom = v; return c }
    public func mt(_ v: Float) -> Self { var c = self; c.layout.margin.top = v; return c }
    public func mb(_ v: Float) -> Self { var c = self; c.layout.margin.bottom = v; return c }
    public func ml(_ v: Float) -> Self { var c = self; c.layout.margin.left = v; return c }
    public func mr(_ v: Float) -> Self { var c = self; c.layout.margin.right = v; return c }

    // MARK: - Alignment & Positioning

    public func itemsStart() -> Self { var c = self; c.layout.alignItems = .start; return c }
    public func itemsCenter() -> Self { var c = self; c.layout.alignItems = .center; return c }
    public func centerY() -> Self { itemsCenter() }
    public func centerX() -> Self { justifyCenter() }
    public func itemsEnd() -> Self { var c = self; c.layout.alignItems = .end; return c }
    public func itemsStretch() -> Self { var c = self; c.layout.alignItems = .stretch; return c }
    public func alignSelf(_ a: AlignItems) -> Self { var c = self; c.layout.alignSelf = a; return c }

    public func justifyStart() -> Self { var c = self; c.layout.justifyContent = .start; return c }
    public func justifyCenter() -> Self { var c = self; c.layout.justifyContent = .center; return c }
    public func justifyEnd() -> Self { var c = self; c.layout.justifyContent = .end; return c }
    public func justifyBetween() -> Self { var c = self; c.layout.justifyContent = .spaceBetween; return c }
    public func justifyAround() -> Self { var c = self; c.layout.justifyContent = .spaceAround; return c }
    public func justifyEvenly() -> Self { var c = self; c.layout.justifyContent = .spaceEvenly; return c }

    public func center() -> Self {
        var copy = self
        copy.layout.alignItems = .center
        copy.layout.justifyContent = .center
        return copy
    }

    public func absolute(x: Float, y: Float) -> Self {
        var copy = self
        copy.layout.isAbsolute = true
        copy.layout.pinLeft = x
        copy.layout.pinTop = y
        return copy
    }

    public func pin(top: Float? = nil, right: Float? = nil, bottom: Float? = nil, left: Float? = nil) -> Self {
        var copy = self
        copy.layout.isAbsolute = true
        if let top { copy.layout.pinTop = top }
        if let right { copy.layout.pinRight = right }
        if let bottom { copy.layout.pinBottom = bottom }
        if let left { copy.layout.pinLeft = left }
        return copy
    }

    public func z(_ order: Int) -> Self {
        var copy = self
        copy.zIndex = order
        return copy
    }

    // MARK: - Scrolling & Clipping

    public func scroll(stickBottom: Bool = false) -> Self {
        var copy = self
        copy.layout.scrollAxes = .vertical
        copy.layout.stickBottom = stickBottom
        copy.layout.clipOverflow = true
        return copy
    }

    public func scrollY(stickBottom: Bool = false) -> Self {
        scroll(stickBottom: stickBottom)
    }

    public func scrollX() -> Self {
        var copy = self
        copy.layout.scrollAxes = .horizontal
        copy.layout.clipOverflow = true
        return copy
    }

    public func scrollXY() -> Self {
        var copy = self
        copy.layout.scrollAxes = .both
        copy.layout.clipOverflow = true
        return copy
    }

    public func clip(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.layout.clipOverflow = enabled
        return copy
    }

    public func stickyTop(_ offset: Float = 0) -> Self {
        var copy = self
        copy.layout.sticky = .top(offset)
        return copy
    }

    public func stickyBottom(_ offset: Float = 0) -> Self {
        var copy = self
        copy.layout.sticky = .bottom(offset)
        return copy
    }

    // MARK: - Visual Styling

    public func bg(_ color: Color) -> Self {
        var copy = self
        copy.background = color
        return copy
    }

    public func linearGradient(top: Color, bottom: Color, angleRadians: Float = .pi * 0.5) -> Self {
        var copy = self
        copy.gradient = .linear(top: top, bottom: bottom, angleRadians: angleRadians)
        return copy
    }

    public func radialGradient(inner: Color, outer: Color) -> Self {
        var copy = self
        copy.gradient = .radial(inner: inner, outer: outer)
        return copy
    }

    public func rounded(_ r: Float) -> Self {
        var copy = self
        copy.corners = .all(r)
        return copy
    }

    /// Apple continuous squircle corners (`radii < 0` in shader).
    public func continuousRounded(_ r: Float) -> Self {
        var copy = self
        copy.corners = .all(-abs(r))
        return copy
    }

    public func corners(_ tl: Float, _ tr: Float, _ br: Float, _ bl: Float) -> Self {
        var copy = self
        copy.corners = Corners(tl, tr, br, bl)
        return copy
    }

    public func pill() -> Self {
        rounded(9999)
    }

    public func border(_ width: Float, _ color: Color) -> Self {
        var copy = self
        copy.borderWidth = max(0, width)
        copy.borderColor = color
        return copy
    }

    public func borderSides(top: Float = 0, right: Float = 0, bottom: Float = 0, left: Float = 0, color: Color) -> Self {
        var copy = self
        copy.borderSides = Sides(top: top, right: right, bottom: bottom, left: left)
        copy.borderColor = color
        return copy
    }

    public func dashedBorder(_ width: Float, _ color: Color, dash: Float = 4, gap: Float = 4, phase: Float = 0) -> Self {
        var copy = self
        copy.borderWidth = max(0.5, width)
        copy.borderColor = color
        copy.dashedBorder = (dash, gap, phase)
        return copy
    }

    public func shadow(_ s: Shadow) -> Self {
        var copy = self
        copy.shadows.append(s)
        return copy
    }

    public func shadows(_ list: [Shadow]) -> Self {
        var copy = self
        copy.shadows.append(contentsOf: list)
        return copy
    }

    public func opacity(_ a: Float) -> Self {
        var copy = self
        copy.opacity = a.clamped(to: 0...1)
        return copy
    }

    public func scale(_ s: Float) -> Self {
        var copy = self
        copy.scale = Vec2(s, s)
        return copy
    }

    public func scale(_ x: Float, _ y: Float) -> Self {
        var copy = self
        copy.scale = Vec2(x, y)
        return copy
    }

    public func rotate(_ radians: Float) -> Self {
        var copy = self
        copy.rotate = radians
        return copy
    }

    public func origin(_ x: Float, _ y: Float) -> Self {
        var copy = self
        copy.origin = Vec2(x, y)
        return copy
    }

    public func offset(_ x: Float, _ y: Float) -> Self {
        var copy = self
        copy.offset = Vec2(x, y)
        return copy
    }

    public func blur(_ radius: Float) -> Self {
        var copy = self
        copy.blur = max(0, radius)
        return copy
    }

    public func backdropBlur(_ radius: Float) -> Self {
        var copy = self
        copy.backdropBlur = max(0, radius)
        return copy
    }

    public func pixelSnap(_ on: Bool = true) -> Self {
        var copy = self
        copy.pixelSnapEnabled = on
        return copy
    }

    public func clipRounded(_ radius: Float) -> Self {
        var copy = self
        copy.clipCorners = nil
        copy.clipRadius = max(0, radius)
        return copy
    }

    public func clipCorners(_ radii: Corners) -> Self {
        var copy = self
        let clamped = Corners(
            max(0, radii.topLeft),
            max(0, radii.topRight),
            max(0, radii.bottomRight),
            max(0, radii.bottomLeft)
        )
        copy.clipCorners = clamped
        copy.clipRadius = clamped.maxMagnitude
        return copy
    }

    public func clipSoft(_ fade: Float) -> Self {
        let f = max(0, fade)
        var copy = self
        copy.clipFade = SIMD4<Float>(f, f, f, f)
        return copy
    }

    public func clipFade(left: Float = 0, top: Float = 0, right: Float = 0, bottom: Float = 0) -> Self {
        var copy = self
        copy.clipFade = SIMD4<Float>(max(0, left), max(0, top), max(0, right), max(0, bottom))
        return copy
    }

    public func clipFadeLinear(left: Float = 0, top: Float = 0, right: Float = 0, bottom: Float = 0) -> Self {
        var copy = self
        copy.clipFade = SIMD4<Float>(-max(0, left), -max(0, top), -max(0, right), -max(0, bottom))
        return copy
    }

    public func hoverGroup() -> Self {
        var copy = self
        copy.isHoverGroup = true
        return copy
    }

    public func hoverGroupShared(_ key: String) -> Self {
        var copy = self
        copy.isHoverGroup = true
        copy.hoverGroupShare = key
        return copy
    }

    public func groupOpacity(_ rest: Float, _ hovered: Float) -> Self {
        var copy = self
        copy.groupOpacity = (rest.clamped(to: 0...1), hovered.clamped(to: 0...1))
        return copy
    }

    public func groupColor(_ color: Color) -> Self {
        var copy = self
        copy.groupColor = color
        return copy
    }

    public func hoverAlone() -> Self {
        var copy = self
        copy.isHoverAlone = true
        return copy
    }

    public func instantChanges() -> Self {
        var copy = self
        copy.hasInstantChanges = true
        return copy
    }

    public func animatedChanges() -> Self {
        var copy = self
        copy.hasAnimatedChanges = true
        return copy
    }

    public func enterDelay(_ seconds: Float) -> Self {
        var copy = self
        copy.enterDelay = seconds.isFinite ? max(0, seconds) : 0
        return copy
    }

    public func looping(_ spec: LoopSpec) -> Self {
        var copy = self
        copy.loopingSpec = spec
        return copy
    }

    public func cycle(_ c: Cycle) -> Self {
        looping(.cycle(c))
    }

    public func sequence(_ frames: MotionSequence) -> Self {
        looping(.sequence(frames))
    }

    public func scrollEdgeFade(_ width: Float) -> Self {
        var copy = self
        copy.scrollEdgeFadeWidth = max(0, width)
        return copy
    }

    public func scrollMargin(_ pts: Float) -> Self {
        var copy = self
        copy.scrollMarginPts = max(0, pts)
        return copy
    }

    public func above(_ key: String, gutter: Float = 0) -> Self {
        anchored(key, side: .top, align: .start, gap: gutter)
    }

    public func anchored(_ key: String, side: Side, align: Align = .start, gap: Float = 0) -> Self {
        var copy = self
        copy.layout.isAbsolute = true
        copy.anchor = Anchor(key: key, side: side, align: align, gap: gap)
        return copy
    }

    public func anchoredFit(_ key: String, side: Side, align: Align = .start, gap: Float = 0) -> Self {
        var copy = anchored(key, side: side, align: align, gap: gap)
        copy.anchor?.fit = true
        return copy
    }

    public func anchoredUnscaled() -> Self {
        var copy = self
        copy.anchor?.unscaled = true
        return copy
    }

    public func anchoredRound() -> Self {
        var copy = self
        copy.anchor?.round = true
        return copy
    }

    public func shape(_ s: Shape) -> Self {
        var copy = self
        copy.shapes.append(s)
        return copy
    }

    // MARK: - Typography Modifiers

    public func font(_ style: TextStyle) -> Self {
        var copy = self
        copy.textStyle = style
        return copy
    }

    public func size(_ fontSize: Float) -> Self {
        var copy = self
        copy.textStyle.size = fontSize
        return copy
    }

    public func weight(_ w: Float) -> Self {
        var copy = self
        copy.textStyle.weight = w
        return copy
    }

    public func bold() -> Self { weight(700) }
    public func semibold() -> Self { weight(600) }
    public func medium() -> Self { weight(500) }
    public func mono() -> Self { var c = self; c.textStyle.family = .monospace; return c }
    public func italic(_ on: Bool = true) -> Self { var c = self; c.textStyle.italic = on; return c }
    public func lineHeight(_ lh: Float) -> Self { var c = self; c.textStyle.lineHeight = lh; return c }
    public func letterSpacing(_ spacing: Float) -> Self { var c = self; c.textStyle.letterSpacing = spacing; return c }
    public func tracking(_ spacing: Float) -> Self { letterSpacing(spacing) }
    public func textAlign(_ align: TextAlign) -> Self { var c = self; c.textStyle.align = align; return c }
    public func noWrap() -> Self { var c = self; c.textStyle.wrap = .noWrap; return c }
    public func wrapText() -> Self { var c = self; c.textStyle.wrap = .wrap; return c }
    public func wrap(_ mode: TextWrap) -> Self { var c = self; c.textStyle.wrap = mode; return c }
    public func ellipsis() -> Self { var c = self; c.textStyle.wrap = .ellipsis; return c }

    public func color(_ c: Color) -> Self {
        var copy = self
        copy.textColor = c
        return copy
    }

    public func placeholder(_ p: String, color: Color? = nil) -> Self {
        var copy = self
        copy.placeholder = p
        if let color { copy.placeholderColor = color }
        return copy
    }

    public func caret(_ color: Color, selection: Color? = nil) -> Self {
        var copy = self
        copy.caretColor = color
        if let selection { copy.selectionColor = selection }
        return copy
    }

    // MARK: - Motion & Live Modifiers

    public func animateLayout(_ spring: Spring = MotionTokens.SETTLE) -> Self {
        var copy = self
        copy.layoutAnim = LayoutAnim(spring: spring)
        return copy
    }

    public func animateLayout(_ spec: LayoutAnim) -> Self {
        var copy = self
        copy.layoutAnim = spec
        return copy
    }

    public func animate(_ spring: Spring = MotionTokens.SNAPPY) -> Self {
        var copy = self
        copy.styleSpring = spring
        return copy
    }

    public func transition(_ t: Transition) -> Self {
        var copy = self
        copy.transition = t
        return copy
    }

    public func liveOpacity(_ binding: Binding<Float>) -> Self {
        bindLive(.opacity, binding)
    }

    public func liveScale(_ binding: Binding<Float>) -> Self {
        bindLive(.scale, binding)
    }

    public func liveBlur(_ binding: Binding<Float>) -> Self {
        bindLive(.blur, binding)
    }

    public func liveOffset(_ binding: Binding<Vec2>) -> Self {
        bindLive(.offset, binding)
    }

    public func liveFill(_ binding: Binding<Color>) -> Self {
        bindLive(.fill, binding)
    }

    public func liveRect(_ binding: Binding<MotionRect>) -> Self {
        bindLive(.rect, binding)
    }

    public func liveTrim(_ binding: Binding<Vec2>) -> Self {
        bindLive(.trim, binding)
    }

    private func bindLive<T: LiveValue>(_ target: BoundLiveProperty.Target, _ b: Binding<T>) -> Self {
        var copy = self
        let entry = BoundLiveProperty(target: target, source: b.live.source, spring: b.spring, restSpring: b.restSpring)
        copy.liveBindings.removeAll { $0.target == target }
        copy.liveBindings.append(entry)
        return copy
    }

    // MARK: - Interaction, Focus & Accessibility

    public func hover(_ bg: Color) -> Self {
        var copy = self
        copy.hoverBg = bg
        return copy
    }

    public func press(_ bg: Color) -> Self {
        var copy = self
        copy.pressBg = bg
        return copy
    }

    public func pressScale(_ factor: Float = 0.97) -> Self {
        var copy = self
        copy.pressScaleFactor = factor
        return copy
    }

    public func focusRing(_ color: Color, offset: Float = 2.0) -> Self {
        var copy = self
        copy.focusRingColor = color
        copy.focusRingOffset = offset
        copy.focusable = true
        return copy
    }

    public func focusable(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.focusable = enabled
        return copy
    }

    public func autofocus(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.autofocus = enabled
        if enabled { copy.focusable = true }
        return copy
    }

    public func focusGroup(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.focusGroup = enabled
        return copy
    }

    public func modal(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.isModal = enabled
        return copy
    }

    public func inert(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.isInert = enabled
        return copy
    }

    /// Marks the drawn, ancestor-clipped rectangle as an explicit native overlay input hit region (`El::hit`).
    public func hit(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.isHit = enabled
        return copy
    }

    public func secure(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.isSecure = enabled
        return copy
    }

    public func revealed(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.isRevealed = enabled
        return copy
    }

    public func role(_ r: ElementRole) -> Self { var c = self; c.role = r; return c }
    public func label(_ l: String) -> Self { var c = self; c.a11yLabel = l; return c }
    public func help(_ h: String) -> Self { var c = self; c.a11yHelp = h; return c }
    public func selected(_ val: String?) -> Self { var c = self; c.a11ySelected = val; return c }
    public func expanded(_ val: Bool?) -> Self { var c = self; c.a11yExpanded = val; return c }
    public func headingLevel(_ l: Int) -> Self { var c = self; c.role = .heading; c.a11yLevel = l; return c }
    public func itemSelected(_ on: Bool = true) -> Self { var c = self; c.itemSelected = on; return c }
    public func focusReturn(_ trigger: String) -> Self { var c = self; c.focusReturnKey = trigger; return c }

    public func description(_ text: String) -> Self { var c = self; c.a11yDescription = text; return c }
    public func activeDescendant(_ key: String) -> Self { var c = self; c.a11yActiveDescendant = key; return c }
    public func a11yValue(_ text: String) -> Self { var c = self; c.a11yValue = text; return c }

    public func rangeValue(_ value: Double, min: Double, max: Double) -> Self {
        var c = self
        let step = c.a11yRange?.step
        c.a11yRange = A11yRange(value: value, min: min, max: max, step: step)
        return c
    }

    @_disfavoredOverload
    public func rangeValue(_ value: Float, min: Float, max: Float) -> Self {
        rangeValue(Double(value), min: Double(min), max: Double(max))
    }

    public func rangeStep(_ step: Double) -> Self {
        var c = self
        var r = c.a11yRange ?? A11yRange(value: 0, min: 0, max: 0)
        r.step = step
        c.a11yRange = r
        return c
    }

    @_disfavoredOverload
    public func rangeStep(_ step: Float) -> Self {
        rangeStep(Double(step))
    }

    public func checked(_ on: Bool) -> Self {
        var c = self
        c.a11yChecked = on ? .trueState : .falseState
        return c
    }

    public func checkedMixed() -> Self {
        var c = self
        c.a11yChecked = .mixed
        return c
    }

    public func disabled(_ on: Bool = true) -> Self {
        var c = self
        c.a11yDisabled = on
        if on { c.focusable = false }
        return c
    }

    public func a11yHidden() -> Self {
        var c = self
        c.isA11yHidden = true
        return c
    }

    public func labelledBy(_ key: String) -> Self { var c = self; c.a11yLabelledBy = key; return c }
    public func describedBy(_ key: String) -> Self { var c = self; c.a11yDescribedBy = key; return c }
    public func busy(_ on: Bool = true) -> Self { var c = self; c.a11yBusy = on; return c }
    public func invalid(_ on: Bool = true) -> Self { var c = self; c.a11yInvalid = on; return c }
    public func readOnly(_ on: Bool = true) -> Self { var c = self; c.a11yReadOnly = on; return c }
    public func sorted(_ ascending: Bool?) -> Self { var c = self; c.a11ySorted = ascending; return c }
    public func liveRegion(_ live: LiveRegionPoliteness?) -> Self { var c = self; c.a11yLive = live; return c }
    public func positionInSet(_ position: Int, size: Int) -> Self { var c = self; c.a11yPosInSet = (position, size); return c }
    public func shortcutHint(_ keys: String) -> Self { var c = self; c.a11yShortcutHint = keys; return c }

    public func href(_ url: String) -> Self {
        var c = self
        c.a11yHref = url
        c.role = .link
        c.focusable = true
        c.handlers.onClick = { _, tx in
            if url.contains(":") { _ = try? tx.openUrl(url) }
        }
        return c
    }

    // MARK: - Event Handlers

    public func onClick(_ handler: @escaping (inout State) -> Void) -> Self {
        onClick { state, _ in handler(&state) }
    }

    public func onClick(_ handler: @escaping (inout State, inout Tx) -> Void) -> Self {
        var copy = self
        copy.focusable = true
        if copy.role == .group { copy.role = .button }
        copy.handlers.onClick = handler
        return copy
    }

    public func onClickPress(_ handler: @escaping (inout State, PointerPress, inout Tx) -> Void) -> Self {
        var copy = self
        copy.focusable = true
        if copy.role == .group { copy.role = .button }
        copy.handlers.onClickPress = handler
        return copy
    }

    public func onDoubleClick(_ handler: @escaping (inout State, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onDoubleClick = handler
        return copy
    }

    public func onSecondaryClick(_ handler: @escaping (inout State, PointerPress, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onSecondaryClick = handler
        return copy
    }

    public func onPointerDown(_ handler: @escaping (inout State, PointerPress, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onPointerDown = handler
        return copy
    }

    public func onPointerUp(_ handler: @escaping (inout State, PointerPress, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onPointerUp = handler
        return copy
    }

    /// Observes pointer movement over this element without creating a native overlay input region (`El::on_pointer_move`).
    public func onPointerMove(_ handler: @escaping (inout State, PointerPress, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onPointerMove = handler
        return copy
    }

    public func onHover(_ handler: @escaping (inout State, Bool, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onHover = handler
        return copy
    }

    public func onDrag(_ handler: @escaping (inout State, Drag, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onDrag = handler
        return copy
    }

    /// Invoked when a drag gesture ends (`cancelled == true` if aborted via `Escape`).
    public func onDragEnd(_ handler: @escaping (inout State, Bool, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onDragEnd = handler
        return copy
    }

    public func onKey(_ handler: @escaping (inout State, KeyEvent, inout Tx) -> Bool) -> Self {
        var copy = self
        copy.handlers.onKey = handler
        return copy
    }

    public func onPhysicalInput(_ handler: @escaping (inout State, PhysicalInput, inout Tx) -> Bool) -> Self {
        var copy = self
        copy.handlers.onPhysicalInput = handler
        return copy
    }

    public func onWheel(_ handler: @escaping (inout State, WheelEvent, inout Tx) -> Bool) -> Self {
        var copy = self
        copy.handlers.onWheel = handler
        return copy
    }

    public func onChange(_ handler: @escaping (inout State, String, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onTextChange = handler
        return copy
    }

    public func onSubmit(_ handler: @escaping (inout State, String, inout Tx) -> Void) -> Self {
        var copy = self
        copy.handlers.onTextSubmit = handler
        return copy
    }

    // MARK: - CSS Grid, Block, Flight & Spellcheck Modifiers

    public func block() -> Self {
        var copy = self
        copy.layout.displayMode = .block
        return copy
    }

    public func grid(
        columns: [GridTrack] = [],
        rows: [GridTrack] = [],
        autoFlow: GridAutoFlow = .row,
        justifyItems: AlignItems = .stretch
    ) -> Self {
        var copy = self
        copy.layout.displayMode = .grid
        var gs = copy.layout.grid ?? GridContainerStyle()
        if !columns.isEmpty { gs.templateColumns = columns }
        if !rows.isEmpty { gs.templateRows = rows }
        gs.autoFlow = autoFlow
        gs.justifyItems = justifyItems
        copy.layout.grid = gs
        return copy
    }

    public func gridTemplateColumns(_ tracks: [GridTrack]) -> Self {
        var copy = self
        copy.layout.displayMode = .grid
        var gs = copy.layout.grid ?? GridContainerStyle()
        gs.templateColumns = tracks
        copy.layout.grid = gs
        return copy
    }

    public func gridTemplateRows(_ tracks: [GridTrack]) -> Self {
        var copy = self
        copy.layout.displayMode = .grid
        var gs = copy.layout.grid ?? GridContainerStyle()
        gs.templateRows = tracks
        copy.layout.grid = gs
        return copy
    }

    public func gridAutoColumns(_ tracks: [GridTrack]) -> Self {
        var copy = self
        copy.layout.displayMode = .grid
        var gs = copy.layout.grid ?? GridContainerStyle()
        gs.autoColumns = tracks.isEmpty ? [.auto] : tracks
        copy.layout.grid = gs
        return copy
    }

    public func gridAutoRows(_ tracks: [GridTrack]) -> Self {
        var copy = self
        copy.layout.displayMode = .grid
        var gs = copy.layout.grid ?? GridContainerStyle()
        gs.autoRows = tracks.isEmpty ? [.auto] : tracks
        copy.layout.grid = gs
        return copy
    }

    public func gridAutoFlow(_ flow: GridAutoFlow) -> Self {
        var copy = self
        copy.layout.displayMode = .grid
        var gs = copy.layout.grid ?? GridContainerStyle()
        gs.autoFlow = flow
        copy.layout.grid = gs
        return copy
    }

    public func gridTemplateAreas(_ areas: [[String]]) -> Self {
        var copy = self
        copy.layout.displayMode = .grid
        var gs = copy.layout.grid ?? GridContainerStyle()
        gs.templateAreas = areas
        copy.layout.grid = gs
        return copy
    }

    public func justifyItems(_ align: AlignItems) -> Self {
        var copy = self
        var gs = copy.layout.grid ?? GridContainerStyle()
        gs.justifyItems = align
        copy.layout.grid = gs
        return copy
    }

    public func alignContent(_ justify: JustifyContent) -> Self {
        var copy = self
        var gs = copy.layout.grid ?? GridContainerStyle()
        gs.alignContent = justify
        copy.layout.grid = gs
        return copy
    }

    public func equalColumns(_ count: Int) -> Self {
        gridTemplateColumns(GridTrack.repeatCount(max(1, count), .fr(1)))
    }

    public func gridCell(column: Int) -> Self {
        gridColumn(.line(column + 1), row: .line(1))
    }

    public func gridColumn(_ start: GridPlacement, end: GridPlacement? = nil, row: GridPlacement? = nil) -> Self {
        var copy = self
        var gi = copy.layout.gridItem ?? GridItemStyle()
        gi.column = start
        if let end { gi.columnEnd = end }
        if let row { gi.row = row }
        copy.layout.gridItem = gi
        return copy
    }

    public func gridRow(_ start: GridPlacement, end: GridPlacement? = nil) -> Self {
        var copy = self
        var gi = copy.layout.gridItem ?? GridItemStyle()
        gi.row = start
        if let end { gi.rowEnd = end }
        copy.layout.gridItem = gi
        return copy
    }

    public func gridArea(_ name: String) -> Self {
        var copy = self
        var gi = copy.layout.gridItem ?? GridItemStyle()
        gi.area = name
        copy.layout.gridItem = gi
        return copy
    }

    public func justifySelf(_ align: AlignItems) -> Self {
        var copy = self
        var gi = copy.layout.gridItem ?? GridItemStyle()
        gi.justifySelf = align
        copy.layout.gridItem = gi
        return copy
    }

    public func flightId(_ id: String) -> Self {
        var copy = self
        copy.flightId = id
        return copy
    }

    public func spellcheck(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.spellcheck = enabled
        return copy
    }
}

// MARK: - Top-Level Declarative Element Constructors (`row`, `col`, `el`, `text`, ...)

@inlinable
public func row<State>() -> El<State> {
    El<State>(direction: .row)
}

@inlinable
public func col<State>() -> El<State> {
    El<State>(direction: .column)
}

@inlinable
public func el<State>() -> El<State> {
    El<State>(direction: .row)
}

public func grid<State>(
    columns: [GridTrack] = [],
    rows: [GridTrack] = [],
    autoFlow: GridAutoFlow = .row
) -> El<State> {
    El<State>(direction: .row).grid(columns: columns, rows: rows, autoFlow: autoFlow)
}

public func block<State>() -> El<State> {
    El<State>(direction: .column).block()
}

public func terminalGrid<State>(
    columns: Int,
    cellWidth: Float,
    cellHeight: Float,
    rows: [TerminalGridRow]
) -> El<State> {
    var node = El<State>(direction: .row)
    node.terminalGridPayload = TerminalGrid(
        columns: columns,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        rows: rows
    )
    return node
}

@inlinable
public func spacer<State>() -> El<State> {
    El<State>(direction: .row).grow(1.0)
}

public func rule<State>(_ thickness: Float = 1.0, _ color: Color) -> El<State> {
    El<State>(direction: .row)
        .role(.separator)
        .wFull()
        .h(max(0.5, thickness))
        .bg(color)
}

public func text<State>(_ content: String) -> El<State> {
    var node = El<State>(direction: .row)
    node.role = .text
    node.plainText = content
    return node
}

public func liveText<State>(_ handle: LiveText) -> El<State> {
    var node = El<State>(direction: .row)
    node.role = .text
    node.liveText = handle
    node.plainText = handle.get()
    return node
}

public func text<State>(_ handle: LiveText) -> El<State> {
    liveText(handle)
}

public func rich<State>(_ spans: [TextSpan]) -> El<State> {
    var node = El<State>(direction: .row)
    node.role = .text
    node.richSpans = spans
    node.plainText = spans.map(\.text).joined()
    return node
}

public func icon<State>(_ svg: SVGIcon, size: Float = 16.0) -> El<State> {
    var node = El<State>(direction: .row)
        .size(size, size)
        .shrink(0)
    node.role = .icon
    node.iconPayload = (svg, size)
    return node
}

public func image<State>(_ atlas: RGBA8Atlas) -> El<State> {
    var node = El<State>(direction: .row)
    node.role = .image
    node.imagePayload = atlas
    if atlas.width > 0 && atlas.height > 0 {
        node.layout.aspectRatio = Float(atlas.width) / Float(atlas.height)
    }
    return node
}

public func canvas<State>(_ shape: Shape) -> El<State> {
    var node = El<State>(direction: .row)
    node.role = .image
    node.shapes = [shape]
    return node
}

/// Interactive single-line or multiline text input bound via a Swift `WritableKeyPath<State, TextEdit>`.
public func textInput<State>(
    key: String,
    _ keyPath: WritableKeyPath<State, TextEdit>
) -> El<State> {
    var node = El<State>(direction: .row)
        .key(key)
        .role(.textInput)
        .focusable(true)
        .clip(true)
    node.textStyle.wrap = .wrap
    node.handlers.editLens = (
        get: { state in state[keyPath: keyPath] },
        set: { state, updated in state[keyPath: keyPath] = updated }
    )
    return node
}
