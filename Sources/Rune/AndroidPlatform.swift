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
    /// Maps Android `AMotionEvent` / `MotionEvent` button-state bitmask to `PointerButton`.
    public static func button(from buttonState: Int32) -> PointerButton {
        if buttonState & 2 != 0 { return .secondary }
        if buttonState & 4 != 0 { return .middle }
        return .primary
    }
}

/// Translates Android `AKEYCODE_*` keycodes into `Rune.Key`.
public enum AndroidKeyTranslator {
    /// Maps Android `AMETA_*` / `KeyEvent.META_*` bitmask into `Rune.Mods`.
    public static func modifiers(from metaState: Int32) -> Mods {
        Mods(
            shift: metaState & 1 != 0,
            ctrl: metaState & 0x1000 != 0,
            alt: metaState & 2 != 0,
            logo: metaState & 0x10000 != 0
        )
    }

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

/// Normalized Android `AKeyEvent` / `android.view.KeyEvent` payload.
public struct AndroidKeyEvent: Sendable, Equatable {
    public enum Action: Int32, Sendable, Equatable {
        case down = 0
        case up = 1
    }

    public var action: Action
    public var keyCode: Int32
    public var metaState: Int32
    public var repeatCount: Int32
    public var unicodeChar: UInt32

    public init(
        action: Action,
        keyCode: Int32,
        metaState: Int32 = 0,
        repeatCount: Int32 = 0,
        unicodeChar: UInt32 = 0
    ) {
        self.action = action
        self.keyCode = keyCode
        self.metaState = metaState
        self.repeatCount = repeatCount
        self.unicodeChar = unicodeChar
    }

    public var mods: Mods {
        AndroidKeyTranslator.modifiers(from: metaState)
    }
}

/// Configuration for embedding a Rune view inside an Android `RuneSurfaceView`.
public struct AndroidSurfaceConfig: Sendable, Equatable {
    public var initialSize: Vec2
    public var configuration: AndroidConfigurationState
    public var darkOverride: Bool?
    public var reducedMotion: Bool
    public var timeScale: Double
    public var sceneName: String?
    public var transparentBackground: Bool
    public var forwardSafeAreaInsets: Bool

    public init(
        initialSize: Vec2 = Vec2(320, 240),
        configuration: AndroidConfigurationState = AndroidConfigurationState(),
        darkOverride: Bool? = nil,
        reducedMotion: Bool = false,
        timeScale: Double = 1.0,
        sceneName: String? = nil,
        transparentBackground: Bool = false,
        forwardSafeAreaInsets: Bool = false
    ) {
        self.initialSize = initialSize
        self.configuration = configuration
        self.darkOverride = darkOverride
        self.reducedMotion = reducedMotion
        self.timeScale = max(0, timeScale)
        self.sceneName = sceneName
        self.transparentBackground = transparentBackground
        self.forwardSafeAreaInsets = forwardSafeAreaInsets
    }
}

/// Lifecycle phase of an embedded `RuneSurfaceView` host.
public enum AndroidSurfaceLifecycleState: String, Sendable, Equatable {
    case created
    case attached
    case surfaceReady
    case paused
    case disposed
}

/// Scheduling outcome returned after stepping a frame in `AndroidSurfaceHost`.
public enum AndroidFrameDisposition: Sendable, Equatable {
    /// Actively animating or dirty; schedule the next Choreographer VSync immediately.
    case continueAnimating
    /// Idle until the next timer, hover, or touch-hold deadline (`seconds > 0`).
    case wakeAfter(Double)
    /// Fully idle; sleep until the next input event or `Waker` wakeup.
    case idle
    /// The embedded Rune runtime requested close or quit.
    case closeRequested
    /// No frame was drawn because the view is disposed, hidden, or lacks a valid surface.
    case skipped

    /// C/JNI delay convention matching `RuneAndroidSurfaceCallbacks.frame`.
    public var nativeDelaySeconds: Double {
        switch self {
        case .continueAnimating: return 0
        case .wakeAfter(let seconds): return max(0, seconds)
        case .idle, .skipped: return -1
        case .closeRequested: return -.infinity
        }
    }
}

/// Portable host managing a Rune `Runtime<State>` embedded inside an Android `RuneSurfaceView`.
///
/// Handles Android surface lifecycle (`surfaceCreated` / `surfaceChanged` / `surfaceDestroyed`),
/// window attachment/visibility/focus, configuration and density updates, safe-area insets,
/// touch/pointer/hover/scroll/key translation, dead-key composition, and frame pacing.
@MainActor
public final class AndroidSurfaceHost<State> {
    public let runtime: Runtime<State>
    public let waker: Waker
    public let config: AndroidSurfaceConfig

