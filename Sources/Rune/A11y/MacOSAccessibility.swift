import Foundation

#if os(macOS) && canImport(AppKit)
import AppKit
#endif

// MARK: - Cross-Platform Runtime Accessibility Projection & Action Dispatch

/// Physical parentage remains available for geometry and labelled-by references. During
/// projection a presentational container passes its descendants to the semantic parent,
/// while skipping a hidden container discards its entire subtree.
private struct AccessibilityTreeEdges {
    enum Projection {
        case node(ElementRole)
        case descendants(scrolls: Bool)
        case hidden
    }

    var roots: [Int] = []
    var children: [[Int]]

    init(count: Int, parent: (Int) -> Int?) {
        children = Array(repeating: [], count: count)
        for index in 0..<count {
            if let p = parent(index), p != index, (0..<count).contains(p) {
                children[p].append(index)
            } else {
                roots.append(index)
            }
        }
    }

    static func hasAncestorOrSelf(_ index: Int, count: Int, parent: (Int) -> Int?, matching: (Int) -> Bool) -> Bool {
        var i: Int? = index
        for _ in 0..<count {
            guard let j = i, (0..<count).contains(j) else { break }
            if matching(j) { return true }
            i = parent(j)
        }
        return false
    }

    func project(_ indices: [Int], insideScroll: Bool, projection: (Int) -> Projection,
                 build: (Int, Bool, ElementRole) -> AccessibilityNode) -> [AccessibilityNode] {
        var nodes: [AccessibilityNode] = []
        nodes.reserveCapacity(indices.count)
        func append(_ indices: [Int], insideScroll: Bool) {
            for i in indices {
                switch projection(i) {
                case let .node(role): nodes.append(build(i, insideScroll, role))
                case let .descendants(scrolls): append(children[i], insideScroll: insideScroll || scrolls)
                case .hidden: continue
                }
            }
        }
        append(indices, insideScroll: insideScroll)
        return nodes
    }
}

