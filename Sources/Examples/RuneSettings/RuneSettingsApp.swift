import Foundation
import Rune
import RuneMotion

enum Appearance: Sendable, Equatable {
    case auto
    case light
    case dark
}

struct SettingsState: Sendable {
    var appearance: Appearance = .auto
    var accent: Int = 0
    var launchAtLogin: Bool = true
    var menuBar: Bool = true
    var sounds: Bool = false
    /// Slider position 0..1; animation speed is 2^(2v - 1), so the middle is 1x.
    var speed: Float = 0.5
    var reduceMotion: Bool = false
    /// Pre-drag slider value (Swift bridge for Rust `Drag::data`).
    var dragStartSpeed: Float? = nil
}

func speedOf(_ v: Float) -> Float {
    powf(2.0, v * 2.0 - 1.0)
}

private struct SettingsPaint {
    let t: ThemeTokens
    let accent: Color
    let hair: Float
}

private let appearances: [(Appearance, String)] = [
    (.auto, "Auto"),
    (.light, "Light"),
    (.dark, "Dark"),
]

private let accentNames: [String] = [
    "blue",
    "purple",
    "pink",
    "orange",
    "green",
    "graphite",
]

func settingsView(_ s: SettingsState, _ cx: inout Cx<SettingsState>) -> El<SettingsState> {
    let dark: Bool = switch s.appearance {
    case .auto: cx.systemDark
    case .light: false
    case .dark: true
    }
    cx.reducedMotion(s.reduceMotion)
    cx.timeScale(speedOf(s.speed))
    let p = SettingsPaint(
        t: Tok.theme(dark: dark),
        accent: Tok.accent(s.accent, dark: dark),
        hair: 1.0 / max(1.0, cx.pixelScale)
    )
    let t = p.t

    return col()
        .key("window")
        .bg(t.bg)
        .wFull()
        .hFull()
        .child(
            row()
                .key("titlebar")
                .h(40)
                .wFull()
                .center()
                .child(text("Settings").key("title").font(Tok.Typography.title).color(t.text))
        )
        .child(
            col()
                .key("content")
                .grow(1)
                .px(Tok.Space.xl)
                .pt(Tok.Space.xs)
                .pb(Tok.Space.xl)
                .gap(Tok.Space.xl)
                .clipFade(left: 0, top: Tok.Space.xs, right: 0, bottom: Tok.Space.xl)
                .child(
                    section(
                        p,
                        key: "appearance",
                        title: "Appearance",
                        rows: [
                            settingRow(p, key: "theme", label: "Theme", onPress: nil, control: segmented(p, current: s.appearance)),
                            settingRow(p, key: "accent", label: "Accent colour", onPress: nil, control: swatches(p, current: s.accent, dark: dark)),
                        ]
                    )
                )
                .child(
                    section(
                        p,
                        key: "general",
                        title: "General",
                        rows: [
                            toggleRow(p, key: "login", label: "Launch at login", on: s.launchAtLogin) {
                                $0.launchAtLogin.toggle()
                            },
                            toggleRow(p, key: "menubar", label: "Show in menu bar", on: s.menuBar) {
                                $0.menuBar.toggle()
                            },
                            toggleRow(p, key: "sounds", label: "Play sounds", on: s.sounds) {
                                $0.sounds.toggle()
                            },
                        ]
                    )
                )
                .child(
                    section(
                        p,
                        key: "motion",
                        title: "Motion",
                        rows: [
                            settingRow(p, key: "speed", label: "Animation speed", onPress: nil, control: speedControl(p, v: s.speed)),
                            toggleRow(p, key: "reduce", label: "Reduce motion", on: s.reduceMotion) {
                                $0.reduceMotion.toggle()
                            },
                        ]
                    )
                )
        )
}

private func section(
    _ p: SettingsPaint,
    key: String,
    title: String,
    rows: [El<SettingsState>]
) -> El<SettingsState> {
    var card: El<SettingsState> = col()
        .key("card")
        .p(Tok.Space.xs)
        .bg(p.t.card)
        .rounded(Tok.Radius.lg)
        .border(p.hair, p.t.cardBorder)
        .shadow(Shadow(x: 0, y: 1, blur: 2, color: p.t.shadow))
        .shadow(Shadow(x: 0, y: 8, blur: 24, color: p.t.shadowSoft))

    for (i, r) in rows.enumerated() {
        card = card.child(r)
        if i + 1 < rows.count {
            card = card.child(
                el()
                    .key("sep\(i)")
                    .h(p.hair)
                    .ml(Tok.Space.md)
                    .mr(Tok.Space.md)
                    .bg(p.t.separator)
            )
        }
    }

    return col()
        .key(key)
        .gap(Tok.Space.sm)
        .child(
            text(title)
                .key("header")
                .font(Tok.Typography.section)
                .color(p.t.textSecondary)
                .ml(Tok.Space.md)
        )
        .child(card)
}

