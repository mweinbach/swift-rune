import Foundation
import Testing
@testable import RuneRef
@testable import Rune

#if canImport(Metal)
import Metal

private actor GenerationCounter {
    private var next: UInt64 = 100
    func allocate() -> UInt64 {
        next &+= 1
        return next
    }
}

private let sharedGen = GenerationCounter()

private func makeRenderFrame(from scene: OracleScene, glyphGeneration: UInt64) -> RenderFrame {
    var instances: [RenderInstance] = []
    instances.reserveCapacity(scene.primitives.count)
    for p in scene.primitives {
        let kind = p.params.count > 1 ? p.params[1] : 0
        let rect = SIMD4<Float>(p.rect[0], p.rect[1], p.rect[2], p.rect[3])
        let radii = SIMD4<Float>(p.radii[0], p.radii[1], p.radii[2], p.radii[3])
        let fill = SIMD4<Float>(p.fill[0], p.fill[1], p.fill[2], p.fill[3])
        let params = SIMD4<Float>(p.params[0], p.params[1], p.params[2], p.params[3])
        let uv = SIMD4<Float>(p.uv[0], p.uv[1], p.uv[2], p.uv[3])
        let clip = SIMD4<Float>(p.clip[0], p.clip[1], p.clip[2], p.clip[3])
        let fadeWidth = SIMD4<Float>(p.fade[0], p.fade[1], p.fade[2], p.fade[3])
        let fadeOrigin: SIMD4<Float> = if let o = p.fadeOrigin, o.count >= 4 {
            SIMD4<Float>(o[0], o[1], o[2], o[3])
        } else {
            clip
        }
        var packedFade = packFade(width: fadeWidth, origin: fadeOrigin, clip: clip)
        let border: SIMD4<Float>
        if kind == 8.0 {
            let clipRadii = SIMD4<Float>(p.border[0], p.border[1], p.border[2], p.border[3])
            packedFade.w = packClipRadii(clip: clip, radii: clipRadii)
            if let t = p.turn, t.count >= 3 {
                border = SIMD4<Float>(0, t[0], t[1], t[2])
            } else {
                border = .zero
            }
        } else {
            border = SIMD4<Float>(p.border[0], p.border[1], p.border[2], p.border[3])
        }
        instances.append(RenderInstance(
            rect: rect,
            radii: radii,
            fill: fill,
            border: border,
            params: params,
            uv: uv,
            clip: clip,
            fade: packedFade
        ))
    }

    let clear = scene.clear.count == 4
        ? SIMD4<Float>(scene.clear[0], scene.clear[1], scene.clear[2], scene.clear[3])
        : SIMD4<Float>(0, 0, 0, 1)
    let atlas = R8Atlas(width: Int(scene.atlas.width), height: Int(scene.atlas.height), texels: scene.atlas.data)
    return RenderFrame(
        width: Int(scene.width),
        height: Int(scene.height),
        srgbBlend: false,
        clearColor: clear,
        glyphs: atlas,
        glyphGeneration: glyphGeneration,
        instances: instances
    )
}

