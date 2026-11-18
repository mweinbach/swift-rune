import Testing
@testable import Rune
import RuneMotion

@Suite("Rune Unseen Presence Parity Tests (motion/unseen_presence.rs)")
struct UnseenPresenceParityTests {
    private struct ListState {
        var rows: [String]
    }

    private func makeListRuntime(rows: [String], tracksFilterKeys: Bool = false) -> Runtime<ListState> {
        Runtime<ListState>(
            state: ListState(rows: rows),
            viewport: Vec2(240, 200),
            pixelScale: 1.0,
            systemDark: true
        ) { st, _ in
            let list: El<ListState> = col()
                .key("list")
                .w(200)
                .h(60)
                .clip(true)
                .scrollY()
                .children(st.rows.map { id in
                    row()
                        .key(id)
                        .wFull()
                        .h(30)
                        .shrink(0)
                        .bg(Tok.accent(0, dark: true))
                        .transition(Transition.opacity)
                })
            return col().p(10).child(tracksFilterKeys ? list.kitFilterKeys(st.rows) : list)
        }
    }

    @Test("Visibility keeps repeated paint coverage and drops nodes skipped by the next draw")
    func retainedPaintVisibility() {
        var frame = KitUnseenPresenceState.PaintedFrame()
        let hidden = KitUnseenPresenceState.PaintedNode(parent: nil, visible: false, inView: false,
            geometricallyInView: false, inheritedOpacity: 0, drawn: .zero, stickyShift: .zero)
        var shown = hidden
        shown.parent = NodeId(4)
        shown.visible = true
        shown.inView = true
        shown.geometricallyInView = true
        shown.inheritedOpacity = 1

        frame.begin()
        for i in 0..<8 { frame.record(NodeId(UInt64(i)), sample: hidden) }
        frame.record(NodeId(6), sample: shown)
        frame.record(NodeId(6), sample: hidden)
        #expect(frame[NodeId(6)]?.visible == false)
        #expect(frame[NodeId(6)]?.inView == true)
        #expect(frame[NodeId(6)]?.geometricallyInView == true)

        frame.begin()
        frame.record(NodeId(6), sample: shown)
        #expect(frame[NodeId(4)] == nil)
        #expect(frame.visibleAncestors() == [NodeId(4)])
        frame.updateOpacity(NodeId(6), opacity: 0)
        #expect(frame[NodeId(6)]?.inView == false)
        #expect(frame[NodeId(6)]?.geometricallyInView == true)

        frame.begin()
        frame.record(NodeId(4), sample: hidden)
        #expect(frame[NodeId(6)] == nil)
        #expect(frame.visibleAncestors().isEmpty)
    }

    @Test func hoverVisibilityUsesTheLastPaintIncludingOverflowingChildren() throws {
        let runtime = Runtime<Void>(state: (), viewport: Vec2(100, 100)) { _, _ in
            col().key("root").children([
                col().key("overflow").child(el().key("child").size(10, 10)),
                col().key("faded").child(el().key("nested").size(10, 10)),
                el().key("offscreen").size(10, 10),
            ])
        }
        _ = runtime.renderFrame(at: 0)
        let nodes = runtime.flatNodes
        var visibility = KitUnseenPresenceState()
        var cached: [Bool]?
        #expect(!visibility.drewNothing(at: 0, nodes: nodes, cached: &cached))
        visibility.beginFrame()
        for node in nodes {
            let pose = try #require(runtime.scene.presented(node.nodeId))
            let visible = node.key == "child" || node.key == "nested"
            visibility.recordFrameNode(pose, visible: visible, inView: visible, geometricallyInView: visible,
                inhOpacity: node.key == "faded" ? 0 : 1, drawn: pose.rect, ownStickyShift: .zero)
        }
        let expected = visibility.drewNothing(nodes: nodes)
        for key in ["child", "offscreen", "faded", "overflow", "root"] {
            let index = try #require(nodes.firstIndex { $0.key == key })
            let hidden = visibility.drewNothing(at: index, nodes: nodes, cached: &cached)
            #expect(hidden == expected[index])
            #expect(hidden == (key == "offscreen" || key == "faded"))
        }
    }

    @Test("Offscreen clipped rows skip enter fade while visible rows fade in (entersUnseen / landUnseenEntrances)")
    func entersUnseenLandsOffscreenRowAndCrossfadesVisibleRow() throws {
        let rt = makeListRuntime(rows: [])
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.01) { st, _ in
            st.rows = ["r0", "r1", "r2", "r3"]
        }
        _ = rt.frame(at: 0.01 + 1.0 / 120.0)

