import Foundation
import Rune
import RuneFX
import RuneMotion

let canvasWidth: Float = 780.0
let canvasHeight: Float = 600.0

let lampRest = Vec2(690.0, 196.0)
let glowBtnRect = FxRect(x: 70, y: 110, w: 180, h: 52)
let neonRect = FxRect(x: 320, y: 84, w: 190, h: 116)
let hotDotCenter: (x: Float, y: Float, r: Float) = (592, 132, 8)
let auraRect = FxRect(x: 70, y: 300, w: 360, h: 56)
let glowTextRect = FxRect(x: 496, y: 270, w: 220, h: 100)

let radarCenter: (x: Float, y: Float, r: Float) = (110, 140, 20)
let avatarCenter: (x: Float, y: Float, r: Float) = (290, 140, 26)
let liveRect = FxRect(x: 430, y: 124, w: 88, h: 32)
let sendCenter: (x: Float, y: Float, r: Float) = (100, 390, 20)
let inboxRect = FxRect(x: 530, y: 332, w: 190, h: 116)

let arcA = Vec2(70, 120)
let arcB = Vec2(710, 120)
let overloadRect = FxRect(x: 70, y: 230, w: 290, h: 160)
let chargedRect = FxRect(x: 450, y: 280, w: 240, h: 60)

let flamesRect = FxRect(x: 80, y: 320, w: 270, h: 150)
let plasmaRect = FxRect(x: 430, y: 150, w: 270, h: 66)
let deployRect = FxRect(x: 475, y: 360, w: 180, h: 52)

let cardSize = Vec2(156, 92)
let cardRest = Vec2(312, 254)

let lensSize = Vec2(220, 72)
let lensRest = Vec2(230, 204)
let crtRect = FxRect(x: 40, y: 330, w: 300, h: 140)
let chromaRect = FxRect(x: 372, y: 356, w: 360, h: 76)

let skeletonRect = FxRect(x: 40, y: 70, w: 330, h: 216)
let thinkingRect = FxRect(x: 34, y: 330, w: 150, h: 44)
let auroraRect = FxRect(x: 420, y: 70, w: 310, h: 186)
let proRect = FxRect(x: 524, y: 336, w: 104, h: 40)

let recCenter: (x: Float, y: Float, r: Float) = (390, 318, 30)
let progressRect = FxRect(x: 20, y: 430, w: 740, h: 10)

let keyCols = 10
let keyCount = 20

func keyRect(_ i: Int) -> FxRect {
    let r = i / keyCols
    let c = i % keyCols
    return FxRect(x: 40 + Float(c) * 71, y: 300 + Float(r) * 106, w: 62, h: 88)
}

private func accentKey(_ i: Int) -> Bool {
    i == 2 || i == 7 || i == 18
}

func lensRect(_ c: Vec2) -> FxRect {
    FxRect(x: c.x - lensSize.x * 0.5, y: c.y - lensSize.y * 0.5, w: lensSize.x, h: lensSize.y)
}

private func inside(_ r: FxRect, _ p: Vec2, pad: Float = 0) -> Bool {
    p.x >= r.x - pad && p.x <= r.x + r.w + pad && p.y >= r.y - pad && p.y <= r.y + r.h + pad
}

private func near(_ c: Vec2, _ p: Vec2, radius: Float) -> Bool {
    hypot(c.x - p.x, c.y - p.y) <= radius
}

func stageBackdrop(for scene: LabScene) -> Color {
    switch scene {
    case .lamp: oklch(0.17, 0.006, 265)
    case .flashlight: oklch(0.16, 0.005, 265)
    case .gi: oklch(0.15, 0.006, 265)
    case .keys: oklch(0.18, 0.004, 265)
    case .godRays: oklch(0.11, 0.014, 265)
    default: oklch(0.145, 0.006, 265)
    }
}

