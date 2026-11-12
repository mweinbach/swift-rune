import Foundation

/// Keyboard modifier flags (`rune::Mods`).
public struct Mods: Sendable, Hashable, Codable {
    public var shift: Bool
    public var ctrl: Bool
    public var alt: Bool
    public var cmd: Bool
    public var logo: Bool

    public init(
        shift: Bool = false,
        ctrl: Bool = false,
        alt: Bool = false,
        cmd: Bool = false,
        logo: Bool = false
    ) {
        self.shift = shift
        self.ctrl = ctrl
        self.alt = alt
        self.cmd = cmd
        self.logo = logo
    }

    public static let none = Mods()

    /// Platform primary shortcut modifier (`cmd` on macOS/iOS, `ctrl` elsewhere).
    public var primaryCommand: Bool {
        #if os(macOS) || os(iOS)
        return cmd
        #else
        return ctrl
        #endif
    }
}

/// Logical key identifier (`rune::Key`).
public enum Key: Sendable, Hashable {
    case text(String)
    case command(Character)
    case enter
    case tab
    case escape
    case backspace
    case delete
    case space
    case arrowLeft
    case arrowRight
    case arrowUp
    case arrowDown
    case home
    case end
    case pageUp
    case pageDown
    case f(UInt8)

    public static func named(_ raw: String) -> Key? {
        switch raw.lowercased() {
        case "enter", "return": return .enter
        case "tab": return .tab
        case "esc", "escape": return .escape
        case "backspace": return .backspace
        case "delete", "del": return .delete
        case "space", " ": return .space
        case "left", "arrowleft": return .arrowLeft
        case "right", "arrowright": return .arrowRight
        case "up", "arrowup": return .arrowUp
        case "down", "arrowdown": return .arrowDown
        case "home": return .home
        case "end": return .end
        case "pageup", "pgup": return .pageUp
        case "pagedown", "pgdn": return .pageDown
        case "plus": return .text("+")
        default:
            if raw.lowercased().hasPrefix("f"), let num = UInt8(raw.dropFirst()), (1...24).contains(num) {
                return .f(num)
            }
            if raw.count == 1 {
                return .text(raw)
            }
            return nil
        }
    }
}

/// Keyboard press/release event (`rune::KeyEvent`).
public struct KeyEvent: Sendable, Hashable {
    public var key: Key
    public var mods: Mods

    public init(key: Key, mods: Mods = .none) {
        self.key = key
        self.mods = mods
    }
}

/// Parsed keyboard shortcut chord (`"mod+shift+k"`, `"cmd+s"`, `"escape"`, `"alt+up"`).
public struct Chord: Sendable, Hashable, CustomStringConvertible {
    public var mods: Mods
    public var key: Key

    public init(mods: Mods = .none, key: Key) {
        self.mods = mods
        self.key = key
    }

    public init?(parsing spec: String) {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last else { return nil }

        var mods = Mods()
        for p in parts.dropLast() {
            switch p.lowercased() {
            case "shift":
                mods.shift = true
            case "ctrl", "control":
                mods.ctrl = true
            case "alt", "opt", "option":
                mods.alt = true
            case "cmd", "command", "meta":
                mods.cmd = true
            case "super", "win", "logo":
                mods.logo = true
            case "mod":
                #if os(macOS) || os(iOS)
                mods.cmd = true
                #else
                mods.ctrl = true
                #endif
            default:
                return nil
            }
        }

        let parsedKey: Key
        if mods.cmd, last.count == 1, let ch = last.lowercased().first {
            parsedKey = .command(ch)
        } else if let k = Key.named(last) {
            if case .text(let s) = k, s.count == 1 {
                parsedKey = .text(s.lowercased())
            } else {
                parsedKey = k
            }
        } else {
            return nil
        }

        self.mods = mods
        self.key = parsedKey
    }

