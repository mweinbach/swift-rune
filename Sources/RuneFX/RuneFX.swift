import Foundation
import Rune
import RuneMotion

// MARK: - Geometry & Colour

/// A 2D rectangle in points (`x, y, w, h`).
public struct FxRect: Sendable, Equatable, Hashable {
    public var x: Float
    public var y: Float
    public var w: Float
    public var h: Float

    @inlinable
    public init(x: Float, y: Float, w: Float, h: Float) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    @inlinable
    public init(_ motionRect: MotionRect) {
        self.x = motionRect.left
        self.y = motionRect.top
        self.w = motionRect.right - motionRect.left
        self.h = motionRect.bottom - motionRect.top
    }

    @inlinable
    public var motionRect: MotionRect {
        MotionRect(left: x, top: y, right: x + w, bottom: y + h)
    }

    @inlinable
    public var center: SIMD2<Float> {
        SIMD2<Float>(x + w * 0.5, y + h * 0.5)
    }

    @inlinable
    public var xywh: SIMD4<Float> {
        SIMD4<Float>(x, y, w, h)
    }

    @inlinable
    public var corners: [SIMD2<Float>] {
        [
            SIMD2<Float>(x, y),
            SIMD2<Float>(x + w, y),
            SIMD2<Float>(x, y + h),
            SIMD2<Float>(x + w, y + h),
        ]
    }

    @inlinable
    public func inflate(_ margin: Float) -> FxRect {
        FxRect(x: x - margin, y: y - margin, w: w + 2 * margin, h: h + 2 * margin)
    }

