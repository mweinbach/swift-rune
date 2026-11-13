import Foundation

/// Primitive shader kinds shared identically between `RuneRef` (CPU) and `MetalRenderer` (GPU).
public enum PrimitiveKind: Int, Sendable, Codable {
    case roundedRect = 0
    case dropShadow = 1
    case glyph = 2
    case insetShadow = 3
    case linearGradient = 4
    case segment = 5
    case triangle = 6
    case image = 7
    case layerBegin = 8
    case layerEnd = 9
    case dashedRing = 10
    case multiGradient = 11
    case backdropBlur = 12
    case effectSlot = 13
}

/// Device-pixel CPU oracle primitive instance (36 floats) used by `RuneRef` parity scenes.
public struct Primitive: Sendable, Equatable {
    /// Bounding quad `[x, y, w, h]` in device pixels (for `.triangle`, `[v2.x, v2.y, bboxW, bboxH]` or bbox with v2 in `fadeOrigin`).
    public var rect: SIMD4<Float>
    /// Corner radii `[topLeft, topRight, bottomRight, bottomLeft]` in device pixels (negative = continuous squircle).
    public var radii: SIMD4<Float>
    /// Primary color `[r, g, b, a]` (straight alpha).
    public var fill: SIMD4<Float>
    /// Secondary / border / end-stop color `[r, g, b, a]` (straight alpha).
    public var border: SIMD4<Float>
    /// `[param0, kind, param1, param2]`.
    public var params: SIMD4<Float>
    /// Atlas UV `[u0, v0, u1, v1]`, segment `[x0, y0, x1, y1]`, triangle `[x0, y0, x1, y1]`, or per-side borders.
    public var uv: SIMD4<Float>
    /// Scissor clip `[cx, cy, cw, ch]` in device pixels.
    public var clip: SIMD4<Float>
    /// Optional directional fade mask `[dirX, dirY, invSpan, minAlpha]` (`invSpan == 0` disables).
    public var fade: SIMD4<Float>
    /// Fade origin `[ox, oy]` (or triangle third vertex `[x2, y2]` when `kind == .triangle`).
    public var fadeOrigin: SIMD2<Float>
    /// Clockwise rotation in radians around quad center.
    public var turn: Float
    public var _pad: Float = 0

    public init(
        rect: SIMD4<Float>,
        radii: SIMD4<Float> = .zero,
        fill: SIMD4<Float> = .zero,
        border: SIMD4<Float> = .zero,
        params: SIMD4<Float> = .zero,
        uv: SIMD4<Float> = .zero,
        clip: SIMD4<Float>,
        fade: SIMD4<Float> = .zero,
        fadeOrigin: SIMD2<Float> = .zero,
        turn: Float = 0
    ) {
        self.rect = rect
        self.radii = radii
        self.fill = fill
        self.border = border
        self.params = params
        self.uv = uv
        self.clip = clip
        self.fade = fade
        self.fadeOrigin = fadeOrigin
        self.turn = turn
    }

    @inlinable
    public var kind: PrimitiveKind {
        PrimitiveKind(rawValue: Int(params.y.rounded())) ?? .roundedRect
    }

    // MARK: - Convenience Builders

    public static func roundedRect(
        rect: SIMD4<Float>,
        radii: SIMD4<Float> = .zero,
        fill: SIMD4<Float>,
        borderColor: SIMD4<Float> = .zero,
        borderWidth: Float = 0,
        borderSides: SIMD4<Float>? = nil,
        clip: SIMD4<Float>,
        turn: Float = 0
    ) -> Primitive {
        if let sides = borderSides, (sides.x > 0 || sides.y > 0 || sides.z > 0 || sides.w > 0) {
            return Primitive(
                rect: rect,
                radii: radii,
                fill: fill,
                border: borderColor,
                params: SIMD4<Float>(-1.0, Float(PrimitiveKind.roundedRect.rawValue), 0, 0),
                uv: sides,
                clip: clip,
                turn: turn
            )
        }
        return Primitive(
            rect: rect,
            radii: radii,
            fill: fill,
            border: borderColor,
            params: SIMD4<Float>(borderWidth, Float(PrimitiveKind.roundedRect.rawValue), 0, 0),
            clip: clip,
            turn: turn
        )
    }

