import Foundation

// MARK: - Assistive SetValue & Text-Field Roles (`rune::a11y::{actions, node, roles}`)

/// Data an assistive client sends with an action request
/// (`accesskit::ActionData::Value` / `accesskit::ActionData::NumericValue`).
public enum AccessibilityActionValue: Sendable, Equatable {
    /// A new value for an editable text field (`ActionData::Value`).
    case text(String)
    /// A number for a stepped range such as a slider (`ActionData::NumericValue`).
    case number(Double)
}

public extension AccessibilityTreeBuilder {
    /// The role an editable text field reads as (`a11y/roles.rs:27-31`): a secure field is a
    /// password input, a field that is not single-line a multi-line text input, else a text input.
    static func textFieldRole(secure: Bool, multiline: Bool) -> ElementRole {
        if secure { return .passwordInput }
        return multiline ? .multilineTextInput : .textInput
    }

    /// Whether an element offers `SetValue` (`a11y/node.rs:225-240`): an enabled field with edit
    /// access does, and so does an enabled control with `onStep` whose range states a positive step.
    static func offersSetValue(enabled: Bool, editable: Bool, steps: Bool, range: A11yRange?) -> Bool {
        guard enabled else { return false }
        if editable { return true }
        guard steps, let step = range?.step else { return false }
        return step > 0
    }

    /// A number asked of a stepped range as that many steps from its value (`a11y/actions.rs:73-82`):
    /// the target clamps into the range, the distance rounds to whole steps and saturates to `i32`,
    /// and no movement is `nil`. As Rust's `as i32` does, a NaN distance is no movement.
    static func setValueSteps(target: Double, range: A11yRange?) -> Int? {
        guard let range, let step = range.step, step > 0 else { return nil }
        // `r.min.min(r.max)` / `r.max.max(r.min)`: Rust's `f64::min`/`max` ignore a NaN operand.
        let lo = Double.minimum(range.min, range.max)
        let hi = Double.maximum(range.max, range.min)
        guard !lo.isNaN, !hi.isNaN else { return nil }
        // `f64::clamp` keeps a NaN target NaN.
        let clamped = target.isNaN ? target : (target < lo ? lo : (target > hi ? hi : target))
        let raw = ((clamped - range.value) / step).rounded()
        guard !raw.isNaN else { return nil }
        let delta: Int
        if raw <= Double(Int32.min) {
            delta = Int(Int32.min)
        } else if raw >= Double(Int32.max) {
            delta = Int(Int32.max)
        } else {
            delta = Int(raw)
        }
        return delta == 0 ? nil : delta
    }

    /// Appends `action` once, as AccessKit's action set holds each action at most once.
    internal static func appendAction(_ action: AccessibilityAction, to actions: inout [AccessibilityAction]) {
        if !actions.contains(action) { actions.append(action) }
    }
}

/// What the element-list tree (`AccessibilityTreeBuilder.project(elements:)`) needs of an element
/// to read its role and actions as the live tree does (`a11y/node.rs:31,222-240`).
public struct ElementA11yInput: Sendable, Equatable {
    /// It has an editor (`input.is_some()`).
    public var isInput: Bool
    /// Its editor takes edits (`input.access.is_some()`).
    public var editable: Bool
    /// It is a field that is not single-line (`RoleCtx::multiline`).
    public var multiline: Bool
    /// It has its own primary press handler (`on_press`).
    public var pressable: Bool
    /// It steps (`focus.step.is_some()`).
    public var steps: Bool
    internal var keepsControlContent = false
    internal var isDefaultButton = false
    internal var labelledBy: String?
    public var range: A11yRange?

    public init(isInput: Bool, editable: Bool, multiline: Bool, pressable: Bool, steps: Bool, range: A11yRange?) {
        self.isInput = isInput
        self.editable = editable
        self.multiline = multiline
        self.pressable = pressable
        self.steps = steps
        self.range = range
    }

    internal init<State>(_ el: El<State>) {
        self.init(
            isInput: el.handlers.editLens != nil,
            editable: el.hasEditAccess,
            multiline: el.isMultilineField,
            pressable: el.handlers.onClick != nil || el.handlers.onClickPress != nil,
            steps: el.handlers.onStep != nil,
            range: el.a11yRange
        )
        keepsControlContent = el.keepsControlContent
        isDefaultButton = el.isDefaultButton && AccessibilityRoleRules.role(for: el, focusable: el.focusable && !el.a11yDisabled) == .button
        labelledBy = el.a11yLabelledBy
    }
}

