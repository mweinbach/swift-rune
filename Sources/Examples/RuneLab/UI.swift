import Foundation
import Rune
import RuneKit
import RuneMotion

private let sidebarW: Float = 212.0
private let panelW: Float = 272.0
private let pillInset: Float = 10.0
private let pillPad: Float = 10.0
private let textX: Float = pillInset + pillPad
private let pillW: Float = sidebarW - 2.0 * pillInset
private let rowH: Float = 28.0
private let rowPitch: Float = 30.0
private let pillR: Float = 8.0
private let groupH: Float = 28.0
private let groupGap: Float = 16.0
private let sliderW: Float = panelW - 40.0

private struct LabPalette {
    let base: Color
    let deep: Color
    let text: Color
    let muted: Color
    let faint: Color
    let accent: Color
    let border: Color
    let hover: Color
    let pressed: Color
    let selected: Color
    let track: Color
    let knob: Color
    let shadow: Color

    static let dark: LabPalette = {
        let k = Kit.neutral(dark: true)
        return LabPalette(
            base: k.c.bgBase,
            deep: k.c.bgDeep,
            text: k.c.textBase,
            muted: k.c.textWeak,
            faint: k.c.textWeak.alpha(0.65),
            accent: k.c.bgAccent,
            border: k.c.borderBase,
            hover: Color.white.alpha(0.05),
            pressed: Color.white.alpha(0.09),
            selected: k.c.layer02,
            track: k.c.layer03,
            knob: k.c.textBase,
            shadow: Color.black.alpha(0.30)
        )
    }()
}

private let bodyFont = TextStyle(size: 13.0, weight: 400.0)
private let labelFont = TextStyle(size: 12.5, weight: 500.0)
private let eyebrowFont = TextStyle(size: 11.0, weight: 600.0, letterSpacing: 0.4)
private let titleFont = TextStyle(size: 17.0, weight: 600.0)
private let valueFont = TextStyle(size: 11.5, weight: 500.0).mono()

func labView(_ s: LabState, _ cx: inout Cx<LabState>) -> El<LabState> {
    cx.reducedMotion(s.reduced)
    let p = LabPalette.dark
    let hair: Float = 1.0 / max(1.0, cx.pixelScale)

    return row()
        .key("window")
        .bg(p.deep)
        .wFull()
        .hFull()
        .child(sidebarView(s, p: p, hair: hair))
        .child(stageView(s))
        .child(panelView(s, p: p, hair: hair))
}

// MARK: - Sidebar

private func sidebarView(_ s: LabState, p: LabPalette, hair: Float) -> El<LabState> {
    let groups: [(String, [LabScene])] = [
        ("Light", Array(LabScene.allCases.prefix(5))),
        ("Effects", Array(LabScene.allCases.dropFirst(5))),
    ]

    var y: Float = 0
    var selY: Float = 0
    var items: [El<LabState>] = []

    for (g, group) in groups.enumerated() {
        if g > 0 { y += groupGap }
        items.append(
            row()
                .key("group\(g)")
                .absolute(x: 0, y: y)
                .size(sidebarW, groupH)
                .pl(textX)
                .itemsCenter()
                .child(text(group.0.uppercased()).key("label").font(eyebrowFont).color(p.faint))
        )
        y += groupH
        for sc in group.1 {
            let selected = sc == s.scene
            if selected { selY = y }
            items.append(
                row()
                    .key(sc.id)
                    .role(.tab)
                    .label(sc.title)
                    .absolute(x: pillInset, y: y)
                    .size(pillW, rowH)
                    .px(pillPad)
                    .itemsCenter()
                    .rounded(pillR)
                    .hover(selected ? .transparent : p.hover)
                    .press(p.pressed)
                    .onClick { state in state.select(sc) }
                    .child(text(sc.title).key("label").font(bodyFont).color(selected ? p.text : p.muted))
            )
            y += rowPitch
        }
    }

    let list: El<LabState> = el()
        .key("scenes")
        .wFull()
        .h(y)
        .child(
            el()
                .key("selection")
                .absolute(x: pillInset, y: selY)
                .size(pillW, rowH)
                .rounded(pillR)
                .bg(p.selected)
                .animateLayout(LayoutAnim.lead(lead: MotionTokens.LEAD, trail: MotionTokens.DEFAULT))
        )
        .children(items)

    return row()
        .key("sidebar-wrap")
        .hFull()
        .child(
            col()
                .key("sidebar")
                .w(sidebarW)
                .hFull()
                .bg(p.base)
                .child(
                    row()
                        .key("brand")
                        .h(52)
                        .wFull()
                        .pl(86)
                        .itemsCenter()
                        .child(text("Rune Lab").key("title").font(TextStyle(size: 13.0, weight: 600.0)).color(p.text))
                )
                .child(list)
                .child(el().grow(1))
                .child(
                    text("↑ ↓ to switch scenes")
                        .key("keys-hint")
                        .font(TextStyle(size: 11.5, weight: 400.0))
                        .color(p.faint)
                        .ml(textX)
                        .mb(16)
                )
        )
        .child(el().key("sidebar-edge").w(hair).hFull().bg(p.border))
}

