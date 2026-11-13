import Foundation
import Rune
import RuneMotion
import RuneRef

/// Port of upstream `crates/rune/examples/live_resize_check.rs`.
@main
public enum RuneLiveResizeCheckApp {
    public struct State: Sendable {
        public var width: Float = 640
        public var height: Float = 420
        public init(width: Float = 640, height: Float = 420) {
            self.width = width
            self.height = height
        }
    }

    public final class ResizeCompositor: Compositor, @unchecked Sendable {
        public typealias State = RuneLiveResizeCheckApp.State
        public var renderedSizes: [(Int, Int)] = []

        public init() {}
        public var features: CompositorFeatures { [] }

        public func render(frame: CompositorFrame<State>) {
            renderedSizes.append(frame.pixelSize)
            frame.drawUI()
        }
    }

    public struct Report: Sendable {
        public let widths: [Float]
        public let barRights: [Float]
        public let compositorFrames: Int
        public let output: String
    }

    public static func view(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        let size = cx.viewport
        return col()
            .wFull()
            .hFull()
            .bg(Color.rgba8(0x0b, 0x0e, 0x14))
            .justifyBetween()
            .child(
                row()
                    .key("top-bar")
                    .wFull()
                    .h(28)
                    .px(12)
                    .itemsCenter()
                    .justifyBetween()
                    .bg(oklch(0.28, 0.08, 250))
                    .child(text("Live resize check").font(TextStyle(size: 12, weight: 600)).color(.white))
                    .child(text("\(Int(size.x))×\(Int(size.y))").font(TextStyle(size: 12, weight: 500)).color(.white))
            )
            .child(
                row()
                    .key("center-row")
                    .wFull()
                    .grow(1)
                    .justifyBetween()
                    .itemsCenter()
                    .child(el().key("left-edge").w(8).hFull().bg(oklch(0.65, 0.2, 30)))
                    .child(text("Edges hug frame").font(TextStyle(size: 14, weight: 500)).color(Color.white.alpha(0.85)))
                    .child(el().key("right-edge").w(8).hFull().bg(oklch(0.65, 0.2, 145)))
            )
            .child(
                el().key("bottom-bar").wFull().h(10).bg(oklch(0.55, 0.18, 280))
            )
    }

    public static func runHeadlessVerify() -> Report {
        let comp = ResizeCompositor()
        let app = App(title: "live_resize_check", state: State()) { s, cx in view(s, &cx) }
            .size(640, 420)
            .compositor(comp)
        let rt = app.makeRuntime(viewport: Vec2(640, 420), pixelScale: 2.0, systemDark: true)

        let widths: [Float] = [640, 520, 780, 480]
        var barRights: [Float] = []
        let device = DeviceKey.next()

        for (i, w) in widths.enumerated() {
            rt.setViewport(Vec2(w, 420))
            let t = Double(i) * (1.0 / 60.0)
            _ = rt.frame(at: t)
            let cf = CompositorFrame<State>(
                deviceKey: device,
                pixelSize: (Int(w * 2), 840),
                dt: 1.0 / 60.0,
                updateMilliseconds: 0.4,
                srgbBlend: false,
                runtime: rt,
                drawUI: { _ = rt.renderFrame(at: t) }
            )
            comp.render(frame: cf)
            if let rect = rectForKey("right-edge", in: rt) {
                barRights.append(rect.right)
            }
        }
        let out = "live_resize_check widths=\(widths) rightEdges=\(barRights) frames=\(comp.renderedSizes.count)"
        return Report(widths: widths, barRights: barRights, compositorFrames: comp.renderedSizes.count, output: out)
    }

    private static func rectForKey(_ key: String, in rt: Runtime<State>) -> MotionRect? {
        guard let els = rt.treeJSON()["elements"] as? [[String: Any]],
              let match = els.first(where: { ($0["key"] as? String) == key }),
              let r = match["rect"] as? [Double], r.count == 4 else {
            return nil
        }
        return MotionRect(left: Float(r[0]), top: Float(r[1]), right: Float(r[0] + r[2]), bottom: Float(r[1] + r[3]))
    }

    @MainActor
    public static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--verify") || args.contains("--headless") {
            print(runHeadlessVerify().output)
            return
        }
        let comp = ResizeCompositor()
        try App(title: "live_resize_check", state: State()) { s, cx in view(s, &cx) }
            .size(640, 420)
            .compositor(comp)
            .run()
    }
}
