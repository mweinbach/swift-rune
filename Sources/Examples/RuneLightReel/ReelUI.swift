import Foundation
import Rune
import RuneLight

let reelS: Float = 2.0
let reelW: Int = 2560
let reelH: Int = 1600
let reelFPS: Int = 60
let reelDuration: Float = 31.0
let reelMips: Int = 12
let reelBloomLevels: Int = 7

let reelTTilt: Float = 7.0
let reelTInputs: Float = 8.3
let reelTCascades: Float = 10.0
let reelTMerge: Float = 12.9
let reelTFluence: Float = 15.2
let reelTUntilt: Float = 16.4
let reelTGlass: Float = 17.8
let reelTArc: Float = 25.2
let reelTEnd: Float = 28.4

let reelUIScale: Float = 0.9
let reelUIO: SIMD2<Float> = SIMD2<Float>(64.0, 18.0)
let reelBG: (Float, Float, Float) = (0.115, 0.012, 268.0)

struct ReelSpring: Sendable {
    var duration: Float
    var bounce: Float

    func eval(d0: Float, v0: Float, t: Float) -> (Float, Float) {
        let w = (2.0 * Float.pi) / max(duration, 1e-3)
        let z = min(max(1.0 - bounce, 0.05), 1.0)
        if z > 0.9999 {
            let c = v0 + w * d0
            let e = exp(-w * t)
            return ((d0 + c * t) * e, (c - w * (d0 + c * t)) * e)
        }
        let wd = w * sqrt(1.0 - z * z)
        let a = d0
        let b = (v0 + z * w * d0) / wd
        let e = exp(-z * w * t)
        let s = sin(wd * t)
        let c = cos(wd * t)
        return (e * (a * c + b * s), e * ((b * wd - z * w * a) * c - (a * wd + z * w * b) * s))
    }
}

func reelSp(_ duration: Float, _ bounce: Float) -> ReelSpring {
    ReelSpring(duration: duration, bounce: bounce)
}

struct ReelKeys: Sendable {
    var initValue: Float
    var keys: [(Float, Float, ReelSpring)]

    func at(_ t: Float) -> Float {
        var x = initValue
        var v: Float = 0.0
        var t0: Float = 0.0
        var target = initValue
        var spring = reelSp(0.3, 0.0)
        for (tk, tg, s) in keys {
            if tk > t { break }
            let (d, vv) = spring.eval(d0: x - target, v0: v, t: tk - t0)
            x = target + d
            v = vv
            t0 = tk
            target = tg
            spring = s
        }
        return target + spring.eval(d0: x - target, v0: v, t: t - t0).0
    }
}

func reelRise(_ t: Float, _ t0: Float, _ dur: Float) -> Float {
    guard t > t0 else { return 0.0 }
    return 1.0 - reelSp(dur, 0.0).eval(d0: 1.0, v0: 0.0, t: t - t0).0
}

func reelWindow(_ t: Float, _ a: Float, _ b: Float, _ fade: Float) -> Float {
    reelRise(t, a, fade) * (1.0 - reelRise(t, b, fade))
}

func reelLerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
    a + (b - a) * t
}

struct ReelCam: Sendable {
    var pitch: Float
    var yaw: Float
    var scale: Float
    var ty: Float
    var tx: Float
}

let reelFovD: Float = 3200.0

func reelProject(_ c: ReelCam, _ x: Float, _ y: Float, _ z: Float) -> SIMD4<Float> {
    let px = (x - Float(reelW) * 0.5) * c.scale
    let py = (y - Float(reelH) * 0.5) * c.scale
    let pz = z * c.scale
    let sy = sin(c.yaw)
    let cy = cos(c.yaw)
    let xr = px * cy - py * sy
    let yr = px * sy + py * cy
    let sp = sin(c.pitch)
    let cp = cos(c.pitch)
    let cz = -pz
    let y2 = yr * cp + cz * sp
    let z2 = -yr * sp + cz * cp
    let x2 = xr + c.tx
    let y3 = y2 + c.ty
    let w = z2 + reelFovD
    return SIMD4<Float>(x2 * reelFovD / (Float(reelW) * 0.5), -y3 * reelFovD / (Float(reelH) * 0.5), 0.5 * w, w)
}

func reelToScreen(_ c: SIMD4<Float>) -> SIMD2<Float> {
    SIMD2<Float>((c.x / c.w + 1.0) * 0.5 * Float(reelW), (1.0 - c.y / c.w) * 0.5 * Float(reelH))
}

