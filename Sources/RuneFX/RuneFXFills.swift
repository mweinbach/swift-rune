import Foundation

public let maxStops = 6

public struct Stops: Sendable, Equatable, Hashable {
    public private(set) var colors: [Rgb]

    public init(_ colors: [Rgb]) {
        if colors.isEmpty {
            self.colors = [Rgb(0, 0, 0)]
        } else {
            self.colors = Array(colors.prefix(maxStops))
        }
    }

    public static func hex(_ values: [UInt32]) -> Stops {
        Stops(values.map { rgb($0) })
    }

    public var count: Int { colors.count }
}

/// Linear sRGB to OKLab.
public func oklab(_ c: Rgb) -> SIMD3<Float> {
    let l = 0.412_221_46 * c.r + 0.536_332_55 * c.g + 0.051_445_995 * c.b
    let m = 0.211_903_5 * c.r + 0.680_699_5 * c.g + 0.107_396_96 * c.b
    let s = 0.088_302_46 * c.r + 0.281_718_85 * c.g + 0.629_978_7 * c.b
    let lc = cbrtf(max(l, 0.0))
    let mc = cbrtf(max(m, 0.0))
    let sc = cbrtf(max(s, 0.0))
    return SIMD3<Float>(
        0.210_454_26 * lc + 0.793_617_8 * mc - 0.004_072_047 * sc,
        1.977_998_5 * lc - 2.428_592_2 * mc + 0.450_593_7 * sc,
        0.025_904_037 * lc + 0.782_771_77 * mc - 0.808_675_77 * sc
    )
}

public enum FillInput: Sendable, Equatable, Hashable {
    case linear
    case radial
    case noise
    case backdrop
    case image

    internal var code: Float {
        switch self {
        case .linear: return 0.0
        case .radial: return 1.0
        case .noise: return 2.0
        case .backdrop: return 3.0
        case .image: return 4.0
        }
    }

    internal var animates: Bool { self == .noise }
}

public enum DitherPattern: Sendable, Equatable, Hashable {
    case bayer2
    case bayer4
    case bayer8
    case blueNoise
    case white
}

public enum GradientKind: Sendable, Equatable, Hashable {
    case linear
    case radial
    case conic
}

public enum FillAnchor: Sendable, Equatable, Hashable {
    case world
    case element
}

public struct LiquidMetalParams: Sendable, Equatable {
    public var tint: Rgb
    public var light: Rgb
    public var flow: Float
    public var scale: Float
    public var speed: Float
    public var bevel: Float
    public var dome: Float
    public var angle: Float
    public var iridescence: Float
    public var contrast: Float
    public var anchor: FillAnchor

    public init(
        tint: Rgb = rgb(0xe9ecf0),
        light: Rgb = rgb(0xffffff),
        flow: Float = 0.6,
        scale: Float = 100.0,
        speed: Float = 0.35,
        bevel: Float = 14.0,
        dome: Float = 0.55,
        angle: Float = -0.12,
        iridescence: Float = 0.08,
        contrast: Float = 1.0,
        anchor: FillAnchor = .world
    ) {
        self.tint = tint
        self.light = light
        self.flow = flow
        self.scale = scale
        self.speed = speed
        self.bevel = bevel
        self.dome = dome
        self.angle = angle
        self.iridescence = iridescence
        self.contrast = contrast
        self.anchor = anchor
    }

    public static func chrome() -> LiquidMetalParams { LiquidMetalParams() }
    public static func gold() -> LiquidMetalParams { LiquidMetalParams(tint: rgb(0xf3c56b), light: rgb(0xfff4dc), iridescence: 0.0) }
    public static func rose() -> LiquidMetalParams { LiquidMetalParams(tint: rgb(0xf2b7a2), light: rgb(0xfff0ea), iridescence: 0.05) }
    public static func gunmetal() -> LiquidMetalParams { LiquidMetalParams(tint: rgb(0x8d949e), light: rgb(0xe8f0ff), iridescence: 0.12, contrast: 1.35) }
}

public struct PlasticParams: Sendable, Equatable {
    public var color: Rgb
    public var roughness: Float
    public var dome: Float
    public var bevel: Float
    public var angle: Float

    public init(color: Rgb = rgb(0xece8de), roughness: Float = 0.15, dome: Float = 0.35, bevel: Float = 6.0, angle: Float = -0.5) {
        self.color = color
        self.roughness = roughness
        self.dome = dome
        self.bevel = bevel
        self.angle = angle
    }

