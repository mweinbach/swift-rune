import Foundation
import RuneMotion
import RuneTaffy

/// Per-`Runtime` retained `RuneTaffy.LayoutStore` driver.
/// Caches node styles, child lists, and Taffy 0.15 `LayoutCache` slots across view commits,
/// compacting sparse arenas in `endCommit`, and supporting `aspect_fit` two-pass refits,
/// `scroll_x` unwrapped widths, and `border_layout` snapped border insets.
final class RetainedLayoutCoordinator {
    private struct MeasureBox: @unchecked Sendable {
        let fn: (Float?) -> Vec2
    }

    private struct PreparedNode {
        var index: Int
        var parentIndex: Int?
        var slot: SlotId = SlotId()
        var taffyStyle: RuneTaffy.TaffyStyle
        var rawTaffyStyle: RuneTaffy.TaffyStyle
        var aspectFitRatio: Float?
        var measureFn: ((Float?) -> Vec2)?
        var childIndices: [Int] = []
        var flow: Flow = .ltr
        var pin: DirPin = .flowing
    }

    private var store = RuneTaffy.LayoutStore()
    private var lastViewport: Vec2 = Vec2(-1, -1)
    private var lastFitHeight: Bool = false

    var storageStats: RuneTaffy.StorageStats {
        store.storageStats()
    }

