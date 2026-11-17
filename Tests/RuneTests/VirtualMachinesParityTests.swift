import Foundation
import RuneMotion
import Testing
@testable import Rune

@Suite("Virtual Machines Parity")
struct VirtualMachinesParityTests {

    // MARK: - el/virtual_list.rs parity (3 tests)

    @Test("gaps_surround_a_virtual_window_without_a_trailing_gap")
    func gapsSurroundAVirtualWindowWithoutATrailingGap() {
        var v = VirtualListBookkeeping()
        v.setEstimate(10)
        v.setGap(4)
        let keys = (0..<20).map { "row-\($0)" }
        _ = v.setKeys(keys, commit: 1, offset: nil)
        v.viewport = 20

        // prefix(end) includes the gap after row `end - 1` except after the final row;
        // rowEnd(end) never includes a trailing gap.
        #expect(v.prefix(0) == 0)
        #expect(v.rowEnd(0) == 0)
        #expect(v.prefix(2) == 28)
        #expect(v.rowEnd(2) == 24)
        #expect(v.prefix(20) == 20 * 10 + 19 * 4)
        #expect(v.rowEnd(20) == 20 * 10 + 19 * 4)

        // Pick a middle window so both `before` and `after` spacers are non-zero.
        v.select(offset: 120, pinned: false, budget: nil)
        #expect(v.range.lowerBound > 0)
        #expect(v.range.upperBound < keys.count)

        let windowExtent = v.rowEnd(v.range.upperBound) - v.prefix(v.range.lowerBound)
        let total = v.prefix(keys.count)
        // Before spacer includes gap before first mounted row; after spacer includes gap after
        // last mounted row; total height has no trailing gap after the final row.
        #expect(v.before == v.prefix(v.range.lowerBound))
        #expect(v.after == total - v.rowEnd(v.range.upperBound))
        #expect(v.before + windowExtent + v.after == total)
    }

    @Test("growth_gap_uses_the_vertical_axis_only")
    func growthGapUsesTheVerticalAxisOnly() {
        let columnEl: El<()> = col().rowGap(7).columnGap(19)
        #expect(virtualGapY(columnEl.layout) == 7)

        let rowEl: El<()> = row().rowGap(7).columnGap(19)
        #expect(virtualGapY(rowEl.layout) == 0)

        var wrappedCol = LayoutStyle(direction: .column)
        wrappedCol.displayMode = .flex
        wrappedCol.wrap = true
        wrappedCol.rowGap = 7
        wrappedCol.columnGap = 19
        #expect(virtualGapY(wrappedCol) == 0)
    }

    @Test("an_absolute_child_is_bounded_only_when_pinned_top_and_bottom")
    func anAbsoluteChildIsBoundedOnlyWhenPinnedTopAndBottom() {
        let parent: El<()> = el().h(100)
        let bound = virtualHeightBound(parent.layout, available: 500)
        #expect(bound == 100)

        let pinnedTopAndBottom: El<()> = el().pin(top: 10, right: 0, bottom: 20, left: 0)
        let pinnedTopOnly: El<()> = el().pin(top: 10)
        let pinnedBottomOnly: El<()> = el().pin(bottom: 20)
        let absoluteFixed: El<()> = el().absolute(x: 0, y: 0).h(45)
        let flowFixed: El<()> = el().h(30)
        let flowAuto: El<()> = el()

        let bounds = VirtualChildBounds.compute(
            style: parent.layout,
            scrolls: false,
            bound: bound,
            children: [
                pinnedTopAndBottom,
                pinnedTopOnly,
                pinnedBottomOnly,
                absoluteFixed,
                flowFixed,
                flowAuto,
            ]
        )

        #expect(bounds.of(pinnedTopAndBottom) == 70)
        #expect(bounds.of(pinnedTopOnly) == Float.infinity)
        #expect(bounds.of(pinnedBottomOnly) == Float.infinity)
        #expect(bounds.of(absoluteFixed) == Float.infinity)
        #expect(virtualHeightBound(absoluteFixed.layout, available: bounds.of(absoluteFixed)) == 45)
        #expect(virtualHeightBound(flowFixed.layout, available: bounds.of(flowFixed)) == 30)
        #expect(bounds.of(flowAuto) == 100)
    }

    // MARK: - runtime/virtual/fill_tests.rs parity (8 tests)

    private struct DevFillModel {
        enum State {
            case idle
            case filling(frames: UInt16, best: Int, resumes: UInt8)
            case waiting(attempt: UInt64, due: Double, best: Int, resumes: UInt8)
            case stalled
        }

        var state: State = .idle
        var nextAttempt: UInt64 = 1

        mutating func step(_ event: VirtualFillStateMachine.Event) -> VirtualFillStateMachine.Effect? {
            switch event {
            case .frame(let now, let wanted, let missing, let moved):
                if !wanted || missing == 0 {
                    state = .idle
                    return nil
                }
                switch state {
                case .idle:
                    state = .filling(frames: 1, best: missing, resumes: 0)
                    return .draw
                case .filling(var frames, var best, var resumes):
                    if moved {
                        state = .filling(frames: 1, best: missing, resumes: 0)
                        return .draw
                    }
                    if missing < best {
                        best = missing
                        resumes = 0
                    }
                    if frames >= VirtualFillStateMachine.fillFrames {
                        let attempt = nextAttempt
                        nextAttempt &+= 1
                        let due = now + VirtualFillStateMachine.resumeWait
                        state = .waiting(attempt: attempt, due: due, best: best, resumes: resumes)
                        return .wakeAt(due)
                    }
                    frames &+= 1
                    state = .filling(frames: frames, best: best, resumes: resumes)
                    return .draw
                case .waiting(_, _, _, _):
                    if moved {
                        state = .filling(frames: 1, best: missing, resumes: 0)
                        return .draw
                    }
                    return nil
                case .stalled:
                    if moved {
                        state = .filling(frames: 1, best: missing, resumes: 0)
                        return .draw
                    }
                    return nil
                }

            case .due(let attempt, _):
                guard case .waiting(let activeAttempt, _, let best, let resumes) = state,
                      activeAttempt == attempt else {
                    return nil
                }
                if resumes >= VirtualFillStateMachine.resumeLimit {
                    state = .stalled
                    return nil
                }
                state = .filling(frames: 1, best: best, resumes: resumes &+ 1)
                return .draw
            }
        }
    }

