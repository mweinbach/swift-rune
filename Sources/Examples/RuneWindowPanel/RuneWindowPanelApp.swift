import Foundation
import Rune
import RuneMotion
import RuneRef

/// Port of upstream `crates/rune/examples/window-panel.rs`.
@main
public enum RuneWindowPanelApp {
    public struct MainState: Sendable {
        public var openCount: Int = 0
        public var panelClosedCount: Int = 0
        public init() {}
    }

    public struct PanelState: Sendable {
        public var textValue: String = "Spotlight-style panel"
        public var escaped: Bool = false
        public var blurred: Bool = false
        public init() {}
    }

    public struct Report: Sendable {
        public let windowKeys: [String]
        public let panelEscaped: Bool
        public let panelBlurred: Bool
        public let mainFrames: Int
        public let output: String
    }

    public static func makeWindows() -> [AnyWindowSpec] {
        let panelHandle = WindowHandle(key: "panel")
        let mainApp = App(title: "main", state: MainState()) { s, _ in
            col()
                .wFull()
                .hFull()
                .p(24)
                .gap(12)
                .itemsCenter()
                .justifyCenter()
                .bg(Color.rgba8(0x0d, 0x0f, 0x14))
                .child(text("Window Panel Probe").font(TextStyle(size: 16, weight: 600)).color(.white))
                .child(text("opened=\(s.openCount)").font(TextStyle(size: 12, weight: 400)).color(Color.white.alpha(0.65)))
                .child(
                    text("Open Panel")
                        .font(TextStyle(size: 13, weight: 600))
                        .color(.white)
                        .p(10)
                        .rounded(8)
                        .bg(oklch(0.58, 0.16, 250))
                        .onClick { st in
                            st.openCount += 1
                            panelHandle.show()
                            panelHandle.focus()
                        }
                )
        }
        .size(480, 320)

        let panelApp = App(title: "panel", state: PanelState()) { s, _ in
            col()
                .wFull()
                .hFull()
                .p(16)
                .gap(8)
                .rounded(14)
                .bg(Color.rgba8(0x16, 0x19, 0x22))
                .border(1, Color.white.alpha(0.14))
                .child(text(s.textValue).font(TextStyle(size: 14, weight: 600)).color(.white))
                .child(text("Press Esc or blur to close").font(TextStyle(size: 12, weight: 400)).color(Color.white.alpha(0.6)))
        }
        .size(420, 180)
        .windowOptions(WindowOptions(alwaysOnTop: true, borderless: true, visible: true))
        .macosWindow(MacWindowOptions().nonactivatingPanel(true))
        .onKey { s, ev, _ in
            if ev.key == .escape {
                s.escaped = true
                panelHandle.hide()
                return true
            }
            return false
        }
        .onFocus { s, focused, _ in
            if !focused {
                s.blurred = true
                panelHandle.hide()
            }
        }

        let mainSpec = AnyWindowSpec(AppWindowSpec.fromApp(mainApp))
        let panelSpec = AnyWindowSpec(AppWindowSpec.fromApp(panelApp), handle: panelHandle, secondary: true)
        return [mainSpec, panelSpec]
    }

    public static func runHeadlessVerify() throws -> Report {
        let windows = makeWindows()
        let flat = RuneMultiWindow.flatten(windows)
        try RuneMultiWindow.validate(flat)
        let keys = flat.map(\.key)

        let headlessOut = try RuneMultiWindow.runHeadless(windows, args: ToolingArgs())

        // Also test Escape + blur behavior directly on panel Runtime
        var escaped = false
        var blurred = false
        let panelHandle = WindowHandle(key: "panel")
        let panelRt = App(title: "panel", state: PanelState()) { s, _ in
            el().wFull().hFull().bg(.black).child(text(s.textValue))
        }
        .onKey { s, ev, _ in
            if ev.key == .escape {
                s.escaped = true
                panelHandle.hide()
                return true
            }
            return false
        }
        .onFocus { s, focused, _ in
            if !focused {
                s.blurred = true
                panelHandle.hide()
            }
        }
        .makeRuntime(viewport: Vec2(420, 180), pixelScale: 2.0, systemDark: true)

        _ = panelRt.frame(at: 0.0)
        _ = panelRt.keyDown(KeyEvent(key: .escape, mods: .none), at: 0.01)
        escaped = panelRt.state.escaped
        panelRt.dispatchFocus(false, at: 0.02)
        blurred = panelRt.state.blurred

        let out = "window_panel keys=\(keys.joined(separator: ",")) escaped=\(escaped) blurred=\(blurred) w=\(headlessOut.finalFrame.width)"
        return Report(
            windowKeys: keys,
            panelEscaped: escaped,
            panelBlurred: blurred,
            mainFrames: headlessOut.finalFrame.width > 0 ? 1 : 0,
            output: out
        )
    }

    @MainActor
    public static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--verify") || args.contains("--headless") {
            print(try runHeadlessVerify().output)
            return
        }
        try RuneMultiWindow.runWindows(makeWindows())
    }
}
