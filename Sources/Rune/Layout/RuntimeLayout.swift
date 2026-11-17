import Foundation
#if os(Android)
import Android
#endif
import RuneMotion
import RuneTaffy
#if canImport(CoreText) && canImport(CoreGraphics)
import CoreText
#endif

/// The node and inherited layout state produced before a subtree is visited.
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

/// Reconciles Rune elements with the per-runtime Taffy store, retaining node styles,
/// child lists, measurements and solved geometry across view commits.
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

    // Supply the current pass's collector and node identity to transferred text measures.
    private typealias Measure = (Float?, Bool, TextLayoutCollector?, RuneMotion.NodeId) -> Vec2
    private enum MeasureBox: @unchecked Sendable {
        case content(Measure)
        case picture(ratio: Float)
    }

    private struct MemoEnvironment: Equatable {
        let textSystem: ObjectIdentifier
        let fontEpoch: UInt64
        let language: String?
        let smoothing: FontSmoothing
        let scale: Float
        let collectsText: Bool
    }

    private typealias OverflowLeaf = (index: Int, id: RuneMotion.NodeId, text: ElResolvedText)

    /// Postorder ranges while a disjoint outer memo is being prepared. Nested memos retain
    /// slices of the same captured storage, so a changed outer version can still transfer
    /// its unchanged inner cards without storing the tree once per nesting level.
    private struct MemoRecord {
        weak var identity: AnyObject?
        var root: SyncPrepared
        var nodes: Range<Int>
        var leaves: Range<Int>
        var overflow: Range<Int>
        var nestedStart: Int
    }

    private struct MemoSpan {
        var record: MemoRecord
        var root: SyncPrepared { record.root }
        var keyedRootPath: String?
        var nodes: ArraySlice<PreparedNode>
        var leaves: ArraySlice<TextLeafFallback>
        var overflow: ArraySlice<OverflowLeaf>
        var nested: ArraySlice<MemoRecord>
        var isGroupRoot: Bool

        func hasSameChildContext(_ prepared: SyncPrepared) -> Bool {
            root.isRow == prepared.isRow && root.childSX == prepared.childSX &&
                root.nodeFlow == prepared.nodeFlow && root.nodeDirected == prepared.nodeDirected &&
                root.areas == prepared.areas
        }
    }

    private typealias SyncResult = (idx: Int, slot: SlotId, dirty: Bool)

    private struct MemoMark {
        let identity: AnyObject
        let wasRecording: Bool
        let firstLeaf: Int
        let firstOverflow: Int
        let firstRecord: Int
    }

    private struct SyncVisit<State> {
        let prepared: SyncPrepared
        let childMark: Int
        let children: [El<State>]
        var childKeys: [String: Int] = [:]
        var childIndices: [Int] = []
        var childrenDirty = false
        let memo: MemoMark?
    }

    private enum SyncStep<State> {
        case visit(SyncVisit<State>)
        case finished(SyncResult)
    }

    private struct PreparedNode {
        var path: String
        var storeKey: UInt64
        var runtimeId: RuneMotion.NodeId
        var screenIdentity: Bool
        var parentIndex: Int?
        var slot: SlotId = SlotId()
        var taffyStyle: RuneTaffy.TaffyStyle
        var rawTaffyStyle: RuneTaffy.TaffyStyle
        var aspectFitRatio: Float?
        var measure: MeasureBox?
        var childIndices: [Int] = []
        var flow: Flow = .ltr
        var pin: DirPin = .flowing
    }

    private var store = RuneTaffy.LayoutEngine()
    private var memoSpans: [ObjectIdentifier: MemoSpan] = [:]
    private var memoEnvironment: MemoEnvironment?
    private var lastMemoLayout: LayoutEngine.ResultNode?
    private(set) var reusedMemoGeometry = false
    /// Number of descendants whose prepared style and measurement were transferred on this pass.
    private(set) var reusedMemoNodeCount = 0
    private var lastViewport: Vec2 = Vec2(-1, -1)
    private var lastFitHeight: Bool = false

    var storageStats: RuneTaffy.StorageStats {
        store.storageStats()
    }

    /// A picture derives its automatic side from the clamped size of the other one.
    /// Percentages with limits resolve during layout, once the parent's size is known.
    private static func configurePicture(_ pixels: Pixels?, style: inout LayoutStyle) -> Float? {
        guard let pixels, style.aspectRatio == nil, (style.width == .auto) != (style.height == .auto) else { return nil }
        let size = pixels.size
        guard size.width > 0, size.height > 0 else { return nil }
        let ratio = Float(size.width) / Float(size.height)
        let hasWidth = style.height == .auto
        let lower = hasWidth ? style.minWidth : style.minHeight
        let upper = hasWidth ? style.maxWidth : style.maxHeight
        if lower != .auto || upper != .auto {
            let specified = hasWidth ? style.width : style.height
            let minimum = lower.resolve(against: nil)
            let maximum = upper.resolve(against: nil)
            guard var points = specified.resolve(against: nil), lower == .auto || minimum != nil,
                  upper == .auto || maximum != nil else { return ratio }
            if let maximum { points = min(points, maximum) }
            if let minimum { points = max(points, minimum) }
            if hasWidth { style.width = .points(points) } else { style.height = .points(points) }
        }
        style.aspectRatio = ratio
        return nil
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
        var overflowLeaves: [OverflowLeaf] = []
        let fEpoch = textSystem.currentFontEpoch
        let langTag = textSystem.language
        let storeRootPath = "/0"
        let keyedRootPath = rootEl.storageKeyId.map { "/@\($0)" }

        if lastViewport != viewport || lastFitHeight != fitHeight {
            lastMemoLayout = nil
            lastViewport = viewport
            lastFitHeight = fitHeight
            store.markAllDirty()
        }

        store.beginCommit()

        let scale = pixelScale
        let environment = MemoEnvironment(textSystem: ObjectIdentifier(textSystem), fontEpoch: fEpoch,
            language: langTag, smoothing: textSystem.smoothing, scale: scale, collectsText: textLayouts != nil)
        if memoEnvironment != environment {
            if memoEnvironment != nil { store.markAllDirty() }
            lastMemoLayout = nil
            memoEnvironment = environment
            memoSpans.removeAll(keepingCapacity: true)
        }
        var nextMemoSpans: [ObjectIdentifier: MemoSpan] = [:]
        var recordingMemo = false
        var memoRecords: [MemoRecord] = []
        reusedMemoNodeCount = 0
        reusedMemoGeometry = false
        var geometryChanged = false
        var hasMirroredFlow = false

        func fnv1a64(_ s: String) -> UInt64 {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for b in s.utf8 {
                hash ^= UInt64(b)
                hash &*= 0x0100_0000_01b3
            }
            return hash
        }

        func makeMeasure(el: El<State>, nodeId: RuneMotion.NodeId, flatIndex: Int, forcedTextFlow: TextFlow?) -> (fn: Measure?, hash: UInt64?, redacted: Bool) {
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
                if resolved.style.fontSmoothing == .systemDefault { hasher.combine(textSystem.smoothing) }
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
                        maxWidth: nil,
                        defaultSmoothing: textSystem.smoothing
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
                let fn: Measure = { maxW, isRealLayout, textLayouts, nodeId in
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
                    return Vec2(box.shaped.size.x, max(box.shaped.size.y, lineH))
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
                if resolved.style.fontSmoothing == .systemDefault { hasher.combine(textSystem.smoothing) }
                let h = UInt64(bitPattern: Int64(hasher.finalize()))
                let keep: TextKeep = resolved.isSecure ? .secret : .cached
                let isClampedOrEllipsis = resolved.style.maxLines > 0 || resolved.style.wrap == .ellipsis
                if textLayouts != nil, !resolved.isSecure, resolved.advanceRun == nil,
                   !resolved.displayedText.isEmpty, resolved.truncateFade || isClampedOrEllipsis {
                    overflowLeaves.append((flatIndex, nodeId, resolved))
                }
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
                        pretty: resolved.pretty,
                        defaultSmoothing: textSystem.smoothing
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
                let fn: Measure = { maxW, isRealLayout, textLayouts, nodeId in
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
                return ({ _, _, _, _ in Vec2(iconSize, iconSize) }, h, false)
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
                return ({ _, _, _, _ in Vec2(w, rowH) }, h, false)
            }
            return (nil, nil, false)
        }

        /// Prepare one node before visiting its children. Large style and measure temporaries
        /// stay outside the traversal loop's stack frame.

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
            let (nodeFlow, _) = stepDirection(parent: effectiveParentFlow, el: el, state: state)
            if nodeFlow == .rtl { hasMirroredFlow = true }
            let nodeDirected = (el.explicitDir != nil) || el.isUnmirrored || parentDirected
            let forcedTextFlow: TextFlow? = (nodeDirected && !el.textDirByParagraph) ? nodeFlow.textFlow : nil
            let segment: String
            let resolvedKey: String?
            if let rawK = el.storageKeyId {
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
            let path = parentPath.isEmpty ? storeRootPath : "\(parentPath)/\(segment)"
            let identityKey: String
            if el.layoutAnim?.travel == .screen, let rk = resolvedKey {
                identityKey = "screen:@\(rk)"
            } else {
                identityKey = path
            }
            let keyHash = fnv1a64(identityKey)
            let runtimeIdentityKey: String
            if el.layoutAnim?.travel == .screen, let rk = resolvedKey {
                runtimeIdentityKey = "screen:@\(rk)"
            } else if let keyedRootPath {
                // Taffy's root slot is stable across root keys. The runtime anchors text
                // layouts for the whole subtree under the authored root identity instead.
                runtimeIdentityKey = keyedRootPath + path.dropFirst(storeRootPath.count)
            } else {
                runtimeIdentityKey = path
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
            let pictureRatioToMeasure = Self.configurePicture(el.pixelsPayload, style: &style)

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

            var borderOverride: Sides?
            if style.borderLayout {
                let rawBorder = el.borderSides ?? Sides.all(el.borderWidth)
                borderOverride = TaffyBridge.snappedBorderSides(rawBorder, pixelScale: scale)
            } else {
                borderOverride = nil
            }

            // A growth track can reveal less than the row's insets. Flex layout gets the
            // revealed slot; its contents keep their positions from the natural layout.
            if style.usesNaturalGrowthContents {
                style.padding.top = 0
                style.padding.bottom = 0
                var border = borderOverride ?? style.border
                border.top = 0
                border.bottom = 0
                borderOverride = border
                style.clipOverflow = true
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
                path: path,
                storeKey: keyHash,
                runtimeId: runtimeNodeId,
                screenIdentity: el.layoutAnim?.travel == .screen && resolvedKey != nil,
                parentIndex: parentIndex,
                taffyStyle: effectiveTaffy,
                rawTaffyStyle: rawTaffy,
                aspectFitRatio: ratio,
                measure: nil,
                flow: nodeFlow,
                pin: pin
            ))

            var measured = el
            if nodeDirected && el.textDirByParagraph && el.handlers.editLens != nil {
                // A `dirByParagraph` field's paragraphs start from the element's flow (`TextDir::Plaintext`).
                measured.textStyle.byParagraphStart = nodeFlow.textFlow
            }
            let (measureFn, measureHash, isRedacted) = makeMeasure(el: measured, nodeId: runtimeNodeId, flatIndex: myIndex, forcedTextFlow: forcedTextFlow)
            flat[myIndex].measure = measureFn.map(MeasureBox.content) ?? pictureRatioToMeasure.map(MeasureBox.picture)

            return SyncPrepared(
                myIndex: myIndex,
                path: path,
                keyHash: keyHash,
                areas: areas,
                childSX: childSX,
                nodeFlow: nodeFlow,
                nodeDirected: nodeDirected,
                isRow: effectiveTaffy.flexDirection.isRow,
                measureHash: measureHash ?? pictureRatioToMeasure.map { 0x7069_6300_0000_0000 | UInt64($0.bitPattern) },
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
            if dirty { geometryChanged = true }
            flat[p.myIndex].slot = slot
            if p.hasRatio {
                aspectFitIndices.append(p.myIndex)
            }
            return (slot, dirty)
        }

        /// Claim the old subtree atomically, including destination paths before any rekey.
        /// Root modifiers are always prepared again. Children share the original memo buffer.
        @inline(never)
        func reuseChildren(_ span: MemoSpan, _ p: SyncPrepared) -> Bool {
            guard span.hasSameChildContext(p),
                  span.nodes.allSatisfy({ store.canReuse(key: $0.storeKey, slot: $0.slot) })
            else { return false }
            let oldStart = span.root.myIndex
            let shift = p.myIndex - oldStart
            let moved = span.root.path != p.path
            let changedIds = moved || span.keyedRootPath != keyedRootPath
            func newPath(_ node: PreparedNode) -> String {
                p.path + node.path.dropFirst(span.root.path.count)
            }
            if moved {
                var slots: [(UInt64, UInt64, SlotId, UInt32)] = []
                slots.reserveCapacity(span.nodes.count)
                for (offset, node) in span.nodes.enumerated() {
                    let key: UInt64
                    if offset == 0 { key = p.keyHash }
                    else { key = node.screenIdentity ? node.storeKey : fnv1a64(newPath(node)) }
                    guard !store.isUsedThisCommit(key: key) else { return false }
                    slots.append((node.storeKey, key, node.slot, UInt32(p.myIndex + offset)))
                }
                store.rekeyAndReuseBatch(slots)
            }
            let oldRoot = span.nodes.first!
            flat[p.myIndex].childIndices = shift == 0 ? oldRoot.childIndices : oldRoot.childIndices.map { $0 + shift }
            if shift == 0 && !changedIds {
                for (offset, node) in span.nodes.dropFirst().enumerated() {
                    store.reuseSlot(node.slot, nodeIndex: UInt32(p.myIndex + offset + 1))
                    if node.flow == .rtl { hasMirroredFlow = true }
                    textLayouts?.liveIds.insert(node.runtimeId)
                }
                flat.append(contentsOf: span.nodes.dropFirst())
            } else {
                for var node in span.nodes.dropFirst() {
                    let index = flat.count
                    if !moved { store.reuseSlot(node.slot, nodeIndex: UInt32(index)) }
                    if moved {
                        node.path = newPath(node)
                        if !node.screenIdentity { node.storeKey = fnv1a64(node.path) }
                    }
                    if changedIds && !node.screenIdentity {
                        let runtimePath = keyedRootPath.map { $0 + node.path.dropFirst(storeRootPath.count) } ?? node.path
                        node.runtimeId = RuneMotion.NodeId.hash(runtimePath)
                    }
                    if shift != 0 {
                        node.parentIndex = node.parentIndex.map { $0 + shift }
                        node.childIndices = node.childIndices.map { $0 + shift }
                    }
                    if node.flow == .rtl { hasMirroredFlow = true }
                    textLayouts?.liveIds.insert(node.runtimeId)
                    flat.append(node)
                }
            }
            for var leaf in span.leaves {
                leaf.index += shift
                leaf.nodeId = flat[leaf.index].runtimeId
                nonSecretLeaves.append(leaf)
            }
            for leaf in span.overflow {
                let index = leaf.index + shift
                overflowLeaves.append((index, flat[index].runtimeId, leaf.text))
            }
            for child in flat[p.myIndex].childIndices { store.pushChild(flat[child].slot) }
            reusedMemoNodeCount += span.nodes.count - 1
            return true
        }

        @inline(never)
        func installMemoGroup() {
            let group = memoRecords.last!
            let records = memoRecords
            memoRecords = []
            let nodes = Array(flat[group.nodes])
            // Screen-space travel keys can alias a slot even in distinct sibling branches.
            guard Set(nodes.map(\.slot)).count == nodes.count else { return }
            let leaves = Array(nonSecretLeaves[group.leaves])
            let overflow = Array(overflowLeaves[group.overflow])
            func local(_ range: Range<Int>, _ start: Int) -> Range<Int> {
                (range.lowerBound - start)..<(range.upperBound - start)
            }
            for (index, record) in records.enumerated() {
                guard let id = record.identity else { continue }
                nextMemoSpans[ObjectIdentifier(id)] = MemoSpan(
                    record: record, keyedRootPath: keyedRootPath, nodes: nodes[local(record.nodes, group.nodes.lowerBound)],
                    leaves: leaves[local(record.leaves, group.leaves.lowerBound)],
                    overflow: overflow[local(record.overflow, group.overflow.lowerBound)],
                    nested: records[record.nestedStart..<index], isGroupRoot: index == records.count - 1
                )
            }
        }

        @inline(never)
        func moveNestedRecords(_ span: MemoSpan, _ p: SyncPrepared, firstLeaf: Int, firstOverflow: Int) {
            let shift = p.myIndex - span.root.myIndex
            let recordShift = memoRecords.count - span.nested.startIndex
            let leafShift = firstLeaf - span.record.leaves.lowerBound
            let overflowShift = firstOverflow - span.record.overflow.lowerBound
            func moved(_ range: Range<Int>, _ by: Int) -> Range<Int> {
                (range.lowerBound + by)..<(range.upperBound + by)
            }
            for var record in span.nested {
                record.nodes = moved(record.nodes, shift)
                record.root.myIndex += shift
                record.root.path = flat[record.root.myIndex].path
                record.root.keyHash = flat[record.root.myIndex].storeKey
                record.leaves = moved(record.leaves, leafShift)
                record.overflow = moved(record.overflow, overflowShift)
                record.nestedStart += recordShift
                memoRecords.append(record)
            }
        }

        @inline(never)
        func beginVisit(
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
        ) -> SyncStep<State> {
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
            if el.anchor?.fit == true { hasAnchoredFit = true }
            if el.children.isEmpty {
                let (slot, dirty) = syncFinish(p, childMark: childMark, childrenDirty: false)
                return .finished((myIndex, slot, dirty))
            }
            let wasRecording = recordingMemo
            let firstRecord = memoRecords.count
            let identity = el.memoLayoutChildren
            let memoKey = identity.flatMap { memo -> ObjectIdentifier? in
                guard memo.traits.isDisjoint(with: [.mutableLayout, .virtual, .growth]),
                      memo.matches(el.children) else { return nil }
                return ObjectIdentifier(memo)
            }
            let firstLeaf = nonSecretLeaves.count
            let firstOverflow = overflowLeaves.count
            if let memoKey, let span = memoSpans[memoKey], span.record.identity === identity,
               reuseChildren(span, p) {
                let (slot, dirty) = syncFinish(p, childMark: childMark, childrenDirty: false)
                if !wasRecording, span.isGroupRoot, p.path == span.root.path, p.myIndex == span.root.myIndex,
                   keyedRootPath == span.keyedRootPath, span.nodes.first?.slot == slot {
                    nextMemoSpans[memoKey] = span
                    for inner in span.nested {
                        if let id = inner.identity {
                            let key = ObjectIdentifier(id)
                            nextMemoSpans[key] = memoSpans[key]
                        }
                    }
                } else {
                    moveNestedRecords(span, p, firstLeaf: firstLeaf, firstOverflow: firstOverflow)
                    memoRecords.append(MemoRecord(identity: identity, root: p, nodes: myIndex..<flat.count,
                        leaves: firstLeaf..<nonSecretLeaves.count, overflow: firstOverflow..<overflowLeaves.count,
                        nestedStart: firstRecord))
                    if !wasRecording { installMemoGroup() }
                }
                return .finished((myIndex, slot, dirty))
            }
            var mark: MemoMark?
            if memoKey != nil, let identity {
                mark = MemoMark(identity: identity, wasRecording: wasRecording, firstLeaf: firstLeaf,
                                firstOverflow: firstOverflow, firstRecord: firstRecord)
                recordingMemo = true
            }
            var visit = SyncVisit(prepared: p, childMark: childMark, children: el.children, memo: mark)
            visit.childIndices.reserveCapacity(el.children.count)
            return .visit(visit)
        }

        @inline(never)
        func finishVisit(_ visit: SyncVisit<State>) -> SyncResult {
            let p = visit.prepared
            flat[p.myIndex].childIndices = visit.childIndices
            let (slot, dirty) = syncFinish(p, childMark: visit.childMark, childrenDirty: visit.childrenDirty)
            if let mark = visit.memo {
                recordingMemo = mark.wasRecording
                memoRecords.append(MemoRecord(identity: mark.identity, root: p, nodes: p.myIndex..<flat.count,
                    leaves: mark.firstLeaf..<nonSecretLeaves.count, overflow: mark.firstOverflow..<overflowLeaves.count,
                    nestedStart: mark.firstRecord))
                if !mark.wasRecording { installMemoGroup() }
            }
            return (p.myIndex, slot, dirty)
        }

        // Swift Testing and app worker threads have small native stacks. Keep the pending
        // parent frames on the heap and preserve Taffy's postorder child-list synchronization.
        func syncTree() -> SyncResult {
            var rootKeys: [String: Int] = [:]
            var next = beginVisit(rootEl, isRoot: true, parentIndex: nil, parentPath: "", siblingIndex: 0,
                siblingKeysSeen: &rootKeys, parentRow: false, parentAreas: nil, scrollXChild: nil,
                parentFlow: .ltr, parentDirected: false)
            var stack: [SyncVisit<State>] = []
            while true {
                switch next {
                case .visit(let visit):
                    stack.append(visit)
                case .finished(let result):
                    guard !stack.isEmpty else { return result }
                    let parent = stack.count - 1
                    stack[parent].childIndices.append(result.idx)
                    if result.dirty { stack[parent].childrenDirty = true }
                    store.pushChild(result.slot)
                }
                let parent = stack.count - 1
                let index = stack[parent].childIndices.count
                if index == stack[parent].children.count {
                    next = .finished(finishVisit(stack.removeLast()))
                } else {
                    let prepared = stack[parent].prepared
                    let child = stack[parent].children[index]
                    next = beginVisit(child, isRoot: false, parentIndex: prepared.myIndex,
                        parentPath: prepared.path, siblingIndex: index, siblingKeysSeen: &stack[parent].childKeys,
                        parentRow: prepared.isRow, parentAreas: prepared.areas, scrollXChild: prepared.childSX,
                        parentFlow: prepared.nodeFlow, parentDirected: prepared.nodeDirected)
                }
            }
        }

        var rootRes = syncTree()
        var rootSlot = rootRes.slot
        store.endCommit(root: &rootSlot) { nodeIdx, newSlot in
            let i = Int(nodeIdx)
            if i < flat.count {
                flat[i].slot = newSlot
            }
        }
        rootRes.slot = rootSlot
        memoSpans = nextMemoSpans

        if let collector = textLayouts {
            onLiveIdsReady?(collector.liveIds)
        }

        let available = RuneTaffy.Size<RuneTaffy.AvailableSpace>(
            width: .definite(viewport.x),
            height: fitHeight ? .maxContent : .definite(viewport.y)
        )

        let measureBoxes = flat.map { ($0.measure, $0.runtimeId) }
        let measureClosure: @Sendable (RuneTaffy.LayoutInput, Int?, RuneTaffy.TaffyStyle) -> RuneTaffy.LayoutOutput = { input, ctx, style in
            guard let idx = ctx, idx >= 0, idx < measureBoxes.count,
                  let box = measureBoxes[idx].0
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
            let measured: Vec2
            switch box {
            case .content(let measure):
                measured = measure(effectiveMaxW, isRealLayout, textLayouts, measureBoxes[idx].1)
            case .picture(let ratio):
                // Rust's picture measure receives known border-box dimensions, and
                // available content-box space when neither side is known.
                let p = style.padding, b = style.border, parent = input.parentSize.width
                let width = input.knownDimensions.width.map {
                    $0 + p.left.resolveOrZero(parent) + p.right.resolveOrZero(parent)
                        + b.left.resolveOrZero(parent) + b.right.resolveOrZero(parent)
                        + (style.overflow.y == .scroll ? style.scrollbarWidth : 0)
                } ?? input.knownDimensions.height.map {
                    ($0 + p.top.resolveOrZero(parent) + p.bottom.resolveOrZero(parent)
                        + b.top.resolveOrZero(parent) + b.bottom.resolveOrZero(parent)
                        + (style.overflow.x == .scroll ? style.scrollbarWidth : 0)) * ratio
                } ?? maxW ?? 0
                measured = Vec2(width, width / ratio)
            }
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

        // Flat nodes are in preorder. Walking them backwards leaves each node's solved
        // children at the top of the stack in their original painter/layout order.
        func extract() -> LayoutEngine.ResultNode {
            var solved: [(RuneTaffy.Layout, LayoutEngine.ResultNode)] = []
            for node in flat.reversed() {
                let box = store.layout(node.slot)
                var content = TaffyBridge.ContentExtent(box)
                var children: [LayoutEngine.ResultNode] = []
                children.reserveCapacity(node.childIndices.count)
                for childIndex in node.childIndices {
                    let child = flat[childIndex]
                    let (childBox, result) = solved.removeLast()
                    var placed = result
                    if node.flow == .rtl && child.pin == .flowing {
                        let rect = placed.layout.localRect
                        placed.layout.localRect = MotionRect.fromXYWH(
                            box.size.width - rect.x - rect.width, rect.y, rect.width, rect.height
                        )
                    }
                    children.append(placed)
                    content.include(childBox, style: child.taffyStyle, content: placed.layout.contentSize)
                }
                let layout = ComputedLayout(
                    localRect: MotionRect.fromXYWH(box.location.x, box.location.y, box.size.width, box.size.height),
                    localSize: Vec2(box.size.width, box.size.height), contentSize: content.size
                )
                solved.append((box, LayoutEngine.ResultNode(layout: layout, children: children)))
            }
            return solved.removeLast().1
        }

        if hasAnchoredFit {
            let preFitSolved = extract()
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
            for leaf in overflowLeaves {
                let bounds = store.layout(flat[leaf.index].slot)
                let width = max(0, bounds.contentBoxSize().width - bounds.scrollbarSize.width)
                if let box = textSystem.preparedOverflowLayout(
                    leaf.text, width: TextBoxGeometry.wrapWidth(width, scale: scale), scale: scale,
                    create: textSystem.isPreparingLayouts
                ) {
                    collector.map[leaf.id] = TextLayoutRecord(box: box, isInput: false)
                }
            }
            for leaf in nonSecretLeaves where collector.map[leaf.nodeId] == nil {
                let bounds = store.layout(flat[leaf.index].slot)
                let contentWidth = max(0, bounds.contentBoxSize().width - bounds.scrollbarSize.width)
                let wrapWidth = leaf.style.wrap == .noWrap ? nil : TextBoxGeometry.wrapWidth(contentWidth, scale: scale)
                if let request = leaf.paragraphs {
                    let box = textSystem.layoutInput(
                        text: leaf.text,
                        spans: leaf.spans,
                        pills: leaf.pills,
                        style: leaf.style,
                        maxWidth: wrapWidth,
                        pixelScale: scale,
                        emitGlyphs: false,
                        request: request
                    )
                    collector.map[leaf.nodeId] = TextLayoutRecord(box: box, isInput: leaf.isInput)
                } else if let existing = textSystem.cachedLayoutBox(for: leaf.shapeKey, matchingWidth: wrapWidth) {
                    collector.map[leaf.nodeId] = TextLayoutRecord(box: existing, isInput: leaf.isInput)
                } else {
                    let box = textSystem.layoutKeyed(
                        text: leaf.text,
                        spans: leaf.spans,
                        pills: leaf.pills,
                        style: leaf.style,
                        maxWidth: wrapWidth,
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

        // Taffy did not change any node, child list, or measurement. The prior solved
        // tree is a value snapshot. Text and live node records above still belong to this
        // pass. RTL mirroring and post-solve fitting can alter geometry outside Taffy.
        let canRetainGeometry = !memoSpans.isEmpty && !hasMirroredFlow && !hasAnchoredFit && aspectFitIndices.isEmpty
        if canRetainGeometry, !geometryChanged, let previous = lastMemoLayout {
            reusedMemoGeometry = true
            return previous
        }
        let result = extract()
        lastMemoLayout = canRetainGeometry ? result : nil
        return result
    }
}
