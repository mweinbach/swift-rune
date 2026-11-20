// Port of upstream `crates/rune-text/src/icon/anim/mod.rs`:
// Monochrome SMIL SVG icon animation evaluator and double-buffered glyph-atlas tile cache.
//
// Only monochrome (`currentColor`) icons animate. Multi-colour icons stay static via
// `ColorIconRasterizer` (avoiding per-frame RGBA re-rasterization on the UI thread).
//
// Each live animated icon uses a pair of `(px + 2) × (px + 2)` slots in the glyph atlas
// (`GlyphAtlas.putBordered` / `GlyphAtlas.writeBordered`) and flips between them ONLY when the
// quantized coverage bytes actually change. That keeps colour tinting on the GPU (`KIND_GLYPH`),
// preserves partial damage rects, and skips flat holds via `SVGIconAnimState.waitingUntil`.

import Foundation
#if os(Android)
import Android
#endif

/// Classification of an icon on the hot paint path (single cached lookup, matching `icon/color.rs`).
public enum SVGIconKind: Equatable, Hashable, Sendable {
    /// Static monochrome icon drawn from the glyph atlas.
    case mono
    /// Monochrome SMIL animated icon drawn from double-buffered glyph atlas tiles.
    case animatedMono
    /// Static multi-colour icon drawn via `ColorIconRasterizer`.
    case color
}

/// Motion state of an animated icon at the sampled time (`icon/anim/mod.rs` `AnimState`).
public enum SVGIconAnimState: Equatable, Sendable {
    /// At least one track is actively interpolating right now (internal; `frameQuad` paces
    /// moving tracks into `.waitingUntil` at the next quantized pixel change).
    case moving
    /// Sleep and wake once at the returned runtime timestamp (seconds) — either for the next
    /// quantized pixel change during active motion (at <= 30 Hz) or after a flat hold / `begin`
    /// wait / discrete plateau / timed `<set>`.
    case waitingUntil(Double)
    /// All finite tracks have finished (or `<set>` without `dur` has already applied): stop
    /// scheduling frames and re-enable `El.cache` / `PaintKeep`.
    case finished
}

/// Output of `TextSystem.animatedIconQuad` / `animatedIconQuadInPlace` (`icon/anim/mod.rs` `AnimatedQuad`).
public struct AnimatedIconQuad: Equatable, Sendable {
    /// Placement in `GlyphAtlas` (inner `px × px` UV/origin surrounded by a 1-texel transparent apron).
    public var entry: GlyphAtlas.Entry
    /// Target quad `[origin.x, origin.y, px, px]` in device pixels.
    public var rect: SIMD4<Float>
    /// Motion / pacing state for the frame loop and wake scheduler.
    public var state: SVGIconAnimState
    /// True when this call wrote/flipped the atlas slot (or a prior write has not yet uploaded);
    /// false when quantized pixels matched the already-displayed slot.
    public var changed: Bool

    public init(entry: GlyphAtlas.Entry, rect: SIMD4<Float>, state: SVGIconAnimState, changed: Bool) {
        self.entry = entry
        self.rect = rect
        self.state = state
        self.changed = changed
    }

    /// Convenience `PositionedGlyph` view matching `TextSystem.iconQuad`.
    public var quad: PositionedGlyph {
        PositionedGlyph(
            rect: rect,
            uv: entry.uv,
            color: nil,
            colorGlyphIndex: nil,
            atlasPage: entry.page
        )
    }
}

/// Result of rendering an icon's static `t = 0` resting frame when SMIL tags are present.
internal enum SVGIconRestCoverage: Sendable {
    /// Compiled animated SVG rendered at `t = 0.0`.
    case rendered([UInt8])
    /// Well-formed SVG within all caps with no supported SMIL tracks (safe for static parser).
    case staticFallback
    /// Hostile/cap-exceeding or malformed SVG (caller must return empty coverage).
    case rejected
}

internal final class SVGAnimatedIcons: @unchecked Sendable {
    /// Hard cap on distinct compiled animation plans retained per `TextSystem`.
    static let maxCachedPlans: Int = 256
    /// CPU byte budget for cached last-frame coverage buffers (`lastCov`) before frame-boundary eviction.
    static let coverageBudget: Int = 2 * 1024 * 1024
    /// Maximum cadence for animated monochrome SVG icons (matches Rune's `Cycle` spinner at 30 Hz).
    /// Combined with next-pixel-change probing so wakes fire only when quantized coverage bytes differ.
    static let iconAnimStep: Double = 1.0 / 30.0
    /// Maximum forward probes per frame when scanning for the next quantized pixel change (12 × 33.3 ms = 0.4 s).
    static let maxPixelProbes: Int = 12

    /// User-space composed transform safety bound (enforced inside `parseTransformBounded` and
    /// `resolveTransform` before multiplying by device scale `size / view`).
    static func localCTMIsSafe(_ m: GTransform) -> Bool {
        m.xx.isFinite && m.xy.isFinite && m.yx.isFinite && m.yy.isFinite && m.tx.isFinite && m.ty.isFinite
            && max(max(abs(m.xx), abs(m.xy)), max(abs(m.yx), abs(m.yy))) <= SVGIconAnimLimits.maxScale
            && max(abs(m.tx), abs(m.ty)) <= SVGIconAnimLimits.maxCoord
    }

    private struct SlotKey: Hashable {
        var icon: SVGIcon
        var pxPacked: UInt32
        /// `0` for indefinite lockstep icons (shared across all instances); node id for finite icons.
        var scope: UInt64
    }

    private struct SlotEntry {
        var slot0: GlyphAtlas.BorderedSlot?
        var slot1: GlyphAtlas.BorderedSlot?
        var cur: Int
        /// `GlyphAtlas.currentUploadGen` at the time `slots[cur]` was last written, so missed
        /// drawables are detected per-slot without horizontal shelf aliasing.
        var lastWriteGen: UInt64
        var lastCov: [UInt8]
        var lastT: Double
        var lastSampleT: Double
        var lastState: SVGIconAnimState
        var used: Bool

        subscript(slot index: Int) -> GlyphAtlas.BorderedSlot? {
            get { index == 0 ? slot0 : slot1 }
            set {
                if index == 0 {
                    slot0 = newValue
                } else {
                    slot1 = newValue
                }
            }
        }

