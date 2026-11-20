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

private func oraclePrimitive(from inst: RenderInstance, node: UInt32, source: String) -> OraclePrimitive {
    let (fadeW, off) = unpackFade(inst.fade)
    let fade = [fadeW.x, fadeW.y, fadeW.z, fadeW.w]
    let clip = [inst.clip.x, inst.clip.y, inst.clip.z, inst.clip.w]
    let isLayer = inst.params.y == 8.0
    let border: [Float]
    if isLayer {
        let cr = unpackClipRadii(inst.fade.w)
        border = [cr.x, cr.y, cr.z, cr.w]
    } else {
        border = [inst.border.x, inst.border.y, inst.border.z, inst.border.w]
    }
    let fadeOrigin: [Float] = [
        clip[0] - off.x * abs(fade[0]),
        clip[1] - off.y * abs(fade[1]),
        clip[2] + off.z * abs(fade[2]),
        clip[3] + off.w * abs(fade[3]),
    ]
    let turn: [Float]? = (isLayer && inst.border.y != 0.0)
        ? [inst.border.y, inst.border.z, inst.border.w]
        : nil
    let clipRadii: [Float]? = (!isLayer && inst.fade.w != 0)
        ? {
            let cr = unpackClipRadii(inst.fade.w)
            return [cr.x, cr.y, cr.z, cr.w]
        }()
        : nil
    return OraclePrimitive(
        node: node,
        source: source,
        rect: [inst.rect.x, inst.rect.y, inst.rect.z, inst.rect.w],
        radii: [inst.radii.x, inst.radii.y, inst.radii.z, inst.radii.w],
        fill: [inst.fill.x, inst.fill.y, inst.fill.z, inst.fill.w],
        border: border,
        params: [inst.params.x, inst.params.y, inst.params.z, inst.params.w],
        uv: [inst.uv.x, inst.uv.y, inst.uv.z, inst.uv.w],
        clip: clip,
        fade: fade,
        fadeOrigin: fadeOrigin,
        turn: turn,
        clipRadii: clipRadii
    )
}

private func renderInstance(from p: OraclePrimitive) -> RenderInstance {
    let kind = p.params.count > 1 ? p.params[1] : 0
    let rect = SIMD4<Float>(p.rect[0], p.rect[1], p.rect[2], p.rect[3])
    // `OracleScene` carries one grayscale R8 glyph atlas and no outline store; clear legacy
    // non-zero `radii` and `params[2]` on glyphs so Metal never routes them to
    // `outline_glyph`, `lcd_mask`, or secondary atlas pages.
    let radii: SIMD4<Float> = kind == 2.0 ? .zero : SIMD4<Float>(p.radii[0], p.radii[1], p.radii[2], p.radii[3])
    let fill = SIMD4<Float>(p.fill[0], p.fill[1], p.fill[2], p.fill[3])
    let params: SIMD4<Float> = kind == 2.0
        ? SIMD4<Float>(p.params[0], p.params[1], 0.0, p.params[3])
        : SIMD4<Float>(p.params[0], p.params[1], p.params[2], p.params[3])
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
        let r = p.clipRadii ?? p.border
        let clipRadii = SIMD4<Float>(r[0], r[1], r[2], r[3])
        packedFade.w = packClipRadii(clip: clip, radii: clipRadii)
        if let t = p.turn, t.count >= 3 {
            border = SIMD4<Float>(0, t[0], t[1], t[2])
        } else {
            border = .zero
        }
    } else {
        border = SIMD4<Float>(p.border[0], p.border[1], p.border[2], p.border[3])
        if let r = p.clipRadii, r.count == 4 {
            packedFade.w = packClipRadii(clip: clip, radii: SIMD4<Float>(r[0], r[1], r[2], r[3]))
        }
    }
    return RenderInstance(
        rect: rect,
        radii: radii,
        fill: fill,
        border: border,
        params: params,
        uv: uv,
        clip: clip,
        fade: packedFade
    )
}

