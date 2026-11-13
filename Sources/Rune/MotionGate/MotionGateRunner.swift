import Foundation
import RuneMotion
#if canImport(simd)
import simd
#endif

// MARK: - El Motion-Gate Modifiers & Runtime Telemetry Bridge

private enum MotionGateExtraKey {
    static let instantChanges = "motionGate.instantChanges"
    static let motionIntent = "motionGate.motionIntent"
    static let ownMotionNone = "motionGate.ownMotionNone"
    static let ownBlurNone = "motionGate.ownBlurNone"
    static let loopSpec = "motionGate.loopSpec"
    static let sequenceSpec = "motionGate.sequenceSpec"
    static let growingRow = "motionGate.inGrowingRow"
    static let revealing = "motionGate.revealing"
}

extension El {
    /// Marks this element's changes as landing at once by design (`El::instant_changes`).
    public func instantChanges(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.runtimeExtras[MotionGateExtraKey.instantChanges] = enabled
        return copy
    }

    /// Marks deliberate authored motion traits (`El::motion_intent`), inherited by descendants.
    public func motionIntent(_ intent: MotionIntent) -> Self {
        var copy = self
        copy.runtimeExtras[MotionGateExtraKey.motionIntent] = intent.rawValue
        return copy
    }

    /// Authored element motion spring (`El::motion`), recording whether `Spring.none` was written directly.
    public func motion(_ spring: Spring) -> Self {
        var copy = self
        copy.styleSpring = spring
        copy.layoutAnim = LayoutAnim(spring: spring)
        if spring == .none {
            copy.runtimeExtras[MotionGateExtraKey.ownMotionNone] = true
        }
        return copy
    }

    /// Theme/token motion spring (`El::token_motion`): settles instantly when `.none` without authoring an own override.
    public func tokenMotion(_ spring: Spring) -> Self {
        var copy = self
        copy.styleSpring = spring
        copy.layoutAnim = LayoutAnim(spring: spring)
        return copy
    }

    /// Authored blur spring (`El::blur_motion`), recording whether `Spring.none` was written directly.
    public func blurMotion(_ spring: Spring) -> Self {
        var copy = self
        copy.runtimeExtras[MotionGateExtraKey.ownBlurNone] = (spring == .none)
        return copy
    }

    /// Attaches a periodic `LoopSpec` (`El::looping`) so `MotionGate` tracks its continuous phase.
    public func looping(_ spec: LoopSpec) -> Self {
        var copy = self
        copy.runtimeExtras[MotionGateExtraKey.loopSpec] = spec
        return copy
    }

    /// Attaches a finite `MotionSequence` (`El::sequence`) so `MotionGate` tracks its 0..1 phase.
    public func sequence(_ seq: MotionSequence) -> Self {
        var copy = self
        copy.runtimeExtras[MotionGateExtraKey.sequenceSpec] = seq
        return copy
    }
}

/// Per-Runtime virtual clock & motion-gate recording state without modifying `Runtime`'s stored properties.
private final class RuntimeMotionTelemetryStore: @unchecked Sendable {
    let lock = NSLock()
    var table: [ObjectIdentifier: RuntimeMotionTelemetry] = [:]
}

private final class RuntimeMotionTelemetry: @unchecked Sendable {
    private static let store = RuntimeMotionTelemetryStore()

    var virtualTime: Double = 0.0
    var lastCommitCount: Int = 0
    var commitWhy: UInt16 = 0
    var loopTracks: [String: (LoopTrack, LoopSpec)] = [:]
    var seqStarts: [String: (Double, MotionSequence)] = [:]
    var cachedGrid: (Int, MotionGateGrid)? = nil

    static func of<S>(_ rt: Runtime<S>) -> RuntimeMotionTelemetry {
        let id = ObjectIdentifier(rt)
        store.lock.lock()
        defer { store.lock.unlock() }
        if let existing = store.table[id] { return existing }
        let created = RuntimeMotionTelemetry()
        store.table[id] = created
        return created
    }

