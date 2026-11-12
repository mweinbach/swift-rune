import Foundation
import Rune

/// Shared chart helpers: series palette that themes with `MermaidTheme`, text contrast ink,
/// smaller/bolder fonts, smooth S-curves, and horizontal axes with grid lines (`rune_mermaid::chart`).
enum MermaidChart {
    /// Series hues, spread so neighbours never look alike.
    private static let hues: [Float] = [255.0, 25.0, 150.0, 70.0, 305.0, 195.0, 350.0, 110.0, 280.0, 170.0, 45.0, 225.0]

    static func isDark(_ paint: MermaidTheme) -> Bool {
        paint.surface.toOKLab()[0] < 0.5
    }

    static func hue(_ i: Int) -> Float {
        hues[i % hues.count]
    }

    /// A series' solid colour: pie slices, lines, swatches.
    static func solid(_ paint: MermaidTheme, hue h: Float) -> Color {
        isDark(paint) ? oklch(0.62, 0.12, h) : oklch(0.72, 0.12, h)
    }

    /// A series' quiet fill, for bars that carry text and bands behind rows.
    static func soft(_ paint: MermaidTheme, hue h: Float) -> Color {
        isDark(paint) ? oklch(0.38, 0.07, h) : oklch(0.9, 0.05, h)
    }

    /// A series' outline, for `soft` fills.
    static func strong(_ paint: MermaidTheme, hue h: Float) -> Color {
        isDark(paint) ? oklch(0.7, 0.12, h) : oklch(0.56, 0.13, h)
    }

    /// Text that reads on `fill`.
    static func ink(_ fill: Color) -> Color {
        fill.toOKLab()[0] > 0.6 ? oklch(0.22, 0.01, 260.0) : oklch(0.97, 0.005, 260.0)
    }

    /// The diagram's type a point smaller: axis ticks, legends, notes.
    static func small(_ paint: MermaidTheme) -> TextStyle {
        var f = paint.font
        f.size = max(1.0, paint.font.size - 1.0)
        let lh = paint.font.lineHeight ?? (paint.font.size * 1.38)
        f.lineHeight = max(1.0, lh - 2.0)
        return f
    }

    static func bold(_ font: TextStyle) -> TextStyle {
        var f = font
        f.weight = 600.0
        return f
    }

    /// A curve from `a` to `b` that leaves and arrives level (or upright when `upright`).
    static func sCurve(_ a: Vec2, _ b: Vec2, upright: Bool) -> [Vec2] {
        let c1: Vec2
        let c2: Vec2
        if upright {
            let m = (a.y + b.y) * 0.5
            c1 = Vec2(a.x, m)
            c2 = Vec2(b.x, m)
        } else {
            let m = (a.x + b.x) * 0.5
            c1 = Vec2(m, a.y)
            c2 = Vec2(m, b.y)
        }
        return (0...20).map { i in
            let t = Float(i) / 20.0
            let u = 1.0 - t
            let k0 = u * u * u
            let k1 = 3.0 * u * u * t
            let k2 = 3.0 * u * t * t
            let k3 = t * t * t
            return Vec2(
                k0 * a.x + k1 * c1.x + k2 * c2.x + k3 * b.x,
                k0 * a.y + k1 * c1.y + k2 * c2.y + k3 * b.y
            )
        }
    }

    /// Grid lines from `top` to `bottom` at each tick's x, between `x0` and `x1`, with its label
    /// centred under `bottom` and kept inside `[x0, x1]` (one that would overlap the last is dropped).
    static func axisX(
        _ c: inout Canvas,
        ticks: [(Float, Measured)],
        xRange: (Float, Float),
        yRange: (Float, Float),
        font: TextStyle,
        paint: MermaidTheme
    ) {
        let (x0, x1) = xRange
        let (top, bottom) = yRange
        let grid = paint.text.alpha(0.08)
        c.stroke([Vec2(x0, bottom), Vec2(x1, bottom)], closed: false, width: 1.0, color: paint.surfaceBorder)
        var right = -Float.greatestFiniteMagnitude
        for (x, m) in ticks {
            if x < x0 - 0.5 || x > x1 + 0.5 { continue }
            c.stroke([Vec2(x, top), Vec2(x, bottom)], closed: false, width: 1.0, color: grid)
            c.stroke([Vec2(x, bottom), Vec2(x, bottom + 4.0)], closed: false, width: 1.0, color: paint.surfaceBorder)
            let left = min(max(x - m.size.x * 0.5, x0), max(x1 - m.size.x, x0))
            if left < right + 8.0 { continue }
            c.labelAt(m, at: Vec2(left, bottom + 6.0), font: font, color: paint.muted, align: .leading)
            right = left + m.size.x
        }
    }
}
