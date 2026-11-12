import Foundation
import Rune

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
    return col()
        .sizeFull()
        .p(Tok.Space.xl)
        .gap(Tok.Space.md)
        .bg(t.bg)
        .child(text("Drag to draw").font(Tok.Typography.body).color(t.textSecondary))
        .child(buildPaper(s))
}

@main
enum RuneSketchApp {
    static func makeSpec() -> AppSpec<SketchState> {
        AppSpec<SketchState>(
            title: "Sketch",
            size: Vec2(560, 420),
            state: SketchState(),
            view: sketchView
        )
    }

    static func main() throws {
        try RuneApp.run(makeSpec())
    }
}
