import Foundation
#if canImport(CoreText) && canImport(CoreGraphics)
import CoreText
import CoreGraphics
#endif

/// The mask and the direct GPU draw share a pen, measured in raster pixels from the mask's top left.
struct TextOutlineGlyph: Sendable, Hashable {
    let rect: SIMD4<Float>
    let outline: GlyphOutline
}

final class TextOutlineGroup: Sendable, Hashable {
    let generation: UInt64
    let size: SIMD2<Float>
    let glyphs: [TextOutlineGlyph]
    let smoothing: FontSmoothing
    #if canImport(CoreText) && canImport(CoreGraphics)
    struct InkVariant: @unchecked Sendable {
        let font: CTFont
        let glyph: CGGlyph
        let ppem: Float
        let phase: UInt8
        let yPhase: UInt8
        let bucket: UInt8
        let bearing: SIMD2<Float>
    }
    let inkVariant: InkVariant?

    init(size: SIMD2<Float>, glyphs: [TextOutlineGlyph], smoothing: FontSmoothing, inkVariant: InkVariant? = nil, generation: UInt64 = 0) {
        self.generation = generation
        self.size = size
        self.glyphs = glyphs
        self.smoothing = smoothing
        self.inkVariant = inkVariant
    }
    #else
    init(size: SIMD2<Float>, glyphs: [TextOutlineGlyph], smoothing: FontSmoothing, generation: UInt64 = 0) {
        self.generation = generation
        self.size = size
        self.glyphs = glyphs
        self.smoothing = smoothing
    }
    #endif

    static func == (lhs: TextOutlineGroup, rhs: TextOutlineGroup) -> Bool {
        lhs === rhs || (lhs.generation == rhs.generation && lhs.size == rhs.size
            && lhs.smoothing == rhs.smoothing && lhs.glyphs == rhs.glyphs)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(generation)
        hasher.combine(size)
        hasher.combine(smoothing)
        hasher.combine(glyphs)
    }
}

struct TextOutlineMaskKey: Hashable {
    let generation: UInt64
    let record: UInt32
    let hint: UInt32
    let size: SIMD2<Int>
    let pen: SIMD2<Float>
    let scale: Float
    let radius: Float
}

struct TextOutlineFillStats: Sendable {
    var masks: UInt64 = 0
    var texels: UInt64 = 0
    var coverNs: UInt64 = 0
    var copyNs: UInt64 = 0
    var elapsedNs: UInt64 { coverNs &+ copyNs }
}

final class TextOutlineStorage {
    let store = OutlineStore()

    #if canImport(CoreText) && canImport(CoreGraphics)
    struct Mask {
        let bytes: [UInt8]?
        let fill: OutlineFillParams
        let width: Int
        let height: Int
        let bearing: SIMD2<Float>
        let group: TextOutlineGroup
        let coverNs: UInt64
    }

    private struct Face {
        let id: UInt64
        let upem: Float
        let metrics: MacOSHintMetrics?
        let color: Bool
        let cjk: Bool
    }
    private var faces: [CTFont: Face] = [:]
    private var scaledFaces: [CTFont: Face] = [:]
    private var nextFace: UInt64 = 1

    /// CF equality includes the variation instance, face, and transform. Sizes of the same
    /// design share curves, while their mask phase and hint transforms remain independent.
    private func face(_ font: CTFont) -> Face {
        if let cached = scaledFaces[font] { return cached }
        let design = CTFontCreateCopyWithAttributes(font, 1, nil, nil)
        let result: Face
        if let cached = faces[design] {
            result = cached
        } else {
            var cjk = false
            if let os2 = CTFontCopyTable(design, CTFontTableTag(kCTFontTableOS2), []) as Data?, os2.count >= 50 {
                let range = os2[46..<50].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                cjk = range & (1 << 17 | 1 << 24 | 1 << 27) != 0
            }
            result = Face(id: nextFace, upem: Float(CTFontGetUnitsPerEm(design)),
                          metrics: MacOSHinter.trueTypeMetrics(font: design), color: GlyphAtlas.isColorFont(design), cjk: cjk)
            nextFace &+= 1
            if faces.count >= 1024 { faces.removeAll(keepingCapacity: true) }
            faces[design] = result
        }
        if scaledFaces.count >= 1024 { scaledFaces.removeAll(keepingCapacity: true) }
        scaledFaces[font] = result
        return result
    }

