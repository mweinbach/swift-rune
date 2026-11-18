import RuneMotion
import Testing
@testable import Rune

@Test func sortedPaintIncludesTheExitingChildAtItsOldLayer() throws {
    let rt = Runtime(state: true, viewport: Vec2(100, 100)) { keep, _ -> El<Bool> in
        var root: El<Bool> = col().key("root")
        root = root.child(el().key("front").size(10, 10).z(4))
        if keep { root = root.child(el().key("leaving").size(10, 10).z(2).transition(.opacity)) }
        return root.child(el().key("back").size(10, 10).z(-1))
    }
    _ = rt.renderFrame(at: 0)
    rt.update(at: 0.03) { keep, _ in keep = false }
    _ = rt.renderFrame(at: 0.03)
    let frame = try #require(rt.lastFrameOutput)
    let root = try #require(rt.flatNodes.first { $0.key == "root" })
    let tree = rt.prepareNativePaintTopology(frame, byID: frame.paintNodesById, holds: false)
    let keys = tree.children(of: root).map { $0 >= 0 ? rt.flatNodes[$0].key : tree.exits[~$0].key }
    #expect(keys == ["back", "leaving", "front"])
}

@Test func syntheticPaintUsesKeyedPosesAfterAMountedFrame() throws {
    let rt = Runtime<Int>(state: 0, viewport: Vec2(100, 100)) { _, _ in
        col().key("root").child(el().key("leaf").size(10, 20))
    }
    _ = rt.renderFrame(at: 0)
    let topology = try #require(rt.nativePaintTopology)
    #expect(topology.presentedIndexBySlot.count == rt.flatNodes.count)
    for i in topology.order.indices {
        #expect(topology.presentedIndexBySlot[topology.order[i]] == i)
    }
    let node = try #require(rt.flatNodes.first { $0.key == "leaf" })
    var scene = rt.scene
    var frame = scene.frame(at: 0)
    // Synthetic samples may override a keyed pose while keeping the same ID and parent order.
    frame.byId[node.nodeId]?.opacity = 0.375
    _ = rt.buildRenderFrame(frameOut: frame, now: 0, publishHitGeometry: true)
    let opacity = try #require(rt.element(byKey: "leaf")?.opacity)
    #expect(abs(opacity - 0.375) < 0.001)
}

@Test func nativePaintTopologyReusesRemountedSlotsAndRebuildsChangedPaintOrder() throws {
    let rt = Runtime<Int>(state: 0, viewport: Vec2(120, 100)) { value, _ in
        // Replacing a leaf's ID keeps the same tree. A later edit changes its paint order
        // and enrolls the sibling in the group-opacity prepass.
        let first: El<Int> = el().key(value == 0 ? "before" : "after").size(20, 20).z(value == 2 ? 1 : 0)
        var second: El<Int> = el().key("sibling").size(20, 20)
        if value == 2 { second = second.groupOpacity(0.5, 1) }
        return col().key("root").children([first, second])
    }
    rt.reducedMotion = true
    _ = rt.renderFrame(at: 0)
    let initial = try #require(rt.nativePaintTopology)
    #expect(!initial.parentSlots.isEmpty)
    var scene = rt.scene
    let presented = scene.frame(at: 0).nodes
    #expect(initial.matchesRemount(presented, mounted: rt.flatNodes, holds: false))
    #expect(!initial.matchesRemount(presented, mounted: rt.flatNodes, holds: true))
    #expect(!initial.matchesRemount(Array(presented.dropLast()), mounted: rt.flatNodes, holds: false))
    var detached = presented
    let child = try #require(detached.firstIndex { $0.parent != nil })
    detached[child].parent = nil
    #expect(!initial.matchesRemount(detached, mounted: rt.flatNodes, holds: false))
    rt.state = 1
    rt.invalidate(at: 1)
    _ = rt.renderFrame(at: 1)
    let reused = try #require(rt.nativePaintTopology)
    let sharedChildren = initial.childSlots.withUnsafeBufferPointer { old in
        reused.childSlots.withUnsafeBufferPointer { old.baseAddress == $0.baseAddress }
    }
    #expect(sharedChildren)
    #expect(reused.identity.map(\.id) != initial.identity.map(\.id))
    #expect(!reused.hasGroupOpacity)

    rt.state = 2
    rt.invalidate(at: 2)
    _ = rt.renderFrame(at: 2)
    let changed = try #require(rt.nativePaintTopology)
    let parent = try #require(rt.flatNodes.first { $0.key == "root" })
    #expect(changed.children(of: parent).compactMap { rt.flatNodes[$0].key } == ["sibling", "after"])
    #expect(changed.hasGroupOpacity)
}

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
