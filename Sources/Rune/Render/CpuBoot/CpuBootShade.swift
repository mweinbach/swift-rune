import Foundation
#if canImport(simd)
import simd
#endif

/// Analytic SDF shading, clips, shadows, gradients, and image sampling (`cpu_boot/shade.rs`).
public enum CpuBootShade {
    public static let shadowInside: Float = 0.99863125

    @inline(__always)
    public static func clamp01(_ v: Float) -> Float {
        min(max(v, 0.0), 1.0)
    }

    @inline(__always)
    public static func mix4(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
        a * (1.0 - t) + b * t
    }

    @inline(__always)
    public static func sdContinuous(_ p: SIMD2<Float>, half: SIMD2<Float>, r: Float) -> Float {
        let e = CONTINUOUS_K * r
        let q = half - SIMD2(abs(p.x), abs(p.y))
        let v = SIMD2<Float>(repeating: e) - q
        if v.x <= 0.0 || v.y <= 0.0 {
            return max(-q.x, -q.y)
        }
        let u = atan2f(v.y, v.x) * (4.0 / 3.14159265) - 1.0
        let u2 = u * u
        return (v.x * v.x + v.y * v.y).squareRoot() - e * (1.14602295 + u2 * (-0.37573161 + u2 * (0.30796609 - 0.07724354 * u2)))
    }

    @inline(__always)
    public static func sdRounded(_ p: SIMD2<Float>, half: SIMD2<Float>, radii: SIMD4<Float>) -> Float {
        var r = radii.x
        if p.x > 0.0 {
            r = p.y > 0.0 ? radii.z : radii.y
        } else {
            r = p.y > 0.0 ? radii.w : radii.x
        }
        if r < 0.0 {
            return sdContinuous(p, half: half, r: min(-r, min(half.x, half.y)))
        }
        r = min(r, min(half.x, half.y))
        let q = SIMD2(abs(p.x), abs(p.y)) - half + SIMD2<Float>(repeating: r)
        let dx = max(q.x, 0), dy = max(q.y, 0)
        return min(max(q.x, q.y), 0.0) + (dx * dx + dy * dy).squareRoot() - r
    }

    @inline(__always)
    public static func ramp(_ d: Float, fade: Float) -> Float {
        if fade == 0.0 { return clamp01(d + 0.5) }
        let x = clamp01(d / abs(fade))
        if fade < 0.0 { return x }
        return x * x * (3.0 - 2.0 * x)
    }

    /// Per-instance clip state (`cpu_boot::shade::Clip`).
    public struct Clip: Sendable, Equatable {
        public let rect: SIMD4<Float>
        public let fadeWidth: SIMD4<Float>
        public let fadeOffset: SIMD4<Float>
        public let radii: SIMD4<Float>?

        public init(rect: SIMD4<Float>, fadeWidth: SIMD4<Float>, fadeOffset: SIMD4<Float>, radii: SIMD4<Float>?) {
            self.rect = rect
            self.fadeWidth = fadeWidth
            self.fadeOffset = fadeOffset
            self.radii = radii
        }

        public static func of(_ inst: RenderInstance) -> Clip {
            let decoded = unpackFade(inst.fade)
            let rawRadii = unpackClipRadii(inst.fade.w)
            let hasRadii = inst.fade.w != 0 && (rawRadii.x != 0 || rawRadii.y != 0 || rawRadii.z != 0 || rawRadii.w != 0)
            return Clip(
                rect: inst.clip,
                fadeWidth: decoded.width,
                fadeOffset: decoded.offset,
                radii: hasRadii ? rawRadii : nil
            )
        }

        /// Margin inside `rect` beyond which `alpha(p)` is guaranteed `1.0`.
        public func inset() -> SIMD4<Float> {
            var result = SIMD4<Float>(repeating: 0.5)
            for edge in 0..<4 where fadeOffset[edge] < 1 {
                result[edge] = max(0.5, abs(fadeWidth[edge]))
            }
            return result
        }