    public private(set) var lifecycleState: AndroidSurfaceLifecycleState = .created
    public private(set) var configuration: AndroidConfigurationState
    public private(set) var pixelWidth: Int32 = 0
    public private(set) var pixelHeight: Int32 = 0
    public private(set) var isAttachedToWindow = false
    public private(set) var isSurfaceReady = false
    public private(set) var isVisible = false
    public private(set) var hasWindowFocus = false
    public private(set) var isDisposed = false
    public private(set) var presentedFrameCount: UInt64 = 0

    /// Invoked whenever state changes, safe-area updates, or background `Waker.wake()` need a redraw.
    public var onRequestFrame: (@Sendable () -> Void)? {
        didSet {
            let callback = onRequestFrame
            waker.setCallback { callback?() }
        }
    }

    /// Invoked when the embedded Rune UI requests closing or quitting.
    public var onCloseRequested: (() -> Void)?

    /// Invoked when EGL resources should be torn down (`Bool` indicates whether the GL context is current).
    public var onReleaseGPU: ((Bool) -> Void)?

    private let appShared: AppShared<State>
    private let compositor: AnyCompositor<State>?
    private let appearanceOverride: Bool?
    private let clock: () -> Double
    private var activeFinger: Int32?
    private var lastMods: Mods = .none
    private var keyboard = AndroidHardwareKeyboard()
    private var hasSeenVisibility = false
    private var hasBeenActive = false
    private var onDisposeHook: (() -> Void)?

    public convenience init(
        spec: AppSpec<State>,
        config: AndroidSurfaceConfig = AndroidSurfaceConfig(),
        clock: (() -> Double)? = nil
    ) {
        var app = App(
            title: spec.title,
            size: spec.size,
            minSize: spec.minSize,
            dark: spec.dark,
            state: spec.makeState(),
            view: spec.view
        )
        app.scenes = spec.scenes
        app.fontData = spec.fonts
        app.fontFamilies = spec.families
        app.setupHook = spec.setup
        app.pollHook = spec.poll
        app.onKeyHook = spec.onKey
        app.srgbBlendEnabled = spec.srgbBlend
        self.init(app: app, config: config, clock: clock) {
            $0.onAppFileDrop = spec.onFileDrop
            $0.onFileDrop = spec.onFileDropPhase
        }
    }

    public init(
        app: App<State>,
        config: AndroidSurfaceConfig = AndroidSurfaceConfig(),
        clock: (() -> Double)? = nil,
        configure: (Runtime<State>) -> Void = { _ in }
    ) {
        self.config = config
        self.configuration = config.configuration
        self.appShared = app.sharedHandle.shared
        self.compositor = app.compositorValue
        self.waker = Waker()
        HeadlessRunner.registerFonts(app.fontData)

        let appearanceOverride = config.darkOverride ?? app.dark
        self.appearanceOverride = appearanceOverride
        let initialViewport = (config.initialSize.x > 0 && config.initialSize.y > 0)
            ? config.initialSize
            : app.size
        let initialScale = max(0.5, config.configuration.pixelScale)

        let runtime = app.makeRuntime(
            viewport: initialViewport,
            pixelScale: initialScale,
            systemDark: appearanceOverride ?? config.configuration.isNightMode,
            reducedMotion: config.reducedMotion,
            waker: waker,
            sceneName: config.sceneName
        )
        runtime.recordEvents = false
        configure(runtime)
        runtime.readSystemContrastSettings()
        if config.configuration.safeAreaInsets != .zero {
            _ = runtime.setSafeAreaInsets(config.configuration.safeAreaInsets)
        }
        self.runtime = runtime

        if let clock {
            self.clock = clock
            runtime.wallStart = nil
        } else {
            let start = ProcessInfo.processInfo.systemUptime
            let timeScale = config.timeScale
            runtime.wallStart = timeScale == 1 ? start : nil
            self.clock = { (ProcessInfo.processInfo.systemUptime - start) * timeScale }
        }
    }

    internal func installDisposeHook(_ hook: @escaping () -> Void) {
        onDisposeHook = hook
    }

    private func now() -> Double {
        clock()
    }

    private func refreshLifecycleState() {
        if isDisposed {
            lifecycleState = .disposed
        } else if isSurfaceReady && (isVisible || !hasSeenVisibility) {
            lifecycleState = .surfaceReady
        } else if hasBeenActive {
            lifecycleState = .paused
        } else if isAttachedToWindow {
            lifecycleState = .attached
        } else {
            lifecycleState = .created
        }
    }

