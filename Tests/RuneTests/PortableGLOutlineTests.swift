#if (os(macOS) || os(Linux) || os(Windows)) && canImport(CRuneOffscreenGL)
import Testing
@testable import Rune

@MainActor
@Suite("Portable GPU outline text")
struct PortableGLOutlineTests {
    @Test("Native text uses the GL outline shader during live scaling")
    func liveLabel() throws {
        let scale = Live<Float>(1)
        let runtime = Runtime<Live<Float>>(state: scale, viewport: Vec2(180, 72), pixelScale: 1) { value, _ in
            el().wFull().hFull().center().child(
                row().liveScale(value.binding).child(
                    text("Rune").font(TextStyle(size: 20).smoothing(.windfoilChromium)).color(.white)
                )
            )
        }
        runtime.clearColor = .black
        runtime.srgbBlend = true
        try withTestGLTarget { gl, capture in
            let first = gl.frame(runtime, at: 0)
            _ = try capture(first.width, first.height) { try gl.draw(first) }
            var moving: RenderFrame?
            for (step, zoom) in [Float(1.08), 1.14, 1.23, 1.31].enumerated() {
                scale.set(zoom)
                let frame = gl.frame(runtime, at: Double(step + 1) / 120)
                if frame.outlines != nil { moving = frame }
            }
            let frame = try #require(moving)
            let curved = frame.instances.filter { $0.params.y == KIND_GLYPH && $0.radii.w > 0 }
            #expect(curved.count >= 3)
            let pixels = try capture(frame.width, frame.height) { try gl.draw(frame) }
            #expect(stride(from: 0, to: pixels.rgba.count, by: 4).filter { pixels.rgba[$0] > 160 }.count > 80)
            #expect(runtime.textSystem.outlineRendererSupport == nil)
            #expect(!runtime.textSystem.glyphAtlas.defersOutlineMasks)
        }
    }

    @Test("Window, isolated layer, and LCD coverages match the pinned Rust painter")
    func outlineReadbacks() throws {
        try withTestGLTarget { gl, capture in
            let support = gl.prepareOutlineText(lcd: true)
            #expect(support.outlines)
            let cases: [(Float, Bool, Bool)] = [
                (0, false, false), (2, true, false), (2, false, false),
                (2, true, true), (0, false, true), (3, false, false)
            ]
            for (mode, lcd, layer) in cases {
                let frame = try CpuBootOutlineTests.frame(mode: mode, lcd: lcd, layer: layer)
                let rendered = try capture(frame.width, frame.height) { try gl.draw(frame) }
                var expected = CpuBootTarget(width: frame.width, height: frame.height)
                let scene = CpuBootScene(frame: frame, lcd: lcd && support.lcd)
                _ = try CpuBoot.paint(scene, into: &expected, threads: 1)
                // The CPU uses the Rust byte blender. Driver UNorm blend rounding varies by at
                // most two channel values across the clipped glyph and its translucent layer.
                let maxDifference = zip(expected.toRGBA8Tight(), rendered.rgba).reduce(0) {
                    max($0, abs(Int($1.0) - Int($1.1)))
                }
                #expect(maxDifference <= 2, "mode \(mode), lcd \(lcd), layer \(layer): \(maxDifference)")
            }
            var transparent = try CpuBootOutlineTests.frame(mode: 2, lcd: true, layer: false)
            transparent.clearColor = SIMD4(repeating: 0)
            transparent.instances[0].fill = SIMD4(repeating: 1)
            let gray = try capture(transparent.width, transparent.height) { try gl.draw(transparent) }
            let pixels = stride(from: 0, to: gray.rgba.count, by: 4)
            #expect(pixels.contains { gray.rgba[$0 + 3] > 128 })
            #expect(pixels.allSatisfy { gray.rgba[$0] == gray.rgba[$0 + 1] && gray.rgba[$0] == gray.rgba[$0 + 2] })
            // Slug is GPU-only. Check its ink and edge samples independently from Windfoil.
            let slug = try CpuBootOutlineTests.frame(mode: 1, lcd: false, layer: false)
            let result = try capture(slug.width, slug.height) { try gl.draw(slug) }
            let background = result.rgba[0]
            let reds = stride(from: 0, to: result.rgba.count, by: 4).map { result.rgba[$0] }
            #expect(reds.filter { $0 > background + 80 }.count > 80)
            #expect(reds.filter { $0 > background + 8 && $0 < background + 80 }.count > 8)
        }
    }

