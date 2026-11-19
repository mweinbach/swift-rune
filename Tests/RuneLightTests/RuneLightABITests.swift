import Foundation
import Testing
@testable import RuneLight
#if canImport(Metal)
@preconcurrency import Metal
#endif

@Suite("RuneLight ABI Parity Tests")
struct RuneLightABITests {
    @Test("Swift RuneLight GPU struct sizes and every field offset match ABI specification")
    func swiftStructOffsetsMatchABISpec() {
        #expect(MemoryLayout<Prim>.size == 96)
        #expect(MemoryLayout<Prim>.stride == 96)
        #expect(MemoryLayout<Prim>.offset(of: \.rect) == 0)
        #expect(MemoryLayout<Prim>.offset(of: \.radii) == 16)
        #expect(MemoryLayout<Prim>.offset(of: \.z) == 32)
        #expect(MemoryLayout<Prim>.offset(of: \.mat) == 48)
        #expect(MemoryLayout<Prim>.offset(of: \.emit) == 64)
        #expect(MemoryLayout<Prim>.offset(of: \.albedo) == 80)

        #expect(MemoryLayout<Light>.size == 64)
        #expect(MemoryLayout<Light>.stride == 64)
        #expect(MemoryLayout<Light>.offset(of: \.pos) == 0)
        #expect(MemoryLayout<Light>.offset(of: \.color) == 16)
        #expect(MemoryLayout<Light>.offset(of: \.axis) == 32)
        #expect(MemoryLayout<Light>.offset(of: \.extra) == 48)

        #expect(MemoryLayout<LightFrameUniforms>.size == 144)
        #expect(MemoryLayout<LightFrameUniforms>.stride == 144)
        #expect(MemoryLayout<LightFrameUniforms>.offset(of: \.sf) == 0)
        #expect(MemoryLayout<LightFrameUniforms>.offset(of: \.gs) == 16)
        #expect(MemoryLayout<LightFrameUniforms>.offset(of: \.ambient) == 32)
        #expect(MemoryLayout<LightFrameUniforms>.offset(of: \.counts) == 48)
        #expect(MemoryLayout<LightFrameUniforms>.offset(of: \.misc) == 64)
        #expect(MemoryLayout<LightFrameUniforms>.offset(of: \.text) == 80)
        #expect(MemoryLayout<LightFrameUniforms>.offset(of: \.gi) == 96)
        #expect(MemoryLayout<LightFrameUniforms>.offset(of: \.bg) == 112)
        #expect(MemoryLayout<LightFrameUniforms>.offset(of: \.ext) == 128)

        #expect(MemoryLayout<CascadeUniforms>.size == 16)
        #expect(MemoryLayout<CascadeUniforms>.stride == 16)
        #expect(MemoryLayout<CascadeUniforms>.offset(of: \.level) == 0)
        #expect(MemoryLayout<CascadeUniforms>.offset(of: \.count) == 4)
        #expect(MemoryLayout<CascadeUniforms>.offset(of: \.merge) == 8)
        #expect(MemoryLayout<CascadeUniforms>.offset(of: \.pad) == 12)

        #expect(MemoryLayout<Glass>.size == 96)
        #expect(MemoryLayout<Glass>.stride == 96)
        #expect(MemoryLayout<Glass>.offset(of: \.a) == 0)
        #expect(MemoryLayout<Glass>.offset(of: \.b) == 16)
        #expect(MemoryLayout<Glass>.offset(of: \.r) == 32)
        #expect(MemoryLayout<Glass>.offset(of: \.p0) == 48)
        #expect(MemoryLayout<Glass>.offset(of: \.p1) == 64)
        #expect(MemoryLayout<Glass>.offset(of: \.tint) == 80)

        #expect(MemoryLayout<GlassLight>.size == 32)
        #expect(MemoryLayout<GlassLight>.stride == 32)
        #expect(MemoryLayout<GlassLight>.offset(of: \.pos) == 0)
        #expect(MemoryLayout<GlassLight>.offset(of: \.color) == 16)

        #expect(MemoryLayout<GlassUniforms>.size == 48)
        #expect(MemoryLayout<GlassUniforms>.stride == 48)
        #expect(MemoryLayout<GlassUniforms>.offset(of: \.size) == 0)
        #expect(MemoryLayout<GlassUniforms>.offset(of: \.misc) == 16)
        #expect(MemoryLayout<GlassUniforms>.offset(of: \.shadow) == 32)
    }

