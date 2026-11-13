import Testing
import Foundation
import Rune
@testable import RuneFX
#if canImport(Metal)
@preconcurrency import Metal
#endif

@Suite("RuneFX Metallib Parity Tests", .serialized)
struct RuneFXMetallibTests {
    @Test("Dumps RuneFX shaders when RUNE_DUMP_METALLIB_DIR is set")
    func dumpBuiltinShadersForPrecompile() throws {
        #if canImport(Metal)
        guard let dir = ProcessInfo.processInfo.environment["RUNE_DUMP_METALLIB_DIR"], !dir.isEmpty else {
            return
        }
        let targetDir = URL(fileURLWithPath: dir).appendingPathComponent("runefx")
        try PrecompiledMetallib.dumpShaders(RuneFXShaders.precompileEntries, to: targetDir)
        #endif
    }

    @Test("RuneFX bundled metallibs match live MSL hashes and compile")
    func bundledRuneFXMetallibsAreFresh() throws {
        #if canImport(Metal)
        guard let device = MTLCreateSystemDefaultDevice() else { return }

        for entry in RuneFXShaders.precompileEntries {
            let result = try PrecompiledMetallib.loadLibraryWithOrigin(
                named: entry.name,
                source: entry.source,
                requiredFunction: entry.requiredFunction,
                bundle: RuneFXShaders.resourceBundle,
                allowPrecompiled: true,
                on: device
            )
            #expect(result.library.functionNames.contains(entry.requiredFunction))
            #expect(result.usedPrecompiled, "Expected precompiled metallib hit for \(entry.name)")

            let cached = try ShaderLibraryCache.load(
                named: entry.name,
                source: entry.source,
                requiredFunction: entry.requiredFunction,
                bundle: RuneFXShaders.resourceBundle,
                on: device
            )
            #expect(cached.functionNames.contains(entry.requiredFunction))
        }

        let blurLib = try ShaderLibraryCache.load(
            named: "fx_blur",
            source: RuneFXShaders.blurShader,
            requiredFunction: "fx_blur_vertex",
            bundle: RuneFXShaders.resourceBundle,
            on: device
        )
        #expect(blurLib.functionNames.contains("fx_blur_vertex"))
        #expect(blurLib.functionNames.contains("fx_blur_down_fragment"))
        #expect(blurLib.functionNames.contains("fx_blur_up_fragment"))

        let simLib = try ShaderLibraryCache.load(
            named: "fx_firesim",
            source: RuneFXShaders.fireSimShader,
            requiredFunction: "fx_firesim_step_kernel",
            bundle: RuneFXShaders.resourceBundle,
            on: device
        )
        for k in ["curl", "forces", "divergence", "jacobi", "project", "advect"] {
            #expect(simLib.functionNames.contains(k))
        }
        #endif
    }
}
