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
    }

    private var store = RuneTaffy.LayoutStore()
    private var lastViewport: Vec2 = Vec2(-1, -1)

    var storageStats: RuneTaffy.StorageStats {
        store.storageStats()
    }

    func compute<State>(
        root rootEl: El<State>,
        state: State,
        viewport: Vec2,
        pixelScale: Float,
        textSystem: TextSystem
    ) -> LayoutEngine.ResultNode {
        var flat: [PreparedNode] = []
        flat.reserveCapacity(32)
        var aspectFitIndices: [Int] = []
        var hasAnchoredFit = false

        if lastViewport != viewport {
            lastViewport = viewport
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

        func makeMeasure(el: El<State>) -> (fn: ((Float?) -> Vec2)?, hash: UInt64?, redacted: Bool) {
            guard el.children.isEmpty else { return (nil, nil, false) }
            if let editLens = el.handlers.editLens {
                var edit = editLens.get(state)
                if el.isSecure {
                    edit.isSecure = true
                    if el.isRevealed { edit.isRevealed = true }
                }
                let str = edit.displayString.isEmpty ? (el.placeholder ?? " ") : edit.displayString
                let textStyle = el.textStyle
                let isSecure = edit.isSecure
                var hasher = Hasher()
                hasher.combine(1)
                if !isSecure {
                    hasher.combine(str)
                }
                hasher.combine(edit.multiline)
                hasher.combine(scale)
                hasher.combine(textStyle)
                let h = UInt64(bitPattern: Int64(hasher.finalize()))
                let fn: (Float?) -> Vec2 = { maxW in
                    let m = textSystem.measure(str, style: textStyle, maxWidth: edit.multiline ? maxW : nil, pixelScale: scale)
                    return Vec2(max(m.x + 2, 4), max(m.y, textStyle.resolvedLineHeight))
                }
                return (fn, isSecure ? 0 : h, isSecure)
            } else if let spans = el.richSpans {
                let textStyle = el.textStyle
                var hasher = Hasher()
                hasher.combine(2)
                hasher.combine(spans)
                hasher.combine(scale)
                hasher.combine(textStyle)
                let h = UInt64(bitPattern: Int64(hasher.finalize()))
                let fn: (Float?) -> Vec2 = { maxW in
                    textSystem.shape(text: "", spans: spans, style: textStyle, maxWidth: maxW, pixelScale: scale, emitGlyphs: false).size
                }
                return (fn, h, false)
            } else if let rawTxt = el.liveText?.get() ?? el.plainText {
                let isSecure = el.isSecure
                let txt = (isSecure && !el.isRevealed && !rawTxt.isEmpty) ? "••••••••••••" : rawTxt
                let textStyle = el.textStyle
                var hasher = Hasher()
                hasher.combine(3)
                if !isSecure {
                    hasher.combine(txt)
                }
                hasher.combine(el.isRevealed)
                hasher.combine(scale)
                hasher.combine(textStyle)
                let h = UInt64(bitPattern: Int64(hasher.finalize()))
                let fn: (Float?) -> Vec2 = { maxW in
                    textSystem.measure(txt, style: textStyle, maxWidth: maxW, pixelScale: scale)
                }
                return (fn, isSecure ? 0 : h, isSecure)
            } else if let (_, iconSize) = el.iconPayload {
                var hasher = Hasher()
                hasher.combine(4)
                hasher.combine(iconSize)
                let h = UInt64(bitPattern: Int64(hasher.finalize()))
                return ({ _ in Vec2(iconSize, iconSize) }, h, false)
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
            scrollXChild: TaffyBridge.ScrollXChild?
        ) -> (idx: Int, slot: SlotId, dirty: Bool) {
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
                if style.height == .auto {
                    style.height = .points(viewport.y)
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
                measureFn: nil
            ))

            let (measureFn, measureHash, isRedacted) = makeMeasure(el: el)
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
                    scrollXChild: childSX
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
            scrollXChild: nil
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
            height: .definite(viewport.y)
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
                let childRes = extract(cIdx)
                childResults.append(childRes)
                let cNode = flat[cIdx]
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
