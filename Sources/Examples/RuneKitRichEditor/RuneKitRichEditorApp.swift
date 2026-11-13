import Foundation
import Rune
import RuneKit

private let filePillIcon = SVGIcon(
    viewBox: 16.0,
    paths: ["M4 2.5H9.5L12.5 5.5V13.5H4V2.5Z M9.5 2.5V5.5H12.5"],
    strokeWidth: 1.25,
    body: #"<path d="M4 2.5H9.5L12.5 5.5V13.5H4V2.5Z M9.5 2.5V5.5H12.5" stroke="currentColor" stroke-linejoin="round" fill="none"/>"#
)

private let agentPillIcon = SVGIcon(
    viewBox: 16.0,
    paths: [
        "M8 8C9.38 8 10.5 6.88 10.5 5.5C10.5 4.12 9.38 3 8 3C6.62 3 5.5 4.12 5.5 5.5C5.5 6.88 6.62 8 8 8Z",
        "M3 13.5C3 11.29 5.24 9.5 8 9.5C10.76 9.5 13 11.29 13 13.5",
    ],
    strokeWidth: 1.25,
    body: #"<path d="M8 8C9.38 8 10.5 6.88 10.5 5.5C10.5 4.12 9.38 3 8 3C6.62 3 5.5 4.12 5.5 5.5C5.5 6.88 6.62 8 8 8Z M3 13.5C3 11.29 5.24 9.5 8 9.5C10.76 9.5 13 11.29 13 13.5" stroke="currentColor" stroke-linecap="round" fill="none"/>"#
)

public struct RichEditorState: Sendable {
    public var edit: TextEdit
    /// Pill IDs that name an agent rather than a file.
    public var agents: [String]

    public init() {
        let html = "<p>Ship the <b>attributed</b> composer with <i>inline marks</i>, "
            + "<u>underline</u>, <del>legacy markdown</del>, <code>Span</code> "
            + "decorations, and <a href=\"https://opencode.ai\">opencode.ai</a>. Ask "
            + "<span data-pill=\"agent:review\">@review</span> to check "
            + "<span data-pill=\"file:crates/rune/src/edit.rs\">edit.rs</span>.</p>"
            + "<ul>"
            + "<li>Byte-range marks shift and split on edits"
            + "<ul><li>Nested list items indent with <code>Tab</code></li></ul>"
            + "</li>"
            + "</ul>"
            + "<ol><li>Paste safe HTML or plain text</li><li>Export marks and blocks</li></ol>"
            + "<blockquote>Formatting lives alongside the string, never inside it.</blockquote>"
            + "<pre><code>fn count(lang: &amp;str, src: &amp;str) -&gt; usize {\n"
            + "\tlet spans = highlight(Some(lang), src);\n"
            + "\tspans.len()\n"
            + "}</code></pre>"
        var edit = TextEdit.fromHTML(html)
        // Place the caret at the end of "attributed" so the Bold button shows active.
        edit.setCursor(utf8Offset: 19, extendSelection: false)
        self.edit = edit
        self.agents = ["agent:review"]
    }
}

/// A mention pill's look by its ID: agents get accent color & person glyph, files get layer03 & page glyph.
private func makePillStyleResolver(_ k: Kit, agents: [String]) -> (String) -> PillStyle {
    let agentBg = k.c.textAccent.alpha(0.22)
    let agentFg = k.c.textAccent
    let fileBg = k.c.layer03
    return { id in
        if agents.contains(id) {
            return PillStyle.default.bg(agentBg).fg(agentFg).icon(agentPillIcon)
        }
        return PillStyle.default.bg(fileBg).icon(filePillIcon)
    }
}

/// Turn the `@query` typed before the caret into a file pill, or insert one at the caret.
public func insertRichMention(_ edit: inout TextEdit) {
    let range = edit.selectedUTF8Range
    let a = range.lowerBound
    let b = range.upperBound
    var queryStart: Int? = nil
    if a == b, a > 0 {
        let utf8 = edit.text.utf8
        if let endIdx = utf8.index(utf8.startIndex, offsetBy: a, limitedBy: utf8.endIndex) {
            let prefix = String(decoding: utf8[utf8.startIndex..<endIdx], as: UTF8.self)
            if let atIndex = prefix.lastIndex(of: "@") {
                let tail = prefix[atIndex...]
                if !tail.contains(where: \.isWhitespace) {
                    queryStart = prefix[..<atIndex].utf8.count
                }
            }
        }
    }
    edit.undoGroup { e in
        e.replaceWithPill(range: (queryStart ?? a)..<b, id: "file:crates/rune/src/text.rs", label: "text.rs")
        e.insert(" ")
    }
}

