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
}

extension El {
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
        var copy = self
        var spec = (copy.runtimeExtras[RenderExtrasKey.clipSpec] as? RenderClipSpec) ?? RenderClipSpec()
        spec.clipRect = true
        spec.radii = SIMD4<Float>(tl, tr, br, bl)
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
    imageFixups: ArraySlice<(index: Int, normUV: SIMD4<Float>, imgW: Float, imgH: Float)>,
    surfacesCount: Int,
    origin: SIMD2<Float>,
    size: SIMD2<Float>,
    blurPx: Float,
    srgbBlend: Bool,
    glyphAtlasSize: (Int, Int),
    imageAtlasSize: (Int, Int),
    userKey: UInt64?
) -> UInt64 {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325
    fnvMix(&h, UInt64(instances.count))
    fnvMix(&h, UInt64(surfacesCount))
    fnvMixFloat(&h, size.x)
    fnvMixFloat(&h, size.y)
    // Preserve subpixel phase alignment when pan hits fractional pixels; whole-pixel pans share phase 0.
    let subX = Int(((origin.x - floorf(origin.x)) * 64.0).rounded())
    let subY = Int(((origin.y - floorf(origin.y)) * 64.0).rounded())
    fnvMix(&h, UInt64(bitPattern: Int64(subX)))
    fnvMix(&h, UInt64(bitPattern: Int64(subY)))
    fnvMixFloat(&h, blurPx)
    fnvMix(&h, srgbBlend ? 1 : 0)
    fnvMix(&h, UInt64(glyphAtlasSize.0))
    fnvMix(&h, UInt64(glyphAtlasSize.1))
    fnvMix(&h, UInt64(imageAtlasSize.0))
    fnvMix(&h, UInt64(imageAtlasSize.1))
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
        fnvMixFloat4(&h, fix.normUV)
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

private struct RenderClipState {
    var rectPt: MotionRect
    var clipPx: SIMD4<Float>
    var fadeWidth: SIMD4<Float> = .zero
    var fadeOrigin: SIMD4<Float> = NO_CLIP
    var fade: SIMD4<UInt32>
    var roundedMask: (rect: SIMD4<Float>, radii: SIMD4<Float>)? = nil
}

// MARK: - `Runtime.renderFrame(at:)` (Upstream `paint/build.rs` Parity)

extension Runtime {
    /// Evaluates view + layout + motion and builds an upstream-parity 128-byte `RenderFrame` (`render::Instance` + `Clip` + `Effect` + `SystemMaterial`).
    @discardableResult
    public func renderFrame(at now: Double) -> RenderFrame {
        RuntimeIdScope.$current.withValue(runtimeId) {
            Theme.withBlend(srgbBlend) {
                let (frameOut, animNow) = stepToFrameOutputScaled(at: now)
                let rf = buildRenderFrame(frameOut: frameOut, now: animNow)
                if hasMovingScaleSettle && cxSettings.viewTimeScale > 0.0 {
                    isAnimating = true
                    animSources |= AnimSource.scaleSettle
                } else if !hasMovingScaleSettle {
                    animSources &= ~AnimSource.scaleSettle
                    if animSources == 0 {
                        isAnimating = false
                    }
                }
                finishPostFrameHooks(at: now)
                return rf
            }
        }
    }

    internal func buildRenderFrame(frameOut: FrameOutput, now: Double) -> RenderFrame {
        textSystem.glyphAtlas.beginFrame(pinnedMask: 0)
        let scale = max(pixelScale, 0.5)
        let widthPx = max(1, Int((viewport.x * scale).rounded()))
        let heightPx = max(1, Int((viewport.y * scale).rounded()))

        var rectMap: [NodeId: MotionRect] = [:]
        var opacityMap: [NodeId: Float] = [:]
        var scaleMap: [NodeId: Vec2] = [:]
        var blurMap: [NodeId: Float] = [:]
        var radiusMap: [NodeId: Corners] = [:]
        var fillMap: [NodeId: Color] = [:]
        var borderMap: [NodeId: Color] = [:]
        var movingSet: Set<NodeId> = []
        var exitingIds: Set<NodeId> = []

        for animNode in frameOut.nodes {
            rectMap[animNode.id] = animNode.rect
            opacityMap[animNode.id] = animNode.opacity
            scaleMap[animNode.id] = animNode.scale
            blurMap[animNode.id] = animNode.blur
            radiusMap[animNode.id] = animNode.corners
            if let mc = animNode.fill {
                fillMap[animNode.id] = Color(mc)
            }
            if let mb = animNode.border {
                borderMap[animNode.id] = Color(mb)
            }
            if animNode.isMoving { movingSet.insert(animNode.id) }
            if animNode.isExiting { exitingIds.insert(animNode.id) }
        }

        // Build effective render list matching `buildRefScene` (mounted + exiting)
        var renderNodes: [FlatNode] = []
        var idToFlat: [NodeId: FlatNode] = [:]
        for n in flatNodes { idToFlat[n.nodeId] = n }
        for (_, snap) in exitingSnapshots { idToFlat[snap.nodeId] = snap }

        func collectVisibleNodes(from node: FlatNode) {
            renderNodes.append(node)
            for child in flatNodes where child.parentIndex == node.index {
                collectVisibleNodes(from: child)
            }
        }
        if let root = flatNodes.first {
            collectVisibleNodes(from: root)
        }
        for animNode in frameOut.nodes where animNode.isExiting {
            if let snap = exitingSnapshots[animNode.id] {
                var exitSnap = snap
                exitSnap.zOrder = snap.zOrder + 1000
                renderNodes.append(exitSnap)
            }
        }
        renderNodes.sort { a, b in
            if a.zOrder != b.zOrder { return a.zOrder < b.zOrder }
            return a.index < b.index
        }

        var pathToPos: [String: Int] = [:]
        for (i, rn) in renderNodes.enumerated() { pathToPos[rn.path] = i }

        var newElements: [ElementInfo] = []
        var newPresentedRects: [String: MotionRect] = [:]
        var newPresentedScales: [String: Vec2] = [:]
        var newDrawnRectByPath: [String: MotionRect] = [:]
        var newRectSpringingById: [NodeId: Bool] = [:]
        var instances: [RenderInstance] = []
        var marks: [UInt32] = []
        var newSurfaces: [SurfaceDraw] = []
        var currentInheritedMark: UInt32 = 0
        var materials: [MaterialDraw] = []

        // Normalized-to-texel fixups applied once glyph/image atlases reach final size
        var glyphFixups: [(index: Int, normUV: SIMD4<Float>, texW: Float, texH: Float, page: UInt16, forceScaled: Bool)] = []
        var imageFixups: [(index: Int, normUV: SIMD4<Float>, imgW: Float, imgH: Float)] = []

        var childrenByParent: [Int: [FlatNode]] = [:]
        var roots: [FlatNode] = []
        for n in renderNodes {
            if let pIdx = n.parentIndex {
                childrenByParent[pIdx, default: []].append(n)
            } else {
                roots.append(n)
            }
        }
        for (k, v) in childrenByParent {
            childrenByParent[k] = v.sorted { $0.zOrder == $1.zOrder ? $0.index < $1.index : $0.zOrder < $1.zOrder }
        }

        let groupHoverChecker = makeGroupHoverPredicate()
        func resolveNodeHoverFrac(_ n: FlatNode, inert: Bool) -> Float {
            let nid = n.nodeId
            if inert || exitingIds.contains(nid) { return 0.0 }
            if let tracked = liveStore.get(Runtime.hoverTrackId(nid), Runtime.hoverProp) {
                return tracked.clamped(to: 0...1)
            }
            if n.el.isHoverGroup || n.el.hoverGroupShare != nil {
                return groupHoverChecker(n) ? 1.0 : 0.0
            }
            return hoveredPath == n.path ? 1.0 : 0.0
        }

        var nodeOwnOpacityById: [NodeId: Float] = [:]
        var nodeHoverFracById: [NodeId: Float] = [:]
        var inheritedGroupFracById: [NodeId: Float] = [:]
        func collectHoverAndOwnOpacity(
            _ n: FlatNode,
            inheritedInert: Bool,
            inheritedGroupFrac: Float
        ) {
            let effInert = inheritedInert || n.el.isInert
            let nid = n.nodeId
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
            nodeOwnOpacityById[nid] = ownOp
            nodeHoverFracById[nid] = ownHoverFrac
            inheritedGroupFracById[nid] = inheritedGroupFrac

            let isGroupScope = el.isHoverGroup || el.hoverBg != nil || el.hoverGroupShare != nil
            let nextGroupFrac = isGroupScope ? ownHoverFrac : inheritedGroupFrac
            for child in childrenByParent[n.index] ?? [] {
                collectHoverAndOwnOpacity(
                    child,
                    inheritedInert: effInert,
                    inheritedGroupFrac: nextGroupFrac
                )
            }
        }
        for r in roots {
            collectHoverAndOwnOpacity(
                r,
                inheritedInert: false,
                inheritedGroupFrac: 0.0
            )
        }

        // Direct children with intermediate opacity activate `.plusLighter` dissolve (`runtime/paint/build.rs:81-89`).
        var dissolveParentIds: Set<NodeId> = []
        for n in renderNodes where n.el.isDissolve {
            let children = childrenByParent[n.index] ?? []
            let hasMidOpacity = children.contains { child in
                let pOp = nodeOwnOpacityById[child.nodeId] ?? child.el.opacity
                return pOp > 0.001 && pOp < 1.0
            }
            if hasMidOpacity {
                dissolveParentIds.insert(n.nodeId)
            }
        }

        let initialClipPt = MotionRect(left: 0, top: 0, right: viewport.x, bottom: viewport.y)
        let rootClip = RenderClipState(rectPt: initialClipPt, clipPx: NO_CLIP, fade: .zero)
        let materialMode = MaterialMode.fromEnv()
        let useNativeMaterials = nativeMaterials && materialMode != .fallback

        @inline(never)
        func hasDynamicInSubtree(_ n: FlatNode) -> Bool {
            if movingSet.contains(n.nodeId)
                || exitingIds.contains(n.nodeId)
                || !n.el.liveBindings.isEmpty
                || n.el.surfacePayload != nil
                || n.el.runtimeExtras[RenderExtrasKey.effectSpec] != nil
                || n.el.runtimeExtras["systemMaterial"] != nil
                || n.el.backdropBlur > 0.05
            {
                return true
            }
            for child in childrenByParent[n.index] ?? [] {
                if hasDynamicInSubtree(child) { return true }
            }
            return false
        }

        @inline(never)
        func paintNodeHeader(
            _ node: FlatNode,
            parentClip: RenderClipState,
            inheritedInert: Bool,
            parentOpacity: Float,
            inheritedTransform: PresentedTransform,
            parentIsDissolve: Bool,
            parentScaleMotion: PaintScaleMotion
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
            extraClipLayer: Bool,
            cacheEligible: Bool,
            layerStartIdx: Int,
            surfaceStartIdx: Int,
            glyphFixupStartIdx: Int,
            imageFixupStartIdx: Int,
            scaleMotion: PaintScaleMotion
        ) {
            let nid = node.nodeId
            let el = node.el
            let subtreeDynamic = !el.liveBindings.isEmpty
                || el.surfacePayload != nil
                || el.runtimeExtras[RenderExtrasKey.effectSpec] != nil
                || el.runtimeExtras["systemMaterial"] != nil
                || el.backdropBlur > 0.05

            var liveOpacity: Float? = nil
            var liveScale: Vec2? = nil
            var liveBlur: Float? = nil
            var liveOffset: Vec2? = nil
            var liveFill: Color? = nil
            var liveRect: MotionRect? = nil
            var liveTrim: Vec2? = nil
            for b in el.liveBindings {
                let lnid = NodeId.hash("live:\(node.path):\(b.target)")
                if b.target == .opacity, let v = liveStore.get(lnid, Props.OPACITY) { liveOpacity = v }
                else if b.target == .scale, let v = liveStore.get(lnid, Props.SCALE) { liveScale = v }
                else if b.target == .blur, let bl = liveStore.get(lnid, Props.BLUR) { liveBlur = bl.radius }
                else if b.target == .offset, let o = liveStore.get(lnid, Props.OFFSET) { liveOffset = o }
                else if b.target == .trim, let tr = liveStore.get(lnid, Props.OFFSET) { liveTrim = tr }
                else if b.target == .fill {
                    if !liveStore.isMoving(lnid, Props.FILL), let exact = liveFillTargets[lnid] {
                        liveFill = exact
                    } else if let mc = liveStore.get(lnid, Props.FILL) {
                        liveFill = Color(mc)
                    }
                }
                else if b.target == .rect, let r = liveStore.get(lnid, Props.RECT) { liveRect = r }
            }

            let baseRect = liveRect ?? rectMap[nid] ?? node.targetRect
            let pinh: PresentedTransform = (el.anchor == nil ? inheritedTransform : .identity)
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
            let nextChildTransform = PresentedTransform(
                dx: ownDx,
                dy: ownDy,
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
            if el.pressScaleFactor != nil {
                recordPressRestingHit(path: node.path, rect: restingRect, clip: parentClip.rectPt, turn: el.rotate)
            }
            let effRect: MotionRect
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
            let ownScaleSpringMoving = scene.store.isAnimating(nid, Props.SCALE)
                || scene.store.isAnimating(nid, Props.UNIFORM_SCALE)
                || scene.store.isAnimating(nid, Props.PRESENCE)
                || scene.store.isAnimating(nid, Props.PRESS_SCALE)
            let ownLiveScaleMoving = el.liveBindings.contains { b in
                b.target == .scale
                    && (liveStore.isMoving(NodeId.hash("live:\(node.path):\(b.target)"), Props.SCALE) || isLinearTweenActive(b.source, at: now))
            }
            let isOwnAnimatedScale = ownScaleSpringMoving || ownLiveScaleMoving || parentScaleMotion == .moving
            let settleResult = resolveScaleSettle(nodeId: nid, scale: sc.x, isAnimated: isOwnAnimatedScale, animNow: now)
            let nodeScaleMotion: PaintScaleMotion = max(
                parentScaleMotion,
                max(ownScaleSpringMoving ? .moving : (ownLiveScaleMoving ? .live : .still), settleResult.motion)
            )
            let rasterScale = nodeScaleMotion.raster(sc: sc.x, rest: settleResult.raster)
            let ownOpacity = nodeOwnOpacityById[nid] ?? (liveOpacity ?? opacityMap[nid] ?? el.opacity)
            let effOpacity = (parentOpacity * ownOpacity).clamped(to: 0...1)
            let effBlur = max(0, liveBlur ?? blurMap[nid] ?? el.blur)
            let baseRadii = SIMD4<Float>(
                el.corners.topLeft,
                el.corners.topRight,
                el.corners.bottomRight,
                el.corners.bottomLeft
            )
            let animR = radiusMap[nid]
            let radiiPt: SIMD4<Float> = animR.map { r in
                SIMD4<Float>(r.topLeft, r.topRight, r.bottomRight, r.bottomLeft)
            } ?? baseRadii
            let radiiPx = radiiPt * scale

            let effInert = inheritedInert || el.isInert
            let visibleClipPt = intersectRects(parentClip.rectPt, effRect)
            newPresentedRects[node.path] = effRect
            newPresentedScales[node.path] = sc

            let isExiting = exitingIds.contains(nid)
            let parentSpringing = node.parentIndex.flatMap {
                flatNodes.indices.contains($0) ? newRectSpringingById[flatNodes[$0].nodeId] : nil
            } ?? false
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
            let hovered = !isExiting && (hoverFrac > 0.0005 || (!effInert && node.key != nil && hoveredKey == node.key))
            let pressed = !effInert && (pressedPath == node.path || (node.key != nil && pressedKey == node.key))
            let focused = (node.key != nil && focusedKey == node.key)

            var effBg = liveFill ?? fillMap[nid] ?? el.background
            if pressed, let pbg = el.pressBg {
                effBg = blendColorOver(bottom: effBg, top: pbg, srgb: srgbBlend)
            } else if let hbg = el.hoverBg {
                let effectiveHover = hoverFrac > 0.0005 ? hoverFrac : (hovered ? 1.0 : 0.0)
                if effectiveHover > 0.0005 {
                    effBg = blendColorOver(bottom: effBg, top: hbg.scaleAlpha(effectiveHover), srgb: srgbBlend)
                }
            }

            newElements.append(ElementInfo(
                path: node.path,
                key: node.key,
                parentIndex: node.parentIndex,
                role: el.role,
                rect: [effRect.x, effRect.y, effRect.width, effRect.height],
                target: [node.targetRect.x, node.targetRect.y, node.targetRect.width, node.targetRect.height],
                visible: [visibleClipPt.x, visibleClipPt.y, visibleClipPt.width, visibleClipPt.height],
                opacity: effOpacity,
                scale: sc.x,
                blur: effBlur,
                radius: abs(radiiPt.x),
                fill: effBg,
                textColor: el.textColor,
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
                scrolled: [scrollOffsets[node.path]?.x ?? 0, scrollOffsets[node.path]?.y ?? 0],
                caret: nil
            ))

            let isDissolveScope = dissolveParentIds.contains(nid)
            if effOpacity <= 0.001 && !isExiting {
                return (false, subtreeDynamic, effOpacity, effBlur, effRect, .zero, .zero, effInert, parentClip, nextChildTransform, isDissolveScope, false, false, false, 0, 0, 0, 0, nodeScaleMotion)
            }

            let rectPx = SIMD4<Float>(effRect.x * scale, effRect.y * scale, effRect.width * scale, effRect.height * scale)
            let clipSpec = el.runtimeExtras[RenderExtrasKey.clipSpec] as? RenderClipSpec
            let effectSpec = el.runtimeExtras[RenderExtrasKey.effectSpec] as? RenderEffectSpec
            let linearGradSpec = el.runtimeExtras[RenderExtrasKey.linearGradient] as? RenderLinearGradientSpec
            let radialGradSpec = el.runtimeExtras[RenderExtrasKey.radialGradient] as? RenderRadialGradientSpec
            let borderGradSpec = el.runtimeExtras[RenderExtrasKey.borderGradient] as? RenderBorderGradientSpec
            let shapeTrim = el.runtimeExtras[RenderExtrasKey.shapeTrim] as? Vec2 ?? liveTrim

            // Determine whether this element opens a rounded/feathered/blurred/cutout GPU layer scope.
            let clipRadiiPt: SIMD4<Float>? = clipSpec?.radii
                ?? el.clipCorners.map { SIMD4<Float>($0.topLeft, $0.topRight, $0.bottomRight, $0.bottomLeft) }
                ?? el.clipRadius.map { SIMD4<Float>(repeating: $0) }
            let gKey = el.foldGlideSpec != nil ? "fold:\(node.path)" : "growth:\(node.path)"
            let growthMaskPt: Float? = {
                guard el.isStreaming || el.isArrivesWhole || el.foldGlideSpec != nil else { return nil }
                guard let gEntry = growthRows[gKey], gEntry.track.moving else { return nil }
                let t = gEntry.track
                let featherH: Float
                if t.mask > 0.5 {
                    featherH = t.mask
                } else if let fg = el.foldGlideSpec?.feather, abs(t.h - t.target) > 0.25 {
                    featherH = fg
                } else {
                    return nil
                }
                let clamped = min(featherH, max(1, t.h))
                return clamped > 0.5 ? clamped : nil
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
            let hasRoundedClip = clipRadiiPt != nil || (el.layout.clipOverflow && el.corners.maxMagnitude != 0)
            let hasCutout = clipSpec?.cutoutCircle != nil
            let hasChildren = !(childrenByParent[node.index]?.isEmpty ?? true)
            let hasOverlappingShape = el.shapes.count > 1 || (el.shapes.first?.ops.count ?? 0) > 1
            let opacityNeedsLayer = effOpacity > 0.001 && ownOpacity > 0.001 && ownOpacity < 0.999 && (hasChildren || hasOverlappingShape)
            let cacheRequested = (el.runtimeExtras[RenderExtrasKey.cacheEnabled] as? Bool) ?? false
            let cacheEligible = cacheRequested
                && !hasCutout
                && el.backdropBlur <= 0.05
                && el.runtimeExtras[RenderExtrasKey.effectSpec] == nil
                && el.runtimeExtras["systemMaterial"] == nil
                && !hasDynamicInSubtree(node)

            let boundsClipPx = SIMD4<Float>(rectPx.x, rectPx.y, rectPx.x + rectPx.z, rectPx.y + rectPx.w)
            let combinedClipPx = intersectClipRects(parentClip.clipPx, boundsClipPx)
            var mergedFadeWidth = parentClip.fadeWidth
            var mergedFadeOrigin = parentClip.fadeOrigin
            let hasClipScope = el.layout.clipOverflow || (clipSpec?.clipRect ?? false) || clipRadiiPt != nil || clipFadeLTRB != nil || clipSpec?.fadeLinear != nil
            if hasClipScope && ownFadePx != .zero {
                inheritFade(width: &mergedFadeWidth, origin: &mergedFadeOrigin, rect: boundsClipPx, own: ownFadePx)
            }
            let scopeClipRect = hasClipScope ? combinedClipPx : parentClip.clipPx
            let scopeBaseFade: SIMD4<UInt32> = (mergedFadeWidth != .zero || parentClip.fade != .zero)
                ? packFade(width: mergedFadeWidth, origin: mergedFadeOrigin, clip: scopeClipRect)
                : .zero
            var scopeFade = scopeBaseFade
            var scopeRoundedMask: (rect: SIMD4<Float>, radii: SIMD4<Float>)? = nil
            if hasClipScope {
                if let customClipR = clipRadiiPt {
                    let cr = customClipR * scale
                    let w = packClipRadii(clip: boundsClipPx, radii: cr)
                    scopeFade = SIMD4<UInt32>(scopeFade.x, scopeFade.y, scopeFade.z, w)
                    scopeRoundedMask = (boundsClipPx, cr)
                } else if el.corners.maxMagnitude != 0 {
                    let w = packClipRadii(clip: boundsClipPx, radii: radiiPx)
                    scopeFade = SIMD4<UInt32>(scopeFade.x, scopeFade.y, scopeFade.z, w)
                    scopeRoundedMask = (boundsClipPx, radiiPx)
                }
            }

            let ownPaintsCount: Int = {
                let effBorder = borderMap[nid] ?? (borderGradSpec?.top ?? el.borderColor)
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
                && mergedFadeWidth != .zero
                && inFade(boundsClipPx, clip: scopeClipRect, width: mergedFadeWidth, origin: mergedFadeOrigin)
                && (ownPaintsCount >= 2 || (ownPaintsCount == 1 && hasChildren))

            let layerOp = el.elLayerOpacity
            let paintEffOpacity = (effOpacity * layerOp).clamped(to: 0...1)
            let layerOpacityNeedsLayer = paintEffOpacity > 0.001 && paintEffOpacity < 0.999 && layerOp < 0.999 && (hasChildren || ownPaintsCount >= 2)
            let needsLayer = el.isolatedLayer || cacheEligible || effBlur > 0.05 || abs(el.rotate) > 1e-4 || hasRoundedClip || hasCutout || isDissolveScope || parentIsDissolve || opacityNeedsLayer || fadeNeedsLayer || layerOpacityNeedsLayer
            let extraClipLayer = needsLayer && hasClipScope && hasRoundedClip && combinedClipPx != boundsClipPx && parentClip.clipPx != NO_CLIP

            let nextChildClip: RenderClipState
            if needsLayer {
                // Inner draws clip tightly to boundsPx inside layer; layer composite applies rounded/feathered mask!
                nextChildClip = RenderClipState(rectPt: visibleClipPt, clipPx: NO_CLIP, fadeWidth: .zero, fadeOrigin: NO_CLIP, fade: .zero, roundedMask: nil)
            } else if hasClipScope {
                nextChildClip = RenderClipState(
                    rectPt: visibleClipPt,
                    clipPx: scopeClipRect,
                    fadeWidth: mergedFadeWidth,
                    fadeOrigin: mergedFadeOrigin,
                    fade: scopeBaseFade,
                    roundedMask: scopeRoundedMask ?? parentClip.roundedMask
                )
            } else {
                nextChildClip = parentClip
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
            let activeClip = needsLayer ? NO_CLIP : scopeClipRect
            let activeFade = needsLayer ? SIMD4<UInt32>.zero : scopeBaseFade
            let rawLocalOpacity = needsLayer ? 1.0 : paintEffOpacity
            let localOpacity = (rawLocalOpacity * el.elPaintAlpha).clamped(to: 0...1)
            let markStartIdx = marks.count

            if needsLayer {
                if extraClipLayer {
                    var outerInst = RenderInstance.beginLayer(
                        bounds: rectPx,
                        clip: parentClip.clipPx,
                        spec: LayerSpec(opacity: 1.0, blend: .sourceOver, blur: 0, clipRadius: 0)
                    )
                    outerInst.fade = parentClip.fade
                    instances.append(outerInst)
                    marks.append(0)
                }
                let layerClip: SIMD4<Float>
                let layerFade: SIMD4<UInt32>
                if extraClipLayer {
                    layerClip = boundsClipPx
                    var ownPacked = ownFadePx != .zero
                        ? packFade(width: ownFadePx, origin: boundsClipPx, clip: boundsClipPx)
                        : .zero
                    if let (_, roundR) = scopeRoundedMask {
                        ownPacked = SIMD4<UInt32>(ownPacked.x, ownPacked.y, ownPacked.z, packClipRadii(clip: boundsClipPx, radii: roundR))
                    }
                    layerFade = ownPacked
                } else if hasClipScope {
                    layerClip = hasRoundedClip ? boundsClipPx : scopeClipRect
                    layerFade = scopeFade
                } else {
                    layerClip = parentClip.clipPx
                    layerFade = parentClip.fade
                }
                var scopeInst = RenderInstance.beginLayer(
                    bounds: rectPx,
                    clip: layerClip,
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
            let castsShadow = !el.shadows.isEmpty && blurHole == nil
            let fillA = castsShadow ? paintBg.a : 0.0
            let solidFill = castsShadow && fillA >= 1.0
            let opaqueForBands = solidFill && localOpacity >= 1.0 && linearGradSpec == nil && radialGradSpec == nil && el.gradient == nil && el.surfacePayload == nil
            let seeThroughFill = castsShadow && fillA > 0.0 && fillA < 1.0
            let dimHole: Float? = ((solidFill && localOpacity < 1.0) || seeThroughFill)
                ? clampSignedCornerRadius(shapeRadiiPx, width: rectPx.z, height: rectPx.w)
                : nil
            let shadowHole = nativeMaterialHole ?? blurHole ?? dimHole
            let circularRadiiPx = SIMD4<Float>(abs(shapeRadiiPx.x), abs(shapeRadiiPx.y), abs(shapeRadiiPx.z), abs(shapeRadiiPx.w))

            for sh in el.shadows where !sh.inset {
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
                let fill = premulSIMD4(sh.color, opacity: localOpacity, srgb: srgbBlend)
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

            // 4. Background fill, multi-stop gradients, and borders
            let bwPx = borderGradSpec.map { snapBorderWidthPx($0.width, scale: scale) }
                ?? snapBorderWidthPx(el.borderWidth, scale: scale)
            let hasSolidBg = paintBg.a > 0.001
            let softEdge = max(0.5, (clipSpec?.soft ?? 0) * scale)

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
                case let .linear(top, bottom, angle):
                    if abs(cosf(angle)) < 0.05 && borderGradSpec == nil {
                        let tCol = angle >= 0 ? top : bottom
                        let bCol = angle >= 0 ? bottom : top
                        let hasBorder = bwPx > 0 && el.borderColor.a > 0.001
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
                        if hasBorder {
                            let edgeCol = premulSIMD4(el.borderColor, opacity: localOpacity, srgb: srgbBlend)
                            instances.append(RenderInstance(
                                rect: rectPx,
                                radii: radiiPx,
                                fill: .zero,
                                border: edgeCol,
                                params: SIMD4<Float>(bwPx, KIND_RECT, softEdge, 1.0),
                                uv: .zero,
                                clip: activeClip,
                                fade: activeFade
                            ))
                            marks.append(0)
                        }
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
                case let .radial(inner, outer):
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

            let effBorderColor = borderMap[nid] ?? (borderGradSpec?.top ?? el.borderColor)
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
            if let dash = el.dashedBorder, bwPx > 0 && (effBorderColor.a > 0.001 || (borderBottomColor?.a ?? 0) > 0.001) {
                if hasSolidBg && !fillPaintedByGrad {
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
                let bgPremul = fillPaintedByGrad ? .zero : premulSIMD4(paintBg, opacity: localOpacity, srgb: srgbBlend)
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
            } else if !fillPaintedByGrad && (hasSolidBg || (bwPx > 0 && effBorderColor.a > 0.001)) {
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
                let rectInst = RenderInstance(
                    rect: rectPx,
                    radii: shapeRadiiPx,
                    fill: premulSIMD4(paintBg, opacity: localOpacity, srgb: srgbBlend),
                    border: bwPx > 0 ? topPremul : .zero,
                    params: SIMD4<Float>(bwPx, KIND_RECT, softEdge, 1.0),
                    uv: sidesVec,
                    clip: activeClip,
                    fade: activeFade
                )
                if !hasSolidBg && bwPx > 0 && effBorderColor.a > 0.001 && sidesVec == .zero {
                    PaintBands.pushRing(into: &instances, marks: &marks, inst: rectInst)
                } else {
                    instances.append(rectInst)
                    marks.append(0)
                }
            } else if fillPaintedByGrad && bwPx > 0 && effBorderColor.a > 0.001 && borderBottomPremul == nil {
                // Solid border atop multi-stop linear/radial gradient
                instances.append(RenderInstance(
                    rect: rectPx,
                    radii: radiiPx,
                    fill: .zero,
                    border: topPremul,
                    params: SIMD4<Float>(bwPx, KIND_RECT, softEdge, 1.0),
                    uv: .zero,
                    clip: activeClip,
                    fade: activeFade
                ))
                marks.append(0)
            }

            // 5. Inset shadows
            for sh in el.shadows where sh.inset {
                let sp = sh.spread * scale
                instances.append(RenderInstance(
                    rect: rectPx,
                    radii: radiiPx,
                    fill: premulSIMD4(sh.color, opacity: localOpacity, srgb: srgbBlend),
                    border: .zero,
                    params: SIMD4<Float>(sp, KIND_INSET, max(0, sh.blur * scale), 1.0),
                    uv: SIMD4<Float>(sh.x * scale, sh.y * scale, 0, 0),
                    clip: activeClip,
                    fade: activeFade
                ))
                marks.append(0)
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

            // 7. Native surface / video
            if let surf = el.surfacePayload {
                newSurfaces.append(SurfaceDraw(
                    surface: surf.surface,
                    fit: surf.fit,
                    beforeInstance: UInt32(instances.count),
                    rect: rectPx,
                    radii: radiiPx,
                    clip: activeClip,
                    fade: .zero,
                    fadeOrigin: .zero,
                    clipFade: activeFade,
                    opacity: localOpacity
                ))
            }

            // 8. Image (`RGBA8Atlas` / `Pixels` + optional `SurfaceFit`)
            if let img = el.imagePayload, img.width > 0 && img.height > 0 {
                let normUV = imagePacker.insert(img)
                let idx = instances.count
                instances.append(RenderInstance(
                    rect: rectPx,
                    radii: radiiPx,
                    fill: SIMD4<Float>(localOpacity, localOpacity, localOpacity, localOpacity),
                    border: .zero,
                    params: SIMD4<Float>(0, KIND_IMAGE, 0, 1.0),
                    uv: normUV,
                    clip: activeClip,
                    fade: activeFade
                ))
                marks.append(0)
                imageFixups.append((idx, normUV, Float(img.width), Float(img.height)))
            } else if let px = el.pixelsPayload {
                let sz = px.size
                if sz.width > 0 && sz.height > 0 {
                    let rgba = px.rgbaBytes()
                    let atlas = RGBA8Atlas(width: Int(sz.width), height: Int(sz.height), texels: rgba)
                    let normUV = imagePacker.insert(atlas)
                    let fitted = Runtime.fittedPixelsGeometry(
                        box: rectPx,
                        uv: normUV,
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
                    let premulFlag: Float = px.isPremultiplied ? 1.0 : 0.0
                    instances.append(RenderInstance(
                        rect: drawRect,
                        radii: drawRadii,
                        fill: SIMD4<Float>(localOpacity, localOpacity, localOpacity, localOpacity),
                        border: .zero,
                        params: SIMD4<Float>(0, KIND_IMAGE, premulFlag, 1.0),
                        uv: drawUV,
                        clip: activeClip,
                        fade: activeFade
                    ))
                    marks.append(0)
                    imageFixups.append((idx, drawUV, Float(sz.width), Float(sz.height)))
                }
            }

            // 9. Vector shapes (`Shape` with `trimmed`/`drawn`, `strokeWidth`, `LineCap`)
            for shape in el.shapes {
                let effective = shapeTrim.map { shape.trimmed(start: $0.x, end: $0.y) } ?? shape
                let vb = effective.viewBox ?? Vec2(max(1, effRect.width), max(1, effRect.height))
                let sx = (effRect.width * scale) / max(1e-4, vb.x)
                let sy = (effRect.height * scale) / max(1e-4, vb.y)
                let swScale = min(sx, sy)
                let ox = rectPx.x
                let oy = rectPx.y

                for op in effective.ops {
                    switch op {
                    case let .stroke(points, closed, strokeWidth, cap, color):
                        guard points.count >= 2 else { continue }
                        let hw = max(0.25, strokeWidth * 0.5 * swScale)
                        let pad = hw + 1.5
                        let col = premulSIMD4(color, opacity: localOpacity, srgb: srgbBlend)
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
                        let col = premulSIMD4(color, opacity: localOpacity, srgb: srgbBlend)
                        for (indices, aaMask) in tris {
                            let p0 = points[indices[0]]
                            let p1 = points[indices[1]]
                            let p2 = points[indices[2]]
                            let v0 = SIMD2<Float>(ox + p0.x * sx, oy + p0.y * sy)
                            let v1 = SIMD2<Float>(ox + p1.x * sx, oy + p1.y * sy)
                            let v2 = SIMD2<Float>(ox + p2.x * sx, oy + p2.y * sy)
                            let minX = min(v0.x, min(v1.x, v2.x)) - 1.5
                            let minY = min(v0.y, min(v1.y, v2.y)) - 1.5
                            let maxX = max(v0.x, max(v1.x, v2.x)) + 1.5
                            let maxY = max(v0.y, max(v1.y, v2.y)) + 1.5
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
                let iconColor = el.textColor ?? (systemDark ? Color.white : Color.black)
                if let colorDecoded = textSystem.colorIcons.rasterize(
                    svg,
                    pixelSize: iconPx,
                    currentColor: iconColor,
                    oneColor: el.isIconOneColor ? iconColor : nil,
                    mirrored: node.mirroredInRtl
                ), let baseMip = colorDecoded.mips.first {
                    let atlas = RGBA8Atlas(width: Int(baseMip.width), height: Int(baseMip.height), texels: [UInt8](baseMip.rgba))
                    let normUV = imagePacker.insert(atlas)
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
                        uv: normUV,
                        clip: activeClip,
                        fade: activeFade
                    ))
                    marks.append(0)
                    imageFixups.append((idx, normUV, pw, ph))
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

            // 10.5 TerminalGrid (`TerminalGrid`)
            if let grid = el.terminalGridPayload {
                let baseX = effRect.x + el.layout.padding.left
                let baseY = effRect.y + el.layout.padding.top
                let cellW = grid.cellSize.x
                let cellH = grid.cellSize.y
                let defaultTextColor = el.textColor ?? (systemDark ? Color.white : Color.black)
                for (rowIdx, row) in grid.rows.enumerated() {
                    let rowY = baseY + Float(rowIdx) * cellH
                    for fill in row.fills {
                        let fw = Float(max(0, fill.endColumn - fill.startColumn)) * cellW
                        guard fw > 0 else { continue }
                        let fx = baseX + Float(fill.startColumn) * cellW
                        instances.append(RenderInstance(
                            rect: SIMD4<Float>(fx * scale, rowY * scale, fw * scale, cellH * scale),
                            radii: .zero,
                            fill: premulSIMD4(fill.color, opacity: localOpacity, srgb: srgbBlend),
                            border: .zero,
                            params: .zero,
                            uv: .zero,
                            clip: activeClip,
                            fade: activeFade
                        ))
                        marks.append(0)
                    }
                    if !row.text.isEmpty || !row.spans.isEmpty {
                        let shaped = textSystem.shape(
                            text: row.text,
                            spans: row.spans.isEmpty ? nil : row.spans,
                            style: row.style,
                            maxWidth: nil,
                            pixelScale: scale
                        )
                        for gq in shaped.glyphs {
                            let gx = (baseX + gq.rect.x) * scale
                            let gy = (rowY + gq.rect.y) * scale
                            let gw = max(1.0, gq.rect.z * scale)
                            let gh = max(1.0, gq.rect.w * scale)
                            let gCol = premulSIMD4(gq.color ?? defaultTextColor, opacity: localOpacity, srgb: srgbBlend)
                            let idx = instances.count
                            instances.append(RenderInstance(
                                rect: SIMD4<Float>(gx, gy, gw, gh),
                                radii: .zero,
                                fill: gCol,
                                border: .zero,
                                params: SIMD4<Float>(0, KIND_GLYPH, systemDark ? 0.88 : 1.05, 0),
                                uv: gq.uv,
                                clip: activeClip,
                                fade: activeFade
                            ))
                            marks.append(0)
                            glyphFixups.append((idx, gq.uv, gw, gh, gq.atlasPage, false))
                        }
                    }
                    for cell in row.cells where !cell.text.isEmpty {
                        let shaped = textSystem.shape(
                            text: cell.text,
                            spans: nil,
                            style: cell.style,
                            maxWidth: nil,
                            pixelScale: scale
                        )
                        let cx = baseX + Float(cell.column) * cellW
                        for gq in shaped.glyphs {
                            let gx = (cx + gq.rect.x) * scale
                            let gy = (rowY + gq.rect.y) * scale
                            let gw = max(1.0, gq.rect.z * scale)
                            let gh = max(1.0, gq.rect.w * scale)
                            let gCol = premulSIMD4(cell.color, opacity: localOpacity, srgb: srgbBlend)
                            let idx = instances.count
                            instances.append(RenderInstance(
                                rect: SIMD4<Float>(gx, gy, gw, gh),
                                radii: .zero,
                                fill: gCol,
                                border: .zero,
                                params: SIMD4<Float>(0, KIND_GLYPH, systemDark ? 0.88 : 1.05, 0),
                                uv: gq.uv,
                                clip: activeClip,
                                fade: activeFade
                            ))
                            marks.append(0)
                            glyphFixups.append((idx, gq.uv, gw, gh, gq.atlasPage, false))
                        }
                    }
                    if let overlay = row.overlayShape {
                        for op in overlay.ops {
                            switch op {
                            case .fill(let pts, let col):
                                let c4 = premulSIMD4(col, opacity: localOpacity, srgb: srgbBlend)
                                for (indices, aaMask) in Shape.triangulate(pts) {
                                    let p0 = pts[indices[0]], p1 = pts[indices[1]], p2 = pts[indices[2]]
                                    let v0 = SIMD2<Float>((baseX + p0.x) * scale, (rowY + p0.y) * scale)
                                    let v1 = SIMD2<Float>((baseX + p1.x) * scale, (rowY + p1.y) * scale)
                                    let v2 = SIMD2<Float>((baseX + p2.x) * scale, (rowY + p2.y) * scale)
                                    let minX = min(v0.x, min(v1.x, v2.x)) - 1.5
                                    let minY = min(v0.y, min(v1.y, v2.y)) - 1.5
                                    let maxX = max(v0.x, max(v1.x, v2.x)) + 1.5
                                    let maxY = max(v0.y, max(v1.y, v2.y)) + 1.5
                                    instances.append(RenderInstance(
                                        rect: SIMD4<Float>(minX, minY, maxX - minX, maxY - minY),
                                        radii: SIMD4<Float>(v0.x, v0.y, v1.x, v1.y),
                                        fill: c4,
                                        border: .zero,
                                        params: SIMD4<Float>(Float(aaMask), KIND_TRIANGLE, 0, 1.0),
                                        uv: SIMD4<Float>(v2.x, v2.y, 0, 0),
                                        clip: activeClip,
                                        fade: activeFade
                                    ))
                                    marks.append(0)
                                }
                            case .stroke(let pts, let closed, let width, let cap, let col):
                                let c4 = premulSIMD4(col, opacity: localOpacity, srgb: srgbBlend)
                                let hw = width * scale * 0.5
                                let pad = hw + 1.5
                                let capFlag: Float = cap == .round ? 1.0 : 0.0
                                let n = pts.count
                                let count = closed ? n : max(0, n - 1)
                                for k in 0..<count {
                                    let a = pts[k], b = pts[(k + 1) % n]
                                    let ax = (baseX + a.x) * scale, ay = (rowY + a.y) * scale
                                    let bx = (baseX + b.x) * scale, by = (rowY + b.y) * scale
                                    instances.append(RenderInstance(
                                        rect: SIMD4<Float>(min(ax, bx) - pad, min(ay, by) - pad, abs(bx - ax) + pad * 2, abs(by - ay) + pad * 2),
                                        radii: SIMD4<Float>(ax, ay, bx, by),
                                        fill: c4,
                                        border: .zero,
                                        params: SIMD4<Float>(hw, KIND_SEGMENT, capFlag, 1.0),
                                        uv: .zero,
                                        clip: activeClip,
                                        fade: activeFade
                                    ))
                                    marks.append(0)
                                }
                            }
                        }
                    }
                }
            }

            // 11. Text (`plainText` / `richSpans` / `advanceIn`)
            if (el.plainText?.isEmpty == false) || (el.richSpans?.isEmpty == false) || el.advanceInRun != nil {
                let resolvedText = ElDisplayResolver.resolveText(
                    el: el,
                    rawText: el.liveText?.get() ?? el.plainText,
                    isSecure: el.isSecure
                )
                let textLeft = effRect.x + el.layout.padding.left * sc.x
                let textTop = effRect.y + el.layout.padding.top * sc.y
                let availW = max(1, (effRect.width - (el.layout.padding.left + el.layout.padding.right) * sc.x) / max(1e-4, sc.x) + 0.5)
                let innerH = max(0, (effRect.height - (el.layout.padding.top + el.layout.padding.bottom) * sc.y) / max(1e-4, sc.y))
                let shaped = resolvedText.shape(
                    using: textSystem,
                    maxWidth: availW,
                    pixelScale: rasterScale * scale,
                    emitGlyphs: true
                )
                let forceScaled = nodeScaleMotion != .still
                    || abs(sc.x - rasterScale) > 1e-4
                    || abs(sc.y - rasterScale) > 1e-4
                var glyphClipEdges = activeClip
                var glyphFade = activeFade
                if resolvedText.truncateFade {
                    let baseClipRect = SIMD4<Float>(activeClip.x, activeClip.y, max(0, activeClip.z - activeClip.x), max(0, activeClip.w - activeClip.y))
                    let fadeRes = ElDisplayResolver.truncateFadeParams(
                        el: el,
                        shaped: shaped,
                        innerW: availW,
                        innerH: innerH,
                        scaleVec: sc,
                        pxScale: scale,
                        textOriginX: textLeft,
                        textOriginY: textTop,
                        baseClipPx: baseClipRect
                    )
                    if fadeRes.isTruncated {
                        glyphClipEdges = SIMD4<Float>(
                            fadeRes.glyphClip.x,
                            fadeRes.glyphClip.y,
                            fadeRes.glyphClip.x + fadeRes.glyphClip.z,
                            fadeRes.glyphClip.y + fadeRes.glyphClip.w
                        )
                        let (pw, po) = unpackFade(activeFade)
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
                        glyphFade = packFade(width: widths, origin: origins, clip: glyphClipEdges)
                    }
                }
                let defaultTextColor = el.textColor ?? (systemDark ? Color.white : Color.black)
                for (bgRect, bgColor) in shaped.backgrounds {
                    let c = premulSIMD4(bgColor, opacity: localOpacity, srgb: srgbBlend)
                    if c.w <= 0.0005 { continue }
                    let r = min(max(0, el.elSpanRadius), bgRect.w * 0.5) * scale
                    instances.append(RenderInstance(
                        rect: SIMD4<Float>((textLeft + bgRect.x) * scale, (textTop + bgRect.y) * scale, bgRect.z * scale, bgRect.w * scale),
                        radii: SIMD4<Float>(repeating: r),
                        fill: c,
                        border: .zero,
                        params: SIMD4<Float>(0, KIND_RECT, 0, 1.0),
                        uv: .zero,
                        clip: activeClip,
                        fade: activeFade
                    ))
                    marks.append(0)
                }
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
                let wordFadeMask = (el.elRevealWordFade != nil)
                    ? wordRevealStore.mask(for: nid, text: resolvedText.displayedText, shaped: shaped, textSystem: textSystem, pixelScale: scale, now: revealClock)
                    : nil
                for gq in shaped.glyphs {
                    let wordAlpha = wordFadeMask?.alpha(for: gq) ?? 1.0
                    let gAlpha = localOpacity * wordAlpha
                    if gAlpha <= 0.0005 { continue }
                    let gx = (textLeft + gq.rect.x * sc.x) * scale
                    let gy = (textTop + gq.rect.y * sc.y) * scale
                    let gw = max(1.0, gq.rect.z * sc.x * scale)
                    let gh = max(1.0, gq.rect.w * sc.y * scale)
                    let gcol = premulSIMD4(gq.color ?? defaultTextColor, opacity: gAlpha, srgb: srgbBlend)
                    let idx = instances.count
                    instances.append(RenderInstance(
                        rect: SIMD4<Float>(gx, gy, gw, gh),
                        radii: .zero,
                        fill: gcol,
                        border: .zero,
                        params: SIMD4<Float>(0, KIND_GLYPH, 0, 1.0),
                        uv: gq.uv,
                        clip: glyphClipEdges,
                        fade: glyphFade
                    ))
                    marks.append(0)
                    glyphFixups.append((idx, gq.uv, gw, gh, gq.atlasPage, forceScaled))
                }
            }
            let hasFocusRingOverride = !isExiting && !effInert && !el.noFocusRing && (focusedPath == node.path) && focusVisible && (el.focusRingColor != nil || el.focusable)
            if !hasFocusRingOverride, let ol = el.elOutline, localOpacity > 0.0005 {
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

            return (true, subtreeDynamic, paintEffOpacity, effBlur, effRect, rectPx, radiiPx, effInert, nextChildClip, nextChildTransform, isDissolveScope, needsLayer, extraClipLayer, cacheEligible, layerStartIdx, surfaceStartIdx, glyphFixupStartIdx, imageFixupStartIdx, nodeScaleMotion)
        }

        @inline(never)
        func paintNodeFooter(
            _ node: FlatNode,
            parentClip: RenderClipState,
            effOpacity: Float,
            effBlur: Float,
            rectPx: SIMD4<Float>,
            radiiPx: SIMD4<Float>,
            needsLayer: Bool,
            extraClipLayer: Bool,
            cacheEligible: Bool,
            subtreeDynamic: Bool,
            layerStartIdx: Int,
            surfaceStartIdx: Int,
            glyphFixupStartIdx: Int,
            imageFixupStartIdx: Int
        ) {
            let nid = node.nodeId
            let el = node.el
            let focused = (node.key != nil && focusedKey == node.key)
            let activeClip = needsLayer ? NO_CLIP : parentClip.clipPx
            let activeFade = needsLayer ? SIMD4<UInt32>.zero : parentClip.fade
            let localOpacity = ((needsLayer ? 1.0 : effOpacity) * el.elPaintAlpha).clamped(to: 0...1)

            // 13. Focus ring
            if focused && focusVisible {
                let ringCol = el.focusRingColor ?? Tok.accent(0, dark: systemDark)
                let off = el.focusRingOffset * scale
                let rw = max(1.0, 2.0 * scale)
                let ringRect = SIMD4<Float>(rectPx.x - off, rectPx.y - off, rectPx.z + 2 * off, rectPx.w + 2 * off)
                instances.append(RenderInstance(
                    rect: ringRect,
                    radii: SIMD4<Float>(repeating: abs(radiiPx.x) + off),
                    fill: .zero,
                    border: premulSIMD4(ringCol, opacity: localOpacity, srgb: srgbBlend),
                    params: SIMD4<Float>(rw, KIND_RECT, 0.5, 1.0),
                    uv: .zero,
                    clip: activeClip,
                    fade: activeFade
                ))
                marks.append(0)
            }

            if needsLayer {
                let innerLayerIdx = layerStartIdx + (extraClipLayer ? 1 : 0)
                if cacheEligible && !subtreeDynamic && newSurfaces.count == surfaceStartIdx && innerLayerIdx < instances.count {
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
                        imageAtlasSize: (imagePacker.atlas.width, imagePacker.atlas.height),
                        userKey: el.runtimeExtras[RenderExtrasKey.cacheKey] as? UInt64
                    )
                    instances[innerLayerIdx].params.w = 1.0
                    instances[innerLayerIdx].radii = packU64ToFloat4(nid.rawValue)
                    instances[innerLayerIdx].uv = packU64ToFloat4(sig)
                    if residentCacheTracker.isResident(nodeId: nid.rawValue, signature: sig) {
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
                }
                foldEndLayer(
                    instances: &instances,
                    surfaces: &newSurfaces,
                    marks: &marks,
                    start: innerLayerIdx,
                    surfaceStart: surfaceStartIdx
                )
                if extraClipLayer {
                    foldEndLayer(
                        instances: &instances,
                        surfaces: &newSurfaces,
                        marks: &marks,
                        start: layerStartIdx,
                        surfaceStart: surfaceStartIdx
                    )
                }
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
            parentScaleMotion: PaintScaleMotion = .still
        ) -> Bool {
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
                parentScaleMotion: parentScaleMotion
            )
            if !h.continueSubtree { return h.subtreeDynamic }

            var subtreeDynamic = h.subtreeDynamic
            let childOpacity = (h.needsLayer ? 1.0 : h.effOpacity).clamped(to: 0...1)
            for child in childrenByParent[node.index] ?? [] {
                if paintSubtree(
                    child,
                    parentClip: h.nextChildClip,
                    inheritedInert: h.nextInert,
                    parentOpacity: childOpacity,
                    inheritedTransform: h.nextChildTransform,
                    parentIsDissolve: h.isDissolveScope,
                    parentScaleMotion: h.scaleMotion
                ) {
                    subtreeDynamic = true
                }
            }

            paintNodeFooter(
                node,
                parentClip: parentClip,
                effOpacity: h.effOpacity,
                effBlur: h.effBlur,
                rectPx: h.rectPx,
                radiiPx: h.radiiPx,
                needsLayer: h.needsLayer,
                extraClipLayer: h.extraClipLayer,
                cacheEligible: h.cacheEligible,
                subtreeDynamic: subtreeDynamic,
                layerStartIdx: h.layerStartIdx,
                surfaceStartIdx: h.surfaceStartIdx,
                glyphFixupStartIdx: h.glyphFixupStartIdx,
                imageFixupStartIdx: h.imageFixupStartIdx
            )
            return subtreeDynamic
        }

        clearPressRestingHits()
        for r in roots {
            paintSubtree(r, parentClip: rootClip, inheritedInert: false, parentOpacity: 1.0)
        }

        // Convert normalized glyph & image UVs to exact pixel texel origins using final grown atlas sizes.
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

        let imgAtlasW = Float(imagePacker.atlas.width)
        let imgAtlasH = Float(imagePacker.atlas.height)
        for fix in imageFixups where fix.index < instances.count {
            let u0 = fix.normUV.x * imgAtlasW
            let v0 = fix.normUV.y * imgAtlasH
            let uw = max(1.0, (fix.normUV.z - fix.normUV.x) * imgAtlasW)
            let vh = max(1.0, (fix.normUV.w - fix.normUV.y) * imgAtlasH)
            instances[fix.index].uv = SIMD4<Float>(u0, v0, uw, vh)
        }

        self.lastElements = newElements
        self.presentedRectByPath = newPresentedRects
        self.presentedScaleByPath = newPresentedScales
        self.drawnRectByPath = newDrawnRectByPath
        self.rectSpringingById = newRectSpringingById
        self.surfaces = newSurfaces

        let clear = clearColor.simd4(srgb: srgbBlend)
        return RenderFrame(
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
    }
}
