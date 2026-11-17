import Testing
@testable import Rune
import RuneMotion

@Suite("Sparse flattened node snapshots")
struct FlatNodeStorageTests {
    @Test func ordinaryNodesBorrowElementsAndCopiesIsolateWrites() throws {
        var branch: El<Int> = col().key("parent")
        branch = branch.child(text("original").key("leaf"))
        branch = branch.child(text("other").key("sibling"))
        let rt = Runtime(state: 0, viewport: Vec2(160, 120), pixelScale: 1, systemDark: true) { _, _ in branch }
        _ = rt.frame(at: 0)
        let original = try #require(rt.flatNodes.first { $0.key == "leaf" })
        #expect(original.cold.isEmpty && original.element.hasSiblings)
        var copy = original
        copy.el.plainText = "changed"
        copy.scrollShift = Vec2(4, 8)
        copy.activeClipFades = [EdgeFadeSpec(rect: .zero, widths: .one, strengths: .one)]
        #expect(copy.el.plainText == "changed" && !copy.element.hasSiblings)
        #expect(copy.activeClipFades.count == 1 && copy.scrollShift == Vec2(4, 8))
        let withFade = copy
        copy.activeClipFades = []
        #expect(copy.cold.isEmpty && withFade.activeClipFades.count == 1)
        #expect(original.cold.isEmpty && original.activeClipFades.isEmpty)
        #expect(original.el.plainText == "original" && original.scrollShift == .zero)
        #expect(branch.children[0].plainText == "original")
    }

    @Test func memoPathReuseTracksReorderDuplicateKeysAndEditedChildren() throws {
        let memo = MemoCache()
        func group(_ epoch: Int) -> El<Int> {
            memo.getOrBuild(id: "memo", deps: epoch) { () -> El<Int> in
                col()
                    .child(text("first").key("row"))
                    .child(text("second").key("row").onClick { $0 += 10 + epoch })
                    .child(el().key("nested").child(text("old").key("field")))
            }.element
        }
        let rt = Runtime(state: 0, viewport: Vec2(160, 120), pixelScale: 1, systemDark: true) { step, _ -> El<Int> in
            let epoch = step == 3 ? 1 : 0
            var body = group(epoch)
            if step == 2 { body.children[2].children[0] = text("edited").key("new-field") }
            let neighbor: El<Int> = el().key("neighbor").h(Float(2 + step))
            return step == 1 ? col().key("root").child(body).child(neighbor) :
                col().key("root").child(neighbor).child(body)
        }
        for step in 0...3 {
            let time = Double(step) / 60
            if step > 0 { rt.update(at: time) { state, _ in state = step } }
            _ = rt.frame(at: time)
            let parent = try #require(rt.flatNodes.first { $0.key == "memo" })
            let row = try #require(rt.flatNodes.first { $0.key == "row#dup1" })
            #expect(row.parentIndex == parent.index)
            #expect(row.path == "/@root/@memo/@row#dup1")
            #expect(row.nodeId == NodeId.hash(row.path))
            var pressed = 0
            var tx = Tx()
            row.el.handlers.onClick?(&pressed, &tx)
            #expect(pressed == (step == 3 ? 11 : 10))
            let field = try #require(rt.flatNodes.first { $0.key == (step == 2 ? "new-field" : "field") })
            #expect(field.path.hasSuffix(step == 2 ? "/@nested/@new-field" : "/@nested/@field"))
            #expect(field.el.plainText == (step == 2 ? "edited" : "old"))
        }
    }

    @Test func reservedSuffixesStayDistinctAcrossRetainedBuilds() throws {
        let memo = MemoCache()
        let stable = memo.getOrBuild(id: "stable", deps: 0) { () -> El<Int> in
            col().child(text("left").key("a")).child(text("right").key("b"))
        }.element
        let source = ["row", "row", "row#dup1", "row"]
        func duplicates(_ tick: Int) -> El<Int> {
            var group: El<Int> = col().key("rows")
            for (i, key) in source.enumerated() {
                group = group.child(el().key(key).size(12, Float(i + tick + 4)).onClick { $0 = i + tick })
            }
            return group
        }
        let rt = Runtime(state: 0, viewport: Vec2(240, 260), pixelScale: 1) { tick, _ in
            col().key("root").child(stable).child(duplicates(tick))
        }
        for tick in 0...1 {
            if tick > 0 { rt.update(at: 0.1) { state, _ in state = tick } }
            _ = rt.frame(at: Double(tick) * 0.1)
            #expect(rt.lastKeyDiagnostics.map(\.count) == [3])
            #expect(rt.siblingKeyWarnings().map(\.count) == [3])
            #expect(rt.keyWarnings.count == 2)
            let branch = try #require(rt.flatNodes.first { $0.key == "stable" }).el
            #expect(branch.memoLayoutChildren?.matches(branch.children) == true)
            let head = try #require(rt.flatNodes.first { $0.key == "rows" }).index
            let children = rt.flatNodes.filter { $0.parentIndex == head }
            #expect(children.compactMap(\.key) == ["row", "row#dup2", "row#dup1", "row#dup3"])
            #expect(Set(children.map(\.nodeId)).count == 4)
            for (i, child) in children.enumerated() {
                #expect(child.nodeId == NodeId.hash(child.path))
                #expect(child.localRect.height == Float(i + tick + 4))
                var pressed = -1
                var tx = Tx()
                child.el.handlers.onClick?(&pressed, &tx)
                #expect(pressed == i + tick)
            }
        }
        rt.viewport = Vec2(250, 260)
        _ = rt.frame(at: 0.2)
        #expect(rt.siblingKeyWarnings().map(\.count) == [3])
    }

    @Test func mountedIndexedRowsRepairTheirOwnDescendants() throws {
        let rt = Runtime(state: 0, viewport: Vec2(200, 160), pixelScale: 1) { _, _ -> El<Int> in
            let list: El<Int> = col().key("list").virtualRows(12, 40, key: { _, i in "r\(i)" }) { _, _ in
                col().h(40).child(el().key("a")).child(el().key("a")).child(el().key("a#dup1"))
            }
            return col().key("scroll").wFull().hFull().scrollY().child(list)
        }
        _ = rt.frame(at: 0)
        let row = try #require(rt.flatNodes.first { $0.key == "r0" })
        let children = rt.flatNodes.filter { $0.parentIndex == row.index }
        #expect(children.compactMap(\.key) == ["a", "a#dup2", "a#dup1"])
        #expect(Set(children.map(\.nodeId)).count == 3)
        #expect(rt.lastKeyDiagnostics.contains { $0.key == "a" && $0.count == 2 })
    }
}