    static func release<S>(_ rt: Runtime<S>) {
        let id = ObjectIdentifier(rt)
        store.lock.lock()
        store.table.removeValue(forKey: id)
        store.lock.unlock()
    }
}

// MARK: - Headless Motion Gate Driver (`motion_gate::Run`, `motion_gate::Sampler`)

public final class MotionGateSampler: @unchecked Sendable {
    public var rec: MotionGateRecording

    public init<S>(runtime rt: Runtime<S>, hz: Double = 120.0) {
        self.rec = MotionGateRecording(size: (rt.viewport.x, rt.viewport.y), hz: hz)
    }

    public func input(_ what: String) {
        rec.input(what)
    }

    public func before<S>(_ rt: Runtime<S>) {
        RuntimeMotionTelemetry.of(rt).commitWhy = 0
    }

    public func frame<S>(_ rt: Runtime<S>, awake: Bool) {
        rec.awake.append(awake)
        MotionGateSampleHelper.sample(rt, rec: rec, gridOverride: nil)
    }
}

public final class MotionGateRun<S>: @unchecked Sendable {
    public var rt: Runtime<S>
    public var rec: MotionGateRecording
    public let dt: Double
    private var drawPixels: ((Runtime<S>) -> (Int, Int, [UInt8])?)?

    public init(_ rt: Runtime<S>, hz: Double = 120.0) {
        self.rt = rt
        let tel = RuntimeMotionTelemetry.of(rt)
        tel.virtualTime = 0.0
        _ = rt.renderFrame(at: 0.0)
        tel.lastCommitCount = rt.viewCommitCount
        self.rec = MotionGateRecording(size: (rt.viewport.x, rt.viewport.y), hz: hz)
        self.dt = 1.0 / hz
    }

    deinit {
        RuntimeMotionTelemetry.release(rt)
    }

    public func pixels(_ draw: @escaping (Runtime<S>) -> (Int, Int, [UInt8])?) {
        self.drawPixels = draw
    }

    public func idle(_ secs: Double) {
        let steps = Int((secs / dt).rounded())
        let tel = RuntimeMotionTelemetry.of(rt)
        for _ in 0..<steps {
            tel.virtualTime += dt
            _ = rt.renderFrame(at: tel.virtualTime)
        }
        tel.lastCommitCount = rt.viewCommitCount
    }

    public func step() {
        let tel = RuntimeMotionTelemetry.of(rt)
        let commitsBefore = rt.viewCommitCount
        tel.virtualTime += dt
        _ = rt.renderFrame(at: tel.virtualTime)
        if rt.viewCommitCount > commitsBefore && tel.commitWhy == 0 {
            tel.commitWhy |= CommitWhy.dirty
        }
        tel.lastCommitCount = rt.viewCommitCount
        rec.awake.append(rt.isAnimating)
        let drawn = drawPixels?(rt).map { (w, h, rgba) in
            MotionGateGrid.fromPixels(rgba, pw: w, ph: h, size: rec.size)
        }
        MotionGateSampleHelper.sample(rt, rec: rec, gridOverride: drawn)
    }

    public func stepN(_ n: Int) {
        for _ in 0..<n { step() }
    }

    public func play(_ secs: Double) {
        stepN(Int((secs / dt).rounded()))
    }

    public func act(_ what: String, _ f: (Runtime<S>) -> Void) {
        let tel = RuntimeMotionTelemetry.of(rt)
        rec.input(what)
        tel.commitWhy |= CommitWhy.input
        f(rt)
        step()
    }

    public func actUpdate(_ what: String, _ body: (_ state: inout S, _ tx: inout Tx) -> Void) {
        let tel = RuntimeMotionTelemetry.of(rt)
        rec.input(what)
        tel.commitWhy |= CommitWhy.input
        var requestedInstant = false
        rt.update(at: tel.virtualTime) { s, tx in
            body(&s, &tx)
            requestedInstant = tx.settleRequested
        }
        if requestedInstant {
            tel.commitWhy |= CommitWhy.instant
        }
        step()
    }

