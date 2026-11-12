// MARK: - Core Geometry & Style Value Types

/// A 2D point with generic scalar type `T`.
public struct Point<T> {
    public var x: T
    public var y: T

    @inlinable
    public init(x: T, y: T) {
        self.x = x
        self.y = y
    }
}

extension Point: Sendable where T: Sendable {}
extension Point: Equatable where T: Equatable {}
extension Point: Hashable where T: Hashable {}

extension Point where T == Float {
    public static let zero = Point(x: 0, y: 0)
}

/// A 2D size with generic scalar type `T`.
public struct Size<T> {
    public var width: T
    public var height: T

    @inlinable
    public init(width: T, height: T) {
        self.width = width
        self.height = height
    }
}

extension Size: Sendable where T: Sendable {}
extension Size: Equatable where T: Equatable {}
extension Size: Hashable where T: Hashable {}

extension Size where T == Float {
    public static let zero = Size(width: 0, height: 0)
}

extension Size where T == Float? {
    public static let none = Size(width: nil, height: nil)
}

extension Size {
    @inlinable
    public func map<U>(_ transform: (T) -> U) -> Size<U> {
        Size<U>(width: transform(width), height: transform(height))
    }

    @inlinable
    public func zipMap<U, V>(_ other: Size<U>, _ transform: (T, U) -> V) -> Size<V> {
        Size<V>(width: transform(width, other.width), height: transform(height, other.height))
    }
}

/// A 4-sided rectangle (left, right, top, bottom) with generic scalar type `T`.
public struct Rect<T> {
    public var left: T
    public var right: T
    public var top: T
    public var bottom: T

    @inlinable
    public init(left: T, right: T, top: T, bottom: T) {
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
    }

    @inlinable
    public init(horizontal: T, vertical: T) {
        self.left = horizontal
        self.right = horizontal
        self.top = vertical
        self.bottom = vertical
    }

    @inlinable
    public init(all value: T) {
        self.left = value
        self.right = value
        self.top = value
        self.bottom = value
    }

    @inlinable
    public func map<U>(_ transform: (T) -> U) -> Rect<U> {
        Rect<U>(
            left: transform(left),
            right: transform(right),
            top: transform(top),
            bottom: transform(bottom)
        )
    }
}

extension Rect: Sendable where T: Sendable {}
extension Rect: Equatable where T: Equatable {}
extension Rect: Hashable where T: Hashable {}

extension Rect where T == Float {
    public static let zero = Rect(left: 0, right: 0, top: 0, bottom: 0)

    @inlinable
    public var horizontalSum: Float { left + right }

    @inlinable
    public var verticalSum: Float { top + bottom }

    @inlinable
    public var sumAxes: Size<Float> {
        Size(width: horizontalSum, height: verticalSum)
    }
}

/// A start/end pair along an axis.
public struct Line<T> {
    public var start: T
    public var end: T

    @inlinable
    public init(start: T, end: T) {
        self.start = start
        self.end = end
    }
}

extension Line: Sendable where T: Sendable {}
extension Line: Equatable where T: Equatable {}
extension Line: Hashable where T: Hashable {}

extension Line where T == Bool {
    public static let `false` = Line(start: false, end: false)
}

// MARK: - Axis Helpers

public enum AbstractAxis: Sendable, Equatable, Hashable {
    case inline
    case block
}

public enum AbsoluteAxis: Sendable, Equatable, Hashable {
    case horizontal
    case vertical

    @inlinable
    public var otherAxis: AbsoluteAxis {
        self == .horizontal ? .vertical : .horizontal
    }
}

extension Size {
    @inlinable
    public func main(direction: FlexDirection) -> T {
        direction.isRow ? width : height
    }

    @inlinable
    public func cross(direction: FlexDirection) -> T {
        direction.isRow ? height : width
    }

    @inlinable
    public mutating func setMain(_ value: T, direction: FlexDirection) {
        if direction.isRow { width = value } else { height = value }
    }

    @inlinable
    public mutating func setCross(_ value: T, direction: FlexDirection) {
        if direction.isRow { height = value } else { width = value }
    }

    @inlinable
    public func get(axis: AbsoluteAxis) -> T {
        axis == .horizontal ? width : height
    }

    @inlinable
    public mutating func set(_ value: T, axis: AbsoluteAxis) {
        if axis == .horizontal { width = value } else { height = value }
    }
}

