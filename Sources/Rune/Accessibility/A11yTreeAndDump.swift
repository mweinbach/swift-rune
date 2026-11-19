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
    /// `announcement`: `Tx::announce`'s window live region (the root's announcer child), held back
    /// from a whole tree when said in the last moments (#980); see `needsFollowUp`.
    public func service(
        rootNode: AccessibilityNode?,
        windowTitle: String,
        announcement: AccessibilityAnnouncement? = nil,
        now: Double = AccessibilityAnnouncement.clock(),
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
        return treeState.diff(root: rootNode, windowTitle: windowTitle, announcement: announcement, now: now)
    }

    /// The last whole tree held the announcer's words back: the host must update again (the
    /// runtime stays dirty) so they go out as a change (`a11y_update`'s `self.dirty = true`).
    public var needsFollowUp: Bool { treeState.held }
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
    /// Authored IDs that left the tree, or the exact runtime path of a removed namesake.
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

/// Cache identity for a mounted node, or for an explicitly constructed tree without runtime paths.
internal enum AccessibilityIdentity: Hashable {
    case runtime(String)
    indirect case scoped(parent: Self?, id: String, occurrence: Int)

    init(_ node: AccessibilityNode, parent: Self?, occurrences: inout [String: Int]) {
        if let path = node.runtimePath {
            self = .runtime(path)
        } else {
            let occurrence = occurrences[node.id, default: 0]
            occurrences[node.id] = occurrence + 1
            self = .scoped(parent: parent, id: node.id, occurrence: occurrence)
        }
    }

    static func walk(_ root: AccessibilityNode, _ visit: (AccessibilityNode, Self) -> Void) {
        func walkNode(_ node: AccessibilityNode, parent: Self?, occurrences: inout [String: Int]) {
            let id = Self(node, parent: parent, occurrences: &occurrences)
            visit(node, id)
            var children: [String: Int] = [:]
            for child in node.children { walkNode(child, parent: id, occurrences: &children) }
        }
        var roots: [String: Int] = [:]
        walkNode(root, parent: nil, occurrences: &roots)
    }
}

/// Tracks previously emitted accessibility fingerprints so idle frames cost zero allocations (`A11yTree`).
public final class AccessibilityTreeState {
    /// `Tx::announce`'s live region, the root's last child (`a11y/tree.rs` `ANNOUNCER`).
    public static let announcerID = "__rune_announcer"

    private struct CachedNode {
        let id: String
        let fingerprint: UInt64
        let frame: MotionRect
    }
    private var previous: [AccessibilityIdentity: CachedNode] = [:]
    private var needsFullTree: Bool = true
    /// The last whole tree held back the announcer's words: an adapter raises no events for the
    /// tree it starts from, so words said as a reader attached (a request arriving as it starts)
    /// would never be spoken. The next update sends them as a change (#980).
    public private(set) var held: Bool = false
    public private(set) var lastChanges = AccessibilityChanges()

    public init() {}

    public func forceFullUpdate() {
        needsFullTree = true
    }

    public func reset() {
        previous.removeAll()
        needsFullTree = true
        held = false
        lastChanges = AccessibilityChanges()
    }

    /// The announcer node: always there, so its first words are a change a reader announces,
    /// not a node that appeared. `holdWords`: it goes without its words for now.
    public static func announcerNode(_ announcement: AccessibilityAnnouncement, holdWords: Bool) -> AccessibilityNode {
        var label: String? = nil
        if let words = announcement.words, !words.text.isEmpty, !holdWords { label = words.text }
        return AccessibilityNode(
            id: announcerID,
            role: .status,
            label: label,
            frame: MotionRect.fromXYWH(0, 0, 1, 1),
            liveRegion: announcement.politeness == .assertive ? .assertive : .polite
        )
    }

