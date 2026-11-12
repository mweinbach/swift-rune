import Foundation
import Rune

public enum DiffLineKind: Sendable, Equatable {
    case context
    case added
    case removed
}

public struct DiffLine: Sendable, Equatable {
    public var kind: DiffLineKind
    public var oldLineNumber: Int?
    public var newLineNumber: Int?
    public var content: String

    public init(kind: DiffLineKind, oldLineNumber: Int?, newLineNumber: Int?, content: String) {
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.content = content
    }
}

public struct DiffHunk: Sendable, Equatable {
    public var header: String
    public var oldStart: Int
    public var newStart: Int
    public var lines: [DiffLine]

    public init(header: String, oldStart: Int = 1, newStart: Int = 1, lines: [DiffLine]) {
        self.header = header
        self.oldStart = oldStart
        self.newStart = newStart
        self.lines = lines
    }
}

/// Parsed or computed file diff (`rune_kit::diff`).
public struct FileDiff: Sendable, Equatable {
    public var oldPath: String
    public var newPath: String
    public var hunks: [DiffHunk]

    public init(oldPath: String, newPath: String, hunks: [DiffHunk]) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.hunks = hunks
    }

    public var additionsCount: Int {
        hunks.reduce(0) { acc, h in acc + h.lines.filter { $0.kind == .added }.count }
    }

    public var deletionsCount: Int {
        hunks.reduce(0) { acc, h in acc + h.lines.filter { $0.kind == .removed }.count }
    }

    /// Computes a Myers / LCS line diff between `oldText` and `newText`.
    public static func between(old oldText: String, new newText: String, path: String = "file") -> FileDiff {
        let oldLines = oldText.isEmpty ? [] : oldText.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let newLines = newText.isEmpty ? [] : newText.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        let m = oldLines.count
        let n = newLines.count
        // DP LCS matrix (clean & exact for typical source files; falls back linearly if huge)
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        if m > 0 && n > 0 {
            for i in stride(from: m - 1, through: 0, by: -1) {
                for j in stride(from: n - 1, through: 0, by: -1) {
                    if oldLines[i] == newLines[j] {
                        dp[i][j] = dp[i + 1][j + 1] + 1
                    } else {
                        dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                    }
                }
            }
        }

        var diffLines: [DiffLine] = []
        var i = 0
        var j = 0
        while i < m && j < n {
            if oldLines[i] == newLines[j] {
                diffLines.append(DiffLine(kind: .context, oldLineNumber: i + 1, newLineNumber: j + 1, content: oldLines[i]))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                diffLines.append(DiffLine(kind: .removed, oldLineNumber: i + 1, newLineNumber: nil, content: oldLines[i]))
                i += 1
            } else {
                diffLines.append(DiffLine(kind: .added, oldLineNumber: nil, newLineNumber: j + 1, content: newLines[j]))
                j += 1
            }
        }
        while i < m {
            diffLines.append(DiffLine(kind: .removed, oldLineNumber: i + 1, newLineNumber: nil, content: oldLines[i]))
            i += 1
        }
        while j < n {
            diffLines.append(DiffLine(kind: .added, oldLineNumber: nil, newLineNumber: j + 1, content: newLines[j]))
            j += 1
        }

        let hunk = DiffHunk(header: "@@ -1,\(m) +1,\(n) @@", oldStart: 1, newStart: 1, lines: diffLines)
        return FileDiff(oldPath: path, newPath: path, hunks: diffLines.isEmpty ? [] : [hunk])
    }

    /// Parses standard `git diff` / unified patch output into one or more `FileDiff` records.
    public static func parseUnified(_ patch: String) -> [FileDiff] {
        let rawLines = patch.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var files: [FileDiff] = []
        var curOldPath = ""
        var curNewPath = ""
        var curHunks: [DiffHunk] = []
        var curHunkHeader: String? = nil
        var curHunkOldStart = 1
        var curHunkNewStart = 1
        var oldCursor = 1
        var newCursor = 1
        var curLines: [DiffLine] = []

        func flushHunk() {
            if let hdr = curHunkHeader {
                curHunks.append(DiffHunk(header: hdr, oldStart: curHunkOldStart, newStart: curHunkNewStart, lines: curLines))
                curHunkHeader = nil
                curLines.removeAll(keepingCapacity: true)
            }
        }

        func flushFile() {
            flushHunk()
            if !curOldPath.isEmpty || !curNewPath.isEmpty || !curHunks.isEmpty {
                files.append(FileDiff(
                    oldPath: curOldPath.isEmpty ? curNewPath : curOldPath,
                    newPath: curNewPath.isEmpty ? curOldPath : curNewPath,
                    hunks: curHunks
                ))
                curOldPath = ""
                curNewPath = ""
                curHunks.removeAll()
            }
        }

        for line in rawLines {
            if line.hasPrefix("diff --git ") {
                flushFile()
                continue
            }
            if line.hasPrefix("--- ") && curHunkHeader == nil {
                var p = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                if p.hasPrefix("a/") { p.removeFirst(2) }
                curOldPath = p
                continue
            }
            if line.hasPrefix("+++ ") && curHunkHeader == nil {
                var p = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                if p.hasPrefix("b/") { p.removeFirst(2) }
                curNewPath = p
                continue
            }
            if line.hasPrefix("@@") {
                flushHunk()
                curHunkHeader = line
                let (os, ns) = parseHunkNumbers(line)
                curHunkOldStart = os
                curHunkNewStart = ns
                oldCursor = os
                newCursor = ns
                continue
            }
            guard curHunkHeader != nil else { continue }
            if line.hasPrefix("+") {
                curLines.append(DiffLine(kind: .added, oldLineNumber: nil, newLineNumber: newCursor, content: String(line.dropFirst())))
                newCursor += 1
            } else if line.hasPrefix("-") {
                curLines.append(DiffLine(kind: .removed, oldLineNumber: oldCursor, newLineNumber: nil, content: String(line.dropFirst())))
                oldCursor += 1
            } else if line.hasPrefix(" ") {
                curLines.append(DiffLine(kind: .context, oldLineNumber: oldCursor, newLineNumber: newCursor, content: String(line.dropFirst())))
                oldCursor += 1
                newCursor += 1
            }
        }
        flushFile()
        return files
    }

    private static func parseHunkNumbers(_ header: String) -> (Int, Int) {
        // Format: @@ -oldStart[,oldCount] +newStart[,newCount] @@
        var oldS = 1
        var newS = 1
        for part in header.split(separator: " ") {
            if part.hasPrefix("-") {
                let nums = part.dropFirst().split(separator: ",")
                if let first = nums.first, let v = Int(first) { oldS = max(1, v) }
            } else if part.hasPrefix("+") {
                let nums = part.dropFirst().split(separator: ",")
                if let first = nums.first, let v = Int(first) { newS = max(1, v) }
            }
        }
        return (oldS, newS)
    }

    /// Word/token-level inline diff between two lines (`rune_kit::diff::words`).
    public static func wordDiff(old: String, new: String) -> [(kind: DiffLineKind, text: String)] {
        let oldTokens = tokenizeWords(old)
        let newTokens = tokenizeWords(new)
        let m = oldTokens.count
        let n = newTokens.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        if m > 0 && n > 0 {
            for i in stride(from: m - 1, through: 0, by: -1) {
                for j in stride(from: n - 1, through: 0, by: -1) {
                    if oldTokens[i] == newTokens[j] {
                        dp[i][j] = dp[i + 1][j + 1] + 1
                    } else {
                        dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                    }
                }
            }
        }
        var out: [(kind: DiffLineKind, text: String)] = []
        var i = 0
        var j = 0
        while i < m && j < n {
            if oldTokens[i] == newTokens[j] {
                out.append((.context, oldTokens[i]))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                out.append((.removed, oldTokens[i]))
                i += 1
            } else {
                out.append((.added, newTokens[j]))
                j += 1
            }
        }
        while i < m {
            out.append((.removed, oldTokens[i]))
            i += 1
        }
        while j < n {
            out.append((.added, newTokens[j]))
            j += 1
        }
        return out
    }

    private static func tokenizeWords(_ s: String) -> [String] {
        var tokens: [String] = []
        var cur = ""
        var curIsWord: Bool? = nil
        for ch in s {
            let isWord = ch.isLetter || ch.isNumber || ch == "_"
            if let prev = curIsWord, prev == isWord, !ch.isWhitespace {
                cur.append(ch)
            } else {
                if !cur.isEmpty { tokens.append(cur) }
                cur = String(ch)
                curIsWord = ch.isWhitespace ? nil : isWord
            }
        }
        if !cur.isEmpty { tokens.append(cur) }
        return tokens
    }

    /// Extracts plain text from the diff for clipboard copy (`rune_kit::diff::copy`).
    public func copyableText(includeRemoved: Bool = false) -> String {
        var lines: [String] = []
        for hunk in hunks {
            for line in hunk.lines {
                if line.kind == .removed && !includeRemoved { continue }
                lines.append(line.content)
            }
        }
        return lines.joined(separator: "\n")
    }
}

