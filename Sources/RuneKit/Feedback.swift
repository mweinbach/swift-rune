import Foundation
import Rune
import RuneMotion

/// Soft Radar 5x5 dot grid layout & keyframe computation (`rune_kit::feedback::radar`).
public enum RadarGrid {
    public struct Dot: Sendable {
        public let x: Float
        public let y: Float
        public let size: Float
        public let stillOpacity: Float
        public let phase: Float
        public let isCenter: Bool
        public let cycle: Cycle?
    }

    public static let loopDuration: Float = 1.8
    private static let span: Int = 5
    private static let dotSize: Double = 2.0
    private static let pitch: Double = 3.0
    private static let dimOpacity: Double = 0.2
    private static let fadeCurve: [Double] = [
        1.0, 0.987, 0.934, 0.812, 0.599, 0.384, 0.238, 0.143, 0.081, 0.041, 0.017, 0.004, 0.0,
    ]

    public static let dots: [Dot] = computeLayout()

    private static func computeLayout() -> [Dot] {
        let trailStops: [(Double, Double)] = fadeCurve.enumerated().map { idx, lvl in
            (Double(idx) * 4.0, round3(0.55 * lvl))
        } + [(100.0, 0.0)]

        var cells: [(Int, Int)] = []
        for i in 0..<(span * span) {
            cells.append((i % span - (span - 1) / 2, i / span - (span - 1) / 2))
        }

        func isCenter(_ c: (Int, Int)) -> Bool { c.0 == 0 && c.1 == 0 }
        func ring(_ c: (Int, Int)) -> Int { max(abs(c.0), abs(c.1)) }
        func frac(_ v: Double) -> Double { v - floor(v) }
        func angle(_ c: (Int, Int)) -> Double { frac(atan2(Double(c.0), Double(-c.1)) / (2.0 * Double.pi)) }
        func round3(_ v: Double) -> Double { floor(v * 1000.0 + 0.5) / 1000.0 }

        func levelAt(_ stops: [(Double, Double)], percent: Double) -> Double {
            guard let next = stops.firstIndex(where: { $0.0 >= percent }) else {
                return stops.first?.1 ?? 0.0
            }
            if next == 0 { return stops[0].1 }
            let (p0, l0) = stops[next - 1]
            let (p1, l1) = stops[next]
            let span = (p1 - p0 == 0) ? 1.0 : (p1 - p0)
            return l0 + (l1 - l0) * (percent - p0) / span
        }

        func headStops(behind: Double, ahead: Double) -> [(Double, Double)] {
            let edge = 1.5
            let off = ahead / 2.0 + edge
            let on = 100.0 - behind / 2.0
            var stops: [(Double, Double)] = [
                (0.0, 1.0),
                (ahead / 2.0, 1.0),
                (off, levelAt(trailStops, percent: off)),
            ]
            for (p, l) in trailStops where p > off && p < 100.0 && p < on - edge {
                stops.append((p, l))
            }
            stops.append((on - edge, 0.0))
            stops.append((on, 1.0))
            stops.append((100.0, 1.0))
            return stops
        }

        return cells.map { cell in
            let at = angle(cell)
            if isCenter(cell) {
                let still = Float(round3(dimOpacity + (1.0 - dimOpacity) * trailStops[0].1))
                return Dot(
                    x: Float(round3(8.0 + Double(cell.0) * pitch - dotSize / 2.0)),
                    y: Float(round3(8.0 + Double(cell.1) * pitch - dotSize / 2.0)),
                    size: Float(dotSize),
                    stillOpacity: still,
                    phase: 0,
                    isCenter: true,
                    cycle: nil
                )
            }

            let myRing = ring(cell)
            let others = cells.filter { $0 != cell && !isCenter($0) && ring($0) == myRing }.map(angle)
            let behind = others.map { frac(at - $0) }.min() ?? 0.25
            let ahead = others.map { frac($0 - at) }.min() ?? 0.25
            let stops = headStops(behind: round3(behind) * 100.0, ahead: round3(ahead) * 100.0)
            let stillLevel = levelAt(stops, percent: frac(0.22 - at) * 100.0)
            let still = Float(round3(dimOpacity + (1.0 - dimOpacity) * stillLevel))
            let frames: [(Float, Float)] = stops.map { p, l in
                (Float(round3(p) / 100.0), Float(round3(dimOpacity + (1.0 - dimOpacity) * l)))
            }
            return Dot(
                x: Float(round3(8.0 + Double(cell.0) * pitch - dotSize / 2.0)),
                y: Float(round3(8.0 + Double(cell.1) * pitch - dotSize / 2.0)),
                size: Float(dotSize),
                stillOpacity: still,
                phase: Float(round3(at)),
                isCenter: false,
                cycle: Cycle(period: loopDuration, phase: Float(round3(at)), stops: frames, still: still, fps: 60.0)
            )
        }
    }

