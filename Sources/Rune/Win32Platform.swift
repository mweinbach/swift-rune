import Foundation
import RuneMotion
import RuneRef

#if os(Windows)
import CRuneWin32
import CRuneGL
#endif

// MARK: - Win32 Platform Types & Translators (platform/win32/)

/// Windows 11 DWM system backdrop material (`DWM_SYSTEMBACKDROP_TYPE`).
public enum Win32Backdrop: UInt32, Sendable, Equatable, Codable {
    case auto = 0
    case none = 1
    case mica = 2
    case acrylic = 3
    case tabbed = 4
}

/// Configuration for a Win32 Rune window (`rune::platform::win32`).
public struct Win32WindowConfig: Sendable, Equatable {
    public var title: String
    public var size: Vec2
    public var minSize: Vec2?
    public var darkTitleBar: Bool
    public var backdrop: Win32Backdrop
    public var cloakedUntilFirstFrame: Bool

    public init(
        title: String = "Rune",
        size: Vec2 = Vec2(960, 640),
        minSize: Vec2? = nil,
        darkTitleBar: Bool = true,
        backdrop: Win32Backdrop = .none,
        cloakedUntilFirstFrame: Bool = true
    ) {
        self.title = title
        self.size = size
        self.minSize = minSize
        self.darkTitleBar = darkTitleBar
        self.backdrop = backdrop
        self.cloakedUntilFirstFrame = cloakedUntilFirstFrame
    }
}

/// Win32 DPI scaling helpers (`96 DPI = 1.0x`, matching `platform/win32/dpi_drag.rs`).
public enum Win32DpiScale {
    public static let baseDPI: UInt32 = 96

    public static func scaleFactor(forDPI dpi: UInt32) -> Float {
        let clamped = max(baseDPI / 2, dpi)
        return Float(clamped) / Float(baseDPI)
    }

    public static func physicalPixels(logical: Float, dpi: UInt32) -> Int32 {
        Int32((logical * scaleFactor(forDPI: dpi)).rounded())
    }

    public static func logicalPoints(physical: Int32, dpi: UInt32) -> Float {
        Float(physical) / scaleFactor(forDPI: dpi)
    }

    public static func clampWindowSize(width: Int32, height: Int32, minLogical: Vec2?, dpi: UInt32) -> (Int32, Int32) {
        guard let minL = minLogical else {
            return (max(1, width), max(1, height))
        }
        let minW = max(1, physicalPixels(logical: minL.x, dpi: dpi))
        let minH = max(1, physicalPixels(logical: minL.y, dpi: dpi))
        return (max(minW, width), max(minH, height))
    }
}

/// Translates Win32 Virtual-Key (`VK_*`) codes to `Rune.Key`.
public enum Win32KeyMap {
    static func modifiers(_ bits: UInt32) -> Mods {
        Mods(shift: bits & 1 != 0, ctrl: bits & 2 != 0,
             alt: bits & 4 != 0, logo: bits & 8 != 0)
    }

    /// Printable shortcuts follow the active keyboard layout. Navigation and function keys retain their VK meaning.
    static func shortcutKey(virtualKey: UInt32, scalar: UnicodeScalar?, mods: Mods) -> Key? {
        let key = translate(virtualKey: virtualKey, shift: mods.shift)
        switch key {
        case .text, nil:
            guard let scalar, scalar.value >= 32, scalar.value != 127 else { return key }
            return .text(String(scalar))
        default:
            return key
        }
    }

    public static func translate(virtualKey vk: UInt32, shift: Bool = false) -> Key? {
        switch vk {
        case 0x08: return .backspace   // VK_BACK
        case 0x09: return .tab         // VK_TAB
        case 0x0D: return .enter       // VK_RETURN
        case 0x1B: return .escape      // VK_ESCAPE
        case 0x20: return .space       // VK_SPACE
        case 0x21: return .pageUp      // VK_PRIOR
        case 0x22: return .pageDown    // VK_NEXT
        case 0x23: return .end         // VK_END
        case 0x24: return .home        // VK_HOME
        case 0x25: return .arrowLeft   // VK_LEFT
        case 0x26: return .arrowUp     // VK_UP
        case 0x27: return .arrowRight  // VK_RIGHT
        case 0x28: return .arrowDown   // VK_DOWN
        case 0x2C: return .printScreen // VK_SNAPSHOT
        case 0x2D: return .insert      // VK_INSERT
        case 0x2E: return .delete      // VK_DELETE
        case 0x5D: return .contextMenu // VK_APPS
        case 0x13: return .pause       // VK_PAUSE
        case 0x91: return .scrollLock  // VK_SCROLL
        case 0x70...0x87:              // VK_F1..VK_F24
            return .f(UInt8(vk - 0x70 + 1))
        case 0x30...0x39:              // '0'..'9'
            let ch = Character(UnicodeScalar(vk)!)
            return .text(String(ch))
        case 0x41...0x5A:              // 'A'..'Z'
            let base = shift ? vk : (vk + 32)
            let ch = Character(UnicodeScalar(base)!)
            return .text(String(ch))
        default:
            return nil
        }
    }
}

/// Normalized Win32 window message representation (`WM_*`) for cross-platform testing and dispatch.
public enum Win32Message: Sendable, Equatable {
    case size(width: Int, height: Int)
    case dpiChanged(dpi: UInt32, suggestedWidth: Int32, suggestedHeight: Int32)
    case mouseMove(x: Float, y: Float)
    case mouseDown(button: PointerButton, x: Float, y: Float)
    case mouseUp(button: PointerButton, x: Float, y: Float)
    case mouseLeave
    case captureLost
    case keyDown(vk: UInt32, mods: Mods)
    case char(scalar: UnicodeScalar)
    case close
}

/// Translates `Win32Message` events into `Runtime<State>` calls.
public enum Win32MessageTranslator {
    @MainActor
    public static func dispatch<State>(
        _ msg: Win32Message,
        to runtime: Runtime<State>,
        dpi: inout UInt32,
        at now: Double,
        pointerMods: Mods = .none
    ) -> Bool {
        switch msg {
        case .size(let w, let h):
            let scale = Win32DpiScale.scaleFactor(forDPI: dpi)
            runtime.setViewport(Vec2(Float(w) / scale, Float(h) / scale), pixelScale: scale)
            return true
        case .dpiChanged(let newDPI, let w, let h):
            dpi = newDPI
            let scale = Win32DpiScale.scaleFactor(forDPI: dpi)
            runtime.setViewport(Vec2(Float(w) / scale, Float(h) / scale), pixelScale: scale)
            return true
        case .mouseMove(let x, let y):
            let scale = Win32DpiScale.scaleFactor(forDPI: dpi) * runtime.zoom()
            runtime.pointerMove(to: Vec2(x / scale, y / scale), mods: pointerMods, at: now)
            return true
        case .mouseDown(let btn, let x, let y):
            let scale = Win32DpiScale.scaleFactor(forDPI: dpi) * runtime.zoom()
            runtime.pointerDown(at: Vec2(x / scale, y / scale), button: btn, mods: pointerMods, at: now)
            return true
        case .mouseUp(let btn, let x, let y):
            let scale = Win32DpiScale.scaleFactor(forDPI: dpi) * runtime.zoom()
            runtime.pointerUp(at: Vec2(x / scale, y / scale), button: btn, mods: pointerMods, at: now)
            return true
        case .mouseLeave:
            runtime.pointerExit(at: now)
            return true
        case .captureLost:
            return runtime.cancelPointerForFocusLoss(at: now)
        case .keyDown(let vk, let mods):
            if let key = Win32KeyMap.translate(virtualKey: vk, shift: mods.shift) {
                return runtime.keyDown(KeyEvent(key: key, mods: mods), at: now)
            }
            return false
        case .char(let scalar):
            let str = String(scalar)
            return runtime.keyDown(KeyEvent(key: .text(str), mods: .none), at: now)
        case .close:
            return runtime.dispatchClose(at: now)
        }
    }
}

