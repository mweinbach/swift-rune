import Foundation
#if os(Android)
import Android
#endif

// MARK: - Focus & Modal State Machines (`runtime/input/focus_machine.rs`, `modal_focus.rs`, `focus.rs`)

/// Arrow navigation behavior of a focus-group container (`focus_machine.rs`).
public enum MenuListKind: Equatable, Sendable {
    /// Menus and listboxes wrap vertically at ends.
    case wrapMenu
    /// Lists, trees, and grids clamp at first and last items.
    case clampedList
}

/// How the active modal/menu was opened (`modal_focus.rs`).
public enum ModalOpenedKind: Equatable, Sendable {
    case dialog
    case pointerMenu
}

/// Type-ahead selection state with a 1-second rolling prefix buffer (`focus_machine.rs`).
public struct TypeSelect: Sendable {
    public static let windowSeconds: Double = 1.0

    public private(set) var query: String = ""
    public private(set) var lastAt: Double = -.infinity

    public init() {}

    public mutating func reset() {
        query = ""
        lastAt = -.infinity
    }

    public mutating func push(_ text: String, at now: Double) -> (query: String, cycleSingleChar: Bool) {
        let lower = text.lowercased()
        if !lastAt.isFinite || (now - lastAt) > Self.windowSeconds {
            query = lower
        } else {
            query += lower
        }
        lastAt = now
        let scalars = Array(query.unicodeScalars)
        let allSame = scalars.count > 1 && scalars.allSatisfy { $0 == scalars[0] }
        let searchQuery = allSame ? String(scalars[0]) : query
        let cycle = scalars.count == 1 || allSame
        return (searchQuery, cycle)
    }

    public func match(
        labels: [String],
        current: Int?,
        query: String,
        cycleSingleChar: Bool
    ) -> Int? {
        guard !query.isEmpty, !labels.isEmpty else { return nil }
        let n = labels.count
        let start = cycleSingleChar ? ((current ?? -1) + 1) : (current ?? 0)
        for offset in 0..<n {
            let idx = ((start % n) + n + offset) % n
            if labels[idx].lowercased().hasPrefix(query) {
                return idx
            }
        }
        return nil
    }
}

/// Tracks a non-repeat physical key press that may trigger a delayed commit focus change (`physical.rs:624`).
public struct PendingPhysicalFocusCheck: Sendable {
    public var code: PhysicalKeyCode
    public var key: Key?
    public var beforeFocus: String?
    public init(code: PhysicalKeyCode, key: Key?, beforeFocus: String?) {
        self.code = code
        self.key = key
        self.beforeFocus = beforeFocus
    }
}

/// How focus came to the element that has it (`focus_machine.rs::Entry`, #1297): by the keys
/// (Tab, an arrow in a group, `Tx.focus` with a ring), or otherwise (a press, a hand-over
/// without a ring, nothing focused). A field's keyboard-entry ring follows it, not modality.
public enum FocusEntry: Equatable, Sendable {
    case other
    case keys
}

/// Focus entry state-machine events (`focus_machine.rs::FocusEvent`, #1297).
public enum FocusEvent: Equatable, Sendable {
    /// Focus moves to `path` (or nowhere) and shows as `keyboard` says.
    case set(path: String?, keyboard: Bool)
    /// The window came to the front again with focus where it was: that isn't the keys moving
    /// focus there.
    case windowReturned
}

