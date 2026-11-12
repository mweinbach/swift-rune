import Foundation
import Rune
import RuneFX
import RuneMotion

enum ShowreelScenesPart2 {
    // MARK: - Pricing

    private static func pricingFeature(_ s: String, on: Bool) -> El<ShowreelState> {
        row().gap(10).itemsCenter()
            .child(
                el().size(16, 16).rounded(8).center()
                    .bg(on ? ShowreelKit.ca(0x54b3fd, 0.18) : ShowreelKit.ca(0xffffff, 0.06))
                    .child(ShowreelKit.dot(on ? 0x54b3fd : 0x8a8a93, 5))
            )
            .child(ShowreelKit.t(s, 13.5, 400, 0xc9c9d0))
    }

    private static func pricingPlan(
        name: String,
        price: String,
        blurb: String,
        feats: [String],
        cta: String,
        pro: Bool,
        press: Float
    ) -> El<ShowreelState> {
        var c: El<ShowreelState> = col().w(268).h(318).p(24).gap(8).rounded(20)
            .bg(ShowreelKit.c(pro ? 0x16181f : 0x121215))
            .border(1, pro ? ShowreelKit.ca(0x54b3fd, 0.35) : ShowreelKit.hair())
            .child(
                row().wFull().itemsCenter()
                    .child(ShowreelKit.t(name, 15, 600, ShowreelKit.TEXT))
                    .child(spacer())
                    .child(
                        pro
                            ? el().px(8).py(3).rounded(8).bg(ShowreelKit.ca(0x54b3fd, 0.16)).child(ShowreelKit.t("Popular", 11.5, 600, 0x8fd0ff))
                            : el()
                    )
            )
            .child(
                row().mt(6).itemsEnd().gap(4)
                    .child(ShowreelKit.t(price, 40, 600, ShowreelKit.TEXT))
                    .child(ShowreelKit.t("/mo", 14, 500, ShowreelKit.MUTED).mb(8))
            )
            .child(ShowreelKit.t(blurb, 13, 400, ShowreelKit.MUTED).mb(10))

        for (i, f) in feats.enumerated() {
            c = c.child(pricingFeature(f, on: pro || i < 2))
        }
        return c.child(spacer()).child(
            row().wFull().h(40).rounded(11).center().scale(1.0 - 0.06 * press)
                .bg(pro ? ShowreelKit.c(0xeef4ff) : ShowreelKit.ca(0xffffff, 0.07))
                .child(ShowreelKit.t(cta, 14, 600, pro ? 0x0e1320 : ShowreelKit.TEXT))
        )
    }