public extension AccessibilityTreeBuilder {
    /// Projects a flattened `[ElementInfo]` array from `Runtime.elements()` into a nested `AccessibilityNode` tree.
    /// Secure text fields (`securePaths.contains(path)` or `role == .textInput && text == nil`) never leak `value`.
    static func project(
        elements: [ElementInfo],
        focusedPath: String?,
        viewport: Vec2,
        securePaths: Set<String> = []
    ) -> AccessibilityNode {
        let edges = AccessibilityTreeEdges(count: elements.count) { elements[$0].parentIndex }
        func projection(_ i: Int) -> AccessibilityTreeEdges.Projection {
            let info = elements[i]
            if info.a11yHidden || info.exiting || info.opacity <= 0.01 { return .hidden }
            if info.a11yInput?.modalMember == false && !info.modalAncestor { return .hidden }
            let input = info.a11yInput
            let takesFocus = info.focusable && !info.disabled
            let keyboardTarget = takesFocus && !info.inert &&
                (info.role != .presentation || input?.explicitFocus == true)
            let role = AccessibilityRoleRules.projectedRole(info.role, keyed: info.key != nil,
                labelled: AccessibilityNameSource.nonblank(info.label) != nil, pressable: input?.rolePressable == true,
                takesFocus: takesFocus, keyboardTarget: keyboardTarget, input: input?.isInput == true,
                modal: input?.isModal == true, scrolls: input?.scrolls == true,
                hasText: AccessibilityNameSource.nonblank(info.text) != nil, hasImage: input?.hasImage == true,
                terminal: input?.hasTerminalGrid == true)
            guard let role else { return .descendants(scrolls: input?.scrolls == true) }
            return .node(role)
        }

        func words(_ index: Int) -> String? {
            AccessibilityNameSource.words(of: index, source: { AccessibilityNameSource(elements[$0], securePaths: securePaths) },
                                           children: { edges.children[$0] })
        }

        func build(_ idx: Int, insideScroll: Bool, semanticRole: ElementRole) -> AccessibilityNode {
            let info = elements[idx]
            let isSecure = info.secure || securePaths.contains(info.path) || (info.role == .textInput && info.text == nil)
            // As the live tree's `a11yNodeActions` (`a11y/node.rs:222-240`, under `actionable`).
            let input = info.a11yInput
            let outsideModal = input?.modalMember == false
            let inert = outsideModal
                ? AccessibilityTreeEdges.hasAncestorOrSelf(idx, count: elements.count, parent: { elements[$0].parentIndex }, matching: { elements[$0].a11yInput?.explicitInert == true })
                : info.inert
            let enabled = !info.disabled && !inert && !outsideModal
            var actions: [AccessibilityAction] = []
            if enabled {
                if [.button, .checkbox, .switchControl, .radio, .tab, .menuItem, .menuItemCheckbox, .menuItemRadio].contains(info.role) ||
                    input?.pressable == true || input?.isInput == true {
                    actions.append(.press)
                }
                if info.focusable {
                    actions.append(.focus)
                }
                if let disclosure = AccessibilityAction.disclosure(expanded: info.expanded, pressable: input?.pressable == true) {
                    actions.append(disclosure)
                }
                if info.role == .slider || input?.steps == true {
                    actions.append(.increment)
                    actions.append(.decrement)
                }
            }
            if AccessibilityTreeBuilder.offersSetValue(
                enabled: enabled,
                editable: input?.editable ?? false,
                steps: input?.steps ?? false,
                range: input?.range
            ) {
                AccessibilityTreeBuilder.appendAction(.setValue, to: &actions)
            }

            if insideScroll { actions.append(.scrollIntoView) }
            let rect = MotionRect.fromXYWH(info.rect)

            let projectedValue: String? = isSecure ? nil : info.text
            func relatedWords(_ key: String?) -> String? {
                guard let key else { return nil }
                return AccessibilityNameSource.relatedIndex(key, from: idx, parent: { elements[$0].parentIndex },
                    children: { edges.children[$0] }, keyAt: { elements[$0].key }).flatMap(words)
            }
            let givenName = AccessibilityNameSource.nonblank(info.label) ?? relatedWords(input?.labelledBy)
            let role = semanticRole
            let controlName = AccessibilityRoleRules.controlName(
                given: givenName, role: role, isDefaultButton: input?.isDefaultButton == true, secure: isSecure,
                words: words(idx)
            )
            // Element keys identify targets. A keyed, unnamed part inside a button does
            // not contribute words; older flat records carry only their fallback key.
            let fallback = input == nil ? info.key : (info.role == .text ? info.text : nil)
            let projectedLabel = controlName ?? (isSecure ? "Password" : fallback)
            let nodeId = info.key ?? info.path

            var projected = AccessibilityNode(
                id: nodeId,
                role: input?.isInput == true || (info.role == .textInput && (isSecure || input?.multiline == true))
                    ? AccessibilityTreeBuilder.textFieldRole(secure: isSecure, multiline: input?.multiline == true)
                    : role,
                label: projectedLabel,
                value: projectedValue,
                help: input?.description ?? relatedWords(input?.describedBy) ?? info.help,
                frame: rect,
                isFocused: enabled && (focusedPath.map { info.path == $0 } ?? info.focused),
                isFocusable: enabled && info.focusable,
                isSelected: info.itemSelected,
                isExpanded: info.expanded,
                level: info.level.map { max(0, $0 - 1) },
                positionInSet: input?.positionInSet,
                sizeOfSet: input?.sizeOfSet,
                isDisabled: info.disabled || inert,
                isModal: input?.isModal == true,
                isSecure: isSecure,
                actions: actions,
                children: controlChildren(edges.project(edges.children[idx], insideScroll: insideScroll || input?.scrolls == true, projection: projection, build: build),
                                          role: role, name: isSecure ? nil : controlName)
            )
            projected.runtimePath = info.path
            projected.keepsControlContent = input?.keepsControlContent == true
            return projected
        }

        let builtRoots = edges.project(edges.roots, insideScroll: false, projection: projection, build: build)
        if builtRoots.count == 1 {
            let root = builtRoots[0]
            let implicitWindow = edges.roots.count == 1 && edges.roots.first.map {
                elements[$0].role == .group && elements[$0].path != root.runtimePath
            } == true
            if !implicitWindow { return root }
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
        var prevMap: [AccessibilityIdentity: AccessibilityNode] = [:]
        if let previous {
            AccessibilityIdentity.walk(previous) { node, id in prevMap[id] = node }
        }

        var announcements: [AccessibilityAnnouncement] = []
        AccessibilityIdentity.walk(current) { node, id in
            let modal = node.role == .dialog || node.role == .alertDialog || node.isModal
            guard !node.isSecure, modal || node.liveRegion != nil else { return }
            let words = [node.label, node.value].compactMap { $0 }.joined(separator: " ")
            guard !words.isEmpty else { return }
            let prev = prevMap[id]
            let prevWords = prev.map { [$0.label, $0.value].compactMap { $0 }.joined(separator: " ") }
            if modal {
                if words != prevWords {
                    announcements.append(AccessibilityAnnouncement(text: words, politeness: .assertive))
                }
            } else if let live = node.liveRegion, words != prevWords || prev?.liveRegion != live {
                announcements.append(AccessibilityAnnouncement(text: words, politeness: live))
            }
        }
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

        let edges = AccessibilityTreeEdges(count: flatNodes.count) { flatNodes[$0].parentIndex }
        func projection(_ i: Int) -> AccessibilityTreeEdges.Projection {
            let node = flatNodes[i]
            let el = node.el
            if el.isA11yHidden || el.opacity <= 0.01 || scene.isExiting(node.nodeId) ||
                node.key == "__v_top_spacer" || node.key == "__v_bot_spacer" { return .hidden }
            if activeModalPath != nil && !modalMemberPaths.contains(node.path) && !modalAncestorPaths.contains(node.path) { return .hidden }
            let takesFocus = nodeTakesFocus(el)
            let keyboardTarget = takesFocus && !node.effectiveInert && (el.role != .presentation || el.explicitlyFocusable)
            guard let role = AccessibilityRoleRules.projectedRole(for: el, takesFocus: takesFocus, keyboardTarget: keyboardTarget)
            else { return .descendants(scrolls: !el.layout.scrollAxes.isEmpty) }
            return .node(role)
        }

        func a11yKeyed(from idx: Int, key: String) -> Int? {
            let match = AccessibilityNameSource.relatedIndex(key, from: idx, parent: { flatNodes[$0].parentIndex },
                                                             children: { edges.children[$0] }, keyAt: { flatNodes[$0].key })
            guard let match, !AccessibilityTreeEdges.hasAncestorOrSelf(match, count: flatNodes.count,
                parent: { flatNodes[$0].parentIndex }, matching: { scene.isExiting(flatNodes[$0].nodeId) }) else { return nil }
            return match
        }

        func a11yWords(_ idx: Int) -> String? {
            AccessibilityNameSource.words(of: idx, source: { index in
                AccessibilityNameSource(flatNodes[index].el, securePath: securePaths.contains(flatNodes[index].path))
            }, children: { edges.children[$0] })
        }

        let selectableRoles: Set<ElementRole> = [.listItem, .option, .tab, .treeItem, .gridCell, .row]
        func build(_ idx: Int, insideScroll: Bool, semanticRole: ElementRole) -> AccessibilityNode {
            let node = flatNodes[idx]
            let el = node.el
            var editIsSecure = el.isSecure
            let richPlain: String? = el.plainText ?? el.richSpans?.map(\.text).joined()
            var editText: String? = editIsSecure ? nil : richPlain
            var editChars: Int? = nil
            var editSel: [Int]? = nil
            // `RoleCtx::multiline`: a field that is not single-line (`a11y/node.rs:31`).
            let editLens = el.hasEditLens ? el.handlers.editLens : nil
            var editMultiline = false
            if let editLens {
                let edit = editLens.get(state)
                editMultiline = edit.multiline
                editIsSecure = editIsSecure || edit.isSecure
                if !editIsSecure {
                    editText = edit.text
                    editChars = edit.text.count
                    editSel = [0, edit.anchor, 0, edit.cursor]
                } else {
                    editText = nil
                }
            }
            let isSecure = editIsSecure || securePaths.contains(node.path) || (el.role == .textInput && editText == nil)
            let rect = presentedRectByPath[node.path] ?? node.targetRect
            let nodeId = node.key ?? node.path

            let outsideModal = activeModalPath != nil && !modalMemberPaths.contains(node.path)
            let inert = outsideModal
                ? AccessibilityTreeEdges.hasAncestorOrSelf(idx, count: flatNodes.count, parent: { flatNodes[$0].parentIndex }, matching: { flatNodes[$0].el.isInert })
                : node.effectiveInert
            let enabled = !el.a11yDisabled && !node.effectiveInert
            var actions = a11yNodeActions(node)
            if insideScroll { actions.append(.scrollIntoView) }

            // Field selection indices refer to the editor's model, including when the element
            // also has a general-purpose value override.
            let value = editLens != nil ? editText : (el.a11yValue ?? el.a11ySelected ?? editText)
            let resolvedValue = isSecure ? nil : value
            let labelledByText = el.a11yLabelledBy.flatMap { a11yKeyed(from: idx, key: $0) }.flatMap(a11yWords)
            let describedByText = el.a11yDescribedBy.flatMap { a11yKeyed(from: idx, key: $0) }.flatMap(a11yWords)
            let resolvedHelp: String? = el.a11yDescription ?? describedByText ?? el.a11yHelp
            let selectedState: Bool? = (selectableRoles.contains(el.role) || el.itemSelected) ? el.itemSelected : nil

            let hasScroll = !el.layout.scrollAxes.isEmpty
            let sOff = hasScroll ? (scrollOffsets[node.path] ?? .zero) : nil
            let sMax = hasScroll ? scrollMaxExtents[node.path] : nil

            let resolvedRole: ElementRole = editLens != nil || (el.role == .textInput && (isSecure || editMultiline))
                ? AccessibilityTreeBuilder.textFieldRole(secure: isSecure, multiline: editMultiline)
                : semanticRole
            let givenName = AccessibilityNameSource.nonblank(el.a11yLabel) ?? labelledByText
            let controlName = AccessibilityRoleRules.controlName(
                given: givenName, role: resolvedRole, isDefaultButton: el.isDefaultButton, secure: isSecure,
                words: a11yWords(idx)
            )
            let resolvedLabel = controlName ?? (isSecure ? "Password" : (el.role == .textInput ? nil : richPlain))
            let hasLinks = hasActiveTextLinks(el)
            var builtChildren = edges.project(edges.children[idx], insideScroll: insideScroll || hasScroll, projection: projection, build: build)
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
                    let linkFocusable = enabled && el.focusable && el.opacity > 0.001 && box.windowUnion.z > 0 && box.windowUnion.w > 0
                    let linkFocused = parentFocused && (activeIdx == box.linkIndex)
                    var linkActions: [AccessibilityAction] = enabled ? [.press] : []
                    if linkFocusable {
                        linkActions.append(.focus)
                    }
                    let linkLabel = box.link.label ?? (isSecure ? nil : box.sliceText)
                    var link = AccessibilityNode(
                        id: box.link.id,
                        role: box.link.role,
                        label: linkLabel,
                        help: box.link.help.map(runeHelpWords),
                        frame: MotionRect.fromXYWH(box.windowUnion.x, box.windowUnion.y, box.windowUnion.z, box.windowUnion.w),
                        isFocused: linkFocused,
                        isFocusable: linkFocusable,
                        url: box.link.id,
                        isDisabled: !enabled,
                        actions: linkActions
                    )
                    link.runtimePath = "\(node.path)#link-\(box.linkIndex)"
                    builtChildren.append(link)
                }
            }

            let resolvedPosInSet: Int? = {
                if let explicit = el.a11yPosInSet?.position { return max(1, explicit) - 1 }
                guard let pIdx = node.parentIndex, pIdx >= 0, pIdx < flatNodes.count,
                      let vList = virtualLists[flatNodes[pIdx].path] else { return nil }
                let rowSeg = node.path.split(separator: "/").last.map(String.init) ?? ""
                if let rowKey = vList.rowKeyBySegment[rowSeg] { return vList.rowPlaces.index(of: rowKey) }
                return node.key.flatMap { vList.rowPlaces.index(ofAuthoredKey: $0) }
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

            var projected = AccessibilityNode(
                id: nodeId,
                role: resolvedRole,
                label: resolvedLabel,
                value: resolvedValue,
                help: resolvedHelp,
                placeholder: el.placeholder,
                range: el.a11yRange,
                frame: rect,
                isFocused: !hasLinks && node.path == focusedPath,
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
                isDisabled: el.a11yDisabled || inert,
                isReadOnly: el.a11yReadOnly,
                isInvalid: el.a11yInvalid,
                isBusy: el.a11yBusy,
                toggled: el.a11yChecked,
                liveRegion: el.a11yLive,
                clipsChildren: el.layout.clipOverflow,
                scrollX: sOff?.x,
                scrollY: sOff?.y,
                scrollYMax: sMax?.y,
                textSelection: isSecure ? nil : editSel,
                characterCount: isSecure ? nil : editChars,
                isModal: el.isModal,
                isSecure: isSecure,
                actions: actions,
                children: AccessibilityTreeBuilder.controlChildren(builtChildren, role: resolvedRole, name: isSecure ? nil : controlName)
            )
            #if os(macOS) && canImport(AppKit)
            if !isSecure, editLens != nil, let value = resolvedValue,
               let box = nodeTextLayouts[node.nodeId]?.box {
                let scale = presentedScaleByPath[node.path] ?? Vec2(1, 1)
                let scroll = inputScroll[node.path] ?? 0
                let origin = Vec2(rect.x + (el.layout.padding.left - scroll) * scale.x,
                                  rect.y + el.layout.padding.top * scale.y)
                projected.fieldLayout = A11yFieldLayout(text: value, box: box, system: textSystem,
                                                        origin: origin, scale: scale)
            }
            #endif
            projected.runtimePath = node.path
            projected.keepsControlContent = el.keepsControlContent
            return projected
        }

        let builtRoots = edges.project(edges.roots, insideScroll: false, projection: projection, build: build)
        if builtRoots.count == 1 {
            let root = builtRoots[0]
            let implicitWindow = edges.roots.count == 1 && edges.roots.first.map {
                flatNodes[$0].el.role == .group && flatNodes[$0].path != root.runtimePath
            } == true
            if !implicitWindow { return root }
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
        if action == .scrollIntoView {
            guard let index = a11yTargetIndex(id), a11yAllowed(index) else { return false }
            var tx = makeTx(at: now)
            tx.scrollIntoView(flatNodes[index].path)
            applyTx(tx, at: now)
            dirtyCommit(at: now, why: CommitWhy.input)
            return true
        }
        if action == .setValue {
            // A new value needs the request's data (`ActionData::Value` / `NumericValue`).
            return performAccessibilitySetValue(id, value: nil, at: now)
        }
        // `a11y_action`: only an allowed node that can do what is asked (`actions.rs:38-81`);
        // a disabled control advertises nothing and takes no action.
        let flatIdx = a11yTargetIndex(id)
        if let flatIdx {
            let flat = flatNodes[flatIdx]
            guard a11yAllowed(flatIdx), a11yTakes(action, on: flat) else {
                return false
            }
            // `(Click, None) if input => A11yAct::Focus(None)` → `set_focus(path, true)`.
            if action == .focus || (action == .press && !a11yPressable(flat.el) && flat.el.handlers.editLens != nil) {
                guard !flat.el.a11yDisabled else { return false }
                setFocus(path: flat.path, keyboard: true, at: now)
                focusedLinkIndex = nil
                dirtyCommit(at: now)
                return true
            }
            if action == .press || action == .expand || action == .collapse {
                // Assistive clients address the node directly, including when it is clipped or covered.
                let rect = presentedRectByPath[flat.path] ?? flat.targetRect
                let center = Vec2(rect.width * 0.5, rect.height * 0.5)
                let press = PointerPress(window: Vec2(rect.x + center.x, rect.y + center.y), local: center,
                                         elementSize: Vec2(rect.width, rect.height), button: .primary, mods: .none, clicks: 1)
                return dispatchPointerClick(flat, press: press, at: now) != nil
            }
        } else {
            // Inline links share their text owner's focus path but receive actions by link index.
            let all = elements()
            let target = all.first(where: { $0.path == id }) ?? all.first(where: { matchesAuthoredKey($0.key, id) })
            guard let target, !target.inert, let parent = target.parentIndex, all.indices.contains(parent),
                  let owner = a11yTargetIndex(all[parent].path), a11yAllowed(owner), !flatNodes[owner].el.a11yDisabled,
                  let box = linkBoxesByPath[all[parent].path]?.first(where: {
                      target.path == "\(all[parent].path)#link-\($0.linkIndex)"
                  }) else { return false }
            let text = flatNodes[owner]
            switch action {
            case .focus where target.focusable:
                setFocus(path: text.path, keyboard: true, at: now)
                focusedLinkIndex = box.linkIndex
                focusedKey = box.link.id
                dirtyCommit(at: now)
            case .press:
                guard let onLink = text.el.handlers.onLink else { return false }
                var tx = makeTx(at: now)
                onLink(&state, box.link.id, &tx)
                applyTx(tx, at: now)
                dirtyCommit(at: now, why: CommitWhy.input)
            default:
                return false
            }
            return true
        }
        switch action {
        case .focus, .press, .expand, .collapse, .setValue, .scrollIntoView:
            return false
        case .increment, .decrement:
            guard let flatIdx, let onStep = flatNodes[flatIdx].el.handlers.onStep else {
                return false
            }
            let delta = (action == .increment) ? 1 : -1
            var tx = makeTx(at: now)
            onStep(&state, delta, &tx)
            applyTx(tx, at: now)
            dirtyCommit(at: now, why: CommitWhy.input)
            return true
        }
    }
}

#if os(macOS) && canImport(AppKit)

/// Bridges `AccessibilityNode` trees and live-region announcements onto an AppKit `NSView` for VoiceOver.
@MainActor
public final class MacOSAccessibilityHost {
    private var previousTree: AccessibilityNode?
    private var lastFocusedId: AccessibilityIdentity?
    private var rootElements: [RuneNSAccessibilityElement] = []
    private var elementById: [AccessibilityIdentity: RuneNSAccessibilityElement] = [:]
    /// The workspace's display options observer (`a11y/macos.rs` `Adapter(_, DisplayOptions)`),
    /// removed with the adapter.
    private var displayOptions: MacOSDisplayOptionsWatcher?
    /// The tree this adapter last sent (`A11yTree`): whole on its first update and again when an
    /// assistive client first asks for it, and whether that whole tree held the announcer's words.
    private let treeState = AccessibilityTreeState()
    /// `Tx::announce`'s live region as the reader was last told it (nil: no words).
    private var announcerLabel: String?
    private var announcerElement: RuneNSAccessibilityElement?
    /// An assistive client has asked for this view's tree (AccessKit's activation).
    public private(set) var isActivated = false
    /// Called synchronously on the first reader query so a native host can supply its current tree.
    public var onActivate: (@MainActor () -> Void)?
    /// What the last update asked VoiceOver to say (`announcementRequested`), in order.
    public private(set) var lastSpoken: [(text: String, politeness: LiveRegionPoliteness)] = []
    /// How many times the announcer had been told to speak at the last update (the `Stamp`'s
    /// `announced: self.announcement.said()`, `a11y/tree.rs`).
    public private(set) var sentAnnouncementCount: UInt32 = 0