        public func alpha(_ p: SIMD2<Float>) -> Float {
            let hard = SIMD4<Float>(p.x - rect.x, p.y - rect.y, rect.z - p.x, rect.w - p.y)
            var a: Float = 1.0
            for edge in 0..<4 {
                let d = hard[edge], f = fadeWidth[edge], offset = fadeOffset[edge]
                if offset >= 1 {
                    a *= ramp(d, fade: 0)
                } else if offset > 0 {
                    a *= min(ramp(d, fade: 0), ramp(d + offset * abs(f), fade: f))
                } else {
                    a *= ramp(d, fade: f)
                }
            }
            if let r = radii {
                let half = SIMD2<Float>((rect.z - rect.x) * 0.5, (rect.w - rect.y) * 0.5)
                let center = SIMD2<Float>(rect.x + half.x, rect.y + half.y)
                a *= clamp01(0.5 - sdRounded(p - center, half: half, radii: r))
            }
            return a
        }
    }

    @inline(__always)
    private static func gaussian(_ x: Float, sigma: Float) -> Float {
        expf(-(x * x) / (2.0 * sigma * sigma)) / (sqrtf(2.0 * 3.14159265) * sigma)
    }

    @inline(__always)
    private static func erfApprox(_ x: Float) -> Float {
        let s: Float = x >= 0 ? 1.0 : -1.0
        let a = abs(x)
        var r = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a
        r = r * r
        return s - s / (r * r)
    }

    @inline(__always)
    private static func shadowX(x: Float, y: Float, sigma: Float, corner: Float, half: SIMD2<Float>) -> Float {
        let delta = min(half.y - corner - abs(y), 0.0)
        let curved = half.x - corner + sqrtf(max(0.0, corner * corner - delta * delta))
        let k = sqrtf(0.5) / sigma
        let a = 0.5 + 0.5 * erfApprox((x - curved) * k)
        let b = 0.5 + 0.5 * erfApprox((x + curved) * k)
        return b - a
    }

    @inline(__always)
    public static func shadow(_ p: SIMD2<Float>, half: SIMD2<Float>, sigma: Float, corner: Float) -> Float {
        if abs(p.x) <= half.x - 6.0 * sigma && abs(p.y) <= half.y - corner - 6.0 * sigma {
            return shadowInside
        }
        let lo = p.y - half.y
        let hi = p.y + half.y
        let start = min(max(-3.0 * sigma, lo), hi)
        let end = min(max(3.0 * sigma, lo), hi)
        let step = (end - start) / 4.0
        var y = start + step * 0.5
        var v: Float = 0.0
        for _ in 0..<4 {
            v += shadowX(x: p.x, y: p.y - y, sigma: sigma, corner: corner, half: half) * gaussian(y, sigma: sigma) * step
            y += step
        }
        return v
    }

    public struct ShadowRow: Sendable {
        public let y: UInt32
        public let py: Float
        public let samples: [(curved: Float, g: Float)]
        public let step: Float
        public let half: SIMD2<Float>
        public let sigma: Float
        public let corner: Float
        public let k: Float
        public let mid: (Float, Float)
        public let centerY: Float

        public func key() -> UInt64 {
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            for s in samples {
                h = (h ^ UInt64(s.curved.bitPattern)) &* 0x100000001b3
                h = (h ^ UInt64(s.g.bitPattern)) &* 0x100000001b3
            }
            h = (h ^ UInt64(step.bitPattern)) &* 0x100000001b3
            return h
        }

        public func inside(_ dx: Float) -> Bool {
            abs(dx) <= half.x - 6.0 * sigma && abs(py - centerY) <= half.y - corner - 6.0 * sigma
        }

        public func flat() -> (Float, Float)? {
            if abs(py - centerY) <= half.y - corner - 6.0 * sigma {
                let reach = half.x - 6.0 * sigma
                return reach > 0 ? (reach, shadowInside) : nil
            }
            return mid.0 > 0 ? mid : nil
        }

