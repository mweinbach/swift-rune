import Foundation
import Rune
import RuneMotion

public enum ControlVisualState: Sendable, Hashable, Equatable {
    case rest
    case hover
    case pressed
    case focus
    case disabled
}

public enum ControlSize: Sendable, Hashable {
    case mini
    case small
    case regular
    case large
    case extraLarge
    case sm
    case md
    case lg

    public var height: Float {
        switch self {
        case .mini: return 16
        case .small: return 20
        case .regular: return 24
        case .large: return 28
        case .extraLarge: return 36
        case .sm: return 26
        case .md: return 32
        case .lg: return 38
        }
    }

    public var horizontalPadding: Float {
        switch self {
        case .mini: return 6
        case .small: return 8
        case .regular: return 10
        case .large: return 12
        case .extraLarge: return 14
        case .sm: return 10
        case .md: return 14
        case .lg: return 18
        }
    }

    /// Upstream `NSSwitch` dimensions `(trackW, trackH, knobW, knobH, inset)`.
    fileprivate var switchMetrics: (tw: Float, th: Float, kw: Float, kh: Float, inset: Float) {
        switch self {
        case .mini: return (36, 16, 21, 14, 1)
        case .small, .sm: return (44, 20, 26, 16, 2)
        case .regular, .md: return (54, 24, 32, 20, 2)
        case .large, .lg: return (64, 28, 38, 24, 2)
        case .extraLarge: return (80, 36, 48, 30, 3)
        }
    }
}

/// Source-over composite matching `rune_kit::over`.
internal func kitOver(_ top: Color, _ bottom: Color) -> Color {
    let a = top.a + bottom.a * (1.0 - top.a)
    guard a > 0 else { return .transparent }
    let inv = 1.0 - top.a
    let r = (top.r * top.a + bottom.r * bottom.a * inv) / a
    let g = (top.g * top.a + bottom.g * bottom.a * inv) / a
    let b = (top.b * top.a + bottom.b * bottom.a * inv) / a
    return Color(r: r, g: g, b: b, a: a)
}

/// Press overlay that composites cleanly over `hover` (`rune_kit::press_over`).
internal func kitPressOver(_ hover: Color, _ pressed: Color) -> Color {
    if hover.a >= 0.999 { return pressed }
    let a = ((pressed.a - hover.a) / (1.0 - hover.a)).clamped(to: 0...1)
    return pressed.alpha(a)
}

/// Fluent toggle switch matching `rune_kit::Switch`.
public struct Switch<State> {
    private var labelText: String?
    private var checked: Bool
    private var isStandard: Bool = false
    private var isWeb: Bool = false
    private var controlSize: ControlSize = .mini
    private var hidesLabel: Bool = false
    private var descriptionText: String?
    private var visualState: ControlVisualState = .rest
    private var onPress: ((inout State, inout Tx) -> Void)?

    public init(checked: Bool) {
        self.checked = checked
    }

    public func label(_ l: String) -> Self { var c = self; c.labelText = l; return c }
    public func hideLabel(_ hide: Bool = true) -> Self { var c = self; c.hidesLabel = hide; return c }
    public func description(_ d: String) -> Self { var c = self; c.descriptionText = d; return c }
    public func standard(_ on: Bool = true) -> Self { var c = self; c.isStandard = on; return c }
    public func web(_ on: Bool = true) -> Self { var c = self; c.isWeb = on; return c }
    public func controlSize(_ s: ControlSize) -> Self { var c = self; c.controlSize = s; return c }
    public func state(_ s: ControlVisualState) -> Self { var c = self; c.visualState = s; return c }
    public func disabled(_ d: Bool) -> Self {
        var c = self
        if d { c.visualState = .disabled }
        return c
    }
    public func onToggle(_ f: @escaping (inout State) -> Void) -> Self {
        var c = self
        c.onPress = { st, _ in f(&st) }
        return c
    }
    public func onToggleTx(_ f: @escaping (inout State, inout Tx) -> Void) -> Self {
        var c = self
        c.onPress = f
        return c
    }