public enum DiffStyle: Sendable, Hashable {
    case unified
    case split
}

extension Kit {
    /// Renders a `FileDiff` in unified or side-by-side split mode (`Kit::diff_view`).
    public func diffView<State>(
        key: String = "diff",
        _ diff: FileDiff,
        style: DiffStyle = .unified
    ) -> El<State> {
        let headerBar: El<State> = row()
            .wFull()
            .h(34)
            .px(12)
            .itemsCenter()
            .justifyBetween()
            .bg(c.layer01)
            .borderSides(bottom: 1.0, color: c.borderMuted)
            .child(text(diff.newPath).font(ty.mono).medium().color(c.textBase))
            .child(
                row().gap(8).itemsCenter()
                    .child(text("+\(diff.additionsCount)").font(ty.smallMedium).mono().color(c.success.fg))
                    .child(text("-\(diff.deletionsCount)").font(ty.smallMedium).mono().color(c.danger.fg))
            )

        var body: El<State> = col().wFull()
        let addBg = c.success.fg.alpha(dark ? 0.14 : 0.10)
        let remBg = c.danger.fg.alpha(dark ? 0.14 : 0.10)

        for (hIdx, hunk) in diff.hunks.enumerated() {
            body = body.child(
                row()
                    .wFull()
                    .px(12)
                    .py(4)
                    .bg(c.layer02)
                    .child(text(hunk.header).font(ty.small).mono().color(c.textFaint))
            )

            switch style {
            case .unified:
                for (lIdx, line) in hunk.lines.enumerated() {
                    let lineBg: Color
                    let prefixChar: String
                    let fgCol: Color
                    switch line.kind {
                    case .added:
                        lineBg = addBg; prefixChar = "+"; fgCol = c.success.fg
                    case .removed:
                        lineBg = remBg; prefixChar = "-"; fgCol = c.danger.fg
                    case .context:
                        lineBg = .transparent; prefixChar = " "; fgCol = c.textBase
                    }

                    let oldNumStr = line.oldLineNumber.map(String.init) ?? ""
                    let newNumStr = line.newLineNumber.map(String.init) ?? ""

                    body = body.child(
                        row()
                            .key("\(key)-\(hIdx)-\(lIdx)")
                            .wFull()
                            .px(10)
                            .py(2)
                            .gap(8)
                            .itemsCenter()
                            .bg(lineBg)
                            .child(text(oldNumStr).font(ty.mono).color(c.textFaint).w(28).textAlign(.trailing))
                            .child(text(newNumStr).font(ty.mono).color(c.textFaint).w(28).textAlign(.trailing))
                            .child(text(prefixChar).font(ty.mono).color(fgCol).w(10))
                            .child(text(line.content).font(ty.mono).color(fgCol).grow(1).noWrap())
                    )
                }

            case .split:
                // Pair consecutive removed + added runs side-by-side
                let lines = hunk.lines
                var idx = 0
                while idx < lines.count {
                    if lines[idx].kind == .context {
                        let ln = lines[idx]
                        body = body.child(splitRow(key: "\(key)-s-\(hIdx)-\(idx)", left: ln, right: ln, addBg: addBg, remBg: remBg))
                        idx += 1
                    } else {
                        var removed: [DiffLine] = []
                        var added: [DiffLine] = []
                        while idx < lines.count && lines[idx].kind == .removed {
                            removed.append(lines[idx])
                            idx += 1
                        }
                        while idx < lines.count && lines[idx].kind == .added {
                            added.append(lines[idx])
                            idx += 1
                        }
                        let pairCount = max(removed.count, added.count)
                        for p in 0..<pairCount {
                            let l = p < removed.count ? removed[p] : nil
                            let r = p < added.count ? added[p] : nil
                            body = body.child(splitRow(key: "\(key)-s-\(hIdx)-\(idx)-\(p)", left: l, right: r, addBg: addBg, remBg: remBg))
                        }
                    }
                }
            }
        }

        return col()
            .key(key)
            .wFull()
            .rounded(radius.lg)
            .bg(c.surfaceRaised)
            .border(1.0, c.borderBase)
            .clip(true)
            .child(headerBar)
            .child(body)
    }