/// Coordinated keyboard highlight, type-select, and modal focus metadata (`focus_machine.rs`, `modal_focus.rs`).
public struct FocusMachine: Sendable {
    public var highlightHidden: Bool = false
    public var highlightedPath: String? = nil
    public var hoveredHighlight: Bool = false
    public var openedModalKind: ModalOpenedKind = .dialog
    public var typeSelect = TypeSelect()
    public var disarmedScrimReturn: Bool = false
    /// The focus the gesture or commit underway took away (`Focus::None { blurred }`); a commit
    /// that settles with no press held clears it (`FocusEvent::Settled`).
    public var blurredFocusPath: String? = nil
    /// Whether the keyboard drove focus last (`Modality::Keyboard`); it outlives a blur.
    public var focusKeyboard: Bool = false
    /// How focus arrived at the currently focused element (`focus_machine.rs::Entry`, #1297).
    public var entry: FocusEntry = .other
    /// Whether the keys put focus where it is (`FocusState::entered_by_keys`, #1297).
    public var enteredByKeys: Bool { entry == .keys }
    /// Whether focus the element lost may go to a neighbour once it leaves the tree
    /// (`Focus::None { handoff }`): Escape hands on, `Tx::blur` doesn't.
    public var focusHandoff: Bool = false
    public var lastPressedWasPointer: Bool = false
    public var suppressedRepeatKey: Key? = nil
    public var suppressedRepeatPhysicalKeys: Set<PhysicalKeyCode> = []
    public var pendingPhysicalFocusCheck: PendingPhysicalFocusCheck? = nil
    public var lastFocusSelectedByGroup: [String: String] = [:]

    public init() {}

    public mutating func step(_ event: FocusEvent) {
        switch event {
        case .set(let path, let keyboard):
            focusKeyboard = keyboard
            entry = (keyboard && path != nil) ? .keys : .other
        case .windowReturned:
            entry = .other
        }
    }

    public mutating func resetForModalClose() {
        highlightHidden = false
        highlightedPath = nil
        hoveredHighlight = false
        openedModalKind = .dialog
        typeSelect.reset()
        disarmedScrimReturn = false
    }

    public static func listKind(for role: ElementRole) -> MenuListKind? {
        switch role {
        case .menu:
            return .wrapMenu
        case .listbox, .list, .tree, .grid:
            return .clampedList
        default:
            return nil
        }
    }
}

extension Runtime {
    /// Returns the element key of the currently visible menu/list focus highlight, if any (`focus_machine.rs`).
    public func highlightedElementKey() -> String? {
        let fm = inputMachines.focusMachine
        guard !fm.highlightHidden else { return nil }
        if let hp = fm.highlightedPath, let idx = nodeByPath[hp] {
            return flatNodes[idx].key
        }
        if focusVisible, let fp = focusedPath, let idx = nodeByPath[fp], flatNodes[idx].el.focusHighlightColor != nil {
            return flatNodes[idx].key
        }
        return nil
    }

    internal func isMenuLikeContainer(_ groupIdx: Int) -> Bool {
        FocusMachine.listKind(for: flatNodes[groupIdx].el.role) != nil
    }

    internal func groupMemberIndices(groupIndex: Int) -> [Int] {
        let prefix = flatNodes[groupIndex].path + "/"
        return flatNodes.indices.filter { i in
            i != groupIndex &&
            (flatNodes[i].path == flatNodes[groupIndex].path || flatNodes[i].path.hasPrefix(prefix)) &&
            canFocusIndex(i)
        }
    }

    internal func menuItemLabel(at idx: Int) -> String {
        let el = flatNodes[idx].el
        if let lbl = el.a11yLabel, !lbl.isEmpty { return lbl }
        if let txt = el.plainText, !txt.isEmpty { return txt }
        if let k = flatNodes[idx].key, !k.isEmpty { return k }
        return ""
    }

    /// A field left mid-composition keeps what it showed (`set_focus` → `finish_field_composition`,
    /// focus.rs:247-255). `why`: the focus move's cause, `INPUT` when a press or key moved it
    /// (the action is input), `DIRTY` when the commit's focus sync did.
    internal func finishPreeditIfNeeded(forPath path: String?, at now: Double, why: UInt16 = CommitWhy.input) {
        guard let path else { return }
        guard let idx = nodeByPath[path],
              let editLens = flatNodes[idx].el.handlers.editLens else {
            return
        }
        var edit = editLens.get(state)
        if let activePreedit = edit.preedit?.text, edit.finishPreedit() {
            editLens.set(&state, edit)
            var tx = makeTx(at: now)
            if flatNodes[idx].el.layoutAnim == nil { tx.instant() }
            flatNodes[idx].el.handlers.onTextChange?(&state, edit.text, &tx)
            _ = flatNodes[idx].el.handlers.onInputChange?(&state, edit.text, &tx)
            applyTx(tx, at: now, markDirtyIfNotLiveOnly: false, why: why)
            _ = dispatchIme(.commit(activePreedit), at: now)
            imeReset = true
            needsCommit = true
            commitWhyPending |= why
        }
    }

