import Foundation
import RuneMotion

// MARK: - Knobs

public struct Knob: Sendable, Equatable {
    public let name: String
    public let min: Float
    public let max: Float
    public let `default`: Float

    public init(name: String, min: Float, max: Float, default: Float) {
        self.name = name
        self.min = min
        self.max = max
        self.default = `default`
    }
}

// MARK: - Glow

public enum GlowStyle: Sendable, Equatable {
    case soft
    case neon
    case aura
    case mask
}

public struct GlowParams: Sendable, Equatable {
    public var style: GlowStyle
    public var color: Rgb
    public var core: Rgb
    public var third: Rgb
    public var radius: Float
    public var intensity: Float
    public var inner: Float
    public var occlusion: Float
    public var breathe: Float
    public var breathePeriod: Float
    public var heat: Float
    public var hot: Float
    public var auraSpeed: Float
    public var rimWidth: Float
    public var reach: Float

    public init(
        style: GlowStyle = .soft,
        color: Rgb = rgb(0x7c5cff),
        core: Rgb = rgb(0xf4f0ff),
        third: Rgb = rgb(0x22d3ee),
        radius: Float = 14.0,
        intensity: Float = 1.0,
        inner: Float = 0.0,
        occlusion: Float = 0.15,
        breathe: Float = 0.0,
        breathePeriod: Float = 2.6,
        heat: Float = 1.0,
        hot: Float = 0.6,
        auraSpeed: Float = 0.12,
        rimWidth: Float = 0.6,
        reach: Float = 4.5
    ) {
        self.style = style
        self.color = color
        self.core = core
        self.third = third
        self.radius = radius
        self.intensity = intensity
        self.inner = inner
        self.occlusion = occlusion
        self.breathe = breathe
        self.breathePeriod = breathePeriod
        self.heat = heat
        self.hot = hot
        self.auraSpeed = auraSpeed
        self.rimWidth = rimWidth
        self.reach = reach
    }

    public static let knobs: [Knob] = [
        Knob(name: "radius", min: 1.0, max: 64.0, default: 14.0),
        Knob(name: "intensity", min: 0.0, max: 3.0, default: 1.0),
        Knob(name: "inner", min: 0.0, max: 1.0, default: 0.0),
        Knob(name: "occlusion", min: 0.0, max: 1.0, default: 0.15),
        Knob(name: "breathe", min: 0.0, max: 1.0, default: 0.0),
        Knob(name: "breathe_period", min: 0.4, max: 8.0, default: 2.6),
        Knob(name: "heat", min: 0.0, max: 1.0, default: 1.0),
        Knob(name: "hot", min: 0.0, max: 1.0, default: 0.6),
        Knob(name: "aura_speed", min: 0.0, max: 1.0, default: 0.12),
        Knob(name: "rim_width", min: 0.2, max: 3.0, default: 0.6),
        Knob(name: "reach", min: 2.0, max: 8.0, default: 4.5),
    ]
}

// MARK: - Pulse

public enum PulseStyle: Sendable, Equatable {
    case radar
    case breathe
    case heartbeat
    case ping(from: SIMD2<Float>, dir: SIMD2<Float>, travel: Float)
    case ripple(at: SIMD2<Float>)
}

public struct PulseParams: Sendable, Equatable {
    public var style: PulseStyle
    public var color: Rgb
    public var core: Rgb
    public var count: UInt32
    public var period: Float
    public var reach: Float
    public var width: Float
    public var intensity: Float
    public var t0: Float
    public var duration: Float
    public var repeatInterval: Float
    public var lag: Float
    public var headRadius: Float
    public var occlusion: Float

    public init(
        style: PulseStyle = .radar,
        color: Rgb = rgb(0x3b82f6),
        core: Rgb = rgb(0xe8f1ff),
        count: UInt32 = 3,
        period: Float = 2.4,
        reach: Float = 36.0,
        width: Float = 1.6,
        intensity: Float = 1.0,
        t0: Float = 0.0,
        duration: Float = 0.75,
        repeatInterval: Float = 0.0,
        lag: Float = 0.16,
        headRadius: Float = 2.6,
        occlusion: Float = 0.15
    ) {
        self.style = style
        self.color = color
        self.core = core
        self.count = count
        self.period = period
        self.reach = reach
        self.width = width
        self.intensity = intensity
        self.t0 = t0
        self.duration = duration
        self.repeatInterval = repeatInterval
        self.lag = lag
        self.headRadius = headRadius
        self.occlusion = occlusion
    }

    public static let knobs: [Knob] = [
        Knob(name: "count", min: 1.0, max: 6.0, default: 3.0),
        Knob(name: "period", min: 0.3, max: 6.0, default: 2.4),
        Knob(name: "reach", min: 4.0, max: 200.0, default: 36.0),
        Knob(name: "width", min: 0.3, max: 8.0, default: 1.6),
        Knob(name: "intensity", min: 0.0, max: 3.0, default: 1.0),
        Knob(name: "duration", min: 0.1, max: 3.0, default: 0.75),
        Knob(name: "repeat", min: 0.0, max: 6.0, default: 0.0),
        Knob(name: "lag", min: 0.02, max: 0.5, default: 0.16),
        Knob(name: "head_radius", min: 0.5, max: 12.0, default: 2.6),
        Knob(name: "occlusion", min: 0.0, max: 1.0, default: 0.15),
    ]
}