        @inline(__always)
        func pendingUpload(_ uploadGen: UInt64) -> Bool {
            uploadGen > 0 && lastWriteGen == uploadGen
        }

        @inline(__always)
        func canReuse(t: Double, sampleT: Double) -> Bool {
            let sameTS = abs(lastSampleT - sampleT) <= 1e-9
            let stillWaiting: Bool
            if sampleT >= lastSampleT && t >= lastT {
                switch lastState {
                case .finished:
                    stillWaiting = true
                case .waitingUntil(let wake):
                    stillWaiting = t + 1e-6 < wake
                case .moving:
                    stillWaiting = false
                }
            } else {
                stillWaiting = false
            }
            return sameTS || stillWaiting
        }
    }

    private let lock = NSLock()
    private var plans: [SVGIcon: SVGCompiledAnim] = [:]
    private var slots: [SlotKey: SlotEntry] = [:]
    private var covBytes: Int = 0
    /// Reusable per-frame scratch buffers (zero heap allocation in steady state).
    private var scratchCov: [UInt8] = []
    private var scratchProbeCov: [UInt8] = []
    private var scratchBuf: [UInt8] = []
    private var scratchLayers: [([UInt8], Float)] = []
    private var scratchOverrides: [NodeOverrides] = []
    private var scratchScopes: [RenderScope] = []
    private var hasAnyFlag: Bool = false

    init() {}

    var hasAny: Bool {
        lock.withLock { hasAnyFlag }
    }

    func beginFrame() {
        lock.lock()
        defer { lock.unlock() }
        guard hasAnyFlag else { return }
        if covBytes > Self.coverageBudget {
            slots = slots.filter { $0.value.used }
            covBytes = slots.values.reduce(0) { $0 + $1.lastCov.count }
        }
        for key in slots.keys {
            slots[key]?.used = false
        }
    }

