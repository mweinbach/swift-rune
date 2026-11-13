import Foundation
import Testing
@testable import RuneKit
@testable import Rune
@testable import RuneMotion

@Suite("RollingText Runtime Parity Tests")
struct RollingTextRuntimeParityTests {

    private struct BasicState: Sendable {
        var key: String
        var text: String
        var mono: Bool
        var reduced: Bool
    }

    private func makeBasicRuntime(
        key: String,
        text: String,
        mono: Bool = false,
        reduced: Bool = false,
        store: RollingTextStore = RollingTextStore()
    ) -> (Runtime<BasicState>, Kit) {
        let kit = Kit.neutral(dark: true)
        let rt = Runtime(
            state: BasicState(key: key, text: text, mono: mono, reduced: reduced),
            viewport: Vec2(400, 120),
            pixelScale: 2.0,
            systemDark: true
        ) { s, cx in
            cx.reducedMotion(s.reduced)
            let font = s.mono ? kit.ty.mono : kit.ty.body
            return row().p(20).child(
                RollingText<BasicState>(key: s.key, value: s.text, font: font, kit: kit, store: store).build()
            )
        }
        _ = rt.frame(at: 0.0)
        return (rt, kit)
    }

    private func glyphKeys<T>(_ rt: Runtime<T>, key: String) -> [(key: String, text: String)] {
        let prefix = "\(key)#"
        return rt.elements()
            .filter { !$0.inert && !$0.exiting && ($0.key?.hasPrefix(prefix) ?? false) }
            .sorted { $0.rect[0] < $1.rect[0] }
            .compactMap { e in
                guard let k = e.key else { return nil }
                return (k, e.text ?? "")
            }
    }

    private func film<T>(
        _ rt: Runtime<T>,
        keys: [String],
        seconds: Double,
        now: inout Double
    ) -> [[([Float], Float)?]] {
        let steps = Int(seconds * 120.0)
        var frames: [[([Float], Float)?]] = []
        frames.reserveCapacity(steps)
        let elemsByKey = { (elems: [ElementInfo]) -> [String: ([Float], Float)] in
            var map: [String: ([Float], Float)] = [:]
            for e in elems {
                if let k = e.key, map[k] == nil {
                    map[k] = (e.rect, e.opacity)
                }
            }
            return map
        }
        for _ in 0..<steps {
            now += 1.0 / 120.0
            _ = rt.frame(at: now)
            let byKey = elemsByKey(rt.elements())
            frames.append(keys.map { byKey[$0] })
        }
        return frames
    }

    private func largestStep(_ frames: [[([Float], Float)?]]) -> Float {
        var worst: Float = 0.0
        for idx in 1..<frames.count {
            let prev = frames[idx - 1]
            let cur = frames[idx]
            for (aOpt, bOpt) in zip(prev, cur) {
                guard let (a, _) = aOpt, let (b, _) = bOpt else { continue }
                for k in 0..<4 {
                    worst = max(worst, abs(a[k] - b[k]))
                }
            }
        }
        return worst
    }

    private func spanWidth<T>(_ rt: Runtime<T>, key: String) throws -> Float {
        let cells = glyphKeys(rt, key: key)
        let firstKey = try #require(cells.first).key
        let lastKey = try #require(cells.last).key
        let first = try #require(rt.element(byKey: firstKey))
        let last = try #require(rt.element(byKey: lastKey))
        return last.rect[0] + last.rect[2] - first.rect[0]
    }

    private func wrongWay(_ xs: [Float]) -> Float {
        guard let first = xs.first, let last = xs.last else { return 0 }
        let net = last - first
        if abs(net) < 0.25 {
            return xs.map { abs($0 - first) }.max() ?? 0
        }
        let dir: Float = net > 0 ? 1 : -1
        let back = xs.map { (first - $0) * dir }.max() ?? 0
        let past = xs.map { ($0 - last) * dir }.max() ?? 0
        return max(back, past)
    }

    // 1. crates/rune-kit/src/rolling_text.rs:377
    @Test("Long labels in RollingTextStore stay bounded by maxBytes (src/rolling_text.rs:377)")
    func longLabelsAreBoundedByBytes() {
        let store = RollingTextStore()
        let long = String(repeating: "x", count: 5_000)
        for i in 0..<200 {
            _ = store.update(key: "long-\(i)", value: long, trailing: false)
            #expect(store.storedBytes <= RollingTextLimits.maxBytes)
        }
    }