    /// Light autohint can preserve fractional pens. The CJK TrueType interpreter and
    /// the explicit whole-pixel mode need a phase-zero glyph on the nearest pixel.
    func usesWholePen(font: CTFont, ppem: Float, smoothing: FontSmoothing) -> Bool {
        let face = face(font)
        return !face.color && (smoothing == .hinted || (smoothing != .hintedGpu && face.cjk && ppem <= 24))
    }

    func mask(font: CTFont, glyph: CGGlyph, ppem: Float, smoothing: FontSmoothing, phase: Float,
              shiftY: Float, inkBucket: UInt8, maximumSide: Int, deferred: Bool) -> Mask? {
        let face = face(font)
        // A CoreText design path has no FreeType light autohint or CJK bytecode at this ppem.
        guard ppem.isFinite, ppem > 0, face.upem > 0, !face.color,
              smoothing != .hinted && smoothing != .hintedGpu,
              !face.cjk || ppem > 24 else { return nil }
        let key = OutlineStore.Key(font: face.id, glyph: UInt32(glyph))
        guard case .outline(let record) = store.glyph(key, build: {
            OutlineBuilder.build(commands: OutlineBuilder.commands(font: font, glyph: glyph), upem: face.upem)
        }) else { return nil }

        let weight = smoothing == .windfoil
            ? GlyphOutline.dilation(ppem: ppem, inkBucket: inkBucket) : 0
        let hint: UInt32
        if smoothing == .windfoil, let metrics = face.metrics,
           let transform = MacOSHinter.autohint(metrics, ppem: Double(ppem), d: weight) {
            hint = store.hint(transform.values)
        } else {
            hint = 0
        }
        let coverage: UInt32 = smoothing == .slug ? 1 : smoothing == .windfoilRgb ? 2 : 0
        var outline = GlyphOutline(pen: SIMD2(phase, 0), scale: ppem / face.upem,
                                   zoom: 1, record: record.record, hint: hint, radius: Float(weight), coverage: coverage)
        let box = outline.rect(bbox: record.bbox)
        let left = floorf(box.x), top = floorf(box.y)
        let width = ceilf(box.x + box.z) - left, height = ceilf(box.y + box.w) + 1 - top
        guard width > 0, height > 0, width <= Float(maximumSide), height <= Float(maximumSide) else { return nil }
        outline.pen = SIMD2(phase - left, shiftY - top)
        let fill = OutlineFillParams(record: record.record, hint: hint, scale: outline.scale,
                                     radius: outline.radius, pen: outline.pen, coverage: coverage == 2 ? 0 : coverage)
        let start = RuneExecutionContext.uptimeNanoseconds
        let bytes = deferred ? nil : OutlineMaskFiller.fillMask(store: store, fill: fill, atX: 0, atY: 0,
                                              width: UInt32(width), height: UInt32(height))
        let coverNs = RuneExecutionContext.uptimeNanoseconds - start
        let size = SIMD2(width, height)
        let variant = smoothing == .windfoil ? TextOutlineGroup.InkVariant(font: font, glyph: glyph, ppem: ppem,
                        phase: UInt8((phase * 60).rounded()), yPhase: UInt8((shiftY * 4).rounded()),
                        bucket: inkBucket, bearing: SIMD2(left, top)) : nil
        let group = TextOutlineGroup(size: size, glyphs: [.init(rect: SIMD4(0, 0, width, height), outline: outline)],
                                     smoothing: smoothing, inkVariant: variant, generation: store.generation)
        return Mask(bytes: bytes, fill: fill, width: Int(width), height: Int(height), bearing: SIMD2(left, top),
                    group: group, coverNs: coverNs)
    }
    #endif
}

extension GlyphAtlas {
    /// CoreGraphics weight depends on the ink's linear luminance, including for two uses of the
    /// same cached shaped line in different colours. Resolve this last part at paint time.
    @TaskLocal static var baseInkBucket: UInt8 = 0

    /// On a cache miss the shaper can prepare the requested ink immediately. The paint
    /// resolver still handles later colour changes, selections, and highlighted spans.
    static func withBaseInk<Result>(_ ink: Color, mode: FontSmoothing, _ shape: () -> Result) -> Result {
        #if canImport(CoreText) && canImport(CoreGraphics)
        if mode == .windfoil || (mode == .on && mode.pipeline.dilate) {
            let bucket = inkBucket(SIMD4(ink.r, ink.g, ink.b, ink.a), encoded: false) ?? 0
            if bucket != baseInkBucket { return $baseInkBucket.withValue(bucket, operation: shape) }
        }
        #endif
        return shape()
    }

