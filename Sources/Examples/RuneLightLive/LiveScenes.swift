import Foundation
import Rune
import RuneLight
import RuneMotion
import RuneRef

#if canImport(Metal)
import Metal
#endif

let livePtW: Float = 1280.0
let livePtH: Float = 800.0
let liveFollowSpring = Spring(duration: 0.12, bounce: 0.0)
let liveLampSpring = Spring(duration: 0.2, bounce: 0.0)
let liveToggleSpring = Spring(duration: 0.25, bounce: 0.15)
let liveHoverSpring = Spring(duration: 0.2, bounce: 0.0)
let livePressDownSpring = Spring(duration: 0.1, bounce: 0.0)
let livePressUpSpring = Spring(duration: 0.3, bounce: 0.2)
let liveAccentSpring = Spring(duration: 0.3, bounce: 0.0)
let liveVolumeSpring = Spring(duration: 0.25, bounce: 0.0)
let liveRig = SIMD3<Float>(80, 130, 260)
let liveHalfAngle: Float = 0.58
let liveBehindComp = SIMD2<Float>(65, 105.5)

enum LightMode: Equatable {
    case behind
    case overhead
    case backlight

    func next() -> LightMode {
        switch self {
        case .behind: return .overhead
        case .overhead: return .backlight
        case .backlight: return .behind
        }
    }

    var label: String {
        switch self {
        case .behind: return "Light: raking (L)"
        case .overhead: return "Light: overhead (L)"
        case .backlight: return "Light: backlight (L)"
        }
    }

    func torch(at p: SIMD2<Float>, scale s: Float) -> Light {
        switch self {
        case .behind, .overhead:
            let (lp, aim): (SIMD3<Float>, SIMD2<Float>) = if self == .behind {
                (
                    SIMD3<Float>(p.x - liveBehindComp.x + liveRig.x, p.y - liveBehindComp.y + liveRig.y, liveRig.z),
                    SIMD2<Float>(p.x - liveBehindComp.x, p.y - liveBehindComp.y)
                )
            } else {
                (SIMD3<Float>(p.x, p.y, 260), p)
            }
            return Light.point(lp.x * s, lp.y * s, lp.z * s)
                .color(liveLinear(1.0, 0.95, 0.88))
                .intensity(7.0)
                .radius(9 * s)
                .range(1800 * s)
                .spot(axis: SIMD3<Float>(aim.x - lp.x, aim.y - lp.y, -lp.z), halfAngle: liveHalfAngle)
                .specular(1.4)
        case .backlight:
            return Light.point(p.x * s, p.y * s, 4 * s)
                .color(liveLinear(1.0, 0.92, 0.82))
                .intensity(4.0)
                .radius(12 * s)
                .range(3000 * s)
                .shafts(2.5)
                .softness(2.2)
        }
    }
}

enum LiveSceneKind: Equatable {
    case flashlight
    case chat
}

