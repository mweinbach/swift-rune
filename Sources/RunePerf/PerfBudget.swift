import Foundation

/// Performance budget thresholds for frame timing and memory usage.
public struct PerfBudget: Sendable, Equatable {
    public var maxP50Ms: Double?
    public var maxP95Ms: Double?
    public var maxP99Ms: Double?
    public var maxMaxMs: Double?
    public var maxResidentBytes: UInt64?
    public var maxFootprintBytes: UInt64?
    public var maxAllocatedBytesPerFrame: UInt64?

    public init(
        maxP50Ms: Double? = nil,
        maxP95Ms: Double? = nil,
        maxP99Ms: Double? = nil,
        maxMaxMs: Double? = nil,
        maxResidentBytes: UInt64? = nil,
        maxFootprintBytes: UInt64? = nil,
        maxAllocatedBytesPerFrame: UInt64? = nil
    ) {
        self.maxP50Ms = maxP50Ms
        self.maxP95Ms = maxP95Ms
        self.maxP99Ms = maxP99Ms
        self.maxMaxMs = maxMaxMs
        self.maxResidentBytes = maxResidentBytes
        self.maxFootprintBytes = maxFootprintBytes
        self.maxAllocatedBytesPerFrame = maxAllocatedBytesPerFrame
    }

    /// Evaluates `stats` and `usage` against this budget, returning any violations.
    public func evaluate(
        stats: PercentileStats? = nil,
        usage: ProcessUsage? = nil,
        frames: [FrameSample] = []
    ) -> [BudgetViolation] {
        var violations: [BudgetViolation] = []

        if let stats {
            if let limit = maxP50Ms, stats.p50 > limit {
                violations.append(BudgetViolation(metric: "p50_ms", actual: stats.p50, limit: limit))
            }
            if let limit = maxP95Ms, stats.p95 > limit {
                violations.append(BudgetViolation(metric: "p95_ms", actual: stats.p95, limit: limit))
            }
            if let limit = maxP99Ms, stats.p99 > limit {
                violations.append(BudgetViolation(metric: "p99_ms", actual: stats.p99, limit: limit))
            }
            if let limit = maxMaxMs, stats.max > limit {
                violations.append(BudgetViolation(metric: "max_ms", actual: stats.max, limit: limit))
            }
        }

        if let usage {
            if let limit = maxResidentBytes, usage.residentBytes > limit {
                violations.append(
                    BudgetViolation(
                        metric: "resident_bytes",
                        actual: Double(usage.residentBytes),
                        limit: Double(limit)
                    )
                )
            }
            if let limit = maxFootprintBytes,
               let footprint = usage.footprintBytes,
               footprint > limit {
                violations.append(
                    BudgetViolation(
                        metric: "footprint_bytes",
                        actual: Double(footprint),
                        limit: Double(limit)
                    )
                )
            }
        }

        if let limit = maxAllocatedBytesPerFrame {
            if let maxAlloc = frames.compactMap(\.allocatedBytes).max(), maxAlloc > limit {
                violations.append(
                    BudgetViolation(
                        metric: "max_allocated_bytes_per_frame",
                        actual: Double(maxAlloc),
                        limit: Double(limit)
                    )
                )
            }
        }

        return violations
    }

    /// Throws `PerfBudgetError.violated` if any threshold is exceeded.
    public func assertWithinBudget(
        stats: PercentileStats? = nil,
        usage: ProcessUsage? = nil,
        frames: [FrameSample] = []
    ) throws {
        let violations = evaluate(stats: stats, usage: usage, frames: frames)
        if !violations.isEmpty {
            throw PerfBudgetError.violated(violations)
        }
    }
}

/// A single performance budget violation.
public struct BudgetViolation: Sendable, Equatable, CustomStringConvertible {
    public var metric: String
    public var actual: Double
    public var limit: Double

    public init(metric: String, actual: Double, limit: Double) {
        self.metric = metric
        self.actual = actual
        self.limit = limit
    }

    public var description: String {
        "\(metric): actual \(actual) exceeded budget \(limit)"
    }
}

/// Error thrown when `PerfBudget.assertWithinBudget` fails.
public enum PerfBudgetError: Error, Sendable, Equatable, CustomStringConvertible {
    case violated([BudgetViolation])

    public var description: String {
        switch self {
        case .violated(let violations):
            return violations.map(\.description).joined(separator: "; ")
        }
    }
}
