import Foundation
#if os(Android)
import Android
#endif
import RuneRef
#if canImport(simd)
import simd
#endif

// MARK: - Authored Motion Intent & Commit Reasons (`el/motion.rs`, `runtime/commit/why.rs`)

/// Authored motion traits for `El.motionIntent(...)`, inherited by descendants (`rune::MotionIntent`).
public struct MotionIntent: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let none = MotionIntent([])
    public static let overshoot = MotionIntent(rawValue: 1 << 0)
    public static let recoil = MotionIntent(rawValue: 1 << 1)
    public static let jiggle = MotionIntent(rawValue: 1 << 2)
    public static let impulse = MotionIntent(rawValue: 1 << 3)
    public static let step = MotionIntent(rawValue: 1 << 4)
    public static let cut = MotionIntent(rawValue: 1 << 5)
    public static let pulse = MotionIntent(rawValue: 1 << 6)

    public static let bounce: MotionIntent = [.overshoot, .recoil, .jiggle]
    public static let kick: MotionIntent = [.bounce, .impulse]
    public static let typing: MotionIntent = [.step, .cut]
}

/// Bitflags explaining why a frame committed (`runtime::CommitWhy`).
public enum CommitWhy {
    public static let poll: UInt16 = 1
    public static let input: UInt16 = 2
    public static let layout: UInt16 = 4
    public static let read: UInt16 = 8
    public static let dirty: UInt16 = 16
    public static let relayout: UInt16 = 32
    public static let settle: UInt16 = 64
    public static let virtual: UInt16 = 128
    public static let route: UInt16 = 256
    public static let instant: UInt16 = 512

    public static let namesList: [String] = [
        "poll", "input", "layout", "read", "dirty",
        "relayout", "settle", "virtual", "route", "instant"
    ]

    public static func names(_ bits: UInt16) -> [String] {
        var out: [String] = []
        for (i, n) in namesList.enumerated() where (bits & (1 << i)) != 0 {
            out.append(n)
        }
        return out
    }
}

// MARK: - Paint Snapshot & Channels (`motion_gate/check/paint.rs`)

/// Per-frame painted properties for an element (`motion_gate::check::paint::Paint`).
public struct MotionGatePaint: Sendable, Equatable {
    public static let colorCount = 6
    public static let cFill = 0
    public static let cBorder = 1
    public static let cText = 2
    public static let cShadow = 3
    public static let cGradient = 4
    public static let cOutline = 5

    public static let sizeCount = 5
    public static let sRadius = 0
    public static let sBorder = 1
    public static let sBlur = 2
    public static let sBackdrop = 3
    public static let sShadow = 4

    public var colors: [Color]
    public var sizes: [Float]
    public var gradientEnd: Color
    public var effect: SIMD4<Float>?
    public var image: (UInt64, UInt64)?
    public var rank: UInt32
    public var intent: UInt16
    public var instant: Bool
    public var atOnce: UInt16
    public var pointer: SIMD2<Float>

    public init(
        colors: [Color] = Array(repeating: .transparent, count: MotionGatePaint.colorCount),
        sizes: [Float] = Array(repeating: 0, count: MotionGatePaint.sizeCount),
        gradientEnd: Color = .transparent,
        effect: SIMD4<Float>? = nil,
        image: (UInt64, UInt64)? = nil,
        rank: UInt32 = 0,
        intent: UInt16 = 0,
        instant: Bool = false,
        atOnce: UInt16 = 0,
        pointer: SIMD2<Float> = .zero
    ) {
        self.colors = colors.count == Self.colorCount ? colors : Array((colors + Array(repeating: .transparent, count: Self.colorCount)).prefix(Self.colorCount))
        self.sizes = sizes.count == Self.sizeCount ? sizes : Array((sizes + Array(repeating: 0, count: Self.sizeCount)).prefix(Self.sizeCount))
        self.gradientEnd = gradientEnd
        self.effect = effect
        self.image = image
        self.rank = rank
        self.intent = intent
        self.instant = instant
        self.atOnce = atOnce
        self.pointer = pointer
    }

