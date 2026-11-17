import Testing
import Foundation
import RuneRef
@testable import Rune

/// Port of `crates/rune/tests/selection_group.rs:373`
/// `a_selection_in_a_virtual_row_scrolled_out_drops_without_panicking`: despite its name, the
/// selection a virtual row holds is kept (pinned) while the row scrolls out under a held press,
/// through Cmd+C and Cmd+A, and when it mounts again.
@Suite("selection_group.rs virtual row parity", .serialized)
struct SelectionGroupVirtualRowParityTests {
    private final class Clock {
        let rt: Runtime<Int>
        var t = 0.0
        init(_ rt: Runtime<Int>) { self.rt = rt }

        /// `support::tick`.
        func tick() {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }

        /// `support::wait`.
        func wait() {
            t += 1.0
            _ = rt.frame(at: t)
        }

        /// `support::drag`.
        func drag(_ p0: Vec2, _ p1: Vec2) {
            rt.pointerMove(to: p0, at: t)
            rt.pointerDown(at: p0, at: t)
            tick()
            for k in 1...6 {
                let f = Float(k) / 6.0
                rt.pointerMove(to: Vec2(p0.x + (p1.x - p0.x) * f, p0.y + (p1.y - p0.y) * f), at: t)
                tick()
            }
            rt.pointerUp(at: p1, at: t)
            tick()
        }

        /// `support::command`, and whether the runtime took the key.
        @discardableResult
        func command(_ c: Character) -> Bool {
            let took = rt.keyDown(KeyEvent(key: .command(c), mods: RuneTestKey.primaryMods()), at: t)
            tick()
            return took
        }

        /// `support::glyphs_at`: centres (points) of the glyphs drawn inside element `path`, by x.
        func glyphs(at path: String) -> [Vec2] {
            guard let e = rt.elements().first(where: { $0.path == path }) else { return [] }
            let scale = rt.pixelScale
            return rt.renderFrame(at: t).instances
                .filter { $0.params.y == KIND_GLYPH }
                .map { Vec2(($0.rect.x + $0.rect.z / 2.0) / scale, ($0.rect.y + $0.rect.w / 2.0) / scale) }
                .filter { $0.x >= e.rect[0] && $0.x <= e.rect[0] + e.rect[2] && $0.y >= e.rect[1] && $0.y <= e.rect[1] + e.rect[3] }
                .sorted { $0.x < $1.x }
        }
    }

    private static func rowsView(_: Int, _: inout Cx<Int>) -> El<Int> {
        let style = TextStyle(size: 14.0, weight: 400.0).lh(20.0)
        return col().wFull().hFull().child(
            col().key("scroll").wFull().grow(1.0).scroll(stickBottom: false).child(
                col().key("rows").wFull().growth(.default).virtualRows(
                    400,
                    60.0,
                    key: { _, i in "r\(i)" },
                    build: { _, i in
                        col().wFull().h(60.0).p(6.0).selectionGroup(true)
                            .child(text("row \(i) title").key("a").font(style).wFull().selectable(true))
                            .child(text("row \(i) body").key("b").font(style).wFull().selectable(true))
                    }
                )
            )
        )
    }

    @Test("a_selection_in_a_virtual_row_scrolled_out_drops_without_panicking")
    func aSelectionInAVirtualRowScrolledOutDropsWithoutPanicking() throws {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(400.0, 400.0), pixelScale: 2.0, systemDark: true, view: Self.rowsView)
        let c = Clock(rt)
        _ = rt.frame(at: 0.0)
        let pathA = try #require(rt.elements().first(where: { $0.path.hasSuffix("/@rows/@r0/@a") })?.path)
        let pathB = try #require(rt.elements().first(where: { $0.path.hasSuffix("/@rows/@r0/@b") })?.path)
        let a = c.glyphs(at: pathA)
        let b = c.glyphs(at: pathB)
        try #require(!a.isEmpty && !b.isEmpty, "row 0 draws its glyphs")
        c.drag(Vec2(a[0].x - 1.5, a[0].y), Vec2(b[b.count - 1].x + 3.0, b[0].y))
        #expect(rt.selectedText() == "row 0 title\nrow 0 body")
        // Mid-drag, the row scrolls out under the held press.
        c.wait()
        rt.pointerMove(to: Vec2(a[0].x - 1.5, a[0].y), at: c.t)
        rt.pointerDown(at: Vec2(a[0].x - 1.5, a[0].y), at: c.t)
        c.tick()
        for _ in 0..<40 {
            rt.wheel(WheelEvent(dx: 0, dy: -400.0), at: Vec2(200.0, 200.0), now: c.t)
            rt.pointerMove(to: Vec2(200.0, 300.0), at: c.t)
            c.tick()
        }
        rt.pointerUp(at: Vec2(200.0, 300.0), at: c.t)
        c.tick()
        #expect(!rt.elements().contains(where: { $0.path == pathA }), "row 0 scrolled out")
        #expect(rt.selectedText() == "row 0 title\nrow 0 body")
        // Both keys act on the selection while its row isn't mounted: Cmd+C copies it, and
        // Cmd+A selects all of its group, the row's two texts (`select_all.rs::select_all_key`).
        #expect(c.command("c"))
        #expect(rt.clipboard.text == "row 0 title\nrow 0 body")
        #expect(c.command("a"))
        #expect(rt.textSelection()?.path == pathA && rt.textSelection()?.range == 0..<"row 0 title".utf8.count)
        #expect(rt.selectionState.coordinator.phase.selection?.far?.path == pathB)
        #expect(rt.selectedText() == "row 0 title\nrow 0 body")
        // Back up: the pinned row's selection is preserved when it mounts again.
        for _ in 0..<40 {
            rt.wheel(WheelEvent(dx: 0, dy: 400.0), at: Vec2(200.0, 200.0), now: c.t)
            c.tick()
        }
        c.wait()
        #expect(rt.elements().contains(where: { $0.path == pathA }))
        #expect(rt.selectedText() == "row 0 title\nrow 0 body")
    }
}
