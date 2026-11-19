import Foundation
import RuneRef
#if canImport(simd)
import simd
#endif

public protocol CpuBootExec: Sendable {
    var threads: Int { get }
    func run(_ job: @Sendable () -> Void)
}

/// Threads spawned for a single `CpuBoot.paint` call and joined before returning (`cpu_boot::raster::Spawn`).
public struct CpuBootSpawnExec: CpuBootExec {
    public let count: Int
    public var threads: Int {
        #if os(WASI)
        1
        #else
        max(1, count)
        #endif
    }

    public init(_ count: Int) {
        self.count = count
    }

    public func run(_ job: @Sendable () -> Void) {
        #if os(WASI)
        job()
        #else
        let n = threads
        if n <= 1 {
            job()
            return
        }
        DispatchQueue.concurrentPerform(iterations: n) { _ in
            job()
        }
        #endif
    }
}

/// CPU tile rasterizer (`cpu_boot/raster.rs`).
public enum CpuBootRaster {
    static let tilePx: Int = Int(CpuBootBin.tileW * CpuBootBin.tileH)

    @inline(__always)
    public static func f16(_ v: Float, _ rounding: HalfRounding) -> Float {
        BackdropPyramid.half(v, nearestEven: rounding == .nearestEven)
    }

    @inline(__always)
    public static func f16x4(_ v: SIMD4<Float>, _ rounding: HalfRounding) -> SIMD4<Float> {
        BackdropPyramid.half4(v, nearestEven: rounding == .nearestEven)
    }

    private struct PowCache {
        var tables: [(UInt32, [Float])] = []
        static let maxTables = 16

        mutating func index(for exponent: Float) -> Int {
            let bits = exponent.bitPattern
            if let existing = tables.firstIndex(where: { $0.0 == bits }) {
                return existing
            }
            if tables.count == Self.maxTables {
                tables.removeFirst()
            }
            let values: [Float] = (0..<256).map { c in
                let f = Float(c) / 255.0
                return exponent == 1.0 ? f : powf(f, exponent)
            }
            tables.append((bits, values))
            return tables.count - 1
        }
    }

    private struct Surface: @unchecked Sendable {
        let base: UnsafeMutablePointer<UInt8>
        let len: Int
        let stride: Int

        @inline(__always)
        func at(_ x: UInt32, _ y: UInt32) -> Int {
            Int(y) * stride + Int(x) * 4
        }

        func fill(_ r: (UInt32, UInt32, UInt32, UInt32), _ px: (UInt8, UInt8, UInt8, UInt8)) {
            let count = Int(r.2 - r.0)
            for y in r.1..<r.3 {
                let offset = at(r.0, y)
                precondition(offset + count * 4 <= len)
                CpuBootBlend.fillRow(base, offset: offset, count: count, bgra: px)
            }
        }

        @inline(__always)
        func span(_ x0: UInt32, _ x1: UInt32, _ y: UInt32, _ c: SIMD4<Float>) {
            let count = Int(x1 - x0)
            let offset = at(x0, y)
            precondition(offset + count * 4 <= len)
            CpuBootBlend.overRow(base, offset: offset, count: count, src: CpuBootBlend.PreSrc(c))
        }

        @inline(__always)
        func blend(_ x: UInt32, _ y: UInt32, _ c: SIMD4<Float>) {
            let offset = at(x, y)
            precondition(offset + 4 <= len)
            CpuBootBlend.overRGBA(base, at: offset, c: c)
        }

        @inline(__always)
        func blendLCD(_ x: UInt32, _ y: UInt32, _ c: SIMD4<Float>, _ k: SIMD3<Float>) {
            let offset = at(x, y)
            precondition(offset + 4 <= len)
            CpuBootBlend.overLCD(base, at: offset, c: c, k: k)
        }

        @inline(__always)
        func writeOpaque(_ x: UInt32, _ y: UInt32, _ c: SIMD4<Float>) {
            let offset = at(x, y)
            precondition(offset + 4 <= len)
            let q = CpuBootBlend.quantizeColor(c)
            base[offset] = q.0
            base[offset + 1] = q.1
            base[offset + 2] = q.2
            base[offset + 3] = q.3
        }
    }

    private final class Scratch {
        var px: [SIMD4<Float>]
        var additive: Bool = false
        var plan: Int = 0

        init() {
            self.px = [SIMD4<Float>](repeating: .zero, count: CpuBootRaster.tilePx)
        }
    }

    private struct Occluder {
        let n: UInt32
        let within: UInt32
        let solid: CpuBootBin.Solid
        let clip: CpuBootShade.Clip
        let r: (UInt32, UInt32, UInt32, UInt32)
    }

    private struct Ranges {
        static let maxRuns = 8
        var runs: [(UInt32, UInt32)] = Array(repeating: (0, 0), count: maxRuns)
        var len: Int = 0