    // 3. crates/rune-kit/tests/rolling_text.rs:210
    @Test("Kept glyphs glide to their new advance monotonically and match plain text (tests/rolling_text.rs:210)")
    func keptGlyphsGlideToTheirNewAdvance() throws {
        struct PairState: Sendable { var text: String; var font: TextStyle }
        let kit = Kit.neutral(dark: true)
        let store = RollingTextStore()
        let font = kit.ty.body
        let rt = Runtime(state: PairState(text: "1:00", font: font), viewport: Vec2(600, 120), pixelScale: 2.0, systemDark: true) { s, _ in
            col().p(20)
                .child(row().child(RollingText<PairState>(key: "pair", value: s.text, font: s.font, kit: kit, store: store).build()))
                .child(row().child(Rune.text(s.text).font(s.font).key("plain")))
        }
        var now = 0.0
        _ = rt.frame(at: now)
        let before = glyphKeys(rt, key: "pair")
        let keptKeys = before.dropFirst().map(\.key) // ":", "0", "0"
        let startXs = try keptKeys.map { try #require(rt.element(byKey: $0)).rect[0] }

        rt.update { s, _ in s.text = "11:00" }
        _ = rt.frame(at: now)
        var trackedXs: [[Float]] = Array(repeating: [], count: keptKeys.count)
        for _ in 0..<240 {
            now += 1.0 / 120.0
            _ = rt.frame(at: now)
            for (idx, k) in keptKeys.enumerated() {
                if let e = rt.element(byKey: k) {
                    trackedXs[idx].append(e.rect[0])
                }
            }
        }
        for (idx, xs) in trackedXs.enumerated() {
            let finalX = try #require(xs.last)
            #expect(finalX > startXs[idx] + 1.0)
            for i in 1..<xs.count {
                #expect(xs[i] >= xs[i - 1] - 0.01)
            }
        }
        let rolled = try spanWidth(rt, key: "pair")
        let plain = try #require(rt.element(byKey: "plain")).rect[2]
        #expect(abs(rolled - plain) <= 0.25)
    }

    // 4. crates/rune-kit/tests/rolling_text.rs:224
    @Test("Reduced motion crossfades in place without travel (tests/rolling_text.rs:224)")
    func reducedMotionCrossfadesInPlace() throws {
        let key = "reduced"
        let (rt, _) = makeBasicRuntime(key: key, text: "0:30", reduced: true)
        let before = glyphKeys(rt, key: key)
        let rest = try #require(rt.element(byKey: before[2].key)).rect
        rt.update { s, _ in s.text = "0:29" }
        var now = 0.0
        _ = rt.frame(at: now)
        let frames = film(rt, keys: [before[2].key], seconds: 0.08, now: &now)
        let lastFrame = try #require(frames.last)
        let lastEntry = try #require(lastFrame.first)
        let (r, o) = try #require(lastEntry)
        #expect(r == rest)
        #expect(o > 0.0 && o < 1.0)
    }

    // 6. crates/rune-kit/tests/rolling_text.rs:304
    @Test("Digit changing soon after label fades in rolls in (tests/rolling_text.rs:304)")
    func digitChangingSoonAfterLabelFadesInRollsIn() throws {
        struct FadeState: Sendable {
            var label: String
            var shown: Bool
            var growth: Bool
            var explicitFade: Bool
        }
        let kit = Kit.neutral(dark: true)
        for (growth, explicitFade) in [(false, false), (true, false), (false, true)] {
            for wait in [0.5, 1.0, 2.0] {
                let store = RollingTextStore()
                let rt = Runtime(
                    state: FadeState(label: "Used 1", shown: false, growth: growth, explicitFade: explicitFade),
                    viewport: Vec2(400, 100),
                    pixelScale: 2.0,
                    systemDark: true
                ) { s, _ in
                    var r: El<FadeState> = row().key("trigger").h(28.0)
                    if s.shown {
                        var count = RollingText<FadeState>(key: "count", value: s.label, font: kit.ty.body, kit: kit, store: store).build()
                        if s.explicitFade {
                            count = count.transition(
                                Transition.opacity.springs(SpringPair(enter: Spring(duration: 0.22, bounce: 0.0), exit: Spring(duration: 0.18, bounce: 0.0)))
                            )
                        }
                        r = r.child(count)
                    }
                    r = r.child(el().key("chevron").size(14.0, 14.0))
                    if !s.growth {
                        return col().wFull().child(r)
                    }
                    return col().wFull().growth(GrowthSpec())
                        .child(col().key("r0").wFull().child(r.animateLayout()))
                }
                var now = 0.0
                _ = rt.frame(at: now)
                rt.update { s, _ in s.shown = true }
                for _ in 0..<Int(wait * 120.0) {
                    now += 1.0 / 120.0
                    _ = rt.frame(at: now)
                }
                let labelOp = try #require(rt.element(byKey: "count")).opacity
                #expect(labelOp > 0.99)
                rt.update { s, _ in s.label = "Used 2" }
                now += 1.0 / 120.0
                _ = rt.frame(at: now)
                let two = try #require(
                    rt.elements().first {
                        !$0.inert && !$0.exiting && $0.text == "2" && ($0.key?.hasPrefix("count#") ?? false)
                    }
                )
                #expect(two.opacity < 0.5)
                #expect(abs(two.rect[1] - two.target[1]) > 1.0)
            }
        }
    }

