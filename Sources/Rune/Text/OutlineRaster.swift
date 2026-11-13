import Foundation
#if canImport(CoreText) && canImport(CoreGraphics)
import CoreText
import CoreGraphics
#endif

// MARK: - Outline Instance & Constants (rune::text::outline)

/// A glyph drawn from its GPU/CPU quadratic outline record (`rune::text::outline::Outline`).
public struct GlyphOutline: Sendable, Equatable {
    /// Text weight multiplier aligning Windfoil's exact curve integration with CoreText flattening.
    public static let textWeight: Double = 0.93
    /// Maximum rest-pixel offset applied by CoreGraphics hint transforms.
    public static let hintReach: Float = 1.5

    /// Baseline origin in device pixels `[x, y]`.
    public var pen: SIMD2<Float>
    /// Rest pixels per font unit.
    public var scale: Float
    /// Device pixels per rest pixel.
    public var zoom: Float
    /// Outline store record index.
    public var record: UInt32
    /// Hint transform record index (`0` for none).
    public var hint: UInt32
    /// Dilation radius in rest pixels.
    public var radius: Float
    /// Coverage function selector (`0` Windfoil box filter, `1` Slug rays).
    public var coverage: UInt32

    public init(
        pen: SIMD2<Float>,
        scale: Float,
        zoom: Float,
        record: UInt32,
        hint: UInt32 = 0,
        radius: Float = 0,
        coverage: UInt32 = 0
    ) {
        self.pen = pen
        self.scale = scale
        self.zoom = zoom
        self.record = record
        self.hint = hint
        self.radius = radius
        self.coverage = coverage
    }

    /// Device-pixel bounding rect `[x, y, w, h]` holding every pixel touched by `bbox` (in font units, y up).
    public func rect(bbox: SIMD4<Float>) -> SIMD4<Float> {
        let s = scale
        let r = radius
        let z = zoom
        let reach: Float = hint != 0 ? Self.hintReach : 0
        let x0 = bbox[0] * s - r - 1.0
        let x1 = bbox[2] * s + r + 1.0
        let y0 = bbox[1] * s - reach - 1.0
        let y1 = bbox[3] * s + 2.0 * r + reach + 1.0
        return SIMD4<Float>(pen[0] + x0 * z, pen[1] - y1 * z, (x1 - x0) * z, (y1 - y0) * z)
    }
}

/// How an outline is grid-fitted before storing (`rune::text::outline::Hinting`).
public enum OutlineHinting: Sendable, Equatable, Hashable {
    case none
    case trueType(ppem: Float)
    case auto(ppem: Float)
    case vertical(ppem: Float)

    public func key() -> UInt64 {
        switch self {
        case .none:
            return 0
        case .trueType(let ppem):
            return UInt64(ppem.bitPattern)
        case .auto(let ppem):
            return (1 << 32) | UInt64(ppem.bitPattern)
        case .vertical(let ppem):
            return (2 << 32) | UInt64(ppem.bitPattern)
        }
    }
}

// MARK: - Outline Path & Band Builder (rune::text::outline::build)

/// Vector outline command in glyph/font space (`y` up).
public enum OutlinePathCommand: Sendable, Equatable {
    case moveTo(SIMD2<Double>)
    case lineTo(SIMD2<Double>)
    case quadTo(SIMD2<Double>, SIMD2<Double>)
    case curveTo(SIMD2<Double>, SIMD2<Double>, SIMD2<Double>)
    case close
}

/// Built outline record ready for upload to `OutlineStore` (`rune::text::outline::build::Built`).
public struct BuiltOutline: Sendable, Equatable {
    public var texels: [SIMD4<UInt32>]
    /// Ink box in font units before dilation: `[x0, y0, x1, y1]` (y up).
    public var bbox: SIMD4<Float>
    public var upem: Float

    public init(texels: [SIMD4<UInt32>], bbox: SIMD4<Float>, upem: Float = 0) {
        self.texels = texels
        self.bbox = bbox
        self.upem = upem
    }
}

public enum OutlineBuilder {
    static let targetPerBand = 10
    static let maxBands = 64
    static let sortMin = 4
    static let connectorBit: UInt32 = 1 << 8

    private struct Quad {
        var x0, y0, cx, cy, x1, y1: Double
    }

