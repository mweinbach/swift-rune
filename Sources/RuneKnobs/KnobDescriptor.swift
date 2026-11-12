import Foundation
import Rune
import RuneMotion

/// Descriptor kind for typed knobs.
public enum KnobKind: String, Sendable, Hashable, Codable {
    case float
    case int
    case bool
    case color
    case text
    case select
    case vec2
    case spring
}

/// Typed value stored for a knob, supporting JSON serialization.
public enum KnobValue: Sendable, Equatable, Codable {
    case float(Float)
    case int(Int)
    case bool(Bool)
    case color(Color)
    case text(String)
    case select(Int)
    case vec2(x: Float, y: Float)
    case spring(duration: Float, bounce: Float)

    public var floatValue: Float? {
        switch self {
        case .float(let v): v
        case .int(let v): Float(v)
        case .bool(let b): b ? 1.0 : 0.0
        case .select(let i): Float(i)
        default: nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .int(let v): v
        case .float(let v): Int(v.rounded())
        case .bool(let b): b ? 1 : 0
        case .select(let i): i
        default: nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): b
        case .float(let v): v >= 0.5
        case .int(let v): v != 0
        default: nil
        }
    }

    public var colorValue: Color? {
        if case .color(let c) = self { return c }
        return nil
    }

    public var textValue: String? {
        if case .text(let s) = self { return s }
        return nil
    }

    public var vec2Value: Vec2? {
        if case .vec2(let x, let y) = self { return Vec2(x, y) }
        return nil
    }

    public var springValue: Spring? {
        if case .spring(let d, let b) = self { return Spring(duration: d, bounce: b) }
        return nil
    }
}

/// A tunable knob descriptor (`rune_knobs::Knob`), supporting numeric sliders, choices, booleans,
/// colors, text, 2D vectors, and spring presets.
public struct Knob: Sendable, Hashable, Codable {
    /// Stable key under which values and presets are stored.
    public var name: String
    /// Display label in the panel (falls back to `name` when empty).
    public var label: String
    public var min: Float
    public var max: Float
    public var `default`: Float
    public var step: Float
    public var labels: [String]
    /// One-line description shown when hovered or focused.
    public var about: String
    /// Short per-option hints for choice knobs.
    public var hints: [String]
    public var kind: KnobKind
    public var defaultColor: Color?
    public var defaultText: String?
    public var defaultVec2: [Float]?
    public var defaultSpringDuration: Float?
    public var defaultSpringBounce: Float?

    public init(
        _ name: String,
        min: Float,
        max: Float,
        default defaultValue: Float,
        step: Float = 0.0,
        label: String = "",
        about: String = "",
        labels: [String] = [],
        hints: [String] = [],
        kind: KnobKind = .float
    ) {
        self.name = name
        self.label = label
        self.min = min
        self.max = max
        self.default = defaultValue
        self.step = step
        self.labels = labels
        self.about = about
        self.hints = hints
        self.kind = labels.isEmpty ? kind : .select
    }

    // MARK: - Typed Factories

    public static func float(
        _ name: String,
        min: Float,
        max: Float,
        default defaultValue: Float,
        step: Float = 0.0
    ) -> Knob {
        Knob(name, min: min, max: max, default: defaultValue, step: step, kind: .float)
    }

    public static func int(
        _ name: String,
        min: Int,
        max: Int,
        default defaultValue: Int,
        step: Int = 1
    ) -> Knob {
        Knob(name, min: Float(min), max: Float(max), default: Float(defaultValue), step: Float(Swift.max(1, step)), kind: .int)
    }

    public static func bool(_ name: String, default defaultValue: Bool = false) -> Knob {
        Knob(
            name,
            min: 0.0,
            max: 1.0,
            default: defaultValue ? 1.0 : 0.0,
            step: 1.0,
            labels: ["Off", "On"],
            kind: .bool
        )
    }