    @Test("MSL and GLSL flag constants match Swift flag constants")
    func shaderFlagConstantsMatchSwift() throws {
        func checkUintConst(_ label: String, in source: String, name: String, expected: UInt32) throws {
            let pattern = #"\b(?:constant|const)\s+uint\s+"# + name + #"\s*=\s*(\d+)u\s*;"#
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            let match = try #require(regex.firstMatch(in: source, range: range), "\(label): const \(name) not found")
            let valueRange = try #require(Range(match.range(at: 1), in: source))
            let val = try #require(UInt32(source[valueRange]))
            #expect(val == expected, "\(label): const \(name) = \(val) != \(expected)")
        }

        let flags: [(String, UInt32)] = [
            ("F_OCC", flagOccluder),
            ("F_EMIT", flagEmissive),
            ("F_RAISED", flagRaised),
            ("F_HINT", flagGIHint),
        ]
        for (name, expected) in flags {
            try checkUintConst("commonPrelude", in: RuneLightShaders.commonPrelude, name: name, expected: expected)
        }
        #if canImport(CRuneGL)
        let glCommon = try LightGLRenderer.shader("common.glsl")
        for (name, expected) in flags {
            try checkUintConst("common.glsl", in: glCommon, name: name, expected: expected)
        }
        #endif
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

    @Test("Metal compiled uniform, storage, and glass struct layouts match Swift ABI")
    func metalUniformStorageAndGlassLayoutsMatchSwift() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }

        // 1. gbuffer render pipeline (Frame, Prim)
        let gbufLib = try device.makeLibrary(source: RuneLightShaders.gbufferShader, options: nil)
        let gbufVs: MTLFunction = try #require(gbufLib.makeFunction(name: "gbuffer_vertex"))
        let gbufFs: MTLFunction = try #require(gbufLib.makeFunction(name: "gbuffer_fragment"))
        let gbufDesc = MTLRenderPipelineDescriptor()
        gbufDesc.vertexFunction = gbufVs
        gbufDesc.fragmentFunction = gbufFs
        gbufDesc.colorAttachments[0].pixelFormat = .rgba16Float
        gbufDesc.colorAttachments[1].pixelFormat = .r32Uint
        var gbufReflOpt: MTLAutoreleasedRenderPipelineReflection?
        _ = try device.makeRenderPipelineState(
            descriptor: gbufDesc,
            options: [.bindingInfo, .bufferTypeInfo],
            reflection: &gbufReflOpt
        )
        let gbufRefl = try #require(gbufReflOpt)

