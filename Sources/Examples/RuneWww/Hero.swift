import Foundation
import Rune

/// The hero: wordmark, heading, lede, actions, and the interactive live card (`www/app/src/hero.rs`).
public enum WwwHero {
    public static let springs: [(name: String, spring: Spring)] = [
        ("Snappy", Spring(duration: 0.25, bounce: 0.0)),
        ("Smooth", Spring(duration: 0.4, bounce: 0.0)),
        ("Bouncy", Spring(duration: 0.5, bounce: 0.3)),
    ]

    public static let cardWidth: Float = 376.0
    public static let stageHeight: Float = 320.0
    public static let puckSize: Float = 28.0
    public static let stops: Int = 4

    public struct Card: Sendable {
        public var on: Bool = true
        public var spring: Int = 2
        public var at: Float = 0.0
        var dragData: Float = 0.0
        var grabbed: Bool = false

        public init() {}
    }

    private static func snap(_ at: Float) -> Float {
        let n = Float(stops - 1)
        return (at * n).rounded() / n
    }

    private static func switchEl(_ c: Card) -> El<WwwState> {
        let t = Tok.theme(dark: true)
        let w: Float = 44.0
        let h: Float = 26.0
        let k: Float = 22.0
        let inset = (h - k) * 0.5
        return el()
            .key("switch")
            .role(.switchControl)
            .label("Lights")
            .checked(c.on)
            .focusable(true)
            .size(w, h)
            .rounded(h * 0.5)
            .bg(c.on ? WwwTokens.ink : t.controlOff)
            .motion(springs[c.spring].spring)
            .onClick { state, _ in
                state.card.on.toggle()
            }
            .child(
                el()
                    .key("knob")
                    .size(k, k)
                    .rounded(k * 0.5)
                    .bg(t.knob)
                    .absolute(x: c.on ? (w - k - inset) : inset, y: inset)
                    .shadow(Shadow(x: 0.0, y: 1.0, blur: 3.0, color: t.knobShadow))
            )
    }

    private static func picker(_ c: Card, seg: Float) -> El<WwwState> {
        let t = Tok.theme(dark: true)
        let h: Float = 32.0
        let pad: Float = 3.0
        var segs: El<WwwState> = row().key("springs")
        for (i, entry) in springs.enumerated() {
            let selected = i == c.spring
            segs = segs.child(
                el()
                    .key(entry.name)
                    .role(.radio)
                    .label(entry.name)
                    .checked(selected)
                    .focusable(true)
                    .size(seg, h - 2.0 * pad)
                    .center()
                    .onClick { state, _ in
                        state.card.spring = i
                    }
                    .child(
                        text(entry.name)
                            .font(TextStyle(size: 13.0, weight: 500.0))
                            .color(selected ? t.text : t.textSecondary)
                    )
            )
        }
        return el()
            .key("picker")
            .role(.radiogroup)
            .label("Spring")
            .size(seg * 3.0 + 2.0 * pad, h)
            .rounded(h * 0.5)
            .bg(t.controlTrack)
            .child(
                el()
                    .key("thumb")
                    .size(seg, h - 2.0 * pad)
                    .rounded((h - 2.0 * pad) * 0.5)
                    .absolute(x: pad + seg * Float(c.spring), y: pad)
                    .bg(oklcha(1.0, 0.0, 0.0, 0.12))
                    .motion(springs[c.spring].spring)
            )
            .child(segs.absolute(x: pad, y: pad))
    }