/// WM_CHAR delivers UTF-16 code units, including a pair of messages for a non-BMP character.
@MainActor
final class Win32Keyboard {
    private var highSurrogate: UInt16?
    private var pressed: [UInt32: Key] = [:]
    private var lastMods = Mods.none

    // Windows scan codes describe switch positions across keyboard layouts.
    private static let positions: [UInt32: PhysicalKeyCode] = [
        0x01: .escape, 0x02: .digit1, 0x03: .digit2, 0x04: .digit3, 0x05: .digit4,
        0x06: .digit5, 0x07: .digit6, 0x08: .digit7, 0x09: .digit8, 0x0a: .digit9,
        0x0b: .digit0, 0x0c: .minus, 0x0d: .equal, 0x0e: .backspace, 0x0f: .tab,
        0x10: .keyQ, 0x11: .keyW, 0x12: .keyE, 0x13: .keyR, 0x14: .keyT, 0x15: .keyY,
        0x16: .keyU, 0x17: .keyI, 0x18: .keyO, 0x19: .keyP, 0x1a: .bracketLeft, 0x1b: .bracketRight,
        0x1c: .enter, 0x1d: .controlLeft, 0x1e: .keyA, 0x1f: .keyS, 0x20: .keyD, 0x21: .keyF,
        0x22: .keyG, 0x23: .keyH, 0x24: .keyJ, 0x25: .keyK, 0x26: .keyL, 0x27: .semicolon,
        0x28: .quote, 0x29: .backquote, 0x2a: .shiftLeft, 0x2b: .backslash, 0x2c: .keyZ,
        0x2d: .keyX, 0x2e: .keyC, 0x2f: .keyV, 0x30: .keyB, 0x31: .keyN, 0x32: .keyM,
        0x33: .comma, 0x34: .period, 0x35: .slash, 0x36: .shiftRight, 0x37: .numpadMultiply,
        0x38: .altLeft, 0x39: .space, 0x3a: .capsLock, 0x47: .numpad7, 0x48: .numpad8,
        0x49: .numpad9, 0x4a: .numpadSubtract, 0x4b: .numpad4, 0x4c: .numpad5, 0x4d: .numpad6,
        0x4e: .numpadAdd, 0x4f: .numpad1, 0x50: .numpad2, 0x51: .numpad3, 0x52: .numpad0,
        0x53: .numpadDecimal, 0x11c: .numpadEnter, 0x11d: .controlRight, 0x135: .numpadDivide,
        0x138: .altRight, 0x147: .home, 0x148: .arrowUp, 0x149: .pageUp, 0x14b: .arrowLeft,
        0x14d: .arrowRight, 0x14f: .end, 0x150: .arrowDown, 0x151: .pageDown, 0x152: .insert,
        0x153: .delete, 0x15b: .superLeft, 0x15c: .superRight
    ]

    /// WM_KEYDOWN delivers named keys and shortcuts. Windows composes printable input
    /// (dead keys, AltGr, active layout, Caps Lock) and sends it separately via WM_CHAR.
    @MainActor
    func key<State>(vk: UInt32, scan: UInt32, down: Bool, repeated: Bool,
                             mods: Mods, altGr: Bool, layoutCharacter: UnicodeScalar? = nil,
                             shortcutCharacter: UnicodeScalar? = nil,
                             to runtime: Runtime<State>, at now: Double) -> Bool {
        if mods != lastMods {
            lastMods = mods
            runtime.dispatchModifiers(mods, at: now)
            _ = runtime.physicalInput(.modifiers(mods), at: now)
        }
        let mapped = Win32KeyMap.translate(virtualKey: vk, shift: mods.shift)
        let base = layoutCharacter.flatMap { $0.value >= 32 && $0.value != 127 ? String($0).lowercased().first : nil }
        let shortcut = shortcutCharacter.flatMap { $0.value >= 32 && $0.value != 127 ? String($0).lowercased().first : nil } ?? base
        let physical = Self.positions[scan] ?? mapped.flatMap(PhysicalKeyCode.from)
        let logical: Key?
        if !down {
            logical = pressed.removeValue(forKey: scan)
        } else {
            switch mapped {
            case .text(let text):
                logical = mods.ctrl && !altGr ? (shortcut ?? text.lowercased().first).map(Key.command) : nil
            case nil:
                logical = mods.ctrl && !altGr ? shortcut.map(Key.command) : nil
            case .space:
                logical = (mods.ctrl || mods.alt || mods.logo) && !altGr ? .space : nil
            default:
                logical = mapped
            }
            if let logical { pressed[scan] = logical }
        }
        let event = logical.map { KeyEvent(key: $0, mods: mods) }
        return runtime.hostInput(down ? .keyPress : .keyRelease) {
            if let physical {
                return runtime.physicalInput(.key(key: physical, mods: mods, pressed: down, repeat: repeated),
                                             fallbackKey: event, baseChar: base, at: now)
            }
            guard let event else { return false }
            return down ? runtime.keyDown(event, isRepeat: repeated, at: now) : runtime.keyUp(event, at: now)
        }
    }

    @MainActor
    func character<State>(_ unit: UInt16, scan: UInt32, mods: Mods, altGr: Bool,
                                   repeated: Bool, to runtime: Runtime<State>, at now: Double,
                                   route: ((KeyEvent, () -> Bool) -> Bool)? = nil) -> Bool {
        if (0xd800...0xdbff).contains(unit) {
            highSurrogate = unit
            return true
        }
        let high = highSurrogate
        highSurrogate = nil
        guard unit >= 0x20, unit != 0x7f else { return false }
        let scalar: UnicodeScalar?
        if (0xdc00...0xdfff).contains(unit) {
            guard let high else { return false }
            scalar = UnicodeScalar(0x10000 + ((UInt32(high) - 0xd800) << 10) + UInt32(unit) - 0xdc00)
        } else {
            scalar = UnicodeScalar(unit)
        }
        guard let scalar else { return false }
        var textMods = mods
        if altGr {
            textMods.ctrl = false
            textMods.alt = false
        }
        let key: Key = scalar == " " ? .space : .text(String(scalar))
        pressed[scan] = key
        return runtime.hostInput(.keyPress) {
            let event = KeyEvent(key: key, mods: textMods)
            let deliver = { runtime.keyDown(event, isRepeat: repeated, at: now) }
            if altGr { return deliver() }
            return route?(event, deliver) ?? deliver()
        }
    }
}

