import Foundation
import Rune
import RuneFX
import RuneMotion

enum ShowreelScenesPart3 {
    // MARK: - Keys

    private static let eighth: Double = 60.0 / 90.0 / 2.0
    private static let padKeys: [(Int, String)] = [
        (10, "A"), (9, "B"), (9, "C"), (9, "D"), (10, "E"), (12, "F"), (99, "G"), (10, "H"),
        (11, "KICK"), (10, "I"), (9, "J"), (10, "K"), (12, "SNR"), (9, "L"), (99, "M"), (11, "FX"),
    ]
    private static let padLight: [Int] = [0, 9, 9, 9, 0, 12, 0, 0, 11, 0, 9, 0, 12, 9, 0, 11]

    private static func hits(_ n: Int) -> [Int] {
        var v: [Int] = []
        let m = ((n % 16) + 16) % 16
        if [0, 3, 5, 8, 11, 13].contains(m) { v.append(8) }
        if m % 4 == 2 { v.append(12) }
        v.append(m % 2 == 0 ? 2 : 1)
        if m == 7 || m == 15 { v.append(6) }
        if m == 14 { v.append(14) }
        if m == 10 { v.append(5) }
        if m == 6 { v.append(13) }
        return v
    }

    private static func pressOf(_ t: Double, key: Int) -> Float {
        let now = Int(floor(t / eighth))
        var p: Float = 0.0
        for n in (now - 3)...now where n >= 0 {
            if hits(n).contains(key) {
                p = max(p, ShowreelKit.pressed(t, Double(n) * eighth))
            }
        }
        return p
    }