    /// Evaluates `dot`'s animated opacity at `time` seconds, or `stillOpacity` for the steady center dot.
    public static func phaseOpacity(dot: Dot, at time: Double) -> Float {
        dot.cycle?.sample(at: time) ?? dot.stillOpacity
    }
}

/// Soft Radar 5x5 activity spinner (`rune_kit::feedback::Spinner`).
public struct Spinner<State> {
    private var diameter: Float = 18
    private var inkColor: Color?

    public init() {}

    public func size(_ s: Float) -> Self { var c = self; c.diameter = s; return c }
    public func color(_ color: Color) -> Self { var c = self; c.inkColor = color; return c }

    public func build(_ k: Kit, key: String = "radar-spinner") -> El<State> {
        let ink = inkColor ?? k.c.stdText
        let u = diameter / 16.0
        var box: El<State> = el()
            .key(key)
            .role(.progress)
            .label("Loading")
            .size(diameter, diameter)

        for (idx, dot) in RadarGrid.dots.enumerated() {
            let side = dot.size * u
            let dotEl: El<State> = el()
                .key("\(key)-d\(idx)")
                .absolute(x: dot.x * u, y: dot.y * u)
                .size(side, side)
                .rounded(side * 0.24)
                .bg(ink)
                .opacity(dot.stillOpacity)
            box = box.child(dotEl)
        }
        return box
    }
}

private enum FeedbackAssets {
    static let ringIcon = SVGIcon(viewBox: 16, paths: ["M8 2A6 6 0 1 0 8 14A6 6 0 1 0 8 2Z"], strokeWidth: 2.0)
    static let arcIcon = SVGIcon(viewBox: 16, paths: ["M8 2A6 6 0 0 1 13.258 10.89"], strokeWidth: 2.0)
    static let loaderLoopSpec = LoopSpec.rotation(period: 0.9)
    static let indeterminateSlide = LoopSpec.slide(period: 1.4, from: Vec2(-1, 0), to: Vec2(4, 0))
    static let quantizedArcs: [SVGIcon] = (0...50).map { step in
        if step == 0 {
            return SVGIcon(viewBox: 16, paths: [], strokeWidth: 2.0)
        } else if step == 50 {
            return ringIcon
        }
        let a = Double(step) / 50.0 * 2.0 * .pi - .pi * 0.5
        let x = 8.0 + 6.0 * cos(a)
        let y = 8.0 + 6.0 * sin(a)
        let large = step > 25 ? 1 : 0
        let d = String(format: "M8 2A6 6 0 %d 1 %.3f %.3f", large, x, y)
        return SVGIcon(viewBox: 16, paths: [d], strokeWidth: 2.0)
    }
}

/// Circular indeterminate loader ring (`rune_kit::feedback::Loader`).
public struct Loader<State> {
    public static var ringIcon: SVGIcon { FeedbackAssets.ringIcon }
    public static var arcIcon: SVGIcon { FeedbackAssets.arcIcon }
    public static var loopSpec: LoopSpec { FeedbackAssets.loaderLoopSpec }

    private var diameter: Float = 16
    private var inkColor: Color?

    public init() {}

    public func size(_ s: Float) -> Self { var c = self; c.diameter = s; return c }
    public func color(_ color: Color) -> Self { var c = self; c.inkColor = color; return c }

