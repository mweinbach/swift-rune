import Testing
@testable import Rune
#if os(Windows)
import WinSDK
#endif

@Suite("Windows text parity")
struct WindowsTextParityTests {
    @Test func skiaTablesMatchPinnedRust() {
        // FNV-1a of every byte returned by skia_gamma::table in 842c28c2.
        let expected: [UInt64] = [0x4c4ba693f0016fdd, 0x2ed719c2158356ab, 0x7582aa233ba93112, 0x560ec9372636fd51,
                                  0x11222f1e848bea8d, 0xf79e9d375466031c, 0x5f7d2c76284c70a2, 0xe083b2271608fc7e]
        for (bucket, table) in WindowsTextGamma.tables.enumerated() {
            #expect(table.count == 256)
            let hash = table.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
            #expect(hash == expected[bucket])
        }
        #expect(WindowsTextGamma.bucket(SIMD4(1, 0, 0, 0), encoded: false) == 1)
        #expect(WindowsTextGamma.bucket(SIMD4(0, 1, 0, 0.25), encoded: false) == 5)
        #expect(WindowsTextGamma.bucket(SIMD4(0.147, 0.281, 0.451, 1), encoded: false) == 4)
    }

    #if os(Windows)
    @Test @MainActor func nativeClearTypeDrawsColorEdgesWhenTheGPUCanBlendChannels() throws {
        let context = try OffscreenGLContext()
        defer { context.close() }
        let renderer = try PortableGLRenderer(resolve: OffscreenGLContext.resolve, isGLES: OffscreenGLContext.isGLES)
        defer { renderer.close() }
        let support = renderer.prepareOutlineText(lcd: true)
        func coverage(_ rgba: [UInt8]) -> (ink: Int, colored: Int) {
            var ink = 0, colored = 0
            for i in stride(from: 0, to: rgba.count, by: 4) {
                if rgba[i] > 100 { ink += 1 }
                if abs(Int(rgba[i]) - Int(rgba[i + 2])) > 3 { colored += 1 }
            }
            return (ink, colored)
        }
        for smoothing: FontSmoothing in [.directWrite, .clearType] {
            let runtime = Runtime<Int>(state: 0, viewport: Vec2(180, 68), pixelScale: 1) { _, _ in
                text("DirectWrite").font(TextStyle(size: 21).smoothing(smoothing)).color(.white)
            }
            runtime.clearColor = .black
            runtime.srgbBlend = true
            let frame = renderer.frame(runtime, at: 0)
            let lcd = smoothing == .clearType && support.lcd
            #expect(frame.instances.contains { $0.params.y == KIND_GLYPH && $0.radii.x == (lcd ? 1 : 0) })
            #expect((frame.outlines?.requestsLCD ?? false) == lcd)
            let rendered = try context.withFramebuffer(width: frame.width, height: frame.height) { try renderer.draw(frame) }
            let gpu = coverage(rendered.rgba)
            #expect(gpu.ink > 20)
            #expect((gpu.colored > 0) == lcd)
            var cpuFrame = frame
            if smoothing == .clearType && !support.lcd {
                // CpuBoot can paint each coverage channel on every Windows adapter.
                runtime.textSystem.outlineRendererSupport = { _ in (true, true) }
                cpuFrame = runtime.renderFrame(at: 0.1)
            }
            let cpuLCD = smoothing == .clearType
            #expect((cpuFrame.outlines?.requestsLCD ?? false) == cpuLCD)
            var target = CpuBootTarget(width: cpuFrame.width, height: cpuFrame.height)
            _ = try CpuBoot.paint(CpuBootScene(frame: cpuFrame, lcd: cpuLCD), into: &target, threads: 1)
            let cpu = coverage(target.toRGBA8Tight())
            #expect(cpu.ink > 20)
            #expect((cpu.colored > 0) == cpuLCD)
        }
    }