    @Test("every_run_of_frames_draws_what_dev_draws")
    func everyRunOfFramesDrawsWhatDevDraws() {
        for length in 1...14 {
            // Exhaustively walk bitmasks representing `(wanted && missing > 0)` across 1...14 frames,
            // plus periodic `moved` / settled pulses derived cleanly up to 14 frames.
            let maskLimit = 1 << length
            for mask in 0..<maskLimit {
                var machine = VirtualFillStateMachine()
                var dev = DevFillModel()
                var t: Double = 0
                for bit in 0..<length {
                    let active = ((mask >> bit) & 1) == 1
                    let moved = active && (bit == 6 || (bit == 13 && (mask & 1) == 0))
                    let effect = machine.step(.frame(now: t, wanted: active, missing: active ? 4 : 0, moved: moved))
                    let devEffect = dev.step(.frame(now: t, wanted: active, missing: active ? 4 : 0, moved: moved))
                    #expect(effect == devEffect)
                    if case .wakeAt(let due) = effect, let wake = machine.armedWake {
                        let nextT = due
                        let dueEff = machine.step(.due(attempt: wake.attempt, now: nextT))
                        let devDueEff = dev.step(.due(attempt: wake.attempt, now: nextT))
                        #expect(dueEff == devDueEff)
                    }
                    t += 1.0 / 60.0
                }
            }
        }
    }

    @Test("a_settled_frame_forgets_the_run_and_the_bound_stops_it")
    func aSettledFrameForgetsTheRunAndTheBoundStopsIt() {
        var machine = VirtualFillStateMachine()
        var t: Double = 0

        for _ in 0..<8 {
            #expect(machine.step(.frame(now: t, wanted: true, missing: 5, moved: false)) == .draw)
            t += 1.0 / 60.0
        }

        // Settling clears the bounded run back to idle.
        #expect(machine.step(.frame(now: t, wanted: false, missing: 0, moved: false)) == nil)
        #expect(machine.phase == .idle)
        t += 1.0 / 60.0

        // Next run gets a full `fillFrames` budget before hitting the bound.
        for _ in 0..<Int(VirtualFillStateMachine.fillFrames) {
            #expect(machine.step(.frame(now: t, wanted: true, missing: 5, moved: false)) == .draw)
            t += 1.0 / 60.0
        }

        #expect(machine.atBound)

        let bounded = machine.step(.frame(now: t, wanted: true, missing: 5, moved: false))
        guard case .wakeAt = bounded else {
            Issue.record("Expected .wakeAt once fillFrames is exceeded, got \(String(describing: bounded))")
            return
        }
        if case .waiting = machine.phase {
        } else {
            Issue.record("Expected .waiting phase after hitting bound, got \(machine.phase)")
        }
    }

    @Test("the_bound_waits_and_the_wake_resumes_the_fill")
    func theBoundWaitsAndTheWakeResumesTheFill() {
        var machine = VirtualFillStateMachine()
        var t: Double = 1.0

        for _ in 0..<Int(VirtualFillStateMachine.fillFrames) {
            #expect(machine.step(.frame(now: t, wanted: true, missing: 3, moved: false)) == .draw)
            t += 1.0 / 60.0
        }

        let eff = machine.step(.frame(now: t, wanted: true, missing: 3, moved: false))
        guard case .wakeAt(let due) = eff, let armed = machine.armedWake else {
            Issue.record("Expected armed wake deadline, got \(String(describing: eff))")
            return
        }
        #expect(due == t + VirtualFillStateMachine.resumeWait)
        #expect(!machine.resuming(at: t))
        #expect(machine.resuming(at: due))

        // While waiting without a due fire or viewport move, extra frames stay silent.
        #expect(machine.step(.frame(now: t + 0.01, wanted: true, missing: 3, moved: false)) == nil)

        // Firing the due deadline resumes filling.
        #expect(machine.step(.due(attempt: armed.attempt, now: due)) == .draw)
        #expect(machine.isFilling)
    }

    @Test("a_starved_fill_stops_after_its_resumes_without_progress")
    func aStarvedFillStopsAfterItsResumesWithoutProgress() {
        var machine = VirtualFillStateMachine()
        var t: Double = 0

        for resume in 0...Int(VirtualFillStateMachine.resumeLimit) {
            let framesThisRound = resume == 0 ? Int(VirtualFillStateMachine.fillFrames) : Int(VirtualFillStateMachine.fillFrames) - 1
            for _ in 0..<framesThisRound {
                #expect(machine.step(.frame(now: t, wanted: true, missing: 10, moved: false)) == .draw)
                t += 1.0 / 60.0
            }
            let bound = machine.step(.frame(now: t, wanted: true, missing: 10, moved: false))
            if resume < Int(VirtualFillStateMachine.resumeLimit) {
                guard case .wakeAt(let due) = bound, let wake = machine.armedWake else {
                    Issue.record("Expected .wakeAt at end of round \(resume), got \(String(describing: bound))")
                    return
                }
                t = due
                let afterDue = machine.step(.due(attempt: wake.attempt, now: t))
                #expect(afterDue == .draw)
                t += 1.0 / 60.0
            } else {
                #expect(bound == nil)
                #expect(machine.phase == .stalled)
            }
        }
    }