func dpx(_ x: Float, _ y: Float, _ w: Float, _ h: Float) -> SIMD4<Float> {
    SIMD4<Float>(
        (reelUIO.x + x * reelUIScale) * reelS,
        (reelUIO.y + y * reelUIScale) * reelS,
        w * reelUIScale * reelS,
        h * reelUIScale * reelS
    )
}

func dpt(_ x: Float, _ y: Float, _ w: Float, _ h: Float) -> SIMD4<Float> {
    SIMD4<Float>(
        reelUIO.x + x * reelUIScale,
        reelUIO.y + y * reelUIScale,
        w * reelUIScale,
        h * reelUIScale
    )
}

struct ReelSt: Sendable {
    var t: Float
    var send: Float
    var rec: Float
    var prog: Float
    var progGlow: Float
    var toastX: Float
    var toastGlow: Float
    var status: Float
    var arc: Float
    var dangerGlow: Float
}

func reelState(t: Float) -> ReelSt {
    let warm: (Float) -> Float = { t0 in reelRise(t, t0, 0.9) }
    var bk: [(Float, Float, ReelSpring)] = []
    var k: Float = 0.25
    var up = true
    while k < reelDuration + 2.0 {
        bk.append((k, up ? 1.0 : 0.5, reelSp(0.9, 0.0)))
        up.toggle()
        k += 1.1
    }
    let breath = ReelKeys(initValue: 0.5, keys: bk).at(t)
    let click: Float = 3.3
    let flare: Float = t > click ? exp(-(t - click) / 0.35) * reelRise(t, click, 0.08) : 0.0
    let send = warm(0.1) * (1.0 + 1.6 * flare)
    let prog = min(ReelKeys(initValue: 0.08, keys: [(click + 0.15, 1.0, reelSp(2.8, 0.0))]).at(t), 1.0)
    let done: Float = 6.1
    let pflash: Float = t > done ? exp(-(t - done) / 0.5) * reelRise(t, done, 0.1) : 0.0
    let progGlow = warm(0.5) * (0.7 + 0.3 * reelRise(t, click, 0.6)) * (1.0 - 0.7 * reelRise(t, done + 0.4, 1.6)) + 1.4 * pflash
    let toastX = ReelKeys(initValue: 420.0, keys: [(1.2, 0.0, reelSp(0.75, 0.12))]).at(t)
    let toastGlow = warm(1.0)
    let arcIn = reelRise(t, reelTArc, 0.35)
    let arcOut = reelRise(t, reelTEnd - 0.4, 0.6)
    return ReelSt(
        t: t,
        send: send,
        rec: warm(0.7) * breath,
        prog: prog,
        progGlow: progGlow,
        toastX: toastX,
        toastGlow: toastGlow,
        status: warm(0.3),
        arc: arcIn * (1.0 - arcOut),
        dangerGlow: arcIn * (1.0 - arcOut)
    )
}

func reelPremul(_ c: Color) -> SIMD4<Float> {
    SIMD4<Float>(c.r * c.a, c.g * c.a, c.b * c.a, c.a)
}

func reelMakeInst(rect: SIMD4<Float>, radii: Float, fill: Color, border: (Color, Float)? = nil) -> ReelUIInst {
    let (bc, bw) = border ?? (.transparent, 0.0)
    return ReelUIInst(
        rect: rect,
        radii: SIMD4<Float>(repeating: radii),
        fill: reelPremul(fill),
        border: bw > 0.0 ? reelPremul(bc) : .zero,
        params: SIMD4<Float>(bw, 0.0, 0.0, 1.0),
        uv: .zero,
        vp: SIMD4<Float>(Float(reelW), Float(reelH), 0.0, 0.0)
    )
}

private func reelScaled(_ c: Color, _ k: Float) -> SIMD3<Float> {
    SIMD3<Float>(c.r * k, c.g * k, c.b * k)
}

final class ReelUI {
    let ts: TextSystem
    var base: [ReelUIInst] = []
    var text: [ReelUIInst] = []
    var prims: [Prim] = []
    let k: Float
    let o: SIMD2<Float>

    init(ts: TextSystem, k: Float, o: SIMD2<Float>) {
        self.ts = ts
        self.k = k
        self.o = o
    }

    func px(_ x: Float, _ y: Float, _ w: Float, _ h: Float) -> SIMD4<Float> {
        SIMD4<Float>((o.x + x * k) * reelS, (o.y + y * k) * reelS, w * k * reelS, h * k * reelS)
    }

