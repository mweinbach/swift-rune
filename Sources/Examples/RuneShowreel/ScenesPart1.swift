import Foundation
import Rune
import RuneFX
import RuneMotion

enum ShowreelScenesPart1 {
    // MARK: - Word & Card

    private static let glyphs = [
        "###....|####...|##.##..|##..##.|##..##.|##.##..|####...|##.##..|##..##.|##...##|##...##",
        "##...##|##...##|##...##|##...##|##...##|##...##|##...##|##...##|##...##|#######|.#####.",
        "###...##|####..##|####..##|####..##|##.##.##|##.##.##|##.##.##|##..####|##..####|##..####|##...###",
        "######|######|##....|##....|#####.|#####.|##....|##....|##....|######|######",
    ]

    private static func ink(_ rows: [Substring], dx: Int) -> [(Int, Int)] {
        var v: [(Int, Int)] = []
        for (y, r) in rows.enumerated() {
            for (x, ch) in r.enumerated() where ch == "#" {
                v.append((x + dx, y))
            }
        }
        return v
    }

    private static let wordCells: (cells: [(Int, Int, Int)], width: Int) = {
        var out: [(Int, Int, Int)] = []
        var at = 0
        var width = 0
        var prev: [(Int, Int)]? = nil
        for (g, glyph) in glyphs.enumerated() {
            let rows = glyph.split(separator: "|")
            let b = ink(rows, dx: 0)
            if let a = prev {
                var x = at + 1
                while a.contains(where: { ax, ay in b.contains(where: { bx, by in abs(bx + x - ax) <= 1 && abs(by - ay) <= 1 }) }) {
                    x += 1
                }
                at = x
            }
            let placed = ink(rows, dx: at)
            out.append(contentsOf: placed.map { ($0.0, $0.1, g) })
            width = at + (rows.first?.count ?? 0)
            prev = placed
        }
        return (out, width)
    }()

    static func wordView(_ s: ShowreelState, card: Bool) -> El<ShowreelState> {
        let t = s.t
        let (cells, width) = wordCells
        let cell: Float = card ? 19.0 : 25.0
        let tile = cell - 1.0
        let totalW = Float(width) * cell
        let totalH: Float = 11.0 * cell
        let zoom: Float = card ? 1.0 : 1.0 + 0.05 * ShowreelKit.ease(t, 0.0, 4.0)
        let ox = (ShowreelKit.W - totalW * zoom) / 2.0
        let oy = card ? 168.0 : (ShowreelKit.H - totalH * zoom) / 2.0

        let chromeFx = ShowreelGfx.chrome(variant: 4, border: 0, flowMul: 1.25, anchorElement: false)
        var layers: [FxLayer] = []
        layers.reserveCapacity(cells.count)
        for (x, y, g) in cells {
            let delay = 0.08 + Double(g) * 0.11 + Double(x) * 0.012 + Double(y) * 0.018
            let k = ShowreelKit.track(t, 0.0, [(delay, 1.0, ShowreelKit.sp(0.55, 0.38))])
            let size = tile * zoom * max(k, 0.0)
            let cx = ox + (Float(x) + 0.5) * cell * zoom
            let cy = oy + (Float(y) + 0.5) * cell * zoom
            if size < 0.5 { continue }
            let shape = FxShape.rounded(
                x: cx - size / 2.0,
                y: cy - size / 2.0,
                w: size,
                h: size,
                radius: 2.5 * zoom * k
            )
            layers.append(chromeFx.on(shape).at(Float(t)))
        }

        var root: El<ShowreelState> = el()
            .w(ShowreelKit.W)
            .h(ShowreelKit.H)
            .bg(ShowreelKit.c(0x000000))
            .child(ShowreelGfx.fxCanvas(key: "word-fx", layers: layers))

        if card {
            let a = ShowreelKit.ease(t, 0.9, 0.6)
            root = root.child(
                el()
                    .absolute(x: 0, y: oy + totalH + 46.0 - 8.0 * a)
                    .w(ShowreelKit.W)
                    .center()
                    .child(ShowreelKit.monoA("github.com/anomalyco/rune", 22.0, 0xb8bcc6, a))
            )
        }
        return root
    }

    // MARK: - Deploy

