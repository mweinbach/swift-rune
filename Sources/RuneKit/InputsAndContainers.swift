import Foundation
import Rune
import RuneMotion

public enum BadgeTone: Sendable, Hashable {
    case neutral
    case accent
    case success
    case warning
    case danger
    case info
}

public struct TreeItem<ID: Hashable & Sendable & CustomStringConvertible>: Sendable {
    public var id: ID
    public var label: String
    public var isFolder: Bool
    public var children: [TreeItem<ID>]

    public init(id: ID, label: String, isFolder: Bool = false, children: [TreeItem<ID>] = []) {
        self.id = id
        self.label = label
        self.isFolder = isFolder || !children.isEmpty
        self.children = children
    }
}

public struct TableColumn<Row>: Sendable {
    public var title: String
    public var width: Float?
    public var grow: Float
    public var align: TextAlign
    public var cell: @Sendable (Row) -> String

    public init(
        title: String,
        width: Float? = nil,
        grow: Float = 1.0,
        align: TextAlign = .leading,
        cell: @escaping @Sendable (Row) -> String
    ) {
        self.title = title
        self.width = width
        self.grow = grow
        self.align = align
        self.cell = cell
    }
}

// MARK: - Badge & Divider (`rune_kit::badge`)

public enum BadgeVariant: Sendable, Hashable {
    case neutral
    case accent
    case subtle
}

/// Compact pill label (`rune_kit::Badge`).
public struct Badge: Sendable {
    public var labelText: String
    public var variantValue: BadgeVariant = .neutral
    public var isStandard: Bool = false
    public var isHighContrast: Bool = false

    public init(_ label: String) {
        self.labelText = label
    }

    public func variant(_ variant: BadgeVariant) -> Badge {
        var copy = self
        copy.variantValue = variant
        return copy
    }

    public func standard(_ on: Bool = true) -> Badge {
        var copy = self
        copy.isStandard = on
        return copy
    }

    public func highContrast(_ on: Bool = true) -> Badge {
        var copy = self
        copy.isHighContrast = on
        return copy
    }

    public func build<State>(_ k: Kit) -> El<State> {
        let c = k.c
        let (h, px, radius, style): (Float, Float, Float, TextStyle) = isStandard
            ? (18, 6, k.radius.xs, k.ty.textSmallMedium)
            : (16, 4, 2, k.ty.smallMedium.lh(11))

        let (fill, fg, borderColor): (Color, Color, Color?) = {
            switch variantValue {
            case .neutral where isStandard:
                return (c.surfaceRaisedBase, c.stdText, c.borderWeak)
            case .neutral:
                return (c.layer02, c.textMuted, isHighContrast ? c.borderStrong : c.borderBase)
            case .accent:
                return (c.bgAccent, c.textContrast, nil)
            case .subtle:
                return (c.layer03, c.textMuted, nil)
            }
        }()

        var badgeEl: El<State> = row()
            .role(.group)
            .label(labelText)
            .liveRegion(.polite)
            .h(h)
            .px(px)
            .center()
            .rounded(radius)
            .bg(fill)
            .child(text(labelText).font(style).color(fg).noWrap().a11yHidden())
        if let borderColor {
            badgeEl = badgeEl.border(0.5, borderColor)
        }
        return badgeEl
    }
}

/// Hairline horizontal or vertical separator (`rune_kit::Divider`).
public struct Divider: Sendable {
    public enum Orientation: Sendable, Hashable {
        case horizontal
        case vertical
    }

    public var orientation: Orientation

    public init(orientation: Orientation = .horizontal) {
        self.orientation = orientation
    }

    public static func horizontal() -> Divider {
        Divider(orientation: .horizontal)
    }

    public static func vertical() -> Divider {
        Divider(orientation: .vertical)
    }

    public func build<State>(_ k: Kit) -> El<State> {
        switch orientation {
        case .horizontal:
            return el().role(.separator).wFull().h(1).bg(k.c.borderBase)
        case .vertical:
            return el().role(.separator).w(1).hFull().bg(k.c.borderBase)
        }
    }
}

// MARK: - Field (`rune_kit::field`)

/// Labelled form field wrapper with optional info icon, prefix, and suffix (`rune_kit::Field`).
public struct Field<State> {
    public static var infoIcon: SVGIcon {
        let d = "M13 13H3V3H13V13ZM6.46777 6.81641V7.81641H7.5791V11.3721H8.5791V6.81641H6.46777ZM7.30078 4.62891V5.62891H8.85645V4.62891H7.30078Z"
        return SVGIcon(
            viewBox: 16,
            paths: [d],
            strokeWidth: nil,
            body: "<path fill-rule=\"evenodd\" d=\"\(d)\" fill=\"currentColor\"/>"
        )
    }

    public var labelText: String?
    public var hasInfo: Bool = false
    public var prefixText: String?
    public var suffixText: String?
    public var controlEl: El<State>?

    public init() {}

    public func label(_ text: String) -> Field<State> {
        var copy = self
        copy.labelText = text
        return copy
    }

    public func info(_ on: Bool = true) -> Field<State> {
        var copy = self
        copy.hasInfo = on
        return copy
    }

    public func prefix(_ text: String) -> Field<State> {
        var copy = self
        copy.prefixText = text
        return copy
    }

    public func suffix(_ text: String) -> Field<State> {
        var copy = self
        copy.suffixText = text
        return copy
    }

    public func control(_ el: El<State>) -> Field<State> {
        var copy = self
        copy.controlEl = el
        return copy
    }

    public func build(_ k: Kit) -> El<State> {
        let c = k.c
        var out: El<State> = col().role(.group).gap(8).wFull().itemsStart()
        if let labelText {
            out = out.label(labelText)
        }
        let asideDesc = [prefixText, suffixText].compactMap { $0 }
        if !asideDesc.isEmpty {
            out = out.description(asideDesc.joined(separator: ". "))
        }
        if let labelText {
            var labelRow: El<State> = row()
                .key("label")
                .wFull()
                .minH(16)
                .gap(4)
                .centerY()
                .child(text(labelText).key("text").font(k.ty.uiMedium.lh(16)).color(c.textBase))
            if hasInfo {
                labelRow = labelRow.child(
                    icon(Field<State>.infoIcon, size: 16)
                        .key("info")
                        .color(c.iconMuted)
                        .a11yHidden()
                )
            }
            out = out.child(labelRow.a11yHidden())
        }
        if let prefixText {
            out = out.child(
                text(prefixText)
                    .key("prefix")
                    .wFull()
                    .minH(11)
                    .font(k.ty.small.lh(11))
                    .color(c.textMuted)
                    .a11yHidden()
            )
        }
        if let controlEl {
            out = out.child(controlEl)
        }
        if let suffixText {
            out = out.child(
                text(suffixText)
                    .key("suffix")
                    .wFull()
                    .minH(11)
                    .font(k.ty.small.lh(11))
                    .color(c.textMuted)
                    .a11yHidden()
            )
        }
        return out
    }
}

// MARK: - Card (`rune_kit::card`)

/// Left-accented card container (`rune_kit::Card`).
public struct Card<State> {
    public var accentColor: Color?
    public var titleText: String?
    public var titleIcon: SVGIcon?
    public var descriptionText: String?
    public var actions: [El<State>] = []
    public var children: [El<State>] = []

    public init() {}

    public func accent(_ color: Color) -> Card<State> {
        var copy = self
        copy.accentColor = color
        return copy
    }

    public func title(_ title: String, icon: SVGIcon? = nil) -> Card<State> {
        var copy = self
        copy.titleText = title
        copy.titleIcon = icon
        return copy
    }

    public func description(_ text: String) -> Card<State> {
        var copy = self
        copy.descriptionText = text
        return copy
    }

    public func action(_ el: El<State>) -> Card<State> {
        var copy = self
        copy.actions.append(el)
        return copy
    }

    public func child(_ el: El<State>) -> Card<State> {
        var copy = self
        copy.children.append(el)
        return copy
    }

