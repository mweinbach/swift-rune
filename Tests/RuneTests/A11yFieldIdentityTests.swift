#if os(macOS) && canImport(AppKit)
import AppKit
import Metal
import Testing
@testable import Rune

@MainActor
@Suite("Native field identity")
struct A11yFieldIdentityTests {
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func activeRowChangesAppKitFocusWhileTheTreeKeepsKeyboardFocus() throws {
        _ = NSApplication.shared
        let runtime = Runtime(state: "first", viewport: Vec2(160, 80)) { cursor, _ in
            col().key("files").role(.tree).focusable().activeDescendant(cursor).children([
                el().key("first").role(.treeItem).label("First file").size(100, 24),
                el().key("second").role(.treeItem).label("Second file").size(100, 24),
            ])
        }
        let view = RuneMetalHostView(frame: NSRect(x: 0, y: 0, width: 160, height: 80),
                                     runtime: runtime, renderer: try MetalRenderer(),
                                     timeScale: 1, respectSystemAppearance: false)
        _ = runtime.frame(at: 0)
        #expect(runtime.accessibilityAction("files", .focus, at: 0.1))
        _ = runtime.frame(at: 0.1)
        view.syncPlatformBridges(treeCommitted: true)
        let first = try #require(view.accessibilityFocusedUIElement as? RuneNSAccessibilityElement)
        #expect(first.accessibilityIdentifier() == "first")
        runtime.update(at: 0.2) { cursor, _ in cursor = "second" }
        _ = runtime.frame(at: 0.2)
        view.syncPlatformBridges(treeCommitted: true)
        let second = try #require(view.accessibilityFocusedUIElement as? RuneNSAccessibilityElement)
        #expect(second.accessibilityIdentifier() == "second")
        #expect(runtime.focusedKey == "files")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func detachedReaderSkipsUnfocusedFieldsAndFirstQueryGetsTheirCurrentValue() throws {
        final class Counter { var reads = 0 }
        let reads = Counter()
        let runtime = Runtime(state: TextEdit("initial"), viewport: Vec2(180, 64)) { _, _ in
            textInput(key: "draft", editAccess(get: { value in
                reads.reads += 1
                return value
            }, set: { state, value in state = value })).size(120, 28)
        }
        _ = NSApplication.shared
        let view = RuneMetalHostView(frame: NSRect(x: 0, y: 0, width: 180, height: 64),
                                     runtime: runtime, renderer: try MetalRenderer(),
                                     timeScale: 1, respectSystemAppearance: false)
        runtime.update(at: 0) { state, _ in state = TextEdit("latest") }
        _ = runtime.frame(at: 0)
        let before = reads.reads
        view.syncPlatformBridges(treeCommitted: true)
        #expect(reads.reads == before)
        #expect(!runtime.assistiveTechnology)

        let field = try #require(view.accessibilityChildren()?.first as? RuneAXTextField)
        #expect(field.accessibilityValue() as? String == "latest")
        #expect(runtime.assistiveTechnology && reads.reads > before)
        runtime.update(at: 0.1) { state, _ in state = TextEdit("changed") }
        _ = runtime.frame(at: 0.1)
        view.syncPlatformBridges(treeCommitted: true)
        #expect(field.accessibilityValue() as? String == "changed")
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func readerHitTestCanActivateBeforeTheFirstFrame() throws {
        _ = NSApplication.shared
        let runtime = Runtime(state: 0, viewport: Vec2(180, 64)) { _, _ in
            el().key("btn").role(.button).label("First button").size(100, 30)
        }
        let view = RuneMetalHostView(frame: NSRect(x: 0, y: 0, width: 180, height: 64),
                                     runtime: runtime, renderer: try MetalRenderer(),
                                     timeScale: 1, respectSystemAppearance: false)
        let target = try #require(view.accessibilityHitTest(NSPoint(x: 10, y: 10)) as? RuneNSAccessibilityElement)
        #expect(target.accessibilityIdentifier() == "btn")
        #expect(runtime.assistiveTechnology)
        #expect(runtime.viewCommitCount == 1)
    }

    @Test func fieldsWithMatchingKeysRouteToTheirOwnEditor() throws {
        struct Form { var first = TextEdit("first"); var second = TextEdit("second") }
        let runtime = Runtime(state: Form(), viewport: Vec2(300, 160), systemDark: false) { _, _ in
            col().children([
                col().key("left").child(textInput(key: "draft", \Form.first)),
                col().key("right").child(textInput(key: "draft", \Form.second))
            ])
        }
        let host = MacOSAccessibilityHost()
        let view = NSView()
        let mainRuntime = MacOSUnsafeSendableBox(runtime)
        func refresh(at time: Double) {
            _ = runtime.frame(at: time)
            host.update(tree: runtime.accessibilitySnapshot(), parentView: view, onSelectText: { id, range in
                MainActor.assumeIsolated { _ = mainRuntime.value.accessibilitySelectText(id, range: range, at: time) }
            }, onSetValue: { id, value in
                MainActor.assumeIsolated { _ = mainRuntime.value.accessibilityAction(id, .setValue, value: value, at: time) }
            }, onAction: { id, action in
                MainActor.assumeIsolated { _ = mainRuntime.value.accessibilityAction(id, action, at: time) }
            })
        }
        refresh(at: 0)
        func fields(under objects: [Any]) -> [RuneNSAccessibilityElement] {
            objects.compactMap { $0 as? RuneNSAccessibilityElement }.flatMap { item in
                item.nodeId == "draft" ? [item] : fields(under: item.accessibilityChildren() ?? [])
            }
        }
        let inputs = fields(under: host.accessibilityChildren())
        try #require(inputs.count == 2)
        let first = inputs[0], second = inputs[1]
        #expect(first !== second)
        #expect(first.accessibilityIdentifier() == "draft" && second.accessibilityIdentifier() == "draft")
        #expect(second.accessibilityPerformPress())
        refresh(at: 0.1)
        #expect(host.accessibilityFocusedUIElement() as? RuneNSAccessibilityElement === second)
        #expect(!first.isAccessibilityFocused() && second.isAccessibilityFocused())
        second.setAccessibilitySelectedTextRange(NSRange(location: 1, length: 3))
        #expect(runtime.state.second.selectedUTF8Range == 1..<4)
        #expect(!runtime.state.first.hasSelection)
        second.setAccessibilityValue("replaced")
        refresh(at: 0.2)
        #expect(runtime.state.first.text == "first" && runtime.state.second.text == "replaced")
        #expect(first.accessibilityValue() as? String == "first")
        #expect(second.accessibilityValue() as? String == "replaced")
    }

    @Test func authorBuiltTreeScopesFieldIdentityToItsAncestors() throws {
        let host = MacOSAccessibilityHost()
        let view = NSView()
        func group(_ id: String, _ value: String, focused: Bool = false) -> AccessibilityNode {
            AccessibilityNode(id: id, role: .group, children: [
                AccessibilityNode(id: "draft", role: .textInput, value: value, isFocused: focused, textSelection: [0, 0, 0, 0])
            ])
        }
        func update(_ groups: [AccessibilityNode]) {
            let tree = AccessibilityNode(id: "root", role: .group, children: groups)
            host.update(tree: tree, parentView: view, onAction: { _, _ in })
        }
        update([group("left", "left"), group("right", "right", focused: true)])
        let held = try #require(host.accessibilityFocusedUIElement() as? RuneNSAccessibilityElement)
        update([group("right", "changed", focused: true), group("left", "left")])
        #expect(host.accessibilityFocusedUIElement() as? RuneNSAccessibilityElement === held)
        #expect(held.accessibilityValue() as? String == "changed")
        update([group("left", "left", focused: true)])
        #expect(held.accessibilityNumberOfCharacters() == 0)
        #expect(host.accessibilityFocusedUIElement() as? RuneNSAccessibilityElement !== held)
    }
}
#endif