    @discardableResult
    internal func updateMenuHoverHighlight(hoveredPath newHover: String?) -> Bool {
        var hoverRowIdx: Int? = nil
        if let hp = newHover, let hIdx = nodeByPath[hp], !flatNodes[hIdx].effectiveInert {
            var walk: Int? = hIdx
            while let cur = walk {
                if flatNodes[cur].effectiveInert { break }
                if canFocusIndex(cur) {
                    if flatNodes[cur].el.focusHighlightColor != nil
                        || (findFocusGroupAncestor(of: cur).map { isMenuLikeContainer($0) } ?? false) {
                        hoverRowIdx = cur
                    }
                    break
                }
                walk = flatNodes[cur].parentIndex
            }
        }
        if hasFocusedTextInput {
            hoverRowIdx = nil
        }
        if let rowIdx = hoverRowIdx {
            let rowPath = flatNodes[rowIdx].path
            let rowKey = flatNodes[rowIdx].key
            let changed = inputMachines.focusMachine.highlightHidden
                || inputMachines.focusMachine.highlightedPath != rowPath
                || !inputMachines.focusMachine.hoveredHighlight
            focusedPath = rowPath
            focusedKey = rowKey
            focusVisible = false
            inputMachines.focusMachine.entry = .other
            inputMachines.focusMachine.highlightHidden = false
            inputMachines.focusMachine.highlightedPath = rowPath
            inputMachines.focusMachine.hoveredHighlight = true
            return changed
        } else if inputMachines.focusMachine.hoveredHighlight {
            inputMachines.focusMachine.hoveredHighlight = false
            inputMachines.focusMachine.highlightedPath = nil
            inputMachines.focusMachine.highlightHidden = true
            return true
        }
        return false
    }

    internal func findSearchFollowsGroup(forFocusedIndex fIdx: Int) -> Int? {
        guard flatNodes[fIdx].el.handlers.editLens != nil else { return nil }
        // Look inside the active modal (or nearest shared parent container) for a `.menu`/`.listbox` with `.focusFollows()`.
        let scopeIndices: AnySequence<Int>
        if activeModalPath != nil {
            scopeIndices = AnySequence(flatNodes.indices.filter { modalMemberPaths.contains(flatNodes[$0].path) })
        } else if let p = flatNodes[fIdx].parentIndex {
            let prefix = flatNodes[p].path + "/"
            scopeIndices = AnySequence(flatNodes.indices.filter { flatNodes[$0].path.hasPrefix(prefix) })
        } else {
            return nil
        }
        for i in scopeIndices {
            let el = flatNodes[i].el
            if el.focusGroup && el.isFocusFollowsSelection && FocusMachine.listKind(for: el.role) != nil {
                return i
            }
        }
        return nil
    }

    internal func invokeKeyboardPress(_ node: FlatNode, at now: Double) -> Bool {
        if let onClick = node.el.handlers.onClick {
            var tx = makeTx(at: now)
            onClick(&state, &tx)
            applyTx(tx, at: now)
            return true
        }
        if let onClickPress = node.el.handlers.onClickPress ?? node.el.handlers.onBackgroundPress {
            let r = presentedRectByPath[node.path] ?? node.targetRect
            let press = PointerPress(
                window: Vec2(r.x + r.width * 0.5, r.y + r.height * 0.5),
                local: Vec2(r.width * 0.5, r.height * 0.5),
                elementSize: Vec2(r.width, r.height),
                button: .primary,
                mods: .none,
                clicks: 1
            )
            var tx = makeTx(at: now)
            onClickPress(&state, press, &tx)
            applyTx(tx, at: now)
            return true
        }
        return false
    }

    internal func isHighlightedMenuNode(_ snap: FlatNode, isFocused: Bool) -> Bool {
        let fm = inputMachines.focusMachine
        if let hp = fm.highlightedPath {
            return !fm.highlightHidden && hp == snap.path
        }
        return !fm.highlightHidden && isFocused && focusVisible
    }

