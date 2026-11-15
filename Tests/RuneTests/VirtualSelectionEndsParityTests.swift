import Testing
import Foundation
import RuneRef
@testable import Rune

/// Ends of a selection across virtual rows, as `crates/rune/src/runtime/virtual/selection.rs`
/// resolves them: a Shift-press extends a selection whose anchor row scrolled out
/// (`selection_down` picks the holder by its row identity), an empty selectable text of a row
/// never built is an end like any other (`walk_row_el` collects it), and a rebound text carries
/// what its watchers heard (`prune_text_selection`).
@Suite("virtual selection ends parity", .serialized)
struct VirtualSelectionEndsParityTests {
    typealias W = SelectionPhaseVirtualWalk

    @Test("a_shift_press_extends_a_selection_whose_anchor_row_scrolled_out")
    func aShiftPressExtendsASelectionWhoseAnchorRowScrolledOut() throws {
        let walk = W.Walk()
        #expect(walk.play(.press(.hiStart)) == nil)
        #expect(walk.play(.up) == nil)
        walk.scroll(top: false)
        let mounted = walk.rt.virtualLists[walk.list]?.lastMountedRange ?? 0..<0
        #expect(!mounted.contains(0), "row 0 isn't mounted: \(mounted)")
        walk.rt.pointerDown(at: W.point(.loEnd), mods: Mods(shift: true), at: walk.clock)
        let sel = try #require(walk.rt.selectionState.coordinator.phase.selection)
        // `phase::step` `Event::Extend`: the anchor stays in row 0, the origin collapses onto it,
        // the focus lands at the end of row 39, and the press drags by character.
        #expect(sel.path == walk.path(0))
        #expect(sel.content == W.content(0))
        #expect(sel.anchor == 0 && sel.focus == W.len)
        #expect(sel.originStart == 0 && sel.originEnd == 0)
        #expect(sel.far?.path == walk.path(W.rows - 1))
        if case .dragging(_, let unit) = walk.rt.selectionState.coordinator.phase {
            #expect(unit == .character)
        } else {
            Issue.record("the Shift-press drags")
        }
        #expect(sel.anchorEnd == VirtualEnd(listPath: walk.list, rowKey: "r0", rowIndex: 0, relPath: "", offset: 0))
        let got = walk.rt.textSelection()
        #expect(got?.path == walk.path(0) && got?.range == 0..<W.len)
    }

    private static func emptyFirstView(_: Int, _: inout Cx<Int>) -> El<Int> {
        col().key("root").w(300.0).h(120.0).child(
            col().key("scroll").wFull().h(120.0).scroll(stickBottom: false).child(
                col().key("list").wFull().growth(.default).selectionGroup(true).virtualRows(
                    40,
                    40.0,
                    key: { _, i in "r\(i)" },
                    build: { _, i in
                        col().wFull().h(40.0)
                            .child(text("").key("e").font(TextStyle(size: 14.0, weight: 400.0)).wFull().h(20.0).selectable(true))
                            .child(text("row \(i)").key("t").font(TextStyle(size: 14.0, weight: 400.0)).wFull().h(20.0).selectable(true))
                    }
                )
            )
        )
    }

    @Test("select_all_starts_at_an_empty_text_of_a_row_never_built")
    func selectAllStartsAtAnEmptyTextOfARowNeverBuilt() throws {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(300.0, 120.0), pixelScale: 1.0, systemDark: true, view: Self.emptyFirstView)
        var t = 0.0
        _ = rt.frame(at: t)
        let list = try #require(rt.virtualLists.keys.first(where: { $0.hasSuffix("@list") }))
        func settle() {
            for _ in 0..<60 {
                t += 1.0 / 60.0
                _ = rt.frame(at: t)
                if !rt.isAnimating && !rt.needsCommit { break }
            }
        }
        settle()
        rt.wheel(WheelEvent(dx: 0, dy: -10_000.0), at: Vec2(150.0, 60.0), now: t)
        settle()
        let mounted: Range<Int> = rt.virtualLists[list].map { $0.lastMountedRange } ?? (0..<0)
        #expect(!mounted.contains(0), "row 0 isn't mounted: \(mounted)")
        #expect(rt.keyDown(KeyEvent(key: .command("a"), mods: Mods(cmd: true)), at: t))
        let sel = try #require(rt.selectionState.coordinator.phase.selection)
        // `virtual_span_under`: the first text of the group is row 0's empty one, built on demand.
        #expect(sel.path == "\(list)/@r0/@e")
        #expect(sel.content == "")
        #expect(sel.anchorEnd == VirtualEnd(listPath: list, rowKey: "r0", rowIndex: 0, relPath: "@e", offset: 0))
        #expect(sel.far?.path == "\(list)/@r39/@t")
        #expect(sel.far?.end == VirtualEnd(listPath: list, rowKey: "r39", rowIndex: 39, relPath: "@t", offset: "row 39".utf8.count))
        let got = rt.textSelection()
        #expect(got?.path == "\(list)/@r0/@e" && got?.range == 0..<0)
    }

    private struct Shifted {
        var before = false
        var changes = 0
    }

    @Test("a_rebound_text_keeps_what_its_watchers_heard")
    func aReboundTextKeepsWhatItsWatchersHeard() throws {
        let rt = Runtime<Shifted>(state: Shifted(), viewport: Vec2(300.0, 200.0), pixelScale: 1.0, systemDark: true) { s, _ in
            var inner: El<Shifted> = col().wFull()
            inner = inner.child(text("hello world").key("t").font(TextStyle(size: 14.0, weight: 400.0)).selectable(true))
            var w: El<Shifted> = col().key("w").wFull()
            if s.before { w = w.child(el().h(10.0)) }
            w = w.child(inner.onSelectionChange { st, _, _ in st.changes += 1 })
            return col().wFull().hFull().child(w)
        }
        var t = 0.0
        _ = rt.frame(at: t)
        rt.update(at: t) { _, tx in tx.selectText("t", range: 0..<5) }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(rt.selectedText() == "hello")
        let heard = rt.state.changes
        #expect(heard == 1)
        let before = try #require(rt.selectionState.coordinator.phase.selection?.path)

        // An unkeyed sibling moves the text's unkeyed parent: the selection follows the text's
        // keyed identity, and its watcher, now at another path, hears no change.
        rt.update(at: t) { s, _ in s.before = true }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        let after = try #require(rt.selectionState.coordinator.phase.selection?.path)
        #expect(after != before, "the text moved: \(before) -> \(after)")
        #expect(SelectionMath.sameKeyedPath(before, after))
        #expect(rt.selectedText() == "hello")
        #expect(rt.state.changes == heard, "a rebind is not a selection change")
    }
}