    private static func track(_ c: Card, trackW: Float) -> El<WwwState> {
        let t = Tok.theme(dark: true)
        let travel = trackW - puckSize
        func toAt(_ x: Float) -> Float {
            ((x - puckSize * 0.5) / max(1.0, travel)).clamped(to: 0...1)
        }

        var stopsRow: El<WwwState> = row().key("stops").w(travel).h(puckSize).absolute(x: puckSize * 0.5, y: 0.0)
        for i in 0..<stops {
            let x = travel * Float(i) / Float(stops - 1)
            stopsRow = stopsRow.child(
                el()
                    .key("stop-\(i)")
                    .size(4.0, 4.0)
                    .rounded(2.0)
                    .bg(oklcha(1.0, 0.0, 0.0, 0.22))
                    .absolute(x: x - 2.0, y: puckSize * 0.5 - 2.0)
            )
        }

        return el()
            .key("track")
            .role(.slider)
            .label("Puck")
            .rangeValue(Double(c.at), min: 0.0, max: 1.0)
            .rangeStep(1.0 / Double(stops - 1))
            .onStep { state, steps, _ in
                state.card.at = snap(state.card.at + Float(steps) / Float(stops - 1)).clamped(to: 0...1)
            }
            .size(trackW, puckSize)
            .motion(springs[c.spring].spring)
            .onPointerDown { state, press, _ in
                state.card.dragData = state.card.at
                state.card.grabbed = true
                let puck = puckSize * 0.5 + state.card.at * travel
                if abs(press.local.x - puck) > puckSize * 0.5 + 4.0 {
                    state.card.at = snap(toAt(press.local.x))
                }
            }
            .onDrag { state, d, tx in
                let puck = puckSize * 0.5 + state.card.dragData * travel
                let grab = abs(d.startLocal.x - puck) <= puckSize * 0.5 + 4.0 ? (d.startLocal.x - puck) : 0.0
                state.card.at = toAt(d.local.x - grab)
                tx.instant()
            }
            .onDragEnd { state, cancelled, _ in
                guard state.card.grabbed else { return }
                state.card.grabbed = false
                state.card.at = cancelled ? state.card.dragData : snap(state.card.at)
            }
            .child(
                el()
                    .key("rail")
                    .size(travel, 2.0)
                    .rounded(1.0)
                    .bg(t.controlOff)
                    .absolute(x: puckSize * 0.5, y: puckSize * 0.5 - 1.0)
                    .a11yHidden()
            )
            .child(
                el()
                    .key("lit")
                    .size(travel * c.at, 2.0)
                    .rounded(1.0)
                    .bg(WwwTokens.ink)
                    .absolute(x: puckSize * 0.5, y: puckSize * 0.5 - 1.0)
                    .a11yHidden()
            )
            .child(stopsRow.a11yHidden())
            .child(
                el()
                    .key("puck")
                    .size(puckSize, puckSize)
                    .rounded(puckSize * 0.5)
                    .bg(t.knob)
                    .absolute(x: travel * c.at, y: 0.0)
                    .shadow(Shadow(x: 0.0, y: 2.0, blur: 8.0, color: oklcha(0.0, 0.0, 0.0, 0.5)))
                    .a11yHidden()
            )
    }

    private static func lineOf(_ key: String, label: String, control: El<WwwState>) -> El<WwwState> {
        let t = Tok.theme(dark: true)
        return row()
            .key(key)
            .wFull()
            .h(36.0)
            .centerY()
            .child(text(label).font(TextStyle(size: 14.0, weight: 400.0)).color(t.textSecondary).grow(1.0))
            .child(control)
    }

