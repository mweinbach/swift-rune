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

    /// Takes and consumes the pending clipboard copy request once (`Runtime::copy_request.take()`).
    @discardableResult
    public func takeCopyRequest() -> String? {
        let out = copyRequest
        copyRequest = nil
        return out
    }

    internal func recordCopy(_ content: ClipboardContent, rich: RichClipboardPayload? = nil) {
        clipboard = content
        richClipboard = rich ?? RichClipboardPayload(content: content)
        clipboardRouting.copies.pendingConcealed = nil
        if boundClipboard != nil {
            writeCopyToBoundClipboard(text: content.text, rich: richClipboard)
            copyRequest = nil
        } else {
            copyRequest = content.text
        }
        recordOwnPills(content)
    }
}
