import Foundation
#if os(Android)
import Android
#endif

// MARK: - Coverage Lanes Abstraction (rune::text::outline::lanes & cover)

/// Scalar / SIMD IEEE single-precision lane arithmetic matching `rune::text::outline::lanes::Lanes`.
public protocol OutlineCoverageLanes {
    associatedtype LaneMask
    static var laneCount: Int { get }
    static func splat(_ v: Float) -> Self
    static func load(_ v: SIMD4<Float>) -> Self
    static func store(_ x: Self) -> SIMD4<Float>
    static func add(_ a: Self, _ b: Self) -> Self
    static func sub(_ a: Self, _ b: Self) -> Self
    static func mul(_ a: Self, _ b: Self) -> Self
    static func div(_ a: Self, _ b: Self) -> Self
    static func neg(_ a: Self) -> Self
    static func sqrt(_ a: Self) -> Self
    static func lt(_ a: Self, _ b: Self) -> LaneMask
    static func le(_ a: Self, _ b: Self) -> LaneMask
    static func ge(_ a: Self, _ b: Self) -> LaneMask
    static func gt(_ a: Self, _ b: Self) -> LaneMask
    static func ne(_ a: Self, _ b: Self) -> LaneMask
    static func select(_ m: LaneMask, _ a: Self, _ b: Self) -> Self
    static func same(_ a: LaneMask, _ b: LaneMask) -> LaneMask
    static func and(_ a: LaneMask, _ b: LaneMask) -> LaneMask
    static func andNot(_ a: LaneMask, _ b: LaneMask) -> LaneMask
    static func bits(_ m: LaneMask) -> UInt32
    static func clamp(_ x: Self, _ lo: Self, _ hi: Self) -> Self
    static func maxLanes(_ a: Self, _ b: Self) -> Self
}

extension Float: OutlineCoverageLanes {
    public typealias LaneMask = Bool
    public static var laneCount: Int { 1 }
    public static func splat(_ v: Float) -> Float { v }
    public static func load(_ v: SIMD4<Float>) -> Float { v[0] }
    public static func store(_ x: Float) -> SIMD4<Float> { SIMD4<Float>(x, 0, 0, 0) }
    public static func add(_ a: Float, _ b: Float) -> Float { a + b }
    public static func sub(_ a: Float, _ b: Float) -> Float { a - b }
    public static func mul(_ a: Float, _ b: Float) -> Float { a * b }
    public static func div(_ a: Float, _ b: Float) -> Float { a / b }
    public static func neg(_ a: Float) -> Float { -a }
    public static func sqrt(_ a: Float) -> Float { a.squareRoot() }
    public static func lt(_ a: Float, _ b: Float) -> Bool { a < b }
    public static func le(_ a: Float, _ b: Float) -> Bool { a <= b }
    public static func ge(_ a: Float, _ b: Float) -> Bool { a >= b }
    public static func gt(_ a: Float, _ b: Float) -> Bool { a > b }
    public static func ne(_ a: Float, _ b: Float) -> Bool { a != b }
    public static func select(_ m: Bool, _ a: Float, _ b: Float) -> Float { m ? a : b }
    public static func same(_ a: Bool, _ b: Bool) -> Bool { a == b }
    public static func and(_ a: Bool, _ b: Bool) -> Bool { a && b }
    public static func andNot(_ a: Bool, _ b: Bool) -> Bool { a && !b }
    public static func bits(_ m: Bool) -> UInt32 { m ? 1 : 0 }
    public static func clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float {
        let clampedLo = x < lo ? lo : x
        return clampedLo > hi ? hi : clampedLo
    }
    public static func maxLanes(_ a: Float, _ b: Float) -> Float { a > b ? a : b }
}

/// Four-lane `SIMD4<Float>` implementation (`F4` / `Portable`).
public struct OutlineF4: OutlineCoverageLanes, Sendable, Equatable {
    public var v: SIMD4<Float>
    public typealias LaneMask = SIMDMask<SIMD4<Int32>>
    public static var laneCount: Int { 4 }

    public init(_ v: SIMD4<Float>) { self.v = v }
    public static func splat(_ x: Float) -> OutlineF4 { OutlineF4(SIMD4<Float>(repeating: x)) }
    public static func load(_ x: SIMD4<Float>) -> OutlineF4 { OutlineF4(x) }
    public static func store(_ x: OutlineF4) -> SIMD4<Float> { x.v }
    public static func add(_ a: OutlineF4, _ b: OutlineF4) -> OutlineF4 { OutlineF4(a.v + b.v) }
    public static func sub(_ a: OutlineF4, _ b: OutlineF4) -> OutlineF4 { OutlineF4(a.v - b.v) }
    public static func mul(_ a: OutlineF4, _ b: OutlineF4) -> OutlineF4 { OutlineF4(a.v * b.v) }
    public static func div(_ a: OutlineF4, _ b: OutlineF4) -> OutlineF4 { OutlineF4(a.v / b.v) }
    public static func neg(_ a: OutlineF4) -> OutlineF4 { OutlineF4(-a.v) }
    public static func sqrt(_ a: OutlineF4) -> OutlineF4 {
        OutlineF4(SIMD4<Float>(
            a.v[0].squareRoot(),
            a.v[1].squareRoot(),
            a.v[2].squareRoot(),
            a.v[3].squareRoot()
        ))
    }
    public static func lt(_ a: OutlineF4, _ b: OutlineF4) -> LaneMask { a.v .< b.v }
    public static func le(_ a: OutlineF4, _ b: OutlineF4) -> LaneMask { a.v .<= b.v }
    public static func ge(_ a: OutlineF4, _ b: OutlineF4) -> LaneMask { a.v .>= b.v }
    public static func gt(_ a: OutlineF4, _ b: OutlineF4) -> LaneMask { a.v .> b.v }
    public static func ne(_ a: OutlineF4, _ b: OutlineF4) -> LaneMask { a.v .!= b.v }
    public static func select(_ m: LaneMask, _ a: OutlineF4, _ b: OutlineF4) -> OutlineF4 {
        OutlineF4(b.v.replacing(with: a.v, where: m))
    }
    public static func same(_ a: LaneMask, _ b: LaneMask) -> LaneMask { a .== b }
    public static func and(_ a: LaneMask, _ b: LaneMask) -> LaneMask { a .& b }
    public static func andNot(_ a: LaneMask, _ b: LaneMask) -> LaneMask { a .& .!b }
    public static func bits(_ m: LaneMask) -> UInt32 {
        var mask: UInt32 = 0
        for i in 0..<4 where m[i] { mask |= (1 << i) }
        return mask
    }
    public static func clamp(_ x: OutlineF4, _ lo: OutlineF4, _ hi: OutlineF4) -> OutlineF4 {
        let a = select(lt(x, lo), lo, x)
        return select(gt(a, hi), hi, a)
    }
    public static func maxLanes(_ a: OutlineF4, _ b: OutlineF4) -> OutlineF4 {
        select(gt(a, b), a, b)
    }
}

