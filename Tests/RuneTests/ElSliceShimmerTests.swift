import Foundation
import Testing
@testable import Rune
import RuneMotion

@Suite("El Slice: Shimmer Counter-Slide & LoopClock Parity (shimmer.rs)")
struct ElSliceShimmerTests {

    private struct ShimmerState {
        var since: Double = 0.0
        var now: Double = 0.0
        var snap: Bool = true
        var zoom: Float = 1.0
        var on: Bool = true
        var tail: Bool = false
        var pad: Float = 0.0
        var ring: Bool = false
        var band: Float = 30.0
        var litAt: Double = -.infinity
    }

    private static let dimColor = Color(r: 0.3, g: 0.3, b: 0.3, a: 1.0)
    private static let litColor = Color(r: 1.0, g: 1.0, b: 1.0, a: 1.0)
    private static let labelWidth: Float = 52.0
    private static let speed: Float = 90.0
    private static let glyphPxTolerance: Float = 2.0

    private static func period(_ s: ShimmerState) -> Double {
        Double((labelWidth + s.band) / speed)
    }

    private static func makeRuntime(_ s: ShimmerState) -> Runtime<ShimmerState> {
        Runtime<ShimmerState>(
            state: s,
            viewport: Vec2(400, 60),
            pixelScale: 2.0
        ) { state, _ in
            let font = TextStyle(size: 13.0, weight: 400.0)
            let w = state.band
            let x0 = -w
            let x1 = labelWidth
            let p = Self.period(state)
            let raw = (-(state.now - state.since) / p).truncatingRemainder(dividingBy: 1.0)
            let euclid = raw < 0.0 ? raw + 1.0 : raw
            let d = euclid * p
            let delay = d > p - 1e-6 ? 0.0 : d

            func spec(_ a: Float, _ b: Float) -> LoopSpec {
                var sp = LoopSpec.slide(period: p, from: Vec2(a, 0), to: Vec2(b, 0)).easing(.linear)
                sp.delay = delay
                return sp
            }

            let lit: El<ShimmerState> = el().key("lit")
                .absolute(x: 0, y: 0)
                .w(w)
                .hFull()
                .looping(spec(-x0 / w, -x1 / w))
                .child(text("Working").font(font).color(Self.litColor).absolute(x: 0, y: 0))

            var sheen: El<ShimmerState> = el().key("sheen")
                .absolute(x: 0, y: 0)
                .w(w)
                .hFull()
                .clipFade(left: w / 2.0, right: w / 2.0)
                .looping(spec(x0 / w, x1 / w))
                .pixelSnap(state.snap)
            if state.now >= state.litAt {
                sheen = sheen.child(lit)
            }

            var labelRow: El<ShimmerState> = row()
                .child(text("Working").key("label").font(font).color(Self.dimColor))
            if state.on {
                labelRow = labelRow.child(sheen)
            }

            var ring: El<ShimmerState> = el().key("ring").size(14, 14)
            if state.ring {
                for k in 0..<3 {
                    ring = ring.child(
                        el().key("d\(k)")
                            .absolute(x: Float(k) * 5.0, y: 5.0)
                            .size(3, 3)
                            .bg(Self.dimColor)
                            .cycle(
                                period: 1.2,
                                phase: Float(k) / 3.0,
                                stops: [(0.0, 0.2), (0.5, 1.0), (1.0, 0.2)],
                                still: 0.2,
                                fps: 30.0
                            )
                    )
                }
            }

            var workingRow: El<ShimmerState> = row().key("working").h(28).gap(8).centerY().pb(12)
                .child(ring)
                .child(labelRow)
            if state.tail {
                workingRow = El<ShimmerState>().wFull().h(28)
                    .motion(Spring(duration: 0.3, bounce: 0.0))
                    .child(workingRow.absolute(x: 0, y: 0).opacity(1.0))
            }

            let content: El<ShimmerState> = col().size(400, 60).pl(state.pad).pt(state.pad / 2.0).child(workingRow)
            return el().size(400, 60).center()
                .child(el().size(400 / state.zoom, 60 / state.zoom).scale(state.zoom).child(content))
        }
    }

