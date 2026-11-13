import Foundation

/// How a numeric parameter reads in an inspector.
public enum FxUnit: Sendable, Equatable {
    case none
    /// Points.
    case pt
    /// Radians (display as degrees).
    case radians
    /// 0..1 fraction (display as percentage).
    case fraction
    /// Per second (speeds, rates).
    case perSecond
}

/// One option of a choice parameter.
public struct FxChoice: Sendable, Equatable {
    public let id: String
    public let name: String
    public let swiftLiteral: String

    public init(id: String, name: String, swiftLiteral: String) {
        self.id = id
        self.name = name
        self.swiftLiteral = swiftLiteral
    }
}

/// The kind and valid range of a tunable fill parameter.
public enum FxParamKind: Sendable, Equatable {
    case number(min: Float, max: Float, step: Float, unit: FxUnit)
    case count(min: UInt32, max: UInt32)
    case toggle
    case choice([FxChoice])
    case color
    case colors(min: Int, max: Int)
    case point
    case points(max: Int)
}

/// A tunable parameter in the fill catalog.
public struct FxParam: Sendable, Equatable {
    public let id: String
    public let name: String
    public let kind: FxParamKind

    public init(id: String, name: String, kind: FxParamKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

/// A parameter's runtime value.
public enum FxValue: Sendable, Equatable {
    case number(Float)
    case count(UInt32)
    case toggle(Bool)
    case choice(Int)
    case color(Rgb)
    case colors(Stops)
    case point(SIMD2<Float>)
    case points([SIMD2<Float>])

    fileprivate var finiteFloat: Float? {
        switch self {
        case .number(let x) where x.isFinite: return x
        case .count(let n): return Float(n)
        default: return nil
        }
    }
}

private func assignFloat(_ value: FxValue, to field: inout Float) -> Bool {
    guard let x = value.finiteFloat else { return false }
    field = x
    return true
}

/// A named preset for a fill style.
public struct FxPreset: Sendable {
    public let id: String
    public let name: String
    public let swiftCode: String
    private let makeStyle: @Sendable () -> FillStyle

    public init(
        id: String,
        name: String,
        swiftCode: String,
        make: @escaping @Sendable () -> FillStyle
    ) {
        self.id = id
        self.name = name
        self.swiftCode = swiftCode
        self.makeStyle = make
    }

    public func style() -> FillStyle {
        makeStyle()
    }

    public func fill() -> FillParams {
        FillParams(style())
    }
}

/// A fill style's catalog metadata entry.
public struct FxStyleInfo: Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let swiftType: String
    public let params: [FxParam]
    public let presets: [FxPreset]
    public let readsBackdrop: Bool

    public init(
        id: String,
        name: String,
        summary: String,
        swiftType: String,
        params: [FxParam],
        presets: [FxPreset],
        readsBackdrop: Bool
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.swiftType = swiftType
        self.params = params
        self.presets = presets
        self.readsBackdrop = readsBackdrop
    }

    public func preset(_ id: String) -> FxPreset? {
        presets.first { $0.id == id }
    }

    public func defaultFill() -> FillParams {
        presets[0].fill()
    }
}

// Upstream-compatible typealiases
public typealias Unit = FxUnit
public typealias Choice = FxChoice
public typealias ParamKind = FxParamKind
public typealias Param = FxParam
public typealias Value = FxValue
public typealias Preset = FxPreset
public typealias StyleInfo = FxStyleInfo

private func num(_ min: Float, _ max: Float, _ step: Float, _ unit: FxUnit) -> FxParamKind {
    .number(min: min, max: max, step: step, unit: unit)
}

// MARK: - Choice tables

extension FillInput {
    public static let choices: [FxChoice] = [
        FxChoice(id: "linear", name: "Linear", swiftLiteral: ".linear"),
        FxChoice(id: "radial", name: "Radial", swiftLiteral: ".radial"),
        FxChoice(id: "noise", name: "Noise", swiftLiteral: ".noise"),
        FxChoice(id: "backdrop", name: "Backdrop", swiftLiteral: ".backdrop"),
        FxChoice(id: "image", name: "Image", swiftLiteral: ".image"),
    ]

    fileprivate static let allOptions: [FillInput] = [.linear, .radial, .noise, .backdrop, .image]
}

extension DitherPattern {
    public static let choices: [FxChoice] = [
        FxChoice(id: "bayer2", name: "Bayer 2×2", swiftLiteral: ".bayer2"),
        FxChoice(id: "bayer4", name: "Bayer 4×4", swiftLiteral: ".bayer4"),
        FxChoice(id: "bayer8", name: "Bayer 8×8", swiftLiteral: ".bayer8"),
        FxChoice(id: "blue_noise", name: "Blue noise", swiftLiteral: ".blueNoise"),
        FxChoice(id: "white", name: "White noise", swiftLiteral: ".white"),
    ]

    fileprivate static let allOptions: [DitherPattern] = [.bayer2, .bayer4, .bayer8, .blueNoise, .white]
}

extension GradientKind {
    public static let choices: [FxChoice] = [
        FxChoice(id: "linear", name: "Linear", swiftLiteral: ".linear"),
        FxChoice(id: "radial", name: "Radial", swiftLiteral: ".radial"),
        FxChoice(id: "conic", name: "Conic", swiftLiteral: ".conic"),
    ]

