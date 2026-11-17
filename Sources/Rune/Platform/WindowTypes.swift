import Foundation
import RuneMotion
import RuneRef
#if os(macOS)
import QuartzCore
#endif

// MARK: - Display & Run Options (window/spec.rs)

/// Native display identifier (`rune::NativeDisplayId`).
public enum NativeDisplayId: Hashable, Sendable, Codable {
    case macOS(UInt32)
    case wayland(String)
    case other(UInt64)
}

/// Platform display identifier (`rune::DisplayId`).
public struct RuneDisplayId: Hashable, Sendable, Codable {
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

// MARK: - Window Attributes Snapshot (window/spec.rs)

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

// MARK: - WindowPlacement & TitlebarSet (window/spec.rs, window/titlebar.rs)

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

/// View-level overrides over base titlebar (`TitlebarSet`).
public struct TitlebarSet: Equatable, Sendable {
    public var titlebar: Titlebar?
    public var height: Float?

    public init(titlebar: Titlebar? = nil, height: Float? = nil) {
        self.titlebar = titlebar
        self.height = height
    }

    public func over(_ base: Titlebar) -> Titlebar {
        var resolved = titlebar ?? base
        if let height {
            resolved.height = height
        }
        return resolved
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

/// Request sent through a `WindowHandle`, either queued before binding or dispatched live.
public enum WindowHandleRequest: Equatable, Sendable {
    case focus
    case minimize
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

// MARK: - Multi-Window Host Registry (window/spec.rs)

/// Platform-erased host session protocol created by `AnyWindowSpec`.
public protocol HostedWindowEntry: AnyObject {
    var key: String { get }
    var title: String { get }
    var size: Vec2 { get }
    var minSize: Vec2? { get }
    var fitsContentHeight: Bool { get }
    var darkOverride: Bool? { get }
    var options: WindowOptions { get }
    var macosWindow: MacWindowOptions { get }
    var chrome: Chrome { get }
    var titlebar: Titlebar? { get }
    var openAs: OpenAs { get }
    var inactive: Bool { get }
    var keepRunning: Bool { get }
    var secondary: Bool { get }
    var handle: WindowHandle { get }

    func createRuntime(pixelScale: Float, systemDark: Bool, reducedMotion: Bool, waker: Waker) -> AnyObject
    func frame(runtimeObj: AnyObject, at time: Double) -> RefScene
    /// The runtime as its host's `CoveredWindowDriver` drives it (`covered_step`, #995).
    func coveredRuntime(runtimeObj: AnyObject) -> any CoveredWindowRuntime
    func applyViewport(runtimeObj: AnyObject, viewport: Vec2, pixelScale: Float)
    func stepViewport(runtimeObj: AnyObject, viewport: Vec2, pixelScale: Float)
    func takeWindowFrameRequest(runtimeObj: AnyObject) -> WindowFrameRequest?
    func runtimeViewport(runtimeObj: AnyObject) -> Vec2
    func setWindowResting(runtimeObj: AnyObject, resting: Bool)
    func applyAppStateUpdates(runtimeObj: AnyObject, at now: Double)
    func applyAppStateUpdates(runtimeObj: AnyObject, at now: Double, shortcutGuard: ShortcutGuard?)
    func markMenusRunning(_ running: Bool)
    @MainActor func syncNativeMenus(
        runtimeObj: AnyObject,
        appliedRevision: inout UInt64,
        nowProvider: @escaping () -> Double,
        onDispatched: @escaping () -> Void
    )
    func helpRegionsList(runtimeObj: AnyObject) -> [(MotionRect, String)]
    func setFocused(runtimeObj: AnyObject, focused: Bool)
    /// The system's accessibility display options changed: re-read reduced motion, contrast and Increase Contrast.
    func readSystemAccessibilitySettings(runtimeObj: AnyObject, forceReducedMotion: Bool)
    func setSystemDark(runtimeObj: AnyObject, dark: Bool)
    func windowTitle(runtimeObj: AnyObject) -> String?
    func quitRequested(runtimeObj: AnyObject) -> Bool
    func relaunchRequested(runtimeObj: AnyObject) -> Bool
    func isAnimating(runtimeObj: AnyObject) -> Bool
    func pointerMove(runtimeObj: AnyObject, to: Vec2, mods: Mods, at: Double)
    /// Dispatches platform input `body` in the scope holding when it arrived (`Runtime.hostInput`).
    func hostInput(runtimeObj: AnyObject, kind: HostInputKind, eventTimestamp: Double?, _ body: () -> Void)
    func pointerExit(runtimeObj: AnyObject, at: Double)
    func pointerDown(runtimeObj: AnyObject, at: Vec2, button: PointerButton, mods: Mods, at: Double)
    func pointerUp(runtimeObj: AnyObject, at: Vec2, button: PointerButton, mods: Mods, at: Double)
    func wheel(runtimeObj: AnyObject, event: WheelEvent, at: Vec2, now: Double)
    func keyDown(runtimeObj: AnyObject, event: KeyEvent, at: Double) -> Bool
    @MainActor func keyDownWithClipboardSync(runtimeObj: AnyObject, event: KeyEvent, isRepeat: Bool, at: Double) -> Bool
    func fileDrop(runtimeObj: AnyObject, event: FileDropPhase, at: Double)
    func acceptsDrop(runtimeObj: AnyObject, urls: [URL], at: Vec2) -> Bool
    func takePopup(runtimeObj: AnyObject) -> Result<PopupShow, PopupMenuError>?
    func resolvePopup(runtimeObj: AnyObject, picked: String?)
    func cancelPopups(runtimeObj: AnyObject)
    func takeFileDialog(runtimeObj: AnyObject) -> FileDialogPending?
    func answerFileDialog(runtimeObj: AnyObject, id: UInt64, result: FileDialogResult)
    func cancelFileDialogs(runtimeObj: AnyObject, at: Double)
    func takeDragOutStart(runtimeObj: AnyObject) -> DragOutStart?
    @MainActor func syncWindowChrome(runtimeObj: AnyObject, window: AnyObject)
    func takeTitlebarChanged(runtimeObj: AnyObject) -> Bool
    func finishDragOut(runtimeObj: AnyObject, outcome: DragOutcome, at: Double)
    func copyTitlebarDragHits(runtimeObj: AnyObject, point: Vec2) -> Bool
    func runQuitHook(runtimeObj: AnyObject)
    func runReopenHook(runtimeObj: AnyObject, hasVisibleWindows: Bool) -> Bool
    func runOpenUrlHook(runtimeObj: AnyObject, url: String)
    func fireOnCreated()
    func fireOnReady()
    func trimIdleCaches(runtimeObj: AnyObject, all: Bool)
    func viewCommitCount(runtimeObj: AnyObject) -> Int
    func dispatchModifiers(runtimeObj: AnyObject, mods: Mods, at: Double)
    func hasFocusedTextInput(runtimeObj: AnyObject) -> Bool
    func hasImeTarget(runtimeObj: AnyObject) -> Bool
    func imeOptionAsAlt(runtimeObj: AnyObject) -> Bool
    func hasSecureFocus(runtimeObj: AnyObject) -> Bool
    func consumeImeReset(runtimeObj: AnyObject) -> Bool
    func focusedImeSnapshot(runtimeObj: AnyObject) -> ImeText?
    func focusedCaretRect(runtimeObj: AnyObject) -> MotionRect?
    @discardableResult func dispatchImeEvent(runtimeObj: AnyObject, event: ImeEvent, at: Double) -> Bool
    func currentCursor(runtimeObj: AnyObject) -> Cursor
    func accessibilitySnapshot(runtimeObj: AnyObject) -> AccessibilityNode
    /// `Tx::announce`'s window live region (`Runtime.a11yAnnouncement`).
    func accessibilityAnnouncement(runtimeObj: AnyObject) -> AccessibilityAnnouncement
    /// Keeps the runtime dirty while the accessibility adapter holds words back (#980).
    func markAccessibilityDirty(runtimeObj: AnyObject)
    @discardableResult func performAccessibilityAction(runtimeObj: AnyObject, id: String, action: AccessibilityAction, at: Double) -> Bool
    @discardableResult func selectAccessibilityText(runtimeObj: AnyObject, id: String, range: Range<Int>, at: Double) -> Bool
    @discardableResult func performAccessibilitySetValue(runtimeObj: AnyObject, id: String, value: AccessibilityActionValue, at: Double) -> Bool
    func shortcutRegistry(runtimeObj: AnyObject) -> ShortcutRegistry?
    var hasAppGlobalShortcuts: Bool { get }
    func attachShortcuts(wake: Waker, headless: Bool) -> ShortcutGuard?
    func runHeadless(args: ToolingArgs) throws -> HeadlessRunner.Output
    func makeDesktopMember(scale: Float, dark: Bool, isMain: Bool) -> any DesktopMember
}

extension HostedWindowEntry {
    public var fitsContentHeight: Bool { false }

    internal var hostMinSize: (Float, Float)? {
        let appMin = minSize.map { ($0.x, $0.y) }
        return fitsContentHeight ? options.fitMinSize(appMin: appMin) : appMin
    }
}

/// Production frames and timed wakes for a native window opened from an `AppWindowSpec`.
internal protocol NativeHostedWindowEntry: HostedWindowEntry {
    func wakeDeadline(runtimeObj: AnyObject, covered: Bool) -> Double?
    #if os(macOS)
    func renderFrame(runtimeObj: AnyObject, renderer: MetalRenderer, at time: Double, nativeMaterials: Bool) -> RenderFrame
    var compositorAnimating: Bool { get }
    func present(_ frame: RenderFrame, drawable: CAMetalDrawable, renderer: MetalRenderer, runtimeObj: AnyObject,
                 dt: Float, started: Double, updateMs: Double, synchronized: Bool, committed: Bool)
    #endif
}

final class TypedHostedWindowEntry<State>: NativeHostedWindowEntry {
    let spec: AppWindowSpec<State>
    #if os(macOS)
    private let reports: FrameReports<State>?
    var compositorAnimating: Bool { spec.compositor?.isAnimating ?? false }
    #endif
    let secondary: Bool
    let handle: WindowHandle
    private var didFireCreated = false

    init(spec: AppWindowSpec<State>, handle: WindowHandle, secondary: Bool) {
        self.spec = spec
        #if os(macOS)
        reports = spec.onFrameEncoded != nil || spec.onFrameDrawn != nil || spec.frameDrawnUpdate != nil
            ? FrameReports(onFrameEncoded: spec.onFrameEncoded, onFrameDrawn: spec.frameDrawnUpdate,
                           onInspectDrawn: spec.onFrameDrawn, windowKey: spec.key)
            : nil
        #endif
        self.handle = handle
        self.secondary = secondary
    }

    var key: String { spec.key }
    var title: String { spec.appSpec.title }
    var size: Vec2 { spec.appSpec.size }
    var minSize: Vec2? { spec.appSpec.minSize }
    var fitsContentHeight: Bool { spec.fitContentHeight }
    var darkOverride: Bool? { spec.appSpec.dark }
    var options: WindowOptions { spec.options }
    var macosWindow: MacWindowOptions { spec.macosWindow }
    var chrome: Chrome { spec.chrome }
    var titlebar: Titlebar? { spec.titlebar }
    var openAs: OpenAs { spec.openAs }
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
        rt.srgbBlend = spec.appSpec.srgbBlend
        rt.poll = spec.appSpec.poll
        rt.onAppFileDrop = spec.appSpec.onFileDrop
        rt.onFileDrop = spec.appSpec.onFileDropPhase
        rt.nativeHelp = true
        rt.fitHeight = spec.fitContentHeight
        rt.readSystemContrastSettings()
        spec.configureRuntime?(rt)
        spec.appShared?.setWaker(waker)
        if rt.fitHeight {
            let limits = options.sizeLimits(appMin: hostMinSize)
            let clamped = WindowFrame.clampSize(
                (rt.viewport.x, rt.contentHeight()),
                min: limits.0,
                max: limits.1
            )
            rt.setViewport(Vec2(clamped.0, clamped.1), pixelScale: pixelScale)
        }
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

    func wakeDeadline(runtimeObj: AnyObject, covered: Bool) -> Double? {
        rt(runtimeObj).windowWakeDeadline(covered: covered)
    }

    #if os(macOS)
    func renderFrame(runtimeObj: AnyObject, renderer: MetalRenderer, at time: Double, nativeMaterials: Bool) -> RenderFrame {
        let runtime = rt(runtimeObj)
        runtime.nativeMaterials = nativeMaterials
        return renderer.frame(runtime, at: time)
    }

    func present(_ frame: RenderFrame, drawable: CAMetalDrawable, renderer: MetalRenderer, runtimeObj: AnyObject,
                 dt: Float, started: Double, updateMs: Double, synchronized: Bool, committed: Bool) {
        let runtime = rt(runtimeObj)
        let count = renderer.present(frame: frame, drawable: drawable, compositor: spec.compositor, runtime: runtime,
                                     dt: dt, updateMilliseconds: updateMs, synchronized: synchronized)
        reports?.presented(frame, at: runtime.currentTime, started: started, updateMs: updateMs, drawCount: count,
                           committed: committed, runtime: runtime, compositor: spec.compositor)
    }
    #endif

    func coveredRuntime(runtimeObj: AnyObject) -> any CoveredWindowRuntime {
        rt(runtimeObj)
    }

    func applyViewport(runtimeObj: AnyObject, viewport: Vec2, pixelScale: Float) {
        rt(runtimeObj).setViewport(viewport, pixelScale: pixelScale)
    }

    func stepViewport(runtimeObj: AnyObject, viewport: Vec2, pixelScale: Float) {
        rt(runtimeObj).stepViewport(viewport, pixelScale: pixelScale)
    }

    func takeWindowFrameRequest(runtimeObj: AnyObject) -> WindowFrameRequest? {
        rt(runtimeObj).takeWindowFrameRequest()
    }

    func runtimeViewport(runtimeObj: AnyObject) -> Vec2 {
        rt(runtimeObj).viewport
    }

    func setWindowResting(runtimeObj: AnyObject, resting: Bool) {
        rt(runtimeObj).windowResting = resting
    }

    func applyAppStateUpdates(runtimeObj: AnyObject, at now: Double) {
        applyAppStateUpdates(runtimeObj: runtimeObj, at: now, shortcutGuard: nil)
    }

    func applyAppStateUpdates(runtimeObj: AnyObject, at now: Double, shortcutGuard: ShortcutGuard?) {
        guard let appShared = spec.appShared else { return }
        shortcutGuard?.drain()
        let req = if let shortcutGuard {
            shortcutGuard.withReceiving {
                appShared.applyStateUpdates(to: rt(runtimeObj), at: now)
            }
        } else {
            appShared.applyStateUpdates(to: rt(runtimeObj), at: now)
        }
        if let pos = req.position {
            handle.setPosition((Int32(pos.x.rounded()), Int32(pos.y.rounded())))
        }
        if let place = req.place, let pos = place.position {
            handle.setPosition((Int32(pos.x.rounded()), Int32(pos.y.rounded())))
        }
        switch req.window {
        case .open: handle.open()
        case .show: handle.show()
        case .hide: handle.hide()
        case .close: handle.close()
        case .none: break
        }
        switch req.activation {
        case .activate, .focus: handle.focus()
        case .minimize, .none: break
        }
    }

    func markMenusRunning(_ running: Bool) {
        guard let appShared = spec.appShared else { return }
        if running {
            AppMenuBridge.attach(spec.menuItems, to: appShared)
        } else {
            AppMenuBridge.markRunning(appShared, running: false)
        }
    }

    @MainActor func syncNativeMenus(
        runtimeObj: AnyObject,
        appliedRevision: inout UInt64,
        nowProvider: @escaping () -> Double,
        onDispatched: @escaping () -> Void
    ) {
        #if os(macOS)
        guard let appShared = spec.appShared else { return }
        let snap = AppMenuBridge.snapshot(for: appShared)
        guard snap.revision != appliedRevision else { return }
        appliedRevision = snap.revision
        if snap.items.isEmpty {
            RuneNativeMenuHost.shared.clear()
            return
        }
        let revision = snap.revision
        do {
            try RuneNativeMenuHost.shared.apply(items: snap.items) { [weak appShared] itemId in
                guard let appShared,
                      AppMenuBridge.fireIfCurrent(id: itemId, revision: revision, for: appShared) else { return }
                onDispatched()
            }
        } catch let err as MenuError {
            AppMenuBridge.recordError(err, for: appShared)
        } catch {
            AppMenuBridge.recordError(.unsupported, for: appShared)
        }
        #else
        let _ = (runtimeObj, appliedRevision, nowProvider, onDispatched)
        #endif
    }

    func helpRegionsList(runtimeObj: AnyObject) -> [(MotionRect, String)] {
        rt(runtimeObj).helpRegionsList()
    }

    func setFocused(runtimeObj: AnyObject, focused: Bool) {
        let r = rt(runtimeObj)
        r.dispatchFocus(focused)
    }

    func readSystemAccessibilitySettings(runtimeObj: AnyObject, forceReducedMotion: Bool) {
        rt(runtimeObj).readSystemAccessibilitySettings(forceReducedMotion: forceReducedMotion)
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

    func hostInput(runtimeObj: AnyObject, kind: HostInputKind, eventTimestamp: Double?, _ body: () -> Void) {
        rt(runtimeObj).hostInput(kind, eventTimestamp: eventTimestamp, body)
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

    @MainActor
    func keyDownWithClipboardSync(runtimeObj: AnyObject, event: KeyEvent, isRepeat: Bool, at: Double) -> Bool {
        #if os(macOS)
        return MacOSClipboardSync.dispatchKeyWithSync(event, runtime: rt(runtimeObj), isRepeat: isRepeat, at: at)
        #else
        return rt(runtimeObj).keyDown(event, isRepeat: isRepeat, at: at)
        #endif
    }

    func fileDrop(runtimeObj: AnyObject, event: FileDropPhase, at: Double) {
        rt(runtimeObj).fileDrop(event, at: at)
    }

    func acceptsDrop(runtimeObj: AnyObject, urls: [URL], at: Vec2) -> Bool {
        rt(runtimeObj).acceptsDrop(urls, at: at)
    }

    func takePopup(runtimeObj: AnyObject) -> Result<PopupShow, PopupMenuError>? {
        rt(runtimeObj).takePopup()
    }

    func resolvePopup(runtimeObj: AnyObject, picked: String?) {
        try? rt(runtimeObj).resolvePopup(picked)
    }

    func cancelPopups(runtimeObj: AnyObject) {
        rt(runtimeObj).cancelPopups()
    }

    func takeFileDialog(runtimeObj: AnyObject) -> FileDialogPending? {
        rt(runtimeObj).takeFileDialog()
    }

    func answerFileDialog(runtimeObj: AnyObject, id: UInt64, result: FileDialogResult) {
        rt(runtimeObj).answerFileDialog(id, result)
    }

    func viewCommitCount(runtimeObj: AnyObject) -> Int {
        rt(runtimeObj).viewCommitCount
    }

    func dispatchModifiers(runtimeObj: AnyObject, mods: Mods, at time: Double) {
        rt(runtimeObj).dispatchModifiers(mods, at: time)
    }

    func hasFocusedTextInput(runtimeObj: AnyObject) -> Bool {
        rt(runtimeObj).hasFocusedTextInput
    }

    func hasImeTarget(runtimeObj: AnyObject) -> Bool {
        rt(runtimeObj).hasImeTarget
    }

    func imeOptionAsAlt(runtimeObj: AnyObject) -> Bool {
        rt(runtimeObj).effectiveImeOptionAsAlt
    }

    func hasSecureFocus(runtimeObj: AnyObject) -> Bool {
        rt(runtimeObj).hasSecureFocus
    }

    func consumeImeReset(runtimeObj: AnyObject) -> Bool {
        rt(runtimeObj).consumeImeReset()
    }

    func focusedImeSnapshot(runtimeObj: AnyObject) -> ImeText? {
        rt(runtimeObj).focusedImeSnapshot()
    }

    func focusedCaretRect(runtimeObj: AnyObject) -> MotionRect? {
        rt(runtimeObj).focusedCaretRect()
    }

    @discardableResult
    func dispatchImeEvent(runtimeObj: AnyObject, event: ImeEvent, at time: Double) -> Bool {
        rt(runtimeObj).dispatchImeEvent(event, at: time)
    }

    func currentCursor(runtimeObj: AnyObject) -> Cursor {
        rt(runtimeObj).currentCursor()
    }

    func accessibilitySnapshot(runtimeObj: AnyObject) -> AccessibilityNode {
        rt(runtimeObj).accessibilitySnapshot()
    }

    func accessibilityAnnouncement(runtimeObj: AnyObject) -> AccessibilityAnnouncement {
        rt(runtimeObj).a11yAnnouncement
    }

    func markAccessibilityDirty(runtimeObj: AnyObject) {
        rt(runtimeObj).markNeedsCommit()
    }

    @discardableResult
    func performAccessibilityAction(runtimeObj: AnyObject, id: String, action: AccessibilityAction, at time: Double) -> Bool {
        rt(runtimeObj).performAccessibilityAction(id, action: action, at: time)
    }

    @discardableResult
    func selectAccessibilityText(runtimeObj: AnyObject, id: String, range: Range<Int>, at time: Double) -> Bool {
        rt(runtimeObj).accessibilitySelectText(id, range: range, at: time)
    }

    @discardableResult
    func performAccessibilitySetValue(runtimeObj: AnyObject, id: String, value: AccessibilityActionValue, at time: Double) -> Bool {
        rt(runtimeObj).accessibilityAction(id, .setValue, value: value, at: time)
    }

    func cancelFileDialogs(runtimeObj: AnyObject, at: Double) {
        rt(runtimeObj).cancelFileDialogs(at: at)
    }

    func takeDragOutStart(runtimeObj: AnyObject) -> DragOutStart? {
        rt(runtimeObj).takeDragOutStart()
    }

    /// `window/chrome.rs::sync_chrome` for this window's `chrome` and `titlebar` (an `NSWindow`
    /// on macOS; nothing elsewhere).
    @MainActor func syncWindowChrome(runtimeObj: AnyObject, window: AnyObject) {
        #if os(macOS)
        // A borderless window has no titlebar (`window.rs`: `app.titlebar.filter(|_| !borderless)`).
        let titlebar = spec.options.borderless ? nil : spec.titlebar
        rt(runtimeObj).syncWindowChrome(windowObject: window, chrome: spec.chrome, titlebar: titlebar)
        #else
        let _ = (runtimeObj, window)
        #endif
    }

    func takeTitlebarChanged(runtimeObj: AnyObject) -> Bool {
        rt(runtimeObj).takeTitlebarChanged()
    }

    func finishDragOut(runtimeObj: AnyObject, outcome: DragOutcome, at: Double) {
        rt(runtimeObj).finishDragOut(outcome, at: at)
    }

    func copyTitlebarDragHits(runtimeObj: AnyObject, point: Vec2) -> Bool {
        guard spec.titlebar != nil || spec.chrome.dragRegions else {
            return false
        }
        return rt(runtimeObj).isBareTitlebarDragRegion(at: point)
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
        _ = all
        rt(runtimeObj).rest(at: ProcessInfo.processInfo.systemUptime)
    }

    func shortcutRegistry(runtimeObj: AnyObject) -> ShortcutRegistry? {
        rt(runtimeObj).shortcutRegistry
    }

    func makeDesktopMember(scale: Float, dark: Bool, isMain: Bool) -> any DesktopMember {
        DesktopWindow(
            key: spec.key,
            spec: spec,
            scale: scale,
            dark: spec.appSpec.dark ?? dark,
            isMain: isMain
        )
    }

    var hasAppGlobalShortcuts: Bool {
        spec.appShared?.shortcuts.hasAppShortcuts ?? false
    }

    func attachShortcuts(wake: Waker, headless: Bool) -> ShortcutGuard? {
        guard let appShared = spec.appShared else { return nil }
        return ShortcutGuard.attach(shared: appShared, wake: wake, headless: headless)
    }

    func runHeadless(args: ToolingArgs) throws -> HeadlessRunner.Output {
        let resolvedChrome = spec.titlebar?.macChrome(spec.chrome) ?? spec.chrome
        let configure = spec.configureRuntime
        return try HeadlessRunner.runHostedWindowSpec(
            spec.appSpec,
            args: args,
            chrome: resolvedChrome,
            windowKey: spec.key,
            availableWindows: [spec.key],
            onReady: spec.onReady,
            appShared: spec.appShared,
            windowOptions: spec.options,
            menuItems: spec.menuItems,
            fitContentHeight: spec.fitContentHeight,
            onQuit: spec.onQuit,
            onReopen: spec.onReopen,
            onOpenUrl: spec.onOpenUrl,
            extraConfigure: { rt, _ in
                configure?(rt)
            }
        )
    }
}

/// Errors from multi-window key validation or launch (`window::spec::validate`).
public enum MultiWindowError: Error, LocalizedError, Equatable {
    case emptyOrDuplicateKey(String)
    case unknownWindow(key: String, available: [String])

    public var errorDescription: String? {
        switch self {
        case .emptyOrDuplicateKey(let key):
            return "empty or duplicate window key: \(key)"
        case let .unknownWindow(key, available):
            return "no such window \"\(key)\"; available: \(available.joined(separator: ", "))"
        }
    }
}

/// Multi-window flattening, validation, dynamic opening, and native launch (`crates/rune/src/window/spec.rs`).
public enum RuneMultiWindow {
    private static let openedLock = NSLock()
    nonisolated(unsafe) private static var pendingOpened: [AnyWindowSpec] = []
    nonisolated(unsafe) private static var wakeHost: (@Sendable () -> Void)?
    nonisolated(unsafe) private static var desktopHandles: [String: WindowHandle] = [:]

    static func setOpenWake(_ wake: (@Sendable () -> Void)?) {
        openedLock.withLock {
            wakeHost = wake
            if wake == nil { desktopHandles.removeAll() }
        }
    }

    static func trackDesktopHandle(_ handle: WindowHandle) {
        openedLock.withLock { desktopHandles[handle.key] = handle }
    }

    static func releaseDesktopHandle(_ handle: WindowHandle) {
        openedLock.withLock {
            if desktopHandles[handle.key] === handle { desktopHandles[handle.key] = nil }
        }
    }

    /// Each window followed depth-first by any secondary windows attached via `window(_:)`.
    public static func flatten(_ windows: [AnyWindowSpec]) -> [AnyWindowSpec] {
        var out: [AnyWindowSpec] = []
        for var w in windows {
            let children = w.takeChildWindows()
            out.append(w)
            out.append(contentsOf: flatten(children))
        }
        return out
    }

    /// Ensures every window has a non-empty, unique key.
    public static func validate(_ windows: [AnyWindowSpec]) throws {
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
        _ spec: AppWindowSpec<State>,
        headless: Bool = false
    ) -> WindowHandle {
        let anySpec = AnyWindowSpec(spec, handle: WindowHandle(key: spec.key), secondary: false)
        if !headless {
            openedLock.lock()
            if let existing = desktopHandles[spec.key] {
                openedLock.unlock()
                existing.open()
                return existing
            }
            if wakeHost != nil { desktopHandles[spec.key] = anySpec.handle }
            pendingOpened.append(anySpec)
            let wake = wakeHost
            openedLock.unlock()
            wake?()
        }
        return anySpec.handle
    }

    /// Resolves CLI arguments for a secondary window (`tooling::window_args`):
    /// explicit per-window args (even empty) never read the host CLI.
    public static func windowArgs(explicit: [String]?, inherited: () -> ToolingArgs) -> ToolingArgs {
        if let explicit {
            return ToolingArgs.parse(explicit)
        }
        return inherited()
    }

    /// Drains windows queued via `openWindow`.
    public static func takeOpened() -> [AnyWindowSpec] {
        openedLock.lock()
        let out = pendingOpened
        pendingOpened.removeAll()
        openedLock.unlock()
        return out
    }

    /// Resolves `--list-windows` / `--window KEY` and executes a headless run on multi-window specs.
    @discardableResult
    public static func runHeadless(
        _ windows: [AnyWindowSpec],
        args: ToolingArgs,
        options: RunOptions = RunOptions()
    ) throws -> HeadlessRunner.Output {
        let flat = flatten(windows)
        try validate(flat)
        let keys = flat.map(\.key)
        if args.listWindows {
            for key in keys {
                print(key)
            }
            return HeadlessRunner.Output(
                finalFrame: Frame(width: 1, height: 1, rgba: [0, 0, 0, 255]),
                treeJSON: Data("{}".utf8),
                windowKeys: keys
            )
        }
        if let desktopPath = args.desktopPath {
            let loaded = try DesktopComposite.loadBackdrop(imagePath: desktopPath, scale: args.pixelScale)
            let dark = args.darkOverride ?? true
            let members: [any DesktopMember] = flat.enumerated().map { idx, spec in
                spec.makeHostEntry().makeDesktopMember(
                    scale: args.pixelScale,
                    dark: dark,
                    isMain: idx == 0
                )
            }
            return try VirtualDesk.runHeadlessDesktop(
                members: members,
                args: args,
                options: options,
                desktop: loaded.desktop,
                backdropRGBA: loaded.rgba,
                width: loaded.pixelWidth,
                height: loaded.pixelHeight
            )
        }
        let target: AnyWindowSpec
        if let requested = args.windowName {
            guard let found = flat.first(where: { $0.key == requested }) else {
                throw MultiWindowError.unknownWindow(key: requested, available: keys)
            }
            target = found
        } else if let first = flat.first {
            target = first
        } else {
            return HeadlessRunner.Output(
                finalFrame: Frame(width: 1, height: 1, rgba: [0, 0, 0, 255]),
                treeJSON: Data("{}".utf8),
                windowKeys: []
            )
        }
        // Pass `windowName: nil` since window routing already selected `target`.
        var resolvedArgs = args
        resolvedArgs.windowName = nil
        return try target.makeHostEntry().runHeadless(args: resolvedArgs)
    }

    /// Runs a multi-window application (`run_windows`).
    @MainActor
    public static func runWindows(
        _ windows: [AnyWindowSpec],
        options: RunOptions = RunOptions(),
        arguments: [String]? = nil
    ) throws {
        let flat = flatten(windows)
        try validate(flat)
        let parsed = arguments.map { ToolingArgs.parse($0) } ?? ToolingArgs.parse()
        if parsed.isHeadlessRequested {
            _ = try runHeadless(flat, args: parsed, options: options)
            return
        }
        #if os(macOS)
        try RuneMultiWindowHost.run(flat, options: options, parsed: parsed)
        #elseif os(Windows) || os(Linux)
        try DesktopWindowGroup.run(flat, options: options, parsed: parsed)
        #else
        _ = try runHeadless(flat, args: parsed, options: options)
        #endif
    }

    /// Runs a multi-window application constructed with explicit `arguments` (`rune::run_windows_with_args`).
    @MainActor
    public static func runWindowsWithArgs(
        options: RunOptions = RunOptions(),
        arguments: [String],
        _ factory: (ToolingArgs) -> [AnyWindowSpec]
    ) throws {
        let parsed = ToolingArgs.parse(arguments)
        let windows = factory(parsed)
        try runWindows(windows, options: options, arguments: arguments)
    }

    /// Display-aware overload of `runWindowsWithArgs` mirroring `rune::run_windows_with_args(|displays| ...)`.
    @MainActor
    @_disfavoredOverload
    public static func runWindowsWithArgs(
        options: RunOptions = RunOptions(),
        arguments: [String],
        _ factory: ([DisplayInfo]) -> [AnyWindowSpec]
    ) throws {
        let parsed = ToolingArgs.parse(arguments)
        let displays: [DisplayInfo]
        if let desktopPath = parsed.desktopPath,
           let loaded = try? DesktopComposite.loadBackdrop(imagePath: desktopPath, scale: parsed.pixelScale) {
            displays = loaded.desktop.displayInfos()
        } else {
            #if os(macOS) || os(Linux) || os(Windows)
            if parsed.isHeadlessRequested {
                displays = VirtualDesktop.single(scale: Double(max(0.5, parsed.pixelScale))).displayInfos()
            } else {
                displays = try DesktopDisplays.connected()
            }
            #else
            displays = VirtualDesktop.single(scale: Double(max(0.5, parsed.pixelScale))).displayInfos()
            #endif
        }
        let windows = factory(displays)
        try runWindows(windows, options: options, arguments: arguments)
    }
}

/// Top-level helper mirroring `rune::run_windows_with_args`.
@MainActor
public func runWindowsWithArgs(
    options: RunOptions = RunOptions(),
    arguments: [String],
    _ factory: (ToolingArgs) -> [AnyWindowSpec]
) throws {
    try RuneMultiWindow.runWindowsWithArgs(options: options, arguments: arguments, factory)
}

/// Top-level display-aware helper mirroring `rune::run_windows_with_args(|displays| ...)`.
@MainActor
@_disfavoredOverload
public func runWindowsWithArgs(
    options: RunOptions = RunOptions(),
    arguments: [String],
    _ factory: ([DisplayInfo]) -> [AnyWindowSpec]
) throws {
    try RuneMultiWindow.runWindowsWithArgs(options: options, arguments: arguments, factory)
}

/// Top-level throwing alias mirroring `rune::try_run_windows_with_args`.
@MainActor
public func tryRunWindowsWithArgs(
    options: RunOptions = RunOptions(),
    arguments: [String],
    _ factory: (ToolingArgs) -> [AnyWindowSpec]
) throws {
    try RuneMultiWindow.runWindowsWithArgs(options: options, arguments: arguments, factory)
}

/// Non-throwing multi-window helper printing startup errors to stderr and exiting `1` on native targets (`rune::run_windows_with_args`).
@MainActor
public func runWindowsWithArgsOrExit(
    options: RunOptions = RunOptions(),
    arguments: [String],
    _ factory: (ToolingArgs) -> [AnyWindowSpec]
) {
    RuneStartup.started {
        try RuneMultiWindow.runWindowsWithArgs(options: options, arguments: arguments, factory)
    }
}