    public func build(_ k: Kit, key: String = "switch") -> El<State> {
        let c = k.c
        let hover = visualState == .hover
        let disabled = visualState == .disabled
        var control: El<State> = switch (isStandard, isWeb) {
        case (true, _): standardControl(k, key: key, hover: hover)
        case (false, true): webControl(k, key: key)
        case (false, false): compactControl(k, key: key)
        }
        if disabled && !isStandard {
            control = control.opacity(0.5)
        }
        if visualState == .focus && !isStandard {
            control = control.border(2.0, c.borderFocus)
        }

        var root: El<State> = row()
            .key(key)
            .role(.switchControl)
            .selected(checked ? "true" : "false")
            .gap(8)
            .itemsCenter()

        if let labelText {
            root = root.label(labelText)
            if !hidesLabel {
                let font = isStandard ? k.ty.textSmall.lh(16) : k.ty.small.lh(16)
                let col = isStandard ? c.stdText : c.textFaint
                root = root.child(text(labelText).key("\(key)-label").font(font).color(col))
            }
        }
        if let descriptionText {
            root = root
                .help(descriptionText)
                .child(text(descriptionText).key("\(key)-description").font(k.ty.textXsmall.lh(15.6)).color(c.stdText))
        }

        control = control.key("\(key)-control")
        root = root.child(control).focusable(!disabled).inert(disabled)
        if !disabled {
            root = root.focusRing(c.borderFocus, offset: 1.0)
            if let onPress {
                root = root.onClick(onPress)
            }
        }
        return root
    }

    private func trackAppearance(_ k: Kit) -> (base: Color, sheenBottom: Color, elev: [Shadow], knob: Color, overlay: Color) {
        let c = k.c
        if checked {
            return (c.bgAccent, k.lightOn(0.1, backdrop: c.bgAccent), k.elevation.switchOn, c.knobOn, k.on(c.contrastHover, backdrop: c.bgAccent))
        }
        return (c.layer04, k.lightOn(0.2, backdrop: c.layer04), k.elevation.switchOff, c.knob, c.hover)
    }

    private func buildThumb(_ k: Kit, key: String, w: Float, h: Float, x: Float, y: Float, radius: Float, knobColor: Color) -> El<State> {
        let c = k.c
        let thumb: El<State> = el()
            .key("\(key)-thumb")
            .size(w, h)
            .absolute(x: x, y: y)
            .rounded(radius)
            .bg(knobColor)
            .linearGradient(top: k.on(c.depthTop, backdrop: knobColor), bottom: k.on(c.depthBottom, backdrop: knobColor))
            .border(0.5, k.on(c.depthTop, backdrop: knobColor))
        return k.elevate(thumb, k.elevation.elements).animate(k.motion.control).animateLayout(k.motion.control)
    }

    private func compactControl(_ k: Kit, key: String) -> El<State> {
        let app = trackAppearance(k)
        let (tw, th, kw, kh, inset) = controlSize.switchMetrics
        let stretch: Float = switch visualState {
        case .hover: (kh * 0.15).rounded()
        case .pressed: (kh * 0.35).rounded()
        default: 0
        }
        let w = kw + stretch
        let x = checked ? (tw - inset - w) : inset
        let thumb = buildThumb(k, key: key, w: w, h: kh, x: x, y: inset, radius: kh * 0.5, knobColor: app.knob)
        let fill = (visualState == .hover) ? kitOver(app.overlay, app.base) : app.base
        var track: El<State> = el()
            .size(tw, th)
            .rounded(th * 0.5)
            .bg(fill)
            .linearGradient(top: k.light(0.0), bottom: app.sheenBottom)
        if visualState == .rest {
            track = track.hover(app.overlay)
        }
        return k.elevate(track, app.elev).animate(k.motion.control).child(thumb)
    }

    private func webControl(_ k: Kit, key: String) -> El<State> {
        let app = trackAppearance(k)
        let hover = visualState == .hover
        let (w, r): (Float, Float) = hover ? (13, 3) : (12, 2)
        let x: Float = 2 + (checked ? (24 - 4 - w) : 0)
        let thumb = buildThumb(k, key: key, w: w, h: 12, x: x, y: 2, radius: r, knobColor: app.knob)
        let fill = hover ? kitOver(app.overlay, app.base) : app.base
        var track: El<State> = el()
            .size(24, 16)
            .rounded(4)
            .bg(fill)
            .linearGradient(top: k.light(0.0), bottom: app.sheenBottom)
        if visualState == .rest {
            track = track.hover(app.overlay)
        }
        return k.elevate(track, app.elev).animate(k.motion.control).child(thumb)
    }

