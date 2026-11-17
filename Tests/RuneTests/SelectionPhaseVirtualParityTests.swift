import Testing
import Foundation
import RuneRef
@testable import Rune

/// Port of `crates/rune/src/runtime/tests/selection_phase_virtual.rs`: `selection_phase`'s walk
/// over the rows of a virtual list: a selection whose anchor row scrolls out of the mounted
/// window and back, a drag while the list scrolls, Select All over rows never built, a handler
/// clearing it. The reference is the same transcription of the code before `selectable::phase`,
/// on a list of forty rows that never change, so every text the selection names stays
/// resolvable (its rows are pinned) and only the pointer's row depends on the scroll. Both
/// sides' virtual ends are compared after every letter: the anchor's row and offset, the focus's
/// when it's in another row, and that the mounted rows hashed between them lie strictly between
/// them.
enum SelectionPhaseVirtualWalk {
    /// Sequences of up to this many letters.
    static let length = 5
    static let rows = 40
    static let rowH: Float = 40.0
    /// What each row reads: every row the same length.
    static let len = 6
    /// `CLICK_SLOP`, as the reference transcribes it.
    static let slop: Float = 4.0

    static func content(_ row: Int) -> String { String(format: "row %02d", row) }

    /// The top line of the viewport at its start, or its bottom line past the end.
    enum Spot: Equatable, CustomStringConvertible {
        case hiStart, loEnd
        var description: String { self == .hiStart ? "HiStart" : "LoEnd" }
    }

    static func point(_ spot: Spot) -> Vec2 {
        switch spot {
        case .hiStart: return Vec2(2.0, 20.0)
        case .loEnd: return Vec2(296.0, 100.0)
        }
    }

    /// The row under `spot`, with the list scrolled to its top or its end, and the byte a press
    /// there lands on.
    static func under(_ spot: Spot, top: Bool) -> (Int, Int) {
        switch (spot, top) {
        case (.hiStart, true): return (0, 0)
        case (.loEnd, true): return (2, len)
        case (.hiStart, false): return (rows - 3, 0)
        case (.loEnd, false): return (rows - 1, len)
        }
    }

    enum Letter: CustomStringConvertible {
        case press(Spot), drag(Spot), up, lost, down, top, selectAll, clear
        var description: String {
            switch self {
            case .press(let s): return "Press(\(s))"
            case .drag(let s): return "Drag(\(s))"
            case .up: return "Up"
            case .lost: return "Lost"
            case .down: return "Down"
            case .top: return "Top"
            case .selectAll: return "SelectAll"
            case .clear: return "Clear"
            }
        }
    }

    static let alphabet: [Letter] = [
        .press(.hiStart), .press(.loEnd), .drag(.hiStart), .drag(.loEnd),
        .up, .lost, .down, .top, .selectAll, .clear,
    ]

    static func view(_: Int, _: inout Cx<Int>) -> El<Int> {
        col().key("root").w(300.0).h(120.0).child(
            col().key("scroll").wFull().h(120.0).scroll(stickBottom: false).child(
                col().key("list").wFull().growth(.default).selectionGroup(true).virtualRows(
                    rows,
                    rowH,
                    key: { _, i in "r\(i)" },
                    build: { _, i in
                        text(content(i)).font(TextStyle(size: 14.0, weight: 400.0)).wFull().h(rowH).selectable(true)
                    }
                )
            )
        )
    }

    enum U: Equatable { case char, word, paragraph }

    /// `unit_at` on "row NN".
    static func unitAt(_ i0: Int, _ unit: U) -> (Int, Int) {
        let i = (i0 == len && unit != .char) ? i0 - 1 : i0
        switch unit {
        case .char: return (i, i)
        case .paragraph: return (0, len)
        case .word:
            switch i {
            case 0...2: return (0, 3)
            case 3: return (3, 4)
            default: return (4, len)
            }
        }
    }

    /// `extend`, transcribed.
    static func extend(_ origin: (Int, Int), _ at: (Int, Int)) -> (Int, Int) {
        at.0 < origin.0 ? (origin.1, at.0) : (origin.0, max(at.1, origin.1))
    }

    struct Run {
        var path: String
        var point: Vec2
        var count: Int
    }

    /// `selectable::Held` before `selectable::phase`, on rows that never change: the anchor's and
    /// the focus's texts always resolve, and resolve to the rows their paths name.
    struct Dev {
        let list: String
        var path: String? = nil
        var content: String = ""
        var anchor = 0
        var focus = 0
        var far: (String, String)? = nil
        var unit: U = .char
        var origin: (Int, Int) = (0, 0)
        var dragging = false
        var presses: Run? = nil

