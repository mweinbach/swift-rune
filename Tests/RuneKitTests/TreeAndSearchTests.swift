import Foundation
import Testing
@testable import RuneKit
@testable import Rune

@Suite("RuneKit SearchFold, FileTree, TreeModel & TreeView Tests")
struct TreeAndSearchTests {
    // MARK: - SearchFold (crates/rune-kit/src/search.rs)

    @Test("SearchFold performs case, full-width ASCII, half-width kana, and asymmetric accent folding")
    func searchFoldBehavior() {
        let fold = SearchFold()

        // ASCII & full case folding
        #expect(fold.contains("Hello World", query: "world"))
        #expect(fold.contains("Straße", query: "STRASSE"))
        #expect(fold.contains("GROẞ", query: "gross"))
        #expect(fold.contains("λόγος", query: "ΛΌΓΟΣ"))
        #expect(fold.contains("İstanbul", query: "istanbul"))

        // Byte range mapping across variable-length fold ("ß" -> "ss")
        let s = "a ß b"
        let ranges = fold.findByteRanges(s, query: "SS")
        #expect(ranges.count == 1)
        #expect(String(s.utf8[s.utf8.index(s.utf8.startIndex, offsetBy: ranges[0].lowerBound)..<s.utf8.index(s.utf8.startIndex, offsetBy: ranges[0].upperBound)]) == "ß")

        // Full-width ASCII & ideographic space
        #expect(fold.contains("ＡＰＩ　Key", query: "api key"))

        // Half-width katakana + voiced marks vs full-width katakana, and hiragana separation
        #expect(fold.contains("ﾃｽﾄ", query: "テスト"))
        #expect(fold.contains("ﾊﾞﾋﾞﾌﾞﾍﾞﾎﾞ", query: "バビブベボ"))
        #expect(fold.contains("ﾊﾟﾋﾟﾌﾟﾍﾟﾎﾟ", query: "パピプペポ"))
        #expect(fold.contains("ｳﾞｧ", query: "ヴァ"))
        #expect(!fold.contains("てすと", query: "テスト"))

        // Asymmetric accents & plain Latin fold letters
        #expect(fold.contains("Việt Nam", query: "viet"))
        #expect(!fold.contains("Viet Nam", query: "việt"))
        #expect(fold.contains("Łódź", query: "lodz"))
        #expect(!fold.contains("lodz", query: "Łódź"))
        #expect(fold.contains("Æther", query: "aether"))
        #expect(fold.contains("œuvre", query: "oeuvre"))
        #expect(fold.contains("Søren", query: "soren"))

        // Empty/whitespace query matches everything
        #expect(fold.contains("anything", query: "   "))
        #expect(fold.findByteRanges("", query: "a").isEmpty)
        #expect(fold.findByteRanges("abc", query: "").isEmpty)
    }

    @Test("SearchFold applies Turkic I -> ı folding for tr/az languages")
    func searchFoldTurkic() {
        let tr = SearchFold.forLanguage("tr-TR")
        let az = SearchFold.forLanguage("az")
        let en = SearchFold.forLanguage("en-US")

        #expect(tr.contains("ISIK", query: "ışık") == false)
        #expect(tr.contains("IŞIK", query: "ı"))
        #expect(az.contains("İSTANBUL", query: "istanbul"))
        #expect(!tr.contains("I", query: "i"))
        #expect(en.contains("I", query: "i"))
    }

    // MARK: - Tree unit tests (crates/rune-kit/src/tree/tests.rs)

