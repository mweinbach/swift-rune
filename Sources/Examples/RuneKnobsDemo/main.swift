import Foundation
import Rune
import RuneKit
import RuneKnobs

private let radiusKnob = Knob("Card radius", min: 0.0, max: 32.0, default: 14.0)
    .about("How round the card's corners are")
private let padKnob = Knob("Card padding", min: 8.0, max: 48.0, default: 24.0)
    .step(1.0)
private let tintKnob = Knob.choice("Card tint", labels: ["Plain", "Accent", "Raised"], default: 0)
private let shadowKnob = Knob.choice("Card shadow", labels: ["Off", "On"], default: 0)

private let knobGroups: [KnobGroup] = [
    KnobGroup("Card", region: "card", knobs: [radiusKnob, padKnob, tintKnob, shadowKnob])
        .presets([KnobPreset("Round", values: ["Card radius": 28.0])])
]

struct KnobsDemoState {
    var knobs = Knobs()
}

private func styleForContext(_ cx: Cx<KnobsDemoState>) -> KnobStyle {
    cx.systemDark ? .dark() : .light()
}

private func pageView(_ s: KnobsDemoState, _ cx: inout Cx<KnobsDemoState>) -> El<KnobsDemoState> {
    let t = Tok.theme(dark: cx.systemDark)
    let ink = cx.systemDark ? t.bg : t.text
    let k = s.knobs
    let tintIdx = Int(k.get(tintKnob).rounded())
    let fill: Color = switch tintIdx {
    case 1: Tok.accent(0, dark: true)
    case 2: t.controlOff
    default: t.knob
    }

    let shadowOffset: Float = k.get(shadowKnob) > 0.5 ? 10.0 : 0.0
    var card: El<KnobsDemoState> = col()
        .key("card")
        .w(240)
        .p(k.get(padKnob))
        .gap(6)
        .rounded(k.get(radiusKnob))
        .bg(fill)
        .child(text("Tune me").font(Tok.Typography.title).color(ink))
        .child(text("⌘⇧K opens the knobs").color(ink))

    if shadowOffset > 0 {
        card = card.shadow(Shadow(x: 0, y: shadowOffset, blur: 24, color: t.bg.alpha(0.35)))
    }

    return col()
        .key("page")
        .grow(1)
        .hFull()
        .center()
        .bg(t.bg)
        .child(card)
}

private func knobsDemoView(_ s: KnobsDemoState, _ cx: inout Cx<KnobsDemoState>) -> El<KnobsDemoState> {
    let page = pageView(s, &cx)
    return RuneKnobs.side(
        page: page,
        knobs: s.knobs,
        groups: knobGroups,
        style: styleForContext(cx),
        keyPath: \.knobs
    )
}

private func onKnobsKey(_ s: inout KnobsDemoState, _ ev: KeyEvent, _ tx: inout Tx) -> Bool {
    if RuneKnobs.key(&s.knobs, event: ev) {
        tx.settle()
        return true
    }
    if s.knobs.open && s.knobs.panelKey(groups: knobGroups, event: ev) {
        tx.settle()
        return true
    }
    return false
}

let spec = AppSpec(
    title: "Knobs",
    size: Vec2(820, 520),
    state: KnobsDemoState(),
    onKey: onKnobsKey,
    view: knobsDemoView
)
.scene("open") { $0.knobs.show() }
.scene("filter") {
    $0.knobs.show()
    $0.knobs.filter("pad")
}

try RuneApp.run(spec)
