import Foundation
import RuneMotion
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Accessibility Tree Projection (`rune::a11y`)

/// Semantic action supported by an accessibility element.
public enum AccessibilityAction: String, Sendable, Hashable, Codable {
    case press
    case focus
    case increment
    case decrement
}

/// Live-region announcement politeness (`rune::LiveRegion`).
public enum LiveRegionPoliteness: String, Sendable, Hashable, Codable {
    case polite
    case assertive
}

/// Window-level accessibility announcement state (`rune::a11y::Announcement`).
public struct AccessibilityAnnouncement: Sendable, Equatable {
    public var text: String
    public var politeness: LiveRegionPoliteness
    public private(set) var count: UInt32 = 0

    public init(text: String = "", politeness: LiveRegionPoliteness = .polite) {
        self.text = text
        self.politeness = politeness
    }

    public mutating func say(_ text: String, politeness: LiveRegionPoliteness = .polite) {
        self.text = text
        self.politeness = politeness
        self.count &+= 1
    }

    /// Alternating zero-width space suffix ensures screen readers speak repeated identical messages.
    public var spokenText: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (count % 2 == 0) ? "\(text)\u{200B}" : text
    }
}

/// Platform-independent semantic accessibility node projected from a laid-out `El<State>`.
public struct AccessibilityNode: Sendable, Equatable {
    public var id: String
    public var role: ElementRole
    public var label: String?
    public var value: String?
    public var help: String?
    public var placeholder: String?
    public var range: A11yRange?
    public var frame: MotionRect
    public var isFocused: Bool
    public var isFocusable: Bool
    public var isSelected: Bool
    public var selectedState: Bool?
    public var isExpanded: Bool?
    public var level: Int?
    public var positionInSet: Int?
    public var sizeOfSet: Int?
    public var keyboardShortcut: String?
    public var url: String?
    public var activeDescendant: String?
    public var sortAscending: Bool?
    public var isDisabled: Bool
    public var isReadOnly: Bool
    public var isInvalid: Bool
    public var isBusy: Bool
    public var toggled: A11yChecked?
    public var liveRegion: LiveRegionPoliteness?
    public var clipsChildren: Bool
    public var scrollX: Float?
    public var scrollY: Float?
    public var scrollYMax: Float?
    public var textSelection: [Int]?
    public var characterCount: Int?
    public var characterLengths: [UInt8]?
    public var characterPositions: [Float]?
    public var characterWidths: [Float]?
    public var wordStarts: [UInt8]?
    public var isModal: Bool
    public var isSecure: Bool
    public var actions: [AccessibilityAction]
    public var children: [AccessibilityNode]

    public init(
        id: String,
        role: ElementRole,
        label: String? = nil,
        value: String? = nil,
        help: String? = nil,
        placeholder: String? = nil,
        range: A11yRange? = nil,
        frame: MotionRect = .zero,
        isFocused: Bool = false,
        isFocusable: Bool = false,
        isSelected: Bool = false,
        selectedState: Bool? = nil,
        isExpanded: Bool? = nil,
        level: Int? = nil,
        positionInSet: Int? = nil,
        sizeOfSet: Int? = nil,
        keyboardShortcut: String? = nil,
        url: String? = nil,
        activeDescendant: String? = nil,
        sortAscending: Bool? = nil,
        isDisabled: Bool = false,
        isReadOnly: Bool = false,
        isInvalid: Bool = false,
        isBusy: Bool = false,
        toggled: A11yChecked? = nil,
        liveRegion: LiveRegionPoliteness? = nil,
        clipsChildren: Bool = false,
        scrollX: Float? = nil,
        scrollY: Float? = nil,
        scrollYMax: Float? = nil,
        textSelection: [Int]? = nil,
        characterCount: Int? = nil,
        characterLengths: [UInt8]? = nil,
        characterPositions: [Float]? = nil,
        characterWidths: [Float]? = nil,
        wordStarts: [UInt8]? = nil,
        isModal: Bool = false,
        isSecure: Bool = false,
        actions: [AccessibilityAction] = [],
        children: [AccessibilityNode] = []
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
        self.help = help
        self.placeholder = placeholder
        self.range = range
        self.frame = frame
        self.isFocused = isFocused
        self.isFocusable = isFocusable
        self.isSelected = isSelected
        self.selectedState = selectedState
        self.isExpanded = isExpanded
        self.level = level
        self.positionInSet = positionInSet
        self.sizeOfSet = sizeOfSet
        self.keyboardShortcut = keyboardShortcut
        self.url = url
        self.activeDescendant = activeDescendant
        self.sortAscending = sortAscending
        self.isDisabled = isDisabled
        self.isReadOnly = isReadOnly
        self.isInvalid = isInvalid
        self.isBusy = isBusy
        self.toggled = toggled
        self.liveRegion = liveRegion
        self.clipsChildren = clipsChildren
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.scrollYMax = scrollYMax
        self.textSelection = textSelection
        self.characterCount = characterCount
        self.characterLengths = characterLengths
        self.characterPositions = characterPositions
        self.characterWidths = characterWidths
        self.wordStarts = wordStarts
        self.isModal = isModal
        self.isSecure = isSecure
        self.actions = actions
        self.children = children
    }
}

/// Projects a laid-out `El<State>` tree into a semantic `AccessibilityNode` tree.
public enum AccessibilityTreeBuilder {
    private static func collectA11yWords<State>(in node: El<State>, out: inout [String]) {
        guard !node.isSecure else { return }
        if let lbl = node.a11yLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !lbl.isEmpty {
            out.append(lbl)
            return
        }
        if node.handlers.editLens == nil,
           let txt = (node.plainText ?? node.richSpans?.map(\.text).joined())?.trimmingCharacters(in: .whitespacesAndNewlines),
           !txt.isEmpty {
            out.append(txt)
        }
        for child in node.children where !child.isA11yHidden && child.opacity > 0.01 && !child.isSecure {
            collectA11yWords(in: child, out: &out)
        }
    }

    private static func relatedWords<State>(key: String?, ancestors: [El<State>], selfKey: String?) -> String? {
        guard let key else { return nil }
        func findFirst(in scope: El<State>, isDirectTarget: Bool) -> El<State>? {
            for child in scope.children {
                if child.keyId == key {
                    // Exclude exact same node if it happens to have an empty or identical key
                    return child
                }
                if let hit = findFirst(in: child, isDirectTarget: false) {
                    return hit
                }
            }
            return nil
        }
        for scope in ancestors.reversed() {
            if let target = findFirst(in: scope, isDirectTarget: true) {
                var parts: [String] = []
                collectA11yWords(in: target, out: &parts)
                let joined = parts.joined(separator: " ")
                if !joined.isEmpty { return joined }
            }
        }
        return nil
    }

    public static func project<State>(
        element: El<State>,
        layout: LayoutEngine.ResultNode,
        state: State? = nil,
        origin: Vec2 = .zero,
        focusedKey: String? = nil,
        path: String = "root"
    ) -> AccessibilityNode? {
        projectNode(
            element: element,
            layout: layout,
            state: state,
            origin: origin,
            focusedKey: focusedKey,
            path: path,
            ancestors: []
        )
    }