// MARK: - Closed-Form Box-Filtered Coverage (rune::text::outline::cover)

public enum OutlineCover {
    internal static func moved(_ code: UInt32, radius r: Float) -> SIMD2<Float> {
        SIMD2<Float>(Float(Int32(code & 3) - 1) * r, Float((code >> 2) & 3) * r)
    }

    internal static func hintY(_ y: Float, _ a: SIMD4<Float>, _ b: SIMD4<Float>, _ c: SIMD4<Float>) -> Float {
        if y < a[1] { return y }
        if y <= a[2] { return (y - a[1]) * c[0] + a[1] }
        if y <= b[0] { return (y - a[2]) * c[1] + a[3] }
        if y <= b[2] { return y + (b[1] - b[0]) }
        return (y - b[2]) * c[2] + b[3]
    }

    @inline(__always)
    internal static func yLanes<L: OutlineCoverageLanes>(
        q1: L, q2: L, q3: L, lo: L, hi: L
    ) -> (L, L) {
        let two = L.splat(2.0)
        let a2 = L.add(L.sub(q1, L.mul(two, q2)), q3)
        let a1 = L.mul(two, L.sub(q2, q1))
        let rising = L.ge(q3, q1)
        let v0 = L.select(rising, lo, hi)
        let v1 = L.select(rising, hi, lo)
        return (lane(a2: a2, a1: a1, q1: q1, q3: q3, v: v0, rising: rising),
                lane(a2: a2, a1: a1, q1: q1, q3: q3, v: v1, rising: rising))
    }

    @inline(__always)
    private static func lane<L: OutlineCoverageLanes>(
        a2: L, a1: L, q1: L, q3: L, v: L, rising: L.LaneMask
    ) -> L {
        let zero = L.splat(0.0)
        let one = L.splat(1.0)
        let sg = L.select(rising, one, L.neg(one))
        let c = L.sub(q1, v)
        let sat0 = L.ge(L.mul(c, sg), zero)
        let sat1 = L.le(L.mul(L.sub(q3, v), sg), zero)
        let disc = L.maxLanes(zero, L.sub(L.mul(a1, a1), L.mul(L.splat(4.0), L.mul(a2, c))))
        let sq = L.sqrt(disc)
        let qq = L.mul(L.splat(-0.5), L.add(a1, L.select(L.ge(a1, zero), sq, L.neg(sq))))
        let useR1 = L.same(L.lt(a1, zero), rising)
        let num = L.select(useR1, qq, c)
        let den = L.select(useR1, a2, qq)
        let valid = L.ne(den, zero)
        let tRaw = L.select(valid, L.clamp(L.div(num, L.select(valid, den, one)), zero, one), zero)
        return L.select(sat0, zero, L.select(sat1, one, tRaw))
    }

    @inline(__always)
    internal static func integrateX<L: OutlineCoverageLanes>(
        q1: (L, L), q2: (L, L), q3: (L, L), t: (L, L), hx: L
    ) -> L {
        let zero = L.splat(0.0)
        let two = L.splat(2.0)
        let a2x = L.add(L.sub(q1.0, L.mul(two, q2.0)), q3.0)
        let a2y = L.add(L.sub(q1.1, L.mul(two, q2.1)), q3.1)
        let a1x = L.mul(two, L.sub(q2.0, q1.0))
        let a1y = L.mul(two, L.sub(q2.1, q1.1))
        let xRising = L.ge(q3.0, q1.0)
        let tx0 = lane(a2: a2x, a1: a1x, q1: q1.0, q3: q3.0, v: L.neg(hx), rising: xRising)
        let tx1 = lane(a2: a2x, a1: a1x, q1: q1.0, q3: q3.0, v: hx, rising: xRising)
        let tc0 = L.clamp(tx0, t.0, t.1)
        let tc1 = L.clamp(tx1, t.0, t.1)
        let t1 = L.select(xRising, tc0, tc1)
        let t2 = L.maxLanes(L.select(xRising, tc1, tc0), t1)

        let half = L.splat(0.5)
        let tmIn = L.mul(half, L.add(t1, t2))
        let dIn = L.mul(half, L.sub(t2, t1))
        let xMid = L.add(L.add(L.mul(L.add(L.mul(a2x, tmIn), a1x), tmIn), q1.0), hx)
        let dmidX = L.add(L.mul(L.mul(two, a2x), tmIn), a1x)
        let dmidY = L.add(L.mul(L.mul(two, a2y), tmIn), a1y)
        let vCubic = L.mul(
            L.div(L.mul(L.mul(L.mul(two, dIn), dIn), dIn), L.splat(3.0)),
            L.add(L.mul(a2x, dmidY), L.mul(L.mul(two, a2y), dmidX))
        )
        let v = L.add(L.mul(L.mul(L.mul(two, dIn), xMid), dmidY), vCubic)
        let inside = L.select(L.le(t2, t1), zero, v)

        let rab0 = L.select(xRising, t2, t.0)
        let rab1 = L.select(xRising, t.1, t1)
        let dOut = L.maxLanes(zero, L.sub(rab1, rab0))
        let tmOut = L.mul(half, L.add(rab0, rab1))
        let dOutY = L.add(L.mul(L.mul(two, a2y), tmOut), a1y)
        let acc = L.add(inside, L.mul(L.mul(dOut, dOutY), L.mul(two, hx)))
        return L.select(L.le(t.1, t.0), zero, acc)
    }

    /// Closed-form box-filtered coverage in `[0, 1]` at `local` (rest px from pen, y up).
    public static func coverage(
        store: OutlineStore,
        record: UInt32,
        hint: UInt32 = 0,
        local: SIMD2<Float>,
        scale: Float,
        radius r: Float = 0,
        halfWidth hw: Float = 0.5
    ) -> Float {
        coverage(store: store, record: record, hint: hint, local: local, scale: scale, radius: r, halfWidth: hw, slug: false)
    }

