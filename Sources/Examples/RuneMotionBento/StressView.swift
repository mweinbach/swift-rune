import Foundation
import Rune
import RuneMotion

private let switchOff = lch(0.44, 0.012, 258.0)
private let knobColor = lch(0.98, 0.0, 0.0)
private let overColor = lch(0.66, 0.2, 25.0)
private let hudW: Float = 660.0
private let graphW: Float = 300.0
private let graphH: Float = 92.0

private func gradeColor(_ ms: Float) -> Lch {
    [ChaosColor.good, ChaosColor.warm, overColor][chaosGrade(ms)]
}

public final class StressHudLive: @unchecked Sendable {
    public private(set) var source: String = ""
    public let big = LiveText("")
    public let bigColor = Live<Color>(bentoColor(ChaosColor.good))
    public let detail = LiveText("")
    public let rate = LiveText("")
    public let bars: [(Live<MotionRect>, Live<Color>)]

    public init() {
        self.bars = (0..<ChaosHudConstants.graph).map { _ in
            (Live<MotionRect>(.zero), Live<Color>(bentoColor(ChaosColor.good)))
        }
    }

    public func set(_ r: ChaosReadout) {
        source = r.source
        big.set(r.big)
        bigColor.set(bentoColor(gradeColor(r.ms)))
        detail.set(r.detail)
        rate.set(r.rate)
        let bw = graphW / Float(ChaosHudConstants.graph)
        for (i, (rect, fill)) in bars.enumerated() {
            let ms = i < r.graph.count ? r.graph[i] : 0.0
            let h = min(ms / ChaosHudConstants.graphMax, 1.0) * graphH
            rect.set(.fromXYWH(Float(i) * bw, graphH - h, bw, h))
            fill.set(bentoColor(gradeColor(ms)))
        }
    }

    public func view() -> El<MotionBentoState> {
        var graphBars: El<MotionBentoState> = el().size(graphW, graphH).absolute(x: 0.0, y: 0.0)
        for (rect, fill) in bars {
            graphBars = graphBars.child(
                el()
                    .absolute(x: 0.0, y: 0.0)
                    .size(0.0, 0.0)
                    .bg(bentoColor(ChaosColor.good))
                    .liveFill(fill.binding)
                    .liveRect(rect.binding)
            )
        }
        func budgetLine(_ ms: Float, _ col: Lch) -> El<MotionBentoState> {
            el().size(graphW, 1.0).absolute(x: 0.0, y: graphH - ms / ChaosHudConstants.graphMax * graphH).bg(bentoColor(col))
        }
        func budgetLabel(_ ms: Float, _ label: String) -> El<MotionBentoState> {
            text(label)
                .font(bentoNums(10.0, 560.0))
                .color(bentoColor(ChaosColor.text2))
                .absolute(x: graphW + 6.0, y: graphH - ms / ChaosHudConstants.graphMax * graphH - 7.0)
        }
        let graphBox = el()
            .size(graphW + 40.0, graphH)
            .child(el().size(graphW, graphH).absolute(x: 0.0, y: 0.0).rounded(4.0).bg(bentoColor(ChaosColor.well)))
            .child(graphBars)
            .child(budgetLine(ChaosHudConstants.budget120, ChaosColor.accent))
            .child(budgetLine(ChaosHudConstants.budget60, overColor))
            .child(budgetLabel(ChaosHudConstants.budget120, "120 Hz"))
            .child(budgetLabel(ChaosHudConstants.budget60, "60 Hz"))

        return row()
            .key("hud")
            .absolute(x: ChaosGrid.width - ChaosGrid.pad - hudW, y: ChaosGrid.pad - 8.0)
            .size(hudW, ChaosStress.header)
            .p(12.0)
            .gap(14.0)
            .rounded(14.0)
            .bg(bentoColor(ChaosColor.tile))
            .border(1.0, bentoColor(ChaosColor.accent.alpha(0.4)))
            .z(1)
            .child(
                col()
                    .w(hudW - graphW - 40.0 - 14.0 - 24.0)
                    .gap(1.0)
                    .child(bentoCaption("Rune · \(source)"))
                    .child(liveText(big).font(bentoNums(36.0, 700.0)).color(bentoColor(ChaosColor.good)))
                    .child(liveText(detail).font(bentoNums(11.0, 500.0)).color(bentoColor(ChaosColor.text2)))
                    .child(liveText(rate).font(bentoNums(11.0, 500.0)).color(bentoColor(ChaosColor.text2)))
            )
            .child(graphBox)
    }
}

