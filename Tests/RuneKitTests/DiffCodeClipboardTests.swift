import Rune
import RuneKit
import Testing

@Suite("Diff code selection")
struct DiffCodeClipboardTests {
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
}
