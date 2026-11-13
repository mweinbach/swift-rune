import Foundation
import Rune

/// Port of `examples/playground`: a small Preferences window with `App.playground` (⌘⇧D),
/// grouped stories, triggers, variants, side-column control, viewport presets, and scenes.
public enum PrefSection: String, CaseIterable, Sendable {
    case general = "General"
    case sync = "Sync"
    case devices = "Devices"
}

public struct PlaygroundPrefsState: Sendable {
    public var section: PrefSection = .general
    public var launchAtLogin: Bool = true
    public var sounds: Bool = false
    public var sync: Bool = true
    public var wifiOnly: Bool = true
    public var devices: [String] = ["Studio desk", "Travel laptop"]

    // Sub-story states hosted cleanly on PlaygroundHost<PlaygroundPrefsState>
    public var switchOn: Bool = true
    public var switchDimmed: Bool = false
    public var switchLabel: String = "Sync across devices"

    public var uploadProgress: Int = 0
    public var uploadRunning: Bool = false
    public var uploadLast: Double = 0.0
    public var uploadReplayStart: Double? = nil
    public var uploadReplayPending: Bool = false
    public var uploadPausedByReplay: Bool = false
    public var uploadResumedByReplay: Bool = false

    public var toastMessage: String = "Synced 3 devices"
    public var toastFailed: Bool = false

    public init(
        section: PrefSection = .general,
        launchAtLogin: Bool = true,
        sounds: Bool = false,
        sync: Bool = true,
        wifiOnly: Bool = true,
        devices: [String] = ["Studio desk", "Travel laptop"],
        switchOn: Bool = true,
        switchDimmed: Bool = false,
        switchLabel: String = "Sync across devices",
        uploadProgress: Int = 0,
        uploadRunning: Bool = false,
        toastMessage: String = "Synced 3 devices",
        toastFailed: Bool = false
    ) {
        self.section = section
        self.launchAtLogin = launchAtLogin
        self.sounds = sounds
        self.sync = sync
        self.wifiOnly = wifiOnly
        self.devices = devices
        self.switchOn = switchOn
        self.switchDimmed = switchDimmed
        self.switchLabel = switchLabel
        self.uploadProgress = uploadProgress
        self.uploadRunning = uploadRunning
        self.toastMessage = toastMessage
        self.toastFailed = toastFailed
    }
}

private let everyDeviceList: [String] = [
    "Studio desk", "Travel laptop", "Kitchen tablet", "Spare phone", "Lab machine", "Old desktop",
    "Living room TV", "Garage Pi", "Work phone", "Reading tablet", "Build server", "Test phone",
    "Backup drive", "Guest laptop", "Car display", "Watch", "Office printer", "Media box",
    "Shared iPad", "Loaner laptop", "Render node", "Home server", "Second monitor hub", "Field kit",
]

private func switchControl(
    _ t: ThemeTokens,
    _ accent: Color,
    key: String,
    label: String,
    on: Bool,
    flip: @escaping (inout PlaygroundPrefsState) -> Void
) -> El<PlaygroundPrefsState> {
    let w: Float = 34
    let h: Float = 20
    let k: Float = 16
    let knob: El<PlaygroundPrefsState> = el()
        .size(k, k)
        .absolute(x: on ? (w - k - 2) : 2, y: 2)
        .rounded(k * 0.5)
        .bg(t.knob)
        .shadow(Shadow(y: 1, blur: 3, color: t.knobShadow))
        .animateLayout(Tok.Motion.SNAPPY)

    return row()
        .key(key)
        .wFull()
        .h(44)
        .px(12)
        .itemsCenter()
        .justifyBetween()
        .rounded(Tok.Radius.MD)
        .bg(t.card)
        .border(1, t.cardBorder)
        .role(.switchControl)
        .label(label)
        .onClick(flip)
        .child(text(label).font(Tok.Typography.body).color(t.text))
        .child(
            el()
                .size(w, h)
                .rounded(h * 0.5)
                .bg(on ? accent : t.controlOff)
                .animate(Tok.Motion.SNAPPY)
                .child(knob)
        )
}