#if os(Windows)
/// The waker can outlive the window (e.g. an outstanding network task). Detaching while
/// holding the same lock as PostMessage makes HWND destruction safe against concurrent wakes.
final class Win32Wake: @unchecked Sendable {
    private let lock = NSLock()
    private var window: OpaquePointer?

    init(_ window: OpaquePointer) { self.window = window }
    func post() { lock.withLock { if let window { rune_win_wake(window) } } }
    func detach() { lock.withLock { window = nil } }
}

@MainActor
class Win32Callback {
    func receive(_ event: RuneWinEvent) -> Int32 { 0 }
}

func dispatchWin32(_ context: UnsafeMutableRawPointer?, _ event: UnsafePointer<RuneWinEvent>?) -> Int32 {
    guard let context, let event else { return 0 }
    // rune_win_run dispatches WNDPROC synchronously on the main thread that entered it.
    let owner = Unmanaged<Win32Callback>.fromOpaque(context).takeUnretainedValue()
    let address = UInt(bitPattern: event)
    return MainActor.assumeIsolated {
        owner.receive(UnsafePointer<RuneWinEvent>(bitPattern: address)!.pointee)
    }
}

private struct Win32HostError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
private enum WindowsGPUWindows {
    static var active = 0
}

@MainActor
final class Win32Session<State>: Win32Callback, DesktopWindowSession {
    private let windowFrame: DesktopWindowFrame
    let window: OpaquePointer
    let runtime: Runtime<State>
    private var renderer: PortableGLRenderer?
    private var cpuBoot: WindowsCPUWindow?
    private let canRecoverOnCPU: Bool
    private var accessibility: WindowsAccessibilityHost?
    private enum StartupWork { case ready, hooks, gpu, accessibility, done }
    private var startupWork = StartupWork.done
    private let shortcuts: ShortcutGuard
    private let menus: WindowsMenu<State>
    private let popups: WindowsPopup<State>
    private let taskbar: WindowsTaskbar
    let shared: AppShared<State>
    let startedAt = RuneExecutionContext.hostUptime
    private let followAppearance: Bool
    private let forceReducedMotion: Bool
    private let timeScale: Double
    private var drawing = false
    private var windowRest = WindowRestTimer()
    private var deferredRest: WindowRestMachine.Effect?
    #if canImport(CRuneMedia)
    private lazy var videoLayers = WindowsVideoLayers(hwnd: rune_win_hwnd(window), wake: wake)
    #endif
    private var elapsed: Double { (RuneExecutionContext.hostUptime - startedAt) * timeScale }
    private let app: App<State>
    private let reports: FrameReports<State>?
    private let nativeTrace: NativeWindowTrace?
    private let handle: WindowHandle
    private let surfaceMeter: SurfaceMeter
    private let wake: Win32Wake
    private var finished = false
    private var quitHookDelivered = false
    var requestedApplicationQuit = false
    var closesWindowGroup: (() -> Bool)?
    var running: Bool { rune_win_running(window) > 0 }
    private var dpi = Win32DpiScale.baseDPI
    private var keyboard = Win32Keyboard()
    private var first = WindowFirstFrame.opened(at: RuneExecutionContext.hostUptime)
    var firstFrame: Bool { !first.notified }
    fileprivate var bootPhase = -1.0
    private var files: [DroppedFile] = []
    private var dropTarget: OpaquePointer?
    private let dragSource = Win32DragSource()
    private var cursor: Cursor?
    private var cursorDPI: UInt32 = 0
    private var title: String?
    private var visible = false
    private var look = Win32WindowLook.due
    private var cover = CoveredWindowDriver()
    private var coveredDraw = Win32CoveredDraw()
    private var drawFailure: (any Error)?
    var failure: (any Error)? {
        if let drawFailure { return drawFailure }
        return rune_win_running(window) < 0 ? Win32HostError(message: "Activating the window's WGL context failed") : nil
    }

    init(window: OpaquePointer, runtime: Runtime<State>, renderer: PortableGLRenderer?, cpuBoot: WindowsCPUWindow?,
         app: App<State>, handle: WindowHandle, wake: Win32Wake, parsed: ToolingArgs,
         limits: ((Float, Float), (Float, Float)?)) throws {
        windowFrame = DesktopWindowFrame(limits: limits)
        nativeTrace = try NativeWindowTrace(args: parsed, recordsDrawables: false)
        followAppearance = parsed.darkOverride == nil && app.dark == nil
        forceReducedMotion = parsed.reducedMotion
        self.timeScale = parsed.timeScale.isFinite && parsed.timeScale > 0 ? parsed.timeScale : 1
        self.window = window
        self.runtime = runtime
        self.renderer = renderer
        self.cpuBoot = cpuBoot
        canRecoverOnCPU = cpuBoot != nil
        self.shared = app.sharedHandle.shared
        self.shortcuts = ShortcutGuard.attach(shared: app.sharedHandle.shared, wake: runtime.waker, headless: false)
        self.menus = WindowsMenu(window: window, shared: app.sharedHandle.shared, title: app.title)
        self.popups = WindowsPopup(window: window, runtime: runtime)
        self.app = app
        reports = app.onFrameEncodedHook != nil || app.onFrameDrawnHook != nil || app.onFrameInspectHook != nil
            ? FrameReports(onFrameEncoded: app.onFrameEncodedHook, onFrameDrawn: app.onFrameDrawnHook,
                           onInspectDrawn: app.onFrameInspectHook)
            : nil
        self.handle = handle
        self.surfaceMeter = SurfaceMeter(name: handle.key)
        handle.attachSurfaceMeter(surfaceMeter)
        runtime.surfaceMeter = surfaceMeter
        self.wake = wake
        rune_win_enable_redraw_turns(window)
        rune_win_defer_startup_hooks(window)
        if rune_win_screen_reader() != 0 {
            accessibility = WindowsAccessibilityHost(window: rune_win_hwnd(window))
        }
        self.taskbar = WindowsTaskbar(window: rune_win_hwnd(window))
        if renderer != nil { WindowsGPUWindows.active += 1 }
        runtime.wallStart = self.timeScale == 1 ? startedAt : nil
    }

    private func syncCaption() {
        guard let base = app.customTitlebar,
              !app.windowOptionsValue.borderless, !app.chromeStyle.borderless else { return }
        let height = runtime.viewTitlebarOverride.over(base).height
        let mirrored = RuneLabels.shared.isRTL
        var native = RuneWinCaption()
        guard rune_win_caption(window, height, mirrored ? 1 : 0, &native) != 0 else { return }
        let button: TitlebarCaptionButton? = switch native.button {
        case 1: .minimize
        case 2: .maximize
        case 3: .close
        default: nil
        }
        let state: TitlebarCaptionState = button.map {
            native.pressed != 0 ? .pressed($0, over: native.over != 0) : .hovered($0)
        } ?? .idle
        runtime.syncWindowsCaption(TitlebarCaption(height: height, hidden: native.hidden != 0, mirrored: mirrored,
                                                   maximized: native.maximized != 0, minimizable: native.minimizable != 0,
                                                   maximizable: native.maximizable != 0, state: state))
    }

