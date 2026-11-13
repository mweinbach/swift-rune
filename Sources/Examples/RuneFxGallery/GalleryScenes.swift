import Foundation
import RuneFX

let galleryW: Float = 640.0
let galleryH: Float = 360.0
let galleryS: Float = 2.0
let gallerySrcPad: Float = 4.0

let galleryEffects: [String] = [
    "glow", "pulse", "electric", "fire", "motion", "distort", "extras",
    "liquid-metal", "plastic", "mesh-gradient", "dither", "grain-gradient",
    "fluted-glass", "fills", "fill-presets",
]

enum GalleryTarget: Equatable {
    case main
    case mask
    case src
}

enum GalleryOp {
    case ui(Range<Int>)
    case fx(Int)
    case backdrop
}

final class GalleryBuilder {
    let atlas: TextAtlas
    var ui: [UiInst] = []
    var mask: [UiInst] = []
    var src: [UiInst] = []
    var srcRect: FxRect?
    var layers: [FxLayer] = []
    var slots: [FxSlot] = []
    var ops: [GalleryOp] = []
    var target: GalleryTarget = .main
    let t: Float
    let reduced: Bool

    init(atlas: TextAtlas, t: Float, reduced: Bool) {
        self.atlas = atlas
        self.t = t
        self.reduced = reduced
    }

    private func push(_ u0: UiInst) {
        var u = u0
        let s = galleryS
        switch target {
        case .main:
            u.vp = SIMD4<Float>(galleryW * s, galleryH * s, 0, 0)
            let i = ui.count
            ui.append(u)
            if let last = ops.last, case .ui(let r) = last, r.upperBound == i {
                ops[ops.count - 1] = .ui(r.lowerBound..<(i + 1))
                return
            }
            ops.append(.ui(i..<(i + 1)))
        case .mask:
            u.vp = SIMD4<Float>(galleryW * s, galleryH * s, 0, 0)
            mask.append(u)
        case .src:
            let r = srcRect!
            u.rect.x -= (r.x - gallerySrcPad) * s
            u.rect.y -= (r.y - gallerySrcPad) * s
            u.vp = SIMD4<Float>((r.w + 2 * gallerySrcPad) * s, (r.h + 2 * gallerySrcPad) * s, 0, 0)
            src.append(u)
        }
    }

    func rect(_ r: FxRect, radius: Float, _ fill: SIMD4<Float>, _ fill2: SIMD4<Float>, _ border: SIMD4<Float>, _ bw: Float) {
        let s = galleryS
        push(UiInst(
            rect: SIMD4<Float>(r.x * s, r.y * s, r.w * s, r.h * s),
            p: SIMD4<Float>(radius * s, bw * s, 0, 0),
            fill: fill,
            fill2: fill2,
            border: border,
            uv: .zero,
            vp: .zero
        ))
    }

    func shadow(_ r: FxRect, radius: Float, sigma: Float, _ c: SIMD4<Float>) {
        let s = galleryS
        push(UiInst(
            rect: SIMD4<Float>(r.x * s, r.y * s, r.w * s, r.h * s),
            p: SIMD4<Float>(radius * s, 0, 2, sigma * s),
            fill: c,
            fill2: c,
            border: .zero,
            uv: .zero,
            vp: .zero
        ))
    }

    @discardableResult
    func text(_ x: Float, _ y: Float, _ str: String, size: Float, weight: UInt8, _ c: SIMD4<Float>) -> Float {
        let s = galleryS
        let reg = atlas.get(str, sizePx: size * s, weight: weight)
        push(UiInst(
            rect: SIMD4<Float>(x * s - 2.0, y * s - reg.ascent, reg.w, reg.h),
            p: SIMD4<Float>(0, 0, 1, 0),
            fill: c,
            fill2: c,
            border: .zero,
            uv: reg.uv,
            vp: .zero
        ))
        return reg.w / s
    }

    func textW(_ str: String, size: Float, weight: UInt8) -> Float {
        atlas.get(str, sizePx: size * galleryS, weight: weight).w / galleryS - 4.0 / galleryS
    }

    func textC(_ cx: Float, _ cy: Float, _ str: String, size: Float, weight: UInt8, _ c: SIMD4<Float>) {
        let w = textW(str, size: size, weight: weight)
        text(cx - w * 0.5, cy + size * 0.36, str, size: size, weight: weight, c)
    }

    func fx(_ l: FxLayer) {
        fxWith(l, FxSlot())
    }

    func fxWith(_ l0: FxLayer, _ slot: FxSlot) {
        let l = l0.at(l0.time == 0.0 ? t : l0.time).reduced(reduced)
        ops.append(.fx(layers.count))
        layers.append(l)
        slots.append(slot)
    }

    func backdrop() {
        ops.append(.backdrop)
    }

    func background(_ title: String, _ sub: String) {
        rect(FxRect(x: 0, y: 0, w: galleryW, h: galleryH), radius: 0, col(0x0c0d11, 1), col(0x0a0b0e, 1), .zero, 0)
        let w = text(24, 34, title, size: 15, weight: 2, col(0xeceef2, 1))
        text(24 + w + 8, 34, sub, size: 12, weight: 0, col(0x6b7280, 1))
    }

    func card(_ r: FxRect, radius: Float) {
        shadow(FxRect(x: r.x, y: r.y + 8, w: r.w, h: r.h), radius: radius, sigma: 16, SIMD4<Float>(0, 0, 0, 0.45))
        rect(r, radius: radius, col(0x17191f, 1), col(0x121419, 1), col(0xffffff, 0.075), 1.0 / galleryS)
    }

    func lines(_ x: Float, _ y: Float, _ w: Float, _ n: Int) {
        let ratios: [Float] = [1.0, 0.82, 0.6, 0.9]
        for i in 0..<n {
            let ww = w * ratios[i % 4]
            rect(FxRect(x: x, y: y + Float(i) * 14.0, w: ww, h: 6), radius: 3, col(0x262a33, 1), col(0x262a33, 1), .zero, 0)
        }
    }