    public static func == (lhs: MotionGatePaint, rhs: MotionGatePaint) -> Bool {
        lhs.colors == rhs.colors &&
        lhs.sizes == rhs.sizes &&
        lhs.gradientEnd == rhs.gradientEnd &&
        lhs.effect == rhs.effect &&
        lhs.image?.0 == rhs.image?.0 &&
        lhs.image?.1 == rhs.image?.1 &&
        lhs.rank == rhs.rank &&
        lhs.intent == rhs.intent &&
        lhs.instant == rhs.instant &&
        lhs.atOnce == rhs.atOnce &&
        lhs.pointer == rhs.pointer
    }

    public func isAtOnce(_ channelIndex: Int) -> Bool {
        (atOnce & (1 << channelIndex)) != 0
    }

    public func intends(_ any: MotionIntent) -> Bool {
        (intent & any.rawValue) != 0
    }

    public var showsCorners: Bool {
        colors[Self.cFill].a > 0.02 ||
        (colors[Self.cBorder].a > 0.02 && sizes[Self.sBorder] > 0.0) ||
        colors[Self.cGradient].a > 0.02 ||
        sizes[Self.sBackdrop] > 0.0
    }

    public var opaque: Bool {
        colors[Self.cFill].a > 0.6 || colors[Self.cGradient].a > 0.6 || image != nil
    }
}

public enum MotionGatePaintUtils {
    public typealias V6 = (Float, Float, Float, Float, Float, Float)

    @inline(__always)
    static func overPremul(_ src: SIMD4<Float>, _ dst: SIMD4<Float>) -> SIMD4<Float> {
        let inv = 1.0 - src.w
        return SIMD4<Float>(
            src.x + dst.x * inv,
            src.y + dst.y * inv,
            src.z + dst.z * inv,
            src.w + dst.w * inv
        )
    }

    @inline(__always)
    static func premulColor(_ c: Color, _ opacity: Float = 1.0) -> SIMD4<Float> {
        let a = c.a * opacity
        return SIMD4<Float>(c.r * a, c.g * a, c.b * a, a)
    }

    /// Ottosson's OKLab toe lightness (`paint::toe`).
    public static func toe(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let k1: Float = 0.206
        let k2: Float = 0.03
        let k3: Float = (1.0 + k1) / (1.0 + k2)
        let l = lab.x
        let x = k3 * l - k1
        let lr = 0.5 * (x + sqrt(max(0.0, x * x + 4.0 * k2 * k3 * l)))
        let s = l > 1e-4 ? (lr / l) : 0.0
        return SIMD3<Float>(lr, lab.y * s, lab.z * s)
    }

    static func seenLab(_ c: Color) -> SIMD3<Float> {
        let lab = c.toOKLab()
        return toe(SIMD3<Float>(lab[0], lab[1], lab[2]))
    }

    public static func oklabDeltaE(_ a: Color, _ b: Color) -> Float {
        func onBg(_ c: Color, _ bg: Color) -> SIMD3<Float> {
            let mixed = overPremul(premulColor(c), premulColor(bg))
            return seenLab(Color(r: mixed.x, g: mixed.y, b: mixed.z, a: mixed.w))
        }
        var maxDe: Float = 0
        for bg in [Color.black, Color.white] {
            let x = onBg(a, bg)
            let y = onBg(b, bg)
            let d = x - y
            maxDe = max(maxDe, sqrt(d.x * d.x + d.y * d.y + d.z * d.z))
        }
        return maxDe
    }

    public static func areaWeight(_ area: Float) -> Float {
        if area < 16.0 { return 0.0 }
        return pow(area / 1600.0, 0.25).clamped(to: 0.5...2.5)
    }

    private static func rectArea(_ r: SIMD4<Float>) -> Float {
        max(0.0, r.z) * max(0.0, r.w)
    }

    private static func ringArea(_ r: SIMD4<Float>, width: Float) -> Float {
        min(2.0 * (r.z + r.w) * max(0.0, width), r.z * r.w)
    }

    private static func labVec(_ c: Color) -> V6 {
        func onBg(_ bg: Color) -> SIMD3<Float> {
            let mixed = overPremul(premulColor(c), premulColor(bg))
            return seenLab(Color(r: mixed.x, g: mixed.y, b: mixed.z, a: mixed.w))
        }
        let k = onBg(.black)
        let w = onBg(.white)
        let denom: Float = 0.08 * Float(2.0).squareRoot()
        return (k.x / denom, k.y / denom, k.z / denom, w.x / denom, w.y / denom, w.z / denom)
    }

