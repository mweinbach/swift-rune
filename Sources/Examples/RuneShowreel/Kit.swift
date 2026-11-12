import Foundation
import Rune
import RuneMotion

enum ShowreelKit {
    static let W: Float = 960.0
    static let H: Float = 540.0

    static let BG: UInt32 = 0x0b0b0d
    static let PANEL: UInt32 = 0x141417
    static let RAISED: UInt32 = 0x1b1b1f
    static let TEXT: UInt32 = 0xededef
    static let MUTED: UInt32 = 0x9a9aa3
    static let FAINT: UInt32 = 0x5f5f68

    static func c(_ hex: UInt32) -> Color {
        let r = UInt8((hex >> 16) & 0xff)
        let g = UInt8((hex >> 8) & 0xff)
        let b = UInt8(hex & 0xff)
        return Color.rgba8(r, g, b, 255)
    }

    static func ca(_ hex: UInt32, _ a: Float) -> Color {
        c(hex).alpha(a.clamped(to: 0...1))
    }

    static func hair() -> Color {
        ca(0xffffff, 0.08)
    }

    static func t<S>(_ s: String, _ size: Float, _ weight: Float, _ color: UInt32) -> El<S> {
        text(s).size(size).weight(weight).color(c(color))
    }

    static func ta<S>(_ s: String, _ size: Float, _ weight: Float, _ color: UInt32, _ alpha: Float) -> El<S> {
        text(s).size(size).weight(weight).color(ca(color, alpha.clamped(to: 0...1)))
    }

    static func mono<S>(_ s: String, _ size: Float, _ color: UInt32) -> El<S> {
        text(s).size(size).weight(500).mono().color(c(color))
    }

    static func monoA<S>(_ s: String, _ size: Float, _ color: UInt32, _ alpha: Float) -> El<S> {
        text(s).size(size).weight(500).mono().color(ca(color, alpha.clamped(to: 0...1)))
    }

    /// 0 -> 1 between `t0` and `t0 + dur`, smoothstep.
    static func ease(_ t: Double, _ t0: Double, _ dur: Double) -> Float {
        let x = Float(((t - t0) / dur).clamped(to: 0...1))
        return x * x * (3.0 - 2.0 * x)
    }

    static func sp(_ duration: Float, _ bounce: Float) -> Spring {
        Spring(duration: duration, bounce: bounce)
    }

    /// A value that starts at `from` and springs to each key's target at its time, carrying velocity
    /// across retargets (as an interrupted Rune spring does).
    static func track(_ t: Double, _ from: Float, _ keys: [(Double, Float, Spring)]) -> Float {
        var x = from
        var v: Float = 0.0
        var target = from
        var t0: Double = 0.0
        var spring = Spring(duration: 0.3, bounce: 0.0)
        for (tk, to, sp) in keys {
            if t < tk { break }
            let (nx, nv) = spring.sample(from: x, velocity: v, target: target, at: Float(tk - t0))
            x = nx
            v = nv
            target = to
            t0 = tk
            spring = sp
        }
        return spring.sample(from: x, velocity: v, target: target, at: Float(t - t0)).position
    }

    /// Press depth (0 -> 1 -> 0) for a tap at `tp`: down fast, back on a bouncy spring.
    static func pressed(_ t: Double, _ tp: Double) -> Float {
        track(t, 0.0, [
            (tp, 1.0, sp(0.12, 0.0)),
            (tp + 0.14, 0.0, sp(0.35, 0.45)),
        ])
    }

    /// An iPad-style round pointer at (x, y), centred, squeezed while pressed.
    static func pointer<S>(_ x: Float, _ y: Float, _ press: Float) -> El<S> {
        let r = 9.0 * (1.0 - 0.22 * press)
        return el()
            .key("pointer")
            .absolute(x: x - r, y: y - r)
            .size(2.0 * r, 2.0 * r)
            .rounded(r)
            .bg(ca(0xf4f4f6, 0.92))
            .border(1.0, ca(0x000000, 0.35))
            .shadow(Shadow(y: 2.0, blur: 8.0, color: ca(0x000000, 0.45)))
    }

    /// A pointer that follows `path` (time, x, y) on springs and presses at each time in `taps`.
    static func pointerAt<S>(
        _ t: Double,
        start: (Float, Float),
        path: [(Double, Float, Float)],
        taps: [Double]
    ) -> El<S> {
        let s = sp(0.55, 0.0)
        let kx = path.map { ($0.0, $0.1, s) }
        let ky = path.map { ($0.0, $0.2, s) }
        let x = track(t, start.0, kx)
        let y = track(t, start.1, ky)
        let k: [(Double, Float, Spring)] = taps.flatMap { tp in
            [(tp, Float(1.0), sp(0.12, 0.0)), (tp + 0.14, Float(0.0), sp(0.3, 0.4))]
        }
        return pointer(x, y, track(t, 0.0, k))
    }

    static func avatar<S>(_ letter: String, _ color: UInt32, _ size: Float) -> El<S> {
        el()
            .size(size, size)
            .rounded(size / 2.0)
            .bg(c(color))
            .center()
            .child(t(letter, size * 0.42, 600.0, 0x0b0b0d))
    }

    static func dot<S>(_ color: UInt32, _ size: Float) -> El<S> {
        el()
            .size(size, size)
            .rounded(size / 2.0)
            .bg(c(color))
    }
}

extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