    private func applyViewport(width: Int32, height: Int32, scale: Float) {
        let clampedScale = max(0.5, scale)
        runtime.pixelScale = clampedScale
        if width > 0 && height > 0 {
            runtime.viewport = Vec2(Float(width) / clampedScale, Float(height) / clampedScale)
        }
    }

    /// Called from `View.onAttachedToWindow()`.
    public func attachToWindow() {
        guard !isDisposed else { return }
        isAttachedToWindow = true
        refreshLifecycleState()
    }

    /// Called from `View.onDetachedFromWindow()`. Suspends active input and pauses rendering while preserving state.
    public func detachFromWindow() {
        guard !isDisposed else { return }
        isAttachedToWindow = false
        if hasWindowFocus {
            setWindowFocus(false)
        }
        if isVisible {
            setVisible(false)
        }
        suspendInput()
        hasBeenActive = true
        refreshLifecycleState()
    }

    /// Called from `SurfaceHolder.Callback.surfaceCreated`.
    public func surfaceCreated(width: Int32 = 0, height: Int32 = 0) {
        guard !isDisposed else { return }
        isSurfaceReady = true
        hasBeenActive = true
        if width > 0 && height > 0 {
            pixelWidth = width
            pixelHeight = height
            applyViewport(width: width, height: height, scale: runtime.pixelScale)
        }
        refreshLifecycleState()
    }

    /// Called from `SurfaceHolder.Callback.surfaceChanged`.
    public func surfaceChanged(
        width: Int32,
        height: Int32,
        density: Float? = nil,
        isNightMode: Bool? = nil
    ) {
        guard !isDisposed else { return }
        isSurfaceReady = true
        hasBeenActive = true
        pixelWidth = max(0, width)
        pixelHeight = max(0, height)
        if density != nil || isNightMode != nil {
            updateConfiguration(density: density, isNightMode: isNightMode)
        } else {
            applyViewport(width: pixelWidth, height: pixelHeight, scale: runtime.pixelScale)
        }
        refreshLifecycleState()
    }

    /// Called from `SurfaceHolder.Callback.surfaceDestroyed`. Releases GPU resources while preserving UI state.
    public func surfaceDestroyed(contextCurrent: Bool = false) {
        guard !isDisposed else { return }
        isSurfaceReady = false
        hasBeenActive = true
        suspendInput()
        onReleaseGPU?(contextCurrent)
        refreshLifecycleState()
    }

    /// Called from `View.onVisibilityChanged` / `View.onWindowVisibilityChanged`.
    public func setVisible(_ visible: Bool) {
        guard !isDisposed else { return }
        hasSeenVisibility = true
        if !visible { hasBeenActive = true }
        let changed = isVisible != visible
        isVisible = visible
        if changed {
            let time = now()
            runtime.setLiveVisible(visible, at: time)
            appShared.setVisible(visible)
            if !visible {
                suspendInput()
            }
        }
        refreshLifecycleState()
    }

    /// Called from `View.onWindowFocusChanged`.
    public func setWindowFocus(_ focused: Bool) {
        guard !isDisposed else { return }
        guard hasWindowFocus != focused else { return }
        hasWindowFocus = focused
        runtime.windowFocus(focused, at: now())
        if !focused {
            suspendInput()
        }
    }

    /// Applies a full `AndroidConfigurationState` snapshot (density, night mode, safe-area insets).
    public func setConfiguration(_ newConfig: AndroidConfigurationState) {
        guard !isDisposed else { return }
        configuration = newConfig
        applyViewport(width: pixelWidth, height: pixelHeight, scale: newConfig.pixelScale)
        runtime.systemDark = appearanceOverride ?? newConfig.isNightMode
        _ = runtime.setSafeAreaInsets(newConfig.safeAreaInsets)
    }

    /// Applies an incremental Android configuration update from `onConfigurationChanged` or `surfaceChanged`.
    public func updateConfiguration(
        densityDPI: Int32? = nil,
        density: Float? = nil,
        isNightMode: Bool? = nil
    ) {
        guard !isDisposed else { return }
        let resolvedDPI: Int32
        if let densityDPI, densityDPI > 0 {
            resolvedDPI = max(120, densityDPI)
        } else if let density, density > 0 {
            resolvedDPI = max(120, Int32((density * 160.0).rounded()))
        } else {
            resolvedDPI = configuration.densityDPI
        }
        let resolvedScale: Float
        if let density, density > 0 {
            resolvedScale = max(0.5, density)
        } else {
            resolvedScale = max(0.5, Float(resolvedDPI) / 160.0)
        }
        configuration.densityDPI = resolvedDPI
        if let isNightMode {
            configuration.isNightMode = isNightMode
        }
        applyViewport(width: pixelWidth, height: pixelHeight, scale: resolvedScale)
        runtime.systemDark = appearanceOverride ?? configuration.isNightMode
    }

