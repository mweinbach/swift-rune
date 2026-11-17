import Foundation
import RuneMotion
import RuneRef

#if os(Linux)
import CRuneLinux
#endif

// MARK: - 1. Wayland wlr-layer-shell Configuration (platform/layer_shell.rs)

/// Wayland `zwlr_layer_shell_v1` layer level.
public enum LayerShellLayer: UInt32, Sendable, Equatable, Codable {
    case background = 0
    case bottom = 1
    case top = 2
    case overlay = 3
}

/// Edge anchor bitmask for a `wlr-layer-shell` surface.
public struct LayerShellAnchor: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let top = LayerShellAnchor(rawValue: 1 << 0)
    public static let bottom = LayerShellAnchor(rawValue: 1 << 1)
    public static let left = LayerShellAnchor(rawValue: 1 << 2)
    public static let right = LayerShellAnchor(rawValue: 1 << 3)
    public static let all: LayerShellAnchor = [.top, .bottom, .left, .right]
}

/// Keyboard focus policy for a `wlr-layer-shell` surface.
public enum KeyboardInteractivity: UInt32, Sendable, Equatable, Codable {
    case none = 0
    case exclusive = 1
    case onDemand = 2
}

/// Configuration for a Wayland `wlr-layer-shell` overlay surface (`rune::platform::layer_shell`).
public struct LayerShellConfig: Sendable, Equatable {
    public var namespace: String
    public var layer: LayerShellLayer
    public var anchor: LayerShellAnchor
    public var size: Vec2
    public var margin: SIMD4<Int32>
    public var exclusiveZone: Int32
    public var keyboardInteractivity: KeyboardInteractivity

    public init(
        namespace: String = "rune-overlay",
        layer: LayerShellLayer = .overlay,
        anchor: LayerShellAnchor = [.top, .left],
        size: Vec2 = Vec2(400, 300),
        margin: SIMD4<Int32> = .zero,
        exclusiveZone: Int32 = 0,
        keyboardInteractivity: KeyboardInteractivity = .onDemand
    ) {
        self.namespace = namespace
        self.layer = layer
        self.anchor = anchor
        self.size = size
        self.margin = margin
        self.exclusiveZone = exclusiveZone
        self.keyboardInteractivity = keyboardInteractivity
    }
}

// MARK: - 2. Layer Shell State Machines (platform/layer_shell_machine.rs)

/// Single-finger touch state machine for a `wlr-layer-shell` surface.
public enum LayerShellTouchState: Sendable, Equatable {
    case up
    case down(id: Int32)
}

public enum LayerShellTouchEvent: Sendable, Equatable {
    case down(id: Int32, x: Float, y: Float)
    case motion(id: Int32, x: Float, y: Float)
    case up(id: Int32)
    case cancel
    case gone
}

public enum LayerShellTouchEffect: Sendable, Equatable {
    case move(Float, Float)
    case press
    case release
    case leave
}

public enum LayerShellTouchMachine {
    public static func step(_ state: inout LayerShellTouchState, event: LayerShellTouchEvent) -> [LayerShellTouchEffect] {
        switch (state, event) {
        case (.up, .down(let id, let x, let y)):
            state = .down(id: id)
            return [.move(x, y), .press]
        case (.down(let id), .motion(let moving, let x, let y)) where id == moving:
            return [.move(x, y)]
        case (.down(let id), .up(let lifted)) where id == lifted:
            state = .up
            return [.release, .leave]
        case (.down, .cancel):
            state = .up
            return [.leave, .release]
        case (_, .gone):
            state = .up
            return []
        default:
            return []
        }
    }
}

/// Compositor readiness state machine for a `wlr-layer-shell` surface.
public enum LayerShellReadinessEvent: Sendable, Equatable {
    case configure(width: UInt32, height: UInt32)
    case scale(Int32)
    case closed
}

public enum LayerShellReadinessState: Sendable, Equatable {
    case configuring(scale: Int32?)
    case ready(width: UInt32?, height: UInt32?, scale: Int32?)
    case closed

    public var isConfigured: Bool {
        if case .configuring = self { return false }
        return true
    }

    public var isClosed: Bool {
        if case .closed = self { return true }
        return false
    }

    public var size: (UInt32, UInt32)? {
        if case .ready(let w?, let h?, _) = self {
            return (w, h)
        }
        return nil
    }

    public mutating func takeSize() -> (UInt32, UInt32)? {
        if case .ready(let w?, let h?, let scale) = self {
            self = .ready(width: nil, height: nil, scale: scale)
            return (w, h)
        }
        return nil
    }

    public mutating func takeScale() -> Int32? {
        switch self {
        case .configuring(let scale?):
            self = .configuring(scale: nil)
            return scale
        case .ready(let w, let h, let scale?):
            self = .ready(width: w, height: h, scale: nil)
            return scale
        default:
            return nil
        }
    }
}

