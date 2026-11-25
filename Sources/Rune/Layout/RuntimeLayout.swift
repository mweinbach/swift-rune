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
    var storePathId: RuneMotion.NodeId
    var runtimePathId: RuneMotion.NodeId
    var keyHash: UInt64
    var areas: [String: RuneTaffy.GridTemplateArea]?
    var childSX: TaffyBridge.ScrollXChild?
    var nodeFlow: Flow
    var nodeDirected: Bool
    var isRow: Bool
    var measureHash: UInt64?
    var isRedacted: Bool
    var aspectFit: Int?
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
        let intrinsicShapes = IntrinsicTextShapes()
    }

    private struct TextLeafFallback {
        var index: Int
        var nodeId: RuneMotion.NodeId
        var shapeKey: TextShapeKey
        var text: String {
            !isInput && shapeKey.spans?.isEmpty == false ? "" : shapeKey.authText
        }
        var isInput: Bool
        /// A by-paragraph field's request (`layout_text`), for a leaf no measure laid out.
        var paragraphs: ParagraphRequest? = nil
    }

    /// Flat storage for label text measurement avoiding a per-leaf heap closure allocation.
    private struct LabelMeasure: @unchecked Sendable {
        var resolved: ElResolvedText
        var labelKey: TextShapeKey?
        var byLineReq: ParagraphRequest?
        var isClampedOrEllipsis: Bool
        var widthIndependent: Bool
    }

    // Supply the current pass's collector and node identity to transferred input measures.
    private typealias Measure = (Float?, Bool, TextLayoutCollector?, RuneMotion.NodeId) -> Vec2
    private enum MeasureBox: @unchecked Sendable {
        case label(Int32)
        case fixed(Vec2)
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
        var labelMeasures: Range<Int>
        var nestedStart: Int
    }

    /// The solver may move a memo root while every descendant keeps its local layout.
    /// Keep the solved child buffer intact for the flatten pass in that case.
    private final class MemoGeometry {
        let descendants: ArraySlice<RetainedLayoutKey>
        init(descendants: ArraySlice<RetainedLayoutKey>) { self.descendants = descendants }

        var rootBox = RuneTaffy.Layout.zero
        var descendantBoxes: [RuneTaffy.Layout] = []
        var result: LayoutEngine.ResultNode?
    }

    /// A virtual row builder returned this exact immutable root. Retain its slot as well
    /// as its children only while its path, inherited style and flow context still match.
    private final class VirtualRowRoot {
        weak var source: AnyObject?
        let key: String
        let parent: SyncPrepared

        init(_ source: AnyObject, key: String, parent: SyncPrepared) {
            self.source = source
            self.key = key
            self.parent = parent
        }

        func matches(_ row: AnyObject, key: String, parent current: SyncPrepared) -> Bool {
            source === row && self.key.utf8.elementsEqual(key.utf8) && parent.storePathId == current.storePathId &&
                parent.runtimePathId == current.runtimePathId && parent.nodeFlow == current.nodeFlow &&
                parent.nodeDirected == current.nodeDirected && parent.isRow == current.isRow &&
                parent.childSX == current.childSX && parent.areas == current.areas
        }
    }

    private final class MemoSpan {
        let record: MemoRecord
        var root: SyncPrepared { record.root }
        let nodes: ArraySlice<PreparedNode>
        let childOffsets: ArraySlice<Int>
        let childOffsetBase: Int32
        let slotKeys: ArraySlice<RetainedLayoutKey>
        let leaves: ArraySlice<TextLeafFallback>
        let overflow: ArraySlice<OverflowLeaf>
        let labelMeasures: ArraySlice<LabelMeasure>
        let nested: ArraySlice<MemoRecord>
        let isGroupRoot: Bool
        let geometry: MemoGeometry?
        var virtualRoot: VirtualRowRoot?

        init(record: MemoRecord, nodes: ArraySlice<PreparedNode>, childOffsets: ArraySlice<Int>,
             childOffsetBase: Int32, slotKeys: ArraySlice<RetainedLayoutKey>,
             leaves: ArraySlice<TextLeafFallback>, overflow: ArraySlice<OverflowLeaf>,
             labelMeasures: ArraySlice<LabelMeasure>, nested: ArraySlice<MemoRecord>,
             isGroupRoot: Bool, geometry: MemoGeometry?) {
            self.record = record
            self.nodes = nodes
            self.childOffsets = childOffsets
            self.childOffsetBase = childOffsetBase
            self.slotKeys = slotKeys
            self.leaves = leaves
            self.overflow = overflow
            self.labelMeasures = labelMeasures
            self.nested = nested
            self.isGroupRoot = isGroupRoot
            self.geometry = geometry
        }

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
        let firstLabelMeasure: Int
        let firstRecord: Int
        let virtualRoot: VirtualRowRoot?
    }

    private struct SyncVisit<State> {
        let prepared: SyncPrepared
        let childMark: Int
        let childOffsetMark: Int
        let children: [El<State>]
        let virtualRows: [String: Runtime<State>.CachedVirtualRow]?
        var childKeys: [String: Int] = [:]
        var childCountSoFar: Int = 0
        var childrenDirty = false
        let memo: MemoMark?
    }

    private enum SyncStep<State> {
        case visit(SyncVisit<State>)
        case finished(SyncResult)
    }

    /// Preorder edges are relative to this node, so sibling insertions preserve an entire memo slice.
    private struct PreparedNode: Sendable {
        var segmentKey: String?
        var segmentIndexOrDup: Int32
        var storeKey: UInt64
        var runtimeId: RuneMotion.NodeId
        var screenIdentity: Bool
        var parentOffset: Int?
        var slot: SlotId = SlotId()
        var contentStyle: TaffyBridge.ContentExtent.Child
        var measure: MeasureBox?
        var childOffsetStart: Int32 = 0
        var childOffsetCount: Int32 = 0
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
    private(set) var reusedVirtualRowRootCount = 0
    private var lastViewport: Vec2 = Vec2(-1, -1)
    private var lastFitHeight: Bool = false

    // Reusable scratch buffers across commits (trimmed on sparse shrink so swap memory stays tight).
    private var spareFlat: [PreparedNode] = []
    private var spareFlatChildOffsets: [Int] = []
    private var spareVisitChildOffsets: [Int] = []
    private var sparePendingStyles: [RuneTaffy.TaffyStyle] = []
    private var spareLabelMeasures: [LabelMeasure] = []
    private var spareNonSecretLeaves: [TextLeafFallback] = []
    private var spareOverflowLeaves: [OverflowLeaf] = []
    private var spareMemoRecords: [MemoRecord] = []
    private var spareGeometryRuns: [(range: Range<Int>, cache: MemoGeometry)] = []
    private var spareSolved: [(RuneTaffy.Layout, LayoutEngine.ResultNode)] = []

    var storageStats: RuneTaffy.StorageStats {
        store.storageStats()
    }

    @inline(__always)
    private static func resetSpare<T>(_ array: inout [T], highWater: Int) {
        let keep = array.capacity <= max(128, highWater * 4)
        array.removeAll(keepingCapacity: keep)
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
        virtualRows: [String: [String: Runtime<State>.CachedVirtualRow]] = [:],
        onLiveIdsReady: ((Set<RuneMotion.NodeId>) -> Void)? = nil
    ) -> LayoutEngine.ResultNode {
        var flat: [PreparedNode] = []
        var flatChildOffsets: [Int] = []
        var visitChildOffsetScratch: [Int] = []
        var pendingStyles: [RuneTaffy.TaffyStyle] = []
        var labelMeasures: [LabelMeasure] = []
        var nonSecretLeaves: [TextLeafFallback] = []
        var overflowLeaves: [OverflowLeaf] = []
        var memoRecords: [MemoRecord] = []
        var geometryRuns: [(range: Range<Int>, cache: MemoGeometry)] = []
        var solved: [(RuneTaffy.Layout, LayoutEngine.ResultNode)] = []

        swap(&flat, &spareFlat)
        swap(&flatChildOffsets, &spareFlatChildOffsets)
        swap(&visitChildOffsetScratch, &spareVisitChildOffsets)
        swap(&pendingStyles, &sparePendingStyles)
        swap(&labelMeasures, &spareLabelMeasures)
        swap(&nonSecretLeaves, &spareNonSecretLeaves)
        swap(&overflowLeaves, &spareOverflowLeaves)
        swap(&memoRecords, &spareMemoRecords)
        swap(&geometryRuns, &spareGeometryRuns)
        swap(&solved, &spareSolved)

        defer {
            let flatCount = flat.count
            let childCount = flatChildOffsets.count
            let labelCount = labelMeasures.count
            let leafCount = nonSecretLeaves.count
            let ovCount = overflowLeaves.count
            Self.resetSpare(&flat, highWater: flatCount)
            Self.resetSpare(&flatChildOffsets, highWater: childCount)
            Self.resetSpare(&visitChildOffsetScratch, highWater: 64)
            Self.resetSpare(&pendingStyles, highWater: 64)
            Self.resetSpare(&labelMeasures, highWater: labelCount)
            Self.resetSpare(&nonSecretLeaves, highWater: leafCount)
            Self.resetSpare(&overflowLeaves, highWater: ovCount)
            Self.resetSpare(&memoRecords, highWater: 32)
            Self.resetSpare(&geometryRuns, highWater: 32)
            Self.resetSpare(&solved, highWater: 64)
            swap(&flat, &spareFlat)
            swap(&flatChildOffsets, &spareFlatChildOffsets)
            swap(&visitChildOffsetScratch, &spareVisitChildOffsets)
            swap(&pendingStyles, &sparePendingStyles)
            swap(&labelMeasures, &spareLabelMeasures)
            swap(&nonSecretLeaves, &spareNonSecretLeaves)
            swap(&overflowLeaves, &spareOverflowLeaves)
            swap(&memoRecords, &spareMemoRecords)
            swap(&geometryRuns, &spareGeometryRuns)
            swap(&solved, &spareSolved)
        }

        let liveHint = max(32, store.liveCount)
        if flat.capacity < liveHint { flat.reserveCapacity(liveHint) }
        if flatChildOffsets.capacity < liveHint { flatChildOffsets.reserveCapacity(liveHint) }
        var aspectFits: [(ratio: Float, raw: RuneTaffy.TaffyStyle)] = []
        var aspectFitOrder: [(index: Int, fit: Int)] = []
        var anchorStyles: [Int: RuneTaffy.TaffyStyle] = [:]
        let fEpoch = textSystem.currentFontEpoch
        let langTag = textSystem.language
        let storeRootPath = "/0"
        let keyedRootPath = rootEl.storageKeyId.map { "/@\($0)" }

        let storeRootId = RuneMotion.NodeId.hash(storeRootPath)
        let runtimeRootId = keyedRootPath.map(RuneMotion.NodeId.hash) ?? storeRootId

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
        if !memoSpans.isEmpty { nextMemoSpans.reserveCapacity(memoSpans.count) }
        var recordingMemo = false
        reusedMemoNodeCount = 0
        reusedVirtualRowRootCount = 0
        reusedMemoGeometry = false
        var geometryChanged = false
        var hasMirroredFlow = false

        /// Reconstructs the runtime path string on demand (only for containers with `virtualEstimate` when `virtualRows` is non-empty).
        func runtimePathString(for index: Int) -> String {
            var chain: [Int] = []
            var cur = index
            while let offset = flat[cur].parentOffset {
                chain.append(cur)
                cur += offset
            }
            var result = keyedRootPath ?? storeRootPath
            for nodeIdx in chain.reversed() {
                let n = flat[nodeIdx]
                result.append("/")
                if let key = n.segmentKey {
                    result.append("@")
                    result.append(key)
                    if n.segmentIndexOrDup > 0 {
                        result.append("#dup")
                        result.append(String(n.segmentIndexOrDup))
                    }
                } else {
                    result.append(String(n.segmentIndexOrDup))
                }
            }
            return result
        }

        func hashTextGeometry(_ hasher: inout Hasher, key: TextShapeKey?, text: String,
                              spans: [TextSpan]?, pills: [PillChip], style: TextStyle) {
            if let key {
                // The mounted leaf already fingerprinted its UTF-8 text and metric attributes.
                hasher.combine(key)
            } else {
                var content = text
                content.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
                hasher.combine(TextSpan.layoutSpans(spans))
                hasher.combine(pills)
                hasher.combine(style)
                hasher.combine(scale)
                if style.fontSmoothing == .systemDefault { hasher.combine(textSystem.smoothing) }
            }
        }

        func makeMeasure(el: borrowing El<State>, nodeId: RuneMotion.NodeId, flatIndex: Int, forcedTextFlow: TextFlow?) -> (box: MeasureBox?, hash: UInt64?, redacted: Bool) {
            guard el.children.isEmpty else { return (nil, nil, false) }
            if el.hasEditLens, let editLens = el.handlers.editLens {
                let rawEdit = editLens.get(state)
                let resolved = ElDisplayResolver.resolveInput(
                    el: el,
                    edit: rawEdit,
                    fallbackDirection: forcedTextFlow
                )
                let measureStr = resolved.renderedString.isEmpty ? " " : resolved.renderedString
                // A wrapped field of more than one paragraph lays out by paragraph (`layout_text`).
                let paragraphs = Runtime<State>.paragraphRequest(field: nodeId, el: el, edit: rawEdit, resolved: resolved)
                let fieldKey: TextShapeKey?
                if !resolved.isSecure, textLayouts != nil {
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
                        isInput: true,
                        paragraphs: paragraphs
                    ))
                    fieldKey = sKey
                } else {
                    fieldKey = nil
                }
                var hasher = Hasher()
                hasher.combine(1)
                if !resolved.isSecure {
                    hashTextGeometry(&hasher, key: fieldKey, text: measureStr, spans: resolved.spans,
                                     pills: resolved.pills, style: resolved.style)
                }
                hasher.combine(resolved.isSingleLine)
                hasher.combine(rawEdit.multiline)
                let h = UInt64(bitPattern: Int64(hasher.finalize()))
                let keep: TextKeep = resolved.isSecure ? .secret : .cached
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
                        request: paragraphs, forMeasurement: true
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
                return (.content(fn), resolved.isSecure ? 0 : h, resolved.isSecure)
            } else if el.richSpans != nil || el.liveText != nil || el.plainText != nil || el.advanceInRun != nil {
                let rawTxt = el.liveText?.get() ?? el.plainText
                let resolved = ElDisplayResolver.resolveText(
                    el: el,
                    rawText: rawTxt,
                    isSecure: el.isSecure,
                    fallbackDirection: forcedTextFlow
                )
                // A label may supply both fallback text and the spans actually being measured.
                let shapeText: String
                if !resolved.isSecure, rawTxt != nil, let spans = resolved.spans {
                    shapeText = spans.map(\.text).joined()
                } else {
                    shapeText = resolved.displayedText
                }
                let isClampedOrEllipsis = resolved.style.maxLines > 0 || resolved.style.wrap == .ellipsis
                if textLayouts != nil, !resolved.isSecure, resolved.advanceRun == nil,
                   !shapeText.isEmpty, resolved.truncateFade || isClampedOrEllipsis {
                    overflowLeaves.append((flatIndex, nodeId, resolved))
                }
                let labelKey: TextShapeKey?
                if !resolved.isSecure, !shapeText.isEmpty, !resolved.truncateFade, resolved.advanceRun == nil, !isClampedOrEllipsis, textLayouts != nil {
                    let sKey = TextShapeKey(
                        authText: shapeText,
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
                        isInput: false
                    ))
                    labelKey = sKey
                } else {
                    labelKey = nil
                }
                var hasher = Hasher()
                hasher.combine(3)
                if !resolved.isSecure {
                    hashTextGeometry(&hasher, key: labelKey, text: shapeText, spans: resolved.spans,
                                     pills: resolved.pills, style: resolved.style)
                    if let adv = resolved.advanceRun {
                        hasher.combine(adv.run)
                        hasher.combine(adv.byteOffset)
                    }
                }
                hasher.combine(el.isRevealed)
                hasher.combine(el.isByLine)
                hasher.combine(resolved.truncateFade)
                hasher.combine(resolved.pretty)
                let h = UInt64(bitPattern: Int64(hasher.finalize()))
                let widthIndependent = labelKey != nil && resolved.style.wrap == .noWrap
                let byLineReq = el.isByLine ? Runtime<State>.staticByLineParagraphRequest(
                    nodeId: nodeId, el: el, style: resolved.style, spans: resolved.spans, pills: resolved.pills
                ) : nil
                let labelIdx = Int32(labelMeasures.count)
                labelMeasures.append(LabelMeasure(
                    resolved: resolved,
                    labelKey: labelKey,
                    byLineReq: byLineReq,
                    isClampedOrEllipsis: isClampedOrEllipsis,
                    widthIndependent: widthIndependent
                ))
                return (.label(labelIdx), resolved.isSecure ? 0 : h, resolved.isSecure)
            } else if let (_, iconSize) = el.iconPayload {
                var hasher = Hasher()
                hasher.combine(4)
                hasher.combine(iconSize)
                let h = UInt64(bitPattern: Int64(hasher.finalize()))
                return (.fixed(Vec2(iconSize, iconSize)), h, false)
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
                return (.fixed(Vec2(w, rowH)), h, false)
            }
            return (nil, nil, false)
        }

        /// Prepare one node before visiting its children. Large style and measure temporaries
        /// stay outside the traversal loop's stack frame.
        @inline(never)
        func syncPrepare(
            _ el: borrowing El<State>,
            parent: SyncPrepared?,
            siblingIndex: Int,
            siblingCount: Int,
            siblingKeysSeen: inout [String: Int]
        ) -> SyncPrepared {
            let pin: DirPin = (el.isUnmirrored || el.anchor != nil) ? .physical : .flowing
            let effectiveParentFlow: Flow = el.isUnmirrored ? .ltr : (parent?.nodeFlow ?? .ltr)
            let (nodeFlow, _) = stepDirection(parent: effectiveParentFlow, el: el, state: state)
            if nodeFlow == .rtl { hasMirroredFlow = true }
            let nodeDirected = (el.explicitDir != nil) || el.isUnmirrored || (parent?.nodeDirected == true)
            let forcedTextFlow: TextFlow? = (nodeDirected && !el.textDirByParagraph) ? nodeFlow.textFlow : nil
            let rawKey = el.storageKeyId
            let dupCount: Int
            if let rawK = rawKey {
                if siblingCount > 1 {
                    let count = siblingKeysSeen[rawK, default: 0]
                    siblingKeysSeen[rawK] = count + 1
                    dupCount = count
                } else {
                    dupCount = 0
                }
            } else {
                dupCount = 0
            }
            let storePathId: RuneMotion.NodeId
            if let parent {
                storePathId = rawKey.map { parent.storePathId.child(key: $0, dup: dupCount) }
                    ?? parent.storePathId.child(index: siblingIndex)
            } else {
                storePathId = storeRootId
            }
            let runtimePathId: RuneMotion.NodeId
            if keyedRootPath == nil {
                runtimePathId = storePathId
            } else if let parent {
                runtimePathId = rawKey.map { parent.runtimePathId.child(key: $0, dup: dupCount) }
                    ?? parent.runtimePathId.child(index: siblingIndex)
            } else {
                runtimePathId = runtimeRootId
            }
            // Screen travel overrides this node's identity only. Children still derive
            // their stable IDs from the authored parent path.
            let screenId: RuneMotion.NodeId? = el.layoutAnim?.travel == .screen
                ? rawKey.map { RuneMotion.NodeId.screenKey($0, dup: dupCount) }
                : nil
            let keyHash = (screenId ?? storePathId).rawValue
            let runtimeNodeId = screenId ?? runtimePathId
            if let collector = textLayouts {
                collector.liveIds.insert(runtimeNodeId)
            }

            var style = el.layout
            if parent == nil {
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
            let forceRow = style.forcesHorizontalFlexRow(childCount: el.children.count)
            let childSX: TaffyBridge.ScrollXChild?
            if hasScrollX {
                let v = style.scrollAxes.contains(.vertical)
                childSX = (el.children.count == 1) ? .single(vertical: v) : .many(vertical: v)
            } else {
                childSX = nil
            }

            let rawTaffy = TaffyBridge.toTaffyStyle(
                style,
                parentAreas: parent?.areas,
                borderOverride: borderOverride,
                scrollXChild: parent?.childSX,
                forceScrollXRow: forceRow
            )
            let ratio = style.aspectFit.flatMap { ($0.isFinite && $0 > 0) ? $0 : nil }
            let effectiveTaffy = ratio != nil
                ? TaffyBridge.fitRoomStyle(raw: rawTaffy, parentRow: parent?.isRow == true)
                : rawTaffy

            let myIndex = flat.count
            pendingStyles.append(effectiveTaffy)
            if el.anchor?.fit == true { anchorStyles[myIndex] = effectiveTaffy }
            flat.append(PreparedNode(
                segmentKey: rawKey,
                segmentIndexOrDup: rawKey != nil ? Int32(dupCount) : Int32(siblingIndex),
                storeKey: keyHash,
                runtimeId: runtimeNodeId,
                screenIdentity: screenId != nil,
                parentOffset: parent.map { $0.myIndex - myIndex },
                contentStyle: TaffyBridge.ContentExtent.Child(effectiveTaffy),
                measure: nil,
                flow: nodeFlow,
                pin: pin
            ))

            let fit = ratio.map { ratio in
                aspectFits.append((ratio, rawTaffy))
                return aspectFits.count - 1
            }

            let measurement: (box: MeasureBox?, hash: UInt64?, redacted: Bool)
            if nodeDirected && el.textDirByParagraph && el.hasEditLens {
                // A `dirByParagraph` field's paragraphs start from the element's flow (`TextDir::Plaintext`).
                var measured = copy el
                measured.textStyle.byParagraphStart = nodeFlow.textFlow
                measurement = makeMeasure(el: measured, nodeId: runtimeNodeId, flatIndex: myIndex, forcedTextFlow: forcedTextFlow)
            } else {
                measurement = makeMeasure(el: el, nodeId: runtimeNodeId, flatIndex: myIndex, forcedTextFlow: forcedTextFlow)
            }
            let (measureBox, measureHash, isRedacted) = measurement
            flat[myIndex].measure = measureBox ?? pictureRatioToMeasure.map(MeasureBox.picture)

            return SyncPrepared(
                myIndex: myIndex,
                storePathId: storePathId,
                runtimePathId: runtimePathId,
                keyHash: keyHash,
                areas: areas,
                childSX: childSX,
                nodeFlow: nodeFlow,
                nodeDirected: nodeDirected,
                isRow: effectiveTaffy.flexDirection.isRow,
                measureHash: measureHash ?? pictureRatioToMeasure.map { 0x7069_6300_0000_0000 | UInt64($0.bitPattern) },
                isRedacted: isRedacted,
                aspectFit: fit
            )
        }

        @inline(never)
        func syncFinish(_ p: SyncPrepared, childMark: Int, childrenDirty: Bool) -> (slot: SlotId, dirty: Bool) {
            let (slot, dirty) = store.syncNode(
                key: p.keyHash,
                nodeIndex: UInt32(p.myIndex),
                style: pendingStyles.removeLast(),
                measure: p.measureHash,
                forceMeasureDirty: p.isRedacted,
                childMark: childMark,
                childrenDirty: childrenDirty
            )
            if dirty { geometryChanged = true }
            flat[p.myIndex].slot = slot
            if let fit = p.aspectFit { aspectFitOrder.append((p.myIndex, fit)) }
            return (slot, dirty)
        }

        /// Claim the old subtree atomically, including destination paths before any rekey.
        /// General memos prepare root modifiers again. A retained virtual row can also claim its root.
        @inline(never)
        func reuseChildren(
            _ span: MemoSpan,
            _ p: SyncPrepared,
            syncingRoot: Bool = true
        ) -> (reused: Bool, rebasedStore: [RuneMotion.NodeId], rebasedRuntime: [RuneMotion.NodeId]) {
            guard span.hasSameChildContext(p),
                  store.canReuse(span.slotKeys)
            else { return (false, [], []) }
            let oldStart = span.root.myIndex
            let shift = p.myIndex - oldStart
            let moved = span.root.storePathId != p.storePathId
            let changedIds = moved || span.root.runtimePathId != p.runtimePathId

            var rebasedStore: [RuneMotion.NodeId] = []
            var rebasedRuntime: [RuneMotion.NodeId] = []
            if changedIds {
                let count = span.nodes.count
                rebasedStore.reserveCapacity(count)
                rebasedRuntime.reserveCapacity(count)
                rebasedStore.append(p.storePathId)
                rebasedRuntime.append(p.runtimePathId)
                let base = span.nodes.startIndex
                for offset in 1..<count {
                    let node = span.nodes[base + offset]
                    let parentLocal = offset + node.parentOffset!
                    let sId: RuneMotion.NodeId
                    if let key = node.segmentKey {
                        sId = rebasedStore[parentLocal].child(key: key, dup: Int(node.segmentIndexOrDup))
                    } else {
                        sId = rebasedStore[parentLocal].child(index: Int(node.segmentIndexOrDup))
                    }
                    let rId: RuneMotion.NodeId
                    if keyedRootPath == nil {
                        rId = sId
                    } else if let key = node.segmentKey {
                        rId = rebasedRuntime[parentLocal].child(key: key, dup: Int(node.segmentIndexOrDup))
                    } else {
                        rId = rebasedRuntime[parentLocal].child(index: Int(node.segmentIndexOrDup))
                    }
                    rebasedStore.append(sId)
                    rebasedRuntime.append(rId)
                }
            }

            if moved {
                var slots: [(UInt64, UInt64, SlotId, UInt32)] = []
                slots.reserveCapacity(span.nodes.count)
                let base = span.nodes.startIndex
                for offset in 0..<span.nodes.count {
                    let node = span.nodes[base + offset]
                    let key: UInt64
                    if offset == 0 {
                        key = p.keyHash
                    } else {
                        key = node.screenIdentity ? node.storeKey : rebasedStore[offset].rawValue
                    }
                    guard !store.isUsedThisCommit(key: key) else { return (false, [], []) }
                    slots.append((node.storeKey, key, node.slot, UInt32(p.myIndex + offset)))
                }
                store.rekeyAndReuseBatch(slots)
            } else {
                store.reuseSlots(span.slotKeys.dropFirst(), startingAt: UInt32(p.myIndex + 1))
            }

            let dstChildBase = Int32(flatChildOffsets.count) - span.childOffsetBase
            if !span.childOffsets.isEmpty {
                flatChildOffsets.append(contentsOf: span.childOffsets)
            }
            let labelShift = Int32(labelMeasures.count - span.labelMeasures.startIndex)
            if !span.labelMeasures.isEmpty {
                labelMeasures.append(contentsOf: span.labelMeasures)
            }

            let oldRoot = span.nodes.first!
            flat[p.myIndex].childOffsetStart = oldRoot.childOffsetStart + dstChildBase
            flat[p.myIndex].childOffsetCount = oldRoot.childOffsetCount

            let base = span.nodes.startIndex
            let nodeCount = span.nodes.count
            for offset in 1..<nodeCount {
                var node = span.nodes[base + offset]
                if node.childOffsetCount > 0 {
                    node.childOffsetStart += dstChildBase
                }
                if case .label(let lIdx) = node.measure {
                    node.measure = .label(lIdx + labelShift)
                }
                if moved && !node.screenIdentity {
                    node.storeKey = rebasedStore[offset].rawValue
                }
                if changedIds && !node.screenIdentity {
                    node.runtimeId = rebasedRuntime[offset]
                }
                if node.flow == .rtl { hasMirroredFlow = true }
                textLayouts?.liveIds.insert(node.runtimeId)
                flat.append(node)
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
            if syncingRoot {
                let cStart = Int(flat[p.myIndex].childOffsetStart)
                let cEnd = cStart + Int(flat[p.myIndex].childOffsetCount)
                for idx in cStart..<cEnd {
                    store.pushChild(flat[p.myIndex + flatChildOffsets[idx]].slot)
                }
            }
            reusedMemoNodeCount += nodeCount - 1
            return (true, rebasedStore, rebasedRuntime)
        }

        @inline(never)
        func installMemoGroup() {
            let group = memoRecords.last!
            let records = memoRecords
            memoRecords.removeAll(keepingCapacity: true)
            var nodes = Array(flat[group.nodes])
            // Screen-space travel keys can alias a slot even in distinct sibling branches.
            var seenSlots = Set<SlotId>()
            seenSlots.reserveCapacity(nodes.count)
            for n in nodes {
                if !seenSlots.insert(n.slot).inserted { return }
            }
            var groupChildOffsets: [Int] = []
            for i in nodes.indices {
                let cStart = Int(nodes[i].childOffsetStart)
                let cCount = Int(nodes[i].childOffsetCount)
                nodes[i].childOffsetStart = Int32(groupChildOffsets.count)
                if cCount > 0 {
                    groupChildOffsets.append(contentsOf: flatChildOffsets[cStart..<(cStart + cCount)])
                }
            }
            let labelBase = Int32(group.labelMeasures.lowerBound)
            if labelBase != 0 {
                for i in nodes.indices {
                    if case .label(let idx) = nodes[i].measure {
                        nodes[i].measure = .label(idx - labelBase)
                    }
                }
            }
            let slotKeys = nodes.map { RetainedLayoutKey(key: $0.storeKey, slot: $0.slot) }
            let leaves = Array(nonSecretLeaves[group.leaves])
            let overflow = Array(overflowLeaves[group.overflow])
            let groupLabels = Array(labelMeasures[group.labelMeasures])
            func local(_ range: Range<Int>, _ start: Int) -> Range<Int> {
                (range.lowerBound - start)..<(range.upperBound - start)
            }
            for (index, record) in records.enumerated() {
                guard let id = record.identity else { continue }
                let localNodes = local(record.nodes, group.nodes.lowerBound)
                let keys = slotKeys[localNodes]
                let coStart = localNodes.isEmpty ? 0 : Int(nodes[localNodes.lowerBound].childOffsetStart)
                let coEnd = localNodes.isEmpty ? 0 : Int(nodes[localNodes.upperBound - 1].childOffsetStart) + Int(nodes[localNodes.upperBound - 1].childOffsetCount)
                nextMemoSpans[ObjectIdentifier(id)] = MemoSpan(
                    record: record, nodes: nodes[localNodes],
                    childOffsets: groupChildOffsets[coStart..<coEnd],
                    childOffsetBase: Int32(coStart),
                    slotKeys: keys,
                    leaves: leaves[local(record.leaves, group.leaves.lowerBound)],
                    overflow: overflow[local(record.overflow, group.overflow.lowerBound)],
                    labelMeasures: groupLabels[local(record.labelMeasures, group.labelMeasures.lowerBound)],
                    nested: records[record.nestedStart..<index], isGroupRoot: index == records.count - 1,
                    geometry: index == records.count - 1 ? MemoGeometry(descendants: keys.dropFirst()) : nil
                )
            }
        }

        @inline(never)
        func moveNestedRecords(
            _ span: MemoSpan,
            _ p: SyncPrepared,
            firstLeaf: Int,
            firstOverflow: Int,
            firstLabelMeasure: Int,
            rebasedStore: [RuneMotion.NodeId],
            rebasedRuntime: [RuneMotion.NodeId]
        ) {
            let shift = p.myIndex - span.root.myIndex
            let recordShift = memoRecords.count - span.nested.startIndex
            let leafShift = firstLeaf - span.record.leaves.lowerBound
            let overflowShift = firstOverflow - span.record.overflow.lowerBound
            let labelShift = firstLabelMeasure - span.record.labelMeasures.lowerBound
            func moved(_ range: Range<Int>, _ by: Int) -> Range<Int> {
                (range.lowerBound + by)..<(range.upperBound + by)
            }
            for var record in span.nested {
                let localOffset = record.root.myIndex - span.root.myIndex
                record.nodes = moved(record.nodes, shift)
                record.root.myIndex += shift
                let node = flat[record.root.myIndex]
                record.root.keyHash = node.storeKey
                if !rebasedStore.isEmpty {
                    record.root.storePathId = rebasedStore[localOffset]
                    record.root.runtimePathId = rebasedRuntime[localOffset]
                } else if !node.screenIdentity {
                    record.root.storePathId = RuneMotion.NodeId(node.storeKey)
                    record.root.runtimePathId = node.runtimeId
                }
                record.leaves = moved(record.leaves, leafShift)
                record.overflow = moved(record.overflow, overflowShift)
                record.labelMeasures = moved(record.labelMeasures, labelShift)
                record.nestedStart += recordShift
                memoRecords.append(record)
            }
        }

        func forwardGroup(_ span: MemoSpan, _ key: ObjectIdentifier) {
            nextMemoSpans[key] = span
            for inner in span.nested {
                if let id = inner.identity {
                    let nestedKey = ObjectIdentifier(id)
                    nextMemoSpans[nestedKey] = memoSpans[nestedKey]
                }
            }
        }

        @inline(never)
        func beginVisit(
            _ el: borrowing El<State>,
            parent: SyncPrepared?,
            siblingIndex: Int,
            siblingCount: Int,
            siblingKeysSeen: inout [String: Int],
            sourceRows: [String: Runtime<State>.CachedVirtualRow]? = nil
        ) -> SyncStep<State> {
            var virtualRoot: VirtualRowRoot?
            if let sourceRows, !el.children.isEmpty, let key = el.storageKeyId, let row = sourceRows[key],
               let authored = row.layoutRootMemo, !recordingMemo, let parent, siblingKeysSeen[key] == nil,
               let current = el.memoLayoutChildren, (current === authored || current === row.layoutProjection?.children),
               current.matches(el.children) {
                let memo = row.layoutProjection?.children ?? authored
                let memoKey = ObjectIdentifier(memo)
                if let span = memoSpans[memoKey], span.isGroupRoot, span.record.identity === memo,
                   span.virtualRoot?.matches(row.layoutProjection?.owner ?? row.rootIdentity, key: key, parent: parent) == true, var node = span.nodes.first {
                    let index = flat.count
                    node.parentOffset = parent.myIndex - index
                    flat.append(node)
                    var prepared = span.root
                    prepared.myIndex = index
                    let reused = reuseChildren(span, prepared, syncingRoot: false)
                    if reused.reused {
                        store.reuseSlot(node.slot, nodeIndex: UInt32(index))
                        textLayouts?.liveIds.insert(node.runtimeId)
                        if node.flow == .rtl { hasMirroredFlow = true }
                        if siblingCount > 1 { siblingKeysSeen[key] = 1 }
                        forwardGroup(span, memoKey)
                        if let geometry = span.geometry { geometryRuns.append((index..<flat.count, geometry)) }
                        reusedVirtualRowRootCount += 1
                        return .finished((index, node.slot, false))
                    }
                    flat.removeLast()
                }
                if current !== memo {
                    // The counterpart has identical intrinsic geometry. Materialize its child tree only
                    // when its prepared slot span is missing. Input and paint use the authored row.
                    var projected = copy el
                    projected.children = memo.children
                    projected.memoLayoutChildren = memo
                    return beginVisit(projected, parent: parent, siblingIndex: siblingIndex,
                                      siblingCount: siblingCount, siblingKeysSeen: &siblingKeysSeen,
                                      sourceRows: sourceRows)
                }
                virtualRoot = VirtualRowRoot(row.layoutProjection?.owner ?? row.rootIdentity, key: key, parent: parent)
            }
            let p = syncPrepare(el, parent: parent, siblingIndex: siblingIndex,
                                siblingCount: siblingCount, siblingKeysSeen: &siblingKeysSeen)
            let myIndex = p.myIndex
            let childMark = store.beginChildren()
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
            let firstLabelMeasure = labelMeasures.count
            if let memoKey, let span = memoSpans[memoKey], span.record.identity === identity {
                let reuseResult = reuseChildren(span, p)
                if reuseResult.reused {
                    let (slot, dirty) = syncFinish(p, childMark: childMark, childrenDirty: false)
                    if !wasRecording, span.isGroupRoot, p.storePathId == span.root.storePathId,
                       p.runtimePathId == span.root.runtimePathId, span.nodes.first?.slot == slot {
                        forwardGroup(span, memoKey)
                    } else {
                        moveNestedRecords(span, p, firstLeaf: firstLeaf, firstOverflow: firstOverflow,
                                          firstLabelMeasure: firstLabelMeasure,
                                          rebasedStore: reuseResult.rebasedStore,
                                          rebasedRuntime: reuseResult.rebasedRuntime)
                        memoRecords.append(MemoRecord(identity: identity, root: p, nodes: myIndex..<flat.count,
                            leaves: firstLeaf..<nonSecretLeaves.count, overflow: firstOverflow..<overflowLeaves.count,
                            labelMeasures: firstLabelMeasure..<labelMeasures.count, nestedStart: firstRecord))
                        if !wasRecording { installMemoGroup() }
                    }
                    if !wasRecording, let current = nextMemoSpans[memoKey] {
                        current.virtualRoot = virtualRoot
                        if let geometry = current.geometry { geometryRuns.append((myIndex..<flat.count, geometry)) }
                    }
                    return .finished((myIndex, slot, dirty))
                }
            }
            var mark: MemoMark?
            if memoKey != nil, let identity {
                mark = MemoMark(identity: identity, wasRecording: wasRecording, firstLeaf: firstLeaf,
                                firstOverflow: firstOverflow, firstLabelMeasure: firstLabelMeasure,
                                firstRecord: firstRecord, virtualRoot: virtualRoot)
                recordingMemo = true
            }
            let rows: [String: Runtime<State>.CachedVirtualRow]?
            if !virtualRows.isEmpty, el.virtualEstimate != nil {
                rows = virtualRows[runtimePathString(for: myIndex)]
            } else {
                rows = nil
            }
            let visit = SyncVisit(
                prepared: p,
                childMark: childMark,
                childOffsetMark: visitChildOffsetScratch.count,
                children: el.children,
                virtualRows: rows,
                memo: mark
            )
            return .visit(visit)
        }

        @inline(never)
        func finishVisit(_ visit: SyncVisit<State>) -> SyncResult {
            let p = visit.prepared
            let offsetCount = visitChildOffsetScratch.count - visit.childOffsetMark
            let offsetStart = flatChildOffsets.count
            if offsetCount > 0 {
                flatChildOffsets.append(contentsOf: visitChildOffsetScratch[visit.childOffsetMark...])
                visitChildOffsetScratch.removeSubrange(visit.childOffsetMark...)
            }
            flat[p.myIndex].childOffsetStart = Int32(offsetStart)
            flat[p.myIndex].childOffsetCount = Int32(offsetCount)
            let (slot, dirty) = syncFinish(p, childMark: visit.childMark, childrenDirty: visit.childrenDirty)
            if let mark = visit.memo {
                recordingMemo = mark.wasRecording
                memoRecords.append(MemoRecord(identity: mark.identity, root: p, nodes: p.myIndex..<flat.count,
                    leaves: mark.firstLeaf..<nonSecretLeaves.count, overflow: mark.firstOverflow..<overflowLeaves.count,
                    labelMeasures: mark.firstLabelMeasure..<labelMeasures.count, nestedStart: mark.firstRecord))
                if !mark.wasRecording {
                    installMemoGroup()
                    if let current = nextMemoSpans[ObjectIdentifier(mark.identity)] {
                        current.virtualRoot = mark.virtualRoot
                        if let geometry = current.geometry { geometryRuns.append((p.myIndex..<flat.count, geometry)) }
                    }
                }
            }
            return (p.myIndex, slot, dirty)
        }

        // Swift Testing and app worker threads have small native stacks. Keep the pending
        // parent frames on the heap and preserve Taffy's postorder child-list synchronization.
        func syncTree() -> SyncResult {
            var rootKeys: [String: Int] = [:]
            var next = beginVisit(rootEl, parent: nil, siblingIndex: 0, siblingCount: 1, siblingKeysSeen: &rootKeys)
            var stack: [SyncVisit<State>] = []
            while true {
                switch next {
                case .visit(let visit):
                    stack.append(visit)
                case .finished(let result):
                    guard !stack.isEmpty else { return result }
                    let parent = stack.count - 1
                    let offset = result.idx - stack[parent].prepared.myIndex
                    visitChildOffsetScratch.append(offset)
                    stack[parent].childCountSoFar += 1
                    if result.dirty { stack[parent].childrenDirty = true }
                    store.pushChild(result.slot)
                }
                let parent = stack.count - 1
                let index = stack[parent].childCountSoFar
                let count = stack[parent].children.count
                if index == count {
                    next = .finished(finishVisit(stack.removeLast()))
                } else {
                    let prepared = stack[parent].prepared
                    // Hold the immutable sibling storage outside the parent's mutating key map.
                    let children = stack[parent].children
                    let rows = stack[parent].virtualRows
                    next = children.withUnsafeBufferPointer { buffer in
                        beginVisit(buffer.baseAddress!.advanced(by: index).pointee, parent: prepared,
                                   siblingIndex: index, siblingCount: count,
                                   siblingKeysSeen: &stack[parent].childKeys, sourceRows: rows)
                    }
                }
            }
        }

        var rootRes = syncTree()
        var rootSlot = rootRes.slot
        var slotsRemapped = false
        store.endCommit(root: &rootSlot) { nodeIdx, newSlot in
            slotsRemapped = true
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

        // Scope closure capture inside a helper so `flat` and `labelMeasures` drop back to
        // refcount 1 immediately after layout and can be reused without COW copies on `defer`.
        func runStoreComputeLayout() {
            let prepared = flat
            let capturedLabels = labelMeasures
            store.computeLayout(root: rootSlot, availableSpace: available, rounding: false) { input, ctx, style in
                guard let idx = ctx, idx >= 0, idx < prepared.count,
                      let box = prepared[idx].measure
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
                case .label(let labelIdx):
                    let m = capturedLabels[Int(labelIdx)]
                    let nodeId = prepared[idx].runtimeId
                    if m.widthIndependent, let labelKey = m.labelKey, let record = textLayouts?.map[nodeId],
                       !record.isInput, record.box.maxWidth == nil, record.box.shapeKey == labelKey {
                        measured = record.box.shaped.size
                    } else if m.resolved.truncateFade || m.resolved.advanceRun != nil || m.isClampedOrEllipsis {
                        var sz = m.resolved.measure(
                            using: textSystem,
                            maxWidth: TextBoxGeometry.wrapWidth(effectiveMaxW, scale: scale),
                            pixelScale: scale
                        )
                        if m.resolved.advanceRun == nil, let mw = effectiveMaxW, mw.isFinite {
                            sz.x = min(sz.x, max(0, mw))
                        }
                        measured = sz
                    } else {
                        let shapeMaxW: Float? = (m.resolved.style.wrap == .noWrap && m.resolved.style.maxLines == 0)
                            ? nil : TextBoxGeometry.wrapWidth(effectiveMaxW, scale: scale)
                        let hasSpans = (m.resolved.spans?.isEmpty == false)
                        let keep: TextKeep = m.resolved.isSecure ? .secret : .cached
                        let lBox: TextLayoutBox
                        if let byLineReq = m.byLineReq {
                            lBox = textSystem.layoutInput(
                                text: hasSpans ? "" : m.resolved.displayedText,
                                spans: m.resolved.spans,
                                pills: m.resolved.pills,
                                style: m.resolved.style,
                                maxWidth: shapeMaxW,
                                pixelScale: scale,
                                emitGlyphs: false,
                                keep: keep,
                                countAsRebreak: (textLayouts != nil) && (isRealLayout || m.widthIndependent),
                                request: byLineReq,
                                forMeasurement: true
                            )
                        } else {
                            lBox = textSystem.layoutKeyed(
                                retaining: m.labelKey,
                                intrinsicShapes: m.labelKey != nil && !m.widthIndependent ? textLayouts?.intrinsicShapes : nil,
                                text: hasSpans ? "" : m.resolved.displayedText,
                                spans: m.resolved.spans,
                                pills: m.resolved.pills,
                                style: m.resolved.style,
                                maxWidth: shapeMaxW,
                                pixelScale: scale,
                                emitGlyphs: false,
                                keep: keep,
                                countAsRebreak: (textLayouts != nil) && (isRealLayout || m.widthIndependent),
                                pretty: m.resolved.pretty, forMeasurement: true
                            )
                        }
                        if !m.resolved.isSecure, isRealLayout || m.widthIndependent, let collector = textLayouts {
                            collector.map[nodeId] = TextLayoutRecord(box: lBox, isInput: false)
                        }
                        measured = lBox.shaped.size
                    }
                case .fixed(let size):
                    measured = size
                case .content(let measure):
                    measured = measure(effectiveMaxW, isRealLayout, textLayouts, prepared[idx].runtimeId)
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
        }

        runStoreComputeLayout()

        func ancestorSlots(of index: Int) -> [SlotId] {
            var ancestors: [SlotId] = []
            var current = index
            while let offset = flat[current].parentOffset {
                current += offset
                ancestors.append(flat[current].slot)
            }
            return ancestors
        }

        if !aspectFits.isEmpty {
            for (idx, fit) in aspectFitOrder {
                let (ratio, raw) = aspectFits[fit]
                let roomLayout = store.boxLayout(flat[idx].slot)
                let fitted = TaffyBridge.fittedStyle(
                    ratio: ratio,
                    raw: raw,
                    room: RuneTaffy.Size(width: roomLayout.size.width, height: roomLayout.size.height)
                )
                if anchorStyles[idx] != nil { anchorStyles[idx] = fitted }
                store.setStyleAndMarkAncestors(flat[idx].slot, style: fitted, ancestors: ancestorSlots(of: idx))
            }
            runStoreComputeLayout()
        }

        // Flat nodes are in preorder. Walking them backwards leaves each node's solved
        // children at the top of the stack in their original painter/layout order.
        func extract(reusingMemos: Bool = false) -> LayoutEngine.ResultNode {
            solved.removeAll(keepingCapacity: true)
            var remaining = flat.count
            var memoIndex = reusingMemos ? geometryRuns.count - 1 : -1
            var capture: MemoGeometry?
            while remaining > 0 {
                if memoIndex >= 0, geometryRuns[memoIndex].range.upperBound == remaining {
                    let (range, cache) = geometryRuns[memoIndex]
                    let index = range.lowerBound
                    let box = store.layout(flat[index].slot)
                    if !slotsRemapped, var result = cache.result,
                       box.size == cache.rootBox.size, box.contentSize == cache.rootBox.contentSize,
                       box.padding == cache.rootBox.padding, box.border == cache.rootBox.border,
                       store.geometryMatches(cache.descendants, reversedBoxes: cache.descendantBoxes) {
                        result.layout.localRect = MotionRect.fromXYWH(box.location.x, box.location.y,
                                                                     box.size.width, box.size.height)
                        solved.append((box, result))
                        remaining = index
                        memoIndex -= 1
                        continue
                    }
                    cache.rootBox = box
                    cache.descendantBoxes.removeAll(keepingCapacity: true)
                    cache.descendantBoxes.reserveCapacity(range.count - 1)
                    capture = cache
                }
                remaining -= 1
                let index = remaining
                let node = flat[index]
                let box = store.layout(node.slot)
                var content = TaffyBridge.ContentExtent(box)
                let cStart = Int(node.childOffsetStart)
                let cCount = Int(node.childOffsetCount)
                var children: [LayoutEngine.ResultNode] = []
                if cCount > 0 {
                    children.reserveCapacity(cCount)
                    for i in cStart..<(cStart + cCount) {
                        let offset = flatChildOffsets[i]
                        let child = flat[index + offset]
                        let (childBox, result) = solved.removeLast()
                        var placed = result
                        if node.flow == .rtl && child.pin == .flowing {
                            let rect = placed.layout.localRect
                            placed.layout.localRect = MotionRect.fromXYWH(
                                box.size.width - rect.x - rect.width, rect.y, rect.width, rect.height
                            )
                        }
                        children.append(placed)
                        content.include(childBox, style: child.contentStyle, content: placed.layout.contentSize)
                    }
                }
                let layout = ComputedLayout(
                    localRect: MotionRect.fromXYWH(box.location.x, box.location.y, box.size.width, box.size.height),
                    localSize: Vec2(box.size.width, box.size.height), contentSize: content.size
                )
                let result = LayoutEngine.ResultNode(layout: layout, children: children)
                if let cache = capture {
                    if index == geometryRuns[memoIndex].range.lowerBound {
                        cache.result = result
                        memoIndex -= 1
                        capture = nil
                    } else {
                        cache.descendantBoxes.append(box)
                    }
                }
                solved.append((box, result))
            }
            return solved.removeLast().1
        }

        if !anchorStyles.isEmpty {
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
                        guard let cur = targetIdx, c >= 0, c < Int(flat[cur].childOffsetCount) else {
                            targetIdx = nil
                            break
                        }
                        targetIdx = cur + flatChildOffsets[Int(flat[cur].childOffsetStart) + c]
                    }
                    guard let idx = targetIdx, var style = anchorStyles[idx] else { continue }
                    let dim: RuneTaffy.Dimension = .length(max(0, bound))
                    if vertical {
                        style.maxSize.height = dim
                    } else {
                        style.maxSize.width = dim
                    }
                    store.setStyleAndMarkAncestors(flat[idx].slot, style: style, ancestors: ancestorSlots(of: idx))
                }
                runStoreComputeLayout()
            }
        }

        if let collector = textLayouts {
            for leaf in overflowLeaves {
                let bounds = store.layout(flat[leaf.index].slot)
                let width = max(0, bounds.contentBoxSize().width - bounds.scrollbarSize.width)
                if let box = textSystem.preparedOverflowLayout(
                    leaf.text, width: TextBoxGeometry.wrapWidth(width, scale: scale), scale: scale,
                    create: textSystem.isPreparingLayouts, forMeasurement: true
                ) {
                    collector.map[leaf.id] = TextLayoutRecord(box: box, isInput: false)
                }
            }
            for leaf in nonSecretLeaves {
                if let record = collector.map[leaf.nodeId] {
                    // An earlier probe may already have supplied this break with another palette.
                    if record.box.spans != leaf.shapeKey.spans, record.box.shapeKey == leaf.shapeKey {
                        collector.map[leaf.nodeId]?.box = textSystem.presentedLayout(record.box, spans: leaf.shapeKey.spans, forMeasurement: true)
                    }
                    continue
                }
                let bounds = store.layout(flat[leaf.index].slot)
                let contentWidth = max(0, bounds.contentBoxSize().width - bounds.scrollbarSize.width)
                let wrapWidth = leaf.shapeKey.style.wrap == .noWrap ? nil : TextBoxGeometry.wrapWidth(contentWidth, scale: scale)
                if let request = leaf.paragraphs {
                    let box = textSystem.layoutInput(
                        text: leaf.text,
                        spans: leaf.shapeKey.spans,
                        pills: leaf.shapeKey.pills,
                        style: leaf.shapeKey.style,
                        maxWidth: wrapWidth,
                        pixelScale: scale,
                        emitGlyphs: false,
                        request: request, forMeasurement: true
                    )
                    collector.map[leaf.nodeId] = TextLayoutRecord(box: box, isInput: leaf.isInput)
                } else if let existing = textSystem.cachedLayoutBox(for: leaf.shapeKey, matchingWidth: wrapWidth, forMeasurement: true) {
                    collector.map[leaf.nodeId] = TextLayoutRecord(box: existing, isInput: leaf.isInput)
                } else {
                    let box = textSystem.layoutKeyed(
                        retaining: leaf.isInput ? nil : leaf.shapeKey, text: leaf.text,
                        spans: leaf.shapeKey.spans,
                        pills: leaf.shapeKey.pills,
                        style: leaf.shapeKey.style,
                        maxWidth: wrapWidth,
                        pixelScale: scale,
                        emitGlyphs: false,
                        keep: .cached,
                        countAsRebreak: true,
                        pretty: leaf.shapeKey.pretty, forMeasurement: true
                    )
                    collector.map[leaf.nodeId] = TextLayoutRecord(box: box, isInput: leaf.isInput)
                }
            }
        }

        // Taffy did not change any node, child list, or measurement. The prior solved
        // tree is a value snapshot. Text and live node records above still belong to this
        // pass. RTL mirroring and post-solve fitting can alter geometry outside Taffy.
        let canRetainGeometry = !memoSpans.isEmpty && !hasMirroredFlow && anchorStyles.isEmpty && aspectFits.isEmpty
        if canRetainGeometry, !geometryChanged, let previous = lastMemoLayout {
            reusedMemoGeometry = true
            return previous
        }
        let result = extract(reusingMemos: canRetainGeometry)
        lastMemoLayout = canRetainGeometry ? result : nil
        return result
    }
}