    private static func sizeVec(_ v: Float, unit: Float) -> V6 {
        (v / unit, 0, 0, 0, 0, 0)
    }

    private static func tokenVec(_ h: UInt64) -> V6 {
        var x = h ^ 0x9E37_79B9_7F4A_7C15
        func next() -> Float {
            x ^= x >> 33
            x = x &* 0xff51_afd7_ed55_8ccd
            x ^= x >> 29
            let f = Float(x >> 40) / Float(UInt64(1) << 24) * 2.0 - 1.0
            return f / 1.41
        }
        return (next(), next(), next(), next(), next(), next())
    }

    public struct Channel: Sendable {
        public let name: String
        public let embed: @Sendable (MotionGatePaint) -> V6
        public let weight: @Sendable (MotionGatePaint, SIMD4<Float>) -> Float
    }

    public static let channels: [Channel] = [
        Channel(name: "fill", embed: { labVec($0.colors[MotionGatePaint.cFill]) }, weight: { _, r in areaWeight(rectArea(r)) }),
        Channel(name: "border", embed: { labVec($0.colors[MotionGatePaint.cBorder]) }, weight: { p, r in areaWeight(ringArea(r, width: max(p.sizes[MotionGatePaint.sBorder], 1.0)) * 6.0) }),
        Channel(name: "text-color", embed: { labVec($0.colors[MotionGatePaint.cText]) }, weight: { _, r in areaWeight(0.4 * rectArea(r)) }),
        Channel(name: "shadow", embed: { labVec($0.colors[MotionGatePaint.cShadow]) }, weight: { _, r in areaWeight(0.5 * rectArea(r)) }),
        Channel(name: "gradient", embed: {
            let a = labVec($0.colors[MotionGatePaint.cGradient])
            let b = labVec($0.gradientEnd)
            return ((a.0 + b.0) * 0.5, (a.1 + b.1) * 0.5, (a.2 + b.2) * 0.5, (a.3 + b.3) * 0.5, (a.4 + b.4) * 0.5, (a.5 + b.5) * 0.5)
        }, weight: { _, r in areaWeight(rectArea(r)) }),
        Channel(name: "outline", embed: { labVec($0.colors[MotionGatePaint.cOutline]) }, weight: { _, r in areaWeight(ringArea(r, width: 2.0) * 6.0) }),
        Channel(name: "radius", embed: { sizeVec($0.sizes[MotionGatePaint.sRadius], unit: 3.0) }, weight: { p, _ in p.showsCorners ? 1.0 : 0.0 }),
        Channel(name: "border-width", embed: { sizeVec($0.sizes[MotionGatePaint.sBorder], unit: 1.0) }, weight: { p, _ in p.colors[MotionGatePaint.cBorder].a > 0.05 ? 1.0 : 0.0 }),
        Channel(name: "blur", embed: { sizeVec($0.sizes[MotionGatePaint.sBlur], unit: 2.0) }, weight: { _, _ in 1.0 }),
        Channel(name: "backdrop-blur", embed: { sizeVec($0.sizes[MotionGatePaint.sBackdrop], unit: 4.0) }, weight: { _, _ in 1.0 }),
        Channel(name: "shadow-blur", embed: { sizeVec($0.sizes[MotionGatePaint.sShadow], unit: 4.0) }, weight: { p, _ in p.colors[MotionGatePaint.cShadow].a > 0.05 ? 1.0 : 0.0 }),
        Channel(name: "effect", embed: {
            if let d = $0.effect {
                return (d.x / 0.5, d.y / 0.5, d.z / 0.5, d.w / 0.5, 0.0, 2.0)
            }
            return (0, 0, 0, 0, 0, 0)
        }, weight: { _, r in rectArea(r) >= 16.0 ? 1.0 : 0.0 }),
        Channel(name: "image", embed: {
            if let img = $0.image {
                return tokenVec(img.0 &* 31 &+ img.1)
            }
            return (0, 0, 0, 0, 0, 0)
        }, weight: { _, r in rectArea(r) >= 16.0 ? 1.0 : 0.0 })
    ]