public enum LayerShellReadinessMachine {
    public static func step(_ state: inout LayerShellReadinessState, event: LayerShellReadinessEvent) {
        switch (state, event) {
        case (.closed, _):
            break
        case (_, .closed):
            state = .closed
        case (.configuring(let scale), .configure(let w, let h)):
            state = .ready(width: w, height: h, scale: scale)
        case (.ready(_, _, let scale), .configure(let w, let h)):
            state = .ready(width: w, height: h, scale: scale)
        case (.configuring, .scale(let s)):
            state = .configuring(scale: s)
        case (.ready(let w, let h, _), .scale(let s)):
            state = .ready(width: w, height: h, scale: s)
        }
    }
}

// MARK: - 3. XDG Desktop Portal Appearance (platform/portal_appearance.rs)

/// D-Bus `Variant` value subset used by `org.freedesktop.portal.Settings`.
public indirect enum PortalVariant: Sendable, Equatable {
    case u32(UInt32)
    case str(String)
    case tuple3(Double, Double, Double)
    case variant(PortalVariant)
}

/// Parser for `org.freedesktop.appearance` `color-scheme` and `accent-color` D-Bus responses.
public enum PortalAppearance {
    public static let busName = "org.freedesktop.portal.Desktop"
    public static let objectPath = "/org/freedesktop/portal/desktop"
    public static let interfaceName = "org.freedesktop.portal.Settings"
    public static let appearanceNamespace = "org.freedesktop.appearance"
    public static let colorSchemeKey = "color-scheme"
    public static let accentColorKey = "accent-color"

    /// 0 = no preference, 1 = prefer dark, 2 = prefer light.
    public static func schemeDark(_ scheme: UInt32) -> Bool? {
        switch scheme {
        case 1: return true
        case 2: return false
        default: return nil
        }
    }

    /// Recursively unwraps `v` (portals wrap `u32` once in `ReadOne` and twice in `Read`).
    public static func parseScheme(_ value: PortalVariant) -> UInt32? {
        switch value {
        case .u32(let x): return x
        case .variant(let inner): return parseScheme(inner)
        case .str, .tuple3: return nil
        }
    }

    /// Parses `(r, g, b)` accent color in `[0, 1]` sRGB into linear-light `Rune.Color`.
    public static func parseAccentColor(_ value: PortalVariant) -> Color? {
        switch value {
        case .tuple3(let r, let g, let b):
            guard (0.0...1.0).contains(r), (0.0...1.0).contains(g), (0.0...1.0).contains(b) else {
                return nil
            }
            return Color.srgb(Float(r), Float(g), Float(b), 1.0)
        case .variant(let inner):
            return parseAccentColor(inner)
        case .u32, .str:
            return nil
        }
    }
}

// MARK: - 4. X11 / Evdev Keysym Mapping (platform/x11/)

/// Translates X11 keysyms (`XK_*`) and Linux evdev keycodes into `Rune.Key`.
public enum LinuxKeyMap {
    /// Named key mapping matching Wayland / layer-shell `named_keysym` (`platform/layer_shell.rs`).
    public static func namedKeysym(_ symbol: UInt32) -> Key? {
        switch symbol {
        case 0xFF08: return .backspace      // XK_BackSpace
        case 0xFF09: return .tab            // XK_Tab
        case 0xFF0D, 0xFF8D: return .enter  // XK_Return, XK_KP_Enter
        case 0xFF1B: return .escape         // XK_Escape
        case 0xFF50: return .home           // XK_Home
        case 0xFF51: return .arrowLeft      // XK_Left
        case 0xFF52: return .arrowUp        // XK_Up
        case 0xFF53: return .arrowRight     // XK_Right
        case 0xFF54: return .arrowDown      // XK_Down
        case 0xFF55: return .pageUp         // XK_Page_Up
        case 0xFF56: return .pageDown       // XK_Page_Down
        case 0xFF57: return .end            // XK_End
        case 0xFFFF: return .delete         // XK_Delete
        case 0xFF67: return .contextMenu    // XK_Menu
        case 0xFF63: return .insert         // XK_Insert
        case 0xFF61, 0xFF15: return .printScreen // XK_Print, XK_Sys_Req
        case 0xFF14: return .scrollLock     // XK_Scroll_Lock
        case 0xFF13, 0xFF6B: return .pause  // XK_Pause, XK_Break
        case 0xFFBE...0xFFD5:               // XK_F1..XK_F24
            return .f(UInt8(symbol - 0xFFBE + 1))
        default:
            return nil
        }
    }

    public static func translate(keysym: UInt32) -> Key? {
        if let named = namedKeysym(keysym) {
            return named
        }
        switch keysym {
        case 0x0020: return .space       // XK_space
        case 0x0021...0x007E:
            guard let scalar = UnicodeScalar(keysym) else { return nil }
            return .text(String(scalar))
        default:
            return nil
        }
    }
}