    public static func dropShadow(
        rect: SIMD4<Float>,
        radii: SIMD4<Float> = .zero,
        color: SIMD4<Float>,
        blur: Float,
        spread: Float = 0,
        offset: SIMD2<Float> = .zero,
        cutoutInner: Bool = false,
        clip: SIMD4<Float>
    ) -> Primitive {
        let pad = max(blur * 3.0 + abs(spread) + 2.0, 2.0)
        let expanded = SIMD4<Float>(
            rect.x + offset.x - pad,
            rect.y + offset.y - pad,
            rect.z + pad * 2.0,
            rect.w + pad * 2.0
        )
        return Primitive(
            rect: expanded,
            radii: radii,
            fill: color,
            border: rect,
            params: SIMD4<Float>(blur, Float(PrimitiveKind.dropShadow.rawValue), spread, cutoutInner ? 1.0 : 0.0),
            uv: SIMD4<Float>(offset.x, offset.y, 0, 0),
            clip: clip
        )
    }

    public static func insetShadow(
        rect: SIMD4<Float>,
        radii: SIMD4<Float> = .zero,
        color: SIMD4<Float>,
        blur: Float,
        spread: Float = 0,
        offset: SIMD2<Float> = .zero,
        clip: SIMD4<Float>
    ) -> Primitive {
        Primitive(
            rect: rect,
            radii: radii,
            fill: color,
            params: SIMD4<Float>(blur, Float(PrimitiveKind.insetShadow.rawValue), spread, 0),
            uv: SIMD4<Float>(offset.x, offset.y, 0, 0),
            clip: clip
        )
    }

    public static func glyph(
        rect: SIMD4<Float>,
        uv: SIMD4<Float>,
        color: SIMD4<Float>,
        gamma: Float = 1.0,
        clip: SIMD4<Float>,
        turn: Float = 0
    ) -> Primitive {
        Primitive(
            rect: rect,
            fill: color,
            params: SIMD4<Float>(0, Float(PrimitiveKind.glyph.rawValue), 0, gamma),
            uv: uv,
            clip: clip,
            turn: turn
        )
    }

    public static func image(
        rect: SIMD4<Float>,
        radii: SIMD4<Float> = .zero,
        uv: SIMD4<Float>,
        tint: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
        clip: SIMD4<Float>,
        turn: Float = 0
    ) -> Primitive {
        Primitive(
            rect: rect,
            radii: radii,
            fill: tint,
            params: SIMD4<Float>(0, Float(PrimitiveKind.image.rawValue), 0, 0),
            uv: uv,
            clip: clip,
            turn: turn
        )
    }

    public static func linearGradient(
        rect: SIMD4<Float>,
        radii: SIMD4<Float> = .zero,
        topColor: SIMD4<Float>,
        bottomColor: SIMD4<Float>,
        angleRadians: Float = .pi * 0.5,
        borderWidth: Float = 0,
        clip: SIMD4<Float>,
        turn: Float = 0
    ) -> Primitive {
        Primitive(
            rect: rect,
            radii: radii,
            fill: topColor,
            border: bottomColor,
            params: SIMD4<Float>(borderWidth, Float(PrimitiveKind.linearGradient.rawValue), angleRadians, 0),
            clip: clip,
            turn: turn
        )
    }

    public static func segment(
        from a: SIMD2<Float>,
        to b: SIMD2<Float>,
        width: Float,
        color: SIMD4<Float>,
        roundCap: Bool = true,
        clip: SIMD4<Float>
    ) -> Primitive {
        let pad = width * 0.5 + 2.0
        let minX = min(a.x, b.x) - pad
        let minY = min(a.y, b.y) - pad
        let maxX = max(a.x, b.x) + pad
        let maxY = max(a.y, b.y) + pad
        return Primitive(
            rect: SIMD4<Float>(minX, minY, maxX - minX, maxY - minY),
            fill: color,
            params: SIMD4<Float>(width, Float(PrimitiveKind.segment.rawValue), roundCap ? 1.0 : 0.0, 0),
            uv: SIMD4<Float>(a.x, a.y, b.x, b.y),
            clip: clip
        )
    }