    func start() {
        WindowsWordSegmenter.start()
        menus.synchronize()
        syncCaption()
        app.onWindowHook?(handle)
        bootPhase = rune_win_boot_end("session_start", bootPhase)
        rune_win_start(window, Unmanaged.passUnretained(self).toOpaque(), dispatchWin32,
                       OpenInactiveLaunch.openInactive(app: app.isOpenInactive) ? 1 : 0,
                       app.windowOptionsValue.visible && !app.isWindowless ? 1 : 0)
    }

    func runSessionQuitHook() {
        guard !quitHookDelivered else { return }
        quitHookDelivered = true
        runtime.dispatchQuit(at: elapsed)
    }

    func cancelSessionQuit() { quitHookDelivered = false }

    func endRedrawTurn() -> Bool {
        rune_win_end_redraw_turn(window, visible && cover.canDraw ? 1 : 0) != 0
    }

    var startupWorkOwed: Bool {
        // A queue full of app wakes can postpone WM_TIMER. Its deadline still
        // starts a hidden window on a busy thread, and the native timer wakes an idle one.
        if let deadline = first.readyDeadline, deadline <= RuneExecutionContext.hostUptime {
            queueStartupWork()
        }
        return startupWork != .done
    }

    private func queueStartupWork() {
        if first.takeReady() { startupWork = .ready }
    }

    func performStartupTurn() {
        guard startupWorkOwed, !finished else { return }
        switch startupWork {
        case .ready:
            startupWork = .hooks
            app.onReadyHook?(handle)
            ReadySignal.ready()
        case .hooks:
            startupWork = cpuBoot?.idleStartOwed == true ? .gpu : accessibility == nil ? .accessibility : .done
            dropTarget = rune_win_drop_attach(window)
            rune_win_install_session_lock(window)
        case .gpu:
            startupWork = accessibility == nil ? .accessibility : .done
            cpuBoot?.startGPU(window)
        case .accessibility:
            startupWork = .done
            accessibility = WindowsAccessibilityHost(window: rune_win_hwnd(window))
            accessibility?.update(runtime)
        case .done:
            break
        }
    }

    func endSession() {
        guard running else { return }
        _ = runtime.dispatchClose(at: elapsed)
        rune_win_show(window, 0)
        rune_win_exit(window)
    }

    func finish() {
        guard !finished else { return }
        finished = true
        RuneStartup.started { try nativeTrace?.finish() }
        defer { runtime.cancelPreparedText() }
        closesWindowGroup = nil
        popups.close()
        rune_win_drag_cancel(rune_win_hwnd(window))
        shortcuts.close()
        wake.detach()
        AppMenuBridge.markRunning(shared, running: false)
        menus.close()
        runSessionQuitHook()
        accessibility?.close()
        taskbar.close()
        #if canImport(CRuneMedia)
        videoLayers.clear()
        #endif
        rune_win_drop_detach(dropTarget)
        dropTarget = nil
        if let renderer {
            WindowsGPUWindows.active -= 1
            if rune_win_make_current(window) != 0 {
                renderer.close()
            } else {
                renderer.abandon()
            }
        }
        cpuBoot = nil
        rune_win_destroy(window)
        shared.setVisible(false)
    }

    func applyHandle(_ request: WindowHandleRequest) {
        switch request {
        case .close: rune_win_request_close(window)
        case .minimize: rune_win_minimize(window)
        case .open, .focus: rune_win_show(window, 1); rune_win_focus(window)
        case .show: rune_win_show(window, 1)
        case .hide: rune_win_show(window, 0)
        case let .setPosition(x, y): rune_win_place(window, 1, x, y, 0, 0, 0)
        case let .resize(w, h, animate): windowFrame.apply(WindowFrameRequest(size: (w, h), animate: animate), to: window)
        case .center: windowFrame.apply(WindowFrameRequest(center: true), to: window)
        case .setTitle(let value):
            runtime.windowTitle = value
            syncTitle()
        case .setAlwaysOnTop(let on): rune_win_topmost(window, on ? 1 : 0)
        case .flash(let on): rune_win_flash(window, on ? 1 : 0)
        case .setTaskbar(let state): taskbar.set(state)
        case .setClickThrough(let on): _ = rune_win_click_through(window, on ? 1 : 0)
        }
    }

    func applyReopenRequests() { processRequests(at: elapsed) }

    private func syncTitle() {
        guard let next = runtime.windowTitle, next != title else { return }
        title = next
        (Array(next.utf16) + [0]).withUnsafeBufferPointer { rune_win_set_title(window, $0.baseAddress) }
    }

    private func applyRuntimeShell(closing: Bool = false) {
        syncTitle()
        let minimize = runtime.shellTakeMinimize()
        if runtime.quitRequested || requestedApplicationQuit {
            if !requestedApplicationQuit { requestApplicationQuit(relaunch: runtime.relaunchRequested) }
            rune_win_exit(window)
        } else if runtime.closeWindowRequested {
            runtime.clearShellRequests()
            rune_win_request_close(window)
        } else if minimize && !closing {
            rune_win_minimize(window)
        }
    }

    private func processRequests(at now: Double, pollHidden: Bool = false) {
        _ = MainQueueDispatcher.shared.drain()
        shortcuts.drain()
        let request = shortcuts.withReceiving { shared.applyStateUpdates(to: runtime, at: now) }
        menus.synchronize()
        if request.quit { requestApplicationQuit(relaunch: request.relaunch || runtime.relaunchRequested) }
        if requestedApplicationQuit || runtime.quitRequested {
            applyRuntimeShell()
            return
        }
        if pollHidden && !visible { _ = runtime.hiddenWake(at: now) }
        switch request.window {
        case .close:
            if !runtime.closeWindowRequested { rune_win_request_close(window) }
        case .open, .show: rune_win_show(window, 1)
        case .hide: rune_win_show(window, 0)
        case .none: break
        }
        let position = request.place?.position ?? request.position
        let size = request.place?.size
        if position != nil || size != nil {
            rune_win_place(window, position == nil ? 0 : 1, Int32(position?.x ?? 0), Int32(position?.y ?? 0),
                           size == nil ? 0 : 1, Int32(size?.x ?? 0), Int32(size?.y ?? 0))
        }
        if runtime.toggleMaximizedRequested {
            runtime.toggleMaximizedRequested = false
            rune_win_titlebar(window, 1)
        }
        if runtime.toggleFullScreenRequested {
            runtime.toggleFullScreenRequested = false
            rune_win_toggle_fullscreen(window)
        }
        if request.activation == .minimize { _ = runtime.minimizeStep(.asked) }
        if request.activation == .activate || request.activation == .focus { rune_win_focus(window) }
        applyRuntimeShell(closing: request.window == .close)
        if let frame = runtime.takeWindowFrameRequest() { windowFrame.apply(frame, to: window) }
    }