        public func sum(_ dx: Float) -> Float {
            var v: Float = 0.0
            for (curved, g) in samples {
                let b = 0.5 + 0.5 * erfApprox((dx + curved) * k)
                let a = 0.5 + 0.5 * erfApprox((dx - curved) * k)
                v += (b - a) * g * step
            }
            return v
        }
    }

    public static func shadowRow(_ i: RenderInstance, y: UInt32, py: Float) -> ShadowRow {
        let half = SIMD2<Float>(i.rect.z * 0.5, i.rect.w * 0.5)
        let centerY = i.rect.y + half.y
        let sigma = max(i.params.z, 0.01)
        let corner = min(abs(i.radii.x), min(half.x, half.y))
        let relY = py - centerY
        let lo = relY - half.y
        let hi = relY + half.y
        let start = min(max(-3.0 * sigma, lo), hi)
        let end = min(max(3.0 * sigma, lo), hi)
        let step = (end - start) / 4.0
        var samples: [(Float, Float)] = []
        samples.reserveCapacity(4)
        for m in 0..<4 {
            let yOff = start + step * (0.5 + Float(m))
            let delta = min(half.y - corner - abs(relY - yOff), 0.0)
            let curved = half.x - corner + sqrtf(max(0.0, corner * corner - delta * delta))
            let g = gaussian(yOff, sigma: sigma)
            samples.append((curved, g))
        }
        let k = sqrtf(0.5) / sigma
        let minCurved = samples.map(\.0).min() ?? 0.0
        let reach = minCurved - 5.5 / k
        var v: Float = 0.0
        for (_, g) in samples {
            v += g * step
        }
        let mid = (reach - abs(reach) * 1e-6 - 1e-3, v)
        return ShadowRow(
            y: y,
            py: py,
            samples: samples,
            step: step,
            half: half,
            sigma: sigma,
            corner: corner,
            k: k,
            mid: mid,
            centerY: centerY
        )
    }

    public static func shadowCov(_ i: RenderInstance, row: ShadowRow, px: Float, cov: Float) -> SIMD4<Float> {
        var c = cov
        if i.uv.z > 0.0 {
            let hole = SIMD2<Float>(i.uv.z * 0.5, i.uv.w * 0.5)
            let at = SIMD2<Float>(px - (i.rect.x + i.uv.x + hole.x), row.py - (i.rect.y + i.uv.y + hole.y))
            c *= clamp01(0.5 + sdRounded(at, half: hole, radii: SIMD4<Float>(repeating: i.radii.w)))
        }
        return i.fill * c
    }

    public static func segment(_ p: SIMD2<Float>, a: SIMD2<Float>, b: SIMD2<Float>, hw: Float, roundCap: Bool) -> Float {
        let w = max(hw, 0.5)
        let weight = min(hw * 2.0, 1.0)
        let ab = b - a
        let len = hypotf(ab.x, ab.y)
        let ap = p - a
        let d: Float
        if len < 1e-4 {
            if !roundCap { return 0.0 }
            d = hypotf(ap.x, ap.y) - w
        } else {
            let dir = ab / len
            let along = ap.x * dir.x + ap.y * dir.y
            if roundCap {
                let t = min(max(along, 0.0), len)
                let dx = ap.x - dir.x * t
                let dy = ap.y - dir.y * t
                d = hypotf(dx, dy) - w
            } else {
                let across = abs(dir.x * ap.y - dir.y * ap.x)
                let qx = abs(along - len * 0.5) - len * 0.5
                let qy = across - w
                d = min(max(qx, qy), 0.0) + hypotf(max(qx, 0.0), max(qy, 0.0))
            }
        }
        return clamp01(0.5 - d) * weight
    }