    public func build(_ k: Kit) -> El<State> {
        let c = k.c
        let accent = accentColor ?? c.iconBase
        var body: El<State> = col()
            .key("body")
            .grow(1)
            .shrink(1)
            .pt(10)
            .pb(10)
            .pl(8)
            .pr(12)
        if titleText != nil {
            body = body.gap(8)
        }

        if let titleText {
            let leading: El<State> = {
                if let titleIcon {
                    return icon(titleIcon, size: 14).color(accent)
                }
                return icon(k.glyph.dash, size: 14).color(c.textFaint)
            }()
            body = body.child(
                row()
                    .key("title")
                    .gap(8)
                    .centerY()
                    .child(row().size(16, 16).center().child(leading).a11yHidden())
                    .child(text(titleText).font(k.ty.bodyMedium).color(c.textBase))
            )
        }
        if let descriptionText {
            body = body.child(
                text(descriptionText)
                    .key("description")
                    .font(k.ty.body)
                    .color(c.textMuted)
                    .wrapText()
                    .wFull()
            )
        }
        if !children.isEmpty {
            body = body.children(children)
        }
        if !actions.isEmpty {
            let indent: Float = titleText == nil ? 0 : 24
            body = body.child(row().key("actions").pl(indent).gap(8).children(actions))
        }

        let rule: El<State> = el()
            .key("rule")
            .w(2)
            .my(8)
            .rounded(2)
            .bg(accent)
            .a11yHidden()

        var root: El<State> = row()
            .role(.group)
            .wFull()
            .itemsStretch()
            .rounded(k.radius.md)
            .child(rule)
            .child(body)
        if let titleText {
            root = root.label(titleText)
        }
        return root
    }
}

// MARK: - Collapsible & Accordion (`rune_kit::collapsible`, `rune_kit::accordion`)

/// Single disclosure section (`rune_kit::Collapsible`).
public struct Collapsible<State> {
    public var titleText: String
    public var isOpen: Bool
    public var isGhost: Bool = false
    public var children: [El<State>] = []
    public var visualState: ControlVisualState = .rest
    public var isDisabled: Bool = false
    public var onToggleHandler: ((inout State, inout Tx) -> Void)?

    public init(_ title: String, isOpen: Bool = false) {
        self.titleText = title
        self.isOpen = isOpen
    }

    public func ghost(_ on: Bool = true) -> Collapsible<State> {
        var copy = self
        copy.isGhost = on
        return copy
    }

    public func child(_ el: El<State>) -> Collapsible<State> {
        var copy = self
        copy.children.append(el)
        return copy
    }

    public func children(_ els: [El<State>]) -> Collapsible<State> {
        var copy = self
        copy.children.append(contentsOf: els)
        return copy
    }

    public func state(_ s: ControlVisualState) -> Collapsible<State> {
        var copy = self
        copy.visualState = s
        if s == .disabled {
            copy.isDisabled = true
        }
        return copy
    }

    public func disabled(_ d: Bool = true) -> Collapsible<State> {
        var copy = self
        copy.isDisabled = d
        if d {
            copy.visualState = .disabled
        }
        return copy
    }

    public func onToggle(_ f: @escaping (inout State) -> Void) -> Collapsible<State> {
        onToggle { s, _ in f(&s) }
    }

    public func onToggle(_ f: @escaping (inout State, inout Tx) -> Void) -> Collapsible<State> {
        var copy = self
        copy.onToggleHandler = f
        return copy
    }

    public func build(_ k: Kit) -> El<State> {
        let c = k.c
        let enabled = !isDisabled && visualState != .disabled
        let showArrow = isOpen || visualState == .hover
        let arrowIcon: El<State> = icon(isOpen ? k.glyph.triangleDown : k.glyph.triangleRight, size: 14)
            .color(c.iconWeaker)
        let arrow: El<State> = row()
            .key("arrow")
            .size(24, 24)
            .center()
            .opacity(showArrow ? 1.0 : 0.0)
            .child(arrowIcon)

        let labelRow: El<State> = row()
            .gap(8)
            .centerY()
            .child(text(titleText).key("title").font(k.ty.textSmallMedium).color(c.stdText))
            .child(arrow)
            .a11yHidden()

        var trigger: El<State> = row()
            .key("trigger")
            .role(.button)
            .label(titleText)
            .expanded(isOpen)
            .focusable(enabled)
            .focusRing(2.0, offset: 0.0, c.borderFocus)
            .disabled(!enabled)
            .wFull()
            .h(32)
            .centerY()
            .child(labelRow)

        if enabled, let onToggleHandler {
            trigger = trigger.onClick(onToggleHandler)
        }

        var root: El<State> = col()
            .role(.group)
            .wFull()
            .rounded(k.radius.md)
            .child(trigger)
        if isOpen {
            root = root.child(
                col()
                    .key("content")
                    .role(.region)
                    .label(titleText)
                    .wFull()
                    .children(children)
            )
        }
        return root
    }
}

/// Fluent item in an `Accordion` (`rune_kit::AccordionItem`).
public struct AccordionSection<State> {
    public var titleText: String
    public var isExpanded: Bool = false
    public var children: [El<State>] = []
    public var visualState: ControlVisualState = .rest
    public var isDisabled: Bool = false
    public var onToggleHandler: ((inout State, inout Tx) -> Void)?

    public init(_ title: String) {
        self.titleText = title
    }

    public func expanded(_ on: Bool = true) -> AccordionSection<State> {
        var copy = self
        copy.isExpanded = on
        return copy
    }

    public func child(_ el: El<State>) -> AccordionSection<State> {
        var copy = self
        copy.children.append(el)
        return copy
    }

    public func children(_ els: [El<State>]) -> AccordionSection<State> {
        var copy = self
        copy.children.append(contentsOf: els)
        return copy
    }

    public func state(_ s: ControlVisualState) -> AccordionSection<State> {
        var copy = self
        copy.visualState = s
        if s == .disabled {
            copy.isDisabled = true
        }
        return copy
    }

    public func disabled(_ d: Bool = true) -> AccordionSection<State> {
        var copy = self
        copy.isDisabled = d
        if d {
            copy.visualState = .disabled
        }
        return copy
    }

    public func onToggle(_ f: @escaping (inout State) -> Void) -> AccordionSection<State> {
        onToggle { s, _ in f(&s) }
    }

    public func onToggle(_ f: @escaping (inout State, inout Tx) -> Void) -> AccordionSection<State> {
        var copy = self
        copy.onToggleHandler = f
        return copy
    }
}

/// Connected stack of collapsible `AccordionSection`s (`rune_kit::Accordion`).
public struct Accordion<State> {
    public typealias Item = AccordionSection<State>

    public var sections: [AccordionSection<State>] = []
    public var widthValue: Float?

    public init() {}

    public func item(_ section: AccordionSection<State>) -> Accordion<State> {
        var copy = self
        copy.sections.append(section)
        return copy
    }

    public func item(
        _ legacy: AccordionItem<State>,
        expanded: Bool = false,
        disabled: Bool = false,
        onToggle: ((inout State, inout Tx) -> Void)? = nil
    ) -> Accordion<State> {
        var section = AccordionSection<State>(legacy.title)
            .expanded(expanded)
            .disabled(disabled)
            .child(legacy.content())
        if let onToggle {
            section = section.onToggle(onToggle)
        }
        return item(section)
    }

    public func width(_ w: Float?) -> Accordion<State> {
        var copy = self
        copy.widthValue = w
        return copy
    }