func onStageDrag(_ s: inout LabState, _ d: Drag, _ tx: inout Tx) {
    let p = Vec2(
        d.local.x - (d.size.x - canvasWidth) * 0.5,
        d.local.y - (d.size.y - canvasHeight) * 0.5
    )
    let now = s.now
    let t = Float(now)

    // Detect start vs move by comparing delta
    if d.delta == .zero && s.grab == nil {
        switch s.scene {
        case .lamp:
            if near(s.lamp, p, radius: 30) {
                s.grab = .lamp(Vec2(p.x - s.lamp.x, p.y - s.lamp.y))
            }
        case .keys:
            if let i = (0..<keyCount).first(where: { inside(keyRect($0), p) }) {
                s.keys[i].animateTo(1.0, anim: .spring(Spring(duration: 0.1, bounce: 0)), at: now)
                s.grab = .key(i)
            }
        case .gi:
            if near(Vec2(recCenter.x, recCenter.y), p, radius: recCenter.r + 20) {
                s.recording.toggle()
            } else if inside(progressRect, p, pad: 10) {
                s.uploading.toggle()
            }
        case .glow:
            if inside(neonRect, p) {
                s.neonOn.toggle()
            }
        case .pulses:
            let shot: LabShot
            if near(Vec2(sendCenter.x, sendCenter.y), p, radius: sendCenter.r + 4) {
                shot = LabShot(kind: .ping, at: Vec2(sendCenter.x, sendCenter.y), t0: t)
            } else if inside(inboxRect, p) {
                shot = LabShot(kind: .rippleCard, at: p, t0: t)
            } else {
                shot = LabShot(kind: .ripple, at: p, t0: t)
            }
            s.shots.append(shot)
            if s.shots.count > 8 { s.shots.removeFirst() }
        case .motion:
            let c = s.card.sample(at: now)
            if inside(FxRect(x: c.x, y: c.y, w: cardSize.x, h: cardSize.y), p, pad: 6) {
                s.grab = .card(Vec2(p.x - c.x, p.y - c.y))
                s.card.set(c)
                s.lastDragPos = p
                s.cardVelocity = .zero
                tx.settle()
            }
        case .electric:
            if !inside(chargedRect, p) {
                s.shots.append(LabShot(kind: .zap, at: p, t0: t))
                if s.shots.count > 8 { s.shots.removeFirst() }
            }
        case .extras:
            if inside(proRect, p, pad: 8) {
                s.shots.append(LabShot(kind: .sparkles, at: p, t0: t))
                if s.shots.count > 8 { s.shots.removeFirst() }
            }
        case .lens:
            if inside(lensRect(s.lens), p, pad: 4) {
                s.grab = .lens(Vec2(p.x - s.lens.x, p.y - s.lens.y))
            } else {
                s.shots.append(LabShot(kind: .shockwave, at: p, t0: t))
                if s.shots.count > 8 { s.shots.removeFirst() }
            }
        default:
            break
        }
        return
    }

    switch s.grab {
    case .lamp(let o):
        s.lamp = Vec2(
            min(max(p.x - o.x, 0), canvasWidth),
            min(max(p.y - o.y, 0), canvasHeight)
        )
        tx.settle()
    case .card(let o):
        let c = Vec2(
            min(max(p.x - o.x, 0), canvasWidth - cardSize.x),
            min(max(p.y - o.y, 0), canvasHeight - cardSize.y)
        )
        let prev = s.lastDragPos ?? p
        s.cardVelocity = Vec2((p.x - prev.x) * 60, (p.y - prev.y) * 60)
        s.lastDragPos = p
        s.card.set(c)
        tx.settle()
    case .lens(let o):
        s.lens = Vec2(
            min(max(p.x - o.x, 0), canvasWidth),
            min(max(p.y - o.y, 0), canvasHeight)
        )
        tx.settle()
    default:
        break
    }
}

func onStageDragEnd(_ s: inout LabState, _ cancelled: Bool, _ tx: inout Tx) {
    let now = s.now
    switch s.grab {
    case .key(let i):
        s.keys[i].animateTo(0.0, anim: .spring(Spring(duration: 0.25, bounce: 0)), at: now)
    case .card:
        let c = s.card.sample(at: now)
        let glide = s.k(.motion, "glide")
        let targetX = min(max(c.x + s.cardVelocity.x * 0.18, 0), canvasWidth - cardSize.x)
        let targetY = min(max(c.y + s.cardVelocity.y * 0.18, 0), canvasHeight - cardSize.y)
        s.card.release(
            velocity: s.cardVelocity,
            target: Vec2(targetX, targetY),
            curve: .spring(Spring(duration: glide, bounce: 0)),
            at: now
        )
        tx.settle()
    default:
        break
    }
    s.grab = nil
    s.lastDragPos = nil
}

// MARK: - Stage View Helpers

private struct StagePalette {
    let sc: LabScene
    let txt = oklch(0.94, 0.003, 265)
    let txt2 = oklch(0.68, 0.01, 265)
    let txt3 = oklch(0.52, 0.01, 265)
    let hair = oklcha(1.0, 0.0, 0.0, 0.07)
    let card = oklch(0.225, 0.007, 265)
}

private func bx(_ x: Float, _ y: Float, _ w: Float, _ h: Float) -> El<LabState> {
    el().absolute(x: x, y: y).size(w, h)
}

private func lbl(_ x: Float, _ y: Float, _ s: String, _ size: Float, _ weight: Float, _ c: Color) -> El<LabState> {
    text(s).absolute(x: x, y: y).font(TextStyle(size: size, weight: weight)).color(c)
}

private func monoLbl(_ x: Float, _ y: Float, _ s: String, _ size: Float, _ c: Color) -> El<LabState> {
    text(s).absolute(x: x, y: y).font(TextStyle(size: size, weight: 500).mono()).color(c)
}

private func rcEl(_ rc: FxRect) -> El<LabState> {
    bx(rc.x, rc.y, rc.w, rc.h)
}

private func circleEl(_ cx: Float, _ cy: Float, _ r: Float) -> El<LabState> {
    bx(cx - r, cy - r, r * 2, r * 2).rounded(r)
}

func hx(_ hex: UInt32) -> Color {
    Color.rgba8(
        UInt8((hex >> 16) & 0xFF),
        UInt8((hex >> 8) & 0xFF),
        UInt8(hex & 0xFF)
    )
}

private func skeletonLines(_ x: Float, _ y: Float, _ w: Float, _ n: Int) -> [El<LabState>] {
    let ratios: [Float] = [1.0, 0.82, 0.6, 0.9]
    return (0..<n).map { i in
        let ww = w * ratios[i % 4]
        return bx(x, y + Float(i) * 14, ww, 6).rounded(3).bg(oklch(0.3, 0.008, 265))
    }
}

private func fxCard(_ p: StagePalette, _ rc: FxRect, _ radius: Float) -> El<LabState> {
    rcEl(rc)
        .rounded(radius)
        .bg(p.card)
        .border(0.5, p.hair)
        .shadow(Shadow(y: 8, blur: 28, color: oklcha(0, 0, 0, 0.5)))
}

private func cap(_ p: StagePalette, _ x: Float, _ y: Float, _ s: String) -> El<LabState> {
    lbl(x, y, s, 11, 500, p.txt3)
}

// MARK: - Scene Canvases

