import Foundation
import Rune
import RuneMotion

/// Port of `crates/rune/examples/expressive_press.rs`.
/// Keycap and ring driven by `scale`, `offset`, `origin`, `rotate`, and spring-animated shadows.
public struct ExpressivePressState: Sendable {
    public var pressed: Bool = false
    public var grown: Bool = false
    public var still: Bool = false

    public init(pressed: Bool = false, grown: Bool = false, still: Bool = false) {
        self.pressed = pressed
        self.grown = grown
        self.still = still
    }
}

public enum RuneExpressivePressApp {
    public static func keycap(pressed: Bool) -> El<ExpressivePressState> {
        el()
            .size(96, 96)
            .rounded(18)
            .center()
            .bg(Color(r: 0.99, g: 0.98, b: 0.96, a: 1.0))
            .border(1, Color(r: 0.0, g: 0.0, b: 0.0, a: 0.08))
            .animate(Spring(duration: 0.22, bounce: 0.0))
            .origin(0.5, 1.0)
            .scale(pressed ? 0.96 : 1.0)
            .offset(0, pressed ? 2.0 : 0.0)
            .shadow(
                Shadow(
                    x: 0,
                    y: pressed ? 2.0 : 8.0,
                    blur: pressed ? 4.0 : 18.0,
                    color: Color.black.alpha(pressed ? 0.30 : 0.22)
                )
            )
            .child(
                text("K")
                    .font(TextStyle(size: 34, weight: 600))
                    .color(Color(r: 0.16, g: 0.17, b: 0.20, a: 1.0))
            )
    }

    public static func ring(grown: Bool) -> El<ExpressivePressState> {
        let accent = Tok.accent(0, dark: false)
        return col()
            .size(96, 96)
            .rounded(24)
            .border(6, accent)
            .itemsCenter()
            .p(10)
            .animate(Spring(duration: 0.50, bounce: 0.15))
            .origin(0.5, 1.0)
            .rotate(grown ? (.pi / 4.0) : 0.0)
            .scale(grown ? 1.0 : 0.55)
            .child(el().size(14, 14).rounded(7).bg(accent))
    }

    public static func view(state: ExpressivePressState, cx: inout Cx<ExpressivePressState>) -> El<ExpressivePressState> {
        let t = Tok.theme(dark: false)
        let label: (String) -> El<ExpressivePressState> = { s in
            text(s).font(Tok.Typography.label).color(t.textSecondary)
        }
        let stage: El<ExpressivePressState>
        if state.still {
            stage = row()
                .gap(56)
                .itemsCenter()
                .child(col().gap(22).itemsCenter().child(keycap(pressed: false)).child(label("Rest")))
                .child(col().gap(22).itemsCenter().child(keycap(pressed: true)).child(label("Pressed")))
        } else {
            stage = row()
                .gap(96)
                .itemsEnd()
                .child(keycap(pressed: state.pressed))
                .child(ring(grown: state.grown))
        }
        return col()
            .wFull()
            .hFull()
            .center()
            .bg(Color(r: 0.86, g: 0.87, b: 0.89, a: 1.0))
            .child(stage)
    }

    public static func onKey(state: inout ExpressivePressState, event: KeyEvent, tx: inout Tx) -> Bool {
        switch event.key {
        case .text("p"): state.pressed = true; return true
        case .text("u"): state.pressed = false; return true
        case .text("r"): state.grown = true; return true
        default: return false
        }
    }

    public static func makeApp() -> App<ExpressivePressState> {
        App(title: "Expressive press", size: Vec2(440, 260), state: ExpressivePressState(), view: view)
            .scene("still") { s, _ in
                s.still = true
                s.pressed = true
            }
            .onKey(onKey)
    }
}

@main
enum RuneExpressivePressMain {
    static func main() throws {
        try RuneExpressivePressApp.makeApp().run()
    }
}
