import Foundation
import Rune
import RuneMotion

/// Parity port of `crates/rune/examples/scroll_keys.rs`:
/// Up/Down move selection across 120 cards while scrolling smoothly to keep the selection in view.
@main
enum RuneScrollKeysApp {
    static let cardCount = 120
    static let cardHeight: Float = 52.0
    static let cardGap: Float = 8.0
    static let listPad: Float = 12.0
    static let viewportHeight: Float = 360.0

    struct Board: Sendable {
        var selected: Int = 4
        var top: Float = 0.0
    }

    static func card(_ s: Board, _ k: Int) -> El<Board> {
        let isSelected = k == s.selected
        return row()
            .key("card-\(k)")
            .wFull()
            .h(cardHeight)
            .px(14)
            .itemsCenter()
            .rounded(10)
            .bg(isSelected ? oklch(0.42, 0.09, 250.0) : oklch(0.26, 0.015, 250.0))
            .hover(Color.white.alpha(0.06))
            .child(text(String(format: "Card %03d", k)).font(TextStyle(size: 13, weight: 500)).color(.white))
    }

    static func view(_ s: Board, _ cx: inout Cx<Board>) -> El<Board> {
        var cards: El<Board> = col().key("cards").wFull().p(listPad).gap(cardGap)
        for k in 0..<cardCount {
            cards = cards.child(card(s, k))
        }

        return col()
            .wFull()
            .hFull()
            .bg(oklch(0.18, 0.01, 250.0))
            .child(
                row()
                    .key("bar")
                    .wFull()
                    .h(40)
                    .px(14)
                    .itemsCenter()
                    .child(text("↑ ↓ to move").font(TextStyle(size: 12, weight: 500)).color(oklch(0.7, 0.01, 250.0)))
            )
            .child(
                col()
                    .key("board")
                    .wFull()
                    .h(viewportHeight)
                    .scroll(stickBottom: false)
                    .child(cards)
            )
    }

    static func onKey(_ s: inout Board, _ e: KeyEvent, _ tx: inout Tx) -> Bool {
        switch e.key {
        case .arrowDown:
            s.selected = min(s.selected + 1, cardCount - 1)
        case .arrowUp:
            s.selected = max(s.selected - 1, 0)
        default:
            return false
        }

        let top = listPad + Float(s.selected) * (cardHeight + cardGap) - listPad
        let bottom = top + cardHeight + 2.0 * listPad
        let to: Float
        if top < s.top {
            to = top
        } else if bottom > s.top + viewportHeight {
            to = bottom - viewportHeight
        } else {
            to = s.top
        }
        if to != s.top {
            s.top = to
            tx.scrollTo("board", offset: Vec2(0, to), animated: true)
        }
        return true
    }

    static func makeApp() -> App<Board> {
        App(title: "Scroll with the keys", size: Vec2(420, 400), state: Board(), view: view)
            .onKey(onKey)
    }

    static func main() throws {
        try makeApp().run()
    }
}