/// SDL keycodes distinguish Unicode key values from scancodes carrying USB HID usages.
enum LinuxDesktopKey {
    static func logical(_ code: Int32, mods: Mods) -> Key? {
        switch code {
        case 8: return .backspace
        case 9: return .tab
        case 13, 0x40000058: return .enter
        case 27: return .escape
        case 32: return .space
        case 127: return .delete
        case 0x4000003a...0x40000045: return .f(UInt8(code - 0x4000003a + 1))
        case 0x40000068...0x40000073: return .f(UInt8(code - 0x40000068 + 13))
        case 0x40000046: return .printScreen
        case 0x40000047: return .scrollLock
        case 0x40000048: return .pause
        case 0x40000049: return .insert
        case 0x4000004a: return .home
        case 0x4000004b: return .pageUp
        case 0x4000004d: return .end
        case 0x4000004e: return .pageDown
        case 0x4000004f: return .arrowRight
        case 0x40000050: return .arrowLeft
        case 0x40000051: return .arrowDown
        case 0x40000052: return .arrowUp
        case 0x40000065, 0x40000076: return .contextMenu
        default:
            guard code >= 32, let scalar = Unicode.Scalar(UInt32(code)) else { return nil }
            let character = Character(String(scalar))
            return mods.ctrl || mods.logo ? .command(character) : .text(String(character))
        }
    }

    static func physical(_ scan: Int32) -> PhysicalKeyCode? {
        switch scan {
        case 4...29:
            return PhysicalKeyCode(rawValue: "key" + String(Unicode.Scalar(UInt8(65 + scan - 4))))
        case 30...38: return PhysicalKeyCode(rawValue: "digit\(scan - 29)")
        case 39: return .digit0
        case 40...56:
            let keys: [PhysicalKeyCode?] = [.enter, .escape, .backspace, .tab, .space, .minus,
                .equal, .bracketLeft, .bracketRight, .backslash, nil, .semicolon, .quote,
                .backquote, .comma, .period, .slash]
            return keys[Int(scan - 40)]
        case 57: return .capsLock
        case 58...69: return PhysicalKeyCode(rawValue: "f\(scan - 57)")
        case 73...82:
            return [.insert, .home, .pageUp, .delete, .end, .pageDown,
                    .arrowRight, .arrowLeft, .arrowDown, .arrowUp][Int(scan - 73)]
        case 84...88:
            return [.numpadDivide, .numpadMultiply, .numpadSubtract, .numpadAdd, .numpadEnter][Int(scan - 84)]
        case 89...97: return PhysicalKeyCode(rawValue: "numpad\(scan - 88)")
        case 98: return .numpad0
        case 99: return .numpadDecimal
        case 104...115: return PhysicalKeyCode(rawValue: "f\(scan - 91)")
        case 224...231:
            return [.controlLeft, .shiftLeft, .altLeft, .superLeft,
                    .controlRight, .shiftRight, .altRight, .superRight][Int(scan - 224)]
        default: return nil
        }
    }

    /// SDL supplies Unicode character offsets. Rune's editor uses UTF-8 byte offsets.
    static func preeditSelection(in text: String, start: Int32, length: Int32) -> Range<Int>? {
        guard start >= 0 else { return nil }
        let scalars = text.unicodeScalars
        let lo = scalars.index(scalars.startIndex, offsetBy: Int(start), limitedBy: scalars.endIndex) ?? scalars.endIndex
        let hi = scalars.index(lo, offsetBy: max(0, Int(length)), limitedBy: scalars.endIndex) ?? scalars.endIndex
        return text.utf8.distance(from: text.utf8.startIndex, to: lo)..<text.utf8.distance(from: text.utf8.startIndex, to: hi)
    }
}

#if os(Linux)
private struct LinuxHostError: LocalizedError, CustomStringConvertible {
    let description: String
    var errorDescription: String? { description }
    init(_ action: String) {
        description = "\(action): \(String(cString: rune_linux_error()))"
    }
}

private final class LinuxAppearanceObserver {
    let handle = rune_linux_appearance_open()
    let followsScheme: Bool
    let forceReducedMotion: Bool
    let forceIncreasedContrast = SystemPreferences.increasedContrastPreset()

    init(followsScheme: Bool, forceReducedMotion: Bool) {
        self.followsScheme = followsScheme
        self.forceReducedMotion = forceReducedMotion
    }

    deinit { rune_linux_appearance_close(handle) }

    @discardableResult
    func update<State>(_ runtime: Runtime<State>) -> Bool {
        var preferences = RuneLinuxPreferences()
        guard rune_linux_appearance_take(handle, &preferences) else { return false }
        if followsScheme { runtime.systemDark = preferences.dark != 0 }
        runtime.setSystemReducedMotion(forceReducedMotion || preferences.reducedMotion == 1)
        runtime.setSystemIncreasedContrast(forceIncreasedContrast || preferences.increasedContrast == 1)
        if preferences.hasAccent {
            let color = Color.srgb(Float(preferences.red), Float(preferences.green), Float(preferences.blue), 1)
            runtime.setSystemAccent(SystemAccent(lightAccent: color, darkAccent: color))
        } else {
            runtime.setSystemAccent(.default)
        }
        return true
    }
}