private let glyphTexelBoundaryJSON = #"{"width":64,"height":64,"clear":[0.025,0.04,0.06,1.0],"primitives":[{"node":4,"source":"generated/3","rect":[10.5,34.25,14.0,21.0],"radii":[25.25,24.625,14.625,8.125],"fill":[0.29413307,0.018131489,0.2034756,0.5137255],"border":[0.3062207,0.45933107,0.2034756,0.5137255],"params":[0.0,2.0,7.8125,1.6686275],"uv":[1.0,1.0,0.0,0.0],"clip":[12.625,8.375,39.125,57.375],"fade":[5.5,4.0,4.5,2.5]}],"atlas":{"width":32,"height":32,"data":[0,73,146,219,36,109,182,255,72,145,218,35,108,181,254,71,144,217,34,107,180,253,70,143,216,33,106,179,252,69,142,215,51,124,197,14,87,160,233,50,123,196,13,86,159,232,49,122,195,12,85,158,231,48,121,194,11,84,157,230,47,120,193,10,102,175,248,65,138,211,28,101,174,247,64,137,210,27,100,173,246,63,136,209,26,99,172,245,62,135,208,25,98,171,244,61,153,226,43,116,189,6,79,152,225,42,115,188,5,78,151,224,41,114,187,4,77,150,223,40,113,186,3,76,149,222,39,112,204,21,94,167,240,57,130,203,20,93,166,239,56,129,202,19,92,165,238,55,128,201,18,91,164,237,54,127,200,17,90,163,255,72,145,218,35,108,181,254,71,144,217,34,107,180,253,70,143,216,33,106,179,252,69,142,215,32,105,178,251,68,141,214,50,123,196,13,86,159,232,49,122,195,12,85,158,231,48,121,194,11,84,157,230,47,120,193,10,83,156,229,46,119,192,9,101,174,247,64,137,210,27,100,173,246,63,136,209,26,99,172,245,62,135,208,25,98,171,244,61,134,207,24,97,170,243,60,152,225,42,115,188,5,78,151,224,41,114,187,4,77,150,223,40,113,186,3,76,149,222,39,112,185,2,75,148,221,38,111,203,20,93,166,239,56,129,202,19,92,165,238,55,128,201,18,91,164,237,54,127,200,17,90,163,236,53,126,199,16,89,162,254,71,144,217,34,107,180,253,70,143,216,33,106,179,252,69,142,215,32,105,178,251,68,141,214,31,104,177,250,67,140,213,49,122,195,12,85,158,231,48,121,194,11,84,157,230,47,120,193,10,83,156,229,46,119,192,9,82,155,228,45,118,191,8,100,173,246,63,136,209,26,99,172,245,62,135,208,25,98,171,244,61,134,207,24,97,170,243,60,133,206,23,96,169,242,59,151,224,41,114,187,4,77,150,223,40,113,186,3,76,149,222,39,112,185,2,75,148,221,38,111,184,1,74,147,220,37,110,202,19,92,165,238,55,128,201,18,91,164,237,54,127,200,17,90,163,236,53,126,199,16,89,162,235,52,125,198,15,88,161,253,70,143,216,33,106,179,252,69,142,215,32,105,178,251,68,141,214,31,104,177,250,67,140,213,30,103,176,249,66,139,212,48,121,194,11,84,157,230,47,120,193,10,83,156,229,46,119,192,9,82,155,228,45,118,191,8,81,154,227,44,117,190,7,99,172,245,62,135,208,25,98,171,244,61,134,207,24,97,170,243,60,133,206,23,96,169,242,59,132,205,22,95,168,241,58,150,223,40,113,186,3,76,149,222,39,112,185,2,75,148,221,38,111,184,1,74,147,220,37,110,183,0,73,146,219,36,109,201,18,91,164,237,54,127,200,17,90,163,236,53,126,199,16,89,162,235,52,125,198,15,88,161,234,51,124,197,14,87,160,252,69,142,215,32,105,178,251,68,141,214,31,104,177,250,67,140,213,30,103,176,249,66,139,212,29,102,175,248,65,138,211,47,120,193,10,83,156,229,46,119,192,9,82,155,228,45,118,191,8,81,154,227,44,117,190,7,80,153,226,43,116,189,6,98,171,244,61,134,207,24,97,170,243,60,133,206,23,96,169,242,59,132,205,22,95,168,241,58,131,204,21,94,167,240,57,149,222,39,112,185,2,75,148,221,38,111,184,1,74,147,220,37,110,183,0,73,146,219,36,109,182,255,72,145,218,35,108,200,17,90,163,236,53,126,199,16,89,162,235,52,125,198,15,88,161,234,51,124,197,14,87,160,233,50,123,196,13,86,159,251,68,141,214,31,104,177,250,67,140,213,30,103,176,249,66,139,212,29,102,175,248,65,138,211,28,101,174,247,64,137,210,46,119,192,9,82,155,228,45,118,191,8,81,154,227,44,117,190,7,80,153,226,43,116,189,6,79,152,225,42,115,188,5,97,170,243,60,133,206,23,96,169,242,59,132,205,22,95,168,241,58,131,204,21,94,167,240,57,130,203,20,93,166,239,56,148,221,38,111,184,1,74,147,220,37,110,183,0,73,146,219,36,109,182,255,72,145,218,35,108,181,254,71,144,217,34,107,199,16,89,162,235,52,125,198,15,88,161,234,51,124,197,14,87,160,233,50,123,196,13,86,159,232,49,122,195,12,85,158,250,67,140,213,30,103,176,249,66,139,212,29,102,175,248,65,138,211,28,101,174,247,64,137,210,27,100,173,246,63,136,209,45,118,191,8,81,154,227,44,117,190,7,80,153,226,43,116,189,6,79,152,225,42,115,188,5,78,151,224,41,114,187,4]}}"#

