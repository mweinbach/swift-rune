import RuneMotion

private let noReportedScroll: [Float] = [0, 0]

internal struct RefElementTextDraw {
    var drawnText: String?
    var elision: TextElision?
}

internal struct RefElementReportContext {
    var defaultForeground: Color?
    var pixelScale: Float
    var webFocus: Bool
    var activeModalPath: String?
    var modalAncestorPaths: Set<String>
    var modalMemberPaths: Set<String>
    var hasTraceNamespace: Bool
}

/// Trivial POD geometry and visual state from one native paint. Authored element fields
/// (`FlatElement`, `path`, `key`, `targetRect`, `committedLayoutTarget`) stay in the frame's
/// retained `FlatNode` arrays and are addressed by `slot` (`>= 0` mounted, `< 0` exit),
/// keeping per-node report storage completely free of ARC traffic.
internal struct PaintedElement {
    static let syntheticSlot = Int.min

    let slot: Int
    var parentIndex: Int?
    let rect: MotionRect
    let visible: MotionRect
    var opacity: Float
    let scale: Float
    let blur: Float
    let radius: Float
    let fill: Color
    let liveTextColor: Color?
    let hover: Float
    let press: Float
    let scrolled: Vec2
    let carried: Vec2
    let stuck: Float
    let focusAllowed: Bool
    let focused: Bool
    let focusVisible: Bool
    let inert: Bool
    let moving: Bool
    let exiting: Bool

    static func placeholder(parentIndex: Int? = nil) -> PaintedElement {
        PaintedElement(
            slot: syntheticSlot, parentIndex: parentIndex, rect: .zero, visible: .zero,
            opacity: 0, scale: 1, blur: 0, radius: 0, fill: .transparent, liveTextColor: nil,
            hover: 0, press: 0, scrolled: .zero, carried: .zero, stuck: 0,
            focusAllowed: false, focused: false, focusVisible: false, inert: true, moving: false, exiting: false
        )
    }

    func report<State>(
        node: borrowing Runtime<State>.FlatNode,
        mounted: [Runtime<State>.FlatNode] = [],
        pose: RawPoseNodeData?,
        edit: TextEdit? = nil,
        carriedPair: [Float]? = nil,
        refContext: RefElementReportContext? = nil,
        refTextDraw: RefElementTextDraw? = nil
    ) -> ElementInfo {
        report(
            el: node.element.value,
            path: node.path,
            key: node.key,
            nodeParentIndex: node.parentIndex,
            mounted: mounted,
            target: node.targetRect,
            committedLayoutTarget: node.committedLayoutTarget,
            pose: pose,
            edit: edit,
            carriedPair: carriedPair ?? (carried == .zero ? noReportedScroll : [carried.x, carried.y]),
            refContext: refContext,
            refTextDraw: refTextDraw
        )
    }

