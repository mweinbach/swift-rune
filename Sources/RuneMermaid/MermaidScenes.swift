import Foundation
import Rune

/// Built scenes, kept by source, style and hover, so a diagram rebuilt with nothing new costs a
/// lookup, and a diagram streaming in builds each line held to the one before (`rune_mermaid::scenes`).
enum MermaidScenes {
    private static let cacheLen = 16
    private static let maxHeldLines = 64

    struct Built: Sendable {
        var scene: MermaidScene?
        var memory: SteadyMemory?
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [Int: Built] = [:]
        private var order: [Int] = []

        func get(_ key: Int) -> Built? {
            lock.lock()
            defer { lock.unlock() }
            return map[key]
        }

        func insert(_ key: Int, _ value: Built) {
            lock.lock()
            defer { lock.unlock() }
            if map[key] == nil {
                if order.count >= MermaidScenes.cacheLen {
                    let old = order.removeFirst()
                    map.removeValue(forKey: old)
                }
                order.append(key)
            }
            map[key] = value
        }

        func clear() {
            lock.lock()
            defer { lock.unlock() }
            map.removeAll()
            order.removeAll()
        }
    }

    private static let cache = Cache()

    static func clearCache() {
        cache.clear()
    }

    static func built(
        _ source: String,
        theme: MermaidTheme,
        hover: (MermaidHover, Color)?,
        prev: SteadyMemory?? = nil
    ) -> Built {
        let key = sceneKey(source, theme: theme, hover: hover, growing: prev != nil)
        if let cached = cache.get(key) {
            return cached
        }
        let b = build(source, theme: theme, hover: hover, prev: prev)
        cache.insert(key, b)
        return b
    }

    private static func build(
        _ source: String,
        theme: MermaidTheme,
        hover: (MermaidHover, Color)?,
        prev: SteadyMemory??
    ) -> Built {
        func makeScene() -> MermaidScene? {
            guard let parsed = MermaidParser.parse(source),
                  let s = renderScene(parsed, theme: theme, hover: hover) else {
                return nil
            }
            return s.withTitle(parsed.title)
        }

        switch prev {
        case .none:
            return Built(scene: makeScene(), memory: nil)
        case let .some(prevMem):
            let held = prevMem?.size ?? .zero
            let (rawScene, mutMem) = SteadyLayout.build(prev: prevMem, makeScene)
            let finalScene: MermaidScene? = rawScene.map { s in
                var copy = s
                copy.size = Vec2(max(s.size.x, held.x), max(s.size.y, held.y))
                return copy
            }
            var mem = mutMem
            mem.size = finalScene?.size ?? held
            return Built(scene: finalScene, memory: mem)
        }
    }

    private static func sceneKey(
        _ source: String,
        theme: MermaidTheme,
        hover: (MermaidHover, Color)?,
        growing: Bool
    ) -> Int {
        var h = Hasher()
        h.combine(source)
        h.combine(theme)
        if let (mode, color) = hover {
            h.combine(true)
            h.combine(mode)
            h.combine(color)
        } else {
            h.combine(false)
        }
        h.combine(growing)
        h.combine(fontEpoch())
        return h.finalize()
    }

    static func growing(
        _ source: String,
        theme: MermaidTheme,
        hover: (MermaidHover, Color)?
    ) -> MermaidScene? {
        let trimmed = trimTrailingWhitespace(source)
        if let cached = cache.get(sceneKey(trimmed, theme: theme, hover: hover, growing: true)) {
            return cached.scene
        }
        var chain: [String] = [trimmed]
        var prev: SteadyMemory? = nil
        while let last = chain.last, let nl = last.lastIndex(of: "\n") {
            let shorter = trimTrailingWhitespace(String(last[..<nl]))
            if let cached = cache.get(sceneKey(shorter, theme: theme, hover: hover, growing: true)) {
                prev = cached.memory
                break
            }
            if chain.count >= maxHeldLines {
                break
            }
            chain.append(shorter)
        }
        let target = chain.removeFirst()
        for s in chain.reversed() {
            prev = build(s, theme: theme, hover: hover, prev: .some(prev)).memory
        }
        return built(target, theme: theme, hover: hover, prev: .some(prev)).scene
    }

    private static func trimTrailingWhitespace(_ s: String) -> String {
        var end = s.endIndex
        while end > s.startIndex {
            let before = s.index(before: end)
            if s[before].isWhitespace {
                end = before
            } else {
                break
            }
        }
        return String(s[..<end])
    }
}