    public func matches(_ ev: KeyEvent) -> Bool {
        guard ev.mods.shift == mods.shift &&
              ev.mods.ctrl == mods.ctrl &&
              ev.mods.alt == mods.alt &&
              ev.mods.cmd == mods.cmd &&
              ev.mods.logo == mods.logo else {
            return false
        }
        switch (key, ev.key) {
        case let (.command(a), .command(b)):
            return a == Character(b.lowercased())
        case let (.command(a), .text(b)):
            return b.count == 1 && Character(b.lowercased()) == a
        case let (.text(a), .command(b)):
            return a.count == 1 && Character(a.lowercased()) == Character(b.lowercased())
        case let (.text(a), .text(b)):
            return a.lowercased() == b.lowercased()
        default:
            return key == ev.key
        }
    }

    public var description: String {
        var parts: [String] = []
        if mods.ctrl { parts.append("Ctrl") }
        if mods.alt { parts.append("Alt") }
        if mods.shift { parts.append("Shift") }
        if mods.cmd { parts.append("Cmd") }
        switch key {
        case .text(let s): parts.append(s.uppercased())
        case .command(let c): parts.append(String(c).uppercased())
        case .enter: parts.append("Enter")
        case .tab: parts.append("Tab")
        case .escape: parts.append("Esc")
        case .backspace: parts.append("Backspace")
        case .delete: parts.append("Delete")
        case .space: parts.append("Space")
        case .arrowLeft: parts.append("Left")
        case .arrowRight: parts.append("Right")
        case .arrowUp: parts.append("Up")
        case .arrowDown: parts.append("Down")
        case .home: parts.append("Home")
        case .end: parts.append("End")
        case .pageUp: parts.append("PageUp")
        case .pageDown: parts.append("PageDown")
        case .f(let n): parts.append("F\(n)")
        }
        return parts.joined(separator: "+")
    }
}

/// Action-mapped shortcut table (`rune::Keybind<A>`).
public struct Keybind<Action: Sendable>: Sendable {
    public var bindings: [(Chord, Action)] = []

    public init(_ specs: [(String, Action)] = []) {
        for (spec, action) in specs {
            if let chord = Chord(parsing: spec) {
                bindings.append((chord, action))
            }
        }
    }

    public mutating func bind(_ spec: String, to action: Action) {
        if let chord = Chord(parsing: spec) {
            bindings.append((chord, action))
        }
    }

    public func match(_ ev: KeyEvent) -> Action? {
        for (chord, action) in bindings.reversed() {
            if chord.matches(ev) {
                return action
            }
        }
        return nil
    }
}

/// Rich clipboard payload (`rune::ClipboardContent`).
public struct ClipboardContent: Sendable, Equatable {
    public var text: String
    public var html: String?
    public var rtf: String?

    public init(_ text: String = "", html: String? = nil, rtf: String? = nil) {
        self.text = text
        self.html = html
        self.rtf = rtf
    }
}

/// Colored inline mark over a UTF-8 byte range inside `TextEdit`.
public struct TextMark: Sendable, Equatable {
    public var utf8Range: Range<Int>
    public var textColor: Color?
    public var background: Color?

    public init(utf8Range: Range<Int>, textColor: Color? = nil, background: Color? = nil) {
        self.utf8Range = utf8Range
        self.textColor = textColor
        self.background = background
    }
}

/// Grapheme-cluster-safe single-line and multiline text editor state (`rune::TextEdit`).
///
/// Caret and selection anchor are stored as UTF-8 byte offsets snapped strictly to extended
/// grapheme cluster (`Character`) boundaries, so ZWJ emoji, flags, and combining accents never split.
public struct TextEdit: Sendable, Equatable {
    private struct Snapshot: Sendable, Equatable {
        var text: String
        var cursor: Int
        var anchor: Int
        var marks: [TextMark]
    }