    private func report<State>(
        el: borrowing El<State>,
        path: String,
        key: String?,
        nodeParentIndex: Int?,
        mounted: [Runtime<State>.FlatNode],
        target: MotionRect,
        committedLayoutTarget: MotionRect,
        pose: RawPoseNodeData?,
        edit: TextEdit?,
        carriedPair: [Float],
        refContext: RefElementReportContext?,
        refTextDraw: RefElementTextDraw?
    ) -> ElementInfo {
        let secure = el.isSecure || edit?.isSecure == true
        let words = secure ? nil : edit?.text ?? el.plainText
        let effectiveMoving = (pose?.ownMoving ?? false) || moving
        if let ref = refContext {
            let traceNs: TraceNamespace? = {
                if let own = el.traceNamespaceValue {
                    return TraceNamespace(className: own.className, host: own.host)
                }
                guard ref.hasTraceNamespace else { return nil }
                var cur = nodeParentIndex
                while let pIdx = cur, mounted.indices.contains(pIdx) {
                    if let anc = mounted[pIdx].el.traceNamespaceValue {
                        return TraceNamespace(className: anc.className, host: anc.host)
                    }
                    cur = mounted[pIdx].parentIndex
                }
                return nil
            }()
            let helpText: String? = el.a11yHelp.flatMap { $0.isEmpty ? nil : runeHelpWords($0) }
            let shapeKey: UInt64? = (!secure && (el.plainText != nil || el.richSpans != nil))
                ? TextShapeKey.compute(
                    text: el.plainText ?? "",
                    spans: el.richSpans,
                    pills: el.pillChips,
                    style: el.textStyle,
                    pixelScale: ref.pixelScale,
                    wrapAnywhere: (el.runtimeExtra("htmlWrapAnywhere") as? Bool) ?? false
                )
                : nil
            var info = ElementInfo(
                path: path, key: key, parentIndex: parentIndex, role: el.role,
                geometry: .boxes(rect: rect, target: target, visible: visible), committedLayoutTarget: committedLayoutTarget,
                opacity: opacity, scale: scale, blur: blur, radius: radius, fill: fill,
                textColor: liveTextColor ?? el.textColor ?? (words != nil ? ref.defaultForeground : nil),
                text: words, label: el.a11yLabel,
                help: helpText, selected: secure ? nil : el.a11ySelected, expanded: el.a11yExpanded, level: el.a11yLevel,
                itemSelected: el.itemSelected, focusable: Runtime<State>.nodeTakesFocusStatic(el, webFocus: ref.webFocus), focused: focused,
                focusVisible: focusVisible, inert: inert,
                modalAncestor: ref.activeModalPath != nil && ref.modalAncestorPaths.contains(path),
                moving: effectiveMoving, exiting: exiting,
                hover: hover, press: press, scrolled: scrolled == carried ? carriedPair : [scrolled.x, scrolled.y],
                carriedScrolled: carriedPair, caret: nil, secure: secure, disabled: el.a11yDisabled,
                checked: el.a11yChecked, a11yValue: el.a11yValue, a11yDescription: el.a11yDescription,
                a11yHidden: el.isA11yHidden, stuck: stuck, traceName: el.traceNameValue, traceNamespace: traceNs,
                virtualExtent: pose?.virtualExtent ?? false,
                editRange: nil,
                loopPhase: pose?.loopPhase, revealing: pose?.revealing ?? false,
                inGrowingRow: pose?.ownGrowingRow ?? false, scrolling: false,
                liveIntent: pose?.ownLiveIntent ?? 0,
                shapeKey: shapeKey,
                drawnText: refTextDraw?.drawnText,
                elision: refTextDraw?.elision
            )
            info.a11yInput = ElementA11yInput(
                copy el,
                edit: edit,
                modalMember: ref.activeModalPath == nil ? nil : ref.modalMemberPaths.contains(path)
            )
            return info
        }
        return ElementInfo(
            path: path, key: key, parentIndex: parentIndex, role: el.role,
            geometry: .boxes(rect: rect, target: target, visible: visible), committedLayoutTarget: committedLayoutTarget,
            opacity: opacity, scale: scale, blur: blur, radius: radius, fill: fill,
            textColor: liveTextColor ?? el.textColor, text: words, label: el.a11yLabel ?? words,
            help: el.a11yHelp, selected: secure ? nil : el.a11ySelected, expanded: el.a11yExpanded, level: el.a11yLevel,
            itemSelected: el.itemSelected, focusable: el.focusable && focusAllowed, focused: focused,
            focusVisible: focusVisible, inert: inert, moving: effectiveMoving, exiting: exiting,
            hover: hover, press: press, scrolled: scrolled == carried ? carriedPair : [scrolled.x, scrolled.y],
            carriedScrolled: carriedPair, caret: nil, secure: secure, disabled: el.a11yDisabled,
            checked: el.a11yChecked, a11yValue: el.a11yValue, a11yDescription: el.a11yDescription,
            a11yHidden: el.isA11yHidden, stuck: stuck, traceName: el.traceNameValue, virtualExtent: pose?.virtualExtent ?? false,
            loopPhase: pose?.loopPhase, revealing: pose?.revealing ?? false, liveIntent: pose?.ownLiveIntent ?? 0,
            a11yInput: edit != nil || el.a11yRange != nil ? ElementA11yInput(copy el, edit: edit) : nil
        )
    }
}