    func windowUnseen() {
        surfaceMeter.setPacing(.idle)
        #if canImport(CRuneMedia)
        videoLayers.clear()
        #endif
        stepRest(.unseen)
    }

    private func stepRest(_ event: WindowRestMachine.Event) {
        let (effect, timer) = windowRest.step(event)
        switch timer {
        case .keep: break
        case .cancel: rune_win_rest_timer(window, -1)
        case .arm(let due):
            let delay = max(1, ceil((due - RuneExecutionContext.hostUptime) * 1000))
            rune_win_rest_timer(window, Int32(delay))
        }
        guard let effect else { return }
        if drawing {
            if deferredRest != .giveBackAll { deferredRest = effect }
        } else {
            giveBack(effect)
        }
    }

    private func giveBack(_ effect: WindowRestMachine.Effect) {
        runtime.rest(at: elapsed)
        if renderer != nil { rune_win_trim_gpu(window, effect == .giveBackAll ? 1 : 0) }
    }

    private func foundWindow(seen: Bool, at now: Double, wall: Double) {
        let moving = !seen && (!runtime.reducedMotion && runtime.loopRuntime.tracks.keys.contains {
            runtime.kitHooks.unseenPresence.frameById[$0]?.inView == true
        } || app.compositorValue?.isAnimating == true)
        look.found(seen: seen, moving: moving, at: wall)
        guard cover.canDraw != seen else { return }
        _ = cover.setCover(.windows, on: !seen, runtime: runtime, at: now)
        if seen {
            coveredDraw = .init()
        } else {
            windowUnseen()
        }
    }

    private func coveredDelay(at now: Double, wall: Double) -> Int32 {
        var due = look.deadline
        if let next = coveredDraw.deadline { due = due.map { min($0, next) } ?? next }
        if let next = runtime.nextWakeDeadline(after: now) {
            let when = wall + max(0, (next - now) / timeScale)
            due = due.map { min($0, when) } ?? when
        }
        guard let due else { return -1 }
        return Int32(min(Double(Int32.max), max(1, ceil((due - wall) * 1000))))
    }

    private func presentGPU(_ renderer: PortableGLRenderer, frame: RenderFrame,
                            at now: Double, updateMilliseconds: Double) throws -> Int {
        let draws = try renderer.draw(frame, compositor: app.compositorValue, runtime: runtime,
                                      at: now, updateMilliseconds: updateMilliseconds)
        // A custom compositor can change pixels outside the Rune UI damage.
        let damage = app.compositorValue == nil ? rune_gl_last_frame_damage(renderer.handle) : -1
        guard rune_win_swap_damage(window, Int32(frame.width), Int32(frame.height),
                                   rune_gl_last_damage_rects(renderer.handle), damage) != 0 else {
            throw Win32HostError(message: "Windows presentation failed")
        }
        return draws
    }

    private func recoverOnCPU(_ error: any Error) -> Bool {
        guard canRecoverOnCPU, let renderer else { return false }
        if rune_win_make_current(window) != 0 { renderer.close() } else { renderer.abandon() }
        self.renderer = nil
        WindowsGPUWindows.active -= 1
        let cpu = WindowsCPUWindow(only: false, wake: wake, atlas: runtime.textSystem.glyphAtlas)
        cpuBoot = cpu
        cpu.failedGPU(window, reason: String(describing: error))
        surfaceMeter.failed(.outdated)
        // Build the next scene with complete layers and CPU glyph masks.
        wake.post()
        return true
    }

    private func present(_ frame: RenderFrame, at now: Double, updateMilliseconds: Double) throws -> Int? {
        if let renderer {
            do { return try presentGPU(renderer, frame: frame, at: now, updateMilliseconds: updateMilliseconds) }
            catch {
                if recoverOnCPU(error) { return nil }
                throw error
            }
        }
        guard let cpuBoot, visible else { return nil }
        let painted = try cpuBoot.present(frame, runtime: runtime, to: window)
        guard let candidate = cpuBoot.takeGPU(window) else { return painted ? 1 : nil }
        do {
            // Present the same scene the DIB just painted before releasing its retained pixels.
            let draws = try presentGPU(candidate, frame: frame, at: now, updateMilliseconds: updateMilliseconds)
            renderer = candidate
            runtime.textSystem.glyphAtlas.fillMasks(on: nil)
            self.cpuBoot = nil
            WindowsGPUWindows.active += 1
            GpuEvents.presented()
            return draws
        } catch {
            candidate.close()
            cpuBoot.failedGPU(window, reason: String(describing: error))
            return painted ? 1 : nil
        }
    }