    /// Registers a compiled monochrome animation for `icon`, returning `true` if accepted.
    func insertPlan(_ icon: SVGIcon, _ plan: SVGCompiledAnim) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if plans.count >= Self.maxCachedPlans && plans[icon] == nil {
            return false
        }
        plans[icon] = plan
        hasAnyFlag = true
        return true
    }

    func isFinite(_ icon: SVGIcon) -> Bool {
        lock.withLock {
            guard let plan = plans[icon] else { return false }
            return !plan.hasIndefinite
        }
    }

    /// Whether the animation for `icon` is still live (moving or waiting for a future segment)
    /// at runtime time `t` (with `mountT` used for finite-only icons).
    func isLive(_ icon: SVGIcon, at t: Double, mountTime mountT: Double) -> Bool {
        lock.withLock {
            guard let plan = plans[icon] else { return false }
            let sampleT = plan.hasIndefinite ? t : max(0.0, t - mountT)
            return plan.stateAt(sampleT: sampleT, runtimeT: t) != .finished
        }
    }

    /// Evaluates the raw state of `icon` at `(t, mountT)` without rasterizing.
    func rawState(_ icon: SVGIcon, at t: Double, mountTime mountT: Double) -> SVGIconAnimState? {
        lock.withLock {
            guard let plan = plans[icon] else { return nil }
            let sampleT = plan.hasIndefinite ? t : max(0.0, t - mountT)
            return plan.stateAt(sampleT: sampleT, runtimeT: t)
        }
    }

    /// Renders `body`'s `t = 0.0` resting frame (for reduced motion / static fallback),
    /// distinguishing hostile-cap rejection from benign SVGs with unsupported SMIL attributes.
    static func renderRestCoverage(
        body: String,
        viewBox: Float,
        px: Int,
        size: Float,
        origin: GPoint
    ) -> SVGIconRestCoverage {
        let plan: SVGCompiledAnim
        switch SVGIconAnimParser.compile(body, viewBox: viewBox) {
        case .animated(let compiled):
            plan = compiled
        case .staticOnly:
            return .staticFallback
        case .rejected:
            return .rejected
        }
        guard px > 0 else { return .rejected }
        let (len, overflow) = px.multipliedReportingOverflow(by: px)
        guard !overflow else { return .rejected }
        var cov = [UInt8](repeating: 0, count: len)
        var buf = [UInt8](repeating: 0, count: len)
        var layers: [([UInt8], Float)] = []
        var overrides: [NodeOverrides] = []
        var scopes: [RenderScope] = []
        scopes.reserveCapacity(SVGIconAnimLimits.maxDepth)
        _ = plan.renderInto(
            px: px,
            size: size,
            origin: origin,
            sampleT: 0.0,
            runtimeT: 0.0,
            acc: &cov,
            buf: &buf,
            layers: &layers,
            overrides: &overrides,
            scopeStack: &scopes
        )
        return .rendered(cov)
    }

    /// Direct coverage evaluation + pacing probe for tests and standalone callers (never touches atlas).
    func renderCoverage(
        _ icon: SVGIcon,
        pixelSize px: Int,
        drawnSize: Float? = nil,
        mirrored: Bool = false,
        at t: Double,
        mountTime mountT: Double = 0.0
    ) -> (coverage: [UInt8], state: SVGIconAnimState)? {
        lock.lock()
        defer { lock.unlock() }
        guard px > 0, let plan = plans[icon] else { return nil }
        let sampleT = plan.hasIndefinite ? t : max(0.0, t - mountT)
        let size = drawnSize ?? Float(px)
        let short = UInt32(min(63, max(0, Int(((Float(px) - size) * 64.0).rounded()))))
        let snappedSize = Float(px) - Float(short) / 64.0
        guard let state = evalIntoScratchLocked(
            icon: icon,
            px: px,
            snappedSize: snappedSize,
            mirrored: mirrored,
            t: t,
            sampleT: sampleT
        ) else {
            return nil
        }
        return (scratchCov, state)
    }

    /// True iff `icon` already has both double-buffered atlas tiles resident on non-evicted
    /// pages, so `loopStep` can update it strictly via `writeBordered` without ever calling
    /// `GlyphAtlas.putBordered` or evicting a glyph page.
    func slotsReady(
        in atlas: GlyphAtlas,
        icon: SVGIcon,
        pixelSize px: Int,
        drawnSize: Float?,
        mirrored: Bool,
        scopeID: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard px > 0, px <= atlas.maxBorderedIconSize else { return false }
        guard let plan = plans[icon] else { return false }
        let size = drawnSize ?? Float(px)
        let key = Self.slotKey(
            icon: icon,
            px: px,
            size: size,
            mirrored: mirrored,
            isIndefinite: plan.hasIndefinite,
            scopeID: scopeID
        )
        guard let entry = slots[key],
              let s0 = entry.slot0,
              let s1 = entry.slot1 else {
            return false
        }
        return s0.side == px + 2 && s1.side == px + 2
            && atlas.pageGen(s0.page) == s0.pageGen
            && atlas.pageGen(s1.page) == s1.pageGen
    }

    /// Evaluates `icon`'s compiled AST at `(t, sampleT)` into `scratchCov` and paces
    /// `.moving` into `.waitingUntil` at the next quantized pixel change (at <= 30 Hz).
    /// Pure CPU evaluation; never touches the glyph atlas.
    private func evalIntoScratchLocked(
        icon: SVGIcon,
        px: Int,
        snappedSize: Float,
        mirrored: Bool,
        t: Double,
        sampleT: Double
    ) -> SVGIconAnimState? {
        guard let plan = plans[icon] else { return nil }
        let (needed, overflow) = px.multipliedReportingOverflow(by: px)
        guard !overflow else { return nil }
        Self.resizeZero(&scratchCov, to: needed)
        Self.resizeZero(&scratchBuf, to: needed)
        let rawState = plan.renderInto(
            px: px,
            size: snappedSize,
            origin: .zero,
            sampleT: sampleT,
            runtimeT: t,
            acc: &scratchCov,
            buf: &scratchBuf,
            layers: &scratchLayers,
            overrides: &scratchOverrides,
            scopeStack: &scratchScopes
        )
        if mirrored {
            Self.mirrorRows(&scratchCov, px: px)
        }

        // Pace `.moving` through `.waitingUntil` at <= 30 Hz, probing ahead so the next wake lands
        // on a timestamp where quantized coverage bytes actually differ from `scratchCov`.
        switch rawState {
        case .moving:
            Self.resizeZero(&scratchProbeCov, to: needed)
            var chosen = SVGIconAnimState.waitingUntil(t + Double(Self.maxPixelProbes) * Self.iconAnimStep)
            for k in 1...Self.maxPixelProbes {
                let dt = Double(k) * Self.iconAnimStep
                let pt = sampleT + dt
                let rt = t + dt
                let ps = plan.renderInto(
                    px: px,
                    size: snappedSize,
                    origin: .zero,
                    sampleT: pt,
                    runtimeT: rt,
                    acc: &scratchProbeCov,
                    buf: &scratchBuf,
                    layers: &scratchLayers,
                    overrides: &scratchOverrides,
                    scopeStack: &scratchScopes
                )
                if mirrored {
                    Self.mirrorRows(&scratchProbeCov, px: px)
                }
                if scratchProbeCov != scratchCov {
                    chosen = .waitingUntil(rt)
                    break
                }
                switch ps {
                case .finished:
                    chosen = .finished
                    return chosen
                case .waitingUntil(let w):
                    chosen = .waitingUntil(w)
                    return chosen
                case .moving:
                    break
                }
            }
            return chosen
        case .waitingUntil, .finished:
            return rawState
        }
    }

    /// Evaluates `icon` at runtime time `t` (using `mountT` when finite-only) during a full
    /// paint, allocating its double-buffered glyph-atlas tile pair when needed and flipping
    /// between them ONLY when the quantized coverage bytes changed.
    func frameQuad(
        in atlas: GlyphAtlas,
        icon: SVGIcon,
        pixelSize px: Int,
        drawnSize: Float?,
        origin: SIMD2<Float>,
        mirrored: Bool,
        at t: Double,
        mountTime mountT: Double,
        scopeID: UInt64
    ) -> AnimatedIconQuad? {
        lock.lock()
        defer { lock.unlock() }
        guard px > 0, px <= atlas.maxBorderedIconSize else { return nil }
        guard let isIndefinite = plans[icon]?.hasIndefinite else { return nil }
        let sampleT = isIndefinite ? t : max(0.0, t - mountT)
        let size = drawnSize ?? Float(px)
        let short = UInt32(min(63, max(0, Int(((Float(px) - size) * 64.0).rounded()))))
        let snappedSize = Float(px) - Float(short) / 64.0
        let key = Self.slotKey(
            icon: icon,
            px: px,
            size: size,
            mirrored: mirrored,
            isIndefinite: isIndefinite,
            scopeID: scopeID
        )

        // Same timestamp, active hold/paced interval, or finished finite animation: reuse the
        // current atlas slot with zero re-rasterization or probing.
        if var entry = slots[key],
           let slot = entry[slot: entry.cur],
           atlas.pageGen(slot.page) == slot.pageGen,
           entry.canReuse(t: t, sampleT: sampleT) {
            entry.used = true
            slots[key] = entry
            Self.touchEntrySlots(atlas: atlas, slot0: entry.slot0, slot1: entry.slot1)
            let pending = entry.pendingUpload(atlas.currentUploadGen)
            return Self.makeAnimatedQuad(slot: slot, origin: origin, px: px, state: entry.lastState, changed: pending)
        }

        guard let state = evalIntoScratchLocked(
            icon: icon,
            px: px,
            snappedSize: snappedSize,
            mirrored: mirrored,
            t: t,
            sampleT: sampleT
        ) else {
            return nil
        }

        if var entry = slots[key] {
            let curSlot = entry[slot: entry.cur]
            let validCur: GlyphAtlas.BorderedSlot? = curSlot.flatMap {
                atlas.pageGen($0.page) == $0.pageGen ? $0 : nil
            }
            let uploadGen = atlas.currentUploadGen
            // If pixels are identical to what the active slot already holds, skip atlas write and
            // skip UV flip (zero upload, zero GPU/DWM damage).
            if let slot = validCur, entry.lastCov == scratchCov {
                entry.used = true
                entry.lastT = t
                entry.lastSampleT = sampleT
                entry.lastState = state
                slots[key] = entry
                Self.touchEntrySlots(atlas: atlas, slot0: entry.slot0, slot1: entry.slot1)
                let pending = entry.pendingUpload(uploadGen)
                return Self.makeAnimatedQuad(slot: slot, origin: origin, px: px, state: state, changed: pending)
            }
            // Write into the OTHER slot of the double-buffered pair so UV flips and partial damage
            // sees ONLY this icon's `KIND_GLYPH` instance change.
            // If `pendingUpload`, the previous frame missed its drawable before uploading:
            // overwrite `entry.cur` in place so we never overwrite the on-screen slot or flip UV
            // back to match the last presented instance, with zero horizontal shelf aliasing.
            let nextIdx: Int
            if validCur != nil {
                nextIdx = entry.pendingUpload(uploadGen) ? entry.cur : (1 - entry.cur)
            } else {
                nextIdx = 0
            }
            let placed: GlyphAtlas.BorderedSlot
            if let existing = entry[slot: nextIdx],
               atlas.writeBordered(slot: existing, px: px, coverage: scratchCov) {
                placed = existing
            } else {
                guard let fresh = atlas.putBordered(px: px, coverage: scratchCov) else {
                    return nil
                }
                entry[slot: nextIdx] = fresh
                placed = fresh
            }
            if let other = entry[slot: 1 - nextIdx],
               atlas.pageGen(other.page) == other.pageGen {
                atlas.touch(page: other.page, texels: UInt32(other.side * other.side))
            }
            entry.used = true
            entry.lastT = t
            entry.lastSampleT = sampleT
            entry.lastState = state
            entry.cur = nextIdx
            entry.lastWriteGen = uploadGen
            if entry.lastCov.count != scratchCov.count {
                covBytes = max(0, covBytes - entry.lastCov.count) + scratchCov.count
            }
            entry.lastCov = scratchCov
            slots[key] = entry
            return Self.makeAnimatedQuad(slot: placed, origin: origin, px: px, state: state, changed: true)
        }

        // First allocation for this (icon, size, mirrored, scope): pre-allocate both double-buffer
        // slots during full paint so steady `loopStep` ticks never allocate or evict any live
        // glyph page. Only commit budget after placement succeeds.
        guard let first = atlas.putBordered(px: px, coverage: scratchCov) else {
            return nil
        }
        let slot0: GlyphAtlas.BorderedSlot?
        let slot1: GlyphAtlas.BorderedSlot?
        let active: GlyphAtlas.BorderedSlot
        if let second = atlas.putBordered(px: px, coverage: scratchCov) {
            if atlas.pageGen(first.page) == first.pageGen {
                slot0 = first
                slot1 = second
                active = first
            } else {
                slot0 = second
                slot1 = nil
                active = second
            }
        } else {
            slot0 = first
            slot1 = nil
            active = first
        }
        let lastCov = scratchCov
        covBytes += lastCov.count
        slots[key] = SlotEntry(
            slot0: slot0,
            slot1: slot1,
            cur: 0,
            lastWriteGen: atlas.currentUploadGen,
            lastCov: lastCov,
            lastT: t,
            lastSampleT: sampleT,
            lastState: state,
            used: true
        )
        return Self.makeAnimatedQuad(slot: active, origin: origin, px: px, state: state, changed: true)
    }

    /// Loop-step variant of `frameQuad` taking `InPlaceGlyphAtlas`, which by construction
    /// cannot allocate in or evict from the glyph atlas or inflate `ShelfState.liveTexels`.
    func frameQuadInPlace(
        in atlas: InPlaceGlyphAtlas,
        icon: SVGIcon,
        pixelSize px: Int,
        drawnSize: Float?,
        origin: SIMD2<Float>,
        mirrored: Bool,
        at t: Double,
        mountTime mountT: Double,
        scopeID: UInt64
    ) -> AnimatedIconQuad? {
        lock.lock()
        defer { lock.unlock() }
        guard px > 0, px <= atlas.maxBorderedIconSize else { return nil }
        guard let isIndefinite = plans[icon]?.hasIndefinite else { return nil }
        let sampleT = isIndefinite ? t : max(0.0, t - mountT)
        let size = drawnSize ?? Float(px)
        let short = UInt32(min(63, max(0, Int(((Float(px) - size) * 64.0).rounded()))))
        let snappedSize = Float(px) - Float(short) / 64.0
        let key = Self.slotKey(
            icon: icon,
            px: px,
            size: size,
            mirrored: mirrored,
            isIndefinite: isIndefinite,
            scopeID: scopeID
        )

        if var entry = slots[key],
           let slot = entry[slot: entry.cur],
           atlas.pageGen(slot.page) == slot.pageGen,
           entry.canReuse(t: t, sampleT: sampleT) {
            entry.used = true
            slots[key] = entry
            let pending = entry.pendingUpload(atlas.uploadGen)
            return Self.makeAnimatedQuad(slot: slot, origin: origin, px: px, state: entry.lastState, changed: pending)
        }

        guard slots[key] != nil else { return nil }
        guard let state = evalIntoScratchLocked(
            icon: icon,
            px: px,
            snappedSize: snappedSize,
            mirrored: mirrored,
            t: t,
            sampleT: sampleT
        ) else {
            return nil
        }
        guard var entry = slots[key],
              let curSlot = entry[slot: entry.cur],
              atlas.pageGen(curSlot.page) == curSlot.pageGen else {
            return nil
        }
        let uploadGen = atlas.uploadGen
        if entry.lastCov == scratchCov {
            entry.used = true
            entry.lastT = t
            entry.lastSampleT = sampleT
            entry.lastState = state
            slots[key] = entry
            let pending = entry.pendingUpload(uploadGen)
            return Self.makeAnimatedQuad(slot: curSlot, origin: origin, px: px, state: state, changed: pending)
        }
        let nextIdx = entry.pendingUpload(uploadGen) ? entry.cur : (1 - entry.cur)
        guard let slot = entry[slot: nextIdx],
              atlas.writeBordered(slot: slot, px: px, coverage: scratchCov) else {
            return nil
        }
        entry.used = true
        entry.lastT = t
        entry.lastSampleT = sampleT
        entry.lastState = state
        entry.cur = nextIdx
        entry.lastWriteGen = uploadGen
        if entry.lastCov.count != scratchCov.count {
            covBytes = max(0, covBytes - entry.lastCov.count) + scratchCov.count
        }
        entry.lastCov = scratchCov
        slots[key] = entry
        return Self.makeAnimatedQuad(slot: slot, origin: origin, px: px, state: state, changed: true)
    }

    private static func touchEntrySlots(
        atlas: GlyphAtlas,
        slot0: GlyphAtlas.BorderedSlot?,
        slot1: GlyphAtlas.BorderedSlot?
    ) {
        if let s = slot0, atlas.pageGen(s.page) == s.pageGen {
            atlas.touch(page: s.page, texels: UInt32(s.side * s.side))
        }
        if let s = slot1, atlas.pageGen(s.page) == s.pageGen {
            atlas.touch(page: s.page, texels: UInt32(s.side * s.side))
        }
    }

    private static func slotKey(
        icon: SVGIcon,
        px: Int,
        size: Float,
        mirrored: Bool,
        isIndefinite: Bool,
        scopeID: UInt64
    ) -> SlotKey {
        let short = UInt32(min(63, max(0, Int(((Float(px) - size) * 64.0).rounded()))))
        let pxPacked = UInt32(px) | (short << 24) | (mirrored ? (UInt32(1) << 31) : 0)
        let scope: UInt64 = isIndefinite ? 0 : scopeID
        return SlotKey(icon: icon, pxPacked: pxPacked, scope: scope)
    }

    private static func makeAnimatedQuad(
        slot: GlyphAtlas.BorderedSlot,
        origin: SIMD2<Float>,
        px: Int,
        state: SVGIconAnimState,
        changed: Bool
    ) -> AnimatedIconQuad {
        AnimatedIconQuad(
            entry: slot.makeEntry(px: px),
            rect: SIMD4<Float>(origin.x, origin.y, Float(px), Float(px)),
            state: state,
            changed: changed
        )
    }

    @inline(__always)
    private static func resizeZero(_ buf: inout [UInt8], to count: Int) {
        if buf.count != count {
            buf = [UInt8](repeating: 0, count: count)
        }
    }

    private static func mirrorRows(_ buf: inout [UInt8], px: Int) {
        guard px > 1, buf.count >= px * px else { return }
        let half = px / 2
        for row in 0..<px {
            let base = row * px
            for col in 0..<half {
                buf.swapAt(base + col, base + (px - 1 - col))
            }
        }
    }
}