    public func build(_ k: Kit) -> El<State> {
        let c = k.c
        var root: El<State> = col().role(.group).itemsStretch()
        if let widthValue {
            root = root.w(widthValue)
        } else {
            root = root.wFull()
        }

        let count = sections.count
        for (i, sec) in sections.enumerated() {
            let enabled = !sec.isDisabled && sec.visualState != .disabled
            let top: Float = (i == 0) ? k.radius.lg : 0.0
            let bottom: Float = (i == count - 1 && !sec.isExpanded) ? k.radius.lg : 0.0

            var trigger: El<State> = row()
                .key("trigger")
                .role(.button)
                .label(sec.titleText)
                .expanded(sec.isExpanded)
                .focusable(enabled)
                .focusRing(2.0, offset: -2.0, c.borderFocus)
                .disabled(!enabled)
                .h(32)
                .px(12)
                .py(8)
                .centerY()
                .justifyBetween()
                .corners(top, top, bottom, bottom)
                .bg(sec.visualState == .hover ? c.hover : c.bgBase)
                .border(1.0, c.borderBase)
                .child(text(sec.titleText).key("title").font(k.ty.textSmall).color(c.textBase).a11yHidden())

            if sec.visualState == .rest {
                trigger = trigger.hover(c.hover)
            }
            if enabled, let onToggle = sec.onToggleHandler {
                trigger = trigger.onClick(onToggle)
            }

            var itemEl: El<State> = col().key("item\(i)").itemsStretch().child(trigger)
            if i > 0 {
                itemEl = itemEl.mt(-1.0)
            }
            if sec.isExpanded {
                let b: Float = (i == count - 1) ? k.radius.lg : 0.0
                let contentEl: El<State> = col()
                    .key("content")
                    .role(.region)
                    .label(sec.titleText)
                    .corners(0, 0, b, b)
                    .bg(c.layer01)
                    .border(1.0, c.borderBase)
                    .mt(-1.0)
                    .pt(1.0)
                    .children(sec.children)
                itemEl = itemEl.child(
                    col()
                        .key("content-clip")
                        .clipSoft(0.0)
                        .child(contentEl)
                )
            }
            root = root.child(itemEl)
        }
        return root
    }
}

// MARK: - TextInput, TextArea & TextField (`rune_kit::text_input`)

private func applyTextFieldShell<State>(
    _ k: Kit,
    _ element: El<State>,
    state: ControlVisualState,
    invalid: Bool,
    focused: Bool
) -> El<State> {
    let c = k.c
    let disabled = state == .disabled
    let hover = state == .hover && !invalid && !focused && !disabled
    var out = element
        .rounded(k.radius.md)
        .bg(hover ? kitOver(c.hover, c.bgBase) : c.bgBase)

    if disabled {
        return out
            .shadows(k.shadowLayers(k.elevation.effectiveInput()))
            .opacity(0.5)
    }
    if invalid {
        return out.border(1.0, c.danger.fg)
    }
    if focused || state == .focus {
        return out.border(1.0, c.borderFocus)
    }
    out = out.shadows(k.shadowLayers(k.elevation.effectiveInput()))
    if state == .rest {
        out = out.hover(c.hover)
    }
    return out.focusWithinRing(c.borderFocus, width: 1.0, offset: -1.0)
}

private func nearestCaretOffset(
    edit: TextEdit,
    local: Vec2,
    elementSize: Vec2,
    leftInset: Float,
    rightInset: Float,
    fontSize: Float,
    multiline: Bool = false,
    lineHeight: Float = 17.5,
    topPadding: Float = 8.0
) -> Int {
    let end = edit.text.utf8.count
    guard end > 0 else { return 0 }
    if multiline {
        let lines = edit.displayString.split(separator: "\n", omittingEmptySubsequences: false)
        let lineCount = max(1, lines.count)
        let textBottom = min(
            max(topPadding + lineHeight, elementSize.y - topPadding),
            topPadding + Float(lineCount) * lineHeight
        )
        if local.y > textBottom || local.x >= elementSize.x - rightInset {
            return end
        }
        if local.x <= leftInset && local.y <= topPadding + lineHeight {
            return 0
        }
        if local.y <= topPadding {
            let firstLineWidth = Float(lines.first?.count ?? 0) * (fontSize * 0.55)
            let lineEndX = min(max(leftInset, elementSize.x - rightInset), leftInset + firstLineWidth)
            return local.x > (leftInset + lineEndX) * 0.5 ? end : 0
        }
        return (local.y - topPadding) >= (textBottom - local.y) ? end : 0
    }
    if local.x <= leftInset {
        return 0
    }
    let estTextWidth = Float(edit.displayString.count) * (fontSize * 0.55)
    let textEndX = min(max(leftInset, elementSize.x - rightInset), leftInset + estTextWidth)
    if local.x >= textEndX {
        return end
    }
    return local.x > (leftInset + textEndX) * 0.5 ? end : 0
}

private func resolvedInputKey<State>(
    explicit: String?,
    editKeyPath: WritableKeyPath<State, TextEdit>
) -> String {
    if let explicit { return explicit }
    return "input-\(UInt(bitPattern: editKeyPath.hashValue))"
}

/// Bordered or plain single-line text field (`rune_kit::TextInput`).
public struct TextInput<State> {
    public var key: String?
    public var editKeyPath: WritableKeyPath<State, TextEdit>
    public var placeholderText: String = ""
    public var labelText: String?
    public var isPlain: Bool = false
    public var trailingEl: El<State>?
    public var hasCopyButton: Bool = false
    public var hasClearButton: Bool = false
    public var isLarge: Bool = false
    public var styleOverride: TextStyle?
    public var heightOverride: Float?
    public var widthOverride: Float? = 280.0
    public var leadingIconSVG: SVGIcon?
    public var leadingIconSizeValue: Float = 16.0
    public var isInvalid: Bool = false
    public var activeDescendantKey: String?
    public var visualState: ControlVisualState = .rest
    public var isFocusedOverride: Bool?
    public var isSecure: Bool = false
    public var isRevealed: Bool = false
    public var isSpellcheck: Bool = false
    public var animatesEditLayout: Bool = false
    public var onChangeHandler: ((inout State, String, inout Tx) -> Void)?
    public var onSubmitHandler: ((inout State, String, inout Tx) -> Void)?
    public var onActionHandler: ((inout State, inout Tx) -> Void)?
    public var onKeyHandler: ((inout State, KeyEvent, inout Tx) -> Bool)?

    public init(key: String? = nil, _ editKeyPath: WritableKeyPath<State, TextEdit>) {
        self.key = key
        self.editKeyPath = editKeyPath
    }

    public func placeholder(_ p: String) -> TextInput<State> {
        var copy = self; copy.placeholderText = p; return copy
    }

    public func label(_ l: String) -> TextInput<State> {
        var copy = self; copy.labelText = l; return copy
    }

    public func plain(_ on: Bool = true) -> TextInput<State> {
        var copy = self; copy.isPlain = on; return copy
    }

    public func trailing(_ el: El<State>) -> TextInput<State> {
        var copy = self; copy.trailingEl = el; return copy
    }

    public func copyButton(_ on: Bool = true) -> TextInput<State> {
        var copy = self; copy.hasCopyButton = on; return copy
    }

    public func clearButton(_ on: Bool = true) -> TextInput<State> {
        var copy = self; copy.hasClearButton = on; return copy
    }

    public func large(_ on: Bool = true) -> TextInput<State> {
        var copy = self; copy.isLarge = on; return copy
    }

    public func textStyle(_ style: TextStyle) -> TextInput<State> {
        var copy = self; copy.styleOverride = style; return copy
    }

    public func height(_ h: Float) -> TextInput<State> {
        var copy = self; copy.heightOverride = h; return copy
    }

    public func width(_ w: Float?) -> TextInput<State> {
        var copy = self; copy.widthOverride = w; return copy
    }

    public func leadingIcon(_ svg: SVGIcon) -> TextInput<State> {
        var copy = self; copy.leadingIconSVG = svg; return copy
    }

    public func leadingIconSize(_ size: Float) -> TextInput<State> {
        var copy = self; copy.leadingIconSizeValue = size; return copy
    }

    public func invalid(_ on: Bool = true) -> TextInput<State> {
        var copy = self; copy.isInvalid = on; return copy
    }

    public func activeDescendant(_ key: String?) -> TextInput<State> {
        var copy = self; copy.activeDescendantKey = key; return copy
    }

    public func state(_ s: ControlVisualState) -> TextInput<State> {
        var copy = self; copy.visualState = s; return copy
    }

    public func disabled(_ d: Bool = true) -> TextInput<State> {
        var copy = self
        if d { copy.visualState = .disabled }
        return copy
    }

