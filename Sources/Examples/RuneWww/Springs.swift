import Foundation
import Rune
import RuneMotion

/// Interactive springs trace demo (`www/app/src/springs.rs`).
public enum WwwSprings {
    public static let springs: [(name: String, note: String, spring: Spring)] = [
        ("Snappy", "0.25s", Spring(duration: 0.25, bounce: 0.0)),
        ("Smooth", "0.4s", Spring(duration: 0.4, bounce: 0.0)),
        ("Bouncy", "0.5s · 0.3", Spring(duration: 0.5, bounce: 0.3)),
    ]

    public static let stops: Int = 5
    public static let window: Double = 2.4
    public static let stageHeight: Float = 72.0
    public static let traceHeight: Float = 96.0
    public static let puckSize: Float = 32.0
    public static let grabRadius: Float = 22.0

    public struct Sample: Sendable {
        public var t: Double
        public var x: Float
        public var target: Float
        public var kick: Bool
    }

    public struct Grab: Sendable {
        public var offset: Float
        public var pts: [(Double, Float)]
        public var live: Bool
    }

    public struct Demo: Sendable {
        public var which: Int = 2
        public var keep: Bool = true
        private var anim = Animated<Float>(0.0)
        public var samples: [Sample] = []
        private var kicked: Bool = false
        private var lastMotion: Double = -.infinity
        private var grab: Grab?
        private var visible: Bool = false
        private var isRunning: Bool = false
        public var x: Float = 0.0
        public var t: Double = 0.0

        public init() {}

        private func spring() -> Spring {
            WwwSprings.springs[which].spring
        }

        public var running: Bool { isRunning }
        public var target: Float { anim.target }

        public static func snap(_ x: Float) -> Float {
            let n = Float(WwwSprings.stops - 1)
            return (x.clamped(to: 0...1) * n).rounded() / n
        }

        public mutating func retarget(to target: Float, now: Double, reduced: Bool) {
            if reduced {
                anim.set(target)
            } else if keep {
                anim.animateTo(target, anim: Anim<Float>(curve: .spring(spring())), at: now)
            } else {
                anim.animateTo(target, anim: Anim<Float>(curve: .spring(spring()), velocityRule: .zero), at: now)
            }
            kick(now)
        }

        private mutating func kick(_ now: Double) {
            kicked = true
            lastMotion = now
            if visible {
                isRunning = true
            }
        }

        public mutating func step(dir: Int, now: Double, reduced: Bool) {
            let to = Demo.snap(anim.target + Float(dir) / Float(WwwSprings.stops - 1))
            retarget(to: to, now: now, reduced: reduced)
        }

        public mutating func press(at: Float, travel: Float, now: Double, reduced: Bool) {
            let cur = anim.sample(at: now)
            let onPuck = abs(at - cur) * travel < WwwSprings.grabRadius
            grab = Grab(offset: at - cur, pts: [(now, at)], live: onPuck)
            if onPuck {
                anim.set(cur)
                kick(now)
            } else {
                retarget(to: at, now: now, reduced: reduced)
            }
        }

        public mutating func drag(at: Float, travel: Float, now: Double) {
            guard var g = grab else { return }
            g.pts.append((now, at))
            if g.pts.count > 6 {
                g.pts.removeFirst()
            }
            if !g.live {
                if abs(at - g.pts[0].1) * travel < 4.0 {
                    grab = g
                    return
                }
                g.live = true
                g.offset = at - anim.sample(at: now)
            }
            grab = g
            anim.set((at - g.offset).clamped(to: 0...1))
            kick(now)
        }

        public mutating func release(now: Double, reduced: Bool, cancelled: Bool = false) {
            guard let g = grab.take() else { return }
            guard g.live else { return }
            if cancelled {
                retarget(to: Demo.snap(anim.sample(at: now)), now: now, reduced: reduced)
                return
            }
            let recent = g.pts.filter { now - $0.0 < 0.1 }
            let v: Float
            if recent.count > 1, let a = recent.first, let b = recent.last {
                v = (b.1 - a.1) / max(0.008, Float(b.0 - a.0))
            } else {
                v = 0.0
            }
            let cur = anim.sample(at: now)
            let target = Demo.snap(cur + v * 0.12)
            if reduced {
                anim.set(target)
            } else {
                anim.release(velocity: keep ? v : 0.0, target: target, curve: .spring(spring()), at: now)
            }
            kick(now)
        }

        public mutating func setVisible(_ on: Bool, now: Double) {
            visible = on
            isRunning = on && (now - lastMotion < WwwSprings.window)
        }

