import Foundation
import RuneMotion
import RuneRef

/// Describes why a frame could not run as a loop-only fast path (`window/loop_frame.rs`, `#1136`).
public enum LoopOnlyFallbackReason: String, Sendable, Equatable {
    case noEligibleLoops = "no-eligible-loops"
    case pendingCommit = "pending-commit"
    case otherMotionActive = "other-motion-active"
    case unsupportedLoopKind = "unsupported-loop-kind"
    case surfaceReconfigured = "surface-reconfigured"
    case reducedMotion = "reduced-motion"
    case noRetainedFrame = "no-retained-frame"
}

/// Recorded opacity-cycle dot instance eligible for loop-only patching (`runtime/paint/cycle.rs`, `#1136`).
public struct LoopOnlyCycleSlot: Sendable, Equatable {
    public var instanceIndex: Int
    public var nodeId: NodeId
    public var baseColor: Color
    public var inheritedAlpha: Float
    public var cycle: Cycle
    public var phaseOffset: Float
    public var rectPx: SIMD4<Float>
    public var srgbBlend: Bool

    public init(
        instanceIndex: Int,
        nodeId: NodeId,
        baseColor: Color,
        inheritedAlpha: Float,
        cycle: Cycle,
        phaseOffset: Float = 0,
        rectPx: SIMD4<Float>,
        srgbBlend: Bool
    ) {
        self.instanceIndex = instanceIndex
        self.nodeId = nodeId
        self.baseColor = baseColor
        self.inheritedAlpha = inheritedAlpha
        self.cycle = cycle
        self.phaseOffset = phaseOffset
        self.rectPx = rectPx
        self.srgbBlend = srgbBlend
    }

    /// Evaluates the patched fill color at `elapsed` seconds.
    public func fill(at elapsed: Double) -> SIMD4<Float> {
        let opacity = max(0, min(1, cycle.sample(at: elapsed + Double(phaseOffset)) * inheritedAlpha))
        let c = Color(r: baseColor.r, g: baseColor.g, b: baseColor.b, a: baseColor.a * opacity)
        return srgbBlend ? c.premulSRGB() : c.premul()
    }
}

/// Recorded horizontal opposing slide-shimmer window eligible for loop-only patching
/// (`runtime/paint/slide.rs`, `#1136`).
///
/// Paint and the loop-only step pose the sliding clip window from the same `anchorRectPx`, so
/// both paths produce identical clip edges and soft-fade parameters.
public struct LoopOnlySlideSlot: Sendable, Equatable {
    public var instanceIndices: Range<Int>
    public var nodeId: NodeId
    /// Anchor rectangle `[x0, y0, x1, y1]` in device pixels from which horizontal slide offset is measured.
    public var anchorRectPx: SIMD4<Float>
    /// Slide travel range `(fromPx, toPx)` along the horizontal axis.
    public var fromPx: Float
    public var toPx: Float
    public var duration: Double
    public var phaseOffset: Double
    public var softFadeLeftPx: Float
    public var softFadeRightPx: Float
    /// Outer ancestor clip `[x0, y0, x1, y1]` in device pixels.
    public var outerClipPx: SIMD4<Float>

    public init(
        instanceIndices: Range<Int>,
        nodeId: NodeId,
        anchorRectPx: SIMD4<Float>,
        fromPx: Float,
        toPx: Float,
        duration: Double,
        phaseOffset: Double = 0,
        softFadeLeftPx: Float = 0,
        softFadeRightPx: Float = 0,
        outerClipPx: SIMD4<Float> = NO_CLIP
    ) {
        self.instanceIndices = instanceIndices
        self.nodeId = nodeId
        self.anchorRectPx = anchorRectPx
        self.fromPx = fromPx
        self.toPx = toPx
        self.duration = duration
        self.phaseOffset = phaseOffset
        self.softFadeLeftPx = softFadeLeftPx
        self.softFadeRightPx = softFadeRightPx
        self.outerClipPx = outerClipPx
    }

    /// Computes the horizontal slide offset in device pixels at `elapsed` seconds.
    public func slideOffsetPx(at elapsed: Double) -> Float {
        guard duration > 0 else { return fromPx }
        let raw = (elapsed + phaseOffset).truncatingRemainder(dividingBy: duration)
        let wrapped = raw < 0 ? raw + duration : raw
        let u = Float(wrapped / duration)
        return fromPx + (toPx - fromPx) * u
    }

    /// Computes the posed horizontal clip `[x0, y0, x1, y1]` in device pixels (top/bottom snapped,
    /// horizontal edges gliding from `anchorRectPx`).
    public func clipRectPx(at elapsed: Double, snapHorizontal: Bool = false) -> SIMD4<Float> {
        let dx = slideOffsetPx(at: elapsed)
        let rawX0 = anchorRectPx.x + dx
        let rawX1 = anchorRectPx.z + dx
        let x0 = snapHorizontal ? rawX0.rounded() : rawX0
        let x1 = snapHorizontal ? rawX1.rounded() : rawX1
        let y0 = anchorRectPx.y.rounded()
        let y1 = anchorRectPx.w.rounded()
        return SIMD4<Float>(
            max(x0, outerClipPx.x),
            max(y0, outerClipPx.y),
            min(x1, outerClipPx.z),
            min(y1, outerClipPx.w)
        )
    }
}

