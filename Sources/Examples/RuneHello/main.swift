import Foundation
import Rune

/// Port of `examples/hello`: a minimal interactive card with an animated toggle switch,
/// supporting both interactive Metal windowing and `--snap hello.png --scene on` / `--tree`.
struct HelloState {
    var on: Bool = false
}

func helloView(_ s: HelloState, _ cx: inout Cx<HelloState>) -> El<HelloState> {
    let t = Tok.theme(dark: cx.systemDark)
    let accent = Tok.accent(0, dark: cx.systemDark)
    let knobX: Float = s.on ? 20.0 : 2.0

    let toggle: El<HelloState> = el()
        .key("sw")
        .role(.switchControl)
        .label("Notifications")
        .selected(s.on ? "true" : "false")
        .size(40, 22)
        .pill()
        .bg(s.on ? accent : t.controlOff)
        .animate(Tok.Motion.SNAPPY)
        .pressScale(0.95)
        .focusRing(accent)
        .onClick { state in state.on.toggle() }
        .child(
            el()
                .key("knob")
                .square(18)
                .pill()
                .bg(t.knob)
                .shadow(Shadow(y: 1, blur: 3, color: t.knobShadow))
                .absolute(x: knobX, y: 2)
                .animateLayout(Tok.Motion.SNAPPY)
        )

    let card: El<HelloState> = col()
        .key("card")
        .w(320)
        .p(20)
        .gap(16)
        .rounded(Tok.Radius.xl)
        .bg(t.card)
        .border(1, t.cardBorder)
        .shadow(Shadow(y: 8, blur: 24, color: t.shadow))
        .child(
            col().gap(4)
                .child(text("Hello, Rune").size(18).semibold().color(t.text))
                .child(text("Declarative Swift UI rendered directly via Metal & RuneRef.").size(13).color(t.textSecondary))
        )
        .child(rule(1, t.separator))
        .child(
            row()
                .wFull()
                .itemsCenter()
                .justifyBetween()
                .child(text(s.on ? "Notifications enabled" : "Notifications paused").size(14).medium().color(t.text))
                .child(toggle)
        )

    return row()
        .sizeFull()
        .center()
        .bg(t.bg)
        .child(card)
}

let spec = AppSpec<HelloState>(
    title: "Hello Rune",
    size: Vec2(460, 300),
    state: HelloState(),
    view: helloView
)
.scene("on") { $0.on = true }
.scene("off") { $0.on = false }

try RuneApp.run(spec)
