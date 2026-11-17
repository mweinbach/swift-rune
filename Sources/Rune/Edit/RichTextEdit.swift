import Foundation
#if canImport(simd)
import simd
#endif

// MARK: - Rich Text Model (crates/rune/src/edit/model.rs)

/// Inline formatting mark stored alongside `TextEdit` (`rune::Mark`).
public enum RichMark: Sendable, Hashable {
    case bold
    case italic
    case underline
    case strike
    case code
    case link(String)
    /// Atomic inline pill (`@file`, `@agent`, attachment) carrying an app id; its text is its label.
    case pill(String)

    public struct AllowMask: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let bold      = AllowMask(rawValue: 1 << 0)
        public static let italic    = AllowMask(rawValue: 1 << 1)
        public static let underline = AllowMask(rawValue: 1 << 2)
        public static let strike    = AllowMask(rawValue: 1 << 3)
        public static let code      = AllowMask(rawValue: 1 << 4)
        public static let link      = AllowMask(rawValue: 1 << 5)
        public static let pill      = AllowMask(rawValue: 1 << 6)
        public static let all       = AllowMask(rawValue: 0x7F)
    }

    public func sameKind(_ other: RichMark) -> Bool {
        switch (self, other) {
        case (.bold, .bold), (.italic, .italic), (.underline, .underline),
             (.strike, .strike), (.code, .code), (.link, .link), (.pill, .pill):
            return true
        default:
            return false
        }
    }

    public var linkURL: String? {
        if case let .link(url) = self { return url }
        return nil
    }

    public var pillID: String? {
        if case let .pill(id) = self { return id }
        return nil
    }

    public var isPill: Bool {
        if case .pill = self { return true }
        return false
    }

    public var kindOrder: UInt8 {
        switch self {
        case .bold: return 0
        case .italic: return 1
        case .underline: return 2
        case .strike: return 3
        case .code: return 4
        case .link: return 5
        case .pill: return 6
        }
    }

    internal var allowBit: AllowMask {
        AllowMask(rawValue: 1 << kindOrder)
    }
}

/// Non-empty UTF-8 byte range `[start, end)` in `TextEdit.text` carrying an inline `RichMark` (`rune::MarkRange`).
public struct RichMarkRange: Sendable, Hashable {
    public var start: Int
    public var end: Int
    public var mark: RichMark

    public init(start: Int, end: Int, mark: RichMark) {
        self.start = start
        self.end = end
        self.mark = mark
    }

    public init(_ range: Range<Int>, _ mark: RichMark) {
        self.start = range.lowerBound
        self.end = range.upperBound
        self.mark = mark
    }

    public var range: Range<Int> { start..<end }
}

/// Paragraph-level block attribute for a `\n`-delimited line in `TextEdit` (`rune::Block`).
public enum Block: Sendable, Hashable {
    case paragraph
    case bullet(UInt8)
    case numbered(UInt8)
    case quote
    case code

    public static let maxListLevel: UInt8 = 3

    public struct AllowMask: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let paragraph = AllowMask(rawValue: 1 << 0)
        public static let bullet    = AllowMask(rawValue: 1 << 1)
        public static let numbered  = AllowMask(rawValue: 1 << 2)
        public static let quote     = AllowMask(rawValue: 1 << 3)
        public static let code      = AllowMask(rawValue: 1 << 4)
        public static let all       = AllowMask(rawValue: 0x1F)
    }

    public var isList: Bool {
        switch self {
        case .bullet, .numbered: return true
        default: return false
        }
    }

    public var listLevel: UInt8? {
        switch self {
        case let .bullet(l), let .numbered(l): return l
        default: return nil
        }
    }

    public func withLevel(_ level: UInt8) -> Block {
        let clamped = min(level, Self.maxListLevel)
        switch self {
        case .bullet: return .bullet(clamped)
        case .numbered: return .numbered(clamped)
        default: return self
        }
    }

    public func sameKind(_ other: Block) -> Bool {
        switch (self, other) {
        case (.paragraph, .paragraph), (.bullet, .bullet),
             (.numbered, .numbered), (.quote, .quote), (.code, .code):
            return true
        default:
            return false
        }
    }

    internal var kindOrder: UInt8 {
        switch self {
        case .paragraph: return 0
        case .bullet: return 1
        case .numbered: return 2
        case .quote: return 3
        case .code: return 4
        }
    }

    internal var allowBit: AllowMask {
        AllowMask(rawValue: 1 << kindOrder)
    }

    /// Left indentation in logical points before pixel scaling (`Block::indent_pt`).
    public func indentPt(fontSize: Float) -> Float {
        let unit = max(18.0, (fontSize * 1.45).rounded())
        switch self {
        case .paragraph:
            return 0.0
        case let .bullet(l), let .numbered(l):
            return unit * Float(min(l, Self.maxListLevel) + 1)
        case .quote:
            return max(14.0, (fontSize * 1.1).rounded())
        case .code:
            return max(10.0, (fontSize * 0.75).rounded())
        }
    }
}

/// Paragraph slice of a `TextEdit` (`rune::ParagraphInfo`).
public struct ParagraphInfo: Sendable, Equatable {
    public var index: Int
    public var range: Range<Int>
    public var block: Block
    public var softBreak: Bool

    public init(index: Int, range: Range<Int>, block: Block, softBreak: Bool) {
        self.index = index
        self.range = range
        self.block = block
        self.softBreak = softBreak
    }
}

/// Visual palette for rich marks and block attributes inside a rich field (`rune::RichStyle`).
public struct RichStyle: Sendable, Equatable {
    public var codeFg: Color?
    public var codeBg: Color
    public var codeBlockBg: Color
    public var link: Color
    public var quoteBar: Color
    public var marker: Color?

    public init(
        codeFg: Color? = nil,
        codeBg: Color = oklcha(0.55, 0.02, 260.0, 0.16),
        codeBlockBg: Color = oklcha(0.5, 0.02, 260.0, 0.12),
        link: Color = oklch(0.68, 0.16, 250.0),
        quoteBar: Color = oklcha(0.6, 0.04, 255.0, 0.45),
        marker: Color? = nil
    ) {
        self.codeFg = codeFg
        self.codeBg = codeBg
        self.codeBlockBg = codeBlockBg
        self.link = link
        self.quoteBar = quoteBar
        self.marker = marker
    }
}

// MARK: - Pending Typing Style & Visual Caret Motion State

/// Pending inline marks armed at a specific `(anchor, cursor)` (`crates/rune/src/edit/typing.rs`).
internal enum TypingStyle: Sendable, Equatable {
    case inherited
    case armed(anchor: Int, focus: Int, marks: [RichMark])

    func at(anchor: Int, cursor: Int) -> [RichMark]? {
        if case let .armed(a, f, marks) = self, a == anchor && f == cursor {
            return marks
        }
        return nil
    }

    mutating func takeAt(anchor: Int, cursor: Int) -> [RichMark]? {
        let cur = self
        self = .inherited
        if case let .armed(a, f, marks) = cur, a == anchor && f == cursor {
            return marks
        }
        return nil
    }
}

/// Kept horizontal goal for consecutive vertical caret motion (`crates/rune/src/edit/caret_motion.rs`).
public enum CaretColumn: Sendable, Equatable {
    case free
    case kept(Float)

    public var goal: Float? {
        if case let .kept(x) = self { return x }
        return nil
    }
}

/// Downstream/upstream affinity at a soft-wrapped visual line boundary (`parley::Affinity`).
public enum TextAffinity: Sendable, Hashable {
    case downstream
    case upstream
}

// MARK: - Rich Text Editing API on TextEdit

extension TextEdit {
    /// Constructs a `TextEdit` from raw parts (syncing blocks, pills, and marks invariants).
    public static func fromRichParts(
        text: String,
        richMarks: [RichMarkRange] = [],
        blocks: [Block] = [],
        softBreaks: [Int] = [],
        multiline: Bool = true
    ) -> TextEdit {
        var edit = TextEdit(text, multiline: multiline)
        edit.isRichEnabled = true
        edit.richMarks = richMarks
        edit.blocks = blocks
        edit.softBreaks = softBreaks
        edit.syncRichInvariants()
        let end = edit.text.utf8.count
        edit.setSelectionRaw(anchor: end, cursor: end)
        return edit
    }

    /// Replaces the soft-break paragraph flags without recording an undo step (`edit/rich.rs`, `set_soft_breaks`).
    public mutating func setSoftBreaks(_ breaks: [Int]) {
        softBreaks = breaks
        syncRichInvariants()
    }

    /// Builder variant of `setSoftBreaks(_:)` (`edit/rich.rs`, `with_soft_breaks`).
    public func withSoftBreaks(_ breaks: [Int]) -> TextEdit {
        var copy = self
        copy.setSoftBreaks(breaks)
        return copy
    }

    /// Enables rich formatting marks/blocks fluently.
    public func rich(_ enabled: Bool = true) -> TextEdit {
        var copy = self
        copy.isRichEnabled = enabled
        copy.multiline = true
        copy.syncRichInvariants()
        return copy
    }

    /// Limits which inline `RichMark` kinds may be stored or toggled.
    public func allowRichMarks(_ mask: RichMark.AllowMask) -> TextEdit {
        var copy = self
        copy.allowedRichMarks = mask
        copy.syncRichInvariants()
        return copy
    }

    /// Limits which `Block` kinds may be applied.
    public func allowBlocks(_ mask: Block.AllowMask) -> TextEdit {
        var copy = self
        copy.allowedBlocks = mask
        copy.syncRichInvariants()
        return copy
    }

    public func allowsRichMark(_ mark: RichMark) -> Bool {
        guard isRichEnabled else { return false }
        guard let allowedRichMarks else { return true }
        return allowedRichMarks.contains(mark.allowBit)
    }

    public func allowsBlock(_ block: Block) -> Bool {
        guard isRichEnabled else { return false }
        guard let allowedBlocks else { return true }
        return allowedBlocks.contains(block.allowBit)
    }

