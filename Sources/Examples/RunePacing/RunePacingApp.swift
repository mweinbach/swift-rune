import Foundation
import Rune
import RuneMotion
import RuneRef

/// Port of upstream `crates/rune/examples/pacing.rs`.
@main
public enum RunePacingApp {
    public struct State: Sendable {
        public var atEnd: Bool = false
        public var toggles: Int = 0
        public init(atEnd: Bool = false, toggles: Int = 0) {
            self.atEnd = atEnd
            self.toggles = toggles
        }
    }

    public struct Report: Sendable {
        public let frames: Int
        public let animatingMidMotion: Bool
        public let startX: Float
        public let midX: Float
        public let endX: Float
        public let output: String
    }

    public static func view(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        let spring = Spring.snappy
        let targetX: Float = s.atEnd ? 340 : 28
        let targetY: Float = s.atEnd ? 210 : 28
        return el()
            .wFull()
            .hFull()
            .bg(Color.rgba8(0x0b, 0x0c, 0x10))
            .onClick { st in
                st.atEnd.toggle()
                st.toggles += 1
            }
            .child(
                row()
                    .key("pill")
                    .pin(top: targetY, left: targetX)
                    .w(240)
                    .h(44)
                    .rounded(22)
                    .px(16)
                    .itemsCenter()
                    .justifyCenter()
                    .bg(s.atEnd ? oklch(0.62, 0.18, 250) : oklch(0.55, 0.16, 155))
                    .animateLayout(spring)
                    .child(
                        text(s.atEnd ? "Pacing -> B (space)" : "Pacing -> A (space)")
                            .font(TextStyle(size: 13, weight: 600))
                            .color(.white)
                    )
            )
    }

    public static func makeApp() -> App<State> {
        App(title: "pacing", state: State()) { s, cx in view(s, &cx) }
            .size(620, 300)
            .onKey { s, ev, _ in
                if ev.key == .space || ev.key == .enter {
                    s.atEnd.toggle()
                    s.toggles += 1
                    return true
                }
                return false
            }
    }

    private static func rectForKey(_ key: String, in rt: Runtime<State>) -> MotionRect? {
        guard let els = rt.treeJSON()["elements"] as? [[String: Any]],
              let match = els.first(where: { ($0["key"] as? String) == key }),
              let r = match["rect"] as? [Double], r.count == 4 else {
            return nil
        }
        return MotionRect(left: Float(r[0]), top: Float(r[1]), right: Float(r[0] + r[2]), bottom: Float(r[1] + r[3]))
    }

    public static func runPacingReport() -> Report {
        let rt = makeApp().makeRuntime(viewport: Vec2(620, 300), pixelScale: 2.0, systemDark: true)
        _ = rt.frame(at: 0.0)
        let startX = rectForKey("pill", in: rt)?.left ?? -1

        _ = rt.keyDown(KeyEvent(key: .space, mods: .none), at: 0.016)
        _ = rt.frame(at: 0.016)
        _ = rt.frame(at: 0.100)
        let midAnimating = rt.isAnimating
        let midX = rectForKey("pill", in: rt)?.left ?? -1

        var frames = 2
        var now = 0.100
        for _ in 0..<90 {
            now += 1.0 / 120.0
            _ = rt.frame(at: now)
            frames += 1
            if !rt.isAnimating {
                break
            }
        }
        let endX = rectForKey("pill", in: rt)?.left ?? -1
        let out = String(format: "pacing frames=%d animating=%@ startX=%.1f midX=%.1f endX=%.1f",
                         frames, midAnimating ? "true" : "false", startX, midX, endX)
        return Report(
            frames: frames,
            animatingMidMotion: midAnimating,
            startX: startX,
            midX: midX,
            endX: endX,
            output: out
        )
    }

    @MainActor
    public static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--verify") || args.contains("--headless") {
            let report = runPacingReport()
            print(report.output)
            return
        }
        try makeApp().run()
    }
}