    static func pricingView(_ s: ShowreelState) -> El<ShowreelState> {
        let hoverT = 0.55
        let tap = 1.25
        let t = s.t
        let hover = ShowreelKit.ease(t, hoverT, 0.35)
        let hit = ShowreelKit.ease(t, tap, 0.08)
        let press = ShowreelKit.pressed(t, tap)
        let x0 = (ShowreelKit.W - 3.0 * 268.0 - 2.0 * 22.0) / 2.0
        let y0: Float = 176.0
        let px = x0 + 268.0 + 22.0
        let lift = ShowreelKit.track(t, 0.0, [(hoverT, 1.0, ShowreelKit.sp(0.45, 0.3))])

        let header: El<ShowreelState> = col().absolute(x: 0, y: 54).w(ShowreelKit.W).itemsCenter().gap(10)
            .child(ShowreelKit.t("PRICING", 12, 600, 0x54b3fd))
            .child(ShowreelKit.t("Plans that scale with you", 32, 600, ShowreelKit.TEXT))
            .child(ShowreelKit.t("Start free. Upgrade when your team needs more.", 15, 400, ShowreelKit.MUTED))

        let proY = y0 - 8.0 * lift
        return el().w(ShowreelKit.W).h(ShowreelKit.H).bg(ShowreelKit.c(0x0a0a0c))
            .child(header)
            .child(pricingPlan(
                name: "Hobby", price: "$0", blurb: "For side projects and prototypes.",
                feats: ["One project", "Preview deploys", "Community support", "Analytics"],
                cta: "Get started", pro: false, press: 0
            ).absolute(x: x0, y: y0))
            .child(pricingPlan(
                name: "Team", price: "$60", blurb: "For studios shipping together.",
                feats: ["Unlimited projects", "SSO and audit log", "Analytics", "Priority support"],
                cta: "Contact us", pro: false, press: 0
            ).absolute(x: x0 + 2.0 * (268.0 + 22.0), y: y0))
            .child(ShowreelGfx.fxLayerEl(
                key: "pro-glow",
                x: px, y: proY, w: 268, h: 318, radius: 20, bleed: 60,
                fx: ShowreelGfx.glow(style: .neon, colorIndex: 13, intensity: 0.35 + 0.5 * hover + 0.8 * hit, radius: 22),
                t: Float(t)
            ))
            .child(pricingPlan(
                name: "Pro", price: "$20", blurb: "For apps people use every day.",
                feats: ["Unlimited projects", "Custom domains", "Team analytics", "Priority builds"],
                cta: "Upgrade", pro: true, press: press
            ).absolute(x: px, y: proY))
            .child(ShowreelGfx.fxLayerEl(
                key: "pro-electric",
                x: px, y: proY, w: 268, h: 318, radius: 20, bleed: 40,
                fx: ShowreelGfx.electric(
                    intensity: 0.5 + 0.7 * hover + 0.4 * hit,
                    amplitude: t >= tap ? 6.0 : 0.0,
                    charged: t < tap,
                    colorIndex: 13
                ),
                t: Float(t)
            ))
            .child(ShowreelGfx.fxLayerEl(
                key: "pro-sparkles",
                x: px + 24, y: proY + 254, w: 220, h: 40, radius: 11, bleed: 60,
                fx: ShowreelGfx.sparkles(burst: Float(tap + 0.05), count: 14, size: 10, colorIndex: 13),
                t: Float(t)
            ))
            .child(ShowreelKit.pointerAt(
                t,
                start: (960, 560),
                path: [(0.12, px + 180, proY + 140), (0.75, px + 140, y0 + 272)],
                taps: [tap]
            ))
    }

    // MARK: - Ask

    private static func askChip(_ s: String, _ a: Float) -> El<ShowreelState> {
        row().h(32).px(14).rounded(16).center()
            .bg(ShowreelKit.ca(0xffffff, 0.05 * a))
            .border(1, ShowreelKit.ca(0xffffff, 0.08 * a))
            .child(ShowreelKit.ta(s, 13, 500, ShowreelKit.MUTED, a))
    }

