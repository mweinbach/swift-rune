import Foundation
import Testing
import RuneMotion
@testable import Rune

/// Nonvirtual four-text window and independent model from Rune's
/// runtime/tests/selection_phase.rs. Coordinates and byte boundaries are constants in the model.
private enum FourTextWalk {
    enum Row: Int, CaseIterable {
        case a, m, b, c

        var key: String {
            switch self {
            case .a: "a"
            case .m: "m"
            case .b: "b"
            case .c: "c"
            }
        }
        var grouped: Bool { self != .c }
    }

    enum Spot: Equatable {
        case start(Row), end(Row), blank

        var row: Row? {
            switch self {
            case let .start(row), let .end(row): row
            case .blank: nil
            }
        }

        var point: Vec2 {
            guard let row else { return Vec2(2, 150) }
            let x: Float = if case .end = self { 296 } else { 2 }
            return Vec2(x, Float(row.rawValue * 24 + 12))
        }

        func offset(in text: String) -> Int {
            if case .end = self { return text.utf8.count }
            return 0
        }
    }

    enum Letter {
        case press(Spot), drag(Spot), up, lost, shift, tick, menu, selectAll, focus, append, rewrite, editMiddle, remount

        static let pointer: [Self] = [
            .press(.start(.a)), .press(.end(.a)), .press(.end(.b)), .press(.start(.c)), .press(.blank),
            .drag(.start(.a)), .drag(.end(.b)), .drag(.end(.c)), .up, .lost, .shift, .tick
        ]
        static let held: [Self] = [
            .press(.start(.a)), .press(.end(.b)), .press(.start(.c)), .drag(.end(.b)), .up, .menu,
            .selectAll, .focus, .append, .rewrite, .editMiddle, .remount
        ]
    }

    struct Document: Equatable {
        var remounted = false
        var appended = 0
        var rewritten = false
        var middleEdited = false

        var groupPath: String { remounted ? "/@root/1" : "/@root/0" }

        func path(_ row: Row) -> String { (row.grouped ? groupPath : "/@root") + "/@" + row.key }

        func row(at path: String) -> Row? { Row.allCases.first { self.path($0) == path } }

        func content(_ row: Row) -> String {
            switch row {
            case .a: (rewritten ? "Alpha beta" : "alpha beta") + String(repeating: " x", count: appended)
            case .m: middleEdited ? "MIDDLE" : "middle"
            case .b: "gamma"
            case .c: "delta"
            }
        }

        mutating func edit(_ letter: Letter) {
            switch letter {
            case .remount: remounted.toggle()
            case .append: appended += 1
            case .rewrite: rewritten.toggle()
            case .editMiddle: middleEdited.toggle()
            default: preconditionFailure("Not a document edit")
            }
        }

        static func view(_ doc: Document, _: inout Cx<Document>) -> El<Document> {
            func line(_ row: Row) -> El<Document> {
                text(doc.content(row)).key(row.key).font(TextStyle(size: 14, weight: 400))
                    .wFull().h(24).selectable()
            }
            var root: El<Document> = col().key("root").w(300)
            if doc.remounted { root = root.child(el().w(300).h(0)) }
            return root.child(col().wFull().selectionGroup().child(line(.a)).child(line(.m)).child(line(.b)))
                .child(line(.c)).child(el().key("button").w(100).h(20).focusable())
                .child(el().key("blank").wFull().h(80))
        }
    }

    struct Endpoint: Equatable {
        var path: String
        var text: String

        init(_ row: Row, _ doc: Document) {
            path = doc.path(row)
            text = doc.content(row)
        }

        func stillContains(_ doc: Document, _ row: Row, through end: Int) -> Bool {
            let now = doc.content(row).utf8
            let old = text.utf8
            if end == 0 { return now.starts(with: old) }
            return old.count >= end && now.count >= end && old.prefix(end).elementsEqual(now.prefix(end))
        }

