import Foundation
import RuneMotion
import RuneTaffy
#if canImport(CoreText) && canImport(CoreGraphics)
import CoreText
#endif

/// Per-`Runtime` retained `RuneTaffy.LayoutStore` driver.
/// Caches node styles, child lists, and Taffy 0.15 `LayoutCache` slots across view commits,
/// compacting sparse arenas in `endCommit`, and supporting `aspect_fit` two-pass refits,
/// `scroll_x` unwrapped widths, and `border_layout` snapped border insets.
/// Per-node data `syncPrepare` hands back to the recursive `syncSubtree` (see there).
fileprivate struct SyncPrepared {
    var myIndex: Int
    var path: String
    var keyHash: UInt64
    var areas: [String: RuneTaffy.GridTemplateArea]?
    var childSX: TaffyBridge.ScrollXChild?
    var nodeFlow: Flow
    var nodeDirected: Bool
    var isRow: Bool
    var measureHash: UInt64?
    var isRedacted: Bool
    var hasRatio: Bool
}

final class RetainedLayoutCoordinator {
    struct TextLayoutRecord {
        var box: TextLayoutBox
        var isInput: Bool
    }

    final class TextLayoutCollector: @unchecked Sendable {
        var map: [RuneMotion.NodeId: TextLayoutRecord] = [:]
        var liveIds: Set<RuneMotion.NodeId> = []
    }

    private struct TextLeafFallback {
        var index: Int
        var nodeId: RuneMotion.NodeId
        var shapeKey: TextShapeKey
        var text: String
        var spans: [TextSpan]?
        var pills: [PillChip]
        var style: TextStyle
        var isInput: Bool
        var pretty: Bool = false
        /// A by-paragraph field's request (`layout_text`), for a leaf no measure laid out.
        var paragraphs: ParagraphRequest? = nil
    }

    private struct MeasureBox: @unchecked Sendable {
        let fn: (Float?, Bool) -> Vec2
    }

