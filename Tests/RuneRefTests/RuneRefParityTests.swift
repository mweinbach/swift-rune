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
}
