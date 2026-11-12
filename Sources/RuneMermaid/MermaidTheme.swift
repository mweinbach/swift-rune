import Foundation
import Rune

/// Colors and typography used to draw a Mermaid diagram (`rune_mermaid::DiagramStyle`).
public struct MermaidTheme: Hashable, Sendable {
    public var text: Color
    public var muted: Color
    public var surface: Color
    public var surfaceBorder: Color
    public var nodeFill: Color
    public var nodeBorder: Color
    public var line: Color
    public var clusterFill: Color
    public var noteFill: Color
    public var noteBorder: Color
    public var font: TextStyle
    public var maxWidth: Float
    /// Minimum scale factor when shrinking a wide diagram to `maxWidth`.
    public internal(set) var minScale: Float

    public init(
        text: Color,
        muted: Color,
        surface: Color,
        surfaceBorder: Color,
        nodeFill: Color,
        nodeBorder: Color,
        line: Color,
        clusterFill: Color,
        noteFill: Color,
        noteBorder: Color,
        font: TextStyle = TextStyle(size: 13.0, weight: 400.0).lh(18.0),
        maxWidth: Float = 680.0,
        minScale: Float = 0.6
    ) {
        self.text = text
        self.muted = muted
        self.surface = surface
        self.surfaceBorder = surfaceBorder
        self.nodeFill = nodeFill
        self.nodeBorder = nodeBorder
        self.line = line
        self.clusterFill = clusterFill
        self.noteFill = noteFill
        self.noteBorder = noteBorder
        self.font = font
        self.maxWidth = maxWidth
        self.minScale = min(max(minScale, 0.0), 1.0)
    }

    /// Neutral light or dark colors derived from Rune's core tokens.
    public static func neutral(dark: Bool) -> MermaidTheme {
        let t = Tok.theme(dark: dark)
        return MermaidTheme(
            text: t.text,
            muted: t.textSecondary,
            surface: t.bg,
            surfaceBorder: t.separator,
            nodeFill: t.card,
            nodeBorder: t.text.alpha(0.2),
            line: t.text.alpha(0.42),
            clusterFill: t.text.alpha(dark ? 0.04 : 0.025),
            noteFill: oklcha(dark ? 0.3 : 0.95, 0.04, 80.0, 1.0),
            noteBorder: oklch(dark ? 0.4 : 0.85, 0.08, 80.0),
            font: TextStyle(size: 13.0, weight: 400.0).lh(18.0),
            maxWidth: 680.0,
            minScale: 0.6
        )
    }

    /// The least a diagram wider than `maxWidth` shrinks to (0.6 by default).
    /// `0.0` always fits the whole diagram in.
    public func minScale(_ k: Float) -> MermaidTheme {
        var copy = self
        copy.minScale = min(max(k, 0.0), 1.0)
        return copy
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(text)
        hasher.combine(muted)
        hasher.combine(surface)
        hasher.combine(surfaceBorder)
        hasher.combine(nodeFill)
        hasher.combine(nodeBorder)
        hasher.combine(line)
        hasher.combine(clusterFill)
        hasher.combine(noteFill)
        hasher.combine(noteBorder)
        hasher.combine(font)
        let bits: UInt32 = maxWidth == 0.0 ? 0 : (maxWidth.isNaN ? Float.nan.bitPattern : maxWidth.bitPattern)
        hasher.combine(bits)
        hasher.combine(minScale.bitPattern)
    }
}

/// Alias matching upstream `DiagramStyle`.
public typealias DiagramStyle = MermaidTheme

/// What hovering a flowchart, state, or class diagram node lights up.
public enum MermaidHover: Hashable, Sendable {
    /// Nothing.
    case off
    /// The edges in and out of it, with their labels.
    case edges
    /// Its edges, its outline, and the outlines of the nodes they reach.
    case neighbours
}

/// Alias matching upstream `Hover`.
public typealias Hover = MermaidHover

/// A diagram's title and drawing without its card, for a viewer that frames and scales it itself.
public struct MermaidDrawing<State> {
    public var el: El<State>
    public var size: Vec2
    public var surface: Color
    public var surfaceBorder: Color

    public init(el: El<State>, size: Vec2, surface: Color, surfaceBorder: Color) {
        self.el = el
        self.size = size
        self.surface = surface
        self.surfaceBorder = surfaceBorder
    }
}

// MARK: - Shared Limits & Label Cleaning

enum MermaidLimits {
    /// Diagrams bigger than this are left as source.
    static let maxItems = 400
    /// How deep subgraphs, composite states, frames, and other blocks may nest.
    static let maxDepth = 8
}

