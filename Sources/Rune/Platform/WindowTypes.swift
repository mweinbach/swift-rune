import Foundation
import RuneMotion
import RuneRef

// MARK: - Display & Run Options (window/spec.rs)

/// Native display identifier (`rune::NativeDisplayId`).
public enum NativeDisplayId: Hashable, Sendable {
    case macOS(UInt32)
    case wayland(String)
    case other(UInt64)
}

/// Platform display identifier (`rune::DisplayId`).
public struct RuneDisplayId: Hashable, Sendable {
    public var native: NativeDisplayId?

    public init(native: NativeDisplayId? = nil) {
        self.native = native
    }
}

/// A display in desktop physical-pixel coordinates (`rune::Display`).
public struct DisplayInfo: Equatable, Sendable {
    public var id: RuneDisplayId?
    public var name: String?
    public var position: (Int32, Int32)
    public var size: (UInt32, UInt32)
    public var scale: Double
    public var primary: Bool

    public init(
        id: RuneDisplayId? = nil,
        name: String? = nil,
        position: (Int32, Int32) = (0, 0),
        size: (UInt32, UInt32) = (1440, 900),
        scale: Double = 2.0,
        primary: Bool = true
    ) {
        self.id = id
        self.name = name
        self.position = position
        self.size = size
        self.scale = scale
        self.primary = primary
    }

    public var nativeId: NativeDisplayId? {
        id?.native
    }

    /// `(x, y, width, height)` in the native global top-left coordinate space.
    public var nativeBounds: [Double] {
        let divisor: Double
        if case .wayland = nativeId {
            divisor = max(scale, 0.001)
        } else {
            divisor = 1.0
        }
        return [
            Double(position.0),
            Double(position.1),
            Double(size.0) / divisor,
            Double(size.1) / divisor,
        ]
    }

    public static func == (lhs: DisplayInfo, rhs: DisplayInfo) -> Bool {
        lhs.id == rhs.id &&
            lhs.name == rhs.name &&
            lhs.position == rhs.position &&
            lhs.size == rhs.size &&
            lhs.scale == rhs.scale &&
            lhs.primary == rhs.primary
    }
}

/// Process-level settings applied once before constructing the native event loop (`rune::RunOptions`).
public struct RuneRunOptions: Equatable, Sendable {
    /// macOS: no Dock icon/default menu and no activation at launch. Ignored elsewhere.
    public var accessory: Bool

    public init(accessory: Bool = false) {
        self.accessory = accessory
    }
}

// MARK: - Window Options & MacWindowOptions (window/spec.rs)

/// Default minimum content size when neither `RuneWindowOptions` nor `AppSpec` sets one (`DEFAULT_MIN_SIZE`).
public let runeDefaultWindowMinSize: (Float, Float) = (420.0, 400.0)

/// Snapshot of computed native window creation attributes (mirrors `winit::window::WindowAttributes`).
public struct WindowAttributesSnapshot: Equatable, Sendable {
    public var title: String
    public var innerSize: (Float, Float)
    public var minInnerSize: (Float, Float)
    public var maxInnerSize: (Float, Float)?
    public var position: (Int32, Int32)?
    public var physicalSize: (UInt32, UInt32)?
    public var resizable: Bool
    public var maximizeButtonEnabled: Bool
    public var transparent: Bool
    public var decorations: Bool
    public var visible: Bool
    public var alwaysOnTop: Bool

    public static func == (lhs: WindowAttributesSnapshot, rhs: WindowAttributesSnapshot) -> Bool {
        lhs.title == rhs.title &&
            lhs.innerSize == rhs.innerSize &&
            lhs.minInnerSize == rhs.minInnerSize &&
            lhs.maxInnerSize?.0 == rhs.maxInnerSize?.0 &&
            lhs.maxInnerSize?.1 == rhs.maxInnerSize?.1 &&
            lhs.position?.0 == rhs.position?.0 &&
            lhs.position?.1 == rhs.position?.1 &&
            lhs.physicalSize?.0 == rhs.physicalSize?.0 &&
            lhs.physicalSize?.1 == rhs.physicalSize?.1 &&
            lhs.resizable == rhs.resizable &&
            lhs.maximizeButtonEnabled == rhs.maximizeButtonEnabled &&
            lhs.transparent == rhs.transparent &&
            lhs.decorations == rhs.decorations &&
            lhs.visible == rhs.visible &&
            lhs.alwaysOnTop == rhs.alwaysOnTop
    }
}

/// Full parity cross-platform window options (`rune::WindowOptions`).
public struct RuneWindowOptions: Equatable, Sendable {
    public var transparent: Bool
    public var borderless: Bool
    public var clickThrough: Bool
    public var alwaysOnTop: Bool
    public var visible: Bool
    public var position: (Int32, Int32)?
    public var physicalSize: (UInt32, UInt32)?
    public var minSize: (Float, Float)?
    public var maxSize: (Float, Float)?
    public var resizable: Bool

    public init(
        transparent: Bool = false,
        borderless: Bool = false,
        clickThrough: Bool = false,
        alwaysOnTop: Bool = false,
        visible: Bool = true,
        position: (Int32, Int32)? = nil,
        physicalSize: (UInt32, UInt32)? = nil,
        minSize: (Float, Float)? = nil,
        maxSize: (Float, Float)? = nil,
        resizable: Bool = true
    ) {
        self.transparent = transparent
        self.borderless = borderless
        self.clickThrough = clickThrough
        self.alwaysOnTop = alwaysOnTop
        self.visible = visible
        self.position = position
        self.physicalSize = physicalSize
        self.minSize = minSize
        self.maxSize = maxSize
        self.resizable = resizable
    }

    public static let `default` = RuneWindowOptions()

