import Foundation
import RuneRef

// MARK: - Core Render ABI Constants (upstream `crates/rune/src/render.rs`)

public let KIND_RECT: Float = 0
public let KIND_SHADOW: Float = 1
public let KIND_GLYPH: Float = 2
public let KIND_INSET: Float = 3
public let KIND_GRADIENT: Float = 4
public let KIND_SEGMENT: Float = 5
public let KIND_TRIANGLE: Float = 6
public let KIND_IMAGE: Float = 7
public let KIND_LAYER: Float = 8
public let KIND_LAYER_END: Float = 9
public let KIND_DASHED: Float = 10
public let KIND_RADIAL: Float = 11
public let KIND_EFFECT: Float = 12
public let KIND_BACKDROP_BLUR: Float = 13

public let CONTINUOUS_K: Float = 1.52866483
public let NO_CLIP = SIMD4<Float>(-1e6, -1e6, 1e6, 1e6)
public let MAX_BACKDROP_BLURS: Int = 4
public let DEFAULT_LAYER_CACHE_BUDGET: UInt64 = 64 * 1024 * 1024

/// How far a corner of `radius` reaches along each edge (`render::corner_extent`).
/// Negative radii draw Apple's continuous corner, reaching `|radius| * CONTINUOUS_K`.
@inlinable
public func cornerExtent(_ radius: Float) -> Float {
    radius < 0 ? -radius * CONTINUOUS_K : radius
}

/// Layer composite blend mode (`render::Blend`).
public enum RenderBlend: UInt8, Sendable, Equatable {
    case sourceOver = 0
    case plusLighter = 1
}

/// Specification for an isolated rendering scope (`render::LayerSpec`).
public struct LayerSpec: Sendable, Equatable {
    public var opacity: Float
    public var blend: RenderBlend
    public var blur: Float
    public var clipRadius: Float

    public init(
        opacity: Float = 1.0,
        blend: RenderBlend = .sourceOver,
        blur: Float = 0.0,
        clipRadius: Float = 0.0
    ) {
        self.opacity = opacity
        self.blend = blend
        self.blur = blur
        self.clipRadius = clipRadius
    }
}

/// Resource/pass counters for diagnostics (`render::LayerStats`).
public struct LayerStats: Sendable, Equatable {
    public var targets: Int = 0
    public var bytes: UInt64 = 0
    public var extraPasses: Int = 0
    public var allocations: UInt64 = 0
    public var cachedLayers: Int = 0
    public var cachedBytes: UInt64 = 0
    public var hits: UInt64 = 0
    public var misses: UInt64 = 0
    public var evictions: UInt64 = 0

    public init(
        targets: Int = 0,
        bytes: UInt64 = 0,
        extraPasses: Int = 0,
        allocations: UInt64 = 0,
        cachedLayers: Int = 0,
        cachedBytes: UInt64 = 0,
        hits: UInt64 = 0,
        misses: UInt64 = 0,
        evictions: UInt64 = 0
    ) {
        self.targets = targets
        self.bytes = bytes
        self.extraPasses = extraPasses
        self.allocations = allocations
        self.cachedLayers = cachedLayers
        self.cachedBytes = cachedBytes
        self.hits = hits
        self.misses = misses
        self.evictions = evictions
    }
}

/// 48-byte uniform block passed to `vs`, `vs_springs`, and `fs` (`render::Globals`).
public struct RenderGlobals: Sendable, Equatable {
    public var viewport: SIMD2<Float>
    public var pad: SIMD2<Float>
    public var flags: SIMD4<Float>
    public var projection: SIMD4<Float>

    public init(
        viewport: SIMD2<Float> = .zero,
        pad: SIMD2<Float> = .zero,
        flags: SIMD4<Float> = .zero,
        projection: SIMD4<Float> = .zero
    ) {
        self.viewport = viewport
        self.pad = pad
        self.flags = flags
        self.projection = projection
    }
}

// MARK: - 128-byte Upstream Instance ABI (`render::Instance`)

