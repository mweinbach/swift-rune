import Foundation

// MARK: - 1. Accessibility Link Surface Adapter (`rune::a11y::AccessibilityLink`)

/// Surface-level accessibility adapter coordinating activation, pending actions, and incremental tree diffs (`a11y/mod.rs`).
public final class AccessibilityLink: @unchecked Sendable {
    public private(set) var isActive: Bool = false
    private let lock = NSLock()
    private var pendingActivate: Bool?
    private var pendingActions: [(id: String, action: AccessibilityAction, value: String?)] = []
    private var treeState = AccessibilityTreeState()

    public init() {}

    public func activate() {
        lock.lock()
        pendingActivate = true
        lock.unlock()
    }

    public func deactivate() {
        lock.lock()
        pendingActivate = false
        lock.unlock()
    }

    public func enqueueAction(nodeID: String, action: AccessibilityAction, value: String? = nil) {
        lock.lock()
        pendingActions.append((nodeID, action, value))
        lock.unlock()
    }

    /// Services queued activation/actions against `rootNode` and returns an incremental `AccessibilityTreeUpdate` if changed.
    public func service(
        rootNode: AccessibilityNode?,
        windowTitle: String,
        actionHandler: ((String, AccessibilityAction, String?) -> Bool)? = nil
    ) -> AccessibilityTreeUpdate? {
        lock.lock()
        let act = pendingActivate
        pendingActivate = nil
        let queued = pendingActions
        pendingActions.removeAll()
        lock.unlock()

        if let act {
            isActive = act
            if act {
                treeState.forceFullUpdate()
            } else {
                treeState.reset()
            }
        }

        if let handler = actionHandler {
            for req in queued {
                _ = handler(req.id, req.action, req.value)
            }
        }

        guard isActive, let rootNode else { return nil }
        return treeState.diff(root: rootNode, windowTitle: windowTitle)
    }
}

// MARK: - 2. Incremental Tree Diffing (`rune::a11y::tree`)

/// Change flags returned after computing an incremental accessibility update (`a11y::tree::Changes`).
public struct AccessibilityChanges: Equatable, Sendable {
    public var structure: Bool
    public var moved: Bool

    public init(structure: Bool = false, moved: Bool = false) {
        self.structure = structure
        self.moved = moved
    }
}

/// Incremental accessibility update emitted when a node mounts, mutates, or moves (`TreeUpdate`).
public struct AccessibilityTreeUpdate: Equatable, Sendable {
    public var windowTitle: String
    public var isFullTree: Bool
    public var updatedNodes: [AccessibilityNode]
    public var removedIDs: [String]
    public var changes: AccessibilityChanges

    public init(
        windowTitle: String,
        isFullTree: Bool,
        updatedNodes: [AccessibilityNode],
        removedIDs: [String],
        changes: AccessibilityChanges
    ) {
        self.windowTitle = windowTitle
        self.isFullTree = isFullTree
        self.updatedNodes = updatedNodes
        self.removedIDs = removedIDs
        self.changes = changes
    }
}

/// Tracks previously emitted accessibility fingerprints so idle frames cost zero allocations (`A11yTree`).
public final class AccessibilityTreeState {
    private var previousFingerprints: [String: UInt64] = [:]
    private var previousFrames: [String: MotionRect] = [:]
    private var needsFullTree: Bool = true
    public private(set) var lastChanges = AccessibilityChanges()

    public init() {}

    public func forceFullUpdate() {
        needsFullTree = true
    }

    public func reset() {
        previousFingerprints.removeAll()
        previousFrames.removeAll()
        needsFullTree = true
        lastChanges = AccessibilityChanges()
    }

