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

    /// Whether an element offers `SetValue` (`a11y/node.rs:225-235`): an enabled editable field
    /// does, and so does an enabled stepped control whose range states a positive step.
    static func offersSetValue(enabled: Bool, editable: Bool, steps: Bool, range: A11yRange?) -> Bool {
        guard enabled else { return false }
        if editable { return true }
        guard steps, let step = range?.step else { return false }
        return step > 0
    }

    /// A number asked of a stepped range as that many steps from its value (`a11y/actions.rs:73-82`):
    /// the target clamps into the range, the distance rounds to whole steps, and no movement is `nil`.
    static func setValueSteps(target: Double, range: A11yRange?) -> Int? {
        guard let range, let step = range.step, step > 0 else { return nil }
        let lo = Swift.min(range.min, range.max)
        let hi = Swift.max(range.max, range.min)
        let clamped = Swift.min(Swift.max(target, lo), hi)
        let raw = ((clamped - range.value) / step).rounded()
        let delta = Int(Swift.min(Swift.max(raw, Double(Int32.min)), Double(Int32.max)))
        return delta == 0 ? nil : delta
    }

    /// Appends `action` once, as AccessKit's action set holds each action at most once.
    internal static func appendAction(_ action: AccessibilityAction, to actions: inout [AccessibilityAction]) {
        if !actions.contains(action) { actions.append(action) }
    }
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

    /// Runs `SetValue` (`a11y/actions.rs:67-82`, `:147-151`): an editable field focuses (as a reader
    /// focuses it first) and its whole text is replaced through its editor so its change handlers
    /// run as for typing; a stepped range moves by the steps the number asks for through `onStep`.
    @discardableResult
    internal func performAccessibilitySetValue(
        _ id: String,
        value: AccessibilityActionValue?,
        at now: Double
    ) -> Bool {
        guard let idx = flatNodes.firstIndex(where: { ($0.key ?? $0.path) == id || $0.path == id }) else {
            return false
        }
        let node = flatNodes[idx]
        // `Runtime::allowed`: inert, disabled and outside-the-modal elements take no action.
        guard !node.effectiveInert, !node.el.a11yDisabled else { return false }
        if activeModalPath != nil && !modalMemberPaths.contains(node.path) { return false }

        if let editLens = node.el.handlers.editLens {
            guard case .text(let text)? = value else { return false }
            a11yFocusForEdit(index: idx, at: now)
            let prevEdit = editLens.get(state)
            var edit = prevEdit
            let stateRevealed = edit.isRevealed
            if node.el.isSecure {
                edit.isSecure = true
                if node.el.isRevealed { edit.isRevealed = true }
            }
            // `e.set_selection(0, e.text.len())`: the whole text, then pasted over.
            edit.selectAll()
            edit.paste(text)
            edit.isRevealed = stateRevealed
            deliverInputEdit(el: node.el, previousEdit: prevEdit, newEdit: edit, editLens: editLens, at: now)
            return true
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

    /// Focuses field `idx` as keyboard focus before an assistive edit (`a11y_edit` → `set_focus(path, true)`).
    private func a11yFocusForEdit(index idx: Int, at now: Double) {
        let target = flatNodes[idx]
        guard focusedPath != target.path, canFocusIndex(idx) else { return }
        let prevNode = focusedPath.flatMap { nodeByPath[$0] }.map { flatNodes[$0] }
        handleKitFocusTransition(prevNode: prevNode, newPath: target.path, at: now)
        finishPreeditIfNeeded(forPath: focusedPath, at: now)
        imeReset = true
        focusedPath = target.path
        focusedKey = target.key
        focusKeyboard = true
        focusVisible = true
        blurredFocusPath = nil
        focusHandoff = false
    }
}