    public func focused(_ f: Bool = true) -> TextInput<State> {
        var copy = self; copy.isFocusedOverride = f; return copy
    }

    public func secure(_ on: Bool = true) -> TextInput<State> {
        var copy = self; copy.isSecure = on; return copy
    }

    public func revealed(_ on: Bool = true) -> TextInput<State> {
        var copy = self; copy.isRevealed = on; return copy
    }

    public func spellcheck(_ on: Bool = true) -> TextInput<State> {
        var copy = self; copy.isSpellcheck = on; return copy
    }

    public func animateEditLayout(_ on: Bool = true) -> TextInput<State> {
        var copy = self; copy.animatesEditLayout = on; return copy
    }

    public func onChange(_ f: @escaping (inout State, String, inout Tx) -> Void) -> TextInput<State> {
        var copy = self; copy.onChangeHandler = f; return copy
    }

    public func onSubmit(_ f: @escaping (inout State, String, inout Tx) -> Void) -> TextInput<State> {
        var copy = self; copy.onSubmitHandler = f; return copy
    }

    public func onAction(_ f: @escaping (inout State) -> Void) -> TextInput<State> {
        onAction { s, _ in f(&s) }
    }

    public func onAction(_ f: @escaping (inout State, inout Tx) -> Void) -> TextInput<State> {
        var copy = self; copy.onActionHandler = f; return copy
    }

    public func onKey(_ f: @escaping (inout State, KeyEvent, inout Tx) -> Bool) -> TextInput<State> {
        var copy = self; copy.onKeyHandler = f; return copy
    }

    public func build(_ k: Kit, cx: Cx<State>? = nil) -> El<State> {
        let c = k.c
        let disabled = visualState == .disabled
        let red = isInvalid && !disabled && (k.invalidText || isPlain)
        let ink = red ? c.danger.fg : c.textBase
        let hint = red ? c.danger.fg : c.textFaint
        let style = styleOverride ?? k.ty.uiCompact
        let base: Float = isLarge ? 32.0 : 28.0
        let linePx = style.resolvedLineHeight
        let height = heightOverride.map { max($0, linePx) } ?? max(base, linePx + 12.0)

        let inputKey = resolvedInputKey(explicit: key.map { "\($0)-input" }, editKeyPath: editKeyPath)
        var field: El<State> = Rune.textInput(key: inputKey, editKeyPath)
            .grow(1.0)
            .shrink(1.0)
            .minW(0)
            .font(style)
            .noWrap()
            .color(ink)
            .placeholder(placeholderText, color: hint)
            .caret(ink, selection: k.selection())
            .secure(isSecure)
            .revealed(isRevealed)
            .spellcheck(isSpellcheck)
            .invalid(isInvalid)
            .focusRing(0, offset: 0, .transparent)

        if let labelText {
            field = field.label(labelText)
        } else if !placeholderText.isEmpty {
            field = field.label(placeholderText)
        }
        if let activeDescendantKey {
            field = field.activeDescendant(activeDescendantKey)
        }
        if animatesEditLayout {
            field = field.animateLayout(k.motion.control)
        }
        if disabled {
            field = field.disabled(true)
        } else {
            if let onChangeHandler { field = field.onChange(onChangeHandler) }
            if let onSubmitHandler { field = field.onSubmit(onSubmitHandler) }
            if let onKeyHandler { field = field.onKey(onKeyHandler) }
        }

        var valueRow: El<State> = row()
            .key("value")
            .grow(1.0)
            .shrink(1.0)
            .minW(0)
            .gap(6.0)
            .centerY()
            .clipRounded(0.0)
        if let leadingIconSVG {
            valueRow = valueRow.child(
                el()
                    .key("leading")
                    .pl(8.0)
                    .center()
                    .child(icon(leadingIconSVG, size: leadingIconSizeValue).color(c.iconMuted))
                    .a11yHidden()
            )
        } else {
            valueRow = valueRow.child(el().w(2.0))
        }
        valueRow = valueRow.child(field)

        var e: El<State> = row()
            .role(.textInput)
            .h(height)
            .pr(8.0)
            .gap(8.0)
            .centerY()
            .child(valueRow)

        if let key {
            e = e.key(key)
        }
        if let widthOverride {
            e = e.w(widthOverride)
        } else {
            e = e.wFull()
        }

        if let trailingEl {
            e = e.child(row().key("trailing").alignSelf(.center).centerY().child(trailingEl))
        }

        if (hasCopyButton && !isSecure) || hasClearButton {
            let (glyph, side, rad): (SVGIcon, Float, Float) = hasClearButton
                ? (k.glyph.clear, 28.0, k.radius.md)
                : (k.glyph.copy, 20.0, k.radius.sm)
            let actionLabel = hasClearButton ? "Clear" : "Copy"
            var btn: El<State> = row()
                .key(key.map { "\($0)-action" } ?? "action")
                .role(.button)
                .label(actionLabel)
                .size(side, side)
                .alignSelf(.center)
                .center()
                .rounded(rad)
                .child(icon(glyph, size: 16.0).color(c.iconMuted))
            if hasClearButton {
                btn = btn.mr(-8.0)
            }
            if disabled {
                btn = btn.disabled(true)
            } else {
                btn = btn
                    .hit(true)
                    .hover(c.hover)
                    .press(kitPressOver(c.hover, c.pressed))
                    .onClick { [onActionHandler] s, tx in
                        onActionHandler?(&s, &tx)
                    }
                    .focusable(false)
            }
            e = e.child(btn)
        }

        if !disabled {
            let kp = editKeyPath
            let leftInset: Float = leadingIconSVG != nil ? (8.0 + leadingIconSizeValue + 6.0) : 8.0
            let fontSize = style.size
            e = e.onPointerDown { s, press, tx in
                var edit = s[keyPath: kp]
                let offset = nearestCaretOffset(
                    edit: edit,
                    local: press.local,
                    elementSize: press.elementSize,
                    leftInset: leftInset,
                    rightInset: 8.0,
                    fontSize: fontSize
                )
                edit.setCursor(utf8Offset: offset, extendSelection: false)
                s[keyPath: kp] = edit
                tx.focus(inputKey)
            }
        }

        if isPlain {
            return disabled ? e.opacity(0.5) : e
        }
        let focused = (isFocusedOverride ?? cx?.isFocused(inputKey) ?? false) && !disabled
        return applyTextFieldShell(k, e, state: visualState, invalid: isInvalid && !disabled, focused: focused)
    }
}

/// Multi-line text area (`rune_kit::TextArea`): 80pt minimum, 17.5pt line height, 8pt padding, optional `autoGrow` / `maxHeight`.
public struct TextArea<State> {
    public var key: String?
    public var editKeyPath: WritableKeyPath<State, TextEdit>
    public var placeholderText: String = ""
    public var labelText: String?
    public var widthOverride: Float? = 280.0
    public var rowCount: Int = 3
    public var growBounds: (min: Int, max: Int)?
    public var maxHeightValue: Float?
    public var isInvalid: Bool = false
    public var visualState: ControlVisualState = .rest
    public var isFocusedOverride: Bool?
    public var isSecure: Bool = false
    public var isRevealed: Bool = false
    public var isSpellcheck: Bool = false
    public var wrapsAnywhere: Bool = false
    public var animatesEditLayout: Bool = false
    public var onChangeHandler: ((inout State, String, inout Tx) -> Void)?
    public var onSubmitHandler: ((inout State, String, inout Tx) -> Void)?
    public var onKeyHandler: ((inout State, KeyEvent, inout Tx) -> Bool)?

    public init(key: String? = nil, _ editKeyPath: WritableKeyPath<State, TextEdit>) {
        self.key = key
        self.editKeyPath = editKeyPath
    }

    public func placeholder(_ p: String) -> TextArea<State> {
        var copy = self; copy.placeholderText = p; return copy
    }

    public func label(_ l: String) -> TextArea<State> {
        var copy = self; copy.labelText = l; return copy
    }

    public func width(_ w: Float?) -> TextArea<State> {
        var copy = self; copy.widthOverride = w; return copy
    }

