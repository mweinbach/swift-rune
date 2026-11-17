import Dispatch
import Foundation
import Testing
@testable import Rune
import RuneMotion
import RuneRef

@Suite("Reveal Phase Parity Tests")
struct RevealPhaseParityTests {
    private static let length: Int = 5
    /// The ignored deep run's depth: the same walk, one letter further.
    private static let deep: Int = 6
    /// Upstream `#[ignore = "the deep run"]`: opt in with `RUNE_REVEAL_DEEP=1`.
    private static let deepRunEnabled: Bool = ProcessInfo.processInfo.environment["RUNE_REVEAL_DEEP"] != nil
    private static let fade: Float = 0.05
    private static let chunk: Int = 6

    private struct Facts: Equatable {
        var reveal: Bool
        var fade: Float
        var reducedMotion: Bool
        var timeScaled: Bool
    }

    private static let steady = Facts(
        reveal: true,
        fade: fade,
        reducedMotion: false,
        timeScaled: false
    )

    private struct Doc: Equatable {
        var words: Int = 0
        var replaced: Bool = false
        var mounts: UInt32 = 0
        var parent: Bool = false

        func content() -> String {
            if replaced { return "a b" }
            guard words > 0 else { return "" }
            return Array(repeating: "w", count: words).joined(separator: " ")
        }

        func key() -> String { "t\(mounts)" }
    }

    private enum Letter: CaseIterable, CustomStringConvertible {
        case chunk
        case tick
        case fade
        case midChunk
        case replace
        case end
        case remount
        case returnParent

        var description: String {
            switch self {
            case .chunk: return "Chunk"
            case .tick: return "Tick"
            case .fade: return "Fade"
            case .midChunk: return "MidChunk"
            case .replace: return "Replace"
            case .end: return "End"
            case .remount: return "Remount"
            case .returnParent: return "Return"
            }
        }
    }

    private struct DevReveal: Equatable {
        var len: Int
        var words: [(UInt32, Double)]
        var fade: Float

        static func == (lhs: DevReveal, rhs: DevReveal) -> Bool {
            lhs.len == rhs.len && lhs.fade == rhs.fade && lhs.words.count == rhs.words.count &&
                zip(lhs.words, rhs.words).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        }
    }

    private struct Dev {
        var state: DevReveal? = nil
        var chain: Double = 0.0

        mutating func commit(content: String, wasPresent: Bool, instant: Bool, now: Double, facts: Facts) {
            if !facts.reveal { return }
            let fade = facts.fade
            let mountedLate = !wasPresent && !instant
            var st = state ?? DevReveal(
                len: mountedLate ? 0 : content.utf8.count,
                words: [],
                fade: fade
            )
            st.fade = fade
            let utf8Count = content.utf8.count
            let isBoundary: Bool = {
                guard st.len <= utf8Count else { return false }
                let idx = content.utf8.index(content.utf8.startIndex, offsetBy: st.len)
                return idx.samePosition(in: content) != nil
            }()
            if instant || utf8Count < st.len || !isBoundary {
                st.len = utf8Count
                st.words.removeAll()
            } else if utf8Count > st.len && fade > 0.0 {
                let starts = wordStarts(in: content, from: st.len)
                let own = st.words.last.map { max($0.1, now) } ?? now
                let chained = !facts.timeScaled && (chain - now) <= Double(fade)
                let chainAt = chained ? max(chain, now) : now
                let queued = Int(max(0.0, chainAt - now) / 0.0055)
                let pending = st.words.filter { $0.1 > now }.count + starts.count + queued
                let stagger: Double = {
                    if facts.reducedMotion { return 0.0 }
                    let k = min(max(Float(pending) / 24.0, 0.0), 1.0)
                    return Double(0.020 + (0.0055 - 0.020) * k)
                }()
                var tn = chainAt > own ? chainAt + stagger : own
                for b in starts {
                    st.words.append((b, tn))
                    tn += stagger
                }
                if !facts.timeScaled, let last = st.words.last {
                    chain = max(chain, last.1)
                }
                st.len = utf8Count
            } else {
                st.len = utf8Count
            }
            state = st
        }