    static func keysView(_ s: ShowreelState) -> El<ShowreelState> {
        let t = s.t
        let bw: Float = 864.0
        let bh: Float = 384.0
        let bx = (ShowreelKit.W - bw) / 2.0
        let by = (ShowreelKit.H - bh) / 2.0 + 4.0
        let keySize: Float = 86.0
        let gap: Float = 12.0
        let kx0 = bx + (bw - 8.0 * keySize - 7.0 * gap) / 2.0
        let ky0 = by + 152.0

        let bar = 12 + Int(t / (eighth * 8.0))
        let display: El<ShowreelState> = col()
            .absolute(x: kx0, y: by + 38)
            .w(230).h(70).px(16)
            .justifyCenter().gap(4).rounded(12)
            .bg(ShowreelKit.c(0x050506)).border(1, ShowreelKit.ca(0xffffff, 0.05))
            .child(
                row().gap(8).itemsEnd()
                    .child(ShowreelKit.mono("90", 30, 0x5df2a8))
                    .child(ShowreelKit.mono("BPM", 13, 0x5df2a8).mb(5))
            )
            .child(ShowreelKit.mono("pattern A · bar \(bar)", 11, 0x3c9b6c))

        var root: El<ShowreelState> = el()
            .w(ShowreelKit.W).h(ShowreelKit.H)
            .linearGradient(top: ShowreelKit.c(0x17161a), bottom: ShowreelKit.c(0x0a0a0b), angleRadians: 1.57)
            .child(
                el().absolute(x: bx, y: by).size(bw, bh).rounded(30)
                    .linearGradient(top: ShowreelKit.c(0x232227), bottom: ShowreelKit.c(0x161619), angleRadians: 1.57)
                    .border(1, ShowreelKit.ca(0xffffff, 0.08))
                    .shadow(Shadow(y: 30, blur: 60, color: ShowreelKit.ca(0x000000, 0.6)))
            )
            .child(display)
            .child(
                col().absolute(x: bx + bw - (kx0 - bx) - 120, y: by + 44).w(120).itemsEnd().gap(8)
                    .child(ShowreelKit.t("PAD-16", 13, 600, 0x8a8a93))
                    .child(row().gap(6).itemsCenter().child(ShowreelKit.dot(0xff5a4d, 7)).child(ShowreelKit.t("REC", 12, 600, 0xff5a4d)))
            )

        var fxLayers: [FxLayer] = []
        var knobDots: [(Float, Float)] = []
        for i in 0..<4 {
            let kx = kx0 + 280.0 + Float(i) * 70.0
            let ky = by + 46.0
            let ang = sin(Float(t) * 0.9 + Float(i) * 1.3) * 2.2 - 1.5708
            let dx = cos(ang) * 16.0
            let dy = sin(ang) * 16.0
            fxLayers.append(
                ShowreelGfx.plastic(colorIndex: 10, roughness: 0.35, dome: 0.7, bevel: 10)
                    .on(FxShape.rounded(x: kx, y: ky, w: 54, h: 54, radius: 27))
                    .at(Float(t))
            )
            knobDots.append((kx + 27.0 + dx - 3.0, ky + 27.0 + dy - 3.0))
        }

        var keyLabels: [(Float, Float, String, UInt32)] = []
        for (i, item) in padKeys.enumerated() {
            let (colIdx, label) = item
            let cx = Float(i % 8)
            let cy = Float(i / 8)
            let p = pressOf(t, key: i)
            let x = kx0 + cx * (keySize + gap)
            let y = ky0 + cy * (keySize + gap) + 3.0 * p
            let size = keySize * (1.0 - 0.04 * p)
            let off = (keySize - size) / 2.0
            let dark = (colIdx == 10 || colIdx == 99)

            root = root.child(
                el().absolute(x: x, y: ky0 + cy * (keySize + gap) + 5.0).size(keySize, keySize).rounded(14)
                    .bg(ShowreelKit.ca(0x000000, 0.45))
            )

            let faceShape = FxShape.rounded(x: x + off, y: y + off, w: size, h: size, radius: 14)
            if p > 0.01 {
                fxLayers.append(
                    ShowreelGfx.glow(style: .soft, colorIndex: padLight[i], intensity: 1.4 * p, radius: 16)
                        .on(faceShape).at(Float(t))
                )
            }
            let faceFx = colIdx == 99
                ? ShowreelGfx.chrome(variant: 0, border: 0, flowMul: 1.4, anchorElement: true)
                : ShowreelGfx.plastic(colorIndex: colIdx, roughness: 0.22, dome: 0.35, bevel: 7)
            fxLayers.append(faceFx.on(faceShape).at(Float(t)))
            keyLabels.append((x + off + 10.0, y + off + 8.0, label, (dark && colIdx != 99) ? 0xb9b9c2 : 0x2a2a2e))
        }

        root = root.child(ShowreelGfx.fxCanvas(key: "keys-fx", layers: fxLayers))
        for (dx, dy) in knobDots {
            root = root.child(ShowreelKit.dot(0xf1ece1, 6).absolute(x: dx, y: dy))
        }
        for (lx, ly, label, color) in keyLabels {
            root = root.child(el().absolute(x: lx, y: ly).child(ShowreelKit.ta(label, 11.5, 600, color, 0.85)))
        }
        return root
    }

    // MARK: - Tabs

    private static let stories: [(String, String, Int)] = [
        ("Kyoto after rain", "Photo essay · 12 min", 1),
        ("The quiet studio", "Design · 6 min", 7),
        ("Night markets", "Travel · 9 min", 5),
        ("Ferry to Naoshima", "Photo essay · 8 min", 4),
        ("Paper and light", "Craft · 5 min", 2),
        ("Cold coast", "Travel · 11 min", 6),
    ]

    private static func storyCard(_ title: String, _ meta: String, _ pal: Int, _ w: Float, _ h: Float, _ seed: UInt32, _ t: Double) -> El<ShowreelState> {
        col().w(w).gap(10)
            .child(ShowreelGfx.fxLayerEl(
                key: "story-\(title)",
                x: 0, y: 0, w: w, h: h, radius: 18, bleed: 0,
                fx: ShowreelGfx.mesh(palette: pal, speed: 0.5, drift: 0.25),
                t: Float(t),
                seed: seed
            ).size(w, h))
            .child(ShowreelKit.t(title, 17, 600, ShowreelKit.TEXT))
            .child(ShowreelKit.t(meta, 13, 400, ShowreelKit.MUTED))
    }