        let frameFields: [(String, Int)] = [
            ("sf", try #require(MemoryLayout<LightFrameUniforms>.offset(of: \.sf))),
            ("gs", try #require(MemoryLayout<LightFrameUniforms>.offset(of: \.gs))),
            ("ambient", try #require(MemoryLayout<LightFrameUniforms>.offset(of: \.ambient))),
            ("counts", try #require(MemoryLayout<LightFrameUniforms>.offset(of: \.counts))),
            ("misc", try #require(MemoryLayout<LightFrameUniforms>.offset(of: \.misc))),
            ("text", try #require(MemoryLayout<LightFrameUniforms>.offset(of: \.text))),
            ("gi", try #require(MemoryLayout<LightFrameUniforms>.offset(of: \.gi))),
            ("bg", try #require(MemoryLayout<LightFrameUniforms>.offset(of: \.bg))),
            ("ext", try #require(MemoryLayout<LightFrameUniforms>.offset(of: \.ext))),
        ]
        let primFields: [(String, Int)] = [
            ("rect", try #require(MemoryLayout<Prim>.offset(of: \.rect))),
            ("radii", try #require(MemoryLayout<Prim>.offset(of: \.radii))),
            ("z", try #require(MemoryLayout<Prim>.offset(of: \.z))),
            ("mat", try #require(MemoryLayout<Prim>.offset(of: \.mat))),
            ("emit", try #require(MemoryLayout<Prim>.offset(of: \.emit))),
            ("albedo", try #require(MemoryLayout<Prim>.offset(of: \.albedo))),
        ]
        try verifyBufferStruct(
            label: "light_gbuffer.vertex.Frame",
            bindings: gbufRefl.vertexBindings,
            bufferIndex: 0,
            expectedSize: MemoryLayout<LightFrameUniforms>.stride,
            expectedFields: frameFields
        )
        try verifyBufferStruct(
            label: "light_gbuffer.vertex.Prim",
            bindings: gbufRefl.vertexBindings,
            bufferIndex: 1,
            expectedSize: MemoryLayout<Prim>.stride,
            expectedFields: primFields
        )

        // 2. shadow compute pipeline (Light)
        let shadowLib = try device.makeLibrary(source: RuneLightShaders.shadowShader, options: nil)
        let shadowFn = try #require(shadowLib.makeFunction(name: "shadow_kernel"))
        var shadowReflOpt: MTLAutoreleasedComputePipelineReflection?
        _ = try device.makeComputePipelineState(
            function: shadowFn,
            options: [.bindingInfo, .bufferTypeInfo],
            reflection: &shadowReflOpt
        )
        let lightFields: [(String, Int)] = [
            ("pos", try #require(MemoryLayout<Light>.offset(of: \.pos))),
            ("color", try #require(MemoryLayout<Light>.offset(of: \.color))),
            ("axis", try #require(MemoryLayout<Light>.offset(of: \.axis))),
            ("extra", try #require(MemoryLayout<Light>.offset(of: \.extra))),
        ]
        try verifyBufferStruct(
            label: "light_shadow.Light",
            bindings: try #require(shadowReflOpt).bindings,
            bufferIndex: 1,
            expectedSize: MemoryLayout<Light>.stride,
            expectedFields: lightFields
        )

        // 3. gi_cascade compute pipeline (Cascade)
        let cascadeLib = try device.makeLibrary(source: RuneLightShaders.giCascadeShader, options: nil)
        let cascadeFn = try #require(cascadeLib.makeFunction(name: "gi_cascade_kernel"))
        var cascadeReflOpt: MTLAutoreleasedComputePipelineReflection?
        _ = try device.makeComputePipelineState(
            function: cascadeFn,
            options: [.bindingInfo, .bufferTypeInfo],
            reflection: &cascadeReflOpt
        )
        let cascadeFields: [(String, Int)] = [
            ("n", try #require(MemoryLayout<CascadeUniforms>.offset(of: \.level))),
            ("count", try #require(MemoryLayout<CascadeUniforms>.offset(of: \.count))),
            ("merge", try #require(MemoryLayout<CascadeUniforms>.offset(of: \.merge))),
            ("pad1", try #require(MemoryLayout<CascadeUniforms>.offset(of: \.pad))),
        ]
        try verifyBufferStruct(
            label: "light_gi_cascade.Cascade",
            bindings: try #require(cascadeReflOpt).bindings,
            bufferIndex: 1,
            expectedSize: MemoryLayout<CascadeUniforms>.stride,
            expectedFields: cascadeFields
        )

        // 4. glass render pipeline (GlassU, Glass, GLight)
        let glassLib = try device.makeLibrary(source: RuneLightShaders.glassShader, options: nil)
        let glassVs: MTLFunction = try #require(glassLib.makeFunction(name: "glass_vertex"))
        let glassFs: MTLFunction = try #require(glassLib.makeFunction(name: "glass_fragment"))
        let glassDesc = MTLRenderPipelineDescriptor()
        glassDesc.vertexFunction = glassVs
        glassDesc.fragmentFunction = glassFs
        glassDesc.colorAttachments[0].pixelFormat = .rgba16Float
        var glassReflOpt: MTLAutoreleasedRenderPipelineReflection?
        _ = try device.makeRenderPipelineState(
            descriptor: glassDesc,
            options: [.bindingInfo, .bufferTypeInfo],
            reflection: &glassReflOpt
        )
        let glassRefl = try #require(glassReflOpt)

        let glassUFields: [(String, Int)] = [
            ("size", try #require(MemoryLayout<GlassUniforms>.offset(of: \.size))),
            ("misc", try #require(MemoryLayout<GlassUniforms>.offset(of: \.misc))),
            ("shadow", try #require(MemoryLayout<GlassUniforms>.offset(of: \.shadow))),
        ]
        let glassFields: [(String, Int)] = [
            ("a", try #require(MemoryLayout<Glass>.offset(of: \.a))),
            ("b", try #require(MemoryLayout<Glass>.offset(of: \.b))),
            ("r", try #require(MemoryLayout<Glass>.offset(of: \.r))),
            ("p0", try #require(MemoryLayout<Glass>.offset(of: \.p0))),
            ("p1", try #require(MemoryLayout<Glass>.offset(of: \.p1))),
            ("tint", try #require(MemoryLayout<Glass>.offset(of: \.tint))),
        ]
        let glassLightFields: [(String, Int)] = [
            ("pos", try #require(MemoryLayout<GlassLight>.offset(of: \.pos))),
            ("color", try #require(MemoryLayout<GlassLight>.offset(of: \.color))),
        ]
        try verifyBufferStruct(
            label: "light_glass.GlassU",
            bindings: glassRefl.fragmentBindings,
            bufferIndex: 0,
            expectedSize: MemoryLayout<GlassUniforms>.stride,
            expectedFields: glassUFields
        )
        try verifyBufferStruct(
            label: "light_glass.Glass",
            bindings: glassRefl.fragmentBindings,
            bufferIndex: 1,
            expectedSize: MemoryLayout<Glass>.stride,
            expectedFields: glassFields
        )
        try verifyBufferStruct(
            label: "light_glass.GLight",
            bindings: glassRefl.fragmentBindings,
            bufferIndex: 2,
            expectedSize: MemoryLayout<GlassLight>.stride,
            expectedFields: glassLightFields
        )
    }
    #endif
}