        func rebound(_ doc: Document, through end: Int) -> Row? {
            // All four keys are unique. Only the unkeyed group slot changes on remount.
            Row.allCases.first { path.hasSuffix("/@" + $0.key) && stillContains(doc, $0, through: end) }
        }
    }

    struct Model {
        var head: Endpoint?
        var far: Endpoint?
        var anchor = 0, focus = 0
        var origin = (0, 0)
        var unit = SelectionUnit.character
        var dragging = false, shift = false
        var between: [Endpoint] = []
        var run: (path: String, at: Double, point: Vec2, count: Int)?
        var pick: String?

        func span(_ text: String, _ offset: Int, _ unit: SelectionUnit) -> (Int, Int) {
            let bytes = Array(text.utf8)
            switch unit {
            case .character: return (offset, offset)
            case .paragraph: return (0, bytes.count)
            case .word:
                if bytes.isEmpty { return (0, 0) }
                let i = min(offset, bytes.count - 1)
                let space = bytes[i] == 32
                var a = i, b = i + 1
                while a > 0 && (bytes[a - 1] == 32) == space { a -= 1 }
                while b < bytes.count && (bytes[b] == 32) == space { b += 1 }
                return (a, b)
            }
        }

        func holder(_ doc: Document) -> Row? {
            guard let head, let h = doc.row(at: head.path) else { return nil }
            let end: Int
            if let far {
                end = (doc.row(at: far.path)?.rawValue ?? -1) > h.rawValue ? head.text.utf8.count : max(anchor, origin.1)
            } else {
                end = max(anchor, focus, origin.1)
            }
            return head.stillContains(doc, h, through: end) ? h : nil
        }

        func focusHolder(_ doc: Document, _ h: Row) -> Row? {
            guard let far else { return h }
            guard let f = doc.row(at: far.path), f.grouped && h.grouped else { return nil }
            return far.stillContains(doc, f, through: f.rawValue > h.rawValue ? focus : far.text.utf8.count) ? f : nil
        }

        func middle(_ doc: Document, _ h: Row, _ f: Row) -> [Endpoint] {
            Row.allCases.filter { $0.rawValue > min(h.rawValue, f.rawValue) && $0.rawValue < max(h.rawValue, f.rawValue) }
                .map { Endpoint($0, doc) }
        }

        func range(_ doc: Document, at row: Row) -> Range<Int>? {
            guard let h = holder(doc), let f = focusHolder(doc, h) else { return nil }
            if h == f { return row == h ? min(anchor, focus)..<max(anchor, focus) : nil }
            let forwards = h.rawValue < f.rawValue
            let (first, last) = forwards ? (h, f) : (f, h)
            guard (first.rawValue...last.rawValue).contains(row.rawValue) else { return nil }
            let n = doc.content(row).utf8.count
            return (row == first ? min(n, forwards ? anchor : focus) : 0)..<(row == last ? min(n, forwards ? focus : anchor) : n)
        }

        mutating func seal(_ doc: Document) {
            between = []
            guard let h = holder(doc) else { return }
            if let f = focusHolder(doc, h) { between = middle(doc, h, f) }
            pick = h.grouped ? doc.groupPath : doc.path(h)
        }

        mutating func clear() {
            head = nil
            far = nil
            dragging = false
        }

        mutating func down(_ spot: Spot, _ doc: Document, _ now: Double) {
            guard let row = spot.row else {
                clear()
                run = nil
                return
            }
            let end = Endpoint(row, doc)
            let at = spot.offset(in: end.text), p = spot.point
            var count = 1
            if let run, run.path == end.path && now - run.at <= 0.3 &&
                abs(p.x - run.point.x) <= 4 && abs(p.y - run.point.y) <= 4 { count += run.count }
            run = (end.path, now, p, count)
            if shift, count == 1, let h = holder(doc), h == row || (h.grouped && row.grouped) {
                unit = .character
                origin = (anchor, anchor)
                focus = at
                far = h == row ? nil : end
            } else {
                unit = count == 1 ? .character : count == 2 ? .word : .paragraph
                origin = span(end.text, at, unit)
                (anchor, focus) = origin
                head = end
                far = nil
            }
            dragging = true
            seal(doc)
        }

