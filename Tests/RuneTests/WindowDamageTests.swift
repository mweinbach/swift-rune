import Testing
@testable import Rune

@Suite("Windows covered frame scheduling")
struct Win32WindowLookTests {
    @Test func quietWindowSleepsAndVisibleMotionChecksForReveal() {
        var look = Win32WindowLook.due
        #expect(look.shouldLook(at: 0))
        look.found(seen: true, moving: true, at: 1)
        #expect(!look.shouldLook(at: 1.249))
        #expect(look.shouldLook(at: 1.25))
        look.found(seen: false, moving: true, at: 2)
        #expect(look.deadline == 2.25)
        look.found(seen: false, moving: true, at: 2.25)
        #expect(look.deadline == 2.75)
        look.found(seen: false, moving: true, at: 2.75)
        #expect(look.deadline == 3.75)
        look.found(seen: false, moving: true, at: 3.75)
        #expect(look.deadline == 4.75)
        look.found(seen: false, moving: false, at: 4)
        #expect(look.deadline == nil)
        look.found(seen: true, moving: false, at: 4.125)
        #expect(!look.shouldLook(at: 4.25))
    }

    @Test func updatesCoalesceAndContinuousChangesStillPresent() {
        var draw = Win32CoveredDraw()
        draw.asked(at: 10)
        draw.asked(at: 10.1875)
        let originalDeadline = draw.takeDue(at: 10.25)
        #expect(!originalDeadline)
        let afterQuietPeriod = draw.takeDue(at: 10.4375)
        #expect(afterQuietPeriod)
        #expect(draw.deadline == nil)
        for i in 0..<9 { draw.asked(at: 20 + Double(i) / 10) }
        #expect(draw.deadline == 21)
        let beforeMaximumWait = draw.takeDue(at: 20.99)
        #expect(!beforeMaximumWait)
        let atMaximumWait = draw.takeDue(at: 21)
        #expect(atMaximumWait)
        let alreadyDrawn = draw.takeDue(at: 22)
        #expect(!alreadyDrawn)
    }
}

#if (os(macOS) || os(Linux) || os(Windows)) && canImport(CRuneOffscreenGL)
import CRuneGL
import Foundation
import RuneRef

@MainActor
@Suite("Incremental GPU frame damage")
struct WindowDamageTests {
    @Test func dragPreviewReadsTheBoundPresentationFramebuffer() throws {
        try withTestGLTarget { renderer, capture in
            let box = RenderInstance(rect: SIMD4(0, 0, 12, 6), fill: SIMD4(1, 0, 0, 1))
            let frame = RenderFrame(width: 12, height: 12, clearColor: SIMD4(0, 1, 0, 1), instances: [box])
            var crop = [UInt8](repeating: 0, count: 4 * 6 * 4)
            let full = try capture(12, 12) {
                try renderer.draw(frame)
                let captured = crop.withUnsafeMutableBufferPointer {
                    rune_gl_window_snapshot(OffscreenGLContext.resolve, 2, 3, 4, 6, 12, $0.baseAddress, $0.count)
                }
                #expect(captured == 1)
            }
            for y in 0..<6 {
                let start = ((y + 3) * 12 + 2) * 4
                #expect(crop[(y * 16)..<(y * 16 + 16)].elementsEqual(full.rgba[start..<(start + 16)]))
            }
            #expect(crop[0] == 255 && crop[4 * 5 * 4 + 1] == 255)
        }
    }

    @Test func comparePartialPresentationToFullReplay() throws {
        let context = try OffscreenGLContext()
        defer { context.close() }
        // Android supplies the same bundled stock shaders through the APK asset manager.
        let partial = try PortableGLRenderer(resolve: OffscreenGLContext.resolve, isGLES: OffscreenGLContext.isGLES,
                                             bundledShaderAssets: true, shaderSource: PortableGLRenderer.bundledShader)
        defer { partial.close() }
        // A client-provided shader pipeline always receives whole frames.
        let full = try PortableGLRenderer(resolve: OffscreenGLContext.resolve, isGLES: OffscreenGLContext.isGLES,
                                          shaderSource: PortableGLRenderer.bundledShader)
        defer { full.close() }
        let wholeForced = ProcessInfo.processInfo.environment["RUNE_WHOLE_FRAMES"] == "1"
        func compare(_ frame: RenderFrame, damage: Int32) throws {
            let a = try context.withFramebuffer(width: frame.width, height: frame.height) { try partial.draw(frame) }
            let b = try context.withFramebuffer(width: frame.width, height: frame.height) { try full.draw(frame) }
            #expect(a.rgba == b.rgba)
            #expect(rune_gl_last_frame_damage(partial.handle) == (wholeForced ? -1 : damage))
            #expect(rune_gl_last_frame_damage(full.handle) == -1)
        }
        let instances: [RenderInstance] = (0..<300).map { i in
            let x = Float(4 + (i % 12) * 15)
            let y = Float(3 + (i / 12) * 7)
            return RenderInstance(rect: SIMD4<Float>(x, y, 15, 13), fill: SIMD4<Float>(0.65, 0.12, 0, 0.7))
        }
        var frame = RenderFrame(width: 192, height: 192, clearColor: SIMD4(0.07, 0.1, 0.13, 0.8),
                                glyphs: R8Atlas(width: 1, height: 1, texels: [190]), instances: instances)
        try compare(frame, damage: -1)
        try compare(frame, damage: 0)
        frame.instances[2].fill.x = 0.3
        frame.instances[299].fill.x = 0.5
        try compare(frame, damage: 2)
        frame.instances[4].params = SIMD4(0.7, KIND_GLYPH, 0, 1)
        frame.instances[4].uv = SIMD4(0, 0, 1, 1)
        try compare(frame, damage: 1)
        frame.instances[4].params.x = 2
        try compare(frame, damage: 1)
        frame.glyphs.texels[0] = 32
        try compare(frame, damage: -1)
        try compare(frame, damage: 0)
        frame.instances.swapAt(22, 23)
        try compare(frame, damage: -1)
        let last = frame.instances.removeLast()
        try compare(frame, damage: 1)
        frame.instances.append(last)
        try compare(frame, damage: 1)
        frame.width = 244
        try compare(frame, damage: -1)
        frame.srgbBlend = true
        try compare(frame, damage: -1)
        frame.clearColor = .zero
        try compare(frame, damage: -1)
    }
}
#endif
