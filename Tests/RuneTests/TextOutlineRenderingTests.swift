import Testing
@testable import Rune

#if canImport(CoreText) && canImport(Metal)
import CoreText
import Metal

@Suite("Native outline text placement")
struct TextOutlineRenderingTests {
    @Test("Moving and landing text use the same font record as the resting mask")
    @MainActor func liveLabel() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try MetalRenderer(device: device)
        let zoom = Live<Float>(1)
        let runtime = Runtime<Live<Float>>(state: zoom, viewport: Vec2(240, 100), pixelScale: 2) { zoom, _ in
            col().wFull().hFull().center().child(
                row().liveScale(zoom.binding).child(text("Office 🦊").font(TextStyle(size: 19).smoothing(.windfoilChromium)).color(.white))
            )
        }
        runtime.clearColor = .black
        runtime.srgbBlend = true
        let initial = renderer.frame(runtime, at: 0)
        #expect(initial.instances.contains { $0.params.y == KIND_GLYPH && $0.radii.w == 0 })
        #expect(initial.instances.contains { $0.params.y == KIND_IMAGE })
        let initialPixels = try renderer.renderOffscreen(initial)
        #expect(initialPixels.rgba.contains(255))
        var time = 0.0
        var lastMoving: RenderFrame?
        for scale: Float in [1.08, 1.14, 1.23, 1.31] {
            zoom.set(scale)
            time += 1.0 / 120
            let frame = renderer.frame(runtime, at: time)
            if frame.outlines != nil { lastMoving = frame }
        }
        let moving = try #require(lastMoving)
        let records = moving.instances.filter { $0.params.y == KIND_GLYPH && $0.radii.w > 0 }
        #expect(records.count >= 3)
        // The inherited live zoom at 1.31 rasterizes at the nearest quarter octave (sqrt(2)).
        #expect(records.allSatisfy { abs($0.radii.w - 1.31 / Float(2).squareRoot()) < 0.001 })
        let curves = try #require(moving.outlines)
        #expect(records.allSatisfy { $0.border.x > 0 && Int($0.border.x) < curves.usedTexels })
        #expect(moving.instances.contains { $0.params.y == KIND_IMAGE })
        let pixels = try renderer.renderOffscreen(moving)
        let whiteInk = stride(from: 0, to: pixels.rgba.count, by: 4).filter {
            pixels.rgba[$0] > 180 && pixels.rgba[$0 + 1] > 180 && pixels.rgba[$0 + 2] > 180
        }.count
        #expect(whiteInk > 100)
        #expect(renderer.renderEngine.outlineText.uploadBytes > 0)
        var rest = moving
        for i in 1...20 {
            time += i == 1 ? 0.3 : 1.0 / 60
            rest = renderer.frame(runtime, at: time)
        }
        #expect(rest.instances.allSatisfy { $0.params.y != KIND_GLYPH || $0.radii.w == 0 })
        #expect(rest.instances.contains { $0.params.y == KIND_GLYPH })
        _ = try renderer.renderOffscreen(rest)
    }

    @Test("Steady RGB ink reuses a three-texel mask on an opaque Metal target")
    @MainActor func residentRGB() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try MetalRenderer(device: device)
        let runtime = Runtime<Int>(state: 0, viewport: Vec2(72, 40), pixelScale: 1) { _, _ in
            el().wFull().hFull().center().child(text("A").font(TextStyle(size: 23).smoothing(.windfoilRgb)).color(.black))
        }
        runtime.clearColor = .white
        runtime.srgbBlend = true
        let frame = renderer.frame(runtime, at: 0)
        if !renderer.renderEngine.outlineSupport(format: .bgra8Unorm, lcd: true).lcd {
            #expect(frame.instances.allSatisfy { $0.params.y != KIND_GLYPH || $0.radii.x == 0 })
            return
        }
        let first = try #require(frame.instances.first { $0.params.y == KIND_GLYPH })
        #expect(first.radii == SIMD4(1, 0, 0, 0))
        #expect(frame.outlines?.requestsLCD == true)
        let pixels = try renderer.renderOffscreen(frame)
        let colored = stride(from: 0, to: pixels.rgba.count, by: 4).filter {
            abs(Int(pixels.rgba[$0]) - Int(pixels.rgba[$0 + 2])) > 4
        }
        #expect(colored.count > 12)
        let placed = runtime.textSystem.glyphAtlas.rasterized
        let warm = renderer.frame(runtime, at: 0.016)
        let second = try #require(warm.instances.first { $0.params.y == KIND_GLYPH })
        #expect(first.uv == second.uv)
        #expect(runtime.textSystem.glyphAtlas.rasterized == placed)
        #expect(try renderer.renderOffscreen(warm).rgba == pixels.rgba)
    }

    @Test("Live zoom rounds the original shaped line's baseline at its raster bucket")
    @MainActor func originalLayoutAtZoom() throws {
        let renderer = try MetalRenderer(device: try #require(MTLCreateSystemDefaultDevice()))
        let zoom = Live<Float>(1)
        let style = TextStyle(size: 16.25, weight: 600).smoothing(.windfoilChromium)
        let runtime = Runtime<Live<Float>>(state: zoom, viewport: Vec2(180, 48), pixelScale: 1) { state, _ in
            el().wFull().hFull().child(text("Ag").font(style).origin(0, 0).liveScale(state.binding))
        }
        _ = renderer.frame(runtime, at: 0)
        let layout = runtime.textSystem.shape(text: "Ag", style: style, maxWidth: nil, pixelScale: 1, emitGlyphs: false)
        let original = try #require(layout.lineBaselinesPx.first)
        zoom.set(1.3)
        let moving = renderer.frame(runtime, at: 0.016)
        let first = try #require(moving.instances.first { $0.params.y == KIND_GLYPH && $0.radii.w > 0 })
        let bucket = Float(2).squareRoot()
        #expect(abs(first.radii.y - (original * bucket).rounded() * 1.3 / bucket) < 0.001)
    }

    @Test("A refused outline renderer uses the readable coverage mask during zoom")
    @MainActor func refusal() throws {
        let zoom = Live<Float>(1)
        let runtime = Runtime<Live<Float>>(state: zoom, viewport: Vec2(180, 80), pixelScale: 1) { zoom, _ in
            el().liveScale(zoom.binding).child(text("Aperture").font(TextStyle(size: 19).smoothing(.slug)))
        }
        var requests = 0
        runtime.textSystem.outlineRendererSupport = { _ in requests += 1; return (false, false) }
        _ = runtime.renderFrame(at: 0)
        zoom.set(1.16)
        let frame = runtime.renderFrame(at: 0.016)
        #expect(requests > 0)
        #expect(frame.outlines == nil)
        #expect(frame.instances.contains { $0.params.y == KIND_GLYPH && $0.radii.w == 0 })
        #expect(frame.glyphs.texels.contains { $0 > 100 })
    }

    @Test("A pinned full store survives a flight, then repaints retained text after reuse")
    @MainActor func fullStore() throws {
        let renderer = try MetalRenderer(device: try #require(MTLCreateSystemDefaultDevice()))
        let runtime = Runtime<Int>(state: 0, viewport: Vec2(96, 42), pixelScale: 1) { _, _ in
            el().wFull().hFull().center().child(text("Atlas").font(TextStyle(size: 19).smoothing(.windfoilChromium)).color(.black))
        }
        runtime.clearColor = .white
        let frame = renderer.frame(runtime, at: 0)
        let atlas = runtime.textSystem.glyphAtlas
        let pixels = try renderer.renderOffscreen(frame)
        let before = try #require(atlas.withOutlineStore { $0.snapshot() })
        let oversized = OutlineStore.Key(font: .max, glyph: .max)
        let found = atlas.withOutlineStore { store in
            store.glyph(oversized) {
                // One header larger than a whole store cannot be published, even to an empty atlas.
                BuiltOutline(texels: Array(repeating: .zero, count: Int(OutlineStore.width * OutlineStore.maxRows)), bbox: .zero)
            }
        }
        #expect(found == .full)
        #expect(atlas.beginFrame(pinnedMask: 1, pinOutlines: true) == false)
        #expect(atlas.withOutlineStore { $0.generation } == before.generation)
        runtime.beginPaintGlyphFrame(pinnedMask: 0)
        #expect(atlas.withOutlineStore { $0.generation } == before.generation + 1)
        let repainted = renderer.frame(runtime, at: 0.016)
        #expect(atlas.withOutlineStore { $0.hasRecords })
        #expect(try renderer.renderOffscreen(repainted).rgba == pixels.rgba)
        #expect(try renderer.renderOffscreen(frame).rgba == pixels.rgba)
    }
}
#endif