    private struct Element {
        var q: Quad
        var code: UInt32

        var isConnector: Bool { (code & OutlineBuilder.connectorBit) != 0 }
        var yRange: (Double, Double) { (min(q.y0, q.y1), max(q.y0, q.y1)) }
        var xMax: Double { max(q.x0, max(q.cx, q.x1)) }
    }

    /// Builds `commands` (in font space scaled by `unit`, leaning by `skew = tan(angle)`) into
    /// dilated monotone pieces and row bands, or `nil` for an empty outline.
    public static func build<S: Sequence>(
        commands: S,
        unit: Double = 1.0,
        skew: Double = 0.0,
        upem: Float = 0.0
    ) -> BuiltOutline? where S.Element == OutlinePathCommand {
        var ctrs = contours(commands, unit: unit, skew: skew)
        guard !ctrs.allSatisfy(\.isEmpty) else { return nil }
        if signedArea(ctrs) < 0 {
            ctrs = reverse(ctrs)
        }
        var elements: [Element] = []
        for c in ctrs {
            dilationElements(c, into: &elements)
        }
        var x0 = Double.greatestFiniteMagnitude
        var y0 = Double.greatestFiniteMagnitude
        var x1 = -Double.greatestFiniteMagnitude
        var y1 = -Double.greatestFiniteMagnitude
        for c in ctrs {
            for q in c {
                x0 = min(x0, min(q.x0, min(q.cx, q.x1)))
                y0 = min(y0, min(q.y0, min(q.cy, q.y1)))
                x1 = max(x1, max(q.x0, max(q.cx, q.x1)))
                y1 = max(y1, max(q.y0, max(q.cy, q.y1)))
            }
        }
        guard x1 >= x0 && y1 >= y0 else { return nil }
        return BuiltOutline(
            texels: bands(elements, y0: y0, y1: y1),
            bbox: SIMD4<Float>(Float(x0), Float(y0), Float(x1), Float(y1)),
            upem: upem
        )
    }

    #if canImport(CoreText) && canImport(CoreGraphics)
    /// Extracts font-unit `OutlinePathCommand`s from a CoreText glyph (`CTFontCreatePathForGlyph`).
    public static func commands(font: CTFont, glyph: CGGlyph) -> [OutlinePathCommand] {
        var cgPath = CTFontCreatePathForGlyph(font, glyph, nil)
        guard let path = cgPath else { return [] }
        let upem = Double(CTFontGetUnitsPerEm(font))
        let fontSize = Double(CTFontGetSize(font))
        let toFontUnits = fontSize > 0 ? upem / fontSize : 1.0

        var out: [OutlinePathCommand] = []
        path.applyWithBlock { elemPtr in
            let elem = elemPtr.pointee
            func pt(_ idx: Int) -> SIMD2<Double> {
                let p = elem.points[idx]
                return SIMD2<Double>(Double(p.x) * toFontUnits, Double(p.y) * toFontUnits)
            }
            switch elem.type {
            case .moveToPoint:
                out.append(.moveTo(pt(0)))
            case .addLineToPoint:
                out.append(.lineTo(pt(0)))
            case .addQuadCurveToPoint:
                out.append(.quadTo(pt(0), pt(1)))
            case .addCurveToPoint:
                out.append(.curveTo(pt(0), pt(1), pt(2)))
            case .closeSubpath:
                out.append(.close)
            @unknown default:
                break
            }
        }
        _ = { cgPath = nil }()
        return out
    }
    #endif

