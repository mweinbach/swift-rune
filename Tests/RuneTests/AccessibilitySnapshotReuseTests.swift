import Testing
@testable import Rune

@Suite("Retained accessibility snapshots")
struct AccessibilitySnapshotReuseTests {
    private func find(_ key: String, in node: AccessibilityNode) -> AccessibilityNode? {
        if node.id == key { return node }
        for child in node.children {
            if let found = find(key, in: child) { return found }
        }
        return nil
    }

    private func check<State>(_ runtime: Runtime<State>, securePaths: Set<String> = []) -> AccessibilityNode {
        let actual = runtime.accessibilitySnapshot(securePaths: securePaths)
        let cache = runtime.accessibilityProjectionCache
        runtime.accessibilityProjectionCache = nil
        let fresh = runtime.accessibilitySnapshot(securePaths: securePaths)
        runtime.accessibilityProjectionCache = cache
        #expect(actual == fresh)
        return actual
    }

    @Test func movedRowsUpdateGeometryFocusAndNamesAcrossSkippedSnapshots() throws {
        let rt = Runtime<Int>(state: 0, viewport: Vec2(200, 90), pixelScale: 1) { step, _ in
            func panel(_ id: Int) -> El<Int> {
                memo("panel-\(id)", deps: step >= 6) {
                    col().key("panel-\(id)").wFull().h(40).shrink(0)
                        .child(text(step < 6 ? "before" : "after").key("words-\(id)").size(60, 18))
                        .child(el().key("button-\(id)").size(35, 15).focusable().onClick { _ in })
                }
            }
            var box: El<Int> = col().key("viewport").size(180, 60).scrollY()
            for i in (step < 4 ? [0, 1, 2, 3] : [3, 2, 1, 0]) { box = box.child(panel(i)) }
            if step == 8 { box = box.inert() }
            if step == 5 { return col().child(box).child(el().key("modal").size(20, 15).modal()) }
            return box
        }
        for i in 0..<9 {
            let t = Double(i + 1) / 60
            rt.update(at: t) { step, tx in
                step = i
                if i == 2 { tx.scrollToInstant("viewport", x: 0, y: 24) }
                if i == 3 { tx.focus("button-1") }
            }
            _ = rt.renderFrame(at: t)
            if i == 7 { continue }
            let current = check(rt)
            if i == 5 {
                #expect(find("words-1", in: current) == nil)
                continue
            }
            let group = try #require(find("panel-1", in: current))
            let next = try #require(find("panel-1", in: check(rt)))
            #expect(!group.children.isEmpty)
            let shared = group.children.withUnsafeBufferPointer { old in
                next.children.withUnsafeBufferPointer { old.baseAddress == $0.baseAddress }
            }
            #expect(shared)
            let button = try #require(find("button-1", in: current))
            if i == 3 { #expect(button.isFocused) }
            if i == 8 {
                #expect(button.isDisabled && !button.isFocusable && !button.actions.contains(.press))
            }
            let words = try #require(find("words-1", in: current))
            #expect(words.value == (i < 6 ? "before" : "after"))
            let path = try #require(words.runtimePath)
            let secured = try #require(find("words-1", in: check(rt, securePaths: [path])))
            #expect(secured.isSecure && secured.value == nil)
            #expect(find("words-1", in: check(rt))?.value == words.value)
        }
    }

    @Test func liveTextReprojectsItsRoleAndDependentNamesWithoutACommit() throws {
        let source = LiveText("")
        let runtime = Runtime<Void>(state: (), viewport: Vec2(180, 80)) { _, _ in
            var leaf: El<Void> = el().key("source").size(100, 18)
            leaf.liveText = source
            return col().key("panel").child(col().key("derived").role(.row).child(leaf))
                .child(el().key("related").role(.button).labelledBy("source"))
        }
        _ = runtime.frame(at: 0)
        let first = check(runtime)
        #expect(find("source", in: first)?.role == .group)
        let commit = runtime.commitCount
        for (i, value) in ["One", "Two", ""].enumerated() {
            source.set(value)
            _ = runtime.frame(at: Double(i + 1) / 60)
            let now = check(runtime)
            #expect(runtime.commitCount == commit)
            #expect(find("source", in: now)?.role == (value.isEmpty ? .group : .text))
            #expect((find("derived", in: now)?.label ?? "") == value)
            #expect((find("related", in: now)?.label ?? "") == value)
        }
        #expect(find("source", in: first)?.role == .group)
    }

    @Test func committingDuringAnEditorReadKeepsTheOriginalFrameCoherent() {
        struct Form {
            var value = TextEdit("first")
            var replaced = false
        }
        final class Callback {
            var run: (() -> Void)?
            var outerCalls = 0
            var counting = false
            var nested = false
            var nestedTree: AccessibilityNode?
        }
        let callback = Callback()
        let runtime = Runtime(state: Form(), viewport: Vec2(220, 160)) { state, _ in
            let field: El<Form> = textInput(key: "entry", editAccess(get: { model in
                if callback.counting, !callback.nested { callback.outerCalls += 1 }
                let run = callback.run
                callback.run = nil
                run?()
                return model.value
            }, set: { model, edit in model.value = edit })).size(90, 24)
            var panel = col().key("panel").size(220, 160).child(field)
            if state.replaced {
                panel = panel.child(col().key("replacement").child(text("After").key("new")))
            } else {
                panel = panel.child(text("Before").key("old").size(36, 24))
                    .child(text("Retired").key("retiring"))
            }
            return panel
        }
        _ = runtime.renderFrame(at: 0)
        let before = runtime.accessibilitySnapshot()
        callback.counting = true
        callback.run = {
            callback.nested = true
            runtime.update(at: 1) { model, _ in
                model.value = TextEdit("second")
                model.replaced = true
            }
            _ = runtime.renderFrame(at: 1)
            callback.nestedTree = runtime.accessibilitySnapshot()
            callback.nested = false
        }
        let during = runtime.accessibilitySnapshot()
        callback.counting = false
        let after = runtime.accessibilitySnapshot()
        #expect(callback.outerCalls == 1)
        #expect(during == before)
        #expect(callback.nestedTree == after)
        #expect(find("entry", in: during)?.value == "first")
        #expect(find("old", in: after) == nil && find("new", in: after)?.value == "After")
        #expect(find("entry", in: after)?.value == "second")
    }

    @Test func anEditorReadCanChangeThePresenceOfALaterSibling() throws {
        final class DuringRead { var perform: (() -> Void)? }
        let callback = DuringRead()
        let runtime = Runtime(state: TextEdit("draft"), viewport: Vec2(180, 80)) { _, _ in
            col().key("panel").child(textInput(key: "input", editAccess(get: { edit in
                let action = callback.perform
                callback.perform = nil
                action?()
                return edit
            }, set: { state, value in state = value })))
                .child(text("Leaving").key("later").transition(.opacity))
        }
        _ = runtime.renderFrame(at: 0)
        let before = runtime.accessibilitySnapshot()
        #expect(before.children.contains { $0.id == "later" })
        let i = try #require(runtime.flatNodes.firstIndex { $0.key == "later" })
        let id = runtime.flatNodes[i].nodeId
        callback.perform = { runtime.scene.remove(id) }
        let after = runtime.accessibilitySnapshot()
        #expect(runtime.scene.isExiting(id))
        #expect(!after.children.contains { $0.id == "later" })
        #expect(before.children.contains { $0.id == "later" })
    }

    @Test func editValuesStayLiveBetweenAccessibilityReads() throws {
        struct Form { var draft = TextEdit("first") }
        let rt = Runtime(state: Form(), viewport: Vec2(200, 80), pixelScale: 1) { _, _ in
            col().key("panel").child(textInput(key: "draft", \Form.draft))
        }
        _ = rt.renderFrame(at: 0)
        #expect(find("draft", in: check(rt))?.value == "first")
        rt.state.draft = TextEdit("second")
        #expect(find("draft", in: check(rt))?.value == "second")
        rt.state.draft.isSecure = true
        let field = try #require(find("draft", in: check(rt)))
        #expect(field.isSecure && field.value == nil && field.textSelection == nil)
    }

    @Test func snapshotReadsThePreviousPaintByPathAfterAReorder() throws {
        let runtime = Runtime(state: false, viewport: Vec2(160, 90), pixelScale: 1) { reversed, _ in
            var column: El<Bool> = col().key("list").sizeFull()
            for key in reversed ? ["two", "one"] : ["one", "two"] {
                column = column.child(text(key).key(key).h(30).wFull())
            }
            return column
        }
        _ = runtime.renderFrame(at: 0)
        let first = runtime.accessibilitySnapshot()
        let old = runtime.presentedRectByPath
        let painted = runtime.layoutCommitGen
        #expect(old.indexedValues(at: painted) != nil)

        runtime.state = true
        runtime.commitTree(at: 1, cut: true)
        #expect(old.indexedValues(at: runtime.layoutCommitGen) == nil)
        let between = runtime.accessibilitySnapshot()
        for key in ["one", "two"] {
            let node = try #require(find(key, in: between))
            let previous = try #require(find(key, in: first))
            #expect(node.frame == previous.frame)
        }
        _ = runtime.renderFrame(at: 1)
        let next = runtime.accessibilitySnapshot()
        #expect(runtime.presentedRectByPath.indexedValues(at: runtime.layoutCommitGen) != nil)
        #expect(find("one", in: next)?.frame == find("two", in: first)?.frame)
    }
}