    private static func edge(_ p: SIMD2<Float>, a: SIMD2<Float>, b: SIMD2<Float>, c: SIMD2<Float>) -> Float {
        let e = b - a
        let l = max(hypotf(e.x, e.y), 1e-6)
        let n = SIMD2<Float>(-e.y / l, e.x / l)
        let s: Float = ((c.x - a.x) * n.x + (c.y - a.y) * n.y) >= 0.0 ? 1.0 : -1.0
        return ((p.x - a.x) * n.x + (p.y - a.y) * n.y) * s
    }

    private static func owns(_ p: SIMD2<Float>, a: SIMD2<Float>, b: SIMD2<Float>, c: SIMD2<Float>) -> Bool {
        let swap = a.x > b.x || (a.x == b.x && a.y > b.y)
        let lo = swap ? b : a
        let hi = swap ? a : b
        let e = hi - lo
        let side = e.x * (c.y - lo.y) - e.y * (c.x - lo.x)
        let v = e.x * (p.y - lo.y) - e.y * (p.x - lo.x)
        return side > 0.0 ? (v >= 0.0) : (v < 0.0)
    }

    private static func soft(_ p: SIMD2<Float>, a: SIMD2<Float>, b: SIMD2<Float>, c: SIMD2<Float>) -> Float {
        let d = edge(p, a: a, b: b, c: c)
        let e = b - a
        let t = ((p.x - a.x) * e.x + (p.y - a.y) * e.y) / max(e.x * e.x + e.y * e.y, 1e-6)
        if t < 0.0 || t > 1.0 { return d >= 0.0 ? 1.0 : 0.0 }
        return clamp01(d + 0.5)
    }

    public static func triangle(_ p: SIMD2<Float>, a: SIMD2<Float>, b: SIMD2<Float>, c: SIMD2<Float>, aa: UInt32) -> Float {
        var cov: Float = 1.0
        let edges: [(UInt32, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)] = [
            (1, a, b, c),
            (2, b, c, a),
            (4, c, a, b),
        ]
        for (bit, u, v, w) in edges {
            if (aa & bit) != 0 {
                cov *= soft(p, a: u, b: v, c: w)
            } else if !owns(p, a: u, b: v, c: w) {
                return 0.0
            }
        }
        return cov
    }

    public static func ringArc(p: SIMD2<Float>, size: SIMD2<Float>, radii: SIMD4<Float>, bw: Float) -> (Float, Float) {
        let h = bw * 0.5
        let half = size * 0.5
        let m = min(half.x, half.y)
        let rc = SIMD4<Float>(
            max(min(abs(radii.x), m) - h, 0.0),
            max(min(abs(radii.y), m) - h, 0.0),
            max(min(abs(radii.z), m) - h, 0.0),
            max(min(abs(radii.w), m) - h, 0.0)
        )
        let e = rc + SIMD4<Float>(repeating: h)
        let arc = rc * 1.570_796_4
        let sTr = max(size.x - bw - rc.x - rc.y, 0.0)
        let sRight = sTr + arc.y
        let sBr = sRight + max(size.y - bw - rc.y - rc.z, 0.0)
        let sBottom = sBr + arc.z
        let sBl = sBottom + max(size.x - bw - rc.z - rc.w, 0.0)
        let sLeft = sBl + arc.w
        let sTl = sLeft + max(size.y - bw - rc.w - rc.x, 0.0)

        let top = p.x - e.x
        let right = sRight + p.y - e.y
        let bottom = sBottom + size.x - e.z - p.x
        let left = sLeft + size.y - e.w - p.y

        let s: Float
        if p.x > half.x {
            if p.y > half.y {
                let vx = p.x - (size.x - e.z)
                let vy = p.y - (size.y - e.z)
                if vx > 0.0 && vy > 0.0 {
                    s = sBr + atan2f(vy, vx) * rc.z
                } else if size.x - p.x < size.y - p.y {
                    s = right
                } else {
                    s = bottom
                }
            } else {
                let vx = p.x - (size.x - e.y)
                let vy = p.y - e.y
                if vx > 0.0 && vy < 0.0 {
                    s = sTr + atan2f(vx, -vy) * rc.y
                } else if size.x - p.x < p.y {
                    s = right
                } else {
                    s = top
                }
            }
        } else if p.y > half.y {
            let vx = p.x - e.w
            let vy = p.y - (size.y - e.w)
            if vx < 0.0 && vy > 0.0 {
                s = sBl + atan2f(-vx, vy) * rc.w
            } else if p.x < size.y - p.y {
                s = left
            } else {
                s = bottom
            }
        } else {
            let vx = p.x - e.x
            let vy = p.y - e.x
            if vx < 0.0 && vy < 0.0 {
                s = sTl + atan2f(-vy, -vx) * rc.x
            } else if p.x < p.y {
                s = left
            } else {
                s = top
            }
        }
        return (s, sTl + arc.x)
    }