    private static func contours<S: Sequence>(
        _ commands: S,
        unit: Double,
        skew: Double
    ) -> [[Quad]] where S.Element == OutlinePathCommand {
        func mapPt(_ v: SIMD2<Double>) -> SIMD2<Double> {
            SIMD2<Double>((v.x + v.y * skew) * unit, v.y * unit)
        }
        var out: [[Quad]] = []
        var cur = SIMD2<Double>.zero
        var start = SIMD2<Double>.zero
        var isOpen = false

        func closeCurrent() {
            guard !out.isEmpty, !out[out.count - 1].isEmpty else { return }
            out[out.count - 1].append(Quad(
                x0: cur.x, y0: cur.y,
                cx: (cur.x + start.x) * 0.5, cy: (cur.y + start.y) * 0.5,
                x1: start.x, y1: start.y
            ))
        }

        for cmd in commands {
            switch cmd {
            case .moveTo(let a):
                if isOpen { closeCurrent() }
                let mapped = mapPt(a)
                cur = mapped
                start = mapped
                isOpen = true
                out.append([])
            case .lineTo(let a):
                let mapped = mapPt(a)
                if !out.isEmpty {
                    out[out.count - 1].append(Quad(
                        x0: cur.x, y0: cur.y,
                        cx: (cur.x + mapped.x) * 0.5, cy: (cur.y + mapped.y) * 0.5,
                        x1: mapped.x, y1: mapped.y
                    ))
                }
                cur = mapped
            case .quadTo(let c1, let a):
                let mc1 = mapPt(c1)
                let ma = mapPt(a)
                if !out.isEmpty {
                    out[out.count - 1].append(Quad(
                        x0: cur.x, y0: cur.y,
                        cx: mc1.x, cy: mc1.y,
                        x1: ma.x, y1: ma.y
                    ))
                }
                cur = ma
            case .curveTo(let c1, let c2, let a):
                let mc1 = mapPt(c1)
                let mc2 = mapPt(c2)
                let ma = mapPt(a)
                if !out.isEmpty {
                    cubicQuads([cur, mc1, mc2, ma], into: &out[out.count - 1])
                }
                cur = ma
            case .close:
                if isOpen { closeCurrent() }
                cur = start
                isOpen = false
            }
        }
        if isOpen { closeCurrent() }
        return out
    }

    private static func cubicQuads(_ p: [SIMD2<Double>], into out: inout [Quad]) {
        let tolerance = 0.1
        let dx = p[3].x - 3.0 * p[2].x + 3.0 * p[1].x - p[0].x
        let dy = p[3].y - 3.0 * p[2].y + 3.0 * p[1].y - p[0].y
        let err = hypot(dx, dy) * 3.0.squareRoot() / 36.0
        let n = min(16, max(1, Int(ceil(cbrt(err / tolerance)))))

        func at(_ t: Double) -> SIMD2<Double> {
            let u = 1.0 - t
            let w0 = u * u * u
            let w1 = 3.0 * u * u * t
            let w2 = 3.0 * u * t * t
            let w3 = t * t * t
            return p[0] * w0 + p[1] * w1 + p[2] * w2 + p[3] * w3
        }

        func tangent(_ t: Double) -> SIMD2<Double> {
            let u = 1.0 - t
            let a = (p[1] - p[0]) * (u * u)
            let b = (p[2] - p[1]) * (2.0 * u * t)
            let c = (p[3] - p[2]) * (t * t)
            return (a + b + c) * 3.0
        }

        for i in 0..<n {
            let t0 = Double(i) / Double(n)
            let t1 = Double(i + 1) / Double(n)
            let a = at(t0)
            let b = at(t1)
            let ta = tangent(t0)
            let tb = tangent(t1)
            let den = ta.x * tb.y - ta.y * tb.x
            var c: SIMD2<Double>
            if abs(den) > 1e-12 {
                let s = ((b.x - a.x) * tb.y - (b.y - a.y) * tb.x) / den
                c = a + ta * s
            } else {
                let m = at((t0 + t1) * 0.5)
                c = m * 2.0 - (a + b) * 0.5
            }
            let chord = hypot(b.x - a.x, b.y - a.y)
            let off = hypot(c.x - (a.x + b.x) * 0.5, c.y - (a.y + b.y) * 0.5)
            if !(abs(den) > 1e-12 && off <= chord * 2.0) {
                let m = at((t0 + t1) * 0.5)
                c = m * 2.0 - (a + b) * 0.5
            }
            out.append(Quad(x0: a.x, y0: a.y, cx: c.x, cy: c.y, x1: b.x, y1: b.y))
        }
    }

    private static func signedArea(_ contours: [[Quad]]) -> Double {
        func cross(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
            ax * by - ay * bx
        }
        var sum = 0.0
        for c in contours {
            for q in c {
                sum += 2.0 * cross(q.x0, q.y0, q.cx, q.cy)
                    + cross(q.x0, q.y0, q.x1, q.y1)
                    + 2.0 * cross(q.cx, q.cy, q.x1, q.y1)
            }
        }
        return sum / 6.0
    }