    internal func handleMenuOrGroupNavigation(
        _ ev: KeyEvent,
        focusedIndex fIdx: Int,
        isRepeat: Bool,
        at now: Double
    ) -> Bool {
        let fNode = flatNodes[fIdx]
        let fm = inputMachines.focusMachine

        // 1. Search field paired with `.focusFollows()` menu/listbox (`focus.rs` searchable menu).
        if let followsGroupIdx = findSearchFollowsGroup(forFocusedIndex: fIdx) {
            let members = groupMemberIndices(groupIndex: followsGroupIdx)
            if !members.isEmpty {
                if ev.mods == .none && (ev.key == .arrowDown || ev.key == .arrowUp) {
                    let down = (ev.key == .arrowDown)
                    let curPos = fm.highlightedPath.flatMap { hp in
                        members.firstIndex(where: { flatNodes[$0].path == hp })
                    }
                    let nextPos: Int
                    if fm.highlightHidden || curPos == nil {
                        nextPos = members.firstIndex(where: { flatNodes[$0].el.isFocusSelected || flatNodes[$0].el.itemSelected })
                            ?? (down ? 0 : members.count - 1)
                    } else {
                        nextPos = down ? (curPos! + 1) % members.count : (curPos! - 1 + members.count) % members.count
                    }
                    inputMachines.focusMachine.highlightHidden = false
                    inputMachines.focusMachine.highlightedPath = flatNodes[members[nextPos]].path
                    inputMachines.focusMachine.hoveredHighlight = false
                    ensureNodeVisibleInScrollAncestors(index: members[nextPos], at: now)
                    dirtyCommit(at: now, why: CommitWhy.input)
                    return true
                }
                if ev.mods == .none && ev.key == .enter && !isRepeat && !fm.highlightHidden,
                   let hp = fm.highlightedPath, let hIdx = nodeByPath[hp],
                   invokeKeyboardPress(flatNodes[hIdx], at: now) {
                    return true
                }
            }
        }

        // 2. Hidden highlight inside a pointer-opened menu blocks Return/Space without revealing (`focus.rs:1490`).
        if let groupIdx = findFocusGroupAncestor(of: fIdx),
           isMenuLikeContainer(groupIdx),
           fm.highlightHidden,
           ev.mods == .none,
           (ev.key == .enter || ev.key == .space) {
            return true
        }

        // 3. Popup/combobox trigger opens on unmodified Up/Down once per press (`focus.rs:647`: only
        // `role == "combobox"` without an input; a disclosure such as a sidebar toggle merely reports
        // `expanded` and must not toggle on arrows).
        if fNode.el.handlers.editLens == nil,
           fNode.el.role == .combobox,
           fNode.el.role != .slider,
           findFocusGroupAncestor(of: fIdx) == nil,
           ev.mods == .none,
           (ev.key == .arrowDown || ev.key == .arrowUp) {
            if isRepeat { return true }
            if invokeKeyboardPress(fNode, at: now) {
                inputMachines.focusMachine.lastPressedWasPointer = false
                inputMachines.focusMachine.highlightHidden = false
                focusVisible = true
                return true
            }
        }

        // 4. Direct focus-group keyboard navigation: arrows, Home/End, PageUp/PageDown, TypeSelect.
        guard let groupIdx = findFocusGroupAncestor(of: fIdx) else {
            return false
        }
        return navigateGroupContainer(groupIdx, focusedNode: fNode, ev: ev, isRepeat: isRepeat, at: now)
    }

