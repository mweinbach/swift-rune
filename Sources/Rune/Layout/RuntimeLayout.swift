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
        let slotKeys: ArraySlice<RetainedLayoutKey>
        let leaves: ArraySlice<TextLeafFallback>
        let overflow: ArraySlice<OverflowLeaf>
        let nested: ArraySlice<MemoRecord>
        let isGroupRoot: Bool
        let geometry: MemoGeometry?
        var virtualRoot: VirtualRowRoot?

        init(record: MemoRecord, nodes: ArraySlice<PreparedNode>, slotKeys: ArraySlice<RetainedLayoutKey>,
             leaves: ArraySlice<TextLeafFallback>,
             overflow: ArraySlice<OverflowLeaf>, nested: ArraySlice<MemoRecord>, isGroupRoot: Bool,
             geometry: MemoGeometry?) {
            self.record = record
            self.nodes = nodes
            self.slotKeys = slotKeys
            self.leaves = leaves
            self.overflow = overflow
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
        let firstRecord: Int
        let virtualRoot: VirtualRowRoot?
    }

    private struct SyncVisit<State> {
        let prepared: SyncPrepared
        let childMark: Int
        let children: [El<State>]
        let virtualRows: [String: Runtime<State>.CachedVirtualRow]?
        var childKeys: [String: Int] = [:]
        var childOffsets: [Int] = []
        var childrenDirty = false
        let memo: MemoMark?
    }

    private enum SyncStep<State> {
        case visit(SyncVisit<State>)
        case finished(SyncResult)
    }

    /// Preorder edges are relative to this node, so sibling insertions preserve an entire memo slice.
    private struct PreparedNode: Sendable {
        var path: String
        var storeKey: UInt64
        var runtimeId: RuneMotion.NodeId
        var screenIdentity: Bool
        var parentOffset: Int?
        var slot: SlotId = SlotId()
        var contentStyle: TaffyBridge.ContentExtent.Child
        var measure: MeasureBox?
        var childOffsets: [Int] = []
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
        virtualRows: [String: [String: Runtime<State>.CachedVirtualRow]] = [:],
        onLiveIdsReady: ((Set<RuneMotion.NodeId>) -> Void)? = nil
    ) -> LayoutEngine.ResultNode {
        var flat: [PreparedNode] = []
        flat.reserveCapacity(max(32, store.liveCount))
        var aspectFits: [(ratio: Float, raw: RuneTaffy.TaffyStyle)] = []
        var aspectFitOrder: [(index: Int, fit: Int)] = []
        var anchorStyles: [Int: RuneTaffy.TaffyStyle] = [:]
        // Keep the full solver style only until this node has been synchronized. A replayed
        // row then transfers compact geometry records without copying grid/style storage.
        var pendingStyles: [RuneTaffy.TaffyStyle] = []
        var nonSecretLeaves: [TextLeafFallback] = []
        var overflowLeaves: [OverflowLeaf] = []
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
        var recordingMemo = false
        var memoRecords: [MemoRecord] = []
        var geometryRuns: [(range: Range<Int>, cache: MemoGeometry)] = []
        reusedMemoNodeCount = 0
        reusedVirtualRowRootCount = 0
        reusedMemoGeometry = false
        var geometryChanged = false
        var hasMirroredFlow = false

        func makeMeasure(el: borrowing El<State>, nodeId: RuneMotion.NodeId, flatIndex: Int, forcedTextFlow: TextFlow?) -> (fn: Measure?, hash: UInt64?, redacted: Bool) {
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
                let labelKey: TextShapeKey?
                if !resolved.isSecure, !resolved.displayedText.isEmpty, !resolved.truncateFade, resolved.advanceRun == nil, !isClampedOrEllipsis, textLayouts != nil {
                    // With both raw text and rich spans, the shaper draws the spans. Otherwise
                    // the resolver already joined and case-transformed their displayed text.
                    let shapeText = rawTxt == nil ? resolved.displayedText : (resolved.spans?.map(\.text).joined() ?? resolved.displayedText)
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
                let widthIndependent = labelKey != nil && resolved.style.wrap == .noWrap
                let fn: Measure = { maxW, isRealLayout, textLayouts, nodeId in
                    if widthIndependent, let labelKey, let record = textLayouts?.map[nodeId],
                       !record.isInput, record.box.maxWidth == nil, record.box.shapeKey == labelKey {
                        return record.box.shaped.size
                    }
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
                        retaining: labelKey,
                        intrinsicShapes: labelKey != nil && !widthIndependent ? textLayouts?.intrinsicShapes : nil,
                        text: hasSpans ? "" : resolved.displayedText,
                        spans: resolved.spans,
                        pills: resolved.pills,
                        style: resolved.style,
                        maxWidth: shapeMaxW,
                        pixelScale: scale,
                        emitGlyphs: false,
                        keep: keep,
                        // Intrinsic probes and final layout have the same break for an ordinary
                        // no-wrap label. Keep the first break for later Taffy probes and paint.
                        countAsRebreak: (textLayouts != nil) && (isRealLayout || widthIndependent),
                        pretty: resolved.pretty
                    )
                    if !resolved.isSecure, isRealLayout || widthIndependent, let collector = textLayouts {
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
            _ el: borrowing El<State>,
            parent: SyncPrepared?,
            siblingIndex: Int,
            siblingKeysSeen: inout [String: Int]
        ) -> SyncPrepared {
            let pin: DirPin = (el.isUnmirrored || el.anchor != nil) ? .physical : .flowing
            let effectiveParentFlow: Flow = el.isUnmirrored ? .ltr : (parent?.nodeFlow ?? .ltr)
            let (nodeFlow, _) = stepDirection(parent: effectiveParentFlow, el: el, state: state)
            if nodeFlow == .rtl { hasMirroredFlow = true }
            let nodeDirected = (el.explicitDir != nil) || el.isUnmirrored || (parent?.nodeDirected == true)
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
            let path = parent.map { "\($0.path)/\(segment)" } ?? storeRootPath
            let storePathId = parent?.storePathId.child(segment) ?? storeRootId
            let runtimePathId = keyedRootPath == nil ? storePathId : (parent?.runtimePathId.child(segment) ?? runtimeRootId)
            // Screen travel overrides this node's identity only. Children still derive
            // their stable IDs from the authored parent path.
            let screenId = el.layoutAnim?.travel == .screen
                ? resolvedKey.map { RuneMotion.NodeId.hash("screen:@\($0)") } : nil
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
                path: path,
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

            let measurement: (fn: Measure?, hash: UInt64?, redacted: Bool)
            if nodeDirected && el.textDirByParagraph && el.hasEditLens {
                // A `dirByParagraph` field's paragraphs start from the element's flow (`TextDir::Plaintext`).
                var measured = copy el
                measured.textStyle.byParagraphStart = nodeFlow.textFlow
                measurement = makeMeasure(el: measured, nodeId: runtimeNodeId, flatIndex: myIndex, forcedTextFlow: forcedTextFlow)
            } else {
                measurement = makeMeasure(el: el, nodeId: runtimeNodeId, flatIndex: myIndex, forcedTextFlow: forcedTextFlow)
            }
            let (measureFn, measureHash, isRedacted) = measurement
            flat[myIndex].measure = measureFn.map(MeasureBox.content) ?? pictureRatioToMeasure.map(MeasureBox.picture)

            return SyncPrepared(
                myIndex: myIndex,
                path: path,
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
        func reuseChildren(_ span: MemoSpan, _ p: SyncPrepared, syncingRoot: Bool = true) -> Bool {
            guard span.hasSameChildContext(p),
                  store.canReuse(span.slotKeys)
            else { return false }
            let oldStart = span.root.myIndex
            let shift = p.myIndex - oldStart
            let moved = span.root.storePathId != p.storePathId
            let changedIds = moved || span.root.runtimePathId != p.runtimePathId
            func newPath(_ node: PreparedNode) -> String {
                p.path + node.path.dropFirst(span.root.path.count)
            }
            if moved {
                var slots: [(UInt64, UInt64, SlotId, UInt32)] = []
                slots.reserveCapacity(span.nodes.count)
                for (offset, node) in span.nodes.enumerated() {
                    let key: UInt64
                    if offset == 0 { key = p.keyHash }
                    else { key = node.screenIdentity ? node.storeKey : RuneMotion.NodeId.hash(newPath(node)).rawValue }
                    guard !store.isUsedThisCommit(key: key) else { return false }
                    slots.append((node.storeKey, key, node.slot, UInt32(p.myIndex + offset)))
                }
                store.rekeyAndReuseBatch(slots)
            } else {
                store.reuseSlots(span.slotKeys.dropFirst(), startingAt: UInt32(p.myIndex + 1))
            }
            let oldRoot = span.nodes.first!
            flat[p.myIndex].childOffsets = oldRoot.childOffsets
            if !changedIds {
                for node in span.nodes.dropFirst() {
                    if node.flow == .rtl { hasMirroredFlow = true }
                    textLayouts?.liveIds.insert(node.runtimeId)
                }
                flat.append(contentsOf: span.nodes.dropFirst())
            } else {
                for var node in span.nodes.dropFirst() {
                    if moved {
                        node.path = newPath(node)
                        if !node.screenIdentity { node.storeKey = RuneMotion.NodeId.hash(node.path).rawValue }
                    }
                    if changedIds && !node.screenIdentity {
                        let runtimePath = keyedRootPath.map { $0 + node.path.dropFirst(storeRootPath.count) } ?? node.path
                        node.runtimeId = RuneMotion.NodeId.hash(runtimePath)
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
            if syncingRoot {
                for offset in flat[p.myIndex].childOffsets { store.pushChild(flat[p.myIndex + offset].slot) }
            }
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
            let slotKeys = nodes.map { RetainedLayoutKey(key: $0.storeKey, slot: $0.slot) }
            let leaves = Array(nonSecretLeaves[group.leaves])
            let overflow = Array(overflowLeaves[group.overflow])
            func local(_ range: Range<Int>, _ start: Int) -> Range<Int> {
                (range.lowerBound - start)..<(range.upperBound - start)
            }
            for (index, record) in records.enumerated() {
                guard let id = record.identity else { continue }
                let localNodes = local(record.nodes, group.nodes.lowerBound)
                let keys = slotKeys[localNodes]
                nextMemoSpans[ObjectIdentifier(id)] = MemoSpan(
                    record: record, nodes: nodes[localNodes], slotKeys: keys,
                    leaves: leaves[local(record.leaves, group.leaves.lowerBound)],
                    overflow: overflow[local(record.overflow, group.overflow.lowerBound)],
                    nested: records[record.nestedStart..<index], isGroupRoot: index == records.count - 1,
                    geometry: index == records.count - 1 ? MemoGeometry(descendants: keys.dropFirst()) : nil
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
                let node = flat[record.root.myIndex]
                record.root.path = node.path
                record.root.keyHash = node.storeKey
                if node.screenIdentity {
                    record.root.storePathId = RuneMotion.NodeId.hash(node.path)
                    let runtimePath = keyedRootPath.map { $0 + node.path.dropFirst(storeRootPath.count) } ?? node.path
                    record.root.runtimePathId = RuneMotion.NodeId.hash(runtimePath)
                } else {
                    record.root.storePathId = RuneMotion.NodeId(node.storeKey)
                    record.root.runtimePathId = node.runtimeId
                }
                record.leaves = moved(record.leaves, leafShift)
                record.overflow = moved(record.overflow, overflowShift)
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
                    if reuseChildren(span, prepared, syncingRoot: false) {
                        store.reuseSlot(node.slot, nodeIndex: UInt32(index))
                        textLayouts?.liveIds.insert(node.runtimeId)
                        if node.flow == .rtl { hasMirroredFlow = true }
                        siblingKeysSeen[key] = 1
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
                                      siblingKeysSeen: &siblingKeysSeen, sourceRows: sourceRows)
                }
                virtualRoot = VirtualRowRoot(row.layoutProjection?.owner ?? row.rootIdentity, key: key, parent: parent)
            }
            let p = syncPrepare(el, parent: parent, siblingIndex: siblingIndex, siblingKeysSeen: &siblingKeysSeen)
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
            if let memoKey, let span = memoSpans[memoKey], span.record.identity === identity,
               reuseChildren(span, p) {
                let (slot, dirty) = syncFinish(p, childMark: childMark, childrenDirty: false)
                if !wasRecording, span.isGroupRoot, p.storePathId == span.root.storePathId,
                   p.runtimePathId == span.root.runtimePathId, span.nodes.first?.slot == slot {
                    forwardGroup(span, memoKey)
                } else {
                    moveNestedRecords(span, p, firstLeaf: firstLeaf, firstOverflow: firstOverflow)
                    memoRecords.append(MemoRecord(identity: identity, root: p, nodes: myIndex..<flat.count,
                        leaves: firstLeaf..<nonSecretLeaves.count, overflow: firstOverflow..<overflowLeaves.count,
                        nestedStart: firstRecord))
                    if !wasRecording { installMemoGroup() }
                }
                if !wasRecording, let current = nextMemoSpans[memoKey] {
                    current.virtualRoot = virtualRoot
                    if let geometry = current.geometry { geometryRuns.append((myIndex..<flat.count, geometry)) }
                }
                return .finished((myIndex, slot, dirty))
            }
            var mark: MemoMark?
            if memoKey != nil, let identity {
                mark = MemoMark(identity: identity, wasRecording: wasRecording, firstLeaf: firstLeaf,
                                firstOverflow: firstOverflow, firstRecord: firstRecord, virtualRoot: virtualRoot)
                recordingMemo = true
            }
            let rows: [String: Runtime<State>.CachedVirtualRow]?
            if !virtualRows.isEmpty, el.virtualEstimate != nil {
                let path = keyedRootPath.map { $0 + p.path.dropFirst(storeRootPath.count) } ?? p.path
                rows = virtualRows[path]
            } else {
                rows = nil
            }
            var visit = SyncVisit(prepared: p, childMark: childMark, children: el.children, virtualRows: rows, memo: mark)
            visit.childOffsets.reserveCapacity(el.children.count)
            return .visit(visit)
        }

        @inline(never)
        func finishVisit(_ visit: SyncVisit<State>) -> SyncResult {
            let p = visit.prepared
            flat[p.myIndex].childOffsets = visit.childOffsets
            let (slot, dirty) = syncFinish(p, childMark: visit.childMark, childrenDirty: visit.childrenDirty)
            if let mark = visit.memo {
                recordingMemo = mark.wasRecording
                memoRecords.append(MemoRecord(identity: mark.identity, root: p, nodes: p.myIndex..<flat.count,
                    leaves: mark.firstLeaf..<nonSecretLeaves.count, overflow: mark.firstOverflow..<overflowLeaves.count,
                    nestedStart: mark.firstRecord))
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
            var next = beginVisit(rootEl, parent: nil, siblingIndex: 0, siblingKeysSeen: &rootKeys)
            var stack: [SyncVisit<State>] = []
            while true {
                switch next {
                case .visit(let visit):
                    stack.append(visit)
                case .finished(let result):
                    guard !stack.isEmpty else { return result }
                    let parent = stack.count - 1
                    let offset = result.idx - stack[parent].prepared.myIndex
                    stack[parent].childOffsets.append(offset)
                    if result.dirty { stack[parent].childrenDirty = true }
                    store.pushChild(result.slot)
                }
                let parent = stack.count - 1
                let index = stack[parent].childOffsets.count
                if index == stack[parent].children.count {
                    next = .finished(finishVisit(stack.removeLast()))
                } else {
                    let prepared = stack[parent].prepared
                    // Hold the immutable sibling storage outside the parent's mutating key map.
                    let children = stack[parent].children
                    let rows = stack[parent].virtualRows
                    next = children.withUnsafeBufferPointer { buffer in
                        beginVisit(buffer.baseAddress!.advanced(by: index).pointee, parent: prepared, siblingIndex: index,
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

        let prepared = flat
        let measureClosure: @Sendable (RuneTaffy.LayoutInput, Int?, RuneTaffy.TaffyStyle) -> RuneTaffy.LayoutOutput = { input, ctx, style in
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

        store.computeLayout(root: rootSlot, availableSpace: available, rounding: false, measureLeaf: measureClosure)

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
            store.computeLayout(root: rootSlot, availableSpace: available, rounding: false, measureLeaf: measureClosure)
        }

        // Flat nodes are in preorder. Walking them backwards leaves each node's solved
        // children at the top of the stack in their original painter/layout order.
        func extract(reusingMemos: Bool = false) -> LayoutEngine.ResultNode {
            var solved: [(RuneTaffy.Layout, LayoutEngine.ResultNode)] = []
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
                var children: [LayoutEngine.ResultNode] = []
                children.reserveCapacity(node.childOffsets.count)
                for offset in node.childOffsets {
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
                        guard let cur = targetIdx, c >= 0, c < flat[cur].childOffsets.count else {
                            targetIdx = nil
                            break
                        }
                        targetIdx = cur + flat[cur].childOffsets[c]
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
                        request: request
                    )
                    collector.map[leaf.nodeId] = TextLayoutRecord(box: box, isInput: leaf.isInput)
                } else if let existing = textSystem.cachedLayoutBox(for: leaf.shapeKey, matchingWidth: wrapWidth) {
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
                        pretty: leaf.shapeKey.pretty
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
