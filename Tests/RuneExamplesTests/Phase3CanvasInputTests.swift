import Foundation
import Testing
@testable import Rune
@testable import RuneCanvasInput

@Suite("Phase 3 canvas_input example")
@MainActor
struct Phase3CanvasInputTests {
    private func near(_ a: Float, _ b: Float) -> Bool {
        abs(a - b) <= 1.0
    }

    private func settle(_ rt: Runtime<CanvasInputState>, now: inout Double) {
        for _ in 0..<180 {
            now += 1.0 / 60.0
            _ = rt.frame(at: now)
        }
    }

    // Upstream: crates/rune/examples/canvas_input.rs:121
    @Test("canvas_input: wheel pan, pinch zoom, space+drag, middle drag, focus + scrollTo, and onDrawnLayout")
    func canvasInputFullSequence() throws {
        let rt = Runtime<CanvasInputState>(
            state: CanvasInputState(),
            viewport: Vec2(600.0, canvasSize),
            pixelScale: 1.0,
            systemDark: true,
            onKey: onCanvasInputKey,
            view: canvasInputView
        )
        var now = 0.0
        _ = rt.frame(at: now)
        let start = try #require(rt.element(byKey: "node7")?.rect)
        #expect(rt.state.toolbar == start)

        // Wheel pan: moves camera without relayout, updating toolbar via onDrawnLayout.
        now += 1.0 / 60.0
        rt.wheel(WheelEvent(dx: -30.0, dy: -20.0, precise: true), at: Vec2(200.0, 200.0), now: now)
        settle(rt, now: &now)
        let panned = try #require(rt.element(byKey: "node7")?.rect)
        #expect(near(panned[0], start[0] - 30.0) && near(panned[1], start[1] - 20.0))
        #expect(rt.state.toolbar == panned)

        // Pinch about the node's corner: corner stays under pointer and size doubles.
        let q = Vec2(panned[0], panned[1])
        now += 1.0 / 60.0
        #expect(rt.magnify(MagnifyEvent(delta: 1.0), at: q, now: now))
        settle(rt, now: &now)
        let zoomed = try #require(rt.element(byKey: "node7")?.rect)
        #expect(near(zoomed[0], q.x) && near(zoomed[1], q.y) && near(zoomed[2], 160.0))

        // Space + drag pans; releasing Space via onKeyUp stops drag pan.
        let spaceEv = KeyEvent(key: .text(" "))
        now += 1.0 / 60.0
        #expect(rt.keyDown(spaceEv, at: now))
        now += 1.0 / 60.0
        _ = rt.frame(at: now)
        #expect(rt.state.space)

        func drag(_ button: PointerButton) {
            let p = rt.state.screen(Vec2(135.0, 110.0))
            now += 1.0 / 60.0
            rt.pointerMove(to: p, at: now)
            now += 1.0 / 60.0
            rt.pointerDown(at: p, button: button, at: now)
            now += 1.0 / 60.0
            rt.pointerMove(to: Vec2(p.x - 20.0, p.y - 10.0), at: now)
            now += 1.0 / 60.0
            rt.pointerMove(to: Vec2(p.x - 40.0, p.y - 20.0), at: now)
            now += 1.0 / 60.0
            rt.pointerUp(at: Vec2(p.x - 40.0, p.y - 20.0), button: button, at: now)
            settle(rt, now: &now)
        }

        drag(.primary)
        let spaced = try #require(rt.element(byKey: "node7")?.rect)
        #expect(near(spaced[0], zoomed[0] - 40.0) && near(spaced[1], zoomed[1] - 20.0))

        now += 1.0 / 60.0
        #expect(rt.keyUp(spaceEv, at: now))
        now += 1.0 / 60.0
        _ = rt.frame(at: now)
        #expect(!rt.state.space)

        drag(.primary)
        let afterRelease = try #require(rt.element(byKey: "node7")?.rect)
        #expect(afterRelease == spaced)

        // Middle button drags to pan with no key held.
        drag(.middle)
        let middled = try #require(rt.element(byKey: "node7")?.rect)
        #expect(near(middled[0], spaced[0] - 40.0) && near(middled[1], spaced[1] - 20.0))

        // Select node13 on the 2x zoomed canvas, then Focus: camera centres it & layer13 glides into view.
        let n13 = try #require(rt.element(byKey: "node13")?.rect)
        let n13Pt = Vec2(n13[0] + n13[2] * 0.5, n13[1] + n13[3] * 0.5)
        #expect(n13Pt.x > 0 && n13Pt.x < canvasSize && n13Pt.y > 0 && n13Pt.y < canvasSize)
        now += 1.0 / 60.0
        rt.pointerDown(at: n13Pt, at: now)
        now += 1.0 / 60.0
        rt.pointerUp(at: n13Pt, at: now)
        now += 1.0 / 60.0
        _ = rt.frame(at: now)
        #expect(rt.state.selected == 13)

        let focusRect = try #require(rt.element(byKey: "focus")?.rect)
        let focusPt = Vec2(focusRect[0] + focusRect[2] * 0.5, focusRect[1] + focusRect[3] * 0.5)
        now += 1.0 / 60.0
        rt.pointerDown(at: focusPt, at: now)
        now += 1.0 / 60.0
        rt.pointerUp(at: focusPt, at: now)
        now += 1.0 / 60.0
        _ = rt.frame(at: now)
        now += 1.0 / 60.0
        _ = rt.frame(at: now)
        let gliding = try #require(rt.element(byKey: "layer13")?.rect[1])

        settle(rt, now: &now)
        let focused = try #require(rt.element(byKey: "node13")?.rect)
        let rowRect = try #require(rt.element(byKey: "layer13")?.rect)
        #expect(near(focused[0] + focused[2] * 0.5, canvasSize * 0.5))
        #expect(near(focused[1] + focused[3] * 0.5, canvasSize * 0.5))
        #expect(gliding > rowRect[1] && near(rowRect[1], canvasLayerRowHeight))
        #expect(rt.state.toolbar == focused)
    }
}