    /// All sufficiently bright inks share one atlas mask when dilation reaches its cap.
    static func dilationBucket(_ bucket: UInt8, ppem: Float) -> UInt8 {
        let bounded = min(4, bucket)
        let radius = Double(ppem) * (0.0058 + Double(bounded) * 0.0025)
        return radius >= Double(Float(0.3)) ? 4 : bounded
    }

    static func inkBucket(_ ink: SIMD4<Float>, encoded: Bool) -> UInt8? {
        func linear(_ value: Float) -> Float {
            guard encoded, value > 0 else { return value }
            return value <= 0.04045 ? value / 12.92 : powf((value + 0.055) / 1.055, 2.4)
        }
        let luma = (Double(linear(ink.y)) * 0.7152)
            .addingProduct(Double(linear(ink.x)), 0.2126)
            .addingProduct(Double(linear(ink.z)), 0.0722)
        guard luma.isFinite else { return nil }
        return UInt8(max(0, min(4, (4 * luma).rounded())))
    }

    func outlineInk(_ glyph: PositionedGlyph, rect: SIMD4<Float>, ink: SIMD4<Float>, encoded: Bool)
        -> (PositionedGlyph, SIMD4<Float>) {
        outlineInk(glyph, rect: rect, bucket: Self.inkBucket(ink, encoded: encoded))
    }

    func outlineInk(_ glyph: PositionedGlyph, rect: SIMD4<Float>, bucket: UInt8?)
        -> (PositionedGlyph, SIMD4<Float>) {
        #if canImport(CoreText) && canImport(CoreGraphics)
        let source: TextOutlineGroup.InkVariant, size: SIMD2<Float>, smoothing: FontSmoothing
        if let classic = glyph.classicInk {
            (source, size, smoothing) = (classic.source, classic.size, classic.smoothing)
        } else if let group = glyph.outlineGroup, let variant = group.inkVariant {
            (source, size, smoothing) = (variant, group.size, group.smoothing)
        } else {
            return (glyph, rect)
        }
        guard let bucket, Self.dilationBucket(bucket, ppem: source.ppem) != source.bucket,
              let entry = rasterizeGlyph(font: source.font, glyph: source.glyph, fontSizePx: source.ppem,
                                         phaseX: source.phase, subpixelYBin: source.yPhase,
                                         smoothing: smoothing, inkBucket: bucket), entry.pixelSize.x > 0, entry.pixelSize.y > 0 else {
            return (glyph, rect)
        }
        var resolved = glyph
        resolved.atlasPage = entry.page
        resolved.uv = entry.uv
        resolved.classicInk = entry.classicInk
        resolved.outlineGroup = entry.outlineGroup
        let scale = SIMD2(rect.z, rect.w) / size
        let delta = (entry.bearingPx - source.bearing) * scale
        return (resolved, SIMD4(rect.x + delta.x, rect.y + delta.y, Float(entry.pixelSize.x) * scale.x, Float(entry.pixelSize.y) * scale.y))
        #elseif os(Linux) || os(Windows) || os(Android)
        if let bucket, bucket != 0, let variant = glyph.desktopInk {
            return variant.resolve(glyph, rect: rect, bucket: bucket, atlas: self)
        }
        return (glyph, rect)
        #else
        return (glyph, rect)
        #endif
    }
}

extension TextOutlineGroup {
    /// Nonuniform stretching keeps its prepared mask. The upstream outline integrator accepts one zoom.
    func appendInstances(into instances: inout [RenderInstance], marks: inout [UInt32], rect: SIMD4<Float>,
                         ink: SIMD4<Float>, gamma: Float, lcd: Bool, clip: SIMD4<Float>, fade: SIMD4<UInt32>) -> Bool {
        guard !glyphs.isEmpty, size.x > 0, size.y > 0 else { return false }
        let zoom = rect.z / size.x
        guard zoom.isFinite, zoom > 0, abs(zoom - rect.w / size.y) < 0.001 * zoom else { return false }
        for glyph in glyphs {
            let r = glyph.rect
            let o = glyph.outline
            let placed = SIMD4(rect.x + r.x * zoom, rect.y + r.y * zoom, r.z * zoom, r.w * zoom)
            let coverage = o.coverage == 2 && !lcd ? 0 : o.coverage
            instances.append(RenderInstance(rect: placed,
                radii: SIMD4(rect.x + o.pen.x * zoom, rect.y + o.pen.y * zoom, o.scale, o.zoom * zoom),
                fill: ink, border: SIMD4(Float(o.record), Float(o.hint), o.radius, Float(coverage)),
                params: SIMD4(0, KIND_GLYPH, 0, gamma), uv: .zero, clip: clip, fade: fade))
            marks.append(0)
        }
        return true
    }
}