    func d(_ v: Float) -> Float {
        v * k * reelS
    }

    func rect(
        _ x: Float, _ y: Float, _ w: Float, _ h: Float,
        _ r: Float,
        _ fill: Color,
        _ border: (Color, Float)? = nil,
        _ light: (Prim, Float) -> Prim = { p, _ in p }
    ) {
        let rPx = px(x, y, w, h)
        let rr = d(r)
        base.append(reelMakeInst(rect: rPx, radii: rr, fill: fill, border: border.map { ($0.0, $0.1 * reelS) }))
        let p = Prim.rect(rPx.x, rPx.y, rPx.z, rPx.w).radius(rr).albedo(SIMD3<Float>(fill.r, fill.g, fill.b))
        prims.append(light(p, k * reelS))
    }

    func paint(_ x: Float, _ y: Float, _ w: Float, _ h: Float, _ r: Float, _ fill: Color) {
        base.append(reelMakeInst(rect: px(x, y, w, h), radii: d(r), fill: fill, border: nil))
    }

    func shadow(_ x: Float, _ y: Float, _ w: Float, _ h: Float, _ r: Float, _ sigma: Float, _ color: Color) {
        var inst = reelMakeInst(rect: px(x, y, w, h), radii: d(r), fill: color, border: nil)
        inst.params = SIMD4<Float>(0.0, 2.0, d(sigma), 1.0)
        base.append(inst)
    }

    @discardableResult
    func text(_ x: Float, _ y: Float, _ s: String, _ size: Float, _ weight: Float, _ color: Color) -> Float {
        let scale = reelS * k
        let style = TextStyle(size: size, weight: weight, family: .systemUI, wrap: .noWrap)
        let shaped = ts.shape(text: s, style: style, maxWidth: nil, pixelScale: scale, emitGlyphs: true)
        let ox = ((o.x + x * k) * reelS).rounded()
        let oy = ((o.y + y * k) * reelS).rounded()
        let fill = reelPremul(color)
        for g in shaped.glyphs {
            text.append(ReelUIInst(
                rect: SIMD4<Float>(ox + g.rect.x * scale, oy + g.rect.y * scale, g.rect.z * scale, g.rect.w * scale),
                radii: .zero,
                fill: fill,
                border: .zero,
                params: SIMD4<Float>(0.0, 1.0, 0.0, 1.0),
                uv: g.uv,
                vp: SIMD4<Float>(Float(reelW), Float(reelH), 0.0, 0.0)
            ))
        }
        return shaped.size.x
    }

    func measure(_ s: String, _ size: Float, _ weight: Float) -> Float {
        let style = TextStyle(size: size, weight: weight, family: .systemUI, wrap: .noWrap)
        return ts.measure(s, style: style, maxWidth: nil, pixelScale: reelS * k).x
    }
}

struct ReelBuiltUI {
    var base: [ReelUIInst]
    var text: [ReelUIInst]
    var prims: [Prim]
}