    public private(set) var text: String
    /// Active caret position in UTF-8 bytes (`0...text.utf8.count`).
    public private(set) var cursor: Int
    /// Selection anchor in UTF-8 bytes (`anchor == cursor` when collapsed).
    public private(set) var anchor: Int
    public var multiline: Bool
    public var isSecure: Bool = false
    public var isRevealed: Bool = false
    public var spellcheckEnabled: Bool = false
    public var marks: [TextMark] = []
    /// Optional open IME composition `(preeditText, cursorRangeInBytes)`.
    public var preedit: (text: String, cursor: Range<Int>?)? = nil

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    public static func == (lhs: TextEdit, rhs: TextEdit) -> Bool {
        lhs.text == rhs.text &&
        lhs.cursor == rhs.cursor &&
        lhs.anchor == rhs.anchor &&
        lhs.multiline == rhs.multiline &&
        lhs.isSecure == rhs.isSecure &&
        lhs.isRevealed == rhs.isRevealed &&
        lhs.marks == rhs.marks &&
        lhs.preedit?.text == rhs.preedit?.text &&
        lhs.preedit?.cursor == rhs.preedit?.cursor
    }

    public init(_ initial: String = "", multiline: Bool = false) {
        let cleaned = multiline ? initial : initial.replacingOccurrences(of: "\n", with: " ")
        self.text = cleaned
        let end = cleaned.utf8.count
        self.cursor = end
        self.anchor = end
        self.multiline = multiline
    }

    public var hasSelection: Bool { cursor != anchor }

    public var selectedUTF8Range: Range<Int> {
        min(cursor, anchor)..<max(cursor, anchor)
    }

    public var selectedText: String {
        guard hasSelection else { return "" }
        let r = selectedUTF8Range
        let s = stringIndex(forUTF8Offset: r.lowerBound)
        let e = stringIndex(forUTF8Offset: r.upperBound)
        return String(text[s..<e])
    }

    /// Replaces the entire text and places the caret at the end.
    public mutating func setText(_ newText: String, recordUndo: Bool = false) {
        if recordUndo { pushUndo() }
        let cleaned = multiline ? newText : newText.replacingOccurrences(of: "\n", with: " ")
        text = cleaned
        let end = cleaned.utf8.count
        cursor = end
        anchor = end
        marks.removeAll()
        preedit = nil
    }

    public mutating func clear() {
        setText("", recordUndo: false)
        undoStack.removeAll()
        redoStack.removeAll()
    }

    public mutating func selectAll() {
        anchor = 0
        cursor = text.utf8.count
    }

    public mutating func collapseSelectionToStart() {
        let pos = min(cursor, anchor)
        cursor = pos
        anchor = pos
    }

    public mutating func collapseSelectionToEnd() {
        let pos = max(cursor, anchor)
        cursor = pos
        anchor = pos
    }

    public mutating func setCursor(utf8Offset: Int, extendSelection: Bool = false) {
        let snapped = snapToGraphemeBoundary(utf8Offset)
        cursor = snapped
        if !extendSelection {
            anchor = snapped
        }
    }

    public mutating func selectWord(atUTF8Offset offset: Int) {
        let snapped = snapToGraphemeBoundary(offset)
        let left = prevWordBoundary(from: snapped == text.utf8.count ? snapped : nextGraphemeBoundary(from: snapped))
        let right = nextWordBoundary(from: left)
        anchor = left
        cursor = right
    }

    /// Inserts `inserted` at the current caret or replaces any active selection.
    public mutating func insert(_ inserted: String) {
        let filtered = multiline ? inserted : inserted.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        guard !filtered.isEmpty || hasSelection else { return }
        pushUndo()
        let range = selectedUTF8Range
        let startIdx = stringIndex(forUTF8Offset: range.lowerBound)
        let endIdx = stringIndex(forUTF8Offset: range.upperBound)
        text.replaceSubrange(startIdx..<endIdx, with: filtered)
        adjustMarks(replacedRange: range, newLength: filtered.utf8.count)
        let newCursor = range.lowerBound + filtered.utf8.count
        cursor = newCursor
        anchor = newCursor
        preedit = nil
    }

