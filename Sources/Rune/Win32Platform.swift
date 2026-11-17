import Foundation
import RuneMotion
import RuneRef

#if os(Windows)
import WinSDK
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
        at now: Double
    ) -> Bool {
        switch msg {
        case .size(let w, let h):
            let scale = Win32DpiScale.scaleFactor(forDPI: dpi)
            runtime.pixelScale = scale
            runtime.viewport = Vec2(Float(w) / scale, Float(h) / scale)
            return true
        case .dpiChanged(let newDPI, let w, let h):
            dpi = newDPI
            let scale = Win32DpiScale.scaleFactor(forDPI: dpi)
            runtime.pixelScale = scale
            runtime.viewport = Vec2(Float(w) / scale, Float(h) / scale)
            return true
        case .mouseMove(let x, let y):
            let scale = Win32DpiScale.scaleFactor(forDPI: dpi)
            runtime.pointerMove(to: Vec2(x / scale, y / scale), mods: .none, at: now)
            return true
        case .mouseDown(let btn, let x, let y):
            let scale = Win32DpiScale.scaleFactor(forDPI: dpi)
            runtime.pointerDown(at: Vec2(x / scale, y / scale), button: btn, mods: .none, at: now)
            return true
        case .mouseUp(let btn, let x, let y):
            let scale = Win32DpiScale.scaleFactor(forDPI: dpi)
            runtime.pointerUp(at: Vec2(x / scale, y / scale), button: btn, mods: .none, at: now)
            return true
        case .mouseLeave:
            runtime.pointerExit(at: now)
            return true
        case .keyDown(let vk, let mods):
            if let key = Win32KeyMap.translate(virtualKey: vk, shift: mods.shift) {
                return runtime.keyDown(KeyEvent(key: key, mods: mods), at: now)
            }
            return false
        case .char(let scalar):
            let str = String(scalar)
            return runtime.keyDown(KeyEvent(key: .text(str), mods: .none), at: now)
        case .close:
            return false
        }
    }
}

#if os(Windows)
/// Win32 native host (`RegisterClassExW`, `CreateWindowExW`, `StretchDIBits` DIB presenter,
/// `DwmSetWindowAttribute` dark titlebar/backdrop).
public enum Win32App {
    @MainActor
    public static func run<State>(_ spec: AppSpec<State>, parsed: ToolingArgs, openInactive: Bool = false) throws {
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

        let hInstance = GetModuleHandleW(nil)
        let className = Array("RuneWin32WindowClass".utf16) + [0]
        let titleUTF16 = Array(spec.title.utf16) + [0]

        var wc = WNDCLASSEXW()
        wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        wc.style = UINT(CS_HREDRAW | CS_VREDRAW)
        wc.lpfnWndProc = DefWindowProcW
        wc.hInstance = hInstance
        wc.hCursor = LoadCursorW(nil, IDC_ARROW)
        className.withUnsafeBufferPointer { ptr in
            wc.lpszClassName = ptr.baseAddress
            RegisterClassExW(&wc)
        }

        let hwnd: HWND? = className.withUnsafeBufferPointer { clsPtr in
            titleUTF16.withUnsafeBufferPointer { ttlPtr in
                CreateWindowExW(
                    0,
                    clsPtr.baseAddress,
                    ttlPtr.baseAddress,
                    DWORD(WS_OVERLAPPEDWINDOW),
                    CW_USEDEFAULT,
                    CW_USEDEFAULT,
                    Int32(vp.x),
                    Int32(vp.y),
                    nil,
                    nil,
                    hInstance,
                    nil
                )
            }
        }
        guard let hwnd else { return }

        var darkVal: BOOL = isDark ? 1 : 0
        let DWMWA_USE_IMMERSIVE_DARK_MODE: DWORD = 20
        DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &darkVal, DWORD(MemoryLayout<BOOL>.size))

        // `App::open_inactive` or `RUNE_OPEN_INACTIVE` (a tool's launch): shown without taking
        // activation or the user's keyboard (#962).
        ShowWindow(hwnd, OpenInactiveLaunch.win32ShowCommand(openInactive: OpenInactiveLaunch.openInactive(app: openInactive)))
        UpdateWindow(hwnd)
        ReadySignal.ready()

        var msg = MSG()
        var running = true
        while running {
            while PeekMessageW(&msg, nil, 0, 0, UINT(PM_REMOVE)) {
                if msg.message == UINT(WM_QUIT) {
                    running = false
                    break
                }
                TranslateMessage(&msg)
                DispatchMessageW(&msg)
            }
            if !running { break }

            _ = MainQueueDispatcher.shared.drain()
            let scene = runtime.frame(at: Date().timeIntervalSince1970)
            if let frame = try? RuneRef.render(scene) {
                presentDIB(hwnd: hwnd, frame: frame)
            }
            Sleep(16)
        }
    }

    private static func presentDIB(hwnd: HWND, frame: Frame) {
        let hdc = GetDC(hwnd)
        defer { ReleaseDC(hwnd, hdc) }
        var bmi = BITMAPINFO()
        bmi.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        bmi.bmiHeader.biWidth = Int32(frame.width)
        bmi.bmiHeader.biHeight = -Int32(frame.height)
        bmi.bmiHeader.biPlanes = 1
        bmi.bmiHeader.biBitCount = 32
        bmi.bmiHeader.biCompression = DWORD(BI_RGB)

        // Convert RGBA -> BGRA for GDI StretchDIBits.
        var bgra = [UInt8](repeating: 0, count: frame.rgba.count)
        for i in stride(from: 0, to: frame.rgba.count, by: 4) {
            bgra[i + 0] = frame.rgba[i + 2]
            bgra[i + 1] = frame.rgba[i + 1]
            bgra[i + 2] = frame.rgba[i + 0]
            bgra[i + 3] = frame.rgba[i + 3]
        }
        bgra.withUnsafeBytes { raw in
            StretchDIBits(
                hdc,
                0, 0, Int32(frame.width), Int32(frame.height),
                0, 0, Int32(frame.width), Int32(frame.height),
                raw.baseAddress,
                &bmi,
                UINT(DIB_RGB_COLORS),
                DWORD(SRCCOPY)
            )
        }
    }
}
#endif