    public func rows(_ r: Int) -> TextArea<State> {
        var copy = self; copy.rowCount = max(1, r); return copy
    }

    public func autoGrow(_ minRows: Int, _ maxRows: Int) -> TextArea<State> {
        let minR = max(1, minRows)
        var copy = self
        copy.growBounds = (minR, max(minR, maxRows))
        return copy
    }

    public func maxHeight(_ h: Float) -> TextArea<State> {
        var copy = self; copy.maxHeightValue = h; return copy
    }

    public func animateEditLayout(_ on: Bool = true) -> TextArea<State> {
        var copy = self; copy.animatesEditLayout = on; return copy
    }

    public func wrapAnywhere(_ on: Bool = true) -> TextArea<State> {
        var copy = self; copy.wrapsAnywhere = on; return copy
    }

    public func invalid(_ on: Bool = true) -> TextArea<State> {
        var copy = self; copy.isInvalid = on; return copy
    }

    public func state(_ s: ControlVisualState) -> TextArea<State> {
        var copy = self; copy.visualState = s; return copy
    }

    public func disabled(_ d: Bool = true) -> TextArea<State> {
        var copy = self
        if d { copy.visualState = .disabled }
        return copy
    }

    public func focused(_ f: Bool = true) -> TextArea<State> {
        var copy = self; copy.isFocusedOverride = f; return copy
    }

    public func secure(_ on: Bool = true) -> TextArea<State> {
        var copy = self; copy.isSecure = on; return copy
    }

    public func revealed(_ on: Bool = true) -> TextArea<State> {
        var copy = self; copy.isRevealed = on; return copy
    }

    public func spellcheck(_ on: Bool = true) -> TextArea<State> {
        var copy = self; copy.isSpellcheck = on; return copy
    }

    public func onChange(_ f: @escaping (inout State, String, inout Tx) -> Void) -> TextArea<State> {
        var copy = self; copy.onChangeHandler = f; return copy
    }

    public func onSubmit(_ f: @escaping (inout State, String, inout Tx) -> Void) -> TextArea<State> {
        var copy = self; copy.onSubmitHandler = f; return copy
    }

    public func onKey(_ f: @escaping (inout State, KeyEvent, inout Tx) -> Bool) -> TextArea<State> {
        var copy = self; copy.onKeyHandler = f; return copy
    }

    public func build(_ k: Kit, cx: Cx<State>? = nil) -> El<State> {
        let c = k.c
        let disabled = visualState == .disabled
        var style = k.ty.ui
        style.lineHeight = ((13.0 * 1.35 * 2.0).rounded()) / 2.0 // 17.5pt
        let line = style.resolvedLineHeight
        let red = isInvalid && !disabled && k.invalidText
        let ink = red ? c.danger.fg : c.textBase
        let hint = red ? c.danger.fg : c.textFaint

        let inputKey = resolvedInputKey(explicit: key.map { "\($0)-input" }, editKeyPath: editKeyPath)
        var field: El<State> = Rune.textInput(key: inputKey, editKeyPath)
            .wFull()
            .font(style)
            .wrapText()
            .color(ink)
            .placeholder(placeholderText, color: hint)
            .caret(ink, selection: k.selection())
            .secure(isSecure)
            .revealed(isRevealed)
            .spellcheck(isSpellcheck)
            .invalid(isInvalid)
            .focusRing(0, offset: 0, .transparent)

        if let labelText {
            field = field.label(labelText)
        } else if !placeholderText.isEmpty {
            field = field.label(placeholderText)
        }
        if animatesEditLayout {
            field = field.animateLayout(k.motion.control)
        }
        if disabled {
            field = field.disabled(true)
        } else {
            if let onChangeHandler { field = field.onChange(onChangeHandler) }
            if let onSubmitHandler { field = field.onSubmit(onSubmitHandler) }
            if let onKeyHandler { field = field.onKey(onKeyHandler) }
        }

        var e: El<State> = col().role(.textInput).p(8.0)
        if let key {
            e = e.key(key)
        }
        if let (minRows, maxRows) = growBounds {
            let maxBound: Float = maxHeightValue.map { max(line, min($0, Float(maxRows) * line)) } ?? (Float(maxRows) * line)
            let viewport: El<State> = col()
                .key(key.map { "\($0)-scroll" } ?? "scroll")
                .wFull()
                .shrink(1.0)
                .minH(Float(minRows) * line)
                .maxH(maxBound)
                .scrollY()
                .animateLayout(k.motion.control)
                .child(field.animateLayout(k.motion.control))
            e = e.animateLayout(k.motion.control).child(viewport)
        } else if let h = maxHeightValue {
            let maxInner = max(line, h - 16.0)
            let minInner = min(maxInner, max(Float(rowCount) * line, 80.0 - 16.0))
            let viewport: El<State> = col()
                .key(key.map { "\($0)-scroll" } ?? "scroll")
                .wFull()
                .shrink(1.0)
                .minH(minInner)
                .maxH(maxInner)
                .scrollY()
                .child(field.animateLayout(k.motion.control))
            e = e.minH(minInner + 16.0).child(viewport)
        } else {
            e = e.minH(max(80.0, Float(rowCount) * line + 16.0)).child(field)
        }

        if let widthOverride {
            e = e.w(widthOverride)
        } else {
            e = e.wFull()
        }

        if !disabled {
            let kp = editKeyPath
            let fontSize = style.size
            e = e.onPointerDown { s, press, tx in
                var edit = s[keyPath: kp]
                let offset = nearestCaretOffset(
                    edit: edit,
                    local: press.local,
                    elementSize: press.elementSize,
                    leftInset: 8.0,
                    rightInset: 8.0,
                    fontSize: fontSize,
                    multiline: true,
                    lineHeight: line,
                    topPadding: 8.0
                )
                edit.setCursor(utf8Offset: offset, extendSelection: false)
                s[keyPath: kp] = edit
                tx.focus(inputKey)
            }
        }

        let focused = (isFocusedOverride ?? cx?.isFocused(inputKey) ?? false) && !disabled
        return applyTextFieldShell(k, e, state: visualState, invalid: isInvalid && !disabled, focused: focused)
    }
}

/// Labelled text field (`rune_kit::TextField`): label above a bordered 32pt input with optional copy/error.
public struct TextField<State> {
    public var key: String?
    public var labelText: String
    public var editKeyPath: WritableKeyPath<State, TextEdit>
    public var placeholderText: String = ""
    public var hidesLabel: Bool = false
    public var isGhost: Bool = false
    public var isMultiline: Bool = false
    public var isCopyable: Bool = false
    public var trailingEl: El<State>?
    public var errorText: String?
    public var visualState: ControlVisualState = .rest
    public var onChangeHandler: ((inout State, String, inout Tx) -> Void)?
    public var onSubmitHandler: ((inout State, String, inout Tx) -> Void)?
    public var onActionHandler: ((inout State, inout Tx) -> Void)?

    public init(key: String? = nil, _ label: String, _ editKeyPath: WritableKeyPath<State, TextEdit>) {
        self.key = key
        self.labelText = label
        self.editKeyPath = editKeyPath
    }

    public func placeholder(_ p: String) -> TextField<State> {
        var copy = self; copy.placeholderText = p; return copy
    }

    public func hideLabel(_ on: Bool = true) -> TextField<State> {
        var copy = self; copy.hidesLabel = on; return copy
    }

    public func ghost(_ on: Bool = true) -> TextField<State> {
        var copy = self; copy.isGhost = on; return copy
    }

    public func multiline(_ on: Bool = true) -> TextField<State> {
        var copy = self; copy.isMultiline = on; return copy
    }

    public func copyable(_ on: Bool = true) -> TextField<State> {
        var copy = self; copy.isCopyable = on; return copy
    }

    public func trailing(_ el: El<State>) -> TextField<State> {
        var copy = self; copy.trailingEl = el; return copy
    }

    public func error(_ msg: String) -> TextField<State> {
        var copy = self; copy.errorText = msg; return copy
    }