    private func standardControl(_ k: Kit, key: String, hover: Bool) -> El<State> {
        let c = k.c
        let disabled = visualState == .disabled
        let (fill, border): (Color, Color) = if disabled {
            (c.surfaceDisabled, c.borderDisabled)
        } else if hover {
            (c.surfaceHover, c.borderHover)
        } else if checked {
            (c.stdIconStrong, c.stdIconStrong)
        } else {
            (c.surfaceBase, c.borderWeak)
        }
        let thumbFill = disabled ? c.stdIcon : c.stdIconInvert
        let stretch: Float = (visualState == .pressed) ? 4 : 0
        var thumb: El<State> = el().key("\(key)-thumb").bg(thumbFill)
        if checked {
            thumb = thumb.size(14 + stretch, 14).absolute(x: 13 - stretch, y: 1).rounded(7)
        } else {
            thumb = thumb.size(16 + stretch, 16).absolute(x: 0, y: 0).rounded(8).border(1, c.stdBorder)
        }
        thumb = k.elevate(thumb, k.elevation.knob).animate(k.motion.control).animateLayout(k.motion.control)
        return el()
            .size(28, 16)
            .rounded(8)
            .bg(fill)
            .border(1, border)
            .animate(k.motion.control)
            .child(thumb)
    }
}

/// Fluent checkbox matching `rune_kit::Checkbox`.
public struct Checkbox<State> {
    private var labelText: String?
    private var checked: Bool
    private var isIndeterminate: Bool = false
    private var hidesLabel: Bool = false
    private var descriptionText: String?
    private var customIcon: SVGIcon?
    private var visualState: ControlVisualState = .rest
    private var onPress: ((inout State, inout Tx) -> Void)?

    public init(checked: Bool) {
        self.checked = checked
    }

    public func label(_ l: String) -> Self { var c = self; c.labelText = l; return c }
    public func hideLabel(_ hide: Bool = true) -> Self { var c = self; c.hidesLabel = hide; return c }
    public func description(_ d: String) -> Self { var c = self; c.descriptionText = d; return c }
    public func indeterminate(_ on: Bool = true) -> Self { var c = self; c.isIndeterminate = on; return c }
    public func icon(_ svg: SVGIcon) -> Self { var c = self; c.customIcon = svg; return c }
    public func state(_ s: ControlVisualState) -> Self { var c = self; c.visualState = s; return c }
    public func disabled(_ d: Bool) -> Self {
        var c = self
        if d { c.visualState = .disabled }
        return c
    }
    public func onToggle(_ f: @escaping (inout State) -> Void) -> Self {
        var c = self
        c.onPress = { st, _ in f(&st) }
        return c
    }
    public func onToggleTx(_ f: @escaping (inout State, inout Tx) -> Void) -> Self {
        var c = self
        c.onPress = f
        return c
    }

    public func build(_ k: Kit, key: String = "checkbox") -> El<State> {
        let c = k.c
        let on = checked || isIndeterminate
        let (fill, border): (Color, Color) = switch visualState {
        case .disabled: (c.surfaceDisabled, c.borderDisabled)
        case .hover: (c.surfaceHover, c.borderHover)
        case .focus: (on ? c.surfaceWeak : .transparent, c.borderActive)
        default: on ? (c.surfaceWeak, c.stdBorder) : (.transparent, c.borderWeak)
        }
        let glyphEl: El<State> = if let customIcon {
            Rune.icon(customIcon, size: 14)
        } else if isIndeterminate {
            Rune.icon(KitIcons.minus, size: 10)
        } else {
            Rune.icon(k.glyph.check, size: 10)
        }
        var control: El<State> = el()
            .key("\(key)-control")
            .size(16, 16)
            .center()
            .rounded(k.radius.sm)
            .bg(fill)
            .border(1.0, border)
            .animate(k.motion.control)
            .child(glyphEl.key("\(key)-mark").color(c.stdIcon).opacity(on ? 1.0 : 0.0))
        if visualState == .rest {
            control = control.hover(c.surfaceHover)
        }

        let disabled = visualState == .disabled
        var root: El<State> = row()
            .key(key)
            .role(.checkbox)
            .selected(isIndeterminate ? "mixed" : (checked ? "true" : "false"))
            .gap(12)
            .itemsCenter()
            .child(control)
            .focusable(!disabled)
            .inert(disabled)
        if !disabled {
            root = root.focusRing(c.borderActive, offset: 1.0)
        }

        if let descriptionText {
            root = root.help(descriptionText)
        }
        if let labelText {
            root = root.label(labelText)
            var content: El<State> = col().key("\(key)-content")
            if !hidesLabel {
                content = content.child(text(labelText).key("\(key)-label").font(k.ty.textSmall.lh(24)).color(c.stdText))
            }
            if let descriptionText {
                content = content.child(text(descriptionText).key("\(key)-description").font(k.ty.textXsmall.lh(15.6)).color(c.stdText))
            }
            if !content.children.isEmpty {
                root = root.child(content)
            }
        }
        if !disabled, let onPress {
            root = root.onClick(onPress)
        }
        return root
    }
}

