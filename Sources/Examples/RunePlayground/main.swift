import Foundation
import Rune
import RuneKit

/// Port of `examples/playground`: a Preferences window with a toggleable interactive Playground (⌘⇧D)
/// featuring grouped stories, search filter, variant pills, stage size presets, and live story controls.
enum PrefSection: String, CaseIterable {
    case general = "General"
    case sync = "Sync"
    case devices = "Devices"
}

enum StoryId: String, CaseIterable {
    case toggle = "Controls/Switches/Toggle"
    case longSwitch = "Controls/Switches/Long label"
    case twoDevices = "Controls/Rows/Two devices"
    case manyDevices = "Lists/Many devices"
    case everyDevice = "Lists/Every device"
    case upload = "Progress/Upload"
    case toast = "Toasts/Sync toast"
    case prefs = "Windows/Preferences"
}

struct PlaygroundState {
    var playgroundOpen: Bool = false
    var section: PrefSection = .general
    var launchAtLogin: Bool = true
    var sounds: Bool = false
    var sync: Bool = true
    var wifiOnly: Bool = true
    var devices: [String] = ["Studio desk", "Travel laptop"]

    // Playground state
    var activeStory: StoryId = .toggle
    var filter = TextEdit("")
    var storySwitchOn: Bool = true
    var storySwitchDimmed: Bool = false
    var uploadProgress: Int = 36
    var toastFailed: Bool = false
    var compactStage: Bool = false
}

private let everyDeviceList = [
    "Studio desk", "Travel laptop", "Kitchen tablet", "Spare phone", "Lab machine", "Old desktop",
    "Living room TV", "Garage Pi", "Work phone", "Reading tablet", "Build server", "Test phone",
    "Backup drive", "Guest laptop", "Car display", "Watch", "Office printer", "Media box",
    "Shared iPad", "Loaner laptop", "Render node", "Home server", "Second monitor hub", "Field kit",
]

private func switchRow(
    key: String,
    label: String,
    on: Bool,
    t: ThemeTokens,
    accent: Color,
    onToggle: @escaping (inout PlaygroundState) -> Void
) -> El<PlaygroundState> {
    let w: Float = 34
    let h: Float = 20
    let k: Float = 16
    let knobX: Float = on ? (w - k - 2) : 2
    return row()
        .key(key)
        .wFull()
        .h(44)
        .px(12)
        .itemsCenter()
        .justifyBetween()
        .rounded(Tok.Radius.md)
        .bg(t.card)
        .border(1, t.cardBorder)
        .onClick(onToggle)
        .child(text(label).size(13).color(t.text))
        .child(
            el()
                .size(w, h)
                .rounded(h * 0.5)
                .bg(on ? accent : t.controlOff)
                .animate(Tok.Motion.SNAPPY)
                .child(
                    el()
                        .square(k)
                        .rounded(k * 0.5)
                        .bg(t.knob)
                        .shadow(Shadow(y: 1, blur: 3, color: t.knobShadow))
                        .absolute(x: knobX, y: 2)
                        .animateLayout(Tok.Motion.SNAPPY)
                )
        )
}

private func devicesList(_ names: [String], t: ThemeTokens) -> El<PlaygroundState> {
    var list: El<PlaygroundState> = col()
        .key("devices")
        .wFull()
        .rounded(Tok.Radius.md)
        .bg(t.card)
        .border(1, t.cardBorder)
    for (i, name) in names.enumerated() {
        if i > 0 {
            list = list.child(rule(1, t.separator))
        }
        list = list.child(
            row()
                .key("device-\(i)")
                .wFull()
                .h(36)
                .px(12)
                .itemsCenter()
                .justifyBetween()
                .child(text(name).size(13).color(t.text))
                .child(text(i == 0 ? "This device" : "Synced").size(11).color(t.textSecondary))
        )
    }
    return list
}

private func preferencesView(_ s: PlaygroundState, t: ThemeTokens, accent: Color) -> El<PlaygroundState> {
    var nav: El<PlaygroundState> = col()
        .key("nav")
        .w(176)
        .hFull()
        .pt(14)
        .px(8)
        .gap(2)
    for sec in PrefSection.allCases {
        let on = (s.section == sec)
        nav = nav.child(
            row()
                .key("sec-\(sec.rawValue)")
                .wFull()
                .h(28)
                .px(10)
                .itemsCenter()
                .rounded(Tok.Radius.sm)
                .bg(on ? t.controlTrack : .transparent)
                .hover(on ? t.controlTrack : t.hover)
                .onClick { state in state.section = sec }
                .child(text(sec.rawValue).size(13).color(t.text))
        )
    }

    let body: El<PlaygroundState>
    switch s.section {
    case .general:
        body = col()
            .wFull()
            .gap(8)
            .child(switchRow(key: "launch", label: "Open at login", on: s.launchAtLogin, t: t, accent: accent) { $0.launchAtLogin.toggle() })
            .child(switchRow(key: "sounds", label: "Play sounds", on: s.sounds, t: t, accent: accent) { $0.sounds.toggle() })
    case .sync:
        var syncCol: El<PlaygroundState> = col()
            .wFull()
            .gap(8)
            .child(switchRow(key: "sync", label: "Sync across devices", on: s.sync, t: t, accent: accent) { $0.sync.toggle() })
            .child(
                switchRow(key: "wifi", label: "Only on Wi-Fi", on: s.wifiOnly && s.sync, t: t, accent: accent) { $0.wifiOnly.toggle() }
                    .opacity(s.sync ? 1.0 : 0.5)
            )
        if !s.sync {
            syncCol = syncCol.child(
                text("Changes stay on this device until sync is back on.")
                    .size(12)
                    .color(t.textSecondary)
                    .px(4)
            )
        }
        body = syncCol
    case .devices:
        body = devicesList(s.devices, t: t)
    }

    return row()
        .wFull()
        .grow(1)
        .bg(t.bg)
        .child(nav)
        .child(el().w(1).hFull().bg(t.separator))
        .child(
            col()
                .key("content")
                .grow(1)
                .hFull()
                .p(24)
                .gap(16)
                .child(text(s.section.rawValue).size(18).semibold().color(t.text))
                .child(body)
        )
}

