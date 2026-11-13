import Foundation
import Rune

/// Pixel-grid `ᚱUNE` wordmark + glint animation (`www/app/src/wordmark.rs`).
public enum WwwWordmark {
    public static let runeRows: [String] = [
        "###....", "####...", "##.##..", "##..##.", "##..##.", "##.##..", "####...", "##.##..", "##..##.", "##...##", "##...##",
    ]
    public static let uRows: [String] = [
        "##...##", "##...##", "##...##", "##...##", "##...##", "##...##", "##...##", "##...##", "##...##", "#######", ".#####.",
    ]
    public static let nRows: [String] = [
        "###...##", "####..##", "####..##", "####..##", "##.##.##", "##.##.##", "##.##.##", "##..####", "##..####", "##..####", "##...###",
    ]
    public static let eRows: [String] = [
        "######", "######", "##....", "##....", "#####.", "#####.", "##....", "##....", "##....", "######", "######",
    ]

    public static let cap: Int = 11
    public static let travel: Double = 0.7
    public static let rise: Double = 0.04
    public static let tau: Double = 0.18
    public static let glintSeconds: Double = travel + rise + tau * 6.0

    public enum Glow: Equatable, Sendable {
        case off
        case glint(Double)
        case lit(Float)
    }

    public enum Which: Equatable, Sendable {
        case masthead
        case brand
    }

    public struct Glyphs: Sendable {
        public let glyphs: [(rows: [String], x: Int32)]
        public let width: Int
        public let carve: [(x: Int32, y: Int32, order: Float)]

        public init() {
            var list: [(rows: [String], x: Int32)] = []
            for rows in [WwwWordmark.runeRows, WwwWordmark.uRows, WwwWordmark.nRows, WwwWordmark.eRows] {
                let x = list.last.map { WwwWordmark.fit(prev: $0.rows, at: $0.x, next: rows) } ?? 0
                list.append((rows, x))
            }
            let last = list.last!
            self.glyphs = list
            self.width = Int(last.x) + last.rows[0].count
            self.carve = WwwWordmark.carveOrder(WwwWordmark.runeRows)
        }
    }

    public struct Glints: Sendable {
        private var mastheadAt: Double?
        private var brandAt: Double?
        private var nextAt: Double?
        private var reduced: Bool = false
        private var seed: UInt32 = 0

        public init() {}

        public mutating func masthead(_ now: Double) {
            WwwWordmark.start(&mastheadAt, now: now)
        }

        public mutating func brand(_ now: Double) {
            WwwWordmark.start(&brandAt, now: now)
        }

        public mutating func mastheadVisible(_ on: Bool, reduced: Bool, now: Double) {
            self.reduced = reduced
            self.nextAt = on ? (now + pause()) : nil
        }

        private mutating func pause() -> Double {
            var x = (seed &+ 0x9e37_79b9) | 1
            x ^= x << 13
            x ^= x >> 17
            x ^= x << 5
            seed = x
            return 5.0 + 4.0 * Double(x) / Double(UInt32.max)
        }

        public mutating func tick(_ now: Double) -> (changed: Bool, moving: Bool, next: Double?) {
            if let at = nextAt, now >= at {
                if !reduced {
                    WwwWordmark.start(&mastheadAt, now: now)
                }
                nextAt = now + pause()
            }
            var changed = false
            var moving = false
            if let at = mastheadAt {
                changed = true
                if now - at >= WwwWordmark.glintSeconds {
                    mastheadAt = nil
                } else {
                    moving = true
                }
            }
            if let at = brandAt {
                changed = true
                if now - at >= WwwWordmark.glintSeconds {
                    brandAt = nil
                } else {
                    moving = true
                }
            }
            return (changed, moving, nextAt)
        }

        public func glow(_ which: Which, now: Double, reduced: Bool) -> Glow {
            let at: Double? = switch which {
            case .masthead: mastheadAt
            case .brand: brandAt
            }
            guard let at else { return .off }
            let t = now - at
            if reduced {
                return WwwWordmark.lit(t).map(Glow.lit) ?? .off
            }
            if t >= 0.0 && t < WwwWordmark.glintSeconds {
                return .glint(t)
            }
            return .off
        }
    }

    public static func inkCells(_ rows: [String]) -> [(Int32, Int32)] {
        var out: [(Int32, Int32)] = []
        for (y, r) in rows.enumerated() {
            for (x, byte) in r.utf8.enumerated() where byte == UInt8(ascii: "#") {
                out.append((Int32(x), Int32(y)))
            }
        }
        return out
    }

    private static func fit(prev: [String], at: Int32, next: [String]) -> Int32 {
        let a = inkCells(prev).map { ($0.0 + at, $0.1) }
        let b = inkCells(next)
        var x = at + 1
        while a.contains(where: { ax, ay in
            b.contains(where: { bx, by in abs(bx + x - ax) <= 1 && abs(by - ay) <= 1 })
        }) {
            x += 1
        }
        return x
    }

