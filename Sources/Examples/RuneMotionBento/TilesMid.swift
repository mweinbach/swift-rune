import Foundation
import Rune
import RuneKit
import RuneMotion

private let trackH: Float = 132.0
public let queueCardH: Float = 140.0
public let queuePeek: Float = 14.0
public let queueShrink: Float = 0.05
private let kindHues: [Float] = [245.0, 30.0, 155.0, 70.0, 200.0, 265.0, 330.0, 175.0]

private func midTileW() -> Float {
    bentoInnerW(1.0) + 2.0 * ChaosGrid.tilePad
}

public func bentoMixer(_ s: MotionBentoState, _ k: Kit) -> El<MotionBentoState> {
    let travel = bentoSpring(s.springs.travel)
    var faders: El<MotionBentoState> = row().wFull().h(bentoInnerH(ChaosGrid.row2)).justifyBetween()
    for (i, name) in ChaosConstants.faders.enumerated() {
        let v = s.m.faders[i]
        let h = 12.0 + v * (trackH - 12.0)
        let track: El<MotionBentoState> = el()
            .size(30.0, trackH)
            .child(el().size(8.0, trackH).absolute(x: 11.0, y: 0.0).rounded(4.0).bg(bentoColor(ChaosColor.well)))
            .child(
                el()
                    .size(8.0, h)
                    .absolute(x: 11.0, y: trackH - h)
                    .rounded(4.0)
                    .linearGradient(top: bentoColor(lch(0.74, 0.14, 240.0)), bottom: bentoColor(ChaosColor.accent))
                    .animate(travel)
                    .animateLayout(travel)
            )
            .child(
                el()
                    .size(30.0, 12.0)
                    .absolute(x: 0.0, y: trackH - h - 6.0)
                    .rounded(6.0)
                    .bg(bentoColor(ChaosColor.text))
                    .shadow(Shadow(y: 2.0, blur: 6.0, color: bentoColor(lch(0.0, 0.0, 0.0).alpha(0.5))))
                    .animate(travel)
                    .animateLayout(travel)
            )

        faders = faders.child(
            col()
                .key("fader\(i)")
                .itemsCenter()
                .gap(8.0)
                .onClick { state in state.act(.fader(UInt8(i))) }
                .child(
                    k.rollingText(
                        key: "level\(i)",
                        String(format: "%.0f", v * 100.0),
                        font: bentoNums(12.0, 560.0),
                        color: bentoColor(ChaosColor.text2)
                    )
                )
                .child(track)
                .child(bentoCaption(name))
        )
    }

    let live = row()
        .gap(6.0)
        .centerY()
        .child(el().size(6.0, 6.0).rounded(3.0).bg(bentoColor(ChaosColor.good)))
        .child(bentoCaption("Live"))

    return bentoTile(key: "mixer", name: "Mixer", aside: live, body: faders).w(midTileW())
}

private func xyGridLines(w: Float, h: Float) -> Shape {
    let lineColor = bentoColor(lch(1.0, 0.0, 0.0).alpha(0.06))
    var shape = Shape.new()
    for i in 1..<4 {
        let x = w * Float(i) / 4.0
        let y = h * Float(i) / 4.0
        shape = shape
            .line(Vec2(x, 0.0), Vec2(x, h), width: 1.0, cap: .butt, color: lineColor)
            .line(Vec2(0.0, y), Vec2(w, y), width: 1.0, cap: .butt, color: lineColor)
    }
    return shape
}

