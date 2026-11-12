import Foundation
import RuneFX

enum LabScene: Int, CaseIterable, Sendable {
    case lamp = 0
    case flashlight
    case gi
    case keys
    case godRays
    case glow
    case pulses
    case electric
    case fire
    case motion
    case lens
    case extras

    var idx: Int { rawValue }
    var isLit: Bool { rawValue < 5 }

    var id: String {
        switch self {
        case .lamp: "lamp"
        case .flashlight: "flashlight"
        case .gi: "gi"
        case .keys: "keys"
        case .godRays: "godrays"
        case .glow: "glow"
        case .pulses: "pulses"
        case .electric: "electric"
        case .fire: "fire"
        case .motion: "motion"
        case .lens: "lens"
        case .extras: "extras"
        }
    }

    var title: String {
        switch self {
        case .lamp: "Lamp"
        case .flashlight: "Flashlight"
        case .gi: "Emissive light"
        case .keys: "Raised keys"
        case .godRays: "God rays"
        case .glow: "Glow"
        case .pulses: "Pulses"
        case .electric: "Electricity"
        case .fire: "Fire"
        case .motion: "Motion blur"
        case .lens: "Liquid glass"
        case .extras: "Extras"
        }
    }

    var hint: String {
        switch self {
        case .lamp: "Drag the lamp. Every bubble casts a soft shadow from the analytic field."
        case .flashlight: "Move the pointer. The torch is held low and to the right, so shadows swing."
        case .gi: "Glowing elements light their neighbours. Click the record button or the progress bar."
        case .keys: "Move the pointer to sweep the light. Press a key."
        case .godRays: "Move the pointer. The light sits behind the grid and shines through the gaps."
        case .glow: "Click the neon card to switch it off: lights cool, never cut."
        case .pulses: "Click anywhere for a ripple. Press send to ping the inbox."
        case .electric: "Hover the charged button."
        case .fire: "Flames, a plasma border and heat haze over a button."
        case .motion: "Drag the card and fling it. It glides on a spring with shutter blur."
        case .lens: "Drag the glass over the page. Click anywhere for a shockwave."
        case .extras: "Shimmer, sparkles, aurora and grain."
        }
    }
}

enum LabKnobKind {
    case slider(decimals: Int)
    case toggle
    case swatch([UInt32])
}

struct LabKnobSpec {
    let id: String
    let label: String
    let min: Float
    let max: Float
    let defaultValue: Float
    let kind: LabKnobKind
}

let fxColors: [UInt32] = [0x22d3ee, 0x8b5cf6, 0xff5fa2, 0xff8a2a, 0x34d399, 0x60a5fa]
let lampColors: [UInt32] = [0xffc78c, 0xff9a4d, 0xfff3e6, 0xb3ccff, 0xff8fb0, 0x9dffd0]

private func sl(_ id: String, _ label: String, _ min: Float, _ max: Float, _ def: Float, _ dec: Int) -> LabKnobSpec {
    LabKnobSpec(id: id, label: label, min: min, max: max, defaultValue: def, kind: .slider(decimals: dec))
}

private func tg(_ id: String, _ label: String, _ on: Bool) -> LabKnobSpec {
    LabKnobSpec(id: id, label: label, min: 0, max: 1, defaultValue: on ? 1 : 0, kind: .toggle)
}

private func sw(_ id: String, _ label: String, _ palette: [UInt32]) -> LabKnobSpec {
    LabKnobSpec(id: id, label: label, min: 0, max: Float(palette.count - 1), defaultValue: 0, kind: .swatch(palette))
}

private func fx(_ knobs: [RuneFX.Knob], _ name: String, _ label: String, _ dec: Int) -> LabKnobSpec {
    guard let k = knobs.first(where: { $0.name == name }) else {
        fatalError("Missing RuneFX knob \(name)")
    }
    return LabKnobSpec(id: k.name, label: label, min: k.min, max: k.max, defaultValue: k.default, kind: .slider(decimals: dec))
}