// MARK: - Electric

public enum ElectricStyle: Sendable, Equatable {
    case arc(a: SIMD2<Float>, b: SIMD2<Float>)
    case border
    case charged
}

public struct ElectricParams: Sendable, Equatable {
    public static let zapLife: Float = 0.5

    public var style: ElectricStyle
    public var color: Rgb
    public var core: Rgb
    public var cool: Rgb
    public var amplitude: Float
    public var frequency: Float
    public var speed: Float
    public var coreWidth: Float
    public var intensity: Float
    public var glow: Float
    public var forks: Float
    public var flicker: Float
    public var strands: UInt32
    public var gap: Float
    public var forkLen: Float
    public var occlusion: Float
    public var zap: Float?

    public init(
        style: ElectricStyle = .border,
        color: Rgb = rgb(0x4f8dff),
        core: Rgb = rgb(0xeaf3ff),
        cool: Rgb = rgb(0x7a4dff),
        amplitude: Float = 5.0,
        frequency: Float = 2.4,
        speed: Float = 3.2,
        coreWidth: Float = 0.6,
        intensity: Float = 1.0,
        glow: Float = 5.0,
        forks: Float = 0.55,
        flicker: Float = 0.45,
        strands: UInt32 = 2,
        gap: Float = 2.0,
        forkLen: Float = 20.0,
        occlusion: Float = 0.12,
        zap: Float? = nil
    ) {
        self.style = style
        self.color = color
        self.core = core
        self.cool = cool
        self.amplitude = amplitude
        self.frequency = frequency
        self.speed = speed
        self.coreWidth = coreWidth
        self.intensity = intensity
        self.glow = glow
        self.forks = forks
        self.flicker = flicker
        self.strands = strands
        self.gap = gap
        self.forkLen = forkLen
        self.occlusion = occlusion
        self.zap = zap
    }

    public static func charged() -> ElectricParams {
        ElectricParams(
            style: .charged,
            amplitude: 1.1,
            frequency: 3.0,
            speed: 2.0,
            coreWidth: 0.5,
            intensity: 0.9,
            glow: 4.0,
            forks: 0.25,
            flicker: 0.0,
            strands: 1,
            gap: 0.5,
            forkLen: 14.0
        )
    }

    public static let knobs: [Knob] = [
        Knob(name: "amplitude", min: 0.0, max: 24.0, default: 5.0),
        Knob(name: "frequency", min: 0.5, max: 8.0, default: 2.4),
        Knob(name: "speed", min: 0.0, max: 10.0, default: 3.2),
        Knob(name: "core_width", min: 0.2, max: 3.0, default: 0.6),
        Knob(name: "intensity", min: 0.0, max: 3.0, default: 1.0),
        Knob(name: "glow", min: 1.0, max: 20.0, default: 5.0),
        Knob(name: "forks", min: 0.0, max: 1.0, default: 0.55),
        Knob(name: "flicker", min: 0.0, max: 1.0, default: 0.45),
        Knob(name: "strands", min: 1.0, max: 3.0, default: 2.0),
        Knob(name: "gap", min: -6.0, max: 12.0, default: 2.0),
        Knob(name: "fork_len", min: 2.0, max: 60.0, default: 20.0),
        Knob(name: "occlusion", min: 0.0, max: 1.0, default: 0.12),
    ]
}

// MARK: - Fire

public enum FireStyle: Sendable, Equatable {
    case top
    case border
    case heat
    case embers
}

public struct FireParams: Sendable, Equatable {
    public var style: FireStyle
    public var low: Rgb
    public var mid: Rgb
    public var hot: Rgb
    public var height: Float
    public var scale: Float
    public var speed: Float
    public var intensity: Float
    public var embers: UInt32
    public var emberRise: Float
    public var emberSize: Float
    public var emberLife: Float
    public var warp: Float
    public var sides: Float
    public var baseGlow: Float
    public var occlusion: Float
    public var swirl: Float
    public var smoke: Float

    public init(
        style: FireStyle = .top,
        low: Rgb = rgb(0x8a1405),
        mid: Rgb = rgb(0xff5a14),
        hot: Rgb = rgb(0xffc65a),
        height: Float = 54.0,
        scale: Float = 20.0,
        speed: Float = 1.5,
        intensity: Float = 1.0,
        embers: UInt32 = 16,
        emberRise: Float = 58.0,
        emberSize: Float = 0.8,
        emberLife: Float = 1.5,
        warp: Float = 1.0,
        sides: Float = 0.32,
        baseGlow: Float = 0.5,
        occlusion: Float = 0.25,
        swirl: Float = 0.0,
        smoke: Float = 0.5
    ) {
        self.style = style
        self.low = low
        self.mid = mid
        self.hot = hot
        self.height = height
        self.scale = scale
        self.speed = speed
        self.intensity = intensity
        self.embers = embers
        self.emberRise = emberRise
        self.emberSize = emberSize
        self.emberLife = emberLife
        self.warp = warp
        self.sides = sides
        self.baseGlow = baseGlow
        self.occlusion = occlusion
        self.swirl = swirl
        self.smoke = smoke
    }

