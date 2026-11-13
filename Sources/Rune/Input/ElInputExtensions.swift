import Foundation

/// Phase of a touch/pen event (`rune::TouchPhase`).
public enum TouchPhase: String, Sendable, Equatable, Hashable {
    case started
    case moved
    case ended
    case cancelled
}

internal struct SpellcheckToggleBinding {
    var enabled: Bool
    var call: (inout Any, Bool, inout Tx) -> Void
}

internal struct SpellcheckLanguagesBinding {
    var call: (inout Any, [String], inout Tx) -> Void
}
