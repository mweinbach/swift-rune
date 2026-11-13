import Foundation
import Rune
import RuneKit
import RuneMotion

private let segH: Float = 44.0
private let segPad: Float = 4.0
private let thermostatRing: Float = 150.0

public func bentoScenes(_ s: MotionBentoState, _ k: Kit) -> El<MotionBentoState> {
    let m = s.m
    let mood = ChaosColor.scene[m.scene]
    let w = bentoInnerW(2.0)
    let segW = (w - 2.0 * segPad) / Float(ChaosConstants.scenes.count)
    let snap = bentoSpring(s.springs.snap)
    let morph = bentoSpring(s.springs.morph)

    var segments: El<MotionBentoState> = row()
        .w(w)
        .h(segH)
        .rounded(12.0)
        .bg(bentoColor(ChaosColor.well))
        .border(1.0, bentoColor(ChaosColor.edge))
        .p(segPad)
        .child(
            el()
                .size(segW, segH - 2.0 * segPad)
                .absolute(x: segPad + segW * Float(m.scene), y: segPad)
                .rounded(9.0)
                .bg(bentoColor(mood))
                .shadow(Shadow(y: 4.0, blur: 14.0, color: bentoColor(mood.alpha(0.45))))
                .animate(snap)
                .animateLayout(snap)
        )

    for (i, name) in ChaosConstants.scenes.enumerated() {
        let on = i == m.scene
        let seg: El<MotionBentoState> = row()
            .key("seg\(i)")
            .grow(1.0)
            .hFull()
            .center()
            .onClick { state in state.act(.scene(UInt8(i))) }
            .child(
                text(name)
                    .font(bentoFont(14.0, 560.0))
                    .color(bentoColor(on ? ChaosColor.onAccent : ChaosColor.text2))
                    .animate(snap)
            )
        segments = segments.child(seg)
    }

    let lightsOn = m.lights.filter { $0 }.count
    let picked = m.chips.filter { $0 }.count
    func stat(_ label: String, _ value: String) -> El<MotionBentoState> {
        col()
            .gap(2.0)
            .p(10.0)
            .w(118.0)
            .rounded(12.0)
            .bg(bentoColor(ChaosColor.well))
            .child(bentoCaption(label))
            .child(k.rollingText(key: "stat-\(label)", value, font: bentoNums(16.0, 600.0), color: bentoColor(ChaosColor.text)))
    }

    let summary = row()
        .h(bentoInnerH(ChaosGrid.row1) - segH - 16.0)
        .w(w)
        .centerY()
        .gap(10.0)
        .child(
            el()
                .size(260.0, 90.0)
                .absolute(x: -30.0 + segW * Float(m.scene) * 0.55, y: 6.0)
                .rounded(45.0)
                .bg(bentoColor(mood.alpha(0.22)))
                .blur(36.0)
                .animate(morph)
                .animateLayout(morph)
        )
        .child(
            col()
                .gap(4.0)
                .grow(1.0)
                .child(
                    k.rollingText(
                        key: "scene-name",
                        ChaosConstants.scenes[m.scene],
                        font: bentoFont(30.0, 650.0),
                        color: bentoColor(ChaosColor.text)
                    )
                )
                .child(
                    text(ChaosConstants.sceneNotes[m.scene])
                        .font(bentoFont(13.0, 460.0))
                        .color(bentoColor(ChaosColor.text2))
                )
        )
        .child(stat("Lights", "\(lightsOn) of 4"))
        .child(stat("Target", m.tempLabel()))
        .child(stat("Genres", "\(picked)"))

    let swatch = row()
        .gap(8.0)
        .centerY()
        .child(bentoCaption("Mood"))
        .child(
            el()
                .size(14.0, 14.0)
                .rounded(7.0)
                .bg(bentoColor(mood))
                .shadow(Shadow(y: 0.0, blur: 8.0, color: bentoColor(mood.alpha(0.6))))
                .animate(morph)
        )

    return bentoTile(
        key: "scene",
        name: "Scenes",
        aside: swatch,
        body: col().gap(16.0).child(segments).child(summary)
    ).w(bentoInnerW(2.0) + 2.0 * ChaosGrid.tilePad)
}

/// The thermostat ring's arc: 270° from the lower left, clockwise, as points.
private func thermostatArc(size: Float, inset: Float) -> [Vec2] {
    let r = size / 2.0 - inset
    let a0: Float = 135.0 * .pi / 180.0
    let sweep: Float = 270.0 * .pi / 180.0
    return (0...96).map { i in
        let a = a0 + sweep * Float(i) / 96.0
        return Vec2(size / 2.0 + r * cosf(a), size / 2.0 + r * sinf(a))
    }
}

