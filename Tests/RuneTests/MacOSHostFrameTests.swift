#if os(macOS)
import AppKit
import Foundation
import Metal
import QuartzCore
import RuneMotion
import Testing
@testable import Rune

struct MacOSHostFrameTests {
    @MainActor
    @Test func preparedTextRunsBetweenFramesOnce() {
        struct State {}
        let runtime = Runtime(state: State()) { _, _ in text("mounted") }
        _ = runtime.frame(at: 0)
        var preparations = 0
        var mayPrepare = false
        let observer = AppleTextIdleObserver(runtime: runtime) { mayPrepare }
        runtime.updateIf { _, tx in
            tx.prepareText { (_: State, _: inout Cx<State>) in
                preparations += 1
                return text("prepared")
            }
            return false
        }
        let commits = runtime.viewCommitCount
        // The test process has no NSApplication event source to drive subsequent idle turns.
        let source = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in }
        defer { source.invalidate() }
        withExtendedLifetime(observer) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.015))
            #expect(preparations == 0 && runtime.textIdleOwed)
            mayPrepare = true
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            #expect(preparations == 1 && !runtime.textIdleOwed)
            #expect(runtime.viewCommitCount == commits)
        }
    }

    @MainActor
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func presentationDistinguishesFailureFromCompositorWithNoUIDraws() throws {
        final class OwnContent: Compositor {
            func render(frame: CompositorFrame<Int>) {}
        }
        let app = App(title: "Own content", size: Vec2(16, 16), state: 0) { _, _ in text("UI") }
            .compositor(OwnContent())
        let entry = AppWindowSpec(app: app).boxed().requireNativeHostEntry()
        let runtime = entry.createRuntime(pixelScale: 1, systemDark: false, reducedMotion: true, waker: Waker())
        let renderer = try MetalRenderer()
        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.drawableSize = CGSize(width: 16, height: 16)
        let drawable = try #require(layer.nextDrawable())
        var frame = RenderFrame(width: 16, height: 16)
        frame.width = Int.max
        #expect(!entry.present(frame, drawable: drawable, renderer: renderer, runtimeObj: runtime,
                               dt: 0, started: CACurrentMediaTime(), updateMs: 0, synchronized: false, committed: false))
        frame.width = 16
        #expect(entry.present(frame, drawable: drawable, renderer: renderer, runtimeObj: runtime,
                              dt: 0, started: CACurrentMediaTime(), updateMs: 0, synchronized: false, committed: false))
    }

    @MainActor
    @Test func idleWakeReplacesAndCancelsOneShot() async throws {
        var ticks = 0
        let driver = MacOSDisplayLinkDriver { ticks += 1 }
        let clock = ContinuousClock()
        driver.sleep(until: 60, now: 0, timeScale: 1)
        driver.sleep(until: 2, now: 1, timeScale: 100)
        let timeout = clock.now.advanced(by: .seconds(1))
        while ticks == 0 && clock.now < timeout {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(ticks == 1)
        #expect(!driver.isRunning)
        driver.sleep(until: 0.01, now: 0, timeScale: 1)
        driver.stop()
        driver.sleep(until: 0, now: 0, timeScale: 0)
        try await Task.sleep(for: .milliseconds(30))
        #expect(ticks == 1)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func groupedWindowBuildsSurfaceAndConsumesEachTimerDeadline() throws {
        let surface = NativeSurface()
        try surface.pushBytes(ByteFrame.synthetic(width: 2, height: 2, index: 0), frameId: 1)
        let app = App(title: "Scheduled window", size: Vec2(16, 16), state: 0) { _, _ in
            nativeSurface(surface).size(16, 16)
        }.poll { _, _, tx in
            tx.wakeAfter(0.25)
            return false
        }
        let entry = AppWindowSpec(app: app).boxed().requireNativeHostEntry()
        let runtime = entry.createRuntime(pixelScale: 1, systemDark: false, reducedMotion: true, waker: Waker())
        let renderer = try MetalRenderer()
        for now in [0.0, 0.25, 0.5] {
            let frame = entry.renderFrame(runtimeObj: runtime, renderer: renderer, at: now, nativeMaterials: false)
            #expect(frame.surfaces.count == 1)
            #expect(!entry.isAnimating(runtimeObj: runtime))
            #expect(entry.wakeDeadline(runtimeObj: runtime, covered: false) == now + 0.25)
            #expect(entry.wakeDeadline(runtimeObj: runtime, covered: true) == now + 0.25)
        }
    }
}
#endif
