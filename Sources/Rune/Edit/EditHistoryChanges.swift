import Foundation

// Undo steps as changes (`crates/rune/src/edit/history.rs`, #990): each step stores the text it
// replaced and the selection, marks and blocks on either side (`Change`), not two whole copies of
// the document. A history keeps its newest step however large, so a paste of a whole file can
// always be undone. Stored histories are version 2 (`history_json`); version 1 still reads.

extension TextEdit {
    /// What a document holds besides its text, either side of a `HistoryChange` (`history::Meta`).
    internal struct HistoryMeta: Sendable, Equatable {
        var anchor: Int
        var cursor: Int
        var marks: [TextMark]
        var richMarks: [RichMarkRange]
        var blocks: [Block]
        var softBreaks: [Int]

        static func of(_ s: Snapshot) -> HistoryMeta {
            HistoryMeta(anchor: s.anchor, cursor: s.cursor, marks: s.marks, richMarks: s.richMarks, blocks: s.blocks, softBreaks: s.softBreaks)
        }

        /// `size_of::<MarkRange>()`, `size_of::<Block>()` and `size_of::<u32>()` upstream (64-bit):
        /// a `MarkRange` is two `usize`s and a `Mark` (a `String`-sized enum), a `Block` a tag and
        /// a `u8`, a soft break a `u32`.
        static let markRangeBytes = 40
        static let blockBytes = 2
        static let softBreakBytes = 4

        /// `Meta::bytes`: its marks, blocks and soft breaks at upstream's sizes, so a history is
        /// trimmed to `HISTORY_BYTES` at the same steps. The Swift-only `marks` (`TextMark`, which
        /// upstream has no counterpart of) aren't counted.
        var byteCost: Int {
            richMarks.count * Self.markRangeBytes
                + blocks.count * Self.blockBytes
                + softBreaks.count * Self.softBreakBytes
        }
    }

    /// One undo step (`history::Change`): UTF-8 bytes `at..<at + removed.utf8.count` of the document
    /// before it became `inserted`, and what the document held besides its text before and after.
    /// Its strings are copy-on-write, so a field cloned for a view and edited after copies none.
    internal struct HistoryChange: Sendable, Equatable {
        var at: Int
        var removed: String
        var inserted: String
        /// The text's UTF-8 length before and after, to tell a document the app replaced from this one.
        var lens: (Int, Int)
        var before: HistoryMeta
        var after: HistoryMeta

        static func == (l: HistoryChange, r: HistoryChange) -> Bool {
            l.at == r.at && l.removed == r.removed && l.inserted == r.inserted
                && l.lens == r.lens && l.before == r.before && l.after == r.after
        }

        var byteCost: Int {
            removed.utf8.count + inserted.utf8.count + before.byteCost + after.byteCost
        }

        /// The step from `before` to `after` (`Change::between`).
        static func between(_ before: Snapshot, _ after: Snapshot) -> HistoryChange {
            toText(before, after.text, after: HistoryMeta.of(after))
        }

        /// The step from `before` to text `b` with `after` besides (`Change::to_text`).
        static func toText(_ before: Snapshot, _ b: String, after: HistoryMeta) -> HistoryChange {
            let a = before.text
            let (at, removed, inserted) = HistoryText.diff(a, b)
            return HistoryChange(
                at: at,
                removed: HistoryText.slice(a, at, at + removed),
                inserted: HistoryText.slice(b, at, at + inserted),
                lens: (a.utf8.count, b.utf8.count),
                before: HistoryMeta.of(before),
                after: after
            )
        }

        /// Whether `text` is this step's document after it (`after`) or before it: its length, and
        /// the bytes the step wrote there (`Change::leads_to`).
        func leadsTo(_ text: String, after: Bool) -> Bool {
            let (len, there) = after ? (lens.1, inserted) : (lens.0, removed)
            return text.utf8.count == len && HistoryText.bytes(of: text, at: at, equal: there)
        }

