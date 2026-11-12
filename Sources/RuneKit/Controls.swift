import Foundation
import Rune
import RuneMotion

public enum ButtonVariant: Sendable, Hashable {
    case primary
    case accent
    case neutral
    case ghost
    case danger
}

public enum ControlSize: Sendable, Hashable {
    case sm
    case md
    case lg

    public var height: Float {
        switch self {
        case .sm: return 26
        case .md: return 32
        case .lg: return 38
        }
    }

    public var horizontalPadding: Float {
        switch self {
        case .sm: return 10
        case .md: return 14
        case .lg: return 18
        }
    }
}

extension Kit {
    /// Interactive button (`Kit::button`).
    public func button<State>(
        key: String,
        _ labelText: String,
        variant: ButtonVariant = .neutral,
        size: ControlSize = .md,
        leadingIcon: SVGIcon? = nil,
        trailingIcon: SVGIcon? = nil,
        disabled: Bool = false,
        onClick: @escaping (inout State, inout Tx) -> Void
    ) -> El<State> {
        let bgCol: Color
        let fgCol: Color
        let hoverCol: Color
        let pressCol: Color
        let borderCol: Color
        let borderW: Float
        let elev: [Shadow]

        switch variant {
        case .primary:
            bgCol = c.bgContrast
            fgCol = c.textContrast
            hoverCol = c.contrastHover
            pressCol = c.contrastPressed
            borderCol = .transparent
            borderW = 0
            elev = elevation.buttonContrast
        case .accent:
            bgCol = c.bgAccent
            fgCol = c.submitFg
            hoverCol = c.submitHover
            pressCol = c.contrastPressed
            borderCol = .transparent
            borderW = 0
            elev = elevation.buttonContrast
        case .neutral:
            bgCol = c.bgButtonNeutral
            fgCol = c.textBase
            hoverCol = c.hover
            pressCol = c.pressed
            borderCol = c.borderBase
            borderW = 1
            elev = elevation.buttonNeutral
        case .ghost:
            bgCol = .transparent
            fgCol = c.textBase
            hoverCol = c.hover
            pressCol = c.pressed
            borderCol = .transparent
            borderW = 0
            elev = []
        case .danger:
            bgCol = c.danger.bg
            fgCol = c.danger.fg
            hoverCol = c.danger.fg.alpha(0.10)
            pressCol = c.danger.fg.alpha(0.18)
            borderCol = c.danger.border
            borderW = 1
            elev = []
        }

        let fontStyle = (size == .sm) ? ty.smallMedium : ty.uiMedium
        var node: El<State> = row()
            .key(key)
            .role(.button)
            .label(labelText)
            .h(size.height)
            .px(size.horizontalPadding)
            .gap(6)
            .center()
            .rounded(radius.md)
            .bg(bgCol)
            .border(borderW, borderCol)
            .shadows(shadowLayers(elev))
            .animate(motion.control)

        if let svg = leadingIcon {
            node = node.child(icon(svg, size: 14).color(fgCol))
        }
        node = node.child(text(labelText).font(fontStyle).color(fgCol).noWrap())
        if let svg = trailingIcon {
            node = node.child(icon(svg, size: 14).color(fgCol))
        }

        if disabled {
            return node.opacity(0.45).inert(true)
        }
        return node
            .hover(hoverCol)
            .press(pressCol)
            .pressScale(0.97)
            .focusRing(c.borderFocus)
            .onClick(onClick)
    }

    /// Compact square icon button (`Kit::icon_button`).
    public func iconButton<State>(
        key: String,
        svg: SVGIcon,
        label labelText: String,
        size: ControlSize = .md,
        variant: ButtonVariant = .ghost,
        disabled: Bool = false,
        onClick: @escaping (inout State, inout Tx) -> Void
    ) -> El<State> {
        let bgCol: Color
        let fgCol: Color
        let hoverCol: Color
        let pressCol: Color
        let borderCol: Color
        let borderW: Float
        let elev: [Shadow]

        switch variant {
        case .primary:
            bgCol = c.bgContrast
            fgCol = c.textContrast
            hoverCol = c.contrastHover
            pressCol = c.contrastPressed
            borderCol = .transparent
            borderW = 0
            elev = elevation.buttonContrast
        case .accent:
            bgCol = c.bgAccent
            fgCol = c.submitFg
            hoverCol = c.submitHover
            pressCol = c.contrastPressed
            borderCol = .transparent
            borderW = 0
            elev = elevation.buttonContrast
        case .neutral:
            bgCol = c.bgButtonNeutral
            fgCol = c.iconBase
            hoverCol = c.hover
            pressCol = c.pressed
            borderCol = c.borderBase
            borderW = 1
            elev = elevation.buttonNeutral
        case .ghost:
            bgCol = .transparent
            fgCol = c.iconBase
            hoverCol = c.hover
            pressCol = c.pressed
            borderCol = .transparent
            borderW = 0
            elev = []
        case .danger:
            bgCol = c.danger.bg
            fgCol = c.danger.fg
            hoverCol = c.danger.fg.alpha(0.10)
            pressCol = c.danger.fg.alpha(0.18)
            borderCol = c.danger.border
            borderW = 1
            elev = []
        }

        let node: El<State> = row()
            .key(key)
            .role(.button)
            .label(labelText)
            .help(labelText)
            .square(size.height)
            .center()
            .rounded(radius.md)
            .bg(bgCol)
            .border(borderW, borderCol)
            .shadows(shadowLayers(elev))
            .animate(motion.control)
            .child(icon(svg, size: 16).color(fgCol))

        if disabled {
            return node.opacity(0.45).inert(true)
        }
        return node
            .hover(hoverCol)
            .press(pressCol)
            .pressScale(0.95)
            .focusRing(c.borderFocus)
            .onClick(onClick)
    }

