import Foundation
import RuneMotion
import RuneRef
#if canImport(simd)
import simd
#endif

// MARK: - Gradients, Clips & Effect Modifiers on `El`

public struct GradientStop: Sendable, Hashable, Codable {
    public var color: Color
    public var offset: Float

    public init(_ color: Color, at offset: Float) {
        self.color = color
        self.offset = offset.clamped(to: 0...1)
    }

    public init(color: Color, offset: Float) {
        self.color = color
        self.offset = offset.clamped(to: 0...1)
    }
}

public enum RadialRadius: Sendable, Hashable, Codable {
    case farthestCorner
    case closestSide
    case farthestSide
    case pixels(Float)
    case xy(Float, Float)
}

internal struct RenderLinearGradientSpec: Sendable, Equatable {
    var angleRadians: Float
    var stops: [GradientStop]
}

internal struct RenderRadialGradientSpec: Sendable, Equatable {
    var center: Vec2
    var radius: RadialRadius
    var stops: [GradientStop]
}

internal struct RenderBorderGradientSpec: Sendable, Equatable {
    var width: Float
    var top: Color
    var bottom: Color
}

internal struct RenderClipSpec: Sendable, Equatable {
    var clipRect: Bool = false
    var radii: SIMD4<Float>? = nil
    var soft: Float = 0.0
    var fadeLTRB: SIMD4<Float>? = nil
    var fadeLinear: (dir: Vec2, from: Float, to: Float)? = nil
    var cutoutCircle: (cx: Float, cy: Float, radius: Float, feather: Float)? = nil

    static func == (lhs: RenderClipSpec, rhs: RenderClipSpec) -> Bool {
        lhs.clipRect == rhs.clipRect
            && lhs.radii == rhs.radii
            && lhs.soft == rhs.soft
            && lhs.fadeLTRB == rhs.fadeLTRB
            && lhs.fadeLinear?.dir == rhs.fadeLinear?.dir
            && lhs.fadeLinear?.from == rhs.fadeLinear?.from
            && lhs.fadeLinear?.to == rhs.fadeLinear?.to
            && lhs.cutoutCircle?.cx == rhs.cutoutCircle?.cx
            && lhs.cutoutCircle?.cy == rhs.cutoutCircle?.cy
            && lhs.cutoutCircle?.radius == rhs.cutoutCircle?.radius
            && lhs.cutoutCircle?.feather == rhs.cutoutCircle?.feather
    }
}

internal struct RenderEffectSpec: Sendable, Equatable {
    var id: UInt64 = 0
    var bleed: Float = 0.0
    var wantsBackdrop: Bool = false
    var data: SIMD4<Float> = .zero
}

internal enum RenderExtrasKey {
    static let linearGradient = "rune.render.linearGradient"
    static let radialGradient = "rune.render.radialGradient"
    static let borderGradient = "rune.render.borderGradient"
    static let clipSpec = "rune.render.clipSpec"
    static let effectSpec = "rune.render.effectSpec"
    static let shapeTrim = "rune.render.shapeTrim"
    static let cacheEnabled = "rune.render.cacheEnabled"
    static let cacheKey = "rune.render.cacheKey"
    static let hoverGroupFocus = "rune.render.hoverGroupFocus"
    static let continuousCorners = "rune.render.continuousCorners"
}

extension El {
    /// Marks this element's corners and clip mask as Apple continuous superellipses (`El::continuous_corners`).
    public func continuousCorners(_ on: Bool = true) -> Self {
        var copy = self
        copy.runtimeExtras[RenderExtrasKey.continuousCorners] = on
        return copy
    }

    /// Shorthand vertical 2-stop gradient (`El::gradient`).
    public func gradient(_ top: Color, _ bottom: Color) -> Self {
        linearGradient(top: top, bottom: bottom, angleRadians: .pi * 0.5)
    }

    /// Multi-stop linear gradient (`El::linear_gradient`).
    public func linearGradient(angle angleRadians: Float = .pi * 0.5, stops: [GradientStop]) -> Self {
        var copy = self
        copy.runtimeExtras[RenderExtrasKey.linearGradient] = RenderLinearGradientSpec(
            angleRadians: angleRadians,
            stops: stops.sorted { $0.offset < $1.offset }
        )
        return copy
    }

    /// Multi-stop positioned elliptical radial gradient (`El::radial_gradient`).
    public func radialGradient(
        center: Vec2 = Vec2(0.5, 0.5),
        radius: RadialRadius = .farthestCorner,
        stops: [GradientStop]
    ) -> Self {
        var copy = self
        copy.runtimeExtras[RenderExtrasKey.radialGradient] = RenderRadialGradientSpec(
            center: center,
            radius: radius,
            stops: stops.sorted { $0.offset < $1.offset }
        )
        return copy
    }

    /// Gradient border (`El::border_gradient`).
    public func borderGradient(width: Float = 1.0, top: Color, bottom: Color) -> Self {
        var copy = self
        copy.runtimeExtras[RenderExtrasKey.borderGradient] = RenderBorderGradientSpec(
            width: max(0, width),
            top: top,
            bottom: bottom
        )
        return copy
    }

    /// Per-corner rounded SDF clip (`El::clip_corners`). Negative corners use continuous superellipses.
    public func clipRounded(tl: Float, tr: Float, br: Float, bl: Float) -> Self {
        var copy = clipCorners(Corners(tl, tr, br, bl))
        copy.clipRadius = nil
        var spec = (copy.runtimeExtras[RenderExtrasKey.clipSpec] as? RenderClipSpec) ?? RenderClipSpec()
        spec.clipRect = true
        spec.radii = nil
        copy.runtimeExtras[RenderExtrasKey.clipSpec] = spec
        copy.layout.clipOverflow = true
        return copy
    }

    /// Uniform continuous squircle clip (`El::clip_continuous`).
    public func clipContinuous(_ radius: Float) -> Self {
        clipRounded(tl: -abs(radius), tr: -abs(radius), br: -abs(radius), bl: -abs(radius))
    }

    /// Per-corner clip alias matching `El::clip_corners`.
    public func clipCorners(_ radius: Float) -> Self {
        clipRounded(radius)
    }

    public func clipCorners(tl: Float, tr: Float, br: Float, bl: Float) -> Self {
        clipRounded(tl: tl, tr: tr, br: br, bl: bl)
    }

    /// Directional feathered fade across `[from, to]` points (`El::clip_fade_linear`).
    public func clipFadeLinear(dx: Float, dy: Float, from: Float = 0, to: Float = 24) -> Self {
        var copy = self
        var spec = (copy.runtimeExtras[RenderExtrasKey.clipSpec] as? RenderClipSpec) ?? RenderClipSpec()
        spec.clipRect = true
        spec.fadeLinear = (Vec2(dx, dy), from, to)
        copy.runtimeExtras[RenderExtrasKey.clipSpec] = spec
        copy.layout.clipOverflow = true
        return copy
    }

    /// Punches a feathered circular cutout through an isolated layer (`El::cutout_circle`).
    public func cutoutCircle(cx: Float, cy: Float, radius: Float, feather: Float = 1.0) -> Self {
        var copy = self
        var spec = (copy.runtimeExtras[RenderExtrasKey.clipSpec] as? RenderClipSpec) ?? RenderClipSpec()
        spec.cutoutCircle = (cx, cy, max(0, radius), max(1, feather))
        copy.runtimeExtras[RenderExtrasKey.clipSpec] = spec
        copy.isolatedLayer = true
        return copy
    }

    /// Reserves a compositor `EffectSite` slot (`El::effect`).
    public func effect(_ id: UInt64 = 0) -> Self {
        var copy = self
        var spec = (copy.runtimeExtras[RenderExtrasKey.effectSpec] as? RenderEffectSpec) ?? RenderEffectSpec()
        spec.id = id
        copy.runtimeExtras[RenderExtrasKey.effectSpec] = spec
        return copy
    }

    /// Expands an effect slot's scissor/quad rectangle by `bleed` points on all sides (`El::effect_bleed`).
    public func effectBleed(_ bleed: Float) -> Self {
        var copy = self
        var spec = (copy.runtimeExtras[RenderExtrasKey.effectSpec] as? RenderEffectSpec) ?? RenderEffectSpec()
        spec.bleed = max(0, bleed)
        copy.runtimeExtras[RenderExtrasKey.effectSpec] = spec
        return copy
    }

    /// Requests a backdrop copy before drawing an effect slot (`El::effect_backdrop`).
    public func effectBackdrop(_ on: Bool = true) -> Self {
        var copy = self
        var spec = (copy.runtimeExtras[RenderExtrasKey.effectSpec] as? RenderEffectSpec) ?? RenderEffectSpec()
        spec.wantsBackdrop = on
        copy.runtimeExtras[RenderExtrasKey.effectSpec] = spec
        return copy
    }

    /// Passes custom 4-float payload to `EffectSite.data` (`El::effect_data`).
    public func effectData(_ data: SIMD4<Float>) -> Self {
        var copy = self
        var spec = (copy.runtimeExtras[RenderExtrasKey.effectSpec] as? RenderEffectSpec) ?? RenderEffectSpec()
        spec.data = data
        copy.runtimeExtras[RenderExtrasKey.effectSpec] = spec
        return copy
    }

    /// Retains this subtree in a pooled offscreen GPU layer across unchanged/panned frames (`El::cache`).
    public func cache(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.runtimeExtras[RenderExtrasKey.cacheEnabled] = enabled
        return copy
    }

    /// Supplies an explicit cache-invalidation salt mixed into `El.cache()`'s retained key (`El::cache_key`).
    public func cacheKey(_ key: UInt64) -> Self {
        var copy = self
        copy.runtimeExtras[RenderExtrasKey.cacheEnabled] = true
        copy.runtimeExtras[RenderExtrasKey.cacheKey] = key
        return copy
    }

    /// Appends multiple `Shape` draws to this element.
    public func shapes(_ list: [Shape]) -> Self {
        var copy = self
        copy.shapes.append(contentsOf: list)
        return copy
    }

    /// Applies fractional progressive draw `[0, t]` across attached `shapes`.
    public func shapeDrawn(_ t: Float) -> Self {
        shapeTrim(start: 0.0, end: t)
    }

    /// Applies fractional stroke trim `[start, end]` across attached `shapes`.
    public func shapeTrim(start: Float, end: Float) -> Self {
        var copy = self
        copy.runtimeExtras[RenderExtrasKey.shapeTrim] = Vec2(start, end)
        return copy
    }
}

// MARK: - Premultiplied Color & Gradient Helpers

@inline(__always)
private func premulSIMD4(_ c: Color, opacity: Float = 1.0, srgb: Bool) -> SIMD4<Float> {
    let v = c.simd4(srgb: srgb)
    let a = (v.w * opacity).clamped(to: 0...1)
    return SIMD4<Float>(v.x * a, v.y * a, v.z * a, a)
}

internal let radialStopProps: [Prop<MotionColor>] = (0..<16).map {
    Prop<MotionColor>.custom(UInt16(80 + $0), .color, name: "radialStop\($0)")
}
internal let shadowColorProps: [Prop<MotionColor>] = (0..<8).map {
    Prop<MotionColor>.custom(UInt16(120 + $0), .color, name: "shadowColor\($0)")
}

private func resolveRadialRadii(
    _ spec: RadialRadius,
    centerLocal: Vec2,
    size: Vec2
) -> (rx: Float, ry: Float)? {
    guard centerLocal.x.isFinite && centerLocal.y.isFinite && size.x.isFinite && size.y.isFinite else {
        return nil
    }
    switch spec {
    case .farthestCorner:
        let dx = max(centerLocal.x, size.x - centerLocal.x)
        let dy = max(centerLocal.y, size.y - centerLocal.y)
        let r = max(1e-3, hypotf(dx, dy))
        return (r, r)
    case .closestSide:
        let r = max(1e-3, min(min(centerLocal.x, size.x - centerLocal.x), min(centerLocal.y, size.y - centerLocal.y)))
        return (r, r)
    case .farthestSide:
        let r = max(1e-3, max(max(centerLocal.x, size.x - centerLocal.x), max(centerLocal.y, size.y - centerLocal.y)))
        return (r, r)
    case .pixels(let p):
        guard p.isFinite && p > 0 else { return nil }
        return (p, p)
    case .xy(let rx, let ry):
        guard rx.isFinite && ry.isFinite && rx > 0 && ry > 0 else { return nil }
        return (rx, ry)
    }
}

private func emitStopSpans(
    stops: [GradientStop],
    rect: SIMD4<Float>,
    radii: SIMD4<Float>,
    uv: SIMD4<Float>,
    clip: SIMD4<Float>,
    fade: SIMD4<UInt32>,
    soft: Float,
    blurPx: Float = 0,
    opacity: Float,
    srgb: Bool,
    into instances: inout [RenderInstance],
    marks: inout [UInt32]
) {
    guard !stops.isEmpty else { return }
    if stops.count == 1 {
        let c = premulSIMD4(stops[0].color, opacity: opacity, srgb: srgb)
        instances.append(RenderInstance(
            rect: rect,
            radii: radii,
            fill: c,
            border: c,
            params: SIMD4<Float>(0, KIND_RADIAL, soft, 1.0),
            uv: uv,
            clip: clip,
            fade: fade
        ))
        marks.append(0)
        return
    }
    let count = stops.count
    let isRadial = uv.z > 0.0
    let w = rect.z
    let h = rect.w
    let cx = uv.x
    let cy = uv.y
    let rx = uv.z
    let ry = uv.w
    let rmax = min(max(abs(radii.x), max(abs(radii.y), max(abs(radii.z), abs(radii.w)))), min(w * 0.5, h * 0.5))
    let pad = 1.0 + max(0, blurPx) * 2.0

    for j in 0..<(count - 1) {
        let s0 = stops[j]
        let s1 = stops[j + 1]
        let c0 = premulSIMD4(s0.color, opacity: opacity, srgb: srgb)
        let c1 = premulSIMD4(s1.color, opacity: opacity, srgb: srgb)
        if isRadial && c0.w <= 0.0005 && c1.w <= 0.0005 {
            continue
        }
        let lowerOpen = j > 0
        let upperOpen = j < count - 2
        let t0 = lowerOpen ? (s0.offset + 2.0) : s0.offset
        let t1 = upperOpen ? (s1.offset + 2.0) : s1.offset

        var segRect = rect
        var segRadii = radii
        var segUV = uv
        if isRadial && j < count - 2 {
            var lx0 = max(0.0, floorf(cx - s1.offset * rx - pad))
            var ly0 = max(0.0, floorf(cy - s1.offset * ry - pad))
            var lx1 = min(w, ceilf(cx + s1.offset * rx + pad))
            var ly1 = min(h, ceilf(cy + s1.offset * ry + pad))
            if rmax > 0.0 {
                if lx0 < rmax && (ly0 < rmax || ly1 > h - rmax) { lx0 = 0.0 }
                if lx1 > w - rmax && (ly0 < rmax || ly1 > h - rmax) { lx1 = w }
                if ly0 < rmax && (lx0 < rmax || lx1 > w - rmax) { ly0 = 0.0 }
                if ly1 > h - rmax && (lx0 < rmax || lx1 > w - rmax) { ly1 = h }
                if lx0 == 0.0 && (ly0 == 0.0 || ly1 == h) { lx1 = max(lx1, min(w, 2.0 * rmax)) }
                if lx1 == w && (ly0 == 0.0 || ly1 == h) { lx0 = min(lx0, max(0.0, w - 2.0 * rmax)) }
                if ly0 == 0.0 && (lx0 == 0.0 || lx1 == w) { ly1 = max(ly1, min(h, 2.0 * rmax)) }
                if ly1 == h && (lx0 == 0.0 || lx1 == w) { ly0 = min(ly0, max(0.0, h - 2.0 * rmax)) }
            }
            if lx1 <= lx0 || ly1 <= ly0 {
                continue
            }
            segRect = SIMD4<Float>(rect.x + lx0, rect.y + ly0, lx1 - lx0, ly1 - ly0)
            segRadii = SIMD4<Float>(
                (lx0 == 0.0 && ly0 == 0.0) ? radii.x : 0.0,
                (lx1 == w && ly0 == 0.0) ? radii.y : 0.0,
                (lx1 == w && ly1 == h) ? radii.z : 0.0,
                (lx0 == 0.0 && ly1 == h) ? radii.w : 0.0
            )
            segUV = SIMD4<Float>(cx - lx0, cy - ly0, rx, ry)
        }

        instances.append(RenderInstance(
            rect: segRect,
            radii: segRadii,
            fill: c0,
            border: c1,
            params: SIMD4<Float>(t0, KIND_RADIAL, soft, t1),
            uv: segUV,
            clip: clip,
            fade: fade
        ))
        marks.append(0)
    }
}

@inline(__always)
private func clampSignedCornerRadius(_ radii: SIMD4<Float>, width: Float, height: Float) -> Float {
    let absMax = max(max(abs(radii.x), abs(radii.y)), max(abs(radii.z), abs(radii.w)))
    let clamped = min(absMax, max(0, min(width, height) * 0.5))
    let continuous = radii.x < 0 || radii.y < 0 || radii.z < 0 || radii.w < 0
    return continuous ? -clamped : clamped
}

private func fnvMix(_ h: inout UInt64, _ value: UInt64) {
    var x = h ^ value
    x &*= 0x9E37_79B9_7F4A_7C15
    x ^= x >> 30
    x &*= 0xBF58_476D_1CE4_E5B9
    x ^= x >> 27
    x &*= 0x94D0_49BB_1331_11EB
    x ^= x >> 31
    h = x
}

private func fnvMixFloat(_ h: inout UInt64, _ v: Float) {
    let bits = v == 0 ? 0 : v.bitPattern
    fnvMix(&h, UInt64(bits))
}

private func fnvMixFloat4(_ h: inout UInt64, _ v: SIMD4<Float>) {
    fnvMixFloat(&h, v.x)
    fnvMixFloat(&h, v.y)
    fnvMixFloat(&h, v.z)
    fnvMixFloat(&h, v.w)
}

private func hashCachedLayerContent(
    instances: ArraySlice<RenderInstance>,
    glyphFixups: ArraySlice<(index: Int, normUV: SIMD4<Float>, texW: Float, texH: Float, page: UInt16, forceScaled: Bool)>,
    imageFixups: ArraySlice<(index: Int, texelEdges: SIMD4<Float>, imgW: Float, imgH: Float)>,
    surfacesCount: Int,
    origin: SIMD2<Float>,
    size: SIMD2<Float>,
    blurPx: Float,
    srgbBlend: Bool,
    glyphAtlasSize: (Int, Int),
    imageVersion: (SIMD4<Float>) -> UInt64,
    userKey: UInt64?
) -> UInt64 {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325
    fnvMix(&h, UInt64(instances.count))
    fnvMix(&h, UInt64(surfacesCount))
    fnvMixFloat(&h, size.x)
    fnvMixFloat(&h, size.y)
    fnvMixFloat(&h, blurPx)
    fnvMix(&h, srgbBlend ? 1 : 0)
    fnvMix(&h, UInt64(glyphAtlasSize.0))
    fnvMix(&h, UInt64(glyphAtlasSize.1))
    if let uk = userKey {
        fnvMix(&h, 1)
        fnvMix(&h, uk)
    } else {
        fnvMix(&h, 0)
    }
    for inst in instances {
        let kind = Float(Int(inst.params.y.rounded()))
        let relRect = SIMD4<Float>(inst.rect.x - origin.x, inst.rect.y - origin.y, inst.rect.z, inst.rect.w)
        fnvMixFloat4(&h, relRect)
        if kind == KIND_SEGMENT || kind == KIND_TRIANGLE {
            fnvMixFloat4(&h, SIMD4<Float>(inst.radii.x - origin.x, inst.radii.y - origin.y, inst.radii.z - origin.x, inst.radii.w - origin.y))
        } else {
            fnvMixFloat4(&h, inst.radii)
        }
        fnvMixFloat4(&h, inst.fill)
        if kind == KIND_LAYER && inst.border.y != 0 {
            fnvMixFloat4(&h, SIMD4<Float>(inst.border.x, inst.border.y, inst.border.z - origin.x, inst.border.w - origin.y))
        } else {
            fnvMixFloat4(&h, inst.border)
        }
        fnvMixFloat4(&h, inst.params)
        if kind == KIND_TRIANGLE {
            fnvMixFloat4(&h, SIMD4<Float>(inst.uv.x - origin.x, inst.uv.y - origin.y, inst.uv.z, inst.uv.w))
        } else {
            fnvMixFloat4(&h, inst.uv)
        }
        if kind == KIND_IMAGE {
            // Cropped images retain their complete allocation in the border field.
            fnvMix(&h, imageVersion(inst.border == .zero ? inst.uv : inst.border))
        }
        if inst.clip == NO_CLIP {
            fnvMix(&h, 0xDEAD_BEEF)
        } else {
            fnvMixFloat4(&h, SIMD4<Float>(inst.clip.x - origin.x, inst.clip.y - origin.y, inst.clip.z - origin.x, inst.clip.w - origin.y))
        }
        fnvMix(&h, UInt64(inst.fade.x))
        fnvMix(&h, UInt64(inst.fade.y))
        fnvMix(&h, UInt64(inst.fade.z))
        fnvMix(&h, UInt64(inst.fade.w))
    }
    for fix in glyphFixups {
        fnvMixFloat4(&h, fix.normUV)
        fnvMixFloat(&h, fix.texW)
        fnvMixFloat(&h, fix.texH)
        fnvMix(&h, fix.forceScaled ? 1 : 0)
    }
    for fix in imageFixups {
        fnvMixFloat4(&h, fix.texelEdges)
        fnvMixFloat(&h, fix.imgW)
        fnvMixFloat(&h, fix.imgH)
    }
    return h
}

