import Foundation
import Rune

/// Parity port of `crates/rune/examples/text_coverage.rs`:
/// colour emoji ZWJ/flags/keycaps, math alphanumerics, and aligned wrapped text across `emoji`, `math`, and `align` scenes.
@main
enum RuneTextCoverageApp {
    enum SceneKind: String, CaseIterable, Sendable {
        case emoji
        case math
        case align
    }

    struct State: Sendable {
        var scene: SceneKind = .emoji
    }

    static func view(_ s: State, _ cx: inout Cx<State>) -> El<State> {
        let t = Tok.theme(dark: cx.systemDark)
        func line(_ content: String, _ size: Float) -> El<State> {
            text(content).font(TextStyle(size: size, weight: 400)).color(t.text)
        }
        func note(_ content: String) -> El<State> {
            text(content).font(TextStyle(size: 12, weight: 400)).color(t.textSecondary)
        }
        func para(_ content: String, _ align: TextAlign) -> El<State> {
            text(content)
                .font(TextStyle(size: 13, weight: 400))
                .color(t.text)
                .wFull()
                .textAlign(align)
                .bg(t.card)
                .p(8)
                .rounded(6)
        }
        func pair(_ a: El<State>, _ b: El<State>) -> El<State> {
            row().wFull().gap(12).child(a.w(250)).child(b.w(250))
        }

        let rows: [El<State>]
        switch s.scene {
        case .emoji:
            rows = [
                note("ZWJ family, flag, skin tone, ❤️, keycap"),
                line("Family 👨‍👩‍👧‍👦 flag 🇯🇵 wave 👋🏽 love ❤️ key 1️⃣", 17),
                line("Small 👨‍👩‍👧‍👦🇯🇵👋🏽❤️ at 12pt", 12),
                line("Large 👨‍👩‍👧‍👦🇯🇵👋🏽❤️", 40),
                line("Faded 👨‍👩‍👧‍👦 🇯🇵 👋🏽 ❤️ (opacity 0.4)", 17).opacity(0.4),
                note("Plain ❤ and ☺︎ stay text symbols"),
                line("Text ❤ ☺︎ ⌘ ⇧", 17),
            ]
        case .math:
            rows = [
                note("Mathematical Alphanumeric Symbols"),
                line("𝐁𝐨𝐥𝐝 𝐴𝑙𝑔𝑒𝑏𝑟𝑎 𝓢𝓬𝓻𝓲𝓹𝓽 𝔉𝔯𝔞𝔨𝔱𝔲𝔯 𝕯𝖔𝖚𝖇𝖑𝖊", 17),
                line("𝔸 𝔹 ℂ 𝔻 𝕖 𝕗 𝟘𝟙𝟚 𝚖𝚘𝚗𝚘 𝖲𝖺𝗇𝗌 𝛼𝛽𝛾 𝜕𝑓/𝜕𝑥", 17),
                line("Let 𝑓(𝑥) = 𝑎𝑥² + 𝑏𝑥 + 𝑐 for 𝑥 ∈ ℝ", 17),
                note("Enclosed and other symbols"),
                line("Ⓐ Ⓑ ① ② ⑴ ⒜ 🄰 🅐 ⠁⠃⠉ 🁣 🜁 ∮ ∯ ⨀ ⨁", 17),
            ]
        case .align:
            let latin = "Wrapped lines align one by one inside the element's width, so a short last line sits where the alignment puts it."
            let hebrew = "שורות עוטפות מתיישרות אחת אחת בתוך רוחב האלמנט, כך שהשורה האחרונה הקצרה יושבת במקום הנכון."
            rows = [
                pair(note("Center"), note("Leading")),
                pair(para(latin, .center), para(latin, .leading)),
                pair(note("Right-to-left Start"), note("Right-to-left Trailing")),
                pair(para(hebrew, .leading), para(hebrew, .trailing)),
            ]
        }

        var container: El<State> = col().wFull().hFull().p(24).gap(12).bg(t.bg)
        for childEl in rows {
            container = container.child(childEl)
        }
        return container
    }

    static func makeApp() -> App<State> {
        App(title: "Text coverage", size: Vec2(560, 360), state: State(), view: view)
            .scene("emoji") { s, _ in s.scene = .emoji }
            .scene("math") { s, _ in s.scene = .math }
            .scene("align") { s, _ in s.scene = .align }
    }

    static func main() throws {
        try makeApp().run()
    }
}
