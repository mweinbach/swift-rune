import Foundation
import RuneMotion

/// How a commit measures, decided once before it starts (`runtime/commit/relayout.rs`).
public enum ResizeCommitKind: Equatable, Sendable {
    /// Run the view and flatten what it returns.
    case rebuild
    /// Only the window resized: lay the last commit's tree out again at the new size.
    case relayout
    /// Only virtual windows moved: keep mounted subtrees and build rows that enter.
    case remount
}

/// Environment snapshot that a cached view build depends on (`Reuse` in `relayout.rs`).
internal struct ResizeBuildEnv: Equatable, Sendable {
    var pixelScale: Float
    var srgbBlend: Bool
    var systemDark: Bool
    var hostReducedMotion: Bool
    var timeScale: Float
    var windowFocused: Bool
    var playgroundAttached: Bool
    var titlebarInset: Float
    var scrollBarOverlay: Bool
    var primaryPointer: PrimaryPointer = .hover
}

/// Snapshot of the last full `runViewPass` output retained for resize-only `.relayout`.
internal final class ResizeCachedViewBuild<State> {
    var viewRootEl: El<State>
    var expandedRootEl: El<State>
    var virtualExpansion: Runtime<State>.VirtualExpansionContext
    var helpLook: HelpLook?
    var env: ResizeBuildEnv
    var fitHeight: Bool
    var reusable: Bool
    var reads: [LayoutReadEntry]
    var caretRead: Bool
    var viewport: Vec2
    var viewportRead: Bool
    var memoEnvHash: UInt64
    var viewOnlyMemoIds: Set<String>
    var virtualRowCache: [String: [String: Runtime<State>.CachedVirtualRow]]

    init(
        viewRootEl: El<State>,
        expandedRootEl: El<State>,
        virtualExpansion: Runtime<State>.VirtualExpansionContext,
        helpLook: HelpLook?,
        env: ResizeBuildEnv,
        fitHeight: Bool,
        reusable: Bool,
        reads: [LayoutReadEntry],
        caretRead: Bool,
        viewport: Vec2,
        viewportRead: Bool,
        memoEnvHash: UInt64 = 0,
        viewOnlyMemoIds: Set<String> = [],
        virtualRowCache: [String: [String: Runtime<State>.CachedVirtualRow]] = [:]
    ) {
        self.viewRootEl = viewRootEl
        self.expandedRootEl = expandedRootEl
        self.virtualExpansion = virtualExpansion
        self.helpLook = helpLook
        self.env = env
        self.fitHeight = fitHeight
        self.reusable = reusable
        self.reads = reads
        self.caretRead = caretRead
        self.viewport = viewport
        self.viewportRead = viewportRead
        self.memoEnvHash = memoEnvHash
        self.viewOnlyMemoIds = viewOnlyMemoIds
        self.virtualRowCache = virtualRowCache
    }
}

extension RuntimeVirtualListState {
    /// Measured rows still mounted outside the desired overscan (`VirtualList::spare`).
    func spare(offset: Float, viewport: Float, prefix: [Float], count: Int, pinned: Bool) -> Float {
        guard !pinned, count > 0 else { return 0 }
        let bounds = overscanBounds(offset: offset, viewport: viewport, prefix: prefix, count: count, pinned: false)
        let lo = min(count, lastMountedRange.lowerBound)
        let hi = min(count, lastMountedRange.upperBound)
        let above = prefix[min(bounds.targetLo, hi)] - prefix[min(lo, bounds.targetLo)]
        let below = rowEnd(hi, prefix: prefix) - rowEnd(min(max(bounds.targetHi, lo), hi), prefix: prefix)
        return max(0, above) + max(0, below)
    }

    /// Whether the viewport has approached a mounted edge (`VirtualList::needs_window`).
    func needsWindow(offset: Float, viewport: Float, prefix: [Float], count: Int, pinned: Bool) -> Bool {
        guard count > 0 else { return false }
        if pinned { return lastMountedRange.upperBound != count }
        let lo = min(count, lastMountedRange.lowerBound)
        let hi = min(count, lastMountedRange.upperBound)
        let edge = viewport * (isIndexed ? Self.indexedEdgeMultiplier : Self.nonIndexedEdgeMultiplier)
        return (lo > 0 && offset < padTop + prefix[lo] + edge) ||
            (hi < count && offset + viewport > padTop + rowEnd(hi, prefix: prefix) - edge)
    }
}

