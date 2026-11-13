import Foundation
import Rune
import RuneKit
import RuneMotion

private let days = ["M", "T", "W", "T", "F", "S", "S"]

public func thousands(_ n: UInt32) -> String {
    let s = String(n)
    var out = ""
    for (i, ch) in s.enumerated() {
        if i > 0 && (s.count - i) % 3 == 0 {
            out.append(",")
        }
        out.append(ch)
    }
    return out
}

public func bentoDockH() -> Float {
    ChaosGrid.height - 2.0 * ChaosGrid.pad - ChaosGrid.header - ChaosGrid.row1 - ChaosGrid.row2 - 3.0 * ChaosGrid.gap
}

public func bentoDock(_ s: MotionBentoState, _ k: Kit) -> El<MotionBentoState> {
    let bodyH = bentoDockH() - 2.0 * ChaosGrid.tilePad - 34.0
    var dock: El<MotionBentoState> = row().key("dock").wFull().h(bentoDockH()).gap(ChaosGrid.gap)
    for i in 0..<ChaosConstants.dock.count {
        let focused = s.m.focus == i
        let deps = [focused ? 1 : 0] + dockVersion(s, i)
        dock = dock.child(
            memo(ChaosConstants.dockKeys[i], deps: deps, cache: s.memoCache) {
                let (aside, body): (El<MotionBentoState>, El<MotionBentoState>) = switch i {
                case 0: bentoEnergy(s, k, h: bodyH)
                case 1: bentoChips(s, k)
                case 2: bentoOrb(s, k, h: bodyH)
                case 3: bentoTransfers(s, k)
                default: bentoVisitors(s, k, h: bodyH)
                }
                return bentoTile(key: ChaosConstants.dockKeys[i], name: ChaosConstants.dock[i], aside: aside, body: body)
                    .grow(focused ? ChaosGrid.dockFocus : 1.0)
                    .w(0.0)
                    .hFull()
                    .bg(bentoColor(focused ? ChaosColor.tileFocus : ChaosColor.tile))
                    .border(1.0, bentoColor(focused ? ChaosColor.accent.alpha(0.45) : ChaosColor.edge))
                    .clip(true)
                    .onClick { state in state.act(.focus(UInt8(i))) }
            }
        )
    }
    return dock
}

private func dockVersion(_ s: MotionBentoState, _ i: Int) -> [UInt32] {
    let m = s.m
    switch i {
    case 0:
        return m.energy.map(\.bitPattern) + [m.kwhTenths]
    case 1:
        return m.chips.map { $0 ? 1 : 0 } + [m.chipsOpen ? 1 : 0]
    case 2:
        return [m.orb.size, m.orb.hue, m.orb.round, m.orb.turn].map(\.bitPattern)
    case 3:
        return m.transfers.map(\.bitPattern)
    default:
        return m.visits.flatMap { [$0.id, $0.count] } + [m.visitors]
    }
}

private func bentoEnergy(_ s: MotionBentoState, _ k: Kit, h: Float) -> (El<MotionBentoState>, El<MotionBentoState>) {
    let barsH = h - 22.0
    var bars: El<MotionBentoState> = row()
        .key("bars")
        .wFull()
        .h(barsH)
        .itemsEnd()
        .gap(6.0)
        .onClick { state in state.act(.energy) }
    var dayLabels: El<MotionBentoState> = row().wFull().gap(6.0)
    let peakVal = s.m.energy.max() ?? 0.0
    let travel = bentoSpring(s.springs.travel)

    for (i, v) in s.m.energy.enumerated() {
        let peak = v == peakVal
        let bar: El<MotionBentoState> = el()
            .grow(1.0)
            .w(0.0)
            .h(10.0 + v * (barsH - 10.0))
            .rounded(6.0)
            .linearGradient(
                top: bentoColor(peak ? lch(0.8, 0.13, 240.0) : lch(0.5, 0.1, 250.0)),
                bottom: bentoColor(peak ? ChaosColor.accent : lch(0.36, 0.07, 255.0))
            )
            .animate(travel)
            .animateLayout(travel)
        bars = bars.child(bar)
        let dayLabel: El<MotionBentoState> = row()
            .grow(1.0)
            .w(0.0)
            .center()
            .child(bentoCaption(days[i]))
        dayLabels = dayLabels.child(dayLabel)
    }

    let aside: El<MotionBentoState> = k.rollingText(
        key: "kwh",
        "\(s.m.energyKwh()) kWh",
        font: bentoNums(12.0, 560.0),
        color: bentoColor(ChaosColor.text2)
    )
    return (aside, col().wFull().gap(6.0).child(bars).child(dayLabels))
}