    public static func choice(_ name: String, labels: [String], default defaultIndex: Int = 0) -> Knob {
        let maxIdx = Float(Swift.max(0, labels.count - 1))
        var k = Knob(name, min: 0.0, max: maxIdx, default: Float(defaultIndex), step: 1.0, labels: labels, kind: .select)
        k.kind = .select
        return k
    }

    public static func select(_ name: String, options: [String], default defaultIndex: Int = 0) -> Knob {
        choice(name, labels: options, default: defaultIndex)
    }

    public static func color(_ name: String, default defaultColor: Color) -> Knob {
        var k = Knob(name, min: 0.0, max: 1.0, default: 0.0, kind: .color)
        k.kind = .color
        k.defaultColor = defaultColor
        return k
    }

    public static func text(_ name: String, default defaultText: String = "") -> Knob {
        var k = Knob(name, min: 0.0, max: 1.0, default: 0.0, kind: .text)
        k.kind = .text
        k.defaultText = defaultText
        return k
    }

    public static func vec2(_ name: String, default defaultVec: Vec2 = .zero, min: Float = -1000, max: Float = 1000) -> Knob {
        var k = Knob(name, min: min, max: max, default: defaultVec.x, kind: .vec2)
        k.kind = .vec2
        k.defaultVec2 = [defaultVec.x, defaultVec.y]
        return k
    }

    public static func spring(_ name: String, default defaultSpring: Spring = Spring(duration: 0.3, bounce: 0.0)) -> Knob {
        var k = Knob(name, min: 0.05, max: 2.0, default: defaultSpring.duration, kind: .spring)
        k.kind = .spring
        k.defaultSpringDuration = defaultSpring.duration
        k.defaultSpringBounce = defaultSpring.bounce
        return k
    }

    // MARK: - Fluent Modifiers

    public func label(_ label: String) -> Knob {
        var copy = self
        copy.label = label
        return copy
    }

    public func about(_ about: String) -> Knob {
        var copy = self
        copy.about = about
        return copy
    }

    public func hints(_ hints: [String]) -> Knob {
        var copy = self
        copy.hints = hints
        return copy
    }

    public func step(_ step: Float) -> Knob {
        var copy = self
        copy.step = step
        return copy
    }

    // MARK: - Metadata & Clamping

    /// What the panel calls it, honoring `KnobNotes` overrides.
    public var title: String {
        if let note = KnobNotes.note(for: name), !note.label.isEmpty {
            return note.label
        }
        return label.isEmpty ? name : label
    }

    /// One-line description, honoring `KnobNotes` overrides.
    public var describe: String {
        if let note = KnobNotes.note(for: name), !note.about.isEmpty {
            return note.about
        }
        return about
    }

    /// Hint for option `index` of a choice knob.
    public func hint(at index: Int) -> String {
        let own = (index >= 0 && index < hints.count) ? hints[index] : ""
        let optLabel = (index >= 0 && index < labels.count) ? labels[index] : ""
        if let note = KnobNotes.note(for: name),
           let match = note.hints.first(where: { $0.0 == optLabel })?.1,
           !match.isEmpty {
            return match
        }
        return own
    }

    /// Clamps and snaps `v` to `[min, max]` and `step`.
    public func clamp(_ v: Float) -> Float {
        let clamped = Swift.min(Swift.max(v, min), max)
        if step > 0.0 {
            let snapped = min + ((clamped - min) / step).rounded() * step
            return Swift.min(snapped, max)
        }
        return clamped
    }

    /// Default typed `KnobValue`.
    public var defaultKnobValue: KnobValue {
        switch kind {
        case .float:
            return .float(clamp(`default`))
        case .int:
            return .int(Int(clamp(`default`).rounded()))
        case .bool:
            return .bool(`default` >= 0.5)
        case .color:
            return .color(defaultColor ?? .white)
        case .text:
            return .text(defaultText ?? "")
        case .select:
            return .select(Int(clamp(`default`).rounded()))
        case .vec2:
            let v = defaultVec2 ?? [0, 0]
            return .vec2(x: v.count > 0 ? v[0] : 0, y: v.count > 1 ? v[1] : 0)
        case .spring:
            return .spring(duration: defaultSpringDuration ?? 0.3, bounce: defaultSpringBounce ?? 0.0)
        }
    }
}