    public func build(_ k: Kit, key: String = "ring-loader") -> El<State> {
        let ink = inkColor ?? k.c.iconMuted
        return el()
            .key(key)
            .role(.progress)
            .label("Loading")
            .size(diameter, diameter)
            .child(icon(FeedbackAssets.ringIcon, size: diameter).key("\(key)-ring").color(ink).absolute(x: 0, y: 0).opacity(0.2))
            .child(icon(FeedbackAssets.arcIcon, size: diameter).key("\(key)-arc").color(ink).absolute(x: 0, y: 0))
    }
}

/// Linear progress bar (`rune_kit::feedback::Progress`).
public struct Progress<State> {
    public static var indeterminateSlide: LoopSpec { FeedbackAssets.indeterminateSlide }

    private var value: Float?
    private var labelText: String?
    private var showsValue: Bool = false

    /// `value` in `0...1`; `nil` is indeterminate.
    public init(value: Float?) {
        self.value = value
    }

    public func label(_ l: String) -> Self { var c = self; c.labelText = l; return c }
    public func showValue(_ on: Bool = true) -> Self { var c = self; c.showsValue = on; return c }

    public func build(_ k: Kit, key: String = "progress") -> El<State> {
        let c = k.c
        var root: El<State> = col().key(key).role(.progress).wFull().gap(4)
        if let labelText {
            root = root.label(labelText)
        }
        if let v = value {
            let clamped = v.clamped(to: 0...1)
            let pct = Int((clamped * 100).rounded())
            root = root.selected("\(pct)%")
        }
        if labelText != nil || showsValue {
            var header: El<State> = row().key("\(key)-header").wFull().gap(8).itemsCenter()
            if let labelText {
                header = header.child(text(labelText).key("\(key)-label").font(k.ty.textSmall).color(c.stdText))
            }
            header = header.child(spacer())
            if showsValue, let value {
                let pct = Int((value.clamped(to: 0...1) * 100).rounded())
                header = header.child(text("\(pct)%").key("\(key)-value").font(k.ty.textSmall).color(c.textWeak))
            }
            root = root.child(header)
        }

        let frac = value?.clamped(to: 0...1) ?? 0.25
        let fill: El<State> = el()
            .key("\(key)-fill")
            .hFull()
            .wFrac(frac)
            .rounded(999)
            .bg(c.borderActive)

        let track: El<State> = row()
            .key("\(key)-track")
            .wFull()
            .h(8)
            .rounded(999)
            .bg(c.surfaceBase)
            .border(1.0, c.borderWeak)
            .clip(true)
            .child(fill)

        return root.child(track)
    }
}

/// Small circular progress indicator (`rune_kit::feedback::ProgressCircle`), quantized to 2% steps.
public struct ProgressCircle<State> {
    public static func arcIcon(for value: Float) -> SVGIcon {
        let step = Int((value.clamped(to: 0...1) * 50.0).rounded())
        return FeedbackAssets.quantizedArcs[max(0, min(50, step))]
    }

    private var value: Float
    private var diameter: Float = 16
    private var labelText: String?

    public init(value: Float) {
        self.value = value
    }

    public func size(_ s: Float) -> Self { var c = self; c.diameter = s; return c }
    public func label(_ l: String) -> Self { var c = self; c.labelText = l; return c }

    public func build(_ k: Kit, key: String = "progress-circle") -> El<State> {
        let ink = k.c.iconMuted
        let clamped = value.clamped(to: 0...1)
        let pct = Int((clamped * 100).rounded())
        var root: El<State> = el()
            .key(key)
            .role(.progress)
            .selected("\(pct)%")
            .size(diameter, diameter)
            .child(icon(FeedbackAssets.ringIcon, size: diameter).key("\(key)-ring").absolute(x: 0, y: 0).color(ink).opacity(0.2))
            .child(icon(Self.arcIcon(for: clamped), size: diameter).key("\(key)-arc").absolute(x: 0, y: 0).color(ink))
        if let labelText {
            root = root.label(labelText)
        }
        return root
    }
}

/// Semantic tone for inline feedback banners (`rune_kit::feedback`).
public enum FeedbackTone: Sendable, Hashable {
    case info
    case success
    case warning
    case danger
}