public func bentoXY(_ s: MotionBentoState, _ k: Kit) -> El<MotionBentoState> {
    let travel = bentoSpring(s.springs.travel)
    let w = bentoInnerW(1.0)
    let h = bentoInnerH(ChaosGrid.row2)
    let px = s.m.puck[0]
    let py = s.m.puck[1]
    let x = px * w
    let y = py * h

    let pad: El<MotionBentoState> = el()
        .key("pad")
        .size(w, h)
        .rounded(14.0)
        .bg(bentoColor(ChaosColor.well))
        .border(1.0, bentoColor(ChaosColor.edge))
        .clip(true)
        .onClick { state in state.act(.puck) }
        .child(canvas(xyGridLines(w: w, h: h)).size(w, h).absolute(x: 0.0, y: 0.0))
        .child(el().size(1.0, h).absolute(x: x, y: 0.0).bg(bentoColor(ChaosColor.accent.alpha(0.35))).animateLayout(travel))
        .child(el().size(w, 1.0).absolute(x: 0.0, y: y).bg(bentoColor(ChaosColor.accent.alpha(0.35))).animateLayout(travel))
        .child(
            el()
                .size(96.0, 96.0)
                .absolute(x: x - 48.0, y: y - 48.0)
                .rounded(48.0)
                .bg(bentoColor(ChaosColor.accent.alpha(0.28)))
                .blur(18.0)
                .animateLayout(travel)
        )
        .child(
            el()
                .size(24.0, 24.0)
                .absolute(x: x - 12.0, y: y - 12.0)
                .rounded(12.0)
                .bg(bentoColor(ChaosColor.accent))
                .border(3.0, bentoColor(ChaosColor.text))
                .shadow(Shadow(y: 3.0, blur: 10.0, color: bentoColor(lch(0.0, 0.0, 0.0).alpha(0.45))))
                .animateLayout(travel)
        )

    let readout: El<MotionBentoState> = row()
        .gap(10.0)
        .child(
            k.rollingText(
                key: "cutoff",
                String(format: "%.0f Hz", 200.0 + px * 7800.0),
                font: bentoNums(12.0, 500.0),
                color: bentoColor(ChaosColor.text3)
            )
        )
        .child(
            k.rollingText(
                key: "res",
                String(format: "Q %.1f", 0.5 + (1.0 - py) * 9.5),
                font: bentoNums(12.0, 500.0),
                color: bentoColor(ChaosColor.text3)
            )
        )

    return bentoTile(key: "xy", name: "Filter", aside: readout, body: pad).w(midTileW())
}

private func trackArt(_ track: Int) -> El<MotionBentoState> {
    let hue = (Float(track) * 47.0 + 200.0).truncatingRemainder(dividingBy: 360.0)
    let angle = 135.0 * Float.pi / 180.0
    return el()
        .size(64.0, 64.0)
        .rounded(12.0)
        .linearGradient(
            top: bentoColor(lch(0.72, 0.15, hue)),
            bottom: bentoColor(lch(0.42, 0.14, (hue + 50.0).truncatingRemainder(dividingBy: 360.0))),
            angleRadians: angle
        )
}

