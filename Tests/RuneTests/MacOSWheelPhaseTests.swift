#if os(macOS)
import AppKit
import Testing
@testable import Rune

@MainActor
@Suite("AppKit wheel phases")
struct MacOSWheelPhaseTests {
    @Test func boundariesPreferMomentumOverTouch() {
        let phases: [(NSEvent.Phase, GesturePhase)] = [
            ([], .changed), (.mayBegin, .began), (.began, .began), (.changed, .changed),
            (.stationary, .changed), (.ended, .ended), (.cancelled, .ended),
            ([.began, .changed], .changed),
        ]
        for (touch, contact) in phases {
            for (momentum, coast) in phases {
                #expect(WheelDistance.appKitPhase(touch: touch, momentum: momentum) ==
                        (coast == .changed ? contact : coast))
            }
        }
    }

    @Test func nativeEventsPreserveDistanceModifiersAndPhase() throws {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                      wheel1: -9, wheel2: 3, wheel3: 0))
        cg.flags = [.maskShift, .maskCommand]
        for (contact, coast, expected) in [
            (CGScrollPhase.began, CGMomentumScrollPhase.none, GesturePhase.began),
            (.changed, .none, .changed), (.ended, .none, .ended), (.cancelled, .none, .ended),
            (.ended, .begin, .began), (.began, .end, .ended), (.changed, .continuous, .changed),
        ] {
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(contact.rawValue))
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(coast.rawValue))
            let native = try #require(NSEvent(cgEvent: cg))
            let wheel = WheelDistance.appKitEvent(native)
            #expect(wheel.phase == expected)
            #expect(wheel.precise && wheel.dx == 3 && wheel.dy == -9)
            #expect(wheel.mods.shift && wheel.mods.cmd)
        }
        let mouse = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                         wheel1: 2, wheel2: 0, wheel3: 0))
        let native = try #require(NSEvent(cgEvent: mouse))
        let wheel = WheelDistance.appKitEvent(native)
        #expect(!wheel.precise && wheel.phase == .changed)
        #expect(wheel.dy == Float(native.scrollingDeltaY) * WheelDistance.linePoints)
    }
}
#endif
