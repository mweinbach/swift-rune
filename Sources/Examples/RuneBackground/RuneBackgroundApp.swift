import Foundation
import Rune

public struct BackgroundState: Sendable {
    public var ticks: UInt64 = 0
    public var closes: UInt32 = 0
    public var note: TextEdit = TextEdit("Type here, close, reopen")
    public var hudSeconds: UInt64 = 0
    public var hudTranscribing: Bool = false
    public var capsulePresses: UInt32 = 0

    public init() {}
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

public func backgroundView(_ s: BackgroundState, _ cx: inout Cx<BackgroundState>) -> El<BackgroundState> {
    let t = Tok.theme(dark: cx.systemDark)
    return col()
        .key("window")
        .bg(t.bg)
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
                .child(bgButton(key: "close", label: "Close window", t: t) { _, tx in
                    tx.closeWindow()
                })
                .child(bgButton(key: "quit", label: "Quit", t: t) { _, tx in
                    tx.requestQuit()
                })
        )
}

public func backgroundHudView(_ s: BackgroundState, _ cx: inout Cx<BackgroundState>) -> El<BackgroundState> {
    let label = s.hudTranscribing
        ? "Transcribing"
        : String(format: "Recording %d:%02d", s.hudSeconds / 60, s.hudSeconds % 60)
    let dotColor = s.hudSeconds.isMultiple(of: 2)
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
        .hFull()
        .center()
        .child(pill)
}

public func backgroundCapsuleView(_ s: BackgroundState, _ cx: inout Cx<BackgroundState>) -> El<BackgroundState> {
    let t = Tok.theme(dark: true)
    return row()
        .key("capsule")
        .wFull()
        .hFull()
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
                    fputs("background: capsule pressed \(state.capsulePresses)\n", stderr)
                }
                .child(text("Press").font(Tok.Typography.label).color(t.text))
        )
}

public func onBackgroundKey(_ s: inout BackgroundState, _ ev: KeyEvent, _ tx: inout Tx) -> Bool {
    switch ev.key {
    case .command("w"):
        tx.closeWindow()
        return true
    case .command("q"):
        tx.requestQuit()
        return true
    default:
        return false
    }
}

private final class OverlayBox: @unchecked Sendable {
    let lock = NSLock()
    var handle: OverlayHandle<BackgroundState>?
}

@main
public enum RuneBackgroundApp {
    public static func makeApp(arguments: [String] = Array(CommandLine.arguments.dropFirst())) -> App<BackgroundState> {
        let hudBox = OverlayBox()
        let capsuleBox = OverlayBox()
        let isHeadless = ToolingArgs.parse(arguments).isHeadlessRequested
        let customArgs = arguments.filter {
            $0 != "--open" && $0 != "--accessory" && $0 != "--release-gpu" && $0 != "--hud-large"
        }

        var app = App<BackgroundState>(
            title: "Background",
            size: Vec2(480, 420),
            state: BackgroundState(),
            view: backgroundView
        )
        .args(RunOptions(arguments: customArgs))
        .keepRunning(true)
        .onKey(onBackgroundKey)
        .onClose { state, _ in
            state.closes += 1
            fputs("background: window closed; still running\n", stderr)
            return true
        }
        .onWindow { window in
            fputs("background: native window \(window.title)\n", stderr)
        }
        .scene("ticked") { state, _ in
            state.ticks = 42
        }

        // Only enable windowless when interactive and `--open` was omitted; in headless CLI
        // mode (`--snap`/`--tree`/`--script`) HeadlessRunner renders the main window directly.
        if !isHeadless && !arguments.contains("--open") {
            app = app.windowless(true)
        }
        if arguments.contains("--accessory") {
            app = app.accessory(true)
        }
        if arguments.contains("--release-gpu") {
            app = app.releaseGpuWhenClosed(true)
        }

        let hudSize = arguments.contains("--hud-large") ? Vec2(1200, 700) : Vec2(240, 44)
        app = app.overlay(
            OverlaySpec(
                name: "background-hud",
                size: hudSize,
                options: OverlayOptions(placement: .edge(.top, margin: 16), keyPolicy: .nonActivating),
                makeState: { BackgroundState() },
                view: backgroundHudView
            )
        ) { handle in
            hudBox.lock.lock()
            hudBox.handle = handle
            hudBox.lock.unlock()
        }

        app = app.overlay(
            OverlaySpec(
                name: "background-capsule",
                size: Vec2(220, 48),
                options: OverlayOptions(placement: .edge(.top, margin: 40), keyPolicy: .nonActivating),
                makeState: { BackgroundState() },
                view: backgroundCapsuleView
            )
        ) { handle in
            capsuleBox.lock.lock()
            capsuleBox.handle = handle
            capsuleBox.lock.unlock()
        }

        if !isHeadless {
            let ticker = app.handle()
            Thread.detachNewThread {
                while true {
                    Thread.sleep(forTimeInterval: 1.0)
                    ticker.update { state, _ in
                        state.ticks += 1
                    }
                    hudBox.lock.lock()
                    let hud = hudBox.handle
                    hudBox.lock.unlock()
                    hud?.update { state in
                        state.hudSeconds += 1
                    }
                }
            }

            let commands = app.handle()
            Thread.detachNewThread {
                while let line = readLine() {
                    let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
                    guard let cmd = words.first else { continue }
                    let arg1 = words.count > 1 ? words[1] : nil
                    hudBox.lock.lock()
                    let hud = hudBox.handle
                    hudBox.lock.unlock()
                    capsuleBox.lock.lock()
                    let capsule = capsuleBox.handle
                    capsuleBox.lock.unlock()

                    switch (cmd, arg1) {
                    case ("open", _): commands.open()
                    case ("show", _): commands.show()
                    case ("hide", _): commands.hide()
                    case ("focus", _): commands.focus()
                    case ("position", let sx?):
                        if words.count > 2, let x = Float(sx), let y = Float(words[2]) {
                            commands.setPosition(Vec2(x, y))
                        }
                    case ("activate", _): commands.activate()
                    case ("close", _): commands.close()
                    case ("quit", _): commands.quit()
                    case ("status", _):
                        fputs("background: visible \(commands.isVisible), window error \(String(describing: commands.windowError))\n", stderr)
                    case ("dock", let on?):
                        fputs("background: dock \(on) pending @platform AppHandle.setDockIcon(_ visible: Bool)\n", stderr)
                    case ("hud", "show"): hud?.show()
                    case ("hud", "hide"): hud?.hide()
                    case ("hud", "transcribing"): hud?.update { $0.hudTranscribing = true }
                    case ("hud", "recording"): hud?.update { $0.hudTranscribing = false }
                    case ("hud", "top"), ("hud", "bottom"), ("hud", "status"):
                        fputs("background: hud placement/status pending @platform dynamic overlay API\n", stderr)
                    case ("capsule", "show"): capsule?.show()
                    case ("capsule", "hide"): capsule?.hide()
                    case ("capsule", "left"), ("capsule", "wide"), ("capsule", "status"):
                        fputs("background: capsule placement/resize/status pending @platform dynamic overlay API\n", stderr)
                    default:
                        fputs(
                            "background: unknown command \(cmd) (open | show | hide | focus | position X Y | activate TOKEN | close | dock on|off | hud show|hide|top|bottom|recording|transcribing|status | capsule show|hide|left|wide|status | quit)\n",
                            stderr
                        )
                    }
                }
            }
        }

        return app
    }

    public static func main() throws {
        try makeApp().run()
    }
}