    private static func projectNode<State>(
        element: El<State>,
        layout: LayoutEngine.ResultNode,
        state: State?,
        origin: Vec2,
        focusedKey: String?,
        path: String,
        ancestors: [El<State>]
    ) -> AccessibilityNode? {
        if element.isInert || element.isA11yHidden {
            return nil
        }

        let nodeId = element.keyId ?? path
        let absRect = MotionRect.fromXYWH(
            origin.x + layout.layout.localRect.x,
            origin.y + layout.layout.localRect.y,
            layout.layout.localRect.width,
            layout.layout.localRect.height
        )

        let enabled = !element.a11yDisabled && !element.isInert
        var actions: [AccessibilityAction] = []
        if enabled {
            if element.handlers.onClick != nil || element.handlers.onClickPress != nil {
                actions.append(.press)
            }
            if element.focusable {
                actions.append(.focus)
            }
            if element.role == .slider {
                actions.append(.increment)
                actions.append(.decrement)
            }
        }

        var value: String? = element.a11yValue ?? element.a11ySelected
        var isSecure = element.isSecure
        if let state, let editLens = element.handlers.editLens {
            let edit = editLens.get(state)
            isSecure = isSecure || edit.isSecure
            value = isSecure ? nil : edit.text
        }

        let resolvedRole: ElementRole = (isSecure && element.role == .textInput) ? .passwordInput : element.role
        let labelledByText = relatedWords(key: element.a11yLabelledBy, ancestors: ancestors, selfKey: element.keyId)
        let describedByText = relatedWords(key: element.a11yDescribedBy, ancestors: ancestors, selfKey: element.keyId)
        let label = isSecure
            ? (element.a11yLabel ?? labelledByText ?? "Password")
            : (element.a11yLabel ?? labelledByText ?? element.plainText)
        let resolvedHelp = element.a11yDescription ?? describedByText ?? element.a11yHelp
        let isFocused = (focusedKey != nil && element.keyId == focusedKey)
        let selectableRole = [.listItem, .option, .tab, .treeItem, .gridCell, .row].contains(resolvedRole)
        let selectedState: Bool? = (selectableRole || element.itemSelected) ? element.itemSelected : nil

        var projectedChildren: [AccessibilityNode] = []
        let childOrigin = Vec2(absRect.x, absRect.y)
        let childAncestors = ancestors + [element]
        let count = min(element.children.count, layout.children.count)
        for i in 0..<count {
            let childPath = "\(nodeId)/#\(i)"
            if let childNode = projectNode(
                element: element.children[i],
                layout: layout.children[i],
                state: state,
                origin: childOrigin,
                focusedKey: focusedKey,
                path: childPath,
                ancestors: childAncestors
            ) {
                projectedChildren.append(childNode)
            }
        }
        var projectedSelection: [Int]? = nil
        if let grid = element.terminalGridPayload {
            let projected = Self.projectTerminalGrid(grid, nodeId: nodeId, bounds: absRect)
            projectedChildren.append(contentsOf: projected.children)
            projectedSelection = projected.selection
        }

        return AccessibilityNode(
            id: nodeId,
            role: resolvedRole,
            label: label,
            value: value,
            help: resolvedHelp,
            placeholder: element.placeholder,
            range: element.a11yRange,
            frame: absRect,
            isFocused: isFocused,
            isFocusable: enabled && element.focusable,
            isSelected: element.itemSelected,
            selectedState: selectedState,
            isExpanded: element.a11yExpanded,
            level: element.a11yLevel.map { max(0, $0 - 1) },
            positionInSet: element.a11yPosInSet.map { max(0, $0.position - 1) },
            sizeOfSet: element.a11yPosInSet?.size,
            keyboardShortcut: element.a11yShortcutHint,
            url: element.a11yHref,
            activeDescendant: element.a11yActiveDescendant,
            sortAscending: element.a11ySorted,
            isDisabled: element.a11yDisabled,
            isReadOnly: element.a11yReadOnly,
            isInvalid: element.a11yInvalid,
            isBusy: element.a11yBusy,
            toggled: element.a11yChecked,
            liveRegion: element.a11yLive,
            clipsChildren: element.layout.clipOverflow,
            textSelection: projectedSelection,
            isModal: element.isModal,
            isSecure: isSecure,
            actions: actions,
            children: projectedChildren
        )
    }

    internal static func projectTerminalGrid(
        _ grid: TerminalGrid,
        nodeId: String,
        bounds: MotionRect
    ) -> (children: [AccessibilityNode], selection: [Int]?) {
        let cw = grid.cellSize.x
        let ch = grid.cellSize.y
        let shown = min(grid.rows.count, max(0, Int(ceil(Double(bounds.height / max(ch, 1.0))))))
        var children: [AccessibilityNode] = []
        children.reserveCapacity(shown)
        var selection: [Int]? = nil
        for k in 0..<shown {
            let row = grid.rows[k]
            let y = bounds.y + Float(k) * ch
            var (rowText, places) = row.readingText()
            let readCount = places.count
            let end = places.last.map { $0.column + max($0.width, 1) } ?? 0
            if !row.wraps && k + 1 < shown {
                rowText.append("\n")
                places.append((column: end, width: 0))
            }
            if row.wraps && end < grid.columns {
                rowText.append(String(repeating: " ", count: grid.columns - end))
                for col in end..<grid.columns {
                    places.append((column: col, width: 1))
                }
            }
            if let caret = grid.caret, caret.row == k {
                let charIdx = TerminalGridRow.charAt(
                    columnPlaces: Array(places.prefix(readCount)),
                    column: caret.column
                )
                selection = [k, charIdx, k, charIdx]
            }
            let chars = Array(rowText)
            let lengths: [UInt8] = chars.map { UInt8(clamping: String($0).utf8.count) }
            let positions: [Float] = places.map { Float($0.column) * cw }
            let widths: [Float] = places.map { Float($0.width) * cw }
            var starts: [UInt8] = []
            for idx in 0..<chars.count {
                let curWs = chars[idx].isWhitespace
                let prevWs = (idx == 0) || chars[idx - 1].isWhitespace
                if !curWs && prevWs {
                    starts.append(UInt8(min(idx, 255)))
                }
            }
            children.append(AccessibilityNode(
                id: "\(nodeId)/line:\(k)",
                role: .text,
                value: rowText,
                frame: MotionRect.fromXYWH(bounds.x, y, Float(grid.columns) * cw, ch),
                characterLengths: lengths,
                characterPositions: positions,
                characterWidths: widths,
                wordStarts: starts
            ))
        }
        return (children, selection)
    }
}

#if os(macOS)
/// Builds an AppKit `NSAccessibilityElement` hierarchy from a projected `AccessibilityNode`.
public enum AppKitAccessibilityMapper {
    public static func nsRole(for role: ElementRole) -> NSAccessibility.Role {
        switch role {
        case .group: return .group
        case .text: return .staticText
        case .button: return .button
        case .checkbox: return .checkBox
        case .switchControl: return .checkBox
        case .radio: return .radioButton
        case .tab: return .radioButton
        case .textInput, .passwordInput: return .textField
        case .slider: return .slider
        case .progress: return .progressIndicator
        case .listItem: return .row
        case .heading: return .staticText
        case .dialog: return .sheet
        case .menu: return .menu
        case .menuItem: return .menuItem
        case .image, .icon: return .image
        case .separator: return .splitter
        case .combobox: return .comboBox
        case .listbox: return .list
        case .option: return .menuItem
        case .tree: return .outline
        case .treeItem: return .row
        case .grid: return .table
        case .row: return .row
        case .gridCell: return .cell
        case .columnHeader: return .column
        case .radiogroup: return .radioGroup
        case .tabList: return .tabGroup
        case .tooltip: return .helpTag
        case .alert, .region, .main, .status, .blockquote: return .group
        case .link: return .link
        case .toolbar: return .toolbar
        case .splitter: return .splitter
        case .list: return .list
        case .menuItemCheckbox: return .menuItem
        case .mark, .code: return .staticText
        case .table: return .table
        }
    }

    @MainActor
    public static func buildElement(
        from node: AccessibilityNode,
        parent: AnyObject? = nil,
        onAction: (@Sendable (String, AccessibilityAction) -> Void)? = nil
    ) -> RuneNSAccessibilityElement {
        let el = RuneNSAccessibilityElement(node: node, parent: parent, onAction: onAction)
        let childEls = node.children.map {
            buildElement(from: $0, parent: el, onAction: onAction)
        }
        el.setAccessibilityChildren(childEls)
        return el
    }
}

/// Concrete `NSAccessibilityElement` backing a projected `AccessibilityNode` on macOS.
public final class RuneNSAccessibilityElement: NSAccessibilityElement {
    public let nodeId: String
    public let supportedActions: [AccessibilityAction]
    private let actionHandler: (@Sendable (String, AccessibilityAction) -> Void)?