    @Test("stale_deadlines_never_restart_the_fill")
    func staleDeadlinesNeverRestartTheFill() {
        var machine = VirtualFillStateMachine()
        var t: Double = 0

        for _ in 0..<Int(VirtualFillStateMachine.fillFrames) {
            _ = machine.step(.frame(now: t, wanted: true, missing: 4, moved: false))
            t += 1.0 / 60.0
        }
        guard case .wakeAt(let firstDue) = machine.step(.frame(now: t, wanted: true, missing: 4, moved: false)),
              let firstWake = machine.armedWake else {
            Issue.record("Expected initial wake")
            return
        }

        // Settling invalidates `firstWake.attempt`.
        #expect(machine.step(.frame(now: firstDue, wanted: false, missing: 0, moved: false)) == nil)
        #expect(machine.step(.due(attempt: firstWake.attempt, now: firstDue + 0.01)) == nil)
        #expect(machine.phase == .idle)

        // Start a second wait and verify the first attempt cannot fire it.
        var t2 = firstDue + 0.1
        for _ in 0..<Int(VirtualFillStateMachine.fillFrames) {
            _ = machine.step(.frame(now: t2, wanted: true, missing: 4, moved: false))
            t2 += 1.0 / 60.0
        }
        _ = machine.step(.frame(now: t2, wanted: true, missing: 4, moved: false))
        guard let secondWake = machine.armedWake else {
            Issue.record("Expected second wake")
            return
        }
        #expect(secondWake.attempt != firstWake.attempt)
        #expect(machine.step(.due(attempt: firstWake.attempt, now: secondWake.due)) == nil)
        #expect(machine.step(.due(attempt: secondWake.attempt, now: secondWake.due)) == .draw)
    }

    @Test("a_wake_after_the_list_is_gone_draws_nothing")
    func aWakeAfterTheListIsGoneDrawsNothing() {
        var machine = VirtualFillStateMachine()
        var t: Double = 0
        for _ in 0..<Int(VirtualFillStateMachine.fillFrames) {
            _ = machine.step(.frame(now: t, wanted: true, missing: 2, moved: false))
            t += 1.0 / 60.0
        }
        _ = machine.step(.frame(now: t, wanted: true, missing: 2, moved: false))
        guard let wake = machine.armedWake else {
            Issue.record("Expected wake before list disappears")
            return
        }

        // List unmounts / stops wanting fill before the wake arrives.
        #expect(machine.step(.frame(now: t + 0.01, wanted: false, missing: 0, moved: false)) == nil)
        #expect(machine.step(.due(attempt: wake.attempt, now: wake.due)) == nil)
        #expect(machine.phase == .idle)
    }

    @Test("a_resume_that_finds_progress_gets_a_fresh_bound")
    func aResumeThatFindsProgressGetsAFreshBound() {
        var machine = VirtualFillStateMachine()
        var t: Double = 0
        var missing = 20

        // Exhaust all resumes while strictly decreasing `missing` every round; it must never stall
        // because progress resets the resume budget.
        for round in 0..<(Int(VirtualFillStateMachine.resumeLimit) + 3) {
            let frames = round == 0 ? Int(VirtualFillStateMachine.fillFrames) : Int(VirtualFillStateMachine.fillFrames) - 1
            for _ in 0..<frames {
                #expect(machine.step(.frame(now: t, wanted: true, missing: missing, moved: false)) == .draw)
                t += 1.0 / 60.0
            }
            guard case .wakeAt(let due) = machine.step(.frame(now: t, wanted: true, missing: missing, moved: false)),
                  let wake = machine.armedWake else {
                Issue.record("Expected wake at round \(round)")
                return
            }
            t = due
            #expect(machine.step(.due(attempt: wake.attempt, now: t)) == .draw)
            missing -= 1
            t += 1.0 / 60.0
        }
        #expect(machine.phase != .stalled)
    }

    @Test("a_moved_viewport_starts_the_fill_again")
    func aMovedViewportStartsTheFillAgain() {
        var machine = VirtualFillStateMachine()
        var t: Double = 0

        // Drive the machine all the way to `.stalled`.
        for resume in 0...Int(VirtualFillStateMachine.resumeLimit) {
            let frames = resume == 0 ? Int(VirtualFillStateMachine.fillFrames) : Int(VirtualFillStateMachine.fillFrames) - 1
            for _ in 0..<frames {
                _ = machine.step(.frame(now: t, wanted: true, missing: 5, moved: false))
                t += 1.0 / 60.0
            }
            _ = machine.step(.frame(now: t, wanted: true, missing: 5, moved: false))
            if let wake = machine.armedWake {
                t = wake.due
                _ = machine.step(.due(attempt: wake.attempt, now: t))
                t += 1.0 / 60.0
            }
        }
        #expect(machine.phase == .stalled)
        #expect(machine.step(.frame(now: t, wanted: true, missing: 5, moved: false)) == nil)

        // Scrolling moves the viewport and immediately restarts filling.
        t += 1.0 / 60.0
        #expect(machine.step(.frame(now: t, wanted: true, missing: 5, moved: true)) == .draw)
        #expect(machine.isFilling)
    }

    // MARK: - runtime/virtual/pins_tests.rs parity (7 tests)

    private enum PinSourceKind: Equatable {
        case stored
        case rebuild
    }

    private struct PinTextEntry: Equatable {
        var rowKey: String
        var content: String
    }

    private struct DevPinsModel {
        var rows: [String] = []
        var texts: [PinTextEntry] = []
        var source: PinSourceKind? = nil

        mutating func applyClear() {
            rows.removeAll(keepingCapacity: true)
            texts.removeAll(keepingCapacity: true)
        }

        mutating func applySelect(_ anchor: String?, _ focus: String?) {
            rows.removeAll(keepingCapacity: true)
            if let anchor { rows.append(anchor) }
            if let focus, !rows.contains(focus) { rows.append(focus) }
            let keep = Set(rows)
            texts.removeAll { !keep.contains($0.rowKey) }
        }

        mutating func applyPin(key: String, text: String) {
            let already = texts.contains { $0.rowKey == key }
            if !rows.contains(key) { rows.append(key) }
            if !already {
                texts.append(PinTextEntry(rowKey: key, content: text))
            }
        }

        mutating func commitStored(stopAfterFirst: Bool = false) {
            texts.removeAll(keepingCapacity: true)
            source = .stored
            for (i, key) in ["a", "b", "c"].enumerated() {
                if stopAfterFirst && i == 1 { return }
                if rows.contains(key) {
                    texts.append(PinTextEntry(rowKey: key, content: "row-\(key)"))
                }
            }
        }

