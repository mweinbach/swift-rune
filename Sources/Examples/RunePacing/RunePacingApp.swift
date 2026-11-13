import Foundation
import Rune

/// Live motion pacing probe mirroring `crates/rune/examples/pacing.rs`.
@main
public enum RunePacingApp {
    public struct State: Sendable {
        public var wide: Bool = false
        public init() {}
    }

    public struct Report: Sendable {
        public let frames: Int
        public let animatingMidMotion: Bool
        public let startX: Float
        public let midX: Float
        public let endX: Float
    }

    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        func stop() { lock.withLock { stopped = true } }
        func isStopped() -> Bool { lock.withLock { stopped } }
    }

    public static func makeApp() -> App<State> {
        App(
            "Pacing",
            size: Vec2(480, 120),
            init: { State() },
            view: { s, _ in
                el()
                    .wFull()
                    .hFull()
                    .bg(Color(r: 0.08, g: 0.08, b: 0.1, a: 1.0))
                    .center()
                    .child(
                        el()
                            .key("pill")
                            .w(s.wide ? 400.0 : 100.0)
                            .h(60.0)
                            .rounded(30.0)
                            .bg(Color(r: 0.4, g: 0.65, b: 1.0, a: 1.0))
                            .motion(Spring(duration: 0.6, bounce: 0.0))
                    )
            }
        )
    }

    @MainActor
    public static func main() throws {
        QuitLifecycle.orderlyExit()
        let app = makeApp()
        let handle = app.handle()
        let isHeadless = ToolingArgs.parse().isHeadlessRequested
        let done = DispatchSemaphore(value: 0)
        let stop = StopFlag()

        if !isHeadless {
            Thread.detachNewThread {
                defer { done.signal() }
                for i in 0..<48 {
                    if stop.isStopped() { return }
                    Thread.sleep(forTimeInterval: i % 3 == 0 ? 0.173 : 0.003)
                    if stop.isStopped() { return }
                    if i == 15 {
                        handle.hide()
                        Thread.sleep(forTimeInterval: 0.035)
                        handle.show()
                    }
                    let wide = (i % 2 == 0)
                    handle.update { s, _ in s.wide = wide }
                }
                for _ in 0..<50 {
                    if stop.isStopped() { return }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                handle.quit()
            }
        } else {
            done.signal()
        }

        try app.run()
        stop.stop()
        done.wait()
    }

    public static func runPacingReport() -> Report {
        let rt = makeApp().makeRuntime(viewport: Vec2(480, 120), pixelScale: 2.0)
        let _ = rt.frame(at: 0.0)
        let startRect = rt.element(byKey: "pill")?.rect
        let startX = (startRect?.count ?? 0) >= 3 ? startRect![2] : 100.0

        rt.update(at: 0.01) { s, _ in s.wide = true }
        let _ = rt.frame(at: 0.15)
        let animatingMid = rt.isAnimating
        let midRect = rt.element(byKey: "pill")?.rect
        let midX = (midRect?.count ?? 0) >= 3 ? midRect![2] : startX

        var frames = 2
        var t = 0.15
        for _ in 0..<40 {
            t += 1.0 / 60.0
            let _ = rt.frame(at: t)
            frames += 1
        }
        let endRect = rt.element(byKey: "pill")?.rect
        let endX = (endRect?.count ?? 0) >= 3 ? endRect![2] : midX

        return Report(
            frames: frames,
            animatingMidMotion: animatingMid,
            startX: startX,
            midX: midX,
            endX: endX
        )
    }
}
