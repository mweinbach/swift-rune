import Foundation
import RuneRef

// MARK: - Motion Gate Runner, Allowlist, Report & Evidence (`motion_gate/gate.rs`, `check/evidence.rs`)

public typealias MotionGateAllow = (kind: String, element: String, cell: String, why: String)

public struct MotionGateAllowRow: Sendable, Equatable {
    public var kind: String
    public var element: String
    public var cell: String
    public var why: String
    public var max: Int?

    public init(_ kind: String, _ element: String, _ cell: String, _ why: String, max: Int? = nil) {
        self.kind = kind
        self.element = element
        self.cell = cell
        self.why = why
        self.max = max
    }

    public func max(_ n: Int) -> MotionGateAllowRow {
        var copy = self
        copy.max = n
        return copy
    }

    public func matches(_ f: MotionGateFinding, cell: String) -> Bool {
        (kind.isEmpty || f.kind == kind) &&
        (element.isEmpty || f.element.contains(element)) &&
        inCell(cell)
    }

    public func inCell(_ cellName: String) -> Bool {
        if cell.isEmpty { return true }
        return cell.split(separator: "|", omittingEmptySubsequences: false).contains {
            $0.isEmpty || cellName.contains(String($0))
        }
    }
}

public struct MotionGateCell: Sendable {
    public var name: String
    public var findings: [MotionGateFinding]
    public var frames: Int
    public var skipped: Bool

    public init(name: String, findings: [MotionGateFinding], frames: Int, skipped: Bool) {
        self.name = name
        self.findings = findings
        self.frames = frames
        self.skipped = skipped
    }
}

public struct MotionGateReport: Sendable, LocalizedError, CustomStringConvertible {
    public var description: String { text }
    public var errorDescription: String? { text }
    public var text: String
    public var summary: String
    public var failing: Int
    public var allowed: Int
    public var unused: Int
}

public enum MotionGateGate {
    public typealias Job = @Sendable () -> MotionGateRecording

    public static func allowed(_ allow: [MotionGateAllow], finding: MotionGateFinding, cell: String) -> String? {
        allow.map { MotionGateAllowRow($0.kind, $0.element, $0.cell, $0.why) }
            .first { $0.matches(finding, cell: cell) }?
            .why
    }

    public static func run(_ cells: [(String, Job)], filter: String = "") -> [MotionGateCell] {
        do {
            return try run(cells, filter: filter, environment: ProcessInfo.processInfo.environment)
        } catch {
            preconditionFailure("Motion gate evidence: \(error)")
        }
    }

    private static func run(
        _ cells: [(String, Job)], filter: String, environment: [String: String]
    ) throws -> [MotionGateCell] {
        let jobs = cells.filter { filter.isEmpty || $0.0.contains(filter) }
        let execute: @Sendable ((String, Job)) throws -> MotionGateCell = { pair in
            let (name, job) = pair
            let rec = job()
            try writeEvidence(cell: name, rec: rec, out: environment["MOTION_GATE_OUT"], environment: environment)
            return MotionGateCell(name: name, findings: motionGateCheck(rec), frames: rec.frames, skipped: rec.frames < 10)
        }
        #if os(WASI)
        return try jobs.map(execute)
        #else
        let queue = JobQueue(jobs)
        let group = DispatchGroup()
        for _ in 0..<min(jobs.count, ProcessInfo.processInfo.activeProcessorCount, 12) {
            group.enter()
            let worker = Thread {
                defer { group.leave() }
                while let (index, job) = queue.take() {
                    queue.finish(index, Result { try execute(job) })
                }
            }
            worker.stackSize = 64 << 20
            worker.start()
        }
        group.wait()
        return try queue.results.map { try $0!.get() }
        #endif
    }

    #if !os(WASI)
    private final class JobQueue: @unchecked Sendable {
        private let lock = NSLock()
        private let jobs: [(String, Job)]
        private var remaining: Int
        private(set) var results: [Result<MotionGateCell, Error>?]

        init(_ jobs: [(String, Job)]) {
            self.jobs = jobs
            remaining = jobs.count
            results = Array(repeating: nil, count: jobs.count)
        }