    private func splitRow<State>(key: String, left: DiffLine?, right: DiffLine?, addBg: Color, remBg: Color) -> El<State> {
        func halfCell(_ line: DiffLine?, isLeft: Bool) -> El<State> {
            guard let line else {
                return row().grow(1).minW(0).px(8).py(2).bg(c.layer01.alpha(0.4))
            }
            let bgCol: Color = (line.kind == .added) ? addBg : (line.kind == .removed ? remBg : .transparent)
            let fgCol: Color = (line.kind == .added) ? c.success.fg : (line.kind == .removed ? c.danger.fg : c.textBase)
            let numStr = (isLeft ? line.oldLineNumber : line.newLineNumber).map(String.init) ?? ""
            return row()
                .grow(1)
                .minW(0)
                .px(8)
                .py(2)
                .gap(6)
                .itemsCenter()
                .bg(bgCol)
                .child(text(numStr).font(ty.mono).color(c.textFaint).w(26).textAlign(.trailing))
                .child(text(line.content).font(ty.mono).color(fgCol).grow(1).ellipsis())
        }

        return row()
            .key(key)
            .wFull()
            .child(halfCell(left, isLeft: true).borderSides(right: 1.0, color: c.borderMuted))
            .child(halfCell(right, isLeft: false))
    }
}