extension Kit {
    /// Soft Radar 5x5 activity spinner (`rune_kit::feedback::Spinner`).
    public func radarSpinner<State>(
        key: String = "radar-spinner",
        size: Float = 18,
        color: Color? = nil
    ) -> El<State> {
        var spinner = Spinner<State>().size(size)
        if let color { spinner = spinner.color(color) }
        return spinner.build(self, key: key)
    }

    /// Circular indeterminate loader ring (`rune_kit::feedback::Loader`).
    public func ringLoader<State>(
        key: String = "ring-loader",
        size: Float = 16,
        color: Color? = nil
    ) -> El<State> {
        var loader = Loader<State>().size(size)
        if let color { loader = loader.color(color) }
        return loader.build(self, key: key)
    }

    /// Linear progress bar with optional label and percentage (`rune_kit::feedback::Progress`).
    public func progressBar<State>(
        key: String = "progress",
        value: Float?,
        label: String? = nil,
        showValue: Bool = false
    ) -> El<State> {
        var p = Progress<State>(value: value)
        if let label { p = p.label(label) }
        if showValue { p = p.showValue(true) }
        return p.build(self, key: key)
    }

    /// Small circular progress indicator (`rune_kit::feedback::ProgressCircle`).
    public func progressCircle<State>(
        key: String = "progress-circle",
        value: Float,
        size: Float = 16,
        label: String? = nil
    ) -> El<State> {
        var p = ProgressCircle<State>(value: value).size(size)
        if let label { p = p.label(label) }
        return p.build(self, key: key)
    }

    /// Inline status banner with tone styling, optional title, message, and dismiss/action slot.
    public func feedbackBanner<State>(
        key: String = "banner",
        tone: FeedbackTone = .info,
        title: String? = nil,
        message: String,
        actionLabel: String? = nil,
        onAction: ((inout State) -> Void)? = nil
    ) -> El<State> {
        let sc: StateColors = switch tone {
        case .info: c.info
        case .success: c.success
        case .warning: c.warning
        case .danger: c.danger
        }

        var content: El<State> = col().grow(1).minW(0).gap(2)
        if let title, !title.isEmpty {
            content = content.child(text(title).font(ty.uiMedium).color(sc.fg))
        }
        content = content.child(text(message).font(ty.textSmall).color(c.textBase))

        var container: El<State> = row()
            .key(key)
            .wFull()
            .p(12)
            .gap(10)
            .itemsCenter()
            .rounded(radius.md)
            .bg(sc.bg)
            .border(1.0, sc.border)
            .child(icon(KitIcons.info, size: 16).color(sc.icon))
            .child(content)

        if let actionLabel, let onAction {
            container = container.child(
                button(key: "\(key)-action", actionLabel, variant: .ghost, size: .sm) { s, _ in
                    onAction(&s)
                }
            )
        }
        return container
    }

    /// Centered empty-state placeholder view.
    public func emptyState<State>(
        key: String = "empty-state",
        icon svg: SVGIcon = KitIcons.search,
        title: String,
        description: String? = nil,
        actionLabel: String? = nil,
        onAction: ((inout State) -> Void)? = nil
    ) -> El<State> {
        var box: El<State> = col()
            .key(key)
            .wFull()
            .p(24)
            .gap(8)
            .itemsCenter()
            .justifyCenter()
            .child(icon(svg, size: 24).color(c.iconFaint))
            .child(text(title).font(ty.bodyMedium).color(c.textBase))

        if let description, !description.isEmpty {
            box = box.child(text(description).font(ty.textSmall).color(c.textMuted))
        }
        if let actionLabel, let onAction {
            box = box.child(
                el().pt(4).child(
                    button(key: "\(key)-action", actionLabel, variant: .neutral, size: .sm) { s, _ in
                        onAction(&s)
                    }
                )
            )
        }
        return box
    }

    /// Error boundary view showing an error message with optional retry action.
    public func errorBoundary<State>(
        key: String = "error-boundary",
        title: String = "Something went wrong",
        error: String,
        retryLabel: String = "Retry",
        onRetry: ((inout State) -> Void)? = nil
    ) -> El<State> {
        feedbackBanner(
            key: key,
            tone: .danger,
            title: title,
            message: error,
            actionLabel: onRetry != nil ? retryLabel : nil,
            onAction: onRetry
        )
    }
}