        mutating func drag(_ spot: Spot, _ doc: Document) {
            guard dragging else { return }
            guard let h = holder(doc) else {
                clear()
                return
            }
            let row: Row, at: Int
            if !h.grouped {
                row = h
                at = spot.offset(in: doc.content(row))
            } else if let hit = spot.row, hit.grouped {
                row = hit
                at = spot.offset(in: doc.content(row))
            } else {
                row = .b
                at = doc.content(row).utf8.count
            }
            let s = span(doc.content(row), at, unit)
            if row == h { (anchor, focus) = s.0 < origin.0 ? (origin.1, s.0) : (origin.0, max(origin.1, s.1)) }
            else if row.rawValue > h.rawValue { (anchor, focus) = (origin.0, s.1) }
            else { (anchor, focus) = (origin.1, s.0) }
            let next = row == h ? nil : Endpoint(row, doc)
            if next?.path != far?.path {
                far = next
                seal(doc)
            }
        }

        mutating func selectAll(_ doc: Document) {
            let h = holder(doc)
            if h == nil { clear() }
            let target = h.map { $0.grouped ? doc.groupPath : doc.path($0) } ?? pick
            let first: Row, last: Row
            if target == doc.groupPath { (first, last) = (.a, .b) }
            else if let target, let row = doc.row(at: target) { (first, last) = (row, row) }
            else { return }
            head = Endpoint(first, doc)
            far = first == last ? nil : Endpoint(last, doc)
            anchor = 0
            focus = doc.content(last).utf8.count
            origin = (0, far == nil ? focus : 0)
            unit = .character
            dragging = false
            seal(doc)
        }

        mutating func menu(_ doc: Document) {
            #if os(macOS)
            guard range(doc, at: .a)?.contains(0) != true else { return }
            head = Endpoint(.a, doc)
            far = nil
            unit = .word
            origin = span(doc.content(.a), 0, unit)
            (anchor, focus) = origin
            dragging = false
            run = nil
            seal(doc)
            #endif
        }

        mutating func prune(_ doc: Document) {
            guard head != nil else { return }
            var rebind = false
            if holder(doc) == nil, let row = head?.rebound(doc, through: max(anchor, focus, origin.1)) {
                head?.path = doc.path(row)
                rebind = true
            }
            if let h = holder(doc), focusHolder(doc, h) == nil, let row = far?.rebound(doc, through: focus) {
                far?.path = doc.path(row)
                rebind = true
            }
            guard let h = holder(doc), let f = focusHolder(doc, h) else {
                clear()
                return
            }
            let changed = middle(doc, h, f)
            if rebind { between = changed }
            if far != nil && changed != between {
                clear()
                return
            }
            head = Endpoint(h, doc)
            if h != f { far = Endpoint(f, doc) }
        }
    }

    struct Reference {
        var doc = Document()
        var model = Model()
        var now = 0.0
        var at = Spot.blank

        mutating func play(_ letter: Letter) {
            switch letter {
            case let .press(spot):
                model.down(spot, doc, now)
                at = spot
            case let .drag(spot):
                model.drag(spot, doc)
                at = spot
            case .up:
                model.drag(at, doc)
                model.dragging = false
            case .lost: model.dragging = false
            case .shift: model.shift.toggle()
            case .tick: now += 1
            case .menu: model.menu(doc)
            case .selectAll: model.selectAll(doc)
            case .focus:
                if let h = model.holder(doc), model.range(doc, at: h) != nil { model.clear() }
            case .append, .rewrite, .editMiddle, .remount:
                doc.edit(letter)
                model.prune(doc)
            }
        }

