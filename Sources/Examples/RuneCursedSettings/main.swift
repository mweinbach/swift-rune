import Foundation
import OpenCodeTheme
import Rune
import RuneFX
import RuneKit
import RuneLight
import RuneMotion

/// Port of `examples/cursed-settings`: a believable OpenCode-styled settings window
/// where every control does exactly what its label says (Firewall builds a wall of fire,
/// Electric Fence electrifies the perimeter, Dark turns the lights off, Spotlight casts
/// a beam from Search, Hot reload heats up and emits embers, Flush cache drains the list).
enum CursedPage: Int, CaseIterable, CustomStringConvertible {
    case general = 0
    case appearance = 1
    case network = 2
    case security = 3
    case accessibility = 4
    case developer = 5

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .network: return "Network"
        case .security: return "Security"
        case .accessibility: return "Accessibility"
        case .developer: return "Developer"
        }
    }

    var id: String { title.lowercased() }
    var description: String { title }

    var icon: SVGIcon {
        switch self {
        case .general: return CursedIcons.settingsGear
        case .appearance: return CursedIcons.sun
        case .network: return CursedIcons.globe
        case .security: return CursedIcons.shield
        case .accessibility: return CursedIcons.personCircle
        case .developer: return CursedIcons.console
        }
    }
}

enum AppearancePick: Int, CaseIterable, CustomStringConvertible {
    case light = 0
    case dark = 1
    case auto = 2

    var description: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .auto: return "Auto"
        }
    }
}

enum HapticsPick: Int, CaseIterable, CustomStringConvertible {
    case off = 0
    case light = 1
    case strong = 2

    var description: String {
        switch self {
        case .off: return "Off"
        case .light: return "Light"
        case .strong: return "Strong"
        }
    }
}

struct Prefs {
    var launchAtLogin: Bool = true
    var fastStartup: Bool = false
    var spotlight: Bool = false
    var autoUpdate: Bool = true
    var appearance: AppearancePick = .auto
    var brightness: Float = 1.0
    var firewall: Bool = false
    var stealth: Bool = false
    var staticIP: Bool = false
    var fence: Bool = false
    var lockOnSleep: Bool = true
    var contrast: Bool = false
    var reduceTransparency: Bool = false
    var reduceMotion: Bool = false
    var haptics: HapticsPick = .light
    var hotReload: Bool = false
    var flushed: Bool = false
}

struct CursedState {
    var page: CursedPage = .general
    var p = Prefs()
    var search = TextEdit("")
    var ip = TextEdit("192.168.1.42")
    var taps: Int = 0
    var flushRequested: Bool = false
    var flushT0: Double? = nil
    var toastUntil: Double? = nil
    var now: Double = 0.0
    var langOpen: Bool = false
    var lang: String = "English"
    var textSizeOpen: Bool = false
    var textSize: String = "13 pt"
    var codeFontOpen: Bool = false
    var codeFont: String = "IBM Plex Mono"
    var brightnessBeforeDrag: Float = 1.0

    mutating func restore() {
        p = Prefs()
        flushRequested = false
        flushT0 = nil
        toastUntil = now + 4.5
        taps += 1
    }
}

private let sidebarW: Float = 232.0
private let navPitch: Float = 30.0
private let navH: Float = 28.0

private func isDarkTheme(_ s: CursedState, systemDark: Bool) -> Bool {
    switch s.p.appearance {
    case .light: return false
    case .dark: return true
    case .auto: return systemDark
    }
}

