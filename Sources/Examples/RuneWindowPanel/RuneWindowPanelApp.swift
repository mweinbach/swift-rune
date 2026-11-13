import Foundation
import Rune
#if canImport(Darwin)
import Darwin
#endif
#if os(macOS)
import AppKit
#endif

/// Multi-window + non-activating quick panel + Unix control socket probe
/// mirroring `crates/rune/examples/window-panel.rs`.
///
/// NOTE: `Sources/Rune` `WindowHandle` exposes `windowNumber` rather than `withRawHandle`,
/// `AppWindowSpec.init(app:)` does not propagate `app.isWindowless` to `options.visible = false`,
/// and `RuneHostedMetalView.requestRender()` does not observe `runtime.closeWindowRequested`.
/// This port configures explicit `WindowOptions(visible: false)` / `WindowOptions.launcherPanel()`,
/// binds `"quick"` + `"main"` `WindowHandle`s, runs the `WINDOW_PANEL_SOCKET` control server,
/// and inspects the live `NSWindow` via `NSApplication.shared.window(withWindowNumber:)`.
@main
public enum RuneWindowPanelApp {
    public struct MainState: Sendable {
        public var status: String = "host ready"
        public init() {}
    }

    public struct QuickState: Sendable {
        public var escaped: Bool = false
        public var blurred: Bool = false
        public var query: String = ""
        public init() {}
    }

    public struct Report: Sendable {
        public let windowKeys: [String]
        public let panelEscaped: Bool
        public let panelBlurred: Bool
        public let mainFrames: Int
    }

    public final class ProbeHandles: @unchecked Sendable {
        private let lock = NSLock()
        var mainHandle: WindowHandle?
        var quickHandle: WindowHandle?
        var mainAppHandle: AppHandle<MainState>?
        var quickAppHandle: AppHandle<QuickState>?
        var mainCreated = false
        var mainReady = false
        var quickCreated = false
        var quickReady = false

        func setMain(_ h: WindowHandle) { lock.withLock { mainHandle = h } }
        func setQuick(_ h: WindowHandle) { lock.withLock { quickHandle = h } }
        func markMainCreated() { lock.withLock { mainCreated = true } }
        func markMainReady() { lock.withLock { mainReady = true } }
        func markQuickCreated() { lock.withLock { quickCreated = true } }
        func markQuickReady() { lock.withLock { quickReady = true } }
    }

    public static func makeQuickApp(
        title: String = "quick",
        handles: ProbeHandles? = nil
    ) -> App<QuickState> {
        var app = App<QuickState>(
            title,
            size: Vec2(480, 110),
            init: { QuickState() },
            view: { s, _ in
                col()
                    .wFull()
                    .hFull()
                    .rounded(14)
                    .bg(Color(r: 0.10, g: 0.11, b: 0.15, a: 0.94))
                    .border(1, Color(r: 1, g: 1, b: 1, a: 0.14))
                    .p(16)
                    .gap(8)
                    .children([
                        text("Quick Panel")
                            .font(Tok.Typography.title)
                            .color(Color(r: 0.95, g: 0.96, b: 0.99, a: 1.0)),
                        text(s.escaped ? "dismissed:escape" : (s.blurred ? "dismissed:blur" : "Press Esc or click away"))
                            .font(Tok.Typography.label)
                            .color(Color(r: 0.72, g: 0.76, b: 0.84, a: 1.0)),
                    ])
            }
        )
        .args([])
        .windowless(true)
        .onKey { s, ev, tx in
            if ev.key == .escape {
                s.escaped = true
                tx.closeWindow()
                handles?.quickHandle?.hide()
                return true
            }
            return false
        }
        .onFocus { s, focused, tx in
            if !focused {
                s.blurred = true
                tx.closeWindow()
                handles?.quickHandle?.hide()
            }
        }
        let launcher = ProcessInfo.processInfo.environment["WINDOW_PANEL_LAUNCHER"] == "1"
        if launcher {
            app = app.configuredOptions(WindowOptions.launcherPanel())
        } else {
            app = app.configuredOptions(
                WindowOptions(
                    minSize: Vec2(0, 0),
                    resizable: false,
                    transparent: true,
                    borderless: true,
                    visible: false
                ).macos(MacWindowOptions().nonactivatingPanel(true))
            )
        }
        return app
    }

    public static func makeMainApp() -> App<MainState> {
        App<MainState>(
            "main",
            size: Vec2(320, 160),
            init: { MainState() },
            view: { s, _ in
                col()
                    .wFull()
                    .hFull()
                    .bg(Color(r: 0.08, g: 0.09, b: 0.12, a: 1.0))
                    .center()
                    .gap(6)
                    .children([
                        text("Window Panel Host")
                            .font(Tok.Typography.title)
                            .color(Color(r: 0.94, g: 0.95, b: 0.98, a: 1.0)),
                        text(s.status)
                            .font(Tok.Typography.label)
                            .color(Color(r: 0.66, g: 0.70, b: 0.78, a: 1.0)),
                    ])
            }
        )
        .keepRunning(true)
    }

