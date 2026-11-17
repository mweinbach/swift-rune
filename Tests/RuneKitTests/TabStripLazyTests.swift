import Foundation
import Testing
import Rune
@testable import RuneKit

/// Lazy `TabStrip` band (`rune_kit::shell::tab_strip`, upstream 80022c59 / #1020): `TabSlot`,
/// `BAND_PAST`, `TabStrip::lazy_tabs`, the scroll band and the unbuilt-run spacers.
@Suite("RuneKit TabStrip lazy band (#1020)")
struct TabStripLazyTests {
    struct S {
        var drag = TabDragState()
    }

    final class Calls {
        var built: [Int] = []
    }

    private func findEl<St>(_ root: El<St>, key: String) -> El<St>? {
        if root.keyId == key { return root }
        for child in root.children {
            if let found = findEl(child, key: key) { return found }
        }
        return nil
    }

    private func keys<St>(_ root: El<St>, containing part: String) -> [String] {
        var out: [String] = []
        func walk(_ node: El<St>) {
            if let k = node.keyId, k.contains(part) { out.append(k) }
            node.children.forEach(walk)
        }
        walk(root)
        return out
    }

    /// The tab ids `tN` and which are built (by key) in strip order.
    private func builtTabs<St>(_ root: El<St>, strip: String) -> [Int] {
        keys(root, containing: "\(strip)-tab-t").compactMap { Int($0.dropFirst("\(strip)-tab-t".count)) }
    }

    private func info(_ rt: Runtime<some Any>, _ key: String) -> ElementInfo? {
        rt.elements().first { !$0.exiting && $0.key == key }
    }

    @Test("BAND_PAST is 40 and TabSlot carries id, pinned, twoLine and keep")
    func constantsAndSlot() {
        #expect(BAND_PAST == 40)
        let slot = TabSlot(id: "a", pinned: true, twoLine: true, keep: true)
        #expect(slot.id == "a" && slot.pinned && slot.twoLine && slot.keep)
        let plain = TabSlot(id: "b")
        #expect(!plain.pinned && !plain.twoLine && !plain.keep)
        #expect(TabStripBand.twoLineHeight == 45.0)
        // Rust's saturating `as i32`.
        #expect(TabStripBand.saturatingInt(.nan) == 0)
        #expect(TabStripBand.saturatingInt(.infinity) == Int(Int32.max))
        #expect(TabStripBand.saturatingInt(-.infinity) == Int(Int32.min))
        #expect(TabStripBand.saturatingInt(-1.0) == -1)
    }

    @Test("band() before the first layout is the strip's start and the fallback long, a step more each side")
    func bandFallsBackBeforeLayout() {
        // Outside any layout the reads miss: `at` is 0 and `shows` is ceil(fallback / step).
        let h = TabStripBand.band(listKey: "x-list", scrollKey: "x-scroll", vertical: false, step: 120, fallback: 800)
        #expect(h.lo == -120 && h.hi == 9 * 120)
        let v = TabStripBand.band(listKey: "x-list", scrollKey: "x-scroll", vertical: true, step: 180, fallback: 1200)
        #expect(v.lo == -180 && v.hi == 9 * 180)
    }

    @Test("built(): the band's tabs plus the first, last, active, dragged, keep, pinned and those by the landing")
    func builtKeepsWhatAGestureKeyOrMenuIsOn() {
        let slots = (0..<50).map { TabSlot(id: "t\($0)", pinned: $0 == 0, keep: $0 == 30) }
        let pitches = [Float](repeating: 10, count: 50)
        // Band (-10, 50): tabs starting before 50 and ending after -10 are 0...4.
        let built = TabStripBand.built(
            slots: slots,
            pitches: pitches,
            band: (-10, 50),
            active: "t20",
            dragging: 25,
            landing: 40
        )
        let on = built.indices.filter { built[$0] }
        #expect(on == [0, 1, 2, 3, 4, 20, 25, 30, 39, 40, 49])
        // A landing at 0 keeps only slot 0 (no slot before it).
        let atStart = TabStripBand.built(slots: slots, pitches: pitches, band: (-10, 50), active: nil, dragging: nil, landing: 0)
        #expect(atStart.indices.filter { atStart[$0] } == [0, 1, 2, 3, 4, 30, 49])
    }

