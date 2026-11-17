import Foundation
import RuneMotion
#if os(macOS) && canImport(AppKit)
import AppKit
#endif

// MARK: - Pointer Geometry Observer (crates/rune/src/input/pointer_observer.rs)

/// Half-open integer screen/canvas rectangle `[x0, y0, x1, y1)` matching `pointer_observer::contains`.
public struct PointerIntRect: Sendable, Equatable {
    public var x0: Int32
    public var y0: Int32
    public var x1: Int32
    public var y1: Int32

    public init(_ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }

    public init(rect: MotionRect) {
        self.x0 = Int32(rect.x.rounded(.down))
        self.y0 = Int32(rect.y.rounded(.down))
        self.x1 = Int32(rect.right.rounded(.up))
        self.y1 = Int32(rect.bottom.rounded(.up))
    }

    /// Half-open containment `[x0, y0) ..< [x1, y1)`.
    public func contains(_ point: (Int32, Int32)) -> Bool {
        point.0 >= x0 && point.1 >= y0 && point.0 < x1 && point.1 < y1
    }
}

/// Thread-safe pointer mailbox (`crates/rune/src/input/pointer_observer.rs`).
/// Global movement outside the canvas wakes the owner only on exit or a followed-display change,
/// and `wake` is always invoked outside the internal lock.
public final class PointerObserver: @unchecked Sendable {
    public enum Presence: Sendable, Equatable {
        /// Off the canvas and not yet seen inside any display.
        case outside
        /// Off the canvas, in `display` or in a gap after leaving it.
        case offCanvas(display: Int)
        /// On the canvas, optionally inside `display`.
        case onCanvas(display: Int?)

        public var display: Int? {
            switch self {
            case .outside: return nil
            case .offCanvas(let d): return d
            case .onCanvas(let d): return d
            }
        }

        public var isOnCanvas: Bool {
            if case .onCanvas = self { return true }
            return false
        }

        internal func step(
            point: (Int32, Int32),
            canvas: PointerIntRect,
            displays: [PointerIntRect],
            follow: Bool
        ) -> (next: Presence, interested: Bool) {
            let onCanvas = canvas.contains(point)
            let hitDisplay = displays.firstIndex { $0.contains(point) } ?? self.display
            let changed = follow && hitDisplay != self.display
            let next: Presence
            if onCanvas {
                next = .onCanvas(display: hitDisplay)
            } else if let d = hitDisplay {
                next = .offCanvas(display: d)
            } else {
                next = .outside
            }
            return (next, onCanvas || self.isOnCanvas || changed)
        }
    }

    private struct SampleState {
        var canvas: PointerIntRect = PointerIntRect(0, 0, 0, 0)
        var displays: [PointerIntRect] = []
        var follow: Bool = false
        var presence: Presence = .outside
        var last: (Int32, Int32)? = nil
        var pending: (Int32, Int32)? = nil
    }

    private let lock = NSLock()
    private var sample = SampleState()
    private let wake: (@Sendable () -> Void)?

    public init(wake: (@Sendable () -> Void)? = nil) {
        self.wake = wake
    }

    /// Current presence state for diagnostics/tests.
    public var presence: Presence {
        lock.lock()
        defer { lock.unlock() }
        return sample.presence
    }

    /// Returns `true` when canvas bounds or `follow` differ from the configured observer geometry.
    public func needsGeometry(canvas: PointerIntRect, follow: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sample.canvas != canvas || sample.follow != follow
    }

    /// Updates canvas/display rectangles and follow mode, clearing the last deduplicated sample if geometry changed.
    public func configure(canvas: PointerIntRect, displays: [PointerIntRect], follow: Bool) {
        lock.lock()
        if sample.canvas != canvas || sample.displays != displays || sample.follow != follow {
            sample.last = nil
        }
        sample.canvas = canvas
        sample.displays = displays
        sample.follow = follow
        lock.unlock()
    }

    /// Consumes and clears the latest pending pointer observation.
    public func take() -> (Int32, Int32)? {
        lock.lock()
        defer { lock.unlock() }
        let pt = sample.pending
        sample.pending = nil
        return pt
    }