        func take() -> (Int, (String, Job))? {
            lock.lock()
            defer { lock.unlock() }
            guard remaining > 0 else { return nil }
            remaining -= 1
            return (remaining, jobs[remaining])
        }

        func finish(_ index: Int, _ result: Result<MotionGateCell, Error>) {
            lock.lock()
            results[index] = result
            lock.unlock()
        }
    }
    #endif

    /// Runs the selected cells and writes their report. A failed gate throws its completed report.
    @discardableResult
    public static func gate(_ cells: [(String, Job)], allow: [MotionGateAllow] = []) throws -> MotionGateReport {
        try gateRows(cells, rows: allow.map { MotionGateAllowRow($0.kind, $0.element, $0.cell, $0.why) })
    }

    @discardableResult
    public static func gateRows(
        _ jobs: [(String, Job)], rows: [MotionGateAllowRow],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> MotionGateReport {
        let start = ProcessInfo.processInfo.systemUptime
        let filter = environment["MOTION_GATE"] ?? ""
        let cells = try run(jobs, filter: filter, environment: environment)
        let report = reportWith(cells, rows: rows, listAllowed: environment["MOTION_GATE_ALLOWED"] != nil,
                                whole: filter.isEmpty, secs: Float(ProcessInfo.processInfo.systemUptime - start))
        if let path = environment["MOTION_GATE_OUT"] {
            try Data(report.text.utf8).write(to: URL(fileURLWithPath: path), options: .runeOutput)
        }
        guard report.failing == 0 else { throw report }
        RuneStandardIO.error(report.summary)
        return report
    }

    public static func report(
        _ cells: [MotionGateCell],
        allow: [MotionGateAllow] = [],
        listAllowed: Bool = false,
        secs: Float = 0.0
    ) -> MotionGateReport {
        let rows = allow.map { MotionGateAllowRow($0.kind, $0.element, $0.cell, $0.why) }
        return reportRows(cells, rows: rows, listAllowed: listAllowed, secs: secs)
    }

    public static func reportRows(
        _ cells: [MotionGateCell],
        rows: [MotionGateAllowRow],
        listAllowed: Bool = false,
        secs: Float = 0.0
    ) -> MotionGateReport {
        reportWith(cells, rows: rows, listAllowed: listAllowed, whole: true, secs: secs)
    }

    private static func reportWith(
        _ cells: [MotionGateCell],
        rows: [MotionGateAllowRow],
        listAllowed: Bool,
        whole: Bool,
        secs: Float
    ) -> MotionGateReport {
        var used = Array(repeating: 0, count: rows.count)
        var text = ""
        var failing = 0
        var allowedN = 0
        var failedKinds: [String] = []

        for c in cells {
            if c.skipped {
                failing += 1
                text += "SKIP \(c.name) (its setup didn't apply)\n"
            }
            for f in c.findings {
                let rowIdx = rows.firstIndex { $0.matches(f, cell: c.name) }
                var overMax: Int? = nil
                if let i = rowIdx {
                    used[i] += 1
                    if let m = rows[i].max, used[i] > m {
                        overMax = m
                    }
                }
                if let i = rowIdx, overMax == nil {
                    allowedN += 1
                    if listAllowed {
                        text += "allowed  \(f)  in \(c.name)  (\(rows[i].why))\n"
                    }
                } else {
                    failing += 1
                    failedKinds.append(f.kind)
                    let past = overMax.map { "  (past its allow row's max of \($0))" } ?? ""
                    text += "\(f)  in \(c.name)\(past)\n"
                }
            }
        }

        func ran(_ r: MotionGateAllowRow) -> Bool {
            cells.contains { !$0.skipped && r.inCell($0.name) }
        }

        var unusedRows: [MotionGateAllowRow] = []
        for (r, count) in zip(rows, used) where whole && count == 0 && ran(r) {
            unusedRows.append(r)
            text += "unused allow row (\"\(r.kind)\", \"\(r.element)\", \"\(r.cell)\"): \(r.why)\n"
        }

        let totalFrames = cells.reduce(0) { $0 + $1.frames }
        let summary = String(format: "motion gate: %d cells, %d frames, %d findings (%d allowed, %d unused allow rows) in %.1f s\n", cells.count, totalFrames, failing, allowedN, unusedRows.count, secs)

        let uniqueFailed = Set(failedKinds)
        for r in MOTION_GATE_RULES where uniqueFailed.contains(r.kind) {
            let threshold = r.threshold == r.threshold.rounded() ? String(Int(r.threshold)) : String(r.threshold)
            text += "  \(r.kind): \(r.means) (\(threshold))\n"
        }

        return MotionGateReport(
            text: summary + text,
            summary: summary,
            failing: failing,
            allowed: allowedN,
            unused: unusedRows.count
        )
    }

    public static func evidence(cell: String, rec: MotionGateRecording, out: String?) {
        do {
            try writeEvidence(cell: cell, rec: rec, out: out, environment: ProcessInfo.processInfo.environment)
        } catch {
            preconditionFailure("Motion gate evidence: \(error)")
        }
    }

    static func writeEvidence(cell: String, rec: MotionGateRecording, out: String?, environment: [String: String]) throws {
        func spec(_ key: String) -> [Substring]? {
            guard let value = environment[key] else { return nil }
            let parts = value.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 2, parts[0].isEmpty || parts[0] == cell else { return nil }
            return parts
        }
        func index(_ text: Substring) -> Int? { UInt(text).flatMap(Int.init(exactly:)) }
        if let parts = spec("MOTION_GATE_DUMP") {
            let from = parts.count > 2 ? index(parts[2]) ?? 0 : 0
            let to = parts.count > 3 ? index(parts[3]) ?? Int.max : Int.max
            let dumped = MotionGateEvidence.dump(rec, filter: String(parts[1]), from: from, to: to)
            if let out {
                try Data(dumped.utf8).write(to: URL(fileURLWithPath: out + ".dump"), options: .runeOutput)
            } else {
                RuneStandardIO.error(dumped)
            }
        }
        if let parts = spec("MOTION_GATE_SHEET"), let at = index(parts[1]) {
            let path = out ?? FileManager.default.temporaryDirectory.appendingPathComponent("motion-gate").path
            let sheet = MotionGateEvidence.sheet(rec, at: at, focus: parts.count > 2 ? String(parts[2]) : "")
            try sheet.pngData().write(to: URL(fileURLWithPath: path + ".sheet.png"), options: .runeOutput)
        }
    }
}

public enum MotionGateEvidence {
    private static func paintLine(_ p: MotionGatePaint) -> String {
        var out = ""
        for ch in MotionGatePaintUtils.channels {
            let v = MotionGatePaintUtils.value(p, channel: ch.name)
            let quiet = (v == "none" || v == "0.0" || v == "#00000000") || (v.hasSuffix("00") && v.count == 9)
            if !quiet {
                out += " \(ch.name)=\(v)"
            }
        }
        out += " z=\(p.rank)"
        if p.intent != 0 {
            out += String(format: " intent=0x%x", p.intent)
        }
        if p.instant {
            out += " instant"
        }
        return out
    }