    @Test("Up to BAND_PAST tabs every tab is built, once each and in order; tabs given whole build them all")
    func atOrUnderBandPastBuildsEverything() {
        let k = Kit.neutral(dark: false)
        let calls = Calls()
        let slots = (0..<BAND_PAST).map { TabSlot(id: "t\($0)") }
        let tree: El<S> = TabStrip<S>(key: "lz")
            .lazyTabs(slots) { i in
                calls.built.append(i)
                return StripTabItem<S>(id: "t\(i)", title: "Tab \(i)")
            }
            .active("t3")
            .availableWidth(800)
            .build(S(), kit: k)
        #expect(calls.built == Array(0..<BAND_PAST))
        #expect(builtTabs(tree, strip: "lz") == Array(0..<BAND_PAST))
        #expect(keys(tree, containing: "-unbuilt-").isEmpty)

        // `.tabs` takes the same path: 41 whole tabs past BAND_PAST build only the band.
        let whole = (0..<(BAND_PAST + 1)).map { StripTabItem<S>(id: "t\($0)", title: "Tab \($0)") }
        let wholeTree: El<S> = TabStrip<S>(key: "wh", tabs: whole, selected: "t0").availableWidth(400).build(S(), kit: k)
        #expect(!keys(wholeTree, containing: "wh-list-unbuilt-").isEmpty)
        #expect(builtTabs(wholeTree, strip: "wh").contains(BAND_PAST))
        let last = findEl(wholeTree, key: "wh-tab-t\(BAND_PAST)")
        #expect(last?.a11yPosInSet?.position == BAND_PAST + 1)
        #expect(last?.a11yPosInSet?.size == BAND_PAST + 1)
    }

    @Test("Past BAND_PAST a horizontal strip builds the band and the kept tabs; runs between are hidden spacers their length")
    func horizontalBandAndSpacers() throws {
        let k = Kit.neutral(dark: false)
        let calls = Calls()
        // Slot 0 pinned, 70 kept (its menu is open), 50 active.
        let slots = (0..<100).map { TabSlot(id: "t\($0)", pinned: $0 == 0, keep: $0 == 70) }
        let tree: El<S> = TabStrip<S>(key: "hz")
            .lazyTabs(slots) { i in
                calls.built.append(i)
                return StripTabItem<S>(id: "t\(i)", title: "Tab \(i)").pinned(i == 0)
            }
            .active("t50")
            .availableWidth(800)
            .build(S(), kit: k)

        // 99 unpinned tabs in 800 points shrink to the 28 point minimum; the step is
        // max((28 + 2) * 4, 64) = 120, the fallback 800 shows ceil(800 / 120) = 7 steps, so the
        // band is (-120, 1080). Pitches: pinned 36 + 2 + separator 3 = 41; unpinned 28 + 2 + 3 = 33,
        // 30 for the tab before the active one, the active one and the last.
        let expectedBuilt = Array(0...32) + [50, 70, 99]
        #expect(calls.built == expectedBuilt)
        #expect(builtTabs(tree, strip: "hz") == expectedBuilt)
        #expect(keys(tree, containing: "hz-list-unbuilt-") == ["hz-list-unbuilt-33", "hz-list-unbuilt-51", "hz-list-unbuilt-71"])

        let list = try #require(findEl(tree, key: "hz-list"))
        #expect(list.role == .tabList)
        let childKeys = list.children.map { $0.keyId ?? "" }
        // tab32, its separator, the run 33..49, then the active tab (no separators either side).
        let i32 = try #require(childKeys.firstIndex(of: "hz-tab-t32"))
        #expect(Array(childKeys[i32...(i32 + 4)]) == ["hz-tab-t32", "hz-sep-32", "hz-list-unbuilt-33", "hz-tab-t50", "hz-list-unbuilt-51"])

        // Each spacer is its run's length less the list's own gap after it, a row high.
        let run33 = try #require(findEl(tree, key: "hz-list-unbuilt-33"))
        #expect(run33.isA11yHidden)
        #expect(run33.layout.width == .points(16 * 33 + 30 - 2))
        #expect(run33.layout.height == .points(TabDensity.full.height))
        #expect(findEl(tree, key: "hz-list-unbuilt-51")?.layout.width == .points(19 * 33 - 2))
        #expect(findEl(tree, key: "hz-list-unbuilt-71")?.layout.width == .points(28 * 33 - 2))

        // position_in_set still counts every tab.
        let t99 = try #require(findEl(tree, key: "hz-tab-t99"))
        #expect(t99.a11yPosInSet?.position == 100 && t99.a11yPosInSet?.size == 100)
        #expect(findEl(tree, key: "hz-tab-t50")?.a11yPosInSet?.position == 51)
    }

