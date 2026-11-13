import Foundation
#if canImport(simd)
import simd
#endif

/// `KIND_BACKDROP_BLUR` on the CPU (`cpu_boot/backdrop.rs`): dual-filter Kawase pyramid + rounded-rect composite.
public enum CpuBootBackdrop {
    public static let mips: Int = 7
    public static let step: UInt32 = 1 << (mips - 1)
    public static let sigmas: [Float] = [1.58, 4.53, 9.62, 19.51, 39.15, 78.36, 156.2]

    public struct Record: Sendable {
        public let n: Int
        public let share: Float
        public let region: SIMD4<Float>
        public let origin: SIMD2<Float>
        public let size: (UInt32, UInt32)
    }

    public final class Blurred: @unchecked Sendable {
        let up: Level
        let place: SIMD4<Float>

        init(up: Level, place: SIMD4<Float>) {
            self.up = up
            self.place = place
        }
    }

    final class Level: @unchecked Sendable {
        let w: UInt32
        let h: UInt32
        var px: [SIMD4<Float>]

        init(w: UInt32, h: UInt32) {
            self.w = w
            self.h = h
            self.px = [SIMD4<Float>](repeating: .zero, count: Int(w * h))
        }

        func sample(_ uv: SIMD2<Float>) -> SIMD4<Float> {
            bilinear(uv, w: w, h: h) { x, y in
                px[Int(y * w + x)]
            }
        }
    }

    private struct Axis: Sendable {
        let i0: UInt32
        let i1: UInt32
        let f: Float
    }

    private static func levels(_ sigma: Float, top: Int) -> (Int, Float) {
        let clampedTop = max(1, min(top, sigmas.count - 1))
        let clampedSigma = min(max(sigma, sigmas[0]), sigmas[clampedTop])
        var n = clampedTop
        for candidate in 1...clampedTop where clampedSigma <= sigmas[candidate] {
            n = candidate
            break
        }
        let a = sigmas[n - 1]
        let b = sigmas[n]
        let share = min(max((clampedSigma * clampedSigma - a * a) / (b * b - a * a), 0.0), 1.0)
        return (n, share)
    }

    public static func plan(_ inst: RenderInstance, viewport: (UInt32, UInt32)) -> Record? {
        let sigma = inst.params.x
        let (n, share) = levels(sigma, top: mips - 1)
        let reach = min(sigma, sigmas[n]) * 3.0 + 2.0
        let vw = Float(viewport.0)
        let vh = Float(viewport.1)
        let region = SIMD4<Float>(
            max(inst.rect.x - reach, 0.0),
            max(inst.rect.y - reach, 0.0),
            min(inst.rect.x + inst.rect.z + reach, vw),
            min(inst.rect.y + inst.rect.w + reach, vh)
        )
        if region.z <= region.x || region.w <= region.y { return nil }
        let align = Float(UInt32(2) << UInt32(n))
        let origin = SIMD2<Float>(floorf(region.x / align) * align, floorf(region.y / align) * align)
        func alignedHalf(_ extent: Float) -> UInt32 {
            let raw = UInt32(max(0, Int32(ceilf(extent / 2.0))))
            let rem = raw % step
            let rounded = rem == 0 ? raw : raw + (step - rem)
            return max(rounded, step)
        }
        let size = (alignedHalf(region.z - origin.x), alignedHalf(region.w - origin.y))
        return Record(n: n, share: share, region: region, origin: origin, size: size)
    }

    public static func bounds(_ inst: RenderInstance, viewport: (UInt32, UInt32)) -> SIMD4<Int32> {
        let r = inst.rect
        let c = inst.clip
        let vw = Float(viewport.0)
        let vh = Float(viewport.1)
        let x0 = min(max(floorf(max(r.x, c.x)), 0.0), vw)
        let y0 = min(max(floorf(max(r.y, c.y)), 0.0), vh)
        let x1 = min(max(ceilf(min(r.x + r.z, c.z)), 0.0), vw)
        let y1 = min(max(ceilf(min(r.y + r.w, c.w)), 0.0), vh)
        if x1 <= x0 || y1 <= y0 { return .zero }
        return SIMD4<Int32>(Int32(x0), Int32(y0), Int32(x1), Int32(y1))
    }

    @inline(__always)
    private static func makeAxis(_ u: Float, _ n: UInt32) -> Axis {
        let x = u * Float(n) - 0.5
        let x0 = floorf(x)
        let maxIdx = Int32(n) - 1
        let i0 = UInt32(min(max(Int32(x0), 0), maxIdx))
        let i1 = UInt32(min(max(Int32(x0 + 1.0), 0), maxIdx))
        return Axis(i0: i0, i1: i1, f: x - x0)
    }

