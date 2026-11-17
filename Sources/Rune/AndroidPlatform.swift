import Foundation
import RuneMotion
import RuneRef

#if os(Android)
import Android
import CRuneAndroid
import CRuneDesktopImages
import CRuneDesktopText
#endif

// MARK: - Android NDK Input & Configuration Translators

/// Android `AMotionEvent` action codes (`AMOTION_EVENT_ACTION_*`).
public enum AndroidMotionAction: Int32, Sendable, Equatable {
    case down = 0
    case up = 1
    case move = 2
    case cancel = 3
    case outside = 4
    case hoverMove = 7
    case scroll = 8
    case hoverEnter = 9
    case hoverExit = 10
}

/// Normalized Android `AMotionEvent` payload.
public struct AndroidMotionEvent: Sendable, Equatable {
    public var action: AndroidMotionAction
    public var pointerId: Int32
    /// True for AMOTION_EVENT_TOOL_TYPE_MOUSE. Finger and stylus taps activate on release.
    public var isMouse: Bool
    public var xPx: Float
    public var yPx: Float
    public var button: PointerButton
    public var mods: Mods
    public var hScroll: Float
    public var vScroll: Float

    public init(
        action: AndroidMotionAction,
        pointerId: Int32 = 0,
        isMouse: Bool = false,
        xPx: Float,
        yPx: Float,
        button: PointerButton = .primary,
        mods: Mods = .none,
        hScroll: Float = 0,
        vScroll: Float = 0
    ) {
        self.action = action
        self.pointerId = pointerId
        self.isMouse = isMouse
        self.xPx = xPx
        self.yPx = yPx
        self.button = button
        self.mods = mods
        self.hScroll = hScroll
        self.vScroll = vScroll
    }
}

/// Translates Android `AMotionEvent` into `Runtime<State>` pointer calls in logical DP.
public enum AndroidMotionTranslator {
    @MainActor
    public static func dispatch<State>(
        _ event: AndroidMotionEvent,
        to runtime: Runtime<State>,
        density: Float,
        at now: Double
    ) {
        let touching = runtime.touching()
        if touching {
            switch event.action {
            case .hoverMove, .hoverEnter, .hoverExit, .outside: return
            case .down, .move, .up, .cancel:
                if event.isMouse { return }
            case .scroll: break
            }
        }
        let scale = max(0.5, density)
        let pt = Vec2(event.xPx / scale, event.yPx / scale)
        let id = UInt64(UInt32(bitPattern: event.pointerId))
        runtime.hostInput(.pointer) {
            switch event.action {
            case .down:
                if event.isMouse {
                    runtime.pointerMove(to: pt, mods: event.mods, at: now)
                    runtime.buttonDown(at: pt, button: event.button, mods: event.mods, at: now)
                } else {
                    runtime.touch(id: id, phase: .started, at: pt, time: now, holdClock: now)
                }
            case .move where !event.isMouse:
                runtime.touch(id: id, phase: .moved, at: pt, time: now)
            case .move, .hoverMove, .hoverEnter:
                runtime.pointerMove(to: pt, mods: event.mods, at: now)
            case .up:
                if event.isMouse {
                    runtime.buttonUp(at: pt, button: event.button, mods: event.mods, at: now)
                } else {
                    runtime.touch(id: id, phase: .ended, at: pt, time: now)
                }
            case .cancel:
                if event.isMouse { runtime.cancelPointer(at: now) }
                else { runtime.touch(id: id, phase: .cancelled, at: pt, time: now) }
            case .outside, .hoverExit:
                runtime.pointerExit(at: now)
            case .scroll:
                if !touching { runtime.pointerMove(to: pt, mods: event.mods, at: now) }
                runtime.wheel(.line(x: event.hScroll, y: event.vScroll), at: touching ? (runtime.pointer() ?? pt) : pt,
                              shift: event.mods.shift, now: now)
            }
        }
    }
}