    public static func dashCov(s: Float, total: Float, d: SIMD3<Float>) -> Float {
        let nominal = d.x + d.y
        if nominal <= 1e-6 { return 1.0 }
        let k = max(total, 0.001) / (max(floorf(total / nominal + 0.5), 1.0) * nominal)
        let period = nominal * k
        let dash = d.x * k
        let a = s + d.z * k - dash * 0.5
        let m = a - period * floorf(a / period + 0.5)
        return clamp01(dash * 0.5 - abs(m) + 0.5)
    }

    private static func borderOver(
        fill: SIMD4<Float>,
        edge: SIMD4<Float>,
        d: Float,
        innerD: Float,
        soft: Float,
        bw: Float,
        opacity: Float,
        shrink: Bool
    ) -> SIMD4<Float> {
        let cov = clamp01(0.5 - d / (soft * 2.0))
        let ring = max(cov - clamp01(0.5 - innerD / (soft * 2.0)), 0.0)
        let hide = clamp01(edge.w / min(max(opacity, 1e-6), 1.0))
        let under = clamp01(0.5 - (d + (shrink && hide > 0.999 ? bw * 0.5 : 0.0)) / (soft * 2.0))
        return edge * ring + fill * (under * (1.0 - hide * ring))
    }

    private static func boxCov(_ p: SIMD2<Float>, half: SIMD2<Float>, radii: SIMD4<Float>) -> Float {
        let r = p.x > 0.0 ? (p.y > 0.0 ? radii.z : radii.y) : (p.y > 0.0 ? radii.w : radii.x)
        if r == 0.0 {
            let ex = clamp01(min(half.x, p.x + 0.5) - max(-half.x, p.x - 0.5))
            let ey = clamp01(min(half.y, p.y + 0.5) - max(-half.y, p.y - 0.5))
            return ex * ey
        }
        return clamp01(0.5 - sdRounded(p, half: half, radii: radii))
    }

    public static func sidesInner(_ i: RenderInstance, center: SIMD2<Float>, half: SIMD2<Float>) -> (SIMD2<Float>, SIMD2<Float>, SIMD4<Float>) {
        let w = i.uv
        let ih = SIMD2<Float>(max(half.x - (w.y + w.w) * 0.5, 0.0), max(half.y - (w.x + w.z) * 0.5, 0.0))
        let ic = SIMD2<Float>(center.x + (w.w - w.y) * 0.5, center.y + (w.x - w.z) * 0.5)
        let cut = SIMD4<Float>(max(w.x, w.w), max(w.x, w.y), max(w.z, w.y), max(w.z, w.w))
        let r = i.radii
        let ir = SIMD4<Float>(
            copysignf(max(abs(r.x) - cut.x, 0.0), r.x),
            copysignf(max(abs(r.y) - cut.y, 0.0), r.y),
            copysignf(max(abs(r.z) - cut.z, 0.0), r.z),
            copysignf(max(abs(r.w) - cut.w, 0.0), r.w)
        )
        return (ic, ih, ir)
    }

    public static func hasSides(_ i: RenderInstance) -> Bool {
        i.uv.z >= 0.0 && i.uv != .zero
    }

