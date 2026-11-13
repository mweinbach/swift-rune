import Foundation
import Rune
import RuneMotion

/// Port of `crates/rune/examples/one_snap.rs`.
///
/// Concentric icon, vector shape, box fill and heading text inside an anchored card over a
/// scaled stage. Clicking `"stage"` zooms to `1.6×` and drifts the anchor diagonally on springs;
/// clicking `"badge"` swaps its inner `canvas` disc for the matching `SVGIcon` disc with `tx.instant()`.

private let ringIcon = SVGIcon(
    viewBox: 16.0,
    paths: [
        "M14.5 8C14.5 11.58985 11.58985 14.5 8 14.5C4.41015 14.5 1.5 11.58985 1.5 8C1.5 4.41015 4.41015 1.5 8 1.5C11.58985 1.5 14.5 4.41015 14.5 8Z",
    ],
    strokeWidth: 1.5
)

private let discIcon = SVGIcon(
    viewBox: 16.0,
    paths: [
        "M12 8C12 10.20914 10.20914 12 8 12C5.79086 12 4 10.20914 4 8C4 5.79086 5.79086 4 8 4C10.20914 4 12 5.79086 12 8Z",
    ],
    strokeWidth: nil
)

public struct OneSnapState: Sendable {
    public var zoomed: Bool
    public var swapped: Bool

    public init(zoomed: Bool = false, swapped: Bool = false) {
        self.zoomed = zoomed
        self.swapped = swapped
    }
}

private func discShape(_ color: Color) -> Shape {
    let pts: [Vec2] = (0..<64).map { k in
        let a = Float.pi * 2.0 * Float(k) / 64.0
        return Vec2(8.0 + 4.0 * cosf(a), 8.0 + 4.0 * sinf(a))
    }
    return Shape().fill(pts, color: color)
}

public func oneSnapView(_ s: OneSnapState, _ cx: inout Cx<OneSnapState>) -> El<OneSnapState> {
    let accent = oklch(0.63, 0.22, 27.0)
    let inner: El<OneSnapState>
    if s.swapped {
        inner = icon(discIcon, size: 16.0).key("disc").color(accent).absolute(x: 0.0, y: 0.0)
    } else {
        inner = canvas(discShape(accent)).key("disc").size(16.0, 16.0).absolute(x: 0.0, y: 0.0)
    }

    let badge: El<OneSnapState> = el()
        .key("badge")
        .size(16.0, 16.0)
        .child(icon(ringIcon, size: 16.0).key("ring").color(.white).absolute(x: 0.0, y: 0.0))
        .child(inner)
        .onClick { (state: inout OneSnapState, tx: inout Tx) in
            state.swapped.toggle()
            tx.instant()
        }

    let zoom: Float = s.zoomed ? 1.6 : 1.0
    let driftX: Float = s.zoomed ? 9.35 : 0.0
    let driftY: Float = s.zoomed ? 6.65 : 0.0

    let anchor: El<OneSnapState> = el()
        .key("anchor")
        .absolute(x: 18.2, y: 14.35)
        .size(28.0, 8.0)
        .offset(driftX, driftY)
        .animate(Spring(duration: 0.55, bounce: 0.0))

    let stage: El<OneSnapState> = col()
        .key("stage")
        .absolute(x: 24.0, y: 20.0)
        .size(180.0, 96.0)
        .rounded(10.0)
        .bg(oklch(0.26, 0.02, 250.0))
        .scale(zoom)
        .animate(Spring(duration: 0.45, bounce: 0.0))
        .origin(0.0, 0.0)
        .onClick { (state: inout OneSnapState) in
            state.zoomed.toggle()
        }
        .child(anchor)

    let title: El<OneSnapState> = text(s.swapped ? "Icon disc" : "Path disc")
        .key("title")
        .font(TextStyle(size: 15.0, weight: 600.0))
        .color(.white)

    let hud: El<OneSnapState> = row()
        .key("hud")
        .p(8.0)
        .gap(8.0)
        .itemsCenter()
        .rounded(9.0)
        .bg(oklch(0.32, 0.02, 250.0))
        .border(1.0, oklch(0.44, 0.02, 250.0))
        .child(badge)
        .child(title)
        .anchored("anchor", side: .bottom, align: .start, gap: 4.1)

    let root: El<OneSnapState> = col()
        .wFull()
        .hFull()
        .bg(oklch(0.18, 0.01, 250.0))
        .child(stage)
        .child(hud)
    return root
}

public func makeApp() -> App<OneSnapState> {
    App(
        title: "One snap",
        size: Vec2(360.0, 240.0),
        state: OneSnapState(),
        view: oneSnapView
    )
}

@main
enum RuneOneSnapMain {
    static func main() throws {
        try makeApp().run()
    }
}