    @inline(__always)
    private static func mix4(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
        a * (1.0 - t) + b * t
    }

    @inline(__always)
    private static func tap(_ x: Axis, _ y: Axis, _ texel: (UInt32, UInt32) -> SIMD4<Float>) -> SIMD4<Float> {
        let top = mix4(texel(x.i0, y.i0), texel(x.i1, y.i0), x.f)
        let bot = mix4(texel(x.i0, y.i1), texel(x.i1, y.i1), x.f)
        return mix4(top, bot, y.f)
    }

    @inline(__always)
    private static func bilinear(_ uv: SIMD2<Float>, w: UInt32, h: UInt32, _ texel: (UInt32, UInt32) -> SIMD4<Float>) -> SIMD4<Float> {
        let x = uv.x * Float(w) - 0.5
        let y = uv.y * Float(h) - 0.5
        let fx0 = floorf(x)
        let fy0 = floorf(y)
        let fx = x - fx0
        let fy = y - fy0
        let maxX = Int32(w) - 1
        let maxY = Int32(h) - 1
        let x0 = UInt32(min(max(Int32(fx0), 0), maxX))
        let x1 = UInt32(min(max(Int32(fx0 + 1.0), 0), maxX))
        let y0 = UInt32(min(max(Int32(fy0), 0), maxY))
        let y1 = UInt32(min(max(Int32(fy0 + 1.0), 0), maxY))
        return mix4(
            mix4(texel(x0, y0), texel(x1, y0), fx),
            mix4(texel(x0, y1), texel(x1, y1), fx),
            fy
        )
    }

    @inline(__always)
    private static func down13(_ s: (Float, Float) -> SIMD4<Float>) -> SIMD4<Float> {
        let a = s(-2.0, -2.0)
        let b = s(0.0, -2.0)
        let c = s(2.0, -2.0)
        let d = s(-1.0, -1.0)
        let e = s(1.0, -1.0)
        let f = s(-2.0, 0.0)
        let g = s(0.0, 0.0)
        let h = s(2.0, 0.0)
        let i = s(-1.0, 1.0)
        let j = s(1.0, 1.0)
        let k = s(-2.0, 2.0)
        let l = s(0.0, 2.0)
        let m = s(2.0, 2.0)
        return (d + e + i + j) * 0.125
            + (a + b + g + f) * 0.03125
            + (b + c + h + g) * 0.03125
            + (f + g + l + k) * 0.03125
            + (g + h + m + l) * 0.03125
    }

