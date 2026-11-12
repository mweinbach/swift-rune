import Foundation
import Rune
import RuneKit
import RuneMotion

/// Port of `examples/motion-bento`: a smart-studio control center where tiles animate
/// simultaneously via `RuneMotion` springs (`Spring`), `rollingText`, `progressCircle`,
/// `progress`, and interactive scene/chaos stepping.
enum StudioScene: Int, CaseIterable, CustomStringConvertible {
    case relax = 0
    case focus = 1
    case cinema = 2
    case night = 3

    var description: String {
        switch self {
        case .relax: return "Relax"
        case .focus: return "Focus"
        case .cinema: return "Cinema"
        case .night: return "Night"
        }
    }

    var accent: Color {
        switch self {
        case .relax: return Color.hex("#4ea8de")!
        case .focus: return Color.hex("#52b788")!
        case .cinema: return Color.hex("#e76f51")!
        case .night: return Color.hex("#9b72cf")!
        }
    }
}

struct MotionBentoState {
    var scene: StudioScene = .relax
    var step: Int = 0
    var events: Int = 12
    var targetTemp: Float = 21.5
    var lightsOn: [Bool] = [true, true, false, true]
    var playing: Bool = true
    var volume: Float = 0.68
    var locked: Bool = true
    var powerWatts: Int = 420
    var netDownMbps: Int = 640
    var blindsOpen: Float = 0.72
    var airQuality: Int = 94

    mutating func stepChaos() {
        step += 1
        events += 3
        let nextIdx = (scene.rawValue + 1) % StudioScene.allCases.count
        scene = StudioScene.allCases[nextIdx]
        switch scene {
        case .relax:
            targetTemp = 21.5
            lightsOn = [true, true, false, true]
            playing = true
            volume = 0.68
            locked = true
            powerWatts = 420
            netDownMbps = 640
            blindsOpen = 0.72
            airQuality = 94
        case .focus:
            targetTemp = 20.0
            lightsOn = [true, true, true, false]
            playing = false
            volume = 0.35
            locked = true
            powerWatts = 580
            netDownMbps = 890
            blindsOpen = 0.90
            airQuality = 97
        case .cinema:
            targetTemp = 22.0
            lightsOn = [false, false, false, true]
            playing = true
            volume = 0.85
            locked = true
            powerWatts = 710
            netDownMbps = 940
            blindsOpen = 0.08
            airQuality = 91
        case .night:
            targetTemp = 18.5
            lightsOn = [false, false, false, false]
            playing = false
            volume = 0.15
            locked = true
            powerWatts = 145
            netDownMbps = 120
            blindsOpen = 0.0
            airQuality = 98
        }
    }
}

private let snappySpring = Spring(duration: 0.42, bounce: 0.18)
private let smoothSpring = Spring(duration: 0.55, bounce: 0.08)

private func tileCard(
    key: String,
    title: String,
    subtitle: String,
    kit: Kit,
    content: El<MotionBentoState>
) -> El<MotionBentoState> {
    let headerRow: El<MotionBentoState> = row()
        .wFull()
        .itemsCenter()
        .justifyBetween()
        .child(text(title).font(kit.ty.uiMedium).color(kit.c.textBase))
        .child(text(subtitle).font(kit.ty.small).color(kit.c.textMuted))

    return col()
        .key(key)
        .grow(1)
        .hFull()
        .p(14)
        .gap(10)
        .rounded(14)
        .bg(kit.c.layer01)
        .border(1, kit.c.borderBase)
        .animate(smoothSpring)
        .child(headerRow)
        .child(content)
}

