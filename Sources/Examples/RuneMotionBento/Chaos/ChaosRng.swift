import Foundation

/// SplitMix64: tiny, fast and identical on every platform, so a seed names one show everywhere.
public struct ChaosRng: Equatable, Sendable {
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        self.state = seed ^ 0x9e37_79b9_7f4a_7c15
    }

    public mutating func nextU64() -> UInt64 {
        state = state &+ 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func f64() -> Double {
        Double(nextU64() >> 11) / Double(UInt64(1) << 53)
    }

    /// Uniform in [lo, hi).
    public mutating func range(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * f64()
    }

    public mutating func rangef(_ lo: Float, _ hi: Float) -> Float {
        Float(range(Double(lo), Double(hi)))
    }

    /// Uniform in 0..<n.
    public mutating func below(_ n: Int) -> Int {
        min(Int(f64() * Double(n)), max(0, n - 1))
    }

    /// An index into `weights`, chosen in proportion to them.
    public mutating func weighted(_ weights: [UInt32]) -> Int {
        let total = weights.reduce(UInt32(0), &+)
        var pick = UInt32(f64() * Double(total))
        for (i, w) in weights.enumerated() {
            if pick < w {
                return i
            }
            pick &-= w
        }
        return weights.count - 1
    }
}
