import Foundation
import Rune

// MARK: - Myers Linear-Space Diff (`rune_kit::diff::myers`)

/// Edit script operation emitted by `Myers.diff`.
public enum MyersOp: Sendable, Equatable, Hashable {
    case equal(Int)
    case delete(Int)
    case insert(Int)
}

/// Linear-space divide-and-conquer Myers diff (`crate::diff::myers`).
public enum Myers {
    /// Maximum edit distance searched in one subproblem before splitting at its furthest advance.
    public static let maxD = 1024

    public static func diff<T: Equatable>(_ a: [T], _ b: [T]) -> [MyersOp] {
        var oldChanged = Array(repeating: false, count: a.count)
        var newChanged = Array(repeating: false, count: b.count)
        var search = Frontiers(oldCount: a.count, newCount: b.count)
        conquer(a, a.indices, b, b.indices, &search, &oldChanged, &newChanged)
        var ops: [MyersOp] = []
        var old = 0
        var new = 0
        while old < a.count || new < b.count {
            let start = old, newStart = new
            while old < a.count && new < b.count && !oldChanged[old] && !newChanged[new] {
                old += 1
                new += 1
            }
            if old > start { ops.append(.equal(old - start)) }
            let deletion = old
            while old < a.count && oldChanged[old] { old += 1 }
            if old > deletion { ops.append(.delete(old - deletion)) }
            let addition = new
            while new < b.count && newChanged[new] { new += 1 }
            if new > addition { ops.append(.insert(new - addition)) }
            if old == start && new == newStart { break }
        }
        return ops
    }

    /// The furthest x reached on each absolute x−y diagonal. All recursive boxes share these arrays.
    private struct Frontiers {
        var forward: [Int]
        var backward: [Int]
        let offset: Int

        init(oldCount: Int, newCount: Int) {
            forward = Array(repeating: 0, count: oldCount + newCount + 3)
            backward = forward
            offset = newCount + 1
        }
    }

    private static func conquer<T: Equatable>(
        _ a: [T], _ old: Range<Int>, _ b: [T], _ new: Range<Int>,
        _ search: inout Frontiers, _ oldChanged: inout [Bool], _ newChanged: inout [Bool]
    ) {
        var x0 = old.lowerBound, x1 = old.upperBound
        var y0 = new.lowerBound, y1 = new.upperBound
        while x0 < x1 && y0 < y1 && a[x0] == b[y0] {
            x0 += 1
            y0 += 1
        }
        while x0 < x1 && y0 < y1 && a[x1 - 1] == b[y1 - 1] {
            x1 -= 1
            y1 -= 1
        }
        if x0 < x1 && y0 < y1,
           let (x, y) = middleSnake(a, x0..<x1, b, y0..<y1, &search) {
            conquer(a, x0..<x, b, y0..<y, &search, &oldChanged, &newChanged)
            conquer(a, x..<x1, b, y..<y1, &search, &oldChanged, &newChanged)
        } else {
            for i in x0..<x1 { oldChanged[i] = true }
            for i in y0..<y1 { newChanged[i] = true }
        }
    }

    private static func middleSnake<T: Equatable>(
        _ a: [T], _ old: Range<Int>, _ b: [T], _ new: Range<Int>, _ v: inout Frontiers
    ) -> (Int, Int)? {
        let x0 = old.lowerBound, x1 = old.upperBound
        let y0 = new.lowerBound, y1 = new.upperBound
        let minDiagonal = x0 - y1, maxDiagonal = x1 - y0
        var fMin = x0 - y0, fMax = fMin
        var bMin = x1 - y1, bMax = bMin
        let odd = (fMin - bMin) & 1 != 0
        let offset = v.offset
        v.forward[fMin + offset] = x0
        v.backward[bMin + offset] = x1

        func split(_ rawX: Int, _ rawY: Int) -> (Int, Int)? {
            let x = min(x1, max(x0, rawX)), y = min(y1, max(y0, rawY))
            return (x == x0 && y == y0) || (x == x1 && y == y1) ? nil : (x, y)
        }
        for _ in 1...maxD {
            if fMin > minDiagonal {
                fMin -= 1
                v.forward[fMin - 1 + offset] = -1
            } else { fMin += 1 }
            if fMax < maxDiagonal {
                fMax += 1
                v.forward[fMax + 1 + offset] = -1
            } else { fMax -= 1 }
            var d = fMax
            while d >= fMin {
                let i = d + offset
                var x = max(v.forward[i - 1] + 1, v.forward[i + 1])
                var y = x - d
                while x < x1 && y < y1 && a[x] == b[y] { x += 1; y += 1 }
                v.forward[i] = x
                if odd && bMin <= d && d <= bMax && v.backward[i] <= x { return split(x, y) }
                d -= 2
            }
            if bMin > minDiagonal {
                bMin -= 1
                v.backward[bMin - 1 + offset] = Int.max
            } else { bMin += 1 }
            if bMax < maxDiagonal {
                bMax += 1
                v.backward[bMax + 1 + offset] = Int.max
            } else { bMax -= 1 }
            d = bMax
            while d >= bMin {
                let i = d + offset
                var x = min(v.backward[i - 1], v.backward[i + 1] - 1)
                var y = x - d
                while x0 < x && y0 < y && a[x - 1] == b[y - 1] { x -= 1; y -= 1 }
                v.backward[i] = x
                if !odd && fMin <= d && d <= fMax && x <= v.forward[i] { return split(x, y) }
                d -= 2
            }
        }
        // xdiff's bounded-search fallback. Keep the last diagonal on a tie, as Rust's max_by_key does.
        var best = fMin
        for d in stride(from: fMin, through: fMax, by: 2) {
            if 2 * v.forward[d + offset] - d >= 2 * v.forward[best + offset] - best { best = d }
        }
        let x = v.forward[best + offset]
        return split(x, x - best)
    }
}

// MARK: - Word-Level Intra-Line Diff (`rune_kit::diff::words`)

/// Token-level Myers diff on a single changed line pair (`crate::diff::words`).
public enum DiffWords {
    /// Maximum UTF-8 byte length of a line before skipping intra-line word diff (`MAX_LINE_DIFF_LENGTH = 1000`).
    public static let maxLineDiffLength = 1000

    public struct Token: Sendable, Equatable {
        public var utf8Range: Range<Int>
        public var text: String
    }

    @inline(__always)
    static func isWordScalar(_ s: UnicodeScalar) -> Bool {
        switch s.value {
        case 0x61...0x7A, 0x41...0x5A, 0x30...0x39, 0x5F,
             0xAD, 0xC0...0xD6, 0xD8...0xF6, 0xF8...0x2C6,
             0x2C8...0x2D7, 0x2DE...0x2FF, 0x1E00...0x1EFF:
            return true
        default:
            return false
        }
    }

    @inline(__always)
    static func isJsSpace(_ s: UnicodeScalar) -> Bool {
        switch s.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680,
             0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// Tokenizes a line into `jsdiff` `WordsWithSpace` tokens with UTF-8 byte offsets.
    public static func tokenize(_ line: String) -> [Token] {
        enum Kind: Equatable { case word, space }
        func kindOf(_ c: UnicodeScalar) -> Kind? {
            if isWordScalar(c) { return .word }
            if isJsSpace(c) && c.value != 0x0A && c.value != 0x0D { return .space }
            return nil
        }

        var result: [Token] = []
        let scalars = line.unicodeScalars
        let utf8View = line.utf8
        var i = scalars.startIndex
        var prevKind: Kind? = nil

        while i < scalars.endIndex {
            let start = i
            let ch = scalars[i]
            let next = scalars.index(after: i)
            if ch.value == 0x0D && next < scalars.endIndex && scalars[next].value == 0x0A {
                i = scalars.index(after: next)
                let startOff = utf8View.distance(from: utf8View.startIndex, to: start.samePosition(in: utf8View) ?? utf8View.endIndex)
                let endOff = utf8View.distance(from: utf8View.startIndex, to: i.samePosition(in: utf8View) ?? utf8View.endIndex)
                result.append(Token(utf8Range: startOff..<endOff, text: String(scalars[start..<i])))
                prevKind = nil
                continue
            }
            let k = kindOf(ch)
            i = next
            let startOff = utf8View.distance(from: utf8View.startIndex, to: start.samePosition(in: utf8View) ?? utf8View.endIndex)
            let endOff = utf8View.distance(from: utf8View.startIndex, to: i.samePosition(in: utf8View) ?? utf8View.endIndex)
            if let k, prevKind == k, !result.isEmpty {
                let prevLo = result[result.count - 1].utf8Range.lowerBound
                result[result.count - 1].utf8Range = prevLo..<endOff
                result[result.count - 1].text += String(scalars[start..<i])
            } else {
                result.append(Token(utf8Range: startOff..<endOff, text: String(scalars[start..<i])))
            }
            prevKind = k
        }
        return result
    }

    /// Single first-to-last changed byte range on each side (`diff::words::words`).
    public static func words(old: String, new: String) -> (old: Range<Int>?, new: Range<Int>?) {
        if old.utf16.count > maxLineDiffLength || new.utf16.count > maxLineDiffLength {
            return (nil, nil)
        }
        let aTokens = tokenize(old)
        let bTokens = tokenize(new)
        let ops = Myers.diff(aTokens.map(\.text), bTokens.map(\.text))

        var oldRange: Range<Int>? = nil
        var newRange: Range<Int>? = nil
        var ai = 0
        var bi = 0

        func span(_ cur: inout Range<Int>?, toks: [Token], from: Int, to: Int) {
            guard to > from else { return }
            let lo = toks[from].utf8Range.lowerBound
            let hi = toks[to - 1].utf8Range.upperBound
            if let prev = cur {
                cur = prev.lowerBound..<hi
            } else {
                cur = lo..<hi
            }
        }

        for op in ops {
            switch op {
            case .equal(let count):
                ai += count
                bi += count
            case .delete(let count):
                span(&oldRange, toks: aTokens, from: ai, to: ai + count)
                ai += count
            case .insert(let count):
                span(&newRange, toks: bTokens, from: bi, to: bi + count)
                bi += count
            }
        }
        return (oldRange, newRange)
    }

    /// Computes UTF-8 byte ranges in `old` (deleted) and `new` (inserted) matching Pierre `word-line` (at most 1 span per side).
    public static func changedRanges(old: String, new: String) -> (old: [Range<Int>], new: [Range<Int>]) {
        let (o, n) = words(old: old, new: new)
        return (o.map { [$0] } ?? [], n.map { [$0] } ?? [])
    }

    /// Token-level diff returning sequential `(kind, text)` chunks for compatibility helpers.
    public static func wordDiff(old: String, new: String) -> [(kind: DiffLineKind, text: String)] {
        let aTokens = tokenize(old)
        let bTokens = tokenize(new)
        let ops = Myers.diff(aTokens.map(\.text), bTokens.map(\.text))
        var result: [(kind: DiffLineKind, text: String)] = []
        var ai = 0
        var bi = 0

        func appendChunk(_ kind: DiffLineKind, _ text: String) {
            guard !text.isEmpty else { return }
            if let last = result.last, last.kind == kind {
                result[result.count - 1].text += text
            } else {
                result.append((kind, text))
            }
        }

        for op in ops {
            switch op {
            case .equal(let count):
                let joined = aTokens[ai..<(ai + count)].map(\.text).joined()
                appendChunk(.context, joined)
                ai += count
                bi += count
            case .delete(let count):
                let joined = aTokens[ai..<(ai + count)].map(\.text).joined()
                appendChunk(.deletion, joined)
                ai += count
            case .insert(let count):
                let joined = bTokens[bi..<(bi + count)].map(\.text).joined()
                appendChunk(.addition, joined)
                bi += count
            }
        }
        return result
    }
}

// MARK: - Line Pairing & Split Rows (`rune_kit::diff::pairs`)

/// Row in side-by-side (`DiffMode.split`) mode (`crate::diff::pairs::SplitRow`).
public enum SplitRow: Sendable, Equatable {
    case pair(old: DiffLine, new: DiffLine, oldChanged: [Range<Int>], newChanged: [Range<Int>])
    case only(DiffLine)
}

enum DiffPairs {
    static let maxComparisons = 4096
    static let minGain: Double = 0.5

    static func strippedUTF16(_ s: String) -> [UInt16] {
        var out: [UInt16] = []
        out.reserveCapacity(s.utf16.count)
        for scalar in s.unicodeScalars where !DiffWords.isJsSpace(scalar) {
            for cu in scalar.utf16 {
                out.append(cu)
            }
        }
        return out
    }

    /// Common prefix + suffix share over longer length (`pairs.rs:similarity`).
    static func similarity(_ a: [UInt16], _ b: [UInt16]) -> Double {
        if a == b { return 1.0 }
        let maxLen = max(a.count, b.count)
        let minLen = min(a.count, b.count)
        if minLen == 0 { return 0.0 }
        var prefix = 0
        while prefix < minLen && a[prefix] == b[prefix] {
            prefix += 1
        }
        var suffix = 0
        let maxSuffix = minLen - prefix
        while suffix < maxSuffix && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        return Double(prefix + suffix) / Double(maxLen)
    }

    /// Contiguous block alignment `(removedCount, addedCount)` (`pairs.rs:blocks`).
    static func blocks(_ removed: [DiffLine], _ added: [DiffLine]) -> [(Int, Int)] {
        let d = removed.count
        let a = added.count
        let pairs = min(d, a)
        let surplus = abs(d - a)
        if pairs == 0 || surplus == 0 || pairs * (surplus + 1) > maxComparisons {
            return [(d, a)]
        }
        let remKeys = removed.map { strippedUTF16($0.text) }
        let addKeys = added.map { strippedUTF16($0.text) }
        let longerAdded = a > d
        var bestOffset = 0
        var bestScore = -1.0
        for offset in 0...surplus {
            let sr = longerAdded ? 0 : offset
            let sa = longerAdded ? offset : 0
            var score = 0.0
            for k in 0..<pairs {
                score += similarity(remKeys[k + sr], addKeys[k + sa])
            }
            if offset == 0 {
                bestOffset = 0
                bestScore = score + Double(pairs) * minGain
            } else if score > bestScore {
                bestOffset = offset
                bestScore = score
            }
        }
        if bestOffset == 0 {
            return [(d, a)]
        }
        let raw: [(Int, Int)] = longerAdded
            ? [(0, bestOffset), (pairs, pairs), (0, a - pairs - bestOffset)]
            : [(bestOffset, 0), (pairs, pairs), (d - pairs - bestOffset, 0)]
        return raw.filter { $0.0 + $0.1 > 0 }
    }

    private static func pushRun(lines: inout [DiffLine], removed: inout [DiffLine], added: inout [DiffLine]) {
        guard !removed.isEmpty || !added.isEmpty else { return }
        let blockList = blocks(removed, added)
        var rIdx = 0
        var aIdx = 0
        for (d, a) in blockList {
            let start = lines.count
            lines.append(contentsOf: removed[rIdx..<(rIdx + d)])
            lines.append(contentsOf: added[aIdx..<(aIdx + a)])
            rIdx += d
            aIdx += a
            for k in 0..<min(d, a) {
                let i = start + k
                let j = start + d + k
                let (oldCh, newCh) = DiffWords.changedRanges(old: lines[i].text, new: lines[j].text)
                lines[i].pair = j
                lines[i].changes = oldCh
                lines[j].pair = i
                lines[j].changes = newCh
            }
        }
        removed.removeAll(keepingCapacity: true)
        added.removeAll(keepingCapacity: true)
    }

    /// Reorders runs block-by-block and precomputes `pair` + `changes` on every `DiffHunk` (`pairs.rs:pair_lines`).
    static func pairLines(_ hunks: inout [DiffHunk]) {
        for hIdx in hunks.indices {
            var newLines: [DiffLine] = []
            newLines.reserveCapacity(hunks[hIdx].lines.count)
            var rem: [DiffLine] = []
            var add: [DiffLine] = []
            for var l in hunks[hIdx].lines {
                l.pair = nil
                l.changes = []
                switch l.kind {
                case .deletion:
                    rem.append(l)
                case .addition:
                    add.append(l)
                case .context:
                    pushRun(lines: &newLines, removed: &rem, added: &add)
                    newLines.append(l)
                }
            }
            pushRun(lines: &newLines, removed: &rem, added: &add)
            hunks[hIdx].lines = newLines
        }
    }

    static func splitRows(for rawLines: [DiffLine]) -> [SplitRow] {
        var lines = rawLines
        // If any line has precomputed `pair`, trust them directly; otherwise compute pairing once.
        let alreadyPaired = lines.contains(where: { $0.pair != nil })
        if !alreadyPaired && lines.contains(where: { $0.kind == .deletion }) && lines.contains(where: { $0.kind == .addition }) {
            var temp = [DiffHunk(oldStart: 1, oldCount: 0, newStart: 1, newCount: 0, lines: lines)]
            pairLines(&temp)
            lines = temp[0].lines
        }

        var rows: [SplitRow] = []
        rows.reserveCapacity(lines.count)
        for l in lines {
            switch (l.kind, l.pair) {
            case (.addition, .some):
                continue
            case (.deletion, .some(let j)) where lines.indices.contains(j):
                let addedLine = lines[j]
                rows.append(.pair(old: l, new: addedLine, oldChanged: l.changes, newChanged: addedLine.changes))
            default:
                rows.append(.only(l))
            }
        }
        return rows
    }
}

// MARK: - Diff Data Model (`rune_kit::diff::model` & `copy`)

/// Side of a file comparison (`crate::diff::model::Side`).
public enum DiffSide: String, Sendable, Equatable, Hashable, Codable {
    case old
    case new
}

/// Which text to copy from a selection or hunk (`crate::diff::copy::CopySide`).
public enum DiffCopySide: Sendable, Equatable {
    case old
    case new
    case both
}

/// Classification of a single line inside a diff hunk (`crate::diff::model::LineKind`).
public enum DiffLineKind: String, Sendable, Equatable, Hashable {
    case context
    case addition
    case deletion

    /// Legacy compatibility aliases.
    public static let added: Self = .addition
    public static let removed: Self = .deletion
}

/// Status of a changed file (`crate::diff::model::FileStatus`).
public enum FileStatus: Sendable, Equatable, Hashable {
    case modified
    case added
    case deleted
    case renamed(from: String)
    case copied

    public var label: String {
        switch self {
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        }
    }
}

/// Full old/new line buffers attached to a `FileDiff` so folded gaps can expand (`crate::diff::model::Source`).
public struct DiffSource: Sendable, Equatable {
    public var oldLines: [String]
    public var newLines: [String]

    public init(oldLines: [String], newLines: [String]) {
        self.oldLines = oldLines
        self.newLines = newLines
    }

    public init(old: String, new: String) {
        self.oldLines = DiffSource.splitLines(old)
        self.newLines = DiffSource.splitLines(new)
    }

    static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let norm = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = norm.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if norm.hasSuffix("\n") && !lines.isEmpty {
            lines.removeLast()
        }
        return lines
    }