    /// Animated toggle switch (`Kit::switch`).
    public func switchControl<State>(
        key: String,
        isOn: Bool,
        label labelText: String? = nil,
        disabled: Bool = false,
        onToggle: @escaping (inout State, Bool) -> Void
    ) -> El<State> {
        let trackW: Float = 38
        let trackH: Float = 22
        let knobSize: Float = 18
        let pad: Float = 2

        let trackFill = isOn ? c.bgAccent : c.layer03
        let knobX = isOn ? (trackW - knobSize - pad) : pad

        let knob: El<State> = el()
            .key("\(key)-knob")
            .square(knobSize)
            .pill()
            .bg(isOn ? c.knobOn : c.knob)
            .shadows(elevation.knob)
            .absolute(x: knobX, y: pad)
            .animateLayout(motion.control)

        var track: El<State> = el()
            .key(key)
            .role(.switchControl)
            .selected(isOn ? "true" : "false")
            .size(trackW, trackH)
            .pill()
            .bg(trackFill)
            .animate(motion.control)
            .child(knob)

        if let labelText {
            track = track.label(labelText)
        }
        if disabled {
            return track.opacity(0.45).inert(true)
        }
        return track
            .pressScale(0.96)
            .focusRing(c.borderFocus)
            .onClick { state, _ in onToggle(&state, !isOn) }
    }

    /// Animated checkbox (`Kit::checkbox`).
    public func checkbox<State>(
        key: String,
        checked: Bool,
        indeterminate: Bool = false,
        label labelText: String? = nil,
        disabled: Bool = false,
        onToggle: @escaping (inout State, Bool) -> Void
    ) -> El<State> {
        let active = checked || indeterminate
        let boxFill = active ? c.bgAccent : c.surfaceWeak
        let boxBorder = active ? c.bgAccent : c.borderStrong

        var box: El<State> = row()
            .key("\(key)-box")
            .square(18)
            .center()
            .rounded(radius.sm)
            .bg(boxFill)
            .border(1.0, boxBorder)
            .animate(motion.control)

        if checked {
            box = box.child(
                icon(KitIcons.check, size: 12)
                    .key("\(key)-mark")
                    .color(c.submitFg)
                    .transition(Transition.scale(0.6).kitRules(small: true).spring(motion.control))
            )
        } else if indeterminate {
            box = box.child(
                icon(KitIcons.minus, size: 12)
                    .key("\(key)-indeterminate")
                    .color(c.submitFg)
                    .transition(Transition.scale(0.6).kitRules(small: true).spring(motion.control))
            )
        }

        var wrapper: El<State> = row()
            .key(key)
            .role(.checkbox)
            .selected(indeterminate ? "mixed" : (checked ? "true" : "false"))
            .itemsCenter()
            .gap(8)
            .child(box)

        if let labelText {
            wrapper = wrapper
                .label(labelText)
                .child(text(labelText).font(ty.ui).color(c.textBase))
        }

        if disabled {
            return wrapper.opacity(0.45).inert(true)
        }
        return wrapper
            .focusRing(c.borderFocus)
            .onClick { state, _ in onToggle(&state, !checked) }
    }