private func intersectClipRects(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> {
    SIMD4<Float>(max(a.x, b.x), max(a.y, b.y), min(a.z, b.z), min(a.w, b.w))
}

private func inheritFade(
    width: inout SIMD4<Float>,
    origin: inout SIMD4<Float>,
    rect: SIMD4<Float>,
    own: SIMD4<Float>
) {
    for edge in 0..<4 {
        let inset = edge < 2 ? (rect[edge] - origin[edge]) : (origin[edge] - rect[edge])
        let o = abs(own[edge])
        let w = abs(width[edge])
        if o > 0 && (o >= w || inset >= w) {
            width[edge] = own[edge]
            origin[edge] = rect[edge]
        }
    }
}

private func inFade(
    _ r: SIMD4<Float>,
    clip: SIMD4<Float>,
    width: SIMD4<Float>,
    origin: SIMD4<Float>
) -> Bool {
    let w = SIMD4<Float>(abs(width.x), abs(width.y), abs(width.z), abs(width.w))
    return (w.x > 0 && r.x < origin.x + w.x && r.z > clip.x)
        || (w.y > 0 && r.y < origin.y + w.y && r.w > clip.y)
        || (w.z > 0 && r.z > origin.z - w.z && r.x < clip.z)
        || (w.w > 0 && r.w > origin.w - w.w && r.y < clip.w)
}

private func insideRounded(_ rect: SIMD4<Float>, mask: SIMD4<Float>, radii: SIMD4<Float>) -> Bool {
    let aa: Float = 1.0
    if rect.z <= rect.x || rect.w <= rect.y { return true }
    if rect.x < mask.x || rect.y < mask.y || rect.z > mask.z || rect.w > mask.w { return false }
    let corners: [(Float, Float, Float, Float, Float)] = [
        (mask.x, mask.y, 1, 1, radii.x),
        (mask.z, mask.y, -1, 1, radii.y),
        (mask.z, mask.w, -1, -1, radii.z),
        (mask.x, mask.w, 1, -1, radii.w)
    ]
    let pts: [(Float, Float)] = [(rect.x, rect.y), (rect.z, rect.y), (rect.z, rect.w), (rect.x, rect.w)]
    for (cx, cy, sx, sy, radius) in corners {
        let e = cornerExtent(radius)
        for (px, py) in pts {
            let dx = (px - cx) * sx
            let dy = (py - cy) * sy
            if dx >= e || dy >= e { continue }
            if !(radius > 0.0 && hypotf(radius - dx, radius - dy) <= radius - aa) {
                return false
            }
        }
    }
    return true
}

private func trimCentralStrip(_ round: inout (rect: SIMD4<Float>, radii: SIMD4<Float>)?, clip: inout SIMD4<Float>) {
    guard let (mask, radii) = round else { return }
    let e = SIMD4<Float>(cornerExtent(radii.x), cornerExtent(radii.y), cornerExtent(radii.z), cornerExtent(radii.w))
    let left = max(e.x, e.w)
    let right = max(e.y, e.z)
    let top = max(e.x, e.y)
    let bottom = max(e.w, e.z)
    let cut = intersectClipRects(clip, mask)
    if cut.z <= cut.x || cut.w <= cut.y
        || (cut.x >= mask.x + left && cut.z <= mask.z - right)
        || (cut.y >= mask.y + top && cut.w <= mask.w - bottom)
    {
        clip = cut
        round = nil
    }
}

private struct RenderClipState {
    var rectPt: MotionRect
    var clipPx: SIMD4<Float>
    var fadeWidth: SIMD4<Float> = .zero
    var fadeOrigin: SIMD4<Float> = NO_CLIP
    var fade: SIMD4<UInt32>
    var roundedMask: (rect: SIMD4<Float>, radii: SIMD4<Float>)? = nil
    // Per-axis inherited fade with the nearest scroll viewport's own ramp omitted.
    var withoutScrollWidth: SIMD4<Float> = .zero
    var withoutScrollOrigin: SIMD4<Float> = NO_CLIP
}

/// A composited layer can reset the renderer's clip and opacity for its inner draws.
/// Pointer geometry keeps the logical clip, turn, and opacity through that layer.
private struct RenderHitScope {
    var localClip: MotionRect?
    var outerClip: MotionRect?
    var turn: Turn?
    var opacity: Float = 1
    var exiting = false
}

private struct SavedRaisedNodeState {
    var elementIndex: Int
    var visibleClipPt: MotionRect
    var unclippedClipPx: SIMD4<Float>
    var unclippedFadeWidth: SIMD4<Float>
    var unclippedFadeOrigin: SIMD4<Float>
    var unclippedFade: SIMD4<UInt32>
    var withoutScrollWidth: SIMD4<Float>
    var withoutScrollOrigin: SIMD4<Float>
    var effOpacity: Float
    var nextInert: Bool
    var nextChildTransform: PresentedTransform
    var isDissolveScope: Bool
    var scaleMotionRaw: Int
    var rectPx: SIMD4<Float>
    var boundsClipPx: SIMD4<Float>
    var ownClipRadiiPx: SIMD4<Float>?
    var rotate: Float
    var outerTurnClip: SIMD4<Float>
}

// MARK: - `Runtime.renderFrame(at:)` (Upstream `paint/build.rs` Parity)

extension Runtime {
    /// Evaluates view + layout + motion and builds an upstream-parity 128-byte `RenderFrame` (`render::Instance` + `Clip` + `Effect` + `SystemMaterial`).
    @discardableResult
    public func renderFrame(at now: Double) -> RenderFrame {
        withRenderFrame(at: now) { settled, frameOut, time in
            if RasterCheck.enabled && !isAnimating {
                return freshRasterCheck(settled, frameOut: frameOut, at: time).frame
            }
            return settled
        }
    }

    /// Compare a settled paint with a fresh one at the same scene time and view state.
    @discardableResult
    public func checkRestingRaster(at time: Double? = nil) -> RasterCheckReport {
        withRenderFrame(at: time ?? currentTime) { settled, frameOut, time in
            freshRasterCheck(settled, frameOut: frameOut, at: time).report
        }
    }

    private func freshRasterCheck(_ settled: RenderFrame, frameOut: FrameOutput, at time: Double)
        -> (frame: RenderFrame, report: RasterCheckReport) {
        textSystem.forgetRasterState()
        let fresh = buildRenderFrame(frameOut: frameOut, now: time)
        return (fresh, RasterCheck.compare(settled, fresh, at: time))
    }

    private func withRenderFrame<T>(at now: Double, finish: (RenderFrame, FrameOutput, Double) -> T) -> T {
        RuntimeIdScope.$current.withValue(runtimeId) {
            Theme.withBlend(srgbBlend) {
                let timer = beginFrameTimers(at: now)
                var (frameOut, animNow) = stepToFrameOutputScaled(at: now, skipFramePoll: timer.alreadyPolled)
                func paint() -> RenderFrame {
                    measureFramePhase(.paint) {
                        buildRenderFrame(frameOut: frameOut, now: animNow, publishHitGeometry: true)
                    }
                }
                var rf = paint()
                for _ in 0..<3 {
                    if !followKeeps(frameOut: &frameOut, at: animNow) { break }
                    rf = paint()
                }
                finishKeeps(cut: false)
                if (hasMovingScaleSettle || pixelSnapGlides.isEasing) && cxSettings.viewTimeScale > 0.0 {
                    isAnimating = true
                    animSources |= AnimSource.scaleSettle
                } else if !hasMovingScaleSettle && !pixelSnapGlides.isEasing {
                    animSources &= ~AnimSource.scaleSettle
                    if animSources == 0 {
                        isAnimating = false
                    }
                }
                let result = finish(rf, frameOut, animNow)
                finishPostFrameHooks(at: now)
                return result
            }
        }
    }

    internal func buildRenderFrame(frameOut: FrameOutput, now: Double, publishHitGeometry: Bool = false) -> RenderFrame {
        beginPixelPaint()
        defer { finishPixelPaint() }
        textSystem.glyphAtlas.beginFrame(pinnedMask: 0)
        elSliceRenderState.cacheScaleFramePending = false
        let commitGen = UInt64(viewCommitCount)
        let scale = max(pixelScale, 0.5)
        let widthPx = max(1, Int((viewport.x * scale).rounded()))
        let heightPx = max(1, Int((viewport.y * scale).rounded()))

        pixelSnapGlides.beginFrame(t: now, size: SIMD2<Float>(Float(widthPx), Float(heightPx)))
        var childSnapByNode: [NodeId: PixelSnap.Inherit] = [:]
        var rectMap: [NodeId: MotionRect] = [:]
        var opacityMap: [NodeId: Float] = [:]
        var scaleMap: [NodeId: Vec2] = [:]
        var blurMap: [NodeId: Float] = [:]
        var radiusMap: [NodeId: Corners] = [:]
        var fillMap: [NodeId: Color] = [:]
        var borderMap: [NodeId: Color] = [:]
        var drawMap: [NodeId: Float] = [:]
        var movingSet: Set<NodeId> = []
        var exitingIds: Set<NodeId> = []

        for animNode in frameOut.nodes {
            rectMap[animNode.id] = animNode.rect
            opacityMap[animNode.id] = animNode.opacity
            scaleMap[animNode.id] = animNode.scale
            blurMap[animNode.id] = animNode.blur
            radiusMap[animNode.id] = animNode.corners
            drawMap[animNode.id] = animNode.draw
            // At rest the authored color is exact. Converting it through motion lanes can
            // move a saturated channel off its endpoint before the byte compositor sees it.
            if let mc = animNode.fill, animNode.isExiting || scene.store.isAnimating(animNode.id, Props.FILL) {
                fillMap[animNode.id] = Color(mc)
            }
            if let mb = animNode.border {
                borderMap[animNode.id] = Color(mb)
            }
            if animNode.isMoving { movingSet.insert(animNode.id) }
            if animNode.isExiting { exitingIds.insert(animNode.id) }
        }

        // Presented nodes retain their parent IDs while exiting, even when a new subtree
        // now occupies the old indices in flatNodes.
        let renderNodes = frameOut.nodes.compactMap { nodeById[$0.id] ?? exitingSnapshots[$0.id] }
        var parentById: [NodeId: NodeId] = [:]
        for n in frameOut.nodes {
            if let parent = n.parent { parentById[n.id] = parent }
        }
        let hasHolds = !scrollRequestsState.keeps.isEmpty
        let hasSticky = hasHolds || flatNodes.contains(where: \.isSticky)
        var beforeSticky: [NodeId: MotionRect] = [:]
        stuckShiftsByPath.removeAll(keepingCapacity: true)
        var newElements: [ElementInfo] = []
        var newSeenMatched: [String: MatchedSeenSnapshot] = [:]
        var newHitGeometries: [String: HitGeometry] = [:]
        var newLinkBoxes: [String: [TextLinkBox]] = [:]
        var hitScopes: [RenderHitScope] = []
        var newPresentedRects: [String: MotionRect] = [:]
        var newPresentedScales: [String: Vec2] = [:]
        var newPresentedScaleMotionById: [NodeId: PaintScaleMotion] = [:]
        var newDrawnRectByPath: [String: MotionRect] = [:]
        var newRectSpringingById: [NodeId: Bool] = [:]
        var instances: [RenderInstance] = []
        var elidedLayers: [(index: Int, node: UInt64, signature: UInt64)] = []
        var marks: [UInt32] = []
        var newSurfaces: [SurfaceDraw] = []
        var surfaceVideo = SurfaceVideoPaint()
        var currentInheritedMark: UInt32 = 0
        var materials: [MaterialDraw] = []

        // Publish normalized glyph pages and image texel edges in the renderer's origin/size ABI.
        var glyphFixups: [(index: Int, normUV: SIMD4<Float>, texW: Float, texH: Float, page: UInt16, forceScaled: Bool)] = []
        var imageFixups: [(index: Int, texelEdges: SIMD4<Float>, imgW: Float, imgH: Float)] = []

        func closeLayer(start: Int, surfaceStart: Int) {
            let count = instances.count
            foldEndLayer(instances: &instances, surfaces: &newSurfaces, marks: &marks,
                         start: start, surfaceStart: surfaceStart)
            // Folding a single draw removes its preceding layer marker.
            // Keep the pending atlas conversion attached to the surviving draw.
            if instances.count < count && count == start + 2 {
                if glyphFixups.last?.index == start + 1 { glyphFixups[glyphFixups.count - 1].index = start }
                if imageFixups.last?.index == start + 1 { imageFixups[imageFixups.count - 1].index = start }
            }
        }

        var childrenByParent: [NodeId: [FlatNode]] = [:]
        var roots: [FlatNode] = []
        for n in renderNodes {
            if let parent = parentById[n.nodeId], rectMap[parent] != nil {
                childrenByParent[parent, default: []].append(n)
            } else {
                roots.append(n)
            }
        }
        func paintsBefore(_ a: FlatNode, _ b: FlatNode) -> Bool {
            if a.zOrder != b.zOrder { return a.zOrder < b.zOrder }
            guard hasSticky else { return false }
            func rank(_ node: FlatNode) -> Int {
                if node.el.anchor != nil || node.el.isModal { return 2 }
                return node.isSticky ? 1 : 0
            }
            return rank(a) < rank(b)
        }
        roots.sort(by: paintsBefore)
        for (parent, children) in childrenByParent {
            childrenByParent[parent] = children.sorted(by: paintsBefore)
        }

        let groupHoverChecker = makeGroupHoverPredicate()
        func resolveNodeHoverFrac(_ n: FlatNode, inert: Bool) -> Float {
            let nid = n.nodeId
            if inert || exitingIds.contains(nid) { return 0.0 }
            if let tracked = liveStore.get(Runtime.hoverTrackId(nid), Runtime.hoverProp) {
                return tracked.clamped(to: 0...1)
            }
            // Synced hover without a track rests at 0 (`paint/tracks.rs::ready_from_rest`).
            if lastHoverTargetById[nid] != nil { return 0.0 }
            if n.el.isHoverGroup || n.el.hoverGroupShare != nil {
                return groupHoverChecker(n) ? 1.0 : 0.0
            }
            return hoveredPath == n.path ? 1.0 : 0.0
        }

        var nodeOwnOpacityById: [NodeId: Float] = [:]
        var nodeHoverFracById: [NodeId: Float] = [:]
        var inheritedGroupFracById: [NodeId: Float] = [:]
        var nodePressById: [NodeId: (color: Color?, frac: Float)] = [:]
        func collectHoverAndOwnOpacity(
            _ n: FlatNode,
            inheritedInert: Bool,
            inheritedGroupFrac: Float,
            inheritedPress: (color: Color?, frac: Float)
        ) {
            let effInert = inheritedInert || n.el.isInert
            let nid = n.nodeId
            if let parent = parentById[nid], exitingIds.contains(parent) { exitingIds.insert(nid) }
            let el = n.el
            var liveOp: Float? = nil
            var liveRect: MotionRect? = nil
            for b in el.liveBindings {
                let lnid = NodeId.hash("live:\(n.path):\(b.target)")
                if b.target == .opacity, let v = liveStore.get(lnid, Props.OPACITY) { liveOp = v }
                else if b.target == .rect, let r = liveStore.get(lnid, Props.RECT) { liveRect = r }
            }
            let baseSize = (liveRect ?? rectMap[nid] ?? n.targetRect).size
            let loopOp = sampleLoopPresentation(id: nid, nodeSize: baseSize, wallNow: currentTime)?.opacity ?? 1.0
            let groupFactor = resolveGroupOpacityFactor(
                nodeId: nid,
                el: el,
                nodePath: n.path,
                inheritedGroupFrac: inheritedGroupFrac
            )
            let ownOp = ((liveOp ?? opacityMap[nid] ?? el.opacity) * groupFactor * loopOp).clamped(to: 0...1)
            let ownHoverFrac = resolveNodeHoverFrac(n, inert: effInert)
            let ownPress: (color: Color?, frac: Float) = {
                if let pc = el.pressColor {
                    let isPressedNode = isNodePressedVisually(path: n.path, effectiveInert: effInert || exitingIds.contains(nid))
                    let frac = (liveStore.get(Runtime.pressTrackId(nid), Runtime.pressProp) ?? (isPressedNode ? 1.0 : 0.0)).clamped(to: 0...1)
                    return (pc, frac)
                }
                return inheritedPress
            }()
            nodeOwnOpacityById[nid] = ownOp
            nodeHoverFracById[nid] = ownHoverFrac
            inheritedGroupFracById[nid] = inheritedGroupFrac
            nodePressById[nid] = ownPress

            let isGroupScope = el.isHoverGroup || el.hoverBg != nil || el.hoverGroupShare != nil
            let nextGroupFrac = isGroupScope ? ownHoverFrac : inheritedGroupFrac
            for child in childrenByParent[n.nodeId] ?? [] {
                collectHoverAndOwnOpacity(
                    child,
                    inheritedInert: effInert,
                    inheritedGroupFrac: nextGroupFrac,
                    inheritedPress: ownPress
                )
            }
        }
        for r in roots {
            collectHoverAndOwnOpacity(
                r,
                inheritedInert: false,
                inheritedGroupFrac: 0.0,
                inheritedPress: (nil, 0.0)
            )
        }

        // Direct children with intermediate opacity activate `.plusLighter` dissolve (`runtime/paint/build.rs:81-89`).
        let dissolveParentIds = refreshDissolvePrepass(
            nodeIds: renderNodes.map(\.nodeId),
            isDissolve: { nid in renderNodes.first(where: { $0.nodeId == nid })?.el.isDissolve ?? false },
            childIds: { nid in (childrenByParent[nid] ?? []).filter { !$0.el.isRaised }.map(\.nodeId) },
            ownOpacity: { nid in
                nodeOwnOpacityById[nid] ?? renderNodes.first(where: { $0.nodeId == nid })?.el.opacity ?? 1.0
            }
        )

        let initialClipPt = MotionRect(left: 0, top: 0, right: viewport.x, bottom: viewport.y)
        let rootClip = RenderClipState(rectPt: initialClipPt, clipPx: NO_CLIP, fade: .zero)
        let materialMode = MaterialMode.fromEnv()
        let useNativeMaterials = nativeMaterials && materialMode != .fallback
        var savedNodeStates: [NodeId: SavedRaisedNodeState] = [:]
        var collectedRaisedNodes: [FlatNode] = []

        @inline(never)
        func hasDynamicInSubtree(_ n: FlatNode) -> Bool {
            if movingSet.contains(n.nodeId)
                || exitingIds.contains(n.nodeId)
                || activeTextFlights.contains(where: {
                    $0.targetNodeId == n.nodeId || FlightSelector.selects($0.state.sourceKey, path: n.path, key: n.key)
                })
                || n.el.isSecure
                || (n.el.handlers.editLens?.get(state).isSecure == true)
                || !n.el.liveBindings.isEmpty
                || n.el.pixelsPayload != nil
                || n.el.surfacePayload != nil
                || n.el.runtimeExtras[RenderExtrasKey.effectSpec] != nil
                || n.el.runtimeExtras["systemMaterial"] != nil
                || n.el.backdropBlur > 0.05
            {
                return true
            }
            for child in childrenByParent[n.nodeId] ?? [] {
                if hasDynamicInSubtree(child) { return true }
            }
            return false
        }

        func hasLiveTextInSubtree(_ node: FlatNode) -> Bool {
            node.el.liveText != nil || (childrenByParent[node.nodeId] ?? []).contains(where: hasLiveTextInSubtree)
        }

        @inline(never)
        func emitTextBackdropsAndPills(
            shaped: ShapedText,
            textLeft: Float,
            textTop: Float,
            sc: Vec2,
            rasterScale: Float,
            localOpacity: Float,
            spanRadius: Float,
            defaultTextColor: Color,
            clipEdges: SIMD4<Float>,
            fade: SIMD4<UInt32>,
            forceScaled: Bool,
            cullY: (Float, Float)? = nil
        ) {
            for (bgRect, bgColor) in shaped.backgrounds {
                let c = premulSIMD4(bgColor, opacity: localOpacity, srgb: srgbBlend)
                if c.w <= 0.0005 { continue }
                // Window text culling (P2-21): skip span backgrounds outside the shown band unless rotated/cached.
                if let (lo, hi) = cullY {
                    let by = (textTop + bgRect.y * sc.y) * scale
                    let bh = bgRect.w * sc.y * scale
                    if by + bh < lo || by > hi { continue }
                }
                let r = min(max(0, spanRadius), bgRect.w * 0.5) * min(sc.x, sc.y) * scale
                instances.append(RenderInstance(
                    rect: SIMD4<Float>(
                        (textLeft + bgRect.x * sc.x) * scale,
                        (textTop + bgRect.y * sc.y) * scale,
                        bgRect.z * sc.x * scale,
                        bgRect.w * sc.y * scale
                    ),
                    radii: SIMD4<Float>(repeating: r),
                    fill: c,
                    border: .zero,
                    params: SIMD4<Float>(0, KIND_RECT, 0, 1.0),
                    uv: .zero,
                    clip: clipEdges,
                    fade: fade
                ))
                marks.append(0)
            }
            for chip in shaped.pillChips {
                let chipFill = premulSIMD4(
                    chip.background ?? Color(r: 0.22, g: 0.25, b: 0.32, a: 0.22),
                    opacity: localOpacity,
                    srgb: srgbBlend
                )
                let ringCol = chip.ring.map { premulSIMD4($0.color, opacity: localOpacity, srgb: srgbBlend) } ?? .zero
                let ringW = (chip.ring?.width ?? 0) * scale
                instances.append(RenderInstance(
                    rect: SIMD4<Float>(
                        (textLeft + chip.rect.x * sc.x) * scale,
                        (textTop + chip.rect.y * sc.y) * scale,
                        chip.rect.z * sc.x * scale,
                        chip.rect.w * sc.y * scale
                    ),
                    radii: SIMD4<Float>(repeating: chip.cornerRadius * min(sc.x, sc.y) * scale),
                    fill: chipFill,
                    border: ringCol,
                    params: SIMD4<Float>(ringW, KIND_RECT, 0, 1.0),
                    uv: .zero,
                    clip: clipEdges,
                    fade: fade
                ))
                marks.append(0)
                if let svg = chip.icon, let ir = chip.iconRect {
                    let pxSize = max(4, Int((min(ir.z, ir.w) * rasterScale * scale).rounded()))
                    let entry = textSystem.glyphAtlas.rasterizeIcon(svg, pixelSize: pxSize)
                    let tint = premulSIMD4(chip.iconColor ?? defaultTextColor, opacity: localOpacity, srgb: srgbBlend)
                    let gx = (textLeft + ir.x * sc.x) * scale
                    let gy = (textTop + ir.y * sc.y) * scale
                    let gw = max(1.0, ir.z * sc.x * scale)
                    let gh = max(1.0, ir.w * sc.y * scale)
                    let idx = instances.count
                    instances.append(RenderInstance(
                        rect: SIMD4<Float>(gx, gy, gw, gh),
                        radii: .zero,
                        fill: tint,
                        border: .zero,
                        params: SIMD4<Float>(0, KIND_GLYPH, 0, 1.0),
                        uv: entry.uv,
                        clip: clipEdges,
                        fade: fade
                    ))
                    marks.append(0)
                    glyphFixups.append((idx, entry.uv, gw, gh, entry.page, forceScaled))
                }
            }
        }

        func appendTextGlyph(_ glyph: PositionedGlyph, rect: SIMD4<Float>, ink: SIMD4<Float>,
                             clip: SIMD4<Float>, fade: SIMD4<UInt32>, forceScaled: Bool) {
            let index = instances.count
            let image = colorGlyphImage(glyph)
            if let image {
                imageFixups.append((index, image.uv, Float(image.pixelSize.x), Float(image.pixelSize.y)))
            } else {
                glyphFixups.append((index, glyph.uv, rect.z, rect.w, glyph.atlasPage, forceScaled))
            }
            instances.append(RenderInstance(
                rect: rect, radii: .zero,
                fill: image == nil ? ink : SIMD4(repeating: ink.w), border: .zero,
                params: SIMD4(0, image == nil ? KIND_GLYPH : KIND_IMAGE, 0, image == nil ? textSystem.coverageExponent(ink) : 1),
                uv: image?.uv ?? glyph.uv, clip: clip, fade: fade
            ))
            marks.append(0)
        }

        @inline(never)
        func paintNodeHeader(
            _ node: FlatNode,
            parentClip inheritedClip: RenderClipState,
            inheritedInert: Bool,
            parentOpacity: Float,
            inheritedTransform: PresentedTransform,
            parentIsDissolve: Bool,
            parentScaleMotion: PaintScaleMotion,
            parentElementIndex: Int?,
            parentInCache: Bool = false,
            parentIsRotated: Bool = false
        ) -> (
            continueSubtree: Bool,
            subtreeDynamic: Bool,
            effOpacity: Float,
            effBlur: Float,
            effRect: MotionRect,
            rectPx: SIMD4<Float>,
            radiiPx: SIMD4<Float>,
            nextInert: Bool,
            nextChildClip: RenderClipState,
            nextChildTransform: PresentedTransform,
            isDissolveScope: Bool,
            needsLayer: Bool,
            outerLayerStarts: [Int],
            cacheEligible: Bool,
            elementIndex: Int,
            layerStartIdx: Int,
            surfaceStartIdx: Int,
            glyphFixupStartIdx: Int,
            imageFixupStartIdx: Int,
            scaleMotion: PaintScaleMotion,
            activeClip: SIMD4<Float>,
            activeFade: SIMD4<UInt32>,
            effScale: Float,
            nodePaintHash: UInt64,
            elideCache: (sig: UInt64, relBounds: SIMD4<Float>, k: Float)?
        ) {
            let nid = node.nodeId
            let el = presentedGrowthElement(node)
            var parentClip = inheritedClip
            if let edge = el.stickyConfig?.edge {
                let slot: Int
                switch edge {
                case .left: slot = 0
                case .top: slot = 1
                case .bottom: slot = 3
                }
                parentClip.fadeWidth[slot] = parentClip.withoutScrollWidth[slot]
                parentClip.fadeOrigin[slot] = parentClip.withoutScrollOrigin[slot]
                parentClip.fade = packFade(width: parentClip.fadeWidth, origin: parentClip.fadeOrigin, clip: parentClip.clipPx)
            }
            let subtreeDynamic = !el.liveBindings.isEmpty
                || el.surfacePayload != nil
                || el.runtimeExtras[RenderExtrasKey.effectSpec] != nil
                || el.runtimeExtras["systemMaterial"] != nil
                || el.backdropBlur > 0.05

            var liveOpacity: Float? = nil
            var liveScale: Vec2? = nil
            var liveBlur: Float? = nil
            var liveOffset: Vec2? = nil
            var liveFill: Color?
            var liveTextColor: Color?
            var liveBorderColor: Color?
            var liveShadowColor: Color?
            var liveGradientTop: Color?
            var liveGradientBottom: Color?
            var liveRect: MotionRect? = nil
            var liveTrim: Vec2? = nil
            for b in el.liveBindings {
                let lnid = NodeId.hash("live:\(node.path):\(b.target)")
                if b.target == .opacity, let v = liveStore.get(lnid, Props.OPACITY) { liveOpacity = v }
                else if b.target == .scale, let v = liveStore.get(lnid, Props.SCALE) { liveScale = v }
                else if b.target == .blur, let bl = liveStore.get(lnid, Props.BLUR) { liveBlur = bl.radius }
                else if b.target == .offset, let o = liveStore.get(lnid, Props.OFFSET) { liveOffset = o }
                else if b.target == .trim, let tr = liveStore.get(lnid, Props.OFFSET) { liveTrim = tr }
                else if b.target == .fill { liveFill = presentedLiveColor(lnid) }
                else if b.target == .textColor { liveTextColor = presentedLiveColor(lnid) }
                else if b.target == .borderColor { liveBorderColor = presentedLiveColor(lnid) }
                else if b.target == .shadowColor { liveShadowColor = presentedLiveColor(lnid) }
                else if b.target == .gradientTop { liveGradientTop = presentedLiveColor(lnid) }
                else if b.target == .gradientBottom { liveGradientBottom = presentedLiveColor(lnid) }
                else if b.target == .rect, let r = liveStore.get(lnid, Props.RECT) { liveRect = r }
            }

            let baseRect = liveRect ?? rectMap[nid] ?? node.targetRect
            let pinh: PresentedTransform
            var inheritedSnap = parentById[nid].flatMap { childSnapByNode[$0] } ?? rootPixelSnap
            inheritedSnap.grow(growthSnapOffsetY(for: node), stack: el.growthSpec != nil)
            var anchorScaleMotion: PaintScaleMotion = .still
            if let a = el.anchor,
               let anchorNode = renderNodes.first(where: { $0.key == a.key }) ?? flatNodes.first(where: { $0.key == a.key }) {
                inheritedSnap.placeAtAnchor()
                let anchorRect = newPresentedRects[anchorNode.path]
                    ?? presentedRectByPath[anchorNode.path]
                    ?? anchorNode.zoomedTargetRect
                let anchorParentId = parentById[anchorNode.nodeId]
                    ?? anchorNode.parentIndex.flatMap { flatNodes.indices.contains($0) ? flatNodes[$0].nodeId : nil }
                let anchorParentPath: String? = anchorParentId.flatMap { (nodeById[$0] ?? exitingSnapshots[$0])?.path }
                let anchorZoom: Float = anchorParentPath.flatMap {
                    newPresentedScales[$0]?.x
                        ?? presentedScaleByPath[$0]?.x
                        ?? anchorNode.parentIndex.flatMap { flatNodes.indices.contains($0) ? flatNodes[$0].inheritedScale : nil }
                } ?? 1.0
                pinh = AnchorLayoutHelper.anchoredPaintTransform(
                    anchor: a,
                    baseRect: liveRect ?? scene.world(nid) ?? baseRect,
                    ownElScale: el.scale,
                    hasScaleTrack: anchoredOverlayHasScaleTrack(el, nodeId: nid),
                    anchorDrawnRect: anchorRect,
                    anchorInheritedZoom: anchorZoom,
                    viewport: viewport
                )
                if (abs(pinh.scale.x - 1.0) > 1e-5 || abs(pinh.scale.y - 1.0) > 1e-5),
                   let aid = anchorParentId {
                    if let cached = newPresentedScaleMotionById[aid] {
                        anchorScaleMotion = cached
                    } else if let prev = presentedScaleMotionById[aid] {
                        anchorScaleMotion = prev
                    } else if scene.store.isAnimating(aid, Props.SCALE)
                        || scene.store.isAnimating(aid, Props.UNIFORM_SCALE)
                        || scene.store.isAnimating(aid, Props.PRESENCE)
                        || scene.store.isAnimating(aid, Props.PRESS_SCALE) {
                        anchorScaleMotion = .moving
                    }
                }
            } else {
                pinh = (el.anchor == nil ? inheritedTransform : .identity)
            }
            let lo = liveOffset ?? .zero
            let baseScNoPress = scaleMap[nid] ?? el.scale
            let ownScNoPress = liveScale.map { Vec2(baseScNoPress.x * max(0, $0.x), baseScNoPress.y * max(0, $0.y)) } ?? baseScNoPress
            let pressSc = pressScaleValue(for: nid)
            let ownSc = Vec2(ownScNoPress.x * pressSc, ownScNoPress.y * pressSc)
            let sc = Vec2(pinh.scale.x * ownSc.x, pinh.scale.y * ownSc.y)
            let scNoPress = Vec2(pinh.scale.x * ownScNoPress.x, pinh.scale.y * ownScNoPress.y)
            let norm = node.anchorAttachNorm ?? el.origin
            let pivot = Vec2(baseRect.x + baseRect.width * norm.x, baseRect.y + baseRect.height * norm.y)
            let ownDx = pinh.dx + lo.x
            let ownDy = pinh.dy + lo.y
            let centre = Vec2(pivot.x + ownDx, pivot.y + ownDy)
            let centreTo = Vec2(
                pinh.anchorTo.x + (centre.x - pinh.anchor.x) * pinh.scale.x,
                pinh.anchorTo.y + (centre.y - pinh.anchor.y) * pinh.scale.y
            )
            let hasOwnScaleNoPress = abs(ownScNoPress.x - 1.0) > 1e-5 || abs(ownScNoPress.y - 1.0) > 1e-5
            let hasOwnScale = hasOwnScaleNoPress || abs(ownSc.x - 1.0) > 1e-5 || abs(ownSc.y - 1.0) > 1e-5
            let (anchor, anchorTo) = hasOwnScale ? (centre, centreTo) : (pinh.anchor, pinh.anchorTo)
            let (anchorRest, anchorRestTo) = hasOwnScaleNoPress ? (centre, centreTo) : (pinh.anchor, pinh.anchorTo)
            let extraScrollY = el.layout.scrollAxes.contains(.vertical) ? slice2State.scrollExtraYByPath[node.path] ?? 0 : 0
            let nextChildTransform = PresentedTransform(
                dx: ownDx,
                dy: ownDy - extraScrollY,
                anchor: anchor,
                anchorTo: anchorTo,
                scale: sc
            )
            let staticOffset = (rectMap[nid] == nil || liveRect != nil) ? el.offset : .zero
            let shifted = baseRect.offsetBy(Vec2(ownDx + staticOffset.x, ownDy + staticOffset.y))
            let restingRect: MotionRect
            if abs(scNoPress.x - 1.0) > 1e-5 || abs(scNoPress.y - 1.0) > 1e-5 || anchorRest != anchorRestTo {
                restingRect = MotionRect(
                    left: anchorRestTo.x + (shifted.left - anchorRest.x) * scNoPress.x,
                    top: anchorRestTo.y + (shifted.top - anchorRest.y) * scNoPress.y,
                    right: anchorRestTo.x + (shifted.right - anchorRest.x) * scNoPress.x,
                    bottom: anchorRestTo.y + (shifted.bottom - anchorRest.y) * scNoPress.y
                )
            } else {
                restingRect = shifted
            }
            var effRect: MotionRect
            if abs(sc.x - 1.0) > 1e-5 || abs(sc.y - 1.0) > 1e-5 || anchor != anchorTo {
                effRect = MotionRect(
                    left: anchorTo.x + (shifted.left - anchor.x) * sc.x,
                    top: anchorTo.y + (shifted.top - anchor.y) * sc.y,
                    right: anchorTo.x + (shifted.right - anchor.x) * sc.x,
                    bottom: anchorTo.y + (shifted.bottom - anchor.y) * sc.y
                )
            } else {
                effRect = shifted
            }
            let parentShift = parentById[nid].flatMap { id in
                (nodeById[id] ?? exitingSnapshots[id]).flatMap { stuckShiftsByPath[$0.path] }
            } ?? .zero
            var stickyShift = parentShift
            if hasSticky {
                beforeSticky[nid] = effRect
                if el.anchor != nil && !node.isSticky {
                    stickyShift = .zero
                } else if (node.isSticky || hasHolds) && nodeById[nid] != nil {
                    let offset: Vec2 = scene.store.get(nid, Props.OFFSET) ?? .zero
                    let ownOffset = Vec2(-(offset.x + lo.x) * pinh.scale.x, -(offset.y + lo.y) * pinh.scale.y)
                    let stickyBounds = effRect.offsetBy(ownOffset)
                    stickyShift = computeStickyShift(
                        nodeIndex: node.index, parentStickyShift: parentShift, nodes: flatNodes,
                        rectOf: { n in n.nodeId == nid ? stickyBounds : beforeSticky[n.nodeId] ?? n.targetRect }
                    ).shift
                }
                if stickyShift != .zero {
                    effRect = effRect.offsetBy(stickyShift)
                    stuckShiftsByPath[node.path] = stickyShift
                }
            }
            if el.pressScaleFactor != nil {
                recordPressRestingHit(path: node.path, rect: restingRect.offsetBy(stickyShift), clip: parentClip.rectPt, turn: el.rotate)
            }
            let ownScaleSpringMoving = scene.store.isUnheldAnimating(nid, Props.SCALE)
                || scene.store.isUnheldAnimating(nid, Props.UNIFORM_SCALE)
                || scene.store.isUnheldAnimating(nid, Props.PRESENCE)
                || scene.store.isUnheldAnimating(nid, Props.PRESS_SCALE)
            let ownLiveScaleMoving = el.liveBindings.contains { b in
                b.target == .scale
                    && (liveStore.isMoving(NodeId.hash("live:\(node.path):\(b.target)"), Props.SCALE) || isLinearTweenActive(b.source))
            }
            let effectiveParentScaleMotion = max(parentScaleMotion, anchorScaleMotion)
            let isOwnAnimatedScale = ownScaleSpringMoving || ownLiveScaleMoving || effectiveParentScaleMotion == .moving
            let settleResult = resolveScaleSettle(nodeId: nid, scale: sc.x, isAnimated: isOwnAnimatedScale, animNow: now)
            let nodeScaleMotion: PaintScaleMotion = max(
                effectiveParentScaleMotion,
                max(ownScaleSpringMoving ? .moving : (ownLiveScaleMoving ? .live : .still), settleResult.motion)
            )
            newPresentedScaleMotionById[nid] = nodeScaleMotion
            let rasterScale = nodeScaleMotion.raster(sc: sc.x, rest: settleResult.raster)
            let ownOpacity = nodeOwnOpacityById[nid] ?? (liveOpacity ?? opacityMap[nid] ?? el.opacity)
            let effOpacity = (parentOpacity * ownOpacity).clamped(to: 0...1)
            let effBlur = max(0, liveBlur ?? blurMap[nid] ?? el.blur)
            let isContinuousCorners = (el.runtimeExtras[RenderExtrasKey.continuousCorners] as? Bool) ?? false
            let baseRadii = SIMD4<Float>(
                el.corners.topLeft,
                el.corners.topRight,
                el.corners.bottomRight,
                el.corners.bottomLeft
            )
            let animR = radiusMap[nid]
            var radiiPt: SIMD4<Float> = animR.map { r in
                SIMD4<Float>(r.topLeft, r.topRight, r.bottomRight, r.bottomLeft)
            } ?? baseRadii
            if isContinuousCorners {
                radiiPt = SIMD4<Float>(
                    radiiPt.x > 0 ? -radiiPt.x : radiiPt.x,
                    radiiPt.y > 0 ? -radiiPt.y : radiiPt.y,
                    radiiPt.z > 0 ? -radiiPt.z : radiiPt.z,
                    radiiPt.w > 0 ? -radiiPt.w : radiiPt.w
                )
            }
            let radiiPx = radiiPt * scale

            let effInert = inheritedInert || el.isInert
            let visibleClipPt = intersectRects(parentClip.rectPt, effRect)
            newPresentedRects[node.path] = effRect
            newPresentedScales[node.path] = sc

            let isExiting = exitingIds.contains(nid)
            let parentSpringing = parentById[nid].flatMap { newRectSpringingById[$0] } ?? false
            let ownSpatialMoving =
                scene.store.isMoving(nid, Props.FRAME) ||
                scene.store.isMoving(nid, Props.TRAVEL) ||
                scene.store.isMoving(nid, Props.SCALE) ||
                scene.store.isMoving(nid, Props.UNIFORM_SCALE) ||
                scene.store.isMoving(nid, Props.OFFSET) ||
                scene.store.isMoving(nid, Props.ROTATE) ||
                scene.store.isMoving(nid, Props.PRESENCE) ||
                (!el.layout.scrollAxes.isEmpty && scrollStore.isMoving(NodeId.hash("scroll:" + node.path), Props.SCROLL))
            if !isExiting {
                let drawnArr = Self.rotatedBoundsArray(effRect, turn: el.rotate)
                newDrawnRectByPath[node.path] = MotionRect.fromXYWH(drawnArr[0], drawnArr[1], drawnArr[2], drawnArr[3])
                newRectSpringingById[nid] = parentSpringing || ownSpatialMoving
            }
            let hoverFrac = isExiting ? 0.0 : (nodeHoverFracById[nid] ?? 0.0)
            let flatFocusWithin = el.focusWithinFlat && !effInert && !isExiting && isFocusWithin(node.path)
            let hovered = !flatFocusWithin && !isExiting && (hoverFrac > 0.0005 || (!effInert && node.key != nil && hoveredKey == node.key))
            let pressed = isNodePressedVisually(path: node.path, effectiveInert: effInert || isExiting) || (!effInert && !isExiting && pressedPath != node.path && node.key != nil && pressedKey == node.key && pressedPointerInside)
            let pressTint = nodePressById[nid] ?? (nil, 0.0)
            let focused = (focusedPath == node.path) && !isExiting
            let highlightActive = focused && (focusVisible || (el.focusHighlightColor != nil && hoveredHighlightActive))

            var effBg = liveFill ?? fillMap[nid] ?? el.background
            if pressed, let pbg = el.pressBg {
                effBg = blendColorOver(bottom: effBg, top: pbg, srgb: srgbBlend)
            } else if !flatFocusWithin, let hbg = el.hoverBg {
                let effectiveHover = hoverFrac > 0.0005 ? hoverFrac : (hovered ? 1.0 : 0.0)
                if effectiveHover > 0.0005 {
                    effBg = blendColorOver(bottom: effBg, top: hbg.scaleAlpha(effectiveHover), srgb: srgbBlend)
                }
            }
            if highlightActive, let activeFocusFill = el.focusFillColor ?? el.focusHighlightColor {
                effBg = activeFocusFill
            }

            if publishHitGeometry, !isExiting, let fid = el.flightId {
                newSeenMatched[fid] = MatchedSeenSnapshot(
                    id: nid, path: node.path, rect: effRect,
                    corners: animR ?? el.corners, fill: effBg.motionColor, opacity: effOpacity
                )
                matchedFlightRegistry.recordPrevious(flightId: fid, rect: effRect)
            }

            let myElementIndex = newElements.count
            if publishHitGeometry {
                var scope = parentElementIndex.map { hitScopes[$0] } ?? RenderHitScope()
                let parentScreenClip = Self.screenClipOfParent(
                    inheritedClip: scope.localClip, ancestorTurn: scope.turn,
                    outerTurnClip: scope.outerClip, localTurnClip: scope.localClip
                )
                if abs(el.rotate) > 1e-4 {
                    let localTurn = Turn.about(effRect.center, radians: el.rotate)
                    scope.turn = scope.turn.map { $0.after(localTurn) } ?? localTurn
                    scope.outerClip = parentScreenClip
                    scope.localClip = nil
                }
                scope.opacity *= ownOpacity
                scope.exiting = scope.exiting || isExiting
                newHitGeometries[node.path] = HitGeometry(
                    path: node.path, parentPath: parentElementIndex.map { newElements[$0].path },
                    rect: effRect, clipRect: scope.localClip ?? effRect,
                    outerClip: scope.outerClip.map { intersectRects($0, initialClipPt) } ?? initialClipPt,
                    turn: scope.turn, opacity: scope.opacity, isExiting: scope.exiting,
                    hasVisualBlocker: el.blocksHits(fill: effBg, border: liveBorderColor ?? borderMap[nid] ?? el.borderColor),
                    isInteractiveBlocker: el.blocksInteractiveHits,
                    parentScreenClip: parentScreenClip
                )
                hitScopes.append(scope)
            }
            let carried = carriedScroll(for: node, scales: newPresentedScales) { newHitGeometries[$0]?.turn }
            let reportedScroll: Vec2
            if el.layout.scrollAxes.isEmpty {
                reportedScroll = carried
            } else {
                let offset = scrollOffsets[node.path] ?? .zero
                reportedScroll = Vec2(offset.x, offset.y + (slice2State.scrollExtraYByPath[node.path] ?? 0))
            }
            newElements.append(ElementInfo(
                path: node.path,
                key: node.key,
                parentIndex: parentElementIndex,
                role: el.role,
                rect: [effRect.x, effRect.y, effRect.width, effRect.height],
                target: [node.targetRect.x, node.targetRect.y, node.targetRect.width, node.targetRect.height],
                committedLayoutTarget: node.cold.committedLayoutTarget,
                visible: [visibleClipPt.x, visibleClipPt.y, visibleClipPt.width, visibleClipPt.height],
                opacity: effOpacity,
                scale: sc.x,
                blur: effBlur,
                radius: abs(radiiPt.x),
                fill: effBg,
                textColor: liveTextColor ?? el.textColor,
                text: el.plainText,
                label: el.a11yLabel ?? el.plainText,
                help: el.a11yHelp,
                selected: el.a11ySelected,
                expanded: el.a11yExpanded,
                level: el.a11yLevel,
                itemSelected: el.itemSelected,
                focusable: el.focusable && !effInert,
                focused: focused,
                focusVisible: focused && focusVisible,
                inert: effInert,
                moving: movingSet.contains(nid),
                exiting: isExiting,
                hover: isExiting ? 0 : (hoverFrac > 0 ? hoverFrac : (hovered ? 1 : 0)),
                press: pressed ? 1 : 0,
                scrolled: [reportedScroll.x, reportedScroll.y],
                carriedScrolled: [carried.x, carried.y],
                caret: nil,
                stuck: abs(stickyShift.y) >= abs(stickyShift.x) ? stickyShift.y : stickyShift.x
            ))

            if el.textHighlights != nil {
                let marks = highlightElementInfos(node: node, owner: newElements[myElementIndex], ownerIndex: myElementIndex,
                                                 rect: effRect, scaleVec: sc, visibleRect: visibleClipPt)
                newElements.append(contentsOf: marks)
                if publishHitGeometry && !marks.isEmpty {
                    hitScopes.append(contentsOf: repeatElement(hitScopes[myElementIndex], count: marks.count))
                }
            }

            let isDissolveScope = dissolveParentIds.contains(nid)
            if effOpacity <= 0.001 && !isExiting {
                return (false, subtreeDynamic, effOpacity, effBlur, effRect, .zero, .zero, effInert, parentClip, nextChildTransform, isDissolveScope, false, [], false, myElementIndex, 0, 0, 0, 0, nodeScaleMotion, NO_CLIP, .zero, sc.x * scale, 0, nil)
            }

            let exactEdgesPx = PixelSnap.edgesPx(effRect, scale: scale)
            let rawEdgesPx = PixelSnap.edgesPx(shifted, scale: scale)
            if el.anchor == nil || node.isSticky {
                inheritedSnap.shift(0, by: stickyShift.x - parentShift.x)
                inheritedSnap.shift(1, by: stickyShift.y - parentShift.y)
            }
            let rigidPx = inheritedSnap.rigid * scale
            let canSnap = !inheritedSnap.off && el.isPixelSnapEnabled && abs(el.rotate) < 1e-6
            let unscaled = abs(sc.x - 1) <= 1e-5 && abs(sc.y - 1) <= 1e-5 && anchor == anchorTo
            let opensLayer = hasOwnScale || (el.anchor != nil && !unscaled)
            let snapLayer = canSnap && opensLayer
                ? pixelSnapGlides.layer(id: nid, r: exactEdgesPx, unscaled: rawEdgesPx, rigid: rigidPx, cached: parentInCache || el.isolatedLayer)
                : inheritedSnap.layer
            let steps = inheritedSnap.steps || el.motionSnapsEnabled
            let rest = canSnap && !steps ? scene.rest(nid) : nil
            let boxGliding = canSnap && (rest != nil || !unscaled)
            let paintedEdges: SIMD4<Float>
            let snapParent: PixelSnap.Parent?
            if !canSnap {
                (paintedEdges, snapParent) = (exactEdgesPx, nil)
            } else if rest == nil && unscaled {
                (paintedEdges, snapParent) = pixelSnapGlides.atRest(id: nid, r: exactEdgesPx, rigid: rigidPx, parent: inheritedSnap.parent)
            } else {
                let growthRow = growthRows["growth:\(node.path)"] != nil || growthRows["fold:\(node.path)"] != nil
                let motion = PixelSnap.motion(rect: shifted, rest: rest, scale: scale, anchored: el.anchor != nil, growthRow: growthRow)
                (paintedEdges, snapParent) = pixelSnapGlides.snapped(
                    id: nid, motion: motion, r: exactEdgesPx, unscaled: rawEdgesPx,
                    rigid: rigidPx, layer: snapLayer, scale: sc.x, parent: inheritedSnap.parent
                )
            }
            var childSnap = inheritedSnap
            childSnap.off = !canSnap
            childSnap.steps = steps
            childSnap.layer = snapLayer
            childSnap.shifted = childSnap.shifted || el.offset != .zero
            if let origin = el.paintContain {
                childSnap.containAt(SIMD2<Float>(origin.x, origin.y))
            }
            childSnap.shift(1, by: node.virtualWindowSnapOriginY)
            childSnap.shift(0, by: -node.scrollShift.x)
            childSnap.shift(1, by: -(node.scrollShift.y + extraScrollY))
            childSnap.parent = childSnap.rigid == inheritedSnap.rigid && PixelSnap.frames(el, effectiveFill: effBg, effectiveBorder: borderMap[nid])
                ? snapParent : nil
            childSnapByNode[nid] = childSnap
            let rectPx = SIMD4<Float>(paintedEdges.x, paintedEdges.y, max(0, paintedEdges.z - paintedEdges.x), max(0, paintedEdges.w - paintedEdges.y))
            let clipSpec = el.runtimeExtras[RenderExtrasKey.clipSpec] as? RenderClipSpec
            let effectSpec = el.runtimeExtras[RenderExtrasKey.effectSpec] as? RenderEffectSpec
            let linearGradSpec = el.runtimeExtras[RenderExtrasKey.linearGradient] as? RenderLinearGradientSpec
            let radialGradSpec = el.runtimeExtras[RenderExtrasKey.radialGradient] as? RenderRadialGradientSpec
            let borderGradSpec = el.runtimeExtras[RenderExtrasKey.borderGradient] as? RenderBorderGradientSpec
            let shapeTrim = el.runtimeExtras[RenderExtrasKey.shapeTrim] as? Vec2 ?? liveTrim

            let boundsClipPx = SIMD4<Float>(rectPx.x, rectPx.y, rectPx.x + rectPx.z, rectPx.y + rectPx.w)
            // Precedence (`paint/build.rs:618-633`): explicit `clipCorners` beats `clipRadius`;
            // `clipRadius` follows element's own `corners` when non-zero, otherwise uses `clipRadius`.
            let rawClipRadiiPt: SIMD4<Float>? = clipSpec?.radii
                ?? el.clipCorners.map { SIMD4<Float>($0.topLeft, $0.topRight, $0.bottomRight, $0.bottomLeft) }
                ?? el.clipRadius.map { r in
                    baseRadii != .zero ? radiiPt : SIMD4<Float>(repeating: r)
                }
                ?? ((el.layout.clipOverflow && radiiPt != .zero) ? radiiPt : nil)
            var ownRound: (rect: SIMD4<Float>, radii: SIMD4<Float>)? = rawClipRadiiPt.map { rawR in
                let half = max(0, min(rectPx.z, rectPx.w) * 0.5)
                func resolveCorner(_ r: Float) -> Float {
                    let mag = min(max(0, abs(r)) * scale, half)
                    return ((isContinuousCorners || r < 0) && mag > 0) ? -mag : mag
                }
                return (boundsClipPx, SIMD4<Float>(resolveCorner(rawR.x), resolveCorner(rawR.y), resolveCorner(rawR.z), resolveCorner(rawR.w)))
            }
            let gKey = el.foldGlideSpec != nil ? "fold:\(node.path)" : "growth:\(node.path)"
            let skipsGrowthReveal = slice2State.joinedRowsWithoutRevealMask.contains(nid)
            let growthMaskPt: Float? = {
                guard !skipsGrowthReveal, let gEntry = growthRows[gKey] else { return nil }
                let t = gEntry.track
                let overflows = gEntry.edge.overflow && (t.streaming || t.isPaced)
                guard gEntry.edge.clip && !overflows else { return nil }
                guard t.h < t.target - 0.01 || t.mask > 0.01 || gEntry.withheld > 0.01 || t.isShuttingFold || (el.foldGlideSpec != nil && abs(t.h - t.target) > 0.25) else {
                    return nil
                }
                let withheldMask: Float = gEntry.withheld > 0.01 ? min(gEntry.withheld, gEntry.edge.floor) : 0
                let combinedMask = max(t.mask, withheldMask)
                let featherH: Float
                if combinedMask > 0.01 {
                    featherH = combinedMask
                } else if let fg = el.foldGlideSpec?.feather, abs(t.h - t.target) > 0.25 {
                    featherH = fg
                } else {
                    return nil
                }
                let clamped = min(featherH, max(1, t.h))
                return clamped > 0.01 ? (t.linearEdge ? -clamped : clamped) : nil
            }()
            let clipFadeLTRB: SIMD4<Float>? = clipSpec?.fadeLTRB
                ?? growthMaskPt.map { SIMD4<Float>(0, 0, 0, $0) }
                ?? el.clipFade
            let ownFadePx: SIMD4<Float>
            if let ltrb = clipFadeLTRB {
                ownFadePx = SIMD4<Float>(ltrb.x * scale, ltrb.y * scale, ltrb.z * scale, ltrb.w * scale)
            } else if let lin = clipSpec?.fadeLinear {
                let softDist = -max(0.5, (lin.to - lin.from) * scale)
                if abs(lin.dir.x) >= abs(lin.dir.y) {
                    ownFadePx = lin.dir.x >= 0 ? SIMD4<Float>(softDist, 0, 0, 0) : SIMD4<Float>(0, 0, softDist, 0)
                } else {
                    ownFadePx = lin.dir.y >= 0 ? SIMD4<Float>(0, softDist, 0, 0) : SIMD4<Float>(0, 0, 0, softDist)
                }
            } else {
                ownFadePx = .zero
            }

            let hasCutout = clipSpec?.cutoutCircle != nil
            let hasChildren = (childrenByParent[node.nodeId] ?? []).contains { !$0.el.isRaised }
            let hasOverlappingShape = el.shapes.count > 1 || (el.shapes.first?.ops.count ?? 0) > 1
            let opacityNeedsLayer = effOpacity > 0.001 && ownOpacity > 0.001 && ownOpacity < 1.0 && (hasChildren || hasOverlappingShape)
            let cacheRequested = (el.runtimeExtras[RenderExtrasKey.cacheEnabled] as? Bool) ?? false
            var cacheEligible = cacheRequested
                && !hasCutout
                && el.backdropBlur <= 0.05
                && el.runtimeExtras[RenderExtrasKey.effectSpec] == nil
                && el.runtimeExtras["systemMaterial"] == nil
                && !hasDynamicInSubtree(node)
            let effScale = sc.x * scale
            var nodePaintHash: UInt64 = 0xCBF2_9CE4_8422_2325
            if cacheEligible {
                fnvMixFloat(&nodePaintHash, inheritedSnap.rigid.x)
                fnvMixFloat(&nodePaintHash, inheritedSnap.rigid.y)
                fnvMixFloat(&nodePaintHash, inheritedSnap.steady.x)
                fnvMixFloat(&nodePaintHash, inheritedSnap.steady.y)
                fnvMixFloat(&nodePaintHash, inheritedSnap.contain.x)
                fnvMixFloat(&nodePaintHash, inheritedSnap.contain.y)
            }
            fnvMixFloat(&nodePaintHash, effBlur)
            fnvMixFloat(&nodePaintHash, effOpacity)
            fnvMixFloat(&nodePaintHash, scale)
            fnvMix(&nodePaintHash, srgbBlend ? 1 : 0)
            fnvMix(&nodePaintHash, focusVisible ? 1 : 0)
            fnvMix(&nodePaintHash, hovered ? 1 : 0)
            fnvMix(&nodePaintHash, pressed ? 1 : 0)
            fnvMix(&nodePaintHash, focused ? 1 : 0)
            var elideCache: (sig: UInt64, relBounds: SIMD4<Float>, k: Float)? = nil
            if cacheEligible, var entry = elSliceRenderState.nodeCaches[nid], entry.commitGen != commitGen {
                if abs(effScale - entry.rasterScale) > 1e-4 {
                    let anotherFrame = ElNodeCacheEntry.stepScaleSettle(
                        seenScale: &entry.scale,
                        since: &entry.since,
                        to: effScale,
                        now: now,
                        reset: false,
                        poll: true
                    )
                    if anotherFrame {
                        entry.isLivePhase = true
                        elSliceRenderState.nodeCaches[nid] = entry
                        elSliceRenderState.cacheScaleFramePending = true
                        cacheEligible = false
                    } else {
                        elSliceRenderState.nodeCaches[nid] = entry
                    }
                }
            }
            if cacheEligible, var entry = elSliceRenderState.nodeCaches[nid] {
                let sameCommit = (commitGen == entry.commitGen)
                let envSame = abs(scale - entry.envScale) <= 1e-4
                let scaleDiff = abs(effScale - entry.rasterScale) > 1e-4
                let isResident = residentCacheTracker.isResident(nodeId: nid.rawValue, signature: entry.signature)
                let eligible = sameCommit && scaleDiff && envSame && isResident && !entry.isLivePhase
                let pending = ElNodeCacheEntry.stepScaleSettle(
                    seenScale: &entry.scale,
                    since: &entry.since,
                    to: effScale,
                    now: now,
                    reset: !envSame,
                    poll: eligible
                )
                let scaleSettling = eligible && (pending || nodeScaleMotion == .moving)
                if scaleSettling { elSliceRenderState.cacheScaleFramePending = true }
                if scaleSettling && entry.paintHash == nodePaintHash && !hasLiveTextInSubtree(node) {
                    elideCache = (
                        entry.signature,
                        entry.relBounds,
                        effScale / max(1e-4, entry.rasterScale)
                    )
                }
                elSliceRenderState.nodeCaches[nid] = entry
            }

            var rectClip = (ownRound == nil && (el.layout.clipOverflow || (clipSpec?.clipRect ?? false) || clipFadeLTRB != nil || clipSpec?.fadeLinear != nil))
                ? intersectClipRects(parentClip.clipPx, boundsClipPx)
                : parentClip.clipPx
            var mergedFadeWidth = parentClip.fadeWidth
            var mergedFadeOrigin = parentClip.fadeOrigin
            let hasClipScope = el.layout.clipOverflow || (clipSpec?.clipRect ?? false) || ownRound != nil || clipFadeLTRB != nil || clipSpec?.fadeLinear != nil
            if publishHitGeometry && hasClipScope {
                hitScopes[myElementIndex].localClip = hitScopes[myElementIndex].localClip.map {
                    intersectRects($0, effRect)
                } ?? effRect
            }
            if hasClipScope && ownFadePx != .zero {
                inheritFade(width: &mergedFadeWidth, origin: &mergedFadeOrigin, rect: boundsClipPx, own: ownFadePx)
            }

            let savedUnclippedClip = hasClipScope || !el.layout.scrollAxes.isEmpty
                ? intersectClipRects(rectClip, boundsClipPx) : rectClip

            var activeRounded = parentClip.roundedMask
            trimCentralStrip(&activeRounded, clip: &rectClip)
            if !cacheEligible {
                trimCentralStrip(&ownRound, clip: &rectClip)
            }

            // 1. Backdrop blur (`KIND_BACKDROP_BLUR = 13`): emitted ahead of element's layer & shadows (`slots.rs` + `build.rs:654`).
            var blurHole: Float? = nil
            if el.backdropBlur > 0.05 && rectPx.z > 0.5 && rectPx.w > 0.5 && effOpacity > 0.001 {
                var blurClip = parentClip.clipPx
                var roundRadii: SIMD4<Float>? = nil
                if let (mask, roundR) = parentClip.roundedMask {
                    let cut = intersectClipRects(blurClip, mask)
                    if cut == mask {
                        blurClip = mask
                        roundRadii = roundR
                    } else {
                        blurClip = cut
                    }
                }
                var blurInst = RenderInstance(
                    rect: rectPx,
                    radii: radiiPx,
                    fill: SIMD4<Float>(0, 0, 0, effOpacity),
                    border: .zero,
                    params: SIMD4<Float>(el.backdropBlur * scale, KIND_BACKDROP_BLUR, 0, scale),
                    uv: .zero,
                    clip: blurClip,
                    fade: parentClip.fade
                )
                if let roundR = roundRadii {
                    blurInst.roundClipCorners(roundR)
                }
                instances.append(blurInst)
                marks.append(0)
                blurHole = clampSignedCornerRadius(radiiPx, width: rectPx.z, height: rectPx.w)
            }

            let layerStartIdx = instances.count
            let surfaceStartIdx = newSurfaces.count
            let glyphFixupStartIdx = glyphFixups.count
            let imageFixupStartIdx = imageFixups.count
            let markStartIdx = marks.count
            var outerLayerStarts: [Int] = []

            var scopeFadeWidth = mergedFadeWidth
            var scopeFadeOrigin = mergedFadeOrigin
            var scopeBaseFade: SIMD4<UInt32> = (scopeFadeWidth != .zero || parentClip.fade != .zero)
                ? packFade(width: scopeFadeWidth, origin: scopeFadeOrigin, clip: rectClip)
                : .zero

            // Outer split 1: preserve a rectangular cut through a rounded corner without recentering corners (`build.rs:661-670`).
            if let (mask, _) = activeRounded ?? ownRound, intersectClipRects(rectClip, mask) != mask {
                outerLayerStarts.append(instances.count)
                var marker = RenderInstance.beginLayer(
                    bounds: rectPx,
                    clip: rectClip,
                    spec: LayerSpec(opacity: 1.0, blend: .sourceOver, blur: 0, clipRadius: 0)
                )
                marker.fade = scopeBaseFade
                instances.append(marker)
                marks.append(0)
                rectClip = NO_CLIP
                scopeFadeWidth = .zero
                scopeFadeOrigin = NO_CLIP
                scopeBaseFade = .zero
            }

            // Outer split 2: nested distinct rounded masks consume ancestor on an outer layer (`build.rs:671-681`).
            if let anc = activeRounded, let own = ownRound, (anc.rect != own.rect || anc.radii != own.radii) {
                outerLayerStarts.append(instances.count)
                var marker = RenderInstance.beginLayer(
                    bounds: rectPx,
                    clip: anc.rect,
                    spec: LayerSpec(opacity: 1.0, blend: .sourceOver, blur: 0, clipRadius: 0)
                )
                marker.fade = packFade(width: scopeFadeWidth, origin: scopeFadeOrigin, clip: anc.rect)
                marker.roundClipCorners(anc.radii)
                instances.append(marker)
                marks.append(0)
                activeRounded = nil
                rectClip = NO_CLIP
                scopeFadeWidth = .zero
                scopeFadeOrigin = NO_CLIP
                scopeBaseFade = .zero
            }

            if let own = ownRound {
                activeRounded = own
            }
            if let (mask, _) = activeRounded {
                rectClip = intersectClipRects(rectClip, mask)
                scopeBaseFade = scopeFadeWidth != .zero
                    ? packFade(width: scopeFadeWidth, origin: scopeFadeOrigin, clip: rectClip)
                    : .zero
            }

            // Live/truncated text clear of rounded corners can skip isolation and the rounded corner SDF (`build.rs:701-705`).
            var glyphsClear = false
            if let (mask, roundR) = activeRounded,
               ((el.plainText?.isEmpty == false) || (el.richSpans?.isEmpty == false) || el.advanceInRun != nil),
               (el.liveText != nil || el.isTruncateFadeEnabled)
            {
                let textLeft = effRect.x + el.layout.padding.left * sc.x
                let textTop = effRect.y + el.layout.padding.top * sc.y
                let boxW = max(0, effRect.width - (el.layout.padding.left + el.layout.padding.right) * sc.x) * scale
                let boxH = max(0, effRect.height - (el.layout.padding.top + el.layout.padding.bottom) * sc.y) * scale
                let textClipRect = intersectClipRects(rectClip, SIMD4<Float>(textLeft * scale, textTop * scale, textLeft * scale + boxW, textTop * scale + boxH))
                glyphsClear = insideRounded(textClipRect, mask: mask, radii: roundR)
            }

            let ownPaintsCount: Int = {
                let effBorder = liveBorderColor ?? borderMap[nid] ?? (borderGradSpec?.top ?? el.borderColor)
                let hasGrad = radialGradSpec != nil || linearGradSpec != nil || el.gradient != nil
                var c = 0
                if !hasGrad && effBg.a > 0.001 { c += 1 }
                if el.borderWidth > 0 && (effBorder.a > 0.001 || borderGradSpec != nil) { c += 1 }
                if hasGrad || el.surfacePayload != nil { c += 1 }
                if !el.shapes.isEmpty { c += 1 }
                if el.imagePayload != nil || el.pixelsPayload != nil { c += 1 }
                if !el.shadows.isEmpty { c += 1 }
                if (el.plainText?.isEmpty == false) || (el.richSpans?.isEmpty == false) || el.iconPayload != nil { c += 1 }
                return c
            }()
            let fadeNeedsLayer = effOpacity > 0.001
                && scopeFadeWidth != .zero
                && inFade(boundsClipPx, clip: rectClip, width: scopeFadeWidth, origin: scopeFadeOrigin)
                && (ownPaintsCount >= 2 || (ownPaintsCount == 1 && hasChildren))
            let roundedTextNeedsLayer = activeRounded != nil && (
                (el.isSingleLineInput && el.handlers.editLens != nil)
                || (((el.plainText?.isEmpty == false) || (el.richSpans?.isEmpty == false) || el.advanceInRun != nil)
                    && (el.liveText != nil || el.isTruncateFadeEnabled)
                    && !glyphsClear)
            )

            let layerOp = el.elLayerOpacity
            let paintEffOpacity = (effOpacity * layerOp).clamped(to: 0...1)
            let layerOpacityNeedsLayer = paintEffOpacity > 0.001 && paintEffOpacity < 0.999 && layerOp < 0.999 && (hasChildren || ownPaintsCount >= 2)
            let needsLayer = el.isolatedLayer || cacheEligible || effBlur > 0.05 || abs(el.rotate) > 1e-4 || hasCutout || isDissolveScope || parentIsDissolve || opacityNeedsLayer || fadeNeedsLayer || roundedTextNeedsLayer || layerOpacityNeedsLayer

            var nextChildClip: RenderClipState
            if needsLayer {
                // Inner draws clip tightly to boundsPx inside layer; layer composite applies rounded/feathered mask!
                nextChildClip = RenderClipState(rectPt: visibleClipPt, clipPx: NO_CLIP, fadeWidth: .zero, fadeOrigin: NO_CLIP, fade: .zero, roundedMask: nil)
            } else if hasClipScope {
                var childClip = rectClip
                if ownRound != nil && (el.layout.clipOverflow || (clipSpec?.clipRect ?? false)) {
                    childClip = intersectClipRects(childClip, boundsClipPx)
                }
                nextChildClip = RenderClipState(
                    rectPt: visibleClipPt,
                    clipPx: childClip,
                    fadeWidth: scopeFadeWidth,
                    fadeOrigin: scopeFadeOrigin,
                    fade: scopeBaseFade,
                    roundedMask: activeRounded
                )
            } else {
                nextChildClip = RenderClipState(
                    rectPt: visibleClipPt,
                    clipPx: rectClip,
                    fadeWidth: scopeFadeWidth,
                    fadeOrigin: scopeFadeOrigin,
                    fade: scopeBaseFade,
                    roundedMask: activeRounded
                )
            }

            var withoutScrollWidth = parentClip.withoutScrollWidth
            var withoutScrollOrigin = parentClip.withoutScrollOrigin
            if needsLayer || !outerLayerStarts.isEmpty {
                withoutScrollWidth = .zero
                withoutScrollOrigin = NO_CLIP
            } else if ownFadePx != .zero {
                inheritFade(width: &withoutScrollWidth, origin: &withoutScrollOrigin, rect: boundsClipPx, own: ownFadePx)
            }
            // Keep the outer fade on a sticky edge, including explicit clips between the
            // viewport and its header. Scroll ramps apply to content inside the viewport.
            let axes = el.layout.scrollAxes
            if !axes.isEmpty {
                nextChildClip.clipPx = intersectClipRects(nextChildClip.clipPx, boundsClipPx)
                for slot in 0..<4 where axes.contains(slot == 0 || slot == 2 ? .horizontal : .vertical) {
                    withoutScrollWidth[slot] = nextChildClip.fadeWidth[slot]
                    withoutScrollOrigin[slot] = nextChildClip.fadeOrigin[slot]
                }
                if let ramp = node.ownScrollFade {
                    let widths = ramp.widths * SIMD4<Float>(sc.x, sc.y, sc.x, sc.y) * scale
                    let offset = ramp.packedOffsets ?? .zero
                    let origin = boundsClipPx + SIMD4<Float>(-abs(widths.x), -abs(widths.y), abs(widths.z), abs(widths.w)) * offset
                    inheritFade(width: &nextChildClip.fadeWidth, origin: &nextChildClip.fadeOrigin, rect: origin, own: widths)
                    inheritFade(width: &mergedFadeWidth, origin: &mergedFadeOrigin, rect: origin, own: widths)
                }
                nextChildClip.fade = packFade(width: nextChildClip.fadeWidth, origin: nextChildClip.fadeOrigin, clip: nextChildClip.clipPx)
            }
            nextChildClip.withoutScrollWidth = withoutScrollWidth
            nextChildClip.withoutScrollOrigin = withoutScrollOrigin

            let scopeRoundFade: SIMD4<UInt32>
            if !needsLayer, let (mask, roundR) = activeRounded {
                scopeRoundFade = SIMD4<UInt32>(scopeBaseFade.x, scopeBaseFade.y, scopeBaseFade.z, packClipRadii(clip: mask, radii: roundR))
            } else {
                scopeRoundFade = scopeBaseFade
            }
            let activeClip = needsLayer ? NO_CLIP : rectClip
            let activeFade = needsLayer ? SIMD4<UInt32>.zero : scopeRoundFade
            let activeGlyphBaseFade = (needsLayer || glyphsClear) ? (needsLayer ? SIMD4<UInt32>.zero : scopeBaseFade) : scopeRoundFade
            let rawLocalOpacity = needsLayer ? 1.0 : paintEffOpacity
            let localOpacity = (rawLocalOpacity * el.elPaintAlpha).clamped(to: 0...1)

            savedNodeStates[node.nodeId] = SavedRaisedNodeState(
                elementIndex: myElementIndex,
                visibleClipPt: visibleClipPt,
                unclippedClipPx: savedUnclippedClip,
                unclippedFadeWidth: mergedFadeWidth,
                unclippedFadeOrigin: mergedFadeOrigin,
                unclippedFade: packFade(width: mergedFadeWidth, origin: mergedFadeOrigin, clip: savedUnclippedClip),
                withoutScrollWidth: withoutScrollWidth,
                withoutScrollOrigin: withoutScrollOrigin,
                effOpacity: effOpacity,
                nextInert: effInert,
                nextChildTransform: nextChildTransform,
                isDissolveScope: isDissolveScope,
                scaleMotionRaw: nodeScaleMotion.rawValue,
                rectPx: rectPx,
                boundsClipPx: boundsClipPx,
                ownClipRadiiPx: ownRound?.radii,
                rotate: el.rotate,
                outerTurnClip: parentClip.clipPx
            )

            if needsLayer {
                var layerFade = scopeBaseFade
                if let (_, roundR) = activeRounded {
                    layerFade = SIMD4<UInt32>(layerFade.x, layerFade.y, layerFade.z, packClipRadii(clip: rectClip, radii: roundR))
                }
                var scopeInst = RenderInstance.beginLayer(
                    bounds: rectPx,
                    clip: rectClip,
                    spec: LayerSpec(opacity: paintEffOpacity, blend: isDissolveScope ? .plusLighter : .sourceOver, blur: effBlur * scale, clipRadius: 0)
                )
                scopeInst.fade = layerFade
                if let hole = clipSpec?.cutoutCircle {
                    let f = max(1.0, hole.feather * scale)
                    let r = max(0, hole.radius * scale)
                    scopeInst.radii = SIMD4<Float>((effRect.x + hole.cx) * scale, (effRect.y + hole.cy) * scale, r, r + f)
                }
                if abs(el.rotate) > 1e-4 {
                    scopeInst = scopeInst.turned(
                        angle: el.rotate,
                        pivot: SIMD2<Float>(rectPx.x + rectPx.z * 0.5, rectPx.y + rectPx.w * 0.5)
                    )
                }
                instances.append(scopeInst)
                marks.append(0)
            }

            // 2. System material slot registration (ahead of outer shadows so `nativeMaterialHole` clears shadow interior)
            var nativeMaterialHole: Float? = nil
            var paintBg: Color = effBg
            var shapeRadiiPx: SIMD4<Float> = radiiPx
            if let mat = el.runtimeExtras["systemMaterial"] as? SystemMaterial {
                let blending = (el.runtimeExtras["systemMaterialBlending"] as? MaterialBlendingMode) ?? .behindWindow
                let isContinuous = (mat == .glass) || (radiiPt.x < 0 || radiiPt.y < 0 || radiiPt.z < 0 || radiiPt.w < 0)
                if mat == .glass {
                    shapeRadiiPx = SIMD4<Float>(
                        -abs(radiiPx.x),
                        -abs(radiiPx.y),
                        -abs(radiiPx.z),
                        -abs(radiiPx.w)
                    )
                }
                let rPx = MaterialMath.clampRadius(
                    [radiiPx.x, radiiPx.y, radiiPx.z, radiiPx.w],
                    width: rectPx.z,
                    height: rectPx.w
                )
                if useNativeMaterials && materials.count < MAX_NATIVE_MATERIALS {
                    let matDraw = MaterialDraw(
                        id: nid.rawValue,
                        material: mat,
                        blending: blending,
                        rect: MotionRect(
                            left: rectPx.x,
                            top: rectPx.y,
                            right: rectPx.x + rectPx.z,
                            bottom: rectPx.y + rectPx.w
                        ),
                        radius: rPx,
                        continuous: isContinuous,
                        opacity: paintEffOpacity * el.elPaintAlpha
                    )
                    materials.append(matDraw)
                    nativeMaterialHole = isContinuous ? -rPx : rPx
                    paintBg = Color(r: 0, g: 0, b: 0, a: 0)
                } else {
                    let baseFill: SIMD4<Float>? = effBg.a > 0.001
                        ? SIMD4<Float>(effBg.r, effBg.g, effBg.b, effBg.a)
                        : nil
                    let fb = MaterialMath.fallbackFill(material: mat, fill: baseFill, dark: systemDark, opacity: 1.0)
                    paintBg = Color(r: fb.x, g: fb.y, b: fb.z, a: fb.w)
                }
            }

            // 3. Outer drop shadows (`runtime/paint/shadow.rs`)
            let shadows = resolvedShadows(for: nid, authored: el.shadows)
            let flatFocusWithinShadows = el.focusWithinFlat && !effInert && !isExiting && isFocusWithin(node.path)
            let castsShadow = !flatFocusWithinShadows && !shadows.isEmpty && blurHole == nil
            let fillA = castsShadow ? paintBg.a : 0.0
            let solidFill = castsShadow && fillA >= 1.0
            let opaqueForBands = solidFill && localOpacity >= 1.0 && linearGradSpec == nil && radialGradSpec == nil && el.gradient == nil && el.surfacePayload == nil
            let seeThroughFill = castsShadow && fillA > 0.0 && fillA < 1.0
            let dimHole: Float? = ((solidFill && localOpacity < 1.0) || seeThroughFill)
                ? clampSignedCornerRadius(shapeRadiiPx, width: rectPx.z, height: rectPx.w)
                : nil
            let shadowHole = nativeMaterialHole ?? blurHole ?? dimHole
            let circularRadiiPx = SIMD4<Float>(abs(shapeRadiiPx.x), abs(shapeRadiiPx.y), abs(shapeRadiiPx.z), abs(shapeRadiiPx.w))

            if !flatFocusWithinShadows {
                for (sIdx, sh) in shadows.enumerated() where !sh.inset {
                let sp = sh.spread * scale
                let sr = SIMD4<Float>(
                    rectPx.x + sh.x * scale - sp,
                    rectPx.y + sh.y * scale - sp,
                    max(0, rectPx.z + 2 * sp),
                    max(0, rectPx.w + 2 * sp)
                )
                let sradii = SIMD4<Float>(
                    circularRadiiPx.x > 0 ? max(0, circularRadiiPx.x + sp) : 0,
                    circularRadiiPx.y > 0 ? max(0, circularRadiiPx.y + sp) : 0,
                    circularRadiiPx.z > 0 ? max(0, circularRadiiPx.z + sp) : 0,
                    circularRadiiPx.w > 0 ? max(0, circularRadiiPx.w + sp) : 0
                )
                let shColor = (sIdx == 0 ? liveShadowColor : nil) ?? (sIdx < shadowColorProps.count ? scene.store.get(nid, shadowColorProps[sIdx]).map(Color.init) : nil) ?? sh.color
                let fill = premulSIMD4(shColor, opacity: localOpacity, srgb: srgbBlend)
                let ring = (sh.x == 0 && sh.y == 0)
                if sh.blur <= 0.0 && (ring || shadowHole == nil) {
                    if ring && sp <= 0.0 { continue }
                    instances.append(RenderInstance(
                        rect: sr,
                        radii: sradii,
                        fill: ring ? .zero : fill,
                        border: ring ? fill : .zero,
                        params: SIMD4<Float>(ring ? sp : 0.0, KIND_RECT, 0.0, 1.0),
                        uv: .zero,
                        clip: activeClip,
                        fade: activeFade
                    ))
                    marks.append(0)
                    continue
                }
                let finalRadii: SIMD4<Float>
                let finalUV: SIMD4<Float>
                if let hole = shadowHole {
                    finalRadii = SIMD4<Float>(sradii.x, sradii.y, sradii.z, hole)
                    finalUV = SIMD4<Float>(rectPx.x - sr.x, rectPx.y - sr.y, rectPx.z, rectPx.w)
                } else {
                    finalRadii = sradii
                    finalUV = .zero
                }
                let shadowInst = RenderInstance(
                    rect: sr,
                    radii: finalRadii,
                    fill: fill,
                    border: .zero,
                    params: SIMD4<Float>(0, KIND_SHADOW, max(0.5, sh.blur * scale * 0.5), 1.0),
                    uv: finalUV,
                    clip: activeClip,
                    fade: activeFade
                )
                if opaqueForBands {
                    PaintBands.pushShadow(into: &instances, marks: &marks, inst: shadowInst, caster: rectPx, radii: radiiPx)
                } else {
                    instances.append(shadowInst)
                    marks.append(0)
                }
                }
            }

            // 4. Background fill, multi-stop gradients, and borders
            let bwPx = borderGradSpec.map { snapBorderWidthPx($0.width, scale: scale) }
                ?? snapBorderWidthPx(el.borderWidth, scale: scale)
            let hasSolidBg = paintBg.a > 0.001
            let softEdge = max(0.5, (clipSpec?.soft ?? 0) * scale)
            // Dimmed, an opaque fill and its linear gradient draw as one opaque gradient (`paint/build.rs:926`).
            let flatDimLinearGradient: Bool = {
                guard hasSolidBg && paintBg.a >= 0.999 && localOpacity < 0.999 else { return false }
                if case .linear = el.gradient, radialGradSpec == nil, linearGradSpec == nil {
                    return true
                }
                return false
            }()
            let hasAnyGradient = radialGradSpec != nil || linearGradSpec != nil || el.gradient != nil
            if hasSolidBg && hasAnyGradient && !flatDimLinearGradient {
                instances.append(RenderInstance(
                    rect: rectPx,
                    radii: shapeRadiiPx,
                    fill: premulSIMD4(paintBg, opacity: localOpacity, srgb: srgbBlend),
                    border: .zero,
                    params: SIMD4<Float>(0, KIND_RECT, softEdge, 1.0),
                    uv: .zero,
                    clip: activeClip,
                    fade: activeFade
                ))
                marks.append(0)
            }

            if let rGrad = radialGradSpec, !rGrad.stops.isEmpty {
                let centerLocal = Vec2(rGrad.center.x * effRect.width, rGrad.center.y * effRect.height)
                if let (rxPt, ryPt) = resolveRadialRadii(rGrad.radius, centerLocal: centerLocal, size: Vec2(effRect.width, effRect.height)) {
                    let animatedStops: [GradientStop] = rGrad.stops.prefix(16).enumerated().map { idx, stop in
                        let c = scene.store.get(nid, radialStopProps[idx]).map(Color.init) ?? stop.color
                        return GradientStop(c, at: stop.offset)
                    }
                    let uv = SIMD4<Float>(centerLocal.x * scale, centerLocal.y * scale, rxPt * scale, ryPt * scale)
                    emitStopSpans(
                        stops: animatedStops,
                        rect: rectPx,
                        radii: shapeRadiiPx,
                        uv: uv,
                        clip: activeClip,
                        fade: activeFade,
                        soft: softEdge,
                        blurPx: (clipSpec?.soft ?? 0) * scale,
                        opacity: localOpacity,
                        srgb: srgbBlend,
                        into: &instances,
                        marks: &marks
                    )
                }
            } else if let lGrad = linearGradSpec, !lGrad.stops.isEmpty {
                let ux = sinf(lGrad.angleRadians)
                let uy = -cosf(lGrad.angleRadians)
                let span = max(1e-3, abs(ux) * rectPx.z + abs(uy) * rectPx.w)
                let uv = SIMD4<Float>(ux / span, uy / span, 0, 0)
                emitStopSpans(
                    stops: Array(lGrad.stops.prefix(16)),
                    rect: rectPx,
                    radii: shapeRadiiPx,
                    uv: uv,
                    clip: activeClip,
                    fade: activeFade,
                    soft: softEdge,
                    opacity: localOpacity,
                    srgb: srgbBlend,
                    into: &instances,
                    marks: &marks
                )
            } else if let grad = el.gradient {
                switch grad {
                case let .linear(authoredTop, authoredBottom, angle):
                    let top = liveGradientTop ?? authoredTop
                    let bottom = liveGradientBottom ?? authoredBottom
                    if abs(cosf(angle)) < 0.05 && borderGradSpec == nil {
                        let tRaw = angle >= 0 ? top : bottom
                        let bRaw = angle >= 0 ? bottom : top
                        let tCol = flatDimLinearGradient ? blendColorOver(bottom: paintBg, top: tRaw, srgb: srgbBlend) : tRaw
                        let bCol = flatDimLinearGradient ? blendColorOver(bottom: paintBg, top: bRaw, srgb: srgbBlend) : bRaw
                        instances.append(RenderInstance(
                            rect: rectPx,
                            radii: radiiPx,
                            fill: premulSIMD4(tCol, opacity: localOpacity, srgb: srgbBlend),
                            border: .zero,
                            params: SIMD4<Float>(0, KIND_GRADIENT, softEdge, 1.0),
                            uv: premulSIMD4(bCol, opacity: localOpacity, srgb: srgbBlend),
                            clip: activeClip,
                            fade: activeFade
                        ))
                        marks.append(0)
                    } else {
                        let ux = cosf(angle)
                        let uy = sinf(angle)
                        let span = max(1e-3, abs(ux) * rectPx.z + abs(uy) * rectPx.w)
                        emitStopSpans(
                            stops: [GradientStop(top, at: 0), GradientStop(bottom, at: 1)],
                            rect: rectPx,
                            radii: radiiPx,
                            uv: SIMD4<Float>(ux / span, uy / span, 0, 0),
                            clip: activeClip,
                            fade: activeFade,
                            soft: softEdge,
                            opacity: localOpacity,
                            srgb: srgbBlend,
                            into: &instances,
                            marks: &marks
                        )
                    }
                case let .radial(authoredInner, authoredOuter):
                    let inner = liveGradientTop ?? authoredInner
                    let outer = liveGradientBottom ?? authoredOuter
                    let uv = SIMD4<Float>(rectPx.z * 0.5, rectPx.w * 0.5, max(1e-3, rectPx.z * 0.5), max(1e-3, rectPx.w * 0.5))
                    emitStopSpans(
                        stops: [GradientStop(inner, at: 0), GradientStop(outer, at: 1)],
                        rect: rectPx,
                        radii: radiiPx,
                        uv: uv,
                        clip: activeClip,
                        fade: activeFade,
                        soft: softEdge,
                        opacity: localOpacity,
                        srgb: srgbBlend,
                        into: &instances,
                        marks: &marks
                    )
                }
            }

            let effBorderColor = liveBorderColor ?? borderMap[nid] ?? (borderGradSpec?.top ?? el.borderColor)
            let springingBottom = scene.store.has(nid, Props.BORDER_BOTTOM)
                && (scene.store.isAnimating(nid, Props.BORDER_BOTTOM) || scene.store.isAnimating(nid, Props.BORDER))
            let topPremul = premulSIMD4(effBorderColor, opacity: localOpacity, srgb: srgbBlend)
            let borderBottomColor: Color? = (bwPx > 0 && (borderGradSpec != nil || springingBottom))
                ? (scene.store.get(nid, Props.BORDER_BOTTOM).map(Color.init) ?? borderGradSpec?.bottom ?? effBorderColor)
                : nil
            let borderBottomPremul: SIMD4<Float>? = borderBottomColor.flatMap { c in
                let p = premulSIMD4(c, opacity: localOpacity, srgb: srgbBlend)
                return (borderGradSpec != nil || p != topPremul) ? p : nil
            }

            // Border & solid fill handling
            let fillPaintedByGrad = radialGradSpec != nil || linearGradSpec != nil || el.gradient != nil
            // Video and other native pictures sit above the box fill but below its border,
            // inset shadows, effect slots and children (runtime/paint/build.rs).
            let hasSurface = el.surfacePayload != nil
            if let (surface, fit) = el.surfacePayload {
                if hasSolidBg && !fillPaintedByGrad {
                    instances.append(RenderInstance(
                        rect: rectPx, radii: shapeRadiiPx,
                        fill: premulSIMD4(paintBg, opacity: localOpacity, srgb: srgbBlend), border: .zero,
                        params: SIMD4<Float>(0, KIND_RECT, softEdge, 1), uv: .zero, clip: activeClip, fade: activeFade
                    ))
                    marks.append(0)
                }
                surfaceVideo.snapshot(surface, path: node.path)
                let visible = rectPx.x < activeClip.z && rectPx.y < activeClip.w
                    && rectPx.x + rectPx.z > activeClip.x && rectPx.y + rectPx.w > activeClip.y
                if visible {
                    surfaceVideo.pull(surface, at: now, wallTime: currentTime, waker: waker)
                    newSurfaces.append(SurfaceDraw(
                        surface: surface.placed(el.surfacePlace), fit: fit, beforeInstance: UInt32(instances.count),
                        rect: rectPx, radii: radiiPx, clip: activeClip, clipFade: activeFade, opacity: localOpacity
                    ))
                } else {
                    surfaceVideo.unpulled(surface)
                }
            }
            if let dash = el.dashedBorder, bwPx > 0 && (effBorderColor.a > 0.001 || (borderBottomColor?.a ?? 0) > 0.001) {
                if hasSolidBg && !fillPaintedByGrad && !hasSurface {
                    instances.append(RenderInstance(
                        rect: rectPx,
                        radii: shapeRadiiPx,
                        fill: premulSIMD4(paintBg, opacity: localOpacity, srgb: srgbBlend),
                        border: .zero,
                        params: SIMD4<Float>(0, KIND_RECT, softEdge, 1.0),
                        uv: .zero,
                        clip: activeClip,
                        fade: activeFade
                    ))
                    marks.append(0)
                }
                instances.append(RenderInstance(
                    rect: rectPx,
                    radii: shapeRadiiPx,
                    fill: topPremul,
                    border: borderBottomPremul ?? topPremul,
                    params: SIMD4<Float>(bwPx, KIND_DASHED, softEdge, 1.0),
                    uv: SIMD4<Float>(max(1, dash.dash * scale), max(1, dash.gap * scale), dash.phase * scale, 0),
                    clip: activeClip,
                    fade: activeFade
                ))
                marks.append(0)
            } else if let bottomPremul = borderBottomPremul, bwPx > 0 {
                let bgPremul = fillPaintedByGrad || hasSurface ? .zero : premulSIMD4(paintBg, opacity: localOpacity, srgb: srgbBlend)
                instances.append(RenderInstance(
                    rect: rectPx,
                    radii: shapeRadiiPx,
                    fill: bgPremul,
                    border: topPremul,
                    params: SIMD4<Float>(bwPx, KIND_GRADIENT, softEdge, 1.0),
                    uv: bottomPremul,
                    clip: activeClip,
                    fade: activeFade
                ))
                marks.append(0)
            } else if !fillPaintedByGrad && ((hasSolidBg && !hasSurface) || (bwPx > 0 && effBorderColor.a > 0.001)) {
                let sidesVec: SIMD4<Float>
                if let s = el.borderSides {
                    sidesVec = SIMD4<Float>(
                        snapBorderWidthPx(s.top, scale: scale),
                        snapBorderWidthPx(s.right, scale: scale),
                        snapBorderWidthPx(s.bottom, scale: scale),
                        snapBorderWidthPx(s.left, scale: scale)
                    )
                } else {
                    sidesVec = .zero
                }
                var fill: SIMD4<Float> = hasSurface ? .zero : premulSIMD4(paintBg, opacity: localOpacity, srgb: srgbBlend)
                if srgbBlend && el.borderWidth == 0 && bwPx == 0 && sidesVec == .zero
                    && el.surfacePayload == nil && fill.w < 1 {
                    // Preserve the transfer curve's exact white endpoint before byte blending.
                    if paintBg.r == 1 { fill.x = fill.w }
                    if paintBg.g == 1 { fill.y = fill.w }
                    if paintBg.b == 1 { fill.z = fill.w }
                }
                let rectInst = RenderInstance(
                    rect: rectPx,
                    radii: shapeRadiiPx,
                    fill: fill,
                    border: bwPx > 0 ? topPremul : .zero,
                    params: SIMD4<Float>(bwPx, KIND_RECT, softEdge, 1.0),
                    uv: sidesVec,
                    clip: activeClip,
                    fade: activeFade
                )
                if (!hasSolidBg || hasSurface) && bwPx > 0 && effBorderColor.a > 0.001 && sidesVec == .zero {
                    PaintBands.pushRing(into: &instances, marks: &marks, inst: rectInst)
                } else {
                    instances.append(rectInst)
                    marks.append(0)
                }
            } else if fillPaintedByGrad && bwPx > 0 && effBorderColor.a > 0.001 && borderBottomPremul == nil {
                // Solid border atop multi-stop linear/radial gradient
                PaintBands.pushRing(into: &instances, marks: &marks, inst: RenderInstance(
                    rect: rectPx,
                    radii: radiiPx,
                    fill: .zero,
                    border: topPremul,
                    params: SIMD4<Float>(bwPx, KIND_RECT, softEdge, 1.0),
                    uv: .zero,
                    clip: activeClip,
                    fade: activeFade
                ))
            }

            // 5. Inset shadows
            if !flatFocusWithinShadows {
                for (sIdx, sh) in shadows.enumerated() where sh.inset {
                    let sp = sh.spread * scale
                    let shColor = (sIdx == 0 ? liveShadowColor : nil) ?? (sIdx < shadowColorProps.count ? scene.store.get(nid, shadowColorProps[sIdx]).map(Color.init) : nil) ?? sh.color
                    instances.append(RenderInstance(
                        rect: rectPx,
                        radii: radiiPx,
                        fill: premulSIMD4(shColor, opacity: localOpacity, srgb: srgbBlend),
                        border: .zero,
                        params: SIMD4<Float>(sp, KIND_INSET, max(0, sh.blur * scale), 1.0),
                        uv: SIMD4<Float>(sh.x * scale, sh.y * scale, 0, 0),
                        clip: activeClip,
                        fade: activeFade
                    ))
                    marks.append(0)
                }
            }

            // 6. Effect slot (`El.effect`, `runtime/paint/slots.rs`)
            if let eff = effectSpec {
                let mark32 = UInt32(truncatingIfNeeded: eff.id)
                let packedMark = SIMD4<Float>(
                    Float(mark32 & 0xFFFF),
                    Float((mark32 >> 16) & 0xFFFF),
                    0,
                    0
                )
                let effScale = scale * sc.x
                let slotInst = RenderInstance(
                    rect: rectPx,
                    radii: radiiPx,
                    fill: SIMD4<Float>(0, 0, 0, 1),
                    border: packedMark,
                    params: SIMD4<Float>(eff.wantsBackdrop ? 1.0 : 0.0, KIND_EFFECT, eff.bleed * effScale, effScale),
                    uv: eff.data,
                    clip: activeClip,
                    fade: activeFade
                )
                if localOpacity >= 1.0 {
                    instances.append(slotInst)
                    marks.append(mark32)
                } else {
                    var layerBegin = RenderInstance.beginLayer(
                        bounds: rectPx,
                        clip: activeClip,
                        spec: LayerSpec(opacity: localOpacity, blend: .sourceOver, blur: 0, clipRadius: 0)
                    )
                    layerBegin.fade = activeFade
                    instances.append(layerBegin)
                    marks.append(0)
                    var innerSlot = slotInst
                    innerSlot.clip = NO_CLIP
                    innerSlot.fade = .zero
                    instances.append(innerSlot)
                    marks.append(mark32)
                    instances.append(RenderInstance.endLayer())
                    marks.append(0)
                }
            }

            // 8. Image (`RGBA8Atlas` / `Pixels` + optional `SurfaceFit`)
            if let img = el.imagePayload, img.width > 0 && img.height > 0 {
                let imageEdges = imagePacker.insert(img)
                let idx = instances.count
                instances.append(RenderInstance(
                    rect: rectPx,
                    radii: radiiPx,
                    fill: SIMD4<Float>(localOpacity, localOpacity, localOpacity, localOpacity),
                    border: .zero,
                    params: SIMD4<Float>(0, KIND_IMAGE, 0, 1.0),
                    uv: imageEdges,
                    clip: activeClip,
                    fade: activeFade
                ))
                marks.append(0)
                imageFixups.append((idx, imageEdges, Float(img.width), Float(img.height)))
            } else if let px = el.pixelsPayload {
                let visible = paintEffOpacity * el.elPaintAlpha > 0.001 && visibleClipPt.width > 0 && visibleClipPt.height > 0
                if let (imageEdges, sz) = placedPixels(px, at: now, visible: visible, box: rectPx,
                                                       fit: el.pixelsFitMode, place: el.surfacePlace) {
                    let fitted = Runtime.fittedPixelsGeometry(
                        box: rectPx,
                        uv: imageEdges,
                        imageWidth: Float(sz.width),
                        imageHeight: Float(sz.height),
                        fit: el.pixelsFitMode,
                        place: el.surfacePlace,
                        pixelScale: scale
                    )
                    let drawRect = fitted.rect
                    let drawUV = fitted.uv
                    let maxR = min(drawRect.z, drawRect.w) * 0.5
                    let drawRadii: SIMD4<Float> = el.pixelsFitMode != nil
                        ? SIMD4<Float>(min(radiiPx.x, maxR), min(radiiPx.y, maxR), min(radiiPx.z, maxR), min(radiiPx.w, maxR))
                        : radiiPx
                    let idx = instances.count
                    instances.append(RenderInstance(
                        rect: drawRect,
                        radii: drawRadii,
                        fill: SIMD4<Float>(localOpacity, localOpacity, localOpacity, localOpacity),
                        border: drawUV == imageEdges ? .zero : imageEdges,
                        params: SIMD4<Float>(0, KIND_IMAGE, 0, 1.0),
                        uv: drawUV,
                        clip: activeClip,
                        fade: activeFade
                    ))
                    marks.append(0)
                    imageFixups.append((idx, drawUV, Float(sz.width), Float(sz.height)))
                }
            }

            // 9. Vector shapes (`Shape` with `trimmed`/`drawn`, `strokeWidth`, `LineCap`)
            let drawFrac = (drawMap[nid] ?? 1.0).clamped(to: 0...1)
            for shape in el.shapes {
                let effective: Shape
                if let t = shapeTrim {
                    effective = shape.trimmed(start: t.x, end: t.x + (t.y - t.x) * drawFrac)
                } else if drawFrac < 1.0 {
                    effective = shape.drawn(drawFrac)
                } else {
                    effective = shape
                }
                let swScale = scale * sc.x
                let sx: Float
                let sy: Float
                let ox: Float
                let oy: Float
                if let vb = effective.viewBox {
                    (sx, sy) = (rectPx.z / vb.x, rectPx.w / vb.y)
                    (ox, oy) = (rectPx.x, rectPx.y)
                } else {
                    (sx, sy) = (swScale, scale * sc.y)
                    if nodeScaleMotion == .still && !boxGliding && unscaled {
                        ox = PixelSnap.onGrid(exactEdgesPx.x, contain: inheritedSnap.contain.x * scale)
                        oy = PixelSnap.onGrid(exactEdgesPx.y, contain: inheritedSnap.contain.y * scale)
                    } else {
                        ox = rectPx.x + (rectPx.z - (exactEdgesPx.z - exactEdgesPx.x)) * 0.5
                        oy = rectPx.y + (rectPx.w - (exactEdgesPx.w - exactEdgesPx.y)) * 0.5
                    }
                }

                for op in effective.ops {
                    switch op {
                    case let .stroke(points, closed, strokeWidth, cap, color):
                        guard points.count >= 2 else { continue }
                        let hw = strokeWidth * 0.5 * swScale
                        let pad = max(0.5, hw) + 1
                        let col = premulSIMD4(applyPressColor(pressTint.color, to: color, frac: pressTint.frac), opacity: localOpacity, srgb: srgbBlend)
                        let capFlag: Float = cap == .round ? 1.0 : 0.0
                        let segCount = closed ? points.count : (points.count - 1)
                        for sIdx in 0..<segCount {
                            let pa = points[sIdx]
                            let pb = points[(sIdx + 1) % points.count]
                            let ax = ox + pa.x * sx
                            let ay = oy + pa.y * sy
                            let bx = ox + pb.x * sx
                            let by = oy + pb.y * sy
                            let minX = min(ax, bx) - pad
                            let minY = min(ay, by) - pad
                            let maxX = max(ax, bx) + pad
                            let maxY = max(ay, by) + pad
                            instances.append(RenderInstance(
                                rect: SIMD4<Float>(minX, minY, maxX - minX, maxY - minY),
                                radii: SIMD4<Float>(ax, ay, bx, by),
                                fill: col,
                                border: .zero,
                                params: SIMD4<Float>(hw, KIND_SEGMENT, capFlag, 1.0),
                                uv: .zero,
                                clip: activeClip,
                                fade: activeFade
                            ))
                            marks.append(0)
                        }
                    case let .fill(points, color):
                        let tris = Shape.triangulate(points)
                        let col = premulSIMD4(applyPressColor(pressTint.color, to: color, frac: pressTint.frac), opacity: localOpacity, srgb: srgbBlend)
                        for (indices, aaMask) in tris {
                            let p0 = points[indices[0]]
                            let p1 = points[indices[1]]
                            let p2 = points[indices[2]]
                            let v0 = SIMD2<Float>(ox + p0.x * sx, oy + p0.y * sy)
                            let v1 = SIMD2<Float>(ox + p1.x * sx, oy + p1.y * sy)
                            let v2 = SIMD2<Float>(ox + p2.x * sx, oy + p2.y * sy)
                            let minX = min(v0.x, min(v1.x, v2.x))
                            let minY = min(v0.y, min(v1.y, v2.y))
                            let maxX = max(v0.x, max(v1.x, v2.x))
                            let maxY = max(v0.y, max(v1.y, v2.y))
                            instances.append(RenderInstance(
                                rect: SIMD4<Float>(minX, minY, maxX - minX, maxY - minY),
                                radii: SIMD4<Float>(v0.x, v0.y, v1.x, v1.y),
                                fill: col,
                                border: .zero,
                                params: SIMD4<Float>(Float(aaMask), KIND_TRIANGLE, 0, 1.0),
                                uv: SIMD4<Float>(v2.x, v2.y, 0, 0),
                                clip: activeClip,
                                fade: activeFade
                            ))
                            marks.append(0)
                        }
                    }
                }
            }

            // 10. Icon (`SVGIcon`)
            if let (svg, iconSizePt) = el.iconPayload {
                let iconPx = max(1, Int((iconSizePt * scale).rounded()))
                let iconColor = applyPressColor(pressTint.color, to: liveTextColor ?? scene.store.get(nid, Props.TEXT_COLOR).map(Color.init) ?? el.textColor ?? (systemDark ? Color.white : Color.black), frac: pressTint.frac)
                if let colorDecoded = textSystem.colorIcons.rasterize(
                    svg,
                    pixelSize: iconPx,
                    currentColor: iconColor,
                    oneColor: el.isIconOneColor ? iconColor : nil,
                    mirrored: node.mirroredInRtl
                ), let baseMip = colorDecoded.mips.first {
                    let atlas = RGBA8Atlas(width: Int(baseMip.width), height: Int(baseMip.height), texels: [UInt8](baseMip.rgba))
                    let imageEdges = imagePacker.insert(atlas)
                    let pw = Float(baseMip.width)
                    let ph = Float(baseMip.height)
                    let ix = rectPx.x + (rectPx.z - pw) * 0.5
                    let iy = rectPx.y + (rectPx.w - ph) * 0.5
                    let idx = instances.count
                    instances.append(RenderInstance(
                        rect: SIMD4<Float>(ix, iy, pw, ph),
                        radii: .zero,
                        fill: SIMD4<Float>(localOpacity, localOpacity, localOpacity, localOpacity),
                        border: .zero,
                        params: SIMD4<Float>(0, KIND_IMAGE, 0, 1.0),
                        uv: imageEdges,
                        clip: activeClip,
                        fade: activeFade
                    ))
                    marks.append(0)
                    imageFixups.append((idx, imageEdges, pw, ph))
                } else {
                    let placed = textSystem.glyphAtlas.rasterizeIcon(
                        svg,
                        pixelSize: iconPx,
                        mirrored: node.mirroredInRtl
                    )
                    let col = premulSIMD4(iconColor, opacity: localOpacity, srgb: srgbBlend)
                    let pw = Float(placed.pixelSize.x)
                    let ph = Float(placed.pixelSize.y)
                    let ix = rectPx.x + (rectPx.z - pw) * 0.5
                    let iy = rectPx.y + (rectPx.w - ph) * 0.5
                    let idx = instances.count
                    instances.append(RenderInstance(
                        rect: SIMD4<Float>(ix, iy, pw, ph),
                        radii: .zero,
                        fill: col,
                        border: .zero,
                        params: SIMD4<Float>(0, KIND_GLYPH, 0, 1.0),
                        uv: placed.uv,
                        clip: activeClip,
                        fade: activeFade
                    ))
                    marks.append(0)
                    glyphFixups.append((idx, placed.uv, pw, ph, placed.page, false))
                }
            }

            if let grid = el.terminalGridPayload {
                let ink = liveTextColor ?? scene.store.get(nid, Props.TEXT_COLOR).map(Color.init) ?? el.textColor ?? Tok.theme(dark: systemDark).text
                let padding = SIMD4<Float>(el.layout.padding.left * sc.x * scale, el.layout.padding.top * sc.y * scale, 0, 0)
                paintTerminalGridInstances(grid, snappedRect: paintedEdges + padding, exactRect: exactEdgesPx + padding,
                                           clip: activeClip, fade: activeFade,
                                           opacity: localOpacity, defaultColor: ink,
                                           into: &instances, marks: &marks, glyphFixups: &glyphFixups, imageFixups: &imageFixups)
            }

            // 11. Text (`editLens` textInput / `plainText` / `richSpans` / `advanceIn`)
            let isTextFlightTarget = activeTextFlights.contains { $0.targetNodeId == nid }
            if let editLens = el.handlers.editLens {
                var edit = editLens.get(state)
                if el.isSecure {
                    edit.isSecure = true
                    if let revealed = el.revealedOverride { edit.isRevealed = revealed }
                }
                let textTop = effRect.y + el.layout.padding.top * sc.y
                let innerW = max(0, (effRect.width - (el.layout.padding.left + el.layout.padding.right) * sc.x) / max(1e-4, sc.x))
                let resolvedInput = ElDisplayResolver.resolveInput(
                    el: el,
                    edit: edit,
                    innerWidth: innerW,
                    pxScale: rasterScale * scale
                )
                let defaultTextColor = liveTextColor ?? el.textColor ?? (systemDark ? Color.white : Color.black)
                let textCol = resolvedInput.showingPlaceholder
                    ? (el.placeholderColor ?? defaultTextColor.alpha(0.45))
                    : defaultTextColor
                let inputBox = textSystem.layoutInput(
                    text: resolvedInput.renderedString, spans: resolvedInput.spans, pills: resolvedInput.pills,
                    style: resolvedInput.style, maxWidth: resolvedInput.maxWidthForShape,
                    pixelScale: rasterScale * scale, emitGlyphs: !resolvedInput.renderedString.isEmpty,
                    keep: resolvedInput.isSecure ? .secret : .cached,
                    request: Self.paragraphRequest(field: nid, el: el, edit: edit, resolved: resolvedInput)
                )
                let shaped = inputBox.shaped
                let scrollX = computeSingleLineScroll(
                    path: node.path, edit: edit, shaped: shaped, isFocused: focused,
                    showingPlaceholder: resolvedInput.showingPlaceholder, innerWidthPt: innerW, pixelScale: inputBox.pixelScale
                )
                let textLeft = effRect.x + (el.layout.padding.left - scrollX) * sc.x
                let inputClipEdges = intersectClipRects(activeClip, boundsClipPx)
                let forceScaled = nodeScaleMotion != .still
                    || abs(sc.x - rasterScale) > 1e-4
                    || abs(sc.y - rasterScale) > 1e-4
                if resolvedInput.style.hasBlockInsets {
                    RichTextFieldRender.emitBlockDecorations(
                        blocks: resolvedInput.blocks, softBreaks: edit.softBreaks,
                        richStyle: resolvedInput.richStyle, displayText: resolvedInput.showingPlaceholder ? "" : resolvedInput.renderedString, shaped: shaped,
                        textSystem: textSystem, font: resolvedInput.showingPlaceholder ? el.textStyle : resolvedInput.style, textColor: defaultTextColor,
                        innerW: innerW * sc.x, textOriginX: textLeft, textOriginY: textTop,
                        scaleVec: sc, pxScale: scale, shapingScale: rasterScale * scale,
                        rect: { rect, radius, color in
                            instances.append(RenderInstance(rect: rect, radii: SIMD4(repeating: radius),
                                fill: premulSIMD4(color, opacity: localOpacity, srgb: srgbBlend), border: .zero,
                                params: SIMD4(0, KIND_RECT, 0, 1), uv: .zero, clip: inputClipEdges, fade: activeFade))
                            marks.append(0)
                        },
                        glyph: { rect, uv, page, color in
                            let ink = premulSIMD4(color, opacity: localOpacity, srgb: srgbBlend)
                            glyphFixups.append((instances.count, uv, rect.z, rect.w, page, forceScaled))
                            instances.append(RenderInstance(rect: rect, radii: .zero,
                                fill: ink, border: .zero, params: SIMD4(0, KIND_GLYPH, 0, textSystem.coverageExponent(ink)),
                                uv: uv, clip: inputClipEdges, fade: activeFade))
                            marks.append(0)
                        }
                    )
                }
                emitTextBackdropsAndPills(
                    shaped: shaped,
                    textLeft: textLeft,
                    textTop: textTop,
                    sc: sc,
                    rasterScale: rasterScale,
                    localOpacity: localOpacity,
                    spanRadius: el.elSpanRadius,
                    defaultTextColor: defaultTextColor,
                    clipEdges: inputClipEdges,
                    fade: activeFade,
                    forceScaled: forceScaled
                )
                let fieldMarks = resolvedInput.showingPlaceholder || resolvedInput.isSecure ? [] : el.textHighlights ?? []
                for quad in TextHighlightPainter.fieldQuads(
                    marks: fieldMarks, box: inputBox, system: textSystem,
                    origin: Vec2(textLeft, textTop), transform: sc, pixelScale: scale
                ) {
                    instances.append(RenderInstance(
                        rect: quad.rect, radii: SIMD4(repeating: quad.cornerRadius),
                        fill: premulSIMD4(quad.bg, opacity: localOpacity, srgb: srgbBlend),
                        border: quad.ring.map { premulSIMD4($0.color, opacity: localOpacity, srgb: srgbBlend) } ?? .zero,
                        params: SIMD4(quad.ring?.width ?? 0, KIND_RECT, 0, 1),
                        uv: .zero, clip: inputClipEdges, fade: activeFade
                    ))
                    marks.append(0)
                }
                let inputGlyphs: [PositionedGlyph]
                let hidesDepartingPlaceholder = resolvedInput.showingPlaceholder && activeTextFlights.contains {
                    FlightSelector.selects($0.state.sourceKey, path: node.path, key: node.key)
                        && $0.state.alphas(target: $0.state.destination, now: now, reducedMotion: reducedMotion).source > 0
                }
                if isTextFlightTarget || hidesDepartingPlaceholder {
                    inputGlyphs = []
                } else if let paragraphs = inputBox.paragraphs {
                    let top = (inputClipEdges.y / scale - textTop) * paragraphs.scale / max(sc.y, 1e-4)
                    let bottom = (inputClipEdges.w / scale - textTop) * paragraphs.scale / max(sc.y, 1e-4)
                    let allRows = parentIsRotated || abs(el.rotate) > 1e-4
                    let rows = allRows ? (-Float.infinity, Float.infinity) : (top, bottom)
                    if paragraphs.waiting { textRows[nid] = rows }
                    inputGlyphs = paragraphs.glyphs(top: rows.0, bottom: rows.1, using: textSystem)
                } else {
                    inputGlyphs = shaped.glyphs
                }
                for gq in inputGlyphs {
                    let gx = (textLeft + gq.rect.x * sc.x) * scale
                    let gy = (textTop + gq.rect.y * sc.y) * scale
                    let gw = max(1.0, gq.rect.z * sc.x * scale)
                    let gh = max(1.0, gq.rect.w * sc.y * scale)
                    let ink = fieldMarks.last { $0.fg != nil && $0.byteRange.contains(gq.utf8Offset) }?.fg ?? gq.color ?? textCol
                    let gcol = premulSIMD4(ink, opacity: localOpacity, srgb: srgbBlend)
                    appendTextGlyph(gq, rect: SIMD4(gx, gy, gw, gh), ink: gcol,
                                    clip: inputClipEdges, fade: activeFade, forceScaled: forceScaled)
                }
                if focused {
                    let offset = displayCaretByteOffset(for: edit, showingPlaceholder: resolvedInput.showingPlaceholder)
                    let caret = textSystem.caretRect(in: shaped, utf8Offset: offset, upstream: edit.caretAffinity == .upstream, pixelScale: inputBox.pixelScale)
                    let x = textLeft + caret.x * sc.x
                    let y = textTop + caret.y * sc.y
                    let width = caret.z * sc.x
                    let height = caret.w * sc.y
                    newElements[myElementIndex].caret = [x, y, width, height]
                    if windowFocused {
                        let color = el.caretColor ?? Tok.accent(0, dark: systemDark)
                        instances.append(RenderInstance(
                            rect: SIMD4(x * scale, y * scale, max(2, width * scale), height * scale),
                            radii: SIMD4(repeating: scale), fill: premulSIMD4(color, opacity: localOpacity, srgb: srgbBlend),
                            border: .zero, params: SIMD4(0, KIND_RECT, 0, 1), uv: .zero, clip: inputClipEdges, fade: activeFade
                        ))
                        marks.append(0)
                    }
                }
            } else if (el.plainText?.isEmpty == false) || (el.richSpans?.isEmpty == false) || el.advanceInRun != nil {
                let resolvedText = ElDisplayResolver.resolveText(
                    el: el,
                    rawText: el.plainText,
                    isSecure: el.isSecure
                )
                let restsExact = TextBoxGeometry.restsExact(
                    isInput: false, scaleStill: nodeScaleMotion == .still && abs(rasterScale - 1) < 1e-5,
                    scale: SIMD2<Float>(sc.x, sc.y)
                )
                let exactOffset = restsExact ? TextBoxGeometry.leafExactOff(
                    rest: snapParent, rigid: inheritedSnap.steady * scale, containPx: inheritedSnap.contain * scale, shifted: childSnap.shifted
                ) : .zero
                let textLeft = (paintedEdges.x + exactOffset.x) / scale + el.layout.padding.left * sc.x
                let textTop = (paintedEdges.y + exactOffset.y) / scale + el.layout.padding.top * sc.y
                let drawnInnerW = max(0, rectPx.z / scale - (el.layout.padding.left + el.layout.padding.right) * sc.x)
                let drawnInnerH = max(0, rectPx.w / scale - (el.layout.padding.top + el.layout.padding.bottom) * sc.y)
                let layoutInnerW = max(0, node.targetRect.width - el.layout.padding.left - el.layout.padding.right)
                let glidingText = boxGliding && unscaled && nodeScaleMotion == .still
                let glide = glidingText ? Vec2(PixelSnap.textGlide(paintedEdges.x), PixelSnap.textGlide(paintedEdges.y)) : .zero
                let glideOffset = glidingText ? SIMD2<Float>(paintedEdges.x - paintedEdges.x.rounded(), paintedEdges.y - paintedEdges.y.rounded()) : .zero
                let restOrigin = SIMD2<Float>(textLeft, textTop) * scale - glideOffset
                var shaped = resolvedText.shape(
                    using: textSystem,
                    maxWidth: TextBoxGeometry.wrapWidth(layoutInnerW, scale: rasterScale * scale),
                    pixelScale: rasterScale * scale,
                    emitGlyphs: true,
                    glidePx: glide
                )
                #if canImport(CRuneDesktopText) && !canImport(CoreText)
                if restsExact, let native = shaped.desktopRestingText {
                    _ = native.place(&shaped, at: restOrigin.x, atlas: textSystem.glyphAtlas)
                }
                #endif
                let forceScaled = nodeScaleMotion != .still
                    || abs(sc.x - rasterScale) > 1e-4
                    || abs(sc.y - rasterScale) > 1e-4
                var glyphClipEdges = activeClip
                var glyphFade = activeGlyphBaseFade
                if resolvedText.truncateFade || el.liveText != nil {
                    let baseClipRect = SIMD4<Float>(activeClip.x, activeClip.y, max(0, activeClip.z - activeClip.x), max(0, activeClip.w - activeClip.y))
                    let fadeRes = ElDisplayResolver.truncateFadeParams(
                        el: el,
                        shaped: shaped,
                        innerW: drawnInnerW,
                        innerH: drawnInnerH,
                        exactInnerWPx: drawnInnerW * scale,
                        layoutInnerW: layoutInnerW,
                        scaleVec: sc,
                        pxScale: scale,
                        textOriginX: textLeft,
                        textOriginY: textTop,
                        baseClipPx: baseClipRect
                    )
                    glyphClipEdges = SIMD4<Float>(
                        fadeRes.glyphClip.x,
                        fadeRes.glyphClip.y,
                        fadeRes.glyphClip.x + fadeRes.glyphClip.z,
                        fadeRes.glyphClip.y + fadeRes.glyphClip.w
                    )
                    if resolvedText.truncateFade && fadeRes.isTruncated {
                        let (pw, po) = unpackFade(glyphFade)
                        var widths = pw
                        var origins = SIMD4<Float>(
                            activeClip.x - po.x * abs(pw.x),
                            activeClip.y - po.y * abs(pw.y),
                            activeClip.z + po.z * abs(pw.z),
                            activeClip.w + po.w * abs(pw.w)
                        )
                        let bounds = fadeRes.boxBoundsPx
                        let own = fadeRes.glyphFadeLTRB
                        for edge in 0..<4 {
                            let inset = edge < 2 ? (bounds[edge] - origins[edge]) : (origins[edge] - bounds[edge])
                            let o = abs(own[edge])
                            let w = abs(widths[edge])
                            if o > 0 && (w == 0 || o >= w || inset >= w) {
                                widths[edge] = own[edge]
                                origins[edge] = bounds[edge]
                            }
                        }
                        var packed = packFade(width: widths, origin: origins, clip: glyphClipEdges)
                        packed.w = glyphFade.w
                        glyphFade = packed
                    } else if el.liveText != nil && fadeRes.isTruncated {
                        glyphClipEdges = SIMD4<Float>(
                            fadeRes.glyphClip.x,
                            fadeRes.glyphClip.y,
                            fadeRes.glyphClip.x + fadeRes.glyphClip.z,
                            fadeRes.glyphClip.y + fadeRes.glyphClip.w
                        )
                    }
                }
                let defaultTextColor = applyPressColor(pressTint.color, to: liveTextColor ?? scene.store.get(nid, Props.TEXT_COLOR).map(Color.init) ?? el.textColor ?? (systemDark ? Color.white : Color.black), frac: pressTint.frac)
                let isRotatedScope = parentIsRotated || abs(el.rotate) > 1e-4
                let inCacheScope = parentInCache || cacheEligible
                let shownMargin = effBlur * scale * 3.0 + (effectSpec.map { $0.bleed * max(sc.x, sc.y) * scale } ?? 0) + 2.0
                let shownY0 = (!isRotatedScope && !inCacheScope) ? max(activeClip.y, -shownMargin) : activeClip.y
                let shownY1 = (!isRotatedScope && !inCacheScope) ? min(activeClip.w, viewport.y * scale + shownMargin) : activeClip.w
                let baseLinePt = resolvedText.style.lineHeight ?? resolvedText.style.size
                let spanMaxPt = resolvedText.spans?.compactMap(\.size).max() ?? 0
                let emPt = max(max(resolvedText.style.size, baseLinePt), spanMaxPt)
                let bandPadPx = 2.0 * emPt * sc.y * scale + 2.0 / max(1e-4, rasterScale * scale)
                let visibleMinY = shownY0 - bandPadPx
                let visibleMaxY = shownY1 + bandPadPx
                let linkInks = recordAndEmitTextLinks(
                    snap: node, el: el, text: resolvedText.displayedText, authoredText: resolvedText.authoredText,
                    caseMap: resolvedText.caseMap, shaped: shaped, elided: shaped.elided,
                    textOriginX: textLeft, textOriginY: textTop, scaleVec: sc, pxScale: scale, shapeScale: rasterScale * scale,
                    localAlpha: localOpacity, defaultTextColor: defaultTextColor, isFocused: focused,
                    isExiting: isExiting, shouldEmit: !isTextFlightTarget, visClip: visibleClipPt, linkBoxes: &newLinkBoxes
                ) { rect, radius, fill, border, width in
                    instances.append(RenderInstance(
                        rect: rect, radii: SIMD4(repeating: radius),
                        fill: premulSIMD4(fill, opacity: localOpacity, srgb: srgbBlend),
                        border: premulSIMD4(border, opacity: localOpacity, srgb: srgbBlend),
                        params: SIMD4(width, KIND_RECT, 0, 1), uv: .zero, clip: glyphClipEdges, fade: glyphFade
                    ))
                    marks.append(0)
                }
                emitTextBackdropsAndPills(
                    shaped: shaped,
                    textLeft: textLeft,
                    textTop: textTop,
                    sc: sc,
                    rasterScale: rasterScale,
                    localOpacity: localOpacity,
                    spanRadius: el.elSpanRadius,
                    defaultTextColor: defaultTextColor,
                    clipEdges: activeClip,
                    fade: activeFade,
                    forceScaled: forceScaled,
                    cullY: isRotatedScope ? nil : (visibleMinY, visibleMaxY)
                )
                var combinedHighlights = el.textHighlights ?? []
                let ringHls = ElDisplayResolver.spanRingHighlights(spanRings: resolvedText.spanRings, spans: resolvedText.spans)
                if !ringHls.isEmpty {
                    combinedHighlights.append(contentsOf: ringHls)
                }
                if !combinedHighlights.isEmpty && !resolvedText.displayedText.isEmpty {
                    let quads = TextHighlightPainter.quads(
                        highlights: combinedHighlights,
                        in: resolvedText.displayedText,
                        shaped: shaped,
                        textSystem: textSystem,
                        pixelScale: scale,
                        origin: .zero
                    )
                    for q in quads {
                        let hlRect = SIMD4<Float>(
                            textLeft * scale + q.rect.x,
                            textTop * scale + q.rect.y,
                            q.rect.z,
                            q.rect.w
                        )
                        if !isRotatedScope && (hlRect.y + hlRect.w < visibleMinY || hlRect.y > visibleMaxY) { continue }
                        let hlRadii = SIMD4<Float>(repeating: q.cornerRadius)
                        let bgColor = premulSIMD4(q.bg, opacity: localOpacity, srgb: srgbBlend)
                        if bgColor.w > 0.0005 {
                            instances.append(RenderInstance(
                                rect: hlRect,
                                radii: hlRadii,
                                fill: bgColor,
                                border: .zero,
                                params: SIMD4<Float>(0, KIND_RECT, 0, 1.0),
                                uv: .zero,
                                clip: activeClip,
                                fade: activeFade
                            ))
                            marks.append(0)
                        }
                        if let ring = q.ring, ring.width > 0 {
                            let ringColor = premulSIMD4(ring.color, opacity: localOpacity, srgb: srgbBlend)
                            if ringColor.w > 0.0005 {
                                instances.append(RenderInstance(
                                    rect: hlRect,
                                    radii: hlRadii,
                                    fill: .zero,
                                    border: ringColor,
                                    params: SIMD4<Float>(ring.width * scale, KIND_RECT, 0, 1.0),
                                    uv: .zero,
                                    clip: activeClip,
                                    fade: activeFade
                                ))
                                marks.append(0)
                            }
                        }
                    }
                }
                if !el.elStrikes.isEmpty {
                    let strikeQuads = ShellSliceRenderHelpers.strikeQuads(
                        strikes: el.elStrikes,
                        richSpans: el.richSpans,
                        text: resolvedText.displayedText,
                        shaped: shaped,
                        textSystem: textSystem,
                        styleSize: el.textStyle.size,
                        defaultTextColor: defaultTextColor,
                        textOriginX: textLeft,
                        textOriginY: textTop,
                        scaleVec: Vec2(1, 1),
                        pxScale: scale,
                        localAlpha: localOpacity,
                        srgbBlend: srgbBlend
                    )
                    for sq in strikeQuads {
                        if !isRotatedScope && (sq.rect.y + sq.rect.w < visibleMinY || sq.rect.y > visibleMaxY) { continue }
                        instances.append(RenderInstance(
                            rect: sq.rect,
                            radii: .zero,
                            fill: sq.color,
                            border: .zero,
                            params: SIMD4<Float>(0, KIND_RECT, 0, 1.0),
                            uv: .zero,
                            clip: activeClip,
                            fade: activeFade
                        ))
                        marks.append(0)
                    }
                }
                let revealClock = scene.store.nodeTimeScale(nid) != 1.0 ? scene.store.nodeTime(nid) : lastScaledAnimNow
                let wordFadeMask = ((el.elRevealWordFade ?? -1) >= 0)
                    ? wordRevealStore.mask(for: nid, text: resolvedText.displayedText, shaped: shaped, textSystem: textSystem, pixelScale: scale, now: revealClock)
                    : nil
                let baselines = restsExact ? TextBoxGeometry.roundedBaselines(originYPx: restOrigin.y, shaped: shaped) : []
                var baselineLine = 0
                let labelGlyphs = isTextFlightTarget ? [] : shaped.glyphs
                for (index, glyph) in labelGlyphs.enumerated() {
                    let wordAlpha = wordFadeMask?.alpha(for: glyph) ?? 1.0
                    let gAlpha = localOpacity * wordAlpha
                    if gAlpha <= 0.0005 { continue }
                    let (gq, placement) = TextBoxGeometry.paintGlyph(
                        glyph, index: index, shaped: shaped, origin: restOrigin, scale: SIMD2<Float>(sc.x, sc.y), pixelScale: scale,
                        restsExact: restsExact, baselines: baselines, line: &baselineLine, atlas: textSystem.glyphAtlas
                    )
                    if !isRotatedScope && (placement.y + placement.w < visibleMinY || placement.y > visibleMaxY) { continue }
                    let glyphBaseColor = linkInkColor(for: glyph, ranges: linkInks) ?? gq.color.map { applyPressColor(pressTint.color, to: $0, frac: pressTint.frac) } ?? defaultTextColor
                    let gcol = premulSIMD4(glyphBaseColor, opacity: gAlpha, srgb: srgbBlend)
                    appendTextGlyph(gq, rect: placement, ink: gcol,
                                    clip: glyphClipEdges, fade: glyphFade, forceScaled: forceScaled)
                }
            }
            let focusOverlay = !hasActiveTextLinks(el) ? resolvedFocusRingOverlay(
                el: el,
                snapIndex: node.index,
                snapPath: node.path,
                isExiting: isExiting,
                effectiveInert: effInert,
                isFocused: focusedPath == node.path && !isExiting,
                forceFocusRings: cxSettings.viewDefaults.forceFocusRings,
                defaultRingOutline: cxSettings.viewDefaults.focusRing ?? Outline(width: 2.0, offset: el.focusRingOffset, color: Tok.accent(0, dark: systemDark)),
                devRect: rectPx,
                devRadii: radiiPx,
                pxScale: scale
            ) : nil
            if focusOverlay == nil, let ol = el.elOutline, localOpacity > 0.0005 {
                let avgScale = effRect.width > 0.001 ? (rectPx.z / (effRect.width * scale)) : 1.0
                if let og = ShellSliceRenderHelpers.resolvedOutlineGeometry(
                    outline: ol,
                    devRect: rectPx,
                    devRadii: radiiPx,
                    pxScale: scale,
                    avgScale: avgScale
                ) {
                    instances.append(RenderInstance(
                        rect: og.rect,
                        radii: og.radii,
                        fill: .zero,
                        border: premulSIMD4(ol.color, opacity: localOpacity, srgb: srgbBlend),
                        params: SIMD4<Float>(og.widthPx, KIND_RECT, 0, 1.0),
                        uv: .zero,
                        clip: activeClip,
                        fade: activeFade
                    ))
                    marks.append(0)
                }
            }
            if currentInheritedMark != 0, markStartIdx < marks.count {
                for mIdx in markStartIdx..<marks.count where marks[mIdx] == 0 {
                    marks[mIdx] = currentInheritedMark
                }
            }

            return (true, subtreeDynamic, paintEffOpacity, effBlur, effRect, rectPx, radiiPx, effInert, nextChildClip, nextChildTransform, isDissolveScope, needsLayer, outerLayerStarts, cacheEligible, myElementIndex, layerStartIdx, surfaceStartIdx, glyphFixupStartIdx, imageFixupStartIdx, nodeScaleMotion, activeClip, activeFade, effScale, nodePaintHash, elideCache)
        }

        @inline(never)
        func paintNodeFooter(
            _ node: FlatNode,
            activeClip: SIMD4<Float>,
            activeFade: SIMD4<UInt32>,
            effOpacity: Float,
            effBlur: Float,
            rectPx: SIMD4<Float>,
            radiiPx: SIMD4<Float>,
            needsLayer: Bool,
            outerLayerStarts: [Int],
            cacheEligible: Bool,
            subtreeDynamic: Bool,
            layerStartIdx: Int,
            surfaceStartIdx: Int,
            glyphFixupStartIdx: Int,
            imageFixupStartIdx: Int,
            effScale: Float,
            nodePaintHash: UInt64,
            elideCache: (sig: UInt64, relBounds: SIMD4<Float>, k: Float)?
        ) {
            let nid = node.nodeId
            let el = node.el
            let localOpacity = ((needsLayer ? 1.0 : effOpacity) * el.elPaintAlpha).clamped(to: 0...1)

            // 13. Focus ring
            if !hasActiveTextLinks(el),
               let overlay = resolvedFocusRingOverlay(
                el: el,
                snapIndex: node.index,
                snapPath: node.path,
                isExiting: exitingIds.contains(nid),
                effectiveInert: node.effectiveInert,
                isFocused: focusedPath == node.path && !exitingIds.contains(nid),
                forceFocusRings: cxSettings.viewDefaults.forceFocusRings,
                defaultRingOutline: cxSettings.viewDefaults.focusRing ?? Outline(width: 2.0, offset: el.focusRingOffset, color: Tok.accent(0, dark: systemDark)),
                devRect: rectPx,
                devRadii: radiiPx,
                pxScale: scale
            ) {
                instances.append(RenderInstance(
                    rect: overlay.rect,
                    radii: SIMD4<Float>(
                        overlay.radii.x >= 0 ? overlay.radii.x : abs(radiiPx.x),
                        overlay.radii.y >= 0 ? overlay.radii.y : abs(radiiPx.y),
                        overlay.radii.z >= 0 ? overlay.radii.z : abs(radiiPx.z),
                        overlay.radii.w >= 0 ? overlay.radii.w : abs(radiiPx.w)
                    ),
                    fill: .zero,
                    border: premulSIMD4(overlay.color, opacity: localOpacity, srgb: srgbBlend),
                    params: SIMD4<Float>(overlay.widthPx, KIND_RECT, 0.5, 1.0),
                    uv: .zero,
                    clip: activeClip,
                    fade: activeFade
                ))
                marks.append(0)
            }

            if needsLayer {
                let innerLayerIdx = layerStartIdx + outerLayerStarts.count
                func truncateLayerChildren(signature: UInt64) {
                    while let last = elidedLayers.last, last.index >= innerLayerIdx {
                        elidedLayers.removeLast()
                    }
                    elidedLayers.append((innerLayerIdx, nid.rawValue, signature))
                    if instances.count > innerLayerIdx + 1 {
                        instances.removeSubrange((innerLayerIdx + 1)..<instances.count)
                        marks.removeSubrange((innerLayerIdx + 1)..<marks.count)
                    }
                    if glyphFixups.count > glyphFixupStartIdx {
                        glyphFixups.removeSubrange(glyphFixupStartIdx..<glyphFixups.count)
                    }
                    if imageFixups.count > imageFixupStartIdx {
                        imageFixups.removeSubrange(imageFixupStartIdx..<imageFixups.count)
                    }
                }
                if cacheEligible && !subtreeDynamic && newSurfaces.count == surfaceStartIdx && innerLayerIdx < instances.count {
                    if let elide = elideCache {
                        truncateLayerChildren(signature: elide.sig)
                        let b0 = floorf(rectPx.x + elide.relBounds.x * elide.k)
                        let b1 = floorf(rectPx.y + elide.relBounds.y * elide.k)
                        let b2 = ceilf(rectPx.x + elide.relBounds.z * elide.k)
                        let b3 = ceilf(rectPx.y + elide.relBounds.w * elide.k)
                        instances[innerLayerIdx].rect = SIMD4<Float>(b0, b1, max(0, b2 - b0), max(0, b3 - b1))
                        instances[innerLayerIdx].params.w = 1.0
                        instances[innerLayerIdx].radii = packU64ToFloat4(nid.rawValue)
                        instances[innerLayerIdx].uv = packU64ToFloat4(elide.sig)
                    } else {
                        let sig = hashCachedLayerContent(
                            instances: instances[(innerLayerIdx + 1)...],
                            glyphFixups: glyphFixups[glyphFixupStartIdx...],
                            imageFixups: imageFixups[imageFixupStartIdx...],
                            surfacesCount: 0,
                            origin: SIMD2<Float>(rectPx.x, rectPx.y),
                            size: SIMD2<Float>(rectPx.z, rectPx.w),
                            blurPx: effBlur * scale,
                            srgbBlend: srgbBlend,
                            glyphAtlasSize: (textSystem.glyphAtlas.atlas.width, textSystem.glyphAtlas.atlas.height),
                            imageVersion: imagePacker.version(at:),
                            userKey: el.runtimeExtras[RenderExtrasKey.cacheKey] as? UInt64
                        )
                        var bx0 = rectPx.x
                        var by0 = rectPx.y
                        var bx1 = rectPx.x + rectPx.z
                        var by1 = rectPx.y + rectPx.w
                        for inst in instances[(innerLayerIdx + 1)...] {
                            if inst.rect.z <= 0 || inst.rect.w <= 0 { continue }
                            if inst.params.y == KIND_LAYER_END { continue }
                            let grow = inst.params.z > 0.5 ? (inst.params.z * 3.0 + 1.0) : 0.0
                            bx0 = min(bx0, inst.rect.x - grow)
                            by0 = min(by0, inst.rect.y - grow)
                            bx1 = max(bx1, inst.rect.x + inst.rect.z + grow)
                            by1 = max(by1, inst.rect.y + inst.rect.w + grow)
                        }
                        let layerGrow = effBlur * scale > 0.05 ? ceilf(effBlur * scale * 3.0) : 0.0
                        bx0 = floorf(bx0 - layerGrow)
                        by0 = floorf(by0 - layerGrow)
                        bx1 = ceilf(bx1 + layerGrow)
                        by1 = ceilf(by1 + layerGrow)
                        let cw = max(0, bx1 - bx0)
                        let ch = max(0, by1 - by0)
                        if cw > 4096 || ch > 4096 {
                            elSliceRenderState.nodeCaches.removeValue(forKey: nid)
                        } else {
                            if abs(el.rotate) <= 1e-4 {
                                instances[innerLayerIdx].rect = SIMD4<Float>(bx0, by0, cw, ch)
                            }
                            let prev = elSliceRenderState.nodeCaches[nid]
                            let rel = SIMD4<Float>(bx0 - rectPx.x, by0 - rectPx.y, bx1 - rectPx.x, by1 - rectPx.y)
                            elSliceRenderState.nodeCaches[nid] = ElNodeCacheEntry(
                                signature: sig,
                                rasterScale: effScale,
                                scale: prev?.scale ?? effScale,
                                since: prev?.since ?? -.infinity,
                                envScale: scale,
                                isLivePhase: false,
                                relBounds: rel,
                                commitGen: commitGen,
                                paintHash: nodePaintHash
                            )
                        }
                        instances[innerLayerIdx].params.w = 1.0
                        instances[innerLayerIdx].radii = packU64ToFloat4(nid.rawValue)
                        instances[innerLayerIdx].uv = packU64ToFloat4(sig)
                        if residentCacheTracker.isResident(nodeId: nid.rawValue, signature: sig) {
                            truncateLayerChildren(signature: sig)
                        }
                    }
                }
                closeLayer(start: innerLayerIdx, surfaceStart: surfaceStartIdx)
            }
            for outerStart in outerLayerStarts.reversed() {
                closeLayer(start: outerStart, surfaceStart: surfaceStartIdx)
            }
        }

        @discardableResult
        func paintSubtree(
            _ node: FlatNode,
            parentClip: RenderClipState,
            inheritedInert: Bool,
            parentOpacity: Float,
            inheritedTransform: PresentedTransform = .identity,
            parentIsDissolve: Bool = false,
            parentScaleMotion: PaintScaleMotion = .still,
            parentElementIndex: Int? = nil,
            allowRaised: Bool = false,
            parentInCache: Bool = false,
            parentIsRotated: Bool = false
        ) -> Bool {
            if !allowRaised && node.el.isRaised {
                collectedRaisedNodes.append(node)
                return true
            }
            let savedMark = currentInheritedMark
            let activeNodeMark = node.el.elMark ?? savedMark
            currentInheritedMark = activeNodeMark
            defer { currentInheritedMark = savedMark }
            let h = paintNodeHeader(
                node,
                parentClip: parentClip,
                inheritedInert: inheritedInert,
                parentOpacity: parentOpacity,
                inheritedTransform: inheritedTransform,
                parentIsDissolve: parentIsDissolve,
                parentScaleMotion: parentScaleMotion,
                parentElementIndex: parentElementIndex,
                parentInCache: parentInCache,
                parentIsRotated: parentIsRotated
            )
            if !h.continueSubtree { return h.subtreeDynamic }

            var subtreeDynamic = h.subtreeDynamic
            let childOpacity = (h.needsLayer ? 1.0 : h.effOpacity).clamped(to: 0...1)
            let childInCache = parentInCache || h.cacheEligible
            let childIsRotated = parentIsRotated || abs(node.el.rotate) > 1e-4
            for child in childrenByParent[node.nodeId] ?? [] {
                if paintSubtree(
                    child,
                    parentClip: h.nextChildClip,
                    inheritedInert: h.nextInert,
                    parentOpacity: childOpacity,
                    inheritedTransform: h.nextChildTransform,
                    parentIsDissolve: h.isDissolveScope,
                    parentScaleMotion: h.scaleMotion,
                    parentElementIndex: h.elementIndex,
                    allowRaised: allowRaised,
                    parentInCache: childInCache,
                    parentIsRotated: childIsRotated
                ) {
                    subtreeDynamic = true
                }
            }

            paintNodeFooter(
                node,
                activeClip: h.activeClip,
                activeFade: h.activeFade,
                effOpacity: h.effOpacity,
                effBlur: h.effBlur,
                rectPx: h.rectPx,
                radiiPx: h.radiiPx,
                needsLayer: h.needsLayer,
                outerLayerStarts: h.outerLayerStarts,
                cacheEligible: h.cacheEligible,
                subtreeDynamic: subtreeDynamic,
                layerStartIdx: h.layerStartIdx,
                surfaceStartIdx: h.surfaceStartIdx,
                glyphFixupStartIdx: h.glyphFixupStartIdx,
                imageFixupStartIdx: h.imageFixupStartIdx,
                effScale: h.effScale,
                nodePaintHash: h.nodePaintHash,
                elideCache: h.elideCache
            )
            return subtreeDynamic
        }

        clearPressRestingHits()
        for r in roots {
            paintSubtree(r, parentClip: rootClip, inheritedInert: false, parentOpacity: 1.0, allowRaised: false)
        }
        for raisedNode in collectedRaisedNodes {
            var chain: [NodeId] = []
            var cursor = parentById[raisedNode.nodeId]
            while let pIdx = cursor {
                chain.append(pIdx)
                cursor = parentById[pIdx]
            }
            var reopenedLayers: [(start: Int, surfaceStart: Int)] = []
            for pIdx in chain.reversed() {
                guard let st = savedNodeStates[pIdx] else { continue }
                if abs(st.rotate) > 1e-4 {
                    let sIdx = instances.count
                    let sfIdx = newSurfaces.count
                    var marker = RenderInstance.beginLayer(
                        bounds: st.rectPx,
                        clip: st.outerTurnClip,
                        spec: LayerSpec(opacity: 1.0, blend: .sourceOver, blur: 0, clipRadius: 0)
                    )
                    marker = marker.turned(
                        angle: st.rotate,
                        pivot: SIMD2<Float>(st.rectPx.x + st.rectPx.z * 0.5, st.rectPx.y + st.rectPx.w * 0.5)
                    )
                    instances.append(marker)
                    marks.append(0)
                    reopenedLayers.append((sIdx, sfIdx))
                }
                if let rPx = st.ownClipRadiiPx {
                    let sIdx = instances.count
                    let sfIdx = newSurfaces.count
                    var marker = RenderInstance.beginLayer(
                        bounds: st.rectPx,
                        clip: st.boundsClipPx,
                        spec: LayerSpec(opacity: 1.0, blend: .sourceOver, blur: 0, clipRadius: 0)
                    )
                    marker.roundClipCorners(rPx)
                    instances.append(marker)
                    marks.append(0)
                    reopenedLayers.append((sIdx, sfIdx))
                }
            }
            if let parentId = parentById[raisedNode.nodeId], let pst = savedNodeStates[parentId] {
                let raisedParentClip = RenderClipState(
                    rectPt: pst.visibleClipPt,
                    clipPx: pst.unclippedClipPx,
                    fadeWidth: pst.unclippedFadeWidth,
                    fadeOrigin: pst.unclippedFadeOrigin,
                    fade: pst.unclippedFade,
                    roundedMask: nil,
                    withoutScrollWidth: pst.withoutScrollWidth,
                    withoutScrollOrigin: pst.withoutScrollOrigin
                )
                paintSubtree(
                    raisedNode,
                    parentClip: raisedParentClip,
                    inheritedInert: pst.nextInert,
                    parentOpacity: pst.effOpacity,
                    inheritedTransform: pst.nextChildTransform,
                    parentIsDissolve: pst.isDissolveScope,
                    parentScaleMotion: PaintScaleMotion(rawValue: pst.scaleMotionRaw) ?? .still,
                    parentElementIndex: pst.elementIndex,
                    allowRaised: true
                )
            } else {
                paintSubtree(raisedNode, parentClip: rootClip, inheritedInert: false, parentOpacity: 1.0, allowRaised: true)
            }
            for (sIdx, sfIdx) in reopenedLayers.reversed() {
                closeLayer(start: sIdx, surfaceStart: sfIdx)
            }
        }

        measureTextFlightDestinations(in: newDrawnRectByPath, at: now)

        forEachTextFlightGlyph(at: now) { glyph, rect, ink, clip in
            let clipEdges = SIMD4(clip.x, clip.y, clip.x + clip.z, clip.y + clip.w)
            appendTextGlyph(glyph, rect: rect, ink: SIMD4(ink.x * ink.w, ink.y * ink.w, ink.z * ink.w, ink.w),
                            clip: clipEdges, fade: .zero, forceScaled: true)
        }

        // Glyph pages use normalized UVs, while image positions already use stable atlas texels.
        let glyphPages = textSystem.glyphAtlas.pageCount
        let compositedGlyphs = textSystem.glyphAtlas.compositedAtlas()
        let glyphW = Float(compositedGlyphs.width)
        let glyphH = Float(compositedGlyphs.height)
        for fix in glyphFixups where fix.index < instances.count {
            let pageIdx = Float(min(Int(fix.page), max(0, glyphPages - 1)))
            let ny0 = glyphPages > 1 ? (fix.normUV.y + pageIdx) / Float(glyphPages) : fix.normUV.y
            let ny1 = glyphPages > 1 ? (fix.normUV.w + pageIdx) / Float(glyphPages) : fix.normUV.w
            let u0 = fix.normUV.x * glyphW
            let v0 = ny0 * glyphH
            let uw = max(1.0, (fix.normUV.z - fix.normUV.x) * glyphW)
            let vh = max(1.0, (ny1 - ny0) * glyphH)
            let scaled = fix.forceScaled || abs(uw - fix.texW) > 0.5 || abs(vh - fix.texH) > 0.5
            instances[fix.index].uv = SIMD4<Float>(u0, v0, scaled ? uw : 0, scaled ? vh : 0)
        }

        for fix in imageFixups where fix.index < instances.count {
            let edges = fix.texelEdges
            instances[fix.index].uv = SIMD4(edges.x, edges.y, edges.z - edges.x, edges.w - edges.y)
        }

        if publishHitGeometry {
            self.seenMatchedByFlightId = newSeenMatched
            self.hitGeometryByPath = newHitGeometries
            self.paintOrderPaths = newElements.map(\.path)
        }
        linkBoxesByPath = newLinkBoxes
        appendLinkElements(to: &newElements)
        lastElements = newElements
        self.presentedRectByPath = newPresentedRects
        self.presentedScaleByPath = newPresentedScales
        self.presentedScaleMotionById = newPresentedScaleMotionById
        self.drawnRectByPath = newDrawnRectByPath
        self.rectSpringingById = newRectSpringingById
        self.surfaces = newSurfaces
        finishSurfaceVideoPaint(surfaceVideo)

        let clear = clearColor.simd4(srgb: srgbBlend)
        var output = RenderFrame(
            width: widthPx,
            height: heightPx,
            srgbBlend: srgbBlend,
            clearColor: SIMD4<Float>(clear.x * clear.w, clear.y * clear.w, clear.z * clear.w, clear.w),
            glyphs: compositedGlyphs,
            glyphGeneration: textSystem.glyphAtlas.generation,
            images: imagePacker.atlas,
            imageRevision: imagePacker.revision,
            instances: instances,
            marks: marks,
            surfaces: newSurfaces,
            materials: materials,
            residentTracker: residentCacheTracker
        )
        output.elidedLayers = elidedLayers
        output.imagePatch = imagePacker.publishPatch()
        return output
    }
}