private func devicesListView(_ s: PlaygroundPrefsState, _ cx: inout Cx<PlaygroundPrefsState>) -> El<PlaygroundPrefsState> {
    let t = Tok.theme(dark: cx.systemDark)
    var list: El<PlaygroundPrefsState> = col()
        .key("devices")
        .wFull()
        .rounded(Tok.Radius.MD)
        .bg(t.card)
        .border(1, t.cardBorder)
    for (i, name) in s.devices.enumerated() {
        var entry: El<PlaygroundPrefsState> = col().key("device-\(i)").wFull()
        if i > 0 {
            entry = entry.child(el().wFull().h(1).bg(t.separator))
        }
        let content: El<PlaygroundPrefsState> = row()
            .wFull()
            .h(36)
            .px(12)
            .itemsCenter()
            .justifyBetween()
            .child(text(name).font(Tok.Typography.body).color(t.text))
            .child(text(i == 0 ? "This device" : "Synced").font(Tok.Typography.label).color(t.textSecondary))
        entry = entry.child(content)
        list = list.child(entry)
    }
    return list
}

private func devicesPage(_ s: PlaygroundPrefsState, _ cx: inout Cx<PlaygroundPrefsState>) -> El<PlaygroundPrefsState> {
    col()
        .wFull()
        .hFull()
        .p(24)
        .child(devicesListView(s, &cx))
}

private func switchStoryView(_ s: PlaygroundPrefsState, _ cx: inout Cx<PlaygroundPrefsState>) -> El<PlaygroundPrefsState> {
    let t = Tok.theme(dark: cx.systemDark)
    let accent = Tok.accent(0, dark: cx.systemDark)
    return col()
        .wFull()
        .hFull()
        .center()
        .child(
            col()
                .w(300)
                .child(
                    switchControl(t, accent, key: "switch", label: s.switchLabel, on: s.switchOn) {
                        $0.switchOn.toggle()
                    }
                    .opacity(s.switchDimmed ? 0.5 : 1.0)
                )
        )
}

private func uploadPoll(_ u: inout PlaygroundPrefsState, _ t: Double, _ tx: inout Tx) -> Bool {
    var changed = false
    if u.uploadReplayPending {
        u.uploadReplayPending = false
        u.uploadReplayStart = t
        u.uploadLast = t
        changed = true
    }
    if let start = u.uploadReplayStart {
        let elapsed = t - start
        if elapsed >= 0.6 && !u.uploadPausedByReplay {
            u.uploadPausedByReplay = true
            u.uploadRunning = false
            changed = true
        }
        if elapsed >= 1.2 && !u.uploadResumedByReplay {
            u.uploadResumedByReplay = true
            u.uploadRunning = true
            u.uploadLast = t
            tx.wakeAfter(0.0)
            changed = true
        }
        if u.uploadPausedByReplay && !u.uploadResumedByReplay {
            tx.wakeAfter(max(0.0, 1.2 - elapsed))
            return changed
        }
    }
    guard u.uploadRunning else { return changed }
    tx.wakeAfter(0.1)
    if t - u.uploadLast < 0.1 { return changed }
    u.uploadLast = t
    u.uploadProgress = min(100, u.uploadProgress + 4)
    u.uploadRunning = u.uploadProgress < 100
    return true
}