private func storyStage(_ s: PlaygroundState, t: ThemeTokens, accent: Color) -> El<PlaygroundState> {
    let stageContent: El<PlaygroundState>
    switch s.activeStory {
    case .toggle:
        stageContent = col().w(300).child(
            switchRow(key: "story-sw", label: "Sync across devices", on: s.storySwitchOn, t: t, accent: accent) {
                $0.storySwitchOn.toggle()
            }
            .opacity(s.storySwitchDimmed ? 0.5 : 1.0)
        )
    case .longSwitch:
        stageContent = col().w(300).child(
            switchRow(key: "story-sw-long", label: "Only sync over Wi-Fi when on battery", on: s.storySwitchOn, t: t, accent: accent) {
                $0.storySwitchOn.toggle()
            }
        )
    case .twoDevices:
        stageContent = col().w(360).child(devicesList(["Studio desk", "Travel laptop"], t: t))
    case .manyDevices:
        stageContent = col().w(360).gap(10)
            .child(devicesList(s.devices, t: t))
            .child(
                row().wFull().h(36).px(12).itemsCenter().justifyBetween().rounded(Tok.Radius.md).bg(t.card).border(1, t.cardBorder)
                    .child(text("Devices: \(s.devices.count)").size(12).color(t.text))
                    .child(
                        row().gap(6)
                            .child(
                                row().key("fewer").square(24).center().rounded(6).bg(t.controlTrack)
                                    .onClick { state in if state.devices.count > 1 { state.devices.removeLast() } }
                                    .child(text("−").size(14).color(t.text))
                            )
                            .child(
                                row().key("more").square(24).center().rounded(6).bg(t.controlTrack)
                                    .onClick { state in state.devices.append("New device \(state.devices.count + 1)") }
                                    .child(text("+").size(14).color(t.text))
                            )
                    )
            )
    case .everyDevice:
        stageContent = col().w(360).h(260).scroll().child(devicesList(everyDeviceList, t: t))
    case .upload:
        let trackW: Float = 240
        let fillW = trackW * Float(s.uploadProgress) / 100.0
        stageContent = col().itemsCenter().gap(12)
            .child(text("Uploading backup · \(s.uploadProgress)%").size(13).color(t.text))
            .child(
                el().w(trackW).h(6).rounded(3).bg(t.controlTrack)
                    .child(el().w(fillW).h(6).rounded(3).bg(accent).animateLayout(Tok.Motion.SNAPPY))
            )
            .child(
                row().gap(8)
                    .child(
                        row().key("step-up").h(28).px(12).center().rounded(6).bg(t.controlTrack)
                            .onClick { state in state.uploadProgress = min(100, state.uploadProgress + 16) }
                            .child(text("+16%").size(12).color(t.text))
                    )
                    .child(
                        row().key("reset-up").h(28).px(12).center().rounded(6).bg(t.controlTrack)
                            .onClick { state in state.uploadProgress = 0 }
                            .child(text("Reset").size(12).color(t.text))
                    )
            )
    case .toast:
        let dotColor = Tok.accent(s.toastFailed ? 3 : 4, dark: true)
        let msg = s.toastFailed ? "Sync failed, retrying" : "Synced 3 devices"
        stageContent = col().itemsCenter().gap(12)
            .child(
                row().h(36).px(16).gap(8).itemsCenter().rounded(18).bg(t.card).border(1, t.cardBorder)
                    .shadow(Shadow(y: 4, blur: 16, color: t.shadow))
                    .child(el().square(8).rounded(4).bg(dotColor))
                    .child(text(msg).size(13).color(t.text))
            )
            .child(
                row().key("toggle-toast").h(28).px(12).center().rounded(6).bg(t.controlTrack)
                    .onClick { state in state.toastFailed.toggle() }
                    .child(text(s.toastFailed ? "Show Success" : "Simulate Failure").size(12).color(t.text))
            )
    case .prefs:
        stageContent = preferencesView(s, t: t, accent: accent)
    }

    let stageW: Float = s.compactStage ? 360 : 520
    return col()
        .key("stage-wrap")
        .grow(1)
        .hFull()
        .p(16)
        .gap(12)
        .itemsCenter()
        .bg(t.bg)
        .child(
            row().wFull().itemsCenter().justifyBetween()
                .child(text(s.activeStory.rawValue).size(14).semibold().color(t.text))
                .child(
                    row().gap(6)
                        .child(
                            row().key("size-compact").px(10).py(4).rounded(6)
                                .bg(s.compactStage ? accent.alpha(0.22) : t.controlTrack)
                                .onClick { state in state.compactStage = true }
                                .child(text("Compact").size(11).color(t.text))
                        )
                        .child(
                            row().key("size-wide").px(10).py(4).rounded(6)
                                .bg(!s.compactStage ? accent.alpha(0.22) : t.controlTrack)
                                .onClick { state in state.compactStage = false }
                                .child(text("Wide").size(11).color(t.text))
                        )
                )
        )
        .child(
            col()
                .key("stage")
                .w(s.activeStory == .prefs ? stageW : stageW)
                .grow(1)
                .center()
                .rounded(Tok.Radius.lg)
                .bg(t.bg)
                .border(1, t.cardBorder)
                .clip(true)
                .child(stageContent)
        )
}