        /// The pinned Rust model hashes its path spellings, including the unkeyed group slot.
        func rustPath(_ path: String) -> String {
            path.split(separator: "/").map { $0.first == "@" ? String($0.dropFirst()) : "#" + $0 }.joined(separator: "/")
        }

        func record() -> String {
            var result = model.shift ? "1|" : "0|"
            if let head = model.head {
                let unit: String = if !model.dragging { "-" } else {
                    switch model.unit {
                    case .character: "c"
                    case .word: "w"
                    case .paragraph: "p"
                    }
                }
                let farPath = model.far.map { rustPath($0.path) } ?? ""
                result += "\(rustPath(head.path))|\(head.text)|\(model.anchor)|\(model.focus)|\(model.origin.0)|\(model.origin.1)|"
                result += "\(farPath)|\(model.far?.text ?? "")|\(unit)|"
                if let h = model.holder(doc), let range = model.range(doc, at: h) {
                    result += "\(rustPath(head.path)):\(range.lowerBound):\(range.upperBound)"
                }
            }
            return result + "\n"
        }

        private struct Transition: Hashable {
            let letterIndex: Int
            let before: String
            let after: String
        }

        /// Visit every prefix in Rust's order. Keep a shortest replay for every distinct
        /// (letter, previous observation, resulting observation), including placed/dragged
        /// phases with identical public ranges. Hidden click runs and document edits are
        /// carried through every reference history. The retained witnesses replay real input.
        static func oracle(_ alphabet: [Letter]) -> (count: Int, hash: UInt64, witnesses: [[Int]]) {
            var count = 0, hash: UInt64 = 14_695_981_039_346_656_037
            var witnesses = [Transition: [Int]]()
            var history: [Int] = []
            func visit(_ parent: Self, _ before: String) {
                for (index, letter) in alphabet.enumerated() {
                    var child = parent
                    child.play(letter)
                    let after = child.record()
                    count += 1
                    for b in after.utf8 { hash = (hash ^ UInt64(b)) &* 1_099_511_628_211 }
                    history.append(index)
                    let edge = Transition(letterIndex: index, before: before, after: after)
                    if history.count < (witnesses[edge]?.count ?? Int.max) { witnesses[edge] = history }
                    if history.count < 5 { visit(child, after) }
                    history.removeLast()
                }
            }
            let initial = Self()
            visit(initial, initial.record())
            return (count, hash, witnesses.values.sorted { $0.lexicographicallyPrecedes($1) })
        }
    }

    final class Walk {
        let runtime = Runtime(state: Document(), viewport: Vec2(320, 240), pixelScale: 1,
                              systemDark: true, view: Document.view)
        var reference = Reference()
        var doc: Document { reference.doc }
        var model: Model { reference.model }
        var now: Double { reference.now }
        var at: Spot { reference.at }

        init() {
            runtime.doubleClickInterval = 0.3
            runtime.frame(at: 0)
        }

        func commit(remount: Bool) {
            runtime.frame(at: now)
            if remount {
                for i in 1...8 where runtime.isAnimating || runtime.needsCommit {
                    runtime.frame(at: now + Double(i))
                }
            }
        }

        func reset() {
            runtime.cancelPointer(at: now)
            runtime.selectionState = RuntimeSelectionState()
            runtime.inputMachines = RuntimeInputMachines()
            runtime.popupQueue = .closed
            let remount = doc.remounted
            let edited = doc != Document()
            reference = Reference()
            if edited {
                runtime.update(at: now) { state, _ in state = Document() }
                commit(remount: remount)
            }
        }

