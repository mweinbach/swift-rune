#if canImport(Metal) || canImport(CRuneOffscreenGL)
import RuneRef
import Testing
@testable import Rune

@Suite("GPU snapshots with a custom compositor")
struct HeadlessGPUCompositorTests {
    private final class MarkerCompositor: Compositor {
        typealias State = Int
        var marks: [UInt32] = []
        var deltas: [Float] = []
        var failure: (any Error)?

        func render(frame: CompositorFrame<Int>) {
            deltas.append(frame.dt)
            #if canImport(Metal)
            #expect(frame.targetTexture != nil && frame.commandBuffer != nil)
            #else
            #expect(frame.openGL != nil)
            #endif
            do {
                try frame.drawUI(withEffects: { self.marks.append($0.site.mark) })
            } catch {
                failure = error
            }
        }
    }

    @Test("A GPU capture exposes a graphics target and visits authored effect slots")
    func compositedSnapshot() throws {
        let compositor = MarkerCompositor()
        let app = App(title: "Offscreen", size: Vec2(16, 8), state: 0) { _, _ in
            el().size(16, 8).bg(Color(r: 1, g: 0, b: 0, a: 1))
                .child(el().size(8, 8).effect(70_000))
        }.compositor(compositor)
        var args = ToolingArgs()
        args.pixelScale = 1
        args.requireGPU = true
        let output = try HeadlessRunner.run(app, args: args)
        if let failure = compositor.failure { throw failure }
        #expect(compositor.marks == [70_000])
        #expect(compositor.deltas == [0])
        #expect(output.finalFrame.pixel(x: 12, y: 4) == SIMD4<UInt8>(255, 0, 0, 255))

        #if os(macOS) || os(Linux) || os(Windows)
        let desktop = VirtualDesktop(displays: [VirtualDisplay(id: 1, frame: [0, 0, 32, 16], scale: 1, primary: true)])
        let window = DesktopWindow(app: app, scale: 1)
        compositor.marks.removeAll()
        compositor.deltas.removeAll()
        _ = try VirtualDesk.runHeadlessDesktop(
            members: [window], args: args, options: app.runOptions, desktop: desktop,
            backdropRGBA: [UInt8](repeating: 0, count: 32 * 16 * 4), width: 32, height: 16
        )
        if let failure = compositor.failure { throw failure }
        #expect(compositor.marks == [70_000])
        #expect(compositor.deltas == [0])
        #endif
    }
}
#endif
