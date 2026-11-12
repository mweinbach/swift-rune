import Foundation
import Rune
import RuneKit
import RuneMotion

/// Port of `examples/web-showcase`: the live interactive panel from Rune's website featuring
/// a switch, a spring-curve segmented picker, and a draggable 4-stop puck track.
private let springs: [(name: String, spring: Spring)] = [
    ("Snappy", Spring(duration: 0.25, bounce: 0.0)),
    ("Smooth", Spring(duration: 0.40, bounce: 0.0)),
    ("Bouncy", Spring(duration: 0.50, bounce: 0.3)),
]

private let cardWidth: Float = 376.0
private let stageHeight: Float = 320.0
private let puckSize: Float = 28.0
private let stopCount: Int = 4

struct WebShowcaseState {
    var on: Bool = true
    var springIndex: Int = 2
    var at: Float = 0.0
    var atBeforeDrag: Float = 0.0
}

private func inkColor() -> Color {
    oklch(0.74, 0.14, 245.0)
}

private func snapToStop(_ at: Float) -> Float {
    let n = Float(stopCount - 1)
    return max(0.0, min(1.0, (at * n).rounded() / n))
}

private func showcaseSwitch(_ s: WebShowcaseState, _ t: ThemeTokens) -> El<WebShowcaseState> {
    let w: Float = 44.0
    let h: Float = 26.0
    let k: Float = 22.0
    let inset: Float = (h - k) / 2.0
    let spring = springs[s.springIndex].spring
    let knobX: Float = s.on ? (w - k - inset) : inset

    return el()
        .key("switch")
        .role(.switchControl)
        .label("Lights")
        .selected(s.on ? "true" : "false")
        .size(w, h)
        .pill()
        .bg(s.on ? inkColor() : t.controlOff)
        .animate(spring)
        .pressScale(0.95)
        .onClick { state in state.on.toggle() }
        .child(
            el()
                .key("knob")
                .square(k)
                .pill()
                .bg(t.knob)
                .absolute(x: knobX, y: inset)
                .animateLayout(spring)
                .shadow(Shadow(y: 1, blur: 3, color: t.knobShadow))
        )
}

private func showcasePicker(_ s: WebShowcaseState, seg: Float, _ t: ThemeTokens) -> El<WebShowcaseState> {
    let h: Float = 32.0
    let pad: Float = 3.0
    let innerH = h - 2.0 * pad
    let spring = springs[s.springIndex].spring

    var segRow: El<WebShowcaseState> = row().key("springs").absolute(x: pad, y: pad)
    for (i, item) in springs.enumerated() {
        let selected = (i == s.springIndex)
        let tabItem: El<WebShowcaseState> = row()
            .key(item.name)
            .role(.tab)
            .label(item.name)
            .selected(selected ? "true" : "false")
            .size(seg, innerH)
            .center()
            .onClick { state in state.springIndex = i }
            .child(
                text(item.name)
                    .font(TextStyle(size: 13, weight: 500))
                    .color(selected ? t.text : t.textSecondary)
            )
        segRow = segRow.child(tabItem)
    }

    return el()
        .key("picker")
        .size(seg * Float(springs.count) + 2.0 * pad, h)
        .pill()
        .bg(t.controlTrack)
        .child(
            el()
                .key("thumb")
                .size(seg, innerH)
                .rounded(innerH / 2.0)
                .absolute(x: pad + seg * Float(s.springIndex), y: pad)
                .bg(oklcha(1.0, 0.0, 0.0, 0.12))
                .animateLayout(spring)
        )
        .child(segRow)
}

