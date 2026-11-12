import Foundation
import Rune
import RuneKit

/// Port of `examples/overlay`: shared stroke SVG + live-offset remote cursor overlay
/// with click-through / interactive mode toggling and animated cursor trajectory.
private let strokeIcon = SVGIcon(
    viewBox: 240.0,
    paths: ["M 12 190 C 55 30 90 210 130 70 S 190 170 228 35"],
    strokeWidth: 4.0
)

private let overlayGreen = Color(r: 0.1, g: 0.85, b: 0.45, a: 1.0)
private let controlsBg = Color(r: 0.018, g: 0.024, b: 0.03, a: 1.0)

struct OverlayState {
    var overlay: Bool = false
    var clickThrough: Bool = true
    var cursor = Live<Vec2>(Vec2(120, 90))
}

private func cursorPoint(_ t: Double) -> Vec2 {
    let clamped = Float(min(t, 4.0))
    return Vec2(
        120.0 + 120.0 * sinf(clamped * 0.7),
        90.0 + 50.0 * sinf(clamped)
    )
}

func overlayView(_ s: OverlayState, _ cx: inout Cx<OverlayState>) -> El<OverlayState> {
    if s.overlay {
        return el()
            .sizeFull()
            .bg(Color(r: 0.02, g: 0.03, b: 0.04, a: 0.92))
            .onClick { state in
                state.clickThrough = true
                state.overlay = false
            }
            .child(
                icon(strokeIcon, size: 240)
                    .key("stroke")
                    .color(overlayGreen)
                    .absolute(x: 80, y: 80)
            )
            .child(
                el()
                    .key("remote-cursor")
                    .size(12, 18)
                    .rounded(3)
                    .bg(overlayGreen)
                    .absolute(x: 0, y: 0)
                    .liveOffset(s.cursor.binding)
            )
            .child(
                text(s.clickThrough ? "Overlay (click-through) — click to return" : "Overlay (interactive) — click to pass through")
                    .font(TextStyle(size: 11.5, weight: 400))
                    .color(overlayGreen.alpha(0.85))
                    .absolute(x: 20, y: 20)
            )
    }

    return col()
        .sizeFull()
        .p(40)
        .gap(20)
        .bg(controlsBg)
        .child(
            text("Display overlays")
                .font(Tok.Typography.body)
                .color(.white)
        )
        .child(
            row()
                .key("test-overlay-input")
                .role(.button)
                .label("Test overlay input")
                .p(16)
                .rounded(8)
                .bg(overlayGreen.alpha(0.15))
                .border(1, overlayGreen.alpha(0.35))
                .pressScale(0.97)
                .onClick { state in
                    state.clickThrough = false
                    state.overlay = true
                }
                .child(
                    text("Test overlay input")
                        .font(TextStyle(size: 13.0, weight: 500))
                        .color(overlayGreen)
                )
        )
        .child(
            row()
                .key("preview-overlay")
                .role(.button)
                .label("Preview overlay")
                .p(12)
                .rounded(8)
                .bg(Color.white.alpha(0.06))
                .pressScale(0.97)
                .onClick { state in
                    state.clickThrough = true
                    state.overlay = true
                }
                .child(
                    text("Preview overlay surface")
                        .font(TextStyle(size: 11.5, weight: 400))
                        .color(Color.white.alpha(0.75))
                )
        )
}

let spec = AppSpec<OverlayState>(
    title: "Rooms overlay example",
    size: Vec2(560, 440),
    state: OverlayState(),
    view: overlayView
)
.scene("controls") { $0.overlay = false }
.scene("overlay") {
    $0.overlay = true
    $0.cursor.snap(cursorPoint(1.2))
}

try RuneApp.run(spec)
