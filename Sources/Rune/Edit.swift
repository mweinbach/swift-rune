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
    case insert
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
    case contextMenu
    case printScreen
    case scrollLock
    case pause
    case modifier(ModifierKey, pressed: Bool)

    public static func named(_ raw: String) -> Key? {
        guard let ck = ChordTable.chordKey(named: raw) else { return nil }
        return ChordTable.key(from: ck, hasPrimary: false)
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
    internal let chordModBits: UInt8
    public let chordKey: ChordKey

    public static func == (lhs: Chord, rhs: Chord) -> Bool {
        lhs.chordModBits == rhs.chordModBits && lhs.chordKey == rhs.chordKey
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(chordModBits)
        hasher.combine(chordKey)
    }

    public init(mods: Mods = .none, key: Key) {
        self.chordModBits = ChordBits.bitsFromMods(mods)
        self.chordKey = ChordTable.chordKey(from: key) ?? .escape
        self.mods = mods
        self.key = key
    }

    public init(chordMods: [ChordMod], key chordKey: ChordKey) {
        let bits = chordMods.reduce(UInt8(0)) { $0 | $1.bit }
        self.chordModBits = bits
        self.chordKey = chordKey
        let resolvedMods = ChordBits.modsFromBits(bits, platform: .current)
        self.mods = resolvedMods
        let hasPrimary = (ChordBits.fold(bits, platform: .current) & ChordBits.primary) != 0
        self.key = ChordTable.key(from: chordKey, hasPrimary: hasPrimary)
    }

    /// Strictly parses a chord string (`"mod+shift+t"`, `"cmd+s"`, `"mod++"`, `"super+space"`), throwing `ChordError` on invalid input.
    public static func parse(_ spec: String) throws -> Chord {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChordError.empty }

        let modifierTokens: [String]
        let keyToken: String
        if trimmed == "+" {
            modifierTokens = []
            keyToken = "+"
        } else if trimmed.hasSuffix("+") {
            let beforeFinalPlus = trimmed.dropLast().trimmingCharacters(in: .whitespaces)
            guard beforeFinalPlus.hasSuffix("+") else {
                throw ChordError.trailingPlus
            }
            let modsPart = String(beforeFinalPlus.dropLast())
            if modsPart.trimmingCharacters(in: .whitespaces).isEmpty {
                throw ChordError.unknownModifier("")
            }
            modifierTokens = modsPart.split(separator: "+", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            keyToken = "+"
        } else {
            let parts = trimmed.split(separator: "+", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            guard let last = parts.last, !last.isEmpty else { throw ChordError.noKey }
            modifierTokens = Array(parts.dropLast())
            keyToken = last
        }

        var bits: UInt8 = 0
        for p in modifierTokens {
            guard !p.isEmpty else { throw ChordError.unknownModifier("") }
            guard let cm = ChordTable.modifierNamed(p) else {
                throw ChordError.unknownModifier(p)
            }
            guard (bits & cm.bit) == 0 else {
                throw ChordError.duplicateModifier(p)
            }
            bits |= cm.bit
        }

        guard var parsedChordKey = ChordTable.chordKey(named: keyToken) else {
            throw ChordError.unknownKey(keyToken)
        }
        // Per upstream chord.rs:135-136: only '{' and '}' fold unconditionally to Shift + '[' / ']'.
        if case .char(let ch) = parsedChordKey, ch == "{" || ch == "}" {
            parsedChordKey = (ch == "{") ? .char("[") : .char("]")
            bits |= ChordBits.shift
        }

        var modsList: [ChordMod] = []
        if (bits & ChordBits.primary) != 0 { modsList.append(.primary) }
        if (bits & ChordBits.ctrl) != 0 { modsList.append(.ctrl) }
        if (bits & ChordBits.alt) != 0 { modsList.append(.alt) }
        if (bits & ChordBits.shift) != 0 { modsList.append(.shift) }
        if (bits & ChordBits.super) != 0 { modsList.append(.super) }
        return Chord(chordMods: modsList, key: parsedChordKey)
    }

    public init?(parsing spec: String) {
        guard let parsed = try? Chord.parse(spec) else { return nil }
        self = parsed
    }

    public func matches(_ ev: KeyEvent) -> Bool {
        matches(ev, on: .current)
    }

    public func matches(_ ev: KeyEvent, on platform: KeyPlatform) -> Bool {
        let want = ChordBits.fold(chordModBits, platform: platform)
        let got = ChordBits.held(ev.mods, platform: platform)
        guard let gotKey = ChordTable.chordKey(from: ev.key) else { return false }
        if want == got && gotKey == chordKey {
            return true
        }
        // Fallback 1 (chord.rs:214): Shift+[ / Shift+{ — event carries Shift and typed a US shifted char.
        if want == got, ev.mods.shift, case .char(let typed) = gotKey,
           let unshifted = ChordTable.usUnshifted(typed), .char(unshifted) == chordKey {
            return true
        }
        // Fallback 2 (chord.rs:219): OS delivered Shift alongside non-alphanumeric shifted char (e.g. mod+plus vs Shift+=).
        if (want | ChordBits.shift) == got,
           case .char(let ch) = chordKey,
           !ch.isLetter, !ch.isNumber,
           gotKey == .char(ch) {
            return true
        }
        return false
    }

    public func sameKeys(_ other: Chord, on platform: KeyPlatform = .current) -> Bool {
        ChordBits.fold(chordModBits, platform: platform) == ChordBits.fold(other.chordModBits, platform: platform)
            && chordKey == other.chordKey
    }

    public func mods(on platform: KeyPlatform = .current) -> [ChordMod] {
        let bits = ChordBits.fold(chordModBits, platform: platform)
        let order: [ChordMod] = platform.isMac
            ? [.ctrl, .alt, .shift, .primary, .super]
            : [.primary, .ctrl, .alt, .shift, .super]
        return order.filter { (bits & $0.bit) != 0 }
    }

    public func keycaps(on platform: KeyPlatform = .current) -> [String] {
        var caps: [String] = mods(on: platform).map { mod in
            switch (mod, platform) {
            case (.primary, .mac): return "⌘"
            case (.ctrl, .mac): return "⌃"
            case (.alt, .mac): return "⌥"
            case (.shift, .mac): return "⇧"
            case (.super, .mac): return "⌘"
            case (.primary, _), (.ctrl, _): return "Ctrl"
            case (.alt, _): return "Alt"
            case (.shift, _): return "Shift"
            case (.super, .windows): return "Win"
            case (.super, .linux): return "Super"
            }
        }
        caps.append(Self.keycapString(chordKey, platform: platform))
        return caps
    }

    public func label(on platform: KeyPlatform = .current) -> String {
        keycaps(on: platform).joined(separator: platform.isMac ? "" : "+")
    }

    public var canonicalString: String {
        var parts: [String] = []
        if (chordModBits & ChordBits.primary) != 0 { parts.append("mod") }
        if (chordModBits & ChordBits.ctrl) != 0 { parts.append("ctrl") }
        if (chordModBits & ChordBits.alt) != 0 { parts.append("alt") }
        if (chordModBits & ChordBits.shift) != 0 { parts.append("shift") }
        if (chordModBits & ChordBits.super) != 0 { parts.append("super") }
        parts.append(Self.canonicalKeyToken(chordKey))
        return parts.joined(separator: "+")
    }

    public var description: String {
        var parts: [String] = []
        let active = mods(on: .current)
        if active.contains(.ctrl) { parts.append("Ctrl") }
        if active.contains(.alt) { parts.append("Alt") }
        if active.contains(.shift) { parts.append("Shift") }
        if active.contains(.primary) || active.contains(.super) {
            #if os(macOS) || os(iOS)
            parts.append("Cmd")
            #else
            parts.append(active.contains(.super) ? "Super" : "Ctrl")
            #endif
        }
        parts.append(Self.keycapString(chordKey, platform: .linux))
        return parts.joined(separator: "+")
    }

    private static func canonicalKeyToken(_ ck: ChordKey) -> String {
        switch ck {
        case .char(let c): return ChordTable.charToken(c)
        case .enter: return "enter"
        case .tab: return "tab"
        case .escape: return "escape"
        case .backspace: return "backspace"
        case .delete: return "delete"
        case .insert: return "insert"
        case .home: return "home"
        case .end: return "end"
        case .pageUp: return "pageup"
        case .pageDown: return "pagedown"
        case .arrowLeft: return "left"
        case .arrowRight: return "right"
        case .arrowUp: return "up"
        case .arrowDown: return "down"
        case .function(let n): return "f\(n)"
        case .contextMenu: return "contextmenu"
        case .printScreen: return "printscreen"
        case .scrollLock: return "scrolllock"
        case .pause: return "pause"
        }
    }

    private static func keycapString(_ ck: ChordKey, platform: KeyPlatform) -> String {
        let mac = platform.isMac
        switch ck {
        case .char(" "): return "Space"
        case .char(let c): return String(c).uppercased()
        case .enter: return mac ? "↩" : "Enter"
        case .tab: return mac ? "⇥" : "Tab"
        case .escape: return mac ? "⎋" : "Esc"
        case .backspace: return mac ? "⌫" : "Backspace"
        case .delete: return mac ? "⌦" : "Delete"
        case .insert: return "Insert"
        case .home: return mac ? "↖" : "Home"
        case .end: return mac ? "↘" : "End"
        case .pageUp: return mac ? "⇞" : (platform == .linux ? "PageUp" : "Page Up")
        case .pageDown: return mac ? "⇟" : (platform == .linux ? "PageDown" : "Page Down")
        case .arrowLeft: return mac ? "←" : "Left"
        case .arrowRight: return mac ? "→" : "Right"
        case .arrowUp: return mac ? "↑" : "Up"
        case .arrowDown: return mac ? "↓" : "Down"
        case .function(let n): return "F\(n)"
        case .contextMenu: return "Menu"
        case .printScreen: return "Print Screen"
        case .scrollLock: return "Scroll Lock"
        case .pause: return "Pause"
        }
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

    public static let multilineSecureMask = "••••••••••••"

    public private(set) var text: String
    /// Active caret position in UTF-8 bytes (`0...text.utf8.count`).
    public private(set) var cursor: Int
    /// Selection anchor in UTF-8 bytes (`anchor == cursor` when collapsed).
    public private(set) var anchor: Int
    public var multiline: Bool
    public var isSecure: Bool = false {
        didSet {
            if isSecure && !oldValue {
                undoStack.removeAll()
                redoStack.removeAll()
                marks.removeAll()
                preedit = nil
                preeditClauses.removeAll()
            }
        }
    }
    public var isRevealed: Bool = false
    public var spellcheckEnabled: Bool = false
    public var marks: [TextMark] = []
    /// Optional open IME composition `(preeditText, cursorRangeInBytes)`.
    public var preedit: (text: String, cursor: Range<Int>?)? = nil {
        didSet {
            if preedit == nil && !preeditClauses.isEmpty {
                preeditClauses.removeAll()
            }
        }
    }
    /// Platform-supplied IME clauses for the open preedit composition (`rune::edit::Clause`).
    public var preeditClauses: [ImeClause] = []
    /// Set when the last key press in `handleKey` requested blurring focus (e.g. non-composing Escape).
    public private(set) var didRequestBlur: Bool = false

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
        lhs.preedit?.cursor == rhs.preedit?.cursor &&
        lhs.preeditClauses == rhs.preeditClauses
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
        let filtered = sanitizeInput(inserted)
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

    /// Deletes backward (or the active selection, or previous word when `word == true`).
    /// For un-selected clusters, deletes one scalar (so accents/Vowel signs peel cleanly) unless CR LF or emoji sequence.
    public mutating func backspace(word: Bool = false) {
        if hasSelection {
            insert("")
            return
        }
        guard cursor > 0 else { return }
        pushUndo()
        let target = word ? prevWordBoundary(from: cursor) : prevBackspaceBoundary(from: cursor)
        let startIdx = text.utf8.index(text.utf8.startIndex, offsetBy: target)
        let endIdx = text.utf8.index(text.utf8.startIndex, offsetBy: cursor)
        text.removeSubrange(startIdx..<endIdx)
        adjustMarks(replacedRange: target..<cursor, newLength: 0)
        cursor = snapToGraphemeBoundary(target)
        anchor = cursor
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
        guard !isSecure && hasSelection else { return nil }
        return selectedText
    }

    public mutating func cut() -> String? {
        guard !isSecure && hasSelection else { return nil }
        let out = selectedText
        insert("")
        return out
    }

    public mutating func paste(_ pasted: String) {
        insert(pasted)
    }

    /// Replaces any revealed secret with bullet masks and hides the field again (`TextEdit::conceal`).
    public mutating func conceal() {
        isRevealed = false
        guard isSecure else { return }
        text = displayString
        let end = text.utf8.count
        cursor = end
        anchor = end
        marks.removeAll()
        preedit = nil
        undoStack.removeAll()
        redoStack.removeAll()
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard !isSecure, let prev = undoStack.popLast() else { return false }
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
        guard !isSecure, let next = redoStack.popLast() else { return false }
        undoStack.append(Snapshot(text: text, cursor: cursor, anchor: anchor, marks: marks))
        text = next.text
        cursor = next.cursor
        anchor = next.anchor
        marks = next.marks
        preedit = nil
        preeditClauses.removeAll()
        return true
    }

    // MARK: - IME Preedit

    public mutating func setPreedit(
        _ preeditText: String,
        cursor cursorRange: Range<Int>? = nil,
        clauses: [ImeClause] = []
    ) {
        guard !isSecure else {
            preedit = nil
            preeditClauses.removeAll()
            return
        }
        if preeditText.isEmpty {
            preedit = nil
            preeditClauses.removeAll()
        } else {
            let validUTF8 = Self.utf8ScalarBoundarySet(in: preeditText)
            let clampedCursor = cursorRange.map { r in
                let lo = min(max(0, r.lowerBound), preeditText.utf8.count)
                let hi = min(max(lo, r.upperBound), preeditText.utf8.count)
                return lo..<hi
            }
            let fits: (ImeClause) -> Bool = { c in
                c.utf8Range.lowerBound < c.utf8Range.upperBound &&
                c.utf8Range.upperBound <= preeditText.utf8.count &&
                validUTF8.contains(c.utf8Range.lowerBound) &&
                validUTF8.contains(c.utf8Range.upperBound)
            }
            preedit = (preeditText, clampedCursor)
            preeditClauses = clauses.allSatisfy(fits) ? clauses : []
        }
    }

    public mutating func commitPreedit(_ committed: String) {
        preedit = nil
        preeditClauses.removeAll()
        guard !isSecure else { return }
        insert(committed)
    }

    public mutating func cancelPreedit() {
        preedit = nil
        preeditClauses.removeAll()
    }

    /// Commits any open preedit text if present (`Event::Finish` in `edit/ime.rs`), returning whether committed.
    @discardableResult
    public mutating func finishPreedit() -> Bool {
        guard let active = preedit, !active.text.isEmpty else {
            preedit = nil
            preeditClauses.removeAll()
            return false
        }
        let committed = active.text
        commitPreedit(committed)
        return true
    }

    /// Returns effective IME clauses for the active preedit (`Composition::clauses` in `edit/ime.rs`).
    public func effectivePreeditClauses() -> [ImeClause] {
        guard let active = preedit, !active.text.isEmpty else { return [] }
        if !preeditClauses.isEmpty { return preeditClauses }
        let len = active.text.utf8.count
        if let c = active.cursor, c.lowerBound < c.upperBound, c.upperBound <= len {
            return [
                ImeClause(utf8Range: 0..<c.lowerBound, isTarget: false),
                ImeClause(utf8Range: c.lowerBound..<c.upperBound, isTarget: true),
                ImeClause(utf8Range: c.upperBound..<len, isTarget: false),
            ].filter { !$0.utf8Range.isEmpty }
        }
        return [ImeClause(utf8Range: 0..<len, isTarget: false)]
    }

    /// Publishes surrounding paragraph context (at most `maxContextBytes` per side) for IME reconversion.
    /// Always returns `nil` when `isSecure == true`.
    public func imeTextSnapshot(maxContextBytes: Int = 1024) -> ImeText? {
        guard !isSecure else { return nil }
        return ImeUTF16Bridge.imeTextSlice(
            text: text,
            selectionUTF8: selectedUTF8Range,
            maxContextBytes: maxContextBytes
        )
    }

    /// Applies an OS `ImeEvent` (`rune::edit::ime::step`).
    @discardableResult
    public mutating func applyIme(_ event: ImeEvent) -> EditOutcome {
        switch event {
        case let .preedit(str, cursorUTF8, clauses):
            setPreedit(str, cursor: cursorUTF8, clauses: clauses)
            return .navigation
        case let .commit(str):
            if isSecure {
                preedit = nil
                preeditClauses.removeAll()
                insert(str)
                return .modified
            }
            let prev = text
            commitPreedit(str)
            return text != prev ? .modified : .navigation
        case let .select(range):
            guard preedit == nil, !isSecure else { return .ignored }
            let start = snapToGraphemeBoundary(range.lowerBound)
            let end = snapToGraphemeBoundary(range.upperBound)
            anchor = start
            cursor = end
            return .navigation
        case .enabled, .disabled:
            return .ignored
        }
    }

    private static func utf8ScalarBoundarySet(in s: String) -> Set<Int> {
        var set = Set<Int>()
        var offset = 0
        set.insert(0)
        for scalar in s.unicodeScalars {
            offset += scalar.utf8.count
            set.insert(offset)
        }
        return set
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
        didRequestBlur = false
        let shift = ev.mods.shift
        let alt = ev.mods.alt

        if let ctrlLetter = ev.controlBinding {
            switch ctrlLetter {
            case "a":
                moveLeft(extend: shift, toLineBoundary: true)
                return .navigation
            case "e":
                moveRight(extend: shift, toLineBoundary: true)
                return .navigation
            case "b":
                moveLeft(extend: shift)
                return .navigation
            case "f":
                moveRight(extend: shift)
                return .navigation
            case "p":
                moveUp(extend: shift)
                return .navigation
            case "n":
                moveDown(extend: shift)
                return .navigation
            case "d":
                let before = text
                deleteForward(word: false)
                return text != before ? .modified : .navigation
            case "h":
                let before = text
                backspace(word: false)
                return text != before ? .modified : .navigation
            case "k":
                let end = lineEnd(for: cursor)
                if cursor < end || hasSelection {
                    if !hasSelection { anchor = end }
                    insert("")
                    return .modified
                }
                return .ignored
            default:
                break
            }
        }

        if ev.mods.primaryCommand && ev.mods.primaryAlone {
            if ev.isCommand("a") {
                selectAll()
                return .navigation
            }
            if ev.isCommand("z") {
                if shift {
                    return redo() ? .modified : .ignored
                } else {
                    return undo() ? .modified : .ignored
                }
            }
            if ev.isCommand("y") {
                return redo() ? .modified : .ignored
            }
            if ev.isCommand("c") {
                if let copied = copy() { return .copy(copied) }
                return .ignored
            }
            if ev.isCommand("x") {
                if let cutStr = cut() { return .copy(cutStr) }
                return .ignored
            }
            switch ev.key {
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
            case .enter:
                if multiline && isSecure {
                    return .submit
                }
                return .ignored
            default:
                return .ignored
            }
        }

        // AltGr / extra modifiers alongside Cmd other than Shift leave primary commands untouched.
        if ev.mods.primaryCommand {
            return .ignored
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
            if preedit != nil {
                return .ignored
            }
            if !multiline {
                return .submit
            }
            if isSecure {
                if ev.mods.ctrl || ev.mods.cmd {
                    return .submit
                }
                insert("\n")
                return .modified
            }
            if shift || alt {
                insert("\n")
                return .modified
            }
            return .submit

        case .escape:
            if preedit != nil {
                cancelPreedit()
                return .modified
            }
            didRequestBlur = true
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

    /// Masked display string (`"••••••••••••"` for hidden multi-line, `•` per scalar for hidden single-line).
    public var displayString: String {
        guard isSecure && !isRevealed else { return text }
        if multiline {
            return Self.multilineSecureMask
        }
        return String(repeating: "•", count: text.unicodeScalars.count)
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

    private func sanitizeInput(_ s: String) -> String {
        if multiline {
            return s.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
        }
        return s.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\u{2028}", with: " ")
    }

    private func prevBackspaceBoundary(from offset: Int) -> Int {
        let start = prevGraphemeBoundary(from: offset)
        let lo = stringIndex(forUTF8Offset: start)
        let hi = stringIndex(forUTF8Offset: offset)
        let cluster = text[lo..<hi]
        if cluster == "\r\n" {
            return start
        }
        let isEmojiSeq = cluster.unicodeScalars.contains { scalar in
            let v = scalar.value
            return v == 0xFE0F
                || v == 0x20E3
                || (0x1F3FB...0x1F3FF).contains(v)
                || (0x1F1E6...0x1F1FF).contains(v)
                || (0xE0020...0xE007F).contains(v)
        } || (cluster.unicodeScalars.contains { $0.value == 0x200D } && cluster.unicodeScalars.contains {
            $0.properties.isEmojiPresentation || $0.properties.isEmoji
        })
        if isEmojiSeq {
            return start
        }
        guard offset > 0 else { return 0 }
        let scalarIdx = text.unicodeScalars.index(before: hi)
        return text.utf8.distance(from: text.utf8.startIndex, to: scalarIdx)
    }

    private func prevWordBoundary(from offset: Int) -> Int {
        if isSecure && !isRevealed { return 0 }
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
        if isSecure && !isRevealed { return text.utf8.count }
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
        guard !isSecure else { return }
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