    public init(
        node: AccessibilityNode,
        parent: AnyObject?,
        onAction: (@Sendable (String, AccessibilityAction) -> Void)?
    ) {
        self.nodeId = node.id
        self.supportedActions = node.actions
        self.actionHandler = onAction
        super.init()

        setAccessibilityRole(AppKitAccessibilityMapper.nsRole(for: node.role))
        if node.isSecure {
            setAccessibilitySubrole(.secureTextField)
        }
        if let parent {
            setAccessibilityParent(parent)
        }
        setAccessibilityIdentifier(node.id)
        if let label = node.label {
            setAccessibilityLabel(label)
        }
        if !node.isSecure, let value = node.value {
            setAccessibilityValue(value)
        }
        if let help = node.help {
            setAccessibilityHelp(help)
        }
        setAccessibilityFrame(CGRect(
            x: CGFloat(node.frame.x),
            y: CGFloat(node.frame.y),
            width: CGFloat(node.frame.width),
            height: CGFloat(node.frame.height)
        ))
        setAccessibilityFocused(node.isFocused)
        setAccessibilitySelected(node.isSelected)
        if let expanded = node.isExpanded {
            setAccessibilityExpanded(expanded)
        }
    }

    public override func accessibilityPerformPress() -> Bool {
        guard supportedActions.contains(.press) else { return false }
        actionHandler?(nodeId, .press)
        return true
    }

    public override func accessibilityPerformIncrement() -> Bool {
        guard supportedActions.contains(.increment) else { return false }
        actionHandler?(nodeId, .increment)
        return true
    }

    public override func accessibilityPerformDecrement() -> Bool {
        guard supportedActions.contains(.decrement) else { return false }
        actionHandler?(nodeId, .decrement)
        return true
    }
}
#elseif canImport(UIKit) && !os(watchOS)
/// Builds a UIKit `UIAccessibilityElement` hierarchy from a projected `AccessibilityNode`.
public enum UIKitAccessibilityMapper {
    public static func traits(for role: ElementRole) -> UIAccessibilityTraits {
        switch role {
        case .button, .menuItem, .menuItemCheckbox: return .button
        case .text, .listItem, .group, .dialog, .menu, .separator: return .staticText
        case .toolbar, .list, .textInput, .passwordInput: return .none
        case .splitter, .slider: return .adjustable
        case .status, .progress: return [.staticText, .updatesFrequently]
        case .heading: return .header
        case .image, .icon: return .image
        case .checkbox, .switchControl, .radio, .tab: return .button
        case .combobox, .option, .link: return .button
        case .listbox, .tree, .treeItem, .grid, .row, .gridCell, .columnHeader, .radiogroup, .tabList, .tooltip, .alert, .region, .main, .mark, .code, .blockquote, .table:
            return .staticText
        }
    }

    @MainActor
    public static func buildElements(
        from node: AccessibilityNode,
        container: Any,
        onAction: (@Sendable (String, AccessibilityAction) -> Void)? = nil
    ) -> [RuneUIAccessibilityElement] {
        var result: [RuneUIAccessibilityElement] = []
        let el = RuneUIAccessibilityElement(node: node, container: container, onAction: onAction)
        if node.role != .group {
            result.append(el)
        }
        for child in node.children {
            result.append(contentsOf: buildElements(from: child, container: container, onAction: onAction))
        }
        return result
    }
}

/// Concrete `UIAccessibilityElement` backing a projected `AccessibilityNode` on iOS/iPadOS/visionOS.
@MainActor
public final class RuneUIAccessibilityElement: UIAccessibilityElement {
    public let nodeId: String
    public let supportedActions: [AccessibilityAction]
    private let actionHandler: (@Sendable (String, AccessibilityAction) -> Void)?

    public init(
        node: AccessibilityNode,
        container: Any,
        onAction: (@Sendable (String, AccessibilityAction) -> Void)?
    ) {
        self.nodeId = node.id
        self.supportedActions = node.actions
        self.actionHandler = onAction
        super.init(accessibilityContainer: container)
        self.isAccessibilityElement = node.role != .group
        self.accessibilityIdentifier = node.id
        self.accessibilityLabel = node.label
        self.accessibilityValue = node.value
        self.accessibilityHint = node.help
        var traits = UIKitAccessibilityMapper.traits(for: node.role)
        if node.isSelected { traits.insert(.selected) }
        self.accessibilityTraits = traits
        self.accessibilityFrameInContainerSpace = CGRect(
            x: CGFloat(node.frame.x),
            y: CGFloat(node.frame.y),
            width: CGFloat(node.frame.width),
            height: CGFloat(node.frame.height)
        )
    }

    public override func accessibilityActivate() -> Bool {
        guard supportedActions.contains(.press) else { return false }
        actionHandler?(nodeId, .press)
        return true
    }

    public override func accessibilityIncrement() {
        guard supportedActions.contains(.increment) else { return }
        actionHandler?(nodeId, .increment)
    }

    public override func accessibilityDecrement() {
        guard supportedActions.contains(.decrement) else { return }
        actionHandler?(nodeId, .decrement)
    }
}
#endif

// MARK: - Spellcheck (`rune::spell`)

/// Spellcheck backend interface (`rune::spell::platform`).
public protocol SpellCheckBackend: Sendable {
    func misspelledUTF8Ranges(in text: String) -> [Range<Int>]
    func suggestions(for word: String) -> [String]
    func learnWord(_ word: String)
    func ignoreWord(_ word: String)
}

/// Deterministic in-memory spellcheck backend for headless tests and cross-platform fallback.
public final class CustomDictionarySpellChecker: SpellCheckBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var dictionary: Set<String>
    private var ignored: Set<String> = []

    public static let defaultWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "code", "color",
        "do", "does", "edit", "editor", "element", "file", "for", "from", "good", "grid",
        "hello", "help", "in", "input", "is", "it", "key", "layout", "line", "list",
        "macos", "menu", "message", "more", "new", "no", "not", "of", "on", "or", "quick",
        "read", "red", "right", "row", "rune", "run", "save", "search", "select", "set",
        "shortcut", "spell", "spellcheck", "swift", "test", "text", "the", "this", "to",
        "tree", "type", "ui", "undo", "user", "view", "virtual", "window", "with", "word",
        "world", "write", "yes", "you"
    ]

    public init(words: Set<String> = CustomDictionarySpellChecker.defaultWords) {
        self.dictionary = Set(words.map { $0.lowercased() })
    }

    public func misspelledUTF8Ranges(in text: String) -> [Range<Int>] {
        lock.lock()
        let dict = dictionary
        let ign = ignored
        lock.unlock()

        var ranges: [Range<Int>] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            if text[idx].isLetter {
                let start = idx
                while idx < text.endIndex && (text[idx].isLetter || text[idx] == "'") {
                    idx = text.index(after: idx)
                }
                let word = String(text[start..<idx]).lowercased()
                if !word.isEmpty && !dict.contains(word) && !ign.contains(word) {
                    let lo = text.utf8.distance(from: text.utf8.startIndex, to: start.samePosition(in: text.utf8)!)
                    let hi = text.utf8.distance(from: text.utf8.startIndex, to: idx.samePosition(in: text.utf8)!)
                    ranges.append(lo..<hi)
                }
            } else {
                idx = text.index(after: idx)
            }
        }
        return ranges
    }

    public func suggestions(for word: String) -> [String] {
        lock.lock()
        let dict = dictionary
        lock.unlock()

        let target = word.lowercased()
        if dict.contains(target) { return [] }
        let scored = dict.compactMap { candidate -> (String, Int)? in
            let d = Self.levenshtein(target, candidate)
            return d <= 2 ? (candidate, d) : nil
        }
        return scored
            .sorted { a, b in a.1 != b.1 ? a.1 < b.1 : a.0 < b.0 }
            .prefix(5)
            .map(\.0)
    }

    public func learnWord(_ word: String) {
        lock.lock()
        defer { lock.unlock() }
        dictionary.insert(word.lowercased())
    }

    public func ignoreWord(_ word: String) {
        lock.lock()
        defer { lock.unlock() }
        ignored.insert(word.lowercased())
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var prev = Array(0...bChars.count)
        for i in 1...aChars.count {
            var curr = Array(repeating: 0, count: bChars.count + 1)
            curr[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = curr
        }
        return prev[bChars.count]
    }
}