    public func update(_ body: (_ state: inout S, _ tx: inout Tx) -> Void) {
        let tel = RuntimeMotionTelemetry.of(rt)
        var requestedInstant = false
        rt.update(at: tel.virtualTime) { s, tx in
            body(&s, &tx)
            requestedInstant = tx.settleRequested
        }
        if requestedInstant {
            tel.commitWhy |= CommitWhy.instant
        }
    }

    public func quiet() {
        rec.quietFrom = rec.frames
    }

    public static func tap(_ rt: Runtime<S>, key: String) {
        guard let el = rt.element(byKey: key) else {
            fatalError("MotionGateRun.tap: no element with key '\(key)'")
        }
        let cx = el.rect[0] + el.rect[2] * 0.5
        let cy = el.rect[1] + el.rect[3] * 0.5
        let tel = RuntimeMotionTelemetry.of(rt)
        let pos = Vec2(cx, cy)
        rt.pointerMove(to: pos, at: tel.virtualTime)
        rt.pointerDown(at: pos, at: tel.virtualTime)
        rt.pointerUp(at: pos, at: tel.virtualTime)
    }

    public func finish() -> [MotionGateFinding] {
        motionGateCheck(rec)
    }

    public func playAndCheck(_ secs: Double = 1.0) -> [MotionGateFinding] {
        play(secs)
        return finish()
    }
}