    public static func triangle(
        v0: SIMD2<Float>,
        v1: SIMD2<Float>,
        v2: SIMD2<Float>,
        aaMask: UInt8 = 0b111,
        color: SIMD4<Float>,
        clip: SIMD4<Float>
    ) -> Primitive {
        let minX = floorf(min(v0.x, min(v1.x, v2.x)) - 1.0)
        let minY = floorf(min(v0.y, min(v1.y, v2.y)) - 1.0)
        let maxX = ceilf(max(v0.x, max(v1.x, v2.x)) + 1.0)
        let maxY = ceilf(max(v0.y, max(v1.y, v2.y)) + 1.0)
        return Primitive(
            rect: SIMD4<Float>(minX, minY, max(1, maxX - minX), max(1, maxY - minY)),
            fill: color,
            params: SIMD4<Float>(Float(aaMask), Float(PrimitiveKind.triangle.rawValue), 0, 0),
            uv: SIMD4<Float>(v0.x, v0.y, v1.x, v1.y),
            clip: clip,
            fadeOrigin: v2
        )
    }

    public static func dashedRing(
        rect: SIMD4<Float>,
        radii: SIMD4<Float> = .zero,
        color: SIMD4<Float>,
        borderWidth: Float,
        dashLength: Float,
        gapLength: Float,
        phase: Float = 0,
        clip: SIMD4<Float>
    ) -> Primitive {
        Primitive(
            rect: rect,
            radii: radii,
            fill: color,
            params: SIMD4<Float>(borderWidth, Float(PrimitiveKind.dashedRing.rawValue), dashLength, gapLength),
            uv: SIMD4<Float>(phase, 0, 0, 0),
            clip: clip
        )
    }

    public static func radialGradient(
        rect: SIMD4<Float>,
        radii: SIMD4<Float> = .zero,
        innerColor: SIMD4<Float>,
        outerColor: SIMD4<Float>,
        center: SIMD2<Float>? = nil,
        clip: SIMD4<Float>
    ) -> Primitive {
        let c = center ?? SIMD2<Float>(rect.x + rect.z * 0.5, rect.y + rect.w * 0.5)
        return Primitive(
            rect: rect,
            radii: radii,
            fill: innerColor,
            border: outerColor,
            params: SIMD4<Float>(0, Float(PrimitiveKind.multiGradient.rawValue), 1.0, 0),
            uv: SIMD4<Float>(c.x, c.y, max(1, rect.z * 0.5), max(1, rect.w * 0.5)),
            clip: clip
        )
    }

    public static func layerBegin(
        rect: SIMD4<Float>,
        radii: SIMD4<Float> = .zero,
        opacity: Float = 1.0,
        additive: Bool = false,
        blurRadius: Float = 0,
        clip: SIMD4<Float>,
        fade: SIMD4<Float> = .zero,
        fadeOrigin: SIMD2<Float> = .zero,
        turn: Float = 0
    ) -> Primitive {
        Primitive(
            rect: rect,
            radii: radii,
            params: SIMD4<Float>(opacity, Float(PrimitiveKind.layerBegin.rawValue), additive ? 1.0 : 0.0, blurRadius),
            clip: clip,
            fade: fade,
            fadeOrigin: fadeOrigin,
            turn: turn
        )
    }

    public static func layerEnd(clip: SIMD4<Float>) -> Primitive {
        Primitive(
            rect: .zero,
            params: SIMD4<Float>(0, Float(PrimitiveKind.layerEnd.rawValue), 0, 0),
            clip: clip
        )
    }

    /// Effect slot placeholder (no-op in scalar reference).
    public static func effectSlot(
        rect: SIMD4<Float> = .zero,
        clip: SIMD4<Float> = SIMD4<Float>(-1e6, -1e6, 2e6, 2e6)
    ) -> Primitive {
        Primitive(
            rect: rect,
            params: SIMD4<Float>(0, Float(PrimitiveKind.effectSlot.rawValue), 0, 0),
            clip: clip
        )
    }
}

/// Single-channel R8 coverage atlas for glyphs and vector icons.
public struct R8Atlas: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var texels: [UInt8]

    public init(width: Int = 1, height: Int = 1, texels: [UInt8]? = nil) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.texels = texels ?? Array(repeating: 0, count: self.width * self.height)
    }
}

/// 4-channel straight RGBA8 image atlas.
public struct RGBA8Atlas: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var texels: [UInt8]

    public init(width: Int = 1, height: Int = 1, texels: [UInt8]? = nil) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.texels = texels ?? Array(repeating: 0, count: self.width * self.height * 4)
    }
}