    /// Ordered pill byte ranges and IDs currently in `text`.
    public var pills: [(range: Range<Int>, id: String)] {
        let len = text.utf8.count
        return richMarks.compactMap { m in
            guard let id = m.mark.pillID else { return nil }
            guard m.start >= 0 && m.start < m.end && m.end <= len else { return nil }
            let lo = stringIndex(forUTF8Offset: m.start)
            let hi = stringIndex(forUTF8Offset: m.end)
            guard !text[lo..<hi].contains("\n") else { return nil }
            return (m.start..<m.end, id)
        }
    }

    internal func clampScalarBoundary(_ utf8Offset: Int) -> Int {
        let clamped = min(max(0, utf8Offset), text.utf8.count)
        let idx = text.utf8.index(text.utf8.startIndex, offsetBy: clamped)
        let aligned = idx.samePosition(in: text.unicodeScalars) ?? {
            var scan = idx
            while scan > text.utf8.startIndex && scan.samePosition(in: text.unicodeScalars) == nil {
                scan = text.utf8.index(before: scan)
            }
            return scan
        }()
        return text.utf8.distance(from: text.utf8.startIndex, to: aligned)
    }

    internal func pillBefore(_ utf8Offset: Int) -> Int? {
        richMarks.first { $0.mark.isPill && $0.start < utf8Offset && utf8Offset <= $0.end }?.start
    }

    internal func pillAfter(_ utf8Offset: Int) -> Int? {
        richMarks.first { $0.mark.isPill && $0.start <= utf8Offset && utf8Offset < $0.end }?.end
    }

    internal func pillAround(_ utf8Offset: Int) -> (Int, Int)? {
        if let hit = richMarks.first(where: { $0.mark.isPill && $0.start < utf8Offset && utf8Offset < $0.end }) {
            return (hit.start, hit.end)
        }
        return nil
    }

    internal func outOfPill(_ utf8Offset: Int, forward: Bool) -> Int {
        if let (s, e) = pillAround(utf8Offset) {
            return forward ? e : s
        }
        return utf8Offset
    }

    internal func coverPills(_ a: Int, _ b: Int) -> (Int, Int) {
        if a == b {
            let p = outOfPill(a, forward: true)
            return (p, p)
        }
        let lo = min(a, b)
        let hi = max(a, b)
        return (outOfPill(lo, forward: false), outOfPill(hi, forward: true))
    }

    internal mutating func snapToPills() {
        guard richMarks.contains(where: { $0.mark.isPill }) else { return }
        if anchor == cursor {
            if let (s, e) = pillAround(cursor) {
                let to = (cursor - s < e - cursor) ? s : e
                setSelectionRaw(anchor: to, cursor: to)
            }
        } else {
            let forward = cursor > anchor
            let nextA = outOfPill(anchor, forward: !forward)
            let nextC = outOfPill(cursor, forward: forward)
            setSelectionRaw(anchor: nextA, cursor: nextC)
        }
    }

    /// Synchronizes `blocks`, `softBreaks`, `richMarks`, `typingStyle`, and pill clamping.
    public mutating func syncRichInvariants() {
        let clampedA = clampScalarBoundary(anchor)
        let clampedC = clampScalarBoundary(cursor)
        if clampedA != anchor || clampedC != cursor {
            setSelectionRaw(anchor: clampedA, cursor: clampedC)
        }
        if isSecure {
            richMarks.removeAll()
            blocks.removeAll()
            softBreaks.removeAll()
            typingStyle = .inherited
            return
        }
        let lineCount = 1 + text.utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        if blocks.count < lineCount {
            blocks.append(contentsOf: repeatElement(.paragraph, count: lineCount - blocks.count))
        } else if blocks.count > lineCount {
            blocks.removeLast(blocks.count - lineCount)
        }
        if let allowedBlocks {
            for i in blocks.indices where !allowedBlocks.contains(blocks[i].allowBit) {
                blocks[i] = .paragraph
            }
        }
        softBreaks = Array(Set(softBreaks.filter { $0 > 0 && $0 < lineCount })).sorted()
        normalizeRichMarks()
        snapToPills()

        let anchorLine = lineIndexOfUTF8(anchor)
        let anchorInCode = anchorLine < blocks.count && blocks[anchorLine] == .code
        if typingStyle.at(anchor: anchor, cursor: cursor) == nil || anchorInCode {
            typingStyle = .inherited
        } else if let allowedRichMarks, case let .armed(a, f, ms) = typingStyle {
            typingStyle = .armed(anchor: a, focus: f, marks: ms.filter { allowedRichMarks.contains($0.allowBit) })
        }
    }

    internal mutating func normalizeRichMarks() {
        if let allowedRichMarks {
            richMarks.removeAll { !allowedRichMarks.contains($0.mark.allowBit) }
        }
        guard !richMarks.isEmpty else { return }

        let len = text.utf8.count
        for i in richMarks.indices {
            richMarks[i].start = clampScalarBoundary(richMarks[i].start)
            richMarks[i].end = clampScalarBoundary(richMarks[i].end)
        }
        richMarks.removeAll { $0.start >= $0.end || $0.end > len }

        // Strip inline marks from `Block.code` paragraphs.
        if blocks.contains(.code) {
            var codeRanges: [Range<Int>] = []
            var lineStart = 0
            var idx = 0
            for (i, b) in text.utf8.enumerated() {
                if b == 0x0A {
                    if idx < blocks.count && blocks[idx] == .code {
                        codeRanges.append(lineStart..<(i + 1))
                    }
                    lineStart = i + 1
                    idx += 1
                }
            }
            if idx < blocks.count && blocks[idx] == .code {
                codeRanges.append(lineStart..<len)
            }
            if !codeRanges.isEmpty {
                var cut: [RichMarkRange] = []
                cut.reserveCapacity(richMarks.count)
                for m in richMarks {
                    var start = m.start
                    for cr in codeRanges {
                        if cr.upperBound <= start { continue }
                        if cr.lowerBound >= m.end { break }
                        if start < cr.lowerBound {
                            cut.append(RichMarkRange(start: start, end: cr.lowerBound, mark: m.mark))
                        }
                        start = max(start, cr.upperBound)
                    }
                    if start < m.end {
                        cut.append(RichMarkRange(start: start, end: m.end, mark: m.mark))
                    }
                }
                richMarks = cut
            }
        }

        // Partition by mark kind order `0...6`.
        var byKind: [[RichMarkRange]] = Array(repeating: [], count: 7)
        for m in richMarks where m.start < m.end {
            byKind[Int(m.mark.kindOrder)].append(m)
        }

        var merged: [RichMarkRange] = []
        for (kindIdx, var list) in byKind.enumerated() where !list.isEmpty {
            if kindIdx == 6 {
                // Pills never span newlines and never overlap/merge.
                list.sort { ($0.start, $0.end) < ($1.start, $1.end) }
                var end = 0
                for m in list {
                    if m.start >= end {
                        let lo = stringIndex(forUTF8Offset: m.start)
                        let hi = stringIndex(forUTF8Offset: m.end)
                        if !text[lo..<hi].contains("\n") {
                            end = m.end
                            merged.append(m)
                        }
                    }
                }
            } else if kindIdx == 5 {
                // Links: later link overwrites overlapping slice of earlier links, adjacent identical links merge.
                var resolved: [RichMarkRange] = []
                for link in list {
                    var nextResolved: [RichMarkRange] = []
                    for old in resolved {
                        if old.end <= link.start || old.start >= link.end {
                            nextResolved.append(old)
                        } else {
                            if old.start < link.start {
                                nextResolved.append(RichMarkRange(start: old.start, end: link.start, mark: old.mark))
                            }
                            if old.end > link.end {
                                nextResolved.append(RichMarkRange(start: link.end, end: old.end, mark: old.mark))
                            }
                        }
                    }
                    nextResolved.append(link)
                    resolved = nextResolved
                }
                resolved.sort { ($0.start, $0.end) < ($1.start, $1.end) }
                if var cur = resolved.first {
                    for m in resolved.dropFirst() {
                        if m.mark == cur.mark && m.start <= cur.end {
                            cur.end = max(cur.end, m.end)
                        } else {
                            merged.append(cur)
                            cur = m
                        }
                    }
                    merged.append(cur)
                }
            } else {
                list.sort { ($0.start, $0.end) < ($1.start, $1.end) }
                if var cur = list.first {
                    for m in list.dropFirst() {
                        if m.start <= cur.end {
                            cur.end = max(cur.end, m.end)
                        } else {
                            merged.append(cur)
                            cur = m
                        }
                    }
                    merged.append(cur)
                }
            }
        }

        merged.sort { ($0.start, $0.end, $0.mark.kindOrder) < ($1.start, $1.end, $1.mark.kindOrder) }
        richMarks = merged
    }

    internal func inheritedRichMarks(at pos: Int) -> [RichMark] {
        guard !richMarks.isEmpty else { return [] }
        let lineIdx = lineIndexOfUTF8(pos)
        if lineIdx < blocks.count && blocks[lineIdx] == .code {
            return []
        }
        let lineStart = lineRangeUTF8(of: lineIdx).lowerBound
        guard pos > lineStart else { return [] }
        var out: [RichMark] = []
        for m in richMarks {
            if m.start < pos && pos <= m.end && !m.mark.isPill && !out.contains(where: { $0.sameKind(m.mark) }) {
                out.append(m.mark)
            }
        }
        return out
    }

    private func rangeHasRichMark(_ start: Int, _ end: Int, _ mark: RichMark) -> Bool {
        guard start < end else { return false }
        let anyLink = (mark == .link(""))
        return richMarks.contains { m in
            let matches: Bool
            if anyLink {
                matches = m.mark.linkURL != nil
            } else {
                matches = (m.mark == mark)
            }
            return matches && m.start <= start && end <= m.end
        }
    }