    private static func live(_ c: Card, cx: Cx<WwwState>, bp: WwwBreakpoint) -> El<WwwState> {
        let stage = cx.layoutSize("stage").flatMap { $0.first } ?? 520.0
        let cardW = (stage - 16.0).clamped(to: 280.0...cardWidth)
        let pad: Float = cardW < cardWidth ? 20.0 : 32.0
        let inner = cardW - 2.0 * pad
        let seg = min((inner - 76.0) / 3.0, 88.0)

        let card: El<WwwState> = col()
            .key("card")
            .w(cardW)
            .p(pad)
            .gap(16.0)
            .rounded(20.0)
            .bg(oklch(0.17, 0.006, 265.0))
            .border(1.0, oklcha(1.0, 0.0, 0.0, 0.08))
            .child(lineOf("lights", label: "Lights", control: switchEl(c)))
            .child(lineOf("spring", label: "Spring", control: picker(c, seg: seg)))
            .child(el().key("gap").h(8.0))
            .child(track(c, trackW: inner))

        let liveFig: El<WwwState> = col()
            .key("live")
            .htmlRole("figure")
            .minW(0.0)
            .child(
                col()
                    .key("stage")
                    .wFull()
                    .h(stageHeight)
                    .center()
                    .rounded(WwwTokens.r2)
                    .bg(.black)
                    .border(1.0, WwwTokens.line)
                    .child(card)
            )
            .child(
                text("Drawn by Rune, live. Flip the switch, pick a spring, throw the puck.")
                    .key("caption")
                    .font(WwwTokens.text13)
                    .color(WwwTokens.fg3)
                    .wrap(.wrap)
                    .mt(12.0)
            )

        return bp.stackHero ? liveFig.wFull() : liveFig.w(520.0)
    }

    public static func hero(
        _ s: WwwState,
        cx: Cx<WwwState>,
        bp: WwwBreakpoint,
        glow: WwwWordmark.Glow
    ) -> El<WwwState> {
        let glyphsWidth = Float(s.glyphs.width)
        let cell: UInt8 = cx.layoutWith("hero-text") { r in
            UInt8((r[2] / max(1.0, glyphsWidth)).rounded(.down).clamped(to: 2.0...10.0))
        } ?? 8
        let reduced = cx.isReducedMotion()

        let masthead: El<WwwState> = col()
            .key("masthead")
            .wFull()
            .label("Rune")
            .role(.image)
            .onHover { state, on, _ in
                if on {
                    let now = state.clockNow()
                    state.glints.masthead(now)
                }
            }
            .onVisible { state, on, _ in
                let now = state.clockNow()
                state.glints.mastheadVisible(on, reduced: reduced, now: now)
            }
            .child(WwwWordmark.wordmark(s.glyphs, cell: Float(cell), glow: glow))

        var textCol: El<WwwState> = col().key("hero-text").minW(0.0)
        textCol = bp.stackHero ? textCol.wFull() : textCol.w(0.0).grow(1.0)
        textCol = textCol
            .child(masthead)
            .child(
                text("A Rust UI framework that draws every frame itself, at 120\u{00A0}Hz.")
                    .key("hero-h")
                    .headingLevel(1)
                    .font(bp.h1)
                    .color(WwwTokens.fg)
                    .wrap(.wrap)
                    .selectable(true)
                    .maxW(bp.h1.size * 16.0)
                    .mt(bp.phone ? 32.0 : 48.0)
            )
            .child(
                WwwUI.prose(
                    "lede",
                    "Rune brings its own GPU renderer, text, layout and springs. Views are plain Rust, a small app's first window opens in about 300\u{00A0}ms, and the same code runs on macOS, Windows, Linux, iOS and the web.",
                    style: bp.lede,
                    color: WwwTokens.fg2
                )
                .maxW(WwwTokens.measureWidth)
                .mt(24.0)
            )
            .child(
                row()
                    .key("actions")
                    .flexWrap()
                    .gap(12.0)
                    .mt(32.0)
                    .child(WwwUI.button("github", "View on GitHub", href: WwwConstants.repo, kind: .github))
                    .child(WwwUI.button("guide", "Read the guide", href: WwwConstants.docs, kind: .secondary))
            )

        let body: El<WwwState> = bp.stackHero
            ? col().gap(48.0)
            : row().gap(64.0).centerY()
        return body
            .key("hero")
            .wFull()
            .pt(bp.stackHero ? 32.0 : 64.0)
            .pb(128.0)
            .child(textCol)
            .child(live(s.card, cx: cx, bp: bp))
    }
}
