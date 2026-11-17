import Testing
@testable import Rune

/// Upstream `679dc1a7` (#956, nested virtual lists window against the outer viewport) and
/// `65f8eb43` (#972, `scroll_key_to` lands a virtual row that isn't mounted yet).
@Suite("VirtualNestingParity")
struct VirtualNestingParityTests {
    // MARK: - VirtualList::{at, locate, extent, passed} (#956)

    private func list(nested: Bool, top: Float, tail: Float = 0, viewport: Float = 300, padTop: Float = 0, padBottom: Float = 0) -> RuntimeVirtualListState {
        var v = RuntimeVirtualListState()
        v.nested = nested
        v.top = top
        v.tail = tail
        v.viewport = viewport
        v.padTop = padTop
        v.padBottom = padBottom
        return v
    }

    @Test("at: a list not nested offsets by its top and keeps the viewport's pin")
    func atNotNested() {
        let v = list(nested: false, top: 100)
        #expect(v.at(250, pinned: false, total: 1000) == (150, false))
        #expect(v.at(50, pinned: false, total: 1000) == (0, false))
        #expect(v.at(250, pinned: true, total: 1000) == (150, true))
    }

    @Test("at: a nested list is never pinned itself, standing where the viewport's end leaves it")
    func atNested() {
        let v = list(nested: true, top: 100, tail: 200, viewport: 300, padTop: 4, padBottom: 6)
        #expect(v.extent(total: 1000) == 1010)
        // Not pinned: scroll - top.
        #expect(v.at(600, pinned: false, total: 1000) == (500, false))
        #expect(v.at(40, pinned: false, total: 1000) == (0, false))
        // Pinned: extent + tail - viewport, and not pinned itself.
        #expect(v.at(0, pinned: true, total: 1000) == (910, false))
        // Clamped at 0 when the list and what runs under it are shorter than the viewport.
        let short = list(nested: true, top: 0, tail: 10, viewport: 300)
        #expect(short.at(0, pinned: true, total: 100) == (0, false))
    }

    @Test("locate: a nested list wholly above the viewport's top is passed and anchors nothing")
    func locatePassed() {
        var v = list(nested: true, top: 100, padTop: 4, padBottom: 6)
        _ = v.locate(100 + 1009, pinned: false, total: 1000)
        #expect(!v.passed)
        _ = v.locate(100 + 1010, pinned: false, total: 1000)
        #expect(v.passed)
        _ = v.locate(0, pinned: false, total: 1000)
        #expect(!v.passed)
        // A list not nested is never passed.
        var outer = list(nested: false, top: 100)
        _ = outer.locate(100_000, pinned: false, total: 1000)
        #expect(!outer.passed)
    }

    @Test("nested: another list's path is a strict ancestor under the same scroll path")
    func nestedDetection() {
        let outer = "/@root/@scroll/@outer"
        let inner = "/@root/@scroll/@outer/@o2/@section/@inner"
        #expect(Runtime<Int>.virtualListIsNested(path: inner, scrollPath: "/@root/@scroll", lists: [outer, inner]))
        // The list's own path, and a sibling whose path merely starts the same, are not ancestors.
        #expect(!Runtime<Int>.virtualListIsNested(path: outer, scrollPath: "/@root/@scroll", lists: [outer]))
        #expect(!Runtime<Int>.virtualListIsNested(path: "/@root/@scroll/@outer2", scrollPath: "/@root/@scroll", lists: [outer]))
        // An ancestor list outside the scroll viewport doesn't nest it.
        #expect(!Runtime<Int>.virtualListIsNested(path: "/@root/@list/@r1/@scroll/@inner", scrollPath: "/@root/@list/@r1/@scroll", lists: ["/@root/@list"]))
    }

    @Test("prefix: rows above an index at their measured or estimated heights")
    func prefixHeights() {
        var v = RuntimeVirtualListState()
        v.lastKeys = ["a", "b", "c"]
        v.measuredByKey["b"] = 50
        #expect(v.prefix(0, estimated: 20) == 0)
        #expect(v.prefix(2, estimated: 20) == 70)
        #expect(v.prefix(3, estimated: 20) == 90)
    }

