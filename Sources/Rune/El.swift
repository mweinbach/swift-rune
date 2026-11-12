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
        scrollLookup: @escaping (String) -> Vec2 = { _ in .zero }
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
    public var onWheel: ((inout State, WheelEvent, inout Tx) -> Bool)?

    /// Mutable projection into `State` for `textInput` elements!
    public var editLens: (get: (State) -> TextEdit, set: (inout State, TextEdit) -> Void)?
    public var onTextChange: ((inout State, String, inout Tx) -> Void)?
    public var onTextSubmit: ((inout State, String, inout Tx) -> Void)?

    public init() {}
}

/// Declarative UI element returned from pure view functions `(State, inout Cx<State>) -> El<State>`.
public struct El<State> {
    public var keyId: String? = nil
    public var role: ElementRole = .group
    public var layout: LayoutStyle
    public var children: [El<State>] = []

    // Content payloads
    public var plainText: String? = nil
    public var richSpans: [TextSpan]? = nil
    public var liveText: LiveText? = nil
    public var textStyle: TextStyle = TextStyle()
    public var textColor: Color? = nil
    public var placeholder: String? = nil
    public var placeholderColor: Color? = nil
    public var caretColor: Color? = nil
    public var selectionColor: Color? = nil
    public var iconPayload: (SVGIcon, Float)? = nil
    public var imagePayload: RGBA8Atlas? = nil
    public var shapes: [Shape] = []

    // Visual styling
    public var background: Color = .transparent
    public var gradient: Gradient? = nil
    public var borderColor: Color = .transparent
    public var borderWidth: Float = 0
    public var borderSides: Sides? = nil
    public var dashedBorder: (dash: Float, gap: Float, phase: Float)? = nil
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

    // Interactive state overlays & focus
    public var hoverBg: Color? = nil
    public var pressBg: Color? = nil
    public var pressScaleFactor: Float? = nil
    public var focusRingColor: Color? = nil
    public var focusRingOffset: Float = 2.0
    public var focusable: Bool = false
    public var autofocus: Bool = false
    public var focusGroup: Bool = false
    public var isModal: Bool = false
    public var isInert: Bool = false
    public var isHit: Bool = false
    public var explicitHit: Bool { get { isHit } set { isHit = newValue } }
    public var isSecure: Bool = false
    public var isRevealed: Bool = false

    // Accessibility metadata
    public var a11yLabel: String? = nil
    public var a11yHelp: String? = nil
    public var a11ySelected: String? = nil
    public var a11yExpanded: Bool? = nil
    public var a11yLevel: Int? = nil
    public var itemSelected: Bool = false

    // Motion & Live bindings
    public var layoutAnim: LayoutAnim? = nil
    public var styleSpring: Spring? = nil
    public var transition: Transition? = nil
    public var flightId: String? = nil
    public var terminalGridPayload: TerminalGrid? = nil
    public var spellcheck: Bool = false
    var liveBindings: [BoundLiveProperty] = []

    // Handlers
    public var handlers = ElementHandlers<State>()
    internal var runtimeExtras: [String: Any] = [:]

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