        mutating func commitIndexed(focused: String?, stopAfterFirst: Bool = false, touchSource: Bool = true) {
            texts.removeAll(keepingCapacity: true)
            var steps: [String] = focused.map { [$0] } ?? []
            for r in rows where r != focused {
                steps.append(r)
            }
            for (step, key) in steps.enumerated() {
                if stopAfterFirst && step == 1 { return }
                if rows.contains(key) {
                    texts.append(PinTextEntry(rowKey: key, content: "row-\(key)"))
                }
            }
            if touchSource {
                source = .rebuild
            }
        }
    }

    private enum PinFuzzEv: CaseIterable {
        case clear
        case selectNone
        case selectA
        case selectAB
        case pinA
        case pinB
        case commitIndexed
        case commitIndexedFocusedB
        case commitStored
        case commitRemount
        case commitPanicIndexed
        case commitFallbackHere
        case commitFallbackEarlier

        func apply(
            to pins: inout VirtualPins,
            dev: inout DevPinsModel,
            collected: [String: ([VirtualOffscreenText], [VirtualSelectionCopyProvider])],
            rebuildSource: VirtualPins.Source
        ) {
            func runCommit(stored: Bool, indexed: Bool, focused: String?, stopAtOne: Bool) {
                pins.clearTexts()
                if stored {
                    pins.setSource(.stored)
                }
                let steps: [String]
                if stored {
                    steps = ["a", "b", "c"]
                } else {
                    var s: [String] = focused.map { [$0] } ?? []
                    s.append(contentsOf: pins.rows.filter { $0 != focused })
                    steps = s
                }
                for (step, key) in steps.enumerated() {
                    if stopAtOne && step == 1 {
                        return
                    }
                    if pins.rows.contains(key), let (t, p) = collected[key] {
                        _ = pins.withTextBuffers { texts, providers in
                            texts.append(contentsOf: t)
                            providers.append(contentsOf: p)
                        }
                    }
                }
                if indexed {
                    pins.setSource(rebuildSource)
                }
            }

            switch self {
            case .clear:
                pins.sync(.clear)
                dev.applyClear()
            case .selectNone:
                pins.sync(.select(anchor: nil, focus: nil))
                dev.applySelect(nil, nil)
            case .selectA:
                pins.sync(.select(anchor: "a", focus: nil))
                dev.applySelect("a", nil)
            case .selectAB:
                pins.sync(.select(anchor: "a", focus: "b"))
                dev.applySelect("a", "b")
            case .pinA:
                let (t, p) = pins.hasTextRow("a") ? ([], []) : collected["a"]!
                pins.sync(.pin(key: "a", texts: t, providers: p))
                dev.applyPin(key: "a", text: "row-a")
            case .pinB:
                let (t, p) = pins.hasTextRow("b") ? ([], []) : collected["b"]!
                pins.sync(.pin(key: "b", texts: t, providers: p))
                dev.applyPin(key: "b", text: "row-b")
            case .commitIndexed:
                runCommit(stored: false, indexed: true, focused: nil, stopAtOne: false)
                dev.commitIndexed(focused: nil)
            case .commitIndexedFocusedB:
                runCommit(stored: false, indexed: true, focused: "b", stopAtOne: false)
                dev.commitIndexed(focused: "b")
            case .commitStored:
                runCommit(stored: true, indexed: false, focused: nil, stopAtOne: false)
                dev.commitStored()
            case .commitRemount:
                runCommit(stored: false, indexed: false, focused: nil, stopAtOne: false)
                dev.commitIndexed(focused: nil, touchSource: false)
            case .commitPanicIndexed:
                runCommit(stored: false, indexed: true, focused: "a", stopAtOne: true)
                dev.commitIndexed(focused: "a", stopAfterFirst: true)
            case .commitFallbackHere:
                runCommit(stored: false, indexed: false, focused: "b", stopAtOne: false)
                dev.commitIndexed(focused: "b", touchSource: false)
            case .commitFallbackEarlier:
                pins.clearTexts()
                dev.texts.removeAll(keepingCapacity: true)
            }
        }
    }

    @Test("every_order_of_pins_commits_panics_and_fallbacks_keeps_what_dev_keeps")
    func everyOrderOfPinsCommitsPanicsAndFallbacksKeepsWhatDevKeeps() {
        let rowEls: [String: El<()>] = [
            "a": el().key("a").child(text("row-a").selectable()),
            "b": el().key("b").child(text("row-b").selectable()),
            "c": el().key("c").child(text("row-c").selectable()),
        ]
        let indices = ["a": 0, "b": 1, "c": 2]
        var collected: [String: ([VirtualOffscreenText], [VirtualSelectionCopyProvider])] = [:]
        for (k, rowEl) in rowEls {
            var t: [VirtualOffscreenText] = []
            var p: [VirtualSelectionCopyProvider] = []
            VirtualSelectionCollector.collectVirtualRowSelection(
                rowEl: rowEl,
                listPath: "list",
                rowKey: k,
                rowIndex: indices[k]!,
                listGroup: nil,
                listInert: false,
                texts: &t,
                copyProviders: &p
            )
            collected[k] = (t, p)
        }
        let rebuildSource = VirtualPins.Source.rebuild(.empty)
        let events = PinFuzzEv.allCases

        func sourceKind(_ source: VirtualPins.Source?) -> PinSourceKind? {
            switch source {
            case nil: return nil
            case .stored: return .stored
            case .rebuild: return .rebuild
            }
        }

        func walk(depth: Int, maxDepth: Int, pins: VirtualPins, dev: DevPinsModel) {
            for ev in events {
                var nextPins = pins
                var nextDev = dev
                ev.apply(
                    to: &nextPins,
                    dev: &nextDev,
                    collected: collected,
                    rebuildSource: rebuildSource
                )
                #expect(!nextPins.isNone)
                #expect(nextPins.rows == nextDev.rows)
                let kept = nextPins.texts.map { PinTextEntry(rowKey: $0.rowKey, content: $0.content) }
                #expect(kept == nextDev.texts)
                #expect(sourceKind(nextPins.source) == nextDev.source)
                if depth < maxDepth {
                    walk(depth: depth + 1, maxDepth: maxDepth, pins: nextPins, dev: nextDev)
                }
            }
        }

        var initialPins = VirtualPins()
        var initialDev = DevPinsModel()
        PinFuzzEv.commitStored.apply(
            to: &initialPins,
            dev: &initialDev,
            collected: collected,
            rebuildSource: rebuildSource
        )
        walk(depth: 1, maxDepth: 4, pins: initialPins, dev: initialDev)
    }