        init(list: String) { self.list = list }

        func path(_ row: Int) -> String { "\(list)/@r\(row)" }

        /// `PressRun::press` with the clock standing still.
        mutating func pressCount(_ path: String, _ point: Vec2) -> Int {
            if var last = presses, last.path == path,
               abs(point.x - last.point.x) <= slop, abs(point.y - last.point.y) <= slop {
                last.point = point
                last.count += 1
                presses = last
                return last.count
            }
            presses = Run(path: path, point: point, count: 1)
            return 1
        }

        mutating func clear() {
            path = nil
            far = nil
            dragging = false
        }

        /// `selection_down` on the row under `spot`: no Shift, so every press starts a selection.
        mutating func down(_ spot: Spot, top: Bool) {
            let (row, at) = under(spot, top: top)
            let clicks = min(pressCount(path(row), point(spot)), 3)
            let unit: U = clicks == 1 ? .char : (clicks == 2 ? .word : .paragraph)
            let origin = unitAt(at, unit)
            self.unit = unit
            self.origin = origin
            (anchor, focus) = origin
            path = path(row)
            content = SelectionPhaseVirtualWalk.content(row)
            far = nil
            dragging = true
        }

        /// `selection_drag`: the group reaches the row the pointer is over.
        mutating func drag(_ spot: Spot, top: Bool) {
            guard dragging else { return }
            guard let h = path.map(rowOf) else { clear(); return }
            let (j, at0) = under(spot, top: top)
            let at = unitAt(at0, unit)
            let (a, f) = j == h ? extend(origin, at) : (j > h ? (origin.0, at.1) : (origin.1, at.0))
            let sameFar = j == h ? far == nil : (far.map { $0.0 == path(j) } ?? false)
            if (anchor, focus) == (a, f) && sameFar { return }
            (anchor, focus) = (a, f)
            if j == h {
                far = nil
            } else if !sameFar {
                far = (path(j), SelectionPhaseVirtualWalk.content(j))
            }
        }

        /// `selection_key`'s Cmd+A: the group is the list, so it selects every row.
        mutating func selectAll() {
            path = path(0)
            content = SelectionPhaseVirtualWalk.content(0)
            (anchor, focus, origin, unit) = (0, len, (0, 0), .char)
            far = (path(rows - 1), SelectionPhaseVirtualWalk.content(rows - 1))
            dragging = false
        }

        /// `Runtime::text_selection`.
        func textSelection() -> (String, Range<Int>)? {
            guard let path else { return nil }
            let h = rowOf(path)
            let range: Range<Int>
            if let (farPath, _) = far {
                let f = rowOf(farPath)
                if f == h {
                    range = min(anchor, focus)..<max(anchor, focus)
                } else {
                    let (a, b) = h < f ? (min(anchor, len), len) : (0, min(anchor, len))
                    range = a < b ? a..<b : anchor..<anchor
                }
            } else {
                range = min(anchor, focus)..<max(anchor, focus)
            }
            return (path, range)
        }
    }

    static func rowOf(_ path: String) -> Int {
        guard let r = path.range(of: "/@r", options: .backwards), let row = Int(path[r.upperBound...]) else {
            preconditionFailure("a row path: \(path)")
        }
        return row
    }

    final class Walk {
        let rt: Runtime<Int>
        let list: String
        var dev: Dev
        /// The list is scrolled to its top (else to its end).
        var top = true
        var at: Spot = .hiStart
        /// The runtime clock: `settle` runs it forward, then stands it back at zero.
        var clock = 0.0

        init() {
            rt = Runtime<Int>(state: 0, viewport: Vec2(300.0, 120.0), pixelScale: 1.0, systemDark: true, view: view)
            rt.doubleClickInterval = 0.3
            _ = rt.frame(at: 0.0)
            guard let list = rt.virtualLists.keys.first(where: { $0.hasSuffix("@list") }) else {
                preconditionFailure("the list is virtual: \(Array(rt.virtualLists.keys))")
            }
            self.list = list
            dev = Dev(list: list)
            settle()
        }

        func path(_ row: Int) -> String { "\(list)/@r\(row)" }

        func settle() {
            for _ in 0..<60 {
                clock += 1.0 / 60.0
                _ = rt.frame(at: clock)
                if !rt.isAnimating && !rt.needsCommit { break }
            }
            clock = 0.0
        }

        func scroll(top: Bool) {
            rt.wheel(WheelEvent(dx: 0, dy: top ? 10_000.0 : -10_000.0), at: Vec2(150.0, 60.0), now: clock)
            settle()
            self.top = top
        }

