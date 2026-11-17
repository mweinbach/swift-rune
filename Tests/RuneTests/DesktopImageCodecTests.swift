import Foundation

enum DesktopImageCodecFixtures {
    // 5×3 GIF with a persistent red pixel. Frame two adds a green pixel at x=3,
    // then restores the previous canvas. Frame three adds a blue pixel at x=4.
    static let gif = "R0lGODlhBQADAIEAAAAAAP8AAAAAAAAAACH/C05FVFNDQVBFMi4wAwEDAAAh+QQFBgAAACwAAAAABQADAAAICwABCBQYYKBBgQEBACH5BA0NAAAALAMAAQABAAEAgQAAAP8AAAD/AAAAAAgEAAUEBAAh+QQFFQAAACwDAAEAAgABAIEAAAD/AAAAAP8AAAAIBQABCAgIADs="

    static let webp = "UklGRigAAABXRUJQVlA4TBwAAAAvBIAAEA9AIECZKtzwiOynxDzwP+4F7/iI6H8M"
}

#if os(macOS) || os(Linux) || os(Windows) || os(Android)
#if os(Android)
import Android
#endif
import Rune
import Testing

@Suite("Native image decoding")
struct DesktopImageCodecTests {
    // An 8×4 JPEG with red and green upper corners and blue and yellow lower corners.
    private let jpeg = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAEBAQEBAQEBAQEBAQECAgMCAgICAgQDAwIDBQQFBQUEBAQFBgcGBQUHBgQEBgkGBwgICAgIBQYJCgkICgcICAj/2wBDAQEBAQICAgQCAgQIBQQFCAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAj/wAARCAAEAAgDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAABf/EACcQAAABCAsAAAAAAAAAAAAAABEBAgMEEhMVFgUGCAkUFxghIzI0/8QAFQEBAQAAAAAAAAAAAAAAAAAABQf/xAAnEQAABAMGBwAAAAAAAAAAAAADERITAgcUAQYVFyIyBAoWIzM0Q//aAAwDAQACEQMRAD8AauZKvUPaA1I5uKc2wmX4fyHquHfRB55yo2mnKLsIM7AJRhPMHSGupJvpHLfhKGur3u4KMtmib88YqUuibEmrUZWEjecaKeiM07cQw82Pg2+TvrMqUyHvUlOkjiP/2Q=="

    private func pixel(_ frame: AnimatedImageFrame, x: Int, y: Int) -> [UInt8] {
        let offset = (y * Int(frame.width) + x) * 4
        return Array(frame.rgba[offset..<(offset + 4)])
    }

    @Test func jpegLoadsThroughCacheAndResizesProportionally() throws {
        let bytes = try #require(Data(base64Encoded: jpeg))
        let cache = ImageCache()
        let image = cache.load(bytes)
        let (w, h) = try image.wait().get()
        #expect(w == 8 && h == 4)
        #expect(cache.load(bytes) === image)

        var atlas = ImageAtlas()
        let placed = atlas.place(image.pixels, drawnSize: SIMD2(8, 4))
        let placement = try #require(placed)
        let page = atlas.pages[placement.page]
        let start = (Int(placement.rect.y) * Int(page.width) + Int(placement.rect.x)) * 4
        let rgb = page.data[start..<(start + 4)].map(Int.init)
        #expect(abs(rgb[0] - 222) <= 3 && abs(rgb[1] - 62) <= 3 && abs(rgb[2] - 30) <= 3)
        #expect(rgb[3] == 255)

        let thumbnail = try DecodedImage.decode(data: bytes, maxDimension: 4)
        #expect(thumbnail.width == 4 && thumbnail.height == 2)
        #expect(thumbnail.mips.last?.width == 1 && thumbnail.mips.last?.height == 1)
    }

