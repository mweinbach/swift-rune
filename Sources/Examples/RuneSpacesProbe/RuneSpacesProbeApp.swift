import Foundation
import Rune
import RuneMotion
import RuneRef

/// Port of upstream `crates/rune/examples/spaces_probe.rs`.
@main
public enum RuneSpacesProbeApp {
    public struct State: Sendable {
        public var phase: Int = 0
        public var excluded: Bool = true
        public init(phase: Int = 0, excluded: Bool = true) {
            self.phase = phase
            self.excluded = excluded
        }
    }

    public struct Report: Sendable {
        public let excludedOption: Bool
        public let prewarmOption: Bool
        public let visibleDuringShow: Bool
        public let sizeAfterResize: Vec2
        public let visibleAfterHide: Bool
        public let instances: Int
        public let output: String
    }

    public static func overlayView(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        row()
            .key("spaces-pill")
            .wFull()
            .hFull()
            .rounded(14)
            .px(16)
            .itemsCenter()
            .justifyBetween()
            .bg(Color.black.alpha(0.75))
            .child(text("Spaces Probe").font(TextStyle(size: 13, weight: 600)).color(.white))
            .child(text(s.excluded ? "excluded" : "captured").font(TextStyle(size: 11, weight: 500)).color(oklch(0.75, 0.14, 155)))
    }

    public static func overlayConfigured() -> ConfiguredOverlay<State> {
        let opts = OverlayOptions(
            placement: .edge(.top, margin: 36),
            display: .primary,
            followPointer: false,
            level: .status,
            excludeFromCapture: true,
            keyPolicy: .nonActivating,
            prewarm: true,
            animateReveal: true
        )
        return OverlaySpec(
            name: "spaces_probe",
            size: Vec2(280, 56),
            edge: .top,
            margin: 36,
            align: .center,
            inset: 0,
            interactive: false,
            options: opts,
            makeState: { State() },
            view: overlayView
        )
        .configured(opts)
        .prewarm(true)
    }

    public static func runHeadlessVerify() -> Report {
        let cfg = overlayConfigured()
        let handle = cfg.makeHandle()
        handle.fadeIn(0.1)
        let visShow = handle.isVisible
        handle.resize(Vec2(340, 64))
        let resized = handle.size
        handle.setExcludeFromCapture(false)
        handle.update { $0.excluded = false; $0.phase += 1 }
        let rf = handle.runtime.renderFrame(at: 0.2)
        handle.setExcludeFromCapture(true)
        handle.fadeOut(0.1, now: 0.2)
        handle.advanceDue(at: 0.4)
        let visHide = handle.isVisible

        let out = "spaces_probe excluded=\(cfg.options.excludeFromCapture) prewarm=\(cfg.options.prewarm) visShow=\(visShow) size=\(Int(resized.x))x\(Int(resized.y)) visHide=\(visHide)"
        return Report(
            excludedOption: cfg.options.excludeFromCapture,
            prewarmOption: cfg.options.prewarm,
            visibleDuringShow: visShow,
            sizeAfterResize: resized,
            visibleAfterHide: visHide,
            instances: rf.instances.count,
            output: out
        )
    }

    @MainActor
    public static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--verify") || args.contains("--headless") {
            print(runHeadlessVerify().output)
            return
        }
        var captured: OverlayHandle<State>?
        let app = App(title: "spaces_probe", state: State()) { _, _ -> El<State> in
            el().wFull().hFull().bg(.transparent)
        }
        .windowless(true)
        .accessory(true)
        .overlay(overlayConfigured().spec) { handle in
            captured = handle
            handle.show()
        }
        _ = captured
        try RuneMultiWindow.runWindows([AnyWindowSpec(AppWindowSpec.fromApp(app))], options: RunOptions(accessory: true))
    }
}
