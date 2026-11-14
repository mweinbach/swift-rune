import Foundation
import RuneMotion
import RuneRef

#if os(Linux)
import Glibc
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

#if os(Linux)
/// Linux Wayland/X11 shared-memory framebuffer host called by `RuneApp.run(spec)`.
public enum LinuxApp {
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
            pixelScale: 1.0,
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

        // Create POSIX shm framebuffer for compositor/display bridge and render initial frame.
        let shmName = "/rune-fb-\(ReadySignal.currentPID)"
        let w = max(1, Int(vp.x))
        let h = max(1, Int(vp.y))
        let byteCount = w * h * 4
        let fd = shm_open(shmName, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 {
            _ = ftruncate(fd, off_t(byteCount))
            if let mapped = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
               mapped != MAP_FAILED {
                let scene = runtime.frame(at: 0.0)
                if let frame = try? RuneRef.render(scene) {
                    let copyCount = min(byteCount, frame.rgba.count)
                    frame.rgba.withUnsafeBytes { raw in
                        if let base = raw.baseAddress {
                            memcpy(mapped, base, copyCount)
                        }
                    }
                }
                ReadySignal.ready()
                munmap(mapped, byteCount)
            }
            close(fd)
            shm_unlink(shmName)
        } else {
            _ = runtime.frame(at: 0.0)
            ReadySignal.ready()
        }
    }
}
#endif