    /// Roving radio group (`Kit::radio_group`).
    public func radioGroup<State, ID: Hashable & CustomStringConvertible>(
        key: String,
        options: [(id: ID, label: String)],
        selected: ID,
        onSelect: @escaping (inout State, ID) -> Void
    ) -> El<State> {
        var container: El<State> = col()
            .key(key)
            .gap(8)
            .focusGroup(true)

        for opt in options {
            let isSel = (opt.id == selected)
            var circle: El<State> = row()
                .square(18)
                .center()
                .pill()
                .bg(isSel ? c.bgAccent : c.surfaceWeak)
                .border(1.0, isSel ? c.bgAccent : c.borderStrong)
                .animate(motion.control)

            if isSel {
                circle = circle.child(
                    el()
                        .key("\(key)-\(opt.id)-dot")
                        .square(8)
                        .pill()
                        .bg(c.submitFg)
                        .transition(Transition.scale(0.5).kitRules(small: true))
                )
            }

            let item: El<State> = row()
                .key("\(key)-\(opt.id)")
                .role(.radio)
                .label(opt.label)
                .selected(isSel ? "true" : "false")
                .itemsCenter()
                .gap(8)
                .child(circle)
                .child(text(opt.label).font(ty.ui).color(c.textBase))
                .focusRing(c.borderFocus)
                .onClick { state, _ in onSelect(&state, opt.id) }

            container = container.child(item)
        }
        return container
    }

    /// Segmented control / pill tab bar with shared-element sliding indicator (`Travel.screen`)!
    public func segmentedControl<State, ID: Hashable & CustomStringConvertible>(
        key: String,
        options: [(id: ID, label: String)],
        selected: ID,
        onSelect: @escaping (inout State, ID) -> Void
    ) -> El<State> {
        var bar: El<State> = row()
            .key(key)
            .p(3)
            .gap(2)
            .rounded(radius.lg)
            .bg(c.layer02)
            .border(1.0, c.borderMuted)
            .focusGroup(true)

        for opt in options {
            let isSel = (opt.id == selected)
            var seg: El<State> = row()
                .key("\(key)-\(opt.id)")
                .role(.tab)
                .label(opt.label)
                .itemSelected(isSel)
                .grow(1)
                .h(26)
                .px(12)
                .center()
                .rounded(radius.md)

            if isSel {
                // Shared-element active pill travelling smoothly across segments via `Travel.screen`!
                seg = seg.child(
                    el()
                        .key("\(key)-active-pill")
                        .pin(top: 0, right: 0, bottom: 0, left: 0)
                        .rounded(radius.md)
                        .bg(c.surfaceRaised)
                        .shadows(shadowLayers(elevation.raised))
                        .animateLayout(LayoutAnim(spring: Tok.Motion.MORPH, travel: .screen))
                )
            }

            seg = seg
                .child(
                    text(opt.label)
                        .font(isSel ? ty.uiMedium : ty.ui)
                        .color(isSel ? c.textBase : c.textMuted)
                        .noWrap()
                        .z(1)
                )
                .focusRing(c.borderFocus)
                .onClick { state, _ in onSelect(&state, opt.id) }

            bar = bar.child(seg)
        }
        return bar
    }

    /// Continuous draggable slider (`Kit::slider`) supporting click-to-jump and `Escape` drag cancel.
    public func slider<State>(
        key: String,
        value: Float,
        range: ClosedRange<Float> = 0...1,
        width: Float? = nil,
        onChange: @escaping (inout State, Float) -> Void
    ) -> El<State> {
        let span = max(1e-5, range.upperBound - range.lowerBound)
        let frac = ((value - range.lowerBound) / span).clamped(to: 0...1)
        let trackH: Float = 6
        let knobD: Float = 16

        var root: El<State> = row()
            .key(key)
            .role(.slider)
            .selected(String(format: "%.2f", value))
            .h(24)
            .itemsCenter()
            .focusRing(c.borderFocus)
            .onDrag { state, drag, _ in
                let usable = max(1.0, drag.size.x - knobD)
                let f = ((drag.local.x - knobD * 0.5) / usable).clamped(to: 0...1)
                let newVal = range.lowerBound + f * span
                onChange(&state, newVal)
            }
            .onKey { state, ev, _ in
                let step = span * 0.05
                if ev.key == .arrowLeft || ev.key == .arrowDown {
                    onChange(&state, (value - step).clamped(to: range))
                    return true
                } else if ev.key == .arrowRight || ev.key == .arrowUp {
                    onChange(&state, (value + step).clamped(to: range))
                    return true
                }
                return false
            }

        if let width {
            root = root.w(width)
        } else {
            root = root.wFull()
        }

        let track: El<State> = row()
            .key("\(key)-track")
            .wFull()
            .h(trackH)
            .pill()
            .bg(c.layer03)
            .itemsCenter()
            .child(
                el()
                    .key("\(key)-fill")
                    .wFrac(frac)
                    .hFull()
                    .pill()
                    .bg(c.bgAccent)
            )

        var knob: El<State> = el()
            .key("\(key)-knob")
            .square(knobD)
            .pill()
            .bg(c.knob)
            .border(0.5, c.borderBase)
            .shadows(shadowLayers(elevation.knob))
            .animateLayout(motion.control)

        if let width {
            knob = knob.absolute(x: frac * max(0, width - knobD), y: (24 - knobD) * 0.5)
            return root.child(track).child(knob)
        }
        return root.child(track).child(knob.ml(-knobD * 0.5))
    }
}