/// App-level note overriding a knob's label, description, or option hints (`rune_knobs::Note`).
public struct KnobNote: Sendable, Equatable {
    public var name: String
    public var label: String
    public var about: String
    public var hints: [(String, String)]

    public init(_ name: String, about: String, label: String = "", hints: [(String, String)] = []) {
        self.name = name
        self.about = about
        self.label = label
        self.hints = hints
    }

    public static func == (lhs: KnobNote, rhs: KnobNote) -> Bool {
        lhs.name == rhs.name &&
        lhs.label == rhs.label &&
        lhs.about == rhs.about &&
        lhs.hints.count == rhs.hints.count &&
        zip(lhs.hints, rhs.hints).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

/// Thread-safe global table of `KnobNote`s (`rune_knobs::describe`).
public enum KnobNotes {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage: [String: KnobNote] = [:]

    public static func describe(_ notes: [KnobNote]) {
        lock.lock()
        defer { lock.unlock() }
        for n in notes {
            if storage[n.name] == nil {
                storage[n.name] = n
            }
        }
    }

    public static func note(for name: String) -> KnobNote? {
        lock.lock()
        defer { lock.unlock() }
        return storage[name]
    }
}

/// Preset values for a group (`rune_knobs::Preset`).
public struct KnobPreset: Sendable, Equatable, Codable {
    public var name: String
    public var values: [String: Float]

    public init(_ name: String, values: [String: Float]) {
        self.name = name
        self.values = values
    }
}

/// A group of knobs tied to a keyed region (`rune_knobs::Group`).
public struct KnobGroup: Sendable, Equatable, Codable {
    public var name: String
    public var region: String
    public var knobs: [Knob]
    public var presets: [KnobPreset]
    public var defaultLabel: String
    public var under: String

    public init(
        _ name: String,
        region: String = "",
        knobs: [Knob],
        presets: [KnobPreset] = [],
        defaultLabel: String = "Default",
        under: String = ""
    ) {
        self.name = name
        self.region = region
        self.knobs = knobs
        self.presets = presets
        self.defaultLabel = defaultLabel
        self.under = under
    }

    public func under(_ page: String) -> KnobGroup {
        var copy = self
        copy.under = page
        return copy
    }

    public func presets(_ presets: [KnobPreset]) -> KnobGroup {
        var copy = self
        copy.presets = presets
        return copy
    }

    public func defaultLabel(_ label: String) -> KnobGroup {
        var copy = self
        copy.defaultLabel = label
        return copy
    }

    /// Page this group belongs to (its own name when standalone).
    public var page: String {
        under.isEmpty ? name : under
    }
}

/// Built-in panel tuning constants and knobs (`crates/rune-knobs/src/lib.rs`).
public enum RuneKnobsDefaults {
    public static let defaultPresetName = "Default"
    public static let slide = Spring(duration: 0.3, bounce: 0.0)
    public static let slideTime = Knob.float("Knobs slide", min: 0.1, max: 0.8, default: 0.3).label("Panel slide time")
    public static let slideBounce = Knob.float("Knobs slide bounce", min: 0.0, max: 0.4, default: 0.0).label("Panel slide bounce")
    public static let layout = Knob.choice("Knobs layout", labels: ["Tree", "On screen", "Tabs"], default: 0)
        .label("Panel layout")
        .about("How this panel lists its parts: a folding tree, what's on screen first, or a tab per page")
    public static let foldTime = Knob.float("Knobs fold", min: 0.05, max: 0.6, default: 0.2)
        .label("Section fold time")
        .about("How long a section of this panel takes to fold or open")
    public static let sideW: Float = 340.0
    public static let sideMin: Float = 280.0
    public static let sideMax: Float = 640.0
}