    @Test func exifTransformsMirroredAndRotatedJPEGCorners() throws {
        let bytes = try #require(Data(base64Encoded: jpeg))
        func corners(_ frame: AnimatedImageFrame) -> [[UInt8]] {
            let x = Int(frame.width) - 1, y = Int(frame.height) - 1
            return [pixel(frame, x: 0, y: 0), pixel(frame, x: x, y: 0),
                    pixel(frame, x: 0, y: y), pixel(frame, x: x, y: y)]
        }
        let original = try DecodedImage.decode(data: bytes)
        let colors = corners(try #require(original.frames.first))
        try #require(Set(colors).count == 4)
        // Big-endian EXIF APP1 segment with an inline 16-bit orientation tag at offsets 28–29.
        var exif = try #require(Data(base64Encoded: "/+EAIkV4aWYAAE1NACoAAAAIAAEBEgADAAAAAQAGAAAAAAAA"))
        for (orientation, order) in [(5, [0, 2, 1, 3]), (6, [2, 0, 3, 1]), (7, [3, 1, 2, 0])] {
            exif[29] = UInt8(orientation)
            var rotated = bytes
            rotated.insert(contentsOf: exif, at: 2)
            let full = try DecodedImage.decode(data: rotated)
            #expect(full.width == 4 && full.height == 8)
            let actual = corners(try #require(full.frames.first))
            for (rgba, index) in zip(actual, order) {
                #expect(zip(rgba, colors[index]).allSatisfy { abs(Int($0.0) - Int($0.1)) <= 2 },
                        "EXIF orientation \(orientation) returned corner \(rgba), expected \(colors[index])")
            }
            let thumb = try DecodedImage.decode(data: rotated, maxDimension: 4)
            #expect(thumb.width == 2 && thumb.height == 4)
        }
    }

    private static var animatedImagesAvailable: Bool {
        #if os(Android)
        return android_get_device_api_level() >= 31
        #else
        return true
        #endif
    }

    @Test func gifCompositesPartialFramesAndRestoresThePreviousCanvas() throws {
        let image = try DecodedImage.decode(data: #require(Data(base64Encoded: DesktopImageCodecFixtures.gif)))
        #expect(image.width == 5 && image.height == 3)
        if !Self.animatedImagesAvailable {
            try #require(image.frames.count == 1)
            #expect(pixel(image.frames[0], x: 0, y: 1) == [255, 0, 0, 255])
            return
        }
        try #require(image.frames.count == 3)
        #expect(image.frames.allSatisfy { $0.width == 5 && $0.height == 3 && $0.rgba.count == 60 })
        #expect(image.frames.map { Int(($0.durationSeconds * 1000).rounded()) } == [60, 130, 210])
        #expect(image.loopCount == 4) // Initial play plus three NETSCAPE repeats.
        #expect(image.frames.allSatisfy { pixel($0, x: 0, y: 1) == [255, 0, 0, 255] })
        #expect(pixel(image.frames[0], x: 3, y: 1)[3] == 0)
        #expect(pixel(image.frames[1], x: 3, y: 1) == [0, 255, 0, 255])
        #expect(pixel(image.frames[2], x: 3, y: 1)[3] == 0)
        #expect(pixel(image.frames[2], x: 4, y: 1) == [0, 0, 255, 255])
    }

    @Test(.enabled(if: animatedImagesAvailable, "Android animation metadata requires API 31"))
    func gifDistinguishesOnePlayFromInfiniteRepetition() throws {
        var bytes = try #require(Data(base64Encoded: DesktopImageCodecFixtures.gif))
        let applicationBlock = Data([0x21, 0xff, 0x0b]) + Data("NETSCAPE2.0".utf8) + Data([3, 1, 3, 0, 0])
        let application = try #require(bytes.range(of: applicationBlock))
        // The 16-bit little-endian repeat count immediately precedes the sub-block terminator.
        bytes[application.upperBound - 3] = 0
        #expect(try DecodedImage.decode(data: bytes).loopCount == 0)
        bytes.removeSubrange(application)
        #expect(try DecodedImage.decode(data: bytes).loopCount == 1)
    }

    @Test func malformedImageFailsThroughTheCache() {
        #expect(throws: ImageLoadError.self) {
            try ImageCache().load(Data("not an image".utf8)).wait().get()
        }
    }

    private static var webpAvailable: Bool {
        #if os(Windows)
        if let bytes = Data(base64Encoded: DesktopImageCodecFixtures.webp) {
            do { _ = try DecodedImage.decode(data: bytes) }
            catch let error as ImageError where error.message.hasPrefix("No installed Windows Imaging Component codec") { return false }
            catch { return true } // The test reports decoding failures from an installed codec.
        }
        #endif
        return true
    }

    @Test(.enabled(if: webpAvailable, "Requires an installed Windows WebP codec"))
    func webpPreservesStraightAlphaAndAnimationTiming() throws {
        let animated = "UklGRpQAAABXRUJQVlA4WAoAAAASAAAABAAAAgAAQU5JTQYAAAAAAAAAAwBBTk1GNAAAAAAAAAAAAAQAAAIAAFoAAAJWUDhMHAAAAC8EgAAQD0AgQJkq3PCI7KfEPPA/7gXv+IjofwxBTk1GLAAAAAAAAAEAAAEAAAAAAKoAAABWUDhMEwAAAC8BAAAQDzDcwzBR8x/wqEBE/wMA"
        let image = try DecodedImage.decode(data: #require(Data(base64Encoded: DesktopImageCodecFixtures.webp)))
        let frame = try #require(image.frames.first)
        func checkTranslucentPink(_ frame: AnimatedImageFrame) {
            let rgba = pixel(frame, x: 2, y: 2).map(Int.init)
            // ImageIO's premultiply/unpremultiply round trip can shift RGB by one.
            #expect(abs(rgba[0] - 234) <= 1 && abs(rgba[1] - 33) <= 1 && abs(rgba[2] - 90) <= 1)
            #expect(rgba[3] == 128)
        }
        #expect(image.width == 5 && image.height == 3)
        checkTranslucentPink(frame)
        #expect(pixel(frame, x: 1, y: 2) == [17, 29, 49, 255])

        let animation = try DecodedImage.decode(data: #require(Data(base64Encoded: animated)))
        if !Self.animatedImagesAvailable {
            try #require(animation.frames.count == 1)
            checkTranslucentPink(animation.frames[0])
            return
        }
        try #require(animation.frames.count == 2)
        #expect(animation.loopCount == 3)
        #expect(animation.frames.map { Int(($0.durationSeconds * 1000).rounded()) } == [90, 170])
        #expect(pixel(animation.frames[1], x: 1, y: 2) == [12, 220, 81, 255])
        checkTranslucentPink(animation.frames[1])
    }
}
#endif
