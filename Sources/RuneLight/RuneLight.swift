import Foundation
import Rune

public let maxLights = 8
public let flagOccluder: UInt32 = 1
public let flagEmissive: UInt32 = 2
public let flagRaised: UInt32 = 4
public let flagGIHint: UInt32 = 8
public let lightCascades: UInt32 = 5
public let giScale: Float = 0.125

/// One lit primitive, in device pixels. 96 bytes (`6 × SIMD4<Float>`).
public struct Prim: Sendable, Equatable {
    public var rect: SIMD4<Float>
    public var radii: SIMD4<Float>
    public var z: SIMD4<Float>
    public var mat: SIMD4<Float>
    public var emit: SIMD4<Float>
    public var albedo: SIMD4<Float>

    public init(
        rect: SIMD4<Float>,
        radii: SIMD4<Float> = .zero,
        z: SIMD4<Float> = .zero,
        mat: SIMD4<Float> = SIMD4<Float>(0.0, 0.6, 0.0, 0.0),
        emit: SIMD4<Float> = .zero,
        albedo: SIMD4<Float> = SIMD4<Float>(0.5, 0.5, 0.5, 0.0)
    ) {
        self.rect = rect
        self.radii = radii
        self.z = z
        self.mat = mat
        self.emit = emit
        self.albedo = albedo
    }

    public static func rect(_ x: Float, _ y: Float, _ w: Float, _ h: Float) -> Prim {
        Prim(rect: SIMD4<Float>(x, y, w, h))
    }

    public static func fromRune(rect: SIMD4<Float>, radii: SIMD4<Float>) -> Prim {
        Prim(rect: rect, radii: radii)
    }

    /// Convert a `Rune.MotionRect` and `Rune.Corners` into a `Prim` in device pixels.
    public static func fromRune(rect: MotionRect, corners: Corners = .all(0), scale: Float = 1.0) -> Prim {
        let s = max(scale, 0.0)
        return Prim(
            rect: SIMD4<Float>(
                rect.left * s,
                rect.top * s,
                max(0, rect.right - rect.left) * s,
                max(0, rect.bottom - rect.top) * s
            ),
            radii: SIMD4<Float>(
                corners.topLeft * s,
                corners.topRight * s,
                corners.bottomRight * s,
                corners.bottomLeft * s
            )
        )
    }

    /// Convert a `Rune.ComputedLayout` into a `Prim` in device pixels.
    public static func fromRune(layout: ComputedLayout, corners: Corners = .all(0), scale: Float = 1.0) -> Prim {
        fromRune(rect: layout.localRect, corners: corners, scale: scale)
    }

    /// Convert a laid-out `Rune.El` and its rect into a `Prim` in device pixels, preserving corner radii and albedo.
    public static func fromRune<State>(element: El<State>, rect: MotionRect, scale: Float = 1.0) -> Prim {
        var prim = fromRune(rect: rect, corners: element.corners, scale: scale)
        if element.background.a > 0 {
            prim = prim.albedo(SIMD3<Float>(element.background.r, element.background.g, element.background.b))
        }
        return prim
    }

    public func radius(_ r: Float) -> Prim {
        var copy = self
        copy.radii = SIMD4<Float>(repeating: r)
        return copy
    }

    public func radii(_ r: SIMD4<Float>) -> Prim {
        var copy = self
        copy.radii = r
        return copy
    }

    public func on(_ zVal: Float) -> Prim {
        var copy = self
        copy.z.x = zVal
        copy.z.y = zVal
        return copy
    }

    public func raised(_ height: Float) -> Prim {
        var copy = self
        copy.z.y = copy.z.x + height
        return copy.setting(flagOccluder, height > 0.0)
    }

    public func floating(bottom: Float, top: Float) -> Prim {
        var copy = self
        copy.z.x = bottom
        copy.z.y = top
        return copy.setting(flagOccluder, true)
    }

    public func bevel(width: Float, height: Float) -> Prim {
        var copy = self
        copy.z.z = width
        copy.z.w = height
        return copy.setting(flagRaised, width > 0.0)
    }