    /// A hidden, retained launcher (`WindowOptions::launcher_panel`).
    public static func launcherPanel() -> RuneConfiguredWindowOptions {
        var native = RuneMacWindowOptions().nonactivatingPanel(true)
        native.launcher = true
        let opts = RuneWindowOptions(
            transparent: true,
            borderless: true,
            visible: false,
            minSize: (0.0, 0.0),
            resizable: false
        )
        return opts.macos(native)
    }

    /// Attach AppKit-specific window properties.
    public func macos(_ native: RuneMacWindowOptions) -> RuneConfiguredWindowOptions {
        RuneConfiguredWindowOptions(options: self, native: native)
    }

    /// One transparent, borderless, topmost, click-through overlay covering `display`.
    public static func overlay(display: DisplayInfo) -> RuneWindowOptions {
        RuneWindowOptions(
            transparent: true,
            borderless: true,
            clickThrough: true,
            alwaysOnTop: true,
            visible: true,
            position: display.position,
            physicalSize: display.size,
            minSize: (0.0, 0.0),
            maxSize: nil,
            resizable: true
        )
    }

    /// The window's minimum and maximum content sizes, with `appMin` as fallback minimum.
    public func sizeLimits(appMin: (Float, Float)?) -> ((Float, Float), (Float, Float)?) {
        var minVal = minSize ?? appMin ?? runeDefaultWindowMinSize
        if let maxVal = maxSize {
            minVal = (min(minVal.0, maxVal.0), min(minVal.1, maxVal.1))
        }
        return (minVal, maxSize)
    }

    /// The minimum a window that fits its content height opens with: content sets height.
    public func fitMinSize(appMin: (Float, Float)?) -> (Float, Float)? {
        if appMin == nil && minSize == nil {
            return (runeDefaultWindowMinSize.0, 0.0)
        }
        return appMin
    }

    /// Computes resolved window attributes (`WindowOptions::attributes`).
    public func attributes(
        title: String,
        size: (Float, Float),
        appMin: (Float, Float)?,
        visible: Bool
    ) -> WindowAttributesSnapshot {
        let (minLim, _) = sizeLimits(appMin: appMin)
        return WindowAttributesSnapshot(
            title: title,
            innerSize: size,
            minInnerSize: minLim,
            maxInnerSize: maxSize,
            position: position,
            physicalSize: physicalSize,
            resizable: resizable,
            maximizeButtonEnabled: resizable,
            transparent: transparent,
            decorations: !borderless,
            visible: visible,
            alwaysOnTop: alwaysOnTop
        )
    }

    public static func == (lhs: RuneWindowOptions, rhs: RuneWindowOptions) -> Bool {
        lhs.transparent == rhs.transparent &&
            lhs.borderless == rhs.borderless &&
            lhs.clickThrough == rhs.clickThrough &&
            lhs.alwaysOnTop == rhs.alwaysOnTop &&
            lhs.visible == rhs.visible &&
            lhs.position?.0 == rhs.position?.0 &&
            lhs.position?.1 == rhs.position?.1 &&
            lhs.physicalSize?.0 == rhs.physicalSize?.0 &&
            lhs.physicalSize?.1 == rhs.physicalSize?.1 &&
            lhs.minSize?.0 == rhs.minSize?.0 &&
            lhs.minSize?.1 == rhs.minSize?.1 &&
            lhs.maxSize?.0 == rhs.maxSize?.0 &&
            lhs.maxSize?.1 == rhs.maxSize?.1 &&
            lhs.resizable == rhs.resizable
    }
}

/// AppKit properties for an ordinary window (`rune::MacWindowOptions`).
public struct RuneMacWindowOptions: Equatable, Sendable {
    public var shadow: Bool?
    public var level: Int?
    public var collectionBehavior: UInt?
    public var excludeFromCapture: Bool?
    public var nonactivatingPanel: Bool
    public var launcher: Bool
    public var cornerRadius: Float?
    public var isCornerCurveCircular: Bool

    public init(
        shadow: Bool? = nil,
        level: Int? = nil,
        collectionBehavior: UInt? = nil,
        excludeFromCapture: Bool? = nil,
        nonactivatingPanel: Bool = false,
        launcher: Bool = false,
        cornerRadius: Float? = nil,
        isCornerCurveCircular: Bool = false
    ) {
        self.shadow = shadow
        self.level = level
        self.collectionBehavior = collectionBehavior
        self.excludeFromCapture = excludeFromCapture
        self.nonactivatingPanel = nonactivatingPanel
        self.launcher = launcher
        self.cornerRadius = cornerRadius
        self.isCornerCurveCircular = isCornerCurveCircular
    }

    public func nonactivatingPanel(_ enabled: Bool) -> RuneMacWindowOptions {
        var copy = self
        copy.nonactivatingPanel = enabled
        if !enabled {
            copy.launcher = false
        }
        return copy
    }

    public func shadow(_ enabled: Bool) -> RuneMacWindowOptions {
        var copy = self
        copy.shadow = enabled
        return copy
    }

    public func level(_ level: Int) -> RuneMacWindowOptions {
        var copy = self
        copy.level = level
        return copy
    }

    public func collectionBehavior(_ bits: UInt) -> RuneMacWindowOptions {
        var copy = self
        copy.collectionBehavior = bits
        return copy
    }

    public func excludeFromCapture(_ exclude: Bool) -> RuneMacWindowOptions {
        var copy = self
        copy.excludeFromCapture = exclude
        return copy
    }

    public func cornerRadius(_ radius: Float) -> RuneMacWindowOptions {
        var copy = self
        copy.cornerRadius = max(0.0, radius)
        return copy
    }

    public func cornerCurveCircular() -> RuneMacWindowOptions {
        var copy = self
        copy.isCornerCurveCircular = true
        return copy
    }
}

