import Foundation

/// One selectable text element's slice within a `TextSelection`
/// (`crates/rune/src/runtime/selection/text_selection.rs`).
public struct SelectedText: Equatable, Hashable, Sendable {
    public var path: String
    public var key: String?
    public var range: Range<Int>
    public var len: Int
    public var whole: Bool
    public var text: String
    public var content: String

    public init(
        path: String,
        key: String? = nil,
        range: Range<Int>,
        len: Int,
        whole: Bool,
        text: String,
        content: String
    ) {
        self.path = path
        self.key = key
        self.range = range
        self.len = len
        self.whole = whole
        self.text = text
        self.content = content
    }

    /// True when the selected byte slice is empty (`SelectedText::is_empty`).
    public var isEmpty: Bool { range.isEmpty }

    /// True when at least one byte is selected in this text (`SelectedText::is_selected`).
    public var isSelected: Bool { !range.isEmpty }

    /// True when every copiable byte of this text is covered (`SelectedText::is_whole`).
    public var isWhole: Bool { whole }

    /// Builds a persistent `SelectionMark` for rendering custom CSS-like highlight boxes later.
    public func mark() -> SelectionMark {
        SelectionMark(path: path, range: range, text: text)
    }
}

/// Snapshot of the active selectable-text selection across one text or `selectionGroup`
/// (`crates/rune/src/runtime/selection/text_selection.rs`).
public struct TextSelection: Equatable, Hashable, Sendable {
    public var texts: [SelectedText]
    public var text: String
    public var backward: Bool

    public init(texts: [SelectedText], text: String, backward: Bool = false) {
        self.texts = texts
        self.text = text
        self.backward = backward
    }

    public var isEmpty: Bool {
        text.isEmpty || texts.isEmpty
    }
}

/// Payload delivered to `El.onSelectionChange` handlers (`crates/rune/src/runtime/selection/text_selection.rs`).
public struct SelectionChange: Equatable, Sendable {
    public var selection: TextSelection?
    public var was: Bool
    public var isDragging: Bool

    public init(selection: TextSelection?, was: Bool, isDragging: Bool) {
        self.selection = selection
        self.was = was
        self.isDragging = isDragging
    }

    /// True on the frame a selection newly entered this element's subtree.
    public var started: Bool {
        !was && selection != nil
    }

    /// True on the frame a selection left or cleared from this element's subtree.
    public var cleared: Bool {
        was && selection == nil
    }
}

/// A marked UTF-8 byte slice of a text element to highlight persistently (`text_marks.rs`).
/// Named `SelectionMark` to stay distinct from `Edit.swift`'s inline `TextMark`.
public struct SelectionMark: Equatable, Hashable, Sendable {
    public var path: String
    public var range: Range<Int>
    public var text: String

    public init(path: String, range: Range<Int>, text: String) {
        self.path = path
        self.range = range
        self.text = text
    }
}

public extension Tx {
    internal static let selectTextActionKey = "rune.selectText"
    internal static let selectAllTextActionKey = "rune.selectAllText"
    internal static let clearTextSelectionActionKey = "rune.clearTextSelection"
    internal static let currentSelectionActionKey = "rune.currentTextSelection"

    /// Programmatically selects UTF-8 byte `range` in the selectable text keyed `key` (`Tx::select_text`).
    mutating func selectText(_ key: String, range: Range<Int>) {
        let clamped = max(0, range.lowerBound)..<max(max(0, range.lowerBound), range.upperBound)
        runtimeActions[Self.selectTextActionKey] = (key: key, range: clamped)
        runtimeActions.removeValue(forKey: Self.selectAllTextActionKey)
        runtimeActions.removeValue(forKey: Self.clearTextSelectionActionKey)
    }

    /// Programmatically selects all selectable text under element/group keyed `key` (`Tx::select_all_text`).
    mutating func selectAllText(_ key: String) {
        runtimeActions[Self.selectAllTextActionKey] = key
        runtimeActions.removeValue(forKey: Self.selectTextActionKey)
        runtimeActions.removeValue(forKey: Self.clearTextSelectionActionKey)
    }

    /// Clears any active `El.selectable` text selection (`Tx::clear_selection`).
    mutating func clearTextSelection() {
        runtimeActions[Self.clearTextSelectionActionKey] = true
        runtimeActions.removeValue(forKey: Self.selectTextActionKey)
        runtimeActions.removeValue(forKey: Self.selectAllTextActionKey)
    }

    /// Current `TextSelection` snapshot exposed to handlers during event dispatch (`Tx::text_selection`).
    func textSelection() -> TextSelection? {
        runtimeActions[Self.currentSelectionActionKey] as? TextSelection
    }

    internal var pendingSelectTextRequest: (key: String, range: Range<Int>)? {
        runtimeActions[Self.selectTextActionKey] as? (key: String, range: Range<Int>)
    }

    internal var pendingSelectAllTextKey: String? {
        runtimeActions[Self.selectAllTextActionKey] as? String
    }

    internal var clearTextSelectionRequested: Bool {
        (runtimeActions[Self.clearTextSelectionActionKey] as? Bool) ?? false
    }

    internal mutating func setCurrentTextSelection(_ selection: TextSelection?) {
        if let selection {
            runtimeActions[Self.currentSelectionActionKey] = selection
        } else {
            runtimeActions.removeValue(forKey: Self.currentSelectionActionKey)
        }
    }
}