    @Test("a_stored_commit_orders_texts_by_child_while_an_indexed_one_builds_the_focused_row_first")
    func aStoredCommitOrdersTextsByChildWhileAnIndexedOneBuildsTheFocusedRowFirst() {
        var buildTrace: [Int] = []
        let rebuild = VirtualPins.RebuildSource { idx, listPath, rowKey, groupPath, inert in
            buildTrace.append(idx)
            let row: El<()> = el().key(rowKey).child(text("item-\(idx)").selectable())
            var t: [VirtualOffscreenText] = []
            var p: [VirtualSelectionCopyProvider] = []
            VirtualSelectionCollector.collectVirtualRowSelection(
                rowEl: row,
                listPath: listPath,
                rowKey: rowKey,
                rowIndex: idx,
                listGroup: groupPath,
                listInert: inert,
                texts: &t,
                copyProviders: &p
            )
            return (t, p, false)
        }

        // Indexed remount with focus on row 8, pins on [2, 8] -> focused row (8) is built FIRST.
        var indexedBook = VirtualListBookkeeping()
        _ = indexedBook.setKeys((0..<12).map { "r-\($0)" }, commit: 1, offset: nil)
        var indexedPins = VirtualPins()
        indexedPins.setSource(.rebuild(rebuild))
        indexedPins.sync(.select(anchor: "r-2", focus: "r-8"))

        var hosts: [String: VirtualListSelectionHost] = [
            "list": VirtualListSelectionHost(
                listPath: "list",
                bookkeeping: indexedBook,
                selection: VirtualPinnedSelection(pins: indexedPins)
            )
        ]
        let plan = VirtualRemountPlanInput(
            listPath: "list",
            newRange: 10..<12,
            mountedKeys: ["r-10", "r-11"],
            focusedRowKey: "r-8"
        )
        let fellBack = VirtualSelectionCollector.remountVirtualPins(plans: [plan], lists: &hosts)
        #expect(!fellBack)
        #expect(buildTrace == [8, 2])
        #expect(hosts["list"]?.selection.pins.texts.map(\.rowKey) == ["r-8", "r-2"])

        // Stored commit orders offscreen texts in child index order even when anchor > focus.
        var storedPins = VirtualPins()
        storedPins.setSource(.stored)
        storedPins.sync(.select(anchor: "r-8", focus: "r-2"))
        let pinnedIndices = storedPins.rows.compactMap { indexedBook.indexOf($0) }.sorted()
        #expect(pinnedIndices == [2, 8])
        for i in pinnedIndices {
            let key = indexedBook.keys[i]
            VirtualSelectionCollector.collectRowIntoPins(
                pins: &storedPins,
                rowEl: (el() as El<()>).key(key).child(text("item-\(i)").selectable()),
                listPath: "list",
                rowKey: key,
                rowIndex: i,
                listGroup: nil,
                listInert: false
            )
        }
        #expect(storedPins.texts.map(\.rowKey) == ["r-2", "r-8"])
    }

    @Test("a_panicking_builder_keeps_the_pins_collected_before_it")
    func aPanickingBuilderKeepsThePinsCollectedBeforeIt() {
        enum SimulatedPanic: Error { case aborted }

        var pins = VirtualPins()
        pins.setSource(.stored)
        pins.sync(.select(anchor: "r-0", focus: "r-1"))
        VirtualSelectionCollector.collectRowIntoPins(
            pins: &pins,
            rowEl: (el() as El<()>).key("r-0").child(text("first").selectable()),
            listPath: "list",
            rowKey: "r-0",
            rowIndex: 0,
            listGroup: nil,
            listInert: false
        )
        VirtualSelectionCollector.collectRowIntoPins(
            pins: &pins,
            rowEl: (el() as El<()>).key("r-1").child(text("second").selectable()),
            listPath: "list",
            rowKey: "r-1",
            rowIndex: 1,
            listGroup: nil,
            listInert: false
        )

        pins.clearTexts()
        do {
            for idx in 0..<2 {
                if idx == 1 { throw SimulatedPanic.aborted }
                let row: El<()> = el().key("r-\(idx)").child(text("rebuilt-\(idx)").selectable())
                var texts: [VirtualOffscreenText] = []
                var providers: [VirtualSelectionCopyProvider] = []
                VirtualSelectionCollector.collectVirtualRowSelection(
                    rowEl: row,
                    listPath: "list",
                    rowKey: "r-\(idx)",
                    rowIndex: idx,
                    listGroup: nil,
                    listInert: false,
                    texts: &texts,
                    copyProviders: &providers
                )
                _ = pins.withTextBuffers { dstTexts, dstProviders in
                    dstTexts.append(contentsOf: texts)
                    dstProviders.append(contentsOf: providers)
                }
            }
        } catch {}

        #expect(pins.rows == ["r-0", "r-1"])
        #expect(pins.texts.map(\.rowKey) == ["r-0"])
        #expect(pins.texts.map(\.content) == ["rebuilt-0"])
    }

    @Test("a_commit_fallback_and_source_change_keep_the_texts_allocation")
    func aCommitFallbackAndSourceChangeKeepTheTextsAllocation() {
        var pins = VirtualPins()
        pins.setSource(.stored)
        for i in 0..<8 {
            let key = "k-\(i)"
            pins.sync(.select(anchor: "k-0", focus: key))
            VirtualSelectionCollector.collectRowIntoPins(
                pins: &pins,
                rowEl: (el() as El<()>).key(key).child(text("text-\(i)").selectable()),
                listPath: "list",
                rowKey: key,
                rowIndex: i,
                listGroup: nil,
                listInert: false
            )
        }
        let initialTextsCap = pins.textsCapacity
        let initialProvidersCap = pins.providersCapacity
        #expect(initialTextsCap >= pins.texts.count)

        pins.clearTexts()
        pins.setSource(.rebuild(.empty))
        pins.setSource(.stored)

        #expect(pins.texts.isEmpty)
        #expect(pins.textsCapacity == initialTextsCap)
        #expect(pins.providersCapacity == initialProvidersCap)
    }

