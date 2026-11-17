import AppKit
import Rune

/// Run with `swift run --package-path Tests/Support/MacOSWindowFrame MacOSWindowFrame wheel single|grouped|overlay`.
@MainActor
final class WheelPhaseProbe {
    private var observed: [WheelEvent] = []

    nonisolated private static func fail(_ reason: String) -> Never {
        FileHandle.standardError.write(Data("FAIL \(reason)\n".utf8))
        exit(1)
    }

    static func run(host: String) throws {
        let probe = WheelPhaseProbe()
        let title = "Rune wheel phases \(getpid())"
        let view: (Int, inout Cx<Int>) -> El<Int> = { _, _ in
            el().sizeFull().onWheel { _, event, tx in
                probe.observed.append(event)
                tx.liveOnly()
                return true
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { fail("wheel probe timed out") }
        if host == "overlay" {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let options = OverlayOptions(interactive: true)
            let handle = OverlaySpec(name: title, size: Vec2(160, 120), interactive: true, options: options,
                                     makeState: { 0 }, view: view).configured(options).makeHandle()
            handle.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let number = handle.windowNumber, let window = app.window(withWindowNumber: Int(number))
                else { fail("missing native overlay") }
                probe.exercise(host: host, window: window)
            }
            app.run()
            return
        }
        let app = App(title: title, size: Vec2(160, 120), state: 0, view: view)
            .openInactive().accessory().keepRunning().onReady { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let window = NSApp.windows.first(where: { $0.title == title }) else { fail("missing native window") }
                    probe.exercise(host: host, window: window)
                }
            }
        switch host {
        case "single": try app.run(arguments: [])
        case "grouped": try RuneMultiWindow.runWindows([AppWindowSpec(app: app).boxed()], options: RunOptions(accessory: true), arguments: [])
        default: Self.fail("expected single, grouped or overlay")
        }
    }

    private func exercise(host: String, window: NSWindow) {
        let sequence: [(touch: CGScrollPhase?, coast: CGMomentumScrollPhase, phase: GesturePhase, momentum: Bool)] = [
            (.began, .none, .began, false), (.changed, .none, .changed, false), (.ended, .none, .ended, false),
            (nil, .begin, .began, true), (nil, .continuous, .changed, true), (nil, .end, .ended, true),
        ]
        // Process-targeted input arrives without a window number. Keep the cursor in place and
        // route the delivered NSEvents to the hit-tested view in this probe's own window.
        let point = CGPoint(x: 50, y: 50)
        guard let root = window.contentView, let target = root.hitTest(root.convert(point, from: nil))
        else { Self.fail("missing native wheel responder") }
        var delivered: [NSEvent] = []
        for (i, step) in sequence.enumerated() {
            let dy: Int32 = step.phase == .ended ? 0 : 3
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)
            else { Self.fail("cannot construct native scroll") }
            cg.location = CGPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y)
            cg.setIntegerValueField(.eventSourceUserData, value: Int64(i + 100))
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(step.touch?.rawValue ?? 0))
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(step.coast.rawValue))
            cg.postToPid(getpid())
            guard let event = NSApp.nextEvent(matching: .scrollWheel, until: Date(timeIntervalSinceNow: 2), inMode: .default, dequeue: true),
                  event.cgEvent?.getIntegerValueField(.eventSourceUserData) == Int64(i + 100)
            else { Self.fail("missing WindowServer event \(i)") }
            delivered.append(event)
        }
        for event in delivered { target.scrollWheel(with: event) }
        guard observed.count == sequence.count else { Self.fail("\(host) \(target) handled \(observed.count) of \(sequence.count) events") }
        for (i, event) in observed.enumerated() {
            guard event.phase == sequence[i].phase, event.momentum == sequence[i].momentum, event.precise,
                  event.dy == Float(delivered[i].scrollingDeltaY)
            else { Self.fail("\(host) event \(i) yielded \(event)") }
        }
        let phases = observed.map { $0.phase.rawValue + ($0.momentum ? "(momentum)" : "") }
        print("PASS \(host) \(type(of: target)) delivered \(phases.joined(separator: ", "))")
        exit(0)
    }
}
