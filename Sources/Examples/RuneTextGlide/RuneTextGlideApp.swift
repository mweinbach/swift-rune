import Foundation
import Rune
import RuneMotion

/// Parity port of `crates/rune/examples/text_glide.rs`:
/// a card that drifts 2.5 pt vertically on a slow spring when tapped.
@main
enum RuneTextGlideApp {
    struct Card: Sendable {
        var down: Bool = false
    }

    static func view(_ s: Card, _ cx: inout Cx<Card>) -> El<Card> {
        let label: El<Card> = text("Quiet harbor glides")
            .font(TextStyle(size: 13, weight: 500))
            .color(.white)

        let card: El<Card> = col()
            .key("card")
            .absolute(x: 40, y: 60)
            .p(12)
            .rounded(10)
            .bg(oklch(0.3, 0.02, 250.0))
            .border(1, oklch(0.42, 0.02, 250.0))
            .offset(0, s.down ? 2.5 : 0)
            .animate(Spring(duration: 1.2, bounce: 0.0))
            .onClick { s in s.down.toggle() }
            .child(label)

        return col()
            .wFull()
            .hFull()
            .bg(oklch(0.2, 0.01, 250.0))
            .child(card)
    }

    static func makeApp() -> App<Card> {
        App(title: "Text glide", size: Vec2(320, 180), state: Card(), view: view)
    }

    static func main() throws {
        try makeApp().run()
    }
}
