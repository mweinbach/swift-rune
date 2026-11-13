import Foundation
import Rune

/// One frame's path as a row/column of steps with a heated comet animation (`www/app/src/pipeline.rs`).
public enum WwwPipeline {
    public static let steps: [(name: String, note: String)] = [
        ("Input", "pointer, keys, text"),
        ("State", "your struct, changed"),
        ("View", "your view, called again"),
        ("Diff", "keyed, against the last"),
        ("Layout", "flex and grid, by Taffy"),
        ("Springs", "position and velocity"),
        ("Draw", "one instanced draw"),
    ]

    public static let travel: Double = 1.8
    public static let rise: Double = 0.06
    public static let tau: Double = 0.32
    public static let cometSize: Float = 64.0
    public static let gapRow: Float = 12.0
    public static let gapCol: Float = 8.0

    public struct Light: Equatable, Sendable {
        public static let dark = Light(heat: [Float](repeating: 0.0, count: 7), head: 0.0, comet: 0.0)
        public var heat: [Float]
        public var head: Float
        public var comet: Float
    }

    public struct Pipeline: Sendable {
        private var start: Double?
        private var fade: Double?
        private var played: Bool = false
        private var visible: Bool = false
        private var t: Double = 0.0

        public init() {}

        public var active: Bool {
            start != nil || fade != nil
        }

        public mutating func play(now: Double, reduced: Bool) {
            if reduced {
                fade = now
            } else {
                start = now
            }
        }

        public mutating func setVisible(_ on: Bool, now: Double, reduced: Bool) {
            visible = on
            if !on {
                start = nil
                fade = nil
            } else if !played {
                played = true
                play(now: now, reduced: reduced)
            }
        }

        public func light() -> Light {
            if let f = fade {
                let s = t - f
                let h = Float(s < 0.75 ? WwwPipeline.smootherstep(s / 0.15) : (1.0 - WwwPipeline.smootherstep((s - 0.75) / 0.15)))
                return Light(heat: [Float](repeating: h, count: 7), head: 0.0, comet: 0.0)
            }
            guard let start else { return .dark }
            let elapsed = t - start
            let tail = elapsed - WwwPipeline.travel
            let comet: Float = tail < 0.0 ? 1.0 : Float(exp(-tail / WwwPipeline.tau))
            var heat = [Float](repeating: 0.0, count: 7)
            for i in 0..<7 {
                let since = elapsed - WwwPipeline.passes(i)
                let tau = (i == WwwPipeline.steps.count - 1) ? WwwPipeline.tau * 2.5 : WwwPipeline.tau
                let v: Double
                if since < 0.0 {
                    v = 0.0
                } else if since < WwwPipeline.rise {
                    v = since / WwwPipeline.rise
                } else {
                    v = exp(-(since - WwwPipeline.rise) / tau)
                }
                heat[i] = v > 0.004 ? Float(v) : 0.0
            }
            return Light(
                heat: heat,
                head: Float(WwwPipeline.smootherstep(elapsed / WwwPipeline.travel)),
                comet: comet > 0.004 ? comet : 0.0
            )
        }

        @discardableResult
        public mutating func tick(_ now: Double) -> Bool {
            t = now
            if let f = fade, now - f >= 0.9 {
                fade = nil
            }
            if let s = start {
                let l = light()
                let lit = (now - s < WwwPipeline.travel) || l.comet > 0.0 || l.heat.contains(where: { $0 > 0.0 })
                if !lit {
                    start = nil
                }
            }
            return start != nil || fade != nil
        }
    }

    private static func smootherstep(_ x: Double) -> Double {
        let clamped = min(max(x, 0.0), 1.0)
        return clamped * clamped * clamped * (clamped * (clamped * 6.0 - 15.0) + 10.0)
    }

    private static func passes(_ i: Int) -> Double {
        let target = Double(i) / Double(steps.count - 1)
        var lo = 0.0
        var hi = 1.0
        for _ in 0..<18 {
            let m = (lo + hi) * 0.5
            if smootherstep(m) < target { lo = m } else { hi = m }
        }
        return lo * travel
    }

    private static func centers(w: Float, h: Float, stacked: Bool) -> [Vec2] {
        let n = Float(steps.count)
        return (0..<steps.count).map { idx in
            let i = Float(idx)
            if stacked {
                let step = (h - gapCol * (n - 1.0)) / n
                return Vec2(w * 0.5, i * (step + gapCol) + step * 0.5)
            } else {
                let step = (w - gapRow * (n - 1.0)) / n
                return Vec2(i * (step + gapRow) + step * 0.5, h * 0.5)
            }
        }
    }

