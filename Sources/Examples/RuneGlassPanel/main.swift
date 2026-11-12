import Foundation
import Rune

private let flightWindow = Vec2(1000, 640)
private let startRect: (x: Float, y: Float, w: Float, h: Float) = (120, 300, 420, 236)
private let dockRect: (x: Float, y: Float, w: Float, h: Float) = (600, 64, 320, 92)
private let startRadius: Float = 26.0
private let dockRadius: Float = 18.0
private let margin: Float = 48.0

struct GlassPanelState {
    var docked: Bool = false
    /// Normalized flight progress 0...1 (0 = asking, 1 = docked).
    var flightT: Float = 0.0
    var popoverMaterial: Bool = ProcessInfo.processInfo.environment["GLASS_PANEL_POPOVER"] != nil
    var mark: Bool = ProcessInfo.processInfo.environment["GLASS_PANEL_MARK"] != nil
    var barPhase: Int = 0
}

private func smoothstep(_ t: Float) -> Float {
    let c = min(max(t, 0.0), 1.0)
    return c * c * (3.0 - 2.0 * c)
}

private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
    a + (b - a) * t
}

private func flightFrame(_ t: Float) -> (x: Float, y: Float, w: Float, h: Float, radius: Float, lift: Float) {
    let p = smoothstep(t)
    let w = lerp(startRect.w, dockRect.w, smoothstep(t * 1.25))
    let h = lerp(startRect.h, dockRect.h, smoothstep(t * 1.25 - 0.25))

    let fromX = startRect.x + startRect.w * 0.5
    let fromY = startRect.y + startRect.h * 0.5
    let toX = dockRect.x + dockRect.w * 0.5
    let toY = dockRect.y + dockRect.h * 0.5
    let ctrlX = lerp(fromX, toX, 0.6)
    let ctrlY: Float = 0.0

    let oneMinusP = 1.0 - p
    let cx = oneMinusP * oneMinusP * fromX + 2.0 * p * oneMinusP * ctrlX + p * p * toX
    let cy = oneMinusP * oneMinusP * fromY + 2.0 * p * oneMinusP * ctrlY + p * p * toY

    let radius = lerp(startRadius, dockRadius, p)
    let lift = sinf(.pi * p)
    return (cx - w * 0.5, cy - h * 0.5, w, h, radius, lift)
}

private func glassButton(
    _ label: String,
    ink: Color,
    fillAlpha: Float,
    action: @escaping (inout GlassPanelState) -> Void
) -> El<GlassPanelState> {
    row()
        .key(label)
        .role(.button)
        .label(label)
        .h(30)
        .px(14)
        .center()
        .rounded(9)
        .bg(ink.alpha(fillAlpha))
        .hover(ink.alpha(fillAlpha + 0.06))
        .onClick(action)
        .child(
            text(label)
                .font(TextStyle(size: 13.0, weight: 560.0))
                .color(ink.alpha(0.847))
        )
}

private func backdropLayer(_ s: GlassPanelState) -> El<GlassPanelState> {
    let cols = 20
    let rows = 13
    let tileW = flightWindow.x / Float(cols)
    let tileH = flightWindow.y / Float(rows)

    var children: [El<GlassPanelState>] = []
    children.reserveCapacity(cols * rows + 4)

    for i in 0..<(cols * rows) {
        let c = i % cols
        let r = i / cols
        let light: Float = (c + r).isMultiple(of: 2) ? 0.8 : 0.5
        let hue = Float((i * 23) % 360)
        children.append(
            el()
                .absolute(x: Float(c) * tileW, y: Float(r) * tileH)
                .size(tileW, tileH)
                .bg(oklch(light, 0.14, hue))
        )
    }

    for k in 0..<4 {
        let xPos = Float((k * 240 + s.barPhase * 45) % Int(flightWindow.x))
        children.append(
            el()
                .absolute(x: xPos, y: 0)
                .size(30, flightWindow.y)
                .bg(k.isMultiple(of: 2) ? .white : .black)
                .animateLayout(Tok.Motion.DEFAULT)
        )
    }

    return el()
        .key("backdrop")
        .wFull()
        .hFull()
        .children(children)
}