// MARK: - Per-Node Overrides & Render Scope

/// Evaluated per-node animated overrides for one frame (reused in scratch array, zero per-frame alloc).
private struct NodeOverrides {
    /// Numeric attribute overrides indexed by `SVGAnimAttrKind.numericSlot`: `(value, additiveSum)`.
    var nums: [(Float, Bool)?] = Array(repeating: nil, count: 17)
    /// Transform tracks applied in document order: `(transform, additiveSum)`.
    var transforms: [(GTransform, Bool)] = []
    var hasAny: Bool = false

    mutating func clear() {
        guard hasAny else { return }
        for i in 0..<nums.count {
            nums[i] = nil
        }
        transforms.removeAll(keepingCapacity: true)
        hasAny = false
    }

    mutating func applyNum(_ attr: SVGAnimAttrKind, val: Float, sum: Bool) {
        guard let slot = attr.numericSlot else { return }
        hasAny = true
        if let prev = nums[slot], sum {
            nums[slot] = (prev.0 + val, prev.1)
        } else {
            nums[slot] = (val, sum)
        }
    }

    func resolve(_ attr: SVGAnimAttrKind, base: Float) -> Float {
        guard let slot = attr.numericSlot, let entry = nums[slot] else { return base }
        return entry.1 ? (base + entry.0) : entry.0
    }