#if os(macOS)
/// AppKit `NSSpellChecker` backend on macOS (`rune::spell::macos`).
public final class MacOSSpellChecker: SpellCheckBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var ignored: Set<String> = []
    private let documentTag: Int

    public init() {
        self.documentTag = NSSpellChecker.uniqueSpellDocumentTag()
    }

    public func misspelledUTF8Ranges(in text: String) -> [Range<Int>] {
        guard !text.isEmpty else { return [] }
        let nsString = text as NSString
        let length = nsString.length
        var found: [Range<Int>] = []
        var start = 0

        lock.lock()
        let ign = ignored
        lock.unlock()

        let checker = NSSpellChecker.shared
        while start < length {
            let range = checker.checkSpelling(of: text, startingAt: start)
            if range.location == NSNotFound || range.length == 0 || range.location < start {
                break
            }
            let word = nsString.substring(with: range)
            if !ign.contains(word.lowercased()), let swiftRange = Range(range, in: text) {
                let lo = text.utf8.distance(from: text.utf8.startIndex, to: swiftRange.lowerBound.samePosition(in: text.utf8)!)
                let hi = text.utf8.distance(from: text.utf8.startIndex, to: swiftRange.upperBound.samePosition(in: text.utf8)!)
                found.append(lo..<hi)
            }
            start = range.location + range.length
        }
        return found
    }

    public func suggestions(for word: String) -> [String] {
        guard !word.isEmpty else { return [] }
        let range = NSRange(location: 0, length: (word as NSString).length)
        let guesses = NSSpellChecker.shared.guesses(
            forWordRange: range,
            in: word,
            language: nil,
            inSpellDocumentWithTag: documentTag
        ) ?? []
        return Array(guesses.prefix(5))
    }

    public func learnWord(_ word: String) {
        NSSpellChecker.shared.learnWord(word)
    }

    public func ignoreWord(_ word: String) {
        lock.lock()
        ignored.insert(word.lowercased())
        lock.unlock()
        NSSpellChecker.shared.ignoreWord(word, inSpellDocumentWithTag: documentTag)
    }
}
#elseif canImport(UIKit) && !os(watchOS)
/// UIKit `UITextChecker` backend on iOS/iPadOS/visionOS (`rune::spell::ios`).
public final class UIKitSpellChecker: SpellCheckBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var ignored: Set<String> = []
    private var learned: Set<String> = []

    public init() {}

    private static var defaultLanguage: String {
        Locale.current.language.languageCode?.identifier ?? "en_US"
    }

    private static func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(body)
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated(body)
        }
    }

    public func misspelledUTF8Ranges(in text: String) -> [Range<Int>] {
        guard !text.isEmpty else { return [] }
        let lang = Self.defaultLanguage

        lock.lock()
        let ign = ignored
        let lrn = learned
        lock.unlock()

        return Self.onMain {
            let nsString = text as NSString
            let length = nsString.length
            var found: [Range<Int>] = []
            var start = 0
            let checker = UITextChecker()
            while start < length {
                let range = checker.rangeOfMisspelledWord(
                    in: text,
                    range: NSRange(location: 0, length: length),
                    startingAt: start,
                    wrap: false,
                    language: lang
                )
                if range.location == NSNotFound || range.length == 0 || range.location < start {
                    break
                }
                let word = nsString.substring(with: range).lowercased()
                if !ign.contains(word), !lrn.contains(word), let swiftRange = Range(range, in: text) {
                    let lo = text.utf8.distance(from: text.utf8.startIndex, to: swiftRange.lowerBound.samePosition(in: text.utf8)!)
                    let hi = text.utf8.distance(from: text.utf8.startIndex, to: swiftRange.upperBound.samePosition(in: text.utf8)!)
                    found.append(lo..<hi)
                }
                start = range.location + range.length
            }
            return found
        }
    }

    public func suggestions(for word: String) -> [String] {
        guard !word.isEmpty else { return [] }
        let lang = Self.defaultLanguage
        return Self.onMain {
            let range = NSRange(location: 0, length: (word as NSString).length)
            let guesses = UITextChecker().guesses(
                forWordRange: range,
                in: word,
                language: lang
            ) ?? []
            return Array(guesses.prefix(5))
        }
    }

    public func learnWord(_ word: String) {
        lock.lock()
        learned.insert(word.lowercased())
        lock.unlock()
        Self.onMain {
            UITextChecker.learnWord(word)
        }
    }

    public func ignoreWord(_ word: String) {
        lock.lock()
        ignored.insert(word.lowercased())
        lock.unlock()
    }
}
#endif

/// Facade for spellchecking, language selection, and word learning (`rune::spell`).
public final class SpellChecker: @unchecked Sendable {
    #if os(macOS)
    public static let shared = SpellChecker(backend: MacOSSpellChecker())
    #elseif canImport(UIKit) && !os(watchOS)
    public static let shared = SpellChecker(backend: UIKitSpellChecker())
    #else
    public static let shared = SpellChecker(backend: CustomDictionarySpellChecker())
    #endif

    private static let dialects: [String: String] = [
        "ar-001": "Modern Standard Arabic",
        "de-AT": "Austrian German",
        "de-CH": "Swiss High German",
        "en-AU": "Australian English",
        "en-CA": "Canadian English",
        "en-GB": "British English",
        "en-US": "American English",
        "es-419": "Latin American Spanish",
        "es-ES": "European Spanish",
        "es-MX": "Mexican Spanish",
        "fa-AF": "Dari",
        "fr-CA": "Canadian French",
        "fr-CH": "Swiss French",
        "nl-BE": "Flemish",
        "pt-BR": "Brazilian Portuguese",
        "pt-PT": "European Portuguese",
        "ro-MD": "Moldovan Romanian",
        "sw-CD": "Congo Swahili",
        "zh-Hans": "Simplified Chinese",
        "zh-Hant": "Traditional Chinese"
    ]

    private let lock = NSLock()
    private var backend: any SpellCheckBackend
    private var chosenLanguages: [String] = []
    private var availableList: [String] = ["en-US", "en-GB", "de-DE", "fr-FR", "es-ES", "ja-JP", "zh-Hans"]
    private var wordCache: [String: Bool] = [:]
    private var generation: UInt64 = 0

    public static let maxSuggestions = 5

    public init(backend: any SpellCheckBackend) {
        self.backend = backend
    }

    public func setBackend(_ backend: any SpellCheckBackend) {
        lock.lock()
        defer { lock.unlock() }
        self.backend = backend
        self.wordCache.removeAll(keepingCapacity: true)
        self.generation &+= 1
    }

    public func setLanguages(_ tags: [String]) {
        lock.lock()
        defer { lock.unlock() }
        if chosenLanguages != tags {
            chosenLanguages = tags
            wordCache.removeAll(keepingCapacity: true)
            generation &+= 1
        }
    }

    public func setAvailableLanguages(_ tags: [String]) {
        lock.lock()
        defer { lock.unlock() }
        availableList = tags
        wordCache.removeAll(keepingCapacity: true)
        generation &+= 1
    }