    public static func boxes(_ i: RenderInstance, kind: UInt32, p: SIMD2<Float>) -> SIMD4<Float> {
        let half = SIMD2<Float>(i.rect.z * 0.5, i.rect.w * 0.5)
        let center = SIMD2<Float>(i.rect.x + half.x, i.rect.y + half.y)
        let q = p - center
        let soft = max(i.params.z, 0.5)
        let tY = clamp01((p.y - i.rect.y) / max(i.rect.w, 1.0))

        switch kind {
        case 0: // KIND_RECT
            let d = sdRounded(q, half: half, radii: i.radii)
            let bw = i.params.x
            if bw <= 0.0 {
                return i.fill * clamp01(0.5 - d / (soft * 2.0))
            }
            let sides = hasSides(i)
            let innerD: Float
            if sides {
                let (ic, ih, ir) = sidesInner(i, center: center, half: half)
                innerD = sdRounded(p - ic, half: ih, radii: ir)
            } else {
                innerD = d + bw
            }
            return borderOver(
                fill: i.fill,
                edge: i.border,
                d: d,
                innerD: innerD,
                soft: soft,
                bw: bw,
                opacity: i.params.w,
                shrink: !sides && i.radii != .zero
            )
        case 1: // KIND_SHADOW
            let sigma = max(i.params.z, 0.01)
            let corner = min(abs(i.radii.x), min(half.x, half.y))
            var cov = shadow(q, half: half, sigma: sigma, corner: corner)
            if i.uv.z > 0.0 {
                let hole = SIMD2<Float>(i.uv.z * 0.5, i.uv.w * 0.5)
                let at = SIMD2<Float>(p.x - (i.rect.x + i.uv.x + hole.x), p.y - (i.rect.y + i.uv.y + hole.y))
                cov *= clamp01(0.5 + sdRounded(at, half: hole, radii: SIMD4<Float>(repeating: i.radii.w)))
            }
            return i.fill * cov
        case 3: // KIND_INSET
            let spread = i.params.x
            let ih = SIMD2<Float>(max(half.x - spread, 0.0), max(half.y - spread, 0.0))
            let qs = SIMD2<Float>(q.x - i.uv.x, q.y - i.uv.y)
            let lit: Float
            if i.params.z < 0.3 {
                let ir = SIMD4<Float>(
                    copysignf(max(abs(i.radii.x) - spread, 0.0), i.radii.x),
                    copysignf(max(abs(i.radii.y) - spread, 0.0), i.radii.y),
                    copysignf(max(abs(i.radii.z) - spread, 0.0), i.radii.z),
                    copysignf(max(abs(i.radii.w) - spread, 0.0), i.radii.w)
                )
                lit = boxCov(qs, half: ih, radii: ir)
            } else {
                let c = min(max(abs(i.radii.x) - spread, 0.0), min(ih.x, ih.y))
                lit = shadow(qs, half: ih, sigma: i.params.z, corner: c)
            }
            return i.fill * (boxCov(q, half: half, radii: i.radii) * (1.0 - clamp01(lit)))
        case 4: // KIND_GRADIENT
            let d = sdRounded(q, half: half, radii: i.radii)
            let bw = i.params.x
            if bw > 0.0 {
                return borderOver(
                    fill: i.fill,
                    edge: mix4(i.border, i.uv, tY),
                    d: d,
                    innerD: d + bw,
                    soft: soft,
                    bw: bw,
                    opacity: i.params.w,
                    shrink: i.radii != .zero
                )
            }
            return mix4(i.fill, i.uv, tY) * clamp01(0.5 - d / (soft * 2.0))
        case 5: // KIND_SEGMENT
            return i.fill * segment(p, a: SIMD2<Float>(i.radii.x, i.radii.y), b: SIMD2<Float>(i.radii.z, i.radii.w), hw: i.params.x, roundCap: i.params.z > 0.5)
        case 6: // KIND_TRIANGLE
            return i.fill * triangle(p, a: SIMD2<Float>(i.radii.x, i.radii.y), b: SIMD2<Float>(i.radii.z, i.radii.w), c: SIMD2<Float>(i.uv.x, i.uv.y), aa: UInt32(max(0, Int(i.params.x + 0.5))))
        case 10: // KIND_DASHED
            let d = sdRounded(q, half: half, radii: i.radii)
            let bw = i.params.x
            let ring = clamp01(0.5 - d / (soft * 2.0)) - clamp01(0.5 - (d + bw) / (soft * 2.0))
            let (s, total) = ringArc(p: SIMD2<Float>(p.x - i.rect.x, p.y - i.rect.y), size: SIMD2<Float>(i.rect.z, i.rect.w), radii: i.radii, bw: bw)
            return mix4(i.fill, i.border, tY) * (ring * dashCov(s: s, total: total, d: SIMD3<Float>(i.uv.x, i.uv.y, i.uv.z)))
        case 11: // KIND_RADIAL
            return radial(i, p: p, inside: false)
        default:
            return .zero
        }
    }

