import Foundation

// MARK: - Runtime Paint Blend API (`crates/rune/src/runtime/paint/blend.rs`)

public extension Runtime {
    /// Rasterizes and places glyphs in `mode` from the next frame (`Runtime::set_font_smoothing`).
    func setFontSmoothing(_ mode: FontSmoothing) {
        if fontSmoothing != mode {
            fontSmoothing = mode
            needsCommit = true
        }
    }
}