    public func gloss(_ gloss: Float, roughness: Float) -> Prim {
        var copy = self
        copy.mat.x = gloss
        copy.mat.y = roughness
        return copy
    }

    public func emissive(_ rgb: SIMD3<Float>) -> Prim {
        var copy = self
        copy.emit = SIMD4<Float>(rgb.x, rgb.y, rgb.z, 0.0)
        let on = rgb.x > 0.0 || rgb.y > 0.0 || rgb.z > 0.0
        return copy.setting(flagEmissive, on)
    }

    public func giHint() -> Prim {
        var copy = self
        copy.mat.z = Float(flagGIHint)
        return copy
    }

    public func albedo(_ rgb: SIMD3<Float>) -> Prim {
        var copy = self
        copy.albedo = SIMD4<Float>(rgb.x, rgb.y, rgb.z, 0.0)
        return copy
    }

    public var flags: UInt32 {
        UInt32(max(mat.z, 0.0))
    }

    private func setting(_ flag: UInt32, _ on: Bool) -> Prim {
        var copy = self
        let f = on ? (flags | flag) : (flags & ~flag)
        copy.mat.z = Float(f)
        return copy
    }
}

/// A light, in device pixels. `z` is height above the UI plane. 64 bytes (`4 × SIMD4<Float>`).
public struct Light: Sendable, Equatable {
    public var pos: SIMD4<Float>
    public var color: SIMD4<Float>
    public var axis: SIMD4<Float>
    public var extra: SIMD4<Float>

    public init(
        pos: SIMD4<Float>,
        color: SIMD4<Float> = SIMD4<Float>(1.0, 1.0, 1.0, 2400.0),
        axis: SIMD4<Float> = SIMD4<Float>(0.0, 0.0, -1.0, 0.0),
        extra: SIMD4<Float> = SIMD4<Float>(0.0, 0.0, 1.0, 1.0)
    ) {
        self.pos = pos
        self.color = color
        self.axis = axis
        self.extra = extra
    }

    public static func point(_ x: Float, _ y: Float, _ z: Float) -> Light {
        Light(pos: SIMD4<Float>(x, y, z, 12.0))
    }

    private var currentIntensity: Float {
        max(color.x, max(color.y, color.z))
    }

    public func color(_ rgb: SIMD3<Float>) -> Light {
        let i = currentIntensity
        var copy = self
        copy.color.x = rgb.x
        copy.color.y = rgb.y
        copy.color.z = rgb.z
        return copy.intensity(i)
    }

    public func intensity(_ i: Float) -> Light {
        var copy = self
        let cur = copy.currentIntensity
        if cur > 0.0 {
            let s = i / cur
            copy.color.x *= s
            copy.color.y *= s
            copy.color.z *= s
        } else {
            copy.color.x = i
            copy.color.y = i
            copy.color.z = i
        }
        return copy
    }

    public func radius(_ r: Float) -> Light {
        var copy = self
        copy.pos.w = r
        return copy
    }

    public func range(_ r: Float) -> Light {
        var copy = self
        copy.color.w = r
        return copy
    }

    public func spot(axis a: SIMD3<Float>, halfAngle: Float) -> Light {
        let l = max(sqrtf(a.x * a.x + a.y * a.y + a.z * a.z), 1e-6)
        var copy = self
        copy.axis = SIMD4<Float>(a.x / l, a.y / l, a.z / l, halfAngle)
        return copy
    }

    public func shafts(_ s: Float) -> Light {
        var copy = self
        copy.extra.x = s
        return copy
    }

    public func bulb(_ g: Float) -> Light {
        var copy = self
        copy.extra.y = g
        return copy
    }

    public func specular(_ s: Float) -> Light {
        var copy = self
        copy.extra.z = s
        return copy
    }

    public func softness(_ s: Float) -> Light {
        var copy = self
        copy.extra.w = s
        return copy
    }

