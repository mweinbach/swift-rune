import Foundation

/// Accessibility toggle/pressed state (`crates/rune/src/el/a11y.rs`).
public enum A11yChecked: String, Sendable, Hashable, Codable {
    case falseState = "false"
    case trueState = "true"
    case mixed = "mixed"
}

/// Accessibility range metadata (`crates/rune/src/el/a11y.rs`).
public struct A11yRange: Sendable, Equatable, Codable {
    public var value: Double
    public var min: Double
    public var max: Double
    public var step: Double?

    public init(value: Double, min: Double, max: Double, step: Double? = nil) {
        self.value = value
        self.min = min
        self.max = max
        self.step = step
    }
}