public extension El {
    /// Keeps the field's editor on screen but takes no edits through it, as an upstream field
    /// without `on_edit` (`Input::access == None`). Kit fields set this when disabled, as upstream
    /// `Edits::apply` leaves a disabled field's handlers off (`rune-kit/src/text_input.rs:102-110`).
    func withoutEditAccess(_ on: Bool = true) -> Self {
        var c = self
        c.editAccessWithheld = on
        return c
    }

    /// The field can be edited (`input.access.is_some()`).
    internal var hasEditAccess: Bool { handlers.editLens != nil && !editAccessWithheld }

    /// `RoleCtx::multiline` (`a11y/node.rs:31`): a field that is not `singleLine()`.
    internal var isMultilineField: Bool { handlers.editLens != nil && !isSingleLineInput }
}

public extension Runtime {
    /// Asks what an assistive client would of the element keyed (or at path) `id`, with the data
    /// the request carries (`Runtime::accessibility_action(key, action, data)`). Returns whether
    /// anything ran. `SetValue` needs `value`; other actions ignore it.
    @discardableResult
    func accessibilityAction(
        _ id: String,
        _ action: AccessibilityAction,
        value: AccessibilityActionValue?,
        at now: Double = 0
    ) -> Bool {
        if action == .setValue {
            return performAccessibilitySetValue(id, value: value, at: now)
        }
        return performAccessibilityAction(id, action: action, at: now)
    }

    /// Applies a reader's selection expressed in UTF-8 bytes of the field's value.
    @discardableResult
    func accessibilitySelectText(_ id: String, range: Range<Int>, at now: Double = 0) -> Bool {
        guard let i = a11yTargetIndex(id), a11yAllowed(i) else { return false }
        let el = flatNodes[i].el
        guard el.hasEditAccess, !el.isSecure, let lens = el.handlers.editLens,
              !lens.get(state).isSecure else { return false }
        return a11yEdit(index: i, at: now) { edit in
            let anchor = edit.clampScalarBoundary(range.lowerBound)
            let focus = edit.clampScalarBoundary(range.upperBound)
            edit.setSelectionRaw(anchor: anchor, cursor: focus)
            edit.snapToPills()
            edit.typingStyle = .inherited
            edit.caretColumn = .free
            edit.caretAffinity = .downstream
        }
    }

    /// Runs `SetValue` (`a11y/actions.rs:67-82`, `:147-151`): a field with edit access focuses (as
    /// a reader focuses it first) and its whole text is replaced through its editor so its change
    /// handlers run as for typing; a stepped control moves by the steps the number asks for.
    @discardableResult
    internal func performAccessibilitySetValue(
        _ id: String,
        value: AccessibilityActionValue?,
        at now: Double
    ) -> Bool {
        guard let idx = a11yTargetIndex(id), a11yAllowed(idx) else { return false }
        let node = flatNodes[idx]
        if node.el.hasEditAccess {
            guard case .text(let text)? = value else { return false }
            return a11yEdit(index: idx, at: now) { edit in
                // `e.set_selection(0, e.text.len()); e.paste(&value)`.
                edit.selectAll()
                edit.paste(text)
            }
        }
        if let onStep = node.el.handlers.onStep {
            guard case .number(let target)? = value,
                  let delta = AccessibilityTreeBuilder.setValueSteps(target: target, range: node.el.a11yRange) else {
                return false
            }
            var tx = makeTx(at: now)
            onStep(&state, delta, &tx)
            applyTx(tx, at: now)
            dirtyCommit(at: now)
            return true
        }
        return false
    }

    /// Native adapters send the full path. An author key remains available to direct callers.
    internal func a11yTargetIndex(_ id: String) -> Int? {
        nodeByPath[id] ?? flatNodes.firstIndex(where: { $0.key == id })
    }

    /// Whether an assistive action may reach node `idx` (`a11y_action`: `allowed(i)` — outside any
    /// inert subtree and inside the modal — and `!subtree_exiting(i)`).
    internal func a11yAllowed(_ idx: Int) -> Bool {
        guard idx >= 0, idx < flatNodes.count else { return false }
        let node = flatNodes[idx]
        if node.effectiveInert { return false }
        if activeModalPath != nil && !modalMemberPaths.contains(node.path) { return false }
        // `subtree_exiting(i)`: the node or an ancestor is animating out.
        var walk: Int? = idx
        while let cur = walk, cur >= 0, cur < flatNodes.count {
            if scene.isExiting(flatNodes[cur].nodeId) { return false }
            walk = flatNodes[cur].parentIndex
        }
        return true
    }