    @MainActor
    public static func main() throws {
        let handles = ProbeHandles()
        let mainApp = makeMainApp()
        let quickApp = makeQuickApp(handles: handles)
        handles.mainAppHandle = mainApp.handle()
        handles.quickAppHandle = quickApp.handle()

        let mainSpec = AppWindowSpec.fromApp(mainApp)
            .onCreated { h in
                handles.setMain(h)
                handles.markMainCreated()
            }
            .onReady { h in
                handles.setMain(h)
                handles.markMainReady()
            }

        let launcher = ProcessInfo.processInfo.environment["WINDOW_PANEL_LAUNCHER"] == "1"
        let quickConfigured = launcher
            ? WindowOptions.launcherPanel()
            : WindowOptions(
                minSize: Vec2(0, 0),
                resizable: false,
                transparent: true,
                borderless: true,
                visible: false
            ).macos(MacWindowOptions().nonactivatingPanel(true))

        let quickSpec = AppWindowSpec.fromApp(quickApp)
            .args([])
            .configuredOptions(quickConfigured)
            .onCreated { h in
                handles.setQuick(h)
                handles.markQuickCreated()
            }
            .onReady { h in
                handles.setQuick(h)
                handles.markQuickReady()
            }

        #if os(macOS) && canImport(Darwin)
        if !ToolingArgs.parse().isHeadlessRequested,
           let sockPath = ProcessInfo.processInfo.environment["WINDOW_PANEL_SOCKET"],
           !sockPath.isEmpty {
            startSocketServer(path: sockPath, handles: handles)
        }
        #endif

        try RuneMultiWindow.runWindows(
            [AnyWindowSpec(mainSpec), AnyWindowSpec(quickSpec)],
            options: RunOptions(arguments: [], accessory: true)
        )
    }

    public static func runHeadlessVerify() throws -> Report {
        let handles = ProbeHandles()
        let mainApp = makeMainApp()
        let panelApp = makeQuickApp(title: "panel", handles: handles)
        let specs = [
            AnyWindowSpec(AppWindowSpec.fromApp(mainApp)),
            AnyWindowSpec(AppWindowSpec.fromApp(panelApp)),
        ]
        try RuneMultiWindow.validate(specs)
        let flat = RuneMultiWindow.flatten(specs)
        let keys = flat.map(\.key)

        let mainRt = mainApp.makeRuntime(viewport: Vec2(320, 160), pixelScale: 2.0)
        _ = mainRt.frame(at: 0.0)

        let panelRt = panelApp.makeRuntime(viewport: Vec2(480, 110), pixelScale: 2.0)
        _ = panelRt.keyDown(KeyEvent(key: .escape), at: 0.05)
        let escaped = panelRt.state.escaped || panelRt.closeWindowRequested
        panelRt.dispatchFocus(false, at: 0.10)
        let blurred = panelRt.state.blurred && panelRt.closeWindowRequested

        return Report(
            windowKeys: keys,
            panelEscaped: escaped,
            panelBlurred: blurred,
            mainFrames: mainRt.viewCommitCount
        )
    }

    #if os(macOS) && canImport(Darwin)
    private static func startSocketServer(path: String, handles: ProbeHandles) {
        Thread.detachNewThread {
            unlink(path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return }
            defer { close(fd) }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let maxPath = MemoryLayout.size(ofValue: addr.sun_path) - 1
            let pathBytes = Array(path.utf8.prefix(maxPath))
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                for i in 0..<pathBytes.count {
                    buf[i] = pathBytes[i]
                }
                buf[pathBytes.count] = 0
            }

            let bindOk = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindOk == 0, listen(fd, 8) == 0 else { return }

            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                var buf = [UInt8](repeating: 0, count: 1024)
                let n = read(client, &buf, buf.count)
                let cmd = n > 0
                    ? String(decoding: buf.prefix(n), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
                let reply = handleCommand(cmd, handles: handles)
                let out = Array((reply + "\n").utf8)
                out.withUnsafeBytes { raw in
                    if let base = raw.baseAddress {
                        _ = Darwin.write(client, base, out.count)
                    }
                }
                close(client)
                if cmd == "quit" {
                    break
                }
            }
        }
    }

    private static func handleCommand(_ cmd: String, handles: ProbeHandles) -> String {
        let quick = handles.quickHandle
        switch cmd {
        case "open":
            quick?.open()
            return "ok"
        case "focus":
            quick?.focus()
            return "ok"
        case "hide":
            quick?.hide()
            return "ok"
        case "visible":
            quick?.setVisible(true)
            return "ok"
        case "invisible":
            quick?.setVisible(false)
            return "ok"
        case "status":
            return DispatchQueue.main.sync {
                MainActor.assumeIsolated { inspect(handles: handles) }
            }
        case "quit":
            handles.mainAppHandle?.quit()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NSApplication.shared.terminate(nil)
                }
            }
            return "ok"
        default:
            return #"{"error":"unknown command"}"#
        }
    }

    @MainActor
    private static func inspect(handles: ProbeHandles) -> String {
        let quickNum = handles.quickHandle?.windowNumber
        let win = quickNum.flatMap { NSApplication.shared.window(withWindowNumber: Int($0)) }
        let snap = handles.quickHandle?.placement()
        let visible = win?.isVisible ?? false
        let isKey = win?.isKeyWindow ?? false
        let isMain = win?.isMainWindow ?? false
        let level = win?.level.rawValue ?? 0
        let canKey = win?.canBecomeKey ?? false
        let isFloating = (win as? NSPanel)?.isFloatingPanel ?? false
        let resp = win?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let ready = handles.quickHandle?.isReady ?? false
        return """
        {"quick_ready":\(ready),"visible":\(visible),"key":\(isKey),"main":\(isMain),"level":\(level),"can_become_key":\(canKey),"floating_panel":\(isFloating),"first_responder":"\(resp)","placement_size":[\(snap?.contentSize.0 ?? 0),\(snap?.contentSize.1 ?? 0)]}
        """
    }
    #endif
}