private func buildKnobSpecs(for scene: LabScene) -> [LabKnobSpec] {
    switch scene {
    case .lamp:
        return [
            sl("height", "Lamp height", 10, 240, 40, 0),
            sl("radius", "Source size", 2, 40, 11, 0),
            sl("intensity", "Intensity", 0, 6, 2.6, 1),
            sw("color", "Colour", lampColors),
            tg("fill", "Fill light", true),
            tg("bounce", "Bounce light (GI)", false),
        ]
    case .flashlight:
        return [
            sl("beam", "Beam angle", 0.2, 1.2, 0.58, 2),
            sl("height", "Torch height", 60, 420, 260, 0),
            sl("radius", "Source size", 2, 30, 9, 0),
            sl("intensity", "Intensity", 0, 14, 7.0, 1),
            sl("ambient", "Ambient", 0, 0.4, 0.07, 2),
        ]
    case .gi:
        return [
            tg("gi", "Global illumination", true),
            sl("strength", "GI strength", 0, 3, 1.0, 2),
            sl("air", "Air scatter", 0, 0.3, 0.09, 2),
            sl("bounce", "Bounce", 0, 1, 0.0, 2),
            sl("emission", "Emission", 0, 3, 1.0, 2),
            sl("ambient", "Ambient", 0, 1, 0.3, 2),
        ]
    case .keys:
        return [
            sl("height", "Light height", 30, 400, 150, 0),
            sl("radius", "Source size", 4, 60, 26, 0),
            sl("bevel", "Bevel", 0.3, 2.0, 1.0, 2),
            sl("gloss", "Gloss", 0, 1, 0.85, 2),
            tg("fill", "Fill light", true),
        ]
    case .godRays:
        return [
            sl("shafts", "Shafts", 0, 3, 1.5, 2),
            sl("intensity", "Intensity", 0, 4, 1.6, 2),
            sl("softness", "Softness", 0.5, 4, 2.2, 2),
            sl("height", "Light height", 1, 40, 4, 0),
        ]
    case .glow:
        let g = GlowParams.knobs
        return [
            fx(g, "radius", "Radius", 0),
            fx(g, "intensity", "Intensity", 2),
            fx(g, "breathe", "Breathe", 2),
            fx(g, "rim_width", "Rim width", 2),
            fx(g, "hot", "Hot core", 2),
            sw("color", "Neon colour", fxColors),
        ]
    case .pulses:
        let p = PulseParams.knobs
        return [
            fx(p, "reach", "Reach", 0),
            fx(p, "width", "Ring width", 1),
            fx(p, "period", "Period", 1),
            fx(p, "count", "Rings", 0),
            fx(p, "intensity", "Intensity", 2),
            sw("color", "Colour", fxColors),
        ]
    case .electric:
        let e = ElectricParams.knobs
        return [
            fx(e, "amplitude", "Amplitude", 1),
            fx(e, "frequency", "Frequency", 1),
            fx(e, "speed", "Speed", 1),
            fx(e, "glow", "Glow", 1),
            fx(e, "forks", "Forks", 2),
            sw("color", "Colour", fxColors),
        ]
    case .fire:
        let f = FireParams.knobs
        return [
            fx(f, "height", "Flame height", 0),
            fx(f, "scale", "Scale", 0),
            fx(f, "speed", "Speed", 2),
            fx(f, "embers", "Embers", 0),
            fx(f, "intensity", "Intensity", 2),
            fx(f, "swirl", "Swirl", 2),
        ]
    case .motion:
        let m = MotionBlurParams.knobs
        return [
            fx(m, "shutter_angle", "Shutter angle", 0),
            sl("glide", "Glide duration", 0.3, 1.4, 0.6, 2),
            tg("smooth", "Soft shutter ends", true),
            tg("directional", "Directional fallback", false),
        ]
    case .lens:
        return [
            sl("depth", "Depth", 0, 40, 16, 0),
            sl("bevel", "Bevel", 2, 40, 14, 0),
            sl("dispersion", "Dispersion", 0, 0.5, 0.14, 2),
            sl("magnification", "Magnification", 0.9, 1.3, 1.04, 2),
            sl("frost", "Frost", 0, 1, 0, 2),
            tg("crt", "CRT terminal", true),
        ]
    case .extras:
        return [
            tg("shimmer", "Shimmer", true),
            tg("aurora", "Aurora", true),
            tg("grain", "Grain", true),
            tg("sparkles", "Sparkles", true),
            sl("speed", "Aurora speed", 0, 1, 0.25, 2),
        ]
    }
}

private let allKnobSpecs: [[LabKnobSpec]] = LabScene.allCases.map(buildKnobSpecs(for:))

func knobSpecs(for scene: LabScene) -> [LabKnobSpec] {
    allKnobSpecs[scene.idx]
}

func defaultKnobValues() -> [[Float]] {
    LabScene.allCases.map { knobSpecs(for: $0).map(\.defaultValue) }
}
