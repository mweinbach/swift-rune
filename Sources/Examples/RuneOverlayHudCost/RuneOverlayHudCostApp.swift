import Foundation
import Rune
import RuneMotion
import RuneRef

#if canImport(Metal)
import Metal
#endif

/// Port of upstream `crates/rune/examples/overlay_hud_cost.rs`.
@main
public enum RuneOverlayHudCostApp {
    public struct State: Sendable {
        public var writes: Int = 2
        public var staged: Bool = true
        public init(writes: Int = 2, staged: Bool = true) {
            self.writes = writes
            self.staged = staged
        }
    }

    public final class HudCompositor: Compositor, @unchecked Sendable {
        public typealias State = RuneOverlayHudCostApp.State

        public let writes: Int
        public let staged: Bool
        public var renderedFrames: Int = 0
        public var uiDraws: Int = 0

        #if canImport(Metal)
        private var uniformBuffer: MTLBuffer?
        #endif

        public init(writes: Int = 2, staged: Bool = true) {
            self.writes = writes
            self.staged = staged
        }

        public var features: CompositorFeatures {
            [.prefersSurfaceFormatMatch]
        }

        public func render(frame: CompositorFrame<State>) {
            renderedFrames += 1
            let phase = Float(sin(Double(renderedFrames) * 0.15) * 0.5 + 0.5)
            let payload = [Float](repeating: phase, count: 64)
            #if canImport(Metal)
            if writes > 0, let device = frame.device {
                if uniformBuffer == nil {
                    uniformBuffer = device.makeBuffer(length: 256, options: [.storageModeShared])
                    uniformBuffer?.label = "hud uniforms"
                }
                if let buf = uniformBuffer {
                    for _ in 0..<writes {
                        payload.withUnsafeBytes { raw in
                            if let base = raw.baseAddress {
                                frame.writeBuffer(buf, offset: 0, bytes: base, length: min(256, raw.count))
                            }
                        }
                    }
                }
            }
            #endif
            _ = payload
            frame.drawUI()
            uiDraws += frame.uiDrawCount
        }
    }

    public struct Report: Sendable {
        public let frames: Int
        public let uiDraws: Int
        public let overlayName: String
        public let overlayVisibleAfterShow: Bool
        public let output: String
    }

    public static func overlaySpec() -> OverlaySpec<State> {
        OverlaySpec(
            name: "HUD",
            size: Vec2(360, 80),
            edge: .bottom,
            margin: 60,
            align: .center,
            inset: 0,
            interactive: false,
            makeState: { State() },
            view: { _, _ in
                row()
                    .wFull()
                    .hFull()
                    .itemsCenter()
                    .justifyCenter()
                    .bg(Color.black.alpha(0.65))
                    .rounded(16)
                    .child(text("Overlay HUD").font(TextStyle(size: 13, weight: 600)).color(.white))
            }
        )
    }

    public static func makeApp(writes: Int = 2, staged: Bool = true) -> (App<State>, HudCompositor) {
        let hud = HudCompositor(writes: writes, staged: staged)
        let app = App(title: "Overlay HUD cost", state: State(writes: writes, staged: staged)) { _, _ -> El<State> in
            el().wFull().hFull().bg(.transparent)
        }
        .size(360, 80)
        .windowless(true)
        .accessory(true)
        .compositor(hud)
        return (app, hud)
    }

    public static func runHeadlessVerify(frames: Int = 12, writes: Int = 2) -> Report {
        let (app, hud) = makeApp(writes: writes, staged: true)
        let rt = app.makeRuntime(viewport: Vec2(360, 80), pixelScale: 2.0, systemDark: true)
        let device = DeviceKey.next()

        for i in 0..<frames {
            _ = rt.frame(at: Double(i) * (1.0 / 120.0))
            let cf = CompositorFrame<State>(
                deviceKey: device,
                pixelSize: (720, 160),
                dt: 1.0 / 120.0,
                updateMilliseconds: 0.5,
                srgbBlend: false,
                runtime: rt,
                drawUI: { _ = rt.renderFrame(at: Double(i) * (1.0 / 120.0)) }
            )
            hud.render(frame: cf)
        }

        let spec = overlaySpec()
        let handle = OverlayHandle(spec: spec)
        handle.fadeIn(0.0)
        let visibleAfterShow = handle.isVisible
        handle.hide()

        let out = "overlay_hud_cost frames=\(hud.renderedFrames) ui_draws=\(hud.uiDraws) overlay=\(spec.name) visible=\(visibleAfterShow)"
        return Report(
            frames: hud.renderedFrames,
            uiDraws: hud.uiDraws,
            overlayName: spec.name,
            overlayVisibleAfterShow: visibleAfterShow,
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
        let (app, _) = makeApp()
        var capturedOverlay: OverlayHandle<State>?
        let configured = app.overlay(overlaySpec()) { handle in
            capturedOverlay = handle
            handle.show()
        }
        _ = capturedOverlay
        let spec = AppWindowSpec.fromApp(configured)
        try RuneMultiWindow.runWindows([AnyWindowSpec(spec)], options: RunOptions(accessory: true))
    }
}