public func bentoStressView(_ s: MotionBentoState, _ wall: ChaosWall) -> El<MotionBentoState> {
    var root = el()
        .w(ChaosGrid.width)
        .h(ChaosGrid.height)
        .bg(bentoColor(ChaosColor.bg))
        .child(stressHeader(s, wall))
    for cell in wall.cells {
        root = root.child(stressControl(s, cell, wall.metrics))
    }
    if let r = s.readout {
        root = root.child(stressHudNaive(r))
    }
    return root
}

private func stressHeader(_ s: MotionBentoState, _ wall: ChaosWall) -> El<MotionBentoState> {
    let load = s.config.load
    let steps = load?.levels.count ?? 1
    let step = load?.stepAt(s.t) ?? 0
    let n = wall.cells.count
    return col()
        .absolute(x: ChaosGrid.pad, y: ChaosGrid.pad - 8.0)
        .size(ChaosGrid.width - 2.0 * ChaosGrid.pad - hudW - ChaosGrid.gap, ChaosStress.header)
        .gap(4.0)
        .child(
            row()
                .gap(10.0)
                .centerY()
                .child(text("Rune").font(bentoFont(24.0, 680.0)).color(bentoColor(ChaosColor.accent)))
                .child(text("stress wall").font(bentoFont(24.0, 680.0)).color(bentoColor(ChaosColor.text)))
        )
        .child(bentoCaption(String(format: "Seed %llu · every control retargets, ticks and reflows at once · t %.2f s", s.config.seed, s.t)))
        .child(
            row()
                .gap(10.0)
                .itemsEnd()
                .child(text("\(n)").font(bentoNums(40.0, 700.0)).color(bentoColor(ChaosColor.text)))
                .child(text("live controls").font(bentoFont(16.0, 560.0)).color(bentoColor(ChaosColor.text2)))
                .child(bentoCaption("step \(step + 1) of \(steps) · \(wall.cols)×\(wall.rows) grid"))
        )
}

private func stressControl(_ s: MotionBentoState, _ cell: ChaosCell, _ m: ChaosMetrics) -> El<MotionBentoState> {
    let x = cell.rect[0]
    let y = cell.rect[1]
    let w = cell.rect[2]
    let h = cell.rect[3]
    let tint = ChaosStress.tint(cell.hue)
    let (fill, edge) = cell.hot ? (ChaosStress.hotFill(cell.hue), ChaosStress.hotEdge(cell.hue)) : (ChaosColor.tile, ChaosColor.edge)
    let travel = bentoSpring(s.springs.travel)
    let snap = bentoSpring(s.springs.snap)
    var bars: El<MotionBentoState> = row().wFull().h(m.barsH).gap(m.barGap).itemsEnd()
    for b in cell.bars {
        let bar: El<MotionBentoState> = el()
            .grow(1.0)
            .h(b * m.barsH)
            .rounded(2.0 * m.u)
            .linearGradient(top: bentoColor(ChaosStress.tintHi(cell.hue)), bottom: bentoColor(ChaosStress.tintLo(cell.hue)))
            .animateLayout(travel)
        bars = bars.child(bar)
    }
    let inset = (m.switchH - m.knob) / 2.0
    let sw: El<MotionBentoState> = el()
        .size(m.switchW, m.switchH)
        .rounded(m.switchH / 2.0)
        .bg(bentoColor(cell.on ? tint : switchOff))
        .animate(snap)
        .child(
            el()
                .size(m.knob, m.knob)
                .absolute(x: cell.on ? m.switchW - inset - m.knob : inset, y: inset)
                .rounded(m.knob / 2.0)
                .bg(bentoColor(knobColor))
                .animate(snap)
                .animateLayout(snap)
        )
    let track: El<MotionBentoState> = el()
        .grow(1.0)
        .h(m.trackH)
        .rounded(m.trackH / 2.0)
        .bg(bentoColor(ChaosColor.well))
        .child(el().wFrac(cell.progress).h(m.trackH).rounded(m.trackH / 2.0).bg(bentoColor(tint)))

    let footRow: El<MotionBentoState> = row()
        .h(m.footH)
        .gap(m.gap)
        .centerY()
        .child(track)
        .child(sw)

    let headRow: El<MotionBentoState> = row()
        .h(ChaosStress.lh(m.name))
        .gap(m.gap)
        .centerY()
        .child(
            el()
                .size(m.dot, m.dot)
                .rounded(m.dot / 2.0)
                .bg(bentoColor(tint))
                .shadow(Shadow(y: 0.0, blur: 2.0 * m.dot, color: bentoColor(tint.alpha(0.8))))
        )
        .child(text(cell.name).font(bentoFont(m.name, 520.0)).color(bentoColor(ChaosColor.text2)))
        .child(spacer())
        .child(text(cell.status).font(bentoFont(m.small, 600.0)).color(bentoColor(tint)))

    let readingRow: El<MotionBentoState> = row()
        .h(ChaosStress.lh(m.reading))
        .centerY()
        .child(text(cell.reading).font(bentoNums(m.reading, 700.0)).color(bentoColor(ChaosColor.text)))
        .child(spacer())
        .child(text(cell.percent).font(bentoNums(m.small, 580.0)).color(bentoColor(ChaosColor.text2)))

    return col()
        .key("z\(cell.id)")
        .absolute(x: x, y: y)
        .size(w, h)
        .p(m.pad)
        .gap(m.gap)
        .rounded(m.radius)
        .bg(bentoColor(fill))
        .border(1.0, bentoColor(edge))
        .shadow(Shadow(y: m.shadowY, blur: m.shadowBlur, color: bentoColor(lch(0.0, 0.0, 0.0).alpha(0.35))))
        .clip(true)
        .animateLayout(bentoSpring(s.springs.layout))
        .transition(Transition.scale(0.85).combined(with: .opacity))
        .child(headRow)
        .child(readingRow)
        .child(bars)
        .child(footRow)
}

