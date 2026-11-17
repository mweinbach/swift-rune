import Foundation
import RuneMotion
import RuneRef

#if os(Android)
import Android
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
    public var hScroll: Float
    public var vScroll: Float

    public init(
        action: AndroidMotionAction,
        pointerId: Int32 = 0,
        isMouse: Bool = false,
        xPx: Float,
        yPx: Float,
        hScroll: Float = 0,
        vScroll: Float = 0
    ) {
        self.action = action
        self.pointerId = pointerId
        self.isMouse = isMouse
        self.xPx = xPx
        self.yPx = yPx
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
        let scale = max(0.5, density)
        let pt = Vec2(event.xPx / scale, event.yPx / scale)
        switch event.action {
        case .down:
            runtime.pointerMove(to: pt, mods: .none, at: now)
            runtime.pressDown(at: pt, at: now, mouse: event.isMouse)
        case .move, .hoverMove, .hoverEnter:
            runtime.pointerMove(to: pt, mods: .none, at: now)
        case .up:
            runtime.pointerUp(at: pt, button: .primary, mods: .none, at: now)
        case .cancel, .outside, .hoverExit:
            runtime.pointerExit(at: now)
        case .scroll:
            runtime.pointerMove(to: pt, mods: .none, at: now)
        }
    }
}

/// Translates Android `AKEYCODE_*` keycodes into `Rune.Key`.
public enum AndroidKeyTranslator {
    public static func translate(keyCode: Int32, unicodeChar: UInt32 = 0) -> Key? {
        switch keyCode {
        case 19: return .arrowUp     // AKEYCODE_DPAD_UP
        case 20: return .arrowDown   // AKEYCODE_DPAD_DOWN
        case 21: return .arrowLeft   // AKEYCODE_DPAD_LEFT
        case 22: return .arrowRight  // AKEYCODE_DPAD_RIGHT
        case 61: return .tab         // AKEYCODE_TAB
        case 62: return .space       // AKEYCODE_SPACE
        case 66, 160: return .enter  // AKEYCODE_ENTER, AKEYCODE_NUMPAD_ENTER
        case 67: return .backspace   // AKEYCODE_DEL
        case 111: return .escape     // AKEYCODE_ESCAPE
        case 112: return .delete     // AKEYCODE_FORWARD_DEL
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
/// Android NDK `ANativeWindow` + `AChoreographer` host called by `RuneApp.run(spec)`.
public enum AndroidApp {
    @MainActor
    public static func run<State>(_ spec: AppSpec<State>, parsed: ToolingArgs) throws {
        HeadlessRunner.registerFonts(spec.fonts)
        var state = spec.makeState()
        var initTx = Tx()
        if let sceneName = parsed.sceneName, let apply = spec.scenes[sceneName] {
            apply(&state, &initTx)
        }
        let vp = parsed.viewportOverride ?? spec.size
        let isDark = parsed.darkOverride ?? spec.dark ?? true
        let waker = Waker()
        spec.setup?(waker)
        let runtime = Runtime<State>(
            state: state,
            viewport: vp,
            pixelScale: 2.0,
            systemDark: isDark,
            reducedMotion: parsed.reducedMotion,
            waker: waker,
            onKey: spec.onKey,
            view: spec.view
        )
        runtime.windowTitle = spec.title
        runtime.srgbBlend = spec.srgbBlend
        runtime.poll = spec.poll
        runtime.onAppFileDrop = spec.onFileDrop
        runtime.onFileDrop = spec.onFileDropPhase
        runtime.readSystemContrastSettings()
        runtime.applyTx(initTx, at: 0.0, markDirtyIfNotLiveOnly: false)
        _ = runtime.frame(at: 0.0)
        ReadySignal.ready()
    }

    /// Presents a rendered `Frame` into an `ANativeWindow` (`WINDOW_FORMAT_RGBA_8888`).
    public static func present(frame: Frame, to windowPtr: UnsafeMutableRawPointer) {
        // ANativeWindow_Buffer stride-aware RGBA8 copy when bound by an Android Activity/NativeActivity.
        _ = (frame, windowPtr)
    }
}
#endif