    private static func runRows(
        exec: any CpuBootExec,
        out: Level,
        y0: UInt32,
        y1: UInt32,
        row: @Sendable (UInt32, UnsafeMutableBufferPointer<SIMD4<Float>>) -> Void
    ) {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var next: UInt32
            let limit: UInt32
            init(start: UInt32, limit: UInt32) {
                self.next = start
                self.limit = limit
            }
            func take() -> UInt32? {
                lock.lock()
                defer { lock.unlock() }
                if next >= limit { return nil }
                let y = next
                next += 1
                return y
            }
        }
        let counter = Counter(start: y0, limit: y1)
        let width = Int(out.w)
        out.px.withUnsafeMutableBufferPointer { buf in
            let rawBase = UInt(bitPattern: buf.baseAddress)
            let count = buf.count
            exec.run {
                let ptr = UnsafeMutablePointer<SIMD4<Float>>(bitPattern: rawBase)
                while let y = counter.take() {
                    guard let ptr else { break }
                    let rowStart = Int(y) * width
                    precondition(rowStart + width <= count)
                    let slice = UnsafeMutableBufferPointer(start: ptr.advanced(by: rowStart), count: width)
                    row(y, slice)
                }
            }
        }
    }

    public static func blur(
        record rec: Record,
        viewport: (UInt32, UInt32),
        half: HalfRounding,
        exec: any CpuBootExec,
        window: @escaping @Sendable (UInt32, UInt32) -> SIMD4<Float>
    ) -> Blurred {
        let pw = rec.size.0
        let ph = rec.size.1
        let extent = SIMD2<Float>(Float(pw) * 2.0, Float(ph) * 2.0)
        let vw = Float(viewport.0)
        let vh = Float(viewport.1)
        let inside = SIMD4<Float>(
            (rec.region.x - rec.origin.x) / extent.x,
            (rec.region.y - rec.origin.y) / extent.y,
            (rec.region.z - rec.origin.x) / extent.x,
            (rec.region.w - rec.origin.y) / extent.y
        )
        func dims(_ m: Int) -> (UInt32, UInt32) {
            (max(pw >> UInt32(m), 1), max(ph >> UInt32(m), 1))
        }
        func scissor(_ m: Int) -> (UInt32, UInt32, UInt32, UInt32) {
            let k = Float(UInt32(2) << UInt32(m))
            let (w, h) = dims(m)
            let sx = min(UInt32(max(0, Int32(floorf((rec.region.x - rec.origin.x) / k)) - 2)), w - 1)
            let sy = min(UInt32(max(0, Int32(floorf((rec.region.y - rec.origin.y) / k)) - 2)), h - 1)
            let sr = min(UInt32(max(0, Int32(ceilf((rec.region.z - rec.origin.x) / k)) + 2)), w)
            let sb = min(UInt32(max(0, Int32(ceilf((rec.region.w - rec.origin.y) / k)) + 2)), h)
            return (sx, sy, max(sr, sx + 1), max(sb, sy + 1))
        }

        let windowRegion = SIMD4<Float>(rec.region.x / vw, rec.region.y / vh, rec.region.z / vw, rec.region.w / vh)
        let windowMap = SIMD4<Float>(extent.x / vw, extent.y / vh, rec.origin.x / vw, rec.origin.y / vh)

        let cx0 = UInt32(max(0, Int32(floorf(rec.region.x)) - 1))
        let cy0 = UInt32(max(0, Int32(floorf(rec.region.y)) - 1))
        let cx1 = min(UInt32(max(0, Int32(ceilf(rec.region.z)) + 1)), viewport.0)
        let cy1 = min(UInt32(max(0, Int32(ceilf(rec.region.w)) + 1)), viewport.1)
        let cw = cx1 - cx0
        var cache: [SIMD4<Float>] = []
        cache.reserveCapacity(Int((cy1 - cy0) * cw))
        for y in cy0..<cy1 {
            for x in cx0..<cx1 {
                cache.append(window(x, y))
            }
        }
        let cachedPixels = cache
        let cachedWindow: @Sendable (UInt32, UInt32) -> SIMD4<Float> = { x, y in
            if x >= cx0 && x < cx1 && y >= cy0 && y < cy1 {
                return cachedPixels[Int((y - cy0) * cw + (x - cx0))]
            }
            return window(x, y)
        }

        let offsets: [Float] = [-2.0, -1.0, 0.0, 1.0, 2.0]
        var down: [Level] = []
        down.reserveCapacity(rec.n + 1)

        for m in 0...rec.n {
            let (w, h) = dims(m)
            let out = Level(w: w, h: h)
            let (sx0, sy0, sx1, sy1) = scissor(m)
            if m == 0 {
                let txStep = 1.0 / vw
                let tyStep = 1.0 / vh
                let xs: [[Axis]] = (sx0..<sx1).map { tx in
                    let u = (Float(tx) + 0.5) / Float(w)
                    return offsets.map { o in
                        let cu = min(max(u * windowMap.x + windowMap.z + txStep * o, windowRegion.x), windowRegion.z)
                        return makeAxis(cu, viewport.0)
                    }
                }
                let ys: [[Axis]] = (sy0..<sy1).map { ty in
                    let u = (Float(ty) + 0.5) / Float(h)
                    return offsets.map { o in
                        let cv = min(max(u * windowMap.y + windowMap.w + tyStep * o, windowRegion.y), windowRegion.w)
                        return makeAxis(cv, viewport.1)
                    }
                }
                runRows(exec: exec, out: out, y0: sy0, y1: sy1) { ty, row in
                    let ay = ys[Int(ty - sy0)]
                    for (idx, tx) in (sx0..<sx1).enumerated() {
                        let ax = xs[idx]
                        let v = down13 { ox, oy in
                            tap(ax[Int(ox + 2.0)], ay[Int(oy + 2.0)], cachedWindow)
                        }
                        row[Int(tx)] = CpuBootRaster.f16x4(v, half)
                    }
                }
            } else {
                let src = down[m - 1]
                let txStep = 1.0 / Float(src.w)
                let tyStep = 1.0 / Float(src.h)
                let xs: [[Axis]] = (sx0..<sx1).map { tx in
                    let u = (Float(tx) + 0.5) / Float(w)
                    return offsets.map { o in
                        makeAxis(min(max(u + txStep * o, inside.x), inside.z), src.w)
                    }
                }
                let ys: [[Axis]] = (sy0..<sy1).map { ty in
                    let u = (Float(ty) + 0.5) / Float(h)
                    return offsets.map { o in
                        makeAxis(min(max(u + tyStep * o, inside.y), inside.w), src.h)
                    }
                }
                runRows(exec: exec, out: out, y0: sy0, y1: sy1) { ty, row in
                    let ay = ys[Int(ty - sy0)]
                    let texel: (UInt32, UInt32) -> SIMD4<Float> = { x, y in src.px[Int(y * src.w + x)] }
                    for (idx, tx) in (sx0..<sx1).enumerated() {
                        let ax = xs[idx]
                        let v = down13 { ox, oy in
                            tap(ax[Int(ox + 2.0)], ay[Int(oy + 2.0)], texel)
                        }
                        row[Int(tx)] = CpuBootRaster.f16x4(v, half)
                    }
                }
            }
            down.append(out)
        }

        var coarse: Level? = nil
        for m in (0..<rec.n).reversed() {
            let (w, h) = dims(m)
            let out = Level(w: w, h: h)
            let src = coarse ?? down[rec.n]
            let fine = down[m]
            let weight: Float = (m + 1 == rec.n) ? rec.share : 1.0
            let txStep = 1.0 / Float(src.w)
            let tyStep = 1.0 / Float(src.h)
            let (sx0, sy0, sx1, sy1) = scissor(m)

            let xs: [([Axis], Axis)] = (sx0..<sx1).map { tx in
                let u = (Float(tx) + 0.5) / Float(w)
                let cAxes = [-txStep, 0.0, txStep].map { o in makeAxis(min(max(u + o, inside.x), inside.z), src.w) }
                let fAxis = makeAxis(min(max(u, inside.x), inside.z), fine.w)
                return (cAxes, fAxis)
            }
            let ys: [([Axis], Axis)] = (sy0..<sy1).map { ty in
                let u = (Float(ty) + 0.5) / Float(h)
                let cAxes = [-tyStep, 0.0, tyStep].map { o in makeAxis(min(max(u + o, inside.y), inside.w), src.h) }
                let fAxis = makeAxis(min(max(u, inside.y), inside.w), fine.h)
                return (cAxes, fAxis)
            }

            runRows(exec: exec, out: out, y0: sy0, y1: sy1) { ty, row in
                let ay = ys[Int(ty - sy0)]
                let coarseTexel: (UInt32, UInt32) -> SIMD4<Float> = { x, y in src.px[Int(y * src.w + x)] }
                let fineTexel: (UInt32, UInt32) -> SIMD4<Float> = { x, y in fine.px[Int(y * fine.w + x)] }
                for (idx, tx) in (sx0..<sx1).enumerated() {
                    let ax = xs[idx]
                    @inline(__always)
                    func s(_ dx: Int, _ dy: Int) -> SIMD4<Float> {
                        tap(ax.0[dx], ay.0[dy], coarseTexel)
                    }
                    var c = s(1, 1) * 4.0
                    c = c + (((s(2, 1) + s(0, 1)) + s(1, 2)) + s(1, 0)) * 2.0
                    c = c + (((s(2, 2) + s(0, 0)) + s(2, 0)) + s(0, 2))
                    c = c / 16.0
                    let f = tap(ax.1, ay.1, fineTexel)
                    let mixed = f * (1.0 - weight) + c * weight
                    row[Int(tx)] = CpuBootRaster.f16x4(mixed, half)
                }
            }
            coarse = out
        }

        let finalUp = coarse ?? down[0]
        return Blurred(
            up: finalUp,
            place: SIMD4<Float>(rec.origin.x, rec.origin.y, extent.x, extent.y)
        )
    }

    public static func composite(
        _ blurred: Blurred,
        inst: RenderInstance,
        clip: CpuBootShade.Clip,
        p: SIMD2<Float>
    ) -> SIMD4<Float> {
        let half = SIMD2<Float>(inst.rect.z * 0.5, inst.rect.w * 0.5)
        let d = CpuBootShade.sdRounded(
            SIMD2<Float>(p.x - inst.rect.x - half.x, p.y - inst.rect.y - half.y),
            half: half,
            radii: inst.radii
        )
        let cov = min(max(0.5 - d, 0.0), 1.0) * clip.alpha(p) * inst.fill.w
        let col = blurred.up.sample(SIMD2<Float>(
            (p.x - blurred.place.x) / blurred.place.z,
            (p.y - blurred.place.y) / blurred.place.w
        ))
        return col * cov
    }
}