        mutating func tick(now: Double) {
            guard var st = state else { return }
            let fade = Double(st.fade)
            var done = 0
            for w in st.words {
                if now - w.1 >= fade {
                    done += 1
                } else {
                    break
                }
            }
            if done > 0 && done == st.words.count {
                st.words.removeAll()
            }
            state = st
        }

        mutating func shift(_ delta: Double) {
            guard var st = state else { return }
            for i in st.words.indices {
                st.words[i].1 += delta
            }
            state = st
        }

        mutating func left() {
            state = nil
        }

        func alpha(byte: UInt32, now: Double) -> Float {
            guard let st = state else { return 1.0 }
            var lo = 0
            var hi = st.words.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if st.words[mid].0 <= byte {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            guard lo > 0 else { return 1.0 }
            let t0 = st.words[lo - 1].1
            if st.fade <= 0.0 {
                return now >= t0 ? 1.0 : 0.0
            }
            let x = Float((now - t0) / Double(st.fade))
            let clamped = min(max(x, 0.0), 1.0)
            let inv = 1.0 - clamped
            return 1.0 - inv * inv * inv
        }
    }

    private static func wordStarts(in s: String, from: Int) -> [UInt32] {
        var out: [UInt32] = []
        var prevSpace = true
        var idx = s.utf8.index(s.utf8.startIndex, offsetBy: from)
        while idx < s.endIndex {
            let c = s[idx]
            let space = c.isWhitespace
            if !space && prevSpace {
                let offset = s.utf8.distance(from: s.utf8.startIndex, to: idx)
                out.append(UInt32(offset))
            }
            prevSpace = space
            idx = s.index(after: idx)
        }
        return out
    }

    private final class Walk {
        var rt: Runtime<Doc>
        var t: Double = 0.0
        var doc = Doc()
        var dev = Dev()
        var present: Bool = true
        var id: NodeId? = nil

        init() {
            let runtime = Runtime(
                state: Doc(),
                viewport: Vec2(200, 200),
                pixelScale: 1.0,
                textSystem: TextSystem()
            ) { d, _ in
                let tEl: El<Doc> = text(d.content())
                    .key(d.key())
                    .wFull()
                    .wrapText()
                    .size(14)
                    .weight(400)
                    .reveal(wordFade: RevealPhaseParityTests.fade)
                let kids: [El<Doc>] = d.parent ? [col().key("p").child(tEl)] : []
                return col().key("root").w(200).children(kids)
            }
            self.rt = runtime
            _ = rt.frame(at: t)
            _ = rt.frame(at: t)
            precondition(!rt.reducedMotion && !rt.systemReducedMotion(), "walk requires non-reduced-motion")
            precondition(!rt.motionNeedsCause, "walk requires motionNeedsCause == false")
            precondition(rt.cxSettings.viewTimeScale == 1.0, "walk requires 1x clock")
            reset()
        }

        func reset() {
            doc = Doc(words: 0, replaced: false, mounts: doc.mounts + 1, parent: true)
            rt.wordRevealStore.reset()
            dev = Dev()
            present = false
            id = nil
            if let err = commit(instant: true) {
                fatalError("reset must succeed: \(err)")
            }
            t += 1.0
            _ = rt.frame(at: t)
            precondition(rt.wordRevealStore.phases.count == 1, "only live text keeps reveal state, got \(rt.wordRevealStore.phases.count)")
        }

        func commit(instant: Bool) -> String? {
            frameCommit(instant: instant, inTree: true)
        }

        func commitAbsent(instant: Bool) -> String? {
            frameCommit(instant: instant, inTree: false)
        }

        private func frameCommit(instant: Bool, inTree: Bool) -> String? {
            let now = t
            let docSnap = doc
            let content = docSnap.content()
            let wasPresent = present
            let commits = rt.commitCount
            rt.update(at: now) { s, tx in
                s = docSnap
                if instant {
                    tx.instant()
                }
            }
            _ = rt.frame(at: now)
            if rt.commitCount != commits + 1 {
                return "an edit committed \(rt.commitCount - commits) times"
            }
            if inTree {
                dev.commit(content: content, wasPresent: wasPresent, instant: instant, now: now, facts: RevealPhaseParityTests.steady)
                present = true
            }
            dev.tick(now: now)
            return compare()
        }