/// An SDL2 Wayland/X11 window that encodes Rune primitives through its OpenGL context.
public enum LinuxApp {
    @MainActor
    public static func run<State>(_ spec: AppSpec<State>, parsed: ToolingArgs) throws {
        let window = AppWindowSpec(key: "main", app: spec)
        try DesktopWindowGroup.run([window.boxed()], options: RunOptions(), parsed: parsed)
    }

    @MainActor
    public static func run<State>(_ app: App<State>, parsed: ToolingArgs) throws {
        let window = AppWindowSpec(app: app, key: "main", onCreated: app.onWindowHook)
        try DesktopWindowGroup.run([window.boxed()], options: app.runOptions, parsed: parsed)
    }

}

@MainActor
final class LinuxWindowSession<State> {
    let window: OpaquePointer
    let renderer: PortableGLRenderer
    let started = ProcessInfo.processInfo.systemUptime
    let timeScale: Double
    private var finished = false
    let app: App<State>
    let runtime: Runtime<State>
    private let shortcuts: ShortcutGuard
    private let menu: LinuxApplicationMenu<State>
    private let popup: LinuxContextMenu<State>
    private var menuConsumedKeys: Set<Int32> = []
    private var menuPointer: Vec2?
    let handle: WindowHandle
    let waker: Waker
    let accessibility: LinuxAccessibilityHost
    private let dragSource = LinuxDragSource()
    private let appearance: LinuxAppearanceObserver
    let reports: FrameReports<State>
    var windowX: Int32 = 0
    var windowY: Int32 = 0
    var cover = CoveredWindowDriver()
    var running = true
    var requestedApplicationQuit = false
    var firstFrame = true
    var didNotifyReady = false
    var appliedCursor: Cursor?
    var nativeCursor: UnsafeMutableRawPointer?
    var resting = false
    var nextFrame: Double?
    var title: String
    var lastMods = Mods.none
    var suppressText = false
    var dropPaths = [URL]()
    private var acceptsSDLDrop = true

    init(app: App<State>, parsed: ToolingArgs, handle passedHandle: WindowHandle? = nil) throws {
        HeadlessRunner.registerFonts(app.fontData)
        let size = parsed.viewportOverride ?? app.size
        let opts = app.windowOptionsValue
        let appMin = app.minSize.map { ($0.x, $0.y) }
        let limits = opts.sizeLimits(appMin: app.isFitContentHeight ? opts.fitMinSize(appMin: appMin) : appMin)
        let visible = opts.visible && !app.isWindowless
        let options = RuneLinuxWindowOptions(
            width: nativeDimension(size.x), height: nativeDimension(size.y),
            minWidth: nativeDimension(limits.0.0), minHeight: nativeDimension(limits.0.1),
            maxWidth: limits.1.map { nativeDimension($0.0) } ?? 0,
            maxHeight: limits.1.map { nativeDimension($0.1) } ?? 0,
            resizable: opts.resizable, borderless: opts.borderless || app.chromeStyle.borderless,
            alwaysOnTop: opts.alwaysOnTop, visible: false, maximized: app.openAs.isMaximized, fullScreen: app.openAs.isFullScreen)
        GpuEvents.starting()
        guard let window = rune_linux_open(app.title, options) else {
            throw LinuxHostError("Opening an SDL2 OpenGL 3.3 window")
        }
        self.window = window
        do {
            self.renderer = try PortableGLRenderer(resolve: rune_linux_gl_proc, isGLES: false)
        } catch {
            rune_linux_close(window)
            throw error
        }
        if let (x, y) = opts.position { rune_linux_set_position(window, x, y) }
        timeScale = parsed.timeScale.isFinite && parsed.timeScale > 0 ? parsed.timeScale : 1
        self.app = app
        self.title = app.title
        let id = rune_linux_id(window), wake = rune_linux_wake_type(window)
        let waker = Waker { rune_linux_wake(id, wake) }
        self.waker = waker
        shortcuts = ShortcutGuard.attach(shared: app.sharedHandle.shared, wake: waker, headless: false,
                                         wayland: DesktopShortcutDriver.usesWayland)
        let initial = Self.size(of: window)
        let menu = LinuxApplicationMenu(shared: app.sharedHandle.shared, title: app.title,
                                        fitsContentHeight: app.isFitContentHeight)
        self.menu = menu
        let popup = LinuxContextMenu<State>()
        self.popup = popup
        var hostedApp = app
        let content = app.view
        let fitsContentHeight = app.isFitContentHeight
        hostedApp.view = { state, cx in
            let windowSize = cx.viewport
            if !menu.sections.isEmpty {
                cx.viewport.y = max(0, windowSize.y - LinuxApplicationMenu<State>.barHeight)
            }
            let body = content(state, &cx)
            cx.viewport = windowSize
            let window = menu.view(content: body, in: &cx)
            return popup.view(content: window, in: &cx, fitsContentHeight: fitsContentHeight)
        }
        runtime = hostedApp.makeRuntime(viewport: initial.logical, pixelScale: initial.scale,
                                        systemDark: parsed.darkOverride, reducedMotion: parsed.reducedMotion,
                                        waker: waker, sceneName: parsed.sceneName)
        menu.runtime = runtime
        popup.runtime = runtime
        menu.refresh()
        runtime.wallStart = timeScale == 1 ? started : nil
        runtime.useClipboard(.shared)
        runtime.urlOpener.headless = false
        runtime.readSystemContrastSettings()
        let queue = app.sharedHandle
        handle = passedHandle ?? WindowHandle(title: app.title, isVisible: visible, onClose: { queue.close() },
                              onMinimize: { queue.minimize() }, onFocus: { queue.focus() },
                              onShow: { queue.show() }, onHide: { queue.hide() },
                              onSetTitle: { new in queue.update { _, tx in tx.setTitle(new) } },
                              onSetPosition: { queue.setPosition($0) }, onPlace: { queue.place($0) })
        handle.setWindowNumber(id)
        accessibility = LinuxAccessibilityHost(title: app.title, waker: waker, isVisible: visible)
        appearance = LinuxAppearanceObserver(followsScheme: parsed.darkOverride == nil && app.dark == nil,
                                             forceReducedMotion: parsed.reducedMotion)
        appearance.update(runtime)
        reports = FrameReports(onFrameEncoded: app.onFrameEncodedHook, onFrameDrawn: app.onFrameDrawnHook,
                               onInspectDrawn: app.onFrameInspectHook)
        app.sharedHandle.shared.setVisible(visible)
        rune_linux_origin(window, &windowX, &windowY)
        runtime.setWindowOrigin(Vec2(Float(windowX), Float(windowY)), at: 0)
        _ = cover.setOccluded(!visible, runtime: runtime, at: 0)
        runtime.fitHeight = app.isFitContentHeight
        runtime.playgroundHost = app.playgroundHost
        do {
            _ = try PlaygroundAttach.attach(
                runtime: runtime, host: app.playgroundHost, scenes: app.scenes, sceneOrder: app.sceneOrder,
                makeState: app.makeState, appId: app.title, open: parsed.playgroundName,
                openRequested: parsed.hasPlayground, variant: parsed.playgroundVariant, windowed: true)
        } catch {
            waker.setCallback {}
            renderer.close()
            rune_linux_close(window)
            throw error
        }
    }