    /// Observes a pointer coordinate, queueing a wakeup outside the lock only when relevant.
    public func observe(_ point: (Int32, Int32)) {
        let shouldWake: Bool
        lock.lock()
        let (nextPresence, interested) = sample.presence.step(
            point: point,
            canvas: sample.canvas,
            displays: sample.displays,
            follow: sample.follow
        )
        sample.presence = nextPresence
        if interested && sample.last.map({ $0.0 != point.0 || $0.1 != point.1 }) ?? true {
            sample.last = point
            sample.pending = point
            shouldWake = true
        } else {
            shouldWake = false
        }
        lock.unlock()
        if shouldWake {
            wake?()
        }
    }
}

// MARK: - Drag-and-Drop Pointer Sampling (crates/rune/src/input/drop_pointer.rs)

/// Samples live system pointer coordinates over a window during OS file drags (`drop_pointer.rs`),
/// dividing by `zoom` (`Cx::zoom`).
public final class DropPointer: @unchecked Sendable {
    private let windowSampler: (@Sendable (AnyObject?) -> Vec2?)?

    public init(sampler: (@Sendable (AnyObject?) -> Vec2?)? = nil) {
        self.windowSampler = sampler
    }

    /// Returns pointer coordinates in zoomed view points (`windowPt / zoom`), or `nil` if unavailable.
    public func sample(in window: AnyObject?, zoom: Float = 1.0) -> Vec2? {
        guard let windowPt = sampleWindow(window) else { return nil }
        let z = zoom > 0 ? zoom : 1.0
        return Vec2(windowPt.x / z, windowPt.y / z)
    }

    /// Samples the live pointer inside `window`'s content view in unzoomed window points.
    public func sampleWindow(_ window: AnyObject?) -> Vec2? {
        if let windowSampler {
            return windowSampler(window)
        }
        #if os(macOS) && canImport(AppKit)
        guard Thread.isMainThread, let obj = window else { return nil }
        nonisolated(unsafe) let target = obj
        return MainActor.assumeIsolated {
            let view: NSView? = (target as? NSView) ?? (target as? NSWindow)?.contentView
            guard let view, let nsWin = view.window else { return nil }
            let p = view.convert(nsWin.mouseLocationOutsideOfEventStream, from: nil)
            let y = view.isFlipped ? p.y : (view.bounds.size.height - p.y)
            return Vec2(Float(p.x), Float(y))
        }
        #else
        _ = window
        return nil
        #endif
    }
}

// MARK: - Duplicate Sibling Key Diagnostics & Repair (crates/rune/src/input/key_diagnostics.rs)

/// Warning produced when two sibling elements share the same explicit `key` under one parent (`key_diagnostics.rs`).
public struct DuplicateKeyWarning: Sendable, Equatable {
    public var key: String
    public var count: Int
    public var paths: [String]
    public var message: String

    public init(key: String, count: Int, paths: [String], message: String = "") {
        self.key = key
        self.count = count
        self.paths = paths
        self.message = message
    }
}

/// Validates and repairs per-parent duplicate sibling keys (`crates/rune/src/input/key_diagnostics.rs`).
public enum KeyDiagnostics {
    static func uniqueSiblings<State>(_ children: [El<State>]) -> Bool {
        guard children.count > 1 else { return true }
        if children.count <= 8 {
            for i in children.indices {
                guard let key = children[i].storageKeyId else { continue }
                for j in (i + 1)..<children.count where children[j].storageKeyId == key { return false }
            }
            return true
        }
        var seen = Set<String>()
        for child in children {
            if let key = child.storageKeyId, !seen.insert(key).inserted { return false }
        }
        return true
    }

    private static func checksSiblings<State>(_ el: El<State>) -> Bool {
        el.virtualEstimate == nil
    }

    /// Returns `true` when no parent in `root` has two sibling children sharing a key (`key_diagnostics::clean`).
    public static func clean<State>(_ root: El<State>) -> Bool {
        var node = root
        var siblings: [ArraySlice<El<State>>] = []
        while true {
            if let owner = node.memoLayoutChildren, owner.matches(node.children) {
                if owner.traits.contains(.duplicateKeys) || (checksSiblings(node) && owner.duplicateSiblings) {
                    return false
                }
            } else {
                if checksSiblings(node) && !uniqueSiblings(node.children) { return false }
                if let first = node.children.first {
                    if node.children.count > 1 { siblings.append(node.children.dropFirst()) }
                    node = first
                    continue
                }
            }
            guard var rest = siblings.popLast() else { return true }
            node = rest.removeFirst()
            if !rest.isEmpty { siblings.append(rest) }
        }
    }

