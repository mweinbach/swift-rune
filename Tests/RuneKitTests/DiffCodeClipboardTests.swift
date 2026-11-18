import Rune
import RuneKit
import Testing

@Suite("Diff code selection")
struct DiffCodeClipboardTests {
    @Test("Scrolling across copy sides refreshes application reads and captured event snapshots", arguments: [false, true])
    @MainActor
    func stationaryPointerCopySide(readInView: Bool) throws {
        struct Host {
            var diff: DiffState
            var captured: DiffSide?
        }
        let old = (1...100).map { "let n_\($0) = \($0)\n" }.joined()
        let new = (1...100).map { "let n_\($0) = \($0)\($0.isMultiple(of: 7) ? " + 1" : "")\n" }.joined()
        let file = FileDiff.fromTexts(path: "a.rs", old: old, new: new)
        let rt = Runtime(state: Host(diff: DiffState(diff: file)), viewport: Vec2(620, 300)) { host, cx in
            let snapshot = host.diff
            let caption = readInView ? snapshot.copySide.rawValue : "Capture"
            return col().wFull().hFull()
                .child(text(caption).key("capture").size(100, 25).onClick { $0.captured = snapshot.copySide })
                .child(DiffView<Host>(key: "diff", kit: .neutral(dark: true), state: \.diff)
                    .viewportHeight(240).build(state: host, cx: cx))
        }
        var time = 0.0
        func settle() {
            for _ in 0..<3 { time += 1 / 60; _ = rt.frame(at: time) }
        }
        let pointer = Vec2(400, 150)
        settle()
        rt.pointerMove(to: pointer, at: time)
        settle()
        let initial = rt.state.diff.copySide
        for expected: DiffSide in [initial == .new ? .old : .new, initial] {
            rt.pointerMove(to: pointer, at: time)
            for _ in 0..<20 where rt.state.diff.copySide != expected {
                rt.wheel(WheelEvent(dx: 0, dy: -17), at: pointer, now: time)
                settle()
            }
            try #require(rt.state.diff.copySide == expected)
            let capture = try #require(rt.element(byKey: "capture"))
            if readInView { #expect(capture.text == expected.rawValue) }
            let button = Vec2(capture.rect[0] + 5, capture.rect[1] + 5)
            rt.pointerMove(to: button, at: time)
            rt.pointerDown(at: button, at: time)
            rt.pointerUp(at: button, at: time + 0.001)
            settle()
            #expect(rt.state.captured == expected)
        }
    }

    @Test("Retained diff rows dispatch through the current application lens and callbacks")
    @MainActor
    func currentActionsAfterViewChanges() throws {
        struct Host {
            var first: DiffState
            var second: DiffState
            var useSecond = false
            var calls: [String] = []
        }
        let file = FileDiff.fromTexts(path: "a.rs", old: "one\nold\nthree\n", new: "one\nnew\nthree\n")
        let document = DiffState(diff: file)
        let rt = Runtime(state: Host(first: document, second: document), viewport: Vec2(620, 220)) { host, cx in
            let second = host.useSecond
            let tag = second ? "second" : "first"
            return DiffView<Host>(key: "fresh", kit: .neutral(dark: false),
                                  get: { second ? $0.second : $0.first }, set: { state, value in
                if second { state.second = value } else { state.first = value }
            })
            .onLineClick { state, _, _ in state.calls.append(tag + " number") }
            .onSelect { state, _, _ in state.calls.append(tag + " selection") }
            .onComment { state, _, _ in state.calls.append(tag + " comment") }
            .build(state: host, cx: cx)
        }
        var time = 0.0
        func settle() {
            for _ in 0..<6 {
                time += 1.0 / 30
                _ = rt.frame(at: time)
            }
        }
        func hover(_ key: String) throws -> Vec2 {
            let rect = try #require(rt.element(byKey: key)).rect
            let point = Vec2(rect[0] + rect[2] / 2, rect[1] + rect[3] / 2)
            rt.pointerMove(to: point, at: time)
            settle()
            return point
        }
        func click(_ key: String) throws {
            let point = try hover(key)
            rt.pointerDown(at: point, at: time)
            rt.pointerUp(at: point, at: time + 0.001)
            settle()
        }
        settle()
        _ = try hover("fresh-code-1")
        #expect(rt.state.first.copySide == .old)
        _ = try hover("fresh-code-2")
        #expect(rt.state.first.copySide == .new)
        rt.update(at: time) { state, _ in state.useSecond = true }
        settle()
        _ = try hover("fresh-code-1")
        #expect(rt.state.second.copySide == .old)
        #expect(rt.state.first.copySide == .new)
        try click("fresh-n-0")
        try click("fresh-n-0-plus")
        #expect(rt.state.calls == ["second number", "second selection", "second comment"])
        #expect(rt.state.first.selectedRange == nil)
        #expect(rt.state.second.selectedRange != nil)

        _ = try hover("fresh-code-1")
        #expect(rt.state.second.copySide == .old)
        let empty = FileDiff.fromTexts(path: "a.rs", old: "one\n", new: "one\n")
        rt.update(at: time) { state, _ in
            state.first = DiffState(diff: empty)
            state.useSecond = false
        }
        settle()
        #expect(rt.element(byKey: "fresh-code-1") == nil)
        // The disappearing old-side cell must release the lens that received its enter.
        var departed = rt.state.second
        let adoptedNewSide = departed.hoverText(side: .new, cell: "probe", inside: true)
        #expect(adoptedNewSide)
    }

    @Test("Dragging across code copies one side and the original UTF-8 text", arguments: [false, true])
    @MainActor
    func copyCodeAcrossRows(wrap: Bool) throws {
        let first = "\tentry.real/alpha[β](é)"
        let last = "\tlast"
        let old = "\tbranch.old/α[15](x)"
        let new = "\tbranch.new/β[25](y)"
        let file = FileDiff.fromTexts(path: "file.rs", old: "head\n\(first)\n\(old)\n\(last)\ntail\n",
                                     new: "head\n\(first)\n\(new)\n\(last)\ntail\n")
        for mode in [DiffMode.unified, .split] {
            var state = DiffState(diff: file, mode: mode)
            state.wrap = wrap
            let width: Float = wrap ? (mode == .unified ? 248 : 450) : 800
            let rt = Runtime(state: state, viewport: Vec2(width, 560)) { state, cx in
                DiffView<DiffState>(key: "diff", kit: .neutral(dark: true), get: { $0 }, set: { $0 = $1 })
                    .build(state: state, cx: cx)
            }
            var t = 0.0
            func tick() { t += 1.0 / 60; _ = rt.frame(at: t) }
            for _ in 0..<3 { tick() }

            let sides: [DiffSide] = mode == .unified ? [.new] : [.old, .new]
            for side in sides {
                func textPoint(line: Int, start: Bool) throws -> Vec2 {
                    let row = try #require(rt.element(byKey: "diff-df0.c\(line)"))
                    let prefix = mode == .unified ? "diff-code-" : "diff-ccode-\(side == .old ? "o" : "n")-"
                    let code = try #require(rt.elements().first {
                        $0.path.hasPrefix(row.path + "/") && $0.key?.hasPrefix(prefix) == true
                    })
                    let bounds = code.rect
                    let x = start ? bounds[0] + 12.5 : bounds[0] + min(212, bounds[2] - 5)
                    let y = start ? bounds[1] + 6 : bounds[1] + bounds[3] - 7
                    return Vec2(x, y)
                }
                let from = try textPoint(line: 2, start: true)
                let to = try textPoint(line: 4, start: false)
                rt.pointerMove(to: from, at: t)
                tick()
                rt.pointerDown(at: from, at: t)
                tick()
                for i in 1...8 {
                    let f = Float(i) / 8
                    rt.pointerMove(to: Vec2(from.x + (to.x - from.x) * f, from.y + (to.y - from.y) * f), at: t)
                    tick()
                }
                rt.pointerUp(at: to, at: t)
                tick()
                let expected = [first, side == .old ? old : new, last].joined(separator: "\n")
                #expect(rt.selectedText() == expected)
                let copy = try Chord.parse("mod+c")
                let handled = rt.keyDown(KeyEvent(key: copy.key, mods: copy.mods), at: t)
                #expect(handled)
                #expect(rt.clipboard.text == expected)
            }
        }
    }

    @Test("A pruned split cell releases its copy side when the pointer stays over the scrolling view")
    @MainActor
    func copyAfterHoveringAnUnmountedCell() throws {
        let old = (1...4_000).map { "let line_\($0) = old_\($0)\n" }.joined()
        let new = (1...4_000).map { i in
            i.isMultiple(of: 3) ? "let line_\(i) = new_\(i)\n" : "let line_\(i) = old_\(i)\n"
        }.joined()
        let file = FileDiff.fromTexts(path: "a.rs", old: old, new: new, context: 4_000)
        let kit = Kit.neutral(dark: true)
        let rt = Runtime(state: DiffState(diff: file, mode: .split), viewport: Vec2(800, 650)) { state, cx in
            DiffView<DiffState>(key: "dv", kit: kit, get: { $0 }, set: { $0 = $1 })
                .viewportHeight(600).build(state: state, cx: cx)
        }
        var t = 0.0
        func advance(_ frames: Int = 1) {
            for _ in 0..<frames {
                t += 1.0 / 120
                _ = rt.frame(at: t)
            }
        }
        func visibleCell(_ prefix: String) throws -> ElementInfo {
            try #require(rt.elements().first {
                guard let key = $0.key, !$0.exiting else { return false }
                return key.hasPrefix(prefix) && !key.hasSuffix("-text") && (150..<300).contains($0.rect[1])
            })
        }

        advance(3)
        let oldCell = try visibleCell("dv-ccode-o-")
        let oldKey = try #require(oldCell.key)
        let pointer = Vec2(oldCell.rect[0] + 22, oldCell.rect[1] + 8)
        rt.pointerMove(to: pointer, at: t)
        advance(3)
        #expect(rt.state.copySide == .old)
        rt.wheel(WheelEvent(dx: 0, dy: -50_000), at: pointer, now: t)
        advance(35)
        #expect(rt.element(byKey: oldKey) == nil)

        let newCell = try visibleCell("dv-scode-n-")
        let newKey = try #require(newCell.key)
        let expected = try #require(rt.element(byKey: newKey + "-text")?.text)
        #expect(expected.contains(" = new_"))
        let start = Vec2(newCell.rect[0] + 12.5, newCell.rect[1] + 8)
        let end = Vec2(newCell.rect[0] + newCell.rect[2] - 4, start.y)
        rt.pointerMove(to: start, at: t)
        advance(2)
        let copySide = rt.state.copySide
        #expect(copySide == .new)
        rt.pointerDown(at: start, at: t)
        advance()
        rt.pointerMove(to: end, at: t)
        advance()
        rt.pointerUp(at: end, at: t)
        advance()
        let selected = rt.selectedText()
        #expect(selected == expected)
        let copy = try Chord.parse("mod+c")
        let handled = rt.keyDown(KeyEvent(key: copy.key, mods: copy.mods), at: t)
        #expect(handled)
        let copied = rt.clipboard.text
        #expect(copied == expected)
    }
}