    private static func coordinate(_ value: Float) -> Int32 {
        guard value.isFinite else { return 0 }
        return Int32(max(Double(Int32.min), min(Double(Int32.max), Double(value).rounded())))
    }

    static func size(of window: OpaquePointer) -> (logical: Vec2, scale: Float) {
        var w: Int32 = 0, h: Int32 = 0, pw: Int32 = 0, ph: Int32 = 0
        rune_linux_size(window, &w, &h, &pw, &ph)
        return (Vec2(Float(max(1, w)), Float(max(1, h))), w > 0 && pw > 0 ? Float(pw) / Float(w) : 1)
    }

    func now() -> Double { (ProcessInfo.processInfo.systemUptime - started) * timeScale }

    func start() {
        DesktopServices.connectLinuxHost(windowID: rune_linux_id(window))
        dragSource.open(windowID: rune_linux_id(window), runtime: runtime)
        if app.windowOptionsValue.visible && !app.isWindowless { rune_linux_show(window) }
        app.onWindowHook?(handle)
    }

    func finish() {
        guard !finished else { return }
        finished = true
        dragSource.close(runtime: runtime, at: now())
        runtime.dispatchQuit(at: now())
        popup.cancelAll(at: now())
        AppMenuBridge.markRunning(app.sharedHandle.shared, running: false, headless: false)
        shortcuts.close()
        DesktopServices.disconnectLinuxHost()
        waker.setCallback {}
        app.sharedHandle.shared.setVisible(false)
        handle.unbind()
        if rune_linux_make_current(window) { renderer.close() } else { renderer.abandon() }
        rune_linux_free_cursor(nativeCursor)
        rune_linux_close(window)
    }

