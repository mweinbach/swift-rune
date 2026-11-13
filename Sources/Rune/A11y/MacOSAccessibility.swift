import Foundation

#if os(macOS) && canImport(AppKit)
import AppKit
#endif

// MARK: - Cross-Platform Runtime Accessibility Projection & Action Dispatch

public extension AccessibilityTreeBuilder {
    /// Projects a flattened `[ElementInfo]` array from `Runtime.elements()` into a nested `AccessibilityNode` tree.
    /// Secure text fields (`securePaths.contains(path)` or `role == .textInput && text == nil`) never leak `value`.
    static func project(
        elements: [ElementInfo],
        focusedPath: String?,
        viewport: Vec2,
        securePaths: Set<String> = []
    ) -> AccessibilityNode {
        var childrenByParent: [Int: [Int]] = [:]
        var roots: [Int] = []
        for (idx, info) in elements.enumerated() where !info.inert {
            if let parent = info.parentIndex {
                childrenByParent[parent, default: []].append(idx)
            } else {
                roots.append(idx)
            }
        }

        func build(_ idx: Int) -> AccessibilityNode {
            let info = elements[idx]
            let isSecure = securePaths.contains(info.path) || (info.role == .textInput && info.text == nil)
            var actions: [AccessibilityAction] = []
            if info.role == .button || info.role == .checkbox || info.role == .switchControl ||
                info.role == .radio || info.role == .tab || info.role == .menuItem {
                actions.append(.press)
            }
            if info.focusable {
                actions.append(.focus)
            }
            if info.role == .slider {
                actions.append(.increment)
                actions.append(.decrement)
            }

            let rect = info.rect.count >= 4
                ? MotionRect.fromXYWH(info.rect[0], info.rect[1], info.rect[2], info.rect[3])
                : .zero

            let projectedValue: String? = isSecure ? nil : info.text
            let projectedLabel: String? = isSecure ? (info.label ?? "Password") : (info.label ?? info.key)
            let nodeId = info.key ?? info.path

            return AccessibilityNode(
                id: nodeId,
                role: (isSecure && info.role == .textInput) ? .passwordInput : info.role,
                label: projectedLabel,
                value: projectedValue,
                help: info.help,
                frame: rect,
                isFocused: info.focused || info.path == focusedPath,
                isFocusable: info.focusable,
                isSelected: info.itemSelected,
                isExpanded: info.expanded,
                level: info.level,
                isModal: info.role == .dialog,
                isSecure: isSecure,
                actions: actions,
                children: (childrenByParent[idx] ?? []).map(build)
            )
        }

        let builtRoots = roots.map(build)
        if builtRoots.count == 1 {
            return builtRoots[0]
        }
        return AccessibilityNode(
            id: "root",
            role: .group,
            label: nil,
            value: nil,
            frame: MotionRect.fromXYWH(0, 0, viewport.x, viewport.y),
            children: builtRoots
        )
    }

    /// Computes live-region and modal/dialog announcements when transitioning between snapshots.
    /// Secure fields are strictly excluded.
    static func liveAnnouncements(
        previous: AccessibilityNode?,
        current: AccessibilityNode
    ) -> [AccessibilityAnnouncement] {
        func flatten(_ node: AccessibilityNode, into out: inout [String: AccessibilityNode]) {
            out[node.id] = node
            for child in node.children {
                flatten(child, into: &out)
            }
        }

        var prevMap: [String: AccessibilityNode] = [:]
        if let previous {
            flatten(previous, into: &prevMap)
        }

        var announcements: [AccessibilityAnnouncement] = []
        func visit(_ node: AccessibilityNode) {
            if !node.isSecure {
                let prev = prevMap[node.id]
                let currentText = [node.label, node.value].compactMap { $0 }.joined(separator: " ")
                let prevText = prev.map { [$0.label, $0.value].compactMap { $0 }.joined(separator: " ") } ?? ""

                if node.role == .dialog || node.isModal {
                    if !currentText.isEmpty && (prev == nil || currentText != prevText) {
                        announcements.append(AccessibilityAnnouncement(text: currentText, politeness: .assertive))
                    }
                } else if let live = node.liveRegion {
                    if !currentText.isEmpty && (prev == nil || currentText != prevText || prev?.liveRegion != live) {
                        announcements.append(AccessibilityAnnouncement(text: currentText, politeness: live))
                    }
                }
            }
            for child in node.children {
                visit(child)
            }
        }
        visit(current)
        return announcements
    }
}

