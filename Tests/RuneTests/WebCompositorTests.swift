import Foundation
import RuneRef
import Testing
@testable import Rune

@MainActor
@Suite("Browser app compositor")
struct WebCompositorTests {
    private final class Probe: Compositor {
        typealias State = Int
        var drawsOwnContent = true
        var isAnimating = true
        var features = CompositorFeatures()
        var renderBody: (CompositorFrame<Int>) -> Void = { _ in }
        func render(frame: CompositorFrame<Int>) { renderBody(frame) }
    }

    private func host(_ probe: Probe, surface: NativeSurface? = nil) -> WebAppHost<Int> {
        let app = App(title: "Compositor", size: Vec2(16, 8), state: 0) { _, _ in
            let red: El<Int> = surface.map { nativeSurface($0, .stretch).size(8, 8) }
                ?? el().size(8, 8).bg(Color(r: 1, g: 0, b: 0, a: 1))
            return el().size(16, 8).bg(Color(r: 0, g: 0, b: 0, a: 1)).child(red)
        }.compositor(probe)
        return WebAppHost(app: app)
    }

    @Test func GPUDispatchesRepeatedSuppressedAndFallbackDraws() throws {
        let probe = Probe()
        let browser = WebBrowserSession(host(probe))
        var counts = [2, 0]
        var frames: [CompositorFrame<Int>] = []
        probe.renderBody = { frame in
            frames.append(frame)
            for _ in 0..<counts.removeFirst() { frame.drawUI() }
        }
        let first = try #require(try browser.renderFrame(at: 0))
        #expect(!first.instances.isEmpty)
        #expect(browser.uiPasses() == 2)
        let hidden = try #require(try browser.renderFrame(at: 0.5))
        #expect(hidden.instances.isEmpty && hidden.surfaces.isEmpty && hidden.materials.isEmpty)
        #expect(hidden.residentTracker == nil)
        #expect(hidden.clearColor == first.clearColor)
        #expect(browser.uiPasses() == 0)
        #expect(frames.map(\.dt) == [0, 0.5])
        #expect(frames[0].deviceKey == frames[1].deviceKey)
        #expect(frames[0].pixelSize.width == 16)
        #expect(throws: CompositorError.expiredFrame) { try frames[0].drawUI(withEffects: { _ in }) }

        probe.drawsOwnContent = false
        probe.renderBody = { frame in
            #expect(throws: CompositorError.nativeCompositorInBrowser) {
                try frame.drawUI(withEffects: { _ in })
            }
            #expect(frame.uiDrawCount == 0)
        }
        let restored = try #require(try browser.renderFrame(at: 1))
        #expect(browser.uiPasses() == 1)
        #expect(!restored.instances.isEmpty)
    }

    @Test func CPUReferenceAlsoHonorsVisibilityAndNativeFeatureErrors() throws {
        let probe = Probe()
        let surface = NativeSurface()
        let source = try ByteFrame(width: 1, height: 1, format: .rgba, color: .srgb,
                                   planes: [Data([255, 0, 0, 255])])
        try surface.pushBytes(source, frameId: 1)
        let browser = WebBrowserSession(host(probe, surface: surface))
        let hidden = try #require(try browser.frame(at: 0))
        #expect(hidden.pixel(x: 4, y: 4) == SIMD4<UInt8>(0, 0, 0, 255))
        probe.renderBody = { $0.drawUI() }
        let shown = try #require(try browser.frame(at: 1))
        #expect(shown.pixel(x: 4, y: 4) == SIMD4<UInt8>(255, 0, 0, 255))
        probe.features.insert(.requiresMetal)
        #expect(throws: CompositorError.nativeCompositorInBrowser) { try browser.renderFrame(at: 2) }
    }
}