        /// `next`, from this step's document after (`mid`), folded into this step: one step from
        /// this one's before to `next`'s after (`Change::join`).
        mutating func join(mid: String, next: HistoryChange) {
            let insEnd = at + inserted.utf8.count
            let s = min(at, next.at)
            let e = max(insEnd, next.at + next.removed.utf8.count)
            var newRemoved = HistoryText.slice(mid, s, at)
            newRemoved += removed
            newRemoved += HistoryText.slice(mid, insEnd, max(e, insEnd))
            var newInserted = HistoryText.slice(mid, s, next.at)
            newInserted += next.inserted
            newInserted += HistoryText.slice(mid, min(next.at + next.removed.utf8.count, e), e)
            (at, removed, inserted) = (s, newRemoved, newInserted)
            lens.1 = next.lens.1
            after = next.after
        }
    }
}

/// UTF-8 byte helpers for history changes: offsets are byte offsets on scalar boundaries.
internal enum HistoryText {
    static func withBytes<R>(_ s: String, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        if let r = s.utf8.withContiguousStorageIfAvailable(body) { return r }
        let copy = Array(s.utf8)
        return copy.withUnsafeBufferPointer(body)
    }

    /// Whether byte `i` of `p` starts a scalar (or is its end).
    static func isBoundary(_ p: UnsafeBufferPointer<UInt8>, _ i: Int) -> Bool {
        i >= 0 && (i == p.count || (i < p.count && (p[i] & 0xC0) != 0x80))
    }

    static func isBoundary(_ s: String, _ i: Int) -> Bool {
        withBytes(s) { isBoundary($0, i) }
    }

    /// Where `a` and `b` differ: the byte both share up to (a character boundary), and how many
    /// bytes of each follow before what they share at the end (`history::diff`).
    static func diff(_ a: String, _ b: String) -> (Int, Int, Int) {
        withBytes(a) { x in
            withBytes(b) { y in
                let n = min(x.count, y.count)
                // In blocks first: a long document's comparison is a few memcmps.
                var pre = 0
                while pre + 4096 <= n && memcmp(x.baseAddress! + pre, y.baseAddress! + pre, 4096) == 0 { pre += 4096 }
                while pre < n && x[pre] == y[pre] { pre += 1 }
                while !isBoundary(x, pre) { pre -= 1 }
                let room = n - pre
                var suf = 0
                while suf + 4096 <= room
                    && memcmp(x.baseAddress! + (x.count - suf - 4096), y.baseAddress! + (y.count - suf - 4096), 4096) == 0 { suf += 4096 }
                while suf < room && x[x.count - 1 - suf] == y[y.count - 1 - suf] { suf += 1 }
                while !isBoundary(x, x.count - suf) || !isBoundary(y, y.count - suf) { suf -= 1 }
                return (pre, x.count - pre - suf, y.count - pre - suf)
            }
        }
    }

    /// `s`'s UTF-8 bytes `a..<b` (both on scalar boundaries) as a string.
    static func slice(_ s: String, _ a: Int, _ b: Int) -> String {
        guard b > a else { return "" }
        let u = s.utf8
        let i = u.index(u.startIndex, offsetBy: a)
        let j = u.index(i, offsetBy: b - a)
        return String(decoding: u[i..<j], as: UTF8.self)
    }

    /// Whether `text`'s bytes from `at` are exactly `there`'s.
    static func bytes(of text: String, at: Int, equal there: String) -> Bool {
        withBytes(text) { t in
            withBytes(there) { w in
                guard at >= 0, at + w.count <= t.count else { return false }
                guard isBoundary(t, at), isBoundary(t, at + w.count) else { return false }
                return w.count == 0 || memcmp(t.baseAddress! + at, w.baseAddress!, w.count) == 0
            }
        }
    }

    /// `s`'s UTF-8 bytes `at..<at + len` become `with`.
    static func replace(_ s: inout String, _ at: Int, _ len: Int, with: String) {
        let u = s.utf8
        let i = u.index(u.startIndex, offsetBy: at)
        let j = u.index(i, offsetBy: len)
        s.unicodeScalars.replaceSubrange(i..<j, with: with.unicodeScalars)
    }
}

// MARK: - Stored histories (`history_json`)

