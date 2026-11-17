import Foundation
import Testing
@testable import Rune

#if canImport(Metal)
@preconcurrency import Metal

@Suite("Metal Windfoil text")
struct MetalOutlineTextTests {
    private enum FixtureError: Error { case emptyGlyph }

    private func glyph(_ store: OutlineStore, id: UInt32 = 1) throws -> OutlineStore.Glyph {
        let commands: [OutlinePathCommand] = [
            .moveTo(SIMD2(0, 0)), .lineTo(SIMD2(12, 0)),
            .quadTo(SIMD2(16, 8), SIMD2(6, 13)), .lineTo(SIMD2(0, 0)), .close,
        ]
        let found = store.glyph(.init(font: 1, glyph: id)) {
            OutlineBuilder.build(commands: commands, upem: 16)
        }
        guard case .outline(let glyph) = found else { throw FixtureError.emptyGlyph }
        return glyph
    }

    @Test("GPU curve coverage matches integration at every pixel, including RGB blend on a backdrop")
    func drawsAnalyticCoverage() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let renderer = try MetalRenderer()
        let store = OutlineStore()
        let glyph = try glyph(store)
        let pen = SIMD2<Float>(4.25, 18.4)
        let zoom: Float = 1.25
        let geometry = GlyphOutline(pen: pen, scale: 1, zoom: zoom, record: glyph.record)
        let background = SIMD4<Float>(60, 90, 120, 255) / 255
        let ink = SIMD4<Float>(0.6, 0.45, 0.18, 0.75)
        var inst = RenderInstance(rect: geometry.rect(bbox: glyph.bbox), radii: SIMD4(pen.x, pen.y, 1, zoom),
                                  fill: ink, border: SIMD4(Float(glyph.record), 0, 0, 0),
                                  params: SIMD4(0, KIND_GLYPH, 0, 1.12))
        for lcd in [false, true] {
            inst.border.w = lcd ? 2 : 0
            let frame = RenderFrame(width: 32, height: 24, srgbBlend: true, clearColor: background,
                                    outlines: store.snapshot(requestsLCD: lcd), instances: [inst])
            let result = try renderer.renderOffscreen(frame)
            var peak = 0
            var inkPixels = 0
            for y in 0..<result.height {
                for x in 0..<result.width {
                    let local = (SIMD2(Float(x) + 0.5, pen.y - (Float(y) + 0.5)) - SIMD2(pen.x, 0)) / zoom
                    let at = (y * result.width + x) * 4
                    for channel in 0..<3 {
                        let shift: Float = lcd ? Float(channel - 1) / (3 * zoom) : 0
                        let coverage = OutlineCover.coverage(store: store, record: glyph.record,
                            local: local + SIMD2(shift, 0), scale: 1, halfWidth: 0.5 / zoom)
                        if channel == 0 && coverage > 0.5 { inkPixels += 1 }
                        let alpha = powf(coverage, inst.params.w)
                        let expected = (ink[channel] * alpha + background[channel] * (1 - ink.w * alpha)) * 255
                        peak = max(peak, abs(Int(result.rgba[at + channel]) - Int(expected.rounded())))
                    }
                }
            }
            #expect(inkPixels > 90)
            #expect(peak <= 2)
        }
        #expect(renderer.renderEngine.outlineText.lcdDrawBatches == 1)
        #expect(renderer.renderEngine.outlineText.uploadBytes == 16 * UInt64(OutlineStore.width))
    }

    @Test("Translucent layers blend outline glyphs as grayscale")
    func layerUsesSingleCoverage() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let renderer = try MetalRenderer()
        let store = OutlineStore()
        let glyph = try glyph(store)
        let bounds = SIMD4<Float>(0, 0, 24, 24)
        let inst = RenderInstance(rect: bounds, radii: SIMD4(3.25, 18.5, 1, 1), fill: SIMD4(repeating: 1),
                                  border: SIMD4(Float(glyph.record), 0, 0, 2), params: SIMD4(0, KIND_GLYPH, 0, 1))
        let frame = RenderFrame(width: 24, height: 24, srgbBlend: true, outlines: store.snapshot(requestsLCD: true),
            instances: [.beginLayer(bounds: bounds, clip: NO_CLIP, spec: LayerSpec(opacity: 0.5)), inst, .endLayer()])
        let result = try renderer.renderOffscreen(frame)
        let rgb = stride(from: 0, to: result.rgba.count, by: 4)
        #expect(rgb.contains { result.rgba[$0] > 100 })
        #expect(rgb.allSatisfy { result.rgba[$0] == result.rgba[$0 + 1] && result.rgba[$0] == result.rgba[$0 + 2] })
        #expect(renderer.renderEngine.outlineText.vectorDrawBatches > 0)
    }

    @Test("Uploads preserve outstanding readers and reload only appended rows")
    func uploadsAreRetainedAndIncremental() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let queue = try #require(device.makeCommandQueue())
        let gpu = MetalOutlineText(device: device)
        let store = OutlineStore()
        let row = Int(OutlineStore.width)
        var id: UInt32 = 1
        while (store.snapshot()?.usedTexels ?? 0) < row + 20 {
            _ = try glyph(store, id: id)
            id += 1
        }
        let original = try #require(store.snapshot())
        let first = try #require(queue.makeCommandBuffer())
        let oldTexture = try gpu.sync(original, readBy: first)
        _ = try glyph(store, id: id)
        let appended = try #require(store.snapshot())
        let second = try #require(queue.makeCommandBuffer())
        let newTexture = try gpu.sync(appended, readBy: second)
        #expect(oldTexture !== newTexture)
        second.commit()
        second.waitUntilCompleted()
        first.commit()
        first.waitUntilCompleted()
        let bytes = gpu.uploadBytes
        _ = try glyph(store, id: id + 1)
        let third = try #require(queue.makeCommandBuffer())
        let updated = try gpu.sync(try #require(store.snapshot()), readBy: third)
        #expect(updated === newTexture)
        #expect(gpu.uploadBytes - bytes == UInt64(row * 16))
        let repeated = try gpu.sync(original, readBy: third)
        #expect(repeated === updated)
        third.commit()
        third.waitUntilCompleted()
    }
}
#endif
