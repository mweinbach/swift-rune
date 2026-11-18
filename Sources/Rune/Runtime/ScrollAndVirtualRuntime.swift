import Foundation
import RuneMotion

// MARK: - Increment 4 Runtime Support (TxCommit, ScrollRequests, Sticky, VirtualRows/VirtualFill, Growth)

extension Runtime {
    /// A reveal's scope identifies an ancestor of the target, including the virtual list that
    /// owns an unmounted row (commit/flatten.rs::in_scope). Swift also accepts a full or keyed path.
    internal static func inScrollRevealScope(_ scope: String?, path: String) -> Bool {
        guard let scope else { return true }
        if !scope.utf8.contains(0x2f) {
            return VirtualRowKeyEncoding.components(path).contains { segment in
                guard segment.first == "@" else { return false }
                return matchesAuthoredKey(VirtualRowKeyEncoding.authoredComponent(segment.dropFirst()), scope)
            }
        }
        var ancestor = path[...]
        while !ancestor.isEmpty {
            if selectsElementSelector(scope, path: String(ancestor), key: nil) { return true }
            guard let slash = ancestor.lastIndex(of: "/") else { break }
            ancestor = ancestor[..<slash]
        }
        return false
    }

    /// A virtual row selector can name the row, a scoped row, or a descendant of the row.
    internal static func virtualRevealRow(_ key: String, in places: VirtualRowPlaces<String>, path: String) -> Int? {
        if let index = places.index(ofAuthoredKey: key) { return index }
        if let target = places.row(containing: key, below: path) { return target.rowIndex }
        for slash in key.utf8.indices.reversed() where key.utf8[slash] == 0x2f {
            let row = String(key[key.utf8.index(after: slash)...])
            if let index = places.index(ofAuthoredKey: row),
               selectsElementSelector(key, path: "\(path)/@\(places.keys[index])", key: row) {
                return index
            }
        }
        for slash in key.utf8.indices where key.utf8[slash] == 0x2f {
            if let index = places.index(ofAuthoredKey: String(key[..<slash])) { return index }
        }
        return nil
    }

    /// Measure a single distant destination before the viewport moves. Multiple distinct targets
    /// must be revealed in order before choosing which window gets the offscreen row budget.
    private func pendingVirtualReveal(
        places: VirtualRowPlaces<String>, list: String
    ) -> Int? {
        var destination: Int?
        for request in pendingScrollReveals where Self.inScrollRevealScope(request.scope, path: list) {
            guard let row = Self.virtualRevealRow(request.key, in: places, path: list) else { continue }
            if let destination, row != destination { return nil }
            destination = row
        }
        return destination
    }

    internal enum VirtualRowReuseMode: Equatable, Sendable {
        case none
        case remount
        case rebuildRegion
    }

    internal struct CachedVirtualRow {
        var el: El<State>
        var memoIds: Set<String>
        var containsVirtual: Bool
        var reusableForRelayout: Bool
        var reads: [MemoRead] = []
        var trackedReads: TrackedReads = TrackedReads()
        var envHash: UInt64 = 0

        func holds(against geometry: MemoGeometry, envHash: UInt64) -> Bool {
            self.envHash == envHash
                && !trackedReads.changed()
                && reads.allSatisfy { $0.matches(geometry) }
        }
    }

    internal struct VirtualSelectionSource {
        var listPath: String
        var places: VirtualRowPlaces<String>
        var keys: [String] { places.keys }
        var mounted: Range<Int>
        var isIndexed: Bool
        var source: VirtualRowSource<State>?
        var storedChildren: [El<State>]
        var scrollAxes: ScrollAxes
        /// The selection's pinned rows built offscreen since this commit (`Pins` texts).
        var pinnedRows = VirtualPinnedRowCache()
    }

    /// Offscreen selection rows, retained through a prepared remount so a fallback leaves the
    /// rows collected up to the first entering row with a nested list (`commit/remount.rs`).
    internal final class VirtualPinnedRowCache {
        var rows: [String: El<State>] = [:]
    }

    internal struct VirtualListMeta {
        let listPath: String
        let scrollPath: String
        let estimate: Float
        let stickBottom: Bool
        let padTop: Float
        let indexed: Bool
        let mounted: RuntimeVirtualListState.VirtualMountedSnapshot
    }

    internal struct VirtualExpansionContext {
        var lands = false
        var rowMappings: [(listPath: String, scrollPath: String, rowSegment: String, rowKey: String)] = []
        var listMeta: [VirtualListMeta] = []
        var anyVirtualList: Bool = false
        var keyDiagnostics: [DuplicateKeyWarning] = []
        var keyRenames: [KeyDiagnostics.Rename] = []
        var virtualInputs: [String: VirtualInputEntry] = [:]
        var builtVirtualRows: [String: [String: CachedVirtualRow]] = [:]
        var remountHitNestedVirtual: Bool = false
        var selectionSources: [String: VirtualSelectionSource] = [:]
        var warnings: [String] = []
    }

    private func virtualRowPlaces(
        _ rawKeys: [String],
        previous: VirtualRowPlaces<String>,
        byteExactKeys: Bool = false,
        listPath: String,
        warnings: inout [String]
    ) -> VirtualRowPlaces<String> {
        if byteExactKeys == previous.byteExactKeys && rawKeys == previous.keys { return previous }
        let places = VirtualRowPlaces(rawKeys, byteExactKeys: byteExactKeys)
        guard places.hasDuplicates else { return places }
        let friendlyPath = listPath
            .split(separator: "/")
            .map { seg in seg.hasPrefix("@") ? String(seg.dropFirst()) : String(seg) }
            .filter { $0 != "0" }
            .joined(separator: "/")
        var repaired = rawKeys
        func authored(_ key: String) -> String {
            VirtualRowKeyEncoding.authoredKey(key) ?? key
        }
        let duplicates = KeyDiagnostics.renameDuplicates(&repaired) { key, suffix in
            let name = "\(authored(key))#dup\(suffix)"
            return VirtualRowKeyEncoding.storageKey(name, byteExact: byteExactKeys)
        }
        for (index, key) in duplicates {
            warnings.append("duplicate virtual row key \"\(authored(key))\" under \"\(friendlyPath)\" -> renamed to \"\(authored(repaired[index]))\"")
        }
        return VirtualRowPlaces(repaired, byteExactKeys: byteExactKeys)
    }