/// Combined ordinary options + native AppKit options (`rune::ConfiguredWindowOptions`).
public struct RuneConfiguredWindowOptions: Equatable, Sendable {
    public var options: RuneWindowOptions
    public var native: RuneMacWindowOptions

    public init(
        options: RuneWindowOptions = .default,
        native: RuneMacWindowOptions = RuneMacWindowOptions()
    ) {
        self.options = options
        self.native = native
    }

    public func macos(_ amend: (RuneMacWindowOptions) -> RuneMacWindowOptions) -> RuneConfiguredWindowOptions {
        RuneConfiguredWindowOptions(options: options, native: amend(native))
    }
}

// MARK: - WindowPlacement & OpenAs (window/spec.rs)

/// A window's place on the desktop in physical pixels (`rune::WindowPlacement`).
public struct WindowPlacement: Equatable, Sendable {
    public var position: (Int32, Int32)
    public var contentPosition: (Int32, Int32)
    public var contentSize: (UInt32, UInt32)
    public var scale: Double
    public var maximized: Bool
    public var minimized: Bool
    public var fullScreen: Bool
    public var restore: ((Int32, Int32), (UInt32, UInt32))?
    public var display: ((Int32, Int32), (UInt32, UInt32))?

    public init(
        position: (Int32, Int32) = (0, 0),
        contentPosition: (Int32, Int32) = (0, 0),
        contentSize: (UInt32, UInt32) = (0, 0),
        scale: Double = 1.0,
        maximized: Bool = false,
        minimized: Bool = false,
        fullScreen: Bool = false,
        restore: ((Int32, Int32), (UInt32, UInt32))? = nil,
        display: ((Int32, Int32), (UInt32, UInt32))? = nil
    ) {
        self.position = position
        self.contentPosition = contentPosition
        self.contentSize = contentSize
        self.scale = scale
        self.maximized = maximized
        self.minimized = minimized
        self.fullScreen = fullScreen
        self.restore = restore
        self.display = display
    }

    public static func == (lhs: WindowPlacement, rhs: WindowPlacement) -> Bool {
        lhs.position == rhs.position &&
            lhs.contentPosition == rhs.contentPosition &&
            lhs.contentSize == rhs.contentSize &&
            lhs.scale == rhs.scale &&
            lhs.maximized == rhs.maximized &&
            lhs.minimized == rhs.minimized &&
            lhs.fullScreen == rhs.fullScreen &&
            lhs.restore?.0.0 == rhs.restore?.0.0 &&
            lhs.restore?.0.1 == rhs.restore?.0.1 &&
            lhs.restore?.1.0 == rhs.restore?.1.0 &&
            lhs.restore?.1.1 == rhs.restore?.1.1 &&
            lhs.display?.0.0 == rhs.display?.0.0 &&
            lhs.display?.0.1 == rhs.display?.0.1 &&
            lhs.display?.1.0 == rhs.display?.1.0 &&
            lhs.display?.1.1 == rhs.display?.1.1
    }
}

/// How a window's first open presents it (`rune::windows::OpenAs`).
public enum RuneOpenAs: Equatable, Sendable {
    case normal
    case maximized
    case fullScreen(maximized: Bool)

    public func maximized(_ on: Bool) -> RuneOpenAs {
        switch (self, on) {
        case (.fullScreen, let m):
            return .fullScreen(maximized: m)
        case (_, true):
            return .maximized
        case (_, false):
            return .normal
        }
    }

    public func fullScreen(_ on: Bool) -> RuneOpenAs {
        switch (self, on) {
        case (.fullScreen(maximized: true), false):
            return .maximized
        case (.fullScreen(maximized: false), false):
            return .normal
        case (.normal, true):
            return .fullScreen(maximized: false)
        case (.maximized, true):
            return .fullScreen(maximized: true)
        default:
            return self
        }
    }

    public var maximizes: Bool {
        switch self {
        case .maximized, .fullScreen(maximized: true):
            return true
        case .normal, .fullScreen(maximized: false):
            return false
        }
    }

    public var fullScreens: Bool {
        if case .fullScreen = self {
            return true
        }
        return false
    }
}

// MARK: - Chrome, Titlebar & ChromeInsets (tooling.rs, window/titlebar.rs)

/// Window frame chrome options (`rune::Chrome`).
public struct RuneChrome: Equatable, Sendable {
    public var fullSizeContent: Bool
    public var trafficLights: (Float, Float)?
    public var dragRegions: Bool

    public static let `default` = RuneChrome(fullSizeContent: true, trafficLights: nil, dragRegions: false)
    public static let trafficLightSize: Float = 14.0
    public static let trafficPitch: Float = 23.0

    public init(
        fullSizeContent: Bool = true,
        trafficLights: (Float, Float)? = nil,
        dragRegions: Bool = false
    ) {
        self.fullSizeContent = fullSizeContent
        self.trafficLights = trafficLights
        self.dragRegions = dragRegions
    }

    /// Headless macOS 26 traffic-light rects `[x, y, w, h]` in points.
    public func trafficLightRects() -> [[Float]]? {
        if !fullSizeContent && trafficLights == nil {
            return nil
        }
        let (x, y) = trafficLights ?? (7.0, 6.0)
        return (0..<3).map { i in
            [x + Float(i) * Self.trafficPitch, y, Self.trafficLightSize, Self.trafficLightSize]
        }
    }

    /// Trailing edge of the zoom button in headless runs.
    public func titlebarInset() -> Float {
        guard let rects = trafficLightRects(), rects.count >= 3 else { return 0.0 }
        return rects[2][0] + rects[2][2]
    }

    /// Whether drag regions govern dragging on macOS (`window::uses_drag_regions`).
    public static func usesDragRegions(chrome: RuneChrome, borderless: Bool, isPanel: Bool) -> Bool {
        chrome.dragRegions && (borderless || chrome.fullSizeContent) && !isPanel
    }

