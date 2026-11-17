import Foundation
import Testing
import RuneMotion
import RuneRef
@testable import Rune

@Suite("Animated image rendering and host deadlines")
struct AnimatedImageRuntimeTests {
    private let red: [UInt8] = [255, 0, 0, 255]
    private let blue: [UInt8] = [0, 0, 255, 255]

    private func animation(plays: Int) -> DecodedImage {
        let frames = [(red, 0.125), (blue, 0.375)].map { color, delay in
            AnimatedImageFrame(width: 2, height: 2, rgba: Data(color + color + color + color), durationSeconds: delay)
        }
        return DecodedImage(id: "two colors", width: 2, height: 2, mips: [], frames: frames, loopCount: plays)
    }

    private func atlasPixel(_ frame: RenderFrame) throws -> [UInt8] {
        let image = try #require(frame.instances.first { $0.params.y == KIND_IMAGE })
        let offset = 4 * (Int(image.uv.y) * frame.images.width + Int(image.uv.x))
        return Array(frame.images.texels[offset..<(offset + 4)])
    }

    @Test func bothPaintersUseTheSameClockAndStopOnTheFinalFrame() throws {
        let pixels = Pixels()
        pixels.setDecoded(animation(plays: 2))
        let rt = Runtime(state: (), viewport: Vec2(4, 4), pixelScale: 1) { _, _ in
            el().size(4, 4).cache().child(el().size(4, 4).pixels(pixels))
        }
        for (t, expected, due) in [(30.0, red, 30.125 as Double?), (30.0625, red, 30.125),
                                   (30.125, blue, 30.5), (30.5, red, 30.625),
                                   (30.625, blue, nil), (50.0, blue, nil)] {
            let reference = try RuneRef.render(rt.frame(at: t))
            let pixel = reference.pixel(x: 2, y: 2)
            #expect([pixel.x, pixel.y, pixel.z, pixel.w] == expected)
            #expect(rt.nextWakeDeadline(after: t) == due)
            let frame = rt.renderFrame(at: t)
            #expect(try atlasPixel(frame) == expected)
            #expect(rt.nextWakeDeadline(after: t) == due)
            #expect(!rt.isAnimating)
        }
    }

    @Test func changingFramesReplaceOneAtlasSlotAndKeepEarlierFramesIntact() throws {
        let pixels = Pixels()
        pixels.setDecoded(animation(plays: 0))
        let rt = Runtime(state: (), viewport: Vec2(4, 4)) { _, _ in el().size(4, 4).pixels(pixels) }
        let first = rt.renderFrame(at: 0)
        let held = rt.renderFrame(at: 0.0625)
        #expect(held.imageRevision == first.imageRevision)
        for cycle in 0..<40 {
            let blueFrame = rt.renderFrame(at: Double(cycle) / 2 + 0.125)
            #expect(try atlasPixel(blueFrame) == blue)
            #expect(blueFrame.instances.last?.uv == first.instances.last?.uv)
            #expect(blueFrame.images.width == first.images.width)
            #expect(blueFrame.images.height == first.images.height)
            #expect(blueFrame.imageRevision != first.imageRevision)
            let redFrame = rt.renderFrame(at: Double(cycle + 1) / 2)
            #expect(try atlasPixel(redFrame) == red)
        }
        #expect(try atlasPixel(first) == red)
        pixels.setDecoded(animation(plays: 1))
        #expect(try atlasPixel(rt.renderFrame(at: 27.25)) == red)
        #expect(rt.nextWakeDeadline(after: 27.25) == 27.375)
        pixels.set(width: 1, height: 1, rgba: blue)
        #expect(try atlasPixel(rt.renderFrame(at: 27.5)) == blue)
        #expect(rt.nextWakeDeadline(after: 27.5) == nil)
    }

    @Test func hiddenAndOffscreenImagesSleepAndSlowImagesScheduleWallClockTime() {
        let pixels = Pixels()
        pixels.setDecoded(animation(plays: 0))
        for reference in [true, false] {
            let rt = Runtime(state: (x: Float(0), scale: Float(0.5)), viewport: Vec2(8, 8)) { state, cx in
                cx.timeScale(state.scale)
                return el().size(8, 8).child(el().size(4, 4).absolute(x: state.x, y: 0).pixels(pixels))
            }
            func paint(_ time: Double) {
                if reference { _ = rt.frame(at: time) } else { _ = rt.renderFrame(at: time) }
            }
            paint(0)
            #expect(rt.nextWakeDeadline(after: 0) == 0.25)
            rt.setLiveVisible(false)
            #expect(rt.nextWakeDeadline(after: 0) == nil)
            rt.setLiveVisible(true)
            rt.update(at: 0) { state, tx in state.x = 20; tx.settle() }
            paint(0.25)
            #expect(rt.nextWakeDeadline(after: 0.25) == nil)
            rt.update(at: 0.25) { state, tx in state.x = 0; tx.settle() }
            paint(0.5)
            #expect(rt.nextWakeDeadline(after: 0.5) == 0.75)
            rt.update(at: 0.5) { state, tx in state.scale = 0; tx.settle() }
            paint(0.625)
            #expect(rt.nextWakeDeadline(after: 0.625) == nil)
        }
    }