    private static let deployRows: [(String, String, String, String, UInt32)] = [
        ("overlay: motion started while hidden plays on show", "f6d096b", "38s", "12m", 0x7c5cff),
        ("text: a span keeps the paragraph's leading ratio", "4112cac", "41s", "1h", 0xff7a1a),
        ("text: snap the pen to 1/256 px before flooring", "bac9e90", "40s", "2h", 0x34d399),
        ("rune-mermaid: hover settings keep their style", "c83aa06", "44s", "3h", 0x54b3fd),
        ("fx: frosted glass reads a blurred backdrop", "9e1d4b2", "39s", "5h", 0xff5ca8),
    ]

    private static func deployStatus(_ label: String, color: UInt32, pulseColor: Int?, t: Double) -> El<ShowreelState> {
        var d: El<ShowreelState> = el().size(8, 8)
        if let p = pulseColor {
            d = d.child(
                ShowreelGfx.fxLayerEl(
                    key: "pulse-\(label)",
                    x: 0, y: 0, w: 8, h: 8, radius: 4, bleed: 14,
                    fx: ShowreelGfx.pulse(style: .breathe, colorIndex: p, period: 1.2, reach: 9.0),
                    t: Float(t)
                )
            )
        }
        d = d.child(ShowreelKit.dot(color, 8).absolute(x: 0, y: 0))
        return row().w(118).gap(9).itemsCenter().child(d).child(ShowreelKit.t(label, 13, 500, ShowreelKit.TEXT))
    }

    private static func deployListRow(
        _ msg: String,
        _ sha: String,
        _ dur: String,
        _ ago: String,
        _ who: UInt32,
        _ st: El<ShowreelState>,
        extra: El<ShowreelState>? = nil
    ) -> El<ShowreelState> {
        var info: El<ShowreelState> = col().gap(5)
            .child(ShowreelKit.t(msg, 13.5, 500, ShowreelKit.TEXT))
            .child(
                row().gap(8).itemsCenter()
                    .child(el().px(6).py(1).rounded(5).bg(ShowreelKit.ca(0xffffff, 0.06)).child(ShowreelKit.mono("dev", 11, ShowreelKit.MUTED)))
                    .child(ShowreelKit.mono(sha, 11, ShowreelKit.FAINT))
            )
        if let extra { info = info.child(extra) }
        return row()
            .key("row-\(sha)")
            .wFull()
            .h(62)
            .px(20)
            .itemsCenter()
            .child(st)
            .child(info.grow(1))
            .child(ShowreelKit.t(dur, 13, 400, ShowreelKit.MUTED).w(60))
            .child(ShowreelKit.t(ago, 13, 400, ShowreelKit.MUTED).w(54))
            .child(ShowreelKit.avatar("", who, 22))
    }

