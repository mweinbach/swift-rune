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
        #expect(FileTree.fileIcon(for: "source.KT") == KitIcons.file)

        let model = FileTree().build([("a", 1), ("a/b", 2)])
        #expect(model.count == 2)
        #expect(model.get("a")?.isDirectory == true)
        #expect(model.get("a")?.data == nil)
        #expect(model.get("a/b")?.isDirectory == false)
    }

    @Test("Tree lookup, filtering, and selection preserve the original UTF-8 ID")
    func distinctUnicodeTreeIDs() {
        let composed = "\u{e9}"
        let decomposed = "e\u{301}"
        let first = composed + "/child"
        let second = decomposed + "/child"
        func bytes(_ id: String) -> [UInt8] { Array(id.utf8) }

        var model = TreeModel<Int>(multiSelect: true)
        let firstRoot = model.insert(parent: nil, id: composed, data: 1)
        #expect(firstRoot)
        #expect(!model.contains(decomposed))
        let missingParent = model.insert(parent: decomposed, id: second, data: 20)
        #expect(!missingParent)
        model.insert(parent: nil, id: decomposed, data: 2)
        model.insert(parent: composed, id: first, data: 10)
        model.insert(parent: decomposed, id: second, data: 20)
        let duplicate = model.insert(parent: nil, id: composed, data: 3)
        #expect(!duplicate)
        model.update(second) { $0 += 1 }
        #expect(model.get(first) == 10 && model.get(second) == 21)
        #expect(model.parent(of: second).map(bytes) == bytes(decomposed))
        #expect(model.children(of: composed).map(bytes) == [bytes(first)])
        model.setExpanded(decomposed, true)
        #expect(model.visibleRow(of: first) == nil)
        #expect(model.visibleRow(of: second) == 2)
        #expect(model.visibleID(at: 2).map(bytes) == bytes(second))
        model.select(first)
        model.setSelected(second, true)
        #expect(model.selectedIDs.map(bytes) == [bytes(first), bytes(second)])
        #expect(model.cursorID.map(bytes) == bytes(second))
        model.filter { $0 == 10 }
        #expect(model.visibleCount == 2 && model.visibleRow(of: first) == 1)
        #expect(model.isMatch(first) && !model.isMatch(second))
        #expect(model.visibleRow(of: second) == nil && model.cursorID == nil)
        var tx = Tx()
        #expect(model.reveal(second, tx: &tx))
        #expect(model.row(at: 3)?.row.id.utf8.elementsEqual(second.utf8) == true)
        #expect(!model.isSelected(first) && model.isSelected(second))
        #expect(model.handleKey(KeyEvent(key: .enter), label: String.init, tx: &tx) == .open(second))
        #expect(Set([TreeKey.open(first), .open(second)]).count == 2)
        #expect(TreeRow(id: first, depth: 1) != TreeRow(id: second, depth: 1))
    }

    @Test("File trees preserve byte-distinct paths, duplicate precedence, and slash boundaries")
    func distinctUnicodeFilePaths() {
        let composed = "\u{e9}"
        let decomposed = "e\u{301}"
        let leadingMark = "\u{301}notes"
        let paths = [(composed + "/a", 1), (decomposed + "/a", 2), (composed + "/a", 3),
                     ("//marks//" + leadingMark + "/", 4), ("mixed/" + composed + "/b", 5),
                     ("mixed/" + decomposed, 6)]
        let builder = FileTree(compactFolders: false)
        var model = builder.build(paths)
        model.expandAll()
        #expect(model.visibleCount == 10)
        #expect(model.get(composed + "/a")?.data == 1)
        #expect(model.get(decomposed + "/a")?.data == 2)
        #expect(model.get("marks/" + leadingMark)?.name.utf8.elementsEqual(leadingMark.utf8) == true)
        #expect(model.depth(of: "marks/" + leadingMark) == 1)
        #expect(model.get("mixed/" + composed)?.isDirectory == true)
        #expect(model.get("mixed/" + decomposed)?.data == 6)
        #expect(FileNode<Int>(name: "x", path: composed, isDirectory: true)
                    != FileNode<Int>(name: "x", path: decomposed, isDirectory: true))
        let mixed = builder.buildTreeItems(paths).first { $0.id == "mixed" }
        #expect(mixed?.children.map { Array($0.id.utf8) } ==
                [Array(("mixed/" + composed).utf8), Array(("mixed/" + decomposed).utf8)])
        let compacted = FileTree().build([(composed + "/dir/a", 1), (decomposed + "/dir/b", 2)])
        #expect(compacted.visibleCount == 2)
        #expect(compacted.children(of: composed + "/dir").map { Array($0.utf8) } == [Array((composed + "/dir/a").utf8)])
        #expect(compacted.children(of: decomposed + "/dir").map { Array($0.utf8) } == [Array((decomposed + "/dir/b").utf8)])
    }

    @Test("Legacy string tree expansion and selection use the spelling the caller supplied")
    func legacyTreeProjectsStoredUnicodeIDs() throws {
        let composed = "\u{e9}"
        let decomposed = "e\u{301}"
        let view: El<[String]> = Kit.neutral(dark: true).fileTree(
            key: "files", paths: [composed + "/a", decomposed + "/b"],
            expanded: [composed], selected: decomposed, onToggle: { _, _ in }, onSelect: { $0.append($1) }
        )
        func row(_ id: String) -> El<[String]>? {
            view.children.first { $0.keyId?.utf8.elementsEqual(("files-" + id).utf8) == true }
        }
        #expect(view.children.count == 3)
        #expect(row(composed)?.a11yExpanded == true && row(composed)?.itemSelected == false)
        #expect(row(decomposed)?.a11yExpanded == false && row(decomposed)?.itemSelected == true)
        #expect(row(composed + "/a") != nil && row(decomposed + "/b") == nil)
        let rt = Runtime(state: [String](), viewport: Vec2(200, 120)) { _, _ in view }
        rt.frame(at: 0)
        let first = try #require(rt.element(byKey: "files-" + composed))
        let second = try #require(rt.element(byKey: "files-" + decomposed))
        #expect(first.path != second.path && first.rect[1] != second.rect[1])
        #expect(rt.accessibilityAction(first.path, .press, at: 0.1))
        #expect(rt.accessibilityAction("files-" + decomposed, .press, at: 0.2))
        #expect(rt.state.map { Array($0.utf8) } == [Array(composed.utf8), Array(decomposed.utf8)])
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
        _ = rt.keyDown(KeyEvent(key: .enter), isRepeat: true, at: 0.1)
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
        _ = rt.keyDown(KeyEvent(key: .text("c")), at: 2)
        #expect(rt.state.files.cursorID == "Cargo.toml")
    }

    @Test("Tree pages use its nested viewport and equal-count reorders update virtual keys")
    func nestedViewportAndReorderedRows() {
        struct State {
            var files = TreeModel<Int>(key: "files")
            var treeHeight: Float = 96
        }
        var state = State()
        for i in 0..<200 { state.files.insert(parent: nil, id: String(i), data: i) }
        let kit = Kit.neutral(dark: true)
        var active: String?
        let rt = Runtime(state: state, viewport: Vec2(320, 600), systemDark: true) { state, cx in
            let tree = Tree(\State.files, label: { String($0) }).build(state, cx: cx, kit: kit)
            active = tree.a11yActiveDescendant
            return col().size(320, 600).child(tree.h(state.treeHeight))
        }
        rt.frame(at: 0)
        #expect(rt.state.files.viewport == 96)
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0)
        _ = rt.keyDown(KeyEvent(key: .home), at: 0)
        _ = rt.keyDown(KeyEvent(key: .pageDown), at: 0)
        rt.frame(at: 0)
        #expect(active == "3")
        rt.update { state, _ in state.treeHeight = 168 }
        rt.frame(at: 0)
        #expect(rt.state.files.viewport == 168)
        _ = rt.keyDown(KeyEvent(key: .pageDown), at: 0)
        rt.frame(at: 0)
        #expect(active == "9")

        rt.update { state, _ in state.files.sortBy(>) }
        _ = rt.keyDown(KeyEvent(key: .home), at: 0)
        for i in 1...40 { rt.frame(at: Double(i) / 60) }
        #expect(active == "199")
        let row = rt.element(byKey: "199")
        #expect(row?.itemSelected == true)
        #expect(row?.visible[3] == 24)
        #expect(row?.visible[1] == 0)
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

    @Test("Multi-select extends with Shift, toggles rows and selects all with the primary modifier")
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
        let primary = RuneKitTestKey.primaryMods()
        rt.pointerDown(at: pt, mods: primary, at: 0)
        rt.pointerUp(at: pt, mods: primary, at: 0)
        rt.frame(at: 0)
        #expect(rt.state.files.selectedIDs.count == 4)

        press(rt, .command("a"), mods: primary)
        #expect(rt.state.files.selectedIDs.count == rt.state.files.visibleCount)
        press(rt, .home)
        press(rt, .command("a"), mods: Mods(alt: true))
        #expect(rt.state.files.selectedIDs == ["assets"])
        press(rt, .command("a"))
        #expect(rt.state.files.selectedIDs.count == rt.state.files.visibleCount)
        press(rt, .home)
        press(rt, .text("a"), mods: primary)
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
        let style = TreeStyle.fromKit(kit).chevronOnlyFolders(true).guidesOnHover(0.5).fadeLongLabels(24)
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

        let guide = itemEl.children.first { $0.keyId == "guide0" }
        #expect(guide?.isA11yHidden == true)
        #expect(guide?.groupOpacity?.rest == 0)
        #expect(guide?.groupOpacity?.hovered == 0.5)
        let label = itemEl.children.first { $0.keyId == "label" }
        #expect(label?.truncateFadeEm == 24 / style.labelFont.size)
        #expect(label?.isHelpWhenTruncated == true)
        #expect(label?.richSpans?.first?.pad == 1)
        let counts = itemEl.children.first { $0.keyId == "changes" }
        #expect(counts?.children.first?.textStyle.features == "'tnum' 1")

        let folder = TreeRowItem<Int>("İstanbul").highlight("istanbul")
            .build(kit: kit, row: row.expanded(false), style: style)
        let glyph = folder.children.first { $0.keyId == "chevron" }?.children.first
        #expect(glyph?.iconRotation == -Float.pi * 0.5)
        #expect(glyph?.mirrorInRtl == true)
        #expect(folder.children.first { $0.keyId == "label" }?.richSpans == nil)

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

    @Test("Byte-distinct file IDs retain their rows, callbacks and accessibility targets through a reorder and reveal")
    func byteDistinctTreeRows() throws {
        let composed = "src/\u{e9}.rs"
        let decomposed = "src/e\u{301}.rs"
        let literal = "src/~utf8~c3a92e7273"
        func bytes(_ value: String?) -> [UInt8]? { value.map { Array($0.utf8) } }
        struct State {
            var files = TreeModel<Int>(key: "files")
            var picks: [String] = []
        }
        var state = State()
        let addedFirst = state.files.insert(parent: nil, id: composed, data: 0)
        let addedSecond = state.files.insert(parent: nil, id: decomposed, data: 201)
        let addedLiteral = state.files.insert(parent: nil, id: literal, data: 202)
        #expect(addedFirst && addedSecond && addedLiteral)
        for i in 1...200 { state.files.insert(parent: nil, id: "row-\(i)", data: i) }
        let kit = Kit.neutral(dark: true)
        let rt = Runtime(state: state, viewport: Vec2(320, 96)) { state, cx in
            Tree(\State.files, label: { "File \($0)" })
                .onSelect { state, id, _ in state.picks.append(id) }
                .build(state, cx: cx, kit: kit)
                .size(320, 96)
        }
        rt.frame(at: 0)
        let first = try #require(rt.element(byKey: composed))
        let second = try #require(rt.element(byKey: decomposed))
        #expect(bytes(first.key) == bytes(composed))
        #expect(bytes(second.key) == bytes(decomposed))
        #expect(first.label == "File 0")
        #expect(second.label == "File 201")
        #expect(rt.element(byKey: literal)?.label == "File 202")
        #expect(first.rect == [0, 0, 320, 24])
        #expect(second.rect == [0, 24, 320, 24])

        #expect(rt.accessibilityAction("files", .focus, at: 0.01))
        #expect(rt.keyDown(KeyEvent(key: .home), at: 0.02))
        #expect(rt.keyDown(KeyEvent(key: .arrowDown), at: 0.03))
        rt.frame(at: 0.04)
        #expect(rt.state.picks.map { Array($0.utf8) } == [Array(composed.utf8), Array(decomposed.utf8)])
        #expect(rt.element(byKey: composed)?.itemSelected == false)
        #expect(rt.element(byKey: decomposed)?.itemSelected == true)
        let active = rt.accessibilitySnapshot().activeDescendant
        #expect(bytes(active) == bytes(decomposed))

        #expect(rt.accessibilityAction(composed, .press, at: 0.1))
        rt.frame(at: 0.11)
        #expect(bytes(rt.state.files.cursorID) == bytes(composed))
        #expect(rt.accessibilityAction(decomposed, .press, at: 0.12))
        rt.frame(at: 0.13)
        #expect(bytes(rt.state.files.cursorID) == bytes(decomposed))
        #expect(rt.accessibilityAction(literal, .press, at: 0.131))
        rt.frame(at: 0.132)
        #expect(bytes(rt.state.files.cursorID) == bytes(literal))
        let point = Vec2(first.rect[0] + 70, first.rect[1] + 12)
        rt.pointerDown(at: point, at: 0.14)
        rt.pointerUp(at: point, at: 0.15)
        rt.frame(at: 0.16)
        #expect(bytes(rt.state.files.cursorID) == bytes(composed))

        rt.update(at: 0.2) { state, _ in state.files.sortBy(<) }
        rt.frame(at: 0.21)
        #expect(rt.element(byKey: decomposed)?.exiting != false)
        rt.update(at: 0.3) { state, tx in
            let found = state.files.reveal(decomposed, tx: &tx)
            #expect(found)
        }
        for i in 1...60 { rt.frame(at: 0.3 + Double(i) / 60) }
        let revealed = try #require(rt.element(byKey: decomposed))
        #expect(bytes(revealed.key) == bytes(decomposed))
        #expect(revealed.visible == [0, 72, 320, 24])
        #expect(revealed.itemSelected)
        #expect(rt.element(byKey: composed) == nil)
    }

    @Test("Sibling trees with different UTF-8 scope names reveal their own rows")
    func byteDistinctTreeScopes() throws {
        let left = "files-\u{e9}"
        let right = "files-e\u{301}"
        func model(_ key: String) -> TreeModel<Int> {
            var model = TreeModel<Int>(key: key)
            for i in 0..<200 { model.insert(parent: nil, id: "row-\(i)", data: i) }
            return model
        }
        struct State {
            var left: TreeModel<Int>
            var right: TreeModel<Int>
        }
        let kit = Kit.neutral(dark: true)
        let rt = Runtime(state: State(left: model(left), right: model(right)), viewport: Vec2(320, 96)) { state, cx in
            row()
                .child(Tree(\State.left, label: String.init).build(state, cx: cx, kit: kit).size(160, 96))
                .child(Tree(\State.right, label: String.init).build(state, cx: cx, kit: kit).size(160, 96))
                .size(320, 96)
        }
        rt.frame(at: 0)
        let leftRoot = try #require(rt.element(byKey: left))
        let rightRoot = try #require(rt.element(byKey: right))
        #expect(leftRoot.path != rightRoot.path)
        #expect(leftRoot.rect[0] == 0 && rightRoot.rect[0] == 160)
        rt.update(at: 0.1) { state, tx in
            let found = state.right.reveal("row-199", tx: &tx)
            #expect(found)
        }
        for i in 1...60 { rt.frame(at: 0.1 + Double(i) / 60) }
        let rows = rt.elements().filter { $0.visible[3] > 0 && !$0.exiting }
        #expect(rows.contains { $0.key == "row-0" && $0.rect[0] == 0 })
        #expect(rows.contains { $0.key == "row-199" && $0.rect[0] == 160 && $0.itemSelected })
        #expect(!rows.contains { $0.key == "row-199" && $0.rect[0] == 0 })
    }
}