    public static func heat() -> FireParams {
        FireParams(
            style: .heat,
            low: rgb(0x7a1606),
            mid: rgb(0xf0601a),
            hot: rgb(0xffc062),
            height: 15.0,
            scale: 7.0,
            speed: 1.3,
            intensity: 0.8,
            embers: 4,
            emberRise: 30.0,
            emberSize: 0.55,
            emberLife: 1.1,
            warp: 0.8,
            baseGlow: 0.35,
            occlusion: 0.1
        )
    }

    public static func plasma() -> FireParams {
        FireParams(
            style: .border,
            low: rgb(0x3a1690),
            mid: rgb(0x7b5cff),
            hot: rgb(0x9fe8ff),
            height: 30.0,
            scale: 16.0,
            speed: 1.1,
            intensity: 0.95,
            embers: 0,
            warp: 1.0,
            sides: 0.55,
            baseGlow: 0.6,
            swirl: 0.8
        )
    }

    public static let knobs: [Knob] = [
        Knob(name: "height", min: 4.0, max: 160.0, default: 54.0),
        Knob(name: "scale", min: 4.0, max: 80.0, default: 20.0),
        Knob(name: "speed", min: 0.0, max: 5.0, default: 1.5),
        Knob(name: "intensity", min: 0.0, max: 3.0, default: 1.0),
        Knob(name: "embers", min: 0.0, max: 40.0, default: 16.0),
        Knob(name: "ember_rise", min: 0.0, max: 200.0, default: 58.0),
        Knob(name: "ember_size", min: 0.2, max: 3.0, default: 0.8),
        Knob(name: "ember_life", min: 0.2, max: 4.0, default: 1.5),
        Knob(name: "warp", min: 0.0, max: 3.0, default: 1.0),
        Knob(name: "sides", min: 0.0, max: 1.0, default: 0.32),
        Knob(name: "base_glow", min: 0.0, max: 2.0, default: 0.5),
        Knob(name: "occlusion", min: 0.0, max: 1.0, default: 0.25),
        Knob(name: "swirl", min: 0.0, max: 3.0, default: 0.0),
        Knob(name: "smoke", min: 0.0, max: 2.0, default: 0.5),
    ]
}

// MARK: - Distort & Lens

public struct LensParams: Sendable, Equatable {
    public var bevel: Float
    public var depth: Float
    public var dispersion: Float
    public var magnification: Float
    public var presence: Float
    public var frost: Float
    public var shadow: Float
    public var rim: Float
    public var lightAngle: Float
    public var tint: Rgb
    public var tintAmount: Float
    public var second: FxShape?
    public var unionK: Float
    public var morph: Float

    public init(
        bevel: Float = 14.0,
        depth: Float = 16.0,
        dispersion: Float = 0.14,
        magnification: Float = 1.04,
        presence: Float = 1.0,
        frost: Float = 0.0,
        shadow: Float = 0.35,
        rim: Float = 1.6,
        lightAngle: Float = -2.09,
        tint: Rgb = rgb(0xffffff),
        tintAmount: Float = 0.0,
        second: FxShape? = nil,
        unionK: Float = 22.0,
        morph: Float = 0.0
    ) {
        self.bevel = bevel
        self.depth = depth
        self.dispersion = dispersion
        self.magnification = magnification
        self.presence = presence
        self.frost = frost
        self.shadow = shadow
        self.rim = rim
        self.lightAngle = lightAngle
        self.tint = tint
        self.tintAmount = tintAmount
        self.second = second
        self.unionK = unionK
        self.morph = morph
    }
}

public enum DistortParams: Sendable, Equatable {
    case heatHaze(height: Float, scale: Float, speed: Float, amount: Float, wholeShape: Bool)
    case shockwave(at: SIMD2<Float>, reach: Float, width: Float, amount: Float, chroma: Float, t0: Float, duration: Float)
    case lens(LensParams)
    case crt(bulge: Float, scanline: Float, scanDepth: Float, chroma: Float, vignette: Float, glow: Float, roll: Float, feather: Float)
    case chromaSplit(offset: SIMD2<Float>, glitch: Float, feather: Float)

    public static func shockwave(at: SIMD2<Float>, t0: Float) -> DistortParams {
        .shockwave(at: at, reach: 160.0, width: 14.0, amount: 9.0, chroma: 0.35, t0: t0, duration: 0.9)
    }

    public static func crt() -> DistortParams {
        .crt(bulge: 0.08, scanline: 1.5, scanDepth: 0.28, chroma: 0.8, vignette: 0.6, glow: 0.35, roll: 1.0, feather: 2.0)
    }

    public static func chromaSplit(offset: SIMD2<Float>) -> DistortParams {
        .chromaSplit(offset: offset, glitch: 0.0, feather: 2.0)
    }
}

// MARK: - Motion Blur (RuneMotion Integration)