    func resolveOpt(_ attr: SVGAnimAttrKind, base: Float?) -> Float? {
        guard let slot = attr.numericSlot, let entry = nums[slot] else { return base }
        return entry.1 ? ((base ?? 0.0) + entry.0) : entry.0
    }

    func resolveTransform(_ base: GTransform) -> GTransform? {
        if transforms.isEmpty {
            return base
        }
        var cur = base
        for (tr, sum) in transforms {
            cur = sum ? GTransform.then(tr, cur) : tr
            if !SVGAnimatedIcons.localCTMIsSafe(cur) {
                return nil
            }
        }
        return cur
    }
}

private struct RenderScope {
    var ctm: GTransform
    var paints: Bool
    var paint: ResolvedPaint
    var layer: Bool
}

private struct ResolvedPaint {
    var fill: Bool? = nil
    var stroke: Bool = false
    var strokeWidth: Float = 1.0
    var fillRule: GAAARule = .nonZero
    var cap: GLineCap = .butt
    var join: GLineJoin = .miter
    var miterLimit: Float = 4.0
    var fillOpacity: Float = 1.0
    var strokeOpacity: Float = 1.0

    func inherit(_ props: SVGAnimPaintProps, overrides ov: NodeOverrides) -> ResolvedPaint {
        let sw = min(
            SVGIconAnimLimits.maxStrokeWidth,
            max(0.0, ov.resolve(.strokeWidth, base: props.strokeWidth ?? strokeWidth))
        )
        let fo = min(1.0, max(0.0, ov.resolve(.fillOpacity, base: props.fillOpacity ?? fillOpacity)))
        let so = min(1.0, max(0.0, ov.resolve(.strokeOpacity, base: props.strokeOpacity ?? strokeOpacity)))
        return ResolvedPaint(
            fill: props.fill ?? fill,
            stroke: props.stroke ?? stroke,
            strokeWidth: sw,
            fillRule: props.fillRule ?? fillRule,
            cap: props.cap ?? cap,
            join: props.join ?? join,
            miterLimit: props.miterLimit ?? miterLimit,
            fillOpacity: fo,
            strokeOpacity: so
        )
    }
}

// MARK: - Compiled AST Evaluation & Rendering

extension SVGCompiledAnim {
    func stateAt(sampleT: Double, runtimeT: Double) -> SVGIconAnimState {
        var state = SVGIconAnimState.finished
        for tr in tracks {
            let (_, s) = tr.sample(sampleT: sampleT, runtimeT: runtimeT)
            state = mergeState(state, s)
        }
        return state
    }

