import Testing
import Foundation
import Rune
import RuneFX
@testable import RuneLight
#if canImport(Metal)
@preconcurrency import Metal
#endif

@Suite("RuneLight Metallib Parity Tests", .serialized)
struct RuneLightMetallibTests {
    @Test("Dumps RuneLight shaders when RUNE_DUMP_METALLIB_DIR is set")
    func dumpBuiltinShadersForPrecompile() throws {
        #if canImport(Metal)
        guard let dir = ProcessInfo.processInfo.environment["RUNE_DUMP_METALLIB_DIR"], !dir.isEmpty else {
            return
        }
        let targetDir = URL(fileURLWithPath: dir).appendingPathComponent("runelight")
        try PrecompiledMetallib.dumpShaders(RuneLightShaders.precompileEntries, to: targetDir)
        #endif
    }

    @Test("RuneLight bundled metallibs match live MSL hashes and compile")
    func bundledRuneLightMetallibsAreFresh() throws {
        #if canImport(Metal)
        guard let device = MTLCreateSystemDefaultDevice() else { return }

        for entry in RuneLightShaders.precompileEntries {
            let result = try PrecompiledMetallib.loadLibraryWithOrigin(
                named: entry.name,
                source: entry.source,
                requiredFunction: entry.requiredFunction,
                bundle: RuneLightShaders.resourceBundle,
                allowPrecompiled: true,
                on: device
            )
            #expect(result.library.functionNames.contains(entry.requiredFunction))
            #expect(result.usedPrecompiled, "Expected precompiled metallib hit for \(entry.name)")

            let cached = try ShaderLibraryCache.load(
                named: entry.name,
                source: entry.source,
                requiredFunction: entry.requiredFunction,
                bundle: RuneLightShaders.resourceBundle,
                on: device
            )
            #expect(cached.functionNames.contains(entry.requiredFunction))
        }

        let expectedFunctions: [String: [String]] = [
            "light_gbuffer": ["gbuffer_vertex", "gbuffer_fragment"],
            "light_field": ["field_kernel"],
            "light_shadow": ["shadow_kernel"],
            "light_gi_scene": ["gi_scene_kernel"],
            "light_gi_cascade": ["gi_cascade_kernel"],
            "light_gi_fluence": ["gi_fluence_kernel"],
            "light_composite": ["composite_vertex", "composite_fragment"],
            "light_glass": ["glass_vertex", "glass_fragment", "glass_pyramid_fragment"],
        ]
        for (libName, fns) in expectedFunctions {
            let entry = try #require(RuneLightShaders.precompileEntries.first { $0.name == libName })
            let lib = try ShaderLibraryCache.load(
                named: entry.name,
                source: entry.source,
                requiredFunction: entry.requiredFunction,
                bundle: RuneLightShaders.resourceBundle,
                on: device
            )
            for fn in fns {
                #expect(lib.functionNames.contains(fn), "Missing \(fn) in \(libName)")
            }
        }
        #endif
    }

    @Test("Every builtin pipeline in RuneFX and RuneLight loads from precompiled metallibs with zero misses")
    func everyBuiltinPipelineIsPrecompiled() throws {
        #if canImport(Metal)
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        ShaderLibraryCache.invalidateForTesting(device: device)
        PrecompiledMetallib.resetLoadCountForTesting()

        let fx = try FxRenderer(device: device, pixelFormat: .bgra8Unorm_srgb)
        fx.addFormat(.rgba16Float)
        try fx.buildEveryPipeline()
        fx.setFireSim(true)

        _ = try LightRenderer(device: device, width: 64, height: 64, outputFormat: .bgra8Unorm_srgb)
        _ = try GlassRenderer(device: device, width: 64, height: 64, pixelFormat: .bgra8Unorm_srgb)

        let expectedLibraries = RuneFXShaders.precompileEntries.count + RuneLightShaders.precompileEntries.count
        #expect(PrecompiledMetallib.precompiledLoadCount == expectedLibraries)
        #endif
    }
}