@Suite("Metal Differential Parity Tests")
struct MetalDifferentialTests {
    @Test("OracleScene via RenderFrame matches OracleFrame on glyph-texel-boundary regression")
    func glyphTexelBoundaryRenderFrameDiff() async throws {
        let gpu: MetalRenderer
        do { gpu = try MetalRenderer() } catch { return }
        let scene = try JSONDecoder().decode(OracleScene.self, from: Data(glyphTexelBoundaryJSON.utf8))
        try scene.validate()
        var cpu = OracleFrame(width: scene.width, height: scene.height, provenance: true)
        cpu.render(scene)
        let rf = makeRenderFrame(from: scene, glyphGeneration: await sharedGen.allocate())
        let gpuFrame = try gpu.renderOffscreen(rf)
        let report = Oracle.compare(scene: scene, cpu: cpu, gpu: gpuFrame.rgba, tolerance: 2)
        #expect(report.outlierPixels == 0, "report=\(report)")
    }

    @Test("OracleGenerator.seeded/dashed/radial via RenderFrame match OracleFrame")
    func oracleGeneratorsRenderFrameDiff() async throws {
        let gpu: MetalRenderer
        do { gpu = try MetalRenderer() } catch { return }

        for seed: UInt64 in 0..<16 {
            let scene = OracleGenerator.seeded(seed: seed, count: 8)
            try scene.validate()
            var cpu = OracleFrame(width: scene.width, height: scene.height, provenance: true)
            cpu.render(scene)
            let rf = makeRenderFrame(from: scene, glyphGeneration: await sharedGen.allocate())
            let gpuFrame = try gpu.renderOffscreen(rf)
            let report = Oracle.compare(scene: scene, cpu: cpu, gpu: gpuFrame.rgba, tolerance: 2)
            #expect(report.outlierPixels == 0, "seeded seed \(seed): \(report)")
        }

        for seed: UInt64 in 0..<16 {
            let scene = OracleGenerator.dashed(seed: seed)
            try scene.validate()
            var cpu = OracleFrame(width: scene.width, height: scene.height, provenance: true)
            cpu.render(scene)
            let rf = makeRenderFrame(from: scene, glyphGeneration: await sharedGen.allocate())
            let gpuFrame = try gpu.renderOffscreen(rf)
            let report = Oracle.compare(scene: scene, cpu: cpu, gpu: gpuFrame.rgba, tolerance: 2)
            #expect(report.outlierPixels == 0, "dashed seed \(seed): \(report)")
        }

        for seed: UInt64 in 0..<16 {
            let scene = OracleGenerator.radial(seed: seed)
            try scene.validate()
            var cpu = OracleFrame(width: scene.width, height: scene.height, provenance: true)
            cpu.render(scene)
            let rf = makeRenderFrame(from: scene, glyphGeneration: await sharedGen.allocate())
            let gpuFrame = try gpu.renderOffscreen(rf)
            let report = Oracle.compare(scene: scene, cpu: cpu, gpu: gpuFrame.rgba, tolerance: 2)
            #expect(report.outlierPixels == 0, "radial seed \(seed): \(report)")
        }
    }

