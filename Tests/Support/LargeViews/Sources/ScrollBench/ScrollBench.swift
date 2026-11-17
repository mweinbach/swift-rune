import Foundation
import LargeViewFixtures
import Rune
import RuneRef
#if canImport(ScrollBenchMetal)
import ScrollBenchMetal
#endif

private enum Workload: String {
    case table, tree, diff

    var viewport: Vec2 {
        switch self {
        case .table: LargeViewFixtures.tableViewport
        case .tree: LargeViewFixtures.treeViewport
        case .diff: LargeViewFixtures.diffViewport
        }
    }

    var wheelDelta: Float { self == .diff ? -400 : -48 }

    func isRow(_ element: ElementInfo) -> Bool {
        switch self {
        case .table: element.role == .row
        case .tree: element.role == .treeItem
        case .diff: element.key?.hasPrefix("dv-df") == true
        }
    }

    var finalKeys: [String] {
        switch self {
        case .table: return (1028...1059).map { "f\($0)" }
        case .tree:
            return (1200...1237).map { index in
                let package = "pkg\(index / 101)"
                let entry = index % 101
                return entry == 0 ? package : "\(package)/file\(entry - 1).rs"
            }
        case .diff:
            return (10_502...10_540).flatMap { line in
                line.isMultiple(of: 7) ? ["df0.o\(line)", "df0.n\(line)"] : ["df0.c\(line)"]
            }
        }
    }
}

private enum Mode: String { case reference, production, window }

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct Row: Codable {
    let key: String?
    let label: String?
    let rect: [Float]
    let visible: [Float]
}

private struct Snapshot: Codable {
    let scene: [Int]
    let count: Int
    let rows: [Row]
    let nativeInstances: Int?
    let referencePrimitives: Int?
    let scrollOffsetY: Float?
    let stickyHeaderBottom: Float?
}

private struct Timing: Codable {
    let p50MS: Double
    let p95MS: Double
    let meanMS: Double
    let within120HzBudget: Int
    let within60HzBudget: Int

    init(_ values: [Double]) {
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double { sorted[Int((Double(sorted.count - 1) * p).rounded())] }
        p50MS = percentile(0.50)
        p95MS = percentile(0.95)
        meanMS = values.reduce(0, +) / Double(values.count)
        within120HzBudget = values.filter { $0 <= 1_000 / 120 }.count
        within60HzBudget = values.filter { $0 <= 1_000 / 60 }.count
    }
}

private struct Result: Codable {
    let workload: String
    let mode: String
    let steps: Int
    let dimensions: [Int]
    let commits: UInt64
    let mountedDataRows: Int
    let visibleDataRows: Int
    let firstVisible: String?
    let lastVisible: String?
    let scrollOffsetY: Float?
    let frameWork: Timing
    let hostReportIntervals: Timing?
}

private func elapsedMS(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant = .now) -> Double {
    let d = (end - start).components
    return Double(d.seconds) * 1_000 + Double(d.attoseconds) / 1e15
}

private struct Probe {
    let workload: Workload
    let mode: Mode
    let output: URL?
    let presentationOutput: URL?
    let steps = 600
    let checkpoints = [0, 1, 24, 60, 300, 600]

    init(_ args: [String]) throws {
        let usage = Failure("Usage: ScrollBench table|tree|diff reference|production|window [--capture directory] [--metal-presents file.csv]")
        guard args.count >= 2, args.count.isMultiple(of: 2),
              let workload = Workload(rawValue: args[0]), let mode = Mode(rawValue: args[1]) else {
            throw usage
        }
        self.workload = workload
        self.mode = mode
        var capture: URL?, presentations: URL?
        for index in stride(from: 2, to: args.count, by: 2) {
            switch args[index] {
            case "--capture" where capture == nil:
                capture = URL(fileURLWithPath: args[index + 1], isDirectory: true)
            #if canImport(ScrollBenchMetal)
            case "--metal-presents" where mode == .window && presentations == nil:
                presentations = URL(fileURLWithPath: args[index + 1])
            #endif
            default: throw usage
            }
        }
        output = capture
        presentationOutput = presentations
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
    }