    public static func atOnceBits(motion: Bool, blur: Bool?) -> UInt16 {
        let sprung: Set<String> = ["fill", "border", "shadow", "gradient", "outline", "radius", "shadow-blur"]
        let blurs = blur ?? motion
        var bits: UInt16 = 0
        for (i, ch) in channels.enumerated() {
            if (motion && sprung.contains(ch.name)) || (blurs && ch.name == "blur") {
                bits |= (1 << i)
            }
        }
        return bits
    }

    public static func swatch(_ p: MotionGatePaint, channel: String) -> Color? {
        switch channel {
        case "fill": return p.colors[MotionGatePaint.cFill]
        case "border": return p.colors[MotionGatePaint.cBorder]
        case "text-color": return p.colors[MotionGatePaint.cText]
        case "shadow": return p.colors[MotionGatePaint.cShadow]
        case "gradient": return p.colors[MotionGatePaint.cGradient]
        case "outline": return p.colors[MotionGatePaint.cOutline]
        default: return nil
        }
    }

    public static func value(_ p: MotionGatePaint, channel: String) -> String {
        if let c = swatch(p, channel: channel) {
            return c.hexString()
        }
        switch channel {
        case "radius": return String(format: "%.1f", p.sizes[MotionGatePaint.sRadius])
        case "border-width": return String(format: "%.1f", p.sizes[MotionGatePaint.sBorder])
        case "blur": return String(format: "%.1f", p.sizes[MotionGatePaint.sBlur])
        case "backdrop-blur": return String(format: "%.1f", p.sizes[MotionGatePaint.sBackdrop])
        case "shadow-blur": return String(format: "%.1f", p.sizes[MotionGatePaint.sShadow])
        case "effect":
            if let d = p.effect {
                return String(format: "[%.2f %.2f %.2f %.2f]", d.x, d.y, d.z, d.w)
            }
            return "none"
        case "image":
            if let img = p.image {
                return "#\(img.0).\(img.1)"
            }
            return "none"
        case "z-order":
            return "\(p.rank)"
        default:
            return ""
        }
    }
}

// MARK: - Series Discontinuities (`motion_gate/check/series.rs`)

public enum MotionGateSeries {
    public typealias V6 = MotionGatePaintUtils.V6

    public struct Tune: Sendable {
        public var snap: Float
        public var flash: Float
        public var still: Float
        public var horizon: Int
        public var rest: (Int, Int)

        public init(snap: Float, flash: Float, still: Float, horizon: Int, rest: (Int, Int)) {
            self.snap = snap
            self.flash = flash
            self.still = still
            self.horizon = horizon
            self.rest = rest
        }
    }

    public struct Event: Sendable, Equatable {
        public var kind: String
        public var k: Int
        public var span: (Int, Int)
        public var size: Float

        public static func == (lhs: Event, rhs: Event) -> Bool {
            lhs.kind == rhs.kind && lhs.k == rhs.k && lhs.span.0 == rhs.span.0 && lhs.span.1 == rhs.span.1 && lhs.size == rhs.size
        }
    }

    public static func dist(_ a: V6, _ b: V6) -> Float {
        let d0 = a.0 - b.0
        let d1 = a.1 - b.1
        let d2 = a.2 - b.2
        let d3 = a.3 - b.3
        let d4 = a.4 - b.4
        let d5 = a.5 - b.5
        return sqrt(d0 * d0 + d1 * d1 + d2 * d2 + d3 * d3 + d4 * d4 + d5 * d5)
    }

    public static func offPath(_ p: V6, _ a: V6, _ b: V6) -> Float {
        let ab = (b.0 - a.0, b.1 - a.1, b.2 - a.2, b.3 - a.3, b.4 - a.4, b.5 - a.5)
        let len2 = ab.0 * ab.0 + ab.1 * ab.1 + ab.2 * ab.2 + ab.3 * ab.3 + ab.4 * ab.4 + ab.5 * ab.5
        if len2 < 1e-12 { return dist(p, a) }
        let dot = (p.0 - a.0) * ab.0 + (p.1 - a.1) * ab.1 + (p.2 - a.2) * ab.2
            + (p.3 - a.3) * ab.3 + (p.4 - a.4) * ab.4 + (p.5 - a.5) * ab.5
        let t = (dot / len2).clamped(to: 0.0...1.0)
        let q: V6 = (a.0 + ab.0 * t, a.1 + ab.1 * t, a.2 + ab.2 * t, a.3 + ab.3 * t, a.4 + ab.4 * t, a.5 + ab.5 * t)
        return dist(p, q)
    }