    static func coverage(store: OutlineStore, record: UInt32, hint: UInt32, local: SIMD2<Float>,
                         scale: Float, radius r: Float, halfWidth hw: Float, slug: Bool) -> Float {
        @inline(__always) func f(_ bits: UInt32) -> Float { Float(bitPattern: bits) }
        let head = store.texel(record)
        let count = head[1]
        guard count > 0 else { return 0 }
        let y0 = f(head[2])
        let invH = f(head[3])

        let hintData: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)? = hint != 0
            ? (
                SIMD4<Float>(f(store.texel(hint)[0]), f(store.texel(hint)[1]), f(store.texel(hint)[2]), f(store.texel(hint)[3])),
                SIMD4<Float>(f(store.texel(hint + 1)[0]), f(store.texel(hint + 1)[1]), f(store.texel(hint + 1)[2]), f(store.texel(hint + 1)[3])),
                SIMD4<Float>(f(store.texel(hint + 2)[0]), f(store.texel(hint + 2)[1]), f(store.texel(hint + 2)[2]), f(store.texel(hint + 2)[3]))
            )
            : nil
        func hy(_ y: Float) -> Float {
            guard let (a, b, c) = hintData else { return y }
            return hintY(y, a, b, c)
        }
        let reach: Float = hintData != nil ? GlyphOutline.hintReach : 0

        let (b0, b1): (UInt32, UInt32)
        if count > 1 {
            let last = Float(count - 1)
            func band(_ u: Float) -> UInt32 {
                UInt32(min(max(floor((u / scale - y0) * invH), 0), last))
            }
            b0 = band(local.y - hw - 2 * r - reach)
            b1 = band(local.y + hw + reach)
        } else {
            b0 = 0
            b1 = 0
        }

        var acc: Float = 0
        var rays = SIMD3<Float>.zero
        for band in b0...max(b0, b1) {
            let e0: Float = count > 1 ? (y0 + Float(band) / invH) * scale : -3.0e38
            let e1: Float = count > 1 ? (y0 + Float(band + 1) / invH) * scale : 3.0e38
            let entry = store.texel(head[0] &+ band)
            let sorted = entry[1] > UInt32(OutlineBuilder.sortMin)
            for k in 0..<entry[1] {
                let t0 = store.texel(entry[0] &+ 2 * k)
                let t1 = store.texel(entry[0] &+ 2 * k + 1)
                if f(t1[3]) * scale + r - local.x <= -hw {
                    if sorted { break }
                    continue
                }
                let code = t1[2]
                let oa = moved(code & 15, radius: r)
                let ob = moved((code >> 4) & 15, radius: r)
                let p0 = SIMD2<Float>(f(t0[0]) * scale + oa.x, hy(f(t0[1]) * scale + oa.y))
                var p1 = SIMD2<Float>(f(t0[2]) * scale + oa.x, hy(f(t0[3]) * scale + oa.y))
                let p2 = SIMD2<Float>(f(t1[0]) * scale + ob.x, hy(f(t1[1]) * scale + ob.y))
                var wlo = -hw
                var whi = hw
                let be0 = hy(e0 + oa.y)
                let be1 = hy(e1 + oa.y)
                if (code & OutlineBuilder.connectorBit) != 0 {
                    p1 = (p0 + p2) * 0.5
                } else {
                    wlo = max(wlo, be0 - local.y)
                    whi = min(whi, be1 - local.y)
                }
                let q1 = p0 - local
                let q2 = p1 - local
                let q3 = p2 - local
                if slug {
                    let connector = code & OutlineBuilder.connectorBit != 0
                    slugCrossings(q1, q2, q3, low: connector ? -.greatestFiniteMagnitude : be0 - local.y,
                                  high: connector ? .greatestFiniteMagnitude : be1 - local.y, halfWidth: hw, into: &rays)
                    continue
                }
                let lo = max(wlo, min(q1.y, q3.y))
                let hi = min(whi, max(q1.y, q3.y))
                if hi <= lo || max(q1.x, q3.x) <= -hw {
                    continue
                }
                if min(q1.x, q3.x) >= hw {
                    let cy3 = min(max(q3.y, wlo), whi)
                    let cy1 = min(max(q1.y, wlo), whi)
                    acc += 2.0 * hw * (cy3 - cy1)
                    continue
                }
                let ty = yLanes(q1: q1.y, q2: q2.y, q3: q3.y, lo: lo, hi: hi)
                acc += integrateX(q1: (q1.x, q1.y), q2: (q2.x, q2.y), q3: (q3.x, q3.y), t: ty, hx: hw)
            }
        }
        if slug { return 0.5 * (min(abs(rays.x), 1) + min(abs(rays.y + rays.z), 1)) }
        return min(1.0, abs(acc) / (4.0 * hw * hw))
    }

    /// The shader's two-ray Slug test is needed at cell fringes even though its
    /// documented software atlas fallback uses the box-filter integration above.
    private static func slugCrossings(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ p2: SIMD2<Float>,
                                      low: Float, high: Float, halfWidth: Float, into rays: inout SIMD3<Float>) {
        func root(_ a: Float, _ b: Float, _ c: Float) -> Float {
            let quadratic = a - 2 * b + c, linear = 2 * (b - a)
            if abs(quadratic) < 1e-6 { return min(1, max(0, -a / (abs(linear) < 1e-6 ? 1e-6 : linear))) }
            let d = sqrt(max(0, linear * linear - 4 * quadratic * a))
            let t = (-linear - d) / (2 * quadratic)
            return min(1, max(0, t >= -1e-4 && t <= 1.0001 ? t : (-linear + d) / (2 * quadratic)))
        }
        func interpolate(_ a: Float, _ b: Float, _ c: Float, _ t: Float) -> Float {
            let left = a + (b - a) * t, right = b + (c - b) * t
            return left + (right - left) * t
        }
        let lo = max(min(p0.y, p2.y), low), hi = min(max(p0.y, p2.y), high)
        if p0.y != p2.y && lo <= 0 && hi > 0 {
            let x = interpolate(p0.x, p1.x, p2.x, root(p0.y, p1.y, p2.y))
            let sign: Float = p2.y > p0.y ? 1 : -1
            rays.x += sign * min(1, max(0, x / (2 * halfWidth) + 0.5))
            if x > 0 { rays.y += sign }
        }
        if p0.x != p2.x && min(p0.x, p2.x) <= 0 && max(p0.x, p2.x) > 0 {
            let y = interpolate(p0.y, p1.y, p2.y, root(p0.x, p1.x, p2.x))
            if abs(y) < halfWidth && y >= low && y < high {
                let sign: Float = p2.x > p0.x ? 1 : -1
                rays.z -= sign * (min(1, max(0, y / (2 * halfWidth) + 0.5)) - (y > 0 ? 1 : 0))
            }
        }
    }
}