    func scroll<S>(_ rt: Runtime<S>, at now: Double) {
        let size = workload.viewport
        rt.wheel(WheelEvent(dx: 0, dy: workload.wheelDelta), at: Vec2(size.x / 2, size.y / 2), now: now)
    }

    func snapshot<S>(_ rt: Runtime<S>, nativeInstances: Int? = nil, referencePrimitives: Int? = nil) -> Snapshot {
        let elements = rt.elements()
        let rows = elements.filter { !$0.exiting && workload.isRow($0) }.map { element in
            let key = workload == .diff ? element.key.map { String($0.dropFirst("dv-".count)) } : element.key
            return Row(key: key, label: element.label, rect: element.rect, visible: element.visible)
        }
        var headerBottom: Float?
        if workload == .diff, let header = elements.first(where: { element in
            element.key == "dv-header" && !element.exiting && element.parentIndex.map { elements[$0].key == "dv" } == true
        }) { headerBottom = header.rect[1] + header.rect[3] }
        let size = [rt.viewport.x, rt.viewport.y].map { Int(($0 * rt.pixelScale).rounded()) }
        return Snapshot(scene: size, count: rows.count, rows: rows, nativeInstances: nativeInstances,
                        referencePrimitives: referencePrimitives,
                        scrollOffsetY: workload == .diff ? rt.scrollOffset(forKey: "dv-body").y : nil,
                        stickyHeaderBottom: headerBottom)
    }

    func capture<S>(_ rt: Runtime<S>, index: Int, scene: RefScene?, nativeInstances: Int? = nil) throws {
        guard let output, checkpoints.contains(index) else { return }
        let base = output.appendingPathComponent("\(workload.rawValue)-\(index)")
        let snapshot = snapshot(rt, nativeInstances: nativeInstances, referencePrimitives: scene?.primitives.count)
        try JSONEncoder().encode(snapshot).write(to: base.appendingPathExtension("json"))
        if let scene, index == 0 || index == 60 {
            let rendered = try RuneRef.render(scene)
            try Data(rendered.rgba).write(to: base.appendingPathExtension("rgba"))
            try rendered.writePNG(to: base.appendingPathExtension("png"))
        }
    }

    func report<S>(_ rt: Runtime<S>, commits: UInt64, work: [Double], arrivals: [Double] = []) throws {
        let frame = snapshot(rt)
        let rows = frame.rows.filter { $0.key != "header" }
        let visible = rows.filter { $0.visible[2] > 0 && $0.visible[3] > 0
            && $0.visible[1] + $0.visible[3] > (frame.stickyHeaderBottom ?? 0)
        }.sorted { $0.visible[1] < $1.visible[1] }
        let begin = visible.first?.key, end = visible.last?.key
        guard rt.viewport == workload.viewport, visible.compactMap(\.key) == workload.finalKeys,
              frame.scrollOffsetY.map({ abs($0 + Float(steps) * workload.wheelDelta) < 0.01 }) ?? true else {
            throw Failure("Unexpected viewport, offset or visible rows after \(work.count) wheels (\(begin ?? "none") to \(end ?? "none"))")
        }
        let result = Result(workload: workload.rawValue, mode: mode.rawValue, steps: work.count, dimensions: frame.scene,
                            commits: commits, mountedDataRows: rows.count, visibleDataRows: visible.count, firstVisible: begin, lastVisible: end,
                            scrollOffsetY: frame.scrollOffsetY,
                            frameWork: Timing(work), hostReportIntervals: arrivals.isEmpty ? nil : Timing(arrivals))
        let bytes = try JSONEncoder().encode(result)
        FileHandle.standardOutput.write(bytes + Data([0x0a]))
        if let output {
            try bytes.write(to: output.appendingPathComponent("\(workload.rawValue)-\(mode.rawValue)-timing.json"))
        }
    }

