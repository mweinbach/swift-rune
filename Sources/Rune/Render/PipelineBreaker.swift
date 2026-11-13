import Foundation

/// Optional Metal pipeline capabilities guarded by circuit breakers (`crates/rune/src/render/breaker.rs`).
public enum BreakerFeature: String, CaseIterable, Sendable, Hashable {
    case isolation = "LAYER_ISOLATION"
    case plusLighter = "PLUS_LIGHTER"
    case layerBlur = "LAYER_BLUR"

    public var label: String {
        switch self {
        case .isolation: return "layer isolation"
        case .plusLighter: return "plus_lighter"
        case .layerBlur: return "layer_blur"
        }
    }
}

/// Circuit breaker state for a single `BreakerFeature`.
public enum BreakerHealth: Sendable, Equatable {
    case untried
    case checking(generation: UInt64)
    case working
    case broken
}

/// Tracks driver/device pipeline rejections and enables clean fallbacks (`crates/rune/src/render/breaker.rs`).
///
/// - `.isolation` broken -> draw child primitives directly into parent target (skip offscreen layer isolation)
/// - `.plusLighter` broken -> fall back from additive blending to `.sourceOver`
/// - `.layerBlur` broken -> composite layer unblurred
public final class PipelineBreakers: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 1
    private var states: [BreakerFeature: BreakerHealth] = Dictionary(
        uniqueKeysWithValues: BreakerFeature.allCases.map { ($0, .untried) }
    )
    private var featureGenerations: [BreakerFeature: UInt64] = Dictionary(
        uniqueKeysWithValues: BreakerFeature.allCases.map { ($0, 1) }
    )
    private var forcedRefusals: Set<BreakerFeature> = []
    private var forcedBuildFailures: Set<BreakerFeature> = []

    public init() {}

    /// Current generation stamp (incremented on `shaderChanged()`).
    public var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    /// Current health for `feature`.
    public func health(for feature: BreakerFeature) -> BreakerHealth {
        lock.lock()
        defer { lock.unlock() }
        return states[feature] ?? .untried
    }

    /// True if `feature` has been marked `.broken` (or explicitly forced refused in tests).
    public func isBroken(_ feature: BreakerFeature) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return forcedRefusals.contains(feature) || states[feature] == .broken
    }

    /// True if `feature` is still allowed to run (`!isBroken(feature)`).
    public func isUsable(_ feature: BreakerFeature) -> Bool {
        !isBroken(feature)
    }

    /// Lists untried features and transitions them to `.checking(generation:)`.
    public func featuresNeedingCheck() -> [(feature: BreakerFeature, generation: UInt64)] {
        lock.lock()
        defer { lock.unlock() }
        var result: [(BreakerFeature, UInt64)] = []
        for feature in BreakerFeature.allCases where states[feature] == .untried {
            generation &+= 1
            let gen = generation
            states[feature] = .checking(generation: gen)
            featureGenerations[feature] = gen
            result.append((feature, gen))
        }
        return result
    }

    /// Starts a check for `feature`, returning its check generation token.
    public func beginCheck(_ feature: BreakerFeature) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        let gen = generation
        states[feature] = .checking(generation: gen)
        featureGenerations[feature] = gen
        return gen
    }

    /// Settles a check if and only if `generation` matches the active `.checking(generation:)` state.
    /// Returns `false` if a newer check or `shaderChanged()` superseded this generation (`a_late_answer_settles_only_its_own_check`).
    @discardableResult
    public func settle(_ feature: BreakerFeature, generation checkGen: UInt64, working: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard states[feature] == .checking(generation: checkGen) else {
            return false
        }
        states[feature] = working ? .working : .broken
        return true
    }

    /// Explicitly marks a feature broken or working at the current generation.
    public func mark(_ feature: BreakerFeature, broken: Bool) {
        lock.lock()
        states[feature] = broken ? .broken : .working
        lock.unlock()
    }

    /// Runs `body` under error-scoped breaker verification for `feature`.
    /// If `forcedRefusals.contains(feature)` or `body` throws, settles `.broken` and returns `nil`.
    public func checkingGpu<T>(_ feature: BreakerFeature, _ body: () throws -> T) -> T? {
        if isBroken(feature) {
            return nil
        }
        if health(for: feature) == .working && !shouldForceBuildFailureForTesting(feature) {
            do {
                return try body()
            } catch {
                mark(feature, broken: true)
                return nil
            }
        }
        let gen = beginCheck(feature)
        do {
            let value = try body()
            settle(feature, generation: gen, working: true)
            return value
        } catch {
            settle(feature, generation: gen, working: false)
            return nil
        }
    }

    /// Invalidates cached health across all features (for shader or driver updates).
    public func shaderChanged() {
        lock.lock()
        generation &+= 1
        for feature in BreakerFeature.allCases {
            states[feature] = .untried
            featureGenerations[feature] = generation
        }
        lock.unlock()
    }

    /// Test helper: forces `feature` to act as refused by the device.
    public func setForcedRefusalForTesting(_ feature: BreakerFeature, refused: Bool) {
        lock.lock()
        if refused {
            forcedRefusals.insert(feature)
            states[feature] = .broken
        } else {
            forcedRefusals.remove(feature)
            states[feature] = .untried
        }
        lock.unlock()
    }

    /// Test helper: forces Metal pipeline compilation for `feature` to attempt an invalid pixel format (`.rgba32Uint`),
    /// exercising real `makeRenderPipelineState` failure inside `checkingGpu`.
    public func setForcedBuildFailureForTesting(_ feature: BreakerFeature, failed: Bool) {
        lock.lock()
        if failed {
            forcedBuildFailures.insert(feature)
        } else {
            forcedBuildFailures.remove(feature)
        }
        generation &+= 1
        states[feature] = .untried
        featureGenerations[feature] = generation
        lock.unlock()
    }

    public func shouldForceBuildFailureForTesting(_ feature: BreakerFeature) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return forcedBuildFailures.contains(feature)
    }

    /// Clears all test refusals and resets every feature to `.untried`.
    public func resetForTesting() {
        lock.lock()
        forcedRefusals.removeAll()
        forcedBuildFailures.removeAll()
        generation &+= 1
        for feature in BreakerFeature.allCases {
            states[feature] = .untried
            featureGenerations[feature] = generation
        }
        lock.unlock()
    }
}
