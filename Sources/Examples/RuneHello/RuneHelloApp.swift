import Foundation
import Rune

struct HelloState {
    var on: Bool = false
}

func helloView(_ s: HelloState, _ cx: inout Cx<HelloState>) -> El<HelloState> {
    let t = Tok.theme(dark: true)
    let label: El<HelloState> = text(s.on ? "Lights on" : "Lights off")
        .font(Tok.Typography.title)
        .color(t.text)
    let knob: El<HelloState> = el()
        .key("knob")
        .size(18, 18)
        .rounded(9)
        .bg(t.knob)
        .absolute(x: s.on ? 18 : 2, y: 2)
        .animateLayout(Tok.Motion.SNAPPY)
    let sw: El<HelloState> = el()
        .key("switch")
        .role(.switchControl)
        .label("Lights")
        .selected(s.on ? "true" : "false")
        .focusable(true)
        .size(38, 22)
        .rounded(11)
        .bg(s.on ? Tok.accent(0, dark: true) : t.controlOff)
        .animate(Tok.Motion.SNAPPY)
        .onClick { $0.on.toggle() }
        .child(knob)
    return col()
        .wFull()
        .hFull()
        .center()
        .gap(16)
        .bg(t.bg)
        .child(label)
        .child(sw)
}

@main
enum RuneHelloApp {
    static func makeSpec() -> AppSpec<HelloState> {
        AppSpec<HelloState>(
            title: "Hello",
            size: Vec2(320, 200),
            state: HelloState(),
            view: helloView
        )
        .scene("on") { $0.on = true }
    }

    static func main() throws {
        try RuneApp.run(makeSpec())
    }
}
