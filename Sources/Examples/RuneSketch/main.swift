import Foundation
import Rune
import RuneKit

/// Port of `examples/sketch`: freehand drawing canvas where pointer-down and drag
/// append strokes rendered as smooth round-capped vector paths.
private let inkColor = Color(r: 0.11, g: 0.11, b: 0.12, a: 1.0)

struct SketchState {
    var strokes: [[Vec2]] = []
}

private func buildPaper(_ s: SketchState) -> El<SketchState> {
    var paper: El<SketchState> = el()
        .key("paper")
        .wFull()
        .grow(1)
        .rounded(Tok.Radius.lg)
        .bg(.white)
        .border(1, Tok.theme(dark: false).cardBorder)
        .onPointerDown { state, press, tx in
            state.strokes.append([press.local])
            tx.settle()
        }
        .onDrag { state, drag, tx in
            if state.strokes.isEmpty {
                state.strokes.append([drag.startLocal, drag.local])
            } else {
                state.strokes[state.strokes.count - 1].append(drag.local)
            }
            tx.settle()
        }

    for stroke in s.strokes where !stroke.isEmpty {
        var path = VectorPath()
        path.moveTo(stroke[0].x, stroke[0].y)
        if stroke.count == 1 {
            path.lineTo(stroke[0].x + 0.01, stroke[0].y + 0.01)
        } else {
            for pt in stroke.dropFirst() {
                path.lineTo(pt.x, pt.y)
            }
        }
        paper = paper.shape(Shape.stroke(path, color: inkColor, width: 2.5, roundCap: true))
    }

    return paper
}

func sketchView(_ s: SketchState, _ cx: inout Cx<SketchState>) -> El<SketchState> {
    let t = Tok.theme(dark: false)

    let header: El<SketchState> = row()
        .wFull()
        .itemsCenter()
        .justifyBetween()
        .child(text("Drag to draw").font(Tok.Typography.body).color(t.textSecondary))
        .child(
            row()
                .key("clear-btn")
                .role(.button)
                .label("Clear")
                .px(10)
                .py(4)
                .rounded(Tok.Radius.sm)
                .bg(t.controlTrack)
                .pressScale(0.95)
                .onClick { state in state.strokes.removeAll() }
                .child(text("Clear").font(TextStyle(size: 11.5, weight: 400)).color(t.textSecondary))
        )

    return col()
        .sizeFull()
        .p(Tok.Space.xl)
        .gap(Tok.Space.md)
        .bg(t.bg)
        .child(header)
        .child(buildPaper(s))
}

let spec = AppSpec<SketchState>(
    title: "Sketch",
    size: Vec2(560, 420),
    state: SketchState(),
    onKey: { state, event, _ in
        if event.key == .escape {
            state.strokes.removeAll()
            return true
        }
        return false
    },
    view: sketchView
)
.scene("empty") { _ in }
.scene("drawn") { s in
    var wave: [Vec2] = []
    for i in 0...48 {
        let t = Float(i) / 48.0
        let x = 70.0 + t * 360.0
        let y = 160.0 + sinf(t * .pi * 3.0) * 52.0
        wave.append(Vec2(x, y))
    }
    let loop: [Vec2] = [
        Vec2(140, 250), Vec2(210, 215), Vec2(280, 260), Vec2(350, 225), Vec2(410, 245)
    ]
    s.strokes = [wave, loop]
}

try RuneApp.run(spec)