    public func disabled(_ d: Bool = true) -> TextField<State> {
        var copy = self
        if d { copy.visualState = .disabled }
        return copy
    }

    public func onChange(_ f: @escaping (inout State, String, inout Tx) -> Void) -> TextField<State> {
        var copy = self; copy.onChangeHandler = f; return copy
    }

    public func onSubmit(_ f: @escaping (inout State, String, inout Tx) -> Void) -> TextField<State> {
        var copy = self; copy.onSubmitHandler = f; return copy
    }

    public func onAction(_ f: @escaping (inout State) -> Void) -> TextField<State> {
        onAction { s, _ in f(&s) }
    }

    public func onAction(_ f: @escaping (inout State, inout Tx) -> Void) -> TextField<State> {
        var copy = self; copy.onActionHandler = f; return copy
    }

    public func build(_ k: Kit) -> El<State> {
        let c = k.c
        let disabled = visualState == .disabled
        let body = TextStyle(size: 14.0, weight: 400.0).lh(21.0)
        let inputKey = resolvedInputKey(explicit: key.map { "\($0)-input" }, editKeyPath: editKeyPath)

        var field: El<State> = Rune.textInput(key: inputKey, editKeyPath)
            .grow(1.0)
            .shrink(1.0)
            .font(body)
            .color(c.textStrong)
            .placeholder(placeholderText, color: c.textWeak)
            .caret(c.textStrong, selection: k.selection())
            .label(labelText)
            .invalid(errorText != nil)
            .focusRing(0, offset: 0, .transparent)

        if !isMultiline {
            field = field.noWrap()
        } else {
            field = field.wrapText()
        }
        if let errorText {
            field = field.description(errorText)
        }
        if disabled {
            field = field.disabled(true)
        } else {
            if let onChangeHandler { field = field.onChange(onChangeHandler) }
            if let onSubmitHandler { field = field.onSubmit(onSubmitHandler) }
        }

        var wrapper: El<State> = row()
            .key(key.map { "\($0)-wrapper" } ?? "wrapper")
            .wFull()
            .minH(32.0)
            .px(12.0)
            .py(isMultiline ? 6.0 : 0.0)
            .centerY()
            .child(field)

        if !isGhost {
            let (fill, border): (Color, Color) = errorText != nil
                ? (c.danger.bg, c.danger.border)
                : (.transparent, c.borderWeak)
            wrapper = wrapper.rounded(k.radius.md).bg(fill).border(1.0, border)
        }
        if let trailingEl {
            wrapper = wrapper.child(row().key("trailing").alignSelf(.center).centerY().child(trailingEl))
        }
        if isCopyable {
            var copyBtn: El<State> = row()
                .key(key.map { "\($0)-copy" } ?? "copy")
                .role(.button)
                .label("Copy")
                .size(24.0, 24.0)
                .center()
                .rounded(k.radius.md)
                .hover(c.hover)
                .child(icon(k.glyph.copy, size: 16.0).color(c.stdIcon))
            if disabled {
                copyBtn = copyBtn.disabled(true)
            } else {
                copyBtn = copyBtn
                    .hit(true)
                    .hover(c.hover)
                    .press(kitPressOver(c.hover, c.pressed))
                    .onClick { [onActionHandler] s, tx in
                        onActionHandler?(&s, &tx)
                    }
                    .focusable(false)
            }
            wrapper = wrapper.pr(4.0).child(copyBtn)
        }

        if !disabled {
            let kp = editKeyPath
            let isMulti = isMultiline
            wrapper = wrapper.onPointerDown { s, press, tx in
                var edit = s[keyPath: kp]
                let offset = nearestCaretOffset(
                    edit: edit,
                    local: press.local,
                    elementSize: press.elementSize,
                    leftInset: 12.0,
                    rightInset: 12.0,
                    fontSize: 14.0,
                    multiline: isMulti,
                    lineHeight: 21.0,
                    topPadding: isMulti ? 6.0 : 0.0
                )
                edit.setCursor(utf8Offset: offset, extendSelection: false)
                s[keyPath: kp] = edit
                tx.focus(inputKey)
            }
        }

        var root: El<State> = col().role(.textInput).gap(8.0).wFull()
        if let key { root = root.key(key) }
        if !hidesLabel {
            root = root.child(
                text(labelText)
                    .key("label")
                    .font(k.ty.textXsmallMedium)
                    .color(c.textWeak)
                    .a11yHidden()
            )
        }
        root = root.child(wrapper)
        if let errorText {
            root = root.child(
                text(errorText)
                    .key("error")
                    .font(k.ty.textXsmallMedium)
                    .color(c.danger.fg)
                    .liveRegion(.assertive)
            )
        }
        return disabled ? root.opacity(0.5) : root
    }
}

extension Kit {
    // MARK: - Text Inputs & Fields

    public func textInputField<State>(
        key: String,
        _ editKeyPath: WritableKeyPath<State, TextEdit>,
        placeholder placeholderText: String = "",
        leadingIcon: SVGIcon? = nil,
        invalid: Bool = false,
        onChange: ((inout State, String, inout Tx) -> Void)? = nil,
        onSubmit: ((inout State, String, inout Tx) -> Void)? = nil
    ) -> El<State> {
        let borderCol = invalid ? c.danger.border : c.borderBase
        let ringCol = invalid ? c.danger.fg : c.borderFocus

        var inputEl = Rune.textInput(key: key, editKeyPath)
            .grow(1)
            .py(6)
            .px(leadingIcon == nil ? 10 : 4)
            .font(ty.ui)
            .color(c.textBase)
            .placeholder(placeholderText, color: c.textFaint)
            .caret(c.bgAccent, selection: c.bgAccent.alpha(0.28))
            .focusRing(ringCol, offset: 1.0)

        if let onChange { inputEl = inputEl.onChange(onChange) }
        if let onSubmit { inputEl = inputEl.onSubmit(onSubmit) }

        var wrapper: El<State> = row()
            .key("\(key)-wrap")
            .wFull()
            .minH(34)
            .itemsCenter()
            .rounded(radius.md)
            .bg(c.surfaceWeak)
            .border(1.0, borderCol)

        if let svg = leadingIcon {
            wrapper = wrapper.child(
                row().pl(10).pr(4).center().child(icon(svg, size: 14).color(c.iconMuted))
            )
        }
        return wrapper.child(inputEl)
    }

    public func textArea<State>(
        key: String,
        _ editKeyPath: WritableKeyPath<State, TextEdit>,
        placeholder placeholderText: String = "",
        minHeight: Float = 84,
        invalid: Bool = false,
        onChange: ((inout State, String, inout Tx) -> Void)? = nil
    ) -> El<State> {
        let borderCol = invalid ? c.danger.border : c.borderBase
        var inputEl = Rune.textInput(key: key, editKeyPath)
            .wFull()
            .minH(minHeight)
            .p(10)
            .rounded(radius.md)
            .bg(c.surfaceWeak)
            .border(1.0, borderCol)
            .font(ty.body)
            .color(c.textBase)
            .placeholder(placeholderText, color: c.textFaint)
            .caret(c.bgAccent, selection: c.bgAccent.alpha(0.28))
            .focusRing(invalid ? c.danger.fg : c.borderFocus, offset: 1.0)

        if let onChange { inputEl = inputEl.onChange(onChange) }
        return inputEl
    }

    public func field<State>(
        label labelText: String,
        description: String? = nil,
        error: String? = nil,
        control: El<State>
    ) -> El<State> {
        var out: El<State> = col().wFull().gap(6)
        out = out.child(text(labelText).font(ty.uiMedium).color(c.textBase))
        out = out.child(control)
        if let error, !error.isEmpty {
            out = out.child(text(error).font(ty.small).color(c.danger.fg))
        } else if let description, !description.isEmpty {
            out = out.child(text(description).font(ty.small).color(c.textMuted))
        }
        return out
    }

    // MARK: - Badges, Dividers, Cards & Progress

