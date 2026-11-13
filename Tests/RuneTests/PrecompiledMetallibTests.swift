import Testing
import Foundation
@testable import Rune
#if canImport(Metal)
@preconcurrency import Metal
#endif

@Suite("Precompiled Metallib Parity Tests", .serialized)
struct PrecompiledMetallibTests {
    @Test("Dumps built-in Rune shaders when RUNE_DUMP_METALLIB_DIR is set")
    func dumpBuiltinShadersForPrecompile() throws {
        #if canImport(Metal)
        guard let dir = ProcessInfo.processInfo.environment["RUNE_DUMP_METALLIB_DIR"], !dir.isEmpty else {
            return
        }
        let targetDir = URL(fileURLWithPath: dir).appendingPathComponent("rune")
        try PrecompiledMetallib.dumpShaders(PrecompiledMetallib.builtinEntries, to: targetDir)
        #endif
    }

    @Test("Bundled Rune metallibs exist, match live MSL hashes, and load via ShaderLibraryCache")
    func bundledMetallibsAreFreshAndLoad() throws {
        #if canImport(Metal)
        guard let device = MTLCreateSystemDefaultDevice() else { return }

        let manifest = PrecompiledMetallib.loadManifest(in: PrecompiledMetallib.runeResourceBundle)
        #expect(manifest != nil)

        for entry in PrecompiledMetallib.builtinEntries {
            let expectedHash = PrecompiledMetallib.fnv64(entry.source)
            #expect(manifest?[entry.name] == expectedHash, "Stale or missing manifest hash for \(entry.name)")

            let result = try PrecompiledMetallib.loadLibraryWithOrigin(
                named: entry.name,
                source: entry.source,
                requiredFunction: entry.requiredFunction,
                bundle: PrecompiledMetallib.runeResourceBundle,
                allowPrecompiled: true,
                on: device
            )
            #expect(result.library.functionNames.contains(entry.requiredFunction))
            #expect(result.usedPrecompiled, "Expected precompiled metallib hit for \(entry.name)")

            let cached = try ShaderLibraryCache.load(
                named: entry.name,
                source: entry.source,
                requiredFunction: entry.requiredFunction,
                bundle: PrecompiledMetallib.runeResourceBundle,
                on: device
            )
            #expect(cached.functionNames.contains(entry.requiredFunction))
        }
        #endif
    }

    @Test("ShaderLibraryCache falls back to runtime MSL when disabled or source hash diverges")
    func runtimeMSLFallbackWorks() throws {
        #if canImport(Metal)
        guard let device = MTLCreateSystemDefaultDevice() else { return }

        // 1. Disabled precompiled loading falls back cleanly to runtime MSL compilation.
        let disabledResult = try PrecompiledMetallib.loadLibraryWithOrigin(
            named: "backdrop_composite",
            source: RenderShaders.backdropCompositeMSL,
            requiredFunction: "backdrop_composite_vs",
            bundle: PrecompiledMetallib.runeResourceBundle,
            allowPrecompiled: false,
            on: device
        )
        #expect(disabledResult.library.functionNames.contains("backdrop_composite_vs"))
        #expect(!disabledResult.usedPrecompiled)

        // 2. Modified source string (hash mismatch vs manifest) bypasses stale metallib and compiles MSL.
        let tweakedSource = RenderShaders.backdropCompositeMSL + "\n// fresh-msl-override\n"
        let tweakedResult = try PrecompiledMetallib.loadLibraryWithOrigin(
            named: "backdrop_composite",
            source: tweakedSource,
            requiredFunction: "backdrop_composite_vs",
            bundle: PrecompiledMetallib.runeResourceBundle,
            allowPrecompiled: true,
            on: device
        )
        #expect(tweakedResult.library.functionNames.contains("backdrop_composite_vs"))
        #expect(!tweakedResult.usedPrecompiled)
        #endif
    }
}