private func buildReel(_ ui: ReelUI, _ st: ReelSt) {
    let bg = oklch(0.155, 0.01, 268.0)
    let side = oklch(0.175, 0.01, 268.0)
    let card = oklch(0.215, 0.011, 268.0)
    let card2 = oklch(0.245, 0.012, 268.0)
    let user = oklch(0.27, 0.04, 268.0)
    let txt = oklch(0.94, 0.005, 268.0)
    let txt2 = oklch(0.70, 0.012, 268.0)
    let txt3 = oklch(0.54, 0.012, 268.0)
    let hair = oklcha(1.0, 0.0, 0.0, 0.07)
    let raise: (Prim, Float) -> Prim = { p, k in p.raised(6.0 * k).bevel(width: 6.0 * k, height: 2.0 * k).gloss(0.5, roughness: 0.42) }
    let chip: (Prim, Float) -> Prim = { p, k in p.on(6.0 * k).raised(2.5 * k).bevel(width: 4.0 * k, height: 1.0 * k).gloss(0.45, roughness: 0.4) }

    ui.shadow(0.0, 18.0, 1280.0, 800.0, 18.0, 40.0, oklcha(0.0, 0.0, 0.0, 0.6))
    ui.rect(0.0, 0.0, 1280.0, 800.0, 18.0, bg, (oklcha(1.0, 0.0, 0.0, 0.08), 1.0))

    ui.rect(0.0, 0.0, 244.0, 800.0, 18.0, side, nil)
    let r = ui.d(18.0)
    if !ui.base.isEmpty {
        ui.base[ui.base.count - 1].radii = SIMD4<Float>(r, 0.0, 0.0, r)
    }
    if !ui.prims.isEmpty {
        ui.prims[ui.prims.count - 1] = ui.prims[ui.prims.count - 1].radii(SIMD4<Float>(r, 0.0, 0.0, r))
    }
    ui.paint(244.0, 0.0, 1.0, 800.0, 0.0, hair)
    for (i, c) in [oklch(0.62, 0.17, 25.0), oklch(0.78, 0.15, 85.0), oklch(0.72, 0.17, 145.0)].enumerated() {
        ui.paint(20.0 + Float(i) * 18.0, 20.0, 11.0, 11.0, 5.5, oklcha(c.toOKLab()[0], 0.02, 268.0, 0.9))
    }
    ui.text(22.0, 52.0, "OpenCode", 16.0, 600.0, txt)
    ui.rect(16.0, 86.0, 212.0, 36.0, 10.0, card, (hair, 1.0)) { p, k in
        p.raised(3.0 * k).bevel(width: 3.0 * k, height: 1.2 * k).gloss(0.5, roughness: 0.45)
    }
    ui.text(32.0, 95.0, "+  New session", 13.0, 500.0, txt)
    ui.text(22.0, 146.0, "TODAY", 11.0, 600.0, txt3)
    let sessions = ["Radiance cascades for UI", "Thick glass optics", "Electric arcs into GI", "Theme tokens codegen", "Scroll momentum", "Slug text spike"]
    for (i, s) in sessions.enumerated() {
        let y = 170.0 + Float(i) * 38.0
        if i == 0 {
            ui.rect(10.0, y - 8.0, 224.0, 34.0, 9.0, oklcha(1.0, 0.0, 0.0, 0.055), nil)
        }
        ui.text(24.0, y, s, 13.0, i == 0 ? 500.0 : 400.0, i == 0 ? txt : txt2)
    }
    ui.rect(16.0, 740.0, 212.0, 40.0, 20.0, card, (hair, 1.0)) { p, k in
        p.raised(3.0 * k).bevel(width: 5.0 * k, height: 1.5 * k).gloss(0.5, roughness: 0.4)
    }
    let green = oklch(0.80, 0.19, 150.0)
    let g = 3.2 * st.status
    ui.rect(34.0, 755.0, 10.0, 10.0, 5.0, green, nil) { p, k in
        p.on(3.0 * k).emissive(reelScaled(green, g))
    }
    ui.text(54.0, 751.0, "Connected · studio", 12.0, 500.0, txt2)

    ui.text(272.0, 22.0, "Radiance cascades for UI", 15.0, 600.0, txt)
    let model = "claude-opus-5.5"
    let mw = ui.measure(model, 12.0, 500.0)
    ui.rect(900.0 - mw - 26.0, 16.0, mw + 26.0, 28.0, 14.0, card, (hair, 1.0)) { p, k in
        p.raised(2.0 * k).bevel(width: 4.0 * k, height: 1.0 * k).gloss(0.5, roughness: 0.4)
    }
    ui.text(900.0 - mw - 13.0, 22.0, model, 12.0, 500.0, txt2)
    ui.paint(245.0, 60.0, 1035.0, 1.0, 0.0, hair)

    let cx: Float = 272.0
    let cw: Float = 628.0
    let ub = "come on, do radiance cascades UI"
    let uw = ui.measure(ub, 14.0, 400.0) + 36.0
    ui.rect(cx + cw - uw, 82.0, uw, 46.0, 16.0, user, (oklcha(1.0, 0.0, 0.0, 0.08), 1.0), raise)
    ui.text(cx + cw - uw + 18.0, 95.0, ub, 14.0, 400.0, txt)

    ui.rect(cx, 150.0, cw, 140.0, 16.0, card, (hair, 1.0), raise)
    let lines = [
        "Every Rune element is an analytic rounded rect, so the frame is already",
        "an exact distance field. Glowing elements are the only lights here: five",
        "cascades of probes trace that field, merge top down, and light the cards",
        "around them with soft coloured bounce and shadow.",
    ]
    for (i, l) in lines.enumerated() {
        ui.text(cx + 22.0, 168.0 + Float(i) * 22.0, l, 14.0, 400.0, txt)
    }
    let chipXs: [Float] = [0.0, 116.0, 236.0]
    for (i, c) in ["Read gi.wgsl", "Edit cascades", "Run bench"].enumerated() {
        let x = cx + 22.0 + chipXs[i]
        let w = ui.measure(c, 12.0, 500.0) + 22.0
        ui.rect(x, 260.0, w, 24.0, 12.0, card2, (hair, 1.0), chip)
        ui.text(x + 11.0, 264.0, c, 12.0, 500.0, txt2)
    }

    ui.rect(cx, 310.0, cw, 102.0, 16.0, card, (hair, 1.0), raise)
    ui.text(cx + 22.0, 326.0, "Rendering reel", 14.0, 600.0, txt)
    let frame = Int((st.prog * 1860.0).rounded())
    let sub = "frame \(frame) / 1860 · 2560×1600 · 60 fps"
    ui.text(cx + 22.0, 348.0, sub, 12.0, 400.0, txt2)
    let pct = "\(Int((st.prog * 100.0).rounded()))%"
    let pw = ui.measure(pct, 12.0, 600.0)
    ui.text(cx + cw - 22.0 - pw, 326.0, pct, 12.0, 600.0, txt2)
    ui.rect(cx + 22.0, 380.0, cw - 44.0, 10.0, 5.0, oklch(0.19, 0.01, 268.0), nil) { p, k in p.on(6.0 * k) }
    let cyan = oklch(0.82, 0.14, 205.0)
    let pg = 1.7 * st.progGlow
    ui.rect(cx + 22.0, 380.0, (cw - 44.0) * st.prog, 10.0, 5.0, cyan, nil) { p, k in
        p.on(6.0 * k).emissive(reelScaled(cyan, pg))
    }

    ui.rect(cx, 432.0, cw, 156.0, 16.0, card, (hair, 1.0), raise)
    ui.text(cx + 22.0, 448.0, "Glowing elements are lights:", 14.0, 400.0, txt)
    ui.rect(cx + 18.0, 478.0, cw - 36.0, 92.0, 10.0, oklch(0.18, 0.01, 268.0), (hair, 1.0)) { p, k in
        p.on(6.0 * k).gloss(0.2, roughness: 0.5)
    }
    let code: [(String, Color)] = [
        ("let send = Prim::from_rune(rect, radii)", oklch(0.84, 0.07, 230.0)),
        ("    .emissive(ACCENT * glow);", oklch(0.80, 0.09, 300.0)),
        ("lights.render(&Scene { prims, gi: Some(Gi::default()), .. });", oklch(0.84, 0.07, 160.0)),
    ]
    for (i, (l, c)) in code.enumerated() {
        ui.text(cx + 36.0, 492.0 + Float(i) * 22.0, l, 13.0, 400.0, c)
    }

    ui.rect(cx, 652.0, cw, 112.0, 20.0, card, (oklcha(1.0, 0.0, 0.0, 0.1), 1.0)) { p, k in
        p.raised(9.0 * k).bevel(width: 7.0 * k, height: 2.5 * k).gloss(0.6, roughness: 0.38)
    }
    ui.text(cx + 22.0, 672.0, "Ask anything…", 14.0, 400.0, txt3)
    let red = oklch(0.66, 0.22, 25.0)
    let rg = 6.0 * st.rec
    ui.rect(cx + 22.0, 724.0, 14.0, 14.0, 7.0, red, nil) { p, k in
        p.on(9.0 * k).emissive(reelScaled(red, rg))
    }
    let secs = 7 + Int(st.t)
    ui.text(cx + 44.0, 722.0, String(format: "Recording  0:%02d", secs), 12.0, 500.0, oklch(0.78, 0.09, 25.0))
    let accent = oklch(0.70, 0.19, 275.0)
    let sg = 3.4 * st.send
    ui.rect(cx + cw - 58.0, 712.0, 38.0, 38.0, 19.0, accent, nil) { p, k in
        p.on(9.0 * k).raised(3.0 * k).emissive(reelScaled(accent, sg))
    }
    let aw = ui.measure("↑", 17.0, 700.0)
    ui.text(cx + cw - 39.0 - aw * 0.5, 719.0, "↑", 17.0, 700.0, oklch(0.99, 0.01, 275.0))

    let rx: Float = 924.0
    let rw: Float = 332.0
    ui.rect(rx, 150.0, rw, 170.0, 16.0, card, (hair, 1.0), raise)
    ui.text(rx + 20.0, 166.0, "Agents", 14.0, 600.0, txt)
    let agents = [("cascades", "tracing · 5 levels"), ("glass", "refraction pass"), ("review", "Argon · no blockers")]
    for (i, (a, b)) in agents.enumerated() {
        let y = 198.0 + Float(i) * 38.0
        ui.rect(rx + 20.0, y + 4.0, 8.0, 8.0, 4.0, oklch(0.5, 0.02, 268.0), nil) { p, k in p.on(6.0 * k) }
        ui.text(rx + 38.0, y, a, 13.0, 500.0, txt)
        let bw = ui.measure(b, 12.0, 400.0)
        ui.text(rx + rw - 20.0 - bw, y + 1.0, b, 12.0, 400.0, txt2)
    }
    ui.rect(rx, 340.0, rw, 140.0, 16.0, card, (hair, 1.0), raise)
    ui.text(rx + 20.0, 356.0, "Branch rc-reel", 14.0, 600.0, txt)
    ui.text(rx + 20.0, 380.0, "12 commits ahead · 3 files changed", 12.0, 400.0, txt2)
    let danger = oklch(0.42, 0.13, 25.0)
    let dg = 1.4 * st.dangerGlow
    ui.rect(rx + 20.0, 424.0, 150.0, 36.0, 10.0, danger, (oklcha(0.75, 0.14, 25.0, 0.5), 1.0)) { p, k in
        let base = p.on(6.0 * k).raised(3.0 * k).bevel(width: 5.0 * k, height: 1.5 * k).gloss(0.6, roughness: 0.35)
        return dg > 0.0 ? base.emissive(reelScaled(oklch(0.66, 0.2, 25.0), dg)) : base
    }
    ui.text(rx + 43.0, 433.0, "Delete branch", 13.0, 600.0, oklch(0.95, 0.03, 25.0))
    ui.rect(rx + 182.0, 424.0, 130.0, 36.0, 10.0, card2, (hair, 1.0), chip)
    ui.text(rx + 225.0, 433.0, "Cancel", 13.0, 600.0, txt)
    ui.rect(rx, 500.0, rw, 264.0, 16.0, card, (hair, 1.0), raise)
    ui.text(rx + 20.0, 516.0, "GPU per frame", 14.0, 600.0, txt)
    for i in 0..<10 {
        let fi = Float(i)
        let h = 30.0 + 90.0 * (0.5 + 0.5 * (sin(fi * 0.9) * 0.7 + cos(fi * 0.37) * 0.3))
        ui.rect(rx + 24.0 + fi * 29.0, 720.0 - h, 16.0, h, 4.0, oklch(0.34, 0.03, 268.0), nil) { p, k in
            p.on(6.0 * k).raised(2.0 * k)
        }
    }
    ui.text(rx + 20.0, 734.0, "GI · composite · glass", 11.0, 500.0, txt3)

    let tx = rx + st.toastX
    ui.rect(tx, 76.0, rw, 56.0, 14.0, card2, (oklcha(1.0, 0.0, 0.0, 0.1), 1.0)) { p, k in
        p.floating(bottom: 10.0 * k, top: 16.0 * k).bevel(width: 6.0 * k, height: 2.0 * k).gloss(0.6, roughness: 0.38)
    }
    let amber = oklch(0.80, 0.16, 70.0)
    let ag = 2.8 * st.toastGlow
    ui.rect(tx + 16.0, 92.0, 24.0, 24.0, 12.0, amber, nil) { p, k in
        p.on(16.0 * k).emissive(reelScaled(amber, ag))
    }
    let cw2 = ui.measure("✓", 14.0, 700.0)
    if cw2 > 0.0 {
        ui.text(tx + 28.0 - cw2 * 0.5, 94.0, "✓", 14.0, 700.0, oklch(0.25, 0.05, 70.0))
    }
    ui.text(tx + 54.0, 88.0, "Build passed", 13.0, 600.0, txt)
    ui.text(tx + 54.0, 107.0, "ci · 1m 12s", 12.0, 400.0, txt2)
}

func buildReelUI(ts: TextSystem, st: ReelSt) -> ReelBuiltUI {
    let ui = ReelUI(ts: ts, k: reelUIScale, o: reelUIO)
    buildReel(ui, st)
    if st.arc > 0.0 {
        let r = ui.px(924.0 + 20.0 - 24.0, 424.0 - 24.0, 150.0 + 48.0, 36.0 + 48.0)
        ui.prims.append(Prim.rect(r.x, r.y, r.z, r.w).radius(ui.d(30.0)).giHint())
    }
    return ReelBuiltUI(base: ui.base, text: ui.text, prims: ui.prims)
}
