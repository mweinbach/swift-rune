import Foundation
import Rune

/// Small shared UI parts for `RuneWww` (`www/app/src/ui.rs`).
public enum WwwUI {
    public enum ButtonKind: Equatable, Sendable {
        case github
        case primary
        case secondary
    }

    public static func hairline(_ key: String) -> El<WwwState> {
        el().key(key).wFull().h(1.0).bg(WwwTokens.line).a11yHidden()
    }

    /// Splits `s` on backticks and styles code spans in mono 13 at full foreground ink.
    public static func prose(
        _ key: String,
        _ s: String,
        style: TextStyle,
        color: Color
    ) -> El<WwwState> {
        var content = ""
        content.reserveCapacity(s.utf8.count)
        var spans: [RichSpan] = []
        for (i, piece) in s.split(separator: "`", omittingEmptySubsequences: false).enumerated() {
            let at = content.utf8.count
            content.append(contentsOf: piece)
            if i % 2 == 1 {
                spans.append(RichSpan(at..<content.utf8.count).mono().size(13.0).color(WwwTokens.fg))
            }
        }
        return rich(content, spans)
            .key(key)
            .font(style)
            .color(color)
            .wrap(.wrap)
            .selectable(true)
    }

    public static func intro(_ key: String, _ s: String) -> El<WwwState> {
        prose(key, s, style: WwwTokens.text16, color: WwwTokens.fg2)
            .maxW(WwwTokens.measureWidth)
            .mt(16.0)
    }

    public static func button(
        _ key: String,
        _ label: String,
        href: String,
        kind: ButtonKind
    ) -> El<WwwState> {
        let primary = kind != .secondary
        let fill = primary ? WwwTokens.fg : WwwTokens.surface2
        let hover = primary ? Color.white : Color.white.alpha(0.04)
        let ink = primary ? Color.black : WwwTokens.fg
        var b: El<WwwState> = row()
            .key(key)
            .href(href)
            .h(40.0)
            .px(16.0)
            .gap(8.0)
            .centerY()
            .rounded(20.0)
            .bg(fill)
            .hover(hover)
            .pressScale(0.98)
        if kind == .github {
            b = b.child(githubMark(Color.black))
        }
        if !primary {
            b = b.border(1.0, WwwTokens.line)
        }
        return b.child(text(label).font(WwwTokens.text14Medium).color(ink))
    }

    /// Parses `[label](url)` markdown links into rich text spans + `TextLink` hit regions.
    public static func linked(
        _ key: String,
        _ s: String,
        style: TextStyle,
        color: Color
    ) -> El<WwwState> {
        var content = ""
        content.reserveCapacity(s.utf8.count)
        var links: [(Range<Int>, String)] = []
        var rest = s[...]
        while let openIdx = rest.firstIndex(of: "[") {
            let afterOpen = rest[openIdx...]
            guard let midRange = afterOpen.range(of: "]("),
                  let closeIdx = afterOpen[midRange.upperBound...].firstIndex(of: ")") else {
                break
            }
            content.append(contentsOf: rest[..<openIdx])
            let at = content.utf8.count
            let label = rest[rest.index(after: openIdx)..<midRange.lowerBound]
            content.append(contentsOf: label)
            let url = String(afterOpen[midRange.upperBound..<closeIdx])
            links.append((at..<content.utf8.count, url))
            rest = rest[rest.index(after: closeIdx)...]
        }
        content.append(contentsOf: rest)

        let spans = links.map { RichSpan($0.0).color(WwwTokens.fg) }
        var t: El<WwwState> = rich(content, spans)
            .key(key)
            .font(style)
            .color(color)
            .wrap(.wrap)
            .selectable(true)
        for (range, url) in links {
            t = t.link(TextLink(range, id: url).hover(LinkPaint().underline(true)))
        }
        return t.onLink { _, url, tx in
            _ = try? tx.openUrl(url)
        }
    }