    /// Alias for `clean(_:)`.
    public static func isClean<State>(_ root: El<State>) -> Bool {
        clean(root)
    }

    /// Collects per-parent duplicate sibling key diagnostics under `root` (`key_diagnostics::find` / `warnings`).
    public static func find<State>(in root: El<State>, path: String? = nil) -> [DuplicateKeyWarning] {
        guard !clean(root) else { return [] }
        var out: [DuplicateKeyWarning] = []
        var pending = [(root, path ?? root.keyId ?? "#0")]
        while let (el, path) = pending.popLast() {
            if checksSiblings(el) {
                var firstIdx: [String: Int] = [:]
                var dupPaths: [String: [String]] = [:]
                var order: [String] = []
                for (idx, child) in el.children.enumerated() {
                    guard let k = child.storageKeyId else { continue }
                    let authored = child.keyId ?? k
                    let childPath = "\(path)/\(authored)"
                    if let first = firstIdx[k] {
                        if dupPaths[k] == nil {
                            order.append(k)
                            dupPaths[k] = ["\(path)/\(authored)#\(first)"]
                        }
                        dupPaths[k, default: []].append("\(childPath)#\(idx)")
                    } else {
                        firstIdx[k] = idx
                    }
                }
                for k in order {
                    let paths = dupPaths[k] ?? []
                    let authored = firstIdx[k].flatMap { el.children[$0].keyId } ?? k
                    let msg = "duplicate sibling key \"\(authored)\" under \"\(path)\": give siblings unique keys"
                    out.append(DuplicateKeyWarning(key: authored, count: paths.count, paths: paths, message: msg))
                }
            }
            for idx in el.children.indices.reversed() {
                let child = el.children[idx]
                if !clean(child) {
                    let segment = child.keyId ?? "#\(idx)"
                    pending.append((child, "\(path)/\(segment)"))
                }
            }
        }
        return out
    }

    /// Convenience returning formatted warning messages (matches Rust `key_diagnostics::warnings`).
    public static func warnings<State>(in root: El<State>) -> [DuplicateKeyWarning] {
        find(in: root)
    }

    /// Renames each later copy of a sibling key `key#dup1`, `key#dup2`, ... in order, skipping names already taken
    /// (`key_diagnostics::rename_duplicates`). Returns `(index, oldKey)` for each renamed slot.
    @discardableResult
    public static func renameDuplicates(_ keys: inout [String]) -> [(index: Int, oldKey: String)] {
        renameDuplicates(&keys, candidate: { "\($0)#dup\($1)" })
    }

    internal static func renameDuplicates(
        _ keys: inout [String], candidate: (String, Int) -> String
    ) -> [(index: Int, oldKey: String)] {
        var taken = Set(keys)
        guard taken.count != keys.count else { return [] }
        var kept = Set<String>()
        var nextSuffix: [String: Int] = [:]
        var renamed: [(index: Int, oldKey: String)] = []
        for i in keys.indices {
            let cur = keys[i]
            if kept.insert(cur).inserted {
                continue
            }
            var n = nextSuffix[cur, default: 1]
            var name = candidate(cur, n)
            while taken.contains(name) {
                n += 1
                name = candidate(cur, n)
            }
            nextSuffix[cur] = n + 1
            taken.insert(name)
            kept.insert(name)
            renamed.append((i, cur))
            keys[i] = name
        }
        return renamed
    }

    /// Repairs duplicate sibling keys across `root` (`key#dup1`, `key#dup2`, ...), returning both the repaired
    /// element tree and the diagnostics for duplicates found (`key_diagnostics::repair`).
    public static func repair<State>(_ root: El<State>) -> (tree: El<State>, warnings: [DuplicateKeyWarning]) {
        repair(root, at: nil) { _ in }
    }

    struct Rename {
        let path: String
        let originalKey: String
        let originalStorage: String
        let warning: String
    }