    private static func litOffsets(_ rt: Runtime<ShimmerState>) -> [Float] {
        let rf = rt.renderFrame(at: rt.currentTime)
        func glyphs(_ c: Color) -> [SIMD4<Float>] {
            let enc = c.simd4(srgb: rt.srgbBlend)
            return rf.instances.compactMap { inst in
                guard inst.params.y == KIND_GLYPH,
                      abs(inst.fill.x - enc.x) < 0.02,
                      abs(inst.fill.y - enc.y) < 0.02 else { return nil }
                return inst.rect
            }
        }
        let dim = glyphs(Self.dimColor)
        let lit = glyphs(Self.litColor)
        #expect(!dim.isEmpty, "expected dim label glyphs")
        return lit.map { l in
            var best: Float? = nil
            for d in dim where abs(d.z - l.z) < 3.0 && abs(d.w - l.w) < 3.0 {
                let dx = (l.x + l.z * 0.5) - (d.x + d.z * 0.5)
                if best == nil || abs(dx) < abs(best!) {
                    best = dx
                }
            }
            return best ?? .nan
        }
    }

    private static func worstOf(_ rt: Runtime<ShimmerState>, _ worst: Float) -> Float {
        let w = Self.litOffsets(rt).reduce(Float(0.0)) { a, b in
            if b.isNaN || abs(b) > abs(a) { return b }
            return a
        }
        if w.isNaN || abs(w) > abs(worst) { return w }
        return worst
    }

    private static func loopOffsets(_ rt: Runtime<ShimmerState>) -> (Float, Float)? {
        func nodeId(_ key: String) -> NodeId? {
            rt.flatNodes.first(where: { $0.key == key })?.nodeId
        }
        guard let s = nodeId("sheen"), let l = nodeId("lit") else { return nil }
        let offS = rt.scene.get(s, Props.OFFSET)?.x ?? 0.0
        let offL = rt.scene.get(l, Props.OFFSET)?.x ?? 0.0
        return (offS, offL)
    }

    private static func run(_ rt: inout Runtime<ShimmerState>, frames: Int) -> Float {
        var worst: Float = 0.0
        let dt = 1.0 / 120.0
        for _ in 0..<frames {
            let next = rt.currentTime + dt
            rt.update(at: next) { s, _ in s.now = next }
            rt.invalidate(at: next)
            _ = rt.frame(at: next)
            worst = Self.worstOf(rt, worst)
        }
        return worst
    }

    private static func worstOffset(snap: Bool, zoom: Float, mountAt: Double) -> Float {
        let s = ShimmerState(since: 0.0, now: mountAt, snap: snap, zoom: zoom)
        var rt = Self.makeRuntime(s)
        _ = rt.frame(at: 0.0)
        return Self.run(&rt, frames: Int(Self.period(s) * 2.5 * 120.0))
    }

    @Test("Counter-sliding shimmer keeps its bright copy aligned on the dim label across zoom/snap/mountAt")
    func zoomAndSnapMatrix() {
        var bad: [(Float, Bool, Double, Float)] = []
        for zoom in [Float(1.0), 1.1, 0.9, 1.25] {
            for snap in [true, false] {
                for mountAt in [0.0, 0.5] {
                    let w = Self.worstOffset(snap: snap, zoom: zoom, mountAt: mountAt)
                    let bound: Float = snap ? Self.glyphPxTolerance : Self.glyphPxTolerance + 1.0 / 64.0
                    if w.isNaN || !(abs(w) < bound) {
                        bad.append((zoom, snap, mountAt, w))
                    }
                }
            }
        }
        #expect(bad.isEmpty, "bright copy drifts off label (zoom, snap, mountAt, px): \(bad)")
    }

