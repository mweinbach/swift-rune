import Foundation
import Rune
import RuneKit
#if os(macOS)
import AppKit
#endif

public final class SharedWindowHandles: @unchecked Sendable {
    private let lock = NSLock()
    private var handles: [WindowHandle] = []

    public init() {}

    public func append(_ handle: WindowHandle) {
        lock.lock()
        handles.append(handle)
        lock.unlock()
    }

    public func snapshot() -> [WindowHandle] {
        lock.lock()
        defer { lock.unlock() }
        return handles
    }
}

public struct ControlsState: Sendable {
    public var clickThrough: Bool = true
    public var overlayHandles: SharedWindowHandles

    public init(clickThrough: Bool = true, overlayHandles: SharedWindowHandles = SharedWindowHandles()) {
        self.clickThrough = clickThrough
        self.overlayHandles = overlayHandles
    }
}

public struct OverlayCanvasState: Sendable {
    public var index: Int
    public var bounds: Vec2
    public var cursor: Live<Vec2>
    public var overlayHandles: SharedWindowHandles
    public var restoredClickThroughCount: Int = 0
    public var phase: Double = 0.0

    public init(
        index: Int,
        bounds: Vec2,
        cursor: Live<Vec2>,
        overlayHandles: SharedWindowHandles = SharedWindowHandles()
    ) {
        self.index = index
        self.bounds = bounds
        self.cursor = cursor
        self.overlayHandles = overlayHandles
    }
}

@main
public enum RuneOverlayApp {
    public static let strokeIcon = SVGIcon(
        viewBox: 240.0,
        paths: [],
        strokeWidth: nil,
        body: #"<path d="M 12 190 C 55 30 90 210 130 70 S 190 170 228 35" fill="none" stroke="currentColor" stroke-width="4" stroke-linecap="round"/>"#
    )

    public static func currentDisplays() -> [DisplayInfo] {
        #if os(macOS)
        let screens = NSScreen.screens
        if !screens.isEmpty {
            let mainHeight = screens[0].frame.height
            return screens.enumerated().map { idx, screen in
                let f = screen.frame
                let displayId = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? UInt32(idx + 1)
                let topLeftY = Int32((mainHeight - f.maxY).rounded())
                return DisplayInfo(
                    id: RuneDisplayId(native: .macOS(displayId)),
                    name: screen.localizedName,
                    position: (Int32(f.origin.x.rounded()), topLeftY),
                    size: (UInt32(max(1, f.width.rounded())), UInt32(max(1, f.height.rounded()))),
                    scale: Double(screen.backingScaleFactor),
                    primary: idx == 0
                )
            }
        }
        #endif
        return [DisplayInfo()]
    }

    public static func cursorPoint(forPhase t: Double, bounds: Vec2, index: Int) -> Vec2 {
        let clamped = min(t, 4.0)
        let shift = Double(index) * 0.5
        let x = Float(120.0 + 120.0 * sin(clamped * 0.7 + shift))
        let y = Float(90.0 + 50.0 * sin(clamped + shift))
        return Vec2(
            min(max(0, x), max(12, bounds.x - 12)),
            min(max(0, y), max(18, bounds.y - 18))
        )
    }

    public static func controlsView(_ s: ControlsState, _ cx: inout Cx<ControlsState>) -> El<ControlsState> {
        let green = Color(r: 0.1, g: 0.85, b: 0.45, a: 1.0)
        let heading: El<ControlsState> = text("Display overlays").font(Tok.Typography.body)
        let testBtn: El<ControlsState> = row()
            .key("test-overlay-input")
            .role(.button)
            .label("Test overlay input")
            .p(16)
            .rounded(8)
            .bg(green.alpha(0.15))
            .onClick { state in
                state.clickThrough = false
                for handle in state.overlayHandles.snapshot() {
                    do {
                        try handle.setClickThrough(false)
                    } catch {
                        fputs("click-through: \(error)\n", stderr)
                    }
                }
            }
            .child(text("Test overlay input").color(.white))

        return col()
            .sizeFull()
            .p(40)
            .gap(20)
            .bg(Color(r: 0.018, g: 0.024, b: 0.03, a: 1.0))
            .child(heading)
            .child(testBtn)
    }