    fileprivate func renderInto(
        px: Int,
        size: Float,
        origin: GPoint,
        sampleT: Double,
        runtimeT: Double,
        acc: inout [UInt8],
        buf: inout [UInt8],
        layers: inout [([UInt8], Float)],
        overrides: inout [NodeOverrides],
        scopeStack: inout [RenderScope]
    ) -> SVGIconAnimState {
        for i in acc.indices { acc[i] = 0 }
        layers.removeAll(keepingCapacity: true)
        scopeStack.removeAll(keepingCapacity: true)
        if overrides.count < nodeCount {
            overrides.reserveCapacity(nodeCount)
            while overrides.count < nodeCount {
                overrides.append(NodeOverrides())
            }
        }
        for i in 0..<nodeCount {
            overrides[i].clear()
        }

        var combinedState = SVGIconAnimState.finished
        for tr in tracks {
            let (val, st) = tr.sample(sampleT: sampleT, runtimeT: runtimeT)
            combinedState = mergeState(combinedState, st)
            let idx = Int(tr.target)
            if let kv = val, idx < overrides.count {
                switch tr.attr {
                case .transform(let tk):
                    overrides[idx].hasAny = true
                    overrides[idx].transforms.append((keyValToTransform(kind: tk, kv: kv), tr.additiveSum))
                default:
                    overrides[idx].applyNum(tr.attr, val: kv.v0, sum: tr.additiveSum)
                }
            }
        }

        let s = size / view
        let rootPaint = ResolvedPaint()
        let rootCTM = GTransform.scale(s, s)

        for op in ops {
            switch op {
            case .pushGroup(let nodeId, let transform, let opacity, let displayNone, let paint, _):
                let upCTM = scopeStack.last?.ctm ?? rootCTM
                let upPaints = scopeStack.last?.paints ?? true
                let upPaint = scopeStack.last?.paint ?? rootPaint
                let ov = overrides[Int(nodeId)]
                let ctm: GTransform
                let ctmOk: Bool
                if let localCTM = ov.resolveTransform(transform) {
                    let composed = GTransform.then(localCTM, upCTM)
                    ctm = composed
                    ctmOk = GaneshIcon.ctmIsSafe(composed)
                } else {
                    ctm = upCTM
                    ctmOk = false
                }
                let alpha = min(1.0, max(0.0, ov.resolve(.opacity, base: opacity)))
                let paints = upPaints && ctmOk && !displayNone && alpha > 0.0
                let nextPaint = upPaint.inherit(paint, overrides: ov)
                let layer = paints && alpha < 1.0 && layers.count < SVGIconAnimLimits.maxLayers
                if layer {
                    layers.append(([UInt8](repeating: 0, count: acc.count), alpha))
                }
                scopeStack.append(RenderScope(ctm: ctm, paints: paints, paint: nextPaint, layer: layer))

            case .popGroup:
                if let popped = scopeStack.popLast(), popped.layer, !layers.isEmpty {
                    let (top, alpha) = layers.removeLast()
                    if layers.isEmpty {
                        GaneshIcon.union(&acc, top, alpha: alpha)
                    } else {
                        let last = layers.count - 1
                        GaneshIcon.union(&layers[last].0, top, alpha: alpha)
                    }
                }

            case .drawShape(let nodeId, let geom, let transform, let opacity, let displayNone, let paint):
                let upCTM = scopeStack.last?.ctm ?? rootCTM
                let upPaints = scopeStack.last?.paints ?? true
                if !upPaints || displayNone {
                    continue
                }
                let ov = overrides[Int(nodeId)]
                let whole = min(1.0, max(0.0, ov.resolve(.opacity, base: opacity)))
                if whole <= 0.0 {
                    continue
                }
                guard let localCTM = ov.resolveTransform(transform) else { continue }
                let ctm = GTransform.then(localCTM, upCTM)
                if !GaneshIcon.ctmIsSafe(ctm) {
                    continue
                }
                let upPaint = scopeStack.last?.paint ?? rootPaint
                let resolved = upPaint.inherit(paint, overrides: ov)
                if layers.isEmpty {
                    drawCompiledShape(
                        geom: geom,
                        ov: ov,
                        ctm: ctm,
                        origin: origin,
                        px: px,
                        whole: whole,
                        paint: resolved,
                        buf: &buf,
                        into: &acc
                    )
                } else {
                    let last = layers.count - 1
                    drawCompiledShape(
                        geom: geom,
                        ov: ov,
                        ctm: ctm,
                        origin: origin,
                        px: px,
                        whole: whole,
                        paint: resolved,
                        buf: &buf,
                        into: &layers[last].0
                    )
                }
            }
        }

        while !layers.isEmpty {
            let (top, alpha) = layers.removeLast()
            if layers.isEmpty {
                GaneshIcon.union(&acc, top, alpha: alpha)
            } else {
                let last = layers.count - 1
                GaneshIcon.union(&layers[last].0, top, alpha: alpha)
            }
        }
        return combinedState
    }
}

