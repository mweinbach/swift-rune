import Foundation
import Rune
import RuneMotion
import RuneRef

/// Port of upstream `crates/rune/examples/pacing_overlay.rs`.
@main
public enum RunePacingOverlayApp {
    public struct State: Sendable {
        public var shown: Bool = true
        public var pulses: Int = 0
        public init(shown: Bool = true, pulses: Int = 0) {
            self.shown = shown
            self.pulses = pulses
        }
    }

    public struct Report: Sendable {
        public let visibleOnFadeIn: Bool
        public let visibleAfterFadeOut: Bool
        public let overlayInstances: Int
        public let output: String
    }

    public static func overlayView(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        row()
            .wFull()
            .hFull()
            .itemsCenter()
            .justifyCenter()
            .bg(.transparent)
            .child(
                row()
                    .key("pulse-pill")
                    .w(260)
                    .h(48)
                    .rounded(24)
                    .itemsCenter()
                    .justifyCenter()
                    .bg(oklch(0.60, 0.18, 250))
                    .looping(.opacity(period: 1.4, low: 0.25, high: 1.0).mode(.pingPong))
                    .child(text("Overlay pacing").font(TextStyle(size: 13, weight: 600)).color(.white))
            )
    }

    public static func overlaySpec() -> OverlaySpec<State> {
        OverlaySpec(
            name: "pacing_overlay",
            size: Vec2(280, 64),
            edge: .top,
            margin: 48,
            align: .center,
            inset: 0,
            interactive: false,
            makeState: { State() },
            view: overlayView
        )
    }

    public static func runHeadlessVerify() -> Report {
        let handle = OverlayHandle(spec: overlaySpec())
        handle.fadeIn(0.0)
        let visIn = handle.isVisible
        let rf = handle.runtime.renderFrame(at: 0.25)
        handle.fadeOut(0.2, now: 0.25)
        handle.advanceDue(at: 0.60)
        let visOut = handle.isVisible
        let out = "pacing_overlay visibleIn=\(visIn) visibleOut=\(visOut) instances=\(rf.instances.count)"
        return Report(
            visibleOnFadeIn: visIn,
            visibleAfterFadeOut: visOut,
            overlayInstances: rf.instances.count,
            output: out
        )
    }

    @MainActor
    public static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--verify") || args.contains("--headless") {
            let report = runHeadlessVerify()
            print(report.output)
            return
        }
        var handleBox: OverlayHandle<State>?
        let app = App(title: "pacing_overlay", state: State()) { s, _ in
            col()
                .wFull()
                .hFull()
                .itemsCenter()
                .justifyCenter()
                .bg(Color.rgba8(0x10, 0x11, 0x14))
                .child(
                    text(s.shown ? "Hide overlay (click)" : "Show overlay (click)")
                        .font(TextStyle(size: 14, weight: 600))
                        .color(.white)
                        .p(12)
                        .rounded(8)
                        .bg(Color.white.alpha(0.1))
                        .onClick { st in
                            st.shown.toggle()
                            st.pulses += 1
                            if st.shown {
                                handleBox?.fadeIn(0.15)
                            } else {
                                handleBox?.fadeOut(0.2)
                            }
                        }
                )
        }
        .size(420, 220)
        .overlay(overlaySpec()) { handle in
            handleBox = handle
            handle.show()
        }
        try RuneMultiWindow.runWindows([AnyWindowSpec(AppWindowSpec.fromApp(app))])
    }
}