    public static func glossy() -> PlasticParams { PlasticParams() }
    public static func matte() -> PlasticParams { PlasticParams(color: rgb(0x2e3036), roughness: 0.8) }
    public static func dished() -> PlasticParams { PlasticParams(color: rgb(0xd8d2c4), roughness: 0.7, dome: -0.45) }
}

public struct MeshGradientParams: Sendable, Equatable {
    public static let defaultPoints: [SIMD2<Float>] = [
        SIMD2<Float>(0.12, 0.18),
        SIMD2<Float>(0.86, 0.12),
        SIMD2<Float>(0.5, 0.55),
        SIMD2<Float>(0.14, 0.9),
        SIMD2<Float>(0.9, 0.86),
        SIMD2<Float>(0.62, 0.3),
    ]

    public var colors: Stops
    public var points: [SIMD2<Float>]
    public var drift: Float
    public var speed: Float
    public var sharpness: Float
    public var warp: Float

    public init(
        colors: Stops = Stops.hex([0x2b1b5a, 0xff6f91, 0xffc46b, 0x6a4cff, 0xff9a5a]),
        points: [SIMD2<Float>] = MeshGradientParams.defaultPoints,
        drift: Float = 0.12,
        speed: Float = 0.25,
        sharpness: Float = 1.6,
        warp: Float = 0.35
    ) {
        self.colors = colors
        self.points = points
        self.drift = drift
        self.speed = speed
        self.sharpness = sharpness
        self.warp = warp
    }

    public static func dusk() -> MeshGradientParams { MeshGradientParams() }
    public static func lagoon() -> MeshGradientParams { MeshGradientParams(colors: Stops.hex([0x0b3d5c, 0x2ec4b6, 0xcbf3f0, 0x1b6ca8])) }
    public static func orchid() -> MeshGradientParams { MeshGradientParams(colors: Stops.hex([0xf9d5e5, 0xc06c84, 0x6c5b7b, 0xf8b195, 0x355c7d, 0xeeac99]), sharpness: 2.0) }
    public static func graphite() -> MeshGradientParams { MeshGradientParams(colors: Stops.hex([0x15171c, 0x3a3f4b, 0x8a93a3, 0x22262e]), drift: 0.08, warp: 0.2) }
}

public struct DitherParams: Sendable, Equatable {
    public var pattern: DitherPattern
    public var input: FillInput
    public var colors: Stops
    public var pixel: Float
    public var angle: Float
    public var scale: Float
    public var speed: Float
    public var bias: Float
    public var contrast: Float

    public init(
        pattern: DitherPattern = .bayer4,
        input: FillInput = .linear,
        colors: Stops = Stops.hex([0x14161c, 0xe8e4d8]),
        pixel: Float = 2.0,
        angle: Float = 0.6,
        scale: Float = 90.0,
        speed: Float = 0.2,
        bias: Float = 0.0,
        contrast: Float = 1.0
    ) {
        self.pattern = pattern
        self.input = input
        self.colors = colors
        self.pixel = pixel
        self.angle = angle
        self.scale = scale
        self.speed = speed
        self.bias = bias
        self.contrast = contrast
    }

    public static func bayer() -> DitherParams { DitherParams() }
    public static func handheld() -> DitherParams { DitherParams(pattern: .bayer8, input: .noise, colors: Stops.hex([0x0f380f, 0x306230, 0x8bac0f, 0x9bbc0f]), pixel: 3.0) }
    public static func grain() -> DitherParams { DitherParams(pattern: .blueNoise, input: .radial, colors: Stops.hex([0x1b1530, 0xffd7a8]), pixel: 1.0) }
    public static func backdrop() -> DitherParams { DitherParams(pattern: .bayer4, input: .backdrop, colors: Stops.hex([0x101418, 0xf2efe6]), pixel: 2.0, bias: -0.1, contrast: 1.35) }
}

public struct GrainGradientParams: Sendable, Equatable {
    public var kind: GradientKind
    public var colors: Stops
    public var angle: Float
    public var center: SIMD2<Float>
    public var amount: Float
    public var size: Float
    public var mono: Bool
    public var fps: Float