/// Translates Android `AKEYCODE_*` keycodes into `Rune.Key`.
public enum AndroidKeyTranslator {
    public static func translate(keyCode: Int32, unicodeChar: UInt32 = 0, pressed: Bool = true) -> Key? {
        switch keyCode {
        case 19: return .arrowUp     // AKEYCODE_DPAD_UP
        case 20: return .arrowDown   // AKEYCODE_DPAD_DOWN
        case 21: return .arrowLeft   // AKEYCODE_DPAD_LEFT
        case 22: return .arrowRight  // AKEYCODE_DPAD_RIGHT
        case 57: return .modifier(.altLeft, pressed: pressed)
        case 58: return .modifier(.altRight, pressed: pressed)
        case 59: return .modifier(.shiftLeft, pressed: pressed)
        case 60: return .modifier(.shiftRight, pressed: pressed)
        case 61: return .tab         // AKEYCODE_TAB
        case 62: return .space       // AKEYCODE_SPACE
        case 66, 160: return .enter  // AKEYCODE_ENTER, AKEYCODE_NUMPAD_ENTER
        case 67: return .backspace   // AKEYCODE_DEL
        case 82: return .contextMenu
        case 111: return .escape     // AKEYCODE_ESCAPE
        case 112: return .delete     // AKEYCODE_FORWARD_DEL
        case 113: return .modifier(.controlLeft, pressed: pressed)
        case 114: return .modifier(.controlRight, pressed: pressed)
        case 116: return .scrollLock
        case 117: return .modifier(.superLeft, pressed: pressed)
        case 118: return .modifier(.superRight, pressed: pressed)
        case 119: return .modifier(.fn, pressed: pressed)
        case 120: return .printScreen
        case 121: return .pause
        case 124: return .insert
        case 122: return .home       // AKEYCODE_MOVE_HOME
        case 123: return .end        // AKEYCODE_MOVE_END
        case 92: return .pageUp      // AKEYCODE_PAGE_UP
        case 93: return .pageDown    // AKEYCODE_PAGE_DOWN
        case 131...142:              // AKEYCODE_F1..F12
            return .f(UInt8(keyCode - 131 + 1))
        default:
            if unicodeChar >= 0x20, let scalar = UnicodeScalar(unicodeChar) {
                return .text(String(scalar))
            }
            return nil
        }
    }
}

/// Hardware dead keys are stateful. Hold an accent until the next printable key, and
/// preserve the resulting logical key for its release even if the modifier state changes.
struct AndroidHardwareKeyboard {
    enum Stroke: Equatable {
        case ignored, consumed, key(Key)
    }

    private var accent: UnicodeScalar?
    private var presses: [Int32: Stroke] = [:]

    mutating func translate(action: Int32, code: Int32, character: UInt32,
                            compose: (UInt32, UInt32) -> UInt32) -> Stroke {
        if action == 1 {
            if let pressed = presses.removeValue(forKey: code) { return pressed }
            guard let key = AndroidKeyTranslator.translate(keyCode: code, unicodeChar: character, pressed: false) else { return .ignored }
            return .key(key)
        }
        guard action == 0 else { return .ignored }
        if let repeated = presses[code] { return repeated }
        if character & 0x8000_0000 != 0, let nextAccent = UnicodeScalar(character & 0x7fff_ffff) {
            let previous = accent
            accent = nextAccent
            let stroke: Stroke
            if previous == nextAccent {
                accent = nil
                stroke = .key(.text(String(nextAccent)))
            } else {
                stroke = previous.map { .key(.text(String($0))) } ?? .consumed
            }
            presses[code] = stroke
            return stroke
        }
        guard let key = AndroidKeyTranslator.translate(keyCode: code, unicodeChar: character) else { return .ignored }
        if case .modifier = key { return .key(key) }
        let stroke: Stroke
        if let accent, let scalar = UnicodeScalar(character), character >= 0x20, character != 0x7f {
            self.accent = nil
            let joined = compose(accent.value, scalar.value)
            let text = joined == 0 ? nil : UnicodeScalar(joined).map { String($0) }
            stroke = .key(.text(text ?? (String(accent) + String(scalar))))
        } else if accent != nil && (key == .backspace || key == .escape) {
            accent = nil
            stroke = .consumed
        } else {
            accent = nil
            stroke = .key(key)
        }
        presses[code] = stroke
        return stroke
    }
}

/// Snapshot of Android `AConfiguration` display density, insets, and night mode.
public struct AndroidConfigurationState: Sendable, Equatable {
    public var densityDPI: Int32
    public var isNightMode: Bool
    /// Safe-area insets `(top, right, bottom, left)` in logical DP.
    public var safeAreaInsets: SIMD4<Float>

    public init(
        densityDPI: Int32 = 160,
        isNightMode: Bool = false,
        safeAreaInsets: SIMD4<Float> = .zero
    ) {
        self.densityDPI = max(120, densityDPI)
        self.isNightMode = isNightMode
        self.safeAreaInsets = safeAreaInsets
    }