    /// Updates safe-area insets `(top, right, bottom, left)` in logical DP.
    public func setSafeAreaInsets(_ insets: SIMD4<Float>) {
        guard !isDisposed else { return }
        configuration.safeAreaInsets = insets
        if runtime.setSafeAreaInsets(insets) {
            onRequestFrame?()
        }
    }

    /// Dispatches a touch, pointer, hover, or mouse-wheel scroll event from `RuneSurfaceView`.
    public func dispatchMotion(_ event: AndroidMotionEvent) {
        guard !isDisposed else { return }
        if !event.isMouse {
            if event.action == .down && activeFinger == nil {
                activeFinger = event.pointerId
            }
            if (event.action == .up || event.action == .cancel) && event.pointerId == activeFinger {
                activeFinger = nil
            }
        }
        AndroidMotionTranslator.dispatch(event, to: runtime, density: runtime.pixelScale, at: now())
    }

    /// Dispatches a hardware or editor-synthesized key event from `RuneSurfaceView`.
    @discardableResult
    public func dispatchKey(
        _ event: AndroidKeyEvent,
        composeDeadKey: (UInt32, UInt32) -> UInt32 = { _, _ in 0 }
    ) -> Bool {
        guard !isDisposed else { return false }
        let mods = event.mods
        let time = now()
        if mods != lastMods {
            lastMods = mods
            runtime.dispatchModifiers(mods, at: time)
        }
        let stroke = keyboard.translate(
            action: event.action.rawValue,
            code: event.keyCode,
            character: event.unicodeChar,
            compose: composeDeadKey
        )
        guard case .key(let key) = stroke else {
            return stroke == .consumed
        }
        let keyEvent = KeyEvent(key: key, mods: mods)
        return runtime.hostInput(.keyPress) {
            switch event.action {
            case .down:
                return runtime.keyDown(keyEvent, isRepeat: event.repeatCount > 0, at: now())
            case .up:
                return runtime.keyUp(keyEvent, at: now())
            }
        }
    }

    /// Cancels active fingers, pointer capture, held modifiers, and pending dead-key state.
    public func suspendInput() {
        keyboard = AndroidHardwareKeyboard()
        lastMods = .none
        if let id = activeFinger {
            runtime.touch(id: UInt64(UInt32(bitPattern: id)), phase: .cancelled, at: .zero, time: now())
            activeFinger = nil
        }
        runtime.cancelPointer(at: now())
    }

    /// Mutates the embedded Rune app state directly from host code and schedules a frame.
    public func update(_ body: (inout State, inout Tx) -> Void) {
        guard !isDisposed else { return }
        runtime.update(body)
        onRequestFrame?()
    }

    /// Runs or queries idle background text preparation turns.
    public func textIdleTurn(run: Bool) -> Bool {
        guard !isDisposed, !runtime.hasPendingCommit else { return false }
        return run ? runtime.textIdleTurn() : runtime.textIdleOwed
    }

    /// Evaluates one Choreographer frame and returns the next pacing disposition.
    ///
    /// Pass a custom `draw` closure on Android to submit via `PortableGLRenderer`; omit it on
    /// macOS/headless hosts to evaluate `runtime.frame(at:)` directly.
    @discardableResult
    public func stepFrame(
        width: Int32,
        height: Int32,
        density: Float,
        isDark: Bool,
        draw: ((Runtime<State>, Double) throws -> Void)? = nil
    ) throws -> AndroidFrameDisposition {
        guard !isDisposed, isSurfaceReady, isVisible, width > 0, height > 0 else {
            return .skipped
        }
        pixelWidth = width
        pixelHeight = height
        updateConfiguration(density: density, isNightMode: isDark)

        let time = now()
        _ = MainQueueDispatcher.shared.drain()
        let requests = appShared.applyStateUpdates(to: runtime, at: time)

        if let draw {
            try draw(runtime, time)
        } else {
            _ = runtime.frame(at: time)
        }
        presentedFrameCount &+= 1

        let closeRequested = requests.window == .close && runtime.dispatchClose(at: time)
        if closeRequested || requests.quit || requests.relaunch || runtime.quitRequested || runtime.relaunchRequested {
            onCloseRequested?()
            return .closeRequested
        }
        if runtime.isAnimating || compositor?.isAnimating == true || runtime.hasPendingCommit || runtime.poll != nil {
            return .continueAnimating
        }
        guard config.timeScale > 0, let next = runtime.nextWakeDeadline(after: time) else {
            return .idle
        }
        return .wakeAfter(max(0, (next - time) / config.timeScale))
    }