    @Test("Vertical spacers are full width and their run's rows high; a two-line row is 45 points")
    func verticalBandAndTwoLineRows() throws {
        let k = Kit.neutral(dark: false)
        // Rows of 28 (compact) + 3 gap, two-line rows of 45 + 3. Step max((28 + 3) * 6, 64) = 186,
        // fallback 1200 shows ceil(1200 / 186) = 7 steps: band (-186, 1674).
        let slots = (0..<80).map { TabSlot(id: "t\($0)", twoLine: $0 % 10 == 5) }
        let tree: El<S> = TabStrip<S>(key: "vt", orientation: .vertical)
            .gap(3)
            .lazyTabs(slots) { i in
                StripTabItem<S>(id: "t\(i)", title: "Tab \(i)").subtitle(i % 10 == 5 ? "project" : nil)
            }
            .build(S(), kit: k)
        var start: Float = 0
        var expected: [Int] = []
        for i in 0..<80 {
            let p: Float = (i % 10 == 5 ? 45 : 28) + 3
            if start < 1674 && start + p > -186 { expected.append(i) }
            start += p
        }
        expected.append(79)
        #expect(builtTabs(tree, strip: "vt") == expected)
        let firstUnbuilt = expected.last(where: { $0 != 79 })! + 1
        let spacer = try #require(findEl(tree, key: "vt-list-unbuilt-\(firstUnbuilt)"))
        var len: Float = 0
        for i in firstUnbuilt..<79 { len += (i % 10 == 5 ? 45 : 28) + 3 }
        #expect(spacer.isA11yHidden)
        #expect(spacer.layout.width == .fraction(1.0))
        #expect(spacer.layout.height == .points(len - 3))
        #expect(findEl(tree, key: "vt-tab-t5")?.layout.height == .points(45))
        #expect(findEl(tree, key: "vt-tab-t4")?.layout.height == .points(28))
    }

    @Test("The incoming tab's place inserts at its landing slot's child, and the tabs by the landing are built")
    func incomingPlaceAtLandingChild() throws {
        let k = Kit.neutral(dark: false)
        var drag = TabDragState()
        drag.setIncoming(index: 60)
        let slots = (0..<100).map { TabSlot(id: "t\($0)") }
        let tree: El<S> = TabStrip<S>(key: "in")
            .lazyTabs(slots) { i in StripTabItem<S>(id: "t\(i)", title: "Tab \(i)") }
            .dragState(\.drag, current: drag)
            .availableWidth(800)
            .build(S(), kit: k)
        let built = builtTabs(tree, strip: "in")
        #expect(built.contains(59) && built.contains(60))
        let list = try #require(findEl(tree, key: "in-list"))
        let childKeys = list.children.map { $0.keyId ?? "" }
        let place = try #require(childKeys.firstIndex(of: "in-list-incoming"))
        #expect(childKeys[place + 1] == "in-tab-t60")
        let placeEl = list.children[place]
        #expect(placeEl.isA11yHidden)
        // An unpinned tab's width: 28 (shrunk to the minimum).
        #expect(placeEl.layout.width == .points(28))

        // A landing past the last tab goes at the end.
        var end = TabDragState()
        end.setIncoming(index: 100)
        let endTree: El<S> = TabStrip<S>(key: "in")
            .lazyTabs(slots) { i in StripTabItem<S>(id: "t\(i)", title: "Tab \(i)") }
            .dragState(\.drag, current: end)
            .availableWidth(800)
            .build(S(), kit: k)
        #expect(findEl(endTree, key: "in-list")?.children.last?.keyId == "in-list-incoming")
    }