    public init(
        kind: GradientKind = .linear,
        colors: Stops = Stops.hex([0x1a0b2e, 0xc2185b, 0xff8a3d, 0xffe1a8]),
        angle: Float = 1.2,
        center: SIMD2<Float> = SIMD2<Float>(0.5, 0.5),
        amount: Float = 0.4,
        size: Float = 0.5,
        mono: Bool = true,
        fps: Float = 12.0
    ) {
        self.kind = kind
        self.colors = colors
        self.angle = angle
        self.center = center
        self.amount = amount
        self.size = size
        self.mono = mono
        self.fps = fps
    }

    public static func ember() -> GrainGradientParams { GrainGradientParams() }
    public static func halo() -> GrainGradientParams { GrainGradientParams(kind: .radial, colors: Stops.hex([0xe9f1ff, 0x7aa2ff, 0x2a2f7a, 0x0b0d1f]), center: SIMD2<Float>(0.5, 0.35)) }
    public static func sweep() -> GrainGradientParams { GrainGradientParams(kind: .conic, colors: Stops.hex([0x00c2a8, 0x3a86ff, 0x8338ec, 0xff006e, 0xffbe0b]), angle: -1.57, mono: false) }
}

public struct FlutedGlassParams: Sendable, Equatable {
    public var rib: Float
    public var angle: Float
    public var refraction: Float
    public var frost: Float
    public var dispersion: Float
    public var highlight: Float
    public var tint: Rgb
    public var tintAmount: Float

    public init(
        rib: Float = 14.0,
        angle: Float = 0.0,
        refraction: Float = 9.0,
        frost: Float = 0.0,
        dispersion: Float = 0.15,
        highlight: Float = 0.5,
        tint: Rgb = rgb(0xffffff),
        tintAmount: Float = 0.0
    ) {
        self.rib = rib
        self.angle = angle
        self.refraction = refraction
        self.frost = frost
        self.dispersion = dispersion
        self.highlight = highlight
        self.tint = tint
        self.tintAmount = tintAmount
    }

    public static func reeded() -> FlutedGlassParams { FlutedGlassParams() }
    public static func fine() -> FlutedGlassParams { FlutedGlassParams(rib: 6.0, refraction: 5.0) }
    public static func frosted() -> FlutedGlassParams { FlutedGlassParams(frost: 0.6) }
    public static func wide() -> FlutedGlassParams { FlutedGlassParams(rib: 32.0, refraction: 18.0, dispersion: 0.25) }
}

public struct MetaballParams: Sendable, Equatable {
    public var colors: Stops
    public var base: Rgb
    public var count: UInt32
    public var size: Float
    public var speed: Float
    public var gloss: Float

    public init(
        colors: Stops = Stops.hex([0xff5e3a, 0xff9a3c, 0xff2d6f]),
        base: Rgb = rgb(0x1a0f1f),
        count: UInt32 = 6,
        size: Float = 0.2,
        speed: Float = 0.4,
        gloss: Float = 0.5
    ) {
        self.colors = colors
        self.base = base
        self.count = count
        self.size = size
        self.speed = speed
        self.gloss = gloss
    }

    public static func lava() -> MetaballParams { MetaballParams() }
    public static func mint() -> MetaballParams { MetaballParams(colors: Stops.hex([0x7cf2c4, 0x37d0e8, 0xb8f36b]), base: rgb(0x0d1b1e)) }
}

public struct SwirlParams: Sendable, Equatable {
    public var colors: Stops
    public var scale: Float
    public var speed: Float
    public var twist: Float
    public var warp: Float

    public init(
        colors: Stops = Stops.hex([0x0b1026, 0x3b2c85, 0x2fb3c9, 0xf2f6ff]),
        scale: Float = 140.0,
        speed: Float = 0.2,
        twist: Float = 0.6,
        warp: Float = 1.0
    ) {
        self.colors = colors
        self.scale = scale
        self.speed = speed
        self.twist = twist
        self.warp = warp
    }

    public static func ink() -> SwirlParams { SwirlParams() }
    public static func marble() -> SwirlParams { SwirlParams(colors: Stops.hex([0xf4f1ea, 0xc9c2b4, 0x6f6a61, 0xf4f1ea]), scale: 90.0, twist: 0.3, warp: 1.6) }
}

public struct VoronoiParams: Sendable, Equatable {
    public var colors: Stops
    public var edgeColor: Rgb
    public var scale: Float
    public var speed: Float
    public var edge: Float
    public var depth: Float

