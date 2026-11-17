import Foundation
import LargeViewFixtures
import Rune
import RuneRef

private enum Workload: String {
    case table, tree

    var viewport: Vec2 {
        self == .table ? LargeViewFixtures.tableViewport : LargeViewFixtures.treeViewport
    }

    var rowRole: ElementRole { self == .table ? .row : .treeItem }

    var finalKeys: [String] {
        switch self {
        case .table: return (1028...1059).map { "f\($0)" }
        case .tree:
            return (1200...1237).map { index in
                let package = "pkg\(index / 101)"
                let entry = index % 101
                return entry == 0 ? package : "\(package)/file\(entry - 1).rs"
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
    let steps = 600
    let checkpoints = [0, 1, 24, 60, 300, 600]

    init(_ args: [String]) throws {
        guard args.count == 2 || args.count == 4,
              let workload = Workload(rawValue: args[0]), let mode = Mode(rawValue: args[1]),
              args.count == 2 || args[2] == "--capture" else {
            throw Failure("Usage: ScrollBench table|tree reference|production|window [--capture directory]")
        }
        self.workload = workload
        self.mode = mode
        output = args.count == 4 ? URL(fileURLWithPath: args[3], isDirectory: true) : nil
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
    }

    func scroll<S>(_ rt: Runtime<S>, at now: Double) {
        let size = workload.viewport
        rt.wheel(WheelEvent(dx: 0, dy: -48), at: Vec2(size.x / 2, size.y / 2), now: now)
    }

    func snapshot<S>(_ rt: Runtime<S>, nativeInstances: Int? = nil, referencePrimitives: Int? = nil) -> Snapshot {
        let rows = rt.elements().filter { !$0.exiting && $0.role == workload.rowRole }
            .map { Row(key: $0.key, label: $0.label, rect: $0.rect, visible: $0.visible) }
        let size = [rt.viewport.x, rt.viewport.y].map { Int(($0 * rt.pixelScale).rounded()) }
        return Snapshot(scene: size, count: rows.count, rows: rows, nativeInstances: nativeInstances,
                        referencePrimitives: referencePrimitives)
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
        let visible = rows.filter { $0.visible[2] > 0 && $0.visible[3] > 0 }.sorted { $0.visible[1] < $1.visible[1] }
        let begin = visible.first?.key, end = visible.last?.key
        let result = Result(workload: workload.rawValue, mode: mode.rawValue, steps: work.count, dimensions: frame.scene,
                            commits: commits, mountedDataRows: rows.count, visibleDataRows: visible.count, firstVisible: begin, lastVisible: end,
                            frameWork: Timing(work), hostReportIntervals: arrivals.isEmpty ? nil : Timing(arrivals))
        let bytes = try JSONEncoder().encode(result)
        print(String(decoding: bytes, as: UTF8.self))
        if let output {
            try bytes.write(to: output.appendingPathComponent("\(workload.rawValue)-\(mode.rawValue)-timing.json"))
        }
        guard rt.viewport == workload.viewport, visible.compactMap(\.key) == workload.finalKeys else {
            throw Failure("Unexpected viewport or scroll position after \(work.count) wheel steps")
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
        let size = workload.viewport
        let app = App(title: "Rune large views", size: size, state: example.state, view: example.view)
            .minSize(size.x, size.y)
        let handle = app.handle()
        var drawn: [FrameEncoded] = []
        var intervals: [Double] = []
        var previous: ContinuousClock.Instant?
        var handled = 0
        var failure: Error?
        let instrumented = app.onFrameEncoded { frame in
            guard frame.outcome == .drawn, drawn.count <= steps else { return }
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
                    handle.quit()
                } else {
                    scroll(rt, at: rt.currentTime)
                    let waker = rt.waker
                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(1)) { waker.wake() }
                }
            } catch {
                failure = error
                handle.quit()
            }
        }
        try instrumented.run(arguments: [])
        if let failure { throw failure }
        if drawn.count != steps + 1 { throw Failure("Window closed before all \(steps) steps were drawn") }
    }
}

@main private struct ScrollBench {
    @MainActor static func main() throws {
        let probe = try Probe(Array(CommandLine.arguments.dropFirst()))
        switch probe.workload {
        case .table: try probe.run(LargeViewFixtures.table(LargeTableState()))
        case .tree: try probe.run(LargeViewFixtures.tree(LargeViewFixtures.treeModel()))
        }
    }
}