        func play(_ letter: Letter) {
            switch letter {
            case let .press(spot): runtime.pointerDown(at: spot.point, at: now)
            case let .drag(spot): runtime.pointerMove(to: spot.point, at: now)
            case .up: runtime.pointerUp(at: at.point, at: now)
            case .lost: runtime.cancelPointer(at: now)
            case .shift: runtime.physicalInput(.modifiers(Mods(shift: !model.shift)), at: now)
            case .tick: break
            case .menu:
                let point = Spot.start(.a).point
                runtime.secondaryDown(at: point, at: now)
                runtime.secondaryUp(at: point, at: now)
                runtime.popupQueue = .closed
            case .selectAll:
                _ = runtime.keyDown(KeyEvent(key: .command("a"), mods: RuneTestKey.primaryMods()), at: now)
                runtime.frame(at: now)
            case .focus:
                runtime.setFocus(path: "/@root/@button", keyboard: true, at: now)
                runtime.setFocus(path: nil, keyboard: false, at: now)
            case .append, .rewrite, .editMiddle, .remount:
                let was = doc.remounted
                runtime.update(at: now) { state, _ in state.edit(letter) }
                commit(remount: was != runtime.state.remounted)
            }
            reference.play(letter)
        }

        func difference() -> String? {
            let phase = runtime.selectionState.coordinator.phase
            if runtime.inputMachines.currentMods.shift != model.shift { return "held Shift differs" }
            if phase.isDragging != model.dragging { return "dragging \(phase.isDragging), expected \(model.dragging)" }
            switch (phase.selection, model.head) {
            case (nil, nil): break
            case let (s?, head?):
                if s.path != head.path || s.content != head.text || s.anchor != model.anchor ||
                    s.focus != model.focus || s.origin != model.origin ||
                    s.far?.path != model.far?.path || s.far?.content != model.far?.text {
                    return "\(s), expected \(head) anchor \(model.anchor) focus \(model.focus) origin \(model.origin) far \(String(describing: model.far))"
                }
                if case .dragging(_, let unit) = phase, unit != model.unit { return "unit \(unit), expected \(model.unit)" }
                if s.anchorEnd != nil || s.far?.end != nil { return "virtual selection endpoint in nonvirtual text" }
            default: return "phase \(phase), expected head \(String(describing: model.head))"
            }
            if !runtime.selectionState.mountedBetween.isEmpty { return "virtual between rows on ordinary text" }
            let actual = runtime.textSelection()
            let expected = model.holder(doc).flatMap { model.range(doc, at: $0) }
            if actual?.path != (expected == nil ? nil : model.head?.path) || actual?.range != expected {
                return "textSelection \(String(describing: actual)), expected \(String(describing: model.head?.path)) \(String(describing: expected))"
            }
            return nil
        }

        func compare(_ sequence: [Letter]) throws {
            reset()
            for (i, letter) in sequence.enumerated() {
                play(letter)
                if let diff = difference() { throw Mismatch(message: "\(sequence.prefix(i + 1)): \(diff)") }
            }
        }

        func check(_ alphabet: [Letter], depth: Int = 5) throws -> Int {
            var sequence = [Letter]()
            var count = 0
            func visit() throws {
                for letter in alphabet {
                    sequence.append(letter)
                    try compare(sequence)
                    count += 1
                    if sequence.count < depth { try visit() }
                    sequence.removeLast()
                }
            }
            try visit()
            return count
        }
    }

    struct Mismatch: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}