    public static func dump(_ rec: MotionGateRecording, filter: String, from: Int, to: Int) -> String {
        var out = ""
        for t in rec.tracks where filter.isEmpty || t.path.contains(filter) {
            out += "\(t.path)\n"
            for (j, pair) in t.frames.enumerated() where pair.0 >= from && pair.0 < to {
                let (k, s) = pair
                let instMark = (k < rec.instant.count && rec.instant[k]) ? " INSTANT" : ""
                let paintStr = (j < t.paint.count ? t.paint[j] : nil).map(paintLine) ?? ""
                let flags = String(s.flags, radix: 2)
                out += String(
                    format: "  %4d [%7.1f %7.1f %6.1f %6.1f] vis [%6.1f %6.1f %6.1f %6.1f] op %.3f sc %.3f %@%@%@\n",
                    k, s.rect[0], s.rect[1], s.rect[2], s.rect[3],
                    s.vis[0], s.vis[1], s.vis[2], s.vis[3],
                    s.op, s.scale, flags.count < 2 ? "0" + flags : flags, instMark, paintStr
                )
            }
        }
        return out
    }
}

extension MotionGateEvidence {
    /// A quarter-scale strip around the finding, with visible bounds and the focused track's paint.
    public static func sheet(_ rec: MotionGateRecording, at: Int, focus: String = "") -> Frame {
        let width = max(0, Int(rec.size.0 * 0.25))
        let height = max(0, Int(rec.size.1 * 0.25))
        let center = max(0, at)
        let start = min(rec.frames, max(0, center - 4))
        let end = min(rec.frames, min(center, Int.max - 5) + 5)
        let frames = start..<end
        let hot = rec.tracks.filter { !focus.isEmpty && $0.path.contains(focus) }
        let channels = (0..<MotionGatePaint.colorCount).filter { channel in
            hot.contains { t in frames.contains { k in (t.paintAt(k)?.colors[channel].a ?? 0) > 0.02 } }
        }
        let stride = width + 6
        let sheetWidth = frames.count * stride
        let sheetHeight = height + 4 + channels.count * 12
        var pixels = Array(repeating: SIMD4<UInt8>(16, 18, 22, 255), count: sheetWidth * sheetHeight)

        func encoded(_ r: Float, _ g: Float, _ b: Float) -> SIMD4<UInt8> {
            func byte(_ v: Float) -> UInt8 { UInt8((RefShader.linearToSRGB(v) * 255).rounded()) }
            return SIMD4(byte(r), byte(g), byte(b), 255)
        }
        for (column, frame) in frames.enumerated() {
            let x0 = column * stride
            if frame < rec.grids.count, let grid = rec.grids[frame] {
                for y in 0..<height {
                    let cy = Int(Float(y * 4) / MotionGateGrid.cellSize)
                    guard cy < grid.h else { continue }
                    for x in 0..<width {
                        let cx = Int(Float(x * 4) / MotionGateGrid.cellSize)
                        guard cx < grid.w else { continue }
                        let c = grid.color(cy * grid.w + cx)
                        pixels[y * sheetWidth + x0 + x] = encoded(c.r, c.g, c.b)
                    }
                }
            }
            if frame == at {
                for x in x0..<(x0 + width) { pixels[x] = SIMD4(255, 210, 80, 255) }
            }
            for track in rec.tracks {
                guard let snap = track.at(frame) else { continue }
                let x = snap.vis[0] * 0.25, y = snap.vis[1] * 0.25
                let w = snap.vis[2] * 0.25, h = snap.vis[3] * 0.25
                guard w >= 1, h >= 1 else { continue }
                let focused = !focus.isEmpty && track.path.contains(focus)
                let alpha = min(1, max(0, snap.op)) * (focused ? 1 : 0.5)
                let ink = focused ? SIMD3<Float>(255, 70, 70) : SIMD3<Float>(200, 205, 215)
                func plot(_ px: Float, _ py: Float) {
                    guard px < Float(width), py < Float(height), width > 0, height > 0 else { return }
                    let i = Int(max(0, py)) * sheetWidth + x0 + Int(max(0, px))
                    for c in 0..<3 {
                        pixels[i][c] = UInt8(Float(pixels[i][c]) * (1 - alpha) + ink[c] * alpha)
                    }
                }
                for i in 0..<Int(w) {
                    plot(x + Float(i), y)
                    plot(x + Float(i), y + h - 1)
                }
                for i in 0..<Int(h) {
                    plot(x, y + Float(i))
                    plot(x + w - 1, y + Float(i))
                }
            }
            guard let paint = hot.lazy.compactMap({ $0.paintAt(frame) }).first else { continue }
            for (row, channel) in channels.enumerated() {
                let top = height + 4 + row * 12
                let color = MotionGatePaintUtils.premulColor(paint.colors[channel])
                for y in 0..<10 {
                    for x in 0..<min(width, 80) {
                        let bg: Float = (x / 5 + y / 5).isMultiple(of: 2) ? 0 : 1
                        let c = MotionGatePaintUtils.overPremul(color, SIMD4(bg, bg, bg, 1))
                        pixels[(top + y) * sheetWidth + x0 + x] = encoded(c.x, c.y, c.z)
                    }
                }
            }
        }
        return Frame(width: sheetWidth, height: sheetHeight, rgba: pixels.withUnsafeBytes { Array($0) })
    }
}
