import Foundation
import RuneMotion

// MARK: - Increment 4 Runtime Support (TxCommit, ScrollRequests, Sticky, VirtualRows/VirtualFill, Growth)

extension Runtime {
    /// Matches a virtual row key directly or as an ancestor segment of a scoped descendant selector
    /// (e.g. `"r40/active-hit"` pins and targets virtual row `"r40"` so nested highlights mount first).
    static func virtualRowMatchesSelector(rowKey: String, virtualPath: String, selector: String) -> Bool {
        if rowKey == selector || selectsElementSelector(selector, path: "\(virtualPath)/\(rowKey)", key: rowKey) {
            return true
        }
        guard selector.contains("/") else { return false }
        let parts = selector.split(separator: "/")
        return parts.dropLast().contains { $0 == rowKey || $0 == "@\(rowKey)" }
    }

    internal enum VirtualRowReuseMode: Equatable, Sendable {
        case none
        case remount
        case rebuildRegion
    }

    internal struct CachedVirtualRow {
        var el: El<State>
        var memoIds: Set<String>
        var reads: [MemoRead] = []
        var trackedReads: TrackedReads = TrackedReads()
        var envHash: UInt64 = 0

        func holds(against geometry: [String: MemoElementGeometry], envHash: UInt64) -> Bool {
            self.envHash == envHash
                && !trackedReads.changed()
                && reads.allSatisfy { $0.matches(geometry) }
        }
    }

    internal struct VirtualSelectionSource {
        var listPath: String
        var keys: [String]
        var mounted: Range<Int>
        var isIndexed: Bool
        var source: VirtualRowSource<State>?
        var storedChildren: [El<State>]
        var scrollAxes: ScrollAxes
    }

    internal struct VirtualExpansionContext {
        var rowMappings: [(listPath: String, scrollPath: String, rowSegment: String, rowKey: String)] = []
        var anyVirtualList: Bool = false
        var virtualInputs: [String: VirtualInputEntry] = [:]
        var builtVirtualRows: [String: [String: CachedVirtualRow]] = [:]
        var remountHitNestedVirtual: Bool = false
        var selectionSources: [String: VirtualSelectionSource] = [:]
    }

    internal struct GrowthCaptureResult {
        var needsClampedRelayout: Bool = false
        var activeCount: Int = 0
        var foldOpens: [PendingFoldOpen] = []
        var scrollCuts: [(viewport: String, cut: Float)] = []
        var foldHeaderUpdates: [(foldKey: String, headerPath: String)] = []
    }

    private struct StackFoldEffect {
        var scrollPath: String?
        var hiddenCut: Float = 0
        var held: [(gKey: String, below: Float)] = []
        var reopened: [(foldPath: String, giving: Bool)] = []
    }

    internal func foldRowHoldsExiting(rowPath: String) -> Bool {
        let prefix = rowPath + "/"
        return exitingSnapshots.contains { nid, snap in
            snap.path.hasPrefix(prefix) && scene.isExiting(nid)
        }
    }

    // MARK: - Helpers

    internal func makeTx(
        at now: Double,
        button: PointerButton = .primary,
        mods: Mods? = nil,
        physicalKey: PhysicalKeyCode? = nil,
        isRepeat: Bool = false
    ) -> Tx {
        var tx = Tx()
        tx.clock = now
        if let sel = currentTextSelection() {
            tx.setCurrentTextSelection(sel)
        }
        tx.button = button
        tx.runtimeActions["focusVisible"] = focusVisible
        tx.runtimeActions["byKeys"] = kitHooks.isDispatchingByKeys || activeByKeys
        tx.physicalKeyValue = currentPhysicalKey
        tx.keyBaseValue = currentKeyBase
        tx.keyRepeatValue = currentKeyRepeat
        tx.tracingEnabled = (traceChannels != nil) || scene.isTracing || isTracing
        tx.focusVisibleAtEvent = focusVisible
        tx.byKeysAtEvent = activeByKeys || kitHooks.isDispatchingByKeys
        tx.assistiveTechnologyActive = assistiveTechnology
        tx.eventInputTime = now
        tx.mods = mods ?? inputMachines.currentMods
        tx.physicalKeyCode = physicalKey
        tx.isKeyRepeat = isRepeat
        tx.focusedElementKey = focusedKey ?? focusedPath.flatMap { fp in
            nodeByPath[fp].map { "#\($0)" }
        }
        return tx
    }

