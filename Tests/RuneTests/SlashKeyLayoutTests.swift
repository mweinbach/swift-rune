import Testing
@testable import Rune
import RuneMotion

@Suite("Layout and highlight selectors with slash-containing keys")
struct SlashKeyLayoutTests {
    @Test(arguments: [false, true])
    func readsChooseFirstMatchAndKeepScope(indexed: Bool) throws {
        final class Reads {
            var first: [Float]?
            var literal: [Float]?
            var tailOfAncestor: [Float]?
            var other: [Float]?
            var missing: [Float]?
            var highlight: [Float]?
            var scopedHighlight: [Float]?
        }
        let reads = Reads()
        let runtime = Runtime<Int>(state: 0, viewport: Vec2(320, 400), pixelScale: 1) { _, cx in
            reads.first = cx.layout("folder/file.swift")
            reads.literal = cx.layout("pane/docs/folder/file.swift")
            reads.tailOfAncestor = cx.windowLayout("docs/folder/file.swift")
            reads.other = cx.layout("other/folder/file.swift")
            reads.missing = cx.layout("skipped/folder/file.swift")
            reads.highlight = cx.layout("find/match")
            reads.scopedHighlight = cx.layout("pane/docs/label/title/find/match")
            if indexed {
                for i in 0..<9 { _ = cx.layout("unmounted-\(i)") }
            }
            let scoped: El<Int> = col().key("pane/docs").itemsStart().children([
                col().child(el().key("folder/file.swift").size(47, 11)),
                text("matched words").key("label/title")
                    .textHighlight(TextHighlight(0..<7, bg: .white, key: "find/match"))
            ])
            return col().wFull().itemsStart().children([
                col().key("folder").child(el().key("file.swift").size(31, 11)),
                scoped,
                col().key("other").child(el().key("folder/file.swift").size(63, 11)),
                text("second match").key("find")
                    .textHighlight(TextHighlight(0..<6, bg: .white, key: "match"))
            ])
        }
        _ = runtime.frame(at: 0)
        #expect(reads.first?[2] == 31)
        #expect(reads.literal?[2] == 47)
        #expect(reads.literal == reads.tailOfAncestor)
        #expect(reads.other?[2] == 63)
        #expect(reads.missing == nil)

        let first = try #require(runtime.highlightTargetWithNode(selector: "pane/docs/label/title/find/match"))
        let second = try #require(runtime.highlightTargetWithNode(selector: "match"))
        let both = try #require(runtime.highlightTargetWithNode(selector: "find/match"))
        #expect(first.nodeIndex < second.nodeIndex)
        #expect(both.nodeIndex == first.nodeIndex)
        #expect(first.rect.width > 0 && second.rect.top > first.rect.top)
        #expect(both.rect.top == first.rect.top && both.rect.bottom == second.rect.bottom)
        #expect(reads.scopedHighlight == [first.rect.left, first.rect.top, first.rect.width, first.rect.height])
        #expect(reads.highlight == [both.rect.left, both.rect.top, both.rect.width, both.rect.height])
        #expect(runtime.highlightTargetWithNode(selector: "other/label/title/find/match") == nil)
    }

    @Test("Memo misses and hits resolve scoped rows and keyed text highlights like Cx")
    func memoScopedGeometryAndInvalidation() throws {
        final class Reads {
            var builds = 0
            var first: [Float]?
            var scoped: [Float]?
            var window: [Float]?
            var mark: [Float]?
        }
        let reads = Reads()
        let runtime = Runtime<Int>(state: 42, viewport: Vec2(320, 300), pixelScale: 1) { width, _ in
            let label: El<Int> = text("search result").key("file/title")
                .textHighlight(TextHighlight(0..<6, bg: .white, key: "find/hit"))
            let probe: El<Int> = memo("inspector", deps: 1) {
                reads.builds += 1
                reads.first = layoutRect("doc/file")
                reads.scoped = layoutRect("pane/sidebar/doc/file")
                reads.window = windowLayout("sidebar/doc/file")
                reads.mark = layoutRect("sidebar/file/title/find/hit")
                return el().h(1)
            }
            return col().wFull().itemsStart().children([
                col().key("doc").child(el().key("file").size(27, 16)),
                col().key("pane/sidebar").itemsStart().children([
                    el().key("doc/file").size(Float(width), 16), label
                ]),
                col().key("elsewhere").child(el().key("doc/file").size(71, 16)),
                probe
            ])
        }
        for i in 0..<4 { _ = runtime.frame(at: Double(i) / 60) }
        #expect(reads.first?[2] == 27)
        #expect(reads.scoped?[2] == 42)
        #expect(reads.window == reads.scoped)
        let mark = try #require(runtime.highlightTargetWithNode(selector: "sidebar/file/title/find/hit"))
        #expect(reads.mark == [mark.rect.left, mark.rect.top, mark.rect.width, mark.rect.height])

        let settledBuilds = reads.builds
        runtime.update(at: 0.1) { _, _ in }
        _ = runtime.frame(at: 0.1)
        #expect(reads.builds == settledBuilds)
        runtime.update(at: 0.2) { width, _ in width = 85 }
        for i in 0..<4 { _ = runtime.frame(at: 0.2 + Double(i) / 60) }
        #expect(reads.scoped?[2] == 85 && reads.window == reads.scoped)
        #expect(reads.builds > settledBuilds)
    }