    internal func handleUnfocusedMenuNavigation(
        _ ev: KeyEvent,
        isRepeat: Bool,
        at now: Double
    ) -> Bool {
        let scopePrefix: String?
        if let mPath = activeModalPath, let mIdx = nodeByPath[mPath] {
            scopePrefix = flatNodes[mIdx].path
        } else {
            scopePrefix = nil
        }
        let candidates = flatNodes.indices.filter { idx in
            let n = flatNodes[idx]
            guard n.el.focusGroup, isMenuLikeContainer(idx), !n.effectiveInert else { return false }
            if let prefix = scopePrefix {
                return n.path == prefix || n.path.hasPrefix(prefix + "/")
            }
            return true
        }
        guard let groupIdx = candidates.last else { return false }
        let fm = inputMachines.focusMachine
        if !fm.highlightHidden,
           let hp = fm.highlightedPath,
           let hIdx = nodeByPath[hp],
           ev.mods == .none,
           (ev.key == .enter || ev.key == .space),
           !isRepeat,
           invokeKeyboardPress(flatNodes[hIdx], at: now) {
            return true
        }
        return navigateGroupContainer(groupIdx, focusedNode: nil, ev: ev, isRepeat: isRepeat, at: now)
    }

    private func navigateGroupContainer(
        _ groupIdx: Int,
        focusedNode fNode: FlatNode?,
        ev: KeyEvent,
        isRepeat: Bool,
        at now: Double
    ) -> Bool {
        let fm = inputMachines.focusMachine
        let members = groupMemberIndices(groupIndex: groupIdx)
        guard !members.isEmpty else { return false }
        let listKind = FocusMachine.listKind(for: flatNodes[groupIdx].el.role)

        if ev.mods == .none,
           (ev.key == .arrowRight || ev.key == .arrowDown || ev.key == .arrowLeft || ev.key == .arrowUp),
           !(listKind == .wrapMenu && (ev.key == .arrowLeft || ev.key == .arrowRight)) {
            let isRtl = flatNodes[groupIdx].flow == .rtl
            let forward: Bool
            switch ev.key {
            case .arrowDown: forward = true
            case .arrowUp: forward = false
            case .arrowRight: forward = !isRtl
            case .arrowLeft: forward = isRtl
            default: forward = true
            }
            if (fm.highlightHidden || (fm.highlightedPath == nil && focusedPath == nil)) && isMenuLikeContainer(groupIdx) {
                let checkedPos = members.firstIndex(where: { flatNodes[$0].el.isFocusSelected || flatNodes[$0].el.itemSelected })
                let curPos = checkedPos ?? focusedPath.flatMap { fp in
                    members.firstIndex(where: { flatNodes[$0].path == fp })
                }
                let entryPos: Int
                if let checkedPos {
                    entryPos = checkedPos
                } else if let curPos, forward {
                    entryPos = curPos
                } else {
                    entryPos = forward ? 0 : members.count - 1
                }
                return moveFocusToGroupMember(members[entryPos], at: now)
            }
            guard let curPath = fm.highlightedPath ?? focusedPath,
                  let curPos = members.firstIndex(where: { flatNodes[$0].path == curPath }) else {
                return false
            }
            let nextPos: Int
            if listKind == .clampedList {
                nextPos = forward ? min(members.count - 1, curPos + 1) : max(0, curPos - 1)
            } else {
                nextPos = forward ? (curPos + 1) % members.count : (curPos - 1 + members.count) % members.count
            }
            return moveFocusToGroupMember(members[nextPos], at: now)
        }

        let focusedIsSlider = fNode.map {
            $0.el.role == .slider || $0.el.handlers.onStep != nil || $0.el.handlers.onStepLimit != nil
        } ?? false
        if !focusedIsSlider && ev.mods == .none && (ev.key == .home || ev.key == .end || ev.key == .pageUp || ev.key == .pageDown) {
            let curPath = fm.highlightedPath ?? focusedPath
            let curPos = curPath.flatMap { cp in members.firstIndex(where: { flatNodes[$0].path == cp }) } ?? 0
            let nextPos: Int
            switch ev.key {
            case .home:
                nextPos = 0
            case .end:
                nextPos = members.count - 1
            case .pageDown, .pageUp:
                let step = pageStepCount(forGroup: groupIdx, members: members)
                nextPos = ev.key == .pageDown
                    ? min(members.count - 1, curPos + step)
                    : max(0, curPos - step)
            default:
                nextPos = curPos
            }
            return moveFocusToGroupMember(members[nextPos], at: now)
        }

        if !ev.mods.ctrl && !ev.mods.alt && !ev.mods.cmd && !isRepeat && isMenuLikeContainer(groupIdx),
           case .text(let ch) = ev.key, ch != " ", fNode?.el.handlers.editLens == nil {
            let labels = members.map { menuItemLabel(at: $0) }
            let curPath = fm.highlightedPath ?? focusedPath
            let curPos = curPath.flatMap { cp in members.firstIndex(where: { flatNodes[$0].path == cp }) }
            let (q, cycle) = inputMachines.focusMachine.typeSelect.push(ch, at: now)
            if let hit = inputMachines.focusMachine.typeSelect.match(
                labels: labels,
                current: curPos,
                query: q,
                cycleSingleChar: cycle
            ) {
                return moveFocusToGroupMember(members[hit], at: now)
            }
        }

        return false
    }

