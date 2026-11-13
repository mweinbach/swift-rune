import Foundation
import Rune

/// Port of `examples/glass-card`: two borderless windows (`pattern` + transparent `card` with
/// `SystemMaterial.glass` / `.popover`), spring-animated frame & corner radius, and `LoopSpec` backdrop.
private let canvasSize = Vec2(760, 480)
private let magenta = Color(r: 1.0, g: 0.0, b: 1.0, a: 1.0)

public struct GlassCardState: Sendable {
    public var docked: Bool = false
    public var busyMs: UInt64 = 0
    public var measure: Bool = false
    public var material: SystemMaterial = .glass

    public static func initial(environment: [String: String] = ProcessInfo.processInfo.environment) -> GlassCardState {
        let busyMs = environment["GLASS_CARD_BUSY_MS"].flatMap { UInt64($0) } ?? 0
        let measure = environment["GLASS_CARD_PATTERN"] == "black"
        let material: SystemMaterial = environment["GLASS_CARD_POPOVER"] != nil ? .popover : .glass
        return GlassCardState(docked: false, busyMs: busyMs, measure: measure, material: material)
    }
}

private func cardFrame(docked: Bool) -> (x: Float, y: Float, w: Float, h: Float, radius: Float) {
    if docked {
        return (canvasSize.x - 290, canvasSize.y - 94, 250, 60, 30)
    } else {
        return (70, 60, 400, 260, 28)
    }
}

public func cardView(_ s: GlassCardState, _ cx: inout Cx<GlassCardState>) -> El<GlassCardState> {
    let f = cardFrame(docked: s.docked)
    let actionLabel = s.docked ? "Fly" : "Dock"

    let button: El<GlassCardState> = row()
        .key("toggle")
        .role(.button)
        .label(actionLabel)
        .h(30)
        .px(14)
        .center()
        .rounded(15)
        .bg(Color.white.alpha(0.18))
        .border(1, Color.white.alpha(0.3))
        .onClick { state in state.docked.toggle() }
        .child(
            text(actionLabel)
                .font(TextStyle(size: 13.0, weight: 600.0))
                .color(.white)
        )

    let title: El<GlassCardState> = text(s.docked ? "Docked" : "Liquid glass")
        .key("title")
        .font(TextStyle(size: s.docked ? 15.0 : 26.0, weight: 650.0))
        .color(.white)

    var card: El<GlassCardState> = col()
        .key("card")
        .absolute(x: f.x, y: f.y)
        .size(f.w, f.h)
        .rounded(f.radius)
        .p(s.docked ? 16 : 26)
        .gap(12)
        .shadow(Shadow(y: 18, blur: 44, color: Color(r: 0, g: 0, b: 0, a: 0.35)))
        .systemMaterial(s.material)
        .animateLayout(Spring(duration: 0.7, bounce: 0.22))
        .animate(Spring(duration: 0.7, bounce: 0.22))

    if s.measure {
        card = card.border(2.0, magenta)
    }

    if s.docked {
        card = card.child(
            row()
                .wFull()
                .hFull()
                .itemsCenter()
                .gap(12)
                .child(title)
                .child(el().grow(1))
                .child(button)
        )
    } else {
        let body: El<GlassCardState> = text(
            "Frame and corner radius on one spring. The material moves in the same transaction as this text, its shadow and the button."
        )
        .key("body")
        .wFull()
        .wrap(.wrap)
        .font(TextStyle(size: 14.0, weight: 450.0))
        .color(Color.white.alpha(0.85))

        card = card
            .child(title)
            .child(body)
        if s.busyMs > 0 {
            card = card.child(
                text("Main thread busy \(s.busyMs) ms a frame")
                    .key("busy")
                    .font(TextStyle(size: 12.0, weight: 500.0))
                    .color(Color.white.alpha(0.7))
            )
        }
        card = card
            .child(el().grow(1))
            .child(
                row()
                    .wFull()
                    .child(el().grow(1))
                    .child(button)
            )
    }

    return el()
        .key("root")
        .sizeFull()
        .child(card)
}