private func uploadView(_ u: PlaygroundPrefsState, _ cx: inout Cx<PlaygroundPrefsState>) -> El<PlaygroundPrefsState> {
    let t = Tok.theme(dark: cx.systemDark)
    let accent = Tok.accent(0, dark: cx.systemDark)
    let label: String
    switch (u.uploadRunning, u.uploadProgress) {
    case (true, _): label = "Pause"
    case (false, 100): label = "Again"
    case (false, 0): label = "Start"
    default: label = "Resume"
    }
    let track: Float = 240
    return col()
        .wFull()
        .hFull()
        .center()
        .gap(12)
        .child(text("Uploading backup · \(u.uploadProgress)%").font(Tok.Typography.body).color(t.text))
        .child(
            el()
                .w(track)
                .h(6)
                .rounded(3)
                .bg(t.controlTrack)
                .child(
                    el()
                        .w(track * Float(u.uploadProgress) / 100.0)
                        .h(6)
                        .rounded(3)
                        .bg(accent)
                        .animateLayout(Tok.Motion.SNAPPY)
                )
        )
        .child(
            row()
                .key("upload-toggle")
                .h(28)
                .px(14)
                .center()
                .rounded(Tok.Radius.SM)
                .bg(t.controlTrack)
                .hover(t.hover)
                .role(.button)
                .label(label)
                .onClick { state, tx in
                    if state.uploadProgress == 100 { state.uploadProgress = 0 }
                    state.uploadRunning.toggle()
                    tx.wakeAfter(0.0)
                }
                .child(text(label).font(Tok.Typography.label).color(t.text))
        )
}

private func toastView(_ s: PlaygroundPrefsState, _ cx: inout Cx<PlaygroundPrefsState>) -> El<PlaygroundPrefsState> {
    let t = Tok.theme(dark: cx.systemDark)
    return el()
        .wFull()
        .hFull()
        .center()
        .child(
            row()
                .h(36)
                .px(16)
                .gap(8)
                .itemsCenter()
                .rounded(18)
                .bg(t.card)
                .border(1, t.cardBorder)
                .shadow(Shadow(y: 4, blur: 16, color: t.shadowSoft))
                .child(el().square(8).rounded(4).bg(Tok.accent(s.toastFailed ? 3 : 4, dark: cx.systemDark)))
                .child(text(s.toastMessage).font(Tok.Typography.body).color(t.text))
        )
}

private func deviceCountSide(_ s: PlaygroundPrefsState, _ cx: inout Cx<PlaygroundPrefsState>) -> El<PlaygroundPrefsState> {
    let t = Tok.theme(dark: cx.systemDark)
    func stepButton(_ key: String, _ label: String, _ action: @escaping (inout PlaygroundPrefsState) -> Void) -> El<PlaygroundPrefsState> {
        row()
            .key(key)
            .size(24, 24)
            .center()
            .rounded(Tok.Radius.SM)
            .hover(t.hover)
            .press(t.press)
            .role(.button)
            .label(label)
            .onClick(action)
            .child(text(label).font(Tok.Typography.body).color(t.text))
    }

    return row()
        .key("device-count")
        .wFull()
        .h(36)
        .pl(12)
        .pr(6)
        .gap(2)
        .itemsCenter()
        .rounded(Tok.Radius.LG)
        .bg(t.card)
        .border(1, t.cardBorder)
        .child(text("Devices").font(Tok.Typography.body).color(t.text))
        .child(el().grow(1))
        .child(text("\(s.devices.count)").font(Tok.Typography.body).color(t.textSecondary).pr(6))
        .child(stepButton("fewer", "−") { if $0.devices.count > 1 { $0.devices.removeLast() } })
        .child(stepButton("more", "+") { $0.devices.append("New device") })
}