    @Test("a_fallback_in_this_list_keeps_all_its_pins_and_one_before_it_keeps_none")
    func aFallbackInThisListKeepsAllItsPinsAndOneBeforeItKeepsNone() {
        let makeHost: (String, Bool) -> VirtualListSelectionHost = { name, hasNestedVirtualAt150 in
            var book = VirtualListBookkeeping()
            _ = book.setKeys((0..<200).map { "\(name)-\($0)" }, commit: 1, offset: nil)
            var pins = VirtualPins()
            pins.setSource(.rebuild(.fromElBuilder { (idx: Int) -> El<()> in
                if hasNestedVirtualAt150 && idx >= 150 {
                    return el().child(col().virtualize())
                }
                return el().child(text("\(name) row \(idx)").selectable())
            }))
            pins.sync(.select(anchor: "\(name)-50", focus: "\(name)-60"))
            return VirtualListSelectionHost(
                listPath: name,
                bookkeeping: book,
                selection: VirtualPinnedSelection(pins: pins)
            )
        }

        // Case 1: Fallback happens in the SECOND list ("two"): "two" built all its offscreen pins
        // before scanning entering rows, so both "one" and "two" keep their offscreen pins.
        var hostsSecondFails: [String: VirtualListSelectionHost] = [
            "one": makeHost("one", false),
            "two": makeHost("two", true),
        ]
        let plansSecondFails = [
            VirtualRemountPlanInput(listPath: "one", newRange: 150..<155, mountedKeys: [], focusedRowKey: nil),
            VirtualRemountPlanInput(listPath: "two", newRange: 150..<155, mountedKeys: [], focusedRowKey: nil),
        ]
        #expect(VirtualSelectionCollector.remountVirtualPins(plans: plansSecondFails, lists: &hostsSecondFails) == true)
        #expect(hostsSecondFails["one"]?.selection.pins.texts.map(\.rowKey) == ["one-50", "one-60"])
        #expect(hostsSecondFails["two"]?.selection.pins.texts.map(\.rowKey) == ["two-50", "two-60"])

        // Case 2: Fallback happens in the FIRST list ("one"): "one" keeps all its pins,
        // while "two" (cleared in place up front, never reached) keeps none.
        var hostsFirstFails: [String: VirtualListSelectionHost] = [
            "one": makeHost("one", true),
            "two": makeHost("two", false),
        ]
        // Seed "two" with stale pre-commit text so we verify it gets cleared in place.
        VirtualSelectionCollector.collectRowIntoPins(
            pins: &hostsFirstFails["two"]!.selection.pins,
            rowEl: (el() as El<()>).key("two-50").child(text("stale").selectable()),
            listPath: "two",
            rowKey: "two-50",
            rowIndex: 50,
            listGroup: nil,
            listInert: false
        )
        let capBefore = hostsFirstFails["two"]!.selection.pins.textsCapacity
        let plansFirstFails = [
            VirtualRemountPlanInput(listPath: "one", newRange: 150..<155, mountedKeys: [], focusedRowKey: nil),
            VirtualRemountPlanInput(listPath: "two", newRange: 0..<5, mountedKeys: [], focusedRowKey: nil),
        ]
        #expect(VirtualSelectionCollector.remountVirtualPins(plans: plansFirstFails, lists: &hostsFirstFails) == true)
        #expect(hostsFirstFails["one"]?.selection.pins.texts.map(\.rowKey) == ["one-50", "one-60"])
        #expect(hostsFirstFails["two"]?.selection.pins.texts.isEmpty == true)
        #expect(hostsFirstFails["two"]!.selection.pins.textsCapacity >= capBefore)
    }

    private func makeTwoListRemountFixture(
        oneFallsBack: Bool,
        twoFallsBack: Bool
    ) -> (hosts: [String: VirtualListSelectionHost], nodes: [SelectableNodeSnapshot]) {
        let makeHost: (String, String, Bool) -> VirtualListSelectionHost = { listPath, prefix, fallsBack in
            var book = VirtualListBookkeeping()
            book.setEstimate(20)
            book.viewport = 5
            _ = book.setKeys((0..<400).map { "\(prefix)-\($0)" }, commit: 1, offset: nil)
            book.select(offset: 0, pinned: false, budget: nil)
            var pins = VirtualPins()
            pins.setSource(.rebuild(.fromElBuilder { (idx: Int) -> El<()> in
                if fallsBack && idx >= 150 {
                    return el().child(col().virtualize())
                }
                return el().child(text("\(prefix) row \(idx)").selectable())
            }))
            return VirtualListSelectionHost(
                listPath: listPath,
                bookkeeping: book,
                selection: VirtualPinnedSelection(pins: pins)
            )
        }

        let hosts: [String: VirtualListSelectionHost] = [
            "root/one": makeHost("root/one", "one", oneFallsBack),
            "root/two": makeHost("root/two", "two", twoFallsBack),
        ]
        let nodes = [
            SelectableNodeSnapshot(path: "root", key: "root", parentPath: nil),
            SelectableNodeSnapshot(path: "root/one", key: "one", parentPath: "root"),
            SelectableNodeSnapshot(path: "root/one/one-0", key: "one-0", parentPath: "root/one"),
            SelectableNodeSnapshot(
                path: "root/one/one-0/text",
                parentPath: "root/one/one-0",
                isSelectable: true,
                text: "one row 0"
            ),
            SelectableNodeSnapshot(path: "root/two", key: "two", parentPath: "root"),
            SelectableNodeSnapshot(path: "root/two/two-0", key: "two-0", parentPath: "root/two"),
            SelectableNodeSnapshot(
                path: "root/two/two-0/text",
                parentPath: "root/two/two-0",
                isSelectable: true,
                text: "two row 0"
            ),
        ]
        return (hosts, nodes)
    }