    /// Permanently tears down the embedded Rune runtime, GPU hook, and semantics hook. Idempotent.
    public func dispose(contextCurrent: Bool = false) {
        guard !isDisposed else { return }
        isDisposed = true
        lifecycleState = .disposed
        isSurfaceReady = false
        isAttachedToWindow = false
        isVisible = false
        hasWindowFocus = false
        suspendInput()
        onReleaseGPU?(contextCurrent)
        onRequestFrame = nil
        onDisposeHook?()
        onDisposeHook = nil
        runtime.dispatchQuit(at: now())
        runtime.cancelPreparedText()
        onCloseRequested = nil
        onReleaseGPU = nil
    }
}

/// Registry mapping `RuneSurfaceView` factory names to Swift view builders.
@MainActor
public final class AndroidSurfaceFactoryRegistry {
    public static let shared = AndroidSurfaceFactoryRegistry()

    private var factories: [String: @MainActor (UnsafeMutableRawPointer) throws -> Void] = [:]

    public init() {}

    public func register(
        named name: String,
        builder: @escaping @MainActor (UnsafeMutableRawPointer) throws -> Void
    ) {
        factories[name] = builder
    }

    public func unregister(named name: String) {
        factories.removeValue(forKey: name)
    }

    public func contains(_ name: String) -> Bool {
        factories[name] != nil
    }

    public var registeredNames: [String] {
        factories.keys.sorted()
    }

    @discardableResult
    public func instantiate(named name: String, surface: UnsafeMutableRawPointer) throws -> Bool {
        guard let builder = factories[name] else { return false }
        try builder(surface)
        return true
    }