    static func askView(_ s: ShowreelState) -> El<ShowreelState> {
        let prompt = "make the settings page feel alive"
        let typeFrom = 0.3
        let typeRate = 30.0
        let sendT = 1.55
        let t = s.t

        let n = min(prompt.count, Int(max(0.0, (t - typeFrom) * typeRate)))
        let sent = t >= sendT
        let press = ShowreelKit.pressed(t, sendT)
        let flare: Float = sent ? 1.6 * Float(exp(-(t - sendT) * 2.2)) : 0.0
        let drop = ShowreelKit.track(t, 0.0, [(sendT + 0.08, 1.0, ShowreelKit.sp(0.6, 0.12))])
        let cw: Float = 640.0
        let ch: Float = 128.0
        let cx0 = (ShowreelKit.W - cw) / 2.0
        let cy0 = 214.0 + (382.0 - 214.0) * drop

        let caretOn = (Int(t * 2.0) % 2 == 0) || n < prompt.count
        let typed = sent ? "" : String(prompt.prefix(n))
        let field: El<ShowreelState> = row().gap(1).itemsCenter()
            .child(
                (typed.isEmpty && !sent && n == 0)
                    ? ShowreelKit.t("Ask anything…", 17, 400, ShowreelKit.FAINT)
                    : ShowreelKit.t(typed, 17, 400, ShowreelKit.TEXT)
            )
            .child(el().w(2).h(22).rounded(1).bg(ShowreelKit.ca(0x9fd4ff, caretOn ? 1.0 : 0.0)))

        let sendBtn: El<ShowreelState> = el().size(36, 36).rounded(18).scale(1.0 - 0.12 * press)
            .bg(n > 0 ? ShowreelKit.c(0xf4f6fb) : ShowreelKit.ca(0xffffff, 0.15))
            .center()
            .child(ShowreelKit.t("↑", 18, 600, 0x0b0b0d))

        let composer: El<ShowreelState> = col().key("composer").absolute(x: cx0, y: cy0).size(cw, ch).p(20).rounded(24)
            .bg(ShowreelKit.c(0x131317)).border(1, ShowreelKit.ca(0xffffff, 0.1))
            .child(field)
            .child(spacer())
            .child(
                row().wFull().itemsCenter().gap(8)
                    .child(row().h(30).px(12).rounded(15).center().gap(6).bg(ShowreelKit.ca(0xffffff, 0.06)).child(ShowreelKit.dot(0x54b3fd, 6)).child(ShowreelKit.t("Build", 12.5, 500, 0xc9c9d0)))
                    .child(row().h(30).px(12).rounded(15).center().bg(ShowreelKit.ca(0xffffff, 0.06)).child(ShowreelKit.t("opus", 12.5, 500, 0xc9c9d0)))
                    .child(spacer())
                    .child(sendBtn)
            )

        let greet = 1.0 - ShowreelKit.ease(t, sendT, 0.25)
        var root: El<ShowreelState> = el().w(ShowreelKit.W).h(ShowreelKit.H).bg(ShowreelKit.c(0x09090b))
            .child(
                col().key("greet").absolute(x: 0, y: 150 - 20 * (1 - greet)).w(ShowreelKit.W).itemsCenter()
                    .child(ShowreelKit.ta("What should we build?", 30, 600, ShowreelKit.TEXT, greet))
            )
            .child(
                row().key("chips").absolute(x: 0, y: 214 + ch + 22).w(ShowreelKit.W).justifyCenter().gap(10)
                    .child(askChip("A springy toggle", greet))
                    .child(askChip("Liquid metal button", greet))
                    .child(askChip("Glass sidebar", greet))
            )
            .child(ShowreelGfx.fxLayerEl(
                key: "aura",
                x: cx0, y: cy0, w: cw, h: ch, radius: 24, bleed: 70,
                fx: ShowreelGfx.glow(style: .aura, colorIndex: 3, intensity: 1.0 + flare, radius: 22),
                t: Float(t)
            ))
            .child(composer)

        if sent {
            let k = ShowreelKit.track(t, 0.0, [(sendT + 0.12, 1.0, ShowreelKit.sp(0.45, 0.25))])
            let a = k.clamped(to: 0...1)
            let bubble: El<ShowreelState> = row().h(42).px(16).rounded(16).center()
                .bg(ShowreelKit.ca(0x1f2633, a))
                .child(ShowreelKit.ta(prompt, 15, 400, 0xe6ecf7, a))
            root = root.child(
                row().key("bubble").absolute(x: 0, y: 58 + 14 * (1 - k)).w(ShowreelKit.W - 160).justifyEnd().child(bubble)
            )

            let r = ShowreelKit.ease(t, sendT + 0.4, 0.3)
            let pulseSize = max(1, 10.0 * r)
            var reply: El<ShowreelState> = col().key("reply").absolute(x: 160, y: 132).w(640).gap(12)
                .child(
                    row().gap(10).itemsCenter()
                        .child(
                            el().size(pulseSize, pulseSize)
                                .child(ShowreelGfx.fxLayerEl(
                                    key: "think-pulse",
                                    x: 0, y: 0, w: 10, h: 10, radius: 5, bleed: 16,
                                    fx: ShowreelGfx.pulse(style: .breathe, colorIndex: 13, period: 1.2, reach: 10),
                                    t: Float(t)
                                ))
                                .child(ShowreelKit.dot(0x54b3fd, 10).absolute(x: 0, y: 0))
                        )
                        .child(ShowreelKit.ta("Thinking", 14, 500, ShowreelKit.MUTED, r))
                )

            for (i, w) in [Float(600), 540, 580, 360].enumerated() {
                let k2 = ShowreelKit.ease(t, sendT + 0.55 + Double(i) * 0.12, 0.25)
                let bw = max(1, w * (0.6 + 0.4 * k2))
                reply = reply.child(
                    el().w(bw).h(12).rounded(6).bg(ShowreelKit.ca(0xffffff, 0.07 * k2))
                        .child(ShowreelGfx.fxLayerEl(
                            key: "reply-shimmer-\(i)",
                            x: 0, y: 0, w: bw, h: 12, radius: 6, bleed: 0,
                            fx: ShowreelGfx.shimmer(intensity: 0.35 * k2, period: 1.3, band: 60),
                            t: Float(t)
                        ))
                )
            }
            root = root.child(reply)
        }

        return root.child(ShowreelKit.pointerAt(
            t,
            start: (760, 470),
            path: [(0.9, cx0 + cw - 38, 214 + ch - 38), (sendT + 0.25, 860, 520)],
            taps: [sendT]
        ))
    }

