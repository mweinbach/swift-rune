import Foundation
import Rune

/// One `{status} Title · note` row inside a ```` ```steps ```` fence (`rune_kit::notes::StepRow`).
public struct NoteStepRow: Sendable, Equatable {
    public var status: String
    public var title: String
    public var note: String?

    public init(status: String, title: String, note: String? = nil) {
        self.status = status
        self.title = title
        self.note = note
    }
}

/// Parsed diffstat breakdown inside a ```` ```size ```` fence (`rune_kit::notes::SizeBar`).
public struct NoteSizeBar: Sendable, Equatable {
    public var parts: [(name: String, additions: Int, deletions: Int)]
    public var files: String?

    public init(parts: [(name: String, additions: Int, deletions: Int)], files: String? = nil) {
        self.parts = parts
        self.files = files
    }

    public static func == (lhs: NoteSizeBar, rhs: NoteSizeBar) -> Bool {
        lhs.files == rhs.files &&
        lhs.parts.count == rhs.parts.count &&
        zip(lhs.parts, rhs.parts).allSatisfy { a, b in
            a.name == b.name && a.additions == b.additions && a.deletions == b.deletions
        }
    }
}

/// A parsed piece of a structured note (`rune_kit::notes::Piece`).
public enum NotePiece: Sendable, Equatable {
    case markdown(String)
    case facts([(label: String, value: String)])
    case compare([(label: String, value: String)])
    case steps([NoteStepRow])
    case size(NoteSizeBar)
    case codeFence(title: String?, marks: [ClosedRange<Int>], lines: [String])
    case callout(label: String?, body: String)

    public static func == (lhs: NotePiece, rhs: NotePiece) -> Bool {
        switch (lhs, rhs) {
        case (.markdown(let a), .markdown(let b)):
            return a == b
        case (.facts(let a), .facts(let b)), (.compare(let a), .compare(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.label == $1.label && $0.value == $1.value }
        case (.steps(let a), .steps(let b)):
            return a == b
        case (.size(let a), .size(let b)):
            return a == b
        case (.codeFence(let t1, let m1, let l1), .codeFence(let t2, let m2, let l2)):
            return t1 == t2 && m1 == m2 && l1 == l2
        case (.callout(let l1, let b1), .callout(let l2, let b2)):
            return l1 == l2 && b1 == b2
        default:
            return false
        }
    }
}

/// Parser for structured Markdown notes (`facts`, `compare`, `steps`, `size`, titled/marked code fences, `> [!note]` callouts).
public enum NoteParser {
    public static func parse(_ source: String) -> [NotePiece] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var out: [NotePiece] = []
        var md: [String] = []

        func flushMD() {
            let joined = md.joined(separator: "\n").trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(.markdown(joined))
            }
            md.removeAll(keepingCapacity: true)
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.drop(while: \.isWhitespace)
            let indent = line.count - trimmed.count

            // Callout: `> [!note]` / `> [!warning]` / `> [!tip]`
            if indent < 4, trimmed.hasPrefix(">") {
                let afterGT = trimmed.dropFirst().drop(while: \.isWhitespace)
                if afterGT.hasPrefix("[!"), let close = afterGT.firstIndex(of: "]") {
                    let rawLabel = String(afterGT[afterGT.index(afterGT.startIndex, offsetBy: 2)..<close])
                        .trimmingCharacters(in: .whitespaces)
                    let label = (!rawLabel.isEmpty && rawLabel.lowercased() != "note") ? rawLabel : nil
                    var bodyLines: [String] = []
                    let tail = String(afterGT[afterGT.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                    if !tail.isEmpty { bodyLines.append(tail) }
                    i += 1
                    while i < lines.count {
                        let next = lines[i].drop(while: \.isWhitespace)
                        if next.hasPrefix(">") {
                            var content = String(next.dropFirst())
                            if content.hasPrefix(" ") { content.removeFirst() }
                            bodyLines.append(content)
                            i += 1
                        } else {
                            break
                        }
                    }
                    flushMD()
                    out.append(.callout(label: label, body: bodyLines.joined(separator: "\n")))
                    continue
                }
            }

            // Special fenced blocks
            if indent < 4, (trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")) {
                let ch = trimmed.first!
                let ticks = trimmed.prefix(while: { $0 == ch }).count
                let infoRaw = String(trimmed.dropFirst(ticks)).trimmingCharacters(in: .whitespaces)
                let tag = infoRaw.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
                let closingFence = String(repeating: ch, count: ticks)
                if let end = ((i + 1)..<lines.count).first(where: { j in
                    let u = lines[j].drop(while: \.isWhitespace)
                    return u.hasPrefix(closingFence) && u.dropFirst(ticks).allSatisfy({ $0 == ch || $0.isWhitespace })
                }) {
                    let body = Array(lines[(i + 1)..<end])
                    var special: NotePiece?
                    switch tag {
                    case "facts", "kv", "stats", "stat":
                        special = .facts(parsePairs(body))
                    case "compare", "before-after":
                        special = .compare(parsePairs(body))
                    case "steps", "status":
                        special = .steps(parseSteps(body))
                    case "size":
                        special = .size(parseSize(body))
                    default:
                        if infoRaw.contains("title=") || infoRaw.contains("{") {
                            let (title, marks) = parseCodeMeta(infoRaw)
                            special = .codeFence(title: title, marks: marks, lines: body)
                        }
                    }
                    if let special {
                        flushMD()
                        out.append(special)
                        i = end + 1
                        continue
                    }
                }
            }

            md.append(line)
            i += 1
        }
        flushMD()
        return out
    }