    public static func events(_ vals: [V6?], tune: Tune, weight: (Int) -> Float) -> [Event] {
        let n = vals.count
        func d(_ k: Int) -> Float? {
            if k <= 0 || k >= n { return nil }
            guard let cur = vals[k], let prev = vals[k - 1] else { return nil }
            return dist(cur, prev)
        }
        func still(_ k: Int) -> Bool {
            guard let x = d(k) else { return true }
            return x < tune.still
        }

        var out: [Event] = []
        var taken = Array(repeating: false, count: n)

        if n > 1 {
            for k in 1..<n {
                guard let step = d(k) else { continue }
                let w = weight(k)
                if w <= 0.0 || step * w < min(tune.flash, tune.snap) { continue }
                let prev = d(k - 1) ?? 0.0
                let next = d(k + 1) ?? 0.0
                guard let a = vals[k - 1], let b = vals[k] else { continue }

                if prev < step / 4.0 {
                    var m = k + 1
                    let limit = min(n, k + tune.horizon + 1)
                    while m < limit && vals[m] != nil && !(still(m) && still(m + 1)) {
                        m += 1
                    }
                    let restIdx = min(m, n - 1)
                    if let rest = vals[restIdx] ?? vals[m - 1] {
                        let e = offPath(b, a, rest)
                        if e >= 0.5 * step && e * w >= tune.flash {
                            out.append(Event(kind: "flash", k: k, span: (k - 1, restIdx), size: e))
                            taken[k] = true
                            if let back = (k + 1...restIdx).first(where: { j in (d(j) ?? 0) >= step / 2.0 }) {
                                taken[back] = true
                            }
                            continue
                        }
                    }
                }

                if next < step / 4.0 && !taken[k] {
                    let from = max(2, k - tune.horizon)
                    if from < k - 1 {
                        if let j = (from..<(k - 1)).reversed().first(where: { still($0) && still($0 - 1) && vals[$0] != nil }),
                           ((j + 1)..<k).allSatisfy({ i in (d(i) ?? Float.infinity) < step / 2.0 }),
                           let s = vals[j] {
                            let e = offPath(a, s, b)
                            if e >= 0.5 * step && e * w >= tune.flash {
                                out.append(Event(kind: "flash", k: k, span: (j, k), size: e))
                                taken[k] = true
                                continue
                            }
                        }
                    }
                }

                if !taken[k] && step * w >= tune.snap && prev < step / 4.0 && next < step / 4.0 {
                    out.append(Event(kind: "snap", k: k, span: (k - 1, k), size: step))
                }
            }
        }

        var segs: [(Int, Int)] = []
        var k = 1
        while k < n {
            if (d(k) ?? 0.0) < tune.still {
                k += 1
                continue
            }
            let a = k
            while k < n, let x = d(k), x >= tune.still {
                k += 1
            }
            segs.append((a, k - 1))
        }

        if segs.count >= 2 {
            for idx in 1..<segs.count {
                let (a1, b1) = segs[idx - 1]
                let (a2, b2) = segs[idx]
                let rest = a2 - b1 - 1
                if rest < tune.rest.0 || rest > tune.rest.1 { continue }
                if (a1...b2).contains(where: { vals[$0] == nil }) { continue }
                guard let v0 = vals[a1 - 1], let v1 = vals[b1], let r = vals[a2 - 1], let v2 = vals[b2] else { continue }
                let first = dist(v0, v1)
                let second = dist(r, v2)
                let wk = weight(a2)
                if first * wk < tune.flash || second * wk < tune.flash { continue }
                let dot = (v1.0 - v0.0) * (v2.0 - r.0) + (v1.1 - v0.1) * (v2.1 - r.1) +
                          (v1.2 - v0.2) * (v2.2 - r.2) + (v1.3 - v0.3) * (v2.3 - r.3) +
                          (v1.4 - v0.4) * (v2.4 - r.4) + (v1.5 - v0.5) * (v2.5 - r.5)
                if dot > 0.7 * first * second && !(taken[a2] || out.contains(where: { $0.k == a1 || $0.k == a2 })) {
                    out.append(Event(kind: "changes-twice", k: a2, span: (a1 - 1, b2), size: first + second))
                }
            }
        }

        out.sort { $0.k < $1.k }
        return out
    }
}