/// Fluent radio item matching `rune_kit::RadioItem`.
public struct RadioItem<State> {
    public var labelText: String
    public var descriptionText: String?
    public var checked: Bool
    public var visualState: ControlVisualState = .rest
    public var isInvalid: Bool = false
    private var onPress: ((inout State, inout Tx) -> Void)?

    public init(label: String, checked: Bool) {
        self.labelText = label
        self.checked = checked
    }

    public func description(_ d: String) -> Self { var c = self; c.descriptionText = d; return c }
    public func state(_ s: ControlVisualState) -> Self { var c = self; c.visualState = s; return c }
    public func disabled(_ d: Bool) -> Self {
        var c = self
        if d { c.visualState = .disabled }
        return c
    }
    public func onSelect(_ f: @escaping (inout State) -> Void) -> Self {
        var c = self
        c.onPress = { st, _ in f(&st) }
        return c
    }
    public func onSelectTx(_ f: @escaping (inout State, inout Tx) -> Void) -> Self {
        var c = self
        c.onPress = f
        return c
    }

    public func build(_ k: Kit, key: String = "radio-item") -> El<State> {
        let c = k.c
        let disabled = visualState == .disabled
        let hover = visualState == .hover
        let (base, sheen): (Color, Color) = if checked {
            (c.bgAccent, k.lightOn(0.2, backdrop: c.bgAccent))
        } else if isInvalid {
            (c.danger.bg, k.light(0.0))
        } else {
            (c.bgBase, k.light(0.06))
        }
        let overlay = checked ? k.on(c.contrastHover, backdrop: c.bgAccent) : c.hover
        let ring = (isInvalid && !checked) ? c.danger.border : c.borderStrong
        var control: El<State> = el()
            .key("\(key)-control")
            .size(16, 16)
            .absolute(x: 0, y: 2)
            .rounded(8)
            .bg(hover ? kitOver(overlay, base) : base)
            .linearGradient(top: sheen, bottom: k.light(0.0))
            .shadows([Shadow(x: 0, y: 0, blur: 0, spread: 0.5, color: ring, inset: true)])
            .animate(k.motion.control)
        if checked {
            let dot = c.knobOn
            control = control.child(
                el()
                    .key("\(key)-dot")
                    .size(6, 6)
                    .absolute(x: 5, y: 5)
                    .rounded(3)
                    .bg(dot)
                    .shadows([
                        Shadow(x: 0, y: 0, blur: 0, spread: 0.5, color: k.on(c.depthTop, backdrop: dot), inset: true),
                        Shadow(x: 0, y: 0.5, blur: 0.5, spread: 0, color: k.darkAlpha(0.4)),
                    ])
            )
        }
        if visualState == .rest && !checked {
            control = control.hover(c.hover)
        }
        if disabled {
            control = control.opacity(0.5)
        }
        if visualState == .focus {
            control = control.border(2.0, c.borderFocus)
        }

        let labelColor = disabled ? c.textMuted : c.textBase
        var words: El<State> = col()
            .key("\(key)-text")
            .gap(6)
            .child(text(labelText).key("\(key)-label").font(k.ty.ui.lh(20)).color(labelColor))
        if let descriptionText {
            let descColor = disabled ? c.textFaint : c.textMuted
            words = words.child(text(descriptionText).key("\(key)-description").font(k.ty.small.lh(11)).color(descColor))
        }

        var root: El<State> = row()
            .key(key)
            .role(.radio)
            .label(labelText)
            .selected(checked ? "true" : "false")
            .itemSelected(checked)
            .gap(8)
            .itemsStart()
            .child(el().key("\(key)-stack").size(16, 20).child(control))
            .child(words)
            .focusable(!disabled)
            .inert(disabled)
        if !disabled {
            root = root.focusRing(c.borderFocus, offset: 1.0)
        }
        if let descriptionText {
            root = root.help(descriptionText)
        }
        if !disabled, let onPress {
            root = root.onClick(onPress)
        }
        return root
    }
}