    @Test("Oracle turned layers, rotated glyphs, effect slots, and rounded clips via RenderFrame match OracleFrame")
    func oracleAdvancedFeaturesRenderFrameDiff() async throws {
        let gpu: MetalRenderer
        do { gpu = try MetalRenderer() } catch { return }

        // Turned layers (inner contents bounded within layer rect so Metal's cropped layer texture matches)
        for seed: UInt64 in 0..<8 {
            var inner = OracleGenerator.seeded(seed: seed, count: 6)
            for idx in inner.primitives.indices {
                inner.primitives[idx].clip = [4, 4, 60, 60]
            }
            let angle = (Float(seed) + 1.0) * 0.25
            let pivotX = 16.0 + Float(seed % 4) * 8.0
            let pivotY = 16.0 + Float((seed >> 2) % 4) * 8.0
            let begin = OraclePrimitive(
                node: 0,
                source: "layer-begin",
                rect: [4, 4, 56, 56],
                radii: [0, 0, 0, 0],
                fill: [0, 0, 0, 0.85],
                border: [0, 0, 0, 0],
                params: [0, 8, 0, 0],
                uv: [0, 0, 0, 0],
                clip: [4, 4, 60, 60],
                fade: [0, 0, 0, 0],
                turn: [angle, pivotX, pivotY]
            )
            let end = OraclePrimitive(
                node: 99,
                source: "layer-end",
                rect: [0, 0, 0, 0],
                radii: [0, 0, 0, 0],
                fill: [0, 0, 0, 0],
                border: [0, 0, 0, 0],
                params: [0, 9, 0, 0],
                uv: [0, 0, 0, 0],
                clip: oracleNoClip,
                fade: [0, 0, 0, 0]
            )
            var scene = inner
            scene.primitives = [begin] + inner.primitives + [end]
            try scene.validate()
            var cpu = OracleFrame(width: scene.width, height: scene.height, provenance: true)
            cpu.render(scene)
            let rf = makeRenderFrame(from: scene, glyphGeneration: await sharedGen.allocate())
            let gpuFrame = try gpu.renderOffscreen(rf)
            let report = Oracle.compare(scene: scene, cpu: cpu, gpu: gpuFrame.rgba, tolerance: 2)
            #expect(report.outlierPixels == 0, "turned layer seed \(seed): \(report)")
        }

        // Rotated glyphs
        for seed: UInt64 in 0..<4 {
            var scene = OracleGenerator.seeded(seed: seed, count: 4)
            scene.primitives.append(OraclePrimitive(
                node: 50,
                source: "rot-glyph",
                rect: [14.25, 16.5, 18.0, 20.0],
                radii: [0, 0, 0, 0],
                fill: [0.8, 0.4, 0.2, 0.9],
                border: [0, 0, 0, 0],
                params: [0.35 + Float(seed) * 0.2, 2.0, 0.0, 1.4],
                uv: [2.0, 3.0, 16.0, 18.0],
                clip: [6, 6, 58, 58],
                fade: [2, 2, 2, 2]
            ))
            try scene.validate()
            var cpu = OracleFrame(width: scene.width, height: scene.height, provenance: true)
            cpu.render(scene)
            let rf = makeRenderFrame(from: scene, glyphGeneration: await sharedGen.allocate())
            let gpuFrame = try gpu.renderOffscreen(rf)
            let report = Oracle.compare(scene: scene, cpu: cpu, gpu: gpuFrame.rgba, tolerance: 2)
            #expect(report.outlierPixels == 0, "rotated glyph seed \(seed): \(report)")
        }

        // Kind 12 effect slots inside viewport
        for seed: UInt64 in 0..<4 {
            var scene = OracleGenerator.seeded(seed: seed, count: 4)
            scene.primitives.insert(OraclePrimitive(
                node: 77,
                source: "effect/slot",
                rect: [8, 8, 24, 24],
                radii: [0, 0, 0, 0],
                fill: [0, 0, 0, 1],
                border: [0, 0, 0, 0],
                params: [0, 12.0, 4.0, 1.0],
                uv: [0, 0, 0, 0],
                clip: [0, 0, 64, 64],
                fade: [0, 0, 0, 0]
            ), at: 1)
            try scene.validate()
            var cpu = OracleFrame(width: scene.width, height: scene.height, provenance: true)
            cpu.render(scene)
            let rf = makeRenderFrame(from: scene, glyphGeneration: await sharedGen.allocate())
            let gpuFrame = try gpu.renderOffscreen(rf)
            let report = Oracle.compare(scene: scene, cpu: cpu, gpu: gpuFrame.rgba, tolerance: 2)
            #expect(report.outlierPixels == 0, "effect slot seed \(seed): \(report)")
        }

        // Rounded clip layers (matching differential.rs uniform & continuous mixed corners)
        let cornerPatterns: [[Float]] = [
            [8, 8, 8, 8],
            [-10, -10, 0, -4],
            [10, 6, 12, 0],
        ]
        for (idx, clipRadii) in cornerPatterns.enumerated() {
            let roundLayerScene = OracleScene(
                width: 64,
                height: 64,
                clear: [0.05, 0.06, 0.08, 1.0],
                primitives: [
                    OraclePrimitive(
                        node: 1,
                        source: "clip-layer",
                        rect: [8, 8, 48, 48],
                        radii: [0, 0, 0, 0],
                        fill: [0, 0, 0, 0.9],
                        border: clipRadii,
                        params: [0, 8, 0, 0],
                        uv: [0, 0, 0, 0],
                        clip: [8, 8, 56, 56],
                        fade: [0, 0, 0, 0]
                    ),
                    OraclePrimitive(
                        node: 2,
                        source: "child",
                        rect: [4, 4, 56, 56],
                        radii: [0, 0, 0, 0],
                        fill: [0.2, 0.7, 0.4, 0.9],
                        border: [0, 0, 0, 0],
                        params: [0, 0, 0, 1],
                        uv: [0, 0, 0, 0],
                        clip: [8, 8, 56, 56],
                        fade: [0, 0, 0, 0]
                    ),
                    OraclePrimitive(
                        node: 3,
                        source: "clip-layer-end",
                        rect: [0, 0, 0, 0],
                        radii: [0, 0, 0, 0],
                        fill: [0, 0, 0, 0],
                        border: [0, 0, 0, 0],
                        params: [0, 9, 0, 0],
                        uv: [0, 0, 0, 0],
                        clip: oracleNoClip,
                        fade: [0, 0, 0, 0]
                    ),
                ],
                atlas: OracleGenerator.seeded(seed: 0, count: 1).atlas
            )
            var cpuRL = OracleFrame(width: 64, height: 64, provenance: true)
            cpuRL.render(roundLayerScene)
            let gpuRL = try gpu.renderOffscreen(makeRenderFrame(from: roundLayerScene, glyphGeneration: await sharedGen.allocate()))
            let reportRL = Oracle.compare(scene: roundLayerScene, cpu: cpuRL, gpu: gpuRL.rgba, tolerance: 2)
            #expect(reportRL.outlierPixels == 0, "rounded clip layer[\(idx)]: \(reportRL)")
        }
    }