    private func draw(at now: Double) -> Int32 {
        // Native modal dialogs may run a nested message pump while Rune is drawing.
        guard !drawing else { return 16 }
        drawing = true
        defer {
            drawing = false
            if let effect = deferredRest {
                deferredRest = nil
                giveBack(effect)
            }
        }
        do {
            if firstFrame { bootPhase = rune_win_boot_end("first_paint_dispatch", bootPhase) }
            // UI Automation presses can request a window action while the app is idle.
            // Deliver them before consuming requests so this paint can carry it out.
            _ = accessibility?.drainActions(runtime, at: now)
            processRequests(at: now)
            // The first swap also reveals a DWM-cloaked window; looking before it would
            // classify its own startup cloak as cover and postpone the first presentation.
            var drawingCovered = false
            if !firstFrame && visible {
                let wall = RuneExecutionContext.hostUptime
                if look.shouldLook(at: wall) {
                    foundWindow(seen: rune_win_is_covered(window) == 0, at: now, wall: wall)
                }
                if !cover.canDraw {
                    if coveredDraw.isDue(at: wall) {
                        drawingCovered = true
                    } else {
                        surfaceMeter.setPacing(.idle)
                        surfaceMeter.skipped()
                        let needed = runtime.isStale || runtime.livePending || runtime.hasPendingInput
                        let committed = runtime.commitCount
                        let updated = runtime.coveredWake(at: now)
                        if needed || updated || runtime.isStale || runtime.commitCount != committed {
                            coveredDraw.asked(at: wall)
                        }
                        accessibility?.update(runtime)
                        processRequests(at: now)
                        return requestedApplicationQuit ? -2 : coveredDelay(at: now, wall: wall)
                    }
                }
            }
            if firstFrame { bootPhase = rune_win_boot_end("first_input_updates", bootPhase) }
            if renderer != nil {
                let slot = rune_win_take_frame_slot(window)
                if slot == 0 { return -1 }
                if slot < 0 {
                    let loss = Win32HostError(message: "Windows lost the GPU presentation surface")
                    guard recoverOnCPU(loss) else { throw loss }
                }
            }
            if drawingCovered {
                _ = coveredDraw.takeDue(at: RuneExecutionContext.hostUptime)
                runtime.settleAll()
            }
            let paced = renderer != nil && rune_win_present_paced(window) != 0
            if visible { surfaceMeter.redraw(paced: paced) }
            let began = RuneExecutionContext.hostUptime
            let commits = runtime.viewCommitCount
            nativeTrace?.begin(runtime, now: began, refreshHz: Double(rune_win_refresh_hz(window)))
            syncCaption()
            let frame = renderer?.frame(runtime, at: now) ?? runtime.renderFrame(at: now)
            if runtime.takeTitlebarChanged() { syncCaption() }
            if firstFrame { bootPhase = rune_win_boot_end("first_layout_text_encode", bootPhase) }
            let encodedAt = RuneExecutionContext.hostUptime
            let updateMs = (encodedAt - began) * 1000
            if !dragSource.pending, let start = runtime.takeDragOutStart() {
                let scale = Win32DpiScale.scaleFactor(forDPI: dpi)
                let picture = DesktopDragPreview.picture(start: start, scale: scale,
                                                       pixelWidth: frame.width, pixelHeight: frame.height)
                dragSource.begin(window: window, start: start, picture: picture, scale: scale) { [weak self] outcome in
                    guard let self else { return }
                    runtime.finishDragOut(outcome, at: elapsed)
                    if !finished { wake.post() }
                }
            }
            #if canImport(CRuneMedia)
            let videoFrame = renderer != nil && visible && cover.canDraw
                ? videoLayers.prepare(frame, allowPromotion: app.compositorValue == nil) : nil
            let presentedFrame = videoFrame?.ui ?? frame
            #else
            let presentedFrame = frame
            #endif
            guard let draws = try present(presentedFrame, at: now, updateMilliseconds: updateMs) else { return -1 }
            let submitted = RuneExecutionContext.hostUptime
            if firstFrame { bootPhase = rune_win_boot_end(renderer == nil ? "first_cpu_draw_total" : "first_gpu_draw_total", bootPhase) }
            runtime.interactionSubmitted(at: submitted)
            nativeTrace?.submitted(runtime, at: submitted, started: began,
                                   target: nil, sequence: nil, continuous: false)
            #if canImport(CRuneMedia)
            if renderer != nil && visible && cover.canDraw {
                // The first GPU frame may have handed over from CPU during present().
                let placement = videoFrame ?? videoLayers.prepare(frame, allowPromotion: app.compositorValue == nil)
                if videoLayers.didPresent(placement) { wake.post() }
            } else {
                videoLayers.clear()
            }
            #endif
            surfaceMeter.presented()
            let active = visible && cover.canDraw && (runtime.isAnimating || app.compositorValue?.isAnimating == true)
            surfaceMeter.setPacing(active ? (paced ? .vsync : .unpaced) : .idle)
            app.devStatsReceiver?(surfaceMeter.currentStats())
            if visible && cover.canDraw && deferredRest != .giveBackAll {
                stepRest(.drew(now: submitted, lowMemory: rune_win_low_memory() != 0))
            }
            if firstFrame {
                _ = rune_win_boot_end("first_present", bootPhase)
                WindowsWordSegmenter.firstFramePresented()
                if renderer != nil { GpuEvents.presented() }
                first.gpuDone()
                _ = first.complete()
                first.notify()
                handle.setReady(true)
                queueStartupWork()
            }
            if let reports, app.onFrameEncodedHook != nil || app.onFrameDrawnHook != nil {
                let refresh = rune_win_refresh_hz(window)
                reports.record(FrameEncoded(
                    outcome: .drawn, frameMs: (submitted - began) * 1000,
                    updateMs: updateMs, encodeMs: (submitted - encodedAt) * 1000,
                    committed: runtime.viewCommitCount != commits, primitives: frame.instances.count,
                    glyphs: frame.instances.reduce(0) { $0 + ($1.params.y == KIND_GLYPH ? 1 : 0) },
                    animating: runtime.isAnimating, compositorAnimating: app.compositorValue?.isAnimating ?? false,
                    drawCount: draws, compositorSummary: app.compositorValue?.summary(), at: submitted,
                    window: handle.key, started: began, refreshHz: refresh > 0 ? Double(refresh) : nil
                ))
                if reports.hasPendingDrawn(at: now) {
                    _ = runtime.updateIf(at: now) { state, tx in reports.flush(state: &state, tx: &tx, at: now) }
                }
            }
            reports?.inspect(runtime)
            let nextCursor = runtime.currentCursor()
            if nextCursor != cursor || cursorDPI != dpi {
                Win32Cursor.apply(nextCursor, dpi: dpi, window: window)
                cursor = nextCursor
                cursorDPI = dpi
            }
            accessibility?.update(runtime)
            let acceptsIME = runtime.windowFocused && runtime.hasImeTarget && !runtime.hasSecureFocus
            rune_win_ime_state(window, acceptsIME ? 1 : 0, runtime.consumeImeReset() ? 1 : 0)
            if acceptsIME, let caret = runtime.focusedCaretRect() {
                let zoom = runtime.zoom()
                rune_win_ime_caret(window, Win32DpiScale.physicalPixels(logical: caret.left * zoom, dpi: dpi),
                                   Win32DpiScale.physicalPixels(logical: caret.bottom * zoom, dpi: dpi))
            }
            applyRuntimeShell()
            if nativeTrace?.reachedLimit == true {
                try nativeTrace?.finish()
                requestedApplicationQuit = true
                rune_win_exit(window)
            }
            if requestedApplicationQuit { return -2 }
            if let frame = runtime.takeWindowFrameRequest() { windowFrame.apply(frame, to: window) }
            if !cover.canDraw { return coveredDelay(at: now, wall: RuneExecutionContext.hostUptime) }
            if visible { popups.pump() }
            if runtime.isAnimating || app.compositorValue?.isAnimating == true || runtime.hasPendingCommit || runtime.livePending || nativeTrace?.keepsDrawing == true {
                return RUNE_WIN_CONTINUE_MOTION
            }
            if runtime.poll != nil { return 16 }
            if let wake = runtime.nextWakeDeadline(after: now) {
                return Int32(min(Double(Int32.max), max(1, ceil((wake - elapsed) / timeScale * 1000))))
            }
            return -1
        } catch {
            surfaceMeter.failed(.outdated)
            drawFailure = error
            return -2
        }
    }