/// One instance in device pixels, matching upstream `render::Instance` (128 bytes, 8 x 16-byte vectors).
public struct RenderInstance: Sendable, Equatable {
    public var rect: SIMD4<Float>
    public var radii: SIMD4<Float>
    public var fill: SIMD4<Float>
    public var border: SIMD4<Float>
    /// `[borderWidth / flag, kind, shadowSigma / bleed / soft, glyphGamma / scale / t1]`
    public var params: SIMD4<Float>
    public var uv: SIMD4<Float>
    /// Clip bounds `[x0, y0, x1, y1]` in device pixels.
    public var clip: SIMD4<Float>
    /// Packed clip fade widths (f16 LTRB), origin offsets (4x unorm8), and packed rounded clip radii (`fade[3]`).
    public var fade: SIMD4<UInt32>

    public init(
        rect: SIMD4<Float> = .zero,
        radii: SIMD4<Float> = .zero,
        fill: SIMD4<Float> = .zero,
        border: SIMD4<Float> = .zero,
        params: SIMD4<Float> = .zero,
        uv: SIMD4<Float> = .zero,
        clip: SIMD4<Float> = NO_CLIP,
        fade: SIMD4<UInt32> = .zero
    ) {
        self.rect = rect
        self.radii = radii
        self.fill = fill
        self.border = border
        self.params = params
        self.uv = uv
        self.clip = clip
        self.fade = fade
    }

    public static let zero = RenderInstance(clip: .zero)

    /// Applies a uniform signed clip radius (negative = continuous corners) into `fade[3]`.
    public mutating func roundClip(_ radius: Float) {
        roundClipCorners(SIMD4<Float>(repeating: radius))
    }

    /// Packs per-corner signed clip radii `[tl, tr, br, bl]` into `fade[3]`.
    public mutating func roundClipCorners(_ radii: SIMD4<Float>) {
        fade.w = packClipRadii(clip: clip, radii: radii)
    }

    /// Begins an isolated scope (`Instance::begin_layer`).
    public static func beginLayer(
        bounds: SIMD4<Float>,
        clip: SIMD4<Float>,
        spec: LayerSpec = LayerSpec()
    ) -> RenderInstance {
        var inst = RenderInstance(
            rect: bounds,
            radii: .zero,
            fill: SIMD4<Float>(0, 0, 0, min(max(spec.opacity, 0), 1)),
            border: .zero,
            params: SIMD4<Float>(
                spec.blend == .plusLighter ? 1.0 : 0.0,
                KIND_LAYER,
                min(max(spec.blur, 0), 64.0),
                0.0
            ),
            uv: .zero,
            clip: clip,
            fade: .zero
        )
        inst.roundClip(spec.clipRadius)
        return inst
    }

    /// Turns this layer composite `angle` radians clockwise about `pivot` (device pixels).
    public func turned(angle: Float, pivot: SIMD2<Float>) -> RenderInstance {
        var copy = self
        copy.border = SIMD4<Float>(0, angle, pivot.x, pivot.y)
        return copy
    }

    /// Closes an isolated scope (`Instance::end_layer`).
    public static func endLayer() -> RenderInstance {
        RenderInstance(
            rect: .zero,
            radii: .zero,
            fill: .zero,
            border: .zero,
            params: SIMD4<Float>(0, KIND_LAYER_END, 0, 0),
            uv: .zero,
            clip: .zero,
            fade: .zero
        )
    }
}

/// Losslessly encodes a `UInt64` across 4 `Float` lanes using 16-bit integer chunks (free of NaN hazards).
@inline(__always)
public func packU64ToFloat4(_ value: UInt64) -> SIMD4<Float> {
    SIMD4<Float>(
        Float(value & 0xFFFF),
        Float((value >> 16) & 0xFFFF),
        Float((value >> 32) & 0xFFFF),
        Float((value >> 48) & 0xFFFF)
    )
}