    @Test("TreeModel type-select jumps by prefix and repeated letter cycles across pause")
    func typingJumpsByPrefixAndRepeatedLetterCycles() {
        var m = TreeModel<String>()
        m.insert(parent: nil, id: "a", data: "alpha")
        m.insert(parent: "a", id: "a/1", data: "one")
        m.insert(parent: "a", id: "a/2", data: "two")
        m.insert(parent: nil, id: "b", data: "beta")
        m.insert(parent: nil, id: "c", data: "bravo")

        #expect(m.stepTypeAhead("b", at: 0.0, label: { $0 }) == 1)
        m.select("b")
        #expect(m.stepTypeAhead("b", at: 0.1, label: { $0 }) == 2)
        m.select("c")
        #expect(m.stepTypeAhead("r", at: 0.2, label: { $0 }) == nil)
        #expect(m.stepTypeAhead("b", at: 2.0, label: { $0 }) == 1)
        m.select("a")
        #expect(m.stepTypeAhead("b", at: 3.5, label: { $0 }) == 1)
        #expect(m.stepTypeAhead("r", at: 3.6, label: { $0 }) == 2)
    }

    @Test("FileTree.naturalCompare counts digits, ignores case, and breaks exact ties (#815)")
    func naturalOrderCountsDigitsAndTiebreaks() {
        var names = ["file10", "File2", "file1", "a", "B"]
        names.sort { FileTree.naturalCompare($0, $1) == .orderedAscending }
        #expect(names == ["a", "B", "file1", "File2", "file10"])

        // #815 exact-text tiebreak: "A" and "a" must not tie
        #expect(FileTree.naturalCompare("A", "a") != .orderedSame)
        #expect(FileTree.naturalCompare("A", "a") == .orderedAscending)
        #expect(FileTree.naturalCompare("a", "A") == .orderedDescending)
        #expect(FileTree.naturalCompare("same", "same") == .orderedSame)
    }

    @Test("FileTree.fileIcon handles dotless names and drops duplicate file-vs-folder paths")
    func fileIconAndDuplicatePaths() {
        #expect(FileTree.fileIcon(for: "go") == KitIcons.file)
        #expect(FileTree.fileIcon(for: "json") == KitIcons.file)
        #expect(FileTree.fileIcon(for: "lock") == KitIcons.file)
        #expect(FileTree.fileIcon(for: "main.go") == KitIcons.fileCode)
        #expect(FileTree.fileIcon(for: ".env") == KitIcons.fileText)
        #expect(FileTree.fileIcon(for: "logo.png") == KitIcons.fileImage)

        let model = FileTree().build([("a", 1), ("a/b", 2)])
        #expect(model.count == 2)
        #expect(model.get("a")?.isDirectory == true)
        #expect(model.get("a")?.data == nil)
        #expect(model.get("a/b")?.isDirectory == false)
    }

    // MARK: - Tree integration tests (crates/rune-kit/tests/tree.rs)

    private static let repoPaths: [String] = [
        "src/main.rs",
        "src/ui/tree/row.rs",
        "src/ui/tree/model.rs",
        "src/lib.rs",
        "README.md",
        "docs/guide/intro/start.md",
        "Cargo.toml",
        "assets/icon10.png",
        "assets/icon2.png",
    ]

    private func buildRepoModel() -> TreeModel<FileNode<(UInt32, UInt32)>> {
        FileTree().build(Self.repoPaths.map { ($0, (UInt32(1), UInt32(0))) })
    }

    private func outline(_ m: TreeModel<FileNode<(UInt32, UInt32)>>) -> [String] {
        (0..<m.visibleCount).map { i in
            let (n, r) = m.row(at: i)!
            let mark: String = switch r.expanded {
            case .some(true): "-"
            case .some(false): "+"
            case .none: " "
            }
            return String(repeating: "  ", count: Int(r.depth)) + mark + n.name
        }
    }

