import Foundation
import RuneMotion

/// Port of `crates/rune-motion/examples/curves.rs`.
/// Generates five SVG plot sheets (`tokens.svg`, `swiftui.svg`, `curves.svg`, `retarget.svg`,
/// `presence-and-paths.svg`) into the output directory passed as argument 1 (or CWD/demo/motion).
public enum RuneMotionCurvesGenerator {
    static let blue = "#2f6fec"
    static let orange = "#e8833a"
    static let grey = "#9aa3ad"
    static let green = "#2fa35a"
    static let red = "#d64545"
    static let purple = "#8a5cd6"

    public struct Series: Sendable {
        public var points: [(Float, Float)]
        public var color: String
        public var dashed: Bool
        public var label: String
    }

    public struct Panel: Sendable {
        public var title: String
        public var x: (Float, Float)
        public var y: (Float, Float)
        public var series: [Series]
        public var marks: [Float]
        public var equalAxes: Bool
    }

    public static func renderSVG(panels: [Panel], cols: Int, pw: Float, ph: Float, title: String) -> String {
        let rows = (panels.count + cols - 1) / cols
        let side = max(Float(cols) * pw, Float(rows) * ph + 40.0)
        var s = String()
        s += "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(side)\" height=\"\(side)\" viewBox=\"0 0 \(side) \(side)\" font-family=\"-apple-system, Helvetica, sans-serif\">"
        s += "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>"
        s += "<text x=\"16\" y=\"26\" font-size=\"16\" font-weight=\"600\" fill=\"#222\">\(title)</text>"

        for (i, p) in panels.enumerated() {
            let ox = Float(i % cols) * pw
            let oy = Float(i / cols) * ph + 40.0
            let (l, t, r, b) = (ox + 44.0, oy + 28.0, ox + pw - 14.0, oy + ph - 26.0)
            let x0 = p.x.0
            var x1 = p.x.1
            let y0 = p.y.0
            var y1 = p.y.1
            if p.equalAxes {
                let span = max(x1 - x0, y1 - y0)
                x1 = x0 + span
                y1 = y0 + span
            }
            let px: (Float) -> Float = { x in l + (x - x0) / max(1e-6, x1 - x0) * (r - l) }
            let py: (Float) -> Float = { y in
                p.equalAxes
                    ? (t + (y - y0) / max(1e-6, y1 - y0) * (b - t))
                    : (b - (y - y0) / max(1e-6, y1 - y0) * (b - t))
            }
            s += "<rect x=\"\(l)\" y=\"\(t)\" width=\"\(r - l)\" height=\"\(b - t)\" fill=\"#fafbfc\" stroke=\"#e3e6ea\"/>"
            s += "<text x=\"\(l)\" y=\"\(t - 9.0)\" font-size=\"12\" font-weight=\"600\" fill=\"#333\">\(p.title)</text>"
            if !p.equalAxes {
                for v: Float in [0.0, 1.0] where v >= y0 && v <= y1 {
                    let yPos = py(v)
                    s += "<line x1=\"\(l)\" x2=\"\(r)\" y1=\"\(yPos)\" y2=\"\(yPos)\" stroke=\"#d5d9de\" stroke-dasharray=\"3 3\"/>"
                    s += "<text x=\"\(l - 4.0)\" y=\"\(yPos + 3.0)\" font-size=\"9\" fill=\"#888\" text-anchor=\"end\">\(v)</text>"
                }
                s += String(format: "<text x=\"%.1f\" y=\"%.1f\" font-size=\"9\" fill=\"#888\" text-anchor=\"end\">%.2f s</text>", r, b + 14.0, x1)
            }
            for m in p.marks {
                let xPos = px(m)
                s += "<line x1=\"\(xPos)\" x2=\"\(xPos)\" y1=\"\(t)\" y2=\"\(b)\" stroke=\"\(red)\" stroke-width=\"1\" stroke-dasharray=\"2 3\"/>"
            }
            for (k, se) in p.series.enumerated() {
                var d = ""
                for (j, pt) in se.points.enumerated() {
                    d += String(format: "%@%.2f,%.2f ", j == 0 ? "M" : "L", px(pt.0), py(pt.1))
                }
                let dash = se.dashed ? " stroke-dasharray=\"4 3\"" : ""
                s += "<path d=\"\(d)\" fill=\"none\" stroke=\"\(se.color)\" stroke-width=\"1.8\"\(dash)/>"
                if !se.label.isEmpty {
                    let ly = t + 12.0 + Float(k) * 12.0
                    s += "<text x=\"\(r - 4.0)\" y=\"\(ly)\" font-size=\"9\" fill=\"\(se.color)\" text-anchor=\"end\">\(se.label)</text>"
                }
            }
        }
        s += "</svg>"
        return s
    }

