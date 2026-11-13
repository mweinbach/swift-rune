import Foundation
import RuneMotion

/// Node metadata snapshot for resolving Cmd+A across `El.selectionGroup` subtrees
/// (`crates/rune/src/runtime/selection/select_all.rs`).
public struct SelectableNodeSnapshot: Sendable, Equatable {
    public var path: String
    public var key: String?
    public var parentPath: String?
    public var isSelectable: Bool
    public var isSelectionGroup: Bool
    public var isFocusedTextInput: Bool
    public var text: String
    public var rect: MotionRect
    public var uncopied: [Range<Int>]
    public var copyBreakBefore: UInt8
    public var copyBreakAfter: UInt8
    public var copyPrefix: String?

    public init(
        path: String,
        key: String? = nil,
        parentPath: String? = nil,
        isSelectable: Bool = false,
        isSelectionGroup: Bool = false,
        isFocusedTextInput: Bool = false,
        text: String = "",
        rect: MotionRect = .zero,
        uncopied: [Range<Int>] = [],
        copyBreakBefore: UInt8 = 1,
        copyBreakAfter: UInt8 = 1,
        copyPrefix: String? = nil
    ) {
        self.path = path
        self.key = key
        self.parentPath = parentPath
        self.isSelectable = isSelectable
        self.isSelectionGroup = isSelectionGroup
        self.isFocusedTextInput = isFocusedTextInput
        self.text = text
        self.rect = rect
        self.uncopied = uncopied
        self.copyBreakBefore = copyBreakBefore
        self.copyBreakAfter = copyBreakAfter
        self.copyPrefix = copyPrefix
    }
}

/// Remembers which `selectionGroup` was last interacted with so Cmd+A targets it even after
/// clicking blank space (`crates/rune/src/runtime/selection/select_all.rs`).
public struct SelectAllPick: Sendable, Equatable {
    public private(set) var lastGroupPath: String?

    public init(lastGroupPath: String? = nil) {
        self.lastGroupPath = lastGroupPath
    }

    public mutating func noteClick(groupPath: String?) {
        if let groupPath {
            lastGroupPath = groupPath
        }
    }

    public mutating func clear() {
        lastGroupPath = nil
    }
}

/// Outcome of Cmd+A `SelectAllResolver` (`crates/rune/src/runtime/select_all_tests.rs`).
public enum SelectAllOutcome: Sendable, Equatable {
    case handledByApp
    case handledByFocusedInput
    case selectGroup(groupPath: String, nodePaths: [String], joinedText: String)
    case none
}

/// Implements upstream's Cmd+A target selection rule (`crates/rune/src/runtime/selection/select_all.rs`):
/// 1. App `onKey` handler wins if it claims `Cmd+A`.
/// 2. A focused `textInput` keeps its own Select All.
/// 3. Otherwise choose the last clicked live `selectionGroup` if still mounted, or the window's
///    unique `selectionGroup` if only one exists; multiple groups with no prior click select nothing.
public enum SelectAllResolver {
    public static func groupPath(forNodeAt index: Int, in nodes: [SelectableNodeSnapshot]) -> String? {
        let byPath = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.path, $0.offset) })
        var cursor: Int? = nodes[index].parentPath.flatMap { byPath[$0] }
        while let idx = cursor {
            if nodes[idx].isSelectionGroup {
                return nodes[idx].path
            }
            cursor = nodes[idx].parentPath.flatMap { byPath[$0] }
        }
        return nil
    }

    public static func groupTexts(groupPath: String, in nodes: [SelectableNodeSnapshot]) -> [SelectableNodeSnapshot] {
        nodes.enumerated().compactMap { idx, node in
            guard node.isSelectable, Self.groupPath(forNodeAt: idx, in: nodes) == groupPath else { return nil }
            return node
        }
    }

    public static func resolve(
        nodes: [SelectableNodeSnapshot],
        pick: inout SelectAllPick,
        appHandledCmdA: Bool = false
    ) -> SelectAllOutcome {
        if appHandledCmdA {
            return .handledByApp
        }
        if nodes.contains(where: { $0.isFocusedTextInput }) {
            return .handledByFocusedInput
        }
        var liveUnits: [String] = []
        var seenUnits: Set<String> = []
        for idx in nodes.indices where nodes[idx].isSelectable {
            let unit = groupPath(forNodeAt: idx, in: nodes) ?? nodes[idx].path
            if seenUnits.insert(unit).inserted {
                liveUnits.append(unit)
            }
        }
        let chosenUnit: String?
        if let remembered = pick.lastGroupPath, liveUnits.contains(remembered) {
            chosenUnit = remembered
        } else {
            if liveUnits.count != 1 {
                if pick.lastGroupPath != nil && !liveUnits.contains(where: { $0 == pick.lastGroupPath }) {
                    pick.clear()
                }
                return .none
            }
            chosenUnit = liveUnits.first
        }
        guard let unit = chosenUnit else { return .none }
        let isGroup = nodes.contains { $0.path == unit && $0.isSelectionGroup }
        let texts: [SelectableNodeSnapshot] = isGroup
            ? groupTexts(groupPath: unit, in: nodes)
            : nodes.filter { $0.path == unit && $0.isSelectable }
        let entries: [CopyJoin.Entry] = texts.compactMap { node in
            let utf8Count = node.text.utf8.count
            guard utf8Count > 0 else { return nil }
            let slice = CopyJoin.copySlice(in: node.text, range: 0..<utf8Count, uncopied: node.uncopied)
            return CopyJoin.Entry(
                rect: node.rect,
                pieceText: slice,
                fromStart: true,
                copyBreakBefore: node.copyBreakBefore,
                copyBreakAfter: node.copyBreakAfter,
                copyPrefix: node.copyPrefix
            )
        }
        let joined = CopyJoin.join(entries)
        return .selectGroup(
            groupPath: unit,
            nodePaths: texts.map(\.path),
            joinedText: joined
        )
    }
}
