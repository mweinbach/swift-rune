#if os(Windows)
import CRuneWin32
import Foundation

/// UI Automation reads copies of the semantic tree. Only the window thread acts on the runtime.
internal final class WindowsAccessibilityHost {
    private var host: OpaquePointer?
    private var identifiers: [AccessibilityIdentity: Int32] = [:]
    private var targets: [Int32: String] = [:]
    private var nextID: Int32 = 1
    private var lastCommit: UInt64?
    private var announcementCount: UInt32?

    init(window: UnsafeMutableRawPointer?) {
        host = rune_uia_attach(window)
    }

    func close() {
        rune_uia_detach(host)
        host = nil
        identifiers.removeAll()
        targets.removeAll()
    }

    deinit {
        rune_uia_detach(host)
    }

    @discardableResult
    func drainActions<State>(_ runtime: Runtime<State>, at time: Double) -> Bool {
        guard let host else { return false }
        var id: Int32 = 0, kind: Int32 = 0, number: Double = 0
        var text: UnsafeMutablePointer<CChar>?
        var handled = false
        while true {
            var start: Int32 = 0, end: Int32 = 0, length: Int32 = 0
            if rune_uia_pop_text_selection(host, &id, &start, &end, &text, &length) != 0 {
                defer { rune_uia_free_text(text) }
                guard let target = targets[id], let text, let index = runtime.a11yTargetIndex(target),
                      let lens = runtime.flatNodes[index].el.handlers.editLens else { continue }
                let editor = lens.get(runtime.state)
                let expected = UnsafeRawBufferPointer(start: text, count: Int(length))
                guard !editor.isSecure, editor.text.utf8.elementsEqual(expected) else { continue }
                let low = ImeUTF16Bridge.utf8Offset(in: editor.text, fromUTF16Offset: Int(start))
                let high = ImeUTF16Bridge.utf8Offset(in: editor.text, fromUTF16Offset: Int(end))
                if runtime.accessibilitySelectText(target, range: min(low, high)..<max(low, high), at: time) { handled = true }
                continue
            }
            guard rune_uia_pop(host, &id, &kind, &text, &number) != 0 else { break }
            defer { rune_uia_free_text(text) }
            guard let target = targets[id] else { continue }
            let action: AccessibilityAction
            let value: AccessibilityActionValue?
            switch kind {
            case Int32(RUNE_UIA_PRESS.rawValue): action = .press; value = nil
            case Int32(RUNE_UIA_FOCUS.rawValue): action = .focus; value = nil
            case Int32(RUNE_UIA_SCROLL_INTO_VIEW.rawValue): action = .scrollIntoView; value = nil
            case Int32(RUNE_UIA_SET_TEXT.rawValue):
                guard let text else { continue }
                action = .setValue; value = .text(String(cString: text))
            case Int32(RUNE_UIA_SET_NUMBER.rawValue): action = .setValue; value = .number(number)
            case Int32(RUNE_UIA_EXPAND.rawValue), Int32(RUNE_UIA_COLLAPSE.rawValue):
                guard let index = runtime.a11yTargetIndex(target),
                      let expanded = runtime.flatNodes[index].el.a11yExpanded,
                      expanded != (kind == Int32(RUNE_UIA_EXPAND.rawValue)) else { continue }
                action = .press; value = nil
            case Int32(RUNE_UIA_SELECT.rawValue):
                guard let index = runtime.a11yTargetIndex(target) else { continue }
                let item = runtime.flatNodes[index].el
                guard !item.itemSelected && item.a11yChecked != .trueState && item.a11ySelected != "true" else { continue }
                action = .press; value = nil
            default: continue
            }
            if runtime.accessibilityAction(target, action, value: value, at: time) { handled = true }
        }
        return handled
    }