/// Fluent radio group matching `rune_kit::RadioGroup`.
public struct RadioGroup<State> {
    private var labelText: String?
    private var descriptionText: String?
    private var radioItems: [RadioItem<State>] = []
    private var isDisabled: Bool = false
    private var isInvalid: Bool = false

    public init() {}

    public func label(_ l: String) -> Self { var c = self; c.labelText = l; return c }
    public func description(_ d: String) -> Self { var c = self; c.descriptionText = d; return c }
    public func item(_ i: RadioItem<State>) -> Self { var c = self; c.radioItems.append(i); return c }
    public func items(_ list: [RadioItem<State>]) -> Self { var c = self; c.radioItems.append(contentsOf: list); return c }
    public func disabled(_ d: Bool) -> Self { var c = self; c.isDisabled = d; return c }
    public func invalid(_ i: Bool) -> Self { var c = self; c.isInvalid = i; return c }

    public func build(_ k: Kit, key: String = "radio-group") -> El<State> {
        let c = k.c
        var root: El<State> = col()
            .key(key)
            .role(.group)
            .focusGroup(true)
            .gap(8)
            .inert(isDisabled)
        if let labelText {
            root = root
                .label(labelText)
                .child(text(labelText).key("\(key)-label").font(k.ty.small.lh(11)).color(c.textFaint))
        }
        if let descriptionText {
            root = root
                .help(descriptionText)
                .child(text(descriptionText).key("\(key)-description").font(k.ty.small.lh(13.2)).color(c.textFaint))
        }
        var itemsCol: El<State> = col().key("\(key)-items").gap(12)
        for (idx, var item) in radioItems.enumerated() {
            if isDisabled { item = item.disabled(true) }
            item.isInvalid = isInvalid
            itemsCol = itemsCol.child(item.build(k, key: "\(key)-item\(idx)"))
        }
        return root.child(itemsCol)
    }
}

/// Fluent segmented control matching `rune_kit::SegmentedControl`.
public struct SegmentedControl<State> {
    private enum WidthMode: Equatable {
        case points(Float)
        case fill
        case fit
    }

    private var labels: [String]
    private var selectedIndex: Int?
    private var widthMode: WidthMode = .points(232)
    private var states: [ControlVisualState] = []
    private var labelText: String?
    private var onPickHandler: ((inout State, Int, inout Tx) -> Void)?

    public init(labels: [String], selected: Int?) {
        self.labels = labels
        self.selectedIndex = selected
    }

    public func label(_ l: String) -> Self { var c = self; c.labelText = l; return c }
    public func width(_ w: Float?) -> Self {
        var c = self
        c.widthMode = w.map { .points($0) } ?? .fill
        return c
    }
    public func fit() -> Self { var c = self; c.widthMode = .fit; return c }
    public func segmentState(_ index: Int, _ s: ControlVisualState) -> Self {
        var c = self
        if c.states.count <= index {
            c.states.append(contentsOf: repeatElement(.rest, count: index + 1 - c.states.count))
        }
        c.states[index] = s
        return c
    }
    public func onPick(_ f: @escaping (inout State, Int, inout Tx) -> Void) -> Self {
        var c = self
        c.onPickHandler = f
        return c
    }

