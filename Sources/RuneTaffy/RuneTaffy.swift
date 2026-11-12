/// `RuneTaffy` — Pure Swift 6 Flexbox, CSS Grid, and Block layout engine.
///
/// Ports `crates/rune-taffy` and Taffy's layout algorithms (`TaffyTree`, `LayoutStore`,
/// `TaffyStyle`, `Cache`, Flexbox, CSS Grid, Block, out-of-flow positioning, and
/// cumulative `roundLayout`) with zero external dependencies and full `Sendable` safety.

// MARK: - Style Builder Helpers (matching taffy::style_helpers)

@inlinable
public func length(_ value: Float) -> Dimension {
    .length(value)
}

@inlinable
public func percent(_ value: Float) -> Dimension {
    .percent(value)
}

@inlinable
public func auto() -> Dimension {
    .auto
}

@inlinable
public func minContent() -> Dimension {
    .minContent
}

@inlinable
public func maxContent() -> Dimension {
    .maxContent
}

@inlinable
public func fitContent(_ value: LengthPercentage) -> Dimension {
    switch value {
    case .length(let px): return .fitContentPx(px)
    case .percent(let p): return .fitContentPercent(p)
    }
}

@inlinable
public func fr(_ value: Float) -> TrackSizingFunction {
    .fr(value)
}

@inlinable
public func minmax(_ min: MinTrackSizingFunction, _ max: MaxTrackSizingFunction) -> TrackSizingFunction {
    .minmax(min, max)
}

@inlinable
public func gridLine(_ index: Int16) -> GridPlacement {
    .line(index)
}

@inlinable
public func gridSpan(_ count: UInt16) -> GridPlacement {
    .span(count)
}

@inlinable
public func line(_ index: Int16) -> GridPlacement {
    .line(index)
}

@inlinable
public func span(_ count: UInt16) -> GridPlacement {
    .span(count)
}

@inlinable
public func flex(_ value: Float) -> TrackSizingFunction {
    .fr(value)
}

@inlinable
public func repeatTracks(_ count: RepetitionCount, _ tracks: [TrackSizingFunction]) -> GridTemplateComponent {
    .repeat(count, tracks)
}

@inlinable
public func evenlySizedTracks(_ count: UInt16) -> GridTemplateComponent {
    .repeat(.count(count), [TrackSizingFunction(min: .length(0), max: .fr(1))])
}

@inlinable
public func zero() -> Float { 0 }

@inlinable
public func zero() -> Dimension { .zero }

@inlinable
public func zero() -> LengthPercentage { .zero }

@inlinable
public func zero() -> LengthPercentageAuto { .zero }

@inlinable
public func zero() -> Size<Float> { .zero }