/// Decodes a `UInt64` previously encoded with `packU64ToFloat4(_:)`.
@inline(__always)
public func unpackFloat4ToU64(_ v: SIMD4<Float>) -> UInt64 {
    let a = UInt64(max(0, min(65535, Int(v.x.rounded()))))
    let b = UInt64(max(0, min(65535, Int(v.y.rounded()))))
    let c = UInt64(max(0, min(65535, Int(v.z.rounded()))))
    let d = UInt64(max(0, min(65535, Int(v.w.rounded()))))
    return a | (b << 16) | (c << 32) | (d << 48)
}

/// Tracks which `(nodeId, signature)` cached layers are currently resident in GPU `LayersPool` memory so
/// `Runtime` can elide unchanged cached subtrees (`cache_layer.rs`).
public final class ResidentLayerTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UInt64: UInt64] = [:]

    public init() {}

    public func isResident(nodeId: UInt64, signature: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[nodeId] == signature
    }

    public func markResident(nodeId: UInt64, signature: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        entries[nodeId] = signature
    }

    public func evict(nodeId: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: nodeId)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    public var isEmpty: Bool { count == 0 }
}

// MARK: - IEEE-754 f16 + Fade & Clip Radii Packing

@inline(__always)
public func f32ToF16Bits(_ value: Float) -> UInt16 {
    let bits = value.bitPattern
    let sign = UInt16((bits >> 16) & 0x8000)
    let exp = Int((bits >> 23) & 0xff)
    let frac = bits & 0x007f_ffff
    if exp == 0xff {
        if frac == 0 { return sign | 0x7c00 }
        let payload = UInt16(max(1, frac >> 13))
        return sign | 0x7e00 | (payload & 0x03ff)
    }
    let unbiased = exp - 127
    if unbiased > 15 {
        return sign | 0x7c00
    }
    if unbiased >= -14 {
        let hExp = UInt32(unbiased + 15)
        let roundBit = (frac >> 12) & 1
        let sticky = (frac & 0x0fff) != 0 ? UInt32(1) : UInt32(0)
        var hMant = frac >> 13
        let lsb = hMant & 1
        if roundBit != 0 && (sticky != 0 || lsb != 0) {
            hMant += 1
        }
        if hMant >= 0x0400 {
            let nextExp = hExp + 1
            if nextExp >= 31 {
                return sign | 0x7c00
            }
            return sign | UInt16(nextExp << 10)
        }
        return sign | UInt16((hExp << 10) | (hMant & 0x03ff))
    }
    if unbiased >= -24 {
        let mant = frac | 0x0080_0000
        let shift = (-14 - unbiased) + 13
        let base = mant >> shift
        let remMask = (UInt32(1) << shift) - 1
        let rem = mant & remMask
        let halfWay = UInt32(1) << (shift - 1)
        var hMant = base
        if rem > halfWay || (rem == halfWay && (base & 1) != 0) {
            hMant += 1
        }
        if hMant >= 0x0400 {
            return sign | 0x0400
        }
        return sign | UInt16(hMant)
    }
    return sign
}

@inline(__always)
public func f16BitsToF32(_ bits: UInt16) -> Float {
    let sign = UInt32(bits & 0x8000) << 16
    let exp = Int((bits >> 10) & 0x1f)
    let frac = UInt32(bits & 0x03ff)
    if exp == 0 {
        if frac == 0 {
            return Float(bitPattern: sign)
        }
        var m = frac
        var e: Int = 127 - 14
        while (m & 0x0400) == 0 {
            m <<= 1
            e -= 1
        }
        m &= 0x03ff
        return Float(bitPattern: sign | (UInt32(e) << 23) | (m << 13))
    }
    if exp == 31 {
        let f = frac == 0 ? 0 : ((frac << 13) | 0x0040_0000)
        return Float(bitPattern: sign | 0x7f80_0000 | f)
    }
    let fExp = UInt32(exp + 127 - 15) << 23
    return Float(bitPattern: sign | fExp | (frac << 13))
}

