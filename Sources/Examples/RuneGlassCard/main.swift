import Foundation
import Rune

/// Port of `examples/glass-card`: a frosted/translucent glass card with spring-animated frame
/// and corner radius flying over an OKLCH color tile pattern and docking into a bottom-right capsule.
private let canvasSize = Vec2(760, 480)
private let magenta = Color(r: 1.0, g: 0.0, b: 1.0, a: 1.0)

struct GlassCardState {
    var docked: Bool = false
    var measure: Bool = false
    var phase: Int = 0
}

private func cardFrame(docked: Bool) -> (x: Float, y: Float, w: Float, h: Float, radius: Float) {
    if docked {
        return (canvasSize.x - 290, canvasSize.y - 94, 250, 60, 30)
    } else {
        return (70, 60, 400, 260, 28)
    }
}

private func backdropLayer(_ s: GlassCardState) -> El<GlassCardState> {
    if s.measure {
        return el()
            .key("pattern")
            .sizeFull()
            .bg(.black)
    }

    let cols = 16
    let rows = 10
    let tileW = canvasSize.x / Float(cols)
    let tileH = canvasSize.y / Float(rows)

    var pattern: El<GlassCardState> = el()
        .key("pattern")
        .sizeFull()
        .bg(Color(r: 0.1, g: 0.1, b: 0.12, a: 1.0))

    for i in 0..<(cols * rows) {
        let c = i % cols
        let r = i / cols
        let light: Float = (c + r).isMultiple(of: 2) ? 0.78 : 0.42
        let hue = Float(((i * 23) + s.phase * 15) % 360)
        pattern = pattern.child(
            el()
                .absolute(x: Float(c) * tileW, y: Float(r) * tileH)
                .size(tileW, tileH)
                .bg(Color.oklch(light, 0.16, hue))
        )
    }

    for k in 0..<6 {
        let xPos = Float((k * 130 + s.phase * 36) % Int(canvasSize.x))
        let bar: El<GlassCardState> = el()
            .absolute(x: xPos, y: 0)
            .size(36, canvasSize.y)
            .bg(k.isMultiple(of: 2) ? Color.white.alpha(0.35) : Color.black.alpha(0.4))
            .animateLayout(Tok.Motion.DEFAULT)
        pattern = pattern.child(bar)
    }

    for k in 0..<3 {
        pattern = pattern.child(
            text("RUNE 120 Hz")
                .size(56)
                .bold()
                .color(Color.white.alpha(0.85))
                .absolute(x: 40 + Float((s.phase * 20) % 120), y: 54 + Float(k) * 164)
        )
    }

    return pattern
}

func glassCardView(_ s: GlassCardState, _ cx: inout Cx<GlassCardState>) -> El<GlassCardState> {
    let f = cardFrame(docked: s.docked)
    let actionLabel = s.docked ? "Fly" : "Dock"

    let toggleBtn: El<GlassCardState> = row()
        .key("toggle")
        .role(.button)
        .label(actionLabel)
        .h(30)
        .px(14)
        .center()
        .rounded(15)
        .bg(Color.white.alpha(0.20))
        .border(1, Color.white.alpha(0.35))
        .hover(Color.white.alpha(0.28))
        .pressScale(0.95)
        .onClick { state in state.docked.toggle() }
        .child(text(actionLabel).size(13).semibold().color(.white))

    let title: El<GlassCardState> = text(s.docked ? "Docked" : "Liquid glass")
        .key("title")
        .size(s.docked ? 15 : 26)
        .semibold()
        .color(.white)

    var card: El<GlassCardState> = col()
        .key("card")
        .absolute(x: f.x, y: f.y)
        .size(f.w, f.h)
        .rounded(f.radius)
        .p(s.docked ? 16 : 26)
        .gap(12)
        .bg(Color(r: 0.14, g: 0.16, b: 0.22, a: 0.58))
        .backdropBlur(24)
        .border(s.measure ? 2.0 : 1.0, s.measure ? magenta : Color.white.alpha(0.28))
        .shadow(Shadow(y: 18, blur: 44, color: Color(r: 0, g: 0, b: 0, a: 0.35)))
        .animateLayout(Spring(duration: 0.7, bounce: 0.22))
        .animate(Spring(duration: 0.7, bounce: 0.22))

    if s.docked {
        card = card.child(
            row()
                .wFull()
                .hFull()
                .itemsCenter()
                .justifyBetween()
                .gap(12)
                .child(title)
                .child(toggleBtn)
        )
    } else {
        let spacer: El<GlassCardState> = el().grow(1)
        let body: El<GlassCardState> = text("Frame and corner radius on one spring. Press Space or click Dock to animate between floating card and capsule.")
            .key("body")
            .wFull()
            .size(14)
            .color(Color.white.alpha(0.85))
        let measureBtn: El<GlassCardState> = row()
            .key("measure-btn")
            .px(10)
            .py(5)
            .rounded(12)
            .bg(Color.white.alpha(s.measure ? 0.28 : 0.12))
            .onClick { state in state.measure.toggle() }
            .child(text(s.measure ? "Pattern" : "Measure").size(12).medium().color(.white))
        card = card
            .child(title)
            .child(body)
            .child(spacer)
            .child(
                row()
                    .wFull()
                    .itemsCenter()
                    .justifyBetween()
                    .child(measureBtn)
                    .child(toggleBtn)
            )
    }

    return el()
        .key("root")
        .sizeFull()
        .child(backdropLayer(s))
        .child(card)
}

let spec = AppSpec<GlassCardState>(
    title: "Glass Card",
    size: canvasSize,
    minSize: canvasSize,
    state: GlassCardState(),
    onKey: { state, event, _ in
        switch event.key {
        case .space:
            state.docked.toggle()
            return true
        case .text(" "):
            state.docked.toggle()
            return true
        case .text("b"):
            state.measure.toggle()
            return true
        case .text("n"):
            state.phase += 1
            return true
        default:
            return false
        }
    },
    view: glassCardView
)
.scene("floating") { $0.docked = false; $0.measure = false }
.scene("docked") { $0.docked = true; $0.measure = false }
.scene("measure") { $0.docked = false; $0.measure = true }

try RuneApp.run(spec)