private func playgroundView(_ s: PlaygroundState, t: ThemeTokens, accent: Color) -> El<PlaygroundState> {
    let q = s.filter.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let stories = StoryId.allCases.filter { q.isEmpty || $0.rawValue.lowercased().contains(q) }

    var sidebar: El<PlaygroundState> = col()
        .key("story-sidebar")
        .w(230)
        .hFull()
        .p(10)
        .gap(6)
        .bg(t.card)
        .child(
            textInput(key: "story-filter", \.filter)
                .wFull()
                .h(30)
                .px(10)
                .rounded(6)
                .bg(t.controlTrack)
                .border(1, t.cardBorder)
                .size(12)
                .color(t.text)
                .placeholder("Filter stories…", color: t.textSecondary)
                .caret(accent)
        )

    var list: El<PlaygroundState> = col().wFull().grow(1).gap(2).scroll()
    for story in stories {
        let on = (story == s.activeStory)
        list = list.child(
            row()
                .key("story-\(story.rawValue)")
                .wFull()
                .px(10)
                .py(6)
                .rounded(6)
                .bg(on ? accent.alpha(0.22) : .transparent)
                .hover(on ? accent.alpha(0.26) : t.hover)
                .onClick { state in state.activeStory = story }
                .child(text(story.rawValue).size(12).color(on ? accent : t.text))
        )
    }
    sidebar = sidebar.child(list)

    return row()
        .wFull()
        .grow(1)
        .child(sidebar)
        .child(el().w(1).hFull().bg(t.separator))
        .child(storyStage(s, t: t, accent: accent))
}

func mainView(_ s: PlaygroundState, _ cx: inout Cx<PlaygroundState>) -> El<PlaygroundState> {
    let t = Tok.theme(dark: cx.systemDark)
    let accent = Tok.accent(0, dark: cx.systemDark)

    let bottomBar: El<PlaygroundState> = row()
        .key("playground-bar")
        .wFull()
        .h(34)
        .px(14)
        .itemsCenter()
        .justifyBetween()
        .bg(t.card)
        .child(text(s.playgroundOpen ? "Playground · \(StoryId.allCases.count) stories" : "Preferences · ⌘⇧D to open Playground").size(11).color(t.textSecondary))
        .child(
            row()
                .key("toggle-playground")
                .px(10)
                .py(4)
                .rounded(6)
                .bg(s.playgroundOpen ? accent.alpha(0.22) : t.controlTrack)
                .onClick { state in state.playgroundOpen.toggle() }
                .child(text(s.playgroundOpen ? "Close Playground" : "Open Playground").size(11).medium().color(s.playgroundOpen ? accent : t.text))
        )

    return col()
        .key("root")
        .sizeFull()
        .bg(t.bg)
        .child(s.playgroundOpen ? playgroundView(s, t: t, accent: accent) : preferencesView(s, t: t, accent: accent))
        .child(rule(1, t.separator))
        .child(bottomBar)
}

let spec = AppSpec<PlaygroundState>(
    title: "Rune Playground",
    size: Vec2(780, 480),
    state: PlaygroundState(),
    onKey: { state, event, _ in
        if event.mods.shift && (event.key == .command("d") || event.key == .command("D")) {
            state.playgroundOpen.toggle()
            return true
        }
        return false
    },
    view: mainView
)
.scene("prefs") { $0.playgroundOpen = false }
.scene("playground") { $0.playgroundOpen = true; $0.activeStory = .toggle }
.scene("upload") { $0.playgroundOpen = true; $0.activeStory = .upload; $0.uploadProgress = 64 }
.scene("toast") { $0.playgroundOpen = true; $0.activeStory = .toast }

try RuneApp.run(spec)
