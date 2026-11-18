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
        var encoded: [FrameEncoded] = []
        let app = App(title: "Own content", size: Vec2(16, 16), state: 0) { _, _ in text("UI") }
            .compositor(OwnContent())
            .onFrameEncoded { encoded.append($0) }
        let entry = AppWindowSpec(app: app).boxed().requireNativeHostEntry()
        let runtime = entry.createRuntime(pixelScale: 1, systemDark: false, reducedMotion: true, waker: Waker())
        let renderer = try MetalRenderer()
        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.drawableSize = CGSize(width: 16, height: 16)
        let drawable = try #require(layer.nextDrawable())
        var frame = RenderFrame(width: 16, height: 16)
        frame.width = Int.max
        #expect(entry.present(frame, drawable: drawable, renderer: renderer, runtimeObj: runtime,
                               dt: 0, started: CACurrentMediaTime(), updateMs: 0, synchronized: false, committed: false,
                               target: nil, refreshHz: nil) == nil)
        frame.width = 16
        let started = CACurrentMediaTime()
        let target = started + 0.008
        let submitted = try #require(entry.present(frame, drawable: drawable, renderer: renderer, runtimeObj: runtime,
                              dt: 0, started: started, updateMs: 0, synchronized: false, committed: false,
                              target: target, refreshHz: 120))
        let report = try #require(encoded.last)
        #expect(report.at == submitted)
        #expect(report.outcome == .drawn)
        #expect(report.at >= started)
        #expect(report.started == started)
        #expect(report.refreshHz == 120)
        #expect(report.presentsAt == target)
    }

    @MainActor
    @Test func initialDrawableCountRestoresAfterVisibleIdleOrASecondOfMotion() {
        let layer = CAMetalLayer()
        layer.maximumDrawableCount = 3
        var launch = MacOSLaunchDrawables()
        launch.cap(layer)
        #expect(layer.maximumDrawableCount == 2)
        launch.submitted(to: layer, visible: false, idle: true, at: 2)
        launch.submitted(to: layer, visible: true, idle: false, at: 10)
        launch.submitted(to: layer, visible: true, idle: false, at: 10.999)
        #expect(layer.maximumDrawableCount == 2)
        launch.submitted(to: layer, visible: true, idle: false, at: 11)
        #expect(layer.maximumDrawableCount == 3)
        launch.cap(layer)
        launch.submitted(to: layer, visible: true, idle: true, at: 20)
        #expect(layer.maximumDrawableCount == 3)
        layer.maximumDrawableCount = 2
        launch.cap(layer)
        launch.submitted(to: layer, visible: true, idle: true, at: 21)
        #expect(layer.maximumDrawableCount == 2)
    }

    @Test func quietTimerComparesInstanceBitsScaleAndEveryAtlasPage() throws {
        var frame = RenderFrame(width: 64, height: 64, instances: [RenderInstance()])
        frame.instances[0].params.w = Float(bitPattern: 0x7fc0_0001)
        frame.glyphPageRevisions = [10, 20]
        frame.imagePageRevisions = [30, 40]
        let first = try #require(SettledWindowFrame(frame, scale: 2))
        #expect(first == SettledWindowFrame(frame, scale: 2))
        #expect(first != SettledWindowFrame(frame, scale: 1))
        var next = frame
        next.instances[0].params.w = Float(bitPattern: 0x7fc0_0002)
        #expect(first != SettledWindowFrame(next, scale: 2))
        next = frame
        next.glyphPageRevisions[1] += 1
        #expect(first != SettledWindowFrame(next, scale: 2))
        next = frame
        next.imagePageRevisions[1] += 1
        #expect(first != SettledWindowFrame(next, scale: 2))
        next = frame
        next.elidedLayers = [(index: 0, node: 3, signature: 4)]
        #expect(SettledWindowFrame(next, scale: 2) == nil)
    }

    @MainActor
    @Test func aFreshTickCanStillDrawAfterMinimumSubmissionSpacing() {
        let period = 1.0 / 60
        let previousTarget = 1 + period
        let target = previousTarget + period
        let lastSubmit = 1.012
        let early = previousTarget + 0.0001
        let retry = MacOSDisplayLinkDriver.retryTime(for: target, lastPresent: lastSubmit,
                                                      lastTarget: previousTarget, now: early, period: period)
        #expect(retry == (lastSubmit + period / 2).nextUp)
        #expect(MacOSDisplayLinkDriver.retryTime(for: target, lastPresent: lastSubmit,
                lastTarget: target, now: early, period: period) == nil)
        #expect(MacOSDisplayLinkDriver.retryTime(for: target, lastPresent: target - 0.001,
                lastTarget: previousTarget, now: target, period: period) == nil)
        #expect(MacOSDisplayLinkDriver.retryTime(for: target, lastPresent: lastSubmit,
                lastTarget: previousTarget, now: 1.025, period: period) == nil)
    }

    @Test func earlyFramePreparationKeepsMinimumSpacingWhenWorkloadChanges() {
        var frame = MacOSFramePreparation()
        let period = 1.0 / 60
        let submitted = 1.012
        let arrived = 1 + period
        let earliest = submitted + period / 2
        #expect(!frame.canStart(at: arrived, submissionAfter: earliest))
        frame.begin(at: 1, earliestSubmission: nil)
        #expect(frame.finished(at: submitted) == nil)
        #expect(frame.canStart(at: arrived, submissionAfter: earliest))
        frame.begin(at: arrived, earliestSubmission: earliest)
        #expect(frame.finished(at: arrived + 0.0003) == earliest)
        #expect(!frame.canStart(at: arrived, submissionAfter: earliest))
        frame.begin(at: arrived, earliestSubmission: earliest)
        #expect(frame.finished(at: earliest) == nil)
        frame.begin(at: arrived, earliestSubmission: earliest)
        #expect(frame.finished(at: arrived + 0.012) == nil)
    }

    @Test func scrollAfterSubmissionKeepsTheWindowAwakeUntilItsNewPixelsAreDrawn() {
        let runtime = Runtime(state: 0, viewport: Vec2(100, 100)) { _, _ in
            col().key("viewport").size(100, 100).scrollY().child(el().size(100, 1_000).shrink(0))
        }
        _ = runtime.frame(at: 0)
        let commits = runtime.viewCommitCount
        #expect(!runtime.windowHasFrameWork)
        runtime.wheel(WheelEvent(dx: 0, dy: -48), at: Vec2(50, 50), now: 0.01)
        #expect(runtime.windowHasFrameWork)
        _ = runtime.frame(at: 0.02)
        #expect(runtime.viewCommitCount == commits)
        #expect(!runtime.windowHasFrameWork)
    }

    @MainActor
    @Test func startupTimerBecomesADisplayLinkWhenTheViewAttaches() {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        let driver = MacOSDisplayLinkDriver {}
        driver.start(in: view)
        #expect(driver.pacing == .unpaced)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        driver.start(in: view)
        #expect(driver.pacing == .paced)
        driver.stop()
    }

    @MainActor
    @Test func idleDisplayLinkKeepsOneRealOpportunityAndPreservesTheWakeDeadline() async throws {
        _ = NSApplication.shared
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        var wakes = 0
        let driver = MacOSDisplayLinkDriver { wakes += 1 }
        defer { driver.stop() }
        driver.start(in: view)
        driver.sleep(until: nil, now: 0, timeScale: 1, afterPacedFrame: true)
        #expect(driver.pacing == .idle)
        let target = CACurrentMediaTime() + 1.0 / 60
        #expect(driver.handleIdleTick(target: target))
        #expect(wakes == 0)
        #expect(driver.beginFrame(in: view, paced: true) == .tick(target))
        driver.submitted()
        driver.endFrame()
        #expect(!driver.handleIdleTick(target: target))

        driver.sleep(until: 1, now: 0, timeScale: 100, afterPacedFrame: true)
        #expect(driver.handleIdleTick(target: target + 1.0 / 60))
        #expect(driver.handleIdleTick(target: target + 2.0 / 60))
        #expect(!driver.isRunning && wakes == 0)
        let timeout = ContinuousClock.now + .seconds(20)
        while wakes == 0 && ContinuousClock.now < timeout { try await Task.sleep(for: .milliseconds(5)) }
        #expect(wakes == 1)
    }

    @MainActor
    @Test func reentrantRenderRequestsWakeOnceAfterTheCurrentFrame() async throws {
        let view = NSView()
        var wakes = 0
        let driver = MacOSDisplayLinkDriver { wakes += 1 }
        #expect(driver.beginFrame(in: view, paced: true) == .now)
        for _ in 0..<20 {
            #expect(driver.beginFrame(in: view, paced: true) == .wait)
        }
        #expect(wakes == 0)
        driver.submitted()
        driver.endFrame()
        await withCheckedContinuation { resume in DispatchQueue.main.async { resume.resume() } }
        #expect(wakes == 1)
        driver.stop()
    }

    @MainActor
    @Test func idleWakeReplacesAndCancelsOneShot() {
        func servicePastShortDeadline() {
            // The host's common-mode timer is serviced in the default run-loop mode.
            // Wait for a later timer in that mode before inspecting the wake count.
            let checkpoint = Timer(timeInterval: 0.03, repeats: false) { _ in }
            RunLoop.main.add(checkpoint, forMode: .default)
            while checkpoint.isValid {
                _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
        }

        var ticks = 0
        let driver = MacOSDisplayLinkDriver { ticks += 1 }
        let distantDeadline = 3_600.0
        driver.sleep(until: distantDeadline, now: 0, timeScale: 1)
        driver.sleep(until: 2, now: 1, timeScale: 100)
        servicePastShortDeadline()
        #expect(ticks == 1)
        #expect(!driver.isRunning)

        driver.sleep(until: 0.01, now: 0, timeScale: 1)
        driver.sleep(until: distantDeadline, now: 0, timeScale: 1)
        servicePastShortDeadline()
        #expect(ticks == 1, "the superseded short deadline must stay canceled")

        driver.sleep(until: 0.01, now: 0, timeScale: 1)
        driver.stop()
        servicePastShortDeadline()
        #expect(ticks == 1, "stopping the driver must cancel its pending deadline")

        driver.sleep(until: 0, now: 0, timeScale: 0)
        servicePastShortDeadline()
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