/// Packs per-edge soft/linear clip fade widths and inward origin offsets (`render::pack_fade`).
public func packFade(
    width: SIMD4<Float>,
    origin: SIMD4<Float>,
    clip: SIMD4<Float>
) -> SIMD4<UInt32> {
    let h0 = UInt32(f32ToF16Bits(min(max(width.x, -65504.0), 65504.0)))
    let h1 = UInt32(f32ToF16Bits(min(max(width.y, -65504.0), 65504.0)))
    let h2 = UInt32(f32ToF16Bits(min(max(width.z, -65504.0), 65504.0)))
    let h3 = UInt32(f32ToF16Bits(min(max(width.w, -65504.0), 65504.0)))
    let widths = [width.x, width.y, width.z, width.w]
    let origins = [origin.x, origin.y, origin.z, origin.w]
    let clips = [clip.x, clip.y, clip.z, clip.w]
    var offsets: UInt32 = 0
    for edge in 0..<4 {
        let distance = edge < 2 ? (clips[edge] - origins[edge]) : (origins[edge] - clips[edge])
        let w = abs(widths[edge])
        let offset: Float = w > 0 ? min(max(distance / w, 0.0), 1.0) : 0.0
        offsets |= UInt32(offset * 255.0 + 0.5) << (edge * 8)
    }
    return SIMD4<UInt32>(h0 | (h1 << 16), h2 | (h3 << 16), offsets, 0)
}

/// Decodes widths and normalized origin offsets from packed `fade` (`render::unpack_fade`).
public func unpackFade(_ fade: SIMD4<UInt32>) -> (width: SIMD4<Float>, offset: SIMD4<Float>) {
    let w = SIMD4<Float>(
        f16BitsToF32(UInt16(fade.x & 0xFFFF)),
        f16BitsToF32(UInt16((fade.x >> 16) & 0xFFFF)),
        f16BitsToF32(UInt16(fade.y & 0xFFFF)),
        f16BitsToF32(UInt16((fade.y >> 16) & 0xFFFF))
    )
    let o = SIMD4<Float>(
        Float(fade.z & 0xFF) / 255.0,
        Float((fade.z >> 8) & 0xFF) / 255.0,
        Float((fade.z >> 16) & 0xFF) / 255.0,
        Float((fade.z >> 24) & 0xFF) / 255.0
    )
    return (w, o)
}

/// Packs per-corner signed clip radii `[tl, tr, br, bl]` into `RenderInstance.fade.w` (`render::pack_clip_radii`).
public func packClipRadii(clip: SIMD4<Float>, radii: SIMD4<Float>) -> UInt32 {
    let half = max(min(clip.z - clip.x, clip.w - clip.y) * 0.5, 0.0)
    let maxUniform = Float(bitPattern: 0x5fff_ffff)
    let raw = [radii.x, radii.y, radii.z, radii.w]
    let clamped = raw.map { radius -> Float in
        let r = min(abs(radius), min(half, maxUniform))
        return (radius < 0 && r > 0) ? -r : r
    }
    if clamped[0] == clamped[1] && clamped[1] == clamped[2] && clamped[2] == clamped[3] {
        return clamped[0] == 0.0 ? 0 : clamped[0].bitPattern
    }
    let continuous = clamped.contains { $0 < 0.0 }
    let maxR = clamped.reduce(0.0 as Float) { max($0, abs($1)) }
    let coarse = maxR > 63.5
    let invStep: Float = coarse ? 0.5 : 2.0
    var bits: UInt32 = 0x6000_0000
        | (continuous ? 0x8000_0000 : 0)
        | (coarse ? 0x1000_0000 : 0)
    for (idx, r) in clamped.enumerated() {
        let q = UInt32(min(max((abs(r) * invStep).rounded(), 0.0), 127.0))
        bits |= q << (idx * 7)
    }
    return bits
}

/// Decodes `RenderInstance.fade.w` into four signed corner radii `[tl, tr, br, bl]`.
public func unpackClipRadii(_ w: UInt32) -> SIMD4<Float> {
    if w == 0 {
        return .zero
    }
    if (w & 0x6000_0000) != 0x6000_0000 {
        return SIMD4<Float>(repeating: Float(bitPattern: w))
    }
    let step: Float = (w & 0x1000_0000) != 0 ? 2.0 : 0.5
    let sign: Float = (w & 0x8000_0000) != 0 ? -1.0 : 1.0
    func corner(_ idx: Int) -> Float {
        let q = (w >> (idx * 7)) & 0x7f
        return q == 0 ? 0.0 : Float(q) * step * sign
    }
    return SIMD4<Float>(corner(0), corner(1), corner(2), corner(3))
}