extension Runtime {
    /// Returns true when every element in `rootEl` can be re-laid-out across resizes without
    /// rebuilding via `view` (`relayout.rs:reusable`).
    internal static func isTreeReusableForRelayout(_ rootEl: El<State>) -> Bool {
        var stack: [El<State>] = [rootEl]
        while let el = stack.popLast() {
            if el.layout.aspectFit != nil || el.anchor?.fit == true || el.pixelsPayload != nil {
                return false
            }
            if !el.children.isEmpty {
                stack.append(contentsOf: el.children)
            }
        }
        return true
    }

    internal func currentResizeBuildEnv() -> ResizeBuildEnv {
        ResizeBuildEnv(
            pixelScale: pixelScale,
            srgbBlend: srgbBlend,
            systemDark: systemDark,
            hostReducedMotion: cxSettings.hostReducedMotion,
            timeScale: cxSettings.viewTimeScale,
            windowFocused: windowFocused,
            playgroundAttached: playgroundHost != nil,
            titlebarInset: cxSettings.titlebarInset,
            scrollBarOverlay: cxSettings.scrollBarsState.isOverlay,
            primaryPointer: cxSettings.primaryPointer
        )
    }

    /// Decides how the next commit measures (`runtime/commit/relayout.rs:commit_kind`).
    public func nextCommitKind(tx: Tx = Tx()) -> ResizeCommitKind {
        guard let cached = cachedResizeBuild else { return .rebuild }
        let unchanged = stateUnchangedSinceBuild
            && !pendingCommitKind.lands
            && !tx.commitKind.lands
            && !resizeReadMovedFlag
            && !hasActiveExitingNodes
            && cached.env == currentResizeBuildEnv()
            && cached.fitHeight == fitHeight
            && playgroundHost == nil
        guard unchanged else { return .rebuild }
        if pendingResizeRelayout || pendingGrowthRelayout {
            if cached.viewportRead && cached.viewport != viewport {
                return .rebuild
            }
            return cached.reusable ? .relayout : .rebuild
        }
        return !activeVirtualPaths.isEmpty ? .remount : .rebuild
    }

    /// Explicitly marks the tree dirty as needing a full `view` rebuild (matching `Runtime::invalidate`).
    public func invalidate(at now: Double? = nil) {
        stateUnchangedSinceBuild = false
        pendingResizeRelayout = false
        pendingGrowthRelayout = false
        dirtyCommit(at: now ?? currentTime, external: true)
    }

    /// Computes the focused `TextEdit` caret rect in the laid-out `nodes`.
    internal func focusedCaretInfo(in nodes: [FlatNode], matching prevKeyPath: String? = nil) -> (keyPath: String, rect: [Float])? {
        let targetNode: FlatNode?
        if let kp = prevKeyPath {
            targetNode = nodes.first(where: { $0.path == kp })
        } else if let fk = focusedKey {
            targetNode = nodes.first(where: { matchesAuthoredKey($0.key, fk) })
        } else if let fp = focusedPath {
            targetNode = nodes.first(where: { $0.path == fp })
        } else {
            targetNode = nil
        }
        guard let node = targetNode,
              let edit = node.el.handlers.editLens?.get(state),
              focusedPath == node.path || matchesAuthoredKey(focusedKey, node.key) else {
            return nil
        }
        let textStyle = node.el.textStyle
        let padL = node.el.layout.padding.left
        let padT = node.el.layout.padding.top
        let padR = node.el.layout.padding.right
        let innerW = max(0, node.targetRect.width - padL - padR)
        let maxW: Float? = textStyle.wrap == .noWrap ? nil : (innerW > 0 ? innerW + 0.5 : nil)
        let shaped = textSystem.shape(
            text: edit.text,
            spans: nil,
            style: textStyle,
            maxWidth: maxW,
            pixelScale: pixelScale,
            emitGlyphs: false
        )
        let measuredCaret = textSystem.caretRect(
            in: shaped,
            utf8Offset: edit.cursor,
            upstream: edit.caretAffinity == .upstream,
            pixelScale: pixelScale
        )
        let rect: [Float] = [
            node.targetRect.left + padL + measuredCaret.x,
            node.targetRect.top + padT + measuredCaret.y,
            measuredCaret.z,
            measuredCaret.w,
        ]
        return (node.path, rect)
    }

