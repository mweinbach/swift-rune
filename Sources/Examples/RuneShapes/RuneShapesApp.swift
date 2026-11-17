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

    let envelope = topPts + topPts.reversed().map { Vec2($0.x, 2 * mid - $0.y) }
    let line: [Vec2] = (0..<n).map { i in
        Vec2(Float(i) * w / Float(n - 1), mid + sinf(Float(i) * 0.21 + t * 3) * mid * 0.8)
    }
    let waveform = Shape()
        .fill(envelope, color: soft)
        .stroke(line, width: 1.5, color: accent)
        .line([0, mid], [w, mid], width: 0.5, cap: .butt, color: ink)
        .viewBox(w, h)
    return canvas(waveform)
}

private func metersEl(_ t: Float) -> El<ShapesState> {
    var meters = Shape()
    for i in 0..<24 {
        let x = 4.0 + Float(i) * 10.0
        let v = level(t, i * 7) * 56.0 + 4.0
        meters = meters.line([x, 64], [x, 64 - v], width: 6, cap: .round, color: v > 48 ? warm : accent)
    }
    return canvas(meters).key("meters").size(244, 68)
}

private func curvesEl() -> El<ShapesState> {
    let wave = Path()
        .moveTo([4, 50])
        .cubicTo([40, -20], [80, 120], [116, 50])
        .quadTo([150, 0], [186, 50])
    let blob = Path()
        .moveTo([210, 30])
        .cubicTo([230, 0], [270, 0], [280, 30])
        .lineTo([260, 80])
        .lineTo([220, 80])
        .close()

    let star: [Vec2] = (0..<10).map { i in
        let a = Float(i) * .pi / 5 - .pi * 0.5
        let radius: Float = i.isMultiple(of: 2) ? 40 : 16
        return Vec2(340 + cosf(a) * radius, 46 + sinf(a) * radius)
    }
    let curves = Shape()
        .strokePath(wave, width: 3, cap: .round, color: warm)
        .fillPath(blob, color: accent)
        .strokePath(blob, width: 1, cap: .round, color: ink)
        .fill(star, color: ink)
        .line([400, 10], [460, 86], width: 0.5, cap: .butt, color: ink)
        .line([410, 10], [470, 86], width: 1, cap: .butt, color: ink)
        .line([420, 10], [480, 86], width: 2, cap: .butt, color: ink)
    return canvas(curves).size(490, 96)
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