    public static func == (lhs: RuneChrome, rhs: RuneChrome) -> Bool {
        lhs.fullSizeContent == rhs.fullSizeContent &&
            lhs.trafficLights?.0 == rhs.trafficLights?.0 &&
            lhs.trafficLights?.1 == rhs.trafficLights?.1 &&
            lhs.dragRegions == rhs.dragRegions
    }
}

/// Custom app-drawn titlebar specification (`rune::Titlebar`).
public struct RuneTitlebar: Equatable, Sendable {
    public static let captionButtonWidth: Float = 46.0

    public var height: Float
    public var trafficLightsOrigin: (Float, Float)?

    public init(height: Float, trafficLights: (Float, Float)? = nil) {
        self.height = height
        self.trafficLightsOrigin = trafficLights
    }

    public func trafficLights(_ x: Float, _ y: Float) -> RuneTitlebar {
        RuneTitlebar(height: height, trafficLights: (x, y))
    }

    /// macOS chrome derived from this titlebar over base `chrome`.
    public func macChrome(_ chrome: RuneChrome) -> RuneChrome {
        let y = max(0.0, (height - RuneChrome.trafficLightSize) / 2.0).rounded()
        let lights = trafficLightsOrigin ?? chrome.trafficLights ?? (16.0, y)
        return RuneChrome(fullSizeContent: true, trafficLights: lights, dragRegions: true)
    }

    public static func == (lhs: RuneTitlebar, rhs: RuneTitlebar) -> Bool {
        lhs.height == rhs.height &&
            lhs.trafficLightsOrigin?.0 == rhs.trafficLightsOrigin?.0 &&
            lhs.trafficLightsOrigin?.1 == rhs.trafficLightsOrigin?.1
    }
}

/// View-level overrides over base titlebar (`TitlebarSet`).
public struct TitlebarSet: Equatable, Sendable {
    public var titlebar: RuneTitlebar?
    public var height: Float?

    public init(titlebar: RuneTitlebar? = nil, height: Float? = nil) {
        self.titlebar = titlebar
        self.height = height
    }

    public func over(_ base: RuneTitlebar) -> RuneTitlebar {
        var resolved = titlebar ?? base
        if let height {
            resolved.height = height
        }
        return resolved
    }
}

/// Insets reserved for window controls inside an app-drawn titlebar (`rune::ChromeInsets`).
public struct RuneChromeInsets: Equatable, Sendable {
    public var leading: Float
    public var trailing: Float
    public var height: Float

    public static let zero = RuneChromeInsets()

    public init(leading: Float = 0.0, trailing: Float = 0.0, height: Float = 0.0) {
        self.leading = leading
        self.trailing = trailing
        self.height = height
    }

    public func zoomed(_ k: Float) -> RuneChromeInsets {
        RuneChromeInsets(leading: leading / k, trailing: trailing / k, height: height / k)
    }

    public func bits() -> [UInt32] {
        [leading.bitPattern, trailing.bitPattern, height.bitPattern]
    }
}

extension El {
    /// Marks this element as a titlebar drag region (`El::window_drag`).
    public func windowDrag(_ enabled: Bool = true) -> Self {
        var copy = self
        if enabled {
            copy.runtimeExtras["windowDrag"] = true
        } else {
            copy.runtimeExtras.removeValue(forKey: "windowDrag")
        }
        return copy
    }

    public var isWindowDrag: Bool {
        (runtimeExtras["windowDrag"] as? Bool) == true
    }
}

// MARK: - Window Memory Rest State Machine (#819 window/rest.rs)

/// Pure state machine managing idle GPU resource trimming (`crates/rune/src/window/rest.rs`).
public struct WindowRestMachine: Equatable, Sendable {
    public static let restAfter: TimeInterval = 10.0
    public static let pressedAfter: TimeInterval = 1.0

    public enum State: Equatable, Sendable {
        case rested
        case drawing(due: TimeInterval)
        case idle
    }

    public enum Event: Equatable, Sendable {
        case drew(now: TimeInterval, lowMemory: Bool)
        case unseen
        case woke(now: TimeInterval)
    }

    public enum Effect: Equatable, Sendable {
        case giveBackUnused
        case giveBackAll
    }

    public private(set) var state: State

    public init(state: State = .rested) {
        self.state = state
    }

    public var deadline: TimeInterval? {
        switch state {
        case .drawing(let due):
            return due
        case .rested, .idle:
            return nil
        }
    }

    @discardableResult
    public mutating func step(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .drew(let now, let lowMemory)):
            let delay = lowMemory ? Self.pressedAfter : Self.restAfter
            state = .drawing(due: now + delay)
            return []
        case (.drawing(let due), .woke(let now)) where now >= due:
            state = .idle
            return [.giveBackUnused]
        case (.drawing, .unseen), (.idle, .unseen):
            state = .rested
            return [.giveBackAll]
        case (.drawing, .woke), (.idle, .woke), (.rested, .woke), (.rested, .unseen):
            return []
        }
    }
}

// MARK: - WindowHandle & Request Queue (window/handle.rs)

/// Snapshot of a window's frame counters (`SurfaceStats`).
public struct WindowSurfaceStats: Equatable, Sendable {
    public var redraws: UInt64
    public var presents: UInt64
    public var failedDrawables: UInt64
    public var loopTurns: UInt64

    public init(
        redraws: UInt64 = 0,
        presents: UInt64 = 0,
        failedDrawables: UInt64 = 0,
        loopTurns: UInt64 = 0
    ) {
        self.redraws = redraws
        self.presents = presents
        self.failedDrawables = failedDrawables
        self.loopTurns = loopTurns
    }
}