        func tick(dt: Double) -> String? {
            let commits = rt.commitCount
            t += dt
            _ = rt.frame(at: t)
            if rt.commitCount != commits {
                return "a frame with no edit committed \(rt.commitCount - commits) times"
            }
            dev.tick(now: t)
            return compare()
        }

        func play(_ letter: Letter) -> String? {
            switch letter {
            case .chunk:
                doc.words += RevealPhaseParityTests.chunk
                return commit(instant: false)
            case .tick:
                return tick(dt: 1.0 / 60.0)
            case .fade:
                return tick(dt: Double(RevealPhaseParityTests.fade))
            case .midChunk:
                if let err = tick(dt: Double(RevealPhaseParityTests.fade) / 2.0) { return err }
                doc.words += 1
                return commit(instant: false)
            case .replace:
                doc.replaced.toggle()
                return commit(instant: false)
            case .end:
                return commit(instant: false)
            case .remount:
                doc.mounts += 1
                present = false
                dev.left()
                return commit(instant: false)
            case .returnParent:
                doc.parent = false
                if let err = commitAbsent(instant: true) { return err }
                present = false
                doc.parent = true
                return commit(instant: false)
            }
        }

        func compare() -> String? {
            let targetKey = doc.key()
            let node = rt.flatNodes.first { $0.key == targetKey }?.nodeId
            if let nid = node {
                id = nid
            }
            guard let id else {
                return "no text for key \(targetKey), and none before it"
            }
            if node == nil && doc.parent {
                return "no text for key \(targetKey)"
            }
            let ours = rt.wordRevealStore.phases[id]
            let theirs = dev.state
            switch (ours, theirs) {
            case (nil, nil):
                break
            case let (.some(phase), .some(st)):
                if phase.shownBytes != st.len {
                    return "shown \(phase.shownBytes), dev \(st.len)"
                }
                let words = phase.fade?.words ?? []
                let wordsEqual = words.count == st.words.count &&
                    zip(words, st.words).allSatisfy { $0.startByte == $1.0 && $0.startTime == $1.1 }
                if !wordsEqual {
                    return "words \(words), dev \(st.words)"
                }
                if case let .fading(_, _, fade) = phase, fade != st.fade {
                    return "fade \(fade), dev \(st.fade)"
                }
            default:
                return "reveal \(String(describing: ours)), dev \(String(describing: theirs))"
            }
            if rt.wordRevealStore.chain.until != dev.chain {
                return "chain \(rt.wordRevealStore.chain.until), dev \(dev.chain)"
            }
            if node == nil {
                return nil
            }
            let nodeNow = rt.scene.store.nodeTime(id)
            let byteCount = UInt32(doc.content().utf8.count)
            for byte in 0...byteCount {
                let ourAlpha = ours?.fade?.alpha(atUTF8Byte: byte, now: nodeNow) ?? 1.0
                let theirAlpha = dev.alpha(byte: byte, now: nodeNow)
                if ourAlpha != theirAlpha {
                    return "alpha at byte \(byte): \(ourAlpha), dev \(theirAlpha)"
                }
            }
            return nil
        }
    }

    private struct StreamState: Equatable {
        var content: String
        var reveal: Float
        var paused: Bool
        var reduced: Bool

        init(content: String = "", reveal: Float = RevealPhaseParityTests.fade, paused: Bool = false, reduced: Bool = false) {
            self.content = content
            self.reveal = reveal
            self.paused = paused
            self.reduced = reduced
        }

        func facts() -> Facts {
            Facts(
                reveal: reveal >= 0.0,
                fade: reduced ? 0.15 : reveal,
                reducedMotion: reduced,
                timeScaled: paused
            )
        }

        static func streamed(_ content: String) -> StreamState {
            StreamState(content: content, reveal: RevealPhaseParityTests.fade)
        }
    }

    private final class Driven {
        var rt: Runtime<StreamState>
        var t: Double = 0.0
        var state: StreamState
        var dev = Dev()
        var present: Bool = true

