#if os(macOS)
import AppKit
import Metal
import RuneMotion
import Testing
@testable import Rune

/// The native Metal path in upstream overlay/frame.rs submits directly to one command queue.
/// Its optional wgpu worker has a different surface-ownership contract.
@MainActor
struct OverlayMetalSubmissionTests {
    private func metalView<S>(_ overlay: OverlayHandle<S>) throws -> RuneOverlayMetalView<S> {
        let number = try #require(overlay.windowNumber)
        let panel = try #require(NSApplication.shared.window(withWindowNumber: Int(number)))
        #expect(!panel.isOpaque)
        let root = try #require(panel.contentView)
        return try #require(([root] + root.subviews).compactMap { $0 as? RuneOverlayMetalView<S> }.first)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func fourFramesStayOrderedWhenThePanelIsReleasedWithWorkInFlight() throws {
        _ = NSApplication.shared
        let probe = OrderedOverlayGPUProbe()
        let options = OverlayOptions(input: .none)
        let overlay = OverlaySpec<Void>(name: "Ordered Metal frames", size: Vec2(48, 32),
                                        options: options, makeState: { () }) { _, _ in
            el().size(48, 32).child(el().absolute(x: 0, y: 0).size(12, 12).bg(.white))
        }.configured(options).releaseGpuWhenHidden().compositor(probe).makeHandle()
        overlay.show()
        defer { overlay.hide() }
        let view = try metalView(overlay)
        let device = try #require((view.layer as? CAMetalLayer)?.device)
        let gate = try #require(device.makeSharedEvent())
        let stamp = try #require(device.makeBuffer(length: 4, options: .storageModeShared))
        let samples = try #require(device.makeBuffer(length: 4 * OrderedOverlayGPUProbe.stride,
                                                     options: .storageModeShared))
        memset(stamp.contents(), 0, 4)
        memset(samples.contents(), 0xAA, samples.length)
        probe.capture = (gate, stamp, samples)
        defer { gate.signaledValue = 1 }
        // Bound the wait if an implementation starts waiting for GPU completion on the UI thread.
        let watchdog = DispatchWorkItem { gate.signaledValue = 1 }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        defer { watchdog.cancel() }

        let before = view.submittedFrames
        for index in 0..<4 {
            let snapshot = view.renderFrame()
            #expect(snapshot.frameCount == before + UInt64(index + 1))
            let done = try #require(probe.completions.last)
            if index == 1 { #expect(done.wait(timeout: .now() + 3) == .success) }
        }
        #expect(probe.completions.count == 4)
        let last = try #require(probe.completions.last)
        #expect(gate.signaledValue == 0)
        #expect(last.wait(timeout: .now()) == .timedOut)
        overlay.hide()
        #expect(!view.hasRenderer)
        #expect(gate.signaledValue == 0)
        gate.signaledValue = 1
        for done in probe.completions { #expect(done.wait(timeout: .now() + 3) == .success) }
        let bytes = samples.contents().assumingMemoryBound(to: UInt8.self)
        for index in 0..<4 {
            let record = bytes.advanced(by: index * OrderedOverlayGPUProbe.stride)
            #expect(record[0] == UInt8(index))
            #expect(Array(UnsafeBufferPointer(start: record + 256, count: 4)) == [255, 255, 255, 255])
            #expect(Array(UnsafeBufferPointer(start: record + 512, count: 4)) == [0, 0, 0, 0])
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func rejectedFrameLeavesTheNextOrdinaryPresentUsable() throws {
        _ = NSApplication.shared
        let overlay = OverlayHandle(spec: OverlaySpec<Void>(name: "Metal retry", size: Vec2(24, 24),
                                      makeState: { () }, view: { _, _ in el().size(12, 12).bg(.white) }))
        overlay.show()
        defer { overlay.hide() }
        let view = try metalView(overlay)
        let evaluate = try #require(view.onEvaluateFrame)
        // Reject this frame in the real Metal size validator, before it borrows a command buffer.
        view.onEvaluateFrame = { now, settle, renderer, materials in
            var result = evaluate(now, settle, renderer, materials)
            result?.frame.width = 0
            return result
        }
        let before = view.submittedFrames
        #expect(view.renderFrame().frameCount == before)
        view.onEvaluateFrame = evaluate
        #expect(view.renderFrame().frameCount == before + 1)
    }
}

private final class OrderedOverlayGPUProbe: Compositor {
    static let stride = 768
    var capture: (gate: MTLSharedEvent, stamp: MTLBuffer, samples: MTLBuffer)?
    var completions: [DispatchGroup] = []

    func render(frame: CompositorFrame<Void>) {
        guard let capture, completions.count < 4,
              let command = frame.commandBuffer, let texture = frame.targetTexture else {
            frame.drawUI()
            return
        }
        let index = completions.count
        if index == 2 { command.encodeWaitForEvent(capture.gate, value: 1) }
        frame.drawUI()
        guard let blit = command.makeBlitCommandEncoder() else {
            Issue.record("Could not read the overlay drawable")
            return
        }
        let offset = index * Self.stride
        // Each GPU job must see its predecessor's write, including two outstanding at release.
        blit.copy(from: capture.stamp, sourceOffset: 0, to: capture.samples, destinationOffset: offset, size: 4)
        blit.fill(buffer: capture.stamp, range: 0..<4, value: UInt8(index + 1))
        let size = MTLSize(width: 1, height: 1, depth: 1)
        for (origin, destination) in [(MTLOrigin(x: 2, y: 2, z: 0), offset + 256),
                                      (MTLOrigin(x: texture.width - 2, y: texture.height - 2, z: 0), offset + 512)] {
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin, sourceSize: size,
                      to: capture.samples, destinationOffset: destination, destinationBytesPerRow: 256,
                      destinationBytesPerImage: 256)
        }
        blit.endEncoding()
        // Observe completion without retaining the drawable or command buffer across teardown.
        let done = DispatchGroup()
        done.enter()
        command.addCompletedHandler { finished in
            #expect(finished.status == .completed)
            done.leave()
        }
        completions.append(done)
    }
}
#endif
