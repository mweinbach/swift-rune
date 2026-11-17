import Testing
@testable import Rune

#if os(macOS) || os(Linux) || os(Windows)
@Suite("Runtime glyph pixels")
struct RuntimeGlyphPixelsTests {
    @Test(arguments: [false, true])
    func centeredHeadingMatchesGPU(systemDark: Bool) throws {
        let ink = Color.rgba8(219, 105, 67)
        let background = systemDark ? Color.rgba8(24, 26, 29) : Color.rgba8(247, 245, 242)
        let runtime = Runtime(state: (), viewport: Vec2(160, 64), pixelScale: 1) { _, _ in
            col().sizeFull().center().bg(background)
                .child(text("Lights on").key("heading").font(Tok.Typography.title).w(79.5).color(ink))
        }
        runtime.systemDark = systemDark
        runtime.fontSmoothing = .windfoilChromium
        runtime.srgbBlend = true

        let reference = runtime.frame(at: 0)
        let renderer = try OffscreenGPURenderer()
        let production = try renderer.frame(runtime, at: 0)
        let bounds = try #require(runtime.lastElements.first { $0.key == "heading" }?.target)
        #expect(bounds[0] == 40.25)
        let glyphs = reference.primitives.filter { $0.kind == .glyph }
        let instances = production.instances.filter { $0.params.y == KIND_GLYPH }
        try #require(!glyphs.isEmpty && glyphs.count == instances.count)
        #expect(reference.glyphs.texels.contains { $0 > 0 && $0 < 255 })
        let color = ink.simd4(srgb: true)
        let luma = 0.2126 * color.x + 0.7152 * color.y + 0.0722 * color.z
        let exponent = 1.12 + (0.45 - 1.12) * luma
        #expect(glyphs.allSatisfy { abs($0.params.w - exponent) < 0.00001 })
        #expect(zip(glyphs, instances).allSatisfy { abs($0.params.w - $1.params.w) < 0.00001 })

        let cpu = try RuneRef.render(reference)
        let gpu = try renderer.renderOffscreen(production)
        try #require(cpu.width == gpu.width && cpu.height == gpu.height)
        let backgroundPixel = cpu.pixel(x: 0, y: 0)
        let hasVisibleInk = (0..<cpu.height).contains { y in
            (0..<cpu.width).contains { x in cpu.pixel(x: x, y: y) != backgroundPixel }
        }
        #expect(hasVisibleInk)
        var maxDelta = 0
        var worstPixel = 0
        for (index, channels) in zip(cpu.rgba, gpu.rgba).enumerated() {
            let delta = abs(Int(channels.0) - Int(channels.1))
            if delta > maxDelta {
                maxDelta = delta
                worstPixel = index / 4
            }
        }
        #expect(maxDelta <= 2, "Pixel (\(worstPixel % cpu.width), \(worstPixel / cpu.width))")
    }
}
#endif