    internal struct GrowthCaptureResult {
        var needsClampedRelayout: Bool = false
        var activeCount: Int = 0
        var foldOpens: [PendingFoldOpen] = []
        var scrollCuts: [(viewport: String, cut: Float)] = []
        var foldHeaderUpdates: [(foldKey: String, headerPath: String)] = []
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
        tx.preparationWindowID = runtimeId
        tx.clock = now
        if let selection = handlerTextSelection() {
            tx.setCurrentTextSelection(selection)
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
        populateTxSlice2Context(&tx, at: now)
        tx.mods = mods ?? (slice2State.currentInputTime != nil ? slice2State.currentMods : inputMachines.currentMods)
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
            if let memo = cur.memoLayoutChildren, memo.matches(cur.children) {
                if memo.traits.contains(.virtual) { return true }
                continue
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
        memoGeometry: @autoclosure () -> MemoGeometry = MemoGeometry(),
        memoEnvHash: UInt64 = MemoScope.activeEnvHash,
        memoPass: UInt64 = 0,
        isReorderPermitted: Bool = true,
        lands: Bool = false,
        bypassBudget: Bool = false,
        forceAll: Bool = false
    ) -> (root: El<State>, context: VirtualExpansionContext) {
        var ctx = VirtualExpansionContext(lands: lands)
        activeVirtualPaths.removeAll(keepingCapacity: true)
        guard treeContainsVirtual(rootEl) else {
            return (rootEl, ctx)
        }
        if rowReuseMode == .remount {
            // Planning clears every list, including lists after the one that may fall back.
            for source in virtualSelectionSources.values {
                source.pinnedRows.rows.removeAll(keepingCapacity: true)
            }
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
            scrollAnchor: false,
            remountRowCache: remountRowCache,
            rowReuseMode: rowReuseMode,
            inReusableRegion: false,
            regionEnvHash: 0,
            memoGeometry: memoGeometry(),
            memoEnvHash: memoEnvHash,
            memoPass: memoPass,
            scrollEstHeight: nil,
            availableHeight: fitHeight ? .infinity : viewport.y,
            isReorderPermitted: isReorderPermitted,
            bypassBudget: bypassBudget,
            forceAll: forceAll,
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
        scrollAnchor: Bool,
        remountRowCache: [String: [String: CachedVirtualRow]]?,
        rowReuseMode: VirtualRowReuseMode,
        inReusableRegion: Bool,
        regionEnvHash: UInt64,
        memoGeometry: MemoGeometry,
        memoEnvHash: UInt64,
        memoPass: UInt64,
        scrollEstHeight: Float?,
        availableHeight: Float,
        isReorderPermitted: Bool,
        bypassBudget: Bool,
        forceAll: Bool,
        ctx: inout VirtualExpansionContext
    ) {
        let (segment, _) = layoutPathSegment(
            keyId: el.storageKeyId,
            siblingIndex: siblingIndex,
            siblingKeysSeen: &siblingKeysSeen
        )
        let path = parentPath.isEmpty ? (el.storageKeyId.map { "/@\($0)" } ?? "/0") : "\(parentPath)/\(segment)"

        if el.virtualEstimate == nil, el.virtualRowsSource == nil,
           let memo = el.memoLayoutChildren, memo.matches(el.children), !memo.traits.contains(.virtual) {
            return
        }

        let nodeInReusableRegion = el.memoRegionReused ? true : inReusableRegion
        let nodeRegionEnvHash = el.memoRegionReused ? el.memoRegionEnvHash : regionEnvHash

        var nextScrollPath = scrollPath
        var nextStickBottom = scrollStickBottom
        var nextScrollAnchor = scrollAnchor
        let bound = virtualHeightBound(el.layout, available: availableHeight)
        var nextEstHeight = scrollEstHeight
        if !el.layout.scrollAxes.isEmpty {
            nextScrollPath = path
            nextStickBottom = el.layout.stickBottom
            nextScrollAnchor = el.scrollAnchorEnabled
            nextEstHeight = bound.isFinite ? bound : nil
        }

        if el.virtualEstimate != nil || el.virtualRowsSource != nil {
            expandSingleVirtualNode(
                &el,
                path: path,
                nextScrollPath: nextScrollPath,
                nextStickBottom: nextStickBottom,
                nextScrollAnchor: nextScrollAnchor,
                remountRowCache: remountRowCache,
                rowReuseMode: rowReuseMode,
                inReusableRegion: nodeInReusableRegion,
                regionEnvHash: nodeRegionEnvHash,
                memoGeometry: memoGeometry,
                memoEnvHash: memoEnvHash,
                memoPass: memoPass,
                scrollEstHeight: nextEstHeight,
                availableHeight: bound,
                isReorderPermitted: isReorderPermitted,
                bypassBudget: bypassBudget,
                forceAll: forceAll,
                ctx: &ctx
            )
            return
        }

        guard !el.children.isEmpty else { return }
        let bounds = VirtualChildBounds.compute(style: el.layout, scrolls: !el.layout.scrollAxes.isEmpty, bound: bound, children: el.children)
        var childSeen: [String: Int] = [:]
        for idx in el.children.indices {
            let childBound = bounds.of(el.children[idx])
            walkVirtualSubtrees(
                &el.children[idx],
                parentPath: path,
                siblingIndex: idx,
                siblingKeysSeen: &childSeen,
                scrollPath: nextScrollPath,
                scrollStickBottom: nextStickBottom,
                scrollAnchor: nextScrollAnchor,
                remountRowCache: remountRowCache,
                rowReuseMode: rowReuseMode,
                inReusableRegion: nodeInReusableRegion,
                regionEnvHash: nodeRegionEnvHash,
                memoGeometry: memoGeometry,
                memoEnvHash: memoEnvHash,
                memoPass: memoPass,
                scrollEstHeight: nextEstHeight,
                availableHeight: childBound,
                isReorderPermitted: isReorderPermitted,
                bypassBudget: bypassBudget,
                forceAll: forceAll,
                ctx: &ctx
            )
            if ctx.remountHitNestedVirtual { return }
        }
    }

    @inline(never)
    private func expandSingleVirtualNode(
        _ el: inout El<State>,
        path: String,
        nextScrollPath: String?,
        nextStickBottom: Bool,
        nextScrollAnchor: Bool,
        remountRowCache: [String: [String: CachedVirtualRow]]?,
        rowReuseMode: VirtualRowReuseMode,
        inReusableRegion: Bool,
        regionEnvHash: UInt64,
        memoGeometry: MemoGeometry,
        memoEnvHash: UInt64,
        memoPass: UInt64,
        scrollEstHeight: Float?,
        availableHeight: Float,
        isReorderPermitted: Bool,
        bypassBudget: Bool,
        forceAll: Bool,
        ctx: inout VirtualExpansionContext
    ) {
        ctx.anyVirtualList = true
        activeVirtualPaths.insert(path)
        var vState = virtualLists[path] ?? RuntimeVirtualListState()
        vState.gap = virtualGapY(el.layout)
        let prevKeys = vState.lastKeys
        let isIndexed = (el.virtualRowsSource != nil)
        let est = max(1, el.virtualEstimate ?? 40)

        let count: Int
        let keys: [String]
        if let src = el.virtualRowsSource {
            count = src.count
            let version = el.virtualRowsVersionHash
            // A remount uses the committed row source and unchanged state. A fresh view can also
            // declare a key version, otherwise verify its keys even when the count stayed the same.
            let sameKeySpace = src.byteExactKeys == vState.rowPlaces.byteExactKeys
            let retainedKeys = sameKeySpace && vState.isIndexed && count == prevKeys.count
                && (rowReuseMode == .remount || (version != nil && version == vState.lastKeysVersion))
            if !retainedKeys {
                var changedKeys: [String]? = sameKeySpace && count == prevKeys.count ? nil : []
                changedKeys?.reserveCapacity(count)
                for index in 0..<count {
                    let authored = src.key(state, index)
                    let key = VirtualRowKeyEncoding.storageKey(authored, byteExact: src.byteExactKeys)
                    if changedKeys == nil {
                        if key == prevKeys[index] { continue }
                        changedKeys = Array(prevKeys.prefix(index))
                        changedKeys?.reserveCapacity(count)
                    }
                    changedKeys?.append(key)
                }
                if let changedKeys {
                    vState.replaceRowPlaces(virtualRowPlaces(changedKeys, previous: vState.rowPlaces, byteExactKeys: src.byteExactKeys, listPath: path, warnings: &ctx.warnings))
                }
            }
            // A layout retry may pair the prior list's keys with this commit's new measurements.
            if vState.measuredByKey.places.keys != vState.lastKeys {
                vState.replaceRowPlaces(vState.rowPlaces)
            }
            keys = vState.lastKeys
            vState.lastKeysVersion = version
        } else {
            count = el.children.count
            var childKeys: [String] = []
            childKeys.reserveCapacity(count)
            for (idx, child) in el.children.enumerated() {
                childKeys.append(child.storageKeyId ?? "__vrow_\(idx)")
            }
            vState.replaceRowPlaces(virtualRowPlaces(childKeys, previous: vState.rowPlaces, listPath: path, warnings: &ctx.warnings))
            keys = vState.lastKeys
            vState.lastKeysVersion = nil
        }

        vState.measuredByKey.prepareOffsets(estimated: est, gap: vState.gap)
        let (prefix, total) = vState.computeOffsets(estimated: est)
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
            vpH = max(1, scrollEstHeight ?? viewport.y)
        }
        let isFirstMount = (scrollOffsets[vpPath] == nil && !wasPinnedToBottom.contains(vpPath))
        let stickyPin = nextStickBottom && (ctx.lands || isFirstMount || wasPinnedToBottom.contains(vpPath))

        let hasPendingRevealForViewport = pendingScrollReveals.contains { req in
            Self.inScrollRevealScope(req.scope, path: path)
        }
        let isReorder = isReorderPermitted && !prevKeys.isEmpty && keys.count == prevKeys.count && keys != prevKeys
            && prevKeys.allSatisfy { vState.rowPlaces.index(of: $0) != nil }
        // A list in a row of another list windows against that list's viewport too (`nested`).
        vState.nested = Self.virtualListIsNested(path: path, scrollPath: vpPath, lists: activeVirtualPaths)
        vState.scrollPath = vpPath
        vState.viewport = vpH
        vState.padTop = el.layout.padding.top
        vState.padBottom = el.layout.padding.bottom
        var curOffsetY = scrollOffsets[vpPath]?.y ?? 0
        let scrolledSinceCommit = vState.lastCommittedOffsetY.map { abs($0 - curOffsetY) > 0.25 } ?? false
        // The viewport's own pin moves its offset; the list windows where that leaves it.
        let held = stickyPin
        if held {
            // Only the viewport's own list follows its end; a nested list stands where it leaves it.
            if !vState.nested {
                curOffsetY = max(0, vState.top + vState.extent(total: total) - vpH)
                scrollOffsets[vpPath] = Vec2(scrollOffsets[vpPath]?.x ?? 0, curOffsetY)
            }
            wasPinnedToBottom.insert(vpPath)
        }
        var (listOffsetY, listPinned) = vState.locate(curOffsetY, pinned: held, total: total)
        if !held,
           !listPinned,
           !vState.passed,
           (nextScrollAnchor || curOffsetY > 0.5),
           !isReorder,
           !scrolledSinceCommit,
           let anchorKey = vState.lastAnchorKey,
           !scrollRequestsState.owns(vpPath),
           !directScrolledPaths.contains(vpPath),
           !hasPendingRevealForViewport,
           let anchorIdx = vState.rowPlaces.index(of: anchorKey) {
            let expectedY = max(0, min(max(0, vState.extent(total: total) - vpH), vState.padTop + prefix[anchorIdx] + vState.lastAnchorLocalY))
            if abs(expectedY - listOffsetY) > 0.25 {
                curOffsetY = max(0, curOffsetY + expectedY - listOffsetY)
                scrollOffsets[vpPath] = Vec2(scrollOffsets[vpPath]?.x ?? 0, curOffsetY)
                let nid = NodeId.hash("scroll:\(vpPath)")
                scrollStore.snap(nid, Props.SCROLL, to: scrollOffsets[vpPath] ?? .zero)
                (listOffsetY, listPinned) = vState.locate(curOffsetY, pinned: held, total: total)
            }
        }

        var pinned: Set<Int> = []
        if let fk = focusedKey, let fi = vState.rowPlaces.index(ofAuthoredKey: fk) {
            pinned.insert(fi)
        }
        let destination = pendingVirtualReveal(places: vState.rowPlaces, list: path)
        var windowOffsetY = vState.revealWindowOffset(row: destination, prefix: prefix, viewport: vpH, from: listOffsetY)
        if let destination { pinned.insert(destination) }
        for rev in scrollRequestsState.reveals where rev.viewport == vpPath {
            if let ri = Self.virtualRevealRow(rev.key, in: vState.rowPlaces, path: path) {
                pinned.insert(ri)
                let bottom = vState.rowEnd(ri + 1, prefix: prefix)
                if isFirstMount && bottom > windowOffsetY + vpH {
                    windowOffsetY = max(0, bottom - vpH)
                }
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
                offset: windowOffsetY,
                viewport: vpH,
                prefix: prefix,
                count: count,
                indexed: isIndexed,
                pinnedIndices: pinned,
                pinned: listPinned,
                bypassBudget: bypassBudget,
                forceAll: forceAll
            )
        }
        // Track first visible anchor row for prepend/resize scroll preservation. A list pinned to
        // its end, or nested and wholly above the viewport's top, anchors nothing.
        let vis = vState.visibleRange(offset: listOffsetY, viewport: vpH, prefix: prefix, count: count)
        if !vis.isEmpty && !listPinned && !vState.passed {
            let ai = vis.first { vState.measuredByKey.heights[$0] != nil } ?? vis.lowerBound
            vState.lastAnchorKey = keys[ai]
            vState.lastAnchorPrefixY = vState.padTop + prefix[ai]
            vState.lastAnchorLocalY = listOffsetY - vState.lastAnchorPrefixY
        } else if listPinned || vState.passed {
            vState.lastAnchorKey = nil
            vState.lastAnchorLocalY = 0
            vState.lastAnchorPrefixY = 0
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
        let (topSpacerH, botSpacerH) = vState.spacerHeights(mounted: mounted, prefix: prefix, total: total)
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
        ctx.listMeta.append(VirtualListMeta(
            listPath: path,
            scrollPath: vpPath,
            estimate: est,
            stickBottom: nextStickBottom,
            padTop: el.layout.padding.top,
            indexed: isIndexed,
            mounted: currentMountedSnapshot
        ))

        let hasFocusedRow = !pinned.isEmpty || (focusedPath?.hasPrefix(path + "/") == true)
        let hasSelectionPin = hasUnmountedVirtualSelectionPin(listPath: path, places: vState.rowPlaces, mounted: mounted)
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

        var selectionSource = VirtualSelectionSource(
            listPath: path,
            places: vState.rowPlaces,
            mounted: mounted,
            isIndexed: isIndexed,
            source: el.virtualRowsSource,
            storedChildren: isIndexed ? [] : el.children,
            scrollAxes: el.layout.scrollAxes
        )
        if rowReuseMode == .remount, let previous = virtualSelectionSources[path] {
            selectionSource.pinnedRows = previous.pinnedRows
        } else {
            // The replacement builders can acquire a resource owned by an offscreen
            // row in the previous tree. Release that list's rows before invoking them.
            virtualSelectionSources.removeValue(forKey: path)
        }
        ctx.selectionSources[path] = selectionSource
        func buildRow(_ source: VirtualRowSource<State>, at index: Int) -> CachedVirtualRow {
            let touched = MemoScope.TouchedIdsBox()
            let row = MemoScope.enterVirtualRow(
                cache: self.memo, envHash: memoEnvHash, geometry: memoGeometry,
                pass: memoPass, touchedIdsOut: touched
            ) { source.build(state, index) }
            self.memo.appendViewReads(touched.reads + touched.trackedReads.memoReads, pass: memoPass)
            var keyedRow = source.keyed(row, storageKey: keys[index])
            if !keyedRow.children.isEmpty, keyedRow.memoLayoutChildren?.matches(keyedRow.children) != true {
                keyedRow.memoLayoutChildren = MemoLayoutChildren(keyedRow.children)
            }
            return CachedVirtualRow(el: keyedRow, memoIds: touched.ids,
                                    containsVirtual: treeContainsVirtual(keyedRow), reusableForRelayout: Self.isTreeReusableForRelayout(keyedRow),
                                    reads: touched.reads, trackedReads: touched.trackedReads, envHash: memoEnvHash)
        }
        func offscreenRow(_ index: Int) -> El<State>? {
            offscreenRowElement(source: selectionSource, at: index) { source in buildRow(source, at: index).el }
        }
        if focusedPath != nil || focusedKey != nil {
            collectOffscreenFocusedVirtualInputs(source: selectionSource, buildRow: offscreenRow, ctx: &ctx)
        }
        if rowReuseMode == .remount {
            // A focused pinned row was collected above; offscreenRowElement reuses it.
            for key in virtualSelectionPinnedRows(path) {
                if let index = selectionSource.places.index(of: key), !mounted.contains(index) {
                    _ = offscreenRow(index)
                }
            }
        }
        var nestedRows: [(index: Int, reused: Bool)] = []
        var rowKeysBySegment = Dictionary<String, String>(minimumCapacity: mounted.count)
        for i in mounted {
            let rowKey = keys[i]
            var rowEl: El<State>
            var didReuseRow = false
            let containsVirtual: Bool
            if isIndexed {
                if canReuseRows,
                   let reused = remountRowCache?[path]?[rowKey],
                   reused.reusableForRelayout,
                   reused.holds(against: memoGeometry, envHash: memoEnvHash) {
                    self.memo.touchEntries(ids: reused.memoIds, pass: memoPass)
                    self.memo.appendViewReads(reused.reads + reused.trackedReads.memoReads, pass: memoPass)
                    reused.trackedReads.read()
                    rowEl = reused.el
                    containsVirtual = reused.containsVirtual
                    didReuseRow = true
                    ctx.builtVirtualRows[path, default: [:]][rowKey] = reused
                } else {
                    let row = buildRow(el.virtualRowsSource!, at: i)
                    containsVirtual = row.containsVirtual
                    if rowReuseMode == .remount && containsVirtual {
                        ctx.remountHitNestedVirtual = true
                        return
                    }
                    rowEl = row.el
                    ctx.builtVirtualRows[path, default: [:]][rowKey] = row
                }
            } else {
                rowEl = el.children[i]
                containsVirtual = treeContainsVirtual(rowEl)
                if rowEl.storageKeyId != rowKey {
                    rowEl.assignStoredKey(rowKey, authored: VirtualRowKeyEncoding.authoredKey(rowKey))
                }
            }
            // Every row now carries its resolved, unique key, including repaired duplicates.
            let rowSeg = "@\(rowKey)"
            if isIndexed && !KeyDiagnostics.clean(rowEl) {
                let repaired = KeyDiagnostics.repair(rowEl, at: "\(path)/\(rowSeg)") { ctx.keyRenames.append($0) }
                ctx.keyDiagnostics.append(contentsOf: repaired.warnings)
                rowEl = repaired.tree
            }
            ctx.rowMappings.append((listPath: path, scrollPath: vpPath, rowSegment: rowSeg, rowKey: rowKey))
            rowKeysBySegment[rowSeg] = rowKey
            if containsVirtual { nestedRows.append((built.count, didReuseRow)) }
            built.append(rowEl)
        }

        virtualLists[path]?.rowKeyBySegment = rowKeysBySegment
        if botSpacerH > 0 {
            built.append(Self.virtualSpacer(key: "__v_bot_spacer", height: botSpacerH))
        }
        if !nestedRows.isEmpty {
            let bounds = VirtualChildBounds.compute(style: el.layout, scrolls: !el.layout.scrollAxes.isEmpty,
                                                    bound: availableHeight, children: built)
            var rowSeenKeys: [String: Int] = [:]
            for nested in nestedRows {
                let childBound = bounds.of(built[nested.index])
                walkVirtualSubtrees(
                    &built[nested.index],
                    parentPath: path,
                    siblingIndex: nested.index,
                    siblingKeysSeen: &rowSeenKeys,
                    scrollPath: nextScrollPath,
                    scrollStickBottom: nextStickBottom,
                    scrollAnchor: nextScrollAnchor,
                    remountRowCache: remountRowCache,
                    rowReuseMode: rowReuseMode,
                    inReusableRegion: nested.reused ? inReusableRegion : false,
                    regionEnvHash: nested.reused ? regionEnvHash : 0,
                    memoGeometry: memoGeometry,
                    memoEnvHash: memoEnvHash,
                    memoPass: memoPass,
                    scrollEstHeight: scrollEstHeight,
                    availableHeight: childBound,
                    isReorderPermitted: isReorderPermitted,
                    bypassBudget: bypassBudget,
                    forceAll: forceAll,
                    ctx: &ctx
                )
                if ctx.remountHitNestedVirtual { return }
            }
        }
        el.children = built
        el.virtualRowsSource = nil
    }

    /// Collects `editLens` inputs in rows of virtual list `path` scrolled out of the mounted window
    /// so the focused field survives being unmounted. Split out of `expandSingleVirtualNode` so its
    /// temporaries don't enlarge that frame on the row-build path (debug stack depth).
    @inline(never)
    private func collectOffscreenFocusedVirtualInputs(
        source: VirtualSelectionSource,
        buildRow: (Int) -> El<State>?,
        ctx: inout VirtualExpansionContext
    ) {
        let path = source.listPath
        let places = source.places
        let mounted = source.mounted
        let keys = places.keys
        var candidateIndices: [Int] = []
        if let fp = focusedPath, fp.hasPrefix(path + "/") {
            if let row = places.row(containing: fp, below: path), !mounted.contains(row.rowIndex) {
                candidateIndices.append(row.rowIndex)
            } else if let prev = virtualInputs[fp], let i = places.index(of: prev.rowKey), !mounted.contains(i) {
                candidateIndices.append(i)
            }
        }
        if candidateIndices.isEmpty && !source.isIndexed {
            for i in keys.indices where !mounted.contains(i) {
                candidateIndices.append(i)
            }
        }
        for i in candidateIndices {
            guard let offEl = buildRow(i) else { continue }
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
            keyId: el.storageKeyId,
            siblingIndex: siblingIndex,
            siblingKeysSeen: &siblingKeysSeen
        )
        let path = "\(parentPath)/\(seg)"
        let publicKey = el.authoredByteExactKey ?? resolvedKey ?? el.keyId
        if el.handlers.editLens != nil,
           (path == targetPath || targetKey.map({ matchesAuthoredKey(publicKey, $0) }) == true) {
            out[path] = VirtualInputEntry(
                path: path,
                key: publicKey,
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

    private func recordGrowthStack(_ el: El<State>, path: String) {
        let prevStack = kitHooks.growthStacks[path]
        var nextStack = prevStack ?? KitGrowthStackState()
        nextStack.isNewStack = (prevStack == nil)
        nextStack.spacerPaths.removeAll(keepingCapacity: true)

        var newChildSegs: [String] = []
        var childSeen: [String: Int] = [:]
        for (cIdx, child) in el.children.enumerated() {
            let (cSeg, _) = layoutPathSegment(keyId: child.storageKeyId, siblingIndex: cIdx, siblingKeysSeen: &childSeen)
            let isSpacer = (child.keyId == "__v_top_spacer" || child.keyId == "__v_bot_spacer") || child.isKitVirtualSpacer
            if !isSpacer {
                newChildSegs.append(cSeg)
            }
        }
        // RuntimeGrowthStackState (`growthStacks`) handles closing holds, foldGlide shuts, and monotonic runs.
        nextStack.order = newChildSegs
        nextStack.closing.removeAll()
        kitHooks.growthStacks[path] = nextStack
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

    private func findHeldFoldHeaderBottom(
        rowEl: El<State>,
        rowRes: LayoutEngine.ResultNode,
        rowPath: String,
        parentWorldY: Float,
        inheritedScale: Float
    ) -> (path: String, bottomWorld: Float, stuck: Float)? {
        guard scrollRequestsState.hasKeeps else { return nil }
        let rowPrefix = rowPath + "/"
        guard let hold = scrollRequestsState.keeps.compactMap(\.hold).first(where: { $0.path.hasPrefix(rowPrefix) }) else {
            return nil
        }
        let stuck = stuckShiftsByPath[hold.path]?.y ?? 0
        guard stuck > 0.5 else { return nil }

        func findHeader(el: El<State>, res: LayoutEngine.ResultNode, parentPath: String, siblingIndex: Int, siblingKeysSeen: inout [String: Int], parentY: Float, scale: Float) -> Float? {
            let (seg, _) = layoutPathSegment(keyId: el.storageKeyId, siblingIndex: siblingIndex, siblingKeysSeen: &siblingKeysSeen)
            let p = parentPath.isEmpty ? (el.storageKeyId.map { "/@\($0)" } ?? "/0") : "\(parentPath)/\(seg)"
            let myScale = scale * el.scale.y
            let myY = parentY + res.layout.localRect.y * scale
            if p == hold.path {
                return myY + res.layout.localRect.height * myScale
            }
            if hold.path.hasPrefix(p + "/") && el.children.count == res.children.count {
                var childSeen: [String: Int] = [:]
                for i in 0..<el.children.count {
                    if let found = findHeader(
                        el: el.children[i],
                        res: res.children[i],
                        parentPath: p,
                        siblingIndex: i,
                        siblingKeysSeen: &childSeen,
                        parentY: myY,
                        scale: myScale
                    ) {
                        return found
                    }
                }
            }
            return nil
        }

        guard rowEl.children.count == rowRes.children.count else { return nil }
        var seen: [String: Int] = [:]
        for i in 0..<rowEl.children.count {
            if let bot = findHeader(
                el: rowEl.children[i],
                res: rowRes.children[i],
                parentPath: rowPath,
                siblingIndex: i,
                siblingKeysSeen: &seen,
                parentY: parentWorldY,
                scale: inheritedScale
            ) {
                return (hold.path, bot, stuck)
            }
        }
        return nil
    }

    private struct GrowthWalkAccum {
        var seenStackOrder: [String] = []
        var existedStackPaths: Set<String> = []
        var stackNewIds: [String: [String]] = [:]
        var stackOpened: [String: [String]] = [:]
        var result = GrowthCaptureResult()
        var seenGrowthKeys: Set<String> = []
        var seenStackPaths: Set<String> = []
        var hiddenCutsByScroll: [String: Float] = [:]
        var heldByScroll: [String: [(growthKey: String, below: Float)]] = [:]
        var reopenedFolds: [(scrollPath: String, growthKey: String, rowPath: String, giving: Bool)] = []
    }

    @inline(never)
    private func growthFoldLimit(path: String, enclosingScrollPath: String?, worldTop: Float, inheritedScale: Float) -> Float {
        let vpBottom: Float
        if let vpPath = enclosingScrollPath,
           let vpRect = presentedRectByPath[vpPath] ?? nodeByPath[vpPath].map({ flatNodes[$0].targetRect }) {
            vpBottom = min(viewport.y, vpRect.bottom)
        } else {
            vpBottom = viewport.y
        }
        let rowTop = presentedRectByPath[path]?.top
            ?? nodeByPath[path].map({ flatNodes[$0].targetRect.top })
            ?? worldTop
        return max(0, (vpBottom - rowTop) / max(1e-4, inheritedScale))
    }

    @inline(never)
    private func findLastRevealWrappedTextIterative(
        in rootEl: El<State>,
        res rootRes: LayoutEngine.ResultNode
    ) -> (el: El<State>, res: LayoutEngine.ResultNode)? {
        var found: (el: El<State>, res: LayoutEngine.ResultNode)? = nil
        var stack: [(el: El<State>, res: LayoutEngine.ResultNode)] = [(rootEl, rootRes)]
        while let cur = stack.popLast() {
            let wordFade = cur.el.runtimeExtras["shell.revealWordFade"] as? Float
            if (cur.el.textReveal >= 0 || (wordFade ?? -1) >= 0),
               (cur.el.plainText != nil || cur.el.richSpans != nil || cur.el.liveText != nil),
               cur.el.textStyle.wrap != .noWrap {
                found = cur
            }
            let count = min(cur.el.children.count, cur.res.children.count)
            for i in (0..<count).reversed() {
                stack.append((cur.el.children[i], cur.res.children[i]))
            }
        }
        return found
    }

    @inline(never)
    private func processGrowthWalkNode(
        el: El<State>,
        res: LayoutEngine.ResultNode,
        path: String,
        inGrowthSpec: GrowthSpec?,
        parentStackPath: String?,
        enclosingScrollPath: String?,
        parentWorldY: Float,
        inheritedScale: Float,
        settleAll: Bool,
        snaps: Bool,
        isRelayoutPass: Bool,
        at now: Double,
        accum: inout GrowthWalkAccum
    ) -> (ownStackPath: String?, nextGrowth: GrowthSpec?, nextScrollPath: String?, childParentWorldY: Float, myScale: Float) {
        let myScale = inheritedScale * el.scale.y
        let myWorldY = parentWorldY + res.layout.localRect.y * inheritedScale
        if scrollRequestsState.hasKeeps {
            slice2State.unclampedBottomByPath[path] = myWorldY + res.layout.localRect.height * myScale
        }

        var ownStackPath = parentStackPath
        if let spec = el.growthSpec {
            if el.virtualEstimate == nil && el.virtualRowsSource == nil {
                recordGrowthStack(el, path: path)
            } else {
                kitHooks.growthStacks.removeValue(forKey: path)
            }
            if accum.seenStackPaths.insert(path).inserted { accum.seenStackOrder.append(path) }
            ownStackPath = path
            let stackWidth = res.layout.localRect.width
            let existed = growthStacks[path] != nil
            if existed { accum.existedStackPaths.insert(path) }
            var stack = growthStacks[path] ?? RuntimeGrowthStackState(width: stackWidth, widthHold: .off)
            if !existed || settleAll {
                stack.widthHold = .off
                stack.pendingHeights.removeAll(keepingCapacity: true)
            } else if abs(stackWidth - stack.width) > 0.25 {
                stack.widthHold = .rewrap(at: now)
            }
            stack.width = stackWidth
            stack.gap = el.layout.rowGap
            let borderBottom = el.layout.borderLayout
                ? TaffyBridge.snappedBorderSides(el.borderSides ?? .all(el.borderWidth), pixelScale: pixelScale).bottom
                : 0
            let rowsEnd = res.children.last?.layout.localRect.bottom ?? el.layout.padding.top
            stack.trailingSpace = max(0, res.layout.localRect.height - rowsEnd - el.layout.padding.bottom - borderBottom)
            stack.spring = spec.spring
            stack.edge = spec.edge
            growthStacks[path] = stack
        }

        let isVirtualSpacer = (el.keyId == "__v_top_spacer" || el.keyId == "__v_bot_spacer") || el.isKitVirtualSpacer
        if !isVirtualSpacer && (inGrowthSpec != nil || el.foldGlideSpec != nil) {
            let gKey = el.foldGlideSpec != nil ? "fold:\(path)" : "growth:\(path)"
            accum.seenGrowthKeys.insert(gKey)
            if let sp = parentStackPath {
                accum.stackNewIds[sp, default: []].append(gKey)
                growthStacks[sp]?.closing.removeValue(forKey: gKey)
            }
            slice2State.growthRowPathByKey[gKey] = path
            if let enclosingScrollPath {
                slice2State.growthScrollByKey[gKey] = enclosingScrollPath
            } else {
                slice2State.growthScrollByKey.removeValue(forKey: gKey)
            }
            let unlaggedH = res.layout.localRect.height
            var naturalH = unlaggedH
            let edge: StreamEdge = el.growthSpec?.edge ?? inGrowthSpec?.edge ?? .feather
            let spring: Spring = el.growthSpec?.spring ?? inGrowthSpec?.spring ?? Growth.spring
            let limit = el.foldGlideSpec != nil
                ? growthFoldLimit(path: path, enclosingScrollPath: enclosingScrollPath, worldTop: myWorldY, inheritedScale: myScale)
                : .infinity
            let glideArg: (FoldGlide, Float)? = el.foldGlideSpec.map { ($0, limit) }
            let streaming = el.isStreaming
            let whole = el.isArrivesWhole && !streaming
            let firstChildTop = res.children.first?.layout.localRect.y
            let hiddenHeader = (el.foldGlideSpec != nil)
                ? findHeldFoldHeaderBottom(rowEl: el, rowRes: res, rowPath: path, parentWorldY: myWorldY, inheritedScale: myScale)
                    .flatMap { info -> (above: Float, header: String)? in
                        guard naturalH <= (info.bottomWorld - myWorldY) / max(1e-4, myScale) + 0.5 else { return nil }
                        return (above: info.stuck, header: info.path)
                    }
                : nil

            if streaming && growthRows[gKey] != nil && !settleAll {
                if let (tEl, tRes) = findLastRevealWrappedTextIterative(in: el, res: res) {
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

            let liveWindow = parentStackPath.flatMap { slice2State.liveTailWindows[$0] }
            let live = el.storageKeyId.map { liveWindow?.visibleKeys.contains($0) == true && liveWindow?.quietMounts.contains($0) == false } ?? false
            let instantGrowth = settleAll || el.hasInstantChanges || (snaps && !streaming && !live)
            if var existing = growthRows[gKey] {
                let prevTarget = existing.track.target
                let prevH = existing.track.h
                let prevTop = existing.lastFirstChildTop
                existing.edge = edge
                existing.spring = spring
                existing.foldLimit = limit
                existing.naturalHeight = unlaggedH
                existing.track.setKind(streaming: streaming, whole: whole, glide: glideArg)
                if (instantGrowth && abs(naturalH - prevTarget) > 1e-4) || settleAll {
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
                            let shutting = effectiveH < existing.track.target - 1e-4
                            let reopening = effectiveH > existing.track.target + 1e-4
                            let wasGiving = (existing.track.give != nil)
                            if reopening && (existing.track.currentLift() > 0 || (el.foldGlideSpec != nil && existing.track.target > 1e-4)) {
                                if let vp = enclosingScrollPath {
                                    accum.reopenedFolds.append((scrollPath: vp, growthKey: gKey, rowPath: path, giving: wasGiving))
                                }
                            }
                            existing.track.linearEdge = live
                            existing.track.retarget(effectiveH)
                            if let hidden = hiddenHeader, shutting && existing.track.isShuttingFold, let vp = enclosingScrollPath {
                                let below = max(0, prevH - existing.track.h)
                                let cutAmt = existing.track.hideAbove(hidden.above)
                                if cutAmt > 0 {
                                    accum.hiddenCutsByScroll[vp, default: 0] += cutAmt
                                }
                                accum.heldByScroll[vp, default: []].append((growthKey: gKey, below: below))
                                accum.result.foldHeaderUpdates.append((foldKey: gKey, headerPath: hidden.header))
                            }
                            if !live, let prevTop, let curTop = firstChildTop {
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
                if live || !existing.track.moving {
                    existing.contentSlide = nil
                }
                existing.lastFirstChildTop = firstChildTop
                growthRows[gKey] = existing
                if existing.track.moving {
                    accum.result.activeCount += 1
                }
                let hasStreamingLagClamp = streaming && (existing.track.h < unlaggedH - 0.1 || existing.withheld > 0.01)
                let holdsFoldLift = existing.track.isShut && !existing.track.moving && existing.track.currentLift() > 0 && foldRowHoldsExiting(rowPath: path)
                if (existing.track.moving && (abs(existing.track.h - existing.track.target) > 1e-4 || existing.track.isShuttingFold))
                    || hasStreamingLagClamp || holdsFoldLift {
                    accum.result.needsClampedRelayout = true
                }
            } else {
                let revealedInCommit = enclosingScrollPath != nil && pendingScrollReveals.contains {
                    Self.inScrollRevealScope($0.scope, path: path)
                }
                let stackExisted = (inGrowthSpec != nil) ? !(kitHooks.growthStacks[parentStackPath ?? ""]?.isNewStack ?? true) : (viewCommitCount > 1)
                let startsFromZero = !instantGrowth
                    && !revealedInCommit
                    && (stackExisted || live || (viewCommitCount > 1 && streaming))
                if startsFromZero, el.foldGlideSpec != nil, let sp = parentStackPath, accum.existedStackPaths.contains(sp) {
                    accum.stackOpened[sp, default: []].append(gKey)
                }
                var track: GrowTrack
                if startsFromZero {
                    track = GrowTrack.settled(0)
                    track.setKind(streaming: streaming, whole: whole, glide: glideArg)
                    track.linearEdge = live
                    track.retarget(naturalH)
                    if kitHooks.frameGrowthStepDt > 0 && el.foldGlideSpec == nil {
                        for step in GrowthSteps(duration: Float(kitHooks.frameGrowthStepDt)) {
                            track.step(by: step, spring: spring, edge: edge, carryingTail: false)
                        }
                    }
                    accum.result.needsClampedRelayout = true
                    accum.result.activeCount += 1
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
                    lastWidth: res.layout.localRect.width,
                    lastFirstChildTop: firstChildTop,
                    contentSlide: nil
                )
            }
        }

        let nextGrowth = el.growthSpec
        let nextScrollPath = el.layout.scrollAxes.isEmpty ? enclosingScrollPath : path
        let childScrollY = !el.layout.scrollAxes.isEmpty ? (scrollOffsets[path]?.y ?? 0) : 0
        return (ownStackPath, nextGrowth, nextScrollPath, myWorldY - childScrollY * myScale, myScale)
    }

    internal func updateGrowthRowsPostLayout(
        rootResult: LayoutEngine.ResultNode,
        rootEl: El<State>,
        hasGrowth: Bool,
        cut: Bool,
        snaps: Bool,
        lands: Bool,
        isRelayoutPass: Bool = false,
        reducedMotionOverride: Bool? = nil,
        at now: Double
    ) -> GrowthCaptureResult {
        var accum = GrowthWalkAccum()
        let settleAll = cut || lands || (reducedMotionOverride ?? reducedMotion)
        slice2State.unclampedBottomByPath.removeAll(keepingCapacity: true)

        guard hasGrowth || !growthRows.isEmpty || !growthStacks.isEmpty ||
              !kitHooks.growthStacks.isEmpty || scrollRequestsState.hasKeeps else {
            if lastGrowthStepTime == nil { lastGrowthStepTime = now }
            return accum.result
        }

        let rootPath = rootEl.storageKeyId.map { "/@\($0)" } ?? "/0"
        typealias WalkItem = (
            el: El<State>,
            res: LayoutEngine.ResultNode,
            path: String,
            inGrowthSpec: GrowthSpec?,
            parentStackPath: String?,
            enclosingScrollPath: String?,
            parentWorldY: Float,
            inheritedScale: Float
        )
        var dfsStack: [WalkItem] = [(
            el: rootEl,
            res: rootResult,
            path: rootPath,
            inGrowthSpec: nil,
            parentStackPath: nil,
            enclosingScrollPath: nil,
            parentWorldY: 0,
            inheritedScale: 1
        )]
        while let item = dfsStack.popLast() {
            let (ownStackPath, nextGrowth, nextScrollPath, childParentWorldY, myScale) = processGrowthWalkNode(
                el: item.el,
                res: item.res,
                path: item.path,
                inGrowthSpec: item.inGrowthSpec,
                parentStackPath: item.parentStackPath,
                enclosingScrollPath: item.enclosingScrollPath,
                parentWorldY: item.parentWorldY,
                inheritedScale: item.inheritedScale,
                settleAll: settleAll,
                snaps: snaps,
                isRelayoutPass: isRelayoutPass,
                at: now,
                accum: &accum
            )
            // A row's own growth was just measured. Ordinary cached children have no tracks
            // to measure unless a held sticky header needs their unclamped geometry.
            if nextGrowth == nil, !scrollRequestsState.hasKeeps,
               let children = item.el.memoLayoutChildren, children.matches(item.el.children),
               children.traits.isDisjoint(with: [.growth, .virtual]) { continue }
            if !item.el.children.isEmpty && item.el.children.count == item.res.children.count {
                var childSeen: [String: Int] = [:]
                var childItems: [WalkItem] = []
                childItems.reserveCapacity(item.el.children.count)
                for i in 0..<item.el.children.count {
                    let cEl = item.el.children[i]
                    let cRes = item.res.children[i]
                    let (seg, _) = layoutPathSegment(keyId: cEl.storageKeyId, siblingIndex: i, siblingKeysSeen: &childSeen)
                    childItems.append((
                        el: cEl,
                        res: cRes,
                        path: "\(item.path)/\(seg)",
                        inGrowthSpec: nextGrowth,
                        parentStackPath: ownStackPath,
                        enclosingScrollPath: nextScrollPath,
                        parentWorldY: childParentWorldY,
                        inheritedScale: myScale
                    ))
                }
                dfsStack.append(contentsOf: childItems.reversed())
            }
        }
        if !kitHooks.growthStacks.isEmpty {
            kitHooks.growthStacks = kitHooks.growthStacks.filter { accum.seenStackPaths.contains($0.key) }
        }
        var result = accum.result
        var seenGrowthKeys = accum.seenGrowthKeys
        let seenStackPaths = accum.seenStackPaths
        let hiddenCutsByScroll = accum.hiddenCutsByScroll
        let heldByScroll = accum.heldByScroll
        let reopenedFolds = accum.reopenedFolds
        for sp in accum.seenStackOrder {
            guard var stack = growthStacks[sp] else { continue }
            let newIds = accum.stackNewIds[sp] ?? []
            let newSet = Set(newIds)
            let existed = accum.existedStackPaths.contains(sp) && viewCommitCount > 1
            let virtualList = virtualLists[sp]
            var order: [String] = []
            order.reserveCapacity(newIds.count + 4)
            var remaining = newSet
            var shut: [String] = []
            var ni = 0
            for old in stack.order {
                if newSet.contains(old) {
                    while ni < newIds.count && newIds[ni] != old {
                        if remaining.remove(newIds[ni]) != nil {
                            order.append(newIds[ni])
                        }
                        ni += 1
                    }
                    if remaining.remove(old) != nil {
                        order.append(old)
                    }
                    ni += 1
                } else {
                    let oldPath = old.hasPrefix("fold:") ? String(old.dropFirst(5)) : (old.hasPrefix("growth:") ? String(old.dropFirst(7)) : old)
                    // An evicted virtual row still occupies its measured height in the spacer.
                    // Only a removed row that was actually drawn can hold a closing slot.
                    let holdsPlace = virtualList.map { list in
                        guard let previous = nodeByPath[oldPath].map({ flatNodes[$0] }),
                              let key = previous.key, list.rowPlaces.index(ofAuthoredKey: key) == nil,
                              presentedRectByPath[oldPath] != nil else { return false }
                        return kitHooks.unseenPresence.frameById[previous.nodeId]?.inView != false
                    } ?? true
                    if let entry = growthRows[old],
                       entry.track.h > 0.01,
                       existed,
                       !settleAll,
                       holdsPlace {
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
                if remaining.remove(newIds[ni]) != nil {
                    order.append(newIds[ni])
                }
                ni += 1
            }
            stack.order = order
            if !settleAll && existed {
                linkGrowthRuns(stack: &stack, order: order, opened: accum.stackOpened[sp] ?? [], shut: shut)
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
        slice2State.growthRowPathByKey = slice2State.growthRowPathByKey.filter { seenGrowthKeys.contains($0.key) }
        slice2State.growthScrollByKey = slice2State.growthScrollByKey.filter { seenGrowthKeys.contains($0.key) }

        // Apply `fold_hold` scroll cuts (`scroll_by_cut`), `give_way`, and `ride_from_end`.
        for (vp, cutAmt) in hiddenCutsByScroll where cutAmt > 0 {
            let cur = scrollOffsets[vp] ?? .zero
            let nextY = max(0, cur.y - cutAmt)
            scrollOffsets[vp] = Vec2(cur.x, nextY)
            result.scrollCuts.append((viewport: vp, cut: cutAmt))
            if let maxExt = scrollMaxExtents[vp] {
                scrollMaxExtents[vp] = Vec2(maxExt.x, max(0, maxExt.y - cutAmt))
            }
        }
        for (vp, heldList) in heldByScroll where !heldList.isEmpty {
            let curY = scrollOffsets[vp]?.y ?? 0
            let maxY = scrollMaxExtents[vp]?.y ?? 0
            let slack = (maxY - curY) - heldList.reduce(0) { $0 + $1.below }
            let travel: Float = heldList.compactMap { growthRows[$0.growthKey] }.reduce(0) { $0 + ($1.track.h - $1.track.target) }
            if travel > 1.0 && slack < travel {
                let share = 1.0 - max(0, slack) / travel
                for item in heldList {
                    growthRows[item.growthKey]?.track.give = share
                }
            }
        }
        for reopened in reopenedFolds {
            let vp = reopened.scrollPath
            let pinned = wasPinnedToBottom.contains(vp)
            guard pinned || reopened.giving else { continue }
            result.foldOpens.append(PendingFoldOpen(
                viewport: vp, foldPrefix: reopened.rowPath, giving: reopened.giving, pinned: pinned
            ))
            let shown: Float = {
                guard let rowRect = presentedRectByPath[reopened.rowPath] ?? nodeByPath[reopened.rowPath].map({ flatNodes[$0].targetRect }),
                      let vpRect = presentedRectByPath[vp] ?? nodeByPath[vp].map({ flatNodes[$0].targetRect }) else { return 0 }
                let scale = presentedScales[vp]?.y ?? nodeByPath[vp].map { flatNodes[$0].inheritedScale } ?? 1
                guard scale > 1e-4 else { return 0 }
                return max(0, (rowRect.top - vpRect.top) / scale)
            }()
            if var entry = growthRows[reopened.growthKey] {
                let below = max(0, entry.track.target - entry.track.h - entry.track.currentLift())
                entry.track.rideUp(shown + below)
                growthRows[reopened.growthKey] = entry
                if entry.track.moving {
                    result.needsClampedRelayout = true
                }
            }
        }
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
        by dt: Float,
        spring: Spring,
        edge: StreamEdge
    ) -> Set<String> {
        var movedKeys: Set<String> = []
        var kept: [RuntimeGrowthRun] = []
        kept.reserveCapacity(stack.runs.count)
        for var run in stack.runs {
            _ = run.step(by: dt, spring: spring, edge: edge, grows: &grows)
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
        func walk(_ el: El<State>, parentPath: String, siblingIndex: Int, siblingKeysSeen: inout [String: Int], inGrowthSpec: GrowthSpec?) -> El<State> {
            let (seg, _) = layoutPathSegment(keyId: el.storageKeyId, siblingIndex: siblingIndex, siblingKeysSeen: &siblingKeysSeen)
            let path = parentPath.isEmpty ? (el.storageKeyId.map { "/@\($0)" } ?? "/0") : "\(parentPath)/\(seg)"
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
                            let height = max(0, t.h)
                            let border = el.layout.borderLayout
                                ? TaffyBridge.snappedBorderSides(el.borderSides ?? .all(el.borderWidth), pixelScale: pixelScale)
                                : el.layout.border
                            let insetHeight = max(0, el.layout.padding.top) + max(0, el.layout.padding.bottom) + border.top + border.bottom
                            out.layout.usesNaturalGrowthContents = height < insetHeight
                            let boxHeight = el.layout.boxSizingBorderBox || height < insetHeight ? height : height - insetHeight
                            out.layout.height = .points(boxHeight)
                            out.layout.minHeight = .points(boxHeight)
                            out.layout.maxHeight = .points(boxHeight)
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
                                let width = min(featherH, max(1, t.h))
                                out.clipFade = SIMD4(0, 0, 0, t.linearEdge ? -width : width)
                            }
                        }
                        if el.joinedRowFaceKey != nil && (el.layout.clipOverflow != out.layout.clipOverflow || el.clipFade != out.clipFade) {
                            out.growthReveal = GrowthReveal(authoredClip: el.layout.clipOverflow, authoredFade: el.clipFade)
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

    internal func advanceGrowthRows(at now: Double, headers: [String: String], markRelayoutDirty: Bool = true) -> Bool {
        var flushedHold = false
        let prevNow = lastGrowthStepTime
        let hasDeferredAtEnd = growthStacks.values.contains { !$0.pendingHeights.isEmpty || !$0.closing.isEmpty || !$0.runs.isEmpty }
        let hasClosing = kitHooks.growthStacks.values.contains { !$0.closing.isEmpty }
        let dt = prevNow.map { max(0, min(1, now - $0)) } ?? (1.0 / 60.0)
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
            return false
        }

        if dt <= 0 {
            flushReleasedHolds(at: now)
            if flushedHold && markRelayoutDirty {
                needsCommit = true
                commitWhyPending |= CommitWhy.relayout
                pendingGrowthRelayout = true
            }
            let hasPending = growthStacks.values.contains { !$0.pendingHeights.isEmpty || !$0.closing.isEmpty || !$0.runs.isEmpty }
            let closingMoving = kitHooks.growthStacks.values.contains { $0.closing.values.contains { $0.track.moving } }
            return hasPending || growthRows.values.contains { $0.track.moving } || closingMoving || !slice2State.liveContentSlides.slides.isEmpty
        }

        let substeps = GrowthSteps(duration: Float(dt))
        let startHeights = growthRows.mapValues { $0.track.h }
        var anyChanged = false
        var anyMoving = false
        var restored: [(gKey: String, r: Float)] = []
        var gave: [(gKey: String, d: Float)] = []
        if !substeps.isEmpty {
            var working = growthRows
            var workingStacks = growthStacks
            let initialHeights: [String: Float] = working.mapValues { $0.track.h }
            let initialMasks: [String: Float] = working.mapValues { $0.track.mask }
            let initiallyMoving: [String: Bool] = working.mapValues { $0.track.moving }
            var ranInBlockKeys: Set<String> = []
            var subNow = now - dt
            for step in substeps {
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
                            by: step,
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
                    entry.track.step(by: step, spring: entry.spring, edge: entry.edge, carryingTail: false)
                    if let vp = slice2State.growthScrollByKey[k] {
                        let grown = max(0, entry.track.h - prevH)
                        if grown > 0 {
                            slice2State.growthGrownByScrollPath[vp, default: 0] += grown
                        }
                    }
                    if !entry.track.moving {
                        entry.contentSlide = nil
                    }
                    working[k] = entry
                    if abs(entry.track.h - prevH) > 1e-5 || abs(entry.track.mask - prevM) > 1e-5 || (wasMoving && !entry.track.moving) {
                        anyChanged = true
                    }
                }
                subNow += Double(step)
            }
            if !slice2State.liveContentSlides.slides.isEmpty {
                let rows = Set(slice2State.liveContentSlides.slides.map(\.row))
                for row in rows {
                    guard let node = mountedNode(row) else {
                        slice2State.liveContentSlides.land(row: row)
                        continue
                    }
                    let prefix = node.el.foldGlideSpec == nil ? "growth:" : "fold:"
                    guard let entry = working[prefix + node.path] else {
                        slice2State.liveContentSlides.land(row: row)
                        continue
                    }
                    slice2State.liveContentSlides.step(row: row, growth: entry.track, spring: entry.spring, steps: substeps)
                }
                anyChanged = true
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
            if let headerPath = headers[gKey] {
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
                    for step in substeps {
                        row.track.step(by: step, spring: row.spring, edge: row.edge, carryingTail: false)
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
            commitWhyPending |= CommitWhy.relayout
            pendingGrowthRelayout = true
        }
        return anyMoving || hasPendingHold || !slice2State.liveContentSlides.slides.isEmpty
    }

    // MARK: - Post-Commit Virtual Measurements & onVisibleRows

    /// Keep the virtual window anchored to natural row heights throughout a growth animation.
    /// The solved layout contains those heights before growth constrains the presented rows.
    internal func measureVirtualsFromSolved(
        expandedRoot: El<State>,
        solvedRoot: LayoutEngine.ResultNode,
        expansion: VirtualExpansionContext,
        lands: Bool
    ) -> Bool {
        guard expansion.anyVirtualList, !expansion.listMeta.isEmpty else { return false }
        let listPathSet = Set(expansion.listMeta.map(\.listPath))
        let scrollPathSet = Set(expansion.listMeta.map(\.scrollPath))
        // Only the lists, their immediate row heights and their viewports affect virtual measurement.
        // Avoid copying and visiting every descendant of every mounted row just to find those nodes.
        var ancestorPaths = Set<String>()
        for target in listPathSet.union(scrollPathSet) {
            var parent = target[...]
            while let separator = parent.lastIndex(of: "/") {
                parent = parent[..<separator]
                if !ancestorPaths.insert(String(parent)).inserted { break }
            }
        }
        var listWorldY: [String: Float] = [:]
        var scrollRects: [String: (y: Float, size: Vec2)] = [:]
        var rowHeightsByList: [String: [String: Float]] = [:]

        let rootKey = expandedRoot.storageKeyId
        let rootPath = rootKey.map { "/@\($0)" } ?? "/0"
        typealias WalkEntry = (el: El<State>, solved: LayoutEngine.ResultNode, path: String, worldY: Float)
        var stack: [WalkEntry] = [(expandedRoot, solvedRoot, rootPath, solvedRoot.layout.localRect.y)]
        while let cur = stack.popLast() {
            let lr = cur.solved.layout.localRect
            if scrollPathSet.contains(cur.path) {
                scrollRects[cur.path] = (cur.worldY, Vec2(lr.width, lr.height))
            }
            if listPathSet.contains(cur.path) {
                listWorldY[cur.path] = cur.worldY
                var segHeights: [String: Float] = [:]
                var childSeen: [String: Int] = [:]
                for (cIdx, childEl) in cur.el.children.enumerated() where cIdx < cur.solved.children.count {
                    let (seg, _) = layoutPathSegment(keyId: childEl.storageKeyId, siblingIndex: cIdx, siblingKeysSeen: &childSeen)
                    let ch = cur.solved.children[cIdx].layout.localRect.height
                    if ch > 0.5 {
                        segHeights[seg] = ch
                    }
                }
                rowHeightsByList[cur.path] = segHeights
            }
            guard ancestorPaths.contains(cur.path) else { continue }
            var childSeen: [String: Int] = [:]
            let n = min(cur.el.children.count, cur.solved.children.count)
            var nextEntries: [WalkEntry] = []
            nextEntries.reserveCapacity(n)
            for cIdx in 0..<n {
                let childEl = cur.el.children[cIdx]
                let childSolved = cur.solved.children[cIdx]
                let (seg, _) = layoutPathSegment(keyId: childEl.storageKeyId, siblingIndex: cIdx, siblingKeysSeen: &childSeen)
                let wy = cur.worldY + childSolved.layout.localRect.y
                nextEntries.append((childEl, childSolved, "\(cur.path)/\(seg)", wy))
            }
            stack.append(contentsOf: nextEntries.reversed())
        }

        for mapping in expansion.rowMappings {
            if let h = rowHeightsByList[mapping.listPath]?[mapping.rowSegment],
               h > 0.5,
               virtualLists[mapping.listPath]?.measuredByKey[mapping.rowKey] != h {
                virtualLists[mapping.listPath]?.measuredByKey[mapping.rowKey] = h
            }
        }

        var needsRetry = false
        for meta in expansion.listMeta {
            guard var vState = virtualLists[meta.listPath],
                  let sInfo = scrollRects[meta.scrollPath] else { continue }
            vState.measuredByKey.prepareOffsets(estimated: meta.estimate, gap: vState.gap)
            virtualLists[meta.listPath] = vState
            scrollViewportSizes[meta.scrollPath] = sInfo.size
            let vpH = max(1, sInfo.size.y)
            let mounted = vState.lastMountedRange
            let count = vState.lastKeys.count
            guard count > 0 else { continue }
            let (prefix, total) = vState.computeOffsets(estimated: meta.estimate)
            let topOffset = max(0, (listWorldY[meta.listPath] ?? sInfo.y) - sInfo.y)
            let pinned = (lands && meta.stickBottom) || wasPinnedToBottom.contains(meta.scrollPath)
            let destination = pendingVirtualReveal(places: vState.rowPlaces, list: meta.listPath)
            var rawOff = scrollOffsets[meta.scrollPath]?.y ?? 0
            if destination == nil, !pinned,
               let anchorKey = vState.lastAnchorKey,
               !scrollRequestsState.owns(meta.scrollPath),
               let anchorIdx = vState.rowPlaces.index(of: anchorKey) {
                let prefixDelta = vState.padTop + prefix[anchorIdx] - vState.lastAnchorPrefixY
                if abs(prefixDelta) > 0.25 {
                    rawOff = max(0, min(max(0, topOffset + vState.extent(total: total) - vpH), rawOff + prefixDelta))
                    let curVec = scrollOffsets[meta.scrollPath] ?? .zero
                    let nextVec = Vec2(curVec.x, rawOff)
                    scrollOffsets[meta.scrollPath] = nextVec
                    scrollStore.snap(NodeId.hash("scroll:\(meta.scrollPath)"), Props.SCROLL, to: nextVec)
                    virtualLists[meta.listPath]?.lastAnchorPrefixY = vState.padTop + prefix[anchorIdx]
                }
            }
            let maxOff = max(0, vState.extent(total: total) - vpH)
            let actualOffset = max(0, min(maxOff, rawOff - topOffset))
            let offset = vState.revealWindowOffset(row: destination, prefix: prefix, viewport: vpH, from: actualOffset)
            if vState.leavesVisibleGap(offset: offset, viewport: vpH, prefix: prefix, pinned: pinned) {
                needsRetry = true
            }
            let (postWanted, postMissing) = vState.postMeasureWindowNeed(
                offset: offset,
                viewport: vpH,
                prefix: prefix,
                count: count,
                mounted: mounted,
                indexed: meta.indexed,
                pinned: pinned
            )
            virtualLists[meta.listPath]?.wantsMoreFrames = postWanted
            virtualLists[meta.listPath]?.missingOverscanRows = postMissing
        }
        return needsRetry
    }

    internal func virtualListsNeedWindowUpdate() -> Bool {
        if activeVirtualPaths.isEmpty { return false }
        for listPath in activeVirtualPaths {
            guard let vState = virtualLists[listPath] else { return true }
            if vState.wantsMoreFrames { return true }
            let est = max(1, (nodeByPath[listPath].flatMap { flatNodes[$0].el.virtualEstimate }) ?? 40)
            let scrollIdx = nodeByPath[listPath].flatMap {
                !flatNodes[$0].el.layout.scrollAxes.isEmpty ? $0 : flatNodes[$0].enclosingVScrollIndex
            }
            let scrollPath = scrollIdx.map { flatNodes[$0].path } ?? listPath
            let vpH = max(1, scrollViewportSizes[scrollPath]?.y ?? viewport.y)
            let offsetY = scrollOffsets[scrollPath]?.y ?? 0
            let (prefix, total) = vState.computeOffsets(estimated: est)
            let stickBottom = scrollIdx.map { flatNodes[$0].el.layout.stickBottom } == true
                && wasPinnedToBottom.contains(scrollPath)
            let (offset, pinned) = vState.at(offsetY, pinned: stickBottom, total: total)
            if vState.needsWindow(offset: offset, viewport: vpH, prefix: prefix, count: vState.lastKeys.count, pinned: pinned) {
                return true
            }
        }
        return false
    }

    internal func updateVirtualVisibleRowsOnScroll() {
        for listPath in activeVirtualPaths {
            syncVirtualVisibleRange(for: listPath)
        }
    }

    private func syncVirtualVisibleRange(for listPath: String) {
        guard var vState = virtualLists[listPath] else { return }
        let est = max(1, (nodeByPath[listPath].flatMap { flatNodes[$0].el.virtualEstimate }) ?? 40)
        let scrollIdx = nodeByPath[listPath].flatMap {
            !flatNodes[$0].el.layout.scrollAxes.isEmpty ? $0 : flatNodes[$0].enclosingVScrollIndex
        }
        let scrollPath = scrollIdx.map { flatNodes[$0].path } ?? listPath
        let vpH = max(1, scrollViewportSizes[scrollPath]?.y ?? viewport.y)
        let offsetY = scrollOffsets[scrollPath]?.y ?? 0
        let (prefix, total) = vState.computeOffsets(estimated: est)
        // Where the laid-out list stands in its viewport's content (`top`, `tail`).
        let placedBefore = (vState.top, vState.tail)
        if let lIdx = nodeByPath[listPath], let sIdx = scrollIdx {
            Self.measureVirtualPlacement(&vState, listIdx: lIdx, scrollIdx: sIdx, nodes: flatNodes)
        }
        vState.viewport = vpH
        let stickyPin = nodeByPath[scrollPath].map { flatNodes[$0].el.layout.stickBottom } == true
            && wasPinnedToBottom.contains(scrollPath)
        let (listOffsetY, listPinned) = vState.locate(offsetY, pinned: stickyPin, total: total)
        let vis = vState.visibleRange(offset: listOffsetY, viewport: vpH, prefix: prefix, count: vState.lastKeys.count)

        if !vis.isEmpty && !listPinned && !vState.passed {
            let ai = vis.first { vState.measuredByKey.heights[$0] != nil } ?? vis.lowerBound
            vState.lastAnchorKey = vState.lastKeys[ai]
            vState.lastAnchorPrefixY = vState.padTop + prefix[ai]
            vState.lastAnchorLocalY = listOffsetY - vState.lastAnchorPrefixY
        } else if listPinned || vState.passed {
            vState.lastAnchorKey = nil
            vState.lastAnchorLocalY = 0
        }
        // A list placed somewhere new in its viewport (a section opening above it, a nested
        // list's first layout) windows where it now stands.
        if abs(vState.top - placedBefore.0) > 0.5 || abs(vState.tail - placedBefore.1) > 0.5,
           vState.needsWindow(offset: listOffsetY, viewport: vpH, prefix: prefix, count: vState.lastKeys.count, pinned: listPinned) {
            needsCommit = true
            commitWhyPending |= CommitWhy.virtual
        }
        vState.lastCommittedOffsetY = offsetY
        virtualLists[listPath] = vState
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
            let hasPendingReveal = pendingScrollReveals.contains { req in
                Self.inScrollRevealScope(req.scope, path: listPath)
            }
            if scrollRequestsState.owns(scrollPath) || directScrolledPaths.contains(scrollPath) || hasPendingReveal {
                continue
            }
            let est = max(1, (pass.byPath[listPath].flatMap { pass.nodes[$0].el.virtualEstimate }) ?? 40)
            let vpH = scrollIdx.map { max(1, pass.nodes[$0].targetRect.height) } ?? max(1, viewport.y)
            let stickyPin = scrollIdx.map { pass.nodes[$0].el.layout.stickBottom } == true
                && savedWasPinned.contains(scrollPath)
            let (prefixBefore, totalBefore) = vBefore.computeOffsets(estimated: est)
            let oldY = savedScrollOffsets[scrollPath]?.y ?? 0
            var located = vBefore
            let (oldListY, oldPinned) = located.locate(oldY, pinned: stickyPin, total: totalBefore)
            let visBefore = vBefore.visibleRange(offset: oldListY, viewport: vpH, prefix: prefixBefore, count: vBefore.lastKeys.count)

            // Where the list now stands in its viewport's content (`top`, `tail`, as laid out).
            if let lIdx = pass.byPath[listPath], let sIdx = scrollIdx {
                Self.measureVirtualPlacement(&vAfter, listIdx: lIdx, scrollIdx: sIdx, nodes: pass.nodes)
            }
            let (prefixAfter, totalAfter) = vAfter.computeOffsets(estimated: est)
            let nextY: Float
            if stickyPin {
                // The viewport's own pin moves its offset; a nested list stands where it leaves it.
                nextY = vAfter.nested ? oldY : max(0, vAfter.top + vAfter.extent(total: totalAfter) - vpH)
            } else if !oldPinned, !located.passed,
                      let aIdx = visBefore.isEmpty ? nil : visBefore.lowerBound,
                      aIdx < prefixBefore.count,
                      aIdx < prefixAfter.count {
                let delta = vAfter.padTop + prefixAfter[aIdx] - vBefore.padTop - prefixBefore[aIdx]
                let listY = max(0, min(max(0, vAfter.extent(total: totalAfter) - vpH), oldListY + delta))
                nextY = max(0, oldY + listY - oldListY)
                vAfter.lastAnchorKey = vAfter.lastKeys[aIdx]
                vAfter.lastAnchorLocalY = oldListY - (vBefore.padTop + prefixBefore[aIdx])
            } else {
                nextY = oldY
            }
            let shifted = abs(nextY - oldY) > 0.05
            let (nextListY, nextPinned) = vAfter.locate(nextY, pinned: stickyPin, total: totalAfter)
            let windowShort = vAfter.leavesVisibleGap(offset: nextListY, viewport: vpH, prefix: prefixAfter, pinned: nextPinned)
            // A list placed somewhere new windows where it now stands (its new `top`/`tail`).
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
            let (prefix, total) = vState.computeOffsets(estimated: est)
            let stickyPin = scrollIdx.map { flatNodes[$0].el.layout.stickBottom } == true
                && wasPinnedToBottom.contains(scrollPath)
            // The list's own offset within its window (`window_offset`: `VirtualList::at`).
            let (listOffsetY, listPinned) = vState.at(curScroll.y, pinned: stickyPin, total: total)
            let (listWanted, listMissing) = vState.fillDemand(
                offset: listOffsetY,
                viewport: vpH,
                prefix: prefix,
                count: count,
                pinned: listPinned
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

        let topRamp: (width: Float, offset: Float) = (el.layout.scrollAxes.contains(.vertical) && hidTop > 0.01 && startW > 0)
            ? ScrollEdgeMath.edgeRamp(style: startStyle, width: startW, hidden: Double(hidTop), scale: 1.0)
            : (0, 0)
        let botRamp: (width: Float, offset: Float) = (el.layout.scrollAxes.contains(.vertical) && hidBot > 0.01 && endW > 0)
            ? ScrollEdgeMath.edgeRamp(style: endStyle, width: endW, hidden: Double(hidBot), scale: 1.0)
            : (0, 0)
        let leftRamp: (width: Float, offset: Float) = (el.layout.scrollAxes.contains(.horizontal) && hidLeft > 0.01 && startW > 0)
            ? ScrollEdgeMath.edgeRamp(style: startStyle, width: startW, hidden: Double(hidLeft), scale: 1.0)
            : (0, 0)
        let rightRamp: (width: Float, offset: Float) = (el.layout.scrollAxes.contains(.horizontal) && hidRight > 0.01 && endW > 0)
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
                let localDelta = Vec2(signedOwnX, -ownDelta.y)
                let inv = Vec2(cumulative[pIdx].x + localDelta.x, cumulative[pIdx].y + localDelta.y)
                cumulative[i] = inv
                // Carry the existing frame and its motion with the viewport before committing the new rect.
                let id = flatNodes[i].nodeId
                scene.translateFrame(id, by: localDelta, screenDelta: inv, carryTakeoff: !launchedFlightIds.contains(id))
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
        }
    }

    /// Keeps use the painted box in window coordinates, including turns about the row's or an ancestor's pivot.
    private func scrollKeepBounds(_ path: String) -> MotionRect? {
        guard let geometry = hitGeometryByPath[path] else { return presentedRectByPath[path] }
        return geometry.turn?.bbox(geometry.rect) ?? geometry.rect
    }

    internal func captureKeepAnchorsBeforeCommit() {
        let drawnRect: (FlatNode) -> MotionRect = { node in
            self.scrollKeepBounds(node.path) ?? node.targetRect
        }

        // `El.scrollAnchor`: anchor the first visible non-sticky row when viewport is scrolled off top.
        var anchorPaths: [String] = []
        if !flatNodes.isEmpty {
            for sIdx in layoutObservers.scrollAnchors {
                let sNode = flatNodes[sIdx]
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
                    guard let childIdx = ((parentIdx + 1)..<flatNodes.count).first(where: { j in
                        guard flatNodes[j].parentIndex == parentIdx, flatNodes[j].el.stickyConfig == nil else { return false }
                        let r = drawnRect(flatNodes[j])
                        return r.width > 0 && r.height > 0
                            && r.bottom > vpRect.top + 0.5
                            && r.top < vpRect.bottom
                    }) else {
                        break
                    }
                    let cNode = flatNodes[childIdx]
                    if activeVirtualPaths.contains(cNode.path) { break }
                    let r = drawnRect(cNode)
                    let hasChildren = childIdx + 1 < flatNodes.count && flatNodes[childIdx + 1].parentIndex == childIdx
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
                let isTopSticky: Bool = {
                    if case .top = hNode.el.stickyConfig?.edge { return true }
                    return scrollRequestsState.keeps.compactMap(\.hold).contains { $0.path == hNode.path }
                }()
                if isTopSticky, abs(stuckShiftsByPath[hNode.path]?.y ?? 0) > 0.01 {
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
        _ = now
        _ = cut

        var keepDeltas: [String: Vec2] = [:]
        for k in scrollRequestsState.keeps {
            guard let vIdx = flatNodes.firstIndex(where: { $0.path == k.viewport && $0.el.layout.scrollAxes.contains(.vertical) }) else {
                continue
            }
            let vNode = flatNodes[vIdx]
            let vPath = vNode.path
            let cur = scrollOffsets[vPath] ?? .zero
            let maxExt = scrollMaxExtents[vPath] ?? .zero

            if flatNodes.contains(where: { $0.path == k.path }) {
                let vpPrefix = vPath + "/"
                let isGrowing = slice2State.growthScrollByKey.contains { (gKey, vp) in
                    vp == vPath
                        && (growthRows[gKey]?.track).map { $0.target > $0.h + (1.0 / 128.0) } == true
                        && (slice2State.growthRowPathByKey[gKey]?.hasPrefix(vpPrefix) ?? false)
                }
                if isGrowing {
                    wasPinnedToBottom.remove(vPath)
                }
                // Mounted anchors follow drawn geometry in `followKeeps(frameOut:at:)`.
                continue
            }

            let laidRelTop: Float
            if let vr = k.virtualRow,
               let vState = virtualLists[vr.listPath],
               let listIdx = flatNodes.firstIndex(where: { $0.path == vr.listPath }),
               let rowIdx = vState.rowPlaces.index(of: vr.rowKey) {
                let est = Float(flatNodes[listIdx].el.virtualEstimate ?? 40)
                let prefixY = vState.prefix(rowIdx, estimated: est)
                let laidRowTop = flatNodes[listIdx].targetRect.top + prefixY + vr.yInRow
                laidRelTop = laidRowTop - vNode.targetRect.top
            } else {
                continue
            }

            let delta = laidRelTop - k.was
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
        return keepDeltas
    }

    internal func followKeeps(frameOut: inout FrameOutput, at now: Double) -> Bool {
        guard !scrollRequestsState.isEmpty else { return false }

        var givingHeaders: Set<String> = []
        for (gKey, header) in foldHeaders {
            if let entry = growthRows[gKey],
               let share = entry.track.give,
               (entry.track.h - entry.track.target) * (1.0 - share) < 0.5 {
                givingHeaders.insert(header)
            }
        }
        scrollRequestsState.stepEndTakesOver(
            givingHeaders: givingHeaders,
            isPinned: { wasPinnedToBottom.contains($0) }
        )

        var deltas: [String: Vec2] = [:]
        for k in scrollRequestsState.keeps {
            guard let tIdx = nodeByPath[k.path],
                  let vIdx = flatNodes[tIdx].enclosingVScrollIndex,
                  flatNodes[vIdx].path == k.viewport,
                  let drawnI = scrollKeepBounds(k.path),
                  let drawnS = scrollKeepBounds(k.viewport) else {
                continue
            }
            let sNode = flatNodes[vIdx]
            let scale = max(1e-4, presentedScales[k.viewport]?.x ?? sNode.inheritedScale)
            let delta = (drawnI.top - drawnS.top - k.was) / scale
            if abs(delta) < (1.0 / 64.0) { continue }
            let cur = scrollOffsets[k.viewport] ?? .zero
            let maxExt = scrollMaxExtents[k.viewport] ?? .zero
            let toY = max(0, min(maxExt.y, cur.y + delta))
            if abs(toY - cur.y) < 1e-5 { continue }

            let next = Vec2(cur.x, toY)
            let nid = NodeId.hash("scroll:\(k.viewport)")
            scrollStore.snap(nid, Props.SCROLL, to: next)
            scrollOffsets[k.viewport] = next
            scrollGlidingPaths.remove(k.viewport)
            updateScrollMode(forPath: k.viewport, event: .moved)
            deltas[k.viewport] = Vec2(0, (deltas[k.viewport]?.y ?? 0) + (toY - cur.y))
            if sNode.el.layout.stickBottom && delta >= 0 && maxExt.y > 0.5 && abs(toY - maxExt.y) <= 1.0 {
                wasPinnedToBottom.insert(k.viewport)
            } else if toY < maxExt.y - 1.0 {
                wasPinnedToBottom.remove(k.viewport)
            }
        }

        // A centred row or text mark can move again when neighbouring virtual rows measure.
        for reveal in scrollRequestsState.reveals where reveal.center {
            let viewportPath = reveal.viewport
            guard let target = mountedRevealTarget(reveal),
                  let view = presentedRectByPath[viewportPath],
                  let offset = scrollOffsets[viewportPath] else { continue }
            let node = flatNodes[target.nodeIndex]
            guard let drawn = presentedRectByPath[node.path] else { continue }
            let scale = presentedScales[viewportPath]?.y ?? 1
            guard scale > 1e-4 else { continue }
            let nodeScale = presentedScales[node.path]?.y ?? 1
            let top = (drawn.top + (target.rect.top - node.targetRect.top) * nodeScale - view.top) / scale
            let height = target.rect.height * nodeScale
            let to = min(scrollMaxExtents[viewportPath]?.y ?? 0,
                         max(0, offset.y + top - max(0, view.height - height) / (2 * scale)))
            let gliding = scrollGlidingPaths.contains(viewportPath)
            let nid = NodeId.hash("scroll:" + viewportPath)
            let aim = gliding ? scrollStore.target(nid, Props.SCROLL)?.y ?? offset.y : offset.y
            guard abs(aim - to) >= 1.0 / 64.0 else { continue }
            applyScrollOffsetRequest(path: viewportPath, x: nil, y: to,
                                     glide: gliding ? MotionTokens.GLIDE : nil, cut: false, animNow: now, holdHover: false)
            if let next = scrollOffsets[viewportPath], abs(next.y - offset.y) > 1e-5 {
                deltas[viewportPath, default: .zero].y += next.y - offset.y
            }
        }

        if !deltas.isEmpty {
            var deltaByViewportId: [NodeId: Vec2] = [:]
            for (vpPath, dv) in deltas {
                if let vpIdx = nodeByPath[vpPath] {
                    deltaByViewportId[flatNodes[vpIdx].nodeId] = dv
                }
            }
            var cumDeltaByNodeId: [NodeId: Vec2] = [:]
            for idx in frameOut.nodes.indices {
                let p = frameOut.nodes[idx]
                let inheritedDelta: Vec2
                if let pid = p.parent {
                    let parentOwn = deltaByViewportId[pid] ?? .zero
                    let parentAcc = cumDeltaByNodeId[pid] ?? .zero
                    inheritedDelta = Vec2(parentAcc.x + parentOwn.x, parentAcc.y + parentOwn.y)
                } else {
                    inheritedDelta = .zero
                }
                cumDeltaByNodeId[p.id] = inheritedDelta
                if inheritedDelta != .zero {
                    frameOut.nodes[idx].rect = frameOut.nodes[idx].rect.offsetBy(
                        Vec2(-inheritedDelta.x, -inheritedDelta.y)
                    )
                    frameOut.byId[p.id] = frameOut.nodes[idx]
                }
            }
            if lastCommittedSpecs.count == flatNodes.count {
                shiftFlatAndSpecsForScrollDeltas(deltas, specs: &lastCommittedSpecs)
                scene.keepFlights(false)
                for id in launchedFlightIds {
                    if let i = nodeIndexById[id], let target = launchScrollById[id]?.layoutTarget {
                        lastCommittedSpecs[i].launchLayout = .projectEndpoint
                        lastCommittedSpecs[i].rect.bottom = lastCommittedSpecs[i].rect.top + target.height
                    }
                }
                scene.commit(lastCommittedSpecs, at: now, initialCut: false)
            }
            return true
        }
        return false
    }

    private func mountedRevealTarget(_ reveal: ScrollRevealTarget) -> (nodeIndex: Int, rect: MotionRect)? {
        guard let viewport = nodeByPath[reveal.viewport] else { return nil }
        func accepts(_ index: Int) -> Bool {
            let node = flatNodes[index]
            guard node.enclosingVScrollIndex == viewport, !subtreeExiting(index) else { return false }
            guard let scope = reveal.scope else { return true }
            var parent = node.parentIndex
            while let i = parent {
                let owner = flatNodes[i]
                if selectsElementSelector(scope, path: owner.path, key: owner.key) { return true }
                parent = owner.parentIndex
            }
            return false
        }
        if let i = flatNodes.indices.first(where: { i in
            let node = flatNodes[i]
            return selectsElementSelector(reveal.key, path: node.path, key: node.key) && accepts(i)
        }) {
            return (i, flatNodes[i].targetRect)
        }
        return highlightTargetWithNode(selector: reveal.key, including: accepts)
    }

    internal func finishKeeps(cut: Bool) {
        guard !scrollRequestsState.isEmpty else { return }
        scrollRequestsState.stepEndClamps { k in
            guard let tIdx = nodeByPath[k.path] else { return .unmounted }
            guard let vIdx = flatNodes[tIdx].enclosingVScrollIndex else { return .loose }
            let vPath = flatNodes[vIdx].path
            if !wasPinnedToBottom.contains(vPath) { return .free }
            let tRect = scrollKeepBounds(k.path) ?? flatNodes[tIdx].targetRect
            let vRect = scrollKeepBounds(vPath) ?? flatNodes[vIdx].targetRect
            return .pinned(tRect.top - vRect.top)
        }

        let isRevealTargetMounted: (ScrollRevealTarget) -> Bool = { target in
            self.mountedRevealTarget(target) != nil
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
                    if scrollGlidingPaths.contains(vPath) || scrollStore.isAnimating {
                        return true
                    }
                    if slice2State.scrollSlacks[vPath]?.moving == true
                        || slice2State.scrollModes[vPath]?.hand.laid != nil
                        || (needsCommit && virtualLists.values.contains { $0.scrollPath == vPath }) {
                        return true
                    }
                    let prefix = vPath + "/"
                    for n in flatNodes where n.path == vPath || n.path.hasPrefix(prefix) {
                        if scene.isEdgeAnimating(n.nodeId)
                            || growthRows["growth:\(n.path)"]?.track.moving == true
                            || growthRows["fold:\(n.path)"]?.track.moving == true {
                            return true
                        }
                    }
                    return false
                },
                mounted: isRevealTargetMounted
            )
        }
    }

    internal func processScrollRequestsAndCallbacks(at now: Double, cut: Bool, followEdge: Bool, snaps: Bool = false) {
        func findScrollViewportIndex(forNode idx: Int, verticalOnly: Bool = false) -> Int? {
            var cur = flatNodes[idx].parentIndex
            while let ci = cur {
                let axes = flatNodes[ci].el.layout.scrollAxes
                let matchesAxis = verticalOnly ? axes.contains(.vertical) : !axes.isEmpty
                if matchesAxis { return ci }
                cur = flatNodes[ci].parentIndex
            }
            return nil
        }

        // A mounted virtual row can temporarily be laid out among closing rows from the previous
        // window. Its position in the scroll content comes from the measured virtual prefix.
        func contentTop(node index: Int, rect: MotionRect, viewport vIdx: Int, offset: Float) -> Double {
            var row = index
            let viewport = flatNodes[vIdx]
            while let parent = flatNodes[row].parentIndex {
                let stack = flatNodes[parent]
                if let list = virtualLists[stack.path], list.scrollPath == viewport.path,
                   let key = flatNodes[row].key, let item = list.rowPlaces.index(ofAuthoredKey: key) {
                    let estimate = max(1, stack.el.virtualEstimate ?? 40)
                    let top = list.top + list.padTop + list.prefix(item, estimated: estimate)
                    return Double(top + rect.top - flatNodes[row].targetRect.top)
                }
                if parent == vIdx { break }
                row = parent
            }
            return Double(rect.top - viewport.targetRect.top + offset)
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
                return findScrollViewportIndex(forNode: targetIdx)
            }
            return nil
        }

        func applyScrollOffset(path: String, next: Vec2, glide: Spring?) {
            setScrollOffset(path: path, next: next, glide: glide, cut: cut, animNow: now)
        }

        if followEdge {
            for i in flatNodes.indices where !flatNodes[i].el.layout.scrollAxes.isEmpty && flatNodes[i].el.layout.stickBottom {
                let path = flatNodes[i].path
                scrollRequestsState.stepNewTail(viewport: path, key: flatNodes[i].key ?? path)
                if wasPinnedToBottom.contains(path) {
                    if !cut && !snaps {
                        if slice2State.scrollSlacks[path] == nil {
                            slice2State.scrollSlacks[path] = ScrollSlack.landed(window: (viewport.x, viewport.y))
                        }
                        slice2State.scrollSlacks[path]?.follow = true
                    }
                } else {
                    let maxExt = scrollMaxExtents[path] ?? .zero
                    applyScrollOffset(path: path, next: Vec2(scrollOffsets[path]?.x ?? 0, maxExt.y), glide: cut ? nil : MotionTokens.GLIDE)
                }
            }
        }

        var reveals = pendingScrollReveals
        pendingScrollReveals.removeAll(keepingCapacity: true)
        let bottoms = pendingScrollBottoms
        pendingScrollBottoms.removeAll(keepingCapacity: true)
        let pages = pendingScrollPages
        pendingScrollPages.removeAll(keepingCapacity: true)
        // Jumps a landing re-commit places again come first; this commit's own requests follow.
        let offsets = scrollKeyLandings.take(pendingScrollOffsets)
        pendingScrollOffsets.removeAll(keepingCapacity: true)

        let followCaret = pendingCaretFollow
        pendingCaretFollow = false
        let destination = !bottoms.isEmpty || !pages.isEmpty || !offsets.isEmpty
        let landing = reveals.isEmpty && !destination && !followCaret && !virtualRevealLandings.isEmpty
        if landing {
            reveals = virtualRevealLandings
        } else if !reveals.isEmpty || destination || followCaret {
            scrollRequestsState.stepCancel()
        }
        virtualRevealLandings.removeAll(keepingCapacity: true)

        for req in reveals {
            let vIdx: Int
            let vPath: String
            let cur: Vec2
            let vpH: Double
            let itemH: Double
            let itemTop: Double

            // A virtual row estimate can stand in for an unmounted descendant. Once mounted,
            // the requested element or highlight supplies its own bounds (`reveal_row_once`).
            if let tIdx = flatNodes.indices.first(where: {
                let node = flatNodes[$0]
                return selectsElementSelector(req.key, path: node.path, key: node.key)
                    && (node.parentIndex.map { Self.inScrollRevealScope(req.scope, path: flatNodes[$0].path) } ?? true)
            }),
               let foundVIdx = findScrollViewportIndex(forNode: tIdx, verticalOnly: true) {
                vIdx = foundVIdx
                vPath = flatNodes[vIdx].path
                let vpRect = flatNodes[vIdx].targetRect
                let tRect = flatNodes[tIdx].targetRect
                cur = scrollOffsets[vPath] ?? .zero
                vpH = Double(vpRect.height)
                itemH = Double(tRect.height)
                itemTop = contentTop(node: tIdx, rect: tRect, viewport: vIdx, offset: cur.y)
            } else if let hlHit = resolveTextHighlightRevealTarget(scope: req.scope, key: req.key),
                      let foundVIdx = findScrollViewportIndex(forNode: hlHit.nodeIndex, verticalOnly: true) {
                vIdx = foundVIdx
                vPath = flatNodes[vIdx].path
                let vpRect = flatNodes[vIdx].targetRect
                cur = scrollOffsets[vPath] ?? .zero
                vpH = Double(vpRect.height)
                itemH = Double(hlHit.rect.height)
                itemTop = contentTop(node: hlHit.nodeIndex, rect: hlHit.rect, viewport: vIdx, offset: cur.y)
            } else if let vHit = resolveVirtualRowBounds(forKey: req.key, scope: req.scope),
                      flatNodes[vHit.vIdx].el.layout.scrollAxes.contains(.vertical) {
                vIdx = vHit.vIdx
                vPath = flatNodes[vIdx].path
                cur = vHit.cur
                vpH = Double(flatNodes[vIdx].targetRect.height)
                itemH = vHit.itemH
                itemTop = vHit.itemTop
            } else {
                if let (hxPath, nextX) = revealRowX(scope: req.scope, key: req.key) {
                    let curXScroll = scrollOffsets[hxPath] ?? .zero
                    applyScrollOffset(path: hxPath, next: Vec2(nextX, curXScroll.y), glide: (req.animated && !snaps) ? MotionTokens.GLIDE : nil)
                }
                continue
            }

            let margin = Double(flatNodes[vIdx].el.scrollMarginPts)
            let stuckCover: Double = {
                var cover: Double = 0.0
                let vpRect = flatNodes[vIdx].targetRect
                let tIdxOpt = flatNodes.firstIndex(where: { selectsElementSelector(req.key, path: $0.path, key: $0.key) })
                let targetPath = tIdxOpt.map { flatNodes[$0].path }
                for hNode in flatNodes {
                    guard case .top = hNode.el.stickyConfig?.edge else { continue }
                    let shiftY = stuckShiftsByPath[hNode.path]?.y ?? 0
                    guard shiftY > 0.01 else { continue }
                    // Must belong to this viewport
                    var pCur = hNode.parentIndex
                    var belongs = false
                    while let pi = pCur {
                        if !flatNodes[pi].el.layout.scrollAxes.isEmpty {
                            belongs = (pi == vIdx)
                            break
                        }
                        pCur = flatNodes[pi].parentIndex
                    }
                    guard belongs else { continue }
                    let isHolder = targetPath.map { $0 == hNode.path || $0.hasPrefix(hNode.path + "/") } ?? false
                    if isHolder {
                        let dTop = itemTop - Double(cur.y)
                        if dTop >= -0.5 && dTop + itemH <= vpH + 0.5 {
                            cover = -1.0 // signal already visible in stuck holder
                            break
                        }
                        continue
                    }
                    let drawnBottom = Double(hNode.targetRect.bottom) + Double(shiftY)
                    cover = max(cover, drawnBottom - Double(vpRect.top))
                }
                return cover
            }()
            if stuckCover < 0 { continue }

            let destY: Double
            if req.center {
                destY = max(0.0, min(Double(scrollMaxExtents[vPath]?.y ?? 0), itemTop - max(0, vpH - itemH) * 0.5))
            } else {
                destY = ScrollEdgeMath.reveal(
                    offset: Double(cur.y),
                    top: itemTop - stuckCover,
                    height: itemH + stuckCover,
                    viewport: vpH,
                    margin: margin
                )
            }

            let eff = scrollRequestsState.stepPlace(
                first: !landing,
                scope: req.scope,
                key: req.key,
                viewport: vPath,
                center: req.center,
                atEnd: false,
                from: Double(cur.y),
                to: destY
            )
            if case .move(let targetY) = eff {
                let jumped = applyScrollOffsetRequest(path: vPath, x: nil, y: Float(targetY),
                    glide: (req.animated && !snaps) ? MotionTokens.GLIDE : nil, cut: cut, animNow: now, holdHover: false)
                if jumped && !activeVirtualPaths.isEmpty { virtualRevealLandings.append(req) }
            }
            if let (hxPath, nextX) = revealRowX(scope: req.scope, key: req.key) {
                let curXScroll = scrollOffsets[hxPath] ?? .zero
                applyScrollOffset(path: hxPath, next: Vec2(nextX, curXScroll.y), glide: (req.animated && !snaps) ? MotionTokens.GLIDE : nil)
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
                applyScrollOffset(path: path, next: Vec2(cur.x, maxExt.y), glide: req.animated ? MotionTokens.GLIDE : nil)
            }
        }

        for req in pages {
            let vIdxOpt = findScrollNode(bySelector: req.key)
                ?? resolveVirtualRowBounds(forKey: req.key, scope: nil).map(\.vIdx)
            if let vIdx = vIdxOpt {
                let path = flatNodes[vIdx].path
                let cur = scrollOffsets[path] ?? .zero
                let vpH = scrollViewportSizes[path]?.y ?? flatNodes[vIdx].targetRect.height
                let nextY = cur.y + Float(req.pages) * max(1, vpH * 0.9)
                markScrollMovedByHand(path: path)
                applyScrollOffset(path: path, next: Vec2(cur.x, nextY), glide: nil)
                if !activeVirtualPaths.isEmpty {
                    needsCommit = true
                }
            }
        }

        /// `offset.rs::scroll_to_offsets` + `apply_jumps` (`ScrollOffsetRequests.swift`).
        func applyOffsetRequest(path: String, x: Float?, y: Float?, glide: Spring?) {
            applyScrollOffsetRequest(path: path, x: x, y: y, glide: glide, cut: cut, animNow: now, recordJump: true)
        }

        for landing in offsets {
            let req = landing.request
            if req.anchor {
                let at = req.y ?? 0
                let vIdx: Int
                let targetY: Float
                if let target = mountedScrollAnchor(key: req.key) {
                    var owner: Int? = target.index
                    while let idx = owner, !flatNodes[idx].el.layout.scrollAxes.contains(.vertical) {
                        owner = flatNodes[idx].parentIndex
                    }
                    guard let owner else { continue }
                    vIdx = owner
                    let vp = flatNodes[vIdx]
                    targetY = max(0, (scrollOffsets[vp.path] ?? .zero).y + target.top - vp.targetRect.top - at)
                } else if let row = virtualRowAnchorOffset(key: req.key, at: at) {
                    vIdx = row.viewport
                    targetY = row.offset
                } else {
                    continue
                }
                let vPath = flatNodes[vIdx].path
                scrollKeyLandings.land(landing)
                // `offset.rs:33-38`: an anchored request always jumps, vertically only.
                applyOffsetRequest(path: vPath, x: nil, y: targetY, glide: nil)
            } else if let vIdx = scrollViewportForOffset(key: req.key, x: req.x, y: req.y) {
                let path = flatNodes[vIdx].path
                // Only the axes the request names move (`offset.rs`: `r.x` / `r.y`).
                applyOffsetRequest(path: path, x: req.x, y: req.y, glide: req.glide)
            }
        }

        if destination || cut {
            scrollRequestsState.stepDestination()
        }

        dispatchScrollCallbacks(at: now, cut: cut || snaps)
    }

    /// Delivers `onAtBottom`, `onFarFromBottom`, and `onScrollOffset` callbacks for current scroll offsets.
    internal func dispatchScrollCallbacks(at now: Double, cut: Bool = false) {
        for i in layoutObservers.scrollReports {
            let node = flatNodes[i]
            let path = node.path
            let cur = scrollOffsets[path] ?? .zero
            let maxExt = scrollMaxExtents[path] ?? .zero
            let vp = scrollViewportSizes[path] ?? Vec2(node.targetRect.width, node.targetRect.height)
            let distFromBottom = max(0, maxExt.y - cur.y)

            if let onAtBottom = node.el.handlers.atBottomReport {
                let isAtBottom = distFromBottom <= 1.0
                if atBottomStates[node.nodeId] != isAtBottom {
                    atBottomStates[node.nodeId] = isAtBottom
                    dispatchScrollEndReport(onAtBottom, value: isAtBottom, at: now)
                }
            }

            if let farSpec = node.el.handlers.farFromBottomReport {
                var thresholdHeight = vp.y
                if let frameKey = farSpec.frameKey {
                    var ancestor = node.parentIndex
                    while let index = ancestor {
                        let parent = flatNodes[index]
                        if parent.key == frameKey {
                            thresholdHeight = parent.targetRect.height
                            break
                        }
                        ancestor = parent.parentIndex
                    }
                }
                let layoutEnd = slice2State.scrollModes[path]?.hand.laid.map(Float.init) ?? maxExt.y
                let isFar = min(maxExt.y, layoutEnd) - cur.y > max(farSpec.min, thresholdHeight)
                if farFromBottomStates[node.nodeId] != isFar {
                    farFromBottomStates[node.nodeId] = isFar
                    dispatchScrollEndReport(farSpec.handler, value: isFar, at: now)
                }
            }

            dispatchScrollOffsetObserverIfChanged(for: node, at: cxSettings.scaledTime(at: now), instant: currentCommitInstant || cut)
        }
    }

    private func dispatchScrollEndReport(_ report: (inout State, Bool) -> Bool, value: Bool, at now: Double) {
        let changed: Bool
        if let scope = turnScope {
            var scopedResult = false
            scope(&state) { scopedResult = report(&$0, value) }
            changed = scopedResult
        } else {
            changed = report(&state, value)
        }
        if changed { dirtyCommit(at: now, inputChange: false) }
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
        // The watcher reports the logical offset plus the room being held under a growth stack.
        let slack = slice2State.scrollSlacks[path]?.height ?? 0
        let pos = ScrollPos(
            offset: Vec2(cur.x, cur.y + slack),
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
        } else if node.el.handlers.onScrollOffset != nil {
            // A clamped hand movement is consumed even when there is no new position to tell.
            scrollMovedByHand.remove(path)
        }
    }

    internal func tellScrollOffsetsAfterSceneFrame(at now: Double, instant: Bool) {
        for i in layoutObservers.scrollReports {
            dispatchScrollOffsetObserverIfChanged(for: flatNodes[i], at: now, instant: instant)
        }
    }

    // MARK: - Paint-Time Sticky Push-Out Helpers

    internal func computePaintStickyShift(
        nodeIndex idx: Int,
        parentStickyShift: Vec2,
        presentedRectByNodeId: [NodeId: MotionRect],
        ownLiveOffset: Vec2 = .zero
    ) -> (shift: Vec2, parentShiftMag: Float) {
        computeStickyShift(
            nodeIndex: idx,
            parentStickyShift: parentStickyShift,
            nodes: flatNodes,
            rectOf: { node in presentedRectByNodeId[node.nodeId] ?? node.targetRect },
            ownLiveOffset: ownLiveOffset
        )
    }

    /// Flattening stores the normal layout of a sticky element. Only an anchored
    /// overlay needs its trigger's sticky position during the commit, before paint.
    internal func stickyShiftForAnchor(_ index: Int, in nodes: [FlatNode], cache: inout [Int: Vec2]) -> Vec2 {
        if let known = cache[index] { return known }
        var chain: [Int] = []
        var shift = Vec2.zero
        var next: Int? = index
        while let i = next {
            if let known = cache[i] {
                shift = known
                break
            }
            chain.append(i)
            let node = nodes[i]
            if node.el.anchor != nil && !node.isSticky { break }
            next = node.parentIndex
        }
        for i in chain.reversed() {
            shift = computeStickyShift(nodeIndex: i, parentStickyShift: shift, nodes: nodes, rectOf: { $0.targetRect }).shift
            cache[i] = shift
        }
        return shift
    }

    internal func computeStickyShift(
        nodeIndex idx: Int,
        parentStickyShift: Vec2,
        nodes: [FlatNode],
        rectOf: (FlatNode) -> MotionRect,
        ownLiveOffset: Vec2 = .zero
    ) -> (shift: Vec2, parentShiftMag: Float) {
        let node = nodes[idx]
        let held = scrollRequestsState.keeps.first(where: { $0.hold?.path == node.path })?.hold
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

        // Immediate parent's inner box bounds sticky push-out, constrained by any growth row
        // ancestor between parent and viewport (`sticky_frame_of` in `sticky.rs:516-543`).
        var boxTop: Float
        var boxBottom: Float
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
            if needsVertical && pIdx != sIdx {
                var aCur: Int? = pIdx
                var growthRowIdx: Int? = nil
                while let aIdx = aCur, aIdx != sIdx {
                    let aNode = nodes[aIdx]
                    let isGrowthRow = growthRows["growth:\(aNode.path)"] != nil || growthRows["fold:\(aNode.path)"] != nil
                    if isGrowthRow {
                        if growthRowIdx == nil { growthRowIdx = aIdx }
                        let aRect = rectOf(aNode)
                        let aPad = aNode.el.layout.padding
                        let aBdr = aNode.el.borderSides ?? Sides(
                            top: aNode.el.borderWidth,
                            right: aNode.el.borderWidth,
                            bottom: aNode.el.borderWidth,
                            left: aNode.el.borderWidth
                        )
                        boxTop = max(boxTop, aRect.top + aPad.top + aBdr.top + parentStickyShift.y)
                        boxBottom = min(boxBottom, aRect.bottom - aPad.bottom - aBdr.bottom + parentStickyShift.y)
                    }
                    aCur = aNode.parentIndex
                }
                if held != nil {
                    let rIdx = growthRowIdx ?? pIdx
                    let rNode = nodes[rIdx]
                    let rRect = rectOf(rNode)
                    let rPad = rNode.el.layout.padding
                    let rBdr = rNode.el.borderSides ?? Sides(
                        top: rNode.el.borderWidth,
                        right: rNode.el.borderWidth,
                        bottom: rNode.el.borderWidth,
                        left: rNode.el.borderWidth
                    )
                    let rPresentedContentBottom = rRect.bottom - rPad.bottom - rBdr.bottom + parentStickyShift.y
                    let rUnclampedBottom = (slice2State.unclampedBottomByPath[rNode.path] ?? rRect.bottom) - rPad.bottom - rBdr.bottom
                    let pUnclampedBottom = (slice2State.unclampedBottomByPath[pNode.path] ?? pRect.bottom) - pad.bottom - bdr.bottom
                    boxTop = -.infinity
                    boxBottom = rPresentedContentBottom - (rUnclampedBottom - pUnclampedBottom)
                }
            }
        } else {
            boxLeft = -.infinity
            boxTop = -.infinity
            boxRight = .infinity
            boxBottom = .infinity
        }

        let rawRect = rectOf(node)
        let shiftedElem = MotionRect.fromXYWH(
            rawRect.x - ownLiveOffset.x + parentStickyShift.x,
            rawRect.y - ownLiveOffset.y + parentStickyShift.y,
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

    internal func stepScrollSlacks(frameOut: FrameOutput, at now: Double) -> Bool {
        let dt: Float = slice2State.scrollLastSlackTickAt.map { Float(max(0, min(1, now - $0))) } ?? (1.0 / 60.0)
        slice2State.scrollLastSlackTickAt = now
        guard !layoutObservers.bottomViewports.isEmpty else {
            slice2State.scrollExtraYByPath.removeAll(keepingCapacity: true)
            return false
        }

        var anyMoving = false
        for i in layoutObservers.bottomViewports {
            let vNode = flatNodes[i]
            let path = vNode.path
            var slack = slice2State.scrollSlacks[path] ?? ScrollSlack.landed(window: (viewport.x, viewport.y))
            let pinned = wasPinnedToBottom.contains(path)

            if !pinned && !slack.moving {
                slack.edges = nil
                slice2State.scrollSlacks[path] = slack
                slice2State.scrollExtraYByPath[path] = 0
                continue
            }

            // Find growth-stack child (`scroll_stack`), else child with deepest bottom (`scroll_content`).
            let directChildren = layoutObservers.bottomChildren[i] ?? []
            let stackChild = directChildren.first {
                flatNodes[$0].el.growthSpec != nil || flatNodes[$0].el.foldGlideSpec != nil
            }
            let cIdxOpt = stackChild ?? directChildren.max { a, b in
                flatNodes[a].targetRect.bottom < flatNodes[b].targetRect.bottom
            }

            guard let cIdx = cIdxOpt,
                  let viewRect = frameOut.byId[vNode.nodeId]?.rect,
                  let cRect = frameOut.byId[flatNodes[cIdx].nodeId]?.rect else {
                slack = ScrollSlack.landed(window: slack.window)
                slice2State.scrollSlacks[path] = slack
                slice2State.scrollExtraYByPath[path] = 0
                continue
            }

            let curOff = scrollOffsets[path]?.y ?? 0
            let maxY = scrollMaxExtents[path]?.y ?? 0
            let cNode = flatNodes[cIdx]
            // Scene reports presented edges on its subpixel grid. Compare both ends on that
            // grid so a settled row and viewport cannot generate scroll slack from rounding.
            let contentTarget = snapRect(cNode.targetRect, pixelScale: scene.store.pixelScale)
            let viewTarget = snapRect(vNode.targetRect, pixelScale: scene.store.pixelScale)
            let lag = (cRect.top - contentTarget.top) - (viewRect.bottom - viewTarget.bottom)
            let trailingSpace = growthStacks[cNode.path]?.trailingSpace ?? 0
            let scrollOverflow = cNode.targetRect.bottom + curOff - vNode.targetRect.bottom
            let short = trailingSpace - scrollOverflow
            let wasHeld = slice2State.scrollHeldByPath[path] ?? false

            let stuckOff: Float?
            if pinned {
                if wasHeld && (short <= 0.5 || lag - short >= -0.5) {
                    stuckOff = scrollOverflow + lag
                } else if maxY > 0 {
                    stuckOff = max(0, maxY + lag)
                } else {
                    let at = scrollOverflow + lag
                    stuckOff = at > 0 ? at : nil
                }
            } else {
                stuckOff = nil
            }
            let effOffset = stuckOff ?? curOff
            let bottomOff = scrollOverflow + lag
            slice2State.scrollHeldByPath[path] = abs(effOffset - bottomOff) < 0.5

            let grown = slice2State.growthGrownByScrollPath.removeValue(forKey: path) ?? 0
            if let spec = cNode.el.growthSpec, !reducedMotion {
                let cPrefix = cNode.path + "/"
                let growing = slice2State.growthRowPathByKey.contains { (gKey, rp) in
                    rp.hasPrefix(cPrefix) && (growthRows[gKey]?.track).map { $0.target > $0.h + (1.0 / 128.0) } == true
                }
                let prevSlackH = slack.track.h
                let top = viewRect.top
                let bottom = viewRect.bottom
                if pinned {
                    var h = slack.track.h - grown
                    if let oldEdges = slack.edges, wasHeld, !slack.follow {
                        let limit = cRect.top + cNode.targetRect.height - trailingSpace
                        let b0 = short > 0.5 ? min(oldEdges.y, limit) : oldEdges.y
                        let b1 = short > 0.5 ? min(bottom, limit) : bottom
                        h += (b1 - b0) - max(0, top - oldEdges.x)
                    }
                    slack.track.h = max(0, h)
                }
                slack.edges = SIMD2<Float>(top, bottom)
                if slack.follow
                    && abs(top - vNode.targetRect.top) < 0.01
                    && abs(bottom - vNode.targetRect.bottom) < 0.01 {
                    slack.follow = false
                }
                slack.settle(growing: growing, now: now, dt: dt, spec: spec)
                slack.stepped = abs(slack.track.h - prevSlackH) > 1e-5
            } else {
                slack = ScrollSlack.landed(window: slack.window)
            }

            slice2State.scrollSlacks[path] = slack
            let exactOffset = effOffset + slack.height
            slice2State.scrollExtraYByPath[path] = exactOffset - curOff
            if slack.moving {
                anyMoving = true
            }
        }
        return anyMoving
    }

    // MARK: - Focus & Reveal Selected

    internal func checkFocusAndRevealSelected() {
        defer { suppressRevealFromHoverCommit = false }
        var newFocus: Int?
        var selectedPaths: Set<String> = []
        for i in layoutObservers.focusSelected {
            let node = flatNodes[i]
            selectedPaths.insert(node.path)
            if node.el.focusable && !node.effectiveInert && !lastFocusSelectedPaths.contains(node.path) {
                newFocus = i
            }
        }
        lastFocusSelectedPaths = selectedPaths

        var revealPaths: Set<String> = []
        for i in layoutObservers.revealSelected {
            let node = flatNodes[i]
            revealPaths.insert(node.path)
            if !isDispatchingHover && !suppressRevealFromHoverCommit && !lastRevealSelectedPaths.contains(node.path) {
                pendingScrollReveals.append(.intoView(scope: nil, key: node.key ?? node.path))
            }
        }
        lastRevealSelectedPaths = revealPaths
        if let i = newFocus {
            focusedPath = flatNodes[i].path
            focusedKey = flatNodes[i].key
        }
    }
}