private func settingRow(
    _ p: SettingsPaint,
    key: String,
    label labelText: String,
    onPress: ((inout SettingsState) -> Void)?,
    control: El<SettingsState>
) -> El<SettingsState> {
    var r: El<SettingsState> = row()
        .key(key)
        .h(44)
        .px(Tok.Space.md)
        .centerY()
        .justifyBetween()
        .rounded(Tok.Radius.md)
        .label(labelText)
        .child(text(labelText).key("label").font(Tok.Typography.body).color(p.t.text))
        .child(control)
    if let onPress {
        r = r.hover(p.t.hover).press(p.t.press).focusable(true).onClick(onPress)
    }
    return r
}

private func toggleRow(
    _ p: SettingsPaint,
    key: String,
    label labelText: String,
    on: Bool,
    flip: @escaping (inout SettingsState) -> Void
) -> El<SettingsState> {
    settingRow(p, key: key, label: labelText, onPress: flip, control: toggleControl(p, on: on))
        .role(.switchControl)
        .selected(on ? "true" : "false")
}

private func toggleControl(_ p: SettingsPaint, on: Bool) -> El<SettingsState> {
    let w: Float = 38
    let h: Float = 22
    let k: Float = 18
    let inset = (h - k) / 2.0
    return el()
        .key("switch")
        .role(.switchControl)
        .size(w, h)
        .rounded(h / 2.0)
        .bg(on ? p.accent : p.t.controlOff)
        .animate(Tok.Motion.SNAPPY)
        .child(
            el()
                .key("knob")
                .size(k, k)
                .absolute(x: on ? (w - k - inset) : inset, y: inset)
                .rounded(k / 2.0)
                .bg(p.t.knob)
                .animateLayout(Tok.Motion.SNAPPY)
                .shadow(Shadow(x: 0, y: 1, blur: 3, color: p.t.knobShadow))
                .shadow(Shadow(x: 0, y: 0, blur: 0.5, color: p.t.edge))
        )
}

private func segmented(_ p: SettingsPaint, current: Appearance) -> El<SettingsState> {
    let w: Float = 205
    let h: Float = 28
    let pad: Float = 2
    let seg = (w - 2 * pad) / 3.0
    let idx = appearances.firstIndex { $0.0 == current } ?? 0

    var segs: El<SettingsState> = row().key("segments")
    for (i, (appearance, name)) in appearances.enumerated() {
        let isSelected = i == idx
        segs = segs.child(
            El<SettingsState>()
                .key(name)
                .role(.tab)
                .label(name)
                .selected(isSelected ? "true" : "false")
                .focusable(true)
                .size(seg, h - 2 * pad)
                .center()
                .rounded(Tok.Radius.sm)
                .hover(isSelected ? .transparent : p.t.hover)
                .onClick { state in
                    state.appearance = appearance
                }
                .child(
                    text(name)
                        .key("label")
                        .font(Tok.Typography.label)
                        .color(isSelected ? p.t.text : p.t.textSecondary)
                )
        )
    }

    return el()
        .key("segmented")
        .role(.group)
        .size(w, h)
        .p(pad)
        .rounded(Tok.Radius.md)
        .bg(p.t.controlTrack)
        .animate(Tok.Motion.SNAPPY)
        .child(
            el()
                .key("indicator")
                .size(seg, h - 2 * pad)
                .absolute(x: pad + Float(idx) * seg, y: pad)
                .rounded(Tok.Radius.sm)
                .bg(p.t.indicator)
                .shadow(Shadow(x: 0, y: 1, blur: 3, color: p.t.shadow))
                .shadow(Shadow(x: 0, y: 0, blur: 0.5, color: p.t.edge))
                .animateLayout(LayoutAnim.lead(lead: MotionTokens.LEAD, trail: Tok.Motion.DEFAULT))
        )
        .child(segs)
}

