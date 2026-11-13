import Foundation
import Rune
import RuneKit
import RuneKnobs

let radiusKnob = Knob("Card radius", min: 0.0, max: 32.0, default: 14.0)
    .about("How round the card's corners are")
let padKnob = Knob("Card padding", min: 8.0, max: 48.0, default: 24.0)
    .step(1.0)
let tintKnob = Knob.choice("Card tint", labels: ["Plain", "Accent", "Raised"], default: 0)
let shadowKnob = Knob.choice("Card shadow", labels: ["Off", "On"], default: 0)

let knobGroups: [KnobGroup] = [
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

func knobsDemoView(_ s: KnobsDemoState, _ cx: inout Cx<KnobsDemoState>) -> El<KnobsDemoState> {
    let page = pageView(s, &cx)
    return RuneKnobs.side(
        page: page,
        knobs: s.knobs,
        groups: knobGroups,
        style: styleForContext(cx),
        keyPath: \.knobs
    )
}

func onKnobsKey(_ s: inout KnobsDemoState, _ ev: KeyEvent, _ tx: inout Tx) -> Bool {
    if RuneKnobs.key(&s.knobs, event: ev) {
        tx.motion(s.knobs.slide())
        return true
    }
    if s.knobs.open && s.knobs.panelKey(groups: knobGroups, event: ev) {
        tx.settle()
        return true
    }
    return false
}

/// The playground's side column: the same knobs as rows, filling its width.
private func storySideView(_ s: KnobsDemoState, _ active: Bool, _ cx: inout Cx<KnobsDemoState>) -> El<KnobsDemoState> {
    var k = s.knobs
    k.kbd = active
    return RuneKnobs.inline(
        knobs: k,
        groups: knobGroups,
        style: styleForContext(cx),
        keyPath: \.knobs
    )
}

func knobsDemoPlayground() -> PlaygroundHost<KnobsDemoState> {
    PlaygroundHost<KnobsDemoState>().story(
        Story(path: "Card/Knobs", { KnobsDemoState() }, pageView)
            .sideKeys(
                RuneKnobs.sideKey(groups: knobGroups, keyPath: \.knobs),
                storySideView
            )
    )
}

@main
enum RuneKnobsDemoApp {
    static func makeApp() -> App<KnobsDemoState> {
        App("Knobs", size: Vec2(820, 520), init: { KnobsDemoState() }, view: knobsDemoView)
            .onKey(onKnobsKey)
            .scene("open") { s, _ in s.knobs.show() }
            .scene("filter") { s, _ in
                s.knobs.show()
                s.knobs.filter("pad")
            }
            .playground(knobsDemoPlayground())
    }

    static func makeSpec() -> AppSpec<KnobsDemoState> {
        makeApp().intoSpec()
    }

    static func main() throws {
        try makeApp().run()
    }
}
