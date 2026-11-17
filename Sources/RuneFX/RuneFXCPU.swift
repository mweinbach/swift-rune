import Foundation

public enum RuneFXCPU: Sendable {
    // Swift Float.pi rounds toward zero. The upstream f32 constants round to nearest.
    private static let pi = Float(Double.pi)
    private static let tau = Float(2 * Double.pi)

    public static let emberDrag: Float = 2.4
    public static let sparkleStagger: Float = 0.16
    public static let burstLife: Float = 0.55
    public static let sparkleMaxScale: Float = 1.16 * 1.35
    public static let auroraSamples: Int = 64
    public static let blueN: Int = 32
    private static let forkSamples: Int = 16

    @inlinable
    public static func pcg(_ v: UInt32) -> UInt32 {
        let s = v &* 747796405 &+ 2891336453
        let w = ((s >> ((s >> 28) &+ 4)) ^ s) &* 277803737
        return (w >> 22) ^ w
    }

    @inlinable
    public static func hu(_ a: UInt32, _ b: UInt32) -> UInt32 {
        pcg(a ^ pcg(b &+ 0x9E3779B9))
    }

    @inlinable
    public static func u01(_ n: UInt32) -> Float {
        Float(pcg(n) >> 8) * (1.0 / 16777216.0)
    }

    private static func hcell(_ cx: Int32, _ cy: Int32, _ seed: UInt32) -> Float {
        Float(pcg(UInt32(bitPattern: cx) ^ pcg(UInt32(bitPattern: cy) ^ pcg(seed))) >> 8) * (1.0 / 16777216.0)
    }

    private static func grad(_ cx: Int32, _ cy: Int32, _ seed: UInt32) -> (Float, Float) {
        let a = hcell(cx, cy, seed) * Self.tau
        return (cosf(a), sinf(a))
    }

    private static func fade(_ f: Float) -> Float {
        f * f * f * (f * (f * 6.0 - 15.0) + 10.0)
    }

    private static func remEuclid(_ a: Int32, _ b: Int32) -> Int32 {
        let r = a % b
        return r < 0 ? r + b : r
    }

    private static func remEuclid(_ a: Int, _ b: Int) -> Int {
        let r = a % b
        return r < 0 ? r + b : r
    }

    /// Gradient noise, ~[-1, 1]; `per > 0` makes it periodic in `x`.
    public static func gnoise(_ x: Float, _ y: Float, per: Int32 = 0, seed: UInt32) -> Float {
        let ix = Int32(floorf(x))
        let iy = Int32(floorf(y))
        let fx = x - floorf(x)
        let fy = y - floorf(y)
        let (x0, x1): (Int32, Int32) = per > 0
            ? { let a = remEuclid(ix, per); return (a, (a + 1) % per) }()
            : (ix, ix + 1)
        func dot(_ cx: Int32, _ cy: Int32, _ dx: Float, _ dy: Float) -> Float {
            let g = grad(cx, cy, seed)
            return g.0 * dx + g.1 * dy
        }
        let a = dot(x0, iy, fx, fy)
        let b = dot(x1, iy, fx - 1.0, fy)
        let c = dot(x0, iy + 1, fx, fy - 1.0)
        let d = dot(x1, iy + 1, fx - 1.0, fy - 1.0)
        let ux = fade(fx)
        let uy = fade(fy)
        let ab = a + (b - a) * ux
        let cd = c + (d - c) * ux
        return (ab + (cd - ab) * uy) * 1.41421
    }

    private static func disp(_ x0: Float, _ t0: Float, per0: Int32, seed: UInt32, oct: UInt32) -> Float {
        var x = x0
        var t = t0
        var a: Float = 1.0
        var s: Float = 0.0
        var n: Float = 0.0
        var per = per0
        for o in 0..<oct {
            s += a * gnoise(x, t, per: per, seed: seed &+ o * 101)
            n += a
            if per > 0 {
                x *= 2.0
                per *= 2
            } else {
                x *= 2.07
            }
            t *= 1.55
            a *= 0.5
        }
        return s / n * 1.6
    }

    private static func pushSamples(_ data: inout [SIMD4<Float>], _ v: [Float]) {
        var idx = 0
        while idx < v.count {
            let x = v[idx]
            let y = idx + 1 < v.count ? v[idx + 1] : 0.0
            let z = idx + 2 < v.count ? v[idx + 2] : 0.0
            let w = idx + 3 < v.count ? v[idx + 3] : 0.0
            data.append(SIMD4<Float>(x, y, z, w))
            idx += 4
        }
    }

    private static func blur3(_ v: [Float], radius: Float, wrap: Bool) -> [Float] {
        let n = v.count
        let r = min(max(Int(roundf(radius * 0.58)), 0), max(n / 2 - 1, 0))
        if r == 0 { return v }
        var a = v
        var b = [Float](repeating: 0.0, count: n)
        func at(_ arr: [Float], _ i: Int) -> Float {
            if wrap {
                return arr[remEuclid(i, n)]
            } else {
                return arr[min(max(i, 0), n - 1)]
            }
        }
        for _ in 0..<3 {
            var acc: Float = 0.0
            for k in -r...r { acc += at(a, k) }
            let inv = 1.0 / Float(2 * r + 1)
            for i in 0..<n {
                b[i] = acc * inv
                acc += at(a, i + r + 1) - at(a, i - r)
            }
            swap(&a, &b)
        }
        return a
    }