    override func receive(_ event: RuneWinEvent) -> Int32 {
        if event.kind != RUNE_WIN_FRAME { surfaceMeter.noteWaited() }
        let now = elapsed
        let mods = Win32KeyMap.modifiers(event.mods)
        let physical = Vec2(Float(event.x), Float(event.y))
        let scale = Win32DpiScale.scaleFactor(forDPI: dpi)
        let point = runtime.inputPoint(fromWindow: Vec2(physical.x / scale, physical.y / scale))
        let altGr = mods.ctrl && event.mods & 16 != 0

        switch event.kind {
        case RUNE_WIN_MOVE, RUNE_WIN_DOWN, RUNE_WIN_UP, RUNE_WIN_WHEEL:
            if visible { foundWindow(seen: true, at: now, wall: RuneExecutionContext.hostUptime) }
        case RUNE_WIN_POSITION, RUNE_WIN_SIZE, RUNE_WIN_VISIBILITY:
            look = .due
        case RUNE_WIN_FOCUS where event.value != 0:
            look = .due
        default: break
        }

        switch event.kind {
        case RUNE_WIN_FRAME:
            return draw(at: now)
        case RUNE_WIN_READY_WITHOUT_FRAME:
            first.skipped(at: RuneExecutionContext.hostUptime)
            queueStartupWork()
        case RUNE_WIN_SESSION_LOCK:
            Clipboard.shared.clearCurrentSecret()
        case RUNE_WIN_REST_TIMER:
            stepRest(.woke(now: RuneExecutionContext.hostUptime))
        case RUNE_WIN_TRIM_GPU:
            renderer?.giveBackForWindowRest(all: event.value != 0)
        case RUNE_WIN_TASKBAR_CREATED:
            taskbar.reapply()
        case RUNE_WIN_WAKE:
            if !visible { processRequests(at: now, pollHidden: true) }
            else if !cover.canDraw {
                processRequests(at: now)
                coveredDraw.asked(at: RuneExecutionContext.hostUptime)
            }
        case RUNE_WIN_SIZE:
            dpi = event.dpi
            let newScale = Win32DpiScale.scaleFactor(forDPI: dpi)
            windowFrame.resized(Vec2(physical.x / newScale, physical.y / newScale), scale: newScale, runtime: runtime)
        case RUNE_WIN_POSITION:
            let windowScale = Win32DpiScale.scaleFactor(forDPI: event.dpi)
            runtime.setWindowPixels((event.x, event.y))
            runtime.setWindowOrigin(Vec2(physical.x / windowScale, physical.y / windowScale), at: now)
        case RUNE_WIN_VISIBILITY:
            visible = event.value != 0
            if !visible {
                popups.cancel()
                windowUnseen()
            }
            shared.setVisible(visible)
            runtime.setLiveVisible(visible && cover.canDraw, at: now)
        case RUNE_WIN_FOCUS:
            if event.value == 0 {
                keyboard = Win32Keyboard()
                menus.lostFocus()
                _ = runtime.physicalInput(.focusLost, at: now)
            }
            runtime.dispatchFocus(event.value != 0, at: now)
        case RUNE_WIN_SETTINGS:
            let settings = SystemPreferences.current()
            if followAppearance, let dark = settings.darkMode, dark != runtime.systemDark {
                runtime.systemDark = dark
                rune_win_dark_title(window, dark ? 1 : 0)
            }
            runtime.setSystemAccent(settings.accent)
            runtime.doubleClickInterval = settings.doubleClickInterval
            runtime.readSystemAccessibilitySettings(forceReducedMotion: forceReducedMotion)
        case RUNE_WIN_CLOSE:
            guard runtime.dispatchClose(at: now) else { return 0 }
            if app.keepsRunning {
                rune_win_show(window, 0)
                return 0
            }
            // A sibling window can own the native menu loop when the last primary closes.
            if closesWindowGroup?() == true { rune_win_exit(window) }
            return 1
        case RUNE_WIN_MOVE, RUNE_WIN_DOWN, RUNE_WIN_UP, RUNE_WIN_LEAVE, RUNE_WIN_CAPTURE_LOST:
            let message: Win32Message
            switch event.kind {
            case RUNE_WIN_MOVE: message = .mouseMove(x: physical.x, y: physical.y)
            case RUNE_WIN_LEAVE: message = .mouseLeave
            case RUNE_WIN_CAPTURE_LOST: message = .captureLost
            default:
                let buttons: [PointerButton] = [.primary, .secondary, .middle, .back, .forward]
                guard Int(event.value) < buttons.count else { return 0 }
                let button = buttons[Int(event.value)]
                message = event.kind == RUNE_WIN_DOWN
                    ? .mouseDown(button: button, x: physical.x, y: physical.y)
                    : .mouseUp(button: button, x: physical.x, y: physical.y)
            }
            runtime.hostInput(.pointer) {
                var eventDPI = dpi
                _ = Win32MessageTranslator.dispatch(message, to: runtime, dpi: &eventDPI, at: now, pointerMods: mods)
            }
            if let action = runtime.takeTitlebarAction() {
                rune_win_titlebar(window, action == .doubleClick ? 1 : 0)
            }
            if let menu = runtime.takeWindowMenu() {
                _ = rune_win_caption_menu(window, menu == .keyboard ? 1 : 0, event.x, event.y)
            }
        case RUNE_WIN_WHEEL:
            let horizontal = event.horizontal != 0 || mods.shift
            let points = runtime.windowsWheelLinePoints(count: event.count, ticks: event.ticks,
                                                       horizontal: event.horizontal != 0, shift: mods.shift, at: point)
            let distance = event.ticks * points
            runtime.hostInput(.wheel) {
                runtime.desktopWheel(dx: horizontal ? distance : 0, dy: horizontal ? 0 : distance,
                                     at: point, mods: mods, now: now)
            }
        case RUNE_WIN_KEY_DOWN, RUNE_WIN_KEY_UP:
            let down = event.kind == RUNE_WIN_KEY_DOWN
            let layout = UnicodeScalar(event.layout_char)
            let shortcut = UnicodeScalar(event.shortcut_char)
            let deliver = {
                self.keyboard.key(vk: event.value, scan: event.scan, down: down,
                                  repeated: event.repeated != 0, mods: mods, altGr: altGr,
                                  layoutCharacter: layout, shortcutCharacter: shortcut, to: self.runtime, at: now)
            }
            if down {
                if menus.keyDown(vk: event.value, scan: event.scan, shortcut: shortcut, mods: mods,
                                 altGr: altGr, deliver: deliver) { return 1 }
                if event.value == 0x20 && mods.alt && !mods.ctrl && !mods.shift && !mods.logo {
                    return rune_win_caption_menu(window, 1, 0, 0)
                }
                return 0
            }
            return menus.takeRelease(scan: event.scan) || deliver() ? 1 : 0
        case RUNE_WIN_CHAR:
            return keyboard.character(UInt16(truncatingIfNeeded: event.value), scan: event.scan, mods: mods,
                                      altGr: altGr, repeated: event.repeated != 0, to: runtime, at: now,
                                      route: menus.character) ? 1 : 0
        case RUNE_WIN_IME_PREEDIT, RUNE_WIN_IME_COMMIT:
            guard runtime.hasImeTarget, !runtime.hasSecureFocus else { return 0 }
            let string = String(decoding: UnsafeBufferPointer(start: event.text, count: Int(event.length)), as: UTF16.self)
            let offset = ImeUTF16Bridge.utf8Offset(in: string, fromUTF16Offset: Int(event.x))
            let ime: ImeEvent = event.kind == RUNE_WIN_IME_COMMIT
                ? .commit(string) : .preedit(string, cursorUTF8: offset..<offset, clauses: [])
            return runtime.hostInput(.keyPress) { runtime.dispatchImeEvent(ime, at: now) } ? 1 : 0
        case RUNE_WIN_DROP_FILE:
            let path = String(decoding: UnsafeBufferPointer(start: event.text, count: Int(event.length)), as: UTF16.self)
            files.append(DroppedFile(path: path))
        case RUNE_WIN_DROP_ENTER, RUNE_WIN_DROP_END:
            let dropped = files
            files.removeAll(keepingCapacity: true)
            let phase: FileDropPhase = event.kind == RUNE_WIN_DROP_ENTER
                ? .entered(dropped, at: point) : .dropped(dropped, at: point)
            return runtime.receiveFileDrop(phase, at: now) ? 1 : 0
        case RUNE_WIN_DROP_OVER:
            return runtime.receiveFileDrop(.hovered(at: point), at: now) ? 1 : 0
        case RUNE_WIN_DROP_LEAVE:
            runtime.fileDrop(.exited, at: now)
        default: break
        }
        return 0
    }
}