    public static func radial(_ i: RenderInstance, p: SIMD2<Float>, inside: Bool) -> SIMD4<Float> {
        let half = SIMD2<Float>(i.rect.z * 0.5, i.rect.w * 0.5)
        let q = SIMD2<Float>(p.x - (i.rect.x + half.x), p.y - (i.rect.y + half.y))
        let soft = max(i.params.z, 0.5)
        let t0Raw = i.params.x
        let t1Raw = i.params.w
        let lowerOpen = t0Raw >= 1.5
        let upperOpen = t1Raw >= 1.5
        let t0 = lowerOpen ? t0Raw - 2.0 : t0Raw
        let t1 = upperOpen ? t1Raw - 2.0 : t1Raw
        let t: Float
        if i.uv.z > 0.0 {
            let dx = (p.x - i.rect.x - i.uv.x) / i.uv.z
            let dy = (p.y - i.rect.y - i.uv.y) / i.uv.w
            t = hypotf(dx, dy)
        } else {
            t = 0.5 + (q.x * i.uv.x + q.y * i.uv.y)
        }
        if (lowerOpen && t < t0) || (upperOpen && t >= t1) {
            return .zero
        }
        let cov: Float = inside ? 1.0 : clamp01(0.5 - sdRounded(q, half: half, radii: i.radii) / (soft * 2.0))
        let u: Float = t1 <= t0 + 1e-6 ? (t >= t0 ? 1.0 : 0.0) : clamp01((t - t0) / (t1 - t0))
        return mix4(i.fill, i.border, u) * cov
    }

    public static func linearRowOutside(_ i: RenderInstance, py: Float, x0: Float, x1: Float) -> Bool {
        if i.uv.z > 0.0 { return false }
        let cx = i.rect.x + i.rect.z * 0.5
        let cy = i.rect.y + i.rect.w * 0.5
        let ta = 0.5 + ((x0 - cx) * i.uv.x + (py - cy) * i.uv.y)
        let tb = 0.5 + ((x1 - cx) * i.uv.x + (py - cy) * i.uv.y)
        let t0Raw = i.params.x
        let t1Raw = i.params.w
        return (t0Raw >= 1.5 && ta < t0Raw - 2.0 && tb < t0Raw - 2.0)
            || (t1Raw >= 1.5 && ta >= t1Raw - 2.0 && tb >= t1Raw - 2.0)
    }

    private static let srgbTables: (decoded: [Float], roundTrip: [Float]) = {
        func decode(_ c: Float) -> Float {
            c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
        }
        func encode(_ c: Float) -> Float {
            let x = min(max(c, 0.0), 1.0)
            return x <= 0.0031308 ? x * 12.92 : 1.055 * powf(x, 1.0 / 2.4) - 0.055
        }
        var dec = [Float](repeating: 0, count: 256)
        var rt = [Float](repeating: 0, count: 256)
        for v in 0..<256 {
            let d = decode(Float(v) / 255.0)
            dec[v] = d
            rt[v] = encode(d)
        }
        return (dec, rt)
    }()