    @Test func splitFrameCanSkipMultiplePictureDeadlines() throws {
        let pixels = Pixels()
        pixels.setDecoded(animation(plays: 0))
        let rt = Runtime(state: (), viewport: Vec2(4, 4)) { _, _ in el().size(4, 4).pixels(pixels) }
        _ = rt.frame(at: 0)
        _ = rt.frameSplit(catchUp: 1.125, dt: 0)
        #expect(rt.currentTime == 1.125)
        #expect(rt.nextWakeDeadline(after: 1.125) == 1.5)
        #expect(try atlasPixel(rt.renderFrame(at: 1.125)) == blue)
    }

    @Test func drawingTheSameAnimationAtTwoSizesPicksTheMipOfEachFrame() throws {
        let tiny = Runtime<Int>.fittedPixelsGeometry(
            box: SIMD4(0, 0, 1, 1), uv: SIMD4(0, 0, 1, 1),
            imageWidth: 4, imageHeight: 4, fit: .fit, pixelScale: 2)
        #expect(tiny.rect == SIMD4(0, 0, 1, 1))
        let black: [UInt8] = [0, 0, 0, 255]
        let white: [UInt8] = [255, 255, 255, 255]
        let spot = white + Array(repeating: black, count: 15).flatMap { $0 }
        let frames = [spot, Array(repeating: blue, count: 16).flatMap { $0 }].map {
            AnimatedImageFrame(width: 4, height: 4, rgba: Data($0), durationSeconds: 0.125)
        }
        let pixels = Pixels()
        pixels.setDecoded(DecodedImage(id: "pyramid", width: 4, height: 4, mips: [], frames: frames))
        let rt = Runtime(state: (), viewport: Vec2(10, 4), pixelScale: 1) { _, _ in
            el().size(10, 4)
                .child(el().absolute(x: 1, y: 1).size(1, 1).pixels(pixels))
                .child(el().absolute(x: 6, y: 0).size(4, 4).pixels(pixels))
        }
        for (t, small, full) in [(0.0, SIMD4<UInt8>(71, 71, 71, 255), SIMD4<UInt8>(255, 255, 255, 255)),
                                 (0.125, SIMD4<UInt8>(0, 0, 255, 255), SIMD4<UInt8>(0, 0, 255, 255))] {
            let reference = try RuneRef.render(rt.frame(at: t))
            #expect(reference.pixel(x: 1, y: 1) == small)
            #expect(reference.pixel(x: 6, y: 0) == full)
            let frame = rt.renderFrame(at: t)
            let pictures = frame.instances.filter { $0.params.y == KIND_IMAGE }
            #expect(pictures.map { $0.uv.z } == [1, 4])
            #expect(try atlasPixel(frame) == [small.x, small.y, small.z, small.w])
        }
    }

    @Test func subtexelFillCropsStillFilterAcrossSourceNeighbors() throws {
        let green: [UInt8] = [0, 255, 0, 255]
        let pixels = Pixels()
        pixels.set(width: 5, height: 1, rgba: blue + red + green + blue + red)
        let rt = Runtime(state: (), viewport: Vec2(2, 8), pixelScale: 1) { _, _ in
            el().size(2, 8).pixelsFit(pixels, .fill)
        }
        let reference = try RuneRef.render(rt.frame(at: 0))
        let frame = rt.renderFrame(at: 0)
        let image = try #require(frame.instances.first { $0.params.y == KIND_IMAGE })
        #expect(image.uv.z == 0.25) // The two screen pixels cover one quarter of a source texel.
        #expect(image.border.z - image.border.x == 5)
        func check(_ raster: Frame) {
            #expect(raster.pixel(x: 0, y: 4) == SIMD4<UInt8>(16, 239, 0, 255))
            #expect(raster.pixel(x: 1, y: 4) == SIMD4<UInt8>(0, 239, 16, 255))
        }
        check(reference)
        #if (os(macOS) || os(Linux) || os(Windows)) && (canImport(Metal) || canImport(CRuneOffscreenGL))
        check(try OffscreenGPURenderer().renderOffscreen(frame))
        #endif
    }

    #if (os(macOS) || os(Linux) || os(Windows)) && (canImport(Metal) || canImport(CRuneOffscreenGL))
    @Test func decodedGIFUpdatesAPersistentGPUTexture() throws {
        let fixture = try #require(Data(base64Encoded: DesktopImageCodecFixtures.gif))
        let image = ImageCache().load(fixture)
        _ = try image.wait().get()
        let rt = Runtime(state: (), viewport: Vec2(5, 3), pixelScale: 1) { _, _ in
            el().size(5, 3).pixels(image.pixels)
        }
        let gpu = try OffscreenGPURenderer()
        let black = SIMD4<UInt8>(0, 0, 0, 255)
        let green = SIMD4<UInt8>(0, 255, 0, 255)
        let blue = SIMD4<UInt8>(0, 0, 255, 255)
        for (t, x3, x4) in [(0.0, black, black), (0.065, green, black),
                            (0.20, black, blue), (0.45, black, black), (1.8, black, blue)] {
            let frame = try gpu.renderOffscreen(rt.renderFrame(at: t))
            #expect(frame.pixel(x: 0, y: 1) == SIMD4<UInt8>(255, 0, 0, 255))
            #expect(frame.pixel(x: 3, y: 1) == x3)
            #expect(frame.pixel(x: 4, y: 1) == x4)
        }
        #expect(rt.nextWakeDeadline(after: 1.8) == nil)
    }
    #endif
}