    fileprivate static let allOptions: [GradientKind] = [.linear, .radial, .conic]
}

extension FillAnchor {
    public static let choices: [FxChoice] = [
        FxChoice(id: "world", name: "World", swiftLiteral: ".world"),
        FxChoice(id: "element", name: "Element", swiftLiteral: ".element"),
    ]

    fileprivate static let allOptions: [FillAnchor] = [.world, .element]
}

// MARK: - Param tables

extension LiquidMetalParams {
    public static let params: [FxParam] = [
        FxParam(id: "tint", name: "Tint", kind: .color),
        FxParam(id: "light", name: "Light", kind: .color),
        FxParam(id: "flow", name: "Flow", kind: num(0.0, 1.5, 0.01, .none)),
        FxParam(id: "scale", name: "Scale", kind: num(16.0, 480.0, 1.0, .pt)),
        FxParam(id: "speed", name: "Speed", kind: num(0.0, 2.0, 0.01, .perSecond)),
        FxParam(id: "bevel", name: "Bevel", kind: num(0.0, 48.0, 0.5, .pt)),
        FxParam(id: "dome", name: "Dome", kind: num(0.0, 1.0, 0.01, .fraction)),
        FxParam(id: "angle", name: "Angle", kind: num(-3.14159, 3.14159, 0.01, .radians)),
        FxParam(id: "iridescence", name: "Iridescence", kind: num(0.0, 1.0, 0.01, .fraction)),
        FxParam(id: "contrast", name: "Contrast", kind: num(0.5, 2.0, 0.01, .none)),
        FxParam(id: "anchor", name: "Anchor", kind: .choice(FillAnchor.choices)),
    ]

    fileprivate func getParam(_ id: String) -> FxValue? {
        switch id {
        case "tint": return .color(tint)
        case "light": return .color(light)
        case "flow": return .number(flow)
        case "scale": return .number(scale)
        case "speed": return .number(speed)
        case "bevel": return .number(bevel)
        case "dome": return .number(dome)
        case "angle": return .number(angle)
        case "iridescence": return .number(iridescence)
        case "contrast": return .number(contrast)
        case "anchor": return .choice(FillAnchor.allOptions.firstIndex(of: anchor) ?? 0)
        default: return nil
        }
    }

    fileprivate mutating func setParam(_ id: String, _ v: FxValue) -> Bool {
        switch id {
        case "tint":
            guard case .color(let c) = v else { return false }
            tint = c
            return true
        case "light":
            guard case .color(let c) = v else { return false }
            light = c
            return true
        case "flow": return assignFloat(v, to: &flow)
        case "scale": return assignFloat(v, to: &scale)
        case "speed": return assignFloat(v, to: &speed)
        case "bevel": return assignFloat(v, to: &bevel)
        case "dome": return assignFloat(v, to: &dome)
        case "angle": return assignFloat(v, to: &angle)
        case "iridescence": return assignFloat(v, to: &iridescence)
        case "contrast": return assignFloat(v, to: &contrast)
        case "anchor":
            guard case .choice(let i) = v, i >= 0 && i < FillAnchor.allOptions.count else { return false }
            anchor = FillAnchor.allOptions[i]
            return true
        default:
            return false
        }
    }
}

extension PlasticParams {
    public static let params: [FxParam] = [
        FxParam(id: "color", name: "Colour", kind: .color),
        FxParam(id: "roughness", name: "Roughness", kind: num(0.05, 1.0, 0.01, .fraction)),
        FxParam(id: "dome", name: "Dome", kind: num(-1.0, 1.0, 0.01, .none)),
        FxParam(id: "bevel", name: "Bevel", kind: num(0.0, 48.0, 0.5, .pt)),
        FxParam(id: "angle", name: "Light angle", kind: num(-3.14159, 3.14159, 0.01, .radians)),
    ]

    fileprivate func getParam(_ id: String) -> FxValue? {
        switch id {
        case "color": return .color(color)
        case "roughness": return .number(roughness)
        case "dome": return .number(dome)
        case "bevel": return .number(bevel)
        case "angle": return .number(angle)
        default: return nil
        }
    }

    fileprivate mutating func setParam(_ id: String, _ v: FxValue) -> Bool {
        switch id {
        case "color":
            guard case .color(let c) = v else { return false }
            color = c
            return true
        case "roughness": return assignFloat(v, to: &roughness)
        case "dome": return assignFloat(v, to: &dome)
        case "bevel": return assignFloat(v, to: &bevel)
        case "angle": return assignFloat(v, to: &angle)
        default:
            return false
        }
    }
}

extension MeshGradientParams {
    public static let params: [FxParam] = [
        FxParam(id: "colors", name: "Colours", kind: .colors(min: 2, max: maxStops)),
        FxParam(id: "points", name: "Points", kind: .points(max: maxStops)),
        FxParam(id: "drift", name: "Drift", kind: num(0.0, 0.4, 0.01, .fraction)),
        FxParam(id: "speed", name: "Speed", kind: num(0.0, 2.0, 0.01, .perSecond)),
        FxParam(id: "sharpness", name: "Sharpness", kind: num(0.5, 4.0, 0.01, .none)),
        FxParam(id: "warp", name: "Warp", kind: num(0.0, 1.0, 0.01, .none)),
    ]

