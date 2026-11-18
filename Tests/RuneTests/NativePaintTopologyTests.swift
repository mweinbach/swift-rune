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

@Test func nativeHitGeometryKeepsItsPaintedSlotsAcrossCommits() throws {
    let rt = Runtime<Int>(state: 0, viewport: Vec2(100, 100)) { state, _ in
        var root: El<Int> = col().key("root")
        if state == 1 { root = root.child(el().key("inserted").size(20, 30).hit()) }
        return root.child(el().key("target").size(20, 10).hit())
    }
    _ = rt.renderFrame(at: 0)
    let path = try #require(rt.element(byKey: "target")?.path)
    let old = rt.hitGeometryByPath
    #expect(old[path]?.contains(Vec2(5, 5)) == true)
    rt.state = 1
    rt.invalidate(at: 1)
    _ = rt.renderFrame(at: 1)
    rt.settleAll()
    _ = rt.renderFrame(at: 2)
    #expect(rt.hitTestElement(at: Vec2(5, 35))?.key == "target")
    #expect(rt.hitGeometryByPath[path]?.contains(Vec2(5, 35)) == true)
    #expect(old[path]?.contains(Vec2(5, 35)) == false)
    var edited = rt.hitGeometryByPath
    edited[path] = nil
    #expect(edited[path] == nil)
    #expect(rt.hitGeometryByPath[path] != nil)
}

@Test func nativePaintRestoresMarksAfterSingleChildScopes() {
    let rt = Runtime(state: (), viewport: Vec2(24, 8), pixelScale: 1) { _, _ -> El<Void> in
        let ink: El<Void> = el().size(8, 8).bg(Color.srgb(1, 0.25, 0.25))
        let wrapped = el().size(8, 8).child(ink)
        return row().size(24, 8).mark(7).children([
            el().size(8, 8).mark(42).child(wrapped),
            wrapped,
            ink.mark(12),
        ])
    }
    let frame = rt.renderFrame(at: 0)
    #expect(frame.marks == [42, 7, 12])
}
