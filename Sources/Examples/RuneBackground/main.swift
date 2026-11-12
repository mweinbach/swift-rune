import Foundation
import Rune

struct BackgroundState {
    var ticks: UInt64 = 0
    var closes: UInt32 = 0
    var windowHidden: Bool = false
    var note: TextEdit = TextEdit("Type here, close, reopen")
    var hudVisible: Bool = true
    var hudBottom: Bool = false
    var transcribing: Bool = false
    var capsuleVisible: Bool = true
    var capsuleWide: Bool = false
    var capsulePresses: UInt32 = 0
}

private func bgButton(
    key: String,
    label: String,
    t: ThemeTokens,
    action: @escaping (inout BackgroundState, inout Tx) -> Void
) -> El<BackgroundState> {
    row()
        .key(key)
        .role(.button)
        .label(label)
        .h(28)
        .px(Tok.Space.md)
        .center()
        .rounded(Tok.Radius.md)
        .bg(t.card)
        .hover(t.hover)
        .border(1, t.cardBorder)
        .onClick(action)
        .child(text(label).font(Tok.Typography.label).color(t.text))
}

private func hudPill(_ s: BackgroundState) -> El<BackgroundState> {
    let mins = s.ticks / 60
    let secs = s.ticks % 60
    let label = s.transcribing
        ? "Transcribing"
        : String(format: "Recording %d:%02d", mins, secs)
    let dotColor = s.ticks.isMultiple(of: 2)
        ? oklch(0.65, 0.2, 25.0)
        : oklch(0.45, 0.12, 25.0)

    let pill: El<BackgroundState> = row()
        .key("pill")
        .h(36)
        .px(Tok.Space.md)
        .gap(Tok.Space.sm)
        .center()
        .rounded(18)
        .bg(oklch(0.20, 0.0, 0.0))
        .border(1, oklch(0.30, 0.0, 0.0))
        .child(el().key("dot").size(8, 8).rounded(4).bg(dotColor))
        .child(text(label).key("label").font(Tok.Typography.label).color(oklch(0.93, 0.0, 0.0)))

    return row()
        .key("hud")
        .wFull()
        .h(44)
        .center()
        .child(pill)
}

private func capsuleOverlay(_ s: BackgroundState) -> El<BackgroundState> {
    let t = Tok.theme(dark: true)
    return row()
        .key("capsule")
        .w(s.capsuleWide ? 320 : 220)
        .h(48)
        .px(Tok.Space.sm)
        .gap(Tok.Space.sm)
        .center()
        .rounded(24)
        .bg(t.card)
        .border(1, t.cardBorder)
        .child(
            text("Pressed \(s.capsulePresses) times")
                .key("presses")
                .font(Tok.Typography.label)
                .color(t.text)
        )
        .child(
            row()
                .key("press")
                .role(.button)
                .label("Press")
                .h(28)
                .px(Tok.Space.md)
                .center()
                .rounded(Tok.Radius.md)
                .bg(t.controlOff)
                .hover(t.hover)
                .onClick { state, _ in
                    state.capsulePresses += 1
                    FileHandle.standardError.write(Data("background: capsule pressed \(state.capsulePresses)\n".utf8))
                }
                .child(text("Press").font(Tok.Typography.label).color(t.text))
        )
}

private func backgroundView(_ s: BackgroundState, _ cx: inout Cx<BackgroundState>) -> El<BackgroundState> {
    let t = Tok.theme(dark: cx.systemDark)

    var mainContent: El<BackgroundState> = col()
        .key("window")
        .wFull()
        .grow(1)
        .px(Tok.Space.xl)
        .py(Tok.Space.xl)
        .gap(Tok.Space.md)
        .child(text("Background app").key("title").font(Tok.Typography.title).color(t.text))
        .child(
            text("\(s.ticks) ticks from a background thread, window closed \(s.closes) times")
                .key("ticks")
                .font(Tok.Typography.body)
                .color(t.textSecondary)
        )
        .child(
            el()
                .key("note-field")
                .wFull()
                .h(32)
                .px(Tok.Space.sm)
                .rounded(Tok.Radius.md)
                .bg(t.card)
                .border(1, t.cardBorder)
                .itemsCenter()
                .child(
                    textInput(key: "note", \.note)
                        .font(Tok.Typography.body)
                        .color(t.text)
                )
        )
        .child(
            row()
                .key("actions")
                .gap(Tok.Space.sm)
                .child(bgButton(key: "close", label: s.windowHidden ? "Reopen window" : "Close window", t: t) { state, _ in
                    if state.windowHidden {
                        state.windowHidden = false
                    } else {
                        state.closes += 1
                        state.windowHidden = true
                        FileHandle.standardError.write(Data("background: window closed; still running\n".utf8))
                    }
                })
                .child(bgButton(key: "tick", label: "Tick", t: t) { state, _ in
                    state.ticks += 1
                })
                .child(bgButton(key: "quit", label: "Quit", t: t) { _, tx in
                    tx.quit()
                })
        )
        .child(
            row()
                .key("overlay-controls")
                .gap(Tok.Space.sm)
                .child(bgButton(key: "toggle-hud", label: s.hudVisible ? "Hide HUD" : "Show HUD", t: t) { state, _ in
                    state.hudVisible.toggle()
                })
                .child(bgButton(key: "toggle-transcribing", label: s.transcribing ? "Recording" : "Transcribing", t: t) { state, _ in
                    state.transcribing.toggle()
                })
                .child(bgButton(key: "toggle-capsule", label: s.capsuleVisible ? "Hide Capsule" : "Show Capsule", t: t) { state, _ in
                    state.capsuleVisible.toggle()
                })
        )

    if s.windowHidden {
        mainContent = col()
            .key("window-closed")
            .wFull()
            .grow(1)
            .center()
            .gap(Tok.Space.md)
            .child(text("Window closed — background app still running (\(s.ticks) ticks)").font(Tok.Typography.body).color(t.textSecondary))
            .child(bgButton(key: "reopen", label: "Open window", t: t) { state, _ in
                state.windowHidden = false
            })
    }

    var root: El<BackgroundState> = col()
        .key("root")
        .wFull()
        .hFull()
        .bg(t.bg)

    if s.hudVisible && !s.hudBottom {
        root = root.child(row().wFull().pt(12).center().child(hudPill(s)))
    }

    root = root.child(mainContent)

    if s.capsuleVisible {
        root = root.child(
            row()
                .wFull()
                .px(12)
                .pb(12)
                .justifyEnd()
                .child(capsuleOverlay(s))
        )
    }

    if s.hudVisible && s.hudBottom {
        root = root.child(row().wFull().pb(12).center().child(hudPill(s)))
    }

    return root
}

private func onBackgroundKey(_ s: inout BackgroundState, _ ev: KeyEvent, _ tx: inout Tx) -> Bool {
    switch ev.key {
    case .command("w"):
        s.closes += 1
        s.windowHidden = true
        FileHandle.standardError.write(Data("background: window closed; still running\n".utf8))
        return true
    case .command("q"):
        tx.quit()
        return true
    default:
        return false
    }
}

let spec = AppSpec(
    title: "Background",
    size: Vec2(480, 420),
    state: BackgroundState(),
    onKey: onBackgroundKey,
    view: backgroundView
)
.scene("ticked") {
    $0.ticks = 42
}
.scene("transcribing") {
    $0.hudVisible = true
    $0.transcribing = true
}
.scene("capsule") {
    $0.capsuleVisible = true
    $0.capsulePresses = 3
    $0.capsuleWide = true
}

try RuneApp.run(spec)