private func makeRenderFrame(from scene: OracleScene, glyphGeneration: UInt64) -> RenderFrame {
    let instances = scene.primitives.map(renderInstance(from:))

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
    private final class TestBundleMarker: NSObject {}

    @Test("rune-ref CLI binary supports --scene JSON, --blame, --seed, --save, --diff, and text-run")
    func cliEndToEndInvocation() throws {
        let binaryURL = Bundle(for: TestBundleMarker.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("rune-ref")
        try #require(FileManager.default.isExecutableFile(atPath: binaryURL.path), "Missing CLI at \(binaryURL.path)")

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

    @Test("differential.rs:74 cpu_gpu_proptest across 128 OracleGenerator.scene cases")
    func cpuGpuProptestRenderFrameDiff() async throws {
        let gpu: MetalRenderer
        do { gpu = try MetalRenderer() } catch { return }

        var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
        func nextByte() -> UInt8 {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return UInt8((rng >> 24) & 0xFF)
        }

        for c in 0..<128 {
            let count = 1 + (c % 8)
            var records: [[UInt8]] = []
            records.reserveCapacity(count)
            for _ in 0..<count {
                records.append((0..<32).map { _ in nextByte() })
            }
            let scene = OracleGenerator.scene(records: records)
            try scene.validate()
            var cpu = OracleFrame(width: scene.width, height: scene.height, provenance: true)
            cpu.render(scene)
            let rf = makeRenderFrame(from: scene, glyphGeneration: await sharedGen.allocate())
            let gpuFrame = try gpu.renderOffscreen(rf)
            let report = Oracle.compare(scene: scene, cpu: cpu, gpu: gpuFrame.rgba, tolerance: 2)
            #expect(report.outlierPixels == 0, "cpu_gpu_proptest case \(c): \(report)")
        }
    }

    @Test("differential.rs:151 gpu_metamorphic translation, transparent, unclipped, and disjoint permutation")
    func gpuMetamorphicRenderFrameDiff() async throws {
        let gpu: MetalRenderer
        do { gpu = try MetalRenderer() } catch { return }

        func close(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { abs(Int($0.0) - Int($0.1)) <= 2 }
        }

        for seed: UInt64 in 0..<32 {
            let scene = OracleGenerator.seeded(seed: seed, count: 8)
            let original = try gpu.renderOffscreen(makeRenderFrame(from: scene, glyphGeneration: await sharedGen.allocate())).rgba

            var shifted = scene
            shifted.width += 4
            shifted.height += 6
            OracleGenerator.translate(&shifted, x: 4.0, y: 6.0)
            let actualShifted = try gpu.renderOffscreen(makeRenderFrame(from: shifted, glyphGeneration: await sharedGen.allocate())).rgba
            for y in 0..<64 {
                let rowA = original[(y * 256)..<((y + 1) * 256)]
                let rowB = actualShifted[((y + 6) * 68 + 4) * 4 ..< ((y + 6) * 68 + 68) * 4]
                #expect(close(rowA, rowB), "translated mismatch seed \(seed) row \(y)")
            }

            var transparent = scene
            for var p in scene.primitives {
                p.fill = [0, 0, 0, 0]
                p.border = [0, 0, 0, 0]
                if p.params[1] == 4.0 {
                    p.uv = [0, 0, 0, 0]
                }
                transparent.primitives.append(p)
            }
            let transparentRgba = try gpu.renderOffscreen(makeRenderFrame(from: transparent, glyphGeneration: await sharedGen.allocate())).rgba
            #expect(original == transparentRgba, "transparent injection mismatch seed \(seed)")

            var full = scene
            for i in full.primitives.indices {
                full.primitives[i].clip = oracleNoClip
                full.primitives[i].fade = [0, 0, 0, 0]
            }
            let unclipped = try gpu.renderOffscreen(makeRenderFrame(from: full, glyphGeneration: await sharedGen.allocate())).rgba
            for i in full.primitives.indices {
                full.primitives[i].clip = [0, 0, 64, 64]
            }
            let viewportClipped = try gpu.renderOffscreen(makeRenderFrame(from: full, glyphGeneration: await sharedGen.allocate())).rgba
            #expect(close(unclipped[...], viewportClipped[...]), "viewport clip mismatch seed \(seed)")

            var disjoint = scene
            for i in disjoint.primitives.indices {
                disjoint.primitives[i].clip = [0, 0, 31, 64]
                disjoint.primitives[i].fade = [0, 0, 0, 0]
            }
            let n = disjoint.primitives.count
            for var p in scene.primitives {
                p.rect[0] += 32.0
                p.clip = [32, 0, 64, 64]
                p.fade = [0, 0, 0, 0]
                disjoint.primitives.append(p)
            }
            let first = try gpu.renderOffscreen(makeRenderFrame(from: disjoint, glyphGeneration: await sharedGen.allocate())).rgba
            disjoint.primitives = Array(disjoint.primitives.dropFirst(n) + disjoint.primitives.prefix(n))
            let rotated = try gpu.renderOffscreen(makeRenderFrame(from: disjoint, glyphGeneration: await sharedGen.allocate())).rgba
            #expect(first == rotated, "disjoint permutation mismatch seed \(seed)")
        }
    }

    @Test("differential.rs:281 multi-stop radial gradient bands match OracleFrame")
    func cpuGpuMultiStopRadialRenderFrameDiff() async throws {
        let gpu: MetalRenderer
        do { gpu = try MetalRenderer() } catch { return }

        var multi = OracleGenerator.scene(records: [])
        let base = OraclePrimitive(
            node: 1,
            source: "radial/multi-0",
            rect: [8, 8, 48, 48],
            radii: [12, 12, 12, 12],
            fill: [0.8, 0.2, 0.1, 0.9],
            border: [0.2, 0.7, 0.4, 0.9],
            params: [0.0, 11.0, 0.0, 2.5],
            uv: [24, 24, 24, 20],
            clip: oracleNoClip,
            fade: [0, 0, 0, 0]
        )
        var outer = base
        outer.node = 2
        outer.source = "radial/multi-1"
        outer.fill = base.border
        outer.border = [0.05, 0.1, 0.3, 0.4]
        outer.params = [2.5, 11.0, 0.0, 1.0]
        multi.primitives = [base, outer]
        try multi.validate()

        var cpu = OracleFrame(width: multi.width, height: multi.height, provenance: true)
        cpu.render(multi)
        let rf = makeRenderFrame(from: multi, glyphGeneration: await sharedGen.allocate())
        let gpuFrame = try gpu.renderOffscreen(rf)
        let report = Oracle.compare(scene: multi, cpu: cpu, gpu: gpuFrame.rgba, tolerance: 2)
        #expect(report.outlierPixels == 0, "multi-stop radial: \(report)")
    }

    private static func makeOracleScene(from rf: RenderFrame, prefix: String) -> OracleScene {
        let primitives: [OraclePrimitive] = rf.instances.enumerated().map { idx, inst in
            oraclePrimitive(from: inst, node: UInt32(idx + 1), source: "\(prefix)/\(idx)")
        }
        return OracleScene(
            width: UInt32(rf.width),
            height: UInt32(rf.height),
            clear: [rf.clearColor.x, rf.clearColor.y, rf.clearColor.z, rf.clearColor.w],
            primitives: primitives,
            atlas: OracleAtlas(width: UInt32(rf.glyphs.width), height: UInt32(rf.glyphs.height), data: rf.glyphs.texels)
        )
    }

    @Test("differential.rs:316 cpu_gpu_cached_subtrees and scrolled multi-line text culling parity")
    func cpuGpuCachedSubtreesAndScrolledText() throws {
        let gpu: MetalRenderer
        do { gpu = try MetalRenderer() } catch { return }

        func makeRuntime(cached: Bool) -> Runtime<Bool> {
            let rt = Runtime(state: cached, viewport: Vec2(64, 64), pixelScale: 1.0, systemDark: true) { isCached, _ in
                var card: El<Bool> = col()
                    .w(48)
                    .h(44)
                    .p(4)
                    .gap(3)
                    .bg(.srgb(0.18, 0.24, 0.36, 1.0))
                    .rounded(8)
                    .border(1, .srgb(0.45, 0.62, 0.88, 1.0))
                    .child(text("Rune").color(.srgb(1, 1, 1, 1)))
                    .child(col().w(36).h(12).bg(.srgb(0.85, 0.32, 0.28, 0.85)).rounded(4))
                if isCached {
                    card = card.cache(true)
                }
                return col()
                    .w(64)
                    .h(64)
                    .p(8)
                    .bg(.srgb(0.06, 0.08, 0.12, 1.0))
                    .child(card)
            }
            rt.srgbBlend = false
            return rt
        }

        let uncachedRt = makeRuntime(cached: false)
        let cachedRt = makeRuntime(cached: true)
        let uncachedRF = uncachedRt.renderFrame(at: 0)
        let cachedRF = cachedRt.renderFrame(at: 0)

        #expect(cachedRF.instances.contains { $0.params.y == 8.0 && $0.params.w == 1.0 })

        let uncachedOracle = Self.makeOracleScene(from: uncachedRF, prefix: "uncached")
        let cachedOracle = Self.makeOracleScene(from: cachedRF, prefix: "cache")
        try uncachedOracle.validate()
        try cachedOracle.validate()

        var cpuUncached = OracleFrame(width: uncachedOracle.width, height: uncachedOracle.height, provenance: true)
        cpuUncached.render(uncachedOracle)
        var cpuCached = OracleFrame(width: cachedOracle.width, height: cachedOracle.height, provenance: true)
        cpuCached.render(cachedOracle)

        let gpuUncached = try gpu.renderOffscreen(uncachedRF)
        let gpuCached = try gpu.renderOffscreen(cachedRF)

        let diffUncached = Oracle.compare(scene: uncachedOracle, cpu: cpuUncached, gpu: gpuUncached.rgba, tolerance: 2)
        #expect(diffUncached.outlierPixels == 0, "uncached CPU vs GPU: \(diffUncached)")
        let diffCached = Oracle.compare(scene: cachedOracle, cpu: cpuCached, gpu: gpuCached.rgba, tolerance: 2)
        #expect(diffCached.outlierPixels == 0, "cached CPU vs GPU: \(diffCached)")
        let diffCachedVsUncached = Oracle.compare(scene: cachedOracle, cpu: cpuUncached, gpu: gpuCached.rgba, tolerance: 2)
        #expect(diffCachedVsUncached.outlierPixels == 0, "cached GPU vs uncached CPU: \(diffCachedVsUncached)")
        #expect(gpuUncached.rgba.count == gpuCached.rgba.count)
        for (a, b) in zip(gpuUncached.rgba, gpuCached.rgba) {
            #expect(abs(Int(a) - Int(b)) <= 1, "cached vs uncached GPU mismatch: \(a) vs \(b)")
        }

        let lines = (0..<40).map { String(format: "Line %02d rune", $0) }.joined(separator: "\n")
        let scrollRt = Runtime(state: (), viewport: Vec2(64, 64), pixelScale: 1.0, systemDark: true) { _, _ in
            col()
                .w(64)
                .h(64)
                .p(6)
                .bg(.srgb(0.06, 0.08, 0.12, 1.0))
                .child(
                    col()
                        .wFull()
                        .h(52)
                        .scrollY()
                        .child(text(lines).font(TextStyle(size: 11, weight: 400, lineHeight: 14)).color(.srgb(1, 1, 1, 1)))
                )
        }
        scrollRt.srgbBlend = false
        _ = scrollRt.renderFrame(at: 0)
        scrollRt.wheel(WheelEvent(dx: 0, dy: -145), at: Vec2(32, 32), now: 0)
        let scrolledRF = scrollRt.renderFrame(at: 1.0 / 60.0)
        let scrolledOracle = Self.makeOracleScene(from: scrolledRF, prefix: "scroll")
        try scrolledOracle.validate()
        var cpuScrolled = OracleFrame(width: scrolledOracle.width, height: scrolledOracle.height, provenance: true)
        cpuScrolled.render(scrolledOracle)
        let gpuScrolled = try gpu.renderOffscreen(scrolledRF)
        let diffScrolled = Oracle.compare(scene: scrolledOracle, cpu: cpuScrolled, gpu: gpuScrolled.rgba, tolerance: 2)
        #expect(diffScrolled.outlierPixels == 0, "scrolled multi-line text CPU vs GPU: \(diffScrolled)")
    }

    @Test("differential.rs:509 cpu_gpu_plus_lighter_layers")
    func cpuGpuPlusLighterLayers() async throws {
        let gpu: MetalRenderer
        do { gpu = try MetalRenderer() } catch { return }
        var scene = OracleGenerator.scene(records: [])
        scene.width = 48
        scene.height = 48
        // Coloured background, then a PlusLighter dissolve layer with opacity 0.7 containing two
        // overlapping rects whose sum saturates past 1.0, plus a nested opaque SourceOver layer
        // (which must isolate rather than flatten into the additive parent).
        let bg = RenderInstance(
            rect: SIMD4<Float>(0, 0, 48, 48),
            radii: .zero,
            fill: SIMD4<Float>(0.1, 0.2, 0.5, 1.0),
            border: .zero,
            params: SIMD4<Float>(0, KIND_RECT, 0, 1.0),
            uv: .zero,
            clip: NO_CLIP,
            fade: .zero
        )
        let layerOpen = RenderInstance.beginLayer(
            bounds: SIMD4<Float>(4, 4, 40, 40),
            clip: NO_CLIP,
            spec: LayerSpec(opacity: 0.7, blend: .plusLighter)
        )
        let childA = RenderInstance(
            rect: SIMD4<Float>(6, 6, 26, 26),
            radii: SIMD4<Float>(repeating: 4.0),
            fill: SIMD4<Float>(0.6, 0.15, 0.05, 0.65),
            border: .zero,
            params: SIMD4<Float>(0, KIND_RECT, 0, 1.0),
            uv: .zero,
            clip: NO_CLIP,
            fade: .zero
        )
        let childB = RenderInstance(
            rect: SIMD4<Float>(16, 16, 26, 26),
            radii: SIMD4<Float>(repeating: 4.0),
            fill: SIMD4<Float>(0.55, 0.45, 0.1, 0.6),
            border: .zero,
            params: SIMD4<Float>(0, KIND_RECT, 0, 1.0),
            uv: .zero,
            clip: NO_CLIP,
            fade: .zero
        )
        let innerOpen = RenderInstance.beginLayer(
            bounds: SIMD4<Float>(12, 24, 20, 16),
            clip: NO_CLIP,
            spec: LayerSpec()
        )
        let innerA = RenderInstance(
            rect: SIMD4<Float>(12, 24, 14, 14),
            radii: .zero,
            fill: SIMD4<Float>(0.0, 0.4, 0.0, 0.5),
            border: .zero,
            params: SIMD4<Float>(0, KIND_RECT, 0, 1.0),
            uv: .zero,
            clip: NO_CLIP,
            fade: .zero
        )
        let innerB = RenderInstance(
            rect: SIMD4<Float>(18, 26, 14, 14),
            radii: .zero,
            fill: SIMD4<Float>(0.0, 0.4, 0.3, 0.5),
            border: .zero,
            params: SIMD4<Float>(0, KIND_RECT, 0, 1.0),
            uv: .zero,
            clip: NO_CLIP,
            fade: .zero
        )
        let instances = [
            bg,
            layerOpen,
            childA,
            childB,
            innerOpen,
            innerA,
            innerB,
            RenderInstance.endLayer(),
            RenderInstance.endLayer(),
        ]
        scene.primitives = instances.enumerated().map { idx, inst in
            oraclePrimitive(from: inst, node: UInt32(idx + 1), source: "plus-lighter/\(idx)")
        }
        try scene.validate()
        var cpu = OracleFrame(width: scene.width, height: scene.height, provenance: true)
        cpu.render(scene)
        let rf = makeRenderFrame(from: scene, glyphGeneration: await sharedGen.allocate())
        let gpuFrame = try gpu.renderOffscreen(rf)
        let report = Oracle.compare(scene: scene, cpu: cpu, gpu: gpuFrame.rgba, tolerance: 2)
        #expect(report.outlierPixels == 0, "plus-lighter: \(report)")
    }

    @Test("differential.rs:597 cpu_gpu_continuous_corners")
    func cpuGpuContinuousCorners() async throws {
        let gpu: MetalRenderer
        do { gpu = try MetalRenderer() } catch { return }
        var scene = OracleGenerator.scene(records: [])
        scene.width = 64
        scene.height = 64
        let rect = RenderInstance(
            rect: SIMD4<Float>(4, 4, 26, 26),
            radii: SIMD4<Float>(repeating: -8.0),
            fill: SIMD4<Float>(0.7, 0.2, 0.3, 0.9),
            border: SIMD4<Float>(0.9, 0.8, 0.2, 0.9),
            params: SIMD4<Float>(2.0, KIND_RECT, 0.0, 0.9),
            uv: .zero,
            clip: NO_CLIP,
            fade: .zero
        )
        let grad = RenderInstance(
            rect: SIMD4<Float>(34, 4, 26, 26),
            radii: SIMD4<Float>(-10.0, 0.0, -6.0, 4.0),
            fill: SIMD4<Float>(0.2, 0.6, 0.9, 1.0),
            border: .zero,
            params: SIMD4<Float>(0.0, KIND_GRADIENT, 0.0, 1.0),
            uv: SIMD4<Float>(0.1, 0.2, 0.6, 1.0),
            clip: NO_CLIP,
            fade: .zero
        )
        let inset = RenderInstance(
            rect: SIMD4<Float>(8, 34, 48, 24),
            radii: SIMD4<Float>(repeating: -7.0),
            fill: SIMD4<Float>(0.0, 0.0, 0.0, 0.6),
            border: .zero,
            params: SIMD4<Float>(2.0, KIND_INSET, 3.0, 1.0),
            uv: SIMD4<Float>(1.0, 2.0, 0.0, 0.0),
            clip: NO_CLIP,
            fade: .zero
        )
        scene.primitives = [rect, grad, inset].enumerated().map { idx, inst in
            oraclePrimitive(from: inst, node: UInt32(idx + 1), source: "continuous/\(idx)")
        }
        try scene.validate()
        var cpu = OracleFrame(width: scene.width, height: scene.height, provenance: true)
        cpu.render(scene)
        let rf = makeRenderFrame(from: scene, glyphGeneration: await sharedGen.allocate())
        let gpuFrame = try gpu.renderOffscreen(rf)
        let report = Oracle.compare(scene: scene, cpu: cpu, gpu: gpuFrame.rgba, tolerance: 2)
        #expect(report.outlierPixels == 0, "continuous-corners: \(report)")
    }

    @Test("differential.rs:646 cpu_gpu_linear_fade_offset")
    func cpuGpuLinearFadeOffset() async throws {
        let gpu: MetalRenderer
        do { gpu = try MetalRenderer() } catch { return }
        var scene = OracleGenerator.scene(records: [])
        scene.width = 64
        scene.height = 64
        let clip = SIMD4<Float>(12.0, 10.0, 52.0, 54.0)
        // Negative widths select linear ramps; origin lies outside clip on all four edges so the
        // ramp starts partially progressed at the hard clip boundary.
        let fadeWidths = SIMD4<Float>(-16.0, -12.0, -20.0, -10.0)
        let origin = SIMD4<Float>(4.0, 4.0, 62.0, 59.0)
        let inst = RenderInstance(
            rect: SIMD4<Float>(0, 0, 64, 64),
            radii: .zero,
            fill: SIMD4<Float>(0.85, 0.45, 0.2, 1.0),
            border: .zero,
            params: SIMD4<Float>(0, KIND_RECT, 0, 1.0),
            uv: .zero,
            clip: clip,
            fade: packFade(width: fadeWidths, origin: origin, clip: clip)
        )
        let prim = oraclePrimitive(from: inst, node: 1, source: "linear-fade-offset")
        // Round-trip must preserve the packed origin offsets, not flip them across the clip edge.
        let roundtrip = renderInstance(from: prim)
        #expect(roundtrip.fade.z == inst.fade.z, "linear fade origin offsets must survive round-trip")
        scene.primitives = [prim]
        try scene.validate()
        var cpu = OracleFrame(width: scene.width, height: scene.height, provenance: true)
        cpu.render(scene)
        let rf = makeRenderFrame(from: scene, glyphGeneration: await sharedGen.allocate())
        let gpuFrame = try gpu.renderOffscreen(rf)
        let report = Oracle.compare(scene: scene, cpu: cpu, gpu: gpuFrame.rgba, tolerance: 2)
        #expect(report.outlierPixels == 0, "linear-fade-offset: \(report)")
    }

    @Test("differential.rs:679 cpu_gpu_rounded_clip_on_primitive")
    func cpuGpuRoundedClipOnPrimitive() async throws {
        let gpu: MetalRenderer
        do { gpu = try MetalRenderer() } catch { return }
        var scene = OracleGenerator.scene(records: [])
        scene.width = 64
        scene.height = 64
        let clipA = SIMD4<Float>(4.0, 4.0, 28.0, 28.0)
        var rectA = RenderInstance(
            rect: SIMD4<Float>(0, 0, 32, 32),
            radii: .zero,
            fill: SIMD4<Float>(0.9, 0.3, 0.2, 1.0),
            border: .zero,
            params: SIMD4<Float>(0, KIND_RECT, 0, 1.0),
            uv: .zero,
            clip: clipA,
            fade: .zero
        )
        rectA.fade.w = packClipRadii(clip: clipA, radii: SIMD4<Float>(repeating: 10.0))

        let clipB = SIMD4<Float>(32.0, 4.0, 60.0, 32.0)
        var rectB = RenderInstance(
            rect: SIMD4<Float>(28, 0, 36, 36),
            radii: .zero,
            fill: SIMD4<Float>(0.2, 0.75, 0.4, 1.0),
            border: .zero,
            params: SIMD4<Float>(0, KIND_RECT, 0, 1.0),
            uv: .zero,
            clip: clipB,
            fade: .zero
        )
        rectB.fade.w = packClipRadii(clip: clipB, radii: SIMD4<Float>(-10.0, -6.0, 0.0, -8.0))

        let primA = oraclePrimitive(from: rectA, node: 1, source: "rounded-clip-uniform")
        let primB = oraclePrimitive(from: rectB, node: 2, source: "rounded-clip-mixed")
        #expect(renderInstance(from: primA).fade.w == rectA.fade.w, "uniform rounded clip must survive round-trip")
        #expect(renderInstance(from: primB).fade.w == rectB.fade.w, "mixed continuous rounded clip must survive round-trip")
        scene.primitives = [primA, primB]
        try scene.validate()
        var cpu = OracleFrame(width: scene.width, height: scene.height, provenance: true)
        cpu.render(scene)
        let rf = makeRenderFrame(from: scene, glyphGeneration: await sharedGen.allocate())
        let gpuFrame = try gpu.renderOffscreen(rf)
        let report = Oracle.compare(scene: scene, cpu: cpu, gpu: gpuFrame.rgba, tolerance: 2)
        #expect(report.outlierPixels == 0, "rounded-clip-primitive: \(report)")
    }

    @Test("differential.rs:722 cpu_gpu_turned_plus_lighter_saturates_before_interpolation")
    func cpuGpuTurnedPlusLighterSaturatesBeforeInterpolation() async throws {
        let gpu: MetalRenderer
        do { gpu = try MetalRenderer() } catch { return }

        func makeScene(_ children: [RenderInstance]) -> OracleScene {
            var scene = OracleGenerator.scene(records: [])
            scene.width = 48
            scene.height = 48
            scene.clear = [0.02, 0.04, 0.08, 1.0]
            let open = RenderInstance.beginLayer(
                bounds: SIMD4<Float>(12.0, 12.0, 24.0, 24.0),
                clip: NO_CLIP,
                spec: LayerSpec(opacity: 0.8, blend: .plusLighter)
            )
            .turned(angle: 0.4, pivot: SIMD2<Float>(24.0, 24.0))
            var all = [open]
            all.append(contentsOf: children)
            all.append(RenderInstance.endLayer())
            scene.primitives = all.enumerated().map { idx, inst in
                oraclePrimitive(from: inst, node: UInt32(idx + 1), source: "turned-add/\(idx)")
            }
            return scene
        }

        func boxInst(_ fill: SIMD4<Float>) -> RenderInstance {
            RenderInstance(
                rect: SIMD4<Float>(12.0, 12.0, 24.0, 24.0),
                radii: .zero,
                fill: fill,
                border: .zero,
                params: SIMD4<Float>(0.0, KIND_RECT, 0.0, 1.0),
                uv: .zero,
                clip: NO_CLIP,
                fade: .zero
            )
        }

        // Two overlapping [0.8, 0.2, 0.0, 0.8] rects sum to [1.6, 0.4, 0.0, 1.6], which saturates to
        // [1.0, 0.4, 0.0, 1.0]. Saturation must happen before the turned layer's bilinear sampling.
        let single = makeScene([boxInst(SIMD4<Float>(1.0, 0.4, 0.0, 1.0))])
        let doubled = makeScene([
            boxInst(SIMD4<Float>(0.8, 0.2, 0.0, 0.8)),
            boxInst(SIMD4<Float>(0.8, 0.2, 0.0, 0.8)),
        ])
        try single.validate()
        try doubled.validate()

        var cpuSingle = OracleFrame(width: 48, height: 48, provenance: true)
        cpuSingle.render(single)
        var cpuDoubled = OracleFrame(width: 48, height: 48, provenance: true)
        cpuDoubled.render(doubled)
        let cpuDiff = Oracle.compare(scene: doubled, cpu: cpuSingle, gpu: cpuDoubled.rgba, tolerance: 1)
        #expect(cpuDiff.outlierPixels == 0, "rune-ref turned PlusLighter clamped after interpolation: \(cpuDiff)")

        let gpuSingle = try gpu.renderOffscreen(makeRenderFrame(from: single, glyphGeneration: await sharedGen.allocate())).rgba
        let gpuDoubled = try gpu.renderOffscreen(makeRenderFrame(from: doubled, glyphGeneration: await sharedGen.allocate())).rgba
        var gpuMax: UInt8 = 0
        var gpuWorst: (Int, Int, [UInt8], [UInt8])?
        for y in 0..<48 {
            for x in 0..<48 {
                let i = (y * 48 + x) * 4
                let a = [gpuSingle[i], gpuSingle[i + 1], gpuSingle[i + 2], gpuSingle[i + 3]]
                let b = [gpuDoubled[i], gpuDoubled[i + 1], gpuDoubled[i + 2], gpuDoubled[i + 3]]
                let d = (0..<4).map { UInt8(abs(Int(a[$0]) - Int(b[$0]))) }.max() ?? 0
                if d > gpuMax {
                    gpuMax = d
                    gpuWorst = (x, y, a, b)
                }
            }
        }
        #expect(gpuMax <= 1, "GPU turned PlusLighter clamped after interpolation: max=\(gpuMax) worst=\(String(describing: gpuWorst))")

        let report = Oracle.compare(scene: doubled, cpu: cpuDoubled, gpu: gpuDoubled, tolerance: 2)
        #expect(report.outlierPixels == 0, "turned-plus-lighter: \(report)")
    }

    private static func parityScene(width: UInt32, height: UInt32, instances: [RenderInstance]) -> OracleScene {
        var scene = OracleGenerator.scene(records: [])
        scene.width = width
        scene.height = height
        scene.primitives = instances.enumerated().map { idx, inst in
            oraclePrimitive(from: inst, node: UInt32(idx + 1), source: "parity/\(idx)")
        }
        return scene
    }

    private static func checkParity(gpu: MetalRenderer, scene: OracleScene, tolerance: UInt8 = 2) async throws {
        try scene.validate()
        var cpu = OracleFrame(width: scene.width, height: scene.height, provenance: true)
        cpu.render(scene)
        let rf = makeRenderFrame(from: scene, glyphGeneration: await sharedGen.allocate())
        let actual = try gpu.renderOffscreen(rf)
        let diff = Oracle.compare(scene: scene, cpu: cpu, gpu: actual.rgba, tolerance: tolerance)
        #expect(diff.outlierPixels == 0, "CPU vs GPU mismatch: \(diff)")
    }

    private static func zeroRenderInstance() -> RenderInstance {
        RenderInstance(
            rect: .zero,
            radii: .zero,
            fill: .zero,
            border: .zero,
            params: .zero,
            uv: .zero,
            clip: NO_CLIP,
            fade: .zero
        )
    }

    @Test("parity.rs: cpu_gpu_banded_rects_and_shadows")
    func cpuGpuBandedRectsAndShadows() async throws {
        let gpu: MetalRenderer
        do { gpu = try MetalRenderer() } catch { return }

        var ring = Self.zeroRenderInstance()
        ring.rect = SIMD4<Float>(8.0, 8.0, 48.0, 48.0)
        ring.radii = SIMD4<Float>(repeating: -8.0)
        ring.border = SIMD4<Float>(0.85, 0.35, 0.2, 0.9)
        ring.params = SIMD4<Float>(3.0, KIND_RECT, 0.0, 0.9)

        var shadow = Self.zeroRenderInstance()
        shadow.rect = SIMD4<Float>(14.0, 14.0, 36.0, 36.0)
        shadow.radii = SIMD4<Float>(repeating: 6.0)
        shadow.fill = SIMD4<Float>(0.0, 0.0, 0.0, 0.6)
        shadow.params = SIMD4<Float>(0.0, KIND_SHADOW, 3.0, 1.0)

        func bands(_ inst: RenderInstance, q: SIMD4<Float>, hole: SIMD4<Float>) -> [RenderInstance] {
            let rects: [SIMD4<Float>] = [
                SIMD4<Float>(q.x, q.y, q.z, hole.y),
                SIMD4<Float>(q.x, hole.y, hole.x, hole.w),
                SIMD4<Float>(hole.z, hole.y, q.z, hole.w),
                SIMD4<Float>(q.x, hole.w, q.z, q.w),
            ]
            return rects.map { r in
                var b = inst
                b.uv = SIMD4<Float>(r.x, r.y, -r.z, r.w)
                return b
            }
        }
        let ringBands = bands(ring, q: SIMD4<Float>(-1.0, -1.0, 49.0, 49.0), hole: SIMD4<Float>(16.0, 16.0, 32.0, 32.0))
        let shadowBands = bands(shadow, q: SIMD4<Float>(-10.0, -10.0, 46.0, 46.0), hole: SIMD4<Float>(8.0, 8.0, 28.0, 28.0))

        try await Self.checkParity(gpu: gpu, scene: Self.parityScene(width: 64, height: 64, instances: ringBands))
        try await Self.checkParity(gpu: gpu, scene: Self.parityScene(width: 64, height: 64, instances: shadowBands))
        try await Self.checkParity(gpu: gpu, scene: Self.parityScene(width: 64, height: 64, instances: [shadowBands[0], ringBands[1]]))
    }

    @Test("parity.rs: cpu_gpu_segments_and_triangles")
    func cpuGpuSegmentsAndTriangles() async throws {
        let gpu: MetalRenderer
        do { gpu = try MetalRenderer() } catch { return }

        var seg1 = Self.zeroRenderInstance()
        seg1.rect = SIMD4<Float>(4.0, 4.0, 30.0, 24.0)
        seg1.radii = SIMD4<Float>(8.0, 8.0, 30.0, 24.0)
        seg1.fill = SIMD4<Float>(0.9, 0.35, 0.15, 0.95)
        seg1.params = SIMD4<Float>(2.25, KIND_SEGMENT, 1.0, 1.0)

        var seg2 = Self.zeroRenderInstance()
        seg2.rect = SIMD4<Float>(32.0, 4.0, 26.0, 20.0)
        seg2.radii = SIMD4<Float>(36.0, 10.0, 54.0, 18.0)
        seg2.fill = SIMD4<Float>(0.16, 0.68, 0.4, 0.8)
        seg2.params = SIMD4<Float>(0.3, KIND_SEGMENT, 0.0, 1.0)

        var dot = Self.zeroRenderInstance()
        dot.rect = SIMD4<Float>(42.0, 20.0, 12.0, 12.0)
        dot.radii = SIMD4<Float>(48.0, 26.0, 48.0, 26.0)
        dot.fill = SIMD4<Float>(0.9, 0.85, 0.2, 1.0)
        dot.params = SIMD4<Float>(3.0, KIND_SEGMENT, 1.0, 1.0)

        var triA = Self.zeroRenderInstance()
        triA.rect = SIMD4<Float>(8.0, 32.0, 24.0, 24.0)
        triA.radii = SIMD4<Float>(8.0, 32.0, 32.0, 32.0)
        triA.uv = SIMD4<Float>(32.0, 56.0, 0.0, 0.0)
        triA.fill = SIMD4<Float>(0.175, 0.315, 0.63, 0.7)
        triA.params = SIMD4<Float>(3.0, KIND_TRIANGLE, 0.0, 1.0)

        var triB = Self.zeroRenderInstance()
        triB.rect = SIMD4<Float>(8.0, 32.0, 24.0, 24.0)
        triB.radii = SIMD4<Float>(8.0, 32.0, 32.0, 56.0)
        triB.uv = SIMD4<Float>(8.0, 56.0, 0.0, 0.0)
        triB.fill = SIMD4<Float>(0.175, 0.315, 0.63, 0.7)
        triB.params = SIMD4<Float>(6.0, KIND_TRIANGLE, 0.0, 1.0)

        var triClipped = Self.zeroRenderInstance()
        triClipped.rect = SIMD4<Float>(34.0, 32.0, 24.0, 24.0)
        triClipped.radii = SIMD4<Float>(46.0, 33.0, 57.0, 55.0)
        triClipped.uv = SIMD4<Float>(35.0, 52.0, 0.0, 0.0)
        triClipped.fill = SIMD4<Float>(0.72, 0.17, 0.55, 0.85)
        triClipped.params = SIMD4<Float>(7.0, KIND_TRIANGLE, 0.0, 1.0)
        triClipped.clip = SIMD4<Float>(38.0, 36.0, 54.0, 53.0)

        try await Self.checkParity(gpu: gpu, scene: Self.parityScene(width: 64, height: 64, instances: [seg1, seg2, dot, triA, triB, triClipped]))
    }

    @Test("parity.rs: cpu_gpu_negative_spread_inset_shadows")
    func cpuGpuNegativeSpreadInsetShadows() async throws {
        let gpu: MetalRenderer
        do { gpu = try MetalRenderer() } catch { return }

        var s1 = Self.zeroRenderInstance()
        s1.rect = SIMD4<Float>(4.0, 4.0, 26.0, 26.0)
        s1.fill = SIMD4<Float>(0.68, 0.2, 0.12, 0.8)
        s1.params = SIMD4<Float>(-4.0, KIND_INSET, 0.0, 1.0)
        s1.uv = SIMD4<Float>(0.0, 6.0, 0.0, 0.0)

        var s2 = Self.zeroRenderInstance()
        s2.rect = SIMD4<Float>(34.0, 4.0, 26.0, 26.0)
        s2.radii = SIMD4<Float>(repeating: 6.0)
        s2.fill = SIMD4<Float>(0.12, 0.56, 0.34, 0.75)
        s2.params = SIMD4<Float>(-2.0, KIND_INSET, 3.0, 1.0)
        s2.uv = SIMD4<Float>(3.0, 4.0, 0.0, 0.0)

        var s3 = Self.zeroRenderInstance()
        s3.rect = SIMD4<Float>(10.0, 34.0, 44.0, 24.0)
        s3.radii = SIMD4<Float>(repeating: -6.0)
        s3.fill = SIMD4<Float>(0.14, 0.28, 0.63, 0.7)
        s3.params = SIMD4<Float>(-3.0, KIND_INSET, 0.0, 1.0)
        s3.uv = SIMD4<Float>(-4.0, 5.0, 0.0, 0.0)

        try await Self.checkParity(gpu: gpu, scene: Self.parityScene(width: 64, height: 64, instances: [s1, s2, s3]))
    }

    @Test("parity.rs: cpu_gpu_mixed_clip_radii_quantization")
    func cpuGpuMixedClipRadiiQuantization() async throws {
        let gpu: MetalRenderer
        do { gpu = try MetalRenderer() } catch { return }

        var fine = OracleGenerator.scene(records: [])
        fine.width = 64
        fine.height = 64
        fine.primitives = [OraclePrimitive(
            node: 1,
            source: "clip-fine",
            rect: [0.0, 0.0, 64.0, 64.0],
            radii: [0.0, 0.0, 0.0, 0.0],
            fill: [0.9, 0.4, 0.2, 1.0],
            border: [0.0, 0.0, 0.0, 0.0],
            params: [0.0, KIND_RECT, 0.0, 1.0],
            uv: [0.0, 0.0, 0.0, 0.0],
            clip: [4.0, 4.0, 60.0, 60.0],
            fade: [0.0, 0.0, 0.0, 0.0],
            fadeOrigin: nil,
            turn: nil,
            clipRadii: [10.3, 4.7, 0.0, 8.2]
        )]
        try await Self.checkParity(gpu: gpu, scene: fine)

        var coarse = OracleGenerator.scene(records: [])
        coarse.width = 200
        coarse.height = 200
        coarse.primitives = [OraclePrimitive(
            node: 1,
            source: "clip-coarse",
            rect: [0.0, 0.0, 200.0, 200.0],
            radii: [0.0, 0.0, 0.0, 0.0],
            fill: [0.2, 0.7, 0.9, 1.0],
            border: [0.0, 0.0, 0.0, 0.0],
            params: [0.0, KIND_RECT, 0.0, 1.0],
            uv: [0.0, 0.0, 0.0, 0.0],
            clip: [10.0, 10.0, 190.0, 190.0],
            fade: [0.0, 0.0, 0.0, 0.0],
            fadeOrigin: nil,
            turn: nil,
            clipRadii: [-71.3, -13.1, 0.0, -40.7]
        )]
        try await Self.checkParity(gpu: gpu, scene: coarse)
    }

    @Test("parity.rs: cpu_gpu_layer_expansion_offscreen_turns_and_scissor_inline")
    func cpuGpuLayerExpansionOffscreenTurnsAndScissorInline() async throws {
        let gpu: MetalRenderer
        do { gpu = try MetalRenderer() } catch { return }

        // 1. Uncached opacity layer with small initial rect containing a child + outer drop shadow.
        var sh = Self.zeroRenderInstance()
        sh.rect = SIMD4<Float>(16.0, 16.0, 28.0, 24.0)
        sh.radii = SIMD4<Float>(repeating: 6.0)
        sh.fill = SIMD4<Float>(0.0, 0.0, 0.0, 0.7)
        sh.params = SIMD4<Float>(0.0, KIND_SHADOW, 5.0, 1.0)

        var box = Self.zeroRenderInstance()
        box.rect = SIMD4<Float>(16.0, 16.0, 28.0, 24.0)
        box.radii = SIMD4<Float>(repeating: 6.0)
        box.fill = SIMD4<Float>(0.8, 0.3, 0.2, 1.0)
        box.params = SIMD4<Float>(0.0, KIND_RECT, 0.0, 1.0)

        let expanded: [RenderInstance] = [
            RenderInstance.beginLayer(
                bounds: SIMD4<Float>(24.0, 24.0, 8.0, 8.0),
                clip: NO_CLIP,
                spec: LayerSpec(opacity: 0.65)
            ),
            sh,
            box,
            RenderInstance.endLayer(),
        ]
        try await Self.checkParity(gpu: gpu, scene: Self.parityScene(width: 64, height: 64, instances: expanded))

        // 2. Uncached layer with empty initial rect [24, 24, 0, 0].
        var eA = Self.zeroRenderInstance()
        eA.rect = SIMD4<Float>(10.0, 10.0, 26.0, 26.0)
        eA.radii = SIMD4<Float>(repeating: 4.0)
        eA.fill = SIMD4<Float>(0.7, 0.2, 0.1, 0.7)
        eA.params = SIMD4<Float>(0.0, KIND_RECT, 0.0, 1.0)

        var eB = Self.zeroRenderInstance()
        eB.rect = SIMD4<Float>(20.0, 20.0, 26.0, 26.0)
        eB.radii = SIMD4<Float>(repeating: 4.0)
        eB.fill = SIMD4<Float>(0.14, 0.42, 0.56, 0.7)
        eB.params = SIMD4<Float>(0.0, KIND_RECT, 0.0, 1.0)

        let emptySeed: [RenderInstance] = [
            RenderInstance.beginLayer(
                bounds: SIMD4<Float>(24.0, 24.0, 0.0, 0.0),
                clip: NO_CLIP,
                spec: LayerSpec(opacity: 0.5, blend: .plusLighter)
            ),
            eA,
            eB,
            RenderInstance.endLayer(),
        ]
        try await Self.checkParity(gpu: gpu, scene: Self.parityScene(width: 64, height: 64, instances: emptySeed))

        // 3. Turned layer whose upright content starts at x < 0 and rotates into the viewport.
        var offBox = Self.zeroRenderInstance()
        offBox.rect = SIMD4<Float>(-12.0, 22.0, 24.0, 16.0)
        offBox.radii = SIMD4<Float>(repeating: 4.0)
        offBox.fill = SIMD4<Float>(0.2, 0.85, 0.45, 1.0)
        offBox.params = SIMD4<Float>(0.0, KIND_RECT, 0.0, 1.0)

        let offscreenTurn: [RenderInstance] = [
            RenderInstance.beginLayer(
                bounds: SIMD4<Float>(-12.0, 22.0, 24.0, 16.0),
                clip: NO_CLIP,
                spec: LayerSpec()
            ).turned(angle: Float.pi * 0.5, pivot: SIMD2<Float>(16.0, 30.0)),
            offBox,
            RenderInstance.endLayer(),
        ]
        try await Self.checkParity(gpu: gpu, scene: Self.parityScene(width: 64, height: 64, instances: offscreenTurn))

        // 4. Integer-clipped opaque layer (`Disposition::Inline` with hardware scissor) with overlapping children.
        var scissoredInner = RenderInstance.beginLayer(
            bounds: SIMD4<Float>(10.0, 10.0, 32.0, 32.0),
            clip: SIMD4<Float>(12.0, 12.0, 40.0, 40.0),
            spec: LayerSpec(opacity: 0.7)
        )
        scissoredInner.fade.w = packClipRadii(clip: scissoredInner.clip, radii: SIMD4<Float>(repeating: 8.0))

        var bg1 = Self.zeroRenderInstance()
        bg1.rect = SIMD4<Float>(0.0, 0.0, 64.0, 64.0)
        bg1.fill = SIMD4<Float>(0.2, 0.1, 0.3, 0.5)
        bg1.params = SIMD4<Float>(0.0, KIND_RECT, 0.0, 1.0)

        var bg2 = Self.zeroRenderInstance()
        bg2.rect = SIMD4<Float>(4.0, 4.0, 56.0, 56.0)
        bg2.fill = SIMD4<Float>(0.72, 0.48, 0.08, 0.8)
        bg2.params = SIMD4<Float>(0.0, KIND_RECT, 0.0, 1.0)

        let scissored: [RenderInstance] = [
            RenderInstance.beginLayer(
                bounds: SIMD4<Float>(8.0, 8.0, 48.0, 48.0),
                clip: SIMD4<Float>(8.0, 8.0, 48.0, 48.0),
                spec: LayerSpec()
            ),
            bg1,
            scissoredInner,
            bg2,
            RenderInstance.endLayer(),
            RenderInstance.endLayer(),
        ]
        try await Self.checkParity(gpu: gpu, scene: Self.parityScene(width: 64, height: 64, instances: scissored))
    }

    @Test("parity.rs: cpu_gpu_effect_slot_with_mark_and_legacy_glyph_radii")
    func cpuGpuEffectSlotWithMarkAndLegacyGlyphRadii() async throws {
        let gpu: MetalRenderer
        do { gpu = try MetalRenderer() } catch { return }

        let mark: UInt32 = 0x1234_5678
        var slot = Self.zeroRenderInstance()
        slot.rect = SIMD4<Float>(8.0, 8.0, 24.0, 24.0)
        slot.fill = SIMD4<Float>(0.0, 0.0, 0.0, 1.0)
        slot.border = SIMD4<Float>(Float(mark & 0xFFFF), Float(mark >> 16), 0.0, 0.0)
        slot.params = SIMD4<Float>(1.0, KIND_EFFECT, 4.0, 1.0)
        slot.uv = SIMD4<Float>(-3.0, 7.5, 1.0, 0.25)

        var bg = Self.zeroRenderInstance()
        bg.rect = SIMD4<Float>(4.0, 4.0, 40.0, 40.0)
        bg.fill = SIMD4<Float>(0.3, 0.5, 0.8, 1.0)
        bg.params = SIMD4<Float>(0.0, KIND_RECT, 0.0, 1.0)

        try await Self.checkParity(gpu: gpu, scene: Self.parityScene(width: 64, height: 64, instances: [bg, slot]))

        var glyphScene = OracleGenerator.scene(records: [])
        glyphScene.primitives = [OraclePrimitive(
            node: 1,
            source: "legacy-glyph",
            rect: [12.0, 12.0, 16.0, 16.0],
            radii: [12.0, 8.0, 4.0, 2.0],
            fill: [0.8, 0.7, 0.5, 0.9],
            border: [0.0, 0.0, 0.0, 0.0],
            params: [0.0, 2.0, 3.5, 1.2],
            uv: [1.0, 1.0, 0.0, 0.0],
            clip: oracleNoClip,
            fade: [0.0, 0.0, 0.0, 0.0],
            fadeOrigin: nil,
            turn: nil,
            clipRadii: nil
        )]
        let inst = renderInstance(from: glyphScene.primitives[0])
        #expect(inst.radii == .zero)
        #expect(inst.params.z == 0.0)
        try await Self.checkParity(gpu: gpu, scene: glyphScene)
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