// MARK: - Atlas Fill Residency & CPU Mask Rasterizer (atlas_fill, outline/fill, fill_bench)

/// One mask the renderer or CPU fills (`rune::text::atlas_fill::Fill`).
public struct OutlineFillParams: Sendable, Equatable {
    public var record: UInt32
    public var hint: UInt32
    public var scale: Float
    public var radius: Float
    public var pen: SIMD2<Float>
    public var coverage: UInt32

    public init(
        record: UInt32,
        hint: UInt32 = 0,
        scale: Float,
        radius: Float = 0,
        pen: SIMD2<Float>,
        coverage: UInt32 = 0
    ) {
        self.record = record
        self.hint = hint
        self.scale = scale
        self.radius = radius
        self.pen = pen
        self.coverage = coverage
    }
}

/// Queued mask fill (`rune::text::atlas_fill::QueuedFill`).
public struct QueuedOutlineFill: Sendable, Equatable {
    /// Texels `[x, y, w, h]`.
    public var rect: SIMD4<UInt32>
    public var fill: OutlineFillParams
    /// Native run cells can restrict a glyph to part of a shared tile.
    var crop: SIMD4<Int>?

    public init(rect: SIMD4<UInt32>, fill: OutlineFillParams) {
        self.rect = rect
        self.fill = fill
    }
}

/// Residency state machine for GPU/CPU-filled atlas entries (`rune::text::atlas_fill::Residency`).
public enum AtlasFillResidency: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        case fillRan
        case rowsUploaded(page: UInt16, y0: UInt32, y1: UInt32)
        case filledOnCpu
    }

    public enum Effect: Sendable, Equatable {
        case queue
    }

    case blank
    case uploaded(page: UInt16, x: UInt32, y: UInt32, w: UInt32, h: UInt32)
    case pending(page: UInt16, x: UInt32, y: UInt32, w: UInt32, h: UInt32, fill: OutlineFillParams)
    case filled(page: UInt16, x: UInt32, y: UInt32, w: UInt32, h: UInt32, fill: OutlineFillParams)

    public mutating func step(_ event: Event) -> [Effect] {
        switch (self, event) {
        case (.pending(let p, let x, let y, let w, let h, _), .filledOnCpu):
            self = .uploaded(page: p, x: x, y: y, w: w, h: h)
            return []
        case (.pending(let p, let x, let y, let w, let h, let f), .fillRan):
            self = .filled(page: p, x: x, y: y, w: w, h: h, fill: f)
            return []
        case (.filled(let p, let x, let y, let w, let h, let f), .rowsUploaded(let upPage, let y0, let y1))
            where p == upPage && y < y1 + 1 && y + h + 1 > y0:
            self = .pending(page: p, x: x, y: y, w: w, h: h, fill: f)
            return [.queue]
        default:
            return []
        }
    }
}

/// Instrumentation census for CPU mask fills (`rune::text::outline::fill::Census`).
public struct OutlineFillCensus: Sendable, Equatable {
    public var texels: UInt64 = 0
    public var integrals: UInt64 = 0
    public var clear: UInt64 = 0
    public var solid: UInt64 = 0
    public var pieces: UInt64 = 0
    public var rowPieces: UInt64 = 0
    public var rowSets: UInt64 = 0

    public init() {}
}

/// CPU outline mask rasterizer matching `outline/fill.rs` across 1-lane and 4-lane IEEE paths.
public enum OutlineMaskFiller {
    private static let margin: Float = 1.0 / 64.0

    private enum Stretch {
        case empty
        case within(lo: Float, hi: Float, right: Float)
        case bent
    }

    private struct Piece {
        var band: UInt32
        var p0, p1, p2: SIMD2<Float>
        var be0, be1: Float
        var connector: Bool
        var xMin, xMax: Float
        var monotoneX: Bool
        var rowStart, rowEnd: UInt32
    }

    private struct Cand {
        var piece: Int
        var row: UInt32
        var q0, q1, q2: Float
        var lo, hi: Float
        var wlo, whi: Float
        var ty0: Float = 0
        var ty1: Float = 0
    }

    private struct RowPiece {
        var ty0, ty1: Float
        var right: Float
        var xMin, xMax: Float
        var p0, p1, p2: SIMD2<Float>
        var stretch: Stretch
    }

    private struct RowTable {
        var starts: [Int] = []
        var rows: [RowPiece] = []
        var byMin: [Int] = []
        var tailStarts: [Int] = []
        var tails: [Float] = []
        var ly: [Float] = []
        var pieceCount: Int = 0
    }

    /// Fills a single `w x h` R8 mask at `(atX, atY)` on its atlas page.
    public static func fillMask(
        store: OutlineStore,
        fill: OutlineFillParams,
        atX: UInt32,
        atY: UInt32,
        width w: UInt32,
        height h: UInt32
    ) -> [UInt8] {
        if fill.coverage == 4 {
            return fillTile(store: store, record: fill.record, width: w, height: h)
        }
        var table = RowTable()
        var census: OutlineFillCensus? = nil
        buildRows(OutlineF4.self, store: store, fill: fill, atY: atY, height: h, into: &table)
        var out: [UInt8] = []
        fillTexels(
            OutlineF4.self,
            table: table,
            coverage: fill.coverage,
            penX: fill.pen.x,
            atX: atX,
            width: w,
            height: h,
            out: &out,
            census: &census
        )
        return out
    }