/// Synthetic text ranges, editors, and inline links capture renderer-produced details at paint
/// time. Keeping them out of the POD `painted` array keeps steady-state frame teardown O(1).
internal final class CapturedElementReport {
    var info: ElementInfo
    init(_ info: ElementInfo) { self.info = info }
}

internal struct NativeFrameReports<State> {
    var mounted: [Runtime<State>.FlatNode]
    var exits: [Runtime<State>.FlatNode]
    var painted: [PaintedElement]
    /// Sparse overrides (editors, sliders, text highlights, link parents) addressed by painted index.
    var captured: [Int: CapturedElementReport]
    /// Trailing synthetic link records appended after painted nodes.
    var trailing: [CapturedElementReport]
    /// Present when published from `buildRefScene` so lazy materialization preserves ref-scene fields.
    var refContext: RefElementReportContext? = nil
    /// Sparse painted-text details (`drawnText`, `elision`) for onscreen labels in `buildRefScene`.
    var refTextDraws: [Int: RefElementTextDraw] = [:]

    var count: Int { painted.count + trailing.count }

    struct Entry {
        fileprivate let reports: NativeFrameReports<State>
        fileprivate let index: Int

        var path: String { reports.path(at: index) }

        func report(poses: [String: RawPoseNodeData]) -> ElementInfo {
            reports.report(at: index, poses: poses)
        }
    }

    func first(where predicate: (Entry) -> Bool) -> Entry? {
        for i in 0..<count {
            let entry = Entry(reports: self, index: i)
            if predicate(entry) { return entry }
        }
        return nil
    }

    @inline(__always)
    func path(at index: Int) -> String {
        if index >= painted.count {
            return trailing[index - painted.count].info.path
        }
        if !captured.isEmpty, let report = captured[index] {
            return report.info.path
        }
        let slot = painted[index].slot
        return slot >= 0 ? mounted[slot].path : exits[~slot].path
    }

    @inline(__always)
    func identity(at index: Int) -> (path: String, key: String?, exiting: Bool) {
        if index >= painted.count {
            let info = trailing[index - painted.count].info
            return (info.path, info.key, info.exiting)
        }
        if !captured.isEmpty, let report = captured[index] {
            let info = report.info
            return (info.path, info.key, info.exiting)
        }
        let element = painted[index]
        let slot = element.slot
        if slot >= 0 {
            return (mounted[slot].path, mounted[slot].key, element.exiting)
        }
        return (exits[~slot].path, exits[~slot].key, element.exiting)
    }

    func report(at index: Int, poses: [String: RawPoseNodeData]) -> ElementInfo {
        if index >= painted.count {
            return trailing[index - painted.count].info
        }
        if !captured.isEmpty, let report = captured[index] {
            return report.info
        }
        let element = painted[index]
        let slot = element.slot
        let textDraw = refTextDraws.isEmpty ? nil : refTextDraws[index]
        if slot >= 0 {
            let path = mounted[slot].path
            return element.report(
                node: mounted[slot],
                mounted: mounted,
                pose: poses.isEmpty ? nil : poses[path],
                refContext: refContext,
                refTextDraw: textDraw
            )
        }
        let path = exits[~slot].path
        return element.report(
            node: exits[~slot],
            mounted: mounted,
            pose: poses.isEmpty ? nil : poses[path],
            refContext: refContext,
            refTextDraw: textDraw
        )
    }

    mutating func updateOpacity(_ opacity: Float, at index: Int) {
        if index >= painted.count {
            trailing[index - painted.count].info.opacity = opacity
        } else if !captured.isEmpty, let report = captured[index] {
            report.info.opacity = opacity
        } else {
            painted[index].opacity = opacity
        }
    }

