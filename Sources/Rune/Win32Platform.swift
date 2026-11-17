import Foundation
import RuneMotion
import RuneRef

#if os(Windows)
import CRuneWin32
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
            let scale = Win32DpiScale.scaleFactor(forDPI: dpi)
            runtime.pointerMove(to: Vec2(x / scale, y / scale), mods: pointerMods, at: now)
            return true
        case .mouseDown(let btn, let x, let y):
            let scale = Win32DpiScale.scaleFactor(forDPI: dpi)
            runtime.pointerDown(at: Vec2(x / scale, y / scale), button: btn, mods: pointerMods, at: now)
            return true
        case .mouseUp(let btn, let x, let y):
            let scale = Win32DpiScale.scaleFactor(forDPI: dpi)
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

private func dispatchWin32(_ context: UnsafeMutableRawPointer?, _ event: UnsafePointer<RuneWinEvent>?) -> Int32 {
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
final class Win32Session<State>: Win32Callback, DesktopWindowSession {
    let window: OpaquePointer
    let runtime: Runtime<State>
    let renderer: PortableGLRenderer
    let accessibility: WindowsAccessibilityHost
    private let shortcuts: ShortcutGuard
    private let menus: WindowsMenu<State>
    private let popups: WindowsPopup<State>
    private let taskbar: WindowsTaskbar
    let shared: AppShared<State>
    let startedAt = ProcessInfo.processInfo.systemUptime
    private let followAppearance: Bool
    private let forceReducedMotion: Bool
    private let timeScale: Double
    private var drawing = false
    private var elapsed: Double { (ProcessInfo.processInfo.systemUptime - startedAt) * timeScale }
    private let app: App<State>
    private let reports: FrameReports<State>?
    private let handle: WindowHandle
    private let wake: Win32Wake
    private var finished = false
    private(set) var requestedApplicationQuit = false
    var closesWindowGroup: (() -> Bool)?
    var running: Bool { rune_win_running(window) > 0 }
    private var dpi = Win32DpiScale.baseDPI
    private var keyboard = Win32Keyboard()
    private var firstFrame = true
    fileprivate var bootPhase = -1.0
    private var files: [DroppedFile] = []
    private var dropTarget: OpaquePointer?
    private let dragSource = Win32DragSource()
    private var cursor: Cursor?
    private var cursorDPI: UInt32 = 0
    private var title: String?
    private var visible = false
    private var drawFailure: (any Error)?
    var failure: (any Error)? {
        if let drawFailure { return drawFailure }
        return rune_win_running(window) < 0 ? Win32HostError(message: "Activating the window's WGL context failed") : nil
    }

    init(window: OpaquePointer, runtime: Runtime<State>, renderer: PortableGLRenderer,
         app: App<State>, handle: WindowHandle, wake: Win32Wake, parsed: ToolingArgs) {
        followAppearance = parsed.darkOverride == nil && app.dark == nil
        forceReducedMotion = parsed.reducedMotion
        self.timeScale = parsed.timeScale.isFinite && parsed.timeScale > 0 ? parsed.timeScale : 1
        self.window = window
        self.runtime = runtime
        self.renderer = renderer
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
        self.wake = wake
        self.accessibility = WindowsAccessibilityHost(window: rune_win_hwnd(window))
        self.taskbar = WindowsTaskbar(window: rune_win_hwnd(window))
        runtime.wallStart = self.timeScale == 1 ? startedAt : nil
    }

    func start() {
        menus.synchronize()
        app.onWindowHook?(handle)
        bootPhase = rune_win_boot_end("session_start", bootPhase)
        rune_win_start(window, Unmanaged.passUnretained(self).toOpaque(), dispatchWin32,
                       OpenInactiveLaunch.openInactive(app: app.isOpenInactive) ? 1 : 0,
                       app.windowOptionsValue.visible && !app.isWindowless ? 1 : 0)
    }

    func finish() {
        guard !finished else { return }
        finished = true
        closesWindowGroup = nil
        popups.close()
        rune_win_drag_cancel(rune_win_hwnd(window))
        shortcuts.close()
        wake.detach()
        AppMenuBridge.markRunning(shared, running: false)
        menus.close()
        runtime.dispatchQuit(at: elapsed)
        accessibility.close()
        taskbar.close()
        rune_win_drop_detach(dropTarget)
        dropTarget = nil
        if rune_win_make_current(window) != 0 {
            renderer.close()
        } else {
            renderer.abandon()
        }
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
        case let .resize(w, h, _): rune_win_place(window, 0, 0, 0, 1, nativeDimension(w), nativeDimension(h))
        case .center: rune_win_center(window)
        case .setTitle(let value):
            runtime.windowTitle = value
            (Array(value.utf16) + [0]).withUnsafeBufferPointer { rune_win_set_title(window, $0.baseAddress) }
        case .setAlwaysOnTop(let on): rune_win_topmost(window, on ? 1 : 0)
        case .flash(let on): rune_win_flash(window, on ? 1 : 0)
        case .setTaskbar(let state): taskbar.set(state)
        case .setClickThrough(let on): _ = rune_win_click_through(window, on ? 1 : 0)
        }
    }

    private func processRequests(at now: Double) {
        _ = MainQueueDispatcher.shared.drain()
        shortcuts.drain()
        let request = shortcuts.withReceiving { shared.applyStateUpdates(to: runtime, at: now) }
        menus.synchronize()
        if request.quit || runtime.quitRequested { requestedApplicationQuit = true }
        if requestedApplicationQuit {
            rune_win_exit(window)
            return
        }
        if runtime.closeWindowRequested {
            runtime.clearShellRequests()
            rune_win_request_close(window)
        }
        switch request.window {
        case .close: rune_win_request_close(window)
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
        if request.activation == .minimize || runtime.shellTakeMinimize() { rune_win_minimize(window) }
        if request.activation == .activate || request.activation == .focus { rune_win_focus(window) }
    }

    private func draw(at now: Double) -> Int32 {
        // Native modal dialogs may run a nested message pump while Rune is drawing.
        guard !drawing else { return 16 }
        drawing = true
        defer { drawing = false }
        do {
            if firstFrame { bootPhase = rune_win_boot_end("first_paint_dispatch", bootPhase) }
            processRequests(at: now)
            _ = accessibility.drainActions(runtime, at: now)
            if firstFrame { bootPhase = rune_win_boot_end("first_input_updates", bootPhase) }
            let began = ProcessInfo.processInfo.systemUptime
            let commits = runtime.viewCommitCount
            let frame = renderer.frame(runtime, at: now)
            if firstFrame { bootPhase = rune_win_boot_end("first_layout_text_encode", bootPhase) }
            let encodedAt = ProcessInfo.processInfo.systemUptime
            let updateMs = (encodedAt - began) * 1000
            let draws = try renderer.draw(frame, compositor: app.compositorValue, runtime: runtime,
                                          at: now, updateMilliseconds: updateMs)
            if firstFrame { bootPhase = rune_win_boot_end("first_gpu_draw_total", bootPhase) }
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
            guard rune_win_swap(window) != 0 else { throw Win32HostError(message: "Windows SwapBuffers failed") }
            if firstFrame {
                _ = rune_win_boot_end("first_present", bootPhase)
                GpuEvents.presented()
                ReadySignal.ready()
                firstFrame = false
                dropTarget = rune_win_drop_attach(window)
                handle.setReady(true)
                app.onReadyHook?(handle)
            }
            if let reports {
                let presented = ProcessInfo.processInfo.systemUptime
                reports.record(FrameEncoded(
                    outcome: .drawn, frameMs: (presented - began) * 1000,
                    updateMs: updateMs, encodeMs: (presented - encodedAt) * 1000,
                    committed: runtime.viewCommitCount != commits, primitives: frame.instances.count,
                    glyphs: frame.instances.lazy.filter { $0.params.y == KIND_GLYPH }.count,
                    animating: runtime.isAnimating, compositorAnimating: app.compositorValue?.isAnimating ?? false,
                    drawCount: draws, compositorSummary: app.compositorValue?.summary()
                ))
                _ = runtime.updateIf(at: now) { state, tx in reports.flush(state: &state, tx: &tx, at: now) }
                reports.inspect(runtime)
            }
            let nextCursor = runtime.currentCursor()
            if nextCursor != cursor || cursorDPI != dpi {
                Win32Cursor.apply(nextCursor, dpi: dpi, window: window)
                cursor = nextCursor
                cursorDPI = dpi
            }
            accessibility.update(runtime)
            let acceptsIME = runtime.windowFocused && runtime.hasImeTarget && !runtime.hasSecureFocus
            rune_win_ime_state(window, acceptsIME ? 1 : 0, runtime.consumeImeReset() ? 1 : 0)
            if acceptsIME, let caret = runtime.focusedCaretRect() {
                rune_win_ime_caret(window, Win32DpiScale.physicalPixels(logical: caret.left, dpi: dpi),
                                   Win32DpiScale.physicalPixels(logical: caret.bottom, dpi: dpi))
            }
            if let nextTitle = runtime.windowTitle, nextTitle != title {
                (Array(nextTitle.utf16) + [0]).withUnsafeBufferPointer { rune_win_set_title(window, $0.baseAddress) }
                title = nextTitle
            }
            if runtime.quitRequested && !requestedApplicationQuit {
                requestedApplicationQuit = true
                rune_win_exit(window)
            }
            if requestedApplicationQuit { return -2 }
            if visible { popups.pump() }
            if runtime.isAnimating || app.compositorValue?.isAnimating == true || runtime.hasPendingCommit || runtime.livePending || runtime.poll != nil { return 16 }
            if let wake = runtime.nextWakeDeadline(after: now) {
                return Int32(min(Double(Int32.max), max(1, ceil((wake - elapsed) / timeScale * 1000))))
            }
            return -1
        } catch {
            drawFailure = error
            return -2
        }
    }

    override func receive(_ event: RuneWinEvent) -> Int32 {
        let now = elapsed
        let mods = Win32KeyMap.modifiers(event.mods)
        let physical = Vec2(Float(event.x), Float(event.y))
        let scale = Win32DpiScale.scaleFactor(forDPI: dpi)
        let point = Vec2(physical.x / scale, physical.y / scale)
        let altGr = mods.ctrl && event.mods & 16 != 0

        switch event.kind {
        case RUNE_WIN_FRAME:
            return draw(at: now)
        case RUNE_WIN_TASKBAR_CREATED:
            taskbar.reapply()
        case RUNE_WIN_WAKE:
            if !visible { processRequests(at: now); _ = runtime.hiddenWake(at: now) }
        case RUNE_WIN_SIZE:
            dpi = event.dpi
            var eventDPI = dpi
            _ = Win32MessageTranslator.dispatch(.size(width: Int(event.x), height: Int(event.y)),
                                                to: runtime, dpi: &eventDPI, at: now)
        case RUNE_WIN_VISIBILITY:
            visible = event.value != 0
            if !visible { popups.cancel() }
            shared.setVisible(visible)
            runtime.setLiveVisible(visible, at: now)
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
        case RUNE_WIN_WHEEL:
            let horizontal = event.horizontal != 0 || mods.shift
            let points = event.count == UInt32.max
                ? (horizontal ? runtime.viewport.x : runtime.viewport.y) * 0.875
                : Float(event.count) * (100 / 3)
            let distance = event.ticks * points
            let wheel = WheelEvent(dx: horizontal ? distance : 0, dy: horizontal ? 0 : distance,
                                   precise: false, mods: mods)
            runtime.hostInput(.wheel) { runtime.wheel(wheel, at: point, now: now) }
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
                return menus.keyDown(vk: event.value, scan: event.scan, shortcut: shortcut, mods: mods,
                                     altGr: altGr, deliver: deliver) ? 1 : 0
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
        GpuEvents.starting()
        boot = rune_win_boot_end("system_preferences", boot)
        let window = (Array(app.title.utf16) + [0]).withUnsafeBufferPointer {
            rune_win_create($0.baseAddress, nativeDimension(viewport.x), nativeDimension(viewport.y),
                            nativeDimension(minimum.0), nativeDimension(minimum.1), dark ? 1 : 0, &error, 512)
        }
        guard let window else {
            let message = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            throw Win32HostError(message: "Windows renderer initialization failed: \(message)")
        }
        boot = rune_win_boot_end("window_and_wgl_total", boot)
        let wake = Win32Wake(window)
        do {
            let rt = app.makeRuntime(viewport: viewport, pixelScale: 1, systemDark: dark,
                                     reducedMotion: parsed.reducedMotion || preferences.reducedMotion, waker: Waker { wake.post() },
                                     sceneName: parsed.sceneName)
            boot = rune_win_boot_end("runtime_setup", boot)
            rt.useClipboard(.shared)
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
            let renderer = try PortableGLRenderer(resolve: rune_win_gl_proc, isGLES: false)
            boot = rune_win_boot_end("renderer_init_total", boot)
            if let (x, y) = app.windowOptionsValue.position { rune_win_place(window, 1, x, y, 0, 0, 0) }
            let config = RuneWinOptions(
                max_width: maximum.map { nativeDimension($0.0) } ?? 0,
                max_height: maximum.map { nativeDimension($0.1) } ?? 0,
                borderless: options.borderless || app.chromeStyle.borderless ? 1 : 0,
                resizable: options.resizable ? 1 : 0, minimizable: options.minimizable ? 1 : 0,
                closable: options.closable ? 1 : 0, maximized: app.openAs.isMaximized ? 1 : 0,
                fullscreen: app.openAs.isFullScreen ? 1 : 0)
            rune_win_configure(window, config)
            if options.alwaysOnTop { rune_win_topmost(window, 1) }
            let session = Win32Session(window: window, runtime: rt, renderer: renderer, app: app, handle: handle,
                                       wake: wake, parsed: parsed)
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