extension TextEdit {
    /// Whether `undo` leads back from `doc` step by step, and `redo` forward, every offset on a
    /// character boundary of the document it's in (`history::chain_holds`).
    static func historyChainHolds(_ doc: String, undo: [HistoryChange], redo: [HistoryChange]) -> Bool {
        var text = doc
        for c in undo.reversed() {
            guard c.leadsTo(text, after: true), historyMetaHolds(c.after, text) else { return false }
            HistoryText.replace(&text, c.at, c.inserted.utf8.count, with: c.removed)
            guard historyMetaHolds(c.before, text) else { return false }
        }
        text = doc
        for c in redo.reversed() {
            guard c.leadsTo(text, after: false), historyMetaHolds(c.before, text) else { return false }
            HistoryText.replace(&text, c.at, c.removed.utf8.count, with: c.inserted)
            guard historyMetaHolds(c.after, text) else { return false }
        }
        return true
    }

    /// Whether `m`'s offsets are on character boundaries of `text`, its blocks one a line (or
    /// none) and its soft breaks inside it (`history::meta_holds`).
    static func historyMetaHolds(_ m: HistoryMeta, _ text: String) -> Bool {
        HistoryText.withBytes(text) { t in
            let at = { (n: Int) in HistoryText.isBoundary(t, n) }
            let lines = 1 + t.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
            return at(m.anchor) && at(m.cursor)
                && m.richMarks.allSatisfy { at($0.start) && at($0.end) && $0.start < $0.end }
                && m.marks.allSatisfy { at($0.utf8Range.lowerBound) && at($0.utf8Range.upperBound) }
                && (m.blocks.isEmpty || m.blocks.count == lines)
                && m.softBreaks.allSatisfy { $0 > 0 && $0 < lines }
        }
    }

    static func historyChangeJSON(_ c: HistoryChange) -> [String: Any] {
        [
            "at": c.at,
            "r": c.removed,
            "i": c.inserted,
            "bl": c.lens.0,
            "al": c.lens.1,
            "b": historyMetaJSON(c.before),
            "a": historyMetaJSON(c.after),
        ]
    }

    static func historyMetaJSON(_ m: HistoryMeta) -> [String: Any] {
        let marksJSON: [Any] = m.richMarks.map { r in
            let kind: Any
            switch r.mark {
            case .bold: kind = "b"
            case .italic: kind = "i"
            case .underline: kind = "u"
            case .strike: kind = "s"
            case .code: kind = "c"
            case .link(let url): kind = ["l", url]
            case .pill(let id): kind = ["p", id]
            }
            return [r.start, r.end, kind]
        }
        let blocksJSON: [Any] = m.blocks.map { b in
            switch b {
            case .paragraph: return "p"
            case .quote: return "q"
            case .code: return "c"
            case .bullet(let l): return ["b", Int(l)]
            case .numbered(let l): return ["n", Int(l)]
            }
        }
        return ["a": m.anchor, "f": m.cursor, "m": marksJSON, "k": blocksJSON, "s": m.softBreaks]
    }

    static func historyChangeFrom(_ obj: Any) -> HistoryChange? {
        guard let d = obj as? [String: Any],
              let at = historyInt(d["at"]),
              let removed = d["r"] as? String,
              let inserted = d["i"] as? String,
              let bl = historyInt(d["bl"]),
              let al = historyInt(d["al"]),
              let before = historyMetaFrom(d["b"]),
              let after = historyMetaFrom(d["a"]) else { return nil }
        return HistoryChange(at: at, removed: removed, inserted: inserted, lens: (bl, al), before: before, after: after)
    }