    /// Available system spellcheck language tags (`rune::spell::available_languages`).
    public func availableLanguages() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return availableList
    }

    /// Active spellcheck languages (`chosen ∩ available`, else locale defaults + `en-US`) (`rune::spell::languages`).
    public func languages() -> [String] {
        lock.lock()
        let chosen = chosenLanguages
        let available = availableList
        lock.unlock()
        if !chosen.isEmpty {
            let intersection = chosen.filter { c in
                available.contains { $0.caseInsensitiveCompare(c) == .orderedSame }
            }
            if !intersection.isEmpty {
                return intersection
            }
        }
        var defaults: [String] = []
        for pref in Locale.preferredLanguages {
            if let match = available.first(where: { $0.caseInsensitiveCompare(pref) == .orderedSame })
                ?? available.first(where: { $0.lowercased().split(separator: "-").first == pref.lowercased().split(separator: "-").first }) {
                if !defaults.contains(match) {
                    defaults.append(match)
                }
            }
        }
        if !defaults.contains(where: { $0.lowercased().hasPrefix("en") }) {
            defaults.append("en-US")
        }
        return defaults
    }

    public func languageName(for tag: String) -> String {
        for (k, v) in Self.dialects where k.caseInsensitiveCompare(tag) == .orderedSame {
            return v
        }
        return tag
    }

    public func misspelledUTF8Ranges(in text: String) -> [Range<Int>] {
        lock.lock()
        let b = backend
        lock.unlock()
        return b.misspelledUTF8Ranges(in: text)
    }

    public func suggestions(for word: String) -> [String] {
        lock.lock()
        let b = backend
        lock.unlock()
        return b.suggestions(for: word)
    }

    public func learnWord(_ word: String) {
        lock.lock()
        let b = backend
        lock.unlock()
        b.learnWord(word)
    }

    public func ignoreWord(_ word: String) {
        lock.lock()
        let b = backend
        lock.unlock()
        b.ignoreWord(word)
    }
}

// MARK: - Shortcuts, Chords & Global/Scoped Registry (`rune::shortcuts`)

/// Scope in which a shortcut registration is active.
public enum ShortcutScope: Sendable, Hashable {
    case global
    case window(String)
    case context(String)
}

/// A sequence of one or more `Chord`s (e.g. `Cmd+K` then `Cmd+S`).
public struct ShortcutSequence: Sendable, Hashable {
    public var chords: [Chord]

    public init(_ chords: [Chord]) {
        self.chords = chords
    }

    public init?(parsing spec: String) {
        let parts = spec
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        var parsed: [Chord] = []
        for part in parts {
            guard let chord = Chord(parsing: part) else { return nil }
            parsed.append(chord)
        }
        self.chords = parsed
    }

    /// Parses a single accelerator with explicit `KeyPlatform` resolution (`shortcuts/parse.rs:29`).
    public static func parseOn(_ input: String, platform: KeyPlatform) throws -> ParsedShortcut {
        try ParsedShortcut.parseOn(input, platform: platform)
    }

    /// Formats a chord in compact macOS symbol style (`⌘⇧P`) or cross-platform style (`Ctrl+Shift+P`).
    public static func formatDisplay(_ chord: Chord, macOSSymbols: Bool = true) -> String {
        if macOSSymbols {
            var prefix = ""
            if chord.mods.ctrl { prefix += "⌃" }
            if chord.mods.alt { prefix += "⌥" }
            if chord.mods.shift { prefix += "⇧" }
            if chord.mods.cmd || chord.mods.logo { prefix += "⌘" }
            return prefix + keyDisplay(chord.key, mods: chord.mods, macOSSymbols: true)
        }
        return chord.description
    }

    public static func formatDisplay(_ sequence: ShortcutSequence, macOSSymbols: Bool = true) -> String {
        sequence.chords
            .map { formatDisplay($0, macOSSymbols: macOSSymbols) }
            .joined(separator: " ")
    }

    private static func keyDisplay(_ key: Key, mods: Mods, macOSSymbols: Bool) -> String {
        switch key {
        case .command(let ch):
            if macOSSymbols, KeyPlatform.current.isMac,
               let name = MacOSCarbonKeyMap.carbonKeyName(for: .char(ch)),
               let lbl = MacOSCarbonKeyMap.displayLabel(for: name, modifiers: MacOSCarbonKeyMap.carbonModifiers(for: mods)) {
                return lbl.uppercased()
            }
            return String(ch).uppercased()
        case .text(let s):
            if macOSSymbols, KeyPlatform.current.isMac, s.count == 1, let ch = s.first,
               let name = MacOSCarbonKeyMap.carbonKeyName(for: .char(ch)),
               let lbl = MacOSCarbonKeyMap.displayLabel(for: name, modifiers: MacOSCarbonKeyMap.carbonModifiers(for: mods)) {
                return lbl.uppercased()
            }
            return s.uppercased()
        case .enter: return macOSSymbols ? "↩" : "Enter"
        case .tab: return macOSSymbols ? "⇥" : "Tab"
        case .escape: return macOSSymbols ? "⎋" : "Esc"
        case .backspace: return macOSSymbols ? "⌫" : "Backspace"
        case .delete: return macOSSymbols ? "⌦" : "Delete"
        case .insert: return "Insert"
        case .space: return macOSSymbols ? "Space" : "Space"
        case .arrowLeft: return macOSSymbols ? "←" : "Left"
        case .arrowRight: return macOSSymbols ? "→" : "Right"
        case .arrowUp: return macOSSymbols ? "↑" : "Up"
        case .arrowDown: return macOSSymbols ? "↓" : "Down"
        case .home: return macOSSymbols ? "↖" : "Home"
        case .end: return macOSSymbols ? "↘" : "End"
        case .pageUp: return macOSSymbols ? "⇞" : "PageUp"
        case .pageDown: return macOSSymbols ? "⇟" : "PageDown"
        case .f(let n): return "F\(n)"
        case .contextMenu: return "Menu"
        case .printScreen: return "Print Screen"
        case .scrollLock: return "Scroll Lock"
        case .pause: return "Pause"
        case .modifier: return ""
        }
    }
}

/// Shortcut registration errors (`rune::shortcuts::ShortcutError`).
public enum ShortcutError: Error, Sendable, Equatable {
    case conflict(existingId: String)
    case invalidAccelerator(String)
    case unknownId(String)
    case unmodifiedDisallowed
    case alreadyInUse(owner: String?)
    case rejectedByOS(String)
    case unsupported
    case permissionDenied
    case notRunning
}

/// Outcome of dispatching a `KeyEvent` through `ShortcutRegistry`.
public enum ShortcutDispatchResult: Sendable, Equatable {
    case handled(id: String)
    case pendingChord
    case unhandled
}

/// Global and scoped shortcut registry with chord-sequence support, conflict detection, and display formatting.
public final class ShortcutRegistry: @unchecked Sendable {
    public struct Entry: Sendable {
        public let id: String
        public let sequence: ShortcutSequence
        public let scope: ShortcutScope
        public let label: String
        public let handler: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var pendingEvents: [KeyEvent] = []
    public var allowUnmodifiedGlobal: Bool = false

    public init() {}

    @discardableResult
    public func register(
        id: String,
        accelerator: String,
        scope: ShortcutScope = .global,
        label: String = "",
        allowUnmodified: Bool = false,
        handler: @escaping @Sendable () -> Void
    ) -> Result<String, ShortcutError> {
        guard let sequence = ShortcutSequence(parsing: accelerator) else {
            return .failure(.invalidAccelerator(accelerator))
        }

        lock.lock()
        defer { lock.unlock() }

        if scope == .global && !allowUnmodified && !allowUnmodifiedGlobal {
            if let first = sequence.chords.first, !Self.isModifiedOrFunction(first) {
                return .failure(.unmodifiedDisallowed)
            }
        }

        if let conflict = entries.first(where: { $0.scope == scope && $0.sequence == sequence }) {
            return .failure(.conflict(existingId: conflict.id))
        }

        entries.append(Entry(
            id: id,
            sequence: sequence,
            scope: scope,
            label: label.isEmpty ? id : label,
            handler: handler
        ))
        return .success(id)
    }

    @discardableResult
    public func unregister(id: String) -> Result<Void, ShortcutError> {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = entries.firstIndex(where: { $0.id == id }) else {
            return .failure(.unknownId(id))
        }
        entries.remove(at: idx)
        return .success(())
    }

    public func registeredEntries(in scope: ShortcutScope? = nil) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        if let scope {
            return entries.filter { $0.scope == scope }
        }
        return entries
    }

    public func resetPendingSequence() {
        lock.lock()
        defer { lock.unlock() }
        pendingEvents.removeAll()
    }