    public var pixelScale: Float {
        Float(densityDPI) / 160.0
    }
}

#if os(Android)
private enum AndroidHostError: Error, CustomStringConvertible {
    case missingActivity, attachFailed, missingShader(String)
    var description: String {
        switch self {
        case .missingActivity: "Start Rune from ANativeActivity_onCreate using AndroidApp.attach(to:spec:)."
        case .attachFailed: "Could not attach Rune to this NativeActivity main looper (Android API 24+ required)."
        case .missingShader(let name): "Missing APK asset GL/\(name)."
        }
    }
}

private final class AndroidWake: Sendable {
    let fd: Int32
    init(_ fd: Int32) { self.fd = fd }
    deinit { rune_android_close_wake(fd) }
}

/// The NDK invokes all activity, input queue, and display callbacks on Android's UI thread.
@MainActor
private final class AndroidSession {
    let waker = Waker()
    private let drawFrame: (Int32, Int32, Float, Bool) throws -> Double
    let textIdle: (Bool) -> Bool
    let pollGPU: (Bool) -> Bool
    let motion: (AndroidMotionEvent) -> Void
    let key: (Int32, Int32, Int32, Int32, UInt32) -> Bool
    let suspendInput: () -> Void
    let focus: (Bool) -> Void
    let visible: (Bool) -> Void
    let releaseGPU: (Bool) -> Void
    let shutdown: () -> Void
    let activity: UnsafeMutableRawPointer

    init<State>(activity: UnsafeMutableRawPointer, app: App<State>, parsed: ToolingArgs,
                configure: (Runtime<State>) -> Void) {
        self.activity = activity
        HeadlessRunner.registerFonts(app.fontData)
        let appearanceOverride = parsed.darkOverride ?? app.dark
        let runtime = app.makeRuntime(viewport: app.size, pixelScale: 1, systemDark: appearanceOverride,
                                      reducedMotion: parsed.reducedMotion, waker: waker, sceneName: parsed.sceneName)
        runtime.recordEvents = false
        configure(runtime)
        textIdle = { run in
            guard !runtime.hasPendingCommit else { return false }
            return run ? runtime.textIdleTurn() : runtime.textIdleOwed
        }
        runtime.readSystemContrastSettings()
        let semantics = AndroidSemanticBridge(activity: activity, runtime: runtime)
        let start = ProcessInfo.processInfo.systemUptime
        runtime.wallStart = parsed.timeScale == 1 ? start : nil
        let now = { (ProcessInfo.processInfo.systemUptime - start) * parsed.timeScale }
        var renderer: PortableGLRenderer?
        pollGPU = { run in
            guard let renderer, renderer.needsSurfaceCompletionPoll else { return false }
            return run ? renderer.pollSurfaceCompletions() : true
        }
        var nativeKeyboardVisible = false
        var activeFinger: Int32?
        var lastMods: Mods = .none
        var keyboard = AndroidHardwareKeyboard()
        drawFrame = { width, height, scale, dark in
            runtime.pixelScale = scale
            runtime.viewport = Vec2(Float(width) / scale, Float(height) / scale)
            runtime.systemDark = appearanceOverride ?? dark
            if renderer == nil {
                renderer = try PortableGLRenderer(resolve: rune_android_resolve, isGLES: true, bundledShaderAssets: true) { name in
                    guard let bytes = rune_android_read_shader(activity, name) else { throw AndroidHostError.missingShader(name) }
                    defer { rune_android_free_string(bytes) }
                    return String(cString: bytes)
                }
            }
            guard let renderer else { throw PortableGLRenderer.RenderError("Rune GLES renderer is unavailable") }
            let time = now()
            _ = MainQueueDispatcher.shared.drain()
            let requests = app.sharedHandle.shared.applyStateUpdates(to: runtime, at: time)
            let updateStart = ProcessInfo.processInfo.systemUptime
            let frame = renderer.frame(runtime, at: time)
            let updateMS = (ProcessInfo.processInfo.systemUptime - updateStart) * 1000
            try renderer.draw(frame, compositor: app.compositorValue, runtime: runtime, at: time, updateMilliseconds: updateMS)
            semantics.refresh()
            if !semantics.isAttached {
                let wantsKeyboard = runtime.hasImeTarget || runtime.hasSecureFocus
                if wantsKeyboard != nativeKeyboardVisible {
                    rune_android_keyboard(activity, wantsKeyboard ? 1 : 0)
                    nativeKeyboardVisible = wantsKeyboard
                }
            }
            let closeRequested = requests.window == .close && runtime.dispatchClose(at: time)
            if closeRequested || requests.quit || requests.relaunch || runtime.quitRequested || runtime.relaunchRequested {
                rune_android_finish(activity)
                return -1
            }
            if runtime.isAnimating || app.compositorValue?.isAnimating == true || runtime.hasPendingCommit || runtime.poll != nil { return 0 }
            guard parsed.timeScale > 0, let next = runtime.nextWakeDeadline(after: time) else { return -1 }
            return max(0, (next - time) / parsed.timeScale)
        }
        focus = { runtime.windowFocus($0, at: now()) }
        visible = {
            runtime.setLiveVisible($0, at: now())
            app.sharedHandle.shared.setVisible($0)
        }
        releaseGPU = { contextCurrent in
            if contextCurrent { renderer?.close() } else { renderer?.abandon() }
            renderer = nil
        }
        shutdown = {
            semantics.close()
            runtime.dispatchQuit(at: now())
            runtime.cancelPreparedText()
            ReadySignal.clear()
        }
        motion = { event in
            if !event.isMouse {
                if event.action == .down && activeFinger == nil { activeFinger = event.pointerId }
                if event.action == .up || event.action == .cancel, event.pointerId == activeFinger { activeFinger = nil }
            }
            AndroidMotionTranslator.dispatch(event, to: runtime, density: runtime.pixelScale, at: now())
        }
        key = { action, code, meta, repeats, character in
            let mods = androidModifiers(meta)
            let time = now()
            if mods != lastMods {
                lastMods = mods
                runtime.dispatchModifiers(mods, at: time)
            }
            let stroke = keyboard.translate(action: action, code: code, character: character) {
                rune_android_compose_key(activity, $0, $1)
            }
            guard case .key(let key) = stroke else { return stroke == .consumed }
            let event = KeyEvent(key: key, mods: mods)
            return runtime.hostInput(.keyPress) {
                if action == 0 { return runtime.keyDown(event, isRepeat: repeats > 0, at: now()) }
                if action == 1 { return runtime.keyUp(event, at: now()) }
                return false
            }
        }
        suspendInput = {
            keyboard = AndroidHardwareKeyboard()
            lastMods = .none
            if let id = activeFinger {
                runtime.touch(id: UInt64(UInt32(bitPattern: id)), phase: .cancelled, at: .zero, time: now())
                activeFinger = nil
            }
            runtime.cancelPointer(at: now())
        }
    }