    internal func caretMoved(from prev: (keyPath: String, rect: [Float])?, in nodes: [FlatNode]) -> Bool {
        guard let prev else { return focusedKey != nil || focusedPath != nil }
        guard let next = focusedCaretInfo(in: nodes, matching: prev.keyPath) else {
            return true
        }
        return LayoutReadConstants.rectsMoved(prev.rect, next.rect)
    }

    /// Checks whether a focused `TextEdit` caret moved since `lastCommittedCaret` during relayout.
    internal func caretMovedDuringRelayout(nodes: [FlatNode]) -> Bool {
        guard let cached = cachedResizeBuild, cached.caretRead else { return false }
        return caretMoved(from: cxSettings.lastCommittedCaret, in: nodes)
    }

    /// Synchronizes virtual list `__v_top_spacer` / `__v_bot_spacer` heights in `el` from `lists`.
    /// Returns `true` if any spacer height changed by more than `0.05`pt.
    private static func syncVirtualSpacers(
        in el: inout El<State>,
        parentPath: String = "",
        siblingIndex: Int = 0,
        siblingKeysSeen: inout [String: Int],
        lists: [String: RuntimeVirtualListState]
    ) -> Bool {
        let seg: String
        if let rk = el.storageKeyId {
            let c = siblingKeysSeen[rk, default: 0]
            siblingKeysSeen[rk] = c + 1
            seg = c == 0 ? "@\(rk)" : "@\(rk)#dup\(c)"
        } else {
            seg = "\(siblingIndex)"
        }
        let path = parentPath.isEmpty ? (el.storageKeyId.map { "/@\($0)" } ?? "/0") : "\(parentPath)/\(seg)"
        var changed = false

        if let vState = lists[path] {
            let est = max(1, el.virtualEstimate ?? 40)
            let count = vState.lastKeys.count
            let mounted = vState.lastMountedRange
            let (prefix, total) = vState.computeOffsets(estimated: est)
            let lo = max(0, min(count, mounted.lowerBound))
            let hi = max(lo, min(count, mounted.upperBound))
            let (newTopH, newBotH) = vState.spacerHeights(mounted: lo..<hi, prefix: prefix, total: total)
            for idx in el.children.indices {
                if el.children[idx].keyId == "__v_top_spacer" {
                    let cur = el.children[idx].layout.height.resolve(against: 0) ?? 0
                    if abs(cur - newTopH) > 0.05 {
                        el.children[idx].layout.height = .points(newTopH)
                        changed = true
                    }
                } else if el.children[idx].keyId == "__v_bot_spacer" {
                    let cur = el.children[idx].layout.height.resolve(against: 0) ?? 0
                    if abs(cur - newBotH) > 0.05 {
                        el.children[idx].layout.height = .points(newBotH)
                        changed = true
                    }
                }
            }
        }

        var childSeen: [String: Int] = [:]
        for idx in el.children.indices {
            if syncVirtualSpacers(
                in: &el.children[idx],
                parentPath: path,
                siblingIndex: idx,
                siblingKeysSeen: &childSeen,
                lists: lists
            ) {
                changed = true
            }
        }
        return changed
    }