/// Request sent through a `RuneWindowHandle`, either queued before binding or dispatched live.
public enum WindowHandleRequest: Equatable, Sendable {
    case focus
    case open
    case close
    case show
    case hide
    case setPosition(x: Int32, y: Int32)
    case setAlwaysOnTop(Bool)
    case resize(width: Float, height: Float, animate: Bool)
    case center
    case setTitle(String)
    case setTaskbar(TaskbarState)
    case flash(Bool)
    case setClickThrough(Bool)
}

/// A window's native reference that outlives any one host and queues unbound requests (`window::WindowHandle`).
public final class RuneWindowHandle: @unchecked Sendable {
    private enum Route {
        case unbound(queued: [WindowHandleRequest])
        case bound(slot: Int, dispatch: @Sendable (Int, WindowHandleRequest) -> Void)
    }

    public let key: String

    private let lock = NSLock()
    private var route: Route = .unbound(queued: [])
    private var readyFlag = false
    private var numberStorage: UInt32 = 0
    private var statsStorage = WindowSurfaceStats()
    private var placementProvider: (() -> WindowPlacement?)?
    private var clickThroughApplier: ((Bool) -> Result<Void, Error>)?

    public init(key: String) {
        self.key = key
    }

    /// Routes queued and future requests to a live host slot.
    public func bind(
        slot: Int,
        dispatch: @escaping @Sendable (Int, WindowHandleRequest) -> Void,
        placementProvider: (() -> WindowPlacement?)? = nil,
        clickThroughApplier: ((Bool) -> Result<Void, Error>)? = nil
    ) {
        lock.lock()
        let pending: [WindowHandleRequest]
        if case .unbound(let queued) = route {
            pending = queued
        } else {
            pending = []
        }
        route = .bound(slot: slot, dispatch: dispatch)
        self.placementProvider = placementProvider
        self.clickThroughApplier = clickThroughApplier
        lock.unlock()

        for req in pending {
            dispatch(slot, req)
        }
    }

    /// Marks native teardown without discarding future queued requests (`WindowHandle::unbind`).
    public func unbind() {
        lock.lock()
        readyFlag = false
        numberStorage = 0
        placementProvider = nil
        clickThroughApplier = nil
        route = .unbound(queued: [])
        lock.unlock()
    }

    public func setReady(_ ready: Bool) {
        lock.lock()
        readyFlag = ready
        lock.unlock()
    }

    public var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return readyFlag
    }

    public func setWindowNumber(_ number: UInt32) {
        lock.lock()
        numberStorage = number
        lock.unlock()
    }

    public var windowNumber: UInt32? {
        lock.lock()
        defer { lock.unlock() }
        return numberStorage != 0 ? numberStorage : nil
    }

    public func updateSurfaceStats(_ stats: WindowSurfaceStats) {
        lock.lock()
        statsStorage = stats
        lock.unlock()
    }

    public var surfaceStats: WindowSurfaceStats {
        lock.lock()
        defer { lock.unlock() }
        return statsStorage
    }

    /// A headless run takes pending unbound requests each turn (`WindowHandle::take_headless`).
    public func takeHeadless() -> [(slot: Int, request: WindowHandleRequest)] {
        lock.lock()
        defer { lock.unlock() }
        guard case .unbound(let queued) = route else {
            return []
        }
        route = .unbound(queued: [])
        return queued.map { (slot: 0, request: $0) }
    }

    public var headlessPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .unbound(let queued) = route else {
            return false
        }
        return !queued.isEmpty
    }

    private func send(_ request: WindowHandleRequest) {
        lock.lock()
        let activeDispatch: ((Int, WindowHandleRequest) -> Void)?
        let activeSlot: Int
        switch route {
        case .bound(let slot, let dispatch):
            activeDispatch = dispatch
            activeSlot = slot
        case .unbound(var queued):
            queued.append(request)
            route = .unbound(queued: queued)
            activeDispatch = nil
            activeSlot = 0
        }
        lock.unlock()

        activeDispatch?(activeSlot, request)
    }

    public func focus() { send(.focus) }
    public func open() { send(.open) }
    public func close() { send(.close) }
    public func show() { setVisible(true) }
    public func hide() { setVisible(false) }
    public func setVisible(_ visible: Bool) { send(visible ? .show : .hide) }
    public func setPosition(_ position: (Int32, Int32)) { send(.setPosition(x: position.0, y: position.1)) }
    public func setAlwaysOnTop(_ on: Bool) { send(.setAlwaysOnTop(on)) }
    public func resize(_ size: (Float, Float)) { send(.resize(width: size.0, height: size.1, animate: true)) }
    public func resizeInstant(_ size: (Float, Float)) { send(.resize(width: size.0, height: size.1, animate: false)) }
    public func center() { send(.center) }
    public func setTitle(_ title: String) { send(.setTitle(title)) }
    public func setTaskbar(_ state: TaskbarState) { send(.setTaskbar(state)) }
    public func flash(_ on: Bool) { send(.flash(on)) }

    public func setClickThrough(_ clickThrough: Bool) throws {
        lock.lock()
        let applier = clickThroughApplier
        lock.unlock()
        if let applier {
            try applier(clickThrough).get()
        } else {
            send(.setClickThrough(clickThrough))
        }
    }

    public func placement() -> WindowPlacement? {
        lock.lock()
        let provider = placementProvider
        lock.unlock()
        return provider?()
    }
}

// MARK: - Multi-Window Specification & Registry (window/spec.rs)

/// One independent retained tree and state for multi-window apps (`rune::WindowSpec<S>`).
public struct RuneWindowSpec<State> {
    public var key: String
    public var appSpec: AppSpec<State>
    public var options: RuneWindowOptions
    public var macosWindow: RuneMacWindowOptions
    public var chrome: RuneChrome
    public var titlebar: RuneTitlebar?
    public var openAs: RuneOpenAs
    public var inactive: Bool
    public var keepRunning: Bool
    public var onCreated: ((RuneWindowHandle) -> Void)?
    public var onReady: ((RuneWindowHandle) -> Void)?
    public var onQuit: ((inout State, inout Tx) -> Void)?
    public var onReopen: ((inout State, Bool, inout Tx) -> Bool)?
    public var onOpenUrl: ((inout State, String, inout Tx) -> Void)?
    public var childWindows: [AnyRuneWindowSpec]

