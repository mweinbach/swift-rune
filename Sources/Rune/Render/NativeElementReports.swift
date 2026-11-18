import RuneMotion

private let noReportedScroll: [Float] = [0, 0]

/// The geometry and visual state from one paint. Authored fields are immutable through
/// FlatElement's copy-on-write storage, even if input commits a new tree before inspection.
internal struct PaintedElement<State> {
    let authored: FlatElement<State>
    let path: String
    let key: String?
    var parentIndex: Int?
    let rect: MotionRect
    let target: MotionRect
    let visible: MotionRect
    let committedLayoutTarget: MotionRect
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

    func report(pose: RawPoseNodeData?, edit: TextEdit? = nil, carriedPair: [Float]? = nil) -> ElementInfo {
        report(authored.value, pose: pose, edit: edit,
               carriedPair: carriedPair ?? (carried == .zero ? noReportedScroll : [carried.x, carried.y]))
    }

    private func report(_ el: El<State>, pose: RawPoseNodeData?, edit: TextEdit?, carriedPair: [Float]) -> ElementInfo {
        let secure = el.isSecure || edit?.isSecure == true
        let words = secure ? nil : edit?.text ?? el.plainText
        return ElementInfo(
            path: path, key: key, parentIndex: parentIndex, role: el.role,
            geometry: .boxes(rect: rect, target: target, visible: visible), committedLayoutTarget: committedLayoutTarget,
            opacity: opacity, scale: scale, blur: blur, radius: radius, fill: fill,
            textColor: liveTextColor ?? el.textColor, text: words, label: el.a11yLabel ?? words,
            help: el.a11yHelp, selected: secure ? nil : el.a11ySelected, expanded: el.a11yExpanded, level: el.a11yLevel,
            itemSelected: el.itemSelected, focusable: el.focusable && focusAllowed, focused: focused,
            focusVisible: focusVisible, inert: inert, moving: pose?.ownMoving ?? moving, exiting: exiting,
            hover: hover, press: press, scrolled: scrolled == carried ? carriedPair : [scrolled.x, scrolled.y],
            carriedScrolled: carriedPair, caret: nil, secure: secure, disabled: el.a11yDisabled,
            checked: el.a11yChecked, a11yValue: el.a11yValue, a11yDescription: el.a11yDescription,
            a11yHidden: el.isA11yHidden, stuck: stuck, traceName: el.traceNameValue, virtualExtent: pose?.virtualExtent ?? false,
            loopPhase: pose?.loopPhase, revealing: pose?.revealing ?? false, liveIntent: pose?.ownLiveIntent ?? 0,
            a11yInput: edit != nil || el.a11yRange != nil ? ElementA11yInput(el, edit: edit) : nil
        )
    }
}

/// Synthetic text ranges and editors capture renderer-produced details at paint time. Boxing
/// just those full records keeps the ordinary array stride independent of ElementInfo's size.
internal final class CapturedElementReport {
    var info: ElementInfo
    init(_ info: ElementInfo) { self.info = info }
}

internal enum NativeElementReport<State> {
    case painted(PaintedElement<State>)
    case captured(CapturedElementReport)

    var path: String {
        switch self {
        case .painted(let element): element.path
        case .captured(let report): report.info.path
        }
    }

    var identity: (path: String, key: String?, exiting: Bool) {
        switch self {
        case .painted(let element): (element.path, element.key, element.exiting)
        case .captured(let report): (report.info.path, report.info.key, report.info.exiting)
        }
    }

    func report(poses: [String: RawPoseNodeData]) -> ElementInfo {
        switch self {
        case .painted(let element): element.report(pose: poses.isEmpty ? nil : poses[element.path])
        case .captured(let report): report.info
        }
    }

    /// Most descendants in a viewport report the same scroll pair.
    static func materialize(_ reports: [Self], poses: [String: RawPoseNodeData]) -> [ElementInfo] {
        var carried = Vec2.zero
        var pair = noReportedScroll
        return reports.map { row in
            switch row {
            case .painted(let element):
                if carried != element.carried {
                    carried = element.carried
                    pair = carried == .zero ? noReportedScroll : [carried.x, carried.y]
                }
                return element.report(pose: poses.isEmpty ? nil : poses[element.path], carriedPair: pair)
            case .captured(let report):
                return report.info
            }
        }
    }

    mutating func updateOpacity(_ opacity: Float) {
        switch self {
        case .painted(var element):
            element.opacity = opacity
            self = .painted(element)
        case .captured(let report):
            report.info.opacity = opacity
        }
    }

    func restoringParent(in treeOrder: [Int]) -> Self {
        switch self {
        case .painted(var element):
            element.parentIndex = element.parentIndex.map { treeOrder[$0] }
            return .painted(element)
        case .captured(let report):
            report.info.parentIndex = report.info.parentIndex.map { treeOrder[$0] }
            return self
        }
    }
}

extension Runtime {
    internal func reportedPath(at index: Int) -> String? {
        if let reports = nativeElementReports {
            return reports.indices.contains(index) ? reports[index].path : nil
        }
        return lastElements.indices.contains(index) ? lastElements[index].path : nil
    }

    internal func updateReportedOpacity(_ opacity: Float, at index: Int) {
        if nativeElementReports != nil {
            nativeElementReports?[index].updateOpacity(opacity)
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
            return (0..<(count ?? reports.count)).first { matches(reports[$0].identity) }
        }
        let infos = lastElements
        return (0..<(count ?? infos.count)).first {
            let info = infos[$0]
            return matches((info.path, info.key, info.exiting))
        }
    }

    internal func reportedElement(at index: Int) -> ElementInfo {
        if let reports = nativeElementReports { return reports[index].report(poses: nativeInspection?.rawPoseByPath ?? [:]) }
        return lastElements[index]
    }

    internal func firstReportedElement(
        where matches: ((path: String, key: String?, exiting: Bool)) -> Bool
    ) -> ElementInfo? {
        reportedElementIndex(where: matches).map { reportedElement(at: $0) }
    }
}
