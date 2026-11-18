import Foundation
import RuneMotion
#if canImport(simd)
import simd
#endif

// MARK: - El Motion-Gate Modifiers & Runtime Telemetry Bridge

internal enum MotionGateExtraKey {
    static let instantChanges = "motionGate.instantChanges"
    static let motionIntent = "motionGate.motionIntent"
    static let ownMotionNone = "motionGate.ownMotionNone"
    static let growingRow = "motionGate.inGrowingRow"
    static let revealing = "motionGate.revealing"
}

extension El {
    /// Marks or clears `El::instant_changes` when passing an explicit boolean; zero-arg `.instantChanges()` lives on `El`.
    public func instantChanges(_ enabled: Bool) -> Self {
        var copy = self
        copy.hasInstantChanges = enabled
        copy.runtimeExtras[MotionGateExtraKey.instantChanges] = enabled
        return copy
    }

    /// Marks deliberate authored motion traits (`El::motion_intent`), inherited by descendants.
    public func motionIntent(_ intent: MotionIntent) -> Self {
        var copy = self
        if !intent.isEmpty {
            let bits = copy.runtimeExtras[MotionGateExtraKey.motionIntent] as? UInt16 ?? 0
            copy.runtimeExtras[MotionGateExtraKey.motionIntent] = bits | intent.rawValue
        }
        return copy
    }

    /// Authored element motion spring (`El::motion`), recording whether `Spring.none` was written directly.
    public func motion(_ spring: Spring) -> Self {
        var copy = self
        copy.styleSpring = spring
        copy.layoutAnim = LayoutAnim(spring: spring)
        if spring == .none {
            copy.runtimeExtras[MotionGateExtraKey.ownMotionNone] = true
        } else if copy.runtimeExtras[MotionGateExtraKey.ownMotionNone] != nil {
            copy.runtimeExtras.removeValue(forKey: MotionGateExtraKey.ownMotionNone)
        }
        return copy
    }

    /// Theme/token motion spring (`El::token_motion`): settles instantly when `.none` without authoring an own override.
    public func tokenMotion(_ spring: Spring) -> Self {
        var copy = self
        copy.styleSpring = spring
        copy.layoutAnim = LayoutAnim(spring: spring)
        if copy.runtimeExtras[MotionGateExtraKey.ownMotionNone] != nil {
            copy.runtimeExtras.removeValue(forKey: MotionGateExtraKey.ownMotionNone)
        }
        return copy
    }

    /// Override the curve used when this element's blur radius changes.
    public func blurMotion(_ spring: Spring) -> Self {
        blurMotion(Curve.from(spring))
    }

    public func blurMotion(_ curve: Curve) -> Self {
        blurMotion(Anim<Blur>(curve: curve))
    }

    @_disfavoredOverload public func blurMotion(_ animation: Anim<Blur>) -> Self {
        var copy = self
        copy.blurMotionOverride = BlurMotion(animation)
        return copy
    }
}

private final class RuntimeMotionTelemetry: @unchecked Sendable {
    var virtualTime: Double = 0
    var commitWhy: UInt16 = 0
    var lastScrollOffsets: [String: Vec2] = [:]
    var cachedGrid: (instances: [RenderInstance], glyphs: MotionGateRasterGlyphs, scale: Float, grid: MotionGateGrid)?
}

// MARK: - Headless Motion Gate Driver (`motion_gate::Run`, `motion_gate::Sampler`)

public final class MotionGateSampler: @unchecked Sendable {
    public var rec: MotionGateRecording
    private let telemetry = RuntimeMotionTelemetry()

    public init<S>(runtime rt: Runtime<S>, hz: Double = 120.0) {
        rt.motionRasterGlyphs = MotionGateRasterGlyphs()
        self.rec = MotionGateRecording(size: (rt.viewport.x, rt.viewport.y), hz: hz)
    }

    public func input(_ what: String) {
        rec.input(what)
    }

    public func before<S>(_ rt: Runtime<S>) {
        rt.commitWhy = 0
    }

    public func frame<S>(_ rt: Runtime<S>, awake: Bool, renderFrame: RenderFrame? = nil) {
        rec.awake.append(awake)
        MotionGateSampleHelper.sample(rt, rec: rec, telemetry: telemetry, renderFrame: renderFrame, gridOverride: nil)
    }
}

public final class MotionGateRun<S>: @unchecked Sendable {
    public var rt: Runtime<S>
    public var rec: MotionGateRecording
    private let telemetry = RuntimeMotionTelemetry()
    public let dt: Double
    private var drawPixels: ((Runtime<S>) -> (Int, Int, [UInt8])?)?

    public init(_ rt: Runtime<S>, hz: Double = 120.0) {
        self.rt = rt
        let tel = telemetry
        rt.motionRasterGlyphs = MotionGateRasterGlyphs()
        tel.virtualTime = 0.0
        _ = rt.frame(at: 0.0)
        tel.lastScrollOffsets = rt.scrollOffsets
        self.rec = MotionGateRecording(size: (rt.viewport.x, rt.viewport.y), hz: hz)
        self.dt = 1.0 / hz
    }

    public func pixels(_ draw: @escaping (Runtime<S>) -> (Int, Int, [UInt8])?) {
        self.drawPixels = draw
    }