public enum BlurMode: Sendable, Equatable {
    case shutter
    case directional
}

public struct MotionBlurParams: Sendable, Equatable {
    public var mode: BlurMode
    public var shutterAngle: Float
    public var frameDt: Float
    public var maxSamples: UInt32
    public var pxPerSample: Float
    public var smoothShutter: Bool

    public init(
        mode: BlurMode = .shutter,
        shutterAngle: Float = 180.0,
        frameDt: Float = 1.0 / 60.0,
        maxSamples: UInt32 = 48,
        pxPerSample: Float = 1.25,
        smoothShutter: Bool = true
    ) {
        self.mode = mode
        self.shutterAngle = shutterAngle
        self.frameDt = frameDt
        self.maxSamples = maxSamples
        self.pxPerSample = pxPerSample
        self.smoothShutter = smoothShutter
    }

    public static let knobs: [Knob] = [
        Knob(name: "shutter_angle", min: 0.0, max: 360.0, default: 180.0),
        Knob(name: "max_samples", min: 1.0, max: 64.0, default: 48.0),
        Knob(name: "px_per_sample", min: 0.5, max: 6.0, default: 1.25),
    ]
}

public struct Pose: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var rotation: Float
    public var scale: Float
    public var opacity: Float

    public init(x: Float = 0.0, y: Float = 0.0, rotation: Float = 0.0, scale: Float = 1.0, opacity: Float = 1.0) {
        self.x = x
        self.y = y
        self.rotation = rotation
        self.scale = scale
        self.opacity = opacity
    }

    public init(transform: Transform2D, opacity: Float = 1.0) {
        self.x = transform.tx
        self.y = transform.ty
        self.rotation = transform.rot
        self.scale = transform.sx
        self.opacity = opacity
    }

    internal func affine(rest: FxRect) -> (Float, Float, Float, Float, Float, Float) {
        let c = rest.center
        let s = sinf(rotation)
        let cosA = cosf(rotation)
        let a = cosA * scale
        let b = s * scale
        let cc = -s * scale
        let d = cosA * scale
        let tx = c.x + x - (a * c.x + cc * c.y)
        let ty = c.y + y - (b * c.x + d * c.y)
        return (a, b, cc, d, tx, ty)
    }

    public func apply(rest: FxRect, point p: SIMD2<Float>) -> SIMD2<Float> {
        let (a, b, c, d, tx, ty) = affine(rest: rest)
        return SIMD2<Float>(a * p.x + c * p.y + tx, b * p.x + d * p.y + ty)
    }
}

public let maxMotionSamples = 64

public struct MotionSamples: Sendable, Equatable {
    public var count: UInt32
    public var mode: BlurMode
    /// Each entry: `(ia, ib, ic, id)` and `(itx, ity, weight * opacity, 0)` flattened as 2 SIMD4s.
    public var xforms: [SIMD4<Float>]
    public var bounds: FxRect
    public var blur: SIMD2<Float>
    public var travelPx: Float

    public var isMoving: Bool { count > 1 }

    private static func invert(_ m: (Float, Float, Float, Float, Float, Float)) -> (Float, Float, Float, Float, Float, Float) {
        let (a, b, c, d, tx, ty) = m
        let det = a * d - b * c
        let id = 1.0 / (abs(det) < 1e-9 ? 1e-9 : det)
        let ia = d * id
        let ib = -b * id
        let ic = -c * id
        let idd = a * id
        return (ia, ib, ic, idd, -(ia * tx + ic * ty), -(ib * tx + idd * ty))
    }