// MARK: - Coarse Window Grid & CPU Raster (`motion_gate/check/raster.rs`)

public final class MotionGateGrid: @unchecked Sendable {
    public static let cellSize: Float = 12.0
    private static let quant: Float = 8192.0

    public let w: Int
    public let h: Int
    private let labData: [SIMD3<Int16>]

    private init(w: Int, h: Int, cells: [SIMD4<Float>]) {
        self.w = w
        self.h = h
        self.labData = cells.map { c in
            let mixed = MotionGatePaintUtils.overPremul(c, SIMD4<Float>(0, 0, 0, 1))
            let lab = Color(r: mixed.x, g: mixed.y, b: mixed.z, a: 1.0).toOKLab()
            return SIMD3<Int16>(
                Int16((lab[0] * Self.quant).rounded().clamped(to: -32767...32767)),
                Int16((lab[1] * Self.quant).rounded().clamped(to: -32767...32767)),
                Int16((lab[2] * Self.quant).rounded().clamped(to: -32767...32767))
            )
        }
    }

    public func lab(_ i: Int) -> SIMD3<Float> {
        let q = labData[i]
        return SIMD3<Float>(Float(q.x) / Self.quant, Float(q.y) / Self.quant, Float(q.z) / Self.quant)
    }

    public func color(_ i: Int) -> Color {
        let v = lab(i)
        return Color.fromOKLab([v.x, v.y, v.z, 1.0])
    }

    public func rect(_ i: Int) -> SIMD4<Float> {
        SIMD4<Float>(Float(i % w) * Self.cellSize, Float(i / w) * Self.cellSize, Self.cellSize, Self.cellSize)
    }

    public static func dims(_ size: (Float, Float)) -> (Int, Int) {
        (
            max(1, Int(ceil(size.0 / cellSize))),
            max(1, Int(ceil(size.1 / cellSize)))
        )
    }

    public struct ApronKey: Hashable, Sendable {
        public let u0: UInt32
        public let u1: UInt32
        public let page: UInt32

        public init(_ i: RenderInstance) {
            self.u0 = i.uv.x.bitPattern
            self.u1 = i.uv.y.bitPattern
            self.page = i.params.z.bitPattern
        }
    }

    private struct Draw {
        var outer: SIMD4<Float>
        var hole: SIMD4<Float>?
        var density: Float
        var color: SIMD4<Float>
        var bottom: SIMD4<Float>?
    }

    private struct Scope {
        var cells: [SIMD4<Float>]
        var opacity: Float
        var clip: SIMD4<Float>
    }

    private static func boxed(_ r: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(r.x, r.y, r.x + r.z, r.y + r.w)
    }

    private static func meet(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(max(a.x, b.x), max(a.y, b.y), min(a.z, b.z), min(a.w, b.w))
    }

    private static func grow(_ b: SIMD4<Float>, _ d: Float) -> SIMD4<Float> {
        SIMD4<Float>(b.x - d, b.y - d, b.z + d, b.w + d)
    }

    private static func overlapArea(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
        let m = meet(a, b)
        return max(0.0, m.z - m.x) * max(0.0, m.w - m.y)
    }