        func reset() {
            rt.cancelPointer(at: clock)
            rt.selectionState = RuntimeSelectionState()
            rt.syncSelectionPins()
            if !top { scroll(top: true) }
            clock = 0.0
            dev = Dev(list: list)
            at = .hiStart
        }

        func play(_ letter: Letter) -> String? {
            switch letter {
            case .press(let spot):
                rt.pointerDown(at: point(spot), at: clock)
                dev.down(spot, top: top)
                at = spot
            case .drag(let spot):
                rt.pointerMove(to: point(spot), at: clock)
                dev.drag(spot, top: top)
                at = spot
            case .up:
                rt.pointerUp(at: point(at), at: clock)
                dev.drag(at, top: top)
                dev.dragging = false
            case .lost:
                rt.cancelPointer(at: clock)
                dev.dragging = false
            case .down:
                scroll(top: false)
            case .top:
                scroll(top: true)
            case .selectAll:
                _ = rt.keyDown(KeyEvent(key: .command("a"), mods: RuneTestKey.primaryMods()), at: clock)
                settle()
                dev.selectAll()
            case .clear:
                rt.update(at: clock) { _, tx in tx.clearTextSelection() }
                settle()
                dev.clear()
            }
            return compare(letter)
        }

        func compare(_ letter: Letter) -> String? {
            let phase = rt.selectionState.coordinator.phase
            let mountedBetween = rt.selectionState.mountedBetween
            switch (phase, dev.path) {
            case (.empty, nil) where !dev.dragging && mountedBetween.isEmpty:
                break
            case (.placed(let sel), .some(let path)), (.dragging(let sel, _), .some(let path)):
                var unit: U? = nil
                if case .dragging(_, let u) = phase {
                    switch u {
                    case .character: unit = .char
                    case .word: unit = .word
                    case .paragraph: unit = .paragraph
                    }
                }
                let theirUnit: U? = dev.dragging ? dev.unit : nil
                let ours = "\(sel.path) \(sel.content) \(sel.anchor) \(sel.focus) \(sel.origin) \(String(describing: sel.far.map { ($0.path, $0.content) })) \(String(describing: unit))"
                let theirs = "\(path) \(dev.content) \(dev.anchor) \(dev.focus) \(dev.origin) \(String(describing: dev.far)) \(String(describing: theirUnit))"
                if ours != theirs { return "after \(letter): \(ours), dev \(theirs)" }
                // `sync_selection_pins` names the rows of both ends, at their offsets.
                func end(_ path: String, _ offset: Int) -> VirtualEnd {
                    let r = rowOf(path)
                    return VirtualEnd(listPath: list, rowKey: "r\(r)", rowIndex: r, relPath: "", offset: offset)
                }
                if sel.anchorEnd != end(path, dev.anchor) {
                    return "after \(letter): anchor end \(String(describing: sel.anchorEnd))"
                }
                if let far = sel.far, let (fp, _) = dev.far {
                    if far.end != end(fp, dev.focus) { return "after \(letter): focus end \(String(describing: far.end))" }
                }
                let (h, f) = (rowOf(path), dev.far.map { rowOf($0.0) } ?? rowOf(path))
                let between = Set(((min(h, f) + 1)..<max(max(h, f), min(h, f) + 1)).map { "r\($0)" })
                if let k = mountedBetween.keys.first(where: { !between.contains($0) }) {
                    return "after \(letter): row \(k) hashed as between rows \(h) and \(f)"
                }
            default:
                let name: String
                switch phase {
                case .empty: name = "empty"
                case .placed: name = "placed"
                case .dragging: name = "dragging"
                }
                return "after \(letter): \(name), dev path \(String(describing: dev.path)) dragging \(dev.dragging)"
            }
            let ours = rt.textSelection()
            let theirs = dev.textSelection()
            if ours?.0 != theirs?.0 || ours?.1 != theirs?.1 {
                return "after \(letter): text_selection \(String(describing: ours)), dev \(String(describing: theirs))"
            }
            return nil
        }
    }

    static func visit(_ walk: Walk, _ sequence: inout [Letter], _ ran: inout Int, _ failure: inout String?) {
        if failure != nil { return }
        ran += 1
        walk.reset()
        for letter in sequence {
            if let why = walk.play(letter) {
                failure = "\(sequence): \(why)"
                return
            }
        }
        if sequence.count == length { return }
        for letter in alphabet {
            sequence.append(letter)
            visit(walk, &sequence, &ran, &failure)
            sequence.removeLast()
        }
    }
}

