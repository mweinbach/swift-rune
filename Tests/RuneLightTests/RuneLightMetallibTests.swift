import Testing
import Foundation
import Rune
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
        #endif
    }
}