    private static func reverse(_ contours: [[Quad]]) -> [[Quad]] {
        contours.map { c in
            c.reversed().map { q in
                Quad(x0: q.x1, y0: q.y1, cx: q.cx, cy: q.cy, x1: q.x0, y1: q.y0)
            }
        }
    }

    private static func code(x: Int32, y: Int32) -> UInt32 {
        UInt32(bitPattern: (x + 1) | (y << 2))
    }

    private static func directionCode(_ q: Quad) -> UInt32 {
        func sign(_ v: Float) -> Int32 { v > 0 ? 1 : (v < 0 ? -1 : 0) }
        let dx = Float(q.x1) - Float(q.x0)
        let dy = Float(q.y1) - Float(q.y0)
        return code(x: sign(dy), y: 1 - sign(dx))
    }

    private static func extremumT(_ p0: Double, _ p1: Double, _ p2: Double) -> Double? {
        let a = p0 - 2.0 * p1 + p2
        guard a != 0 else { return nil }
        let t = (p0 - p1) / a
        return (t > 0.0 && t < 1.0) ? t : nil
    }

    private static func subdivide(_ q: Quad, t: Double) -> (Quad, Quad) {
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        let x01 = lerp(q.x0, q.cx)
        let y01 = lerp(q.y0, q.cy)
        let x12 = lerp(q.cx, q.x1)
        let y12 = lerp(q.cy, q.y1)
        let xm = lerp(x01, x12)
        let ym = lerp(y01, y12)
        return (
            Quad(x0: q.x0, y0: q.y0, cx: x01, cy: y01, x1: xm, y1: ym),
            Quad(x0: xm, y0: ym, cx: x12, cy: y12, x1: q.x1, y1: q.y1)
        )
    }

    private static func monotone(_ q: Quad, into out: inout [Quad]) {
        let tx = extremumT(q.x0, q.cx, q.x1)
        let ty = extremumT(q.y0, q.cy, q.y1)
        let ts: [Double]
        switch (tx, ty) {
        case (.some(let a), .some(let b)):
            ts = a <= b ? [a, b] : [b, a]
        case (.some(let a), .none):
            ts = [a]
        case (.none, .some(let b)):
            ts = [b]
        case (.none, .none):
            ts = []
        }
        var rest = q
        var consumed = 0.0
        for t in ts {
            let local = (t - consumed) / (1.0 - consumed)
            guard local > 0.0 && local < 1.0 else { continue }
            let (l, r) = subdivide(rest, t: local)
            out.append(l)
            rest = r
            consumed = t
        }
        out.append(rest)
    }

    private static func dilationElements(_ contour: [Quad], into out: inout [Element]) {
        guard !contour.isEmpty else { return }
        var pieces: [(Quad, UInt32)] = []
        for q in contour {
            if q.x0 == q.x1 && q.y0 == q.y1 {
                pieces.append((q, code(x: 0, y: 1)))
                continue
            }
            var split: [Quad] = []
            monotone(q, into: &split)
            for s in split {
                pieces.append((s, directionCode(s)))
            }
        }
        let n = pieces.count
        for i in 0..<n {
            let (q, c) = pieces[i]
            if q.y0 != q.cy || q.y0 != q.y1 {
                out.append(Element(q: q, code: c | (c << 4)))
            }
            let next = pieces[(i + 1) % n].1
            if next != c {
                let conn = Quad(x0: q.x1, y0: q.y1, cx: q.x1, cy: q.y1, x1: q.x1, y1: q.y1)
                out.append(Element(q: conn, code: c | (next << 4) | connectorBit))
            }
        }
    }

