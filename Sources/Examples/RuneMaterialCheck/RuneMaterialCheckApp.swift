import Foundation
import Rune
import RuneMotion
import RuneRef

/// Port of upstream `crates/rune/examples/material_check.rs`.
@main
public enum RuneMaterialCheckApp {
    public struct State: Sendable {
        public var shown: Bool = false
        public var opens: Int = 0
        public init(shown: Bool = false, opens: Int = 0) {
            self.shown = shown
            self.opens = opens
        }
    }

    public struct Report: Sendable {
        public let mainMaterialCount: Int
        public let overlayPrewarmed: Bool
        public let overlayVisible: Bool
        public let overlayInstances: Int
        public let output: String
    }

    public static func overlayView(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        col()
            .key("mat-overlay")
            .wFull()
            .hFull()
            .rounded(14)
            .p(14)
            .gap(6)
            .systemMaterial(.popover, blending: .behindWindow)
            .child(text("Popover Material").font(TextStyle(size: 14, weight: 600)).color(.white))
            .child(text("opens=\(s.opens)").font(TextStyle(size: 12, weight: 400)).color(Color.white.alpha(0.75)))
    }

    public static func mainView(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        col()
            .wFull()
            .hFull()
            .p(20)
            .gap(12)
            .bg(Color.rgba8(0x0c, 0x0e, 0x12))
            .child(
                row()
                    .key("glass-card")
                    .wFull()
                    .h(84)
                    .rounded(14)
                    .p(14)
                    .itemsCenter()
                    .justifyBetween()
                    .systemMaterial(.glass, blending: .behindWindow)
                    .child(text("SystemMaterial.glass").font(TextStyle(size: 14, weight: 600)).color(.white))
                    .child(
                        text(s.shown ? "Hide HUD" : "Show HUD")
                            .font(TextStyle(size: 12, weight: 600))
                            .color(.white)
                            .p(8)
                            .rounded(8)
                            .bg(Color.white.alpha(0.14))
                    )
            )
            .child(
                row()
                    .key("popover-card")
                    .wFull()
                    .h(84)
                    .rounded(14)
                    .p(14)
                    .itemsCenter()
                    .systemMaterial(.popover, blending: .behindWindow)
                    .child(text("SystemMaterial.popover").font(TextStyle(size: 14, weight: 600)).color(.white))
            )
    }

    public static func overlayConfigured() -> ConfiguredOverlay<State> {
        OverlaySpec(
            name: "material_check",
            size: Vec2(280, 96),
            edge: .top,
            margin: 48,
            align: .center,
            inset: 0,
            interactive: false,
            makeState: { State() },
            view: overlayView
        )
        .configured(OverlayOptions())
        .prewarm(true)
        .animateReveal(true)
    }

    public static func runHeadlessVerify() -> Report {
        let app = App(title: "material_check", state: State()) { s, cx in mainView(s, &cx) }
            .size(480, 260)
        let rt = app.makeRuntime(viewport: Vec2(480, 260), pixelScale: 2.0, systemDark: true)
        rt.nativeMaterials = true
        let rfMain = rt.renderFrame(at: 0.0)

        let cfg = overlayConfigured()
        let handle = cfg.makeHandle()
        handle.fadeIn(0.15)
        let vis = handle.isVisible
        let rfOverlay = handle.runtime.renderFrame(at: 0.0)
        handle.fadeOut(0.1, now: 0.1)

        let matCount = rfMain.materials.count
        let out = "material_check materials=\(matCount) prewarm=\(cfg.options.prewarm) visible=\(vis) overlayInstances=\(rfOverlay.instances.count)"
        return Report(
            mainMaterialCount: matCount,
            overlayPrewarmed: cfg.options.prewarm,
            overlayVisible: vis,
            overlayInstances: rfOverlay.instances.count,
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
        let app = App(title: "material_check", state: State()) { s, cx in mainView(s, &cx) }
            .size(480, 260)
        try RuneMultiWindow.runWindows([AnyWindowSpec(AppWindowSpec.fromApp(app))])
    }
}