extension Rect {
    @inlinable
    public func mainStart(direction: FlexDirection) -> T {
        switch direction {
        case .row: return left
        case .rowReverse: return right
        case .column: return top
        case .columnReverse: return bottom
        }
    }

    @inlinable
    public func mainEnd(direction: FlexDirection) -> T {
        switch direction {
        case .row: return right
        case .rowReverse: return left
        case .column: return bottom
        case .columnReverse: return top
        }
    }

    @inlinable
    public func crossStart(direction: FlexDirection) -> T {
        direction.isRow ? top : left
    }

    @inlinable
    public func crossEnd(direction: FlexDirection) -> T {
        direction.isRow ? bottom : right
    }

    @inlinable
    public func get(axis: AbsoluteAxis) -> Line<T> {
        axis == .horizontal
            ? Line(start: left, end: right)
            : Line(start: top, end: bottom)
    }
}

extension Rect where T == Float {
    @inlinable
    public func mainAxisSum(direction: FlexDirection) -> Float {
        direction.isRow ? (left + right) : (top + bottom)
    }

    @inlinable
    public func crossAxisSum(direction: FlexDirection) -> Float {
        direction.isRow ? (top + bottom) : (left + right)
    }
}

// MARK: - AvailableSpace

/// Available space passed from parent to child during layout.
public enum AvailableSpace: Sendable, Equatable, Hashable {
    case definite(Float)
    case minContent
    case maxContent

    public static let zero = AvailableSpace.definite(0)

    @inlinable
    public static func from(_ opt: Float?) -> AvailableSpace {
        if let v = opt { return .definite(v) }
        return .maxContent
    }

    @inlinable
    public var isDefinite: Bool {
        if case .definite = self { return true }
        return false
    }

    @inlinable
    public var definiteValue: Float? {
        if case .definite(let v) = self { return v }
        return nil
    }

    @inlinable
    public func intoOption() -> Float? {
        definiteValue
    }

    @inlinable
    public func unwrapOr(_ defaultValue: Float) -> Float {
        definiteValue ?? defaultValue
    }

    @inlinable
    public func unwrapOrElse(_ defaultProvider: () -> Float) -> Float {
        definiteValue ?? defaultProvider()
    }

    @inlinable
    public func mapDefiniteValue(_ transform: (Float) -> Float) -> AvailableSpace {
        switch self {
        case .definite(let v): return .definite(transform(v))
        case .minContent: return .minContent
        case .maxContent: return .maxContent
        }
    }

    @inlinable
    public func maybeSet(_ value: Float?) -> AvailableSpace {
        if let v = value { return .definite(v) }
        return self
    }

    @inlinable
    public func maybeAdd(_ amount: Float?) -> AvailableSpace {
        switch (self, amount) {
        case (.definite(let a), let b?): return .definite(a + b)
        default: return self
        }
    }

    @inlinable
    public func maybeSub(_ amount: Float?) -> AvailableSpace {
        switch (self, amount) {
        case (.definite(let a), let b?): return .definite(a - b)
        default: return self
        }
    }

    @inlinable
    public func maybeMin(_ value: Float?) -> AvailableSpace {
        switch (self, value) {
        case (.definite(let a), let b?): return .definite(Swift.min(a, b))
        case (.definite(let a), nil): return .definite(a)
        case (.minContent, _): return .minContent
        case (.maxContent, let b?): return .definite(b)
        case (.maxContent, nil): return .maxContent
        }
    }

    @inlinable
    public func maybeMax(_ value: Float?) -> AvailableSpace {
        switch (self, value) {
        case (.definite(let a), let b?): return .definite(Swift.max(a, b))
        default: return self
        }
    }
}

extension Size where T == AvailableSpace {
    public static let minContent = Size(width: .minContent, height: .minContent)
    public static let maxContent = Size(width: .maxContent, height: .maxContent)

    @inlinable
    public func intoOptions() -> Size<Float?> {
        Size<Float?>(width: width.intoOption(), height: height.intoOption())
    }
}

// MARK: - Dimension, LengthPercentage, LengthPercentageAuto

/// A CSS dimension value: length, percentage, auto, or intrinsic sizing keyword.
public enum Dimension: Sendable, Equatable, Hashable {
    case length(Float)
    case percent(Float)
    case auto
    case minContent
    case maxContent
    case fitContentPx(Float)
    case fitContentPercent(Float)