    fileprivate func getParam(_ id: String) -> FxValue? {
        switch id {
        case "colors": return .colors(colors)
        case "points": return .points(points)
        case "drift": return .number(drift)
        case "speed": return .number(speed)
        case "sharpness": return .number(sharpness)
        case "warp": return .number(warp)
        default: return nil
        }
    }

    fileprivate mutating func setParam(_ id: String, _ v: FxValue) -> Bool {
        switch id {
        case "colors":
            guard case .colors(let s) = v else { return false }
            colors = s
            return true
        case "points":
            guard case .points(let pts) = v, pts.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
            var padded = Array(pts.prefix(maxStops))
            while padded.count < maxStops { padded.append(.zero) }
            points = padded
            return true
        case "drift": return assignFloat(v, to: &drift)
        case "speed": return assignFloat(v, to: &speed)
        case "sharpness": return assignFloat(v, to: &sharpness)
        case "warp": return assignFloat(v, to: &warp)
        default:
            return false
        }
    }
}

extension DitherParams {
    public static let params: [FxParam] = [
        FxParam(id: "pattern", name: "Pattern", kind: .choice(DitherPattern.choices)),
        FxParam(id: "input", name: "Input", kind: .choice(FillInput.choices)),
        FxParam(id: "colors", name: "Colours", kind: .colors(min: 2, max: maxStops)),
        FxParam(id: "pixel", name: "Pixel", kind: num(0.5, 16.0, 0.5, .pt)),
        FxParam(id: "angle", name: "Angle", kind: num(-3.14159, 3.14159, 0.01, .radians)),
        FxParam(id: "scale", name: "Noise scale", kind: num(8.0, 400.0, 1.0, .pt)),
        FxParam(id: "speed", name: "Speed", kind: num(0.0, 2.0, 0.01, .perSecond)),
        FxParam(id: "bias", name: "Bias", kind: num(-1.0, 1.0, 0.01, .none)),
        FxParam(id: "contrast", name: "Contrast", kind: num(0.2, 4.0, 0.01, .none)),
    ]

    fileprivate func getParam(_ id: String) -> FxValue? {
        switch id {
        case "pattern": return .choice(DitherPattern.allOptions.firstIndex(of: pattern) ?? 0)
        case "input": return .choice(FillInput.allOptions.firstIndex(of: input) ?? 0)
        case "colors": return .colors(colors)
        case "pixel": return .number(pixel)
        case "angle": return .number(angle)
        case "scale": return .number(scale)
        case "speed": return .number(speed)
        case "bias": return .number(bias)
        case "contrast": return .number(contrast)
        default: return nil
        }
    }

    fileprivate mutating func setParam(_ id: String, _ v: FxValue) -> Bool {
        switch id {
        case "pattern":
            guard case .choice(let i) = v, i >= 0 && i < DitherPattern.allOptions.count else { return false }
            pattern = DitherPattern.allOptions[i]
            return true
        case "input":
            guard case .choice(let i) = v, i >= 0 && i < FillInput.allOptions.count else { return false }
            input = FillInput.allOptions[i]
            return true
        case "colors":
            guard case .colors(let s) = v else { return false }
            colors = s
            return true
        case "pixel": return assignFloat(v, to: &pixel)
        case "angle": return assignFloat(v, to: &angle)
        case "scale": return assignFloat(v, to: &scale)
        case "speed": return assignFloat(v, to: &speed)
        case "bias": return assignFloat(v, to: &bias)
        case "contrast": return assignFloat(v, to: &contrast)
        default:
            return false
        }
    }
}

extension GrainGradientParams {
    public static let params: [FxParam] = [
        FxParam(id: "kind", name: "Kind", kind: .choice(GradientKind.choices)),
        FxParam(id: "colors", name: "Colours", kind: .colors(min: 2, max: maxStops)),
        FxParam(id: "angle", name: "Angle", kind: num(-3.14159, 3.14159, 0.01, .radians)),
        FxParam(id: "center", name: "Centre", kind: .point),
        FxParam(id: "amount", name: "Grain", kind: num(0.0, 1.0, 0.01, .fraction)),
        FxParam(id: "size", name: "Grain size", kind: num(0.5, 8.0, 0.25, .pt)),
        FxParam(id: "mono", name: "Mono", kind: .toggle),
        FxParam(id: "fps", name: "Grain rate", kind: num(0.0, 30.0, 1.0, .perSecond)),
    ]

    fileprivate func getParam(_ id: String) -> FxValue? {
        switch id {
        case "kind": return .choice(GradientKind.allOptions.firstIndex(of: kind) ?? 0)
        case "colors": return .colors(colors)
        case "angle": return .number(angle)
        case "center": return .point(center)
        case "amount": return .number(amount)
        case "size": return .number(size)
        case "mono": return .toggle(mono)
        case "fps": return .number(fps)
        default: return nil
        }
    }