func stageCanvas(_ s: LabState, scene: LabScene) -> El<LabState> {
    let p = StagePalette(sc: scene)
    let kids: [El<LabState>] = switch scene {
    case .lamp: lampCanvas(s, p)
    case .flashlight: flashlightCanvas(p)
    case .gi: giCanvas(s, p)
    case .keys: keysCanvas(s, p)
    case .godRays: godraysCanvas(p)
    case .glow: glowCanvas(s, p)
    case .pulses: pulsesCanvas(s, p)
    case .electric: electricCanvas(s, p)
    case .fire: fireCanvas(s, p)
    case .motion: motionCanvas(s, p)
    case .lens: lensCanvas(s, p)
    case .extras: extrasCanvas(s, p)
    }

    return el()
        .key("canvas-\(scene.id)")
        .size(canvasWidth, canvasHeight)
        .children(kids)
}

private func lampCanvas(_ s: LabState, _ p: StagePalette) -> [El<LabState>] {
    let user = oklch(0.3, 0.045, 258)
    let userHair = oklcha(1, 0, 0, 0.08)
    func card(_ rc: FxRect, _ c: Color, _ h: Color) -> El<LabState> {
        rcEl(rc).rounded(16).bg(c).border(1, h)
    }
    func body(_ x: Float, _ y: Float, _ lines: [String]) -> [El<LabState>] {
        lines.enumerated().map { lbl(x, y + Float($0.offset) * 21, $0.element, 14, 400, p.txt) }
    }

    let colorIdx = Int(s.k(.lamp, "color").rounded())
    let lampCol = hx(lampColors[min(max(colorIdx, 0), lampColors.count - 1)])
    let intensity = s.k(.lamp, "intensity")
    let lampRadius = s.k(.lamp, "radius")

    var v: [El<LabState>] = [
        // Ambient lamp glow halo
        circleEl(s.lamp.x, s.lamp.y, lampRadius * 8.0)
            .bg(lampCol.alpha(min(0.22, intensity * 0.05)))
            .shadow(Shadow(blur: 80, color: lampCol.alpha(min(0.45, intensity * 0.12)))),
        card(FxRect(x: 400, y: 20, w: 360, h: 64), user, userHair),
        card(FxRect(x: 20, y: 106, w: 500, h: 150), p.card, p.hair),
        card(FxRect(x: 500, y: 280, w: 260, h: 44), user, userHair),
        card(FxRect(x: 20, y: 348, w: 540, h: 160), p.card, p.hair),
    ]
    v += body(418, 32, ["what if lighting effects. like you could", "put a light and it would raytrace…"])
    v += body(40, 122, [
        "Every Rune element is an analytic rounded rect, so the",
        "frame is already an exact distance field. A light can",
        "sphere-trace soft shadows straight through it.",
    ])
    let chips = ["Read shader.wgsl", "Edit lib.rs", "Run bench"]
    let chipX: [Float] = [40, 176, 276]
    let chipW: [Float] = [124, 88, 84]
    for (i, chip) in chips.enumerated() {
        v.append(bx(chipX[i], 212, chipW[i], 26).rounded(13).bg(oklch(0.27, 0.008, 265)).border(1, p.hair))
        v.append(lbl(chipX[i] + 11, 217, chip, 12, 500, p.txt2))
    }
    v += body(520, 292, ["MAKE THIS SOOO GOOOD"])
    v += body(40, 364, ["Lights are springs like everything else."])
    v.append(bx(36, 396, 508, 96).rounded(10).bg(oklch(0.195, 0.008, 265)).border(1, p.hair))
    let code = oklch(0.8, 0.06, 200)
    let codeLines = [
        "let lamp = Light::point(x, y, 40.0)",
        "    .color(WARM).intensity(2.6).radius(11.0);",
        "lights.render(&scene, &[lamp], target);",
    ]
    for (i, line) in codeLines.enumerated() {
        v.append(monoLbl(54, 412 + Float(i) * 22, line, 12.5, code))
    }
    v.append(rcEl(FxRect(x: 20, y: 532, w: 740, h: 56)).rounded(18).bg(p.card).border(1, oklcha(1, 0, 0, 0.09)))
    v.append(lbl(42, 550, "Ask anything…", 14, 400, p.txt3))
    v.append(circleEl(728, 560, 16).bg(oklch(0.72, 0.15, 255)))
    v.append(bx(723, 559, 10, 2).rounded(1).bg(oklch(0.2, 0.02, 255)))

    let held: Bool = if case .lamp = s.grab { true } else { false }
    v.append(
        circleEl(s.lamp.x, s.lamp.y, 15)
            .key("lamp")
            .bg(lampCol.alpha(0.35))
            .border(1.5, oklcha(1, 0, 0, held ? 0.7 : 0.32))
            .shadow(Shadow(blur: 18, color: lampCol.alpha(0.85)))
            .animateLayout(Spring(duration: 0.2, bounce: 0))
    )
    return v
}

