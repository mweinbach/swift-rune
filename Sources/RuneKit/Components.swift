import Foundation
import Rune
import RuneMotion

// MARK: - Accordion (`rune_kit::accordion`)

/// One item in a `Kit.accordion` disclosure group.
public struct AccordionItem<State> {
    public var id: String
    public var title: String
    public var content: () -> El<State>

    public init(id: String, title: String, content: @escaping () -> El<State>) {
        self.id = id
        self.title = title
        self.content = content
    }
}

// MARK: - Keybind (`rune_kit::keybind`)

public enum KeybindVariant: Sendable, Hashable {
    case subtle
    case outline
    case neutral
    case ghost
}

// MARK: - TabStrip (`rune_kit::shell::tab_strip`)

public struct TabItem: Sendable, Equatable {
    public var id: String
    public var title: String
    public var dirty: Bool
    public var closable: Bool

    public init(id: String, title: String, dirty: Bool = false, closable: Bool = true) {
        self.id = id
        self.title = title
        self.dirty = dirty
        self.closable = closable
    }
}

extension Kit {
    // MARK: - Accordion

    /// Multi-item disclosure accordion (`Kit::accordion`).
    public func accordion<State>(
        key: String,
        items: [AccordionItem<State>],
        expanded: Set<String>,
        onToggle: @escaping (inout State, String, Bool) -> Void
    ) -> El<State> {
        var container: El<State> = col()
            .key(key)
            .wFull()
            .rounded(radius.lg)
            .bg(c.surfaceRaised)
            .border(1.0, c.borderBase)
            .clip(true)

        for (idx, item) in items.enumerated() {
            let isOpen = expanded.contains(item.id)
            var section = collapsible(
                key: "\(key)-\(item.id)",
                title: item.title,
                isOpen: isOpen,
                onToggle: { s, open in onToggle(&s, item.id, open) },
                content: item.content
            )
            if idx + 1 < items.count {
                section = section.borderSides(bottom: 1.0, color: c.borderMuted)
            }
            container = container.child(section)
        }
        return container
    }

    // MARK: - List & ListItem (`rune_kit::list`)

    /// Selectable list row (`Kit::list_item`).
    public func listItem<State>(
        key: String,
        title: String,
        subtitle: String? = nil,
        leading: El<State>? = nil,
        trailing: El<State>? = nil,
        selected: Bool = false,
        disabled: Bool = false,
        onClick: ((inout State, inout Tx) -> Void)? = nil
    ) -> El<State> {
        var textCol: El<State> = col().grow(1).minW(0).gap(2)
            .child(
                text(title)
                    .font(selected ? ty.uiMedium : ty.ui)
                    .color(selected ? c.textAccent : c.textBase)
                    .ellipsis()
            )
        if let subtitle, !subtitle.isEmpty {
            textCol = textCol.child(
                text(subtitle)
                    .font(ty.small)
                    .color(c.textMuted)
                    .ellipsis()
            )
        }

        var r: El<State> = row()
            .key(key)
            .role(.listItem)
            .itemSelected(selected)
            .wFull()
            .minH(subtitle == nil ? 32 : 44)
            .px(10)
            .py(6)
            .gap(10)
            .itemsCenter()
            .rounded(radius.md)
            .bg(selected ? c.bgAccent.alpha(0.14) : .transparent)
            .child(leading)
            .child(textCol)
            .child(trailing)

        if disabled {
            return r.opacity(0.45).inert(true)
        }
        r = r.hover(c.hover).press(c.pressed).focusRing(c.borderFocus)
        if let onClick {
            r = r.onClick(onClick)
        }
        return r
    }

    /// Vertical list container (`Kit::list`).
    public func list<State>(
        key: String,
        items: [El<State>]
    ) -> El<State> {
        col()
            .key(key)
            .wFull()
            .gap(2)
            .focusGroup(true)
            .children(items)
    }

    // MARK: - Spinner & Loader (`rune_kit::feedback`)