public func preferencesView(_ s: PlaygroundPrefsState, _ cx: inout Cx<PlaygroundPrefsState>) -> El<PlaygroundPrefsState> {
    let t = Tok.theme(dark: cx.systemDark)
    let accent = Tok.accent(0, dark: cx.systemDark)

    var nav: El<PlaygroundPrefsState> = col()
        .key("nav")
        .w(176)
        .hFull()
        .pt(cx.titlebarInset() > 0 ? 44 : 12)
        .px(8)
        .gap(2)
    for sec in PrefSection.allCases {
        let on = (s.section == sec)
        nav = nav.child(
            row()
                .key(sec.rawValue)
                .wFull()
                .h(28)
                .px(10)
                .itemsCenter()
                .rounded(Tok.Radius.SM)
                .bg(on ? t.controlTrack : .transparent)
                .hover(on ? t.controlTrack : t.hover)
                .role(.tab)
                .label(sec.rawValue)
                .onClick { $0.section = sec }
                .child(text(sec.rawValue).font(Tok.Typography.body).color(t.text))
        )
    }

    let body: El<PlaygroundPrefsState>
    switch s.section {
    case .general:
        body = col()
            .gap(8)
            .child(switchControl(t, accent, key: "launch", label: "Open at login", on: s.launchAtLogin) {
                $0.launchAtLogin.toggle()
            })
            .child(switchControl(t, accent, key: "sounds", label: "Play sounds", on: s.sounds) {
                $0.sounds.toggle()
            })
    case .sync:
        var syncCol = col()
            .gap(8)
            .child(switchControl(t, accent, key: "sync", label: "Sync across devices", on: s.sync) {
                $0.sync.toggle()
            })
            .child(
                switchControl(t, accent, key: "wifi", label: "Only on Wi-Fi", on: s.wifiOnly && s.sync) {
                    $0.wifiOnly.toggle()
                }
                .opacity(s.sync ? 1.0 : 0.5)
            )
        if !s.sync {
            syncCol = syncCol.child(
                text("Changes stay on this device until sync is back on.")
                    .font(Tok.Typography.body)
                    .color(t.textSecondary)
                    .px(4)
            )
        }
        body = syncCol
    case .devices:
        body = devicesListView(s, &cx)
    }

    return row()
        .wFull()
        .hFull()
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
                .child(text(s.section.rawValue).font(Tok.Typography.title).color(t.text))
                .child(body)
        )
}