/// Patched loop-only frame delta produced without running `poll`, view, layout, or full paint (`#1136`).
public struct LoopOnlyStepResult: Sendable, Equatable {
    public var patchedIndices: [Int]
    public var dirtyRectsPx: [SIMD4<Float>]
    public var changed: Bool

    public init(patchedIndices: [Int], dirtyRectsPx: [SIMD4<Float>], changed: Bool) {
        self.patchedIndices = patchedIndices
        self.dirtyRectsPx = dirtyRectsPx
        self.changed = changed
    }
}

/// Plan of eligible loop-only slots captured from the most recent ordinary frame (`#1136`).
public struct LoopOnlyPlan: Sendable, Equatable {
    public var cycleSlots: [LoopOnlyCycleSlot] = []
    public var slideSlots: [LoopOnlySlideSlot] = []
    public var ineligibleReason: LoopOnlyFallbackReason?

    public init(
        cycleSlots: [LoopOnlyCycleSlot] = [],
        slideSlots: [LoopOnlySlideSlot] = [],
        ineligibleReason: LoopOnlyFallbackReason? = nil
    ) {
        self.cycleSlots = cycleSlots
        self.slideSlots = slideSlots
        self.ineligibleReason = ineligibleReason
    }

    public var isEligible: Bool {
        ineligibleReason == nil && (!cycleSlots.isEmpty || !slideSlots.isEmpty)
    }

    /// Patches `instances` in place for `elapsed` seconds, returning changed instance indices and dirty pixel rects.
    public func apply(to instances: inout [RenderInstance], at elapsed: Double, snapSlideHorizontal: Bool = false) -> LoopOnlyStepResult {
        guard isEligible else {
            return LoopOnlyStepResult(patchedIndices: [], dirtyRectsPx: [], changed: false)
        }
        var patched: [Int] = []
        var dirty: [SIMD4<Float>] = []

        for slot in cycleSlots {
            guard instances.indices.contains(slot.instanceIndex) else { continue }
            let nextFill = slot.fill(at: elapsed)
            if instances[slot.instanceIndex].fill != nextFill {
                instances[slot.instanceIndex].fill = nextFill
                patched.append(slot.instanceIndex)
                dirty.append(slot.rectPx)
            }
        }

        for slot in slideSlots {
            let nextClip = slot.clipRectPx(at: elapsed, snapHorizontal: snapSlideHorizontal)
            var slotChanged = false
            for idx in slot.instanceIndices where instances.indices.contains(idx) {
                let prevClip = instances[idx].clip
                if prevClip != nextClip {
                    instances[idx].clip = nextClip
                    patched.append(idx)
                    if !slotChanged {
                        dirty.append(SIMD4<Float>(
                            min(prevClip.x, nextClip.x),
                            min(prevClip.y, nextClip.y),
                            max(prevClip.z, nextClip.z),
                            max(prevClip.w, nextClip.w)
                        ))
                        slotChanged = true
                    }
                }
            }
        }

        return LoopOnlyStepResult(patchedIndices: patched, dirtyRectsPx: dirty, changed: !patched.isEmpty)
    }
}

/// Differential harness for `RUNE_LOOP_CHECK=1` (instance comparison) and `RUNE_LOOP_CHECK=2` (pixel check),
/// matching `crates/rune/src/tooling/loop_check.rs` (`#1136`).
public struct LoopOnlyCheck: Sendable, Equatable {
    public enum Mode: Int, Sendable, Equatable {
        case off = 0
        case instances = 1
        case pixels = 2
    }

    public var mode: Mode
    public var compared: Int = 0
    public var differed: Int = 0
    public var skippedByReason: [LoopOnlyFallbackReason: Int] = [:]

    public init(mode: Mode) {
        self.mode = mode
    }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> LoopOnlyCheck {
        let raw = env["RUNE_LOOP_CHECK"].flatMap(Int.init) ?? 0
        return LoopOnlyCheck(mode: Mode(rawValue: raw) ?? .off)
    }

    public mutating func recordSkipped(_ reason: LoopOnlyFallbackReason) {
        skippedByReason[reason, default: 0] += 1
    }

    /// Compares a loop-only patched instance array against the full ordinary frame's instances.
    /// Returns `true` when bit-identical.
    @discardableResult
    public mutating func compareInstances(stepped: [RenderInstance], ordinary: [RenderInstance]) -> Bool {
        compared += 1
        let same = stepped.count == ordinary.count && zip(stepped, ordinary).allSatisfy { a, b in
            a.rect == b.rect && a.radii == b.radii && a.fill == b.fill && a.border == b.border
                && a.params == b.params && a.uv == b.uv && a.clip == b.clip && a.fade == b.fade
        }
        if !same { differed += 1 }
        return same
    }

    /// Exit code 3 when `RUNE_LOOP_CHECK` is active and either no step was compared or any differed (`#1136`).
    public var failedExitCode: Int32? {
        guard mode != .off else { return nil }
        return (compared == 0 || differed > 0) ? 3 : nil
    }
}