    public func removeAll() {
        factories.removeAll()
    }
}

#if os(Android)
private enum AndroidHostError: Error, CustomStringConvertible {
    case missingActivity, attachFailed, surfaceAttachFailed, missingShader(String)
    var description: String {
        switch self {
        case .missingActivity: "Start Rune from ANativeActivity_onCreate using AndroidApp.attach(to:spec:)."
        case .attachFailed: "Could not attach Rune to this NativeActivity main looper (Android API 24+ required)."
        case .surfaceAttachFailed: "Could not attach Rune to this RuneSurfaceView host (Android API 24+ required)."
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
    AndroidKeyTranslator.modifiers(from: meta)
}

private func session(_ state: UnsafeMutableRawPointer?) -> AndroidSession {
    Unmanaged<AndroidSession>.fromOpaque(state!).takeUnretainedValue()
}

/// Type-erased Android UI-thread bridge connecting `RuneAndroidSurface` C callbacks to `AndroidSurfaceHost<State>`.
@MainActor
private final class AndroidSurfaceSession {
    let drawFrame: (Int32, Int32, Float, Bool) -> Double
    let textIdle: (Bool) -> Bool
    let pollGPU: (Bool) -> Bool
    let releaseGPU: (Bool) -> Void
    let surfaceChanged: (Int32, Int32) -> Void
    let surfaceDestroyed: () -> Void
    let configChanged: (Int32, Float, Bool) -> Void
    let safeArea: (Float, Float, Float, Float) -> Void
    let motion: (AndroidMotionEvent) -> Void
    let key: (AndroidKeyEvent) -> Bool
    let suspendInput: () -> Void
    let focus: (Bool) -> Void
    let visible: (Bool) -> Void
    let shutdown: () -> Void

    init<State>(surface: UnsafeMutableRawPointer, host: AndroidSurfaceHost<State>, app: App<State>) {
        let semanticsHandle = rune_android_surface_semantics_shim(surface)
        let semantics: AndroidSemanticBridge<State>? = semanticsHandle.map {
            AndroidSemanticBridge(activity: $0, runtime: host.runtime)
        }
        var renderer: PortableGLRenderer?
        var nativeKeyboardVisible = false

        host.onCloseRequested = {
            rune_android_surface_request_close(surface)
        }
        host.onReleaseGPU = { contextCurrent in
            if contextCurrent { renderer?.close() } else { renderer?.abandon() }
            renderer = nil
        }
        host.installDisposeHook {
            semantics?.close()
        }

        textIdle = { run in host.textIdleTurn(run: run) }
        pollGPU = { run in
            guard let renderer, renderer.needsSurfaceCompletionPoll else { return false }
            return run ? renderer.pollSurfaceCompletions() : true
        }
        releaseGPU = { contextCurrent in
            host.onReleaseGPU?(contextCurrent)
        }
        surfaceChanged = { width, height in
            host.surfaceChanged(width: width, height: height)
        }
        surfaceDestroyed = {
            host.surfaceDestroyed(contextCurrent: false)
        }
        configChanged = { dpi, density, dark in
            host.updateConfiguration(densityDPI: dpi, density: density, isNightMode: dark)
        }
        safeArea = { top, right, bottom, left in
            host.setSafeAreaInsets(SIMD4(top, right, bottom, left))
        }
        motion = { event in
            host.dispatchMotion(event)
        }
        key = { event in
            host.dispatchKey(event) { accent, char in
                rune_android_surface_compose_key(surface, accent, char)
            }
        }
        suspendInput = { host.suspendInput() }
        focus = { host.setWindowFocus($0) }
        visible = { host.setVisible($0) }
        shutdown = { host.dispose(contextCurrent: false) }

        drawFrame = { width, height, scale, dark in
            do {
                let disposition = try host.stepFrame(
                    width: width,
                    height: height,
                    density: scale,
                    isDark: dark
                ) { runtime, time in
                    if renderer == nil {
                        renderer = try PortableGLRenderer(
                            resolve: rune_android_resolve,
                            isGLES: true,
                            bundledShaderAssets: true
                        ) { name in
                            guard let bytes = rune_android_surface_read_shader(surface, name) else {
                                throw AndroidHostError.missingShader(name)
                            }
                            defer { rune_android_free_string(bytes) }
                            return String(cString: bytes)
                        }
                    }
                    guard let renderer else {
                        throw PortableGLRenderer.RenderError("Rune GLES renderer is unavailable")
                    }
                    let updateStart = ProcessInfo.processInfo.systemUptime
                    let frame = renderer.frame(runtime, at: time)
                    let updateMS = (ProcessInfo.processInfo.systemUptime - updateStart) * 1000
                    try renderer.draw(
                        frame,
                        compositor: app.compositorValue,
                        runtime: runtime,
                        at: time,
                        updateMilliseconds: updateMS
                    )
                    semantics?.refresh()
                    if semantics?.isAttached != true {
                        let wantsKeyboard = runtime.hasImeTarget || runtime.hasSecureFocus
                        if wantsKeyboard != nativeKeyboardVisible {
                            rune_android_surface_keyboard(surface, wantsKeyboard ? 1 : 0)
                            nativeKeyboardVisible = wantsKeyboard
                        }
                    }
                }
                return disposition.nativeDelaySeconds
            } catch {
                rune_android_log(String(describing: error))
                rune_android_surface_request_close(surface)
                return -.infinity
            }
        }
    }
}

private func surfaceSession(_ state: UnsafeMutableRawPointer?) -> AndroidSurfaceSession {
    Unmanaged<AndroidSurfaceSession>.fromOpaque(state!).takeUnretainedValue()
}

/// Hosts a Rune app in android.app.NativeActivity or an embeddable dev.rune.RuneSurfaceView.
public enum AndroidApp {
    @MainActor private static var attachingActivity: UnsafeMutableRawPointer?
    @MainActor private static var installedSurfaceFactoryResolver = false

    @MainActor
    private static func ensureSurfaceFactoryResolver() {
        guard !installedSurfaceFactoryResolver else { return }
        installedSurfaceFactoryResolver = true
        rune_android_surface_set_factory_resolver { surface, rawName in
            guard let surface, let rawName else { return 0 }
            let name = String(cString: rawName)
            return MainActor.assumeIsolated {
                do {
                    return try AndroidSurfaceFactoryRegistry.shared.instantiate(named: name, surface: surface) ? 1 : 0
                } catch {
                    rune_android_log("RuneSurfaceView factory '\(name)' failed: \(error)")
                    return 0
                }
            }
        }
    }

    /// Registers a named `AppSpec` factory for `RuneSurfaceView(context, factoryName)`.
    @MainActor
    public static func registerView<State>(
        named name: String,
        config: AndroidSurfaceConfig = AndroidSurfaceConfig(),
        make: @escaping @MainActor () -> AppSpec<State>
    ) {
        ensureSurfaceFactoryResolver()
        AndroidSurfaceFactoryRegistry.shared.register(named: name) { surface in
            _ = try attachView(to: surface, spec: make(), config: config)
        }
    }

    /// Registers a named `App` factory for `RuneSurfaceView(context, factoryName)`.
    @MainActor
    public static func registerView<State>(
        named name: String,
        config: AndroidSurfaceConfig = AndroidSurfaceConfig(),
        makeApp: @escaping @MainActor () -> App<State>
    ) {
        ensureSurfaceFactoryResolver()
        AndroidSurfaceFactoryRegistry.shared.register(named: name) { surface in
            _ = try attachView(to: surface, app: makeApp(), config: config)
        }
    }

    /// Unregisters a previously registered `RuneSurfaceView` factory name.
    @MainActor
    public static func unregisterView(named name: String) {
        AndroidSurfaceFactoryRegistry.shared.unregister(named: name)
    }

    /// Attaches an embeddable Rune `AppSpec` to a `RuneSurfaceView` native host handle
    /// (and optional `ANativeWindow` pointer).
    @MainActor
    @discardableResult
    public static func attachView<State>(
        to surfaceHost: UnsafeMutableRawPointer,
        surface: UnsafeMutableRawPointer? = nil,
        spec: AppSpec<State>,
        config: AndroidSurfaceConfig = AndroidSurfaceConfig()
    ) throws -> AndroidSurfaceHost<State> {
        var app = App(
            title: spec.title,
            size: spec.size,
            minSize: spec.minSize,
            dark: spec.dark,
            state: spec.makeState(),
            view: spec.view
        )
        app.scenes = spec.scenes
        app.fontData = spec.fonts
        app.fontFamilies = spec.families
        app.setupHook = spec.setup
        app.pollHook = spec.poll
        app.onKeyHook = spec.onKey
        app.srgbBlendEnabled = spec.srgbBlend
        return try attachView(to: surfaceHost, surface: surface, app: app, config: config) {
            $0.onAppFileDrop = spec.onFileDrop
            $0.onFileDrop = spec.onFileDropPhase
        }
    }

    /// Attaches an embeddable Rune `App` to a `RuneSurfaceView` native host handle
    /// (and optional `ANativeWindow` pointer).
    @MainActor
    @discardableResult
    public static func attachView<State>(
        to surfaceHost: UnsafeMutableRawPointer,
        surface: UnsafeMutableRawPointer? = nil,
        app: App<State>,
        config: AndroidSurfaceConfig = AndroidSurfaceConfig()
    ) throws -> AndroidSurfaceHost<State> {
        try attachView(to: surfaceHost, surface: surface, app: app, config: config) { _ in }
    }

    /// Creates a native host from custom JNI objects (`JNIEnv*`, `RuneSurfaceView`, `Context`,
    /// `AssetManager`, optional `android.view.Surface`) and attaches `spec`.
    @MainActor
    @discardableResult
    public static func attachView<State>(
        to jniEnv: UnsafeMutableRawPointer,
        view: UnsafeMutableRawPointer,
        context: UnsafeMutableRawPointer,
        assetManager: UnsafeMutableRawPointer,
        surface: UnsafeMutableRawPointer? = nil,
        spec: AppSpec<State>,
        config: AndroidSurfaceConfig = AndroidSurfaceConfig()
    ) throws -> AndroidSurfaceHost<State> {
        guard let hostHandle = rune_android_surface_create_from_jni(
            jniEnv, view, context, assetManager, surface
        ) else {
            throw AndroidHostError.surfaceAttachFailed
        }
        do {
            return try attachView(to: hostHandle, surface: nil, spec: spec, config: config)
        } catch {
            rune_android_surface_destroy(hostHandle)
            throw error
        }
    }

    /// Creates a native host from custom JNI objects (`JNIEnv*`, `RuneSurfaceView`, `Context`,
    /// `AssetManager`, optional `android.view.Surface`) and attaches `app`.
    @MainActor
    @discardableResult
    public static func attachView<State>(
        to jniEnv: UnsafeMutableRawPointer,
        view: UnsafeMutableRawPointer,
        context: UnsafeMutableRawPointer,
        assetManager: UnsafeMutableRawPointer,
        surface: UnsafeMutableRawPointer? = nil,
        app: App<State>,
        config: AndroidSurfaceConfig = AndroidSurfaceConfig()
    ) throws -> AndroidSurfaceHost<State> {
        guard let hostHandle = rune_android_surface_create_from_jni(
            jniEnv, view, context, assetManager, surface
        ) else {
            throw AndroidHostError.surfaceAttachFailed
        }
        do {
            return try attachView(to: hostHandle, surface: nil, app: app, config: config)
        } catch {
            rune_android_surface_destroy(hostHandle)
            throw error
        }
    }

    @MainActor
    private static func attachView<State>(
        to surfaceHost: UnsafeMutableRawPointer,
        surface nativeWindow: UnsafeMutableRawPointer?,
        app: App<State>,
        config: AndroidSurfaceConfig,
        configure: (Runtime<State>) -> Void
    ) throws -> AndroidSurfaceHost<State> {
        if let contextShim = rune_android_surface_context_shim(surfaceHost) {
            rune_image_android_attach(contextShim)
            rune_android_text_attach(contextShim)
        }
        let host = AndroidSurfaceHost(app: app, config: config, configure: configure)
        let bridge = AndroidSurfaceSession(surface: surfaceHost, host: host, app: app)
        let retained = Unmanaged.passRetained(bridge)

        var callbacks = RuneAndroidSurfaceCallbacks()
        callbacks.frame = { ptr, w, h, scale, dark in
            let bridge = surfaceSession(ptr)
            return MainActor.assumeIsolated { bridge.drawFrame(w, h, scale, dark != 0) }
        }
        callbacks.presented = { _ in }
        callbacks.text_idle = { ptr, run in
            let bridge = surfaceSession(ptr)
            return MainActor.assumeIsolated { bridge.textIdle(run != 0) ? 1 : 0 }
        }
        callbacks.poll_gpu = { ptr, run in
            let bridge = surfaceSession(ptr)
            return MainActor.assumeIsolated { bridge.pollGPU(run != 0) ? 1 : 0 }
        }
        callbacks.release_gpu = { ptr, current in
            let bridge = surfaceSession(ptr)
            MainActor.assumeIsolated { bridge.releaseGPU(current != 0) }
        }
        callbacks.focus = { ptr, active in
            let bridge = surfaceSession(ptr)
            MainActor.assumeIsolated { bridge.focus(active != 0) }
        }
        callbacks.visible = { ptr, active in
            let bridge = surfaceSession(ptr)
            MainActor.assumeIsolated { bridge.visible(active != 0) }
        }
        callbacks.surface_changed = { ptr, w, h in
            let bridge = surfaceSession(ptr)
            MainActor.assumeIsolated { bridge.surfaceChanged(w, h) }
        }
        callbacks.surface_destroyed = { ptr in
            let bridge = surfaceSession(ptr)
            MainActor.assumeIsolated { bridge.surfaceDestroyed() }
        }
        callbacks.config_changed = { ptr, dpi, density, dark in
            let bridge = surfaceSession(ptr)
            MainActor.assumeIsolated { bridge.configChanged(dpi, density, dark != 0) }
        }
        callbacks.safe_area = { ptr, top, right, bottom, left in
            let bridge = surfaceSession(ptr)
            MainActor.assumeIsolated { bridge.safeArea(top, right, bottom, left) }
        }
        callbacks.suspend_input = { ptr in
            let bridge = surfaceSession(ptr)
            MainActor.assumeIsolated { bridge.suspendInput() }
        }
        callbacks.destroy = { ptr in
            let bridge = Unmanaged<AndroidSurfaceSession>.fromOpaque(ptr!).takeRetainedValue()
            MainActor.assumeIsolated { bridge.shutdown() }
        }
        callbacks.motion = { ptr, m in
            guard let action = AndroidMotionAction(rawValue: m.action) else { return }
            let bridge = surfaceSession(ptr)
            let event = AndroidMotionEvent(
                action: action,
                pointerId: m.id,
                isMouse: m.mouse != 0,
                xPx: m.x,
                yPx: m.y,
                button: AndroidMotionTranslator.button(from: m.buttons),
                mods: AndroidKeyTranslator.modifiers(from: m.meta),
                hScroll: m.hscroll,
                vScroll: m.vscroll
            )
            MainActor.assumeIsolated { bridge.motion(event) }
        }
        callbacks.key = { ptr, action, code, meta, repeatCount, character in
            guard let keyAction = AndroidKeyEvent.Action(rawValue: action) else { return 0 }
            let bridge = surfaceSession(ptr)
            let event = AndroidKeyEvent(
                action: keyAction,
                keyCode: code,
                metaState: meta,
                repeatCount: repeatCount,
                unicodeChar: character
            )
            return MainActor.assumeIsolated { bridge.key(event) ? 1 : 0 }
        }

        let fd = rune_android_surface_attach(surfaceHost, nativeWindow, retained.toOpaque(), callbacks)
        guard fd >= 0 else {
            host.dispose(contextCurrent: false)
            retained.release()
            throw AndroidHostError.surfaceAttachFailed
        }
        let wake = AndroidWake(fd)
        host.onRequestFrame = { rune_android_wake(wake.fd) }
        return host
    }

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
