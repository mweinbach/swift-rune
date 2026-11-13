import Foundation
import Rune

/// Port of `crates/rune/examples/window_resize.rs`:
/// `Tx.resizeWindow` toggles the window height between 400 and 600 points with its top edge fixed,
/// or when `RUNE_RESIZE_FIT=1` lets `App.fitContentHeight()` size the window from content height.
public struct WindowResizeState: Sendable {
    public var tall: Bool

    public init(tall: Bool = false) {
        self.tall = tall
    }
}

private func edgeBar(_ labelText: String, _ color: Color) -> El<WindowResizeState> {
    row()
        .wFull()
        .h(44.0)
        .center()
        .bg(color)
        .child(text(labelText).color(.white))
}

public func toggleWindowResize(_ s: inout WindowResizeState, _ tx: inout Tx, fit: Bool) {
    s.tall.toggle()
    if !fit {
        tx.resizeWindow((480.0, s.tall ? 600.0 : 400.0))
    }
}

public func windowResizeView(
    _ s: WindowResizeState,
    fit: Bool = ProcessInfo.processInfo.environment["RUNE_RESIZE_FIT"] != nil
) -> El<WindowResizeState> {
    let height: Float = s.tall ? 600.0 : 400.0
    var body: El<WindowResizeState> = col()
        .wFull()
        .center()
        .gap(12.0)
        .child(text("\(Int(height)) pt").font(Tok.Typography.title).color(.white))
        .child(
            row()
                .key("toggle")
                .p(10.0)
                .rounded(8.0)
                .bg(oklch(0.45, 0.02, 260.0))
                .child(text("Toggle").color(.white))
                .onClick { state, tx in
                    toggleWindowResize(&state, &tx, fit: fit)
                }
        )
    body = fit ? body.h(height - 88.0) : body.grow(1.0)
    let root: El<WindowResizeState> = col()
        .key("root")
        .wFull()
        .bg(oklch(0.22, 0.02, 260.0))
        .border(2.0, oklch(0.75, 0.18, 145.0))
        .child(edgeBar("top edge", oklch(0.5, 0.15, 260.0)))
        .child(body)
        .child(edgeBar("bottom edge", oklch(0.55, 0.2, 25.0)))
    return fit ? root : root.hFull()
}

@main
public enum RuneWindowResizeApp {
    public static func makeApp(
        fit: Bool = ProcessInfo.processInfo.environment["RUNE_RESIZE_FIT"] != nil
    ) -> App<WindowResizeState> {
        var app = App(
            title: "Window resize",
            size: Vec2(480.0, 400.0),
            minSize: Vec2(200.0, 200.0),
            state: WindowResizeState(),
            view: { state, _ in windowResizeView(state, fit: fit) }
        )
        if fit {
            app = app.fitContentHeight()
        }
        return app
    }

    public static func main() throws {
        let env = ProcessInfo.processInfo.environment
        let fit = env["RUNE_RESIZE_FIT"] != nil
        let app = makeApp(fit: fit)
        let isHeadless = ToolingArgs.parse(Array(CommandLine.arguments.dropFirst())).isHeadlessRequested
        if env["RUNE_RESIZE_AUTO"] != nil && !isHeadless {
            let handle = app.handle()
            DispatchQueue.global(qos: .utility).async {
                while true {
                    Thread.sleep(forTimeInterval: 1.5)
                    handle.update { state, tx in
                        toggleWindowResize(&state, &tx, fit: fit)
                    }
                }
            }
        }
        try app.run()
    }
}