    /// Dispatches `event` against active scopes (in priority order), advancing or completing multi-chord sequences.
    public func dispatch(
        _ event: KeyEvent,
        activeScopes: [ShortcutScope] = [.global]
    ) -> ShortcutDispatchResult {
        // Standalone modifier key press/release never advances or cancels a multi-chord sequence.
        if case .modifier = event.key {
            return .unhandled
        }

        lock.lock()
        let candidateEvents = pendingEvents + [event]

        var matchedEntry: Entry? = nil
        var hasPrefixMatch = false

        for scope in activeScopes {
            for entry in entries where entry.scope == scope {
                let target = entry.sequence.chords
                if target.count == candidateEvents.count &&
                    zip(target, candidateEvents).allSatisfy({ $0.matches($1) }) {
                    matchedEntry = entry
                    break
                }
                if target.count > candidateEvents.count &&
                    zip(target.prefix(candidateEvents.count), candidateEvents).allSatisfy({ $0.matches($1) }) {
                    hasPrefixMatch = true
                }
            }
            if matchedEntry != nil { break }
        }

        if let matched = matchedEntry {
            pendingEvents.removeAll()
            lock.unlock()
            matched.handler()
            return .handled(id: matched.id)
        }

        if hasPrefixMatch {
            pendingEvents = candidateEvents
            lock.unlock()
            return .pendingChord
        }

        pendingEvents.removeAll()
        lock.unlock()
        return .unhandled
    }

    private static func isModifiedOrFunction(_ chord: Chord) -> Bool {
        if chord.mods.cmd || chord.mods.ctrl || chord.mods.alt || chord.mods.logo {
            return true
        }
        if case .f = chord.key {
            return true
        }
        return false
    }
}

// MARK: - Shortcut::parse_on & Bindings State Machine (crates/rune/src/shortcuts/parse.rs, service/machine.rs)

/// Validated, layout-independent global accelerator (`rune::shortcuts::Shortcut`, `parse.rs:17`).
public struct ParsedShortcut: Sendable, Hashable, CustomStringConvertible {
    public static let ctrlBit: UInt8 = 1
    public static let altBit: UInt8 = 2
    public static let shiftBit: UInt8 = 4
    public static let superBit: UInt8 = 8
    private static let primaryNameBit: UInt8 = 16

    public var mods: UInt8
    public var keyName: String

    public init(mods: UInt8, keyName: String) {
        self.mods = mods
        self.keyName = keyName
    }

    private func modifierKeycaps(on platform: KeyPlatform) -> [String] {
        var out: [String] = []
        if (mods & Self.ctrlBit) != 0 { out.append(platform.isMac ? "⌃" : "Ctrl") }
        if (mods & Self.altBit) != 0 { out.append(platform.isMac ? "⌥" : "Alt") }
        if (mods & Self.shiftBit) != 0 { out.append(platform.isMac ? "⇧" : "Shift") }
        if (mods & Self.superBit) != 0 {
            switch platform {
            case .mac: out.append("⌘")
            case .windows: out.append("Win")
            case .linux: out.append("Super")
            }
        }
        return out
    }

    private static func usOrNamedKeycap(_ name: String, platform: KeyPlatform) -> String {
        let mac = platform.isMac
        switch name {
        case "escape": return mac ? "⎋" : "Esc"
        case "enter": return mac ? "↩" : "Return"
        case "space": return "Space"
        case "tab": return mac ? "⇥" : "Tab"
        case "backspace": return mac ? "⌫" : "Backspace"
        case "delete": return mac ? "⌦" : "Delete"
        case "insert": return "Insert"
        case "home": return mac ? "↖" : "Home"
        case "end": return mac ? "↘" : "End"
        case "pageup": return mac ? "⇞" : "Page Up"
        case "pagedown": return mac ? "⇟" : "Page Down"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case "minus": return "-"
        case "equal": return "="
        case "comma": return ","
        case "period": return "."
        case "slash": return "/"
        case "semicolon": return ";"
        case "quote": return "'"
        case "bracketleft": return "["
        case "bracketright": return "]"
        case "backslash": return "\\"
        case "backquote": return "`"
        default: return name.uppercased()
        }
    }

    private var carbonLayoutMods: UInt32 {
        var mask: UInt32 = 0
        if (mods & Self.superBit) != 0 { mask |= MacOSKeyboardLayout.cmdKeyMask }
        if (mods & Self.ctrlBit) != 0 { mask |= MacOSKeyboardLayout.controlKeyMask }
        return mask
    }

    /// Physical-position keycaps using the active macOS keyboard layout (`shortcuts/keys.rs:77`).
    public func keycaps(on platform: KeyPlatform = .current) -> [String] {
        var labels = modifierKeycaps(on: platform)
        let namedKeys: Set<String> = [
            "escape", "enter", "space", "tab", "backspace", "delete", "insert",
            "home", "end", "pageup", "pagedown", "left", "right", "up", "down"
        ]
        if namedKeys.contains(keyName) || keyName.hasPrefix("f") && Int(keyName.dropFirst()) != nil {
            labels.append(Self.usOrNamedKeycap(keyName, platform: platform))
            return labels
        }
        if platform.isMac,
           let label = MacOSCarbonKeyMap.displayLabel(for: keyName, modifiers: carbonLayoutMods) {
            labels.append(label.uppercased())
        } else {
            labels.append(Self.usOrNamedKeycap(keyName, platform: platform))
        }
        return labels
    }

    /// Menu-style keycaps using the character/accelerator name on every layout (`shortcuts/keys.rs:88`).
    public func menuKeycaps(on platform: KeyPlatform = .current) -> [String] {
        var labels = modifierKeycaps(on: platform)
        labels.append(Self.usOrNamedKeycap(keyName, platform: platform))
        return labels
    }

    public var description: String {
        var out = ""
        for (bit, name) in [
            (Self.ctrlBit, "ctrl"),
            (Self.altBit, "alt"),
            (Self.shiftBit, "shift"),
            (Self.superBit, "super"),
        ] {
            if (mods & bit) != 0 {
                out += name + "+"
            }
        }
        out += keyName
        return out
    }

    /// Whether this shortcut carries Ctrl/Alt/Super or is a function key (`f1`–`f24`).
    public var hasBindingModifier: Bool {
        if (mods & (Self.ctrlBit | Self.altBit | Self.superBit)) != 0 { return true }
        guard keyName.hasPrefix("f"), keyName.count > 1, let num = Int(keyName.dropFirst()) else {
            return false
        }
        return (1...24).contains(num)
    }

    /// Parses an accelerator resolving `"mod"`/`"primary"` for `platform` (`parse.rs:29`).
    public static func parseOn(_ input: String, platform: KeyPlatform = .current) throws -> ParsedShortcut {
        var mods: UInt8 = 0
        var named: UInt8 = 0
        var key: String? = nil

        for rawPart in input.split(separator: "+", omittingEmptySubsequences: false) {
            let part = rawPart.trimmingCharacters(in: .whitespaces).lowercased()
            let (nameBit, modBit): (UInt8, UInt8)
            switch part {
            case "ctrl", "control":
                (nameBit, modBit) = (ctrlBit, ctrlBit)
            case "alt", "option", "opt":
                (nameBit, modBit) = (altBit, altBit)
            case "shift":
                (nameBit, modBit) = (shiftBit, shiftBit)
            case "cmd", "command", "super", "meta", "logo", "win":
                (nameBit, modBit) = (superBit, superBit)
            case "mod", "primary":
                (nameBit, modBit) = (primaryNameBit, platform == .mac ? superBit : ctrlBit)
            default:
                (nameBit, modBit) = (0, 0)
            }

            if modBit != 0 {
                if key != nil || (named & nameBit) != 0 {
                    throw ShortcutError.invalidAccelerator(input)
                }
                named |= nameBit
                mods |= modBit
            } else {
                if key != nil {
                    throw ShortcutError.invalidAccelerator(input)
                }
                let normalized = normalizeKeyName(part)
                guard isKnownPhysicalKeyName(normalized) else {
                    throw ShortcutError.invalidAccelerator(input)
                }
                key = normalized
            }
        }

        guard let resolvedKey = key else {
            throw ShortcutError.invalidAccelerator(input)
        }
        return ParsedShortcut(mods: mods, keyName: resolvedKey)
    }