private func stressHudNaive(_ r: ChaosReadout) -> El<MotionBentoState> {
    let bw = graphW / Float(ChaosHudConstants.graph)
    var graphBars: El<MotionBentoState> = el().size(graphW, graphH).absolute(x: 0.0, y: 0.0)
    for (i, ms) in r.graph.enumerated() {
        let h = min(ms / ChaosHudConstants.graphMax, 1.0) * graphH
        graphBars = graphBars.child(
            el()
                .size(bw, h)
                .absolute(x: Float(i) * bw, y: graphH - h)
                .bg(bentoColor(gradeColor(ms)))
        )
    }
    func budgetLine(_ ms: Float, _ col: Lch) -> El<MotionBentoState> {
        el().size(graphW, 1.0).absolute(x: 0.0, y: graphH - ms / ChaosHudConstants.graphMax * graphH).bg(bentoColor(col))
    }
    func budgetLabel(_ ms: Float, _ label: String) -> El<MotionBentoState> {
        text(label)
            .font(bentoNums(10.0, 560.0))
            .color(bentoColor(ChaosColor.text2))
            .absolute(x: graphW + 6.0, y: graphH - ms / ChaosHudConstants.graphMax * graphH - 7.0)
    }
    let graphBox = el()
        .size(graphW + 40.0, graphH)
        .child(el().size(graphW, graphH).absolute(x: 0.0, y: 0.0).rounded(4.0).bg(bentoColor(ChaosColor.well)))
        .child(graphBars)
        .child(budgetLine(ChaosHudConstants.budget120, ChaosColor.accent))
        .child(budgetLine(ChaosHudConstants.budget60, overColor))
        .child(budgetLabel(ChaosHudConstants.budget120, "120 Hz"))
        .child(budgetLabel(ChaosHudConstants.budget60, "60 Hz"))

    return row()
        .key("hud")
        .absolute(x: ChaosGrid.width - ChaosGrid.pad - hudW, y: ChaosGrid.pad - 8.0)
        .size(hudW, ChaosStress.header)
        .p(12.0)
        .gap(14.0)
        .rounded(14.0)
        .bg(bentoColor(ChaosColor.tile))
        .border(1.0, bentoColor(ChaosColor.accent.alpha(0.4)))
        .z(1)
        .child(
            col()
                .w(hudW - graphW - 40.0 - 14.0 - 24.0)
                .gap(1.0)
                .child(bentoCaption("Rune · \(r.source)"))
                .child(text(r.big).font(bentoNums(36.0, 700.0)).color(bentoColor(gradeColor(r.ms))))
                .child(text(r.detail).font(bentoNums(11.0, 500.0)).color(bentoColor(ChaosColor.text2)))
                .child(text(r.rate).font(bentoNums(11.0, 500.0)).color(bentoColor(ChaosColor.text2)))
        )
        .child(graphBox)
}