// MARK: - Stage

private func stageView(_ s: LabState) -> El<LabState> {
    el()
        .key("stage")
        .role(.group)
        .grow(1)
        .hFull()
        .center()
        .bg(stageBackdrop(for: s.scene))
        .animate(Tok.Motion.DEFAULT)
        .clip(true)
        .onDrag(onStageDrag)
        .onDragEnd(onStageDragEnd)
        .child(stageCanvas(s, scene: s.scene))
}

// MARK: - Panel

private func panelView(_ s: LabState, p: LabPalette, hair: Float) -> El<LabState> {
    let sc = s.scene
    let specs = knobSpecs(for: sc)
    var knobsCol: El<LabState> = col().key("knobs-\(sc.id)").gap(18).wFull()
    for (i, k) in specs.enumerated() {
        knobsCol = knobsCol.child(knobControl(s, sc: sc, index: i, spec: k, p: p))
    }

    return row()
        .key("panel-wrap")
        .hFull()
        .child(el().key("panel-edge").w(hair).hFull().bg(p.border))
        .child(
            col()
                .key("panel")
                .w(panelW)
                .hFull()
                .bg(p.base)
                .px(20)
                .pt(48)
                .pb(20)
                .child(text(sc.title).key("scene-title").font(titleFont).color(p.text))
                .child(
                    text(sc.hint)
                        .key("scene-hint")
                        .w(panelW - 40)
                        .font(TextStyle(size: 12.5, weight: 400, lineHeight: 18))
                        .color(p.muted)
                        .mt(8)
                )
                .child(el().key("sep").h(hair).wFull().bg(p.border).mt(20).mb(20))
                .child(knobsCol)
                .child(el().grow(1))
                .child(el().key("sep2").h(hair).wFull().bg(p.border).mb(14))
                .child(toggleRow(key: "reduced", label: "Reduce motion", on: s.reduced, p: p) { state in
                    state.reduced.toggle()
                })
                .child(readoutView(s, p: p))
        )
}

private func readoutView(_ s: LabState, p: LabPalette) -> El<LabState> {
    func fmt(_ v: Float?) -> String {
        v.map { String(format: "%.2f ms", $0) } ?? "—"
    }
    func line(_ key: String, _ name: String, _ value: String) -> El<LabState> {
        row()
            .key(key)
            .h(20)
            .wFull()
            .itemsCenter()
            .justifyBetween()
            .child(text(name).key("name").font(TextStyle(size: 12.0, weight: 400.0)).color(p.faint))
            .child(text(value).key("value").font(valueFont).color(p.muted))
    }

    let stateStr = s.perf.live ? "Animating" : "At rest · no frames"
    return col()
        .key("readout")
        .mt(12)
        .gap(2)
        .child(line("gpu", "GPU frame", fmt(s.perf.gpuMs)))
        .child(line("cpu", "CPU frame", fmt(s.perf.cpuMs > 0 ? s.perf.cpuMs : nil)))
        .child(line("state", "Display link", stateStr))
}

private func knobControl(
    _ s: LabState,
    sc: LabScene,
    index: Int,
    spec: LabKnobSpec,
    p: LabPalette
) -> El<LabState> {
    let v = s.vals[sc.idx][index]
    switch spec.kind {
    case .slider(let dec):
        return sliderRow(sc: sc, index: index, spec: spec, value: v, decimals: dec, p: p)
    case .toggle:
        let on = v > 0.5
        return toggleRow(key: spec.id, label: spec.label, on: on, p: p) { state in
            let cur = state.vals[sc.idx][index]
            state.vals[sc.idx][index] = cur > 0.5 ? 0.0 : 1.0
        }
    case .swatch(let palette):
        return swatchRow(sc: sc, index: index, spec: spec, current: Int(v.rounded()), palette: palette, p: p)
    }
}