        mutating func cut(_ a: UInt32, _ b: UInt32) {
            var next = Array(repeating: (UInt32(0), UInt32(0)), count: Self.maxRuns)
            var nextLen = 0
            for idx in 0..<len {
                let (x0, x1) = runs[idx]
                let p0 = (x0, min(x1, a))
                if p0.1 > p0.0 {
                    if nextLen == Self.maxRuns { return }
                    next[nextLen] = p0
                    nextLen += 1
                }
                let p1 = (max(x0, b), x1)
                if p1.1 > p1.0 {
                    if nextLen == Self.maxRuns { return }
                    next[nextLen] = p1
                    nextLen += 1
                }
            }
            runs = next
            len = nextLen
        }
    }

    private struct Segment {
        let y1: UInt32
        let solid: (UInt32, UInt32)
        let whole: (Float, Float)
        let vis: Ranges
    }

    @inline(__always)
    private static func rowFrom(_ v: Float) -> UInt32 {
        UInt32(max(0, Int32(ceilf(v - 0.5))))
    }

    @inline(__always)
    private static func rowPast(_ v: Float) -> UInt32 {
        UInt32(max(0, Int32(floorf(v - 0.5) + 1.0)))
    }

    private static func solidBreaks(_ s: CpuBootBin.Solid, _ out: inout [UInt32]) {
        let (top, bottom) = s.bands()
        out.append(rowFrom(s.edges.y + s.inset))
        out.append(rowFrom(s.edges.y + top))
        out.append(rowPast(s.edges.w - bottom))
        out.append(rowPast(s.edges.w - s.inset))
    }

    private static func clipBreaks(_ c: CpuBootShade.Clip, _ out: inout [UInt32]) {
        let inset = c.inset()
        out.append(rowFrom(c.rect.y + inset.y))
        out.append(rowPast(c.rect.w - inset.w))
        if let radii = c.radii {
            let (top, bottom) = CpuBootBin.Solid(edges: c.rect, radii: radii, inset: 0.5).bands()
            out.append(rowFrom(c.rect.y + top))
            out.append(rowPast(c.rect.w - bottom))
        }
    }

    private static func centres(_ span: (Float, Float), _ x0: UInt32, _ x1: UInt32) -> (UInt32, UInt32) {
        if span.0 > span.1 { return (x1, x1) }
        let fx0 = Float(x0)
        let fx1 = Float(x1)
        let a = UInt32(min(max(ceilf(span.0 - 0.5), fx0), fx1))
        let b = UInt32(min(max(floorf(span.1 - 0.5) + 1.0, Float(a)), fx1))
        return (a, b)
    }

    @inline(__always)
    private static func holeAlpha(_ p: SIMD2<Float>, _ h: SIMD4<Float>) -> Float {
        if h.w <= 0.0 { return 1.0 }
        let dx = p.x - h.x
        let dy = p.y - h.y
        return min(max(((sqrtf(dx * dx + dy * dy) - (h.z + h.w) * 0.5) / max(h.w - h.z, 1.0)) + 0.5, 0.0), 1.0)
    }

    private struct TilePainter {
        let scene: CpuBootScene
        let bins: CpuBootBin.Bins
        let surface: Surface
        var stats: CpuBootReport = CpuBootReport()
        var powCache = PowCache()
        var layers: [Scratch] = []
        var depth: Int = 0
        var tile: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0)
        var occ: [Occluder] = []
        var currentN: UInt32 = 0
        var breaks: [UInt32] = []
        var segs: [Segment] = []
        let blurred: [CpuBootBackdrop.Blurred?]

        func tileRect(tx: UInt32, ty: UInt32) -> (UInt32, UInt32, UInt32, UInt32) {
            let w = UInt32(scene.size.0)
            let h = UInt32(scene.size.1)
            return (
                tx * CpuBootBin.tileW,
                ty * CpuBootBin.tileH,
                min((tx + 1) * CpuBootBin.tileW, w),
                min((ty + 1) * CpuBootBin.tileH, h)
            )
        }

        mutating func collectOccluders(_ list: ArraySlice<UInt32>) {
            occ.removeAll(keepingCapacity: true)
            for n in list {
                let idx = Int(n)
                let within = bins.within[idx]
                // Inside a PlusLighter layer every primitive adds to what came before it; an opaque
                // box never hides an earlier sibling (`#1228`).
                if within != CpuBootBin.topLayer && bins.layers[Int(within)].additive { continue }
                let i = scene.instances[idx]
                guard let solid = CpuBootBin.opaqueBox(i) else { continue }
                let b = bins.bounds[idx]
                let rx0 = max(UInt32(max(0, b.x)), tile.0)
                let ry0 = max(UInt32(max(0, b.y)), tile.1)
                let rx1 = min(UInt32(max(0, b.z)), tile.2)
                let ry1 = min(UInt32(max(0, b.w)), tile.3)
                if rx1 > rx0 && ry1 > ry0 {
                    occ.append(Occluder(n: n, within: within, solid: solid, clip: CpuBootShade.Clip.of(i), r: (rx0, ry0, rx1, ry1)))
                }
            }
        }

