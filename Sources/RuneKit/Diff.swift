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
    /// Edit-distance search cap before falling back to a replace chunk (`MAX_D = 1024`).
    public static let maxD = 1024

    /// Computes an edit script turning `a` into `b` in O((N + M) * D) time and O(N + M) space.
    public static func diff<T: Equatable>(_ a: [T], _ b: [T]) -> [MyersOp] {
        var ops: [MyersOp] = []
        conquer(a[...], b[...], out: &ops)
        return ops
    }

    private struct Snake {
        var xStart: Int
        var yStart: Int
        var xEnd: Int
        var yEnd: Int
    }

    private static func push(_ out: inout [MyersOp], _ op: MyersOp) {
        switch (out.last, op) {
        case (_, .equal(0)), (_, .delete(0)), (_, .insert(0)):
            return
        case (.some(.equal(let a)), .equal(let b)):
            out[out.count - 1] = .equal(a + b)
        case (.some(.delete(let a)), .delete(let b)):
            out[out.count - 1] = .delete(a + b)
        case (.some(.insert(let a)), .insert(let b)):
            out[out.count - 1] = .insert(a + b)
        case (.some(.insert(let ins)), .delete(let del)):
            // Canonical diff order: emit deletions before consecutive insertions.
            out.removeLast()
            push(&out, .delete(del))
            out.append(.insert(ins))
        default:
            out.append(op)
        }
    }

    private static func conquer<T: Equatable>(
        _ a: ArraySlice<T>,
        _ b: ArraySlice<T>,
        out: inout [MyersOp]
    ) {
        var loA = a.startIndex
        var hiA = a.endIndex
        var loB = b.startIndex
        var hiB = b.endIndex

        var prefix = 0
        while loA < hiA && loB < hiB && a[loA] == b[loB] {
            loA += 1
            loB += 1
            prefix += 1
        }
        if prefix > 0 {
            push(&out, .equal(prefix))
        }

        var suffix = 0
        while hiA > loA && hiB > loB && a[hiA - 1] == b[hiB - 1] {
            hiA -= 1
            hiB -= 1
            suffix += 1
        }

        let midA = a[loA..<hiA]
        let midB = b[loB..<hiB]
        let n = midA.count
        let m = midB.count

        if n == 0 && m == 0 {
            if suffix > 0 { push(&out, .equal(suffix)) }
            return
        }
        if n == 0 {
            push(&out, .insert(m))
            if suffix > 0 { push(&out, .equal(suffix)) }
            return
        }
        if m == 0 {
            push(&out, .delete(n))
            if suffix > 0 { push(&out, .equal(suffix)) }
            return
        }

        if let snake = middleSnake(midA, midB) {
            conquer(midA[midA.startIndex..<(midA.startIndex + snake.xStart)],
                    midB[midB.startIndex..<(midB.startIndex + snake.yStart)],
                    out: &out)
            let eqLen = snake.xEnd - snake.xStart
            if eqLen > 0 {
                push(&out, .equal(eqLen))
            }
            conquer(midA[(midA.startIndex + snake.xEnd)..<midA.endIndex],
                    midB[(midB.startIndex + snake.yEnd)..<midB.endIndex],
                    out: &out)
        } else {
            push(&out, .delete(n))
            push(&out, .insert(m))
        }

        if suffix > 0 {
            push(&out, .equal(suffix))
        }
    }

    private static func middleSnake<T: Equatable>(
        _ a: ArraySlice<T>,
        _ b: ArraySlice<T>
    ) -> Snake? {
        let n = a.count
        let m = b.count
        let maxTotal = n + m
        let delta = n - m
        let odd = (delta & 1) != 0
        let limit = min((maxTotal + 1) / 2, maxD)
        let off = maxTotal
        let size = 2 * maxTotal + 1

        var vf = [Int](repeating: 0, count: size)
        var vb = [Int](repeating: n, count: size)

        let aBase = a.startIndex
        let bBase = b.startIndex

        for d in 0...limit {
            var k = -d
            while k <= d {
                let takeDown = (k == -d) || (k != d && vf[off + k - 1] < vf[off + k + 1])
                var x = takeDown ? vf[off + k + 1] : vf[off + k - 1] + 1
                var y = x - k
                let x0 = x
                let y0 = y
                while x < n && y < m && a[aBase + x] == b[bBase + y] {
                    x += 1
                    y += 1
                }
                vf[off + k] = x
                if odd {
                    let c = k - delta
                    let bound = d - 1
                    if c >= -bound && c <= bound && vf[off + k] >= vb[off + c] {
                        return Snake(xStart: x0, yStart: y0, xEnd: x, yEnd: y)
                    }
                }
                k += 2
            }

            var c = -d
            while c <= d {
                let takeUp = (c == d) || (c != -d && vb[off + c - 1] < vb[off + c + 1])
                var x = takeUp ? vb[off + c - 1] : vb[off + c + 1] - 1
                var y = x - (delta + c)
                let x1 = x
                let y1 = y
                while x > 0 && y > 0 && a[aBase + x - 1] == b[bBase + y - 1] {
                    x -= 1
                    y -= 1
                }
                vb[off + c] = x
                if !odd {
                    let kForward = delta + c
                    if kForward >= -d && kForward <= d && vb[off + c] <= vf[off + kForward] {
                        return Snake(xStart: x, yStart: y, xEnd: x1, yEnd: y1)
                    }
                }
                c += 2
            }
        }
        return nil
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
            case (.deletion, .some(let j)) where j < lines.count:
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

    /// Single-side file indicator if the file was added or deleted.
    public var soleSide: DiffSide? {
        switch status {
        case .added: .new
        case .deleted: .old
        case .modified, .renamed, .copied: nil
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
        let oldLines = DiffSource.splitLines(old)
        let newLines = DiffSource.splitLines(new)
        let status: FileStatus = if oldLines.isEmpty && !newLines.isEmpty {
            .added
        } else if !oldLines.isEmpty && newLines.isEmpty {
            .deleted
        } else {
            .modified
        }

        let (aIds, bIds) = intern(oldLines, newLines)
        let ops = Myers.diff(aIds, bIds)
        var hunks = buildContextHunks(oldLines: oldLines, newLines: newLines, ops: ops, context: max(0, context))
        DiffPairs.pairLines(&hunks)

        return FileDiff(
            oldPath: status == .added ? "/dev/null" : path,
            newPath: status == .deleted ? "/dev/null" : path,
            status: status,
            hunks: hunks,
            isBinary: false,
            source: DiffSource(oldLines: oldLines, newLines: newLines)
        )
    }

    /// Upstream convenience alias matching `FileDiff::from_texts(path, old, new, context)`.
    public static func fromTexts(
        path: String,
        old: String,
        new: String,
        context: Int = 3
    ) -> FileDiff {
        between(old: old, new: new, path: path, context: context)
    }

    /// Builds a `FileDiff` when either `old` or `new` may be nil (`FileDiff::patch`).
    public static func patch(
        old: String?,
        new: String?,
        path: String,
        oldPath: String? = nil,
        context: Int = 3
    ) -> FileDiff {
        var diff = between(old: old ?? "", new: new ?? "", path: path, context: context)
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

    private static func intern(_ old: [String], _ new: [String]) -> ([Int], [Int]) {
        var table: [String: Int] = [:]
        table.reserveCapacity(old.count + new.count)
        func idFor(_ s: String) -> Int {
            if let id = table[s] { return id }
            let next = table.count
            table[s] = next
            return next
        }
        return (old.map(idFor), new.map(idFor))
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
        context: Int
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
                    lines.append(DiffLine(kind: .context, oldNumber: o + 1, newNumber: n + 1, text: oldLines[o]))
                case let .del(o):
                    if firstOld == nil { firstOld = o + 1 }
                    oldCount += 1
                    lines.append(DiffLine(kind: .deletion, oldNumber: o + 1, newNumber: nil, text: oldLines[o]))
                case let .ins(n):
                    if firstNew == nil { firstNew = n + 1 }
                    newCount += 1
                    lines.append(DiffLine(kind: .addition, oldNumber: nil, newNumber: n + 1, text: newLines[n]))
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
        side == other.side
    }

    public static func < (lhs: DiffLineRef, rhs: DiffLineRef) -> Bool {
        if lhs.side != rhs.side {
            return lhs.side == .old
        }
        return lhs.line < rhs.line
    }
}

/// Ordered selected range inside a diff (`crate::diff::state::LineRange`).
public struct DiffLineRange: Sendable, Equatable, Hashable {
    public var start: DiffLineRef
    public var end: DiffLineRef

    public init(start: DiffLineRef, end: DiffLineRef) {
        if start <= end {
            self.start = start
            self.end = end
        } else {
            self.start = end
            self.end = start
        }
    }

    public init?(from range: LineRange<DiffLineRef>?) {
        guard let range else { return nil }
        self.init(start: range.start, end: range.end)
    }

    public func contains(_ ref: DiffLineRef) -> Bool {
        ref.side == start.side && ref.line >= start.line && ref.line <= end.line
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

    public var baseHeight: Float {
        switch self {
        case .gap: DiffLayout.gapHeight
        case .unified, .splitPair, .splitOnly: DiffLayout.lineHeight
        case .annotation: DiffLayout.noteHeight
        }
    }

    public func lineRef(for mode: DiffMode, preferredSide: DiffSide? = nil) -> DiffLineRef? {
        switch self {
        case .gap, .annotation:
            return nil
        case .unified(let line, _, _):
            switch line.kind {
            case .deletion:
                return line.oldLine.map { DiffLineRef(side: .old, line: $0) }
            case .addition, .context:
                return (line.newLine ?? line.oldLine).map {
                    DiffLineRef(side: line.newLine != nil ? .new : .old, line: $0)
                }
            }
        case let .splitPair(old, new, _, _):
            if preferredSide == .old, let l = old.oldLine {
                return DiffLineRef(side: .old, line: l)
            }
            if let l = new.newLine {
                return DiffLineRef(side: .new, line: l)
            }
            return old.oldLine.map { DiffLineRef(side: .old, line: $0) }
        case .splitOnly(let line):
            if line.kind == .deletion || preferredSide == .old {
                if let l = line.oldLine { return DiffLineRef(side: .old, line: l) }
            }
            if let l = line.newLine { return DiffLineRef(side: .new, line: l) }
            return line.oldLine.map { DiffLineRef(side: .old, line: $0) }
        }
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
    public var files: [FileDiff]
    public var mode: DiffMode
    public var wrap: Bool
    public var annotations: [DiffAnnotation]
    public var selection: LineSelectionState<DiffLineRef>
    public var hoveredRow: Int?
    public var copiedToastVisible: Bool
    public var visibleFile: Int

    private var ui: [DiffFileUI]
    private var copyTracker = DiffCopyTracker()

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

    public mutating func setCollapsed(file: Int, _ collapsed: Bool) {
        guard files.indices.contains(file), ui.indices.contains(file) else { return }
        ui[file].collapsed = collapsed
    }

    public mutating func setMode(_ mode: DiffMode) {
        self.mode = mode
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
    }

    /// Convenience single-file wrapper preserved for callers.
    public mutating func expand(gapIndex: Int, direction: DiffExpand) {
        expand(file: 0, gapIndex: gapIndex, direction: direction)
    }

    /// Selects a single line or range on `side`.
    public mutating func select(_ range: DiffLineRange?) {
        let lr = range.map { LineRange(start: $0.start, end: $0.end) }
        selection.step(.set(lr))
    }

    /// Currently active selected range, normalized in ascending order.
    public var selectedRange: DiffLineRange? {
        DiffLineRange(from: selection.selected)
    }

    /// Copies the currently selected lines (`copySide`), or the entire diff side if nothing is selected.
    public func copyText(side: DiffCopySide? = nil) -> String {
        let resolved: DiffCopySide = side ?? {
            switch copySide {
            case .old: .old
            case .new: .new
            }
        }()
        if let sel = selectedRange {
            var lines: [String] = []
            for h in effectiveHunks(file: visibleFile) {
                for l in h.lines {
                    let matchesSel: Bool = switch sel.start.side {
                    case .old:
                        l.oldLine.map { $0 >= sel.start.line && $0 <= sel.end.line } ?? false
                    case .new:
                        l.newLine.map { $0 >= sel.start.line && $0 <= sel.end.line } ?? false
                    }
                    guard matchesSel else { continue }
                    if matchesCopySide(l.kind, copySide: resolved) {
                        lines.append(l.text)
                    }
                }
            }
            return lines.joined(separator: "\n")
        }
        let targetFile = files.indices.contains(visibleFile) ? files[visibleFile] : diff
        switch resolved {
        case .old: return targetFile.text(side: .old)
        case .new: return targetFile.text(side: .new)
        case .both: return targetFile.copyableText(includeRemoved: true)
        }
    }

    private func matchesCopySide(_ kind: DiffLineKind, copySide: DiffCopySide) -> Bool {
        switch (copySide, kind) {
        case (.both, _): true
        case (.new, .addition), (.new, .context): true
        case (.old, .deletion), (.old, .context): true
        default: false
        }
    }

    private func fileYOffset(_ file: Int) -> Float {
        var y: Float = 0
        for idx in 0..<min(file, files.count) {
            y += DiffLayout.headerHeight
            if files[idx].isBinary {
                y += DiffLayout.noteHeight
            } else if !collapsed(file: idx) {
                for r in rows(file: idx) {
                    y += r.baseHeight
                }
            }
        }
        return y
    }

    public mutating func scrollToFile(_ file: Int, keyPrefix: String = "diff", tx: inout Tx) {
        guard files.indices.contains(file) else { return }
        visibleFile = file
        let y = (files.count <= 1) ? Float(0) : fileYOffset(file)
        tx.scrollTo("\(keyPrefix)-body", offset: Vec2(x: 0, y: y))
    }

    public mutating func scrollToLine(_ file: Int, at: DiffLineRef, keyPrefix: String = "diff", tx: inout Tx) {
        guard files.indices.contains(file) else { return }
        if collapsed(file: file) {
            setCollapsed(file: file, false)
        }
        for gap in computeGaps(file: file) {
            let start = (at.side == .old) ? gap.oldStart : gap.newStart
            let end = (at.side == .old) ? gap.oldEnd : gap.newEnd
            if Int(at.line) >= start && Int(at.line) < end {
                expand(file: file, gapIndex: gap.index, direction: .all)
                break
            }
        }
        let rList = rows(file: file)
        if let idx = rList.firstIndex(where: { $0.lineRef(for: mode, preferredSide: at.side) == at }) {
            var y = (files.count <= 1) ? Float(0) : (fileYOffset(file) + DiffLayout.headerHeight)
            for row in rList.prefix(idx) {
                y += row.baseHeight
            }
            tx.scrollTo("\(keyPrefix)-body", offset: Vec2(x: 0, y: y))
        }
        visibleFile = file
    }

    @discardableResult
    public mutating func nextHunk(forward: Bool, keyPrefix: String = "diff", tx: inout Tx) -> Bool {
        guard !files.isEmpty else { return false }
        let target = forward ? min(files.count - 1, visibleFile + (files[visibleFile].hunks.count <= 1 ? 1 : 0)) : max(0, visibleFile - (files[visibleFile].hunks.count <= 1 ? 1 : 0))
        if files[target].hunks.isEmpty { return false }
        scrollToFile(target, keyPrefix: keyPrefix, tx: &tx)
        return true
    }

    @discardableResult
    public mutating func nextFile(forward: Bool, keyPrefix: String = "diff", tx: inout Tx) -> Bool {
        let target = forward ? visibleFile + 1 : visibleFile - 1
        guard files.indices.contains(target) else { return false }
        scrollToFile(target, keyPrefix: keyPrefix, tx: &tx)
        return true
    }

    /// Keyboard navigation and copy/clear handler (`DiffState::key`).
    public mutating func key(_ event: KeyEvent, keyPrefix: String = "diff", tx: inout Tx) -> Bool {
        let mods = event.mods
        let noCmdMods = !mods.cmd && !mods.ctrl && !mods.alt
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
        case .command("c"):
            if selection.selected != nil {
                tx.copyText(copyText())
                return true
            }
            return false
        case .text("c") where mods.primaryCommand:
            if selection.selected != nil {
                tx.copyText(copyText())
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
                    lines = pre + lines
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
        guard files.indices.contains(file), !collapsed(file: file) else { return [] }
        let hunks = effectiveHunks(file: file)
        guard !hunks.isEmpty else { return [] }
        let gaps = computeGaps(file: file)
        let gapByIndex = Dictionary(uniqueKeysWithValues: gaps.map { ($0.index, $0) })

        // Index annotations by (side, line) for this file
        var annsByLine: [DiffLineRef: [DiffAnnotation]] = [:]
        for ann in annotations where ann.file == file {
            annsByLine[DiffLineRef(side: ann.side, line: ann.line), default: []].append(ann)
        }

        var out: [DiffRow] = []

        func appendAnnotations(forOld o: UInt32?, new n: UInt32?) {
            if let o, let list = annsByLine[DiffLineRef(side: .old, line: o)] {
                out.append(contentsOf: list.map { .annotation($0) })
            }
            if let n, let list = annsByLine[DiffLineRef(side: .new, line: n)] {
                out.append(contentsOf: list.map { .annotation($0) })
            }
        }

        if let g0 = gapByIndex[0] {
            out.append(.gap(g0))
        }

        for (k, h) in hunks.enumerated() {
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
            case .gap, .annotation: row.baseHeight
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
    public var highlighter: SyntaxHighlighter
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
    public func highlighter(_ hl: SyntaxHighlighter) -> Self { var c = self; c.highlighter = hl; return c }
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
        let filesToRender = st.files.isEmpty ? [st.diff] : st.files
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
            .wFull()
            .bg(k.c.surfaceBase)
            .border(1, k.c.borderMuted)
            .rounded(k.radius.md)
            .clip()
        if look.viewportHeight == 0 && cx.viewport.y > 0 {
            container = container.maxH(cx.viewport.y)
        }

        if filesToRender.count == 1 {
            let fIdx = 0
            let diff = filesToRender[0]
            let lang = diff.language
            let gutterDigits = diff.columns
            let gutterWidth = Float(gutterDigits) * 8.5 + 16

            if look.showHeader {
                container = container.child(buildHeader(hostState: hostState, fileIndex: fIdx, state: st, diff: diff, addColor: addColor, delColor: delColor))
            }

            if diff.isBinary {
                return container.child(
                    El<State>(direction: .row)
                        .px(12)
                        .py(12)
                        .child(text("Binary file changed — diff preview unavailable").font(k.ty.caption()).color(k.c.textMuted))
                )
            }

            if st.collapsed(file: fIdx) {
                return container
            }

            let rows = st.rows(file: fIdx)
            if rows.isEmpty {
                return container.child(
                    El<State>(direction: .row)
                        .px(12)
                        .py(10)
                        .child(text("No changes").font(k.ty.caption()).color(k.c.textMuted))
                )
            }

            let scrollY = cx.scrollOffset(of: "\(key)-body").y
            let effectiveViewport = look.viewportHeight > 0 ? look.viewportHeight : cx.viewport.y
            let win = st.visibleWindow(
                for: rows,
                scrollY: scrollY,
                viewportHeight: effectiveViewport,
                lineHeightMultiplier: look.lineHeightMultiplier
            )

            var body = El<State>(direction: .column)
                .key("\(key)-body")
                .wFull()
                .scrollXY()
            if look.viewportHeight > 0 {
                body = body.maxH(look.viewportHeight)
            } else if cx.viewport.y > 0 {
                let avail = max(0, cx.viewport.y - (look.showHeader ? DiffLayout.headerHeight : 0) - 2)
                body = body.maxH(avail).shrink(1)
            }

            if win.beforeHeight > 0 {
                body = body.child(El<State>(direction: .row).key("\(key)-before").wFull().h(win.beforeHeight).shrink(0))
            }

            for rowIdx in win.range {
                body = body.child(renderRow(
                    hostState: hostState,
                    fileIndex: fIdx,
                    prefix: filePrefix(fIdx),
                    rowIdx: rowIdx,
                    rows: rows,
                    st: st,
                    lang: lang,
                    syntaxTheme: syntaxTheme,
                    gutterDigits: gutterDigits,
                    gutterWidth: gutterWidth,
                    lineH: lineH,
                    addLineBg: addLineBg,
                    delLineBg: delLineBg,
                    addWordBg: addWordBg,
                    delWordBg: delWordBg,
                    selBg: selBg
                ))
            }

            if win.afterHeight > 0 {
                body = body.child(El<State>(direction: .row).key("\(key)-after").wFull().h(win.afterHeight).shrink(0))
            }

            return container.child(body)
        }

        // Multi-file scroll stack
        var stack = El<State>(direction: .column)
            .key("\(key)-body")
            .wFull()
            .scrollXY()
        if look.viewportHeight > 0 {
            stack = stack.maxH(look.viewportHeight)
        } else if cx.viewport.y > 0 {
            stack = stack.maxH(max(0, cx.viewport.y - 2)).shrink(1)
        }

        for (fIdx, diff) in filesToRender.enumerated() {
            let prefix = filePrefix(fIdx)
            let lang = diff.language
            let gutterDigits = diff.columns
            let gutterWidth = Float(gutterDigits) * 8.5 + 16
            let headerW: Float? = cx.viewport.x > 2 ? (cx.viewport.x - 2) : nil

            if diff.isBinary {
                var fileSection = El<State>(direction: .column).minWFrac(1.0).shrink(0)
                if look.showHeader {
                    fileSection = fileSection.child(
                        El<State>(direction: .column)
                            .wFull()
                            .shrink(0)
                            .stickyTop()
                            .child(buildHeader(hostState: hostState, fileIndex: fIdx, state: st, diff: diff, addColor: addColor, delColor: delColor, fixedWidth: headerW))
                    )
                }
                fileSection = fileSection.child(
                    El<State>(direction: .row).key("\(prefix)-binary").px(12).py(12)
                        .child(text("Binary file changed — diff preview unavailable").font(k.ty.caption()).color(k.c.textMuted))
                )
                stack = stack.child(fileSection)
                continue
            }
            let rows = st.collapsed(file: fIdx) ? [] : st.rows(file: fIdx)
            let maxCols: Int = st.wrap ? 0 : rows.reduce(0) { best, row in
                switch row {
                case let .unified(line, _, _): return max(best, line.text.count)
                case let .splitPair(o, n, _, _): return max(best, o.text.count + n.text.count)
                case let .splitOnly(line): return max(best, line.text.count)
                case .gap, .annotation: return best
                }
            }
            let contentMinW: Float = maxCols > 0 ? (Float(maxCols) * 7.5 + 2 * gutterWidth + 60) : 0

            var fileSection = El<State>(direction: .column)
                .minWFrac(1.0)
                .shrink(0)
            if contentMinW > (headerW ?? 0) {
                fileSection = fileSection.minW(contentMinW)
            }
            if look.showHeader {
                var headerWrap = El<State>(direction: .column)
                    .wFull()
                    .shrink(0)
                    .stickyTop()
                if contentMinW > (headerW ?? 0) {
                    headerWrap = headerWrap.minW(contentMinW)
                }
                fileSection = fileSection.child(
                    headerWrap.child(buildHeader(hostState: hostState, fileIndex: fIdx, state: st, diff: diff, addColor: addColor, delColor: delColor, fixedWidth: headerW, stickyLeft: true))
                )
            }
            if st.collapsed(file: fIdx) {
                stack = stack.child(fileSection)
                continue
            }
            if rows.isEmpty {
                fileSection = fileSection.child(
                    El<State>(direction: .row).key("\(prefix)-empty").px(12).py(10)
                        .child(text("No changes").font(k.ty.caption()).color(k.c.textMuted))
                )
                stack = stack.child(fileSection)
                continue
            }
            for rowIdx in rows.indices {
                fileSection = fileSection.child(renderRow(
                    hostState: hostState,
                    fileIndex: fIdx,
                    prefix: prefix,
                    rowIdx: rowIdx,
                    rows: rows,
                    st: st,
                    lang: lang,
                    syntaxTheme: syntaxTheme,
                    gutterDigits: gutterDigits,
                    gutterWidth: gutterWidth,
                    lineH: lineH,
                    addLineBg: addLineBg,
                    delLineBg: delLineBg,
                    addWordBg: addWordBg,
                    delWordBg: delWordBg,
                    selBg: selBg
                ))
            }
            stack = stack.child(fileSection)
        }
        return container.child(stack)
    }

    private func renderRow(
        hostState: State?,
        fileIndex: Int,
        prefix: String,
        rowIdx: Int,
        rows: [DiffRow],
        st: DiffState,
        lang: String?,
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
        switch rows[rowIdx] {
        case .gap(let gap):
            let totalGutterW = 3 + (st.mode == .unified ? 2 * gutterWidth : gutterWidth)
            return buildGapRow(fileIndex: fileIndex, prefix: prefix, gap: gap, height: DiffLayout.gapHeight, gutterWidth: totalGutterW)
        case .annotation(let ann):
            return buildAnnotationRow(hostState: hostState, prefix: prefix, mode: st.mode, ann: ann)
        case let .unified(line, intraOld, intraNew):
            return buildUnifiedRow(
                prefix: prefix,
                rowIdx: rowIdx,
                rows: rows,
                line: line,
                intraOld: intraOld,
                intraNew: intraNew,
                st: st,
                lang: lang,
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
                rows: rows,
                oldLine: oldLine,
                newLine: newLine,
                oldChanged: oldChanged,
                newChanged: newChanged,
                st: st,
                lang: lang,
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
                rows: rows,
                line: line,
                st: st,
                lang: lang,
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

        let stats = El<State>(direction: .row)
            .gap(6)
            .itemsCenter()
            .child(text("+\(diff.additionsCount)").font(k.ty.mono).color(addColor))
            .child(text("-\(diff.deletionsCount)").font(k.ty.mono).color(delColor))

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

        let headerLabel = "\(diff.path), \(diff.additionsCount) added, \(diff.deletionsCount) removed"
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

    private func buildAnnotationRow(hostState: State?, prefix: String, mode: DiffMode, ann: DiffAnnotation) -> El<State> {
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

        if mode == .split {
            let emptyHalf = { El<State>(direction: .column).wFrac(0.5).minW(0) }
            let noteHalf = El<State>(direction: .column).wFrac(0.5).minW(0).child(noteBody)
            return El<State>(direction: .row)
                .key("\(prefix)-note-\(ann.id)")
                .wFull()
                .itemsStart()
                .child(ann.side == .old ? noteHalf : emptyHalf())
                .child(ann.side == .new ? noteHalf : emptyHalf())
        }

        return El<State>(direction: .column)
            .key("\(prefix)-note-\(ann.id)")
            .wFull()
            .child(noteBody)
    }

    // MARK: Gutter & Line Selection Helpers

    private func numberCell(
        cellKey: String,
        number: Int?,
        digits: Int,
        width: Float,
        rowIdx: Int,
        rows: [DiffRow],
        side: DiffSide,
        lineH: Float,
        lineBg: Color
    ) -> El<State> {
        let labelStr: String = if let n = number {
            String(format: "%\(digits)d", n)
        } else {
            String(repeating: " ", count: digits)
        }
        guard let n = number else {
            return text(labelStr)
                .font(kit.ty.mono)
                .color(kit.c.textFaint)
                .key(cellKey)
                .w(width)
                .h(lineH)
                .px(6)
                .itemsCenter()
                .justifyEnd()
                .bg(lineBg)
                .shrink(0)
        }
        let point = DiffLineRef(side: side, line: UInt32(n))
        let mode = forcedMode

        var cell: El<State>
        if let onCommentHandler {
            let plusBtn = El<State>(direction: .row)
                .key("\(cellKey)-plus")
                .w(14)
                .h(14)
                .itemsCenter()
                .justifyCenter()
                .rounded(kit.radius.sm)
                .hover(kit.c.surfaceHover)
                .role(.button)
                .label("Add comment on line \(n)")
                .child(icon(KitIcons.plus, size: 10).color(kit.c.textAccent))
                .onClick { [get, onCommentHandler] (s: inout State, tx: inout Tx) in
                    let d = get(s)
                    let range: DiffLineRange = if let sel = d.selectedRange, sel.contains(point) {
                        sel
                    } else {
                        DiffLineRange(start: point, end: point)
                    }
                    onCommentHandler(&s, range, &tx)
                }
            cell = El<State>(direction: .row)
                .key(cellKey)
                .w(width)
                .h(lineH)
                .px(6)
                .gap(4)
                .itemsCenter()
                .justifyEnd()
                .bg(lineBg)
                .shrink(0)
                .child(plusBtn)
                .child(text(labelStr).font(kit.ty.mono).color(kit.c.textFaint))
        } else {
            cell = text(labelStr)
                .font(kit.ty.mono)
                .color(kit.c.textFaint)
                .key(cellKey)
                .w(width)
                .h(lineH)
                .px(6)
                .itemsCenter()
                .justifyEnd()
                .bg(lineBg)
                .shrink(0)
        }

        cell = cell
            .onPointerDown { [get, set, onLineClickHandler] (s: inout State, press: PointerPress, tx: inout Tx) in
                var d = get(s)
                if let mode { d.mode = mode }
                let resolvedMode = d.mode
                d.selection.step(.press(at: point, column: .numbers, shift: press.mods.shift)) { ref in
                    rows.firstIndex { row in
                        row.lineRef(for: resolvedMode, preferredSide: ref.side) == ref
                    }.map { UInt32($0) }
                }
                set(&s, d)
                onLineClickHandler?(&s, point, &tx)
            }
            .onDrag { [get, set] (s: inout State, drag: Drag, _: inout Tx) in
                var d = get(s)
                if let mode { d.mode = mode }
                guard d.selection.isTracking else { return }
                let anchor = d.selection.selected?.start ?? point
                let rowOff = Int(floor(drag.local.y / lineH))
                let targetIdx = max(0, min(rows.count - 1, rowIdx + rowOff))
                let stepDir = (targetIdx >= rowIdx) ? -1 : 1
                var resolved: DiffLineRef?
                for idx in stride(from: targetIdx, through: rowIdx, by: stepDir) {
                    if let cand = rows[idx].lineRef(for: d.mode, preferredSide: side), anchor.joins(with: cand) {
                        resolved = cand
                        break
                    }
                }
                if let targetRef = resolved {
                    d.selection.step(.move(at: targetRef))
                    set(&s, d)
                }
            }
            .onDragEnd { [get, set, onSelectHandler] (s: inout State, cancelled: Bool, tx: inout Tx) in
                var d = get(s)
                let eff = d.selection.step(cancelled ? .cancel : .release)
                set(&s, d)
                if case let .ended(range) = eff {
                    onSelectHandler?(&s, DiffLineRange(from: range), &tx)
                }
            }
        return cell
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
        lang: String?,
        syntaxTheme: SyntaxTheme,
        changedRanges: [Range<Int>],
        wordBg: Color,
        wrap: Bool
    ) -> [TextSpan] {
        let (code, offsetMap) = expandTabsWithOffsets(rawText)
        guard !code.isEmpty else {
            return [TextSpan(" ", color: kit.c.textBase, monospace: true)]
        }

        let highlights = highlighter.highlight(language: lang, code: code)
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

    private func codeBlock(
        cellKey: String,
        side: DiffSide,
        line: DiffLine,
        changed: [Range<Int>],
        wordBg: Color,
        lang: String?,
        syntaxTheme: SyntaxTheme,
        wrap: Bool,
        pr: Float
    ) -> El<State> {
        let spans = buildCodeSpans(text: line.text, lang: lang, syntaxTheme: syntaxTheme, changedRanges: changed, wordBg: wordBg, wrap: wrap)
        var codeEl: El<State> = rich(spans).font(kit.ty.mono)
        if !wrap { codeEl = codeEl.noWrap() }
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

    private func isLineSelected(_ st: DiffState, side: DiffSide, line: DiffLine) -> Bool {
        guard let sel = st.selectedRange else { return false }
        if let n = line.lineNumber(for: sel.start.side) {
            return sel.contains(DiffLineRef(side: sel.start.side, line: n))
        }
        if let n = line.lineNumber(for: side) {
            return sel.contains(DiffLineRef(side: side, line: n))
        }
        return false
    }

    private func buildUnifiedRow(
        prefix: String,
        rowIdx: Int,
        rows: [DiffRow],
        line: DiffLine,
        intraOld: [Range<Int>],
        intraNew: [Range<Int>],
        st: DiffState,
        lang: String?,
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
        let selected = isLineSelected(st, side: side, line: line)
        let rowBg = selected ? diffTintColor(baseBg, hue: selBg, t: 0.45) : baseBg

        let sigil: String = switch line.kind {
        case .addition: "+"
        case .deletion: "-"
        case .context: " "
        }
        let sigilColor: Color = switch line.kind {
        case .addition: kit.c.success.fg
        case .deletion: kit.c.danger.fg
        case .context: kit.c.textFaint
        }

        let changed = (line.kind == .deletion) ? intraOld : intraNew
        let wordBg = (line.kind == .deletion) ? delWordBg : addWordBg
        let codeEl = codeBlock(
            cellKey: "\(prefix)-code-\(rowIdx)",
            side: side,
            line: line,
            changed: changed,
            wordBg: wordBg,
            lang: lang,
            syntaxTheme: syntaxTheme,
            wrap: st.wrap,
            pr: 12
        )

        let gutter = El<State>(direction: .row)
            .key("\(prefix)-gutter-\(rowIdx)")
            .h(lineH)
            .bg(rowBg)
            .itemsCenter()
            .shrink(0)
            .stickyLeft(0)
            .child(gutterBar(line.kind, height: lineH))
            .child(numberCell(cellKey: "\(prefix)-o-\(rowIdx)", number: line.oldNumber, digits: gutterDigits, width: gutterWidth, rowIdx: rowIdx, rows: rows, side: .old, lineH: lineH, lineBg: rowBg))
            .child(numberCell(cellKey: "\(prefix)-n-\(rowIdx)", number: line.newNumber, digits: gutterDigits, width: gutterWidth, rowIdx: rowIdx, rows: rows, side: .new, lineH: lineH, lineBg: rowBg))
            .child(text(sigil).font(kit.ty.mono).color(sigilColor).w(18).h(lineH).itemsCenter().justifyCenter().shrink(0))

        return El<State>(direction: .row)
            .key("\(prefix)-row-\(rowIdx)")
            .label(DiffViewHelpers.rowLabel(line))
            .wFull()
            .minH(lineH)
            .bg(rowBg)
            .itemsCenter()
            .child(gutter)
            .child(codeEl)
    }

    private func buildSplitPairRow(
        prefix: String,
        rowIdx: Int,
        rows: [DiffRow],
        oldLine: DiffLine,
        newLine: DiffLine,
        oldChanged: [Range<Int>],
        newChanged: [Range<Int>],
        st: DiffState,
        lang: String?,
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
        let oldBg = isLineSelected(st, side: .old, line: oldLine) ? diffTintColor(delLineBg, hue: selBg, t: 0.45) : delLineBg
        let newBg = isLineSelected(st, side: .new, line: newLine) ? diffTintColor(addLineBg, hue: selBg, t: 0.45) : addLineBg

        let oldCode = codeBlock(cellKey: "\(prefix)-scode-o-\(rowIdx)", side: .old, line: oldLine, changed: oldChanged, wordBg: delWordBg, lang: lang, syntaxTheme: syntaxTheme, wrap: st.wrap, pr: 8)
        let newCode = codeBlock(cellKey: "\(prefix)-scode-n-\(rowIdx)", side: .new, line: newLine, changed: newChanged, wordBg: addWordBg, lang: lang, syntaxTheme: syntaxTheme, wrap: st.wrap, pr: 8)

        let leftPane = El<State>(direction: .row)
            .wFrac(0.5)
            .minH(lineH)
            .bg(oldBg)
            .itemsCenter()
            .borderSides(right: 1, color: kit.c.borderMuted)
            .child(gutterBar(.deletion, height: lineH))
            .child(numberCell(cellKey: "\(prefix)-so-\(rowIdx)", number: oldLine.oldNumber, digits: gutterDigits, width: gutterWidth, rowIdx: rowIdx, rows: rows, side: .old, lineH: lineH, lineBg: oldBg))
            .child(text("-").font(kit.ty.mono).color(kit.c.danger.fg).w(16).h(lineH).itemsCenter().justifyCenter().shrink(0))
            .child(oldCode)

        let rightPane = El<State>(direction: .row)
            .wFrac(0.5)
            .minH(lineH)
            .bg(newBg)
            .itemsCenter()
            .child(gutterBar(.addition, height: lineH))
            .child(numberCell(cellKey: "\(prefix)-sn-\(rowIdx)", number: newLine.newNumber, digits: gutterDigits, width: gutterWidth, rowIdx: rowIdx, rows: rows, side: .new, lineH: lineH, lineBg: newBg))
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
        rows: [DiffRow],
        line: DiffLine,
        st: DiffState,
        lang: String?,
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
            let lBg = isLineSelected(st, side: .old, line: line) ? diffTintColor(kit.c.surfaceBase, hue: selBg, t: 0.45) : kit.c.surfaceBase
            let rBg = isLineSelected(st, side: .new, line: line) ? diffTintColor(kit.c.surfaceBase, hue: selBg, t: 0.45) : kit.c.surfaceBase
            let leftCode = codeBlock(cellKey: "\(prefix)-ccode-o-\(rowIdx)", side: .old, line: line, changed: [], wordBg: .transparent, lang: lang, syntaxTheme: syntaxTheme, wrap: st.wrap, pr: 8)
            let rightCode = codeBlock(cellKey: "\(prefix)-ccode-n-\(rowIdx)", side: .new, line: line, changed: [], wordBg: .transparent, lang: lang, syntaxTheme: syntaxTheme, wrap: st.wrap, pr: 8)
            let leftPane = El<State>(direction: .row)
                .wFrac(0.5).minH(lineH).bg(lBg).itemsCenter().borderSides(right: 1, color: kit.c.borderMuted)
                .child(gutterBar(.context, height: lineH))
                .child(numberCell(cellKey: "\(prefix)-co-\(rowIdx)", number: line.oldNumber, digits: gutterDigits, width: gutterWidth, rowIdx: rowIdx, rows: rows, side: .old, lineH: lineH, lineBg: lBg))
                .child(El<State>(direction: .row).w(16).h(lineH).shrink(0))
                .child(leftCode)
            let rightPane = El<State>(direction: .row)
                .wFrac(0.5).minH(lineH).bg(rBg).itemsCenter()
                .child(gutterBar(.context, height: lineH))
                .child(numberCell(cellKey: "\(prefix)-cn-\(rowIdx)", number: line.newNumber, digits: gutterDigits, width: gutterWidth, rowIdx: rowIdx, rows: rows, side: .new, lineH: lineH, lineBg: rBg))
                .child(El<State>(direction: .row).w(16).h(lineH).shrink(0))
                .child(rightCode)
            return El<State>(direction: .row).key("\(prefix)-crow-\(rowIdx)").wFull()
                .child(leftPane.label(DiffViewHelpers.rowLabel(line, side: .old)))
                .child(rightPane.label(DiffViewHelpers.rowLabel(line, side: .new)))

        case .deletion:
            let bg = isLineSelected(st, side: .old, line: line) ? diffTintColor(delLineBg, hue: selBg, t: 0.45) : delLineBg
            let code = codeBlock(cellKey: "\(prefix)-dcode-\(rowIdx)", side: .old, line: line, changed: [], wordBg: .transparent, lang: lang, syntaxTheme: syntaxTheme, wrap: st.wrap, pr: 8)
            let leftPane = El<State>(direction: .row)
                .wFrac(0.5).minH(lineH).bg(bg).itemsCenter().borderSides(right: 1, color: kit.c.borderMuted)
                .child(gutterBar(.deletion, height: lineH))
                .child(numberCell(cellKey: "\(prefix)-do-\(rowIdx)", number: line.oldNumber, digits: gutterDigits, width: gutterWidth, rowIdx: rowIdx, rows: rows, side: .old, lineH: lineH, lineBg: bg))
                .child(text("-").font(kit.ty.mono).color(kit.c.danger.fg).w(16).h(lineH).itemsCenter().justifyCenter().shrink(0))
                .child(code)
            return El<State>(direction: .row).key("\(prefix)-drow-\(rowIdx)").wFull()
                .child(leftPane.label(DiffViewHelpers.rowLabel(line, side: .old)))
                .child(emptySide("\(prefix)-dempty-\(rowIdx)", kit.c.surfaceRaised))

        case .addition:
            let bg = isLineSelected(st, side: .new, line: line) ? diffTintColor(addLineBg, hue: selBg, t: 0.45) : addLineBg
            let code = codeBlock(cellKey: "\(prefix)-acode-\(rowIdx)", side: .new, line: line, changed: [], wordBg: .transparent, lang: lang, syntaxTheme: syntaxTheme, wrap: st.wrap, pr: 8)
            let rightPane = El<State>(direction: .row)
                .wFrac(0.5).minH(lineH).bg(bg).itemsCenter()
                .child(gutterBar(.addition, height: lineH))
                .child(numberCell(cellKey: "\(prefix)-an-\(rowIdx)", number: line.newNumber, digits: gutterDigits, width: gutterWidth, rowIdx: rowIdx, rows: rows, side: .new, lineH: lineH, lineBg: bg))
                .child(text("+").font(kit.ty.mono).color(kit.c.success.fg).w(16).h(lineH).itemsCenter().justifyCenter().shrink(0))
                .child(code)
            return El<State>(direction: .row).key("\(prefix)-arow-\(rowIdx)").wFull()
                .child(emptySide("\(prefix)-aempty-\(rowIdx)", kit.c.surfaceRaised).borderSides(right: 1, color: kit.c.borderMuted))
                .child(rightPane.label(DiffViewHelpers.rowLabel(line, side: .new)))
        }
    }
}

// MARK: - Kit Diff Entry Points (`diffView`, `layer`, `tabbed`)

extension Kit {
    /// Renders a read-only unified or split diff element using the full `DiffView` renderer.
    public func diffView<State>(
        key: String,
        _ diff: FileDiff,
        style: DiffStyle = .unified
    ) -> El<State> {
        let fixedState = DiffState(diff: diff, mode: style.mode, expanded: true)
        return DiffView<State>(
            key: key,
            kit: self,
            get: { _ in fixedState },
            set: { _, _ in }
        ).buildReadOnly(diffState: fixedState, cx: Cx<State>(viewport: .zero))
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

        // Snap byte offsets to valid UTF-8 scalar boundaries in `code`.
        func snapBoundary(_ offset: Int) -> Int? {
            guard offset >= 0, offset <= total else { return nil }
            let idx = utf8.index(utf8.startIndex, offsetBy: offset)
            return idx.samePosition(in: code) != nil ? offset : nil
        }

        var cutSet: Set<Int> = [0, total]
        for h in highlights {
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
            if let h = highlights.first(where: { $0.range.lowerBound <= a && a < $0.range.upperBound }) {
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

