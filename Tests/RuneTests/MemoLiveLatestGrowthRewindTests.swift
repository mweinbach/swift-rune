import Foundation
import Testing
@testable import Rune
@testable import RuneMotion
@testable import RuneRef

// MARK: - Latest Tests (`latest/tests.rs`)

@Suite("Latest<T> Parity Tests")
struct LatestParityTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func inc() {
            lock.withLock { count += 1 }
        }

        var value: Int {
            lock.withLock { count }
        }
    }

    private func eventually(_ what: String, timeout: TimeInterval = 5.0, done: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() {
            if Date() >= deadline {
                Issue.record("Timed out waiting until \(what)")
                return
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    @Test func newestAnswerWinsWhenOlderFinishesLastAndUntakenDropped() {
        let wakes = Counter()
        let search = Latest<String>(waker: { wakes.inc() })

        let semStart = DispatchSemaphore(value: 0)
        let semGate = DispatchSemaphore(value: 0)
        let oldFinished = Counter()

        search.request("a") { q in
            semStart.signal()
            semGate.wait()
            oldFinished.inc()
            return q
        }
        semStart.wait()

        search.request("ab") { q in q }
        eventually("ab lands") { wakes.value == 1 }
        #expect(search.take() == "ab")
        #expect(!search.isPending)

        semGate.signal()
        eventually("older finishes") { oldFinished.value == 1 }
        Thread.sleep(forTimeInterval: 0.01)
        #expect(search.take() == nil)
        #expect(wakes.value == 1)

        // Newer request drops an untaken answer
        search.request("first") { q in q }
        eventually("first lands") { wakes.value == 2 }
        let semGate2 = DispatchSemaphore(value: 0)
        search.request("second") { q in
            semGate2.wait()
            return q
        }
        #expect(search.take() == nil)
        #expect(search.isPending)
        semGate2.signal()
        eventually("second lands") { wakes.value == 3 }
        #expect(search.take() == "second")
        #expect(!search.isPending)
    }

    @Test func debounceSetWakerAndCancelSemantics() {
        let wakes = Counter()
        let search = Latest<String>(waker: { wakes.inc() }).debounce(0.08)
        final class Runs: @unchecked Sendable {
            let lock = NSLock()
            var items: [String] = []
            func append(_ s: String) { lock.withLock { items.append(s) } }
            func snapshot() -> [String] { lock.withLock { items } }
        }
        let runs = Runs()

        for q in ["a", "ab", "abc"] {
            search.request(q) { s in
                runs.append(s)
                return s
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        eventually("abc lands") { wakes.value == 1 }
        #expect(search.take() == "abc")
        #expect(runs.snapshot() == ["abc"])

        // setWaker after submission replaces waker and preserves pending debounced request
        let oldWakes = Counter()
        let newWakes = Counter()
        let deferred = Latest<Int>(waker: { oldWakes.inc() }).debounce(0.08)
        deferred.request(7) { $0 }
        #expect(deferred.isPending)
        deferred.setWaker { newWakes.inc() }
        #expect(deferred.isPending)
        eventually("deferred lands on new waker") { newWakes.value == 1 }
        #expect(oldWakes.value == 0)
        #expect(deferred.take() == 7)

        // cancel cancels pending debounced work
        let cancelledRuns = Counter()
        search.request("drop") { s in
            cancelledRuns.inc()
            return s
        }
        search.cancel()
        #expect(!search.isPending)
        Thread.sleep(forTimeInterval: 0.1)
        #expect(cancelledRuns.value == 0)
        #expect(search.take() == nil)
    }

    @Test func requestIfChangedAndRequestOptParity() {
        let wakes = Counter()
        let search = Latest<Int>(waker: { wakes.inc() })
        let runs = Counter()

        for _ in 0..<5 {
            search.requestIfChanged(key: 42) { k in
                runs.inc()
                return k * 2
            }
        }
        eventually("first key lands") { wakes.value == 1 }
        search.requestIfChanged(key: 42) { k in
            runs.inc()
            return k * 2
        }
        Thread.sleep(forTimeInterval: 0.02)
        #expect(runs.value == 1)
        #expect(wakes.value == 1)
        #expect(search.take() == 84)

        search.cancel()
        search.requestIfChanged(key: 42) { k in k + 10 }
        eventually("after cancel key runs again") { wakes.value == 2 }
        #expect(search.take() == 52)

        // requestOpt returning nil settles without waking and supersedes prior untaken result
        let optRan = Counter()
        search.request(100) { $0 }
        eventually("100 lands") { wakes.value == 3 }
        search.requestOpt(99) { _ in
            optRan.inc()
            return nil
        }
        eventually("requestOpt settles") { !search.isPending && optRan.value == 1 }
        #expect(search.take() == nil)
        #expect(wakes.value == 3)
    }

    @Test func deinitCancelsWithoutWaking() {
        let wakes = Counter()
        let semGate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let finished = Counter()

        do {
            let scoped = Latest<Int>(waker: { wakes.inc() })
            scoped.request(1) { n in
                started.signal()
                semGate.wait()
                finished.inc()
                return n
            }
            started.wait()
        }
        semGate.signal()
        eventually("worker completes") { finished.value == 1 }
        Thread.sleep(forTimeInterval: 0.01)
        #expect(wakes.value == 0)
    }
}

// MARK: - Growth Parity Tests (`growth.rs`)

@Suite("Growth Parity Tests")
struct GrowthParityTests {
    private static let foldSpring = Spring(duration: 0.18, bounce: 0.0)

    private func fold(from: Float, to: Float, secs: Float, limit: Float = 900.0) -> (GrowTrack, [(Float, Float)]) {
        var t = GrowTrack.settled(from)
        t.whole = true
        t.setKind(streaming: false, whole: true, glide: (FoldGlide(spring: Self.foldSpring, feather: nil), limit))
        t.retarget(to)
        var out: [(Float, Float)] = [(0.0, t.h)]
        let frames = Int(secs * 120.0)
        for k in 0..<frames {
            t.step(spring: Growth.spring, edge: .feather, carryingTail: false)
            t.step(spring: Growth.spring, edge: .feather, carryingTail: false)
            out.append((Float(k + 1) / 120.0, t.h))
        }
        return (t, out)
    }

    @Test func foldGlidesOnOwnSpringWithinDurationAndNoOvershoot() {
        for (from, to) in [(Float(40), Float(640)), (Float(640), Float(40)), (Float(40), Float(900))] {
            let (t, hs) = fold(from: from, to: to, secs: 0.5)
            let idx = Int((Self.foldSpring.duration * 120.0).rounded())
            let left = abs(hs[idx].1 - to)
            #expect(left < 0.02 * abs(to - from))
            #expect(!t.moving)
            let minH = min(from, to) - 1e-3
            let maxH = max(from, to) + 1e-3
            #expect(hs.allSatisfy { $0.1 >= minH && $0.1 <= maxH })
        }
    }

    @Test func foldLandsWithoutCreepingAndPastWindowMovesOnlyVisiblePart() {
        let (tClose, hsClose) = fold(from: 3040.0, to: 40.0, secs: 0.5, limit: 900.0)
        #expect(hsClose[0].1 == 900.0)
        #expect(!tClose.moving && tClose.h == 40.0)

        let (tOpen, hsOpen) = fold(from: 40.0, to: 3040.0, secs: 0.5, limit: 900.0)
        #expect(!tOpen.moving && tOpen.h == 3040.0)
        let jumpIdx = hsOpen.firstIndex { $0.1 > 900.0 }!
        #expect(hsOpen[jumpIdx - 1].1 > 898.0 && hsOpen[jumpIdx].1 == 3040.0)
    }

    @Test func foldFeatherBothWaysAndReversalPreservesVelocity() {
        for (from, to) in [(Float(40), Float(640)), (Float(640), Float(40))] {
            var t = GrowTrack.settled(from)
            t.whole = true
            t.setKind(
                streaming: false,
                whole: true,
                glide: (FoldGlide(spring: Self.foldSpring, feather: 20.0), Float.infinity)
            )
            t.retarget(to)
            var masks: [Float] = []
            for _ in 0..<120 {
                t.step(spring: Growth.spring, edge: .feather, carryingTail: false)
                t.step(spring: Growth.spring, edge: .feather, carryingTail: false)
                masks.append(t.mask)
            }
            let peak = masks.max() ?? 0
            #expect(abs(peak - 20.0) < 1e-3)
            #expect(masks.first! < 6.0)
            #expect(masks.last! == 0.0)
        }

        // Reversal mid-glide keeps velocity without snapping
        var rev = GrowTrack.settled(640.0)
        rev.whole = true
        rev.setKind(streaming: false, whole: true, glide: (FoldGlide(spring: Self.foldSpring, feather: nil), 900.0))
        rev.retarget(40.0)
        for _ in 0..<12 {
            rev.step(spring: Growth.spring, edge: .feather, carryingTail: false)
        }
        let h0 = rev.h
        #expect(rev.v < 0 && h0 < 640.0 && h0 > 40.0)
        rev.retarget(640.0)
        #expect(rev.h == h0)
        rev.step(spring: Growth.spring, edge: .feather, carryingTail: false)
        #expect(rev.h < h0)
        for _ in 0..<120 {
            rev.step(spring: Growth.spring, edge: .feather, carryingTail: false)
        }
        #expect(!rev.moving && rev.h == 640.0)
    }

    @Test func hideAboveAndRideUpLiftContentsWithoutMovingViewport() {
        var t = GrowTrack.settled(200.0)
        t.setKind(streaming: false, whole: true, glide: (FoldGlide(spring: Self.foldSpring, feather: nil), 900.0))
        t.retarget(50.0)
        let cut = t.hideAbove(40.0)
        #expect(cut == 40.0)
        #expect(t.h == 160.0)
        #expect(abs(t.currentLift() - 40.0) < 1e-3)

        t.retarget(250.0)
        t.rideUp(50.0)
        #expect(t.isStaged)
        t.forgetFolded()
        #expect(t.currentLift() == 0)
        #expect(!t.isShut)
    }
}

// MARK: - Memo, Snapshot & Region Parity Tests (`memo.rs` & `snapshot/tests.rs`)

@Suite("Memo, Snapshot & Region Parity Tests", .serialized)
struct MemoSnapshotParityTests {
    @Test func snapshotValuesStayStableAcrossCommitRetriesAndRestoreOnThrow() {
        let hist = MemoSnapshotHistory()
        var seen = false
        var count = 9

        MemoSnapshot.enter(history: hist) {
            for _ in 0..<4 {
                #expect(!snapshot("item", seen))
                #expect(snapshot("item", count) == 9)
                seen = true
                count = 8
            }
        }

        MemoSnapshot.enter(history: hist) {
            #expect(snapshot("item", seen))
            #expect(snapshot("item", count) == 8)
            #expect(snapshot("other", 12) == 12)
        }

        enum TestErr: Error { case abort }
        MemoSnapshot.enter(history: hist) {
            #expect(snapshot("item", 77) == 8)
            do {
                try MemoSnapshot.enter(history: hist) {
                    #expect(snapshot("item", 99) == 99)
                    throw TestErr.abort
                }
            } catch {}
            #expect(snapshot("item", 77) == 8)
        }
    }

    @Test func memoReuseEnvInvalidationAndDuplicateGuardParity() {
        struct S { var version: Int; var ticks: Int; var presses: Int }
        final class Counter: @unchecked Sendable { var n = 0 }
        let builds = Counter()

        let rt = Runtime(
            state: S(version: 0, ticks: 0, presses: 0),
            viewport: Vec2(200, 200),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            col().size(200, 200).children([
                memo("card", s.version) {
                    builds.n += 1
                    return col().child(
                        el().key("button").size(40, 40).bg(.white).onClick { st in st.presses += 1 }
                    )
                },
                text("tick \(s.ticks)").key("tick")
            ])
        }

        _ = rt.frame(at: 0.0)
        #expect(builds.n == 1)

        for i in 1...3 {
            rt.update { st, _ in st.ticks += 1 }
            _ = rt.frame(at: Double(i) / 60.0)
        }
        #expect(builds.n == 1)

        let btnRect = rt.element(byKey: "button")!.rect
        let cx = btnRect[0] + btnRect[2] * 0.5
        let cy = btnRect[1] + btnRect[3] * 0.5
        rt.pointerDown(at: Vec2(cx, cy), at: 0.1)
        rt.pointerUp(at: Vec2(cx, cy), at: 0.11)
        _ = rt.frame(at: 0.12)
        #expect(rt.state.presses == 1)
        #expect(builds.n == 1)

        rt.update { st, _ in st.version += 1 }
        _ = rt.frame(at: 0.2)
        #expect(builds.n == 2)

        rt.setSystemDark(false)
        _ = rt.frame(at: 0.25)
        #expect(builds.n == 3)

        rt.setViewport(Vec2(200, 200), pixelScale: 2.0)
        _ = rt.frame(at: 0.3)
        #expect(builds.n == 4)

        rt.memo.clear()
        rt.invalidate()
        _ = rt.frame(at: 0.35)
        #expect(builds.n == 5)
    }

    @Test func samePassDuplicateIdBuildsBothAndNestedMemoSurvivesKeepSince() {
        final class Counter: @unchecked Sendable { var n = 0 }
        let builds = Counter()

        let rtDup = Runtime(state: 0, viewport: Vec2(200, 200), pixelScale: 1.0) { _, _ in
            col().children([
                col().key("a").child(memo("same", 0) { builds.n += 1; return text("a").key("t") }),
                col().key("b").child(memo("same", 0) { builds.n += 1; return text("b").key("t") })
            ])
        }
        _ = rtDup.frame(at: 0.0)
        rtDup.invalidate()
        _ = rtDup.frame(at: 0.02)
        let texts = rtDup.elements().compactMap(\.text)
        #expect(texts == ["a", "b"])
        #expect(builds.n == 3)

        // Nested memo inside reused outer memo
        let nestedBuilds = Counter()
        let rtNest = Runtime(state: (0, 0), viewport: Vec2(200, 200), pixelScale: 1.0) { s, _ in
            col().child(
                memo("outer", s.0) {
                    nestedBuilds.n += 1
                    return col().children([
                        memo("inner", s.1) {
                            nestedBuilds.n += 1
                            return text("inner").key("t")
                        },
                        text("outer \(s.0)")
                    ])
                }
            )
        }
        _ = rtNest.frame(at: 0.0)
        #expect(nestedBuilds.n == 2)
        rtNest.invalidate()
        _ = rtNest.frame(at: 0.02)
        #expect(nestedBuilds.n == 2)
        rtNest.update { st, _ in st.0 += 1 }
        _ = rtNest.frame(at: 0.04)
        #expect(nestedBuilds.n == 3)
        rtNest.invalidateMemos(byPrefix: "outer")
        _ = rtNest.frame(at: 0.06)
        #expect(nestedBuilds.n == 5)
    }

    @Test func layoutSizeAndWindowLayoutThresholdInsideMemo() {
        struct Moving { var top: Float; var width: Float; var ticks: Int }
        final class Counter: @unchecked Sendable { var n = 0 }
        let builds = Counter()

        let rt = Runtime(
            state: Moving(top: 0, width: 100, ticks: 0),
            viewport: Vec2(300, 300),
            pixelScale: 1.0
        ) { s, cx in
            col().size(300, 300).children([
                el().key("gap").size(10, s.top),
                el().key("probe").size(s.width, 10),
                memo("sz", 0) {
                    builds.n += 1
                    let sz = cx.layoutSize("probe") ?? [-1, -1]
                    return text("sz=\(Int(sz[0]))x\(Int(sz[1]))").key("sz")
                },
                memo("rect", 0) {
                    builds.n += 1
                    let r = cx.layout("probe") ?? [-1, -1, -1, -1]
                    return text("y=\(Int(r[1]))").key("rect")
                },
                text("tick \(s.ticks)").key("tick")
            ])
        }
        _ = rt.frame(at: 0.0)
        #expect(rt.element(byKey: "sz")?.text == "sz=100x10")
        let initialBuilds = builds.n

        rt.update { st, _ in
            st.top = 40
            st.ticks += 1
        }
        _ = rt.frame(at: 0.05)
        // Moving `top` moves rect y -> rebuilds ONLY `rect`, not `sz`!
        #expect(builds.n == initialBuilds + 1)

        rt.update { st, _ in st.width = 150 }
        _ = rt.frame(at: 0.1)
        #expect(builds.n == initialBuilds + 3)
        #expect(rt.element(byKey: "sz")?.text == "sz=150x10")
    }

    @Test func regionWithTrackedCellsAndDebugWarnings() {
        clearRegionWarnings()
        let cache = MemoCache()
        let tracked = Tracked(1)
        var nonTracked = "first"

        let e1: El<Int> = regionWith("r-warn", inputs: 0, cache: cache) {
            let v = tracked.value
            return text("\(v):\(nonTracked)")
        }
        #expect(e1.plainText == "1:first")
        #expect(regionWarnings().isEmpty)

        nonTracked = "second"
        _ = regionWith("r-warn", inputs: 0, cache: cache) { () -> El<Int> in
            let v = tracked.value
            return text("\(v):\(nonTracked)")
        }
        #if DEBUG
        #expect(regionWarnings().count == 1)
        #expect(regionWarnings()[0].contains("r-warn"))
        #endif

        tracked.value = 2
        let e2: El<Int> = regionWith("r-warn", inputs: 0, cache: cache) {
            let v = tracked.value
            return text("\(v):\(nonTracked)")
        }
        #expect(e2.plainText == "2:second")
    }
}

// MARK: - Rewind & Live Parity Tests (`rewind/tests.rs` & `live.rs`)

@Suite("Rewind & Live Parity Tests")
struct RewindAndLiveParityTests {
    private struct AppState {
        var y: Float = 0
        var rewind = Rewind()
        var scrub = Scrub()
        var sent: [RewindSent] = []
        var inset: Float = 0
    }

    private func makeApp(rewind: Rewind = Rewind()) -> Runtime<AppState> {
        let rt = Runtime(
            state: AppState(rewind: rewind),
            viewport: Vec2(400, 300),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            let appEl: El<AppState> = el()
                .size(400, 300)
                .child(el().key("title").absolute(x: 10, y: s.y).size(100, 20).bg(.white))
                .child(el().key("still").absolute(x: 200, y: 200).size(40, 40).bg(.white))
            return el()
                .size(400, 300)
                .child(appEl)
                .child(
                    el()
                        .absolute(x: s.inset, y: s.inset)
                        .size(400 - s.inset, 300 - s.inset)
                        .child(s.scrub.view(\.scrub) { st, sent, _ in st.sent.append(sent) })
                )
        }
        _ = rt.frame(at: 0.0)
        return rt
    }

    private func attach(_ rt: Runtime<AppState>) {
        rt.update { s, tx in tx.recordRewind(s.rewind) }
        _ = rt.frame(at: rt.currentTime + 1.0 / 60.0)
    }

    private func jump(_ rt: Runtime<AppState>, y: Float) {
        rt.update { s, tx in
            s.y = y
            tx.settle()
        }
    }

    private func stepFrames(_ rt: Runtime<AppState>, count: Int) {
        for _ in 0..<count {
            _ = rt.frame(at: rt.currentTime + 1.0 / 60.0)
        }
    }

    @Test func attachDetachWindowAndByteBudget() {
        let rt = makeApp()
        stepFrames(rt, count: 5)
        #expect(rt.rewind() == nil)
        #expect(rt.state.rewind.frameCount == 0)

        // Poll can attach recorder
        rt.poll = { s, _, tx in
            if s.y == 0 {
                s.y = 1
                tx.recordRewind(s.rewind)
                return true
            }
            return false
        }
        stepFrames(rt, count: 3)
        #expect(rt.rewind() != nil)
        #expect(rt.state.rewind.frameCount > 0)
        rt.poll = nil

        let held = rt.state.rewind.frameCount
        rt.update { _, tx in tx.recordRewind(nil) }
        stepFrames(rt, count: 5)
        #expect(rt.state.rewind.frameCount == held)

        // Window retention keeps ~1s of 60Hz frames (~59..62)
        let rtWin = makeApp(rewind: Rewind().seconds(1.0))
        attach(rtWin)
        stepFrames(rtWin, count: 30)
        jump(rtWin, y: 40)
        stepFrames(rtWin, count: 300)
        let winFrames = rtWin.state.rewind.frameCount
        #expect((59...62).contains(winFrames))
        let clip = rtWin.state.rewind.freeze()
        #expect(clip.frame(0).count == 2)

        // Byte budget respected
        let budget = 4096
        let rtBudget = makeApp(rewind: Rewind().maxBytes(budget))
        attach(rtBudget)
        for k in 0..<120 {
            jump(rtBudget, y: Float(k % 50))
            _ = rtBudget.frame(at: rtBudget.currentTime + 1.0 / 60.0)
        }
        #expect(rtBudget.state.rewind.estimatedBytes <= budget)
        #expect(rtBudget.state.rewind.frameCount > 10)
    }

    @Test func jumpBlipSmoothMotionAndScrubberKeysAndBundle() throws {
        let rt = makeApp()
        attach(rt)
        stepFrames(rt, count: 10)
        jump(rt, y: 7.5)
        stepFrames(rt, count: 10)

        let clip = rt.state.rewind.freeze()
        let kJump = (0..<clip.len).first { clip.hasJump($0) }!
        let changes = clip.changes(kJump)
        #expect(changes.count == 1)
        #expect(changes[0].jump)
        #expect(changes[0].label() == "title ↓7.5 pt")
        #expect(abs(clip.activity(kJump) - 7.5) < 0.01)
        #expect(clip.activity(kJump + 1) == 0)

        // Bundle output check
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rune-rewind-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let bundle = try clip.writeBundle(to: tmpDir, range: 0..<clip.len, note: "the title hops")
        let trace = try String(contentsOf: tmpDir.appendingPathComponent("trace.jsonl"), encoding: .utf8)
        let traceLines = trace.split(separator: "\n")
        #expect(traceLines.first?.contains("\"type\":\"header\"") == true)
        #expect(traceLines.count == clip.len + 1)
        #expect(trace.contains(",10,7.5,100,20,1,0,0]"))
        let pngBytes = try Data(contentsOf: tmpDir.appendingPathComponent("contact.png"))
        #expect(Array(pngBytes.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        let summary = try String(contentsOf: tmpDir.appendingPathComponent("summary.md"), encoding: .utf8)
        #expect(summary == bundle.summary)
        #expect(summary.contains("> the title hops"))
        #expect(summary.contains("## Jumps") && summary.contains("title ↓7.5 pt"))

        // Blip out and back produces only 1 jump frame
        let rtBlip = makeApp()
        attach(rtBlip)
        stepFrames(rtBlip, count: 10)
        jump(rtBlip, y: 9.0)
        stepFrames(rtBlip, count: 1)
        jump(rtBlip, y: 0.0)
        stepFrames(rtBlip, count: 10)
        let blipClip = rtBlip.state.rewind.freeze()
        let blipJumps = (0..<blipClip.len).filter { blipClip.hasJump($0) }
        #expect(blipJumps.count == 1)
        #expect(blipClip.changes(blipJumps[0])[0].label() == "title ↓9.0 pt")

        // Smooth motion has zero jumps
        let rtSmooth = makeApp()
        attach(rtSmooth)
        for k in 1...30 {
            jump(rtSmooth, y: Float(k) * 3.0)
            stepFrames(rtSmooth, count: 1)
        }
        let smoothClip = rtSmooth.state.rewind.freeze()
        #expect((0..<smoothClip.len).allSatisfy { !smoothClip.hasJump($0) })

        // Scrubber keys + inset view + Send button
        let rtScrub = makeApp()
        rtScrub.update { s, tx in
            s.inset = 50
            tx.settle()
        }
        attach(rtScrub)
        stepFrames(rtScrub, count: 5)
        jump(rtScrub, y: 30)
        stepFrames(rtScrub, count: 5)
        rtScrub.update { s, _ in
            s.scrub.open(s.rewind)
            s.scrub.setNote("title jumps")
        }
        stepFrames(rtScrub, count: 2)
        #expect(rtScrub.state.scrub.isOpen && rtScrub.state.rewind.isPaused)
        let movedId = rtScrub.state.scrub.clip!.changes(rtScrub.state.scrub.currentFrameIndex)[0].id
        let boxRect = rtScrub.element(byKey: "rewind-box-\(movedId)")!.rect
        #expect(boxRect == [10, 30, 100, 20])
        let barRect = rtScrub.element(byKey: "rewind-bar")!.rect
        #expect(barRect[0] >= 50)

        let sendRect = rtScrub.element(byKey: "rewind-send")!.rect
        let sx = sendRect[0] + sendRect[2] * 0.5
        let sy = sendRect[1] + sendRect[3] * 0.5
        rtScrub.pointerDown(at: Vec2(sx, sy), at: rtScrub.currentTime + 0.01)
        rtScrub.pointerUp(at: Vec2(sx, sy), at: rtScrub.currentTime + 0.02)
        _ = rtScrub.frame(at: rtScrub.currentTime + 0.03)
        #expect(rtScrub.state.sent.count == 1)
        #expect(rtScrub.state.sent[0].note == "title jumps")

        let curK = rtScrub.state.scrub.currentFrameIndex
        #expect(rtScrub.state.scrub.key(KeyEvent(key: .arrowLeft)) == .handled)
        #expect(rtScrub.state.scrub.currentFrameIndex == curK - 1)
        #expect(rtScrub.state.scrub.key(KeyEvent(key: .arrowRight, mods: Mods(shift: true))) == .handled)
        #expect(rtScrub.state.scrub.key(KeyEvent(key: .arrowRight, mods: Mods(shift: true))) == .handled)
        #expect(rtScrub.state.scrub.selection == (curK - 1)..<(curK + 2))
        if case .send(let sentViaReturn) = rtScrub.state.scrub.key(KeyEvent(key: .enter)) {
            #expect(sentViaReturn.frames == (curK - 1)..<(curK + 2))
        } else {
            Issue.record("Expected Enter to return .send")
        }
        #expect(rtScrub.state.scrub.key(KeyEvent(key: .escape)) == .closed)
        #expect(!rtScrub.state.scrub.isOpen && !rtScrub.state.rewind.isPaused)
    }

    @Test func liveNonFiniteSanitizationAndLiveText() {
        let v = Live<Float>(0.5)
        #expect(!v.set(.nan))
        #expect(v.get() == 0.5)
        #expect(v.set(.infinity))
        #expect(v.get() == Float.greatestFiniteMagnitude)
        #expect(v.set(-.infinity))
        #expect(v.get() == -Float.greatestFiniteMagnitude)
        #expect(v.set(0.0))
        #expect(!v.set(-0.0))

        let lt = LiveText("hello")
        #expect(!lt.set("hello"))
        #expect(lt.set("world"))
        #expect(lt.get() == "world")
    }
}