private func sectionCard(
    _ kit: Kit,
    key: String,
    title: String,
    trailing: El<CursedState>? = nil,
    contrast: Bool = false,
    rows: [El<CursedState>]
) -> El<CursedState> {
    var inner: El<CursedState> = col().key("\(key)-rows").wFull()
    for (i, r) in rows.enumerated() {
        inner = inner.child(r)
        if i + 1 < rows.count {
            inner = inner.child(kit.divider())
        }
    }

    var head: El<CursedState> = row()
        .key("\(key)-head")
        .wFull()
        .h(24)
        .itemsCenter()
        .justifyBetween()
        .child(
            text(title)
                .font(TextStyle(size: 13, weight: 500))
                .color(kit.c.textBase)
        )
    if let trailing {
        head = head.child(trailing)
    }

    return col()
        .key(key)
        .wFull()
        .gap(10)
        .child(head)
        .child(
            col()
                .key("\(key)-card")
                .wFull()
                .rounded(8)
                .bg(kit.c.layer01)
                .border(contrast ? 1.5 : 0.5, contrast ? kit.c.textBase.alpha(0.45) : kit.c.borderMuted)
                .px(16)
                .child(inner)
        )
}

private func settingRow(
    _ kit: Kit,
    key: String,
    title: String,
    desc: String,
    control: El<CursedState>
) -> El<CursedState> {
    row()
        .key(key)
        .wFull()
        .py(12)
        .gap(16)
        .itemsCenter()
        .child(
            col()
                .grow(1)
                .gap(2)
                .child(text(title).font(kit.ty.uiMedium).color(kit.c.textBase))
                .child(text(desc).font(kit.ty.ui).color(kit.c.textMuted))
        )
        .child(control)
}

private func toggleRow(
    _ kit: Kit,
    key: String,
    title: String,
    desc: String,
    on: Bool,
    flip: @escaping (inout CursedState) -> Void
) -> El<CursedState> {
    settingRow(
        kit,
        key: key,
        title: title,
        desc: desc,
        control: kit.switchControl(key: "\(key)-switch", isOn: on, label: title) { state, _ in
            flip(&state)
            state.taps += 1
        }
    )
}

private func itemRow(
    _ kit: Kit,
    key: String,
    lead: El<CursedState>,
    name: String,
    trailing: El<CursedState>
) -> El<CursedState> {
    row()
        .key(key)
        .wFull()
        .h(44)
        .gap(10)
        .itemsCenter()
        .child(lead)
        .child(text(name).font(kit.ty.uiMedium).color(kit.c.textBase).grow(1))
        .child(trailing)
}

private func appTile(key: String, letter: String, color: Color) -> El<CursedState> {
    row()
        .key(key)
        .square(22)
        .rounded(5.5)
        .bg(color)
        .center()
        .child(
            text(letter)
                .font(TextStyle(size: 11, weight: 600))
                .color(.white)
        )
}

private func pageHeader(_ kit: Kit, title: String, desc: String) -> El<CursedState> {
    col()
        .key("header")
        .gap(2)
        .child(text(title).font(TextStyle(size: 15, weight: 600)).color(kit.c.textBase))
        .child(text(desc).font(kit.ty.ui).color(kit.c.textMuted))
}

