#if os(macOS)
import AppKit
import Foundation
import Metal
import RuneMotion
import Testing
@testable import Rune

struct MacOSHostFrameTests {
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