    /// Active inline marks at the caret (including pending typing style) or covering the whole selection.
    public func activeRichMarks() -> [RichMark] {
        let range = selectedUTF8Range
        if range.isEmpty {
            let lineIdx = lineIndexOfUTF8(range.lowerBound)
            if lineIdx < blocks.count && blocks[lineIdx] == .code {
                return []
            }
            if let armed = typingStyle.at(anchor: anchor, cursor: cursor) {
                return armed
            }
            return inheritedRichMarks(at: range.lowerBound)
        }
        var out: [RichMark] = []
        for m in richMarks {
            if m.start <= range.lowerBound && range.upperBound <= m.end && !out.contains(m.mark) {
                out.append(m.mark)
            }
        }
        return out
    }

    /// Whether `mark` is active at caret or covers whole selection (`RichMark.link("")` checks any link).
    public func hasRichMark(_ mark: RichMark) -> Bool {
        let anyLink = (mark == .link(""))
        return activeRichMarks().contains { existing in
            anyLink ? (existing.linkURL != nil) : (existing == mark)
        }
    }

    /// Active `RichMark.link` URL at caret or covering whole selection.
    public var activeLink: String? {
        let range = selectedUTF8Range
        if range.isEmpty {
            if let armed = typingStyle.at(anchor: anchor, cursor: cursor) {
                return armed.compactMap(\.linkURL).first
            }
            let lineIdx = lineIndexOfUTF8(range.lowerBound)
            if (lineIdx < blocks.count && blocks[lineIdx] == .code) || range.lowerBound <= lineRangeUTF8(of: lineIdx).lowerBound {
                return nil
            }
            return richMarks.first(where: { $0.start < range.lowerBound && range.lowerBound <= $0.end && $0.mark.linkURL != nil })?.mark.linkURL
        }
        return richMarks.first(where: { $0.start <= range.lowerBound && range.upperBound <= $0.end && $0.mark.linkURL != nil })?.mark.linkURL
    }

    private mutating func editTypingStyle(at pos: Int, _ body: (inout [RichMark]) -> Void) {
        let lineIdx = lineIndexOfUTF8(pos)
        if lineIdx < blocks.count && blocks[lineIdx] == .code { return }
        var active = activeRichMarks()
        body(&active)
        typingStyle = .armed(anchor: anchor, focus: cursor, marks: active)
    }

    public mutating func toggleMark(_ mark: RichMark) {
        guard !isSecure && allowsRichMark(mark) else { return }
        syncRichInvariants()
        let r = selectedUTF8Range
        if r.isEmpty {
            if !mark.isPill {
                editTypingStyle(at: r.lowerBound) { active in
                    if let idx = active.firstIndex(where: { $0.sameKind(mark) }) {
                        if active[idx] == mark || mark == .link("") {
                            active.remove(at: idx)
                        } else {
                            active[idx] = mark
                        }
                    } else {
                        active.append(mark)
                    }
                }
            }
            return
        }
        if rangeHasRichMark(r.lowerBound, r.upperBound, mark) {
            removeMark(mark)
        } else {
            setMark(mark)
        }
    }

    public mutating func setMark(_ mark: RichMark) {
        guard !isSecure && allowsRichMark(mark) else { return }
        syncRichInvariants()
        let r = selectedUTF8Range
        if r.isEmpty {
            if !mark.isPill {
                editTypingStyle(at: r.lowerBound) { active in
                    if let idx = active.firstIndex(where: { $0.sameKind(mark) }) {
                        active[idx] = mark
                    } else {
                        active.append(mark)
                    }
                }
            }
            return
        }
        let before = captureUndoBaseline()
        if mark.isPill {
            richMarks.removeAll { $0.mark.isPill && $0.end > r.lowerBound && $0.start < r.upperBound }
        }
        richMarks.append(RichMarkRange(start: r.lowerBound, end: r.upperBound, mark: mark))
        typingStyle = .inherited
        normalizeRichMarks()
        recordUndoChange(before: before, kind: .other)
    }

    public mutating func removeMark(_ mark: RichMark) {
        guard !isSecure && isRichEnabled else { return }
        syncRichInvariants()
        let r = selectedUTF8Range
        if r.isEmpty {
            var active = activeRichMarks()
            active.removeAll { $0.sameKind(mark) }
            typingStyle = .armed(anchor: anchor, focus: cursor, marks: active)
            return
        }
        let before = captureUndoBaseline()
        var next: [RichMarkRange] = []
        next.reserveCapacity(richMarks.count)
        for m in richMarks {
            if !m.mark.sameKind(mark) || m.end <= r.lowerBound || m.start >= r.upperBound {
                next.append(m)
            } else if m.mark.isPill {
                // Pill drops whole; label text remains.
            } else {
                if m.start < r.lowerBound {
                    next.append(RichMarkRange(start: m.start, end: r.lowerBound, mark: m.mark))
                }
                if m.end > r.upperBound {
                    next.append(RichMarkRange(start: r.upperBound, end: m.end, mark: m.mark))
                }
            }
        }
        richMarks = next
        typingStyle = .inherited
        normalizeRichMarks()
        recordUndoChange(before: before, kind: .other)
    }

    public mutating func setLink(_ url: String?) {
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = trimmed, !u.isEmpty {
            setMark(.link(u))
        } else {
            removeMark(.link(""))
        }
    }

    /// Inserts an atomic `RichMark.pill(id)` replacing the selection, collapsing caret after it.
    public mutating func insertPill(id: String, label: String) {
        replaceWithPill(range: selectedUTF8Range, id: id, label: label)
    }

    /// Replaces `range` with `label` marked as `RichMark.pill(id)`.
    public mutating func replaceWithPill(range: Range<Int>, id: String, label: String) {
        let cleanLabel = String(label.map { c in
            (c.isNewline || c.asciiValue.map({ $0 < 0x20 || $0 == 0x7F }) == true || c == "\u{2028}" || c == "\u{2029}") ? " " : c
        })
        guard !isSecure && !cleanLabel.isEmpty else { return }
        syncRichInvariants()
        let before = captureUndoBaseline()
        let lo = clampScalarBoundary(min(range.lowerBound, range.upperBound))
        let hi = clampScalarBoundary(max(range.lowerBound, range.upperBound))
        let covered = coverPills(lo, hi)
        typingStyle = .inherited
        applyRichReplace(
            range: covered.0..<covered.1,
            replacement: cleanLabel,
            insertedMarks: [],
            newLineBlock: nil,
            markNewLinesSoft: false
        )
        let pillEnd = covered.0 + cleanLabel.utf8.count
        richMarks.append(RichMarkRange(start: covered.0, end: pillEnd, mark: .pill(id)))
        normalizeRichMarks()
        setSelectionRaw(anchor: pillEnd, cursor: pillEnd)
        recordUndoChange(before: before, kind: .other)
    }

    // MARK: - Rich Replace Engine (text + richMarks + blocks + softBreaks)

    internal mutating func applyRichReplace(
        range: Range<Int>,
        replacement s: String,
        insertedMarks: [RichMark],
        newLineBlock: Block?,
        markNewLinesSoft: Bool
    ) {
        let a = range.lowerBound
        let b = range.upperBound
        let delLen = b - a
        let insLen = s.utf8.count

        if richMarks.isEmpty && insertedMarks.isEmpty && softBreaks.isEmpty && !markNewLinesSoft
            && (newLineBlock == nil || newLineBlock == .paragraph)
            && blocks.allSatisfy({ $0 == .paragraph }) {
            let removed = text.utf8[text.utf8.index(text.utf8.startIndex, offsetBy: a)..<text.utf8.index(text.utf8.startIndex, offsetBy: b)]
                .reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
            let added = s.utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
            var nextText = text
            let sIdx = nextText.utf8.index(nextText.utf8.startIndex, offsetBy: a)
            let eIdx = nextText.utf8.index(nextText.utf8.startIndex, offsetBy: b)
            nextText.replaceSubrange(sIdx..<eIdx, with: s)
            setTextStorageRaw(nextText)
            let nextLines = max(1, blocks.count + added - removed)
            blocks = Array(repeating: .paragraph, count: nextLines)
            setSelectionRaw(anchor: a + insLen, cursor: a + insLen)
            return
        }

        let lineA = lineIndexOfUTF8(a)
        let lineB = lineIndexOfUTF8(b)
        let lineARange = lineRangeUTF8(of: lineA)
        let lineBRange = lineRangeUTF8(of: lineB)

        let mergeTakeB = lineA < lineB && lineARange.isEmpty && a == lineARange.lowerBound && b == lineBRange.lowerBound
        let mergedBlock = mergeTakeB
            ? (lineB < blocks.count ? blocks[lineB] : .paragraph)
            : (lineA < blocks.count ? blocks[lineA] : .paragraph)
        let mergedSoft = mergeTakeB
            ? (softBreaks.contains(lineB) && lineA > 0)
            : softBreaks.contains(lineA)

        let removedLines = lineB - lineA
        let addedLines = s.utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        let nextLineBlk = newLineBlock ?? (mergedBlock == .code ? Block.code : Block.paragraph)

        if removedLines > 0 {
            let rmHi = min(lineB + 1, blocks.count)
            if lineA + 1 < rmHi {
                blocks.removeSubrange((lineA + 1)..<rmHi)
            }
        }
        if lineA < blocks.count {
            blocks[lineA] = mergedBlock
        }
        if addedLines > 0 {
            let insertAt = min(lineA + 1, blocks.count)
            blocks.insert(contentsOf: repeatElement(nextLineBlk, count: addedLines), at: insertAt)
        }

        var nextSoft: [Int] = []
        for sb in softBreaks {
            if sb < lineA {
                nextSoft.append(sb)
            } else if sb > lineB {
                let shifted = sb - removedLines + addedLines
                if shifted > 0 { nextSoft.append(shifted) }
            }
        }
        if mergedSoft && lineA > 0 {
            nextSoft.append(lineA)
        }
        if markNewLinesSoft && addedLines > 0 {
            for k in 1...addedLines {
                nextSoft.append(lineA + k)
            }
        }
        softBreaks = nextSoft

        var updatedMarks: [RichMarkRange] = []
        updatedMarks.reserveCapacity(richMarks.count + insertedMarks.count)
        for m in richMarks {
            if m.end <= a {
                updatedMarks.append(m)
            } else if m.start >= b {
                updatedMarks.append(RichMarkRange(start: m.start - delLen + insLen, end: m.end - delLen + insLen, mark: m.mark))
            } else if m.mark.isPill {
                // Cutting into a pill drops the pill mark.
            } else {
                if m.start < a {
                    updatedMarks.append(RichMarkRange(start: m.start, end: a, mark: m.mark))
                }
                if m.end > b {
                    updatedMarks.append(RichMarkRange(start: a + insLen, end: m.end - delLen + insLen, mark: m.mark))
                }
            }
        }
        if insLen > 0 {
            for im in insertedMarks where !im.isPill {
                if s == "\n" {
                    let wasInside = updatedMarks.contains { $0.mark == im && $0.start >= a + insLen }
                    if !wasInside { continue }
                }
                updatedMarks.append(RichMarkRange(start: a, end: a + insLen, mark: im))
            }
        }
        richMarks = updatedMarks

        var nextText = text
        let sIdx = nextText.utf8.index(nextText.utf8.startIndex, offsetBy: a)
        let eIdx = nextText.utf8.index(nextText.utf8.startIndex, offsetBy: b)
        nextText.replaceSubrange(sIdx..<eIdx, with: s)
        setTextStorageRaw(nextText)
        setSelectionRaw(anchor: a + insLen, cursor: a + insLen)
        syncRichInvariants()
    }