public func patternView(measure: Bool) -> El<Void> {
    if measure {
        return el()
            .key("pattern")
            .sizeFull()
            .bg(Color(r: 0, g: 0, b: 0, a: 1))
    }

    let cols = 16
    let rows = 10
    let tileW = canvasSize.x / Float(cols)
    let tileH = canvasSize.y / Float(rows)

    var pattern: El<Void> = el()
        .key("pattern")
        .sizeFull()
        .bg(Color(r: 0.1, g: 0.1, b: 0.12, a: 1.0))

    for i in 0..<(cols * rows) {
        let c = i % cols
        let r = i / cols
        let light: Float = (c + r).isMultiple(of: 2) ? 0.78 : 0.42
        pattern = pattern.child(
            el()
                .absolute(x: Float(c) * tileW, y: Float(r) * tileH)
                .size(tileW, tileH)
                .bg(Color.oklch(light, 0.16, Float((i * 23) % 360)))
        )
    }

    for k in 0..<6 {
        let barColor = k.isMultiple(of: 2) ? Color.white : Color(r: 0, g: 0, b: 0, a: 1)
        pattern = pattern.child(
            el()
                .absolute(x: 0, y: 0)
                .size(36, canvasSize.y)
                .bg(barColor)
                .loopSlide(
                    period: 3.6,
                    from: Vec2(-1.0, 0.0),
                    to: Vec2(canvasSize.x / 36.0, 0.0),
                    delay: Double(k) * 0.6
                )
        )
    }

    for k in 0..<3 {
        pattern = pattern.child(
            text("RUNE 120 Hz")
                .font(TextStyle(size: 64.0, weight: 800.0))
                .color(.white)
                .absolute(x: 40, y: 60 + Float(k) * 170)
                .loopSlide(
                    period: 4.0,
                    from: Vec2(0.0, 0.0),
                    to: Vec2(0.9, 0.0),
                    delay: Double(k) * 1.3
                )
        )
    }

    return pattern
}

@main
public enum RuneGlassCardApp {
    private static func busyPoll(_ s: inout GlassCardState, _ now: Double, _ tx: inout Tx) -> Bool {
        if s.busyMs > 0 {
            Thread.sleep(forTimeInterval: Double(s.busyMs) / 1000.0)
        }
        return false
    }

    private static func onKey(_ s: inout GlassCardState, _ event: KeyEvent, _ tx: inout Tx) -> Bool {
        switch event.key {
        case .space, .text(" "):
            s.docked.toggle()
            return true
        case .text("b"):
            s.busyMs = s.busyMs > 0 ? 0 : 8
            return true
        default:
            return false
        }
    }

    public static func makeWindows(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [AnyWindowSpec] {
        let place = environment["GLASS_CARD_AT"].flatMap { raw -> (Float, Float)? in
            let parts = raw.split(separator: ",", maxSplits: 1)
            guard parts.count == 2, let x = Float(parts[0]), let y = Float(parts[1]) else { return nil }
            return (x, y)
        }
        let originPt = place ?? (80.0, 80.0)
        let origin: (Int32, Int32) = (Int32((originPt.0 * 2.0).rounded()), Int32((originPt.1 * 2.0).rounded()))
        let measure = environment["GLASS_CARD_PATTERN"] == "black"

        let patternApp = App<Void>(
            title: "Glass card pattern",
            size: canvasSize,
            minSize: canvasSize,
            state: (),
            view: { _, _ in patternView(measure: measure) }
        )
        .args([])

        let traceArgs: [String] = environment["GLASS_CARD_TRACE"].map { ["--native", "--trace", $0] } ?? []
        let cardApp = App<GlassCardState>(
            title: "Glass card",
            size: canvasSize,
            minSize: canvasSize,
            state: GlassCardState.initial(environment: environment),
            view: cardView
        )
        .poll(busyPoll)
        .onKey(onKey)
        .scene("floating") { s, _ in s.docked = false; s.measure = false }
        .scene("docked") { s, _ in s.docked = true; s.measure = false }
        .scene("measure") { s, _ in s.docked = false; s.measure = true }
        .args(traceArgs)

        let cardHandle = cardApp.handle()
        let parsed = ToolingArgs.parse(Array(arguments.dropFirst()))
        if !parsed.isHeadlessRequested {
            if environment["GLASS_CARD_MANUAL"] == nil {
                DispatchQueue.global(qos: .utility).async {
                    while true {
                        Thread.sleep(forTimeInterval: 1.6)
                        cardHandle.update { state, _ in state.docked.toggle() }
                    }
                }
            }
            if let secStr = environment["GLASS_CARD_SECONDS"], let seconds = Double(secStr), seconds > 0 {
                DispatchQueue.global(qos: .utility).async {
                    Thread.sleep(forTimeInterval: seconds)
                    cardHandle.quit()
                }
            }
        }

        let at = WindowOptions(
            minSize: canvasSize,
            resizable: false,
            alwaysOnTop: true,
            borderless: true,
            position: origin
        )
        var over = at
        over.transparent = true
        let overConfigured = over.macos(MacWindowOptions(shadow: false))

        var patternWin = AppWindowSpec.fromApp(patternApp).options(at)
        patternWin.key = "pattern"

        var cardWin = AppWindowSpec.fromApp(cardApp).configuredOptions(overConfigured)
        cardWin.key = "card"

        return [patternWin.boxed(), cardWin.boxed()]
    }

    @MainActor
    public static func main() throws {
        try RuneMultiWindow.runWindows(makeWindows())
    }
}
