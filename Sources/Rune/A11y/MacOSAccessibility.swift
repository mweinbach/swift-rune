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

// The arrays are allocated on the first accessibility read. A mutation of the authored
// tree invalidates every entry except descendants certified by the last applied memo pass.
final class AccessibilityProjectionCache {
    fileprivate final class Template {
        var node: AccessibilityNode
        var snapshot: UInt64
        let controlName: String?
        let insideScroll: Bool

        init(node: AccessibilityNode, controlName: String?, insideScroll: Bool, snapshot: UInt64) {
            self.node = node
            self.snapshot = snapshot
            self.controlName = controlName
            self.insideScroll = insideScroll
        }
    }

    fileprivate struct VirtualIndex {
        let places: VirtualRowPlaces<String>
        let mounted: Range<Int>

        init(_ list: RuntimeVirtualListState) {
            places = list.rowPlaces
            mounted = list.lastMountedRange
        }

        func position(path: String, key: String?) -> Int? {
            var end = path.endIndex
            while end > path.startIndex {
                let previous = path.index(before: end)
                guard path[previous] == "/" else { break }
                end = previous
            }
            let prefix = path[..<end]
            let start = prefix.lastIndex(of: "/").map { prefix.index(after: $0) } ?? prefix.startIndex
            let segment = prefix[start...]
            if segment.first == "@", let i = places.index(of: String(segment.dropFirst())), mounted.contains(i) { return i }
            return key.flatMap { places.index(ofAuthoredKey: $0) }
        }
    }

    fileprivate struct Slot {
        var projection: AccessibilityTreeEdges.Projection?
        var inert = false
        var template: Template?
    }

    fileprivate var slots: [Slot] = []
    fileprivate var snapshot: UInt64 = 0
    private var edges: AccessibilityTreeEdges?
    private var previousWebFocus: Bool?
    private var pending: [(current: Range<Int>, previous: Range<Int>)]?

    func committed(reusing ranges: [(current: Range<Int>, previous: Range<Int>)]) {
        // Multiple commits may occur between accessibility reads, including memo settles.
        if pending != nil || ranges.isEmpty { slots = [] }
        pending = ranges
        edges = nil
    }