private func bentoChips(_ s: MotionBentoState, _ k: Kit) -> (El<MotionBentoState>, El<MotionBentoState>) {
    let snap = bentoSpring(s.springs.snap)
    var wrap: El<MotionBentoState> = row().wFull().flexWrap().gap(6.0).animateLayout(bentoSpring(s.springs.layout))
    for i in 0..<s.m.chipsShown() {
        let on = s.m.chips[i]
        let chipEl: El<MotionBentoState> = row()
            .key("chip\(i)")
            .h(28.0)
            .px(12.0)
            .rounded(14.0)
            .center()
            .bg(bentoColor(on ? ChaosColor.accent : ChaosColor.well))
            .border(1.0, bentoColor(on ? ChaosColor.accent.alpha(0.0) : ChaosColor.edge))
            .pressScale(0.94)
            .transition(Transition.scale(0.8))
            .animate(snap)
            .onClick { state in state.act(.chip(UInt8(i))) }
            .child(
                text(ChaosConstants.chips[i])
                    .font(bentoFont(13.0, 540.0))
                    .color(bentoColor(on ? ChaosColor.onAccent : ChaosColor.text2))
                    .animate(snap)
            )
        wrap = wrap.child(chipEl)
    }

    let more: El<MotionBentoState> = row()
        .key("more")
        .h(22.0)
        .px(8.0)
        .rounded(11.0)
        .center()
        .hover(bentoColor(ChaosColor.well))
        .onClick { state in state.act(.chipsMore) }
        .child(
            k.rollingText(
                key: "more-label",
                s.m.chipsOpen ? "Less" : "More",
                font: bentoFont(12.0, 560.0),
                color: bentoColor(ChaosColor.accent)
            )
        )
    return (more, wrap)
}

private func bentoOrb(_ s: MotionBentoState, _ k: Kit, h: Float) -> (El<MotionBentoState>, El<MotionBentoState>) {
    let o = s.m.orb
    let side = 40.0 + o.size * (h - 50.0)
    let tint = lch(0.7, 0.16, o.hue)
    let shape: El<MotionBentoState> = el()
        .key("orb")
        .size(side, side)
        .rounded(o.round * side)
        .linearGradient(
            top: bentoColor(lch(0.84, 0.12, o.hue - 20.0)),
            bottom: bentoColor(lch(0.52, 0.19, o.hue + 25.0))
        )
        .shadow(Shadow(y: 10.0, blur: 44.0, color: bentoColor(tint.alpha(0.55))))
        .rotate(o.turn * .pi / 180.0)
        .animate(bentoSpring(s.springs.morph))
        .animateLayout(bentoSpring(s.springs.morph))
        .onClick { state in state.act(.orb) }
        .child(
            el()
                .size(side * 0.34, side * 0.34)
                .absolute(x: side * 0.14, y: side * 0.14)
                .rounded(side * 0.17)
                .bg(bentoColor(lch(1.0, 0.0, 0.0).alpha(0.28)))
        )

    let aside: El<MotionBentoState> = k.rollingText(
        key: "hue",
        String(format: "%.0f°", o.hue),
        font: bentoNums(12.0, 560.0),
        color: bentoColor(ChaosColor.text2)
    )
    return (aside, row().wFull().h(h).center().child(shape))
}

