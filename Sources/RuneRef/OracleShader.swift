import Foundation

/// Scalar transcription of upstream `crates/rune-ref/src/shader.rs` matching `OracleScene` / `OracleFrame`.
public enum OracleShader {
    @inline(__always)
    private static func clamp(_ x: Float) -> Float {
        min(max(x, 0.0), 1.0)
    }

    @inline(__always)
    private static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a * (1.0 - t) + b * t
    }

    @inline(__always)
    private static func copySign(_ mag: Float, _ signSource: Float) -> Float {
        let s = signSource.sign == .minus ? -abs(mag) : abs(mag)
        return s
    }

    static func sd(_ p: (Float, Float), _ h: (Float, Float), _ radii: [Float]) -> Float {
        let index: Int
        if p.0 > 0.0 {
            index = p.1 > 0.0 ? 2 : 1
        } else if p.1 > 0.0 {
            index = 3
        } else {
            index = 0
        }
        if radii[index] < 0.0 {
            return sdContinuous(p, h, min(-radii[index], min(h.0, h.1)))
        }
        let r = min(radii[index], min(h.0, h.1))
        let q0 = abs(p.0) - h.0 + r
        let q1 = abs(p.1) - h.1 + r
        let a = max(q0, 0.0)
        let b = max(q1, 0.0)
        return min(max(q0, q1), 0.0) + sqrtf(a * a + b * b) - r
    }

    /// Apple's continuous corner (`sd_continuous` in `shader.rs`).
    private static func sdContinuous(_ p: (Float, Float), _ h: (Float, Float), _ r: Float) -> Float {
        let e: Float = 1.528_664_8 * r
        let q0 = h.0 - abs(p.0)
        let q1 = h.1 - abs(p.1)
        let v0 = e - q0
        let v1 = e - q1
        if v0 <= 0.0 || v1 <= 0.0 {
            return max(-q0, -q1)
        }
        let u = atan2f(v1, v0) * (4.0 / Float.pi) - 1.0
        let u2 = u * u
        let g = 1.146_022_9 + u2 * (-0.375_731_6 + u2 * (0.307_966_1 - 0.077_243_54 * u2))
        return sqrtf(v0 * v0 + v1 * v1) - e * g
    }

    static func ramp(_ d: Float, _ fade: Float) -> Float {
        if fade == 0.0 {
            return clamp(d + 0.5)
        }
        let x = clamp(d / abs(fade))
        return fade < 0.0 ? x : x * x * (3.0 - 2.0 * x)
    }

    private static func erf(_ x: Float) -> Float {
        let s: Float = x > 0.0 ? 1.0 : (x < 0.0 ? -1.0 : 0.0)
        let a = abs(x)
        let r1 = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a
        let r2 = r1 * r1
        return s - s / (r2 * r2)
    }

    private static func shadow(_ p: (Float, Float), _ h: (Float, Float), _ sigma: Float, _ corner: Float) -> Float {
        let lo = p.1 - h.1
        let hi = p.1 + h.1
        let start = min(max(-3.0 * sigma, lo), hi)
        let end = min(max(3.0 * sigma, lo), hi)
        let step = (end - start) / 4.0
        var y = start + step * 0.5
        var v: Float = 0.0
        for _ in 0..<4 {
            let delta = min(h.1 - corner - abs(p.1 - y), 0.0)
            let curved = h.0 - corner + sqrtf(max(corner * corner - delta * delta, 0.0))
            let scale = sqrtf(0.5) / sigma
            let left = 0.5 + 0.5 * erf((p.0 - curved) * scale)
            let right = 0.5 + 0.5 * erf((p.0 + curved) * scale)
            let gaussian = expf(-(y * y) / (2.0 * sigma * sigma)) / (sqrtf(2.0 * Float.pi) * sigma)
            v += (right - left) * gaussian * step
            y += step
        }
        return v
    }

    static func ringArc(_ p: (Float, Float), _ size: (Float, Float), _ radii: [Float], _ bw: Float) -> (Float, Float) {
        let h = bw * 0.5
        let m = min(size.0 * 0.5, size.1 * 0.5)
        let rc = [0, 1, 2, 3].map { max(min(abs(radii[$0]), m) - h, 0.0) }
        let e = rc.map { $0 + h }
        let arc = rc.map { $0 * 1.5707964 }
        let sTr = max(size.0 - bw - rc[0] - rc[1], 0.0)
        let sRight = sTr + arc[1]
        let sBr = sRight + max(size.1 - bw - rc[1] - rc[2], 0.0)
        let sBottom = sBr + arc[2]
        let sBl = sBottom + max(size.0 - bw - rc[2] - rc[3], 0.0)
        let sLeft = sBl + arc[3]
        let sTl = sLeft + max(size.1 - bw - rc[3] - rc[0], 0.0)
        let top = p.0 - e[0]
        let right = sRight + p.1 - e[1]
        let bottom = sBottom + size.0 - e[2] - p.0
        let left = sLeft + size.1 - e[3] - p.1
        let s: Float
        if p.0 > size.0 * 0.5 {
            if p.1 > size.1 * 0.5 {
                let v0 = p.0 - (size.0 - e[2])
                let v1 = p.1 - (size.1 - e[2])
                if v0 > 0.0 && v1 > 0.0 {
                    s = sBr + atan2f(v1, v0) * rc[2]
                } else if size.0 - p.0 < size.1 - p.1 {
                    s = right
                } else {
                    s = bottom
                }
            } else {
                let v0 = p.0 - (size.0 - e[1])
                let v1 = p.1 - e[1]
                if v0 > 0.0 && v1 < 0.0 {
                    s = sTr + atan2f(v0, -v1) * rc[1]
                } else if size.0 - p.0 < p.1 {
                    s = right
                } else {
                    s = top
                }
            }
        } else if p.1 > size.1 * 0.5 {
            let v0 = p.0 - e[3]
            let v1 = p.1 - (size.1 - e[3])
            if v0 < 0.0 && v1 > 0.0 {
                s = sBl + atan2f(-v0, v1) * rc[3]
            } else if p.0 < size.1 - p.1 {
                s = left
            } else {
                s = bottom
            }
        } else {
            let v0 = p.0 - e[0]
            let v1 = p.1 - e[0]
            if v0 < 0.0 && v1 < 0.0 {
                s = sTl + atan2f(-v1, -v0) * rc[0]
            } else if p.0 < p.1 {
                s = left
            } else {
                s = top
            }
        }
        return (s, sTl + arc[0])
    }

    static func dashCov(_ s: Float, _ total: Float, _ d0: Float, _ d1: Float, _ d2: Float) -> Float {
        let nominal = d0 + d1
        let k = max(total, 0.001) / (max(floorf(total / nominal + 0.5), 1.0) * nominal)
        let period = nominal * k
        let dash = d0 * k
        let a = s + d2 * k - dash * 0.5
        let m = a - period * floorf(a / period + 0.5)
        return clamp(dash * 0.5 - abs(m) + 0.5)
    }

    private static func borderOver(
        _ fill: [Float],
        _ edge: [Float],
        _ d: Float,
        _ innerD: Float,
        _ soft: Float,
        _ bw: Float,
        _ opacity: Float,
        _ shrink: Bool
    ) -> (Float, Float, Float, Float) {
        let cov = clamp(0.5 - d / (soft * 2.0))
        let ring = max(cov - clamp(0.5 - innerD / (soft * 2.0)), 0.0)
        let hide = clamp(edge[3] / min(max(opacity, 1e-6), 1.0))
        let pull: Float = (shrink && hide > 0.999) ? bw * 0.5 : 0.0
        let under = clamp(0.5 - (d + pull) / (soft * 2.0))
        let factor = under * (1.0 - hide * ring)
        return (
            edge[0] * ring + fill[0] * factor,
            edge[1] * ring + fill[1] * factor,
            edge[2] * ring + fill[2] * factor,
            edge[3] * ring + fill[3] * factor
        )
    }

    private static func boxCov(_ p: (Float, Float), _ h: (Float, Float), _ radii: [Float]) -> Float {
        let r: Float
        if p.0 > 0.0 {
            r = p.1 > 0.0 ? radii[2] : radii[1]
        } else if p.1 > 0.0 {
            r = radii[3]
        } else {
            r = radii[0]
        }
        if r == 0.0 {
            let ex = clamp(min(h.0, p.0 + 0.5) - max(-h.0, p.0 - 0.5))
            let ey = clamp(min(h.1, p.1 + 0.5) - max(-h.1, p.1 - 0.5))
            return ex * ey
        }
        return clamp(0.5 - sd(p, h, radii))
    }

    public static func fragment(_ i: OraclePrimitive, atlas: OracleAtlas, screen: (Float, Float)) -> (Float, Float, Float, Float) {
        let kind = UInt32(i.params[1])
        // Kind 12 = effect slot no-op
        if kind == 12 {
            return (0, 0, 0, 0)
        }
        let rotated = kind == 2 && i.params[0] != 0.0
        let p: (Float, Float)
        if rotated {
            let s = sinf(i.params[0])
            let c = cosf(i.params[0])
            let cx = i.rect[0] + i.rect[2] * 0.5
            let cy = i.rect[1] + i.rect[3] * 0.5
            let dx = screen.0 - cx
            let dy = screen.1 - cy
            p = (cx + (c * dx + s * dy), cy + (c * dy - s * dx))
        } else {
            p = screen
        }
        let grow: Float = switch kind {
        case 1: i.params[2] * 3.0 + 1.0
        case 2: 0.0
        case 3: 1.0
        default: 1.0 + i.params[2] * 2.0
        }
        if p.0 < i.rect[0] - grow
            || p.1 < i.rect[1] - grow
            || p.0 >= i.rect[0] + i.rect[2] + grow
            || p.1 >= i.rect[1] + i.rect[3] + grow
        {
            return (0, 0, 0, 0)
        }
        let h = (i.rect[2] * 0.5, i.rect[3] * 0.5)
        let q = (p.0 - (i.rect[0] + h.0), p.1 - (i.rect[1] + h.1))
        var col: (Float, Float, Float, Float) = (0, 0, 0, 0)

        switch kind {
        case 0:
            let d = sd(q, h, i.radii)
            let soft = max(i.params[2], 0.5)
            let bw = i.params[0]
            if bw > 0.0 {
                let w = i.uv
                let sides = w[2] >= 0.0 && w != [0, 0, 0, 0]
                let innerD: Float
                if sides {
                    let ih = (max(h.0 - (w[1] + w[3]) * 0.5, 0.0), max(h.1 - (w[0] + w[2]) * 0.5, 0.0))
                    let at = (q.0 - (w[3] - w[1]) * 0.5, q.1 - (w[0] - w[2]) * 0.5)
                    let cut = [max(w[0], w[3]), max(w[0], w[1]), max(w[2], w[1]), max(w[2], w[3])]
                    let innerRadii = (0..<4).map { n in
                        copySign(max(abs(i.radii[n]) - cut[n], 0.0), i.radii[n])
                    }
                    innerD = sd(at, ih, innerRadii)
                } else {
                    innerD = d + bw
                }
                col = borderOver(i.fill, i.border, d, innerD, soft, bw, i.params[3], !sides && i.radii != [0, 0, 0, 0])
            } else {
                let cov = clamp(0.5 - d / (soft * 2.0))
                col = (i.fill[0] * cov, i.fill[1] * cov, i.fill[2] * cov, i.fill[3] * cov)
            }

        case 1:
            var cov = shadow(q, h, max(i.params[2], 0.01), min(abs(i.radii[0]), min(h.0, h.1)))
            if i.uv[2] > 0.0 {
                let hole = (i.uv[2] * 0.5, i.uv[3] * 0.5)
                let at = (p.0 - (i.rect[0] + i.uv[0] + hole.0), p.1 - (i.rect[1] + i.uv[1] + hole.1))
                cov *= clamp(0.5 + sd(at, hole, [i.radii[3], i.radii[3], i.radii[3], i.radii[3]]))
            }
            col = (i.fill[0] * cov, i.fill[1] * cov, i.fill[2] * cov, i.fill[3] * cov)

        case 2:
            let cov: Float
            if i.uv[2] > 0.0 || rotated {
                let span = i.uv[2] > 0.0 ? (i.uv[2], i.uv[3]) : (i.rect[2], i.rect[3])
                let px = (p.0 - i.rect[0]) * span.0 / i.rect[2] - 0.5
                let py = (p.1 - i.rect[1]) * span.1 / i.rect[3] - 0.5
                let x = Int32(i.uv[0] + floorf(px))
                let y = Int32(i.uv[1] + floorf(py))
                let fx = px - floorf(px)
                let fy = py - floorf(py)
                cov = mix(
                    mix(atlas.load(x, y), atlas.load(x + 1, y), fx),
                    mix(atlas.load(x, y + 1), atlas.load(x + 1, y + 1), fx),
                    fy
                )
            } else {
                cov = atlas.load(
                    Int32(i.uv[0] + floorf(p.0 - i.rect[0])),
                    Int32(i.uv[1] + floorf(p.1 - i.rect[1]))
                )
            }
            let pcov = powf(cov, i.params[3])
            col = (i.fill[0] * pcov, i.fill[1] * pcov, i.fill[2] * pcov, i.fill[3] * pcov)

        case 3:
            let cov = boxCov(q, h, i.radii)
            let spread = i.params[0]
            let ih = (max(h.0 - spread, 0.0), max(h.1 - spread, 0.0))
            let iq = (q.0 - i.uv[0], q.1 - i.uv[1])
            let lit: Float
            if i.params[2] < 0.3 {
                let innerRadii = i.radii.map { copySign(max(abs($0) - spread, 0.0), $0) }
                lit = boxCov(iq, ih, innerRadii)
            } else {
                lit = shadow(iq, ih, i.params[2], max(min(abs(i.radii[0]) - spread, min(ih.0, ih.1)), 0.0))
            }
            let factor = cov * (1.0 - clamp(lit))
            col = (i.fill[0] * factor, i.fill[1] * factor, i.fill[2] * factor, i.fill[3] * factor)

        case 4:
            let d = sd(q, h, i.radii)
            let soft = max(i.params[2], 0.5)
            let bw = i.params[0]
            let t = clamp((p.1 - i.rect[1]) / max(i.rect[3], 1.0))
            if bw > 0.0 {
                let edge = [
                    mix(i.border[0], i.uv[0], t),
                    mix(i.border[1], i.uv[1], t),
                    mix(i.border[2], i.uv[2], t),
                    mix(i.border[3], i.uv[3], t),
                ]
                col = borderOver(i.fill, edge, d, d + bw, soft, bw, i.params[3], i.radii != [0, 0, 0, 0])
            } else {
                let cov = clamp(0.5 - d / (soft * 2.0))
                col = (
                    mix(i.fill[0], i.uv[0], t) * cov,
                    mix(i.fill[1], i.uv[1], t) * cov,
                    mix(i.fill[2], i.uv[2], t) * cov,
                    mix(i.fill[3], i.uv[3], t) * cov
                )
            }

        case 10:
            let d = sd(q, h, i.radii)
            let soft = max(i.params[2], 0.5)
            let ring = clamp(0.5 - d / (soft * 2.0)) - clamp(0.5 - (d + i.params[0]) / (soft * 2.0))
            let t = clamp((p.1 - i.rect[1]) / max(i.rect[3], 1.0))
            let local = (p.0 - i.rect[0], p.1 - i.rect[1])
            let (s, total) = ringArc(local, (i.rect[2], i.rect[3]), i.radii, i.params[0])
            let cov = ring * dashCov(s, total, i.uv[0], i.uv[1], i.uv[2])
            col = (
                mix(i.fill[0], i.border[0], t) * cov,
                mix(i.fill[1], i.border[1], t) * cov,
                mix(i.fill[2], i.border[2], t) * cov,
                mix(i.fill[3], i.border[3], t) * cov
            )

        case 11:
            let d = sd(q, h, i.radii)
            let soft = max(i.params[2], 0.5)
            let cov = clamp(0.5 - d / (soft * 2.0))
            let t0Raw = i.params[0]
            let t1Raw = i.params[3]
            let lowerOpen = t0Raw >= 1.5
            let upperOpen = t1Raw >= 1.5
            let t0 = lowerOpen ? t0Raw - 2.0 : t0Raw
            let t1 = upperOpen ? t1Raw - 2.0 : t1Raw
            let t: Float
            if i.uv[2] > 0.0 {
                let dx = (p.0 - i.rect[0] - i.uv[0]) / i.uv[2]
                let dy = (p.1 - i.rect[1] - i.uv[1]) / i.uv[3]
                t = sqrtf(dx * dx + dy * dy)
            } else {
                t = 0.5 + (q.0 * i.uv[0] + q.1 * i.uv[1])
            }
            if !((lowerOpen && t < t0) || (upperOpen && t >= t1)) {
                let u: Float
                if t1 <= t0 + 1e-6 {
                    u = t >= t0 ? 1.0 : 0.0
                } else {
                    u = clamp((t - t0) / (t1 - t0))
                }
                col = (
                    mix(i.fill[0], i.border[0], u) * cov,
                    mix(i.fill[1], i.border[1], u) * cov,
                    mix(i.fill[2], i.border[2], u) * cov,
                    mix(i.fill[3], i.border[3], u) * cov
                )
            }

        default:
            fatalError("unsupported primitive kind \(kind)")
        }

        let clip = clipCoverage(i, screen: screen)
        return (col.0 * clip, col.1 * clip, col.2 * clip, col.3 * clip)
    }

    public static func layerClipCoverage(_ i: OraclePrimitive, screen: (Float, Float)) -> Float {
        clipCoverage(i, screen: screen) * (i.params[3] == 0.0 ? holeAlpha(screen, i.radii) : 1.0)
    }

    private static func holeAlpha(_ p: (Float, Float), _ h: [Float]) -> Float {
        if h[3] <= 0.0 { return 1.0 }
        let dx = p.0 - h[0]
        let dy = p.1 - h[1]
        return clamp((sqrtf(dx * dx + dy * dy) - (h[2] + h[3]) * 0.5) / max(h[3] - h[2], 1.0) + 0.5)
    }

    public static func clipCoverage(_ i: OraclePrimitive, screen: (Float, Float)) -> Float {
        let origin = i.fadeOrigin ?? i.clip
        let hard = [
            screen.0 - i.clip[0],
            screen.1 - i.clip[1],
            i.clip[2] - screen.0,
            i.clip[3] - screen.1,
        ]
        var alpha: Float = 1.0
        for edge in 0..<4 {
            let f = min(max(i.fade[edge], -65504.0), 65504.0)
            let width = OraclePrimitive.float16BitsTo32(OraclePrimitive.float32To16Bits(f))
            let distance = edge < 2 ? (i.clip[edge] - origin[edge]) : (origin[edge] - i.clip[edge])
            let w = abs(i.fade[edge])
            let rawOffset = w > 0.0 ? clamp(distance / w) : 0.0
            let offset = floorf(rawOffset * 255.0 + 0.5) / 255.0
            let edgeCov: Float
            if offset >= 1.0 {
                edgeCov = ramp(hard[edge], 0.0)
            } else if offset > 0.0 {
                edgeCov = min(ramp(hard[edge], 0.0), ramp(hard[edge] + offset * abs(width), width))
            } else {
                edgeCov = ramp(hard[edge], width)
            }
            alpha *= edgeCov
        }
        let radii = i.params[1] == 8.0 ? (i.clipRadii ?? i.border) : (i.clipRadii ?? [0, 0, 0, 0])
        if radii != [0, 0, 0, 0] {
            let half = ((i.clip[2] - i.clip[0]) * 0.5, (i.clip[3] - i.clip[1]) * 0.5)
            let q = (screen.0 - i.clip[0] - half.0, screen.1 - i.clip[1] - half.1)
            alpha *= clamp(0.5 - sd(q, half, radii))
        }
        return alpha
    }
}