    static func tabsView(_ s: ShowreelState) -> El<ShowreelState> {
        let t = s.t
        let scroll = 50.0 * Float(t) + ShowreelKit.track(t, 0.0, [(0.9, 260.0, ShowreelKit.sp(1.1, 0.0))])
        var feed: El<ShowreelState> = col().absolute(x: 40, y: 30 - scroll).w(ShowreelKit.W - 80).gap(28)
            .child(col().gap(4).child(ShowreelKit.t("Today", 30, 600, ShowreelKit.TEXT)).child(ShowreelKit.t("Friday, November 6", 14, 500, ShowreelKit.MUTED)))
            .child(storyCard("Glass, light and the long weekend", "Featured · 14 min", 0, ShowreelKit.W - 80, 300, 1, t))

        let cardW = (ShowreelKit.W - 80.0 - 40.0) / 3.0
        for rowIdx in stride(from: 0, to: stories.count, by: 3) {
            var r: El<ShowreelState> = row().gap(20)
            for i in rowIdx..<min(rowIdx + 3, stories.count) {
                let item = stories[i]
                r = r.child(storyCard(item.0, item.1, item.2, cardW, 180, UInt32(10 + i + item.2), t))
            }
            feed = feed.child(r)
        }

        let bw: Float = 400.0
        let bh: Float = 64.0
        let bx = (ShowreelKit.W - bw) / 2.0
        let by = ShowreelKit.H - bh - 26.0
        let tabs = ["Today", "Search", "Saved", "Profile"]
        let slot = bw / 4.0
        let sel = ShowreelKit.track(t, 0.0, [(0.55, 2.0, ShowreelKit.sp(0.7, 0.28)), (1.75, 1.0, ShowreelKit.sp(0.6, 0.3))])
        let sx = bx + slot * sel + 6.0

        var root: El<ShowreelState> = el().w(ShowreelKit.W).h(ShowreelKit.H).bg(ShowreelKit.c(0x0b0b0d))
            .child(feed)
            .child(
                el().absolute(x: bx, y: by).size(bw, bh).rounded(bh / 2.0)
                    .backdropBlur(18)
                    .bg(ShowreelKit.ca(0x1b1b20, 0.65))
                    .border(1, ShowreelKit.ca(0xffffff, 0.16))
            )
            .child(
                el().absolute(x: sx, y: by + 6).size(slot - 12, bh - 12).rounded((bh - 12) / 2.0)
                    .bg(ShowreelKit.ca(0xffffff, 0.16))
                    .border(1, ShowreelKit.ca(0xffffff, 0.24))
            )
            .child(
                el().absolute(x: bx + bw + 16, y: by).size(bh, bh).rounded(bh / 2.0)
                    .backdropBlur(18)
                    .bg(ShowreelKit.ca(0x1b1b20, 0.65))
                    .border(1, ShowreelKit.ca(0xffffff, 0.16))
            )

        for (i, name) in tabs.enumerated() {
            let on = abs(sel - Float(i)) < 0.5
            root = root.child(
                row().absolute(x: bx + slot * Float(i), y: by).size(slot, bh).center()
                    .child(ShowreelKit.t(name, 13.5, 600, on ? 0xffffff : 0xd8d8de))
            )
        }
        return root.child(row().absolute(x: bx + bw + 16, y: by).size(bh, bh).center().child(ShowreelKit.t("+", 26, 400, 0xffffff)))
    }

    // MARK: - Type