    public func idle(_ secs: Double) {
        let steps = Int((secs / dt).rounded())
        let tel = telemetry
        for _ in 0..<steps {
            tel.virtualTime += dt
            _ = rt.frame(at: tel.virtualTime)
        }
        tel.lastScrollOffsets = rt.scrollOffsets
    }

    public func step() {
        step(suppressDirtyCommit: false)
    }

    private func step(suppressDirtyCommit: Bool) {
        let tel = telemetry
        rt.commitWhy = 0
        let commitsBefore = rt.viewCommitCount
        let playedBefore = rt.playgroundPlayedKeys
        let scrollBefore = rt.scrollOffsets
        tel.virtualTime += dt
        let originalPoll = rt.poll
        if let pollFn = originalPoll {
            rt.poll = { state, now, tx in
                let changed = pollFn(&state, now, &tx)
                if changed {
                    tel.commitWhy |= CommitWhy.poll
                }
                return changed
            }
        }
        _ = rt.frame(at: tel.virtualTime)
        if originalPoll != nil {
            rt.poll = originalPoll
        }
        if rt.playgroundPlayedKeys > playedBefore {
            rec.input("a story step's key")
            tel.commitWhy |= CommitWhy.input
        }
        if rt.viewCommitCount > commitsBefore && tel.commitWhy == 0 && !suppressDirtyCommit && rt.scrollOffsets == scrollBefore {
            tel.commitWhy |= CommitWhy.dirty
        }
        rec.awake.append(rt.isAnimating)
        let drawn = drawPixels?(rt).map { (w, h, rgba) in
            MotionGateGrid.fromPixels(rgba, pw: w, ph: h, size: rec.size)
        }
        MotionGateSampleHelper.sample(rt, rec: rec, telemetry: telemetry, renderFrame: nil, gridOverride: drawn)
    }

    public func stepN(_ n: Int) {
        for _ in 0..<n { step() }
    }

    public func play(_ secs: Double) {
        stepN(Int((secs / dt).rounded()))
    }

    public func act(_ what: String, _ f: (Runtime<S>) -> Void) {
        let tel = telemetry
        let commitsBefore = rt.viewCommitCount
        let scrollBefore = rt.scrollOffsets
        rec.input(what)
        f(rt)
        let pureScroll = (rt.scrollOffsets != scrollBefore) && (rt.viewCommitCount == commitsBefore)
        if !pureScroll {
            tel.commitWhy |= CommitWhy.input
        }
        step(suppressDirtyCommit: pureScroll)
    }

    public func actUpdate(_ what: String, _ body: (_ state: inout S, _ tx: inout Tx) -> Void) {
        let tel = telemetry
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
        let tel = telemetry
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
        let pos = Vec2(cx, cy)
        rt.pointerMove(to: pos, at: rt.currentTime)
        rt.pointerDown(at: pos, at: rt.currentTime)
        rt.pointerUp(at: pos, at: rt.currentTime)
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
    static func sample<S>(_ rt: Runtime<S>, rec: MotionGateRecording, telemetry: RuntimeMotionTelemetry,
                          renderFrame: RenderFrame?, gridOverride: MotionGateGrid?) {
        let why = rt.commitWhy | telemetry.commitWhy
        rt.commitWhy = 0
        telemetry.commitWhy = 0
        let offsets = rt.scrollOffsets
        let moved = offsets != telemetry.lastScrollOffsets
        telemetry.lastScrollOffsets = offsets
        let els = rt.elements()
        rec.commits(scrolling: moved || rt.frameHadScrollSinceLastFrame || els.contains(where: \.scrolling), why: why)
        rec.sampleWith(els, paints: rt.paints())

        let grid: MotionGateGrid?
        if let gridOverride {
            grid = gridOverride
        } else {
            var frame = renderFrame
            if frame == nil, let output = rt.lastFrameOutput {
                // The reference frame publishes the element and hit-test geometry for this step.
                // Capture the same painter stream without replacing that geometry with a second pass.
                let elements = rt.lastElements, rects = rt.presentedRectByPath, scales = rt.presentedScales
                let surfaces = rt.surfaces
                frame = rt.buildRenderFrame(frameOut: output, now: rt.currentTime)
                rt.lastElements = elements
                rt.presentedRectByPath = rects
                rt.presentedScales = scales
                rt.surfaces = surfaces
            }
            let instances = frame?.instances ?? []
            let glyphs = rt.motionRasterGlyphs ?? MotionGateRasterGlyphs()
            if let cached = telemetry.cachedGrid, cached.scale == rt.pixelScale, cached.glyphs == glyphs,
               cached.instances == instances {
                grid = cached.grid
            } else {
                let raster = MotionGateGrid.rasterizeWith(instances, size: rec.size, scale: rt.pixelScale,
                                                         aprons: glyphs.iconAprons, shifts: glyphs.shifts)
                telemetry.cachedGrid = (instances, glyphs, rt.pixelScale, raster)
                grid = raster
            }
        }
        rec.setGrid(grid)
        rec.tips.append(rt.helpTooltip().map { [$0.rect.x, $0.rect.y, $0.rect.z, $0.rect.w] })
    }
}