    @Test func directWriteCorrectsTheNativeAtlasOncePerInk() throws {
        let system = TextSystem()
        let atlas = system.glyphAtlas
        let ink = SIMD4<Float>(0, 0, 0, 1)
        for smoothing: FontSmoothing in [.directWrite, .clearType] {
            let shape = system.shape(text: "Windows", style: TextStyle(size: 19, fontSmoothing: smoothing),
                                     maxWidth: nil, pixelScale: 1)
            let glyph = try #require(shape.glyphs.first(where: { $0.windowsMask != nil }))
            let raw = try #require(atlas.pageData(Int(glyph.atlasPage)))
            let dark = system.glyphMask(for: glyph, ink: ink, encoded: false)
            let light = system.glyphMask(for: glyph, ink: SIMD4(repeating: 1), encoded: true)
            #expect(dark.gamma == 1 && light.gamma == 1)
            #expect(dark.uv != light.uv || dark.page != light.page)
            let allocated = atlas.rasterized
            let repeated = system.glyphMask(for: glyph, ink: SIMD4(0, 0, 0, 0.4), encoded: true)
            #expect(repeated.uv == dark.uv && repeated.page == dark.page)
            #expect(atlas.rasterized == allocated)
            let w = atlas.atlas.width, h = atlas.atlas.height
            func origin(_ uv: SIMD4<Float>) -> Int {
                Int((uv.y * Float(h)).rounded()) * w + Int((uv.x * Float(w)).rounded())
            }
            let width = Int(((glyph.uv.z - glyph.uv.x) * Float(w)).rounded())
            let height = Int(((glyph.uv.w - glyph.uv.y) * Float(h)).rounded())
            let rect = SIMD4<Float>(0, 0, Float(width), Float(height))
            if smoothing == .clearType {
                let rgb = try #require(system.lcdMask(for: glyph, rect: rect, ink: ink, encoded: false))
                let corrected = try #require(atlas.pageData(Int(rgb.page)))
                let source = try #require(glyph.windowsMask?.rgb?())
                let tile = try #require(glyph.windowsMask?.bounds)
                let left = Int((glyph.uv.x * Float(w)).rounded()) - Int(tile.x)
                let top = Int((glyph.uv.y * Float(h)).rounded()) - Int(tile.y)
                var coloredEdges = false
                for y in 0..<height {
                    for x in 0..<width {
                        let i = 3 * ((top + y) * Int(tile.z) + left + x)
                        coloredEdges = coloredEdges || source[i] != source[i + 1] || source[i + 1] != source[i + 2]
                        for c in 0..<3 {
                            #expect(corrected[origin(rgb.uv) + y * w + x * 3 + c] == WindowsTextGamma.tables[0][Int(source[i + c])])
                        }
                    }
                }
                #expect(coloredEdges)
                #expect(system.lcdMask(for: glyph, rect: rect * 2, ink: ink, encoded: false) == nil)
            } else {
                #expect(system.lcdMask(for: glyph, rect: rect, ink: ink, encoded: false) == nil)
            }
            for (sample, bucket) in [(dark, 0), (light, 7)] {
                let corrected = try #require(atlas.pageData(Int(sample.page)))
                var antialiased = false
                for y in 0..<height {
                    for x in 0..<width {
                        let v = raw[origin(glyph.uv) + y * w + x]
                        if v > 0 && v < 255 { antialiased = true }
                        #expect(corrected[origin(sample.uv) + y * w + x] == WindowsTextGamma.tables[bucket][Int(v)])
                    }
                }
                #expect(antialiased)
            }
        }
    }

    @Test func systemDictionarySelectsWithinThaiAndPreservesUTF8Offsets() async throws {
        let text = "😀ภาษาไทย!"
        // icu_segmenter 2.3.0 new_for_non_complex_scripts at the upstream pin.
        #expect(WindowsWordSegmenter.ruleBasedBoundaries(in: text) == [4, 25, 26])
        #expect(WindowsWordSegmenter.ruleBasedBoundaries(in: "ภาษาພາສາ") == [12, 24])
        #expect(WindowsWordSegmenter.ruleBasedBoundaries(in: "漢字字・ですカナก") == [9, 12, 18, 24, 27])
        #expect(WindowsWordSegmenter.ruleBasedBoundaries(in: "we're") == [5])
        // Server Core and Windows 10 before 1903 support only the rule-based path.
        guard let icu = "icu.dll".withCString(encodedAs: UTF16.self, { LoadLibraryExW($0, nil, DWORD(LOAD_LIBRARY_SEARCH_SYSTEM32)) }) else { return }
        defer { _ = FreeLibrary(icu) }
        WindowsWordSegmenter.firstFramePresented()
        var ends = WindowsWordSegmenter.boundaries(in: text)
        for _ in 0..<200 where ends == nil {
            try await Task.sleep(for: .milliseconds(10))
            ends = WindowsWordSegmenter.boundaries(in: text)
        }
        try #require(ends == [4, 16, 25, 26])
        let selected = SelectionMath.unitRange(in: text, at: 19, unit: .word)
        #expect(selected.0 == 16 && selected.1 == 25)
        let all = Set([0, 4, 7, 10, 13, 16, 19, 22, 25, 26])
        #expect(WindowsWordSegmenter.visualWordBreaks(all, in: text) == Set([0, 4, 16, 25, 26]))
        #expect(WindowsWordSegmenter.visualWordBreaks(Set([0, 3, 6]), in: "៖៖") == Set([0, 6]))
    }
    #endif
}