    public static func fromTrack(
        _ p: MotionBlurParams,
        rest: FxRect,
        at t: Float,
        scale: Float,
        track: (Float) -> Pose
    ) -> MotionSamples {
        let open = p.frameDt * p.shutterAngle / 360.0
        let t0 = t - open * 0.5
        let t1 = t + open * 0.5
        let pa = track(t0)
        let pb = track(t1)
        let pm = track(t)

        var travel: Float = 0.0
        for c in rest.corners {
            let a = pa.apply(rest: rest, point: c)
            let m = pm.apply(rest: rest, point: c)
            let b = pb.apply(rest: rest, point: c)
            let d1 = hypotf(m.x - a.x, m.y - a.y)
            let d2 = hypotf(b.x - m.x, b.y - m.y)
            travel = max(travel, d1 + d2)
        }
        let travelPx = travel * scale
        var xforms = [SIMD4<Float>](repeating: .zero, count: maxMotionSamples * 2)
        var bounds = rest
        var count: UInt32 = 1
        var blur = SIMD2<Float>.zero

        func put(_ i: Int, _ pose: Pose, _ w: Float) {
            let inv = invert(pose.affine(rest: rest))
            xforms[i * 2] = SIMD4<Float>(inv.0, inv.1, inv.2, inv.3)
            xforms[i * 2 + 1] = SIMD4<Float>(inv.4, inv.5, w * pose.opacity, 0.0)
            var b: FxRect?
            for c in rest.corners {
                let q = pose.apply(rest: rest, point: c)
                let r = FxRect(x: q.x, y: q.y, w: 0.0, h: 0.0)
                b = b.map { $0.union(r) } ?? r
            }
            if let b {
                bounds = i == 0 ? b : bounds.union(b)
            }
        }

        let maxS = min(max(Int(p.maxSamples), 1), maxMotionSamples)
        let want = min(max(Int(ceilf(travelPx / max(p.pxPerSample, 0.25))), 1), maxS)

        if want <= 1 || open <= 0.0 {
            put(0, pm, 1.0)
            return MotionSamples(count: 1, mode: p.mode, xforms: xforms, bounds: bounds, blur: blur, travelPx: travelPx)
        }

        switch p.mode {
        case .shutter:
            var w = [Float](repeating: 0.0, count: want)
            var sum: Float = 0.0
            for i in 0..<want {
                let u = (Float(i) + 0.5) / Float(want)
                let wi: Float = p.smoothShutter ? (0.5 - 0.5 * cosf(2.0 * .pi * u)) : 1.0
                w[i] = wi
                sum += wi
            }
            for i in 0..<want {
                let u = (Float(i) + 0.5) / Float(want)
                let pose = track(t0 + (t1 - t0) * u)
                put(i, pose, w[i] / sum)
            }
            count = UInt32(want)
        case .directional:
            put(0, pm, 1.0)
            blur = SIMD2<Float>(pb.x - pa.x, pb.y - pa.y)
            count = UInt32(min(want, 32))
            let half = blur * 0.5
            let a = FxRect(x: bounds.x - half.x, y: bounds.y - half.y, w: bounds.w, h: bounds.h)
            let b = FxRect(x: bounds.x + half.x, y: bounds.y + half.y, w: bounds.w, h: bounds.h)
            bounds = a.union(b)
        }

        return MotionSamples(count: count, mode: p.mode, xforms: xforms, bounds: bounds, blur: blur, travelPx: travelPx)
    }

    /// Convenience for `RuneMotion.Animated<Transform2D>` / `Spring` curves.
    public static func fromMotion(
        _ p: MotionBlurParams,
        rest: FxRect,
        at t: Float,
        scale: Float,
        sample: (Float) -> Transform2D
    ) -> MotionSamples {
        fromTrack(p, rest: rest, at: t, scale: scale) { time in
            Pose(transform: sample(time))
        }
    }
}

// MARK: - Extras (Shimmer, Sparkles, Aurora, Grain)

public struct ShimmerParams: Sendable, Equatable {
    public var color: Rgb
    public var base: Rgb
    public var baseAlpha: Float
    public var period: Float
    public var band: Float
    public var angle: Float
    public var intensity: Float
    public var useMask: Bool
    public var pause: Float
    public var feather: Float

    public init(
        color: Rgb = rgb(0xffffff),
        base: Rgb = rgb(0x1c1f26),
        baseAlpha: Float = 0.0,
        period: Float = 1.8,
        band: Float = 28.0,
        angle: Float = 0.35,
        intensity: Float = 0.16,
        useMask: Bool = false,
        pause: Float = 0.3,
        feather: Float = 0.0
    ) {
        self.color = color
        self.base = base
        self.baseAlpha = baseAlpha
        self.period = period
        self.band = band
        self.angle = angle
        self.intensity = intensity
        self.useMask = useMask
        self.pause = pause
        self.feather = feather
    }
}

public struct SparkleParams: Sendable, Equatable {
    public var color: Rgb
    public var count: UInt32
    public var life: Float
    public var size: Float
    public var intensity: Float
    public var margin: Float
    public var burst: Float?

    public init(
        color: Rgb = rgb(0xffe6a8),
        count: UInt32 = 6,
        life: Float = 1.5,
        size: Float = 7.0,
        intensity: Float = 1.0,
        margin: Float = 10.0,
        burst: Float? = nil
    ) {
        self.color = color
        self.count = count
        self.life = life
        self.size = size
        self.intensity = intensity
        self.margin = margin
        self.burst = burst
    }

    public var burstLife: Float {
        RuneFXCPU.sparkleStagger + life * RuneFXCPU.burstLife * 1.3
    }
}

public struct AuroraParams: Sendable, Equatable {
    public var a: Rgb
    public var b: Rgb
    public var c: Rgb
    public var scale: Float
    public var speed: Float
    public var intensity: Float
    public var feather: Float

    public init(
        a: Rgb = rgb(0x16c79a),
        b: Rgb = rgb(0x3b6cff),
        c: Rgb = rgb(0xa23bff),
        scale: Float = 120.0,
        speed: Float = 0.25,
        intensity: Float = 0.5,
        feather: Float = 40.0
    ) {
        self.a = a
        self.b = b
        self.c = c
        self.scale = scale
        self.speed = speed
        self.intensity = intensity
        self.feather = feather
    }
}

public struct GrainParams: Sendable, Equatable {
    public var amount: Float
    public var fps: Float
    public var feather: Float

    public init(amount: Float = 0.03, fps: Float = 0.0, feather: Float = 0.0) {
        self.amount = amount
        self.fps = fps
        self.feather = feather
    }
}

// MARK: - GPU Uniform & Instance Layouts