func liveLinear(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> {
    SIMD3<Float>(RefShader.srgbToLinear(r), RefShader.srgbToLinear(g), RefShader.srgbToLinear(b))
}

struct LiveTrack {
    var t0: Double
    var x0: Float
    var v0: Float
    var target: Float
    var spring: Spring

    static func at(_ v: Float) -> LiveTrack {
        LiveTrack(t0: 0, x0: v, v0: 0, target: v, spring: Spring(duration: 0.3, bounce: 0))
    }

    func sample(at t: Double) -> (Float, Float) {
        let res = spring.sample(from: x0, velocity: v0, target: target, at: Float(max(t - t0, 0)))
        return (res.position, res.velocity)
    }

    func value(at t: Double) -> Float {
        sample(at: t).0
    }

    mutating func retarget(at t: Double, target: Float, spring: Spring) {
        let (x, v) = sample(at: t)
        self = LiveTrack(t0: t, x0: x, v0: v, target: target, spring: spring)
    }

    func isBusy(at t: Double, eps: Float) -> Bool {
        let (x, v) = sample(at: t)
        return abs(x - target) > eps || abs(v) > eps * 10
    }
}

struct LiveUIInst {
    var rect: SIMD4<Float>
    var radii: SIMD4<Float>
    var fill: SIMD4<Float>
    var border: SIMD4<Float>
    var params: SIMD4<Float>
    var uv: SIMD4<Float>
    var vp: SIMD4<Float>
}

private func premul(_ c: Color) -> SIMD4<Float> {
    SIMD4<Float>(c.r * c.a, c.g * c.a, c.b * c.a, c.a)
}

private func makeInst(rect: SIMD4<Float>, radii: Float, fill: Color, border: (Color, Float)? = nil, vp: SIMD2<Float>) -> LiveUIInst {
    let (bc, bw) = border ?? (.transparent, 0)
    return LiveUIInst(
        rect: rect,
        radii: SIMD4<Float>(repeating: radii),
        fill: premul(fill),
        border: bw > 0 ? premul(bc) : .zero,
        params: SIMD4<Float>(bw, 0, 0, 1),
        uv: .zero,
        vp: SIMD4<Float>(vp.x, vp.y, 0, 0)
    )
}

struct LiveHit {
    var id: Int
    var rect: SIMD4<Float>
}

let liveToggle0 = 0
let liveDot0 = 5
let liveSlider = 10
let liveButton0 = 11
let liveCtlCount = 18
let liveDotHues: [Float] = [255, 300, 350, 40, 150]

func liveAccentFor(_ hue: Float) -> Color {
    oklch(0.7, 0.15, hue)
}

struct LivePanel {
    var toggles: [Float] = [1, 0, 1, 0, 1]
    var accent: Color = liveAccentFor(255)
    var selected: Int = 0
    var ring: Float = 0
    var volume: Float = 82.0 / 130.0
    var hover: [Float] = [Float](repeating: 0, count: liveCtlCount)
    var press: [Float] = [Float](repeating: 0, count: liveCtlCount)

    func lift(_ id: Int) -> Float {
        (1.0 + 0.45 * hover[id]) * (1.0 - 0.92 * min(max(press[id], 0), 1.2))
    }
}

struct LiveFrame {
    var prims: [Prim]
    var base: [LiveUIInst]
    var text: [LiveUIInst]
    var clear: Color
    var lights: [Light]
    var settings: LightSettings
}

final class LiveUI {
    let ts: TextSystem
    let scale: Float
    let vp: SIMD2<Float>
    var base: [LiveUIInst] = []
    var text: [LiveUIInst] = []
    var prims: [Prim] = []
    let clear: Color

    init(ts: TextSystem, clear: Color, scale: Float, viewportPx: SIMD2<Float>) {
        self.ts = ts
        self.clear = clear
        self.scale = scale
        self.vp = viewportPx
    }

    func rect(
        _ x: Float, _ y: Float, _ w: Float, _ h: Float,
        radius r: Float,
        fill: Color,
        border: (Color, Float)? = nil,
        _ build: (Prim) -> Prim = { $0 }
    ) {
        let pxRect = SIMD4<Float>(x * scale, y * scale, w * scale, h * scale)
        base.append(makeInst(rect: pxRect, radii: r * scale, fill: fill, border: border.map { ($0.0, $0.1 * scale) }, vp: vp))
        prims.append(build(Prim.fromRune(rect: pxRect, radii: SIMD4<Float>(repeating: r * scale)).albedo(SIMD3<Float>(fill.r, fill.g, fill.b))))
    }

    func paint(_ x: Float, _ y: Float, _ w: Float, _ h: Float, radius r: Float, fill: Color) {
        let pxRect = SIMD4<Float>(x * scale, y * scale, w * scale, h * scale)
        base.append(makeInst(rect: pxRect, radii: r * scale, fill: fill, border: nil, vp: vp))
    }

    @discardableResult
    func text(_ x: Float, _ y: Float, _ str: String, size: Float, weight: Float, color: Color) -> Float {
        let shaped = ts.shape(text: str, style: TextStyle(size: size, weight: weight, family: .systemUI, wrap: .noWrap), maxWidth: nil, pixelScale: scale, emitGlyphs: true)
        let ox = (x * scale).rounded()
        let oy = (y * scale).rounded()
        let fill = premul(color)
        for g in shaped.glyphs {
            text.append(LiveUIInst(
                rect: SIMD4<Float>(ox + g.rect.x * scale, oy + g.rect.y * scale, g.rect.z * scale, g.rect.w * scale),
                radii: .zero,
                fill: fill,
                border: .zero,
                params: SIMD4<Float>(0, 1, 0, 1),
                uv: g.uv,
                vp: SIMD4<Float>(vp.x, vp.y, 0, 0)
            ))
        }
        return shaped.size.x
    }

    func lines(_ x: Float, _ y: Float, lh: Float, _ items: [String], size: Float, weight: Float, color: Color) {
        for (i, line) in items.enumerated() where !line.isEmpty {
            text(x, y + Float(i) * lh, line, size: size, weight: weight, color: color)
        }
    }

    func measure(_ str: String, size: Float, weight: Float) -> Float {
        ts.measure(str, style: TextStyle(size: size, weight: weight, family: .systemUI, wrap: .noWrap), maxWidth: nil, pixelScale: scale).x
    }
}

private func mixColor(_ a: Color, _ b: Color, _ k0: Float) -> Color {
    let k = min(max(k0, 0), 1)
    return Color(r: a.r + (b.r - a.r) * k, g: a.g + (b.g - a.g) * k, b: a.b + (b.b - a.b) * k, a: a.a + (b.a - a.a) * k)
}

func liveChatScene(ts: TextSystem, t: Float, p: SIMD2<Float>, scale: Float, vp: SIMD2<Float>) -> LiveFrame {
    let bg = oklch(0.17, 0.006, 265)
    let ui = LiveUI(ts: ts, clear: bg, scale: scale, viewportPx: vp)
    let side = oklch(0.195, 0.006, 265)
    let txt = oklch(0.93, 0.004, 265)
    let txt2 = oklch(0.66, 0.01, 265)
    let txt3 = oklch(0.52, 0.01, 265)
    let hair = oklcha(1, 0, 0, 0.06)
    let card = oklch(0.235, 0.007, 265)
    let user = oklch(0.3, 0.045, 258)
    let code = oklch(0.195, 0.008, 265)
    let accent = oklch(0.72, 0.15, 255)

    ui.rect(0, 0, 268, 800, radius: 0, fill: side)
    ui.paint(268, 0, 1, 800, radius: 0, fill: hair)
    ui.text(24, 22, "OpenCode", size: 15, weight: 600, color: txt)
    ui.rect(20, 58, 228, 34, radius: 9, fill: card, border: (hair, 1)) {
        $0.raised(3 * scale).bevel(width: 3 * scale, height: 1.2 * scale).gloss(0.5, roughness: 0.45)
    }
    ui.text(36, 66, "+  New session", size: 13, weight: 500, color: txt)
    ui.text(24, 116, "TODAY", size: 11, weight: 600, color: txt3)
    let sessions = [
        "rune-light: lighting for UIs", "Scroll momentum on iOS", "Theme tokens codegen",
        "Hex settings screen", "Slug text spike", "Radiance cascades notes", "Motion blur from tracks",
    ]
    for (i, s) in sessions.enumerated() {
        let y = 138 + Float(i) * 36
        if i == 0 { ui.rect(14, y - 7, 240, 32, radius: 8, fill: oklcha(1, 0, 0, 0.06)) }
        ui.text(26, y, s, size: 13, weight: i == 0 ? 500 : 400, color: i == 0 ? txt : txt2)
    }
    ui.text(300, 22, "rune-light: lighting for UIs", size: 14, weight: 600, color: txt)
    let chip = "claude-opus-5.5"
    let cw = ui.measure(chip, size: 12, weight: 500)
    ui.rect(1240 - cw - 24, 16, cw + 24, 28, radius: 14, fill: card, border: (hair, 1)) {
        $0.raised(2 * scale).bevel(width: 4 * scale, height: 1 * scale).gloss(0.5, roughness: 0.4)
    }
    ui.text(1240 - cw - 12, 22, chip, size: 12, weight: 500, color: txt2)
    ui.paint(269, 60, 1011, 1, radius: 0, fill: hair)

    let raise: (Prim) -> Prim = { $0.raised(7 * scale).bevel(width: 6 * scale, height: 2 * scale).gloss(0.55, roughness: 0.42) }
    ui.rect(800, 88, 440, 68, radius: 16, fill: user, border: (oklcha(1, 0, 0, 0.08), 1), raise)
    ui.lines(818, 101, lh: 21, ["what if lighting effects. like you could put a light and", "it would raytrace around the ui elements…"], size: 14, weight: 400, color: txt)

    ui.rect(300, 182, 600, 152, radius: 16, fill: card, border: (hair, 1), raise)
    ui.lines(322, 198, lh: 21, [
        "Every Rune element is an analytic rounded rect, so the frame is",
        "already an exact distance field. A light can sphere-trace soft",
        "shadows straight through it: contact-hard near each bubble,",
        "wide and soft where the light is far.",
    ], size: 14, weight: 400, color: txt)
    let chipXs: [Float] = [0, 140, 330]
    for (i, ct) in ["Read shader.wgsl", "Edit rune-light/src/lib.rs", "Run bench"].enumerated() {
        let x = 322 + chipXs[i]
        let w = ui.measure(ct, size: 12, weight: 500) + 22
        ui.rect(x, 292, w, 26, radius: 13, fill: oklch(0.27, 0.008, 265), border: (hair, 1)) {
            $0.on(7 * scale).raised(2.5 * scale).bevel(width: 4 * scale, height: 1 * scale).gloss(0.4, roughness: 0.4)
        }
        ui.text(x + 11, 297, ct, size: 12, weight: 500, color: txt2)
    }

    ui.rect(960, 360, 280, 44, radius: 16, fill: user, border: (oklcha(1, 0, 0, 0.08), 1), raise)
    ui.lines(980, 372, lh: 21, ["MAKE THIS SOOO GOOOD"], size: 14, weight: 400, color: txt)

    ui.rect(300, 430, 640, 196, radius: 16, fill: card, border: (hair, 1), raise)
    ui.lines(322, 446, lh: 21, ["Here's the API: lights are springs like everything else."], size: 14, weight: 400, color: txt)
    ui.rect(318, 480, 604, 126, radius: 10, fill: code, border: (hair, 1)) { $0.on(7 * scale).gloss(0.2, roughness: 0.5) }
    ui.lines(336, 494, lh: 20, [
        "let lamp = Light::point(x, y, 60.0)",
        "    .color(WARM).intensity(1.6).radius(10.0);",
        "",
        "lights.render(&scene, &[lamp], target);",
        "",
    ], size: 13, weight: 400, color: oklch(0.8, 0.06, 200))

    ui.rect(300, 690, 940, 78, radius: 18, fill: card, border: (oklcha(1, 0, 0, 0.09), 1)) {
        $0.raised(10 * scale).bevel(width: 7 * scale, height: 2.5 * scale).gloss(0.6, roughness: 0.38)
    }
    ui.text(322, 708, "Ask anything…", size: 14, weight: 400, color: txt3)
    ui.rect(1192, 724, 32, 32, radius: 16, fill: accent) {
        $0.on(10 * scale).raised(4 * scale).bevel(width: 10 * scale, height: 3 * scale).gloss(0.8, roughness: 0.3)
    }
    ui.paint(1203, 739, 10, 2, radius: 1, fill: oklch(0.2, 0.02, 255))

    let lamp = Light.point(p.x * scale, p.y * scale, 40 * scale)
        .color(liveLinear(1.0, 0.78, 0.55)).intensity(2.6).radius(11 * scale).range(1100 * scale).bulb(0.75).specular(1.2)
    let fill = Light.point(-300 * scale, -200 * scale, 900 * scale)
        .color(liveLinear(0.55, 0.65, 1.0)).intensity(0.35).radius(220 * scale).range(6000 * scale).specular(0.4)
    let s = LightSettings(ambient: SIMD3<Float>(0.62, 0.63, 0.7), contactAO: 0.45, rim: 0.9, albedoFloor: 0.07, time: t)
    return LiveFrame(prims: ui.prims, base: ui.base, text: ui.text, clear: ui.clear, lights: [lamp, fill], settings: s)
}

func liveFlashlightScene(ts: TextSystem, t: Float, p: SIMD2<Float>, panel: LivePanel, scale: Float, vp: SIMD2<Float>) -> (LiveFrame, [LiveHit]) {
    let bg = oklch(0.16, 0.005, 265)
    let ui = LiveUI(ts: ts, clear: bg, scale: scale, viewportPx: vp)
    let card = oklch(0.225, 0.006, 265)
    let txt = oklch(0.94, 0.003, 265)
    let txt2 = oklch(0.66, 0.01, 265)
    let hair = oklcha(1, 0, 0, 0.06)
    let accent = panel.accent
    var hits: [LiveHit] = []
    let raiseCard: (Prim) -> Prim = { $0.raised(4 * scale).bevel(width: 5 * scale, height: 1.5 * scale).gloss(0.45, roughness: 0.45) }
    let top = 4 * scale

    ui.text(160, 70, "Settings", size: 24, weight: 600, color: txt)
    ui.text(160, 106, "Appearance, sound and shortcuts", size: 13, weight: 400, color: txt2)
    let rows: [(String, String, Int)] = [
        ("Appearance", "Dark", 2), ("Accent colour", "", 3), ("Reduce motion", "", 1),
        ("Sound effects", "", 0), ("Notification volume", "", 4), ("Push to talk", "⌥ Space", 2),
        ("Auto-update", "", 1), ("Send crash reports", "", 0), ("Launch at login", "", 1),
    ]
    var toggle = 0
    var button = 0
    let y: Float = 150
    for gi in 0..<3 {
        let group = Array(rows[(gi * 3)..<(gi * 3 + 3)])
        let x = 160 + Float(gi) * 330
        let h = Float(group.count) * 56
        ui.rect(x, y, 310, h, radius: 14, fill: card, border: (hair, 1), raiseCard)
        for (ri, (label, value, kind)) in group.enumerated() {
            let ry = y + Float(ri) * 56
            if ri > 0 { ui.paint(x + 16, ry, 278, 1, radius: 0, fill: hair) }
            ui.text(x + 18, ry + 19, label, size: 13, weight: 500, color: txt)
            let rx = x + 310 - 18
            switch kind {
            case 0, 1:
                let id = liveToggle0 + toggle
                toggle += 1
                let k = panel.toggles[id - liveToggle0]
                let m = panel.lift(id)
                ui.rect(rx - 42, ry + 16, 42, 24, radius: 12, fill: mixColor(oklch(0.33, 0.006, 265), accent, k)) { $0.on(top).gloss(0.4, roughness: 0.4) }
                ui.rect(rx - 40 + 18 * k, ry + 18, 20, 20, radius: 10, fill: oklch(0.96, 0, 0)) {
                    $0.on(top).raised(5 * scale * m).bevel(width: 10 * scale, height: 4 * scale * m).gloss(0.7, roughness: 0.3)
                }
                hits.append(LiveHit(id: id, rect: SIMD4<Float>(rx - 42, ry + 16, 42, 24)))
            case 2:
                let id = liveButton0 + button
                button += 1
                let m = panel.lift(id)
                let w = ui.measure(value, size: 12, weight: 500) + 20
                ui.rect(rx - w, ry + 14, w, 28, radius: 8, fill: oklch(0.3, 0.006, 265), border: (hair, 1)) {
                    $0.on(top).raised(3 * scale * m).bevel(width: 4 * scale, height: 1.2 * scale * m).gloss(0.5, roughness: 0.4)
                }
                ui.text(rx - w + 10, ry + 20, value, size: 12, weight: 500, color: txt)
                hits.append(LiveHit(id: id, rect: SIMD4<Float>(rx - w, ry + 14, w, 28)))
            case 3:
                for (k, hVal) in liveDotHues.enumerated() {
                    let id = liveDot0 + k
                    let m = panel.lift(id)
                    let c = oklch(0.68, 0.15, hVal)
                    let cx = rx - 18 - Float(k) * 26
                    if k == panel.selected && panel.ring > 0 {
                        let o: Float = 3
                        let ring = oklcha(0.95, 0, 0, 0.8 * panel.ring)
                        ui.base.append(makeInst(
                            rect: SIMD4<Float>((cx - o) * scale, (ry + 19 - o) * scale, (18 + 2 * o) * scale, (18 + 2 * o) * scale),
                            radii: (9 + o) * scale, fill: .transparent, border: (ring, 1.5 * scale), vp: vp
                        ))
                    }
                    ui.rect(cx, ry + 19, 18, 18, radius: 9, fill: c) {
                        $0.on(top).raised(3.5 * scale * m).bevel(width: 9 * scale, height: 3 * scale * m).gloss(0.7, roughness: 0.3)
                    }
                    hits.append(LiveHit(id: id, rect: SIMD4<Float>(cx - 4, ry + 15, 26, 26)))
                }
            default:
                let m = panel.lift(liveSlider)
                let v = min(max(panel.volume, 0), 1)
                ui.rect(rx - 130, ry + 26, 130, 4, radius: 2, fill: oklch(0.33, 0.006, 265)) { $0.on(top) }
                if v > 0 { ui.rect(rx - 130, ry + 26, 130 * v, 4, radius: 2, fill: accent) { $0.on(top) } }
                ui.rect(rx - 140 + 130 * v, ry + 18, 20, 20, radius: 10, fill: oklch(0.96, 0, 0)) {
                    $0.on(top).raised(6 * scale * m).bevel(width: 10 * scale, height: 4 * scale * m).gloss(0.7, roughness: 0.3)
                }
                hits.append(LiveHit(id: liveSlider, rect: SIMD4<Float>(rx - 130, ry + 12, 130, 32)))
            }
        }
    }

    let by: Float = 340
    ui.rect(160, by, 970, 150, radius: 14, fill: card, border: (hair, 1), raiseCard)
    ui.text(180, by + 20, "Keyboard shortcuts", size: 15, weight: 600, color: txt)
    ui.text(180, by + 46, "Press a key combination to record a new shortcut.", size: 13, weight: 400, color: txt2)
    for (i, k) in ["⌘", "⇧", "K"].enumerated() {
        let id = liveButton0 + 2 + i
        let m = panel.lift(id)
        ui.rect(180 + Float(i) * 52, by + 82, 44, 44, radius: 10, fill: oklch(0.3, 0.006, 265), border: (hair, 1)) {
            $0.on(top).raised(6 * scale * m).bevel(width: 7 * scale, height: 2.5 * scale * m).gloss(0.6, roughness: 0.35)
        }
        ui.text(195 + Float(i) * 52, by + 94, k, size: 15, weight: 600, color: txt)
        hits.append(LiveHit(id: id, rect: SIMD4<Float>(180 + Float(i) * 52, by + 82, 44, 44)))
    }
    let m6 = panel.lift(liveButton0 + 6)
    ui.rect(940, by + 90, 170, 36, radius: 10, fill: accent) {
        $0.on(top).raised(5 * scale * m6).bevel(width: 6 * scale, height: 2 * scale * m6).gloss(0.7, roughness: 0.3)
    }
    ui.text(975, by + 99, "Record shortcut", size: 13, weight: 600, color: oklch(0.18, 0.03, 255))
    hits.append(LiveHit(id: liveButton0 + 6, rect: SIMD4<Float>(940, by + 90, 170, 36)))

    let m5 = panel.lift(liveButton0 + 5)
    ui.rect(780, by + 90, 140, 36, radius: 10, fill: oklch(0.3, 0.006, 265), border: (hair, 1)) {
        $0.on(top).raised(5 * scale * m5).bevel(width: 6 * scale, height: 2 * scale * m5).gloss(0.6, roughness: 0.35)
    }
    ui.text(828, by + 99, "Reset", size: 13, weight: 600, color: txt)
    hits.append(LiveHit(id: liveButton0 + 5, rect: SIMD4<Float>(780, by + 90, 140, 36)))

    let tileNames = ["Microphone", "Speakers", "Camera", "Display", "Battery"]
    let tileSubs = ["MacBook Pro", "Studio Display", "FaceTime HD", "Built-in", "92 %"]
    let tileFills: [Float] = [0.7, 0.45, 0, 0.85, 0.92]
    for i in 0..<5 {
        let x = 160 + Float(i) * 198
        ui.rect(x, 520, 180, 120, radius: 14, fill: card, border: (hair, 1), raiseCard)
        ui.text(x + 18, 538, tileNames[i], size: 13, weight: 600, color: txt)
        ui.text(x + 18, 560, tileSubs[i], size: 12, weight: 400, color: txt2)
        ui.rect(x + 18, 600, 144, 18, radius: 9, fill: oklch(0.27, 0.006, 265)) { $0.on(top) }
        if tileFills[i] > 0 {
            ui.rect(x + 18, 600, 144 * tileFills[i], 18, radius: 9, fill: accent) {
                $0.on(top).raised(2 * scale).bevel(width: 9 * scale, height: 2 * scale).gloss(0.6, roughness: 0.3)
            }
        }
    }

    let s = LightSettings(
        ambient: SIMD3<Float>(0.07, 0.075, 0.09),
        text: TextPolicy(floor: 0.32, ceiling: 1.3, lit: 1.0, specular: 0.1),
        gi: nil,
        backgroundGloss: 0.5,
        contactAO: 0.3,
        rim: 1.0,
        albedoFloor: 0.04,
        time: t
    )
    return (LiveFrame(prims: ui.prims, base: ui.base, text: ui.text, clear: ui.clear, lights: [], settings: s), hits)
}

private func applyMachined(_ f: inout LiveFrame) {
    for i in f.prims.indices {
        if f.prims[i].z.z > 0 {
            f.prims[i].z.z *= 0.45
            f.prims[i].mat.x = min(f.prims[i].mat.x * 1.3, 1.0)
            f.prims[i].mat.y *= 0.6
        }
        f.prims[i].z.x *= 1.5
        f.prims[i].z.y *= 1.5
    }
    f.settings.ambient = SIMD3<Float>(0.035, 0.037, 0.045)
    f.settings.albedoFloor = 0.045
    f.settings.contactAO = 0.6
    f.settings.rim = 1.8
    f.settings.backgroundGloss = 0.12
    f.settings.backgroundRoughness = 0.25
}

func translateLiveFrame(_ f: inout LiveFrame, offset o: SIMD2<Float>) {
    if o == .zero { return }
    for i in f.base.indices {
        f.base[i].rect.x += o.x
        f.base[i].rect.y += o.y
    }
    for i in f.text.indices {
        f.text[i].rect.x += o.x
        f.text[i].rect.y += o.y
    }
    for i in f.prims.indices {
        f.prims[i].rect.x += o.x
        f.prims[i].rect.y += o.y
    }
    for i in f.lights.indices {
        f.lights[i].pos.x += o.x
        f.lights[i].pos.y += o.y
    }
}

final class LiveState {
    var which: LiveSceneKind
    let start = ContinuousClock().now
    var fake: Double?
    var cursor = SIMD2<Float>(640, 400)
    var x = LiveTrack.at(640)
    var y = LiveTrack.at(400)
    var lamp = SIMD2<Float>(1085, 250)
    var direct: Bool = true
    var radius: Float = 1.0
    var rays: Bool = false
    var mode: LightMode = .behind
    var modeAt: Double = -.infinity
    var machined: Bool = true
    var bare: Bool = false
    var press: SIMD2<Float>?
    var dragging: Bool = false

    var on: [Bool]
    var toggles: [LiveTrack]
    var selected: Int
    var accent: [LiveTrack]
    var volume: LiveTrack
    var hover: [LiveTrack]
    var pressed: [LiveTrack]
    var hits: [LiveHit] = []
    var hovered: Int?
    var active: Int?

    init(which: LiveSceneKind) {
        let d = LivePanel()
        self.which = which
        self.on = d.toggles.map { $0 > 0.5 }
        self.toggles = d.toggles.map { LiveTrack.at($0) }
        self.selected = d.selected
        self.accent = [d.accent.r, d.accent.g, d.accent.b].map { LiveTrack.at($0) }
        self.volume = LiveTrack.at(d.volume)
        self.hover = (0..<liveCtlCount).map { _ in LiveTrack.at(0) }
        self.pressed = (0..<liveCtlCount).map { _ in LiveTrack.at(0) }
        switchScene(which)
    }

    func now() -> Double {
        if let fake { return fake }
        let d = ContinuousClock().now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }

    func jump(_ p: SIMD2<Float>) {
        x = LiveTrack.at(p.x)
        y = LiveTrack.at(p.y)
    }

    func switchScene(_ w: LiveSceneKind) {
        if which == .chat {
            lamp = SIMD2<Float>(x.target, y.target)
        }
        which = w
        dragging = false
        active = nil
        setHover(nil)
        switch w {
        case .flashlight: jump(cursor)
        case .chat: jump(lamp)
        }
    }

    private func follow(_ p: SIMD2<Float>, spring: Spring) {
        if direct {
            jump(p)
        } else {
            let t = now()
            x.retarget(at: t, target: p.x, spring: spring)
            y.retarget(at: t, target: p.y, spring: spring)
        }
    }

    private func hit(_ p: SIMD2<Float>) -> LiveHit? {
        guard which == .flashlight else { return nil }
        let pad: Float = 4
        return hits.reversed().first { h in
            p.x >= h.rect.x - pad && p.x <= h.rect.x + h.rect.z + pad && p.y >= h.rect.y - pad && p.y <= h.rect.y + h.rect.w + pad
        }
    }

    private func sliderValue(_ p: SIMD2<Float>) -> Float? {
        guard let h = hits.first(where: { $0.id == liveSlider }) else { return nil }
        return min(max((p.x - h.rect.x) / h.rect.z, 0), 1)
    }

    private func setHover(_ id: Int?) {
        guard id != hovered else { return }
        let t = now()
        if let old = hovered { hover[old].retarget(at: t, target: 0, spring: liveHoverSpring) }
        if let new = id { hover[new].retarget(at: t, target: 1, spring: liveHoverSpring) }
        hovered = id
    }

    func pointerMove(_ p: SIMD2<Float>) {
        cursor = p
        if let down = press {
            let dx = p.x - down.x
            let dy = p.y - down.y
            if sqrtf(dx * dx + dy * dy) > 4 { dragging = true }
        }
        if active == liveSlider && dragging, let v = sliderValue(p) {
            volume = LiveTrack.at(v)
        }
        setHover(active ?? hit(p)?.id)
        switch which {
        case .flashlight: follow(p, spring: liveFollowSpring)
        case .chat where dragging: follow(p, spring: liveLampSpring)
        case .chat: break
        }
    }

    func button(down: Bool) {
        let t = now()
        if down {
            press = cursor
            dragging = false
            active = hit(cursor)?.id
            if let id = active {
                pressed[id].retarget(at: t, target: 1, spring: livePressDownSpring)
                if id == liveSlider, let v = sliderValue(cursor) {
                    volume.retarget(at: t, target: v, spring: liveVolumeSpring)
                }
            }
            return
        }
        if let id = active {
            active = nil
            pressed[id].retarget(at: t, target: 0, spring: livePressUpSpring)
            if hit(cursor)?.id == id {
                if (liveToggle0..<(liveToggle0 + 5)).contains(id) {
                    let i = id - liveToggle0
                    on[i].toggle()
                    toggles[i].retarget(at: t, target: on[i] ? 1 : 0, spring: liveToggleSpring)
                } else if (liveDot0..<(liveDot0 + 5)).contains(id) {
                    selected = id - liveDot0
                    let a = liveAccentFor(liveDotHues[selected])
                    let targets = [a.r, a.g, a.b]
                    for i in 0..<3 {
                        accent[i].retarget(at: t, target: targets[i], spring: liveAccentSpring)
                    }
                }
            }
            setHover(hit(cursor)?.id)
        }
        press = nil
        dragging = false
    }

    func isAnimating(at t: Double) -> Bool {
        if x.isBusy(at: t, eps: 0.05) || y.isBusy(at: t, eps: 0.05) || volume.isBusy(at: t, eps: 1e-3) {
            return true
        }
        return (toggles + accent + hover + pressed).contains { $0.isBusy(at: t, eps: 1e-3) }
    }

    func panel(at t: Double) -> LivePanel {
        LivePanel(
            toggles: toggles.map { $0.value(at: t) },
            accent: Color(r: accent[0].value(at: t), g: accent[1].value(at: t), b: accent[2].value(at: t), a: 1),
            selected: selected,
            ring: 1.0,
            volume: volume.value(at: t),
            hover: hover.map { $0.value(at: t) },
            press: pressed.map { $0.value(at: t) }
        )
    }

    func buildFrame(ts: TextSystem, scale: Float, viewportPx: SIMD2<Float>) -> (LiveFrame, Bool) {
        let t = now()
        let p = SIMD2<Float>(x.value(at: t), y.value(at: t))
        var frame: LiveFrame
        switch which {
        case .flashlight:
            let (fr, newHits) = liveFlashlightScene(ts: ts, t: Float(t), p: p, panel: panel(at: t), scale: scale, vp: viewportPx)
            hits = newHits
            frame = fr
            frame.lights = [mode.torch(at: p, scale: scale)]
            if machined { applyMachined(&frame) }
            if mode == .backlight {
                frame.settings.shaftsOver = 0.1
                frame.settings.ambient = SIMD3<Float>(
                    max(frame.settings.ambient.x, 0.06),
                    max(frame.settings.ambient.y, 0.06),
                    max(frame.settings.ambient.z, 0.06)
                )
            }
            if bare {
                frame.prims.removeAll()
                frame.base.removeAll()
                frame.text.removeAll()
            }
        case .chat:
            frame = liveChatScene(ts: ts, t: Float(t), p: p, scale: scale, vp: viewportPx)
        }

        if !frame.lights.isEmpty {
            frame.lights[0].pos.w *= radius
            frame.lights[0].extra.w *= sqrtf(radius)
            if rays { frame.lights[0].extra.x = 1.5 }
        }
        if rays && mode != .backlight {
            frame.settings.shaftsOver = max(frame.settings.shaftsOver, 0.12)
        }

        let since = t - modeAt
        let alpha = Float(1.0 - min(max((since - 1.2) / 0.4, 0.0), 1.0))
        if which == .flashlight && alpha > 0 {
            let capUI = LiveUI(ts: ts, clear: frame.clear, scale: scale, viewportPx: viewportPx)
            capUI.text(24, 772, mode.label, size: 12, weight: 500, color: oklcha(1, 0, 0, alpha))
            frame.text.append(contentsOf: capUI.text)
        }
        return (frame, isAnimating(at: t) || since < 1.7)
    }
}

#if canImport(Metal)
private let liveUIMetalSource = """
#include <metal_stdlib>
using namespace metal;

struct Inst {
    float4 rect;
    float4 radii;
    float4 fill;
    float4 border;
    float4 params;
    float4 uv;
    float4 vp;
};

struct VOut {
    float4 pos [[position]];
    uint id [[flat]];
    float2 px;
};

vertex VOut live_ui_vs(
    uint vi [[vertex_id]],
    uint ii [[instance_id]],
    constant Inst* insts [[buffer(0)]]
) {
    Inst u = insts[ii];
    float2 corner = float2(float(vi & 1u), float((vi >> 1u) & 1u));
    float2 px = u.rect.xy - 1.0 + (u.rect.zw + 2.0) * corner;
    VOut o;
    o.pos = float4(px.x / u.vp.x * 2.0 - 1.0, 1.0 - px.y / u.vp.y * 2.0, 0.0, 1.0);
    o.id = ii;
    o.px = px;
    return o;
}

static inline float sd_rrect(float2 q, float2 halfSz, float4 radii) {
    float r = (q.x >= 0.0) ? ((q.y >= 0.0) ? radii.z : radii.y) : ((q.y >= 0.0) ? radii.w : radii.x);
    float rr = clamp(r, 0.0, min(halfSz.x, halfSz.y));
    float2 k = abs(q) - halfSz + rr;
    return length(max(k, float2(0.0))) + min(max(k.x, k.y), 0.0) - rr;
}

fragment float4 live_ui_fs(
    VOut in [[stage_in]],
    constant Inst* insts [[buffer(0)]],
    texture2d<float> atlas [[texture(0)]],
    sampler smp [[sampler(0)]]
) {
    Inst u = insts[in.id];
    int kind = int(u.params.y + 0.5);
    if (kind == 1) {
        float2 t = (in.px - u.rect.xy) / max(u.rect.zw, float2(1e-4));
        if (any(t < 0.0) || any(t > 1.0)) { return float4(0.0); }
        float2 uv = mix(u.uv.xy, u.uv.zw, t);
        float a = atlas.sample(smp, uv, level(0.0)).r;
        return u.fill * a;
    }
    float2 halfSz = u.rect.zw * 0.5;
    float2 q = in.px - u.rect.xy - halfSz;
    float d = sd_rrect(q, halfSz, u.radii);
    float cov = clamp(0.5 - d, 0.0, 1.0);
    float4 o = u.fill * cov;
    float bw = u.params.x;
    if (bw > 0.0) {
        float inner = clamp(0.5 - (d + bw), 0.0, 1.0);
        float band = cov - inner;
        o = o * (1.0 - u.border.a * band) + u.border * band;
    }
    return o;
}
"""

final class LiveGfx {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let uiPipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    let ts = TextSystem()
    var light: LightRenderer
    var baseTex: MTLTexture
    var textTex: MTLTexture
    var atlasTex: MTLTexture
    var atlasGen: UInt64 = 0
    var instBuf: MTLBuffer
    var instCap: Int = 1024
    var size: (Int, Int)
    let outputFormat: MTLPixelFormat

    init(device: MTLDevice, width: Int, height: Int, outputFormat: MTLPixelFormat) throws {
        precondition(MemoryLayout<LiveUIInst>.stride == 112)
        self.device = device
        self.queue = device.makeCommandQueue()!
        self.outputFormat = outputFormat
        self.size = (max(width, 1), max(height, 1))

        let lib = try device.makeLibrary(source: liveUIMetalSource, options: nil)
        let pd = MTLRenderPipelineDescriptor()
        pd.label = "live ui"
        pd.vertexFunction = lib.makeFunction(name: "live_ui_vs")
        pd.fragmentFunction = lib.makeFunction(name: "live_ui_fs")
        pd.colorAttachments[0].pixelFormat = .rgba16Float
        pd.colorAttachments[0].isBlendingEnabled = true
        pd.colorAttachments[0].rgbBlendOperation = .add
        pd.colorAttachments[0].alphaBlendOperation = .add
        pd.colorAttachments[0].sourceRGBBlendFactor = .one
        pd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pd.colorAttachments[0].sourceAlphaBlendFactor = .one
        pd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.uiPipeline = try device.makeRenderPipelineState(descriptor: pd)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        self.sampler = device.makeSamplerState(descriptor: sd)!

        let ad = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1024, height: 1024, mipmapped: false)
        ad.usage = [.shaderRead]
        ad.storageMode = .shared
        self.atlasTex = device.makeTexture(descriptor: ad)!

        self.instBuf = device.makeBuffer(length: self.instCap * MemoryLayout<LiveUIInst>.stride, options: .storageModeShared)!
        self.light = try LightRenderer(device: device, width: UInt32(self.size.0), height: UInt32(self.size.1), outputFormat: outputFormat)
        (self.baseTex, self.textTex) = Self.makeLayerTextures(device: device, width: self.size.0, height: self.size.1)
    }

    private static func makeLayerTextures(device: MTLDevice, width: Int, height: Int) -> (MTLTexture, MTLTexture) {
        func mk(_ label: String) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            let t = device.makeTexture(descriptor: d)!
            t.label = label
            return t
        }
        return (mk("ui base"), mk("ui text"))
    }

    func resize(width: Int, height: Int) throws {
        let w = max(width, 1), h = max(height, 1)
        guard w != size.0 || h != size.1 else { return }
        size = (w, h)
        light = try LightRenderer(device: device, width: UInt32(w), height: UInt32(h), outputFormat: outputFormat)
        (baseTex, textTex) = Self.makeLayerTextures(device: device, width: w, height: h)
    }

    private func drawUI(cmd: MTLCommandBuffer, target: MTLTexture, clear: MTLClearColor, insts: [LiveUIInst]) {
        let r8 = ts.glyphAtlas.atlas
        if atlasTex.width != r8.width || atlasTex.height != r8.height {
            let ad = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: r8.width, height: r8.height, mipmapped: false)
            ad.usage = [.shaderRead]
            ad.storageMode = .shared
            atlasTex = device.makeTexture(descriptor: ad)!
            atlasGen = 0
        }
        if atlasGen != ts.glyphAtlas.generation {
            r8.texels.withUnsafeBytes { raw in
                if let ptr = raw.baseAddress {
                    atlasTex.replace(region: MTLRegionMake2D(0, 0, r8.width, r8.height), mipmapLevel: 0, withBytes: ptr, bytesPerRow: r8.width)
                }
            }
            atlasGen = ts.glyphAtlas.generation
        }

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = clear
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rp) else { return }
        if !insts.isEmpty {
            if insts.count > instCap {
                while instCap < insts.count { instCap *= 2 }
                instBuf = device.makeBuffer(length: instCap * MemoryLayout<LiveUIInst>.stride, options: .storageModeShared)!
            }
            _ = insts.withUnsafeBytes { raw in memcpy(instBuf.contents(), raw.baseAddress!, raw.count) }
            enc.setRenderPipelineState(uiPipeline)
            enc.setVertexBuffer(instBuf, offset: 0, index: 0)
            enc.setFragmentBuffer(instBuf, offset: 0, index: 0)
            enc.setFragmentTexture(atlasTex, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: insts.count)
        }
        enc.endEncoding()
    }

    func render(_ frame: LiveFrame, into target: MTLTexture, present drawable: MTLDrawable? = nil) {
        var f = frame
        f.settings.seed = 0
        let cmd = queue.makeCommandBuffer()!
        drawUI(
            cmd: cmd,
            target: baseTex,
            clear: MTLClearColor(red: Double(f.clear.r), green: Double(f.clear.g), blue: Double(f.clear.b), alpha: 1),
            insts: f.base
        )
        drawUI(cmd: cmd, target: textTex, clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0), insts: f.text)
        let scene = LightScene(prims: f.prims, lights: f.lights, settings: f.settings, emission: nil)
        _ = light.render(scene: scene, commandBuffer: cmd, baseTexture: baseTex, textTexture: textTex, targetTexture: target)
        if let drawable {
            cmd.present(drawable)
        }
        cmd.commit()
        if drawable == nil {
            cmd.waitUntilCompleted()
        }
    }
}
#endif