    func draw(width: Int32, height: Int32, scale: Float, dark: Bool) -> Double {
        do { return try drawFrame(width, height, scale, dark) }
        catch {
            rune_android_log(String(describing: error))
            rune_android_finish(activity)
            return -.infinity
        }
    }
}

private func androidModifiers(_ meta: Int32) -> Mods {
    Mods(shift: meta & 1 != 0, ctrl: meta & 0x1000 != 0, alt: meta & 2 != 0, logo: meta & 0x10000 != 0)
}

private func session(_ state: UnsafeMutableRawPointer?) -> AndroidSession {
    Unmanaged<AndroidSession>.fromOpaque(state!).takeUnretainedValue()
}

/// Hosts a Rune app in android.app.NativeActivity. State lives across surface recreation.
public enum AndroidApp {
    @MainActor private static var attachingActivity: UnsafeMutableRawPointer?

    /// Call once from the app library's ANativeActivity_onCreate entry point on the main thread.
    @MainActor
    public static func attach<State>(to activity: UnsafeMutableRawPointer, spec: AppSpec<State>) {
        attach(to: activity) { try RuneApp.run(spec, arguments: []) }
    }

    @MainActor
    public static func attach<State>(to activity: UnsafeMutableRawPointer, app: App<State>) {
        attach(to: activity) { try RuneApp.run(app, arguments: app.runOptions.arguments ?? []) }
    }

    @MainActor
    private static func attach(to activity: UnsafeMutableRawPointer, launch: () throws -> Void) {
        rune_image_android_attach(activity)
        attachingActivity = activity
        defer { attachingActivity = nil }
        do { try launch() }
        catch { rune_android_log(String(describing: error)); rune_android_finish(activity) }
    }