public extension Runtime {
    /// Returns the current accessibility tree snapshot built from live runtime elements.
    func accessibilitySnapshot(securePaths: Set<String> = []) -> AccessibilityNode {
        if flatNodes.isEmpty {
            return AccessibilityTreeBuilder.project(
                elements: elements(),
                focusedPath: focusedPath,
                viewport: viewport,
                securePaths: securePaths
            )
        }

        // Map keyed elements to descriptive text for `labelledBy` / `describedBy`.
        var textByKey: [String: String] = [:]
        func collectText(_ idx: Int, into parts: inout [String], childrenByParent: [Int: [Int]]) {
            let n = flatNodes[idx]
            guard !n.el.isA11yHidden && !n.el.isSecure else { return }
            if let lbl = n.el.a11yLabel, !lbl.isEmpty { parts.append(lbl) }
            else if let txt = n.el.plainText, !txt.isEmpty { parts.append(txt) }
            for c in (childrenByParent[idx] ?? []) {
                collectText(c, into: &parts, childrenByParent: childrenByParent)
            }
        }

        var childrenByParent: [Int: [Int]] = [:]
        var roots: [Int] = []
        for (idx, node) in flatNodes.enumerated() {
            if node.effectiveInert || node.el.isA11yHidden { continue }
            if let pIdx = node.parentIndex,
               pIdx >= 0,
               pIdx < flatNodes.count,
               !flatNodes[pIdx].effectiveInert,
               !flatNodes[pIdx].el.isA11yHidden {
                childrenByParent[pIdx, default: []].append(idx)
            } else {
                roots.append(idx)
            }
        }
        for (idx, node) in flatNodes.enumerated() where !node.effectiveInert && !node.el.isA11yHidden {
            if let k = node.key {
                var parts: [String] = []
                collectText(idx, into: &parts, childrenByParent: childrenByParent)
                if !parts.isEmpty {
                    textByKey[k] = parts.joined(separator: " ")
                }
            }
        }

        let selectableRoles: Set<ElementRole> = [.listItem, .option, .tab, .treeItem, .gridCell, .row]
        func build(_ idx: Int) -> AccessibilityNode {
            let node = flatNodes[idx]
            let el = node.el
            var editIsSecure = el.isSecure
            var editText: String? = el.plainText
            var editChars: Int? = nil
            var editSel: [Int]? = nil
            if let editLens = el.handlers.editLens {
                let edit = editLens.get(state)
                editIsSecure = editIsSecure || edit.isSecure
                if !editIsSecure {
                    editText = edit.text
                    editChars = edit.text.count
                    let lo = min(edit.anchor, edit.cursor)
                    let hi = max(edit.anchor, edit.cursor)
                    editSel = [0, lo, 0, hi]
                } else {
                    editText = nil
                }
            }
            let isSecure = editIsSecure || securePaths.contains(node.path) || (el.role == .textInput && editText == nil)
            let rect = presentedRectByPath[node.path] ?? node.targetRect
            let nodeId = node.key ?? node.path

            var actions: [AccessibilityAction] = []
            if el.handlers.onClick != nil || el.handlers.onClickPress != nil ||
               [.button, .checkbox, .switchControl, .radio, .tab, .menuItem].contains(el.role) {
                actions.append(.press)
            }
            if el.focusable && !node.effectiveInert {
                actions.append(.focus)
            }
            if el.role == .slider {
                actions.append(.increment)
                actions.append(.decrement)
            }

            let resolvedValue: String? = isSecure ? nil : (el.a11yValue ?? el.a11ySelected ?? editText)
            let labelledByText = el.a11yLabelledBy.flatMap { textByKey[$0] }
            let describedByText = el.a11yDescribedBy.flatMap { textByKey[$0] }
            let resolvedLabel: String? = isSecure
                ? (el.a11yLabel ?? labelledByText ?? "Password")
                : (el.a11yLabel ?? labelledByText ?? (el.role == .textInput ? nil : el.plainText))
            let resolvedHelp: String? = el.a11yDescription ?? describedByText ?? el.a11yHelp
            let selectedState: Bool? = (selectableRoles.contains(el.role) || el.itemSelected) ? el.itemSelected : nil

            let hasScroll = !el.layout.scrollAxes.isEmpty
            let sOff = hasScroll ? (scrollOffsets[node.path] ?? .zero) : nil
            let sMax = hasScroll ? scrollMaxExtents[node.path] : nil

            let resolvedRole: ElementRole = (isSecure && el.role == .textInput) ? .passwordInput : el.role

            return AccessibilityNode(
                id: nodeId,
                role: resolvedRole,
                label: resolvedLabel,
                value: resolvedValue,
                help: resolvedHelp,
                placeholder: el.placeholder,
                range: el.a11yRange,
                frame: rect,
                isFocused: (node.path == focusedPath) || (focusedKey != nil && node.key == focusedKey),
                isFocusable: el.focusable && !node.effectiveInert,
                isSelected: el.itemSelected,
                selectedState: selectedState,
                isExpanded: el.a11yExpanded,
                level: el.a11yLevel,
                positionInSet: el.a11yPosInSet?.position,
                sizeOfSet: el.a11yPosInSet?.size,
                keyboardShortcut: el.a11yShortcutHint,
                url: el.a11yHref,
                activeDescendant: el.a11yActiveDescendant,
                sortAscending: el.a11ySorted,
                isDisabled: el.a11yDisabled,
                isReadOnly: el.a11yReadOnly,
                isInvalid: el.a11yInvalid,
                toggled: el.a11yChecked,
                liveRegion: el.a11yLive,
                clipsChildren: el.layout.clipOverflow,
                scrollX: sOff?.x,
                scrollY: sOff?.y,
                scrollYMax: sMax?.y,
                textSelection: editSel,
                characterCount: editChars,
                isModal: el.isModal || el.role == .dialog,
                isSecure: isSecure,
                actions: actions,
                children: (childrenByParent[idx] ?? []).map(build)
            )
        }

        let builtRoots = roots.map(build)
        if builtRoots.count == 1 {
            return builtRoots[0]
        }
        return AccessibilityNode(
            id: "root",
            role: .group,
            label: nil,
            value: nil,
            frame: MotionRect.fromXYWH(0, 0, viewport.x, viewport.y),
            children: builtRoots
        )
    }