    static func normalized(_ pts: [(Float, Float)]) -> [(Float, Float)] {
        let m = pts.map { abs($0.1) }.reduce(1e-6, max)
        return pts.map { ($0.0, $0.1 / m) }
    }

    static func springPanel(name: String, spring: Spring, tMax: Float) -> Panel {
        let n = 300
        var x: [(Float, Float)] = []
        var v: [(Float, Float)] = []
        for i in 0...n {
            let t = tMax * Float(i) / Float(n)
            let sample = spring.sample(from: 0, velocity: 0, target: 1, at: t)
            x.append((t, sample.position))
            v.append((t, sample.velocity))
        }
        return Panel(
            title: "\(name)  \(spring.duration)/\(spring.bounce)",
            x: (0, tMax),
            y: (-0.45, 1.25),
            series: [
                Series(points: x, color: blue, dashed: false, label: "position"),
                Series(points: normalized(v), color: orange, dashed: true, label: "velocity (norm.)"),
            ],
            marks: [spring.duration],
            equalAxes: false
        )
    }

    static func curvePanel(name: String, curve: Curve, from: Float, to: Float, tMax: Float) -> Panel {
        let prop = Prop<Float>(id: PropId(64), propClass: .spatial, name: "x")
        let id = NodeId(1)
        var store = AnimationStore()
        store.snap(id, prop, to: from)
        store.set(id, prop, to: to, anim: Anim(curve: curve, blend: .merge), at: 0)
        var x: [(Float, Float)] = []
        var v: [(Float, Float)] = []
        for i in 0...300 {
            let t = tMax * Float(i) / 300.0
            store.sample(at: Double(t))
            x.append((t, store.get(id, prop) ?? to))
            v.append((t, store.velocity(id, prop).lanes[0]))
        }
        return Panel(
            title: name,
            x: (0, tMax),
            y: (-0.45, 1.25),
            series: [
                Series(points: x, color: blue, dashed: false, label: "position"),
                Series(points: normalized(v), color: orange, dashed: true, label: "velocity (norm.)"),
            ],
            marks: [],
            equalAxes: false
        )
    }

    static func retargetSeries(curve: Curve, blend: Blend, naive: Bool) -> ([(Float, Float)], [(Float, Float)]) {
        let prop = Prop<Float>(id: PropId(64), propClass: .spatial, name: "x")
        let id = NodeId(1)
        var store = AnimationStore()
        store.snap(id, prop, to: 0)
        store.set(id, prop, to: 1.0, anim: Anim(curve: curve, blend: blend), at: 0)
        let plan: [(Double, Float)] = [(0.15, 0.2), (0.32, 1.1), (0.55, 0.6)]
        var x: [(Float, Float)] = []
        var v: [(Float, Float)] = []
        var k = 0
        for i in 0...480 {
            let t = Double(i) / 400.0
            store.sample(at: t)
            if k < plan.count && t >= plan[k].0 {
                if naive {
                    let cur = store.get(id, prop) ?? 0
                    store.snap(id, prop, to: cur)
                }
                store.set(id, prop, to: plan[k].1, anim: Anim(curve: curve, blend: blend), at: t)
                k += 1
            }
            x.append((Float(t), store.get(id, prop) ?? 0))
            v.append((Float(t), store.velocity(id, prop).lanes[0]))
        }
        return (x, normalized(v))
    }