    private static func runs(rows: [String], dx: Int32, into out: inout [SIMD4<Float>]) {
        for (y, row) in rows.enumerated() {
            let bytes = Array(row.utf8)
            var x = 0
            while x < bytes.count {
                if bytes[x] != UInt8(ascii: "#") {
                    x += 1
                    continue
                }
                let start = x
                while x < bytes.count && bytes[x] == UInt8(ascii: "#") {
                    x += 1
                }
                out.append(SIMD4<Float>(Float(dx + Int32(start)), Float(y), Float(x - start), 1.0))
            }
        }
    }

    private static func rect(_ r: SIMD4<Float>) -> [Vec2] {
        [
            Vec2(r.x, r.y),
            Vec2(r.x + r.z, r.y),
            Vec2(r.x + r.z, r.y + r.w),
            Vec2(r.x, r.y + r.w),
        ]
    }

    private static func carveOrder(_ rows: [String]) -> [(x: Int32, y: Int32, order: Float)] {
        let path: [(Vec2, Vec2)] = [
            (Vec2(1.0, 0.5), Vec2(1.0, 10.5)),
            (Vec2(1.5, 0.5), Vec2(5.0, 3.5)),
            (Vec2(5.0, 3.5), Vec2(1.5, 6.5)),
            (Vec2(2.5, 6.5), Vec2(6.0, 10.5)),
        ]
        let lens = path.map { hypotf($0.1.x - $0.0.x, $0.1.y - $0.0.y) }
        let total: Float = lens.reduce(0, +)
        return inkCells(rows).map { x, y in
            let cx = Float(x) + 0.5
            let cy = Float(y) + 0.5
            var best = Float.infinity
            var arc: Float = 0
            var acc: Float = 0
            for (i, (a, b)) in path.enumerated() {
                let dx = b.x - a.x
                let dy = b.y - a.y
                let p = (((cx - a.x) * dx + (cy - a.y) * dy) / (dx * dx + dy * dy)).clamped(to: 0...1)
                let d = hypotf(a.x + dx * p - cx, a.y + dy * p - cy)
                if d < best - 1e-6 {
                    best = d
                    arc = acc + p * lens[i]
                }
                acc += lens[i]
            }
            return (x, y, arc / total)
        }
    }

    private static func easeInOut(_ p: Double) -> Double {
        if p < 0.5 { return 2.0 * p * p }
        return 1.0 - pow(-2.0 * p + 2.0, 2.0) / 2.0
    }

    private static func passes(_ order: Float) -> Double {
        var lo = 0.0
        var hi = 1.0
        for _ in 0..<20 {
            let m = (lo + hi) * 0.5
            if easeInOut(m) < Double(order) { lo = m } else { hi = m }
        }
        return (lo + hi) * 0.5 * travel
    }

    public static func heat(_ order: Float, _ t: Double) -> Float {
        let since = t - passes(order)
        if since < 0.0 {
            return 0.0
        } else if since < rise {
            return Float(since / rise)
        } else {
            let h = Float(exp(-(since - rise) / tau))
            return h > 0.004 ? h : 0.0
        }
    }

    public static func lit(_ t: Double) -> Float? {
        let fade = 0.09
        let hold = 0.5
        let level: Double
        if t < 0.0 {
            return nil
        } else if t < fade {
            level = t / fade
        } else if t < fade + hold {
            level = 1.0
        } else if t < 2.0 * fade + hold {
            level = 1.0 - (t - fade - hold) / fade
        } else {
            return nil
        }
        return Float(level)
    }

    private static func start(_ at: inout Double?, now: Double) {
        if at.map({ now - $0 >= glintSeconds }) ?? true {
            at = now
        }
    }

    public static func wordmark<State>(_ g: Glyphs, cell: Float, glow: Glow) -> El<State> {
        var rects: [SIMD4<Float>] = []
        for (rows, x) in g.glyphs {
            runs(rows: rows, dx: x, into: &rects)
        }
        var shape = Shape().viewBox(Float(g.width), Float(cap))
        for r in rects {
            shape = shape.fill(rect(r), color: WwwTokens.ink)
        }
        let hot = WwwTokens.glint
        for (x, y, order) in g.carve {
            let h: Float = switch glow {
            case .off: 0.0
            case .glint(let t): heat(order, t)
            case .lit(let level): level
            }
            if h > 0.0 {
                shape = shape.fill(rect(SIMD4<Float>(Float(x), Float(y), 1.0, 1.0)), color: hot.alpha(h))
            }
        }
        return canvas(shape)
            .key("wordmark")
            .size(cell * Float(g.width), cell * Float(cap))
            .a11yHidden()
    }
}