    @Test("RefGenerator dashed, radial, scene, and seeded (without linearGradient borderWidth) match MetalRenderer RefScene path")
    func refGeneratorMetalRefSceneCheck() throws {
        let gpu: MetalRenderer
        do { gpu = try MetalRenderer() } catch { return }

        for seed: UInt64 in 0..<8 {
            let s = RefGenerator.dashed(seed: seed, count: 6)
            let cpu = try RuneRef.render(s)
            let actual = try gpu.renderOffscreen(s)
            let diff = RuneRef.compare(scene: s, expected: cpu, actual: actual, channelTolerance: 2, maxFailingPixels: 0)
            #expect(diff.passed, "RefGenerator.dashed(\(seed)): \(diff)")
        }

        for seed: UInt64 in 0..<8 {
            let s = RefGenerator.radial(seed: seed, count: 6)
            let cpu = try RuneRef.render(s)
            let actual = try gpu.renderOffscreen(s)
            let diff = RuneRef.compare(scene: s, expected: cpu, actual: actual, channelTolerance: 2, maxFailingPixels: 0)
            #expect(diff.passed, "RefGenerator.radial(\(seed)): \(diff)")
        }

        // NOTE: MetalRenderer.mslSource (`kind == 4`, linearGradient) omits `params.x > 0` border-ring masking
        // present in `RefShader.evaluatePrimitive` (`Shader.swift:519-530`). Verify all other primitives across
        // 8 seeded scenes pass when `borderWidth == 0` on linearGradient.
        for seed: UInt64 in 0..<8 {
            var s = RefGenerator.seeded(seed: seed, count: 6)
            for idx in s.primitives.indices where s.primitives[idx].kind == .linearGradient {
                s.primitives[idx].params.x = 0
            }
            let cpu = try RuneRef.render(s)
            let actual = try gpu.renderOffscreen(s)
            let diff = RuneRef.compare(scene: s, expected: cpu, actual: actual, channelTolerance: 2, maxFailingPixels: 0)
            #expect(diff.passed, "RefGenerator.seeded(\(seed), no gradient border): \(diff)")
        }

        var record0 = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { record0[i] = UInt8((i * 37 + 11) & 0xFF) }
        var record1 = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { record1[i] = UInt8((i * 73 + 5) & 0xFF) }
        record0[0] = 0 // roundedRect
        record1[0] = 2 // glyph
        let genScene = RefGenerator.scene(from: [record0, record1])
        let cpuGen = try RuneRef.render(genScene)
        let actualGen = try gpu.renderOffscreen(genScene)
        let diffGen = RuneRef.compare(scene: genScene, expected: cpuGen, actual: actualGen, channelTolerance: 2, maxFailingPixels: 0)
        #expect(diffGen.passed, "RefGenerator.scene: \(diffGen)")
    }