    /// Returns true if any active virtual list's mounted window no longer covers its current scroll viewport.
    internal func anyVirtualListNeedsWindow() -> Bool {
        for listPath in activeVirtualPaths {
            guard let vState = virtualLists[listPath] else { return true }
            let est = max(1, (nodeByPath[listPath].flatMap { flatNodes[$0].el.virtualEstimate }) ?? 40)
            let scrollIdx = nodeByPath[listPath].flatMap {
                !flatNodes[$0].el.layout.scrollAxes.isEmpty ? $0 : flatNodes[$0].enclosingVScrollIndex
            }
            let scrollPath = scrollIdx.map { flatNodes[$0].path } ?? listPath
            let vpH = max(1, scrollViewportSizes[scrollPath]?.y ?? viewport.y)
            let stickyPin = nodeByPath[scrollPath].map { flatNodes[$0].el.layout.stickBottom } == true
                && wasPinnedToBottom.contains(scrollPath)
            let (prefix, total) = vState.computeOffsets(estimated: est)
            let scrollY = stickyPin && !vState.nested ? max(0, vState.top + vState.extent(total: total) - vpH) : (scrollOffsets[scrollPath]?.y ?? 0)
            let (offsetY, pinned) = vState.at(scrollY, pinned: stickyPin, total: total)
            if vState.needsWindow(offset: offsetY, viewport: vpH, prefix: prefix, count: vState.lastKeys.count, pinned: pinned) {
                return true
            }
        }
        return false
    }

    /// Validates that mounted virtual list ranges remain valid after a resize-only relayout,
    /// anchoring scroll offsets by the height delta above the first visible row (`anchor_virtuals` +
    /// `anchor_delta`). Returns `(ok, lists, anchoredScrollYs)`.
    internal func updateAndCheckVirtualRelayout(_ pass: MeasurePassResult) -> (
        ok: Bool,
        lists: [String: RuntimeVirtualListState],
        anchoredScrollYs: [String: Float]
    ) {
        guard pass.virtualExpansion.anyVirtualList else { return (true, virtualLists, [:]) }
        var anchorInfoByList: [String: (scrollPath: String, scrollIdx: Int?, vpH: Float, stickyPin: Bool, oldOffsetY: Float, oldListY: Float, prefixBefore: [Float], anchorIdx: Int?)] = [:]
        for listPath in activeVirtualPaths {
            guard let vBefore = virtualLists[listPath] else { return (false, virtualLists, [:]) }
            let est = max(1, (pass.byPath[listPath].flatMap { pass.nodes[$0].el.virtualEstimate }) ?? 40)
            let scrollIdx = pass.byPath[listPath].flatMap {
                !pass.nodes[$0].el.layout.scrollAxes.isEmpty ? $0 : pass.nodes[$0].enclosingVScrollIndex
            }
            let scrollPath = scrollIdx.map { pass.nodes[$0].path } ?? listPath
            let vpH = scrollIdx.map { max(1, pass.nodes[$0].targetRect.height) } ?? max(1, viewport.y)
            let stickyPin = scrollIdx.map { pass.nodes[$0].el.layout.stickBottom } == true
                && wasPinnedToBottom.contains(scrollPath)
            let (prefixBefore, totalBefore) = vBefore.computeOffsets(estimated: est)
            let oldOffsetY = scrollOffsets[scrollPath]?.y ?? 0
            // `anchor_virtuals`: the list's own offset; one pinned, or nested and wholly above the
            // viewport's top, anchors nothing (`VirtualList::locate`).
            var located = vBefore
            let (oldListY, oldPinned) = located.locate(oldOffsetY, pinned: stickyPin, total: totalBefore)
            let vis = vBefore.visibleRange(offset: oldListY, viewport: vpH, prefix: prefixBefore, count: vBefore.lastKeys.count)
            // A pending keep or reveal owns this viewport through an animated resize.
            let anchorIdx = (vis.isEmpty || oldPinned || located.passed || scrollRequestsState.owns(scrollPath)) ? nil : vis.lowerBound
            anchorInfoByList[listPath] = (scrollPath, scrollIdx, vpH, stickyPin, oldOffsetY, oldListY, prefixBefore, anchorIdx)
        }

        var tempLists = virtualLists
        for meta in pass.virtualExpansion.listMeta {
            guard var list = tempLists[meta.listPath] else { continue }
            for key in meta.mounted.mountedKeys {
                guard let index = pass.byPath["\(meta.listPath)/@\(key)"] else { continue }
                let height = pass.nodes[index].targetRect.height
                if height > 0.5 { list.measuredByKey[key] = height }
            }
            tempLists[meta.listPath] = list
        }
        var anchoredScrollYs: [String: Float] = [:]
        for listPath in activeVirtualPaths {
            guard var vState = tempLists[listPath],
                  let info = anchorInfoByList[listPath] else { return (false, tempLists, [:]) }
            let est = max(1, (pass.byPath[listPath].flatMap { pass.nodes[$0].el.virtualEstimate }) ?? 40)
            if let lIdx = pass.byPath[listPath], let sIdx = info.scrollIdx {
                Self.measureVirtualPlacement(&vState, listIdx: lIdx, scrollIdx: sIdx, nodes: pass.nodes)
            }
            vState.measuredByKey.prepareOffsets(estimated: est, gap: vState.gap)
            tempLists[listPath] = vState
            let (prefix, total) = vState.computeOffsets(estimated: est)
            let scrollY: Float
            if info.stickyPin {
                scrollY = vState.nested ? info.oldOffsetY : max(0, vState.top + vState.extent(total: total) - info.vpH)
            } else if let aIdx = info.anchorIdx, aIdx < prefix.count, aIdx < info.prefixBefore.count {
                let delta = prefix[aIdx] - info.prefixBefore[aIdx]
                let listY = max(0, min(max(0, vState.extent(total: total) - info.vpH), info.oldListY + delta))
                let candidate = max(0, info.oldOffsetY + listY - info.oldListY)
                scrollY = candidate
                if abs(candidate - info.oldOffsetY) > 0.05 {
                    anchoredScrollYs[info.scrollPath] = candidate
                }
            } else {
                scrollY = info.oldOffsetY
            }
            // `windows_move`: the list's own offset within its window (`VirtualList::at`).
            let (offsetY, pinned) = vState.at(scrollY, pinned: info.stickyPin, total: total)
            if vState.needsWindow(offset: offsetY, viewport: info.vpH, prefix: prefix, count: vState.lastKeys.count, pinned: pinned)
                || vState.spare(offset: offsetY, viewport: info.vpH, prefix: prefix, count: vState.lastKeys.count, pinned: pinned) > info.vpH {
                return (false, tempLists, [:])
            }
        }
        return (true, tempLists, anchoredScrollYs)
    }