    private static func along(_ c: [Vec2], p: Float) -> Vec2 {
        let clamped = p.clamped(to: 0...1)
        let span = Float(c.count - 1) * clamped
        let i = min(Int(floorf(span)), c.count - 2)
        let f = span - Float(i)
        let a = c[i]
        let b = c[i + 1]
        return Vec2(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f)
    }

    private static func stepElement(_ i: Int, heat: Float, stacked: Bool) -> El<WwwState> {
        let (name, note) = steps[i]
        let body: El<WwwState> = stacked
            ? row().justifyBetween().gap(16.0)
            : col().gap(4.0).minH(96.0).w(0.0).grow(1.0)
        let glow = WwwTokens.ink.alpha(0.35)
        return body
            .key("pl-\(name.lowercased())")
            .role(.listItem)
            .p(12.0)
            .rounded(WwwTokens.r2)
            .bg(oklch(0.15, 0.004, 265.0))
            .border(1.0, WwwTokens.line)
            .child(
                el()
                    .key("heat")
                    .pin(top: 0.0, right: 0.0, bottom: 0.0, left: 0.0)
                    .rounded(WwwTokens.r2)
                    .bg(WwwTokens.ink.alpha(0.18))
                    .border(1.0, WwwTokens.ink.alpha(0.7))
                    .shadow(Shadow(x: 0.0, y: 0.0, blur: 24.0, color: glow))
                    .opacity(heat)
                    .a11yHidden()
            )
            .child(text(name).key("name").font(WwwTokens.text14Medium).color(WwwTokens.fg))
            .child(text(note).key("note").font(WwwTokens.mono12).color(WwwTokens.fg3).wrap(.wrap))
    }

    public static func pipeline(
        _ p: Pipeline,
        size: [Float]?,
        bp: WwwBreakpoint,
        reduced: Bool
    ) -> El<WwwState> {
        let stacked = bp.stackSplit
        let light = p.light()
        let w = size.flatMap { $0.count >= 2 ? $0[0] : nil } ?? 1000.0
        let h = size.flatMap { $0.count >= 2 ? $0[1] : nil } ?? 96.0
        let c = centers(w: w, h: h, stacked: stacked)
        let a = c[0]
        let b = c[steps.count - 1]
        let wire: El<WwwState> = stacked
            ? el().size(1.0, b.y - a.y)
            : el().size(b.x - a.x, 1.0)
        let head = along(c, p: light.head)
        let cometStops: [GradientStop] = [
            GradientStop(WwwTokens.glint, at: 0.0),
            GradientStop(WwwTokens.ink.alpha(0.6), at: 0.2),
            GradientStop(.transparent, at: 1.0),
        ]
        let comet: El<WwwState> = el()
            .key("comet")
            .size(cometSize, cometSize)
            .rounded(cometSize * 0.5)
            .radialGradient(
                center: Vec2(0.5, 0.5),
                radius: .pixels(cometSize * 0.5),
                stops: cometStops
            )
            .absolute(x: head.x - cometSize * 0.5, y: head.y - cometSize * 0.5)
            .opacity(light.comet)
            .a11yHidden()

        var list: El<WwwState> = (stacked ? col().gap(gapCol) : row().gap(gapRow))
            .key("pl")
            .role(.list)
            .label("One frame, step by step")
            .wFull()
        for i in 0..<steps.count {
            list = list.child(stepElement(i, heat: light.heat[i], stacked: stacked))
        }

        let diagram: El<WwwState> = col()
            .key("pl-box")
            .wFull()
            .onClick { state, _ in
                let now = state.clockNow()
                state.pipeline.play(now: now, reduced: reduced)
            }
            .onVisible { state, on, _ in
                let now = state.clockNow()
                state.pipeline.setVisible(on, now: now, reduced: reduced)
            }
            .child(wire.key("wire").bg(WwwTokens.line2).absolute(x: a.x, y: a.y).a11yHidden())
            .child(comet)
            .child(list)

        return col()
            .key("pipeline")
            .htmlRole("figure")
            .wFull()
            .mt(32.0)
            .child(diagram)
            .child(
                text("Click the diagram to run the frame again.")
                    .key("caption")
                    .font(WwwTokens.text13)
                    .color(WwwTokens.fg3)
                    .wrap(.wrap)
                    .maxW(WwwTokens.measureWidth)
                    .mt(12.0)
            )
    }
}