    func slice(_ side: DiffSide, range: Range<Int>) -> [String] {
        let src = (side == .old) ? oldLines : newLines
        let lo = max(0, min(src.count, range.lowerBound))
        let hi = max(lo, min(src.count, range.upperBound))
        return Array(src[lo..<hi])
    }
}

/// A single diff line with 1-based old/new file line numbers (`crate::diff::model::Line`).
public struct DiffLine: Sendable, Equatable, Hashable {
    public var kind: DiffLineKind
    public var oldNumber: Int?
    public var newNumber: Int?
    public var text: String
    public var noNewline: Bool
    public var changes: [Range<Int>]
    public var pair: Int?

    public var oldLine: UInt32? { oldNumber.map { UInt32($0) } }
    public var newLine: UInt32? { newNumber.map { UInt32($0) } }

    public init(
        kind: DiffLineKind,
        oldNumber: Int?,
        newNumber: Int?,
        text: String,
        noNewline: Bool = false,
        changes: [Range<Int>] = [],
        pair: Int? = nil
    ) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
        self.noNewline = noNewline
        self.changes = changes
        self.pair = pair
    }

    public func lineNumber(for side: DiffSide) -> UInt32? {
        switch side {
        case .old: oldLine
        case .new: newLine
        }
    }
}

/// Contiguous context hunk inside a `FileDiff` (`crate::diff::model::Hunk`).
public struct DiffHunk: Sendable, Equatable, Hashable {
    public var header: String
    public var section: String?
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var lines: [DiffLine]

    public init(
        header: String? = nil,
        section: String? = nil,
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        lines: [DiffLine]
    ) {
        self.section = section
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        if let header {
            self.header = header
        } else {
            let oldRange = (oldCount == 1) ? "\(oldStart)" : "\(oldStart),\(oldCount)"
            let newRange = (newCount == 1) ? "\(newStart)" : "\(newStart),\(newCount)"
            let suffix = section.map { $0.isEmpty ? "" : " \($0)" } ?? ""
            self.header = "@@ -\(oldRange) +\(newRange) @@\(suffix)"
        }
        self.lines = lines
    }

    /// Pairs consecutive deletions and additions into side-by-side `SplitRow` entries.
    public func splitRows() -> [SplitRow] {
        DiffPairs.splitRows(for: lines)
    }

    public var additionsCount: Int {
        lines.reduce(0) { $0 + ($1.kind == .addition ? 1 : 0) }
    }

    public var deletionsCount: Int {
        lines.reduce(0) { $0 + ($1.kind == .deletion ? 1 : 0) }
    }
}

/// Rendering layout style (legacy compatibility alias alongside `DiffMode`).
public enum DiffStyle: Sendable, Equatable {
    case unified
    case split

    public var mode: DiffMode {
        switch self {
        case .unified: .unified
        case .split: .split
        }
    }
}

/// Complete file diff with context hunks, status, optional source buffer, and copy/folding helpers (`crate::diff::model::FileDiff`).
public struct FileDiff: Sendable, Equatable {
    public var oldPath: String
    public var newPath: String
    public var status: FileStatus
    public var similarity: UInt8?
    public var oldMode: String?
    public var newMode: String?
    public var hunks: [DiffHunk]
    public var isBinary: Bool
    public var source: DiffSource?

    public var path: String { newPath.isEmpty || newPath == "/dev/null" ? oldPath : newPath }

    public var additionsCount: Int {
        hunks.reduce(0) { $0 + $1.additionsCount }
    }

    public var deletionsCount: Int {
        hunks.reduce(0) { $0 + $1.deletionsCount }
    }

    /// Syntax language name inferred from the file path.
    public var language: String? {
        Syntax.langForPath(path)
    }

    /// The only side that has content for an added, deleted, or one-sided text diff.
    public var soleSide: DiffSide? {
        switch status {
        case .added: return .new
        case .deleted: return .old
        case .modified:
            guard let source else { return nil }
            if source.oldLines.isEmpty && !source.newLines.isEmpty { return .new }
            if source.newLines.isEmpty && !source.oldLines.isEmpty { return .old }
            return nil
        case .renamed, .copied: return nil
        }
    }

    /// True if gap lines between or around hunks can be expanded from `source`.
    public var expandable: Bool {
        source != nil
    }

    /// Highest 1-based line number on the given side present in hunks or source.
    public func lastLine(side: DiffSide) -> UInt32 {
        if let src = source {
            let count = (side == .old) ? src.oldLines.count : src.newLines.count
            return UInt32(max(0, count))
        }
        var maxLine: Int = 0
        for hunk in hunks {
            let end = (side == .old) ? (hunk.oldStart + hunk.oldCount - 1) : (hunk.newStart + hunk.newCount - 1)
            maxLine = max(maxLine, end)
            for l in hunk.lines {
                if let n = (side == .old ? l.oldNumber : l.newNumber) {
                    maxLine = max(maxLine, n)
                }
            }
        }
        return UInt32(max(0, maxLine))
    }

    /// Digit columns needed to display the largest line number across both sides.
    public var columns: Int {
        let maxN = max(Int(lastLine(side: .old)), Int(lastLine(side: .new)))
        return max(2, String(maxN).count)
    }

    /// Width in monospace columns, including lines that can be revealed from a folded gap.
    internal func textColumns(tabSize: Int) -> Int {
        let step = max(1, tabSize)
        func columns(_ line: String) -> Int {
            if !line.utf8.contains(9) { return line.unicodeScalars.count }
            return line.unicodeScalars.reduce(0) { col, scalar in
                col + (scalar == "\t" ? step - col % step : 1)
            }
        }
        var widest = 0
        for hunk in hunks {
            for line in hunk.lines { widest = max(widest, columns(line.text)) }
        }
        if let source {
            for line in source.oldLines { widest = max(widest, columns(line)) }
            for line in source.newLines { widest = max(widest, columns(line)) }
        }
        return widest
    }

    /// Folds a single-hunk full-context diff around its changes with `context` lines each side
    /// (`FileDiff::fold`), preserving pairing and source texts for later gap expansion.
    public func fold(context: Int) -> FileDiff {
        guard hunks.count == 1, !isBinary else { return self }
        let only = hunks[0]
        if only.oldStart > 1 || only.newStart > 1 {
            return self
        }
        let ctx = max(0, context)
        let lines = only.lines
        func sideText(_ side: DiffSide) -> String {
            var out = ""
            for l in lines {
                let keep = l.kind == .context || l.kind == (side == .old ? .deletion : .addition)
                guard keep else { continue }
                out += l.text
                if !l.noNewline {
                    out.append("\n")
                }
            }
            return out
        }
        let oldStr = sideText(.old)
        let newStr = sideText(.new)
        let newSrc = DiffSource(old: oldStr, new: newStr)

        var ranges: [(Int, Int)] = []
        for (i, l) in lines.enumerated() where l.kind != .context {
            let start = max(0, i - ctx)
            let end = min(lines.count - 1, i + ctx)
            if let lastIdx = ranges.indices.last, start <= ranges[lastIdx].1 + 1 {
                ranges[lastIdx].1 = max(ranges[lastIdx].1, end)
            } else {
                ranges.append((start, end))
            }
        }
        func countBefore(_ side: DiffSide, index: Int) -> Int {
            lines[..<index].filter { $0.lineNumber(for: side) != nil }.count
        }
        var copy = self
        copy.hunks = ranges.map { start, end in
            let slice = Array(lines[start...end])
            let ob = countBefore(.old, index: start)
            let nb = countBefore(.new, index: start)
            let oc = slice.filter { $0.lineNumber(for: .old) != nil }.count
            let nc = slice.filter { $0.lineNumber(for: .new) != nil }.count
            return DiffHunk(
                section: FileDiff.findSection(in: newSrc.oldLines, before: ob),
                oldStart: oc == 0 ? ob : ob + 1,
                oldCount: oc,
                newStart: nc == 0 ? nb : nb + 1,
                newCount: nc,
                lines: slice
            )
        }
        DiffPairs.pairLines(&copy.hunks)
        copy.source = newSrc
        return copy
    }

