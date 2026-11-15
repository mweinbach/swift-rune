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
            if let parent = info.parentIndex, parent >= 0, parent < elements.count, !elements[parent].inert {
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
            // `a11y/node.rs:236-240`: an enabled field with an editor takes a new value
            // (`editRange` is present exactly when the element has an edit lens).
            if info.editRange != nil && !info.disabled && !info.inert {
                actions.append(.setValue)
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
                isFocusable: !info.disabled && !info.inert && info.focusable,
                isSelected: info.itemSelected,
                isExpanded: info.expanded,
                level: info.level.map { max(0, $0 - 1) },
                isDisabled: info.disabled,
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
    /// Returns the current accessibility tree snapshot built from live runtime nodes.
    func accessibilitySnapshot(securePaths: Set<String> = []) -> AccessibilityNode {
        if flatNodes.isEmpty {
            return AccessibilityTreeBuilder.project(
                elements: elements(),
                focusedPath: focusedPath,
                viewport: viewport,
                securePaths: securePaths
            )
        }

        // Build visible accessibility tree parent/child edges, while preserving full `flatNodes`
        // for `labelledBy` / `describedBy` scoping (`a11y/node.rs:260-282`).
        var childrenByParent: [Int: [Int]] = [:]
        var allChildrenByParent: [Int: [Int]] = [:]
        var roots: [Int] = []
        for (idx, node) in flatNodes.enumerated() {
            if let pIdx = node.parentIndex, pIdx >= 0, pIdx < flatNodes.count {
                allChildrenByParent[pIdx, default: []].append(idx)
            }
            let isVirtualSpacer = (node.key == "__v_top_spacer" || node.key == "__v_bot_spacer")
            if node.effectiveInert || node.el.isA11yHidden || isVirtualSpacer { continue }
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

        func isInside(ancestor: Int, candidate: Int) -> Bool {
            var cur = flatNodes[candidate].parentIndex
            while let p = cur {
                if p == ancestor { return true }
                cur = flatNodes[p].parentIndex
            }
            return false
        }

        func a11yKeyed(from idx: Int, key: String) -> Int? {
            var scope = flatNodes[idx].parentIndex
            while let s = scope {
                for j in (s + 1)..<flatNodes.count {
                    guard isInside(ancestor: s, candidate: j) else { break }
                    if j != idx, flatNodes[j].key == key {
                        return flatNodes[j].effectiveInert ? nil : j
                    }
                }
                scope = flatNodes[s].parentIndex
            }
            return nil
        }

        func a11yContentWords(_ idx: Int) -> String {
            var parts: [String] = []
            func visit(_ cur: Int) {
                for c in (allChildrenByParent[cur] ?? []) {
                    let cn = flatNodes[c]
                    if cn.el.isA11yHidden || cn.el.opacity <= 0.01 || cn.el.isSecure { continue }
                    if let lbl = cn.el.a11yLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !lbl.isEmpty {
                        parts.append(lbl)
                        continue
                    }
                    if cn.el.handlers.editLens == nil,
                       let txt = (cn.el.plainText ?? cn.el.richSpans?.map(\.text).joined())?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !txt.isEmpty {
                        parts.append(txt)
                    }
                    visit(c)
                }
            }
            visit(idx)
            return parts.joined(separator: " ")
        }

        func a11yWords(_ idx: Int) -> String? {
            let n = flatNodes[idx]
            if n.el.isSecure { return nil }
            if let lbl = n.el.a11yLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !lbl.isEmpty {
                return lbl
            }
            if n.el.handlers.editLens == nil,
               let txt = (n.el.plainText ?? n.el.richSpans?.map(\.text).joined())?.trimmingCharacters(in: .whitespacesAndNewlines),
               !txt.isEmpty {
                return txt
            }
            let content = a11yContentWords(idx)
            return content.isEmpty ? nil : content
        }

        let selectableRoles: Set<ElementRole> = [.listItem, .option, .tab, .treeItem, .gridCell, .row]
        func build(_ idx: Int) -> AccessibilityNode {
            let node = flatNodes[idx]
            let el = node.el
            var editIsSecure = el.isSecure
            let richPlain: String? = el.plainText ?? el.richSpans?.map(\.text).joined()
            var editText: String? = editIsSecure ? nil : richPlain
            var editChars: Int? = nil
            var editSel: [Int]? = nil
            // `RoleCtx::multiline`: a field that is not single-line (`a11y/node.rs:31`).
            let editMultiline = el.isMultilineField
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

            let enabled = !el.a11yDisabled && !node.effectiveInert
            let actions = a11yNodeActions(node)

            let resolvedValue: String? = isSecure ? nil : (el.a11yValue ?? el.a11ySelected ?? editText)
            let labelledByText = el.a11yLabelledBy.flatMap { a11yKeyed(from: idx, key: $0) }.flatMap(a11yWords)
            let describedByText = el.a11yDescribedBy.flatMap { a11yKeyed(from: idx, key: $0) }.flatMap(a11yWords)
            let resolvedLabel: String? = isSecure
                ? (el.a11yLabel ?? labelledByText ?? "Password")
                : (el.a11yLabel ?? labelledByText ?? (el.role == .textInput ? nil : richPlain))
            let resolvedHelp: String? = el.a11yDescription ?? describedByText ?? el.a11yHelp
            let selectedState: Bool? = (selectableRoles.contains(el.role) || el.itemSelected) ? el.itemSelected : nil

            let hasScroll = !el.layout.scrollAxes.isEmpty
            let sOff = hasScroll ? (scrollOffsets[node.path] ?? .zero) : nil
            let sMax = hasScroll ? scrollMaxExtents[node.path] : nil

            let resolvedRole: ElementRole = el.role == .textInput && (isSecure || editMultiline)
                ? AccessibilityTreeBuilder.textFieldRole(secure: isSecure, multiline: editMultiline)
                : el.role
            let hasLinks = hasActiveTextLinks(el)
            var builtChildren = (childrenByParent[idx] ?? []).map(build)
            if let grid = el.terminalGridPayload {
                let projected = AccessibilityTreeBuilder.projectTerminalGrid(grid, nodeId: nodeId, bounds: rect)
                builtChildren.append(contentsOf: projected.children)
                if editSel == nil {
                    editSel = projected.selection
                }
            }
            if hasLinks, let boxes = linkBoxesByPath[node.path], !boxes.isEmpty {
                let parentFocused = (node.path == focusedPath) && !node.el.isA11yHidden
                let activeIdx = focusedLinkIndex ?? 0
                for box in boxes {
                    let linkFocusable = el.focusable && !node.effectiveInert && el.opacity > 0.001 && box.windowUnion.z > 0 && box.windowUnion.w > 0
                    let linkFocused = parentFocused && (activeIdx == box.linkIndex)
                    var linkActions: [AccessibilityAction] = [.press]
                    if linkFocusable {
                        linkActions.append(.focus)
                    }
                    let linkLabel = box.link.label ?? (isSecure ? nil : box.sliceText)
                    builtChildren.append(AccessibilityNode(
                        id: box.link.id,
                        role: box.link.role,
                        label: linkLabel,
                        help: box.link.help.map(runeHelpWords),
                        frame: MotionRect.fromXYWH(box.windowUnion.x, box.windowUnion.y, box.windowUnion.z, box.windowUnion.w),
                        isFocused: linkFocused,
                        isFocusable: linkFocusable,
                        url: box.link.id,
                        actions: linkActions
                    ))
                }
            }

            let resolvedPosInSet: Int? = {
                if let explicit = el.a11yPosInSet?.position { return max(0, explicit - 1) }
                guard let pIdx = node.parentIndex, pIdx >= 0, pIdx < flatNodes.count,
                      let vList = virtualLists[flatNodes[pIdx].path] else { return nil }
                let rowSeg = node.path.split(separator: "/").last.map(String.init) ?? ""
                guard let rowKey = vList.rowKeyBySegment[rowSeg] ?? node.key else { return nil }
                for k in vList.lastMountedRange where k >= 0 && k < vList.lastKeys.count {
                    if vList.lastKeys[k] == rowKey { return k }
                }
                return vList.lastKeys.firstIndex(of: rowKey)
            }()
            let resolvedSizeOfSet: Int? = {
                if let explicit = el.a11yPosInSet?.size { return explicit }
                if let containerSize = virtualLists[node.path]?.lastKeys.count { return containerSize }
                if let pIdx = node.parentIndex, pIdx >= 0, pIdx < flatNodes.count,
                   let parentList = virtualLists[flatNodes[pIdx].path] {
                    return parentList.lastKeys.count
                }
                return nil
            }()

            return AccessibilityNode(
                id: nodeId,
                role: resolvedRole,
                label: resolvedLabel,
                value: resolvedValue,
                help: resolvedHelp,
                placeholder: el.placeholder,
                range: el.a11yRange,
                frame: rect,
                isFocused: !hasLinks && ((node.path == focusedPath) || (focusedKey != nil && node.key == focusedKey)),
                isFocusable: !hasLinks && enabled && el.focusable,
                isSelected: el.itemSelected,
                selectedState: selectedState,
                isExpanded: el.a11yExpanded,
                level: el.a11yLevel.map { max(0, $0 - 1) },
                positionInSet: resolvedPosInSet,
                sizeOfSet: resolvedSizeOfSet,
                keyboardShortcut: el.a11yShortcutHint,
                url: el.a11yHref,
                activeDescendant: el.a11yActiveDescendant,
                sortAscending: el.a11ySorted,
                isDisabled: el.a11yDisabled,
                isReadOnly: el.a11yReadOnly,
                isInvalid: el.a11yInvalid,
                isBusy: el.a11yBusy,
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
                children: builtChildren
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

    /// Returns the accessibility tree serialized as deterministic JSON (`Runtime::a11y_json` / `a11y::dump`).
    func accessibilityJSON(pretty: Bool = false, securePaths: Set<String> = []) -> String {
        AccessibilityDump.jsonString(from: accessibilitySnapshot(securePaths: securePaths), pretty: pretty)
    }

    /// Dispatches an accessibility action by key/path (`Runtime::a11y_action` convenience).
    @discardableResult
    func accessibilityAction(
        _ id: String,
        _ action: AccessibilityAction,
        at now: Double = 0
    ) -> Bool {
        performAccessibilityAction(id, action: action, at: now)
    }

    /// Dispatches an accessibility action onto an element identified by `id` (`key` or `path`).
    @discardableResult
    func performAccessibilityAction(
        _ id: String,
        action: AccessibilityAction,
        at now: Double
    ) -> Bool {
        if action == .setValue {
            // A new value needs the request's data (`ActionData::Value` / `NumericValue`).
            return performAccessibilitySetValue(id, value: nil, at: now)
        }
        // `a11y_action`: only an allowed node that can do what is asked (`actions.rs:38-81`);
        // a disabled control advertises nothing and takes no action.
        let all = elements()
        if let flatIdx = a11yTargetIndex(id) {
            guard a11yAllowed(flatIdx), a11yNodeActions(flatNodes[flatIdx]).contains(action) else {
                return false
            }
        } else {
            // An inline text link is a sub-node of its text, not an element of its own:
            // `(Click, Some(link))` presses it whatever its text offers (`actions.rs:49`).
            guard action == .press || action == .focus,
                  let link = all.first(where: { ($0.key ?? $0.path) == id || $0.path == id }),
                  link.role == .link, !link.inert else {
                return false
            }
        }
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
        case .setValue:
            return false
        case .increment, .decrement:
            guard let flatTarget = flatNodes.first(where: { ($0.key ?? $0.path) == id || $0.path == id }),
                  !flatTarget.effectiveInert,
                  let onStep = flatTarget.el.handlers.onStep else {
                return false
            }
            let delta = (action == .increment) ? 1 : -1
            var tx = makeTx(at: now)
            onStep(&state, delta, &tx)
            applyTx(tx, at: now)
            dirtyCommit(at: now)
            return true
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
        onSetValue: (@Sendable (String, AccessibilityActionValue) -> Void)? = nil,
        onAction: @escaping @Sendable (String, AccessibilityAction) -> Void
    ) {
        let announcements = AccessibilityTreeBuilder.liveAnnouncements(previous: previousTree, current: tree)
        previousTree = tree

        var map: [String: RuneNSAccessibilityElement] = [:]
        func convertNode(_ node: AccessibilityNode, parent: AnyObject) -> RuneNSAccessibilityElement {
            let elem = AppKitAccessibilityMapper.buildElement(from: node, onAction: onAction, onSetValue: onSetValue)
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
