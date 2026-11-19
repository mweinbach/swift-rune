import Foundation
import Testing
@testable import RuneRef
@testable import Rune

@Suite("RuneRef Parity Tests")
struct RuneRefParityTests {
    static let upstreamGoldens: [(UInt64, String)] = [
        (0, "36f6aefc4d7c36910ee798986eb39062edc40385728f9aefe9c11b665daa1478"),
        (1, "270fb4349cc80c4eaa97e9dd4346f91cbd6fad2e235d0983cd6fd466e54e0675"),
        (2, "146ccdad62888e39c5ccbc07d8ce81c0d493505be05e11cf7ecf9daed79c562c"),
        (3, "4c768398c7899a038e6ea5890112819b118e2df31175c9ca9fbaf95712782818"),
        (4, "2f1dd0f326dbf98c5bd57d06adae49f2c819a3cdffc9e5f75651755ee1139aa4"),
        (5, "dcdbd7d410d5aa542330a9ab2f6ab7ebc202ea653b268d34c2aab52de9d61cb8"),
        (6, "9001ab24ecfe59e3f6716e06a95027a985579e0bacdfdda36400b49452cef6d1"),
        (7, "a459d7aefe2ef5004891c59c8dd110e1a1d5b38aa862af7eedd2483dcbb5ab07"),
        (8, "6cffd2911ab5b6c5dbba4add0da485a9a9fc7f950255f956577b8329fb6e9f96"),
        (9, "6091f51afe00ffdca47ce48195d9987913b3295d65b375c5bf42372e561e3a82"),
        (10, "385a43a7a3d8a30b37cc94e1e7461f3187fa28a5a9bdbafd0117e20d0ed2c643"),
        (11, "a359ef5267bd87b3977f91fea6ac53a64edf5e4b7a7e2308dca03c191b609d7e"),
        (12, "71c9655fb9dac08bcbc6b1eb149b445b73e48181d1227e1cdcd2697dd0bb7a91"),
        (13, "d0c29bdf1e073d56b326fd70ec02cdaa3699de771d3f0f3874ba1d70d46938d0"),
        (14, "b9e355a0653b0581759327bc5a8c4a40c80e8c5c6b17992c75578a958212a605"),
        (15, "e42a98b4aba1b188c6579c9f2b2b5fa1a292b166ecf27c0a9f62cd40f9eec26e"),
    ]

    @Test("BLAKE3 vector sanity and upstream goldens.json 16 canonical seeds match bit-for-bit")
    func goldensMatchUpstreamBitForBit() throws {
        #expect(
            Blake3.hashHex(Array("hello".utf8))
                == "ea8f163db38682925e4491c5e58d4bb3506ef8c14eb78a86e908c5624a67200f"
        )
        // Multi-chunk (>1024 bytes) Merkle hash check vs empty
        let longBytes = [UInt8](repeating: 0x41, count: 4096)
        #expect(Blake3.hashHex(longBytes).count == 64)
        #expect(Blake3.hashHex([]) == "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262")