    /// Composite the same byte-rounded source coverage as native text rasterization.
    /// The GPU reads this ordered list from the same immutable outline snapshot.
    private static func fillTile(store: OutlineStore, record: UInt32, width: UInt32, height: UInt32) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: Int(width) * Int(height))
        let count = store.texel(record).x
        guard count <= 64 else { return pixels }
        for i in 0..<count {
            let base = record &+ 1 &+ 3 * i
            let r = store.texel(base), p = store.texel(base &+ 1), g = store.texel(base &+ 2)
            guard r.x < width, r.y < height, r.z > 0, r.w > 0,
                  r.z <= width - r.x, r.w <= height - r.y, g.z <= 1 else { continue }
            let pen = SIMD2(Float(bitPattern: p.x) - Float(r.x), Float(bitPattern: p.y) - Float(r.y))
            let part = OutlineFillParams(record: g.x, hint: g.y, scale: Float(bitPattern: p.z),
                                         radius: Float(bitPattern: p.w), pen: pen, coverage: g.z)
            let mask = fillMask(store: store, fill: part, atX: 0, atY: 0, width: r.z, height: r.w)
            for row in 0..<Int(r.w) {
                let src = row * Int(r.z)
                let dst = (Int(r.y) + row) * Int(width) + Int(r.x)
                for col in 0..<Int(r.z) where mask[src + col] != 0 {
                    let alpha = Int(mask[src + col])
                    pixels[dst + col] = UInt8(alpha + (Int(pixels[dst + col]) * (255 - alpha) + 127) / 255)
                }
            }
        }
        return pixels
    }

    /// Query a tile's cell bounds with exactly the solver and byte rounding used to
    /// paint the full mask. A fringe query builds a single row at its original pen.
    static func hasInk(store: OutlineStore, fill: OutlineFillParams, columns: Range<Int>, row: Int) -> Bool {
        var rows = RowTable(), out: [UInt8] = []
        var census: OutlineFillCensus?
        buildRows(OutlineF4.self, store: store, fill: fill, atY: UInt32(row), height: 1,
                  absolutePenY: fill.pen.y, into: &rows)
        fillTexels(OutlineF4.self, table: rows, coverage: fill.coverage, penX: fill.pen.x, atX: UInt32(columns.lowerBound),
                   width: UInt32(columns.count), height: 1, absolutePenX: fill.pen.x, out: &out, census: &census)
        if out.contains(where: { $0 != 0 }) { return true }
        guard fill.coverage == 1 else { return false }
        return columns.contains { x in
            let local = SIMD2(Float(x) + 0.5 - fill.pen.x, fill.pen.y - Float(row) - 0.5)
            let rays = OutlineCover.coverage(store: store, record: fill.record, hint: fill.hint, local: local,
                                            scale: fill.scale, radius: fill.radius, halfWidth: 0.5, slug: true)
            return (rays * 255).rounded(.toNearestOrEven) > 0
        }
    }

    /// Groups fills sharing outline/scale/radius/coverage/height/pen.y (`outline::share_rows`).
    public static func shareRows(_ fills: [QueuedOutlineFill]) -> [[UInt32]] {
        struct Key: Hashable {
            var r, h, s, rad, c, ht, py: UInt32
        }
        var groups: [[UInt32]] = []
        var index: [Key: Int] = Dictionary(minimumCapacity: fills.count)
        for (i, q) in fills.enumerated() {
            let f = q.fill
            let k = Key(
                r: f.record,
                h: f.hint,
                s: f.scale.bitPattern,
                rad: f.radius.bitPattern,
                c: f.coverage,
                ht: q.rect[3],
                py: f.pen.y.bitPattern
            )
            let gi: Int
            if let existing = index[k] {
                gi = existing
            } else {
                gi = groups.count
                groups.append([])
                index[k] = gi
            }
            groups[gi].append(UInt32(i))
        }
        return groups
    }

    /// Fills a shared-row group using lane implementation `L`.
    public static func fillShared<L: OutlineCoverageLanes>(
        _ lanes: L.Type,
        store: OutlineStore,
        fills: [QueuedOutlineFill],
        group: [UInt32],
        outs: inout [[UInt8]],
        census: inout OutlineFillCensus?
    ) {
        var table = RowTable()
        var hasRows = false
        for (idx, fillIndex) in group.enumerated() {
            let q = fills[Int(fillIndex)]
            let x = q.rect[0]
            let y = q.rect[1]
            let w = q.rect[2]
            let h = q.rect[3]
            let penY = Float(y) + q.fill.pen.y
            let same = hasRows && table.ly.count == Int(h) && (0..<Int(h)).allSatisfy { row in
                (penY - (Float(y + UInt32(row)) + 0.5)) == table.ly[row]
            }
            if !same {
                buildRows(lanes, store: store, fill: q.fill, atY: y, height: h, into: &table)
                hasRows = true
                if var c = census {
                    c.pieces += UInt64(table.pieceCount)
                    c.rowSets += 1
                    census = c
                }
            }
            outs[idx].removeAll(keepingCapacity: true)
            fillTexels(
                lanes,
                table: table,
                coverage: q.fill.coverage,
                penX: q.fill.pen.x,
                atX: x,
                width: w,
                height: h,
                out: &outs[idx],
                census: &census
            )
        }
    }

    private static func buildRows<L: OutlineCoverageLanes>(
        _: L.Type,
        store: OutlineStore,
        fill: OutlineFillParams,
        atY: UInt32,
        height h: UInt32,
        absolutePenY: Float? = nil,
        into table: inout RowTable
    ) {
        @inline(__always) func f(_ bits: UInt32) -> Float { Float(bitPattern: bits) }
        let rec = fill.record
        let scale = fill.scale
        let r = fill.radius
        let hw: Float = 0.5
        let penY = absolutePenY ?? (Float(atY) + fill.pen.y)
        let head = store.texel(rec)
        let count = head[1]
        let y0 = f(head[2])
        let invH = f(head[3])

        let hintData: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)? = fill.hint != 0
            ? (
                SIMD4<Float>(f(store.texel(fill.hint)[0]), f(store.texel(fill.hint)[1]), f(store.texel(fill.hint)[2]), f(store.texel(fill.hint)[3])),
                SIMD4<Float>(f(store.texel(fill.hint + 1)[0]), f(store.texel(fill.hint + 1)[1]), f(store.texel(fill.hint + 1)[2]), f(store.texel(fill.hint + 1)[3])),
                SIMD4<Float>(f(store.texel(fill.hint + 2)[0]), f(store.texel(fill.hint + 2)[1]), f(store.texel(fill.hint + 2)[2]), f(store.texel(fill.hint + 2)[3]))
            )
            : nil
        func hy(_ y: Float) -> Float {
            guard let (a, b, c) = hintData else { return y }
            return OutlineCover.hintY(y, a, b, c)
        }
        let reach: Float = hintData != nil ? GlyphOutline.hintReach : 0

        func rowBands(_ ly: Float) -> (UInt32, UInt32) {
            guard count > 1 else { return (0, 0) }
            let last = Float(count - 1)
            func band(_ u: Float) -> UInt32 {
                UInt32(min(max(floor((u / scale - y0) * invH), 0), last))
            }
            return (band(ly - hw - 2 * r - reach), band(ly + hw + reach))
        }

        func lyOf(_ row: UInt32) -> Float {
            penY - (Float(atY + row) + 0.5)
        }

        func firstRow(near: Float, test: (Float, Float) -> Bool, y: Float) -> UInt32 {
            var row = UInt32(min(max(near, 0), Float(h)))
            while row > 0 && test(y, lyOf(row - 1)) { row -= 1 }
            while row < h && !test(y, lyOf(row)) { row += 1 }
            return row
        }

        let firstBand = rowBands(lyOf(h > 0 ? h - 1 : 0)).0
        let lastBand = rowBands(lyOf(0)).1
        let top = penY - Float(atY) - 0.5

        var pieces: [Piece] = []
        if count > 0 {
            for band in firstBand...max(firstBand, lastBand) {
                let e0: Float = count > 1 ? (y0 + Float(band) / invH) * scale : -3.0e38
                let e1: Float = count > 1 ? (y0 + Float(band + 1) / invH) * scale : 3.0e38
                let entry = store.texel(head[0] &+ band)
                for k in 0..<entry[1] {
                    let t0 = store.texel(entry[0] &+ 2 * k)
                    let t1 = store.texel(entry[0] &+ 2 * k + 1)
                    let code = t1[2]
                    let oa = OutlineCover.moved(code & 15, radius: r)
                    let ob = OutlineCover.moved((code >> 4) & 15, radius: r)
                    let p0 = SIMD2<Float>(f(t0[0]) * scale + oa.x, hy(f(t0[1]) * scale + oa.y))
                    var p1 = SIMD2<Float>(f(t0[2]) * scale + oa.x, hy(f(t0[3]) * scale + oa.y))
                    let p2 = SIMD2<Float>(f(t1[0]) * scale + ob.x, hy(f(t1[1]) * scale + ob.y))
                    let be0 = hy(e0 + oa.y)
                    let be1 = hy(e1 + oa.y)
                    let connector = (code & OutlineBuilder.connectorBit) != 0
                    if connector {
                        p1 = (p0 + p2) * 0.5
                    }
                    let ylo = min(p0.y, p2.y)
                    let yhi = max(p0.y, p2.y)
                    let yBoundLo = connector ? ylo : max(ylo, be0)
                    let yBoundHi = connector ? yhi : min(yhi, be1)
                    let xMin = min(p0.x, p2.x)
                    let xMax = max(p0.x, p2.x)
                    let rStart = firstRow(near: top - yBoundHi - hw, test: { $0 - $1 > -0.5 }, y: yBoundHi)
                    let rEnd = firstRow(near: top - yBoundLo + hw, test: { $0 - $1 >= 0.5 }, y: yBoundLo)
                    pieces.append(Piece(
                        band: band,
                        p0: p0, p1: p1, p2: p2,
                        be0: be0, be1: be1,
                        connector: connector,
                        xMin: xMin, xMax: xMax,
                        monotoneX: p1.x >= xMin && p1.x <= xMax,
                        rowStart: rStart, rowEnd: rEnd
                    ))
                }
            }
        }
        table.pieceCount = pieces.count

        let rowBandsList = (0..<h).map { rowBands(lyOf($0)) }
        var cands: [Cand] = []
        for (i, pc) in pieces.enumerated() where pc.rowStart < pc.rowEnd {
            for row in pc.rowStart..<pc.rowEnd {
                let (b0, b1) = rowBandsList[Int(row)]
                guard pc.band >= b0 && pc.band <= b1 else { continue }
                let ly = lyOf(row)
                var wlo = -hw
                var whi = hw
                if !pc.connector {
                    wlo = max(wlo, pc.be0 - ly)
                    whi = min(whi, pc.be1 - ly)
                }
                let q0 = pc.p0.y - ly
                let q1 = pc.p1.y - ly
                let q2 = pc.p2.y - ly
                let lo = max(wlo, min(q0, q2))
                let hi = min(whi, max(q0, q2))
                guard hi > lo else { continue }
                cands.append(Cand(piece: i, row: row, q0: q0, q1: q1, q2: q2, lo: lo, hi: hi, wlo: wlo, whi: whi))
            }
        }

        let laneN = L.laneCount
        var idx = 0
        while idx < cands.count {
            var v0 = SIMD4<Float>.zero
            var v1 = SIMD4<Float>.zero
            var v2 = SIMD4<Float>.zero
            var v3 = SIMD4<Float>.zero
            var v4 = SIMD4<Float>.zero
            let countChunk = min(laneN, cands.count - idx)
            for k in 0..<laneN {
                let c = cands[idx + min(k, countChunk - 1)]
                v0[k] = c.q0
                v1[k] = c.q1
                v2[k] = c.q2
                v3[k] = c.lo
                v4[k] = c.hi
            }
            let (ty0L, ty1L) = OutlineCover.yLanes(
                q1: L.load(v0), q2: L.load(v1), q3: L.load(v2),
                lo: L.load(v3), hi: L.load(v4)
            )
            let ty0 = L.store(ty0L)
            let ty1 = L.store(ty1L)
            for k in 0..<countChunk {
                cands[idx + k].ty0 = ty0[k]
                cands[idx + k].ty1 = ty1[k]
            }
            idx += laneN
        }

        var starts = [Int](repeating: 0, count: Int(h) + 2)
        for c in cands {
            starts[Int(c.row) + 2] += 1
        }
        if starts.count > 2 {
            for k in 1..<(starts.count - 1) {
                starts[k + 1] += starts[k]
            }
        }

        var rows = [RowPiece](
            repeating: RowPiece(ty0: 0, ty1: 0, right: 0, xMin: 0, xMax: 0, p0: .zero, p1: .zero, p2: .zero, stretch: .empty),
            count: cands.count
        )
        for c in cands {
            let pc = pieces[c.piece]
            let right = 2.0 * hw * (min(max(c.q2, c.wlo), c.whi) - min(max(c.q0, c.wlo), c.whi))
            let stretch: Stretch
            if c.ty1 <= c.ty0 {
                stretch = .empty
            } else if !pc.monotoneX {
                stretch = .bent
            } else {
                let a2y = c.q0 - 2.0 * c.q1 + c.q2
                let a1y = 2.0 * (c.q1 - c.q0)
                let d = max(0, c.ty1 - c.ty0)
                let tm = 0.5 * (c.ty0 + c.ty1)
                let rVal = d * (2.0 * a2y * tm + a1y) * (2.0 * hw)
                let a2x = pc.p0.x - 2.0 * pc.p1.x + pc.p2.x
                let a1x = 2.0 * (pc.p1.x - pc.p0.x)
                let xa = (a2x * c.ty0 + a1x) * c.ty0 + pc.p0.x
                let xb = (a2x * c.ty1 + a1x) * c.ty1 + pc.p0.x
                stretch = .within(lo: min(xa, xb) - margin, hi: max(xa, xb) + margin, right: rVal)
            }
            let slot = starts[Int(c.row) + 1]
            rows[slot] = RowPiece(
                ty0: c.ty0, ty1: c.ty1, right: right,
                xMin: pc.xMin, xMax: pc.xMax,
                p0: pc.p0, p1: pc.p1, p2: pc.p2,
                stretch: stretch
            )
            starts[Int(c.row) + 1] = slot + 1
        }

        var byMin: [Int] = []
        byMin.reserveCapacity(rows.count)
        var tailStarts: [Int] = []
        tailStarts.reserveCapacity(Int(h))
        var tails: [Float] = []
        for row in 0..<Int(h) {
            let a = starts[row]
            let b = starts[row + 1]
            var rowOrder = Array(0..<(b - a))
            rowOrder.sort { lhs, rhs in
                let lx = rows[a + lhs].xMin
                let rx = rows[a + rhs].xMin
                return lx == rx ? lhs < rhs : lx < rx
            }
            byMin.append(contentsOf: rowOrder)

            let base = tails.count
            tailStarts.append(base)
            let countRow = b - a
            tails.append(contentsOf: repeatElement(0.0, count: countRow + 1))
            for k in stride(from: countRow - 1, through: 0, by: -1) {
                tails[base + k] = tails[base + k + 1] + rows[a + rowOrder[k]].right
            }
        }

        table.starts = starts
        table.rows = rows
        table.byMin = byMin
        table.tailStarts = tailStarts
        table.tails = tails
        table.ly = (0..<h).map(lyOf)
    }

    private struct Job {
        var slot: Int
        var lane: Int
        var rowPieceIdx: Int
        var lx: Float
    }

    private static func fillTexels<L: OutlineCoverageLanes>(
        _: L.Type,
        table: RowTable,
        coverage: UInt32,
        penX: Float,
        atX: UInt32,
        width w: UInt32,
        height h: UInt32,
        absolutePenX: Float? = nil,
        out: inout [UInt8],
        census: inout OutlineFillCensus?
    ) {
        let hw: Float = 0.5
        let across: Float = coverage == 3 ? 3.0 : 1.0
        let pen = absolutePenX ?? (Float(atX) + penX)
        @inline(__always) func lxOf(_ col: UInt32) -> Float {
            across == 1.0
                ? (Float(atX + col) + 0.5 - pen)
                : ((Float(atX + col) + 0.5 - pen) / across)
        }

        let zero = L.splat(0.0)
        let one = L.splat(1.0)
        let half = L.splat(hw)
        let laneN = L.laneCount

        for row in 0..<Int(h) {
            let a = table.starts[row]
            let b = table.starts[row + 1]
            let n = b - a
            let baseOut = out.count
            out.append(contentsOf: repeatElement(0, count: Int(w)))
            if n == 0 {
                if var c = census {
                    c.texels += UInt64(w)
                    c.clear += UInt64(w)
                    census = c
                }
                continue
            }

            let ly = table.ly[row]
            let tailBase = table.tailStarts[row]
            let groups = (Int(w) + laneN - 1) / laneN
            var slots = [SIMD4<Float>](repeating: .zero, count: groups * n)
            var startedList: [SIMD4<Float>] = []
            startedList.reserveCapacity(groups)
            var jobs: [Job] = []

            for g in 0..<groups {
                let c0 = g * laneN
                let activeLanes = min(laneN, Int(w) - c0)
                var lxs = SIMD4<Float>.zero
                for k in 0..<laneN {
                    lxs[k] = lxOf(UInt32(c0 + min(k, activeLanes - 1)))
                }
                let lx = L.load(lxs)
                var started = zero
                for k in 0..<n {
                    let rowPieceIdx = a + table.byMin[a + k]
                    let rp = table.rows[rowPieceIdx]
                    let begun = L.lt(L.sub(L.splat(rp.xMin), lx), half)
                    started = L.add(started, L.select(begun, one, zero))
                    let spans = L.and(begun, L.gt(L.sub(L.splat(rp.xMax), lx), L.neg(half)))

                    let constant: L
                    let integral: L.LaneMask
                    switch rp.stretch {
                    case .empty:
                        continue
                    case .within(let lo, let hi, let right):
                        let rightOf = L.ge(L.sub(L.splat(lo), lx), half)
                        let leftOf = L.le(L.sub(L.splat(hi), lx), L.neg(half))
                        constant = L.select(L.and(spans, rightOf), L.splat(right), zero)
                        integral = L.andNot(L.andNot(spans, rightOf), leftOf)
                    case .bent:
                        constant = zero
                        integral = spans
                    }
                    let slot = g * n + k
                    slots[slot] = L.store(constant)
                    var wanted = L.bits(integral) & UInt32((1 << activeLanes) - 1)
                    while wanted != 0 {
                        let lane = wanted.trailingZeroBitCount
                        wanted &= wanted - 1
                        jobs.append(Job(slot: slot, lane: lane, rowPieceIdx: rowPieceIdx, lx: lxs[lane]))
                    }
                }
                startedList.append(L.store(started))
            }

            var jobIdx = 0
            while jobIdx < jobs.count {
                var v = [SIMD4<Float>](repeating: .zero, count: 8)
                let countChunk = min(laneN, jobs.count - jobIdx)
                for k in 0..<laneN {
                    let j = jobs[jobIdx + min(k, countChunk - 1)]
                    let rp = table.rows[j.rowPieceIdx]
                    v[0][k] = rp.p0.x - j.lx
                    v[1][k] = rp.p0.y - ly
                    v[2][k] = rp.p1.x - j.lx
                    v[3][k] = rp.p1.y - ly
                    v[4][k] = rp.p2.x - j.lx
                    v[5][k] = rp.p2.y - ly
                    v[6][k] = rp.ty0
                    v[7][k] = rp.ty1
                }
                let cov = L.store(OutlineCover.integrateX(
                    q1: (L.load(v[0]), L.load(v[1])),
                    q2: (L.load(v[2]), L.load(v[3])),
                    q3: (L.load(v[4]), L.load(v[5])),
                    t: (L.load(v[6]), L.load(v[7])),
                    hx: half
                ))
                for k in 0..<countChunk {
                    let j = jobs[jobIdx + k]
                    slots[j.slot][j.lane] = cov[k]
                }
                jobIdx += laneN
            }

            if var c = census {
                c.integrals += UInt64(jobs.count)
                census = c
            }

            for g in 0..<groups {
                let c0 = g * laneN
                let activeLanes = min(laneN, Int(w) - c0)
                var tailVec = SIMD4<Float>.zero
                for k in 0..<laneN {
                    let tailOffset = min(n, max(0, Int(startedList[g][k])))
                    tailVec[k] = table.tails[tailBase + tailOffset]
                }
                var acc = L.load(tailVec)
                for k in 0..<n {
                    acc = L.add(acc, L.load(slots[g * n + k]))
                }
                let final = L.store(acc)
                for k in 0..<activeLanes {
                    let norm = min(1.0, abs(final[k]) / (4.0 * hw * hw)) * 255.0
                    out[baseOut + c0 + k] = UInt8(clamping: Int(norm.rounded(.toNearestOrEven)))
                }
            }

            if var c = census {
                c.texels += UInt64(w)
                c.rowPieces += UInt64(n)
                for col in 0..<Int(w) {
                    let b = out[baseOut + col]
                    if b == 0 { c.clear += 1 }
                    if b == 255 { c.solid += 1 }
                }
                census = c
            }
        }
    }
}