    private static func bands(_ elements: [Element], y0: Double, y1: Double) -> [SIMD4<UInt32>] {
        let n = elements.count
        var r = n <= targetPerBand ? 1 : min(maxBands, (n + targetPerBand - 1) / targetPerBand)
        let invH = (r > 1 && y1 > y0) ? Double(r) / (y1 - y0) : 0.0
        if invH == 0.0 { r = 1 }

        func bandIndex(_ y: Double) -> Int {
            guard invH != 0.0 else { return 0 }
            return min(r - 1, max(0, Int(floor((y - y0) * invH))))
        }

        var buckets = [[Int]](repeating: [], count: r)
        for (k, e) in elements.enumerated() {
            let (lo, hi) = e.yRange
            if e.isConnector {
                buckets[bandIndex(lo)].append(k)
            } else {
                for b in bandIndex(lo)...bandIndex(hi) {
                    buckets[b].append(k)
                }
            }
        }

        @inline(__always) func bits(_ v: Double) -> UInt32 { Float(v).bitPattern }
        var texels: [SIMD4<UInt32>] = [SIMD4<UInt32>(1, UInt32(r), bits(y0), bits(invH))]
        texels.append(contentsOf: repeatElement(.zero, count: r))

        for b in 0..<r {
            if buckets[b].count > sortMin {
                buckets[b].sort { elements[$0].xMax > elements[$1].xMax }
            }
            texels[1 + b] = SIMD4<UInt32>(UInt32(texels.count), UInt32(buckets[b].count), 0, 0)
            for k in buckets[b] {
                let e = elements[k]
                texels.append(SIMD4<UInt32>(bits(e.q.x0), bits(e.q.y0), bits(e.q.cx), bits(e.q.cy)))
                texels.append(SIMD4<UInt32>(bits(e.q.x1), bits(e.q.y1), e.code, bits(e.xMax)))
            }
        }
        return texels
    }
}

// MARK: - Outline Store (rune::text::outline::store)

public enum OutlineSupport: Sendable, Equatable {
    case untried
    case drawn
    case unavailable
}

public final class OutlineStore: @unchecked Sendable {
    public static let width: UInt32 = 1024
    public static let maxRows: UInt32 = 4096

    public struct Key: Hashable, Sendable, Equatable {
        public var font: UInt64
        public var index: UInt32
        public var glyph: UInt32
        public var coords: UInt64
        public var skew: UInt8
        public var hinted: UInt64

        public init(
            font: UInt64,
            index: UInt32 = 0,
            glyph: UInt32,
            coords: UInt64 = 0,
            skew: UInt8 = 0,
            hinted: UInt64 = 0
        ) {
            self.font = font
            self.index = index
            self.glyph = glyph
            self.coords = coords
            self.skew = skew
            self.hinted = hinted
        }
    }

    public struct Glyph: Sendable, Equatable {
        public var record: UInt32
        public var bbox: SIMD4<Float>
        public var upem: Float

        public init(record: UInt32, bbox: SIMD4<Float>, upem: Float) {
            self.record = record
            self.bbox = bbox
            self.upem = upem
        }
    }

    public enum Found: Sendable, Equatable {
        case outline(Glyph)
        case empty
        case full
    }

    private var texels: [SIMD4<UInt32>]
    private var used: Int
    private var glyphs: [Key: Glyph?] = [:]
    private var hints: [[UInt32]: UInt32] = [:]
    private var dirty: (UInt32, UInt32)?
    private var full: Bool = false
    public private(set) var support: OutlineSupport = .untried

    public init() {
        self.texels = Array(repeating: .zero, count: Int(Self.width))
        self.used = 1
    }

    public init(texels: [SIMD4<UInt32>]) {
        self.texels = texels.isEmpty ? Array(repeating: .zero, count: Int(Self.width)) : texels
        self.used = max(1, texels.count)
    }

    public func glyph(_ key: Key, build: () -> BuiltOutline?) -> Found {
        if let cached = glyphs[key] {
            return cached.map(Found.outline) ?? .empty
        }
        guard let built = build() else {
            glyphs[key] = .some(nil)
            return .empty
        }
        guard let record = push(built.texels, relative: true) else {
            return .full
        }
        let g = Glyph(record: record, bbox: built.bbox, upem: built.upem)
        glyphs[key] = .some(g)
        return .outline(g)
    }

    public func hint(_ values: [Double]) -> UInt32 {
        precondition(values.count == 11)
        let bits = values.map { Float($0).bitPattern }
        if let at = hints[bits] {
            return at
        }
        let hintTexels = [
            SIMD4<UInt32>(bits[0], bits[1], bits[2], bits[3]),
            SIMD4<UInt32>(bits[4], bits[5], bits[6], bits[7]),
            SIMD4<UInt32>(bits[8], bits[9], bits[10], 0),
        ]
        guard let at = push(hintTexels, relative: false) else { return 0 }
        hints[bits] = at
        return at
    }