    /// Dispatches an accessibility action onto an element identified by `id` (`key` or `path`).
    @discardableResult
    func performAccessibilityAction(
        _ id: String,
        action: AccessibilityAction,
        at now: Double
    ) -> Bool {
        let all = elements()
        guard let target = all.first(where: { ($0.key ?? $0.path) == id || $0.path == id }),
              !target.inert,
              target.rect.count >= 4 else {
            return false
        }
        let cx = target.rect[0] + target.rect[2] * 0.5
        let cy = target.rect[1] + target.rect[3] * 0.5
        let center = Vec2(cx, cy)

        switch action {
        case .press, .focus:
            pointerDown(at: center, button: .primary, mods: Mods(), at: now)
            pointerUp(at: center, button: .primary, mods: Mods(), at: now)
            return true
        case .increment:
            pointerDown(at: center, button: .primary, mods: Mods(), at: now)
            pointerUp(at: center, button: .primary, mods: Mods(), at: now)
            return keyDown(KeyEvent(key: .arrowUp), at: now) || keyDown(KeyEvent(key: .arrowRight), at: now)
        case .decrement:
            pointerDown(at: center, button: .primary, mods: Mods(), at: now)
            pointerUp(at: center, button: .primary, mods: Mods(), at: now)
            return keyDown(KeyEvent(key: .arrowDown), at: now) || keyDown(KeyEvent(key: .arrowLeft), at: now)
        }
    }
}