    /// A stored document's selection, marks, blocks and soft breaks, as numbers: `historyMetaHolds`
    /// checks them against the text they're for (`history::meta_from`).
    static func historyMetaFrom(_ obj: Any?) -> HistoryMeta? {
        guard let dict = obj as? [String: Any],
              let anchor = historyInt(dict["a"]),
              let focus = historyInt(dict["f"]),
              let rawMarks = dict["m"] as? [Any],
              let rawBlocks = dict["k"] as? [Any],
              let rawSoft = dict["s"] as? [Any] else { return nil }
        var richMarks: [RichMarkRange] = []
        richMarks.reserveCapacity(rawMarks.count)
        for item in rawMarks {
            guard let arr = item as? [Any], arr.count >= 3,
                  let start = historyInt(arr[0]),
                  let end = historyInt(arr[1]) else { return nil }
            let mark: RichMark
            if let k = arr[2] as? String {
                switch k {
                case "b": mark = .bold
                case "i": mark = .italic
                case "u": mark = .underline
                case "s": mark = .strike
                case "c": mark = .code
                default: return nil
                }
            } else if let pair = arr[2] as? [Any], pair.count >= 2,
                      let tag = pair[0] as? String, let payload = pair[1] as? String {
                switch tag {
                case "l": mark = .link(payload)
                case "p": mark = .pill(payload)
                default: return nil
                }
            } else {
                return nil
            }
            richMarks.append(RichMarkRange(start: start, end: end, mark: mark))
        }
        var blocks: [Block] = []
        blocks.reserveCapacity(rawBlocks.count)
        for item in rawBlocks {
            if let b = item as? String {
                switch b {
                case "p": blocks.append(.paragraph)
                case "q": blocks.append(.quote)
                case "c": blocks.append(.code)
                default: return nil
                }
            } else if let pair = item as? [Any], pair.count >= 2,
                      let tag = pair[0] as? String, let lvl = historyInt(pair[1]) {
                let clamped = UInt8(min(lvl, Int(Block.maxListLevel)))
                switch tag {
                case "b": blocks.append(.bullet(clamped))
                case "n": blocks.append(.numbered(clamped))
                default: return nil
                }
            } else {
                return nil
            }
        }
        var softBreaks: [Int] = []
        softBreaks.reserveCapacity(rawSoft.count)
        for item in rawSoft {
            guard let n = historyInt(item) else { return nil }
            softBreaks.append(n)
        }
        return HistoryMeta(anchor: anchor, cursor: focus, marks: [], richMarks: richMarks, blocks: blocks, softBreaks: softBreaks)
    }

    /// A version-1 snapshot, when every offset in it is on a character boundary of its text
    /// (`history::snapshot_from`).
    static func historySnapshotFrom(_ obj: Any?) -> Snapshot? {
        guard let dict = obj as? [String: Any], let text = dict["t"] as? String,
              let m = historyMetaFrom(obj), historyMetaHolds(m, text) else { return nil }
        return Snapshot(text: text, cursor: m.cursor, anchor: m.anchor, marks: m.marks, richMarks: m.richMarks, blocks: m.blocks, softBreaks: m.softBreaks)
    }

    /// Version 2: the document as written, and each step's change (`history::read_v2`).
    static func historyReadV2(_ dict: [String: Any]) -> (String, [HistoryChange], [HistoryChange])? {
        guard let doc = dict["d"] as? String,
              let undoArr = dict["undo"] as? [Any],
              let redoArr = dict["redo"] as? [Any] else { return nil }
        var undo: [HistoryChange] = []
        for item in undoArr {
            guard let c = historyChangeFrom(item) else { return nil }
            undo.append(c)
        }
        var redo: [HistoryChange] = []
        for item in redoArr {
            guard let c = historyChangeFrom(item) else { return nil }
            redo.append(c)
        }
        return (doc, undo, redo)
    }

    /// Version 1: each step the document before and after it; the document as written is the
    /// newest undo step's after (or the next redo step's before) (`history::read_v1`).
    static func historyReadV1(_ dict: [String: Any]) -> (String, [HistoryChange], [HistoryChange])? {
        func read(_ key: String) -> [(Snapshot, Snapshot)]? {
            guard let arr = dict[key] as? [Any] else { return nil }
            var out: [(Snapshot, Snapshot)] = []
            for item in arr {
                guard let c = item as? [String: Any],
                      let b = historySnapshotFrom(c["b"]),
                      let a = historySnapshotFrom(c["a"]) else { return nil }
                out.append((b, a))
            }
            return out
        }
        guard let undo = read("undo"), let redo = read("redo") else { return nil }
        guard let doc = undo.last.map({ $0.1.text }) ?? redo.last.map({ $0.0.text }) else { return nil }
        return (doc, undo.map { HistoryChange.between($0.0, $0.1) }, redo.map { HistoryChange.between($0.0, $0.1) })
    }

    static func historyInt(_ value: Any?) -> Int? {
        guard let num = value as? NSNumber else { return nil }
        if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
        let d = num.doubleValue
        guard d >= 0, d.rounded(.towardZero) == d, d <= Double(Int.max) else { return nil }
        return Int(d)
    }
}