    /// Circular indeterminate activity spinner (`Kit::spinner`).
    public func spinner<State>(
        key: String = "spinner",
        size: Float = 16,
        strokeWidth: Float = 2.0,
        color: Color? = nil
    ) -> El<State> {
        let r = max(2.0, (size - strokeWidth) * 0.5)
        let center = size * 0.5
        var trackPath = VectorPath()
        trackPath.arc(center: Vec2(center, center), radius: r, startAngle: 0, endAngle: 2.0 * .pi)
        var arcPath = VectorPath()
        arcPath.arc(center: Vec2(center, center), radius: r, startAngle: -.pi * 0.5, endAngle: .pi * 0.75)

        return el()
            .key(key)
            .role(.progress)
            .square(size)
            .shape(.stroke(trackPath, color: c.layer03, width: strokeWidth))
            .shape(.stroke(arcPath, color: color ?? c.textAccent, width: strokeWidth))
    }

    /// Labeled loading indicator (`Kit::loader`).
    public func loader<State>(
        key: String = "loader",
        label: String = "Loading...",
        size: Float = 16
    ) -> El<State> {
        row()
            .key(key)
            .gap(8)
            .itemsCenter()
            .child(spinner(key: "\(key)-spin", size: size))
            .child(text(label).font(ty.ui).color(c.textMuted))
    }

    // MARK: - Keybind (`rune_kit::keybind`)

    /// Formats a keycap label: uppercases single ASCII/round-tripping letters (`"k"` -> `"K"`), leaving named keys intact.
    public static func keycapLabel(_ key: String) -> String {
        let upper = key.uppercased()
        return (key.count == 1 && upper.lowercased() == key) ? upper : key
    }

    /// Keyboard shortcut keycap sequence (`Kit::keybind`).
    public func keybind<State>(
        _ keys: [String],
        variant: KeybindVariant = .subtle
    ) -> El<State> {
        let bgCol: Color
        let borderCol: Color
        let inkCol: Color
        let capHeight: Float
        let capPx: Float
        let capRadius: Float
        let capGap: Float
        let font = TextStyle(size: ty.smallMedium.size, weight: ty.smallMedium.weight, lineHeight: 11.0, letterSpacing: ty.smallMedium.letterSpacing, family: ty.smallMedium.family)

        switch variant {
        case .subtle:
            bgCol = c.layer02
            borderCol = c.borderMuted
            inkCol = c.textMuted
            capHeight = 18
            capPx = 5
            capRadius = radius.xs
            capGap = 3
        case .outline:
            bgCol = .transparent
            borderCol = c.borderBase
            inkCol = c.textMuted
            capHeight = 18
            capPx = 5
            capRadius = radius.xs
            capGap = 3
        case .neutral:
            bgCol = c.layer03
            borderCol = .transparent
            inkCol = c.textMuted
            capHeight = 14
            capPx = 4
            capRadius = 2.0
            capGap = 2.0
        case .ghost:
            bgCol = .transparent
            borderCol = .transparent
            inkCol = c.textFaint
            capHeight = 14
            capPx = 4
            capRadius = 2.0
            capGap = 2.0
        }

        return row()
            .role(.group)
            .label(keys.joined(separator: " "))
            .gap(capGap)
            .itemsCenter()
            .children(keys.enumerated().map { idx, cap in
                var box: El<State> = row()
                    .key("key\(idx)")
                    .h(capHeight)
                    .minW(capHeight)
                    .px(capPx)
                    .center()
                    .rounded(capRadius)
                    .bg(bgCol)
                if borderCol.a > 0 {
                    box = box.border(1.0, borderCol)
                }
                return box
                    .child(text(Kit.keycapLabel(cap)).font(font).color(inkCol).noWrap())
                    .a11yHidden()
            })
    }

    // MARK: - RollingText (`rune_kit::rolling_text`)

    /// Keyed status/counter text with per-grapheme LCS diffing (`Kit::rolling_text`).
    public func rollingText<State>(
        key: String,
        _ value: String,
        font: TextStyle? = nil,
        color: Color? = nil
    ) -> El<State> {
        RollingText<State>(key: key, value: value, font: font, color: color, kit: self)
            .build()
    }

    // MARK: - SearchField (`rune_kit::search`)