private func brightnessSlider(_ kit: Kit, _ v: Float) -> El<CursedState> {
    let w: Float = 168.0
    let h: Float = 20.0
    let kd: Float = 16.0
    let bar: Float = 4.0
    let travel = w - kd
    let toValue: (Float) -> Float = { x in max(0.0, min(1.0, (x - kd / 2.0) / travel)) }

    return row()
        .key("brightness-control")
        .gap(10)
        .itemsCenter()
        .child(icon(CursedIcons.sun, size: 14).color(kit.c.iconFaint))
        .child(
            el()
                .key("brightness-slider")
                .role(.slider)
                .label("Brightness")
                .size(w, h)
                .onPointerDown { state, press, _ in
                    state.brightnessBeforeDrag = state.p.brightness
                    let knobX = kd / 2.0 + state.p.brightness * travel
                    if abs(press.local.x - knobX) > kd / 2.0 + 3.0 {
                        state.p.brightness = toValue(press.local.x)
                    }
                }
                .onDrag { state, drag, tx in
                    let knobX = kd / 2.0 + state.brightnessBeforeDrag * travel
                    let grab = abs(drag.startLocal.x - knobX) <= kd / 2.0 + 3.0
                        ? (drag.startLocal.x - knobX)
                        : 0.0
                    state.p.brightness = toValue(drag.local.x - grab)
                    tx.settle()
                }
                .onDragEnd { state, cancelled, _ in
                    if cancelled { state.p.brightness = state.brightnessBeforeDrag }
                }
                .child(
                    el()
                        .key("track")
                        .size(w, bar)
                        .absolute(x: 0, y: (h - bar) / 2.0)
                        .rounded(bar / 2.0)
                        .bg(kit.c.layer04)
                )
                .child(
                    el()
                        .key("fill")
                        .size(kd / 2.0 + v * travel, bar)
                        .absolute(x: 0, y: (h - bar) / 2.0)
                        .rounded(bar / 2.0)
                        .bg(kit.c.iconBase)
                )
                .child(
                    el()
                        .key("knob")
                        .square(kd)
                        .absolute(x: v * travel, y: (h - kd) / 2.0)
                        .pill()
                        .bg(kit.c.knobOn)
                        .border(0.5, kit.c.borderStrong)
                        .shadow(Shadow(y: 1, blur: 3, color: Color.black.alpha(0.18)))
                )
        )
        .child(icon(CursedIcons.sun, size: 18).color(kit.c.iconMuted))
        .child(
            text("\(Int((v * 100.0).rounded()))%")
                .w(36)
                .font(kit.ty.ui)
                .color(kit.c.textMuted)
        )
}

private func sidebarView(_ s: CursedState, _ kit: Kit) -> El<CursedState> {
    let w = sidebarW - 24.0
    let idx = CursedPage.allCases.firstIndex(of: s.page) ?? 0

    var nav: El<CursedState> = el()
        .key("nav")
        .w(w)
        .h(Float(CursedPage.allCases.count) * navPitch)
        .child(
            el()
                .key("nav-sel")
                .absolute(x: 0, y: Float(idx) * navPitch)
                .size(w, navH)
                .rounded(6)
                .bg(kit.c.layer03)
                .animateLayout(Tok.Motion.SNAPPY)
        )

    for (i, p) in CursedPage.allCases.enumerated() {
        let selected = (i == idx)
        let navRow: El<CursedState> = row()
            .key("nav-\(p.id)")
            .role(.tab)
            .label(p.title)
            .selected(selected ? "true" : "false")
            .absolute(x: 0, y: Float(i) * navPitch)
            .size(w, navH)
            .px(8)
            .gap(8)
            .itemsCenter()
            .rounded(6)
            .hover(selected ? .transparent : kit.c.hover)
            .onClick { state in
                state.page = p
                state.taps += 1
            }
            .child(icon(p.icon, size: 16).color(selected ? kit.c.iconBase : kit.c.iconMuted))
            .child(text(p.title).font(kit.ty.ui).color(selected ? kit.c.textBase : kit.c.textMuted))
        nav = nav.child(navRow)
    }

    return col()
        .key("sidebar")
        .w(sidebarW)
        .hFull()
        .bg(kit.c.bgDeep)
        .px(12)
        .pt(20)
        .pb(16)
        .gap(16)
        .child(
            kit.textInputField(key: "search", \CursedState.search, placeholder: "Search")
                .w(w)
        )
        .child(nav)
        .child(spacer())
        .child(
            kit.button(key: "restore", "Restore Defaults", variant: .neutral) { state, _ in
                state.restore()
            }
        )
}