    public func build(_ k: Kit, key: String = "segmented") -> El<State> {
        let c = k.c
        let n = max(1, labels.count)
        let font = k.ty.ui.lh(13)
        var root: El<State> = row()
            .key(key)
            .role(.group)
            .focusGroup(true)
            .h(28)
            .itemsCenter()
            .rounded(6)
            .bg(c.layer01)
            .shadows([Shadow(x: 0, y: 0, blur: 0, spread: 0.5, color: c.borderBase)])

        if let labelText {
            root = root.label(labelText)
        }
        switch widthMode {
        case .points(let w): root = root.w(w)
        case .fill: root = root.wFull()
        case .fit: root = root.equalColumns(n)
        }

        let indicator: El<State> = el()
            .key("\(key)-indicator")
            .h(28)
            .rounded(6)
            .bg(c.bgBase)
            .shadows([Shadow(x: 0, y: 0, blur: 0, spread: 0.5, color: c.borderStrong)])
            .animateLayout(k.motion.control)

        if let sel = selectedIndex {
            switch widthMode {
            case .points(let w):
                let seg = w / Float(n)
                root = root.child(indicator.w(seg).absolute(x: seg * Float(sel), y: 0))
            case .fit:
                root = root.child(indicator.gridCell(column: sel))
            case .fill:
                break
            }
        }

        for (i, l) in labels.enumerated() {
            let st = i < states.count ? states[i] : .rest
            let on = selectedIndex == i
            let ink = (on || st == .hover) ? c.textBase : c.textMuted
            let hovers = (st == .rest && !on && onPickHandler != nil)
            let labelEl: El<State> = text(l)
                .key("\(key)-label\(i)")
                .font(font)
                .color(ink)
                .ellipsis()
            var seg: El<State> = row()
                .key("\(key)-segment\(i)")
                .role(.tab)
                .focusable(st != .disabled)
                .itemSelected(on)
                .selected(on ? "true" : "false")
                .focusRing(c.borderFocus, offset: 1.0)
                .inert(st == .disabled)
                .label(l)
                .grow(1)
                .shrink(1)
                .h(28)
                .px(12)
                .center()
                .rounded(6)
                .child(labelEl)

            if widthMode == .fit {
                seg = seg.gridCell(column: i)
            }
            if widthMode == .fill && on {
                seg = seg
                    .bg(c.bgBase)
                    .shadows([Shadow(x: 0, y: 0, blur: 0, spread: 0.5, color: c.borderStrong)])
            }
            switch st {
            case .focus: seg = seg.border(2.0, c.borderFocus)
            case .disabled: seg = seg.opacity(0.45)
            case .hover where !on: seg = seg.bg(c.hover)
            default: break
            }
            if hovers {
                seg = seg.hover(c.hover).press(kitPressOver(c.hover, c.pressed))
            }
            if st != .disabled, let pick = onPickHandler {
                seg = seg.onClick { state, tx in pick(&state, i, &tx) }
            }
            root = root.child(seg)
        }
        return root
    }
}

public enum ButtonVariant: Sendable, Hashable {
    case primary
    case accent
    case neutral
    case ghost
    case ghostMuted
    case danger
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
        case .ghost, .ghostMuted:
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

        let fontStyle = (size == .sm || size == .mini || size == .small) ? ty.smallMedium : ty.uiMedium
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
        visualState: ControlVisualState = .rest,
        expanded: Bool? = nil,
        omitHelp: Bool = false,
        onClick: @escaping (inout State, inout Tx) -> Void
    ) -> El<State> {
        let bgCol: Color
        let fgCol: Color
        let hoverCol: Color
        let pressCol: Color
        let borderCol: Color
        let borderW: Float
        let elev: [Shadow]

        let activeOn = !disabled && (visualState == .pressed || expanded == true)

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
            bgCol = (expanded == true && !disabled) ? c.pressed : .transparent
            fgCol = c.iconBase
            hoverCol = c.hover
            pressCol = c.pressed
            borderCol = .transparent
            borderW = 0
            elev = []
        case .ghostMuted:
            bgCol = (expanded == true && !disabled) ? c.pressed : .transparent
            fgCol = activeOn ? c.iconBase : c.iconMuted
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

        let (cornerRadius, glyphSize): (Float, Float) = switch size {
        case .mini: (radius.sm, 12)
        case .small, .sm: (radius.sm, 16)
        case .regular, .large, .md, .lg: (radius.md, 16)
        case .extraLarge: (radius.lg, 18)
        }

        var node: El<State> = row()
            .key(key)
            .role(.button)
            .label(labelText)
        if !omitHelp {
            node = node.help(labelText)
        }
        if let expanded {
            node = node.expanded(expanded)
        }
        node = node
            .square(size.height)
            .center()
            .rounded(cornerRadius)
            .bg(bgCol)
            .border(borderW, borderCol)
            .shadows(shadowLayers(elev))
            .animate(motion.control)
            .child(icon(svg, size: glyphSize).key("icon").color(fgCol).a11yHidden())

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
                .itemSelected(isSel)
                .itemsCenter()
                .gap(8)
                .child(circle)
                .child(text(opt.label).font(ty.ui).color(c.textBase))
                .focusable(true)
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