    public func scrollOffset(forKey key: String) -> Vec2 {
        if let match = flatNodes.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) }) {
            return scrollOffsets[match.path] ?? .zero
        }
        return .zero
    }

    internal func layoutPathSegment(
        keyId: String?,
        siblingIndex: Int,
        siblingKeysSeen: inout [String: Int]
    ) -> (segment: String, resolvedKey: String?) {
        if let rawK = keyId {
            let count = siblingKeysSeen[rawK, default: 0]
            siblingKeysSeen[rawK] = count + 1
            if count == 0 {
                return ("@\(rawK)", rawK)
            } else {
                let dup = "\(rawK)#dup\(count)"
                return ("@\(dup)", dup)
            }
        }
        return ("\(siblingIndex)", nil)
    }

    // MARK: - Pre-Layout Virtualize / VirtualRows Expansion

    private func treeContainsVirtual(_ rootEl: El<State>) -> Bool {
        var stack: [El<State>] = [rootEl]
        while let cur = stack.popLast() {
            if cur.virtualEstimate != nil || cur.virtualRowsSource != nil {
                return true
            }
            if !cur.children.isEmpty {
                stack.append(contentsOf: cur.children)
            }
        }
        return false
    }

    @inline(never)
    internal func expandVirtualSubtrees(
        in rootEl: El<State>,
        remountRowCache: [String: [String: CachedVirtualRow]]? = nil,
        rowReuseMode: VirtualRowReuseMode = .none,
        memoGeometry: [String: MemoElementGeometry] = [:],
        memoEnvHash: UInt64 = MemoScope.activeEnvHash,
        memoPass: UInt64 = 0
    ) -> (root: El<State>, context: VirtualExpansionContext) {
        var ctx = VirtualExpansionContext()
        activeVirtualPaths.removeAll(keepingCapacity: true)
        guard treeContainsVirtual(rootEl) else {
            return (rootEl, ctx)
        }
        var expanded = rootEl
        var rootSeen: [String: Int] = [:]
        walkVirtualSubtrees(
            &expanded,
            parentPath: "",
            siblingIndex: 0,
            siblingKeysSeen: &rootSeen,
            scrollPath: nil,
            scrollStickBottom: false,
            remountRowCache: remountRowCache,
            rowReuseMode: rowReuseMode,
            inReusableRegion: false,
            regionEnvHash: 0,
            memoGeometry: memoGeometry,
            memoEnvHash: memoEnvHash,
            memoPass: memoPass,
            ctx: &ctx
        )
        return (expanded, ctx)
    }

    private func walkVirtualSubtrees(
        _ el: inout El<State>,
        parentPath: String,
        siblingIndex: Int,
        siblingKeysSeen: inout [String: Int],
        scrollPath: String?,
        scrollStickBottom: Bool,
        remountRowCache: [String: [String: CachedVirtualRow]]?,
        rowReuseMode: VirtualRowReuseMode,
        inReusableRegion: Bool,
        regionEnvHash: UInt64,
        memoGeometry: [String: MemoElementGeometry],
        memoEnvHash: UInt64,
        memoPass: UInt64,
        ctx: inout VirtualExpansionContext
    ) {
        let (segment, _) = layoutPathSegment(
            keyId: el.keyId,
            siblingIndex: siblingIndex,
            siblingKeysSeen: &siblingKeysSeen
        )
        let path = parentPath.isEmpty ? (el.keyId.map { "/@\($0)" } ?? "/0") : "\(parentPath)/\(segment)"

        let nodeInReusableRegion = el.memoRegionReused ? true : inReusableRegion
        let nodeRegionEnvHash = el.memoRegionReused ? el.memoRegionEnvHash : regionEnvHash

        var nextScrollPath = scrollPath
        var nextStickBottom = scrollStickBottom
        if !el.layout.scrollAxes.isEmpty {
            nextScrollPath = path
            nextStickBottom = el.layout.stickBottom
        }

        if el.virtualEstimate != nil || el.virtualRowsSource != nil {
            expandSingleVirtualNode(
                &el,
                path: path,
                nextScrollPath: nextScrollPath,
                nextStickBottom: nextStickBottom,
                remountRowCache: remountRowCache,
                rowReuseMode: rowReuseMode,
                inReusableRegion: nodeInReusableRegion,
                regionEnvHash: nodeRegionEnvHash,
                memoGeometry: memoGeometry,
                memoEnvHash: memoEnvHash,
                memoPass: memoPass,
                ctx: &ctx
            )
            return
        }

        guard !el.children.isEmpty else { return }
        var childSeen: [String: Int] = [:]
        for idx in el.children.indices {
            walkVirtualSubtrees(
                &el.children[idx],
                parentPath: path,
                siblingIndex: idx,
                siblingKeysSeen: &childSeen,
                scrollPath: nextScrollPath,
                scrollStickBottom: nextStickBottom,
                remountRowCache: remountRowCache,
                rowReuseMode: rowReuseMode,
                inReusableRegion: nodeInReusableRegion,
                regionEnvHash: nodeRegionEnvHash,
                memoGeometry: memoGeometry,
                memoEnvHash: memoEnvHash,
                memoPass: memoPass,
                ctx: &ctx
            )
        }
    }

    @inline(never)
    private func expandSingleVirtualNode(
        _ el: inout El<State>,
        path: String,
        nextScrollPath: String?,
        nextStickBottom: Bool,
        remountRowCache: [String: [String: CachedVirtualRow]]?,
        rowReuseMode: VirtualRowReuseMode,
        inReusableRegion: Bool,
        regionEnvHash: UInt64,
        memoGeometry: [String: MemoElementGeometry],
        memoEnvHash: UInt64,
        memoPass: UInt64,
        ctx: inout VirtualExpansionContext
    ) {
        ctx.anyVirtualList = true
        activeVirtualPaths.insert(path)
        var vState = virtualLists[path] ?? RuntimeVirtualListState()
        let isIndexed = (el.virtualRowsSource != nil)
        let est = max(1, el.virtualEstimate ?? 40)

        let count: Int
        let keys: [String]
        if let src = el.virtualRowsSource {
            count = src.count
            if let ver = el.virtualRowsVersionHash,
               vState.lastKeysVersion == ver,
               vState.lastKeys.count == count {
                keys = vState.lastKeys
            } else {
                var builtKeys: [String] = []
                builtKeys.reserveCapacity(count)
                for i in 0..<count {
                    builtKeys.append(src.key(state, i))
                }
                keys = builtKeys
                vState.lastKeys = builtKeys
                vState.lastKeysVersion = el.virtualRowsVersionHash
            }
        } else {
            count = el.children.count
            var childKeys: [String] = []
            childKeys.reserveCapacity(count)
            for (idx, child) in el.children.enumerated() {
                childKeys.append(child.keyId ?? "__vrow_\(idx)")
            }
            keys = childKeys
            vState.lastKeys = childKeys
            vState.lastKeysVersion = nil
        }

        let (prefix, total) = vState.computeOffsets(keys: keys, estimated: est)
        let vpPath = nextScrollPath ?? path
        let oldVpH = scrollViewportSizes[vpPath]?.y
        let oldRootH = flatNodes.first?.targetRect.height
        let vpH: Float
        if let oldVpH {
            if let oldRootH, abs(viewport.y - oldRootH) > 0.5, abs(oldVpH - oldRootH) < 0.5 {
                vpH = max(1, viewport.y)
            } else {
                vpH = max(1, oldVpH)
            }
        } else {
            vpH = max(1, viewport.y)
        }
        let isFirstMount = (scrollOffsets[vpPath] == nil && !wasPinnedToBottom.contains(vpPath))
        let stickyPin = nextStickBottom && (isFirstMount || wasPinnedToBottom.contains(vpPath))

        let vpScrollKey = vpPath.split(separator: "/").last.flatMap { $0.hasPrefix("@") ? String($0.dropFirst()) : nil }
        let hasPendingRevealForViewport = pendingScrollReveals.contains { req in
            req.scope == nil || req.scope == vpPath || req.scope == path
                || req.scope.map { selectsElementSelector($0, path: vpPath, key: vpScrollKey) } == true
        }
        var curOffsetY = scrollOffsets[vpPath]?.y ?? 0
        let scrolledSinceCommit = vState.lastCommittedOffsetY.map { abs($0 - curOffsetY) > 0.25 } ?? false
        if stickyPin {
            curOffsetY = max(0, total - vpH)
            scrollOffsets[vpPath] = Vec2(scrollOffsets[vpPath]?.x ?? 0, curOffsetY)
            wasPinnedToBottom.insert(vpPath)
        } else if curOffsetY > 0.5,
                  !scrolledSinceCommit,
                  let anchorKey = vState.lastAnchorKey,
                  !scrollRequestsState.owns(vpPath),
                  !directScrolledPaths.contains(vpPath),
                  !hasPendingRevealForViewport,
                  let anchorIdx = keys.firstIndex(of: anchorKey) {
            let expectedY = prefix[anchorIdx] + vState.lastAnchorLocalY
            if abs(expectedY - curOffsetY) > 0.25 {
                curOffsetY = max(0, min(max(0, total - vpH), expectedY))
                scrollOffsets[vpPath] = Vec2(scrollOffsets[vpPath]?.x ?? 0, curOffsetY)
                let nid = NodeId.hash("scroll:\(vpPath)")
                scrollStore.snap(nid, Props.SCROLL, to: scrollOffsets[vpPath] ?? .zero)
            }
        }

        var pinned: Set<Int> = []
        if let fk = focusedKey, let fi = keys.firstIndex(of: fk) {
            pinned.insert(fi)
        }
        let vpKey = nextScrollPath.flatMap { p -> String? in
            guard let tail = p.split(separator: "/").last, tail.hasPrefix("@") else { return nil }
            let raw = String(tail.dropFirst())
            return raw
        }
        for req in pendingScrollReveals where req.scope == nil
            || (nextScrollPath.map { selectsElementSelector(req.scope!, path: $0, key: vpKey) } ?? false)
            || req.scope == path {
            if let ri = keys.firstIndex(where: { Self.virtualRowMatchesSelector(rowKey: $0, virtualPath: path, selector: req.key) }) {
                pinned.insert(ri)
            }
        }
        for rev in scrollRequestsState.reveals where rev.viewport == vpPath {
            if let ri = keys.firstIndex(where: { Self.virtualRowMatchesSelector(rowKey: $0, virtualPath: path, selector: rev.key) }) {
                pinned.insert(ri)
            }
        }

        let mounted: Range<Int>
        let wantedMore: Bool
        let missing: Int
        if checkingLiveOnly && !vState.lastMountedRange.isEmpty {
            let lo = max(0, min(vState.lastMountedRange.lowerBound, count))
            let hi = max(lo, min(vState.lastMountedRange.upperBound, count))
            mounted = lo..<hi
            wantedMore = false
            missing = 0
        } else {
            (mounted, wantedMore, missing) = vState.overscanWindow(
                offset: curOffsetY,
                viewport: vpH,
                prefix: prefix,
                count: count,
                indexed: isIndexed,
                pinnedIndices: pinned,
                pinned: stickyPin
            )
        }

        // Track first visible anchor row for prepend/resize scroll preservation.
        let vis = vState.visibleRange(offset: curOffsetY, viewport: vpH, prefix: prefix, count: count)
        if !vis.isEmpty && !stickyPin {
            let ai = vis.lowerBound
            vState.lastAnchorKey = keys[ai]
            vState.lastAnchorLocalY = max(0, curOffsetY - prefix[ai])
        } else if stickyPin {
            vState.lastAnchorKey = nil
            vState.lastAnchorLocalY = 0
        }

        vState.lastMountedRange = mounted
        vState.wantsMoreFrames = wantedMore
        vState.missingOverscanRows = missing
        vState.isIndexed = isIndexed
        vState.lastCommittedOffsetY = curOffsetY
        virtualLists[path] = vState
        if !isIndexed {
            PerfWarn.overbuilt(path: path, site: el.virtualizeSite, built: count, mounted: mounted.count)
        }

        var built: [El<State>] = []
        let topSpacerH = mounted.lowerBound > 0 ? prefix[mounted.lowerBound] : 0
        let botSpacerH = mounted.upperBound < count ? max(0, total - prefix[mounted.upperBound]) : 0
        if topSpacerH > 0 {
            built.append(Self.virtualSpacer(key: "__v_top_spacer", height: topSpacerH))
        }

        let mountedKeys = mounted.map { keys[$0] }
        let currentMountedSnapshot = RuntimeVirtualListState.VirtualMountedSnapshot(
            mountedKeys: mountedKeys,
            range: mounted,
            topSpacerH: topSpacerH,
            botSpacerH: botSpacerH,
            padTop: el.layout.padding.top,
            padBottom: el.layout.padding.bottom
        )
        let priorSnapshotMatches = (vState.lastMountedSnapshot == currentMountedSnapshot)
        vState.lastMountedSnapshot = currentMountedSnapshot
        virtualLists[path]?.lastMountedSnapshot = currentMountedSnapshot

        let hasFocusedRow = !pinned.isEmpty || (focusedPath?.hasPrefix(path + "/") == true)
        let hasSelectionPin = hasUnmountedVirtualSelectionPin(listPath: path, keys: keys, mounted: mounted)
        let canReuseRows: Bool
        switch rowReuseMode {
        case .none:
            canReuseRows = false
        case .remount:
            canReuseRows = (remountRowCache != nil)
        case .rebuildRegion:
            canReuseRows = (remountRowCache != nil)
                && inReusableRegion
                && regionEnvHash == memoEnvHash
                && priorSnapshotMatches
                && !hasFocusedRow
                && !hasSelectionPin
        }

        ctx.selectionSources[path] = VirtualSelectionSource(
            listPath: path,
            keys: keys,
            mounted: mounted,
            isIndexed: isIndexed,
            source: el.virtualRowsSource,
            storedChildren: isIndexed ? [] : el.children,
            scrollAxes: el.layout.scrollAxes
        )
        var rowSeenKeys: [String: Int] = [:]
        for i in mounted {
            let rowKey = keys[i]
            var rowEl: El<State>
            var didReuseRow = false
            if isIndexed {
                if canReuseRows,
                   let reused = remountRowCache?[path]?[rowKey],
                   Self.isTreeReusableForRelayout(reused.el),
                   reused.holds(against: memoGeometry, envHash: memoEnvHash) {
                    self.memo.touchEntries(ids: reused.memoIds, pass: memoPass)
                    self.memo.appendViewReads(reused.reads + reused.trackedReads.memoReads, pass: memoPass)
                    reused.trackedReads.read()
                    rowEl = reused.el
                    didReuseRow = true
                    ctx.builtVirtualRows[path, default: [:]][rowKey] = reused
                } else {
                    let rowTouchedBox = MemoScope.TouchedIdsBox()
                    var builtEl = MemoScope.enterVirtualRow(
                        cache: self.memo,
                        envHash: memoEnvHash,
                        geometry: memoGeometry,
                        pass: memoPass,
                        touchedIdsOut: rowTouchedBox
                    ) {
                        el.virtualRowsSource!.build(state, i)
                    }
                    self.memo.appendViewReads(rowTouchedBox.reads + rowTouchedBox.trackedReads.memoReads, pass: memoPass)
                    if rowReuseMode == .remount && treeContainsVirtual(builtEl) {
                        ctx.remountHitNestedVirtual = true
                    }
                    builtEl = builtEl.key(rowKey)
                    rowEl = builtEl
                    ctx.builtVirtualRows[path, default: [:]][rowKey] = CachedVirtualRow(
                        el: rowEl,
                        memoIds: rowTouchedBox.ids,
                        reads: rowTouchedBox.reads,
                        trackedReads: rowTouchedBox.trackedReads,
                        envHash: memoEnvHash
                    )
                }
            } else {
                rowEl = el.children[i]
                if rowEl.keyId == nil {
                    rowEl = rowEl.key(rowKey)
                }
            }
            var walkSeen = rowSeenKeys
            let (rowSeg, _) = layoutPathSegment(
                keyId: rowEl.keyId,
                siblingIndex: built.count,
                siblingKeysSeen: &rowSeenKeys
            )
            ctx.rowMappings.append((listPath: path, scrollPath: vpPath, rowSegment: rowSeg, rowKey: keys[i]))
            virtualLists[path]?.rowKeyBySegment[rowSeg] = keys[i]
            walkVirtualSubtrees(
                &rowEl,
                parentPath: path,
                siblingIndex: built.count,
                siblingKeysSeen: &walkSeen,
                scrollPath: nextScrollPath,
                scrollStickBottom: nextStickBottom,
                remountRowCache: remountRowCache,
                rowReuseMode: rowReuseMode,
                inReusableRegion: didReuseRow ? inReusableRegion : false,
                regionEnvHash: didReuseRow ? regionEnvHash : 0,
                memoGeometry: memoGeometry,
                memoEnvHash: memoEnvHash,
                memoPass: memoPass,
                ctx: &ctx
            )
            built.append(rowEl)
        }

        if botSpacerH > 0 {
            built.append(Self.virtualSpacer(key: "__v_bot_spacer", height: botSpacerH))
        }
        if focusedPath != nil || focusedKey != nil {
            collectOffscreenFocusedVirtualInputs(
                el: el,
                path: path,
                keys: keys,
                count: count,
                mounted: mounted,
                isIndexed: isIndexed,
                rowKeyBySegment: vState.rowKeyBySegment,
                ctx: &ctx
            )
        }
        el.children = built
        el.virtualRowsSource = nil
    }

    /// Collects `editLens` inputs in rows of virtual list `path` scrolled out of the mounted window
    /// so the focused field survives being unmounted. Split out of `expandSingleVirtualNode` so its
    /// temporaries don't enlarge that frame on the row-build path (debug stack depth).
    @inline(never)
    private func collectOffscreenFocusedVirtualInputs(
        el: El<State>,
        path: String,
        keys: [String],
        count: Int,
        mounted: Range<Int>,
        isIndexed: Bool,
        rowKeyBySegment: [String: String],
        ctx: inout VirtualExpansionContext
    ) {
        var candidateIndices: [Int] = []
        if let fp = focusedPath, fp.hasPrefix(path + "/") {
            let rest = fp.dropFirst(path.count + 1)
            let rowSeg = String(rest.prefix(while: { $0 != "/" }))
            let rowKey = rowSeg.hasPrefix("@") ? String(rowSeg.dropFirst()) : rowSeg
            let baseRowKey = rowKey.components(separatedBy: "#dup").first ?? rowKey
            for i in 0..<count where !mounted.contains(i) {
                if keys[i] == rowKey || keys[i] == baseRowKey || keys[i] == rowKeyBySegment[rowSeg] {
                    candidateIndices.append(i)
                }
            }
        } else if let fp = focusedPath, let prev = virtualInputs[fp] {
            for i in 0..<count where !mounted.contains(i) && keys[i] == prev.rowKey {
                candidateIndices.append(i)
            }
        }
        if candidateIndices.isEmpty && !isIndexed {
            for i in 0..<count where !mounted.contains(i) {
                candidateIndices.append(i)
            }
        }
        for i in candidateIndices {
            var offEl = isIndexed ? el.virtualRowsSource!.build(state, i) : el.children[i]
            if isIndexed || offEl.keyId == nil {
                offEl = offEl.key(keys[i])
            }
            var seen: [String: Int] = [:]
            collectVirtualInputs(
                in: offEl,
                parentPath: path,
                siblingIndex: i,
                siblingKeysSeen: &seen,
                rowKey: keys[i],
                targetPath: focusedPath,
                targetKey: focusedKey,
                out: &ctx.virtualInputs
            )
        }
    }

    /// Top/bottom spacer standing in for unmounted virtual rows (kept out of line, see above).
    @inline(never)
    private static func virtualSpacer(key: String, height: Float) -> El<State> {
        El<State>().key(key).wFull().h(height)
    }

    private func collectVirtualInputs(
        in el: El<State>,
        parentPath: String,
        siblingIndex: Int,
        siblingKeysSeen: inout [String: Int],
        rowKey: String,
        targetPath: String?,
        targetKey: String?,
        out: inout [String: VirtualInputEntry]
    ) {
        let (seg, resolvedKey) = layoutPathSegment(
            keyId: el.keyId,
            siblingIndex: siblingIndex,
            siblingKeysSeen: &siblingKeysSeen
        )
        let path = "\(parentPath)/\(seg)"
        if el.handlers.editLens != nil,
           (path == targetPath || (targetKey != nil && (resolvedKey == targetKey || el.keyId == targetKey))) {
            out[path] = VirtualInputEntry(
                path: path,
                key: resolvedKey ?? el.keyId,
                rowKey: rowKey,
                el: el
            )
        }
        var childSeen: [String: Int] = [:]
        for idx in el.children.indices {
            collectVirtualInputs(
                in: el.children[idx],
                parentPath: path,
                siblingIndex: idx,
                siblingKeysSeen: &childSeen,
                rowKey: rowKey,
                targetPath: targetPath,
                targetKey: targetKey,
                out: &out
            )
        }
    }

    // MARK: - GrowthStack & FoldGlide

    internal func prepareGrowthStacksBeforeLayout(
        in rootEl: El<State>,
        cut: Bool,
        snaps: Bool,
        lands: Bool
    ) -> El<State> {
        let settleAll = cut || lands || reducedMotion
        var activeStackPaths: Set<String> = []

        @inline(never)
        func walk(
            _ el: El<State>,
            parentPath: String,
            siblingIndex: Int,
            siblingKeysSeen: inout [String: Int]
        ) -> El<State> {
            let (seg, _) = layoutPathSegment(keyId: el.keyId, siblingIndex: siblingIndex, siblingKeysSeen: &siblingKeysSeen)
            let path = parentPath.isEmpty ? (el.keyId.map { "/@\($0)" } ?? "/0") : "\(parentPath)/\(seg)"

            var out = el
            if let spec = el.growthSpec, el.virtualEstimate == nil, el.virtualRowsSource == nil {
                activeStackPaths.insert(path)
                out = mergeGrowthStackContainer(out, path: path, spec: spec, settleAll: settleAll, snaps: snaps)
            }

            if !out.children.isEmpty {
                var childSeen: [String: Int] = [:]
                var nextChildren: [El<State>] = []
                nextChildren.reserveCapacity(out.children.count)
                for idx in out.children.indices {
                    nextChildren.append(walk(out.children[idx], parentPath: path, siblingIndex: idx, siblingKeysSeen: &childSeen))
                }
                out.children = nextChildren
            }
            return out
        }

        var rootSeen: [String: Int] = [:]
        let result = walk(rootEl, parentPath: "", siblingIndex: 0, siblingKeysSeen: &rootSeen)
        if !kitHooks.growthStacks.isEmpty {
            kitHooks.growthStacks = kitHooks.growthStacks.filter { activeStackPaths.contains($0.key) }
        }
        return result
    }

    @inline(never)
    private func mergeGrowthStackContainer(
        _ el: El<State>,
        path: String,
        spec: GrowthSpec,
        settleAll: Bool,
        snaps: Bool
    ) -> El<State> {
        let prevStack = kitHooks.growthStacks[path]
        var nextStack = prevStack ?? KitGrowthStackState()
        nextStack.isNewStack = (prevStack == nil)
        nextStack.spacerPaths.removeAll(keepingCapacity: true)

        var newChildSegs: [String] = []
        var childSeen: [String: Int] = [:]
        for (cIdx, child) in el.children.enumerated() {
            let (cSeg, _) = layoutPathSegment(keyId: child.keyId, siblingIndex: cIdx, siblingKeysSeen: &childSeen)
            let isSpacer = (child.keyId == "__v_top_spacer" || child.keyId == "__v_bot_spacer") || child.isKitVirtualSpacer
            if !isSpacer {
                newChildSegs.append(cSeg)
            }
        }
        // RuntimeGrowthStackState (`growthStacks`) handles closing holds, foldGlide shuts, and monotonic runs.
        nextStack.order = newChildSegs
        nextStack.closing.removeAll()
        kitHooks.growthStacks[path] = nextStack
        return el
    }

    internal func syncClosingGrowthFrames(on scene: inout Scene) {
        guard !kitHooks.growthStacks.isEmpty else { return }
        for stack in kitHooks.growthStacks.values {
            for closing in stack.closing.values {
                guard let spacerPath = stack.spacerPaths[closing.nodeId],
                      let spacerIdx = nodeByPath[spacerPath] else {
                    continue
                }
                let spacerLocal = flatNodes[spacerIdx].localRect
                let orig = closing.originalLocalRect
                let shifted = MotionRect.fromXYWH(orig.x, spacerLocal.y, orig.width, orig.height)
                if var snap = exitingSnapshots[closing.nodeId] {
                    snap.localRect = shifted
                    exitingSnapshots[closing.nodeId] = snap
                }
                scene.setFrame(closing.nodeId, shifted, .instant)
            }
        }
    }

    internal func updateGrowthRowsPostLayout(
        rootResult: LayoutEngine.ResultNode,
        rootEl: El<State>,
        cut: Bool,
        snaps: Bool,
        lands: Bool,
        isRelayoutPass: Bool = false,
        reducedMotionOverride: Bool? = nil,
        at now: Double
    ) -> GrowthCaptureResult {
        var result = GrowthCaptureResult()
        var seenGrowthKeys: Set<String> = []
        var seenStackPaths: Set<String> = []
        var seenStackOrder: [String] = []
        var existedStackPaths: Set<String> = []
        var stackNewIds: [String: [String]] = [:]
        var stackOpened: [String: [String]] = [:]
        let settleAll = cut || lands || (reducedMotionOverride ?? reducedMotion)

        var stackFoldEffects: [String: StackFoldEffect] = [:]

        func findFoldHiddenAbove(
            foldEl: El<State>,
            foldRes: LayoutEngine.ResultNode,
            foldPath: String,
            targetHeight: Float
        ) -> (above: Float, headerPath: String)? {
            guard !scrollRequestsState.keeps.isEmpty, viewCommitCount > 1, !stuckShiftsByPath.isEmpty else {
                return nil
            }
            let prefix = foldPath + "/"
            guard let hold = scrollRequestsState.keeps.compactMap(\.hold).first(where: { $0.path.hasPrefix(prefix) }) else {
                return nil
            }
            func findHeaderRelBottom(el: El<State>, res: LayoutEngine.ResultNode, path: String, relY: Float) -> Float? {
                if path == hold.path {
                    return relY + res.layout.localRect.height
                }
                var childSeen: [String: Int] = [:]
                let count = min(el.children.count, res.children.count)
                for i in 0..<count {
                    let (seg, _) = layoutPathSegment(keyId: el.children[i].keyId, siblingIndex: i, siblingKeysSeen: &childSeen)
                    let childPath = "\(path)/\(seg)"
                    if hold.path == childPath || hold.path.hasPrefix(childPath + "/") {
                        let nextRelY = relY + res.children[i].layout.localRect.y
                        if let found = findHeaderRelBottom(el: el.children[i], res: res.children[i], path: childPath, relY: nextRelY) {
                            return found
                        }
                    }
                }
                return nil
            }
            guard let hdrRelBottom = findHeaderRelBottom(el: foldEl, res: foldRes, path: foldPath, relY: 0) else {
                return nil
            }
            if targetHeight > hdrRelBottom + 0.5 {
                return nil
            }
            guard let stuckShift = stuckShiftsByPath[hold.path]?.y, stuckShift > 0.5 else {
                return nil
            }
            return (stuckShift, hold.path)
        }

        func foldLimit(path: String, enclosingScrollPath: String?) -> Float {
            guard let vpPath = enclosingScrollPath,
                  let vpRect = presentedRectByPath[vpPath] ?? nodeByPath[vpPath].map({ flatNodes[$0].targetRect }),
                  let rowRect = presentedRectByPath[path] ?? nodeByPath[path].map({ flatNodes[$0].targetRect }) else {
                return .infinity
            }
            return max(0, vpRect.bottom - rowRect.top)
        }

        func findLastRevealWrappedText(
            in el: El<State>,
            res: LayoutEngine.ResultNode
        ) -> (el: El<State>, res: LayoutEngine.ResultNode)? {
            var found: (el: El<State>, res: LayoutEngine.ResultNode)? = nil
            if el.textStyle.wrap != .noWrap && (el.plainText != nil || el.richSpans != nil || el.liveText != nil) {
                let hasReveal = ((el.runtimeExtras["shell.revealWordFade"] as? Float).map { $0 >= 0 } ?? false) || el.textReveal >= 0.0
                if hasReveal {
                    found = (el, res)
                }
            }
            let count = min(el.children.count, res.children.count)
            for i in 0..<count {
                if let sub = findLastRevealWrappedText(in: el.children[i], res: res.children[i]) {
                    found = sub
                }
            }
            return found
        }

        // Iterative traversal + `@inline(never)` keep `-Onone` stack frames small on deep trees (avoiding 512KB Cooperative thread SIGBUS).
        @inline(never)
        func stepGrowthNode(
            el: El<State>,
            res: LayoutEngine.ResultNode,
            path: String,
            inGrowthSpec: GrowthSpec?,
            parentStackPath: String?,
            enclosingScrollPath: String?
        ) -> String? {
            var ownStackPath = parentStackPath
            if el.growthSpec != nil {
                if seenStackPaths.insert(path).inserted {
                    seenStackOrder.append(path)
                }
                ownStackPath = path
                let stackWidth = res.layout.localRect.width
                let existed = growthStacks[path] != nil
                if existed {
                    existedStackPaths.insert(path)
                }
                var stack = growthStacks[path] ?? RuntimeGrowthStackState(width: stackWidth, widthHold: .off)
                if !existed || settleAll {
                    stack.widthHold = .off
                    stack.pendingHeights.removeAll(keepingCapacity: true)
                } else if abs(stackWidth - stack.width) > 0.25 {
                    stack.widthHold = .rewrap(at: now)
                }
                stack.width = stackWidth
                stack.gap = el.layout.rowGap
                if let gs = el.growthSpec {
                    stack.spring = gs.spring
                    stack.edge = gs.edge
                }
                growthStacks[path] = stack
            }

            let isVirtualSpacer = (el.keyId == "__v_top_spacer" || el.keyId == "__v_bot_spacer") || el.isKitVirtualSpacer
            if !isVirtualSpacer && (inGrowthSpec != nil || el.foldGlideSpec != nil) {
                let gKey = el.foldGlideSpec != nil ? "fold:\(path)" : "growth:\(path)"
                seenGrowthKeys.insert(gKey)
                if let sp = parentStackPath {
                    stackNewIds[sp, default: []].append(gKey)
                    growthStacks[sp]?.closing.removeValue(forKey: gKey)
                }
                let unlaggedH = res.layout.localRect.height
                var naturalH = unlaggedH
                let edge: StreamEdge = el.growthSpec?.edge ?? inGrowthSpec?.edge ?? .feather
                let spring: Spring = el.growthSpec?.spring ?? inGrowthSpec?.spring ?? Growth.spring
                let limit = el.foldGlideSpec != nil ? foldLimit(path: path, enclosingScrollPath: enclosingScrollPath) : .infinity
                let glideArg: (FoldGlide, Float)? = el.foldGlideSpec.map { ($0, limit) }
                let streaming = el.isStreaming
                let whole = el.isArrivesWhole && !streaming
                let firstChildTop = res.children.first?.layout.localRect.y

                if streaming && growthRows[gKey] != nil && !settleAll {
                    if let (tEl, tRes) = findLastRevealWrappedText(in: el, res: res) {
                        let resolved = ElDisplayResolver.resolveText(
                            el: tEl,
                            rawText: tEl.liveText?.get() ?? tEl.plainText,
                            isSecure: tEl.isSecure
                        )
                        if resolved.style.wrap == .wrap {
                            let innerW = max(0, tRes.layout.localRect.width - tEl.layout.padding.left - tEl.layout.padding.right)
                            let scale = max(1.0, pixelScale)
                            let shaped = resolved.shape(
                                using: textSystem,
                                maxWidth: innerW > 0 ? innerW : nil,
                                pixelScale: scale,
                                emitGlyphs: false
                            )
                            let lag = TextLineMetrics.streamHeightLag(
                                lineCount: shaped.lineCount,
                                lineHeightPx: shaped.lineMetricHeightPt(shaped.lineCount - 1) * scale,
                                lineAdvancePx: shaped.lastLineAdvancePx,
                                hangingAdvancePx: shaped.hangingAdvancePx,
                                widthPx: innerW * scale,
                                scale: scale
                            )
                            naturalH = max(0, unlaggedH - lag)
                        }
                    }
                }

                let instantGrowth = settleAll || el.hasInstantChanges || (snaps && el.foldGlideSpec == nil && !streaming && !whole)
                if var existing = growthRows[gKey] {
                    let prevTarget = existing.track.target
                    let prevH = existing.track.h
                    let prevTop = existing.lastFirstChildTop
                    let givingBeforeRetarget = existing.track.give != nil
                    existing.edge = edge
                    existing.spring = spring
                    existing.foldLimit = limit
                    existing.naturalHeight = unlaggedH
                    existing.track.setKind(streaming: streaming, whole: whole, glide: glideArg)
                    let hiddenInfo = el.foldGlideSpec != nil
                        ? findFoldHiddenAbove(foldEl: el, foldRes: res, foldPath: path, targetHeight: naturalH)
                        : nil
                    if instantGrowth {
                        existing.track = existing.track.restarted(at: naturalH)
                        existing.withheld = 0
                        existing.lastWidth = res.layout.localRect.width
                        existing.contentSlide = nil
                        if let sp = parentStackPath {
                            growthStacks[sp]?.pendingHeights.removeValue(forKey: gKey)
                        }
                    } else {
                        let holdState = parentStackPath.flatMap { growthStacks[$0]?.widthHold } ?? .off
                        var effectiveH = (streaming && !isRelayoutPass && holdState.mayShrink(at: now))
                            ? max(naturalH, min(existing.track.h, existing.track.target))
                            : naturalH
                        if streaming && abs(res.layout.localRect.width - existing.lastWidth) < 0.01 {
                            effectiveH = max(effectiveH, min(existing.track.h, existing.track.target))
                        }
                        existing.lastWidth = res.layout.localRect.width
                        existing.withheld = max(0, unlaggedH - effectiveH)
                        if let sp = parentStackPath, holdState.defers(at: now) {
                            if abs(effectiveH - existing.track.target) > 0.1 || growthStacks[sp]?.pendingHeights[gKey] != nil {
                                growthStacks[sp]?.pendingHeights[gKey] = effectiveH
                            }
                        } else {
                            if let sp = parentStackPath {
                                growthStacks[sp]?.pendingHeights.removeValue(forKey: gKey)
                            }
                            if abs(existing.track.target - effectiveH) > 1e-4 {
                                let shutting = effectiveH < prevTarget - 1e-4
                                let reopening = el.foldGlideSpec != nil
                                    && effectiveH > prevTarget + 1e-4
                                    && (existing.track.currentLift() > 0 || (existing.track.glide != nil && prevTarget > 1e-4))
                                existing.track.retarget(effectiveH)
                                if let (above, header) = hiddenInfo, shutting && existing.track.isShuttingFold {
                                    let effectKey = parentStackPath ?? "__root"
                                    var eff = stackFoldEffects[effectKey] ?? StackFoldEffect(scrollPath: enclosingScrollPath)
                                    if eff.scrollPath == nil { eff.scrollPath = enclosingScrollPath }
                                    eff.held.append((gKey: gKey, below: max(0, prevH - existing.track.h)))
                                    eff.hiddenCut += existing.track.hideAbove(above)
                                    stackFoldEffects[effectKey] = eff
                                    result.foldHeaderUpdates.append((foldKey: gKey, headerPath: header))
                                } else if reopening {
                                    let effectKey = parentStackPath ?? "__root"
                                    var eff = stackFoldEffects[effectKey] ?? StackFoldEffect(scrollPath: enclosingScrollPath)
                                    if eff.scrollPath == nil { eff.scrollPath = enclosingScrollPath }
                                    eff.reopened.append((foldPath: path, giving: givingBeforeRetarget))
                                    stackFoldEffects[effectKey] = eff
                                }
                                if let prevTop, let curTop = firstChildTop {
                                    let topDelta = curTop - prevTop
                                    let was = effectiveH - prevH
                                    if topDelta * (effectiveH - prevTarget) > 0.01 && abs(was) > 0.01 {
                                        let curSlide: Float
                                        if let oldSlide = existing.contentSlide, abs(oldSlide.was) > 0.01 {
                                            let oldLeft = prevTarget - prevH
                                            curSlide = oldSlide.dy * min(1, max(0, oldLeft / oldSlide.was))
                                        } else {
                                            curSlide = 0
                                        }
                                        existing.contentSlide = (was: was, dy: curSlide - topDelta)
                                    }
                                }
                            }
                        }
                    }
                    if !existing.track.moving {
                        existing.contentSlide = nil
                    }
                    existing.lastFirstChildTop = firstChildTop
                    growthRows[gKey] = existing
                    if existing.track.moving {
                        result.activeCount += 1
                    }
                    let hasStreamingLagClamp = streaming && (existing.track.h < unlaggedH - 0.1 || existing.withheld > 0.01)
                    let holdsFoldLift = existing.track.isShut && !existing.track.moving && existing.track.currentLift() > 0 && foldRowHoldsExiting(rowPath: path)
                    if (existing.track.moving && (abs(existing.track.h - existing.track.target) > 1e-4 || existing.track.isShuttingFold))
                        || hasStreamingLagClamp
                        || holdsFoldLift {
                        result.needsClampedRelayout = true
                    }
                } else {
                    let revealedInCommit = enclosingScrollPath.map { sp in
                        let sKey = sp.split(separator: "/").last.flatMap { $0.hasPrefix("@") ? String($0.dropFirst()) : nil }
                        return pendingScrollReveals.contains { req in
                            req.scope == nil || req.scope == sp || req.scope.map { selectsElementSelector($0, path: sp, key: sKey) } == true
                        }
                    } ?? false
                    let stackExisted = (inGrowthSpec != nil) ? !(kitHooks.growthStacks[parentStackPath ?? ""]?.isNewStack ?? true) : (viewCommitCount > 1)
                    if !settleAll && !cut && !snaps && viewCommitCount > 1 && el.foldGlideSpec != nil,
                       let sp = parentStackPath, existedStackPaths.contains(sp) {
                        stackOpened[sp, default: []].append(gKey)
                    }
                    let startsFromZero = !instantGrowth
                        && !revealedInCommit
                        && (whole || streaming)
                        && (stackExisted || (viewCommitCount > 1 && streaming))
                    var track: GrowTrack
                    if startsFromZero {
                        track = GrowTrack.settled(0)
                        track.setKind(streaming: streaming, whole: whole, glide: glideArg)
                        track.retarget(naturalH)
                        if kitHooks.frameGrowthStepDt > 0 && el.foldGlideSpec == nil {
                            let steps = max(1, min(240, Int(floor(kitHooks.frameGrowthStepDt / Double(Growth.substep)))))
                            for _ in 0..<steps {
                                track.step(spring: spring, edge: edge, carryingTail: false)
                            }
                        }
                        result.needsClampedRelayout = true
                        result.activeCount += 1
                    } else {
                        track = GrowTrack.settled(naturalH)
                        track.setKind(streaming: streaming, whole: whole, glide: glideArg)
                    }
                    growthRows[gKey] = RuntimeGrowthEntry(
                        track: track,
                        edge: edge,
                        spring: spring,
                        foldLimit: limit,
                        naturalHeight: unlaggedH,
                        withheld: 0,
                        lastWidth: res.layout.localRect.width,
                        lastFirstChildTop: firstChildTop,
                        contentSlide: nil
                    )
                }
            }
            return ownStackPath
        }

        let rootPath = rootEl.keyId.map { "/@\($0)" } ?? "/0"
        var workStack: [(
            el: El<State>,
            res: LayoutEngine.ResultNode,
            path: String,
            inGrowthSpec: GrowthSpec?,
            parentStackPath: String?,
            enclosingScrollPath: String?
        )] = [
            (
                el: rootEl,
                res: rootResult,
                path: rootPath,
                inGrowthSpec: nil,
                parentStackPath: nil,
                enclosingScrollPath: nil
            )
        ]
        while let item = workStack.popLast() {
            let ownStackPath = stepGrowthNode(
                el: item.el,
                res: item.res,
                path: item.path,
                inGrowthSpec: item.inGrowthSpec,
                parentStackPath: item.parentStackPath,
                enclosingScrollPath: item.enclosingScrollPath
            )
            let nextGrowth = item.el.growthSpec
            let nextScrollPath = item.el.layout.scrollAxes.isEmpty ? item.enclosingScrollPath : item.path
            if !item.el.children.isEmpty && item.el.children.count == item.res.children.count {
                var childSeen: [String: Int] = [:]
                var childPaths: [String] = []
                childPaths.reserveCapacity(item.el.children.count)
                for i in 0..<item.el.children.count {
                    let (seg, _) = layoutPathSegment(keyId: item.el.children[i].keyId, siblingIndex: i, siblingKeysSeen: &childSeen)
                    childPaths.append("\(item.path)/\(seg)")
                }
                for i in (0..<item.el.children.count).reversed() {
                    workStack.append((
                        el: item.el.children[i],
                        res: item.res.children[i],
                        path: childPaths[i],
                        inGrowthSpec: nextGrowth,
                        parentStackPath: ownStackPath,
                        enclosingScrollPath: nextScrollPath
                    ))
                }
            }
        }
        for (_, eff) in stackFoldEffects {
            guard let vpPath = eff.scrollPath else { continue }
            if eff.hiddenCut > 0,
               let cur = scrollOffsets[vpPath],
               let maxExt = scrollMaxExtents[vpPath] {
                scrollOffsets[vpPath] = Vec2(cur.x, max(0, cur.y - eff.hiddenCut))
                scrollMaxExtents[vpPath] = Vec2(maxExt.x, max(0, maxExt.y - eff.hiddenCut))
                result.scrollCuts.append((viewport: vpPath, cut: eff.hiddenCut))
            }
            if !eff.held.isEmpty {
                let curY = scrollOffsets[vpPath]?.y ?? 0
                let maxY = scrollMaxExtents[vpPath]?.y ?? 0
                let belowSum = eff.held.reduce(0) { $0 + $1.below }
                let slack = (maxY - curY) - belowSum
                let travel: Float = eff.held.compactMap { growthRows[$0.gKey] }.reduce(0) { $0 + ($1.track.h - $1.track.target) }
                if travel > 1.0 && slack < travel {
                    let share = 1.0 - max(0, slack) / travel
                    for (gKey, _) in eff.held {
                        growthRows[gKey]?.track.give = share
                    }
                }
            }
            for re in eff.reopened {
                let isPinned = wasPinnedToBottom.contains(vpPath)
                if isPinned || re.giving {
                    result.foldOpens.append(PendingFoldOpen(
                        viewport: vpPath,
                        foldPrefix: re.foldPath,
                        giving: re.giving,
                        pinned: isPinned
                    ))
                    let shown: Float = {
                        guard let rowRect = presentedRectByPath[re.foldPath] ?? nodeByPath[re.foldPath].map({ flatNodes[$0].targetRect }),
                              let vpRect = presentedRectByPath[vpPath] ?? nodeByPath[vpPath].map({ flatNodes[$0].targetRect }) else {
                            return 0
                        }
                        let scale = nodeByPath[vpPath].map { flatNodes[$0].inheritedScale }.flatMap { $0 > 1e-4 ? $0 : nil } ?? 1.0
                        return max(0, (rowRect.top - vpRect.top) / scale)
                    }()
                    let gKey = "fold:\(re.foldPath)"
                    if var entry = growthRows[gKey] {
                        let below = max(0, entry.track.target - entry.track.h - entry.track.currentLift())
                        entry.track.rideUp(shown + below)
                        growthRows[gKey] = entry
                        result.needsClampedRelayout = true
                    }
                }
            }
        }
        for sp in seenStackOrder {
            guard var stack = growthStacks[sp] else { continue }
            let newIds = stackNewIds[sp] ?? []
            let newSet = Set(newIds)
            let existed = existedStackPaths.contains(sp) && viewCommitCount > 1
            let isVirtual = (virtualLists[sp] != nil)
            var order: [String] = []
            order.reserveCapacity(newIds.count + 4)
            var shut: [String] = []
            var ni = 0
            for old in stack.order {
                if newSet.contains(old) {
                    while ni < newIds.count && newIds[ni] != old {
                        if !order.contains(newIds[ni]) {
                            order.append(newIds[ni])
                        }
                        ni += 1
                    }
                    if !order.contains(old) {
                        order.append(old)
                    }
                    ni += 1
                } else {
                    let oldPath = old.hasPrefix("fold:") ? String(old.dropFirst(5)) : (old.hasPrefix("growth:") ? String(old.dropFirst(7)) : old)
                    // Upstream `apply.rs`: `is_virtual && unseen_ids.contains(old)` — a virtual row that drew
                    // nothing on the last paint (scrolled past, overscan) leaves at once instead of holding its height.
                    let virtualUnseen = isVirtual && (presentedRectByPath[oldPath] == nil
                        || nodeByPath[oldPath].map { unseenPresence.currentPaintUnseenIds.contains(flatNodes[$0].nodeId) } ?? true)
                    if let entry = growthRows[old],
                       entry.track.h > 0.01,
                       existed,
                       !settleAll,
                       !virtualUnseen {
                        let hold: Double = (entry.track.glide != nil) ? 0.0 : 0.15
                        if entry.track.glide != nil && stack.closing[old] == nil {
                            shut.append(old)
                        }
                        if stack.closing[old] == nil {
                            stack.closing[old] = now + hold
                        }
                        seenGrowthKeys.insert(old)
                        order.append(old)
                    } else {
                        stack.closing.removeValue(forKey: old)
                    }
                }
            }
            while ni < newIds.count {
                if !order.contains(newIds[ni]) {
                    order.append(newIds[ni])
                }
                ni += 1
            }
            stack.order = order
            if !settleAll && existed {
                linkGrowthRuns(stack: &stack, order: order, opened: stackOpened[sp] ?? [], shut: shut)
                if !stack.runs.isEmpty || !shut.isEmpty {
                    result.activeCount += 1
                }
            } else {
                stack.runs.removeAll(keepingCapacity: true)
            }
            growthStacks[sp] = stack
        }

        growthRows = growthRows.filter { seenGrowthKeys.contains($0.key) }
        growthStacks = growthStacks.compactMap { (k, v) -> (String, RuntimeGrowthStackState)? in
            guard seenStackPaths.contains(k) else { return nil }
            var copy = v
            copy.pendingHeights = copy.pendingHeights.filter { seenGrowthKeys.contains($0.key) }
            copy.closing = copy.closing.filter { seenGrowthKeys.contains($0.key) }
            return (k, copy)
        }.reduce(into: [:]) { $0[$1.0] = $1.1 }
        if lastGrowthStepTime == nil {
            lastGrowthStepTime = now
        }
        return result
    }

    private func linkGrowthRuns(
        stack: inout RuntimeGrowthStackState,
        order: [String],
        opened: [String],
        shut: [String]
    ) {
        var keptRuns: [RuntimeGrowthRun] = []
        keptRuns.reserveCapacity(stack.runs.count)
        for var run in stack.runs {
            if run.commit(order: order, grows: &growthRows) {
                keptRuns.append(run)
            }
        }
        stack.runs = keptRuns
        for k in shut {
            if var g = growthRows[k] {
                g.track.retarget(0)
                growthRows[k] = g
            }
        }
        for set in [opened, shut] where !set.isEmpty {
            let setKeys = Set(set)
            var block: [String] = []
            func foldSig(_ e: RuntimeGrowthEntry) -> (Spring?, Float?) {
                (e.track.glide, e.track.feather)
            }
            func flushBlock() {
                if block.count > 1, let run = RuntimeGrowthRun.link(keys: block, grows: growthRows) {
                    stack.runs.append(run)
                }
                block.removeAll(keepingCapacity: true)
            }
            for k in order {
                let eligibleEntry: RuntimeGrowthEntry? = setKeys.contains(k) ? growthRows[k].flatMap { e in
                    (e.track.glide != nil && !e.track.isStaged && e.track.currentLift() == 0) ? e : nil
                } : nil
                if let e = eligibleEntry {
                    if let lastKey = block.last, let lastE = growthRows[lastKey], foldSig(lastE) != foldSig(e) {
                        flushBlock()
                    }
                    block.append(k)
                } else {
                    flushBlock()
                }
            }
            flushBlock()
        }
    }

    private static func stepGrowthRuns(
        stack: inout RuntimeGrowthStackState,
        grows: inout [String: RuntimeGrowthEntry],
        steps: Int,
        spring: Spring,
        edge: StreamEdge
    ) -> Set<String> {
        var movedKeys: Set<String> = []
        var kept: [RuntimeGrowthRun] = []
        kept.reserveCapacity(stack.runs.count)
        for var run in stack.runs {
            _ = run.step(steps: steps, spring: spring, edge: edge, grows: &grows)
            for k in run.rows {
                movedKeys.insert(k)
            }
            if run.moving {
                kept.append(run)
            }
        }
        stack.runs = kept
        return movedKeys
    }

    internal func applyGrowthConstraints(in rootEl: El<State>) -> El<State> {
        func findLastRevealingWrappedText(
            el: El<State>,
            res: LayoutEngine.ResultNode
        ) -> (El<State>, LayoutEngine.ResultNode)? {
            if !el.children.isEmpty && el.children.count == res.children.count {
                for i in el.children.indices.reversed() {
                    if let match = findLastRevealingWrappedText(el: el.children[i], res: res.children[i]) {
                        return match
                    }
                }
            }
            if el.textStyle.wrap != .noWrap,
               el.textReveal >= 0.0,
               (el.liveText != nil || el.plainText != nil || el.richSpans != nil) {
                return (el, res)
            }
            return nil
        }

        func walk(_ el: El<State>, parentPath: String, siblingIndex: Int, siblingKeysSeen: inout [String: Int], inGrowthSpec: GrowthSpec?) -> El<State> {
            let (seg, _) = layoutPathSegment(keyId: el.keyId, siblingIndex: siblingIndex, siblingKeysSeen: &siblingKeysSeen)
            let path = parentPath.isEmpty ? (el.keyId.map { "/@\($0)" } ?? "/0") : "\(parentPath)/\(seg)"
            var out = el

            let isVirtualSpacer = (el.keyId == "__v_top_spacer" || el.keyId == "__v_bot_spacer") || el.isKitVirtualSpacer
            if !isVirtualSpacer && (inGrowthSpec != nil || el.foldGlideSpec != nil) {
                let gKey = el.foldGlideSpec != nil ? "fold:\(path)" : "growth:\(path)"
                if let entry = growthRows[gKey] {
                    let t = entry.track
                    let diff = abs(t.h - t.target)
                    let hasStreamingLagClamp = el.isStreaming && (t.h < entry.naturalHeight - 0.1 || entry.withheld > 0.01)
                    let landedFoldExiting = (el.foldGlideSpec != nil && t.isShut && !t.moving && foldRowHoldsExiting(rowPath: path))
                    let clampCollapse = (el.foldGlideSpec != nil && t.h > t.target + 0.1) || t.isShuttingFold || landedFoldExiting
                    let overflows = entry.edge.overflow && (t.streaming || t.isPaced)
                    if t.moving || hasStreamingLagClamp || landedFoldExiting {
                        if t.h < t.target - 1e-4 || hasStreamingLagClamp || clampCollapse || diff > 1e-4 {
                            out.layout.height = .points(max(0, t.h))
                            out.layout.maxHeight = .points(max(0, t.h))
                            if entry.edge.clip && !overflows {
                                out.layout.clipOverflow = true
                            }
                        }
                        if (t.moving || landedFoldExiting) && entry.edge.clip && !overflows {
                            let withheldMask: Float = entry.withheld > 0.01 ? min(entry.withheld, entry.edge.floor) : 0
                            let combinedMask = max(t.mask, withheldMask)
                            let featherH: Float
                            if combinedMask > 0.5 {
                                featherH = combinedMask
                            } else if let fg = el.foldGlideSpec?.feather, diff > 0.25 {
                                featherH = fg
                            } else {
                                featherH = 0
                            }
                            if featherH > 0.5 {
                                out = out.clipFadeLinear(bottom: min(featherH, max(1, t.h)))
                            }
                        }
                    }
                }
            }

            let nextGrowth = el.growthSpec
            if !el.children.isEmpty {
                var childSeen: [String: Int] = [:]
                out.children = el.children.enumerated().map { idx, ch in
                    walk(ch, parentPath: path, siblingIndex: idx, siblingKeysSeen: &childSeen, inGrowthSpec: nextGrowth)
                }
            }
            return out
        }
        var rootSeen: [String: Int] = [:]
        return walk(rootEl, parentPath: "", siblingIndex: 0, siblingKeysSeen: &rootSeen, inGrowthSpec: nil)
    }

    internal func advanceGrowthRows(at now: Double, markRelayoutDirty: Bool = true) -> Bool {
        var flushedHold = false
        let prevNow = lastGrowthStepTime
        let hasDeferredAtEnd = growthStacks.values.contains { !$0.pendingHeights.isEmpty || !$0.closing.isEmpty || !$0.runs.isEmpty }
        let hasClosing = kitHooks.growthStacks.values.contains { !$0.closing.isEmpty }
        let dt = prevNow.map { max(0, min(0.1, now - $0)) } ?? (1.0 / 60.0)
        lastGrowthStepTime = now

        func flushReleasedHolds(at checkTime: Double) {
            for (sp, var stack) in growthStacks {
                var dirtyStack = false
                if !stack.pendingHeights.isEmpty && !stack.widthHold.defers(at: checkTime) {
                    for (gKey, pendingH) in stack.pendingHeights {
                        if var entry = growthRows[gKey], abs(entry.track.target - pendingH) > 0.1 {
                            entry.track.retarget(pendingH)
                            growthRows[gKey] = entry
                            flushedHold = true
                        }
                    }
                    stack.pendingHeights.removeAll(keepingCapacity: true)
                    dirtyStack = true
                }
                for (gKey, closeAt) in stack.closing where checkTime >= closeAt {
                    if var entry = growthRows[gKey], entry.track.target > 0.0 {
                        if reducedMotion {
                            entry.track = GrowTrack.settled(0)
                        } else {
                            entry.track.retarget(0)
                        }
                        growthRows[gKey] = entry
                        flushedHold = true
                    }
                }
                if dirtyStack {
                    growthStacks[sp] = stack
                }
            }
        }

        if growthRows.isEmpty && !hasDeferredAtEnd && !hasClosing {
            growthSubstepAccumulator = 0
            return false
        }

        if dt <= 0 {
            flushReleasedHolds(at: now)
            if flushedHold && markRelayoutDirty {
                needsCommit = true
                pendingGrowthRelayout = true
            }
            let hasPending = growthStacks.values.contains { !$0.pendingHeights.isEmpty || !$0.closing.isEmpty || !$0.runs.isEmpty }
            let closingMoving = kitHooks.growthStacks.values.contains { $0.closing.values.contains { $0.track.moving } }
            return hasPending || growthRows.values.contains { $0.track.moving } || closingMoving
        }

        let stepSize = GrowthCaps.fixedSubstep
        growthSubstepAccumulator += dt
        var substeps = Int(floor((growthSubstepAccumulator + 1e-9) / stepSize))
        growthSubstepAccumulator = max(0, growthSubstepAccumulator - Double(substeps) * stepSize)
        substeps = min(substeps, 240)

        let stepOrigin = (prevNow ?? (now - dt))
        let startHeights = growthRows.mapValues { $0.track.h }
        var anyChanged = false
        var anyMoving = false
        var restored: [(gKey: String, r: Float)] = []
        var gave: [(gKey: String, d: Float)] = []
        if substeps > 0 {
            var working = growthRows
            var workingStacks = growthStacks
            let initialHeights: [String: Float] = working.mapValues { $0.track.h }
            let initialMasks: [String: Float] = working.mapValues { $0.track.mask }
            let initiallyMoving: [String: Bool] = working.mapValues { $0.track.moving }
            var ranInBlockKeys: Set<String> = []
            for s in 0..<substeps {
                let subNow = stepOrigin + Double(s + 1) * stepSize
                var substepRunKeys: Set<String> = []
                for (sp, var stack) in workingStacks {
                    if !stack.pendingHeights.isEmpty && !stack.widthHold.defers(at: subNow) {
                        for (gKey, pendingH) in stack.pendingHeights {
                            if var entry = working[gKey], abs(entry.track.target - pendingH) > 0.1 {
                                entry.track.retarget(pendingH)
                                working[gKey] = entry
                                flushedHold = true
                            }
                        }
                        stack.pendingHeights.removeAll(keepingCapacity: true)
                    }
                    for (gKey, closeAt) in stack.closing where subNow >= closeAt {
                        if var entry = working[gKey], entry.track.target > 0.0 {
                            if reducedMotion {
                                entry.track = GrowTrack.settled(0)
                            } else {
                                entry.track.retarget(0)
                            }
                            working[gKey] = entry
                            flushedHold = true
                        }
                    }
                    if !stack.runs.isEmpty {
                        let movedRunKeys = Self.stepGrowthRuns(
                            stack: &stack,
                            grows: &working,
                            steps: 1,
                            spring: stack.spring,
                            edge: stack.edge
                        )
                        substepRunKeys.formUnion(movedRunKeys)
                        ranInBlockKeys.formUnion(movedRunKeys)
                    }
                    workingStacks[sp] = stack
                }
                for (k, var entry) in working {
                    if substepRunKeys.contains(k) { continue }
                    let wasMoving = entry.track.moving
                    if !wasMoving && entry.track.h == entry.track.target && entry.track.v == 0 {
                        continue
                    }
                    let prevH = entry.track.h
                    let prevM = entry.track.mask
                    entry.track.step(spring: entry.spring, edge: entry.edge, carryingTail: false)
                    if !entry.track.moving {
                        entry.contentSlide = nil
                    }
                    working[k] = entry
                    if abs(entry.track.h - prevH) > 1e-5 || abs(entry.track.mask - prevM) > 1e-5 || (wasMoving && !entry.track.moving) {
                        anyChanged = true
                    }
                }
            }
            for k in ranInBlockKeys {
                guard let entry = working[k] else { continue }
                let h0 = initialHeights[k] ?? entry.track.h
                let m0 = initialMasks[k] ?? entry.track.mask
                let wasM = initiallyMoving[k] ?? false
                if abs(entry.track.h - h0) > 0.05 || abs(entry.track.mask - m0) > 0.05 || (wasM && !entry.track.moving) {
                    anyChanged = true
                }
            }
            for (sp, var stack) in workingStacks where !stack.closing.isEmpty {
                let prevOrderCount = stack.order.count
                stack.order.removeAll { k in
                    let keep = stack.closing[k] == nil || working[k].map { $0.track.h > 0.01 || $0.track.target > 0 } ?? false
                    if !keep {
                        working.removeValue(forKey: k)
                    }
                    return !keep
                }
                if stack.order.count != prevOrderCount {
                    anyChanged = true
                }
                stack.closing = stack.closing.filter { stack.order.contains($0.key) }
                workingStacks[sp] = stack
            }
            for (k, var entry) in working {
                let r = entry.track.restore
                if r > 0 {
                    entry.track.restore = 0
                    restored.append((gKey: k, r: r))
                }
                if let share = entry.track.give, let h0 = initialHeights[k] {
                    let d = (h0 - entry.track.h) * share
                    if abs(d) > 1e-6 {
                        gave.append((gKey: k, d: d))
                    }
                }
                if !entry.track.moving && entry.track.give != nil {
                    entry.track.give = nil
                }
                working[k] = entry
            }
            growthStacks = workingStacks
            growthRows = working
            anyMoving = growthRows.contains { k, entry in
                entry.track.moving || abs(entry.track.h - (startHeights[k] ?? entry.track.h)) > 1e-5
            } || growthStacks.values.contains { !$0.runs.isEmpty }
        }
        for (gKey, r) in restored where gKey.hasPrefix("fold:") {
            let rowPath = String(gKey.dropFirst(5))
            if let ri = nodeByPath[rowPath],
               let sIdx = flatNodes[ri].enclosingVScrollIndex {
                let vpPath = flatNodes[sIdx].path
                if !wasPinnedToBottom.contains(vpPath) {
                    let scale = flatNodes[sIdx].inheritedScale
                    let cur = scrollOffsets[vpPath] ?? .zero
                    let next = Vec2(cur.x, cur.y + r)
                    scrollOffsets[vpPath] = next
                    let maxOld = scrollMaxExtents[vpPath] ?? .zero
                    scrollMaxExtents[vpPath] = Vec2(maxOld.x, max(maxOld.y, next.y))
                    let vpNid = NodeId.hash("scroll:\(vpPath)")
                    scrollStore.snap(vpNid, Props.SCROLL, to: next)
                    for idx in scrollRequestsState.keeps.indices where scrollRequestsState.keeps[idx].viewport == vpPath {
                        if let kIdx = nodeByPath[scrollRequestsState.keeps[idx].path], kIdx <= ri {
                            scrollRequestsState.keeps[idx].was -= r * scale
                        }
                    }
                }
            }
        }
        for (gKey, d) in gave {
            if let headerPath = foldHeaders[gKey] {
                for idx in scrollRequestsState.keeps.indices where scrollRequestsState.keeps[idx].hold?.path == headerPath {
                    let vpPath = scrollRequestsState.keeps[idx].viewport
                    let scale = nodeByPath[vpPath].map { flatNodes[$0].inheritedScale } ?? 1.0
                    scrollRequestsState.keeps[idx].was += d * scale
                }
            }
        }
        flushReleasedHolds(at: now)
        if hasClosing {
            for (stackPath, var stack) in kitHooks.growthStacks where !stack.closing.isEmpty {
                var finished: [String] = []
                for (seg, var row) in stack.closing {
                    let prevH = row.track.h
                    for _ in 0..<substeps {
                        row.track.step(spring: row.spring, edge: row.edge, carryingTail: false)
                    }
                    if abs(row.track.h - prevH) > 0.05 || !row.track.moving {
                        anyChanged = true
                    }
                    if !row.track.moving && row.track.h <= 0.01 {
                        finished.append(seg)
                    } else {
                        anyMoving = true
                        stack.closing[seg] = row
                    }
                }
                for seg in finished {
                    stack.closing.removeValue(forKey: seg)
                    stack.order.removeAll { $0 == seg }
                }
                kitHooks.growthStacks[stackPath] = stack
            }
        }
        let hasPendingHold = growthStacks.values.contains { !$0.pendingHeights.isEmpty || !$0.closing.isEmpty || !$0.runs.isEmpty }
        if (anyChanged || flushedHold) && markRelayoutDirty {
            needsCommit = true
            pendingGrowthRelayout = true
        }
        return anyMoving || hasPendingHold
    }

    // MARK: - Post-Commit Virtual Measurements & onVisibleRows

    internal func recordVirtualMeasurementsAndCallbacks(
        expansion: VirtualExpansionContext,
        at now: Double
    ) {
        for mapping in expansion.rowMappings {
            let rowPath = "\(mapping.listPath)/\(mapping.rowSegment)"
            guard let rIdx = nodeByPath[rowPath] else { continue }
            let h = flatNodes[rIdx].targetRect.height
            if h > 0.5 && virtualLists[mapping.listPath]?.measuredByKey[mapping.rowKey] != h {
                virtualLists[mapping.listPath]?.measuredByKey[mapping.rowKey] = h
            }
        }

        for listPath in activeVirtualPaths {
            guard var vState = virtualLists[listPath] else { continue }
            let est = max(1, (nodeByPath[listPath].flatMap { flatNodes[$0].el.virtualEstimate }) ?? 40)
            let scrollIdx = nodeByPath[listPath].flatMap {
                !flatNodes[$0].el.layout.scrollAxes.isEmpty ? $0 : flatNodes[$0].enclosingVScrollIndex
            }
            let scrollPath = scrollIdx.map { flatNodes[$0].path } ?? listPath
            let vpH = max(1, scrollViewportSizes[scrollPath]?.y ?? viewport.y)
            let offsetY = scrollOffsets[scrollPath]?.y ?? 0
            let (prefix, _) = vState.computeOffsets(keys: vState.lastKeys, estimated: est)
            let vis = vState.visibleRange(offset: offsetY, viewport: vpH, prefix: prefix, count: vState.lastKeys.count)

            let prevVis = vState.lastVisibleRange
            vState.lastVisibleRange = vis
            let stickyPin = nodeByPath[scrollPath].map { flatNodes[$0].el.layout.stickBottom } == true
                && wasPinnedToBottom.contains(scrollPath)
            if !vis.isEmpty && !stickyPin {
                let ai = vis.lowerBound
                vState.lastAnchorKey = vState.lastKeys[ai]
                vState.lastAnchorLocalY = max(0, offsetY - prefix[ai])
            } else if stickyPin {
                vState.lastAnchorKey = nil
                vState.lastAnchorLocalY = 0
            }
            if vState.measuredByKey.count > RuntimeVirtualListState.maxCachedKeys {
                let keepSet = Set(vState.lastKeys)
                vState.pruneMeasurements(keeping: keepSet)
            }
            vState.lastCommittedOffsetY = offsetY
            virtualLists[listPath] = vState

            if prevVis != vis,
               let lIdx = nodeByPath[listPath],
               let onVis = flatNodes[lIdx].el.handlers.onVisibleRows {
                let tx = makeTx(at: now)
                let changed: Bool
                if let scope = turnScope {
                    var res = false
                    scope(&state) { s in res = onVis(&s, vis) }
                    changed = res
                } else {
                    changed = onVis(&state, vis)
                }
                if changed {
                    applyTx(tx, at: now, markDirtyIfNotLiveOnly: true)
                }
            }
        }
    }

    /// Re-anchors and expands active virtual lists after a full measure pass when newly measured
    /// row heights shift the scroll anchor or overflow the mounted overscan window (`measure.rs:135`).
    internal func prepareVirtualRemeasureAfterFullPass(
        _ pass: MeasurePassResult,
        savedVirtuals: [String: RuntimeVirtualListState],
        savedScrollOffsets: [String: Vec2],
        savedScrollMaxExtents: [String: Vec2],
        savedScrollViewportSizes: [String: Vec2],
        savedScrollContentSizes: [String: Vec2],
        savedWasPinned: Set<String>,
        savedGrowthRows: [String: RuntimeGrowthEntry]
    ) -> Bool {
        guard pass.virtualExpansion.anyVirtualList else { return false }
        var heightsByList: [String: [String: Float]] = [:]
        for mapping in pass.virtualExpansion.rowMappings {
            let rowPath = "\(mapping.listPath)/\(mapping.rowSegment)"
            guard let rIdx = pass.byPath[rowPath] else { continue }
            let h = pass.nodes[rIdx].targetRect.height
            if h > 0.5 {
                heightsByList[mapping.listPath, default: [:]][mapping.rowKey] = h
            }
        }

        var updatedLists: [String: RuntimeVirtualListState] = [:]
        var updatedScrollYs: [String: Float] = [:]
        for listPath in activeVirtualPaths {
            guard let vBefore = savedVirtuals[listPath],
                  var vAfter = virtualLists[listPath],
                  vBefore.lastKeys == vAfter.lastKeys,
                  !vBefore.lastMountedRange.isEmpty else {
                continue
            }
            let scrollIdx = pass.byPath[listPath].flatMap {
                !pass.nodes[$0].el.layout.scrollAxes.isEmpty ? $0 : pass.nodes[$0].enclosingVScrollIndex
            }
            let scrollPath = scrollIdx.map { pass.nodes[$0].path } ?? listPath
            let scrollKey = scrollIdx.flatMap { pass.nodes[$0].key }
            let hasPendingReveal = pendingScrollReveals.contains { req in
                req.scope == nil || req.scope == scrollPath || req.scope == listPath
                    || req.scope.map { selectsElementSelector($0, path: scrollPath, key: scrollKey) } == true
            }
            if scrollRequestsState.owns(scrollPath) || directScrolledPaths.contains(scrollPath) || hasPendingReveal {
                continue
            }
            let est = max(1, (pass.byPath[listPath].flatMap { pass.nodes[$0].el.virtualEstimate }) ?? 40)
            let vpH = scrollIdx.map { max(1, pass.nodes[$0].targetRect.height) } ?? max(1, viewport.y)
            let stickyPin = scrollIdx.map { pass.nodes[$0].el.layout.stickBottom } == true
                && savedWasPinned.contains(scrollPath)
            let (prefixBefore, _) = vBefore.computeOffsets(keys: vBefore.lastKeys, estimated: est)
            let oldY = savedScrollOffsets[scrollPath]?.y ?? 0
            let visBefore = vBefore.visibleRange(offset: oldY, viewport: vpH, prefix: prefixBefore, count: vBefore.lastKeys.count)

            if let measured = heightsByList[listPath] {
                for (rk, h) in measured {
                    vAfter.measuredByKey[rk] = h
                }
            }
            let (prefixAfter, totalAfter) = vAfter.computeOffsets(keys: vAfter.lastKeys, estimated: est)
            let nextY: Float
            if stickyPin {
                nextY = max(0, totalAfter - vpH)
            } else if let aIdx = visBefore.isEmpty ? nil : visBefore.lowerBound,
                      aIdx < prefixBefore.count,
                      aIdx < prefixAfter.count {
                let delta = prefixAfter[aIdx] - prefixBefore[aIdx]
                nextY = max(0, min(max(0, totalAfter - vpH), oldY + delta))
                vAfter.lastAnchorKey = vAfter.lastKeys[aIdx]
                vAfter.lastAnchorLocalY = max(0, oldY - prefixBefore[aIdx])
            } else {
                nextY = oldY
            }
            let shifted = abs(nextY - oldY) > 0.05
            let windowShort = vAfter.needsWindow(offset: nextY, viewport: vpH, prefix: prefixAfter, count: vAfter.lastKeys.count, pinned: stickyPin)
            if shifted || windowShort {
                updatedLists[listPath] = vAfter
                if shifted {
                    updatedScrollYs[scrollPath] = nextY
                }
            }
        }
        guard !updatedLists.isEmpty else { return false }

        virtualLists = savedVirtuals
        scrollOffsets = savedScrollOffsets
        scrollMaxExtents = savedScrollMaxExtents
        scrollViewportSizes = savedScrollViewportSizes
        scrollContentSizes = savedScrollContentSizes
        wasPinnedToBottom = savedWasPinned
        growthRows = savedGrowthRows
        for (lp, vl) in updatedLists {
            virtualLists[lp] = vl
        }
        for (sp, ny) in updatedScrollYs {
            let nextOff = Vec2(scrollOffsets[sp]?.x ?? 0, ny)
            scrollOffsets[sp] = nextOff
            scrollStore.snap(NodeId.hash("scroll:\(sp)"), Props.SCROLL, to: nextOff)
        }
        return true
    }

    internal func stepVirtualFillAfterCommit(now: Double) {
        var wanted = false
        var missing = 0
        var moved = false
        for listPath in activeVirtualPaths {
            guard var vState = virtualLists[listPath], vState.isIndexed else { continue }
            let scrollIdx = nodeByPath[listPath].flatMap {
                !flatNodes[$0].el.layout.scrollAxes.isEmpty ? $0 : flatNodes[$0].enclosingVScrollIndex
            }
            let scrollPath = scrollIdx.map { flatNodes[$0].path } ?? listPath
            let curScroll = scrollOffsets[scrollPath] ?? .zero
            let vpH = max(1, scrollViewportSizes[scrollPath]?.y ?? viewport.y)
            let est = max(1, (nodeByPath[listPath].flatMap { flatNodes[$0].el.virtualEstimate }) ?? 40)
            let count = vState.lastKeys.count
            let (prefix, _) = vState.computeOffsets(keys: vState.lastKeys, estimated: est)
            let stickyPin = scrollIdx.map { flatNodes[$0].el.layout.stickBottom } == true
                && wasPinnedToBottom.contains(scrollPath)
            let (listWanted, listMissing) = vState.fillDemand(
                offset: curScroll.y,
                viewport: vpH,
                prefix: prefix,
                count: count,
                pinned: stickyPin
            )
            vState.wantsMoreFrames = listWanted
            vState.missingOverscanRows = listMissing
            virtualLists[listPath] = vState
            if listWanted {
                wanted = true
                missing += listMissing
            }
            if let prevScroll = virtualFillLastScrollOffsets[scrollPath], abs(curScroll.y - prevScroll.y) > 0.5 {
                moved = true
            }
            virtualFillLastScrollOffsets[scrollPath] = curScroll
        }

        lastVirtualFillWanted = wanted
        lastVirtualFillMissing = missing
        lastVirtualFillMoved = moved

        let effect = virtualFill.step(.frame(now: now, wanted: wanted, missing: missing, moved: moved))
        if effect == .draw {
            virtualFillNeedsCommit = true
        }
        virtualFillWantsDraw = (effect == .draw)
    }

    // MARK: - Scroll Requests, FollowEdge & Scroll Callbacks

    internal func computeScrollFadeSpec(for node: FlatNode) -> EdgeFadeSpec? {
        let el = node.el
        guard el.scrollEdgeFadeWidth > 0 || el.scrollFadeStyle.end != nil else { return nil }
        guard !el.layout.scrollAxes.isEmpty else { return nil }
        let curScroll = scrollOffsets[node.path] ?? .zero
        let maxExt = scrollMaxExtents[node.path] ?? .zero
        let baseW = el.scrollEdgeFadeWidth
        let style = el.scrollFadeStyle
        let (startStyle, startW) = style.edge(width: baseW, end: false)
        let (endStyle, endW) = style.edge(width: baseW, end: true)
        let hidTop = style.endOnly ? 0 : curScroll.y
        let hidBot = max(0, maxExt.y - curScroll.y)
        let rawLeft = curScroll.x
        let rawRight = max(0, maxExt.x - curScroll.x)
        let (rtlLeft, rtlRight) = (node.flow == .rtl) ? (rawRight, rawLeft) : (rawLeft, rawRight)
        let hidLeft = style.endOnly ? 0 : rtlLeft
        let hidRight = rtlRight

        let topRamp: (width: Float, offset: Float) = (el.layout.scrollAxes.contains(.vertical) && hidTop > 0.5 && startW > 0)
            ? ScrollEdgeMath.edgeRamp(style: startStyle, width: startW, hidden: Double(hidTop), scale: 1.0)
            : (0, 0)
        let botRamp: (width: Float, offset: Float) = (el.layout.scrollAxes.contains(.vertical) && hidBot > 0.5 && endW > 0)
            ? ScrollEdgeMath.edgeRamp(style: endStyle, width: endW, hidden: Double(hidBot), scale: 1.0)
            : (0, 0)
        let leftRamp: (width: Float, offset: Float) = (el.layout.scrollAxes.contains(.horizontal) && hidLeft > 0.5 && startW > 0)
            ? ScrollEdgeMath.edgeRamp(style: startStyle, width: startW, hidden: Double(hidLeft), scale: 1.0)
            : (0, 0)
        let rightRamp: (width: Float, offset: Float) = (el.layout.scrollAxes.contains(.horizontal) && hidRight > 0.5 && endW > 0)
            ? ScrollEdgeMath.edgeRamp(style: endStyle, width: endW, hidden: Double(hidRight), scale: 1.0)
            : (0, 0)

        guard abs(topRamp.width) > 0.05 || abs(botRamp.width) > 0.05 || abs(leftRamp.width) > 0.05 || abs(rightRamp.width) > 0.05 else {
            return nil
        }
        return EdgeFadeSpec(
            rect: intersectRects(node.clipRect, node.targetRect),
            widths: SIMD4<Float>(leftRamp.width, topRamp.width, rightRamp.width, botRamp.width),
            strengths: SIMD4<Float>(repeating: 1.0),
            packedOffsets: SIMD4<Float>(leftRamp.offset, topRamp.offset, rightRamp.offset, botRamp.offset),
            scrollPath: node.path,
            belowSticky: style.belowSticky
        )
    }

    internal func shiftFlatAndSpecsForScrollDeltas(
        _ deltasByScrollPath: [String: Vec2],
        specs: inout [NodeSpec]
    ) {
        guard !deltasByScrollPath.isEmpty, specs.count == flatNodes.count else { return }
        var cumulative = Array(repeating: Vec2.zero, count: flatNodes.count)
        for i in flatNodes.indices {
            if let pIdx = flatNodes[i].parentIndex {
                let p = flatNodes[pIdx]
                let pEl = p.el
                let ownDelta = deltasByScrollPath[p.path] ?? .zero
                let signedOwnX = (p.flow == .rtl) ? ownDelta.x : -ownDelta.x
                let inv = Vec2(cumulative[pIdx].x + signedOwnX, cumulative[pIdx].y - ownDelta.y)
                cumulative[i] = inv
                if inv != .zero {
                    flatNodes[i].targetRect = flatNodes[i].targetRect.offsetBy(inv)
                    specs[i].rect = specs[i].rect.offsetBy(inv)
                }
                let parentClips = pEl.layout.clipOverflow || pEl.clipRadius != nil || pEl.clipCorners != nil || pEl.clipFade != nil
                flatNodes[i].clipRect = parentClips ? intersectRects(p.clipRect, p.targetRect) : p.clipRect
                if inv != .zero {
                    if var ownSF = flatNodes[i].ownScrollFade {
                        ownSF.rect = intersectRects(flatNodes[i].clipRect, flatNodes[i].targetRect)
                        flatNodes[i].ownScrollFade = ownSF
                    }
                    if var ownCF = flatNodes[i].ownClipFade {
                        ownCF.rect = intersectRects(flatNodes[i].clipRect, flatNodes[i].targetRect)
                        flatNodes[i].ownClipFade = ownCF
                    }
                }
                var inheritedFades = p.activeClipFades
                if let pSF = flatNodes[pIdx].ownScrollFade {
                    inheritedFades.append(pSF)
                }
                if let pCF = flatNodes[pIdx].ownClipFade {
                    inheritedFades.append(pCF)
                }
                flatNodes[i].activeClipFades = inheritedFades
            }
            if deltasByScrollPath[flatNodes[i].path] != nil {
                flatNodes[i].ownScrollFade = computeScrollFadeSpec(for: flatNodes[i])
            }
            nodeById[flatNodes[i].nodeId] = flatNodes[i]
        }
    }

    internal func captureKeepAnchorsBeforeCommit() {
        let drawnRect: (FlatNode) -> MotionRect = { node in
            self.presentedRectByPath[node.path] ?? node.targetRect
        }

        // `El.scrollAnchor`: anchor the first visible non-sticky row when viewport is scrolled off top.
        var anchorPaths: [String] = []
        if !flatNodes.isEmpty {
            for sIdx in flatNodes.indices {
                let sNode = flatNodes[sIdx]
                guard sNode.el.scrollAnchorEnabled,
                      sNode.el.layout.scrollAxes.contains(.vertical) else { continue }
                let sPath = sNode.path
                if activeVirtualPaths.contains(sPath) { continue }
                if scrollRequestsState.owns(sPath) { continue }
                let curY = scrollOffsets[sPath]?.y ?? 0
                let scrollNid = NodeId.hash("scroll:" + sPath)
                if curY <= 0.5
                    || wasPinnedToBottom.contains(sPath)
                    || scrollGlidingPaths.contains(sPath)
                    || directScrolledPaths.contains(sPath)
                    || scrollStore.isAnimating(scrollNid, Props.SCROLL) {
                    continue
                }
                let vpRect = drawnRect(sNode)
                var parentIdx = sIdx
                var foundRowPath: String? = nil
                while true {
                    let children = flatNodes.indices.filter { flatNodes[$0].parentIndex == parentIdx }
                    guard let childIdx = children.first(where: { j in
                        let r = drawnRect(flatNodes[j])
                        return r.width > 0 && r.height > 0
                            && r.bottom > vpRect.top + 0.5
                            && r.top < vpRect.bottom
                            && flatNodes[j].el.stickyConfig == nil
                    }) else {
                        break
                    }
                    let cNode = flatNodes[childIdx]
                    if activeVirtualPaths.contains(cNode.path) { break }
                    let r = drawnRect(cNode)
                    let hasChildren = flatNodes.contains { $0.parentIndex == childIdx }
                    if r.top < vpRect.top - 0.5 && hasChildren {
                        parentIdx = childIdx
                        continue
                    }
                    foundRowPath = cNode.path
                    break
                }
                if let rowPath = foundRowPath {
                    anchorPaths.append(rowPath)
                }
            }
        }

        let explicitKeeps = pendingKeepOnScreenKeys
        pendingKeepOnScreenKeys.removeAll(keepingCapacity: true)
        let allKeepKeys = anchorPaths + explicitKeeps
        guard !allKeepKeys.isEmpty, !flatNodes.isEmpty else { return }

        for key in allKeepKeys {
            guard let tIdx = flatNodes.firstIndex(where: { selectsElementSelector(key, path: $0.path, key: $0.key) }) else {
                continue
            }
            // Find enclosing vertical viewport.
            var cur = flatNodes[tIdx].parentIndex
            var vIdxOpt: Int? = nil
            while let ci = cur {
                if flatNodes[ci].el.layout.scrollAxes.contains(.vertical) {
                    vIdxOpt = ci
                    break
                }
                cur = flatNodes[ci].parentIndex
            }
            guard let vIdx = vIdxOpt else { continue }
            let vpRect = drawnRect(flatNodes[vIdx])
            let tRect = drawnRect(flatNodes[tIdx])

            var hold: ScrollKeepHold? = nil
            var anc = flatNodes[tIdx].parentIndex ?? tIdx
            var checkIdx: Int? = tIdx
            while let hIdx = checkIdx, hIdx != vIdx {
                let hNode = flatNodes[hIdx]
                if case .top = hNode.el.stickyConfig?.edge,
                   abs(stuckShiftsByPath[hNode.path]?.y ?? 0) > 0.01 {
                    let hRect = drawnRect(hNode)
                    hold = ScrollKeepHold(path: hNode.path, inset: hRect.top - vpRect.top)
                    break
                }
                checkIdx = hNode.parentIndex
                anc = checkIdx ?? vIdx
            }
            _ = anc

            var virtualRow: (listPath: String, rowKey: String, yInRow: Float)? = nil
            var rCheck: Int? = tIdx
            while let rIdx = rCheck, rIdx != vIdx {
                if let listIdx = flatNodes[rIdx].parentIndex,
                   activeVirtualPaths.contains(flatNodes[listIdx].path),
                   let rKey = flatNodes[rIdx].key {
                    virtualRow = (
                        listPath: flatNodes[listIdx].path,
                        rowKey: rKey,
                        yInRow: flatNodes[tIdx].targetRect.top - flatNodes[rIdx].targetRect.top
                    )
                    break
                }
                rCheck = flatNodes[rIdx].parentIndex
            }

            scrollRequestsState.arriveCapture(ScrollKeep(
                path: flatNodes[tIdx].path,
                viewport: flatNodes[vIdx].path,
                was: tRect.top - vpRect.top,
                virtualRow: virtualRow,
                hold: hold
            ))
        }
    }

    internal func applyKeepCompensation(
        at now: Double,
        cut: Bool,
        specs: inout [NodeSpec]
    ) -> [String: Vec2] {
        guard !scrollRequestsState.isEmpty else { return [:] }
        let givingHeaders: Set<String> = Set(foldHeaders.compactMap { gKey, headerPath in
            guard let entry = growthRows[gKey], let share = entry.track.give else { return nil }
            return (entry.track.h - entry.track.target) * (1 - share) < 0.5 ? headerPath : nil
        })
        scrollRequestsState.stepEndTakesOver(
            givingHeaders: givingHeaders,
            isPinned: { wasPinnedToBottom.contains($0) }
        )

        var keepDeltas: [String: Vec2] = [:]
        for k in scrollRequestsState.keeps {
            guard let vIdx = flatNodes.firstIndex(where: { $0.path == k.viewport && $0.el.layout.scrollAxes.contains(.vertical) }) else {
                continue
            }
            let vNode = flatNodes[vIdx]
            let vPath = vNode.path
            let cur = scrollOffsets[vPath] ?? .zero
            let maxExt = scrollMaxExtents[vPath] ?? .zero

            let currentRelTop: Float
            if let tIdx = flatNodes.firstIndex(where: { $0.path == k.path }) {
                currentRelTop = flatNodes[tIdx].targetRect.top - vNode.targetRect.top
            } else if let vr = k.virtualRow,
                      let vState = virtualLists[vr.listPath],
                      let listIdx = flatNodes.firstIndex(where: { $0.path == vr.listPath }),
                      let rowIdx = vState.lastKeys.firstIndex(of: vr.rowKey) {
                let est = Float(flatNodes[listIdx].el.virtualEstimate ?? 40)
                let prefixY: Float = (0..<rowIdx).reduce(0) { sum, idx in
                    sum + vState.rowHeight(forKey: vState.lastKeys[idx], estimated: est)
                }
                let laidRowTop = flatNodes[listIdx].targetRect.top + prefixY + vr.yInRow
                currentRelTop = laidRowTop - vNode.targetRect.top
            } else {
                continue
            }

            let delta = currentRelTop - k.was
            if abs(delta) < (1.0 / 64.0) { continue }
            let toY = max(0, min(maxExt.y, cur.y + delta))
            if abs(toY - cur.y) < 1e-5 { continue }

            let next = Vec2(cur.x, toY)
            let nid = NodeId.hash("scroll:\(vPath)")
            scrollStore.snap(nid, Props.SCROLL, to: next)
            scrollOffsets[vPath] = next
            scrollGlidingPaths.remove(vPath)
            keepDeltas[vPath] = Vec2(0, toY - cur.y)
            if vNode.el.layout.stickBottom && delta >= 0 && maxExt.y > 0.5 && abs(toY - maxExt.y) <= 1.0 {
                wasPinnedToBottom.insert(vPath)
            } else if toY < maxExt.y - 1.0 {
                wasPinnedToBottom.remove(vPath)
            }
        }

        if !keepDeltas.isEmpty {
            shiftFlatAndSpecsForScrollDeltas(keepDeltas, specs: &specs)
        }

        scrollRequestsState.stepEndClamps { k in
            guard let tIdx = flatNodes.firstIndex(where: { $0.path == k.path }) else { return .unmounted }
            var cur = flatNodes[tIdx].parentIndex
            var vIdxOpt: Int? = nil
            while let ci = cur {
                if flatNodes[ci].el.layout.scrollAxes.contains(.vertical) {
                    vIdxOpt = ci
                    break
                }
                cur = flatNodes[ci].parentIndex
            }
            guard let vIdx = vIdxOpt else { return .loose }
            let vPath = flatNodes[vIdx].path
            if !wasPinnedToBottom.contains(vPath) { return .free }
            return .pinned(flatNodes[tIdx].targetRect.top - flatNodes[vIdx].targetRect.top)
        }

        let isRevealTargetMounted: (ScrollRevealTarget) -> Bool = { target in
            self.flatNodes.contains { selectsElementSelector(target.key, path: $0.path, key: $0.key) }
                || self.highlightTargetWithNode(selector: target.key, scrolled: true) != nil
        }
        if cut {
            scrollRequestsState.stepFinish(
                gliding: { scrollGlidingPaths.contains($0) },
                animating: { _ in false },
                mounted: isRevealTargetMounted
            )
        } else {
            scrollRequestsState.stepFinish(
                gliding: { scrollGlidingPaths.contains($0) },
                animating: { vPath in
                    !growthRows.isEmpty || scrollGlidingPaths.contains(vPath)
                },
                mounted: isRevealTargetMounted
            )
        }

        return keepDeltas
    }

    internal func processScrollRequestsAndCallbacks(at now: Double, cut: Bool, followEdge: Bool, snaps: Bool = false) {
        func nodeMatchesScope(_ idx: Int, scopeKey: String?) -> Bool {
            guard let scopeKey else { return true }
            var walk: Int? = idx
            while let wi = walk {
                if selectsElementSelector(scopeKey, path: flatNodes[wi].path, key: flatNodes[wi].key) {
                    return true
                }
                walk = flatNodes[wi].parentIndex
            }
            return false
        }

        func findScrollViewportIndex(forNode idx: Int, scopeKey: String?, verticalOnly: Bool = false) -> Int? {
            var cur = flatNodes[idx].parentIndex
            while let ci = cur {
                let axes = flatNodes[ci].el.layout.scrollAxes
                let matchesAxis = verticalOnly ? axes.contains(.vertical) : !axes.isEmpty
                if matchesAxis {
                    if nodeMatchesScope(ci, scopeKey: scopeKey) {
                        return ci
                    }
                }
                cur = flatNodes[ci].parentIndex
            }
            return nil
        }

        func findScrollNode(bySelector selector: String) -> Int? {
            if let idx = flatNodes.firstIndex(where: {
                !$0.el.layout.scrollAxes.isEmpty && selectsElementSelector(selector, path: $0.path, key: $0.key)
            }) {
                return idx
            }
            if let targetIdx = flatNodes.firstIndex(where: {
                selectsElementSelector(selector, path: $0.path, key: $0.key)
            }) {
                return findScrollViewportIndex(forNode: targetIdx, scopeKey: nil)
            }
            return nil
        }

        func applyScrollOffset(path: String, next: Vec2, glide: Spring?) {
            let maxExt = scrollMaxExtents[path] ?? .zero
            let clamped = Vec2(
                max(0, min(maxExt.x, next.x)),
                max(0, min(maxExt.y, next.y))
            )
            let nid = NodeId.hash("scroll:\(path)")
            if let glide, !cut && !reducedMotion {
                let start = scrollOffsets[path] ?? .zero
                if scrollStore.get(nid, Props.SCROLL) == nil {
                    scrollStore.snap(nid, Props.SCROLL, to: start)
                }
                scrollStore.set(nid, Props.SCROLL, to: clamped, anim: .spring(glide), at: now)
                scrollGlidingPaths.insert(path)
                scrollOffsets[path] = start
            } else {
                scrollStore.snap(nid, Props.SCROLL, to: clamped)
                scrollOffsets[path] = clamped
                scrollGlidingPaths.remove(path)
                frameInstantScrollKey = path
                clearScrollHandGliding(path: path)
            }
            if maxExt.y > 0.5 && abs(clamped.y - maxExt.y) <= 1.0 {
                wasPinnedToBottom.insert(path)
            } else {
                wasPinnedToBottom.remove(path)
            }
        }

        if followEdge {
            for i in flatNodes.indices where !flatNodes[i].el.layout.scrollAxes.isEmpty && flatNodes[i].el.layout.stickBottom {
                let path = flatNodes[i].path
                let maxExt = scrollMaxExtents[path] ?? .zero
                scrollRequestsState.stepNewTail(viewport: path, key: flatNodes[i].key ?? path)
                clearScrollHandGliding(path: path)
                applyScrollOffset(path: path, next: Vec2(scrollOffsets[path]?.x ?? 0, maxExt.y), glide: cut ? nil : MotionTokens.GLIDE)
            }
        }

        let reveals = pendingScrollReveals
        pendingScrollReveals.removeAll(keepingCapacity: true)
        let bottoms = pendingScrollBottoms
        pendingScrollBottoms.removeAll(keepingCapacity: true)
        let pages = pendingScrollPages
        pendingScrollPages.removeAll(keepingCapacity: true)
        let offsets = pendingScrollOffsets
        pendingScrollOffsets.removeAll(keepingCapacity: true)

        let followCaret = pendingCaretFollow
        pendingCaretFollow = false
        let destination = !bottoms.isEmpty || !pages.isEmpty || !offsets.isEmpty
        if !reveals.isEmpty || destination || followCaret {
            scrollRequestsState.stepCancel()
        }

        for req in reveals {
            let vIdx: Int
            let vPath: String
            let cur: Vec2
            let vpH: Double
            let itemH: Double
            let itemTop: Double

            if let tIdx = flatNodes.indices.first(where: {
                nodeMatchesScope($0, scopeKey: req.scope)
                    && selectsElementSelector(req.key, path: flatNodes[$0].path, key: flatNodes[$0].key)
            }),
               let foundVIdx = findScrollViewportIndex(forNode: tIdx, scopeKey: req.scope) {
                vIdx = foundVIdx
                vPath = flatNodes[vIdx].path
                let vpRect = flatNodes[vIdx].targetRect
                let tRect = flatNodes[tIdx].targetRect
                cur = scrollOffsets[vPath] ?? .zero
                vpH = Double(vpRect.height)
                itemH = Double(tRect.height)
                itemTop = Double(tRect.y - vpRect.y) + Double(cur.y)
            } else if let hlHit = highlightTargetWithNode(selector: req.key, scrolled: true),
                      let foundVIdx = findScrollViewportIndex(forNode: hlHit.nodeIndex, scopeKey: req.scope) {
                vIdx = foundVIdx
                vPath = flatNodes[vIdx].path
                let vpRect = flatNodes[vIdx].targetRect
                cur = scrollOffsets[vPath] ?? .zero
                vpH = Double(vpRect.height)
                itemH = Double(hlHit.rect.height)
                itemTop = Double(hlHit.rect.y - vpRect.y) + Double(cur.y)
            } else {
                var resolved: (vIdx: Int, itemTop: Double, itemH: Double, cur: Vec2)? = nil
                for (listIdx, node) in flatNodes.enumerated() where nodeMatchesScope(listIdx, scopeKey: req.scope) {
                    guard let vState = virtualLists[node.path],
                          let rowIdx = vState.lastKeys.firstIndex(where: {
                              Self.virtualRowMatchesSelector(rowKey: $0, virtualPath: node.path, selector: req.key)
                          }) else { continue }
                    let candidateVIdx: Int?
                    if !node.el.layout.scrollAxes.isEmpty && nodeMatchesScope(listIdx, scopeKey: req.scope) {
                        candidateVIdx = listIdx
                    } else {
                        candidateVIdx = findScrollViewportIndex(forNode: listIdx, scopeKey: req.scope)
                    }
                    guard let foundVIdx = candidateVIdx else { continue }
                    let est = Float(node.el.virtualEstimate ?? 40)
                    let prefixY: Float = (0..<rowIdx).reduce(0) { sum, idx in
                        sum + vState.rowHeight(forKey: vState.lastKeys[idx], estimated: est)
                    }
                    let rowH = vState.rowHeight(forKey: vState.lastKeys[rowIdx], estimated: est)
                    let vpNode = flatNodes[foundVIdx]
                    let c = scrollOffsets[vpNode.path] ?? .zero
                    let top = Double(node.targetRect.top + prefixY - vpNode.targetRect.y) + Double(c.y)
                    resolved = (foundVIdx, top, Double(rowH), c)
                    break
                }
                guard let hit = resolved else { continue }
                vIdx = hit.vIdx
                vPath = flatNodes[vIdx].path
                cur = hit.cur
                vpH = Double(flatNodes[vIdx].targetRect.height)
                itemH = hit.itemH
                itemTop = hit.itemTop
            }

            let destY: Double
            if req.center {
                destY = max(0.0, min(Double(scrollMaxExtents[vPath]?.y ?? 0), itemTop + itemH * 0.5 - vpH * 0.5))
            } else {
                destY = ScrollEdgeMath.reveal(
                    offset: Double(cur.y),
                    top: itemTop,
                    height: itemH,
                    viewport: vpH,
                    margin: Double(flatNodes[vIdx].el.scrollMarginPts)
                )
            }

            let eff = scrollRequestsState.stepPlace(
                first: true,
                scope: req.scope,
                key: req.key,
                viewport: vPath,
                center: req.center,
                atEnd: false,
                from: Double(cur.y),
                to: destY
            )
            if case .move(let targetY) = eff {
                clearScrollHandGliding(path: vPath)
                applyScrollOffset(path: vPath, next: Vec2(cur.x, Float(targetY)), glide: (req.animated && !snaps) ? MotionTokens.GLIDE : nil)
            }
        }

        if followCaret, let caretInfo = focusedCaretInfo(in: flatNodes), let fIdx = nodeByPath[caretInfo.keyPath] {
            let caretRect = caretInfo.rect
            for horizontal in [false, true] {
                var curIdx = fIdx
                var targetVIdx: Int? = nil
                while flatNodes[curIdx].el.anchor == nil, let parent = flatNodes[curIdx].parentIndex {
                    if flatNodes[parent].el.layout.scrollAxes.contains(horizontal ? .horizontal : .vertical) {
                        targetVIdx = parent
                        break
                    }
                    curIdx = parent
                }
                guard let vIdx = targetVIdx else { continue }
                let vPath = flatNodes[vIdx].path
                let cur = scrollOffsets[vPath] ?? .zero
                let vpRect = flatNodes[vIdx].targetRect
                let axisCur = Double(horizontal ? cur.x : cur.y)
                let vpStart = Double(horizontal ? vpRect.x : vpRect.y)
                let vpLen = Double(horizontal ? vpRect.width : vpRect.height)
                let caretAt = Double(horizontal ? caretRect[0] : caretRect[1])
                let caretLen = Double(horizontal ? caretRect[2] : caretRect[3])
                let at = caretAt - vpStart + axisCur
                let margin = Double(flatNodes[vIdx].el.scrollMarginPts)
                let nextAxis = ScrollEdgeMath.reveal(
                    offset: axisCur,
                    top: at,
                    height: caretLen,
                    viewport: vpLen,
                    margin: margin
                )
                if abs(nextAxis - axisCur) > 1e-4 {
                    let next = horizontal ? Vec2(Float(nextAxis), cur.y) : Vec2(cur.x, Float(nextAxis))
                    applyScrollOffset(path: vPath, next: next, glide: nil)
                }
            }
        }

        for req in bottoms {
            if let vIdx = findScrollNode(bySelector: req.key) {
                let path = flatNodes[vIdx].path
                let maxExt = scrollMaxExtents[path] ?? .zero
                let cur = scrollOffsets[path] ?? .zero
                _ = scrollRequestsState.stepPlace(
                    first: true,
                    scope: nil,
                    key: req.key,
                    viewport: path,
                    center: false,
                    atEnd: true,
                    from: Double(cur.y),
                    to: Double(maxExt.y)
                )
                clearScrollHandGliding(path: path)
                applyScrollOffset(path: path, next: Vec2(cur.x, maxExt.y), glide: req.animated ? MotionTokens.GLIDE : nil)
            }
        }

        for req in pages {
            if let vIdx = findScrollNode(bySelector: req.key) {
                let path = flatNodes[vIdx].path
                let cur = scrollOffsets[path] ?? .zero
                let vpH = scrollViewportSizes[path]?.y ?? flatNodes[vIdx].targetRect.height
                let nextY = cur.y + Float(req.pages) * max(1, vpH * 0.9)
                markScrollMovedByHand(path: path)
                markScrollHandGliding(path: path)
                applyScrollOffset(path: path, next: Vec2(cur.x, nextY), glide: MotionTokens.GLIDE)
            }
        }

        for req in offsets {
            if req.anchor {
                guard let tIdx = flatNodes.firstIndex(where: { selectsElementSelector(req.key, path: $0.path, key: $0.key) }),
                      let vIdx = findScrollViewportIndex(forNode: tIdx, scopeKey: nil, verticalOnly: true) else {
                    continue
                }
                let vPath = flatNodes[vIdx].path
                let cur = scrollOffsets[vPath] ?? .zero
                let vpRect = flatNodes[vIdx].targetRect
                let tRect = flatNodes[tIdx].targetRect
                let at = req.y ?? 0
                let targetY = cur.y + (tRect.top - vpRect.top) - at
                markScrollMovedByHand(path: vPath)
                if req.glide != nil {
                    markScrollHandGliding(path: vPath)
                } else {
                    clearScrollHandGliding(path: vPath)
                }
                applyScrollOffset(path: vPath, next: Vec2(cur.x, targetY), glide: req.glide)
            } else if let vIdx = findScrollNode(bySelector: req.key) {
                let path = flatNodes[vIdx].path
                let cur = scrollOffsets[path] ?? .zero
                let next = Vec2(req.x ?? cur.x, req.y ?? cur.y)
                markScrollMovedByHand(path: path)
                if req.glide != nil {
                    markScrollHandGliding(path: path)
                } else {
                    clearScrollHandGliding(path: path)
                }
                applyScrollOffset(path: path, next: next, glide: req.glide)
            }
        }

        if destination || cut {
            scrollRequestsState.stepDestination()
        }

        dispatchScrollCallbacks(at: now)
    }

    /// Delivers `onAtBottom`, `onFarFromBottom`, and `onScrollOffset` callbacks for current scroll offsets.
    internal func dispatchScrollCallbacks(at now: Double) {
        // Scroll callbacks: onAtBottom, onFarFromBottom, onScrollOffset
        for i in flatNodes.indices {
            let node = flatNodes[i]
            guard !node.el.layout.scrollAxes.isEmpty else { continue }
            let path = node.path
            let cur = scrollOffsets[path] ?? .zero
            let maxExt = scrollMaxExtents[path] ?? .zero
            let vp = scrollViewportSizes[path] ?? Vec2(node.targetRect.width, node.targetRect.height)
            let distFromBottom = max(0, maxExt.y - cur.y)

            if let onAtBottom = node.el.handlers.onAtBottom {
                let isAtBottom = distFromBottom <= 1.0
                if atBottomStates[path] != isAtBottom {
                    atBottomStates[path] = isAtBottom
                    if let scope = turnScope {
                        scope(&state) { s in onAtBottom(&s, isAtBottom) }
                    } else {
                        onAtBottom(&state, isAtBottom)
                    }
                    needsCommit = true
                }
            }

            if let farSpec = node.el.handlers.onFarFromBottom {
                let farDist: Float
                if let frameKey = farSpec.frameKey,
                   let fIdx = flatNodes.firstIndex(where: { selectsElementSelector(frameKey, path: $0.path, key: $0.key) }) {
                    let frameRect = flatNodes[fIdx].targetRect
                    farDist = max(0, maxExt.y - cur.y - (vp.y - frameRect.height))
                } else {
                    farDist = distFromBottom
                }
                let isFar = farDist >= farSpec.min
                if farFromBottomStates[path] != isFar {
                    farFromBottomStates[path] = isFar
                    if let scope = turnScope {
                        scope(&state) { s in farSpec.handler(&s, isFar) }
                    } else {
                        farSpec.handler(&state, isFar)
                    }
                    needsCommit = true
                }
            }

            dispatchScrollOffsetObserverIfChanged(for: node, at: cxSettings.scaledTime(at: now), instant: currentCommitInstant)
        }
    }

    internal func dispatchScrollOffsetObserverIfChanged(
        for node: FlatNode,
        at now: Double = 0.0,
        instant: Bool = false,
        drawnOverride: Vec2? = nil
    ) {
        guard node.el.handlers.onScrollOffset != nil || node.el.handlers.onScroll != nil else { return }
        let path = node.path
        let cur = scrollOffsets[path] ?? .zero
        let maxExt = scrollMaxExtents[path] ?? .zero
        let vp = scrollViewportSizes[path] ?? Vec2(node.targetRect.width, node.targetRect.height)
        let drawn: Vec2
        if let d = drawnOverride {
            drawn = Vec2(
                abs(d.x - vp.x) > 0.05 ? d.x : vp.x,
                abs(d.y - vp.y) > 0.05 ? d.y : vp.y
            )
        } else if let pres = scene.presented(node.nodeId)?.rect {
            drawn = Vec2(
                abs(pres.width - vp.x) > 0.05 ? pres.width : vp.x,
                abs(pres.height - vp.y) > 0.05 ? pres.height : vp.y
            )
        } else {
            drawn = vp
        }
        let pos = ScrollPos(
            offset: cur,
            max: maxExt,
            viewport: vp,
            drawn: drawn,
            direction: node.flow == .rtl ? .rtl : .ltr
        )
        let isNewHandler = consumeNewScrollOffsetHandlerToken(path: path, token: node.el.handlers.onScrollOffsetToken)
        if lastScrollOffsetReports[path] != pos || isNewHandler {
            lastScrollOffsetReports[path] = pos
            if let onScrollOffset = node.el.handlers.onScrollOffset {
                dispatchScrollOffsetWithWatch(path: path, pos: pos, instant: instant, now: now, handler: onScrollOffset)
            }
            if let onScroll = node.el.handlers.onScroll {
                var tx = makeTx(at: now)
                if let scope = turnScope {
                    scope(&state) { s in onScroll(&s, pos, &tx) }
                } else {
                    onScroll(&state, pos, &tx)
                }
                applyTx(tx, at: now, markDirtyIfNotLiveOnly: !tx.liveOnlyRequested, liveOnlyLabel: "onScroll")
            }
        }
    }

    internal func tellScrollOffsetsAfterSceneFrame(at now: Double, instant: Bool) {
        for node in flatNodes where !node.el.layout.scrollAxes.isEmpty && (node.el.handlers.onScrollOffset != nil || node.el.handlers.onScroll != nil) {
            dispatchScrollOffsetObserverIfChanged(for: node, at: now, instant: instant)
        }
    }

    // MARK: - Paint-Time Sticky Push-Out Helpers

    internal func computePaintStickyShift(
        nodeIndex idx: Int,
        parentStickyShift: Vec2,
        presentedRectByNodeId: [NodeId: MotionRect]
    ) -> (shift: Vec2, parentShiftMag: Float) {
        computeStickyShift(
            nodeIndex: idx,
            parentStickyShift: parentStickyShift,
            nodes: flatNodes,
            rectOf: { node in presentedRectByNodeId[node.nodeId] ?? node.targetRect }
        )
    }

    internal func computeStickyShift(
        nodeIndex idx: Int,
        parentStickyShift: Vec2,
        nodes: [FlatNode],
        rectOf: (FlatNode) -> MotionRect
    ) -> (shift: Vec2, parentShiftMag: Float) {
        let node = nodes[idx]
        let held = scrollRequestsState.keeps.compactMap(\.hold).first(where: { $0.path == node.path })
        let effEdge: StickyEdge
        let effInset: Float
        let effTail: Bool
        if let held {
            effEdge = .top(held.inset)
            effInset = held.inset
            effTail = false
        } else if let sticky = node.el.stickyConfig, let edge = sticky.edge {
            effEdge = edge
            effInset = sticky.inset
            effTail = sticky.tail
        } else {
            return (parentStickyShift, max(abs(parentStickyShift.x), abs(parentStickyShift.y)))
        }

        let needsVertical: Bool
        switch effEdge {
        case .top, .bottom: needsVertical = true
        case .left: needsVertical = false
        }

        let scrollIdx = needsVertical ? node.enclosingVScrollIndex : node.enclosingHScrollIndex
        guard let sIdx = scrollIdx else {
            return (parentStickyShift, max(abs(parentStickyShift.x), abs(parentStickyShift.y)))
        }

        let scrollNode = nodes[sIdx]
        let scrollRect = rectOf(scrollNode)
        let scrollClip = intersectRects(scrollRect, scrollNode.clipRect)

        // Intersect scroll band across any outer scroll viewports on the same axis.
        var bandTop = scrollClip.top
        var bandBottom = scrollClip.bottom
        var bandLeft = scrollClip.left
        var bandRight = scrollClip.right
        var anc = scrollNode.parentIndex
        while let aIdx = anc {
            let aNode = nodes[aIdx]
            if (needsVertical && aNode.el.layout.scrollAxes.contains(.vertical))
                || (!needsVertical && aNode.el.layout.scrollAxes.contains(.horizontal)) {
                let aRect = rectOf(aNode)
                bandTop = max(bandTop, aRect.top)
                bandBottom = min(bandBottom, aRect.bottom)
                bandLeft = max(bandLeft, aRect.left)
                bandRight = min(bandRight, aRect.right)
            }
            anc = aNode.parentIndex
        }

        // Immediate parent's inner box bounds sticky push-out.
        let boxTop: Float
        let boxBottom: Float
        let boxLeft: Float
        let boxRight: Float
        if let pIdx = node.parentIndex {
            let pNode = nodes[pIdx]
            let pRect = rectOf(pNode)
            let pad = pNode.el.layout.padding
            let bdr = pNode.el.borderSides ?? Sides(
                top: pNode.el.borderWidth,
                right: pNode.el.borderWidth,
                bottom: pNode.el.borderWidth,
                left: pNode.el.borderWidth
            )
            if pIdx == sIdx {
                let curScroll = scrollOffsets[pNode.path] ?? .zero
                let contentW = max(pRect.width, scrollContentSizes[pNode.path]?.x ?? pRect.width)
                let contentH = max(pRect.height, scrollContentSizes[pNode.path]?.y ?? pRect.height)
                if pNode.flow == .rtl {
                    boxLeft = pRect.right + curScroll.x - contentW + pad.left + bdr.left
                    boxRight = pRect.right + curScroll.x - pad.right - bdr.right
                } else {
                    boxLeft = pRect.left - curScroll.x + pad.left + bdr.left
                    boxRight = pRect.left - curScroll.x + contentW - pad.right - bdr.right
                }
                boxTop = pRect.top - curScroll.y + pad.top + bdr.top
                boxBottom = pRect.top - curScroll.y + contentH - pad.bottom - bdr.bottom
            } else {
                boxLeft = pRect.left + pad.left + bdr.left + parentStickyShift.x
                boxTop = pRect.top + pad.top + bdr.top + parentStickyShift.y
                boxRight = pRect.right - pad.right - bdr.right + parentStickyShift.x
                boxBottom = pRect.bottom - pad.bottom - bdr.bottom + parentStickyShift.y
            }
        } else {
            boxLeft = -.infinity
            boxTop = -.infinity
            boxRight = .infinity
            boxBottom = .infinity
        }

        let rawRect = rectOf(node)
        let shiftedElem = MotionRect.fromXYWH(
            rawRect.x + parentStickyShift.x,
            rawRect.y + parentStickyShift.y,
            rawRect.width,
            rawRect.height
        )
        let bounds = StickyMath.FrameBounds(
            bandTop: bandTop,
            bandBottom: bandBottom,
            boxTop: boxTop,
            boxBottom: boxBottom,
            bandLeft: bandLeft,
            bandRight: bandRight,
            boxLeft: boxLeft,
            boxRight: boxRight
        )
        let localDelta = StickyMath.shift(
            edge: effEdge,
            inset: effInset,
            tail: effTail,
            elemRect: (
                top: shiftedElem.top,
                bottom: shiftedElem.bottom,
                left: shiftedElem.left,
                right: shiftedElem.right
            ),
            frame: bounds
        )
        let totalShift: Vec2
        if needsVertical {
            totalShift = Vec2(parentStickyShift.x, parentStickyShift.y + localDelta)
        } else {
            totalShift = Vec2(parentStickyShift.x + localDelta, parentStickyShift.y)
        }
        return (totalShift, max(abs(localDelta), max(abs(parentStickyShift.x), abs(parentStickyShift.y))))
    }

    // MARK: - Focus & Reveal Selected

    internal func checkFocusAndRevealSelected() {
        defer { suppressRevealFromHoverCommit = false }
        var newFocusedKey: String? = nil
        var newFocusedPath: String? = nil
        for node in flatNodes {
            if node.el.isFocusSelected && node.el.focusable && !node.effectiveInert {
                if !lastFocusSelectedPaths.contains(node.path) {
                    newFocusedPath = node.path
                    newFocusedKey = node.key
                }
            }
            if node.el.isRevealSelected && !isDispatchingHover && !suppressRevealFromHoverCommit && !lastRevealSelectedPaths.contains(node.path) {
                let targetKey = node.key ?? node.path
                pendingScrollReveals.append(.intoView(scope: nil, key: targetKey))
            }
        }
        lastFocusSelectedPaths = Set(flatNodes.filter { $0.el.isFocusSelected }.map(\.path))
        lastRevealSelectedPaths = Set(flatNodes.filter { $0.el.isRevealSelected }.map(\.path))
        if let fp = newFocusedPath {
            focusedPath = fp
            focusedKey = newFocusedKey
        }
    }
}