private func cardView(
    _ s: GlassPanelState,
    dark: Bool,
    frame: (x: Float, y: Float, w: Float, h: Float, radius: Float, lift: Float),
    showDockedContent: Bool
) -> El<GlassPanelState> {
    let ink: Color = dark ? .white : .black
    let frostBase = dark ? Color(r: 0.118, g: 0.118, b: 0.118, a: 1.0) : .white
    let frost = frostBase.alpha(s.popoverMaterial ? 0.78 : 0.62)

    let swapTransition = Transition(
        insertion: TransitionEffect(zeroOpacity: 0, zeroScale: Vec2(0.96, 0.96), zeroBlur: 3.0),
        removal: TransitionEffect(zeroOpacity: 0, zeroScale: Vec2(0.96, 0.96), zeroBlur: 3.0)
    )
    let content: El<GlassPanelState>
    if showDockedContent {
        content = row()
            .key("docked")
            .absolute(x: 0, y: 0)
            .size(dockRect.w, dockRect.h)
            .px(20)
            .gap(12)
            .itemsCenter()
            .transition(swapTransition)
            .child(
                col()
                    .gap(3)
                    .child(
                        text("Waiting for access")
                            .font(TextStyle(size: 15.0, weight: 620.0))
                            .color(ink.alpha(0.847))
                    )
                    .child(
                        text("Turn it on in System Settings")
                            .font(TextStyle(size: 12.0, weight: 450.0))
                            .color(ink.alpha(0.5))
                    )
            )
            .child(el().grow(1))
            .child(glassButton("Open", ink: ink, fillAlpha: 0.12) { state in
                state.docked = false
                state.flightT = 0.0
            })
    } else {
        content = col()
            .key("asking")
            .absolute(x: 0, y: 0)
            .size(startRect.w, startRect.h)
            .p(22)
            .gap(12)
            .transition(swapTransition)
            .child(
                text("Allow screen recording?")
                    .font(TextStyle(size: 19.0, weight: 650.0))
                    .color(ink.alpha(0.847))
            )
            .child(
                text("The assistant needs to see the window you are working in to help with it.")
                    .wFull()
                    .font(TextStyle(size: 13.5, weight: 450.0))
                    .color(ink.alpha(0.5))
            )
            .child(
                row()
                    .key("setting")
                    .wFull()
                    .h(44)
                    .px(14)
                    .itemsCenter()
                    .rounded(11)
                    .bg(ink.alpha(0.065))
                    .child(
                        text("Screen & System Audio Recording")
                            .font(TextStyle(size: 13.0, weight: 550.0))
                            .color(ink.alpha(0.847))
                    )
            )
            .child(el().grow(1))
            .child(
                row()
                    .wFull()
                    .gap(10)
                    .child(el().grow(1))
                    .child(glassButton("Not Now", ink: ink, fillAlpha: 0.065) { state in
                        state.docked = true
                        state.flightT = 1.0
                    })
                    .child(glassButton("Open Settings", ink: ink, fillAlpha: 0.12) { state in
                        state.docked = true
                        state.flightT = 1.0
                    })
            )
    }

    let frosted: El<GlassPanelState> = el()
        .key("frost")
        .wFull()
        .hFull()
        .rounded(frame.radius)
        .clip(true)
        .backdropBlur(s.popoverMaterial ? 16.0 : 28.0)
        .bg(frost)
        .border(1, ink.alpha(0.08))
        .child(content)

    let contactShadow = Shadow(x: 0, y: 0.5, blur: 1.5, color: Color.black.alpha(0.3 - 0.1 * frame.lift))
    let ambientShadow = Shadow(
        x: 0,
        y: 8.0 + 12.0 * frame.lift,
        blur: 18.0 + 14.0 * frame.lift,
        color: Color.black.alpha(0.32 + 0.14 * frame.lift)
    )

    return el()
        .key("card")
        .absolute(x: frame.x, y: frame.y)
        .size(frame.w, frame.h)
        .rounded(frame.radius)
        .shadows([contactShadow, ambientShadow])
        .animateLayout(Spring(duration: 0.6, bounce: 0.08))
        .animate(Spring(duration: 0.6, bounce: 0.08))
        .child(frosted)
}

private func glassPanelView(_ s: GlassPanelState, _ cx: inout Cx<GlassPanelState>) -> El<GlassPanelState> {
    let dark = cx.systemDark
    let frame = flightFrame(s.flightT)
    let showDocked = s.flightT >= 0.4

    var root: El<GlassPanelState> = el()
        .key("root")
        .wFull()
        .hFull()
        .child(backdropLayer(s))
        .child(cardView(s, dark: dark, frame: frame, showDockedContent: showDocked))

    if s.mark {
        let markColor = s.flightT >= 0.99
            ? Color(r: 1.0, g: 0.0, b: 1.0, a: 1.0)
            : Color(r: 0.0, g: 1.0, b: 1.0, a: 1.0)
        root = root.child(
            el()
                .key("mark")
                .absolute(x: dockRect.x - margin + 12, y: dockRect.y - margin + 4)
                .size(4, 4)
                .bg(markColor)
        )
    }

    return root
}

private func onGlassPanelKey(_ s: inout GlassPanelState, _ ev: KeyEvent, _ tx: inout Tx) -> Bool {
    switch ev.key {
    case .space:
        s.docked.toggle()
        s.flightT = s.docked ? 1.0 : 0.0
        s.barPhase += 1
        return true
    case .text("m"):
        s.mark.toggle()
        return true
    case .text("p"):
        s.popoverMaterial.toggle()
        return true
    case .arrowRight:
        s.flightT = min(1.0, s.flightT + 0.15)
        s.docked = s.flightT >= 0.99
        return true
    case .arrowLeft:
        s.flightT = max(0.0, s.flightT - 0.15)
        s.docked = s.flightT >= 0.99
        return true
    default:
        return false
    }
}

let spec = AppSpec(
    title: "Glass panel",
    size: flightWindow,
    state: GlassPanelState(),
    onKey: onGlassPanelKey,
    view: glassPanelView
)
.scene("asking") {
    $0.docked = false
    $0.flightT = 0.0
}
.scene("flight") {
    $0.docked = false
    $0.flightT = 0.45
    $0.barPhase = 2
}
.scene("docked") {
    $0.docked = true
    $0.flightT = 1.0
    $0.barPhase = 4
}
.scene("mark") {
    $0.docked = true
    $0.flightT = 1.0
    $0.mark = true
}

try RuneApp.run(spec)
