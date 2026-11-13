import Foundation
import RuneMotion

// MARK: - Pointer Geometry Observer (crates/rune/src/input/pointer_observer.rs)

/// Tracks whether mounted interactive elements need layout geometry recomputation and observes geometry changes
/// without spamming steady-state frames (`pointer_observer.rs`).
public struct PointerObserver: Sendable, Equatable {
    public private(set) var needsGeometry: Bool = false
    public private(set) var lastObservedVersion: UInt64 = 0
    public private(set) var trackedRects: [String: MotionRect] = [:]
    public private(set) var canvasBounds: MotionRect = .zero
    public private(set) var displayBounds: [MotionRect] = []
    public private(set) var followPointer: Bool = false

    public init() {}

    /// Returns `true` when tracked canvas bounds or follow mode differ from the cached observer config (`Observer::needs_geometry`).
    public func needsGeometry(canvas: MotionRect, follow: Bool) -> Bool {
        canvasBounds != canvas || followPointer != follow
    }

    /// Configures canvas/display geometry and follow mode (`Observer::configure`).
    public mutating func configure(canvas: MotionRect, displays: [MotionRect], follow: Bool) {
        if canvasBounds != canvas || displayBounds != displays || followPointer != follow {
            needsGeometry = true
        }
        canvasBounds = canvas
        displayBounds = displays
        followPointer = follow
    }

    /// Marks geometry as dirty (e.g., after pointer enter, hit-region mount, or resize).
    public mutating func markNeedsGeometry() {
        needsGeometry = true
    }

    /// Configures tracked element keys and marks geometry refresh needed if the key set changed.
    public mutating func configure(keys: [String]) {
        let keySet = Set(keys)
        if Set(trackedRects.keys) != keySet {
            for k in trackedRects.keys where !keySet.contains(k) {
                trackedRects.removeValue(forKey: k)
            }
            needsGeometry = true
        }
    }

    /// Consumes and clears the `needsGeometry` flag (`PointerObserver::take`).
    public mutating func take() -> Bool {
        let needed = needsGeometry
        needsGeometry = false
        return needed
    }

    /// Observes a snapshot of `[keyOrPath: MotionRect]` at `version`.
    /// Sets `needsGeometry = true` only when a tracked geometry actually changes or `version` advances with deltas.
    @discardableResult
    public mutating func observe(_ rects: [String: MotionRect], version: UInt64) -> Bool {
        var changed = false
        if rects.count != trackedRects.count {
            changed = true
        } else {
            for (k, r) in rects {
                if trackedRects[k] != r {
                    changed = true
                    break
                }
            }
        }
        if changed {
            trackedRects = rects
            lastObservedVersion = version
            needsGeometry = true
        }
        return changed
    }

    /// Resets tracked rects and forces fresh geometry observation.
    public mutating func invalidate() {
        trackedRects.removeAll(keepingCapacity: true)
        needsGeometry = true
    }
}

// MARK: - Drag-and-Drop Pointer State Machine (crates/rune/src/input/drop_pointer.rs)

/// Tracks live OS file-drop drag coordinates and coalesced move events (`drop_pointer.rs`).
public struct DropPointer: Sendable, Equatable {
    public private(set) var isActive: Bool = false
    public private(set) var position: Vec2? = nil
    public private(set) var pendingMove: Vec2? = nil
    public private(set) var targetKey: String? = nil

    public init() {}

    /// Begins an OS drag session at `pos` over optional `targetKey`.
    public mutating func enter(at pos: Vec2, targetKey: String? = nil) {
        isActive = true
        position = pos
        pendingMove = pos
        self.targetKey = targetKey
    }

    /// Updates pointer coordinates while dragged over the window, coalescing pending move notifications.
    public mutating func move(to pos: Vec2, targetKey: String? = nil) {
        guard isActive else {
            enter(at: pos, targetKey: targetKey)
            return
        }
        if position != pos || self.targetKey != targetKey {
            position = pos
            pendingMove = pos
            self.targetKey = targetKey
        }
    }

    /// Consumes and clears the latest pending move point.
    public mutating func takePendingMove() -> Vec2? {
        defer { pendingMove = nil }
        return pendingMove
    }

    /// Ends the drop session upon performDrop (`return position`) or dragExit (`nil` on exit).
    @discardableResult
    public mutating func finish(committed: Bool) -> Vec2? {
        let dropPoint = committed ? position : nil
        isActive = false
        position = nil
        pendingMove = nil
        targetKey = nil
        return dropPoint
    }
}

// MARK: - Duplicate Element Key Diagnostics & Auto-Repair (crates/rune/src/input/key_diagnostics.rs)

/// Warning produced when two sibling/mounted elements share the same explicit `key` (`key_diagnostics.rs`).
public struct DuplicateKeyWarning: Sendable, Equatable {
    public var key: String
    public var count: Int
    public var paths: [String]

    public init(key: String, count: Int, paths: [String]) {
        self.key = key
        self.count = count
        self.paths = paths
    }
}

/// Validates and optionally repairs duplicate explicit `El.key` identifiers across a view tree (`key_diagnostics.rs`).
public enum KeyDiagnostics {
    /// Collects all duplicate explicit `keyId`s across `root`.
    public static func warnings<State>(in root: El<State>) -> [DuplicateKeyWarning] {
        var locations: [String: [String]] = [:]
        var order: [String] = []
        func walk(_ node: El<State>, path: String) {
            if let k = node.keyId, !k.isEmpty {
                if locations[k] == nil { order.append(k) }
                locations[k, default: []].append(path)
            }
            for (idx, child) in node.children.enumerated() {
                let seg = child.keyId.map { "[\($0)]" } ?? "\(idx)"
                walk(child, path: "\(path)/\(seg)")
            }
        }
        walk(root, path: root.keyId.map { "[\($0)]" } ?? "root")
        return order.compactMap { k in
            guard let paths = locations[k], paths.count > 1 else { return nil }
            return DuplicateKeyWarning(key: k, count: paths.count, paths: paths)
        }
    }

    /// Returns `true` when every explicit `keyId` in `root` is unique (`key_diagnostics::clean`).
    public static func isClean<State>(_ root: El<State>) -> Bool {
        warnings(in: root).isEmpty
    }

    /// Walks `root` and disambiguates duplicate keys (`"foo"` -> `"foo"`, `"foo#2"`, `"foo#3"`, ...),
    /// returning both the repaired tree and the diagnostics for the duplicates found (`rename_duplicates`).
    public static func renameDuplicates<State>(_ root: El<State>) -> (tree: El<State>, warnings: [DuplicateKeyWarning]) {
        let warns = warnings(in: root)
        guard !warns.isEmpty else { return (root, []) }
        var seenCount: [String: Int] = [:]
        var usedKeys: Set<String> = []

        func rewrite(_ node: El<State>) -> El<State> {
            var copy = node
            if let k = copy.keyId, !k.isEmpty {
                let n = (seenCount[k] ?? 0) + 1
                seenCount[k] = n
                if n == 1 && !usedKeys.contains(k) {
                    usedKeys.insert(k)
                } else {
                    var suffix = n
                    var candidate = "\(k)#\(suffix)"
                    while usedKeys.contains(candidate) {
                        suffix += 1
                        candidate = "\(k)#\(suffix)"
                    }
                    usedKeys.insert(candidate)
                    copy.keyId = candidate
                }
            }
            if !copy.children.isEmpty {
                copy.children = copy.children.map(rewrite)
            }
            return copy
        }

        return (rewrite(root), warns)
    }
}