    @Test("Sparse R8 fills are resident on each page and survive replay")
    func pageLocalMaskFills() throws {
        let source = try CpuBootOutlineTests.frame(mode: 0, lcd: false, layer: false)
        let curves = try #require(source.outlines)
        let record = UInt32(try #require(source.instances.first).border.x)
        let blank = R8Atlas(width: 40, height: 28)
        func placement(_ x: UInt32, _ shift: Float) -> QueuedOutlineFill {
            QueuedOutlineFill(rect: SIMD4(x, 2, 15, 16),
                              fill: OutlineFillParams(record: record, scale: 1,
                                                      pen: SIMD2(0.75 + shift, 14.25)))
        }
        func plan(_ fills: [QueuedOutlineFill], base: R8Atlas? = nil, revision: UInt64 = 1) -> OutlineMaskPlan {
            OutlineMaskPlan(base: base ?? blank, curves: curves, fills: fills, baseGeneration: revision, epoch: 1)
        }
        func frame(_ plans: [OutlineMaskPlan], patch: GlyphAtlasPatch?) -> RenderFrame {
            var frame = RenderFrame(width: 80, height: 28, srgbBlend: true, glyphPages: plans.map(\.base),
                instances: (0..<2).map { page in
                    RenderInstance(rect: SIMD4(Float(40 * page), 0, 40, 28), fill: SIMD4(repeating: 1),
                                   params: SIMD4(0, KIND_GLYPH, Float(page), 1))
                })
            frame.glyphPageFills = plans
            frame.rawGlyphPageRevisions = plans.map(\.baseGeneration)
            frame.rawGlyphPagePatches = [nil, patch]
            return frame
        }
        let first = plan([placement(2, 0)])
        let other = plan([placement(4, 0.25)])
        let appended = plan([placement(4, 0.25), placement(21, 0.5)])
        var changed = blank
        changed.texels[24 * 40 + 28] = 188
        let distant = plan(other.fills, base: changed, revision: 2)
        changed.texels[8 * 40 + 2] = 155
        let adjacent = plan(other.fills, base: changed, revision: 3)
        changed.texels[8 * 40 + 3] = 46
        let gutter = plan(other.fills, base: changed, revision: 4)
        changed.texels[10 * 40 + 9] = 234
        let overlapping = plan(other.fills, base: changed, revision: 5)
        let cases: [(OutlineMaskPlan, Int, GlyphAtlasPatch?)] = [
            (other, 2, nil), (other, 2, nil), (appended, 3, nil), (other, 4, nil),
            (distant, 4, .init(fromRevision: 1, edges: SIMD4(28, 24, 29, 25))),
            (adjacent, 4, .init(fromRevision: 2, edges: SIMD4(2, 8, 4, 9))),
            (gutter, 5, .init(fromRevision: 3, edges: SIMD4(3, 8, 4, 9))),
            (overlapping, 6, .init(fromRevision: 4, edges: SIMD4(9, 10, 10, 11)))
        ]
        try withTestGLTarget { gl, capture in
            var lastPixels: [UInt8] = []
            for (second, expectedFills, patch) in cases {
                let packet = frame([first, second], patch: patch)
                if second === appended {
                    var moving = packet
                    moving.instances = source.instances
                    moving.outlines = curves
                    let count = gl.gpuMaskFillCount
                    _ = try capture(moving.width, moving.height) { try gl.draw(moving) }
                    #expect(gl.gpuMaskFillCount == count)
                }
                let result = try capture(packet.width, packet.height) { try gl.draw(packet) }
                let pages = [first.cpuAtlas(), second.cpuAtlas()]
                var difference = 0
                for y in 0..<28 {
                    for x in 0..<80 {
                        let expected = pages[x / 40].texels[y * 40 + x % 40]
                        difference = max(difference, abs(Int(result.rgba[(y * 80 + x) * 4]) - Int(expected)))
                    }
                }
                #expect(difference <= 1)
                #expect(gl.gpuMaskFillCount == expectedFills)
                lastPixels = result.rgba
            }
            let retained = frame([first, overlapping], patch: nil)
            gl.giveBackForWindowRest(all: true)
            let resumed = try capture(retained.width, retained.height) { try gl.draw(retained) }
            #expect(resumed.rgba == lastPixels)
            #expect(gl.gpuMaskFillCount == 8)
        }
    }

    @Test("Shader refusal is remembered and the ordinary mask program still draws")
    func rejectedOptionalProgram() throws {
        let context = try OffscreenGLContext()
        defer { context.close() }
        var attempts = 0
        let gl = try PortableGLRenderer(resolve: OffscreenGLContext.resolve, isGLES: OffscreenGLContext.isGLES) { name in
            if name == "outline.frag" {
                attempts += 1
                return "invalid outline program"
            }
            return try PortableGLRenderer.bundledShader(name)
        }
        defer { gl.close() }
        #expect(!gl.prepareOutlineText(lcd: true).outlines)
        #expect(!gl.prepareOutlineText(lcd: false).outlines)
        #expect(attempts == 1)
        let glyph = RenderInstance(rect: SIMD4(0, 0, 1, 1), fill: SIMD4(repeating: 1),
                                   params: SIMD4(0, KIND_GLYPH, 0, 1))
        let frame = RenderFrame(width: 1, height: 1, srgbBlend: true,
                                glyphs: .init(width: 1, height: 1, texels: [255]), instances: [glyph])
        let rendered = try context.withFramebuffer(width: 1, height: 1) { try gl.draw(frame) }
        #expect(rendered.rgba == [255, 255, 255, 255])
    }
}
#endif