    @MainActor
    public static func run<State>(_ spec: AppSpec<State>, parsed: ToolingArgs) throws {
        var app = App(title: spec.title, size: spec.size, minSize: spec.minSize, dark: spec.dark,
                      state: spec.makeState(), view: spec.view)
        app.scenes = spec.scenes
        app.fontData = spec.fonts
        app.fontFamilies = spec.families
        app.setupHook = spec.setup
        app.pollHook = spec.poll
        app.onKeyHook = spec.onKey
        app.srgbBlendEnabled = spec.srgbBlend
        try run(app, parsed: parsed) {
            $0.onAppFileDrop = spec.onFileDrop
            $0.onFileDrop = spec.onFileDropPhase
        }
    }

    @MainActor
    public static func run<State>(_ app: App<State>, parsed: ToolingArgs) throws {
        try run(app, parsed: parsed) { _ in }
    }

    @MainActor
    private static func run<State>(_ app: App<State>, parsed: ToolingArgs,
                                   configure: (Runtime<State>) -> Void) throws {
        guard let activity = attachingActivity else { throw AndroidHostError.missingActivity }
        rune_android_text_attach(activity)
        let host = AndroidSession(activity: activity, app: app, parsed: parsed, configure: configure)
        let retained = Unmanaged.passRetained(host)
        var callbacks = RuneAndroidCallbacks()
        callbacks.frame = { ptr, w, h, scale, dark in
            let host = session(ptr)
            return MainActor.assumeIsolated { host.draw(width: w, height: h, scale: scale, dark: dark != 0) }
        }
        callbacks.presented = { _ in ReadySignal.ready() }
        callbacks.text_idle = { ptr, run in
            let host = session(ptr)
            return MainActor.assumeIsolated { host.textIdle(run != 0) ? 1 : 0 }
        }
        callbacks.release_gpu = { ptr, current in
            let host = session(ptr)
            MainActor.assumeIsolated { host.releaseGPU(current != 0) }
        }
        callbacks.poll_gpu = { ptr, run in
            let host = session(ptr)
            return MainActor.assumeIsolated { host.pollGPU(run != 0) ? 1 : 0 }
        }
        callbacks.suspend_input = { ptr in
            let host = session(ptr)
            MainActor.assumeIsolated { host.suspendInput() }
        }
        callbacks.focus = { ptr, active in
            let host = session(ptr)
            MainActor.assumeIsolated { host.focus(active != 0) }
        }
        callbacks.visible = { ptr, active in
            let host = session(ptr)
            MainActor.assumeIsolated { host.visible(active != 0) }
        }
        callbacks.destroy = { ptr in
            let host = Unmanaged<AndroidSession>.fromOpaque(ptr!).takeRetainedValue()
            MainActor.assumeIsolated {
                host.waker.setCallback {}
                host.shutdown()
            }
        }
        callbacks.motion = { ptr, m in
            guard let action = AndroidMotionAction(rawValue: m.action) else { return }
            let host = session(ptr)
            let button: PointerButton = m.buttons & 2 != 0 ? .secondary : (m.buttons & 4 != 0 ? .middle : .primary)
            let event = AndroidMotionEvent(action: action, pointerId: m.id, isMouse: m.mouse != 0, xPx: m.x, yPx: m.y,
                                           button: button, mods: androidModifiers(m.meta), hScroll: m.hscroll, vScroll: m.vscroll)
            MainActor.assumeIsolated { host.motion(event) }
        }
        callbacks.key = { ptr, action, code, meta, repeatCount, character in
            let host = session(ptr)
            return MainActor.assumeIsolated { host.key(action, code, meta, repeatCount, character) ? 1 : 0 }
        }
        let fd = rune_android_attach(activity, retained.toOpaque(), callbacks)
        guard fd >= 0 else {
            host.shutdown()
            retained.release()
            throw AndroidHostError.attachFailed
        }
        let wake = AndroidWake(fd)
        host.waker.setCallback { rune_android_wake(wake.fd) }
    }

    /// Copies a CPU-rendered frame to a separate, CPU-owned Android native window.
    public static func present(frame: Frame, to windowPtr: UnsafeMutableRawPointer) {
        guard let width = Int32(exactly: frame.width), let height = Int32(exactly: frame.height),
              width > 0, height > 0, frame.rgba.count / 4 / frame.width >= frame.height else { return }
        frame.rgba.withUnsafeBufferPointer {
            rune_android_present_rgba(windowPtr, $0.baseAddress, width, height)
        }
    }
}
#endif