    @Test("landings: each jump is placed again while windows move, at most three times")
    func landingRounds() {
        var l = ScrollKeyLandings()
        let req = ScrollOffsetRequest(key: "r", y: 0, anchor: true)
        var taken = l.take([req])
        #expect(taken == [ScrollKeyLanding(request: req, round: 0)])
        for round in 0..<ScrollKeyLanding.maxRounds {
            l.land(taken[0])
            let queued = l.finish(windowsMoved: true)
            #expect(queued)
            taken = l.take([])
            #expect(taken == [ScrollKeyLanding(request: req, round: round + 1)])
        }
        l.land(taken[0])
        let queuedPastLimit = l.finish(windowsMoved: true)
        #expect(!queuedPastLimit)
        #expect(!l.awaiting)
        // No window moved: nothing is placed again.
        l.land(ScrollKeyLanding(request: req, round: 0))
        let queuedUnmoved = l.finish(windowsMoved: false)
        #expect(!queuedUnmoved)
        let none = l.take([])
        #expect(none.isEmpty)
    }

    // MARK: - Runtime (#956)

    struct S {}

    /// An outer virtual list in a scroll viewport whose third row is a long section: a 4000pt
    /// header over a nested list of 1000 rows of 20pt (it starts 4200pt into the viewport's content).
    private func timeline(stick: Bool) -> Runtime<S> {
        Runtime<S>(state: S(), viewport: Vec2(240, 300), pixelScale: 1.0) { _, _ in
            col().key("scroll").size(240, 300).scrollY(stickBottom: stick).child(
                col().key("outer").w(240).virtualRows(
                    count: 5,
                    estimatedRowHeight: 100,
                    key: { _, i in "o\(i)" },
                    build: { _, i in
                        guard i == 2 else { return el().size(240, 100) }
                        return col().w(240)
                            .child(el().key("header").size(240, 4000))
                            .child(col().key("inner").w(240).virtualRows(
                                count: 1000,
                                estimatedRowHeight: 20,
                                key: { _, j in "i\(j)" },
                                build: { _, _ in el().size(240, 20) }
                            ))
                    }
                )
            )
        }
    }

    private func mountedInner(_ rt: Runtime<S>) -> [Int] {
        rt.elements().compactMap { e in
            guard !e.exiting, let k = e.key, k.hasPrefix("i"), let j = Int(k.dropFirst()) else { return nil }
            return j
        }
    }

