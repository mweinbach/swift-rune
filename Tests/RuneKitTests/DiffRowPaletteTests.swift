import Rune
import RuneKit
import Testing

@Suite("Diff row palette")
@MainActor
struct DiffRowPaletteTests {
    private struct State {
        var kit: Kit
        var diff: DiffState
        var tints = DiffTints()
    }

    private func runtime(dark: Bool) -> Runtime<State> {
        let file = FileDiff.fromTexts(path: "colors.txt", old: "keep\nleft old value\nend\n",
                                      new: "keep\nleft new value\nend\n")
        let rt = Runtime(state: State(kit: .neutral(dark: dark), diff: DiffState(diff: file)),
                         viewport: Vec2(600, 320), pixelScale: 1, systemDark: dark) { state, cx in
            DiffView(key: "diff", kit: state.kit, state: \State.diff)
                .tints(state.tints)
                .build(state: state, cx: cx)
        }
        settle(rt, at: 0)
        return rt
    }

    private func settle(_ rt: Runtime<State>, at time: Double) {
        for tick in 0...20 { _ = rt.frame(at: time + Double(tick) / 30) }
    }

    private func checkRow(_ rt: Runtime<State>, _ index: Int, side: DiffSide, line: String,
                          gutter: String, number: String, bar: String) throws {
        let row = try #require(rt.element(byKey: "diff-row-\(index)"))
        let strip = try #require(rt.element(byKey: "diff-gutter-\(index)"))
        let old = try #require(rt.element(byKey: "diff-o-\(index)"))
        let new = try #require(rt.element(byKey: "diff-n-\(index)"))
        let marker = rt.elements().first {
            $0.path.hasPrefix(strip.path + "/") && $0.rect[0] == strip.rect[0] && $0.rect[2] == 3
        }
        #expect(old.rect[0] == strip.rect[0] + 3)
        #expect(row.fill.hex() == line)
        #expect(strip.fill.hex() == gutter)
        #expect((marker?.fill ?? .transparent).hex() == bar)
        #expect((side == .old ? old : new).textColor?.hex() == number)
        // In unified mode the shared gutter paints the background for both number columns.
        #expect(old.fill.a == 0)
        #expect(new.fill.a == 0)
    }

    @Test("Unified rows and selections match the upstream neutral themes", arguments: [false, true])
    func neutralRows(dark: Bool) throws {
        let rt = runtime(dark: dark)
        // sRGBA8 from rune-kit c7bb7eb7 Runtime::elements() for this same three-line change.
        let base = dark ? "#1c1d20ff" : "#ffffffff"
        try checkRow(rt, 0, side: .new, line: base, gutter: base,
                     number: dark ? "#a2a5aacc" : "#606369cc", bar: "#00000000")
        try checkRow(rt, 1, side: .old, line: dark ? "#362a2bff" : "#f9ebe9ff",
                     gutter: dark ? "#443131ff" : "#f4dddaff",
                     number: dark ? "#e5918bff" : "#954946ff", bar: dark ? "#ff847dff" : "#a83634ff")
        let addBar = dark ? "#5dc879ff" : "#00792fff"
        try checkRow(rt, 2, side: .new, line: dark ? "#26312bff" : "#e8f1e9ff",
                     gutter: dark ? "#2b3b31ff" : "#d9e8daff", number: dark ? "#78be8aff" : "#347444ff", bar: addBar)

        rt.update(at: 1) { state, _ in state.diff.select(.line(DiffLineRef(side: .new, line: 2))) }
        settle(rt, at: 1)
        try checkRow(rt, 2, side: .new, line: dark ? "#2c3746ff" : "#dfe9f6ff",
                     gutter: dark ? "#35485fff" : "#c4d6eeff", number: dark ? "#eff0f2ff" : "#1a1c1fff", bar: addBar)
    }

    @Test("Changing the theme and overriding diff tints updates mounted rows and words")
    func themeAndOverrides() throws {
        let rt = runtime(dark: true)
        rt.update(at: 1) { state, _ in
            state.kit.c.bgBase = .rgba8(0x35, 0x29, 0x10, 0x63)
            state.kit.c.textMuted = .rgba8(0xb2, 0xc7, 0xdd, 0xb4)
            state.kit.c.success.icon = .rgba8(0x03, 0x8a, 0xd4, 0x29)
            state.kit.c.info.icon = .rgba8(0xf0, 0x80, 0x00, 0x80)
        }
        settle(rt, at: 1)
        // The base contributes its alpha to the row and gutter, and the muted text to the number.
        try checkRow(rt, 2, side: .new, line: "#37362a63", gutter: "#383d3763", number: "#519dd8b4", bar: "#038ad429")

        let addWord = Color(r: 1, g: 0, b: 1)
        let delWord = Color(r: 0, g: 1, b: 1)
        rt.update(at: 2) { state, _ in
            state.tints = DiffTints(addition: .rgba8(0x12, 0x34, 0x56, 0x78), deletion: .rgba8(0xab, 0xcd, 0xef, 0x89),
                                    additionWord: addWord, deletionWord: delWord)
        }
        settle(rt, at: 2)
        try checkRow(rt, 2, side: .new, line: "#12345678", gutter: "#12345678", number: "#519dd8b4", bar: "#038ad429")
        try checkRow(rt, 1, side: .old, line: "#abcdef89", gutter: "#abcdef89", number: "#ec9c9bb4", bar: "#ff847dff")
        let instances = rt.renderFrame(at: 2.8).instances
        for (index, color) in [(1, delWord), (2, addWord)] {
            let code = try #require(rt.element(byKey: "diff-code-\(index)")).rect
            let paintsWord = instances.contains { item in
                let middleY = item.rect.y + item.rect.w / 2
                let difference = item.fill - color.premul()
                return item.rect.x >= code[0] && (code[1]..<(code[1] + code[3])).contains(middleY)
                    && max(abs(difference.x), abs(difference.y), abs(difference.z), abs(difference.w)) < 0.00001
            }
            #expect(paintsWord, "Expected the word highlight in diff-code-\(index)")
        }

        rt.update(at: 3) { state, _ in state.diff.select(.line(DiffLineRef(side: .new, line: 2))) }
        settle(rt, at: 3)
        try checkRow(rt, 2, side: .new, line: "#573a1363", gutter: "#6c441463", number: "#eff0f2ff", bar: "#038ad429")
    }
}