private func flashlightCanvas(_ p: StagePalette) -> [El<LabState>] {
    let accent = oklch(0.7, 0.15, 255)
    var v: [El<LabState>] = [
        lbl(20, 6, "Settings", 24, 600, p.txt),
        lbl(20, 42, "Appearance, sound and shortcuts", 13, 400, p.txt2),
    ]
    let rows: [(String, String, Int)] = [
        ("Appearance", "Dark", 2),
        ("Accent", "", 3),
        ("Reduce motion", "", 1),
        ("Sound effects", "", 0),
        ("Volume", "", 4),
        ("Push to talk", "⌥ Space", 2),
        ("Auto-update", "", 1),
        ("Crash reports", "", 0),
        ("Launch at login", "", 1),
    ]
    for g in 0..<3 {
        let x: Float = 20 + Float(g) * 253
        let y: Float = 84
        v.append(bx(x, y, 233, 156).rounded(14).bg(p.card).border(1, p.hair))
        for ri in 0..<3 {
            let (name, value, kind) = rows[g * 3 + ri]
            let ry = y + Float(ri) * 52
            if ri > 0 {
                v.append(bx(x + 14, ry, 205, 1).bg(p.hair))
            }
            v.append(lbl(x + 16, ry + 18, name, 13, 500, p.txt))
            let rx = x + 233 - 16
            switch kind {
            case 0, 1:
                let on = kind == 1
                v.append(bx(rx - 40, ry + 15, 40, 22).rounded(11).bg(on ? accent : oklch(0.33, 0.006, 265)))
                let kx = on ? rx - 20 : rx - 38
                v.append(bx(kx, ry + 17, 18, 18).rounded(9).bg(oklch(0.96, 0, 0)))
            case 2:
                let w: Float = 14 + Float(value.count) * 7.4
                v.append(bx(rx - w, ry + 13, w, 26).rounded(8).bg(oklch(0.3, 0.006, 265)).border(1, p.hair))
                v.append(lbl(rx - w + 8, ry + 18, value, 12, 500, p.txt))
            case 3:
                let hues: [Float] = [255, 300, 350, 40, 150]
                for (k, h) in hues.enumerated() {
                    let cx = rx - 16 - Float(k) * 24
                    v.append(bx(cx, ry + 18, 16, 16).rounded(8).bg(oklch(0.68, 0.15, h)))
                }
            default:
                v.append(bx(rx - 110, ry + 25, 110, 4).rounded(2).bg(oklch(0.33, 0.006, 265)))
                v.append(bx(rx - 110, ry + 25, 70, 4).rounded(2).bg(accent))
                v.append(bx(rx - 49, ry + 18, 18, 18).rounded(9).bg(oklch(0.96, 0, 0)))
            }
        }
    }
    let by: Float = 266
    v.append(bx(20, by, 739, 132).rounded(14).bg(p.card).border(1, p.hair))
    v.append(lbl(40, by + 18, "Keyboard shortcuts", 15, 600, p.txt))
    v.append(lbl(40, by + 42, "Press a key combination to record a new shortcut.", 13, 400, p.txt2))
    for (i, k) in ["⌘", "⇧", "K"].enumerated() {
        let x: Float = 40 + Float(i) * 52
        v.append(bx(x, by + 72, 44, 44).rounded(10).bg(oklch(0.3, 0.006, 265)).border(1, p.hair))
        v.append(lbl(x + 15, by + 84, k, 15, 600, p.txt))
    }
    v.append(bx(589, by + 78, 150, 36).rounded(10).bg(accent))
    v.append(lbl(611, by + 87, "Record shortcut", 13, 600, oklch(0.18, 0.03, 255)))
    v.append(bx(459, by + 78, 116, 36).rounded(10).bg(oklch(0.3, 0.006, 265)).border(1, p.hair))
    v.append(lbl(498, by + 87, "Reset", 13, 600, p.txt))

    let names = ["Microphone", "Speakers", "Camera", "Battery"]
    let subs = ["MacBook Pro", "Studio Display", "FaceTime HD", "92 %"]
    let fills: [Float] = [0.7, 0.45, 0.0, 0.92]
    for i in 0..<4 {
        let x: Float = 20 + Float(i) * 189.5
        v.append(bx(x, 424, 172, 116).rounded(14).bg(p.card).border(1, p.hair))
        v.append(lbl(x + 16, 440, names[i], 13, 600, p.txt))
        v.append(lbl(x + 16, 462, subs[i], 12, 400, p.txt2))
        v.append(bx(x + 16, 502, 140, 16).rounded(8).bg(oklch(0.27, 0.006, 265)))
        if fills[i] > 0 {
            v.append(bx(x + 16, 502, 140 * fills[i], 16).rounded(8).bg(accent))
        }
    }
    return v
}

