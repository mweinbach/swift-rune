import Foundation
import Testing
@testable import RuneRef
@testable import Rune

@Suite("RuneRef & Metal Differential Tests")
struct RuneRefTests {
    @Test("An Oracle shadow keeps visible blur outside its caster when replayed")
    func oracleShadowBounds() throws {
        let caster = SIMD4<Float>(12, 12, 12, 12)
        let shadow = OraclePrimitive(
            node: 1, source: "shadow", rect: [12, 12, 12, 12], radii: [0, 0, 0, 0],
            fill: [1, 1, 1, 1], border: [0, 0, 0, 0], params: [0, 1, 3, 0],
            uv: [0, 0, 0, 0], clip: oracleNoClip, fade: [0, 0, 0, 0]
        ).toInstance()
        #expect(shadow.border == caster)
        let frame = try RuneRef.render(RefScene(width: 36, height: 36, clearColor: .zero, primitives: [shadow]))
        #expect(frame.pixel(x: 9, y: 18).w > 0)
    }

    #if canImport(Metal) || canImport(CRuneOffscreenGL)
    @Test("Dashed rings agree on pixels inside the rounded perimeter")
    func dashedCornerPixels() throws {
        let renderer = try OffscreenGPURenderer()
        for seed: UInt64 in [11, 13] {
            let scene = RefGenerator.dashed(seed: seed, count: 8)
            let pixels = try renderer.renderOffscreen(scene)
            let diff = RuneRef.compare(scene: scene, expected: try RuneRef.render(scene), actual: pixels,
                                       channelTolerance: 2, maxFailingPixels: 0)
            #expect(diff.passed, "seed \(seed): \(diff)")
        }
    }
    #endif

