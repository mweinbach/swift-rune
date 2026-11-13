import Foundation
import Rune

public struct RichClipboardState: Sendable {
    public var field = TextEdit()
    public var last: (String, ClipboardContent)? = nil
    public var clipboard: Clipboard

    public init(clipboard: Clipboard = Clipboard.shared) {
        self.clipboard = clipboard
    }
}

public func sampleRichPayload() -> RichClipboardPayload {
    RichClipboardPayload(
        text: "Rune copies bold and italic text.",
        html: "Rune copies <b>bold</b> and <i>italic</i> text.",
        rtf: #"{\rtf1\ansi{\fonttbl\f0\fswiss Helvetica;}\f0 Rune copies {\b bold} and {\i italic} text.}"#
    )
}

public func recordSeen(_ s: inout RichClipboardState, how: String, content: ClipboardContent) {
    let htmlLen = content.html.map { "\($0.utf8.count)" } ?? "nil"
    let rtfLen = content.rtf.map { "\($0.utf8.count)" } ?? "nil"
    print("\(how): text \(content.text.utf8.count) bytes, html \(htmlLen) bytes, rtf \(rtfLen) bytes")
    if let html = content.html {
        print(html)
    }
    s.last = (how, content)
}

public func richSummary(_ last: (String, ClipboardContent)?) -> (String, String) {
    guard let (how, content) = last else {
        return ("Paste formatted text into the field", "")
    }
    func form(_ name: String, _ str: String?) -> String {
        if let str { return "\(name) \(str.utf8.count) B" }
        return "no \(name)"
    }
    let head = "\(how): text \(content.text.utf8.count) B, \(form("HTML", content.html)), \(form("RTF", content.rtf))"
    let preview = String((content.html ?? "").prefix(400))
    return (head, preview)
}

func richButton(
    key: String,
    label: String,
    action: @escaping (inout RichClipboardState, inout Tx) -> Void
) -> El<RichClipboardState> {
    let t = Tok.theme(dark: true)
    return row()
        .key(key)
        .role(.button)
        .p(Tok.Space.sm)
        .rounded(Tok.Radius.md)
        .bg(t.card)
        .border(1, t.cardBorder)
        .child(text(label).font(Tok.Typography.label).color(t.text))
        .onClick(action)
}

public func richClipboardView(_ s: RichClipboardState, _ cx: inout Cx<RichClipboardState>) -> El<RichClipboardState> {
    let t = Tok.theme(dark: true)
    let (head, preview) = richSummary(s.last)

    let field: El<RichClipboardState> = textInput(key: "field", \RichClipboardState.field)
        .wFull()
        .minH(80)
        .p(Tok.Space.sm)
        .rounded(Tok.Radius.md)
        .bg(t.card)
        .border(1, t.cardBorder)
        .font(Tok.Typography.body)
        .color(t.text)
        .onInputPaste { state, content, _ in
            recordSeen(&state, how: "Pasted", content: content)
            return false
        }

    return col()
        .sizeFull()
        .p(Tok.Space.xl)
        .gap(Tok.Space.md)
        .bg(t.bg)
        .child(field)
        .child(
            row()
                .gap(Tok.Space.sm)
                .child(richButton(key: "copy", label: "Copy formatted") { _, tx in
                    tx.copyRich(sampleRichPayload())
                })
                .child(richButton(key: "read", label: "Read clipboard") { state, _ in
                    let payload = state.clipboard.readRich()
                    recordSeen(&state, how: "Read", content: payload.content)
                })
        )
        .child(text(head).key("summary").font(Tok.Typography.body).color(t.textSecondary))
        .child(text(preview).key("preview").font(Tok.Typography.label).color(t.textSecondary).wFull())
}

@main
enum RuneRichClipboardApp {
    static func makeSpec() -> AppSpec<RichClipboardState> {
        AppSpec<RichClipboardState>(
            title: "Rich Clipboard",
            size: Vec2(560, 420),
            state: RichClipboardState(),
            view: richClipboardView
        )
    }

    static func main() throws {
        try RuneApp.run(makeSpec())
    }
}
