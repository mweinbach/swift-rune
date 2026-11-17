#if canImport(UIKit) && !os(watchOS)
import Testing
import UIKit
import RuneMotion
@testable import Rune

@MainActor
struct IOSHostTouchTests {
    @Test("The first contact owns the pan until it lifts or the host detaches")
    func primaryContactAndTeardown() throws {
        let runtime = Runtime(state: 0, viewport: Vec2(200, 200), pixelScale: 1) { _, _ in
            col().key("list").size(200, 200).scrollY(stickBottom: false)
                .children((0..<20).map { i in
                    el().key("row\(i)").size(200, 40).onClick { taps in taps += 1 }
                })
        }
        let view = try RuneIOSView(frame: .zero, runtime: runtime)
        _ = runtime.frame(at: 0)

        view.deliverContact(id: 1, phase: .started, at: Vec2(50, 120), eventTimestamp: nil, time: 0.01)
        view.deliverContact(id: 2, phase: .started, at: Vec2(50, 30), eventTimestamp: nil, time: 0.02)
        view.deliverContact(id: 2, phase: .ended, at: Vec2(50, 30), eventTimestamp: nil, time: 0.03)
        #expect(runtime.touching())

        view.deliverContact(id: 1, phase: .moved, at: Vec2(50, 70), eventTimestamp: nil, time: 0.04)
        #expect(runtime.scrollOffset(forKey: "list").y == 50)
        view.willMove(toWindow: nil)
        #expect(!runtime.touching())
        #expect(runtime.state == 0)

        view.deliverContact(id: 3, phase: .started, at: Vec2(50, 40), button: .primary, eventTimestamp: nil, time: 1)
        #expect(!runtime.touching())
        view.deliverContact(id: 3, phase: .ended, at: Vec2(50, 40), eventTimestamp: nil, time: 1.02)
        #expect(runtime.state == 1)
    }
}
#endif