    @Test("the_real_remount_collects_this_lists_pins_before_it_falls_back")
    func theRealRemountCollectsThisListsPinsBeforeItFallsBack() {
        var (hosts, nodes) = makeTwoListRemountFixture(oneFallsBack: false, twoFallsBack: true)
        var phase = SelectionPhase.empty
        var anchorState = VirtualSelectionAnchorState()

        // Pin unmounted row 50 in "root/two" via the real unmounted selection request path.
        let selected = VirtualSelectionCollector.selectUnmountedRequest(
            selector: "two-50",
            range: nil,
            phase: &phase,
            anchorState: &anchorState,
            nodes: nodes,
            lists: &hosts
        )
        #expect(selected)
        #expect(hosts["root/two"]?.selection.pins.rows == ["two-50"])

        // Scrolling "root/two" to 150..<160 hits the nested virtual row on entry and falls back,
        // AFTER rebuilding "root/two"'s pinned row "two-50".
        let plans = [
            VirtualRemountPlanInput(listPath: "root/one", newRange: 0..<10, mountedKeys: ["one-0"], focusedRowKey: nil),
            VirtualRemountPlanInput(listPath: "root/two", newRange: 150..<160, mountedKeys: [], focusedRowKey: nil),
        ]
        let fellBack = VirtualSelectionCollector.remountVirtualPins(plans: plans, lists: &hosts)
        #expect(fellBack)
        #expect(hosts["root/two"]?.selection.pins.texts.map(\.rowKey) == ["two-50"])
        #expect(hosts["root/two"]?.selection.pins.texts.first?.content == "two row 50")
    }

    @Test("the_real_remount_clears_later_lists_in_place_when_an_earlier_one_falls_back")
    func theRealRemountClearsLaterListsInPlaceWhenAnEarlierOneFallsBack() {
        var (hosts, nodes) = makeTwoListRemountFixture(oneFallsBack: true, twoFallsBack: false)
        var phase = SelectionPhase.empty
        var anchorState = VirtualSelectionAnchorState()

        let selected = VirtualSelectionCollector.selectUnmountedRequest(
            selector: "two-50",
            range: nil,
            phase: &phase,
            anchorState: &anchorState,
            nodes: nodes,
            lists: &hosts
        )
        #expect(selected)
        let capBefore = hosts["root/two"]!.selection.pins.textsCapacity
        #expect(!hosts["root/two"]!.selection.pins.texts.isEmpty)

        // Scrolling "root/one" to 150..<160 falls back before "root/two" is reached; "root/two"
        // was cleared in place (retaining allocation) and has zero texts left.
        let plans = [
            VirtualRemountPlanInput(listPath: "root/one", newRange: 150..<160, mountedKeys: [], focusedRowKey: nil),
            VirtualRemountPlanInput(listPath: "root/two", newRange: 0..<10, mountedKeys: ["two-0"], focusedRowKey: nil),
        ]
        let fellBack = VirtualSelectionCollector.remountVirtualPins(plans: plans, lists: &hosts)
        #expect(fellBack)
        #expect(hosts["root/two"]?.selection.pins.texts.isEmpty == true)
        #expect(hosts["root/two"]!.selection.pins.textsCapacity >= capBefore)
    }

    // MARK: - VirtualRowReorder & VirtualSelectionCollector coverage

    @Test("reorder_measures_only_rows_that_changed_order")
    func reorderMeasuresOnlyRowsThatChangedOrder() {
        let a = NodeId.hash("row/a")
        let b = NodeId.hash("row/b")
        let c = NodeId.hash("row/c")
        let d = NodeId.hash("row/d")
        let heights: [NodeId: Float] = [a: 20, b: 30, c: 40, d: 15]

        var reorder = VirtualRowReorder()

        // Non-animated commits report no jumps even when reordered.
        reorder.measure(animates: false, old: [a, b, c], new: [c, a, b], gap: 5) { heights[$0] }
        #expect(reorder.jumps.isEmpty)

        // Insertions/deletions that preserve relative order of kept rows report no jumps.
        reorder.measure(animates: true, old: [a, b, c], new: [a, d, b, c], gap: 5) { heights[$0] }
        #expect(reorder.jumps.isEmpty)

        // Actual permutation measures each kept row's delta (`oldTop - newTop`) across gaps.
        // Old kept order: a (0), b (25), c (60).
        // New kept order: c (0), a (45), b (70).
        reorder.measure(animates: true, old: [a, b, c], new: [c, a, b], gap: 5) { heights[$0] }
        #expect(reorder.jump(for: c) == 60)
        #expect(reorder.jump(for: a) == -45)
        #expect(reorder.jump(for: b) == -45)
    }

