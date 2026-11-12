import Foundation
import Rune

/// What one layout leaves for the next build of a longer source to hold to, in the layout's
/// own axes (`rune_mermaid::steady`).
struct SteadyMemo: Sendable {
    var rank: [Int] = []
    var along: [Float?] = []
    var depth: [Float] = []
    var ids: [String] = []

    func renamed(ids newIds: [String]) -> SteadyMemo {
        if newIds.isEmpty || ids.isEmpty {
            return self
        }
        var was: [String: Int] = [:]
        was.reserveCapacity(ids.count)
        for (i, id) in ids.enumerated() {
            was[id] = i
        }
        let old: [Int?] = newIds.map { was[$0] }
        return SteadyMemo(
            rank: old.map { o in o.flatMap { $0 < rank.count ? rank[$0] : nil } ?? 0 },
            along: old.map { o in o.flatMap { $0 < along.count ? along[$0] : nil } },
            depth: depth,
            ids: newIds
        )
    }
}

/// What a streaming build laid out, one `SteadyMemo` per layout in the order it ran them,
/// whether a horizontal diagram turned upright, and how big it drew.
struct SteadyMemory: Sendable {
    var layouts: [SteadyMemo] = []
    var turned: Bool = false
    var origin: Vec2? = nil
    var size: Vec2 = .zero
}

enum SteadyLayout {
    private final class BuildState {
        var prev: SteadyMemory?
        var next: SteadyMemory

        init(prev: SteadyMemory?) {
            self.prev = prev
            self.next = SteadyMemory()
        }
    }

    private static let threadKey = "com.rune.mermaid.steady.build"

    private static var currentBuild: BuildState? {
        get { Thread.current.threadDictionary[threadKey] as? BuildState }
        set {
            if let newValue {
                Thread.current.threadDictionary[threadKey] = newValue
            } else {
                Thread.current.threadDictionary.removeObject(forKey: threadKey)
            }
        }
    }

    /// Runs `body`, holding its layouts to `prev`'s, and returns what they laid out.
    static func build<R>(prev: SteadyMemory?, _ body: () -> R) -> (R, SteadyMemory) {
        let saved = currentBuild
        let state = BuildState(prev: prev)
        currentBuild = state
        defer { currentBuild = saved }
        let out = body()
        return (out, state.next)
    }

    /// Runs one layout of nodes named `ids`: `place` receives the held memo (if any) and
    /// returns `(result, memo)` for the next build.
    static func layout<T>(ids: [String], place: (SteadyMemo?) -> (T, SteadyMemo)?) -> T? {
        guard let state = currentBuild else {
            return place(nil)?.0
        }
        let at = state.next.layouts.count
        let held = state.prev.flatMap { $0.layouts.indices.contains(at) ? $0.layouts[at].renamed(ids: ids) : nil }
        if let placed = place(held) {
            var memo = placed.1
            memo.ids = ids
            state.next.layouts.append(memo)
            return placed.0
        } else {
            var empty = SteadyMemo()
            empty.ids = ids
            state.next.layouts.append(empty)
            return nil
        }
    }

    static func turned() -> Bool {
        currentBuild?.prev?.turned ?? false
    }

    static func setTurned(_ turned: Bool) {
        currentBuild?.next.turned = turned
    }

    static func origin(bounds b: (Float, Float, Float, Float), turned: Bool) -> Vec2 {
        guard let state = currentBuild else {
            return Vec2(b.0, b.1)
        }
        let was: Vec2?
        if let prev = state.prev, prev.turned == turned {
            was = prev.origin
        } else {
            was = nil
        }
        let o = was.map { Vec2(min($0.x, b.0), min($0.y, b.1)) } ?? Vec2(b.0, b.1)
        state.next.origin = o
        return o
    }
}