@Suite("Nonvirtual selection phase — four-text Rune reference", .serialized)
struct SelectionPhaseWalkTests {
    @Test func physicalSpotsAndRemountPaths() throws {
        typealias W = FourTextWalk
        let walk = W.Walk()
        for row in W.Row.allCases {
            for spot in [W.Spot.start(row), .end(row)] { try walk.compare([.press(spot)]) }
        }
        for spot in [W.Spot.start(.a), .end(.a), .end(.b), .blank] { try walk.compare([.press(.end(.c)), .drag(spot)]) }
        try walk.compare([.remount])
        for row in W.Row.allCases { #expect(walk.runtime.nodeByPath[walk.doc.path(row)] != nil) }
        #expect(walk.runtime.flatNodes.contains { $0.path == walk.doc.groupPath && $0.el.isSelectionGroup })
    }

    @Test func keyboardFocusAndPointerCapture() throws {
        let walk = FourTextWalk.Walk()
        try walk.compare([.press(.start(.a)), .drag(.end(.b)), .focus])
        try walk.compare([.press(.start(.a)), .lost, .press(.start(.a))])
        try walk.compare([.press(.start(.a)), .shift, .press(.end(.b))])
        try walk.compare([.press(.start(.a)), .drag(.end(.b)), .editMiddle])
        try walk.compare([.press(.start(.a)), .drag(.end(.b)), .remount])
    }

    @Test func hostClickIntervalAndDiagonalSlop() {
        let walk = FourTextWalk.Walk()
        let rt = walk.runtime
        let a = Vec2(2, 12), diagonal = Vec2(6, 16)
        rt.doubleClickInterval = 0.7
        rt.pointerDown(at: a, at: 0)
        rt.pointerUp(at: a, at: 0)
        rt.pointerDown(at: diagonal, at: 0.7)
        #expect(rt.textSelection()?.range == 0..<5)
        rt.pointerUp(at: diagonal, at: 0.7)
        rt.doubleClickInterval = 0.1
        rt.pointerDown(at: diagonal, at: 0.9)
        #expect(rt.textSelection()?.range.isEmpty == true)
    }

    @Test func tabTakesTheSelectionKeyboard() {
        let walk = FourTextWalk.Walk()
        walk.runtime.tabVisitsControls = true
        walk.play(.press(.start(.a)))
        walk.play(.drag(.end(.b)))
        walk.play(.up)
        #expect(walk.runtime.textSelection() != nil)
        _ = walk.runtime.keyDown(KeyEvent(key: .tab), at: 0)
        #expect(walk.runtime.focusedPath == "/@root/@button")
        #expect(walk.runtime.textSelection() == nil)
    }

    private func verify(_ alphabet: [FourTextWalk.Letter], hash: UInt64) throws {
        let oracle = FourTextWalk.Reference.oracle(alphabet)
        #expect(oracle.count == 271_452)
        #expect(oracle.hash == hash)
        let walk = FourTextWalk.Walk()
        for history in oracle.witnesses { try walk.compare(history.map { alphabet[$0] }) }
    }

    /// FNV-1a of the original Rust Dev's phase and holder-range outputs after all 271,452
    /// prefixes of each alphabet, in prefix order, at 842c28c2. The secondary-click word
    /// selection is macOS-specific in the reference.
    @Test func everyPointerTransitionMatchesPinnedRust() throws {
        try verify(FourTextWalk.Letter.pointer, hash: 0x000b_dfb3_feb2_e3ab)
    }

    @Test func everyHeldTransitionMatchesPinnedRust() throws {
        #if os(macOS)
        try verify(FourTextWalk.Letter.held, hash: 0xa083_4ced_e720_2982)
        #else
        try verify(FourTextWalk.Letter.held, hash: 0xe409_2ce7_2ac1_5e59)
        #endif
    }

    /// Run the literal independent-runtime replay of every complete history with
    /// `RUNE_TEST_FULL_SELECTION_WALK=1 xcrun swift test -c release --filter SelectionPhaseWalkTests`.
    /// The regular suite already replays each distinct observable transition on Runtime.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUNE_TEST_FULL_SELECTION_WALK"] == "1"))
    func everyPointerSequence() throws {
        #expect(try FourTextWalk.Walk().check(FourTextWalk.Letter.pointer) == 271_452)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUNE_TEST_FULL_SELECTION_WALK"] == "1"))
    func everyHeldSequence() throws {
        #expect(try FourTextWalk.Walk().check(FourTextWalk.Letter.held) == 271_452)
    }
}