        init(_ initial: StreamState) {
            self.state = initial
            self.rt = Runtime(
                state: initial,
                viewport: Vec2(300, 200),
                pixelScale: 1.0,
                textSystem: TextSystem()
            ) { s, cx in
                cx.reducedMotion(s.reduced)
                var el: El<StreamState> = text(s.content).key("t").wFull().wrapText()
                if s.reveal >= 0.0 {
                    el = el.reveal(wordFade: s.reveal)
                }
                if s.paused {
                    el = el.timeScale(0.0)
                }
                return col().key("root").w(300).child(el)
            }
            _ = rt.frame(at: 0.0)
            dev.commit(content: initial.content, wasPresent: false, instant: true, now: 0.0, facts: initial.facts())
        }

        func id() -> NodeId? {
            rt.flatNodes.first { $0.key == "t" }?.nodeId
        }

        func now() -> Double {
            id().map { rt.scene.store.nodeTime($0) } ?? t
        }

        func set(_ mutate: (inout StreamState) -> Void) -> String? {
            mutate(&state)
            return commit(instant: false)
        }

        func commit(instant: Bool) -> String? {
            let before = now()
            let nextState = state
            let wasPresent = present
            rt.update(at: t) { s, tx in
                s = nextState
                if instant { tx.instant() }
            }
            _ = rt.frame(at: t)
            let after = now()
            if after != before {
                dev.shift(after - before)
            }
            dev.commit(content: nextState.content, wasPresent: wasPresent, instant: instant, now: after, facts: nextState.facts())
            dev.tick(now: after)
            present = true
            return check()
        }

        func tick(dt: Double) -> String? {
            t += dt
            _ = rt.frame(at: t)
            dev.tick(now: now())
            return check()
        }

        func check() -> String? {
            guard let nid = id() else { return "no text" }
            let ours = rt.wordRevealStore.phases[nid]
            let theirs = dev.state
            switch (ours, theirs) {
            case (nil, nil):
                break
            case let (.some(phase), .some(st)):
                if phase.shownBytes != st.len {
                    return "shown \(phase.shownBytes), dev \(st.len)"
                }
                let words = phase.fade?.words ?? []
                let wordsEqual = words.count == st.words.count &&
                    zip(words, st.words).allSatisfy { $0.startByte == $1.0 && $0.startTime == $1.1 }
                if !wordsEqual {
                    return "words \(words), dev \(st.words)"
                }
                if phase.isFading != !st.words.isEmpty {
                    return "fading \(phase.isFading), dev words \(st.words)"
                }
                if case let .fading(_, _, fade) = phase, fade != st.fade {
                    return "fade \(fade), dev \(st.fade)"
                }
            default:
                return "reveal \(String(describing: ours)), dev \(String(describing: theirs))"
            }
            if rt.wordRevealStore.chain.until != dev.chain {
                return "chain \(rt.wordRevealStore.chain.until), dev \(dev.chain)"
            }
            let cur = now()
            let len = UInt32(state.content.utf8.count)
            for byte in 0...len {
                let ourAlpha = ours?.fade?.alpha(atUTF8Byte: byte, now: cur) ?? 1.0
                let theirAlpha = dev.alpha(byte: byte, now: cur)
                if ourAlpha != theirAlpha {
                    return "alpha at byte \(byte): \(ourAlpha), dev \(theirAlpha)"
                }
            }
            let fading = theirs.map { !$0.words.isEmpty } ?? false
            let wakes = fading && !state.paused
            let source = (rt.animSources & AnimSource.reveal) != 0
            if source != wakes {
                return "REVEAL source \(source), dev fading \(fading), paused \(state.paused)"
            }
            return nil
        }
    }

    private static func visit(
        walk: Walk,
        alphabet: [Letter],
        depth: Int,
        sequence: inout [Letter],
        ran: inout Int,
        failure: inout String?
    ) {
        if failure != nil { return }
        ran += 1
        walk.reset()
        for letter in sequence {
            if let why = walk.play(letter) {
                failure = "\(sequence): \(why)"
                return
            }
        }
        if sequence.count == depth { return }
        for letter in alphabet {
            sequence.append(letter)
            visit(walk: walk, alphabet: alphabet, depth: depth, sequence: &sequence, ran: &ran, failure: &failure)
            sequence.removeLast()
        }
    }

