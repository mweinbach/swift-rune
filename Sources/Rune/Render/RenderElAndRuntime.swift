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

extension SIMD4 where Scalar == Float {
    func withContinuousCorners(_ continuous: Bool) -> Self {
        continuous ? Self(-abs(x), -abs(y), -abs(z), -abs(w)) : self
    }
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
    glyphAtlas: GlyphAtlas,
    imageVersion: (ImageAtlasRegion) -> UInt64,
    userKey: UInt64?
) -> UInt64 {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325
    fnvMix(&h, UInt64(instances.count))
    fnvMix(&h, UInt64(surfacesCount))
    fnvMixFloat(&h, size.x)
    fnvMixFloat(&h, size.y)
    fnvMixFloat(&h, blurPx)
    fnvMix(&h, srgbBlend ? 1 : 0)
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
            fnvMix(&h, imageVersion(ImageAtlasRegion(page: Int(inst.params.x), edges: inst.border == .zero ? inst.uv : inst.border)))
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
    var usedGlyphPages: UInt8 = 0
    for fix in glyphFixups {
        usedGlyphPages |= 1 << fix.page
        fnvMix(&h, UInt64(fix.page))
        fnvMixFloat4(&h, fix.normUV)
        fnvMixFloat(&h, fix.texW)
        fnvMixFloat(&h, fix.texH)
        fnvMix(&h, fix.forceScaled ? 1 : 0)
    }
    if usedGlyphPages != 0 {
        let (size, epoch) = glyphAtlas.pageSignature(usedPages: usedGlyphPages)
        fnvMix(&h, UInt64(size.x))
        fnvMix(&h, UInt64(size.y))
        fnvMix(&h, epoch)
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
    var viewportApplies = true
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

private typealias PaintHeader = (
    continueSubtree: Bool,
    subtreeDynamic: Bool,
    effOpacity: Float,
    effBlur: Float,
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
)

private struct PaintContext {
    let clip: RenderClipState
    let inert: Bool
    let groupHover: Float
    let opacity: Float
    let enclosingOpacity: Float
    let transform: PresentedTransform
    let dissolve: Bool
    let scaleMotion: PaintScaleMotion
    let element: Int?
    let allowRaised: Bool
    let inCache: Bool
    let rotated: Bool
}

private struct PaintBranch {
    let slot: Int
    let header: PaintHeader
    let context: PaintContext
    let children: ArraySlice<Int>
    var nextChild: Int
    let savedMark: UInt32
    var dynamic: Bool
}

/// A composited layer can reset the renderer's clip and opacity for its inner draws.
/// Pointer geometry keeps the logical clip, turn, and opacity through that layer.
private struct RenderHitScope {
    var localClip: MotionRect?
    var outerClip: MotionRect?
    var turn: Turn?
    var opacity: Float = 1
    var blur: Float = 0
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
    var enclosingLayerOpacity: Float
    var nextInert: Bool
    var nextChildTransform: PresentedTransform
    var childIsRotated: Bool
    var isDissolveScope: Bool
    var scaleMotionRaw: Int
    var rectPx: SIMD4<Float>
    var boundsClipPx: SIMD4<Float>
    var ownClipRadiiPx: SIMD4<Float>?
    var rotate: Float
    var turnPivot: SIMD2<Float>
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
        let fresh = buildRenderFrame(frameOut: frameOut, now: time, freshRaster: true)
        return (fresh, RasterCheck.compare(settled, fresh, at: time))
    }

    private func withRenderFrame<T>(at now: Double, finish: (RenderFrame, FrameOutput, Double) -> T) -> T {
        RuntimeIdScope.$current.withValue(runtimeId) {
            Theme.withBlend(srgbBlend) {
                let interactionStart = interactionFrameBegins()
                frameHadCommitted = false
                lastWasSettled = false
                let timer = beginFrameTimers(at: now)
                var (frameOut, animNow) = stepToFrameOutputScaled(at: now, skipFramePoll: timer.alreadyPolled)
                func paint() -> RenderFrame {
                    measureRuntimePhase(.paint) {
                        buildRenderFrame(frameOut: frameOut, now: animNow, publishHitGeometry: true)
                    }
                }
                var rf = paint()
                for _ in 0..<3 {
                    if !followKeeps(frameOut: &frameOut, at: animNow) { break }
                    rf = paint()
                }
                landUnseenEntrances(on: &scene)
                endUnseenExits(on: &scene)
                kitHooks.unseenPresence.recordPostBuildFilterSeen(nodes: flatNodes)
                frameMovedScrollPaths.removeAll(keepingCapacity: true)
                frameLandingHoldIds.removeAll(keepingCapacity: true)
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
                if rewindRecorder != nil { captureRewindFrame(at: now) }
                if let interactionStart { interactionBuilt(shapedSince: interactionStart) }
                return result
            }
        }
    }

    internal func buildRenderFrame(frameOut: FrameOutput, now: Double, publishHitGeometry: Bool = false,
                                   freshRaster: Bool = false) -> RenderFrame {
        cyclePaint.begin()
        if publishHitGeometry { kitHooks.unseenPresence.beginFrame() }
        activePaintedLoopWake = nil
        activePaintedLoopsAnimating = false
        beginPixelPaint()
        defer { finishPixelPaint() }
        beginPaintGlyphFrame(pinnedMask: 0)
        textSystem.beginOutlineFrame()
        let defaultForeground = cxSettings.viewDefaults.textForeground
        var outlineGeneration: UInt64?
        var usedOutlines = false
        var usedLCD = false
        var outlineSupport: [Bool: (outlines: Bool, lcd: Bool)] = [:]

        func supportsLCDMasks() -> Bool {
            guard let prepare = textSystem.outlineRendererSupport else { return false }
            if let known = outlineSupport[true] { return known.lcd }
            let result = prepare(true)
            outlineSupport[true] = result
            return result.lcd
        }

        func supportedOutlineMode(_ requested: FontSmoothing, moving: Bool) -> FontSmoothing? {
            let mode = requested == .systemDefault ? textSystem.smoothing : requested
            guard mode.isOutlineMode, let prepare = textSystem.outlineRendererSupport else { return nil }
            let lcd = mode.isLCD
            let support: (outlines: Bool, lcd: Bool)
            if let known = outlineSupport[lcd] {
                support = known
            } else {
                guard moving || lcd else { return nil }
                support = prepare(lcd)
                outlineSupport[lcd] = support
            }
            return support.outlines ? mode.drawn(lcdOK: support.lcd) : nil
        }

        func directOutlineMode(_ requested: FontSmoothing, node: NodeId, moving: Bool) -> (mode: FontSmoothing?, lcdMask: Bool) {
            let mode = requested == .systemDefault ? textSystem.smoothing : requested
            guard mode.isOutlineMode, textSystem.outlineRendererSupport != nil else { return (nil, false) }
            let (path, effects) = textSystem.outlinePaths.step(node: node.rawValue, frame: moving ? .moving : .resting)
            if !effects.isEmpty { elSliceRenderState.cacheScaleFramePending = true }
            guard path.emit == .outline || mode.isLCD else { return (nil, false) }
            guard let drawn = supportedOutlineMode(mode, moving: path.emit == .outline),
                  path.emit == .outline || drawn.isLCD else { return (nil, false) }
            return (drawn, path.emit == .atlas && drawn.isLCD)
        }

        elSliceRenderState.cacheScaleFramePending = false
        let commitGen = UInt64(viewCommitCount)
        if !freshRaster && labelDrawCommit != viewCommitCount {
            labelDraws.removeAll(keepingCapacity: true)
            labelDrawCommit = viewCommitCount
        }
        var nextLabelDraws: [NodeId: RetainedLabelDraws] = [:]
        if !freshRaster { nextLabelDraws.reserveCapacity(labelDraws.count) }

        let scale = max(pixelScale, 0.5)
        let widthPx = max(1, Int((viewport.x * scale).rounded()))
        let heightPx = max(1, Int((viewport.y * scale).rounded()))

        pixelSnapGlides.beginFrame(t: now, size: SIMD2<Float>(Float(widthPx), Float(heightPx)))
        var childSnapByNode: [NodeId: PixelSnap.Inherit] = [:]
        let paintMotion = PaintMotionTracks(store: scene.store)
        var carriedScrollCache = makeCarriedScrollCache()
        let presentedById = frameOut.paintNodesById
        var exitingIds: Set<NodeId> = []
        for p in frameOut.nodes where p.isExiting { exitingIds.insert(p.id) }

        let hasHolds = !scrollRequestsState.keeps.isEmpty
        let topology = prepareNativePaintTopology(frameOut, byID: presentedById, holds: hasHolds)
        let hasSticky = topology.hasSticky
        let hasRaised = topology.hasRaised
        let hasAnimatedTracks = scene.store.activeLen != 0
        let canPaintFocusRing = focusedPath != nil || cxSettings.viewDefaults.forceFocusRings
        func renderNode(_ slot: Int) -> FlatNode { slot >= 0 ? flatNodes[slot] : topology.exits[~slot] }
        let renderNodes = topology.order.lazy.map(renderNode)
        var beforeSticky: [NodeId: MotionRect] = [:]
        stuckShiftsByPath.removeAll(keepingCapacity: true)
        var newElements: [ElementInfo] = []
        newElements.reserveCapacity(frameOut.nodes.count)
        var rawPoseByPath: [String: RawPoseNodeData] = [:]
        var movingGrowthPaths: Set<String> = []
        var flightTargets: Set<NodeId> = []
        var flightSources: Set<NodeId> = []
        if publishHitGeometry {
            movingGrowthPaths = movingGrowthPaintPaths()
            for flight in activeTextFlights {
                flightTargets.insert(flight.targetNodeId)
                for node in renderNodes where FlightSelector.selects(flight.state.sourceKey, path: node.path, key: node.key) {
                    flightSources.insert(node.nodeId)
                }
            }
        }
        var hasInheritedFlags = !frameLandingHoldIds.isEmpty
        var newSeenMatched: [String: MatchedSeenSnapshot] = [:]
        var newHitGeometries = Dictionary<String, HitGeometry>(minimumCapacity: publishHitGeometry ? frameOut.nodes.count : 0)
        var newLinkBoxes: [String: [TextLinkBox]] = [:]
        var hitScopes: [RenderHitScope] = []
        if publishHitGeometry { hitScopes.reserveCapacity(frameOut.nodes.count) }
        var newPresentedRects = Dictionary<String, MotionRect>(minimumCapacity: frameOut.nodes.count)
        var newPresentedScales = Dictionary<String, Vec2>(minimumCapacity: frameOut.nodes.count)
        var newPresentedScaleMotionById = Dictionary<NodeId, PaintScaleMotion>(minimumCapacity: frameOut.nodes.count)
        var drawnOverrides: [String: MotionRect] = [:]
        // Raster-only walks omit hit scopes but still need rotated ancestors for drawn bounds.
        var rasterTurns: [Int: Turn] = [:]
        var newRectSpringingById: [NodeId: Bool] = [:]
        let selectableRanges = computeActiveSelectionRangesByPath()
        let markedPaths = Set(selectionState.lastCommittedMarkedTexts.map(\.path))
        var instances: [RenderInstance] = []
        var elidedLayers: [(index: Int, node: UInt64, signature: UInt64)] = []
        var marks: [UInt32] = []
        var newSurfaces: [SurfaceDraw] = []
        var surfaceVideo = SurfaceVideoPaint()
        let zeroScroll: [Float] = [0, 0]
        var lastCarried = Vec2.zero
        var lastCarriedPair = zeroScroll
        var currentInheritedMark: UInt32 = 0
        var materials: [MaterialDraw] = []
        var backdropBlurCount = 0

        // Publish normalized glyph pages and image texel edges in the renderer's origin/size ABI.
        var glyphFixups: [GlyphUVFixup] = []
        // Zero denotes a padded icon. Positive values are the vertical phase of a native text mask.
        var motionGlyphMasks: [SIMD3<Float>: Float] = [:]
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

        let hoverStore = liveStore
        let hasLiveTracks = hoverStore.trackLen > 0
        var groupHoverChecker: GroupHoverContext?
        func resolveNodeHoverFrac(_ n: FlatNode, inert: Bool) -> Float {
            let nid = n.nodeId
            if inert || exitingIds.contains(nid) { return 0.0 }
            if hasLiveTracks, let tracked = hoverStore.get(Runtime.hoverTrackId(nid), Runtime.hoverProp) {
                return tracked.clamped(to: 0...1)
            }
            // Synced hover without a track rests at 0 (`paint/tracks.rs::ready_from_rest`).
            if lastHoverTargetById[nid] != nil { return 0.0 }
            if n.el.isHoverGroup || n.el.hoverGroupShare != nil {
                if groupHoverChecker == nil { groupHoverChecker = makeGroupHoverPredicate() }
                return groupHoverChecker!(n) ? 1.0 : 0.0
            }
            return hoveredPath == n.path ? 1.0 : 0.0
        }

        var nodeOwnOpacityById: [NodeId: Float] = [:]
        var loopSamples: [NodeId: LoopSampleResult] = [:]
        var nodeHoverFracById: [NodeId: Float] = [:]
        var nodePressById: [NodeId: (color: Color?, frac: Float)] = [:]
        typealias InteractionScope = (inert: Bool, group: Float, press: (color: Color?, frac: Float))
        func collectHoverAndOwnOpacity(_ n: FlatNode, scope: InteractionScope) -> InteractionScope {
            let effInert = scope.inert || n.el.isInert
            let nid = n.nodeId
            if let parent = presentedById[nid]?.parent, exitingIds.contains(parent) { exitingIds.insert(nid) }
            let el = n.el
            var liveOp: Float? = nil
            var liveRect: MotionRect? = nil
            for b in el.liveBindings {
                let lnid = NodeId.hash("live:\(n.path):\(b.target)")
                if b.target == .opacity, let v = liveStore.get(lnid, Props.OPACITY) { liveOp = v }
                else if b.target == .rect, let r = liveStore.get(lnid, Props.RECT) { liveRect = r }
            }
            let baseSize = (liveRect ?? presentedById[nid]?.rect ?? n.targetRect).size
            let loop = loopRuntime.tracks[nid] == nil ? nil : sampleLoopPresentation(id: nid, nodeSize: baseSize, wallNow: currentTime)
            if let loop { loopSamples[nid] = loop }
            let loopOp = loop?.opacity ?? 1.0
            let groupFactor = resolveGroupOpacityFactor(
                nodeId: nid,
                el: el,
                nodePath: n.path,
                inheritedGroupFrac: scope.group
            )
            let ownOp = ((liveOp ?? presentedById[nid]?.opacity ?? el.opacity) * groupFactor * loopOp).clamped(to: 0...1)
            let ownHoverFrac = resolveNodeHoverFrac(n, inert: effInert)
            let ownPress: (color: Color?, frac: Float) = {
                if let pc = el.pressColor {
                    let isPressedNode = isNodePressedVisually(path: n.path, effectiveInert: effInert || exitingIds.contains(nid))
                    let frac = (liveStore.get(Runtime.pressTrackId(nid), Runtime.pressProp) ?? (isPressedNode ? 1.0 : 0.0)).clamped(to: 0...1)
                    return (pc, frac)
                }
                return scope.press
            }()
            if ownOp != 1 || el.opacity != 1 { nodeOwnOpacityById[nid] = ownOp }
            if ownHoverFrac != 0 { nodeHoverFracById[nid] = ownHoverFrac }
            if ownPress.color != nil && ownPress.frac != 0 { nodePressById[nid] = ownPress }

            let isGroupScope = el.isHoverGroup || el.hoverBg != nil || el.hoverGroupShare != nil
            return (effInert, isGroupScope ? ownHoverFrac : scope.group, ownPress)
        }
        let hasGroupOpacity = topology.hasGroupOpacity || !elSliceRenderState.groupFadeIds.isEmpty
        // Group opacity follows the current parent in paint order. Raised or dissolving
        // branches can draw out of order or inspect children before the first child paints.
        let needsInteractionPrepass = (hasGroupOpacity && hasRaised) || topology.hasPressColor
            || !topology.dissolveIndices.isEmpty || !loopRuntime.tracks.isEmpty || !exitingIds.isEmpty
        if needsInteractionPrepass {
            var pending: [(slot: Int, scope: InteractionScope)] = []
            for root in topology.roots.reversed() { pending.append((root, (false, 0, (nil, 0)))) }
            while let (slot, parent) = pending.popLast() {
                let node = renderNode(slot)
                let scope = collectHoverAndOwnOpacity(node, scope: parent)
                for child in topology.children(of: node).reversed() { pending.append((child, scope)) }
            }
        }

        // Only direct children participate in a dissolve. Scratch indices retain filtered scene order.
        hasDissolve = !topology.dissolveIndices.isEmpty
        var dissolveParentIds: Set<NodeId> = []
        if hasDissolve {
            var scratch = [Bool](repeating: false, count: topology.order.count)
            for index in topology.dissolveIndices {
                let parent = renderNode(topology.order[index])
                for slot in topology.children(of: parent) {
                    let child = renderNode(slot)
                    guard !child.el.isRaised else { continue }
                    let opacity = nodeOwnOpacityById[child.nodeId] ?? child.el.opacity
                    if opacity > 0.001 && opacity < 1 {
                        scratch[index] = true
                        dissolveParentIds.insert(parent.nodeId)
                        break
                    }
                }
            }
            dissolveScratch = scratch
        } else {
            dissolveScratch.removeAll(keepingCapacity: true)
        }

        let hasPresenceFlights = !activeFlightIds.isEmpty || !launchedFlightIds.isEmpty || !unclippedMatchedFlightIds.isEmpty
        let initialClipPt = MotionRect(left: 0, top: 0, right: viewport.x, bottom: viewport.y)
        let rootClip = RenderClipState(rectPt: initialClipPt, clipPx: NO_CLIP, fade: .zero)
        let materialMode = MaterialMode.launchMode
        let useNativeMaterials = nativeMaterials && materialMode != .fallback
        var savedNodeStates: [NodeId: SavedRaisedNodeState] = [:]
        var collectedRaisedNodes: [(slot: Int, offset: Int)] = []
        var raisedRanges: [(offset: Int, indices: Range<Int>)] = []

        func subtreeContains(_ node: FlatNode, where predicate: (FlatNode) -> Bool) -> Bool {
            if predicate(node) { return true }
            var pending = Array(topology.children(of: node).reversed())
            while let slot = pending.popLast() {
                let child = renderNode(slot)
                if predicate(child) { return true }
                pending.append(contentsOf: topology.children(of: child).reversed())
            }
            return false
        }

        @inline(never)
        func hasDynamicInSubtree(_ node: FlatNode) -> Bool {
            subtreeContains(node) { n in
                presentedById[n.nodeId]?.isMoving == true
                || loopSamples[n.nodeId] != nil
                || exitingIds.contains(n.nodeId)
                || activeTextFlights.contains(where: {
                    $0.targetNodeId == n.nodeId || FlightSelector.selects($0.state.sourceKey, path: n.path, key: n.key)
                })
                || (!selectableRanges.isEmpty && selectableRanges[n.path] != nil)
                || (!markedPaths.isEmpty && markedPaths.contains(n.path))
                || n.el.isSecure
                || (n.el.handlers.editLens?.get(state).isSecure == true)
                || !n.el.liveBindings.isEmpty
                || n.el.pixelsPayload != nil
                || n.el.surfacePayload != nil
                || n.el.runtimeExtras[RenderExtrasKey.effectSpec] != nil
                || n.el.runtimeExtras["systemMaterial"] != nil
                || n.el.backdropBlur > 0
            }
        }

        func hasLiveTextInSubtree(_ node: FlatNode) -> Bool {
            subtreeContains(node) { $0.el.liveText != nil }
        }

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
            rotated: Bool,
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
                if let svg = chip.icon, let rect = chip.iconRect {
                    emitMask(svg, rect: rect, color: chip.iconColor ?? defaultTextColor)
                }
            }
            for inline in shaped.inlineIcons {
                if let img = inline.image, img.width > 0, img.height > 0 {
                    var box = deviceRect(inline.rect)
                    let fit = min(box.z / Float(img.width), box.w / Float(img.height))
                    let w = Float(img.width) * fit, h = Float(img.height) * fit
                    box = SIMD4(box.x + (box.z - w) / 2, box.y + (box.w - h) / 2, w, h)
                    let region = imagePacker.insert(img)
                    let uv = region.edges
                    let radius = min(inline.cornerRadius * min(sc.x, sc.y) * scale, min(w, h) / 2)
                    imageFixups.append((instances.count, uv, Float(img.width), Float(img.height)))
                    instances.append(RenderInstance(rect: box, radii: SIMD4(repeating: radius),
                        fill: SIMD4(repeating: localOpacity), params: SIMD4(Float(region.page), KIND_IMAGE, 0, 1), uv: uv, clip: clipEdges, fade: fade))
                    marks.append(0)
                } else if let svg = inline.icon {
                    emitMask(svg, rect: inline.rect, color: inline.color ?? defaultTextColor)
                }
            }

            func deviceRect(_ rect: SIMD4<Float>) -> SIMD4<Float> {
                SIMD4((textLeft + rect.x * sc.x) * scale, (textTop + rect.y * sc.y) * scale,
                      rect.z * sc.x * scale, rect.w * sc.y * scale)
            }
            func emitMask(_ svg: SVGIcon, rect: SIMD4<Float>, color: Color) {
                let pxSize = max(4, Int((min(rect.z, rect.w) * rasterScale * scale).rounded()))
                let entry = textSystem.glyphAtlas.rasterizeIcon(svg, pixelSize: pxSize)
                let tint = premulSIMD4(color, opacity: localOpacity, srgb: srgbBlend)
                appendIcon(entry, rect: deviceRect(rect), ink: tint, clip: clipEdges, fade: fade, rotated: rotated)
            }
        }

        func appendIcon(_ entry: GlyphAtlas.Entry, rect: SIMD4<Float>, ink: SIMD4<Float>,
                        clip: SIMD4<Float>, fade: SIMD4<UInt32>, rotated: Bool = false) {
            guard entry.uv != .zero else { return }
            let pixels = SIMD2(Float(entry.pixelSize.x), Float(entry.pixelSize.y))
            let near: (Float) -> Bool = { abs($0 - $0.rounded()) < 1.0 / 512 }
            let aligned = !rotated && near(rect.x) && near(rect.y)
                && abs(rect.z - pixels.x) < 1.0 / 512 && abs(rect.w - pixels.y) < 1.0 / 512
            var box = SIMD4(rect.x.rounded(), rect.y.rounded(), pixels.x, pixels.y)
            var uv = entry.uv
            if !aligned {
                // Linear filtering needs the transparent gutter around a moving or scaled mask.
                let texel = SIMD2(rect.z, rect.w) / pixels
                let du = (uv.z - uv.x) / pixels.x, dv = (uv.w - uv.y) / pixels.y
                box = rect + SIMD4(-texel.x, -texel.y, 2 * texel.x, 2 * texel.y)
                uv += SIMD4(-du, -dv, du, dv)
                if motionRasterGlyphs != nil { motionGlyphMasks[SIMD3(uv.x, uv.y, Float(entry.page))] = 0 }
            }
            glyphFixups.append((instances.count, uv, box.z, box.w, entry.page, !aligned))
            instances.append(RenderInstance(rect: box, radii: .zero, fill: ink, border: .zero,
                                            params: SIMD4(0, KIND_GLYPH, 0, 1), uv: uv, clip: clip, fade: fade))
            marks.append(0)
        }

        var labelRasters = TextBoxGeometry.ScaledLabelRasters()
        var previousGlyphInk: SIMD4<Float>?
        var previousInkBucket: UInt8?
        func appendTextGlyph(_ source: PositionedGlyph, rect sourceRect: SIMD4<Float>, ink: SIMD4<Float>,
                             clip: SIMD4<Float>, fade: SIMD4<UInt32>, forceScaled: Bool,
                             outlineMode: FontSmoothing? = nil, desktopOutline: TextOutlineGroup? = nil, lcdMask: Bool = false) {
            let glyph: PositionedGlyph, rect: SIMD4<Float>
            if source.usesInkDilation && ink.w > 0 {
                if previousGlyphInk != ink {
                    previousGlyphInk = ink
                    previousInkBucket = GlyphAtlas.inkBucket(ink / ink.w, encoded: srgbBlend)
                }
                (glyph, rect) = textSystem.glyphAtlas.outlineInk(source, rect: sourceRect, bucket: previousInkBucket)
            } else {
                (glyph, rect) = (source, sourceRect)
            }
            if let outlineMode, let group = glyph.outlineGroup ?? desktopOutline {
                if outlineGeneration == nil { outlineGeneration = textSystem.glyphAtlas.withOutlineStore { $0.generation } }
                if lcdMask, group.generation == outlineGeneration, let sample = textSystem.glyphAtlas.lcdMask(for: group) {
                    glyphFixups.append((instances.count, sample.uv, rect.z, rect.w, sample.page, forceScaled))
                    instances.append(RenderInstance(rect: rect, radii: SIMD4(1, 0, 0, 0), fill: ink,
                        params: SIMD4(0, KIND_GLYPH, 0, textSystem.coverageExponent(ink, mode: outlineMode)),
                        uv: sample.uv, clip: clip, fade: fade))
                    marks.append(0)
                    usedLCD = true
                    return
                }
                if group.generation == outlineGeneration, group.appendInstances(into: &instances, marks: &marks, rect: rect, ink: ink,
                                     gamma: textSystem.coverageExponent(ink, mode: outlineMode),
                                     lcd: outlineMode.isLCD, clip: clip, fade: fade) {
                    usedOutlines = true
                    usedLCD = usedLCD || outlineMode.isLCD
                    return
                }
            }
            let index = instances.count
            let image = colorGlyphImage(glyph)
            let uv: SIMD4<Float>, gamma: Float
            var lcd: Float = 0
            if let image {
                uv = image.region.edges
                gamma = 1
                imageFixups.append((index, image.region.edges, Float(image.pixelSize.x), Float(image.pixelSize.y)))
            } else {
                let sample: (uv: SIMD4<Float>, page: UInt16, gamma: Float)
                if glyph.hasLCDMask, !forceScaled, ink.w > 0, supportsLCDMasks(),
                   let rgb = textSystem.lcdMask(for: glyph, rect: rect, ink: SIMD4(ink.x / ink.w, ink.y / ink.w, ink.z / ink.w, ink.w), encoded: srgbBlend) {
                    sample = (rgb.uv, rgb.page, 1)
                    usedLCD = true
                    lcd = 1
                } else {
                    sample = textSystem.glyphMask(for: glyph, premultipliedInk: ink, encoded: srgbBlend)
                }
                uv = sample.uv
                gamma = sample.gamma
                if motionRasterGlyphs != nil, glyph.maskShiftY > 0 {
                    motionGlyphMasks[SIMD3(uv.x, uv.y, Float(sample.page))] = glyph.maskShiftY
                }
                glyphFixups.append((index, uv, rect.z, rect.w, sample.page, forceScaled))
            }
            instances.append(RenderInstance(
                rect: rect, radii: SIMD4(lcd, 0, 0, 0),
                fill: image == nil ? ink : SIMD4(repeating: ink.w), border: .zero,
                params: SIMD4(Float(image?.region.page ?? 0), image == nil ? KIND_GLYPH : KIND_IMAGE, 0, gamma),
                uv: uv, clip: clip, fade: fade
            ))
            marks.append(0)
        }

        #if DEBUG
        // Leave the unoptimized geometry stack frame before invoking the font rasterizer.
        var pendingTextPaint: (() -> Void)?
        #endif

        @inline(never)
        func paintNodeHeader(
            _ node: FlatNode, el: El<State>, presented: Presented?, loop: LoopSampleResult?,
            parentClip inheritedClip: RenderClipState,
            inheritedInert: Bool,
            groupHover: inout Float,
            parentOpacity: Float,
            enclosingLayerOpacity: Float = 1,
            inheritedTransform: PresentedTransform,
            parentIsDissolve: Bool,
            parentScaleMotion: PaintScaleMotion,
            parentElementIndex: Int?,
            parentInCache: Bool = false,
            parentIsRotated: Bool = false
        ) -> PaintHeader {
            let nid = node.nodeId
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
            let subtreeDynamic = loop != nil || !el.liveBindings.isEmpty
                || el.surfacePayload != nil
                || el.runtimeExtras[RenderExtrasKey.effectSpec] != nil
                || el.runtimeExtras["systemMaterial"] != nil
                || el.backdropBlur > 0

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

            let presentedBorder = presented?.border.map(Color.init)
            let baseRect = liveRect ?? presented?.rect ?? node.targetRect
            let pinh: PresentedTransform
            var inheritedSnap = presented?.parent.flatMap { childSnapByNode[$0] } ?? rootPixelSnap
            inheritedSnap.grow(growthSnapOffsetY(for: node), stack: el.growthSpec != nil)
            var anchorScaleMotion: PaintScaleMotion = .still
            if let a = el.anchor,
               let anchorNode = renderNodes.first(where: { $0.key == a.key }) ?? flatNodes.first(where: { $0.key == a.key }) {
                inheritedSnap.placeAtAnchor()
                let anchorRect = newPresentedRects[anchorNode.path]
                    ?? presentedRectByPath[anchorNode.path]
                    ?? anchorNode.zoomedTargetRect
                let anchorParentId = presentedById[anchorNode.nodeId]?.parent
                    ?? anchorNode.parentIndex.flatMap { flatNodes.indices.contains($0) ? flatNodes[$0].nodeId : nil }
                let anchorParentPath: String? = anchorParentId.flatMap { (mountedNode($0) ?? exitingSnapshots[$0])?.path }
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
            let loopOffset = loop?.offset ?? .zero
            let lo = Vec2((liveOffset?.x ?? 0) + loopOffset.x, (liveOffset?.y ?? 0) + loopOffset.y)
            let baseScale = presented?.scale ?? el.scale
            let baseScNoPress = Vec2(baseScale.x * (loop?.scale ?? 1), baseScale.y * (loop?.scale ?? 1))
            let ownScNoPress = liveScale.map { Vec2(baseScNoPress.x * max(0, $0.x), baseScNoPress.y * max(0, $0.y)) } ?? baseScNoPress
            let pressSc = el.pressScaleFactor == nil ? 1 : pressScaleValue(for: nid)
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
            var nextChildTransform = PresentedTransform(
                dx: ownDx,
                dy: ownDy - extraScrollY,
                anchor: anchor,
                anchorTo: anchorTo,
                scale: sc
            )
            let staticOffset = (presented?.rect == nil || liveRect != nil) ? el.offset : .zero
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
            let parentShift: Vec2
            if !stuckShiftsByPath.isEmpty, let id = presented?.parent, let parent = mountedNode(id) ?? exitingSnapshots[id] {
                parentShift = stuckShiftsByPath[parent.path] ?? .zero
            } else {
                parentShift = .zero
            }
            var stickyShift = parentShift
            if hasSticky {
                beforeSticky[nid] = effRect
                if el.anchor != nil && !node.isSticky {
                    stickyShift = .zero
                } else if (node.isSticky || hasHolds) && nodeIndexById[nid] != nil {
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
            let ownScaleSpringMoving = paintMotion.unheldScale.contains(nid)
            let ownLiveScaleMoving = el.liveBindings.contains { b in
                b.target == .scale
                    && (liveStore.isMoving(NodeId.hash("live:\(node.path):\(b.target)"), Props.SCALE) || isLinearTweenActive(b.source))
            }
            let effectiveParentScaleMotion = max(parentScaleMotion, anchorScaleMotion)
            let nodeScaleMotion = textScaleMotion(
                node: nid, local: ownSc.x, world: sc.x, inherited: effectiveParentScaleMotion,
                live: el.liveBindings.contains(where: { $0.target == .scale }), anchored: el.anchor != nil,
                animating: ownScaleSpringMoving || ownLiveScaleMoving, at: now)
            newPresentedScaleMotionById[nid] = nodeScaleMotion
            let restScale = el.anchor != nil && effectiveParentScaleMotion == .still ? pinh.scale.x : pinh.stillScale
            nextChildTransform.stillScale = nodeScaleMotion == .still ? sc.x : restScale
            let rasterScale = nodeScaleMotion.raster(sc: sc.x, rest: restScale)
            let effInert = inheritedInert || el.isInert
            let hoverFrac = needsInteractionPrepass ? (nodeHoverFracById[nid] ?? 0) : resolveNodeHoverFrac(node, inert: effInert)
            let ownOpacity: Float
            if needsInteractionPrepass {
                ownOpacity = nodeOwnOpacityById[nid] ?? 1
            } else {
                let groupFactor = hasGroupOpacity
                    ? resolveGroupOpacityFactor(nodeId: nid, el: el, nodePath: node.path, inheritedGroupFrac: groupHover)
                    : 1
                ownOpacity = ((liveOpacity ?? presented?.opacity ?? el.opacity) * groupFactor).clamped(to: 0...1)
                if hasGroupOpacity && (el.isHoverGroup || el.hoverBg != nil || el.hoverGroupShare != nil) {
                    groupHover = hoverFrac
                }
            }
            let effOpacity = (parentOpacity * ownOpacity).clamped(to: 0...1)
            let effBlur = max(0, liveBlur ?? presented?.blur ?? el.blur)
            let isContinuousCorners = (el.runtimeExtras[RenderExtrasKey.continuousCorners] as? Bool) ?? false
            let baseRadii = SIMD4<Float>(
                el.corners.topLeft,
                el.corners.topRight,
                el.corners.bottomRight,
                el.corners.bottomLeft
            )
            let animR = presented?.corners
            let radiiPt = (animR.map { r in
                SIMD4<Float>(r.topLeft, r.topRight, r.bottomRight, r.bottomLeft)
            } ?? baseRadii).withContinuousCorners(isContinuousCorners)
            let radiiPx = radiiPt * scale

            let visibleClipPt = intersectRects(parentClip.rectPt, effRect)
            newPresentedRects[node.path] = effRect
            newPresentedScales[node.path] = sc

            let isExiting = exitingIds.contains(nid)
            let parentSpringing = !newRectSpringingById.isEmpty && presented?.parent.flatMap { newRectSpringingById[$0] } == true
            let ownSpatialMoving =
                paintMotion.spatial.contains(nid) ||
                (!el.layout.scrollAxes.isEmpty && scrollStore.isMoving(NodeId.hash("scroll:" + node.path), Props.SCROLL))
            if !isExiting {
                if parentSpringing || ownSpatialMoving { newRectSpringingById[nid] = true }
            }
            let flatFocusWithin = el.focusWithinFlat && !effInert && !isExiting && isFocusWithin(node.path)
            let hovered = !flatFocusWithin && !isExiting && (hoverFrac > 0.0005 || (!effInert && matchesAuthoredKey(hoveredKey, node.key)))
            let pressed = isNodePressedVisually(path: node.path, effectiveInert: effInert || isExiting) || (!effInert && !isExiting && pressedPath != node.path && pressedPointerInside && matchesAuthoredKey(pressedKey, node.key))
            let pressTint = nodePressById[nid] ?? (nil, 0.0)
            let focused = (focusedPath == node.path) && !isExiting
            let highlightActive = focused && (focusVisible || (el.focusHighlightColor != nil && hoveredHighlightActive))

            // At rest the authored fill preserves exact saturated channel endpoints.
            let animatedFill = presented?.fill.flatMap { fill in
                (presented?.isExiting == true || (hasAnimatedTracks && scene.store.isAnimating(nid, Props.FILL))) ? Color(fill) : nil
            }
            var effBg = liveFill ?? animatedFill ?? el.background
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
            let parentScope = publishHitGeometry ? parentElementIndex.map { hitScopes[$0] } : nil
            var turn = parentScope?.turn
            if !publishHitGeometry, !rasterTurns.isEmpty, let parentElementIndex {
                turn = rasterTurns[parentElementIndex]
            }
            let hasOwnTurn = abs(el.rotate) > 1e-4
            if hasOwnTurn {
                let pivot = Vec2(effRect.x + effRect.width * el.origin.x, effRect.y + effRect.height * el.origin.y)
                let localTurn = Turn.about(pivot, radians: el.rotate)
                turn = turn.map { $0.after(localTurn) } ?? localTurn
            }
            let infoRect = turn?.bbox(effRect) ?? effRect
            if !isExiting && (!exitingIds.isEmpty || infoRect != effRect) {
                drawnOverrides[node.path] = infoRect
            }
            var infoVisible = visibleClipPt
            var presenceScreenClip = initialClipPt
            var infoOpacity = effOpacity
            var infoBlur = effBlur
            let infoExiting = isExiting || parentScope?.exiting == true
            var loopVisible = false
            if liveVisible, !reducedMotion, !isExiting, let track = loopRuntime.tracks[nid] {
                let home = effRect.offsetBy(Vec2(-loopOffset.x * pinh.scale.x, -loopOffset.y * pinh.scale.y))
                let margin = 2 / scale + 3 * effBlur
                let localClip = parentScope?.localClip ?? parentClip.rectPt
                let world = turn?.bbox(home) ?? home
                let screen = intersectRects(parentScope?.outerClip ?? initialClipPt, initialClipPt)
                let baseOpacity = (parentScope?.opacity ?? parentOpacity) * (liveOpacity ?? presented?.opacity ?? el.opacity)
                loopVisible = baseOpacity >= 1.0 / 255.0 && localClip.width > 0 && localClip.height > 0 &&
                    home.right > localClip.left - margin && home.left < localClip.right + margin &&
                    home.bottom > localClip.top - margin && home.top < localClip.bottom + margin &&
                    world.right > screen.left - margin && world.left < screen.right + margin &&
                    world.bottom > screen.top - margin && world.top < screen.bottom + margin
                if loopVisible { schedulePaintedLoop(track, id: nid) }
            }
            if publishHitGeometry {
                var scope = parentScope ?? RenderHitScope()
                let parentScreenClip = Self.screenClipOfParent(
                    inheritedClip: scope.localClip, ancestorTurn: scope.turn,
                    outerTurnClip: scope.outerClip, localTurnClip: scope.localClip
                )
                if hasOwnTurn {
                    scope.turn = turn
                    scope.outerClip = parentScreenClip
                    scope.localClip = nil
                }
                scope.opacity *= ownOpacity
                scope.blur += effBlur * max(sc.x, sc.y)
                infoBlur = (parentElementIndex.map { newElements[$0].blur } ?? 0) + effBlur * sc.x
                if let parentScreenClip { presenceScreenClip = intersectRects(parentScreenClip, initialClipPt) }
                scope.exiting = infoExiting
                newHitGeometries[node.path] = HitGeometry(
                    path: node.path, paintOrder: myElementIndex, parentPath: parentElementIndex.map { newElements[$0].path },
                    rect: effRect, clipRect: scope.localClip ?? effRect,
                    outerClip: scope.outerClip.map { intersectRects($0, initialClipPt) } ?? initialClipPt,
                    turn: scope.turn, opacity: scope.opacity, isExiting: scope.exiting,
                    hasVisualBlocker: el.blocksHits(fill: effBg, border: liveBorderColor ?? presentedBorder ?? el.borderColor),
                    isInteractiveBlocker: el.blocksInteractiveHits,
                    parentScreenClip: parentScreenClip
                )
                infoVisible = intersectRects(infoRect, parentScreenClip ?? initialClipPt)
                infoOpacity = scope.opacity
                hitScopes.append(scope)
            } else if let turn {
                rasterTurns[myElementIndex] = turn
            }
            let carried = carriedScroll(for: node, scales: newPresentedScales, cache: &carriedScrollCache) { newHitGeometries[$0]?.turn }
            let reportedScroll: Vec2
            if el.layout.scrollAxes.isEmpty {
                reportedScroll = carried
            } else {
                let offset = scrollOffsets[node.path] ?? .zero
                reportedScroll = Vec2(offset.x, offset.y + (slice2State.scrollExtraYByPath[node.path] ?? 0))
            }
            let shadows = resolvedShadows(for: nid, authored: el.shadows)
            let editLens = el.hasEditLens ? el.handlers.editLens : nil
            let edit = isExiting ? nil : editLens?.get(state)
            let secure = el.isSecure || edit?.isSecure == true
            let words = secure ? nil : (edit?.text ?? el.plainText)
            let moving = presented?.isMoving == true
            let growing = !movingGrowthPaths.isEmpty && movingGrowthPaths.contains(node.path)
            let flightTarget = !flightTargets.isEmpty && flightTargets.contains(nid)
            let inFlight = flightTarget || (!flightSources.isEmpty && flightSources.contains(nid))
            var pose: RawPoseNodeData?
            if publishHitGeometry && needsPaintPose(node, el: el, rotation: el.rotate, shadows: shadows, growing: growing, inFlight: inFlight) {
                let liveSpatialMoving = el.liveBindings.contains { binding in
                    let id = NodeId.hash("live:\(node.path):\(binding.target)")
                    switch binding.target {
                    case .scale: return liveStore.isMoving(id, Props.SCALE) || isLinearTweenActive(binding.source)
                    case .offset: return liveStore.isMoving(id, Props.OFFSET) || isLinearTweenActive(binding.source)
                    case .rect: return liveStore.isMoving(id, Props.RECT) || isLinearTweenActive(binding.source)
                    default: return false
                    }
                }
                pose = inspectPaintedNode(
                    node, el: el, rotation: el.rotate, scale: sc.x, shadows: shadows, liveShadowColor: liveShadowColor,
                    spatialMoving: moving || liveSpatialMoving, flightTarget: flightTarget, inFlight: inFlight, growthMoving: growing
                )
                rawPoseByPath[node.path] = pose
                if let pose, pose.ownMoving || pose.ownScrolling || pose.ownGrowingRow || pose.ownMotionLive
                    || pose.ownLiveIntent != 0 || pose.instantHoverGroupRule {
                    hasInheritedFlags = true
                }
            }
            if moving { hasInheritedFlags = true }
            // Most descendants share one scroll translation, and an unclipped box has one
            // geometry for both inspection fields. Preserve the public arrays by sharing storage.
            if carried != lastCarried {
                lastCarried = carried
                lastCarriedPair = carried == .zero ? zeroScroll : [carried.x, carried.y]
            }
            let rect = infoRect.xywh
            newElements.append(ElementInfo(
                path: node.path,
                key: node.key,
                parentIndex: parentElementIndex,
                role: el.role,
                rect: rect,
                target: node.targetRect == infoRect ? rect : node.targetRect.xywh,
                committedLayoutTarget: node.committedLayoutTarget,
                visible: infoVisible == infoRect ? rect : infoVisible.xywh,
                opacity: infoOpacity,
                scale: sc.x,
                blur: infoBlur,
                radius: abs(radiiPt.x),
                fill: effBg,
                textColor: liveTextColor ?? el.textColor,
                text: words,
                label: el.a11yLabel ?? words,
                help: el.a11yHelp,
                selected: secure ? nil : el.a11ySelected,
                expanded: el.a11yExpanded,
                level: el.a11yLevel,
                itemSelected: el.itemSelected,
                focusable: el.focusable && !effInert,
                focused: focused,
                focusVisible: focused && focusVisible,
                inert: effInert || infoExiting,
                moving: pose?.ownMoving ?? moving,
                exiting: infoExiting,
                hover: isExiting ? 0 : (hoverFrac > 0 ? hoverFrac : (hovered ? 1 : 0)),
                press: pressed ? 1 : 0,
                scrolled: reportedScroll == carried ? lastCarriedPair : [reportedScroll.x, reportedScroll.y],
                carriedScrolled: lastCarriedPair,
                caret: nil,
                secure: secure,
                disabled: el.a11yDisabled,
                checked: el.a11yChecked,
                a11yValue: el.a11yValue,
                a11yDescription: el.a11yDescription,
                a11yHidden: el.isA11yHidden,
                stuck: abs(stickyShift.y) >= abs(stickyShift.x) ? stickyShift.y : stickyShift.x,
                traceName: el.traceNameValue,
                virtualExtent: pose?.virtualExtent ?? false,
                loopPhase: pose?.loopPhase,
                revealing: pose?.revealing ?? false,
                liveIntent: pose?.ownLiveIntent ?? 0
            ))
            if edit != nil || el.a11yRange != nil { newElements[myElementIndex].a11yInput = ElementA11yInput(el, edit: edit) }

            if el.textHighlights != nil {
                let marks = highlightElementInfos(node: node, owner: newElements[myElementIndex], ownerIndex: myElementIndex,
                                                 rect: effRect, scaleVec: sc, visibleRect: visibleClipPt)
                newElements.append(contentsOf: marks)
                if publishHitGeometry && !marks.isEmpty {
                    hitScopes.append(contentsOf: repeatElement(hitScopes[myElementIndex], count: marks.count))
                }
            }

            let effectSpec = el.runtimeExtras[RenderExtrasKey.effectSpec] as? RenderEffectSpec
            if publishHitGeometry, let presented {
                let scope = hitScopes[myElementIndex]
                let flight = (hasPresenceFlights && (activeFlightIds.contains(nid) || launchedFlightIds.contains(nid)
                    || unclippedMatchedFlightIds.contains(nid))) || (el.flightId != nil && scene.isEdgeAnimating(nid))
                let margin = 2 / scale + 3 * scope.blur + (effectSpec?.bleed ?? 0) * max(sc.x, sc.y)
                let sticky = (el.anchor != nil && !node.isSticky) ? Vec2.zero
                    : Vec2(stickyShift.x - parentShift.x, stickyShift.y - parentShift.y)
                kitHooks.unseenPresence.recordNativeFrameNode(
                    presented, rect: effRect, drawn: infoRect, scale: sc, turn: scope.turn,
                    localClip: scope.localClip, screenClip: presenceScreenClip, margin: margin,
                    bypassClip: el.isolatedLayer || flight, opacity: infoOpacity, sticky: sticky
                )
            }

            let isDissolveScope = dissolveParentIds.contains(nid)
            // A retained table cell can be mounted far beyond its scroll viewport. Keep its
            // geometry and inspection records, but do not resolve glyphs or emit draws below a
            // clip which cannot cover a framebuffer pixel. Layers may render beyond the window.
            let clip = parentClip.clipPx
            let clipMisses = clip.z < clip.x - 1 || clip.w < clip.y - 1
                || (parentClip.viewportApplies && (clip.z < -1 || clip.w < -1
                    || clip.x > Float(widthPx) + 1 || clip.y > Float(heightPx) + 1))
            let canCullToViewport = parentClip.viewportApplies && !parentInCache && !parentIsRotated
                && el.rotate == 0 && effBlur == 0 && !el.isolatedLayer && effectSpec == nil
            // Leaves with ordinary box ink or an icon can reject distant overscan before
            // snapping, resolving materials, or touching an atlas. Keep geometry above.
            var clippedBox = false
            if canCullToViewport, topology.children(of: node).isEmpty,
               effRect.bottom * scale < max(0, clip.y) - 2 || effRect.top * scale > min(Float(heightPx), clip.w) + 2 {
                let iconHeight = el.iconPayload.map { max(1, ($0.1 * scale).rounded()) } ?? 0
                let overhang = max(0, (iconHeight - effRect.height * scale) * 0.5)
                clippedBox = (effRect.bottom * scale < max(0, clip.y) - overhang - 2
                    || effRect.top * scale > min(Float(heightPx), clip.w) + overhang + 2)
                    && el.plainText == nil && el.richSpans == nil && el.advanceInRun == nil
                    && el.terminalGridPayload == nil && el.shapes.isEmpty && shadows.isEmpty
                    && (el.runtimeExtras.isEmpty || (el.runtimeExtras.count == 1 && el.elMark != nil))
                    && el.backdropBlur == 0 && el.elOutline == nil
                    && !focused && !el.focusable && el.focusWithinRing == nil && el.anchor == nil
            }
            let clippedSingleLine: Bool
            if !clipMisses, canCullToViewport, sc.y > 0,
               effRect.bottom * scale < max(0, clip.y) || effRect.top * scale > min(Float(heightPx), clip.w),
               el.plainText != nil || el.richSpans != nil,
               el.isTruncateFadeEnabled || (el.textStyle.wrap != .wrap && el.textStyle.maxLines == 0),
               el.liveText == nil, el.advanceInRun == nil, el.pillChips.isEmpty,
               el.iconPayload == nil, el.imagePayload == nil, el.terminalGridPayload == nil, el.shapes.isEmpty, shadows.isEmpty,
               el.backdropBlur == 0, el.focusRingColor == nil, el.focusWithinRing == nil, el.elOutline == nil,
               !focused, !el.focusable, el.textHighlights == nil, el.spanRingsSpec.isEmpty, el.elStrikes.isEmpty,
               el.runtimeExtras.isEmpty || (el.runtimeExtras.count == 1 && el.elMark != nil) {
                // A no-wrap label may still contain hard breaks. Keep the shaper's overhang
                // allowance and account for the text offset from vertical padding.
                let yScale = max(abs(sc.y) * scale, 0.0625)
                let spans = el.richSpans
                let band = TextRasterWindow(lowerY: max(0, clip.y) / yScale,
                                            upperY: min(Float(heightPx), clip.w) / yScale)
                    .expanded(for: el.textStyle, spans: spans, scale: yScale)
                let padding = el.layout.padding.top * yScale
                let outside = effRect.bottom * scale + max(0, padding) < band.lowerY * yScale
                    || effRect.top * scale + min(0, padding) > band.upperY * yScale
                // A larger span can move the baseline by the font's line-height multiplier.
                // Use the measured line boxes for those labels.
                clippedSingleLine = outside && el.plainText?.contains(where: \.isNewline) != true
                    && spans?.contains(where: { $0.pad > 0 || ($0.size ?? 0) > el.textStyle.size || $0.text.contains(where: \.isNewline) }) != true
            } else {
                clippedSingleLine = false
            }
            if clipMisses || clippedSingleLine || clippedBox, topology.children(of: node).isEmpty, !parentInCache, !parentIsRotated,
               el.surfacePayload == nil, el.pixelsPayload == nil, el.role != .textInput,
               editLens == nil, !hasActiveTextLinks(el), !el.isSecure,
               el.runtimeExtras[RenderExtrasKey.cacheEnabled] == nil, activeTextFlights.isEmpty {
                return (false, subtreeDynamic, effOpacity, effBlur, .zero, .zero, effInert, parentClip, nextChildTransform, isDissolveScope, false, [], false, myElementIndex, 0, 0, 0, 0, nodeScaleMotion, NO_CLIP, .zero, sc.x * scale, 0, nil)
            }
            if effOpacity <= 0.001 && (!isExiting || parentOpacity == 0) {
                if publishHitGeometry && !topology.children(of: node).isEmpty {
                    let clip = el.runtimeExtras[RenderExtrasKey.clipSpec] as? RenderClipSpec
                    if el.layout.clipOverflow || el.clipRadius != nil || el.clipCorners != nil
                        || el.clipFade != nil || clip != nil {
                        parentClip.rectPt = visibleClipPt
                        hitScopes[myElementIndex].localClip = hitScopes[myElementIndex].localClip.map {
                            intersectRects($0, effRect)
                        } ?? effRect
                    }
                }
                return (false, subtreeDynamic, effOpacity, effBlur, .zero, .zero, effInert, parentClip, nextChildTransform, isDissolveScope, false, [], false, myElementIndex, 0, 0, 0, 0, nodeScaleMotion, NO_CLIP, .zero, sc.x * scale, 0, nil)
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
            childSnap.parent = childSnap.rigid == inheritedSnap.rigid && PixelSnap.frames(el, effectiveFill: effBg, effectiveBorder: presentedBorder)
                ? snapParent : nil
            childSnapByNode[nid] = childSnap
            let rectPx = SIMD4<Float>(paintedEdges.x, paintedEdges.y, max(0, paintedEdges.z - paintedEdges.x), max(0, paintedEdges.w - paintedEdges.y))
            let clipSpec = el.runtimeExtras[RenderExtrasKey.clipSpec] as? RenderClipSpec
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
            let hasChildren = hasRaised ? topology.children(of: node).contains { !renderNode($0).el.isRaised } : !topology.children(of: node).isEmpty
            let hasOverlappingShape = el.shapes.count > 1 || (el.shapes.first?.ops.count ?? 0) > 1
            let opacityNeedsLayer = effOpacity > 0.001 && ownOpacity > 0.001 && ownOpacity < 1.0 && (hasChildren || hasOverlappingShape || (el.iconPayload != nil && effBg.a > 0.001))
            let cacheRequested = (el.runtimeExtras[RenderExtrasKey.cacheEnabled] as? Bool) ?? false
            var cacheEligible = cacheRequested
                && !hasCutout
                && el.backdropBlur <= 0
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
            // Keep the last reusable entry while the projected raster is too large to open.
            if cacheEligible {
                var width = rectPx.z
                var height = rectPx.w
                if let entry = elSliceRenderState.nodeCaches[nid] {
                    let ratio = effScale / max(1e-4, entry.rasterScale)
                    width = (entry.relBounds.z - entry.relBounds.x) * ratio
                    height = (entry.relBounds.w - entry.relBounds.y) * ratio
                }
                cacheEligible = effScale.isFinite && width > 0 && height > 0
                    && ceilf(width) <= 4096 && ceilf(height) <= 4096
            }
            if cacheEligible, var entry = elSliceRenderState.nodeCaches[nid] {
                let sameCommit = (commitGen == entry.commitGen)
                let envSame = abs(scale - entry.envScale) <= 1e-4 && !lastWasSettled
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
                // A plain shape has no mutable atlas input or descendant paint to re-hash.
                // Text, images and nested content continue through content-signature validation.
                let plainLeaf = !hasChildren && el.role == .group && el.plainText == nil && el.richSpans == nil
                    && el.iconPayload == nil && el.imagePayload == nil && el.terminalGridPayload == nil
                    && editLens == nil && el.runtimeExtras.count == 1
                let sameRaster = sameCommit && !scaleDiff && isResident && !entry.isLivePhase && plainLeaf
                if (sameRaster || scaleSettling) && entry.paintHash == nodePaintHash && !hasLiveTextInSubtree(node) {
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
            if el.backdropBlur > 0, backdropBlurCount < MAX_BACKDROP_BLURS,
               visibleClipPt.width > 0, visibleClipPt.height > 0,
               effOpacity * el.elLayerOpacity * el.elPaintAlpha > 0.001 {
                backdropBlurCount += 1
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
                    fill: SIMD4<Float>(0, 0, 0, effOpacity * el.elLayerOpacity * el.elPaintAlpha),
                    border: .zero,
                    params: SIMD4<Float>(el.backdropBlur * sc.x * scale, KIND_BACKDROP_BLUR, 0, sc.x * scale),
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
                let effBorder = liveBorderColor ?? presentedBorder ?? (borderGradSpec?.top ?? el.borderColor)
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
                (edit?.multiline == false)
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
            nextChildClip.viewportApplies = parentClip.viewportApplies && !needsLayer

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

            let turnPivot = SIMD2(rectPx.x + rectPx.z * el.origin.x, rectPx.y + rectPx.w * el.origin.y)
            if hasRaised {
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
                    enclosingLayerOpacity: enclosingLayerOpacity,
                    nextInert: effInert,
                    nextChildTransform: nextChildTransform,
                    childIsRotated: parentIsRotated || abs(el.rotate) > 1e-4,
                    isDissolveScope: isDissolveScope,
                    scaleMotionRaw: nodeScaleMotion.rawValue,
                    rectPx: rectPx,
                    boundsClipPx: boundsClipPx,
                    ownClipRadiiPx: ownRound?.radii,
                    rotate: el.rotate,
                    turnPivot: turnPivot,
                    outerTurnClip: parentClip.clipPx
                )
            }

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
                        pivot: turnPivot
                    )
                }
                instances.append(scopeInst)
                marks.append(0)
            }

            // 2. System material slot registration (ahead of outer shadows so `nativeMaterialHole` clears shadow interior)
            var nativeMaterialHole: Float? = nil
            var paintBg: Color = effBg
            let shapeRadiiPx = radiiPx
            if let mat = el.runtimeExtras["systemMaterial"] as? SystemMaterial {
                let blending = (el.runtimeExtras["systemMaterialBlending"] as? MaterialBlendingMode) ?? .behindWindow
                let isContinuous = isContinuousCorners || radiiPt.x < 0 || radiiPt.y < 0 || radiiPt.z < 0 || radiiPt.w < 0
                let rPx = MaterialMath.clampRadius(
                    [radiiPx.x, radiiPx.y, radiiPx.z, radiiPx.w],
                    width: rectPx.z,
                    height: rectPx.w
                )
                // Native views sit outside GPU layers, so apply the opacity the GPU would composite.
                let materialOpacity = enclosingLayerOpacity * paintEffOpacity * el.elPaintAlpha
                if materials.count < MAX_NATIVE_MATERIALS, visibleClipPt.width > 0, visibleClipPt.height > 0,
                   materialOpacity > 0.001 {
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
                        opacity: materialOpacity
                    )
                    materials.append(matDraw)
                    if useNativeMaterials {
                        nativeMaterialHole = isContinuous ? -rPx : rPx
                        paintBg = .transparent
                    }
                }
                if nativeMaterialHole == nil && effBg.a <= 0 {
                    let tint = MaterialMath.fallbackFill(material: mat, dark: systemDark)
                    paintBg = Color(r: tint.x, g: tint.y, b: tint.z, a: tint.w)
                }
            }

            // 3. Outer drop shadows (`runtime/paint/shadow.rs`)
            let flatFocusWithinShadows = el.focusWithinFlat && !effInert && !isExiting && isFocusWithin(node.path)
            let castsShadow = !flatFocusWithinShadows && !shadows.isEmpty && blurHole == nil && el.attachedSystemMaterial == nil
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
            // The fragment shader supplies the half-pixel antialiasing floor. Encoding
            // that floor here enlarges the vertex quad and invalidates neighboring tiles.
            let softEdge = max(0, (clipSpec?.soft ?? 0) * scale)
            // A container's children may legitimately extend outside its own box. Cull
            // only its fill here and retain all child transforms, layers, hit and clip state.
            let hasSolidBg = paintBg.a > 0.001 && (!canCullToViewport || needsLayer
                || !outerLayerStarts.isEmpty || cacheEligible
                || (boundsClipPx.w >= max(0, activeClip.y) - 2 - 3 * softEdge
                    && boundsClipPx.y <= min(Float(heightPx), activeClip.w) + 2 + 3 * softEdge
                    && boundsClipPx.z >= max(0, activeClip.x) - 2 - 3 * softEdge
                    && boundsClipPx.x <= min(Float(widthPx), activeClip.z) + 2 + 3 * softEdge))
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

            let effBorderColor = liveBorderColor ?? presentedBorder ?? (borderGradSpec?.top ?? el.borderColor)
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
                var rectInst = RenderInstance(
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
                    if loopVisible, let spec = el.loopingSpec, case let .opacityCycle(curve) = spec.kind,
                       spec.mode == .wrap, loopRuntime.tracks[nid]?.isActive(at: scene.store.nodeTime(nid)) == true,
                       publishHitGeometry, instances.count == layerStartIdx,
                       !parentInCache, !parentIsRotated, !needsLayer, !hasChildren,
                       parentOpacity == 1, parentElementIndex.map({ hitScopes[$0].opacity == 1 && hitScopes[$0].turn == nil }) ?? true,
                       effOpacity == loop?.opacity, localOpacity == effOpacity, bwPx == 0, sidesVec == .zero,
                       el.isPlainCycleDecoration, let dt = curve.frameInterval(), dt.isFinite,
                       curve.stops.allSatisfy({ $0.fraction.isFinite && $0.opacity.isFinite &&
                           $0.opacity > 0.001 && $0.opacity <= 1 && paintBg.a * $0.opacity > 0.0005 }) {
                        var ink = paintBg.simd4(srgb: srgbBlend)
                        if srgbBlend {
                            if paintBg.r == 1 { ink.x = 1 }
                            if paintBg.g == 1 { ink.y = 1 }
                            if paintBg.b == 1 { ink.z = 1 }
                        }
                        rectInst.fill = SIMD4(ink.x * fill.w, ink.y * fill.w, ink.z * fill.w, fill.w)
                        rectInst.params.w = localOpacity
                        cyclePaint.record(node: nid, element: myElementIndex, path: node.path, index: instances.count,
                                          rect: rectPx, ink: ink, curve: curve, interval: dt)
                    }
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
                let region = imagePacker.insert(img)
                let imageEdges = region.edges
                let idx = instances.count
                instances.append(RenderInstance(
                    rect: rectPx,
                    radii: radiiPx,
                    fill: SIMD4<Float>(localOpacity, localOpacity, localOpacity, localOpacity),
                    border: .zero,
                    params: SIMD4<Float>(Float(region.page), KIND_IMAGE, 0, 1.0),
                    uv: imageEdges,
                    clip: activeClip,
                    fade: activeFade
                ))
                marks.append(0)
                imageFixups.append((idx, imageEdges, Float(img.width), Float(img.height)))
            } else if let px = el.pixelsPayload {
                let visible = paintEffOpacity * el.elPaintAlpha > 0.001 && visibleClipPt.width > 0 && visibleClipPt.height > 0
                if let (region, sz) = placedPixels(px, at: now, visible: visible, box: rectPx,
                                                       fit: el.pixelsFitMode, place: el.surfacePlace) {
                    let imageEdges = region.edges
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
                        params: SIMD4<Float>(Float(region.page), KIND_IMAGE, 0, 1.0),
                        uv: drawUV,
                        clip: activeClip,
                        fade: activeFade
                    ))
                    marks.append(0)
                    imageFixups.append((idx, drawUV, Float(sz.width), Float(sz.height)))
                }
            }

            // 9. Vector shapes (`Shape` with `trimmed`/`drawn`, `strokeWidth`, `LineCap`)
            @inline(never)
            func paintShape(_ shape: Shape, drawFrac: Float) {
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

            if !el.shapes.isEmpty {
                let drawFrac = (presentedById[nid]?.draw ?? 1.0).clamped(to: 0...1)
                for shape in el.shapes { paintShape(shape, drawFrac: drawFrac) }
            }

            // 10. Icon (`SVGIcon`)
            if let (svg, iconSizePt) = el.iconPayload {
                let iconPx = max(1, Int((iconSizePt * scale).rounded()))
                let iconColor = applyPressColor(pressTint.color, to: liveTextColor ?? scene.store.get(nid, Props.TEXT_COLOR).map(Color.init) ?? el.textColor ?? defaultForeground, frac: pressTint.frac)
                if let colorDecoded = textSystem.colorIcons.rasterize(
                    svg,
                    pixelSize: iconPx,
                    currentColor: iconColor,
                    oneColor: el.isIconOneColor ? iconColor : nil,
                    mirrored: node.mirroredInRtl
                ), let baseMip = colorDecoded.mips.first {
                    let atlas = RGBA8Atlas(width: Int(baseMip.width), height: Int(baseMip.height), texels: [UInt8](baseMip.rgba))
                    let region = imagePacker.insert(atlas)
                    let imageEdges = region.edges
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
                        params: SIMD4<Float>(Float(region.page), KIND_IMAGE, 0, 1.0),
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
                    appendIcon(placed, rect: SIMD4(ix, iy, pw, ph), ink: col, clip: activeClip, fade: activeFade,
                               rotated: parentIsRotated || abs(el.rotate) > 1e-4)
                }
            }

            if let grid = el.terminalGridPayload {
                let ink = liveTextColor ?? scene.store.get(nid, Props.TEXT_COLOR).map(Color.init) ?? el.textColor ?? defaultForeground
                let padding = SIMD4<Float>(el.layout.padding.left * sc.x * scale, el.layout.padding.top * sc.y * scale, 0, 0)
                paintTerminalGridInstances(grid, snappedRect: paintedEdges + padding, exactRect: exactEdgesPx + padding,
                                           clip: activeClip, fade: activeFade,
                                           opacity: localOpacity, defaultColor: ink,
                                           into: &instances, marks: &marks, glyphFixups: &glyphFixups, imageFixups: &imageFixups,
                                           lcdAvailable: supportsLCDMasks, usedLCD: &usedLCD)
            }

            // 11. Text (`editLens` textInput / `plainText` / `richSpans` / `advanceIn`)
            let isTextFlightTarget = activeTextFlights.contains { $0.targetNodeId == nid }
            func rasterWindow(clip: SIMD4<Float>, originY: Float) -> TextRasterWindow? {
                let margin = effBlur * scale * 3 + (effectSpec?.bleed ?? 0) * max(sc.x, sc.y) * scale + 2
                return TextRasterWindow.paint(top: clip.y, bottom: clip.w, viewport: viewport.y * scale,
                                              origin: originY, scale: sc.y * scale, margin: margin,
                                              transformed: parentIsRotated || abs(el.rotate) > 1e-4 ||
                                                parentInCache || cacheEligible || isTextFlightTarget)
            }
            @inline(never)
            func paintField(_ value: TextEdit) {
                var edit = value
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
                let defaultTextColor = liveTextColor ?? el.textColor ?? defaultForeground
                let textCol = resolvedInput.showingPlaceholder
                    ? (el.placeholderColor ?? defaultForeground.alpha(0.4))
                    : defaultTextColor
                let inputClipEdges = intersectClipRects(activeClip, boundsClipPx)
                let inputWindow = rasterWindow(clip: inputClipEdges, originY: textTop * scale)
                let layout = textSystem.layoutInput(
                    text: resolvedInput.renderedString, spans: resolvedInput.spans, pills: resolvedInput.pills,
                    style: resolvedInput.style, maxWidth: resolvedInput.maxWidthForShape,
                    pixelScale: rasterScale * scale, emitGlyphs: !resolvedInput.renderedString.isEmpty,
                    keep: resolvedInput.isSecure ? .secret : .cached,
                    request: Self.paragraphRequest(field: nid, el: el, edit: edit, resolved: resolvedInput),
                    rasterWindow: inputWindow
                )
                let inputBox = prepareVisibleParagraphs(in: layout, field: nid, window: inputWindow)
                let (outlineMode, lcdMask) = directOutlineMode(el.textStyle.fontSmoothing, node: nid, moving: nodeScaleMotion != .still)
                let shaped = inputBox.shaped
                let scrollX = computeSingleLineScroll(
                    path: node.path, edit: edit, shaped: shaped, isFocused: focused,
                    showingPlaceholder: resolvedInput.showingPlaceholder, innerWidthPt: innerW, pixelScale: inputBox.pixelScale
                )
                let textLeft = effRect.x + (el.layout.padding.left - scrollX) * sc.x
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
                        glyph: { rect, glyph, color in
                            let ink = premulSIMD4(color, opacity: localOpacity, srgb: srgbBlend)
                            appendTextGlyph(glyph, rect: rect, ink: ink, clip: inputClipEdges, fade: activeFade, forceScaled: forceScaled, outlineMode: outlineMode, lcdMask: lcdMask)
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
                    rotated: parentIsRotated || abs(el.rotate) > 1e-4
                )
                if focused && edit.hasSelection && edit.preedit == nil && !resolvedInput.showingPlaceholder {
                    let displayRange = resolvedInput.selectionRange(for: edit)
                    let color = el.fieldSelectionColor(foreground: defaultForeground, active: windowFocused)
                    let fill = premulSIMD4(color, opacity: localOpacity, srgb: srgbBlend)
                    for box in textSystem.selectionRects(in: shaped, utf8Range: displayRange, pixelScale: inputBox.pixelScale) {
                        let rect = TextBoxGeometry.pixelRect(origin: SIMD2(textLeft, textTop),
                            box: SIMD4(box.x, box.y, max(2, box.z), box.w), k: SIMD2(sc.x, sc.y), pxScale: scale)
                        instances.append(RenderInstance(rect: rect, radii: SIMD4(repeating: 2 * scale),
                            fill: fill, border: .zero, params: SIMD4(0, KIND_RECT, 0, 1),
                            uv: .zero, clip: inputClipEdges, fade: activeFade))
                        marks.append(0)
                    }
                }
                let departing = (el.spellcheck || resolvedInput.showingPlaceholder) && activeTextFlights.contains {
                    FlightSelector.selects($0.state.sourceKey, path: node.path, key: node.key)
                        && $0.state.alphas(target: $0.state.destination, now: now, reducedMotion: reducedMotion).source > 0
                }
                if el.spellcheck && !resolvedInput.isSecure && !isExiting && !departing {
                    let color = premulSIMD4(FieldSpelling.color, opacity: localOpacity, srgb: srgbBlend)
                    fieldSpelling.paint(edit: edit, focusedPath: focused ? node.path : nil,
                        now: currentTime, box: inputBox, system: textSystem,
                        origin: Vec2(textLeft, textTop), scale: sc, pixels: scale,
                        clip: inputClipEdges, rotated: parentIsRotated || abs(el.rotate) > 1e-4) { marker, radius in
                            instances.append(RenderInstance(rect: marker, radii: SIMD4(repeating: radius), fill: color,
                                border: .zero, params: SIMD4(0, KIND_RECT, 0, 1), uv: .zero, clip: inputClipEdges, fade: activeFade))
                            marks.append(0)
                        }
                } else if focused {
                    fieldSpelling.watch = nil
                }
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
                if isTextFlightTarget || (resolvedInput.showingPlaceholder && departing) {
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
                    if let window = inputWindow,
                       gq.rect.y + gq.rect.w < window.lowerY || gq.rect.y > window.upperY { continue }
                    let gx = (textLeft + gq.rect.x * sc.x) * scale
                    let gy = (textTop + gq.rect.y * sc.y) * scale
                    let gw = max(1.0, gq.rect.z * sc.x * scale)
                    let gh = max(1.0, gq.rect.w * sc.y * scale)
                    if !parentIsRotated, abs(el.rotate) <= 1e-4, gx + gw < inputClipEdges.x || gx > inputClipEdges.z { continue }
                    let ink = fieldMarks.last { $0.fg != nil && $0.byteRange.contains(gq.utf8Offset) }?.fg ?? gq.color ?? textCol
                    let gcol = premulSIMD4(ink, opacity: localOpacity, srgb: srgbBlend)
                    appendTextGlyph(gq, rect: SIMD4(gx, gy, gw, gh), ink: gcol,
                                    clip: inputClipEdges, fade: activeFade, forceScaled: forceScaled, outlineMode: outlineMode, lcdMask: lcdMask)
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
                        let color = el.caretColor ?? defaultForeground
                        instances.append(RenderInstance(
                            rect: SIMD4(x * scale, y * scale, max(2, width * scale), height * scale),
                            radii: SIMD4(repeating: scale), fill: premulSIMD4(color, opacity: localOpacity, srgb: srgbBlend),
                            border: .zero, params: SIMD4(0, KIND_RECT, 0, 1), uv: .zero, clip: inputClipEdges, fade: activeFade
                        ))
                        marks.append(0)
                    }
                }
            }
            @inline(never)
            func paintLabel() {
                let resolvedText = ElDisplayResolver.resolveText(
                    el: el,
                    rawText: el.plainText,
                    isSecure: el.isSecure
                )
                let (outlineMode, lcdMask) = directOutlineMode(resolvedText.style.fontSmoothing, node: nid, moving: nodeScaleMotion != .still)
                let raster = isTextFlightTarget ? nil : labelRasters.raster(scale: rasterScale, still: nodeScaleMotion == .still)
                let shapeScale = raster == nil ? rasterScale * scale : scale
                let restsExact = TextBoxGeometry.restsExact(
                    isInput: false, scaleStill: nodeScaleMotion == .still && abs(rasterScale - 1) < 1e-5,
                    scale: SIMD2<Float>(sc.x, sc.y)
                )
                let exactOffset = restsExact ? TextBoxGeometry.leafExactOff(
                    rest: snapParent, rigid: inheritedSnap.steady * scale, containPx: inheritedSnap.contain * scale, shifted: childSnap.shifted
                ) : .zero
                let boxLeft = (paintedEdges.x + exactOffset.x) / scale + el.layout.padding.left * sc.x
                let textTop = (paintedEdges.y + exactOffset.y) / scale + el.layout.padding.top * sc.y
                let drawnInnerW = max(0, rectPx.z / scale - (el.layout.padding.left + el.layout.padding.right) * sc.x)
                let drawnInnerH = max(0, rectPx.w / scale - (el.layout.padding.top + el.layout.padding.bottom) * sc.y)
                let layoutInnerW = max(0, node.targetRect.width - el.layout.padding.left - el.layout.padding.right)
                let glidingText = boxGliding && unscaled && nodeScaleMotion == .still
                let glide = glidingText ? Vec2(PixelSnap.textGlide(paintedEdges.x), PixelSnap.textGlide(paintedEdges.y)) : .zero
                let glideOffset = glidingText ? SIMD2<Float>(paintedEdges.x - paintedEdges.x.rounded(), paintedEdges.y - paintedEdges.y.rounded()) : .zero
                let restY = textTop * scale - glideOffset.y
                let defaultTextColor = applyPressColor(pressTint.color, to: liveTextColor ?? scene.store.get(nid, Props.TEXT_COLOR).map(Color.init) ?? el.textColor ?? defaultForeground, frac: pressTint.frac)
                let inkMode = resolvedText.style.fontSmoothing == .systemDefault ? textSystem.smoothing : resolvedText.style.fontSmoothing
                var shaped = GlyphAtlas.withBaseInk(defaultTextColor, mode: inkMode) {
                    resolvedText.shape(
                        using: textSystem,
                        maxWidth: TextBoxGeometry.wrapWidth(layoutInnerW, scale: shapeScale),
                        pixelScale: shapeScale,
                        emitGlyphs: true,
                        glidePx: glide,
                        rasterWindow: rasterWindow(clip: activeClip, originY: restY)
                    )
                }
                let textLeft = boxLeft + TextBoxGeometry.inlineOffset(align: el.textStyle.align,
                    wrap: resolvedText.truncateFade ? .noWrap : resolvedText.style.wrap, shaped: shaped,
                    innerWidth: drawnInnerW, textScale: sc.x, pixelScale: scale)
                let restOrigin = SIMD2<Float>(textLeft * scale - glideOffset.x, restY)
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
                        textOriginX: boxLeft,
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
                let isRotatedScope = parentIsRotated || abs(el.rotate) > 1e-4
                let inCacheScope = parentInCache || cacheEligible
                let shownMargin = effBlur * scale * 3.0 + (effectSpec.map { $0.bleed * max(sc.x, sc.y) * scale } ?? 0) + 2.0
                let shownY0 = (!isRotatedScope && !inCacheScope) ? max(activeClip.y, -shownMargin) : activeClip.y
                let shownY1 = (!isRotatedScope && !inCacheScope) ? min(activeClip.w, viewport.y * scale + shownMargin) : activeClip.w
                let baseLinePt = resolvedText.style.lineHeight ?? resolvedText.style.size
                let spanMaxPt = resolvedText.spans?.compactMap(\.size).max() ?? 0
                let emPt = max(max(resolvedText.style.size, baseLinePt), spanMaxPt)
                let bandPadPx = 2.0 * emPt * sc.y * scale + 2.0 / max(1e-4, shapeScale)
                let visibleMinY = shownY0 - bandPadPx
                let visibleMaxY = shownY1 + bandPadPx
                var selectionInk: SelectablePaintInk?
                if (!selectableRanges.isEmpty && selectableRanges[node.path] != nil) || (!markedPaths.isEmpty && markedPaths.contains(node.path)) {
                    func paintSelection(_ rect: SIMD4<Float>, _ straight: SIMD4<Float>, radius: Float, reach: Float?) {
                        let color = SIMD4(straight.x * straight.w, straight.y * straight.w,
                                          straight.z * straight.w, straight.w)
                        let radii = SIMD4<Float>(repeating: radius)
                        func makeRect(_ box: SIMD4<Float>) -> RenderInstance {
                            RenderInstance(rect: box, radii: radii, fill: color, params: SIMD4(0, KIND_RECT, 0, 1),
                                           clip: glyphClipEdges, fade: glyphFade)
                        }
                        if let reach {
                            let prior = instances.count
                            SelectionRunExtender.join(into: &instances, rect: rect, fill: color, radii: radii,
                                clip: glyphClipEdges, turn: isRotatedScope ? 1 : 0, reach: reach, makePrimitive: makeRect)
                            if instances.count != prior { marks.append(0) }
                        } else {
                            instances.append(makeRect(rect))
                            marks.append(0)
                        }
                    }
                    selectionInk = emitSelectableHighlightIfNeeded(
                        snap: node, el: el, isExiting: isExiting, activeSelectionRanges: selectableRanges,
                        textOriginX: textLeft, textOriginY: textTop, scaleVec: sc, pxScale: scale,
                        localAlpha: localOpacity, shaped: shaped,
                        emitMark: { paintSelection($0, $1, radius: 0, reach: nil) },
                        emitHighlight: { paintSelection($0, $1, radius: $2, reach: $3) }
                    )
                }
                let linkInks = recordAndEmitTextLinks(
                    snap: node, el: el, text: resolvedText.displayedText, authoredText: resolvedText.authoredText,
                    caseMap: resolvedText.caseMap, shaped: shaped, elided: shaped.elided,
                    textOriginX: textLeft, textOriginY: textTop, scaleVec: sc, pxScale: scale, shapeScale: shapeScale,
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
                    rotated: parentIsRotated || abs(el.rotate) > 1e-4,
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
                let labelGlyphs = isTextFlightTarget ? [] : shaped.glyphs
                let canRetain = !freshRaster && restsExact && !forceScaled && !isRotatedScope && !inCacheScope
                    && glide == .zero && raster == nil && outlineMode == nil && !lcdMask
                    && inkMode == textSystem.smoothing && motionRasterGlyphs == nil
                    && el.liveText == nil && pressTint.frac == 0 && selectionInk == nil
                    && el.advanceInRun == nil && !el.isSecure && el.textHighlights == nil
                    && wordFadeMask == nil && linkInks.isEmpty && !labelGlyphs.isEmpty
                    && shaped.lineGlyphRanges.count == 1
                let runInk = premulSIMD4(defaultTextColor, opacity: localOpacity, srgb: srgbBlend)
                let visible = SIMD4<Float>(glyphClipEdges.x, shownY0, glyphClipEdges.z, shownY1)
                let retained = canRetain ? labelDraws[nid] : nil
                let reused = retained?.replay(
                    shaped: shaped, at: restOrigin, clip: glyphClipEdges, fade: glyphFade, visible: visible,
                    ink: runInk, opacity: localOpacity, baseline: shaped.lineBaselinesPx.first, scale: scale, smoothing: inkMode, srgb: srgbBlend, atlas: textSystem.glyphAtlas,
                    into: &instances, marks: &marks, fixups: &glyphFixups
                ) == true
                if reused {
                    nextLabelDraws[nid] = retained
                } else {
                    let firstDraw = instances.count
                    let firstFixup = glyphFixups.count
                    var runBounds = SIMD4<Float>(.infinity, .infinity, -.infinity, -.infinity)
                    let baselines = restsExact ? TextBoxGeometry.roundedBaselines(originYPx: restOrigin.y, shaped: shaped) : []
                    let placements = TextBoxGeometry.GlyphPlacementBatch(shaped: shaped, atlas: textSystem.glyphAtlas,
                                                                         exact: !freshRaster && (restsExact || raster != nil))
                    defer { placements?.finish() }
                    var baselineLine = 0
                    for (index, glyph) in labelGlyphs.enumerated() {
                        let wordAlpha = wordFadeMask?.alpha(for: glyph) ?? 1.0
                        let gAlpha = localOpacity * wordAlpha
                        if gAlpha <= 0.0005 { continue }
                        let (gq, placement) = TextBoxGeometry.paintGlyph(
                            glyph, index: index, shaped: shaped, origin: restOrigin, scale: SIMD2<Float>(sc.x, sc.y), pixelScale: scale,
                            restsExact: restsExact, baselines: baselines, line: &baselineLine, atlas: textSystem.glyphAtlas,
                            raster: raster, placements: placements
                        )
                        if !isRotatedScope && (placement.y + placement.w < shownY0 || placement.y > shownY1 ||
                                               placement.x + placement.z < glyphClipEdges.x || placement.x > glyphClipEdges.z) { continue }
                        if canRetain {
                            runBounds.x = min(runBounds.x, placement.x)
                            runBounds.y = min(runBounds.y, placement.y)
                            runBounds.z = max(runBounds.z, placement.x + placement.z)
                            runBounds.w = max(runBounds.w, placement.y + placement.w)
                        }
                        let glyphBaseColor = selectionInk?.color(for: glyph) ?? linkInkColor(for: glyph, ranges: linkInks) ?? gq.color.map { applyPressColor(pressTint.color, to: $0, frac: pressTint.frac) } ?? defaultTextColor
                        let gcol = premulSIMD4(glyphBaseColor, opacity: gAlpha, srgb: srgbBlend)
                        var desktopOutline: TextOutlineGroup?
                        #if os(Linux) || os(Windows) || os(Android)
                        if outlineMode != nil, let native = shaped.desktopRestingText {
                            while baselineLine + 1 < shaped.lineGlyphRanges.count && index >= shaped.lineGlyphRanges[baselineLine].upperBound {
                                baselineLine += 1
                            }
                            desktopOutline = native.outlineGroup(for: gq, line: baselineLine, shaped: shaped, atlas: textSystem.glyphAtlas)
                        }
                        #endif
                        appendTextGlyph(gq, rect: placement, ink: gcol, clip: glyphClipEdges, fade: glyphFade,
                                        forceScaled: forceScaled, outlineMode: outlineMode, desktopOutline: desktopOutline, lcdMask: lcdMask)
                    }
                    if canRetain, instances.count - firstDraw == labelGlyphs.count,
                       glyphFixups.count - firstFixup == labelGlyphs.count,
                       labelGlyphs.allSatisfy({ !$0.hasLCDMask }),
                       instances[firstDraw...].allSatisfy({ $0.params.y == KIND_GLYPH }) {
                        var draws: [RetainedLabelDraws.Draw] = []
                        var pages: Set<UInt16> = []
                        draws.reserveCapacity(labelGlyphs.count)
                        for fixup in glyphFixups[firstFixup...] {
                            draws.append(.init(instance: instances[fixup.index], page: fixup.page))
                            pages.insert(fixup.page)
                        }
                        nextLabelDraws[nid] = RetainedLabelDraws(
                            source: .init(shaped), origin: restOrigin, bounds: runBounds, ink: runInk, opacity: localOpacity, baseline: shaped.lineBaselinesPx.first, scale: scale,
                            smoothing: inkMode, srgb: srgbBlend, pages: pages, resets: textSystem.glyphAtlas.resets, draws: draws
                        )
                    }
                }
            }
            func finishPaint() {
                let outline = el.elOutline
                let focusOverlay = outline != nil && !hasActiveTextLinks(el) ? resolvedFocusRingOverlay(
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
                if let ol = outline, focusOverlay == nil, localOpacity > 0.0005 {
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
            }

            if let editLens {
                let value = editLens.get(state)
                #if DEBUG
                pendingTextPaint = {
                    paintField(value)
                    finishPaint()
                }
                #else
                paintField(value)
                finishPaint()
                #endif
            } else if (el.plainText?.isEmpty == false) || (el.richSpans?.isEmpty == false) || el.advanceInRun != nil {
                #if DEBUG
                pendingTextPaint = {
                    paintLabel()
                    finishPaint()
                }
                #else
                paintLabel()
                finishPaint()
                #endif
            } else {
                finishPaint()
            }

            return (true, subtreeDynamic, paintEffOpacity, effBlur, rectPx, radiiPx, effInert, nextChildClip, nextChildTransform, isDissolveScope, needsLayer, outerLayerStarts, cacheEligible, myElementIndex, layerStartIdx, surfaceStartIdx, glyphFixupStartIdx, imageFixupStartIdx, nodeScaleMotion, activeClip, activeFade, effScale, nodePaintHash, elideCache)
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
                    params: SIMD4<Float>(overlay.widthPx, KIND_RECT, 0, 1.0),
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
                            glyphAtlas: textSystem.glyphAtlas,
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

        var branches: [PaintBranch] = []

        func finishNode(_ node: FlatNode, _ h: PaintHeader, dynamic subtreeDynamic: Bool) {
            guard h.continueSubtree && (canPaintFocusRing || h.needsLayer || !h.outerLayerStarts.isEmpty) else { return }
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
        }

        @discardableResult
        func paintSubtree(
            _ rootSlot: Int,
            parentClip: RenderClipState,
            inheritedInert: Bool,
            parentOpacity: Float,
            enclosingLayerOpacity: Float = 1,
            inheritedTransform: PresentedTransform = .identity,
            parentIsDissolve: Bool = false,
            parentScaleMotion: PaintScaleMotion = .still,
            parentElementIndex: Int? = nil,
            allowRaised: Bool = false,
            parentInCache: Bool = false,
            parentIsRotated: Bool = false
        ) -> Bool {
            var nextSlot: Int? = rootSlot
            var context = PaintContext(
                clip: parentClip, inert: inheritedInert, groupHover: 0, opacity: parentOpacity, enclosingOpacity: enclosingLayerOpacity,
                transform: inheritedTransform, dissolve: parentIsDissolve, scaleMotion: parentScaleMotion,
                element: parentElementIndex, allowRaised: allowRaised, inCache: parentInCache, rotated: parentIsRotated
            )
            var dynamic = false
            // Slots address both mounted and exiting nodes throughout this paint. Retain only
            // traversal state on the heap so deep trees also fit native UI thread stacks.
            while let slot = nextSlot {
                nextSlot = nil
                let node = renderNode(slot)
                if hasRaised && !context.allowRaised && node.el.isRaised {
                    collectedRaisedNodes.append((slot, newElements.count))
                    dynamic = true
                } else {
                    let savedMark = currentInheritedMark
                    currentInheritedMark = node.el.elMark ?? savedMark
                    var groupHover = context.groupHover
                    let presented = presentedById[node.nodeId]
                    let loop = loopSamples[node.nodeId]
                    let turn = (presented?.rotate ?? node.el.rotate) + (loop?.rotation ?? 0)
                    func header(_ el: El<State>) -> PaintHeader {
                        paintNodeHeader(
                            node, el: el, presented: presented, loop: loop,
                            parentClip: context.clip, inheritedInert: context.inert, groupHover: &groupHover, parentOpacity: context.opacity,
                            enclosingLayerOpacity: context.enclosingOpacity, inheritedTransform: context.transform,
                            parentIsDissolve: context.dissolve, parentScaleMotion: context.scaleMotion,
                            parentElementIndex: context.element, parentInCache: context.inCache, parentIsRotated: context.rotated
                        )
                    }
                    let h: PaintHeader
                    if turn == node.el.rotate && !slice2State.joinedRowsWithoutRevealMask.contains(node.nodeId) {
                        h = header(node.el)
                    } else {
                        var adjusted = presentedGrowthElement(node)
                        adjusted.rotate = turn
                        h = header(adjusted)
                    }
                    #if DEBUG
                    if let paint = pendingTextPaint {
                        pendingTextPaint = nil
                        paint()
                    }
                    #endif
                    let children = topology.children(of: node)
                    if (h.continueSubtree || publishHitGeometry), let first = children.first {
                        context = PaintContext(
                            clip: h.nextChildClip, inert: h.nextInert, groupHover: groupHover,
                            opacity: h.continueSubtree ? (h.needsLayer ? 1 : h.effOpacity).clamped(to: 0...1) : 0,
                            enclosingOpacity: h.needsLayer ? context.enclosingOpacity * h.effOpacity : context.enclosingOpacity,
                            transform: h.nextChildTransform, dissolve: h.isDissolveScope, scaleMotion: h.scaleMotion,
                            element: h.elementIndex, allowRaised: context.allowRaised || !h.continueSubtree,
                            inCache: context.inCache || h.cacheEligible, rotated: context.rotated || abs(turn) > 1e-4
                        )
                        branches.append(PaintBranch(slot: slot, header: h, context: context, children: children,
                                                    nextChild: children.startIndex + 1, savedMark: savedMark, dynamic: h.subtreeDynamic))
                        nextSlot = first
                        continue
                    }
                    dynamic = h.subtreeDynamic
                    finishNode(node, h, dynamic: dynamic)
                    currentInheritedMark = savedMark
                }

                while !branches.isEmpty {
                    let i = branches.count - 1
                    if dynamic { branches[i].dynamic = true }
                    let index = branches[i].nextChild
                    if index < branches[i].children.endIndex {
                        let child = branches[i].children[index]
                        branches[i].nextChild = index + 1
                        nextSlot = child
                        context = branches[i].context
                        break
                    }
                    let parent = branches.removeLast()
                    dynamic = parent.dynamic
                    finishNode(renderNode(parent.slot), parent.header, dynamic: dynamic)
                    currentInheritedMark = parent.savedMark
                }
            }
            return dynamic
        }

        clearPressRestingHits()
        for root in topology.roots {
            paintSubtree(root, parentClip: rootClip, inheritedInert: false, parentOpacity: 1.0, allowRaised: false)
        }
        for (slot, offset) in collectedRaisedNodes {
            let raisedNode = renderNode(slot)
            let start = newElements.count
            var chain: [NodeId] = []
            var cursor = presentedById[raisedNode.nodeId]?.parent
            while let pIdx = cursor {
                chain.append(pIdx)
                cursor = presentedById[pIdx]?.parent
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
                        pivot: st.turnPivot
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
            if let parentId = presentedById[raisedNode.nodeId]?.parent, let pst = savedNodeStates[parentId] {
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
                    slot,
                    parentClip: raisedParentClip,
                    inheritedInert: pst.nextInert,
                    parentOpacity: pst.effOpacity,
                    enclosingLayerOpacity: pst.enclosingLayerOpacity,
                    inheritedTransform: pst.nextChildTransform,
                    parentIsDissolve: pst.isDissolveScope,
                    parentScaleMotion: PaintScaleMotion(rawValue: pst.scaleMotionRaw) ?? .still,
                    parentElementIndex: pst.elementIndex,
                    allowRaised: true,
                    // The raised branch paints outside ancestor caches, inside the reopened turns.
                    parentInCache: false,
                    parentIsRotated: pst.childIsRotated
                )
            } else {
                paintSubtree(slot, parentClip: rootClip, inheritedInert: false, parentOpacity: 1.0, allowRaised: true)
            }
            if publishHitGeometry { raisedRanges.append((offset, start..<newElements.count)) }
            for (sIdx, sfIdx) in reopenedLayers.reversed() {
                closeLayer(start: sIdx, surfaceStart: sfIdx)
            }
        }

        // Reuse all presented boxes when rotation leaves the bounds numerically unchanged.
        // Exits can have the same path as their replacement, so retain only the live boxes there.
        var newDrawnRectByPath = exitingIds.isEmpty ? newPresentedRects : drawnOverrides
        if exitingIds.isEmpty {
            for (path, drawn) in drawnOverrides { newDrawnRectByPath[path] = drawn }
        }
        measureTextFlightDestinations(in: newDrawnRectByPath, at: now)

        forEachTextFlightGlyph(at: now) { glyph, rect, ink, clip in
            let clipEdges = SIMD4(clip.x, clip.y, clip.x + clip.z, clip.y + clip.w)
            appendTextGlyph(glyph, rect: rect, ink: SIMD4(ink.x * ink.w, ink.y * ink.w, ink.z * ink.w, ink.w),
                            clip: clipEdges, fade: .zero, forceScaled: true,
                            outlineMode: supportedOutlineMode(glyph.outlineGroup?.smoothing ?? .systemDefault, moving: true))
        }

        // Glyph placement uses normalized page-local edges; GPU instances address that page in texels.
        let glyphAtlas = textSystem.glyphAtlas.framePages()
        if motionRasterGlyphs != nil { motionRasterGlyphs = MotionGateRasterGlyphs() }
        for fix in glyphFixups where fix.index < instances.count {
            let page = min(Int(fix.page), glyphAtlas.bases.count - 1)
            let glyphW = Float(glyphAtlas.bases[page].width), glyphH = Float(glyphAtlas.bases[page].height)
            instances[fix.index].params.z = Float(page)
            let u0 = fix.normUV.x * glyphW, v0 = fix.normUV.y * glyphH
            let uw = max(1.0, (fix.normUV.z - fix.normUV.x) * glyphW)
            let vh = max(1.0, (fix.normUV.w - fix.normUV.y) * glyphH)
            let texelsPerPixel: Float = instances[fix.index].radii.x == 1 ? 3 : 1
            let scaled = fix.forceScaled || abs(uw / texelsPerPixel - fix.texW) > 0.5 || abs(vh - fix.texH) > 0.5
            instances[fix.index].uv = SIMD4<Float>(u0, v0, scaled ? uw : 0, scaled ? vh : 0)
            if !motionGlyphMasks.isEmpty, let shift = motionGlyphMasks[SIMD3(fix.normUV.x, fix.normUV.y, Float(fix.page))] {
                let key = MotionGateGrid.ApronKey(instances[fix.index])
                if shift > 0 { motionRasterGlyphs?.shifts[key] = shift }
                else { motionRasterGlyphs?.iconAprons.insert(key) }
            }
        }

        for fix in imageFixups where fix.index < instances.count {
            let edges = fix.texelEdges
            instances[fix.index].uv = SIMD4(edges.x, edges.y, edges.z - edges.x, edges.w - edges.y)
        }

        if publishHitGeometry {
            self.seenMatchedByFlightId = newSeenMatched
            self.hitGeometryByPath = newHitGeometries
            self.paintOrderPaths = newElements.map(\.path)
            if let firstRaised = raisedRanges.first {
                // Paint lifted subtrees last, then return them to their tree positions for inspection.
                var order: [Int] = []
                order.reserveCapacity(newElements.count)
                var cursor = 0
                for (offset, indices) in raisedRanges {
                    order.append(contentsOf: cursor..<offset)
                    order.append(contentsOf: indices)
                    cursor = offset
                }
                order.append(contentsOf: cursor..<firstRaised.indices.lowerBound)
                var treeIndex = [Int](repeating: 0, count: order.count)
                for (index, source) in order.enumerated() { treeIndex[source] = index }
                cyclePaint.restoreTreeOrder(treeIndex)
                newElements = order.map { source in
                    var info = newElements[source]
                    info.parentIndex = info.parentIndex.map { treeIndex[$0] }
                    return info
                }
            }
            nativeInspection = NativeFrameInspection(
                rawPoseByPath: rawPoseByPath, landingHolds: frameLandingHoldIds,
                elementCount: newElements.count, hasInheritedFlags: hasInheritedFlags, a11yMaterialized: false
            )
        }
        linkBoxesByPath = newLinkBoxes
        appendLinkElements(to: &newElements)
        if publishHitGeometry { lastElements = newElements }
        self.presentedRectByPath = newPresentedRects
        self.presentedScaleByPath = newPresentedScales
        self.presentedScaleMotionById = newPresentedScaleMotionById
        self.drawnRectByPath = newDrawnRectByPath
        self.rectSpringingById = newRectSpringingById
        self.surfaces = newSurfaces
        finishSurfaceVideoPaint(surfaceVideo)
        if publishHitGeometry {
            publishHoverOrder()
            refreshHoverAfterPaint()
        }
        if activePaintedLoopsAnimating {
            isAnimating = true
            animSources |= AnimSource.loop
        }

        let clear = clearColor.simd4(srgb: srgbBlend)
        var output = RenderFrame(
            width: widthPx,
            height: heightPx,
            srgbBlend: srgbBlend,
            clearColor: SIMD4<Float>(clear.x * clear.w, clear.y * clear.w, clear.z * clear.w, clear.w),
            glyphs: glyphAtlas.bases[0],
            glyphPages: glyphAtlas.bases.count > 1 ? glyphAtlas.bases : [],
            glyphGeneration: glyphAtlas.generation,
            images: imagePacker.atlas,
            imageRevision: imagePacker.revision,
            instances: instances,
            marks: marks,
            surfaces: newSurfaces,
            materials: materials,
            residentTracker: residentCacheTracker
        )
        if usedOutlines || usedLCD {
            output.outlines = textSystem.glyphAtlas.withOutlineStore { $0.snapshot(requestsLCD: usedLCD) }
        }
        // Every fresh mask has a fixup. A retained draw may already hold absolute atlas UVs.
        if glyphAtlas.fills.contains(where: { $0 != nil }) {
            output.knownGlyphMaskUse = !glyphFixups.isEmpty || output.usesGlyphAtlasMasks
        }
        output.glyphPageFills = glyphAtlas.fills
        if glyphAtlas.bases.count == 1 { output.maskFills = glyphAtlas.fills.first ?? nil }
        output.glyphPageRevisions = glyphAtlas.revisions
        output.rawGlyphPageRevisions = glyphAtlas.rawRevisions
        output.glyphPagePatches = glyphAtlas.patches
        output.rawGlyphPagePatches = glyphAtlas.rawPatches
        output.elidedLayers = elidedLayers
        imagePacker.publish(into: &output)
        if !freshRaster { labelDraws = nextLabelDraws }
        return output
    }
}