    public init(
        oldPath: String,
        newPath: String,
        status: FileStatus = .modified,
        similarity: UInt8? = nil,
        oldMode: String? = nil,
        newMode: String? = nil,
        hunks: [DiffHunk],
        isBinary: Bool = false,
        source: DiffSource? = nil
    ) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.status = status
        self.similarity = similarity
        self.oldMode = oldMode
        self.newMode = newMode
        self.hunks = hunks
        self.isBinary = isBinary
        self.source = source
    }

    /// Computes a structured context diff between two strings using linear-space `Myers`.
    public static func between(
        old: String,
        new: String,
        path: String = "file",
        context: Int = 3
    ) -> FileDiff {
        var diff = fromTexts(path: path, old: old, new: new, context: context)
        if old.isEmpty && !new.isEmpty {
            diff.status = .added
            diff.oldPath = "/dev/null"
        } else if new.isEmpty && !old.isEmpty {
            diff.status = .deleted
            diff.newPath = "/dev/null"
        }
        return diff
    }

    /// Computes a diff for two versions of the same path (`FileDiff::from_texts`).
    public static func fromTexts(
        path: String,
        old: String,
        new: String,
        context: Int = 3
    ) -> FileDiff {
        if old.utf8.contains(0) || new.utf8.contains(0) {
            return FileDiff(oldPath: path, newPath: path, hunks: [], isBinary: true)
        }
        let oldLines = DiffSource.splitLines(old)
        let newLines = DiffSource.splitLines(new)

        let missingOldBreak = !old.isEmpty && old.utf8.last != 10
        let missingNewBreak = !new.isEmpty && new.utf8.last != 10
        let (aIds, bIds) = intern(oldLines, newLines, missingOldBreak: missingOldBreak, missingNewBreak: missingNewBreak)
        let ops = Myers.diff(aIds, bIds)
        var hunks = buildContextHunks(oldLines: oldLines, newLines: newLines, ops: ops, context: max(0, context),
                                      missingOldBreak: missingOldBreak, missingNewBreak: missingNewBreak)
        DiffPairs.pairLines(&hunks)

        return FileDiff(
            oldPath: path,
            newPath: path,
            hunks: hunks,
            isBinary: false,
            source: DiffSource(oldLines: oldLines, newLines: newLines)
        )
    }

    /// Builds a `FileDiff` when either `old` or `new` may be nil (`FileDiff::patch`).
    public static func patch(
        old: String?,
        new: String?,
        path: String,
        oldPath: String? = nil,
        context: Int = 3
    ) -> FileDiff {
        var diff = fromTexts(path: path, old: old ?? "", new: new ?? "", context: context)
        if old == nil && new != nil {
            diff.status = .added
            diff.oldPath = "/dev/null"
            diff.newPath = path
        } else if new == nil && old != nil {
            diff.status = .deleted
            diff.oldPath = oldPath ?? path
            diff.newPath = "/dev/null"
        } else if let oldPath, oldPath != path {
            diff.status = .renamed(from: oldPath)
            diff.oldPath = oldPath
            diff.newPath = path
        }
        return diff
    }

    /// Attaches a full `DiffSource` to a parsed patch for gap expansion (`fold`).
    public func withSource(_ source: DiffSource) -> FileDiff {
        var copy = self
        copy.source = source
        return copy
    }

    /// Word-level intra-line diff (`FileDiff.wordDiff`).
    public static func wordDiff(old: String, new: String) -> [(kind: DiffLineKind, text: String)] {
        DiffWords.wordDiff(old: old, new: new)
    }

    /// Parses a unified diff (`git diff` / `diff -u`) string into `FileDiff` values.
    public static func parseUnified(_ patch: String) -> [FileDiff] {
        parse(patch)
    }

    /// Parses a unified diff (`git diff` / `diff -u`) string into `FileDiff` values (`FileDiff::parse`).
    public static func parse(_ patch: String) -> [FileDiff] {
        let lines: [String] = patch.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            raw.hasSuffix("\r") ? String(raw.dropLast()) : String(raw)
        }

        var files: [FileDiff] = []
        var cur: FileDiff? = nil
        var inHeader = false

        func flushCur() {
            guard var f = cur else { return }
            cur = nil
            if f.status == .modified {
                if f.oldPath == "/dev/null" {
                    f.status = .added
                } else if f.newPath == "/dev/null" {
                    f.status = .deleted
                } else if !f.oldPath.isEmpty && !f.newPath.isEmpty && f.oldPath != f.newPath {
                    f.status = .renamed(from: f.oldPath)
                }
            }
            DiffPairs.pairLines(&f.hunks)
            files.append(f)
        }

        func stripGitPrefix(_ raw: String) -> String {
            let p = unquoteGitPath(raw)
            if p.hasPrefix("a/") || p.hasPrefix("b/") {
                return String(p.dropFirst(2))
            }
            return p
        }

        func pathOf(_ raw: String) -> String {
            let s: String = if raw.hasPrefix("\"") {
                raw
            } else {
                raw.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
            }
            let trimmed = String(s.reversed().drop(while: { $0.isWhitespace }).reversed())
            if trimmed == "/dev/null" {
                return "/dev/null"
            }
            return stripGitPrefix(trimmed)
        }

        func applyHeaderLine(_ f: inout FileDiff, _ l: String) {
            func afterPrefix(_ p: String) -> String? {
                guard l.hasPrefix(p) else { return nil }
                return String(l.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            }
            if let m = afterPrefix("old mode ") {
                f.oldMode = m
            } else if let m = afterPrefix("new mode ") {
                f.newMode = m
            } else if let m = afterPrefix("new file mode ") {
                f.newMode = m
                f.status = .added
                f.oldPath = "/dev/null"
            } else if let m = afterPrefix("deleted file mode ") {
                f.oldMode = m
                f.status = .deleted
                f.newPath = "/dev/null"
            } else if let p = afterPrefix("rename from ") {
                let u = unquoteGitPath(p)
                f.oldPath = u
                f.status = .renamed(from: u)
            } else if let p = afterPrefix("rename to ") {
                f.newPath = unquoteGitPath(p)
                if case .renamed = f.status {} else {
                    f.status = .renamed(from: f.oldPath)
                }
            } else if let p = afterPrefix("copy from ") {
                f.oldPath = unquoteGitPath(p)
                f.status = .copied
            } else if let p = afterPrefix("copy to ") {
                f.newPath = unquoteGitPath(p)
                f.status = .copied
            } else if let s = afterPrefix("similarity index ") {
                let digits = s.hasSuffix("%") ? String(s.dropLast()) : s
                f.similarity = UInt8(digits)
            } else if let rest = afterPrefix("index ") {
                if let sp = rest.firstIndex(of: " ") {
                    let mode = String(rest[rest.index(after: sp)...])
                    if f.oldMode == nil { f.oldMode = mode }
                    if f.newMode == nil { f.newMode = mode }
                }
            } else if l.hasPrefix("Binary files ") || l == "GIT binary patch" {
                f.isBinary = true
            }
        }

        func parseHunkBody(
            header: String,
            parsed: (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String?),
            startIndex: Int
        ) -> (DiffHunk, Int) {
            var oldNum = parsed.oldCount == 0 ? 0 : parsed.oldStart
            var newNum = parsed.newCount == 0 ? 0 : parsed.newStart
            if parsed.oldStart > 0 && parsed.oldCount == 0 { oldNum = parsed.oldStart }
            if parsed.newStart > 0 && parsed.newCount == 0 { newNum = parsed.newStart }
            var oldLeft = parsed.oldCount
            var newLeft = parsed.newCount
            var outLines: [DiffLine] = []
            var idx = startIndex
            while idx < lines.count {
                let l = lines[idx]
                if l.hasPrefix("\\") {
                    if !outLines.isEmpty {
                        outLines[outLines.count - 1].noNewline = true
                    }
                    idx += 1
                    continue
                }
                if oldLeft == 0 && newLeft == 0 {
                    break
                }
                let firstByte = l.utf8.first
                let kind: DiffLineKind
                let bodyText: String
                if firstByte == UInt8(ascii: " ") {
                    kind = .context
                    bodyText = String(l.dropFirst())
                } else if l.isEmpty && idx + 1 < lines.count {
                    kind = .context
                    bodyText = ""
                } else if firstByte == UInt8(ascii: "-") && oldLeft > 0 {
                    kind = .deletion
                    bodyText = String(l.dropFirst())
                } else if firstByte == UInt8(ascii: "+") && newLeft > 0 {
                    kind = .addition
                    bodyText = String(l.dropFirst())
                } else {
                    break
                }

                switch kind {
                case .context:
                    guard oldLeft > 0 && newLeft > 0 else {
                        return (DiffHunk(header: header, section: parsed.section, oldStart: parsed.oldStart, oldCount: parsed.oldCount - oldLeft, newStart: parsed.newStart, newCount: parsed.newCount - newLeft, lines: outLines), idx)
                    }
                    oldLeft -= 1
                    newLeft -= 1
                    outLines.append(DiffLine(kind: .context, oldNumber: oldNum, newNumber: newNum, text: bodyText))
                    oldNum += 1
                    newNum += 1
                case .deletion:
                    oldLeft -= 1
                    outLines.append(DiffLine(kind: .deletion, oldNumber: oldNum, newNumber: nil, text: bodyText))
                    oldNum += 1
                case .addition:
                    newLeft -= 1
                    outLines.append(DiffLine(kind: .addition, oldNumber: nil, newNumber: newNum, text: bodyText))
                    newNum += 1
                }
                idx += 1
            }
            let hunk = DiffHunk(
                header: header,
                section: parsed.section,
                oldStart: parsed.oldStart,
                oldCount: parsed.oldCount - oldLeft,
                newStart: parsed.newStart,
                newCount: parsed.newCount - newLeft,
                lines: outLines
            )
            return (hunk, idx)
        }

        var i = 0
        while i < lines.count {
            let l = lines[i]
            if l.hasPrefix("diff --git ") {
                flushCur()
                let rest = String(l.dropFirst("diff --git ".count))
                let parts = parseGitDiffPaths(rest)
                cur = FileDiff(oldPath: parts.old, newPath: parts.new, hunks: [])
                inHeader = true
                i += 1
                continue
            }
            if l.hasPrefix("--- "),
               i + 1 < lines.count, lines[i + 1].hasPrefix("+++ "),
               i + 2 < lines.count, lines[i + 2].hasPrefix("@@ ") {
                let a = pathOf(String(l.dropFirst(4)))
                let b = pathOf(String(lines[i + 1].dropFirst(4)))
                if var f = cur, inHeader {
                    f.oldPath = a
                    f.newPath = b
                    cur = f
                } else {
                    flushCur()
                    cur = FileDiff(oldPath: a, newPath: b, hunks: [])
                }
                inHeader = false
                i += 2
                continue
            }
            if cur != nil {
                if l.hasPrefix("@@ "), let parsed = parseHunkHeader(l) {
                    inHeader = false
                    let (hunk, nextIdx) = parseHunkBody(header: l, parsed: parsed, startIndex: i + 1)
                    cur?.hunks.append(hunk)
                    i = nextIdx
                    continue
                } else if inHeader {
                    applyHeaderLine(&cur!, l)
                }
            }
            i += 1
        }
        flushCur()
        return files
    }

    /// Reconstructs plain file text for the specified side (when `source` is present, returns full source; else reconstructs from hunks).
    public func text(side: DiffSide) -> String {
        if let src = source {
            let lines = (side == .old) ? src.oldLines : src.newLines
            return lines.joined(separator: "\n")
        }
        var out: [String] = []
        for h in hunks {
            for l in h.lines {
                switch (side, l.kind) {
                case (.old, .context), (.old, .deletion):
                    out.append(l.text)
                case (.new, .context), (.new, .addition):
                    out.append(l.text)
                default:
                    break
                }
            }
        }
        return out.joined(separator: "\n")
    }

    /// Flattens hunks to clean copyable text (`includeRemoved: false` copies only `new` / `context` lines).
    public func copyableText(includeRemoved: Bool = false) -> String {
        var out: [String] = []
        for h in hunks {
            for l in h.lines {
                if l.kind == .deletion && !includeRemoved { continue }
                out.append(l.text)
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: Interning, Section Detection & Context Hunk Builder

    private static func intern(_ old: [String], _ new: [String], missingOldBreak: Bool, missingNewBreak: Bool) -> ([Int], [Int]) {
        var table: [String: Int] = [:]
        table.reserveCapacity(old.count + new.count)
        func idFor(_ s: String) -> Int {
            if let id = table[s] { return id }
            let next = table.count
            table[s] = next
            return next
        }
        func ids(_ lines: [String], missingBreak: Bool) -> [Int] {
            var ids = lines.map(idFor)
            // Interned IDs are nonnegative. Use their complement for the unterminated last line.
            if missingBreak, !ids.isEmpty { ids[ids.count - 1] = ~ids[ids.count - 1] }
            return ids
        }
        return (ids(old, missingBreak: missingOldBreak), ids(new, missingBreak: missingNewBreak))
    }

    private static func findSection(in lines: [String], before index: Int) -> String? {
        let end = min(index, lines.count)
        let start = max(0, end - 2000)
        var i = end - 1
        while i >= start {
            let line = lines[i]
            if let first = line.first, first.isLetter || first == "_" || first == "$" {
                let trimmedEnd = String(line.reversed().drop(while: { $0.isWhitespace }).reversed())
                return trimmedEnd.count > 80 ? String(trimmedEnd.prefix(80)) : trimmedEnd
            }
            if i == start { break }
            i -= 1
        }
        return nil
    }

    private static func buildContextHunks(
        oldLines: [String],
        newLines: [String],
        ops: [MyersOp],
        context: Int,
        missingOldBreak: Bool,
        missingNewBreak: Bool
    ) -> [DiffHunk] {
        // Expand MyersOps into indexed edit items tracking old/new line numbers.
        enum Entry {
            case eq(oldIdx: Int, newIdx: Int)
            case del(oldIdx: Int)
            case ins(newIdx: Int)
        }

        var entries: [Entry] = []
        entries.reserveCapacity(oldLines.count + newLines.count)
        var oi = 0
        var ni = 0
        for op in ops {
            switch op {
            case .equal(let k):
                for _ in 0..<k {
                    entries.append(.eq(oldIdx: oi, newIdx: ni))
                    oi += 1
                    ni += 1
                }
            case .delete(let k):
                for _ in 0..<k {
                    entries.append(.del(oldIdx: oi))
                    oi += 1
                }
            case .insert(let k):
                for _ in 0..<k {
                    entries.append(.ins(newIdx: ni))
                    ni += 1
                }
            }
        }

        // Identify non-equal entry ranges
        var changeSpans: [Range<Int>] = []
        var idx = 0
        while idx < entries.count {
            if case .eq = entries[idx] {
                idx += 1
                continue
            }
            let start = idx
            while idx < entries.count {
                if case .eq = entries[idx] { break }
                idx += 1
            }
            changeSpans.append(start..<idx)
        }
        guard !changeSpans.isEmpty else { return [] }

        // Expand each span by `context` and merge overlapping/touching hunks
        var windows: [Range<Int>] = []
        for span in changeSpans {
            let lo = max(0, span.lowerBound - context)
            let hi = min(entries.count, span.upperBound + context)
            if let last = windows.last, lo <= last.upperBound {
                windows[windows.count - 1] = last.lowerBound..<max(last.upperBound, hi)
            } else {
                windows.append(lo..<hi)
            }
        }

        return windows.map { window in
            var lines: [DiffLine] = []
            lines.reserveCapacity(window.count)
            var firstOld: Int?
            var firstNew: Int?
            var oldCount = 0
            var newCount = 0

            for entry in entries[window] {
                switch entry {
                case let .eq(o, n):
                    if firstOld == nil { firstOld = o + 1 }
                    if firstNew == nil { firstNew = n + 1 }
                    oldCount += 1
                    newCount += 1
                    lines.append(DiffLine(kind: .context, oldNumber: o + 1, newNumber: n + 1, text: oldLines[o], noNewline: missingOldBreak && o + 1 == oldLines.count))
                case let .del(o):
                    if firstOld == nil { firstOld = o + 1 }
                    oldCount += 1
                    lines.append(DiffLine(kind: .deletion, oldNumber: o + 1, newNumber: nil, text: oldLines[o], noNewline: missingOldBreak && o + 1 == oldLines.count))
                case let .ins(n):
                    if firstNew == nil { firstNew = n + 1 }
                    newCount += 1
                    lines.append(DiffLine(kind: .addition, oldNumber: nil, newNumber: n + 1, text: newLines[n], noNewline: missingNewBreak && n + 1 == newLines.count))
                }
            }

            let oldStart = firstOld ?? (oldCount == 0 ? 0 : 1)
            let newStart = firstNew ?? (newCount == 0 ? 0 : 1)
            let secIdx = max(0, (firstOld ?? 1) - 1)
            let section = findSection(in: oldLines, before: secIdx)

            return DiffHunk(
                section: section,
                oldStart: oldStart,
                oldCount: oldCount,
                newStart: newStart,
                newCount: newCount,
                lines: lines
            )
        }
    }

    private static func unquoteGitPath(_ p: String) -> String {
        guard p.hasPrefix("\"") && p.hasSuffix("\"") && p.count >= 2 else { return p }
        let inner = p.dropFirst().dropLast()
        let raw = Array(inner.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(raw.count)
        var idx = 0
        while idx < raw.count {
            let c = raw[idx]
            idx += 1
            if c != UInt8(ascii: "\\") {
                out.append(c)
                continue
            }
            guard idx < raw.count else {
                out.append(UInt8(ascii: "\\"))
                break
            }
            let esc = raw[idx]
            idx += 1
            switch esc {
            case UInt8(ascii: "n"): out.append(UInt8(ascii: "\n"))
            case UInt8(ascii: "t"): out.append(UInt8(ascii: "\t"))
            case UInt8(ascii: "r"): out.append(UInt8(ascii: "\r"))
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var val = Int(esc - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    if idx < raw.count, raw[idx] >= UInt8(ascii: "0"), raw[idx] <= UInt8(ascii: "7") {
                        val = val * 8 + Int(raw[idx] - UInt8(ascii: "0"))
                        idx += 1
                    } else {
                        break
                    }
                }
                out.append(UInt8(truncatingIfNeeded: val))
            default:
                out.append(esc)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func quotedEnd(_ s: String) -> String.Index? {
        var escaped = false
        var idx = s.index(after: s.startIndex)
        while idx < s.endIndex {
            let ch = s[idx]
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                return s.index(after: idx)
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    private static func stripAB(_ p: String) -> String {
        let u = unquoteGitPath(p)
        if u.hasPrefix("a/") || u.hasPrefix("b/") {
            return String(u.dropFirst(2))
        }
        return u
    }

    private static func parseGitDiffPaths(_ s: String) -> (old: String, new: String) {
        if s.hasPrefix("\""), let end = quotedEnd(s) {
            let a = stripAB(String(s[..<end]))
            let tail = String(s[end...]).trimmingCharacters(in: .whitespaces)
            let b = stripAB(tail)
            return (a, b)
        }
        let utf8 = Array(s.utf8)
        let half = utf8.count / 2
        if utf8.count % 2 == 1, utf8[half] == UInt8(ascii: " "),
           let midIdx = s.utf8.index(s.utf8.startIndex, offsetBy: half, limitedBy: s.utf8.endIndex),
           let nextIdx = s.utf8.index(after: midIdx) as String.Index? {
            let left = String(s[..<midIdx])
            let right = String(s[nextIdx...])
            if left.hasPrefix("a/"), right.hasPrefix("b/"), left.dropFirst(2) == right.dropFirst(2) {
                return (stripAB(left), stripAB(right))
            }
        }
        if let bRange = s.range(of: " b/") {
            let old = stripAB(String(s[..<bRange.lowerBound]))
            let new = stripAB(String(s[s.index(after: bRange.lowerBound)...]))
            return (old, new)
        }
        return ("", "")
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String?)? {
        guard let endAt = line.dropFirst(3).range(of: " @@") else { return nil }
        let coords = String(line[line.index(line.startIndex, offsetBy: 3)..<endAt.lowerBound])
        let after = String(line[endAt.upperBound...]).trimmingCharacters(in: .whitespaces)
        let section = after.isEmpty ? nil : after

        let parts = coords.split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("-"), parts[1].hasPrefix("+") else { return nil }
        func parseSide(_ raw: Substring) -> (Int, Int)? {
            let comps = raw.dropFirst().split(separator: ",", maxSplits: 1)
            guard let start = Int(comps[0]) else { return nil }
            let count = comps.count > 1 ? (Int(comps[1]) ?? 1) : 1
            return (start, count)
        }
        guard let (os, oc) = parseSide(parts[0]),
              let (ns, nc) = parseSide(parts[1]) else { return nil }
        return (os, oc, ns, nc, section)
    }
}

// MARK: - Interactive Diff State (`rune_kit::diff::state`)

/// Visual layout mode of `DiffState` (`crate::diff::state::DiffMode`).
public enum DiffMode: String, Sendable, Equatable, Hashable, Codable {
    case unified
    case split
}

/// Folded header display mode (`crate::diff::view::line_info::FoldRow`).
public enum DiffFoldRow: Sendable, Equatable, Hashable {
    case summary
    case lineInfo
}

/// Gap expansion direction (`crate::diff::state::Expand`).
public enum DiffExpand: Sendable, Equatable, Hashable {
    case up
    case down
    case all
}

/// Point inside a diff selection (`crate::diff::state::LineRef`).
public struct DiffLineRef: LinePoint, Comparable {
    public var side: DiffSide
    public var line: UInt32

    public init(side: DiffSide, line: UInt32) {
        self.side = side
        self.line = line
    }

    public func joins(with other: DiffLineRef) -> Bool {
        // DiffState scopes each gesture to its file. Both sides of that file can join.
        true
    }

    public static func < (lhs: DiffLineRef, rhs: DiffLineRef) -> Bool {
        if lhs.side != rhs.side {
            return lhs.side == .old
        }
        return lhs.line < rhs.line
    }
}

/// Selected lines in gesture order (`crate::diff::state::LineRange`).
public struct DiffLineRange: Sendable, Equatable, Hashable {
    public var file: Int
    public var start: DiffLineRef
    public var end: DiffLineRef

    public init(file: Int = 0, start: DiffLineRef, end: DiffLineRef) {
        self.file = file
        self.start = start
        self.end = end
    }

    public init?(file: Int = 0, from range: LineRange<DiffLineRef>?) {
        guard let range else { return nil }
        self.init(file: file, start: range.start, end: range.end)
    }

    /// Tests a range on one side by line number. DiffState resolves cross-side ranges by row.
    public func contains(_ ref: DiffLineRef) -> Bool {
        if ref == start || ref == end { return true }
        guard start.side == end.side, ref.side == start.side else { return false }
        return (min(start.line, end.line)...max(start.line, end.line)).contains(ref.line)
    }

    /// Single-line selection range (`LineRange::line`).
    public static func line(_ ref: DiffLineRef) -> DiffLineRange {
        line(ref, file: 0)
    }

    public static func line(_ ref: DiffLineRef, file: Int) -> DiffLineRange {
        DiffLineRange(file: file, start: ref, end: ref)
    }
}

/// Inline review comment attached to a line (`crate::diff::state::Annotation`).
public struct DiffAnnotation: Sendable, Equatable, Hashable {
    public var id: String
    public var file: Int
    public var side: DiffSide
    public var line: UInt32
    public var author: String?
    public var body: String

    public init(id: String, file: Int = 0, side: DiffSide, line: UInt32, author: String? = nil, body: String) {
        self.id = id
        self.file = file
        self.side = side
        self.line = line
        self.author = author
        self.body = body
    }
}

/// Collapsed gap between two context hunks (or file start/end) (`crate::diff::state::Gap`).
public struct DiffGap: Sendable, Equatable, Hashable {
    public var index: Int
    public var oldStart: Int
    public var oldEnd: Int
    public var newStart: Int
    public var newEnd: Int
    public var atStart: Bool
    public var atEnd: Bool

    public var count: Int {
        max(oldEnd - oldStart, newEnd - newStart)
    }

    public var canStep: Bool {
        count > DiffLayout.expandStep
    }
}

/// Constants matching `crate::diff::state` pixel metrics.
public enum DiffLayout {
    public static let expandStep = 20
    public static let lineHeight: Float = 20
    public static let headerHeight: Float = 44
    public static let gapHeight: Float = 32
    public static let noteHeight: Float = 40
}

/// Single flattened virtualized row emitted by `DiffState.rows()` (`crate::diff::state::Row`).
public enum DiffRow: Sendable, Equatable {
    case gap(DiffGap)
    case unified(DiffLine, intraOld: [Range<Int>] = [], intraNew: [Range<Int>] = [])
    case splitPair(old: DiffLine, new: DiffLine, oldChanged: [Range<Int>], newChanged: [Range<Int>])
    case splitOnly(DiffLine)
    case annotation(DiffAnnotation)
    case splitAnnotations(owner: DiffLineRef, old: [DiffAnnotation], new: [DiffAnnotation])

    public var baseHeight: Float {
        switch self {
        case .gap: DiffLayout.gapHeight
        case .unified, .splitPair, .splitOnly: DiffLayout.lineHeight
        case .annotation: DiffLayout.noteHeight
        case let .splitAnnotations(_, old, new): Float(max(old.count, new.count)) * DiffLayout.noteHeight
        }
    }

    fileprivate func line(on side: DiffSide) -> DiffLine? {
        switch self {
        case .gap, .annotation, .splitAnnotations:
            return nil
        case .unified(let line, _, _), .splitOnly(let line):
            return line.lineNumber(for: side) == nil ? nil : line
        case let .splitPair(old, new, _, _):
            return side == .old ? old : new
        }
    }

    public func lineRef(for mode: DiffMode, preferredSide: DiffSide? = nil) -> DiffLineRef? {
        func ref(on side: DiffSide) -> DiffLineRef? {
            line(on: side)?.lineNumber(for: side).map { DiffLineRef(side: side, line: $0) }
        }
        let side = preferredSide ?? .new
        if let preferred = ref(on: side) { return preferred }
        if mode == .split && preferredSide != nil { return nil }
        return ref(on: side == .old ? .new : .old)
    }
}

private struct GapExpansion: Sendable, Equatable, Hashable {
    var top: Int = 0
    var bottom: Int = 0
}

private struct DiffFileUI: Sendable, Equatable, Hashable {
    var collapsed: Bool = false
    var expansions: [Int: GapExpansion] = [:]
}

private extension DiffHunk {
    func lineRange(on side: DiffSide) -> Range<Int> {
        let (start, count) = side == .old ? (oldStart, oldCount) : (newStart, newCount)
        let first = count == 0 ? start + 1 : max(1, start)
        return first..<(first + max(0, count))
    }
}

/// Highlighter input is always 128 raw lines from the same side, including folded context.
private final class DiffHighlightCache: @unchecked Sendable {
    private struct Key: Hashable {
        let file: Int
        let side: DiffSide
        let chunk: Int
        let highlighter: Data
    }

    private struct HunkSide: Hashable {
        let file: Int
        let hunk: Int
        let side: DiffSide
    }

    private struct Chunk {
        let starts: [Int]
        let colors: [SyntaxHighlight]

        func highlights(line: Int) -> [SyntaxHighlight] {
            let start = starts[line]
            let end = starts[line + 1] - 1
            var lo = 0, hi = colors.count
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                if colors[mid].range.upperBound <= start { lo = mid + 1 } else { hi = mid }
            }
            var result: [SyntaxHighlight] = []
            for color in colors[lo...] {
                if color.range.lowerBound >= end { break }
                let a = max(start, color.range.lowerBound), b = min(end, color.range.upperBound)
                if a < b { result.append(SyntaxHighlight(range: (a - start)..<(b - start), paint: color.paint)) }
            }
            return result
        }
    }

    let version = UUID()
    private let lock = NSLock()
    private var chunks: [Key: Chunk] = [:]
    private var sideRows: [HunkSide: [Int]] = [:]
    private static let chunkSize = 128

    func highlights(file: Int, diff: FileDiff, side: DiffSide, line: UInt32, language: String?,
                    highlighter: SyntaxHighlighter) -> [SyntaxHighlight] {
        if highlighter.isBuiltin && language.map(Syntax.known) != true { return [] }
        let offset = max(0, Int(line) - 1)
        let key = Key(file: file, side: side, chunk: offset / Self.chunkSize, highlighter: Data(highlighter.id.utf8))
        let chunk: Chunk
        if let cached = lock.withLock({ chunks[key] }) {
            chunk = cached
        } else {
            // Highlight outside the lock: a custom highlighter may call back into the app.
            let (text, starts) = source(file: file, diff: diff, side: side, firstLine: key.chunk * Self.chunkSize + 1)
            let computed = Chunk(starts: starts, colors: highlighter.highlight(language: language, code: text))
            chunk = lock.withLock {
                if let cached = chunks[key] { return cached }
                if chunks.count > 512 { chunks.removeAll(keepingCapacity: true) }
                chunks[key] = computed
                return computed
            }
        }
        return chunk.highlights(line: offset % Self.chunkSize)
    }

    private func source(file: Int, diff: FileDiff, side: DiffSide, firstLine: Int) -> (String, [Int]) {
        let hunks = diff.hunks
        var h = 0, hi = hunks.count
        while h < hi {
            let mid = h + (hi - h) / 2
            if hunks[mid].lineRange(on: side).upperBound <= firstLine { h = mid + 1 } else { hi = mid }
        }
        var rows: [Int]?
        var text = ""
        var starts: [Int] = []
        starts.reserveCapacity(Self.chunkSize + 1)
        for n in firstLine..<(firstLine + Self.chunkSize) {
            starts.append(text.utf8.count)
            while h < hunks.count && hunks[h].lineRange(on: side).upperBound <= n {
                h += 1
                rows = nil
            }
            if h < hunks.count, hunks[h].lineRange(on: side).contains(n) {
                let hunk = hunks[h]
                let positions = rows ?? lock.withLock {
                    let key = HunkSide(file: file, hunk: h, side: side)
                    if let existing = sideRows[key] { return existing }
                    let positions = hunk.lines.indices.filter { hunk.lines[$0].lineNumber(for: side) != nil }
                    sideRows[key] = positions
                    return positions
                }
                rows = positions
                let i = n - hunk.lineRange(on: side).lowerBound
                if positions.indices.contains(i) { text += hunk.lines[positions[i]].text }
            } else if let source = diff.source {
                let old = h == 0 ? 1 : hunks[h - 1].lineRange(on: .old).upperBound
                let new = h == 0 ? 1 : hunks[h - 1].lineRange(on: .new).upperBound
                let delta = n - (side == .old ? old : new)
                if source.oldLines.indices.contains(old + delta - 1) {
                    text += source.oldLines[old + delta - 1]
                } else if source.newLines.indices.contains(new + delta - 1) {
                    text += source.newLines[new + delta - 1]
                }
            }
            text.append("\n")
        }
        starts.append(text.utf8.count)
        return (text, starts)
    }
}

// A structural edit replaces the cache on that DiffState value. Unedited copies, scrolls,
// selections, and alternate-mode views can share their immutable row indexes.
private final class DiffRowCache: @unchecked Sendable {
    private let lock = NSLock()
    private var byMode: [DiffMode: DiffRowIndex] = [:]
    private var columnsByTabSize: [Int: [Int]] = [:]
    private var widthsByMode: [DiffMode: [Int: Float]] = [:]

    func contentWidth(for state: DiffState, index: DiffRowIndex, tabSize: Int) -> Float {
        lock.lock()
        defer { lock.unlock() }
        if let width = widthsByMode[state.mode]?[tabSize] { return width }
        let columns: [Int]
        if let cached = columnsByTabSize[tabSize] {
            columns = cached
        } else {
            columns = state.files.map { $0.textColumns(tabSize: tabSize) }
            columnsByTabSize[tabSize] = columns
        }
        let width = columns.enumerated().reduce(Float(0)) { width, item in
            let (file, count) = item
            let panes = state.mode == .split && state.files[file].soleSide == nil ? 2 : 1
            return max(width, Float(count * panes) * 7.5 + Float(index.sections[file].digits) * 17 + 92)
        }
        widthsByMode[state.mode, default: [:]][tabSize] = width
        return width
    }

    func index(for state: DiffState) -> DiffRowIndex {
        lock.lock()
        defer { lock.unlock() }
        if let existing = byMode[state.mode] { return existing }
        let index = DiffRowIndex(state)
        byMode[state.mode] = index
        return index
    }
}

fileprivate struct DiffRowIndex: Sendable {
    enum Kind: Sendable {
        case header, binary, empty, line(Int)
    }

    struct Entry: Sendable {
        let file: Int
        let kind: Kind
        let key: String
    }

    struct Section: Sendable {
        let rows: [DiffRow]
        let first: Int
        let lineIndex: [DiffLineRef: Int]
        let estimatedTop: Float
        let digits: Int
        let additions: Int
        let deletions: Int
    }

    let version = UUID()
    var sections: [Section] = []
    var entries: [Entry] = []
    var withoutHeaders: [Entry] = []
    var hunks: [Int] = []

    init(_ state: DiffState) {
        var estimatedTop: Float = 0
        let annotations = Dictionary(grouping: state.annotations, by: { $0.file })
        for (file, diff) in state.files.enumerated() {
            let prefix = "df\(file)"
            let first = entries.count
            entries.append(Entry(file: file, kind: .header, key: prefix))
            let bodyStart = entries.count
            var hunkRows: [Int] = []
            let rows = state.makeRows(file: file, annotations: annotations[file] ?? [], hunkRows: &hunkRows)
            var lineIndex: [DiffLineRef: Int] = [:]
            if rows.isEmpty && !state.collapsed(file: file) {
                entries.append(Entry(file: file, kind: diff.isBinary ? .binary : .empty, key: "\(prefix).note"))
            }
            for (i, row) in rows.enumerated() {
                let suffix: String
                func indexLine(_ line: DiffLine) {
                    if let n = line.oldLine { lineIndex[DiffLineRef(side: .old, line: n)] = i }
                    if let n = line.newLine { lineIndex[DiffLineRef(side: .new, line: n)] = i }
                }
                func lineKey(_ line: DiffLine) -> String {
                    switch line.kind {
                    case .addition: "n\(line.newNumber ?? 0)"
                    case .deletion: "o\(line.oldNumber ?? 0)"
                    case .context: "c\(line.oldNumber ?? 0)"
                    }
                }
                switch row {
                case .gap(let gap): suffix = "g\(gap.index)"
                case .annotation(let ann): suffix = "a\(ann.id)"
                case .splitAnnotations(let owner, _, _): suffix = "a\(owner.side.rawValue)\(owner.line)"
                case .unified(let line, _, _), .splitOnly(let line):
                    indexLine(line)
                    suffix = lineKey(line)
                case .splitPair(let old, let new, _, _):
                    indexLine(old)
                    indexLine(new)
                    suffix = lineKey(old)
                }
                entries.append(Entry(file: file, kind: .line(i), key: "\(prefix).\(suffix)"))
            }
            hunks.append(contentsOf: hunkRows.map { bodyStart + $0 })
            withoutHeaders.append(contentsOf: entries[bodyStart...])
            let digits = diff.columns
            sections.append(Section(rows: rows, first: first, lineIndex: lineIndex, estimatedTop: estimatedTop, digits: digits,
                                    additions: diff.additionsCount, deletions: diff.deletionsCount))
            estimatedTop += DiffLayout.headerHeight
            if rows.isEmpty && !state.collapsed(file: file) {
                estimatedTop += DiffLayout.noteHeight
            } else {
                estimatedTop += rows.reduce(0) { $0 + $1.baseHeight }
            }
        }
    }
}

private struct DiffCopyTracker: Sendable, Equatable, Hashable {
    private struct Entry: Sendable, Equatable, Hashable {
        var side: DiffSide
        var cell: String
    }

    private(set) var side: DiffSide = .new
    private var cells: [Entry] = []

    /// Updates active copy side as pointer enters/leaves text cells (`diff::copy::CopySide`).
    mutating func step(side: DiffSide, cell: String, inside: Bool) -> Bool {
        let prev = self.side
        if inside {
            if !cells.contains(where: { $0.cell == cell }) {
                cells.append(Entry(side: side, cell: cell))
            }
            if cells.allSatisfy({ $0.side == side }) {
                self.side = side
            }
        } else {
            cells.removeAll { $0.cell == cell }
        }
        return self.side != prev
    }
}

/// Interactive diff state tracking mode, multi-file folding, gap expansion, annotations, copy side, navigation, and line selection (`crate::diff::state::DiffState`).
public struct DiffState: Sendable, Equatable {
    public var files: [FileDiff] {
        didSet {
            invalidateRows()
            highlightCache = DiffHighlightCache()
            if ui.count > files.count { ui.removeLast(ui.count - files.count) }
            if ui.count < files.count { ui += Array(repeating: DiffFileUI(), count: files.count - ui.count) }
            visibleFile = min(visibleFile, max(0, files.count - 1))
        }
    }
    public var mode: DiffMode {
        didSet { if mode != oldValue { navigationRow = nil } }
    }
    public var wrap: Bool
    public var annotations: [DiffAnnotation] {
        didSet { invalidateRows() }
    }
    public var selection: LineSelectionState<DiffLineRef>
    public var hoveredRow: Int?
    public var copiedToastVisible: Bool
    public var visibleFile: Int
    public var highlighter: SyntaxHighlighter = .builtin {
        didSet {
            highlightCache = DiffHighlightCache()
            highlighterRevision &+= 1
        }
    }
    internal var notifiedVisibleFile: Int?
    private var highlighterRevision: UInt64 = 0
    private var highlightCache = DiffHighlightCache()
    fileprivate var highlightVersion: UUID { highlightCache.version }

    func highlights(file: Int, side: DiffSide, line: UInt32, using highlighter: SyntaxHighlighter? = nil) -> [SyntaxHighlight] {
        guard files.indices.contains(file) else { return [] }
        let diff = files[file]
        return highlightCache.highlights(file: file, diff: diff, side: side, line: line,
                                         language: diff.language, highlighter: highlighter ?? self.highlighter)
    }

    private var rowCache = DiffRowCache()
    fileprivate var rowIndex: DiffRowIndex { rowCache.index(for: self) }
    fileprivate func contentWidth(index: DiffRowIndex, tabSize: Int) -> Float {
        rowCache.contentWidth(for: self, index: index, tabSize: tabSize)
    }
    fileprivate var stickyFile: Int?
    fileprivate var firstVisibleRow: Int?
    fileprivate var hasInlineHeaders = true
    fileprivate var selectionFile = 0
    fileprivate var selectionBeforePress: DiffLineRange?
    private var navigationRow: Int?
    private var ui: [DiffFileUI]
    private var copyTracker = DiffCopyTracker()

    public static func == (lhs: DiffState, rhs: DiffState) -> Bool {
        lhs.files == rhs.files
            && lhs.mode == rhs.mode
            && lhs.wrap == rhs.wrap
            && lhs.annotations == rhs.annotations
            && lhs.selection == rhs.selection
            && lhs.selectionFile == rhs.selectionFile
            && lhs.selectionBeforePress == rhs.selectionBeforePress
            && lhs.hoveredRow == rhs.hoveredRow
            && lhs.copiedToastVisible == rhs.copiedToastVisible
            && lhs.visibleFile == rhs.visibleFile
            && lhs.highlighterRevision == rhs.highlighterRevision
            && lhs.highlighter.id.utf8.elementsEqual(rhs.highlighter.id.utf8)
            && lhs.ui == rhs.ui
    }

    /// Compatibility accessor for the primary file (`files[0]`).
    public var diff: FileDiff {
        get { files.first ?? FileDiff(oldPath: "", newPath: "", hunks: []) }
        set {
            if files.isEmpty {
                files = [newValue]
                ui = [DiffFileUI()]
            } else {
                files[0] = newValue
                if ui.isEmpty { ui = [DiffFileUI()] }
            }
        }
    }

    /// Compatibility accessor for the primary file's expanded state (`!collapsed(file: 0)`).
    public var expanded: Bool {
        get { !collapsed(file: 0) }
        set { setCollapsed(file: 0, !newValue) }
    }

    /// Active copy side tracked from pointer hover over old/new code cells (`copy_side`).
    public var copySide: DiffSide {
        copyTracker.side
    }

    public init(
        files: [FileDiff],
        mode: DiffMode = .unified,
        expanded: Bool = true,
        wrap: Bool = false,
        annotations: [DiffAnnotation] = []
    ) {
        self.files = files
        self.ui = files.map { _ in DiffFileUI(collapsed: !expanded, expansions: [:]) }
        self.mode = mode
        self.wrap = wrap
        self.annotations = annotations
        self.selection = .idle(selected: nil)
        self.hoveredRow = nil
        self.copiedToastVisible = false
        self.visibleFile = 0
    }

    public init(
        diff: FileDiff,
        mode: DiffMode = .unified,
        expanded: Bool = true,
        wrap: Bool = false,
        annotations: [DiffAnnotation] = []
    ) {
        self.init(files: [diff], mode: mode, expanded: expanded, wrap: wrap, annotations: annotations)
    }

    public mutating func setFiles(_ files: [FileDiff]) {
        self.files = files
        self.ui = files.map { _ in DiffFileUI() }
        self.selection = .idle(selected: nil)
        self.hoveredRow = nil
        self.visibleFile = 0
        selectionFile = 0
        selectionBeforePress = nil
        stickyFile = nil
        notifiedVisibleFile = nil
        navigationRow = nil
        firstVisibleRow = nil
    }

    public mutating func setDiff(_ diff: FileDiff) {
        setFiles([diff])
    }

    public func fileIndex(path: String) -> Int? {
        files.firstIndex { $0.path == path || $0.oldPath == path }
    }

    public func collapsed(file: Int) -> Bool {
        guard files.indices.contains(file), ui.indices.contains(file) else { return false }
        return ui[file].collapsed
    }

    private mutating func invalidateRows() {
        rowCache = DiffRowCache()
        navigationRow = nil
    }

    public mutating func setCollapsed(file: Int, _ collapsed: Bool) {
        guard files.indices.contains(file), ui.indices.contains(file) else { return }
        guard ui[file].collapsed != collapsed else { return }
        ui[file].collapsed = collapsed
        invalidateRows()
    }

    public mutating func setMode(_ mode: DiffMode) {
        self.mode = mode
    }

    /// In split mode, returns the sole side `file` shows across the whole width when added or deleted (`DiffState::single_column`).
    public func singleColumn(file: Int = 0) -> DiffSide? {
        guard mode == .split, files.indices.contains(file) else { return nil }
        return files[file].soleSide
    }

    /// Replaces the syntax highlighter used by `DiffState` / `DiffView` (`DiffState::set_highlighter`).
    public mutating func setHighlighter(_ highlighter: SyntaxHighlighter) {
        self.highlighter = highlighter
    }

    public mutating func toggleExpanded() {
        setCollapsed(file: 0, !collapsed(file: 0))
    }

    public mutating func toggleWrap() {
        wrap.toggle()
    }

    /// Tracks pointer entering/leaving a code cell (`copy_side`). Returns true if copy side changed.
    @discardableResult
    public mutating func hoverText(side: DiffSide, cell: String, inside: Bool) -> Bool {
        copyTracker.step(side: side, cell: cell, inside: inside)
    }

    /// Lines still hidden in `file`'s gap `gap`, or `nil` when the file is not expandable.
    public func hidden(file: Int = 0, gap: Int) -> Int? {
        guard files.indices.contains(file) else { return nil }
        guard files[file].expandable else { return nil }
        return computeGaps(file: file).first(where: { $0.index == gap })?.count ?? 0
    }

    /// Expands a collapsed context gap in `up`, `down`, or `all` direction (`state.rs:expand`).
    public mutating func expand(file: Int = 0, gapIndex: Int, direction: DiffExpand) {
        guard files.indices.contains(file), ui.indices.contains(file) else { return }
        let fileDiff = files[file]
        guard fileDiff.expandable else { return }
        let gaps = computeGaps(file: file)
        guard let gap = gaps.first(where: { $0.index == gapIndex }) else { return }
        let remaining = gap.count
        guard remaining > 0 else { return }

        var exp = ui[file].expansions[gapIndex, default: GapExpansion()]
        let last = (gapIndex == fileDiff.hunks.count)
        switch direction {
        case .all:
            exp.top += remaining
        case .up:
            if last {
                exp.top += min(DiffLayout.expandStep, remaining)
            } else {
                // Gap 0 and middle gaps expand bottom edge upward toward hunk above
                exp.bottom += min(DiffLayout.expandStep, remaining)
            }
        case .down:
            exp.top += min(DiffLayout.expandStep, remaining)
        }
        ui[file].expansions[gapIndex] = exp
        invalidateRows()
    }

    /// Convenience single-file wrapper preserved for callers.
    public mutating func expand(gapIndex: Int, direction: DiffExpand) {
        expand(file: 0, gapIndex: gapIndex, direction: direction)
    }

    /// Selects a single line or range on `side`.
    public mutating func select(_ range: DiffLineRange?) {
        selectionFile = range?.file ?? 0
        selectionBeforePress = nil
        let lr = range.map { LineRange(start: $0.start, end: $0.end) }
        selection.step(.set(lr))
    }

    /// Currently active range, from the gesture's anchor to its moving end.
    public var selectedRange: DiffLineRange? {
        DiffLineRange(file: selectionFile, from: selection.selected)
    }

    private func selectedRows(_ selection: DiffLineRange) -> ClosedRange<Int>? {
        guard files.indices.contains(selection.file) else { return nil }
        let index = rowIndex.sections[selection.file].lineIndex
        guard let a = index[selection.start], let b = index[selection.end] else { return nil }
        return min(a, b)...max(a, b)
    }

    /// Whether the given line belongs to this selection in the current row layout.
    public func contains(_ selection: DiffLineRange, at point: DiffLineRef) -> Bool {
        guard let interval = selectedRows(selection),
              let row = rowIndex.sections[selection.file].lineIndex[point] else { return false }
        return interval.contains(row)
    }

    fileprivate func rowSelected(_ row: Int, file: Int, side: DiffSide?) -> Bool {
        guard let sel = selectedRange, sel.file == file,
              selectedRows(sel)?.contains(row) == true else { return false }
        return side == nil || side == sel.start.side || side == sel.end.side
    }

    /// Selected text in document order from the side on which the gesture started.
    public func selectedText() -> String? {
        guard let selection = selectedRange else { return nil }
        return selectedText(selection, side: selection.start.side)
    }

    private func selectedText(_ selection: DiffLineRange, side: DiffSide) -> String? {
        guard let interval = selectedRows(selection) else { return nil }
        let rows = rowIndex.sections[selection.file].rows
        return rows[interval].compactMap { $0.line(on: side)?.text }.joined(separator: "\n")
    }

    /// Copies selected lines, or the visible file when there is no selection.
    public func copyText(side: DiffCopySide? = nil) -> String {
        if let selection = selectedRange {
            let source: DiffSide = switch side {
            case .old: .old
            case .new: .new
            case .both, nil: selection.start.side
            }
            return selectedText(selection, side: source) ?? ""
        }
        let targetFile = files.indices.contains(visibleFile) ? files[visibleFile] : diff
        switch side {
        case .old: return targetFile.text(side: .old)
        case .new: return targetFile.text(side: .new)
        case .both: return targetFile.copyableText(includeRemoved: true)
        case nil: return targetFile.text(side: copySide)
        }
    }

    /// The file covering the given position at the base line and annotation heights.
    public func fileAtY(_ y: Float) -> Int {
        let sections = rowIndex.sections
        var lo = 0
        var hi = sections.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if sections[mid].estimatedTop <= y + 0.5 { lo = mid + 1 } else { hi = mid }
        }
        return max(0, lo - 1)
    }

    public mutating func scrollToFile(_ file: Int, keyPrefix: String = "diff", tx: inout Tx) {
        guard files.indices.contains(file) else { return }
        let index = rowIndex
        var row = index.sections[file].first
        if !hasInlineHeaders || files.count <= 1 {
            let firstBody = row + 1
            if index.entries.indices.contains(firstBody), index.entries[firstBody].file == file {
                row = firstBody
            }
        }
        reveal(row, belowHeader: false, keyPrefix: keyPrefix, tx: &tx)
    }

    public mutating func scrollToLine(_ file: Int, at: DiffLineRef, keyPrefix: String = "diff", tx: inout Tx) {
        guard files.indices.contains(file) else { return }
        if collapsed(file: file) { setCollapsed(file: file, false) }
        if rowIndex.sections[file].lineIndex[at] == nil {
            for gap in computeGaps(file: file) {
                let start = (at.side == .old) ? gap.oldStart : gap.newStart
                let end = (at.side == .old) ? gap.oldEnd : gap.newEnd
                if (start..<end).contains(Int(at.line)) {
                    expand(file: file, gapIndex: gap.index, direction: .all)
                    break
                }
            }
        }
        let section = rowIndex.sections[file]
        if let local = section.lineIndex[at] {
            reveal(section.first + 1 + local, belowHeader: true, keyPrefix: keyPrefix, tx: &tx)
        }
    }

    private mutating func reveal(_ row: Int, belowHeader: Bool, keyPrefix: String, tx: inout Tx) {
        let entry = rowIndex.entries[row]
        let offset = belowHeader && hasInlineHeaders && files.count > 1 ? DiffLayout.headerHeight : 0
        tx.scrollKeyTo("\(keyPrefix)-\(entry.key)", at: offset)
        visibleFile = entry.file
        navigationRow = row
    }

    private func navigationPosition() -> Int {
        guard let firstVisibleRow else { return navigationRow ?? 0 }
        var row = min(firstVisibleRow, max(0, rowIndex.entries.count - 1))
        if stickyFile != nil {
            var height: Float = 0
            let index = rowIndex
            while row + 1 < index.entries.count && height < DiffLayout.headerHeight {
                let entry = index.entries[row]
                switch entry.kind {
                case .header: height += DiffLayout.headerHeight
                case .empty, .binary: height += DiffLayout.noteHeight
                case .line(let i): height += index.sections[entry.file].rows[i].baseHeight
                }
                row += 1
            }
        }
        if let navigationRow, abs(navigationRow - row) <= 3 { return navigationRow }
        return row
    }

    @discardableResult
    public mutating func nextHunk(forward: Bool, keyPrefix: String = "diff", tx: inout Tx) -> Bool {
        let from = navigationPosition()
        let hunks = rowIndex.hunks
        let target = forward ? hunks.first { $0 > from } : hunks.last { $0 < from }
        guard let target else { return false }
        reveal(target, belowHeader: true, keyPrefix: keyPrefix, tx: &tx)
        return true
    }

    @discardableResult
    public mutating func nextFile(forward: Bool, keyPrefix: String = "diff", tx: inout Tx) -> Bool {
        let row = navigationPosition()
        guard rowIndex.entries.indices.contains(row) else { return false }
        let file = rowIndex.entries[row].file
        let target = forward ? file + 1 : file - 1
        guard files.indices.contains(target) else { return false }
        scrollToFile(target, keyPrefix: keyPrefix, tx: &tx)
        return true
    }

    /// Keyboard navigation and copy/clear handler (`DiffState::key`).
    public mutating func key(_ event: KeyEvent, keyPrefix: String = "diff", tx: inout Tx) -> Bool {
        let mods = event.mods
        let noCmdMods = !mods.cmd && !mods.ctrl && !mods.alt && !mods.logo
        switch event.key {
        case .text("j") where noCmdMods:
            return nextHunk(forward: true, keyPrefix: keyPrefix, tx: &tx)
        case .text("k") where noCmdMods:
            return nextHunk(forward: false, keyPrefix: keyPrefix, tx: &tx)
        case .text("]") where noCmdMods:
            return nextFile(forward: true, keyPrefix: keyPrefix, tx: &tx)
        case .text("[") where noCmdMods:
            return nextFile(forward: false, keyPrefix: keyPrefix, tx: &tx)
        case .escape where selection.selected != nil:
            select(nil)
            return true
        case .command("c") where mods.primaryAlone, .text("c") where mods.primaryCommand && mods.primaryAlone:
            if let value = selectedText() {
                tx.copyText(value)
                return true
            }
            return false
        default:
            return false
        }
    }

    /// Returns gap descriptors for `file` accounting for expansions so far.
    public func computeGaps(file: Int = 0) -> [DiffGap] {
        guard files.indices.contains(file) else { return [] }
        let targetDiff = files[file]
        guard !targetDiff.hunks.isEmpty else { return [] }
        let expansions = ui.indices.contains(file) ? ui[file].expansions : [:]
        var gaps: [DiffGap] = []
        let hunks = targetDiff.hunks

        // Leading gap (index 0) before hunk 0
        let exp0 = expansions[0, default: GapExpansion()]
        let leadingOldEnd = max(1, hunks[0].oldStart - exp0.bottom)
        let leadingNewEnd = max(1, hunks[0].newStart - exp0.bottom)
        if leadingOldEnd > 1 + exp0.top || leadingNewEnd > 1 + exp0.top {
            gaps.append(DiffGap(
                index: 0,
                oldStart: 1 + exp0.top,
                oldEnd: leadingOldEnd,
                newStart: 1 + exp0.top,
                newEnd: leadingNewEnd,
                atStart: true,
                atEnd: false
            ))
        }

        // Between consecutive hunks (index k + 1)
        for k in 0..<(hunks.count - 1) {
            let prev = hunks[k]
            let next = hunks[k + 1]
            let idx = k + 1
            let exp = expansions[idx, default: GapExpansion()]
            let oStart = prev.oldStart + prev.oldCount + exp.top
            let oEnd = next.oldStart - exp.bottom
            let nStart = prev.newStart + prev.newCount + exp.top
            let nEnd = next.newStart - exp.bottom
            if oEnd > oStart || nEnd > nStart {
                gaps.append(DiffGap(
                    index: idx,
                    oldStart: oStart,
                    oldEnd: max(oStart, oEnd),
                    newStart: nStart,
                    newEnd: max(nStart, nEnd),
                    atStart: false,
                    atEnd: false
                ))
            }
        }

        // Trailing gap (index hunks.count) if source has trailing lines
        if let src = targetDiff.source, let last = hunks.last {
            let idx = hunks.count
            let exp = expansions[idx, default: GapExpansion()]
            let oStart = last.oldStart + last.oldCount + exp.top
            let oEnd = src.oldLines.count + 1 - exp.bottom
            let nStart = last.newStart + last.newCount + exp.top
            let nEnd = src.newLines.count + 1 - exp.bottom
            if oEnd > oStart || nEnd > nStart {
                gaps.append(DiffGap(
                    index: idx,
                    oldStart: oStart,
                    oldEnd: max(oStart, oEnd),
                    newStart: nStart,
                    newEnd: max(nStart, nEnd),
                    atStart: false,
                    atEnd: true
                ))
            }
        }
        return gaps
    }

    private func contextLinesFromSource(
        file: Int,
        oldStart1: Int,
        newStart1: Int,
        count: Int
    ) -> [DiffLine] {
        guard files.indices.contains(file), count > 0, let src = files[file].source else { return [] }
        var out: [DiffLine] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let oNum = oldStart1 + i
            let nNum = newStart1 + i
            let text: String
            if oNum >= 1 && oNum <= src.oldLines.count {
                text = src.oldLines[oNum - 1]
            } else if nNum >= 1 && nNum <= src.newLines.count {
                text = src.newLines[nNum - 1]
            } else {
                continue
            }
            out.append(DiffLine(kind: .context, oldNumber: oNum, newNumber: nNum, text: text))
        }
        return out
    }

    /// Returns hunks including lines expanded out of adjacent gaps.
    public func effectiveHunks(file: Int = 0) -> [DiffHunk] {
        guard files.indices.contains(file) else { return [] }
        let targetDiff = files[file]
        guard !targetDiff.hunks.isEmpty else { return [] }
        let hunks = targetDiff.hunks
        let expansions = ui.indices.contains(file) ? ui[file].expansions : [:]
        var result: [DiffHunk] = []
        for (k, h) in hunks.enumerated() {
            var lines = h.lines
            // Prepend expanded bottom of gap `k` (and top of gap 0 when .all opened it) above this hunk
            let gapAbove = expansions[k, default: GapExpansion()]
            if (gapAbove.bottom > 0 || (k == 0 && gapAbove.top > 0)), targetDiff.source != nil {
                let prevEndOld = (k == 0) ? 1 : (hunks[k - 1].oldStart + hunks[k - 1].oldCount)
                let avail = max(0, h.oldStart - prevEndOld)
                let wanted = (k == 0) ? (gapAbove.bottom + gapAbove.top) : gapAbove.bottom
                let take = min(avail, wanted)
                if take > 0 {
                    let pre = contextLinesFromSource(
                        file: file,
                        oldStart1: h.oldStart - take,
                        newStart1: h.newStart - take,
                        count: take
                    )
                    lines = pre + lines.map { original in
                        var line = original
                        if let pair = line.pair { line.pair = pair + pre.count }
                        return line
                    }
                }
            }

            // Append expanded top of gap `k + 1` below this hunk
            let gapBelow = expansions[k + 1, default: GapExpansion()]
            if gapBelow.top > 0, let src = targetDiff.source {
                let nextOldStart = (k + 1 < hunks.count) ? hunks[k + 1].oldStart : (src.oldLines.count + 1)
                let avail = max(0, nextOldStart - (h.oldStart + h.oldCount))
                let topTake = min(avail, gapBelow.top)
                if topTake > 0 {
                    let post = contextLinesFromSource(
                        file: file,
                        oldStart1: h.oldStart + h.oldCount,
                        newStart1: h.newStart + h.newCount,
                        count: topTake
                    )
                    lines.append(contentsOf: post)
                }
            }

            result.append(DiffHunk(
                header: h.header,
                section: h.section,
                oldStart: lines.first?.oldNumber ?? h.oldStart,
                oldCount: lines.filter { $0.kind != .addition }.count,
                newStart: lines.first?.newNumber ?? h.newStart,
                newCount: lines.filter { $0.kind != .deletion }.count,
                lines: lines
            ))
        }
        return result
    }

    /// Flattens hunks, gaps, intra-line diffs, and annotations into renderable `DiffRow` values.
    public func rows(file: Int = 0) -> [DiffRow] {
        guard files.indices.contains(file) else { return [] }
        return rowIndex.sections[file].rows
    }

    fileprivate func makeRows(file: Int, annotations: [DiffAnnotation], hunkRows: inout [Int]) -> [DiffRow] {
        guard !files[file].isBinary, !collapsed(file: file) else { return [] }
        let hunks = ui[file].expansions.isEmpty ? files[file].hunks : effectiveHunks(file: file)
        guard !hunks.isEmpty else { return [] }
        let gaps = computeGaps(file: file)
        let gapByIndex = Dictionary(uniqueKeysWithValues: gaps.map { ($0.index, $0) })

        // Index annotations by (side, line) for this file
        var annsByLine: [DiffLineRef: [DiffAnnotation]] = [:]
        for ann in annotations {
            annsByLine[DiffLineRef(side: ann.side, line: ann.line), default: []].append(ann)
        }

        var out: [DiffRow] = []

        func appendAnnotations(forOld o: UInt32?, new n: UInt32?) {
            let old = o.flatMap { annsByLine[DiffLineRef(side: .old, line: $0)] } ?? []
            let new = n.flatMap { annsByLine[DiffLineRef(side: .new, line: $0)] } ?? []
            guard !old.isEmpty || !new.isEmpty else { return }
            if mode == .split, let owner = o.map({ DiffLineRef(side: .old, line: $0) }) ?? n.map({ DiffLineRef(side: .new, line: $0) }) {
                out.append(.splitAnnotations(owner: owner, old: old, new: new))
            } else {
                out.append(contentsOf: old.map { .annotation($0) })
                out.append(contentsOf: new.map { .annotation($0) })
            }
        }

        if let g0 = gapByIndex[0] {
            out.append(.gap(g0))
        }

        for (k, h) in hunks.enumerated() {
            hunkRows.append(k == 0 ? 0 : out.count)
            if k > 0, let g = gapByIndex[k] {
                out.append(.gap(g))
            }
            switch mode {
            case .unified:
                let split = h.splitRows()
                var intraOldByLine: [Int: [Range<Int>]] = [:]
                var intraNewByLine: [Int: [Range<Int>]] = [:]
                for r in split {
                    if case let .pair(old, new, oCh, nCh) = r {
                        if let on = old.oldNumber { intraOldByLine[on] = oCh }
                        if let nn = new.newNumber { intraNewByLine[nn] = nCh }
                    }
                }
                for l in h.lines {
                    let iOld = (l.kind == .deletion ? l.oldNumber.flatMap { intraOldByLine[$0] } : nil) ?? []
                    let iNew = (l.kind == .addition ? l.newNumber.flatMap { intraNewByLine[$0] } : nil) ?? []
                    out.append(.unified(l, intraOld: iOld, intraNew: iNew))
                    appendAnnotations(forOld: l.oldLine, new: l.newLine)
                }
            case .split:
                for r in h.splitRows() {
                    switch r {
                    case let .pair(old, new, oldChanged, newChanged):
                        out.append(.splitPair(old: old, new: new, oldChanged: oldChanged, newChanged: newChanged))
                        appendAnnotations(forOld: old.oldLine, new: new.newLine)
                    case .only(let l):
                        out.append(.splitOnly(l))
                        appendAnnotations(forOld: l.oldLine, new: l.newLine)
                    }
                }
            }
        }

        if let gEnd = gapByIndex[hunks.count] {
            out.append(.gap(gEnd))
        }

        return out
    }

    /// Computes total body height and visible `[start..<end)` row slice for virtualization.
    public func visibleWindow(
        for rows: [DiffRow],
        scrollY: Float,
        viewportHeight: Float,
        lineHeightMultiplier: Float = 1.0,
        overscan: Int = 8
    ) -> (range: Range<Int>, beforeHeight: Float, afterHeight: Float) {
        guard !rows.isEmpty else { return (0..<0, 0, 0) }
        var ys: [Float] = []
        ys.reserveCapacity(rows.count + 1)
        var acc: Float = 0
        for row in rows {
            ys.append(acc)
            let h: Float = switch row {
            case .gap, .annotation, .splitAnnotations: row.baseHeight
            case .unified, .splitPair, .splitOnly: row.baseHeight * lineHeightMultiplier
            }
            acc += h
        }
        ys.append(acc)

        if viewportHeight <= 0 {
            return (0..<rows.count, 0, 0)
        }

        let topY = max(0, scrollY)
        let botY = topY + viewportHeight

        // Binary search first visible row
        var lo = 0
        var hi = rows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ys[mid + 1] <= topY { lo = mid + 1 } else { hi = mid }
        }
        let firstVis = max(0, lo - overscan)

        lo = firstVis
        hi = rows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ys[mid] < botY { lo = mid + 1 } else { hi = mid }
        }
        let lastVis = min(rows.count, lo + overscan)

        let beforeH = ys[firstVis]
        let afterH = acc - ys[lastVis]
        return (firstVis..<lastVis, beforeH, afterH)
    }
}

// MARK: - OKLab Color Tinting Helper

private func diffTintColor(_ base: Color, hue: Color, t: Float) -> Color {
    let clampedT = min(1, max(0, t))
    // Linear RGB interpolation preserving base alpha (safe and fast; OKLab deltas for muted tints match visually)
    return Color(
        r: base.r + (hue.r - base.r) * clampedT,
        g: base.g + (hue.g - base.g) * clampedT,
        b: base.b + (hue.b - base.b) * clampedT,
        a: base.a
    )
}

// MARK: - DiffView Component (`rune_kit::diff::view`)

/// Tint overrides for `DiffView` (`crate::diff::view::Tints`).
public struct DiffTints: Sendable, Equatable {
    public var addition: Color?
    public var deletion: Color?
    public var additionWord: Color?
    public var deletionWord: Color?

    public init(
        addition: Color? = nil,
        deletion: Color? = nil,
        additionWord: Color? = nil,
        deletionWord: Color? = nil
    ) {
        self.addition = addition
        self.deletion = deletion
        self.additionWord = additionWord
        self.deletionWord = deletionWord
    }
}

/// Visual configuration options for `DiffView` (`crate::diff::view::Look`).
public struct DiffLook: Sendable, Equatable {
    public var foldRow: DiffFoldRow
    public var showHeader: Bool
    public var lineHeightMultiplier: Float
    public var tabSize: Int
    public var viewportHeight: Float
    public var tints: DiffTints

    public init(
        foldRow: DiffFoldRow = .summary,
        showHeader: Bool = true,
        lineHeightMultiplier: Float = 1.0,
        tabSize: Int = 4,
        viewportHeight: Float = 0,
        tints: DiffTints = DiffTints()
    ) {
        self.foldRow = foldRow
        self.showHeader = showHeader
        self.lineHeightMultiplier = lineHeightMultiplier
        self.tabSize = tabSize
        self.viewportHeight = viewportHeight
        self.tints = tints
    }
}

/// Virtualized, syntax-highlighted, interactive diff viewer (`crate::diff::view::DiffView`).
public struct DiffView<State>: Sendable {
    public let key: String
    public let kit: Kit
    public let get: @Sendable (State) -> DiffState
    public let set: @Sendable (inout State, DiffState) -> Void
    public var look: DiffLook
    public var highlighter: SyntaxHighlighter {
        didSet { hasCustomHighlighter = true }
    }
    private var hasCustomHighlighter: Bool = false
    public var forcedMode: DiffMode?
    public var onCopyHandler: (@Sendable (inout State, String, inout Tx) -> Void)?
    public var onSelectHandler: (@Sendable (inout State, DiffLineRange?, inout Tx) -> Void)?
    public var onLineClickHandler: (@Sendable (inout State, DiffLineRef, inout Tx) -> Void)?
    public var onCommentHandler: (@Sendable (inout State, DiffLineRange, inout Tx) -> Void)?
    public var onVisibleFileHandler: (@Sendable (inout State, Int) -> Void)?
    public var annotationBuilder: (@Sendable (State, DiffAnnotation) -> El<State>)?
    public var headerActionsBuilder: (@Sendable (State, Int) -> El<State>)?

    public init(
        key: String,
        kit: Kit,
        get: @escaping @Sendable (State) -> DiffState,
        set: @escaping @Sendable (inout State, DiffState) -> Void
    ) {
        self.key = key
        self.kit = kit
        self.get = get
        self.set = set
        self.look = DiffLook()
        self.highlighter = .builtin
    }

    public init(
        key: String,
        kit: Kit,
        state keyPath: WritableKeyPath<State, DiffState> & Sendable
    ) {
        self.init(
            key: key,
            kit: kit,
            get: { $0[keyPath: keyPath] },
            set: { $0[keyPath: keyPath] = $1 }
        )
    }

    public func mode(_ mode: DiffMode) -> Self { var c = self; c.forcedMode = mode; return c }
    public func foldRow(_ row: DiffFoldRow) -> Self { var c = self; c.look.foldRow = row; return c }
    public func showHeader(_ show: Bool) -> Self { var c = self; c.look.showHeader = show; return c }
    public func lineHeight(_ mult: Float) -> Self { var c = self; c.look.lineHeightMultiplier = max(0.8, mult); return c }
    public func tabSize(_ spaces: Int) -> Self { var c = self; c.look.tabSize = max(1, spaces); return c }
    public func viewportHeight(_ h: Float) -> Self { var c = self; c.look.viewportHeight = max(0, h); return c }
    public func tints(_ tints: DiffTints) -> Self { var c = self; c.look.tints = tints; return c }
    public func highlighter(_ hl: SyntaxHighlighter) -> Self {
        var c = self
        c.highlighter = hl
        return c
    }
    public func onCopy(_ fn: @escaping @Sendable (inout State, String, inout Tx) -> Void) -> Self {
        var c = self; c.onCopyHandler = fn; return c
    }
    public func onSelect(_ fn: @escaping @Sendable (inout State, DiffLineRange?, inout Tx) -> Void) -> Self {
        var c = self; c.onSelectHandler = fn; return c
    }
    public func onLineClick(_ fn: @escaping @Sendable (inout State, DiffLineRef, inout Tx) -> Void) -> Self {
        var c = self; c.onLineClickHandler = fn; return c
    }
    public func onComment(_ fn: @escaping @Sendable (inout State, DiffLineRange, inout Tx) -> Void) -> Self {
        var c = self; c.onCommentHandler = fn; return c
    }
    public func onVisibleFile(_ fn: @escaping @Sendable (inout State, Int) -> Void) -> Self {
        var c = self; c.onVisibleFileHandler = fn; return c
    }
    public func annotation(_ fn: @escaping @Sendable (State, DiffAnnotation) -> El<State>) -> Self {
        var c = self; c.annotationBuilder = fn; return c
    }
    public func headerActions(_ fn: @escaping @Sendable (State, Int) -> El<State>) -> Self {
        var c = self; c.headerActionsBuilder = fn; return c
    }

    /// Builds a read-only `El<State>` without evaluating any `State` value (`Kit.diffView` compatibility).
    public func buildReadOnly(diffState: DiffState, cx: Cx<State> = Cx<State>(viewport: .zero)) -> El<State> {
        var st = diffState
        if let forcedMode {
            st.mode = forcedMode
        }
        return renderContainer(hostState: nil, diffState: st, cx: cx)
    }

    public func build(state: State, cx: Cx<State>) -> El<State> {
        var diffState = get(state)
        if let forcedMode {
            diffState.mode = forcedMode
        }
        return renderContainer(hostState: state, diffState: diffState, cx: cx)
    }

    private func filePrefix(_ fileIndex: Int) -> String {
        fileIndex == 0 ? key : "\(key)-f\(fileIndex)"
    }

    private func renderContainer(hostState: State?, diffState st: DiffState, cx: Cx<State>) -> El<State> {
        let k = kit
        let syntaxTheme = SyntaxTheme.fromKit(k)
        let lineH = DiffLayout.lineHeight * look.lineHeightMultiplier

        let addColor = k.c.success.fg
        let delColor = k.c.danger.fg
        let addLineBg = look.tints.addition ?? diffTintColor(k.c.surfaceBase, hue: addColor, t: 0.14)
        let delLineBg = look.tints.deletion ?? diffTintColor(k.c.surfaceBase, hue: delColor, t: 0.14)
        let addWordBg = look.tints.additionWord ?? diffTintColor(k.c.surfaceBase, hue: addColor, t: 0.28)
        let delWordBg = look.tints.deletionWord ?? diffTintColor(k.c.surfaceBase, hue: delColor, t: 0.28)
        let selBg = k.selection()

        var container = El<State>(direction: .column)
            .key(key)
            .dir(.ltr)
            .wFull()
            .bg(k.c.surfaceBase)
            .border(1, k.c.borderMuted)
            .rounded(k.radius.md)
            .clip()
        if look.viewportHeight == 0 && cx.viewport.y > 0 {
            container = container.maxH(cx.viewport.y)
        }

        let index = st.rowIndex
        let multiple = st.files.count > 1
        let inlineHeaders = multiple && look.showHeader
        let entries = inlineHeaders ? index.entries : index.withoutHeaders
        let contentWidth = st.wrap ? 0 : st.contentWidth(index: index, tabSize: look.tabSize)
        let bodyKey = "\(key)-body"
        let width = cx.layoutWith(bodyKey, token: "diff-width") { $0[2] } ?? max(0, cx.viewport.x - 2)

        if !multiple && look.showHeader {
            container = container.child(buildHeader(hostState: hostState, fileIndex: 0, state: st, diff: st.diff,
                                                    addColor: addColor, delColor: delColor))
        }

        if st.files.isEmpty {
            return container.child(text("No changes").font(k.ty.caption()).color(k.c.textMuted).px(12).py(10))
        }
        if entries.isEmpty { return container }

        let font = k.ty.mono
        // A single line can round up by one device pixel. Leave that headroom at any scale.
        let gutterFitsCode = !st.wrap && font.family == .monospace && font.maxLines == 0
            && font.resolvedLineHeight + 1 <= lineH
            && syntaxTheme.weights.allSatisfy { $0 == nil || $0 == font.weight }

        var list = El<State>(direction: .column).key("\(key)-rows").wFull().shrink(0).role(.list).label("Diff")
        if !st.wrap { list = list.minW(contentWidth) }
        // The runtime gives each virtual row its model key. The inner element preserves the
        // app-facing key for its header, code row, gap, or custom annotation.
        list = list.virtualRows(count: entries.count, estimatedRowHeight: lineH, key: { _, i in
            "\(key)-\(entries[i].key)"
        }, build: { current, i in
            let entry = entries[i]
            let file = entry.file
            let diff = st.files[file]
            let section = index.sections[file]
            let prefix = filePrefix(file)
            let shell = El<State>(direction: .column).wFull().shrink(0)
            let row: El<State>
            switch entry.kind {
            case .header:
                if st.stickyFile == file && inlineHeaders {
                    row = el().h(DiffLayout.headerHeight)
                } else {
                    row = buildHeader(hostState: hostState == nil ? nil : current, fileIndex: file, state: st,
                                      diff: diff, addColor: addColor, delColor: delColor,
                                      fixedWidth: width > 0 ? width : nil, stickyLeft: true)
                }
            case .binary, .empty:
                let message = diff.isBinary ? "Binary file changed — diff preview unavailable" : "No changes"
                row = El<State>(direction: .row).key("\(prefix)-\(diff.isBinary ? "binary" : "empty")")
                    .px(12).py(diff.isBinary ? 12 : 10)
                    .child(text(message).font(k.ty.caption()).color(k.c.textMuted))
            case .line(let local):
                row = renderRow(hostState: hostState == nil ? nil : current, fileIndex: file,
                                           prefix: prefix, rowIdx: local, rows: section.rows, st: st,
                                           syntaxTheme: syntaxTheme, gutterDigits: section.digits,
                                           gutterWidth: Float(section.digits) * 8.5 + 16, lineH: lineH,
                                           addLineBg: addLineBg, delLineBg: delLineBg, addWordBg: addWordBg,
                                           delWordBg: delWordBg, selBg: selBg,
                                           annotationFixedWidth: !st.wrap && width > 0 ? width : nil,
                                           annotationStickyLeft: !st.wrap)
                // The gutter sets the intrinsic height of an ordinary unwrapped code line.
                // Give layout this height directly so remounts can skip measuring its subtree.
                if gutterFitsCode, case .unified(let line, _, _) = section.rows[local], !line.noNewline,
                   line.text.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) {
                    return shell.h(lineH).child(row.h(lineH))
                }
            }
            return shell.child(row)
        }).virtualRowsVersion(index.version)
        if hostState != nil {
            list = list.onVisibleRows { [get, set, onVisibleFileHandler] host, visible in
                guard entries.indices.contains(visible.lowerBound) else { return false }
                let entry = entries[visible.lowerBound]
                var d = get(host)
                let top = visible.lowerBound + (inlineHeaders ? 0 : entry.file + 1)
                let sticky = inlineHeaders && top > index.sections[entry.file].first ? entry.file : nil
                let changed = sticky != d.stickyFile
                let report = d.notifiedVisibleFile != entry.file
                if changed || report || d.firstVisibleRow != top || d.hasInlineHeaders != inlineHeaders {
                    d.stickyFile = sticky
                    d.visibleFile = entry.file
                    d.notifiedVisibleFile = entry.file
                    d.firstVisibleRow = top
                    d.hasInlineHeaders = inlineHeaders
                    set(&host, d)
                    if report { onVisibleFileHandler?(&host, entry.file) }
                }
                return changed || (report && onVisibleFileHandler != nil)
            }
        }
        var body = El<State>(direction: .column).key(bodyKey).wFull()
        body = st.wrap ? body.scrollY() : body.scrollXY()
        if look.viewportHeight > 0 {
            body = body.maxH(look.viewportHeight)
        } else if cx.viewport.y > 0 {
            let header = !multiple && look.showHeader ? DiffLayout.headerHeight : 0
            body = body.maxH(max(0, cx.viewport.y - header - 2)).shrink(1)
        }
        body = body.child(list)
        if inlineHeaders, let file = st.stickyFile, st.files.indices.contains(file) {
            let header = buildHeader(hostState: hostState, fileIndex: file, state: st, diff: st.files[file],
                                     addColor: addColor, delColor: delColor, fixedWidth: width > 0 ? width : nil)
            let overlay = El<State>(direction: .column).absolute(x: 0, y: 0)
                .w(max(width, contentWidth)).stickyTop()
                .child(header.stickyLeft())
            body = body.child(overlay)
        }
        return container.child(body)
    }

    private func renderRow(
        hostState: State?,
        fileIndex: Int,
        prefix: String,
        rowIdx: Int,
        rows: [DiffRow],
        st: DiffState,
        syntaxTheme: SyntaxTheme,
        gutterDigits: Int,
        gutterWidth: Float,
        lineH: Float,
        addLineBg: Color,
        delLineBg: Color,
        addWordBg: Color,
        delWordBg: Color,
        selBg: Color,
        annotationFixedWidth: Float? = nil,
        annotationStickyLeft: Bool = false
    ) -> El<State> {
        switch rows[rowIdx] {
        case .gap(let gap):
            let totalGutterW = 3 + (st.mode == .unified ? 2 * gutterWidth : gutterWidth)
            return buildGapRow(fileIndex: fileIndex, prefix: prefix, gap: gap, height: DiffLayout.gapHeight, gutterWidth: totalGutterW)
        case .annotation(let ann):
            var note = buildAnnotation(hostState: hostState, prefix: prefix, ann: ann)
            if annotationStickyLeft { note = note.stickyLeft(0) }
            return annotationFixedWidth.map { note.w($0) } ?? note.wFull()
        case let .splitAnnotations(owner, old, new):
            return buildSplitAnnotations(hostState: hostState, prefix: prefix, owner: owner, old: old, new: new, single: st.singleColumn(file: fileIndex))
        case let .unified(line, intraOld, intraNew):
            return buildUnifiedRow(
                prefix: prefix,
                rowIdx: rowIdx,
                file: fileIndex,
                line: line,
                intraOld: intraOld,
                intraNew: intraNew,
                st: st,
                syntaxTheme: syntaxTheme,
                gutterDigits: gutterDigits,
                gutterWidth: gutterWidth,
                lineH: lineH,
                addLineBg: addLineBg,
                delLineBg: delLineBg,
                addWordBg: addWordBg,
                delWordBg: delWordBg,
                selBg: selBg
            )
        case let .splitPair(oldLine, newLine, oldChanged, newChanged):
            return buildSplitPairRow(
                prefix: prefix,
                rowIdx: rowIdx,
                file: fileIndex,
                oldLine: oldLine,
                newLine: newLine,
                oldChanged: oldChanged,
                newChanged: newChanged,
                st: st,
                syntaxTheme: syntaxTheme,
                gutterDigits: gutterDigits,
                gutterWidth: gutterWidth,
                lineH: lineH,
                addLineBg: addLineBg,
                delLineBg: delLineBg,
                addWordBg: addWordBg,
                delWordBg: delWordBg,
                selBg: selBg
            )
        case .splitOnly(let line):
            return buildSplitOnlyRow(
                prefix: prefix,
                rowIdx: rowIdx,
                file: fileIndex,
                line: line,
                st: st,
                syntaxTheme: syntaxTheme,
                gutterDigits: gutterDigits,
                gutterWidth: gutterWidth,
                lineH: lineH,
                addLineBg: addLineBg,
                delLineBg: delLineBg,
                selBg: selBg
            )
        }
    }

    // MARK: Header

    private func buildHeader(hostState: State?, fileIndex: Int, state st: DiffState, diff: FileDiff, addColor: Color, delColor: Color, fixedWidth: Float? = nil, stickyLeft: Bool = false) -> El<State> {
        let k = kit
        let prefix = filePrefix(fileIndex)
        let collapsed = st.collapsed(file: fileIndex)
        let titleText: String = switch diff.status {
        case .renamed(let from): "\(from) → \(diff.newPath)"
        default: diff.path
        }

        let foldSummaryText: String = {
            switch look.foldRow {
            case .summary:
                return titleText
            case .lineInfo:
                return "\(titleText)  (\(diff.hunks.count) hunk\(diff.hunks.count == 1 ? "" : "s"))"
            }
        }()

        let statusColor: Color = switch diff.status {
        case .added: k.c.success.fg
        case .deleted: k.c.danger.fg
        case .modified: k.c.warning.fg
        case .renamed, .copied: k.c.textAccent
        }

        let foldBtn = El<State>(direction: .row)
            .key("\(prefix)-fold")
            .role(.button)
            .focusable()
            .itemsCenter()
            .gap(6)
            .child(icon(collapsed ? KitIcons.chevronRight : KitIcons.chevronDown, size: 14).color(k.c.textMuted))
            .child(text(foldSummaryText).font(k.ty.uiMedium).color(k.c.textBase))
            .onClick { [get, set] s in
                var d = get(s)
                d.setCollapsed(file: fileIndex, !d.collapsed(file: fileIndex))
                set(&s, d)
            }

        let statusBadge = El<State>(direction: .row)
            .px(6)
            .py(2)
            .rounded(k.radius.sm)
            .bg(k.alpha(statusColor, 0.14))
            .child(text(diff.status.label).font(k.ty.caption()).color(statusColor))

        let section = st.files.indices.contains(fileIndex) ? st.rowIndex.sections[fileIndex] : nil
        let additions = section?.additions ?? 0
        let deletions = section?.deletions ?? 0
        let stats = El<State>(direction: .row)
            .gap(6)
            .itemsCenter()
            .child(text("+\(additions)").font(k.ty.mono).color(addColor))
            .child(text("-\(deletions)").font(k.ty.mono).color(delColor))

        let modeLabel = (st.mode == .unified) ? "Split" : "Unified"
        let modeBtn = El<State>(direction: .row)
            .key("\(prefix)-mode")
            .role(.button)
            .focusable()
            .px(8)
            .py(3)
            .rounded(k.radius.sm)
            .border(1, k.c.borderMuted)
            .hover(k.c.surfaceHover)
            .onClick { [get, set] s in
                var d = get(s)
                d.setMode(d.mode == .unified ? .split : .unified)
                set(&s, d)
            }
            .child(text(modeLabel).font(k.ty.caption()).color(k.c.textMuted))

        let wrapBtn = El<State>(direction: .row)
            .key("\(prefix)-wrap")
            .role(.button)
            .focusable()
            .px(8)
            .py(3)
            .rounded(k.radius.sm)
            .border(1, st.wrap ? k.c.textAccent : k.c.borderMuted)
            .hover(k.c.surfaceHover)
            .onClick { [get, set] s in
                var d = get(s)
                d.toggleWrap()
                set(&s, d)
            }
            .child(text("Wrap").font(k.ty.caption()).color(st.wrap ? k.c.textAccent : k.c.textMuted))

        let copyBtn = El<State>(direction: .row)
            .key("\(prefix)-copy")
            .role(.button)
            .focusable()
            .px(8)
            .py(3)
            .rounded(k.radius.sm)
            .border(1, k.c.borderMuted)
            .hover(k.c.surfaceHover)
            .gap(4)
            .itemsCenter()
            .onClick { [get, set, onCopyHandler] (s: inout State, tx: inout Tx) in
                var d = get(s)
                let txt = d.copyText()
                d.copiedToastVisible = true
                set(&s, d)
                tx.copyText(txt)
                onCopyHandler?(&s, txt, &tx)
            }
            .child(icon(st.copiedToastVisible ? KitIcons.check : KitIcons.copy, size: 12).color(k.c.textMuted))
            .child(text(st.copiedToastVisible ? "Copied" : "Copy").font(k.ty.caption()).color(k.c.textMuted))

        var actionsRow = El<State>(direction: .row)
            .gap(8)
            .itemsCenter()
            .child(stats)
            .child(modeBtn)
            .child(wrapBtn)
            .child(copyBtn)
        if let custom = headerActionsBuilder, let hostState {
            actionsRow = actionsRow.child(
                El<State>(direction: .row)
                    .key("\(prefix)-actions")
                    .itemsCenter()
                    .child(custom(hostState, fileIndex))
            )
        }

        let headerLabel = "\(diff.path), \(additions) added, \(deletions) removed"
        var hdr = El<State>(direction: .row)
            .key("\(prefix)-header")
            .role(.heading)
            .label(headerLabel)
            .shrink(0)
            .h(DiffLayout.headerHeight)
            .px(12)
            .itemsCenter()
            .justifyBetween()
            .bg(k.c.surfaceRaised)
            .borderSides(bottom: 1, color: k.c.borderMuted)
            .child(
                El<State>(direction: .row)
                    .gap(8)
                    .itemsCenter()
                    .child(foldBtn)
                    .child(statusBadge)
            )
            .child(actionsRow)
        if stickyLeft { hdr = hdr.stickyLeft(0) }
        return if let fixedWidth { hdr.w(fixedWidth) } else { hdr.wFull() }
    }

    // MARK: Gap & Annotation Rows

    private func buildGapRow(fileIndex: Int, prefix: String, gap: DiffGap, height: Float, gutterWidth: Float) -> El<State> {
        let k = kit
        if look.foldRow == .lineInfo {
            let hidden = gap.count
            let labelStr = (hidden == 1) ? "1 unmodified line" : "\(hidden) unmodified lines"
            let w = max(24, gutterWidth - 2)
            let steps: [(DiffExpand, String, String)] = if gap.atStart {
                [(.up, "\(prefix)-gap-\(gap.index)-up", "Show \(min(hidden, DiffLayout.expandStep)) more lines above")]
            } else if gap.atEnd {
                [(.down, "\(prefix)-gap-\(gap.index)-down", "Show \(min(hidden, DiffLayout.expandStep)) more lines below")]
            } else if hidden <= DiffLayout.expandStep {
                [(.all, "\(prefix)-gap-\(gap.index)-all", "Show \(hidden) hidden lines")]
            } else {
                [
                    (.down, "\(prefix)-gap-\(gap.index)-down", "Show \(DiffLayout.expandStep) more lines below"),
                    (.up, "\(prefix)-gap-\(gap.index)-up", "Show \(DiffLayout.expandStep) more lines above"),
                ]
            }
            let btnH: Float = steps.count == 2 ? (height - 2) / 2 : height
            var btnCol = El<State>(direction: .column).key("\(prefix)-gap-\(gap.index)-btns").w(w + 2).h(height).gap(2).bg(k.c.surfaceBase)
            for (how, btnKey, a11yLabel) in steps {
                let glyph = (how == .up) ? KitIcons.chevronUp : KitIcons.chevronDown
                btnCol = btnCol.child(
                    El<State>(direction: .row)
                        .key(btnKey)
                        .w(w).h(btnH)
                        .itemsCenter().justifyCenter()
                        .bg(k.c.layer01)
                        .hover(k.c.surfaceHover)
                        .role(.button)
                        .label(a11yLabel)
                        .child(icon(glyph, size: 12).color(k.c.textMuted))
                        .onClick { [get, set] (s: inout State, _: inout Tx) in
                            var d = get(s)
                            d.expand(file: fileIndex, gapIndex: gap.index, direction: how)
                            set(&s, d)
                        }
                )
            }
            let wordsBtn = El<State>(direction: .row)
                .key("\(prefix)-gap-\(gap.index)-words")
                .h(height)
                .px(10)
                .itemsCenter()
                .role(.button)
                .label(labelStr)
                .onClick { [get, set] s in
                    var d = get(s)
                    if gap.atStart {
                        d.expand(file: fileIndex, gapIndex: gap.index, direction: .up)
                    } else if gap.atEnd {
                        d.expand(file: fileIndex, gapIndex: gap.index, direction: .down)
                    } else {
                        d.expand(file: fileIndex, gapIndex: gap.index, direction: .down)
                        d.expand(file: fileIndex, gapIndex: gap.index, direction: .up)
                    }
                    set(&s, d)
                }
                .child(text(labelStr).font(k.ty.caption()).color(k.c.textFaint))

            return El<State>(direction: .row)
                .key("\(prefix)-gap-\(gap.index)")
                .wFull()
                .h(height)
                .itemsCenter()
                .bg(k.c.layer01)
                .borderSides(top: 1, bottom: 1, color: k.c.borderMuted)
                .child(btnCol)
                .child(wordsBtn)
        }

        var bar = El<State>(direction: .row)
            .key("\(prefix)-gap-\(gap.index)")
            .h(height)
            .px(12)
            .gap(8)
            .itemsCenter()
            .bg(k.c.surfaceRaised)
            .borderSides(top: 1, bottom: 1, color: k.c.borderMuted)

        if gap.canStep && !gap.atStart {
            bar = bar.child(gapActionButton(id: "\(prefix)-gap-\(gap.index)-down", label: "Expand 20 down") { [get, set] s in
                var d = get(s)
                d.expand(file: fileIndex, gapIndex: gap.index, direction: .down)
                set(&s, d)
            })
        }
        bar = bar.child(gapActionButton(id: "\(prefix)-gap-\(gap.index)-all", label: "Expand all (\(gap.count) lines)") { [get, set] s in
            var d = get(s)
            d.expand(file: fileIndex, gapIndex: gap.index, direction: .all)
            set(&s, d)
        })
        if gap.canStep && !gap.atEnd {
            bar = bar.child(gapActionButton(id: "\(prefix)-gap-\(gap.index)-up", label: "Expand 20 up") { [get, set] s in
                var d = get(s)
                d.expand(file: fileIndex, gapIndex: gap.index, direction: .up)
                set(&s, d)
            })
        }
        return bar
    }

    private func gapActionButton(id: String, label: String, action: @escaping @Sendable (inout State) -> Void) -> El<State> {
        El<State>(direction: .row)
            .key(id)
            .role(.button)
            .focusable()
            .px(8)
            .py(2)
            .rounded(kit.radius.sm)
            .hover(kit.c.surfaceHover)
            .onClick(action)
            .child(text(label).font(kit.ty.caption()).color(kit.c.textAccent))
    }

    private func buildAnnotation(hostState: State?, prefix: String, ann: DiffAnnotation) -> El<State> {
        let noteBody: El<State>
        if let custom = annotationBuilder, let hostState {
            noteBody = custom(hostState, ann)
        } else {
            let k = kit
            noteBody = El<State>(direction: .column)
                .minH(DiffLayout.noteHeight)
                .px(16)
                .py(6)
                .bg(k.c.surfaceFloat)
                .borderSides(top: 1, bottom: 1, color: k.c.borderMuted)
                .child(
                    El<State>(direction: .row)
                        .gap(6)
                        .child(text(ann.author ?? "Note").font(k.ty.caption()).color(k.c.textAccent))
                        .child(text("L\(ann.line)").font(k.ty.mono).color(k.c.textFaint))
                )
                .child(text(ann.body).font(k.ty.body).color(k.c.textBase))
        }

        return El<State>(direction: .column).key("\(prefix)-note-\(ann.id)").child(noteBody)
    }

    private func buildSplitAnnotations(
        hostState: State?, prefix: String, owner: DiffLineRef, old: [DiffAnnotation], new: [DiffAnnotation], single: DiffSide?
    ) -> El<State> {
        var row = El<State>(direction: .row)
            .key("\(prefix)-split-\(owner.side.rawValue)-\(owner.line)-notes")
            .wFull()
            .itemsStart()
        for side in [DiffSide.old, .new] where single == nil || single == side {
            var column = El<State>(direction: .column).key(side.rawValue).wFrac(single == nil ? 0.5 : 1).minW(0)
            for ann in side == .old ? old : new {
                column = column.child(buildAnnotation(hostState: hostState, prefix: prefix, ann: ann).wFull())
            }
            row = row.child(column)
        }
        return row
    }

    // MARK: Gutter & Line Selection Helpers

    // `numberCell` is split into `@inline(never)` pieces so the long `El` builder chains don't
    // all share one debug-build frame on top of `renderContainer`/`buildUnifiedRow` (their
    // combined frames overflowed the 512 KB Swift Testing thread stack). No behavior change.
    private func numberCell(
        cellKey: String,
        number: Int?,
        digits: Int,
        width: Float,
        rowIdx: Int,
        file: Int,
        side: DiffSide,
        lineH: Float,
        lineBg: Color,
        unifiedLine: DiffLine? = nil
    ) -> El<State> {
        let labelStr = number.map(String.init) ?? ""
        let opposite: DiffSide = side == .old ? .new : .old
        let point = number.map { DiffLineRef(side: side, line: UInt32($0)) }
            ?? unifiedLine?.lineNumber(for: opposite).map { DiffLineRef(side: opposite, line: $0) }
        let cell: El<State>
        if unifiedLine == nil, let point, let onCommentHandler {
            cell = numberCommentCell(
                labelStr: labelStr, point: point, file: file, cellKey: cellKey, width: width, lineH: lineH, lineBg: lineBg,
                onCommentHandler: onCommentHandler
            )
        } else {
            cell = numberLabelCell(labelStr: labelStr, cellKey: cellKey, width: width, lineH: lineH, lineBg: lineBg)
        }
        guard let point else { return cell }
        return attachNumberCellHandlers(cell, point: point, rowIdx: rowIdx, file: file, side: side, lineH: lineH)
    }

    @inline(never)
    private func numberLabelCell(labelStr: String, cellKey: String, width: Float, lineH: Float, lineBg: Color) -> El<State> {
        text(labelStr)
            .font(kit.ty.mono)
            .color(kit.c.textFaint)
            .key(cellKey)
            .w(width)
            .h(lineH)
            .px(8)
            .textAlign(.trailing)
            .itemsCenter()
            .justifyEnd()
            .bg(lineBg)
            .shrink(0)
    }

    @inline(never)
    private func numberCommentCell(
        labelStr: String,
        point: DiffLineRef,
        file: Int,
        cellKey: String,
        width: Float,
        lineH: Float,
        lineBg: Color,
        onCommentHandler: @escaping @Sendable (inout State, DiffLineRange, inout Tx) -> Void
    ) -> El<State> {
        El<State>(direction: .row)
            .key(cellKey)
            .w(width)
            .h(lineH)
            .px(6)
            .gap(4)
            .itemsCenter()
            .justifyEnd()
            .bg(lineBg)
            .shrink(0)
            .child(commentButton(key: "\(cellKey)-plus", file: file, point: point, onComment: onCommentHandler))
            .child(text(labelStr).font(kit.ty.mono).color(kit.c.textFaint))
    }

    @inline(never)
    private func commentButton(
        key: String, file: Int, point: DiffLineRef,
        onComment: @escaping @Sendable (inout State, DiffLineRange, inout Tx) -> Void
    ) -> El<State> {
        El<State>(direction: .row)
            .key(key)
            .size(16, 16)
            .itemsCenter()
            .justifyCenter()
            .rounded(4)
            .bg(kit.c.info.icon)
            .cursor(.pointer)
            .role(.button)
            .label("Comment on this line")
            .child(icon(KitIcons.plus, size: 12).color(kit.c.white))
            .onClick { [get, forcedMode] (s: inout State, tx: inout Tx) in
                var d = get(s)
                if let forcedMode { d.mode = forcedMode }
                let lines = if let sel = d.selectedRange, sel.file == file, d.contains(sel, at: point) {
                    sel
                } else {
                    DiffLineRange(file: file, start: point, end: point)
                }
                onComment(&s, lines, &tx)
            }
    }

    @inline(never)
    private func attachNumberCellHandlers(
        _ cell: El<State>,
        point: DiffLineRef,
        rowIdx: Int,
        file: Int,
        side: DiffSide,
        lineH: Float
    ) -> El<State> {
        let mode = forcedMode
        return cell
            .cursor(.pointer)
            .onPointerDown { [get, set, onLineClickHandler] (s: inout State, press: PointerPress, tx: inout Tx) in
                var d = get(s)
                if let mode { d.mode = mode }
                guard d.files.indices.contains(file) else { return }
                d.selectionBeforePress = d.selectedRange
                if d.selectionFile != file { d.selection.step(.set(nil)) }
                d.selectionFile = file
                let lineIndex = d.rowIndex.sections[file].lineIndex
                d.selection.step(.press(at: point, column: .numbers, shift: press.mods.shift)) { ref in
                    lineIndex[ref].map(UInt32.init)
                }
                set(&s, d)
                onLineClickHandler?(&s, point, &tx)
            }
            .onDrag { [get, set] (s: inout State, drag: Drag, _: inout Tx) in
                var d = get(s)
                if let mode { d.mode = mode }
                guard d.selection.isTracking, d.selectionFile == file else { return }
                let rows = d.rows(file: file)
                guard rows.indices.contains(rowIdx) else { return }
                var targetIdx = rowIdx
                var remaining = drag.local.y
                func height(at i: Int) -> Float {
                    switch rows[i] {
                    case .gap, .annotation, .splitAnnotations: rows[i].baseHeight
                    case .unified, .splitOnly, .splitPair: lineH
                    }
                }
                while remaining < 0 && targetIdx > 0 {
                    targetIdx -= 1
                    remaining += height(at: targetIdx)
                }
                while targetIdx + 1 < rows.count && remaining >= height(at: targetIdx) {
                    remaining -= height(at: targetIdx)
                    targetIdx += 1
                }
                guard remaining >= 0,
                      remaining < height(at: targetIdx) || file + 1 == d.files.count,
                      let target = rows[targetIdx].lineRef(for: d.mode, preferredSide: side) else { return }
                d.selection.step(.move(at: target))
                set(&s, d)
            }
            .onDragEnd { [get, set, onSelectHandler] (s: inout State, cancelled: Bool, tx: inout Tx) in
                var d = get(s)
                guard d.selection.isTracking, d.selectionFile == file else { return }
                let eff = d.selection.step(cancelled ? .cancel : .release)
                if cancelled { d.select(d.selectionBeforePress) }
                d.selectionBeforePress = nil
                set(&s, d)
                if case let .ended(range) = eff {
                    onSelectHandler?(&s, DiffLineRange(file: file, from: range), &tx)
                }
            }
    }

    // MARK: Unified & Split Rows

    private func expandTabsWithOffsets(_ raw: String) -> (text: String, rawToExpanded: [Int]?) {
        DiffViewHelpers.expandTabsWithOffsets(raw, tabSize: look.tabSize)
    }

    private func insertSoftBreaks(_ s: String, enabled: Bool) -> String {
        DiffViewHelpers.insertSoftBreaks(s, enabled: enabled)
    }

    private func gutterBar(_ kind: DiffLineKind?, height: Float) -> El<State> {
        let color: Color = switch kind {
        case .addition: kit.c.success.fg
        case .deletion: kit.c.danger.fg
        case .context, nil: .transparent
        }
        return El<State>(direction: .row).w(3).h(height).shrink(0).bg(color)
    }

    private func noNewlineNote() -> El<State> {
        El<State>(direction: .row)
            .pb(2)
            .child(text("No newline at end of file").font(kit.ty.caption()).color(kit.c.textFaint))
    }

    private func buildCodeSpans(
        text rawText: String,
        highlights: [SyntaxHighlight],
        syntaxTheme: SyntaxTheme,
        changedRanges: [Range<Int>],
        wordBg: Color,
        wrap: Bool
    ) -> [TextSpan] {
        let (code, offsetMap) = expandTabsWithOffsets(rawText)
        guard !code.isEmpty else {
            return [TextSpan(" ", color: kit.c.textBase, monospace: true)]
        }

        return DiffViewHelpers.mergeCodeSpans(
            code: code,
            rawCount: rawText.utf8.count,
            offsetMap: offsetMap,
            highlights: highlights,
            changedRanges: changedRanges,
            defaultColor: kit.c.textBase,
            syntaxTheme: syntaxTheme,
            wordBg: wordBg,
            wrap: wrap
        )
    }

    private struct CodeAppearance: Equatable {
        let changes: [Range<Int>]
        let document: UUID
        let source: DiffLineRef
        let highlighter: Data
        let theme: SyntaxTheme
        let font: TextStyle
        let textColor: Color
        let wordColor: Color
        let tabSize: Int
        let wrap: Bool
    }

    private func codeBlock(
        cellKey: String,
        state: DiffState,
        file: Int,
        side: DiffSide,
        line: DiffLine,
        changed: [Range<Int>],
        wordBg: Color,
        syntaxTheme: SyntaxTheme,
        wrap: Bool,
        pr: Float
    ) -> El<State> {
        let resolved = hasCustomHighlighter ? highlighter : state.highlighter
        let sourceSide: DiffSide = line.oldNumber != nil && (line.kind == .deletion || line.newNumber == nil) ? .old : .new
        let source = DiffLineRef(side: sourceSide, line: line.lineNumber(for: sourceSide) ?? 1)
        let appearance = CodeAppearance(changes: changed, document: state.highlightVersion,
                                        source: source, highlighter: Data(resolved.id.utf8), theme: syntaxTheme, font: kit.ty.mono,
                                        textColor: kit.c.textBase, wordColor: wordBg, tabSize: look.tabSize, wrap: wrap)
        let codeEl: El<State> = memo(cellKey, deps: appearance) {
            let highlights = state.highlights(file: file, side: source.side, line: source.line, using: resolved)
            let spans = buildCodeSpans(text: line.text, highlights: highlights, syntaxTheme: syntaxTheme,
                                       changedRanges: changed, wordBg: wordBg, wrap: wrap)
            let code: El<State> = rich(spans).font(kit.ty.mono)
            return wrap ? code : code.noWrap()
        }
        let hoverHandler: (inout State, Bool, inout Tx) -> Void = { [get, set] s, inside, tx in
            var d = get(s)
            let prevCopySide = d.copySide
            if d.hoverText(side: side, cell: cellKey, inside: inside) {
                set(&s, d)
                if d.copySide == prevCopySide {
                    tx.liveOnly()
                }
            } else {
                tx.liveOnly()
            }
        }
        if !line.noNewline {
            return codeEl
                .key(cellKey)
                .grow(1)
                .pr(pr)
                .onHover(hoverHandler)
        }
        return El<State>(direction: .column)
            .key(cellKey)
            .grow(1)
            .pr(pr)
            .onHover(hoverHandler)
            .child(codeEl)
            .child(noNewlineNote())
    }

    private func buildUnifiedRow(
        prefix: String,
        rowIdx: Int,
        file: Int,
        line: DiffLine,
        intraOld: [Range<Int>],
        intraNew: [Range<Int>],
        st: DiffState,
        syntaxTheme: SyntaxTheme,
        gutterDigits: Int,
        gutterWidth: Float,
        lineH: Float,
        addLineBg: Color,
        delLineBg: Color,
        addWordBg: Color,
        delWordBg: Color,
        selBg: Color
    ) -> El<State> {
        let baseBg: Color = switch line.kind {
        case .addition: addLineBg
        case .deletion: delLineBg
        case .context: kit.c.surfaceBase
        }
        let side: DiffSide = (line.kind == .deletion) ? .old : .new
        let selected = st.rowSelected(rowIdx, file: file, side: nil)
        let rowBg = selected ? diffTintColor(baseBg, hue: selBg, t: 0.45) : baseBg

        let changed = (line.kind == .deletion) ? intraOld : intraNew
        let wordBg = (line.kind == .deletion) ? delWordBg : addWordBg
        let codeEl = codeBlock(
            cellKey: "\(prefix)-code-\(rowIdx)",
            state: st,
            file: file,
            side: side,
            line: line,
            changed: changed,
            wordBg: wordBg,
            syntaxTheme: syntaxTheme,
            wrap: st.wrap,
            pr: 12
        )

        var gutter = El<State>(direction: .row)
            .key("\(prefix)-gutter-\(rowIdx)")
            .minH(lineH)
            .selfStretch()
            .bg(rowBg)
            .itemsStart()
            .shrink(0)
            .child(gutterBar(line.kind, height: lineH))
            .child(numberCell(cellKey: "\(prefix)-o-\(rowIdx)", number: line.oldNumber, digits: gutterDigits, width: gutterWidth, rowIdx: rowIdx, file: file, side: .old, lineH: lineH, lineBg: rowBg, unifiedLine: line))
            .child(numberCell(cellKey: "\(prefix)-n-\(rowIdx)", number: line.newNumber, digits: gutterDigits, width: gutterWidth, rowIdx: rowIdx, file: file, side: .new, lineH: lineH, lineBg: rowBg, unifiedLine: line))
        let commentPoint = line.newLine.map { DiffLineRef(side: .new, line: $0) }
            ?? line.oldLine.map { DiffLineRef(side: .old, line: $0) }
        if let onCommentHandler, let point = commentPoint {
            let sideKey = point.side == .new ? "n" : "o"
            gutter = gutter.child(
                commentButton(key: "\(prefix)-\(sideKey)-\(rowIdx)-plus", file: file, point: point, onComment: onCommentHandler)
                    .groupOpacity(0, 1)
                    .absolute(x: 3 + 2 * gutterWidth - 10, y: 2)
            )
        }
        if !st.wrap { gutter = gutter.stickyLeft(0) }

        return El<State>(direction: .row)
            .key("\(prefix)-row-\(rowIdx)")
            .role(.listItem)
            .label(DiffViewHelpers.rowLabel(line))
            .wFull()
            .minH(lineH)
            .bg(rowBg)
            .itemsStart()
            .hover(kit.alpha(kit.c.textBase, kit.dark ? 0.06 : 0.035))
            .hoverGroup()
            .child(gutter)
            .child(codeEl)
    }

    private func buildSplitPairRow(
        prefix: String,
        rowIdx: Int,
        file: Int,
        oldLine: DiffLine,
        newLine: DiffLine,
        oldChanged: [Range<Int>],
        newChanged: [Range<Int>],
        st: DiffState,
        syntaxTheme: SyntaxTheme,
        gutterDigits: Int,
        gutterWidth: Float,
        lineH: Float,
        addLineBg: Color,
        delLineBg: Color,
        addWordBg: Color,
        delWordBg: Color,
        selBg: Color
    ) -> El<State> {
        let oldBg = st.rowSelected(rowIdx, file: file, side: .old) ? diffTintColor(delLineBg, hue: selBg, t: 0.45) : delLineBg
        let newBg = st.rowSelected(rowIdx, file: file, side: .new) ? diffTintColor(addLineBg, hue: selBg, t: 0.45) : addLineBg

        let oldCode = codeBlock(cellKey: "\(prefix)-scode-o-\(rowIdx)", state: st, file: file, side: .old, line: oldLine, changed: oldChanged, wordBg: delWordBg, syntaxTheme: syntaxTheme, wrap: st.wrap, pr: 8)
        let newCode = codeBlock(cellKey: "\(prefix)-scode-n-\(rowIdx)", state: st, file: file, side: .new, line: newLine, changed: newChanged, wordBg: addWordBg, syntaxTheme: syntaxTheme, wrap: st.wrap, pr: 8)

        let leftPane = El<State>(direction: .row)
            .wFrac(0.5)
            .minH(lineH)
            .bg(oldBg)
            .itemsCenter()
            .borderSides(right: 1, color: kit.c.borderMuted)
            .child(gutterBar(.deletion, height: lineH))
            .child(numberCell(cellKey: "\(prefix)-so-\(rowIdx)", number: oldLine.oldNumber, digits: gutterDigits, width: gutterWidth, rowIdx: rowIdx, file: file, side: .old, lineH: lineH, lineBg: oldBg))
            .child(text("-").font(kit.ty.mono).color(kit.c.danger.fg).w(16).h(lineH).itemsCenter().justifyCenter().shrink(0))
            .child(oldCode)

        let rightPane = El<State>(direction: .row)
            .wFrac(0.5)
            .minH(lineH)
            .bg(newBg)
            .itemsCenter()
            .child(gutterBar(.addition, height: lineH))
            .child(numberCell(cellKey: "\(prefix)-sn-\(rowIdx)", number: newLine.newNumber, digits: gutterDigits, width: gutterWidth, rowIdx: rowIdx, file: file, side: .new, lineH: lineH, lineBg: newBg))
            .child(text("+").font(kit.ty.mono).color(kit.c.success.fg).w(16).h(lineH).itemsCenter().justifyCenter().shrink(0))
            .child(newCode)

        return El<State>(direction: .row)
            .key("\(prefix)-srow-\(rowIdx)")
            .wFull()
            .child(leftPane.label(DiffViewHelpers.rowLabel(oldLine)))
            .child(rightPane.label(DiffViewHelpers.rowLabel(newLine)))
    }

    private func buildSplitOnlyRow(
        prefix: String,
        rowIdx: Int,
        file: Int,
        line: DiffLine,
        st: DiffState,
        syntaxTheme: SyntaxTheme,
        gutterDigits: Int,
        gutterWidth: Float,
        lineH: Float,
        addLineBg: Color,
        delLineBg: Color,
        selBg: Color
    ) -> El<State> {
        let emptySide = { (sideKey: String, bg: Color) -> El<State> in
            El<State>(direction: .row)
                .key(sideKey)
                .wFrac(0.5)
                .minH(lineH)
                .bg(bg)
        }

        switch line.kind {
        case .context:
            let lBg = st.rowSelected(rowIdx, file: file, side: .old) ? diffTintColor(kit.c.surfaceBase, hue: selBg, t: 0.45) : kit.c.surfaceBase
            let rBg = st.rowSelected(rowIdx, file: file, side: .new) ? diffTintColor(kit.c.surfaceBase, hue: selBg, t: 0.45) : kit.c.surfaceBase
            let leftCode = codeBlock(cellKey: "\(prefix)-ccode-o-\(rowIdx)", state: st, file: file, side: .old, line: line, changed: [], wordBg: .transparent, syntaxTheme: syntaxTheme, wrap: st.wrap, pr: 8)
            let rightCode = codeBlock(cellKey: "\(prefix)-ccode-n-\(rowIdx)", state: st, file: file, side: .new, line: line, changed: [], wordBg: .transparent, syntaxTheme: syntaxTheme, wrap: st.wrap, pr: 8)
            let leftPane = El<State>(direction: .row)
                .wFrac(0.5).minH(lineH).bg(lBg).itemsCenter().borderSides(right: 1, color: kit.c.borderMuted)
                .child(gutterBar(.context, height: lineH))
                .child(numberCell(cellKey: "\(prefix)-co-\(rowIdx)", number: line.oldNumber, digits: gutterDigits, width: gutterWidth, rowIdx: rowIdx, file: file, side: .old, lineH: lineH, lineBg: lBg))
                .child(El<State>(direction: .row).w(16).h(lineH).shrink(0))
                .child(leftCode)
            let rightPane = El<State>(direction: .row)
                .wFrac(0.5).minH(lineH).bg(rBg).itemsCenter()
                .child(gutterBar(.context, height: lineH))
                .child(numberCell(cellKey: "\(prefix)-cn-\(rowIdx)", number: line.newNumber, digits: gutterDigits, width: gutterWidth, rowIdx: rowIdx, file: file, side: .new, lineH: lineH, lineBg: rBg))
                .child(El<State>(direction: .row).w(16).h(lineH).shrink(0))
                .child(rightCode)
            return El<State>(direction: .row).key("\(prefix)-crow-\(rowIdx)").wFull()
                .child(leftPane.label(DiffViewHelpers.rowLabel(line, side: .old)))
                .child(rightPane.label(DiffViewHelpers.rowLabel(line, side: .new)))

        case .deletion:
            let bg = st.rowSelected(rowIdx, file: file, side: .old) ? diffTintColor(delLineBg, hue: selBg, t: 0.45) : delLineBg
            let code = codeBlock(cellKey: "\(prefix)-dcode-\(rowIdx)", state: st, file: file, side: .old, line: line, changed: [], wordBg: .transparent, syntaxTheme: syntaxTheme, wrap: st.wrap, pr: 8)
            let leftPane = El<State>(direction: .row)
                .wFrac(0.5).minH(lineH).bg(bg).itemsCenter().borderSides(right: 1, color: kit.c.borderMuted)
                .child(gutterBar(.deletion, height: lineH))
                .child(numberCell(cellKey: "\(prefix)-do-\(rowIdx)", number: line.oldNumber, digits: gutterDigits, width: gutterWidth, rowIdx: rowIdx, file: file, side: .old, lineH: lineH, lineBg: bg))
                .child(text("-").font(kit.ty.mono).color(kit.c.danger.fg).w(16).h(lineH).itemsCenter().justifyCenter().shrink(0))
                .child(code)
            let row = El<State>(direction: .row).key("\(prefix)-drow-\(rowIdx)").wFull()
            let content = leftPane.label(DiffViewHelpers.rowLabel(line, side: .old))
            if st.singleColumn(file: file) == .old { return row.child(content.wFull()) }
            return row.child(content).child(emptySide("\(prefix)-dempty-\(rowIdx)", kit.c.surfaceRaised))

        case .addition:
            let bg = st.rowSelected(rowIdx, file: file, side: .new) ? diffTintColor(addLineBg, hue: selBg, t: 0.45) : addLineBg
            let code = codeBlock(cellKey: "\(prefix)-acode-\(rowIdx)", state: st, file: file, side: .new, line: line, changed: [], wordBg: .transparent, syntaxTheme: syntaxTheme, wrap: st.wrap, pr: 8)
            let rightPane = El<State>(direction: .row)
                .wFrac(0.5).minH(lineH).bg(bg).itemsCenter()
                .child(gutterBar(.addition, height: lineH))
                .child(numberCell(cellKey: "\(prefix)-an-\(rowIdx)", number: line.newNumber, digits: gutterDigits, width: gutterWidth, rowIdx: rowIdx, file: file, side: .new, lineH: lineH, lineBg: bg))
                .child(text("+").font(kit.ty.mono).color(kit.c.success.fg).w(16).h(lineH).itemsCenter().justifyCenter().shrink(0))
                .child(code)
            let row = El<State>(direction: .row).key("\(prefix)-arow-\(rowIdx)").wFull()
            let content = rightPane.label(DiffViewHelpers.rowLabel(line, side: .new))
            if st.singleColumn(file: file) == .new { return row.child(content.wFull()) }
            return row.child(emptySide("\(prefix)-aempty-\(rowIdx)", kit.c.surfaceRaised).borderSides(right: 1, color: kit.c.borderMuted))
                .child(content)
        }
    }
}

// MARK: - Kit Diff Entry Points (`diffView`, `layer`, `tabbed`)

private struct ReadOnlyDiffAppearance: Equatable {
    let file: FileDiff
    let style: DiffStyle
    let kit: Kit
}

extension Kit {
    /// Renders a read-only unified or split diff element using the full `DiffView` renderer.
    public func diffView<State>(
        key: String,
        _ diff: FileDiff,
        style: DiffStyle = .unified
    ) -> El<State> {
        memo(key, deps: ReadOnlyDiffAppearance(file: diff, style: style, kit: self)) {
            let fixedState = DiffState(diff: diff, mode: style.mode)
            return DiffView<State>(key: key, kit: self, get: { _ in fixedState }, set: { _, _ in })
                .buildReadOnly(diffState: fixedState)
        }
    }

    /// Renders a stateful `DiffView` element driven by a `DiffState` lens.
    public func diffView<State>(
        key: String,
        state: State,
        cx: Cx<State>,
        at keyPath: WritableKeyPath<State, DiffState> & Sendable,
        configure: (DiffView<State>) -> DiffView<State> = { $0 }
    ) -> El<State> {
        let base = DiffView<State>(key: key, kit: self, state: keyPath)
        return configure(base).build(state: state, cx: cx)
    }

    /// Renders multiple file diffs stacked vertically (`diff::view::layer`).
    public func diffLayer<State>(
        key: String,
        state: State,
        cx: Cx<State>,
        get: @escaping @Sendable (State) -> [DiffState],
        set: @escaping @Sendable (inout State, [DiffState]) -> Void,
        gap: Float = 12
    ) -> El<State> {
        let list = get(state)
        var col = El<State>(direction: .column).key(key).wFull().gap(gap)
        for i in list.indices {
            let itemView = DiffView<State>(
                key: "\(key)-\(i)",
                kit: self,
                get: { s in
                    let arr = get(s)
                    return i < arr.count ? arr[i] : list[i]
                },
                set: { s, newVal in
                    var arr = get(s)
                    if i < arr.count {
                        arr[i] = newVal
                        set(&s, arr)
                    }
                }
            )
            col = col.child(itemView.build(state: state, cx: cx))
        }
        return col
    }

    /// Renders multiple file diffs behind a file-selector tab strip (`diff::view::tabbed`).
    public func diffTabbed<State>(
        key: String,
        state: State,
        cx: Cx<State>,
        activeIndex: @escaping @Sendable (State) -> Int,
        setActiveIndex: @escaping @Sendable (inout State, Int) -> Void,
        get: @escaping @Sendable (State) -> [DiffState],
        set: @escaping @Sendable (inout State, [DiffState]) -> Void
    ) -> El<State> {
        let list = get(state)
        let active = max(0, min(max(0, list.count - 1), activeIndex(state)))

        var tabBar = El<State>(direction: .row)
            .key("\(key)-tabs")
            .wFull()
            .gap(4)
            .px(8)
            .py(6)
            .bg(c.surfaceRaised)
            .borderSides(bottom: 1, color: c.borderMuted)

        for (i, item) in list.enumerated() {
            let isActive = (i == active)
            tabBar = tabBar.child(
                El<State>(direction: .row)
                    .key("\(key)-tab-\(i)")
                    .role(.tab)
                    .focusable()
                    .selected(isActive ? item.diff.path : nil)
                    .px(10)
                    .py(4)
                    .rounded(radius.sm)
                    .bg(isActive ? c.surfaceHover : .transparent)
                    .border(1, isActive ? c.borderStrong : .transparent)
                    .onClick { s in setActiveIndex(&s, i) }
                    .child(text(item.diff.path).font(ty.caption()).color(isActive ? c.textBase : c.textMuted))
            )
        }

        var root = El<State>(direction: .column).key(key).wFull().child(tabBar)
        if !list.isEmpty {
            let idx = active
            let view = DiffView<State>(
                key: "\(key)-panel-\(idx)",
                kit: self,
                get: { s in
                    let arr = get(s)
                    return idx < arr.count ? arr[idx] : list[idx]
                },
                set: { s, newVal in
                    var arr = get(s)
                    if idx < arr.count {
                        arr[idx] = newVal
                        set(&s, arr)
                    }
                }
            )
            root = root.child(view.build(state: state, cx: cx))
        }
        return root
    }
}

// MARK: - DiffView Helpers (exposed internally for unit testing)

/// Pure helper functions used by `DiffView` (`rune_kit::diff::view` free helpers).
internal enum DiffViewHelpers: Sendable {
    /// Expands ASCII tabs to `tabSize`-column stops, returning `(text, rawToExpanded)` when any `\t` is present.
    static func expandTabsWithOffsets(_ raw: String, tabSize: Int = 4) -> (text: String, rawToExpanded: [Int]?) {
        guard raw.utf8.contains(0x09) else { return (raw, nil) }
        let step = max(1, tabSize)
        var out = ""
        out.reserveCapacity(raw.utf8.count + 8)
        var rawToExpanded: [Int] = []
        rawToExpanded.reserveCapacity(raw.utf8.count + 1)
        var col = 0
        for scalar in raw.unicodeScalars {
            let expandedStart = out.utf8.count
            for _ in 0..<scalar.utf8.count {
                rawToExpanded.append(expandedStart)
            }
            if scalar == "\t" {
                let spaces = step - (col % step)
                out.append(String(repeating: " ", count: spaces))
                col += spaces
            } else {
                out.unicodeScalars.append(scalar)
                col += 1
            }
        }
        rawToExpanded.append(out.utf8.count)
        return (out, rawToExpanded)
    }

    /// Inserts zero-width soft-break opportunities (`U+200B`) after `.`, `(`, `[`, and `/` before non-whitespace.
    static func insertSoftBreaks(
        _ s: String,
        enabled: Bool,
        trailingNonWhitespace: Bool = false
    ) -> String {
        guard enabled, !s.isEmpty else { return s }
        guard s.utf8.contains(where: { $0 == 0x2E || $0 == 0x28 || $0 == 0x5B || $0 == 0x2F }) else {
            return s
        }
        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count + 8)
        for idx in scalars.indices {
            let sc = scalars[idx]
            out.append(sc)
            if sc == "." || sc == "(" || sc == "[" || sc == "/" {
                let nextIsNonWS: Bool
                if idx + 1 < scalars.count {
                    nextIsNonWS = !scalars[idx + 1].properties.isWhitespace
                } else {
                    nextIsNonWS = trailingNonWhitespace
                }
                if nextIsNonWS {
                    out.append("\u{200B}")
                }
            }
        }
        return String(out)
    }

    /// Merges syntax highlight spans and intra-line changed word ranges into coalesced `TextSpan` slices.
    static func mergeCodeSpans(
        code: String,
        rawCount: Int,
        offsetMap: [Int]?,
        highlights: [SyntaxHighlight],
        changedRanges: [Range<Int>],
        defaultColor: Color,
        syntaxTheme: SyntaxTheme,
        wordBg: Color,
        wrap: Bool
    ) -> [TextSpan] {
        let utf8 = code.utf8
        let total = utf8.count
        guard total > 0 else { return [] }

        func mapRawOffset(_ rawOffset: Int) -> Int {
            guard let offsetMap else { return min(max(0, rawOffset), total) }
            let clamped = min(max(0, rawOffset), min(rawCount, offsetMap.count - 1))
            return min(max(0, offsetMap[clamped]), total)
        }

        let mappedChanges: [Range<Int>] = changedRanges.compactMap { r in
            let lo = mapRawOffset(r.lowerBound)
            let hi = mapRawOffset(r.upperBound)
            return lo < hi ? (lo..<hi) : nil
        }
        let mappedHighlights = offsetMap == nil ? highlights : highlights.map { h in
            SyntaxHighlight(range: mapRawOffset(h.range.lowerBound)..<mapRawOffset(h.range.upperBound), paint: h.paint)
        }

        // Snap byte offsets to valid UTF-8 scalar boundaries in `code`.
        func snapBoundary(_ offset: Int) -> Int? {
            guard offset >= 0, offset <= total else { return nil }
            let idx = utf8.index(utf8.startIndex, offsetBy: offset)
            return idx.samePosition(in: code.unicodeScalars) != nil ? offset : nil
        }

        var cutSet: Set<Int> = [0, total]
        for h in mappedHighlights {
            if let lo = snapBoundary(h.range.lowerBound), let hi = snapBoundary(h.range.upperBound), lo < hi {
                cutSet.insert(lo)
                cutSet.insert(hi)
            }
        }
        for r in mappedChanges {
            if let lo = snapBoundary(r.lowerBound), let hi = snapBoundary(r.upperBound), lo < hi {
                cutSet.insert(lo)
                cutSet.insert(hi)
            }
        }
        let cuts = cutSet.sorted()

        var spans: [TextSpan] = []
        spans.reserveCapacity(max(1, cuts.count - 1))

        for i in 0..<(cuts.count - 1) {
            let a = cuts[i]
            let b = cuts[i + 1]
            guard a < b else { continue }

            var fg = defaultColor
            var weight: Float? = nil
            if let h = mappedHighlights.first(where: { $0.range.lowerBound <= a && a < $0.range.upperBound }) {
                fg = syntaxTheme.paint(h.paint)
                if case .kind(let kind) = h.paint {
                    weight = syntaxTheme.weight(for: kind)
                }
            }

            let inChanged = mappedChanges.contains(where: { $0.lowerBound <= a && a < $0.upperBound })
            let bg: Color? = inChanged ? wordBg : nil

            let startIdx = utf8.index(utf8.startIndex, offsetBy: a)
            let endIdx = utf8.index(utf8.startIndex, offsetBy: b)
            let trailingNonWS: Bool = {
                guard wrap, b < total else { return false }
                let rest = code[endIdx...]
                return rest.unicodeScalars.first.map { !$0.properties.isWhitespace } ?? false
            }()
            let rawSlice = String(decoding: utf8[startIdx..<endIdx], as: UTF8.self)
            let textSlice = insertSoftBreaks(rawSlice, enabled: wrap, trailingNonWhitespace: trailingNonWS)

            if let last = spans.last,
               last.color == fg,
               last.background == bg,
               last.weight == weight {
                spans[spans.count - 1].text += textSlice
            } else {
                spans.append(TextSpan(textSlice, color: fg, background: bg, weight: weight, monospace: true))
            }
        }
        return spans
    }

    /// Accessibility label for a diff line row (`added|removed|unchanged line N: text`).
    static func rowLabel(_ line: DiffLine, side: DiffSide? = nil) -> String {
        let kindWord: String = switch line.kind {
        case .addition: "added"
        case .deletion: "removed"
        case .context: "unchanged"
        }
        let n: Int = (side == .old ? line.oldNumber : side == .new ? line.newNumber : nil)
            ?? line.newNumber
            ?? line.oldNumber
            ?? 0
        return "\(kindWord) line \(n): \(line.text)"
    }
}