/// Strips one pair of surrounding `"..."` quotes (unescaping `\"`), then runs `clean`.
func cleanQuoted(_ s: String) -> String {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") {
        let inner = String(t.dropFirst().dropLast())
        return clean(inner.replacingOccurrences(of: "\\\"", with: "\""))
    }
    return clean(t)
}

/// Mermaid label markup to plain text: `<br>` and `\n` breaks, entity codes, markdown-string backticks.
func clean(_ s: String) -> String {
    var str = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if str.count >= 2, str.hasPrefix("`"), str.hasSuffix("`") {
        str = String(str.dropFirst().dropLast())
    }
    var out = ""
    out.reserveCapacity(str.count)
    var idx = str.startIndex
    while idx < str.endIndex {
        let ch = str[idx]
        if ch == "<" || ch == "#" || ch == "&" || ch == "\\" {
            let rest = str[idx...]
            let lower = rest.prefix(6).lowercased()
            if lower.hasPrefix("<br>") {
                out.append("\n")
                idx = str.index(idx, offsetBy: 4)
                continue
            } else if lower.hasPrefix("<br/>") {
                out.append("\n")
                idx = str.index(idx, offsetBy: 5)
                continue
            } else if lower.hasPrefix("<br />") {
                out.append("\n")
                idx = str.index(idx, offsetBy: 6)
                continue
            } else if rest.hasPrefix("\\n") {
                out.append("\n")
                idx = str.index(idx, offsetBy: 2)
                continue
            } else if rest.hasPrefix("#quot;") {
                out.append("\"")
                idx = str.index(idx, offsetBy: 6)
                continue
            } else if rest.hasPrefix("#59;") {
                out.append(";")
                idx = str.index(idx, offsetBy: 4)
                continue
            } else if rest.hasPrefix("#35;") {
                out.append("#")
                idx = str.index(idx, offsetBy: 4)
                continue
            } else if rest.hasPrefix("&amp;") {
                out.append("&")
                idx = str.index(idx, offsetBy: 5)
                continue
            } else if rest.hasPrefix("&lt;") {
                out.append("<")
                idx = str.index(idx, offsetBy: 4)
                continue
            } else if rest.hasPrefix("&gt;") {
                out.append(">")
                idx = str.index(idx, offsetBy: 4)
                continue
            } else if rest.hasPrefix("&quot;") {
                out.append("\"")
                idx = str.index(idx, offsetBy: 6)
                continue
            } else if rest.hasPrefix("&apos;") || rest.hasPrefix("#apos;") {
                out.append("'")
                idx = str.index(idx, offsetBy: 6)
                continue
            }
        }
        out.append(ch)
        idx = str.index(after: idx)
    }
    return out
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .joined(separator: "\n")
}

// MARK: - Node & Edge Styling

struct NodeStyle: Equatable {
    var fill: Color?
    var stroke: Color?
    var color: Color?
    var width: Float?

    static let `default` = NodeStyle()

    func merge(_ over: NodeStyle) -> NodeStyle {
        NodeStyle(
            fill: over.fill ?? fill,
            stroke: over.stroke ?? stroke,
            color: over.color ?? color,
            width: over.width ?? width
        )
    }

    func resolve(against paint: MermaidTheme) -> (fill: Color, border: Color, text: Color) {
        let resolvedFill = fill.map { adaptFill(base: paint.nodeFill, color: $0, darkLift: 0.055, lightDrop: 0.035) } ?? paint.nodeFill
        let dark = paint.nodeFill.toOKLab()[0] < 0.5
        let resolvedBorder = (stroke ?? fill).map { adaptStroke(base: paint.nodeBorder, color: $0, dark: dark) } ?? paint.nodeBorder
        let resolvedText: Color
        if let c = color, abs(c.toOKLab()[0] - resolvedFill.toOKLab()[0]) > 0.35 {
            resolvedText = c
        } else {
            resolvedText = paint.text
        }
        return (resolvedFill, resolvedBorder, resolvedText)
    }
}

struct EdgeStyle: Equatable {
    var stroke: Color?
    var width: Float?

    static let `default` = EdgeStyle()

    func merge(_ over: EdgeStyle) -> EdgeStyle {
        EdgeStyle(stroke: over.stroke ?? stroke, width: over.width ?? width)
    }
}

struct StyleSheet {
    private var defs: [String: NodeStyle] = [:]
    private var classes: [String: [String]] = [:]
    private var inline: [String: NodeStyle] = [:]