    // 7. crates/rune-kit/tests/rolling_text.rs:366
    @Test("Trailing label rolls new digits in their columns (tests/rolling_text.rs:366)")
    func trailingLabelRollsNewDigitsInTheirColumns() throws {
        struct TrailState: Sendable { var label: String; var trailing: Bool }
        let kit = Kit.neutral(dark: true)

        func measureDrift(trailing: Bool) throws -> (newDrift: Float, sDrift: Float) {
            let store = RollingTextStore()
            let rt = Runtime(
                state: TrailState(label: "9s", trailing: trailing),
                viewport: Vec2(400, 120),
                pixelScale: 2.0,
                systemDark: true
            ) { s, _ in
                let num = Double(s.label.dropLast()) ?? 0
                let label = RollingText<TrailState>(key: "t", value: s.label, font: kit.ty.mono, kit: kit, store: store)
                    .value(num)
                    .trailing(s.trailing)
                return row().w(200.0).p(20.0).justifyEnd().child(label.build())
            }
            var now = 0.0
            _ = rt.frame(at: now)
            rt.update { s, _ in s.label = "10s" }

            func elem(_ glyph: String) -> (x: Float, targetX: Float)? {
                rt.elements()
                    .first { !$0.inert && !$0.exiting && $0.text == glyph && ($0.key?.hasPrefix("t#") ?? false) }
                    .map { ($0.rect[0], $0.target[0]) }
            }

            let s0 = try #require(elem("s")).x
            var maxNew: Float = 0.0
            var maxS: Float = 0.0
            for _ in 0..<90 {
                now += 1.0 / 120.0
                _ = rt.frame(at: now)
                for d in ["1", "0"] {
                    let (at, rest) = try #require(elem(d))
                    maxNew = max(maxNew, abs(at - rest))
                }
                maxS = max(maxS, abs(try #require(elem("s")).x - s0))
            }
            return (maxNew, maxS)
        }

        let (newTrailing, sTrailing) = try measureDrift(trailing: true)
        #expect(newTrailing < 0.75)
        #expect(sTrailing < 0.5)
        let (newUntrailing, _) = try measureDrift(trailing: false)
        #expect(newUntrailing > 3.0)
    }

    // 8. crates/rune-kit/tests/rolling_text.rs:401
    @Test("Value under reduced motion swaps in place and mid-roll reversal retargets smoothly (tests/rolling_text.rs:401)")
    func valueUnderReducedMotionSwapsInPlaceAndReversalMidRollRetargets() throws {
        struct NumState: Sendable { var value: Double; var reduced: Bool }
        let kit = Kit.neutral(dark: true)

        func makeNumRuntime(_ value: Double, reduced: Bool) -> Runtime<NumState> {
            let store = RollingTextStore()
            let rt = Runtime(
                state: NumState(value: value, reduced: reduced),
                viewport: Vec2(400, 120),
                pixelScale: 2.0,
                systemDark: true
            ) { s, cx in
                cx.reducedMotion(s.reduced)
                let labelStr = s.value.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(s.value))" : "\(s.value)"
                return row().p(20.0).child(
                    RollingText<NumState>(key: "n", value: labelStr, font: kit.ty.mono, kit: kit, store: store)
                        .value(s.value)
                        .build()
                )
            }
            _ = rt.frame(at: 0.0)
            return rt
        }

        func glyph(_ rt: Runtime<NumState>, _ text: String) -> (rect: [Float], target: [Float])? {
            rt.elements()
                .first { !$0.inert && !$0.exiting && $0.text == text && ($0.key?.hasPrefix("n#") ?? false) }
                .map { ($0.rect, $0.target) }
        }

        let reducedRt = makeNumRuntime(9.0, reduced: true)
        reducedRt.update { s, _ in s.value = 8.0 }
        var now = 0.0
        for _ in 0..<4 {
            now += 1.0 / 120.0
            _ = reducedRt.frame(at: now)
            let g = try #require(glyph(reducedRt, "8"))
            #expect(g.rect[1] == g.target[1])
        }

        let revRt = makeNumRuntime(8.0, reduced: false)
        revRt.update { s, _ in s.value = 9.0 }
        now = 0.0
        for _ in 0..<8 {
            now += 1.0 / 120.0
            _ = revRt.frame(at: now)
        }
        revRt.update { s, _ in s.value = 8.0 }
        var last = glyph(revRt, "8")?.rect[1]
        var worst: Float = 0.0
        for _ in 0..<120 {
            now += 1.0 / 120.0
            _ = revRt.frame(at: now)
            let y = glyph(revRt, "8")?.rect[1]
            if let a = last, let b = y {
                worst = max(worst, abs(a - b))
            }
            last = y
        }
        let settled = try #require(glyph(revRt, "8"))
        #expect(worst < 4.0)
        #expect(settled.rect == settled.target)
    }

    // 9. crates/rune-kit/tests/rolling_text.rs:494
    @Test("Trailing label holds leaving and entering glyphs in their columns (tests/rolling_text.rs:494)")
    func trailingLabelHoldsLeavingAndEnteringGlyphsInTheirColumns() throws {
        struct SecState: Sendable { var text: String }
        let kit = Kit.neutral(dark: true)

        func makeSecondsRuntime(_ initial: String) -> Runtime<SecState> {
            let store = RollingTextStore()
            let rt = Runtime(
                state: SecState(text: initial),
                viewport: Vec2(400, 120),
                pixelScale: 2.0,
                systemDark: true
            ) { s, _ in
                let v = Double(s.text.dropLast()) ?? 0
                return row().w(200.0).p(20.0).justifyEnd().child(
                    RollingText<SecState>(key: "t", value: s.text, font: kit.ty.mono, kit: kit, store: store)
                        .value(v)
                        .trailing(true)
                        .build()
                )
            }
            _ = rt.frame(at: 0.0)
            return rt
        }

        func cell(_ rt: Runtime<SecState>, _ text: String, exiting: Bool) -> [Float]? {
            rt.elements()
                .first { $0.exiting == exiting && $0.text == text && ($0.key?.hasPrefix("t#") ?? false) }
                .map(\.rect)
        }

        func run(from: String, to: String, gone: [String], came: [String]) throws -> Float {
            let rt = makeSecondsRuntime(from)
            let starts = try gone.map { try #require(cell(rt, $0, exiting: false))[0] }
            rt.update { s, _ in s.text = to }
            var now = 0.0
            var worst: Float = 0.0
            for _ in 0..<90 {
                now += 1.0 / 120.0
                _ = rt.frame(at: now)
                for (g, x0) in zip(gone, starts) {
                    if let r = cell(rt, g, exiting: true) {
                        worst = max(worst, abs(r[0] - x0))
                    }
                }
                for c in came {
                    let e = try #require(
                        rt.elements().first { !$0.exiting && $0.text == c && ($0.key?.hasPrefix("t#") ?? false) }
                    )
                    worst = max(worst, abs(e.rect[0] - e.target[0]))
                }
            }
            return worst
        }

        let a = try run(from: "9s", to: "10s", gone: ["9"], came: ["1"])
        #expect(a < 0.75)

        let rt = makeSecondsRuntime("10s")
        let x0 = try #require(cell(rt, "0", exiting: false))[0]
        rt.update { s, _ in s.text = "11s" }
        var now = 0.0
        var drift: Float = 0.0
        for _ in 0..<90 {
            now += 1.0 / 120.0
            _ = rt.frame(at: now)
            if let r = cell(rt, "0", exiting: true) {
                drift = max(drift, abs(r[0] - x0))
            }
        }
        #expect(drift < 0.5)

        let c = try run(from: "19s", to: "100s", gone: ["1", "9"], came: [])
        #expect(c < 0.75)
    }

    // 10. crates/rune-kit/tests/rolling_text.rs:602
    @Test("Trailing labels in a sliding row never reverse (tests/rolling_text.rs:602)")
    func trailingLabelsInSlidingRowNeverReverse() throws {
        struct UsageState: Sendable {
            var cents: Int
            var tokens: Int
            var leads: Bool
        }
        let kit = Kit.neutral(dark: true)
        let spring = Spring(duration: 0.3, bounce: 0.0)
        let font = TextStyle(size: 12.0, weight: 440.0).lh(16.0).features("'tnum' 1")

        for leads in [true, false] {
            let store = RollingTextStore()
            let rt = Runtime(
                state: UsageState(cents: 42, tokens: 12_345, leads: leads),
                viewport: Vec2(400, 80),
                pixelScale: 2.0,
                systemDark: true
            ) { s, _ in
                let tokensText = s.tokens >= 1_000
                    ? String(format: "%.1fK", Double(s.tokens) / 1000.0)
                    : "\(s.tokens)"
                let centsText = String(format: "$%d.%02d", s.cents / 100, s.cents % 100)
                let usageAnim = s.leads ? LayoutAnim.widthLeads(spring) : LayoutAnim(spring: spring)
                let usage: El<UsageState> = row()
                    .key("usage")
                    .gap(6.0)
                    .itemsCenter()
                    .animateLayout(usageAnim)
                    .child(el().key("ring").size(14.0, 14.0))
                    .child(
                        RollingText<UsageState>(key: "ctx", value: tokensText, font: font, kit: kit, store: store)
                            .value(Double(s.tokens))
                            .spring(spring)
                            .trailing(true)
                            .build()
                    )
                    .child(
                        RollingText<UsageState>(key: "cost", value: centsText, font: font, kit: kit, store: store)
                            .value(Double(s.cents))
                            .spring(spring)
                            .trailing(true)
                            .build()
                    )

                let header: El<UsageState> = row()
                    .key("header")
                    .w(300.0)
                    .h(32.0)
                    .px(10.0)
                    .gap(8.0)
                    .itemsCenter()
                    .child(
                        row().itemsCenter().shrink(1.0).minW(0).child(
                            Rune.text("Refactor the session list so pinned rows keep their place")
                                .font(TextStyle(size: 13.0, weight: 530.0))
                                .ellipsis()
                                .shrink(1.0)
                                .minW(0)
                        )
                    )
                    .child(spacer())
                    .child(usage)
                return header
            }
            var now = 0.0
            _ = rt.frame(at: now)
            let before = try #require(rt.element(byKey: "cost")).rect[0]

            for (stepIdx, (centsDelta, tokensDelta, secs)) in [(7, 1_400, 0.8), (996, 98_000, 1.0)].enumerated() {
                rt.update { s, _ in
                    s.cents += centsDelta
                    s.tokens += tokensDelta
                }
                var paths: [(key: String, text: String, xs: [Float])] = []
                for _ in 0..<Int(secs * 120.0) {
                    now += 1.0 / 120.0
                    _ = rt.frame(at: now)
                    for e in rt.elements() {
                        guard let k = e.key, k.hasPrefix("cost#") || k.hasPrefix("ctx#") else { continue }
                        if let idx = paths.firstIndex(where: { $0.key == k }) {
                            paths[idx].xs.append(e.rect[0])
                        } else {
                            paths.append((k, e.text ?? "", [e.rect[0]]))
                        }
                    }
                }
                for (k, t, xs) in paths {
                    let w = wrongWay(xs)
                    #expect(w < 0.5, "leads=\(leads) step=\(stepIdx) \(k) (\(t)) went \(w)pt wrong way")
                }
            }
            let after = try #require(rt.element(byKey: "cost")).rect[0]
            #expect(after < before - 5.0)
        }
    }
}