    static func deployView(_ s: ShowreelState) -> El<ShowreelState> {
        let tap = 0.7
        let confirm = 1.6
        let dismiss = 2.3
        let insert = 2.4
        let readyT = 3.4
        let t = s.t

        let hover = ShowreelKit.track(t, 0.0, [(0.5, 1.0, ShowreelKit.sp(0.35, 0.3))])
        let press = ShowreelKit.pressed(t, tap)
        let scale = 1.0 + 0.05 * hover - 0.08 * press
        let flow: Float = 1.0 + 1.2 * (t > tap ? Float(exp(-(t - tap) * 1.5)) : 0.0)

        let button: El<ShowreelState> = el()
            .key("deploy")
            .size(132, 40)
            .rounded(20)
            .scale(scale)
            .child(ShowreelGfx.fxLayerEl(
                key: "deploy-glow",
                x: 0, y: 0, w: 132, h: 40, radius: 20, bleed: 40,
                fx: ShowreelGfx.glow(style: .soft, colorIndex: 0, intensity: 0.22 * hover, radius: 12),
                t: Float(t)
            ))
            .child(ShowreelGfx.fxLayerEl(
                key: "deploy-chrome",
                x: 0, y: 0, w: 132, h: 40, radius: 20, bleed: 0,
                fx: ShowreelGfx.chrome(variant: 5, border: 0, flowMul: flow, anchorElement: false),
                t: Float(t)
            ))
            .child(row().absolute(x: 0, y: 0).size(132, 40).center().child(ShowreelKit.t("Deploy", 15, 600, 0x0e0f12)))

        let logo: El<ShowreelState> = el()
            .size(26, 26)
            .rounded(7)
            .linearGradient(top: ShowreelKit.c(0x54b3fd), bottom: ShowreelKit.c(0x3d6bff), angleRadians: 2.3)

        let top: El<ShowreelState> = row()
            .wFull()
            .h(64)
            .px(24)
            .itemsCenter()
            .gap(12)
            .child(logo)
            .child(ShowreelKit.t("anomaly", 14, 500, ShowreelKit.MUTED))
            .child(ShowreelKit.t("/", 14, 400, ShowreelKit.FAINT))
            .child(ShowreelKit.t("rune", 14, 600, ShowreelKit.TEXT))
            .child(
                row().ml(6).px(10).py(4).gap(6).rounded(10).itemsCenter().bg(ShowreelKit.ca(0x34d399, 0.12))
                    .child(ShowreelKit.dot(0x34d399, 6))
                    .child(ShowreelKit.t("Production", 12, 500, 0x6ee7b7))
            )
            .child(spacer())
            .child(
                row()
                    .child(ShowreelKit.avatar("", 0xff7a1a, 26).border(2, ShowreelKit.c(ShowreelKit.BG)))
                    .child(ShowreelKit.avatar("", 0x7c5cff, 26).border(2, ShowreelKit.c(ShowreelKit.BG)).ml(-7))
                    .child(ShowreelKit.avatar("", 0x34d399, 26).border(2, ShowreelKit.c(ShowreelKit.BG)).ml(-7))
            )
            .child(el().w(10))
            .child(button)

        let tabs = ["Overview", "Deployments", "Analytics", "Logs", "Storage", "Settings"]
        var tabRow: El<ShowreelState> = row().wFull().h(42).px(24).gap(26).itemsCenter()
        for (i, name) in tabs.enumerated() {
            let on = i == 1
            tabRow = tabRow.child(
                col().h(42).justifyCenter()
                    .child(ShowreelKit.t(name, 13.5, on ? 600 : 450, on ? ShowreelKit.TEXT : ShowreelKit.MUTED))
                    .child(el().absolute(x: 0, y: 40).h(2).wFull().bg(on ? ShowreelKit.c(ShowreelKit.TEXT) : ShowreelKit.ca(0, 0)))
            )
        }

        let grow = ShowreelKit.track(t, 0.0, [(insert, 1.0, ShowreelKit.sp(0.5, 0.18))])
        let isReady = t >= readyT
        var list: El<ShowreelState> = col().wFull().rounded(14).bg(ShowreelKit.c(ShowreelKit.PANEL)).border(1, ShowreelKit.hair()).clip(true)

        if grow > 0.001 {
            let progress = ShowreelKit.ease(t, insert + 0.1, readyT - insert - 0.15)
            let fade = 1.0 - ShowreelKit.ease(t, readyT, 0.3)
            let barW = max(1, 260.0 * progress)
            let bar: El<ShowreelState> = el().mt(4).w(260).h(3).rounded(2).bg(ShowreelKit.ca(0xffffff, 0.08 * fade))
                .child(
                    el().absolute(x: 0, y: 0).h(3).w(barW).rounded(2).bg(ShowreelKit.ca(0xffb547, fade))
                        .child(ShowreelGfx.fxLayerEl(
                            key: "bar-shimmer",
                            x: 0, y: 0, w: barW, h: 3, radius: 2, bleed: 0,
                            fx: ShowreelGfx.shimmer(intensity: 0.5 * fade, period: 0.9, band: 40),
                            t: Float(t)
                        ))
                )
            let st = isReady
                ? deployStatus("Ready", color: 0x34d399, pulseColor: 4, t: t)
                : deployStatus("Building", color: 0xffb547, pulseColor: 5, t: t)
            let fresh = deployListRow(
                "README: a 30 second showcase, cut from real renders",
                "ba5b054",
                isReady ? "1m 39s" : "…",
                "now",
                0x54b3fd,
                st,
                extra: bar
            )
            list = list.child(
                el().key("fresh").wFull().h(62.0 * grow + 9.0 * grow).clip(true).child(
                    el().absolute(x: 0, y: -62.0 * (1.0 - grow)).wFull()
                        .bg(ShowreelKit.ca(0xffffff, 0.025 + 0.03 * (1.0 - ShowreelKit.ease(t, readyT, 0.8))))
                        .child(fresh)
                )
            )
        }

        for (i, r) in deployRows.enumerated() {
            if i > 0 || grow > 0.001 {
                list = list.child(el().wFull().h(1).bg(ShowreelKit.hair()))
            }
            list = list.child(deployListRow(r.0, r.1, r.2, r.3, r.4, deployStatus("Ready", color: 0x34d399, pulseColor: nil, t: t)))
        }

        var root: El<ShowreelState> = col()
            .w(ShowreelKit.W)
            .h(ShowreelKit.H)
            .bg(ShowreelKit.c(ShowreelKit.BG))
            .child(top)
            .child(tabRow)
            .child(el().wFull().h(1).bg(ShowreelKit.hair()))
            .child(el().p(24).child(list))

        // Confirm dialog between TAP and DISMISS
        let sheetK = ShowreelKit.track(t, 0.0, [
            (tap + 0.08, 1.0, ShowreelKit.sp(0.42, 0.25)),
            (dismiss, 0.0, ShowreelKit.sp(0.32, 0.0)),
        ])
        if sheetK > 0.01 {
            let confirmPress = ShowreelKit.pressed(t, confirm)
            let sheet: El<ShowreelState> = col()
                .key("confirm-sheet")
                .absolute(x: (ShowreelKit.W - 360) / 2.0, y: 170 + 18 * (1 - sheetK))
                .w(360)
                .p(22)
                .gap(12)
                .rounded(16)
                .bg(ShowreelKit.c(ShowreelKit.RAISED))
                .border(1, ShowreelKit.ca(0xffffff, 0.12))
                .shadow(Shadow(y: 16, blur: 40, color: ShowreelKit.ca(0x000000, 0.6)))
                .opacity(sheetK.clamped(to: 0...1))
                .scale(0.94 + 0.06 * sheetK)
                .child(ShowreelKit.t("Deploy to Production?", 16, 600, ShowreelKit.TEXT))
                .child(ShowreelKit.t("This will promote ba5b054 to anomaly.co/rune.", 13, 400, ShowreelKit.MUTED))
                .child(
                    row().wFull().gap(10).mt(4)
                        .child(spacer())
                        .child(row().h(34).px(14).rounded(9).center().bg(ShowreelKit.ca(0xffffff, 0.06)).child(ShowreelKit.t("Cancel", 13, 500, ShowreelKit.MUTED)))
                        .child(
                            row().h(34).px(16).rounded(9).center().scale(1.0 - 0.07 * confirmPress).bg(ShowreelKit.c(0xf4f6fb))
                                .child(ShowreelKit.t("Confirm", 13, 600, 0x0e0f12))
                        )
                )
            root = root.child(sheet)
        }

        if isReady {
            root = root.child(ShowreelGfx.fxLayerEl(
                key: "deploy-sparkles",
                x: 804, y: 12, w: 132, h: 40, radius: 20, bleed: 60,
                fx: ShowreelGfx.sparkles(burst: Float(readyT), count: 16, size: 10, colorIndex: 4),
                t: Float(t)
            ))
        }

        root = root.child(ShowreelKit.pointerAt(
            t,
            start: (640, 220),
            path: [(0.15, 868, 32), (1.15, 585, 286), (2.5, 760, 440)],
            taps: [tap, confirm]
        ))
        return root
    }