        @discardableResult
        public mutating func tick(_ now: Double) -> Bool {
            guard isRunning else { return false }
            if grab != nil || !anim.isSettled(at: now) {
                lastMotion = now
            }
            x = anim.sample(at: now)
            t = now
            samples.append(Sample(t: now, x: x, target: anim.target, kick: kicked))
            kicked = false
            while samples.count > 2 && samples[1].t < now - WwwSprings.window {
                samples.removeFirst()
            }
            if now - lastMotion > WwwSprings.window {
                isRunning = false
            }
            return true
        }
    }

    private static func travel(_ w: Float) -> Float {
        max(1.0, w - 64.0)
    }

    private static func frac(_ x: Float, width w: Float) -> Float {
        ((x - 32.0) / travel(w)).clamped(to: 0...1)
    }

    private static func dashed(
        onto initialShape: Shape,
        points: [Vec2],
        on: Float,
        off: Float,
        width: Float,
        color: Color
    ) -> Shape {
        var shape = initialShape
        var phase: Float = 0.0
        guard points.count >= 2 else { return shape }
        for idx in 0..<(points.count - 1) {
            let a = points[idx]
            let b = points[idx + 1]
            let len = hypotf(b.x - a.x, b.y - a.y)
            guard len > 0 else { continue }
            var d: Float = 0.0
            let period = on + off
            while d < len {
                let into = phase.truncatingRemainder(dividingBy: period)
                let left = into < on ? (on - into) : (period - into)
                let step = min(left, len - d)
                if into < on {
                    let p0 = Vec2(a.x + (b.x - a.x) * d / len, a.y + (b.y - a.y) * d / len)
                    let p1 = Vec2(a.x + (b.x - a.x) * (d + step) / len, a.y + (b.y - a.y) * (d + step) / len)
                    shape = shape.line(p0, p1, width: width, cap: .butt, color: color)
                }
                d += step
                phase += step
            }
        }
        return shape
    }

    private static func trace(_ d: Demo, width w: Float) -> Shape {
        let h = traceHeight
        let pad: Float = 8.0
        func xAt(_ t: Double) -> Float {
            w - Float((d.t - t) / window) * w
        }
        func yAt(_ v: Float) -> Float {
            h - pad - (v + 0.15) / 1.3 * (h - 2.0 * pad)
        }
        var shape = Shape()
        guard d.samples.count >= 2 else { return shape }
        let targetPts = d.samples.map { Vec2(xAt($0.t), yAt($0.target)) }
        shape = dashed(onto: shape, points: targetPts, on: 2.0, off: 4.0, width: 1.0, color: Color.white.alpha(0.12))
        let pathPts = d.samples.map { Vec2(xAt($0.t), yAt($0.x)) }
        shape = shape.stroke(pathPts, width: 1.5, color: WwwTokens.ink)
        for s in d.samples where s.kick {
            shape = WwwUI.shapeDot(center: Vec2(xAt(s.t), yAt(s.x)), radius: 2.5, color: WwwTokens.glint, onto: shape)
        }
        return shape
    }

    private static func segmented(_ d: Demo, stacked: Bool) -> El<WwwState> {
        var segs: El<WwwState> = row()
            .key("springs")
            .role(.radiogroup)
            .label("Spring")
            .p(3.0)
            .rounded(18.0)
            .bg(WwwTokens.surface2)
        for (i, entry) in springs.enumerated() {
            let on = i == d.which
            let seg: El<WwwState> = stacked
                ? col().py(4.0)
                : row().h(30.0).gap(8.0).centerY()
            segs = segs.child(
                seg
                    .key(entry.name)
                    .role(.radio)
                    .label(entry.name)
                    .checked(on)
                    .focusable(true)
                    .px(12.0)
                    .rounded(15.0)
                    .bg(on ? WwwTokens.surface3 : .transparent)
                    .hoverGroup()
                    .onClick { state, _ in
                        state.spring.which = i
                    }
                    .child(
                        text(entry.name)
                            .font(TextStyle(size: 13.0, weight: 500.0).lh(20.0))
                            .color(on ? WwwTokens.fg : WwwTokens.fg2)
                            .groupColor(WwwTokens.fg)
                    )
                    .child(text(entry.note).font(WwwTokens.mono12).color(WwwTokens.fg3).a11yHidden())
            )
        }
        return segs
    }

    private static func checkbox(_ on: Bool) -> El<WwwState> {
        var box: El<WwwState> = el().key("box").size(16.0, 16.0).rounded(4.0).center()
        if on {
            let tick = Shape().viewBox(16.0, 16.0).stroke(
                [Vec2(4.0, 8.5), Vec2(7.0, 11.5), Vec2(12.0, 5.0)],
                width: 2.0,
                color: .black
            )
            box = box.bg(WwwTokens.ink).child(canvas(tick).key("tick").size(16.0, 16.0))
        } else {
            box = box.border(1.5, WwwTokens.line2)
        }
        return row()
            .key("keep")
            .role(.checkbox)
            .label("Keep velocity")
            .checked(on)
            .focusable(true)
            .gap(8.0)
            .centerY()
            .onClick { state, _ in
                state.spring.keep.toggle()
            }
            .child(box.a11yHidden())
            .child(text("Keep velocity").font(WwwTokens.text14).color(WwwTokens.fg2).a11yHidden())
    }