    @Test("a list in a row of another windows against the same viewport where the row places it")
    func nestedListWindowsAgainstOuterViewport() {
        let rt = timeline(stick: false)
        _ = rt.frame(at: 0)
        var t = 0.0
        rt.update(at: 0.01) { _, tx in tx.scrollToInstant("scroll", x: 0, y: 4200 + 20 * 500) }
        for _ in 0..<12 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        #expect(abs(rt.scrollOffset(forKey: "scroll").y - 14_200) < 0.5)
        let mounted = mountedInner(rt)
        // The rows in view are mounted, not all of them, and not the list's first rows.
        for j in 500..<515 { #expect(mounted.contains(j), "row i\(j) in view is mounted") }
        #expect(!mounted.contains(0))
        #expect(mounted.count < 1000)
        // Row i500 sits at the viewport's top.
        let scrollTop = rt.element(byKey: "scroll")?.target[1] ?? 0
        let i500 = rt.element(byKey: "i500")
        #expect(i500 != nil)
        #expect(abs((i500?.target[1] ?? -1) - scrollTop) < 0.5)
    }

    @Test("while the viewport holds its end, a nested list windows where the end leaves it")
    func nestedListWindowsAtTheViewportsEnd() {
        let rt = timeline(stick: true)
        var t = 0.0
        for _ in 0..<12 {
            _ = rt.frame(at: t)
            t += 1.0 / 60.0
        }
        let scrollTop = rt.element(byKey: "scroll")?.target[1] ?? 0
        // The viewport holds its end: the two 100pt rows under the section show under its last rows.
        let max = rt.scrollMaxExtents["/@scroll"]?.y ?? rt.scrollMaxExtents.values.map(\.y).max() ?? 0
        #expect(max > 20_000)
        #expect(abs(rt.scrollOffset(forKey: "scroll").y - max) < 0.5)
        let mounted = mountedInner(rt)
        for j in 995..<1000 { #expect(mounted.contains(j), "row i\(j) above the end is mounted") }
        #expect(!mounted.contains(0))
        #expect(mounted.count < 1000)
        let last = rt.element(byKey: "i999")?.target ?? [0, -1000, 0, 0]
        #expect(abs(last[1] + last[3] - (scrollTop + 300 - 200)) < 0.5)
    }

    // MARK: - Runtime (#972)

    /// A virtual list estimating 20pt rows that lay out at 30pt, in a 300pt viewport.
    private func transcript(stick: Bool) -> Runtime<S> {
        Runtime<S>(state: S(), viewport: Vec2(240, 300), pixelScale: 1.0) { _, _ in
            col().key("scroll").size(240, 300).scrollY(stickBottom: stick).child(
                col().key("list").w(240).virtualRows(
                    count: 1000,
                    estimatedRowHeight: 20,
                    key: { _, i in "r\(i)" },
                    build: { _, _ in el().size(240, 30).bg(Color.white).transition(.opacity) }
                )
            )
        }
    }

    @Test("scrollKeyTo lands a virtual row that isn't mounted yet, placed from its layout in the frame")
    func scrollKeyToLandsUnmountedVirtualRow() {
        for stick in [false, true] {
            let rt = transcript(stick: stick)
            _ = rt.frame(at: 0)
            _ = rt.frame(at: 1.0 / 60.0)
            #expect(rt.element(byKey: "r600") == nil, "r600 starts unmounted")
            let before = rt.scrollOffset(forKey: "scroll").y
            rt.update(at: 0.02) { _, tx in tx.scrollKeyTo("r600", at: 12) }
            _ = rt.frame(at: 0.03)
            // The jump moved the viewport, mounted the row, and placed its top 12pt under the
            // viewport's top from its laid-out position, in this one frame.
            let row = rt.element(byKey: "r600")
            #expect(row != nil, "the jump mounts r600 (stick: \(stick))")
            #expect(abs(rt.scrollOffset(forKey: "scroll").y - before) > 1000)
            if let row {
                let scrollTop = rt.element(byKey: "scroll")?.target[1] ?? 0
                #expect(abs(row.target[1] - (scrollTop + 12)) < 0.5, "r600 lands 12pt under the top (stick: \(stick))")
            }
            // The rows the jump mounts show at once instead of fading in.
            #expect((rt.presented("r600")?.opacity ?? 0) > 0.99)
            #expect((rt.presented("r601")?.opacity ?? 0) > 0.99)
        }
    }

    @Test("a single row/mark jump mounts an offscreen row and lands on its scoped descendant")
    func scrollKeyToLandsScopedDescendant() {
        let rt = Runtime<S>(state: S(), viewport: Vec2(240, 300), pixelScale: 1.0) { _, _ in
            col().key("scroll").size(240, 300).scrollY().child(
                col().key("list").w(240).virtualRows(
                    count: 1000, estimatedRowHeight: 30, key: { _, i in "r\(i)" },
                    build: { _, _ in
                        col().w(240).child(el().size(240, 10)).child(
                            col().key("inner").child(el().key("mark").size(240, 20))
                        )
                    }
                )
            )
        }
        _ = rt.frame(at: 0)
        #expect(rt.element(byKey: "r600") == nil)
        rt.update(at: 0.02) { _, tx in tx.scrollKeyTo("r600/mark", at: 12) }
        _ = rt.frame(at: 0.03)
        let row = rt.element(byKey: "r600")
        #expect(row != nil)
        if let row {
            let vp = rt.element(byKey: "scroll")!.target
            #expect(abs(row.target[1] + 10 - vp[1] - 12) < 0.5)
        }
    }

    @Test("scrollKeyTo for a key no list holds leaves the viewport where it was")
    func scrollKeyToUnknownKey() {
        let rt = transcript(stick: false)
        _ = rt.frame(at: 0)
        rt.update(at: 0.01) { _, tx in tx.scrollToInstant("scroll", x: 0, y: 900) }
        _ = rt.frame(at: 0.02)
        let before = rt.scrollOffset(forKey: "scroll").y
        rt.update(at: 0.03) { _, tx in tx.scrollKeyTo("missing", at: 0) }
        _ = rt.frame(at: 0.04)
        #expect(abs(rt.scrollOffset(forKey: "scroll").y - before) < 0.5)
        #expect(rt.scrollKeyLandings.pending.isEmpty)
    }
}