    private final class WalkResults: @unchecked Sendable {
        let lock = NSLock()
        var total = 0
        var failures: [String] = []
    }

    private static func walkAll(alphabet: [Letter], depth: Int) {
        let results = WalkResults()
        DispatchQueue.concurrentPerform(iterations: alphabet.count) { idx in
            let walk = Walk()
            var ran = 0
            var failure: String? = nil
            var seq = [alphabet[idx]]
            visit(walk: walk, alphabet: alphabet, depth: depth, sequence: &seq, ran: &ran, failure: &failure)
            results.lock.lock()
            results.total += ran
            if let f = failure {
                results.failures.append(f)
            }
            results.lock.unlock()
        }
        #expect(results.failures.isEmpty, "sequences differ from dev: \(results.failures)")
        var expected = 0
        var power = 1
        for _ in 1...depth {
            power *= alphabet.count
            expected += power
        }
        #expect(results.total == expected, "every sequence ran (\(results.total) vs \(expected))")
    }

    @Test("every short sequence of streaming events leaves what dev left")
    func everyShortSequenceOfStreamingEventsLeavesWhatDevLeft() {
        Self.walkAll(alphabet: Letter.allCases, depth: Self.length)
    }

    // The deep run: `RUNE_REVEAL_DEEP=1 xcrun swift test --no-parallel --filter everyDeeperSequence`.
    @Test(
        "every deeper sequence of streaming events leaves what dev left",
        .enabled(if: RevealPhaseParityTests.deepRunEnabled, "the deep run (set RUNE_REVEAL_DEEP=1)")
    )
    func everyDeeperSequenceOfStreamingEventsLeavesWhatDevLeft() {
        Self.walkAll(alphabet: Letter.allCases, depth: Self.deep)
    }

    @Test("a chunk fades its words and the chain follows")
    func aChunkFadesItsWordsAndTheChainFollows() throws {
        let walk = Walk()
        #expect(walk.play(.chunk) == nil)
        let id = try #require(walk.rt.flatNodes.first { $0.key == walk.doc.key() }?.nodeId)
        let phase = try #require(walk.rt.wordRevealStore.phases[id])
        guard case let .fading(_, words, _) = phase else {
            Issue.record("a chunk's words fade, got \(phase)")
            return
        }
        #expect(words.count == Self.chunk, "every word of the chunk fades")
        let lastTime = try #require(words.last?.startTime)
        #expect(walk.rt.wordRevealStore.chain.until >= lastTime, "the chain holds the newest word")
        let nodeNow = walk.rt.scene.store.nodeTime(id)
        #expect(walk.rt.wordRevealStore.chain.until - nodeNow > Double(Self.fade), "a chunk's run outlasts a fade")
    }

    @Test("a remount starts its words from none")
    func aRemountStartsItsWordsFromNone() throws {
        let walk = Walk()
        #expect(walk.play(.chunk) == nil)
        #expect(walk.play(.remount) == nil)
        let id = try #require(walk.rt.flatNodes.first { $0.key == walk.doc.key() }?.nodeId)
        let phase = try #require(walk.rt.wordRevealStore.phases[id])
        guard case let .fading(_, words, _) = phase else {
            Issue.record("a remount fades its words in, got \(phase)")
            return
        }
        #expect(words.first?.startByte == 0, "it starts at its first word")
    }

    @Test("a returning child keeps its words after an instant parent unmount")
    func aReturningChildKeepsItsWordsAfterAnInstantParentUnmount() throws {
        struct S { var parent: Bool = false }
        let rt = Runtime(state: S(), viewport: Vec2(300, 200), pixelScale: 1.0) { s, _ in
            let kids: [El<S>] = s.parent ? [
                col().key("p").child(
                    text("a b c").key("t").wFull().wrapText().reveal(wordFade: RevealPhaseParityTests.fade)
                )
            ] : []
            return col().key("root").w(300).children(kids)
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.0) { s, _ in s.parent = true }
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 0.1)
        let id = try #require(rt.flatNodes.first { $0.key == "t" }?.nodeId)
        #expect(rt.wordRevealStore.phases[id]?.caughtUp(endBytes: 5) == true, "the first words have shown")

