import Foundation

public enum ChaosStress {
    public static let bars: Int = 8
    public static let header: Float = 120.0
    public static let shuffle: Double = 2.0
    public static let wideEvery: Double = 1.7
    public static let wideShare: Int = 12
    public static let status: [String] = ["Idle", "Heat", "Cool", "Boost", "Eco", "Auto"]
    public static let hues: [Float] = [245.0, 200.0, 290.0, 165.0, 70.0]
    private static let aspect: Float = 1.5

    /// The wall's rectangle in window points, below the header.
    public static func area() -> (Float, Float, Float, Float) {
        let y = ChaosGrid.pad - 8.0 + header + ChaosGrid.gap
        return (ChaosGrid.pad, y, ChaosGrid.width - 2.0 * ChaosGrid.pad, ChaosGrid.height - ChaosGrid.pad - y)
    }

    public static func tint(_ hue: Float) -> Lch { lch(0.72, 0.15, hue) }
    public static func tintHi(_ hue: Float) -> Lch { lch(0.82, 0.12, hue) }
    public static func tintLo(_ hue: Float) -> Lch { lch(0.52, 0.16, hue) }
    public static func hotFill(_ hue: Float) -> Lch { lch(0.235, 0.035, hue) }
    public static func hotEdge(_ hue: Float) -> Lch { lch(0.72, 0.15, hue).alpha(0.55) }

    /// Line height for a type size, as both builds set it.
    public static func lh(_ size: Float) -> Float {
        (size * 1.3).rounded()
    }
}

public struct ChaosError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) {
        self.description = description
    }
}

/// How many controls the wall holds over time.
public enum ChaosLoad: Equatable, Sendable {
    case fixed(Int)
    case ramp(levels: [Int], hold: Double)

    /// From `from` to `to` controls, ×√2 a step (rounded), `to` last.
    public static func ramp(from: Int, to: Int, hold: Double) -> ChaosLoad {
        var levels: [Int] = []
        var n = Double(max(from, 1))
        while Int(n.rounded()) < to {
            levels.append(Int(n.rounded()))
            n *= 2.0.squareRoot()
        }
        levels.append(max(to, max(from, 1)))
        return .ramp(levels: levels, hold: hold)
    }

    /// `A:B`, as `--ramp` takes it.
    public static func parseRamp(_ spec: String, hold: Double) throws -> ChaosLoad {
        let parts = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw ChaosError("--ramp wants FROM:TO, got \(spec)")
        }
        func parseCount(_ s: Substring) throws -> Int {
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            guard let n = Int(trimmed), n >= 0 else {
                throw ChaosError("--ramp: not a count: \(s)")
            }
            return n
        }
        let a = try parseCount(parts[0])
        let b = try parseCount(parts[1])
        if a == 0 || b < a {
            throw ChaosError("--ramp wants 0 < FROM ≤ TO, got \(spec)")
        }
        return .ramp(from: a, to: b, hold: hold)
    }

    public var levels: [Int] {
        switch self {
        case .fixed(let n): return [n]
        case .ramp(let levels, _): return levels
        }
    }

    /// The level index at show time `t`.
    public func stepAt(_ t: Double) -> Int {
        switch self {
        case .fixed:
            return 0
        case .ramp(let levels, let hold):
            return min(Int(max(t - ChaosSchedule.start, 0.0) / hold), levels.count - 1)
        }
    }

    public func at(_ t: Double) -> Int {
        levels[stepAt(t)]
    }

    /// The show a ramp needs: every level held once. `nil` for a fixed load.
    public var duration: Double? {
        switch self {
        case .fixed: return nil
        case .ramp(let levels, let hold): return ChaosSchedule.start + Double(levels.count) * hold
        }
    }
}

/// One control at one moment.
public struct ChaosCell: Equatable, Sendable {
    public var id: UInt32
    /// x, y, w, h in window points.
    public var rect: [Float]
    public var wide: Bool
    public var hue: Float
    public var on: Bool
    public var hot: Bool
    public var bars: [Float]
    public var progress: Float
    public var status: String
    public var readingValue: Double

    public var name: String { "Zone \(id + 1)" }
    public var reading: String { String(format: "%.2f", readingValue) }
    public var percent: String { String(format: "%.0f%%", progress * 100.0) }
}

/// Every size inside a control, from the height of the wall's rows.
public struct ChaosMetrics: Equatable, Sendable {
    public var u: Float
    public var pad: Float
    public var gap: Float
    public var radius: Float
    public var name: Float
    public var reading: Float
    public var small: Float
    public var dot: Float
    public var barGap: Float
    public var barsH: Float
    public var footH: Float
    public var trackH: Float
    public var switchW: Float
    public var switchH: Float
    public var knob: Float
    public var shadowY: Float
    public var shadowBlur: Float

    public static func forHeight(_ h: Float) -> ChaosMetrics {
        let u = (min(max(h / 100.0, 0.25), 1.5) * 16.0).rounded() / 16.0
        let pad = 7.0 * u
        let gap = 4.0 * u
        let name = 11.0 * u
        let reading = 16.0 * u
        let small = 10.0 * u
        let footH = 12.0 * u
        let barsH = max(h - 2.0 * pad - 3.0 * gap - ChaosStress.lh(name) - ChaosStress.lh(reading) - footH, 2.0)
        return ChaosMetrics(
            u: u,
            pad: pad,
            gap: gap,
            radius: 12.0 * u,
            name: name,
            reading: reading,
            small: small,
            dot: 6.0 * u,
            barGap: 3.0 * u,
            barsH: barsH,
            footH: footH,
            trackH: 4.0 * u,
            switchW: 22.0 * u,
            switchH: 12.0 * u,
            knob: 10.0 * u,
            shadowY: 4.0 * u,
            shadowBlur: 12.0 * u
        )
    }
}