    @discardableResult
    mutating func classDef(_ rest: String) -> Bool {
        let trimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ws = trimmed.firstIndex(where: \.isWhitespace) else { return false }
        let names = trimmed[..<ws]
        let props = String(trimmed[ws...])
        let st = parseStyleProps(props)
        for name in names.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
            defs[name] = st
        }
        return true
    }

    @discardableResult
    mutating func assignClasses(_ rest: String) -> Bool {
        let trimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ws = trimmed.firstIndex(where: \.isWhitespace) else { return false }
        let targets = trimmed[..<ws]
        let classesPart = trimmed[ws...]
        let clsList = classesPart.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for id in targets.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
            for cls in clsList {
                addClass(id, cls)
            }
        }
        return true
    }

    @discardableResult
    mutating func style(_ rest: String) -> Bool {
        let trimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ws = trimmed.firstIndex(where: \.isWhitespace) else { return false }
        let targets = trimmed[..<ws]
        let props = String(trimmed[ws...])
        let st = parseStyleProps(props)
        for id in targets.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
            addStyle(id, st)
        }
        return true
    }

    mutating func addClass(_ id: String, _ cls: String) {
        guard !id.isEmpty && !cls.isEmpty else { return }
        classes[id, default: []].append(cls)
    }

    mutating func addStyle(_ id: String, _ st: NodeStyle) {
        guard !id.isEmpty else { return }
        let cur = inline[id] ?? .default
        inline[id] = cur.merge(st)
    }

    mutating func stripInline(_ raw: String) -> String? {
        if let range = raw.range(of: ":::") {
            let id = raw[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let cls = raw[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if id.isEmpty || cls.isEmpty { return nil }
            addClass(id, cls)
            return id
        }
        return raw.trimmingCharacters(in: .whitespaces)
    }

    func get(_ id: String) -> NodeStyle {
        var st = NodeStyle.default
        if let clsList = classes[id] {
            for cls in clsList {
                if let cs = defs[cls] {
                    st = st.merge(cs)
                }
            }
        }
        if let inl = inline[id] {
            st = st.merge(inl)
        }
        return st
    }
}

func adaptFill(base: Color, color c: Color, darkLift: Float, lightDrop: Float) -> Color {
    let baseL = base.toOKLab()[0]
    let dark = baseL < 0.5
    let lab = c.toOKLab()
    let a = lab[1], b = lab[2]
    let chroma = hypotf(a, b)
    if chroma < 0.01 {
        return oklabMix(base, c, 0.2)
    }
    let scale = min(max(chroma * 0.9, 0.032), 0.075) / chroma
    let l = dark ? min(baseL + darkLift, 0.42) : max(baseL - lightDrop, 0.82)
    return Color.fromOKLab([l, a * scale, b * scale, base.a])
}

func adaptStroke(base: Color, color c: Color, dark: Bool) -> Color {
    let lab = c.toOKLab()
    let a = lab[1], b = lab[2]
    let chroma = hypotf(a, b)
    if chroma < 0.01 {
        return oklabMix(base, c, 0.35)
    }
    let scale = min(max(chroma * 1.1, 0.07), 0.13) / chroma
    return Color.fromOKLab([dark ? 0.58 : 0.60, a * scale, b * scale, 1.0])
}

func oklabMix(_ a: Color, _ b: Color, _ t: Float) -> Color {
    let la = a.toOKLab()
    let lb = b.toOKLab()
    return Color.fromOKLab([
        la[0] + (lb[0] - la[0]) * t,
        la[1] + (lb[1] - la[1]) * t,
        la[2] + (lb[2] - la[2]) * t,
        la[3],
    ])
}

func parseStyleProps(_ props: String) -> NodeStyle {
    var out = NodeStyle.default
    for part in props.split(whereSeparator: { $0 == "," || $0 == ";" }) {
        guard let colon = part.firstIndex(of: ":") else { continue }
        let k = part[..<colon].trimmingCharacters(in: .whitespaces)
        var v = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if v.hasSuffix("!important") {
            v = String(v.dropLast("!important".count)).trimmingCharacters(in: .whitespaces)
        }
        switch k {
        case "fill": out.fill = parseColorSpec(v)
        case "stroke": out.stroke = parseColorSpec(v)
        case "color": out.color = parseColorSpec(v)
        case "stroke-width":
            if let w = parsePx(v) {
                out.width = min(max(w, 0.0), 5.0)
            }
        default: break
        }
    }
    return out
}

func parseEdgeStyleProps(_ props: String) -> EdgeStyle {
    var out = EdgeStyle.default
    for part in props.split(whereSeparator: { $0 == "," || $0 == ";" }) {
        guard let colon = part.firstIndex(of: ":") else { continue }
        let k = part[..<colon].trimmingCharacters(in: .whitespaces)
        var v = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if v.hasSuffix("!important") {
            v = String(v.dropLast("!important".count)).trimmingCharacters(in: .whitespaces)
        }
        switch k {
        case "stroke": out.stroke = parseColorSpec(v)
        case "stroke-width":
            if let w = parsePx(v) {
                out.width = min(max(w, 0.75), 5.0)
            }
        default: break
        }
    }
    return out
}

private func parsePx(_ v: String) -> Float? {
    var s = v
    if s.hasSuffix("px") {
        s = String(s.dropLast(2))
    }
    s = s.trimmingCharacters(in: .whitespaces)
    guard let w = Float(s), w.isFinite else { return nil }
    return w
}

func parseColorSpec(_ s: String) -> Color? {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if let c = Color.hex(trimmed) {
        return c
    }
    let lower = trimmed.lowercased()
    if (lower.hasPrefix("rgb(") || lower.hasPrefix("rgba(")) && lower.hasSuffix(")") {
        let inner: String
        if lower.hasPrefix("rgba(") {
            inner = String(lower.dropFirst(5).dropLast())
        } else {
            inner = String(lower.dropFirst(4).dropLast())
        }
        let nums = inner.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        if nums.count >= 3 {
            let r = RefShader.srgbToLinear(min(max(nums[0] / 255.0, 0.0), 1.0))
            let g = RefShader.srgbToLinear(min(max(nums[1] / 255.0, 0.0), 1.0))
            let b = RefShader.srgbToLinear(min(max(nums[2] / 255.0, 0.0), 1.0))
            let a = nums.count >= 4 ? min(max(nums[3], 0.0), 1.0) : 1.0
            return Color(r: r, g: g, b: b, a: a)
        }
    }
    let hex: String? = switch lower {
    case "red", "crimson", "salmon", "lightcoral", "pink": "#ef4444"
    case "green", "lightgreen", "palegreen", "emerald", "lime": "#22c55e"
    case "blue", "lightblue", "skyblue", "dodgerblue": "#3b82f6"
    case "yellow", "lightyellow", "gold", "amber", "orange": "#eab308"
    case "purple", "violet", "lavender", "magenta": "#a855f7"
    case "cyan", "aqua", "teal", "turquoise": "#06b6d4"
    case "gray", "grey", "lightgray", "lightgrey", "silver": "#9ca3af"
    default: nil
    }
    return hex.flatMap { Color.hex($0) }
}

// MARK: - Lexing & Statement Splitting

/// What follows keyword `w` and a space (or end of string), trimmed.
func word(_ l: String, _ w: String) -> String? {
    guard l.hasPrefix(w) else { return nil }
    let rest = l.dropFirst(w.count)
    guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
    return rest.trimmingCharacters(in: .whitespaces)
}

/// Splits a line at `;` outside quotes and brackets (and never at an HTML entity's `;`).
func statements(_ line: String) -> [String] {
    var out: [String] = []
    var start = line.startIndex
    var quoted = false
    var escaped = false
    var brackets = 0

    var idx = line.startIndex
    while idx < line.endIndex {
        let c = line[idx]
        if escaped {
            escaped = false
        } else if quoted {
            if c == "\\" { escaped = true }
            else if c == "\"" { quoted = false }
        } else {
            switch c {
            case "\"":
                quoted = true
            case "[", "(", "{":
                brackets += 1
            case "]", ")", "}":
                brackets = max(0, brackets - 1)
            case ";" where brackets == 0:
                out.append(String(line[start..<idx]))
                start = line.index(after: idx)
            default:
                break
            }
        }
        idx = line.index(after: idx)
    }
    out.append(String(line[start...]))
    return out
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("%%") }
}

/// Character cursor over one statement (`Cur` in upstream).
struct StringScanner {
    let s: String
    var i: String.Index

    init(_ s: String) {
        self.s = s
        self.i = s.startIndex
    }

    var rest: Substring { s[i...] }
    var done: Bool { i >= s.endIndex }

    func peek() -> Character? {
        done ? nil : s[i]
    }

    func peek2() -> Character? {
        guard !done else { return nil }
        let next = s.index(after: i)
        return next < s.endIndex ? s[next] : nil
    }

    mutating func bump() {
        if !done {
            i = s.index(after: i)
        }
    }

    mutating func eat(_ token: String) -> Bool {
        if rest.hasPrefix(token) {
            i = s.index(i, offsetBy: token.count)
            return true
        }
        return false
    }

    mutating func skipWS() {
        while let c = peek(), c.isWhitespace {
            bump()
        }
    }
}