    func compute<State>(
        root rootEl: El<State>,
        state: State,
        viewport: Vec2,
        pixelScale: Float,
        textSystem: TextSystem,
        fitHeight: Bool = false
    ) -> LayoutEngine.ResultNode {
        var flat: [PreparedNode] = []
        flat.reserveCapacity(32)
        var aspectFitIndices: [Int] = []
        var hasAnchoredFit = false

        if lastViewport != viewport || lastFitHeight != fitHeight {
            lastViewport = viewport
            lastFitHeight = fitHeight
            store.markAllDirty()
        }

        store.beginCommit()

        let scale = pixelScale

        func fnv1a64(_ s: String) -> UInt64 {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for b in s.utf8 {
                hash ^= UInt64(b)
                hash &*= 0x0100_0000_01b3
            }
            return hash
        }

        func makeMeasure(el: El<State>, forcedTextFlow: TextFlow?) -> (fn: ((Float?) -> Vec2)?, hash: UInt64?, redacted: Bool) {
            guard el.children.isEmpty else { return (nil, nil, false) }
            if let editLens = el.handlers.editLens {
                let rawEdit = editLens.get(state)
                let resolved = ElDisplayResolver.resolveInput(
                    el: el,
                    edit: rawEdit,
                    fallbackDirection: forcedTextFlow
                )
                let measureStr = resolved.renderedString.isEmpty ? " " : resolved.renderedString
                var hasher = Hasher()
                hasher.combine(1)
                if !resolved.isSecure {
                    hasher.combine(measureStr)
                    if let sp = resolved.spans { hasher.combine(sp) }
                    for p in resolved.pills { hasher.combine(p) }
                }
                hasher.combine(resolved.isSingleLine)
                hasher.combine(rawEdit.multiline)
                hasher.combine(scale)
                hasher.combine(resolved.style)
                let h = UInt64(bitPattern: Int64(hasher.finalize()))
                let fn: (Float?) -> Vec2 = { maxW in
                    let shapeW = resolved.measureWidth(maxW)
                    let m: Vec2
                    if resolved.spans != nil || !resolved.pills.isEmpty {
                        m = textSystem.shape(
                            text: measureStr,
                            spans: resolved.spans,
                            pills: resolved.pills,
                            style: resolved.style,
                            maxWidth: shapeW,
                            pixelScale: scale,
                            emitGlyphs: false
                        ).size
                    } else {
                        m = textSystem.measure(measureStr, style: resolved.style, maxWidth: shapeW, pixelScale: scale)
                    }
                    let lineH = TextSystem.specLineHeight(
                        lineCount: 1,
                        lineHeightPt: resolved.style.resolvedLineHeight,
                        scale: scale,
                        exact: resolved.style.exactLines
                    )
                    return Vec2(max(m.x + 2, 4), max(m.y, lineH))
                }
                return (fn, resolved.isSecure ? 0 : h, resolved.isSecure)
            } else if el.richSpans != nil || el.liveText != nil || el.plainText != nil || el.advanceInRun != nil {
                let rawTxt = el.liveText?.get() ?? el.plainText
                let resolved = ElDisplayResolver.resolveText(
                    el: el,
                    rawText: rawTxt,
                    isSecure: el.isSecure,
                    fallbackDirection: forcedTextFlow
                )
                var hasher = Hasher()
                hasher.combine(el.richSpans != nil ? 2 : 3)
                if !resolved.isSecure {
                    hasher.combine(resolved.displayedText)
                    if let sp = resolved.spans { hasher.combine(sp) }
                    for p in resolved.pills { hasher.combine(p) }
                    if let adv = resolved.advanceRun {
                        hasher.combine(adv.run)
                        hasher.combine(adv.byteOffset)
                    }
                }
                hasher.combine(el.isRevealed)
                hasher.combine(resolved.truncateFade)
                hasher.combine(scale)
                hasher.combine(resolved.style)
                let h = UInt64(bitPattern: Int64(hasher.finalize()))
                let fn: (Float?) -> Vec2 = { maxW in
                    resolved.measure(using: textSystem, maxWidth: maxW, pixelScale: scale)
                }
                return (fn, resolved.isSecure ? 0 : h, resolved.isSecure)
            } else if let (_, iconSize) = el.iconPayload {
                var hasher = Hasher()
                hasher.combine(4)
                hasher.combine(iconSize)
                let h = UInt64(bitPattern: Int64(hasher.finalize()))
                return ({ _ in Vec2(iconSize, iconSize) }, h, false)
            } else if let grid = el.terminalGridPayload {
                var hasher = Hasher()
                hasher.combine(5)
                hasher.combine(grid.columns)
                hasher.combine(grid.cellSize.x)
                hasher.combine(grid.cellSize.y)
                hasher.combine(grid.rows.count)
                let h = UInt64(bitPattern: Int64(hasher.finalize()))
                let w = Float(grid.columns) * grid.cellSize.x
                let rowH = Float(grid.rows.count) * grid.cellSize.y
                return ({ _ in Vec2(w, rowH) }, h, false)
            }
            return (nil, nil, false)
        }

        func syncSubtree(
            _ el: El<State>,
            isRoot: Bool,
            parentIndex: Int?,
            parentPath: String,
            siblingIndex: Int,
            siblingKeysSeen: inout [String: Int],
            parentRow: Bool,
            parentAreas: [String: RuneTaffy.GridTemplateArea]?,
            scrollXChild: TaffyBridge.ScrollXChild?,
            parentFlow: Flow,
            parentDirected: Bool
        ) -> (idx: Int, slot: SlotId, dirty: Bool) {
            let pin: DirPin = (el.isUnmirrored || el.anchor != nil) ? .physical : .flowing
            let effectiveParentFlow: Flow = el.isUnmirrored ? .ltr : parentFlow
            let (nodeFlow, _) = stepDirection(parent: effectiveParentFlow, event: DirEvent.of(el, state: state), state: state)
            let nodeDirected = (el.explicitDir != nil) || el.isUnmirrored || parentDirected
            let forcedTextFlow: TextFlow? = (nodeDirected && !el.textDirByParagraph) ? nodeFlow.textFlow : nil
            let segment: String
            let resolvedKey: String?
            if let rawK = el.keyId {
                let count = siblingKeysSeen[rawK, default: 0]
                siblingKeysSeen[rawK] = count + 1
                if count == 0 {
                    resolvedKey = rawK
                    segment = "@\(rawK)"
                } else {
                    let dup = "\(rawK)#dup\(count)"
                    resolvedKey = dup
                    segment = "@\(dup)"
                }
            } else {
                resolvedKey = nil
                segment = "\(siblingIndex)"
            }
            let path = parentPath.isEmpty ? "/0" : "\(parentPath)/\(segment)"
            let identityKey: String
            if el.layoutAnim?.travel == .screen, let rk = resolvedKey {
                identityKey = "screen:@\(rk)"
            } else {
                identityKey = path
            }
            let keyHash = fnv1a64(identityKey)

            var style = el.layout
            if isRoot {
                if style.width == .auto {
                    style.width = .points(viewport.x)
                }
                if !fitHeight && style.height == .auto {
                    style.height = .points(viewport.y)
                }
            }
            if style.aspectRatio == nil,
               (style.width == .auto) != (style.height == .auto),
               let px = el.pixelsPayload {
                let sz = px.size
                if sz.width > 0 && sz.height > 0 {
                    style.aspectRatio = Float(sz.width) / Float(sz.height)
                }
            }

            let borderOverride: Sides?
            if style.borderLayout {
                let rawBorder = el.borderSides ?? Sides.all(el.borderWidth)
                borderOverride = TaffyBridge.snappedBorderSides(rawBorder, pixelScale: scale)
            } else {
                borderOverride = nil
            }

            let areas: [String: RuneTaffy.GridTemplateArea]? = style.grid.map {
                TaffyBridge.mapGridAreas($0.templateAreas)
            }
            let hasScrollX = style.scrollAxes.contains(.horizontal)
            let forceRow = hasScrollX && (el.children.count == 1 || !style.scrollAxes.contains(.vertical))
            let childSX: TaffyBridge.ScrollXChild?
            if hasScrollX {
                let v = style.scrollAxes.contains(.vertical)
                childSX = (el.children.count == 1) ? .single(vertical: v) : .many(vertical: v)
            } else {
                childSX = nil
            }

            let rawTaffy = TaffyBridge.toTaffyStyle(
                style,
                parentAreas: parentAreas,
                borderOverride: borderOverride,
                scrollXChild: scrollXChild,
                forceScrollXRow: forceRow
            )
            let ratio = style.aspectFit.flatMap { ($0.isFinite && $0 > 0) ? $0 : nil }
            let effectiveTaffy = ratio != nil
                ? TaffyBridge.fitRoomStyle(raw: rawTaffy, parentRow: parentRow)
                : rawTaffy

            let myIndex = flat.count
            flat.append(PreparedNode(
                index: myIndex,
                parentIndex: parentIndex,
                taffyStyle: effectiveTaffy,
                rawTaffyStyle: rawTaffy,
                aspectFitRatio: ratio,
                measureFn: nil,
                flow: nodeFlow,
                pin: pin
            ))

            let (measureFn, measureHash, isRedacted) = makeMeasure(el: el, forcedTextFlow: forcedTextFlow)
            flat[myIndex].measureFn = measureFn

            let isRow = effectiveTaffy.flexDirection.isRow
            let childMark = store.beginChildren()
            var childrenDirty = false
            var childKeys: [String: Int] = [:]
            var childIndices: [Int] = []
            childIndices.reserveCapacity(el.children.count)

            for (cIdx, childEl) in el.children.enumerated() {
                let childRes = syncSubtree(
                    childEl,
                    isRoot: false,
                    parentIndex: myIndex,
                    parentPath: path,
                    siblingIndex: cIdx,
                    siblingKeysSeen: &childKeys,
                    parentRow: isRow,
                    parentAreas: areas,
                    scrollXChild: childSX,
                    parentFlow: nodeFlow,
                    parentDirected: nodeDirected
                )
                childIndices.append(childRes.idx)
                store.pushChild(childRes.slot)
                childrenDirty = childrenDirty || childRes.dirty
            }
            flat[myIndex].childIndices = childIndices

            let (slot, dirty) = store.syncNode(
                key: keyHash,
                nodeIndex: UInt32(myIndex),
                style: effectiveTaffy,
                measure: measureHash,
                forceMeasureDirty: isRedacted,
                childMark: childMark,
                childrenDirty: childrenDirty
            )
            flat[myIndex].slot = slot
            if ratio != nil {
                aspectFitIndices.append(myIndex)
            }
            if el.anchor?.fit == true {
                hasAnchoredFit = true
            }
            return (myIndex, slot, dirty)
        }

        var rootKeys: [String: Int] = [:]
        var rootRes = syncSubtree(
            rootEl,
            isRoot: true,
            parentIndex: nil,
            parentPath: "",
            siblingIndex: 0,
            siblingKeysSeen: &rootKeys,
            parentRow: false,
            parentAreas: nil,
            scrollXChild: nil,
            parentFlow: .ltr,
            parentDirected: false
        )

        var rootSlot = rootRes.slot
        store.endCommit(root: &rootSlot) { nodeIdx, newSlot in
            let i = Int(nodeIdx)
            if i < flat.count {
                flat[i].slot = newSlot
            }
        }
        rootRes.slot = rootSlot

        let available = RuneTaffy.Size<RuneTaffy.AvailableSpace>(
            width: .definite(viewport.x),
            height: fitHeight ? .maxContent : .definite(viewport.y)
        )

        let measureBoxes: [MeasureBox?] = flat.map { $0.measureFn.map { MeasureBox(fn: $0) } }
        let measureClosure: @Sendable (RuneTaffy.LayoutInput, Int?, RuneTaffy.TaffyStyle) -> RuneTaffy.LayoutOutput = { input, ctx, _ in
            guard let idx = ctx, idx >= 0, idx < measureBoxes.count,
                  let box = measureBoxes[idx]
            else {
                return RuneTaffy.LayoutOutput.fromOuterSize(.zero)
            }
            let maxW: Float?
            switch input.availableSpace.width {
            case .definite(let w): maxW = max(0, w)
            case .minContent: maxW = 0
            case .maxContent: maxW = nil
            }
            let measured = box.fn(maxW)
            return RuneTaffy.LayoutOutput.fromOuterSize(RuneTaffy.Size(
                width: input.knownDimensions.width ?? measured.x,
                height: input.knownDimensions.height ?? measured.y
            ))
        }

        store.computeLayout(root: rootSlot, availableSpace: available, rounding: false, measureLeaf: measureClosure)

        if !aspectFitIndices.isEmpty {
            for idx in aspectFitIndices {
                guard let ratio = flat[idx].aspectFitRatio else { continue }
                let roomLayout = store.boxLayout(flat[idx].slot)
                let fitted = TaffyBridge.fittedStyle(
                    ratio: ratio,
                    raw: flat[idx].rawTaffyStyle,
                    room: RuneTaffy.Size(width: roomLayout.size.width, height: roomLayout.size.height)
                )
                flat[idx].taffyStyle = fitted
                var ancestors: [SlotId] = []
                var cur = flat[idx].parentIndex
                while let p = cur {
                    ancestors.append(flat[p].slot)
                    cur = flat[p].parentIndex
                }
                store.setStyleAndMarkAncestors(flat[idx].slot, style: fitted, ancestors: ancestors)
            }
            store.computeLayout(root: rootSlot, availableSpace: available, rounding: false, measureLeaf: measureClosure)
        }

        func extract(_ idx: Int) -> LayoutEngine.ResultNode {
            let node = flat[idx]
            let taffyLayout = store.layout(node.slot)

            var childResults: [LayoutEngine.ResultNode] = []
            childResults.reserveCapacity(node.childIndices.count)
            var childLayoutsForContent: [(layout: RuneTaffy.Layout, style: RuneTaffy.TaffyStyle, content: Vec2)] = []
            childLayoutsForContent.reserveCapacity(node.childIndices.count)

            for cIdx in node.childIndices {
                var childRes = extract(cIdx)
                let cNode = flat[cIdx]
                if node.flow == .rtl && cNode.pin == .flowing {
                    let lr = childRes.layout.localRect
                    childRes.layout.localRect = MotionRect.fromXYWH(
                        taffyLayout.size.width - lr.x - lr.width,
                        lr.y,
                        lr.width,
                        lr.height
                    )
                }
                childResults.append(childRes)
                let cLayout = store.layout(cNode.slot)
                childLayoutsForContent.append((cLayout, cNode.taffyStyle, childRes.layout.contentSize))
            }

            let content = TaffyBridge.computeContentSize(
                ownLayout: taffyLayout,
                ownStyle: node.taffyStyle,
                children: childLayoutsForContent
            )

            return LayoutEngine.ResultNode(
                layout: ComputedLayout(
                    localRect: MotionRect.fromXYWH(
                        taffyLayout.location.x,
                        taffyLayout.location.y,
                        taffyLayout.size.width,
                        taffyLayout.size.height
                    ),
                    localSize: Vec2(taffyLayout.size.width, taffyLayout.size.height),
                    contentSize: content
                ),
                children: childResults
            )
        }

        if hasAnchoredFit {
            let preFitSolved = extract(rootRes.idx)
            let boundsToApply = AnchorLayoutHelper.collectFitBounds(
                rootEl: rootEl,
                solved: preFitSolved,
                viewport: viewport
            )
            if !boundsToApply.isEmpty {
                for (idxPath, vertical, bound) in boundsToApply {
                    var targetIdx: Int? = rootRes.idx
                    for c in idxPath {
                        guard let cur = targetIdx, c >= 0, c < flat[cur].childIndices.count else {
                            targetIdx = nil
                            break
                        }
                        targetIdx = flat[cur].childIndices[c]
                    }
                    guard let idx = targetIdx else { continue }
                    let dim: RuneTaffy.Dimension = .length(max(0, bound))
                    if vertical {
                        flat[idx].taffyStyle.maxSize.height = dim
                    } else {
                        flat[idx].taffyStyle.maxSize.width = dim
                    }
                    var ancestors: [SlotId] = []
                    var cur = flat[idx].parentIndex
                    while let p = cur {
                        ancestors.append(flat[p].slot)
                        cur = flat[p].parentIndex
                    }
                    store.setStyleAndMarkAncestors(flat[idx].slot, style: flat[idx].taffyStyle, ancestors: ancestors)
                }
                store.computeLayout(root: rootSlot, availableSpace: available, rounding: false, measureLeaf: measureClosure)
            }
        }

        return extract(rootRes.idx)
    }
}