/// Win32 application host. Runtime input, drawing and window messages share one UI thread.
public enum Win32App {
    @MainActor
    public static func run<State>(_ spec: AppSpec<State>, parsed: ToolingArgs, openInactive: Bool = false) throws {
        var entry = AppWindowSpec(key: "main", app: spec)
        entry.openInactive = openInactive
        try DesktopWindowGroup.run([entry.boxed()], options: RunOptions(), parsed: parsed)
    }

    @MainActor
    public static func run<State>(_ app: App<State>, parsed: ToolingArgs) throws {
        let entry = AppWindowSpec(app: app, key: "main")
        try DesktopWindowGroup.run([entry.boxed()], options: app.runOptions, parsed: parsed)
    }

    @MainActor
    static func openSession<State>(app: App<State>, parsed: ToolingArgs, handle: WindowHandle) throws -> Win32Session<State> {
        // Include process loading and app construction before Rune opened this session.
        var boot = rune_win_boot_clock()
        if boot >= 0 { boot = rune_win_boot_end("host_entry", 0) }
        HeadlessRunner.registerFonts(app.fontData)
        boot = rune_win_boot_end("register_fonts", boot)
        let viewport = parsed.viewportOverride ?? app.size
        let preferences = SystemPreferences.current()
        let dark = parsed.darkOverride ?? app.dark ?? preferences.darkMode ?? true
        let options = app.windowOptionsValue
        let appMinimum = app.minSize.map { ($0.x, $0.y) }
        let fittedMinimum = app.isFitContentHeight ? options.fitMinSize(appMin: appMinimum) : appMinimum
        let (minimum, maximum) = options.sizeLimits(appMin: fittedMinimum)
        var error = [CChar](repeating: 0, count: 512)
        let environment = ProcessInfo.processInfo.environment
        let cpuMode = environment["RUNE_CPU_FIRST"]
        let opensOnCPU = options.visible && !app.isWindowless && !options.transparent
            && app.compositorValue == nil && app.srgbBlendEnabled && app.fontSmoothingMode != .slug
            && WindowsGPUWindows.active == 0 && cpuMode != "0"
            && GpuBackendPolicy.defaulted(env: environment["RUNE_GPU_BACKEND"], chosen: app.gpuBackendPreference)
        if !opensOnCPU { GpuEvents.starting() }
        boot = rune_win_boot_end("system_preferences", boot)
        let window = (Array(app.title.utf16) + [0]).withUnsafeBufferPointer {
            let create = opensOnCPU ? rune_win_create_cpu : rune_win_create
            return create($0.baseAddress, nativeDimension(viewport.x), nativeDimension(viewport.y),
                          nativeDimension(minimum.0), nativeDimension(minimum.1), dark ? 1 : 0, &error, 512)
        }
        guard let window else {
            let message = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            throw Win32HostError(message: "Windows renderer initialization failed: \(message)")
        }
        boot = rune_win_boot_end(opensOnCPU ? "window_cpu" : "window_and_wgl_total", boot)
        let wake = Win32Wake(window)
        do {
            let rt = app.makeRuntime(viewport: viewport, pixelScale: 1, systemDark: dark,
                                     reducedMotion: parsed.reducedMotion || preferences.reducedMotion, waker: Waker { wake.post() },
                                     sceneName: parsed.sceneName)
            boot = rune_win_boot_end("runtime_setup", boot)
            rt.useClipboard(.shared)
            rt.recordEvents = false
            rt.urlOpener.headless = false
            rt.readSystemContrastSettings()
            rt.setSystemAccent(preferences.accent)
            rt.doubleClickInterval = preferences.doubleClickInterval
            rt.playgroundHost = app.playgroundHost
            _ = try PlaygroundAttach.attach(
                runtime: rt, host: app.playgroundHost, scenes: app.scenes, sceneOrder: app.sceneOrder,
                makeState: app.makeState, appId: app.title, open: parsed.playgroundName,
                openRequested: parsed.hasPlayground, variant: parsed.playgroundVariant, windowed: true
            )
            boot = rune_win_boot_end("desktop_services", boot)
            let renderer = opensOnCPU ? nil : try PortableGLRenderer(resolve: rune_win_gl_proc, isGLES: false)
            if renderer != nil { boot = rune_win_boot_end("renderer_init_total", boot) }
            if let (x, y) = app.windowOptionsValue.position { rune_win_place(window, 1, x, y, 0, 0, 0) }
            let config = RuneWinOptions(
                max_width: maximum.map { nativeDimension($0.0) } ?? 0,
                max_height: maximum.map { nativeDimension($0.1) } ?? 0,
                borderless: options.borderless || app.chromeStyle.borderless ? 1 : 0,
                resizable: options.resizable ? 1 : 0, minimizable: options.minimizable ? 1 : 0,
                closable: options.closable ? 1 : 0, maximized: app.openAs.isMaximized ? 1 : 0,
                fullscreen: app.openAs.isFullScreen ? 1 : 0)
            if config.fullscreen != 0, config.borderless == 0, let titlebar = app.customTitlebar {
                // Save the custom frame's restored geometry before entering full screen.
                var caption = RuneWinCaption()
                _ = rune_win_caption(window, titlebar.height, RuneLabels.shared.isRTL ? 1 : 0, &caption)
            }
            rune_win_configure(window, config)
            if options.alwaysOnTop { rune_win_topmost(window, 1) }
            let cpu = opensOnCPU ? WindowsCPUWindow(only: cpuMode == "only", wake: wake, atlas: rt.textSystem.glyphAtlas) : nil
            let session = try Win32Session(window: window, runtime: rt, renderer: renderer, cpuBoot: cpu,
                                           app: app, handle: handle, wake: wake, parsed: parsed, limits: (minimum, maximum))
            session.bootPhase = rune_win_boot_end("configure_window_session", boot)
            return session
        } catch {
            wake.detach()
            rune_win_destroy(window)
            throw error
        }
    }
}
#endif
