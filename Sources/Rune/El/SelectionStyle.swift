import Foundation
import RuneMotion

/// Selection highlight and selected-text ink colors for an `El.selectable` element,
/// mirroring `crates/rune/src/el/selection_style.rs`.
public struct SelectionStyle: Hashable, Sendable {
    /// Highlight color when the window holds keyboard focus.
    public var active: Color
    /// Optional ink color override on selected glyphs while focused.
    public var activeInk: Color?
    /// Highlight color when the window is unfocused.
    public var inactive: Color
    /// Optional ink color override on selected glyphs while unfocused.
    public var inactiveInk: Color?

    /// Chromium / macOS window-state tint (`#0041c6cc` + white ink when active;
    /// `#bababacc` + `#323232` ink when unfocused).
    public static let chromium = SelectionStyle(
        active: Color.hex("#0041c6cc") ?? .srgb(0.0, 0.255, 0.776, 0.8),
        activeInk: .white,
        inactive: Color.hex("#bababacc") ?? .srgb(0.729, 0.729, 0.729, 0.8),
        inactiveInk: Color.hex("#323232") ?? .srgb(0.196, 0.196, 0.196, 1.0)
    )

    public init(
        active: Color,
        activeInk: Color? = nil,
        inactive: Color,
        inactiveInk: Color? = nil
    ) {
        self.active = active
        self.activeInk = activeInk
        self.inactive = inactive
        self.inactiveInk = inactiveInk
    }

    /// Both focused and unfocused windows draw the same highlight color without recoloring glyphs.
    public init(highlight: Color) {
        self.active = highlight
        self.activeInk = nil
        self.inactive = highlight
        self.inactiveInk = nil
    }

    /// Applies `color` as the selected-glyph ink (`ink` sets the active window ink).
    public func ink(_ color: Color) -> SelectionStyle {
        var copy = self
        copy.activeInk = color
        return copy
    }

    /// Overrides the unfocused highlight and optional glyph ink (`SelectionStyle::inactive`).
    public func inactive(_ highlight: Color, ink: Color? = nil) -> SelectionStyle {
        var copy = self
        copy.inactive = highlight
        copy.inactiveInk = ink
        return copy
    }

    /// Picks `(highlight, ink)` for the current window focus state.
    public func pick(active isFocusedWindow: Bool) -> (highlight: Color, ink: Color?) {
        if isFocusedWindow {
            return (active, activeInk)
        }
        return (inactive, inactiveInk)
    }
}

private final class SelectionChangeBox<State> {
    let handler: (inout State, SelectionChange, inout Tx) -> Void
    init(_ handler: @escaping (inout State, SelectionChange, inout Tx) -> Void) {
        self.handler = handler
    }
}

private final class SelectionCopyBox {
    let handler: (TextSelection) -> String?
    init(_ handler: @escaping (TextSelection) -> String?) {
        self.handler = handler
    }
}

/// Selectable-text and selection-group modifiers (`crates/rune/src/el/text.rs`,
/// `runtime/selection/toolbar.rs`).
public extension El {
    /// Marks this text element as user-selectable (`El::selectable`).
    func selectable(_ on: Bool = true) -> Self {
        guard !isSecure else { return self }
        var copy = self
        copy.runtimeExtras[Self.selectableExtraKey] = on
        return copy
    }

    /// Marks this container as a `selection_group` boundary (`El::selection_group`): dragging across
    /// texts or pressing Cmd+A spans and joins its selectable descendants.
    func selectionGroup(_ on: Bool = true) -> Self {
        var copy = self
        copy.runtimeExtras[Self.selectionGroupExtraKey] = on
        return copy
    }

    /// Applies an explicit `SelectionStyle` (highlight + optional ink per window focus state) to
    /// selectable text inside this element (`El::selection_style`).
    func selectionStyle(_ style: SelectionStyle) -> Self {
        var copy = self
        copy.runtimeExtras[Self.selectionStyleExtraKey] = style
        copy.selectionColor = style.active
        return copy
    }

    /// Keeps the active selectable-text selection and keyboard focus untouched when this control
    /// (e.g. a floating Copy / Quote toolbar button) is pressed (`El::keeps_text_selection`).
    func keepsTextSelection() -> Self {
        var copy = self
        copy.runtimeExtras[Self.keepsTextSelectionExtraKey] = true
        return copy
    }

    /// Fires once per commit/frame when the text selection intersecting this subtree changes,
    /// starts, clears, or releases from a drag (`El::on_selection_change`).
    func onSelectionChange(_ handler: @escaping (inout State, SelectionChange, inout Tx) -> Void) -> Self {
        var copy = self
        copy.runtimeExtras[Self.onSelectionChangeExtraKey] = SelectionChangeBox(handler)
        return copy
    }

    /// Customizes the clipboard string copied when a selection lies inside this subtree
    /// (`El::selection_copy`).
    func selectionCopy(_ handler: @escaping (TextSelection) -> String?) -> Self {
        var copy = self
        copy.runtimeExtras[Self.selectionCopyExtraKey] = SelectionCopyBox(handler)
        return copy
    }
}

internal extension El {
    static var selectableExtraKey: String { "rune.selectable" }
    static var selectionGroupExtraKey: String { "rune.selectionGroup" }
    static var selectionStyleExtraKey: String { "rune.selectionStyle" }
    static var keepsTextSelectionExtraKey: String { "rune.keepsTextSelection" }
    static var onSelectionChangeExtraKey: String { "rune.onSelectionChange" }
    static var selectionCopyExtraKey: String { "rune.selectionCopy" }

    var isSelectable: Bool {
        !isSecure && ((runtimeExtras[Self.selectableExtraKey] as? Bool) ?? false)
    }

    var isSelectionGroup: Bool {
        (runtimeExtras[Self.selectionGroupExtraKey] as? Bool) ?? false
    }

    var resolvedSelectionStyle: SelectionStyle? {
        runtimeExtras[Self.selectionStyleExtraKey] as? SelectionStyle
    }

    var preservesTextSelection: Bool {
        (runtimeExtras[Self.keepsTextSelectionExtraKey] as? Bool) ?? false
    }

    var hasSelectionChangeHandler: Bool {
        runtimeExtras[Self.onSelectionChangeExtraKey] is SelectionChangeBox<State>
    }

    var hasSelectionCopyHandler: Bool {
        runtimeExtras[Self.selectionCopyExtraKey] is SelectionCopyBox
    }

    @discardableResult
    func invokeSelectionChange(state: inout State, change: SelectionChange, tx: inout Tx) -> Bool {
        guard let box = runtimeExtras[Self.onSelectionChangeExtraKey] as? SelectionChangeBox<State> else {
            return false
        }
        box.handler(&state, change, &tx)
        return true
    }

    func invokeSelectionCopy(_ selection: TextSelection) -> String? {
        guard let box = runtimeExtras[Self.selectionCopyExtraKey] as? SelectionCopyBox else {
            return nil
        }
        return box.handler(selection)
    }

    static func liftSelectionChangeBox<Parent>(
        to _: Parent.Type = Parent.self,
        from extra: Any?,
        isValid: @escaping () -> Bool,
        get: @escaping () -> State?,
        set: @escaping (State) -> Void
    ) -> Any? {
        guard let box = extra as? SelectionChangeBox<State> else { return nil }
        return SelectionChangeBox<Parent> { _, change, tx in
            guard isValid(), var child = get() else { return }
            box.handler(&child, change, &tx)
            set(child)
        }
    }
}