    /// Most descendants in a viewport report the same scroll pair.
    func materialize(poses: [String: RawPoseNodeData]) -> [ElementInfo] {
        var result: [ElementInfo] = []
        result.reserveCapacity(count)
        var carried = Vec2.zero
        var pair = noReportedScroll
        let hasTextDraws = !refTextDraws.isEmpty
        for i in painted.indices {
            if !captured.isEmpty, let report = captured[i] {
                result.append(report.info)
                continue
            }
            let element = painted[i]
            if carried != element.carried {
                carried = element.carried
                pair = carried == .zero ? noReportedScroll : [carried.x, carried.y]
            }
            let textDraw = hasTextDraws ? refTextDraws[i] : nil
            let slot = element.slot
            if slot >= 0 {
                let path = mounted[slot].path
                result.append(element.report(
                    node: mounted[slot],
                    mounted: mounted,
                    pose: poses.isEmpty ? nil : poses[path],
                    carriedPair: pair,
                    refContext: refContext,
                    refTextDraw: textDraw
                ))
            } else {
                let path = exits[~slot].path
                result.append(element.report(
                    node: exits[~slot],
                    mounted: mounted,
                    pose: poses.isEmpty ? nil : poses[path],
                    carriedPair: pair,
                    refContext: refContext,
                    refTextDraw: textDraw
                ))
            }
        }
        for report in trailing {
            result.append(report.info)
        }
        return result
    }
}

/// Paint-order reference for a native frame. When no raised subtrees reordered `painted`,
/// `orderSlots` is `nil` and `nativeElementReports` itself is already in exact paint order.
internal struct NativePaintOrder<State> {
    var mounted: [Runtime<State>.FlatNode]
    var exits: [Runtime<State>.FlatNode]
    var slots: [Int]
    var captured: [Int: CapturedElementReport]

    @inline(__always)
    func path(at index: Int) -> String {
        if !captured.isEmpty, let report = captured[index] {
            return report.info.path
        }
        let slot = slots[index]
        return slot >= 0 ? mounted[slot].path : exits[~slot].path
    }

    func materializePaths() -> [String] {
        var paths: [String] = []
        paths.reserveCapacity(slots.count)
        for i in slots.indices {
            paths.append(path(at: i))
        }
        return paths
    }
}

extension Runtime {
    internal func reportedPath(at index: Int) -> String? {
        if let reports = nativeElementReports {
            return (0..<reports.count).contains(index) ? reports.path(at: index) : nil
        }
        return lastElements.indices.contains(index) ? lastElements[index].path : nil
    }

    internal func updateReportedOpacity(_ opacity: Float, at index: Int) {
        if nativeElementReports != nil {
            nativeElementReports?.updateOpacity(opacity, at: index)
        } else {
            lastElements[index].opacity = opacity
        }
    }

    /// A single-element inspection need only expand its matching record.
    internal func reportedElementIndex(
        count: Int? = nil,
        where matches: ((path: String, key: String?, exiting: Bool)) -> Bool
    ) -> Int? {
        if let reports = nativeElementReports {
            let limit = count ?? reports.count
            return (0..<limit).first { matches(reports.identity(at: $0)) }
        }
        let infos = lastElements
        return (0..<(count ?? infos.count)).first {
            let info = infos[$0]
            return matches((info.path, info.key, info.exiting))
        }
    }

    internal func reportedElement(at index: Int) -> ElementInfo {
        if let reports = nativeElementReports { return reports.report(at: index, poses: nativeInspection?.rawPoseByPath ?? [:]) }
        return lastElements[index]
    }

    internal func firstReportedElement(
        where matches: ((path: String, key: String?, exiting: Bool)) -> Bool
    ) -> ElementInfo? {
        reportedElementIndex(where: matches).map { reportedElement(at: $0) }
    }
}