    static func repair<State>(_ root: El<State>, at mountedPath: String?, onRename: (Rename) -> Void)
        -> (tree: El<State>, warnings: [DuplicateKeyWarning]) {
        let warns = find(in: root, path: mountedPath)
        guard !warns.isEmpty else { return (root, []) }
        func repairChildren(_ copy: inout El<State>, path: String) {
            if checksSiblings(copy) && !uniqueSiblings(copy.children) {
                var keyedIndices: [Int] = []
                var keyedStrings: [String] = []
                var authoredByStorage: [String: String] = [:]
                for (i, c) in copy.children.enumerated() {
                    if let k = c.storageKeyId {
                        keyedIndices.append(i)
                        keyedStrings.append(k)
                        if let authored = c.authoredByteExactKey { authoredByStorage[k] = authored }
                    }
                }
                let changes = renameDuplicates(&keyedStrings) { stored, suffix in
                    guard let authored = authoredByStorage[stored] else { return "\(stored)#dup\(suffix)" }
                    let exact = matchesAuthoredKey(VirtualRowKeyEncoding.storageKey(authored), stored)
                    return VirtualRowKeyEncoding.storageKey("\(authored)#dup\(suffix)", byteExact: exact)
                }
                for (localIdx, originalStorage) in changes {
                    let childIdx = keyedIndices[localIdx]
                    let original = copy.children[childIdx].keyId ?? originalStorage
                    let stored = keyedStrings[localIdx]
                    if copy.children[childIdx].authoredByteExactKey != nil {
                        copy.children[childIdx].storageKeyId = stored
                        copy.children[childIdx].authoredByteExactKey = VirtualRowKeyEncoding.authoredKey(stored)
                    } else {
                        copy.children[childIdx].keyId = stored
                    }
                    let repaired = copy.children[childIdx]
                    onRename(Rename(path: "\(path)/@\(keyedStrings[localIdx])", originalKey: original, originalStorage: originalStorage,
                                    warning: "Duplicate sibling key '\(original)' renamed to '\(repaired.keyId ?? keyedStrings[localIdx])' under \(path)"))
                }
            }
        }

        var node = root
        var path = mountedPath ?? root.storageKeyId.map { "/@\($0)" } ?? "/0"
        var nextChild = 0
        var parents: [(node: El<State>, path: String, child: Int)] = []
        while true {
            if nextChild == 0 { repairChildren(&node, path: path) }
            if let i = (nextChild..<node.children.count).first(where: { !clean(node.children[$0]) }) {
                parents.append((node, path, i))
                node = node.children[i]
                path += "/" + (node.storageKeyId.map { "@\($0)" } ?? String(i))
                nextChild = 0
            } else {
                guard var parent = parents.popLast() else { return (node, warns) }
                parent.node.children[parent.child] = node
                node = parent.node
                path = parent.path
                nextChild = parent.child + 1
            }
        }
    }

    /// Compatibility alias for `repair(_:)`.
    public static func renameDuplicates<State>(_ root: El<State>) -> (tree: El<State>, warnings: [DuplicateKeyWarning]) {
        repair(root)
    }
}

extension Runtime {
    /// Inspects the mounted flat tree for duplicate sibling keys under any non-virtualized parent.
    public func siblingKeyWarnings() -> [DuplicateKeyWarning] {
        var byParent: [Int: [(storage: String, key: String, path: String)]] = [:]
        for idx in flatNodes.indices {
            let node = flatNodes[idx]
            guard let pIdx = node.parentIndex,
                  flatNodes[pIdx].el.virtualEstimate == nil,
                  let storage = renamedSiblingKeys[node.path]?.originalStorage ?? node.el.storageKeyId,
                  let key = renamedSiblingKeys[node.path]?.originalKey ?? node.key else { continue }
            byParent[pIdx, default: []].append((storage, key, node.path))
        }
        var out: [DuplicateKeyWarning] = []
        for pIdx in byParent.keys.sorted() {
            let children = byParent[pIdx] ?? []
            var groups: [String: [String]] = [:]
            var order: [(storage: String, key: String)] = []
            for c in children {
                if groups[c.storage] == nil { order.append((c.storage, c.key)) }
                groups[c.storage, default: []].append(c.path)
            }
            let pPath = flatNodes[pIdx].path
            for (storage, k) in order {
                let paths = groups[storage] ?? []
                if paths.count > 1 {
                    let msg = "duplicate sibling key \"\(k)\" under \"\(pPath)\": give siblings unique keys"
                    out.append(DuplicateKeyWarning(key: k, count: paths.count, paths: paths, message: msg))
                }
            }
        }
        return out
    }
}