    /// Search input with leading magnifying glass and optional clear button (`Kit::search`).
    public func searchField<State>(
        key: String,
        _ editKeyPath: WritableKeyPath<State, TextEdit>,
        placeholder placeholderText: String = "Search...",
        onChange: ((inout State, String, inout Tx) -> Void)? = nil,
        onSubmit: ((inout State, String, inout Tx) -> Void)? = nil,
        onClear: ((inout State) -> Void)? = nil
    ) -> El<State> {
        var inputEl = Rune.textInput(key: key, editKeyPath)
            .singleLine()
            .grow(1)
            .py(6)
            .px(4)
            .font(ty.ui)
            .color(c.textBase)
            .placeholder(placeholderText, color: c.textFaint)
            .caret(c.bgAccent, selection: selection())
            .focusRing(c.borderFocus, offset: 1.0)

        if let onChange { inputEl = inputEl.onChange(onChange) }
        if let onSubmit { inputEl = inputEl.onSubmit(onSubmit) }

        var wrapper: El<State> = row()
            .key("\(key)-wrap")
            .wFull()
            .minH(32)
            .itemsCenter()
            .rounded(radius.md)
            .bg(c.surfaceWeak)
            .border(1.0, c.borderBase)
            .child(row().pl(10).pr(4).center().child(icon(KitIcons.search, size: 14).color(c.iconMuted)))
            .child(inputEl)

        if let onClear {
            wrapper = wrapper.child(
                row().pr(4).child(
                    iconButton(key: "\(key)-clear", svg: KitIcons.circleX, label: "Clear", size: .sm) { s, _ in
                        onClear(&s)
                    }
                )
            )
        }
        return wrapper
    }

    // MARK: - TabStrip (`rune_kit::shell::tab_strip`)

    /// Horizontal closable tab strip (`Kit::tab_strip`).
    public func tabStrip<State>(
        key: String,
        tabs: [TabItem],
        selected: String,
        onSelect: @escaping (inout State, String) -> Void,
        onClose: ((inout State, String) -> Void)? = nil
    ) -> El<State> {
        var strip: El<State> = row()
            .key(key)
            .wFull()
            .h(36)
            .px(6)
            .gap(2)
            .itemsCenter()
            .bg(c.layer01)
            .borderSides(bottom: 1.0, color: c.borderMuted)
            .focusGroup(true)

        for tab in tabs {
            let isSel = (tab.id == selected)
            var tabEl: El<State> = row()
                .key("\(key)-tab-\(tab.id)")
                .role(.tab)
                .label(tab.title)
                .itemSelected(isSel)
                .h(28)
                .px(10)
                .gap(6)
                .itemsCenter()
                .rounded(radius.sm)
                .bg(isSel ? c.surfaceRaised : .transparent)
                .border(isSel ? 1.0 : 0.0, isSel ? c.borderMuted : .transparent)
                .hover(isSel ? .transparent : c.hover)
                .focusRing(c.borderFocus)
                .onClick { s, _ in onSelect(&s, tab.id) }
                .child(
                    text(tab.title)
                        .font(isSel ? ty.uiMedium : ty.ui)
                        .color(isSel ? c.textBase : c.textMuted)
                        .noWrap()
                )

            if tab.dirty {
                tabEl = tabEl.child(el().square(6).pill().bg(c.bgAccent))
            }
            if tab.closable, let onClose {
                tabEl = tabEl.child(
                    row()
                        .key("\(key)-close-\(tab.id)")
                        .square(16)
                        .center()
                        .rounded(radius.xs)
                        .hover(c.pressed)
                        .onClick { s, _ in onClose(&s, tab.id) }
                        .child(icon(KitIcons.close, size: 10).color(c.iconMuted))
                )
            }
            strip = strip.child(tabEl)
        }
        return strip
    }

    // MARK: - ScrollBar (`rune_kit::scroll_bar`)

    /// Vertical scroll bar indicator (`Kit::scroll_bar`).
    public func scrollBar<State>(
        key: String = "scrollbar",
        contentFraction: Float,
        scrollFraction: Float,
        trackHeight: Float
    ) -> El<State> {
        let clampedContent = contentFraction.clamped(to: 0.05...1.0)
        let contentH = trackHeight / clampedContent
        let maxScroll = max(0, contentH - trackHeight)
        let metrics = ScrollAxisMetrics(
            offset: scrollFraction.clamped(to: 0...1) * maxScroll,
            content: contentH,
            viewport: trackHeight
        )
        let style = KitScrollBarStyle.fromKit(self)
            .key(key)
            .thumbKey("\(key)-thumb")
            .trackInsets(start: 0, end: 0)
            .edgeInset(0)
            .strip(6)
            .width(6)
            .hoverWidth(6)
            .minThumb(ScrollBarMetrics.minThumbLength)
            .track(c.layer02.alpha(0.5))
            .thumb(c.borderStrong)
            .thumbHover(c.borderStrong)
            .alwaysVisible(true)
        return styledScrollBar(style, metrics: metrics)
    }
}
