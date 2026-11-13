import Foundation
#if canImport(simd)
import simd
#else
@inline(__always)
private func simd_abs(_ v: SIMD2<Float>) -> SIMD2<Float> {
    SIMD2<Float>(abs(v.x), abs(v.y))
}

@inline(__always)
private func simd_max(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> {
    SIMD2<Float>(max(a.x, b.x), max(a.y, b.y))
}

@inline(__always)
private func simd_dot(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
    a.x * b.x + a.y * b.y
}

@inline(__always)
private func simd_length_squared(_ v: SIMD2<Float>) -> Float {
    v.x * v.x + v.y * v.y
}

@inline(__always)
private func simd_length(_ v: SIMD2<Float>) -> Float {
    (v.x * v.x + v.y * v.y).squareRoot()
}
#endif

/// Pure scalar CPU implementation of Rune's instanced uber-shader (`shader.wgsl`).
/// Every helper is deterministic and free of GPU driver heuristics.
public enum RefShader {
    @inlinable
    public static func clamp01(_ x: Float) -> Float {
        min(max(x, 0.0), 1.0)
    }

    @inlinable
    public static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let span = e1 - e0
        if abs(span) < 1e-6 { return x >= e1 ? 1.0 : 0.0 }
        let t = clamp01((x - e0) / span)
        return t * t * (3.0 - 2.0 * t)
    }

    @inlinable
    public static func linearToSRGB(_ c: Float) -> Float {
        let x = clamp01(c)
        if x <= 0.0031308 {
            return x * 12.92
        }
        return 1.055 * powf(x, 1.0 / 2.4) - 0.055
    }

    @inlinable
    public static func srgbToLinear(_ c: Float) -> Float {
        let x = clamp01(c)
        if x <= 0.04045 {
            return x / 12.92
        }
        return powf((x + 0.055) / 1.055, 2.4)
    }

    /// Selects the active corner radius `[tl, tr, br, bl]` for `p` relative to quad center.
    @inlinable
    public static func pickCornerRadius(_ p: SIMD2<Float>, _ radii: SIMD4<Float>) -> Float {
        if p.x < 0 {
            return p.y < 0 ? radii.x : radii.w
        } else {
            return p.y < 0 ? radii.y : radii.z
        }
    }

    /// Signed distance to a rounded rectangle with circular (`r >= 0`) or Apple continuous squircle (`r < 0`) corners.
    @inlinable
    public static func sdBox(_ p: SIMD2<Float>, halfSize b: SIMD2<Float>, radii: SIMD4<Float>) -> Float {
        let rawR = pickCornerRadius(p, radii)
        let maxR = max(0, min(b.x, b.y))
        if rawR >= 0 {
            let r = min(rawR, maxR)
            let q = simd_abs(p) - b + SIMD2<Float>(repeating: r)
            return simd_length(simd_max(q, .zero)) + min(max(q.x, q.y), 0.0) - r
        } else {
            // Apple continuous corner (superellipse / polynomial throat)
            let r = min(-rawR, maxR)
            if r <= 1e-4 {
                let q = simd_abs(p) - b
                return simd_length(simd_max(q, .zero)) + min(max(q.x, q.y), 0.0)
            }
            let q = simd_abs(p) - b + SIMD2<Float>(repeating: r)
            let std = simd_length(simd_max(q, .zero)) + min(max(q.x, q.y), 0.0) - r
            // Continuous superellipse refinement inside corner region
            let u = simd_max(simd_abs(p) - (b - SIMD2<Float>(repeating: r * 1.528665)), .zero) / (r * 1.528665)
            if u.x > 0 && u.y > 0 {
                // p=2.5 superellipse blend gives smooth G2 curvature matching CALayer continuous corners
                let se = (powf(powf(u.x, 2.4) + powf(u.y, 2.4), 1.0 / 2.4) - 1.0) * (r * 0.85)
                let w = clamp01(min(u.x, u.y) * 2.0)
                return std * (1.0 - w * 0.35) + se * (w * 0.35)
            }
            return std
        }
    }

    @inlinable
    public static func boxCoverage(_ sd: Float) -> Float {
        clamp01(0.5 - sd)
    }

    /// Composite straight-alpha `fill` and `border` over each other with bleed-avoidant fill pull-in.
    /// Returns premultiplied RGBA `[r*a, g*a, b*a, a]`.
    @inlinable
    public static func borderOver(
        fill: SIMD4<Float>,
        border: SIMD4<Float>,
        dOuter: Float,
        dInner: Float
    ) -> SIMD4<Float> {
        let outerCov = boxCoverage(dOuter)
        if outerCov <= 0 { return .zero }
        if border.w <= 0.0001 {
            let a = fill.w * outerCov
            return SIMD4<Float>(fill.x * a, fill.y * a, fill.z * a, a)
        }
        let innerCov = boxCoverage(dInner)
        // Pull fill edge inward when border is opaque so fill never bleeds around thin 1px borders.
        let fillCov: Float
        if border.w >= 0.999 {
            fillCov = boxCoverage((dOuter + dInner) * 0.5)
        } else {
            fillCov = outerCov
        }
        let borderMask = max(0.0, outerCov - innerCov)
        let ba = border.w * borderMask
        let fa = fill.w * fillCov
        let invBa = 1.0 - ba
        let outRGB = SIMD3<Float>(border.x, border.y, border.z) * ba
            + SIMD3<Float>(fill.x, fill.y, fill.z) * (fa * invBa)
        let outA = ba + fa * invBa
        return SIMD4<Float>(outRGB.x, outRGB.y, outRGB.z, outA)
    }

    /// Abramowitz-Stegun / Evan Wallace fast error function approximation (`max error < 1.5e-3`).
    @inlinable
    public static func erfApprox(_ x: Float) -> Float {
        let s: Float = x < 0 ? -1.0 : 1.0
        let ax = abs(x)
        let t = 1.0 / (1.0 + 0.3275911 * ax)
        let y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * expf(-ax * ax)
        return s * y
    }

    /// Analytic 2D Gaussian rounded-rect shadow coverage (Evan Wallace method).
    public static func gaussianShadowCoverage(
        p: SIMD2<Float>,
        halfSize: SIMD2<Float>,
        radius: Float,
        blur: Float
    ) -> Float {
        let sigma = max(blur * 0.5, 0.25)
        if blur <= 0.5 {
            let sd = sdBox(p, halfSize: halfSize, radii: SIMD4<Float>(repeating: radius))
            return boxCoverage(sd)
        }
        let r = min(max(0, radius), min(halfSize.x, halfSize.y))
        let invSqrt2Sigma = 1.0 / (1.41421356 * sigma)

        // 4-point midpoint quadrature across [-3*sigma, +3*sigma] along Y
        let low = max(-halfSize.y, p.y - 3.0 * sigma)
        let high = min(halfSize.y, p.y + 3.0 * sigma)
        if low >= high { return 0.0 }

        let step = (high - low) * 0.25
        var integral: Float = 0.0
        for i in 0..<4 {
            let y = low + (Float(i) + 0.5) * step
            let cy = max(0.0, abs(y) - (halfSize.y - r))
            let xHalf = (halfSize.x - r) + sqrtf(max(0.0, r * r - cy * cy))
            let x0 = (p.x - xHalf) * invSqrt2Sigma
            let x1 = (p.x + xHalf) * invSqrt2Sigma
            let xInt = 0.5 * (erfApprox(x1) - erfApprox(x0))
            let dy = (y - p.y) / sigma
            let weight = 0.3989422804 * expf(-0.5 * dy * dy) / sigma
            integral += xInt * weight * step
        }
        return clamp01(integral)
    }

    /// Analytic capsule or butt-capped line segment coverage with sub-pixel stroke weighting.
    @inlinable
    public static func segmentCoverage(
        p: SIMD2<Float>,
        a: SIMD2<Float>,
        b: SIMD2<Float>,
        width: Float,
        roundCap: Bool
    ) -> Float {
        let ab = b - a
        let len2 = simd_length_squared(ab)
        let effectiveW = max(width, 1.0)
        let weight = min(max(width, 0.0), 1.0)
        let halfW = effectiveW * 0.5

        if len2 < 1e-6 {
            let d = simd_length(p - a) - halfW
            return clamp01(0.5 - d) * weight
        }
        if roundCap {
            let t = clamp01(simd_dot(p - a, ab) / len2)
            let proj = a + ab * t
            let d = simd_length(p - proj) - halfW
            return clamp01(0.5 - d) * weight
        } else {
            let len = sqrtf(len2)
            let dir = ab / len
            let n = SIMD2<Float>(-dir.y, dir.x)
            let rel = p - (a + b) * 0.5
            let along = abs(simd_dot(rel, dir)) - len * 0.5
            let perp = abs(simd_dot(rel, n)) - halfW
            let q = SIMD2<Float>(along, perp)
            let d = simd_length(simd_max(q, .zero)) + min(max(q.x, q.y), 0.0)
            return clamp01(0.5 - d) * weight
        }
    }

    /// Analytic polygon triangle coverage: outer boundary edges (`aaMask & (1 << i) != 0`) get
    /// smooth SDF antialiasing, while interior shared edges use a half-open top-left ownership rule
    /// so adjacent triangles have zero seams and zero double-blending.
    @inlinable
    public static func triangleCoverage(
        p: SIMD2<Float>,
        v0: SIMD2<Float>,
        v1: SIMD2<Float>,
        v2: SIMD2<Float>,
        aaMask: Int
    ) -> Float {
        let area2 = (v1.x - v0.x) * (v2.y - v0.y) - (v1.y - v0.y) * (v2.x - v0.x)
        if abs(area2) < 1e-5 { return 0.0 }
        // Orient CCW (positive area in screen coords means clockwise, normalize sign)
        let sign: Float = area2 > 0 ? 1.0 : -1.0
        let verts = [v0, v1, v2]
        var cov: Float = 1.0

        for i in 0..<3 {
            let a = verts[i]
            let b = verts[(i + 1) % 3]
            let e = b - a
            let len = simd_length(e)
            if len < 1e-5 { return 0.0 }
            // Signed distance (> 0 outside, < 0 inside)
            let cross = ((p.x - a.x) * e.y - (p.y - a.y) * e.x) * sign
            let d = cross / len
            if (aaMask & (1 << i)) != 0 {
                cov = min(cov, clamp01(0.5 - d))
                if cov <= 0 { return 0.0 }
            } else {
                // Half-open ownership rule on shared interior diagonal
                let orientE = e * sign
                let ownsTie = (orientE.y > 0) || (orientE.y == 0 && orientE.x < 0)
                if d > 0 || (d == 0 && !ownsTie) {
                    return 0.0
                }
            }
        }
        return cov
    }

    /// Computes arc length along a rounded-rect perimeter for seamless dashed rings.
    public static func ringArcLength(p: SIMD2<Float>, halfSize b: SIMD2<Float>, r: Float) -> Float {
        let cr = min(max(0, r), min(b.x, b.y))
        let sx = max(0, b.x - cr)
        let sy = max(0, b.y - cr)
        let topLen = 2.0 * sx
        let sideLen = 2.0 * sy
        let cornerLen = 0.5 * .pi * cr

        // Walk clockwise starting from top-left straight start (-sx, -b.y)
        if p.y <= -sy && abs(p.x) <= sx {
            return p.x + sx
        } else if p.x > sx && p.y < -sy {
            let ang = atan2f(p.x - sx, -(p.y + sy)) // 0 at top, pi/2 at right
            return topLen + clamp01(ang / (0.5 * .pi)) * cornerLen
        } else if p.x >= sx && abs(p.y) <= sy {
            return topLen + cornerLen + (p.y + sy)
        } else if p.x > sx && p.y > sy {
            let ang = atan2f(p.y - sy, p.x - sx)
            return topLen + cornerLen + sideLen + clamp01(ang / (0.5 * .pi)) * cornerLen
        } else if p.y >= sy && abs(p.x) <= sx {
            return topLen + 2.0 * cornerLen + sideLen + (sx - p.x)
        } else if p.x < -sx && p.y > sy {
            let ang = atan2f(-(p.x + sx), p.y - sy)
            return 2.0 * topLen + 2.0 * cornerLen + sideLen + clamp01(ang / (0.5 * .pi)) * cornerLen
        } else if p.x <= -sx && abs(p.y) <= sy {
            return 2.0 * topLen + 3.0 * cornerLen + sideLen + (sy - p.y)
        } else {
            let ang = atan2f(-(p.y + sy), -(p.x + sx))
            return 2.0 * topLen + 3.0 * cornerLen + 2.0 * sideLen + clamp01(ang / (0.5 * .pi)) * cornerLen
        }
    }

    @inlinable
    public static func dashCoverage(arc: Float, dash: Float, gap: Float, phase: Float) -> Float {
        let period = max(dash + gap, 1.0)
        var pos = (arc + phase).truncatingRemainder(dividingBy: period)
        if pos < 0 { pos += period }
        let enter = clamp01(pos + 0.5)
        let exit = clamp01(dash - pos + 0.5)
        let wrapEnter = clamp01(pos - period + dash + 0.5)
        return max(min(enter, exit), wrapEnter)
    }

    @inlinable
    public static func clipCoverage(pixelCenter p: SIMD2<Float>, clip: SIMD4<Float>) -> Float {
        if clip.z <= 0 || clip.w <= 0 { return 0.0 }
        // Pixel-aligned clips are exact; sub-pixel clips antialias smoothly.
        let ix = clamp01(min(p.x - clip.x + 0.5, (clip.x + clip.z) - p.x + 0.5))
        let iy = clamp01(min(p.y - clip.y + 0.5, (clip.y + clip.w) - p.y + 0.5))
        return ix * iy
    }

    /// Clamped bilinear sample of an `R8Atlas` at UV `[0, 1]`.
    public static func sampleR8(_ atlas: R8Atlas, u: Float, v: Float) -> Float {
        let fx = clamp01(u) * Float(atlas.width) - 0.5
        let fy = clamp01(v) * Float(atlas.height) - 0.5
        let x0 = Int(floorf(fx))
        let y0 = Int(floorf(fy))
        let tx = fx - Float(x0)
        let ty = fy - Float(y0)

        func fetch(_ x: Int, _ y: Int) -> Float {
            let cx = min(max(x, 0), atlas.width - 1)
            let cy = min(max(y, 0), atlas.height - 1)
            return Float(atlas.texels[cy * atlas.width + cx]) / 255.0
        }

        let c00 = fetch(x0, y0)
        let c10 = fetch(x0 + 1, y0)
        let c01 = fetch(x0, y0 + 1)
        let c11 = fetch(x0 + 1, y0 + 1)
        let top = c00 + (c10 - c00) * tx
        let bot = c01 + (c11 - c01) * tx
        return top + (bot - top) * ty
    }

    /// Clamped bilinear sample of an `RGBA8Atlas` at UV `[0, 1]`, converting texels to linear light when `!srgbBlend`.
    public static func sampleRGBA8(_ atlas: RGBA8Atlas, u: Float, v: Float, srgbBlend: Bool) -> SIMD4<Float> {
        let fx = clamp01(u) * Float(atlas.width) - 0.5
        let fy = clamp01(v) * Float(atlas.height) - 0.5
        let x0 = Int(floorf(fx))
        let y0 = Int(floorf(fy))
        let tx = fx - Float(x0)
        let ty = fy - Float(y0)

        func fetch(_ x: Int, _ y: Int) -> SIMD4<Float> {
            let cx = min(max(x, 0), atlas.width - 1)
            let cy = min(max(y, 0), atlas.height - 1)
            let idx = (cy * atlas.width + cx) * 4
            let r = Float(atlas.texels[idx]) / 255.0
            let g = Float(atlas.texels[idx + 1]) / 255.0
            let b = Float(atlas.texels[idx + 2]) / 255.0
            let a = Float(atlas.texels[idx + 3]) / 255.0
            if srgbBlend {
                return SIMD4<Float>(r, g, b, a)
            } else {
                return SIMD4<Float>(srgbToLinear(r), srgbToLinear(g), srgbToLinear(b), a)
            }
        }

        let c00 = fetch(x0, y0)
        let c10 = fetch(x0 + 1, y0)
        let c01 = fetch(x0, y0 + 1)
        let c11 = fetch(x0 + 1, y0 + 1)
        let top = c00 + (c10 - c00) * tx
        let bot = c01 + (c11 - c01) * tx
        return top + (bot - top) * ty
    }

    /// Evaluates a single `Primitive` at pixel center `fragCoord = (px + 0.5, py + 0.5)` and returns
    /// **premultiplied** RGBA `[r*a, g*a, b*a, a]`.
    public static func evaluatePrimitive(
        _ prim: Primitive,
        fragCoord: SIMD2<Float>,
        glyphs: R8Atlas,
        images: RGBA8Atlas,
        srgbBlend: Bool
    ) -> SIMD4<Float> {
        let clipCov = clipCoverage(pixelCenter: fragCoord, clip: prim.clip)
        if clipCov <= 0 { return .zero }

        let center = SIMD2<Float>(prim.rect.x + prim.rect.z * 0.5, prim.rect.y + prim.rect.w * 0.5)
        let halfSize = SIMD2<Float>(prim.rect.z * 0.5, prim.rect.w * 0.5)
        var localP = fragCoord - center
        if prim.turn != 0 {
            let cs = cosf(-prim.turn)
            let sn = sinf(-prim.turn)
            localP = SIMD2<Float>(localP.x * cs - localP.y * sn, localP.x * sn + localP.y * cs)
        }

        var fadeCov = clipCov
        if prim.fade.z != 0 {
            let d = simd_dot(fragCoord - prim.fadeOrigin, SIMD2<Float>(prim.fade.x, prim.fade.y)) * prim.fade.z
            let mask = prim.fade.w + (1.0 - prim.fade.w) * clamp01(d)
            fadeCov *= mask
            if fadeCov <= 0 { return .zero }
        }

        let outPremul: SIMD4<Float>
        switch prim.kind {
        case .roundedRect:
            let dOuter = sdBox(localP, halfSize: halfSize, radii: prim.radii)
            if dOuter >= 0.5 { return .zero }
            let dInner: Float
            if prim.params.x < 0 {
                // Per-side border widths in uv = [top, right, bottom, left]
                let sides = prim.uv
                let innerCenterShift = SIMD2<Float>((sides.w - sides.y) * 0.5, (sides.x - sides.z) * 0.5)
                let innerHalf = SIMD2<Float>(
                    max(0, halfSize.x - (sides.w + sides.y) * 0.5),
                    max(0, halfSize.y - (sides.x + sides.z) * 0.5)
                )
                let avgSide = SIMD4<Float>(
                    (sides.x + sides.w) * 0.5,
                    (sides.x + sides.y) * 0.5,
                    (sides.z + sides.y) * 0.5,
                    (sides.z + sides.w) * 0.5
                )
                let innerRadii = SIMD4<Float>(
                    prim.radii.x >= 0 ? max(0, prim.radii.x - avgSide.x) : min(0, prim.radii.x + avgSide.x),
                    prim.radii.y >= 0 ? max(0, prim.radii.y - avgSide.y) : min(0, prim.radii.y + avgSide.y),
                    prim.radii.z >= 0 ? max(0, prim.radii.z - avgSide.z) : min(0, prim.radii.z + avgSide.z),
                    prim.radii.w >= 0 ? max(0, prim.radii.w - avgSide.w) : min(0, prim.radii.w + avgSide.w)
                )
                dInner = sdBox(localP - innerCenterShift, halfSize: innerHalf, radii: innerRadii)
            } else if prim.params.x > 0 {
                let bw = prim.params.x
                let innerHalf = SIMD2<Float>(max(0, halfSize.x - bw), max(0, halfSize.y - bw))
                let innerRadii = SIMD4<Float>(
                    prim.radii.x >= 0 ? max(0, prim.radii.x - bw) : min(0, prim.radii.x + bw),
                    prim.radii.y >= 0 ? max(0, prim.radii.y - bw) : min(0, prim.radii.y + bw),
                    prim.radii.z >= 0 ? max(0, prim.radii.z - bw) : min(0, prim.radii.z + bw),
                    prim.radii.w >= 0 ? max(0, prim.radii.w - bw) : min(0, prim.radii.w + bw)
                )
                dInner = sdBox(localP, halfSize: innerHalf, radii: innerRadii)
            } else {
                dInner = dOuter - 10.0
            }
            outPremul = borderOver(fill: prim.fill, border: prim.border, dOuter: dOuter, dInner: dInner)

        case .dropShadow:
            // prim.border holds original casting box [bx, by, bw, bh], prim.uv.xy = offset, params.x = blur, params.z = spread
            let boxRect = (prim.border.z > 0 && prim.border.w > 0) ? prim.border : prim.rect
            let offset = SIMD2<Float>(prim.uv.x, prim.uv.y)
            let spread = prim.params.z
            let shadowCenter = SIMD2<Float>(boxRect.x + boxRect.z * 0.5, boxRect.y + boxRect.w * 0.5) + offset
            let shadowHalf = SIMD2<Float>(max(0, boxRect.z * 0.5 + spread), max(0, boxRect.w * 0.5 + spread))
            let r = abs(pickCornerRadius(fragCoord - shadowCenter, prim.radii)) + spread
            var cov = gaussianShadowCoverage(p: fragCoord - shadowCenter, halfSize: shadowHalf, radius: max(0, r), blur: prim.params.x)
            if prim.params.w > 0.5 {
                // Cut out caster interior
                let casterCenter = SIMD2<Float>(boxRect.x + boxRect.z * 0.5, boxRect.y + boxRect.w * 0.5)
                let casterHalf = SIMD2<Float>(boxRect.z * 0.5, boxRect.w * 0.5)
                let casterSD = sdBox(fragCoord - casterCenter, halfSize: casterHalf, radii: prim.radii)
                cov *= (1.0 - boxCoverage(casterSD))
            }
            let a = prim.fill.w * cov
            outPremul = SIMD4<Float>(prim.fill.x * a, prim.fill.y * a, prim.fill.z * a, a)

        case .insetShadow:
            let dOuter = sdBox(localP, halfSize: halfSize, radii: prim.radii)
            let outerCov = boxCoverage(dOuter)
            if outerCov <= 0 { return .zero }
            let spread = prim.params.z
            let offset = SIMD2<Float>(prim.uv.x, prim.uv.y)
            let innerHalf = SIMD2<Float>(max(0, halfSize.x - spread), max(0, halfSize.y - spread))
            let r = max(0, abs(pickCornerRadius(localP - offset, prim.radii)) - spread)
            let lit = gaussianShadowCoverage(p: localP - offset, halfSize: innerHalf, radius: r, blur: prim.params.x)
            let cov = outerCov * clamp01(1.0 - lit)
            let a = prim.fill.w * cov
            outPremul = SIMD4<Float>(prim.fill.x * a, prim.fill.y * a, prim.fill.z * a, a)

        case .glyph:
            if abs(localP.x) > halfSize.x + 0.5 || abs(localP.y) > halfSize.y + 0.5 { return .zero }
            let uNorm = (localP.x + halfSize.x) / max(prim.rect.z, 1e-4)
            let vNorm = (localP.y + halfSize.y) / max(prim.rect.w, 1e-4)
            if uNorm < 0 || uNorm > 1 || vNorm < 0 || vNorm > 1 { return .zero }
            let u = prim.uv.x + (prim.uv.z - prim.uv.x) * uNorm
            let v = prim.uv.y + (prim.uv.w - prim.uv.y) * vNorm
            var cov = sampleR8(glyphs, u: u, v: v)
            let gamma = prim.params.w
            if gamma > 0 && abs(gamma - 1.0) > 1e-3 {
                cov = powf(clamp01(cov), gamma)
            }
            let a = prim.fill.w * cov
            outPremul = SIMD4<Float>(prim.fill.x * a, prim.fill.y * a, prim.fill.z * a, a)

        case .image:
            let dOuter = sdBox(localP, halfSize: halfSize, radii: prim.radii)
            let outerCov = boxCoverage(dOuter)
            if outerCov <= 0 { return .zero }
            let uNorm = clamp01((localP.x + halfSize.x) / max(prim.rect.z, 1e-4))
            let vNorm = clamp01((localP.y + halfSize.y) / max(prim.rect.w, 1e-4))
            let u = prim.uv.x + (prim.uv.z - prim.uv.x) * uNorm
            let v = prim.uv.y + (prim.uv.w - prim.uv.y) * vNorm
            let tex = sampleRGBA8(images, u: u, v: v, srgbBlend: srgbBlend)
            let c = tex * prim.fill
            let a = c.w * outerCov
            outPremul = SIMD4<Float>(c.x * a, c.y * a, c.z * a, a)

        case .linearGradient:
            let dOuter = sdBox(localP, halfSize: halfSize, radii: prim.radii)
            let outerCov = boxCoverage(dOuter)
            if outerCov <= 0 { return .zero }
            let angle = prim.params.z
            let dir = SIMD2<Float>(cosf(angle), sinf(angle))
            let maxExtent = abs(dir.x) * halfSize.x + abs(dir.y) * halfSize.y
            let t = maxExtent > 1e-4 ? clamp01(0.5 + simd_dot(localP, dir) / (2.0 * maxExtent)) : 0.5
            let col = prim.fill + (prim.border - prim.fill) * t
            var mask = outerCov
            if prim.params.x > 0 {
                let bw = prim.params.x
                let innerHalf = SIMD2<Float>(max(0, halfSize.x - bw), max(0, halfSize.y - bw))
                let innerRadii = SIMD4<Float>(
                    max(0, abs(prim.radii.x) - bw),
                    max(0, abs(prim.radii.y) - bw),
                    max(0, abs(prim.radii.z) - bw),
                    max(0, abs(prim.radii.w) - bw)
                )
                let dInner = sdBox(localP, halfSize: innerHalf, radii: innerRadii)
                mask = max(0, outerCov - boxCoverage(dInner))
            }
            let a = col.w * mask
            outPremul = SIMD4<Float>(col.x * a, col.y * a, col.z * a, a)

        case .multiGradient:
            let dOuter = sdBox(localP, halfSize: halfSize, radii: prim.radii)
            let outerCov = boxCoverage(dOuter)
            if outerCov <= 0 { return .zero }
            let gc = SIMD2<Float>(prim.uv.x, prim.uv.y)
            let rx = max(1e-3, prim.uv.z)
            let ry = max(1e-3, prim.uv.w)
            let rel = (fragCoord - gc) / SIMD2<Float>(rx, ry)
            let t = clamp01(simd_length(rel))
            let col = prim.fill + (prim.border - prim.fill) * t
            let a = col.w * outerCov
            outPremul = SIMD4<Float>(col.x * a, col.y * a, col.z * a, a)

        case .segment:
            let a = SIMD2<Float>(prim.uv.x, prim.uv.y)
            let b = SIMD2<Float>(prim.uv.z, prim.uv.w)
            let cov = segmentCoverage(
                p: fragCoord,
                a: a,
                b: b,
                width: prim.params.x,
                roundCap: prim.params.z >= 0.5
            )
            let alpha = prim.fill.w * cov
            outPremul = SIMD4<Float>(prim.fill.x * alpha, prim.fill.y * alpha, prim.fill.z * alpha, alpha)

        case .triangle:
            let v0 = SIMD2<Float>(prim.uv.x, prim.uv.y)
            let v1 = SIMD2<Float>(prim.uv.z, prim.uv.w)
            let v2 = prim.fadeOrigin
            let aaMask = Int(prim.params.x.rounded())
            let cov = triangleCoverage(p: fragCoord, v0: v0, v1: v1, v2: v2, aaMask: aaMask)
            let alpha = prim.fill.w * cov
            outPremul = SIMD4<Float>(prim.fill.x * alpha, prim.fill.y * alpha, prim.fill.z * alpha, alpha)

        case .dashedRing:
            let bw = max(0.5, prim.params.x)
            let dOuter = sdBox(localP, halfSize: halfSize, radii: prim.radii)
            let outerCov = boxCoverage(dOuter)
            if outerCov <= 0 { return .zero }
            let innerHalf = SIMD2<Float>(max(0, halfSize.x - bw), max(0, halfSize.y - bw))
            let avgR = abs(pickCornerRadius(localP, prim.radii))
            let innerRadii = SIMD4<Float>(
                max(0, abs(prim.radii.x) - bw),
                max(0, abs(prim.radii.y) - bw),
                max(0, abs(prim.radii.z) - bw),
                max(0, abs(prim.radii.w) - bw)
            )
            let dInner = sdBox(localP, halfSize: innerHalf, radii: innerRadii)
            let ringCov = max(0, outerCov - boxCoverage(dInner))
            if ringCov <= 0 { return .zero }
            let midHalf = SIMD2<Float>(max(0, halfSize.x - bw * 0.5), max(0, halfSize.y - bw * 0.5))
            let arc = ringArcLength(p: localP, halfSize: midHalf, r: max(0, avgR - bw * 0.5))
            let dCov = dashCoverage(arc: arc, dash: prim.params.z, gap: prim.params.w, phase: prim.uv.x)
            let alpha = prim.fill.w * ringCov * dCov
            outPremul = SIMD4<Float>(prim.fill.x * alpha, prim.fill.y * alpha, prim.fill.z * alpha, alpha)

        case .layerBegin, .layerEnd, .backdropBlur, .effectSlot:
            return .zero
        }

        return outPremul * fadeCov
    }
}