    func update<State>(_ runtime: Runtime<State>) {
        guard let host else { return }
        // Keep a usable initial tree for the first WM_GETOBJECT, including when a client attaches
        // to an idle window. Active readers also need animated and scrolled element bounds.
        let announcement = runtime.a11yAnnouncement
        guard lastCommit != runtime.commitCount || announcement.count != announcementCount || rune_uia_active(host) != 0 else { return }
        lastCommit = runtime.commitCount
        announcementCount = announcement.count
        var tree = runtime.nativeAccessibilitySnapshot()
        tree.children.append(AccessibilityTreeState.announcerNode(announcement, holdWords: false))
        let scale = Double(runtime.pixelScale)
        let viewport = MotionRect.fromXYWH(0, 0, runtime.viewport.x, runtime.viewport.y)
        var updatedIDs: [AccessibilityIdentity: Int32] = [:]
        var updatedTargets: [Int32: String] = [:]
        rune_uia_begin(host, runtime.windowTitle ?? "")

        func oneBased(_ index: Int?) -> Int32 {
            guard let index, index >= 0 else { return 0 }
            return min(Int32(clamping: index), Int32.max - 1) + 1
        }

        func publish(_ node: AccessibilityNode, id: AccessibilityIdentity, under parent: Int32, clippedTo clip: MotionRect) {
            let number: Int32
            if let existing = identifiers[id] {
                number = existing
            } else {
                guard nextID < Int32.max else { return }
                number = nextID
                nextID += 1
            }
            updatedIDs[id] = number
            updatedTargets[number] = node.runtimePath ?? node.id
            let rect = MotionRect(
                left: max(clip.left, node.frame.left), top: max(clip.top, node.frame.top),
                right: min(clip.right, node.frame.right), bottom: min(clip.bottom, node.frame.bottom)
            )
            var native = RuneUiaNode()
            native.id = number
            native.parent = parent
            native.x = Double(rect.left) * scale
            native.y = Double(rect.top) * scale
            native.width = Double(rect.width) * scale
            native.height = Double(rect.height) * scale
            native.focused = node.isFocused ? 1 : 0
            native.focusable = node.isFocusable ? 1 : 0
            native.disabled = node.isDisabled ? 1 : 0
            let secure = node.isSecure || node.role == .passwordInput
            native.secure = secure ? 1 : 0
            native.read_only = node.isReadOnly ? 1 : 0
            native.pressable = node.actions.contains(.press) ? 1 : 0
            native.settable = node.actions.contains(.setValue) ? 1 : 0
            native.scroll_item = node.actions.contains(.scrollIntoView) ? 1 : 0
            native.modal = node.isModal ? 1 : 0
            native.toggle = Self.toggleState(node)
            if node.role == .radio {
                native.selected = node.isSelected || node.toggled == .trueState || node.value == "true" ? 1 : 0
            } else {
                native.selected = node.selectedState.map { $0 ? 1 : 0 } ?? -1
            }
            native.expanded = node.isExpanded.map { $0 ? 1 : 0 } ?? -1
            native.level = oneBased(node.level)
            native.position = oneBased(node.positionInSet)
            native.size_of_set = node.sizeOfSet.map { Int32(clamping: $0) } ?? 0
            switch node.liveRegion {
            case .polite: native.live = 1
            case .assertive: native.live = 2
            case nil: native.live = 0
            }
            if let range = node.range {
                native.has_range = 1
                native.minimum = range.min
                native.maximum = range.max
                native.number = range.value
                native.step = range.step ?? 0
            }
            let name = AccessibilityDump.resolvedName(for: node) ?? ""
            rune_uia_add(host, native, node.id, node.role.rawValue, name, node.help ?? node.placeholder ?? "",
                         secure ? "" : node.value ?? "", node.keyboardShortcut ?? "")
            if !secure, node.role == .textInput || node.role == .multilineTextInput,
               let selection = node.textSelection, selection.count == 4, let value = node.value,
               let target = node.runtimePath {
                let utf16 = Array(value.utf16)
                if utf16.count < Int(Int32.max) {
                    let anchor = Int32(clamping: ImeUTF16Bridge.utf16Offset(in: value, fromUTF8Offset: selection[1]))
                    let focus = Int32(clamping: ImeUTF16Bridge.utf16Offset(in: value, fromUTF8Offset: selection[3]))
                    if let cells = runtime.windowsTextGeometry(target: target, clip: rect) {
                        var offsets: [Int32] = [0]
                        var offset: Int32 = 0
                        for character in value {
                            offset += Int32(character.utf16.count)
                            offsets.append(offset)
                        }
                        rune_uia_text_model(host, number, anchor, focus, utf16, Int32(utf16.count), offsets, Int32(offsets.count))
                        rune_uia_text_geometry(host, number, cells, Int32(cells.count), windowsAccessibilityWordBreaks)
                    } else {
                        rune_uia_text_model(host, number, anchor, focus, utf16, Int32(utf16.count), nil, 0)
                    }
                }
            }
            var occurrences: [String: Int] = [:]
            for child in node.children {
                let childID = AccessibilityIdentity(child, parent: id, occurrences: &occurrences)
                publish(child, id: childID, under: number, clippedTo: node.clipsChildren ? rect : clip)
            }
        }
        var roots: [String: Int] = [:]
        let rootID = AccessibilityIdentity(tree, parent: nil, occurrences: &roots)
        publish(tree, id: rootID, under: 0, clippedTo: viewport)
        identifiers = updatedIDs
        targets = updatedTargets
        rune_uia_commit(host)
    }

    private static func toggleState(_ node: AccessibilityNode) -> Int8 {
        switch node.toggled {
        case .falseState: return 0
        case .trueState: return 1
        case .mixed: return 2
        case nil:
            switch node.role {
            case .checkbox, .switchControl, .menuItemCheckbox:
                // Rune also exposes the legacy selected("true"/"false") binding as a value.
                return node.value == "mixed" ? 2 : (node.value == "true" || node.isSelected ? 1 : 0)
            default: return -1
            }
        }
    }
}
#endif