        rt.update(at: 0.1) { s, tx in
            s.parent = false
            tx.instant()
        }
        _ = rt.frame(at: 0.1)
        #expect(rt.wordRevealStore.phases[id] != nil, "the unmounted child keeps its reveal state")

        rt.update(at: 0.1) { s, _ in s.parent = true }
        _ = rt.frame(at: 0.1)
        let back = try #require(rt.flatNodes.first { $0.key == "t" }?.nodeId)
        #expect(back == id, "the same key returns under the same id")
        let phase = try #require(rt.wordRevealStore.phases[id])
        #expect(phase.caughtUp(endBytes: 5), "it comes back showing its words, not replaying them: \(phase)")
    }

    @Test("an instant commit clears a fade")
    func anInstantCommitClearsAFade() throws {
        struct S { var longer: Bool = false }
        let rt = Runtime(state: S(), viewport: Vec2(300, 200), pixelScale: 1.0) { s, _ in
            let content = s.longer ? "a b c" : "a"
            return col().key("root").w(300).child(
                text(content).key("t").wFull().wrapText().reveal(wordFade: RevealPhaseParityTests.fade)
            )
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.0) { s, _ in s.longer = true }
        _ = rt.frame(at: 0.0)
        let id = try #require(rt.flatNodes.first { $0.key == "t" }?.nodeId)
        #expect(rt.wordRevealStore.phases[id]?.isFading == true, "the new words fade")

        rt.update(at: 0.0) { _, tx in tx.instant() }
        _ = rt.frame(at: 0.0)
        #expect(rt.wordRevealStore.phases[id]?.caughtUp(endBytes: 5) == true, "the instant commit shows them at once")
    }