    func button(_ r: FxRect, _ label: String, top: UInt32, bottom: UInt32, textColor: UInt32) {
        shadow(FxRect(x: r.x, y: r.y + 4, w: r.w, h: r.h), radius: r.h * 0.5, sigma: 8, SIMD4<Float>(0, 0, 0, 0.4))
        rect(r, radius: r.h * 0.5, col(top, 1), col(bottom, 1), col(0xffffff, 0.16), 1.0 / galleryS)
        let cx = r.x + r.w * 0.5
        let cy = r.y + r.h * 0.5
        textC(cx, cy, label, size: 14, weight: 2, col(textColor, 1))
    }

    func caption(_ x: Float, _ y: Float, _ s: String) {
        text(x, y, s, size: 11, weight: 1, col(0x6b7280, 1))
    }
}

func galleryFling(_ t: Float) -> Pose {
    let x0: Float = -150
    let target: Float = 410
    let v0: Float = 3000
    let d: Float = 0.6
    let ts: Float = 0
    let w = (2.0 * Float.pi) / d
    let tau = max(t - ts, 0)
    let a = x0 - target
    let b = v0 + w * a
    let e = expf(-w * tau)
    let x = target + (a + b * tau) * e
    let v: Float = (t < ts) ? 0 : (b - w * (a + b * tau)) * e
    return Pose(x: x, y: 0, rotation: v * 0.00005, scale: 1, opacity: 1)
}

