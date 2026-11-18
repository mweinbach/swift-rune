import Foundation
import Testing
@testable import Rune

@Suite
struct WebAccessibilityDeltaTests {
    private func object(_ bytes: Data?) throws -> [String: Any] {
        let data = try #require(bytes)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }


    private func comparablePatch(_ bytes: Data?) throws -> Data? {
        guard let bytes else { return nil }
        var packet = try object(bytes)
        // Removal order has no semantic meaning and depends on the dictionary's seed.
        if let removed = packet["removed"] as? [String] { packet["removed"] = removed.sorted() }
        return try JSONSerialization.data(withJSONObject: packet, options: .sortedKeys)
    }

    @Test func pathCollectionsPreserveUTF8AndOtherFields() throws {
        let path = "/quoted\"/slash\\/\u{0}\t\n/水/🪐/e\u{301}"
        let fields: [String: Any] = ["nodes": [["unknown": path]], "local": true]
        for removed in [nil, [path]] {
            for children in [nil, [path: [path]]] {
                let paths = WebAccessibilityPatch(removed: removed, children: children)
                let packet = try object(paths.encodePacket(fields))
                let result = (packet["nodes"] as? [[String: String]])?.first?["unknown"]
                #expect(result?.utf8.elementsEqual(path.utf8) == true)
                #expect((packet["removed"] as? [String])?.first?.utf8.elementsEqual(path.utf8) == removed.map { _ in true })
                let order = packet["children"] as? [String: [String]]
                #expect(order?.keys.first?.utf8.elementsEqual(path.utf8) == children.map { _ in true })
                #expect(order?[path]?.first?.utf8.elementsEqual(path.utf8) == children.map { _ in true })
            }
        }
    }

    @Test func failedPatchIsFollowedByACompleteSnapshot() throws {
        let runtime = Runtime<Int>(state: 0, viewport: Vec2(100, 100)) { state, _ in
            col().key("root").role(.group).child(
                el().key("control-\(state)").role(.slider)
                    .rangeValue(state == 1 ? Double.infinity : 1, min: 0, max: 10)
            )
        }
        let mirror = WebAccessibilityProjection()
        let legacy = WebAccessibilityProjection()
        mirror.enablePatches()
        _ = runtime.frame(at: 0)
        #expect(try object(legacy.update(runtime))["root"] != nil)
        #expect(try object(mirror.update(runtime))["root"] != nil)
        runtime.update(at: 0.1) { state, _ in state = 1 }
        _ = runtime.frame(at: 0.1)
        #expect(mirror.update(runtime) == nil)
        runtime.update(at: 0.2) { state, _ in state = 2 }
        _ = runtime.frame(at: 0.2)
        #expect(try object(mirror.update(runtime))["root"] != nil)
        #expect(try object(legacy.update(runtime))["root"] != nil)
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
        let runtime = Runtime<Void>(state: (), viewport: Vec2(200, 100), pixelScale: 10) { _, _ in
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
        position.set(Vec2(25.2, 0))
        _ = runtime.frame(at: 0.2)
        #expect(runtime.commitCount == initial)
        let packet = try object(mirror.update(runtime))
        let changed = try #require(packet["nodes"] as? [[String: Any]])
        let live = try #require(changed.first { $0["key"] as? String == "live" })
        #expect(live["name"] as? String == "Two")
        // Darwin and Swift Foundation serialize the same Float with different decimal precision.
        let reference = try object(JSONSerialization.data(withJSONObject: ["position": Float(25.2)]))
        #expect((live["bounds"] as? [Double])?.first == (reference["position"] as? Double))
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
        runtime.update(at: 0.1) { state, tx in
            state.replaced = true
            tx.announce("Details changed", .polite)
        }
        _ = runtime.frame(at: 0.1)
        let change = try #require(mirror.update(runtime))
        #expect(!String(decoding: change, as: UTF8.self).contains("private-value"))
        let packet = try object(change)
        let changed = try #require(packet["nodes"] as? [[String: Any]])
        let announcement = try #require(packet["announcement"] as? [String: String])
        #expect(announcement["text"] == "Details changed")
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

    @Test func retainedVirtualSubtreesKeepCurrentBoundsAndSemantics() throws {
        final class Owner {}
        let owners = (0..<36).map { _ in Owner() }
        let offset = Live<Vec2>(.zero)
        let runtime = Runtime(state: 0, viewport: Vec2(220, 100), pixelScale: 2) { _, _ in
            let rows: El<Int> = col().key("list").wFull().virtualRows(
                count: owners.count, estimatedRowHeight: 20,
                key: { step, row in "row-\(step < 9 ? row : owners.count - row - 1)" },
                buildContent: { step, position in
                    let id = step < 9 ? position : owners.count - position - 1
                    let node: El<Int> = memo("row-content-\(id)", deps: 0) {
                        col().key("row-\(id)").h(20).wFull().child(
                            row().key("group-\(id)").h(20).wFull()
                                .child(text("Word \(id)").key("word-\(id)").liveOffset(offset.binding))
                                .child(el().key("action-\(id)").focusable().role(.button).label("Select").size(20, 18)))
                    }
                    return VirtualRowContent(memoized: node, owner: owners[id])
                })
            return col().key("scroll").sizeFull().scrollY().child(rows)
        }
        let mirror = WebAccessibilityProjection()
        let oracle = WebAccessibilityProjection()
        mirror.enablePatches()
        oracle.enablePatches()
        var replayed = 0
        for step in 0..<16 {
            let time = Double(step) / 60
            offset.set(Vec2(Float(step) * 0.7, Float(step % 5) * 0.6))
            runtime.update(at: time) { value, tx in
                value = step
                if step == 4 { tx.focus("action-4") }
                tx.scrollToInstant("scroll", x: 0, y: Float((step * 12) % 120))
            }
            _ = runtime.renderFrame(at: time)
            replayed += runtime.replayedVirtualFlatRoots
            let actual = try comparablePatch(mirror.update(runtime))
            let retained = runtime.accessibilityProjectionCache
            runtime.accessibilityProjectionCache = nil
            let fresh = try comparablePatch(oracle.update(runtime))
            let full = runtime.accessibilitySnapshot()
            runtime.accessibilityProjectionCache = retained
            #expect(actual == fresh)
            // Alternate public snapshots and uninterrupted runs of browser deltas.
            if step.isMultiple(of: 4) { #expect(runtime.accessibilitySnapshot() == full) }
            #expect(mirror.update(runtime) == nil)
        }
        #expect(replayed > 0)
    }

    @Test func aGeneratedLinkPathCanCoincideWithAnAuthoredKey() throws {
        let runtime = Runtime(state: 0, viewport: Vec2(200, 100), pixelScale: 1) { phase, _ in
            let links = (3...7).contains(phase % 10)
            let list: El<Int> = col().wFull().virtualRows(count: 40, estimatedRowHeight: 24,
                key: { _, index in "row-\(index)" }, buildContent: { _, index in
                    let words: El<Int> = text("Docs").key("article").size(44, 20)
                    let article = links ? words.link(TextLink(0..<4, id: "docs")) : words
                    let group: El<Int> = memo("parts-\(index)", deps: 0) {
                        row().key("parts").child(text("Row \(index)")).child(el().role(.button).size(12, 12))
                    }
                    let collision = row().key("article#link-0").child(group)
                    return VirtualRowContent(col().h(24).wFull().child(article).child(collision))
                })
            return col().key("viewport").sizeFull().scrollY().child(list)
        }
        let mirror = WebAccessibilityProjection()
        let oracle = WebAccessibilityProjection()
        mirror.enablePatches()
        oracle.enablePatches()
        var observedCollision = false
        for step in 0..<24 {
            let time = Double(step) / 60
            runtime.update(at: time) { phase, tx in
                phase = step
                tx.scrollToInstant("viewport", x: 0, y: Float((step * 11) % 54))
            }
            _ = runtime.renderFrame(at: time)
            let actual = try comparablePatch(mirror.update(runtime))
            let retained = runtime.accessibilityProjectionCache
            runtime.accessibilityProjectionCache = nil
            let expected = try comparablePatch(oracle.update(runtime))
            var paths = Set<String>()
            func collect(_ node: AccessibilityNode) {
                if let path = node.runtimePath, !paths.insert(path).inserted, path.hasSuffix("/@article#link-0") {
                    observedCollision = true
                }
                node.children.forEach(collect)
            }
            collect(runtime.accessibilitySnapshot())
            runtime.accessibilityProjectionCache = retained
            #expect(actual == expected)
        }
        #expect(observedCollision)
    }
}
