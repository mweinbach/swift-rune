import Foundation
import Testing
@testable import Rune

@Suite("Headless scripted gestures")
struct HeadlessGestureParityTests {
    @Test("A scripted swipe delivers the 120 Hz upstream curve and release velocity")
    func swipeTimeline() throws {
        let script = #"[{"t":0.1,"type":"scroll","key":"canvas","dx":-60,"dy":120,"dur":0.2,"fling":true}]"#
        let steps = try HeadlessRunner.parseScript(jsonData: Data(script.utf8))
        try #require(steps.count == 26)
        #expect(steps[0].action == .move)
        var x: Float = 0
        var y: Float = 0
        for index in 1...24 {
            let step = steps[index]
            guard case let .scroll(dx, dy) = step.action else {
                Issue.record("Expected a wheel sample at index \(index)")
                return
            }
            x += dx
            y += dy
            let f = Float(index) / 24
            let distance = f * (2 - f)
            #expect(abs(step.t - (0.1 + Double(index) / 120)) < 1e-9)
            #expect(step.position == .key("canvas"))
            #expect(abs(x + 60 * distance) < 0.0001)
            #expect(abs(y - 120 * distance) < 0.0001)
        }
        #expect(abs(steps[25].t - 0.3001) < 1e-9)
        #expect(steps[25].action == .fling(vx: -150, vy: 300))
    }

    @Test("A headless application receives scripted wheel, rotate and smart magnify at the target")
    func runtimeDelivery() throws {
        final class Events {
            var wheels: [WheelEvent] = []
            var rotate: [RotateEvent] = []
            var smart: [Vec2] = []
        }
        let events = Events()
        let app = App(title: "Gestures", size: Vec2(64, 64), state: ()) { _, _ in
            El<Void>().size(64, 64)
                .onWheel { _, event, _ in events.wheels.append(event); return true }
                .onRotate { _, event, _ in events.rotate.append(event); return true }
                .onSmartMagnify { _, x, y, _ in events.smart.append(Vec2(x, y)); return true }
        }
        var args = ToolingArgs()
        args.scriptArg = """
        [
          {"t":0.02,"type":"scroll","x":18,"y":23,"dy":-40,"dur":0.1},
          {"t":0.13,"type":"wheel","x":18,"y":23,"dy":1,"phase":"ended","precise":false},
          {"t":0.14,"type":"rotate","x":18,"y":23,"degrees":-27,"phase":"began"},
          {"t":0.15,"type":"smart-magnify","x":18,"y":23}
        ]
        """
        args.atTime = 0.18
        args.pixelScale = 1
        _ = try HeadlessRunner.run(app, args: args)
        try #require(events.wheels.count == 13)
        #expect(abs(events.wheels.prefix(12).reduce(Float.zero) { $0 + $1.dy } + 40) < 0.0001)
        #expect(events.wheels.prefix(12).allSatisfy { !$0.precise })
        #expect(events.wheels.last?.precise == false)
        #expect(events.wheels.last?.phase == .ended)
        #expect(events.rotate == [RotateEvent(degrees: -27, x: 18, y: 23, phase: .began)])
        #expect(events.smart == [Vec2(18, 23)])
    }

    @Test("Releasing a swipe continues scrolling, with the same screen travel at either zoom")
    func swipeReleaseInScrollView() throws {
        func finalOffset(zoom: Float, fling: Bool) throws -> Float {
            var last: Float?
            let app = App(title: "Scroll", size: Vec2(100, 100), state: ()) { _, cx in
                cx.zoom(zoom)
                return col().wFull().hFull().scroll(stickBottom: false)
                    .onScrollOffset { last = $0.offset.y }
                    .child(El().wFull().h(500))
            }
            var args = ToolingArgs()
            args.scriptArg = #"[{"t":0.02,"type":"scroll","x":60,"y":60,"dy":-40,"dur":0.1,"fling":\#(fling)}]"#
            args.atTime = 0.35
            args.pixelScale = 1
            _ = try HeadlessRunner.run(app, args: args)
            return try #require(last) * zoom
        }
        let swipe = try finalOffset(zoom: 1, fling: false)
        let release = try finalOffset(zoom: 1, fling: true)
        #expect(abs(swipe - 40) < 0.1)
        #expect(release > swipe + 10)
        #expect(abs(try finalOffset(zoom: 2, fling: false) - swipe) < 0.1)
        #expect(abs(try finalOffset(zoom: 2, fling: true) - release) < 0.1)
    }

    @Test("A resize starts from the outer window size under zoom")
    func zoomedResize() throws {
        let app = App(title: "Resize", size: Vec2(100, 60), state: ()) { _, cx in
            cx.zoom(2)
            return El<Void>().wFull().hFull()
        }
        var args = ToolingArgs()
        args.scriptArg = #"[{"t":0.02,"type":"resize","dw":40,"dh":-10,"dur":0.1}]"#
        args.pixelScale = 1
        args.atTime = 0.15
        let output = try HeadlessRunner.run(app, args: args)
        #expect(output.finalFrame.width == 140)
        #expect(output.finalFrame.height == 50)
    }

    @Test("A virtual desktop delivers a phase and a relative gesture to the window under the pointer")
    func desktopGestureDelivery() throws {
        final class Events {
            var wheels: [WheelEvent] = []
            var rotations: [RotateEvent] = []
        }
        func member(_ key: String, x: Int32, events: Events) -> DesktopWindow<Void> {
            let app = App(title: key, size: Vec2(40, 40), state: ()) { _, _ in
                El<Void>().size(40, 40)
                    .onWheel { _, event, _ in events.wheels.append(event); return true }
                    .onRotate { _, event, _ in events.rotations.append(event); return true }
            }
            var spec = AppWindowSpec(app: app)
            spec.options.position = (x, 0)
            return DesktopWindow(key: key, spec: spec, scale: 1)
        }
        let left = Events()
        let right = Events()
        var args = ToolingArgs()
        args.scriptArg = """
        [
          {"t":0.02,"type":"wheel","x":58,"y":23,"dy":-2,"precise":false,"phase":"began"},
          {"t":0.04,"type":"rotate","degrees":-14,"phase":"ended"}
        ]
        """
        args.pixelScale = 1
        args.atTime = 0.08
        let desktop = try VirtualDesktop.fromScript(object: nil, scale: 1, size: (80, 40))
        _ = try VirtualDesk.runHeadlessDesktop(
            members: [member("left", x: 0, events: left), member("right", x: 40, events: right)],
            args: args, options: RunOptions(), desktop: desktop,
            backdropRGBA: Array(repeating: 0, count: 80 * 40 * 4), width: 80, height: 40
        )
        #expect(left.wheels.isEmpty && left.rotations.isEmpty)
        #expect(right.wheels == [WheelEvent(dy: -2, precise: false, phase: .began, x: 18, y: 23)])
        #expect(right.rotations == [RotateEvent(degrees: -14, x: 18, y: 23, phase: .ended)])
    }
}