    public static let zero = Dimension.length(0)

    @inlinable
    public var isAuto: Bool {
        self == .auto
    }

    @inlinable
    public func maybeResolve(_ context: Float?) -> Float? {
        switch self {
        case .length(let v): return v
        case .percent(let p): return context.map { $0 * p }
        case .auto, .minContent, .maxContent, .fitContentPx, .fitContentPercent: return nil
        }
    }

    @inlinable
    public func maybeResolve(_ context: Float?, calc: (Float) -> Float) -> Float? {
        maybeResolve(context)
    }

    @inlinable
    public func resolveOrZero(_ context: Float?) -> Float {
        maybeResolve(context) ?? 0
    }
}

/// A CSS `<length-percentage>` value.
public enum LengthPercentage: Sendable, Equatable, Hashable {
    case length(Float)
    case percent(Float)

    public static let zero = LengthPercentage.length(0)

    @inlinable
    public func maybeResolve(_ context: Float?) -> Float? {
        switch self {
        case .length(let v): return v
        case .percent(let p): return context.map { $0 * p }
        }
    }

    @inlinable
    public func resolveOrZero(_ context: Float?) -> Float {
        maybeResolve(context) ?? 0
    }
}

/// A CSS `<length-percentage> | auto` value.
public enum LengthPercentageAuto: Sendable, Equatable, Hashable {
    case length(Float)
    case percent(Float)
    case auto

    public static let zero = LengthPercentageAuto.length(0)

    @inlinable
    public var isAuto: Bool {
        self == .auto
    }

    @inlinable
    public func maybeResolve(_ context: Float?) -> Float? {
        switch self {
        case .length(let v): return v
        case .percent(let p): return context.map { $0 * p }
        case .auto: return nil
        }
    }

    @inlinable
    public func resolveOrZero(_ context: Float?) -> Float {
        maybeResolve(context) ?? 0
    }

    @inlinable
    public func resolveToOption(_ context: Float?) -> Float? {
        maybeResolve(context)
    }
}

// MARK: - Style Enums

public enum Display: Sendable, Equatable, Hashable {
    case flex
    case grid
    case block
    case flowRoot
    case none
}

public enum Position: Sendable, Equatable, Hashable {
    case `static`
    case relative
    case absolute
    case fixed
    case sticky
}

public enum BoxSizing: Sendable, Equatable, Hashable {
    case borderBox
    case contentBox
}

public enum Overflow: Sendable, Equatable, Hashable {
    case visible
    case clip
    case hidden
    case scroll

    @inlinable
    public var isScrollContainer: Bool {
        self == .hidden || self == .scroll
    }
}

public enum Direction: Sendable, Equatable, Hashable {
    case ltr
    case rtl
}

public enum TextAlign: Sendable, Equatable, Hashable {
    case auto
    case left
    case right
    case center
}

public enum FlexDirection: Sendable, Equatable, Hashable {
    case row
    case column
    case rowReverse
    case columnReverse

    @inlinable
    public var isRow: Bool {
        self == .row || self == .rowReverse
    }

    @inlinable
    public var isColumn: Bool {
        self == .column || self == .columnReverse
    }

    @inlinable
    public var isReverse: Bool {
        self == .rowReverse || self == .columnReverse
    }

    @inlinable
    public var mainAxis: AbsoluteAxis {
        isRow ? .horizontal : .vertical
    }

    @inlinable
    public var crossAxis: AbsoluteAxis {
        isRow ? .vertical : .horizontal
    }
}

public enum FlexWrap: Sendable, Equatable, Hashable {
    case noWrap
    case wrap
    case wrapReverse
}

public enum AlignmentSafety: Sendable, Equatable, Hashable {
    case `default`
    case unsafe
    case safe
}

public enum AlignItems: Sendable, Equatable, Hashable {
    case normal
    case start
    case end
    case flexStart
    case flexEnd
    case selfStart
    case selfEnd
    case center
    case baseline
    case stretch
}

public typealias AlignSelf = AlignItems
public typealias JustifyItems = AlignItems
public typealias JustifySelf = AlignItems

public enum AlignContent: Sendable, Equatable, Hashable {
    case normal
    case start
    case end
    case flexStart
    case flexEnd
    case center
    case stretch
    case spaceBetween
    case spaceEvenly
    case spaceAround
}