func bentoView(_ s: MotionBentoState, _ cx: inout Cx<MotionBentoState>) -> El<MotionBentoState> {
    let bg = Color.hex("#0c0e13")!
    let fg = Color.hex("#eef1f6")!
    let kit = Kit.fromPalette(PaletteSeed(bg: bg, fg: fg, accent: s.scene.accent), focus: .accent)

    let eventsCounter: El<MotionBentoState> = row()
        .gap(6)
        .itemsCenter()
        .child(kit.rollingText(key: "events-roll", "\(s.events)", font: kit.ty.uiMedium, color: kit.c.textBase))
        .child(text("events").font(kit.ty.small).color(kit.c.textMuted))

    let dot: El<MotionBentoState> = el()
        .square(10)
        .rounded(5)
        .bg(s.scene.accent)
        .animate(snappySpring)

    let scenePill: El<MotionBentoState> = row()
        .key("scene-pill")
        .h(32)
        .px(14)
        .gap(8)
        .itemsCenter()
        .rounded(16)
        .bg(kit.c.layer01)
        .border(1, kit.c.borderBase)
        .onClick { state in state.stepChaos() }
        .child(dot)
        .child(text(s.scene.description).font(kit.ty.uiMedium).color(kit.c.textBase))

    let stepBtn: El<MotionBentoState> = kit.button(key: "step-btn", "Step Chaos", variant: .accent, size: .sm) { state, _ in
        state.stepChaos()
    }

    let header: El<MotionBentoState> = row()
        .key("header")
        .wFull()
        .h(52)
        .itemsCenter()
        .justifyBetween()
        .child(
            col().gap(2)
                .child(text("Studio").size(22).bold().color(kit.c.textBase))
                .child(text("Control center · Friday evening").font(kit.ty.small).color(kit.c.textMuted))
        )
        .child(
            row().gap(12).itemsCenter()
                .child(eventsCounter)
                .child(scenePill)
                .child(stepBtn)
        )

    // Row 1: Climate, Lights, Audio, Security
    let tempFrac = ((s.targetTemp - 16.0) / 12.0).clamped(to: 0...1)
    let climateTile = tileCard(
        key: "tile-climate",
        title: "Thermostat",
        subtitle: "Zone 1",
        kit: kit,
        content: row().wFull().grow(1).itemsCenter().gap(14)
            .child(kit.progressCircle(key: "thermo-ring", fraction: tempFrac, diameter: 54, strokeWidth: 5))
            .child(
                col().gap(4)
                    .child(text(String(format: "%.1f°C", s.targetTemp)).size(20).semibold().color(kit.c.textBase))
                    .child(
                        row().gap(6)
                            .child(kit.button(key: "temp-dn", "−", variant: .ghost, size: .sm) { state, _ in
                                state.targetTemp = max(16, state.targetTemp - 0.5)
                            })
                            .child(kit.button(key: "temp-up", "+", variant: .ghost, size: .sm) { state, _ in
                                state.targetTemp = min(28, state.targetTemp + 0.5)
                            })
                    )
            )
    )

    let roomNames = ["Desk", "Ceiling", "Wash", "Strip"]
    var lightGrid: El<MotionBentoState> = col().wFull().grow(1).gap(6)
    for idx in 0..<4 {
        let on = s.lightsOn[idx]
        let lightRow: El<MotionBentoState> = row()
            .key("light-\(idx)")
            .wFull()
            .h(26)
            .px(10)
            .itemsCenter()
            .justifyBetween()
            .rounded(7)
            .bg(on ? s.scene.accent.alpha(0.22) : kit.c.layer02)
            .border(1, on ? s.scene.accent.alpha(0.55) : kit.c.borderBase)
            .animate(snappySpring)
            .onClick { state in
                state.lightsOn[idx].toggle()
                state.events += 1
            }
            .child(text(roomNames[idx]).font(kit.ty.small).color(on ? kit.c.textBase : kit.c.textMuted))
            .child(el().square(8).rounded(4).bg(on ? s.scene.accent : kit.c.textMuted.alpha(0.35)))
        lightGrid = lightGrid.child(lightRow)
    }
    let lightsTile = tileCard(
        key: "tile-lights",
        title: "Lighting",
        subtitle: "\(s.lightsOn.filter { $0 }.count)/4 active",
        kit: kit,
        content: lightGrid
    )

    let audioTile = tileCard(
        key: "tile-audio",
        title: "Now Playing",
        subtitle: s.playing ? "Playing" : "Paused",
        kit: kit,
        content: col().wFull().grow(1).justifyBetween()
            .child(
                col().gap(2)
                    .child(text("Midnight Signals").font(kit.ty.uiMedium).color(kit.c.textBase))
                    .child(text("Ambient Works · 24-bit").font(kit.ty.small).color(kit.c.textMuted))
            )
            .child(
                row().wFull().itemsCenter().gap(8)
                    .child(kit.button(key: "play-btn", s.playing ? "Pause" : "Play", variant: .neutral, size: .sm) { state, _ in
                        state.playing.toggle()
                    })
                    .child(el().grow(1).child(kit.progress(key: "vol-bar", fraction: s.volume)))
            )
    )

    let securityTile = tileCard(
        key: "tile-security",
        title: "Perimeter",
        subtitle: s.locked ? "Armed" : "Disarmed",
        kit: kit,
        content: col().wFull().grow(1).justifyBetween()
            .child(
                row().gap(8).itemsCenter()
                    .child(kit.badge(s.locked ? "All Doors Locked" : "Entry Unlocked", tone: s.locked ? .success : .warning))
            )
            .child(
                kit.button(key: "lock-btn", s.locked ? "Unlock" : "Lock All", variant: .neutral, size: .sm) { state, _ in
                    state.locked.toggle()
                    state.events += 1
                }
            )
    )

    // Row 2: Energy, Network, Blinds, Air Quality
    let powerFrac = Float(s.powerWatts) / 1000.0
    let energyTile = tileCard(
        key: "tile-energy",
        title: "Power Draw",
        subtitle: "\(s.powerWatts) W",
        kit: kit,
        content: col().wFull().grow(1).justifyBetween()
            .child(text("\(s.powerWatts) W").size(22).bold().color(kit.c.textBase))
            .child(kit.progress(key: "power-bar", fraction: powerFrac.clamped(to: 0...1)))
            .child(text("Solar offset 62%").font(kit.ty.small).color(kit.c.textMuted))
    )

    let netTile = tileCard(
        key: "tile-net",
        title: "Network",
        subtitle: "Fiber 1G",
        kit: kit,
        content: col().wFull().grow(1).justifyBetween()
            .child(text("\(s.netDownMbps) Mbps").size(20).semibold().color(kit.c.textBase))
            .child(kit.progress(key: "net-bar", fraction: (Float(s.netDownMbps) / 1000.0).clamped(to: 0...1)))
            .child(text("Latency 4 ms · 0% loss").font(kit.ty.small).color(kit.c.textMuted))
    )

    let blindsTile = tileCard(
        key: "tile-blinds",
        title: "Shades",
        subtitle: "\(Int((s.blindsOpen * 100).rounded()))%",
        kit: kit,
        content: col().wFull().grow(1).justifyBetween()
            .child(kit.progress(key: "blinds-bar", fraction: s.blindsOpen))
            .child(
                row().gap(6)
                    .child(kit.button(key: "blinds-0", "Close", variant: .ghost, size: .sm) { state, _ in state.blindsOpen = 0 })
                    .child(kit.button(key: "blinds-50", "Half", variant: .ghost, size: .sm) { state, _ in state.blindsOpen = 0.5 })
                    .child(kit.button(key: "blinds-100", "Open", variant: .ghost, size: .sm) { state, _ in state.blindsOpen = 1.0 })
            )
    )

    let airTile = tileCard(
        key: "tile-air",
        title: "Air Quality",
        subtitle: "AQI \(s.airQuality)",
        kit: kit,
        content: col().wFull().grow(1).justifyBetween()
            .child(text("\(s.airQuality)%").size(22).bold().color(kit.c.textBase))
            .child(kit.badge("Clean Air", tone: .success))
            .child(text("CO₂ 412 ppm · 46% RH").font(kit.ty.small).color(kit.c.textMuted))
    )

    // Bottom Dock: Scene selector
    var dock: El<MotionBentoState> = row()
        .key("dock")
        .wFull()
        .h(54)
        .px(16)
        .gap(10)
        .itemsCenter()
        .justifyCenter()
        .rounded(16)
        .bg(kit.c.layer01)
        .border(1, kit.c.borderBase)

    for sc in StudioScene.allCases {
        let active = (sc == s.scene)
        let item: El<MotionBentoState> = row()
            .key("dock-\(sc.description)")
            .h(34)
            .px(16)
            .gap(8)
            .itemsCenter()
            .rounded(10)
            .bg(active ? sc.accent.alpha(0.22) : .transparent)
            .border(1, active ? sc.accent : .transparent)
            .animate(snappySpring)
            .onClick { state in
                state.scene = sc
                state.step += 1
                state.events += 1
            }
            .child(el().square(8).rounded(4).bg(sc.accent))
            .child(text(sc.description).font(kit.ty.uiMedium).color(active ? kit.c.textBase : kit.c.textMuted))
        dock = dock.child(item)
    }

    return col()
        .key("root")
        .sizeFull()
        .p(20)
        .gap(14)
        .bg(bg)
        .child(header)
        .child(
            row().wFull().grow(1).gap(14)
                .child(climateTile)
                .child(lightsTile)
                .child(audioTile)
                .child(securityTile)
        )
        .child(
            row().wFull().grow(1).gap(14)
                .child(energyTile)
                .child(netTile)
                .child(blindsTile)
                .child(airTile)
        )
        .child(dock)
}

let spec = AppSpec<MotionBentoState>(
    title: "Motion Bento",
    size: Vec2(1060, 660),
    dark: true,
    state: MotionBentoState(),
    onKey: { state, event, _ in
        if event.key == .space {
            state.stepChaos()
            return true
        }
        return false
    },
    view: bentoView
)
.scene("relax") { $0.scene = .relax }
.scene("cinema") { $0.stepChaos(); $0.stepChaos(); $0.scene = .cinema }
.scene("night") { $0.stepChaos(); $0.stepChaos(); $0.stepChaos(); $0.scene = .night }

try RuneApp.run(spec)
