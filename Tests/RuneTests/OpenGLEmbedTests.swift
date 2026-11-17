#if canImport(CRuneOffscreenGL) && (os(macOS) || os(Windows) || os(Linux))
import CRuneOffscreenGL
import Testing
import Rune

@Suite("Embedded OpenGL windows")
struct OpenGLEmbedTests {
    @Test @MainActor
    func hostDrawsIntoCallersFramebufferAndRedrawsAfterResize() throws {
        var diagnostics = [CChar](repeating: 0, count: 512)
        let context = try #require(rune_offscreen_gl_open(&diagnostics, 512))
        defer { rune_offscreen_gl_close(context) }
        #if os(Linux)
        let gles = true
        #else
        let gles = false
        #endif
        let renderer = try OpenGLLayerRenderer(resolve: rune_offscreen_gl_proc, isGLES: gles)
        defer { renderer.close() }
        let spec = AppSpec(size: Vec2(24, 16), state: false) { on, _ in
            el().sizeFull().cache().bg(on ? Color(r: 0, g: 1, b: 0, a: 1) : Color(r: 1, g: 0, b: 0, a: 1))
        }
        let host = try LayerHost(spec: spec, scale: 1, config: EmbedHostConfig(initialSize: spec.size))
        func center(_ width: Int, _ height: Int) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let count = bytes.count
            try #require(rune_offscreen_gl_read(context, &bytes, count) != 0)
            let i = (height / 2 * width + width / 2) * 4
            return Array(bytes[i..<i + 4])
        }

        try #require(rune_offscreen_gl_bind(context, 24, 16) != 0)
        #expect(try renderer.draw(host, at: 0).drew)
        #expect(try center(24, 16) == [255, 0, 0, 255])
        #expect(try !renderer.draw(host, at: 0.010).drew)

        host.update { on, _ in on = true }
        host.resize(viewport: Vec2(17, 11))
        try #require(rune_offscreen_gl_bind(context, 17, 11) != 0)
        #expect(try renderer.draw(host, at: 0.020).drew)
        #expect(try center(17, 11) == [0, 255, 0, 255])
        #expect(try renderer.draw(host, at: 0.030, forceRedraw: true).drew)
        #expect(renderer.layerStats().hits > 0)

        let replacement = try OpenGLLayerRenderer(resolve: rune_offscreen_gl_proc, isGLES: gles)
        defer { replacement.close() }
        replacement.setLayerCacheBudget(0)
        #expect(try replacement.draw(host, at: 0.040).drew)
        #expect(try center(17, 11) == [0, 255, 0, 255])
        #expect(replacement.layerStats().cachedBytes == 0)
        #expect(try renderer.draw(host, at: 0.050).drew)
        #expect(try center(17, 11) == [0, 255, 0, 255])
    }
}
#endif