    private static func stripDashPrefixes(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("- ") {
            s = String(s.dropFirst(2))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parsePairs(_ lines: [String]) -> [(label: String, value: String)] {
        var out: [(label: String, value: String)] = []
        for raw in lines {
            let line = stripDashPrefixes(raw)
            guard !line.isEmpty else { continue }
            if let colon = line.firstIndex(of: ":") {
                let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                out.append((k, v))
            } else if !out.isEmpty {
                out[out.count - 1].value += " " + line
            }
        }
        return out
    }

    private static func parseSteps(_ lines: [String]) -> [NoteStepRow] {
        var out: [NoteStepRow] = []
        for raw in lines {
            var s = stripDashPrefixes(raw)
            guard !s.isEmpty else { continue }
            var status = "proposed"
            if s.hasPrefix("{"), let end = s.firstIndex(of: "}") {
                status = String(s[s.index(after: s.startIndex)..<end]).trimmingCharacters(in: .whitespaces)
                s = String(s[s.index(after: end)...]).trimmingCharacters(in: .whitespaces)
            }
            if let sep = s.range(of: " · ") {
                let title = String(s[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
                let note = String(s[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
                out.append(NoteStepRow(status: status, title: title, note: note))
            } else {
                out.append(NoteStepRow(status: status, title: s, note: nil))
            }
        }
        return out
    }

    private static func parseSize(_ lines: [String]) -> NoteSizeBar {
        let joined = lines.joined(separator: " ")
        var parts: [(name: String, additions: Int, deletions: Int)] = []
        var files: String?
        for chunk in joined.components(separatedBy: " · ") {
            let trimmed = chunk.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasSuffix("files") || trimmed.hasSuffix("file") {
                files = trimmed
                continue
            }
            let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let name = tokens.first else { continue }
            var adds = 0
            var dels = 0
            for tok in tokens.dropFirst() {
                if tok.hasPrefix("+") {
                    adds = Int(tok.dropFirst().replacingOccurrences(of: ",", with: "")) ?? 0
                } else if tok.hasPrefix("−") || tok.hasPrefix("-") {
                    dels = Int(tok.dropFirst().replacingOccurrences(of: ",", with: "")) ?? 0
                }
            }
            parts.append((name: name, additions: adds, deletions: dels))
        }
        return NoteSizeBar(parts: parts, files: files)
    }

    private static func parseCodeMeta(_ info: String) -> (String?, [ClosedRange<Int>]) {
        var title: String?
        if let start = info.range(of: "title=\"") {
            let rest = info[start.upperBound...]
            if let end = rest.firstIndex(of: "\"") {
                title = String(rest[..<end])
            }
        }
        var marks: [ClosedRange<Int>] = []
        if let open = info.lastIndex(of: "{"),
           let close = info[open...].firstIndex(of: "}") {
            let inner = info[info.index(after: open)..<close]
            for spec in inner.split(separator: ",") {
                let t = spec.trimmingCharacters(in: .whitespaces)
                if let dash = t.firstIndex(of: "-") {
                    if let lo = Int(t[..<dash].trimmingCharacters(in: .whitespaces)),
                       let hi = Int(t[t.index(after: dash)...].trimmingCharacters(in: .whitespaces)),
                       lo <= hi {
                        marks.append(lo...hi)
                    }
                } else if let line = Int(t) {
                    marks.append(line...line)
                }
            }
        }
        return (title, marks)
    }
}

extension Kit {
    /// Renders a structured Markdown note (`facts`, `compare`, `steps`, `size`, titled/marked code fences, `> [!note]` callouts).
    public func note<State>(
        _ source: String,
        key: String = "note",
        gap: Float = 12
    ) -> El<State> {
        let pieces = NoteParser.parse(source)
        var root: El<State> = col().key(key).wFull().gap(gap)
        for (idx, piece) in pieces.enumerated() {
            let pKey = "\(key)/p\(idx)"
            switch piece {
            case .markdown(let md):
                root = root.child(markdown(md, key: pKey))
            case .facts(let rows):
                root = root.child(drawNoteFacts(key: pKey, rows: rows))
            case .compare(let sides):
                root = root.child(drawNoteCompare(key: pKey, sides: sides))
            case .steps(let steps):
                root = root.child(drawNoteSteps(key: pKey, steps: steps))
            case .size(let bar):
                root = root.child(drawNoteSize(key: pKey, sizeBar: bar))
            case let .codeFence(title, marks, lines):
                root = root.child(drawNoteCode(key: pKey, title: title, marks: marks, lines: lines))
            case let .callout(label, body):
                root = root.child(drawNoteCallout(key: pKey, label: label, body: body))
            }
        }
        return root
    }

    private func noteStatusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "built", "done", "shipped", "merged", "verified", "green", "good":
            return c.success.fg
        case "risk", "blocked", "failed", "red", "bad", "error":
            return c.danger.fg
        case "proposal", "proposed", "warn", "warning", "hold":
            return c.warning.fg
        case "working", "on a branch", "in flight":
            return c.info.fg
        default:
            return c.textMuted
        }
    }

    private func splitLeadingStatus(_ value: String) -> (String?, String) {
        let s = value.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("{"), let end = s.firstIndex(of: "}") {
            let st = String(s[s.index(after: s.startIndex)..<end]).trimmingCharacters(in: .whitespaces)
            let rest = String(s[s.index(after: end)...]).trimmingCharacters(in: .whitespaces)
            return (st, rest)
        }
        return (nil, s)
    }

    private func drawNoteFacts<State>(key: String, rows: [(label: String, value: String)]) -> El<State> {
        var list: El<State> = col()
            .key(key)
            .role(.group)
            .label("facts")
            .wFull()
            .rounded(8)
            .bg(c.layer02)
            .border(1.0, c.borderWeak)
            .px(14)
            .py(6)

        for (idx, item) in rows.enumerated() {
            if idx > 0 {
                list = list.child(el().wFull().h(1).bg(c.borderWeak))
            }
            let (st, rest) = splitLeadingStatus(item.value)
            var right: El<State> = row().gap(6).itemsCenter()
            if let st {
                let tone = noteStatusColor(st)
                right = right
                    .child(el().size(7).rounded(3.5).bg(tone))
                    .child(text(st).font(ty.smallMedium).color(tone))
            }
            if !rest.isEmpty {
                right = right.child(text(rest).font(ty.textSmall).color(c.textBase))
            }
            let valueSummary = [st, rest.isEmpty ? nil : rest].compactMap { $0 }.joined(separator: " ")
            let rowLabel = valueSummary.isEmpty ? item.label : "\(item.label): \(valueSummary)"
            list = list.child(
                row()
                    .key("\(key)-fact-\(idx)")
                    .role(.listItem)
                    .label(rowLabel)
                    .positionInSet(idx + 1, size: rows.count)
                    .wFull()
                    .py(7)
                    .itemsCenter()
                    .justifyBetween()
                    .gap(16)
                    .child(text(item.label.uppercased()).font(ty.smallMedium).color(c.textMuted).a11yHidden())
                    .child(right.a11yHidden())
            )
        }
        return list
    }

    private func drawNoteCompare<State>(key: String, sides: [(label: String, value: String)]) -> El<State> {
        var container: El<State> = row().key(key).wFull().gap(10)
        for (idx, side) in sides.enumerated() {
            container = container.child(
                col()
                    .key("\(key)-side-\(idx)")
                    .grow(1)
                    .minW(0)
                    .p(12)
                    .gap(4)
                    .rounded(8)
                    .bg(c.layer02)
                    .border(1.0, c.borderWeak)
                    .child(text(side.label.uppercased()).font(ty.smallMedium).color(c.textMuted))
                    .child(text(side.value).font(ty.body).color(c.textBase))
            )
        }
        return container
    }

    private func drawNoteSteps<State>(key: String, steps: [NoteStepRow]) -> El<State> {
        let doneCount = steps.filter {
            ["built", "done", "shipped", "merged", "verified"].contains($0.status.lowercased())
        }.count
        var list: El<State> = col()
            .key(key)
            .role(.group)
            .label("\(doneCount) of \(steps.count) built")
            .wFull()
            .rounded(8)
            .bg(c.layer02)
            .border(1.0, c.borderWeak)
            .px(14)
            .py(6)

        for (idx, step) in steps.enumerated() {
            if idx > 0 {
                list = list.child(el().wFull().h(1).bg(c.borderWeak))
            }
            let tone = noteStatusColor(step.status)
            var left: El<State> = row().gap(8).itemsCenter().grow(1).minW(0)
                .child(el().size(7).rounded(3.5).bg(tone))
                .child(text(step.title).font(ty.uiMedium).color(c.textBase).a11yHidden())
            if let note = step.note {
                left = left.child(text(note).font(ty.small).color(c.textMuted).a11yHidden())
            }
            let stepLabel = [step.title, step.status, step.note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            list = list.child(
                row()
                    .key("\(key)-step-\(idx)")
                    .role(.listItem)
                    .label(stepLabel)
                    .positionInSet(idx + 1, size: steps.count)
                    .wFull()
                    .py(7)
                    .itemsCenter()
                    .justifyBetween()
                    .gap(12)
                    .child(left)
                    .child(text(step.status).font(ty.smallMedium).color(tone).a11yHidden())
            )
        }
        return list
    }

    private func drawNoteSize<State>(key: String, sizeBar: NoteSizeBar) -> El<State> {
        let totalAdds = sizeBar.parts.reduce(0) { $0 + max(0, $1.additions) }
        let totalDels = sizeBar.parts.reduce(0) { $0 + max(0, $1.deletions) }
        let total = max(1, totalAdds + totalDels)
        let addFrac = Float(totalAdds) / Float(total)
        let delFrac = Float(totalDels) / Float(total)

        var header: El<State> = row().wFull().justifyBetween().itemsCenter()
            .child(text("+\(totalAdds)  -\(totalDels)").font(ty.smallMedium).color(c.textBase))
        if let files = sizeBar.files {
            header = header.child(text(files).font(ty.small).color(c.textMuted))
        }

        let bar: El<State> = row()
            .wFull()
            .h(6)
            .rounded(999)
            .bg(c.surfaceBase)
            .clip(true)
            .child(el().hFull().wFrac(addFrac).bg(c.success.icon))
            .child(el().hFull().wFrac(delFrac).bg(c.danger.icon))

        return col()
            .key(key)
            .wFull()
            .p(12)
            .gap(8)
            .rounded(8)
            .bg(c.layer02)
            .border(1.0, c.borderWeak)
            .child(header)
            .child(bar)
    }

    private func drawNoteCode<State>(
        key: String,
        title: String?,
        marks: [ClosedRange<Int>],
        lines: [String]
    ) -> El<State> {
        var selection = LineSelection()
        for r in marks {
            for line in r { selection.toggle(line) }
        }
        return codeBlock(
            key: key,
            code: lines.joined(separator: "\n"),
            language: title.flatMap { Syntax.langForPath($0) },
            showLineNumbers: true,
            lineSelection: selection.isEmpty ? nil : selection
        )
    }

    private func drawNoteCallout<State>(key: String, label: String?, body: String) -> El<State> {
        var content: El<State> = col().wFull().gap(4)
        if let label {
            content = content.child(text(label.uppercased()).font(ty.smallMedium).color(c.info.fg).a11yHidden())
        }
        content = content.child(markdown(body, key: "\(key)-md"))
        return row()
            .key(key)
            .role(.group)
            .label(label ?? "note")
            .wFull()
            .p(12)
            .rounded(8)
            .bg(c.info.bg)
            .borderSides(left: 3.0, color: c.info.border)
            .child(content)
    }
}