    /// Deletes one extended grapheme cluster backward (or the active selection, or previous word when `word == true`).
    public mutating func backspace(word: Bool = false) {
        if hasSelection {
            insert("")
            return
        }
        guard cursor > 0 else { return }
        pushUndo()
        let target = word ? prevWordBoundary(from: cursor) : prevGraphemeBoundary(from: cursor)
        let startIdx = stringIndex(forUTF8Offset: target)
        let endIdx = stringIndex(forUTF8Offset: cursor)
        text.removeSubrange(startIdx..<endIdx)
        adjustMarks(replacedRange: target..<cursor, newLength: 0)
        cursor = target
        anchor = target
    }

    /// Deletes one extended grapheme cluster forward (or the active selection, or next word when `word == true`).
    public mutating func deleteForward(word: Bool = false) {
        if hasSelection {
            insert("")
            return
        }
        guard cursor < text.utf8.count else { return }
        pushUndo()
        let target = word ? nextWordBoundary(from: cursor) : nextGraphemeBoundary(from: cursor)
        let startIdx = stringIndex(forUTF8Offset: cursor)
        let endIdx = stringIndex(forUTF8Offset: target)
        text.removeSubrange(startIdx..<endIdx)
        adjustMarks(replacedRange: cursor..<target, newLength: 0)
    }

    public mutating func moveLeft(extend: Bool = false, word: Bool = false, toLineBoundary: Bool = false) {
        if !extend && hasSelection && !word && !toLineBoundary {
            collapseSelectionToStart()
            return
        }
        let nextPos: Int
        if toLineBoundary {
            nextPos = lineStart(for: cursor)
        } else if word {
            nextPos = prevWordBoundary(from: cursor)
        } else {
            nextPos = prevGraphemeBoundary(from: cursor)
        }
        setCursor(utf8Offset: nextPos, extendSelection: extend)
    }

    public mutating func moveRight(extend: Bool = false, word: Bool = false, toLineBoundary: Bool = false) {
        if !extend && hasSelection && !word && !toLineBoundary {
            collapseSelectionToEnd()
            return
        }
        let nextPos: Int
        if toLineBoundary {
            nextPos = lineEnd(for: cursor)
        } else if word {
            nextPos = nextWordBoundary(from: cursor)
        } else {
            nextPos = nextGraphemeBoundary(from: cursor)
        }
        setCursor(utf8Offset: nextPos, extendSelection: extend)
    }

    public mutating func moveUp(extend: Bool = false) {
        guard multiline else {
            setCursor(utf8Offset: 0, extendSelection: extend)
            return
        }
        let curLineStart = lineStart(for: cursor)
        guard curLineStart > 0 else {
            setCursor(utf8Offset: 0, extendSelection: extend)
            return
        }
        let colChars = graphemeCount(from: curLineStart, to: cursor)
        let prevLineEnd = curLineStart - 1
        let prevLineStart = lineStart(for: prevLineEnd)
        let target = utf8Offset(from: prevLineStart, advancingGraphemes: colChars, limit: prevLineEnd)
        setCursor(utf8Offset: target, extendSelection: extend)
    }

    public mutating func moveDown(extend: Bool = false) {
        guard multiline else {
            setCursor(utf8Offset: text.utf8.count, extendSelection: extend)
            return
        }
        let curLineStart = lineStart(for: cursor)
        let curLineEnd = lineEnd(for: cursor)
        guard curLineEnd < text.utf8.count else {
            setCursor(utf8Offset: text.utf8.count, extendSelection: extend)
            return
        }
        let colChars = graphemeCount(from: curLineStart, to: cursor)
        let nextLineStart = curLineEnd + 1
        let nextLineEnd = lineEnd(for: nextLineStart)
        let target = utf8Offset(from: nextLineStart, advancingGraphemes: colChars, limit: nextLineEnd)
        setCursor(utf8Offset: target, extendSelection: extend)
    }

    public func copy() -> String? {
        guard (!isSecure || isRevealed) && hasSelection else { return nil }
        return selectedText
    }