    private static func srgbEncode(_ c: Float) -> Float {
        let x = min(max(c, 0.0), 1.0)
        return x <= 0.0031308 ? x * 12.92 : 1.055 * powf(x, 1.0 / 2.4) - 0.055
    }

    public static func imageTexel(_ page: CpuBootImage, x: Int, y: Int, premultiplied: Bool) -> SIMD4<Float> {
        guard x >= 0, y >= 0, x < page.width, y < page.height else { return .zero }
        let at = (y * page.width + x) * 4
        guard at + 3 < page.data.count else { return .zero }
        let c0 = page.data[at]
        let c1 = page.data[at + 1]
        let c2 = page.data[at + 2]
        let c3 = page.data[at + 3]
        let a = Float(c3) / 255.0
        if a <= 0.0 { return .zero }
        let rt = srgbTables.roundTrip
        if !premultiplied {
            return SIMD4<Float>(rt[Int(c0)] * a, rt[Int(c1)] * a, rt[Int(c2)] * a, a)
        }
        if c3 == 255 {
            return SIMD4<Float>(rt[Int(c0)], rt[Int(c1)], rt[Int(c2)], 1.0)
        }
        let dec = srgbTables.decoded
        return SIMD4<Float>(
            srgbEncode(dec[Int(c0)] / a) * a,
            srgbEncode(dec[Int(c1)] / a) * a,
            srgbEncode(dec[Int(c2)] / a) * a,
            a
        )
    }

    public static func image(_ i: RenderInstance, page: CpuBootImage, p: SIMD2<Float>) -> SIMD4<Float> {
        guard page.width > 0, page.height > 0, i.rect.z > 0, i.rect.w > 0 else { return .zero }
        let half = SIMD2<Float>(i.rect.z * 0.5, i.rect.w * 0.5)
        let d = sdRounded(SIMD2<Float>(p.x - i.rect.x - half.x, p.y - i.rect.y - half.y), half: half, radii: i.radii)
        let hasBounds = i.border.z > i.border.x && i.border.w > i.border.y
        func taps(start: Float, span: Float, lowerBound: Float, upperBound: Float, count: Int, at coordinate: Float)
            -> (first: Int, last: Int, weight: Float) {
            let end = start + span
            let lower = min(Float(count), max(0, hasBounds ? lowerBound : min(start, end)))
            let upper = min(Float(count), max(0, hasBounds ? upperBound : max(start, end)))
            let lo = min(Float(count - 1), floorf(lower + lower * Float.ulpOfOne))
            let hi = min(Float(count - 1), max(lo, ceilf(upper - upper * Float.ulpOfOne) - 1))
            let pixel = min(hi, max(lo, start + coordinate * span - 0.5))
            let base = floorf(pixel)
            return (Int(base), min(Int(base) + 1, Int(hi)), pixel - base)
        }
        let x = taps(start: i.uv.x, span: i.uv.z, lowerBound: i.border.x, upperBound: i.border.z,
                     count: page.width, at: (p.x - i.rect.x) / i.rect.z)
        let y = taps(start: i.uv.y, span: i.uv.w, lowerBound: i.border.y, upperBound: i.border.w,
                     count: page.height, at: (p.y - i.rect.y) / i.rect.w)
        let pm = i.params.z > 0.5
        let top = mix4(imageTexel(page, x: x.first, y: y.first, premultiplied: pm),
                       imageTexel(page, x: x.last, y: y.first, premultiplied: pm), x.weight)
        let bottom = mix4(imageTexel(page, x: x.first, y: y.last, premultiplied: pm),
                          imageTexel(page, x: x.last, y: y.last, premultiplied: pm), x.weight)
        return mix4(top, bottom, y.weight) * (i.fill.w * clamp01(0.5 - d))
    }
}