// MARK: - Recorded FillSet Benchmark Harness (rune::text::fill_bench)

public enum OutlineFillLanes: Sendable, Equatable {
    case native
    case portable
    case one
}

/// Decodable recorded fill workload (`RUNEFIL1`, `rune::text::fill_bench::FillSet`).
public struct OutlineFillSet: Sendable {
    public static let magic: [UInt8] = Array("RUNEFIL1".utf8)

    public let store: OutlineStore
    public let fills: [QueuedOutlineFill]

    public init(store: OutlineStore, fills: [QueuedOutlineFill]) {
        self.store = store
        self.fills = fills
    }

    public static func decode(_ bytes: [UInt8]) -> OutlineFillSet? {
        guard bytes.count >= magic.count, Array(bytes[0..<magic.count]) == magic else { return nil }
        var pos = magic.count
        func nextU32() -> UInt32? {
            guard pos + 4 <= bytes.count else { return nil }
            let v = UInt32(bytes[pos])
                | (UInt32(bytes[pos + 1]) << 8)
                | (UInt32(bytes[pos + 2]) << 16)
                | (UInt32(bytes[pos + 3]) << 24)
            pos += 4
            return v
        }
        guard let texelCount = nextU32() else { return nil }
        var texels: [SIMD4<UInt32>] = []
        texels.reserveCapacity(Int(texelCount))
        for _ in 0..<texelCount {
            guard let a = nextU32(), let b = nextU32(), let c = nextU32(), let d = nextU32() else { return nil }
            texels.append(SIMD4<UInt32>(a, b, c, d))
        }
        guard let fillCount = nextU32() else { return nil }
        var fills: [QueuedOutlineFill] = []
        fills.reserveCapacity(Int(fillCount))
        for _ in 0..<fillCount {
            guard let x = nextU32(), let y = nextU32(), let w = nextU32(), let h = nextU32(),
                  let record = nextU32(), let hint = nextU32(),
                  let scaleBits = nextU32(), let radiusBits = nextU32(),
                  let pxBits = nextU32(), let pyBits = nextU32(),
                  let coverage = nextU32() else { return nil }
            fills.append(QueuedOutlineFill(
                rect: SIMD4<UInt32>(x, y, w, h),
                fill: OutlineFillParams(
                    record: record,
                    hint: hint,
                    scale: Float(bitPattern: scaleBits),
                    radius: Float(bitPattern: radiusBits),
                    pen: SIMD2<Float>(Float(bitPattern: pxBits), Float(bitPattern: pyBits)),
                    coverage: coverage
                )
            ))
        }
        return OutlineFillSet(store: OutlineStore(texels: texels), fills: fills)
    }