    func turn(redraw: Bool) throws -> Int32 {
        guard running else { return 0 }
        // libdispatch and async Swift callbacks share this thread with SDL.
        _ = RunLoop.main.run(mode: .default, before: Date())
        let queued = MainQueueDispatcher.shared.drain() > 0
        let t = now()
        DesktopServices.pumpLinuxHost()
        LinuxWaylandFileDrops.take(windowID: rune_linux_id(window), runtime: runtime, at: t)
        dragSource.poll(runtime: runtime, at: t)
        let appearanceChanged = appearance.update(runtime)
        let accessibilityChanged = accessibility.pump(runtime: runtime, at: t) { rune_linux_focus(window) }
        if runtime.hasPopup, menu.activeSection != nil { menu.dismiss() }
        menu.applyFocus(at: t)
        popup.refresh(at: t)
        shortcuts.drain()
        let requests = shortcuts.withReceiving { app.sharedHandle.shared.applyStateUpdates(to: runtime, at: t) }
        menu.refresh()
        apply(requests, at: t)
        guard running else { return 0 }
        if redraw || queued || appearanceChanged || accessibilityChanged || runtime.isStale && cover.canDraw || nextFrame.map({ $0 <= t }) == true {
            if cover.canDraw && !rune_linux_make_current(window) { throw LinuxHostError("Activating the SDL OpenGL context") }
            try draw(renderer, at: t)
        }
        applyShell(at: t)
        // AppHandle, Live, native input, and AT-SPI wake SDL directly. Service external
        // Foundation main-queue work even if the window rests indefinitely.
        let wait = nextFrame.map { max(0, min(100, (($0 - now()) / timeScale * 1000).rounded(.up))) } ?? 100
        if runtime.hasPopup && !popup.isOpen && cover.canDraw { return 0 }
        return dragSource.active ? min(8, Int32(wait)) : Int32(wait)
    }

    func draw(_ renderer: PortableGLRenderer, at now: Double) throws {
        if cover.canDraw {
            let size = Self.size(of: window)
            runtime.setViewport(size.logical, pixelScale: size.scale)
            let start = ProcessInfo.processInfo.systemUptime
            let commitsBefore = runtime.viewCommitCount
            let frame = renderer.frame(runtime, at: now)
            let updated = ProcessInfo.processInfo.systemUptime
            let drawCount = try renderer.draw(frame, compositor: app.compositorValue, runtime: runtime,
                                              at: now, updateMilliseconds: (updated - start) * 1000)
            dragSource.beginAfterDrawing(runtime: runtime, at: now, scale: size.scale,
                                         pixelWidth: frame.width, pixelHeight: frame.height)
            rune_linux_present(window)
            if app.onFrameEncodedHook != nil || app.onFrameDrawnHook != nil {
                let presented = ProcessInfo.processInfo.systemUptime
                reports.record(FrameEncoded(
                    outcome: .drawn, frameMs: (presented - start) * 1000,
                    updateMs: (updated - start) * 1000, encodeMs: (presented - updated) * 1000,
                    committed: runtime.viewCommitCount != commitsBefore, primitives: frame.instances.count,
                    glyphs: frame.instances.reduce(0) { $0 + ($1.params.y == KIND_GLYPH ? 1 : 0) },
                    animating: runtime.isAnimating, compositorAnimating: app.compositorValue?.isAnimating ?? false,
                    drawCount: drawCount, compositorSummary: app.compositorValue?.summary(), at: presented,
                    window: handle.key, presentsAt: presented, started: start))
                if reports.hasPendingDrawn(at: now) {
                    _ = runtime.updateIf(at: now) { state, tx in reports.flush(state: &state, tx: &tx, at: now) }
                }
            }
            reports.inspect(runtime)
            if firstFrame {
                GpuEvents.presented()
                ReadySignal.ready()
                firstFrame = false
            }
            syncCursor()
            if runtime.windowFocused, let area = runtime.imeCursorArea ?? runtime.imeArea, area.count == 4 {
                rune_linux_set_ime_rect(Self.coordinate(area[0]), Self.coordinate(area[1]), nativeDimension(area[2]), nativeDimension(area[3]))
            }
            let animating = runtime.isAnimating || app.compositorValue?.isAnimating == true
            if !animating && !resting { runtime.rest(at: now) }
            resting = !animating
        } else {
            _ = cover.step(runtime, at: now)
        }
        if !didNotifyReady {
            didNotifyReady = true
            handle.setReady(true)
            app.onReadyHook?(handle)
        }
        accessibility.update(runtime: runtime, windowX: windowX, windowY: windowY)
        runtime.schedulePendingWakes(from: now)
        nextFrame = runtime.nextWakeDeadline(after: runtime.currentTime)
        if cover.canDraw && (runtime.isAnimating || app.compositorValue?.isAnimating == true) {
            nextFrame = min(nextFrame ?? .infinity, now + Runtime<State>.timerFrameInterval * timeScale)
        }
    }