    fileprivate mutating func setParam(_ id: String, _ v: FxValue) -> Bool {
        switch id {
        case "kind":
            guard case .choice(let i) = v, i >= 0 && i < GradientKind.allOptions.count else { return false }
            kind = GradientKind.allOptions[i]
            return true
        case "colors":
            guard case .colors(let s) = v else { return false }
            colors = s
            return true
        case "angle": return assignFloat(v, to: &angle)
        case "center":
            guard case .point(let p) = v, p.x.isFinite && p.y.isFinite else { return false }
            center = p
            return true
        case "amount": return assignFloat(v, to: &amount)
        case "size": return assignFloat(v, to: &size)
        case "mono":
            guard case .toggle(let b) = v else { return false }
            mono = b
            return true
        case "fps": return assignFloat(v, to: &fps)
        default:
            return false
        }
    }
}

extension FlutedGlassParams {
    public static let params: [FxParam] = [
        FxParam(id: "rib", name: "Rib width", kind: num(2.0, 64.0, 0.5, .pt)),
        FxParam(id: "angle", name: "Angle", kind: num(-3.14159, 3.14159, 0.01, .radians)),
        FxParam(id: "refraction", name: "Refraction", kind: num(0.0, 40.0, 0.5, .pt)),
        FxParam(id: "frost", name: "Frost", kind: num(0.0, 1.0, 0.01, .fraction)),
        FxParam(id: "dispersion", name: "Dispersion", kind: num(0.0, 1.0, 0.01, .fraction)),
        FxParam(id: "highlight", name: "Highlight", kind: num(0.0, 1.0, 0.01, .fraction)),
        FxParam(id: "tint", name: "Tint", kind: .color),
        FxParam(id: "tint_amount", name: "Tint amount", kind: num(0.0, 1.0, 0.01, .fraction)),
    ]

    fileprivate func getParam(_ id: String) -> FxValue? {
        switch id {
        case "rib": return .number(rib)
        case "angle": return .number(angle)
        case "refraction": return .number(refraction)
        case "frost": return .number(frost)
        case "dispersion": return .number(dispersion)
        case "highlight": return .number(highlight)
        case "tint": return .color(tint)
        case "tint_amount", "tintAmount": return .number(tintAmount)
        default: return nil
        }
    }

    fileprivate mutating func setParam(_ id: String, _ v: FxValue) -> Bool {
        switch id {
        case "rib": return assignFloat(v, to: &rib)
        case "angle": return assignFloat(v, to: &angle)
        case "refraction": return assignFloat(v, to: &refraction)
        case "frost": return assignFloat(v, to: &frost)
        case "dispersion": return assignFloat(v, to: &dispersion)
        case "highlight": return assignFloat(v, to: &highlight)
        case "tint":
            guard case .color(let c) = v else { return false }
            tint = c
            return true
        case "tint_amount", "tintAmount": return assignFloat(v, to: &tintAmount)
        default:
            return false
        }
    }
}

extension MetaballParams {
    public static let params: [FxParam] = [
        FxParam(id: "colors", name: "Colours", kind: .colors(min: 1, max: maxStops)),
        FxParam(id: "base", name: "Base", kind: .color),
        FxParam(id: "count", name: "Count", kind: .count(min: 1, max: 8)),
        FxParam(id: "size", name: "Size", kind: num(0.05, 0.5, 0.01, .fraction)),
        FxParam(id: "speed", name: "Speed", kind: num(0.0, 2.0, 0.01, .perSecond)),
        FxParam(id: "gloss", name: "Gloss", kind: num(0.0, 1.0, 0.01, .fraction)),
    ]

    fileprivate func getParam(_ id: String) -> FxValue? {
        switch id {
        case "colors": return .colors(colors)
        case "base": return .color(base)
        case "count": return .count(count)
        case "size": return .number(size)
        case "speed": return .number(speed)
        case "gloss": return .number(gloss)
        default: return nil
        }
    }

    fileprivate mutating func setParam(_ id: String, _ v: FxValue) -> Bool {
        switch id {
        case "colors":
            guard case .colors(let s) = v else { return false }
            colors = s
            return true
        case "base":
            guard case .color(let c) = v else { return false }
            base = c
            return true
        case "count":
            if case .count(let n) = v {
                count = n
                return true
            }
            if case .number(let x) = v, x.isFinite {
                count = UInt32(max(0.0, x.rounded()))
                return true
            }
            return false
        case "size": return assignFloat(v, to: &size)
        case "speed": return assignFloat(v, to: &speed)
        case "gloss": return assignFloat(v, to: &gloss)
        default:
            return false
        }
    }
}

extension SwirlParams {
    public static let params: [FxParam] = [
        FxParam(id: "colors", name: "Colours", kind: .colors(min: 2, max: maxStops)),
        FxParam(id: "scale", name: "Scale", kind: num(16.0, 480.0, 1.0, .pt)),
        FxParam(id: "speed", name: "Speed", kind: num(0.0, 2.0, 0.01, .perSecond)),
        FxParam(id: "twist", name: "Twist", kind: num(-2.0, 2.0, 0.01, .none)),
        FxParam(id: "warp", name: "Warp", kind: num(0.0, 2.5, 0.01, .none)),
    ]

    fileprivate func getParam(_ id: String) -> FxValue? {
        switch id {
        case "colors": return .colors(colors)
        case "scale": return .number(scale)
        case "speed": return .number(speed)
        case "twist": return .number(twist)
        case "warp": return .number(warp)
        default: return nil
        }
    }