    public mutating func cut() -> String? {
        guard (!isSecure || isRevealed) && hasSelection else { return nil }
        let out = selectedText
        insert("")
        return out
    }

    public mutating func paste(_ pasted: String) {
        insert(pasted)
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let prev = undoStack.popLast() else { return false }
        redoStack.append(Snapshot(text: text, cursor: cursor, anchor: anchor, marks: marks))
        text = prev.text
        cursor = prev.cursor
        anchor = prev.anchor
        marks = prev.marks
        preedit = nil
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(Snapshot(text: text, cursor: cursor, anchor: anchor, marks: marks))
        text = next.text
        cursor = next.cursor
        anchor = next.anchor
        marks = next.marks
        preedit = nil
        return true
    }

    // MARK: - IME Preedit

    public mutating func setPreedit(_ preeditText: String, cursor cursorRange: Range<Int>? = nil) {
        if preeditText.isEmpty {
            preedit = nil
        } else {
            preedit = (preeditText, cursorRange)
        }
    }

    public mutating func commitPreedit(_ committed: String) {
        preedit = nil
        insert(committed)
    }

    public mutating func cancelPreedit() {
        preedit = nil
    }

    public enum EditOutcome: Sendable, Equatable {
        case ignored
        case navigation
        case modified
        case submit
        case copy(String)
    }

    /// Processes a keyboard `KeyEvent`, returning how the editor responded.
    public mutating func handleKey(_ ev: KeyEvent) -> EditOutcome {
        let shift = ev.mods.shift
        let primary = ev.mods.primaryCommand
        let alt = ev.mods.alt

        if primary {
            switch ev.key {
            case .command("a"), .text("a"), .text("A"):
                selectAll()
                return .navigation
            case .command("z"), .text("z"), .text("Z"):
                if shift {
                    return redo() ? .modified : .ignored
                } else {
                    return undo() ? .modified : .ignored
                }
            case .command("y"), .text("y"), .text("Y"):
                return redo() ? .modified : .ignored
            case .command("c"), .text("c"), .text("C"):
                if let copied = copy() { return .copy(copied) }
                return .ignored
            case .command("x"), .text("x"), .text("X"):
                if let cutStr = cut() { return .copy(cutStr) }
                return .ignored
            case .arrowLeft:
                moveLeft(extend: shift, toLineBoundary: true)
                return .navigation
            case .arrowRight:
                moveRight(extend: shift, toLineBoundary: true)
                return .navigation
            case .arrowUp:
                setCursor(utf8Offset: 0, extendSelection: shift)
                return .navigation
            case .arrowDown:
                setCursor(utf8Offset: text.utf8.count, extendSelection: shift)
                return .navigation
            case .backspace:
                let start = lineStart(for: cursor)
                if start < cursor || hasSelection {
                    if !hasSelection { anchor = start }
                    insert("")
                    return .modified
                }
                return .ignored
            case .delete:
                let end = lineEnd(for: cursor)
                if cursor < end || hasSelection {
                    if !hasSelection { anchor = end }
                    insert("")
                    return .modified
                }
                return .ignored
            default:
                return .ignored
            }
        }

        switch ev.key {
        case .backspace:
            let before = text
            backspace(word: alt || ev.mods.ctrl)
            return text != before ? .modified : .navigation

        case .delete:
            let before = text
            deleteForward(word: alt || ev.mods.ctrl)
            return text != before ? .modified : .navigation

        case .arrowLeft:
            moveLeft(extend: shift, word: alt || ev.mods.ctrl)
            return .navigation

        case .arrowRight:
            moveRight(extend: shift, word: alt || ev.mods.ctrl)
            return .navigation

        case .arrowUp:
            moveUp(extend: shift)
            return .navigation

        case .arrowDown:
            moveDown(extend: shift)
            return .navigation

        case .home:
            moveLeft(extend: shift, toLineBoundary: true)
            return .navigation

        case .end:
            moveRight(extend: shift, toLineBoundary: true)
            return .navigation

        case .enter:
            if multiline && !ev.mods.ctrl {
                insert("\n")
                return .modified
            }
            return .submit

        case .escape:
            if preedit != nil {
                cancelPreedit()
                return .modified
            }
            return .ignored

        case .space:
            if !ev.mods.ctrl {
                insert(" ")
                return .modified
            }
            return .ignored

        case .text(let s):
            if !ev.mods.ctrl {
                insert(s)
                return .modified
            }
            return .ignored

        default:
            return .ignored
        }
    }

