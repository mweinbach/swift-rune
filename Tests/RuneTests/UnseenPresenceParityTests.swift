import Testing
@testable import Rune
import RuneMotion

@Suite("Rune Unseen Presence Parity Tests (motion/unseen_presence.rs)")
struct UnseenPresenceParityTests {
    private struct ListState {
        var rows: [String]
    }

    private func makeListRuntime(rows: [String]) -> Runtime<ListState> {
        Runtime<ListState>(
            state: ListState(rows: rows),
            viewport: Vec2(240, 200),
            pixelScale: 1.0,
            systemDark: true
        ) { st, _ in
            col()
                .p(10)
                .child(
                    col()
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
                )
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

    @Test("Unseen row re-fades on list replacement (reenterUnseenRow) but stays opaque when scrolled into view")
    func reenterUnseenRowFadesOnFilterReplacementNotOnScroll() throws {
        let rt = makeListRuntime(rows: (0..<8).map { "r\($0)" })

        var t = 0.0
        for _ in 0..<45 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }

        // 1. Scroll down so previously clipped `r4` enters view: must stay opaque (no reenter fade).
        rt.update(at: t) { _, tx in
            tx.scrollTo("list", offset: Vec2(0, 120), animated: false)
        }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        let scrolledIn = try #require(rt.elements().first { $0.key == "r4" })
        #expect(scrolledIn.opacity == 1.0)

        // Reset back to top and settle.
        rt.update(at: t) { _, tx in
            tx.scrollTo("list", offset: .zero, animated: false)
        }
        for _ in 0..<20 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        let unseenR7 = try #require(rt.elements().first { $0.key == "r7" })
        #expect(unseenR7.opacity == 1.0)

        // 2. Replace list so previously clipped `r7` moves to the visible top: must re-enter fade (`< 0.2`).
        rt.update(at: t) { st, _ in
            st.rows = ["r7"]
        }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        let movedUp = try #require(rt.elements().first { $0.key == "r7" })
        #expect(movedUp.opacity < 0.2)

        for _ in 0..<45 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        let settled = try #require(rt.elements().first { $0.key == "r7" })
        #expect(settled.opacity > 0.99)
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

    @Test("runtime/tests/unseen_entrances::colours_out_of_sight_land_at_once")
    func coloursOutOfSightLandAtOnce() throws {
        let rt = Runtime<UInt32>(
            state: 0,
            viewport: Vec2(300, 300),
            pixelScale: 2.0,
            systemDark: true
        ) { n, _ in
            let fill: Color = (n % 2 == 1) ? .white : .transparent
            let rows: [El<UInt32>] = (0..<40).map { i -> El<UInt32> in
                col().key("r\(i)").wFull().h(40).bg(fill)
            }
            return col().wFull().hFull().child(
                col().key("scroll").wFull().h(100).scrollY(stickBottom: false).child(col().children(rows))
            )
        }
        var t = 0.0
        _ = rt.frame(at: t)
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        rt.update(at: t) { n, _ in n = 1 }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        func isFading(_ key: String) throws -> Bool {
            let id = NodeId.hash(try #require(rt.elements().first { $0.key == key }).path)
            return rt.scene.store.isAnimating(id, Props.FILL)
        }
        #expect(try isFading("r0"), "a row in sight fades its fill")
        #expect(try !isFading("r30"), "a row out of sight lands it")
    }

    @Test("runtime/tests/unseen_entrances::what_mounts_out_of_sight_enters_at_once")
    func whatMountsOutOfSightEntersAtOnce() {
        let rt = Runtime<UInt32>(
            state: 0,
            viewport: Vec2(300, 300),
            pixelScale: 2.0,
            systemDark: true
        ) { n, _ in
            let rows: [El<UInt32>] = (0..<40).map { i -> El<UInt32> in
                let digit: El<UInt32> = el().key("d\(i)-\(n)").size(10, 10).bg(.white).transition(.opacity)
                return col().key("r\(i)").wFull().h(40).child(digit)
            }
            return col().wFull().hFull().child(
                col().key("scroll").wFull().h(100).scrollY(stickBottom: false).child(col().children(rows))
            )
        }
        var t = 0.0
        _ = rt.frame(at: t)
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        rt.update(at: t) { n, _ in n = 1 }
        t += 1.0 / 120.0
        _ = rt.frame(at: t)
        func opacity(_ key: String) -> Float? {
            rt.elements().first { $0.key == key }?.opacity
        }
        #expect(opacity("d0-1").map { $0 < 1.0 } ?? false, "a digit in sight fades in")
        #expect(opacity("d30-1") == 1.0, "a digit out of sight lands at once")
        #expect(opacity("d30-0") == nil, "and the one it replaced goes at once")
    }
}