    fileprivate mutating func setParam(_ id: String, _ v: FxValue) -> Bool {
        switch id {
        case "colors":
            guard case .colors(let s) = v else { return false }
            colors = s
            return true
        case "scale": return assignFloat(v, to: &scale)
        case "speed": return assignFloat(v, to: &speed)
        case "twist": return assignFloat(v, to: &twist)
        case "warp": return assignFloat(v, to: &warp)
        default:
            return false
        }
    }
}

extension VoronoiParams {
    public static let params: [FxParam] = [
        FxParam(id: "colors", name: "Colours", kind: .colors(min: 1, max: maxStops)),
        FxParam(id: "edge_color", name: "Seam colour", kind: .color),
        FxParam(id: "scale", name: "Cell size", kind: num(6.0, 200.0, 1.0, .pt)),
        FxParam(id: "speed", name: "Speed", kind: num(0.0, 2.0, 0.01, .perSecond)),
        FxParam(id: "edge", name: "Seam", kind: num(0.0, 8.0, 0.25, .pt)),
        FxParam(id: "depth", name: "Depth", kind: num(0.0, 1.0, 0.01, .fraction)),
    ]

    fileprivate func getParam(_ id: String) -> FxValue? {
        switch id {
        case "colors": return .colors(colors)
        case "edge_color", "edgeColor": return .color(edgeColor)
        case "scale": return .number(scale)
        case "speed": return .number(speed)
        case "edge": return .number(edge)
        case "depth": return .number(depth)
        default: return nil
        }
    }

    fileprivate mutating func setParam(_ id: String, _ v: FxValue) -> Bool {
        switch id {
        case "colors":
            guard case .colors(let s) = v else { return false }
            colors = s
            return true
        case "edge_color", "edgeColor":
            guard case .color(let c) = v else { return false }
            edgeColor = c
            return true
        case "scale": return assignFloat(v, to: &scale)
        case "speed": return assignFloat(v, to: &speed)
        case "edge": return assignFloat(v, to: &edge)
        case "depth": return assignFloat(v, to: &depth)
        default:
            return false
        }
    }
}

extension WaveParams {
    public static let params: [FxParam] = [
        FxParam(id: "colors", name: "Colours", kind: .colors(min: 2, max: maxStops)),
        FxParam(id: "amplitude", name: "Amplitude", kind: num(0.0, 0.25, 0.005, .fraction)),
        FxParam(id: "frequency", name: "Frequency", kind: num(0.2, 6.0, 0.05, .none)),
        FxParam(id: "speed", name: "Speed", kind: num(0.0, 2.0, 0.01, .perSecond)),
        FxParam(id: "angle", name: "Angle", kind: num(-3.14159, 3.14159, 0.01, .radians)),
        FxParam(id: "softness", name: "Softness", kind: num(0.0, 0.1, 0.001, .fraction)),
    ]

    fileprivate func getParam(_ id: String) -> FxValue? {
        switch id {
        case "colors": return .colors(colors)
        case "amplitude": return .number(amplitude)
        case "frequency": return .number(frequency)
        case "speed": return .number(speed)
        case "angle": return .number(angle)
        case "softness": return .number(softness)
        default: return nil
        }
    }

    fileprivate mutating func setParam(_ id: String, _ v: FxValue) -> Bool {
        switch id {
        case "colors":
            guard case .colors(let s) = v else { return false }
            colors = s
            return true
        case "amplitude": return assignFloat(v, to: &amplitude)
        case "frequency": return assignFloat(v, to: &frequency)
        case "speed": return assignFloat(v, to: &speed)
        case "angle": return assignFloat(v, to: &angle)
        case "softness": return assignFloat(v, to: &softness)
        default:
            return false
        }
    }
}

extension HalftoneParams {
    public static let params: [FxParam] = [
        FxParam(id: "input", name: "Input", kind: .choice(FillInput.choices)),
        FxParam(id: "ink", name: "Ink", kind: .color),
        FxParam(id: "base", name: "Base", kind: .color),
        FxParam(id: "cell", name: "Dot pitch", kind: num(2.0, 32.0, 0.5, .pt)),
        FxParam(id: "angle", name: "Screen angle", kind: num(-3.14159, 3.14159, 0.01, .radians)),
        FxParam(id: "ramp_angle", name: "Ramp angle", kind: num(-3.14159, 3.14159, 0.01, .radians)),
        FxParam(id: "scale", name: "Noise scale", kind: num(8.0, 400.0, 1.0, .pt)),
        FxParam(id: "speed", name: "Speed", kind: num(0.0, 2.0, 0.01, .perSecond)),
        FxParam(id: "bias", name: "Bias", kind: num(-1.0, 1.0, 0.01, .none)),
        FxParam(id: "contrast", name: "Contrast", kind: num(0.2, 4.0, 0.01, .none)),
    ]

    fileprivate func getParam(_ id: String) -> FxValue? {
        switch id {
        case "input": return .choice(FillInput.allOptions.firstIndex(of: input) ?? 0)
        case "ink": return .color(ink)
        case "base": return .color(base)
        case "cell": return .number(cell)
        case "angle": return .number(angle)
        case "ramp_angle", "rampAngle": return .number(rampAngle)
        case "scale": return .number(scale)
        case "speed": return .number(speed)
        case "bias": return .number(bias)
        case "contrast": return .number(contrast)
        default: return nil
        }
    }