    /// Masked display string (`•` per grapheme cluster when `isSecure && !isRevealed` is true).
    public var displayString: String {
        if isSecure && !isRevealed {
            return String(repeating: "•", count: text.count)
        }
        return text
    }

    // MARK: - Grapheme & Word Boundary Helpers

    public func snapToGraphemeBoundary(_ utf8Offset: Int) -> Int {
        let clamped = utf8Offset.clamped(to: 0...text.utf8.count)
        if clamped == 0 || clamped == text.utf8.count { return clamped }
        var bytePos = 0
        for ch in text {
            let nextPos = bytePos + ch.utf8.count
            if clamped <= nextPos {
                return (clamped - bytePos <= nextPos - clamped) ? bytePos : nextPos
            }
            bytePos = nextPos
        }
        return text.utf8.count
    }

    public func stringIndex(forUTF8Offset offset: Int) -> String.Index {
        let clamped = snapToGraphemeBoundary(offset)
        return text.utf8.index(text.utf8.startIndex, offsetBy: clamped)
    }

    private func prevGraphemeBoundary(from offset: Int) -> Int {
        let idx = stringIndex(forUTF8Offset: offset)
        guard idx > text.startIndex else { return 0 }
        let prev = text.index(before: idx)
        return text.utf8.distance(from: text.utf8.startIndex, to: prev.samePosition(in: text.utf8)!)
    }

    private func nextGraphemeBoundary(from offset: Int) -> Int {
        let idx = stringIndex(forUTF8Offset: offset)
        guard idx < text.endIndex else { return text.utf8.count }
        let next = text.index(after: idx)
        return text.utf8.distance(from: text.utf8.startIndex, to: next.samePosition(in: text.utf8)!)
    }

    private func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    private func prevWordBoundary(from offset: Int) -> Int {
        var idx = stringIndex(forUTF8Offset: offset)
        while idx > text.startIndex && !isWordChar(text[text.index(before: idx)]) {
            idx = text.index(before: idx)
        }
        while idx > text.startIndex && isWordChar(text[text.index(before: idx)]) {
            idx = text.index(before: idx)
        }
        return text.utf8.distance(from: text.utf8.startIndex, to: idx.samePosition(in: text.utf8)!)
    }

    private func nextWordBoundary(from offset: Int) -> Int {
        var idx = stringIndex(forUTF8Offset: offset)
        while idx < text.endIndex && !isWordChar(text[idx]) {
            idx = text.index(after: idx)
        }
        while idx < text.endIndex && isWordChar(text[idx]) {
            idx = text.index(after: idx)
        }
        return text.utf8.distance(from: text.utf8.startIndex, to: idx.samePosition(in: text.utf8)!)
    }

    private func lineStart(for offset: Int) -> Int {
        var idx = stringIndex(forUTF8Offset: offset)
        while idx > text.startIndex {
            let prev = text.index(before: idx)
            if text[prev] == "\n" { break }
            idx = prev
        }
        return text.utf8.distance(from: text.utf8.startIndex, to: idx.samePosition(in: text.utf8)!)
    }

    private func lineEnd(for offset: Int) -> Int {
        var idx = stringIndex(forUTF8Offset: offset)
        while idx < text.endIndex && text[idx] != "\n" {
            idx = text.index(after: idx)
        }
        return text.utf8.distance(from: text.utf8.startIndex, to: idx.samePosition(in: text.utf8)!)
    }