@inlinable
public func effectMark(_ instance: RenderInstance) -> UInt32 {
    (UInt32(instance.border.x) & 0xFFFF) | ((UInt32(instance.border.y) & 0xFFFF) << 16)
}

@inlinable
public func packU64F32(_ v: UInt64) -> SIMD4<Float> {
    SIMD4<Float>(
        Float(v & 0xFFFF),
        Float((v >> 16) & 0xFFFF),
        Float((v >> 32) & 0xFFFF),
        Float((v >> 48) & 0xFFFF)
    )
}

@inlinable
public func unpackU64F32(_ a: SIMD4<Float>) -> UInt64 {
    (UInt64(a.x) & 0xFFFF)
        | ((UInt64(a.y) & 0xFFFF) << 16)
        | ((UInt64(a.z) & 0xFFFF) << 32)
        | ((UInt64(a.w) & 0xFFFF) << 48)
}

/// Closes a runtime scope, folding empty/single-draw groups back into the direct path (`render::end_layer`).
public func foldEndLayer(
    instances: inout [RenderInstance],
    surfaces: inout [SurfaceDraw],
    marks: inout [UInt32],
    start: Int,
    surfaceStart: Int
) {
    let primitives = instances.count - start - 1
    let videos = surfaces.count - surfaceStart
    let scope = instances[start]
    let unmasked: Bool
    if primitives == 1 {
        unmasked = instances[start + 1].clip == NO_CLIP && instances[start + 1].fade == .zero
    } else if videos == 1 {
        unmasked = surfaces[surfaceStart].clip == NO_CLIP && surfaces[surfaceStart].clipFade == .zero
    } else {
        unmasked = true
    }
    let transferClip = scope.fade.w == 0 && unmasked
    let fadedEffect = primitives == 1 && instances[start + 1].params.y == KIND_EFFECT && scope.fill.w != 1.0
    if !fadedEffect
        && primitives + videos <= 1
        && (primitives + videos == 0 || (scope.border.y == 0 && scope.radii == .zero))
        && scope.params.x == 0
        && scope.params.z == 0
        && scope.params.w == 0
        && (transferClip || (scope.clip == NO_CLIP && scope.fade == .zero))
    {
        let opacity = scope.fill.w
        if primitives == 1 {
            var inst = instances[start + 1]
            if transferClip {
                inst.clip = scope.clip
                inst.fade = scope.fade
            }
            inst.fill *= opacity
            if inst.params.y != KIND_GLYPH {
                inst.border *= opacity
            }
            if inst.params.y == KIND_GRADIENT {
                inst.uv *= opacity
            }
            if inst.params.y == KIND_RECT || inst.params.y == KIND_GRADIENT {
                inst.params.w *= opacity
            }
            instances[start + 1] = inst
        }
        if videos == 1 {
            if transferClip {
                surfaces[surfaceStart].clip = scope.clip
                surfaces[surfaceStart].clipFade = scope.fade
            }
            surfaces[surfaceStart].opacity *= opacity
            if surfaces[surfaceStart].beforeInstance > 0 {
                surfaces[surfaceStart].beforeInstance -= 1
            }
        }
        instances.remove(at: start)
        if marks.count > start {
            marks.remove(at: start)
        }
    } else {
        instances.append(.endLayer())
        if start < marks.count {
            marks.append(marks[start])
        }
    }
}

// MARK: - Effect Slots (`EffectSite` / `EffectHook` / `EffectPhase` / `EffectBackdropHook`)

#if canImport(Metal)
import Metal
#endif