public func bentoQueue(_ s: MotionBentoState, _ k: Kit) -> El<MotionBentoState> {
    let layout = bentoSpring(s.springs.layout)
    let w = bentoInnerW(1.0)
    let h = bentoInnerH(ChaosGrid.row2)
    var deck: El<MotionBentoState> = el().w(w).h(h)

    for (depth, card) in s.m.queue.enumerated().reversed() {
        let d = Float(depth)
        let front = depth == 0
        let (title, artist) = ChaosConstants.tracks[card.track]
        let shade = lch(0.29 - 0.025 * d, 0.018, 258.0)
        let progress: Float = 0.18 + 0.09 * Float(card.id % 7)
        let secs = UInt32(progress * 220.0)

        let info = col()
            .gap(14.0)
            .wFull()
            .opacity(front ? 1.0 : 0.0)
            .child(
                row()
                    .gap(14.0)
                    .centerY()
                    .child(trackArt(card.track))
                    .child(
                        col()
                            .gap(3.0)
                            .child(text(title).font(bentoFont(16.0, 620.0)).color(bentoColor(ChaosColor.text)))
                            .child(text(artist).font(bentoFont(13.0, 460.0)).color(bentoColor(ChaosColor.text2)))
                    )
            )
            .child(
                col()
                    .gap(6.0)
                    .child(
                        el()
                            .wFull()
                            .h(4.0)
                            .rounded(2.0)
                            .bg(bentoColor(ChaosColor.wellHi))
                            .child(el().wFrac(progress).h(4.0).rounded(2.0).bg(bentoColor(ChaosColor.text2)))
                    )
                    .child(
                        row()
                            .child(
                                text(String(format: "%u:%02u", secs / 60, secs % 60))
                                    .font(bentoNums(11.0, 500.0))
                                    .color(bentoColor(ChaosColor.text3))
                            )
                            .child(spacer())
                            .child(text("3:40").font(bentoNums(11.0, 500.0)).color(bentoColor(ChaosColor.text3)))
                    )
            )

        deck = deck.child(
            col()
                .key("card\(card.id)")
                .size(w, queueCardH)
                .absolute(x: 0.0, y: d * queuePeek)
                .scale(1.0 - d * queueShrink)
                .rounded(16.0)
                .bg(bentoColor(shade))
                .border(1.0, bentoColor(ChaosColor.edge))
                .shadow(Shadow(y: 6.0, blur: 18.0, color: bentoColor(lch(0.0, 0.0, 0.0).alpha(0.35))))
                .p(16.0)
                .animate(layout)
                .animateLayout(layout)
                .transition(
                    Transition.asymmetric(
                        insertion: .scale(0.9),
                        removal: Transition.move(edge: .trailing).combined(with: .opacity)
                    )
                )
                .child(info)
        )
    }

    let skip: El<MotionBentoState> = row()
        .key("skip")
        .h(24.0)
        .px(10.0)
        .rounded(12.0)
        .center()
        .bg(bentoColor(ChaosColor.accentDim))
        .hover(bentoColor(ChaosColor.accent.alpha(0.28)))
        .pressScale(0.94)
        .onClick { state in state.act(.queue) }
        .child(text("Skip").font(bentoFont(12.0, 600.0)).color(bentoColor(ChaosColor.accent)))

    return bentoTile(key: "queue", name: "Up next", aside: skip, body: deck).w(midTileW())
}

public func bentoFeed(_ s: MotionBentoState, _ k: Kit) -> El<MotionBentoState> {
    var rows: El<MotionBentoState> = col().wFull().gap(6.0)
    for item in s.m.feed {
        let hue = kindHues[item.kind % kindHues.count]
        let rowItem: El<MotionBentoState> = row()
            .key("item\(item.id)")
            .h(40.0)
            .wFull()
            .px(12.0)
            .gap(10.0)
            .rounded(12.0)
            .centerY()
            .bg(bentoColor(ChaosColor.well))
            .transition(
                Transition.asymmetric(
                    insertion: Transition.offset(x: 0.0, y: -12.0).combined(with: .opacity),
                    removal: .scale(0.96)
                )
            )
            .child(el().size(8.0, 8.0).rounded(4.0).bg(bentoColor(lch(0.72, 0.15, hue))))
            .child(
                text(ChaosConstants.feedKinds[item.kind])
                    .font(bentoFont(13.0, 500.0))
                    .color(bentoColor(ChaosColor.text))
                    .ellipsis()
            )
            .child(spacer())
            .child(
                text(String(format: "9:%02u", item.minute))
                    .font(bentoNums(12.0, 460.0))
                    .color(bentoColor(ChaosColor.text3))
            )
        rows = rows.child(rowItem)
    }

    let test: El<MotionBentoState> = row()
        .key("test")
        .h(24.0)
        .px(10.0)
        .rounded(12.0)
        .center()
        .bg(bentoColor(ChaosColor.well))
        .hover(bentoColor(ChaosColor.wellHi))
        .pressScale(0.94)
        .onClick { state in state.act(.feed) }
        .child(text("Test alert").font(bentoFont(12.0, 560.0)).color(bentoColor(ChaosColor.text2)))

    return bentoTile(
        key: "feed",
        name: "Activity",
        aside: test,
        body: rows.animateLayout(bentoSpring(s.springs.layout))
    ).w(midTileW())
}