    // MARK: - Glass

    private static let queueTracks: [(String, String, String, Int)] = [
        ("Low Light", "Kaito Hayes", "3:41", 7),
        ("Glass Hours", "Mira Sol", "4:02", 1),
        ("Afterimage", "Sunday Static", "2:57", 5),
        ("Paper Moons", "Kaito Hayes", "3:18", 4),
        ("Slow Signal", "Ode Park", "5:06", 6),
    ]

    static func glassView(_ s: ShowreelState) -> El<ShowreelState> {
        let t = s.t
        var root: El<ShowreelState> = el().w(ShowreelKit.W).h(ShowreelKit.H).bg(ShowreelKit.c(0x120a1e))
            .child(ShowreelGfx.fxCanvas(
                key: "glass-bg",
                layers: [ShowreelGfx.mesh(palette: 7, speed: 0.55, drift: 0.22).on(FxShape.rounded(x: 0, y: 0, w: ShowreelKit.W, h: ShowreelKit.H, radius: 0)).at(Float(t)).seed(3)]
            ))

        var wave: El<ShowreelState> = row().absolute(x: 40, y: 400).w(ShowreelKit.W - 40).h(80).gap(4).itemsEnd()
        for i in 0..<112 {
            let x = Float(i)
            let h = 10.0 + 34.0 * (0.5 + 0.5 * sin(x * 0.37 + Float(t) * 5.1)) * (0.55 + 0.45 * abs(sin(x * 0.11 - Float(t) * 2.3)))
            wave = wave.child(el().w(4).h(h).rounded(2).bg(ShowreelKit.ca(0xffffff, x < 44.0 ? 0.85 : 0.5)))
        }
        root = root.child(wave)

        let title: El<ShowreelState> = col().absolute(x: 48, y: 120).gap(6)
            .child(ShowreelKit.ta("NOW PLAYING", 12, 600, 0xffffff, 0.75))
            .child(ShowreelKit.t("Night Drive", 128, 600, 0xffffff))
            .child(ShowreelKit.ta("Kaito Hayes · Low Light Sessions", 20, 500, 0xffffff, 0.8))
        root = root.child(title)

        let progress = (0.38 + 0.02 * Float(t)).clamped(to: 0...1)
        root = root.child(
            row().absolute(x: 48, y: 496).w(470).gap(12).itemsCenter()
                .child(ShowreelKit.mono("1:42", 12, 0xffffff))
                .child(
                    el().w(380).h(4).rounded(2).bg(ShowreelKit.ca(0xffffff, 0.25))
                        .child(el().absolute(x: 0, y: 0).h(4).w(380 * progress).rounded(2).bg(ShowreelKit.c(0xffffff)))
                )
                .child(ShowreelKit.mono("3:58", 12, 0xffffff))
        )

        let x = ShowreelKit.track(t, ShowreelKit.W + 10.0, [(0.35, 548.0, ShowreelKit.sp(0.95, 0.12))])
        let gw = ShowreelKit.W - 548.0
        var queue: El<ShowreelState> = col().absolute(x: x, y: 0).w(gw).h(ShowreelKit.H).pt(54).px(34).gap(4)
        let head = ShowreelKit.ease(t, 0.95, 0.4)
        queue = queue.child(
            row().wFull().mb(14).offset(0, 10 * (1 - head))
                .child(ShowreelKit.ta("Up next", 22, 600, 0xffffff, head))
                .child(spacer())
                .child(ShowreelKit.ta("Shuffle", 13, 500, 0xffffff, 0.7 * head))
        )

        for (i, item) in queueTracks.enumerated() {
            let k = ShowreelKit.track(t, 0.0, [(1.05 + Double(i) * 0.07, 1.0, ShowreelKit.sp(0.5, 0.2))])
            let thumbSize = max(1, 48.0 * k.clamped(to: 0...1))
            queue = queue.child(
                row().wFull().h(68).gap(14).itemsCenter().offset(24 * (1 - k), 0)
                    .child(ShowreelGfx.fxLayerEl(
                        key: "q-thumb-\(i)",
                        x: 0, y: 0, w: thumbSize, h: thumbSize, radius: 10, bleed: 0,
                        fx: ShowreelGfx.mesh(palette: item.3, speed: 0.4),
                        t: Float(t),
                        seed: UInt32(i + 5)
                    ).size(thumbSize, thumbSize))
                    .child(
                        col().gap(4).grow(1)
                            .child(ShowreelKit.ta(item.0, 15, 600, 0xffffff, k))
                            .child(ShowreelKit.ta(item.1, 13, 400, 0xffffff, 0.7 * k))
                    )
                    .child(ShowreelKit.monoA(item.2, 12, 0xffffff, 0.8 * k))
            )
        }

        return root
            .child(
                el().absolute(x: x, y: 0).size(gw + 10, ShowreelKit.H)
                    .backdropBlur(18)
                    .bg(ShowreelKit.ca(0x1b1230, 0.42))
            )
            .child(el().absolute(x: x, y: 0).w(1).h(ShowreelKit.H).bg(ShowreelKit.ca(0xffffff, 0.35)))
            .child(queue)
    }