    public static func generateAll() -> [(filename: String, svg: String)] {
        var outputs: [(String, String)] = []

        // 1. Kit tokens + SwiftUI presets
        var tokenPanels: [Panel] = []
        for (name, pair) in MotionTokens.ALL {
            tokenPanels.append(springPanel(name: name, spring: pair.enter, tMax: 1.2))
            tokenPanels.append(springPanel(name: "\(name) exit", spring: pair.exit, tMax: 1.2))
        }
        outputs.append((
            "tokens.svg",
            renderSVG(
                panels: tokenPanels,
                cols: 4,
                pw: 300,
                ph: 170,
                title: "Kit motion tokens: position (blue), velocity (orange), duration (red)"
            )
        ))

        let swiftuiPanels: [Panel] = [
            springPanel(name: ".smooth", spring: .smooth, tMax: 1.5),
            springPanel(name: ".snappy", spring: .snappy, tMax: 1.5),
            springPanel(name: ".bouncy", spring: .bouncy, tMax: 1.5),
            springPanel(name: "overdamped", spring: Spring(duration: 0.5, bounce: -0.5), tMax: 1.5),
            springPanel(name: "interactive", spring: .interactive, tMax: 1.5),
            springPanel(name: "very bouncy", spring: Spring(duration: 0.5, bounce: 0.7), tMax: 1.5),
        ]
        outputs.append(("swiftui.svg", renderSVG(panels: swiftuiPanels, cols: 3, pw: 300, ph: 170, title: "SwiftUI springs")))

        // 2. Other curves
        var otherPanels: [Panel] = [
            curvePanel(name: "CSS ease", curve: .tween(duration: 0.6, easing: .ease), from: 0, to: 1, tMax: 0.8),
            curvePanel(name: "Kit CSS enter 150 ms", curve: MotionTokens.CSS_ENTER, from: 0, to: 1, tMax: 0.3),
            curvePanel(name: "Kit CSS exit 110 ms", curve: MotionTokens.CSS_EXIT, from: 0, to: 1, tMax: 0.3),
            curvePanel(name: "overshoot bezier", curve: .tween(duration: 0.5, easing: .overshoot), from: 0, to: 1, tMax: 0.7),
            curvePanel(name: "steps(4)", curve: .tween(duration: 0.6, easing: .steps(4, .jumpEnd)), from: 0, to: 1, tMax: 0.8),
            curvePanel(
                name: "linear() piecewise",
                curve: .tween(duration: 0.6, easing: .piecewise([Vec2(0, 0), Vec2(0.3, 0.7), Vec2(0.6, 0.9), Vec2(1, 1)])),
                from: 0,
                to: 1,
                tMax: 0.8
            ),
        ]
        // Decay fling
        do {
            let prop = Prop<Float>(id: PropId(64), propClass: .gesture, name: "x")
            let id = NodeId(1)
            var store = AnimationStore()
            store.snap(id, prop, to: 0)
            _ = store.release(id, prop, Release.decay(.IOS_NORMAL), velocity: Velocity(lanes: MotionLanes(2.0)), at: 0)
            var x: [(Float, Float)] = []
            var v: [(Float, Float)] = []
            for i in 0...300 {
                let t = 3.0 * Float(i) / 300.0
                store.sample(at: Double(t))
                x.append((t, store.get(id, prop) ?? 0))
                v.append((t, store.velocity(id, prop).lanes[0]))
            }
            otherPanels.append(
                Panel(
                    title: "decay 0.998/ms (fling v=2)",
                    x: (0, 3.0),
                    y: (-0.1, 1.25),
                    series: [
                        Series(points: x, color: blue, dashed: false, label: "position"),
                        Series(points: normalized(v), color: orange, dashed: true, label: "velocity"),
                    ],
                    marks: [],
                    equalAxes: false
                )
            )
        }
        // Keyframe track
        do {
            let track = KeyframeTrack<Float>(
                duration: 0.75,
                stops: [
                    Keyframe(at: 0.0, value: 0.0, easing: .linear),
                    Keyframe(at: 0.2, value: 0.4, easing: .linear),
                    Keyframe(at: 0.47, value: 1.1, easing: .easeInOut),
                    Keyframe(at: 0.67, value: 0.8, easing: .easeInOut),
                    Keyframe(at: 1.0, value: 1.0, easing: .overshoot),
                ]
            )
            var x: [(Float, Float)] = []
            var v: [(Float, Float)] = []
            let dt: Float = 1.0 / 300.0
            for i in 0...300 {
                let t = Float(i) * dt
                let val = track.sample(elapsed: t)
                let prev = track.sample(elapsed: max(0, t - dt))
                x.append((t, val))
                v.append((t, i == 0 ? 0 : (val - prev) / dt))
            }
            otherPanels.append(
                Panel(
                    title: "keyframes: linear, cubic, cubic, overshoot",
                    x: (0, 1.0),
                    y: (-0.45, 1.25),
                    series: [
                        Series(points: x, color: blue, dashed: false, label: "position"),
                        Series(points: normalized(v), color: orange, dashed: true, label: "velocity"),
                    ],
                    marks: [0.15, 0.35, 0.5],
                    equalAxes: false
                )
            )
        }
        outputs.append(("curves.svg", renderSVG(panels: otherPanels, cols: 4, pw: 300, ph: 170, title: "Tweens, decay and keyframes")))

        // 3. Retargeting mid-flight
        let retargetSpecs: [(String, Curve, Blend)] = [
            ("spring merge (SwiftUI): keeps x and v", .spring(MotionTokens.REFLOW), .merge),
            ("tween additive (Core Animation)", .easeInOut(0.35), .additive),
            ("spring, bounce .3", .spring(Spring(duration: 0.4, bounce: 0.3)), .merge),
        ]
        let retargetPanels = retargetSpecs.map { name, curve, blend in
            let (x, v) = retargetSeries(curve: curve, blend: blend, naive: false)
            let (nx, nv) = retargetSeries(curve: curve, blend: blend, naive: true)
            return Panel(
                title: name,
                x: (0, 1.2),
                y: (-1.1, 1.3),
                series: [
                    Series(points: nx, color: grey, dashed: false, label: "naive restart (v = 0)"),
                    Series(points: nv, color: grey, dashed: true, label: ""),
                    Series(points: x, color: blue, dashed: false, label: "position"),
                    Series(points: v, color: orange, dashed: true, label: "velocity"),
                ],
                marks: [0.15, 0.32, 0.55],
                equalAxes: false
            )
        }
        outputs.append(("retarget.svg", renderSVG(panels: retargetPanels, cols: 3, pw: 380, ph: 220, title: "Retargeting at the red lines: position and velocity stay continuous")))

        // 4. Presence (blurReplace enter/exit/revive/exit) & 5. Screen vs Parent travel
        var scene = Scene()
        let rootId = NodeId(9)
        let cardId = NodeId(1)
        let rootSpec = NodeSpec(id: rootId, rect: MotionRect(left: 0, top: 0, right: 1, bottom: 1))
        let cardSpec = NodeSpec(
            id: cardId,
            rect: MotionRect(left: 0, top: 0, right: 200, bottom: 40),
            transition: Transition.blurReplace()
        )
        scene.commit([rootSpec], at: 0.0, initialCut: true)
        scene.commit([rootSpec, cardSpec], at: 0.0)

        var op: [(Float, Float)] = []
        var bl: [(Float, Float)] = []
        var sc: [(Float, Float)] = []
        for i in 0...480 {
            let t = Double(i) / 240.0
            if i == 168 {
                scene.commit([rootSpec], at: t)
            } else if i == 220 {
                scene.commit([rootSpec, cardSpec], at: t)
            } else if i == 400 {
                scene.commit([rootSpec], at: t)
            }
            let out = scene.frame(at: t)
            if let p = out.byId[cardId] {
                op.append((Float(t), p.opacity))
                bl.append((Float(t), p.blur / 6.0))
                sc.append((Float(t), (p.scale.x - 0.96) / 0.04))
            }
        }
        let presence = Panel(
            title: "blurReplace: enter, exit, revive mid-exit, exit",
            x: (0, 2.0),
            y: (-0.1, 1.15),
            series: [
                Series(points: op, color: blue, dashed: false, label: "opacity"),
                Series(points: bl, color: purple, dashed: false, label: "blur / 6 px"),
                Series(points: sc, color: green, dashed: true, label: "(scale − .96) / .04"),
            ],
            marks: [0.7, 220.0 / 240.0, 400.0 / 240.0],
            equalAxes: false
        )

        func traceChildPath(screen: Bool) -> [(Float, Float)] {
            var s = Scene()
            let (p, c) = (NodeId(10), NodeId(11))
            s.commit([
                NodeSpec(id: p, rect: MotionRect(left: 0, top: 0, right: 400, bottom: 400)),
                NodeSpec(id: c, parent: p, rect: MotionRect(left: 10, top: 10, right: 60, bottom: 60)),
            ], at: 0.0, initialCut: true)
            let la = LayoutAnim(spring: MotionTokens.DRIFT, travel: screen ? .screen : .parent)
            s.commit([
                NodeSpec(id: p, rect: MotionRect(left: 200, top: 100, right: 600, bottom: 500), layoutAnim: LayoutAnim(spring: MotionTokens.GLIDE)),
                NodeSpec(id: c, parent: p, rect: MotionRect(left: 100, top: 200, right: 150, bottom: 250), layoutAnim: la),
            ], at: 0.0)
            var pts: [(Float, Float)] = []
            for i in 0...360 {
                let out = s.frame(at: Double(i) / 120.0)
                if let q = out.byId[c] {
                    pts.append((q.rect.left, q.rect.top))
                }
            }
            return pts
        }

        let paths = Panel(
            title: "child path in root space (parent GLIDE, child DRIFT)",
            x: (0, 320),
            y: (0, 320),
            series: [
                Series(points: traceChildPath(screen: false), color: grey, dashed: false, label: "parent space: dog-leg"),
                Series(points: traceChildPath(screen: true), color: blue, dashed: false, label: "Travel::Screen: straight"),
            ],
            marks: [],
            equalAxes: true
        )
        outputs.append(("presence-and-paths.svg", renderSVG(panels: [presence, paths], cols: 2, pw: 420, ph: 330, title: "Presence and travel")))

        return outputs
    }
}

@main
enum RuneMotionCurvesMain {
    static func main() throws {
        let outDir = CommandLine.arguments.dropFirst().first ?? "demo/motion"
        let fm = FileManager.default
        try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        for item in RuneMotionCurvesGenerator.generateAll() {
            let path = (outDir as NSString).appendingPathComponent(item.filename)
            try item.svg.write(toFile: path, atomically: true, encoding: .utf8)
            print("wrote \(path)")
        }
    }
}