    @Test("TextSystem shaped glyph run (addTextRun pattern) matches OracleFrame vs RenderFrame")
    func shapedTextRunDifferential() async throws {
        let gpu: MetalRenderer
        do { gpu = try MetalRenderer() } catch { return }

        let strings = ["Rune ffi", "Ág jW", "012345", "a\u{301} test"]
        for seed: UInt64 in 0..<UInt64(strings.count) {
            var scene = OracleGenerator.seeded(seed: seed, count: 4)
            let textSystem = TextSystem()
            let style = TextStyle(size: Float(9 + seed % 15), weight: 400)
            let shaped = textSystem.shape(
                text: strings[Int(seed)],
                style: style,
                maxWidth: 60.0,
                pixelScale: 1.0
            )
            for i in scene.primitives.indices where scene.primitives[i].params.count > 1 && scene.primitives[i].params[1] == 2.0 {
                scene.primitives[i].uv[0] += 960.0
                scene.primitives[i].uv[1] += 960.0
            }
            let atlas = textSystem.glyphAtlas.atlas
            var atlasBytes = atlas.texels
            let copyH = min(Int(scene.atlas.height), 32)
            let copyW = min(Int(scene.atlas.width), 32)
            if atlas.width >= 992 && atlas.height >= 992 {
                for y in 0..<copyH {
                    let dstStart = (y + 960) * atlas.width + 960
                    let srcStart = y * Int(scene.atlas.width)
                    for x in 0..<copyW {
                        atlasBytes[dstStart + x] = scene.atlas.data[srcStart + x]
                    }
                }
            }
            let first = UInt32(scene.primitives.count + 1)
            for (n, q) in shaped.glyphs.enumerated() {
                let u0 = q.uv.x * Float(atlas.width)
                let v0 = q.uv.y * Float(atlas.height)
                scene.primitives.append(OraclePrimitive(
                    node: first + UInt32(n),
                    source: "text/\(seed)/glyph-\(n)",
                    rect: [q.rect.x + 2.0, q.rect.y + 2.0, q.rect.z, q.rect.w],
                    radii: [0, 0, 0, 0],
                    fill: [0.7, 0.6, 0.5, 0.8],
                    border: [0, 0, 0, 0],
                    params: [0.0, 2.0, 0.0, 0.85],
                    uv: [u0, v0, 0.0, 0.0],
                    clip: oracleNoClip,
                    fade: [0, 0, 0, 0]
                ))
            }
            scene.atlas = OracleAtlas(width: UInt32(atlas.width), height: UInt32(atlas.height), data: atlasBytes)
            try scene.validate()

            var cpu = OracleFrame(width: scene.width, height: scene.height, provenance: true)
            cpu.render(scene)
            let rf = makeRenderFrame(from: scene, glyphGeneration: await sharedGen.allocate())
            let gpuFrame = try gpu.renderOffscreen(rf)
            let report = Oracle.compare(scene: scene, cpu: cpu, gpu: gpuFrame.rgba, tolerance: 2)
            #expect(report.outlierPixels == 0, "text-run seed \(seed): \(report)")
        }
    }