func buildGalleryScene(name: String, into b: GalleryBuilder) {
    let t = b.t
    switch name {
    case "glow":
        b.background("Glow", "soft · neon that cools · aura · text bloom · hot core")
        let btn = FxRect(x: 56, y: 92, w: 150, h: 44)
        b.fx(Fx.glow(GlowParams(radius: 16, intensity: 0.85, breathe: 0.4, breathePeriod: 2.6, hot: 0.4))
            .on(FxShape.capsule(x: btn.x, y: btn.y, w: btn.w, h: btn.h)))
        b.button(btn, "Generate", top: 0x8f72ff, bottom: 0x6646ee, textColor: 0xffffff)
        b.caption(56, 166, "Soft · breathing")

        let card = FxRect(x: 262, y: 70, w: 156, h: 96)
        b.card(card, radius: 14)
        b.text(278, 98, "Neon", size: 14, weight: 2, col(0xe6f9ff, 1))
        b.lines(278, 116, 100, 3)
        var heat = Heat(attack: 0.12, cool: 0.32)
        heat.set(at: -1.0, on: true)
        heat.set(at: 0.35, on: false)
        let h: Float = t < 0.35 ? 1.0 : heat.at(t)
        b.fx(Fx.glow(GlowParams(
            style: .neon,
            color: rgb(0x22d3ee),
            core: rgb(0xeafcff),
            radius: 10,
            intensity: 1.0,
            inner: 0.35,
            heat: h,
            hot: 0.9,
            rimWidth: 0.55
        )).on(FxShape.rounded(x: card.x, y: card.y, w: card.w, h: card.h, radius: 14)).over())
        b.caption(262, 192, "Neon · lights cool, never cut")

        let cap = FxRect(x: 56, y: 236, w: 300, h: 48)
        b.shadow(FxRect(x: cap.x, y: cap.y + 6, w: cap.w, h: cap.h), radius: 24, sigma: 12, SIMD4<Float>(0, 0, 0, 0.5))
        b.rect(cap, radius: 24, col(0x15171d, 1), col(0x111318, 1), col(0xffffff, 0.08), 0.5)
        b.text(80, 265, "Ask anything…", size: 14, weight: 0, col(0x7d8390, 1))
        b.fx(Fx.glow(GlowParams(
            style: .aura,
            color: rgb(0xff5fa2),
            core: rgb(0x8b5cf6),
            third: rgb(0x38bdf8),
            radius: 12,
            intensity: 0.9,
            inner: 0.55,
            occlusion: 0.1,
            hot: 0.55,
            auraSpeed: 0.15,
            rimWidth: 0.6
        )).on(FxShape.capsule(x: cap.x, y: cap.y, w: cap.w, h: cap.h)).over())
        b.caption(56, 308, "Aura · flowing spectrum")

        let (tx, ty): (Float, Float) = (432, 292)
        b.target = .mask
        b.text(tx, ty, "Rune", size: 64, weight: 2, col(0xffffff, 1))
        b.target = .main
        b.fx(Fx.glow(GlowParams(
            style: .mask,
            color: rgb(0xff8a2a),
            core: rgb(0xfff1d6),
            radius: 10,
            intensity: 1.1,
            breathe: 0.25,
            breathePeriod: 3.2,
            hot: 0.0
        )).on(FxShape.rounded(x: tx, y: ty - 56, w: 160, h: 72, radius: 0))
            .source(slot: 0, rect: FxRect(x: 0, y: 0, w: galleryW, h: galleryH)))
        b.text(tx, ty, "Rune", size: 64, weight: 2, col(0xfff4e6, 1))
        b.caption(432, 320, "Mask · text bloom")

        let dot = FxShape.circle(cx: 470, cy: 112, r: 7)
        b.fx(Fx.glow(GlowParams(color: rgb(0xffa630), core: rgb(0xfff6e0), radius: 9, intensity: 1.3, hot: 1.0)).on(dot))
        b.rect(dot.rect, radius: 7, col(0xfff3dc, 1), col(0xffd9a0, 1), .zero, 0)
        b.text(490, 117, "Recording", size: 13, weight: 1, col(0xd6d9df, 1))
        b.caption(462, 166, "Hot core")

    case "pulse":
        b.background("Pulses", "radar · breathing halo · heartbeat · ping that lands and ripples")
        let rec = FxShape.circle(cx: 96, cy: 112, r: 18)
        b.fx(Fx.pulse(PulseParams(color: rgb(0xff4d5e), core: rgb(0xffe4e6), period: 2.2, reach: 46, width: 1.3)).on(rec))
        b.rect(rec.rect, radius: 18, col(0xff5a68, 1), col(0xe5243b, 1), col(0xffffff, 0.2), 0.5)
        b.rect(FxRect(x: 90, y: 106, w: 12, h: 12), radius: 3, col(0xffffff, 0.95), col(0xffffff, 0.95), .zero, 0)
        b.caption(76, 184, "Radar")

        let av = FxShape.circle(cx: 236, cy: 112, r: 22)
        b.fx(Fx.pulse(PulseParams(style: .breathe, color: rgb(0x34d399), core: rgb(0xd1fae5), period: 2.8, reach: 12, intensity: 0.8)).on(av))
        b.rect(av.rect, radius: 22, col(0x3a4150, 1), col(0x262b35, 1), col(0x34d399, 0.9), 1.0)
        b.textC(236, 112, "KL", size: 14, weight: 2, col(0xeef0f3, 1))
        b.caption(196, 184, "Breathing halo")

        let live = FxRect(x: 354, y: 98, w: 74, h: 28)
        b.fx(Fx.pulse(PulseParams(style: .heartbeat, color: rgb(0xff3b6b), core: rgb(0xffe4ec), period: 1.1, reach: 26, width: 1.1))
            .on(FxShape.capsule(x: live.x, y: live.y, w: live.w, h: live.h)))
        b.rect(live, radius: 14, col(0xf43f5e, 1), col(0xdb1f48, 1), col(0xffffff, 0.2), 0.5)
        b.textC(391, 112, "LIVE", size: 12, weight: 2, col(0xffffff, 1))
        b.caption(360, 184, "Heartbeat")

        let send = FxShape.circle(cx: 84, cy: 268, r: 16)
        let inbox = FxRect(x: 446, y: 222, w: 150, h: 92)
        b.card(inbox, radius: 14)
        b.text(462, 250, "Inbox", size: 14, weight: 2, col(0xeef0f3, 1))
        b.lines(462, 266, 96, 3)
        b.fx(Fx.pulse(PulseParams(
            style: .ping(from: SIMD2<Float>(104, 268), dir: SIMD2<Float>(1, 0), travel: 332),
            color: rgb(0x60a5fa),
            core: rgb(0xf0f7ff),
            t0: 0.05,
            duration: 0.62,
            lag: 0.16,
            headRadius: 2.6
        )).on(send))
        b.button(send.rect, "", top: 0x4b8dff, bottom: 0x2f6fe8, textColor: 0xffffff)
        b.textC(84, 267, "→", size: 15, weight: 2, col(0xffffff, 1))
        b.fx(Fx.pulse(PulseParams(
            style: .ripple(at: SIMD2<Float>(452, 268)),
            color: rgb(0x93c5fd),
            core: rgb(0xffffff),
            reach: 0,
            width: 2.2,
            intensity: 0.7,
            t0: 0.62,
            duration: 0.9
        )).on(FxShape.rounded(x: inbox.x, y: inbox.y, w: inbox.w, h: inbox.h, radius: 14)).over())
        b.caption(64, 330, "Ping → ripple (anticipation, decelerating landing, cools)")

    case "electric":
        b.background("Electricity", "arc with forks · border current · calm charged border")
        let a = SIMD2<Float>(64, 96)
        let c = SIMD2<Float>(576, 96)
        b.fx(Fx.electric(ElectricParams(
            style: .arc(a: SIMD2<Float>(a.x + 6, a.y), b: SIMD2<Float>(c.x - 6, c.y)),
            amplitude: 9,
            glow: 6,
            forks: 0.6,
            strands: 3
        )).on(FxShape.rounded(x: a.x, y: a.y - 1, w: c.x - a.x, h: 2, radius: 0)))
        for p in [a, c] {
            b.rect(FxRect(x: p.x - 8, y: p.y - 8, w: 16, h: 16), radius: 8, col(0xb8c0cc, 1), col(0x4b5563, 1), col(0xffffff, 0.3), 0.5)
        }
        b.caption(64, 140, "Arc · forks shoot out and cool")
        let card = FxRect(x: 64, y: 178, w: 236, h: 132)
        b.card(card, radius: 16)
        b.text(84, 210, "Overload", size: 15, weight: 2, col(0xeef0f3, 1))
        b.lines(84, 228, 170, 4)
        b.fx(Fx.electric(ElectricParams(amplitude: 4, glow: 5, gap: 3, forkLen: 22))
            .on(FxShape.rounded(x: card.x, y: card.y, w: card.w, h: card.h, radius: 16))
            .seed(7))
        b.caption(64, 340, "Border current")
        let btn = FxRect(x: 380, y: 222, w: 196, h: 50)
        b.button(btn, "Charged", top: 0x1e2a44, bottom: 0x162036, textColor: 0xdbe8ff)
        var charged = ElectricParams.charged()
        charged.color = rgb(0x60a5fa)
        b.fx(Fx.electric(charged).on(FxShape.capsule(x: btn.x, y: btn.y, w: btn.w, h: btn.h)).seed(3))
        b.caption(380, 300, "Charged border (calm, for UI)")

    case "fire":
        b.background("Fire & plasma", "flames + embers · plasma border · heat for a button")
        let card = FxRect(x: 72, y: 204, w: 224, h: 124)
        b.fx(Fx.fire(FireParams()).on(FxShape.rounded(x: card.x, y: card.y, w: card.w, h: card.h, radius: 16)).seed(5))
        b.card(card, radius: 16)
        b.text(92, 236, "Hot take", size: 15, weight: 2, col(0xfff1e6, 1))
        b.lines(92, 254, 160, 4)

        let cap = FxRect(x: 356, y: 118, w: 224, h: 56)
        b.fx(Fx.fire(FireParams.plasma()).on(FxShape.capsule(x: cap.x, y: cap.y, w: cap.w, h: cap.h)).seed(11))
        b.rect(cap, radius: 28, col(0x17142a, 1), col(0x100e1f, 1), col(0xb9a8ff, 0.25), 0.5)
        b.textC(cap.x + cap.w * 0.5, cap.y + cap.h * 0.5, "Plasma", size: 15, weight: 2, col(0xe9e4ff, 1))
        b.caption(356, 214, "Plasma border")

        let btn = FxRect(x: 392, y: 266, w: 152, h: 44)
        b.fx(Fx.fire(FireParams.heat()).on(FxShape.capsule(x: btn.x, y: btn.y, w: btn.w, h: btn.h)).seed(2))
        b.button(btn, "Deploy", top: 0xff8a3d, bottom: 0xe8590c, textColor: 0xffffff)
        b.backdrop()
        b.fx(Fx.distort(.heatHaze(height: 26, scale: 9, speed: 2, amount: 1.1, wholeShape: false))
            .on(FxShape.capsule(x: btn.x, y: btn.y, w: btn.w, h: btn.h)))
        b.caption(392, 336, "Heat (UI) + haze")
        b.caption(72, 350, "Flames + embers")

    case "motion":
        b.background("Motion blur", "a card flung across the frame · none / directional / shutter 180°")
        let rest = FxRect(x: 60, y: 0, w: 124, h: 74)
        let lanes: [(String, Float, Float, BlurMode)] = [
            ("No blur", 62, 0, .shutter),
            ("Directional (cheap fallback)", 162, 180, .directional),
            ("Shutter 180° (exact sub-frame poses)", 262, 180, .shutter),
        ]
        for (i, (label, y, angle, mode)) in lanes.enumerated() {
            let r = FxRect(x: rest.x, y: y, w: rest.w, h: rest.h)
            b.caption(24, y + rest.h + 18, label)
            if i == 0 {
                b.srcRect = r
                b.target = .src
                b.shadow(FxRect(x: r.x, y: r.y + 4, w: r.w, h: r.h), radius: 14, sigma: 4, SIMD4<Float>(0, 0, 0, 0.35))
                b.rect(r, radius: 14, col(0x23262e, 1), col(0x1a1c22, 1), col(0xffffff, 0.1), 0.5)
                b.rect(FxRect(x: r.x + 12, y: r.y + 12, w: 26, h: 26), radius: 13, col(0x9b7bff, 1), col(0x6d4cf5, 1), .zero, 0)
                b.text(r.x + 46, r.y + 23, "Flight 204", size: 12.5, weight: 2, col(0xf3f4f6, 1))
                b.text(r.x + 46, r.y + 37, "Departing 9:41", size: 10.5, weight: 0, col(0x9aa1ad, 1))
                b.rect(FxRect(x: r.x + 12, y: r.y + 56, w: r.w - 24, h: 5), radius: 2.5, col(0x30343d, 1), col(0x30343d, 1), .zero, 0)
                b.rect(FxRect(x: r.x + 12, y: r.y + 56, w: (r.w - 24) * 0.62, h: 5), radius: 2.5, col(0x34d399, 1), col(0x10b981, 1), .zero, 0)
                b.target = .main
            }
            let baseRect = b.srcRect!
            let srcR = baseRect.inflate(gallerySrcPad)
            let dy = y - 62.0
            let p = MotionBlurParams(mode: mode, shutterAngle: angle)
            var sp = p
            if b.reduced { sp.shutterAngle = 0 }
            let samples = MotionSamples.fromTrack(sp, rest: baseRect, at: t, scale: galleryS) { tt in
                var q = galleryFling(tt)
                q.y += dy
                return q
            }
            b.fx(Fx.motionBlur(p, samples)
                .on(FxShape.rounded(x: r.x, y: r.y, w: r.w, h: r.h, radius: 14))
                .source(slot: 1, rect: srcR))
        }

    case "distort":
        b.background("Distortion", "liquid-glass lens (gooey union) · shockwave · CRT · chromatic split")
        let tiles: [(UInt32, UInt32, String)] = [
            (0x8b5cf6, 0x5b21b6, "Violet"),
            (0xfb923c, 0xea580c, "Ember"),
            (0x2dd4bf, 0x0f766e, "Lagoon"),
            (0xf472b6, 0xbe185d, "Orchid"),
        ]
        for (i, (a, c, label)) in tiles.enumerated() {
            let x = 40 + Float(i) * 143
            b.rect(FxRect(x: x, y: 60, w: 131, h: 64), radius: 12, col(a, 1), col(c, 1), col(0xffffff, 0.15), 0.5)
            b.text(x + 12, 112, label, size: 13, weight: 2, col(0xffffff, 0.95))
        }
        let para = [
            "Glass bends what is behind it: the rim squeezes the page,",
            "the middle stays sharp, and colour splits only at the edge.",
            "Rune samples the backdrop once per lens and lights the rim.",
        ]
        for (i, l) in para.enumerated() {
            b.text(40, 152 + Float(i) * 20, l, size: 13, weight: 0, col(0xb4b9c4, 1))
        }
        let crt = FxRect(x: 40, y: 222, w: 250, h: 118)
        b.rect(crt, radius: 12, col(0x0d1a12, 1), col(0x07110b, 1), .zero, 0)
        b.text(56, 250, "> rune build --release", size: 13, weight: 1, col(0x4ade80, 1))
        b.text(56, 270, "  compiling rune-fx v0.0.1", size: 13, weight: 0, col(0x86efac, 0.8))
        b.text(56, 290, "  finished in 1.84 s", size: 13, weight: 0, col(0x86efac, 0.8))
        b.rect(FxRect(x: 56, y: 304, w: 120, h: 14), radius: 3, col(0x22c55e, 1), col(0x16a34a, 1), .zero, 0)
        b.text(330, 300, "Chromatic", size: 40, weight: 2, col(0xf3f4f6, 1))

        let lx: Float = b.reduced ? 380 : 352 + 70 * (0.5 - 0.5 * cosf(t * 2.2))
        b.backdrop()
        b.fx(Fx.lens(LensParams(second: FxShape.circle(cx: lx, cy: 116, r: 30), unionK: 26))
            .on(FxShape.capsule(x: 140, y: 84, w: 200, h: 64)))
        b.backdrop()
        b.fx(Fx.lens(LensParams(frost: 1.0)).on(FxShape.capsule(x: 388, y: 92, w: 220, h: 66)))
        b.backdrop()
        b.fx(Fx.distort(.shockwave(at: SIMD2<Float>(470, 150), t0: 0.0)).on(FxShape.rounded(x: 0, y: 0, w: galleryW, h: galleryH, radius: 0)))
        b.backdrop()
        b.fx(Fx.distort(.crt()).on(FxShape.rounded(x: crt.x, y: crt.y, w: crt.w, h: crt.h, radius: 12)))
        b.backdrop()
        b.fx(Fx.distort(.chromaSplit(offset: SIMD2<Float>(1.6, 0), glitch: 0.3, feather: 2.0))
            .on(FxShape.rounded(x: 322, y: 256, w: 260, h: 60, radius: 6)))

    case "extras":
        b.background("Extras", "skeleton shimmer · text sheen · sparkles · aurora + grain")
        let list = FxRect(x: 40, y: 62, w: 280, h: 186)
        b.card(list, radius: 16)
        for i in 0..<3 {
            let y = list.y + 22 + Float(i) * 54
            for tgt in [GalleryTarget.main, GalleryTarget.mask] {
                b.target = tgt
                let c = (tgt == .main) ? col(0x22262e, 1) : col(0xffffff, 1)
                b.rect(FxRect(x: list.x + 20, y: y, w: 32, h: 32), radius: 16, c, c, .zero, 0)
                b.rect(FxRect(x: list.x + 64, y: y + 4, w: 160 - Float(i) * 24, h: 10), radius: 5, c, c, .zero, 0)
                b.rect(FxRect(x: list.x + 64, y: y + 20, w: 104, h: 8), radius: 4, c, c, .zero, 0)
            }
            b.target = .main
        }
        b.fx(Fx.shimmer(ShimmerParams(band: 42, intensity: 0.11, useMask: true))
            .on(FxShape.rounded(x: list.x, y: list.y, w: list.w, h: list.h, radius: 16))
            .source(slot: 0, rect: FxRect(x: 0, y: 0, w: galleryW, h: galleryH)))
        b.caption(40, 272, "Skeleton shimmer")
        b.text(40, 316, "Thinking…", size: 20, weight: 1, col(0x8b919c, 1))
        b.target = .mask
        b.text(40, 316, "Thinking…", size: 20, weight: 1, col(0xffffff, 1))
        b.target = .main
        b.fx(Fx.shimmer(ShimmerParams(period: 1.6, band: 18, angle: 0.25, intensity: 0.85, useMask: true))
            .on(FxShape.rounded(x: 36, y: 292, w: 110, h: 32, radius: 0))
            .source(slot: 0, rect: FxRect(x: 0, y: 0, w: galleryW, h: galleryH)))
        b.caption(40, 344, "Text sheen")

        let au = FxRect(x: 352, y: 62, w: 248, h: 152)
        b.card(au, radius: 18)
        b.fx(Fx.aurora(AuroraParams(scale: 110, intensity: 0.75, feather: 18))
            .on(FxShape.rounded(x: au.x, y: au.y, w: au.w, h: au.h, radius: 18)).over())
        b.fx(Fx.grain(GrainParams(amount: 0.016))
            .on(FxShape.rounded(x: au.x, y: au.y, w: au.w, h: au.h, radius: 18)))
        b.text(372, 196, "Aurora", size: 18, weight: 2, col(0xf5f7fa, 1))
        b.caption(352, 238, "Aurora + static grain")

        let pro = FxRect(x: 432, y: 274, w: 88, h: 34)
        b.rect(pro, radius: 17, col(0xf7d98b, 1), col(0xcf9f38, 1), col(0xffffff, 0.4), 0.5)
        b.textC(476, 291, "PRO", size: 13, weight: 2, col(0x3b2a06, 1))
        b.fx(Fx.sparkles(SparkleParams(count: 6, size: 8, margin: 20))
            .on(FxShape.capsule(x: pro.x, y: pro.y, w: pro.w, h: pro.h)).seed(4))
        b.caption(432, 344, "Sparkles")

    case "liquid-metal":
        b.background("Liquid metal", "chrome · gold · rose gold · gunmetal · as a border")
        func lmShadow(_ r: FxRect, _ radius: Float) {
            b.shadow(FxRect(x: r.x, y: r.y + 10, w: r.w, h: r.h), radius: radius, sigma: 16, SIMD4<Float>(0, 0, 0, 0.55))
        }
        let slab = FxRect(x: 32, y: 58, w: 260, h: 160)
        lmShadow(slab, 40)
        b.fx(Fx.fill(FillStyle.liquidMetal(LiquidMetalParams.chrome()).intensity(1)).on(FxShape.rounded(x: slab.x, y: slab.y, w: slab.w, h: slab.h, radius: 40)))
        b.caption(32, 238, "Chrome")

        let btn = FxRect(x: 318, y: 62, w: 180, h: 52)
        lmShadow(btn, 26)
        b.fx(Fx.fill(FillStyle.liquidMetal(LiquidMetalParams.gold()).intensity(1)).on(FxShape.capsule(x: btn.x, y: btn.y, w: btn.w, h: btn.h)))
        b.caption(318, 134, "Gold")

        lmShadow(FxRect(x: 534, y: 54, w: 68, h: 68), 34)
        b.fx(Fx.fill(FillStyle.liquidMetal(LiquidMetalParams.rose()).intensity(1)).on(FxShape.circle(cx: 568, cy: 88, r: 34)))
        b.caption(534, 134, "Rose gold")

        let gm = FxRect(x: 318, y: 152, w: 290, h: 66)
        lmShadow(gm, 18)
        b.fx(Fx.fill(FillStyle.liquidMetal(LiquidMetalParams.gunmetal()).intensity(1)).on(FxShape.rounded(x: gm.x, y: gm.y, w: gm.w, h: gm.h, radius: 18)))
        b.caption(318, 238, "Gunmetal")

        let card = FxRect(x: 32, y: 262, w: 260, h: 74)
        b.card(card, radius: 24)
        b.fx(Fx.fill(FillStyle.liquidMetal(LiquidMetalParams.chrome()).border(7)).on(FxShape.rounded(x: card.x, y: card.y, w: card.w, h: card.h, radius: 24)))
        b.textC(card.x + card.w * 0.5, card.y + card.h * 0.5, "Chrome border", size: 15, weight: 2, col(0xe8eaee, 1))

        b.rect(FxRect(x: 330, y: 263, w: 72, h: 72), radius: 36, col(0x7c5cff, 1), col(0x2b1b5a, 1), .zero, 0)
        b.textC(366, 299, "KL", size: 22, weight: 2, col(0xffffff, 0.95))
        b.fx(Fx.fill(FillStyle.liquidMetal(LiquidMetalParams.gold()).border(4)).on(FxShape.circle(cx: 366, cy: 299, r: 36)))

        let cap = FxRect(x: 428, y: 272, w: 180, h: 54)
        b.rect(cap, radius: 27, col(0x1a1c22, 1), col(0x121419, 1), .zero, 0)
        b.fx(Fx.fill(FillStyle.liquidMetal(LiquidMetalParams.rose()).border(5)).on(FxShape.capsule(x: cap.x, y: cap.y, w: cap.w, h: cap.h)))
        b.textC(cap.x + cap.w * 0.5, cap.y + cap.h * 0.5, "Rose border", size: 14, weight: 2, col(0xf2d4c8, 1))

    case "plastic":
        b.background("Plastic", "glossy · matte and dished · liquid metal keys pinned to the window or to each key")
        let colors: [UInt32] = [0xece8de, 0x2e3036, 0xd7263d, 0xf46036, 0xffd60a, 0x2a9d8f, 0x3d6fd6, 0x7b5cd6]
        let labels = ["Esc", "Q", "W", "E", "R", "T", "Y", "U"]
        let rows: [(Float, PlasticParams, String)] = [
            (52, PlasticParams(roughness: 0.12), "Glossy: roughness .12, dome .35"),
            (138, PlasticParams(roughness: 0.8, dome: -0.4), "Matte, dished: roughness .8, dome −.4"),
        ]
        for (y, baseP, capText) in rows {
            for (k, (cHex, label)) in zip(colors, labels).enumerated() {
                let r = FxRect(x: 54 + Float(k) * 68, y: y, w: 56, h: 56)
                b.shadow(FxRect(x: r.x, y: r.y + 5, w: r.w, h: r.h), radius: 10, sigma: 6, SIMD4<Float>(0, 0, 0, 0.55))
                var p = baseP
                let c = rgb(cHex)
                p.color = c
                b.fx(Fx.fill(FillParams(.plastic(p))).on(FxShape.rounded(x: r.x, y: r.y, w: r.w, h: r.h, radius: 10)))
                let lum = c.r + c.g + c.b
                let ink = lum > 1.2 ? col(0x26272b, 0.85) : col(0xf4f4f6, 0.9)
                b.textC(r.x + r.w * 0.5, r.y + r.h * 0.5, label, size: 13, weight: 2, ink)
            }
            b.caption(54, y + 74, capText)
        }
        let anchorRows: [(Float, FillAnchor, String)] = [
            (232, .world, "Liquid metal on 24 pt keys, anchor: world (default)"),
            (290, .element, "Liquid metal on 24 pt keys, anchor: element"),
        ]
        for (y, anchor, capText) in anchorRows {
            for k in 0..<18 {
                let r = FxRect(x: 53 + Float(k) * 30, y: y, w: 24, h: 24)
                b.shadow(FxRect(x: r.x, y: r.y + 3, w: r.w, h: r.h), radius: 5, sigma: 4, SIMD4<Float>(0, 0, 0, 0.55))
                b.fx(Fx.fill(FillStyle.liquidMetal(LiquidMetalParams.chrome().anchor(anchor)).intensity(1))
                    .on(FxShape.rounded(x: r.x, y: r.y, w: r.w, h: r.h, radius: 5)))
            }
            b.caption(54, y + 42, capText)
        }

    case "mesh-gradient":
        b.background("Mesh gradient", "dusk · lagoon · orchid · graphite: drifting points, blended in OKLab")
        b.fx(Fx.fill(FillStyle.meshGradient(MeshGradientParams.dusk()).intensity(1)).on(FxShape.rounded(x: 32, y: 58, w: 300, h: 272, radius: 28)))
        b.text(56, 306, "Dusk", size: 28, weight: 2, col(0xffffff, 0.95))
        let others: [(MeshGradientParams, String)] = [
            (MeshGradientParams.lagoon(), "Lagoon"),
            (MeshGradientParams.orchid(), "Orchid"),
            (MeshGradientParams.graphite(), "Graphite"),
        ]
        for (k, (p, label)) in others.enumerated() {
            let y = 58 + Float(k) * 94
            b.fx(Fx.fill(FillStyle.meshGradient(p).intensity(1)).on(FxShape.rounded(x: 352, y: y, w: 256, h: 84, radius: 18)).seed(UInt32(k + 2)))
            b.text(372, y + 68, label, size: 15, weight: 2, col(0xffffff, 0.92))
        }

    case "dither":
        b.background("Dither", "Bayer 2×2, 4×4, 8×8 · blue noise · of a ramp, noise or the backdrop")
        let xs: [Float] = [32, 182, 332, 482]
        let tiles: [(DitherParams, String)] = [
            (DitherParams.bayer(), "Bayer 4×4, ramp"),
            (DitherParams.handheld(), "Palette, noise"),
            (DitherParams.grain(), "Blue noise, radial"),
            (DitherParams.backdrop(), "Backdrop"),
        ]
        for (x, (p, label)) in zip(xs, tiles) {
            let r = FxRect(x: x, y: 58, w: 140, h: 128)
            if p.input == .backdrop {
                b.rect(r, radius: 16, col(0xff7aa2, 1), col(0x3b2a8f, 1), .zero, 0)
                b.rect(FxRect(x: x + 62, y: 74, w: 64, h: 64), radius: 32, col(0xfff1c2, 1), col(0xffb44d, 1), .zero, 0)
                b.text(x + 14, 172, "Aa", size: 40, weight: 2, col(0xffffff, 1))
                b.backdrop()
            }
            b.fx(Fx.fill(FillStyle.dither(p).intensity(1)).on(FxShape.rounded(x: r.x, y: r.y, w: r.w, h: r.h, radius: 16)))
            b.caption(x, 204, label)
        }
        let pats: [(DitherPattern, String)] = [
            (.bayer2, "Bayer 2×2"),
            (.bayer4, "Bayer 4×4"),
            (.bayer8, "Bayer 8×8"),
            (.white, "White noise"),
        ]
        for (x, (pattern, label)) in zip(xs, pats) {
            var p = DitherParams.bayer()
            p.pattern = pattern
            p.pixel = 3
            p.angle = 0
            p.colors = Stops.hex([0x1b1530, 0x9be7ff])
            b.fx(Fx.fill(FillStyle.dither(p).intensity(1)).on(FxShape.rounded(x: x, y: 222, w: 140, h: 96, radius: 14)))
            b.caption(x, 336, label)
        }

    case "grain-gradient":
        b.background("Grain gradient", "linear · radial · conic, with film grain (mono or colour)")
        let cols: [(Float, GrainGradientParams, String)] = [
            (32, GrainGradientParams.ember(), "Ember (linear, mono)"),
            (229, GrainGradientParams.halo(), "Halo (radial)"),
            (426, GrainGradientParams.sweep(), "Sweep (conic, colour grain)"),
        ]
        for (x, p, label) in cols {
            b.fx(Fx.fill(FillStyle.grainGradient(p).intensity(1)).on(FxShape.rounded(x: x, y: 58, w: 182, h: 250, radius: 22)))
            b.caption(x, 328, label)
        }

    case "fluted-glass":
        b.background("Fluted glass", "reeded · fine · frosted · wide ribs, over moving content")
        b.rect(FxRect(x: 24, y: 48, w: 592, h: 266), radius: 24, col(0x1e2a5a, 1), col(0x0d1226, 1), .zero, 0)
        let blobs: [(UInt32, UInt32, Float, Float, Float)] = [
            (0xff8a3d, 0xe0451f, 140, 118, 54),
            (0x8b5cf6, 0x4c1d95, 255, 236, 62),
            (0x2dd4bf, 0x0f766e, 405, 112, 50),
            (0xf472b6, 0xbe185d, 548, 226, 58),
        ]
        for (k, (a, c, x, y, r)) in blobs.enumerated() {
            let dx: Float = b.reduced ? 0 : 26 * sinf(t * 0.9 + Float(k) * 1.7)
            b.rect(FxRect(x: x - r + dx, y: y - r, w: 2 * r, h: 2 * r), radius: r, col(a, 1), col(c, 1), .zero, 0)
        }
        b.text(46, 214, "Fluted", size: 96, weight: 2, col(0xffffff, 0.96))
        let cols: [(Float, FlutedGlassParams, String)] = [
            (40, FlutedGlassParams.reeded(), "Reeded"),
            (190, FlutedGlassParams.fine(), "Fine"),
            (340, FlutedGlassParams.frosted(), "Frosted"),
            (490, FlutedGlassParams.wide(), "Wide"),
        ]
        for (x, p, label) in cols {
            b.backdrop()
            b.fx(Fx.fill(FillStyle.flutedGlass(p).intensity(1)).on(FxShape.rounded(x: x, y: 60, w: 120, h: 240, radius: 16)))
            b.caption(x, 324, label)
        }

    case "fills":
        b.background("More fills", "metaballs · swirl · voronoi · waves · halftone")
        let xs: [Float] = [32, 229, 426]
        let row1: [(FillParams, String)] = [
            (FillParams(.metaballs(MetaballParams.lava())), "Metaballs"),
            (FillParams(.swirl(SwirlParams.ink())), "Swirl"),
            (FillParams(.voronoi(VoronoiParams.stained())), "Voronoi"),
        ]
        for (x, (p, label)) in zip(xs, row1) {
            b.fx(Fx.fill(p).on(FxShape.rounded(x: x, y: 56, w: 182, h: 118, radius: 18)))
            b.caption(x, 192, label)
        }
        b.fx(Fx.fill(FillStyle.waves(WaveParams.sea()).intensity(1)).on(FxShape.rounded(x: 32, y: 208, w: 182, h: 118, radius: 18)))
        b.caption(32, 344, "Waves")
        b.fx(Fx.fill(FillStyle.halftone(HalftoneParams.print()).intensity(1)).on(FxShape.rounded(x: 229, y: 208, w: 182, h: 118, radius: 18)))
        b.caption(229, 344, "Halftone")
        let r = FxRect(x: 426, y: 208, w: 182, h: 118)
        b.rect(r, radius: 18, col(0xf6d365, 1), col(0xfda085, 1), .zero, 0)
        b.rect(FxRect(x: 470, y: 222, w: 90, h: 90), radius: 45, col(0x5b8def, 1), col(0x1d2b64, 1), .zero, 0)
        b.backdrop()
        b.fx(Fx.fill(FillStyle.halftone(HalftoneParams.backdrop()).intensity(1)).on(FxShape.rounded(x: r.x, y: r.y, w: r.w, h: r.h, radius: 18)))
        b.caption(426, 344, "Halftone of the backdrop")

    case "fill-presets":
        b.background("Fill presets", "every style and preset in the catalog")
        let all: [(FxStyleInfo, FxPreset)] = fillStyles().flatMap { s in s.presets.map { (s, $0) } }
        for (k, (s, p)) in all.enumerated() {
            let x = 28 + Float(k % 8) * 74
            let y = 50 + Float(k / 8) * 78
            let r = FxRect(x: x, y: y, w: 66, h: 44)
            let f = p.fill()
            if f.needsBackdrop {
                b.rect(r, radius: 10, col(0x3b82f6, 1), col(0x1e1b4b, 1), .zero, 0)
                b.rect(FxRect(x: x + 8, y: y + 6, w: 30, h: 30), radius: 15, col(0xffd166, 1), col(0xef476f, 1), .zero, 0)
                b.text(x + 34, y + 36, "Aa", size: 22, weight: 2, col(0xffffff, 1))
                b.backdrop()
            }
            b.fx(Fx.fill(f).on(FxShape.rounded(x: r.x, y: r.y, w: r.w, h: r.h, radius: 10)).seed(UInt32(k)))
            b.text(x, y + 56, s.name, size: 9, weight: 1, col(0x6b7280, 1))
            b.text(x, y + 67, p.name, size: 9, weight: 2, col(0xb4b9c4, 1))
        }

    case "blend":
        b.rect(FxRect(x: 0, y: 0, w: galleryW, h: galleryH), radius: 0, col(0xfaf7f2, 1), col(0xf3ede3, 1), .zero, 0)
        let tw = b.text(24, 34, "Blend", size: 15, weight: 2, col(0x1f1c18, 1))
        b.text(24 + tw + 8, 34, "warm glow & shader fill over #FAF7F2 cream paper", size: 12, weight: 0, col(0x6e6559, 1))

        let modes: [(String, FxBlend)] = [
            ("Normal", .normal),
            ("Multiply", .multiply),
            ("Screen", .screen),
            ("Overlay", .overlay),
            ("SoftLight", .softLight),
        ]
        for (idx, (label, _)) in modes.enumerated() {
            let x = 24 + Float(idx) * 120
            let well = FxRect(x: x, y: 54, w: 112, h: 132)
            b.rect(well, radius: 12, col(0xfaf7f2, 1), col(0xf4efe6, 1), col(0x2b241c, 0.10), 1.0 / galleryS)
            for r in 0..<3 {
                let ry = 140 + Float(r) * 12
                b.rect(FxRect(x: x + 16, y: ry, w: 80 - Float(r) * 14, h: 4), radius: 2, col(0xd8cfc2, 1), col(0xd8cfc2, 1), .zero, 0)
            }
            let card = FxRect(x: x, y: 212, w: 112, h: 108)
            b.rect(card, radius: 12, col(0xf6f0e6, 1), col(0xebe2d3, 1), col(0x2b241c, 0.12), 1.0 / galleryS)
            b.rect(FxRect(x: x + 12, y: 228, w: 56, h: 22), radius: 6, col(0xd48b45, 0.35), col(0xb85d22, 0.35), .zero, 0)
            b.text(x + 16, 274, "Paper", size: 13, weight: 2, col(0x3a3128, 0.85))
            for r in 0..<2 {
                let ry = 286 + Float(r) * 11
                b.rect(FxRect(x: x + 16, y: ry, w: 76 - Float(r) * 18, h: 4), radius: 2, col(0x9c8e7b, 0.55), col(0x9c8e7b, 0.55), .zero, 0)
            }
            b.textC(x + 56, 336, label, size: 11, weight: 2, col(0x3f372e, 1))
        }
        b.backdrop()
        for (idx, (_, mode)) in modes.enumerated() {
            let x = 24 + Float(idx) * 120
            let pill = FxRect(x: x + 22, y: 92, w: 68, h: 32)
            let glow = Fx.glow(GlowParams(
                color: rgb(0xc85a14),
                core: rgb(0xe88c28),
                radius: 22,
                intensity: 1.15,
                inner: 0.65,
                hot: 0.45
            )).on(FxShape.capsule(x: pill.x, y: pill.y, w: pill.w, h: pill.h))
            b.fxWith(glow, FxSlot().blend(mode))
            b.button(pill, "Hero", top: 0x2c2520, bottom: 0x1e1915, textColor: 0xfaf7f2)

            let fillShape = FxShape.rounded(x: x + 8, y: 220, w: 96, h: 92, radius: 10)
            let fill = Fx.fill(FillStyle.grainGradient(GrainGradientParams.ember()).intensity(1)).on(fillShape).opacity(0.82)
            b.fxWith(fill, FxSlot().blend(mode))
        }

    default:
        fputs("error: unknown effect '\(name)'\n", stderr)
        Foundation.exit(1)
    }
}