    fileprivate func prepare(count: Int, webFocus: Bool, parent: (Int) -> Int?) -> AccessibilityTreeEdges {
        if pending != nil || slots.count != count || previousWebFocus != webFocus {
            var next = [Slot](repeating: Slot(), count: count)
            if let pending, previousWebFocus == webFocus, !slots.isEmpty {
                for span in pending {
                    next.replaceSubrange(span.current, with: slots[span.previous])
                }
            }
            slots = next
            pending = nil
            previousWebFocus = webFocus
        }
        if let edges { return edges }
        let built = AccessibilityTreeEdges(count: count, parent: parent)
        edges = built
        return built
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
            if let announcement = liveAnnouncement(previous: prevMap[id], current: node) { announcements.append(announcement) }
        }
        return announcements
    }

    internal static func liveAnnouncement(previous: AccessibilityNode?, current: AccessibilityNode) -> AccessibilityAnnouncement? {
        let modal = current.role == .dialog || current.role == .alertDialog || current.isModal
        guard !current.isSecure, modal || current.liveRegion != nil else { return nil }
        let words = [current.label, current.value].compactMap { $0 }.joined(separator: " ")
        guard !words.isEmpty else { return nil }
        let previousWords = previous.map { [$0.label, $0.value].compactMap { $0 }.joined(separator: " ") }
        if modal { return words == previousWords ? nil : AccessibilityAnnouncement(text: words, politeness: .assertive) }
        guard let live = current.liveRegion, words != previousWords || previous?.liveRegion != live else { return nil }
        return AccessibilityAnnouncement(text: words, politeness: live)
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

        let storage = accessibilityProjectionCache ?? AccessibilityProjectionCache()
        accessibilityProjectionCache = storage
        let edges = storage.prepare(count: flatNodes.count, webFocus: cxSettings.viewDefaults.webFocus) { flatNodes[$0].parentIndex }
        // A caller can request a different secure or modal projection without applying a layout.
        let reuseSemantic = securePaths.isEmpty && activeModalPath == nil
        let previousSnapshot = storage.snapshot
        storage.snapshot &+= 1
        let currentSnapshot = storage.snapshot
        var changes = 0
        var virtualAt: [Int: AccessibilityProjectionCache.VirtualIndex] = [:]
        if nodeByPath.count == flatNodes.count {
            for (path, list) in virtualLists {
                if let i = nodeByPath[path] { virtualAt[i] = .init(list) }
            }
        } else if !virtualLists.isEmpty {
            // Distinct authored byte paths may compare equal as a Swift String.
            for i in flatNodes.indices {
                if let list = virtualLists[flatNodes[i].path] { virtualAt[i] = .init(list) }
            }
        }
        func projection(_ i: Int) -> AccessibilityTreeEdges.Projection {
            let node = flatNodes[i]
            if scene.isExiting(node.nodeId) {
                changes += 1
                return .hidden
            }
            if activeModalPath != nil && !modalMemberPaths.contains(node.path) && !modalAncestorPaths.contains(node.path) { return .hidden }
            if reuseSemantic, storage.slots[i].inert == node.effectiveInert, let cached = storage.slots[i].projection {
                return cached
            }
            let el = node.el
            let result: AccessibilityTreeEdges.Projection
            if el.isA11yHidden || el.opacity <= 0.01 || node.key == "__v_top_spacer" || node.key == "__v_bot_spacer" {
                result = .hidden
            } else {
                let takesFocus = nodeTakesFocus(el)
                let keyboardTarget = takesFocus && !node.effectiveInert && (el.role != .presentation || el.explicitlyFocusable)
                if let role = AccessibilityRoleRules.projectedRole(for: el, takesFocus: takesFocus, keyboardTarget: keyboardTarget) {
                    result = .node(role)
                } else {
                    result = .descendants(scrolls: !el.layout.scrollAxes.isEmpty)
                }
            }
            changes += 1
            // LiveText updates the flat element in place and can add or remove an implicit text role.
            if reuseSemantic, el.liveText == nil {
                storage.slots[i] = .init(projection: result, inert: node.effectiveInert)
            }
            return result
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
            let rect = presentedRectByPath[node.path] ?? node.targetRect
            let virtualOwner = virtualAt[idx]
            let parentList = node.parentIndex.flatMap { virtualAt[$0] }
            if reuseSemantic, virtualOwner == nil, parentList == nil,
               let cached = storage.slots[idx].template, cached.insideScroll == insideScroll {
                let wasPublished = cached.snapshot == previousSnapshot
                let childRevision = changes
                if !edges.children[idx].isEmpty {
                    let children = edges.project(edges.children[idx], insideScroll: insideScroll, projection: projection, build: build)
                    if !wasPublished || changes != childRevision {
                        cached.node.children = AccessibilityTreeBuilder.controlChildren(children, role: cached.node.role, name: cached.controlName)
                    }
                }
                let focused = node.path == focusedPath
                if !wasPublished || changes != childRevision || cached.node.frame != rect || cached.node.isFocused != focused {
                    cached.node.frame = rect
                    cached.node.isFocused = focused
                    changes += 1
                }
                cached.snapshot = currentSnapshot
                return cached.node
            }
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
                return parentList?.position(path: node.path, key: node.key)
            }()
            let resolvedSizeOfSet: Int? = {
                if let explicit = el.a11yPosInSet?.size { return explicit }
                return virtualOwner?.places.keys.count ?? parentList?.places.keys.count
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
                let scale = presentedScales[node.path] ?? Vec2(1, 1)
                let scroll = inputScroll[node.path] ?? 0
                let origin = Vec2(rect.x + (el.layout.padding.left - scroll) * scale.x,
                                  rect.y + el.layout.padding.top * scale.y)
                projected.fieldLayout = A11yFieldLayout(text: value, box: box, system: textSystem,
                                                        origin: origin, scale: scale)
            }
            #endif
            projected.runtimePath = node.path
            projected.keepsControlContent = el.keepsControlContent
            // Bounds and focus are sampled from the current frame on every read. Fields,
            // links, grids and related labels also depend on live state or another subtree.
            changes += 1
            if reuseSemantic, el.liveText == nil, !hasScroll, !hasLinks, editLens == nil, el.terminalGridPayload == nil,
               el.a11yLabelledBy == nil, el.a11yDescribedBy == nil, virtualOwner == nil, parentList == nil,
               edges.children[idx].isEmpty || resolvedRole == .group || givenName != nil {
                storage.slots[idx].template = .init(node: projected,
                    controlName: isSecure ? nil : controlName, insideScroll: insideScroll, snapshot: currentSnapshot)
            }
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

/// Window hosts keep these callbacks for their lifetime. A client calling the public
/// update method with new callbacks gets a new snapshot for each actionable native element.
internal final class MacOSAccessibilityCallbacks: Sendable {
    typealias Action = @Sendable (String, AccessibilityAction) -> Void
    typealias SetValue = @Sendable (String, AccessibilityActionValue) -> Void
    typealias Select = @Sendable (String, Range<Int>) -> Void
    let select: Select?
    let assign: SetValue?
    let perform: Action

    init(onSelectText: Select?, onSetValue: SetValue?, onAction: @escaping Action) {
        self.select = onSelectText
        self.assign = onSetValue
        self.perform = onAction
    }
}

@MainActor
private final class AppKitAccessibilityEntry {
    let identity: AccessibilityIdentity
    var element: RuneNSAccessibilityElement?
    var node: AccessibilityNode
    weak var parent: AppKitAccessibilityEntry?
    var children: [AppKitAccessibilityEntry] = []
    var focused: AccessibilityIdentity?
    var pass: UInt64 = 0
    var usesCallbacks = false

    init(_ identity: AccessibilityIdentity, node: AccessibilityNode) {
        self.identity = identity
        self.node = node
    }
}

private extension AccessibilityNode {
    /// Values consumed by RuneNSAccessibilityElement.update. Field text, selections, and
    /// retained text layouts are synchronized by RuneAXTextField separately.
    func hasSameAppKitProperties(as old: Self) -> Bool {
        role == old.role && isSecure == old.isSecure && isModal == old.isModal &&
        isDisabled == old.isDisabled && isFocused == old.isFocused && isSelected == old.isSelected &&
        isExpanded == old.isExpanded && level == old.level && actions == old.actions &&
        Self.sameBytes(id, old.id) && Self.sameBytes(label, old.label) &&
        Self.sameBytes(value, old.value) && Self.sameBytes(help, old.help)
    }

    static func sameBytes(_ text: String?, _ other: String?) -> Bool {
        switch (text, other) {
        case let (lhs?, rhs?): return lhs.utf8.elementsEqual(rhs.utf8)
        case (nil, nil): return true
        default: return false
        }
    }

    func sharesChildren(with old: Self) -> Bool {
        guard children.count == old.children.count else { return false }
        if children.isEmpty { return true }
        return children.withUnsafeBufferPointer { current in
            old.children.withUnsafeBufferPointer { previous in current.baseAddress == previous.baseAddress }
        }
    }
}

/// Bridges `AccessibilityNode` trees and live-region announcements onto an AppKit `NSView` for VoiceOver.
@MainActor
public final class MacOSAccessibilityHost {
    private var previousTree: AccessibilityNode?
    private var lastFocusedId: AccessibilityIdentity?
    private weak var rootView: NSView?
    private var entries: [AccessibilityIdentity: AppKitAccessibilityEntry] = [:]
    private var roots: [AppKitAccessibilityEntry] = []
    private var pass: UInt64 = 0
    private var viewTransform: CGAffineTransform?
    private struct RuntimeStamp: Equatable {
        var runtime: ObjectIdentifier
        var commit: UInt64
        var live: UInt64
        var focused: String?
        var focusedLink: Int?
        var viewport: Vec2
        var count: Int
    }
    private var runtimeStamp: RuntimeStamp?
    private var lastScroll: [String: Vec2] = [:]
    private var wasAnimating = false
    private var refreshedFrames = false
    private var geometryRecords: [(entry: AppKitAccessibilityEntry, index: Int)]?
    private var lastCallbacks: MacOSAccessibilityCallbacks?
    #if DEBUG
    internal private(set) var lastUpdatedElements = 0
    internal private(set) var lastVisitedNodes = 0
    internal private(set) var materializedCount = 0
    #endif
    /// The workspace's display options observer (`a11y/macos.rs` `Adapter(_, DisplayOptions)`),
    /// removed with the adapter.
    private var displayOptions: MacOSDisplayOptionsWatcher?
    /// The tree this adapter last sent (`A11yTree`): whole on its first update and again when an
    /// assistive client first asks for it, and whether that whole tree held the announcer's words.
    private var fullAnnouncement = true
    private var heldWords = false
    /// `Tx::announce`'s live region as the reader was last told it (nil: no words).
    private var announcerLabel: String?
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

    /// AppKit requests screen rectangles, while the runtime paints in window coordinates.
    /// A pure scroll or moving window changes those rectangles between authored commits.
    @discardableResult
    internal func synchronize<State>(_ runtime: Runtime<State>, in view: NSView, force: Bool,
                                     callbacks: MacOSAccessibilityCallbacks) -> Bool {
        let stamp = RuntimeStamp(runtime: ObjectIdentifier(runtime), commit: runtime.commitCount, live: runtime.accessibilityLiveRevision,
                                 focused: runtime.focusedPath, focusedLink: runtime.focusedLinkIndex,
                                 viewport: runtime.viewport, count: runtime.flatNodes.count)
        let transform = RuneAXTextField.viewToScreen(view)
        let moved = viewTransform != transform || lastScroll != runtime.scrollOffsets || wasAnimating || runtime.isAnimating
        lastScroll = runtime.scrollOffsets
        wasAnimating = runtime.isAnimating
        if !force, !heldWords, runtimeStamp == stamp, callbacks === lastCallbacks,
           !announcementChanged(runtime.a11yAnnouncement) {
            if !moved || refreshGeometry(runtime, transform: transform) { return false }
        }
        let tree = runtime.nativeAccessibilitySnapshot()
        let held = update(tree: tree, announcement: runtime.a11yAnnouncement, parentView: view, callbacks: callbacks, transform: transform)
        runtimeStamp = stamp
        return held
    }

    private func refreshGeometry<State>(_ runtime: Runtime<State>, transform: CGAffineTransform) -> Bool {
        if geometryRecords == nil {
            var records: [(entry: AppKitAccessibilityEntry, index: Int)] = []
            records.reserveCapacity(entries.count)
            for entry in entries.values {
                guard let path = entry.node.runtimePath else {
                    // Only the window's invisible announcement has fixed geometry.
                    if entry.node.id == AccessibilityTreeState.announcerID { continue }
                    return false
                }
                // A text run/link or terminal cell can have bounds relative to a shaped line.
                guard let i = runtime.nodeByPath[path] else { return false }
                records.append((entry, i))
            }
            geometryRecords = records
        }
        guard let records = geometryRecords else { return false }
        let viewMoved = viewTransform != transform
        for (entry, index) in records {
            let flat = runtime.flatNodes[index]
            guard flat.path == entry.node.runtimePath else { return false }
            let frame = runtime.presentedRectByPath[flat.path] ?? flat.targetRect
            guard viewMoved || entry.node.frame != frame else { continue }
            // Rich text fields also need the new line layout's origin and transform.
            if entry.node.role == .textInput || entry.node.role == .multilineTextInput { return false }
            refreshedFrames = true
            entry.node.frame = frame
            entry.element?.setAccessibilityFrame(Self.screenFrame(frame, transform: transform))
        }
        viewTransform = transform
        return true
    }

    private static func screenFrame(_ frame: MotionRect, transform: CGAffineTransform) -> CGRect {
        CGRect(x: CGFloat(frame.left), y: CGFloat(frame.top), width: CGFloat(max(0, frame.width)),
               height: CGFloat(max(0, frame.height))).applying(transform)
    }

    /// AccessKit creates a platform node for a reader's request, including its native
    /// ancestors. Populating the semantic tree alone need not create any AppKit objects.
    private func materialize(_ entry: AppKitAccessibilityEntry) -> RuneNSAccessibilityElement {
        if let element = entry.element { return element }
        return refreshElement(entry)
    }

    @discardableResult
    private func refreshElement(_ entry: AppKitAccessibilityEntry) -> RuneNSAccessibilityElement {
        let node = entry.node
        let parent: AnyObject? = entry.parent.map { materialize($0) } ?? rootView
        let callbacks = lastCallbacks
        let transform = viewTransform ?? .identity
        let element = AppKitAccessibilityMapper.makeElement(node, parent: parent,
            onAction: node.actions.isEmpty ? nil : callbacks?.perform, onSelectText: callbacks?.select,
            onSetValue: node.actions.contains(.setValue) ? callbacks?.assign : nil,
            reusing: entry.element, viewToScreen: transform)
        if element !== entry.element {
            #if DEBUG
            if entry.element == nil { materializedCount += 1 }
            #endif
            if let old = entry.element {
                old.invalidate()
                entry.parent?.element?.cacheChildren(nil)
            }
            entry.element = element
            if !node.actions.isEmpty {
                var ancestor: AppKitAccessibilityEntry? = entry
                while let current = ancestor, !current.usesCallbacks {
                    current.usesCallbacks = true
                    ancestor = current.parent
                }
            }
            element.resolveChildren { [weak self, weak entry] in
                guard let self, let entry, entries[entry.identity] === entry else { return [] }
                let children: [Any] = entry.children.map { materialize($0) }
                entry.element?.cacheChildren(children)
                return children
            }
        }
        element.setAccessibilityFrame(Self.screenFrame(node.frame, transform: transform))
        return element
    }

    /// Synchronizes retained native proxies and emits focus and VoiceOver announcements.
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
        update(tree: tree, announcement: announcement, now: now, parentView: parentView,
               callbacks: MacOSAccessibilityCallbacks(onSelectText: onSelectText, onSetValue: onSetValue, onAction: onAction))
    }

    @discardableResult
    internal func update(tree: AccessibilityNode, announcement: AccessibilityAnnouncement? = nil,
                         now: Double = AccessibilityAnnouncement.clock(), parentView: NSView,
                         callbacks: MacOSAccessibilityCallbacks, transform suppliedTransform: CGAffineTransform? = nil) -> Bool {
        let revisitGeometry = refreshedFrames
        refreshedFrames = false
        pass &+= 1
        runtimeStamp = nil
        geometryRecords = nil
        #if DEBUG
        lastUpdatedElements = 0
        lastVisitedNodes = 0
        #endif
        let transform = suppliedTransform ?? RuneAXTextField.viewToScreen(parentView)
        let parentViewChanged = rootView !== parentView
        let movedView = viewTransform != transform || parentViewChanged
        viewTransform = transform
        rootView = parentView
        let callbacksChanged = callbacks !== lastCallbacks
        lastCallbacks = callbacks
        var changedFieldValues: [AppKitAccessibilityEntry] = []
        var changedSelections: [AppKitAccessibilityEntry] = []
        var replacedFocusedElement = false
        var destroyed: [RuneNSAccessibilityElement] = []
        var removed: [AppKitAccessibilityEntry] = []
        var spoken: [(text: String, politeness: LiveRegionPoliteness)] = []
        let speaksChanges = previousTree != nil || !isActivated
        func recordLive(_ old: AccessibilityNode?, _ node: AccessibilityNode) {
            if speaksChanges, let announcement = AccessibilityTreeBuilder.liveAnnouncement(previous: old, current: node),
               let text = announcement.spokenText { spoken.append((text, announcement.politeness)) }
        }

        // A requested native child always materializes its ancestors. For an unread
        // branch without focus, refresh its absolute geometry and model in place while
        // the mounted identities and child order match. Event sources use the normal
        // reconciliation path so announcements and editor notifications remain exact.
        func advanceUnread(_ node: AccessibilityNode, _ entry: AppKitAccessibilityEntry) -> Bool {
            guard !node.isFocused, !node.isModal, node.liveRegion == nil,
                  node.role != .dialog, node.role != .alertDialog,
                  node.role != .textInput, node.role != .multilineTextInput,
                  let path = node.runtimePath, entry.node.runtimePath == path,
                  node.children.count == entry.children.count else { return false }
            if !node.children.isEmpty, revisitGeometry || !node.sharesChildren(with: entry.node) {
                for i in node.children.indices {
                    if !advanceUnread(node.children[i], entry.children[i]) { return false }
                }
            }
            entry.pass = pass
            entry.node = node
            #if DEBUG
            lastVisitedNodes += 1
            #endif
            return true
        }

        func syncChildren(_ nodes: [AccessibilityNode], parent: AppKitAccessibilityEntry?, scope: AccessibilityIdentity?,
                          previous: [AppKitAccessibilityEntry], focused: inout AccessibilityIdentity?,
                          windowAnnouncer: Bool = false) -> (children: [AppKitAccessibilityEntry], changed: Bool) {
            var occurrences: [String: Int] = [:]
            // Copy the prefix only when identity, order, or native proxy actually changes.
            var changed: [AppKitAccessibilityEntry]?
            for (index, node) in nodes.enumerated() {
                let id = AccessibilityIdentity(node, parent: scope, occurrences: &occurrences)
                let prior = index < previous.count ? previous[index] : nil
                let candidate = prior?.identity == id ? prior : entries[id]
                let child: AppKitAccessibilityEntry
                if let candidate, candidate.element == nil, candidate.focused == nil,
                   candidate.parent === parent, advanceUnread(node, candidate) {
                    child = candidate
                } else {
                    child = syncNode(node, id, parent: parent, old: candidate,
                                     announce: !windowAnnouncer || index + 1 != nodes.count)
                }
                if focused == nil { focused = child.focused }
                if changed == nil, prior !== child { changed = Array(previous.prefix(index)) }
                changed?.append(child)
            }
            if changed == nil, nodes.count != previous.count { changed = Array(previous.prefix(nodes.count)) }
            guard let changed else { return (previous, false) }
            for old in previous where old.pass != pass { removed.append(old) }
            return (changed, true)
        }

        func syncNode(_ node: AccessibilityNode, _ id: AccessibilityIdentity, parent: AppKitAccessibilityEntry?,
                      old: AppKitAccessibilityEntry?, announce: Bool) -> AppKitAccessibilityEntry {
            #if DEBUG
            lastVisitedNodes += 1
            #endif
            let entry = old ?? AppKitAccessibilityEntry(id, node: node)
            let prior = old?.node
            let reparented = entry.parent !== parent || (parent == nil && parentViewChanged)
            entry.parent = parent
            entry.pass = pass
            entry.node = node
            if old == nil { entries[id] = entry }
            if announce { recordLive(prior, node) }
            let field = node.role == .textInput || node.role == .multilineTextInput
            if field, let prior, !node.isSecure, !prior.isSecure,
               (prior.role == .textInput || prior.role == .multilineTextInput),
               !AccessibilityNode.sameBytes(prior.value, node.value) { changedFieldValues.append(entry) }
            if field, let prior, prior.textSelection != node.textSelection,
               prior.textSelection?.count == 4, node.textSelection?.count == 4,
               !prior.isSecure, !node.isSecure {
                changedSelections.append(entry)
            }
            var replaced = false
            if let element = entry.element {
                let needsUpdate = reparented || field || (callbacksChanged && !node.actions.isEmpty) ||
                    prior.map { !node.hasSameAppKitProperties(as: $0) } != false
                if needsUpdate {
                    #if DEBUG
                    lastUpdatedElements += 1
                    #endif
                    replaced = refreshElement(entry) !== element
                    if replaced && node.isFocused { replacedFocusedElement = true }
                } else if movedView || prior?.frame != node.frame {
                    element.setAccessibilityFrame(Self.screenFrame(node.frame, transform: transform))
                }
            }
            if replaced || revisitGeometry || (callbacksChanged && entry.usesCallbacks) || movedView ||
                    prior.map({ !node.sharesChildren(with: $0) }) != false {
                var focus: AccessibilityIdentity?
                let children = syncChildren(node.children, parent: entry, scope: id, previous: entry.children, focused: &focus)
                entry.children = children.children
                if children.changed { entry.element?.cacheChildren(nil) }
                // The parent's native handle can change when a secure field starts exposing
                // a text provider. A descendant handle already held by a client follows it.
                if replaced, let parent = entry.element {
                    for child in entry.children { child.element?.setAccessibilityParent(parent) }
                }
                entry.usesCallbacks = (entry.element != nil && !node.actions.isEmpty) || entry.children.contains(where: \.usesCallbacks)
                entry.focused = node.isFocused ? id : focus
            } else if node.isFocused {
                entry.focused = id
            } else if entry.focused == id {
                entry.focused = entry.children.lazy.compactMap(\.focused).first
            }
            return entry
        }

        let windowGroup = tree.id == "root" && tree.role == .group && tree.label == nil &&
            !tree.isFocusable && !tree.isFocused && !tree.isDisabled && tree.actions.isEmpty
        if windowGroup { recordLive(previousTree, tree) }
        var visibleRoots = windowGroup ? tree.children : [tree]
        var announcerSpeech: (String, LiveRegionPoliteness)?
        if let announcement {
            sentAnnouncementCount = announcement.count
            heldWords = fullAnnouncement && announcement.recent(now: now)
            let node = AccessibilityTreeState.announcerNode(announcement, holdWords: heldWords)
            if !fullAnnouncement, let label = node.label, label != announcerLabel { announcerSpeech = (label, node.liveRegion ?? .polite) }
            fullAnnouncement = false
            announcerLabel = node.label
            visibleRoots.append(node)
        }
        var focusedNodeId: AccessibilityIdentity?
        let children = syncChildren(visibleRoots, parent: nil, scope: nil, previous: roots,
                                    focused: &focusedNodeId, windowAnnouncer: announcement != nil)
        roots = children.children
        func discard(_ entry: AppKitAccessibilityEntry) {
            guard entry.pass != pass, entries[entry.identity] === entry else { return }
            entries.removeValue(forKey: entry.identity)
            #if DEBUG
            if entry.element != nil { materializedCount -= 1 }
            #endif
            if let element = entry.element {
                element.invalidate()
                destroyed.append(element)
            }
            for child in entry.children { discard(child) }
        }
        for orphan in removed { discard(orphan) }
        previousTree = tree
        if let announcerSpeech { spoken.append(announcerSpeech) }
        lastSpoken = spoken
        for element in destroyed { NSAccessibility.post(element: element, notification: .uiElementDestroyed) }
        // As in the macOS AccessKit event adapter, readers see changed text before its selection.
        for entry in changedFieldValues { NSAccessibility.post(element: materialize(entry), notification: .valueChanged) }
        for entry in changedSelections {
            if let field = materialize(entry) as? RuneAXTextField { NSAccessibility.post(element: field, notification: .selectedTextChanged) }
        }

        if focusedNodeId != lastFocusedId || replacedFocusedElement {
            lastFocusedId = focusedNodeId
            if let fid = focusedNodeId, let entry = entries[fid] {
                NSAccessibility.post(element: materialize(entry), notification: .focusedUIElementChanged)
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
        return heldWords
    }

    /// An assistive client asked for the tree. The first time (AccessKit's activation), the next
    /// update holds the whole tree that client starts from.
    public func activate() {
        guard !isActivated else { return }
        isActivated = true
        if previousTree != nil { fullAnnouncement = true }
        onActivate?()
    }

    public func accessibilityChildren() -> [Any] {
        activate()
        return roots.map { materialize($0) }
    }

    public func accessibilityFocusedUIElement() -> Any? {
        activate()
        if let fid = lastFocusedId {
            return entries[fid].map { materialize($0) }
        }
        return nil
    }

    public func accessibilityHitTest(_ screenPoint: NSPoint, in parentView: NSView) -> Any? {
        activate()
        let transform = viewTransform ?? RuneAXTextField.viewToScreen(parentView)
        func hit(_ entry: AppKitAccessibilityEntry) -> AppKitAccessibilityEntry? {
            for child in entry.children.reversed() {
                if let result = hit(child) { return result }
            }
            return Self.screenFrame(entry.node.frame, transform: transform).contains(screenPoint) ? entry : nil
        }
        for root in roots.reversed() {
            if let result = hit(root) { return materialize(result) }
        }
        return nil
    }
}

#endif