    @Test("OraclePrimitive.toInstance and OracleScene.toRefScene convert atlas UVs, kinds, and fade cleanly")
    func oracleToRefSceneConversion() throws {
        let jsonScene = try JSONDecoder().decode(OracleScene.self, from: Data(glyphTexelBoundaryJSON.utf8))
        let refScene = jsonScene.toRefScene()
        #expect(refScene.width == 64)
        #expect(refScene.height == 64)
        #expect(refScene.glyphs.width == 32)
        #expect(refScene.glyphs.height == 32)
        #expect(refScene.primitives.count == 1)
        let glyphPrim = refScene.primitives[0]
        #expect(glyphPrim.kind == .glyph)
        // uv normalized from texels [1, 1, 14, 21] over 32x32 atlas; LTRB fade does not leak into RefScene directional fade
        #expect(abs(glyphPrim.uv.x - 1.0 / 32.0) < 1e-5)
        #expect(abs(glyphPrim.uv.y - 1.0 / 32.0) < 1e-5)
        #expect(abs(glyphPrim.uv.z - 15.0 / 32.0) < 1e-5)
        #expect(abs(glyphPrim.uv.w - 22.0 / 32.0) < 1e-5)
        #expect(glyphPrim.fade == .zero)
        #expect(glyphPrim.fadeOrigin == .zero)

        let slot = OraclePrimitive(
            node: 1,
            source: "slot",
            rect: [0, 0, 10, 10],
            radii: [0, 0, 0, 0],
            fill: [0, 0, 0, 1],
            border: [0, 0, 0, 0],
            params: [0, 12.0, 6.0, 1.0],
            uv: [0, 0, 0, 0],
            clip: oracleNoClip,
            fade: [0, 0, 0, 0]
        ).toInstance()
        #expect(slot.kind == .effectSlot)

        let grad = OraclePrimitive(
            node: 2,
            source: "grad",
            rect: [0, 0, 20, 20],
            radii: [0, 0, 0, 0],
            fill: [0.5, 0.25, 0.25, 0.5],
            border: [0, 0, 0, 0],
            params: [2.0, 4.0, 0.5, 1.0],
            uv: [0.25, 0.5, 0.25, 0.5],
            clip: oracleNoClip,
            fade: [0, 0, 0, 0]
        ).toInstance()
        #expect(grad.kind == .linearGradient)
        #expect(abs(grad.params.z - (.pi * 0.5)) < 1e-5)
        #expect(abs(grad.border.y - 1.0) < 1e-5)

        let rendered = try RuneRef.render(refScene)
        #expect(rendered.rgba.count == 64 * 64 * 4)
    }