    @Test("Shimmer stopping and restarting keeps its bright copy aligned on the label")
    func shimmerRestartsStayAligned() {
        var bad: [(Bool, Int, Double, Float)] = []
        for tail in [false, true] {
            for offFrames in [1, 6, 60] {
                for stopAt in [0.3, 0.9, 1.5] {
                    let s = ShimmerState(tail: tail)
                    var rt = Self.makeRuntime(s)
                    _ = rt.frame(at: 0.0)
                    _ = Self.run(&rt, frames: Int(stopAt * 120.0))
                    rt.update(at: rt.currentTime) { st, _ in st.on = false }
                    _ = Self.run(&rt, frames: offFrames)
                    let restartAt = rt.currentTime
                    rt.update(at: restartAt) { st, _ in
                        st.on = true
                        st.since = restartAt
                    }
                    let w = Self.run(&rt, frames: Int(Self.period(s) * 2.5 * 120.0))
                    if w.isNaN || !(abs(w) < Self.glyphPxTolerance) {
                        bad.append((tail, offFrames, stopAt, w))
                    }
                }
            }
        }
        #expect(bad.isEmpty, "bright copy drifts after restart: \(bad)")
    }

    @Test("Shimmer stopped while waiting for its delayed next pass restarts in lockstep")
    func shimmerStoppedWhileWaitingRestartsInStep() {
        var bad: [(Double, Double, Float)] = []
        for stopAt in [0.2, 0.7, 1.2] {
            for gap in [0.05, 0.5] {
                let s = ShimmerState(since: -0.8, band: 140.0)
                var rt = Self.makeRuntime(s)
                _ = rt.frame(at: 0.0)
                _ = Self.run(&rt, frames: Int(stopAt * 120.0))
                rt.update(at: rt.currentTime) { st, _ in st.on = false }
                _ = Self.run(&rt, frames: Int(gap * 120.0))
                let restartAt = rt.currentTime
                rt.update(at: restartAt) { st, _ in
                    st.on = true
                    st.since = restartAt
                }
                var worst: Float = 0.0
                for _ in 0..<Int(Self.period(s) * 1.5 * 120.0) {
                    let next = rt.currentTime + 1.0 / 120.0
                    rt.update(at: next) { st, _ in st.now = next }
                    rt.invalidate(at: next)
                    _ = rt.frame(at: next)
                    if let (a, b) = Self.loopOffsets(rt) {
                        let d = a + b
                        if abs(d) > abs(worst) { worst = d }
                    }
                }
                if abs(worst) > 0.01 {
                    bad.append((stopAt, gap, worst))
                }
            }
        }
        #expect(bad.isEmpty, "sheen and lit fall out of step while waiting: \(bad)")
    }

    @Test("Shimmer under hovering pointer and late frames stays phase-locked across 6 seeds")
    func shimmerUnderHoveringPointerAndLateFramesStaysInStep() {
        var bad: [(UInt64, Float, Float)] = []
        for seed in UInt64(0)..<6 {
            let s = ShimmerState(since: -0.8, zoom: 1.6, tail: true, pad: 40.0, ring: true, band: 140.0)
            let rt = Self.makeRuntime(s)
            _ = rt.frame(at: 0.0)

            var x = (seed &* 0x9E37_79B9_7F4A_7C15) | 1
            func rnd() -> Double {
                x ^= x << 13
                x ^= x >> 7
                x ^= x << 17
                return Double(x % 1000) / 1000.0
            }

            var worstLoop: Float = 0.0
            var worstGlyph: Float = 0.0
            for k in 0..<900 {
                let r = rnd()
                let (catchUp, dt): (Double, Double) =
                    if r < 0.05 { (0.15 + rnd() * 0.3, 1.0 / 120.0) }
                    else if r < 0.15 { (1.0 / 60.0, 1.0 / 120.0) }
                    else { (0.0, 1.0 / 120.0) }

                let target = rt.currentTime + catchUp + dt
                rt.update(at: rt.currentTime) { st, _ in st.now = target }
                if rnd() < 0.2 { rt.invalidate(at: rt.currentTime) }
                if rnd() < 0.3 {
                    rt.pointerMove(to: Vec2(150 + Float(rnd()) * 120, 20 + Float(rnd()) * 20), at: rt.currentTime)
                }
                if k == 300 {
                    rt.update(at: rt.currentTime) { st, _ in st.on = false }
                    rt.invalidate(at: rt.currentTime)
                }
                if k == 300 + Int(seed % 3) * 4 + 1 {
                    rt.update(at: rt.currentTime) { st, _ in
                        st.on = true
                        st.since = target - 0.3
                    }
                    rt.invalidate(at: rt.currentTime)
                }
                _ = rt.frameSplit(catchUp: catchUp, dt: dt)
                if let (a, b) = Self.loopOffsets(rt) {
                    if abs(a + b) > abs(worstLoop) { worstLoop = a + b }
                }
                worstGlyph = Self.worstOf(rt, worstGlyph)
            }
            if abs(worstLoop) > 0.01 || worstGlyph.isNaN || !(abs(worstGlyph) < Self.glyphPxTolerance) {
                bad.append((seed, worstLoop, worstGlyph))
            }
        }
        #expect(bad.isEmpty, "out of step (seed, loopSum pt, glyphPx): \(bad)")
    }

