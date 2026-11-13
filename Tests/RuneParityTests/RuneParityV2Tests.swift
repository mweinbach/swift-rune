import Foundation
import Testing
@testable import RuneParityCLI

@Suite("UpstreamMap v2 Schema & Parity Tests")
struct RuneParityV2Tests {
    @Test("upstream-map.json decodes as v2 with optional null crate paths, crateExamples, and extraBins")
    func v2UpstreamMapSchema() throws {
        let mapURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RuneParityTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent(".agents/skills/upstream-rune-sync/references/upstream-map.json")

        let data = try Data(contentsOf: mapURL)
        let decoded = try JSONDecoder().decode(UpstreamMap.self, from: data)

        #expect(decoded.version == 2)
        #expect(decoded.upstreamBranch == "dev")
        #expect(decoded.crates.count == 18)
        #expect((decoded.themes ?? []).count == 1)
        #expect(decoded.examples.count == 31)
        #expect((decoded.crateExamples ?? []).count == 66)
        #expect((decoded.extraBins ?? []).count == 2)
        #expect(decoded.swiftOnlyExecutables == ["RuneParityCLI"])

        let staging = try #require(decoded.crates.first(where: { $0.upstreamPath == "crates/rune-staging" }))
        #expect(staging.swiftTarget == "RuneStaging")
        #expect(staging.swiftPath == "Sources/RuneStaging")
        #expect(staging.status == "mostly")

        let devGuard = try #require(decoded.extraBins?.first(where: { $0.upstreamPath == "tools/rune-dev-guard" }))
        #expect(devGuard.swiftTarget == nil)
        #expect(devGuard.status == "missing")
    }
}