    public init(
        colors: Stops = Stops.hex([0x1f2a44, 0x2c3e66, 0x3d5a8a, 0x5577b0]),
        edgeColor: Rgb = rgb(0x0b0f1a),
        scale: Float = 36.0,
        speed: Float = 0.25,
        edge: Float = 1.5,
        depth: Float = 0.4
    ) {
        self.colors = colors
        self.edgeColor = edgeColor
        self.scale = scale
        self.speed = speed
        self.edge = edge
        self.depth = depth
    }

    public static func cells() -> VoronoiParams { VoronoiParams() }
    public static func stained() -> VoronoiParams { VoronoiParams(colors: Stops.hex([0xd7263d, 0xf46036, 0x2e294e, 0x1b998b, 0xc5d86d]), edgeColor: rgb(0x111111), scale: 20.0, edge: 2.0, depth: 0.25) }
}

public struct WaveParams: Sendable, Equatable {
    public var colors: Stops
    public var amplitude: Float
    public var frequency: Float
    public var speed: Float
    public var angle: Float
    public var softness: Float

    public init(
        colors: Stops = Stops.hex([0xbfe7ff, 0x5fb3e8, 0x2a7bbf, 0x154a85, 0x0a2649]),
        amplitude: Float = 0.05,
        frequency: Float = 1.6,
        speed: Float = 0.4,
        angle: Float = 0.0,
        softness: Float = 0.006
    ) {
        self.colors = colors
        self.amplitude = amplitude
        self.frequency = frequency
        self.speed = speed
        self.angle = angle
        self.softness = softness
    }

    public static func sea() -> WaveParams { WaveParams() }
    public static func dunes() -> WaveParams { WaveParams(colors: Stops.hex([0xfde6c4, 0xf4b77c, 0xe08a4f, 0xb35a3a, 0x6e3226]), amplitude: 0.07, frequency: 1.1, speed: 0.15) }
}

public struct HalftoneParams: Sendable, Equatable {
    public var input: FillInput
    public var ink: Rgb
    public var base: Rgb
    public var cell: Float
    public var angle: Float
    public var rampAngle: Float
    public var scale: Float
    public var speed: Float
    public var bias: Float
    public var contrast: Float

    public init(
        input: FillInput = .radial,
        ink: Rgb = rgb(0x1b1b1f),
        base: Rgb = rgb(0xf1ece1),
        cell: Float = 6.0,
        angle: Float = 0.785,
        rampAngle: Float = 0.6,
        scale: Float = 90.0,
        speed: Float = 0.2,
        bias: Float = 0.0,
        contrast: Float = 1.0
    ) {
        self.input = input
        self.ink = ink
        self.base = base
        self.cell = cell
        self.angle = angle
        self.rampAngle = rampAngle
        self.scale = scale
        self.speed = speed
        self.bias = bias
        self.contrast = contrast
    }

    public static func print() -> HalftoneParams { HalftoneParams() }
    public static func backdrop() -> HalftoneParams { HalftoneParams(input: .backdrop, cell: 4.0) }
}

public enum FillStyle: Sendable, Equatable {
    case liquidMetal(LiquidMetalParams)
    case meshGradient(MeshGradientParams)
    case dither(DitherParams)
    case grainGradient(GrainGradientParams)
    case flutedGlass(FlutedGlassParams)
    case metaballs(MetaballParams)
    case swirl(SwirlParams)
    case voronoi(VoronoiParams)
    case waves(WaveParams)
    case halftone(HalftoneParams)
    case plastic(PlasticParams)

    internal var index: Int {
        switch self {
        case .liquidMetal: return 0
        case .meshGradient: return 1
        case .dither: return 2
        case .grainGradient: return 3
        case .flutedGlass: return 4
        case .metaballs: return 5
        case .swirl: return 6
        case .voronoi: return 7
        case .waves: return 8
        case .halftone: return 9
        case .plastic: return 10
        }
    }
}

public struct FillParams: Sendable, Equatable {
    public var style: FillStyle
    public var border: Float
    public var intensity: Float

    public init(_ style: FillStyle, border: Float = 0.0, intensity: Float = 1.0) {
        self.style = style
        self.border = border
        self.intensity = intensity
    }

    public func border(_ width: Float) -> FillParams { var copy = self; copy.border = width; return copy }
    public func intensity(_ k: Float) -> FillParams { var copy = self; copy.intensity = k; return copy }

    public var needsBackdrop: Bool {
        switch style {
        case .flutedGlass: return true
        case .dither(let p): return p.input == .backdrop
        case .halftone(let p): return p.input == .backdrop
        default: return false
        }
    }