    public func scaled(_ k: Float) -> Light {
        var copy = self
        copy.color.x *= k
        copy.color.y *= k
        copy.color.z *= k
        copy.extra.x *= k
        copy.extra.y *= k
        return copy
    }
}

public struct TextPolicy: Sendable, Equatable {
    public var floor: Float
    public var ceiling: Float
    public var lit: Float
    public var specular: Float

    public init(floor: Float = 0.82, ceiling: Float = 1.25, lit: Float = 1.0, specular: Float = 0.15) {
        self.floor = floor
        self.ceiling = ceiling
        self.lit = lit
        self.specular = specular
    }
}

public struct GIParams: Sendable, Equatable {
    public var strength: Float
    public var air: Float
    public var bounce: Float
    public var absorption: Float
    public var emission: Float

    public init(
        strength: Float = 1.0,
        air: Float = 0.12,
        bounce: Float = 0.25,
        absorption: Float = 0.35,
        emission: Float = 1.0
    ) {
        self.strength = strength
        self.air = air
        self.bounce = bounce
        self.absorption = absorption
        self.emission = emission
    }
}

public struct LightSettings: Sendable, Equatable {
    public var ambient: SIMD3<Float>
    public var exposure: Float
    public var text: TextPolicy
    public var gi: GIParams?
    public var backgroundGloss: Float
    public var backgroundRoughness: Float
    public var contactAO: Float
    public var rim: Float
    public var shaftsOver: Float
    public var albedoFloor: Float
    public var seed: Float
    public var time: Float

    public init(
        ambient: SIMD3<Float> = SIMD3<Float>(0.55, 0.55, 0.58),
        exposure: Float = 1.0,
        text: TextPolicy = TextPolicy(),
        gi: GIParams? = nil,
        backgroundGloss: Float = 0.4,
        backgroundRoughness: Float = 0.55,
        contactAO: Float = 0.35,
        rim: Float = 0.6,
        shaftsOver: Float = 0.35,
        albedoFloor: Float = 0.025,
        seed: Float = 0.0,
        time: Float = 0.0
    ) {
        self.ambient = ambient
        self.exposure = exposure
        self.text = text
        self.gi = gi
        self.backgroundGloss = backgroundGloss
        self.backgroundRoughness = backgroundRoughness
        self.contactAO = contactAO
        self.rim = rim
        self.shaftsOver = shaftsOver
        self.albedoFloor = albedoFloor
        self.seed = seed
        self.time = time
    }
}

public struct LightScene: Sendable {
    public var prims: [Prim]
    public var lights: [Light]
    public var settings: LightSettings

    public init(prims: [Prim], lights: [Light], settings: LightSettings = LightSettings()) {
        self.prims = prims
        self.lights = lights
        self.settings = settings
    }
}

public struct LightTimings: Sendable, Equatable {
    public var field: Double = 0
    public var shadows: Double = 0
    public var gi: Double = 0
    public var giScene: Double = 0
    public var cascades: [Double] = [Double](repeating: 0, count: Int(lightCascades))
    public var fluence: Double = 0
    public var raster: Double = 0
    public var total: Double = 0
}

/// 144-byte Frame uniform matching Metal `Frame` (`9 × SIMD4`).
public struct LightFrameUniforms: Sendable, Equatable {
    public var sf: SIMD4<Float> = .zero
    public var gs: SIMD4<Float> = .zero
    public var ambient: SIMD4<Float> = .zero
    public var counts: SIMD4<UInt32> = .zero
    public var misc: SIMD4<Float> = .zero
    public var text: SIMD4<Float> = .zero
    public var gi: SIMD4<Float> = .zero
    public var bg: SIMD4<Float> = .zero
    public var ext: SIMD4<Float> = .zero

    public init() {}
}

public struct CascadeUniforms: Sendable, Equatable {
    public var level: UInt32
    public var count: UInt32
    public var merge: UInt32
    public var pad: UInt32 = 0

    public init(level: UInt32, count: UInt32 = lightCascades, merge: UInt32 = 1) {
        self.level = level
        self.count = count
        self.merge = merge
    }
}