private func stressMix(_ seed: UInt64, _ id: UInt32, _ salt: UInt32, _ epoch: UInt64) -> UInt64 {
    var z = seed ^ (UInt64(id) &* 0x9e37_79b9_7f4a_7c15) ^ (UInt64(salt) << 40) ^ (epoch &* 0xd6e8_feb8_6659_fd93)
    z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
    z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
    return z ^ (z >> 31)
}

private func stressUnit(_ x: UInt64) -> Float {
    Float(x >> 40) / Float(UInt64(1) << 24)
}

private func stressEpoch(_ t: Double, _ every: Double, _ phase: Float) -> UInt64 {
    UInt64(floor(max(t / every + Double(phase), 0.0)))
}

/// The wall: its controls at the last `update(t:n:)`.
public struct ChaosWall: Sendable {
    private let seed: UInt64
    public private(set) var cells: [ChaosCell] = []
    private var order: [UInt32] = []
    private var orderEpoch: (UInt64, Int)?
    private var wide: [Bool] = []
    private var wideEpoch: (UInt64, Int)?
    public private(set) var metrics: ChaosMetrics = .forHeight(100.0)
    public private(set) var cols: Int = 1
    public private(set) var rows: Int = 1

    public init(seed: UInt64) {
        self.seed = seed
    }

    /// Moves the wall to show time `t` with `n` controls.
    public mutating func update(t: Double, n: Int) {
        if cells.count > n {
            cells.removeLast(cells.count - n)
        }
        while cells.count < n {
            let id = UInt32(cells.count)
            cells.append(ChaosCell(
                id: id,
                rect: [0, 0, 0, 0],
                wide: false,
                hue: 0,
                on: false,
                hot: false,
                bars: Array(repeating: 0, count: ChaosStress.bars),
                progress: 0,
                status: "",
                readingValue: 0
            ))
        }

        let oe = stressEpoch(t, ChaosStress.shuffle, 0.5)
        if orderEpoch?.0 != oe || orderEpoch?.1 != n {
            orderEpoch = (oe, n)
            order = (0..<UInt32(n)).sorted { stressMix(seed, $0, 1, oe) < stressMix(seed, $1, 1, oe) }
        }

        let we = stressEpoch(t, ChaosStress.wideEvery, 0.0)
        if wideEpoch?.0 != we || wideEpoch?.1 != n {
            wideEpoch = (we, n)
            let k = n / ChaosStress.wideShare
            var ids = Array(0..<UInt32(n))
            if k > 0 {
                ids.sort { stressMix(seed, $0, 2, we) < stressMix(seed, $1, 2, we) }
            }
            wide = Array(repeating: false, count: n)
            for id in ids.prefix(k) {
                wide[Int(id)] = true
            }
        }

        for idx in cells.indices {
            let id = cells[idx].id
            func h(_ salt: UInt32) -> Float { stressUnit(stressMix(seed, id, salt, 0)) }
            let eb = stressEpoch(t, 0.16 + 0.3 * Double(h(3)), h(4))
            var sum: Float = 0
            for j in 0..<ChaosStress.bars {
                let b = 0.1 + 0.9 * stressUnit(stressMix(seed, id, 100 + UInt32(j), eb))
                cells[idx].bars[j] = b
                sum += b
            }
            let level = sum / Float(ChaosStress.bars)
            cells[idx].hot = level > 0.6
            cells[idx].on = stressUnit(stressMix(seed, id, 5, stressEpoch(t, 0.7 + 1.2 * Double(h(6)), h(7)))) < 0.5
            let hueIdx = Int(stressMix(seed, id, 8, stressEpoch(t, 3.0, h(9))) % UInt64(ChaosStress.hues.count))
            cells[idx].hue = ChaosStress.hues[hueIdx]
            let progRaw = t * (0.05 + 0.25 * Double(h(10))) + Double(h(11))
            cells[idx].progress = Float(progRaw - floor(progRaw))
            let stIdx = Int(stressMix(seed, id, 12, stressEpoch(t, 1.1, h(13))) % UInt64(ChaosStress.status.count))
            cells[idx].status = ChaosStress.status[stIdx]
            cells[idx].readingValue = 20.0 + 980.0 * Double(h(14)) + t * (1.5 + 30.0 * Double(h(15)))
            cells[idx].wide = wide[Int(id)]
        }
        flow()
    }

    private mutating func flow() {
        let n = cells.count
        let (ax, ay, aw, ah) = ChaosStress.area()
        let aspect: Float = 1.5
        let slots = max(n + n / ChaosStress.wideShare, 1)
        let colsEst = Int((Float(slots) * (aw / ah) / aspect).squareRoot().rounded())
        let cols = min(max(colsEst, 1), slots)
        let rows = (slots + cols - 1) / cols
        let gap = min(max(10.0 * (40.0 / Float(slots)).squareRoot(), 3.0), 12.0)
        let cw = (aw - gap * Float(cols - 1)) / Float(cols)
        let ch = (ah - gap * Float(rows - 1)) / Float(rows)
        metrics = ChaosMetrics.forHeight(ch)
        self.cols = cols
        self.rows = rows

        var col = 0
        var row = 0
        for id in order {
            let idx = Int(id)
            let span = (cells[idx].wide && col + 2 <= cols) ? 2 : 1
            cells[idx].rect = [
                ax + Float(col) * (cw + gap),
                ay + Float(row) * (ch + gap),
                Float(span) * cw + Float(span - 1) * gap,
                ch,
            ]
            col += span
            if col >= cols {
                col = 0
                row += 1
            }
        }
    }
}
