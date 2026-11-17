import Foundation
import Testing
@testable import Rune

@Suite("Color glyph painting")
struct ColorGlyphPaintTests {
    @Test func glyphsKeepTheirPixelsWhenTheImageAtlasGrows() {
        var packer = Runtime<Int>.ImageAtlasPacker()
        let width = 36
        let height = 42
        let center = (height / 2 * width + width / 2) * 4
        func bitmap(_ color: [UInt8]) -> GlyphAtlas.ColorGlyphEntry {
            var pixels = Data(count: width * height * 4)
            pixels.replaceSubrange(center..<(center + 4), with: color)
            return .init(pixelSize: SIMD2(width, height), bearingPx: .zero, rgba: pixels)
        }
        let red = bitmap([128, 0, 0, 128])
        let blue = bitmap([0, 0, 128, 128])
        let r = packer.insert(red)
        let b = packer.insert(blue)
        #expect(packer.atlas.height > 64)
        #expect(r != b)
        #expect(packer.insert(red) == r)
        let redIndex = ((Int(r.y) + height / 2) * packer.atlas.width + Int(r.x) + width / 2) * 4
        let blueIndex = ((Int(b.y) + height / 2) * packer.atlas.width + Int(b.x) + width / 2) * 4
        #expect(Array(packer.atlas.texels[redIndex..<(redIndex + 4)]) == [255, 0, 0, 128])
        #expect(Array(packer.atlas.texels[blueIndex..<(blueIndex + 4)]) == [0, 0, 255, 128])
    }

    #if canImport(CoreText) || os(Linux) || os(Windows)
    @Test func mixedLinePreservesEmojiColorsAndTextTint() throws {
        let font = TextSystem()
        #if !canImport(CoreText)
        let fontPath = ProcessInfo.processInfo.environment["RUNE_COLOR_EMOJI_FONT"]
        if let fontPath {
            HeadlessRunner.registerFonts([try Data(contentsOf: URL(fileURLWithPath: fontPath))])
        }
        // A supplied color font also verifies that process-local font registration reaches the shaper.
        let glyphs = font.shape(text: "🍎", style: TextStyle(size: 32), maxWidth: nil, pixelScale: 1).glyphs
        if fontPath != nil { try #require(glyphs.contains { $0.colorGlyphIndex != nil }) }
        else if !glyphs.contains(where: { $0.colorGlyphIndex != nil }) { return }
        #endif
        let runtime = Runtime(state: false, viewport: Vec2(150, 70), pixelScale: 1, textSystem: font) { _, _ in
            text("A🍎B").size(32).color(.rgba8(0, 0, 255))
        }
        let reference = runtime.frame(at: 0)
        #expect(reference.primitives.contains { $0.kind == .image })
        #expect(reference.primitives.contains { $0.kind == .glyph })
        let production = runtime.renderFrame(at: 0)
        #expect(production.instances.contains { $0.params.y == KIND_IMAGE })
        #expect(production.instances.contains { $0.params.y == KIND_GLYPH })
        func checkPixels(_ frame: Frame) {
            var redPixels = 0
            var bluePixels = 0
            for i in stride(from: 0, to: frame.rgba.count, by: 4) {
                let red = Int(frame.rgba[i]), green = Int(frame.rgba[i + 1]), blue = Int(frame.rgba[i + 2])
                if red > green + 60 && red > blue + 60 { redPixels += 1 }
                if blue > red + 60 && blue > green + 60 { bluePixels += 1 }
            }
            #expect(redPixels > 20)
            #expect(bluePixels > 20)
        }
        checkPixels(try RuneRef.render(reference))
        #if canImport(Metal) || canImport(CRuneOffscreenGL)
        do {
            checkPixels(try OffscreenGPURenderer().renderOffscreen(production))
        } catch OffscreenRenderError.unavailable {
            // Hosts without an offscreen device still exercise the paint stream and reference output.
        }
        #endif
    }
    #endif
}
