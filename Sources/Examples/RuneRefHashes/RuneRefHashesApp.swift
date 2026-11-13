import Foundation
import RuneRef

/// Parity port of `crates/rune-ref/examples/hashes.rs`: prints the JSON BLAKE3 hash corpus
/// for `OracleGenerator.seeded(seed, 8)` across seeds `0..<16`.
@main
enum RuneRefHashesApp {
    struct Entry: Encodable {
        let seed: UInt64
        let hash: String
    }

    static func computeHashes(seedCount: Int = 16, primitiveCount: Int = 8) throws -> [Entry] {
        var entries: [Entry] = []
        entries.reserveCapacity(seedCount)
        for seed in 0..<UInt64(seedCount) {
            let scene = OracleGenerator.seeded(seed: seed, count: primitiveCount)
            try scene.validate()
            var frame = OracleFrame(width: scene.width, height: scene.height, provenance: false)
            frame.render(scene)
            entries.append(Entry(seed: seed, hash: frame.hash()))
        }
        return entries
    }

    static func main() throws {
        let entries = try computeHashes()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        if let json = String(data: data, encoding: .utf8) {
            print(json)
        }
    }
}