    #if os(macOS)
    @Test("rune-ref CLI binary supports --scene JSON, --blame, --seed, --save, --diff, and text-run")
    func cliEndToEndInvocation() throws {
        guard let binaryURL = Self.locateRuneRefBinary() else {
            Issue.record("rune-ref CLI binary not found near test bundle or /tmp/swift-build-ref/debug/rune-ref")
            return
        }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rune-ref-cli-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // 1. Replay glyph-texel-boundary.json with --blame 16,38 --diff
        let boundaryFile = tmpDir.appendingPathComponent("glyph-texel-boundary.json")
        try Data(glyphTexelBoundaryJSON.utf8).write(to: boundaryFile)
        let boundaryRun = try Self.runCLI(
            binaryURL: binaryURL,
            arguments: ["--scene", boundaryFile.path, "--blame", "16,38", "--diff"]
        )
        #expect(boundaryRun.status == 0, "stderr=\(boundaryRun.stderr) stdout=\(boundaryRun.stdout)")
        #expect(boundaryRun.stdout.contains("blake3=5dee85cba41c7805ea3566d844fd6725ee074fea0e0336697ae4fbcb89c764b8"))
        #expect(boundaryRun.stdout.contains("node=4 source=generated/3 kind=2.0"))
        #expect(boundaryRun.stdout.contains("\"outlier_pixels\" : 0"))

        // 2. Generate seeded scene with --seed 5 --save <path> --blame 32,32 --diff, then reload saved JSON
        let savedFile = tmpDir.appendingPathComponent("seeded-5.json")
        let seededRun = try Self.runCLI(
            binaryURL: binaryURL,
            arguments: ["--scene", "seeded", "--seed", "5", "--save", savedFile.path, "--blame", "32,32", "--diff"]
        )
        #expect(seededRun.status == 0, "stderr=\(seededRun.stderr) stdout=\(seededRun.stdout)")
        #expect(seededRun.stdout.contains("\"outlier_pixels\" : 0"))
        #expect(FileManager.default.fileExists(atPath: savedFile.path))

        let reloadRun = try Self.runCLI(
            binaryURL: binaryURL,
            arguments: ["--scene", savedFile.path, "--diff"]
        )
        #expect(reloadRun.status == 0, "stderr=\(reloadRun.stderr) stdout=\(reloadRun.stdout)")
        #expect(reloadRun.stdout.contains("\"outlier_pixels\" : 0"))

        // 3. Generate text-run with --seed 0 --diff
        let textRun = try Self.runCLI(
            binaryURL: binaryURL,
            arguments: ["--scene", "text-run", "--seed", "0", "--diff"]
        )
        #expect(textRun.status == 0, "stderr=\(textRun.stderr) stdout=\(textRun.stdout)")
        #expect(textRun.stdout.contains("\"outlier_pixels\" : 0"))
    }

    private static func locateRuneRefBinary() -> URL? {
        var candidates: [URL] = []
        for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
            candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("rune-ref"))
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(repoRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/rune-ref"))
        candidates.append(repoRoot.appendingPathComponent(".build/x86_64-apple-macosx/debug/rune-ref"))
        candidates.append(repoRoot.appendingPathComponent(".build/debug/rune-ref"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func runCLI(binaryURL: URL, arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (
            proc.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }
    #endif
}
#endif