    private enum WindowEvent {
        case stall(Double)
        case covered(Double)
        case restartCovered(Double)
        case stop
        case start
    }

    private static func driveWindow(
        _ rt: Runtime<ShimmerState>,
        secs: Double,
        events: inout [(Double, WindowEvent)]
    ) -> (loopSum: Float, glyphPx: Float) {
        let start = rt.currentTime
        var hostClock = start
        var quietFrom = start + 0.6
        var worstLoop: Float = 0.0
        var worstGlyph: Float = 0.0

        while hostClock < start + secs {
            var covered = false
            let gap: Double
            if let first = events.first, hostClock - start >= first.0 {
                let ev = events.removeFirst().1
                quietFrom = max(quietFrom, hostClock + 1.5)
                switch ev {
                case .stall(let g):
                    gap = g
                case .stop:
                    rt.update(at: hostClock) { st, _ in st.on = false }
                    gap = 1.0 / 120.0
                case .start:
                    let cur = hostClock
                    rt.update(at: cur) { st, _ in
                        st.on = true
                        st.since = cur
                    }
                    gap = 1.0 / 120.0
                case .covered(let g), .restartCovered(let g):
                    let restart: Bool
                    if case .restartCovered = ev { restart = true } else { restart = false }
                    rt.setLiveVisible(false, at: hostClock)
                    let end = hostClock + g
                    if restart {
                        rt.update(at: hostClock) { st, _ in st.on = false }
                    }
                    while hostClock < end {
                        hostClock += 0.05
                        let cur = hostClock
                        rt.update(at: cur) { st, _ in
                            st.now = cur
                            if restart && !st.on && cur >= end - g / 2.0 {
                                st.on = true
                                st.since = cur
                            }
                        }
                        rt.invalidate(at: cur)
                        _ = rt.hiddenWake(at: cur)
                    }
                    rt.setLiveVisible(true, at: hostClock)
                    rt.settleAll()
                    covered = true
                    gap = g
                }
            } else {
                gap = 1.0 / 120.0
            }

            let step = FrameClockStep.split(gap: gap, running: rt.isAnimating)
            if !covered {
                hostClock += max(0.0, gap - step.total)
            }
            let target = hostClock + step.total
            rt.update(at: target) { st, _ in st.now = target }
            rt.invalidate(at: target)
            let catchUp = max(0.0, hostClock - rt.currentTime) + step.catchUp
            _ = rt.frameSplit(catchUp: catchUp, dt: step.dt)
            hostClock = rt.currentTime

            func isWaiting(_ key: String) -> Bool {
                guard let node = rt.flatNodes.first(where: { $0.key == key }),
                      let track = rt.loopRuntime.tracks[node.nodeId] else { return false }
                let nt = rt.scene.store.nodeTime(node.nodeId)
                return track.pendingStart(at: nt) != nil
            }
            if isWaiting("sheen") != isWaiting("lit") {
                continue
            }
            if let (a, b) = Self.loopOffsets(rt), abs(a + b) > abs(worstLoop) {
                worstLoop = a + b
            }
            if rt.currentTime >= quietFrom && rt.state.on {
                worstGlyph = Self.worstOf(rt, worstGlyph)
            }
        }
        return (worstLoop, worstGlyph)
    }

