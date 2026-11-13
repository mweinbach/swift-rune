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
        h.combine(node.placeholder)
        h.combine(node.range?.value)
        h.combine(node.positionInSet)
        h.combine(node.sizeOfSet)
        h.combine(node.keyboardShortcut)
        h.combine(node.url)
        h.combine(node.activeDescendant)
        h.combine(node.sortAscending)
        h.combine(node.isDisabled)
        h.combine(node.isReadOnly)
        h.combine(node.isInvalid)
        h.combine(node.toggled)
        h.combine(node.selectedState)
        h.combine(node.liveRegion)
        h.combine(node.clipsChildren)
        h.combine(node.scrollX)
        h.combine(node.scrollY)
        h.combine(node.scrollYMax)
        h.combine(node.textSelection)
        h.combine(node.characterCount)
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
    public static func dictionary(from node: AccessibilityNode, isRoot: Bool = true) -> [String: Any] {
        let resolvedRole = (node.isSecure && node.role == .textInput) ? ElementRole.passwordInput.rawValue : node.role.rawValue
        var dict: [String: Any] = [
            "key": node.id,
            "role": resolvedRole,
            "bounds": [
                round1(node.frame.x),
                round1(node.frame.y),
                round1(node.frame.width),
                round1(node.frame.height),
            ],
        ]
        if let name = resolvedName(for: node) {
            dict["name"] = name
        }
        // Static text nodes carry their content in `name` (`Role::Label`); never emit `value` for `.text` or secure fields (`dump.rs:51`).
        if node.role != .text && !node.isSecure, let val = node.value {
            dict["value"] = val
        }
        if let help = node.help, help != node.label { dict["description"] = help }
        if let placeholder = node.placeholder { dict["placeholder"] = placeholder }
        if let range = node.range {
            dict["range"] = [range.value, range.min, range.max, range.step as Any? ?? NSNull()]
        }
        if let heading = node.level { dict["level"] = heading + 1 }
        if let pos = node.positionInSet { dict["position"] = pos + 1 }
        if let size = node.sizeOfSet { dict["setSize"] = size }
        if let shortcut = node.keyboardShortcut { dict["shortcut"] = shortcut }
        if let url = node.url { dict["url"] = url }
        if let active = node.activeDescendant { dict["activeDescendant"] = active }
        if let sortAsc = node.sortAscending {
            dict["sort"] = sortAsc ? "ascending" : "descending"
        }

        var states: [String] = []
        if node.isFocused && !isRoot { states.append("focused") }
        if node.isDisabled { states.append("disabled") }
        if node.isReadOnly { states.append("read-only") }
        if node.isInvalid { states.append("invalid") }
        if node.isModal { states.append("modal") }
        if let toggled = node.toggled {
            switch toggled {
            case .trueState: states.append("checked")
            case .falseState: states.append("unchecked")
            case .mixed: states.append("mixed")
            }
        }
        if let exp = node.isExpanded { states.append(exp ? "expanded" : "collapsed") }
        if let sel = node.selectedState {
            states.append(sel ? "selected" : "unselected")
        } else if node.isSelected {
            states.append("selected")
        }
        if let live = node.liveRegion {
            states.append(live == .assertive ? "live-assertive" : "live-polite")
        }
        if node.clipsChildren { states.append("clips") }
        if !states.isEmpty { dict["states"] = states }

        if !node.actions.isEmpty { dict["actions"] = node.actions.map(\.rawValue) }
        if let sy = node.scrollY {
            dict["scroll"] = [round1(node.scrollX ?? 0), round1(sy), round1(node.scrollYMax ?? 0)]
        }
        if let sel = node.textSelection, sel.count == 4 {
            dict["selection"] = sel
        }
        if let chars = node.characterCount {
            dict["chars"] = chars
        }
        if !node.children.isEmpty {
            dict["children"] = node.children.map { dictionary(from: $0, isRoot: false) }
        }
        return dict
    }

    private static func resolvedName(for node: AccessibilityNode) -> String? {
        if let label = node.label { return label }
        if node.role == .text {
            return node.isSecure ? nil : node.value
        }
        if namedByContainerContent(node.role) {
            var parts: [String] = []
            collectDescendantLabels(in: node.children, out: &parts)
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        return nil
    }

    private static func namedByContainerContent(_ role: ElementRole) -> Bool {
        switch role {
        case .button, .checkbox, .link, .menuItem, .radio, .switchControl, .tab,
             .listItem, .option, .treeItem, .row, .gridCell, .columnHeader, .heading, .alert:
            return true
        default:
            return false
        }
    }

    private static func collectDescendantLabels(in children: [AccessibilityNode], out: inout [String]) {
        for child in children {
            switch child.role {
            case .text:
                if let text = child.isSecure ? nil : (child.label ?? child.value), !text.isEmpty {
                    out.append(text)
                }
            case .image, .icon:
                if let label = child.label, !label.isEmpty {
                    out.append(label)
                }
            case .group:
                collectDescendantLabels(in: child.children, out: &out)
            default:
                break
            }
        }
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