    /// Runs resize-only relayout reusing the cached `El` tree (`runtime/commit/relayout.rs:relayout`).
    /// Returns `nil` when relayout detects a moved layout/caret read or shifted virtual window,
    /// cleanly falling back to a full `view` pass.
    internal func tryRelayoutPass(
        at now: Double,
        cut: Bool,
        commitKind: TxCommit,
        commitMotion: MotionSource?,
        commitColorSpring: Spring?,
        commitCut: Bool,
        prevMountedIds: Dictionary<NodeId, Int>.Keys
    ) -> MeasurePassResult? {
        guard let cached = cachedResizeBuild else { return nil }
        let collector = LayoutReadCollector(rects: layoutSeen.rects)
        let savedVirtuals = virtualLists
        let savedScrollOffsets = scrollOffsets
        let savedScrollMaxExtents = scrollMaxExtents
        let savedScrollViewportSizes = scrollViewportSizes
        let savedScrollContentSizes = scrollContentSizes
        let savedWasPinned = wasPinnedToBottom
        let savedGrowthRows = growthRows
        let savedGrowthStacks = growthStacks
        let savedLastGrowthStepTime = lastGrowthStepTime

        var expandedRoot = cached.expandedRootEl
        if cached.virtualExpansion.anyVirtualList {
            var rootSeen: [String: Int] = [:]
            _ = Self.syncVirtualSpacers(in: &expandedRoot, siblingKeysSeen: &rootSeen, lists: virtualLists)
        }

        var pass = buildMeasureResult(
            rootEl: expandedRoot,
            expandedContextOverride: cached.virtualExpansion,
            passHelpLook: cached.helpLook,
            collector: collector,
            at: now,
            cut: cut,
            commitKind: commitKind,
            commitMotion: commitMotion,
            commitColorSpring: commitColorSpring,
            commitCut: commitCut,
            prevMountedIds: prevMountedIds,
            isResizeRelayout: pendingResizeRelayout
        )
        pass.reads = cached.reads

        let (virtualOk, measuredLists, anchoredScrollYs) = updateAndCheckVirtualRelayout(pass)
        if (!cached.reads.isEmpty && evaluateLayoutMoved(reads: cached.reads, nodes: pass.nodes, force: false))
            || caretMovedDuringRelayout(nodes: pass.nodes)
            || !virtualOk {
            virtualLists = savedVirtuals
            scrollOffsets = savedScrollOffsets
            scrollMaxExtents = savedScrollMaxExtents
            scrollViewportSizes = savedScrollViewportSizes
            scrollContentSizes = savedScrollContentSizes
            wasPinnedToBottom = savedWasPinned
            growthRows = savedGrowthRows
            growthStacks = savedGrowthStacks
            lastGrowthStepTime = savedLastGrowthStepTime
            return nil
        }

        if cached.virtualExpansion.anyVirtualList {
            var rootSeen: [String: Int] = [:]
            let spacerChanged = Self.syncVirtualSpacers(
                in: &expandedRoot,
                siblingKeysSeen: &rootSeen,
                lists: measuredLists
            )
            virtualLists = measuredLists
            if spacerChanged || !anchoredScrollYs.isEmpty {
                scrollOffsets = savedScrollOffsets
                for (scrollPath, newY) in anchoredScrollYs {
                    let prevX = scrollOffsets[scrollPath]?.x ?? 0
                    let nextOff = Vec2(prevX, newY)
                    scrollOffsets[scrollPath] = nextOff
                    let nid = NodeId.hash("scroll:\(scrollPath)")
                    scrollStore.snap(nid, Props.SCROLL, to: nextOff)
                }
                scrollMaxExtents = savedScrollMaxExtents
                scrollViewportSizes = savedScrollViewportSizes
                scrollContentSizes = savedScrollContentSizes
                wasPinnedToBottom = savedWasPinned
                growthRows = savedGrowthRows
                growthStacks = savedGrowthStacks
                lastGrowthStepTime = savedLastGrowthStepTime
                pass = buildMeasureResult(
                    rootEl: expandedRoot,
                    expandedContextOverride: cached.virtualExpansion,
                    passHelpLook: cached.helpLook,
                    collector: collector,
                    at: now,
                    cut: cut,
                    commitKind: commitKind,
                    commitMotion: commitMotion,
                    commitColorSpring: commitColorSpring,
                    commitCut: commitCut,
                    prevMountedIds: prevMountedIds
                )
                pass.reads = cached.reads
            }
            cachedResizeBuild?.expandedRootEl = expandedRoot
            for meta in cached.virtualExpansion.listMeta where !meta.mounted.mountedKeys.isEmpty {
                activeVirtualPaths.insert(meta.listPath)
            }
        }
        return pass
    }

