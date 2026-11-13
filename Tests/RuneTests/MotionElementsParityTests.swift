import Foundation
import Testing
@testable import Rune

/// Direct port of `crates/rune/tests/motion_elements.rs`.
@Suite("Rune MotionElements Parity Tests (tests/motion_elements.rs)")
struct MotionElementsParityTests {
    private struct S {
        var words: Bool = false
    }

    private static func makeRuntime() -> Runtime<S> {
        Runtime<S>(
            state: S(),
            viewport: Vec2(600, 900),
            pixelScale: 2.0,
            systemDark: true
        ) { s, _ in
            let rowEls: [El<S>] = (0..<30).map { i in
                el().key("row\(i)").wFull().h(40).child(text("row \(i)"))
            }
            let rows = col().wFull().children(rowEls)
            return col().wFull().hFull()
                .child(col().key("scroll").w(300).h(400).scrollY(stickBottom: false).child(rows))
                .child(
                    s.words
                        ? text("a much longer line of words").key("words")
                        : el().key("words").w(10).h(10).bg(.black)
                )
        }
    }

    private static func agree(_ rt: Runtime<S>, _ out: inout [MotionElement]) {
        rt.motionElements(&out)
        let els = rt.elements()
        #expect(out.count == els.count)
        for (m, e) in zip(out, els) {
            let ep = rt.elementPath(m.id)
            #expect(ep?.path == e.path)
            #expect(ep?.key == e.key)
            #expect(m.rect == e.rect, "\(e.path)")
            #expect(m.visible == e.visible, "\(e.path)")
            #expect(m.opacity == e.opacity, "\(e.path)")
            #expect(m.scale == e.scale, "\(e.path)")
            #expect(m.parent.map { els[Int($0)].path } == e.parentIndex.map { els[$0].path }, "\(e.path)")
            let flagPairs: [(UInt16, Bool)] = [
                (MotionElement.EXITING, e.exiting),
                (MotionElement.SCROLLING, e.scrolling),
                (MotionElement.GROWING, e.inGrowingRow || e.revealing),
                (MotionElement.LIVE, e.liveIntent != 0),
                (MotionElement.VIRTUAL, e.virtualExtent),
                (MotionElement.TEXT, e.role == .text),
                (MotionElement.LOOP, e.loopPhase != nil),
                (MotionElement.PAINTS, e.fill.a > 0.01 || (e.text.map { !$0.isEmpty } ?? false)),
            ]
            for (flag, want) in flagPairs {
                #expect(m.is(flag) == want, "\(e.path) flag \(flag)")
            }
            #expect((m.textHash != 0) == (e.text.map { !$0.isEmpty } ?? false), "\(e.path)")
        }
    }

    @Test("motion_elements::motion_elements_match_elements_through_a_scroll")
    func motionElementsMatchElementsThroughAScroll() throws {
        let rt = Self.makeRuntime()
        var out: [MotionElement] = []
        var t = 0.0
        _ = rt.frame(at: t)
        Self.agree(rt, &out)
        rt.wheel(WheelEvent(dx: 0, dy: -120), at: Vec2(100, 200), now: t)
        var scrolled = false
        for _ in 0..<30 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
            Self.agree(rt, &out)
            scrolled = scrolled || out.contains { $0.is(MotionElement.SCROLLING) }
        }
        #expect(scrolled)
        let before = try #require(out.first { rt.elementPath($0.id)?.key == "words" })
        rt.update(at: t) { s, _ in s.words = true }
        for _ in 0..<30 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
            Self.agree(rt, &out)
        }
        let after = try #require(out.first { rt.elementPath($0.id)?.key == "words" })
        #expect(before.textHash != after.textHash)
        #expect(out.filter { $0.is(MotionElement.TEXT) }.allSatisfy { $0.textHash != 0 })
    }

    @Test("motion_elements::a_glide_marks_the_content_it_carries_scrolling")
    func aGlideMarksTheContentItCarriesScrolling() throws {
        let rt = Self.makeRuntime()
        var out: [MotionElement] = []
        var t = 0.0
        _ = rt.frame(at: t)
        rt.update(at: t) { _, tx in tx.scrollTo("scroll", x: 0, y: 400) }
        func yPos() throws -> Float {
            try #require(rt.elements().first { $0.key == "row3" }).rect[1]
        }
        var moved = 0
        var last = try yPos()
        for f in 0..<120 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
            Self.agree(rt, &out)
            let nowY = try yPos()
            if abs(nowY - last) > 0.01 {
                moved += 1
                let row3 = try #require(rt.elements().first { $0.key == "row3" })
                #expect(row3.scrolling || abs(nowY - last) < 0.5, "frame \(f): moving row not marked scrolling")
            }
            last = nowY
        }
        #expect(moved > 5)
        #expect(rt.elements().allSatisfy { !$0.scrolling })
    }

    @Test("motion_elements::secure_text_hashes_to_zero")
    func secureTextHashesToZero() throws {
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(300, 200),
            pixelScale: 2.0,
            systemDark: true
        ) { _, _ in
            col()
                .child(text("hunter2").key("plain"))
                .child(text("hunter2").key("secret").secure())
        }
        _ = rt.frame(at: 0.0)
        var out: [MotionElement] = []
        rt.motionElements(&out)
        func hash(_ k: String) throws -> UInt64 {
            try #require(out.first { rt.elementPath($0.id)?.key == k }).textHash
        }
        #expect(try hash("plain") != 0)
        #expect(try hash("secret") == 0)
    }
}