private func generalPage(_ s: CursedState, _ kit: Kit) -> El<CursedState> {
    let p = s.p
    return col()
        .wFull()
        .gap(24)
        .child(pageHeader(kit, title: "General", desc: "Startup, search and updates."))
        .child(sectionCard(kit, key: "startup", title: "Startup", contrast: p.contrast, rows: [
            toggleRow(kit, key: "login", title: "Launch at login", desc: "Open OpenCode when you log in.", on: p.launchAtLogin) {
                $0.p.launchAtLogin.toggle()
            },
            toggleRow(kit, key: "fast", title: "Lightning-fast startup", desc: "Skip the splash screen and open instantly.", on: p.fastStartup) {
                $0.p.fastStartup.toggle()
            },
        ]))
        .child(sectionCard(kit, key: "search-sec", title: "Search", contrast: p.contrast, rows: [
            toggleRow(kit, key: "spotlight", title: "Show in Spotlight", desc: "Let Spotlight find your sessions and settings.", on: p.spotlight) {
                $0.p.spotlight.toggle()
            },
            settingRow(
                kit,
                key: "language",
                title: "Language",
                desc: "Used for menus and messages.",
                control: kit.select(
                    key: "lang",
                    options: [("English", "English"), ("Japanese", "Japanese"), ("German", "German")],
                    selected: s.lang,
                    isOpen: s.langOpen,
                    onToggleOpen: { st, open in st.langOpen = open },
                    onSelect: { st, v in st.lang = v; st.langOpen = false }
                ).w(150)
            ),
        ]))
        .child(sectionCard(kit, key: "updates", title: "Updates", contrast: p.contrast, rows: [
            toggleRow(kit, key: "updates-row", title: "Automatic updates", desc: "Download and install updates in the background.", on: p.autoUpdate) {
                $0.p.autoUpdate.toggle()
            },
        ]))
}

private func appearancePage(_ s: CursedState, _ kit: Kit) -> El<CursedState> {
    let p = s.p
    return col()
        .wFull()
        .gap(24)
        .child(pageHeader(kit, title: "Appearance", desc: "How OpenCode looks."))
        .child(sectionCard(kit, key: "theme", title: "Theme", contrast: p.contrast, rows: [
            settingRow(
                kit,
                key: "mode",
                title: "Appearance",
                desc: "Match the system, or pick one.",
                control: kit.segmentedControl(
                    key: "mode-control",
                    options: [(.light, "Light"), (.dark, "Dark"), (.auto, "Auto")],
                    selected: p.appearance
                ) { state, picked in
                    state.p.appearance = picked
                    state.taps += 1
                }
                .w(204)
            ),
            settingRow(kit, key: "brightness", title: "Brightness", desc: "How bright the window is.", control: brightnessSlider(kit, p.brightness)),
        ]))
        .child(sectionCard(kit, key: "text", title: "Text", contrast: p.contrast, rows: [
            settingRow(
                kit,
                key: "size",
                title: "Text size",
                desc: "Used across the app.",
                control: kit.select(
                    key: "size-sel",
                    options: [("12 pt", "12 pt"), ("13 pt", "13 pt"), ("14 pt", "14 pt")],
                    selected: s.textSize,
                    isOpen: s.textSizeOpen,
                    onToggleOpen: { st, open in st.textSizeOpen = open },
                    onSelect: { st, v in st.textSize = v; st.textSizeOpen = false }
                ).w(130)
            ),
            settingRow(
                kit,
                key: "font",
                title: "Code font",
                desc: "Used in diffs and the terminal.",
                control: kit.select(
                    key: "font-sel",
                    options: [("IBM Plex Mono", "IBM Plex Mono"), ("SF Mono", "SF Mono"), ("JetBrains Mono", "JetBrains Mono")],
                    selected: s.codeFont,
                    isOpen: s.codeFontOpen,
                    onToggleOpen: { st, open in st.codeFontOpen = open },
                    onSelect: { st, v in st.codeFont = v; st.codeFontOpen = false }
                ).w(168)
            ),
        ]))
}