        let visibleRow = try #require(rt.elements().first { $0.key == "r0" })
        let offscreenRow = try #require(rt.elements().first { $0.key == "r3" })
        #expect(visibleRow.opacity < 0.2)
        #expect(offscreenRow.opacity == 1.0)
    }

    @Test("Unseen row re-fades on list replacement but stays opaque when scrolled into view", arguments: [false, true], [false, true])
    func reenterUnseenRowFadesOnFilterReplacementNotOnScroll(native: Bool, tracksFilterKeys: Bool) throws {
        let rt = makeListRuntime(rows: (0..<8).map { "r\($0)" }, tracksFilterKeys: tracksFilterKeys)

        func draw(at time: Double) {
            if native {
                _ = rt.renderFrame(at: time)
            } else {
                _ = rt.frame(at: time)
            }
        }

        var t = 0.0
        for _ in 0..<45 {
            t += 1.0 / 60.0
            draw(at: t)
        }

        // 1. Scroll down so previously clipped `r4` enters view: must stay opaque (no reenter fade).
        rt.update(at: t) { _, tx in
            tx.scrollTo("list", offset: Vec2(0, 120), animated: false)
        }
        t += 1.0 / 120.0
        draw(at: t)
        let scrolledIn = try #require(rt.elements().first { $0.key == "r4" })
        #expect(scrolledIn.opacity == 1.0)

        // Reset back to top and settle.
        rt.update(at: t) { _, tx in
            tx.scrollTo("list", offset: .zero, animated: false)
        }
        for _ in 0..<20 {
            t += 1.0 / 60.0
            draw(at: t)
        }
        let unseenR7 = try #require(rt.elements().first { $0.key == "r7" })
        #expect(unseenR7.opacity == 1.0)

        // 2. Replace list so previously clipped `r7` moves to the visible top: must re-enter fade (`< 0.2`).
        rt.update(at: t) { st, _ in
            st.rows = ["r7"]
        }
        t += 1.0 / 120.0
        draw(at: t)
        let movedUp = try #require(rt.elements().first { $0.key == "r7" })
        #expect(movedUp.opacity < 0.2)

        for _ in 0..<45 {
            t += 1.0 / 60.0
            draw(at: t)
        }
        let settled = try #require(rt.elements().first { $0.key == "r7" })
        #expect(settled.opacity > 0.99)
    }

    @Test("A viewport keeps its scroll coordinates when preceding siblings move its flat index", arguments: [false, true])
    func reorderedViewportRetainsScrollSpace(native: Bool) throws {
        struct State { var replaceFirst = false }
        let rt = Runtime<State>(state: State(), viewport: Vec2(240, 200), pixelScale: 1, systemDark: true) { state, _ in
            let rows: [El<State>] = (0..<8).map { index in
                row().key(index == 0 && state.replaceFirst ? "new" : "r\(index)")
                    .wFull().h(30).shrink(0).bg(Tok.accent(0, dark: true)).transition(.opacity)
            }
            let list: El<State> = col().key("list").w(200).h(60).clip(true).scrollY().children(rows)
            if state.replaceFirst { return col().child(row().key("spacer").h(0)).child(list) }
            return col().child(list)
        }
        func draw(_ t: Double) {
            if native { _ = rt.renderFrame(at: t) } else { _ = rt.frame(at: t) }
        }
        for f in 0...45 { draw(Double(f) / 60) }
        rt.update(at: 0.75) { state, tx in
            state.replaceFirst = true
            tx.scrollTo("list", offset: Vec2(0, 120), animated: false)
        }
        draw(0.75 + 1.0 / 120)
        let visible = try #require(rt.elements().first { $0.key == "r4" })
        #expect(rt.scrollOffset(forKey: "list").y == 120)
        #expect(visible.opacity == 1)
    }

    @Test("Omitted unseen clipped rows unmount immediately without exit ghost (endUnseenExits)")
    func endUnseenExitsUnmountsClippedOmittedRowsImmediately() throws {
        let rt = makeListRuntime(rows: ["r0", "r1", "r2", "r3", "r4"])

        var t = 0.0
        for _ in 0..<45 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }

        rt.update(at: t) { st, _ in
            st.rows = ["r0"]
        }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)

        let els = rt.elements()
        let exitingVisible = els.first { $0.key == "r1" }
        let omittedUnseen = els.first { $0.key == "r4" }
        #expect(exitingVisible?.exiting == true)
        #expect(omittedUnseen == nil)
    }

    @Test("Clearing a list keeps visible exits and retires clipped rows", arguments: [false, true])
    func clearingListWithoutAnyRemainingTransitions(native: Bool) {
        let rt = makeListRuntime(rows: ["visible", "also-visible", "clipped", "farther"])
        func draw(_ time: Double) {
            if native { _ = rt.renderFrame(at: time) } else { _ = rt.frame(at: time) }
        }
        for frame in 0...45 { draw(Double(frame) / 60) }
        rt.update(at: 0.75) { state, _ in state.rows.removeAll() }
        draw(0.75 + 1.0 / 120)
        let mounted = rt.elements()
        #expect(mounted.first { $0.key == "visible" }?.exiting == true)
        #expect(!mounted.contains { $0.key == "farther" })
    }
}
