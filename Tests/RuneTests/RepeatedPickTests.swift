import Foundation
import RuneMotion
import Testing
@testable import Rune

@Test func repeatedPicksRespectTurnsTransparentScopesAndPublishedGeometry() throws {
    let view = Vec2(140, 190)
    let rt = Runtime<Int>(state: 0, viewport: view) { start, _ in
        var stack: El<Int> = col().key("list").size(view.x, view.y).scrollY()
        for i in start..<(start + 160) {
            stack = stack.child(el().key("row-\(i)").w(130).h(24).shrink(0).hit().opacity(i.isMultiple(of: 3) ? 0 : 1))
        }
        return stack
    }
    _ = rt.renderFrame(at: 0)
    let point = Vec2(10, 30)
    func picks() -> [String?] {
        [rt.elementAt(point.x, point.y)?.path,
         rt.elementAtWith(10, 5, pick: Pick(transparent: true))?.path,
         rt.elementAtInWith("list", x: point.x, y: point.y, pick: .default)?.path]
    }
    let before = picks()
    #expect(before[0]?.contains("row-1") == true)
    for _ in 0..<12 { #expect(picks() == before) }

    rt.state = 300
    rt.invalidate(at: 1)
    rt.flushPendingCommitIfNeeded(at: 1)
    #expect(picks() == before)
    _ = rt.renderFrame(at: 1)
    let after = picks()
    #expect(after[0]?.contains("row-301") == true)
    for _ in 0..<12 { #expect(picks() == after) }
    let current = try #require(after[0])
    rt.hitGeometryByPath[current] = nil
    #expect(rt.elementAt(point.x, point.y)?.path != current)
}

@Test func repeatedPickBandsConservativelyPreserveTurnAndScreenOverflow() {
    let screen = MotionRect.fromXYWH(0, 0, 200, 300)
    let far = MotionRect.fromXYWH(10, 400, 25, 25)
    let near = MotionRect.fromXYWH(10, 190, 25, 24)
    var geometry = FrameGeometry<HitGeometry>()
    func hit(_ rect: MotionRect, turn: Turn? = nil) -> HitGeometry {
        HitGeometry(paintOrder: 0, rect: rect, clipRect: rect, outerClip: screen, turn: turn,
                    opacity: 0, isExiting: false, hasVisualBlocker: false, isInteractiveBlocker: false)
    }
    let paths = (0..<140).map(String.init)
    for path in paths { geometry[path] = hit(far) }
    let translated = Turn(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: -210)
    geometry["38"] = hit(far, turn: translated)
    geometry["113"] = hit(near)
    var candidates = RepeatedPickCandidates()
    func order(at y: Float, height: Float = 300) -> [String] {
        candidates.paths(at: Vec2(12, y), viewport: Vec2(200, height), order: paths, geometry: geometry)
    }
    for _ in 0..<7 { #expect(order(at: 194) == paths) }
    #expect(order(at: 194) == ["38", "113"])
    #expect(order(at: 301, height: 450) == paths)
    #expect(order(at: -1) == paths)
}

@Test func repeatedPicksFollowDuplicateAndReplacedPaintOrders() {
    let rt = Runtime<Void>(state: (), viewport: Vec2(120, 120)) { _, _ in el() }
    let box = MotionRect.fromXYWH(0, 0, 100, 100)
    let visible = HitGeometry(paintOrder: 0, rect: box, clipRect: box, outerClip: box,
                              turn: nil, opacity: 1, isExiting: false,
                              hasVisualBlocker: false, isInteractiveBlocker: false)
    rt.hitGeometryByPath = FrameGeometry(byPath: ["a": visible, "b": visible])
    let prefix = Array(repeating: "synthetic", count: 140)
    rt.paintOrderPaths = prefix + ["a", "b", "a"]
    for _ in 0..<14 { #expect(rt.elementAt(10, 10)?.path == "a") }
    rt.paintOrderPaths = prefix + ["a", "b"]
    for _ in 0..<14 { #expect(rt.elementAt(10, 10)?.path == "b") }
}

@Test func inputHitCandidatesFollowPublishedPaintOrderAndFallbackGeometry() {
    let order = (0..<160).map(String.init)
    let slots = Dictionary(uniqueKeysWithValues: order.reversed().enumerated().map { ($1, $0) })
    let screen = MotionRect.fromXYWH(0, 0, 200, 300)
    var geometry = FrameGeometry<HitGeometry>(pathSlots: slots)
    for (index, path) in order.enumerated() {
        let rect = MotionRect.fromXYWH(0, index == 41 ? 4 : 304, 20, 20)
        let turn = index == 130 ? Turn(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: -300) : nil
        geometry.record(HitGeometry(paintOrder: index, rect: rect, clipRect: rect, outerClip: screen,
                                    turn: turn, opacity: 1, isExiting: false, hasVisualBlocker: false,
                                    isInteractiveBlocker: false), at: slots[path]!, path: path)
    }
    var candidates = RepeatedPickCandidates()
    candidates.didPublishNativeOrder(geometry, count: order.count)
    let point = Vec2(5, 10)
    #expect(candidates.inputPaths(at: point, order: order, geometry: geometry) == ["41", "130"])
    #expect(candidates.inputPaths(at: Vec2(25, 10), order: order, geometry: geometry).isEmpty)
    // Missing presented geometry falls back to the live flat node during input dispatch.
    geometry["41"] = nil
    candidates.didPublishNativeOrder(geometry, count: order.count)
    #expect(candidates.inputPaths(at: point, order: order, geometry: geometry) == order)
}

@Test func dropFilterCanRepaintAnInitiallyMissedTargetUnderThePointer() {
    var moveTarget: (() -> Void)?
    let rt = Runtime<Bool>(state: false, viewport: Vec2(160, 160)) { moved, _ in
        let filler: [El<Bool>] = (0..<128).map { el().key("f\($0)").size(1, 1).absolute(x: 140, y: 140) }
        let lower: El<Bool> = el().key("lower").size(30, 30).absolute(x: moved ? 0 : 90, y: 0)
            .onDropFiles { _, _, _ in }
        let upper: El<Bool> = el().key("upper").size(30, 30).absolute(x: 0, y: 0)
            .acceptsFiles { _ in moveTarget?(); return false }
        return el().key("root").size(160, 160).children(filler + [lower, upper])
    }
    _ = rt.renderFrame(at: 0)
    moveTarget = { [weak rt] in
        guard let rt else { return }
        rt.state = true
        rt.invalidate(at: 1)
        _ = rt.renderFrame(at: 1)
        rt.settleAll()
        _ = rt.renderFrame(at: 2)
    }
    let hit = rt.dropTargetHitTest(at: Vec2(5, 5), for: [URL(fileURLWithPath: "/file")])
    #expect(rt.state)
    #expect(hit?.key == "lower")
}