    private func syncCursor() {
        guard rune_linux_has_mouse(window) else { appliedCursor = nil; return }
        let wanted = runtime.currentCursor()
        guard wanted != appliedCursor else { return }
        let old = nativeCursor
        appliedCursor = wanted
        let kind: Int
        switch wanted {
        case .default: kind = RuneLinuxCursorDefault
        case .pointer, .grab, .grabbing: kind = RuneLinuxCursorHand
        case .text: kind = RuneLinuxCursorText
        case .notAllowed: kind = RuneLinuxCursorNo
        case .move: kind = RuneLinuxCursorMove
        case .resizeColumn: kind = RuneLinuxCursorColumn
        case .resizeRow: kind = RuneLinuxCursorRow
        case .crosshair, .cell, .zoomIn, .zoomOut: kind = RuneLinuxCursorCross
        case .hidden: kind = RuneLinuxCursorHidden
        case .image(let image):
            if let metrics = try? image.decodedMetrics(),
               let frame = try? Frame.fromPNG(data: Data(image.bytes)) {
                nativeCursor = frame.rgba.withUnsafeBufferPointer { bytes in
                    rune_linux_set_image_cursor(bytes.baseAddress, Int32(frame.width), Int32(frame.height),
                                                Int32(metrics.width), Int32(metrics.height),
                                                Int32(metrics.hot.x), Int32(metrics.hot.y))
                }
                rune_linux_free_cursor(old)
                return
            }
            kind = RuneLinuxCursorDefault
        }
        nativeCursor = rune_linux_set_cursor(Int32(kind))
        rune_linux_free_cursor(old)
    }

    func apply(_ requests: AppDrainedRequests<State>, at now: Double) {
        if requests.quit || requests.relaunch { requestedApplicationQuit = true; running = false; return }
        switch requests.window {
        case .open, .show: rune_linux_show(window)
        case .hide: rune_linux_hide(window)
        case .close: requestClose(at: now)
        case .none: break
        }
        if let point = requests.position { rune_linux_set_position(window, Self.coordinate(point.x), Self.coordinate(point.y)) }
        if let place = requests.place {
            if let size = place.size { rune_linux_set_size(window, nativeDimension(size.x), nativeDimension(size.y)) }
            if let pos = place.position { rune_linux_set_position(window, Self.coordinate(pos.x), Self.coordinate(pos.y)) }
            if place.activate { rune_linux_focus(window) } else { rune_linux_show(window) }
        }
        switch requests.activation {
        case .focus: rune_linux_focus(window)
        case .activate: rune_linux_activate(window, requests.openToken)
        case .minimize: rune_linux_minimize(window)
        case .none: break
        }
    }

    func requestClose(at now: Double) {
        guard runtime.dispatchClose(at: now) else { return }
        if app.keepsRunning { rune_linux_hide(window) }
        else { running = false }
    }

    func applyShell(at now: Double) {
        if let new = runtime.windowTitle, new != title {
            title = new
            rune_linux_set_title(window, new)
        }
        if runtime.quitRequested { requestedApplicationQuit = true; running = false; return }
        if runtime.closeWindowRequested {
            runtime.clearShellRequests()
            requestClose(at: now)
        } else if runtime.minimizeRequested || runtime.toggleMaximizedRequested || runtime.toggleFullScreenRequested {
            if runtime.minimizeRequested && app.windowOptionsValue.minimizable { rune_linux_minimize(window) }
            if runtime.toggleMaximizedRequested { rune_linux_toggle_maximized(window) }
            if runtime.toggleFullScreenRequested { rune_linux_toggle_fullscreen(window) }
            runtime.clearShellRequests()
        }
        if let request = runtime.takeWindowFrameRequest() {
            if let (w, h) = request.size { rune_linux_set_size(window, nativeDimension(w), nativeDimension(h)) }
            if request.center { rune_linux_center(window) }
        }
    }