    private static func normalizeKeyName(_ part: String) -> String {
        switch part {
        case "esc": return "escape"
        case "return", "numpadenter": return "enter"
        case "spacebar": return "space"
        case "arrowleft": return "left"
        case "arrowright": return "right"
        case "arrowup": return "up"
        case "arrowdown": return "down"
        case "del": return "delete"
        case "ins": return "insert"
        case "pgup": return "pageup"
        case "pgdn": return "pagedown"
        case "-": return "minus"
        case "=", "plus": return "equal"
        case ",": return "comma"
        case ".": return "period"
        case "/": return "slash"
        case ";": return "semicolon"
        case "'": return "quote"
        case "[": return "bracketleft"
        case "]": return "bracketright"
        case "\\": return "backslash"
        case "`": return "backquote"
        default:
            if part.hasPrefix("key"), part.count == 4, let c = part.last, c.isASCII, c.isLowercase {
                return String(c)
            }
            if part.hasPrefix("digit"), part.count == 6, let c = part.last, c.isASCII, c.isNumber {
                return String(c)
            }
            return part
        }
    }

    private static let physicalKeyPairs: [(PhysicalKeyCode, String)] = [
        (.keyA, "a"), (.keyB, "b"), (.keyC, "c"), (.keyD, "d"), (.keyE, "e"), (.keyF, "f"), (.keyG, "g"), (.keyH, "h"),
        (.keyI, "i"), (.keyJ, "j"), (.keyK, "k"), (.keyL, "l"), (.keyM, "m"), (.keyN, "n"), (.keyO, "o"), (.keyP, "p"),
        (.keyQ, "q"), (.keyR, "r"), (.keyS, "s"), (.keyT, "t"), (.keyU, "u"), (.keyV, "v"), (.keyW, "w"), (.keyX, "x"),
        (.keyY, "y"), (.keyZ, "z"),
        (.digit0, "0"), (.digit1, "1"), (.digit2, "2"), (.digit3, "3"), (.digit4, "4"),
        (.digit5, "5"), (.digit6, "6"), (.digit7, "7"), (.digit8, "8"), (.digit9, "9"),
        (.f1, "f1"), (.f2, "f2"), (.f3, "f3"), (.f4, "f4"), (.f5, "f5"), (.f6, "f6"), (.f7, "f7"), (.f8, "f8"),
        (.f9, "f9"), (.f10, "f10"), (.f11, "f11"), (.f12, "f12"), (.f13, "f13"), (.f14, "f14"), (.f15, "f15"), (.f16, "f16"),
        (.f17, "f17"), (.f18, "f18"), (.f19, "f19"), (.f20, "f20"), (.f21, "f21"), (.f22, "f22"), (.f23, "f23"), (.f24, "f24"),
        (.escape, "escape"), (.enter, "enter"), (.space, "space"), (.tab, "tab"), (.backspace, "backspace"), (.delete, "delete"), (.insert, "insert"),
        (.home, "home"), (.end, "end"), (.pageUp, "pageup"), (.pageDown, "pagedown"),
        (.arrowLeft, "left"), (.arrowRight, "right"), (.arrowUp, "up"), (.arrowDown, "down"),
        (.minus, "minus"), (.equal, "equal"), (.comma, "comma"), (.period, "period"), (.slash, "slash"),
        (.semicolon, "semicolon"), (.quote, "quote"), (.bracketLeft, "bracketleft"), (.bracketRight, "bracketright"),
        (.backslash, "backslash"), (.backquote, "backquote"),
    ]

    private static let physicalKeyByName: [String: PhysicalKeyCode] = Dictionary(
        uniqueKeysWithValues: physicalKeyPairs.map { ($0.1, $0.0) }
    )
    private static let nameByPhysicalKey: [PhysicalKeyCode: String] = Dictionary(
        uniqueKeysWithValues: physicalKeyPairs.map { ($0.0, $0.1) }
    )

    /// Builds a shortcut from a hardware key code and modifier flags (`shortcuts/keys.rs:28`).
    public static func fromPhysicalKey(
        _ key: PhysicalKeyCode,
        mods: Mods = .none,
        platform: KeyPlatform = .current
    ) throws -> ParsedShortcut {
        guard let name = nameByPhysicalKey[key] else {
            throw ShortcutError.invalidAccelerator("\(key)")
        }
        var bits: UInt8 = 0
        if mods.ctrl || (!platform.isMac && mods.cmd) { bits |= ctrlBit }
        if mods.alt { bits |= altBit }
        if mods.shift { bits |= shiftBit }
        if mods.logo || (platform.isMac && mods.cmd) { bits |= superBit }
        return ParsedShortcut(mods: bits, keyName: name)
    }

    /// The physical hardware key corresponding to this shortcut (`shortcuts/keys.rs:38`).
    public var physicalKey: PhysicalKeyCode? {
        Self.physicalKeyByName[keyName]
    }

    /// Modifiers represented as logical `Mods` (`shortcuts/keys.rs:50`).
    public func modifiers(on platform: KeyPlatform = .current) -> Mods {
        Mods(
            shift: (mods & Self.shiftBit) != 0,
            ctrl: (mods & Self.ctrlBit) != 0,
            alt: (mods & Self.altBit) != 0,
            cmd: (mods & (platform.isMac ? Self.superBit : Self.ctrlBit)) != 0,
            logo: (mods & Self.superBit) != 0
        )
    }

    /// Refuses bare shortcuts without ⌘/⌃/⌥ (or Ctrl/Alt/Super) unless F1–F24 (`shortcuts/keys.rs:43`).
    public func requireModifier(on platform: KeyPlatform = .current) throws {
        let isFunction = keyName.hasPrefix("f") && keyName.count > 1 && Int(keyName.dropFirst()) != nil
        if isFunction || (mods & (Self.ctrlBit | Self.altBit | Self.superBit)) != 0 {
            return
        }
        let names = platform.isMac ? "⌘, ⌃ or ⌥" : "Ctrl, Alt or Super"
        throw ShortcutError.invalidAccelerator("\(self) needs \(names)")
    }

    private static func isKnownPhysicalKeyName(_ name: String) -> Bool {
        physicalKeyByName[name] != nil
    }
}

public protocol ShortcutBackendDriver: AnyObject {
    func register(id: UInt32, shortcut: ParsedShortcut) -> Result<Void, ShortcutError>
    func unregister(id: UInt32) -> Result<Void, ShortcutError>
}

public enum ShortcutBindingsState<Backend> {
    case virtual([UInt32: ParsedShortcut])
    case disconnected
    case connected(native: Backend, registrations: [UInt32: ParsedShortcut])

    public func find(_ shortcut: ParsedShortcut) -> UInt32? {
        switch self {
        case .virtual(let regs), .connected(_, let regs):
            return regs.first(where: { $0.value == shortcut })?.key
        case .disconnected:
            return nil
        }
    }
}

public enum ShortcutBindEvent<Backend> {
    case register(id: UInt32, shortcut: ParsedShortcut, claimed: Bool)
    case opened(native: Backend, id: UInt32, shortcut: ParsedShortcut)
    case bound(id: UInt32, shortcut: ParsedShortcut)
    case rejected(ShortcutError)
    case unregister(UInt32)
    case unbound(UInt32)
    case release
}

public enum ShortcutBindEffect<Backend> {
    case refuse(ShortcutError)
    case connect(id: UInt32, shortcut: ParsedShortcut)
    case bind(id: UInt32, shortcut: ParsedShortcut)
    case unbind(UInt32)
    case claim(id: UInt32, shortcut: ParsedShortcut)
    case disclaim(UInt32)
    case disclaimAll([UInt32: ParsedShortcut])
    case disconnect(Backend)
}