private func giCanvas(_ s: LabState, _ p: StagePalette) -> [El<LabState>] {
    var v: [El<LabState>] = [
        lbl(20, 4, "Voice memo", 24, 600, p.txt),
        lbl(20, 40, "Recording · Studio Display microphone", 13, 400, p.txt2),
    ]
    func card(_ rc: FxRect, _ radius: Float) -> El<LabState> {
        rcEl(rc).rounded(radius).bg(p.card).border(1, p.hair)
    }
    let leftCards = [("Transcript", "Live, 2 speakers"), ("Markers", "3 added"), ("Noise", "Voice isolation on")]
    for (i, item) in leftCards.enumerated() {
        let y: Float = 80 + Float(i) * 110
        v.append(card(FxRect(x: 20, y: y, w: 200, h: 96), 16))
        v.append(lbl(40, y + 18, item.0, 14, 600, p.txt))
        v.append(lbl(40, y + 42, item.1, 13, 400, p.txt2))
    }
    v.append(card(FxRect(x: 240, y: 80, w: 300, h: 316), 20))
    v.append(lbl(262, 98, "00:42.18", 30, 600, p.txt))
    v.append(lbl(262, 140, s.recording ? "Recording" : "Paused", 13, 500, oklch(0.75, 0.12, 25)))
    for k in 0..<30 {
        let h: Float = 8 + 40 * abs(0.5 + 0.5 * (sinf(Float(k) * 0.7) * cosf(Float(k) * 0.23 + 1.0)))
        v.append(bx(262 + Float(k) * 8.6, 206 - h * 0.5, 4.4, h).rounded(2.2).bg(oklch(0.5, 0.01, 265)))
    }
    let emission = s.k(.gi, "emission")
    v.append(circleEl(recCenter.x, recCenter.y, 50).bg(oklch(0.27, 0.008, 265)).border(1, p.hair))
    let recCol = s.recording ? oklch(0.66, 0.2, 25) : oklch(0.35, 0.04, 25)
    v.append(
        circleEl(recCenter.x, recCenter.y, recCenter.r)
            .bg(recCol)
            .shadow(Shadow(blur: s.recording ? 28 * emission : 0, color: recCol.alpha(0.75)))
    )

    let rightCards = [("Agent finished", "Demos rendered"), ("Build passed", "ci · 1m 12s"), ("Review", "No blockers")]
    for (i, item) in rightCards.enumerated() {
        let y: Float = 80 + Float(i) * 110
        v.append(card(FxRect(x: 560, y: y, w: 200, h: 96), 16))
        v.append(lbl(598, y + 18, item.0, 14, 600, p.txt))
        v.append(lbl(598, y + 42, item.1, 13, 400, p.txt2))
        let c = i == 0 ? oklch(0.78, 0.17, 150) : oklch(0.45, 0.01, 265)
        v.append(bx(578, y + 22, 10, 10).rounded(5).bg(c).shadow(Shadow(blur: i == 0 ? 12 : 0, color: c.alpha(0.7))))
    }
    v.append(rcEl(progressRect).rounded(5).bg(oklch(0.24, 0.006, 265)))
    let progCol = oklch(0.78, 0.13, 210)
    v.append(
        rcEl(FxRect(x: progressRect.x, y: progressRect.y, w: progressRect.w * (s.uploading ? 0.62 : 0.28), h: progressRect.h))
            .rounded(5)
            .bg(progCol)
            .shadow(Shadow(blur: s.uploading ? 16 : 4, color: progCol.alpha(0.6)))
    )
    v.append(lbl(20, 452, "Uploading to OpenCode · 3 of 5 files", 12, 500, p.txt2))
    let actions = ["Pause", "Marker", "Trim", "Share", "Export"]
    for i in 0..<5 {
        let x: Float = 20 + Float(i) * 151
        v.append(card(FxRect(x: x, y: 492, w: 136, h: 90), 16))
        v.append(lbl(x + 18, 510, actions[i], 13, 600, p.txt))
    }
    return v
}

private func keysCanvas(_ s: LabState, _ p: StagePalette) -> [El<LabState>] {
    let keyCol = oklch(0.29, 0.004, 265)
    var v: [El<LabState>] = [
        rcEl(FxRect(x: 0, y: 0, w: canvasWidth, h: canvasHeight))
            .rounded(32)
            .bg(oklch(0.255, 0.004, 265))
            .border(1, oklcha(1, 0, 0, 0.05)),
        lbl(40, 30, "OP-1 Field · Control surface", 15, 600, p.txt),
        lbl(40, 54, "Bevels from the SDF catch the light", 12, 400, p.txt2),
    ]
    let hues: [Float] = [255, 150, 60, 25]
    for (i, h) in hues.enumerated() {
        let cx: Float = 90 + Float(i) * 116
        v.append(circleEl(cx, 170, 42).bg(keyCol).shadow(Shadow(y: 4, blur: 10, color: oklcha(0, 0, 0, 0.45))))
        v.append(circleEl(cx, 140, 5).bg(oklch(0.7, 0.14, h)))
    }
    v.append(bx(530, 100, 210, 140).rounded(18).bg(oklch(0.14, 0.01, 265)))
    v.append(lbl(554, 124, "128 BPM", 26, 600, oklch(0.85, 0.12, 150)))
    v.append(lbl(554, 166, "Pattern A · bar 12", 13, 400, oklch(0.6, 0.06, 150)))
    let names = ["C", "D", "E", "F", "G", "A", "B", "C", "D", "E"]
    for i in 0..<keyCount {
        let rc = keyRect(i)
        let accent = accentKey(i)
        let press = s.keys[i].sample(at: s.now)
        let fill = accent ? oklch(0.62 - 0.08 * press, 0.17, 35) : oklch(0.29 - 0.05 * press, 0.004, 265)
        v.append(
            rcEl(FxRect(x: rc.x, y: rc.y + press * 3, w: rc.w, h: rc.h))
                .rounded(14)
                .bg(fill)
                .shadow(Shadow(y: 4 - press * 3, blur: 8 - press * 5, color: oklcha(0, 0, 0, 0.4)))
        )
        v.append(lbl(rc.x + 12, rc.y + 12 + press * 3, names[i % keyCols], 12, 600, accent ? oklch(0.2, 0.03, 35) : p.txt2))
    }
    return v
}

private func godraysCanvas(_ p: StagePalette) -> [El<LabState>] {
    let names = [
        "Inbox", "Calendar", "Notes", "Music", "Photos", "Maps", "Files", "Terminal", "Mail", "Weather", "Clock",
        "Books", "Home", "Wallet", "Health", "Code", "Notes", "Rune",
    ]
    var v: [El<LabState>] = [
        circleEl(374, 304, 180).bg(oklch(0.55, 0.14, 240).alpha(0.16)).shadow(Shadow(blur: 100, color: oklch(0.65, 0.15, 240).alpha(0.35))),
        lbl(28, 70, "Good evening", 30, 600, p.txt),
        lbl(28, 114, "18 apps · light from behind the grid", 14, 400, p.txt2),
    ]
    for i in 0..<18 {
        let rw = i / 6
        let c = i % 6
        let x: Float = 28 + Float(c) * 124
        let y: Float = 190 + Float(rw) * 124
        v.append(bx(x, y, 104, 104).rounded(22).bg(oklch(0.21, 0.008, 265)).border(1, p.hair))
        v.append(bx(x + 16, y + 16, 36, 36).rounded(11).bg(oklch(0.62, 0.12, Float((i * 47) % 360))))
        v.append(lbl(x + 16, y + 70, names[i], 13, 600, p.txt))
    }
    return v
}