public func bentoThermostat(_ s: MotionBentoState, _ k: Kit) -> El<MotionBentoState> {
    let m = s.m
    let points = thermostatArc(size: thermostatRing, inset: 9.0)
    let track = Shape.new().strokeWith(points, closed: false, width: 10.0, cap: .round, color: bentoColor(ChaosColor.wellHi))
    let fill = Shape.new().strokeWith(points, closed: false, width: 10.0, cap: .round, color: bentoColor(ChaosColor.accent))
    let ring = el()
        .size(thermostatRing, thermostatRing)
        .child(canvas(track).size(thermostatRing, thermostatRing).absolute(x: 0.0, y: 0.0))
        .child(
            canvas(fill)
                .size(thermostatRing, thermostatRing)
                .absolute(x: 0.0, y: 0.0)
                .liveTrim(s.ring.smooth(bentoSpring(s.springs.travel)))
        )
        .child(
            col()
                .size(thermostatRing, thermostatRing)
                .absolute(x: 0.0, y: 0.0)
                .center()
                .gap(0.0)
                .child(k.rollingText(key: "temp", m.tempLabel(), font: bentoNums(34.0, 640.0), color: bentoColor(ChaosColor.text)))
                .child(bentoCaption("Target"))
        )

    let heating = m.temp > 21.0
    let aside: El<MotionBentoState> = row()
        .gap(6.0)
        .centerY()
        .child(
            el()
                .size(8.0, 8.0)
                .rounded(4.0)
                .bg(bentoColor(heating ? ChaosColor.warm : ChaosColor.accent))
                .animate(bentoSpring(s.springs.morph))
        )
        .child(
            k.rollingText(
                key: "mode",
                heating ? "Heating" : "Cooling",
                font: bentoFont(12.0, 460.0),
                color: bentoColor(ChaosColor.text3)
            )
        )

    let buttons: El<MotionBentoState> = col()
        .gap(10.0)
        .child(bentoWellButton(key: "up", label: "+", w: 52.0, h: 44.0) { $0.act(.tempUp) })
        .child(bentoWellButton(key: "down", label: "−", w: 52.0, h: 44.0) { $0.act(.tempDown) })

    let body = row()
        .h(bentoInnerH(ChaosGrid.row1))
        .centerY()
        .gap(14.0)
        .child(ring)
        .child(spacer())
        .child(buttons)

    return bentoTile(key: "thermo", name: "Thermostat", aside: aside, body: body)
        .w(bentoInnerW(1.0) + 2.0 * ChaosGrid.tilePad)
}

public func bentoLights(_ s: MotionBentoState, _ k: Kit) -> El<MotionBentoState> {
    let m = s.m
    let onCount = m.lights.filter { $0 }.count
    var rows: El<MotionBentoState> = col().gap(4.0)
    for (i, name) in ChaosConstants.lights.enumerated() {
        let lit = m.lights[i]
        let lightRow: El<MotionBentoState> = row()
            .h(34.0)
            .centerY()
            .gap(12.0)
            .child(
                el()
                    .size(10.0, 10.0)
                    .rounded(5.0)
                    .bg(bentoColor(lit ? ChaosColor.warm : ChaosColor.wellHi))
                    .shadow(Shadow(y: 0.0, blur: 10.0, color: bentoColor(lit ? ChaosColor.warm.alpha(0.7) : ChaosColor.warm.alpha(0.0))))
                    .animate(bentoSpring(s.springs.snap))
            )
            .child(
                text(name)
                    .font(bentoFont(14.0, 500.0))
                    .color(bentoColor(lit ? ChaosColor.text : ChaosColor.text2))
            )
            .child(spacer())
            .child(
                k.switchControl(key: "light\(i)", isOn: lit, label: name) { state, _ in
                    state.act(.light(UInt8(i)))
                }
            )
        rows = rows.child(lightRow)
    }

    let aside: El<MotionBentoState> = k.rollingText(key: "lights-on", "\(onCount) on", font: bentoFont(12.0, 460.0), color: bentoColor(ChaosColor.text3))
    return bentoTile(key: "lights", name: "Lights", aside: aside, body: rows)
        .w(bentoInnerW(1.0) + 2.0 * ChaosGrid.tilePad)
}