    public init(key: String, app: AppSpec<State>) {
        self.key = key
        self.appSpec = app
        self.options = .default
        self.macosWindow = RuneMacWindowOptions()
        self.chrome = .default
        self.titlebar = nil
        self.openAs = .normal
        self.inactive = false
        self.keepRunning = false
        self.onCreated = nil
        self.onReady = nil
        self.onQuit = nil
        self.onReopen = nil
        self.onOpenUrl = nil
        self.childWindows = []
    }

    public func options(_ options: RuneWindowOptions) -> RuneWindowSpec<State> {
        var copy = self
        copy.options = options
        copy.macosWindow = RuneMacWindowOptions()
        return copy
    }

    public func configuredOptions(_ configured: RuneConfiguredWindowOptions) -> RuneWindowSpec<State> {
        var copy = self
        copy.options = configured.options
        copy.macosWindow = configured.native
        return copy
    }

    public func chrome(_ chrome: RuneChrome) -> RuneWindowSpec<State> {
        var copy = self
        copy.chrome = chrome
        return copy
    }

    public func titlebar(_ titlebar: RuneTitlebar) -> RuneWindowSpec<State> {
        var copy = self
        copy.titlebar = titlebar
        return copy
    }

    public func inactive(_ on: Bool = true) -> RuneWindowSpec<State> {
        var copy = self
        copy.inactive = on
        return copy
    }

    public func maximized(_ on: Bool) -> RuneWindowSpec<State> {
        var copy = self
        copy.openAs = copy.openAs.maximized(on)
        return copy
    }

    public func fullScreen(_ on: Bool) -> RuneWindowSpec<State> {
        var copy = self
        copy.openAs = copy.openAs.fullScreen(on)
        return copy
    }

    public func keepRunning(_ on: Bool = true) -> RuneWindowSpec<State> {
        var copy = self
        copy.keepRunning = on
        return copy
    }

    public func onCreated(_ body: @escaping (RuneWindowHandle) -> Void) -> RuneWindowSpec<State> {
        var copy = self
        copy.onCreated = body
        return copy
    }

    public func onReady(_ body: @escaping (RuneWindowHandle) -> Void) -> RuneWindowSpec<State> {
        var copy = self
        copy.onReady = body
        return copy
    }

    public func onQuit(_ body: @escaping (inout State, inout Tx) -> Void) -> RuneWindowSpec<State> {
        var copy = self
        copy.onQuit = body
        return copy
    }

    public func onReopen(_ body: @escaping (inout State, Bool, inout Tx) -> Bool) -> RuneWindowSpec<State> {
        var copy = self
        copy.onReopen = body
        return copy
    }

    public func onOpenUrl(_ body: @escaping (inout State, String, inout Tx) -> Void) -> RuneWindowSpec<State> {
        var copy = self
        copy.onOpenUrl = body
        return copy
    }

    /// Adds a secondary child window owned by this window (`App::window`).
    public func window<Child>(_ spec: RuneWindowSpec<Child>) -> (RuneWindowSpec<State>, RuneWindowHandle) {
        let handle = RuneWindowHandle(key: spec.key)
        var child = spec
        child.keepRunning = true
        var copy = self
        copy.childWindows.append(AnyRuneWindowSpec.secondary(child, handle: handle))
        return (copy, handle)
    }

    public func boxed() -> AnyRuneWindowSpec {
        AnyRuneWindowSpec(self, handle: nil, secondary: false)
    }
}

/// Platform-erased host session protocol created by `AnyRuneWindowSpec`.
public protocol HostedWindowEntry: AnyObject {
    var key: String { get }
    var title: String { get }
    var size: Vec2 { get }
    var minSize: Vec2? { get }
    var darkOverride: Bool? { get }
    var options: RuneWindowOptions { get }
    var macosWindow: RuneMacWindowOptions { get }
    var chrome: RuneChrome { get }
    var titlebar: RuneTitlebar? { get }
    var openAs: RuneOpenAs { get }
    var inactive: Bool { get }
    var keepRunning: Bool { get }
    var secondary: Bool { get }
    var handle: RuneWindowHandle { get }

    func createRuntime(pixelScale: Float, systemDark: Bool, reducedMotion: Bool, waker: Waker) -> AnyObject
    func frame(runtimeObj: AnyObject, at time: Double) -> RefScene
    func applyViewport(runtimeObj: AnyObject, viewport: Vec2, pixelScale: Float)
    func setFocused(runtimeObj: AnyObject, focused: Bool)
    func setSystemDark(runtimeObj: AnyObject, dark: Bool)
    func windowTitle(runtimeObj: AnyObject) -> String?
    func quitRequested(runtimeObj: AnyObject) -> Bool
    func relaunchRequested(runtimeObj: AnyObject) -> Bool
    func isAnimating(runtimeObj: AnyObject) -> Bool
    func pointerMove(runtimeObj: AnyObject, to: Vec2, mods: Mods, at: Double)
    func pointerExit(runtimeObj: AnyObject, at: Double)
    func pointerDown(runtimeObj: AnyObject, at: Vec2, button: PointerButton, mods: Mods, at: Double)
    func pointerUp(runtimeObj: AnyObject, at: Vec2, button: PointerButton, mods: Mods, at: Double)
    func wheel(runtimeObj: AnyObject, event: WheelEvent, at: Vec2, now: Double)
    func keyDown(runtimeObj: AnyObject, event: KeyEvent, at: Double) -> Bool
    func fileDrop(runtimeObj: AnyObject, event: FileDropPhase, at: Double)
    func copyTitlebarDragHits(runtimeObj: AnyObject, point: Vec2) -> Bool
    func runQuitHook(runtimeObj: AnyObject)
    func runReopenHook(runtimeObj: AnyObject, hasVisibleWindows: Bool) -> Bool
    func runOpenUrlHook(runtimeObj: AnyObject, url: String)
    func fireOnCreated()
    func fireOnReady()
    func trimIdleCaches(runtimeObj: AnyObject, all: Bool)
    func runHeadless(args: ToolingArgs) throws -> HeadlessRunner.Output
}

