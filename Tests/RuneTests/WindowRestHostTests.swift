import Foundation
import Testing
import RuneMotion
@testable import Rune

@MainActor
@Suite("Window rest scheduling and cache residency")
struct WindowRestHostTests {
    @Test("A burst of presents coalesces; pressure advances the wake and hiding cancels it")
    func timerCoalescing() {
        var timer = WindowRestTimer()
        #expect(timer.step(.drew(now: 0, lowMemory: false)).1 == .arm(10))
        for i in 1...480 {
            #expect(timer.step(.drew(now: Double(i) / 240, lowMemory: false)).1 == .keep)
        }
        #expect(timer.step(.woke(now: 10)).1 == .arm(12))
        #expect(timer.step(.drew(now: 10.25, lowMemory: true)).1 == .arm(11.25))
        let idle = timer.step(.woke(now: 11.25))
        #expect(idle.0 == .giveBackUnused && idle.1 == .keep)
        #expect(timer.step(.woke(now: 12)).0 == nil)
        #expect(timer.step(.unseen).0 == .giveBackAll)
        #expect(timer.step(.unseen).0 == nil)
        #expect(timer.step(.drew(now: 15, lowMemory: false)).1 == .arm(25))
        let hidden = timer.step(.unseen)
        #expect(hidden.0 == .giveBackAll && hidden.1 == .cancel)
        #expect(timer.step(.woke(now: 25)).0 == nil)
    }

    #if canImport(AppKit) || canImport(UIKit)
    @Test("A sleeping Apple host receives the idle wake and a later hidden notification exactly once")
    func appleIdleWake() async throws {
        var gaveBack: [Bool] = []
        let host = AppleWindowRest { gaveBack.append($0) }
        let before = ProcessInfo.processInfo.systemUptime
        host.step(.drew(now: before - WindowRestMachine.restAfter + 0.03, lowMemory: false))
        #expect(gaveBack.isEmpty)
        let timeout = before + 2
        while gaveBack.isEmpty && ProcessInfo.processInfo.systemUptime < timeout {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gaveBack == [false])
        host.step(.unseen)
        host.step(.unseen)
        #expect(gaveBack == [false, true])
    }
    #endif

    @Test("Rest returns an empty image page without moving an image still on screen")
    func imageRest() {
        let runtime = Runtime<Void>(state: (), viewport: Vec2(8, 8), pixelScale: 1) { _, _ in el() }
        let image = RGBA8Atlas(width: 256, height: 128,
                               texels: [UInt8](repeating: 255, count: 256 * 128 * 4))
        runtime.beginPixelPaint()
        let firstUV = runtime.imagePacker.insert(image)
        runtime.finishPixelPaint()
        let revision = runtime.imagePacker.revision
        runtime.rest()
        #expect(runtime.imagePacker.revision == revision)
        runtime.beginPixelPaint()
        #expect(runtime.imagePacker.insert(image) == firstUV)
        runtime.finishPixelPaint()
        runtime.beginPixelPaint()
        runtime.finishPixelPaint()
        runtime.rest()
        #expect(runtime.imagePacker.atlas.width == 64 && runtime.imagePacker.atlas.height == 64)
        #expect(runtime.imagePacker.revision != revision)
    }

    @Test("Rest compacts old rewind identities and preserves replay and ongoing deltas")
    func rewindRest() {
        let runtime = Runtime<Void>(state: (), viewport: Vec2(8, 8), pixelScale: 1) { _, _ in el() }
        let recorder = RewindRecorder(windowSeconds: 0.5)
        runtime.rewindRecorder = recorder
        func sample(_ key: String, _ x: Float) -> RewindElementSnapshot {
            RewindElementSnapshot(key: key, rect: .fromXYWH(x, 0, 1, 1), opacity: 1)
        }
        recorder.recordFrame(at: 0, elements: (0..<512).map { sample("old-\($0)", Float($0)) })
        recorder.recordFrame(at: 1, elements: [sample("kept", 1)])
        recorder.recordFrame(at: 2, elements: [sample("kept", 2)])
        let before = recorder.estimatedBytes
        let clip = recorder.freeze()
        runtime.rest()
        #expect(recorder.estimatedBytes == before)
        recorder.resume()
        runtime.rest()
        #expect(recorder.estimatedBytes < before / 8)
        #expect(recorder.freeze().frames == clip.frames)
        recorder.resume()
        recorder.recordFrame(at: 2.1, elements: [sample("kept", 3)])
        #expect(recorder.freeze().frames.last?.elements == [sample("kept", 3)])
    }

    private func checkLayerRest(frame: (Runtime<Bool>, Double) -> RenderFrame,
                                draw: (RenderFrame) throws -> Frame,
                                rest: (Bool) -> Void, stats: () -> LayerStats) throws {
        let runtime = Runtime<Bool>(state: true, viewport: Vec2(32, 16), pixelScale: 1) { show, _ in
            let root = row().sizeFull().child(el().key("kept").size(16, 16).cache().bg(.white)) as El<Bool>
            return show ? root.child(el().key("gone").size(16, 16).cache().bg(.white)) : root
        }
        runtime.clearColor = .black
        _ = try draw(frame(runtime, 0))
        try #require(stats().cachedLayers == 2)
        runtime.update(at: 1) { state, _ in state = false }
        let baseline = try draw(frame(runtime, 1))
        #expect(baseline.pixel(x: 8, y: 8) == SIMD4(repeating: 255))
        #expect(baseline.pixel(x: 24, y: 8) == SIMD4(0, 0, 0, 255))
        for hidden in [false, true] {
            rest(hidden)
            #expect(stats().cachedLayers == 1)
            let next = frame(runtime, hidden ? 3 : 2)
            #expect(next.elidedLayers.count == 1)
            let recovered = try draw(next)
            #expect(recovered == baseline)
        }
    }

    #if canImport(Metal)
    @Test("Metal redraws the exact last scene after idle and hidden rest")
    func metalRest() throws {
        let renderer = try MetalRenderer()
        try checkLayerRest(frame: { renderer.frame($0, at: $1) },
                           draw: { try renderer.renderOffscreen($0) },
                           rest: renderer.giveBackForWindowRest(all:), stats: renderer.layerStats)
    }
    #endif

    #if (os(macOS) || os(Linux) || os(Windows)) && canImport(CRuneOffscreenGL)
    @Test("OpenGL redraws the exact last scene after idle and hidden rest")
    func glRest() throws {
        try withTestGLTarget { renderer, capture in
            try checkLayerRest(frame: { renderer.frame($0, at: $1) },
                               draw: { frame in
                                   try capture(frame.width, frame.height) { try renderer.draw(frame) }
                               }, rest: renderer.giveBackForWindowRest(all:), stats: renderer.layerStats)
        }
    }
    #endif
}