    private static func draws(_ q: RenderInstance, apron: Bool) -> [Draw] {
        let kind = q.params.y
        let outer = boxed(q.rect)
        func solid(_ color: SIMD4<Float>, _ density: Float, bottom: SIMD4<Float>? = nil) -> Draw {
            Draw(outer: outer, hole: nil, density: density, color: color, bottom: bottom)
        }
        func ring(_ color: SIMD4<Float>, _ width: Float, _ density: Float, bottom: SIMD4<Float>? = nil) -> Draw {
            Draw(outer: outer, hole: grow(outer, -width), density: density, color: color, bottom: bottom)
        }

        var out: [Draw] = []
        if kind == KIND_RECT {
            out.append(solid(q.fill, 1.0))
            if q.params.x > 0.0 {
                out.append(ring(q.border, q.params.x, 1.0))
            }
        } else if kind == KIND_GRADIENT {
            if q.params.x > 0.0 {
                out.append(ring(q.border, q.params.x, 1.0, bottom: q.uv))
            } else {
                out.append(solid(q.fill, 1.0, bottom: q.uv))
            }
        } else if kind == KIND_GLYPH {
            let t: SIMD2<Float> = (apron && q.uv.z > 2.0 && q.uv.w > 2.0)
                ? SIMD2<Float>(q.rect.z / q.uv.z, q.rect.w / q.uv.w)
                : .zero
            let core = SIMD4<Float>(outer.x + t.x, outer.y + t.y, outer.z - t.x, outer.w - t.y)
            out.append(Draw(outer: core, hole: nil, density: 0.35, color: q.fill, bottom: nil))
        } else if kind == KIND_RADIAL {
            let t = abs(q.params.w.truncatingRemainder(dividingBy: 2.0) - q.params.x.truncatingRemainder(dividingBy: 2.0)).clamped(to: 0.0...1.0)
            let mid = q.fill + (q.border - q.fill) * 0.5
            out.append(solid(mid, t))
        } else if kind == KIND_DASHED {
            out.append(ring(q.fill, q.params.x, 0.5, bottom: q.border))
        } else if kind == KIND_SEGMENT {
            let x0 = q.radii.x, y0 = q.radii.y, x1 = q.radii.z, y1 = q.radii.w
            let hw = q.params.x
            let b = SIMD4<Float>(min(x0, x1) - hw, min(y0, y1) - hw, max(x0, x1) + hw, max(y0, y1) + hw)
            let area = max(1e-3, (b.z - b.x) * (b.w - b.y))
            let len = hypot(x1 - x0, y1 - y0)
            let dens = min(1.0, (len + 2.0 * hw) * 2.0 * hw / area)
            out.append(Draw(outer: b, hole: nil, density: dens, color: q.fill, bottom: nil))
        } else if kind == KIND_TRIANGLE {
            let ax = q.radii.x, ay = q.radii.y, bx = q.radii.z, by = q.radii.w
            let cx = q.uv.x, cy = q.uv.y
            let b = SIMD4<Float>(min(min(ax, bx), cx), min(min(ay, by), cy), max(max(ax, bx), cx), max(max(ay, by), cy))
            out.append(Draw(outer: b, hole: nil, density: 0.5, color: q.fill, bottom: nil))
        } else if kind == KIND_IMAGE {
            let a = q.fill.w
            out.append(solid(SIMD4<Float>(0.5 * a, 0.5 * a, 0.5 * a, a), 1.0))
        } else if kind == KIND_SHADOW {
            let sigma = max(0.5, q.params.z)
            let u = q.uv
            let window: SIMD4<Float> = u.z < 0.0
                ? SIMD4<Float>(q.rect.x + u.x, q.rect.y + u.y, q.rect.x - u.z, q.rect.y + u.w)
                : SIMD4<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
            let hole: SIMD4<Float>? = u.z > 0.0
                ? SIMD4<Float>(q.rect.x + u.x, q.rect.y + u.y, q.rect.x + u.x + u.z, q.rect.y + u.y + u.w)
                : nil
            for d in [-sigma, 0.0, sigma] {
                out.append(Draw(outer: meet(grow(outer, d), window), hole: hole, density: 1.0 / 3.0, color: q.fill, bottom: nil))
            }
        }
        return out
    }

    public static func rasterize(_ instances: [RenderInstance], size: (Float, Float), scale: Float) -> MotionGateGrid {
        rasterizeWith(instances, size: size, scale: scale, aprons: [], shifts: [:])
    }

