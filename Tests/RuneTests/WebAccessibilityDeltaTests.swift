import Foundation
import Testing
@testable import Rune

@Suite
struct WebAccessibilityDeltaTests {
    private func object(_ bytes: Data?) throws -> [String: Any] {
        let data = try #require(bytes)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func movingToACanonicallyEquivalentRowPublishesTheNewActiveDescendant() throws {
        let composed = "\u{e9}"
        let decomposed = "e\u{301}"
        let runtime = Runtime<String>(state: composed, viewport: Vec2(150, 100)) { cursor, _ in
            col().key("files").role(.tree).sizeFull().activeDescendant(cursor).children([
                el().key(composed, byteExact: true).role(.treeItem).label("First file"),
                el().key(decomposed, byteExact: true).role(.treeItem).label("Second file"),
            ])
        }
        let mirror = WebAccessibilityProjection()
        mirror.enablePatches()
        let tracker = AccessibilityTreeState()
        _ = runtime.frame(at: 0)
        _ = try object(mirror.update(runtime))
        _ = tracker.diff(root: runtime.accessibilitySnapshot(), windowTitle: "Files")
        runtime.update(at: 0.1) { cursor, _ in cursor = decomposed }
        _ = runtime.frame(at: 0.1)

        let packet = try object(mirror.update(runtime))
        let nodes = try #require(packet["nodes"] as? [[String: Any]])
        let tree = try #require(nodes.first { $0["key"] as? String == "files" })
        let browserTarget = try #require(tree["activeDescendant"] as? String)
        #expect(browserTarget.utf8.elementsEqual(decomposed.utf8))
        let delta = try #require(tracker.diff(root: runtime.accessibilitySnapshot(), windowTitle: "Files"))
        let nativeTarget = try #require(delta.updatedNodes.first { $0.id == "files" }?.activeDescendant)
        #expect(nativeTarget.utf8.elementsEqual(decomposed.utf8))
        #expect(mirror.update(runtime) == nil)
    }

    @Test func scrollingChangesRowsWithoutRewritingTheirCells() throws {
        let runtime = Runtime<Int>(state: 0, viewport: Vec2(200, 120), pixelScale: 1) { _, _ in
            var list: El<Int> = col().key("items").sizeFull().scrollY()
            for rowIndex in 0..<80 {
                let cell: El<Int> = text("Cell \(rowIndex)").key("cell")
                list = list.child(row().key("row-\(rowIndex)").h(24).shrink(0).child(cell))
            }
            return list
        }
        let mirror = WebAccessibilityProjection()
        mirror.enablePatches()
        _ = runtime.frame(at: 0)
        #expect(mirror.deferredPull(runtime) == -2)
        let full = try #require(mirror.update(runtime))
        #expect(try object(full)["root"] != nil)
        #expect(mirror.update(runtime) == nil)
        runtime.wheel(WheelEvent(dy: -48), at: Vec2(50, 50), now: 0.1)
        _ = runtime.frame(at: 0.1)
        #expect(mirror.deferredPull(runtime) == -1)
        let change = try #require(mirror.update(runtime))
        let packet = try object(change)
        #expect(change.count < full.count)
        #expect(packet["local"] as? Bool == true)
        #expect(packet["root"] == nil)
        let bounds = try #require(packet["bounds"] as? [String: [Double]])
        #expect(bounds.keys.contains { $0.hasSuffix("/@row-4") })
        #expect(!bounds.keys.contains { $0.hasSuffix("/@cell") })
        let nodes = try #require(packet["nodes"] as? [[String: Any]])
        #expect(nodes.count == 1)
        let scroll = try #require(nodes.first?["scroll"] as? [Double])
        #expect(scroll[1] > 0)
        #expect(mirror.update(runtime) == nil)
    }

    @Test func aLiveLabelAndPositionFollowWithoutACommit() throws {
        let label = LiveText("One")
        let position = Live<Vec2>(.zero)
        let runtime = Runtime<Void>(state: (), viewport: Vec2(200, 100), pixelScale: 1) { _, _ in
            col().key("root").sizeFull().child(
                liveText(label).key("live").size(100, 24).liveOffset(position.binding)
            )
        }
        let mirror = WebAccessibilityProjection()
        mirror.enablePatches()
        _ = runtime.frame(at: 0)
        _ = try object(mirror.update(runtime))
        let initial = runtime.commitCount
        label.set("Two")
        position.set(Vec2(25, 0))
        _ = runtime.frame(at: 0.2)
        #expect(runtime.commitCount == initial)
        let packet = try object(mirror.update(runtime))
        let changed = try #require(packet["nodes"] as? [[String: Any]])
        let live = try #require(changed.first { $0["key"] as? String == "live" })
        #expect(live["name"] as? String == "Two")
        #expect((live["bounds"] as? [Double])?.first == 25)
        #expect(mirror.update(runtime) == nil)
    }

    @Test func commitUpdatesFocusHierarchyAndRedactionAcrossResets() throws {
        struct State { var replaced = false; var secret = TextEdit("private-value") }
        let runtime = Runtime<State>(state: State(), viewport: Vec2(220, 160), pixelScale: 1) { state, _ in
            col().key("root").sizeFull().children([
                el().key("switch").role(.switchControl).label("Show details").focusable(true)
                    .selected(state.replaced ? "true" : "false").h(32),
                text(state.replaced ? "After" : "Before").key(state.replaced ? "after" : "before"),
                textInput(key: "secret", \.secret).secure(true).label("Password"),
            ])
        }
        let mirror = WebAccessibilityProjection()
        mirror.enablePatches()
        _ = runtime.frame(at: 0)
        let first = try #require(mirror.update(runtime))
        #expect(!String(decoding: first, as: UTF8.self).contains("private-value"))
        #expect(runtime.accessibilityAction("switch", .focus, at: 0.1))
        runtime.state.replaced = true
        runtime.markNeedsCommit(settle: true)
        _ = runtime.frame(at: 0.1)
        let change = try #require(mirror.update(runtime))
        #expect(!String(decoding: change, as: UTF8.self).contains("private-value"))
        let packet = try object(change)
        let changed = try #require(packet["nodes"] as? [[String: Any]])
        let control = try #require(changed.first { $0["key"] as? String == "switch" })
        #expect((control["states"] as? [String])?.contains("focused") == true)
        #expect(control["value"] as? String == "true")
        #expect(changed.contains { $0["name"] as? String == "After" })
        #expect((packet["removed"] as? [String])?.contains { $0.hasSuffix("/@before") } == true)
        let order = try #require(packet["children"] as? [String: [String]])
        #expect(order.count == 1)
        #expect(order.values.first?.count == 3)
        runtime.viewport = Vec2(240, 180)
        #expect(mirror.deferredPull(runtime) == 0)
        _ = runtime.frame(at: 0.2)
        let reset = try object(mirror.update(runtime))
        #expect(reset["root"] != nil && reset["width"] as? Int == 240)
        #expect(mirror.update(runtime) == nil)
    }
}