    private struct PreparedNode {
        var index: Int
        var parentIndex: Int?
        var slot: SlotId = SlotId()
        var taffyStyle: RuneTaffy.TaffyStyle
        var rawTaffyStyle: RuneTaffy.TaffyStyle
        var aspectFitRatio: Float?
        var measureFn: ((Float?, Bool) -> Vec2)?
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
        fitHeight: Bool = false,
        textLayouts: TextLayoutCollector? = nil,
        onLiveIdsReady: ((Set<RuneMotion.NodeId>) -> Void)? = nil
    ) -> LayoutEngine.ResultNode {
        var flat: [PreparedNode] = []
        flat.reserveCapacity(32)
        var aspectFitIndices: [Int] = []
        var hasAnchoredFit = false
        var nonSecretLeaves: [TextLeafFallback] = []
        let fEpoch = textSystem.currentFontEpoch
        let langTag = textSystem.language

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

        func makeMeasure(el: El<State>, nodeId: RuneMotion.NodeId, flatIndex: Int, forcedTextFlow: TextFlow?) -> (fn: ((Float?, Bool) -> Vec2)?, hash: UInt64?, redacted: Bool) {
            guard el.children.isEmpty else { return (nil, nil, false) }
            if let editLens = el.handlers.editLens {
                let rawEdit = editLens.get(state)
                let resolved = ElDisplayResolver.resolveInput(
                    el: el,
                    edit: rawEdit,
                    fallbackDirection: forcedTextFlow
                )
                let measureStr = resolved.renderedString.isEmpty ? " " : resolved.renderedString
                // A wrapped field of more than one paragraph lays out by paragraph (`layout_text`).
                let paragraphs = Runtime<State>.paragraphRequest(field: nodeId, el: el, edit: rawEdit, resolved: resolved)
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
                let keep: TextKeep = resolved.isSecure ? .secret : .cached
                if !resolved.isSecure, !measureStr.isEmpty, textLayouts != nil {
                    let sKey = TextShapeKey(
                        authText: measureStr,
                        spans: resolved.spans,
                        pills: resolved.pills,
                        style: resolved.style,
                        pixelScale: max(scale, 1.0),
                        fontEpoch: fEpoch,
                        languageTag: langTag,
                        maxWidth: nil
                    )
                    nonSecretLeaves.append(TextLeafFallback(
                        index: flatIndex,
                        nodeId: nodeId,
                        shapeKey: sKey,
                        text: measureStr,
                        spans: resolved.spans,
                        pills: resolved.pills,
                        style: resolved.style,
                        isInput: true,
                        paragraphs: paragraphs
                    ))
                }
                let fn: (Float?, Bool) -> Vec2 = { maxW, isRealLayout in
                    // Wraps at `w * scale + FIT_SLACK` device px, as every text node lays out (#948).
                    let shapeW = TextBoxGeometry.wrapWidth(resolved.measureWidth(maxW), scale: scale)
                    let box = textSystem.layoutInput(
                        text: measureStr,
                        spans: resolved.spans,
                        pills: resolved.pills,
                        style: resolved.style,
                        maxWidth: shapeW,
                        pixelScale: scale,
                        emitGlyphs: false,
                        keep: keep,
                        countAsRebreak: (textLayouts != nil) && isRealLayout,
                        request: paragraphs
                    )
                    if !resolved.isSecure, isRealLayout, let collector = textLayouts {
                        collector.map[nodeId] = TextLayoutRecord(box: box, isInput: true)
                    }
                    let lineH = TextSystem.specLineHeight(
                        lineCount: 1,
                        lineHeightPt: resolved.style.resolvedLineHeight,
                        scale: scale,
                        exact: resolved.style.exactLines
                    )
                    return Vec2(max(box.shaped.size.x + 2, 4), max(box.shaped.size.y, lineH))
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
                hasher.combine(resolved.pretty)
                hasher.combine(scale)
                hasher.combine(resolved.style)
                let h = UInt64(bitPattern: Int64(hasher.finalize()))
                let keep: TextKeep = resolved.isSecure ? .secret : .cached
                let isClampedOrEllipsis = resolved.style.maxLines > 0 || resolved.style.wrap == .ellipsis
                if !resolved.isSecure, !resolved.displayedText.isEmpty, !resolved.truncateFade, resolved.advanceRun == nil, !isClampedOrEllipsis, textLayouts != nil {
                    let hasSpans = (resolved.spans?.isEmpty == false)
                    let sKey = TextShapeKey(
                        authText: resolved.displayedText,
                        spans: resolved.spans,
                        pills: resolved.pills,
                        style: resolved.style,
                        pixelScale: max(scale, 1.0),
                        fontEpoch: fEpoch,
                        languageTag: langTag,
                        maxWidth: nil,
                        pretty: resolved.pretty
                    )
                    nonSecretLeaves.append(TextLeafFallback(
                        index: flatIndex,
                        nodeId: nodeId,
                        shapeKey: sKey,
                        text: hasSpans ? "" : resolved.displayedText,
                        spans: resolved.spans,
                        pills: resolved.pills,
                        style: resolved.style,
                        isInput: false,
                        pretty: resolved.pretty
                    ))
                }
                let fn: (Float?, Bool) -> Vec2 = { maxW, isRealLayout in
                    if resolved.truncateFade || resolved.advanceRun != nil || isClampedOrEllipsis {
                        // Every text wraps at `w * scale + FIT_SLACK` device px; a truncated or clamped
                        // one is no wider than its room (`compute_layout`: `lw.min(a)`, #948).
                        var sz = resolved.measure(using: textSystem, maxWidth: TextBoxGeometry.wrapWidth(maxW, scale: scale), pixelScale: scale)
                        if resolved.advanceRun == nil, let mw = maxW, mw.isFinite {
                            sz.x = min(sz.x, max(0, mw))
                        }
                        return sz
                    }
                    // A text laid out again in its own box fits: it wraps at `w * scale + FIT_SLACK`
                    // device px (`compute_layout` / `relayout::lay_out_text`, #948).
                    let shapeMaxW: Float? = (resolved.style.wrap == .noWrap && resolved.style.maxLines == 0) ? nil : TextBoxGeometry.wrapWidth(maxW, scale: scale)
                    let hasSpans = (resolved.spans?.isEmpty == false)
                    let box = textSystem.layoutKeyed(
                        text: hasSpans ? "" : resolved.displayedText,
                        spans: resolved.spans,
                        pills: resolved.pills,
                        style: resolved.style,
                        maxWidth: shapeMaxW,
                        pixelScale: scale,
                        emitGlyphs: false,
                        keep: keep,
                        countAsRebreak: (textLayouts != nil) && isRealLayout,
                        pretty: resolved.pretty
                    )
                    if !resolved.isSecure, isRealLayout, let collector = textLayouts {
                        collector.map[nodeId] = TextLayoutRecord(box: box, isInput: false)
                    }
                    return box.shaped.size
                }
                return (fn, resolved.isSecure ? 0 : h, resolved.isSecure)
            } else if let (_, iconSize) = el.iconPayload {
                var hasher = Hasher()
                hasher.combine(4)
                hasher.combine(iconSize)
                let h = UInt64(bitPattern: Int64(hasher.finalize()))
                return ({ _, _ in Vec2(iconSize, iconSize) }, h, false)
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
                return ({ _, _ in Vec2(w, rowH) }, h, false)
            }
            return (nil, nil, false)
        }

        /// Per-node half of `syncSubtree`, kept out of the recursive frame (`@inline(never)`): its
        /// style temporaries (`TaffyStyle` copies, `PreparedNode`, `makeMeasure`) would otherwise
        /// stay live across every child's recursion and overflow the 512 KB test-thread stack on
        /// deep trees in debug builds.

        @inline(never)
        func syncPrepare(
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
        ) -> SyncPrepared {
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
            let runtimePath = isRoot ? (resolvedKey.map { "/@\($0)" } ?? "/0") : "\(parentPath)/\(segment)"
            let runtimeIdentityKey: String
            if el.layoutAnim?.travel == .screen, let rk = resolvedKey {
                runtimeIdentityKey = "screen:@\(rk)"
            } else {
                runtimeIdentityKey = runtimePath
            }
            let runtimeNodeId = RuneMotion.NodeId.hash(runtimeIdentityKey)
            if let collector = textLayouts {
                collector.liveIds.insert(runtimeNodeId)
            }

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

            if let font = el.outsideListDiscFont {
                #if canImport(CoreText) && canImport(CoreGraphics)
                let primary = textSystem.resolveCTFont(style: font, pixelScale: 1)
                let ascent = Float(CTFontGetAscent(primary))
                let descent = Float(abs(CTFontGetDescent(primary)))
                #else
                let ascent = font.size * 0.8
                let descent = font.size * 0.2
                #endif
                let a = (ascent * scale).rounded()
                let twoThirds = floor(a * 2 / 3)
                let diameter = floor((twoThirds + 1) / 2)
                let leading = floor((font.linePx() * scale - a - (descent * scale).rounded()) / 2)
                style.width = .points(diameter / scale)
                style.height = .points(diameter / scale)
                style.isAbsolute = true
                style.pinLeft = nil
                style.pinRight = (twoThirds + 7 - diameter) / scale
                style.pinTop = (leading + floor(1.5 * (a - twoThirds))) / scale
                style.pinBottom = nil
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

            var measured = el
            if nodeDirected && el.textDirByParagraph && el.handlers.editLens != nil {
                // A `dirByParagraph` field's paragraphs start from the element's flow (`TextDir::Plaintext`).
                measured.textStyle.byParagraphStart = nodeFlow.textFlow
            }
            let (measureFn, measureHash, isRedacted) = makeMeasure(el: measured, nodeId: runtimeNodeId, flatIndex: myIndex, forcedTextFlow: forcedTextFlow)
            flat[myIndex].measureFn = measureFn

            return SyncPrepared(
                myIndex: myIndex,
                path: path,
                keyHash: keyHash,
                areas: areas,
                childSX: childSX,
                nodeFlow: nodeFlow,
                nodeDirected: nodeDirected,
                isRow: effectiveTaffy.flexDirection.isRow,
                measureHash: measureHash,
                isRedacted: isRedacted,
                hasRatio: ratio != nil
            )
        }

        @inline(never)
        func syncFinish(_ p: SyncPrepared, childMark: Int, childrenDirty: Bool) -> (slot: SlotId, dirty: Bool) {
            let (slot, dirty) = store.syncNode(
                key: p.keyHash,
                nodeIndex: UInt32(p.myIndex),
                style: flat[p.myIndex].taffyStyle,
                measure: p.measureHash,
                forceMeasureDirty: p.isRedacted,
                childMark: childMark,
                childrenDirty: childrenDirty
            )
            flat[p.myIndex].slot = slot
            if p.hasRatio {
                aspectFitIndices.append(p.myIndex)
            }
            return (slot, dirty)
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
            let p = syncPrepare(
                el,
                isRoot: isRoot,
                parentIndex: parentIndex,
                parentPath: parentPath,
                siblingIndex: siblingIndex,
                siblingKeysSeen: &siblingKeysSeen,
                parentRow: parentRow,
                parentAreas: parentAreas,
                scrollXChild: scrollXChild,
                parentFlow: parentFlow,
                parentDirected: parentDirected
            )
            let myIndex = p.myIndex
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
                    parentPath: p.path,
                    siblingIndex: cIdx,
                    siblingKeysSeen: &childKeys,
                    parentRow: p.isRow,
                    parentAreas: p.areas,
                    scrollXChild: p.childSX,
                    parentFlow: p.nodeFlow,
                    parentDirected: p.nodeDirected
                )
                childIndices.append(childRes.idx)
                store.pushChild(childRes.slot)
                childrenDirty = childrenDirty || childRes.dirty
            }
            flat[myIndex].childIndices = childIndices

            let (slot, dirty) = syncFinish(p, childMark: childMark, childrenDirty: childrenDirty)
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

        if let collector = textLayouts {
            onLiveIdsReady?(collector.liveIds)
        }

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
            let isRealLayout: Bool
            switch input.availableSpace.width {
            case .definite(let w):
                maxW = max(0, w)
                isRealLayout = true
            case .minContent:
                maxW = 0
                isRealLayout = (input.knownDimensions.width != nil)
            case .maxContent:
                maxW = nil
                isRealLayout = (input.knownDimensions.width != nil)
            }
            let effectiveMaxW = input.knownDimensions.width.map { max(0, $0) } ?? maxW
            let measured = box.fn(effectiveMaxW, isRealLayout)
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

        if let collector = textLayouts {
            for leaf in nonSecretLeaves where collector.map[leaf.nodeId] == nil {
                if let request = leaf.paragraphs {
                    let w: Float? = max(0, store.layout(flat[leaf.index].slot).size.width)
                    let box = textSystem.layoutInput(
                        text: leaf.text,
                        spans: leaf.spans,
                        pills: leaf.pills,
                        style: leaf.style,
                        maxWidth: w,
                        pixelScale: scale,
                        emitGlyphs: false,
                        request: request
                    )
                    collector.map[leaf.nodeId] = TextLayoutRecord(box: box, isInput: leaf.isInput)
                } else if let existing = textSystem.cachedLayoutBox(for: leaf.shapeKey) {
                    collector.map[leaf.nodeId] = TextLayoutRecord(box: existing, isInput: leaf.isInput)
                } else {
                    let w: Float? = leaf.style.wrap == .noWrap ? nil : max(0, store.layout(flat[leaf.index].slot).size.width)
                    let box = textSystem.layoutKeyed(
                        text: leaf.text,
                        spans: leaf.spans,
                        pills: leaf.pills,
                        style: leaf.style,
                        maxWidth: w,
                        pixelScale: scale,
                        emitGlyphs: false,
                        keep: .cached,
                        countAsRebreak: true,
                        pretty: leaf.pretty
                    )
                    collector.map[leaf.nodeId] = TextLayoutRecord(box: box, isInput: leaf.isInput)
                }
            }
        }

        return extract(rootRes.idx)
    }
}