    public static func demo(
        _ s: WwwState,
        cx: Cx<WwwState>,
        bp: WwwBreakpoint
    ) -> El<WwwState> {
        let d = s.spring
        let reduced = cx.isReducedMotion()
        let w = cx.layoutSize("spring-stage").flatMap { $0.first } ?? 600.0
        let travelW = travel(w)

        var rail: El<WwwState> = el()
            .key("rail")
            .h(2.0)
            .rounded(1.0)
            .bg(WwwTokens.surface3)
            .pin(top: 35.0, right: 32.0, left: 32.0)
            .a11yHidden()
        for i in 0..<stops {
            let x = travelW * Float(i) / Float(stops - 1)
            rail = rail.child(
                el()
                    .key("stop-\(i)")
                    .size(4.0, 4.0)
                    .rounded(2.0)
                    .bg(WwwTokens.line2)
                    .absolute(x: x - 2.0, y: -1.0)
            )
        }

        let puck: El<WwwState> = el()
            .key("puck")
            .size(puckSize, puckSize)
            .rounded(puckSize * 0.5)
            .bg(WwwTokens.fg)
            .absolute(x: 16.0 + d.x * travelW, y: 20.0)
            .shadows([
                Shadow(x: 0.0, y: 2.0, blur: 8.0, color: oklcha(0.0, 0.0, 0.0, 0.5)),
                Shadow(x: 0.0, y: 0.0, blur: 0.0, spread: 4.0, color: WwwTokens.ink.alpha(0.25), inset: false),
            ])
            .a11yHidden()

        let stage: El<WwwState> = el()
            .key("spring-stage")
            .wFull()
            .h(stageHeight)
            .rounded(WwwTokens.r2)
            .bg(WwwTokens.surface1)
            .border(1.0, WwwTokens.line)
            .role(.slider)
            .label("Puck position")
            .focusable(true)
            .rangeValue(Double(d.target), min: 0.0, max: 1.0)
            .rangeStep(1.0 / Double(stops - 1))
            .onStep { state, steps, _ in
                let now = state.clockNow()
                let dir = steps > 0 ? 1 : (steps < 0 ? -1 : 0)
                state.spring.step(dir: dir, now: now, reduced: reduced)
            }
            .onPointerDown { state, press, _ in
                let now = state.clockNow()
                let at = frac(press.local.x, width: press.elementSize.x)
                state.spring.press(at: at, travel: travel(press.elementSize.x), now: now, reduced: reduced)
            }
            .onDrag { state, dragEv, _ in
                let now = state.clockNow()
                let at = frac(dragEv.local.x, width: dragEv.size.x)
                state.spring.drag(at: at, travel: travel(dragEv.size.x), now: now)
            }
            .onDragEnd { state, cancelled, _ in
                let now = state.clockNow()
                state.spring.release(now: now, reduced: reduced, cancelled: cancelled)
            }
            .onVisible { state, on, _ in
                let now = state.clockNow()
                state.spring.setVisible(on, now: now)
            }
            .child(rail)
            .child(puck)

        let traceW = cx.layoutSize("trace").flatMap { $0.first } ?? w
        let traceCanvas: El<WwwState> = canvas(trace(d, width: traceW))
            .key("trace")
            .wFull()
            .h(traceHeight)
            .mt(8.0)
            .clipFadeLinear(dx: traceW * 0.25, dy: 0.0, from: 0.0, to: 0.0)
            .a11yHidden()

        let controls: El<WwwState> = row()
            .key("controls")
            .wFull()
            .justifyBetween()
            .flexWrap()
            .rowGap(12.0)
            .columnGap(24.0)
            .centerY()
            .mt(16.0)
            .child(segmented(d, stacked: bp.narrow))
            .child(checkbox(d.keep))

        return col()
            .key("spring-demo")
            .htmlRole("figure")
            .wFull()
            .mt(32.0)
            .child(stage)
            .child(traceCanvas)
            .child(controls)
            .child(
                text("Click the track, then click somewhere else before the puck lands. Or grab it and throw it. Turn off \u{201C}Keep velocity\u{201D} to see a spring that starts from rest every time.")
                    .key("caption")
                    .font(WwwTokens.text13)
                    .color(WwwTokens.fg3)
                    .wrap(.wrap)
                    .maxW(WwwTokens.measureWidth)
                    .mt(12.0)
            )
    }
}