    @Test("virtual_selection_anchors_and_bounded_collector")
    func virtualSelectionAnchorsAndBoundedCollector() {
        // 1. Anchors + custom LCA `selectionCopy` provider across mounted + unmounted rows.
        var book = VirtualListBookkeeping()
        book.setEstimate(20)
        book.viewport = 60
        let keys = (0..<30).map { "m-\($0)" }
        _ = book.setKeys(keys, commit: 1, offset: nil)
        book.select(offset: 0, pinned: false, budget: nil) // mounts beginning slice

        var pins = VirtualPins()
        pins.setSource(.rebuild(.fromElBuilder { (idx: Int) -> El<()> in
            el().child(text("msg \(idx)").selectable())
        }))

        var hosts: [String: VirtualListSelectionHost] = [
            "chat/list": VirtualListSelectionHost(
                listPath: "chat/list",
                bookkeeping: book,
                selection: VirtualPinnedSelection(
                    pins: pins,
                    scope: VirtualSelectionScope(groupPath: "chat", inert: false)
                )
            )
        ]

        var nodes: [SelectableNodeSnapshot] = [
            SelectableNodeSnapshot(path: "chat", key: "chat", parentPath: nil, isSelectionGroup: true),
            SelectableNodeSnapshot(path: "chat/header", key: "header", parentPath: "chat", isSelectable: true, text: "Header"),
            SelectableNodeSnapshot(path: "chat/list", key: "list", parentPath: "chat"),
        ]
        for r in book.range {
            let rk = keys[r]
            nodes.append(SelectableNodeSnapshot(
                path: "chat/list/\(rk)",
                key: rk,
                parentPath: "chat/list"
            ))
            nodes.append(SelectableNodeSnapshot(
                path: "chat/list/\(rk)/text",
                parentPath: "chat/list/\(rk)",
                isSelectable: true,
                text: "msg \(r)"
            ))
        }

        let span = VirtualSelectionCollector.virtualSpanUnder(rootIndex: 0, nodes: nodes, lists: &hosts)
        #expect(span != nil)
        var phase = SelectionPhase.empty
        var anchorState = VirtualSelectionAnchorState()
        if let (first, last) = span {
            VirtualSelectionCollector.selectSpanEnds(
                first: first,
                last: last,
                phase: &phase,
                anchorState: &anchorState,
                nodes: nodes,
                lists: &hosts
            )
        }

        #expect(VirtualSelectionCollector.hasNonemptySelection(
            phase: phase,
            anchorState: anchorState,
            nodes: nodes,
            lists: hosts
        ))
        #expect(VirtualSelectionCollector.selectionSpansUnmounted(
            phase: phase,
            anchorState: anchorState,
            nodes: nodes,
            lists: hosts
        ))
        #expect(VirtualSelectionCollector.betweenMatches(
            span!.0,
            span!.1,
            phase: phase,
            anchorState: &anchorState,
            nodes: nodes,
            lists: hosts
        ))

        let providers: [String: VirtualSelectionCopyProvider] = [
            "chat": VirtualSelectionCopyProvider(path: "chat") { sel in
                "[GROUP:\(sel.texts.count)] \(sel.text)"
            }
        ]
        let copied = VirtualSelectionCollector.copyVirtualText(
            phase: phase,
            anchorState: anchorState,
            nodes: nodes,
            lists: hosts,
            copyProviders: providers
        )
        #expect(copied?.hasPrefix("[GROUP:31] Header\nmsg 0") == true)
        #expect(copied?.hasSuffix("msg 29") == true)

        // 2. Bounded row cap (`maxVirtualCopyRows = 10_000`) stops before scanning unbounded rows.
        var bigBook = VirtualListBookkeeping()
        bigBook.setEstimate(20)
        bigBook.viewport = 5
        let bigCount = VirtualCopyLimits.maxVirtualCopyRows + 50
        _ = bigBook.setKeys((0..<bigCount).map { "b-\($0)" }, commit: 1, offset: nil)
        bigBook.select(offset: 0, pinned: false, budget: nil)
        var bigPins = VirtualPins()
        bigPins.setSource(.rebuild(.fromElBuilder { (idx: Int) -> El<()> in
            el().child(text("x\(idx)").selectable())
        }))
        var bigHosts: [String: VirtualListSelectionHost] = [
            "big/list": VirtualListSelectionHost(
                listPath: "big/list",
                bookkeeping: bigBook,
                selection: VirtualPinnedSelection(pins: bigPins)
            )
        ]
        let bigNodes = [
            SelectableNodeSnapshot(path: "big", key: "big", parentPath: nil, isSelectionGroup: true),
            SelectableNodeSnapshot(path: "big/list", key: "list", parentPath: "big"),
            SelectableNodeSnapshot(path: "big/list/b-0", key: "b-0", parentPath: "big/list"),
            SelectableNodeSnapshot(
                path: "big/list/b-0/text",
                parentPath: "big/list/b-0",
                isSelectable: true,
                text: "x0"
            ),
        ]
        if let (first, last) = VirtualSelectionCollector.virtualSpanUnder(rootIndex: 0, nodes: bigNodes, lists: &bigHosts) {
            var bigPhase = SelectionPhase.empty
            var bigAnchors = VirtualSelectionAnchorState()
            VirtualSelectionCollector.selectSpanEnds(
                first: first,
                last: last,
                phase: &bigPhase,
                anchorState: &bigAnchors,
                nodes: bigNodes,
                lists: &bigHosts
            )
            let bigCollected = VirtualSelectionCollector.collectVirtualSelection(
                phase: bigPhase,
                anchorState: bigAnchors,
                nodes: bigNodes,
                lists: bigHosts
            )
            #expect(bigCollected != nil)
            let mountedCount = bigBook.range.count
            let collectedCount = bigCollected?.texts.count ?? 0
            #expect(collectedCount < bigCount)
            #expect(collectedCount - mountedCount <= VirtualCopyLimits.maxVirtualCopyRows)
        } else {
            Issue.record("Expected virtualSpanUnder to resolve bounded big list")
        }

        // 3. Bounded byte cap (`maxVirtualCopyBytes = 4 MiB`).
        var join = BoundedCopyJoin()
        let chunk = String(repeating: "a", count: 1_500_000)
        let push1 = join.push(
            content: chunk,
            uncopied: [],
            copyBreakBefore: 0,
            copyBreakAfter: 0,
            copyPrefix: nil,
            range: 0..<chunk.utf8.count,
            piece: chunk,
            beside: false,
            cap: VirtualCopyLimits.maxVirtualCopyBytes
        )
        #expect(!push1)
        let push2 = join.push(
            content: chunk,
            uncopied: [],
            copyBreakBefore: 0,
            copyBreakAfter: 0,
            copyPrefix: nil,
            range: 0..<chunk.utf8.count,
            piece: chunk,
            beside: false,
            cap: VirtualCopyLimits.maxVirtualCopyBytes
        )
        #expect(!push2)
        // 4.5M exceeds 4 MiB so the third push hits the cap and seals (`true` == capped).
        let push3 = join.push(
            content: chunk,
            uncopied: [],
            copyBreakBefore: 0,
            copyBreakAfter: 0,
            copyPrefix: nil,
            range: 0..<chunk.utf8.count,
            piece: chunk,
            beside: false,
            cap: VirtualCopyLimits.maxVirtualCopyBytes
        )
        #expect(push3)
        #expect(join.currentByteCount <= VirtualCopyLimits.maxVirtualCopyBytes)
        #expect(join.finish().utf8.count <= VirtualCopyLimits.maxVirtualCopyBytes)
    }
}