    fileprivate mutating func setParam(_ id: String, _ v: FxValue) -> Bool {
        switch id {
        case "input":
            guard case .choice(let i) = v, i >= 0 && i < FillInput.allOptions.count else { return false }
            input = FillInput.allOptions[i]
            return true
        case "ink":
            guard case .color(let c) = v else { return false }
            ink = c
            return true
        case "base":
            guard case .color(let c) = v else { return false }
            base = c
            return true
        case "cell": return assignFloat(v, to: &cell)
        case "angle": return assignFloat(v, to: &angle)
        case "ramp_angle", "rampAngle": return assignFloat(v, to: &rampAngle)
        case "scale": return assignFloat(v, to: &scale)
        case "speed": return assignFloat(v, to: &speed)
        case "bias": return assignFloat(v, to: &bias)
        case "contrast": return assignFloat(v, to: &contrast)
        default:
            return false
        }
    }
}

// MARK: - FillStyle & FillParams catalog accessors

extension FillStyle {
    fileprivate func getParam(_ id: String) -> FxValue? {
        switch self {
        case .liquidMetal(let p): return p.getParam(id)
        case .meshGradient(let p): return p.getParam(id)
        case .dither(let p): return p.getParam(id)
        case .grainGradient(let p): return p.getParam(id)
        case .flutedGlass(let p): return p.getParam(id)
        case .metaballs(let p): return p.getParam(id)
        case .swirl(let p): return p.getParam(id)
        case .voronoi(let p): return p.getParam(id)
        case .waves(let p): return p.getParam(id)
        case .halftone(let p): return p.getParam(id)
        case .plastic(let p): return p.getParam(id)
        }
    }

    fileprivate mutating func setParam(_ id: String, _ v: FxValue) -> Bool {
        switch self {
        case .liquidMetal(var p):
            let ok = p.setParam(id, v)
            if ok { self = .liquidMetal(p) }
            return ok
        case .meshGradient(var p):
            let ok = p.setParam(id, v)
            if ok { self = .meshGradient(p) }
            return ok
        case .dither(var p):
            let ok = p.setParam(id, v)
            if ok { self = .dither(p) }
            return ok
        case .grainGradient(var p):
            let ok = p.setParam(id, v)
            if ok { self = .grainGradient(p) }
            return ok
        case .flutedGlass(var p):
            let ok = p.setParam(id, v)
            if ok { self = .flutedGlass(p) }
            return ok
        case .metaballs(var p):
            let ok = p.setParam(id, v)
            if ok { self = .metaballs(p) }
            return ok
        case .swirl(var p):
            let ok = p.setParam(id, v)
            if ok { self = .swirl(p) }
            return ok
        case .voronoi(var p):
            let ok = p.setParam(id, v)
            if ok { self = .voronoi(p) }
            return ok
        case .waves(var p):
            let ok = p.setParam(id, v)
            if ok { self = .waves(p) }
            return ok
        case .halftone(var p):
            let ok = p.setParam(id, v)
            if ok { self = .halftone(p) }
            return ok
        case .plastic(var p):
            let ok = p.setParam(id, v)
            if ok { self = .plastic(p) }
            return ok
        }
    }
}

extension FillParams {
    /// Params every fill style has.
    public static let commonParams: [FxParam] = [
        FxParam(id: "border", name: "Border", kind: num(0.0, 32.0, 0.5, .pt)),
        FxParam(id: "intensity", name: "Intensity", kind: num(0.0, 1.0, 0.01, .fraction)),
    ]

    /// This style's catalog entry.
    public var info: FxStyleInfo {
        fillStyles()[style.index]
    }

    /// A param's value, common or the style's own, by id.
    public func get(_ id: String) -> FxValue? {
        switch id {
        case "border": return .number(border)
        case "intensity": return .number(intensity)
        default: return style.getParam(id)
        }
    }

    /// Set a param by id. Returns `false` when the id is unknown or the value has the wrong kind.
    @discardableResult
    public mutating func set(_ id: String, _ value: FxValue) -> Bool {
        switch id {
        case "border": return assignFloat(value, to: &border)
        case "intensity": return assignFloat(value, to: &intensity)
        default:
            return style.setParam(id, value)
        }
    }

    /// Swift source that rebuilds these params as `Fx.fill(FillParams(...))`, written against the closest preset.
    public func toSwift() -> String {
        let info = self.info
        var best: (count: Int, preset: FxPreset, diff: [String])?
        for preset in info.presets {
            let base = preset.style()
            var diff: [String] = []
            for param in info.params {
                guard let val = style.getParam(param.id),
                      base.getParam(param.id) != val else { continue }
                let field = Self.swiftFieldName(param.id)
                let lit = Self.swiftLiteral(val, param: param)
                diff.append("p.\(field) = \(lit)")
            }
            if best == nil || diff.count < best!.count {
                best = (diff.count, preset, diff)
            }
        }
        guard let (_, preset, diff) = best else {
            return "Fx.fill(FillParams(\(Self.swiftCaseName(style))(/* ... */)))"
        }
        let styleExpr: String
        if diff.isEmpty {
            styleExpr = preset.swiftCode
        } else {
            styleExpr = "{ var p = \(preset.swiftCode); \(diff.joined(separator: "; ")); return p }()"
        }
        var expr = "FillParams(\(Self.swiftCaseName(style))(\(styleExpr)))"
        if border != 0.0 {
            expr += ".border(\(Self.swiftFloat(border)))"
        }
        if intensity != 1.0 {
            expr += ".intensity(\(Self.swiftFloat(intensity)))"
        }
        return "Fx.fill(\(expr))"
    }