public struct FxGlobals: Sendable, Equatable {
    public var viewport: SIMD2<Float>
    public var dither: Float
    public var srgb: Float

    public init(viewport: SIMD2<Float>, dither: Float = 0.0, srgb: Float = 0.0) {
        self.viewport = viewport
        self.dither = dither
        self.srgb = srgb
    }
}

public struct FxBackdropEncoding: Sendable, Equatable {
    public var encoded: Float
    public var present: Float
    public var pad0: Float = 0.0
    public var pad1: Float = 0.0

    public init(encoded: Float, present: Float) {
        self.encoded = encoded
        self.present = present
    }
}

/// 256-byte GPU instance matching Metal `Inst` struct (`16 × SIMD4`).
public struct FxInstRaw: Sendable, Equatable {
    public var rect: SIMD4<Float> = .zero
    public var shape: SIMD4<Float> = .zero
    public var bounds: SIMD4<Float> = .zero
    public var c0: SIMD4<Float> = .zero
    public var c1: SIMD4<Float> = .zero
    public var c2: SIMD4<Float> = .zero
    public var p0: SIMD4<Float> = .zero
    public var p1: SIMD4<Float> = .zero
    public var p2: SIMD4<Float> = .zero
    public var p3: SIMD4<Float> = .zero
    public var t: SIMD4<Float> = .zero
    public var aux: SIMD4<Float> = .zero
    public var aux2: SIMD4<Float> = .zero
    public var xf: SIMD4<Float> = .zero
    public var clip: SIMD4<Float> = fxNoClip
    public var fade: SIMD4<UInt32> = .zero

    public init() {}
}

public enum FxEffectKind: Int, CaseIterable, Sendable {
    case glow = 0
    case pulse = 1
    case electric = 2
    case fire = 3
    case distort = 4
    case motion = 5
    case extras = 6
    case fill = 7

    public var shaderName: String {
        switch self {
        case .glow: return "glow"
        case .pulse: return "pulse"
        case .electric: return "electric"
        case .fire: return "fire"
        case .distort: return "distort"
        case .motion: return "motion"
        case .extras: return "extras"
        case .fill: return "fill"
        }
    }
}

public enum FxPackConstants {
    public static let pingLife: Float = 2.2
    public static let lensFrostSigma: Float = 18.0
    public static let calmT: Float = 2.37
}

// MARK: - Packing