private func showcaseTrack(_ s: WebShowcaseState, trackW: Float, _ t: ThemeTokens) -> El<WebShowcaseState> {
    let travel = max(1.0, trackW - puckSize)
    let spring = springs[s.springIndex].spring
    let toAt: (Float) -> Float = { x in
        max(0.0, min(1.0, (x - puckSize / 2.0) / travel))
    }

    var stops: El<WebShowcaseState> = el()
        .key("stops")
        .size(travel, puckSize)
        .absolute(x: puckSize / 2.0, y: 0)
    for i in 0..<stopCount {
        let x = travel * Float(i) / Float(stopCount - 1)
        let dot: El<WebShowcaseState> = el()
            .key("stop-\(i)")
            .square(4)
            .pill()
            .bg(oklcha(1.0, 0.0, 0.0, 0.22))
            .absolute(x: x - 2.0, y: puckSize / 2.0 - 2.0)
        stops = stops.child(dot)
    }

    return el()
        .key("track")
        .role(.slider)
        .label("Puck")
        .size(trackW, puckSize)
        .onPointerDown { state, press, _ in
            state.atBeforeDrag = state.at
            let puckX = puckSize / 2.0 + state.at * travel
            if abs(press.local.x - puckX) > puckSize / 2.0 + 4.0 {
                state.at = snapToStop(toAt(press.local.x))
            }
        }
        .onDrag { state, d, tx in
            let puckX = puckSize / 2.0 + state.atBeforeDrag * travel
            let grab = abs(d.startLocal.x - puckX) <= puckSize / 2.0 + 4.0
                ? (d.startLocal.x - puckX)
                : 0.0
            state.at = toAt(d.local.x - grab)
            tx.settle()
        }
        .onDragEnd { state, cancelled, _ in
            state.at = cancelled ? state.atBeforeDrag : snapToStop(state.at)
        }
        .child(
            el()
                .key("rail")
                .size(travel, 2)
                .rounded(1)
                .bg(t.controlOff)
                .absolute(x: puckSize / 2.0, y: puckSize / 2.0 - 1.0)
        )
        .child(
            el()
                .key("lit")
                .size(travel * s.at, 2)
                .rounded(1)
                .bg(inkColor())
                .absolute(x: puckSize / 2.0, y: puckSize / 2.0 - 1.0)
                .animateLayout(spring)
        )
        .child(stops)
        .child(
            el()
                .key("puck")
                .square(puckSize)
                .pill()
                .bg(t.knob)
                .absolute(x: travel * s.at, y: 0)
                .animateLayout(spring)
                .shadow(Shadow(y: 2, blur: 8, color: oklcha(0.0, 0.0, 0.0, 0.5)))
        )
}

private func lineRow(_ labelText: String, control: El<WebShowcaseState>, _ t: ThemeTokens) -> El<WebShowcaseState> {
    row()
        .wFull()
        .h(36)
        .itemsCenter()
        .child(
            text(labelText)
                .font(TextStyle(size: 14, weight: 400))
                .color(t.textSecondary)
                .grow(1)
        )
        .child(control)
}

func webShowcaseView(_ s: WebShowcaseState, _ cx: inout Cx<WebShowcaseState>) -> El<WebShowcaseState> {
    let t = Tok.theme(dark: true)
    let stageW = cx.viewport.x
    let cw = max(280.0, min(cardWidth, stageW - 16.0))
    let pad: Float = cw < cardWidth ? 20.0 : 32.0
    let inner = cw - 2.0 * pad
    let seg = min(88.0, (inner - 76.0) / 3.0)

    let card = col()
        .key("card")
        .w(cw)
        .p(pad)
        .gap(16)
        .rounded(20)
        .bg(oklch(0.17, 0.006, 265.0))
        .border(1, oklcha(1.0, 0.0, 0.0, 0.08))
        .child(lineRow("Lights", control: showcaseSwitch(s, t), t))
        .child(lineRow("Spring", control: showcasePicker(s, seg: seg, t), t))
        .child(el().h(8))
        .child(showcaseTrack(s, trackW: inner, t))

    return col()
        .key("stage")
        .sizeFull()
        .center()
        .bg(.black)
        .child(card)
}

let spec = AppSpec<WebShowcaseState>(
    title: "Rune",
    size: Vec2(560, stageHeight),
    state: WebShowcaseState(),
    view: webShowcaseView
)
.scene("poster") { _ in }
.scene("end") { s in
    s.at = 1.0
}
.scene("off") { s in
    s.on = false
    s.springIndex = 0
    s.at = 1.0 / 3.0
}

try RuneApp.run(spec)
