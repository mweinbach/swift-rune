import Foundation

/// Per-frame runtime counters (`rune::runtime::FrameStats`).
public struct FrameStats: Sendable, Equatable {
    public var commits: UInt64
    public var layoutNodes: Int
    public var glyphs: Int
    public var shaped: UInt32

    public init(
        commits: UInt64 = 0,
        layoutNodes: Int = 0,
        glyphs: Int = 0,
        shaped: UInt32 = 0
    ) {
        self.commits = commits
        self.layoutNodes = layoutNodes
        self.glyphs = glyphs
        self.shaped = shaped
    }
}

extension AnimSource {
    /// Human-readable labels aligned by bit index (`AnimSource::NAMES`).
    public static let NAMES: [String] = [
        "tracks",
        "growth",
        "scroll",
        "reveal",
        "loop",
        "scale-settle",
        "video",
        "text-flight",
        "live",
        "virtual-fill",
    ]
}

internal enum FrameStatsSidecar {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var counters: [ObjectIdentifier: (glyphs: Int, shaped: UInt32)] = [:]
    }

    private static let storage = Storage()

    static func set<State>(_ runtime: Runtime<State>, glyphs: Int, shaped: UInt32) {
        storage.lock.lock()
        storage.counters[ObjectIdentifier(runtime)] = (glyphs, shaped)
        storage.lock.unlock()
    }

    static func get<State>(_ runtime: Runtime<State>) -> (glyphs: Int, shaped: UInt32) {
        storage.lock.lock()
        let out = storage.counters[ObjectIdentifier(runtime)] ?? (0, 0)
        storage.lock.unlock()
        return out
    }
}

extension Runtime {
    /// Per-frame statistics (`Runtime::stats`).
    public var stats: FrameStats {
        let counts = FrameStatsSidecar.get(self)
        return FrameStats(
            commits: commitCount,
            layoutNodes: flatNodes.count,
            glyphs: counts.glyphs,
            shaped: counts.shaped
        )
    }

    /// Most recent clipboard copy text requested via `Tx.copy(...)`, if non-empty (`Runtime::copy_request`).
    public var copyRequest: String? {
        clipboard.text.isEmpty ? nil : clipboard.text
    }
}