#if os(macOS) && canImport(AppKit)

/// Bridges `AccessibilityNode` trees and live-region announcements onto an AppKit `NSView` for VoiceOver.
@MainActor
public final class MacOSAccessibilityHost {
    private var previousTree: AccessibilityNode?
    private var lastFocusedId: String?
    private var rootElements: [RuneNSAccessibilityElement] = []
    private var elementById: [String: RuneNSAccessibilityElement] = [:]

    public init() {}

    /// Rebuilds cached `NSAccessibilityElement` wrappers for `tree` and emits focus / VoiceOver announcements.
    public func update(
        tree: AccessibilityNode,
        parentView: NSView,
        onAction: @escaping @Sendable (String, AccessibilityAction) -> Void
    ) {
        let announcements = AccessibilityTreeBuilder.liveAnnouncements(previous: previousTree, current: tree)
        previousTree = tree

        var map: [String: RuneNSAccessibilityElement] = [:]
        func convertNode(_ node: AccessibilityNode, parent: AnyObject) -> RuneNSAccessibilityElement {
            let elem = AppKitAccessibilityMapper.buildElement(from: node, onAction: onAction)
            elem.setAccessibilityParent(parent)

            let viewRect = NSRect(
                x: CGFloat(node.frame.left),
                y: CGFloat(node.frame.top),
                width: CGFloat(max(0, node.frame.width)),
                height: CGFloat(max(0, node.frame.height))
            )
            if let window = parentView.window {
                let winRect = parentView.convert(viewRect, to: nil)
                let screenRect = window.convertToScreen(winRect)
                elem.setAccessibilityFrame(screenRect)
            } else {
                elem.setAccessibilityFrame(viewRect)
            }

            let builtChildren = node.children.map { convertNode($0, parent: elem) }
            elem.setAccessibilityChildren(builtChildren)
            map[node.id] = elem
            return elem
        }

        if tree.id == "root" && tree.role == .group && tree.label == nil {
            rootElements = tree.children.map { convertNode($0, parent: parentView) }
        } else {
            rootElements = [convertNode(tree, parent: parentView)]
        }
        elementById = map

        let focusedNodeId = Self.findFocusedId(in: tree)
        if focusedNodeId != lastFocusedId {
            lastFocusedId = focusedNodeId
            if let fid = focusedNodeId, let focusedElem = map[fid] {
                NSAccessibility.post(element: focusedElem, notification: .focusedUIElementChanged)
            } else {
                NSAccessibility.post(element: parentView, notification: .focusedUIElementChanged)
            }
        }

        for announcement in announcements {
            guard let spoken = announcement.spokenText else { continue }
            let priority: NSAccessibilityPriorityLevel =
                announcement.politeness == .assertive ? .high : .medium
            NSAccessibility.post(
                element: parentView,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: spoken,
                    .priority: priority.rawValue,
                ]
            )
        }
    }

    public func accessibilityChildren() -> [Any] {
        rootElements
    }

    public func accessibilityFocusedUIElement() -> Any? {
        if let fid = lastFocusedId {
            return elementById[fid]
        }
        return nil
    }

    public func accessibilityHitTest(_ screenPoint: NSPoint, in parentView: NSView) -> Any? {
        func hitTestNode(_ element: RuneNSAccessibilityElement) -> RuneNSAccessibilityElement? {
            let children = (element.accessibilityChildren() as? [RuneNSAccessibilityElement]) ?? []
            for child in children.reversed() {
                if let hit = hitTestNode(child) {
                    return hit
                }
            }
            if element.accessibilityFrame().contains(screenPoint) {
                return element
            }
            return nil
        }

        _ = parentView
        for root in rootElements.reversed() {
            if let hit = hitTestNode(root) {
                return hit
            }
        }
        return nil
    }

    private static func findFocusedId(in node: AccessibilityNode) -> String? {
        if node.isFocused { return node.id }
        for child in node.children {
            if let found = findFocusedId(in: child) {
                return found
            }
        }
        return nil
    }
}

#endif
