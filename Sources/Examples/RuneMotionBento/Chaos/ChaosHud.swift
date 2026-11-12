import Foundation

public enum ChaosHudConstants {
    public static let budget120: Float = 1000.0 / 120.0
    public static let budget60: Float = 1000.0 / 60.0
    public static let graph: Int = 120
    public static let graphMax: Float = 40.0
    public static let readout: Int = 15
}

/// 0 within the 120 Hz budget, 1 within 60 Hz, 2 over.
public func chaosGrade(_ ms: Float) -> Int {
    if ms <= ChaosHudConstants.budget120 { return 0 }
    if ms <= ChaosHudConstants.budget60 { return 1 }
    return 2
}

private func hudPercentile(_ values: [Float], _ p: Float) -> Float {
    guard !values.isEmpty else { return 0.0 }
    let s = values.sorted()
    let idx = Int((Float(s.count - 1) * p).rounded())
    return s[idx]
}

public struct ChaosReplay: Sendable {
    private let samples: [(Float, Float)]

    public init(samples: [(Float, Float)]) {
        self.samples = samples.sorted { $0.0 < $1.0 }
    }

    public static func load(path: String) throws -> ChaosReplay {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var samples: [(Float, Float)] = []
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 3,
                  let t = Float(parts[0]),
                  let ms = Float(parts[2]),
                  t.isFinite else {
                continue
            }
            samples.append((t, ms))
        }
        return ChaosReplay(samples: samples)
    }

    public func until(_ t: Double) -> ArraySlice<(Float, Float)> {
        let limit = Float(t) + 1e-4
        let endIdx = samples.firstIndex(where: { $0.0 > limit }) ?? samples.endIndex
        return samples[..<endIdx]
    }
}

public struct ChaosReadout: Equatable, Sendable {
    public var graph: [Float] = []
    public var ms: Float = 0.0
    public var p95: Float = 0.0
    public var fps: Float = 0.0
    public var missed: UInt32 = 0
    public var source: String = ""

    private static func of(_ values: [Float]) -> ChaosReadout {
        let graph = Array(values.suffix(ChaosHudConstants.graph))
        let ms = hudPercentile(Array(graph.suffix(ChaosHudConstants.readout)), 0.5)
        let p95 = hudPercentile(graph, 0.95)
        return ChaosReadout(graph: graph, ms: ms, p95: p95)
    }

    public static func replay(_ r: ChaosReplay, at t: Double) -> ChaosReadout {
        var out = of(r.until(t).map(\.1))
        let refreshes = out.graph.reduce(UInt32(0)) { acc, ms in
            acc + UInt32(max(1.0, ceilf(ms / ChaosHudConstants.budget120)))
        }
        out.missed = refreshes > UInt32(out.graph.count) ? refreshes - UInt32(out.graph.count) : 0
        out.fps = refreshes > 0 ? 120.0 * Float(out.graph.count) / Float(refreshes) : 0.0
        out.source = "measured headless · live pending"
        return out
    }

    public static func live(_ m: ChaosMeter) -> ChaosReadout {
        var out = of(m.tail(ChaosHudConstants.graph).map(\.1))
        let recent = m.recent()
        out.fps = Float(recent.fps)
        out.missed = UInt32(recent.dropped)
        out.source = "live window"
        return out
    }

    public var big: String {
        String(format: "%.1f ms", ms)
    }

    public var detail: String {
        String(format: "build + layout + paint · p95 %.1f", p95)
    }

    public var rate: String {
        if source == "live window" {
            return String(format: "%.0f fps · missed %u", fps, missed)
        }
        return String(format: "≈ %.0f fps at 120 Hz · %u missed / s", fps, missed)
    }
}