private func glowCanvas(_ s: LabState, _ p: StagePalette) -> [El<LabState>] {
    let colorIdx = Int(s.k(.glow, "color").rounded())
    let glowCol = hx(fxColors[min(max(colorIdx, 0), fxColors.count - 1)])
    let intensity = s.k(.glow, "intensity")
    let radius = s.k(.glow, "radius")

    var v: [El<LabState>] = [
        rcEl(glowBtnRect)
            .rounded(glowBtnRect.h * 0.5)
            .bg(hx(0x7a5cf6))
            .border(0.5, oklcha(1, 0, 0, 0.16))
            .shadow(Shadow(y: 4, blur: 10 + radius * 0.6, color: hx(0x7a5cf6).alpha(min(0.8, intensity * 0.45)))),
        lbl(glowBtnRect.x + 52, glowBtnRect.y + 16, "Generate", 15, 600, .white),
        cap(p, glowBtnRect.x, glowBtnRect.y + 80, "Soft · breathing"),
        fxCard(p, neonRect, 16)
            .border(s.neonOn ? 1.5 : 0.5, s.neonOn ? glowCol : p.hair)
            .shadow(Shadow(blur: s.neonOn ? radius * 0.9 : 0, color: glowCol.alpha(s.neonOn ? min(0.85, intensity * 0.5) : 0))),
        lbl(neonRect.x + 18, neonRect.y + 20, "Neon", 15, 600, hx(0xe6f9ff)),
    ]
    v += skeletonLines(neonRect.x + 18, neonRect.y + 50, 120, 3)
    v.append(cap(p, neonRect.x, neonRect.y + neonRect.h + 24, s.neonOn ? "Neon · click to switch off" : "Neon · click to switch on"))
    v.append(
        circleEl(hotDotCenter.x, hotDotCenter.y, hotDotCenter.r)
            .bg(hx(0xfff3dc))
            .shadow(Shadow(blur: 18, color: hx(0xff9a4d).alpha(0.85)))
    )
    v.append(lbl(hotDotCenter.x + 18, hotDotCenter.y - 9, "Recording", 13, 500, oklch(0.88, 0.005, 265)))
    v.append(cap(p, hotDotCenter.x - 10, neonRect.y + neonRect.h + 24, "Hot core"))
    v.append(
        rcEl(auraRect)
            .rounded(auraRect.h * 0.5)
            .bg(oklch(0.2, 0.008, 265))
            .border(1, glowCol.alpha(0.45))
            .shadow(Shadow(y: 6, blur: 20, color: glowCol.alpha(0.35)))
    )
    v.append(lbl(auraRect.x + 26, auraRect.y + 18, "Ask anything…", 15, 400, oklch(0.62, 0.01, 265)))
    v.append(cap(p, auraRect.x, auraRect.y + auraRect.h + 24, "Aura · flowing spectrum"))
    v.append(
        text("Rune")
            .absolute(x: glowTextRect.x, y: glowTextRect.y)
            .font(TextStyle(size: 76, weight: 600))
            .color(hx(0xfff4e6))
            .shadow(Shadow(blur: 24, color: glowCol.alpha(0.45)))
    )
    v.append(cap(p, glowTextRect.x, auraRect.y + auraRect.h + 24, "Mask · text bloom"))
    return v
}

private func pulsesCanvas(_ s: LabState, _ p: StagePalette) -> [El<LabState>] {
    let colorIdx = Int(s.k(.pulses, "color").rounded())
    let pulseCol = hx(fxColors[min(max(colorIdx, 0), fxColors.count - 1)])

    var v: [El<LabState>] = [
        circleEl(radarCenter.x, radarCenter.y, radarCenter.r + 22).border(1.5, hx(0xf04e5e).alpha(0.3)),
        circleEl(radarCenter.x, radarCenter.y, radarCenter.r + 42).border(1.0, hx(0xf04e5e).alpha(0.14)),
        circleEl(radarCenter.x, radarCenter.y, radarCenter.r).bg(hx(0xf04e5e)).border(0.5, oklcha(1, 0, 0, 0.2)),
        bx(radarCenter.x - 6, radarCenter.y - 6, 12, 12).rounded(3).bg(oklcha(1, 0, 0, 0.95)),
        cap(p, radarCenter.x - 18, radarCenter.y + 70, "Radar"),
        circleEl(avatarCenter.x, avatarCenter.y, avatarCenter.r + 8).border(2, hx(0x34d399).alpha(0.35)),
        circleEl(avatarCenter.x, avatarCenter.y, avatarCenter.r).bg(oklch(0.33, 0.012, 265)).border(1, hx(0x34d399)),
        lbl(avatarCenter.x - 10, avatarCenter.y - 9, "KL", 14, 600, oklch(0.95, 0.003, 265)),
        cap(p, avatarCenter.x - 40, avatarCenter.y + 70, "Breathing halo"),
        rcEl(liveRect).rounded(liveRect.h * 0.5).bg(hx(0xe8315a)).border(0.5, oklcha(1, 0, 0, 0.2)),
        lbl(liveRect.x + 28, liveRect.y + 8, "LIVE", 12, 600, .white),
        cap(p, liveRect.x + 10, avatarCenter.y + 70, "Heartbeat"),
        fxCard(p, inboxRect, 16),
        lbl(inboxRect.x + 18, inboxRect.y + 20, "Inbox", 15, 600, p.txt),
    ]
    v += skeletonLines(inboxRect.x + 18, inboxRect.y + 50, 120, 3)
    v.append(
        circleEl(sendCenter.x, sendCenter.y, sendCenter.r)
            .key("send")
            .bg(hx(0x3d7ff5))
            .border(0.5, oklcha(1, 0, 0, 0.16))
            .shadow(Shadow(y: 4, blur: 10, color: oklcha(0, 0, 0, 0.4)))
    )
    v.append(lbl(sendCenter.x - 6, sendCenter.y - 10, "→", 16, 600, .white))
    v.append(cap(p, sendCenter.x - 30, sendCenter.y + 46, "Send · ping → ripple"))
    v.append(cap(p, 250, 560, "Click anywhere for a ripple"))

    for shot in s.shots {
        v.append(circleEl(shot.at.x, shot.at.y, 48).border(2, pulseCol.alpha(0.65)))
    }
    return v
}