    private func graphemeCount(from startUTF8: Int, to endUTF8: Int) -> Int {
        guard endUTF8 > startUTF8 else { return 0 }
        let s = stringIndex(forUTF8Offset: startUTF8)
        let e = stringIndex(forUTF8Offset: endUTF8)
        return text.distance(from: s, to: e)
    }

    private func utf8Offset(from startUTF8: Int, advancingGraphemes count: Int, limit limitUTF8: Int) -> Int {
        var idx = stringIndex(forUTF8Offset: startUTF8)
        let limitIdx = stringIndex(forUTF8Offset: limitUTF8)
        var remaining = count
        while remaining > 0 && idx < limitIdx {
            idx = text.index(after: idx)
            remaining -= 1
        }
        return text.utf8.distance(from: text.utf8.startIndex, to: idx.samePosition(in: text.utf8)!)
    }

    private mutating func adjustMarks(replacedRange: Range<Int>, newLength: Int) {
        guard !marks.isEmpty else { return }
        let delta = newLength - replacedRange.count
        var updated: [TextMark] = []
        updated.reserveCapacity(marks.count)
        for var m in marks {
            if m.utf8Range.upperBound <= replacedRange.lowerBound {
                updated.append(m)
            } else if m.utf8Range.lowerBound >= replacedRange.upperBound {
                m.utf8Range = (m.utf8Range.lowerBound + delta)..<(m.utf8Range.upperBound + delta)
                updated.append(m)
            } else {
                let newLo = min(m.utf8Range.lowerBound, replacedRange.lowerBound)
                let tail = max(0, m.utf8Range.upperBound - replacedRange.upperBound)
                let newHi = newLo + max(0, min(m.utf8Range.upperBound, replacedRange.lowerBound) - newLo) + newLength + tail
                if newHi > newLo {
                    m.utf8Range = newLo..<newHi
                    updated.append(m)
                }
            }
        }
        marks = updated
    }

    private mutating func pushUndo() {
        undoStack.append(Snapshot(text: text, cursor: cursor, anchor: anchor, marks: marks))
        if undoStack.count > 128 {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }
}

// MARK: - Spellcheck Integration on TextEdit

extension TextEdit {
    /// Returns UTF-8 byte ranges of misspelled words when `spellcheckEnabled` is true and `!isSecure`.
    public func misspelledUTF8Ranges(using checker: SpellChecker = .shared) -> [Range<Int>] {
        guard spellcheckEnabled && !isSecure else { return [] }
        return checker.misspelledUTF8Ranges(in: text)
    }

    /// Returns `(range, word, suggestions)` if `offset` lies within a misspelled word.
    public func spellingSuggestions(
        atUTF8Offset offset: Int,
        using checker: SpellChecker = .shared
    ) -> (range: Range<Int>, word: String, suggestions: [String])? {
        let ranges = misspelledUTF8Ranges(using: checker)
        guard let hit = ranges.first(where: { $0.contains(offset) || $0.upperBound == offset }) else {
            return nil
        }
        let lo = stringIndex(forUTF8Offset: hit.lowerBound)
        let hi = stringIndex(forUTF8Offset: hit.upperBound)
        let word = String(text[lo..<hi])
        return (hit, word, checker.suggestions(for: word))
    }

    /// Replaces `range` (e.g. a misspelled word) with `replacement` while recording an undo snapshot.
    public mutating func replaceUTF8Range(_ range: Range<Int>, with replacement: String) {
        let lo = max(0, min(text.utf8.count, range.lowerBound))
        let hi = max(lo, min(text.utf8.count, range.upperBound))
        pushUndo()
        let startIdx = stringIndex(forUTF8Offset: lo)
        let endIdx = stringIndex(forUTF8Offset: hi)
        text.replaceSubrange(startIdx..<endIdx, with: replacement)
        let newCursor = lo + replacement.utf8.count
        cursor = newCursor
        anchor = newCursor
        adjustMarks(replacedRange: lo..<hi, newLength: replacement.utf8.count)
    }
}