    private static func swiftFloat(_ v: Float) -> String {
        let x: Float = v.isFinite ? v : 0.0
        let s = String(x)
        return (s.contains(".") || s.contains("e") || s.contains("E")) ? s : "\(s).0"
    }

    private static func swiftFieldName(_ id: String) -> String {
        switch id {
        case "tint_amount": return "tintAmount"
        case "edge_color": return "edgeColor"
        case "ramp_angle": return "rampAngle"
        default: return id
        }
    }

    private static func swiftCaseName(_ style: FillStyle) -> String {
        switch style {
        case .liquidMetal: return ".liquidMetal"
        case .meshGradient: return ".meshGradient"
        case .dither: return ".dither"
        case .grainGradient: return ".grainGradient"
        case .flutedGlass: return ".flutedGlass"
        case .metaballs: return ".metaballs"
        case .swirl: return ".swirl"
        case .voronoi: return ".voronoi"
        case .waves: return ".waves"
        case .halftone: return ".halftone"
        case .plastic: return ".plastic"
        }
    }

    private static func swiftLiteral(_ value: FxValue, param: FxParam) -> String {
        switch value {
        case .number(let x):
            return swiftFloat(x)
        case .count(let n):
            return String(n)
        case .toggle(let b):
            return b ? "true" : "false"
        case .choice(let idx):
            if case .choice(let choices) = param.kind, idx >= 0, idx < choices.count {
                return choices[idx].swiftLiteral
            }
            return "0"
        case .color(let c):
            return String(format: "rgb(0x%06x)", c.hex())
        case .colors(let stops):
            let hexes = stops.colors.map { String(format: "0x%06x", $0.hex()) }.joined(separator: ", ")
            return "Stops.hex([\(hexes)])"
        case .point(let p):
            return "SIMD2<Float>(\(swiftFloat(p.x)), \(swiftFloat(p.y)))"
        case .points(let pts):
            let items = pts.map { "SIMD2<Float>(\(swiftFloat($0.x)), \(swiftFloat($0.y)))" }.joined(separator: ", ")
            return "[\(items)]"
        }
    }
}

// MARK: - Catalog table

private let allFillStyles: [FxStyleInfo] = [
    FxStyleInfo(
        id: "liquid_metal",
        name: "Liquid metal",
        summary: "Polished metal reflecting a studio, flowing like liquid. Works as a fill or a tube-like border.",
        swiftType: "LiquidMetalParams",
        params: LiquidMetalParams.params,
        presets: [
            FxPreset(id: "chrome", name: "Chrome", swiftCode: "LiquidMetalParams.chrome()") { .liquidMetal(.chrome()) },
            FxPreset(id: "gold", name: "Gold", swiftCode: "LiquidMetalParams.gold()") { .liquidMetal(.gold()) },
            FxPreset(id: "rose", name: "Rose gold", swiftCode: "LiquidMetalParams.rose()") { .liquidMetal(.rose()) },
            FxPreset(id: "gunmetal", name: "Gunmetal", swiftCode: "LiquidMetalParams.gunmetal()") { .liquidMetal(.gunmetal()) },
        ],
        readsBackdrop: false
    ),
    FxStyleInfo(
        id: "mesh_gradient",
        name: "Mesh gradient",
        summary: "Up to six colours pinned to slowly drifting points, blended in OKLab.",
        swiftType: "MeshGradientParams",
        params: MeshGradientParams.params,
        presets: [
            FxPreset(id: "dusk", name: "Dusk", swiftCode: "MeshGradientParams.dusk()") { .meshGradient(.dusk()) },
            FxPreset(id: "lagoon", name: "Lagoon", swiftCode: "MeshGradientParams.lagoon()") { .meshGradient(.lagoon()) },
            FxPreset(id: "orchid", name: "Orchid", swiftCode: "MeshGradientParams.orchid()") { .meshGradient(.orchid()) },
            FxPreset(id: "graphite", name: "Graphite", swiftCode: "MeshGradientParams.graphite()") { .meshGradient(.graphite()) },
        ],
        readsBackdrop: false
    ),
    FxStyleInfo(
        id: "dither",
        name: "Dither",
        summary: "Bayer or blue-noise dithering of a ramp, noise, the backdrop or an image into a palette.",
        swiftType: "DitherParams",
        params: DitherParams.params,
        presets: [
            FxPreset(id: "bayer", name: "Bayer", swiftCode: "DitherParams.bayer()") { .dither(.bayer()) },
            FxPreset(id: "handheld", name: "Handheld", swiftCode: "DitherParams.handheld()") { .dither(.handheld()) },
            FxPreset(id: "grain", name: "Blue noise", swiftCode: "DitherParams.grain()") { .dither(.grain()) },
            FxPreset(id: "backdrop", name: "Backdrop", swiftCode: "DitherParams.backdrop()") { .dither(.backdrop()) },
        ],
        readsBackdrop: true
    ),
    FxStyleInfo(
        id: "grain_gradient",
        name: "Grain gradient",
        summary: "A linear, radial or conic gradient scattered into film grain.",
        swiftType: "GrainGradientParams",
        params: GrainGradientParams.params,
        presets: [
            FxPreset(id: "ember", name: "Ember", swiftCode: "GrainGradientParams.ember()") { .grainGradient(.ember()) },
            FxPreset(id: "halo", name: "Halo", swiftCode: "GrainGradientParams.halo()") { .grainGradient(.halo()) },
            FxPreset(id: "sweep", name: "Sweep", swiftCode: "GrainGradientParams.sweep()") { .grainGradient(.sweep()) },
        ],
        readsBackdrop: false
    ),
    FxStyleInfo(
        id: "fluted_glass",
        name: "Fluted glass",
        summary: "Reeded glass over the backdrop: each rib shows a squeezed, flipped strip of what is behind.",
        swiftType: "FlutedGlassParams",
        params: FlutedGlassParams.params,
        presets: [
            FxPreset(id: "reeded", name: "Reeded", swiftCode: "FlutedGlassParams.reeded()") { .flutedGlass(.reeded()) },
            FxPreset(id: "fine", name: "Fine", swiftCode: "FlutedGlassParams.fine()") { .flutedGlass(.fine()) },
            FxPreset(id: "frosted", name: "Frosted", swiftCode: "FlutedGlassParams.frosted()") { .flutedGlass(.frosted()) },
            FxPreset(id: "wide", name: "Wide", swiftCode: "FlutedGlassParams.wide()") { .flutedGlass(.wide()) },
        ],
        readsBackdrop: true
    ),
    FxStyleInfo(
        id: "metaballs",
        name: "Metaballs",
        summary: "Glossy blobs that drift and merge.",
        swiftType: "MetaballParams",
        params: MetaballParams.params,
        presets: [
            FxPreset(id: "lava", name: "Lava", swiftCode: "MetaballParams.lava()") { .metaballs(.lava()) },
            FxPreset(id: "mint", name: "Mint", swiftCode: "MetaballParams.mint()") { .metaballs(.mint()) },
        ],
        readsBackdrop: false
    ),
    FxStyleInfo(
        id: "swirl",
        name: "Swirl",
        summary: "Colours stirred into a slow swirl.",
        swiftType: "SwirlParams",
        params: SwirlParams.params,
        presets: [
            FxPreset(id: "ink", name: "Ink", swiftCode: "SwirlParams.ink()") { .swirl(.ink()) },
            FxPreset(id: "marble", name: "Marble", swiftCode: "SwirlParams.marble()") { .swirl(.marble()) },
        ],
        readsBackdrop: false
    ),
    FxStyleInfo(
        id: "voronoi",
        name: "Voronoi",
        summary: "Cells around drifting seed points, with seams.",
        swiftType: "VoronoiParams",
        params: VoronoiParams.params,
        presets: [
            FxPreset(id: "cells", name: "Cells", swiftCode: "VoronoiParams.cells()") { .voronoi(.cells()) },
            FxPreset(id: "stained", name: "Stained glass", swiftCode: "VoronoiParams.stained()") { .voronoi(.stained()) },
        ],
        readsBackdrop: false
    ),
    FxStyleInfo(
        id: "waves",
        name: "Waves",
        summary: "Layered bands of colour with rolling edges.",
        swiftType: "WaveParams",
        params: WaveParams.params,
        presets: [
            FxPreset(id: "sea", name: "Sea", swiftCode: "WaveParams.sea()") { .waves(.sea()) },
            FxPreset(id: "dunes", name: "Dunes", swiftCode: "WaveParams.dunes()") { .waves(.dunes()) },
        ],
        readsBackdrop: false
    ),
    FxStyleInfo(
        id: "halftone",
        name: "Halftone",
        summary: "Print dots on a rotated screen, sized by a ramp, noise, the backdrop or an image.",
        swiftType: "HalftoneParams",
        params: HalftoneParams.params,
        presets: [
            FxPreset(id: "print", name: "Print", swiftCode: "HalftoneParams.print()") { .halftone(.print()) },
            FxPreset(id: "backdrop", name: "Backdrop", swiftCode: "HalftoneParams.backdrop()") { .halftone(.backdrop()) },
        ],
        readsBackdrop: true
    ),
    FxStyleInfo(
        id: "plastic",
        name: "Plastic",
        summary: "Moulded plastic under a soft light: glossy to matte, domed or dished, with a rolled rim.",
        swiftType: "PlasticParams",
        params: PlasticParams.params,
        presets: [
            FxPreset(id: "glossy", name: "Glossy", swiftCode: "PlasticParams.glossy()") { .plastic(.glossy()) },
            FxPreset(id: "matte", name: "Matte", swiftCode: "PlasticParams.matte()") { .plastic(.matte()) },
            FxPreset(id: "dished", name: "Dished", swiftCode: "PlasticParams.dished()") { .plastic(.dished()) },
        ],
        readsBackdrop: false
    ),
]

/// Every fill style, in catalog order.
public func fillStyles() -> [FxStyleInfo] {
    allFillStyles
}

/// Look up a fill style by its snake_case id.
public func fillStyle(_ id: String) -> FxStyleInfo? {
    allFillStyles.first { $0.id == id }
}