private enum MotionGateSampleHelper {
    static func sample<S>(_ rt: Runtime<S>, rec: MotionGateRecording, gridOverride: MotionGateGrid?) {
        let tel = RuntimeMotionTelemetry.of(rt)
        let why = tel.commitWhy
        tel.commitWhy = 0
        rec.commits(scrolling: false, why: why)

        let els = rt.elements()
        let now = tel.virtualTime

        var nodeByPath: [String: Runtime<S>.FlatNode] = [:]
        for n in rt.flatNodes {
            nodeByPath[n.path] = n
        }

        // Clean stale loop/sequence entries
        let activePaths = Set(els.map(\.path))
        tel.loopTracks = tel.loopTracks.filter { activePaths.contains($0.key) }
        tel.seqStarts = tel.seqStarts.filter { activePaths.contains($0.key) }

        var metas: [ElementMotionMeta] = []
        var paints: [MotionGateRecording.PaintKey: MotionGatePaint] = [:]
        metas.reserveCapacity(els.count)

        var rankCounter: UInt32 = 1
        var inheritedIntent = Array(repeating: UInt16(0), count: els.count)
        var inheritedInstant = Array(repeating: false, count: els.count)

        for (i, e) in els.enumerated() {
            let pIntent = e.parentIndex.flatMap { p in (p >= 0 && p < i) ? inheritedIntent[p] : nil } ?? 0
            let pInstant = e.parentIndex.flatMap { p in (p >= 0 && p < i) ? inheritedInstant[p] : nil } ?? false
            let node = nodeByPath[e.path]
            let el = node?.el

            let ownIntent = (el?.runtimeExtras[MotionGateExtraKey.motionIntent] as? UInt16) ?? 0
            let totalIntent = pIntent | ownIntent
            inheritedIntent[i] = totalIntent

            let ownInstant = (el?.runtimeExtras[MotionGateExtraKey.instantChanges] as? Bool) ?? false
            let totalInstant = pInstant || ownInstant
            inheritedInstant[i] = totalInstant

            var phase: Double? = nil
            if let loopSpec = el?.runtimeExtras[MotionGateExtraKey.loopSpec] as? LoopSpec {
                if let existing = tel.loopTracks[e.path], existing.1 == loopSpec {
                    phase = existing.0.phase(at: now)
                } else {
                    let track = LoopTrack(spec: loopSpec, now: now)
                    tel.loopTracks[e.path] = (track, loopSpec)
                    phase = track.phase(at: now)
                }
            } else if let seq = el?.runtimeExtras[MotionGateExtraKey.sequenceSpec] as? MotionSequence {
                let t0: Double
                if let existing = tel.seqStarts[e.path], existing.1 == seq {
                    t0 = existing.0
                } else {
                    t0 = now
                    tel.seqStarts[e.path] = (t0, seq)
                }
                let elapsed = max(0.0, now - t0 - seq.delay)
                let dur = max(1e-6, seq.duration)
                phase = min(1.0, elapsed / dur)
            }

            let meta = ElementMotionMeta(
                scrolling: false,
                inGrowingRow: (el?.runtimeExtras[MotionGateExtraKey.growingRow] as? Bool) ?? false,
                revealing: (el?.runtimeExtras[MotionGateExtraKey.revealing] as? Bool) ?? false,
                liveIntent: totalIntent,
                virtualExtent: false,
                loopPhase: phase
            )
            metas.append(meta)

            let ownMotionNone = (el?.runtimeExtras[MotionGateExtraKey.ownMotionNone] as? Bool) ?? false
            let ownBlurNone = el?.runtimeExtras[MotionGateExtraKey.ownBlurNone] as? Bool
            let atOnce = MotionGatePaintUtils.atOnceBits(motion: ownMotionNone, blur: ownBlurNone)

            var colors = Array(repeating: Color.transparent, count: MotionGatePaint.colorCount)
            colors[MotionGatePaint.cFill] = e.fill
            colors[MotionGatePaint.cBorder] = el?.borderColor ?? .transparent
            colors[MotionGatePaint.cText] = e.textColor ?? .transparent
            colors[MotionGatePaint.cShadow] = el?.shadows.first?.color ?? .transparent
            if let lg = el?.runtimeExtras[RenderExtrasKey.linearGradient] as? RenderLinearGradientSpec {
                colors[MotionGatePaint.cGradient] = lg.stops.first?.color ?? .transparent
            }
            colors[MotionGatePaint.cOutline] = el?.focusRingColor ?? .transparent

            var sizes = Array(repeating: Float(0), count: MotionGatePaint.sizeCount)
            sizes[MotionGatePaint.sRadius] = e.radius
            sizes[MotionGatePaint.sBorder] = el?.borderWidth ?? 0
            sizes[MotionGatePaint.sBlur] = e.blur
            sizes[MotionGatePaint.sBackdrop] = el?.backdropBlur ?? 0
            sizes[MotionGatePaint.sShadow] = el?.shadows.first?.blur ?? 0

            let gradEnd = (el?.runtimeExtras[RenderExtrasKey.linearGradient] as? RenderLinearGradientSpec)?.stops.last?.color ?? .transparent
            let effData = (el?.runtimeExtras[RenderExtrasKey.effectSpec] as? RenderEffectSpec)?.data

            rankCounter &+= 1
            let paint = MotionGatePaint(
                colors: colors,
                sizes: sizes,
                gradientEnd: gradEnd,
                effect: effData,
                image: nil,
                rank: rankCounter,
                intent: totalIntent,
                instant: totalInstant,
                atOnce: atOnce,
                pointer: SIMD2<Float>(e.hover, e.press)
            )
            paints[MotionGateRecording.PaintKey(path: e.path, exiting: e.exiting)] = paint
        }

        rec.sampleWith(els, meta: metas, paints: paints)

        let grid: MotionGateGrid
        if let gridOverride {
            grid = gridOverride
        } else {
            let rf = rt.renderFrame(at: now)
            grid = MotionGateGrid.rasterize(rf.instances, size: rec.size, scale: rt.pixelScale)
        }
        rec.setGrid(grid)
        rec.tips.append(nil)
    }
}