private func drawCompiledShape(
    geom: SVGAnimBaseGeom,
    ov: NodeOverrides,
    ctm: GTransform,
    origin: GPoint,
    px: Int,
    whole: Float,
    paint p: ResolvedPaint,
    buf: inout [UInt8],
    into: inout [UInt8]
) {
    let lim = SVGIconAnimLimits.maxCoord
    let shape: GaneshArea.Shape
    switch geom {
    case .circle(let cxBase, let cyBase, let rBase):
        let r = min(lim, max(0.0, ov.resolve(.r, base: rBase)))
        if r <= 0.0 { return }
        let cx = min(lim, max(-lim, ov.resolve(.cx, base: cxBase)))
        let cy = min(lim, max(-lim, ov.resolve(.cy, base: cyBase)))
        shape = .oval(center: GPoint(x: cx, y: cy), radii: GPoint(x: r, y: r))

    case .ellipse(let cxBase, let cyBase, let rxBase, let ryBase):
        let rx = min(lim, max(0.0, ov.resolve(.rx, base: rxBase)))
        let ry = min(lim, max(0.0, ov.resolve(.ry, base: ryBase)))
        if rx <= 0.0 || ry <= 0.0 { return }
        let cx = min(lim, max(-lim, ov.resolve(.cx, base: cxBase)))
        let cy = min(lim, max(-lim, ov.resolve(.cy, base: cyBase)))
        shape = .oval(center: GPoint(x: cx, y: cy), radii: GPoint(x: rx, y: ry))

    case .rect(let xBase, let yBase, let wBase, let hBase, let rxBase, let ryBase):
        let w = min(lim, max(0.0, ov.resolve(.width, base: wBase)))
        let h = min(lim, max(0.0, ov.resolve(.height, base: hBase)))
        if w <= 0.0 || h <= 0.0 { return }
        let x = min(lim, max(-lim, ov.resolve(.x, base: xBase)))
        let y = min(lim, max(-lim, ov.resolve(.y, base: yBase)))
        let rxV = ov.resolveOpt(.rx, base: rxBase)
        let ryV = ov.resolveOpt(.ry, base: ryBase)
        let rxC = min(w * 0.5, max(0.0, (rxV ?? ryV) ?? 0.0))
        let ryC = min(h * 0.5, max(0.0, (ryV ?? rxV) ?? 0.0))
        if rxC == 0.0 || abs(rxC - ryC) <= 1e-4 {
            shape = .rounded(lo: GPoint(x: x, y: y), hi: GPoint(x: x + w, y: y + h), r: rxC)
        } else {
            // Non-uniform rounded rectangle (`rx != ry`) with exact 90-degree elliptical conics (`w = sqrt(2)/2`).
            let k: Float = 0.7071067811865476
            let els: [GEl] = [
                .move(GPoint(x: x + rxC, y: y)),
                .line(GPoint(x: x + w - rxC, y: y)),
                .conic(GPoint(x: x + w, y: y), GPoint(x: x + w, y: y + ryC), k),
                .line(GPoint(x: x + w, y: y + h - ryC)),
                .conic(GPoint(x: x + w, y: y + h), GPoint(x: x + w - rxC, y: y + h), k),
                .line(GPoint(x: x + rxC, y: y + h)),
                .conic(GPoint(x: x, y: y + h), GPoint(x: x, y: y + h - ryC), k),
                .line(GPoint(x: x, y: y + ryC)),
                .conic(GPoint(x: x, y: y), GPoint(x: x + rxC, y: y), k),
                .close,
            ]
            shape = .path(els)
        }

    case .line(let x1Base, let y1Base, let x2Base, let y2Base):
        let x1 = min(lim, max(-lim, ov.resolve(.x1, base: x1Base)))
        let y1 = min(lim, max(-lim, ov.resolve(.y1, base: y1Base)))
        let x2 = min(lim, max(-lim, ov.resolve(.x2, base: x2Base)))
        let y2 = min(lim, max(-lim, ov.resolve(.y2, base: y2Base)))
        shape = .path([.move(GPoint(x: x1, y: y1)), .line(GPoint(x: x2, y: y2))])

    case .path(let els):
        shape = .path(els)
    }

    let doFill = p.fill ?? !p.stroke
    if doFill {
        GaneshIcon.paintShape(
            shape,
            ctm: ctm,
            origin: origin,
            pen: nil,
            fill: p.fillRule,
            alpha: whole * p.fillOpacity,
            px: px,
            buf: &buf,
            into: &into
        )
    }
    if p.stroke && p.strokeWidth > 0.0 {
        let pen = GaneshArea.Pen(width: p.strokeWidth, cap: p.cap, join: p.join, miterLimit: p.miterLimit)
        GaneshIcon.paintShape(
            shape,
            ctm: ctm,
            origin: origin,
            pen: pen,
            fill: .nonZero,
            alpha: whole * p.strokeOpacity,
            px: px,
            buf: &buf,
            into: &into
        )
    }
}

private func mergeState(_ a: SVGIconAnimState, _ b: SVGIconAnimState) -> SVGIconAnimState {
    switch (a, b) {
    case (.moving, _), (_, .moving):
        return .moving
    case (.waitingUntil(let x), .waitingUntil(let y)):
        return .waitingUntil(min(x, y))
    case (.waitingUntil(let x), .finished), (.finished, .waitingUntil(let x)):
        return .waitingUntil(x)
    case (.finished, .finished):
        return .finished
    }
}

// MARK: - Track Sampling & Interpolation

extension SVGAnimTrack {
    /// Evaluates the track at `sampleT` (with `runtimeT` used to express `.waitingUntil` in the
    /// runtime clock domain).
    func sample(sampleT: Double, runtimeT: Double) -> (SVGAnimKeyVal?, SVGIconAnimState) {
        let beginD = Double(begin)
        if sampleT < beginD {
            let delta = max(0.0, beginD - sampleT)
            return (nil, .waitingUntil(runtimeT + delta))
        }
        let elapsed = sampleT - beginD

        if isSet {
            guard let d = dur else {
                return (values.first, .finished)
            }
            let durD = Double(d)
            if elapsed < durD {
                return (values.first, .waitingUntil(runtimeT + (durD - elapsed)))
            } else if freeze {
                return (values.first, .finished)
            } else {
                return (nil, .finished)
            }
        }

        let durD = Double(dur ?? 1.0)
        if let rep = repeatCount {
            let total = durD * Double(rep)
            if elapsed >= total {
                if !freeze {
                    return (nil, .finished)
                }
                // SMIL 3.0: fractional `repeatCount` with `fill="freeze"` freezes at `fract(rep)`.
                let frac = rep - floorf(rep)
                let endU: Float = abs(frac) <= 1e-6 ? 1.0 : frac
                return (evalU(endU), .finished)
            }
        }

        let cycle = floor(elapsed / durD)
        let cycleStart = beginD + cycle * durD
        let local = min(durD, max(0.0, elapsed - cycle * durD))
        let u = Float(local / durD)
        let (val, segState) = evalUWithState(u: u, cycleStart: cycleStart, dur: durD, sampleT: sampleT, runtimeT: runtimeT)
        return (val, segState)
    }

    func evalU(_ u: Float) -> SVGAnimKeyVal {
        let n = values.count
        if n <= 1 {
            return values[0]
        }
        let seg = segmentFor(u)
        if calcMode == .discrete {
            return values[seg]
        }
        let t0 = keyTimes[seg]
        let t1 = keyTimes[seg + 1]
        let span = t1 - t0
        let raw: Float = span <= 1e-6 ? 1.0 : min(1.0, max(0.0, (u - t0) / span))
        let frac: Float
        switch calcMode {
        case .spline:
            let s = keySplines[seg]
            frac = cubicBezier(x1: s.x, y1: s.y, x2: s.z, y2: s.w, x: raw)
        case .linear, .paced:
            frac = raw
        case .discrete:
            frac = 0.0
        }
        return lerpKeyVal(values[seg], values[seg + 1], frac)
    }