    // MARK: - Fire

    private static func fireChannel(_ name: String, on: Bool) -> El<ShowreelState> {
        row().wFull().h(30).px(12).rounded(8).itemsCenter().gap(8)
            .bg(on ? ShowreelKit.ca(0xffffff, 0.07) : ShowreelKit.ca(0, 0))
            .child(ShowreelKit.t("#", 14, 500, ShowreelKit.FAINT))
            .child(ShowreelKit.t(name, 13.5, on ? 600 : 450, on ? ShowreelKit.TEXT : ShowreelKit.MUTED))
    }

    private static func fireMsg(_ who: UInt32, _ name: String, _ time: String, _ body: String) -> El<ShowreelState> {
        row().wFull().gap(12)
            .child(ShowreelKit.avatar("", who, 30))
            .child(
                col().gap(4)
                    .child(row().gap(8).itemsCenter().child(ShowreelKit.t(name, 13.5, 600, ShowreelKit.TEXT)).child(ShowreelKit.t(time, 12, 400, ShowreelKit.FAINT)))
                    .child(ShowreelKit.t(body, 13.5, 400, 0xc9c9d0))
            )
    }

    static func fireView(_ s: ShowreelState) -> El<ShowreelState> {
        let tap = 0.95
        let t = s.t
        let press = ShowreelKit.pressed(t, tap)
        let blaze = ShowreelKit.ease(t, tap, 0.5)
        let flame: Float = 0.18 + 1.25 * blaze

        var side: El<ShowreelState> = col().w(220).h(ShowreelKit.H).px(12).pt(22).gap(2).bg(ShowreelKit.c(0x101013)).border(1, ShowreelKit.hair())
        side = side.child(
            row().px(12).pb(16).gap(10).itemsCenter()
                .child(el().size(22, 22).rounded(6).bg(ShowreelKit.c(0xff7a1a)))
                .child(ShowreelKit.t("Anomaly", 14, 600, ShowreelKit.TEXT))
        )
        for (i, ch) in ["general", "releases", "incidents", "design", "random"].enumerated() {
            side = side.child(fireChannel(ch, on: i == 1))
        }

        let cx0 = 220.0 + (ShowreelKit.W - 220.0 - 460.0) / 2.0
        let cy0: Float = 250.0
        let card: El<ShowreelState> = col()
            .absolute(x: cx0, y: cy0)
            .w(460)
            .h(220)
            .p(24)
            .gap(10)
            .rounded(18)
            .bg(ShowreelKit.c(0x1c1b1f))
            .border(1, ShowreelKit.ca(0xffffff, 0.09))
            .shadow(Shadow(y: 18, blur: 40, color: ShowreelKit.ca(0x000000, 0.5)))
            .child(row().gap(10).itemsCenter().child(ShowreelKit.t("Release", 12, 600, 0xff9a5a)).child(spacer()).child(ShowreelKit.mono("v2.0.0", 12, ShowreelKit.MUTED)))
            .child(ShowreelKit.t("Ship v2.0 to production", 22, 600, ShowreelKit.TEXT))
            .child(ShowreelKit.t("Friday · 4:58 PM · 214 files changed", 13.5, 400, ShowreelKit.MUTED))
            .child(spacer())
            .child(
                row().wFull().gap(10)
                    .child(spacer())
                    .child(row().h(38).px(18).rounded(10).center().bg(ShowreelKit.ca(0xffffff, 0.06)).child(ShowreelKit.t("Not today", 13.5, 500, ShowreelKit.MUTED)))
                    .child(
                        row().h(38).px(20).rounded(10).center().scale(1.0 - 0.07 * press).bg(ShowreelKit.c(0xff5a1f))
                            .child(ShowreelKit.t(t >= tap ? "Shipping…" : "Ship it", 13.5, 600, 0xffffff))
                    )
            )

        let thread: El<ShowreelState> = col().absolute(x: 260, y: 40).w(ShowreelKit.W - 300).gap(18)
            .child(fireMsg(0x7c5cff, "mira", "4:51 PM", "all green on dev, release notes are in"))
            .child(fireMsg(0x34d399, "kai", "4:55 PM", "it's friday. it's 4:55. are we sure"))
            .child(fireMsg(0xff7a1a, "ode", "4:57 PM", "rune renders it at 120 Hz, what could go wrong"))

        return el().w(ShowreelKit.W).h(ShowreelKit.H).bg(ShowreelKit.c(ShowreelKit.BG))
            .child(side.absolute(x: 0, y: 0))
            .child(thread)
            .child(ShowreelGfx.fxLayerEl(
                key: "fire-glow",
                x: cx0, y: cy0, w: 460, h: 220, radius: 18, bleed: 80,
                fx: ShowreelGfx.glow(style: .soft, colorIndex: 8, intensity: 0.25 + 0.9 * blaze, radius: 30),
                t: Float(t)
            ))
            .child(ShowreelGfx.fxLayerEl(
                key: "fire-flames",
                x: cx0, y: cy0, w: 460, h: 220, radius: 18, bleed: 200,
                fx: ShowreelGfx.fire(height: 64 + 70 * blaze, intensity: flame, style: .top, smoke: 0.6),
                t: Float(t)
            ))
            .child(card)
            .child(ShowreelKit.pointerAt(t, start: (700, 520), path: [(0.25, cx0 + 400, cy0 + 182)], taps: [tap]))
    }
}