private func electricCanvas(_ s: LabState, _ p: StagePalette) -> [El<LabState>] {
    let colorIdx = Int(s.k(.electric, "color").rounded())
    let elecCol = hx(fxColors[min(max(colorIdx, 0), fxColors.count - 1)])

    var v: [El<LabState>] = []
    for term in [arcA, arcB] {
        v.append(circleEl(term.x, term.y, 9).bg(oklch(0.72, 0.01, 265)).border(0.5, oklcha(1, 0, 0, 0.3)))
    }
    v.append(bx(arcA.x + 9, arcA.y - 1, arcB.x - arcA.x - 18, 2).bg(elecCol.alpha(0.55)).shadow(Shadow(blur: 10, color: elecCol.alpha(0.8))))
    v.append(cap(p, arcA.x, arcA.y + 40, "Arc · click to zap"))
    v.append(fxCard(p, overloadRect, 18).border(1, elecCol.alpha(0.65)).shadow(Shadow(blur: 18, color: elecCol.alpha(0.35))))
    v.append(lbl(overloadRect.x + 22, overloadRect.y + 22, "Overload", 16, 600, p.txt))
    v += skeletonLines(overloadRect.x + 22, overloadRect.y + 56, 200, 4)
    v.append(cap(p, overloadRect.x, overloadRect.y + overloadRect.h + 26, "Border current"))
    v.append(
        rcEl(chargedRect)
            .key("charged")
            .rounded(chargedRect.h * 0.5)
            .bg(hx(0x1b2740))
            .border(1, elecCol.alpha(0.5))
            .shadow(Shadow(y: 4, blur: 16, color: elecCol.alpha(0.45)))
    )
    v.append(lbl(chargedRect.x + 86, chargedRect.y + 19, "Charged", 16, 600, hx(0xdbe8ff)))
    v.append(cap(p, chargedRect.x, chargedRect.y + chargedRect.h + 26, "Hover to charge"))
    return v
}

private func fireCanvas(_ s: LabState, _ p: StagePalette) -> [El<LabState>] {
    let fireCol = hx(0xff7a2a)
    let plasmaCol = hx(0x8b5cf6)
    var v: [El<LabState>] = [
        fxCard(p, flamesRect, 18)
            .border(1, fireCol.alpha(0.55))
            .shadow(Shadow(y: -8, blur: 28, color: fireCol.alpha(0.45))),
        lbl(flamesRect.x + 22, flamesRect.y + 24, "Hot take", 16, 600, hx(0xfff1e6)),
    ]
    v += skeletonLines(flamesRect.x + 22, flamesRect.y + 58, 190, 4)
    v.append(cap(p, flamesRect.x, flamesRect.y + flamesRect.h + 26, "Flames + embers"))
    v.append(
        rcEl(plasmaRect)
            .rounded(plasmaRect.h * 0.5)
            .bg(hx(0x15122a))
            .border(1.5, plasmaCol.alpha(0.6))
            .shadow(Shadow(blur: 20, color: plasmaCol.alpha(0.45)))
    )
    v.append(lbl(plasmaRect.x + 106, plasmaRect.y + 22, "Plasma", 16, 600, hx(0xe9e4ff)))
    v.append(cap(p, plasmaRect.x, plasmaRect.y + plasmaRect.h + 28, "Plasma border"))
    v.append(
        rcEl(deployRect)
            .rounded(deployRect.h * 0.5)
            .bg(hx(0xf2702a))
            .border(0.5, oklcha(1, 0, 0, 0.16))
            .shadow(Shadow(y: 4, blur: 18, color: hx(0xf2702a).alpha(0.55)))
    )
    v.append(lbl(deployRect.x + 62, deployRect.y + 16, "Deploy", 15, 600, .white))
    v.append(cap(p, deployRect.x, deployRect.y + deployRect.h + 28, "Heat + haze"))
    return v
}

private func motionCanvas(_ s: LabState, _ p: StagePalette) -> [El<LabState>] {
    var v: [El<LabState>] = []
    for gy in 0..<11 {
        for gx in 0..<14 {
            v.append(bx(30 + Float(gx) * 55, 26 + Float(gy) * 55, 2, 2).rounded(1).bg(oklcha(1, 0, 0, 0.07)))
        }
    }
    let c = s.card.sample(at: s.now)
    let w = cardSize.x
    let h = cardSize.y
    v.append(
        bx(c.x, c.y, w, h)
            .key("card")
            .rounded(14)
            .bg(oklch(0.25, 0.008, 265))
            .border(0.5, oklcha(1, 0, 0, 0.1))
            .shadow(Shadow(y: 4, blur: 8, color: oklcha(0, 0, 0, 0.35)))
            .animateLayout(Spring(duration: s.k(.motion, "glide"), bounce: 0))
            .child(bx(12, 12, 28, 28).rounded(14).bg(hx(0x8462fa)))
            .child(lbl(50, 13, "Flight 204", 13, 600, oklch(0.96, 0.003, 265)))
            .child(lbl(50, 31, "Departing 9:41", 11, 400, oklch(0.7, 0.01, 265)))
            .child(bx(12, 66, w - 24, 6).rounded(3).bg(oklch(0.33, 0.008, 265)))
            .child(bx(12, 66, (w - 24) * 0.62, 6).rounded(3).bg(hx(0x22c48a)))
    )
    v.append(cap(p, 300, 560, "Drag and fling the card"))
    return v
}