    public static func rasterizeWith(
        _ instances: [RenderInstance],
        size: (Float, Float),
        scale: Float,
        aprons: Set<ApronKey>,
        shifts: [ApronKey: Float]
    ) -> MotionGateGrid {
        let (w, h) = dims(size)
        let px = cellSize * scale
        let full = SIMD4<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var stack: [Scope] = [Scope(cells: Array(repeating: .zero, count: w * h), opacity: 1.0, clip: full)]
        let cellArea = px * px

        for var q in instances {
            let kind = q.params.y
            if kind == KIND_LAYER {
                let clip = meet(stack[stack.count - 1].clip, q.clip)
                stack.append(Scope(cells: Array(repeating: .zero, count: w * h), opacity: q.fill.w.clamped(to: 0.0...1.0), clip: clip))
                continue
            }
            if kind == KIND_LAYER_END {
                if stack.count > 1 {
                    let top = stack.removeLast()
                    let pIdx = stack.count - 1
                    for i in 0..<(w * h) {
                        stack[pIdx].cells[i] = MotionGatePaintUtils.overPremul(top.cells[i] * top.opacity, stack[pIdx].cells[i])
                    }
                }
                continue
            }

            let topIdx = stack.count - 1
            let clip = meet(stack[topIdx].clip, q.clip)
            let key: ApronKey? = (kind == KIND_GLYPH) ? ApronKey(q) : nil
            let isApron = key.map { aprons.contains($0) } ?? false
            if let k = key, let dy = shifts[k] {
                q.rect.y += dy
            }

            for d in draws(q, apron: isApron) {
                if d.color.w <= 1e-4 || d.density <= 0.0 { continue }
                let b = meet(d.outer, clip)
                if b.z <= b.x || b.w <= b.y { continue }
                let cx0 = max(0, Int(floor(b.x / px)))
                let cy0 = max(0, Int(floor(b.y / px)))
                let cx1 = min(w, Int(ceil(b.z / px)))
                let cy1 = min(h, Int(ceil(b.w / px)))
                guard cx0 < cx1 && cy0 < cy1 else { continue }
                let height = max(1e-3, d.outer.w - d.outer.y)
                for cy in cy0..<cy1 {
                    for cx in cx0..<cx1 {
                        let cell = SIMD4<Float>(Float(cx) * px, Float(cy) * px, Float(cx + 1) * px, Float(cy + 1) * px)
                        var cover = overlapArea(b, cell)
                        if let hole = d.hole {
                            cover -= overlapArea(meet(hole, b), cell)
                        }
                        let k = (cover / cellArea).clamped(to: 0.0...1.0) * d.density
                        if k <= 0.0 { continue }
                        let color: SIMD4<Float>
                        if let bottom = d.bottom {
                            let t = (((cell.y + cell.w) * 0.5 - d.outer.y) / height).clamped(to: 0.0...1.0)
                            color = d.color + (bottom - d.color) * t
                        } else {
                            color = d.color
                        }
                        let idx = cy * w + cx
                        stack[topIdx].cells[idx] = MotionGatePaintUtils.overPremul(color * k, stack[topIdx].cells[idx])
                    }
                }
            }
        }

        while stack.count > 1 {
            let top = stack.removeLast()
            let pIdx = stack.count - 1
            for i in 0..<(w * h) {
                stack[pIdx].cells[i] = MotionGatePaintUtils.overPremul(top.cells[i] * top.opacity, stack[pIdx].cells[i])
            }
        }
        return MotionGateGrid(w: w, h: h, cells: stack[0].cells)
    }

    public static func fromPixels(_ rgba: [UInt8], pw: Int, ph: Int, size: (Float, Float)) -> MotionGateGrid {
        let (w, h) = dims(size)
        let sx = Float(pw) / max(1.0, size.0)
        let sy = Float(ph) / max(1.0, size.1)
        let lut: [Float] = (0...255).map { v in
            let c = Float(v) / 255.0
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        var cells = Array(repeating: SIMD4<Float>.zero, count: w * h)
        for cy in 0..<h {
            for cx in 0..<w {
                let x0 = Int(Float(cx) * cellSize * sx)
                let y0 = Int(Float(cy) * cellSize * sy)
                let x1 = min(pw, Int(Float(cx + 1) * cellSize * sx))
                let y1 = min(ph, Int(Float(cy + 1) * cellSize * sy))
                var sum = SIMD3<Float>.zero
                var n: Float = 0
                if y0 < y1 && x0 < x1 {
                    var y = y0
                    while y < y1 {
                        var x = x0
                        while x < x1 {
                            let p = (y * pw + x) * 4
                            if p + 3 < rgba.count {
                                let a = Float(rgba[p + 3]) / 255.0
                                sum.x += lut[Int(rgba[p])] * a
                                sum.y += lut[Int(rgba[p + 1])] * a
                                sum.z += lut[Int(rgba[p + 2])] * a
                                n += 1.0
                            }
                            x += 2
                        }
                        y += 2
                    }
                }
                if n > 0.0 {
                    cells[cy * w + cx] = SIMD4<Float>(sum.x / n, sum.y / n, sum.z / n, 1.0)
                }
            }
        }
        return MotionGateGrid(w: w, h: h, cells: cells)
    }
}