    /// `pressable` in `a11y_action` / `a11y_node` (`a11y/actions.rs:43`, `node.rs:225`): the element
    /// has its own primary press handler (`El::on_press`, Swift `onClick` / `onClickPress`).
    internal func a11yPressable(_ el: El<State>) -> Bool {
        el.handlers.onClick != nil || el.handlers.onClickPress != nil
    }

    /// What a pointer or keyboard user can do to node `node`, as the tree advertises it
    /// (`a11y/node.rs:222-240`, all under `actionable`: enabled and allowed).
    internal func a11yNodeActions(_ node: FlatNode) -> [AccessibilityAction] {
        let el = node.el
        let enabled = !el.a11yDisabled && !node.effectiveInert
        guard enabled else { return [] }
        var actions: [AccessibilityAction] = []
        // `on_press.is_some() || input.is_some()`; Swift also reads its press roles as pressable.
        if a11yPressable(el) || el.handlers.editLens != nil ||
           [.button, .checkbox, .switchControl, .radio, .tab, .menuItem, .menuItemCheckbox, .menuItemRadio].contains(el.role) {
            actions.append(.press)
        }
        if el.focusable {
            actions.append(.focus)
        }
        if el.role == .slider || el.handlers.onStep != nil {
            actions.append(.increment)
            actions.append(.decrement)
        }
        if AccessibilityTreeBuilder.offersSetValue(
            enabled: enabled,
            editable: el.hasEditAccess,
            steps: el.handlers.onStep != nil,
            range: el.a11yRange
        ) {
            AccessibilityTreeBuilder.appendAction(.setValue, to: &actions)
        }
        return actions
    }

    /// Whether `a11y_action` takes `action` on node `node` (`a11y/actions.rs:32-81`): it reads the
    /// handlers the element has, not whether it is disabled (`El::disabled` only drops focusability).
    internal func a11yTakes(_ action: AccessibilityAction, on node: FlatNode) -> Bool {
        let el = node.el
        switch action {
        // `(Click, None) if pressable` / `(Click, None) if input` (focus).
        case .press: return a11yPressable(el) || el.handlers.editLens != nil
        // `(Focus, None) if focusable`: `can_focus` — takes focus, or a field with edit access.
        case .focus: return el.focusable || el.hasEditAccess
        // `(Increment | Decrement, None) if steps`.
        case .increment, .decrement: return el.handlers.onStep != nil
        case .setValue: return el.hasEditAccess || el.handlers.onStep != nil
        }
    }

    /// Moves focus to `path` (or clears it), as keyboard focus when `keyboard`
    /// (`Runtime::set_focus(path, keyboard)`): an open composition in the field left finishes, the
    /// IME resets, and kit fields hear the focus change.
    internal func setFocus(path: String?, keyboard: Bool, at now: Double) {
        guard focusedPath != path else { return }
        let prevNode = focusedPath.flatMap { nodeByPath[$0] }.map { flatNodes[$0] }
        handleKitFocusTransition(prevNode: prevNode, newPath: path, at: now)
        finishPreeditIfNeeded(forPath: focusedPath, at: now)
        imeReset = true
        focusedPath = path
        focusedKey = path.flatMap { nodeByPath[$0] }.flatMap { flatNodes[$0].key }
        focusKeyboard = keyboard
        focusVisible = keyboard && path != nil
        blurredFocusPath = nil
        focusHandoff = false
    }

    /// Focuses field `idx` (as a reader focuses it first) and edits the focused field through its
    /// editor (`a11y_edit` → `with_focused`): its change handlers run only when the text changed.
    internal func a11yEdit(index idx: Int, at now: Double, _ apply: (inout TextEdit) -> Void) -> Bool {
        let path = flatNodes[idx].path
        if focusedPath != path { setFocus(path: path, keyboard: true, at: now) }
        guard let fp = focusedPath,
              let el = focusedInputElement(at: fp),
              el.hasEditAccess,
              let editLens = el.handlers.editLens else {
            return false
        }
        let prevEdit = editLens.get(state)
        var edit = prevEdit
        let stateRevealed = edit.isRevealed
        // `edit.set_single_line(single_line)`: the field's El decides one line or many.
        edit.multiline = !el.isSingleLineInput
        if el.isSecure && !edit.isSecure { edit.isSecure = true }
        if let rev = el.revealedOverride { edit.isRevealed = rev }
        apply(&edit)
        edit.isRevealed = stateRevealed
        if edit.text != prevEdit.text {
            deliverInputEdit(el: el, previousEdit: prevEdit, newEdit: edit, editLens: editLens, at: now)
        } else {
            // The selection moved but nothing changed: no change handler (`with_focused`).
            editLens.set(&state, edit)
            pendingCaretFollow = true
            dirtyCommit(at: now)
        }
        return true
    }
}
