import Foundation
#if canImport(simd)
import simd
#else
@inline(__always)
private func simd_length(_ v: SIMD2<Float>) -> Float {
    (v.x * v.x + v.y * v.y).squareRoot()
}

@inline(__always)
private func simd_length(_ v: SIMD3<Float>) -> Float {
    (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
}

@inline(__always)
private func simd_normalize(_ v: SIMD3<Float>) -> SIMD3<Float> {
    let len = simd_length(v)
    return len > 0 ? v / len : .zero
}

@inline(__always)
private func simd_cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3<Float>(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x
    )
}
#endif

public enum RuneLightCPU: Sendable {
    public static func sdRoundedRect(_ p: SIMD2<Float>, half: SIMD2<Float>, radii: SIMD4<Float>) -> Float {
        var r: Float
        if p.x > 0.0 {
            r = p.y > 0.0 ? radii.z : radii.y
        } else {
            r = p.y > 0.0 ? radii.w : radii.x
        }
        r = min(r, min(half.x, half.y))
        let q = SIMD2<Float>(abs(p.x) - half.x + r, abs(p.y) - half.y + r)
        return min(max(q.x, q.y), 0.0) + hypotf(max(q.x, 0.0), max(q.y, 0.0)) - r
    }

    public static func primSD(_ pr: Prim, at p: SIMD2<Float>) -> Float {
        let half = SIMD2<Float>(pr.rect.z * 0.5, pr.rect.w * 0.5)
        let center = SIMD2<Float>(pr.rect.x + half.x, pr.rect.y + half.y)
        return sdRoundedRect(p - center, half: half, radii: pr.radii)
    }

    public static func field(prims: [Prim], at p: SIMD2<Float>) -> SIMD3<Float> {
        var best = SIMD3<Float>(1e4, 0.0, 0.0)
        for pr in prims where (pr.flags & flagOccluder) != 0 {
            let d = primSD(pr, at: p)
            if d < best.x {
                best = SIMD3<Float>(d, pr.z.x, pr.z.y)
            }
        }
        return best
    }

    public static func slab(_ f: SIMD3<Float>, z: Float) -> Float {
        let dz = max(z - f.z, f.y - z)
        let a = SIMD2<Float>(f.x, dz)
        return hypotf(max(a.x, 0.0), max(a.y, 0.0)) + min(max(a.x, a.y), 0.0)
    }

    public static func sceneSD(prims: [Prim], at q: SIMD3<Float>) -> Float {
        var best: Float = 1e4
        for pr in prims where (pr.flags & flagOccluder) != 0 {
            let d2 = primSD(pr, at: SIMD2<Float>(q.x, q.y))
            best = min(best, slab(SIMD3<Float>(d2, pr.z.x, pr.z.y), z: q.z))
        }
        return best
    }

    private static func smooth(_ res: Float) -> Float {
        let k = min(max(0.5 + 0.5 * res, 0.0), 1.0)
        return k * k * (3.0 - 2.0 * k)
    }

    public static func estimate(prims: [Prim], light: Light, at p: SIMD3<Float>) -> Float {
        let l = SIMD3<Float>(light.pos.x, light.pos.y, light.pos.z)
        let radius = light.pos.w * light.extra.w
        let d = l - p
        let dist = simd_length(d)
        let rd = d / max(dist, 1e-6)
        let theta = max(radius / max(dist, 1e-6), 1e-3)
        let zmax = prims
            .filter { ($0.flags & flagOccluder) != 0 }
            .reduce(Float(0.0)) { max($0, $1.z.y) } + 0.5

        var t: Float = 0.75
        var res: Float = 1.0
        var ph: Float = 1e10

        for _ in 0..<64 {
            if t >= dist - radius { break }
            let q = p + rd * t
            if rd.z >= 0.0 && q.z > zmax { break }
            let h = slab(field(prims: prims, at: SIMD2<Float>(q.x, q.y)), z: q.z)
            if h <= 0.0 {
                res = min(res, h / (t * theta))
            } else {
                let y = h * h / (2.0 * ph)
                let dd = sqrtf(max(h * h - y * y, 0.0))
                res = min(res, dd / (max(t - y, 1e-3) * theta))
            }
            ph = max(h, 1e-3)
            if res <= -1.0 { break }
            t += min(max(abs(h), 0.6 + t * 0.012), 96.0)
        }
        return smooth(res)
    }

    private static func blocked(prims: [Prim], from p: SIMD3<Float>, to target: SIMD3<Float>) -> Bool {
        let d = target - p
        let dist = simd_length(d)
        let rd = d / max(dist, 1e-6)
        var t: Float = 0.05
        while t < dist {
            let q = p + rd * t
            let h = sceneSD(prims: prims, at: q)
            if h < 0.01 { return true }
            t += max(h, 0.02)
        }
        return false
    }

    public static func groundTruth(prims: [Prim], light: Light, at p: SIMD3<Float>, samples n: UInt32) -> Float {
        let c = SIMD3<Float>(light.pos.x, light.pos.y, light.pos.z)
        let r = light.pos.w * light.extra.w
        let w = simd_normalize(c - p)
        let up = abs(w.z) < 0.9 ? SIMD3<Float>(0.0, 0.0, 1.0) : SIMD3<Float>(1.0, 0.0, 0.0)
        let u = simd_normalize(simd_cross(w, up))
        let v = simd_cross(w, u)
        var lit: UInt32 = 0
        var total: UInt32 = 0
        for i in 0..<n {
            for j in 0..<n {
                let ax = (Float(i) + 0.5) / Float(n) * 2.0 - 1.0
                let ay = (Float(j) + 0.5) / Float(n) * 2.0 - 1.0
                if ax * ax + ay * ay > 1.0 { continue }
                total += 1
                let tgt = c + (u * ax + v * ay) * r
                if !blocked(prims: prims, from: p, to: tgt) {
                    lit += 1
                }
            }
        }
        return Float(lit) / Float(max(total, 1))
    }
}