public typealias JustifyContent = AlignContent

// MARK: - Grid Types

public enum GridAutoFlow: Sendable, Equatable, Hashable {
    case row
    case column
    case rowDense
    case columnDense

    @inlinable
    public var isRow: Bool {
        self == .row || self == .rowDense
    }

    @inlinable
    public var isColumn: Bool {
        self == .column || self == .columnDense
    }

    @inlinable
    public var isDense: Bool {
        self == .rowDense || self == .columnDense
    }

    @inlinable
    public var primaryAxis: AbsoluteAxis {
        isRow ? .horizontal : .vertical
    }
}

public enum MinTrackSizingFunction: Sendable, Equatable, Hashable {
    case length(Float)
    case percent(Float)
    case auto
    case minContent
    case maxContent

    public static let zero = MinTrackSizingFunction.length(0)

    @inlinable
    public var isIntrinsic: Bool {
        switch self {
        case .auto, .minContent, .maxContent: return true
        case .length, .percent: return false
        }
    }

    @inlinable
    public func definiteValue(_ parentSize: Float?) -> Float? {
        switch self {
        case .length(let v): return v
        case .percent(let p): return parentSize.map { $0 * p }
        case .auto, .minContent, .maxContent: return nil
        }
    }

    @inlinable
    public func usesPercentage() -> Bool {
        if case .percent = self { return true }
        return false
    }
}

public enum MaxTrackSizingFunction: Sendable, Equatable, Hashable {
    case length(Float)
    case percent(Float)
    case fr(Float)
    case auto
    case minContent
    case maxContent
    case fitContentPx(Float)
    case fitContentPercent(Float)

    public static let zero = MaxTrackSizingFunction.length(0)

    @inlinable
    public var isIntrinsic: Bool {
        switch self {
        case .auto, .minContent, .maxContent, .fitContentPx, .fitContentPercent: return true
        case .length, .percent, .fr: return false
        }
    }

    @inlinable
    public var isFlexible: Bool {
        if case .fr = self { return true }
        return false
    }

    @inlinable
    public var frValue: Float? {
        if case .fr(let f) = self { return f }
        return nil
    }

    @inlinable
    public func definiteValue(_ parentSize: Float?) -> Float? {
        switch self {
        case .length(let v): return v
        case .percent(let p): return parentSize.map { $0 * p }
        case .fr, .auto, .minContent, .maxContent, .fitContentPx, .fitContentPercent: return nil
        }
    }

    @inlinable
    public func definiteLimit(_ parentSize: Float?) -> Float? {
        switch self {
        case .fitContentPx(let px): return px
        case .fitContentPercent(let p): return parentSize.map { $0 * p }
        default: return definiteValue(parentSize)
        }
    }

    @inlinable
    public func usesPercentage() -> Bool {
        switch self {
        case .percent, .fitContentPercent: return true
        default: return false
        }
    }
}

public struct TrackSizingFunction: Sendable, Equatable, Hashable {
    public var min: MinTrackSizingFunction
    public var max: MaxTrackSizingFunction

    @inlinable
    public init(min: MinTrackSizingFunction, max: MaxTrackSizingFunction) {
        self.min = min
        self.max = max
    }

    public static let auto = TrackSizingFunction(min: .auto, max: .auto)
    public static let minContent = TrackSizingFunction(min: .minContent, max: .minContent)
    public static let maxContent = TrackSizingFunction(min: .maxContent, max: .maxContent)

    @inlinable
    public static func length(_ v: Float) -> TrackSizingFunction {
        TrackSizingFunction(min: .length(v), max: .length(v))
    }

    @inlinable
    public static func percent(_ p: Float) -> TrackSizingFunction {
        TrackSizingFunction(min: .percent(p), max: .percent(p))
    }

    @inlinable
    public static func fr(_ f: Float) -> TrackSizingFunction {
        TrackSizingFunction(min: .auto, max: .fr(f))
    }

    @inlinable
    public static func minmax(_ min: MinTrackSizingFunction, _ max: MaxTrackSizingFunction) -> TrackSizingFunction {
        TrackSizingFunction(min: min, max: max)
    }