    public func badge<State>(_ labelText: String, tone: BadgeTone = .neutral) -> El<State> {
        let (bgCol, fgCol, borderCol): (Color, Color, Color) = {
            switch tone {
            case .neutral: return (c.layer02, c.textMuted, c.borderMuted)
            case .accent: return (c.bgAccent.alpha(0.16), c.textAccent, c.bgAccent.alpha(0.35))
            case .success: return (c.success.bg, c.success.fg, c.success.border)
            case .warning: return (c.warning.bg, c.warning.fg, c.warning.border)
            case .danger: return (c.danger.bg, c.danger.fg, c.danger.border)
            case .info: return (c.info.bg, c.info.fg, c.info.border)
            }
        }()
        return row()
            .h(20)
            .px(8)
            .center()
            .pill()
            .bg(bgCol)
            .border(1.0, borderCol)
            .child(text(labelText).font(ty.smallMedium).color(fgCol).noWrap())
    }

    public func badge<State>(
        _ labelText: String,
        variant: BadgeVariant,
        standard: Bool = false,
        highContrast: Bool = false
    ) -> El<State> {
        Badge(labelText).variant(variant).standard(standard).highContrast(highContrast).build(self)
    }

    public func divider<State>() -> El<State> {
        rule(1.0, c.borderMuted)
    }

    public func dividerVertical<State>() -> El<State> {
        Divider.vertical().build(self)
    }

    public func card<State>(
        key: String? = nil,
        padding: Float = 16,
        _ content: El<State>
    ) -> El<State> {
        var box: El<State> = col()
            .p(padding)
            .rounded(radius.xl)
            .bg(c.surfaceRaised)
            .shadows(shadowLayers(elevation.raised))
            .child(content)
        if let key { box = box.key(key) }
        return box
    }

    public func progress<State>(
        key: String,
        fraction: Float,
        height: Float = 6
    ) -> El<State> {
        let clamped = fraction.clamped(to: 0...1)
        return row()
            .key(key)
            .role(.progress)
            .selected(String(format: "%.0f%%", clamped * 100))
            .wFull()
            .h(height)
            .pill()
            .bg(c.layer02)
            .clip(true)
            .child(
                el()
                    .key("\(key)-bar")
                    .wFrac(clamped)
                    .hFull()
                    .pill()
                    .bg(c.bgAccent)
                    .animateLayout(motion.disclosure)
            )
    }

    public func progressCircle<State>(
        key: String,
        fraction: Float,
        diameter: Float = 24,
        strokeWidth: Float = 2.5
    ) -> El<State> {
        let clamped = fraction.clamped(to: 0...1)
        let r = (diameter - strokeWidth) * 0.5
        let cPt = diameter * 0.5
        var circlePath = VectorPath()
        circlePath.arc(center: Vec2(cPt, cPt), radius: r, startAngle: -.pi * 0.5, endAngle: 1.5 * .pi)
        return el()
            .key(key)
            .role(.progress)
            .square(diameter)
            .shape(.stroke(circlePath, color: c.layer03, width: strokeWidth))
            .shape(.stroke(circlePath, color: c.bgAccent, width: strokeWidth).drawn(clamped))
    }

    // MARK: - Collapsible & Accordion

    public func collapsible<State>(
        key: String,
        title: String,
        isOpen: Bool,
        onToggle: @escaping (inout State, Bool) -> Void,
        content: () -> El<State>
    ) -> El<State> {
        let header: El<State> = row()
            .key("\(key)-header")
            .role(.button)
            .expanded(isOpen)
            .wFull()
            .py(8)
            .px(10)
            .itemsCenter()
            .justifyBetween()
            .rounded(radius.md)
            .hover(c.hover)
            .focusRing(c.borderFocus)
            .onClick { s, _ in onToggle(&s, !isOpen) }
            .child(text(title).font(ty.uiMedium).color(c.textBase))
            .child(
                icon(KitIcons.chevronRight, size: 14)
                    .key("\(key)-chevron")
                    .color(c.iconMuted)
                    .rotate(isOpen ? (.pi * 0.5) : 0)
                    .animate(motion.control)
            )

        var wrap: El<State> = col()
            .key(key)
            .wFull()
            .animateLayout(LayoutAnim.widthLeads(motion.disclosure))
            .child(header)

        if isOpen {
            wrap = wrap.child(
                col()
                    .key("\(key)-body")
                    .wFull()
                    .px(10)
                    .pb(8)
                    .transition(Transition.reveal(edge: .top).spring(motion.disclosure))
                    .child(content())
            )
        }
        return wrap
    }

    // MARK: - Select, Popover, Menu, Dialog & Toast

    public func select<State, ID: Hashable & CustomStringConvertible>(
        key: String,
        options: [(id: ID, label: String)],
        selected: ID,
        isOpen: Bool,
        onToggleOpen: @escaping (inout State, Bool) -> Void,
        onSelect: @escaping (inout State, ID) -> Void
    ) -> El<State> {
        let currentLabel = options.first(where: { $0.id == selected })?.label ?? ""

        let trigger: El<State> = row()
            .key("\(key)-trigger")
            .role(.button)
            .expanded(isOpen)
            .wFull()
            .h(32)
            .px(10)
            .itemsCenter()
            .justifyBetween()
            .rounded(radius.md)
            .bg(c.bgButtonNeutral)
            .border(1.0, isOpen ? c.borderFocus : c.borderBase)
            .hover(c.hover)
            .focusRing(c.borderFocus)
            .onClick { s, _ in onToggleOpen(&s, !isOpen) }
            .child(text(currentLabel).font(ty.ui).color(c.textBase).ellipsis())
            .child(icon(KitIcons.chevronDown, size: 14).color(c.iconMuted))

        var root: El<State> = col().key(key).wFull().child(trigger)

        if isOpen {
            var menuList: El<State> = col()
                .key("\(key)-menu")
                .role(.menu)
                .pin(top: 36, right: 0, left: 0)
                .p(4)
                .gap(2)
                .rounded(radius.lg)
                .bg(c.surfaceRaised)
                .shadows(shadowLayers(elevation.floating))
                .z(50)
                .focusGroup(true)
                .transition(Transition.scale(0.96).kitRules().spring(motion.overlay))

            for opt in options {
                let isSel = (opt.id == selected)
                let item: El<State> = row()
                    .key("\(key)-opt-\(opt.id)")
                    .role(.menuItem)
                    .itemSelected(isSel)
                    .wFull()
                    .h(28)
                    .px(8)
                    .itemsCenter()
                    .justifyBetween()
                    .rounded(radius.sm)
                    .bg(isSel ? c.hover : .transparent)
                    .hover(c.hover)
                    .focusRing(c.borderFocus)
                    .onClick { s, _ in
                        onSelect(&s, opt.id)
                        onToggleOpen(&s, false)
                    }
                    .child(text(opt.label).font(isSel ? ty.uiMedium : ty.ui).color(c.textBase))
                    .child(isSel ? icon(KitIcons.check, size: 13).color(c.textAccent) : nil)

                menuList = menuList.child(item)
            }
            root = root.child(menuList)
        }
        return root
    }

    /// Modal dialog overlay trapping keyboard focus & pointer events (`Kit::dialog`).
    public func dialog<State>(
        key: String,
        title: String,
        description: String? = nil,
        maxWidth: Float = 420,
        onDismiss: @escaping (inout State) -> Void,
        body: El<State>,
        footer: El<State>? = nil
    ) -> El<State> {
        var sheet: El<State> = col()
            .key("\(key)-sheet")
            .role(.dialog)
            .label(title)
            .modal(true)
            .focusable(true)
            .autofocus(true)
            .wFull()
            .maxW(maxWidth)
            .p(20)
            .gap(14)
            .rounded(radius.xl)
            .bg(c.surfaceRaised)
            .shadows(shadowLayers(elevation.overlay))
            .transition(Transition.scale(0.95).kitRules().spring(motion.overlay))
            .onKey { s, ev, _ in
                if ev.key == .escape {
                    onDismiss(&s)
                    return true
                }
                return false
            }

        let header: El<State> = row()
            .wFull()
            .itemsCenter()
            .justifyBetween()
            .child(text(title).font(ty.bodyMedium).size(16).semibold().color(c.textBase))
            .child(
                iconButton(key: "\(key)-close", svg: KitIcons.close, label: "Close", size: .sm) { s, _ in
                    onDismiss(&s)
                }
            )
        sheet = sheet.child(header)

        if let description {
            sheet = sheet.child(text(description).font(ty.ui).color(c.textMuted))
        }
        sheet = sheet.child(body)
        if let footer {
            sheet = sheet.child(footer)
        }

        return row()
            .key(key)
            .pin(top: 0, right: 0, bottom: 0, left: 0)
            .p(24)
            .center()
            .bg(c.scrim)
            .z(100)
            .transition(Transition.opacity.spring(motion.overlay))
            .child(sheet)
    }