private final class TypedHostedWindowEntry<State>: HostedWindowEntry {
    private var spec: RuneWindowSpec<State>
    let secondary: Bool
    let handle: RuneWindowHandle
    private var didFireCreated = false

    init(spec: RuneWindowSpec<State>, handle: RuneWindowHandle, secondary: Bool) {
        self.spec = spec
        self.handle = handle
        self.secondary = secondary
    }

    var key: String { spec.key }
    var title: String { spec.appSpec.title }
    var size: Vec2 { spec.appSpec.size }
    var minSize: Vec2? { spec.appSpec.minSize }
    var darkOverride: Bool? { spec.appSpec.dark }
    var options: RuneWindowOptions { spec.options }
    var macosWindow: RuneMacWindowOptions { spec.macosWindow }
    var chrome: RuneChrome { spec.chrome }
    var titlebar: RuneTitlebar? { spec.titlebar }
    var openAs: RuneOpenAs { spec.openAs }
    var inactive: Bool { spec.inactive }
    var keepRunning: Bool { spec.keepRunning }

    func createRuntime(pixelScale: Float, systemDark: Bool, reducedMotion: Bool, waker: Waker) -> AnyObject {
        let initialState = spec.appSpec.makeState()
        let rt = Runtime<State>(
            state: initialState,
            viewport: spec.appSpec.size,
            pixelScale: pixelScale,
            systemDark: spec.appSpec.dark ?? systemDark,
            reducedMotion: reducedMotion,
            waker: waker,
            onKey: spec.appSpec.onKey,
            view: spec.appSpec.view
        )
        rt.windowTitle = spec.appSpec.title
        rt.urlOpener.headless = false
        if let onQuit = spec.onQuit {
            nonisolated(unsafe) weak let weakRt = rt
            nonisolated(unsafe) let quitFn = onQuit
            QuitLifecycle.registerQuitHook(key: rt) {
                guard let r = weakRt else { return }
                var tx = Tx()
                quitFn(&r.state, &tx)
                r.markNeedsCommit()
            }
        }
        return rt
    }

    private func rt(_ obj: AnyObject) -> Runtime<State> {
        // Guaranteed by TypedHostedWindowEntry lifecycle.
        obj as! Runtime<State>
    }

    func frame(runtimeObj: AnyObject, at time: Double) -> RefScene {
        rt(runtimeObj).frame(at: time)
    }

    func applyViewport(runtimeObj: AnyObject, viewport: Vec2, pixelScale: Float) {
        let r = rt(runtimeObj)
        r.viewport = viewport
        r.pixelScale = pixelScale
    }

    func setFocused(runtimeObj: AnyObject, focused: Bool) {
        rt(runtimeObj).windowFocused = focused
    }

    func setSystemDark(runtimeObj: AnyObject, dark: Bool) {
        rt(runtimeObj).systemDark = dark
    }

    func windowTitle(runtimeObj: AnyObject) -> String? {
        rt(runtimeObj).windowTitle
    }

    func quitRequested(runtimeObj: AnyObject) -> Bool {
        rt(runtimeObj).quitRequested
    }

    func relaunchRequested(runtimeObj: AnyObject) -> Bool {
        rt(runtimeObj).relaunchRequested
    }

    func isAnimating(runtimeObj: AnyObject) -> Bool {
        rt(runtimeObj).isAnimating
    }

    func pointerMove(runtimeObj: AnyObject, to: Vec2, mods: Mods, at: Double) {
        rt(runtimeObj).pointerMove(to: to, mods: mods, at: at)
    }

    func pointerExit(runtimeObj: AnyObject, at: Double) {
        rt(runtimeObj).pointerExit(at: at)
    }

    func pointerDown(runtimeObj: AnyObject, at: Vec2, button: PointerButton, mods: Mods, at time: Double) {
        rt(runtimeObj).pointerDown(at: at, button: button, mods: mods, at: time)
    }

    func pointerUp(runtimeObj: AnyObject, at: Vec2, button: PointerButton, mods: Mods, at time: Double) {
        rt(runtimeObj).pointerUp(at: at, button: button, mods: mods, at: time)
    }

    func wheel(runtimeObj: AnyObject, event: WheelEvent, at: Vec2, now: Double) {
        rt(runtimeObj).wheel(event, at: at, now: now)
    }

    func keyDown(runtimeObj: AnyObject, event: KeyEvent, at: Double) -> Bool {
        rt(runtimeObj).keyDown(event, at: at)
    }

    func fileDrop(runtimeObj: AnyObject, event: FileDropPhase, at: Double) {
        rt(runtimeObj).fileDrop(event, at: at)
    }

    func copyTitlebarDragHits(runtimeObj: AnyObject, point: Vec2) -> Bool {
        let r = rt(runtimeObj)
        guard let hit = r.hitTestElement(at: point) else { return false }
        if hit.role == .button || hit.role == .textInput || hit.focusable {
            return false
        }
        if let tb = spec.titlebar {
            return point.y <= tb.height
        }
        return false
    }

