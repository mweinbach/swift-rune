import RuneMotion
import Testing
@testable import Rune

@Test func nativePaintTopologyFollowsThePresentedOrderAndParentBetweenCommits() throws {
    let rt = Runtime<Int>(state: 0, viewport: Vec2(100, 100)) { _, _ in
        col().key("root").child(el().key("one").size(10, 10)).child(el().key("two").size(20, 20))
    }
    _ = rt.renderFrame(at: 0)
    var scene = rt.scene
    var frame = scene.frame(at: 0)
    let root = try #require(rt.flatNodes.first { $0.key == "root" })
    let one = try #require(rt.flatNodes.first { $0.key == "one" })
    let two = try #require(rt.flatNodes.first { $0.key == "two" })
    let before = rt.prepareNativePaintTopology(frame, byID: frame.paintNodesById, holds: false)
    #expect(Array(before.children(of: root)) == [one.index, two.index])
    #expect(before.matches(frame.nodes, holds: false))
    #expect(!before.matches(frame.nodes, holds: true))

    let a = try #require(frame.nodes.firstIndex { $0.id == one.nodeId })
    let b = try #require(frame.nodes.firstIndex { $0.id == two.nodeId })
    frame.nodes.swapAt(a, b)
    let reordered = rt.prepareNativePaintTopology(frame, byID: frame.paintNodesById, holds: false)
    #expect(Array(reordered.children(of: root)) == [two.index, one.index])

    // A transition may detach a node before the next authored commit.
    frame.nodes[a].parent = nil
    frame.byId[two.nodeId] = frame.nodes[a]
    let detached = rt.prepareNativePaintTopology(frame, byID: frame.paintNodesById, holds: false)
    #expect(detached.roots.contains(two.index))
    #expect(Array(detached.children(of: root)) == [one.index])
}