    @Test("With no availableWidth every horizontal tab is the overflow's max_width wide, and spacers use that pitch")
    func noViewportUsesMaxWidth() throws {
        let k = Kit.neutral(dark: false)
        let slots = (0..<60).map { TabSlot(id: "t\($0)") }
        let tree: El<S> = TabStrip<S>(key: "mw")
            .lazyTabs(slots) { i in StripTabItem<S>(id: "t\(i)", title: "Tab \(i)") }
            .active("t0")
            .build(S(), kit: k)
        // `viewport.map_or(max_width, ..)`: 224 for HORIZONTAL_DEFAULT, drawn at that width.
        #expect(findEl(tree, key: "mw-tab-t1")?.layout.width == .points(224))
        // Step max((224 + 2) * 4, 64) = 904, fallback 2000 shows ceil(2000 / 904) = 3: band
        // (-904, 4520). Pitches: 226 for t0 (active, no separator), 229 after.
        var start: Float = 0
        var expected: [Int] = []
        for i in 0..<60 {
            let p: Float = i == 0 || i == 59 ? 226 : 229
            if start < 4520 && start + p > -904 { expected.append(i) }
            start += p
        }
        expected.append(59)
        #expect(builtTabs(tree, strip: "mw") == expected)
        let from = expected[expected.count - 2] + 1
        let spacer = try #require(findEl(tree, key: "mw-list-unbuilt-\(from)"))
        #expect(spacer.layout.width == .points(Float(59 - from) * 229 - 2))

        // `.scroll` has no bound upstream (infinite); a horizontal strip takes HORIZONTAL_DEFAULT's 224.
        let scrollTree: El<S> = TabStrip<S>(key: "sc")
            .overflow(.scroll())
            .lazyTabs(Array(slots.prefix(3))) { i in StripTabItem<S>(id: "t\(i)", title: "Tab \(i)") }
            .build(S(), kit: k)
        #expect(findEl(scrollTree, key: "sc-tab-t1")?.layout.width == .points(224))
        // `.shrink` takes its own max_width; pinned tabs take ShrinkThenScroll's pinned_width.
        let shrinkTree: El<S> = TabStrip<S>(key: "sh")
            .overflow(.shrink(minWidth: 88, maxWidth: 200))
            .lazyTabs(Array(slots.prefix(3))) { i in StripTabItem<S>(id: "t\(i)", title: "Tab \(i)") }
            .build(S(), kit: k)
        #expect(findEl(shrinkTree, key: "sh-tab-t1")?.layout.width == .points(200))
        let pinTree: El<S> = TabStrip<S>(key: "pn")
            .overflow(.shrinkThenScroll(pinnedWidth: 40))
            .lazyTabs([TabSlot(id: "p", pinned: true), TabSlot(id: "u")]) { i in
                StripTabItem<S>(id: i == 0 ? "p" : "u", title: "T").pinned(i == 0)
            }
            .build(S(), kit: k)
        #expect(findEl(pinTree, key: "pn-tab-p")?.layout.width == .points(40))
    }

    @MainActor
    @Test("In a Runtime a strip with no availableWidth draws its tabs at max_width, so unbuilt runs keep the last tab in place")
    func runtimeNoViewportKeepsPlaces() throws {
        let k = Kit.neutral(dark: false)
        let rt = Runtime(state: S(), viewport: Vec2(812, 80), systemDark: false) { s, _ in
            col().sizeFull().child(
                TabStrip<S>(key: "nv")
                    .lazyTabs((0..<60).map { TabSlot(id: "t\($0)") }) { i in StripTabItem<S>(id: "t\(i)", title: "Tab \(i)") }
                    .active("t0")
                    .build(s, kit: k)
            )
        }
        rt.frame(at: 0.0)
        rt.frame(at: 1.0 / 60.0)
        let list = try #require(info(rt, "nv-list"))
        #expect(info(rt, "nv-tab-t30") == nil)
        let t1 = try #require(info(rt, "nv-tab-t1"))
        #expect(abs(t1.rect[2] - 224) < 0.5)
        // t0 226 (no separator by the active tab), then 229 a tab.
        let t59 = try #require(info(rt, "nv-tab-t59"))
        #expect(abs((t59.rect[0] - list.rect[0]) - (226 + 58 * 229)) < 0.5)
    }

    @Test("A tab given whole that is marked (its menu open) or renaming stays built wherever the strip has scrolled")
    func wholeTabsMarkedOrEditingAreKept() throws {
        let k = Kit.neutral(dark: false)
        let tabs = (0..<100).map { i in
            StripTabItem<S>(id: "t\(i)", title: "Tab \(i)")
                .marked(i == 80)
                .editor(i == 90 ? text("rename") : nil)
        }
        #expect(tabs[80].isMarked && !tabs[79].isMarked)
        let tree: El<S> = TabStrip<S>(key: "mk", tabs: tabs, selected: "t0").availableWidth(800).build(S(), kit: k)
        let built = builtTabs(tree, strip: "mk")
        #expect(built.contains(80))
        #expect(built.contains(90))
        #expect(!built.contains(79) && !built.contains(81) && !built.contains(89))
        // The marked tab keeps the hover wash, as upstream's `item.marked => c.hover`.
        #expect(findEl(tree, key: "mk-tab-t80")?.background == k.c.surfaceHover)
    }

