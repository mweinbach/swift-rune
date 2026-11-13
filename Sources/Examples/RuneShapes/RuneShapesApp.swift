import Foundation
import Rune

/// Port of `examples/shapes`: vector shapes including a filled waveform envelope,
/// polylines, level meters, Bézier paths, concave star polygon, and hairline/thick strokes.
public struct ShapesState: Sendable {
    public var t: Float = 0.0
    public var fixedSceneT: Bool = false

    public init(t: Float = 0.0, fixedSceneT: Bool = false) {
        self.t = t
        self.fixedSceneT = fixedSceneT
    }
}

private let ink = Color(r: 0.92, g: 0.93, b: 0.95, a: 1.0)
private let accent = Color(r: 0.35, g: 0.55, b: 1.0, a: 1.0)
private let soft = Color(r: 0.35, g: 0.55, b: 1.0, a: 0.35)
private let warm = Color(r: 1.0, g: 0.55, b: 0.3, a: 1.0)
private let bg = Color(r: 0.06, g: 0.065, b: 0.08, a: 1.0)
private let cardBg = Color(r: 0.1, g: 0.11, b: 0.13, a: 1.0)

private func level(_ t: Float, _ i: Int) -> Float {
    let x = Float(i) * 0.09 + t * 2.0
    return min(1.0, abs(sinf(x) * 0.6 + sinf(x * 2.7) * 0.3 + cosf(x * 7.1) * 0.1))
}

private func waveformEl(_ t: Float, w: Float, h: Float) -> El<ShapesState> {
    let n = 160
    let mid = h * 0.5
    var topPts: [Vec2] = []
    topPts.reserveCapacity(n)
    for i in 0..<n {
        let px = Float(i) * w / Float(n - 1)
        let py = mid - level(t, i) * (mid - 2.0) - 0.5
        topPts.append(Vec2(px, py))
    }

    var envPath = VectorPath()
    if let first = topPts.first {
        envPath.moveTo(first.x, first.y)
        for p in topPts.dropFirst() {
            envPath.lineTo(p.x, p.y)
        }
        for p in topPts.reversed() {
            envPath.lineTo(p.x, 2.0 * mid - p.y)
        }
        envPath.close()
    }

    var wavePath = VectorPath()
    for i in 0..<n {
        let px = Float(i) * w / Float(n - 1)
        let py = mid + sinf(Float(i) * 0.21 + t * 3.0) * mid * 0.8
        if i == 0 {
            wavePath.moveTo(px, py)
        } else {
            wavePath.lineTo(px, py)
        }
    }

    var hairline = VectorPath()
    hairline.moveTo(0, mid)
    hairline.lineTo(w, mid)

    return canvas(Shape.fill(envPath, color: soft).viewBox(w, h))
        .shape(Shape.stroke(wavePath, color: accent, width: 1.5).viewBox(w, h))
        .shape(Shape.stroke(hairline, color: ink, width: 0.5, roundCap: false).viewBox(w, h))
}

private func metersEl(_ t: Float) -> El<ShapesState> {
    var node: El<ShapesState> = el().key("meters").size(244, 68)
    for i in 0..<24 {
        let x = 4.0 + Float(i) * 10.0
        let v = level(t, i * 7) * 56.0 + 4.0
        var bar = VectorPath()
        bar.moveTo(x, 64.0)
        bar.lineTo(x, 64.0 - v)
        let col = v > 48.0 ? warm : accent
        node = node.shape(Shape.stroke(bar, color: col, width: 6.0, roundCap: true))
    }
    return node
}

private func curvesEl() -> El<ShapesState> {
    var wave = VectorPath()
    wave.moveTo(4.0, 50.0)
    wave.cubicTo(c1x: 40.0, c1y: -20.0, c2x: 80.0, c2y: 120.0, x: 116.0, y: 50.0)
    wave.quadTo(cx: 150.0, cy: 0.0, x: 186.0, y: 50.0)

    var blob = VectorPath()
    blob.moveTo(210.0, 30.0)
    blob.cubicTo(c1x: 230.0, c1y: 0.0, c2x: 270.0, c2y: 0.0, x: 280.0, y: 30.0)
    blob.lineTo(260.0, 80.0)
    blob.lineTo(220.0, 80.0)
    blob.close()

    var star = VectorPath()
    for i in 0..<10 {
        let a = Float(i) * .pi / 5.0 - .pi * 0.5
        let r: Float = (i % 2 == 0) ? 40.0 : 16.0
        let px = 340.0 + cosf(a) * r
        let py = 46.0 + sinf(a) * r
        if i == 0 {
            star.moveTo(px, py)
        } else {
            star.lineTo(px, py)
        }
    }
    star.close()

    func diag(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) -> VectorPath {
        var p = VectorPath()
        p.moveTo(x0, y0)
        p.lineTo(x1, y1)
        return p
    }

    return canvas(Shape.stroke(wave, color: warm, width: 3.0, roundCap: true))
        .shape(Shape.fill(blob, color: accent))
        .shape(Shape.stroke(blob, color: ink, width: 1.0, roundCap: true))
        .shape(Shape.fill(star, color: ink))
        .shape(Shape.stroke(diag(400.0, 10.0, 460.0, 86.0), color: ink, width: 0.5, roundCap: false))
        .shape(Shape.stroke(diag(410.0, 10.0, 470.0, 86.0), color: ink, width: 1.0, roundCap: false))
        .shape(Shape.stroke(diag(420.0, 10.0, 480.0, 86.0), color: ink, width: 2.0, roundCap: false))
        .size(490, 96)
}

public func shapesView(_ s: ShapesState, _ cx: inout Cx<ShapesState>) -> El<ShapesState> {
    col()
        .key("root")
        .sizeFull()
        .p(24)
        .gap(16)
        .bg(bg)
        .child(text("Waveform: filled envelope, polyline, hairline").color(ink))
        .child(
            waveformEl(s.t, w: 260, h: 96)
                .key("wave")
                .size(520, 96)
                .bg(cardBg)
                .rounded(8)
        )
        .child(
            row()
                .gap(24)
                .child(
                    col()
                        .gap(8)
                        .child(text("Meters").color(ink))
                        .child(metersEl(s.t))
                )
                .child(
                    col()
                        .gap(8)
                        .child(text("Paths, a concave fill, line widths").color(ink))
                        .child(memo("curves", 0) { curvesEl().key("curves") })
                )
        )
}

@main
public enum RuneShapesApp {
    public static func makeSpec() -> AppSpec<ShapesState> {
        AppSpec<ShapesState>(
            title: "Shapes",
            size: Vec2(820, 360),
            state: ShapesState(),
            poll: { state, t, _ in
                guard !state.fixedSceneT else { return false }
                state.t = Float(t)
                return true
            },
            onKey: { state, event, _ in
                if event.key == .space {
                    state.t += 0.35
                    return true
                }
                return false
            },
            view: shapesView
        )
        .scene("t15") {
            $0.fixedSceneT = true
            $0.t = 1.5
        }
    }

    public static func main() throws {
        try RuneApp.run(makeSpec())
    }
}
