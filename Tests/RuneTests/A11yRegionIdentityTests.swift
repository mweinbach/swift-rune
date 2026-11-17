import Testing
@testable import Rune

@MainActor
@Suite("Live-region identity across snapshots")
struct A11yRegionIdentityTests {
    @Test func onlyTheChangedRuntimeRegionAnnounces() throws {
        struct State { var second = "old"; var showSecond = true }
        let rt = Runtime(state: State(), viewport: Vec2(220, 100), systemDark: false) { state, _ in
            let left: El<State> = col().key("left").child(el().key("status").role(.status).label("first").liveRegion(.polite))
            let right: El<State> = col().key("right").child(el().key("status").role(.status).label(state.second).liveRegion(.polite))
            return col().children(state.showSecond ? [left, right] : [left])
        }
        func snapshot(at time: Double) -> AccessibilityNode {
            _ = rt.frame(at: time)
            return rt.accessibilitySnapshot()
        }
        let original = snapshot(at: 0)
        let tracker = AccessibilityTreeState()
        _ = tracker.diff(root: original, windowTitle: "")
        #expect(tracker.diff(root: original, windowTitle: "") == nil)
        #expect(AccessibilityTreeBuilder.liveAnnouncements(previous: original, current: original).isEmpty)
        rt.update(at: 0.1) { state, tx in state.second = "saved"; tx.instant() }
        let changed = snapshot(at: 0.1)
        let announced = AccessibilityTreeBuilder.liveAnnouncements(previous: original, current: changed)
        #expect(announced.map(\.text) == ["saved"])
        let delta = try #require(tracker.diff(root: changed, windowTitle: ""))
        #expect(delta.updatedNodes.map(\.id) == ["status"])
        #expect(delta.updatedNodes.first?.label == "saved")
        let secondPath = try #require(rt.elements().first { $0.key == "status" && $0.label == "saved" }?.path)
        rt.update(at: 0.2) { state, tx in state.showSecond = false; tx.instant() }
        let reduced = snapshot(at: 0.2)
        #expect(AccessibilityTreeBuilder.liveAnnouncements(previous: changed, current: reduced).isEmpty)
        let removal = try #require(tracker.diff(root: reduced, windowTitle: ""))
        #expect(removal.changes.structure)
        #expect(removal.removedIDs.contains(secondPath))
        #expect(removal.removedIDs.contains("right"))
        #expect(!removal.removedIDs.contains("status"))
    }

    @Test func authorProvidedIDsStayStableAcrossReorderingAndRemoval() throws {
        func branch(_ id: String, words: String) -> AccessibilityNode {
            AccessibilityNode(id: id, role: .group, children: [
                AccessibilityNode(id: "status", role: .status, label: words, liveRegion: .polite)
            ])
        }
        let left = branch("left", words: "one")
        let right = branch("right", words: "two")
        var root = AccessibilityNode(id: "root", role: .group, children: [left, right])
        let tracker = AccessibilityTreeState()
        _ = tracker.diff(root: root, windowTitle: "")
        let initial = root
        root.children = [right, left]
        #expect(AccessibilityTreeBuilder.liveAnnouncements(previous: initial, current: root).isEmpty)
        let reordered = try #require(tracker.diff(root: root, windowTitle: ""))
        #expect(reordered.updatedNodes.map(\.id) == ["root"])
        root.children = [right]
        let partial = try #require(tracker.diff(root: root, windowTitle: ""))
        #expect(partial.removedIDs == ["left"])
        root.children = []
        let last = try #require(tracker.diff(root: root, windowTitle: ""))
        #expect(last.removedIDs == ["right", "status"])
    }
}