    @inlinable
    public func union(_ other: FxRect) -> FxRect {
        let x0 = min(x, other.x)
        let y0 = min(y, other.y)
        let x1 = max(x + w, other.x + other.w)
        let y1 = max(y + h, other.y + other.h)
        return FxRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    @inlinable
    public static func fromPoints(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> FxRect {
        let x0 = min(a.x, b.x)
        let y0 = min(a.y, b.y)
        let x1 = max(a.x, b.x)
        let y1 = max(a.y, b.y)
        return FxRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }
}

/// The node's shape, in points. Capsules and circles are rounded rects with `radius = min(w, h) / 2`.
public struct FxShape: Sendable, Equatable, Hashable {
    public var rect: FxRect
    public var radius: Float

    @inlinable
    public init(rect: FxRect, radius: Float) {
        self.rect = rect
        self.radius = radius
    }

    @inlinable
    public static func rounded(x: Float, y: Float, w: Float, h: Float, radius: Float) -> FxShape {
        FxShape(rect: FxRect(x: x, y: y, w: w, h: h), radius: radius)
    }

    @inlinable
    public static func capsule(x: Float, y: Float, w: Float, h: Float) -> FxShape {
        FxShape(rect: FxRect(x: x, y: y, w: w, h: h), radius: min(w, h) * 0.5)
    }

    @inlinable
    public static func circle(cx: Float, cy: Float, r: Float) -> FxShape {
        FxShape(rect: FxRect(x: cx - r, y: cy - r, w: 2 * r, h: 2 * r), radius: r)
    }
}

/// Linear-light RGB colour.
public struct Rgb: Sendable, Equatable, Hashable {
    public var r: Float
    public var g: Float
    public var b: Float

    @inlinable
    public init(_ r: Float, _ g: Float, _ b: Float) {
        self.r = r
        self.g = g
        self.b = b
    }

    @inlinable
    public init(_ color: Color) {
        self.r = color.r
        self.g = color.g
        self.b = color.b
    }

    @inlinable
    public init(_ color: MotionColor) {
        self.r = color.r
        self.g = color.g
        self.b = color.b
    }

    @inlinable
    public var v4: SIMD4<Float> {
        SIMD4<Float>(r, g, b, 1.0)
    }
}

/// Convert sRGB hex (`0xRRGGBB`) to linear-light `Rgb`.
@inlinable
public func rgb(_ hex: UInt32) -> Rgb {
    func decode(_ shift: UInt32) -> Float {
        let c = Float((hex >> shift) & 0xff) / 255.0
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }
    return Rgb(decode(16), decode(8), decode(0))
}

// MARK: - Time Helpers

/// Continuous phase clock for effects whose speed animates: `at(t)` never jumps when `setSpeed` is called.
public struct Phase: Sendable, Equatable {
    public var speed: Float
    public var offset: Float

    public init(speed: Float) {
        self.speed = speed
        self.offset = 0.0
    }

    /// Effect time to pass as the layer's time.
    public func at(_ t: Float) -> Float {
        t * speed + offset
    }

    public mutating func setSpeed(at t: Float, speed: Float) {
        offset += t * (self.speed - speed)
        self.speed = speed
    }
}

/// Heat of a light that is switched on/off: rises over `attack` s, cools exponentially with
/// time constant `cool` s once off. Feed into `GlowParams.heat`: lights cool, never cut.
public struct Heat: Sendable, Equatable {
    private enum Switch: Sendable, Equatable {
        case off(since: Float, from: Float)
        case on(since: Float, from: Float)
    }

    public var attack: Float
    public var cool: Float
    private var state: Switch

    public init(attack: Float, cool: Float) {
        self.attack = attack
        self.cool = cool
        self.state = .off(since: 0.0, from: 0.0)
    }

    public mutating func set(at t: Float, on: Bool) {
        switch (state, on) {
        case (.off, true):
            state = .on(since: t, from: at(t))
        case (.on, false):
            state = .off(since: t, from: at(t))
        default:
            break
        }
    }

    public func at(_ t: Float) -> Float {
        switch state {
        case .on(let since, let from):
            let k = min(max(t - since, 0.0) / max(attack, 1e-3), 1.0)
            let inv = 1.0 - k
            let e = 1.0 - inv * inv * inv
            return from + (1.0 - from) * e
        case .off(let since, let from):
            return from * expf(-max(t - since, 0.0) / max(cool, 1e-3))
        }
    }

    /// Still changing, so worth ticking frames for: warming up, or not yet cooled to nothing.
    public func isActive(at t: Float) -> Bool {
        switch state {
        case .on(let since, _):
            return t < since + max(attack, 1e-3)
        case .off:
            return at(t) > 1.0 / 512.0
        }
    }
}

/// A single instance in `OneShots<T>`.
public struct OneShot<T: Sendable>: Sendable {
    public var t0: Float
    public var data: T
    public var seed: UInt32
    fileprivate var retired: Float?
}

/// Overlapping one-shot effects: taps, pings, shockwaves, zaps, sparkle bursts.
public struct OneShots<T: Sendable>: Sendable {
    public static var fadeDuration: Float { 0.16 }

    private let cap: Int
    private var shots: [OneShot<T>] = []
    private var count: UInt32 = 0

    public init(cap: Int) {
        self.cap = max(cap, 1)
    }

    public mutating func trigger(at t: Float, data: T) {
        shots.removeAll { s in
            if let r = s.retired { return t - r >= Self.fadeDuration }
            return false
        }
        let active = shots.filter { $0.retired == nil }.count
        if active >= cap, let idx = shots.enumerated()
            .filter({ $0.element.retired == nil })
            .min(by: { $0.element.t0 < $1.element.t0 })?.offset {
            shots[idx].retired = t
        }
        while shots.count >= cap * 2 {
            if let idx = shots.indices.min(by: {
                (shots[$0].retired ?? Float.greatestFiniteMagnitude) < (shots[$1].retired ?? Float.greatestFiniteMagnitude)
            }) {
                shots.remove(at: idx)
            } else {
                break
            }
        }
        count &+= 1
        shots.append(OneShot(t0: t, data: data, seed: RuneFXCPU.hu(count, 0x51ed), retired: nil))
    }

    /// Instances alive at `t` (started less than `life` seconds ago) with their opacity.
    public func live(at t: Float, life: Float) -> [(shot: OneShot<T>, opacity: Float)] {
        shots.compactMap { s in
            let k: Float
            if let r = s.retired {
                let x = min(max((t - r) / Self.fadeDuration, 0.0), 1.0)
                k = 1.0 - x * x * (3.0 - 2.0 * x)
            } else {
                k = 1.0
            }
            return (t - s.t0 < life && k > 0.0) ? (s, k) : nil
        }
    }

    public mutating func prune(at t: Float, life: Float) {
        shots.removeAll { s in
            if t - s.t0 >= life { return true }
            if let r = s.retired { return t - r >= Self.fadeDuration }
            return false
        }
    }

    public func isAnimating(at t: Float, life: Float) -> Bool {
        !live(at: t, life: life).isEmpty
    }

    public mutating func clear() {
        shots.removeAll()
    }
}

// MARK: - Effect Layer & Blend

public enum Place: Sendable, Equatable {
    case under
    case over
}

public struct Source: Sendable, Equatable {
    public var slot: UInt32
    public var rect: FxRect

    public init(slot: UInt32, rect: FxRect) {
        self.slot = slot
        self.rect = rect
    }
}

public let fxNoClip = SIMD4<Float>(-1e6, -1e6, 1e6, 1e6)

public enum FxBlend: Sendable, Equatable, Hashable {
    case normal
    case multiply
    case screen
    case overlay
    case softLight

    public var needsBackdrop: Bool {
        switch self {
        case .multiply, .overlay, .softLight: return true
        case .normal, .screen: return false
        }
    }

    public var cost: FxCost {
        switch self {
        case .normal, .screen:
            return FxCost(passes: 0, samples: 0, alu: 0, backdrop: false, source: false)
        case .multiply, .overlay, .softLight:
            return FxCost(passes: 0, samples: 1, alu: 1, backdrop: true, source: false)
        }
    }

    internal var code: UInt32 {
        switch self {
        case .normal: return 0
        case .multiply: return 1
        case .screen: return 2
        case .overlay: return 3
        case .softLight: return 4
        }
    }
}

public struct FxSlot: Sendable, Equatable {
    public var scale: Float
    public var clip: SIMD4<Float>
    public var fade: SIMD4<UInt32>
    public var backdropSrgb: Bool?
    public var blend: FxBlend

    public init(
        scale: Float = 0.0,
        clip: SIMD4<Float> = fxNoClip,
        fade: SIMD4<UInt32> = .zero,
        backdropSrgb: Bool? = nil,
        blend: FxBlend = .normal
    ) {
        self.scale = scale
        self.clip = clip
        self.fade = fade
        self.backdropSrgb = backdropSrgb
        self.blend = blend
    }
}

public struct FxCost: Sendable, Equatable {
    public var passes: UInt32
    public var samples: UInt32
    public var alu: UInt32
    public var backdrop: Bool
    public var source: Bool

    public init(passes: UInt32, samples: UInt32, alu: UInt32, backdrop: Bool, source: Bool) {
        self.passes = passes
        self.samples = samples
        self.alu = alu
        self.backdrop = backdrop
        self.source = source
    }
}

public enum Fx: Sendable, Equatable {
    case glow(GlowParams)
    case pulse(PulseParams)
    case electric(ElectricParams)
    case fire(FireParams)
    case distort(DistortParams)
    case motionBlur(MotionBlurParams, MotionSamples)
    case shimmer(ShimmerParams)
    case sparkles(SparkleParams)
    case aurora(AuroraParams)
    case grain(GrainParams)
    case fill(FillParams)

    public static func lens(_ p: LensParams) -> Fx { .distort(.lens(p)) }

    public func on(_ shape: FxShape) -> FxLayer {
        let place: Place
        switch self {
        case .glow, .pulse, .fire, .aurora:
            place = .under
        case .fill(let p) where !p.needsBackdrop:
            place = .under
        default:
            place = .over
        }
        return FxLayer(fx: self, shape: shape, place: place)
    }

    public var needsBackdrop: Bool {
        switch self {
        case .distort: return true
        case .fill(let p): return p.needsBackdrop
        default: return false
        }
    }

    public var cost: FxCost {
        func c(_ samples: UInt32, _ alu: UInt32) -> FxCost {
            FxCost(passes: 1, samples: samples, alu: alu, backdrop: false, source: false)
        }
        switch self {
        case .glow(let p):
            switch p.style {
            case .mask: return FxCost(passes: 1, samples: 13, alu: 0, backdrop: false, source: true)
            case .aura: return c(0, 1)
            default: return c(0, 0)
            }
        case .pulse:
            return c(0, 0)
        case .electric(let p):
            let s = min(max(p.strands, 1), 3)
            switch p.style {
            case .arc: return c(1 + s * 4 + 4 * 6, 0)
            case .border: return c(1 + s * 6 + 5 * 6, 0)
            case .charged: return c(1 + 6 + 5 * 6, 0)
            }
        case .fire(let p):
            let alu: UInt32 = switch p.style {
            case .embers: 0
            case .border: 3
            default: 8
            }
            return c(min(p.embers, 40) * 2, alu)
        case .distort(let d):
            let (s, a): (UInt32, UInt32) = switch d {
            case .heatHaze: (1, 6)
            case .shockwave: (3, 0)
            case .lens(let l): (l.frost > 0 ? 12 : 12, 0)
            case .crt: (7, 0)
            case .chromaSplit: (3, 0)
            }
            return FxCost(passes: 1, samples: s, alu: a, backdrop: true, source: false)
        case .motionBlur(_, let ms):
            return FxCost(passes: 1, samples: ms.count, alu: 0, backdrop: false, source: true)
        case .shimmer(let p):
            return FxCost(passes: 1, samples: p.useMask ? 1 : 0, alu: 0, backdrop: false, source: p.useMask)
        case .sparkles(let p):
            return c(min(p.count, 64) * 2, 0)
        case .aurora:
            return c(12, 3)
        case .grain:
            return c(0, 0)
        case .fill(let p):
            return p.cost
        }
    }
}

public struct FxLayer: Sendable, Equatable {
    public var fx: Fx
    public var shape: FxShape
    public var place: Place
    public var time: Float
    public var seed: UInt32
    public var reducedMotion: Bool
    public var source: Source?
    public var opacity: Float

    public init(
        fx: Fx,
        shape: FxShape,
        place: Place = .over,
        time: Float = 0.0,
        seed: UInt32 = 1,
        reducedMotion: Bool = false,
        source: Source? = nil,
        opacity: Float = 1.0
    ) {
        self.fx = fx
        self.shape = shape
        self.place = place
        self.time = time
        self.seed = seed
        self.reducedMotion = reducedMotion
        self.source = source
        self.opacity = opacity
    }

    public func at(_ t: Float) -> FxLayer { var copy = self; copy.time = t; return copy }
    public func seed(_ s: UInt32) -> FxLayer { var copy = self; copy.seed = s; return copy }
    public func over() -> FxLayer { var copy = self; copy.place = .over; return copy }
    public func under() -> FxLayer { var copy = self; copy.place = .under; return copy }
    public func reduced(_ on: Bool) -> FxLayer { var copy = self; copy.reducedMotion = on; return copy }
    public func source(slot: UInt32, rect: FxRect) -> FxLayer { var copy = self; copy.source = Source(slot: slot, rect: rect); return copy }
    public func opacity(_ k: Float) -> FxLayer { var copy = self; copy.opacity = k; return copy }

    public var isSilent: Bool {
        if !(opacity > 0.0) { return true }
        switch fx {
        case .glow(let p): return p.intensity <= 0.0 || p.heat <= 0.0
        case .pulse(let p): return p.intensity <= 0.0
        case .electric(let p): return p.intensity <= 0.0
        case .fire(let p): return p.intensity <= 0.0
        case .distort(.heatHaze(_, _, _, let amount, _)),
             .distort(.shockwave(_, _, _, let amount, _, _, _)):
            return amount <= 0.0
        case .distort(.chromaSplit(let offset, let glitch, _)):
            return offset == .zero && glitch <= 0.0
        case .distort(.lens), .distort(.crt):
            return false
        case .motionBlur:
            return source == nil
        case .shimmer(let p):
            return p.intensity <= 0.0 && p.baseAlpha <= 0.0
        case .sparkles(let p):
            return p.intensity <= 0.0 || p.count == 0
        case .aurora(let p):
            return p.intensity <= 0.0
        case .grain(let p):
            return p.amount <= 0.0
        case .fill(let p):
            return p.drawsNothing(in: shape.rect)
        }
    }

    public var isAnimating: Bool {
        if isSilent { return false }
        let t = time
        let rm = reducedMotion
        switch fx {
        case .glow(let p):
            return (p.breathe > 0.0 && !rm) || (p.style == .aura && p.auraSpeed > 0.0 && !rm)
        case .pulse(let p):
            switch p.style {
            case .ping: return p.repeatInterval > 0.0 || t < p.t0 + p.duration * FxPackConstants.pingLife
            case .ripple: return t < p.t0 + p.duration
            default: return !rm
            }
        case .distort(.shockwave(_, _, _, _, _, let t0, let duration)):
            return t < t0 + duration
        case .distort(.lens):
            return false
        case .distort(.chromaSplit(_, let glitch, _)):
            return glitch > 0.0 && !rm
        case .motionBlur(_, let s):
            return s.isMoving
        case .grain(let g):
            return g.fps > 0.0 && !rm
        case .fill(let p):
            return p.animates && !rm
        case .electric(let p):
            if let t0 = p.zap { return t < t0 + ElectricParams.zapLife }
            return !rm
        case .sparkles(let p):
            if let t0 = p.burst { return t < t0 + p.burstLife }
            return !rm
        default:
            return !rm
        }
    }
}