        for (seed, expectedHash) in Self.upstreamGoldens {
            let scene = OracleGenerator.seeded(seed: seed, count: 8)
            try scene.validate()
            var frame = OracleFrame(width: scene.width, height: scene.height, provenance: false)
            frame.render(scene)
            #expect(frame.hash() == expectedHash, "Golden mismatch for seed \(seed)")
        }
    }

    @Test("Kind 12 effect slot is a no-op in both OracleShader and RuneRef")
    func effectSlotIsNoOp() throws {
        let oracle = OracleGenerator.seeded(seed: 1, count: 4)
        var baseFrame = OracleFrame(width: oracle.width, height: oracle.height, provenance: true)
        baseFrame.render(oracle)

        var withEffect = oracle
        withEffect.primitives.append(OraclePrimitive(
            node: 99,
            source: "effect-slot",
            rect: [0, 0, 64, 64],
            radii: [0, 0, 0, 0],
            fill: [1, 0, 0, 1],
            border: [0, 0, 0, 0],
            params: [1, 12, 2, 3],
            uv: [0, 0, 0, 0],
            clip: oracleNoClip,
            fade: [0, 0, 0, 0]
        ))
        try withEffect.validate()
        var effectFrame = OracleFrame(width: withEffect.width, height: withEffect.height, provenance: true)
        effectFrame.render(withEffect)
        #expect(effectFrame.rgba == baseFrame.rgba)
        #expect(effectFrame.hash() == baseFrame.hash())

        var swiftScene = RefGenerator.seeded(seed: 1, count: 4)
        let baseSwift = try RuneRef.render(swiftScene)
        swiftScene.primitives.append(.effectSlot(rect: SIMD4<Float>(0, 0, 64, 64)))
        let withSwiftEffect = try RuneRef.render(swiftScene)
        #expect(baseSwift.rgba == withSwiftEffect.rgba)
        #expect(baseSwift.blake3Hash() == withSwiftEffect.blake3Hash())
    }

    @Test("JSON replay round-trip, fade_origin, turn layers, dashed/radial generators, and provenance blame")
    func jsonReplayGeneratorsAndBlame() throws {
        // Explicit JSON schema with fade_origin, rotated layer, and glyph sampling
        let json = """
        {
          "width": 32,
          "height": 32,
          "clear": [0.02, 0.03, 0.04, 1.0],
          "atlas": {
            "width": 4,
            "height": 4,
            "data": [255, 192, 64, 0, 255, 192, 64, 0, 255, 128, 32, 0, 0, 0, 0, 0]
          },
          "primitives": [
            {
              "node": 10,
              "source": "layer/turn",
              "rect": [4, 4, 24, 24],
              "radii": [4, 4, 4, 4],
              "fill": [0, 0, 0, 0.9],
              "border": [0, 0, 0, 0],
              "params": [0, 8, 0, 0],
              "uv": [0, 0, 0, 0],
              "clip": [2, 2, 30, 30],
              "fade": [0, 0, 0, 0],
              "turn": [0.25, 16, 16]
            },
            {
              "node": 11,
              "source": "rect/faded",
              "rect": [6, 6, 18, 18],
              "radii": [3, 3, 3, 3],
              "fill": [0.8, 0.2, 0.3, 1.0],
              "border": [0, 0, 0, 0],
              "params": [0, 0, 0, 0],
              "uv": [0, 0, 0, 0],
              "clip": [-1000000.0, -1000000.0, 1000000.0, 1000000.0],
              "fade": [0, 0, 0, 0],
              "fade_origin": [6, 6, 24, 24]
            },
            {
              "node": 12,
              "source": "glyph/texel-boundary",
              "rect": [10, 10, 8, 8],
              "radii": [0, 0, 0, 0],
              "fill": [0.9, 0.9, 0.9, 1.0],
              "border": [0, 0, 0, 0],
              "params": [0, 2, 0, 0.85],
              "uv": [0.5, 0.5, 0, 0],
              "clip": [-1000000.0, -1000000.0, 1000000.0, 1000000.0],
              "fade": [0, 0, 0, 0]
            },
            {
              "node": 10,
              "source": "layer/turn/end",
              "rect": [0, 0, 0, 0],
              "radii": [0, 0, 0, 0],
              "fill": [0, 0, 0, 0],
              "border": [0, 0, 0, 0],
              "params": [0, 9, 0, 0],
              "uv": [0, 0, 0, 0],
              "clip": [-1000000.0, -1000000.0, 1000000.0, 1000000.0],
              "fade": [0, 0, 0, 0]
            }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(OracleScene.self, from: Data(json.utf8))
        try decoded.validate()
        let encoded = try JSONEncoder().encode(decoded)
        let redecoded = try JSONDecoder().decode(OracleScene.self, from: encoded)
        #expect(redecoded == decoded)

        var f1 = OracleFrame(width: 32, height: 32, provenance: true)
        f1.render(decoded)
        var f2 = OracleFrame(width: 32, height: 32, provenance: true)
        f2.render(redecoded)
        #expect(f1.hash() == f2.hash())
        #expect(f1.blame(decoded, x: 0, y: 0) == nil)
        let centerBlame = f1.blame(decoded, x: 14, y: 14)
        #expect(centerBlame != nil)

        // Compare detects mismatch and cites blame
        var corrupted = f1.rgba
        let pxIdx = (14 * 32 + 14) * 4
        corrupted[pxIdx] = corrupted[pxIdx] ^ 0x40
        let diff = Oracle.compare(scene: decoded, cpu: f1, gpu: corrupted, tolerance: 2)
        #expect(diff.outlierPixels == 1)
        #expect(diff.maxChannel >= 32)
        #expect(diff.first?.x == 14 && diff.first?.y == 14)
        #expect(diff.first?.node != nil)

        // Upstream provenance_and_diff_name_the_source exact check
        var provScene = OracleGenerator.scene(records: [Array(repeating: UInt8(0), count: 32)])
        provScene.primitives[0].rect = [2, 2, 10, 10]
        provScene.primitives[0].fill = [1, 1, 1, 1]
        try provScene.validate()
        var provFrame = OracleFrame(width: provScene.width, height: provScene.height, provenance: true)
        provFrame.render(provScene)
        #expect(provFrame.blame(provScene, x: 5, y: 5)?.source == "generated/0")
        #expect(provFrame.blame(provScene, x: 63, y: 63) == nil)
        var badProv = provFrame.rgba
        badProv[(5 * 64 + 5) * 4] = 0
        let provDiff = Oracle.compare(scene: provScene, cpu: provFrame, gpu: badProv, tolerance: 2)
        #expect(provDiff.outlierPixels == 1)
        #expect(provDiff.first?.node == 1)

        // Dashed & radial generators + RefGenerator.radial + translate invariance
        for scene in [OracleGenerator.dashed(seed: 2, count: 6), OracleGenerator.radial(seed: 3, count: 6)] {
            try scene.validate()
            var a = OracleFrame(width: scene.width, height: scene.height)
            a.render(scene)
            var shifted = scene
            shifted.width += 4
            shifted.height += 6
            OracleGenerator.translate(&shifted, x: 4, y: 6)
            var b = OracleFrame(width: shifted.width, height: shifted.height)
            b.render(shifted)
            for y in 0..<scene.height {
                for x in 0..<scene.width {
                    let i0 = Int(y * scene.width + x) * 4
                    let i1 = Int((y + 6) * shifted.width + (x + 4)) * 4
                    #expect(a.rgba[i0..<(i0 + 4)] == b.rgba[i1..<(i1 + 4)])
                }
            }
        }

        let swiftRadial = RefGenerator.radial(seed: 5, count: 6)
        try swiftRadial.validate()
        let swiftRadialFrame = try RuneRef.render(swiftRadial)
        #expect(swiftRadialFrame.blake3Hash().count == 64)
    }

    @Test("Bit-packing helpers (f16, packFade, packClipRadii) match upstream invariants")
    func packingHelpersRoundTrip() {
        for v: Float in [-32.5, -1.0, 0.0, 0.125, 0.5, 1.0, 42.0] {
            let bits = OraclePrimitive.float32To16Bits(v)
            let round = OraclePrimitive.float16BitsTo32(bits)
            #expect(abs(round - v) <= 0.05)
        }
        let fade = OraclePrimitive.packFade(
            width: [8.0, 4.0, 12.0, 16.0],
            origin: [2.0, 1.0, 106.0, 108.0],
            clip: [4.0, 2.0, 100.0, 100.0]
        )
        let unpackedFade = OraclePrimitive.unpackFade(fade)
        #expect(unpackedFade.width == [8.0, 4.0, 12.0, 16.0])
        #expect(abs(unpackedFade.offset[0] - 0.25) < 0.01)
        #expect(abs(unpackedFade.offset[1] - 0.25) < 0.01)
        #expect(abs(unpackedFade.offset[2] - 0.5) < 0.01)
        #expect(abs(unpackedFade.offset[3] - 0.5) < 0.01)

        let radii = OraclePrimitive.packClipRadii(
            clip: [0.0, 0.0, 100.0, 100.0],
            radii: [4.0, 8.0, 12.0, 16.0]
        )
        let unpackedRadii = OraclePrimitive.unpackClipRadii(radii)
        #expect(unpackedRadii == [4.0, 8.0, 12.0, 16.0])
    }

    @Test("OracleShader fade ramp linear vs smoothstep matches upstream shader.rs")
    func aNegativeFadeRampsLinearlyAndAPositiveOneEases() {
        for (d, linear) in [
            (Float(0.0), Float(0.0)),
            (4.0, 0.25),
            (8.0, 0.5),
            (12.0, 0.75),
            (16.0, 1.0),
            (20.0, 1.0),
        ] {
            #expect(abs(OracleShader.ramp(d, -16.0) - linear) < 1e-6)
        }
        #expect(abs(OracleShader.ramp(4.0, 16.0) - 0.15625) < 1e-6)
        #expect(OracleShader.ramp(8.0, 16.0) == OracleShader.ramp(8.0, -16.0))
    }

    @Test("OracleShader ringArc walks the centre line clockwise matching upstream shader.rs")
    func ringArcWalksTheCentreLine() {
        let cases: [((Float, Float), [Float], Float)] = [
            ((40.0, 20.0), [10.0, 10.0, 10.0, 10.0], 2.0),
            ((30.0, 30.0), [0.0, 6.0, 15.0, 3.0], 1.0),
            ((50.0, 12.0), [6.0, 6.0, 6.0, 6.0], 0.5),
            ((24.0, 18.0), [0.0, 0.0, 0.0, 0.0], 1.5),
        ]
        for (size, radii, bw) in cases {
            let h = bw * 0.5
            let rc = radii.map { max(0.0, min($0, min(size.0, size.1) * 0.5) - h) }
            let (_, total) = OracleShader.ringArc((size.0 * 0.5, h), size, radii, bw)
            let expected = 2.0 * (size.0 + size.1 - 2.0 * bw)
                - (2.0 - Float.pi * 0.5) * rc.reduce(0, +)
            #expect(abs(total - expected) < 1e-3)

            var points: [(Float, Float)] = []
            let steps = 400
            for n in 0..<steps {
                let angle = Float(n) / Float(steps) * (2.0 * Float.pi)
                let dir = (sinf(angle), -cosf(angle))
                var lo: Float = 0.0
                var hi: Float = size.0 + size.1
                for _ in 0..<60 {
                    let mid = (lo + hi) * 0.5
                    let q = (dir.0 * mid, dir.1 * mid)
                    if OracleShader.sd(q, (size.0 * 0.5, size.1 * 0.5), radii) + h < 0.0 {
                        lo = mid
                    } else {
                        hi = mid
                    }
                }
                points.append((size.0 * 0.5 + dir.0 * lo, size.1 * 0.5 + dir.1 * lo))
            }

            var trip: Float = 0.0
            for n in 1...steps {
                let a = points[n - 1]
                let b = points[n % steps]
                let chord = sqrtf((b.0 - a.0) * (b.0 - a.0) + (b.1 - a.1) * (b.1 - a.1))
                var ds = (OracleShader.ringArc(b, size, radii, bw).0 - OracleShader.ringArc(a, size, radii, bw).0)
                    .truncatingRemainder(dividingBy: total)
                if ds < 0 { ds += total }
                #expect(ds > chord - 1e-3 && ds < chord * 1.5 + 1e-3)
                trip += ds
            }
            #expect(abs(trip - total) < 1e-2)
        }
    }

    @Test("OracleShader dash pattern closes smoothly at the seam matching upstream shader.rs")
    func dashPatternClosesAtTheSeam() {
        for total: Float in [37.3, 100.0, 251.9, 3.0] {
            for d: (Float, Float, Float) in [(4.0, 3.0, 0.0), (6.0, 2.5, 1.7), (10.0, 10.0, -4.0)] {
                for n in 0..<50 {
                    let s = Float(n) * 0.37
                    #expect(abs(OracleShader.dashCov(s, total, d.0, d.1, d.2) - OracleShader.dashCov(s + total, total, d.0, d.1, d.2)) < 1e-3)
                    #expect(abs(OracleShader.dashCov(s, total, d.0, d.1, d.2) - OracleShader.dashCov(s - total, total, d.0, d.1, d.2)) < 1e-3)
                }
            }
        }
        #expect(abs(OracleShader.dashCov(0.0, 100.0, 4.0, 3.0, 0.0) - 0.5) < 1e-4)
        #expect(OracleShader.dashCov(1.0, 100.0, 4.0, 3.0, 0.0) == 1.0)
        for n in 0..<50 {
            let s = Float(n) * 1.3
            #expect(abs(OracleShader.dashCov(s, 100.0, 4.0, 3.0, 7.0) - OracleShader.dashCov(s, 100.0, 4.0, 3.0, 0.0)) < 1e-3)
        }
    }

    @Test("Oracle glyph rotation turns clockwise and clips on screen matching upstream reference.rs")
    func glyphRotationTurnsClockwiseAndClipsOnScreen() throws {
        func renderGlyph(angle: Float, clip: [Float]) throws -> OracleFrame {
            var s = OracleGenerator.scene(records: [])
            s.atlas.data = [UInt8](repeating: 0, count: s.atlas.data.count)
            for y in 1..<5 {
                for x in 1..<5 {
                    s.atlas.data[y * 32 + x] = 255
                }
            }
            var p = OracleGenerator.scene(records: [[UInt8](repeating: 0, count: 32)]).primitives[0]
            p.rect = [20.0, 20.0, 16.0, 16.0]
            p.radii = [0, 0, 0, 0]
            p.fill = [1, 1, 1, 1]
            p.params = [angle, 2.0, 0.0, 1.0]
            p.uv = [1.0, 1.0, 0.0, 0.0]
            p.clip = clip
            s.primitives.append(p)
            try s.validate()
            var frame = OracleFrame(width: s.width, height: s.height, provenance: false)
            frame.render(s)
            return frame
        }

        func isLit(_ f: OracleFrame, _ x: Int, _ y: Int) -> Bool {
            f.rgba[(y * 64 + x) * 4] == 255
        }

        let cw = try renderGlyph(angle: Float.pi * 0.5, clip: oracleNoClip)
        let ccw = try renderGlyph(angle: -Float.pi * 0.5, clip: oracleNoClip)
        #expect(cw.rgba != ccw.rgba)
        #expect(isLit(cw, 34, 21) && !isLit(cw, 21, 34) && !isLit(cw, 21, 21))
        #expect(isLit(ccw, 21, 34) && !isLit(ccw, 34, 21) && !isLit(ccw, 21, 21))

        let clipped = try renderGlyph(angle: Float.pi * 0.5, clip: [28.0, oracleNoClip[1], oracleNoClip[2], oracleNoClip[3]])
        #expect(isLit(clipped, 34, 21) && !isLit(clipped, 21, 34))
    }

    private func makeOracleLayer(kind: Float, blur: Float) -> OraclePrimitive {
        OraclePrimitive(
            node: 1,
            source: "layer",
            rect: kind == 9.0 ? [0, 0, 0, 0] : [0, 0, 8, 8],
            radii: [0, 0, 0, 0],
            fill: [0, 0, 0, kind == 9.0 ? 0.0 : 1.0],
            border: [0, 0, 0, 0],
            params: [0, kind, blur, 0],
            uv: [0, 0, 0, 0],
            clip: oracleNoClip,
            fade: [0, 0, 0, 0],
            fadeOrigin: nil,
            turn: nil,
            clipRadii: nil
        )
    }

    @Test("OracleScene.validate rejects unbalanced, unclosed, malformed cache, turned+cache, blurred, and deep layers")
    func validateRejectsLayersItCannotRender() throws {
        let base = OracleGenerator.scene(records: [])
        func sceneWith(_ primitives: [OraclePrimitive]) -> OracleScene {
            OracleScene(width: base.width, height: base.height, clear: base.clear, primitives: primitives, atlas: base.atlas)
        }

        try sceneWith([makeOracleLayer(kind: 8, blur: 0), makeOracleLayer(kind: 9, blur: 0)]).validate()

        #expect(throws: (any Error).self) {
            try sceneWith([makeOracleLayer(kind: 9, blur: 0)]).validate()
        }
        #expect(throws: (any Error).self) {
            try sceneWith([makeOracleLayer(kind: 8, blur: 0)]).validate()
        }

        var malformed = makeOracleLayer(kind: 8, blur: 0)
        malformed.params[3] = 2.0
        #expect(throws: (any Error).self) {
            try sceneWith([malformed, makeOracleLayer(kind: 9, blur: 0)]).validate()
        }

        var turned = makeOracleLayer(kind: 8, blur: 0)
        turned.turn = [0.4, 4.0, 4.0]
        try sceneWith([turned, makeOracleLayer(kind: 9, blur: 0)]).validate()

        // A turned subtree never opens a cache, so a turned cache record is malformed.
        turned.params[3] = 1.0
        #expect(throws: (any Error).self) {
            try sceneWith([turned, makeOracleLayer(kind: 9, blur: 0)]).validate()
        }

        // The CPU compositor has no layer blur, so a blurred layer would render unblurred.
        #expect(throws: (any Error).self) {
            try sceneWith([makeOracleLayer(kind: 8, blur: 2.0), makeOracleLayer(kind: 9, blur: 0)]).validate()
        }

        // Each nested scope holds a full-frame buffer while it renders, so nesting is bounded.
        let deep = Array(repeating: makeOracleLayer(kind: 8, blur: 0), count: 1000)
            + Array(repeating: makeOracleLayer(kind: 9, blur: 0), count: 1000)
        #expect(throws: (any Error).self) {
            try sceneWith(deep).validate()
        }
    }

    @Test("Dashed rings translate by integer pixels and never draw outside solid ring (32 seeds)")
    func dashedRingsTranslateAndStayInsideTheirRing() throws {
        for seed: UInt64 in 0..<32 {
            let scene = OracleGenerator.dashed(seed: seed, count: 8)
            try scene.validate()
            var original = OracleFrame(width: scene.width, height: scene.height, provenance: false)
            original.render(scene)

            var shifted = scene
            shifted.width += 4
            shifted.height += 6
            OracleGenerator.translate(&shifted, x: 4, y: 6)
            try shifted.validate()
            var actual = OracleFrame(width: shifted.width, height: shifted.height, provenance: false)
            actual.render(shifted)

            for y in 0..<64 {
                let origSlice = original.rgba[(y * 256)..<((y + 1) * 256)]
                let actStart = ((y + 6) * 68 + 4) * 4
                let actEnd = ((y + 6) * 68 + 68) * 4
                #expect(Array(origSlice) == Array(actual.rgba[actStart..<actEnd]), "seed \(seed) row \(y)")
            }

            // Dashes only ever take coverage away from the solid ring.
            for p in scene.primitives {
                var one = scene
                one.primitives = [p]
                var dashed = OracleFrame(width: one.width, height: one.height, provenance: true)
                dashed.render(one)

                one.primitives[0].params[1] = 4.0
                one.primitives[0].uv = one.primitives[0].border
                one.primitives[0].border = one.primitives[0].fill
                one.primitives[0].fill = [0, 0, 0, 0]
                var solid = OracleFrame(width: one.width, height: one.height, provenance: true)
                solid.render(one)

                let dOwners = dashed.owners ?? []
                let sOwners = solid.owners ?? []
                for (n, (d, s)) in zip(dOwners, sOwners).enumerated() {
                    #expect(d == nil || s != nil, "seed \(seed): pixel \(n) dashed outside the ring")
                }
            }
        }
    }

    @Test("Kind 12 effect slots across 16 seeded scenes match rgba and never appear in owners")
    func effectSlotsAreAcceptedAndDrawNothingParity() throws {
        for seed: UInt64 in 0..<16 {
            let scene = OracleGenerator.seeded(seed: seed, count: 8)
            var slotted = scene
            for (n, p) in scene.primitives.enumerated().reversed() {
                var slot = p
                slot.source = "effect/\(n)"
                slot.fill = [0, 0, 0, 1]
                slot.border = [0, 0, 0, 0]
                slot.params = [0, 12.0, 6.0, 1.0]
                slot.uv = [0, 0, 0, 0]
                if n % 3 == 0 {
                    slot.rect[2] = 0.0
                }
                slotted.primitives.insert(slot, at: n)
            }
            try scene.validate()
            try slotted.validate()
            var a = OracleFrame(width: scene.width, height: scene.height, provenance: true)
            a.render(scene)
            var b = OracleFrame(width: slotted.width, height: slotted.height, provenance: true)
            b.render(slotted)
            #expect(a.rgba == b.rgba, "seed \(seed)")
            let owners = (b.owners ?? []).compactMap { $0 }
            #expect(owners.allSatisfy { slotted.primitives[$0].params[1] != 12.0 }, "seed \(seed)")
        }
    }

    @Test("Upstream regressions/glyph-texel-boundary.json replays with exact BLAKE3 hash")
    func glyphTexelBoundaryRegressionReplay() throws {
        let json = #"{"width":64,"height":64,"clear":[0.025,0.04,0.06,1.0],"primitives":[{"node":4,"source":"generated/3","rect":[10.5,34.25,14.0,21.0],"radii":[25.25,24.625,14.625,8.125],"fill":[0.29413307,0.018131489,0.2034756,0.5137255],"border":[0.3062207,0.45933107,0.2034756,0.5137255],"params":[0.0,2.0,7.8125,1.6686275],"uv":[1.0,1.0,0.0,0.0],"clip":[12.625,8.375,39.125,57.375],"fade":[5.5,4.0,4.5,2.5]}],"atlas":{"width":32,"height":32,"data":[0,73,146,219,36,109,182,255,72,145,218,35,108,181,254,71,144,217,34,107,180,253,70,143,216,33,106,179,252,69,142,215,51,124,197,14,87,160,233,50,123,196,13,86,159,232,49,122,195,12,85,158,231,48,121,194,11,84,157,230,47,120,193,10,102,175,248,65,138,211,28,101,174,247,64,137,210,27,100,173,246,63,136,209,26,99,172,245,62,135,208,25,98,171,244,61,153,226,43,116,189,6,79,152,225,42,115,188,5,78,151,224,41,114,187,4,77,150,223,40,113,186,3,76,149,222,39,112,204,21,94,167,240,57,130,203,20,93,166,239,56,129,202,19,92,165,238,55,128,201,18,91,164,237,54,127,200,17,90,163,255,72,145,218,35,108,181,254,71,144,217,34,107,180,253,70,143,216,33,106,179,252,69,142,215,32,105,178,251,68,141,214,50,123,196,13,86,159,232,49,122,195,12,85,158,231,48,121,194,11,84,157,230,47,120,193,10,83,156,229,46,119,192,9,101,174,247,64,137,210,27,100,173,246,63,136,209,26,99,172,245,62,135,208,25,98,171,244,61,134,207,24,97,170,243,60,152,225,42,115,188,5,78,151,224,41,114,187,4,77,150,223,40,113,186,3,76,149,222,39,112,185,2,75,148,221,38,111,203,20,93,166,239,56,129,202,19,92,165,238,55,128,201,18,91,164,237,54,127,200,17,90,163,236,53,126,199,16,89,162,254,71,144,217,34,107,180,253,70,143,216,33,106,179,252,69,142,215,32,105,178,251,68,141,214,31,104,177,250,67,140,213,49,122,195,12,85,158,231,48,121,194,11,84,157,230,47,120,193,10,83,156,229,46,119,192,9,82,155,228,45,118,191,8,100,173,246,63,136,209,26,99,172,245,62,135,208,25,98,171,244,61,134,207,24,97,170,243,60,133,206,23,96,169,242,59,151,224,41,114,187,4,77,150,223,40,113,186,3,76,149,222,39,112,185,2,75,148,221,38,111,184,1,74,147,220,37,110,202,19,92,165,238,55,128,201,18,91,164,237,54,127,200,17,90,163,236,53,126,199,16,89,162,235,52,125,198,15,88,161,253,70,143,216,33,106,179,252,69,142,215,32,105,178,251,68,141,214,31,104,177,250,67,140,213,30,103,176,249,66,139,212,48,121,194,11,84,157,230,47,120,193,10,83,156,229,46,119,192,9,82,155,228,45,118,191,8,81,154,227,44,117,190,7,99,172,245,62,135,208,25,98,171,244,61,134,207,24,97,170,243,60,133,206,23,96,169,242,59,132,205,22,95,168,241,58,150,223,40,113,186,3,76,149,222,39,112,185,2,75,148,221,38,111,184,1,74,147,220,37,110,183,0,73,146,219,36,109,201,18,91,164,237,54,127,200,17,90,163,236,53,126,199,16,89,162,235,52,125,198,15,88,161,234,51,124,197,14,87,160,252,69,142,215,32,105,178,251,68,141,214,31,104,177,250,67,140,213,30,103,176,249,66,139,212,29,102,175,248,65,138,211,47,120,193,10,83,156,229,46,119,192,9,82,155,228,45,118,191,8,81,154,227,44,117,190,7,80,153,226,43,116,189,6,98,171,244,61,134,207,24,97,170,243,60,133,206,23,96,169,242,59,132,205,22,95,168,241,58,131,204,21,94,167,240,57,149,222,39,112,185,2,75,148,221,38,111,184,1,74,147,220,37,110,183,0,73,146,219,36,109,182,255,72,145,218,35,108,200,17,90,163,236,53,126,199,16,89,162,235,52,125,198,15,88,161,234,51,124,197,14,87,160,233,50,123,196,13,86,159,251,68,141,214,31,104,177,250,67,140,213,30,103,176,249,66,139,212,29,102,175,248,65,138,211,28,101,174,247,64,137,210,46,119,192,9,82,155,228,45,118,191,8,81,154,227,44,117,190,7,80,153,226,43,116,189,6,79,152,225,42,115,188,5,97,170,243,60,133,206,23,96,169,242,59,132,205,22,95,168,241,58,131,204,21,94,167,240,57,130,203,20,93,166,239,56,148,221,38,111,184,1,74,147,220,37,110,183,0,73,146,219,36,109,182,255,72,145,218,35,108,181,254,71,144,217,34,107,199,16,89,162,235,52,125,198,15,88,161,234,51,124,197,14,87,160,233,50,123,196,13,86,159,232,49,122,195,12,85,158,250,67,140,213,30,103,176,249,66,139,212,29,102,175,248,65,138,211,28,101,174,247,64,137,210,27,100,173,246,63,136,209,45,118,191,8,81,154,227,44,117,190,7,80,153,226,43,116,189,6,79,152,225,42,115,188,5,78,151,224,41,114,187,4]}}"#
        let scene = try JSONDecoder().decode(OracleScene.self, from: Data(json.utf8))
        try scene.validate()
        var frame = OracleFrame(width: scene.width, height: scene.height, provenance: false)
        frame.render(scene)
        #expect(frame.hash() == "5dee85cba41c7805ea3566d844fd6725ee074fea0e0336697ae4fbcb89c764b8")
    }

    @Test("OracleFrame metamorphic invariants match upstream reference.rs (translation, transparent owners, clip, disjoint)")
    func oracleMetamorphicInvariants() throws {
        for seed: UInt64 in 0..<16 {
            let scene = OracleGenerator.seeded(seed: seed, count: 6)
            try scene.validate()
            var original = OracleFrame(width: scene.width, height: scene.height, provenance: true)
            original.render(scene)

            var shifted = scene
            shifted.width += 4
            shifted.height += 6
            OracleGenerator.translate(&shifted, x: 4, y: 6)
            try shifted.validate()
            var actualShift = OracleFrame(width: shifted.width, height: shifted.height, provenance: true)
            actualShift.render(shifted)
            let wBytes = Int(scene.width) * 4
            for y in 0..<Int(scene.height) {
                let a = original.rgba[(y * wBytes)..<((y + 1) * wBytes)]
                let start = ((y + 6) * Int(shifted.width) + 4) * 4
                #expect(Array(a) == Array(actualShift.rgba[start..<(start + wBytes)]), "seed \(seed) row \(y)")
            }

            // Transparent primitives preserve both bytes and provenance owners.
            var transparent = scene
            for var p in scene.primitives {
                p.fill = [0, 0, 0, 0]
                p.border = [0, 0, 0, 0]
                if p.params[1] == 4.0 { p.uv = [0, 0, 0, 0] }
                transparent.primitives.append(p)
            }
            try transparent.validate()
            var actualTrans = OracleFrame(width: transparent.width, height: transparent.height, provenance: true)
            actualTrans.render(transparent)
            #expect(actualTrans.rgba == original.rgba, "seed \(seed)")
            #expect(actualTrans.owners == original.owners, "seed \(seed)")

            // Full viewport clip equals no clip at all pixel centers.
            var full = scene
            for i in full.primitives.indices {
                full.primitives[i].clip = oracleNoClip
                full.primitives[i].fade = [0, 0, 0, 0]
            }
            try full.validate()
            var unclipped = OracleFrame(width: full.width, height: full.height, provenance: false)
            unclipped.render(full)
            for i in full.primitives.indices {
                full.primitives[i].clip = [0, 0, 64, 64]
            }
            try full.validate()
            var clippedFull = OracleFrame(width: full.width, height: full.height, provenance: false)
            clippedFull.render(full)
            #expect(unclipped.rgba == clippedFull.rgba, "seed \(seed)")

            // Disjoint clipped groups commute.
            var disjoint = scene
            for i in disjoint.primitives.indices {
                disjoint.primitives[i].clip = [0, 0, 31, 64]
                disjoint.primitives[i].fade = [0, 0, 0, 0]
            }
            let leftCount = disjoint.primitives.count
            for var p in scene.primitives {
                p.rect[0] += 32.0
                p.clip = [32, 0, 64, 64]
                p.fade = [0, 0, 0, 0]
                disjoint.primitives.append(p)
            }
            try disjoint.validate()
            var da = OracleFrame(width: disjoint.width, height: disjoint.height, provenance: false)
            da.render(disjoint)
            disjoint.primitives = Array(disjoint.primitives[leftCount...] + disjoint.primitives[..<leftCount])
            var db = OracleFrame(width: disjoint.width, height: disjoint.height, provenance: false)
            db.render(disjoint)
            #expect(da.rgba == db.rgba, "seed \(seed)")
        }
    }

    @Test("reference.rs:215 OracleScene.validate accepts continuous corners and rejects unimplemented kinds")
    func validateAcceptsContinuousCornersAndRejectsUnimplementedKinds() throws {
        let base = OracleGenerator.scene(records: [])
        var rect = OracleGenerator.scene(records: [[UInt8](repeating: 0, count: 32)]).primitives[0]
        rect.params = [0.0, 0.0, 0.0, 1.0]
        rect.rect = [4.0, 4.0, 24.0, 24.0]
        rect.radii = [-6.0, -6.0, -6.0, -6.0]
        rect.fill = [0.8, 0.2, 0.1, 1.0]
        rect.border = [0.0, 0.0, 0.0, 0.0]
        rect.clip = [2.0, 2.0, 30.0, 30.0]
        rect.clipRadii = [-4.0, -4.0, 0.0, -4.0]
        let validScene = OracleScene(
            width: base.width,
            height: base.height,
            clear: base.clear,
            primitives: [rect],
            atlas: base.atlas
        )
        try validScene.validate()

        // JSON replay round-trip preserves `clip_radii` and omits it when nil.
        let encoded = try JSONEncoder().encode(validScene)
        let jsonString = String(decoding: encoded, as: UTF8.self)
        #expect(jsonString.contains("\"clip_radii\""))
        let decoded = try JSONDecoder().decode(OracleScene.self, from: encoded)
        #expect(decoded == validScene)

        var withoutClipRadii = rect
        withoutClipRadii.clipRadii = nil
        let encodedNil = try JSONEncoder().encode(withoutClipRadii)
        #expect(!String(decoding: encodedNil, as: UTF8.self).contains("clip_radii"))

        // Mixed positive and negative clip radii cannot be packed and are rejected.
        var mixedSignClip = rect
        mixedSignClip.clipRadii = [-4.0, 4.0, 0.0, 0.0]
        #expect(throws: (any Error).self) {
            try OracleScene(
                width: base.width,
                height: base.height,
                clear: base.clear,
                primitives: [mixedSignClip],
                atlas: base.atlas
            ).validate()
        }

        // Kinds 5 (segment), 6 (triangle), 7 (image) and 13 (backdrop blur) are not implemented here.
        for kind: Float in [5.0, 6.0, 7.0, 13.0] {
            var unsupported = rect
            unsupported.params[1] = kind
            #expect(throws: (any Error).self, "kind \(kind) must be rejected") {
                try OracleScene(
                    width: base.width,
                    height: base.height,
                    clear: base.clear,
                    primitives: [unsupported],
                    atlas: base.atlas
                ).validate()
            }
        }
    }

    @Test("reference.rs:241 PlusLighter blends additively inside, saturates, and composites source-over")
    func plusLighterBlendsAdditivelyInsideSaturatesAndCompositesSourceOver() throws {
        var scene = OracleGenerator.scene(records: [])
        scene.width = 16
        scene.height = 16
        scene.clear = [0.0, 0.0, 0.5, 1.0]
        var open = makeOracleLayer(kind: 8.0, blur: 0.0)
        open.rect = [0.0, 0.0, 16.0, 16.0]
        open.params[0] = 1.0 // PlusLighter
        open.fill = [0.0, 0.0, 0.0, 0.5] // 50% layer opacity
        var child = OracleGenerator.scene(records: [[UInt8](repeating: 0, count: 32)]).primitives[0]
        child.rect = [0.0, 0.0, 16.0, 16.0]
        child.radii = [0.0, 0.0, 0.0, 0.0]
        child.params = [0.0, 0.0, 0.0, 1.0]
        child.border = [0.0, 0.0, 0.0, 0.0]
        child.clip = oracleNoClip
        child.fade = [0.0, 0.0, 0.0, 0.0]
        child.fill = [0.6, 0.0, 0.0, 0.6]
        // Two identical children sum to [1.2, 0, 0, 1.2], saturate to [1, 0, 0, 1], then multiply by
        // opacity 0.5 -> [0.5, 0, 0, 0.5], composited source-over [0, 0, 0.5, 1] -> [0.5, 0, 0.25, 1].
        scene.primitives = [open, child, child, makeOracleLayer(kind: 9.0, blur: 0.0)]
        try scene.validate()
        var frame = OracleFrame(width: scene.width, height: scene.height, provenance: true)
        frame.render(scene)
        let base = (8 * 16 + 8) * 4
        let px = Array(frame.rgba[base..<(base + 4)])
        // srgb_encode(0.5) * 255 = 188, srgb_encode(0.25) * 255 = 137.
        #expect(abs(Int(px[0]) - 188) <= 1 && px[1] == 0 && abs(Int(px[2]) - 137) <= 1 && px[3] == 255, "got \(px)")
    }

    @Test("reference.rs:268 rounded clip clips ordinary primitive corners")
    func roundedClipClipsOrdinaryPrimitiveCorners() throws {
        var scene = OracleGenerator.scene(records: [])
        scene.width = 32
        scene.height = 32
        scene.clear = [0.0, 0.0, 0.0, 1.0]
        var rect = OracleGenerator.scene(records: [[UInt8](repeating: 0, count: 32)]).primitives[0]
        rect.rect = [0.0, 0.0, 32.0, 32.0]
        rect.radii = [0.0, 0.0, 0.0, 0.0]
        rect.fill = [1.0, 1.0, 1.0, 1.0]
        rect.border = [0.0, 0.0, 0.0, 0.0]
        rect.params = [0.0, 0.0, 0.0, 1.0]
        rect.clip = [0.0, 0.0, 32.0, 32.0]
        rect.fade = [0.0, 0.0, 0.0, 0.0]
        rect.clipRadii = [12.0, 12.0, 12.0, 12.0]
        scene.primitives = [rect]
        try scene.validate()
        var frame = OracleFrame(width: scene.width, height: scene.height, provenance: true)
        frame.render(scene)
        let corner = Array(frame.rgba[0..<4])
        let centerBase = (16 * 32 + 16) * 4
        let center = Array(frame.rgba[centerBase..<(centerBase + 4)])
        #expect(corner == [0, 0, 0, 255], "rounded clip must cut the corner")
        #expect(center == [255, 255, 255, 255], "centre stays filled")
    }
}
