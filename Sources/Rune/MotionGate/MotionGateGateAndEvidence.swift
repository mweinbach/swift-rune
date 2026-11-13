import Foundation

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

public struct MotionGateReport: Sendable {
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
        let filtered = cells.enumerated().filter { filter.isEmpty || $0.element.0.contains(filter) }
        return filtered.map { _, pair in
            let (name, job) = pair
            let rec = job()
            evidence(cell: name, rec: rec, out: ProcessInfo.processInfo.environment["MOTION_GATE_OUT"])
            return MotionGateCell(
                name: name,
                findings: motionGateCheck(rec),
                frames: rec.frames,
                skipped: rec.frames < 10
            )
        }
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
            text += "  \(r.kind): \(r.means) (\(r.threshold))\n"
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
        let env = ProcessInfo.processInfo.environment
        if let spec = env["MOTION_GATE_DUMP"] {
            let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 2, (parts[0].isEmpty || parts[0] == cell) {
                let from = parts.count > 2 ? (Int(parts[2]) ?? 0) : 0
                let to = parts.count > 3 ? (Int(parts[3]) ?? Int.max) : Int.max
                let dumped = MotionGateEvidence.dump(rec, filter: parts[1], from: from, to: to)
                if let out {
                    try? dumped.write(toFile: "\(out).dump", atomically: true, encoding: .utf8)
                }
            }
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
                out += String(
                    format: "  %4d [%7.1f %7.1f %6.1f %6.1f] vis [%6.1f %6.1f %6.1f %6.1f] op %.3f sc %.3f %02x%@%@\n",
                    k, s.rect[0], s.rect[1], s.rect[2], s.rect[3],
                    s.vis[0], s.vis[1], s.vis[2], s.vis[3],
                    s.op, s.scale, s.flags, instMark, paintStr
                )
            }
        }
        return out
    }
}
