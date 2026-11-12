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
                cycle: Cycle(period: loopDuration, phase: Float(round3(at)), stops: frames, still: still)
            )
        }
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
        let ink = color ?? c.stdText
        let u = size / 16.0
        var box: El<State> = el()
            .key(key)
            .label("Loading")
            .size(size, size)

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

    /// Circular indeterminate loader ring (`rune_kit::feedback::Loader`).
    public func ringLoader<State>(
        key: String = "ring-loader",
        size: Float = 16,
        color: Color? = nil
    ) -> El<State> {
        let ink = color ?? c.iconMuted
        let ringIcon = SVGIcon(viewBox: 16, paths: ["M8 2A6 6 0 1 1 7.99 2"], strokeWidth: 2.0)
        let arcIcon = SVGIcon(viewBox: 16, paths: ["M8 2A6 6 0 0 1 13.258 10.89"], strokeWidth: 2.0)
        return el()
            .key(key)
            .label("Loading")
            .size(size, size)
            .child(icon(ringIcon, size: size).color(ink).absolute(x: 0, y: 0).opacity(0.2))
            .child(icon(arcIcon, size: size).color(ink).absolute(x: 0, y: 0))
    }

    /// Linear progress bar with optional label and percentage (`rune_kit::feedback::Progress`).
    public func progressBar<State>(
        key: String = "progress",
        value: Float?,
        label: String? = nil,
        showValue: Bool = false
    ) -> El<State> {
        var root: El<State> = col().key(key).wFull().gap(4)
        if let label {
            root = root.label(label)
        }
        if label != nil || showValue {
            var header: El<State> = row().wFull().gap(8).itemsCenter()
            if let label {
                header = header.child(text(label).font(ty.textSmall).color(c.stdText))
            }
            header = header.child(spacer())
            if showValue, let value {
                let pct = Int((value.clamped(to: 0...1) * 100).rounded())
                header = header.child(text("\(pct)%").font(ty.textSmall).color(c.textWeak))
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

    /// Small circular progress indicator (`rune_kit::feedback::ProgressCircle`).
    public func progressCircle<State>(
        key: String = "progress-circle",
        value: Float,
        size: Float = 16,
        label: String? = nil
    ) -> El<State> {
        let clamped = value.clamped(to: 0...1)
        let pct = Int((clamped * 100).rounded())
        var root: El<State> = el()
            .key(key)
            .size(size, size)
            .rounded(size * 0.5)
            .border(2.0, c.borderWeak)
            .center()
            .child(
                el()
                    .size(max(2, size * 0.55 * clamped), max(2, size * 0.55 * clamped))
                    .rounded(size * 0.5)
                    .bg(c.borderActive)
            )
        if let label {
            root = root.label("\(label) \(pct)%")
        }
        return root
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