    private enum RemountFallback: Error { case nestedVirtual }

    /// Re-expands active virtual lists without re-running `view` or rebuilding already-mounted
    /// indexed rows (`runtime/commit/remount.rs`). Returns `nil` when fallback to full rebuild is needed.
    internal func tryVirtualRemountPass(
        at now: Double,
        cut: Bool,
        commitKind: TxCommit,
        commitMotion: MotionSource?,
        commitColorSpring: Spring?,
        commitCut: Bool,
        prevMountedIds: Dictionary<NodeId, Int>.Keys
    ) -> MeasurePassResult? {
        guard let cached = cachedResizeBuild,
              cached.reusable,
              !activeVirtualPaths.isEmpty,
              !lastViewReadScroll,
              playgroundHost == nil,
              !cached.viewportRead || cached.viewport == viewport else {
            return nil
        }

        let savedVirtuals = virtualLists
        let savedActiveVirtualPaths = activeVirtualPaths
        let savedScrollOffsets = scrollOffsets
        let savedScrollMaxExtents = scrollMaxExtents
        let savedScrollViewportSizes = scrollViewportSizes
        let savedScrollContentSizes = scrollContentSizes
        let savedWasPinned = wasPinnedToBottom
        let savedGrowthRows = growthRows

        func restoreSavedAndFallback() -> MeasurePassResult? {
            virtualLists = savedVirtuals
            activeVirtualPaths = savedActiveVirtualPaths
            scrollOffsets = savedScrollOffsets
            scrollMaxExtents = savedScrollMaxExtents
            scrollViewportSizes = savedScrollViewportSizes
            scrollContentSizes = savedScrollContentSizes
            wasPinnedToBottom = savedWasPinned
            growthRows = savedGrowthRows
            return nil
        }

        let preGeom = currentMemoGeometry()
        guard var pass = try? buildMeasureResult(
            rootEl: cached.viewRootEl,
            remountRowCache: cached.virtualRowCache,
            rowReuseMode: .remount,
            memoGeometryOverride: preGeom,
            passHelpLook: cached.helpLook,
            collector: LayoutReadCollector(rects: layoutSeen.rects),
            at: now,
            cut: cut,
            commitKind: commitKind,
            commitMotion: commitMotion,
            commitColorSpring: commitColorSpring,
            commitCut: commitCut,
            prevMountedIds: prevMountedIds,
            onRemountFallback: { throw RemountFallback.nestedVirtual }
        ) else {
            return restoreSavedAndFallback()
        }

        if prepareVirtualRemeasureAfterFullPass(
            pass,
            savedVirtuals: savedVirtuals,
            savedScrollOffsets: savedScrollOffsets,
            savedScrollMaxExtents: savedScrollMaxExtents,
            savedScrollViewportSizes: savedScrollViewportSizes,
            savedScrollContentSizes: savedScrollContentSizes,
            savedWasPinned: savedWasPinned,
            savedGrowthRows: savedGrowthRows
        ) {
            let remeasureCache = pass.virtualExpansion.builtVirtualRows
            guard let remeasure = try? buildMeasureResult(
                rootEl: cached.viewRootEl,
                retryingVirtualWindow: true,
                remountRowCache: remeasureCache,
                rowReuseMode: .remount,
                memoGeometryOverride: preGeom,
                passHelpLook: cached.helpLook,
                collector: LayoutReadCollector(rects: layoutSeen.rects),
                at: now,
                cut: cut,
                commitKind: commitKind,
                commitMotion: commitMotion,
                commitColorSpring: commitColorSpring,
                commitCut: commitCut,
                prevMountedIds: prevMountedIds,
                onRemountFallback: { throw RemountFallback.nestedVirtual }
            ) else {
                return restoreSavedAndFallback()
            }
            pass = remeasure
        }

        if evaluateLayoutMoved(reads: cached.reads, nodes: pass.nodes, force: false)
            || self.memo.hasInvalidatedReads(computing: { currentMemoGeometry(nodes: pass.nodes) })
            || (cached.caretRead && caretMoved(from: cxSettings.lastCommittedCaret, in: pass.nodes)) {
            return restoreSavedAndFallback()
        }

        var keptMemoIds = cached.viewOnlyMemoIds
        for rowMap in pass.virtualExpansion.builtVirtualRows.values {
            for entry in rowMap.values {
                keptMemoIds.formUnion(entry.memoIds)
            }
        }
        var evictMemoIds: Set<String> = []
        for (listPath, oldMap) in cached.virtualRowCache {
            let newMap = pass.virtualExpansion.builtVirtualRows[listPath] ?? [:]
            for (rowKey, oldEntry) in oldMap where newMap[rowKey] == nil {
                evictMemoIds.formUnion(oldEntry.memoIds)
            }
        }
        evictMemoIds.subtract(keptMemoIds)
        self.memo.removeEntries(ids: evictMemoIds)

        cached.expandedRootEl = pass.expandedRootEl
        cached.virtualExpansion = pass.virtualExpansion
        cached.virtualRowCache = pass.virtualExpansion.builtVirtualRows
        pass.reads = cached.reads
        pass.isVirtualRemount = true
        return pass
    }
}