    @Test("Shimmer survives window stalls, covered hidden wakes, restarts while covered, and late lit mounts at zoom 1.6")
    func shimmerThroughRealWindowStaysInStep() {
        let baseState = ShimmerState(since: -0.8, zoom: 1.6, tail: true, pad: 40.0, ring: true, band: 140.0)
        var cases: [(String, ShimmerState, [(Double, WindowEvent)])] = []

        for litAt in [0.3, 1.6, 2.9] {
            var s = baseState
            s.litAt = litAt
            cases.append(("litAt=\(litAt)", s, []))
            cases.append(("litAt=\(litAt) covered", s, [(litAt - 0.2, .covered(0.5))]))
        }
        for at in [0.5, 1.7, 2.0] {
            for g in [0.2, 0.6, 3.0] {
                cases.append(("stall at=\(at) g=\(g)", baseState, [(at, .stall(g))]))
            }
            for g in [0.3, 2.0, 6.0] {
                cases.append(("covered at=\(at) g=\(g)", baseState, [(at, .covered(g))]))
                cases.append(("restart covered at=\(at) g=\(g)", baseState, [(at, .restartCovered(g))]))
            }
            for off in [0.02, 0.2] {
                cases.append(("restart at=\(at) off=\(off) stall", baseState, [
                    (at, .stop),
                    (at + off, .start),
                    (at + off + 0.1, .stall(0.4)),
                ]))
            }
        }

        var bad: [(String, Float, Float)] = []
        for (tag, s, var events) in cases {
            let rt = Self.makeRuntime(s)
            _ = rt.frame(at: 0.0)
            let worst = Self.driveWindow(rt, secs: 7.0, events: &events)
            if abs(worst.loopSum) > 0.01 || worst.glyphPx.isNaN || !(abs(worst.glyphPx) < Self.glyphPxTolerance) {
                bad.append((tag, worst.loopSum, worst.glyphPx))
            }
        }
        #expect(bad.isEmpty, "window stress cases out of step: \(bad)")
    }

    @Test("Shimmer on a sleeping host wakes via wakeDeadline and keeps bright copy aligned across zoom and restart gaps")
    func shimmerOnSleepingHostKeepsBrightCopyOnLabel() {
        var bad: [(Float, Double, Double, Float)] = []
        for zoom in [Float(1.0), 1.6] {
            for gap in [0.05, 0.4, 1.3] {
                for stopAt in [0.7, 1.6, 2.05] {
                    let s = ShimmerState(since: -0.8, zoom: zoom, tail: true, ring: true, band: 140.0)
                    let rt = Self.makeRuntime(s)
                    _ = rt.frame(at: 0.0)

                    var events: [(Double, (inout ShimmerState) -> Void)] = [
                        (stopAt, { $0.on = false }),
                        (stopAt + gap, { $0.on = true; $0.since = -1.0 }),
                        (stopAt + gap + 1.1, { $0.zoom += 0.0 }),
                    ]

                    let until = stopAt + gap + 3.0 * Self.period(s)
                    var worst: Float = 0.0
                    var dt: Double = 1.0 / 120.0
                    while rt.currentTime < until {
                        let nextEvent = events.first?.0 ?? .infinity
                        let dtNow = min(dt, max(0.0, nextEvent - rt.currentTime))
                        let tNext = rt.currentTime + dtNow
                        rt.update(at: rt.currentTime) { st, _ in st.now = tNext }
                        if let first = events.first, first.0 <= tNext + 1e-9 {
                            let (_, fn) = events.removeFirst()
                            rt.update(at: rt.currentTime) { st, _ in
                                fn(&st)
                                if st.on && st.since < 0.0 {
                                    st.since = st.now
                                }
                            }
                            rt.invalidate(at: rt.currentTime)
                        }
                        _ = rt.frame(at: tNext)
                        let animating = rt.isAnimating
                        worst = Self.worstOf(rt, worst)
                        dt = animating
                            ? 1.0 / 120.0
                            : (rt.wakeDeadline().map { max(1.0 / 120.0, $0 - rt.currentTime) } ?? 0.25)
                    }
                    if worst.isNaN || !(abs(worst) < Self.glyphPxTolerance) {
                        bad.append((zoom, gap, stopAt, worst))
                    }
                }
            }
        }
        #expect(bad.isEmpty, "sleeping host drifted (zoom, gap, stopAt, px): \(bad)")
    }
}
