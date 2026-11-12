import Foundation
import Rune

/// Port of `examples/web-hello`: a mobile-proportioned Messages app with a scrollable
/// stick-to-bottom message list, a `TextEdit` composer, Send button, and Copy-last action.
struct WebHelloState {
    var messages: [String] = (1...24).map { "Message \($0): Hello from Rune." }
    var draft = TextEdit("")

    mutating func send() {
        let trimmed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(draft.text)
        draft.clear()
    }
}

func webHelloView(_ s: WebHelloState, _ cx: inout Cx<WebHelloState>) -> El<WebHelloState> {
    let t = Tok.theme(dark: cx.systemDark)
    let accent = Tok.accent(0, dark: cx.systemDark)

    var messageList: El<WebHelloState> = col()
        .wFull()
        .gap(12)
        .py(16)
    for (i, msg) in s.messages.enumerated() {
        messageList = messageList.child(
            text(msg)
                .key("message-\(i)")
                .font(Tok.Typography.body)
                .color(t.text)
                .wFull()
                .p(16)
                .rounded(12)
                .bg(t.card)
                .border(1, t.cardBorder)
        )
    }

    let composer: El<WebHelloState> = textInput(key: "composer", \.draft)
        .placeholder("Message", color: t.textSecondary)
        .font(Tok.Typography.body)
        .color(t.text)
        .caret(accent)
        .focusRing(accent)
        .grow(1)
        .h(48)
        .p(12)
        .rounded(12)
        .bg(t.card)
        .border(1, t.cardBorder)
        .onSubmit { state, _, tx in
            state.send()
            tx.scrollTo("messages", offset: Vec2(0, 1_000_000), animated: true)
        }

    let sendButton: El<WebHelloState> = row()
        .key("send")
        .role(.button)
        .label("Send")
        .h(48)
        .px(16)
        .center()
        .rounded(12)
        .bg(t.controlOff)
        .pressScale(0.96)
        .focusRing(accent)
        .onClick { state, tx in
            state.send()
            tx.scrollTo("messages", offset: Vec2(0, 1_000_000), animated: true)
        }
        .child(text("Send").font(Tok.Typography.label).color(t.text))

    let copyButton: El<WebHelloState> = row()
        .key("copy")
        .role(.button)
        .label("Copy last")
        .h(44)
        .px(8)
        .center()
        .rounded(8)
        .pressScale(0.96)
        .onClick { state, tx in
            if let last = state.messages.last {
                tx.copyText(last)
            }
        }
        .child(text("Copy last").font(Tok.Typography.label).color(t.textSecondary))

    let header: El<WebHelloState> = row()
        .wFull()
        .itemsCenter()
        .child(text("Messages").font(Tok.Typography.title).color(t.text).grow(1))
        .child(copyButton)

    let scroller: El<WebHelloState> = col()
        .key("messages")
        .wFull()
        .grow(1)
        .minH(0)
        .scroll(stickBottom: true)
        .child(messageList)

    let composerRow: El<WebHelloState> = row()
        .wFull()
        .gap(8)
        .itemsCenter()
        .child(composer)
        .child(sendButton)

    return col()
        .sizeFull()
        .p(16)
        .gap(8)
        .bg(t.bg)
        .child(header)
        .child(scroller)
        .child(composerRow)
}

let spec = AppSpec<WebHelloState>(
    title: "Messages",
    size: Vec2(390, 760),
    state: WebHelloState(),
    view: webHelloView
)
.scene("default") { _ in }
.scene("sent") { s in
    s.messages.append("Just shipped the Swift port!")
}

try RuneApp.run(spec)