    private func evalUWithState(
        u: Float,
        cycleStart: Double,
        dur: Double,
        sampleT: Double,
        runtimeT: Double
    ) -> (SVGAnimKeyVal, SVGIconAnimState) {
        let n = values.count
        if n <= 1 {
            return (values[0], .finished)
        }
        let seg = segmentFor(u)
        if calcMode == .discrete {
            let nextU = (seg + 1 < n) ? Double(keyTimes[seg + 1]) : 1.0
            let nextSample = cycleStart + nextU * dur
            let wake = clampWake(nextSample: nextSample, sampleT: sampleT, runtimeT: runtimeT)
            return (values[seg], wake)
        }
        let a = values[seg]
        let b = values[seg + 1]
        let t0 = keyTimes[seg]
        let t1 = keyTimes[seg + 1]
        let span = t1 - t0
        let flat = keyValEq(a, b) || span <= 1e-6
        if flat {
            let nextSample = cycleStart + Double(t1) * dur
            let wake = clampWake(nextSample: nextSample, sampleT: sampleT, runtimeT: runtimeT)
            return (a, wake)
        }
        let raw = min(1.0, max(0.0, (u - t0) / span))
        let frac: Float
        switch calcMode {
        case .spline:
            let s = keySplines[seg]
            frac = cubicBezier(x1: s.x, y1: s.y, x2: s.z, y2: s.w, x: raw)
        case .linear, .paced:
            frac = raw
        case .discrete:
            frac = 0.0
        }
        return (lerpKeyVal(a, b, frac), .moving)
    }

    private func clampWake(nextSample: Double, sampleT: Double, runtimeT: Double) -> SVGIconAnimState {
        var target = nextSample
        if let rep = repeatCount {
            let end = Double(begin) + Double(dur ?? 1.0) * Double(rep)
            if target > end {
                target = end
            }
        }
        let delta = target - sampleT
        if delta <= 1e-6 {
            // At a segment boundary right now: step one frame to enter the next segment.
            return .moving
        }
        return .waitingUntil(runtimeT + delta)
    }

    private func segmentFor(_ u: Float) -> Int {
        let n = values.count
        if calcMode == .discrete {
            var seg = 0
            for i in 1..<n {
                if u >= keyTimes[i] {
                    seg = i
                } else {
                    break
                }
            }
            return seg
        }
        var seg = 0
        for i in 0..<(n - 1) {
            if u >= keyTimes[i] {
                seg = i
            } else {
                break
            }
        }
        return seg
    }
}

private func keyValEq(_ a: SVGAnimKeyVal, _ b: SVGAnimKeyVal) -> Bool {
    let len = Int(max(a.len, b.len))
    for i in 0..<len {
        if abs(a[i] - b[i]) > 1e-6 {
            return false
        }
    }
    return true
}

private func lerpKeyVal(_ a: SVGAnimKeyVal, _ b: SVGAnimKeyVal, _ frac: Float) -> SVGAnimKeyVal {
    let len = max(a.len, b.len)
    var out = SVGAnimKeyVal(0, 0, 0, len: len)
    for i in 0..<Int(len) {
        let v = a[i] + (b[i] - a[i]) * frac
        out[i] = v.isFinite ? v : b[i]
    }
    return out
}

internal func cubicBezier(x1 inX1: Float, y1: Float, x2 inX2: Float, y2: Float, x: Float) -> Float {
    if abs(inX1 - y1) < 1e-5 && abs(inX2 - y2) < 1e-5 {
        return x
    }
    let x1 = min(1.0, max(0.0, inX1))
    let x2 = min(1.0, max(0.0, inX2))
    @inline(__always) func sample(_ a: Float, _ b: Float, _ t: Float) -> Float {
        let mt = 1.0 - t
        return 3.0 * mt * mt * t * a + 3.0 * mt * t * t * b + t * t * t
    }
    @inline(__always) func slope(_ a: Float, _ b: Float, _ t: Float) -> Float {
        let mt = 1.0 - t
        return 3.0 * mt * mt * a + 6.0 * mt * t * (b - a) + 3.0 * t * t * (1.0 - b)
    }
    var s = x
    for _ in 0..<8 {
        let err = sample(x1, x2, s) - x
        if abs(err) < 1e-6 {
            return sample(y1, y2, s)
        }
        let d = slope(x1, x2, s)
        if abs(d) < 1e-6 {
            break
        }
        s = min(1.0, max(0.0, s - err / d))
    }
    var lo: Float = 0.0
    var hi: Float = 1.0
    s = x
    for _ in 0..<20 {
        let v = sample(x1, x2, s)
        if abs(v - x) < 1e-6 {
            break
        }
        if v < x { lo = s } else { hi = s }
        s = 0.5 * (lo + hi)
    }
    return sample(y1, y2, s)
}

private func keyValToTransform(kind: SVGAnimTransformKind, kv: SVGAnimKeyVal) -> GTransform {
    let co = SVGIconAnimLimits.maxCoord
    let sc = SVGIconAnimLimits.maxScale
    let sk = SVGIconAnimLimits.maxSkewDeg
    switch kind {
    case .translate:
        return .translation(min(co, max(-co, kv.v0)), min(co, max(-co, kv.v1)))
    case .scale:
        let sx = min(sc, max(-sc, kv.v0))
        let sy = min(sc, max(-sc, kv.len >= 2 ? kv.v1 : kv.v0))
        return .scale(sx, sy)
    case .rotate:
        return SVGIconAnimParser.rotateTransform(
            deg: min(36_000.0, max(-36_000.0, kv.v0)),
            cx: min(co, max(-co, kv.v1)),
            cy: min(co, max(-co, kv.v2))
        )
    case .skewX:
        let deg = min(sk, max(-sk, kv.v0))
        return GTransform(xx: 1, xy: 0, yx: Float(tan(Double(deg) * Double.pi / 180.0)), yy: 1, tx: 0, ty: 0)
    case .skewY:
        let deg = min(sk, max(-sk, kv.v0))
        return GTransform(xx: 1, xy: Float(tan(Double(deg) * Double.pi / 180.0)), yx: 0, yy: 1, tx: 0, ty: 0)
    }
}