    @Test("an unprompted commit lands a new text whole")
    func anUnpromptedCommitLandsANewTextWhole() throws {
        struct S { var shown: Bool = false }
        let rt = Runtime(state: S(), viewport: Vec2(200, 200), pixelScale: 1.0) { s, _ in
            let kids: [El<S>] = s.shown ? [
                text("a b c d").key("t").wFull().wrapText().reveal(wordFade: RevealPhaseParityTests.fade)
            ] : []
            return col().key("root").w(200).children(kids)
        }
        rt.motionNeedsCause = true
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.0) { s, _ in s.shown = true }
        _ = rt.frame(at: 0.0)
        let id = try #require(rt.flatNodes.first { $0.key == "t" }?.nodeId)
        #expect(rt.wordRevealStore.phases[id]?.caughtUp(endBytes: 7) == true, "no input caused it, so it shows whole")
    }

    @Test("a cut through a character shows whole")
    func aCutThroughACharacterShowsWhole() throws {
        struct S { var content: String = "" }
        let rt = Runtime(state: S(), viewport: Vec2(200, 200), pixelScale: 1.0) { s, _ in
            col().key("root").w(200).child(
                text(s.content).key("t").wFull().wrapText().reveal(wordFade: RevealPhaseParityTests.fade)
            )
        }
        _ = rt.frame(at: 0.0)
        rt.update(at: 0.0) { s, _ in s.content = "aaa bbbb" }
        _ = rt.frame(at: 0.0)
        let id = try #require(rt.flatNodes.first { $0.key == "t" }?.nodeId)
        #expect(rt.wordRevealStore.phases[id]?.isFading == true, "the first chunk fades")

        // Byte 8 is inside "é" (bytes 7 and 8) now, so the old end still fading cannot be kept.
        let accented = "aaaaaaaé"
        rt.update(at: 0.0) { s, _ in s.content = accented }
        _ = rt.frame(at: 0.0)
        #expect(rt.wordRevealStore.phases[id]?.caughtUp(endBytes: accented.utf8.count) == true, "a moved boundary shows whole")
    }

    @Test("a reveal turned off mid fade keeps what arrives for later")
    func aRevealTurnedOffMidFadeKeepsWhatArrivesForLater() {
        let w = Driven(.streamed("a b"))
        #expect(w.set { $0.content = "a b c d" } == nil)
        #expect(w.set { $0.reveal = -1.0 } == nil)
        #expect(w.set { $0.content = "a b c d  " } == nil)
        #expect(w.tick(dt: 1.0) == nil)
        #expect(w.set { $0.content = "a b c d  ef" } == nil)
        #expect(w.set { $0.reveal = Self.fade } == nil)
        let keptNewWords = w.rt.wordRevealStore.phases.values.contains { phase in
            (phase.fade?.words ?? []).contains { $0.startByte >= 8 }
        }
        #expect(keptNewWords, "the bytes that arrived while off fade in")
        #expect(w.set { $0.content = "a b c d  efg" } == nil)
        #expect(w.tick(dt: 0.3) == nil)
    }

    @Test("a reveal of zero shows future words whole")
    func aRevealOfZeroShowsFutureWordsWhole() {
        let w = Driven(.streamed("a b"))
        #expect(w.set { $0.reveal = 0.0 } == nil)
        #expect(w.set { $0.content = "a b c d" } == nil)
        #expect(w.set { $0.content = "a b c d e" } == nil)
        #expect(w.tick(dt: 0.1) == nil)
    }

    @Test("reduced motion fades every word together")
    func reducedMotionFadesEveryWordTogether() {
        let w = Driven(.streamed("a b"))
        #expect(w.set { $0.reduced = true } == nil)
        #expect(w.set { $0.content = "a b c d e f" } == nil)
        let times = w.rt.wordRevealStore.phases.values.flatMap { ($0.fade?.words ?? []).map(\.startTime) }
        #expect(times.count > 1, "the chunk's words fade: \(times)")
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 == $1 }, "no stagger, so they start together: \(times)")
        #expect(w.tick(dt: 0.2) == nil)
        #expect(w.set { $0.reduced = false } == nil)
        #expect(w.set { $0.content = "a b c d e f g" } == nil)
        #expect(w.tick(dt: 0.2) == nil)
    }

    @Test("a paused clock freezes the fade and its resume shifts the words")
    func aPausedClockFreezesTheFadeAndItsResumeShiftsTheWords() {
        let w = Driven(.streamed("a b"))
        #expect(w.set { $0.content = "a b c d" } == nil)
        let before = w.rt.wordRevealStore.phases.values.flatMap { ($0.fade?.words ?? []).map(\.startTime) }
        let chain = w.rt.wordRevealStore.chain.until
        #expect(w.set { $0.paused = true } == nil)
        #expect(w.tick(dt: 0.2) == nil)
        let whileFrozen = w.rt.wordRevealStore.phases.values.flatMap { ($0.fade?.words ?? []).map(\.startTime) }
        #expect(before == whileFrozen, "a frozen clock doesn't fade")
        #expect(w.set { $0.content = "a b c d e" } == nil)
        let frozen = w.now()
        #expect(w.set { $0.content = "a b c d e f" } == nil)
        let added = w.rt.wordRevealStore.phases.values.flatMap {
            ($0.fade?.words ?? []).filter { $0.startByte >= 9 }.map(\.startTime)
        }
        #expect(added.allSatisfy { $0 >= frozen }, "a chunk on a scaled clock starts at its own time: \(added) from \(frozen)")
        #expect(chain == w.rt.wordRevealStore.chain.until, "a scaled clock never joins the chain")
        #expect(w.set { $0.paused = false } == nil)
        let resumed = w.now()
        #expect(resumed > frozen, "the clock jumped on resume: \(resumed) from \(frozen)")
        let shifted = w.rt.wordRevealStore.phases.values.flatMap { ($0.fade?.words ?? []).map(\.startTime) }
        #expect(zip(shifted, before).allSatisfy { a, b in a - b >= resumed - frozen - 1e-9 }, "every word moved with the clock")
        #expect(w.tick(dt: 0.2) == nil)
        #expect(w.set { $0.content = "a b c d e f g" } == nil)
        #expect(w.tick(dt: 0.2) == nil)
    }
}