    /// Inserts a soft break (`Shift+Return`, `<br>`) inheriting the current block.
    public mutating func insertSoftBreak() {
        guard !isSecure && multiline else { return }
        syncRichInvariants()
        let covered = coverPills(selectedUTF8Range.lowerBound, selectedUTF8Range.upperBound)
        let range = covered.0..<covered.1
        let lineBlk = blocks[min(lineIndexOfUTF8(range.lowerBound), max(0, blocks.count - 1))]
        let insertedMarks = typingStyle.takeAt(anchor: anchor, cursor: cursor) ?? inheritedRichMarks(at: range.lowerBound)
        let before = captureUndoBaseline()
        applyRichReplace(
            range: range,
            replacement: "\n",
            insertedMarks: insertedMarks,
            newLineBlock: lineBlk,
            markNewLinesSoft: true
        )
        adjustMarks(replacedRange: range, newLength: 1)
        let newCursor = range.lowerBound + 1
        setSelectionRaw(anchor: newCursor, cursor: newCursor)
        caretColumn = .free
        caretAffinity = .downstream
        recordUndoChange(before: before, kind: .lineBreak)
    }

    // MARK: - Paragraphs & Block Operations

    private func selectedLineRange() -> ClosedRange<Int> {
        let r = selectedUTF8Range
        let first = lineIndexOfUTF8(r.lowerBound)
        let last: Int
        if r.upperBound > r.lowerBound {
            let prevIdx = text.utf8.index(text.utf8.startIndex, offsetBy: r.upperBound - 1)
            if text.utf8[prevIdx] == 0x0A {
                last = lineIndexOfUTF8(r.upperBound - 1)
            } else {
                last = lineIndexOfUTF8(r.upperBound)
            }
        } else {
            last = lineIndexOfUTF8(r.upperBound)
        }
        return first...max(first, last)
    }

    public var activeBlock: Block {
        let first = selectedLineRange().lowerBound
        return first < blocks.count ? blocks[first] : .paragraph
    }

    public var selectionInList: Bool {
        selectedLineRange().contains { idx in
            (idx < blocks.count ? blocks[idx] : .paragraph).isList
        }
    }

    public mutating func setBlock(_ block: Block) {
        guard !isSecure && multiline && allowsBlock(block) else { return }
        let normalized = block.withLevel(block.listLevel ?? 0)
        syncRichInvariants()
        let before = captureUndoBaseline()
        for i in selectedLineRange() where i < blocks.count {
            blocks[i] = normalized
        }
        if normalized == .code { typingStyle = .inherited }
        normalizeRichMarks()
        recordUndoChange(before: before, kind: .other)
    }

    public mutating func toggleBlock(_ block: Block) {
        guard !isSecure && multiline && allowsBlock(block) else { return }
        syncRichInvariants()
        let lines = selectedLineRange()
        let allMatch = lines.allSatisfy { idx in
            (idx < blocks.count ? blocks[idx] : .paragraph).sameKind(block)
        }
        if allMatch {
            setBlock(.paragraph)
        } else {
            let before = captureUndoBaseline()
            for i in lines where i < blocks.count {
                switch (blocks[i].listLevel, block) {
                case let (lvl?, .bullet(0)):
                    blocks[i] = .bullet(lvl)
                case let (lvl?, .numbered(0)):
                    blocks[i] = .numbered(lvl)
                default:
                    blocks[i] = block.withLevel(block.listLevel ?? 0)
                }
            }
            if block == .code { typingStyle = .inherited }
            normalizeRichMarks()
            recordUndoChange(before: before, kind: .other)
        }
    }

    @discardableResult
    public mutating func indentList() -> Bool {
        guard !isSecure && multiline else { return false }
        syncRichInvariants()
        guard selectionInList else { return false }
        let before = captureUndoBaseline()
        for i in selectedLineRange() where i < blocks.count {
            if let lvl = blocks[i].listLevel {
                blocks[i] = blocks[i].withLevel(min(lvl + 1, Block.maxListLevel))
            }
        }
        recordUndoChange(before: before, kind: .other)
        return true
    }

    @discardableResult
    public mutating func outdentList() -> Bool {
        guard !isSecure && multiline else { return false }
        syncRichInvariants()
        guard selectionInList else { return false }
        let before = captureUndoBaseline()
        for i in selectedLineRange() where i < blocks.count {
            if let lvl = blocks[i].listLevel {
                blocks[i] = blocks[i].withLevel(lvl > 0 ? lvl - 1 : 0)
            }
        }
        recordUndoChange(before: before, kind: .other)
        return true
    }

    /// Paragraph breakdown for rendering, numbering, and HTML export.
    public func paragraphs() -> [ParagraphInfo] {
        var out: [ParagraphInfo] = []
        var idx = 0
        var start = 0
        for (i, b) in text.utf8.enumerated() {
            if b == 0x0A {
                let blk = idx < blocks.count ? blocks[idx] : .paragraph
                out.append(ParagraphInfo(
                    index: idx,
                    range: start..<i,
                    block: blk,
                    softBreak: softBreaks.contains(idx)
                ))
                start = i + 1
                idx += 1
            }
        }
        let blk = idx < blocks.count ? blocks[idx] : .paragraph
        out.append(ParagraphInfo(
            index: idx,
            range: start..<text.utf8.count,
            block: blk,
            softBreak: softBreaks.contains(idx)
        ))
        return out
    }
}

// MARK: - Rich Display Mapping (crates/rune/src/edit/display.rs)

extension TextEdit {
    public struct RichDisplaySpecs: Sendable {
        public var displayText: String
        public var preeditRange: Range<Int>?
        public var spans: [RichSpan]
        public var links: [TextLink]
        public var blocks: [Block]
        public var pills: [(range: Range<Int>, id: String)]
    }

    /// Splices `preedit` into `text` at the current selection (or returns masked string if hidden secret).
    public func displayWithRichPreedit() -> (text: String, preeditRange: Range<Int>?) {
        if isSecure && !isRevealed {
            return (displayString, nil)
        }
        guard let pre = preedit else {
            return (text, nil)
        }
        let r = selectedUTF8Range
        let sIdx = stringIndex(forUTF8Offset: r.lowerBound)
        let eIdx = stringIndex(forUTF8Offset: r.upperBound)
        var out = text
        out.replaceSubrange(sIdx..<eIdx, with: pre.text)
        let start = r.lowerBound
        return (out, start..<(start + pre.text.utf8.count))
    }

    /// Maps model range `start..<end` into display coordinates, shifting or splitting around `preedit`.
    public func mapRangeToDisplay(_ start: Int, _ end: Int) -> [Range<Int>] {
        guard !(isSecure && !isRevealed), start < end else { return [] }
        let s = clampScalarBoundary(start)
        let e = clampScalarBoundary(end)
        guard s < e else { return [] }
        guard let pre = preedit else {
            return [s..<e]
        }
        let sel = selectedUTF8Range
        let delLen = sel.count
        let insLen = pre.text.utf8.count
        if e <= sel.lowerBound {
            return [s..<e]
        }
        if s >= sel.upperBound {
            return [(s - delLen + insLen)..<(e - delLen + insLen)]
        }
        var out: [Range<Int>] = []
        if s < sel.lowerBound { out.append(s..<sel.lowerBound) }
        if e > sel.upperBound { out.append((sel.lowerBound + insLen)..<(e - delLen + insLen)) }
        return out
    }

