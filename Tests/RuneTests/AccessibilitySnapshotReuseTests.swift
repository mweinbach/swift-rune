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
}