    @Test("Two transforms of the same rect keep independent layout dependencies")
    func distinctTransformsOnOneKey() {
        let collector = LayoutReadCollector()
        let width = LayoutSame.make { $0[2] }
        let height = LayoutSame.make { $0[3] }
        collector.noteRead(key: "row/item", same: width)
        collector.noteRead(key: "row/item", same: height)
        collector.noteRead(key: "row/item", same: width)
        #expect(collector.reads.count == 2)
        #expect(collector.reads.contains { $0.moved([0, 0, 8, 10], [0, 0, 8, 20]) })
    }

    @Test("A memo pass resolves only requested geometry, including absent keys")
    func onlyRequestedMemoGeometry() {
        var queries: [MemoGeometry.Query] = []
        var selections = 0
        let lookup = MemoGeometry(resolve: { query in
            queries.append(query)
            return nil
        }, selection: {
            selections += 1
            return []
        })
        let read = MemoRead.layout(key: "absent/item", rect: nil)
        #expect(queries.isEmpty && selections == 0)
        #expect(read.matches(lookup) && read.matches(lookup))
        #expect(queries == [.layout("absent/item")])
        #expect(selections == 0)
        #expect(lookup.selectionBoxes == [] && lookup.selectionBoxes == [])
        #expect(selections == 1)
    }

    @Test("Retained candidates belong to the current node buffer and commit")
    func replacedNodesInSameCommit() {
        let original = ["first", "second"]
        let replacement = ["alternative", "keys"]
        var index = LayoutKeyIndex()
        index.prepare(nodes: original, stamp: 0, lookups: 1, keyOf: { $0 })
        #expect(index.indexIfValid(nodes: original, stamp: 0) == nil)
        index.prepare(nodes: original, stamp: 0, lookups: 1, keyOf: { $0 })
        #expect(index.indexIfValid(nodes: original, stamp: 0) != nil)
        #expect(index.indexIfValid(nodes: replacement, stamp: 0) == nil)
        #expect(index.indexIfValid(nodes: original, stamp: 1) == nil)
        index.prepare(nodes: replacement, stamp: 0, lookups: 9, keyOf: { $0 })
        let current = index.indexIfValid(nodes: replacement, stamp: 0)
        #expect(LayoutKeyIndex.firstMatch(selector: "keys", index: current, nodes: replacement,
                                          keyOf: { $0 }, parentOf: { _ in nil }) == 1)
        index.invalidate()
        #expect(index.indexIfValid(nodes: replacement, stamp: 0) == nil)
    }

    @Test("A repeated geometry read resolves one leaf and preserves other selector lookups")
    func cachesOnlyTheRequestedLeaf() {
        let nodes = ["root", "viewport", "other", "viewport"]
        var index = LayoutKeyIndex()
        var visited = 0
        func key(_ value: String) -> String? { visited += 1; return value }
        for _ in 0..<3 {
            index.prepare(nodes: nodes, stamp: 1, lookups: 1, selector: "viewport", keyOf: key)
            let current = index.indexIfValid(nodes: nodes, stamp: 1)
            #expect(LayoutKeyIndex.firstMatch(selector: "viewport", index: current, nodes: nodes,
                                               keyOf: key, parentOf: { _ in nil }) == 1)
        }
        #expect(visited == 2)
        let current = index.indexIfValid(nodes: nodes, stamp: 1)
        #expect(LayoutKeyIndex.firstMatch(selector: "other", index: current, nodes: nodes,
                                           keyOf: key, parentOf: { _ in nil }) == 2)
        #expect(LayoutKeyIndex.markedCandidates(selector: "highlight", index: current, nodes: nodes) == nil)
        let replacement = ["viewport"]
        index.prepare(nodes: replacement, stamp: 1, lookups: 1, selector: "viewport", keyOf: key)
        #expect(index.indexIfValid(nodes: nodes, stamp: 1) == nil)
        let updated = index.indexIfValid(nodes: replacement, stamp: 1)
        #expect(LayoutKeyIndex.firstMatch(selector: "viewport", index: updated, nodes: replacement,
                                           keyOf: key, parentOf: { _ in nil }) == 0)
    }

    @Test("Indexed highlight candidates stay in document order and visit each owner once")
    func deduplicatesOwnersAcrossLiteralAndScopedTails() {
        let marks = [["a/b/c", "b/c", "c", "c"], ["c"], ["a/b/c"]]
        var index = LayoutKeyIndex()
        index.build(nodes: marks, keyOf: { _ in nil }, highlightKeysOf: { $0 })
        #expect(LayoutKeyIndex.markedCandidates(selector: "a/b/c", index: index, nodes: marks) == [0, 1, 2])
        #expect(LayoutKeyIndex.markedCandidates(selector: "missing", index: index, nodes: marks) == [])
    }
}