    public func richDisplaySpecs(
        baseStyle: TextStyle = TextStyle(),
        style: RichStyle = RichStyle()
    ) -> RichDisplaySpecs {
        let (disp, preRange) = displayWithRichPreedit()
        if isSecure {
            return RichDisplaySpecs(displayText: disp, preeditRange: nil, spans: [], links: [], blocks: [], pills: [])
        }
        var spans: [RichSpan] = []
        var links: [TextLink] = []

        func appendMark(_ r: Range<Int>, _ mark: RichMark) {
            guard !r.isEmpty else { return }
            switch mark {
            case .bold:
                spans.append(RichSpan(r).weight(min(900, max(600, baseStyle.weight + 250))))
            case .italic:
                spans.append(RichSpan(r).italic())
            case .underline:
                spans.append(RichSpan(r).underline())
            case .strike:
                spans.append(RichSpan(r).strikethrough())
            case .code:
                var sp = RichSpan(r).mono().bg(style.codeBg).pad(2)
                if let fg = style.codeFg { sp = sp.color(fg) }
                spans.append(sp)
            case let .link(url):
                spans.append(RichSpan(r).color(style.link).underline())
                links.append(TextLink(r, id: url))
            case .pill:
                break
            }
        }

        for m in richMarks {
            for mapped in mapRangeToDisplay(m.start, m.end) {
                appendMark(mapped, m.mark)
            }
        }

        if let preRange, !preRange.isEmpty {
            for m in activeRichMarks() where !m.isPill {
                appendMark(preRange, m)
            }
        }

        let displayBlocks = self.displayBlocks(for: disp)
        var lineStart = 0
        var lineIdx = 0
        for (i, b) in disp.utf8.enumerated() {
            if b == 0x0A {
                if lineIdx < displayBlocks.count && displayBlocks[lineIdx] == .code && lineStart < i {
                    var sp = RichSpan(lineStart..<i).mono()
                    if let fg = style.codeFg { sp = sp.color(fg) }
                    spans.append(sp)
                }
                lineStart = i + 1
                lineIdx += 1
            }
        }
        if lineIdx < displayBlocks.count && displayBlocks[lineIdx] == .code && lineStart < disp.utf8.count {
            var sp = RichSpan(lineStart..<disp.utf8.count).mono()
            if let fg = style.codeFg { sp = sp.color(fg) }
            spans.append(sp)
        }

        return RichDisplaySpecs(
            displayText: disp,
            preeditRange: preRange,
            spans: spans,
            links: links,
            blocks: displayBlocks,
            pills: displayPills()
        )
    }

    public func displayPills() -> [(range: Range<Int>, id: String)] {
        guard !isSecure else { return [] }
        if preedit == nil {
            return pills
        }
        return richMarks.compactMap { m in
            guard let id = m.mark.pillID else { return nil }
            let mapped = mapRangeToDisplay(m.start, m.end)
            guard mapped.count == 1, let first = mapped.first, first.count == (m.end - m.start) else { return nil }
            return (first, id)
        }
    }

    internal func displayBlocks(for dispText: String) -> [Block] {
        let lineCount = 1 + dispText.utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        guard !blocks.isEmpty else { return Array(repeating: .paragraph, count: lineCount) }
        if preedit == nil {
            var out = blocks
            if out.count < lineCount {
                out.append(contentsOf: repeatElement(.paragraph, count: lineCount - out.count))
            } else if out.count > lineCount {
                out.removeLast(out.count - lineCount)
            }
            return out
        }
        let sel = selectedUTF8Range
        let lineA = lineIndexOfUTF8(sel.lowerBound)
        let lineB = lineIndexOfUTF8(sel.upperBound)
        var out = blocks
        if lineB > lineA && lineB < out.count {
            out.removeSubrange((lineA + 1)...lineB)
        }
        let fill = lineA < out.count ? out[lineA] : .paragraph
        while out.count < lineCount { out.append(fill) }
        if out.count > lineCount { out.removeLast(out.count - lineCount) }
        return out
    }
}

// MARK: - Soft-Wrap Visual Line & Line-Edge Motion (crates/rune/src/edit/caret_motion.rs)

extension TextEdit {
    /// Moves vertically across soft-wrapped visual lines of `shaped`, keeping `caretColumn` (`Column::Kept`).
    public mutating func moveLine(
        delta: Int,
        in shaped: ShapedText,
        textSystem: TextSystem = TextSystem(),
        pixelScale: Float = 1.0,
        extend: Bool = false
    ) {
        guard shaped.cursorLineCount > 0 else {
            setCursor(utf8Offset: delta < 0 ? 0 : text.utf8.count, extendSelection: extend)
            return
        }
        let goalX = caretColumn.goal ?? textSystem.caretRect(
            in: shaped, utf8Offset: cursor, affinity: caretAffinity, pixelScale: pixelScale
        ).x
        let landing = textSystem.moveLine(
            in: shaped, utf8Offset: cursor, delta: delta, goalX: goalX,
            affinity: caretAffinity, pixelScale: pixelScale
        )
        let byte = landing?.utf8Offset ?? text.utf8.count
        let finalOffset = outOfPill(snapToGraphemeBoundary(byte), forward: delta > 0)
        setSelectionRaw(anchor: extend ? anchor : finalOffset, cursor: finalOffset)
        caretColumn = .kept(goalX)
        caretAffinity = landing?.affinity ?? .downstream
        typingStyle = .inherited
    }

    /// Moves to the visual start (`end == false`) or end (`end == true`) of the current soft-wrapped line.
    public mutating func lineEdge(
        end toEnd: Bool,
        in shaped: ShapedText,
        textSystem: TextSystem = TextSystem(),
        extend: Bool = false
    ) {
        guard shaped.cursorLineCount > 0 else {
            let pos = toEnd ? text.utf8.count : 0
            setCursor(utf8Offset: pos, extendSelection: extend)
            return
        }
        let landing = textSystem.lineEdge(in: shaped, utf8Offset: cursor, toEnd: toEnd, affinity: caretAffinity)
        let target = snapToGraphemeBoundary(landing.utf8Offset)
        setSelectionRaw(anchor: extend ? anchor : target, cursor: target)
        snapToPills()
        caretColumn = .free
        caretAffinity = landing.affinity
        typingStyle = .inherited
    }
}

// MARK: - Safe HTML Import & Export (crates/rune/src/edit/html.rs)

extension TextEdit {
    private enum HTMLListKind { case bullet, numbered }

    private struct HTMLActiveMark {
        var mark: RichMark
        var start: Int
    }

    private struct HTMLTagFrame {
        var tag: String
        var addedMarks: [RichMark] = []
        var suppressedMarks: [RichMark] = []
    }

