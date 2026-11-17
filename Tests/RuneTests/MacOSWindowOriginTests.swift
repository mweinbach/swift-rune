#if os(macOS)
import AppKit
import Testing
@testable import Rune

@MainActor
@Suite("AppKit content origins and pointer coordinates", .serialized)
struct MacOSWindowOriginTests {
    private struct State {
        var rect: [Float] = []
        var drag: Drag?
    }

    @Test("Moving a decorated window updates screen layout and zoomed drag coordinates")
    func movingWindow() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 50, y: 100, width: 240, height: 180),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        defer { window.orderOut(nil); window.close() }
        let runtime = Runtime(state: State(), viewport: Vec2(240, 180), pixelScale: Float(window.backingScaleFactor)) { _, cx in
            cx.zoom(2)
            return el().wFull().hFull().onScreenLayout { $0.rect = $1 }.onDrag { state, drag, _ in state.drag = drag }
        }
        let view = RuneMetalHostView(frame: NSRect(x: 0, y: 0, width: 240, height: 180), runtime: runtime,
                                     renderer: try MetalRenderer(), timeScale: 1, respectSystemAppearance: false)
        window.contentView = view
        window.orderBack(nil)
        _ = runtime.frame(at: 0)
        let mainHeight = try #require(NSScreen.screens.first).frame.height
        let desktopHeight = CGDisplayBounds(CGMainDisplayID()).height
        let initial = window.convertPoint(toScreen: view.convert(.zero, to: nil))
        #expect(runtime.state.rect == [Float(initial.x), Float(mainHeight - initial.y), 240, 180])

        let scale = window.backingScaleFactor
        // The handle's physical top-left includes the title bar. Its content starts below it.
        MacOSWindowOrigin.setPosition(of: window, x: 200 * scale, y: 140 * scale)
        _ = runtime.frame(at: 0.1)
        let placement = RuneMacWindowConfig.placement(of: window)
        #expect(placement.position.0 == Int32(200 * scale))
        #expect(placement.position.1 == Int32(140 * scale))
        let moved = window.convertPoint(toScreen: view.convert(.zero, to: nil))
        #expect(moved != initial)
        #expect(runtime.state.rect == [Float(moved.x), Float(mainHeight - moved.y), 240, 180])
        #expect(placement.contentPosition.0 == Int32((moved.x * scale).rounded()))
        #expect(placement.contentPosition.1 == Int32(((desktopHeight - moved.y) * scale).rounded()))
        #expect(placement.contentPosition.1 > placement.position.1)
        let point = NSPoint(x: 42, y: 30)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(point, to: nil),
                                                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        let drag = try #require(runtime.state.drag)
        #expect(drag.window == Vec2(21, 15))
        #expect(drag.screenPoint()?.0 == placement.contentPosition.0 + Int32(42 * scale))
        #expect(drag.screenPoint()?.1 == placement.contentPosition.1 + Int32(30 * scale))
        window.contentView = nil
        #expect(runtime.screenPixels(at: .zero) == nil)
    }

    @Test("An overlay reports its new screen rect through its live panel")
    func overlayMove() throws {
        _ = NSApplication.shared
        let handle = OverlayHandle(spec: OverlaySpec(name: "overlay-origin", size: Vec2(120, 60),
                                                      makeState: { State() }) { _, _ in
            el().wFull().hFull().onScreenLayout { $0.rect = $1 }
        })
        handle.setPlacement(.rect(.fromXYWH(45, 76, 120, 60)))
        handle.show()
        defer { handle.hide() }
        let windowNumber = try #require(handle.windowNumber)
        let panel = try #require(NSApp.window(withWindowNumber: Int(windowNumber)))
        let primary = try #require(NSScreen.screens.first).frame
        let first = panel.contentRect(forFrameRect: panel.frame)
        _ = handle.runtime.frame(at: 0.1)
        #expect(handle.runtime.state.rect == [Float(first.minX), Float(primary.height - first.maxY), 120, 60])
        handle.setPlacement(.rect(.fromXYWH(85, 116, 120, 60)))
        _ = handle.runtime.frame(at: 0.2)
        let next = panel.contentRect(forFrameRect: panel.frame)
        #expect(next.origin != first.origin)
        #expect(handle.runtime.state.rect == [Float(next.minX), Float(primary.height - next.maxY), 120, 60])
    }
}
#endif
