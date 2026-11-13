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
    public var phase: Double = 0.0

    public init(index: Int, bounds: Vec2, cursor: Live<Vec2>) {
        self.index = index
        self.bounds = bounds
        self.cursor = cursor
    }
}

@main
public enum RuneOverlayApp {
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
        let cx = max(80.0, Double(bounds.x) * 0.5)
        let cy = max(80.0, Double(bounds.y) * 0.5)
        let rx = max(40.0, Double(bounds.x) * 0.25)
        let ry = max(40.0, Double(bounds.y) * 0.22)
        let shift = Double(index) * 0.7
        let x = Float(cx + cos(t * 2.2 + shift) * rx - 14.0)
        let y = Float(cy + sin(t * 3.1 + shift) * ry - 14.0)
        return Vec2(x, y)
    }

    public static func controlsView(_ s: ControlsState, _ cx: inout Cx<ControlsState>) -> El<ControlsState> {
        let t = Tok.theme(dark: true)
        let modeText = s.clickThrough ? "Click-through: ON" : "Click-through: OFF"
        let buttonText = s.clickThrough ? "Make interactive" : "Make click-through"
        return col()
            .sizeFull()
            .p(16)
            .gap(12)
            .bg(t.bg)
            .child(
                row()
                    .wFull()
                    .itemsCenter()
                    .justifyBetween()
                    .child(text("Overlay Controls").font(Tok.Typography.title).color(t.text))
                    .child(text(modeText).font(Tok.Typography.monoCaption).color(t.textSecondary))
            )
            .child(
                row()
                    .key("toggle-click-through")
                    .role(.button)
                    .label(buttonText)
                    .h(36)
                    .px(14)
                    .center()
                    .rounded(8)
                    .bg(s.clickThrough ? t.card : Tok.accent(0, dark: true))
                    .border(1, t.cardBorder)
                    .onClick { state in
                        state.clickThrough.toggle()
                        let next = state.clickThrough
                        for handle in state.overlayHandles.snapshot() {
                            try? handle.setClickThrough(next)
                        }
                    }
                    .child(text(buttonText).font(Tok.Typography.label).color(.white))
            )
    }

    public static func overlayView(_ s: OverlayCanvasState, _ cx: inout Cx<OverlayCanvasState>) -> El<OverlayCanvasState> {
        let label = "Overlay \(s.index) (\(Int(s.bounds.x))x\(Int(s.bounds.y)))"
        return el()
            .sizeFull()
            .bg(.transparent)
            .child(
                row()
                    .pin(top: 24, left: 24)
                    .h(30)
                    .px(12)
                    .center()
                    .rounded(999)
                    .bg(Color.srgb(0.07, 0.09, 0.12, 0.78))
                    .border(1, Color.white.alpha(0.16))
                    .child(text(label).size(12).color(.white))
            )
            .child(
                el()
                    .key("cursor-\(s.index)")
                    .w(28)
                    .h(28)
                    .rounded(14)
                    .bg(Tok.accent(0, dark: true).alpha(0.88))
                    .border(2, .white)
                    .liveOffset(s.cursor.binding)
            )
    }

    public static func makeWindows(
        displays: [DisplayInfo] = currentDisplays(),
        arguments: [String] = Array(CommandLine.arguments.dropFirst())
    ) -> [AnyWindowSpec] {
        let resolvedDisplays = displays.isEmpty ? [DisplayInfo()] : displays
        let isHeadless = ToolingArgs.parse(arguments).isHeadlessRequested
        let overlayHandles = SharedWindowHandles()

        let controlsSpec = AppSpec<ControlsState>(
            title: "Overlay Controls",
            size: Vec2(320, 130),
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
                state: OverlayCanvasState(index: idx, bounds: bounds, cursor: cursor),
                setup: { _ in
                    guard !isHeadless else { return }
                    let thread = Thread {
                        let start = Date()
                        while !Thread.current.isCancelled {
                            Thread.sleep(forTimeInterval: 1.0 / 120.0)
                            let t = Date().timeIntervalSince(start)
                            cursor.set(cursorPoint(forPhase: t, bounds: bounds, index: idx))
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
                        "overlay-\(idx) created (windowNumber: \(String(describing: handle.windowNumber)))\n",
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
