import Testing
@testable import Rune

@Suite("reveal_insert.rs:48 and pose_hit.rs:239 parity")
struct RevealInsertAndPoseHitParityTests {
    private struct RevealState {
        var items: [UInt32]
    }

    private struct RowDeps: Equatable {
        let id: UInt32
        let isFirst: Bool
    }

    private func itemKey(_ id: UInt32) -> String { "item\(id)" }

    private func revealView(_ s: RevealState, _ cx: inout Cx<RevealState>) -> El<RevealState> {
        let rows: El<RevealState> = col()
            .key("rows")
            .wFull()
            .px(8.0)
            .py(6.0)
            .growth(.default)
            .virtualRows(
                count: s.items.count,
                estimatedRowHeight: 44.0,
                key: { state, i in "item\(state.items[i])" },
                build: { state, i in
                    let id = state.items[i]
                    return memo("item\(id)", RowDeps(id: id, isFirst: i == 0)) {
                        var row: El<RevealState> = col().wFull()
                        if i == 0 {
                            row = row.child(el().key("section").wFull().h(30.0))
                        }
                        return row.child(
                            el().key("item\(id)").wFull().h(44.0).child(text("Row \(id)"))
                        )
                    }
                }
            )
        return col().wFull().hFull().child(
            col().key("list").wFull().h(300.0).scroll(ScrollSpec(stickBottom: false)).scrollMargin(6.0).child(rows)
        )
    }

    private func shownHeight(_ rt: Runtime<RevealState>, key: String) -> Float {
        rt.element(byKey: key)?.visible[3] ?? 0.0
    }

    private func scrolledAwayAndBack() -> Runtime<RevealState> {
        let rt = Runtime<RevealState>(
            state: RevealState(items: Array(UInt32(0)..<UInt32(1000))),
            viewport: Vec2(400.0, 300.0),
            pixelScale: 1.0,
            systemDark: true,
            view: revealView
        )
        var t = 0.0
        for _ in 0..<10 {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        rt.settleAll()
        for row in [UInt32(40), UInt32(0)] {
            rt.update(at: t) { _, tx in tx.scrollIntoView(itemKey(row)) }
            for _ in 0..<3 {
                t += 1.0 / 120.0
                _ = rt.frame(at: t)
            }
        }
        return rt
    }

    @Test("rows_inserted_above_the_top_and_revealed_in_the_same_commit_land_in_view")
    func rowsInsertedAboveTheTopAndRevealedInTheSameCommitLandInView() {
        for inserted in [UInt32(1), UInt32(2)] {
            let rt = scrolledAwayAndBack()
            var t = rt.currentTime
            rt.update(at: t) { s, tx in
                for n in 0..<inserted {
                    s.items.insert(1001 + n, at: 0)
                }
                tx.scrollIntoView(itemKey(s.items[0]))
            }
            let first = itemKey(1000 + inserted)
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            let h = shownHeight(rt, key: first)
            #expect(h > 43.5, "\(inserted) inserted: the first frame shows the new first row whole, not \(h)")
            for _ in 0..<3 {
                t += 1.0 / 120.0
                _ = rt.frame(at: t)
            }
            #expect(shownHeight(rt, key: first) > 43.5, "\(inserted) inserted: and keeps showing it")
            rt.settleAll()
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            #expect(shownHeight(rt, key: first) > 43.5, "\(inserted) inserted: settled")
            guard let section = rt.elements().first(where: { $0.key == "section" && !$0.exiting }) else {
                Issue.record("Missing non-exiting section element for inserted=\(inserted)")
                return
            }
            #expect(section.visible[3] > 29.5 && section.rect[1] >= -0.05, "\(inserted) inserted: at the top: \(section)")
        }
    }

    @Test("sticky_and_anchored_elements_pick_in_paint_order_after_scrolling")
    func stickyAndAnchoredElementsPickInPaintOrderAfterScrolling() {
        struct Hits {
            var list: [String] = []
        }
        let rt = Runtime<Hits>(
            state: Hits(),
            viewport: Vec2(200.0, 200.0),
            pixelScale: 1.0,
            systemDark: true
        ) { _, _ in
            col().wFull().hFull().child(
                col().key("scroll").size(100.0, 100.0).scroll(ScrollSpec(stickBottom: false))
                    .child(
                        col().wFull().h(300.0)
                            .child(el().key("header").wFull().h(30.0).stickyTop(0.0).onClick { s in s.list.append("header") })
                            .child(el().key("row").wFull().h(270.0).onClick { s in s.list.append("row") })
                            .child(el().key("popup").size(60.0, 20.0).anchored("header", side: .bottom, align: .start, gap: 0.0).onClick { s in s.list.append("popup") })
                    )
            )
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.0) { _, tx in tx.scrollToY("scroll", 20.0) }
        _ = rt.frame(at: 0.0)
        for (y, expected): (Float, String) in [(15.0, "header"), (35.0, "popup"), (65.0, "row")] {
            #expect(rt.elementAt(20.0, y)?.key == expected)
            rt.update(at: 0.0) { s, _ in s.list.removeAll() }
            rt.pointerDown(at: Vec2(20.0, y), at: 0.0)
            rt.pointerUp(at: Vec2(20.0, y), at: 0.0)
            _ = rt.frame(at: 0.0)
            #expect(rt.state.list == [expected])
        }
    }
}
