import Foundation
import Testing
import RuneMotion
@testable import Rune
@testable import RuneKit
#if canImport(Metal)
import Metal
#endif

@MainActor
@Suite struct FeedbackMotionTests {
    @Test func radarGeometryAndWallClockSamplesMatchRust() {
        // Fingerprints from feedback/radar.rs and rune-motion/src/cycle.rs at 842c28c2.
        let samples: [(Double, UInt64)] = [
            (0, 0x3cd8f5413a1b7980), (0.027, 0xddaac1caaaebdb56),
            (0.14, 0xf9e347c8df424295), (0.47, 0x862093ebd2aea886),
            (1.97, 0x77811b04aaa9dfa0), (8.2, 0xcd20b44712b312b9),
        ]
        for (wall, expected) in samples {
            var hash: UInt64 = 0xcbf29ce484222325
            for dot in RadarGrid.dots {
                for v in [dot.x, dot.y, dot.size, dot.stillOpacity, RadarGrid.phaseOpacity(dot: dot, at: wall)] {
                    hash = (hash ^ UInt64(v.bitPattern)) &* 0x100000001b3
                }
            }
            #expect(hash == expected)
        }
    }

    private func radar() -> WebAppHost<Bool> {
        let kit = Kit.neutral(dark: false)
        let spec = AppSpec(title: "Radar", size: Vec2(96, 48), state: false) { state, _ in
            row().wFull().hFull()
                .child(Spinner<Bool>().size(28).color(state ? .black : .white).build(kit))
                .child(el().key("toggle").size(50, 28).onClick { $0.toggle() })
        }
        return WebAppHost(spec: spec)
    }

    @Test func restingCycleMatchesEveryFullPaintAndRetainsEarlierSnapshots() throws {
        let host = radar(), reference = radar()
        let session = WebBrowserSession(host)
        let initial = try session.renderFrame(at: 0)
        let first = try #require(initial)
        _ = try reference.renderGPUFrame(at: 0)
        let serial = host.runtime.cyclePaint.serial
        #expect(host.runtime.cyclePaint.slots.count == 24)
        #expect(host.runtime.element(byKey: "radar-spinner-d12")?.a11yHidden == true)
        #expect(try session.renderFrame(at: 0.001) == nil)
        for wall in [0.027, 0.14, 0.47, 1.97] {
            let scheduled = try session.renderFrame(at: wall)
            let fast = try #require(scheduled)
            let fresh = try reference.renderGPUFrame(at: wall)
            #expect(host.runtime.cyclePaint.serial == serial)
            #expect(fast.instances == fresh.instances && fast.marks == fresh.marks)
            #expect(host.runtime.motionWakeDeadline() == wall + Double(Float(1) / 60))
            for slot in host.runtime.cyclePaint.slots {
                #expect(host.runtime.lastElements[slot.element].opacity == slot.curve.sample(at: wall))
                #expect(host.runtime.hitGeometryByPath[slot.path]?.opacity == slot.curve.sample(at: wall))
            }
            #expect(fast.instances != first.instances)
            let paint = host.runtime.cyclePaint
            let packet = UnsafeMutableRawBufferPointer.allocate(byteCount: WebCyclePacket.size(slotCount: paint.slots.count), alignment: 4)
            defer { packet.deallocate() }
            WebCyclePacket.write(scene: fast, paint: paint, to: packet.baseAddress!)
            let words = packet.bindMemory(to: UInt32.self)
            #expect(packet.count == 600 && words[0] == WebCyclePacket.magic && words[5] == 24)
            for (i, slot) in paint.slots.enumerated() {
                #expect(words[6 + i * 6] == UInt32(slot.index))
                #expect(Float(bitPattern: words[11 + i * 6]) == fast.instances[slot.index].params.w)
            }
        }
        let original = try radar().renderGPUFrame(at: 0)
        #expect(original.instances == first.instances)
    }

    @Test func offscreenLoopsSleepAndInteractiveLeavesUseOrdinaryPaint() throws {
        let curve = Cycle(period: 1, stops: [(0, 0.2), (0.5, 0.8), (1, 0.2)])
        let spec = AppSpec(title: "Cycle eligibility", size: Vec2(100, 60), state: false) { show, _ in
            el().wFull().hFull().child(
                el().key("interactive").absolute(x: 0, y: show ? 10 : 180).size(14, 14)
                    .bg(.white).a11yHidden().onClick { $0.toggle() }.cycle(curve))
        }
        let host = WebAppHost(spec: spec)
        _ = try host.renderGPUFrame(at: 0)
        #expect(!host.runtime.isAnimating && host.runtime.motionWakeDeadline() == nil)
        host.runtime.state = true
        host.runtime.markNeedsCommit(settle: true)
        _ = try host.renderGPUFrame(at: 0.1)
        #expect(host.runtime.motionWakeDeadline() != nil && host.runtime.cyclePaint.slots.isEmpty)
        let paint = host.runtime.cyclePaint.serial
        _ = try host.renderGPUFrame(at: 0.2, allowCycle: true)
        #expect(host.runtime.cyclePaint.serial > paint)
    }