    @inlinable
    public static func fitContent(_ limit: LengthPercentage) -> TrackSizingFunction {
        switch limit {
        case .length(let px): return TrackSizingFunction(min: .auto, max: .fitContentPx(px))
        case .percent(let p): return TrackSizingFunction(min: .auto, max: .fitContentPercent(p))
        }
    }

    @inlinable
    public var isAutoRepetitionEligible: Bool {
        !min.isIntrinsic && !max.isIntrinsic && !max.isFlexible
    }
}

public enum RepetitionCount: Sendable, Equatable, Hashable {
    case count(UInt16)
    case autoFill
    case autoFit
}

public enum GridTemplateComponent: Sendable, Equatable, Hashable {
    case single(TrackSizingFunction)
    case `repeat`(RepetitionCount, [TrackSizingFunction])

    @inlinable
    public static func length(_ v: Float) -> GridTemplateComponent {
        .single(.length(v))
    }

    @inlinable
    public static func percent(_ p: Float) -> GridTemplateComponent {
        .single(.percent(p))
    }

    @inlinable
    public static func fr(_ f: Float) -> GridTemplateComponent {
        .single(.fr(f))
    }

    public static let auto = GridTemplateComponent.single(.auto)
    public static let minContent = GridTemplateComponent.single(.minContent)
    public static let maxContent = GridTemplateComponent.single(.maxContent)

    @inlinable
    public static func minmax(_ min: MinTrackSizingFunction, _ max: MaxTrackSizingFunction) -> GridTemplateComponent {
        .single(.minmax(min, max))
    }

    @inlinable
    public static func repeatTracks(_ count: RepetitionCount, _ tracks: [TrackSizingFunction]) -> GridTemplateComponent {
        .repeat(count, tracks)
    }
}

public enum GridPlacement: Sendable, Equatable, Hashable {
    case auto
    case line(Int16)
    case namedLine(String, Int16)
    case span(UInt16)
    case namedSpan(String, UInt16)

    @inlinable
    public static func fromLine(_ index: Int16) -> GridPlacement {
        .line(index)
    }

    @inlinable
    public static func fromSpan(_ count: UInt16) -> GridPlacement {
        .span(count)
    }
}

public struct GridTemplateArea: Sendable, Equatable, Hashable {
    public var name: String
    public var rowStart: UInt16
    public var rowEnd: UInt16
    public var columnStart: UInt16
    public var columnEnd: UInt16

    public init(name: String, rowStart: UInt16, rowEnd: UInt16, columnStart: UInt16, columnEnd: UInt16) {
        self.name = name
        self.rowStart = rowStart
        self.rowEnd = rowEnd
        self.columnStart = columnStart
        self.columnEnd = columnEnd
    }
}

// MARK: - Math Utilities

@inlinable
internal func maybeClamp(_ value: Float, min: Float?, max: Float?) -> Float {
    var v = value
    if let max { v = Swift.min(v, max) }
    if let min { v = Swift.max(v, min) }
    return v
}

@inlinable
internal func maybeMin(_ a: Float?, _ b: Float?) -> Float? {
    switch (a, b) {
    case (let x?, let y?): return Swift.min(x, y)
    case (let x?, nil): return x
    case (nil, let y?): return y
    case (nil, nil): return nil
    }
}

@inlinable
internal func maybeMax(_ a: Float?, _ b: Float?) -> Float? {
    switch (a, b) {
    case (let x?, let y?): return Swift.max(x, y)
    case (let x?, nil): return x
    case (nil, let y?): return y
    case (nil, nil): return nil
    }
}

@inlinable
internal func maybeAdd(_ a: Float?, _ b: Float?) -> Float? {
    switch (a, b) {
    case (let x?, let y?): return x + y
    default: return nil
    }
}

@inlinable
internal func maybeSub(_ a: Float?, _ b: Float?) -> Float? {
    switch (a, b) {
    case (let x?, let y?): return x - y
    default: return nil
    }
}

@inlinable
internal func applyAspectRatio(_ knownDimensions: Size<Float?>, _ aspectRatio: Float?) -> Size<Float?> {
    guard let ratio = aspectRatio, ratio > 0, ratio.isFinite else {
        return knownDimensions
    }
    switch (knownDimensions.width, knownDimensions.height) {
    case (let w?, nil):
        return Size(width: w, height: w / ratio)
    case (nil, let h?):
        return Size(width: h * ratio, height: h)
    default:
        return knownDimensions
    }
}
