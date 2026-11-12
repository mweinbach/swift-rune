import Foundation
import Rune
import RuneKit

/// Port of `examples/settings`: full macOS-style Appearance, Accent, Motion & Editor settings panel
/// showcasing `RuneKit` (`Kit.fromPalette`, `segmentedControl`, `switchControl`, `slider`, `collapsible`).
enum AppearanceMode: String, CustomStringConvertible {
    case dark = "Dark"
    case light = "Light"
    case system = "Auto"
    var description: String { rawValue }
}

struct SettingsState {
    var appearance: AppearanceMode = .dark
    var accentIndex: Int = 0
    var fontSize: Float = 14.0
    var smoothScrolling: Bool = true
    var springAnimations: Bool = true
    var showAdvanced: Bool = false
    var profileName = TextEdit("Anomaly Engineer")
}

func settingsView(_ s: SettingsState, _ cx: inout Cx<SettingsState>) -> El<SettingsState> {
    let isDark: Bool = {
        switch s.appearance {
        case .dark: return true
        case .light: return false
        case .system: return cx.systemDark
        }
    }()

    let accent = Tok.accent(s.accentIndex, dark: isDark)
    let bg = isDark ? Color.hex("#111318")! : Color.hex("#f7f8fa")!
    let fg = isDark ? Color.hex("#f1f3f5")! : Color.hex("#181a1f")!
    let kit = Kit.fromPalette(PaletteSeed(bg: bg, fg: fg, accent: accent), focus: .accent)

    let accentSwatches: El<SettingsState> = row()
        .key("accent-swatches")
        .gap(10)
        .itemsCenter()
        .children((0..<6).map { idx -> El<SettingsState> in
            let colSwatch = Tok.accent(idx, dark: isDark)
            let selected = (s.accentIndex == idx)
            return row()
                .key("swatch-\(idx)")
                .square(24)
                .center()
                .pill()
                .bg(colSwatch)
                .border(selected ? 2.5 : 0, kit.c.textBase)
                .pressScale(0.92)
                .onClick { state in state.accentIndex = idx }
        })

    let appearanceCard: El<SettingsState> = kit.card(
        key: "appearance-card",
        col()
            .wFull()
            .gap(14)
            .child(
                row().wFull().itemsCenter().justifyBetween()
                    .child(text("Appearance").font(kit.ty.uiMedium).color(kit.c.textBase))
                    .child(
                        kit.segmentedControl(
                            key: "theme-seg",
                            options: [(.dark, "Dark"), (.light, "Light"), (.system, "Auto")],
                            selected: s.appearance
                        ) { state, picked in state.appearance = picked }
                        .w(210)
                    )
            )
            .child(kit.divider())
            .child(
                row().wFull().itemsCenter().justifyBetween()
                    .child(text("Accent Color").font(kit.ty.uiMedium).color(kit.c.textBase))
                    .child(accentSwatches)
            )
    )

    let generalCard: El<SettingsState> = kit.card(
        key: "general-card",
        col()
            .wFull()
            .gap(14)
            .child(
                kit.field(
                    label: "Display Name",
                    description: "Shown on local snapshots and trace headers.",
                    control: kit.textInputField(key: "profile-input", \.profileName, placeholder: "Your name")
                )
            )
            .child(kit.divider())
            .child(
                row().wFull().itemsCenter().justifyBetween()
                    .child(
                        col().gap(2)
                            .child(text("UI Font Scale (\(Int(s.fontSize.rounded())) pt)").font(kit.ty.uiMedium).color(kit.c.textBase))
                            .child(text("Drag slider or press Escape while dragging to revert").font(kit.ty.small).color(kit.c.textMuted))
                    )
                    .child(
                        kit.slider(key: "font-slider", value: s.fontSize, range: 11...20, width: 180) { state, val in
                            state.fontSize = val
                        }
                    )
            )
            .child(kit.divider())
            .child(
                row().wFull().itemsCenter().justifyBetween()
                    .child(text("Inertial Smooth Scrolling").font(kit.ty.uiMedium).color(kit.c.textBase))
                    .child(
                        kit.switchControl(key: "scroll-switch", isOn: s.smoothScrolling, label: "Smooth Scrolling") { state, on in
                            state.smoothScrolling = on
                        }
                    )
            )
            .child(
                row().wFull().itemsCenter().justifyBetween()
                    .child(text("Analytic Spring Motion").font(kit.ty.uiMedium).color(kit.c.textBase))
                    .child(
                        kit.switchControl(key: "spring-switch", isOn: s.springAnimations, label: "Spring Motion") { state, on in
                            state.springAnimations = on
                        }
                    )
            )
    )

    let advancedSection: El<SettingsState> = kit.card(
        key: "advanced-card",
        padding: 8,
        kit.collapsible(
            key: "adv-disclosure",
            title: "Diagnostics & Renderer Info",
            isOpen: s.showAdvanced,
            onToggle: { state, open in state.showAdvanced = open }
        ) {
            col().wFull().pt(6).gap(6)
                .child(text("Backend: Instanced Uber-Quad Metal + RuneRef Scalar Reference").font(kit.ty.mono).color(kit.c.textMuted))
                .child(text("Color Space: Premultiplied OKLab Motion + Linear sRGB Blending").font(kit.ty.mono).color(kit.c.textMuted))
        }
    )

    return col()
        .sizeFull()
        .bg(kit.c.page)
        .child(kit.toolbar(title: "Settings", trailing: kit.badge("swift-rune", tone: .accent)))
        .child(
            col()
                .key("settings-scroll")
                .wFull()
                .grow(1)
                .minH(0)
                .p(24)
                .gap(16)
                .scroll()
                .child(appearanceCard)
                .child(generalCard)
                .child(advancedSection)
        )
}

let spec = AppSpec<SettingsState>(
    title: "Rune Settings",
    size: Vec2(560, 580),
    state: SettingsState(),
    view: settingsView
)
.scene("light") {
    $0.appearance = .light
    $0.accentIndex = 3
    $0.showAdvanced = true
}
.scene("dark") {
    $0.appearance = .dark
    $0.accentIndex = 0
}

try RuneApp.run(spec)