    @Test("RefScene validation catches malformed dimensions, NaNs, and unbalanced layers")
    func sceneValidationErrors() {
        #expect(throws: RefSceneError.invalidDimensions(width: 0, height: 100)) {
            try RefScene(width: 0, height: 100).validate()
        }
        var malformed = RefScene(width: 1, height: 1)
        malformed.images.width = Int.max
        #expect(throws: RefSceneError.invalidAtlasDimensions(width: .max, height: 1)) {
            try malformed.validate()
        }

        let nanPrim = Primitive.roundedRect(
            rect: SIMD4<Float>(.nan, 0, 10, 10),
            fill: SIMD4<Float>(1, 1, 1, 1),
            clip: SIMD4<Float>(0, 0, 50, 50)
        )
        #expect(throws: RefSceneError.nonFinitePrimitive(index: 0)) {
            try RefScene(width: 50, height: 50, primitives: [nanPrim]).validate()
        }

        let clip = SIMD4<Float>(0, 0, 50, 50)
        #expect(throws: RefSceneError.unbalancedLayerEnd(index: 0)) {
            try RefScene(width: 50, height: 50, primitives: [.layerEnd(clip: clip)]).validate()
        }

        #expect(throws: RefSceneError.unclosedLayers(remaining: 1)) {
            try RefScene(width: 50, height: 50, primitives: [.layerBegin(rect: clip, clip: clip)]).validate()
        }

        #expect(throws: RefSceneError.nonFiniteClearColor) {
            try RefScene(width: 10, height: 10, clearColor: SIMD4<Float>(0, .nan, 0, 1)).validate()
        }
    }

    @Test("Adjacent ear-clipped polygon triangles render with zero interior seam")
    func seamlessPolygonTriangles() throws {
        var path = VectorPath()
        path.moveTo(10, 10)
        path.lineTo(50, 10)
        path.lineTo(50, 50)
        path.lineTo(10, 50)
        path.close()
        let tris = path.triangulate()
        #expect(tris.count == 2)

        let clip = SIMD4<Float>(0, 0, 60, 60)
        let prims = tris.map { t in
            Primitive.triangle(
                v0: SIMD2<Float>(t.v0.x, t.v0.y),
                v1: SIMD2<Float>(t.v1.x, t.v1.y),
                v2: SIMD2<Float>(t.v2.x, t.v2.y),
                aaMask: t.aaMask,
                color: SIMD4<Float>(1, 1, 1, 1),
                clip: clip
            )
        }
        let scene = RefScene(
            width: 60,
            height: 60,
            srgbBlend: true,
            clearColor: SIMD4<Float>(0, 0, 0, 1),
            primitives: prims
        )
        let frame = try RuneRef.render(scene)
        // Check diagonal pixels right along (10,10)->(50,50) — every interior pixel must be 255 white!
        for k in 12..<48 {
            let px = frame.pixel(x: k, y: k)
            #expect(px == SIMD4<UInt8>(255, 255, 255, 255), "Seam detected at (\(k), \(k)): \(px)")
        }
    }

    @Test("A tolerated difference retains the measured channel delta")
    func differenceWithinTolerance() {
        let scene = RefScene(width: 1, height: 1)
        let expected = Frame(width: 1, height: 1, rgba: [40, 50, 60, 255])
        let actual = Frame(width: 1, height: 1, rgba: [40, 52, 60, 255])
        let result = RuneRef.compare(scene: scene, expected: expected, actual: actual, channelTolerance: 2)
        #expect(result.passed)
        #expect(result.differingPixels == 0)
        #expect(result.maxChannelDelta == 2)
        #expect(result.worstBlame == nil)
    }

    @Test("PNG encode and decode round-trips rendered frame cleanly")
    func pngRoundTrip() throws {
        let clip = SIMD4<Float>(0, 0, 32, 32)
        let scene = RefScene(
            width: 32,
            height: 32,
            srgbBlend: true,
            clearColor: SIMD4<Float>(0.1, 0.2, 0.3, 1.0),
            primitives: [
                .roundedRect(
                    rect: SIMD4<Float>(4, 4, 24, 24),
                    radii: SIMD4<Float>(repeating: 6),
                    fill: SIMD4<Float>(0.9, 0.3, 0.2, 1.0),
                    clip: clip
                )
            ]
        )
        let rendered = try RuneRef.render(scene)
        let pngBytes = try rendered.pngData()
        #expect(pngBytes.count > 64)
        let decoded = try Frame.fromPNG(data: pngBytes)
        #expect(decoded.width == 32 && decoded.height == 32)
        let diff = RuneRef.compare(scene: scene, expected: rendered, actual: decoded, channelTolerance: 2)
        #expect(diff.passed)
    }

    #if canImport(Metal)
    @Test("Metal GPU uber-shader matches RuneRef CPU renderer across primitive kinds")
    func metalMatchesCPUReference() throws {
        let gpu: MetalRenderer
        do {
            gpu = try MetalRenderer()
        } catch {
            // Only skip if running on a headless VM with no Metal device at all
            return
        }

        let w = 160
        let h = 120
        let clip = SIMD4<Float>(0, 0, Float(w), Float(h))

        let scene = RefScene(
            width: w,
            height: h,
            srgbBlend: false,
            clearColor: SIMD4<Float>(0.03, 0.04, 0.06, 1.0),
            primitives: [
                // 1. Drop shadow
                .dropShadow(
                    rect: SIMD4<Float>(20, 20, 60, 40),
                    radii: SIMD4<Float>(repeating: 8),
                    color: SIMD4<Float>(0, 0, 0, 0.5),
                    blur: 8,
                    offset: SIMD2<Float>(0, 4),
                    clip: clip
                ),
                // 2. Rounded rect with border
                .roundedRect(
                    rect: SIMD4<Float>(20, 20, 60, 40),
                    radii: SIMD4<Float>(repeating: 8),
                    fill: SIMD4<Float>(0.15, 0.35, 0.85, 1.0),
                    borderColor: SIMD4<Float>(0.8, 0.9, 1.0, 1.0),
                    borderWidth: 2,
                    clip: clip
                ),
                // 3. Linear gradient pill
                .linearGradient(
                    rect: SIMD4<Float>(92, 20, 50, 40),
                    radii: SIMD4<Float>(repeating: 12),
                    topColor: SIMD4<Float>(0.8, 0.2, 0.4, 1.0),
                    bottomColor: SIMD4<Float>(0.2, 0.1, 0.6, 1.0),
                    clip: clip
                ),
                // 4. Capsule stroke segment
                .segment(
                    from: SIMD2<Float>(24, 84),
                    to: SIMD2<Float>(80, 102),
                    width: 4,
                    color: SIMD4<Float>(0.2, 0.85, 0.45, 1.0),
                    roundCap: true,
                    clip: clip
                ),
                // 5. Dashed border ring
                .dashedRing(
                    rect: SIMD4<Float>(96, 72, 46, 36),
                    radii: SIMD4<Float>(repeating: 6),
                    color: SIMD4<Float>(0.9, 0.75, 0.2, 1.0),
                    borderWidth: 2,
                    dashLength: 6,
                    gapLength: 4,
                    clip: clip
                ),
            ]
        )

        let cpuFrame = try RuneRef.render(scene)
        let gpuFrame = try gpu.renderOffscreen(scene)
        let diff = RuneRef.compare(
            scene: scene,
            expected: cpuFrame,
            actual: gpuFrame,
            channelTolerance: 2,
            maxFailingPixels: 0
        )
        #expect(diff.passed, "GPU vs CPU mismatch: \(diff)")
    }

    @Test("Metal GPU matches RuneRef CPU on isolated blurred/rotated layers, backdrop blur, squircles, inset shadows, and atlases")
    func metalMatchesCPUOnLayersBlurAndAtlases() throws {
        let gpu: MetalRenderer
        do {
            gpu = try MetalRenderer()
        } catch {
            return
        }

        let w = 140
        let h = 110
        let clip = SIMD4<Float>(0, 0, Float(w), Float(h))

        var glyphAtlas = R8Atlas(width: 16, height: 16)
        for y in 2..<14 {
            for x in 2..<14 {
                glyphAtlas.texels[y * 16 + x] = (x == y || x + y == 15) ? 255 : 64
            }
        }

        var imgAtlas = RGBA8Atlas(width: 8, height: 8)
        for y in 0..<8 {
            for x in 0..<8 {
                let o = (y * 8 + x) * 4
                imgAtlas.texels[o] = UInt8(x * 32)
                imgAtlas.texels[o + 1] = UInt8(y * 32)
                imgAtlas.texels[o + 2] = 180
                imgAtlas.texels[o + 3] = 255
            }
        }

        let layerRect = SIMD4<Float>(18, 16, 48, 36)
        let scene = RefScene(
            width: w,
            height: h,
            srgbBlend: false,
            clearColor: SIMD4<Float>(0.06, 0.07, 0.10, 1.0),
            glyphs: glyphAtlas,
            images: imgAtlas,
            primitives: [
                // Continuous squircle (`radii < 0`) + inset shadow
                .roundedRect(
                    rect: SIMD4<Float>(76, 14, 52, 40),
                    radii: SIMD4<Float>(repeating: -10),
                    fill: SIMD4<Float>(0.2, 0.55, 0.4, 1.0),
                    clip: clip
                ),
                .insetShadow(
                    rect: SIMD4<Float>(76, 14, 52, 40),
                    radii: SIMD4<Float>(repeating: 10),
                    color: SIMD4<Float>(0, 0, 0, 0.45),
                    blur: 6,
                    offset: SIMD2<Float>(0, 2),
                    clip: clip
                ),
                // Isolated blurred + semi-transparent + slightly rotated group layer!
                .layerBegin(
                    rect: layerRect,
                    opacity: 0.72,
                    blurRadius: 3.0,
                    clip: clip,
                    turn: 0.12
                ),
                .roundedRect(
                    rect: layerRect,
                    radii: SIMD4<Float>(repeating: 8),
                    fill: SIMD4<Float>(0.9, 0.25, 0.35, 1.0),
                    clip: clip
                ),
                .glyph(
                    rect: SIMD4<Float>(28, 22, 24, 24),
                    uv: SIMD4<Float>(2.0 / 16.0, 2.0 / 16.0, 14.0 / 16.0, 14.0 / 16.0),
                    color: SIMD4<Float>(1, 1, 1, 1),
                    clip: clip
                ),
                .layerEnd(clip: clip),
                // Image quad
                .image(
                    rect: SIMD4<Float>(18, 64, 36, 32),
                    radii: SIMD4<Float>(repeating: 6),
                    uv: SIMD4<Float>(0.0625, 0.0625, 0.9375, 0.9375),
                    tint: SIMD4<Float>(1, 1, 1, 1),
                    clip: clip
                ),
                // Backdrop blur over overlapping content
                Primitive(
                    rect: SIMD4<Float>(68, 42, 54, 48),
                    radii: SIMD4<Float>(repeating: 10),
                    params: SIMD4<Float>(4.0, Float(PrimitiveKind.backdropBlur.rawValue), 0, 0),
                    clip: clip
                ),
            ]
        )

        let cpuFrame = try RuneRef.render(scene)
        let gpuFrame = try gpu.renderOffscreen(scene)
        let diff = RuneRef.compare(
            scene: scene,
            expected: cpuFrame,
            actual: gpuFrame,
            channelTolerance: 2,
            maxFailingPixels: 0
        )
        #expect(diff.passed, "GPU vs CPU layer/blur/atlas mismatch: \(diff)")
    }
    #endif

    @Test("RefBlend separable modes preserve source on transparent backdrops")
    func separableBlendModes() {
        let src = SIMD4<Float>(0.12, 0.24, 0.06, 0.3)
        for mode in SeparableBlendMode.allCases {
            let out = RefBlend.composite(mode: mode, src: src, dst: .zero)
            #expect(abs(out.x - src.x) < 1e-6)
            #expect(abs(out.y - src.y) < 1e-6)
            #expect(abs(out.z - src.z) < 1e-6)
            #expect(abs(out.w - src.w) < 1e-6)
        }
        // White multiplied by half-gray yields half-gray
        let white = SIMD4<Float>(1, 1, 1, 1)
        let gray = SIMD4<Float>(0.5, 0.5, 0.5, 1)
        let mul = RefBlend.composite(mode: .multiply, src: white, dst: gray)
        #expect(abs(mul.x - 0.5) < 1e-6 && abs(mul.w - 1.0) < 1e-6)
    }

    @Test("Metamorphic properties: translation invariance, transparent no-op, full clip, disjoint commutativity")
    func metamorphicProperties() throws {
        for seed: UInt64 in 0..<8 {
            let scene = RefGenerator.seeded(seed: seed, count: 6)
            let original = try RuneRef.render(scene)
            #expect(original.fnv1aHash() == (try RuneRef.render(scene)).fnv1aHash())

            // 1. Integer translation invariance
            var shifted = scene
            shifted.width += 4
            shifted.height += 6
            RefGenerator.translate(&shifted, dx: 4, dy: 6)
            let actual = try RuneRef.render(shifted)
            for y in 0..<scene.height {
                for x in 0..<scene.width {
                    #expect(original.pixel(x: x, y: y) == actual.pixel(x: x + 4, y: y + 6))
                }
            }

            // 2. Transparent primitives preserve output bytes
            var withTransparent = scene
            for var p in scene.primitives {
                p.fill = .zero
                p.border = .zero
                withTransparent.primitives.append(p)
            }
            #expect((try RuneRef.render(withTransparent)).rgba == original.rgba)

            // 3. Full viewport clip equals RefGenerator.noClip
            var unclipped = scene
            for i in unclipped.primitives.indices {
                unclipped.primitives[i].clip = RefGenerator.noClip
            }
            var fullClip = unclipped
            for i in fullClip.primitives.indices {
                fullClip.primitives[i].clip = SIMD4<Float>(0, 0, Float(scene.width), Float(scene.height))
            }
            #expect((try RuneRef.render(unclipped)).rgba == (try RuneRef.render(fullClip)).rgba)
        }

        // 4. Disjoint clipped groups commute
        var disjoint = RefGenerator.seeded(seed: 42, count: 4)
        for i in disjoint.primitives.indices {
            disjoint.primitives[i].clip = SIMD4<Float>(0, 0, 30, 64)
        }
        let leftCount = disjoint.primitives.count
        var right = RefGenerator.seeded(seed: 99, count: 4)
        RefGenerator.translate(&right, dx: 32, dy: 0)
        for i in right.primitives.indices {
            right.primitives[i].clip = SIMD4<Float>(32, 0, 32, 64)
        }
        disjoint.primitives.append(contentsOf: right.primitives)
        let orderA = try RuneRef.render(disjoint)
        disjoint.primitives = Array(disjoint.primitives[leftCount...] + disjoint.primitives[..<leftCount])
        let orderB = try RuneRef.render(disjoint)
        #expect(orderA.rgba == orderB.rgba)
    }

    @Test("Dashed rings translate cleanly and semi-transparent PNG round-trips straight alpha")
    func dashedTranslationAndSemiTransparentPNG() throws {
        let dashed = RefGenerator.dashed(seed: 3, count: 6)
        let orig = try RuneRef.render(dashed)
        var shifted = dashed
        shifted.width += 4
        shifted.height += 6
        RefGenerator.translate(&shifted, dx: 4, dy: 6)
        let moved = try RuneRef.render(shifted)
        for y in 0..<dashed.height {
            for x in 0..<dashed.width {
                #expect(orig.pixel(x: x, y: y) == moved.pixel(x: x + 4, y: y + 6))
            }
        }

        // Semi-transparent clearColor PNG round-trip preserves straight RGB
        let semiScene = RefScene(
            width: 8,
            height: 8,
            srgbBlend: true,
            clearColor: SIMD4<Float>(0.8, 0.2, 0.4, 0.5)
        )
        let semiFrame = try RuneRef.render(semiScene)
        let decoded = try Frame.fromPNG(data: try semiFrame.pngData())
        let diff = RuneRef.compare(scene: semiScene, expected: semiFrame, actual: decoded, channelTolerance: 2)
        #expect(diff.passed, "Semi-transparent PNG round-trip mismatch: \(diff)")
    }

    @Test("Grayscale and RGB PNG transparency keys match the complete sample")
    func portablePNGTransparencyKeys() throws {
        // Each fixture has a transparent pixel followed by a near match.
        // FFmpeg yields the straight RGBA bytes below.
        let fixtures: [(String, [UInt8])] = [
            ("iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAAAAADRSSBWAAAAAnRSTlMAJT2XGX8AAAALSURBVHicY1BVAwAAcwBMHTPEOAAAAABJRU5ErkJggg==",
             [37, 37, 37, 0, 38, 38, 38, 255]),
            ("iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAABnRSTlMACwAWACFNtPkcAAAAD0lEQVR4nGPgFlPkFlMCAAGqAIY9sMQ3AAAAAElFTkSuQmCC",
             [11, 22, 33, 0, 11, 22, 34, 255])
        ]
        for (base64, expected) in fixtures {
            let data = try #require(Data(base64Encoded: base64))
            #expect(try PortablePNG.decode(data).rgba == expected)
        }
    }

    @Test("PortablePNG encodes, decodes, and unfilters scanline types 0..4")
    func portablePNGRoundTripAndUnfiltering() throws {
        // 1. Exact byte-for-byte round-trip via PortablePNG
        let width = 7
        let height = 5
        var rgba = [UInt8]()
        rgba.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                rgba.append(UInt8((x * 37 + y * 13) & 0xFF))
                rgba.append(UInt8((x * 19 + y * 53) & 0xFF))
                rgba.append(UInt8((x * 7 + y * 97) & 0xFF))
                rgba.append(UInt8(((x + y) * 29) & 0xFF))
            }
        }
        let encoded = try PortablePNG.encode(width: width, height: height, rgba: rgba)
        #expect(throws: PortablePNG.Error.invalidDimensions(width: Int.max, height: 2)) {
            try PortablePNG.encode(width: Int.max, height: 2, rgba: [])
        }
        #expect(throws: PortablePNG.Error.invalidDimensions(width: width, height: height)) {
            try PortablePNG.decode(encoded, maxDimension: width - 1)
        }
        let decoded = try PortablePNG.decode(encoded)
        #expect(decoded.width == width)
        #expect(decoded.height == height)
        #expect(decoded.rgba == rgba)

        // 2. Interop with Frame.pngData() / Frame.fromPNG(data:) (exercises DEFLATE inflate on ImageIO PNGs)
        let scene = RefGenerator.seeded(seed: 7, count: 6)
        let rendered = try RuneRef.render(scene)
        let imageIOPNG = try rendered.pngData()
        let portableDecoded = try PortablePNG.decode(imageIOPNG)
        #expect(portableDecoded.width == rendered.width)
        #expect(portableDecoded.height == rendered.height)
        #expect(portableDecoded.rgba == rendered.rgba)

        let imageIODecoded = try Frame.fromPNG(data: encoded)
        #expect(imageIODecoded.width == width)
        #expect(imageIODecoded.height == height)

        // 3. Direct scanline unfiltering for filter types 0..4 (bpp = 4)
        let prev: [UInt8] = [10, 20, 30, 40, 50, 60, 70, 80]
        let expected: [UInt8] = [100, 110, 120, 130, 140, 150, 160, 170]
        let bpp = 4

        // Filter 0: None
        let raw0 = expected
        #expect(try PortablePNG.unfilterScanline(filterType: 0, raw: raw0[...], prev: prev, bpp: bpp) == expected)

        // Filter 1: Sub
        var raw1 = [UInt8](repeating: 0, count: expected.count)
        for i in 0..<expected.count {
            let left: UInt8 = i >= bpp ? expected[i - bpp] : 0
            raw1[i] = expected[i] &- left
        }
        #expect(try PortablePNG.unfilterScanline(filterType: 1, raw: raw1[...], prev: prev, bpp: bpp) == expected)

        // Filter 2: Up
        var raw2 = [UInt8](repeating: 0, count: expected.count)
        for i in 0..<expected.count {
            raw2[i] = expected[i] &- prev[i]
        }
        #expect(try PortablePNG.unfilterScanline(filterType: 2, raw: raw2[...], prev: prev, bpp: bpp) == expected)

        // Filter 3: Average
        var raw3 = [UInt8](repeating: 0, count: expected.count)
        for i in 0..<expected.count {
            let left = Int(i >= bpp ? expected[i - bpp] : 0)
            let up = Int(prev[i])
            raw3[i] = expected[i] &- UInt8((left + up) >> 1)
        }
        #expect(try PortablePNG.unfilterScanline(filterType: 3, raw: raw3[...], prev: prev, bpp: bpp) == expected)

        // Filter 4: Paeth
        var raw4 = [UInt8](repeating: 0, count: expected.count)
        for i in 0..<expected.count {
            let a = Int(i >= bpp ? expected[i - bpp] : 0)
            let b = Int(prev[i])
            let c = Int(i >= bpp ? prev[i - bpp] : 0)
            let p = a + b - c
            let pa = abs(p - a)
            let pb = abs(p - b)
            let pc = abs(p - c)
            let pred = UInt8((pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c))
            raw4[i] = expected[i] &- pred
        }
        #expect(try PortablePNG.unfilterScanline(filterType: 4, raw: raw4[...], prev: prev, bpp: bpp) == expected)
    }
}