extension FxLayer {
    internal func pack() -> (kind: FxEffectKind, inst: FxInstRaw, bounds: FxRect)? {
        if isSilent { return nil }
        let s = shape
        let r = s.rect
        var i = FxInstRaw()
        i.rect = r.xywh
        i.shape = SIMD4<Float>(max(0.0, min(s.radius, min(r.w * 0.5, r.h * 0.5))), 1.0, min(opacity, 1.0), 0.0)
        i.t = SIMD4<Float>(time, Float(seed % 65_536), 0.0, reducedMotion ? 1.0 : 0.0)
        i.aux2 = source?.rect.xywh ?? SIMD4<Float>(0.0, 0.0, 1.0, 1.0)

        let rm = reducedMotion
        let loopedT = rm ? FxPackConstants.calmT : time
        let kind: FxEffectKind
        let bounds: FxRect

        switch fx {
        case .glow(let p):
            i.t.z = switch p.style {
            case .soft: 0.0
            case .neon: 1.0
            case .aura: 2.0
            case .mask: 3.0
            }
            i.c0 = p.color.v4
            i.c1 = p.core.v4
            i.c2 = p.third.v4
            i.p0 = SIMD4<Float>(p.radius, p.intensity, p.inner, p.occlusion)
            i.p1 = SIMD4<Float>(p.breathe, p.breathePeriod, min(max(p.heat, 0.0), 1.0), p.hot)
            i.p2 = SIMD4<Float>(p.auraSpeed, p.rimWidth, p.reach, 0.0)
            kind = .glow
            bounds = r.inflate(p.radius * p.reach * (1.0 + 0.22 * p.breathe))

        case .pulse(let p):
            i.c0 = p.color.v4
            i.c1 = p.core.v4
            i.p0 = SIMD4<Float>(Float(p.count), p.period, p.reach, p.width)
            i.p1 = SIMD4<Float>(p.intensity, p.t0, p.duration, p.repeatInterval)
            i.p2 = SIMD4<Float>(0.0, p.lag, p.headRadius, p.occlusion)
            let (v, b): (Float, FxRect)
            switch p.style {
            case .radar:
                (v, b) = (0.0, r.inflate(p.reach + p.width * 3.2 * 4.0))
            case .breathe:
                (v, b) = (1.0, r.inflate(p.reach * 5.0))
            case .heartbeat:
                (v, b) = (2.0, r.inflate(p.reach + p.width * 16.0 + 2.0))
            case .ping(let from, let dir, let travel):
                if p.repeatInterval <= 0.0 && (time < p.t0 || time > p.t0 + p.duration * FxPackConstants.pingLife) {
                    return nil
                }
                let l = hypotf(dir.x, dir.y)
                let d = l > 1e-6 ? SIMD2<Float>(dir.x / l, dir.y / l) : SIMD2<Float>(1.0, 0.0)
                i.aux = SIMD4<Float>(from.x, from.y, d.x, d.y)
                i.p2.x = travel
                let to = from + d * travel
                let back = from - d * (travel * 0.06)
                (v, b) = (3.0, FxRect.fromPoints(back, to).inflate(p.headRadius * 10.0 + 30.0))
            case .ripple(let at):
                if time < p.t0 || time > p.t0 + p.duration {
                    return nil
                }
                i.aux = SIMD4<Float>(at.x, at.y, 0.0, 0.0)
                if p.reach <= 0.0 {
                    let far = r.corners.map { hypotf($0.x - at.x, $0.y - at.y) }.max() ?? 0.0
                    i.p0.z = far
                }
                (v, b) = (4.0, r.inflate(1.0))
            }
            i.t.z = v
            kind = .pulse
            bounds = b

        case .electric(let p):
            i.t.x = loopedT
            if let t0 = p.zap {
                if time < t0 || time > t0 + ElectricParams.zapLife {
                    return nil
                }
                i.t.x = time
            }
            i.c0 = p.color.v4
            i.c1 = p.core.v4
            i.c2 = p.cool.v4
            i.p0 = SIMD4<Float>(p.amplitude, p.frequency, p.speed, p.coreWidth)
            i.p1 = SIMD4<Float>(p.intensity, p.glow, p.forks, p.flicker)
            i.p2 = SIMD4<Float>(Float(min(max(p.strands, 1), 3)), p.gap, p.forkLen, p.occlusion)
            let m = p.amplitude * 1.7 + p.glow * 5.0
            kind = .electric
            switch p.style {
            case .arc(let a, let b):
                i.t.z = 0.0
                i.aux = SIMD4<Float>(a.x, a.y, b.x, b.y)
                let len = max(hypotf(b.x - a.x, b.y - a.y), 1.0)
                bounds = FxRect.fromPoints(a, b).inflate(p.glow * 5.0 + p.coreWidth * 3.0 + RuneFXCPU.arcReach(p, len: len))
            case .border:
                i.t.z = 1.0
                bounds = r.inflate(m + max(p.gap, 0.0) + p.forkLen * 1.3)
            case .charged:
                i.t.z = 2.0
                bounds = r.inflate(m + max(p.gap, 0.0) + p.forkLen * 0.6)
            }

        case .fire(let p):
            i.t.x = loopedT
            i.t.z = switch p.style {
            case .top, .heat: 0.0
            case .border: 1.0
            case .embers: 3.0
            }
            i.c0 = p.low.v4
            i.c1 = p.mid.v4
            i.c2 = p.hot.v4
            i.p0 = SIMD4<Float>(p.height, p.scale, p.speed, p.intensity)
            i.p1 = SIMD4<Float>(rm ? 0.0 : Float(min(p.embers, 40)), p.emberRise, p.emberSize, p.emberLife)
            i.p2 = SIMD4<Float>(p.warp, p.sides, p.baseGlow, p.occlusion)
            i.p3 = SIMD4<Float>(p.swirl, 0.0, 0.0, 0.0)
            let emberUp: Float
            let emberSide: Float
            if p.embers > 0 && !rm {
                let life = max(p.emberLife, 0.1) * 1.4
                emberUp = p.height * 0.55 + p.emberRise * (1.48 / RuneFXCPU.emberDrag + 0.32 * life) + p.emberSize * 4.0
                emberSide = 7.5 * life + 9.0
            } else {
                emberUp = 0.0
                emberSide = 0.0
            }
            kind = .fire
            switch p.style {
            case .border:
                bounds = r.inflate(max(p.height * p.sides * 0.3, 2.5) * 4.6 + 2.0)
            default:
                let up = max(p.height * 2.6 + 8.0, emberUp) + 4.0
                bounds = FxRect(x: r.x - emberSide, y: r.y - up, w: r.w + 2.0 * emberSide, h: up + 4.0)
            }

        case .distort(let d):
            kind = .distort
            switch d {
            case .heatHaze(let height, let scale, let speed, let amount, let wholeShape):
                i.t.x = loopedT
                i.t.z = 0.0
                i.p0 = SIMD4<Float>(height, scale, speed, amount)
                i.p1 = SIMD4<Float>(wholeShape ? 1.0 : 0.0, 0.0, 0.0, 0.0)
                bounds = wholeShape ? r.inflate(amount + 2.0) : FxRect(x: r.x - 4.0, y: r.y - height - 4.0, w: r.w + 8.0, h: height + 12.0)
            case .shockwave(let at, let reach, let width, let amount, let chroma, let t0, let duration):
                if time < t0 || time > t0 + duration { return nil }
                i.t.z = 1.0
                i.aux = SIMD4<Float>(at.x, at.y, 0.0, 0.0)
                i.p0 = SIMD4<Float>(reach, width, amount, chroma)
                i.p1 = SIMD4<Float>(t0, duration, 0.0, 0.0)
                bounds = FxRect(x: at.x, y: at.y, w: 0.0, h: 0.0).inflate(reach + width * 5.0 + amount)
            case .lens(let l):
                i.t.z = 2.0
                i.c0 = l.tint.v4
                i.p0 = SIMD4<Float>(l.bevel, l.depth, l.dispersion, l.magnification)
                i.p1 = SIMD4<Float>(min(max(l.presence, 0.0), 1.0), l.frost, l.shadow, l.rim)
                var b = r
                if let s2 = l.second {
                    let sr = min(s2.radius, min(s2.rect.w * 0.5, s2.rect.h * 0.5))
                    i.p2 = SIMD4<Float>(l.lightAngle, l.tintAmount, l.unionK, sr)
                    i.p3 = s2.rect.xywh
                    i.shape.w = l.morph
                    b = b.union(s2.rect)
                } else {
                    i.p2 = SIMD4<Float>(l.lightAngle, l.tintAmount, 0.0, 0.0)
                }
                bounds = b.inflate(28.0)
            case .crt(let bulge, let scanline, let scanDepth, let chroma, let vignette, let glow, let roll, let feather):
                i.t.z = 3.0
                i.p0 = SIMD4<Float>(bulge, scanline, scanDepth, chroma)
                i.p1 = SIMD4<Float>(vignette, glow, roll, feather)
                bounds = r.inflate(feather)
            case .chromaSplit(let offset, let glitch, let feather):
                i.t.z = 4.0
                i.p0 = SIMD4<Float>(offset.x, offset.y, glitch, feather)
                bounds = r.inflate(feather)
            }

        case .motionBlur(_, let ms):
            i.xf = SIMD4<Float>(0.0, Float(ms.count), ms.mode == .shutter ? 0.0 : 1.0, 0.0)
            i.aux = SIMD4<Float>(ms.blur.x, ms.blur.y, 0.0, 0.0)
            kind = .motion
            bounds = ms.bounds.inflate(2.0)

        case .shimmer(let p):
            i.t.z = 0.0
            i.c0 = p.color.v4
            i.c1 = SIMD4<Float>(p.base.r, p.base.g, p.base.b, p.baseAlpha)
            i.p0 = SIMD4<Float>(p.period, p.band, p.angle, p.intensity)
            i.p1 = SIMD4<Float>(p.useMask ? 1.0 : 0.0, p.pause, p.feather, 0.0)
            kind = .extras
            bounds = r.inflate(1.0)

        case .sparkles(let p):
            if let t0 = p.burst, time < t0 || time > t0 + p.burstLife {
                return nil
            }
            i.t.z = 1.0
            i.c0 = p.color.v4
            i.p0 = SIMD4<Float>(Float(min(p.count, 64)), p.life, p.size, p.intensity)
            i.p1 = SIMD4<Float>(p.margin, 0.0, 0.0, 0.0)
            kind = .extras
            bounds = r.inflate(p.margin + p.size * RuneFXCPU.sparkleMaxScale + 2.0)

        case .aurora(let p):
            i.t.z = 2.0
            i.c0 = p.a.v4
            i.c1 = p.b.v4
            i.c2 = p.c.v4
            i.p0 = SIMD4<Float>(p.scale, p.speed, p.intensity, p.feather)
            kind = .extras
            bounds = r.inflate(1.0)

        case .grain(let p):
            i.t.z = 3.0
            i.p0 = SIMD4<Float>(p.amount, p.fps, p.feather, 0.0)
            kind = .extras
            bounds = r.inflate(1.0)

        case .fill(let p):
            guard let b = p.pack(into: &i, reducedMotion: rm, time: time) else { return nil }
            kind = .fill
            bounds = b
        }

        return (kind, i, bounds)
    }