private func lensCanvas(_ s: LabState, _ p: StagePalette) -> [El<LabState>] {
    let tiles: [(UInt32, String)] = [(0x7c4ff0, "Violet"), (0xf07a2c, "Ember"), (0x22b5a4, "Lagoon"), (0xe0559c, "Orchid")]
    var v: [El<LabState>] = []
    for (i, tile) in tiles.enumerated() {
        let x: Float = 40 + Float(i) * 180
        v.append(bx(x, 60, 160, 80).rounded(14).bg(hx(tile.0)).border(0.5, oklcha(1, 0, 0, 0.15)))
        v.append(lbl(x + 14, 110, tile.1, 14, 600, oklcha(1, 0, 0, 0.95)))
    }
    let lines = [
        "Glass bends what is behind it: the rim squeezes the page,",
        "the middle stays sharp, and colour splits only at the edge.",
        "Rune copies the backdrop once per lens and lights the rim.",
    ]
    for (i, line) in lines.enumerated() {
        v.append(lbl(40, 176 + Float(i) * 24, line, 15, 400, oklch(0.78, 0.01, 265)))
    }
    v.append(rcEl(crtRect).rounded(14).bg(hx(0x0c1910)))
    v.append(monoLbl(crtRect.x + 18, crtRect.y + 22, "> rune build --release", 13, hx(0x4ade80)))
    v.append(monoLbl(crtRect.x + 18, crtRect.y + 44, "  compiling rune-fx", 13, hx(0x86efac).alpha(0.8)))
    v.append(monoLbl(crtRect.x + 18, crtRect.y + 66, "  finished in 1.84 s", 13, hx(0x86efac).alpha(0.8)))
    v.append(bx(crtRect.x + 18, crtRect.y + 96, 132, 14).rounded(3).bg(hx(0x22c55e)))
    v.append(
        text("Chromatic")
            .absolute(x: chromaRect.x + 8, y: chromaRect.y + 6)
            .font(TextStyle(size: 52, weight: 600))
            .color(oklch(0.96, 0.003, 265))
    )
    v.append(cap(p, 270, 560, "Drag the glass · click for a shockwave"))

    // Liquid glass lens pill
    let lr = lensRect(s.lens)
    let frost = s.k(.lens, "frost")
    v.append(
        rcEl(lr)
            .key("lens")
            .rounded(lr.h * 0.5)
            .backdropBlur(max(2.0, frost * 22.0))
            .bg(Color.white.alpha(0.08 + frost * 0.14))
            .border(1.2, Color.white.alpha(0.32))
            .shadow(Shadow(y: 8, blur: 24, color: Color.black.alpha(0.45)))
    )
    return v
}

private func extrasCanvas(_ s: LabState, _ p: StagePalette) -> [El<LabState>] {
    var v: [El<LabState>] = [fxCard(p, skeletonRect, 16)]
    let bar = oklch(0.27, 0.006, 265)
    for i in 0..<3 {
        let y = skeletonRect.y + 24 + Float(i) * 62
        v.append(bx(skeletonRect.x + 22, y, 36, 36).rounded(18).bg(bar))
        v.append(bx(skeletonRect.x + 72, y + 5, 190 - Float(i) * 28, 11).rounded(5.5).bg(bar))
        v.append(bx(skeletonRect.x + 72, y + 23, 120, 9).rounded(4.5).bg(bar))
    }
    v.append(cap(p, skeletonRect.x, skeletonRect.y + skeletonRect.h + 24, "Skeleton shimmer"))
    v.append(
        text("Thinking…")
            .absolute(x: thinkingRect.x + 6, y: thinkingRect.y + 8)
            .font(TextStyle(size: 22, weight: 500))
            .color(oklch(0.62, 0.01, 265))
    )
    v.append(cap(p, thinkingRect.x + 6, thinkingRect.y + thinkingRect.h + 16, "Text sheen"))
    let auroraOn = s.on(.extras, "aurora")
    v.append(
        fxCard(p, auroraRect, 18)
            .bg(auroraOn ? oklch(0.24, 0.08, 285) : p.card)
            .shadow(Shadow(blur: auroraOn ? 32 : 0, color: oklch(0.6, 0.16, 190).alpha(auroraOn ? 0.35 : 0)))
    )
    v.append(lbl(auroraRect.x + 22, auroraRect.y + auroraRect.h - 40, "Aurora", 19, 600, oklch(0.97, 0.003, 265)))
    v.append(cap(p, auroraRect.x, auroraRect.y + auroraRect.h + 24, "Aurora + static grain"))
    v.append(rcEl(proRect).rounded(proRect.h * 0.5).bg(hx(0xe9c46a)).border(0.5, oklcha(1, 0, 0, 0.4)))
    v.append(lbl(proRect.x + 36, proRect.y + 11, "PRO", 14, 600, hx(0x3b2a06)))
    v.append(cap(p, proRect.x, proRect.y + proRect.h + 26, "Sparkles · click for a burst"))
    return v
}
