import Testing
@testable import Rune

@MainActor
@Suite("Desktop input in a zoomed window")
struct DesktopInputZoomTests {
    @Test func windowsContactRetainsItsOriginAndIdentityThroughRelease() {
        let runtime = Runtime(state: [Bool](), viewport: Vec2(300, 200), pixelScale: 1.5) { _, cx in
            cx.zoom(2)
            return el().size(60, 50).onClick { taps, tx in taps.append(tx.touchTap()) }
        }
        _ = runtime.frame(at: 0)
        var dpi: UInt32 = 144
        func contact(_ id: UInt32, _ phase: TouchPhase, _ now: Double) {
            _ = Win32MessageTranslator.dispatch(.touch(id: id, phase: phase, x: 120, y: 90),
                                                to: runtime, dpi: &dpi, at: now)
        }
        contact(7, .started, 0.1)
        #expect(runtime.pointerPosition == Vec2(40, 30))
        contact(8, .started, 0.11)
        contact(8, .ended, 0.12)
        #expect(runtime.touching() && runtime.state.isEmpty)
        contact(7, .ended, 0.13)
        #expect(runtime.state == [true])
        contact(7, .started, 0.2)
        contact(7, .cancelled, 0.21)
        contact(7, .ended, 0.22)
        #expect(!runtime.touching() && runtime.state == [true])
        _ = Win32MessageTranslator.dispatch(.mouseDown(button: .primary, x: 120, y: 90), to: runtime, dpi: &dpi, at: 1)
        _ = Win32MessageTranslator.dispatch(.mouseUp(button: .primary, x: 120, y: 90), to: runtime, dpi: &dpi, at: 1.1)
        #expect(runtime.state == [true, false])
    }

    private struct Events {
        var clicks = 0
        var wheel: WheelEvent?
        var magnify: MagnifyEvent?
    }

    @Test(arguments: [Float(0.5), 2])
    func pointerAndWheel(zoom: Float) {
        let runtime = Runtime(state: Events(), viewport: Vec2(400, 300), pixelScale: 1.5) { _, cx in
            cx.zoom(zoom)
            return el().size(70, 60)
                .onClick { $0.clicks += 1 }
                .onWheel { state, event, _ in state.wheel = event; return true }
                .onMagnify { state, event, _ in state.magnify = event; return true }
        }
        _ = runtime.frame(at: 0)
        var dpi: UInt32 = 144
        let x = 55 * zoom * 1.5, y = 40 * zoom * 1.5
        _ = Win32MessageTranslator.dispatch(.mouseMove(x: x, y: y), to: runtime, dpi: &dpi, at: 0.1)
        #expect(runtime.pointerPosition == Vec2(55, 40))
        _ = Win32MessageTranslator.dispatch(.mouseDown(button: .primary, x: x, y: y), to: runtime, dpi: &dpi, at: 0.2)
        _ = Win32MessageTranslator.dispatch(.mouseUp(button: .primary, x: x, y: y), to: runtime, dpi: &dpi, at: 0.3)
        #expect(runtime.state.clicks == 1)

        let point = runtime.inputPoint(fromWindow: Vec2(x / 1.5, y / 1.5))
        runtime.desktopWheel(dx: 0, dy: 120, at: point, mods: .none, now: 0.4)
        #expect(runtime.state.wheel?.dy == 120 / zoom)
        #expect(runtime.state.wheel?.x == 55 && runtime.state.wheel?.y == 40)
        runtime.desktopWheel(dx: 0, dy: -20, at: point, mods: Mods(ctrl: true), now: 0.5)
        #expect(runtime.state.magnify?.delta == 0.1)
        #expect(runtime.state.wheel?.dy == 120 / zoom)
    }

    @Test("Page scroll resolves against the scroller under the pointer")
    func pageWheel() {
        let runtime = Runtime(state: (), viewport: Vec2(400, 300), pixelScale: 1) { _, cx in
            cx.zoom(2)
            return col().wFull().hFull().child(
                col().size(80, 60).scroll(ScrollSpec()).child(el().size(70, 500).shrink(0)))
        }
        _ = runtime.frame(at: 0)
        let inside = Vec2(20, 20), outside = Vec2(150, 100)
        #expect(runtime.windowsWheelLinePoints(count: .max, ticks: 1, horizontal: false, shift: false, at: inside) == 105)
        #expect(runtime.windowsWheelLinePoints(count: .max, ticks: 1, horizontal: false, shift: false, at: outside) == 262.5)
        #expect(runtime.windowsWheelLinePoints(count: .max, ticks: 0, horizontal: false, shift: false, at: inside) == 0)
    }

    @Test("Native popup anchors stay under their point or keyed element at 2× page zoom")
    func popupAnchors() throws {
        let runtime = Runtime(state: (), viewport: Vec2(400, 300), pixelScale: 1.5) { _, cx in
            cx.zoom(2)
            return col().wFull().hFull().child(el().key("button").absolute(x: 15, y: 25).size(60, 20))
        }
        _ = runtime.frame(at: 0)
        for (anchor, expected) in [(PopupAnchor.point(30, 40), PopupShowAnchor.point(60, 80)),
                                   (.key("button"), .rect(.fromXYWH(30, 50, 120, 40)))] {
            runtime.update(at: 0.1) { _, tx in
                tx.popupMenu(PopupMenu().item("open", "Open"), at: anchor) { (_: inout Void, _, _) in }
            }
            _ = runtime.frame(at: 0.2)
            let show = try #require(runtime.takePopup()).get()
            #expect(show.anchor == expected)
            try runtime.resolvePopup(nil)
        }
    }
}