    func handleEvent(_ event: RuneLinuxEvent, at now: Double) {
        let point = Vec2(event.x, event.y)
        let mods = Mods(shift: event.modifiers & UInt32(RuneLinuxShift) != 0,
                        ctrl: event.modifiers & UInt32(RuneLinuxControl) != 0,
                        alt: event.modifiers & UInt32(RuneLinuxAlt) != 0,
                        logo: event.modifiers & UInt32(RuneLinuxSuper) != 0)
        switch event.kind {
        case RuneLinuxKey: key(event, mods: mods, at: now)
        case RuneLinuxText:
            guard !popup.isOpen, menu.activeSection == nil, !suppressText, let utf8 = event.text else { return }
            let text = String(cString: utf8)
            guard !text.isEmpty else { return }
            if !runtime.hasImeTarget || runtime.hasSecureFocus || !runtime.dispatchImeEvent(.commit(text), at: now) {
                _ = runtime.keyDown(KeyEvent(key: .text(text), mods: mods), at: now)
            }
        case RuneLinuxPreedit:
            guard !popup.isOpen, menu.activeSection == nil, runtime.hasImeTarget && !runtime.hasSecureFocus,
                  let utf8 = event.text else { return }
            let text = String(cString: utf8)
            let cursor = LinuxDesktopKey.preeditSelection(in: text, start: event.start, length: event.length)
            _ = runtime.dispatchImeEvent(.preedit(text, cursorUTF8: cursor, clauses: []), at: now)
        case RuneLinuxMotion:
            if menuPointer != point {
                menuPointer = point
                menu.pointerMoved()
                popup.pointerMoved()
            }
            runtime.pointerMove(to: point, mods: mods, at: now)
        case RuneLinuxLeave:
            menuPointer = nil
            appliedCursor = nil
            runtime.pointerExit(at: now)
        case RuneLinuxButton:
            let buttons: [PointerButton] = [.primary, .middle, .secondary, .back, .forward]
            guard event.code > 0 && event.code <= buttons.count else { return }
            let button = buttons[Int(event.code - 1)]
            if event.active {
                menu.pointerMoved()
                menuPointer = point
                if !popup.isOpen { menu.rememberFocus() }
                runtime.pointerDown(at: point, button: button, mods: mods, at: now)
            } else { runtime.pointerUp(at: point, button: button, mods: mods, at: now) }
        case RuneLinuxWheel:
            let (dx, dy) = WheelDistance.wheelDelta(.line(x: event.dx, y: event.dy), scale: 1,
                                                   shift: mods.shift, linePoints: WheelDistance.linePoints)
            runtime.wheel(WheelEvent(dx: dx, dy: dy, precise: false, mods: mods), at: point, now: now)
        case RuneLinuxFocus:
            runtime.dispatchFocus(event.active, at: now)
            if !event.active {
                lastMods = .none
                suppressText = false
                menuConsumedKeys.removeAll()
                menu.dismiss()
                popup.cancelAll(at: now)
            }
        case RuneLinuxVisibility:
            if !event.active { popup.cancelAll(at: now) }
            app.sharedHandle.shared.setVisible(event.active)
            accessibility.setVisible(event.active)
            _ = cover.setOccluded(!event.active, runtime: runtime, at: now)
        case RuneLinuxMoved:
            windowX = Self.coordinate(point.x)
            windowY = Self.coordinate(point.y)
            runtime.setWindowOrigin(point, at: now)
        case RuneLinuxClose:
            if app.windowOptionsValue.closable { requestClose(at: now) }
        case RuneLinuxQuit: requestClose(at: now)
        case RuneLinuxDropBegin:
            dropPaths.removeAll()
            acceptsSDLDrop = LinuxWaylandFileDrops.mayUseSDL(windowID: rune_linux_id(window))
        case RuneLinuxDropFile:
            if acceptsSDLDrop, let utf8 = event.text { dropPaths.append(URL(fileURLWithPath: String(cString: utf8))) }
        case RuneLinuxDropEnd:
            if !dropPaths.isEmpty {
                let dropped = dropPaths.map { DroppedFile(url: $0) }
                runtime.fileDrop(.dropped(dropped, at: point), at: now)
            }
            dropPaths.removeAll()
            acceptsSDLDrop = true
        default: break
        }
    }

    func key(_ event: RuneLinuxEvent, mods: Mods, at now: Double) {
        if mods != lastMods {
            runtime.dispatchModifiers(mods, at: now)
            lastMods = mods
        }
        let logical = LinuxDesktopKey.logical(event.code, mods: mods)
        if !event.active, menuConsumedKeys.remove(event.scan) != nil {
            suppressText = false
            return
        }
        if event.repeated, menuConsumedKeys.contains(event.scan),
           logical == .f(10) || (menu.activeSection == nil && !popup.isOpen) {
            suppressText = true
            return
        }
        let keyEvent = logical.map { KeyEvent(key: $0, mods: mods) }
        if event.active, popup.isOpen {
            if let keyEvent { popup.navigate(keyEvent) }
            menuConsumedKeys.insert(event.scan)
            suppressText = true
            return
        }
        let altGr = event.modifiers & UInt32(RuneLinuxAltGr) != 0
        let match = event.active && !altGr ? keyEvent.flatMap(menu.matching) : nil
        let revision = menu.revision
        if event.active, let keyEvent {
            if let match, !match.keysFirst, menu.fire(match, revision: revision) {
                menuConsumedKeys.insert(event.scan)
                suppressText = true
                return
            }
            if match == nil, (!altGr && menu.navigate(keyEvent)) || menu.activeSection != nil {
                menuConsumedKeys.insert(event.scan)
                suppressText = true
                return
            }
        }
        let waitsForText: Bool
        switch logical {
        case .text: waitsForText = true
        case .command: waitsForText = altGr
        case .space: waitsForText = runtime.hasImeTarget && !mods.ctrl && !mods.logo
        default: waitsForText = false
        }
        let fallback = waitsForText && event.active && match == nil ? nil : keyEvent
        let handled: Bool
        if let physical = LinuxDesktopKey.physical(event.scan) {
            handled = runtime.physicalWithFallback(.key(key: physical, mods: mods, pressed: event.active, repeat: event.repeated),
                                                   fallbackKey: fallback, at: now)
        } else if let fallback {
            handled = event.active ? runtime.keyDown(fallback, isRepeat: event.repeated, at: now)
                                   : runtime.keyUp(fallback, at: now)
        } else {
            handled = false
        }
        if event.active {
            let menuHandled = !handled && match.map { menu.fire($0, revision: revision) } == true
            suppressText = handled || menuHandled || (logical == .space && !waitsForText)
        } else { suppressText = false }
    }
}
#endif