private func bentoTransfers(_ s: MotionBentoState, _ k: Kit) -> (El<MotionBentoState>, El<MotionBentoState>) {
    let travel = bentoSpring(s.springs.travel)
    var rows: El<MotionBentoState> = col().wFull().gap(12.0)
    for (i, name) in ChaosConstants.files.enumerated() {
        let p = s.m.transfers[i]
        let done = p >= 1.0
        let label = done ? "Done" : String(format: "%.0f%%", p * 100.0)
        let rowEl: El<MotionBentoState> = col()
            .key("row\(i)")
            .wFull()
            .gap(6.0)
            .onClick { state in state.act(.transfer(UInt8(i))) }
            .child(
                row()
                    .wFull()
                    .centerY()
                    .child(text(name).font(bentoFont(13.0, 500.0)).color(bentoColor(ChaosColor.text)).ellipsis())
                    .child(spacer())
                    .child(
                        k.rollingText(
                            key: "pct\(i)",
                            label,
                            font: bentoNums(12.0, 560.0).aligned(.trailing),
                            color: bentoColor(done ? ChaosColor.good : ChaosColor.text2)
                        )
                    )
            )
            .child(
                el()
                    .wFull()
                    .h(6.0)
                    .rounded(3.0)
                    .bg(bentoColor(ChaosColor.well))
                    .child(
                        el()
                            .wFrac(max(p, 0.02))
                            .h(6.0)
                            .rounded(3.0)
                            .bg(bentoColor(done ? ChaosColor.good : ChaosColor.accent))
                            .animate(travel)
                            .animateLayout(travel)
                    )
            )
        rows = rows.child(rowEl)
    }

    let active = s.m.transfers.filter { $0 < 1.0 }.count
    let aside: El<MotionBentoState> = k.rollingText(key: "active", "\(active) active", font: bentoFont(12.0, 460.0), color: bentoColor(ChaosColor.text3))
    return (aside, rows)
}

private func bentoVisitors(_ s: MotionBentoState, _ k: Kit, h: Float) -> (El<MotionBentoState>, El<MotionBentoState>) {
    let count: El<MotionBentoState> = row()
        .key("count")
        .onClick { state in state.act(.visitors) }
        .child(
            k.rollingText(
                key: "visitors",
                thousands(s.m.visitors),
                font: bentoNums(40.0, 660.0),
                color: bentoColor(ChaosColor.text)
            )
        )

    let chartH = h - 52.0 - 18.0 - 14.0
    let newest = s.m.visits.last?.id
    var chart: El<MotionBentoState> = row().wFull().h(chartH).itemsEnd().gap(4.0).animateLayout(bentoSpring(s.springs.layout))
    for v in s.m.visits {
        let fresh = v.id == newest
        let bar: El<MotionBentoState> = el()
            .key("visit\(v.id)")
            .grow(1.0)
            .w(0.0)
            .h(4.0 + (chartH - 4.0) * Float(v.count) / Float(ChaosConstants.visitMax))
            .rounded(3.0)
            .bg(bentoColor(fresh ? ChaosColor.good : lch(0.4, 0.06, 160.0)))
            .transition(Transition.scale(0.05, anchor: Vec2(0.5, 1.0)))
        chart = chart.child(bar)
    }

    let body: El<MotionBentoState> = col()
        .gap(4.0)
        .child(count)
        .child(bentoCaption("Unique visitors today"))
        .child(el().h(10.0))
        .child(chart)
    let live: El<MotionBentoState> = row()
        .gap(6.0)
        .centerY()
        .child(el().size(6.0, 6.0).rounded(3.0).bg(bentoColor(ChaosColor.good)))
        .child(bentoCaption("Live"))
    return (live, body)
}