    @MainActor func run<S>(_ rt: Runtime<S>) throws {
        if mode == .window {
            try window(rt)
            return
        }
        rt.setSrgbBlend(true)
        if mode == .production {
            let initial = rt.renderFrame(at: 0)
            try capture(rt, index: 0, scene: nil, nativeInstances: initial.instances.count)
        } else {
            try capture(rt, index: 0, scene: rt.frame(at: 0))
        }
        let startCommits = rt.viewCommitCount
        var work: [Double] = []
        for index in 1...steps {
            let now = Double(index) / 120
            scroll(rt, at: now)
            let start = ContinuousClock.now
            let scene: RefScene?
            let nativeCount: Int?
            if mode == .production {
                nativeCount = rt.renderFrame(at: now).instances.count
                scene = nil
            } else {
                scene = rt.frame(at: now)
                nativeCount = nil
            }
            work.append(elapsedMS(start))
            try capture(rt, index: index, scene: scene, nativeInstances: nativeCount)
        }
        let commits = rt.viewCommitCount - startCommits
        if mode == .production { _ = rt.frame(at: Double(steps) / 120) }
        try report(rt, commits: UInt64(commits), work: work)
    }

    @MainActor private func window<S>(_ example: Runtime<S>) throws {
        #if canImport(ScrollBenchMetal)
        if let presentationOutput {
            try FileManager.default.createDirectory(at: presentationOutput.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard scroll_bench_observe_presentations(presentationOutput.path) else {
                throw Failure("Could not open presentation CSV at \(presentationOutput.path)")
            }
        }
        #endif
        let size = workload.viewport
        let app = App(title: "Rune large views", size: size, state: example.state, view: example.view)
            .minSize(size.x, size.y)
        let handle = app.handle()
        var drawn: [FrameEncoded] = []
        var intervals: [Double] = []
        var previous: ContinuousClock.Instant?
        var handled = 0
        let instrumented = app.onFrameEncoded { frame in
            guard frame.outcome == .drawn, drawn.count <= steps else { return }
            #if canImport(ScrollBenchMetal)
            if presentationOutput != nil, Int(scroll_bench_wheels_submitted()) != drawn.count { return }
            #endif
            let now = ContinuousClock.now
            if let previous { intervals.append(elapsedMS(previous, now)) }
            previous = now
            drawn.append(frame)
        }.onFrameDrawn { rt in
            guard drawn.count > handled else { return }
            handled = drawn.count
            let index = handled - 1
            do {
                try capture(rt, index: index, scene: nil, nativeInstances: drawn[index].primitives)
                if index == steps {
                    let measured = drawn.dropFirst()
                    try report(rt, commits: UInt64(measured.filter(\.committed).count),
                               work: measured.map(\.frameMs), arrivals: intervals)
                    if presentationOutput != nil {
                        // Keep the final drawable visible while Metal delivers its timestamp.
                        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { handle.quit() }
                    } else {
                        handle.quit()
                    }
                } else {
                    #if canImport(ScrollBenchMetal)
                    if presentationOutput != nil {
                        scroll_bench_wheel(Double(workload.wheelDelta))
                        return
                    }
                    #endif
                    scroll(rt, at: rt.currentTime)
                    let waker = rt.waker
                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(1)) { waker.wake() }
                }
            } catch {
                ScrollBench.fail(error)
            }
        }
        try instrumented.run(arguments: [])
        if drawn.count != steps + 1 { throw Failure("Window closed before all \(steps) steps were drawn") }
    }
}

@main private struct ScrollBench {
    static func fail(_ error: Error) -> Never {
        FileHandle.standardError.write(Data("ScrollBench: \(error)\n".utf8))
        exit(1)
    }

    @MainActor static func main() {
        do {
            let probe = try Probe(Array(CommandLine.arguments.dropFirst()))
            switch probe.workload {
            case .table: try probe.run(LargeViewFixtures.table(LargeTableState()))
            case .tree: try probe.run(LargeViewFixtures.tree(LargeViewFixtures.treeModel()))
            case .diff: try probe.run(LargeViewFixtures.diff())
            }
        } catch {
            fail(error)
        }
    }
}