    @Test("Paths become a tree with folders first in natural order and compacted folders")
    func pathsBecomeTreeWithFoldersFirst() {
        var m = buildRepoModel()
        m.expandAll()
        #expect(outline(m) == [
            "-assets",
            "   icon2.png",
            "   icon10.png",
            "-docs/guide/intro",
            "   start.md",
            "-src",
            "  -ui/tree",
            "     model.rs",
            "     row.rs",
            "   lib.rs",
            "   main.rs",
            " Cargo.toml",
            " README.md",
        ])
        #expect(m.parent(of: "src/ui/tree/row.rs") == "src/ui/tree")
        #expect(m.get("docs/guide/intro")?.name == "docs/guide/intro")
        #expect(m.get("src/ui") == nil)
    }

    @Test("Compact folders and dirs-first can be turned off")
    func compactFoldersAndDirsFirstOff() {
        var m = FileTree().compactFolders(false).dirsFirst(false).build([
            ("b/c/d.rs", ()),
            ("a.rs", ()),
            ("c.rs", ()),
        ])
        m.expandAll()
        let names = (0..<m.visibleCount).map { m.row(at: $0)!.data.name }
        #expect(names == ["a.rs", "b", "c", "d.rs", "c.rs"])
    }

    @Test("Filter keeps ancestor folders open and restores folder state on clear")
    func filterKeepsFoldersOpenAndRestores() {
        var m = buildRepoModel()
        m.filter { $0.name.contains("row") }
        #expect(outline(m) == ["-src", "  -ui/tree", "     row.rs"])
        #expect(m.isMatch("src/ui/tree/row.rs") && !m.isMatch("src"))
        m.toggle("src/ui/tree")
        #expect(outline(m) == ["-src", "  +ui/tree"])
        m.clearFilter()
        #expect(outline(m) == ["+assets", "+docs/guide/intro", "+src", " Cargo.toml", " README.md"])
    }

    @Test("Matching folder shows as a leaf without non-matching children")
    func matchingFolderShowsWithoutOtherChildren() {
        var m = buildRepoModel()
        m.filter { $0.name == "assets" }
        #expect(outline(m) == [" assets"])
    }

    @Test("Closing a folder brings cursor and single selection up to the folder")
    func closingFolderBringsCursorUp() {
        var m = buildRepoModel()
        m.expandAll()
        m.select("src/ui/tree/row.rs")
        m.setExpanded("src", false)
        #expect(m.cursorID == "src")
        #expect(m.selectedIDs == ["src"])

        var multi = buildRepoModel().multiSelect(true)
        multi.expandAll()
        multi.select("src/ui/tree/row.rs")
        multi.setExpanded("src", false)
        var tx = Tx()
        _ = multi.handleKey(KeyEvent(key: .arrowDown, mods: Mods(shift: true)), label: { $0.name }, tx: &tx)
        #expect(multi.selectedIDs == ["src", "Cargo.toml"])
    }

    @Test("Filtering clears hidden cursor and reveal makes filtered-out row visible")
    func filteringClearsHiddenCursorAndRevealShowsRow() {
        var m = buildRepoModel()
        m.expandAll()
        m.select("README.md")
        #expect(m.visibleCount == 13)
        m.filter { $0.name.contains("row") }
        #expect(m.cursorID == nil)
        var tx = Tx()
        #expect(m.reveal("README.md", tx: &tx))
        #expect(m.visibleRow(of: "README.md") != nil)
    }

    // MARK: - Runtime TreeView tests

    private struct TreeAppState {
        var files: TreeModel<FileNode<(UInt32, UInt32)>>
        var picked: [String] = []
        var opened: [String] = []
    }

    private func makeTreeRuntime(_ model: TreeModel<FileNode<(UInt32, UInt32)>>) -> Runtime<TreeAppState> {
        let kit = Kit.neutral(dark: true)
        let rt = Runtime(
            state: TreeAppState(files: model),
            viewport: Vec2(320, 240),
            systemDark: true
        ) { state, cx in
            col().size(320, 240).child(
                Tree(\TreeAppState.files, label: { $0.name })
                    .name("Files")
                    .row { node, row in
                        TreeRowItem.file(node, row: row)
                            .changes(added: node.data?.0 ?? 0, removed: 0)
                    }
                    .onSelect { s, id, _ in s.picked.append(id) }
                    .onOpen { s, id, _ in s.opened.append(id) }
                    .build(state, cx: cx, kit: kit)
                    .h(240)
            )
        }
        rt.frame(at: 0)
        return rt
    }

    private func press(_ rt: Runtime<TreeAppState>, _ key: Key, mods: Mods = .none) {
        _ = rt.keyDown(KeyEvent(key: key, mods: mods), at: 0)
        rt.frame(at: 0)
    }

    private func focusTree(_ rt: Runtime<TreeAppState>) {
        press(rt, .tab)
        let focused = rt.elements().first { $0.focused }?.key
        #expect(focused == "files")
    }

    private func treeRows(_ rt: Runtime<TreeAppState>) -> [ElementInfo] {
        rt.elements().filter { ($0.level ?? 0) >= 1 && !$0.exiting && $0.label != nil }
    }

    @Test("Tree arrows move, open, close, climb, Home/End, and report selection")
    func arrowsMoveOpenCloseAndClimb() {
        let rt = makeTreeRuntime(buildRepoModel())
        focusTree(rt)
        press(rt, .arrowDown)
        #expect(rt.state.files.cursorID == "assets")
        press(rt, .arrowDown)
        press(rt, .arrowDown)
        #expect(rt.state.files.cursorID == "src")
        press(rt, .arrowRight)
        #expect(rt.state.files.isExpanded("src"))
        #expect(rt.state.files.cursorID == "src")
        press(rt, .arrowRight)
        #expect(rt.state.files.cursorID == "src/ui/tree")
        press(rt, .arrowRight)
        press(rt, .arrowRight)
        #expect(rt.state.files.cursorID == "src/ui/tree/model.rs")
        press(rt, .arrowRight)
        #expect(rt.state.files.cursorID == "src/ui/tree/model.rs")
        press(rt, .arrowLeft)
        #expect(rt.state.files.cursorID == "src/ui/tree")
        press(rt, .arrowLeft)
        #expect(!rt.state.files.isExpanded("src/ui/tree"))
        press(rt, .end)
        #expect(rt.state.files.cursorID == "README.md")
        press(rt, .home)
        #expect(rt.state.files.cursorID == "assets")
        press(rt, .arrowUp)
        #expect(rt.state.files.cursorID == "assets")
        #expect(rt.state.picked.last == "assets")
        #expect(rt.state.files.isSelected("assets") && !rt.state.files.isSelected("README.md"))
    }

    @Test("Return toggles folder and opens file; Space toggles folder")
    func returnTogglesFolderAndOpensFile() {
        let rt = makeTreeRuntime(buildRepoModel())
        focusTree(rt)
        press(rt, .end)
        press(rt, .enter)
        #expect(rt.state.opened == ["README.md"])
        press(rt, .home)
        press(rt, .enter)
        #expect(rt.state.files.isExpanded("assets"))
        press(rt, .text(" "))
        #expect(!rt.state.files.isExpanded("assets"))
    }

    @Test("Typing jumps to matching row name")
    func typingJumpsToName() {
        let rt = makeTreeRuntime(buildRepoModel())
        focusTree(rt)
        press(rt, .text("r"))
        #expect(rt.state.files.cursorID == "README.md")
        press(rt, .text("c"))
        #expect(rt.state.files.cursorID == "README.md")
    }

    @Test("Rows carry level, expanded state, and selection")
    func rowsCarryLevelOpenStateAndSelection() {
        var m = buildRepoModel()
        m.setExpanded("src", true)
        m.select("src/lib.rs")
        let rt = makeTreeRuntime(m)

        let treeEl = rt.element(byKey: "files")
        #expect(treeEl?.label == "Files")
        #expect(treeEl?.focusable == true)

        let rows = treeRows(rt)
        func find(_ label: String) -> ElementInfo {
            rows.first { $0.label == label }!
        }
        #expect(find("src").level == 1)
        #expect(find("src").expanded == true)
        #expect(find("assets").level == 1)
        #expect(find("assets").expanded == false)
        #expect(find("lib.rs").level == 2)
        #expect(find("lib.rs").expanded == nil)
        #expect(find("lib.rs").itemSelected == true)
        #expect(find("main.rs").itemSelected == false)
    }

    @Test("Click selects row, folder click toggles, and focuses tree")
    func clickSelectsAndFolderToggles() {
        let rt = makeTreeRuntime(buildRepoModel())
        func center(of label: String) -> Vec2 {
            let r = treeRows(rt).first { $0.label == label }!.rect
            return Vec2(r[0] + r[2] * 0.5, r[1] + r[3] * 0.5)
        }
        let srcPt = center(of: "src")
        rt.pointerDown(at: srcPt, at: 0)
        rt.pointerUp(at: srcPt, at: 0)
        rt.frame(at: 0)
        #expect(rt.state.files.isExpanded("src") && rt.state.files.isSelected("src"))
        #expect(rt.elements().first { $0.focused }?.key == "files")

        let mainPt = center(of: "main.rs")
        rt.pointerDown(at: mainPt, at: 0)
        rt.pointerUp(at: mainPt, at: 0)
        rt.frame(at: 0)
        #expect(rt.state.files.selectedIDs == ["src/main.rs"])
        #expect(rt.state.picked == ["src", "src/main.rs"])
    }

    @Test("Multi-select extends with Shift, toggles with Cmd-click, and selects all with Cmd-A")
    func multiSelectShiftAndCmd() {
        var m = buildRepoModel().multiSelect(true)
        m.expandAll()
        let rt = makeTreeRuntime(m)
        focusTree(rt)
        press(rt, .arrowDown)
        press(rt, .arrowDown, mods: Mods(shift: true))
        press(rt, .arrowDown, mods: Mods(shift: true))
        #expect(rt.state.files.selectedIDs == ["assets", "assets/icon2.png", "assets/icon10.png"])

        let libRect = treeRows(rt).first { $0.label == "lib.rs" }!.rect
        let pt = Vec2(libRect[0] + 40, libRect[1] + 5)
        rt.pointerDown(at: pt, mods: Mods(cmd: true), at: 0)
        rt.pointerUp(at: pt, mods: Mods(cmd: true), at: 0)
        rt.frame(at: 0)
        #expect(rt.state.files.selectedIDs.count == 4)

        press(rt, .command("a"), mods: Mods(cmd: true))
        #expect(rt.state.files.selectedIDs.count == rt.state.files.visibleCount)
    }

    @Test("50,000 rows build only visible window")
    func fiftyThousandRowsBuildOnlyVisibleWindow() {
        var paths: [(String, (UInt32, UInt32))] = []
        paths.reserveCapacity(50_000)
        for d in 0..<500 {
            for f in 0..<100 {
                paths.append(("pkg\(d)/file\(f).rs", (1, 0)))
            }
        }
        var m = FileTree().build(paths)
        m.expandAll()
        #expect(m.visibleCount == 50_500)
        let rt = makeTreeRuntime(m)
        let built = treeRows(rt).count
        #expect((10..<80).contains(built))
    }

    @Test("Reveal opens parent folder, selects, and scrolls to a far row in Runtime")
    func revealOpensSelectsAndScrollsToFarRow() {
        var paths: [(String, (UInt32, UInt32))] = []
        paths.reserveCapacity(50_000)
        for d in 0..<500 {
            for f in 0..<100 {
                paths.append(("pkg\(d)/file\(f).rs", (1, 0)))
            }
        }
        var m = FileTree().build(paths)
        m.collapseAll()

        let kit = Kit.neutral(dark: true)
        let rt = Runtime(
            state: TreeAppState(files: m),
            viewport: Vec2(320, 240),
            systemDark: true,
            onKey: { state, ev, tx in
                if ev.key == .f(1) {
                    return state.files.reveal("pkg321/file77.rs", tx: &tx)
                }
                return false
            }
        ) { state, cx in
            col().size(320, 240).child(
                Tree(\TreeAppState.files, label: { $0.name })
                    .row { node, row in TreeRowItem.file(node, row: row) }
                    .build(state, cx: cx, kit: kit)
                    .h(240)
            )
        }
        rt.frame(at: 0)
        _ = rt.keyDown(KeyEvent(key: .f(1)), at: 0)
        for f in 1..<40 {
            rt.frame(at: Double(f) / 60.0)
        }
        #expect(rt.state.files.isExpanded("pkg321") && rt.state.files.isSelected("pkg321/file77.rs"))
        #expect(rt.state.files.selected() == ["pkg321/file77.rs"])
        #expect(rt.state.files.cursor() == "pkg321/file77.rs")
        let row = treeRows(rt).first { $0.label == "file77.rs" }
        #expect(row != nil)
        if let row {
            #expect(row.visible[3] > 20.0 && row.visible[1] >= 0.0 && row.visible[1] + row.visible[3] <= 240.5)
            #expect(row.itemSelected)
        }
    }

    @Test("TreeRowItem renders highlight, changes, badge, dot, and chevronOnlyFolders")
    func treeRowItemBuilders() {
        let kit = Kit.neutral(dark: true)
        let style = TreeStyle.fromKit(kit).chevronOnlyFolders(true)
        let node = FileNode(name: "README.md", path: "README.md", isDirectory: false, data: (3, 1))
        let row = TreeRow(id: "README.md", depth: 1, expanded: nil, selected: true, cursor: true, matched: true, multi: true)

        let itemEl: El<Int> = TreeRowItem<Int>.file(node, row: row)
            .iconColor(kit.c.textAccent)
            .labelColor(kit.c.textStrong)
            .highlight("read")
            .changes(added: 3, removed: 1)
            .badge("M")
            .dot(kit.c.success.icon)
            .trailing(text("extra"))
            .build(kit: kit, row: row, style: style)
            .key("row")

        let rt = Runtime(state: 0, viewport: Vec2(320, 60), systemDark: true) { _, _ in
            itemEl
        }
        rt.frame(at: 0)
        #expect(rt.element(byKey: "row")?.itemSelected == true)
        #expect(rt.element(byKey: "badge")?.text == "M")
        #expect(rt.element(byKey: "added")?.text == "+3")
        #expect(rt.element(byKey: "removed")?.text == "\u{2212}1")
        #expect(rt.element(byKey: "dot") != nil)
    }

    @Test("TreeStyle builders customize metrics and colors")
    func treeStyleBuilders() {
        let kit = Kit.neutral(dark: true)
        let style = TreeStyle.fromKit(kit)
            .hover(kit.c.surfaceHover)
            .gap(8)
            .radius(6)
            .label(kit.ty.small, rest: kit.c.textMuted, selected: kit.c.textStrong)
            .fadeLongLabels(24)
            .chevronOnlyFolders(true)
            .chevron(KitIcons.chevronRight)
            .chevronColors(rest: kit.c.iconFaint, selected: kit.c.iconBase)
            .chevronNudge(1)
            .guidesOnHover(0.5)
        #expect(style.gap == 8)
        #expect(style.radius == 6)
        #expect(style.labelFade == 24)
        #expect(style.chevronOnly)
        #expect(style.chevronNudge == 1)
        #expect(style.guidesHover == 0.5)
    }

    @Test("PageDown with no cursor jumps to first row")
    func pageDownNoCursorStartsAtZero() {
        var m = buildRepoModel()
        var tx = Tx()
        #expect(m.cursorID == nil)
        let outcome = m.handleKey(KeyEvent(key: .pageDown), label: { $0.name }, tx: &tx)
        #expect(outcome == .handled)
        #expect(m.cursorID == m.visibleID(at: 0))
    }
}
