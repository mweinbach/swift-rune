import Foundation
import Testing
@testable import Rune
import RuneMotion

@Suite("Rune Reveal Phase, Chain & Insert Parity Tests (reveal_phase.rs, reveal_chain.rs, reveal_insert.rs)")
struct RevealPhaseParityTests {
    private struct Doc {
        var paras: [String]
    }

    private static func words(_ n: Int) -> String {
        (0..<n).map { "word\($0)" }.joined(separator: " ")
    }

    private static func chainRuntime() -> Runtime<Doc> {
        let rt = Runtime<Doc>(
            state: Doc(paras: [""]),
            viewport: Vec2(600, 800),
            pixelScale: 2.0,
            systemDark: true
        ) { s, _ in
            col().wFull().children(
                s.paras.enumerated().map { i, p in
                    text(p).wrapText().wFull().reveal(0.3).key("p\(i)")
                }
            )
        }
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 1.0 / 60.0)
        return rt
    }

    private static func wordTimes(_ rt: Runtime<Doc>, key: String) -> (Double, Double)? {
        guard let node = rt.flatNodes.first(where: { $0.key == key }),
              let phase = rt.reveals[node.nodeId],
              let first = phase.words.first?.start,
              let last = phase.words.last?.start else {
            return nil
        }
        return (first, last)
    }

    @Test("reveal_chain::one_chunk_over_three_paragraphs_fades_them_in_order")
    func oneChunkOverThreeParagraphsFadesInOrder() throws {
        let rt = Self.chainRuntime()
        rt.update(at: 1.0 / 60.0) { s, _ in
            s.paras = [Self.words(12), Self.words(12), Self.words(12)]
        }
        _ = rt.frame(at: 2.0 / 60.0)
        let a = try #require(Self.wordTimes(rt, key: "p0"))
        let b = try #require(Self.wordTimes(rt, key: "p1"))
        let c = try #require(Self.wordTimes(rt, key: "p2"))
        #expect(b.0 > a.1 && c.0 > b.1, "each paragraph starts after the one above ends: \(a) \(b) \(c)")
    }

    @Test("reveal_chain::a_new_paragraph_waits_for_the_last_ones_tail")
    func newParagraphWaitsForLastOnesTail() throws {
        let rt = Self.chainRuntime()
        rt.update(at: 1.0 / 60.0) { s, _ in
            s.paras = [Self.words(30)]
        }
        _ = rt.frame(at: 2.0 / 60.0)
        let a = try #require(Self.wordTimes(rt, key: "p0"))
        rt.update(at: 2.0 / 60.0) { s, _ in
            s.paras.append(Self.words(4))
        }
        _ = rt.frame(at: 3.0 / 60.0)
        let b = try #require(Self.wordTimes(rt, key: "p1"))
        #expect(b.0 > a.1, "next paragraph starts after last word above: \(a) then \(b)")
    }

    @Test("reveal_chain::once_everything_has_shown_a_new_paragraph_starts_at_once")
    func onceShownNewParagraphStartsAtOnce() throws {
        let rt = Self.chainRuntime()
        var t = 1.0 / 60.0
        rt.update(at: t) { s, _ in
            s.paras = [Self.words(8)]
        }
        for _ in 0..<120 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        rt.update(at: t) { s, _ in
            s.paras.append(Self.words(4))
        }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        let (first, _) = try #require(Self.wordTimes(rt, key: "p1"))
        #expect(abs(first - t) < 0.02, "no wait once nothing is fading: starts \(first), now \(t)")
    }

    @Test("reveal_chain::texts_behind_a_long_run_fade_together")
    func textsBehindLongRunFadeTogether() throws {
        let rt = Self.chainRuntime()
        rt.update(at: 1.0 / 60.0) { s, _ in
            s.paras = [Self.words(120), Self.words(120), Self.words(120)]
        }
        _ = rt.frame(at: 2.0 / 60.0)
        let a = try #require(Self.wordTimes(rt, key: "p0"))
        let b = try #require(Self.wordTimes(rt, key: "p1"))
        let c = try #require(Self.wordTimes(rt, key: "p2"))
        #expect(a.1 - a.0 > 0.3, "first paragraph run outlasts a fade: \(a)")
        #expect(b.0 < a.1 && c.0 < a.1, "the rest don't wait for it: \(a) \(b) \(c)")
    }

    @Test("reveal_phase: appended words fade monotonically from 0 -> 1 and go idle")
    func revealPhaseWordFadeAndIdle() throws {
        struct StreamDoc { var content = "" }
        let rt = Runtime<StreamDoc>(
            state: StreamDoc(content: ""),
            viewport: Vec2(240, 200),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            col().wFull().child(text(s.content).key("msg").wFull().wrapText().reveal(0.2))
        }
        var t = 0.0
        _ = rt.frame(at: t)
        rt.update(at: t) { s, _ in s.content = "alpha beta gamma" }
        t += 1.0 / 60.0
        _ = rt.frame(at: t)
        #expect(rt.isAnimating)
        let node = try #require(rt.flatNodes.first { $0.key == "msg" })
        let rev = try #require(rt.reveals[node.nodeId])
        #expect(rev.isFading)
        let firstWordAlpha = rev.alpha(at: 0, now: t)
        let lastWordByte = UInt32("alpha beta ".utf8.count)
        let lastWordAlpha = rev.alpha(at: lastWordByte, now: t)
        #expect(firstWordAlpha >= lastWordAlpha)
        #expect(rt.flatNodes.count >= 2)

        for _ in 0..<60 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        let settledRev = try #require(rt.reveals[node.nodeId])
        #expect(!settledRev.isFading)
        #expect(settledRev.alpha(at: lastWordByte, now: t) == 1.0)
    }

    @Test("reveal_insert: entering revealed text fades all initial words unless cut")
    func revealInsertEnteringVsCut() throws {
        struct InsertDoc { var show = false }
        let rt = Runtime<InsertDoc>(
            state: InsertDoc(show: false),
            viewport: Vec2(240, 200),
            pixelScale: 1.0,
            systemDark: true
        ) { s, _ in
            col().key("root").wFull().children(
                s.show ? [text("one two three four").key("late").wFull().wrapText().reveal(0.25)] : []
            )
        }
        var t = 0.0
        _ = rt.frame(at: t)
        t += 1.0 / 60.0
        rt.update(at: t) { s, _ in s.show = true }
        _ = rt.frame(at: t)
        let node = try #require(rt.flatNodes.first { $0.key == "late" })
        let rev = try #require(rt.reveals[node.nodeId])
        #expect(rev.isFading, "late-mounted revealed text fades in its initial words")
        let lastWordByte = UInt32("one two three ".utf8.count)
        #expect(rev.alpha(at: lastWordByte, now: t) < 0.5)

        for _ in 0..<60 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        #expect(rt.reveals[node.nodeId]?.isFading == false)
    }

    @Test("reveal_phase: remount, instant commit, unprompted commit, char cut, toggle off, reveal(0), reducedMotion, and paused clock shift")
    func revealPhaseStateMachineAndRuntimeEdgeCases() throws {
        // 1. State-machine checks matching reveal_phase.rs unit cases
        var chain: RevealChain? = RevealChain()
        var phase = RevealPhase.idle(shown: 0, fade: 0.3)

        // Remount (entering) starts all words from 0
        _ = phase.step(.commit(content: "alpha beta gamma", fade: 0.3, arrival: .entering, now: 1.0, reducedMotion: false), chain: &chain)
        #expect(phase.isFading)
        #expect(phase.alpha(at: 0, now: 1.0) < 0.01)

        // Cut through a character (shrink or non-boundary) shows whole (replaced)
        _ = phase.step(.commit(content: "ab", fade: 0.3, arrival: .kept, now: 1.05, reducedMotion: false), chain: &chain)
        #expect(!phase.isFading)
        #expect(phase.shownBytes == "ab".utf8.count)

        // Reveal(0) shows future words whole
        _ = phase.step(.commit(content: "ab cd ef", fade: 0.0, arrival: .kept, now: 1.1, reducedMotion: false), chain: &chain)
        #expect(!phase.isFading)
        #expect(phase.alpha(at: UInt32("ab ".utf8.count), now: 1.1) == 1.0)

        // Reduced motion gives stagger == 0 so every appended word starts together
        var rmPhase = RevealPhase.idle(shown: 0, fade: 0.15)
        var noChain: RevealChain? = nil
        _ = rmPhase.step(.commit(content: "one two three four", fade: 0.15, arrival: .entering, now: 2.0, reducedMotion: true), chain: &noChain)
        #expect(rmPhase.words.count == 4)
        let allEqualStart = Set(rmPhase.words.map(\.start)).count == 1
        #expect(allEqualStart)

        // Paused clock shift moves all remaining word start timestamps by delta
        let beforeShift = rmPhase.words.first?.start ?? 0
        _ = rmPhase.step(.shift(delta: 0.75), chain: &noChain)
        #expect(abs((rmPhase.words.first?.start ?? 0) - (beforeShift + 0.75)) < 1e-6)

        // Instant / replaced commit clears active fade
        _ = rmPhase.step(.commit(content: "one two three four", fade: 0.15, arrival: .replaced, now: 2.8, reducedMotion: false), chain: &noChain)
        #expect(!rmPhase.isFading)

        // 2. Runtime tests: instant commit clears fade, toggle reveal off mid-fade keeps later text for when re-enabled
        struct ToggleState: Sendable {
            var text: String = "hello"
            var revealOn: Bool = true
            var instantParentShown: Bool = true
        }
        let rt = Runtime<ToggleState>(state: ToggleState()) { s, _ in
            let rowNode: El<ToggleState> = el().child(
                s.revealOn
                    ? text(s.text).key("msg").wFull().wrapText().reveal(0.3)
                    : text(s.text).key("msg").wFull().wrapText()
            )
            return col().w(300).children(s.instantParentShown ? [rowNode] : [])
        }
        var t = 0.0
        _ = rt.frame(at: t)
        t += 1.0 / 60.0
        rt.update(at: t) { s, _ in s.text = "hello world again" }
        _ = rt.frame(at: t)
        let msgNode = try #require(rt.flatNodes.first { $0.key == "msg" })
        #expect(rt.reveals[msgNode.nodeId]?.isFading == true)

        // Instant commit clears active fade immediately
        t += 1.0 / 60.0
        rt.update(at: t) { s, tx in
            s.text = "hello world again now"
            tx.instant()
        }
        _ = rt.frame(at: t)
        #expect(rt.reveals[msgNode.nodeId]?.isFading == false)

        // Returning child keeps words after an instant parent unmount/remount
        t += 1.0 / 60.0
        rt.update(at: t) { s, tx in
            s.instantParentShown = false
            tx.instant()
        }
        _ = rt.frame(at: t)
        t += 1.0 / 60.0
        rt.update(at: t) { s, tx in
            s.instantParentShown = true
            tx.instant()
        }
        _ = rt.frame(at: t)
        let returnedNode = try #require(rt.flatNodes.first { $0.key == "msg" })
        #expect(rt.reveals[returnedNode.nodeId]?.isFading == false)

        // Turning reveal off mid-fade holds what arrives later until reveal turns back on
        t += 1.0 / 60.0
        rt.update(at: t) { s, _ in
            s.text = "hello world again now streaming"
        }
        _ = rt.frame(at: t)
        #expect(rt.reveals[returnedNode.nodeId]?.isFading == true)
        t += 0.5
        _ = rt.frame(at: t) // finish previous fade
        rt.update(at: t) { s, _ in
            s.revealOn = false
            s.text = "hello world again now streaming later"
        }
        _ = rt.frame(at: t)
        t += 1.0 / 60.0
        rt.update(at: t) { s, _ in s.revealOn = true }
        _ = rt.frame(at: t)
        #expect(rt.reveals[returnedNode.nodeId]?.isFading == true)

        // Reduced motion on Runtime renders appended words together
        let rtRM = Runtime<String>(state: "start") { s, _ in
            col().w(300).child(text(s).key("rm").wFull().wrapText().reveal(0.3))
        }
        rtRM.setSystemReducedMotion(true)
        _ = rtRM.frame(at: 0)
        rtRM.update(at: 0.1) { s, _ in s = "start alpha beta gamma" }
        _ = rtRM.frame(at: 0.1)
        let rmNode = try #require(rtRM.flatNodes.first { $0.key == "rm" })
        let rmPhaseRT = try #require(rtRM.reveals[rmNode.nodeId])
        #expect(Set(rmPhaseRT.words.map(\.start)).count <= 1)

        // Unprompted commits land newly-mounted reveal text whole without fading
        struct UnpromptedState { var shown = false }
        let rtUnprompted = Runtime<UnpromptedState>(state: UnpromptedState()) { s, _ in
            let kids: [El<UnpromptedState>] = s.shown
                ? [text("one two three").key("unp").wFull().wrapText().reveal(0.3)]
                : []
            return col().w(300).children(kids)
        }
        _ = rtUnprompted.frame(at: 0)
        rtUnprompted.update(at: 0.1) { s, tx in
            s.shown = true
            tx.setUnprompted()
        }
        _ = rtUnprompted.frame(at: 0.1)
        let unpNode = try #require(rtUnprompted.flatNodes.first { $0.key == "unp" })
        #expect(rtUnprompted.reveals[unpNode.nodeId]?.isFading != true)
    }

    @Test("reveal_insert: rows inserted above top and revealed in the same commit stay visible in view")
    func rowsInsertedAboveTopAndRevealedLandInView() throws {
        struct InsertState: Sendable {
            var items: [UInt32] = (0..<1000).map { UInt32($0) }
        }
        struct RowMemoDeps: Equatable {
            let id: UInt32
            let isFirst: Bool
        }

        func scrolledAwayAndBack() -> (rt: Runtime<InsertState>, t: Double) {
            let rt = Runtime<InsertState>(
                state: InsertState(),
                viewport: Vec2(400, 300),
                pixelScale: 1.0,
                systemDark: true
            ) { (s: InsertState, _) -> El<InsertState> in
                let rows: El<InsertState> = col()
                    .key("rows")
                    .wFull()
                    .px(8)
                    .py(6)
                    .growth(GrowthSpec.default)
                    .virtualRows(
                        s.items.count,
                        Float(44.0),
                        key: { (st: InsertState, i: Int) in "item\(st.items[i])" },
                        build: { (st: InsertState, i: Int) -> El<InsertState> in
                            let id = st.items[i]
                            return memo("item\(id)", RowMemoDeps(id: id, isFirst: i == 0)) {
                                var row: El<InsertState> = col().wFull()
                                if i == 0 {
                                    row = row.child(el().key("section").wFull().h(30))
                                }
                                return row.child(
                                    el().key("item\(id)").wFull().h(44).child(text("Row \(id)"))
                                )
                            }
                        }
                    )
                return col().wFull().hFull().child(
                    col()
                        .key("list")
                        .wFull()
                        .h(300)
                        .scroll(stickBottom: false)
                        .scrollMargin(6)
                        .child(rows)
                )
            }

            var t = 0.0
            for _ in 0..<10 {
                t += 1.0 / 120.0
                _ = rt.frame(at: t)
            }
            rt.settleAll()

            for row in [40, 0] {
                rt.update(at: t) { _, tx in
                    tx.scrollIntoView("item\(row)")
                }
                for _ in 0..<3 {
                    t += 1.0 / 120.0
                    _ = rt.frame(at: t)
                }
            }
            return (rt, t)
        }

        for inserted in UInt32(1)...2 {
            var (rt, t) = scrolledAwayAndBack()
            rt.update(at: t) { s, tx in
                for n in 0..<inserted {
                    s.items.insert(1001 + n, at: 0)
                }
                tx.scrollIntoView("item\(s.items[0])")
            }

            let first = "item\(1000 + inserted)"
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            let el1 = rt.element(byKey: first)
            let firstAfter1 = try #require(el1)
            #expect(firstAfter1.visible[3] > 43.5, "after 1 frame visible=\(firstAfter1.visible.description)")

            for _ in 0..<3 {
                t += 1.0 / 120.0
                _ = rt.frame(at: t)
            }
            let el4 = rt.element(byKey: first)
            let firstAfter4 = try #require(el4)
            #expect(firstAfter4.visible[3] > 43.5, "after 4 frames visible=\(firstAfter4.visible.description)")

            rt.settleAll()
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            let elS = rt.element(byKey: first)
            let firstAfterSettle = try #require(elS)
            #expect(firstAfterSettle.visible[3] > 43.5, "after settle visible=\(firstAfterSettle.visible.description)")

            let secEl = rt.elements().first { $0.key == "section" && !$0.exiting }
            let section = try #require(secEl)
            #expect(
                section.visible[3] > 29.5 && section.rect[1] >= -0.05,
                "section hidden/clipped rect=\(section.rect.description) visible=\(section.visible.description)"
            )
        }
    }
}