    // MARK: - Shock

    private static let shockTaps: [(Double, Int, Int)] = [(0.5, 2, 1), (1.1667, 0, 2), (1.8333, 4, 0)]

    static func shockView(_ s: ShowreelState) -> El<ShowreelState> {
        let t = s.t
        let cols = 5
        let rows = 3
        let gx: Float = 28.0
        let gy: Float = 92.0
        let gap: Float = 10.0
        let tw = (ShowreelKit.W - 2.0 * gx - gap * Float(cols - 1)) / Float(cols)
        let th = (ShowreelKit.H - gy - 24.0 - gap * Float(rows - 1)) / Float(rows)

        let seg = ["Years", "Months", "Days", "All Photos"]
        let sel = ShowreelKit.track(t, 3.0, [(0.25, 2.0, ShowreelKit.sp(0.45, 0.25))])
        var segRow: El<ShowreelState> = el().h(34).w(4.0 * 92.0 + 8.0).rounded(10).bg(ShowreelKit.ca(0xffffff, 0.06))
            .child(el().absolute(x: 4.0 + sel * 92.0, y: 4.0).size(92, 26).rounded(7).bg(ShowreelKit.ca(0xffffff, 0.14)))
        for (i, name) in seg.enumerated() {
            let active = abs(sel - Float(i)) < 0.5
            segRow = segRow.child(
                row().absolute(x: 4.0 + Float(i) * 92.0, y: 4.0).size(92, 26).center()
                    .child(ShowreelKit.t(name, 13, 500, active ? ShowreelKit.TEXT : ShowreelKit.MUTED))
            )
        }

        let header: El<ShowreelState> = row().absolute(x: gx, y: 28).w(ShowreelKit.W - 2.0 * gx).itemsCenter()
            .child(col().gap(3).child(ShowreelKit.t("Library", 24, 600, ShowreelKit.TEXT)).child(ShowreelKit.t("1,284 photos · 3 albums", 13, 400, ShowreelKit.MUTED)))
            .child(spacer())
            .child(segRow)

        var tileLayers: [FxLayer] = []
        for r in 0..<rows {
            for cc in 0..<cols {
                let i = r * cols + cc
                let press = shockTaps.filter { $0.1 == cc && $0.2 == r }.map { ShowreelKit.pressed(t, $0.0) }.max() ?? 0.0
                let sc = 1.0 - 0.06 * press
                let w = tw * sc
                let h = th * sc
                let x = gx + Float(cc) * (tw + gap) + (tw - w) * 0.5
                let y = gy + Float(r) * (th + gap) + (th - h) * 0.5
                let shape = FxShape.rounded(x: x, y: y, w: w, h: h, radius: 12)
                tileLayers.append(ShowreelGfx.mesh(palette: i % 8, speed: 0.5, drift: 0.25).on(shape).at(Float(t)).seed(UInt32(i + 1)))
            }
        }

        var root: El<ShowreelState> = el().w(ShowreelKit.W).h(ShowreelKit.H).bg(ShowreelKit.c(0x08080a))
            .child(ShowreelGfx.fxCanvas(key: "shock-tiles", layers: tileLayers))
            .child(header)

        // Subtle ripple rings at tap points during shockwave expansion
        for (tp, cc, r) in shockTaps where t >= tp {
            let elapsed = Float(t - tp)
            if elapsed < 1.1 {
                let p = elapsed / 1.1
                let cx = gx + Float(cc) * (tw + gap) + tw / 2.0
                let cy = gy + Float(r) * (th + gap) + th / 2.0
                let rad = 20.0 + p * 520.0
                root = root.child(
                    el().key("ring-\(cc)-\(r)")
                        .absolute(x: cx - rad, y: cy - rad)
                        .size(rad * 2, rad * 2)
                        .rounded(rad)
                        .border(2.0 * (1.0 - p), ShowreelKit.ca(0xffffff, 0.35 * (1.0 - p)))
                )
            }
        }

        let path = shockTaps.map { tp, cc, r in
            (tp - 0.42, gx + Float(cc) * (tw + gap) + tw / 2.0, gy + Float(r) * (th + gap) + th / 2.0)
        }
        return root.child(ShowreelKit.pointerAt(t, start: (700, 500), path: path, taps: shockTaps.map(\.0)))
    }
}