private func sliderRow(
    sc: LabScene,
    index: Int,
    spec: LabKnobSpec,
    value: Float,
    decimals: Int,
    p: LabPalette
) -> El<LabState> {
    let w = sliderW
    let h: Float = 18.0
    let kd: Float = 14.0
    let bar: Float = 4.0
    let travel = w - kd
    let minVal = spec.min
    let maxVal = spec.max
    let span = max(1e-5, maxVal - minVal)
    let u = min(max((value - minVal) / span, 0), 1)
    let formatted = String(format: "%.\(decimals)f", value)

    return col()
        .key(spec.id)
        .gap(6)
        .child(
            row()
                .key("head")
                .wFull()
                .justifyBetween()
                .child(text(spec.label).key("label").font(labelFont).color(p.text))
                .child(text(formatted).key("value").font(valueFont).color(p.muted))
        )
        .child(
            el()
                .key("slider")
                .role(.slider)
                .label(spec.label)
                .size(w, h)
                .onDrag { state, d, tx in
                    let norm = min(max((d.local.x - kd * 0.5) / travel, 0), 1)
                    state.vals[sc.idx][index] = minVal + norm * span
                    tx.settle()
                }
                .child(el().key("track").size(w, bar).absolute(x: 0, y: (h - bar) * 0.5).rounded(bar * 0.5).bg(p.track))
                .child(el().key("fill").size(kd * 0.5 + u * travel, bar).absolute(x: 0, y: (h - bar) * 0.5).rounded(bar * 0.5).bg(p.accent))
                .child(
                    el()
                        .key("knob")
                        .size(kd, kd)
                        .absolute(x: u * travel, y: (h - kd) * 0.5)
                        .rounded(kd * 0.5)
                        .bg(p.knob)
                        .shadow(Shadow(y: 1, blur: 3, color: p.shadow))
                )
        )
}

private func toggleRow(
    key: String,
    label: String,
    on: Bool,
    p: LabPalette,
    flip: @escaping (inout LabState) -> Void
) -> El<LabState> {
    let w: Float = 32.0
    let h: Float = 18.0
    let k: Float = 14.0
    let inset = (h - k) * 0.5

    return row()
        .key(key)
        .role(.switchControl)
        .label(label)
        .h(26)
        .wFull()
        .itemsCenter()
        .justifyBetween()
        .onClick(flip)
        .child(text(label).key("label").font(labelFont).color(p.text))
        .child(
            el()
                .key("switch")
                .size(w, h)
                .rounded(h * 0.5)
                .bg(on ? p.accent : p.track)
                .animate(Tok.Motion.SNAPPY)
                .child(
                    el()
                        .key("knob")
                        .size(k, k)
                        .absolute(x: on ? w - k - inset : inset, y: inset)
                        .rounded(k * 0.5)
                        .bg(p.knob)
                        .shadow(Shadow(y: 1, blur: 2, color: p.shadow))
                        .animateLayout(Tok.Motion.SNAPPY)
                )
        )
}

private func swatchRow(
    sc: LabScene,
    index: Int,
    spec: LabKnobSpec,
    current: Int,
    palette: [UInt32],
    p: LabPalette
) -> El<LabState> {
    let d: Float = 16.0
    let gap: Float = 10.0
    let ringW: Float = 1.5
    let ring = d + 2.0 * (ringW + 2.0)

    var children: [El<LabState>] = [
        el()
            .key("ring")
            .size(ring, ring)
            .absolute(x: Float(current) * (d + gap) - (ring - d) * 0.5, y: -(ring - d) * 0.5)
            .rounded(ring * 0.5)
            .border(ringW, p.text)
            .animateLayout(LayoutAnim.lead(lead: Spring(duration: 0.22, bounce: 0), trail: Spring(duration: 0.28, bounce: 0)))
    ]

    for (j, hex) in palette.enumerated() {
        let c = Color.rgba8(
            UInt8((hex >> 16) & 0xFF),
            UInt8((hex >> 8) & 0xFF),
            UInt8(hex & 0xFF)
        )
        children.append(
            el()
                .key("c\(j)")
                .role(.button)
                .size(d, d)
                .rounded(d * 0.5)
                .bg(c)
                .onClick { state in state.vals[sc.idx][index] = Float(j) }
        )
    }

    return col()
        .key(spec.id)
        .gap(10)
        .child(text(spec.label).key("label").font(labelFont).color(p.text))
        .child(row().key("swatches").gap(gap).children(children))
}