    private func pageStepCount(forGroup groupIdx: Int, members: [Int]) -> Int {
        var walk: Int? = groupIdx
        var scrollHeight: Float = 0
        while let cur = walk {
            if flatNodes[cur].el.layout.scrollAxes.contains(.vertical) {
                scrollHeight = flatNodes[cur].targetRect.height
                break
            }
            walk = flatNodes[cur].parentIndex
        }
        guard scrollHeight > 0, !members.isEmpty else { return 1 }
        let totalH = members.reduce(Float(0)) { $0 + max(1, flatNodes[$1].targetRect.height) }
        let avgH = max(1, totalH / Float(members.count))
        return max(1, Int(floor(scrollHeight / avgH)) - 1)
    }

    @discardableResult
    private func moveFocusToGroupMember(_ memberIdx: Int, at now: Double) -> Bool {
        let nextNode = flatNodes[memberIdx]
        let moved = (focusedPath != nextNode.path)
        if moved {
            finishPreeditIfNeeded(forPath: focusedPath, at: now)
        }
        assignFocusPath(nextNode.path, keyboard: true)
        focusedKey = nextNode.key
        inputMachines.focusMachine.highlightHidden = false
        inputMachines.focusMachine.highlightedPath = nextNode.path
        inputMachines.focusMachine.hoveredHighlight = false
        inputMachines.focusMachine.step(.set(path: nextNode.path, keyboard: true))
        inputMachines.focusMachine.blurredFocusPath = nil
        inputMachines.focusMachine.focusHandoff = false
        clearTabStartFocusPath()
        focusVisible = true
        ensureNodeVisibleInScrollAncestors(index: memberIdx, at: now)
        dirtyCommit(at: now, why: CommitWhy.input)
        if let g = findFocusGroupAncestor(of: memberIdx),
           (nextNode.el.role == .radio || nextNode.el.role == .tab || flatNodes[g].el.isFocusFollowsSelection),
           moved {
            _ = invokeKeyboardPress(nextNode, at: now)
        }
        return true
    }

    internal func ensureNodeVisibleInScrollAncestors(index targetIdx: Int, at now: Double) {
        _ = now
        let targetRect = flatNodes[targetIdx].targetRect
        var walk = flatNodes[targetIdx].parentIndex
        while let cur = walk {
            let node = flatNodes[cur]
            if node.el.layout.scrollAxes.contains(.vertical) {
                let vpTop = node.targetRect.y
                let vpBottom = node.targetRect.y + node.targetRect.height
                let curOff = scrollOffsets[node.path] ?? .zero
                var nextY = curOff.y
                if targetRect.y < vpTop {
                    nextY -= (vpTop - targetRect.y)
                } else if targetRect.y + targetRect.height > vpBottom {
                    nextY += (targetRect.y + targetRect.height - vpBottom)
                }
                if nextY != curOff.y {
                    let maxY = scrollMaxExtents[node.path]?.y ?? max(0, (scrollContentSizes[node.path]?.y ?? node.targetRect.height) - node.targetRect.height)
                    let clampedY = min(max(0, nextY), maxY)
                    let nextVec = Vec2(curOff.x, clampedY)
                    scrollOffsets[node.path] = nextVec
                    scrollStore.snap(NodeId.hash("scroll:" + node.path), Props.SCROLL, to: nextVec)
                    scrollMovedSinceLastFrame = true
                }
            }
            walk = node.parentIndex
        }
    }
}
