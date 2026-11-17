import Testing
@testable import Rune

@Suite("Selection snapshots in event transactions")
struct SelectionSnapshotTests {
    private final class RowBuilds {
        var count = 0
        var heard: [Int] = []
        var buildsAtDelivery: [Int] = []
    }

    private struct Model {
        let builds = RowBuilds()
        var secureMiddleRow = false
    }

    @Test func transactionsShareTheVirtualSelectionUntilTheTreeOrEndpointsChange() throws {
        let count = 1_000
        let runtime = Runtime(state: Model(), viewport: Vec2(220, 90)) { model, _ in
            col().wFull().hFull().scroll(stickBottom: false).child(
                col().wFull().key("list").selectionGroup().virtualRows(
                    count, 20, key: { _, index in "r\(index)" },
                    build: { model, index in
                        model.builds.count += 1
                        return text("row \(index)").wFull().h(20).selectable()
                            .secure(model.secureMiddleRow && index == 500)
                    }
                )
            )
        }
        func snapshot() -> TextSelection? {
            var seen: TextSelection?
            runtime.updateIf { _, tx in seen = tx.textSelection(); return false }
            return seen
        }

        _ = runtime.frame(at: 0)
        runtime.update { _, tx in tx.selectAllText("list") }
        _ = runtime.frame(at: 0.1)
        let selection = try #require(snapshot())
        #expect(selection.text == (0..<count).map { "row \($0)" }.joined(separator: "\n"))
        let builds = runtime.state.builds.count
        let commit = runtime.viewCommitCount
        for _ in 0..<8 {
            runtime.updateIf { _, _ in false }
            #expect(snapshot()?.texts.count == count)
        }
        #expect(runtime.state.builds.count == builds)
        #expect(runtime.viewCommitCount == commit)

        runtime.update { model, _ in model.secureMiddleRow = true }
        _ = runtime.frame(at: 0.2)
        let redacted = try #require(snapshot())
        #expect(!redacted.texts.contains { $0.text == "row 500" })
        #expect(redacted.texts.count == count - 1)
        #expect(selection.texts.count == count)
        #expect(runtime.state.builds.count > builds)

        runtime.update { _, tx in tx.selectText("r0", range: 0..<3) }
        _ = runtime.frame(at: 0.3)
        #expect(snapshot()?.text == "row")
        let beforeDrag = runtime.viewCommitCount
        runtime.pointerDown(at: Vec2(1, 10), at: 0.31)
        #expect(snapshot() == nil)
        runtime.pointerMove(to: Vec2(45, 10), at: 0.32)
        #expect(snapshot()?.text == "row 0")
        runtime.pointerUp(at: Vec2(45, 10), at: 0.33)
        #expect(runtime.viewCommitCount == beforeDrag)
        runtime.update { _, tx in tx.clearTextSelection() }
        _ = runtime.frame(at: 0.4)
        #expect(snapshot() == nil)
    }

    @Test func selectionObserversAndTheirTransactionsShareOffscreenRows() {
        let count = 256
        let runtime = Runtime(state: Model(), viewport: Vec2(220, 90)) { _, _ in
            col().wFull().hFull().scroll(stickBottom: false).child(
                col().wFull().key("list").selectionGroup().virtualRows(
                    count, 20, key: { _, index in "r\(index)" },
                    build: { model, index in
                        model.builds.count += 1
                        return text("row \(index)").wFull().h(20).selectable()
                    }
                ).onSelectionChange { model, change, tx in
                    #expect(tx.textSelection() == change.selection)
                    model.builds.heard.append(change.selection?.texts.count ?? 0)
                    model.builds.buildsAtDelivery.append(model.builds.count)
                }
            )
        }
        _ = runtime.frame(at: 0)
        runtime.update { _, tx in tx.selectAllText("list") }
        let before = runtime.state.builds.count
        _ = runtime.frame(at: 0.1)
        #expect(runtime.state.builds.heard == [count])
        #expect((runtime.state.builds.buildsAtDelivery.first ?? 0) - before < count + 40)
        let delivered = runtime.state.builds.count
        for _ in 0..<4 {
            runtime.dispatchSelectionChanges(at: 0.1)
            runtime.updateIf { _, tx in
                #expect(tx.textSelection()?.texts.count == count)
                return false
            }
        }
        #expect(runtime.state.builds.count == delivered)
        #expect(runtime.state.builds.heard == [count])
        runtime.update { _, tx in tx.clearTextSelection() }
        _ = runtime.frame(at: 0.2)
        #expect(runtime.state.builds.heard == [count, 0])
    }
}
