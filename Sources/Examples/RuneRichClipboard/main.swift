import Foundation
import Rune

/// Port of `examples/rich-clipboard`: copy and paste formatted text (plain, HTML, RTF).
struct RichClipboardState {
    var field = TextEdit()
    var last: (String, ClipboardContent)? = nil
    var clipboard = Clipboard.shared
}

func sampleRichPayload() -> RichClipboardPayload {
    RichClipboardPayload(
        text: "Rune copies bold and italic text.",
        html: "Rune copies <b>bold</b> and <i>italic</i> text.",
        rtf: #"{\rtf1\ansi{\fonttbl\f0\fswiss Helvetica;}\f0 Rune copies {\b bold} and {\i italic} text.}"#
    )
}

func recordSeen(_ s: inout RichClipboardState, how: String, content: ClipboardContent) {
    let htmlLen = content.html.map { "\($0.utf8.count)" } ?? "nil"
    let rtfLen = content.rtf.map { "\($0.utf8.count)" } ?? "nil"
    print("\(how): text \(content.text.utf8.count) bytes, html \(htmlLen) bytes, rtf \(rtfLen) bytes")
    if let html = content.html {
        print(html)
    }
    s.last = (how, content)
}

func richSummary(_ last: (String, ClipboardContent)?) -> (String, String) {
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
        .p(8)
        .rounded(Tok.Radius.md)
        .bg(t.card)
        .border(1, t.cardBorder)
        .hover(t.hover)
        .press(t.press)
        .child(text(label).size(12).medium().color(t.text))
        .onClick(action)
}

func richClipboardView(_ s: RichClipboardState, _ cx: inout Cx<RichClipboardState>) -> El<RichClipboardState> {
    let t = Tok.theme(dark: true)
    let (head, preview) = richSummary(s.last)

    let field: El<RichClipboardState> = textInput(key: "field", \RichClipboardState.field)
        .wFull()
        .minH(80)
        .p(8)
        .rounded(Tok.Radius.md)
        .bg(t.card)
        .border(1, t.cardBorder)
        .size(14)
        .color(t.text)

    return col()
        .sizeFull()
        .p(24)
        .gap(12)
        .bg(t.bg)
        .child(field)
        .child(
            row()
                .gap(8)
                .child(richButton(key: "copy", label: "Copy formatted") { state, _ in
                    let payload = sampleRichPayload()
                    state.clipboard.writeRich(payload)
                    recordSeen(&state, how: "Copied", content: payload.content)
                })
                .child(richButton(key: "read", label: "Read clipboard") { state, _ in
                    let payload = state.clipboard.readRich()
                    recordSeen(&state, how: "Read", content: payload.content)
                })
        )
        .child(text(head).key("summary").size(13).color(t.textSecondary))
        .child(text(preview).key("preview").size(12).medium().color(t.textSecondary).wFull())
}

let spec = AppSpec<RichClipboardState>(
    title: "Rich Clipboard",
    size: Vec2(560, 420),
    dark: true,
    state: RichClipboardState(),
    view: richClipboardView
)
.scene("idle") { $0.last = nil }
.scene("copied") {
    let sample = sampleRichPayload().content
    $0.last = ("Copied", sample)
}
.scene("pasted") {
    let sample = sampleRichPayload().content
    $0.field = TextEdit(sample.text)
    $0.last = ("Pasted", sample)
}

try RuneApp.run(spec as AppSpec<RichClipboardState>)