    public var masks: Int { fills.count }
    public var texels: UInt64 { fills.reduce(0) { $0 + UInt64($1.rect[2] * $1.rect[3]) } }

    public func bytes(lanes: OutlineFillLanes) -> [UInt8] {
        var outs = [[UInt8]](repeating: [], count: fills.count)
        for group in OutlineMaskFiller.shareRows(fills) {
            var groupOuts = [[UInt8]](repeating: [], count: group.count)
            var census: OutlineFillCensus? = nil
            switch lanes {
            case .native, .portable:
                OutlineMaskFiller.fillShared(OutlineF4.self, store: store, fills: fills, group: group, outs: &groupOuts, census: &census)
            case .one:
                OutlineMaskFiller.fillShared(Float.self, store: store, fills: fills, group: group, outs: &groupOuts, census: &census)
            }
            for (gi, fi) in group.enumerated() {
                outs[Int(fi)] = groupOuts[gi]
            }
        }
        return outs.flatMap { $0 }
    }

    public func census() -> OutlineFillCensus {
        var result = OutlineFillCensus()
        for group in OutlineMaskFiller.shareRows(fills) {
            var groupOuts = [[UInt8]](repeating: [], count: group.count)
            var optionalCensus: OutlineFillCensus? = result
            OutlineMaskFiller.fillShared(OutlineF4.self, store: store, fills: fills, group: group, outs: &groupOuts, census: &optionalCensus)
            if let updated = optionalCensus {
                result = updated
            }
        }
        return result
    }
}