    @MainActor
    @Test("In a Runtime unbuilt runs keep every tab in place, and scrolling the strip builds the band it shows")
    func runtimeScrollBuildsTheBand() throws {
        let k = Kit.neutral(dark: false)
        let rt = Runtime(state: S(), viewport: Vec2(812, 80), systemDark: false) { s, _ in
            let slots = (0..<100).map { TabSlot(id: "t\($0)", pinned: $0 == 0, keep: $0 == 70) }
            return col().sizeFull().child(
                TabStrip<S>(key: "rt")
                    .lazyTabs(slots) { i in StripTabItem<S>(id: "t\(i)", title: "Tab \(i)").pinned(i == 0) }
                    .active("t50")
                    .availableWidth(800)
                    .build(s, kit: k)
            )
        }
        rt.frame(at: 0.0)
        rt.frame(at: 1.0 / 60.0)
        let list = try #require(info(rt, "rt-list"))
        let scroller = try #require(info(rt, "rt-scroll"))
        #expect(abs(scroller.rect[2] - 800) < 0.5)
        // Tab 50 starts after the pinned tab (41) and 48 tabs of 33 and tab 49's 30; tab 99 after
        // 96 tabs of 33 and two of 30.
        let t50 = try #require(info(rt, "rt-tab-t50"))
        #expect(abs((t50.rect[0] - list.rect[0]) - (41 + 48 * 33 + 30)) < 0.5)
        let t99 = try #require(info(rt, "rt-tab-t99"))
        #expect(abs((t99.rect[0] - list.rect[0]) - (41 + 96 * 33 + 2 * 30)) < 0.5)
        #expect(info(rt, "rt-tab-t10") != nil)
        #expect(info(rt, "rt-tab-t40") == nil)

        // Scroll about 1200 points along (a wheel to the left scrolls an LTR strip forward).
        let mid = Vec2(scroller.rect[0] + 200, scroller.rect[1] + scroller.rect[3] / 2)
        rt.pointerMove(to: mid, at: 0.03)
        var t = 0.04
        rt.wheel(WheelEvent(dx: -1200, dy: 0), at: mid, now: t)
        for _ in 0..<60 { t += 1.0 / 60.0; rt.frame(at: t) }
        let offset = rt.scrollOffset(forKey: "rt-scroll").x
        #expect(offset > 1000)
        let listAfter = try #require(info(rt, "rt-list"))
        #expect(abs((scroller.rect[0] - listAfter.rect[0]) - offset) < 0.5)
        // The band is read in steps of 120: `at = floor(offset / 120)`, built over
        // ((at - 1) * 120, (at + 2 + 7) * 120).
        let at = Float((offset / 120).rounded(.down))
        let lo = (at - 1) * 120, hi = (at + 9) * 120
        func start(_ i: Int) -> Float {
            // Pinned 41, then 33 a tab, 30 for tab 49 (before the active one) and tab 50.
            var s: Float = 0
            for j in 0..<i { s += j == 0 ? 41 : (j == 49 || j == 50 || j == 99 ? 30 : 33) }
            return s
        }
        func pitch(_ i: Int) -> Float { start(i + 1) - start(i) }
        for i in 1..<99 where i != 50 && i != 70 {
            let near = start(i) < hi && start(i) + pitch(i) > lo
            #expect((info(rt, "rt-tab-t\(i)") != nil) == near, "tab \(i) built \(near) for band (\(lo), \(hi))")
        }
        #expect(info(rt, "rt-tab-t40") != nil)
        #expect(info(rt, "rt-tab-t10") == nil)
        #expect(info(rt, "rt-list-unbuilt-1") != nil)
        // Every tab kept its place.
        let t99After = try #require(info(rt, "rt-tab-t99"))
        #expect(abs((t99After.rect[0] - listAfter.rect[0]) - start(99)) < 0.5)
        let t40 = try #require(info(rt, "rt-tab-t40"))
        #expect(abs((t40.rect[0] - listAfter.rect[0]) - start(40)) < 0.5)
    }
}