    /// `Tx::announce` was called since the last update: the stamp changed, so the tree goes out
    /// although the view did not re-commit (a `Tx::live_only()` handler's words, #980).
    public func announcementChanged(_ announcement: AccessibilityAnnouncement) -> Bool {
        announcement.count != sentAnnouncementCount
    }

    public init() {}

    /// Watches `NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification` for as long as
    /// this adapter lives, calling `onChange` on the main thread (#980).
    public func watchDisplayOptions(_ onChange: @escaping @MainActor () -> Void) {
        displayOptions = MacOSDisplayOptionsWatcher(onChange: onChange)
    }

    public var watchesDisplayOptions: Bool { displayOptions?.isWatching ?? false }

    /// Rebuilds cached `NSAccessibilityElement` wrappers for `tree` and emits focus / VoiceOver announcements.
    ///
    /// `announcement`: `Tx::announce`'s window live region (`Runtime.a11yAnnouncement`), the
    /// root's announcer (`a11y/tree.rs` `ANNOUNCER`). A whole tree raises no events, as AccessKit
    /// diffs against the tree it starts from; words said in the last 1.5 s go out without them in
    /// that tree and as a change in the next update, so a reader that just attached hears them
    /// (#980). Returns `true` while words are held: the host keeps the runtime dirty and updates
    /// again (`a11y_update`'s `self.dirty = true`).
    @discardableResult
    public func update(
        tree: AccessibilityNode,
        announcement: AccessibilityAnnouncement? = nil,
        now: Double = AccessibilityAnnouncement.clock(),
        parentView: NSView,
        onSelectText: (@Sendable (String, Range<Int>) -> Void)? = nil,
        onSetValue: (@Sendable (String, AccessibilityActionValue) -> Void)? = nil,
        onAction: @escaping @Sendable (String, AccessibilityAction) -> Void
    ) -> Bool {
        // A reader that just attached starts from this tree; existing live regions are its baseline.
        var spoken: [(text: String, politeness: LiveRegionPoliteness)] = []
        if previousTree != nil || !isActivated {
            spoken = AccessibilityTreeBuilder.liveAnnouncements(previous: previousTree, current: tree)
                .compactMap { a in a.spokenText.map { ($0, a.politeness) } }
        }
        previousTree = tree
        var announcer: AccessibilityNode? = nil
        if let announcement {
            sentAnnouncementCount = announcement.count
            let full = treeState.diff(root: tree, windowTitle: "", announcement: announcement, now: now)?.isFullTree ?? false
            let node = AccessibilityTreeState.announcerNode(announcement, holdWords: treeState.held)
            // Its words are a change a reader announces; a whole tree's are not.
            if !full, let label = node.label, label != announcerLabel {
                spoken.append((label, node.liveRegion ?? .polite))
            }
            announcerLabel = node.label
            announcer = node
        }
        lastSpoken = spoken

        var map: [AccessibilityIdentity: RuneNSAccessibilityElement] = [:]
        var focusedNodeId: AccessibilityIdentity?
        var changedSelections: [RuneAXTextField] = []
        lazy var viewToScreen = RuneAXTextField.viewToScreen(parentView)
        func convertChildren(_ children: [AccessibilityNode], parent: AnyObject, scope: AccessibilityIdentity?) -> [RuneNSAccessibilityElement] {
            var occurrences: [String: Int] = [:]
            return children.map { node in
                let id = AccessibilityIdentity(node, parent: scope, occurrences: &occurrences)
                return convertNode(node, parent: parent, id: id)
            }
        }
        func convertNode(_ node: AccessibilityNode, parent: AnyObject, id: AccessibilityIdentity) -> RuneNSAccessibilityElement {
            if node.isFocused && focusedNodeId == nil { focusedNodeId = id }
            let old = elementById[id]
            let previous = (old as? RuneAXTextField)?.snapshot
            let elem = AppKitAccessibilityMapper.makeElement(node, parent: parent, onAction: onAction,
                                                            onSelectText: onSelectText, onSetValue: onSetValue,
                                                            reusing: old, viewToScreen: viewToScreen)
            if let previous, let field = old as? RuneAXTextField, elem === field {
                let current = field.snapshot
                if previous.anchor != current.anchor || previous.focus != current.focus {
                    changedSelections.append(field)
                }
            }

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

            elem.setAccessibilityChildren(convertChildren(node.children, parent: elem, scope: id))
            map[id] = elem
            return elem
        }

        let windowGroup = tree.id == "root" && tree.role == .group && tree.label == nil &&
            !tree.isFocusable && !tree.isFocused && !tree.isDisabled && tree.actions.isEmpty
        let roots = windowGroup ? tree.children : [tree]
        rootElements = convertChildren(roots, parent: parentView, scope: nil)
        // The window's own live region, which draws nothing: the root's last child.
        announcerElement = announcer.map { convertNode($0, parent: parentView, id: .scoped(parent: nil, id: $0.id, occurrence: 0)) }
        if let announcerElement { rootElements.append(announcerElement) }
        for (id, element) in elementById where map[id] !== element {
            element.invalidate()
        }
        elementById = map
        for field in changedSelections {
            NSAccessibility.post(element: field, notification: .selectedTextChanged)
        }

        if focusedNodeId != lastFocusedId {
            lastFocusedId = focusedNodeId
            if let fid = focusedNodeId, let focusedElem = map[fid] {
                NSAccessibility.post(element: focusedElem, notification: .focusedUIElementChanged)
            } else {
                NSAccessibility.post(element: parentView, notification: .focusedUIElementChanged)
            }
        }

        for (words, politeness) in spoken {
            let priority: NSAccessibilityPriorityLevel = politeness == .assertive ? .high : .medium
            NSAccessibility.post(
                element: parentView,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: words,
                    .priority: priority.rawValue,
                ]
            )
        }
        return treeState.held
    }

    /// An assistive client asked for the tree. The first time (AccessKit's activation), the next
    /// update holds the whole tree that client starts from.
    public func activate() {
        guard !isActivated else { return }
        isActivated = true
        if previousTree != nil { treeState.forceFullUpdate() }
        onActivate?()
    }

    public func accessibilityChildren() -> [Any] {
        activate()
        return rootElements
    }

    public func accessibilityFocusedUIElement() -> Any? {
        activate()
        if let fid = lastFocusedId {
            return elementById[fid]
        }
        return nil
    }

    public func accessibilityHitTest(_ screenPoint: NSPoint, in parentView: NSView) -> Any? {
        activate()
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
}

#endif