    public var needsSource: Bool {
        switch style {
        case .dither(let p): return p.input == .image
        case .halftone(let p): return p.input == .image
        default: return false
        }
    }

    public var animates: Bool {
        switch style {
        case .liquidMetal(let p): return p.speed > 0 && p.flow > 0
        case .meshGradient(let p): return p.speed > 0 && (p.drift > 0 || p.warp > 0)
        case .dither(let p): return p.input.animates && p.speed > 0
        case .grainGradient(let p): return p.fps > 0 && p.amount > 0
        case .flutedGlass: return false
        case .metaballs(let p): return p.speed > 0
        case .swirl(let p): return p.speed > 0
        case .voronoi(let p): return p.speed > 0
        case .waves(let p): return p.speed > 0 && p.amplitude > 0
        case .halftone(let p): return p.input.animates && p.speed > 0
        case .plastic: return false
        }
    }

    public var cost: FxCost {
        let ramp: UInt32 = 2
        func inputCost(_ inp: FillInput) -> (UInt32, UInt32) {
            switch inp {
            case .noise: return (0, 3)
            case .backdrop, .image: return (1, 0)
            default: return (0, 0)
            }
        }
        let (samples, alu): (UInt32, UInt32) = switch style {
        case .liquidMetal(let p): (0, p.flow > 0 ? 8 : 0)
        case .meshGradient(let p): (UInt32(p.colors.count) * 2, p.warp > 0 ? 2 : 0)
        case .dither(let p):
            {
                let (s, a) = inputCost(p.input)
                return (s + 1 + (p.pattern == .blueNoise ? 1 : 0), a)
            }()
        case .grainGradient: (ramp, 0)
        case .flutedGlass(let p): (p.frost > 0 ? 6 : 3, 0)
        case .metaballs(let p): (min(max(p.count, 1), 8) * 2, 0)
        case .swirl: (ramp, 9)
        case .voronoi: (1, 0)
        case .waves(let p): (UInt32(p.colors.count), 0)
        case .halftone(let p):
            {
                let (s, a) = inputCost(p.input)
                return (s * 4, a * 4)
            }()
        case .plastic: (0, 0)
        }
        return FxCost(passes: 1, samples: samples, alu: alu, backdrop: needsBackdrop, source: needsSource)
    }

    internal func drawsNothing(in r: FxRect) -> Bool {
        !(intensity > 0.0) || !(border.isFinite && border >= 0.0) || !(r.w > 0.0) || !(r.h > 0.0)
    }

