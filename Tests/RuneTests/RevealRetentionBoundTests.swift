import Foundation
import Testing
@testable import Rune
import RuneMotion

/// Ports of the r364 (c369cc05) tests in upstream `runtime/tests/reveal_phase.rs`: the reveal state
/// a keyed child leaves behind is kept for its return, but only the newest `REVEALS_KEPT`.
///
/// Upstream's `Runtime::frame(dt)` takes a delta; Swift's `frame(at:)` takes the absolute time, so
/// each test keeps a running clock that advances by the same deltas.
@Suite("Reveal Retention Bound Tests")
struct RevealRetentionBoundTests {
    private static let fade: Float = 0.05

    private final class Clock {
        var t = 0.0
        func step<S>(_ rt: Runtime<S>, _ dt: Double) {
            t += dt
            _ = rt.frame(at: t)
        }
    }

    /// A child that never comes back leaves its reveal behind: only the newest `REVEALS_KEPT` that
    /// left are kept for a return, the oldest go (`removed_children_keep_at_most_the_newest_reveals`).
    @Test("removed children keep at most the newest reveals")
    func removedChildrenKeepAtMostTheNewestReveals() throws {
        let kept = WordRevealStore.REVEALS_KEPT
        #expect(kept == 64)
        struct S {
            var n: Int = 0
            var present: Bool = false
        }
        let rt = Runtime(state: S(), viewport: Vec2(300, 200), pixelScale: 1.0, systemDark: true) { s, _ in
            let kids: [El<S>] = s.present ? [
                col().key("p\(s.n)").child(
                    text("a b c").key("t").wFull().wrapText().reveal(wordFade: RevealRetentionBoundTests.fade)
                )
            ] : []
            return col().key("root").w(300).children(kids)
        }
        let clock = Clock()
        clock.step(rt, 0.0)
        let count = kept * 2
        var ids: [NodeId] = []
        for n in 0..<count {
            rt.update(at: clock.t) { s, _ in
                s.n = n
                s.present = true
            }
            clock.step(rt, 0.0)
            clock.step(rt, 0.1)
            ids.append(try #require(rt.flatNodes.first { $0.key == "t" }?.nodeId))
            rt.update(at: clock.t) { s, tx in
                s.present = false
                tx.instant()
            }
            clock.step(rt, 0.0)
        }
        #expect(Set(ids).count == count, "every key mounts its text under its own id")
        let store = rt.wordRevealStore
        #expect(store.phases.count == kept, "the newest keys' reveals stay and the oldest left")
        #expect(store.revealsKept.count <= kept, "\(store.revealsKept.count) orphans tracked")
        // Upstream's dropped paths leave with the next commit's `prune_path_ids`; Swift's ids are
        // path hashes, so the per-id side tables are what must stay bounded with the states.
        rt.update(at: clock.t) { s, _ in s.n += 1 }
        clock.step(rt, 0.0)
        let after = rt.wordRevealStore
        let sides = after.sideTableCounts
        #expect(sides.texts <= kept && sides.parentIds <= kept && sides.born <= kept, "\(sides) ids kept")
        #expect(after.phases[ids[count - 1]] != nil, "the newest key's reveal stays for a return")
        #expect(after.phases[ids[0]] == nil, "the oldest key's reveal left")
        #expect(Set(after.revealsKept) == Set(ids[(count - kept)...]), "exactly the newest keys are kept")
        #expect(after.revealsKept.first == ids[count - 1], "kept newest first")
    }

    /// A child that comes back after its parent unmounted instantly keeps its words while its reveal
    /// is still one of the newest `REVEALS_KEPT`, however many other keys have left since
    /// (`a_child_returning_within_the_bound_keeps_its_words`).
    @Test("a child returning within the bound keeps its words")
    func aChildReturningWithinTheBoundKeepsItsWords() throws {
        let kept = WordRevealStore.REVEALS_KEPT
        struct S {
            var parent: Bool = false
            var other: Int = 0
            var otherPresent: Bool = false
        }
        let rt = Runtime(state: S(), viewport: Vec2(300, 200), pixelScale: 1.0, systemDark: true) { s, _ in
            var kids: [El<S>] = []
            if s.parent {
                kids.append(col().key("p").child(
                    text("a b c").key("t").wFull().wrapText().reveal(wordFade: RevealRetentionBoundTests.fade)
                ))
            }
            if s.otherPresent {
                kids.append(col().key("o\(s.other)").child(
                    text("a b c").key("t").wFull().wrapText().reveal(wordFade: RevealRetentionBoundTests.fade)
                ))
            }
            return col().key("root").w(300).children(kids)
        }
        let clock = Clock()
        clock.step(rt, 0.0)
        rt.update(at: clock.t) { s, _ in s.parent = true }
        clock.step(rt, 0.0)
        clock.step(rt, 0.1)
        // Only `p`'s text is mounted here, so key `t` names `root/p/t`.
        let id = try #require(rt.flatNodes.first { $0.key == "t" }?.nodeId)
        #expect(rt.wordRevealStore.phases[id]?.caughtUp(endBytes: 5) == true, "the first words have shown")
        rt.update(at: clock.t) { s, tx in
            s.parent = false
            tx.instant()
        }
        clock.step(rt, 0.0)
        for n in 0..<(kept / 2) {
            rt.update(at: clock.t) { s, _ in
                s.other = n
                s.otherPresent = true
            }
            clock.step(rt, 0.0)
            clock.step(rt, 0.1)
            rt.update(at: clock.t) { s, tx in
                s.otherPresent = false
                tx.instant()
            }
            clock.step(rt, 0.0)
        }
        #expect(rt.wordRevealStore.phases[id] != nil, "the returning child's reveal is still within the bound")
        rt.update(at: clock.t) { s, _ in s.parent = true }
        clock.step(rt, 0.0)
        let back = try #require(rt.flatNodes.first { $0.key == "t" }?.nodeId)
        #expect(back == id, "the same key returns under the same id")
        let phase = try #require(rt.wordRevealStore.phases[back])
        #expect(phase.caughtUp(endBytes: 5), "it comes back showing its words, not replaying them: \(phase)")
    }
}