    public static func overlayView(_ s: OverlayCanvasState, _ cx: inout Cx<OverlayCanvasState>) -> El<OverlayCanvasState> {
        let green = Color(r: 0.1, g: 0.85, b: 0.45, a: 1.0)
        let strokeEl: El<OverlayCanvasState> = icon(strokeIcon, size: 240.0)
            .key("stroke")
            .color(green)
            .pin(top: 80, left: 80)
        let cursorEl: El<OverlayCanvasState> = el()
            .key("remote-cursor")
            .w(12)
            .h(18)
            .rounded(3)
            .bg(green)
            .pin(top: 0, left: 0)
            .liveOffset(s.cursor.binding)

        return el()
            .sizeFull()
            .bg(.transparent)
            .child(strokeEl)
            .child(cursorEl)
            .onClick { state in
                state.restoredClickThroughCount += 1
                for handle in state.overlayHandles.snapshot() {
                    try? handle.setClickThrough(true)
                }
            }
    }

    public static func makeWindows(
        displays: [DisplayInfo] = currentDisplays(),
        arguments: [String] = Array(CommandLine.arguments.dropFirst())
    ) -> [AnyWindowSpec] {
        let resolvedDisplays = displays.isEmpty ? [DisplayInfo()] : displays
        let isHeadless = ToolingArgs.parse(arguments).isHeadlessRequested || arguments.contains("--headless")
        let overlayHandles = SharedWindowHandles()

        let controlsSpec = AppSpec<ControlsState>(
            title: "Rooms overlay example",
            size: Vec2(560, 440),
            dark: true,
            state: ControlsState(clickThrough: true, overlayHandles: overlayHandles),
            view: controlsView
        )
        let controlsWindow = AppWindowSpec(key: "controls", app: controlsSpec).boxed()

        var windows: [AnyWindowSpec] = [controlsWindow]
        for (idx, display) in resolvedDisplays.enumerated() {
            let bounds = Vec2(Float(max(1, display.size.0)), Float(max(1, display.size.1)))
            let initialPos = cursorPoint(forPhase: 0.0, bounds: bounds, index: idx)
            let cursor = Live<Vec2>(initialPos)

            let overlaySpec = AppSpec<OverlayCanvasState>(
                title: "Overlay \(idx)",
                size: bounds,
                dark: true,
                state: OverlayCanvasState(
                    index: idx,
                    bounds: bounds,
                    cursor: cursor,
                    overlayHandles: overlayHandles
                ),
                setup: { _ in
                    guard !isHeadless else { return }
                    let thread = Thread {
                        let start = Date()
                        for tick in 1...480 {
                            let targetT = Double(tick) / 120.0
                            let remaining = targetT - Date().timeIntervalSince(start)
                            if remaining > 0 {
                                Thread.sleep(forTimeInterval: remaining)
                            }
                            cursor.set(cursorPoint(forPhase: targetT, bounds: bounds, index: idx))
                        }
                    }
                    thread.name = "overlay-cursor-\(idx)"
                    thread.start()
                },
                poll: { state, dt, tx in
                    guard isHeadless else { return false }
                    state.phase += max(0.0, dt)
                    let next = cursorPoint(forPhase: state.phase, bounds: state.bounds, index: state.index)
                    let changed = next != state.cursor.get()
                    state.cursor.set(next)
                    tx.wakeAfter(1.0 / 60.0)
                    return changed
                },
                view: overlayView
            )
            let overlayWindow = AppWindowSpec(key: "overlay-\(idx)", app: overlaySpec)
                .options(WindowOptions.overlay(display: display))
                .onCreated { handle in
                    overlayHandles.append(handle)
                    fputs(
                        "overlay native window number: \(String(describing: handle.windowNumber))\n",
                        stderr
                    )
                }
                .boxed()
            windows.append(overlayWindow)
        }
        return windows
    }

    @MainActor
    public static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        try RuneMultiWindow.runWindows(makeWindows(arguments: args), arguments: args)
    }
}