    @Test func nominalSixtyHertzDisplaySamplesEachTickAndKeepsAppTimersExact() throws {
        let host = radar(), session = WebBrowserSession(host)
        _ = try session.renderFrame(at: 0)
        let serial = host.runtime.cyclePaint.serial
        for tick in 1...120 {
            let frame = try session.renderFrame(at: Double(tick) / 60)
            #expect(frame != nil && host.runtime.cyclePaint.serial == serial)
        }
        let due = 2 + 1.0 / 60
        host.runtime.wakeAt(due - 0.0001)
        let early = try session.renderFrame(at: due - 0.0003)
        #expect(early == nil)
        let timerFrame = try session.renderFrame(at: due)
        #expect(timerFrame != nil && host.runtime.cyclePaint.serial > serial)
    }

    private final class UIPasses: Compositor {
        typealias State = Bool
        var drawsOwnContent = false
        var draws = 0
        func render(frame: CompositorFrame<Bool>) {
            draws += 1
            frame.drawUI()
            frame.drawUI()
        }
    }

    @Test func passiveCompositorReceivesCycleFramesAndOwnContentTakesAFullFrame() throws {
        let passes = UIPasses()
        let kit = Kit.neutral(dark: true)
        let app = App(title: "Composited radar", size: Vec2(50, 50), state: false) { _, _ in
            Spinner<Bool>().size(16).build(kit)
        }.compositor(passes)
        let host = WebAppHost(app: app)
        _ = try host.renderGPUFrame(at: 0)
        let serial = host.runtime.cyclePaint.serial
        _ = try host.renderGPUFrame(at: 0.1, allowCycle: true)
        #expect(host.runtime.cyclePaint.serial == serial && passes.draws == 2 && host.uiPasses == 2)
        passes.drawsOwnContent = true
        _ = try host.renderGPUFrame(at: 0.2, allowCycle: true)
        #expect(host.runtime.cyclePaint.serial > serial && passes.draws == 3)
    }

    @Test func inputTimersAndReducedMotionTakeOrdinaryFrames() throws {
        let host = radar()
        let session = WebBrowserSession(host)
        _ = try session.renderFrame(at: 0)
        var serial = host.runtime.cyclePaint.serial
        host.runtime.wakeAt(0.03)
        _ = try session.renderFrame(at: 0.04)
        #expect(host.runtime.cyclePaint.serial > serial)
        serial = host.runtime.cyclePaint.serial
        for phase in ["pointerdown", "pointerup"] {
            let data = Data("""
                {"kind":"\(phase)","x":40,"y":10,"button":"primary","pointerType":"mouse"}
                """.utf8)
            #expect(session.send(data, at: 0.06))
        }
        _ = try session.renderFrame(at: 0.06)
        #expect(host.runtime.state)
        #expect(host.runtime.cyclePaint.serial > serial)
        host.runtime.setSystemReducedMotion(true)
        _ = try session.renderFrame(at: 0.1)
        #expect(host.runtime.motionWakeDeadline() == nil)
        #expect(host.runtime.cyclePaint.slots.isEmpty)
        for (i, dot) in RadarGrid.dots.enumerated() {
            #expect(host.runtime.element(byKey: "radar-spinner-d\(i)")?.opacity == dot.stillOpacity)
        }
    }

    @Test func continuousGPUFeedbackMovesAndStopsAtItsReducedMotionPose() throws {
        let kit = Kit.neutral(dark: false)
        let spec = AppSpec(title: "Loading", size: Vec2(120, 60), state: ()) { _, _ in
            col().wFull().hFull().child(kit.ringLoader()).child(Progress<Void>(value: nil).build(kit))
        }
        let host = WebAppHost(spec: spec)
        let start = try host.renderGPUFrame(at: 0)
        let initialFill = try #require(host.runtime.element(byKey: "progress-fill")?.rect)
        #expect(host.runtime.isAnimating)
        let moving = try host.renderGPUFrame(at: 0.35, allowCycle: true)
        let movedFill = try #require(host.runtime.element(byKey: "progress-fill")?.rect)
        #expect(moving.instances != start.instances && movedFill[0] > initialFill[0])
        #expect(moving.instances.contains { $0.params.y == KIND_LAYER && abs($0.border.y) > 0.1 })
        host.runtime.setSystemReducedMotion(true)
        let still = try host.renderGPUFrame(at: 0.5)
        #expect(!host.runtime.isAnimating && host.runtime.motionWakeDeadline() == nil)
        let later = try host.renderGPUFrame(at: 2)
        #expect(still.instances == later.instances)
    }

    #if canImport(Metal)
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func cycleMatchesFullPaintOnMetal() throws {
        let host = radar(), reference = radar(), renderer = try OffscreenGPURenderer()
        let initial = try renderer.renderOffscreen(host.renderGPUFrame(at: 0))
        _ = try reference.renderGPUFrame(at: 0)
        let frame = try host.renderGPUFrame(at: 0.47, allowCycle: true)
        let actual = try renderer.renderOffscreen(frame)
        let oracle = try renderer.renderOffscreen(reference.renderGPUFrame(at: 0.47))
        #expect(actual.rgba == oracle.rgba)
        #expect(initial.rgba != actual.rgba)
    }
    #endif
}