/// Where a compositor is asked to draw an effect slot (`MetalRenderer.drawRangeWith` / `drawWith*`).
public struct EffectSite {
    public let index: UInt32
    public let instance: RenderInstance
    public let mark: UInt32
    public let data: SIMD4<Float>
    public let scale: Float
    public let pixelSize: (width: Int, height: Int)
    public let origin: SIMD2<Float>
    public let inLayer: Bool
    public let opacity: Float
    public let turn: Float
    public let srgbBlend: Bool
    #if canImport(Metal)
    public let pixelFormat: MTLPixelFormat
    public let backdrop: MTLTexture?

    public init(
        index: UInt32,
        instance: RenderInstance,
        mark: UInt32,
        data: SIMD4<Float>,
        scale: Float,
        pixelFormat: MTLPixelFormat,
        origin: SIMD2<Float>,
        pixelSize: (width: Int, height: Int),
        inLayer: Bool,
        opacity: Float = 1.0,
        turn: Float = 0.0,
        srgbBlend: Bool,
        backdrop: MTLTexture?
    ) {
        self.index = index
        self.instance = instance
        self.mark = mark
        self.data = data
        self.scale = scale
        self.pixelFormat = pixelFormat
        self.origin = origin
        self.pixelSize = pixelSize
        self.inLayer = inLayer
        self.opacity = opacity
        self.turn = turn
        self.srgbBlend = srgbBlend
        self.backdrop = backdrop
    }
    #else
    public init(
        index: UInt32,
        instance: RenderInstance,
        mark: UInt32,
        data: SIMD4<Float>,
        scale: Float,
        origin: SIMD2<Float>,
        pixelSize: (width: Int, height: Int),
        inLayer: Bool,
        opacity: Float = 1.0,
        turn: Float = 0.0,
        srgbBlend: Bool
    ) {
        self.index = index
        self.instance = instance
        self.mark = mark
        self.data = data
        self.scale = scale
        self.origin = origin
        self.pixelSize = pixelSize
        self.inLayer = inLayer
        self.opacity = opacity
        self.turn = turn
        self.srgbBlend = srgbBlend
    }
    #endif
}

#if canImport(Metal)
public enum EffectPhase {
    /// Outside any active render command encoder, after target->backdrop copy completes.
    case backdrop(MTLCommandBuffer)
    /// Inside the open render command encoder at the slot's painter position (scissor already clipped).
    case draw(MTLRenderCommandEncoder)
}

public typealias EffectHook = (MTLRenderCommandEncoder, EffectSite) -> Void
public typealias EffectBackdropHook = (EffectPhase, EffectSite) -> Void
#endif

// MARK: - RenderFrame (Full Upstream Frame Payload)

/// Complete device-pixel frame built by `Runtime.renderFrame(at:)` matching upstream `render::Instance`.
public struct RenderFrame: Sendable {
    public var width: Int
    public var height: Int
    public var srgbBlend: Bool
    public var clearColor: SIMD4<Float>
    public var glyphs: R8Atlas
    public var glyphGeneration: UInt64
    public var images: RGBA8Atlas
    public var imageRevision: UInt64
    public var instances: [RenderInstance]
    public var marks: [UInt32]
    public var surfaces: [SurfaceDraw]
    public var materials: [MaterialDraw]
    public var residentTracker: ResidentLayerTracker?

    public init(
        width: Int,
        height: Int,
        srgbBlend: Bool = false,
        clearColor: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1),
        glyphs: R8Atlas = R8Atlas(),
        glyphGeneration: UInt64 = 1,
        images: RGBA8Atlas = RGBA8Atlas(),
        imageRevision: UInt64 = 1,
        instances: [RenderInstance] = [],
        marks: [UInt32] = [],
        surfaces: [SurfaceDraw] = [],
        materials: [MaterialDraw] = [],
        residentTracker: ResidentLayerTracker? = nil
    ) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.srgbBlend = srgbBlend
        self.clearColor = clearColor
        self.glyphs = glyphs
        self.glyphGeneration = glyphGeneration
        self.images = images
        self.imageRevision = imageRevision
        self.instances = instances
        self.marks = marks
        self.surfaces = surfaces
        self.materials = materials
        self.residentTracker = residentTracker
    }
}