private func swatches(_ p: SettingsPaint, current: Int, dark: Bool) -> El<SettingsState> {
    let d: Float = 18
    let gap: Float = 12
    let ringW: Float = 2
    let ring = d + 2 * (ringW + 2)

    var r: El<SettingsState> = row()
        .key("swatches")
        .role(.group)
        .label("Accent colour")
        .gap(gap)
        .child(
            el()
                .key("ring")
                .size(ring, ring)
                .absolute(
                    x: Float(current) * (d + gap) - (ring - d) / 2.0,
                    y: -(ring - d) / 2.0
                )
                .rounded(ring / 2.0)
                .border(ringW, p.accent)
                .animateLayout(
                    LayoutAnim.lead(
                        lead: Spring(duration: 0.22, bounce: 0.0),
                        trail: Spring(duration: 0.28, bounce: 0.0)
                    )
                )
        )

    for i in 0..<6 {
        let name = accentNames[i]
        r = r.child(
            El<SettingsState>()
                .key(name)
                .role(.radio)
                .label(name)
                .selected(i == current ? "true" : "false")
                .focusable(true)
                .size(d, d)
                .rounded(d / 2.0)
                .bg(Tok.accent(i, dark: dark))
                .border(p.hair, Color.black.alpha(dark ? 0.0 : 0.08))
                .onClick { state in
                    state.accent = i
                }
        )
    }
    return r
}

private func speedControl(_ p: SettingsPaint, v: Float) -> El<SettingsState> {
    let w: Float = 180
    let h: Float = 22
    let k: Float = 18
    let bar: Float = 4
    let travel = w - k
    let toValue: (Float) -> Float = { x in
        min(1.0, max(0.0, (x - k / 2.0) / travel))
    }

    return row()
        .key("speed-control")
        .gap(Tok.Space.md)
        .centerY()
        .child(
            el()
                .key("slider")
                .role(.slider)
                .label("Animation speed")
                .size(w, h)
                .onDrag { s, d, tx in
                    if s.dragStartSpeed == nil {
                        s.dragStartSpeed = s.speed
                        let knob = k / 2.0 + s.speed * travel
                        if abs(d.local.x - knob) > k / 2.0 + 2.0 {
                            s.speed = toValue(d.local.x)
                        }
                    } else {
                        let initial = s.dragStartSpeed ?? s.speed
                        let knob = k / 2.0 + initial * travel
                        let grab = abs(d.startLocal.x - knob) <= k / 2.0 + 2.0 ? (d.startLocal.x - knob) : 0.0
                        s.speed = toValue(d.local.x - grab)
                        tx.settle()
                    }
                }
                .onDragEnd { s, cancelled, _ in
                    let start = s.dragStartSpeed
                    s.dragStartSpeed = nil
                    if cancelled, let start {
                        s.speed = start
                    }
                }
                .child(
                    el()
                        .key("track")
                        .size(w, bar)
                        .absolute(x: 0, y: (h - bar) / 2.0)
                        .rounded(bar / 2.0)
                        .bg(p.t.controlOff)
                )
                .child(
                    el()
                        .key("fill")
                        .size(k / 2.0 + v * travel, bar)
                        .absolute(x: 0, y: (h - bar) / 2.0)
                        .rounded(bar / 2.0)
                        .bg(p.accent)
                        .animateLayout(Tok.Motion.SNAPPY)
                )
                .child(
                    el()
                        .key("knob")
                        .size(k, k)
                        .absolute(x: v * travel, y: (h - k) / 2.0)
                        .rounded(k / 2.0)
                        .bg(p.t.knob)
                        .animateLayout(Tok.Motion.SNAPPY)
                        .shadow(Shadow(x: 0, y: 1, blur: 3, color: p.t.knobShadow))
                        .shadow(Shadow(x: 0, y: 0, blur: 0.5, color: p.t.edge))
                )
        )
        .child(
            text(String(format: "%.2f×", speedOf(v)))
                .key("value")
                .w(40)
                .font(Tok.Typography.monoCaption)
                .color(p.t.textSecondary)
                .textAlign(.trailing)
        )
}

@main
enum RuneSettingsApp {
    static func makeSpec() -> AppSpec<SettingsState> {
        AppSpec(
            title: "Settings",
            size: Vec2(620, 520),
            state: SettingsState(),
            view: settingsView
        )
        .scene("default") { _ in }
        .scene("light") { $0.appearance = .light }
        .scene("dark") { $0.appearance = .dark }
        .scene("reduced-motion") { $0.reduceMotion = true }
        .scene("toggles-off") {
            $0.launchAtLogin = false
            $0.menuBar = false
            $0.sounds = false
        }
        .scene("accent-pink") { $0.accent = 2 }
        .scene("slow") { $0.speed = 0.0 }
    }

    static func main() throws {
        try RuneApp.run(makeSpec())
    }
}