    public func toast<State>(
        key: String,
        message: String,
        tone: BadgeTone = .neutral,
        onDismiss: ((inout State) -> Void)? = nil
    ) -> El<State> {
        let (bgCol, fgCol, borderCol, leadingSvg): (Color, Color, Color, SVGIcon?) = {
            switch tone {
            case .neutral: return (c.surfaceRaised, c.textBase, c.borderBase, nil)
            case .accent: return (c.surfaceRaised, c.textBase, c.bgAccent.alpha(0.45), KitIcons.info)
            case .success: return (c.success.bg, c.success.fg, c.success.border, KitIcons.check)
            case .warning: return (c.warning.bg, c.warning.fg, c.warning.border, KitIcons.info)
            case .danger: return (c.danger.bg, c.danger.fg, c.danger.border, KitIcons.circleX)
            case .info: return (c.info.bg, c.info.fg, c.info.border, KitIcons.info)
            }
        }()

        var bar: El<State> = row()
            .key(key)
            .px(14)
            .py(10)
            .gap(10)
            .itemsCenter()
            .rounded(radius.lg)
            .bg(bgCol)
            .border(1.0, borderCol)
            .shadows(shadowLayers(elevation.floating))
            .transition(Transition.push(from: .bottom).spring(motion.overlay))

        if let leadingSvg {
            let iconColor = (tone == .accent) ? c.textAccent : fgCol
            bar = bar.child(icon(leadingSvg, size: 15).color(iconColor))
        }
        bar = bar.child(text(message).font(ty.uiMedium).color(fgCol))

        if let onDismiss {
            bar = bar.child(
                iconButton(key: "\(key)-dismiss", svg: KitIcons.close, label: "Dismiss", size: .sm) { s, _ in
                    onDismiss(&s)
                }
            )
        }
        return bar
    }

    // MARK: - App Shell (`sidebar`, `toolbar`, `splitView`), `tree` & `table`

    public func splitView<State>(
        sidebarWidth: Float = 220,
        sidebar: El<State>,
        detail: El<State>
    ) -> El<State> {
        row()
            .sizeFull()
            .bg(c.page)
            .child(
                col()
                    .w(sidebarWidth)
                    .hFull()
                    .shrink(0)
                    .bg(c.layer01)
                    .borderSides(right: 1.0, color: c.borderMuted)
                    .child(sidebar)
            )
            .child(
                col()
                    .grow(1)
                    .minW(0)
                    .hFull()
                    .bg(c.page)
                    .child(detail)
            )
    }

    public func toolbar<State>(title: String, trailing: El<State>? = nil) -> El<State> {
        row()
            .wFull()
            .h(46)
            .px(16)
            .itemsCenter()
            .justifyBetween()
            .bg(c.page)
            .borderSides(bottom: 1.0, color: c.borderMuted)
            .child(text(title).font(ty.uiMedium).semibold().color(c.textBase))
            .child(trailing)
    }

    public func tree<State, ID: Hashable & Sendable & CustomStringConvertible>(
        key: String,
        roots: [TreeItem<ID>],
        expanded: Set<ID>,
        selected: ID?,
        onToggleExpand: @escaping (inout State, ID) -> Void,
        onSelect: @escaping (inout State, ID) -> Void
    ) -> El<State> {
        var list: El<State> = col().key(key).wFull().gap(2).focusGroup(true)

        func emit(_ item: TreeItem<ID>, depth: Int) {
            let isExp = expanded.contains(item.id)
            let isSel = (selected == item.id)
            let indent = Float(depth) * 14.0 + 8.0

            var rowEl: El<State> = row()
                .key("\(key)-\(item.id)")
                .role(.listItem)
                .itemSelected(isSel)
                .expanded(item.isFolder ? isExp : nil)
                .wFull()
                .h(28)
                .pl(indent)
                .pr(8)
                .gap(6)
                .itemsCenter()
                .rounded(radius.sm)
                .bg(isSel ? c.bgAccent.alpha(0.16) : .transparent)
                .hover(c.hover)
                .focusRing(c.borderFocus)
                .onClick { s, _ in
                    onSelect(&s, item.id)
                    if item.isFolder {
                        onToggleExpand(&s, item.id)
                    }
                }

            if item.isFolder {
                rowEl = rowEl
                    .child(
                        icon(KitIcons.chevronRight, size: 12)
                            .color(c.iconMuted)
                            .rotate(isExp ? .pi * 0.5 : 0)
                            .animate(motion.control)
                    )
                    .child(icon(KitIcons.folder, size: 14).color(isSel ? c.textAccent : c.iconMuted))
            } else {
                rowEl = rowEl
                    .child(el().w(12).h(12))
                    .child(icon(KitIcons.file, size: 14).color(isSel ? c.textAccent : c.iconFaint))
            }

            rowEl = rowEl.child(
                text(item.label)
                    .font(isSel ? ty.uiMedium : ty.ui)
                    .color(isSel ? c.textAccent : c.textBase)
                    .ellipsis()
            )
            list = list.child(rowEl)

            if item.isFolder && isExp {
                for child in item.children {
                    emit(child, depth: depth + 1)
                }
            }
        }

        for root in roots {
            emit(root, depth: 0)
        }
        return list
    }

    public func table<State, Row>(
        key: String,
        columns: [TableColumn<Row>],
        rows: [Row]
    ) -> El<State> {
        var headerRow: El<State> = row()
            .wFull()
            .h(32)
            .px(12)
            .itemsCenter()
            .bg(c.layer01)
            .borderSides(bottom: 1.0, color: c.borderBase)

        for colSpec in columns {
            var hCell: El<State> = row().px(6).itemsCenter()
            if let w = colSpec.width {
                hCell = hCell.w(w).shrink(0)
            } else {
                hCell = hCell.grow(colSpec.grow).minW(0)
            }
            hCell = hCell.child(
                text(colSpec.title)
                    .font(ty.smallMedium)
                    .color(c.textMuted)
                    .textAlign(colSpec.align)
                    .ellipsis()
            )
            headerRow = headerRow.child(hCell)
        }

        var bodyCol: El<State> = col().wFull()
        for (rIdx, rowData) in rows.enumerated() {
            var rEl: El<State> = row()
                .key("\(key)-row-\(rIdx)")
                .wFull()
                .minH(34)
                .px(12)
                .py(6)
                .itemsCenter()
                .hover(c.hover)

            if rIdx + 1 < rows.count {
                rEl = rEl.borderSides(bottom: 1.0, color: c.borderMuted)
            }

            for colSpec in columns {
                var cEl: El<State> = row().px(6).itemsCenter()
                if let w = colSpec.width {
                    cEl = cEl.w(w).shrink(0)
                } else {
                    cEl = cEl.grow(colSpec.grow).minW(0)
                }
                cEl = cEl.child(
                    text(colSpec.cell(rowData))
                        .font(ty.ui)
                        .color(c.textBase)
                        .textAlign(colSpec.align)
                        .ellipsis()
                )
                rEl = rEl.child(cEl)
            }
            bodyCol = bodyCol.child(rEl)
        }

        return col()
            .key(key)
            .wFull()
            .rounded(radius.lg)
            .bg(c.surfaceRaised)
            .border(1.0, c.borderBase)
            .clip(true)
            .child(headerRow)
            .child(bodyCol)
    }
}
