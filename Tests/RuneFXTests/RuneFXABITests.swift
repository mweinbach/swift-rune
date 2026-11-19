import Foundation
import RuneMotion
import Testing
@testable import RuneFX
#if canImport(Metal)
@preconcurrency import Metal
#endif

@Suite("RuneFX ABI & OKLab Parity Tests")
struct RuneFXABITests {
    @Test("oklab matches canonical RuneMotion.linearToOKLab for non-negative RGB and clamps negative LMS")
    func oklabMatchesCanonicalForNonNegativeRgbAndClampsNegativeLms() {
        #expect(Float(0.412_221_46).bitPattern == Float(0.412_221_47).bitPattern)
        for v in 0...255 {
            let c = MotionColor.srgbDecode(Float(v) / 255.0)
            for rgb in [
                SIMD3<Float>(c, c, c),
                SIMD3<Float>(c, 0.0, 0.0),
                SIMD3<Float>(0.0, c, 0.0),
                SIMD3<Float>(0.0, 0.0, c),
                SIMD3<Float>(c, 1.0 - c, 0.5 * c),
            ] {
                let got = oklab(Rgb(rgb.x, rgb.y, rgb.z))
                let canon = MotionColor.linearToOKLab(r: rgb.x, g: rgb.y, b: rgb.z)
                #expect(
                    [got.x.bitPattern, got.y.bitPattern, got.z.bitPattern]
                        == [canon.L.bitPattern, canon.a.bitPattern, canon.b.bitPattern],
                    "\(rgb)"
                )
            }
        }
        for rgb in [
            SIMD3<Float>(0.0, 0.0, 0.0),
            SIMD3<Float>(2.5, 1.2, 0.4),
            SIMD3<Float>(0.001, 0.999, 0.123),
        ] {
            let got = oklab(Rgb(rgb.x, rgb.y, rgb.z))
            let canon = MotionColor.linearToOKLab(r: rgb.x, g: rgb.y, b: rgb.z)
            #expect(
                [got.x.bitPattern, got.y.bitPattern, got.z.bitPattern]
                    == [canon.L.bitPattern, canon.a.bitPattern, canon.b.bitPattern],
                "\(rgb)"
            )
        }
        // Negative inputs can make LMS negative before cbrtf, where oklab clamps LMS to 0.
        let neg = SIMD3<Float>(-0.5, 0.2, 0.1)
        let gotNeg = oklab(Rgb(neg.x, neg.y, neg.z))
        let clampedRgbCanon = MotionColor.linearToOKLab(r: neg.x, g: neg.y, b: neg.z)
        #expect(gotNeg != SIMD3<Float>(clampedRgbCanon.L, clampedRgbCanon.a, clampedRgbCanon.b))
        let l = 0.412_221_46 * neg.x + 0.536_332_55 * neg.y + 0.051_445_995 * neg.z
        let m = 0.211_903_5 * neg.x + 0.680_699_5 * neg.y + 0.107_396_96 * neg.z
        let s = 0.088_302_46 * neg.x + 0.281_718_85 * neg.y + 0.629_978_7 * neg.z
        let lc = cbrtf(l)
        let mc = cbrtf(m)
        let sc = cbrtf(s)
        let unclampedLms = SIMD3<Float>(
            0.210_454_26 * lc + 0.793_617_8 * mc - 0.004_072_047 * sc,
            1.977_998_5 * lc - 2.428_592_2 * mc + 0.450_593_7 * sc,
            0.025_904_037 * lc + 0.782_771_77 * mc - 0.808_675_77 * sc
        )
        #expect(gotNeg != unclampedLms)
    }

    @Test("Swift FX GPU struct sizes and every field offset match ABI specification")
    func swiftStructOffsetsMatchABISpec() {
        #expect(MemoryLayout<FxInstRaw>.size == 256)
        #expect(MemoryLayout<FxInstRaw>.stride == 256)
        #expect(MemoryLayout<FxInstRaw>.offset(of: \.rect) == 0)
        #expect(MemoryLayout<FxInstRaw>.offset(of: \.shape) == 16)
        #expect(MemoryLayout<FxInstRaw>.offset(of: \.bounds) == 32)
        #expect(MemoryLayout<FxInstRaw>.offset(of: \.c0) == 48)
        #expect(MemoryLayout<FxInstRaw>.offset(of: \.c1) == 64)
        #expect(MemoryLayout<FxInstRaw>.offset(of: \.c2) == 80)
        #expect(MemoryLayout<FxInstRaw>.offset(of: \.p0) == 96)
        #expect(MemoryLayout<FxInstRaw>.offset(of: \.p1) == 112)
        #expect(MemoryLayout<FxInstRaw>.offset(of: \.p2) == 128)
        #expect(MemoryLayout<FxInstRaw>.offset(of: \.p3) == 144)
        #expect(MemoryLayout<FxInstRaw>.offset(of: \.t) == 160)
        #expect(MemoryLayout<FxInstRaw>.offset(of: \.aux) == 176)
        #expect(MemoryLayout<FxInstRaw>.offset(of: \.aux2) == 192)
        #expect(MemoryLayout<FxInstRaw>.offset(of: \.xf) == 208)
        #expect(MemoryLayout<FxInstRaw>.offset(of: \.clip) == 224)
        #expect(MemoryLayout<FxInstRaw>.offset(of: \.fade) == 240)

        #expect(MemoryLayout<FxGlobals>.size == 16)
        #expect(MemoryLayout<FxGlobals>.stride == 16)
        #expect(MemoryLayout<FxGlobals>.offset(of: \.viewport) == 0)
        #expect(MemoryLayout<FxGlobals>.offset(of: \.dither) == 8)
        #expect(MemoryLayout<FxGlobals>.offset(of: \.srgb) == 12)

        #expect(MemoryLayout<FxBackdropEncoding>.size == 16)
        #expect(MemoryLayout<FxBackdropEncoding>.stride == 16)
        #expect(MemoryLayout<FxBackdropEncoding>.offset(of: \.encoded) == 0)
        #expect(MemoryLayout<FxBackdropEncoding>.offset(of: \.present) == 4)
        #expect(MemoryLayout<FxBackdropEncoding>.offset(of: \.pad0) == 8)
        #expect(MemoryLayout<FxBackdropEncoding>.offset(of: \.pad1) == 12)

        #expect(MemoryLayout<FireSimUniform>.size == 96)
        #expect(MemoryLayout<FireSimUniform>.stride == 96)
        #expect(MemoryLayout<FireSimUniform>.offset(of: \.dims) == 0)
        #expect(MemoryLayout<FireSimUniform>.offset(of: \.origin) == 16)
        #expect(MemoryLayout<FireSimUniform>.offset(of: \.shape) == 32)
        #expect(MemoryLayout<FireSimUniform>.offset(of: \.shape2) == 48)
        #expect(MemoryLayout<FireSimUniform>.offset(of: \.fire) == 64)
        #expect(MemoryLayout<FireSimUniform>.offset(of: \.fire2) == 80)

        #expect(MemoryLayout<FireSimKernelParams>.size == 16)
        #expect(MemoryLayout<FireSimKernelParams>.stride == 16)
        #expect(MemoryLayout<FireSimKernelParams>.offset(of: \.dt) == 0)
        #expect(MemoryLayout<FireSimKernelParams>.offset(of: \.buoyancy) == 4)
        #expect(MemoryLayout<FireSimKernelParams>.offset(of: \.cooling) == 8)
        #expect(MemoryLayout<FireSimKernelParams>.offset(of: \.smoke) == 12)
    }

    #if canImport(Metal)
    private func verifyBufferStruct(
        label: String,
        bindings: [any MTLBinding],
        bufferIndex: Int,
        expectedSize: Int,
        expectedFields: [(String, Int)]
    ) throws {
        let binding = try #require(
            bindings.first(where: { $0.type == .buffer && $0.index == bufferIndex }) as? MTLBufferBinding,
            "\(label): buffer(\(bufferIndex)) not found in reflection"
        )
        let structType: MTLStructType
        let dataSize: Int
        if let direct = binding.bufferStructType {
            structType = direct
            dataSize = binding.bufferDataSize
        } else if let ptr = binding.bufferPointerType, let elem = ptr.elementStructType() {
            structType = elem
            dataSize = ptr.dataSize
        } else {
            Issue.record("\(label): buffer(\(bufferIndex)) has no struct reflection")
            return
        }
        #expect(dataSize == expectedSize, "\(label): buffer(\(bufferIndex)) size \(dataSize) != \(expectedSize)")
        #expect(structType.members.count == expectedFields.count, "\(label): member count \(structType.members.count) != \(expectedFields.count)")
        for (member, (field, offset)) in zip(structType.members, expectedFields) {
            #expect(member.name == field, "\(label): member name \(member.name) != \(field)")
            #expect(member.offset == offset, "\(label).\(field): offset \(member.offset) != \(offset)")
        }
    }

    @Test("Metal compiled uniform and storage struct layouts match Swift ABI")
    func metalUniformAndStorageLayoutsMatchSwift() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }

        // 1. common + glow render pipeline (Globals, Inst, BackdropEncoding)
        let glowLib = try device.makeLibrary(source: RuneFXShaders.glowShader, options: nil)
        let glowVs: MTLFunction = try #require(glowLib.makeFunction(name: "fx_vertex"))
        let glowFs: MTLFunction = try #require(glowLib.makeFunction(name: "fx_glow_fragment"))
        let glowDesc = MTLRenderPipelineDescriptor()
        glowDesc.vertexFunction = glowVs
        glowDesc.fragmentFunction = glowFs
        glowDesc.colorAttachments[0].pixelFormat = .rgba16Float
        var renderRefl: MTLAutoreleasedRenderPipelineReflection?
        _ = try device.makeRenderPipelineState(
            descriptor: glowDesc,
            options: [.bindingInfo, .bufferTypeInfo],
            reflection: &renderRefl
        )
        let glowRefl = try #require(renderRefl)

        let globalsFields: [(String, Int)] = [
            ("viewport", try #require(MemoryLayout<FxGlobals>.offset(of: \.viewport))),
            ("dither", try #require(MemoryLayout<FxGlobals>.offset(of: \.dither))),
            ("srgb", try #require(MemoryLayout<FxGlobals>.offset(of: \.srgb))),
        ]
        let instFields: [(String, Int)] = [
            ("rect", try #require(MemoryLayout<FxInstRaw>.offset(of: \.rect))),
            ("shape", try #require(MemoryLayout<FxInstRaw>.offset(of: \.shape))),
            ("bounds", try #require(MemoryLayout<FxInstRaw>.offset(of: \.bounds))),
            ("c0", try #require(MemoryLayout<FxInstRaw>.offset(of: \.c0))),
            ("c1", try #require(MemoryLayout<FxInstRaw>.offset(of: \.c1))),
            ("c2", try #require(MemoryLayout<FxInstRaw>.offset(of: \.c2))),
            ("p0", try #require(MemoryLayout<FxInstRaw>.offset(of: \.p0))),
            ("p1", try #require(MemoryLayout<FxInstRaw>.offset(of: \.p1))),
            ("p2", try #require(MemoryLayout<FxInstRaw>.offset(of: \.p2))),
            ("p3", try #require(MemoryLayout<FxInstRaw>.offset(of: \.p3))),
            ("t", try #require(MemoryLayout<FxInstRaw>.offset(of: \.t))),
            ("aux", try #require(MemoryLayout<FxInstRaw>.offset(of: \.aux))),
            ("aux2", try #require(MemoryLayout<FxInstRaw>.offset(of: \.aux2))),
            ("xf", try #require(MemoryLayout<FxInstRaw>.offset(of: \.xf))),
            ("clip", try #require(MemoryLayout<FxInstRaw>.offset(of: \.clip))),
            ("fade", try #require(MemoryLayout<FxInstRaw>.offset(of: \.fade))),
        ]
        let encodingFields: [(String, Int)] = [
            ("encoded", try #require(MemoryLayout<FxBackdropEncoding>.offset(of: \.encoded))),
            ("present", try #require(MemoryLayout<FxBackdropEncoding>.offset(of: \.present))),
            ("pad0", try #require(MemoryLayout<FxBackdropEncoding>.offset(of: \.pad0))),
            ("pad1", try #require(MemoryLayout<FxBackdropEncoding>.offset(of: \.pad1))),
        ]

        try verifyBufferStruct(
            label: "fx_glow.vertex.Globals",
            bindings: glowRefl.vertexBindings,
            bufferIndex: 0,
            expectedSize: MemoryLayout<FxGlobals>.stride,
            expectedFields: globalsFields
        )
        try verifyBufferStruct(
            label: "fx_glow.vertex.Inst",
            bindings: glowRefl.vertexBindings,
            bufferIndex: 1,
            expectedSize: MemoryLayout<FxInstRaw>.stride,
            expectedFields: instFields
        )
        try verifyBufferStruct(
            label: "fx_glow.fragment.Globals",
            bindings: glowRefl.fragmentBindings,
            bufferIndex: 0,
            expectedSize: MemoryLayout<FxGlobals>.stride,
            expectedFields: globalsFields
        )
        try verifyBufferStruct(
            label: "fx_glow.fragment.Inst",
            bindings: glowRefl.fragmentBindings,
            bufferIndex: 1,
            expectedSize: MemoryLayout<FxInstRaw>.stride,
            expectedFields: instFields
        )
        try verifyBufferStruct(
            label: "fx_glow.fragment.BackdropEncoding",
            bindings: glowRefl.fragmentBindings,
            bufferIndex: 4,
            expectedSize: MemoryLayout<FxBackdropEncoding>.stride,
            expectedFields: encodingFields
        )

        // 2. firesim compute kernels (FireSimUniform, FireSimParams)
        let simLib = try device.makeLibrary(source: RuneFXShaders.fireSimShader, options: nil)
        let forcesFn = try #require(simLib.makeFunction(name: "forces"))
        var simRefl: MTLAutoreleasedComputePipelineReflection?
        _ = try device.makeComputePipelineState(
            function: forcesFn,
            options: [.bindingInfo, .bufferTypeInfo],
            reflection: &simRefl
        )
        let forcesRefl = try #require(simRefl)
        let simUniformFields: [(String, Int)] = [
            ("dims", try #require(MemoryLayout<FireSimUniform>.offset(of: \.dims))),
            ("origin", try #require(MemoryLayout<FireSimUniform>.offset(of: \.origin))),
            ("shape", try #require(MemoryLayout<FireSimUniform>.offset(of: \.shape))),
            ("shape2", try #require(MemoryLayout<FireSimUniform>.offset(of: \.shape2))),
            ("fire", try #require(MemoryLayout<FireSimUniform>.offset(of: \.fire))),
            ("fire2", try #require(MemoryLayout<FireSimUniform>.offset(of: \.fire2))),
        ]
        try verifyBufferStruct(
            label: "fx_firesim.forces.FireSimUniform",
            bindings: forcesRefl.bindings,
            bufferIndex: 0,
            expectedSize: MemoryLayout<FireSimUniform>.stride,
            expectedFields: simUniformFields
        )

        let stepFn = try #require(simLib.makeFunction(name: "fx_firesim_step_kernel"))
        var stepRefl: MTLAutoreleasedComputePipelineReflection?
        _ = try device.makeComputePipelineState(
            function: stepFn,
            options: [.bindingInfo, .bufferTypeInfo],
            reflection: &stepRefl
        )
        let stepParamsFields: [(String, Int)] = [
            ("dt", try #require(MemoryLayout<FireSimKernelParams>.offset(of: \.dt))),
            ("buoyancy", try #require(MemoryLayout<FireSimKernelParams>.offset(of: \.buoyancy))),
            ("cooling", try #require(MemoryLayout<FireSimKernelParams>.offset(of: \.cooling))),
            ("smoke", try #require(MemoryLayout<FireSimKernelParams>.offset(of: \.smoke))),
        ]
        try verifyBufferStruct(
            label: "fx_firesim.step.FireSimParams",
            bindings: try #require(stepRefl).bindings,
            bufferIndex: 0,
            expectedSize: MemoryLayout<FireSimKernelParams>.stride,
            expectedFields: stepParamsFields
        )
    }
    #endif
}