    public func diff(root: AccessibilityNode, windowTitle: String) -> AccessibilityTreeUpdate? {
        var flat: [AccessibilityNode] = []
        flatten(root, into: &flat)

        var nextFP: [String: UInt64] = [:]
        var nextFrames: [String: MotionRect] = [:]
        var updated: [AccessibilityNode] = []
        var structureChanged = false
        var moved = false

        for node in flat {
            let fp = fingerprint(node)
            nextFP[node.id] = fp
            nextFrames[node.id] = node.frame
            if needsFullTree {
                updated.append(node)
            } else if let prev = previousFingerprints[node.id] {
                if prev != fp {
                    updated.append(node)
                    if let pb = previousFrames[node.id], pb != node.frame {
                        moved = true
                    }
                }
            } else {
                updated.append(node)
                structureChanged = true
            }
        }

        let removed = previousFingerprints.keys.filter { nextFP[$0] == nil }.sorted()
        if !removed.isEmpty {
            structureChanged = true
        }
        let full = needsFullTree
        if full && !flat.isEmpty {
            structureChanged = true
        }

        previousFingerprints = nextFP
        previousFrames = nextFrames
        needsFullTree = false
        lastChanges = AccessibilityChanges(structure: structureChanged, moved: moved)

        if !full && updated.isEmpty && removed.isEmpty {
            return nil
        }
        return AccessibilityTreeUpdate(
            windowTitle: windowTitle,
            isFullTree: full,
            updatedNodes: updated,
            removedIDs: removed,
            changes: lastChanges
        )
    }

    private func flatten(_ node: AccessibilityNode, into out: inout [AccessibilityNode]) {
        out.append(node)
        for child in node.children {
            flatten(child, into: &out)
        }
    }

    private func fingerprint(_ node: AccessibilityNode) -> UInt64 {
        var h = Hasher()
        h.combine(node.id)
        h.combine(node.role)
        h.combine(node.label)
        h.combine(node.value)
        h.combine(node.help)
        h.combine(node.isFocused)
        h.combine(node.isFocusable)
        h.combine(node.isSelected)
        h.combine(node.isExpanded)
        h.combine(node.level)
        h.combine(node.isModal)
        h.combine(node.isSecure)
        h.combine(node.frame)
        h.combine(node.actions)
        h.combine(node.children.map(\.id))
        return UInt64(bitPattern: Int64(h.finalize()))
    }
}

// MARK: - 3. Nested Accessibility JSON Dump (`rune::a11y::dump`)

/// Nested JSON dump of a projected `AccessibilityNode` tree (`a11y/dump.rs`).
public enum AccessibilityDump {
    public static func dictionary(from node: AccessibilityNode) -> [String: Any] {
        var dict: [String: Any] = [
            "key": node.id,
            "role": node.role.rawValue,
            "bounds": [
                round1(node.frame.x),
                round1(node.frame.y),
                round1(node.frame.width),
                round1(node.frame.height),
            ],
        ]
        if let label = node.label { dict["name"] = label }
        // Never leak plaintext for secure fields in accessibility dumps (`a11y::dump` / `D-A1`).
        if !node.isSecure, let val = node.value { dict["value"] = val }
        if let help = node.help, help != node.label { dict["description"] = help }
        if let heading = node.level { dict["level"] = heading }
        var states: [String] = []
        if node.isFocused { states.append("focused") }
        if node.isFocusable { states.append("focusable") }
        if node.isSelected { states.append("selected") }
        if node.isModal { states.append("modal") }
        if let exp = node.isExpanded { states.append(exp ? "expanded" : "collapsed") }
        if !states.isEmpty { dict["states"] = states }
        if !node.actions.isEmpty { dict["actions"] = node.actions.map(\.rawValue) }
        if !node.children.isEmpty {
            dict["children"] = node.children.map { dictionary(from: $0) }
        }
        return dict
    }

    public static func jsonString(from node: AccessibilityNode, pretty: Bool = false) -> String {
        let obj = dictionary(from: node)
        var opts: JSONSerialization.WritingOptions = [.sortedKeys]
        if pretty { opts.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: opts),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    private static func round1(_ v: Float) -> Double {
        Double((v * 10.0).rounded() / 10.0)
    }
}