    /// Checks whether an href URL uses a safe scheme (`http`, `https`, `mailto`, `tel`, or scheme-less).
    internal static func isSafeHref(_ url: String) -> Bool {
        var cleaned = ""
        for scalar in url.unicodeScalars {
            let isCtrl = scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value)
            let isWS = scalar.properties.isWhitespace
            if !isCtrl && !isWS {
                cleaned.append(String(scalar).lowercased())
                if cleaned.count >= 64 { break }
            }
        }
        guard !cleaned.isEmpty else { return false }
        var schemeEnd = cleaned.startIndex
        while schemeEnd < cleaned.endIndex {
            let c = cleaned[schemeEnd]
            if c.isASCII && (c.isLetter || c.isNumber || c == "+" || c == "-" || c == ".") {
                schemeEnd = cleaned.index(after: schemeEnd)
            } else {
                break
            }
        }
        if schemeEnd == cleaned.endIndex || cleaned[schemeEnd] != ":" {
            return true // Relative path or fragment
        }
        let scheme = String(cleaned[..<schemeEnd])
        return scheme == "http" || scheme == "https" || scheme == "mailto" || scheme == "tel"
    }

    internal static func decodeHTMLEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var out = ""
        out.reserveCapacity(input.count)
        var rest = input[...]
        while let amp = rest.firstIndex(of: "&") {
            out.append(contentsOf: rest[..<amp])
            let afterAmp = rest.index(after: amp)
            let scanEnd = rest.index(afterAmp, offsetBy: min(33, rest.distance(from: afterAmp, to: rest.endIndex)))
            guard let semi = rest[afterAmp..<scanEnd].firstIndex(of: ";") else {
                out.append("&")
                rest = rest[afterAmp...]
                continue
            }
            let entity = String(rest[afterAmp..<semi])
            if entity.isEmpty || entity.contains(where: \.isWhitespace) {
                out.append("&")
                rest = rest[afterAmp...]
                continue
            }
            var decoded: UnicodeScalar? = nil
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                if let code = UInt32(entity.dropFirst(2), radix: 16), let sc = UnicodeScalar(code), code != 0 {
                    decoded = sc
                }
            } else if entity.hasPrefix("#") {
                if let code = UInt32(entity.dropFirst(), radix: 10), let sc = UnicodeScalar(code), code != 0 {
                    decoded = sc
                }
            } else {
                switch entity {
                case "amp", "AMP": decoded = "&"
                case "lt", "LT": decoded = "<"
                case "gt", "GT": decoded = ">"
                case "quot", "QUOT": decoded = "\""
                case "apos", "#39": decoded = "'"
                case "nbsp", "NBSP": decoded = "\u{00A0}"
                case "copy": decoded = "©"
                case "mdash": decoded = "—"
                case "ndash": decoded = "–"
                case "hellip": decoded = "…"
                case "lsquo": decoded = "‘"
                case "rsquo": decoded = "’"
                case "ldquo": decoded = "“"
                case "rdquo": decoded = "”"
                case "bull": decoded = "•"
                case "colon": decoded = ":"
                case "Tab": decoded = "\t"
                case "NewLine": decoded = "\n"
                default: break
                }
            }
            if let decoded {
                out.unicodeScalars.append(decoded)
                rest = rest[rest.index(after: semi)...]
            } else {
                out.append("&")
                rest = rest[afterAmp...]
            }
        }
        out.append(contentsOf: rest)
        return out
    }

    private static func escapeHTML(_ s: String, into out: inout String) {
        for ch in s {
            switch ch {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            case "\"": out.append("&quot;")
            default: out.append(ch)
            }
        }
    }

    private static func extractHTMLAttr(_ attrs: String, name: String) -> String? {
        let bytes = Array(attrs.utf8)
        var i = 0
        while i < bytes.count {
            while i < bytes.count && (bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D) {
                i += 1
            }
            let keyStart = i
            while i < bytes.count && ((bytes[i] >= 0x61 && bytes[i] <= 0x7A)
                || (bytes[i] >= 0x41 && bytes[i] <= 0x5A)
                || (bytes[i] >= 0x30 && bytes[i] <= 0x39)
                || bytes[i] == 0x2D || bytes[i] == 0x5F || bytes[i] == 0x3A) {
                i += 1
            }
            if i == keyStart { i += 1; continue }
            let key = String(decoding: bytes[keyStart..<i], as: UTF8.self)
            while i < bytes.count && (bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D) {
                i += 1
            }
            guard i < bytes.count && bytes[i] == 0x3D else { continue } // '='
            i += 1
            while i < bytes.count && (bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D) {
                i += 1
            }
            guard i < bytes.count else { break }
            let valBytes: ArraySlice<UInt8>
            if bytes[i] == 0x22 || bytes[i] == 0x27 {
                let q = bytes[i]
                i += 1
                let vs = i
                while i < bytes.count && bytes[i] != q { i += 1 }
                valBytes = bytes[vs..<i]
                if i < bytes.count { i += 1 }
            } else {
                let vs = i
                while i < bytes.count && bytes[i] != 0x20 && bytes[i] != 0x09 && bytes[i] != 0x0A && bytes[i] != 0x0D && bytes[i] != 0x3E && bytes[i] != 0x2F {
                    i += 1
                }
                valBytes = bytes[vs..<i]
            }
            if key.caseInsensitiveCompare(name) == .orderedSame {
                return decodeHTMLEntities(String(decoding: valBytes, as: UTF8.self))
            }
        }
        return nil
    }

    private static func parseCSSStyleMarks(_ style: String, add: inout [RichMark], remove: inout [RichMark]) {
        for decl in style.split(separator: ";") {
            guard let colon = decl.firstIndex(of: ":") else { continue }
            let prop = decl[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let val = decl[decl.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if prop == "font-weight" {
                let v = val.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
                if v == "bold" || v == "bolder" || Float(v).map({ $0 >= 600 }) == true {
                    add.append(.bold)
                } else if v == "normal" || v == "lighter" || Float(v).map({ $0 < 600 }) == true {
                    remove.append(.bold)
                }
            } else if prop == "font-style" {
                let v = val.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
                if v == "italic" || v == "oblique" {
                    add.append(.italic)
                } else if v == "normal" {
                    remove.append(.italic)
                }
            } else if prop == "text-decoration" || prop == "text-decoration-line" {
                for tok in val.split(whereSeparator: \.isWhitespace).map({ $0.lowercased() }) {
                    if tok == "underline" { add.append(.underline) }
                    else if tok == "line-through" { add.append(.strike) }
                    else if tok == "none" {
                        remove.append(.underline)
                        remove.append(.strike)
                    }
                }
            }
        }
    }

    /// Parses safe rich HTML (`<b>`, `<i>`, `<u>`, `<s>`, `<code>`, `<a href>`, `<span data-pill>`, `<p>`, `<ul>`, `<ol>`, `<li>`, `<blockquote>`, `<pre>`, `<br>`) into a `TextEdit`.
    public static func fromHTML(_ html: String) -> TextEdit {
        let maxDepth = 512
        var text = ""
        var marks: [RichMarkRange] = []
        var blocks: [Block] = [.paragraph]
        var softBreaks: [Int] = []

        var stack: [HTMLTagFrame] = []
        var openTags: [String: Int] = [:]
        var activeMarks: [HTMLActiveMark] = []
        var listStack: [HTMLListKind] = []
        var inPre = 0
        var inQuote = 0
        var inLi = 0
        var lineHasBlock = false
        var lineOpen = false
        var lineHasContent = false
        var deferredBr: (textLen: Int, blockCount: Int)? = nil

        func currentDefaultBlock() -> Block {
            if inPre > 0 { return .code }
            if inLi > 0, let kind = listStack.last {
                let lvl = UInt8(min(listStack.count - 1, Int(Block.maxListLevel)))
                return kind == .bullet ? .bullet(lvl) : .numbered(lvl)
            }
            if inQuote > 0 { return .quote }
            return .paragraph
        }

        func flushActiveMarks(at pos: Int) {
            for idx in activeMarks.indices {
                if inPre == 0 && activeMarks[idx].start < pos {
                    marks.append(RichMarkRange(start: activeMarks[idx].start, end: pos, mark: activeMarks[idx].mark))
                }
                activeMarks[idx].start = pos
            }
        }

        func startNewParagraph(_ block: Block) {
            if (!lineHasBlock || lineOpen) && !lineHasContent {
                if !blocks.isEmpty { blocks[blocks.count - 1] = block }
                lineHasBlock = true
                lineOpen = true
                return
            }
            flushActiveMarks(at: text.utf8.count)
            text.append("\n")
            blocks.append(block)
            let newPos = text.utf8.count
            for idx in activeMarks.indices { activeMarks[idx].start = newPos }
            lineHasBlock = true
            lineOpen = true
            lineHasContent = false
        }

        func pushBr() {
            flushActiveMarks(at: text.utf8.count)
            let blk = blocks.last ?? .paragraph
            text.append("\n")
            blocks.append(blk)
            if inPre == 0 {
                softBreaks.append(blocks.count - 1)
            }
            let newPos = text.utf8.count
            for idx in activeMarks.indices { activeMarks[idx].start = newPos }
        }

        let voidTags: Set<String> = ["area", "base", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]
        let blockTags: Set<String> = ["p", "div", "ul", "ol", "li", "blockquote", "pre", "h1", "h2", "h3", "h4", "h5", "h6"]
        var cursorIdx = html.startIndex

        while cursorIdx < html.endIndex {
            if html[cursorIdx] == "<" {
                if html[cursorIdx...].hasPrefix("<!--") {
                    let afterStart = html.index(cursorIdx, offsetBy: 4)
                    if let r = html[afterStart...].range(of: "-->") {
                        cursorIdx = r.upperBound
                    } else {
                        break
                    }
                    continue
                }
                if html[cursorIdx...].hasPrefix("<!") || html[cursorIdx...].hasPrefix("<?") {
                    let afterStart = html.index(cursorIdx, offsetBy: 2)
                    if let gt = html[afterStart...].firstIndex(of: ">") {
                        cursorIdx = html.index(after: gt)
                    } else {
                        break
                    }
                    continue
                }
                let afterLt = html.index(after: cursorIdx)
                guard let gt = html[afterLt...].firstIndex(of: ">") else {
                    text.append(decodeHTMLEntities(String(html[cursorIdx...])))
                    break
                }
                let rawTag = html[afterLt..<gt].trimmingCharacters(in: .whitespacesAndNewlines)
                cursorIdx = html.index(after: gt)
                guard !rawTag.isEmpty else { continue }

                let isClosing = rawTag.hasPrefix("/")
                var body = rawTag[...]
                if isClosing { body = body.dropFirst() }
                if body.hasSuffix("/") { body = body.dropLast() }
                let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
                let tagEnd = trimmedBody.firstIndex(where: { $0.isWhitespace || $0 == "/" }) ?? trimmedBody.endIndex
                let tag = trimmedBody[..<tagEnd].lowercased()
                let attrs = String(trimmedBody[tagEnd...])
                let selfClosing = rawTag.hasSuffix("/") || voidTags.contains(tag)

                if !isClosing && (tag == "script" || tag == "style" || tag == "head") {
                    if !selfClosing {
                        let pat = "</\(tag)"
                        if let closeRange = html[cursorIdx...].range(of: pat, options: [.caseInsensitive]),
                           let closeGt = html[closeRange.upperBound...].firstIndex(of: ">") {
                            cursorIdx = html.index(after: closeGt)
                        } else {
                            cursorIdx = html.endIndex
                        }
                    }
                    continue
                }

                if !isClosing && tag == "br" {
                    if let def = deferredBr, def.textLen == text.utf8.count && def.blockCount == blocks.count {
                        pushBr()
                        lineHasBlock = true
                        lineOpen = true
                    }
                    deferredBr = nil
                    if inPre > 0 {
                        pushBr()
                        lineHasContent = false
                    } else {
                        deferredBr = (text.utf8.count, blocks.count)
                        lineHasBlock = true
                        lineOpen = true
                        lineHasContent = true
                    }
                    continue
                }

                if !isClosing && !selfClosing && stack.count >= maxDepth {
                    continue
                }

                if !isClosing {
                    switch tag {
                    case "ul":
                        listStack.append(.bullet)
                        if lineHasContent { lineOpen = false }
                    case "ol":
                        listStack.append(.numbered)
                        if lineHasContent { lineOpen = false }
                    case "li":
                        inLi += 1
                        startNewParagraph(currentDefaultBlock())
                    case "blockquote":
                        inQuote += 1
                        startNewParagraph(currentDefaultBlock())
                    case "pre":
                        inPre += 1
                        startNewParagraph(.code)
                    case "p", "div", "h1", "h2", "h3", "h4", "h5", "h6":
                        startNewParagraph(currentDefaultBlock())
                    default:
                        break
                    }

                    var toAdd: [RichMark] = []
                    var toSuppress: [RichMark] = []
                    switch tag {
                    case "b", "strong", "h1", "h2", "h3", "h4", "h5", "h6":
                        toAdd.append(.bold)
                    case "i", "em":
                        toAdd.append(.italic)
                    case "u", "ins":
                        toAdd.append(.underline)
                    case "s", "del", "strike":
                        toAdd.append(.strike)
                    case "code" where inPre == 0:
                        toAdd.append(.code)
                    case "a":
                        if let href = extractHTMLAttr(attrs, name: "href"), isSafeHref(href) {
                            toAdd.append(.link(href.trimmingCharacters(in: .whitespacesAndNewlines)))
                        }
                    case "span":
                        if let id = extractHTMLAttr(attrs, name: "data-pill") {
                            toAdd.append(.pill(id))
                        }
                    default:
                        break
                    }
                    if let styleAttr = extractHTMLAttr(attrs, name: "style") {
                        parseCSSStyleMarks(styleAttr, add: &toAdd, remove: &toSuppress)
                        toAdd.removeAll { candidate in toSuppress.contains { $0.sameKind(candidate) } }
                    }

                    let pos = text.utf8.count
                    var frame = HTMLTagFrame(tag: tag)
                    for rem in toSuppress {
                        if let idx = activeMarks.firstIndex(where: { $0.mark.sameKind(rem) }) {
                            let popped = activeMarks.remove(at: idx)
                            if inPre == 0 && popped.start < pos {
                                marks.append(RichMarkRange(start: popped.start, end: pos, mark: popped.mark))
                            }
                            frame.suppressedMarks.append(popped.mark)
                        }
                    }
                    for m in toAdd {
                        if let idx = activeMarks.firstIndex(where: { $0.mark.sameKind(m) }) {
                            if activeMarks[idx].mark != m {
                                let old = activeMarks.remove(at: idx)
                                if inPre == 0 && old.start < pos {
                                    marks.append(RichMarkRange(start: old.start, end: pos, mark: old.mark))
                                }
                                frame.suppressedMarks.append(old.mark)
                                activeMarks.append(HTMLActiveMark(mark: m, start: pos))
                                frame.addedMarks.append(m)
                            }
                        } else {
                            activeMarks.append(HTMLActiveMark(mark: m, start: pos))
                            frame.addedMarks.append(m)
                        }
                    }
                    if !selfClosing {
                        openTags[tag, default: 0] += 1
                        stack.append(frame)
                    }
                } else {
                    let pos = text.utf8.count
                    if openTags[tag, default: 0] > 0, let frameIdx = stack.lastIndex(where: { $0.tag == tag }) {
                        while stack.count > frameIdx {
                            let frame = stack.removeLast()
                            openTags[frame.tag] = max(0, (openTags[frame.tag] ?? 1) - 1)
                            for m in frame.addedMarks.reversed() {
                                if let idx = activeMarks.lastIndex(where: { $0.mark == m }) {
                                    let ended = activeMarks.remove(at: idx)
                                    if inPre == 0 && ended.start < pos {
                                        marks.append(RichMarkRange(start: ended.start, end: pos, mark: ended.mark))
                                    }
                                }
                            }
                            for sup in frame.suppressedMarks {
                                if !activeMarks.contains(where: { $0.mark.sameKind(sup) }) {
                                    activeMarks.append(HTMLActiveMark(mark: sup, start: pos))
                                }
                            }
                            switch frame.tag {
                            case "ul", "ol":
                                _ = listStack.popLast()
                                lineOpen = false
                            case "li":
                                inLi = max(0, inLi - 1)
                                lineOpen = false
                            case "blockquote":
                                inQuote = max(0, inQuote - 1)
                                lineOpen = false
                            case "pre":
                                inPre = max(0, inPre - 1)
                                lineOpen = false
                            case "p", "div", "h1", "h2", "h3", "h4", "h5", "h6":
                                lineOpen = false
                            default:
                                break
                            }
                        }
                    }
                }
            } else {
                let nextLt = html[cursorIdx...].firstIndex(of: "<") ?? html.endIndex
                let rawSlice = String(html[cursorIdx..<nextLt])
                cursorIdx = nextLt
                let decoded = decodeHTMLEntities(rawSlice)
                if inPre > 0 {
                    let scalars = Array(decoded.unicodeScalars)
                    var si = 0
                    while si < scalars.count {
                        let sc = scalars[si]
                        if sc == "\r" {
                            if si + 1 < scalars.count && scalars[si + 1] == "\n" { si += 1 }
                            text.append("\n")
                            blocks.append(.code)
                            lineHasBlock = true
                            lineOpen = false
                            lineHasContent = false
                        } else if sc == "\n" {
                            if lineOpen && !lineHasContent {
                                lineOpen = false
                            } else {
                                text.append("\n")
                                blocks.append(.code)
                                lineHasBlock = true
                                lineOpen = false
                                lineHasContent = false
                            }
                        } else if sc == "\t" || !(sc.value < 0x20 || sc.value == 0x7F) {
                            text.unicodeScalars.append(sc)
                            lineHasBlock = true
                            lineOpen = false
                            lineHasContent = true
                        }
                        si += 1
                    }
                } else {
                    let allWS = decoded.allSatisfy(\.isWhitespace)
                    if !lineOpen && allWS && (!lineHasBlock || lineHasContent) {
                        continue
                    }
                    if lineOpen && !lineHasContent && allWS && cursorIdx < html.endIndex && html[cursorIdx] == "<" {
                        let restAfterLt = html[html.index(after: cursorIdx)...].drop(while: \.isWhitespace).lowercased()
                        let nextIsBlock = blockTags.contains { b in
                            restAfterLt.hasPrefix(b) && (restAfterLt.dropFirst(b.count).first.map { $0.isWhitespace || $0 == ">" || $0 == "/" } ?? false)
                        }
                        if nextIsBlock { continue }
                    }
                    if !lineOpen && !decoded.isEmpty && (!lineHasBlock || lineHasContent) {
                        let blk = currentDefaultBlock()
                        if !lineHasBlock {
                            if !blocks.isEmpty { blocks[blocks.count - 1] = blk }
                            lineHasBlock = true
                            lineOpen = true
                        } else if !allWS {
                            startNewParagraph(blk)
                        }
                    }
                    if allWS {
                        if let def = deferredBr, def.textLen == text.utf8.count && def.blockCount == blocks.count {
                            continue
                        }
                    } else {
                        if let def = deferredBr, def.textLen == text.utf8.count && def.blockCount == blocks.count {
                            pushBr()
                        }
                        deferredBr = nil
                    }
                    var prevSpace = text.isEmpty || text.hasSuffix("\n") || text.hasSuffix(" ")
                    for sc in decoded.unicodeScalars {
                        if sc == "\u{00A0}" {
                            text.unicodeScalars.append(sc)
                            prevSpace = false
                            lineHasBlock = true
                            lineOpen = true
                            lineHasContent = true
                        } else if Character(sc).isWhitespace {
                            if !prevSpace {
                                text.append(" ")
                                prevSpace = true
                                lineHasBlock = true
                                lineOpen = true
                                lineHasContent = true
                            }
                        } else if !(sc.value < 0x20 || sc.value == 0x7F) {
                            text.unicodeScalars.append(sc)
                            prevSpace = false
                            lineHasBlock = true
                            lineOpen = true
                            lineHasContent = true
                        }
                    }
                }
            }
        }

        flushActiveMarks(at: text.utf8.count)
        if blocks.count > 1 && blocks.last == .code && text.hasSuffix("\n") && !softBreaks.contains(blocks.count - 1) {
            text.removeLast()
            blocks.removeLast()
        }

        return TextEdit.fromRichParts(text: text, richMarks: marks, blocks: blocks, softBreaks: softBreaks, multiline: true)
    }

    /// Pastes rich HTML with plain-text fallback at the selection (`edit/input.rs:433`), dropping pill marks.
    public mutating func pasteHTML(_ html: String, plain: String) {
        pasteRich(html: html, plain: plain, keepPills: false)
    }

    /// Pastes rich HTML with plain-text fallback, preserving `RichMark.pill` marks (`edit/input.rs:438`).
    public mutating func pasteHTMLWithPills(_ html: String, plain: String) {
        pasteRich(html: html, plain: plain, keepPills: true)
    }

    private mutating func pasteRich(html: String, plain: String, keepPills: Bool) {
        if isSecure || html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            paste(plain)
            return
        }
        if !isRichEnabled {
            let textOnly = plain.isEmpty ? Self.fromHTML(html).text : plain
            paste(textOnly)
            return
        }
        var frag = Self.fromHTML(html)
        if !keepPills {
            frag.richMarks.removeAll { $0.mark.isPill }
        }
        if let allowedRichMarks {
            frag.richMarks.removeAll { !allowedRichMarks.contains($0.mark.allowBit) }
        }
        if let allowedBlocks {
            for i in frag.blocks.indices where !allowedBlocks.contains(frag.blocks[i].allowBit) {
                frag.blocks[i] = .paragraph
            }
        }
        let unformatted = frag.richMarks.isEmpty && frag.blocks.allSatisfy { $0 == .paragraph }
        if !plain.isEmpty && (frag.text.isEmpty || unformatted) {
            paste(plain)
            return
        }
        if !isRichEnabled {
            paste(plain.isEmpty ? frag.text : plain)
            return
        }
        syncRichInvariants()
        if multiline {
            let lineIdx = lineIndexOfUTF8(selectedUTF8Range.lowerBound)
            if lineIdx < blocks.count && blocks[lineIdx] == .code {
                paste(plain.isEmpty ? frag.text : plain)
                return
            }
        }

        breakHistoryGroup()
        let before = captureUndoBaseline()
        let covered = coverPills(selectedUTF8Range.lowerBound, selectedUTF8Range.upperBound)
        let a = covered.0
        let b = covered.1

        if !multiline {
            var clean = ""
            var byteMap = [Int](repeating: 0, count: frag.text.utf8.count + 1)
            var utf8Pos = 0
            for ch in frag.text {
                let chLen = ch.utf8.count
                for k in 0..<chLen {
                    byteMap[utf8Pos + k] = clean.utf8.count
                }
                if !(ch.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }) && ch != "\u{2028}" && ch != "\u{2029}" {
                    clean.append(ch)
                } else if ch == "\n", !clean.isEmpty, clean.last != " " {
                    clean.append(" ")
                }
                utf8Pos += chLen
            }
            byteMap[frag.text.utf8.count] = clean.utf8.count
            applyRichReplace(range: a..<b, replacement: clean, insertedMarks: [], newLineBlock: nil, markNewLinesSoft: false)
            adjustMarks(replacedRange: a..<b, newLength: clean.utf8.count)
            for m in frag.richMarks {
                let sIdx = a + byteMap[min(m.start, frag.text.utf8.count)]
                let eIdx = a + byteMap[min(m.end, frag.text.utf8.count)]
                if sIdx < eIdx {
                    richMarks.append(RichMarkRange(start: sIdx, end: eIdx, mark: m.mark))
                }
            }
            typingStyle = .inherited
            normalizeRichMarks()
            recordUndoChange(before: before, kind: .other)
            return
        }

        if a < b {
            applyRichReplace(range: a..<b, replacement: "", insertedMarks: [], newLineBlock: nil, markNewLinesSoft: false)
            adjustMarks(replacedRange: a..<b, newLength: 0)
        }
        let insAt = a
        let lineIdx = lineIndexOfUTF8(insAt)
        let lineRange = lineRangeUTF8(of: lineIdx)
        let lineWasEmpty = lineRange.isEmpty
        let origBlock = lineIdx < blocks.count ? blocks[lineIdx] : .paragraph

        applyRichReplace(range: insAt..<insAt, replacement: frag.text, insertedMarks: [], newLineBlock: nil, markNewLinesSoft: false)
        adjustMarks(replacedRange: insAt..<insAt, newLength: frag.text.utf8.count)

        let fragLines = frag.blocks.count
        if fragLines == 1 {
            if lineWasEmpty && origBlock == .paragraph && frag.blocks[0] != .paragraph && lineIdx < blocks.count {
                blocks[lineIdx] = frag.blocks[0]
            }
        } else if fragLines > 1 {
            if (lineWasEmpty || insAt == lineRange.lowerBound) && origBlock == .paragraph && lineIdx < blocks.count {
                blocks[lineIdx] = frag.blocks[0]
            }
            for k in 1..<fragLines where lineIdx + k < blocks.count {
                blocks[lineIdx + k] = frag.blocks[k]
            }
            for sb in frag.softBreaks {
                let target = lineIdx + sb
                if target > 0 { softBreaks.append(target) }
            }
        }

        for m in frag.richMarks {
            richMarks.append(RichMarkRange(start: insAt + m.start, end: insAt + m.end, mark: m.mark))
        }
        typingStyle = .inherited
        syncRichInvariants()
        recordUndoChange(before: before, kind: .other)
    }

    /// Exports `range` (or whole editor if `nil`) to semantic HTML.
    public func toHTML(range: Range<Int>? = nil) -> String {
        guard !isSecure else { return "" }
        let len = text.utf8.count
        let r = range ?? (0..<len)
        let start = min(r.lowerBound, len)
        let end = max(start, min(r.upperBound, len))
        if start == end && blocks.allSatisfy({ $0 == .paragraph }) {
            return ""
        }

        var paras: [(index: Int, range: Range<Int>, block: Block, softBreak: Bool)] = []
        for p in paragraphs() {
            let pEndWithNL = p.range.upperBound < len ? p.range.upperBound + 1 : p.range.upperBound
            if p.range.lowerBound <= end && pEndWithNL >= start {
                let subStart = max(p.range.lowerBound, start)
                let subEnd = min(p.range.upperBound, end)
                if subStart <= subEnd && (subStart < subEnd || start == end || (p.range.lowerBound >= start && p.range.upperBound <= end)) {
                    paras.append((p.index, subStart..<subEnd, p.block, p.softBreak && p.range.lowerBound > start))
                }
            }
        }

        let blockDirs = computeHTMLBlockDirs(paras: paras)
        var out = ""
        var idx = 0
        while idx < paras.count {
            let blk = paras[idx].block
            let dirAttr = blockDirs[idx]
            switch blk {
            case .code:
                out.append("<pre><code>")
                var first = true
                while idx < paras.count && paras[idx].block == .code {
                    if !first { out.append("\n") }
                    first = false
                    let sr = paras[idx].range
                    let sIdx = stringIndex(forUTF8Offset: sr.lowerBound)
                    let eIdx = stringIndex(forUTF8Offset: sr.upperBound)
                    Self.escapeHTML(String(text[sIdx..<eIdx]), into: &out)
                    idx += 1
                }
                out.append("</code></pre>")
            case .bullet, .numbered:
                var openLists: [HTMLListKind] = []
                while idx < paras.count && paras[idx].block.isList {
                    let curBlk = paras[idx].block
                    let itemDirAttr = blockDirs[idx]
                    let (kind, level): (HTMLListKind, Int) = {
                        switch curBlk {
                        case let .bullet(l): return (.bullet, Int(l))
                        case let .numbered(l): return (.numbered, Int(l))
                        default: return (.bullet, 0)
                        }
                    }()
                    let targetDepth = level + 1
                    while openLists.count > targetDepth {
                        let popped = openLists.removeLast()
                        out.append(popped == .bullet ? "</ul>" : "</ol>")
                    }
                    if openLists.count == targetDepth && openLists.last != kind {
                        let popped = openLists.removeLast()
                        out.append(popped == .bullet ? "</ul>" : "</ol>")
                    }
                    while openLists.count < targetDepth {
                        let k = (openLists.count + 1 == targetDepth) ? kind : (openLists.last ?? kind)
                        out.append(k == .bullet ? "<ul>" : "<ol>")
                        openLists.append(k)
                    }
                    out.append("<li\(itemDirAttr)>")
                    serializeInlineHTML(paras[idx].range, into: &out)
                    idx += 1
                    while idx < paras.count && paras[idx].softBreak && paras[idx].block == curBlk {
                        out.append("<br>")
                        serializeInlineHTML(paras[idx].range, into: &out)
                        idx += 1
                    }
                    out.append("</li>")
                }
                while let popped = openLists.popLast() {
                    out.append(popped == .bullet ? "</ul>" : "</ol>")
                }
            case .quote:
                out.append("<blockquote\(dirAttr)>")
                serializeInlineHTML(paras[idx].range, into: &out)
                idx += 1
                while idx < paras.count && paras[idx].softBreak && paras[idx].block == .quote {
                    out.append("<br>")
                    serializeInlineHTML(paras[idx].range, into: &out)
                    idx += 1
                }
                out.append("</blockquote>")
            case .paragraph:
                out.append("<p\(dirAttr)>")
                serializeInlineHTML(paras[idx].range, into: &out)
                idx += 1
                while idx < paras.count && paras[idx].softBreak && paras[idx].block == .paragraph {
                    out.append("<br>")
                    serializeInlineHTML(paras[idx].range, into: &out)
                    idx += 1
                }
                out.append("</p>")
            }
        }
        return out
    }

    private func computeHTMLBlockDirs(paras: [(index: Int, range: Range<Int>, block: Block, softBreak: Bool)]) -> [String] {
        var last: TextFlow? = nil
        var shownByParaIndex: [Int: TextFlow] = [:]
        for p in paragraphs() {
            let subStart = stringIndex(forUTF8Offset: p.range.lowerBound)
            let subEnd = stringIndex(forUTF8Offset: p.range.upperBound)
            let slice = String(text[subStart..<subEnd])
            let strong: TextFlow? = {
                for sc in slice.unicodeScalars {
                    let v = sc.value
                    if (0x0590...0x08FF).contains(v) || (0xFB1D...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v) {
                        return .rtl
                    }
                    if (0x0041...0x024F).contains(v) || (0x0370...0x052F).contains(v) {
                        return .ltr
                    }
                }
                return nil
            }()
            last = forcedDir ?? strong ?? last
            if let last {
                shownByParaIndex[p.index] = last
            }
        }
        let hasRTL = paras.contains { $0.block != .code && shownByParaIndex[$0.index] == .rtl }
        guard hasRTL else { return Array(repeating: "", count: paras.count) }
        return paras.map { p in
            switch (p.block, shownByParaIndex[p.index]) {
            case (.code, _), (_, .ltr?):
                return " dir=\"ltr\""
            case (_, .rtl?):
                return " dir=\"rtl\""
            default:
                return ""
            }
        }
    }

    private func serializeInlineHTML(_ range: Range<Int>, into out: inout String) {
        var at = range.lowerBound
        for m in richMarks where range.lowerBound <= m.start && m.end <= range.upperBound {
            guard let id = m.mark.pillID else { continue }
            serializeMarksHTML(at..<m.start, into: &out)
            out.append("<span data-pill=\"")
            Self.escapeHTML(id, into: &out)
            out.append("\">")
            serializeMarksHTML(m.range, into: &out)
            out.append("</span>")
            at = m.end
        }
        serializeMarksHTML(at..<range.upperBound, into: &out)
    }

    private func serializeMarksHTML(_ range: Range<Int>, into out: inout String) {
        guard !range.isEmpty else { return }
        let overlapping = richMarks.filter { $0.start < range.upperBound && $0.end > range.lowerBound && !$0.mark.isPill }
        if overlapping.isEmpty {
            let sIdx = stringIndex(forUTF8Offset: range.lowerBound)
            let eIdx = stringIndex(forUTF8Offset: range.upperBound)
            Self.escapeHTML(String(text[sIdx..<eIdx]), into: &out)
            return
        }
        var bounds = [range.lowerBound, range.upperBound]
        for m in overlapping {
            bounds.append(m.start.clamped(to: range.lowerBound...range.upperBound))
            bounds.append(m.end.clamped(to: range.lowerBound...range.upperBound))
        }
        let sortedBounds = Array(Set(bounds)).sorted()
        func canonicalOrder(_ m: RichMark) -> UInt8 {
            switch m {
            case .link: return 0
            case .bold: return 1
            case .italic: return 2
            case .underline: return 3
            case .strike: return 4
            case .code: return 5
            case .pill: return 6
            }
        }
        for i in 0..<(sortedBounds.count - 1) {
            let a = sortedBounds[i]
            let b = sortedBounds[i + 1]
            guard a < b else { continue }
            let active = overlapping.filter { $0.start <= a && $0.end >= b }
                .map(\.mark)
                .sorted { canonicalOrder($0) < canonicalOrder($1) }
            for m in active {
                switch m {
                case .bold: out.append("<strong>")
                case .italic: out.append("<em>")
                case .underline: out.append("<u>")
                case .strike: out.append("<s>")
                case .code: out.append("<code>")
                case let .link(url):
                    out.append("<a href=\"")
                    Self.escapeHTML(url, into: &out)
                    out.append("\">")
                case .pill: break
                }
            }
            let sIdx = stringIndex(forUTF8Offset: a)
            let eIdx = stringIndex(forUTF8Offset: b)
            Self.escapeHTML(String(text[sIdx..<eIdx]), into: &out)
            for m in active.reversed() {
                switch m {
                case .bold: out.append("</strong>")
                case .italic: out.append("</em>")
                case .underline: out.append("</u>")
                case .strike: out.append("</s>")
                case .code: out.append("</code>")
                case .link: out.append("</a>")
                case .pill: break
                }
            }
        }
    }
}