private func networkPage(_ s: CursedState, _ kit: Kit) -> El<CursedState> {
    let p = s.p
    func allow(_ key: String, _ letter: String, _ hex: String, _ name: String) -> El<CursedState> {
        itemRow(
            kit,
            key: key,
            lead: appTile(key: "\(key)-tile", letter: letter, color: Color.hex(hex)!),
            name: name,
            trailing: text("Allow incoming connections").font(kit.ty.ui).color(kit.c.textMuted)
        )
    }

    var allowedSection = sectionCard(kit, key: "allowed", title: "Allowed apps", contrast: p.contrast, rows: [
        allow("opencode", "O", "#1d1d1f", "OpenCode"),
        allow("rune", "R", "#6d4aff", "Rune"),
        allow("display", "S", "#2f80ed", "Studio Display Updater"),
    ])

    if p.firewall {
        let fireAtlas = CursedGfx.firewallOverlay(width: 648, height: 185, time: Float(s.now), reducedMotion: p.reduceMotion)
        allowedSection = el()
            .wFull()
            .child(allowedSection)
            .child(
                image(fireAtlas)
                    .key("firewall-flames")
                    .sizeFull()
                    .absolute(x: 0, y: 0)
            )
    }

    return col()
        .wFull()
        .gap(24)
        .child(pageHeader(kit, title: "Network", desc: "Firewall and addresses."))
        .child(sectionCard(kit, key: "firewall", title: "Firewall", contrast: p.contrast, rows: [
            toggleRow(kit, key: "firewall-row", title: "Firewall", desc: "Block incoming connections from unknown apps.", on: p.firewall) {
                $0.p.firewall.toggle()
            },
        ]))
        .child(allowedSection)
        .child(sectionCard(kit, key: "address", title: "Address", contrast: p.contrast, rows: [
            toggleRow(kit, key: "static", title: "Static IP", desc: "Use a fixed address instead of DHCP.", on: p.staticIP) {
                $0.p.staticIP.toggle()
            },
            settingRow(
                kit,
                key: "ip",
                title: "IP address",
                desc: "This Mac's address on the local network.",
                control: kit.textInputField(key: "ip-field", \CursedState.ip, placeholder: "192.168.1.42")
                    .w(168)
                    .opacity(p.staticIP ? 1.0 : 0.45)
            ),
        ]))
}

private func securityPage(_ s: CursedState, _ kit: Kit) -> El<CursedState> {
    let p = s.p
    func door(_ key: String, _ name: String, _ status: String) -> El<CursedState> {
        itemRow(
            kit,
            key: key,
            lead: el().square(8).rounded(4).bg(kit.c.success.icon).mx(7),
            name: name,
            trailing: kit.badge(status, tone: .neutral)
        )
    }

    var perimeterSection = sectionCard(kit, key: "perimeter", title: "Perimeter", contrast: p.contrast, rows: [
        door("front", "Front door", "Locked"),
        door("back", "Back door", "Locked"),
        door("ssh", "Port 22", "Closed"),
        door("server", "Port 4096", "OpenCode only"),
    ])

    if p.fence {
        let fenceAtlas = CursedGfx.electricFenceOverlay(width: 648, height: 220, time: Float(s.now), reducedMotion: p.reduceMotion)
        perimeterSection = el()
            .wFull()
            .child(perimeterSection)
            .child(
                image(fenceAtlas)
                    .key("electric-fence-arcs")
                    .sizeFull()
                    .absolute(x: 0, y: 0)
            )
    }

    return col()
        .wFull()
        .gap(24)
        .child(pageHeader(kit, title: "Security", desc: "Locks, passwords and the perimeter."))
        .child(sectionCard(kit, key: "protection", title: "Protection", contrast: p.contrast, rows: [
            toggleRow(kit, key: "fence", title: "Electric fence", desc: "Protect the perimeter of your network.", on: p.fence) {
                $0.p.fence.toggle()
            },
            toggleRow(kit, key: "sleep", title: "Require password after sleep", desc: "Ask for your password when the display wakes.", on: p.lockOnSleep) {
                $0.p.lockOnSleep.toggle()
            },
        ]))
        .child(perimeterSection)
}