    internal func fillTables(into i: inout FxInstRaw, data: inout [SIMD4<Float>]) {
        let t = i.t.x
        let rm = reducedMotion
        switch fx {
        case .motionBlur(_, let ms):
            i.xf.x = Float(data.count)
            let count = Int(ms.count)
            for k in 0..<count {
                data.append(ms.xforms[k * 2])
                data.append(ms.xforms[k * 2 + 1])
            }
        case .electric(let p):
            i.xf = RuneFXCPU.electric(p, shape: shape, t: t, seed: seed, reduced: rm, data: &data)
        case .fire(let p):
            if p.embers > 0 && !rm {
                let (first, count) = RuneFXCPU.embers(p, rect: shape.rect, radius: shape.radius, t: t, seed: seed, data: &data)
                i.xf = SIMD4<Float>(first, count, 0.0, 0.0)
            }
        case .sparkles(let p):
            let (first, count) = RuneFXCPU.sparkles(p, rect: shape.rect, t: t, seed: seed, reduced: rm, data: &data)
            i.xf = SIMD4<Float>(first, count, 0.0, 0.0)
        case .aurora(let p):
            let first = RuneFXCPU.aurora(p, rect: shape.rect, t: t, seed: seed, data: &data)
            i.xf = SIMD4<Float>(first, Float(RuneFXCPU.auroraSamples), 0.0, 0.0)
        case .fill(let p):
            p.fillTables(into: &i, shape: shape, time: t, seed: seed, reducedMotion: rm, data: &data)
        default:
            break
        }
    }
}