public enum RefSceneError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidDimensions(width: Int, height: Int)
    case nonFiniteClearColor
    case invalidGlyphAtlasSize(expected: Int, actual: Int)
    case invalidImageAtlasSize(expected: Int, actual: Int)
    case nonFinitePrimitive(index: Int)
    case unbalancedLayerEnd(index: Int)
    case layerStackOverflow(index: Int, maxDepth: Int)
    case unclosedLayers(remaining: Int)

    public var description: String {
        switch self {
        case let .invalidDimensions(w, h):
            return "Invalid scene dimensions \(w)x\(h)"
        case .nonFiniteClearColor:
            return "Scene clearColor contains NaN or infinite float values"
        case let .invalidGlyphAtlasSize(exp, act):
            return "Glyph atlas byte count mismatch (expected \(exp), got \(act))"
        case let .invalidImageAtlasSize(exp, act):
            return "Image atlas byte count mismatch (expected \(exp), got \(act))"
        case let .nonFinitePrimitive(idx):
            return "Primitive at index \(idx) contains NaN or infinite float values"
        case let .unbalancedLayerEnd(idx):
            return "Unmatched layerEnd primitive at index \(idx)"
        case let .layerStackOverflow(idx, maxDepth):
            return "Layer nesting exceeded maximum depth \(maxDepth) at index \(idx)"
        case let .unclosedLayers(rem):
            return "Scene ended with \(rem) unclosed layerBegin scope(s)"
        }
    }
}

/// Complete device-pixel frame input for `RuneRef` and Metal differential verification.
public struct RefScene: Sendable, Equatable {
    public static let maxLayerDepth = 8

    public var width: Int
    public var height: Int
    /// When `false` (default on native Metal), primitives supply linear-light colors, blend in linear
    /// light, and gamma-encode to sRGB8 at final output. When `true`, blends directly in sRGB space.
    public var srgbBlend: Bool
    public var clearColor: SIMD4<Float>
    public var glyphs: R8Atlas
    public var images: RGBA8Atlas
    public var primitives: [Primitive]

    public init(
        width: Int,
        height: Int,
        srgbBlend: Bool = false,
        clearColor: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1),
        glyphs: R8Atlas = R8Atlas(),
        images: RGBA8Atlas = RGBA8Atlas(),
        primitives: [Primitive] = []
    ) {
        self.width = width
        self.height = height
        self.srgbBlend = srgbBlend
        self.clearColor = clearColor
        self.glyphs = glyphs
        self.images = images
        self.primitives = primitives
    }

    public func validate() throws(RefSceneError) {
        guard width > 0 && height > 0 && width <= 16384 && height <= 16384 else {
            throw .invalidDimensions(width: width, height: height)
        }
        guard Self.isFinite(clearColor) else {
            throw .nonFiniteClearColor
        }
        let expectedGlyphs = glyphs.width * glyphs.height
        if glyphs.texels.count != expectedGlyphs {
            throw .invalidGlyphAtlasSize(expected: expectedGlyphs, actual: glyphs.texels.count)
        }
        let expectedImages = images.width * images.height * 4
        if images.texels.count != expectedImages {
            throw .invalidImageAtlasSize(expected: expectedImages, actual: images.texels.count)
        }
        var depth = 0
        for (i, p) in primitives.enumerated() {
            if !Self.isFinite(p.rect) || !Self.isFinite(p.radii) || !Self.isFinite(p.fill)
                || !Self.isFinite(p.border) || !Self.isFinite(p.params) || !Self.isFinite(p.uv)
                || !Self.isFinite(p.clip) || !Self.isFinite(p.fade)
                || !p.fadeOrigin.x.isFinite || !p.fadeOrigin.y.isFinite || !p.turn.isFinite {
                throw .nonFinitePrimitive(index: i)
            }
            switch p.kind {
            case .layerBegin:
                depth += 1
                if depth > Self.maxLayerDepth {
                    throw .layerStackOverflow(index: i, maxDepth: Self.maxLayerDepth)
                }
            case .layerEnd:
                if depth == 0 {
                    throw .unbalancedLayerEnd(index: i)
                }
                depth -= 1
            default:
                break
            }
        }
        if depth != 0 {
            throw .unclosedLayers(remaining: depth)
        }
    }

    @inlinable
    static func isFinite(_ v: SIMD4<Float>) -> Bool {
        v.x.isFinite && v.y.isFinite && v.z.isFinite && v.w.isFinite
    }
}