private func accessibilityPage(_ s: CursedState, _ kit: Kit) -> El<CursedState> {
    let p = s.p
    return col()
        .wFull()
        .gap(24)
        .child(pageHeader(kit, title: "Accessibility", desc: "Display, motion and feedback."))
        .child(sectionCard(kit, key: "display", title: "Display", contrast: p.contrast, rows: [
            toggleRow(kit, key: "contrast", title: "Increase contrast", desc: "Make edges and text stand out more.", on: p.contrast) {
                $0.p.contrast.toggle()
            },
            toggleRow(kit, key: "transparency", title: "Reduce transparency", desc: "Make glass surfaces solid.", on: p.reduceTransparency) {
                $0.p.reduceTransparency.toggle()
            },
        ]))
        .child(sectionCard(kit, key: "motion", title: "Motion", contrast: p.contrast, rows: [
            toggleRow(kit, key: "reduce", title: "Reduce motion", desc: "Calmer, shorter animations.", on: p.reduceMotion) {
                $0.p.reduceMotion.toggle()
            },
        ]))
        .child(sectionCard(kit, key: "feedback", title: "Feedback", contrast: p.contrast, rows: [
            settingRow(
                kit,
                key: "haptics",
                title: "Haptic feedback",
                desc: "How strongly clicks are felt.",
                control: kit.segmentedControl(
                    key: "haptics-control",
                    options: [(.off, "Off"), (.light, "Light"), (.strong, "Strong")],
                    selected: p.haptics
                ) { state, picked in
                    state.p.haptics = picked
                    state.taps += 1
                }
                .w(204)
            ),
        ]))
}

private func developerPage(_ s: CursedState, _ kit: Kit) -> El<CursedState> {
    let p = s.p
    var reloadBtn: El<CursedState> = kit.button(key: "reload-btn", "Reload now", variant: p.hotReload ? .danger : .neutral) { state, _ in
        state.taps += 1
    }
    if p.hotReload {
        reloadBtn = reloadBtn.bg(Color.hex("#d8401a")!)
    }

    func sizeRow(_ key: String, _ name: String, _ v: String) -> El<CursedState> {
        itemRow(
            kit,
            key: key,
            lead: icon(CursedIcons.folder, size: 16).color(kit.c.iconMuted).mx(3),
            name: name,
            trailing: text(v).font(kit.ty.ui).color(kit.c.textMuted)
        )
    }

    let cacheRows: [El<CursedState>] = p.flushed
        ? [row().key("empty").wFull().h(44).itemsCenter().child(text("Nothing cached.").font(kit.ty.ui).color(kit.c.textMuted))]
        : [
            sizeRow("shaders", "Shader cache", "1.2 GB"),
            sizeRow("thumbs", "Thumbnails", "640 MB"),
            sizeRow("snapshots", "Session snapshots", "512 MB"),
        ]

    let flushBtn: El<CursedState> = kit.button(
        key: "flush-btn",
        "Flush cache",
        variant: .neutral,
        disabled: p.flushed
    ) { state, _ in
        state.p.flushed = true
        state.taps += 1
    }

    var reloadingCard = sectionCard(kit, key: "reloading", title: "Reloading", contrast: p.contrast, rows: [
        toggleRow(kit, key: "hot", title: "Hot reload", desc: "Reload the app when files change.", on: p.hotReload) {
            $0.p.hotReload.toggle()
        },
        settingRow(kit, key: "reload", title: "Reload renderer", desc: "Rebuild shaders and reload the window.", control: reloadBtn),
    ])

    if p.hotReload {
        let embers = CursedGfx.hotReloadOverlay(width: 648, height: 150, time: Float(s.now), reducedMotion: p.reduceMotion)
        reloadingCard = el()
            .wFull()
            .child(reloadingCard)
            .child(image(embers).key("hot-embers").sizeFull().absolute(x: 0, y: 0))
    }

    return col()
        .wFull()
        .gap(24)
        .child(pageHeader(kit, title: "Developer", desc: "Builds, reloads and caches."))
        .child(reloadingCard)
        .child(sectionCard(
            kit,
            key: "cache",
            title: p.flushed ? "Cache · Zero KB" : "Cache · 2.4 GB",
            trailing: flushBtn,
            contrast: p.contrast,
            rows: cacheRows
        ))
}

