import Testing
@testable import Rune

@Suite("Joined faces in a live virtual list")
struct JoinedRowSeamTests {
    private struct Feed {
        var phase = 0
        var pressed = 0
    }

    @Test("Previously visible faces share their painted and interactive seam while another row crosses",
          arguments: [false, true])
    func drawnAndInteractiveSeam(native: Bool) throws {
        let runtime = Runtime<Feed>(state: Feed(), viewport: Vec2(280, 180), pixelScale: 1) { state, _ in
            let split = state.phase == 1
            func prompt(_ key: String, _ label: String, _ hit: Int) -> El<Feed> {
                col().key(key).wFull().arrivesWhole().joinedRowFace("\(key)/\(label)")
                    .pt(split ? 12 : 4).pb(split ? 20 : 0)
                    .child(el().key(label).wFull().h(30).hit().bg(.white).onClick { $0.pressed = hit })
            }
            let a = prompt("a", "top", 1)
            let b = prompt("b", "bottom", 2)
            let between: El<Feed> = el().key("between").w(20).h(36)
            let order = state.phase == 0 ? [between, a, b] : split ? [a, between, b] : [a, b, between]
            return col().wFull().hFull().scrollY(stickBottom: true).child(
                col().key("rows").wFull().growth().virtualize(40)
                    .child(el().key("older").wFull().h(300)).children(order)
            )
        }
        runtime.motionNeedsCause = true
        runtime.poll = { state, time, tx in
            guard time >= 0.5, state.phase < 2 else { return false }
            state.phase += 1
            tx.growVisibleTail("rows")
            return true
        }
        func draw(at time: Double) {
            if native { _ = runtime.renderFrame(at: time) }
            else { _ = runtime.frame(at: time) }
        }
        var frame = 0
        while runtime.state.phase == 0 && frame <= 36 {
            draw(at: Double(frame) / 60)
            frame += 1
        }
        try #require(runtime.state.phase == 1)
        for step in 0..<36 {
            let top = try #require(runtime.element(byKey: "top")).rect
            let bottom = try #require(runtime.element(byKey: "bottom")).rect
            #expect(abs(bottom[1] - top[1] - top[3] - 4) < 0.05, "frame \(step): \(top), \(bottom)")
            if step == 4 {
                let time = Double(frame - 1) / 60
                for (key, rect, hit) in [("top", top, 1), ("bottom", bottom, 2)] {
                    let position = Vec2(80, rect[1] + 15)
                    #expect(runtime.contains(key, x: position.x, y: position.y))
                    #expect(runtime.elementAt(position.x, position.y)?.key == key)
                    runtime.pointerDown(at: position, at: time)
                    runtime.pointerUp(at: position, at: time)
                    draw(at: time)
                    #expect(runtime.state.pressed == hit)
                }
            }
            draw(at: Double(frame) / 60)
            frame += 1
        }
    }
}