    func runQuitHook(runtimeObj: AnyObject) {
        guard let onQuit = spec.onQuit else { return }
        let r = rt(runtimeObj)
        var tx = Tx()
        onQuit(&r.state, &tx)
        r.markNeedsCommit()
    }

    func runReopenHook(runtimeObj: AnyObject, hasVisibleWindows: Bool) -> Bool {
        guard let onReopen = spec.onReopen else { return false }
        let r = rt(runtimeObj)
        var tx = Tx()
        let handled = onReopen(&r.state, hasVisibleWindows, &tx)
        if tx.quitRequested {
            _ = QuitLifecycle.send(.start(ending: false, after: .exit))
        }
        r.markNeedsCommit()
        return handled
    }

    func runOpenUrlHook(runtimeObj: AnyObject, url: String) {
        guard let onOpenUrl = spec.onOpenUrl else { return }
        let r = rt(runtimeObj)
        var tx = Tx()
        onOpenUrl(&r.state, url, &tx)
        if tx.quitRequested {
            _ = QuitLifecycle.send(.start(ending: false, after: .exit))
        }
        r.markNeedsCommit()
    }

    func fireOnCreated() {
        guard !didFireCreated else { return }
        didFireCreated = true
        spec.onCreated?(handle)
    }

    func fireOnReady() {
        spec.onReady?(handle)
    }

    func trimIdleCaches(runtimeObj: AnyObject, all: Bool) {
        let _ = (runtimeObj, all)
        // Renderer-level GPU memory trim hooks run on the host window controller.
    }

    func runHeadless(args: ToolingArgs) throws -> HeadlessRunner.Output {
        try HeadlessRunner.run(spec.appSpec, args: args)
    }
}

/// Type-erased multi-window spec (`rune::AnyWindowSpec`).
public struct AnyRuneWindowSpec {
    public let key: String
    public let handle: RuneWindowHandle
    public let secondary: Bool
    private var childWindows: [AnyRuneWindowSpec]
    private let entry: HostedWindowEntry

    public init<State>(
        _ spec: RuneWindowSpec<State>,
        handle: RuneWindowHandle? = nil,
        secondary: Bool = false
    ) {
        let h = handle ?? RuneWindowHandle(key: spec.key)
        self.key = spec.key
        self.handle = h
        self.secondary = secondary
        self.childWindows = spec.childWindows
        self.entry = TypedHostedWindowEntry(spec: spec, handle: h, secondary: secondary)
    }

    public static func secondary<State>(
        _ spec: RuneWindowSpec<State>,
        handle: RuneWindowHandle
    ) -> AnyRuneWindowSpec {
        AnyRuneWindowSpec(spec, handle: handle, secondary: true)
    }

    public func makeHostEntry() -> HostedWindowEntry {
        entry
    }

    public mutating func takeChildWindows() -> [AnyRuneWindowSpec] {
        let children = childWindows
        childWindows.removeAll()
        return children
    }
}

/// Errors from multi-window key validation or launch (`window::spec::validate`).
public enum MultiWindowError: Error, LocalizedError, Equatable {
    case emptyOrDuplicateKey(String)

    public var errorDescription: String? {
        switch self {
        case .emptyOrDuplicateKey(let key):
            return "empty or duplicate window key: \(key)"
        }
    }
}

/// Multi-window flattening, validation, dynamic opening, and native launch (`crates/rune/src/window/spec.rs`).
public enum RuneMultiWindow {
    private static let openedLock = NSLock()
    nonisolated(unsafe) private static var pendingOpened: [AnyRuneWindowSpec] = []

    /// Each window followed depth-first by any secondary windows attached via `window(_:)`.
    public static func flatten(_ windows: [AnyRuneWindowSpec]) -> [AnyRuneWindowSpec] {
        var out: [AnyRuneWindowSpec] = []
        for var w in windows {
            let children = w.takeChildWindows()
            out.append(w)
            out.append(contentsOf: flatten(children))
        }
        return out
    }

    /// Ensures every window has a non-empty, unique key.
    public static func validate(_ windows: [AnyRuneWindowSpec]) throws {
        var seen = Set<String>()
        for w in windows {
            guard !w.key.isEmpty, seen.insert(w.key).inserted else {
                throw MultiWindowError.emptyOrDuplicateKey(w.key)
            }
        }
    }

    /// Queues a new window to open in the running event loop at the end of the turn (`open_window`).
    @discardableResult
    public static func openWindow<State>(
        _ spec: RuneWindowSpec<State>,
        headless: Bool = false
    ) -> RuneWindowHandle {
        let anySpec = AnyRuneWindowSpec(spec, handle: RuneWindowHandle(key: spec.key), secondary: false)
        if !headless {
            openedLock.lock()
            pendingOpened.append(anySpec)
            openedLock.unlock()
        }
        return anySpec.handle
    }

    /// Drains windows queued via `openWindow`.
    public static func takeOpened() -> [AnyRuneWindowSpec] {
        openedLock.lock()
        let out = pendingOpened
        pendingOpened.removeAll()
        openedLock.unlock()
        return out
    }

    /// Runs a multi-window application (`run_windows`).
    @MainActor
    public static func runWindows(
        _ windows: [AnyRuneWindowSpec],
        options: RuneRunOptions = RuneRunOptions(),
        arguments: [String]? = nil
    ) throws {
        let flat = flatten(windows)
        try validate(flat)
        let parsed = arguments.map { ToolingArgs.parse($0) } ?? ToolingArgs.parse()
        if parsed.isHeadlessRequested {
            if let first = flat.first {
                _ = try first.makeHostEntry().runHeadless(args: parsed)
            }
            return
        }
        #if os(macOS)
        try RuneMultiWindowHost.run(flat, options: options, parsed: parsed)
        #else
        if let first = flat.first {
            _ = try first.makeHostEntry().runHeadless(args: parsed)
        }
        #endif
    }
}