/// The next unit of work for the walk's workers (`AtomicUsize::fetch_add`).
final class UnitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0

    func take(below count: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard next < count else { return nil }
        next += 1
        return next - 1
    }
}

@Suite("selection_phase_virtual.rs parity", .serialized)
struct SelectionPhaseVirtualParityTests {
    typealias W = SelectionPhaseVirtualWalk

    @Test("every_short_sequence_over_virtual_rows_leaves_what_dev_left")
    func everyShortSequenceOverVirtualRowsLeavesWhatDevLeft() async {
        // Upstream hands the first letters out to worker threads, each with its own runtime. Here
        // the work goes out by the first two letters (and the ten one-letter sequences on their
        // own), so the workers finish together; every sequence still replays from a reset.
        var split: [[W.Letter]] = W.alphabet.map { [$0] }
        for a in W.alphabet { for b in W.alphabet { split.append([a, b]) } }
        let units = split
        let workers = min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 8)
        let next = UnitCounter()
        let results = await withTaskGroup(of: (Int, [String]).self) { group in
            for _ in 0..<workers {
                group.addTask {
                    let walk = W.Walk()
                    var ran = 0
                    var failures: [String] = []
                    while let i = next.take(below: units.count) {
                        var failure: String? = nil
                        var sequence = units[i]
                        if sequence.count == 1 {
                            ran += 1
                            walk.reset()
                            if let why = walk.play(sequence[0]) { failure = "\(sequence): \(why)" }
                        } else {
                            W.visit(walk, &sequence, &ran, &failure)
                        }
                        if let failure { failures.append(failure) }
                    }
                    return (ran, failures)
                }
            }
            var all: [(Int, [String])] = []
            for await r in group { all.append(r) }
            return all
        }
        var total = 0
        var failures: [String] = []
        for (ran, f) in results {
            total += ran
            failures.append(contentsOf: f)
        }
        print("\(total) sequences up to length \(W.length)")
        #expect(failures.isEmpty, "sequences differ from dev: \(failures)")
        let expected = (1...W.length).reduce(0) { $0 + Int(pow(Double(W.alphabet.count), Double($1))) }
        if failures.isEmpty {
            #expect(total == expected, "every sequence ran")
        }
    }

    /// The facts the reference takes as constants: the row under each spot at either end of the
    /// list, and that the anchor's row leaves the mounted window when the list scrolls to its end.
    @Test("the_virtual_reference_knows_which_row_each_spot_is_on")
    func theVirtualReferenceKnowsWhichRowEachSpotIsOn() {
        let walk = W.Walk()
        for top in [true, false] {
            for spot in [W.Spot.hiStart, .loEnd] {
                walk.reset()
                if !top { walk.scroll(top: false) }
                walk.rt.pointerDown(at: W.point(spot), at: walk.clock)
                let (row, at) = W.under(spot, top: top)
                let got = walk.rt.textSelection()
                #expect(got?.path == walk.path(row) && got?.range == at..<at, "\(spot) top \(top): \(String(describing: got))")
            }
        }
        walk.reset()
        let range = { walk.rt.virtualLists[walk.list]?.lastMountedRange ?? 0..<0 }
        #expect(range().contains(0))
        walk.scroll(top: false)
        #expect(!range().contains(0) && !range().contains(2), "\(range())")
        walk.scroll(top: true)
        #expect(!range().contains(W.rows - 1), "\(range())")
    }

    /// A selection made again over the same rows reuses the buckets of the map that hashes the
    /// mounted rows between its ends: a press, a handler's clear and the next drag clear it in place.
    @Test("a_repeated_drag_across_virtual_rows_keeps_the_mounted_row_map")
    func aRepeatedDragAcrossVirtualRowsKeepsTheMountedRowMap() {
        let walk = W.Walk()
        let capacity = { walk.rt.selectionState.mountedBetween.capacity }
        for letter in [W.Letter.press(.hiStart), .drag(.loEnd), .up] {
            let why = walk.play(letter)
            #expect(why == nil, "\(why ?? "")")
        }
        #expect(walk.rt.selectionState.mountedBetween["r1"] != nil, "row 1 lies between rows 0 and 2")
        let warm = capacity()
        #expect(warm > 0)
        for letter in [W.Letter.press(.hiStart), .drag(.loEnd), .up, .clear, .press(.hiStart), .drag(.loEnd)] {
            let why = walk.play(letter)
            #expect(why == nil, "\(why ?? "")")
            #expect(capacity() == warm, "after \(letter)")
        }
        #expect(walk.rt.selectionState.mountedBetween["r1"] != nil)
    }
}