    public static func navLink(
        _ key: String,
        _ label: String,
        href: String,
        style: TextStyle
    ) -> El<WwwState> {
        row()
            .key(key)
            .href(href)
            .hoverGroup()
            .child(text(label).font(style).color(WwwTokens.fg2).groupColor(WwwTokens.fg))
    }

    public static func githubMark(_ color: Color) -> El<WwwState> {
        canvas(Shape().viewBox(16.0, 16.0).fillPath(markPath(), color: color))
            .key("mark")
            .size(16.0, 16.0)
            .a11yHidden()
    }

    private static func markPath() -> Path {
        svgPath("M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8")
    }

    private static func numbers(_ s: Substring) -> [Float] {
        var out: [Float] = []
        var cur = ""
        func flush() {
            if let v = Float(cur) {
                out.append(v)
            }
            cur.removeAll(keepingCapacity: true)
        }
        for c in s {
            switch c {
            case "0"..."9":
                cur.append(c)
            case "." where cur.contains("."):
                flush()
                cur.append(c)
            case ".":
                cur.append(c)
            case "-":
                flush()
                cur.append(c)
            default:
                flush()
            }
        }
        flush()
        return out
    }

    public static func svgPath(_ d: String) -> Path {
        var path = Path()
        var at = Vec2(0, 0)
        var start = at
        var ctrl = at
        var cmds: [String] = []
        var piece = ""
        for c in d {
            if c.isASCII && c.isLetter, !piece.isEmpty {
                cmds.append(piece)
                piece.removeAll(keepingCapacity: true)
            }
            piece.append(c)
        }
        if !piece.isEmpty {
            cmds.append(piece)
        }

        for cmd in cmds {
            guard let op = cmd.first else { continue }
            let n = numbers(cmd.dropFirst())
            let rel = op.isLowercase
            func off(_ p: Vec2) -> Vec2 {
                rel ? Vec2(p.x + at.x, p.y + at.y) : p
            }
            switch op.uppercased() {
            case "M":
                var i = 0
                while i + 1 < n.count {
                    at = off(Vec2(n[i], n[i + 1]))
                    if i == 0 {
                        path = path.moveTo(at)
                        start = at
                    } else {
                        path = path.lineTo(at)
                    }
                    i += 2
                }
                ctrl = at
            case "L":
                var i = 0
                while i + 1 < n.count {
                    at = off(Vec2(n[i], n[i + 1]))
                    path = path.lineTo(at)
                    i += 2
                }
                ctrl = at
            case "C":
                var i = 0
                while i + 5 < n.count {
                    let c1 = off(Vec2(n[i], n[i + 1]))
                    let c2 = off(Vec2(n[i + 2], n[i + 3]))
                    let end = off(Vec2(n[i + 4], n[i + 5]))
                    path = path.cubicTo(c1, c2, end)
                    ctrl = c2
                    at = end
                    i += 6
                }
            case "S":
                var i = 0
                while i + 3 < n.count {
                    let c1 = Vec2(2.0 * at.x - ctrl.x, 2.0 * at.y - ctrl.y)
                    let c2 = off(Vec2(n[i], n[i + 1]))
                    let end = off(Vec2(n[i + 2], n[i + 3]))
                    path = path.cubicTo(c1, c2, end)
                    ctrl = c2
                    at = end
                    i += 4
                }
            case "A":
                var i = 0
                while i + 6 < n.count {
                    let end = off(Vec2(n[i + 5], n[i + 6]))
                    let corner = Vec2(end.x, at.y)
                    path = path.quadTo(corner, end)
                    at = end
                    ctrl = at
                    i += 7
                }
            case "Z":
                path = path.close()
                at = start
                ctrl = at
            default:
                break
            }
        }
        return path
    }

    public static func shapeDot(center: Vec2, radius: Float, color: Color, onto shape: Shape) -> Shape {
        let pts: [Vec2] = (0..<12).map { i in
            let a = Float(i) / 12.0 * (2.0 * Float.pi)
            return Vec2(center.x + radius * cosf(a), center.y + radius * sinf(a))
        }
        return shape.fill(pts, color: color)
    }
}
