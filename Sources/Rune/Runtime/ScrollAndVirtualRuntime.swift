import Foundation
import RuneMotion

// MARK: - Increment 4 Runtime Support (TxCommit, ScrollRequests, Sticky, VirtualRows/VirtualFill, Growth)

extension Runtime {
    internal struct VirtualExpansionContext {
        var rowMappings: [(listPath: String, scrollPath: String, rowSegment: String, rowKey: String)] = []
        var anyVirtualList: Bool = false
        var virtualInputs: [String: VirtualInputEntry] = [:]
    }

    internal struct GrowthCaptureResult {
        var needsClampedRelayout: Bool = false
        var activeCount: Int = 0
    }

    // MARK: - Helpers

    internal func makeTx(at now: Double, button: PointerButton = .primary) -> Tx {
        var tx = Tx()
        tx.clock = now
        if let sel = currentTextSelection() {
            tx.setCurrentTextSelection(sel)
        }
        tx.button = button
        tx.runtimeActions["focusVisible"] = focusVisible
        tx.runtimeActions["byKeys"] = kitHooks.isDispatchingByKeys
        tx.physicalKeyValue = currentPhysicalKey
        tx.keyBaseValue = currentKeyBase
        tx.keyRepeatValue = currentKeyRepeat
        tx.tracingEnabled = (traceChannels != nil) || scene.isTracing
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
    internal func expandVirtualSubtrees(in rootEl: El<State>) -> (root: El<State>, context: VirtualExpansionContext) {
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
        ctx: inout VirtualExpansionContext
    ) {
        let (segment, _) = layoutPathSegment(
            keyId: el.keyId,
            siblingIndex: siblingIndex,
            siblingKeysSeen: &siblingKeysSeen
        )
        let path = parentPath.isEmpty ? (el.keyId.map { "/@\($0)" } ?? "/0") : "\(parentPath)/\(segment)"

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

        var curOffsetY = scrollOffsets[vpPath]?.y ?? 0
        if stickyPin {
            curOffsetY = max(0, total - vpH)
            scrollOffsets[vpPath] = Vec2(scrollOffsets[vpPath]?.x ?? 0, curOffsetY)
            wasPinnedToBottom.insert(vpPath)
        } else if let anchorKey = vState.lastAnchorKey,
                  !scrollRequestsState.owns(vpPath),
                  !directScrolledPaths.contains(vpPath),
                  let anchorIdx = keys.firstIndex(of: anchorKey) {
            let prefixDelta = prefix[anchorIdx] - vState.lastAnchorPrefixY
            if abs(prefixDelta) > 0.25 {
                curOffsetY = max(0, min(max(0, total - vpH), curOffsetY + prefixDelta))
                scrollOffsets[vpPath] = Vec2(scrollOffsets[vpPath]?.x ?? 0, curOffsetY)
                let nid = NodeId.hash("scroll:\(vpPath)")
                scrollStore.snap(nid, Props.SCROLL, to: scrollOffsets[vpPath] ?? .zero)
            }
        }

        var pinned: Set<Int> = []
        if let fk = focusedKey, let fi = keys.firstIndex(of: fk) {
            pinned.insert(fi)
        }
        for req in pendingScrollReveals where req.scope == nil || req.scope == nextScrollPath || req.scope == path {
            if let ri = keys.firstIndex(where: { $0 == req.key || selectsElementSelector(req.key, path: path + "/" + $0, key: $0) }) {
                pinned.insert(ri)
            }
        }

        let (mounted, wantedMore, missing) = vState.overscanWindow(
            offset: curOffsetY,
            viewport: vpH,
            prefix: prefix,
            count: count,
            indexed: isIndexed,
            pinnedIndices: pinned
        )

        // Track first visible anchor row for prepend/resize scroll preservation.
        let vis = vState.visibleRange(offset: curOffsetY, viewport: vpH, prefix: prefix, count: count)
        if !vis.isEmpty && !stickyPin {
            let ai = vis.lowerBound
            vState.lastAnchorKey = keys[ai]
            vState.lastAnchorLocalY = max(0, curOffsetY - prefix[ai])
            vState.lastAnchorPrefixY = prefix[ai]
        } else if stickyPin {
            vState.lastAnchorKey = nil
            vState.lastAnchorLocalY = 0
            vState.lastAnchorPrefixY = 0
        }

        vState.lastMountedRange = mounted
        vState.wantsMoreFrames = wantedMore
        vState.missingOverscanRows = missing
        virtualLists[path] = vState
        if !isIndexed {
            PerfWarn.overbuilt(path: path, site: el.virtualizeSite, built: count, mounted: mounted.count)
        }

        var built: [El<State>] = []
        let topSpacerH = mounted.lowerBound > 0 ? prefix[mounted.lowerBound] : 0
        let botSpacerH = mounted.upperBound < count ? max(0, total - prefix[mounted.upperBound]) : 0
        if topSpacerH > 0 {
            built.append(El<State>().key("__v_top_spacer").wFull().h(topSpacerH))
        }

        var rowSeenKeys: [String: Int] = [:]
        for i in mounted {
            var rowEl = isIndexed ? el.virtualRowsSource!.build(state, i) : el.children[i]
            if rowEl.keyId == nil {
                rowEl = rowEl.key(keys[i])
            }
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
                siblingKeysSeen: &rowSeenKeys,
                scrollPath: nextScrollPath,
                scrollStickBottom: nextStickBottom,
                ctx: &ctx
            )
            built.append(rowEl)
        }

        if botSpacerH > 0 {
            built.append(El<State>().key("__v_bot_spacer").wFull().h(botSpacerH))
        }
        if focusedPath != nil || focusedKey != nil {
            var candidateIndices: [Int] = []
            if let fp = focusedPath, fp.hasPrefix(path + "/") {
                let rest = fp.dropFirst(path.count + 1)
                let rowSeg = String(rest.prefix(while: { $0 != "/" }))
                let rowKey = rowSeg.hasPrefix("@") ? String(rowSeg.dropFirst()) : rowSeg
                let baseRowKey = rowKey.components(separatedBy: "#dup").first ?? rowKey
                for i in 0..<count where !mounted.contains(i) {
                    if keys[i] == rowKey || keys[i] == baseRowKey || keys[i] == vState.rowKeyBySegment[rowSeg] {
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
                if offEl.keyId == nil {
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
        el.children = built
        el.virtualRowsSource = nil
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

    internal func updateGrowthRowsPostLayout(
        rootResult: LayoutEngine.ResultNode,
        rootEl: El<State>,
        cut: Bool,
        snaps: Bool,
        lands: Bool,
        at now: Double
    ) -> GrowthCaptureResult {
        var result = GrowthCaptureResult()
        var seenGrowthKeys: Set<String> = []
        let settleAll = cut || lands || reducedMotion

        func foldLimit(path: String, enclosingScrollPath: String?) -> Float {
            guard let vpPath = enclosingScrollPath,
                  let vpRect = presentedRectByPath[vpPath] ?? nodeByPath[vpPath].map({ flatNodes[$0].targetRect }),
                  let rowRect = presentedRectByPath[path] ?? nodeByPath[path].map({ flatNodes[$0].targetRect }) else {
                return .infinity
            }
            return max(0, vpRect.bottom - rowRect.top)
        }

        func walk(
            el: El<State>,
            res: LayoutEngine.ResultNode,
            parentPath: String,
            siblingIndex: Int,
            siblingKeysSeen: inout [String: Int],
            inGrowthSpec: GrowthSpec?,
            enclosingScrollPath: String?
        ) {
            let (seg, _) = layoutPathSegment(keyId: el.keyId, siblingIndex: siblingIndex, siblingKeysSeen: &siblingKeysSeen)
            let path = parentPath.isEmpty ? (el.keyId.map { "/@\($0)" } ?? "/0") : "\(parentPath)/\(seg)"

            let isVirtualSpacer = (el.keyId == "__v_top_spacer" || el.keyId == "__v_bot_spacer")
            if !isVirtualSpacer && (inGrowthSpec != nil || el.foldGlideSpec != nil) {
                let gKey = el.foldGlideSpec != nil ? "fold:\(path)" : "growth:\(path)"
                seenGrowthKeys.insert(gKey)
                let naturalH = res.layout.localRect.height
                let edge: StreamEdge = el.growthSpec?.edge ?? inGrowthSpec?.edge ?? .feather
                let spring: Spring = el.growthSpec?.spring ?? inGrowthSpec?.spring ?? Growth.spring
                let limit = el.foldGlideSpec != nil ? foldLimit(path: path, enclosingScrollPath: enclosingScrollPath) : .infinity
                let glideArg: (FoldGlide, Float)? = el.foldGlideSpec.map { ($0, limit) }
                let streaming = el.isStreaming
                let whole = el.isArrivesWhole && !streaming
                let firstChildTop = res.children.first?.layout.localRect.y

                if var existing = growthRows[gKey] {
                    let prevTarget = existing.track.target
                    let prevH = existing.track.h
                    let prevTop = existing.lastFirstChildTop
                    existing.edge = edge
                    existing.spring = spring
                    existing.foldLimit = limit
                    existing.track.setKind(streaming: streaming, whole: whole, glide: glideArg)
                    if settleAll || (snaps && el.foldGlideSpec == nil && !streaming && !whole) {
                        existing.track = existing.track.restarted(at: naturalH)
                        existing.contentSlide = nil
                    } else if abs(existing.track.target - naturalH) > 0.1 {
                        existing.track.retarget(naturalH)
                        if let prevTop, let curTop = firstChildTop {
                            let topDelta = curTop - prevTop
                            let was = naturalH - prevH
                            if topDelta * (naturalH - prevTarget) > 0.01 && abs(was) > 0.01 {
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
                    if !existing.track.moving {
                        existing.contentSlide = nil
                    }
                    existing.lastFirstChildTop = firstChildTop
                    growthRows[gKey] = existing
                    if existing.track.moving {
                        result.activeCount += 1
                        if abs(existing.track.h - existing.track.target) > 0.1 || existing.track.isShuttingFold {
                            result.needsClampedRelayout = true
                        }
                    }
                } else {
                    let startsFromZero = !settleAll
                        && viewCommitCount > 1
                        && (whole || streaming)
                    var track: GrowTrack
                    if startsFromZero {
                        track = GrowTrack.settled(0)
                        track.setKind(streaming: streaming, whole: whole, glide: glideArg)
                        track.retarget(naturalH)
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
                        lastFirstChildTop: firstChildTop,
                        contentSlide: nil
                    )
                }
            }

            let nextGrowth = el.growthSpec ?? inGrowthSpec
            let nextScrollPath = el.layout.scrollAxes.isEmpty ? enclosingScrollPath : path
            if !el.children.isEmpty && el.children.count == res.children.count {
                var childSeen: [String: Int] = [:]
                for i in 0..<el.children.count {
                    walk(
                        el: el.children[i],
                        res: res.children[i],
                        parentPath: path,
                        siblingIndex: i,
                        siblingKeysSeen: &childSeen,
                        inGrowthSpec: nextGrowth,
                        enclosingScrollPath: nextScrollPath
                    )
                }
            }
        }

        var rootSeen: [String: Int] = [:]
        walk(
            el: rootEl,
            res: rootResult,
            parentPath: "",
            siblingIndex: 0,
            siblingKeysSeen: &rootSeen,
            inGrowthSpec: nil,
            enclosingScrollPath: nil
        )
        growthRows = growthRows.filter { seenGrowthKeys.contains($0.key) }
        if lastGrowthStepTime == nil {
            lastGrowthStepTime = now
        }
        return result
    }

    internal func applyGrowthConstraints(in rootEl: El<State>) -> El<State> {
        func walk(_ el: El<State>, parentPath: String, siblingIndex: Int, siblingKeysSeen: inout [String: Int], inGrowthSpec: GrowthSpec?) -> El<State> {
            let (seg, _) = layoutPathSegment(keyId: el.keyId, siblingIndex: siblingIndex, siblingKeysSeen: &siblingKeysSeen)
            let path = parentPath.isEmpty ? (el.keyId.map { "/@\($0)" } ?? "/0") : "\(parentPath)/\(seg)"
            var out = el

            let isVirtualSpacer = (el.keyId == "__v_top_spacer" || el.keyId == "__v_bot_spacer")
            if !isVirtualSpacer && (inGrowthSpec != nil || el.foldGlideSpec != nil) {
                let gKey = el.foldGlideSpec != nil ? "fold:\(path)" : "growth:\(path)"
                if let entry = growthRows[gKey], entry.track.moving {
                    let t = entry.track
                    let diff = abs(t.h - t.target)
                    let clampCollapse = (el.foldGlideSpec != nil && t.h > t.target + 0.1) || t.isShuttingFold
                    if t.h < t.target - 0.1 || clampCollapse || diff > 0.1 {
                        out.layout.height = .points(max(0, t.h))
                        out.layout.maxHeight = .points(max(0, t.h))
                        out.layout.clipOverflow = true
                    }
                    let featherH: Float
                    if t.mask > 0.5 {
                        featherH = t.mask
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

            let nextGrowth = el.growthSpec ?? inGrowthSpec
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

    internal func advanceGrowthRows(at now: Double) -> Bool {
        guard !growthRows.isEmpty else {
            lastGrowthStepTime = now
            growthSubstepAccumulator = 0
            return false
        }
        let dt = lastGrowthStepTime.map { max(0, min(0.1, now - $0)) } ?? (1.0 / 60.0)
        lastGrowthStepTime = now
        guard dt > 0 else {
            return growthRows.values.contains { $0.track.moving }
        }
        growthSubstepAccumulator += dt
        let stepSize = Double(Growth.substep)
        var substeps = Int(floor(growthSubstepAccumulator / stepSize))
        growthSubstepAccumulator -= Double(substeps) * stepSize
        substeps = min(substeps, 240)
        if substeps <= 0 {
            return growthRows.values.contains { $0.track.moving }
        }
        var anyChanged = false
        var anyMoving = false
        for (k, var entry) in growthRows {
            if !entry.track.moving { continue }
            let prevH = entry.track.h
            let prevM = entry.track.mask
            for _ in 0..<substeps {
                entry.track.step(spring: entry.spring, edge: entry.edge, carryingTail: false)
            }
            if !entry.track.moving {
                entry.contentSlide = nil
            }
            growthRows[k] = entry
            if abs(entry.track.h - prevH) > 0.05 || abs(entry.track.mask - prevM) > 0.05 || !entry.track.moving {
                anyChanged = true
            }
            if entry.track.moving {
                anyMoving = true
            }
        }
        if anyChanged {
            needsCommit = true
        }
        return anyMoving
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
                vState.lastAnchorPrefixY = prefix[ai]
            } else if stickyPin {
                vState.lastAnchorKey = nil
                vState.lastAnchorLocalY = 0
                vState.lastAnchorPrefixY = 0
            }
            if vState.measuredByKey.count > RuntimeVirtualListState.maxCachedKeys {
                let keepSet = Set(vState.lastKeys)
                vState.pruneMeasurements(keeping: keepSet)
            }
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

    internal func stepVirtualFillAfterCommit(now: Double) {
        var wanted = false
        var missing = 0
        var moved = false
        for listPath in activeVirtualPaths {
            guard let vState = virtualLists[listPath] else { continue }
            if vState.wantsMoreFrames {
                wanted = true
                missing += vState.missingOverscanRows
            }
            let scrollIdx = nodeByPath[listPath].flatMap {
                !flatNodes[$0].el.layout.scrollAxes.isEmpty ? $0 : flatNodes[$0].enclosingVScrollIndex
            }
            let scrollPath = scrollIdx.map { flatNodes[$0].path } ?? listPath
            let curScroll = scrollOffsets[scrollPath] ?? .zero
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
        let hidLeft = style.endOnly ? 0 : curScroll.x
        let hidRight = max(0, maxExt.x - curScroll.x)

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
                let pDelta = Vec2(cumulative[pIdx].x + ownDelta.x, cumulative[pIdx].y + ownDelta.y)
                cumulative[i] = pDelta
                if pDelta != .zero {
                    let inv = Vec2(-pDelta.x, -pDelta.y)
                    flatNodes[i].targetRect = flatNodes[i].targetRect.offsetBy(inv)
                    specs[i].rect = specs[i].rect.offsetBy(inv)
                }
                let parentClips = pEl.layout.clipOverflow || pEl.clipRadius != nil || pEl.clipCorners != nil || pEl.clipFade != nil
                flatNodes[i].clipRect = parentClips ? intersectRects(p.clipRect, p.targetRect) : p.clipRect
                if pDelta != .zero {
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
        scrollRequestsState.stepEndTakesOver(
            givingHeaders: [],
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

        if cut {
            scrollRequestsState.stepFinish(
                gliding: { scrollGlidingPaths.contains($0) },
                animating: { _ in false },
                mounted: { r in flatNodes.contains { selectsElementSelector(r.key, path: $0.path, key: $0.key) } }
            )
        } else {
            scrollRequestsState.stepFinish(
                gliding: { scrollGlidingPaths.contains($0) },
                animating: { vPath in
                    !growthRows.isEmpty || scrollGlidingPaths.contains(vPath)
                },
                mounted: { r in flatNodes.contains { selectsElementSelector(r.key, path: $0.path, key: $0.key) } }
            )
        }

        return keepDeltas
    }

    internal func processScrollRequestsAndCallbacks(at now: Double, cut: Bool, followEdge: Bool, snaps: Bool = false) {
        func findScrollViewportIndex(forNode idx: Int, scopeKey: String?, verticalOnly: Bool = false) -> Int? {
            var cur = flatNodes[idx].parentIndex
            while let ci = cur {
                let axes = flatNodes[ci].el.layout.scrollAxes
                let matchesAxis = verticalOnly ? axes.contains(.vertical) : !axes.isEmpty
                if matchesAxis {
                    if let scopeKey {
                        if selectsElementSelector(scopeKey, path: flatNodes[ci].path, key: flatNodes[ci].key) {
                            return ci
                        }
                    } else {
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

        let destination = !bottoms.isEmpty || !pages.isEmpty || !offsets.isEmpty
        if !reveals.isEmpty || destination {
            scrollRequestsState.stepCancel()
        }

        for req in reveals {
            let vIdx: Int
            let vPath: String
            let cur: Vec2
            let vpH: Double
            let itemH: Double
            let itemTop: Double

            if let tIdx = flatNodes.firstIndex(where: { selectsElementSelector(req.key, path: $0.path, key: $0.key) }),
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
                for (listIdx, node) in flatNodes.enumerated() {
                    guard let vState = virtualLists[node.path],
                          let rowIdx = vState.lastKeys.firstIndex(where: {
                              $0 == req.key || selectsElementSelector(req.key, path: "\(node.path)/\($0)", key: $0)
                          }) else { continue }
                    let candidateVIdx: Int?
                    if !node.el.layout.scrollAxes.isEmpty && (req.scope == nil || selectsElementSelector(req.scope!, path: node.path, key: node.key)) {
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
                    margin: 8.0
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
                applyScrollOffset(path: vPath, next: Vec2(cur.x, Float(targetY)), glide: (req.animated && !snaps) ? MotionTokens.GLIDE : nil)
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
            if let vIdx = findScrollNode(bySelector: req.key) {
                let path = flatNodes[vIdx].path
                let cur = scrollOffsets[path] ?? .zero
                let vpH = scrollViewportSizes[path]?.y ?? flatNodes[vIdx].targetRect.height
                let nextY = cur.y + Float(req.pages) * max(1, vpH * 0.9)
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
                applyScrollOffset(path: vPath, next: Vec2(cur.x, targetY), glide: req.glide)
            } else if let vIdx = findScrollNode(bySelector: req.key) {
                let path = flatNodes[vIdx].path
                let cur = scrollOffsets[path] ?? .zero
                let next = Vec2(req.x ?? cur.x, req.y ?? cur.y)
                markScrollMovedByHand(path: path)
                applyScrollOffset(path: path, next: next, glide: req.glide)
            }
        }

        if destination || cut {
            scrollRequestsState.stepDestination()
        }

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

            dispatchScrollOffsetObserverIfChanged(for: node, at: now)
        }
    }

    internal func dispatchScrollOffsetObserverIfChanged(for node: FlatNode, at now: Double = 0.0) {
        guard node.el.handlers.onScrollOffset != nil || node.el.handlers.onScroll != nil else { return }
        let path = node.path
        let cur = scrollOffsets[path] ?? .zero
        let maxExt = scrollMaxExtents[path] ?? .zero
        let vp = scrollViewportSizes[path] ?? Vec2(node.targetRect.width, node.targetRect.height)
        let pos = ScrollPos(
            offset: cur,
            max: maxExt,
            viewport: vp,
            drawn: Vec2(node.targetRect.width, node.targetRect.height)
        )
        if lastScrollOffsetReports[path] != pos {
            lastScrollOffsetReports[path] = pos
            if let onScrollOffset = node.el.handlers.onScrollOffset {
                dispatchScrollOffsetWithWatch(path: path, pos: pos, handler: onScrollOffset)
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

    // MARK: - Paint-Time Sticky Push-Out Helpers

    internal func computePaintStickyShift(
        nodeIndex idx: Int,
        parentStickyShift: Vec2,
        presentedRectByNodeId: [NodeId: MotionRect]
    ) -> (shift: Vec2, parentShiftMag: Float) {
        let node = flatNodes[idx]
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

        let scrollNode = flatNodes[sIdx]
        let scrollRect = presentedRectByNodeId[scrollNode.nodeId] ?? scrollNode.targetRect
        let scrollClip = intersectRects(scrollRect, scrollNode.clipRect)

        // Intersect scroll band across any outer scroll viewports on the same axis.
        var bandTop = scrollClip.top
        var bandBottom = scrollClip.bottom
        var bandLeft = scrollClip.left
        var bandRight = scrollClip.right
        var anc = scrollNode.parentIndex
        while let aIdx = anc {
            let aNode = flatNodes[aIdx]
            if (needsVertical && aNode.el.layout.scrollAxes.contains(.vertical))
                || (!needsVertical && aNode.el.layout.scrollAxes.contains(.horizontal)) {
                let aRect = presentedRectByNodeId[aNode.nodeId] ?? aNode.targetRect
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
            let pNode = flatNodes[pIdx]
            let pRect = presentedRectByNodeId[pNode.nodeId] ?? pNode.targetRect
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
                boxLeft = pRect.left - curScroll.x + pad.left + bdr.left
                boxTop = pRect.top - curScroll.y + pad.top + bdr.top
                boxRight = pRect.left - curScroll.x + contentW - pad.right - bdr.right
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

        let rawRect = presentedRectByNodeId[node.nodeId] ?? node.targetRect
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