    internal func pack(into i: inout FxInstRaw, reducedMotion rm: Bool, time: Float) -> FxRect? {
        let r = FxRect(x: i.rect.x, y: i.rect.y, w: i.rect.z, h: i.rect.w)
        if drawsNothing(in: r) { return nil }
        func fin(_ x: Float, _ d: Float) -> Float { x.isFinite ? x : d }

        i.t.x = rm ? FxPackConstants.calmT : RuneFXCPU.foldT(time)
        i.t.z = Float(style.index)
        i.aux = SIMD4<Float>(border, min(intensity, 1.0), 0.0, 0.0)

        switch style {
        case .liquidMetal(let p):
            i.c0 = p.tint.v4
            i.c1 = p.light.v4
            i.p0 = SIMD4<Float>(max(fin(p.flow, 0.0), 0.0), max(fin(p.scale, 100.0), 1.0), fin(p.speed, 0.0), max(fin(p.bevel, 0.0), 0.0))
            i.p1 = SIMD4<Float>(fin(p.dome, 0.0), fin(p.angle, 0.0), max(fin(p.iridescence, 0.0), 0.0), max(fin(p.contrast, 1.0), 0.1))
            i.p2 = SIMD4<Float>(p.anchor == .element ? 1.0 : 0.0, 0.0, 0.0, 0.0)
        case .meshGradient(let p):
            i.p0 = SIMD4<Float>(p.drift, p.speed, min(max(p.sharpness, 0.1), 8.0), p.warp)
        case .dither(let p):
            let pat: Float = switch p.pattern {
            case .bayer2: 1.0
            case .bayer4: 2.0
            case .bayer8: 3.0
            case .blueNoise: 4.0
            case .white: 5.0
            }
            i.p0 = SIMD4<Float>(pat, p.input.code, max(p.pixel, 0.25), p.angle)
            i.p1 = SIMD4<Float>(max(p.scale, 1.0), p.speed, p.bias, p.contrast)
        case .grainGradient(let p):
            let kind: Float = switch p.kind {
            case .linear: 0.0
            case .radial: 1.0
            case .conic: 2.0
            }
            i.p0 = SIMD4<Float>(kind, p.angle, p.center.x, p.center.y)
            i.p1 = SIMD4<Float>(p.amount, max(p.size, 0.25), p.mono ? 1.0 : 0.0, rm ? 0.0 : p.fps)
        case .flutedGlass(let p):
            i.c0 = p.tint.v4
            i.p0 = SIMD4<Float>(max(p.rib, 1.0), p.angle, p.refraction, p.frost)
            i.p1 = SIMD4<Float>(p.dispersion, p.highlight, p.tintAmount, 0.0)
        case .metaballs(let p):
            i.c0 = p.base.v4
            i.p0 = SIMD4<Float>(Float(min(max(p.count, 1), 8)), p.size, p.speed, p.gloss)
        case .swirl(let p):
            i.p0 = SIMD4<Float>(max(p.scale, 1.0), p.speed, p.twist, p.warp)
        case .voronoi(let p):
            i.c0 = p.edgeColor.v4
            i.p0 = SIMD4<Float>(max(p.scale, 2.0), p.speed, p.edge, p.depth)
        case .waves(let p):
            i.p0 = SIMD4<Float>(p.amplitude, p.frequency, p.speed, p.angle)
            i.p1 = SIMD4<Float>(p.softness, 0.0, 0.0, 0.0)
        case .halftone(let p):
            i.c0 = p.ink.v4
            i.c1 = p.base.v4
            i.p0 = SIMD4<Float>(0.0, p.input.code, max(p.cell, 1.0), p.rampAngle)
            i.p1 = SIMD4<Float>(max(p.scale, 1.0), p.speed, p.bias, p.contrast)
            i.p2 = SIMD4<Float>(p.angle, 0.0, 0.0, 0.0)
        case .plastic(let p):
            i.c0 = p.color.v4
            i.p0 = SIMD4<Float>(min(max(fin(p.roughness, 0.15), 0.0), 1.0), fin(p.dome, 0.0), max(fin(p.bevel, 0.0), 0.0), fin(p.angle, 0.0))
        }
        return r.inflate(1.0)
    }

    internal func fillTables(into i: inout FxInstRaw, shape: FxShape, time: Float, seed: UInt32, reducedMotion: Bool, data: inout [SIMD4<Float>]) {
        func pushStops(_ s: Stops, points: [SIMD2<Float>]?) -> (Float, Float) {
            let first = Float(data.count)
            for (k, c) in s.colors.enumerated() {
                let pt = (points != nil && k < points!.count) ? points![k] : .zero
                let l = oklab(c)
                data.append(SIMD4<Float>(c.r, c.g, c.b, pt.x))
                data.append(SIMD4<Float>(l.x, l.y, l.z, pt.y))
            }
            return (first, Float(s.count))
        }

        let (f, n): (Float, Float)
        switch style {
        case .meshGradient(let p):
            let pts = RuneFXCPU.meshPoints(p, time: time, seed: seed)
            (f, n) = pushStops(p.colors, points: pts)
        case .dither(let p):
            (f, n) = pushStops(p.colors, points: nil)
        case .grainGradient(let p):
            (f, n) = pushStops(p.colors, points: nil)
        case .metaballs(let p):
            (f, n) = pushStops(p.colors, points: nil)
        case .swirl(let p):
            (f, n) = pushStops(p.colors, points: nil)
        case .voronoi(let p):
            (f, n) = pushStops(p.colors, points: nil)
        case .waves(let p):
            (f, n) = pushStops(p.colors, points: nil)
        default:
            return
        }

        i.xf = SIMD4<Float>(f, n, 0.0, 0.0)
        switch style {
        case .dither(let p) where p.pattern == .blueNoise:
            i.xf.z = Float(data.count)
            i.xf.w = Float(RuneFXCPU.blueN)
            data.append(contentsOf: RuneFXCPU.blueNoiseTile)
        case .metaballs(let p):
            i.xf.z = Float(data.count)
            i.xf.w = Float(min(max(p.count, 1), 8))
            RuneFXCPU.metaballs(p, rect: shape.rect, time: time, seed: seed, data: &data)
        default:
            break
        }
    }
}
