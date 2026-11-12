import Foundation
import Rune
import RuneKit
import RuneMotion

/// Port of `examples/matched`: shared-element motion with `El.flightId`.
/// 1–4 picks a tile, Return (or click) zooms it to the whole stage, Escape zooms back.
private let matchedScenes: [(sky: [UInt8], ground: [UInt8], sun: [UInt8])] = [
    ([255, 166, 120], [58, 40, 92], [255, 236, 170]),
    ([120, 200, 255], [30, 90, 70], [255, 255, 235]),
    ([196, 150, 255], [40, 30, 70], [255, 200, 240]),
    ([255, 214, 120], [120, 60, 30], [255, 250, 220]),
]

private let sceneNames = ["Dusk", "Lake", "Haze", "Dune"]

private func generatePicture(_ index: Int) -> RGBA8Atlas {
    let w = 320
    let h = 240
    let (sky, ground, sun) = matchedScenes[index]
    var rgba: [UInt8] = []
    rgba.reserveCapacity(w * h * 4)

    func mix(_ a: [UInt8], _ b: [UInt8], _ t: Float) -> [Float] {
        (0..<3).map { k in
            let af = Float(a[k])
            let bf = Float(b[k])
            return af + (bf - af) * t
        }
    }

    for y in 0..<h {
        let v = Float(y) / Float(h)
        for x in 0..<w {
            let u = Float(x) / Float(w)
            let horizon = 0.62 + 0.04 * sinf(u * 6.0 + Float(index))
            let land = max(0.0, min(1.0, (v - horizon) * Float(h) + 0.5))
            let airBase = mix(sky, ground, powf(min(1.0, v / horizon), 2.2) * 0.5)
            let dx = u - 0.3 - 0.12 * Float(index)
            let dy = (v - 0.42) * 0.75
            let d = sqrtf(dx * dx + dy * dy)
            let glow = powf(max(0.0, min(1.0, 1.0 - d / 0.16)), 0.6)
            let air = (0..<3).map { k in
                airBase[k] + (Float(sun[k]) - airBase[k]) * glow
            }
            let soil = mix(ground, [10, 10, 16], max(0.0, v - horizon) * 1.6)
            for k in 0..<3 {
                let px = air[k] + (soil[k] - air[k]) * land
                rgba.append(UInt8(max(0.0, min(255.0, px))))
            }
            rgba.append(255)
        }
    }

    return RGBA8Atlas(width: w, height: h, texels: rgba)
}

struct MatchedState {
    var picked: Int = 0
    var zoomed: Bool = false
    var pictures: [RGBA8Atlas] = (0..<4).map(generatePicture)
}

private func tileEl(_ s: MatchedState, _ i: Int) -> El<MatchedState> {
    let id = "tile-\(i + 1)"
    var t: El<MatchedState> = el()
        .key(id)
        .flightId(id)
        .grow(1)
        .rounded(20)
        .clip(true)
        .bg(.black)
        .animateLayout(Tok.Motion.DEFAULT)
        .onClick { state in
            if state.zoomed {
                state.zoomed = false
            } else {
                state.picked = i
                state.zoomed = true
            }
        }
        .child(image(s.pictures[i]).sizeFull())
        .child(
            text("\(i + 1)  \(sceneNames[i])")
                .font(TextStyle(size: 22, weight: 600))
                .color(.white)
                .absolute(x: 18, y: 14)
        )

    if s.picked == i {
        t = t.child(
            el()
                .absolute(x: 0, y: 0)
                .sizeFull()
                .rounded(20)
                .border(3, .white)
        )
    }
    return t
}

func matchedView(_ s: MatchedState, _ cx: inout Cx<MatchedState>) -> El<MatchedState> {
    let theme = Tok.theme(dark: true)
    let hint: El<MatchedState> = text("1–4 pick    ↩ zoom    esc back")
        .font(Tok.Typography.label)
        .color(theme.textSecondary)

    var stage: El<MatchedState> = col()
        .key("stage")
        .wFull()
        .grow(1)
        .minH(0)

    if s.zoomed {
        stage = stage.child(tileEl(s, s.picked))
    } else {
        func pair(_ a: Int) -> El<MatchedState> {
            row()
                .key("row-\(a)")
                .grow(1)
                .minH(0)
                .gap(12)
                .child(tileEl(s, a))
                .child(tileEl(s, a + 1))
        }

        stage = stage.child(
            col()
                .key("grid")
                .grow(1)
                .minH(0)
                .gap(12)
                .transition(.scale(0.96))
                .child(pair(0))
                .child(pair(2))
        )
    }

    return col()
        .sizeFull()
        .p(24)
        .gap(14)
        .bg(theme.bg)
        .child(hint)
        .child(stage)
}

let spec = AppSpec<MatchedState>(
    title: "Matched",
    size: Vec2(720, 480),
    state: MatchedState(),
    onKey: { state, event, _ in
        switch event.key {
        case let .text(t) where !state.zoomed:
            if let n = Int(t), (1...4).contains(n) {
                state.picked = n - 1
                return true
            }
            return false
        case .enter:
            state.zoomed = true
            return true
        case .escape:
            state.zoomed = false
            return true
        default:
            return false
        }
    },
    view: matchedView
)
.scene("grid") { _ in }
.scene("one") { $0.zoomed = true }

try RuneApp.run(spec)
