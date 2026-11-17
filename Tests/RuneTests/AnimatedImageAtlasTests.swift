import Foundation
import Testing
@testable import Rune

@Suite("Animated image atlas")
struct AnimatedImageAtlasTests {
    private func clip(plays: Int) -> DecodedImage {
        let red: [UInt8] = [255, 0, 0, 255]
        let green: [UInt8] = [0, 255, 0, 255]
        let clear: [UInt8] = [255, 0, 0, 0]
        let frames = [
            AnimatedImageFrame(width: 2, height: 2, rgba: Data(red + red + red + red), durationSeconds: 0.125),
            AnimatedImageFrame(width: 2, height: 2, rgba: Data(green + clear + clear + clear), durationSeconds: 0.25)
        ]
        return DecodedImage(id: "clip", width: 2, height: 2, mips: [], frames: frames, loopCount: plays)
    }

    private func pixel(in atlas: ImageAtlas, at placement: PlacedImage) -> [UInt8] {
        let page = atlas.pages[placement.page]
        let offset = Int(placement.rect.y * page.width + placement.rect.x) * 4
        return Array(page.data[offset..<(offset + 4)])
    }

    @Test func finitePlaybackAdvancesAtTheDeadlineAndRestsOnTheLastFrame() throws {
        let image = clip(plays: 2)
        #expect(image.frame(at: 0) == image.frames[0])
        #expect(image.frame(at: 0.125) == image.frames[1])
        #expect(image.frame(at: 0.375) == image.frames[0])
        #expect(image.frame(at: 0.75) == image.frames[1])
        #expect(image.frame(at: -0.125) == image.frames[1])
        #expect(image.frame(at: -0.375) == image.frames[0])
        let pixels = Pixels()
        pixels.setDecoded(image)
        var playback = ImagePlayback()
        let untimed = playback.sample(pixels, at: nil)
        #expect(untimed?.frameIndex == 0)
        #expect(untimed?.nextDeadline == nil)

        let samples: [(time: Double, index: Int, deadline: Double?)] = [
            (10, 0, 10.125),
            (10.125.nextDown, 0, 10.125),
            (10.125, 1, 10.375),
            (10.375.nextDown, 1, 10.375),
            (10.375, 0, 10.5),
            (10.5, 1, nil),
            (500, 1, nil)
        ]
        for expected in samples {
            let sample = playback.sample(pixels, at: expected.time)
            let frame = try #require(sample)
            #expect(frame.frameIndex == expected.index)
            #expect(frame.nextDeadline == expected.deadline)
        }
    }

    @Test func eachHandleAndGenerationStartsOnItsFirstTimedDraw() throws {
        let image = clip(plays: 0)
        let first = Pixels(), second = Pixels()
        first.setDecoded(image)
        second.setDecoded(image)
        var playback = ImagePlayback()
        _ = playback.sample(first, at: 1)
        let later = playback.sample(first, at: 4.125) // Eight full plays plus one frame.
        let other = playback.sample(second, at: 4.125)
        #expect(later?.frameIndex == 1 && later?.nextDeadline == 4.375)
        #expect(other?.frameIndex == 0 && other?.nextDeadline == 4.25)

        first.set(width: 1, height: 1, rgba: [10, 20, 30, 40])
        let replacement = playback.sample(first, at: 5)
        let still = try #require(replacement)
        #expect(still.rgba == [10, 20, 30, 40])
        #expect(still.frameIndex == 0 && still.nextDeadline == nil && !still.premultiplied)
        first.setDecoded(image)
        let restarted = playback.sample(first, at: 5.625)
        #expect(restarted?.generation == first.generation)
        #expect(restarted?.frameIndex == 0 && restarted?.nextDeadline == 5.75)
    }

    @Test func fractionalDelaysAdvanceOnTheirAbsoluteWakeTime() throws {
        let frames = [0.06, 0.13, 0.21].map {
            AnimatedImageFrame(width: 1, height: 1, rgba: Data(count: 4), durationSeconds: $0)
        }
        let pixels = Pixels()
        pixels.setDecoded(DecodedImage(id: "fractional", width: 1, height: 1, mips: [], frames: frames))
        var playback = ImagePlayback()
        var now = 123_456.789
        for tick in 0..<30 {
            let sample = playback.sample(pixels, at: now)
            let frame = try #require(sample)
            #expect(frame.frameIndex == tick % frames.count)
            let deadline = try #require(frame.nextDeadline)
            let preceding = playback.sample(pixels, at: deadline.nextDown)
            #expect(preceding?.frameIndex == frame.frameIndex)
            #expect(deadline > now)
            now = deadline
        }
    }

    @Test func eachMipUploadsOnlyWhenItsDisplayedFrameChanges() throws {
        let pixels = Pixels()
        pixels.setDecoded(clip(plays: 1))
        var atlas = ImageAtlas()
        let small = SIMD2<Float>(1, 1)
        let first = atlas.place(pixels, drawnSize: small, at: 12)
        let placement = try #require(first)
        #expect(placement.rect.z == 1 && placement.rect.w == 1 && placement.premultiplied)
        #expect(pixel(in: atlas, at: placement) == [255, 0, 0, 255])
        _ = atlas.place(pixels, drawnSize: small, at: 12.125.nextDown)
        #expect(atlas.copies == 1)

        let second = atlas.place(pixels, drawnSize: small, at: 12.125)
        #expect(second == placement)
        // One opaque green pixel among three transparent pixels in linear light.
        #expect(pixel(in: atlas, at: placement) == [0, 137, 0, 64])
        #expect(atlas.copies == 2)
        let full = atlas.place(pixels, drawnSize: SIMD2(2, 2), at: 12.125)
        let fullPlacement = try #require(full)
        #expect(fullPlacement.rect.z == 2 && fullPlacement.rect.w == 2)
        #expect(pixel(in: atlas, at: fullPlacement) == [0, 255, 0, 255])
        _ = atlas.place(pixels, drawnSize: small, at: 24)
        #expect(atlas.copies == 3)
    }

    @Test func decodedPNGProvidesStraightPixelsAndAPremultipliedAtlasEntry() throws {
        // A 1×1 PNG containing a red pixel with 50% opacity.
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DQAAAEgQGALFXOsAAAAABJRU5ErkJggg=="
        let image = try DecodedImage.decode(data: #require(Data(base64Encoded: png)))
        let pixels = Pixels()
        pixels.setDecoded(image)
        var playback = ImagePlayback()
        let sample = playback.sample(pixels, at: 42)
        let frame = try #require(sample)
        #expect(!frame.premultiplied && frame.nextDeadline == nil)
        #expect(frame.rgba == [255, 0, 0, 128])

        var atlas = ImageAtlas()
        let slot = atlas.place(pixels, drawnSize: SIMD2(1, 1))
        let placement = try #require(slot)
        #expect(placement.premultiplied)
        #expect(pixel(in: atlas, at: placement) == [188, 0, 0, 128])
    }
}