    private func push(_ incoming: [SIMD4<UInt32>], relative: Bool) -> UInt32? {
        let at = used
        let end = at + incoming.count
        guard end <= Int(Self.maxRows * Self.width) else {
            full = true
            return nil
        }
        let w = Int(Self.width)
        if end > texels.count {
            let aligned = ((end + w - 1) / w) * w
            texels.append(contentsOf: repeatElement(.zero, count: aligned - texels.count))
        }
        for i in 0..<incoming.count {
            texels[at + i] = incoming[i]
        }
        if relative, let first = incoming.first {
            let bandCount = Int(first[1])
            for idx in at..<(at + 1 + bandCount) {
                texels[idx][0] &+= UInt32(at)
            }
        }
        used = end
        let rowStart = UInt32(at) / Self.width
        let rowEnd = (UInt32(end) + Self.width - 1) / Self.width
        if let d = dirty {
            dirty = (min(d.0, rowStart), max(d.1, rowEnd))
        } else {
            dirty = (rowStart, rowEnd)
        }
        return UInt32(at)
    }

    @discardableResult
    public func beginFrame(pinned: Bool) -> Bool {
        guard full && !pinned else { return false }
        full = false
        used = 1
        glyphs.removeAll(keepingCapacity: true)
        hints.removeAll(keepingCapacity: true)
        return true
    }

    public func usedTexels() -> ArraySlice<SIMD4<UInt32>> {
        texels[0..<used]
    }

    public func texel(_ i: UInt32) -> SIMD4<UInt32> {
        let idx = Int(i)
        return idx < texels.count ? texels[idx] : .zero
    }

    public var hasRecords: Bool { used > 1 }

    public func setSupport(_ support: OutlineSupport) {
        self.support = support
    }

    public var rows: UInt32 {
        UInt32(texels.count / Int(Self.width))
    }

    public func takeDirty() -> (UInt32, [UInt8])? {
        guard let (y0, y1) = dirty else { return nil }
        dirty = nil
        let start = Int(y0 * Self.width)
        let end = Int(y1 * Self.width)
        var bytes: [UInt8] = []
        bytes.reserveCapacity((end - start) * 16)
        for t in texels[start..<end] {
            for lane in 0..<4 {
                var v = t[lane].littleEndian
                withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) }
            }
        }
        return (y0, bytes)
    }

    public func invalidate() {
        dirty = (0, rows)
    }
}

// MARK: - RasterPath State Machine (rune::text::outline::path)

/// Per-text rasterization mode machine (`Still`, `Moving`, `Landing`).
public enum OutlineRasterPath: Sendable, Equatable {
    case still
    case moving
    case landing

    public enum Frame: Sendable, Equatable {
        case resting
        case moving
    }

    public enum PathEffect: Sendable, Equatable {
        case placeMasks
    }

    public enum Emit: Sendable, Equatable {
        case atlas
        case outline
    }

    public mutating func step(_ frame: Frame) -> [PathEffect] {
        switch (self, frame) {
        case (_, .moving):
            self = .moving
            return []
        case (.moving, .resting):
            self = .landing
            return [.placeMasks]
        case (.landing, .resting), (.still, .resting):
            self = .still
            return []
        }
    }

    public var emit: Emit {
        switch self {
        case .still: return .atlas
        case .moving, .landing: return .outline
        }
    }
}

/// Frame-to-frame `OutlineRasterPath` tracker keyed by node ID.
public struct OutlinePaths: Sendable {
    private var now: [UInt64: OutlineRasterPath] = [:]
    private var last: [UInt64: OutlineRasterPath] = [:]

    public init() {}

    public mutating func beginFrame() {
        swap(&now, &last)
        now.removeAll(keepingCapacity: true)
    }

    public mutating func step(node: UInt64, frame: OutlineRasterPath.Frame) -> (OutlineRasterPath, [OutlineRasterPath.PathEffect]) {
        if let existing = now[node] {
            return (existing, [])
        }
        var path = last.removeValue(forKey: node) ?? .still
        let effects = path.step(frame)
        if path != .still {
            now[node] = path
        }
        return (path, effects)
    }
}