@main
public enum RunePlaygroundApp {
    public static func makeHost() -> PlaygroundHost<PlaygroundPrefsState> {
        PlaygroundHost<PlaygroundPrefsState>()
            .enabled(true)
            .page("Lists/Live devices", view: devicesPage)
            .trigger("Lists/Many devices", key: "a", label: "Add device") { s, _ in
                s.devices.append("New device")
            }
            .trigger("Lists/Many devices", key: "x", label: "Remove the last") { s, _ in
                if !s.devices.isEmpty { s.devices.removeLast() }
            }
            .side("Lists/Many devices", view: deviceCountSide)
            .variant("Lists/Many devices", name: "Six") { _ in }
            .variant("Lists/Many devices", name: "Just this one") { s in
                s.devices = Array(s.devices.prefix(1))
            }
            .variant("Lists/Many devices", name: "Long names") { s in
                s.devices = [
                    "Studio desk in the back office",
                    "Travel laptop (borrowed for the conference)",
                    "Kitchen tablet",
                ]
            }
            .story(
                PlaygroundStory(
                    path: "Lists/Every device",
                    makeState: {
                        PlaygroundPrefsState(devices: everyDeviceList)
                    },
                    view: { s, _, cx in
                        col().wFull().hFull().scroll().child(devicesListView(s, &cx))
                    }
                )
            )
            .story(
                PlaygroundStory(
                    path: "Windows/Preferences",
                    makeState: { PlaygroundPrefsState() },
                    view: { s, _, cx in preferencesView(s, &cx) }
                )
            )
            .story(
                PlaygroundStory(
                    path: "Progress/Upload",
                    makeState: { PlaygroundPrefsState() },
                    view: { s, _, cx in uploadView(s, &cx) }
                )
            )
            .trigger("Progress/Upload", key: "r", label: "Run, pause, resume") { u, tx in
                u.uploadRunning = true
                u.uploadReplayPending = true
                u.uploadReplayStart = nil
                u.uploadPausedByReplay = false
                u.uploadResumedByReplay = false
                tx.wakeAfter(0.0)
            }
            .trigger("Progress/Upload", key: "f", label: "Finish") { u, _ in
                u.uploadProgress = 100
                u.uploadRunning = false
            }
            .variant("Progress/Upload", name: "From the start") { _ in }
            .variant("Progress/Upload", name: "Half done") { $0.uploadProgress = 48 }
            .story(
                PlaygroundStory(
                    path: "Toasts/Sync toast",
                    makeState: { PlaygroundPrefsState() },
                    view: { s, _, cx in toastView(s, &cx) }
                )
            )
            .trigger("Toasts/Sync toast", key: "e", label: "Fail") { s, _ in
                s.toastMessage = "Sync failed, retrying"
                s.toastFailed = true
            }
            .variant("Toasts/Sync toast", name: "Synced") { _ in }
            .variant("Toasts/Sync toast", name: "Failed") { s in
                s.toastMessage = "Sync failed, retrying"
                s.toastFailed = true
            }
            .story(
                PlaygroundStory(
                    path: "Controls/Switches/Toggle",
                    makeState: { PlaygroundPrefsState(switchOn: true, switchDimmed: false, switchLabel: "Sync across devices") },
                    view: { s, _, cx in switchStoryView(s, &cx) }
                )
            )
            .trigger("Controls/Switches/Toggle", key: "t", label: "Flip") { s, _ in
                s.switchOn.toggle()
            }
            .variant("Controls/Switches/Toggle", name: "On") { _ in }
            .variant("Controls/Switches/Toggle", name: "Off") { $0.switchOn = false }
            .variant("Controls/Switches/Toggle", name: "Dimmed") { $0.switchDimmed = true }
            .story(
                PlaygroundStory(
                    path: "Controls/Switches/Long label",
                    makeState: {
                        PlaygroundPrefsState(switchOn: false, switchDimmed: false, switchLabel: "Only sync over Wi-Fi when on battery")
                    },
                    view: { s, _, cx in switchStoryView(s, &cx) }
                )
            )
            .story(
                PlaygroundStory(
                    path: "Controls/Rows/Two devices",
                    makeState: { PlaygroundPrefsState(devices: ["Studio desk", "Travel laptop"]) },
                    view: { s, _, cx in devicesListView(s, &cx) }
                )
            )
            .story(
                PlaygroundStory(
                    path: "Controls/Rows/One device",
                    makeState: { PlaygroundPrefsState(devices: ["Studio desk"]) },
                    view: { s, _, cx in devicesListView(s, &cx) }
                )
            )
            .story(
                PlaygroundStory(
                    path: "Controls/Rows/Long names",
                    makeState: {
                        PlaygroundPrefsState(devices: [
                            "Studio desk in the back office",
                            "Travel laptop (borrowed for the conference)",
                        ])
                    },
                    view: { s, _, cx in devicesListView(s, &cx) }
                )
            )
            .groupOrder(["Controls"])
            .startFolded(true)
            .viewportPresets([
                ViewportPreset(name: "Compact", size: Vec2(420, 300)),
                ViewportPreset(name: "Wide", size: Vec2(900, 560)),
            ])
    }

    public static func makeApp() -> App<PlaygroundPrefsState> {
        App<PlaygroundPrefsState>(
            title: "Preferences",
            size: Vec2(640, 420),
            state: PlaygroundPrefsState(),
            view: preferencesView
        )
        .scene("Sections/General") { s, _ in
            s.section = .general
        }
        .scene("Sections/Sync paused") { s, _ in
            s.section = .sync
            s.sync = false
        }
        .scene("Lists/Many devices") { s, _ in
            s.section = .devices
            s.devices.append(contentsOf: ["Kitchen tablet", "Spare phone", "Lab machine", "Old desktop"])
        }
        .poll(uploadPoll)
        .playground(makeHost())
    }

    @MainActor
    public static func main() throws {
        try makeApp().run()
    }
}
