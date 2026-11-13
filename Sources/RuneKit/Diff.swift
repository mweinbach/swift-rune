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
        if s == "_" { return true }
        return s.properties.isAlphabetic || CharacterSet.decimalDigits.contains(s)
    }

    @inline(__always)
    static func isJsSpace(_ s: UnicodeScalar) -> Bool {
        switch s.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680,
             0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    /// Tokenizes a line into `jsdiff` `WordsWithSpace` tokens with UTF-8 byte offsets.
    public static func tokenize(_ line: String) -> [Token] {
        var result: [Token] = []
        let scalars = line.unicodeScalars
        var i = scalars.startIndex
        let utf8View = line.utf8

        while i < scalars.endIndex {
            let start = i
            let ch = scalars[i]
            if isWordScalar(ch) {
                while i < scalars.endIndex && isWordScalar(scalars[i]) {
                    i = scalars.index(after: i)
                }
            } else if isJsSpace(ch) {
                while i < scalars.endIndex && isJsSpace(scalars[i]) {
                    i = scalars.index(after: i)
                }
            } else {
                i = scalars.index(after: i)
            }
            let startOff = utf8View.distance(from: utf8View.startIndex, to: start.samePosition(in: utf8View) ?? utf8View.endIndex)
            let endOff = utf8View.distance(from: utf8View.startIndex, to: i.samePosition(in: utf8View) ?? utf8View.endIndex)
            result.append(Token(utf8Range: startOff..<endOff, text: String(scalars[start..<i])))
        }
        return result
    }

    /// Computes UTF-8 byte ranges in `old` (deleted) and `new` (inserted) that changed.
    public static func changedRanges(old: String, new: String) -> (old: [Range<Int>], new: [Range<Int>]) {
        if old.utf8.count > maxLineDiffLength || new.utf8.count > maxLineDiffLength {
            return ([], [])
        }
        let aTokens = tokenize(old)
        let bTokens = tokenize(new)
        let ops = Myers.diff(aTokens.map(\.text), bTokens.map(\.text))

        var oldRanges: [Range<Int>] = []
        var newRanges: [Range<Int>] = []
        var ai = 0
        var bi = 0

        func pushRange(_ list: inout [Range<Int>], _ range: Range<Int>) {
            guard !range.isEmpty else { return }
            if let last = list.last, last.upperBound == range.lowerBound {
                list[list.count - 1] = last.lowerBound..<range.upperBound
            } else {
                list.append(range)
            }
        }

        for op in ops {
            switch op {
            case .equal(let count):
                ai += count
                bi += count
            case .delete(let count):
                if count > 0 {
                    let lo = aTokens[ai].utf8Range.lowerBound
                    let hi = aTokens[ai + count - 1].utf8Range.upperBound
                    pushRange(&oldRanges, lo..<hi)
                }
                ai += count
            case .insert(let count):
                if count > 0 {
                    let lo = bTokens[bi].utf8Range.lowerBound
                    let hi = bTokens[bi + count - 1].utf8Range.upperBound
                    pushRange(&newRanges, lo..<hi)
                }
                bi += count
            }
        }
        return (oldRanges, newRanges)
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
        for scalar in s.unicodeScalars where !DiffWords.isJsSpace(scalar) {
            for cu in scalar.utf16 {
                out.append(cu)
            }
        }
        return out
    }

    static func similarity(_ a: [UInt16], _ b: [UInt16]) -> Double {
        if a.isEmpty && b.isEmpty { return 1.0 }
        let maxLen = max(a.count, b.count)
        if maxLen == 0 { return 1.0 }
        let minLen = min(a.count, b.count)
        if maxLen - minLen > Int(ceil(Double(maxLen) * (1.0 - minGain))) + 1 {
            return 0.0
        }
        // Standard O(min(n, m)) Levenshtein distance
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        var prev = Array(0...short.count)
        var curr = [Int](repeating: 0, count: short.count + 1)
        for (i, lc) in long.enumerated() {
            curr[0] = i + 1
            for (j, sc) in short.enumerated() {
                let cost = (lc == sc) ? 0 : 1
                curr[j + 1] = min(
                    min(curr[j] + 1, prev[j + 1] + 1),
                    prev[j] + cost
                )
            }
            swap(&prev, &curr)
        }
        let dist = prev[short.count]
        return 1.0 - Double(dist) / Double(maxLen)
    }

    static func pairLines(_ dels: [DiffLine], _ adds: [DiffLine]) -> [(Int, Int)] {
        let n = dels.count
        let m = adds.count
        if n == 0 || m == 0 { return [] }
        if n * m > maxComparisons {
            let count = min(n, m)
            return (0..<count).map { ($0, $0) }
        }

        let delKeys = dels.map { strippedUTF16($0.text) }
        let addKeys = adds.map { strippedUTF16($0.text) }

        var dp = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                var best = max(dp[i + 1][j], dp[i][j + 1])
                let sim = similarity(delKeys[i], addKeys[j])
                if sim >= minGain {
                    best = max(best, sim + dp[i + 1][j + 1])
                }
                dp[i][j] = best
            }
        }

        var pairs: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < n && j < m {
            let sim = similarity(delKeys[i], addKeys[j])
            if sim >= minGain && abs(dp[i][j] - (sim + dp[i + 1][j + 1])) < 1e-9 {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    static func splitRows(for lines: [DiffLine]) -> [SplitRow] {
        var rows: [SplitRow] = []
        var i = 0
        while i < lines.count {
            if lines[i].kind == .context {
                rows.append(.only(lines[i]))
                i += 1
                continue
            }

            var dels: [DiffLine] = []
            var adds: [DiffLine] = []
            while i < lines.count && lines[i].kind != .context {
                if lines[i].kind == .deletion {
                    dels.append(lines[i])
                } else {
                    adds.append(lines[i])
                }
                i += 1
            }

            let matches = pairLines(dels, adds)
            var di = 0
            var ai = 0
            for (mi, mj) in matches {
                while di < mi {
                    rows.append(.only(dels[di]))
                    di += 1
                }
                while ai < mj {
                    rows.append(.only(adds[ai]))
                    ai += 1
                }
                let delLine = dels[mi]
                let addLine = adds[mj]
                let changed = DiffWords.changedRanges(old: delLine.text, new: addLine.text)
                rows.append(.pair(old: delLine, new: addLine, oldChanged: changed.old, newChanged: changed.new))
                di += 1
                ai += 1
            }
            while di < dels.count {
                rows.append(.only(dels[di]))
                di += 1
            }
            while ai < adds.count {
                rows.append(.only(adds[ai]))
                ai += 1
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

    public var label: String {
        switch self {
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
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

    public var oldLine: UInt32? { oldNumber.map { UInt32($0) } }
    public var newLine: UInt32? { newNumber.map { UInt32($0) } }

    public init(kind: DiffLineKind, oldNumber: Int?, newNumber: Int?, text: String) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
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
            let suffix = section.map { " \($0)" } ?? ""
            self.header = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\(suffix)"
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
    public var hunks: [DiffHunk]
    public var isBinary: Bool
    public var source: DiffSource?

    public var path: String { newPath.isEmpty ? oldPath : newPath }

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
        case .modified, .renamed: nil
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
        hunks: [DiffHunk],
        isBinary: Bool = false,
        source: DiffSource? = nil
    ) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.status = status
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
        let hunks = buildContextHunks(oldLines: oldLines, newLines: newLines, ops: ops, context: max(0, context))

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
        let rawLines = patch.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var files: [FileDiff] = []
        var curOld = ""
        var curNew = ""
        var curStatus: FileStatus = .modified
        var curBinary = false
        var curHunks: [DiffHunk] = []
        var sawFile = false

        var activeHunkHeader: String?
        var activeSection: String?
        var activeOldStart = 1
        var activeOldCount = 0
        var activeNewStart = 1
        var activeNewCount = 0
        var activeLines: [DiffLine] = []
        var curOldNum = 1
        var curNewNum = 1

        func flushHunk() {
            guard let hdr = activeHunkHeader else { return }
            curHunks.append(DiffHunk(
                header: hdr,
                section: activeSection,
                oldStart: activeOldStart,
                oldCount: activeOldCount,
                newStart: activeNewStart,
                newCount: activeNewCount,
                lines: activeLines
            ))
            activeHunkHeader = nil
            activeSection = nil
            activeLines = []
        }

        func flushFile() {
            flushHunk()
            guard sawFile else { return }
            if curOld == "/dev/null" { curStatus = .added }
            else if curNew == "/dev/null" { curStatus = .deleted }
            files.append(FileDiff(
                oldPath: curOld,
                newPath: curNew,
                status: curStatus,
                hunks: curHunks,
                isBinary: curBinary
            ))
            curOld = ""
            curNew = ""
            curStatus = .modified
            curBinary = false
            curHunks = []
            sawFile = false
        }

        func stripGitPrefix(_ s: String) -> String {
            var p = s.trimmingCharacters(in: .whitespaces)
            if p.hasPrefix("\"") && p.hasSuffix("\"") && p.count >= 2 {
                p = String(p.dropFirst().dropLast())
            }
            if p.hasPrefix("a/") || p.hasPrefix("b/") {
                return String(p.dropFirst(2))
            }
            return p
        }

        for line in rawLines {
            if line.hasPrefix("diff --git ") {
                flushFile()
                sawFile = true
                let rest = String(line.dropFirst("diff --git ".count))
                let parts = parseGitDiffPaths(rest)
                curOld = parts.old
                curNew = parts.new
                continue
            }

            if !sawFile && line.hasPrefix("--- ") {
                sawFile = true
            }

            if line.hasPrefix("new file mode") {
                curStatus = .added
                continue
            }
            if line.hasPrefix("deleted file mode") {
                curStatus = .deleted
                continue
            }
            if line.hasPrefix("rename from ") {
                let from = String(line.dropFirst("rename from ".count))
                curOld = from
                curStatus = .renamed(from: from)
                continue
            }
            if line.hasPrefix("rename to ") {
                let to = String(line.dropFirst("rename to ".count))
                curNew = to
                continue
            }
            if (line.hasPrefix("Binary files ") && line.hasSuffix(" differ")) || line == "GIT binary patch" {
                curBinary = true
                continue
            }
            if line.hasPrefix("--- ") && activeHunkHeader == nil {
                let pathPart = String(line.dropFirst(4)).split(separator: "\t", maxSplits: 1).first.map(String.init) ?? ""
                if pathPart == "/dev/null" {
                    curOld = "/dev/null"
                    curStatus = .added
                } else {
                    curOld = stripGitPrefix(pathPart)
                }
                continue
            }
            if line.hasPrefix("+++ ") && activeHunkHeader == nil {
                let pathPart = String(line.dropFirst(4)).split(separator: "\t", maxSplits: 1).first.map(String.init) ?? ""
                if pathPart == "/dev/null" {
                    curNew = "/dev/null"
                    curStatus = .deleted
                } else {
                    curNew = stripGitPrefix(pathPart)
                }
                continue
            }
            if line.hasPrefix("@@ ") {
                flushHunk()
                sawFile = true
                if let parsed = parseHunkHeader(line) {
                    activeHunkHeader = line
                    activeSection = parsed.section
                    activeOldStart = parsed.oldStart
                    activeOldCount = parsed.oldCount
                    activeNewStart = parsed.newStart
                    activeNewCount = parsed.newCount
                    curOldNum = parsed.oldStart
                    curNewNum = parsed.newStart
                }
                continue
            }

            guard activeHunkHeader != nil else { continue }
            if line.hasPrefix("+") {
                activeLines.append(DiffLine(kind: .addition, oldNumber: nil, newNumber: curNewNum, text: String(line.dropFirst())))
                curNewNum += 1
            } else if line.hasPrefix("-") {
                activeLines.append(DiffLine(kind: .deletion, oldNumber: curOldNum, newNumber: nil, text: String(line.dropFirst())))
                curOldNum += 1
            } else if line.hasPrefix(" ") {
                activeLines.append(DiffLine(kind: .context, oldNumber: curOldNum, newNumber: curNewNum, text: String(line.dropFirst())))
                curOldNum += 1
                curNewNum += 1
            } else if line == "\\ No newline at end of file" {
                continue
            } else if !line.isEmpty {
                // Treat bare unprefixed line inside hunk as context
                activeLines.append(DiffLine(kind: .context, oldNumber: curOldNum, newNumber: curNewNum, text: line))
                curOldNum += 1
                curNewNum += 1
            }
        }
        flushFile()
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
        let limit = max(0, index - 80)
        var i = index - 1
        while i >= limit {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("fn ") || trimmed.hasPrefix("pub fn ") || trimmed.hasPrefix("async fn ") ||
               trimmed.hasPrefix("func ") || trimmed.hasPrefix("public func ") || trimmed.hasPrefix("private func ") ||
               trimmed.hasPrefix("def ") || trimmed.hasPrefix("async def ") ||
               trimmed.hasPrefix("class ") || trimmed.hasPrefix("struct ") || trimmed.hasPrefix("enum ") ||
               trimmed.hasPrefix("impl ") || trimmed.hasPrefix("protocol ") || trimmed.hasPrefix("# ") || trimmed.hasPrefix("## ") {
                let singleLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
                return singleLine.count > 80 ? String(singleLine.prefix(80)) : singleLine
            }
            if i == 0 { break }
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

    private static func parseGitDiffPaths(_ s: String) -> (old: String, new: String) {
        // Handles `a/foo b/foo` and quoted paths `"a/foo bar" "b/foo bar"`
        if let bRange = s.range(of: " b/") {
            var old = String(s[..<bRange.lowerBound])
            if old.hasPrefix("a/") { old = String(old.dropFirst(2)) }
            let new = String(s[bRange.upperBound...])
            return (old, new)
        }
        let parts = s.split(separator: " ", maxSplits: 1).map(String.init)
        let o = parts.first.map { $0.hasPrefix("a/") ? String($0.dropFirst(2)) : $0 } ?? ""
        let n = parts.dropFirst().first.map { $0.hasPrefix("b/") ? String($0.dropFirst(2)) : $0 } ?? o
        return (o, n)
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
    public var side: DiffSide
    public var line: UInt32
    public var author: String?
    public var body: String

    public init(id: String, side: DiffSide, line: UInt32, author: String? = nil, body: String) {
        self.id = id
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

/// Interactive diff state tracking mode, folding, gap expansion, annotations, and line selection (`crate::diff::state::DiffState`).
public struct DiffState: Sendable, Equatable {
    public var diff: FileDiff
    public var mode: DiffMode
    public var expanded: Bool
    public var wrap: Bool
    public var annotations: [DiffAnnotation]
    public var selection: LineSelectionState<DiffLineRef>
    public var hoveredRow: Int?
    public var copiedToastVisible: Bool

    private var gapExpansions: [Int: GapExpansion] = [:]

    public init(
        diff: FileDiff,
        mode: DiffMode = .unified,
        expanded: Bool = true,
        wrap: Bool = false,
        annotations: [DiffAnnotation] = []
    ) {
        self.diff = diff
        self.mode = mode
        self.expanded = expanded
        self.wrap = wrap
        self.annotations = annotations
        self.selection = .idle(selected: nil)
        self.hoveredRow = nil
        self.copiedToastVisible = false
    }

    public mutating func setDiff(_ diff: FileDiff) {
        self.diff = diff
        self.gapExpansions = [:]
        self.selection = .idle(selected: nil)
        self.hoveredRow = nil
    }

    public mutating func setMode(_ mode: DiffMode) {
        self.mode = mode
    }

    public mutating func toggleExpanded() {
        expanded.toggle()
    }

    public mutating func toggleWrap() {
        wrap.toggle()
    }

    /// Expands a collapsed context gap in `up`, `down`, or `all` direction by `DiffLayout.expandStep`.
    public mutating func expand(gapIndex: Int, direction: DiffExpand) {
        let gaps = computeGaps()
        guard let gap = gaps.first(where: { $0.index == gapIndex }) else { return }
        var exp = gapExpansions[gapIndex, default: GapExpansion()]
        let remaining = gap.count
        switch direction {
        case .up:
            exp.top += min(DiffLayout.expandStep, remaining)
        case .down:
            exp.bottom += min(DiffLayout.expandStep, remaining)
        case .all:
            exp.top += remaining
        }
        gapExpansions[gapIndex] = exp
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
    public func copyText(side: DiffCopySide = .new) -> String {
        if let sel = selectedRange {
            var lines: [String] = []
            for h in effectiveHunks() {
                for l in h.lines {
                    let matchesSel: Bool = switch sel.start.side {
                    case .old:
                        l.oldLine.map { $0 >= sel.start.line && $0 <= sel.end.line } ?? false
                    case .new:
                        l.newLine.map { $0 >= sel.start.line && $0 <= sel.end.line } ?? false
                    }
                    guard matchesSel else { continue }
                    if matchesCopySide(l.kind, copySide: side) {
                        lines.append(l.text)
                    }
                }
            }
            return lines.joined(separator: "\n")
        }
        switch side {
        case .old: return diff.text(side: .old)
        case .new: return diff.text(side: .new)
        case .both: return diff.copyableText(includeRemoved: true)
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

    /// Returns gap descriptors between/around hunks accounting for expansions so far.
    public func computeGaps() -> [DiffGap] {
        guard !diff.hunks.isEmpty else { return [] }
        var gaps: [DiffGap] = []
        let hunks = diff.hunks

        // Leading gap (index 0) before hunk 0
        let exp0 = gapExpansions[0, default: GapExpansion()]
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
            let exp = gapExpansions[idx, default: GapExpansion()]
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
        if let src = diff.source, let last = hunks.last {
            let idx = hunks.count
            let exp = gapExpansions[idx, default: GapExpansion()]
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
        oldStart1: Int,
        newStart1: Int,
        count: Int
    ) -> [DiffLine] {
        guard count > 0, let src = diff.source else { return [] }
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
    public func effectiveHunks() -> [DiffHunk] {
        guard !diff.hunks.isEmpty else { return [] }
        let hunks = diff.hunks
        var result: [DiffHunk] = []
        for (k, h) in hunks.enumerated() {
            var lines = h.lines
            // Prepend expanded bottom of gap `k` above this hunk
            let gapAbove = gapExpansions[k, default: GapExpansion()]
            if gapAbove.bottom > 0, diff.source != nil {
                let prevEndOld = (k == 0) ? 1 : (hunks[k - 1].oldStart + hunks[k - 1].oldCount)
                let prevEndNew = (k == 0) ? 1 : (hunks[k - 1].newStart + hunks[k - 1].newCount)
                let avail = max(0, h.oldStart - prevEndOld)
                let take = min(avail, gapAbove.bottom + gapAbove.top)
                let bottomTake = min(avail, gapAbove.bottom)
                if bottomTake > 0 {
                    let pre = contextLinesFromSource(
                        oldStart1: h.oldStart - bottomTake,
                        newStart1: h.newStart - bottomTake,
                        count: bottomTake
                    )
                    lines = pre + lines
                }
                _ = take
                _ = prevEndNew
            }

            // Append expanded top of gap `k + 1` below this hunk
            let gapBelow = gapExpansions[k + 1, default: GapExpansion()]
            if gapBelow.top > 0, let src = diff.source {
                let nextOldStart = (k + 1 < hunks.count) ? hunks[k + 1].oldStart : (src.oldLines.count + 1)
                let avail = max(0, nextOldStart - (h.oldStart + h.oldCount))
                let topTake = min(avail, gapBelow.top)
                if topTake > 0 {
                    let post = contextLinesFromSource(
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
    public func rows() -> [DiffRow] {
        guard expanded else { return [] }
        let hunks = effectiveHunks()
        guard !hunks.isEmpty else { return [] }
        let gaps = computeGaps()
        let gapByIndex = Dictionary(uniqueKeysWithValues: gaps.map { ($0.index, $0) })

        // Index annotations by (side, line)
        var annsByLine: [DiffLineRef: [DiffAnnotation]] = [:]
        for ann in annotations {
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

        // Emit leading gap 0 if present (plus any top-expanded prefix lines)
        if let g0 = gapByIndex[0] {
            let exp0 = gapExpansions[0, default: GapExpansion()]
            if exp0.top > 0 {
                let topLines = contextLinesFromSource(oldStart1: 1, newStart1: 1, count: exp0.top)
                for l in topLines {
                    out.append(mode == .unified ? .unified(l) : .splitOnly(l))
                    appendAnnotations(forOld: l.oldLine, new: l.newLine)
                }
            }
            out.append(.gap(g0))
        }

        for (k, h) in hunks.enumerated() {
            if k > 0, let g = gapByIndex[k] {
                out.append(.gap(g))
            }
            switch mode {
            case .unified:
                // Compute intra-line highlights for paired deletion/addition runs even in unified view
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

    /// Builds a read-only `El<State>` without evaluating any `State` value (`Kit.diffView` compatibility).
    public func buildReadOnly(diffState: DiffState, cx: Cx<State> = Cx<State>(viewport: .zero)) -> El<State> {
        var st = diffState
        if let forcedMode {
            st.mode = forcedMode
        }
        return renderContainer(diffState: st, cx: cx)
    }

    public func build(state: State, cx: Cx<State>) -> El<State> {
        var diffState = get(state)
        if let forcedMode {
            diffState.mode = forcedMode
        }
        return renderContainer(diffState: diffState, cx: cx)
    }

    private func renderContainer(diffState st: DiffState, cx: Cx<State>) -> El<State> {
        let k = kit
        let diff = st.diff
        let syntaxTheme = SyntaxTheme.fromKit(k)
        let lang = diff.language
        let gutterDigits = diff.columns
        let gutterWidth = Float(gutterDigits) * 8.5 + 16
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
            .bg(k.c.surfaceBase)
            .border(1, k.c.borderMuted)
            .rounded(k.radius.md)
            .clip()

        if look.showHeader {
            container = container.child(buildHeader(state: st, addColor: addColor, delColor: delColor))
        }

        if diff.isBinary {
            return container.child(
                El<State>(direction: .row)
                    .px(12)
                    .py(12)
                    .child(text("Binary file changed — diff preview unavailable").font(k.ty.caption()).color(k.c.textMuted))
            )
        }

        if !st.expanded {
            return container
        }

        let rows = st.rows()
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

        if win.beforeHeight > 0 {
            body = body.child(El<State>(direction: .row).key("\(key)-before").wFull().h(win.beforeHeight).shrink(0))
        }

        for rowIdx in win.range {
            let row = rows[rowIdx]
            switch row {
            case .gap(let gap):
                body = body.child(buildGapRow(gap: gap, height: DiffLayout.gapHeight))
            case .annotation(let ann):
                body = body.child(buildAnnotationRow(ann))
            case let .unified(line, intraOld, intraNew):
                body = body.child(buildUnifiedRow(
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
                ))
            case let .splitPair(oldLine, newLine, oldChanged, newChanged):
                body = body.child(buildSplitPairRow(
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
                ))
            case .splitOnly(let line):
                body = body.child(buildSplitOnlyRow(
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
                ))
            }
        }

        if win.afterHeight > 0 {
            body = body.child(El<State>(direction: .row).key("\(key)-after").wFull().h(win.afterHeight).shrink(0))
        }

        return container.child(body)
    }

    // MARK: Header

    private func buildHeader(state st: DiffState, addColor: Color, delColor: Color) -> El<State> {
        let k = kit
        let diff = st.diff
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
        case .renamed: k.c.textAccent
        }

        let foldBtn = El<State>(direction: .row)
            .key("\(key)-fold")
            .role(.button)
            .focusable()
            .itemsCenter()
            .gap(6)
            .child(icon(st.expanded ? KitIcons.chevronDown : KitIcons.chevronRight, size: 14).color(k.c.textMuted))
            .child(text(foldSummaryText).font(k.ty.uiMedium).color(k.c.textBase))
            .onClick { [get, set] s in
                var d = get(s)
                d.toggleExpanded()
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
            .key("\(key)-mode")
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
            .key("\(key)-wrap")
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
            .key("\(key)-copy")
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
                let txt = d.copyText(side: .new)
                d.copiedToastVisible = true
                set(&s, d)
                tx.copyText(txt)
                onCopyHandler?(&s, txt, &tx)
            }
            .child(icon(st.copiedToastVisible ? KitIcons.check : KitIcons.copy, size: 12).color(k.c.textMuted))
            .child(text(st.copiedToastVisible ? "Copied" : "Copy").font(k.ty.caption()).color(k.c.textMuted))

        return El<State>(direction: .row)
            .key("\(key)-header")
            .stickyTop()
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
            .child(
                El<State>(direction: .row)
                    .gap(8)
                    .itemsCenter()
                    .child(stats)
                    .child(modeBtn)
                    .child(wrapBtn)
                    .child(copyBtn)
            )
    }

    // MARK: Gap & Annotation Rows

    private func buildGapRow(gap: DiffGap, height: Float) -> El<State> {
        let k = kit
        var bar = El<State>(direction: .row)
            .key("\(key)-gap-\(gap.index)")
            .h(height)
            .px(12)
            .gap(8)
            .itemsCenter()
            .bg(k.c.surfaceRaised)
            .borderSides(top: 1, bottom: 1, color: k.c.borderMuted)

        if gap.canStep && !gap.atStart {
            bar = bar.child(gapActionButton(id: "\(key)-gap-\(gap.index)-down", label: "Expand 20 down") { [get, set] s in
                var d = get(s)
                d.expand(gapIndex: gap.index, direction: .down)
                set(&s, d)
            })
        }
        bar = bar.child(gapActionButton(id: "\(key)-gap-\(gap.index)-all", label: "Expand all (\(gap.count) lines)") { [get, set] s in
            var d = get(s)
            d.expand(gapIndex: gap.index, direction: .all)
            set(&s, d)
        })
        if gap.canStep && !gap.atEnd {
            bar = bar.child(gapActionButton(id: "\(key)-gap-\(gap.index)-up", label: "Expand 20 up") { [get, set] s in
                var d = get(s)
                d.expand(gapIndex: gap.index, direction: .up)
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

    private func buildAnnotationRow(_ ann: DiffAnnotation) -> El<State> {
        let k = kit
        return El<State>(direction: .column)
            .key("\(key)-note-\(ann.id)")
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
        var cell = El<State>(direction: .row)
            .key(cellKey)
            .w(width)
            .h(lineH)
            .px(6)
            .itemsCenter()
            .justifyEnd()
            .bg(lineBg)
            .shrink(0)
            .child(text(labelStr).font(kit.ty.mono).color(kit.c.textFaint))

        guard let n = number else { return cell }
        let point = DiffLineRef(side: side, line: UInt32(n))
        let mode = forcedMode

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

    private func expandTabs(_ s: String) -> String {
        guard s.contains("\t") else { return s }
        return s.replacingOccurrences(of: "\t", with: String(repeating: " ", count: look.tabSize))
    }

    private func buildCodeSpans(
        text rawText: String,
        lang: String?,
        syntaxTheme: SyntaxTheme,
        changedRanges: [Range<Int>],
        wordBg: Color
    ) -> [TextSpan] {
        let code = expandTabs(rawText)
        guard !code.isEmpty else {
            return [TextSpan(" ", color: kit.c.textBase, monospace: true)]
        }

        let highlights = highlighter.highlight(language: lang, code: code)
        let utf8Len = code.utf8.count
        var cuts: Set<Int> = [0, utf8Len]
        for h in highlights {
            let lo = max(0, min(utf8Len, h.range.lowerBound))
            let hi = max(lo, min(utf8Len, h.range.upperBound))
            cuts.insert(lo)
            cuts.insert(hi)
        }
        // Only apply byte-offset intra-line word ranges when tabs weren't expanded or lengths match
        let useWordRanges = (rawText == code)
        if useWordRanges {
            for r in changedRanges {
                let lo = max(0, min(utf8Len, r.lowerBound))
                let hi = max(lo, min(utf8Len, r.upperBound))
                cuts.insert(lo)
                cuts.insert(hi)
            }
        }
        let sorted = cuts.sorted()
        let utf8 = code.utf8

        var spans: [TextSpan] = []
        spans.reserveCapacity(max(1, sorted.count - 1))

        for i in 0..<(sorted.count - 1) {
            let lo = sorted[i]
            let hi = sorted[i + 1]
            guard lo < hi else { continue }
            let startIdx = utf8.index(utf8.startIndex, offsetBy: lo)
            let endIdx = utf8.index(utf8.startIndex, offsetBy: hi)
            let slice = String(decoding: utf8[startIdx..<endIdx], as: UTF8.self)

            let color: Color = highlights.first(where: { $0.range.lowerBound <= lo && hi <= $0.range.upperBound })
                .map { syntaxTheme.paint($0.paint) } ?? kit.c.textBase
            let isWordChanged = useWordRanges && changedRanges.contains(where: { $0.lowerBound <= lo && hi <= $0.upperBound })

            spans.append(TextSpan(
                slice,
                color: color,
                background: isWordChanged ? wordBg : nil,
                monospace: true
            ))
        }
        return spans
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
        let spans = buildCodeSpans(text: line.text, lang: lang, syntaxTheme: syntaxTheme, changedRanges: changed, wordBg: wordBg)

        var codeEl: El<State> = rich(spans).font(kit.ty.mono)
        if !st.wrap {
            codeEl = codeEl.noWrap()
        }

        return El<State>(direction: .row)
            .key("\(key)-row-\(rowIdx)")
            .wFull()
            .minH(lineH)
            .bg(rowBg)
            .itemsCenter()
            .child(numberCell(cellKey: "\(key)-o-\(rowIdx)", number: line.oldNumber, digits: gutterDigits, width: gutterWidth, rowIdx: rowIdx, rows: rows, side: .old, lineH: lineH, lineBg: rowBg))
            .child(numberCell(cellKey: "\(key)-n-\(rowIdx)", number: line.newNumber, digits: gutterDigits, width: gutterWidth, rowIdx: rowIdx, rows: rows, side: .new, lineH: lineH, lineBg: rowBg))
            .child(El<State>(direction: .row).w(18).h(lineH).itemsCenter().justifyCenter().shrink(0).child(text(sigil).font(kit.ty.mono).color(sigilColor)))
            .child(El<State>(direction: .row).grow(1).pr(12).child(codeEl))
    }

    private func buildSplitPairRow(
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

        let oldSpans = buildCodeSpans(text: oldLine.text, lang: lang, syntaxTheme: syntaxTheme, changedRanges: oldChanged, wordBg: delWordBg)
        let newSpans = buildCodeSpans(text: newLine.text, lang: lang, syntaxTheme: syntaxTheme, changedRanges: newChanged, wordBg: addWordBg)

        var oldCode: El<State> = rich(oldSpans).font(kit.ty.mono)
        var newCode: El<State> = rich(newSpans).font(kit.ty.mono)
        if !st.wrap {
            oldCode = oldCode.noWrap()
            newCode = newCode.noWrap()
        }

        let leftPane = El<State>(direction: .row)
            .wFrac(0.5)
            .minH(lineH)
            .bg(oldBg)
            .itemsCenter()
            .borderSides(right: 1, color: kit.c.borderMuted)
            .child(numberCell(cellKey: "\(key)-so-\(rowIdx)", number: oldLine.oldNumber, digits: gutterDigits, width: gutterWidth, rowIdx: rowIdx, rows: rows, side: .old, lineH: lineH, lineBg: oldBg))
            .child(El<State>(direction: .row).w(16).h(lineH).itemsCenter().justifyCenter().shrink(0).child(text("-").font(kit.ty.mono).color(kit.c.danger.fg)))
            .child(El<State>(direction: .row).grow(1).pr(8).child(oldCode))

        let rightPane = El<State>(direction: .row)
            .wFrac(0.5)
            .minH(lineH)
            .bg(newBg)
            .itemsCenter()
            .child(numberCell(cellKey: "\(key)-sn-\(rowIdx)", number: newLine.newNumber, digits: gutterDigits, width: gutterWidth, rowIdx: rowIdx, rows: rows, side: .new, lineH: lineH, lineBg: newBg))
            .child(El<State>(direction: .row).w(16).h(lineH).itemsCenter().justifyCenter().shrink(0).child(text("+").font(kit.ty.mono).color(kit.c.success.fg)))
            .child(El<State>(direction: .row).grow(1).pr(8).child(newCode))

        return El<State>(direction: .row)
            .key("\(key)-srow-\(rowIdx)")
            .wFull()
            .child(leftPane)
            .child(rightPane)
    }

    private func buildSplitOnlyRow(
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
        let spans = buildCodeSpans(text: line.text, lang: lang, syntaxTheme: syntaxTheme, changedRanges: [], wordBg: .transparent)
        var code: El<State> = rich(spans).font(kit.ty.mono)
        if !st.wrap { code = code.noWrap() }

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
            let leftPane = El<State>(direction: .row)
                .wFrac(0.5).minH(lineH).bg(lBg).itemsCenter().borderSides(right: 1, color: kit.c.borderMuted)
                .child(numberCell(cellKey: "\(key)-co-\(rowIdx)", number: line.oldNumber, digits: gutterDigits, width: gutterWidth, rowIdx: rowIdx, rows: rows, side: .old, lineH: lineH, lineBg: lBg))
                .child(El<State>(direction: .row).w(16).h(lineH).shrink(0))
                .child(El<State>(direction: .row).grow(1).pr(8).child(code))
            let rightPane = El<State>(direction: .row)
                .wFrac(0.5).minH(lineH).bg(rBg).itemsCenter()
                .child(numberCell(cellKey: "\(key)-cn-\(rowIdx)", number: line.newNumber, digits: gutterDigits, width: gutterWidth, rowIdx: rowIdx, rows: rows, side: .new, lineH: lineH, lineBg: rBg))
                .child(El<State>(direction: .row).w(16).h(lineH).shrink(0))
                .child(El<State>(direction: .row).grow(1).pr(8).child(code))
            return El<State>(direction: .row).key("\(key)-crow-\(rowIdx)").wFull().child(leftPane).child(rightPane)

        case .deletion:
            let bg = isLineSelected(st, side: .old, line: line) ? diffTintColor(delLineBg, hue: selBg, t: 0.45) : delLineBg
            let leftPane = El<State>(direction: .row)
                .wFrac(0.5).minH(lineH).bg(bg).itemsCenter().borderSides(right: 1, color: kit.c.borderMuted)
                .child(numberCell(cellKey: "\(key)-do-\(rowIdx)", number: line.oldNumber, digits: gutterDigits, width: gutterWidth, rowIdx: rowIdx, rows: rows, side: .old, lineH: lineH, lineBg: bg))
                .child(El<State>(direction: .row).w(16).h(lineH).itemsCenter().justifyCenter().shrink(0).child(text("-").font(kit.ty.mono).color(kit.c.danger.fg)))
                .child(El<State>(direction: .row).grow(1).pr(8).child(code))
            return El<State>(direction: .row).key("\(key)-drow-\(rowIdx)").wFull()
                .child(leftPane)
                .child(emptySide("\(key)-dempty-\(rowIdx)", kit.c.surfaceRaised))

        case .addition:
            let bg = isLineSelected(st, side: .new, line: line) ? diffTintColor(addLineBg, hue: selBg, t: 0.45) : addLineBg
            let rightPane = El<State>(direction: .row)
                .wFrac(0.5).minH(lineH).bg(bg).itemsCenter()
                .child(numberCell(cellKey: "\(key)-an-\(rowIdx)", number: line.newNumber, digits: gutterDigits, width: gutterWidth, rowIdx: rowIdx, rows: rows, side: .new, lineH: lineH, lineBg: bg))
                .child(El<State>(direction: .row).w(16).h(lineH).itemsCenter().justifyCenter().shrink(0).child(text("+").font(kit.ty.mono).color(kit.c.success.fg)))
                .child(El<State>(direction: .row).grow(1).pr(8).child(code))
            return El<State>(direction: .row).key("\(key)-arow-\(rowIdx)").wFull()
                .child(emptySide("\(key)-aempty-\(rowIdx)", kit.c.surfaceRaised).borderSides(right: 1, color: kit.c.borderMuted))
                .child(rightPane)
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