func cursedView(_ s: CursedState, _ cx: inout Cx<CursedState>) -> El<CursedState> {
    let dark = isDarkTheme(s, systemDark: cx.systemDark)
    let kit = OpenCodeTheme.kit(dark: dark)

    let pageEl: El<CursedState>
    switch s.page {
    case .general: pageEl = generalPage(s, kit)
    case .appearance: pageEl = appearancePage(s, kit)
    case .network: pageEl = networkPage(s, kit)
    case .security: pageEl = securityPage(s, kit)
    case .accessibility: pageEl = accessibilityPage(s, kit)
    case .developer: pageEl = developerPage(s, kit)
    }

    let content = col()
        .key("content")
        .grow(1)
        .hFull()
        .bg(kit.c.bgBase)
        .px(40)
        .pt(32)
        .child(
            pageEl
                .key("page-\(s.page.id)")
                .transition(.opacity)
        )

    var root = el()
        .sizeFull()
        .child(
            row()
                .key("window")
                .sizeFull()
                .bg(kit.c.bgBase)
                .child(sidebarView(s, kit))
                .child(el().key("sidebar-edge").w(1).hFull().bg(kit.c.borderBase))
                .child(content)
        )

    // Brightness / Dark mode gag
    if s.p.brightness < 0.99 {
        let dim = max(0.0, min(0.88, 1.0 - s.p.brightness))
        root = root.child(
            el()
                .key("brightness-curtain")
                .sizeFull()
                .absolute(x: 0, y: 0)
                .bg(Color.black.alpha(dim))
        )
    }

    // Reduce transparency frosted gag
    if s.p.reduceTransparency {
        root = root.child(
            el()
                .key("frosted-curtain")
                .sizeFull()
                .absolute(x: 0, y: 0)
                .bg(kit.c.bgDeep.alpha(0.35))
        )
    }

    // Spotlight beam from search bar
    if s.p.spotlight {
        root = root.child(
            el()
                .key("spotlight-beam")
                .size(460, 460)
                .rounded(230)
                .absolute(x: 60, y: -40)
                .bg(Color(r: 1.0, g: 0.96, b: 0.78, a: 0.14))
        )
    }

    // Restore-defaults toast
    if s.toastUntil != nil {
        root = root.child(
            row()
                .absolute(x: 0, y: 0)
                .sizeFull()
                .p(20)
                .itemsEnd()
                .justifyEnd()
                .child(
                    kit.toast(
                        key: "restored",
                        message: "Defaults restored — The fire department has been notified.",
                        tone: .success
                    ) { state in
                        state.toastUntil = nil
                    }
                )
        )
    }

    return root
}

let spec = AppSpec<CursedState>(
    title: "Settings",
    size: Vec2(960, 660),
    state: CursedState(),
    view: cursedView
)
.scene("default") { _ in }
.scene("general") { $0.page = .general }
.scene("appearance") { $0.page = .appearance }
.scene("network") { $0.page = .network }
.scene("security") { $0.page = .security }
.scene("accessibility") { $0.page = .accessibility }
.scene("developer") { $0.page = .developer }
.scene("fire") {
    $0.page = .network
    $0.p.firewall = true
    $0.p.staticIP = true
}
.scene("fence") {
    $0.page = .security
    $0.p.fence = true
}
.scene("dark") {
    $0.page = .appearance
    $0.p.appearance = .dark
}
.scene("spotlight") {
    $0.p.spotlight = true
}
.scene("contrast") {
    $0.page = .accessibility
    $0.p.contrast = true
}
.scene("frosted") {
    $0.page = .accessibility
    $0.p.reduceTransparency = true
}
.scene("hot") {
    $0.page = .developer
    $0.p.hotReload = true
}
.scene("flushed") {
    $0.page = .developer
    $0.p.flushed = true
}
.scene("reduced-fire") {
    $0.page = .network
    $0.p.firewall = true
    $0.p.reduceMotion = true
}

try RuneApp.run(spec)
