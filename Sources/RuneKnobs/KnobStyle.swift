import Rune

/// Color palette for the RuneKnobs panel (`rune_knobs::Style`).
public struct KnobStyle: Sendable, Equatable {
    public var bg: Color
    /// Wells: the preset tray.
    public var inset: Color
    /// The selected preset chip.
    public var raised: Color
    public var fg: Color
    /// Labels and readouts.
    public var fg2: Color
    /// Group tabs at rest, icons, hints.
    public var fg3: Color
    /// A card of rows.
    public var fill: Color
    public var fillHover: Color
    public var fillSelected: Color
    /// A slider's fill at rest, hovered and dragged.
    public var slider: Color
    public var sliderHover: Color
    public var sliderActive: Color
    public var handle: Color
    public var border: Color
    /// The hairline between rows, over their fills.
    public var rule: Color
    /// The panel's top edge highlight.
    public var rim: Color
    public var shadow: Color
    /// The outline around a region.
    public var outline: Color

    public init(
        bg: Color,
        inset: Color,
        raised: Color,
        fg: Color,
        fg2: Color,
        fg3: Color,
        fill: Color,
        fillHover: Color,
        fillSelected: Color,
        slider: Color,
        sliderHover: Color,
        sliderActive: Color,
        handle: Color,
        border: Color,
        rule: Color,
        rim: Color,
        shadow: Color,
        outline: Color
    ) {
        self.bg = bg
        self.inset = inset
        self.raised = raised
        self.fg = fg
        self.fg2 = fg2
        self.fg3 = fg3
        self.fill = fill
        self.fillHover = fillHover
        self.fillSelected = fillSelected
        self.slider = slider
        self.sliderHover = sliderHover
        self.sliderActive = sliderActive
        self.handle = handle
        self.border = border
        self.rule = rule
        self.rim = rim
        self.shadow = shadow
        self.outline = outline
    }

    /// Dark knobs theme matching upstream `Style::dark()`.
    public static func dark() -> KnobStyle {
        func h(_ s: String) -> Color { Color.hex(s) ?? .black }
        return KnobStyle(
            bg: h("#1d1d1f"),
            inset: h("#161618"),
            raised: h("#3c3c3e"),
            fg: h("#fafafa"),
            fg2: h("#c4c4c6"),
            fg3: h("#8a8a8d"),
            fill: h("#29292b"),
            fillHover: h("#2f2f31"),
            fillSelected: h("#363638"),
            slider: h("#5a5a5c"),
            sliderHover: h("#626264"),
            sliderActive: h("#6e6e70"),
            handle: h("#ffffff"),
            border: h("#2c2c2e"),
            rule: Color.white.alpha(0.025),
            rim: h("#3a3a3c"),
            shadow: Color.black.alpha(0.45),
            outline: Color.white.alpha(0.55)
        )
    }

    /// Light knobs theme matching upstream `Style::light()`.
    public static func light() -> KnobStyle {
        func h(_ s: String) -> Color { Color.hex(s) ?? .white }
        return KnobStyle(
            bg: h("#ffffff"),
            inset: h("#ececee"),
            raised: h("#ffffff"),
            fg: h("#1d1d1f"),
            fg2: h("#4a4a4d"),
            fg3: h("#8a8a8d"),
            fill: h("#f3f3f5"),
            fillHover: h("#ececee"),
            fillSelected: h("#e4e4e7"),
            slider: h("#dcdce0"),
            sliderHover: h("#d3d3d8"),
            sliderActive: h("#c8c8ce"),
            handle: h("#1d1d1f"),
            border: h("#e2e2e5"),
            rule: Color.black.alpha(0.05),
            rim: h("#ffffff"),
            shadow: Color.black.alpha(0.18),
            outline: Color.black.alpha(0.45)
        )
    }

    public static let `default` = KnobStyle.dark()
}

/// Phosphor Icons (regular, 256 grid) used in the knobs panel (`crates/rune-knobs/src/icons.rs`).
public enum KnobIcons {
    public static let undo = SVGIcon(
        viewBox: 256,
        paths: ["M232,144a64.07,64.07,0,0,1-64,64H80a8,8,0,0,1,0-16h88a48,48,0,0,0,0-96H51.31l34.35,34.34a8,8,0,0,1-11.32,11.32l-48-48a8,8,0,0,1,0-11.32l48-48A8,8,0,0,1,85.66,45.66L51.31,80H168A64.07,64.07,0,0,1,232,144Z"]
    )

    public static let random = SVGIcon(
        viewBox: 256,
        paths: ["M192,32H64A32,32,0,0,0,32,64V192a32,32,0,0,0,32,32H192a32,32,0,0,0,32-32V64A32,32,0,0,0,192,32Zm16,160a16,16,0,0,1-16,16H64a16,16,0,0,1-16-16V64A16,16,0,0,1,64,48H192a16,16,0,0,1,16,16ZM104,92A12,12,0,1,1,92,80,12,12,0,0,1,104,92Zm72,0a12,12,0,1,1-12-12A12,12,0,0,1,176,92Zm-72,72a12,12,0,1,1-12-12A12,12,0,0,1,104,164Zm36-36a12,12,0,1,1-12-12A12,12,0,0,1,140,128Zm36,36a12,12,0,1,1-12-12A12,12,0,0,1,176,164Z"]
    )

    public static let reset = SVGIcon(
        viewBox: 256,
        paths: ["M224,128a96,96,0,0,1-94.71,96H128A95.38,95.38,0,0,1,62.1,197.8a8,8,0,0,1,11-11.63A80,80,0,1,0,71.43,71.39a3.07,3.07,0,0,1-0.26,0.25L44.59,96H72a8,8,0,0,1,0,16H24a8,8,0,0,1-8-8V56a8,8,0,0,1,16,0V85.8L60.25,60A96,96,0,0,1,224,128Z"]
    )

    public static let copy = SVGIcon(
        viewBox: 256,
        paths: ["M216,32H88a8,8,0,0,0-8,8V80H40a8,8,0,0,0-8,8V216a8,8,0,0,0,8,8H168a8,8,0,0,0,8-8V176h40a8,8,0,0,0,8-8V40A8,8,0,0,0,216,32ZM160,208H48V96H160Zm48-48H176V88a8,8,0,0,0-8-8H96V48H208Z"]
    )

    public static let target = SVGIcon(
        viewBox: 256,
        paths: ["M232,120h-8.34A96.14,96.14,0,0,0,136,32.34V24a8,8,0,0,0-16,0v8.34A96.14,96.14,0,0,0,32.34,120H24a8,8,0,0,0,0,16h8.34A96.14,96.14,0,0,0,120,223.66V232a8,8,0,0,0,16,0v-8.34A96.14,96.14,0,0,0,223.66,136H232a8,8,0,0,0,0-16Zm-96,87.6V200a8,8,0,0,0-16,0v7.6A80.15,80.15,0,0,1,48.4,136H56a8,8,0,0,0,0-16H48.4A80.15,80.15,0,0,1,120,48.4V56a8,8,0,0,0,16,0V48.4A80.15,80.15,0,0,1,207.6,120H200a8,8,0,0,0,0,16h7.6A80.15,80.15,0,0,1,136,207.6ZM128,88a40,40,0,1,0,40,40A40,40,0,0,0,128,88Zm0,64a24,24,0,1,1,24-24A24,24,0,0,1,128,152Z"]
    )
}
