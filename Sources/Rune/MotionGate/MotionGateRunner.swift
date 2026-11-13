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
    var lastScrollOffsets: [String: Vec2] = [:]

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
        _ = rt.frame(at: 0.0)
        tel.lastCommitCount = rt.viewCommitCount
        tel.lastScrollOffsets = rt.scrollOffsets
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
            _ = rt.frame(at: tel.virtualTime)
        }
        tel.lastCommitCount = rt.viewCommitCount
        tel.lastScrollOffsets = rt.scrollOffsets
    }

    public func step() {
        step(suppressDirtyCommit: false)
    }

    private func step(suppressDirtyCommit: Bool) {
        let tel = RuntimeMotionTelemetry.of(rt)
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
            rec.input("play.press")
            tel.commitWhy |= CommitWhy.input
        }
        if rt.viewCommitCount > commitsBefore && tel.commitWhy == 0 && !suppressDirtyCommit && rt.scrollOffsets == scrollBefore {
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

        let curScrollOffsets = rt.scrollOffsets
        var movedScrollPaths = Set<String>()
        for (path, cur) in curScrollOffsets where tel.lastScrollOffsets[path] != cur {
            movedScrollPaths.insert(path)
        }
        for (path, _) in tel.lastScrollOffsets where curScrollOffsets[path] == nil {
            movedScrollPaths.insert(path)
        }
        let anyScrollChanged = !movedScrollPaths.isEmpty
        tel.lastScrollOffsets = curScrollOffsets
        rec.commits(scrolling: anyScrollChanged, why: why)

        let els = rt.elements()
        let now = rt.currentTime

        var nodeByPath: [String: Runtime<S>.FlatNode] = [:]
        var elByPath: [String: El<S>] = [:]
        nodeByPath.reserveCapacity(rt.flatNodes.count + rt.exitingSnapshots.count)
        elByPath.reserveCapacity(rt.flatNodes.count + rt.exitingSnapshots.count)
        for n in rt.exitingSnapshots.values {
            nodeByPath[n.path] = n
            elByPath[n.path] = n.el
        }
        for n in rt.flatNodes {
            nodeByPath[n.path] = n
            elByPath[n.path] = n.el
        }

        // Track ancestor scrolling state onto descendants without mutating per-node `els[i].scrolled`
        // (so `carriedScrolled` below can single-count nested scroll containers cleanly).
        var ancScrolling = Array(repeating: false, count: els.count)
        for i in 0..<els.count {
            var scrolling = false
            var cur = els[i].parentIndex
            var hops = 0
            while let p = cur, p >= 0, p < els.count, hops <= els.count {
                if movedScrollPaths.contains(els[p].path) {
                    scrolling = true
                    break
                }
                cur = els[p].parentIndex
                hops += 1
            }
            ancScrolling[i] = scrolling
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
            let el = elByPath[e.path]

            let ownIntent = (el?.runtimeExtras[MotionGateExtraKey.motionIntent] as? UInt16) ?? 0
            let totalIntent = pIntent | ownIntent
            inheritedIntent[i] = totalIntent

            let ownInstant = (el?.hasInstantChanges ?? false)
                || ((el?.runtimeExtras[MotionGateExtraKey.instantChanges] as? Bool) ?? false)
            let totalInstant = pInstant || ownInstant
            inheritedInstant[i] = totalInstant

            var phase: Double? = nil
            if let loopSpec = el?.loopingSpec {
                if case .sequence(let seq) = loopSpec.kind {
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
                } else if let existing = tel.loopTracks[e.path], existing.1 == loopSpec {
                    phase = existing.0.phase(at: now)
                } else {
                    let track = LoopTrack(spec: loopSpec, now: now)
                    tel.loopTracks[e.path] = (track, loopSpec)
                    phase = track.phase(at: now)
                }
            }

            var carriedX: Float = 0
            var carriedY: Float = 0
            var curParentIdx = e.parentIndex
            while let pIdx = curParentIdx, pIdx >= 0, pIdx < els.count {
                let pPath = els[pIdx].path
                if let pEl = elByPath[pPath], !pEl.layout.scrollAxes.isEmpty {
                    let sc = els[pIdx].scrolled
                    if sc.count >= 2 {
                        let scale = nodeByPath[pPath]?.inheritedScale ?? 1.0
                        carriedX += sc[0] * scale
                        carriedY += sc[1] * scale
                    }
                }
                curParentIdx = els[pIdx].parentIndex
            }

            let meta = ElementMotionMeta(
                scrolling: ancScrolling[i],
                inGrowingRow: (el?.runtimeExtras[MotionGateExtraKey.growingRow] as? Bool) ?? false,
                revealing: (el?.runtimeExtras[MotionGateExtraKey.revealing] as? Bool) ?? false,
                liveIntent: totalIntent,
                virtualExtent: false,
                loopPhase: phase,
                carriedScrolled: [carriedX, carriedY]
            )
            metas.append(meta)

            let ownMotionNone = (el?.runtimeExtras[MotionGateExtraKey.ownMotionNone] as? Bool) ?? false
            let ownBlurNone = el?.runtimeExtras[MotionGateExtraKey.ownBlurNone] as? Bool
            let atOnce = MotionGatePaintUtils.atOnceBits(motion: ownMotionNone, blur: ownBlurNone)

            var colors = Array(repeating: Color.transparent, count: MotionGatePaint.colorCount)
            colors[MotionGatePaint.cFill] = e.fill
            colors[MotionGatePaint.cBorder] = node.flatMap { rt.scene.get($0.nodeId, Props.BORDER).map(Color.init) }
                ?? el?.borderColor
                ?? .transparent
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
            let savedElements = rt.lastElements
            let savedRects = rt.presentedRectByPath
            let savedScales = rt.presentedScaleByPath
            let savedSurfaces = rt.surfaces
            var exitByPath: [String: Runtime<S>.FlatNode] = [:]
            for (_, snap) in rt.exitingSnapshots {
                exitByPath[snap.path] = snap
            }
            var presentedNodes: [Presented] = []
            presentedNodes.reserveCapacity(els.count)
            for e in els {
                guard let fn = e.exiting ? (exitByPath[e.path] ?? nodeByPath[e.path]) : nodeByPath[e.path] else {
                    continue
                }
                let rect = MotionRect(
                    left: e.rect[0] - fn.el.offset.x,
                    top: e.rect[1] - fn.el.offset.y,
                    right: (e.rect[0] - fn.el.offset.x) + e.rect[2],
                    bottom: (e.rect[1] - fn.el.offset.y) + e.rect[3]
                )
                let pScale = (e.scale.isFinite && e.scale > 0) ? e.scale : 1.0
                presentedNodes.append(Presented(
                    id: fn.nodeId,
                    parent: nil,
                    rect: rect,
                    targetRect: fn.targetRect,
                    revealClip: nil,
                    opacity: e.opacity,
                    scale: Vec2(pScale, pScale),
                    rotate: 0,
                    corners: Corners.all(e.radius),
                    blur: e.blur,
                    fill: e.fill.motionColor,
                    border: (rt.scene.get(fn.nodeId, Props.BORDER).map(Color.init) ?? fn.el.borderColor).motionColor,
                    presence: e.exiting ? 0.0 : 1.0,
                    isExiting: e.exiting,
                    isMoving: e.moving
                ))
            }
            let synthFrameOut = FrameOutput(changed: [], exited: [], events: [], animating: rt.isAnimating, nodes: presentedNodes)
            let rf = rt.buildRenderFrame(frameOut: synthFrameOut, now: rt.currentTime)
            rt.lastElements = savedElements
            rt.presentedRectByPath = savedRects
            rt.presentedScaleByPath = savedScales
            rt.surfaces = savedSurfaces
            grid = MotionGateGrid.rasterize(rf.instances, size: rec.size, scale: rt.pixelScale)
        }
        rec.setGrid(grid)
        rec.tips.append(rt.helpTooltip().map { [$0.rect.x, $0.rect.y, $0.rect.z, $0.rect.w] })
    }
}