    private static func rrectTotal(_ rect: FxRect, _ r: Float) -> Float {
        let rr = min(max(r, 0.0), min(rect.w, rect.h) * 0.5)
        let bx = rect.w * 0.5 - rr
        let by = rect.h * 0.5 - rr
        return 4.0 * (by + rr * Self.pi * 0.5 + bx)
    }

    private static func ss(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0.0), 1.0)
        return t * t * (3.0 - 2.0 * t)
    }

    private static func gauss3(_ h: UInt32) -> Float {
        (u01(h) + u01(h &+ 1) + u01(h &+ 2) - 1.5) * 2.0
    }

    private struct Strikes {
        let period: Float
        let seed: UInt32

        init(speed: Float, seed: UInt32) {
            self.period = speed > 0.0 ? min(max(0.55 / speed, 0.05), 4.0) : .infinity
            self.seed = hu(seed, 0x5157)
        }

        func start(_ k: Int32) -> Float {
            if period.isInfinite { return k <= 0 ? 0.0 : .infinity }
            return (Float(k) + 0.35 * u01(hu(seed, UInt32(bitPattern: k)))) * period
        }

        func at(_ t: Float) -> (Int32, Float, Float) {
            if period.isInfinite { return (0, max(t, 0.0), .infinity) }
            var k = Int32(floorf(t / period))
            if t < start(k) { k -= 1 }
            let s = start(k)
            return (k, t - s, start(k + 1) - s)
        }

        func channel(_ k: Int32) -> UInt32 {
            let c = Int32(floorf(Float(k) / 3.0 + 0.5 * u01(hu(seed, 77))))
            return hu(seed ^ 0xC4A2, UInt32(bitPattern: c))
        }

        func strikeSeed(_ k: Int32) -> UInt32 {
            hu(seed ^ 0x3D1F, UInt32(bitPattern: k))
        }
    }

    private static func strikeEnv(age: Float, dur: Float, flicker: Float, h: UInt32) -> Float {
        let flash = 1.0 + 0.65 * expf(-age / 0.022)
        let a1 = dur.isFinite ? dur * (0.3 + 0.4 * u01(h)) : .infinity
        let ret: Float = (u01(h &+ 1) < 0.6 && age > a1) ? 0.7 * flicker * expf(-(age - a1) / 0.03) : 0.0
        let settle = 0.72 + 0.28 * expf(-age / 0.12)
        return flash * settle + ret
    }

    private static func zapEnv(age: Float, flicker: Float, reduced: Bool, h: UInt32) -> Float {
        let out = 1.0 - ss(0.6, 1.0, age / ElectricParams.zapLife)
        if reduced { return expf(-age / 0.15) * out }
        let a1 = 0.07 + 0.06 * u01(h)
        let ret: Float = age > a1 ? (0.5 + 0.5 * flicker) * expf(-(age - a1) / 0.035) : 0.0
        return ((1.0 + 0.65 * expf(-age / 0.022)) * expf(-age / 0.11) + ret) * out
    }

    private static func ghostEnv(_ g: Float) -> Float {
        0.9 * expf(-g / 0.07)
    }

    private static func mpd(
        _ initial: [Float],
        periodic: Bool,
        levels: UInt32,
        amp: (UInt32) -> Float,
        channel: UInt32,
        strike: UInt32,
        memory: UInt32
    ) -> [Float] {
        var pts = initial
        for lv in 0..<levels {
            let m = pts.count
            let seg = periodic ? m : m - 1
            let sd = hu(lv < memory ? channel : strike, lv * 7919 + 1)
            let a = amp(lv)
            var next: [Float] = []
            next.reserveCapacity(seg * 2 + 1)
            for i in 0..<seg {
                let p0 = pts[i]
                let p1 = pts[(i + 1) % m]
                next.append(p0)
                next.append((p0 + p1) * 0.5 + a * gauss3(hu(sd, UInt32(i) * 3)))
            }
            if !periodic { next.append(pts[m - 1]) }
            pts = next
        }
        return pts
    }

    private static func resample(_ ctrl: [Float], count n: Int, periodic: Bool, limit: Float) -> [Float] {
        if limit <= 0.0 { return [Float](repeating: 0.0, count: n) }
        let m = ctrl.count
        var out = [Float](repeating: 0.0, count: n)
        for i in 0..<n {
            let x = periodic ? Float(i) / Float(n) * Float(m) : Float(i) / Float(n - 1) * Float(m - 1)
            let i0 = min(Int(floorf(x)), m - 1)
            let f = x - Float(i0)
            let i1 = periodic ? (i0 + 1) % m : min(i0 + 1, m - 1)
            let d = ctrl[i0] + (ctrl[i1] - ctrl[i0]) * f
            out[i] = limit * tanhf(d / limit)
        }
        return out
    }

    private static func forkWalk(_ hk: UInt32, len: Float) -> [Float] {
        var s = [Float](repeating: 0.0, count: forkSamples)
        var acc: Float = 0.0
        for i in 1..<forkSamples {
            acc = min(max(acc + gauss3(hu(hk, 100 + UInt32(i))) * len * 0.07, -len * 0.3), len * 0.3)
            s[i] = acc
        }
        return s
    }

    private static func forkEnv(age: Float, life: Float) -> (Float, Float, Float) {
        let k = 1.0 - min(age / 0.035, 1.0)
        let grow = 1.0 - k * k * k
        let lifee = ss(0.0, 0.01, age) * expf(-age / (life * 0.4)) * (1.0 - ss(0.75 * life, life, age))
        return (grow, lifee, 1.0 - age / life)
    }

    private static func arcAmp(_ p: ElectricParams, len l: Float) -> Float {
        p.amplitude * sqrtf(l / 100.0)
    }

    private static func arcForkLen(_ l: Float) -> Float {
        min(max(l * 0.16, 12.0), 80.0)
    }

    public static func arcReach(_ p: ElectricParams, len l: Float) -> Float {
        2.0 * arcAmp(p, len: l) + (p.forks > 0.0 ? arcForkLen(l) * 1.1 : 0.0)
    }

    public static func electric(
        _ p: ElectricParams,
        shape: FxShape,
        t: Float,
        seed: UInt32,
        reduced: Bool,
        data: inout [SIMD4<Float>]
    ) -> SIMD4<Float> {
        let first = Float(data.count)
        let freq = p.frequency / 100.0
        let strands = p.zap != nil ? 1 : Int(min(max(p.strands, 1), 3))
        let rate = reduced ? 0.0 : p.forks
        let st = Strikes(speed: (reduced || p.zap != nil) ? 0.0 : p.speed, seed: seed)
        let (k, age, dur) = (reduced && p.zap == nil) ? (Int32(0), Float(1.0), Float.infinity) : st.at(t - (p.zap ?? 0.0))

        func startOf(_ ks: Int32) -> Float {
            if let t0 = p.zap { return ks == 0 ? t0 : .infinity }
            return st.start(ks)
        }

        let still = reduced || st.period.isInfinite
        func noise(_ j: Int) -> Float {
            reduced ? 1.0 : 1.0 - p.flicker * 0.25 * (0.5 + 0.5 * gnoise(t * 14.0, Float(j) * 3.7, seed: seed &+ 17))
        }
        let bright: [Float]
        if p.zap != nil {
            bright = [zapEnv(age: age, flicker: p.flicker, reduced: reduced, h: st.strikeSeed(0)) * noise(0), 0.0, 0.0]
        } else {
            bright = [
                (reduced ? 1.0 : strikeEnv(age: age, dur: dur, flicker: p.flicker, h: st.strikeSeed(k)) * noise(0)),
                still ? 0.0 : ghostEnv(age) * noise(1),
                still ? 0.0 : ghostEnv(age + st.start(k) - st.start(k - 1)) * noise(2),
            ]
        }

        let hdr = data.count
        data.append(.zero)
        data.append(SIMD4<Float>(bright[0], bright[1], bright[2], 0.0))

        func nextMult4(_ x: Int) -> Int { ((x + 3) / 4) * 4 }

        switch p.style {
        case .arc(let a, let b):
            let l = max(hypotf(b.x - a.x, b.y - a.y), 1.0)
            let n = nextMult4(min(max(Int(ceilf(l)), 32), 1024))
            let step = l / Float(n - 1)
            let amp = arcAmp(p, len: l)
            let levels = UInt32(min(max(Int(ceilf(log2f(max(l * freq * 6.0, 8.0)))), 3), 8))
            let paths: [[Float]] = (0..<max(strands, 2)).map { j in
                let ks = k - Int32(j)
                let ctrl = mpd([0.0, 0.0], periodic: false, levels: levels, amp: { lv in amp * 0.65 * powf(2.0, -0.62 * Float(lv)) }, channel: st.channel(ks), strike: st.strikeSeed(ks), memory: 2)
                return resample(ctrl, count: n, periodic: false, limit: amp * 2.0)
            }
            for v in paths[0..<strands] { pushSamples(&data, v) }
            for v in paths[0..<strands] { pushSamples(&data, blur3(v, radius: p.glow * 1.2 / step, wrap: false)) }

            let dir = SIMD2<Float>((b.x - a.x) / l, (b.y - a.y) / l)
            let nrm = SIMD2<Float>(-dir.y, dir.x)
            var forks = 0
            outer: for j in 0..<2 {
                let ks = k - Int32(j)
                let fage = t - startOf(ks)
                for c in 0..<3 as Range<UInt32> {
                    if forks == 4 { break outer }
                    let hk = hu(st.strikeSeed(ks) ^ 0xF04C, c)
                    let life = 0.07 + 0.13 * u01(hk &+ 2)
                    if u01(hk) > rate || fage > life || fage < 0.0 { continue }
                    let path = paths[j]
                    let u0 = 0.12 + 0.73 * u01(hk &+ 3)
                    let i0 = min(max(Int(u0 * Float(n - 1)), 2), n - 3)
                    let slope = (path[i0 + 2] - path[i0 - 2]) / (4.0 * step)
                    let side: Float = u01(hk &+ 4) > 0.5 ? 1.0 : -1.0
                    let ang = atanf(slope) + (0.35 + 0.5 * u01(hk &+ 5)) * side
                    let len = arcForkLen(l) * (0.45 + 0.55 * u01(hk &+ 6))
                    let o = a + dir * (u0 * l) + nrm * path[i0]
                    let sa = sinf(ang), ca = cosf(ang)
                    let fd = SIMD2<Float>(dir.x * ca - dir.y * sa, dir.x * sa + dir.y * ca)
                    let (grow, lifee, heat) = forkEnv(age: fage, life: life)
                    data.append(SIMD4<Float>(o.x, o.y, fd.x, fd.y))
                    data.append(SIMD4<Float>(len, grow, lifee * max(bright[0], 0.6), heat))
                    pushSamples(&data, forkWalk(hk, len: len))
                    forks += 1
                }
            }
            data[hdr] = SIMD4<Float>(Float(n), Float(strands), Float(forks), 0.0)
            return SIMD4<Float>(first, Float(n), Float(forks), Float(strands))

        case .border:
            let total = rrectTotal(shape.rect, shape.radius)
            let n = nextMult4(min(max(Int(ceilf(total)), 64), 2048))
            let step = total / Float(n)
            let cells = max(Int(roundf(total * freq)), 3)
            let paths: [[Float]] = (0..<max(strands, 2)).map { j in
                let ks = k - Int32(j)
                let ch = st.channel(ks)
                let coarse = (0..<cells).map { idx in p.amplitude * 0.7 * gauss3(hu(ch, UInt32(idx) * 3 + 5)) }
                let ctrl = mpd(coarse, periodic: true, levels: 3, amp: { lv in p.amplitude * 0.7 * powf(2.0, -0.62 * Float(lv + 1)) }, channel: ch, strike: st.strikeSeed(ks), memory: 1)
                return resample(ctrl, count: n, periodic: true, limit: p.amplitude * 1.7)
            }
            for v in paths[0..<strands] { pushSamples(&data, v) }
            for v in paths[0..<strands] { pushSamples(&data, blur3(v, radius: p.glow * 1.2 / step, wrap: true)) }
            for j in 0..<strands {
                pushSamples(&data, crawl(n: n, cells: cells, speed: p.speed, t: t, seed: seed &+ UInt32(j) * 7919, k: Float(j), calm: false))
            }
            var forks = 0
            outerB: for j in 0..<2 {
                let ks = k - Int32(j)
                let fage = t - startOf(ks)
                for c in 0..<3 as Range<UInt32> {
                    if forks == 5 { break outerB }
                    let hk = hu(st.strikeSeed(ks) ^ 0xF04C, c)
                    let life = 0.07 + 0.13 * u01(hk &+ 2)
                    if u01(hk) > rate || fage > life || fage < 0.0 { continue }
                    let i0 = min(Int(u01(hk &+ 3) * Float(n)), n - 1)
                    let len = p.forkLen * (0.6 + 0.6 * u01(hk &+ 4))
                    let (grow, lifee, heat) = forkEnv(age: fage, life: life)
                    data.append(SIMD4<Float>(Float(i0) * step, total, paths[j][i0], 0.0))
                    data.append(SIMD4<Float>(len, grow, lifee * max(bright[0], 0.6), heat))
                    pushSamples(&data, forkWalk(hk, len: len))
                    forks += 1
                }
            }
            data[hdr] = SIMD4<Float>(Float(n), Float(strands), Float(forks), 0.0)
            return SIMD4<Float>(first, Float(n), Float(forks), Float(strands))

        case .charged:
            data[hdr + 1] = SIMD4<Float>(1.0, 0.0, 0.0, 0.0)
            let total = rrectTotal(shape.rect, shape.radius)
            let n = nextMult4(min(max(Int(ceilf(total)), 64), 2048))
            let step = total / Float(n)
            let cells = max(Int32(roundf(total * freq)), 3)
            let sp = p.speed * 0.35
            let tm = reduced ? 0.0 : t
            let buf = (0..<n).map { idx -> Float in
                let x = Float(idx) / Float(n) * Float(cells)
                return disp(x, tm * sp, per0: cells, seed: seed, oct: 3) * p.amplitude
            }
            pushSamples(&data, buf)
            pushSamples(&data, blur3(buf, radius: p.glow * 1.2 / step, wrap: true))
            pushSamples(&data, crawl(n: n, cells: Int(cells), speed: p.speed, t: tm, seed: seed, k: 0.0, calm: true))
            var forks = 0
            for j in 0..<5 as Range<UInt32> {
                guard let f = forkSlot(seed: seed, j: j, t: t, rate: rate * 0.5, baseP: 0.3, varP: 0.25) else { continue }
                let hk = f.hk
                let len = p.forkLen * 0.4 * (0.6 + 0.6 * u01(hk &+ 4))
                let (grow, lifee, heat) = forkEnv(age: f.age, life: f.life)
                data.append(SIMD4<Float>(u01(hk &+ 3) * total, total, 0.0, 0.0))
                data.append(SIMD4<Float>(len, grow, lifee, heat))
                pushSamples(&data, forkWalk(hk, len: len))
                forks += 1
            }
            data[hdr] = SIMD4<Float>(Float(n), 1.0, Float(forks), 0.0)
            return SIMD4<Float>(first, Float(n), Float(forks), 1.0)
        }
    }

    private static func crawl(n: Int, cells: Int, speed: Float, t: Float, seed: UInt32, k: Float, calm: Bool) -> [Float] {
        let cc = max(Int32(cells / 3), 2)
        let sp = calm ? speed * 0.35 : speed
        return (0..<n).map { i in
            let cx = Float(i) / Float(n) * Float(cc)
            let c = 0.5 + 0.5 * gnoise(cx - t * sp * 0.08 * Float(cc), t * 0.35 + k * 5.0, per: cc, seed: seed &+ 3)
            return calm ? (0.45 + 0.55 * ss(0.2, 0.8, c)) : (0.3 + 0.7 * ss(0.25, 0.75, c))
        }
    }

    private static func forkSlot(seed: UInt32, j: UInt32, t: Float, rate: Float, baseP: Float, varP: Float) -> (hk: UInt32, age: Float, life: Float)? {
        let hj = hu(seed, j * 977 + 13)
        let p = baseP + varP * u01(hj)
        let tau = t / p + u01(hj &+ 1)
        let kk = floorf(tau)
        let age = (tau - kk) * p
        let hk = hu(hj, UInt32(bitPattern: Int32(kk)))
        if u01(hk) > rate { return nil }
        let life = 0.15 + 0.1 * u01(hk &+ 2)
        if age > life { return nil }
        return (hk, age, life)
    }

    public static func embers(
        _ p: FireParams,
        rect: FxRect,
        radius: Float,
        t: Float,
        seed: UInt32,
        data: inout [SIMD4<Float>]
    ) -> (Float, Float) {
        let first = Float(data.count)
        var count: UInt32 = 0
        let life0 = max(p.emberLife, 0.1)
        let k = emberDrag
        for e in 0..<min(p.embers, 40) {
            let hk0 = hu(seed &+ 991, e * 7 + 3)
            let life = life0 * (0.6 + 0.8 * u01(hk0))
            let tau = t / life + u01(hk0 &+ 1)
            let kk = floorf(tau)
            let a = tau - kk
            let hk = hu(hk0, UInt32(bitPattern: Int32(kk)))
            let age = a * life
            let x0 = rect.x + radius * 0.6 + (rect.w - radius * 1.2) * u01(hk &+ 2)
            let y0 = rect.y - p.height * (0.1 + 0.45 * u01(hk &+ 3))
            let v0 = -p.emberRise * (1.0 + 0.8 * u01(hk &+ 4))
            let vt = -p.emberRise * 0.32
            let ek = expf(-k * age)
            let y = y0 + vt * age + (v0 - vt) * (1.0 - ek) / k
            let vy = vt + (v0 - vt) * ek
            let sway = 2.5 + 5.0 * u01(hk &+ 5)
            let fq = 3.0 + 4.0 * u01(hk &+ 6)
            let ph = Self.tau * u01(hk &+ 7)
            let drift = (u01(hk &+ 8) - 0.5) * 14.0
            let grow = 1.0 - expf(-age * 3.0)
            let x = x0 + drift * age + sway * sinf(age * fq + ph) * grow
            let vx = drift + sway * (cosf(age * fq + ph) * fq * grow + sinf(age * fq + ph) * 3.0 * expf(-age * 3.0))
            let sz = p.emberSize * (0.5 + 0.8 * u01(hk &+ 9)) * (1.0 - 0.4 * a)
            let attack = min(max(age / 0.05, 0.0), 1.0)
            let temp = expf(-age / (life * 0.42)) * (1.0 - a * a) * (0.8 + 0.3 * u01(hk &+ 10)) * attack
            if temp < 0.004 { continue }
            let kShutter: Float = 0.6 / 60.0
            data.append(SIMD4<Float>(x, y, vx * kShutter, vy * kShutter))
            data.append(SIMD4<Float>(sz, temp, 0.0, 0.0))
            count += 1
        }
        return (first, Float(count))
    }

    private static func starScale(_ a: Float) -> Float {
        let x = min(a / 0.22, 1.0)
        let c: Float = 2.2
        let xm1 = x - 1.0
        let squared = xm1 * xm1
        let back = 1.0 + (c + 1.0) * (squared * xm1) + c * squared
        return back * (1.0 - ss(0.55, 1.0, a))
    }

    public static func sparkles(
        _ p: SparkleParams,
        rect: FxRect,
        t: Float,
        seed: UInt32,
        reduced: Bool,
        data: inout [SIMD4<Float>]
    ) -> (Float, Float) {
        let first = Float(data.count)
        var count: UInt32 = 0
        let cx = rect.x + rect.w * 0.5
        let cy = rect.y + rect.h * 0.5
        let hw = rect.w * 0.5
        let hh = rect.h * 0.5
        for k in 0..<min(p.count, 64) {
            let h0 = hu(seed &+ 313, k * 11 + 1)
            let (hk, age, life): (UInt32, Float, Float)
            if let t0 = p.burst {
                life = p.life * burstLife * (0.7 + 0.6 * u01(h0))
                hk = h0
                age = t - t0 - sparkleStagger * u01(h0 &+ 1)
            } else if reduced {
                if u01(h0 &+ 9) > 0.6 { continue }
                (hk, age, life) = (h0, 0.5, 1.0)
            } else {
                life = p.life * (0.7 + 0.6 * u01(h0))
                let cycle = life * (1.5 + 0.8 * u01(h0 &+ 2))
                let tau = t / cycle + u01(h0 &+ 1)
                let kk = floorf(tau)
                hk = hu(h0, UInt32(bitPattern: Int32(kk)))
                age = (tau - kk) * cycle
            }
            if age < 0.0 || age > life { continue }
            let a = age / life
            let th = Self.tau * u01(hk &+ 2)
            let dx = cosf(th)
            let dy = sinf(th)
            let edge = 1.0 / max(abs(dx) / max(hw, 1.0), abs(dy) / max(hh, 1.0))
            var out = p.margin * (0.15 + 0.85 * u01(hk &+ 3))
            if p.burst != nil && !reduced {
                out *= 0.35 + 0.65 * (1.0 - expf(-age * 5.0))
            }
            let pos = SIMD2<Float>(cx + dx * (edge + out), cy + dy * (edge + out))
            let v = u01(hk &+ 4)
            let size = p.size * (0.45 + 0.9 * v * v)
            let (sc, env): (Float, Float) = reduced
                ? (1.0, sinf(Self.pi * a) * 0.7)
                : {
                    let fq = 5.0 + 4.0 * u01(hk &+ 5)
                    let tw = 0.5 + 0.5 * sinf(Self.tau * fq * age + Self.tau * u01(hk &+ 6))
                    return (starScale(a), 1.0 - 0.3 * tw * tw)
                }()
            if sc * env < 0.01 { continue }
            let spin: Float = reduced ? 0.0 : (u01(hk &+ 7) - 0.5) * 1.2 * age
            let ang = (u01(hk &+ 8) - 0.5) * 0.35 + spin
            data.append(SIMD4<Float>(pos.x, pos.y, size * sc, env))
            data.append(SIMD4<Float>(cosf(ang), sinf(ang), 0.0, 0.0))
            count += 1
        }
        return (first, Float(count))
    }

    public static func aurora(
        _ p: AuroraParams,
        rect: FxRect,
        t: Float,
        seed: UInt32,
        data: inout [SIMD4<Float>]
    ) -> Float {
        let first = Float(data.count)
        let tt = t * p.speed
        var ys = [Float](repeating: 0.0, count: auroraSamples)
        var ws = [Float](repeating: 0.0, count: auroraSamples)
        for k in 0..<3 as Range<UInt32> {
            let fk = Float(k)
            for i in 0..<auroraSamples {
                let x = rect.x + rect.w * Float(i) / Float(auroraSamples - 1)
                let qx = x / max(p.scale, 1.0)
                var s: Float = 0.0
                var a: Float = 0.5
                var px = qx * 0.55 + tt * (0.25 + 0.12 * fk)
                var py = fk * 3.1 + tt * 0.07
                for o in 0..<3 as Range<UInt32> {
                    s += a * gnoise(px, py, per: 0, seed: seed &+ k &+ o * 131)
                    let nx = 0.8 * px - 0.6 * py
                    let ny = 0.6 * px + 0.8 * py
                    px = nx * 2.02
                    py = ny * 2.02
                    a *= 0.5
                }
                let wv = s / 0.875
                ws[i] = wv
                ys[i] = 0.3 + 0.2 * fk + 0.22 * wv
            }
            pushSamples(&data, ys)
            pushSamples(&data, ws)
        }
        return first
    }

    public static func foldT(_ t: Float) -> Float {
        if !t.isFinite { return 0.0 }
        let raw = Double(t) * (1.0 / 1024.0)
        let u = raw - floor(raw)
        return Float(u <= 0.5 ? u * 1024.0 : (1.0 - u) * 1024.0)
    }

    public static func meshPoints(_ p: MeshGradientParams, time t: Float, seed: UInt32) -> [SIMD2<Float>] {
        let tt = foldT(t * p.speed * 0.5)
        let drift = p.drift.isFinite ? p.drift : 0.0
        return p.points.enumerated().map { k, q in
            let s = seed &+ UInt32(k) * 31
            let x = tt + Float(k) * 13.1
            return SIMD2<Float>(
                q.x + drift * 1.4 * gnoise(x, 0.5, seed: s),
                q.y + drift * 1.4 * gnoise(x, 7.5, seed: s &+ 97)
            )
        }
    }

    public static func metaballs(
        _ p: MetaballParams,
        rect: FxRect,
        time t: Float,
        seed: UInt32,
        data: inout [SIMD4<Float>]
    ) {
        let n = min(max(p.count, 1), 8)
        let short = max(min(rect.w, rect.h), 0.0)
        let tt = foldT(t * p.speed * 0.5)
        let size = p.size.isFinite ? max(p.size, 0.0) : 0.0
        let colors = UInt32(max(p.colors.count, 1))
        for k in 0..<n {
            let h = hu(seed, k + 1)
            let a = (Float(k) + u01(h) * 0.6) / Float(n) * Self.tau
            let baseX = 0.5 + 0.24 * cosf(a)
            let baseY = 0.5 + 0.24 * sinf(a)
            let x = tt + Float(k) * 7.3
            let wx = gnoise(x, 1.5, seed: h) * 0.5
            let wy = gnoise(x, 4.5, seed: h &+ 5) * 0.5
            let r = size * short * (0.7 + 0.6 * u01(h &+ 2))
            data.append(SIMD4<Float>(rect.x + rect.w * (baseX + wx), rect.y + rect.h * (baseY + wy), r, Float(k % colors)))
        }
    }

    /// The pinned void-and-cluster filter has a fixed seed, Gaussian kernel and tile size.
    /// Its row-major ranks are precomputed so the first blue-noise fill can draw immediately.
    public static let blueNoiseTile: [SIMD4<Float>] = {
        let ranks: [UInt16] = [
             880,  263,  118,  708,  331,  534,  989,  124,  690,  287,   21,  614,  828,  559,  944,    2,
             295,  171,  698,   49,  919,  610,   78,  518,  402,  677,  175,  837,    5,  997,  634,  367,
              43,  660,  416,  207,  784,    4,  404,  827,  466,  778,  985,  483,  242,  329,  689,  411,
             512,  906,  343,  493,  809,  315, 1012,  229,  889,  298,  494,  709,  413,  228,  482,  758,
             544,  806,  983,  563,  900,  642,  300,  916,   65,  363,  167,  722,   89,  783,  136,  844,
             639,   88,  763,  585,  198,  450,  646,  760,   30,  791,  968,   90,  596,  877,  116,  951,
             308,  144,  354,   68,  462,  177,  732,  581,  217,  664,  552,  902,  381,  976,  575,  218,
             964,  438,  251,  980,   15,  878,  143,  365,  576,  434,  155,  286,  776,  338,  686,  204,
             865,  509,  726,  852,  277,  970,   84,  502, 1014,  817,  273,   54,  648,  463,  288,   44,
             362,  799,  131,  665,  388,  718,  532,  957,  210,  911,  652,  517, 1019,   52,  572,  445,
              12, 1004,  226,  604,  688,  419,  775,  351,  137,  428,  740,  516,  181,  832,  752,  896,
             537,  696,  921,  496,  268,  818,   70,  305,  700,   41,  358,  835,  212,  401,  913,  762,
             645,  391,  119,  485,   28,  892,  235,  635,  849,   11,  922,  340,  996,  103,  415,  623,
             183,  296,   57,  602,  162, 1001,  425,  609,  845,  486,  751,  106,  605,  723,  134,  252,
             789,  543,  840,  960,  348,  166,  545,  935,  303,  484,  224,  662,  560,  257,  703,   14,
            1011,  476,  836,  361,  779,  514,   98,  903,  243,  146,  974,  454,  274,  956,  497,  344,
             943,  178,  292,  620,  734,  820,  449,   94,  721,  580,  802,   74,  875,  372,  936,  519,
             328,  741,  127,  932,  650,  209,  756,  359,  675,  566,  330,  876,   25,  666,  850,   67,
             442,  674,   38,  424,  223,   58,  656,  992,  193,  379,  972,  161,  457,  744,  111,  214,
             868,  613,  255,  448,   17,  312,  967,  474,   32,  785,  196,  704,  535,  383,  164,  590,
             250,  882,  769, 1020,  579,  909,  373,  276,  846,   31,  672,  527,  244,  829,  569,  670,
             430,   62,  984,  564,  874,  711,  594,  132,  910,  397, 1002,   97,  821,  293,  990,  742,
             370,  529,  101,  327,  489,  153,  774,  515,  615,  433,  780,  324,  908,   36,  350,  966,
             163,  730,  376,  805,  174,  407,  260,  825,  521,  279,  616,  446,  220,  630,  480,  114,
             937,  200,  638,  831,  262,  673,   75,  872,  138,  249,  938,   91,  608,  707,  487,  281,
             842,  508,  241,   82,  536, 1023,   42,  661,  168,  765,   55,  941,  693,  885,   13,  798,
             692,  432,  978,   20,  747,  961,  405,  316, 1005,  717,  554,  179,  422, 1015,  142,  766,
               6,  619,  915,  676,  345,  753,  471,  931,  357,  881,  573,  341,  135,  390,  553,  282,
             591,  133,  352,  556,  456,  187,  571,  655,    7,  467,  346,  794,  873,  232,  649,  400,
             946,  301,  451,  128,  859,  195,  606,  105,  435,  710,  202,  501,  770, 1013,  192,  867,
              45,  737,  884,  247,  839,  104,  920,  788,  216,  855,  625,   46,  302,  538,   63,  857,
             557,  190,  719,  981,  562,  311,  803,  261,  998,    1,  310,  858,   60,  612,  464,  336,
             918,  495,  173,  624,  701,  375,  284,  513,  414,  126,  986,  736,  475,  953,  714,  325,
              96,  816,  380,   85,  478,   26,  907,  681,  542,  815,  631,  949,  258,  729,  110,  787,
             265,  394, 1008,   35,  473,  965,   71,  745,  904,  565,  256,  387,  150,  595,  206,  439,
             999,  657,  269,  894,  781,  636,  409,  122,  213,  366,  452,  148,  551,  412,  977,  643,
              72,  574,  796,  326,  862,  587,  172,  663,  317,   29,  694,  927,  814,   87,  895,  748,
             510,  156,  427,  586,  225,  334,  987,  503,  754,  924,   79,  679,  795,  319,  197,  506,
             939,  208,  684,  129,  253,  767,  396, 1018,  469,  801,  201,  525,  299,  667,  369,  248,
              18,  804,  955,   59,  725,  149,  838,   40,  306,  598,  864,  236,  962,   24,  843,  695,
             364,  856,  443,  539,  950,   10,  507,  234,   86,  879,  637,  423,   47, 1010,  546,  833,
             617,  323,  680,  522,  930,  444,  647,  550,  952,  176,  477,  355,  523,  618,  436,  107,
             283,  600,   48,  735,  378,  633,  824,  925,  592,  371,  139,  945,  773,  180,  453,   99,
             973,  191,  389,  113,  297,  790,  221,  368,   92,  712,  823,   50,  761,  157, 1016,  731,
             883,  170,  995,  290,  893,  188,  321,  120,  716,  270,  500,  685,  335,  603,  871,  275,
             715,  488,  914,  841,  584,    8, 1017,  671,  870,  417,  280,  654,  891,  392,  233,  533,
             431,  641,  793,  504,   81,  699,  459,  548,  786,  982,   73,  822,  230,    0,  750,  395,
             578,   53,  759,  231,  420,  733,  152,  481,  240,  577,  993,  117,  314,  568,  800,    3,
             307,  100,  374,  215,  589,  813, 1003,   23,  408,  186,  628,  429,  928,  511,  994,  141,
             898,  339,  160,  640,  934,  349,  547,  905,   61,  808,  182,  499,  933,   80,  668,  975,
             768,  901,  683,  954,  426,  151,  278,  658,  890,  318,  851,  570,  130,  356,  644,  245,
             691,  528, 1006,  465,  108,  812,  264,  706,  441,  353,  724,  627,  410,  854,  219,  472,
             158,  526,  254,   27,  749,  848,  385,  109,  520,  739,   39,  267,  697,  811,   76,  455,
             860,   22,  792,  304,  588,   51,  991,  140,  601,  959,   16,  259,  764,  123,  360,  607,
              64,  834,  440,  626,  313,  531,  963,  713,  227,  917,  468,  979,  393,  211,  948,  582,
             289,  403,  199,  720,  886,  406,  659,  322,  866,  222,  826,  558, 1009,  492,  702,  947,
             337,  727, 1022,  121,  888,  205,   34,  597,  421,  145,  622,   95,  861,  490,  743,  154,
             705,  971,  611,  125,  498,  237,  782,  530,   83,  479,  386,  147,  309,   37,  869,  239,
             651,  194,  384,  561,  687,  460,  807,  294, 1007,  819,  332,  771,  549,   33,  320,  897,
              66,  470,  830,  333,  958,    9,  912,  185,  632,  755,  899,  669,  797,  599,  399,  524,
             969,   19,  777,  285,   77,  940,  377,  746,   69,  505,  189,  682,  272, 1021,  653,  382,
             540,  246,  102,  757,  555,  678,  437,  342,  988,  266,   56,  458,  203,  926,   93,  810,
             461,  593,  929,  491,  853,  169,  629,  238,  567,  887,  398,  923,  115,  447,  184,  772,
             863,  621, 1000,  418,  271,  165,  847,  738,  112,  583,  942,  347,  541,  728,  291,  159,
        ]
        func threshold(_ i: Int) -> Float { (Float(ranks[i]) + 0.5) / Float(blueN * blueN) }
        return stride(from: 0, to: ranks.count, by: 4).map { i in
            SIMD4(threshold(i), threshold(i + 1), threshold(i + 2), threshold(i + 3))
        }
    }()
}