    static func typeView(_ s: ShowreelState) -> El<ShowreelState> {
        let title = "Small type, sharp edges"
        let lines = [
            "Good interfaces are mostly text. Labels, numbers,",
            "code and long reading all live or die by the edge",
        ]
        let typedA = "of "
        let typedB = "every glyph"
        let typedC = ", and where it lands on the pixel."
        let typeFrom = 0.5
        let typeRate = 16.0
        let selectT = 3.9
        let bodySize: Float = 17.0
        let ink: UInt32 = 0xc9cad1
        let t = s.t

        func body(_ str: String, _ color: UInt32) -> El<ShowreelState> {
            text(str).size(bodySize).weight(400).color(ShowreelKit.c(color))
        }

        let full = typedA + typedB + typedC
        let n = min(full.count, Int(max(0.0, (t - typeFrom) * typeRate)))
        let typing = n < full.count
        let sel = ShowreelKit.track(t, 0.0, [(selectT, 1.0, ShowreelKit.sp(0.3, 0.0))])
        let bar = ShowreelKit.track(t, 0.0, [(selectT + 0.12, 1.0, ShowreelKit.sp(0.45, 0.32))])

        let caretOn = typing || (Int(t * 1.8) % 2 == 0)
        let caretEl: El<ShowreelState> = el().w(2).h(22).rounded(1).bg(ShowreelKit.ca(0x8ab4ff, caretOn ? 1.0 : 0.0))

        let last: El<ShowreelState> = if t < selectT {
            row().h(28).itemsCenter().child(body(String(full.prefix(n)), ink)).child(caretEl)
        } else {
            row().h(28).itemsCenter()
                .child(body(typedA, ink))
                .child(el().rounded(3).bg(ShowreelKit.ca(0x3b82f6, 0.42 * sel)).child(body(typedB, 0xffffff)))
                .child(body(typedC, ink))
        }

        var doc: El<ShowreelState> = col().key("doc").absolute(x: 200, y: 130).w(600).gap(0)
            .child(
                row().gap(8).itemsCenter()
                    .child(text("Notes").size(12.5).weight(500).color(ShowreelKit.c(ShowreelKit.FAINT)))
                    .child(text("/").size(12.5).weight(400).color(ShowreelKit.c(0x45454c)))
                    .child(text("Typography").size(12.5).weight(500).color(ShowreelKit.c(ShowreelKit.MUTED)))
            )
            .child(el().h(22))
            .child(text(title).size(40).weight(600).tracking(-0.9).color(ShowreelKit.c(0xf3f3f5)))
            .child(el().h(10))
            .child(
                row().gap(10).itemsCenter()
                    .child(ShowreelKit.avatar("", 0x7c5cff, 18))
                    .child(text("Mira Chen").size(13).weight(500).color(ShowreelKit.c(ShowreelKit.MUTED)))
                    .child(text("·").size(13).weight(400).color(ShowreelKit.c(ShowreelKit.FAINT)))
                    .child(text("4 min read").size(13).weight(400).color(ShowreelKit.c(ShowreelKit.FAINT)))
            )
            .child(el().h(26))

        for l in lines {
            doc = doc.child(row().h(28).itemsCenter().child(body(l, ink)))
        }
        doc = doc.child(last)
        doc = doc.child(el().h(24)).child(
            row().gap(10).itemsCenter()
                .child(el().px(8).py(3).rounded(6).bg(ShowreelKit.ca(0xffffff, 0.06)).child(ShowreelKit.mono("font-feature-settings: \"tnum\"", 12.5, 0x9ecbff)))
                .child(text("0123456789").size(13).weight(500).color(ShowreelKit.c(ShowreelKit.MUTED)))
        )

        var root: El<ShowreelState> = el().w(ShowreelKit.W).h(ShowreelKit.H).bg(ShowreelKit.c(0x0b0b0d)).child(doc)
        if t >= selectT + 0.1 {
            let item = { (lbl: String, w: Float, on: Bool) -> El<ShowreelState> in
                row().size(30, 28).rounded(7).center().bg(ShowreelKit.ca(0xffffff, on ? 0.1 : 0.0))
                    .child(text(lbl).size(14).weight(w).color(ShowreelKit.c(on ? 0xffffff : 0xb4b6bf)))
            }
            let fmtBar: El<ShowreelState> = row().key("format").h(38).px(5).gap(2).rounded(11).itemsCenter()
                .bg(ShowreelKit.c(0x1d1e23)).border(1, ShowreelKit.ca(0xffffff, 0.1))
                .shadow(Shadow(y: 10, blur: 28, color: ShowreelKit.ca(0x000000, 0.55)))
                .scale(0.86 + 0.14 * bar)
                .opacity(bar.clamped(to: 0...1))
                .child(item("B", 700, true))
                .child(item("I", 400, false))
                .child(item("U", 400, false))
                .child(el().w(1).h(18).mx(4).bg(ShowreelKit.ca(0xffffff, 0.12)))
                .child(item("Aa", 500, false))
                .child(item("“", 500, false))

            root = root.child(
                row().key("format-at").absolute(x: 181, y: 284 - 6 * (1 - bar)).child(fmtBar)
            )
        }
        return root
    }
}