        mutating func computeSegments(
            _ r: (UInt32, UInt32, UInt32, UInt32),
            solid: CpuBootBin.Solid?,
            clip: CpuBootShade.Clip
        ) {
            breaks.removeAll(keepingCapacity: true)
            breaks.append(r.1)
            breaks.append(r.3)
            if let solid { solidBreaks(solid, &breaks) }
            clipBreaks(clip, &breaks)

            var lo = 0
            var hi = occ.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if occ[mid].n <= currentN { lo = mid + 1 } else { hi = mid }
            }
            let within = bins.within[Int(currentN)]
            var relevant: [Occluder] = []
            for idx in lo..<occ.count {
                let o = occ[idx]
                if o.within == within && o.r.1 < r.3 && o.r.3 > r.1 && o.r.0 < r.2 && o.r.2 > r.0 {
                    relevant.append(o)
                    breaks.append(o.r.1)
                    breaks.append(o.r.3)
                    solidBreaks(o.solid, &breaks)
                    clipBreaks(o.clip, &breaks)
                }
            }

            breaks.removeAll { $0 < r.1 || $0 > r.3 }
            breaks.sort()
            var deduped: [UInt32] = []
            deduped.reserveCapacity(breaks.count)
            for b in breaks where deduped.last != b {
                deduped.append(b)
            }
            breaks = deduped