    public func diff(
        root: AccessibilityNode,
        windowTitle: String,
        announcement: AccessibilityAnnouncement? = nil,
        now: Double = AccessibilityAnnouncement.clock()
    ) -> AccessibilityTreeUpdate? {
        let full = needsFullTree
        // A whole tree with words said in the last moments: they go out without them now.
        let hold = full && (announcement?.recent(now: now) ?? false)
        // Held words go out with the root, whose node carries the announcer.
        let wasHeld = held
        var root = root
        if let announcement {
            root.children.append(Self.announcerNode(announcement, holdWords: hold))
        }

        var next: [AccessibilityIdentity: CachedNode] = [:]
        var updated: [AccessibilityNode] = []
        var structureChanged = full
        var moved = false
        AccessibilityIdentity.walk(root) { node, identity in
            let fp = fingerprint(node)
            let prior = previous[identity]
            let carriesHeldWords = wasHeld && (next.isEmpty || node.id == Self.announcerID)
            next[identity] = CachedNode(id: node.id, fingerprint: fp, frame: node.frame)
            if full || carriesHeldWords || prior?.fingerprint != fp {
                updated.append(node)
                if !full, let prior, prior.frame != node.frame { moved = true }
            }
            if prior == nil { structureChanged = true }
        }

        let missing = previous.filter { next[$0.key] == nil }
        var removed = Set<String>()
        if !missing.isEmpty {
            structureChanged = true
            let remaining = Set(next.values.map(\.id))
            let counts = Dictionary(previous.values.map { ($0.id, 1) }, uniquingKeysWith: +)
            for (identity, old) in missing {
                // A surviving namesake must remain addressable. A runtime node also has its
                // precise path; manually constructed trees expose the supplied IDs alone.
                if case .runtime(let path) = identity, remaining.contains(old.id) || counts[old.id, default: 0] > 1 {
                    removed.insert(path)
                } else if !remaining.contains(old.id) {
                    removed.insert(old.id)
                }
            }
        }

        previous = next
        needsFullTree = false
        held = hold
        lastChanges = AccessibilityChanges(structure: structureChanged, moved: moved)

        if !full && updated.isEmpty && missing.isEmpty {
            return nil
        }
        return AccessibilityTreeUpdate(
            windowTitle: windowTitle,
            isFullTree: full,
            updatedNodes: updated,
            removedIDs: removed.sorted(),
            changes: lastChanges
        )
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
        h.combine(node.activeDescendantKey)
        h.combine(node.sortAscending)
        h.combine(node.isDisabled)
        h.combine(node.isReadOnly)
        h.combine(node.isInvalid)
        h.combine(node.isBusy)
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
        for child in node.children { h.combine(child.runtimePath ?? child.id) }
        return UInt64(bitPattern: Int64(h.finalize()))
    }
}

// MARK: - 3. Nested Accessibility JSON Dump (`rune::a11y::dump`)

enum AccessibilityDumpField: String, CodingKey {
    case key, role, bounds, path, name, value, description, placeholder, actions, states, busy, focusable
    case range, level, position, setSize, shortcut, url, activeDescendant, sort, scroll, selection, chars
    case anchor, selectable, documentText, inlineStart, inlineEnd, pageScrollX, pageContentWidth, font
    case family, size, weight, lineHeight, tracking, italic, align
}

protocol AccessibilityDumpFields {
    associatedtype Failure: Error
    mutating func set(_ field: AccessibilityDumpField, _ value: String) throws(Failure)
    mutating func set(_ field: AccessibilityDumpField, _ value: Bool) throws(Failure)
    mutating func set(_ field: AccessibilityDumpField, _ value: Int) throws(Failure)
    mutating func set(_ field: AccessibilityDumpField, _ value: Float) throws(Failure)
    mutating func set(_ field: AccessibilityDumpField, _ value: [String]) throws(Failure)
    mutating func set(_ field: AccessibilityDumpField, _ value: [Double]) throws(Failure)
    mutating func set(_ field: AccessibilityDumpField, _ value: [Int]) throws(Failure)
    mutating func setRange(_ range: A11yRange) throws(Failure)
    mutating func setFont(_ font: WebDocumentAccessibilityNode.Font) throws(Failure)
}

private struct AccessibilityDictionaryFields: AccessibilityDumpFields {
    var values: [String: Any] = [:]

    mutating func set(_ field: AccessibilityDumpField, _ value: String) { values[field.rawValue] = value }
    mutating func set(_ field: AccessibilityDumpField, _ value: Bool) { values[field.rawValue] = value }
    mutating func set(_ field: AccessibilityDumpField, _ value: Int) { values[field.rawValue] = value }
    mutating func set(_ field: AccessibilityDumpField, _ value: Float) { values[field.rawValue] = value }
    mutating func set(_ field: AccessibilityDumpField, _ value: [String]) { values[field.rawValue] = value }
    mutating func set(_ field: AccessibilityDumpField, _ value: [Double]) { values[field.rawValue] = value }
    mutating func set(_ field: AccessibilityDumpField, _ value: [Int]) { values[field.rawValue] = value }

    mutating func setRange(_ range: A11yRange) {
        values["range"] = [range.value, range.min, range.max, range.step as Any? ?? NSNull()]
    }