/// Pure shortcut-bindings state machine (`shortcuts/service/machine.rs:133`).
public func stepShortcutBindings<Backend>(
    _ state: inout ShortcutBindingsState<Backend>,
    event: ShortcutBindEvent<Backend>
) -> [ShortcutBindEffect<Backend>] {
    switch event {
    case .register(let id, let shortcut, let claimed):
        switch state {
        case .virtual(var regs):
            if regs.values.contains(shortcut) {
                return [.refuse(.alreadyInUse(owner: nil))]
            }
            regs[id] = shortcut
            state = .virtual(regs)
            return []
        case .disconnected:
            if claimed {
                return [.refuse(.alreadyInUse(owner: nil))]
            }
            return [.connect(id: id, shortcut: shortcut)]
        case .connected(let native, let regs):
            if claimed || regs.values.contains(shortcut) {
                return [.refuse(.alreadyInUse(owner: nil))]
            }
            _ = native
            return [.bind(id: id, shortcut: shortcut)]
        }

    case .opened(let native, let id, let shortcut):
        state = .connected(native: native, registrations: [:])
        return [.bind(id: id, shortcut: shortcut)]

    case .bound(let id, let shortcut):
        guard case .connected(let native, var regs) = state else { return [] }
        regs[id] = shortcut
        state = .connected(native: native, registrations: regs)
        return [.claim(id: id, shortcut: shortcut)]

    case .rejected(let error):
        var out: [ShortcutBindEffect<Backend>] = []
        if let disc = disconnectBindingsIfEmpty(&state) {
            out.append(disc)
        }
        out.append(.refuse(error))
        return out

    case .unregister(let id):
        switch state {
        case .virtual(var regs):
            if regs.removeValue(forKey: id) != nil {
                state = .virtual(regs)
                return []
            }
            return [.refuse(.unknownId("\(id)"))]
        case .connected(_, let regs) where regs[id] != nil:
            return [.unbind(id)]
        default:
            return [.refuse(.unknownId("\(id)"))]
        }

    case .unbound(let id):
        guard case .connected(let native, var regs) = state else { return [] }
        regs.removeValue(forKey: id)
        state = .connected(native: native, registrations: regs)
        var out: [ShortcutBindEffect<Backend>] = []
        if let disc = disconnectBindingsIfEmpty(&state) {
            out.append(disc)
        }
        out.append(.disclaim(id))
        return out

    case .release:
        switch state {
        case .virtual(var regs):
            regs.removeAll()
            state = .virtual(regs)
            return []
        case .disconnected:
            return []
        case .connected(let native, let regs):
            state = .disconnected
            return [.disconnect(native), .disclaimAll(regs)]
        }
    }
}

private func disconnectBindingsIfEmpty<Backend>(_ state: inout ShortcutBindingsState<Backend>) -> ShortcutBindEffect<Backend>? {
    guard case .connected(let native, let regs) = state, regs.isEmpty else { return nil }
    state = .disconnected
    return .disconnect(native)
}

/// Process-wide shortcut ownership registry so same-process engines reject duplicates with owner app title (`service.rs:377`).
public final class ShortcutProcessClaims: @unchecked Sendable {
    public static let shared = ShortcutProcessClaims()

    private let lock = NSLock()
    private var claims: [ParsedShortcut: (engineID: ObjectIdentifier, regID: UInt32, owner: String)] = [:]

    public init() {}

    public func owner(of shortcut: ParsedShortcut) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return claims[shortcut]?.owner
    }

    public func isClaimed(_ shortcut: ParsedShortcut) -> Bool {
        owner(of: shortcut) != nil
    }

    public func claim(shortcut: ParsedShortcut, engineID: ObjectIdentifier, regID: UInt32, owner: String) {
        lock.lock()
        claims[shortcut] = (engineID, regID, owner)
        lock.unlock()
    }

    public func disclaim(engineID: ObjectIdentifier, regID: UInt32) {
        lock.lock()
        claims = claims.filter { !($0.value.engineID == engineID && $0.value.regID == regID) }
        lock.unlock()
    }

    public func disclaimAll(engineID: ObjectIdentifier) {
        lock.lock()
        claims = claims.filter { $0.value.engineID != engineID }
        lock.unlock()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return claims.count
    }
}

/// Coordinates `ShortcutBindingsState`, backend connect/bind/unbind, and process-wide claim names (`shortcuts/service.rs:377`).
public final class ShortcutEngine {
    public let title: String
    public var bindings: ShortcutBindingsState<any ShortcutBackendDriver>
    public let claims: ShortcutProcessClaims
    public var allowUnmodified: Bool
    private let connect: () -> Result<any ShortcutBackendDriver, ShortcutError>

    public init(
        title: String,
        bindings: ShortcutBindingsState<any ShortcutBackendDriver> = .disconnected,
        claims: ShortcutProcessClaims = .shared,
        allowUnmodified: Bool = false,
        connect: @escaping () -> Result<any ShortcutBackendDriver, ShortcutError> = { .failure(.rejectedByOS("unsupported")) }
    ) {
        self.title = title
        self.bindings = bindings
        self.claims = claims
        self.allowUnmodified = allowUnmodified
        self.connect = connect
    }

    deinit {
        release()
    }

    private var engineID: ObjectIdentifier { ObjectIdentifier(self) }

    public func owner(of shortcut: ParsedShortcut) -> String? {
        if let inProcess = claims.owner(of: shortcut) {
            return inProcess
        }
        if bindings.find(shortcut) != nil {
            return title
        }
        return nil
    }

    @discardableResult
    public func register(id: UInt32, shortcut: ParsedShortcut) -> Result<Void, ShortcutError> {
        if !allowUnmodified && !shortcut.hasBindingModifier {
            return .failure(.unmodifiedDisallowed)
        }
        let alreadyClaimed = claims.isClaimed(shortcut)
        let effects = stepShortcutBindings(&bindings, event: .register(id: id, shortcut: shortcut, claimed: alreadyClaimed))
        for effect in effects {
            switch effect {
            case .refuse(let err):
                if case .alreadyInUse = err {
                    return .failure(.alreadyInUse(owner: claims.owner(of: shortcut)))
                }
                return .failure(err)
            case .connect(let cid, let cs):
                switch connect() {
                case .success(let driver):
                    return applyBind(driver: driver, id: cid, shortcut: cs, fromOpened: true)
                case .failure(let err):
                    return .failure(err)
                }
            case .bind(let bid, let bs):
                if case .connected(let driver, _) = bindings {
                    return applyBind(driver: driver, id: bid, shortcut: bs, fromOpened: false)
                }
            default:
                break
            }
        }
        return .success(())
    }

    private func applyBind(
        driver: any ShortcutBackendDriver,
        id: UInt32,
        shortcut: ParsedShortcut,
        fromOpened: Bool
    ) -> Result<Void, ShortcutError> {
        if fromOpened {
            _ = stepShortcutBindings(&bindings, event: .opened(native: driver, id: id, shortcut: shortcut))
        }
        switch driver.register(id: id, shortcut: shortcut) {
        case .success:
            for eff in stepShortcutBindings(&bindings, event: .bound(id: id, shortcut: shortcut)) {
                if case .claim(let cid, let cs) = eff {
                    claims.claim(shortcut: cs, engineID: engineID, regID: cid, owner: title)
                }
            }
            return .success(())
        case .failure(let err):
            _ = stepShortcutBindings(&bindings, event: .rejected(err))
            return .failure(err)
        }
    }

    @discardableResult
    public func unregister(id: UInt32) -> Result<Void, ShortcutError> {
        let effects = stepShortcutBindings(&bindings, event: .unregister(id))
        for effect in effects {
            switch effect {
            case .refuse(let err):
                return .failure(err)
            case .unbind(let uid):
                guard case .connected(let driver, _) = bindings else { return .failure(.unknownId("\(uid)")) }
                switch driver.unregister(id: uid) {
                case .success:
                    for eff in stepShortcutBindings(&bindings, event: .unbound(uid)) {
                        if case .disclaim(let did) = eff {
                            claims.disclaim(engineID: engineID, regID: did)
                        }
                    }
                    return .success(())
                case .failure(let err):
                    return .failure(err)
                }
            default:
                break
            }
        }
        return .success(())
    }

    public func release() {
        let effects = stepShortcutBindings(&bindings, event: .release)
        for effect in effects {
            if case .disclaimAll = effect {
                claims.disclaimAll(engineID: engineID)
            }
        }
    }
}