            segs.removeAll(keepingCapacity: true)
            guard breaks.count >= 2 else { return }
            for w in 0..<(breaks.count - 1) {
                let ya = breaks[w]
                let yb = breaks[w + 1]
                let pa = Float(ya) + 0.5
                let pb = Float(yb - 1) + 0.5
                let whole = CpuBootBin.intersect(CpuBootBin.clipSpan(clip, y: pa), CpuBootBin.clipSpan(clip, y: pb))
                let inside: (Float, Float)
                if let solid {
                    inside = CpuBootBin.intersect(
                        CpuBootBin.intersect(solid.span(at: pa), solid.span(at: pb)),
                        whole
                    )
                } else {
                    inside = CpuBootBin.emptySpan
                }
                var vis = Ranges()
                vis.runs[0] = (r.0, r.2)
                vis.len = 1
                for o in relevant where o.r.1 <= ya && o.r.3 >= yb {
                    let covered = CpuBootBin.intersect(
                        CpuBootBin.intersect(o.solid.span(at: pa), o.solid.span(at: pb)),
                        CpuBootBin.intersect(CpuBootBin.clipSpan(o.clip, y: pa), CpuBootBin.clipSpan(o.clip, y: pb))
                    )
                    let (ca, cb) = centres(covered, o.r.0, o.r.2)
                    if cb > ca { vis.cut(ca, cb) }
                    if vis.len == 0 { break }
                }
                segs.append(Segment(y1: yb, solid: centres(inside, r.0, r.2), whole: whole, vis: vis))
            }
        }

        @inline(__always)
        func slot(_ x: UInt32, _ y: UInt32) -> Int {
            Int((y - tile.1) * CpuBootBin.tileW + (x - tile.0))
        }

        @inline(__always)
        mutating func put(_ x: UInt32, _ y: UInt32, _ c: SIMD4<Float>) {
            if depth == 0 {
                if max(max(c.x, c.y), max(c.z, c.w)) * 255.0 <= 0.5 { return }
                surface.blend(x, y, c)
                return
            }
            let s = slot(x, y)
            let top = layers[depth - 1]
            let d = top.px[s]
            let half = scene.half
            let c16 = f16x4(c, half)
            let k: Float = top.additive ? 1.0 : (1.0 - c16.w)
            top.px[s] = f16x4(c16 + d * k, half)
        }

        mutating func putSpan(_ x0: UInt32, _ x1: UInt32, _ y: UInt32, _ c: SIMD4<Float>) {
            if x1 <= x0 { return }
            stats.spanPx += UInt64(x1 - x0)
            if depth == 0 {
                surface.span(x0, x1, y, c)
                return
            }
            let half = scene.half
            let c16 = f16x4(c, half)
            let top = layers[depth - 1]
            let rowStart = Int((y - tile.1) * CpuBootBin.tileW)
            let startIdx = rowStart + Int(x0 - tile.0)
            let endIdx = rowStart + Int(x1 - tile.0)
            if c16.w == 1.0 && !top.additive {
                for idx in startIdx..<endIdx {
                    top.px[idx] = c16
                }
                return
            }
            let k: Float = top.additive ? 1.0 : (1.0 - c16.w)
            for idx in startIdx..<endIdx {
                top.px[idx] = f16x4(c16 + top.px[idx] * k, half)
            }
        }

        mutating func draw(_ n: UInt32, _ r: (UInt32, UInt32, UInt32, UInt32)) {
            let i = scene.instances[Int(n)]
            currentN = n
            if i.params.y == KIND_LAYER {
                openLayer(n)
                return
            }
            if i.params.y == KIND_LAYER_END {
                closeLayer(r)
                return
            }
            let clip = CpuBootShade.Clip.of(i)
            let kind = UInt32(i.params.y)
            switch kind {
            case 2:
                drawGlyph(i, r, clip)
            case 7:
                drawImage(i, r, clip)
            case 0, 4:
                drawShaded(i, kind: kind, r: r, clip: clip, solid: CpuBootBin.interior(i))
            case 1:
                drawShadow(i, r: r, clip: clip)
            case 11:
                let solid = CpuBootBin.Solid(
                    edges: SIMD4<Float>(i.rect.x, i.rect.y, i.rect.x + i.rect.z, i.rect.y + i.rect.w),
                    radii: i.radii,
                    inset: max(i.params.z, 0.5)
                )
                drawShaded(i, kind: 11, r: r, clip: clip, solid: solid)
            case 3, 5, 6, 10:
                drawShaded(i, kind: kind, r: r, clip: clip, solid: nil)
            case 13:
                drawBackdrop(i, r: r, clip: clip)
            default:
                break
            }
        }

        mutating func openLayer(_ n: UInt32) {
            guard let plan = bins.scope[n] else { return }
            let l = bins.layers[Int(plan)]
            if l.show != .render { return }
            if layers.count == depth {
                layers.append(Scratch())
            }
            let s = layers[depth]
            for idx in 0..<s.px.count { s.px[idx] = .zero }
            s.additive = l.additive
            s.plan = Int(plan)
            depth += 1
        }

        mutating func closeLayer(_ r: (UInt32, UInt32, UInt32, UInt32)) {
            if depth == 0 { return }
            depth -= 1
            let topLayer = layers[depth]
            let l = bins.layers[topLayer.plan]
            let begin = scene.instances[Int(l.begin)]
            let clip = CpuBootShade.Clip.of(begin)
            let opacity = begin.fill.w
            computeSegments(r, solid: nil, clip: clip)
            var k = 0
            for y in r.1..<r.3 {
                let py = Float(y) + 0.5
                while segs[k].y1 <= y { k += 1 }
                let seg = segs[k]
                let whole = seg.whole
                let (fa, fb) = (!l.additive && l.hole.w <= 0.0) ? centres(whole, r.0, r.2) : (r.2, r.2)
                for runIdx in 0..<seg.vis.len {
                    let (va, vb) = seg.vis.runs[runIdx]
                    let a = max(fa, va)
                    let b = min(fb, vb)
                    if b <= a { continue }
                    let at = slot(a, y)
                    let count = Int(b - a)
                    if depth == 0 {
                        let dstOffset = surface.at(a, y)
                        topLayer.px.withUnsafeBufferPointer { buf in
                            if let basePtr = buf.baseAddress {
                                CpuBootBlend.compositeRowBy(
                                    surface.base,
                                    offset: dstOffset,
                                    src: basePtr.advanced(by: at),
                                    count: count,
                                    opacity: opacity
                                )
                            }
                        }
                        continue
                    }
                    let parent = layers[depth - 1]
                    for idx in 0..<count {
                        let s = topLayer.px[at + idx]
                        if s == .zero { continue }
                        let c = opacity == 1.0 ? s : (s * opacity)
                        if c.w == 1.0 && !parent.additive && opacity == 1.0 {
                            parent.px[at + idx] = c
                            continue
                        }
                        if c == .zero { continue }
                        let c16 = f16x4(c, scene.half)
                        let factor: Float = parent.additive ? 1.0 : (1.0 - c16.w)
                        parent.px[at + idx] = f16x4(c16 + parent.px[at + idx] * factor, scene.half)
                    }
                }
                for runIdx in 0..<seg.vis.len {
                    let (va, vb) = seg.vis.runs[runIdx]
                    for x in va..<vb where x < fa || x >= fb {
                        var s = topLayer.px[slot(x, y)]
                        if s == .zero { continue }
                        let px = Float(x) + 0.5
                        if l.additive {
                            s = SIMD4<Float>(
                                min(max(s.x, 0.0), 1.0),
                                min(max(s.y, 0.0), 1.0),
                                min(max(s.z, 0.0), 1.0),
                                min(max(s.w, 0.0), 1.0)
                            )
                        }
                        let a = (px >= whole.0 && px <= whole.1) ? 1.0 : clip.alpha(SIMD2<Float>(px, py))
                        let h = holeAlpha(SIMD2<Float>(px, py), l.hole)
                        if depth == 0 && s.w == 1.0 && opacity == 1.0 && a == 1.0 && h == 1.0 {
                            surface.writeOpaque(x, y, s)
                            continue
                        }
                        let c = s * (opacity * a * h)
                        if c != .zero { put(x, y, c) }
                    }
                }
            }
        }

        mutating func drawShaded(
            _ i: RenderInstance,
            kind: UInt32,
            r: (UInt32, UInt32, UInt32, UInt32),
            clip: CpuBootShade.Clip,
            solid: CpuBootBin.Solid?
        ) {
            let gradientRow = kind == 4 && i.params.x <= 0.0
            computeSegments(r, solid: solid, clip: clip)
            var k = 0
            for y in r.1..<r.3 {
                let py = Float(y) + 0.5
                while segs[k].y1 <= y { k += 1 }
                let seg = segs[k]
                let whole = seg.whole
                let (ia, ib) = seg.solid
                let c: SIMD4<Float>
                if gradientRow {
                    let t = min(max((py - i.rect.y) / max(i.rect.w, 1.0), 0.0), 1.0)
                    c = CpuBootShade.mix4(i.fill, i.uv, t)
                } else {
                    c = i.fill
                }
                if kind == 11 && CpuBootShade.linearRowOutside(i, py: py, x0: Float(r.0) + 0.5, x1: Float(r.2) - 0.5) {
                    continue
                }
                for runIdx in 0..<seg.vis.len {
                    let (va, vb) = seg.vis.runs[runIdx]
                    let leftEnd = min(max(ia, va), vb)
                    for x in va..<leftEnd {
                        shadePixel(i, kind: kind, clip: clip, whole: whole, x: x, y: y)
                    }
                    if kind == 11 {
                        let midStart = max(ia, va)
                        let midEnd = min(ib, vb)
                        if midStart < midEnd {
                            for x in midStart..<midEnd {
                                let rc = CpuBootShade.radial(i, p: SIMD2<Float>(Float(x) + 0.5, py), inside: true)
                                if rc != .zero { put(x, y, rc) }
                            }
                        }
                    } else {
                        putSpan(max(ia, va), min(ib, vb), y, c)
                    }
                    let rightStart = min(max(ib, va), vb)
                    for x in rightStart..<vb {
                        shadePixel(i, kind: kind, clip: clip, whole: whole, x: x, y: y)
                    }
                }
            }
        }

        mutating func drawShadow(_ i: RenderInstance, r: (UInt32, UInt32, UInt32, UInt32), clip: CpuBootShade.Clip) {
            var key: UInt64? = nil
            var sums = [Float](repeating: .nan, count: Int(CpuBootBin.tileW))
            let cx = i.rect.x + i.rect.z * 0.5
            computeSegments(r, solid: nil, clip: clip)
            var k = 0
            for y in r.1..<r.3 {
                let py = Float(y) + 0.5
                while segs[k].y1 <= y { k += 1 }
                let seg = segs[k]
                let whole = seg.whole
                let row = CpuBootShade.shadowRow(i, y: y, py: py)
                let rk = row.key()
                if key != rk {
                    key = rk
                    for idx in 0..<sums.count { sums[idx] = .nan }
                }
                let fa: UInt32
                let fb: UInt32
                let flat: SIMD4<Float>
                if i.uv.z <= 0.0, let (reach, cov) = row.flat() {
                    let (a, b) = centres(CpuBootBin.intersect((cx - reach, cx + reach), whole), r.0, r.2)
                    fa = a + 1
                    fb = max(b > 0 ? b - 1 : 0, a + 1)
                    flat = i.fill * cov
                } else {
                    fa = r.2
                    fb = r.2
                    flat = .zero
                }
                if fb > fa {
                    for runIdx in 0..<seg.vis.len {
                        let (va, vb) = seg.vis.runs[runIdx]
                        putSpan(max(fa, va), min(fb, vb), y, flat)
                    }
                }
                for runIdx in 0..<seg.vis.len {
                    let (va, vb) = seg.vis.runs[runIdx]
                    for x in va..<vb where x < fa || x >= fb {
                        let px = Float(x) + 0.5
                        let dx = px - cx
                        let cov: Float
                        if row.inside(dx) {
                            cov = CpuBootShade.shadowInside
                        } else {
                            let sIdx = Int(x - tile.0)
                            if sums[sIdx].isNaN {
                                sums[sIdx] = row.sum(dx)
                            }
                            cov = sums[sIdx]
                        }
                        let c = CpuBootShade.shadowCov(i, row: row, px: px, cov: cov)
                        if c == .zero { continue }
                        let a = (px >= whole.0 && px <= whole.1) ? 1.0 : clip.alpha(SIMD2<Float>(px, py))
                        stats.shadedPx += 1
                        if a > 0.0 { put(x, y, c * a) }
                    }
                }
            }
        }

        @inline(__always)
        mutating func shadePixel(
            _ i: RenderInstance,
            kind: UInt32,
            clip: CpuBootShade.Clip,
            whole: (Float, Float),
            x: UInt32,
            y: UInt32
        ) {
            let p = SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5)
            let c = CpuBootShade.boxes(i, kind: kind, p: p)
            if c == .zero { return }
            let a = (p.x >= whole.0 && p.x <= whole.1) ? 1.0 : clip.alpha(p)
            stats.shadedPx += 1
            if a > 0.0 { put(x, y, c * a) }
        }

        mutating func drawGlyph(_ i: RenderInstance, _ r: (UInt32, UInt32, UInt32, UInt32), _ clip: CpuBootShade.Clip) {
            if i.radii.w > 0.0 {
                drawOutline(i, r, clip)
                return
            }
            let pageIdx = Int(i.params.z)
            guard pageIdx >= 0 && pageIdx < scene.glyphPages.count else { return }
            let mask = scene.glyphPages[pageIdx]
            let size = scene.glyphSize(at: pageIdx)
            let pw = size.x, ph = size.y
            guard pw > 0 && ph > 0, mask.count >= pw * ph else { return }

            @inline(__always)
            func load(_ x: Int, _ y: Int) -> UInt8 {
                if x < 0 || y < 0 || x >= pw || y >= ph { return 0 }
                return mask[y * pw + x]
            }

            let e = i.params.w
            let turn = i.params.x
            let rotated = turn != 0.0
            let filtered = i.uv.z > 0.0 || rotated
            let lcd = i.radii.x > 0.5 && !filtered
            let byChannel = lcd && scene.lcd && depth == 0
            let sVal = sinf(turn)
            let cVal = cosf(turn)
            let centre = SIMD2<Float>(i.rect.x + i.rect.z * 0.5, i.rect.y + i.rect.w * 0.5)
            let span = i.uv.z > 0.0 ? SIMD2<Float>(i.uv.z, i.uv.w) : SIMD2<Float>(i.rect.z, i.rect.w)
            let tableIdx = powCache.index(for: e)
            let powTable = powCache.tables[tableIdx].1
            var count: UInt64 = 0
            computeSegments(r, solid: nil, clip: clip)
            var k = 0
            for y in r.1..<r.3 {
                let py = Float(y) + 0.5
                while segs[k].y1 <= y { k += 1 }
                let seg = segs[k]
                let whole = seg.whole
                let ty = Int(i.uv.y) + Int(floorf(py - i.rect.y))
                if !lcd && !filtered {
                    if ty < 0 || ty >= ph { continue }
                    let rowStart = ty * pw
                    let t0 = Int(i.uv.x) + Int(floorf(Float(r.0) + 0.5 - i.rect.x)) - Int(r.0)
                    for runIdx in 0..<seg.vis.len {
                        let (va, vb) = seg.vis.runs[runIdx]
                        for x in va..<vb {
                            let gx = t0 + Int(x)
                            if gx < 0 || gx >= pw { continue }
                            let v = mask[rowStart + gx]
                            if v == 0 { continue }
                            count += 1
                            let px = Float(x) + 0.5
                            let a = (px >= whole.0 && px <= whole.1) ? 1.0 : clip.alpha(SIMD2<Float>(px, py))
                            let cov = powTable[Int(v)]
                            put(x, y, i.fill * (cov * a))
                        }
                    }
                    continue
                }
                for runIdx in 0..<seg.vis.len {
                    let (va, vb) = seg.vis.runs[runIdx]
                    for x in va..<vb {
                        let px = Float(x) + 0.5
                        @inline(__always)
                        func alpha() -> Float {
                            (px >= whole.0 && px <= whole.1) ? 1.0 : clip.alpha(SIMD2<Float>(px, py))
                        }
                        if lcd {
                            let tx = Int(i.uv.x) + Int(floorf(px - i.rect.x)) * 3
                            let c0 = load(tx, ty)
                            let c1 = load(tx + 1, ty)
                            let c2 = load(tx + 2, ty)
                            if c0 == 0 && c1 == 0 && c2 == 0 { continue }
                            count += 1
                            let a = alpha()
                            let mean = powf((Float(c0) + Float(c1) + Float(c2)) / 3.0 / 255.0, e)
                            if byChannel {
                                if mean < 1.0e-5 { continue }
                                let k0 = powTable[Int(c0)]
                                let k1 = powTable[Int(c1)]
                                let k2 = powTable[Int(c2)]
                                let f = i.fill * a
                                surface.blendLCD(
                                    x,
                                    y,
                                    SIMD4<Float>(f.x * k0, f.y * k1, f.z * k2, f.w * mean),
                                    SIMD3<Float>(f.w * k0, f.w * k1, f.w * k2)
                                )
                            } else {
                                put(x, y, i.fill * (mean * a))
                            }
                            continue
                        }
                        let cov: Float
                        if filtered {
                            let p: SIMD2<Float>
                            if rotated {
                                let d = SIMD2<Float>(px - centre.x, py - centre.y)
                                p = SIMD2<Float>(centre.x + cVal * d.x + sVal * d.y, centre.y - sVal * d.x + cVal * d.y)
                                if p.x < i.rect.x || p.y < i.rect.y || p.x >= i.rect.x + i.rect.z || p.y >= i.rect.y + i.rect.w {
                                    continue
                                }
                            } else {
                                p = SIMD2<Float>(px, py)
                            }
                            let lx = (p.x - i.rect.x) * span.x / i.rect.z - 0.5
                            let ly = (p.y - i.rect.y) * span.y / i.rect.w - 0.5
                            let bx = floorf(lx)
                            let by = floorf(ly)
                            let fx = lx - bx
                            let fy = ly - by
                            let tx = Int(i.uv.x + bx)
                            let ty2 = Int(i.uv.y + by)
                            let s00 = Float(load(tx, ty2)) / 255.0
                            let s10 = Float(load(tx + 1, ty2)) / 255.0
                            let s01 = Float(load(tx, ty2 + 1)) / 255.0
                            let s11 = Float(load(tx + 1, ty2 + 1)) / 255.0
                            let c0 = s00 * (1.0 - fx) + s10 * fx
                            let c1 = s01 * (1.0 - fx) + s11 * fx
                            let cValPix = c0 * (1.0 - fy) + c1 * fy
                            if cValPix <= 0.0 { continue }
                            cov = (e == 1.0) ? cValPix : powf(cValPix, e)
                        } else {
                            let v = load(Int(i.uv.x) + Int(floorf(px - i.rect.x)), ty)
                            if v == 0 { continue }
                            cov = powTable[Int(v)]
                        }
                        count += 1
                        let a = alpha()
                        put(x, y, i.fill * (cov * a))
                    }
                }
            }
            stats.glyphPx += count
        }

        /// Direct Windfoil glyphs keep their outlines while a text run changes scale.
        mutating func drawOutline(_ i: RenderInstance, _ r: (UInt32, UInt32, UInt32, UInt32), _ clip: CpuBootShade.Clip) {
            guard let store = scene.outlines,
                  let record = UInt32(exactly: i.border.x), let hint = UInt32(exactly: i.border.y) else { return }
            let zoom = i.radii.w
            let halfWidth = 0.5 / zoom
            let across: Float = i.border.w == 3 ? 3 : 1
            let rgb = i.border.w == 2 && scene.lcd && depth == 0
            let exponent = i.params.w
            func coverage(_ local: SIMD2<Float>) -> Float {
                OutlineCover.coverage(store: store, record: record, hint: hint, local: local,
                                      scale: i.radii.z, radius: i.border.z, halfWidth: halfWidth)
            }
            computeSegments(r, solid: nil, clip: clip)
            var segmentIndex = 0
            for y in r.1..<r.3 {
                let py = Float(y) + 0.5
                while segs[segmentIndex].y1 <= y { segmentIndex += 1 }
                let segment = segs[segmentIndex]
                for run in 0..<segment.vis.len {
                    let (start, end) = segment.vis.runs[run]
                    for x in start..<end {
                        let px = Float(x) + 0.5
                        let local = SIMD2((px - i.radii.x) / across / zoom, (i.radii.y - py) / zoom)
                        let alpha = px >= segment.whole.0 && px <= segment.whole.1 ? 1 : clip.alpha(SIMD2(px, py))
                        if rgb {
                            let third = SIMD2(2 * halfWidth / 3, Float.zero)
                            let red = coverage(local - third), green = coverage(local), blue = coverage(local + third)
                            let mean = powf((red + green + blue) / 3, exponent)
                            guard mean >= 1.0e-5 else { continue }
                            let weights = SIMD3(powf(red, exponent), powf(green, exponent), powf(blue, exponent))
                            let fill = i.fill * alpha
                            surface.blendLCD(x, y, fill * SIMD4(weights, mean), weights * fill.w)
                        } else {
                            let value = coverage(local)
                            guard value > 0 else { continue }
                            stats.glyphPx += 1
                            put(x, y, i.fill * powf(value, exponent) * alpha)
                        }
                    }
                }
            }
        }

        mutating func drawBackdrop(_ i: RenderInstance, r: (UInt32, UInt32, UInt32, UInt32), clip: CpuBootShade.Clip) {
            guard let at = bins.blurs.firstIndex(where: { $0.0 == currentN }),
                  let b = blurred[at] else {
                return
            }
            for y in r.1..<r.3 {
                for x in r.0..<r.2 {
                    let c = CpuBootBackdrop.composite(b, inst: i, clip: clip, p: SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5))
                    if c != .zero { put(x, y, c) }
                }
            }
        }

        mutating func drawImage(_ i: RenderInstance, _ r: (UInt32, UInt32, UInt32, UInt32), _ clip: CpuBootShade.Clip) {
            let pageIdx = Int(i.params.x)
            guard pageIdx >= 0 && pageIdx < scene.images.count else { return }
            let page = scene.images[pageIdx]
            computeSegments(r, solid: nil, clip: clip)
            var k = 0
            for y in r.1..<r.3 {
                let py = Float(y) + 0.5
                while segs[k].y1 <= y { k += 1 }
                let seg = segs[k]
                let whole = seg.whole
                for runIdx in 0..<seg.vis.len {
                    let (va, vb) = seg.vis.runs[runIdx]
                    for x in va..<vb {
                        let p = SIMD2<Float>(Float(x) + 0.5, py)
                        let c = CpuBootShade.image(i, page: page, p: p)
                        if c == .zero { continue }
                        let a = (p.x >= whole.0 && p.x <= whole.1) ? 1.0 : clip.alpha(p)
                        stats.shadedPx += 1
                        put(x, y, c * a)
                    }
                }
            }
        }
    }

    public static func run(
        scene: CpuBootScene,
        bins: CpuBootBin.Bins,
        target: inout CpuBootTarget,
        tiles: [UInt32],
        exec: any CpuBootExec,
        wide: any CpuBootExec
    ) -> CpuBootReport {
        var report = CpuBootReport()
        report.threads = exec.threads
        if tiles.isEmpty { return report }

        let clearScaled = SIMD4<Float>(
            min(max(scene.clear.x, 0.0), 1.0) * 255.0,
            min(max(scene.clear.y, 0.0), 1.0) * 255.0,
            min(max(scene.clear.z, 0.0), 1.0) * 255.0,
            min(max(scene.clear.w, 0.0), 1.0) * 255.0
        )
        let clearBGRA: (UInt8, UInt8, UInt8, UInt8) = (
            CpuBootBlend.quantize(clearScaled.z),
            CpuBootBlend.quantize(clearScaled.y),
            CpuBootBlend.quantize(clearScaled.x),
            CpuBootBlend.quantize(clearScaled.w)
        )

        var blurred: [CpuBootBackdrop.Blurred?] = []
        blurred.reserveCapacity(bins.blurs.count)
        var cuts: [UInt32] = bins.blurs.map { $0.0 }
        cuts.append(UInt32.max)

        final class PhaseAccumulator: @unchecked Sendable {
            let lock = NSLock()
            var nextIndex: Int = 0
            var aggregate = CpuBootReport()
        }

        let targetStride = target.stride
        let targetLen = target.pixels.count
        var from: UInt32 = 0

        for (phase, until) in cuts.enumerated() {
            let phaseFrom = from
            let doneBlurred = blurred
            let acc = PhaseAccumulator()
            target.pixels.withUnsafeMutableBufferPointer { pxBuf in
                let rawPtr = pxBuf.baseAddress!
                let surface = Surface(base: rawPtr, len: targetLen, stride: targetStride)
                let chunk = tiles.count > 512 ? 16 : 1
                exec.run {
                    var painter = TilePainter(scene: scene, bins: bins, surface: surface, blurred: doneBlurred)
                    while true {
                        acc.lock.lock()
                        let at = acc.nextIndex
                        acc.nextIndex += chunk
                        acc.lock.unlock()
                        if at >= tiles.count { break }
                        let endAt = min(at + chunk, tiles.count)
                        for tileIdx in at..<endAt {
                            let t = Int(tiles[tileIdx])
                            let began = RuneExecutionContext.uptimeNanoseconds
                            painter.tile = painter.tileRect(tx: UInt32(t) % bins.cols, ty: UInt32(t) / bins.cols)
                            if phase == 0 && !bins.covered[t] {
                                painter.surface.fill(painter.tile, clearBGRA)
                                painter.stats.cleared += 1
                            }
                            let list = bins.tile(t)
                            let startPos = list.firstIndex(where: { $0 >= phaseFrom }) ?? list.endIndex
                            let endPos = list.firstIndex(where: { $0 >= until }) ?? list.endIndex
                            let sub = list[startPos..<endPos]
                            painter.collectOccluders(sub)
                            for n in sub {
                                let b = bins.bounds[Int(n)]
                                let rx0 = max(UInt32(max(0, b.x)), painter.tile.0)
                                let ry0 = max(UInt32(max(0, b.y)), painter.tile.1)
                                let rx1 = min(UInt32(max(0, b.z)), painter.tile.2)
                                let ry1 = min(UInt32(max(0, b.w)), painter.tile.3)
                                if rx1 > rx0 && ry1 > ry0 {
                                    painter.draw(n, (rx0, ry0, rx1, ry1))
                                }
                            }
                            painter.depth = 0
                            let elapsed = RuneExecutionContext.uptimeNanoseconds &- began
                            painter.stats.slowestTileNs = max(painter.stats.slowestTileNs, elapsed)
                        }
                    }
                    acc.lock.lock()
                    acc.aggregate.spanPx += painter.stats.spanPx
                    acc.aggregate.shadedPx += painter.stats.shadedPx
                    acc.aggregate.glyphPx += painter.stats.glyphPx
                    acc.aggregate.cleared += painter.stats.cleared
                    acc.aggregate.slowestTileNs = max(acc.aggregate.slowestTileNs, painter.stats.slowestTileNs)
                    acc.lock.unlock()
                }
            }

            report.spanPx += acc.aggregate.spanPx
            report.shadedPx += acc.aggregate.shadedPx
            report.glyphPx += acc.aggregate.glyphPx
            report.cleared += acc.aggregate.cleared
            report.slowestTileNs = max(report.slowestTileNs, acc.aggregate.slowestTileNs)

            if phase < bins.blurs.count {
                let (n, rec) = bins.blurs[phase]
                let b = bins.bounds[Int(n)]
                let shown = tiles.contains { t in
                    let tx = t % bins.cols
                    let ty = t / bins.cols
                    return Int32(tx * CpuBootBin.tileW) < b.z
                        && Int32((tx + 1) * CpuBootBin.tileW) > b.x
                        && Int32(ty * CpuBootBin.tileH) < b.w
                        && Int32((ty + 1) * CpuBootBin.tileH) > b.y
                }
                let began = RuneExecutionContext.uptimeNanoseconds
                if shown {
                    let snapshot = target.pixels
                    let blurredResult = CpuBootBackdrop.blur(
                        record: rec,
                        viewport: (UInt32(scene.size.0), UInt32(scene.size.1)),
                        half: scene.half,
                        exec: wide
                    ) { x, y in
                        let at = Int(y) * targetStride + Int(x) * 4
                        return SIMD4<Float>(
                            Float(snapshot[at + 2]) / 255.0,
                            Float(snapshot[at + 1]) / 255.0,
                            Float(snapshot[at]) / 255.0,
                            Float(snapshot[at + 3]) / 255.0
                        )
                    }
                    blurred.append(blurredResult)
                } else {
                    blurred.append(nil)
                }
                report.blurNs += RuneExecutionContext.uptimeNanoseconds &- began
            }
            from = until
        }

        return report
    }
}