/// Syntax-highlight every `.code` paragraph run using `Syntax.builtin`.
public func richCodeBlockSpans(edit: TextEdit, theme: SyntaxTheme) -> [RichSpan] {
    var out: [RichSpan] = []
    let paras = edit.paragraphs()
    var i = 0
    while i < paras.count {
        if paras[i].block == .code {
            let start = paras[i].range.lowerBound
            var end = paras[i].range.upperBound
            while i + 1 < paras.count && paras[i + 1].block == .code {
                i += 1
                end = paras[i].range.upperBound
            }
            let utf8 = edit.text.utf8
            if let sIdx = utf8.index(utf8.startIndex, offsetBy: start, limitedBy: utf8.endIndex),
               let eIdx = utf8.index(utf8.startIndex, offsetBy: end, limitedBy: utf8.endIndex) {
                let code = String(decoding: utf8[sIdx..<eIdx], as: UTF8.self)
                let highlights = Syntax.builtin(language: "rust", code: code)
                for h in highlights {
                    let absRange = (start + h.range.lowerBound)..<(start + h.range.upperBound)
                    var span = RichSpan(absRange).color(theme.paint(h.paint))
                    if case .kind(let k) = h.paint {
                        if let w = theme.weight(for: k) { span = span.weight(w) }
                        if k == .comment { span = span.italic(true) }
                    }
                    out.append(span)
                }
            }
        }
        i += 1
    }
    return out
}

private func toolbarButton(
    _ k: Kit,
    key: String,
    _ label: String,
    active: Bool,
    onPress: @escaping (inout RichEditorState) -> Void
) -> El<RichEditorState> {
    k.button(
        key: key,
        label,
        variant: active ? .primary : .ghost,
        size: .small
    ) { state, _ in
        onPress(&state)
    }
}

public func richEditorView(_ s: RichEditorState, _ cx: inout Cx<RichEditorState>) -> El<RichEditorState> {
    let k = Kit.neutral(dark: true)
    let syntax = SyntaxTheme.fromKit(k)
    let spans = richCodeBlockSpans(edit: s.edit, theme: syntax)
    let blk = s.edit.activeBlock

    let bar: El<RichEditorState> = row()
        .key("toolbar")
        .gap(4.0)
        .itemsCenter()
        .child(toolbarButton(k, key: "bold", "B", active: s.edit.hasRichMark(.bold)) { $0.edit.toggleMark(.bold) })
        .child(toolbarButton(k, key: "italic", "I", active: s.edit.hasRichMark(.italic)) { $0.edit.toggleMark(.italic) })
        .child(toolbarButton(k, key: "underline", "U", active: s.edit.hasRichMark(.underline)) { $0.edit.toggleMark(.underline) })
        .child(toolbarButton(k, key: "strike", "S", active: s.edit.hasRichMark(.strike)) { $0.edit.toggleMark(.strike) })
        .child(toolbarButton(k, key: "code", "<>", active: s.edit.hasRichMark(.code)) { $0.edit.toggleMark(.code) })
        .child(toolbarButton(k, key: "link", "Link", active: s.edit.activeLink != nil) { state in
            let next: String? = state.edit.activeLink != nil ? nil : "https://opencode.ai"
            state.edit.setLink(next)
        })
        .child(toolbarButton(k, key: "mention", "@", active: false) { insertRichMention(&$0.edit) })
        .child(el().w(4.0))
        .child(toolbarButton(k, key: "bullet", "• List", active: { if case .bullet = blk { return true }; return false }()) {
            $0.edit.toggleBlock(.bullet(0))
        })
        .child(toolbarButton(k, key: "numbered", "1. List", active: { if case .numbered = blk { return true }; return false }()) {
            $0.edit.toggleBlock(.numbered(0))
        })
        .child(toolbarButton(k, key: "quote", "Quote", active: blk == .quote) {
            $0.edit.toggleBlock(.quote)
        })
        .child(toolbarButton(k, key: "codeblock", "Code", active: blk == .code) {
            $0.edit.toggleBlock(.code)
        })

    let composer: El<RichEditorState> = col()
        .wFull()
        .rounded(k.radius.lg)
        .bg(k.c.layer01)
        .border(1.0, k.c.borderBase)
        .p(10.0)
        .gap(8.0)
        .child(bar)
        .child(Divider.horizontal().build(k))
        .child(
            TextArea<RichEditorState>(key: "composer-input", \.edit)
                .rows(11)
                .decorations(spans)
                .pillStyle(makePillStyleResolver(k, agents: s.agents))
                .build(k, cx: cx)
        )

    return col()
        .wFull()
        .hFull()
        .bg(k.c.page)
        .p(20.0)
        .gap(10.0)
        .child(text("Rich composer").font(Tok.Typography.title).color(k.c.textBase))
        .child(composer)
}

@main
public enum RuneKitRichEditorApp {
    public static func makeSpec() -> App<RichEditorState> {
        App(
            "Rich editor",
            size: Vec2(560.0, 380.0),
            init: RichEditorState.init,
            view: richEditorView
        )
        .families(["Inter", "IBM Plex Mono"])
    }

    public static func main() throws {
        try makeSpec().run()
    }
}