    mutating func setFont(_ font: WebDocumentAccessibilityNode.Font) {
        var fields = Self()
        font.write(to: &fields)
        values["font"] = fields.values
    }
}

/// Nested JSON dump of a projected `AccessibilityNode` tree (`a11y/dump.rs`).
public enum AccessibilityDump {
    public static func dictionary(from node: AccessibilityNode, isRoot: Bool = true) -> [String: Any] {
        dictionary(from: node, isRoot: isRoot, forBrowser: false)
    }

    internal static func dictionary(
        from node: AccessibilityNode, isRoot: Bool, forBrowser: Bool, syntheticPath: String? = nil
    ) -> [String: Any] {
        var fields = AccessibilityDictionaryFields()
        fields.values["bounds"] = [
            round1(node.frame.x), round1(node.frame.y), round1(node.frame.width), round1(node.frame.height)
        ]
        writeShallow(node, isRoot: isRoot, forBrowser: forBrowser, syntheticPath: syntheticPath, to: &fields)
        if !node.children.isEmpty {
            fields.values["children"] = node.children.enumerated().map { index, child in
                // Terminal lines and other derived children can share author IDs in separate subtrees.
                let path = forBrowser && child.runtimePath == nil
                    ? "\(node.runtimePath ?? syntheticPath ?? node.id)#a11y-\(index)" : nil
                return dictionary(from: child, isRoot: false, forBrowser: forBrowser, syntheticPath: path)
            }
        }
        return fields.values
    }

    /// Write the shared native dump and browser patch schema to their concrete representations.
    static func writeShallow<Fields: AccessibilityDumpFields>(
        _ node: AccessibilityNode, isRoot: Bool, forBrowser: Bool, syntheticPath: String?, to fields: inout Fields
    ) throws(Fields.Failure) {
        let defaultRole = (node.isSecure && (node.role == .textInput || node.role == .searchbox)) ? ElementRole.passwordInput.rawValue : node.role.rawValue
        let resolvedRole = (forBrowser ? node.webDocument?.role : nil) ?? defaultRole
        try fields.set(.key, node.id)
        try fields.set(.role, resolvedRole)
        if let name = resolvedName(for: node) {
            try fields.set(.name, name)
        }
        if forBrowser {
            try node.webDocument?.write(to: &fields)
            try fields.set(.path, node.runtimePath ?? syntheticPath ?? node.id)
            if node.isBusy { try fields.set(.busy, true) }
            if node.isFocusable { try fields.set(.focusable, true) }
        }
        // Static text nodes carry their content in `name` (`Role::Label`); never emit `value` for `.text` or secure fields (`dump.rs:51`).
        if node.role != .text && !node.isSecure, let val = node.value {
            try fields.set(.value, val)
        }
        if let help = node.help, help != node.label { try fields.set(.description, help) }
        if let placeholder = node.placeholder { try fields.set(.placeholder, placeholder) }
        if let range = node.range {
            try fields.setRange(range)
        }
        if let heading = node.level { try fields.set(.level, heading + 1) }
        if let pos = node.positionInSet { try fields.set(.position, pos + 1) }
        if let size = node.sizeOfSet { try fields.set(.setSize, size) }
        if let shortcut = node.keyboardShortcut { try fields.set(.shortcut, shortcut) }
        if let url = node.url { try fields.set(.url, url) }
        if let active = node.activeDescendant { try fields.set(.activeDescendant, active) }
        if let sortAsc = node.sortAscending {
            try fields.set(.sort, sortAsc ? "ascending" : "descending")
        }

        var states: [String] = []
        if node.isFocused && (!isRoot || forBrowser) { states.append("focused") }
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
        if !states.isEmpty { try fields.set(.states, states) }

        if !node.actions.isEmpty { try fields.set(.actions, node.actions.map(\.rawValue)) }
        if let sy = node.scrollY {
            try fields.set(.scroll, [round1(node.scrollX ?? 0), round1(sy), round1(node.scrollYMax ?? 0)])
        }
        if let sel = node.textSelection, sel.count == 4 {
            try fields.set(.selection, sel)
        }
        if let chars = node.characterCount {
            try fields.set(.chars, chars)
        }
    }

    /// The computed accessible name shared by native providers and the JSON tree.
    internal static func resolvedName(for node: AccessibilityNode) -> String? {
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
        case .button, .checkbox, .link, .menuItem, .menuItemCheckbox, .menuItemRadio, .radio, .switchControl, .tab,
             .listItem, .option, .treeItem, .row, .gridCell, .cell, .rowHeader, .columnHeader, .heading, .alert, .status:
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
