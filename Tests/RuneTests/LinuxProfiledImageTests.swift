#if os(Linux)
import Foundation
import Rune
import Testing

@Suite("Linux image decoding")
struct LinuxProfiledImageTests {
    // The embedded ICC profile was generated with LittleCMS from D65,
    // BT.709 red/blue, green (0.21, 0.71), and gamma 2.19921875.
    // Expected sRGB samples come from an independent Pillow ImageCms conversion.
    private func pixel(_ frame: AnimatedImageFrame, _ x: Int, _ y: Int) -> [UInt8] {
        let offset = (y * Int(frame.width) + x) * 4
        return Array(frame.rgba[offset..<(offset + 4)])
    }

    @Test func gifImageRetentionUsesThumbnailDimensions() throws {
        var gif = Data("GIF89a".utf8)
        // A 1024×1024 canvas with a two-entry global palette (black, red).
        gif.append(contentsOf: [0, 4, 0, 4, 0x80, 0, 0, 0, 0, 0, 255, 0, 0])
        let delays = Array(UInt8(2)...31)
        for (x, delay) in delays.enumerated() {
            gif.append(contentsOf: [0x21, 0xf9, 4, 4, delay, 0, 0, 0])
            gif.append(contentsOf: [0x2c, UInt8(x), 0, 0, 0, 1, 0, 1, 0, 0])
            // A one-pixel update. LZW codes are clear, red, end.
            gif.append(contentsOf: [2, 2, 0x4c, 1, 0])
        }
        gif.append(0x3b)

        let thumbnail = try DecodedImage.decode(data: gif, maxDimension: 2)
        #expect(thumbnail.frames.count == delays.count)
        #expect(thumbnail.frames.allSatisfy { $0.width == 2 && $0.height == 2 })
        #expect(thumbnail.frames.map { Int(($0.durationSeconds * 100).rounded()) } == delays.map(Int.init))

        let fullSize = try DecodedImage.decode(data: gif)
        try #require(fullSize.frames.count == 1)
        let first = fullSize.frames[0]
        try #require(first.width == 1024 && first.height == 1024)
        #expect(pixel(first, 0, 0) == [255, 0, 0, 255])
    }

    @Test func taggedPNGRetainsStraightAlphaAfterColorConversion() throws {
        let bytes = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAABaGlDQ1BJQ0MgUHJvZmlsZQAAeJx1kTtLA0EUhU8eEiEhKqSwsEihqRJ8JIIQC41FmqAhRlCx2Uw2ibC7LrsbJPgHbARBrEzhA3+CrQg29oI24g+wEgQbDesZV0wQc4eZ+3GYM9x7B/DPaUK3gwuAbjhWKZ+Lr29sxkMvCGMEUWQRVYRtLhaLBfSN9wf4ZL5Pybf63/s3wlXVFoBvkJwRpuWQ58mFXceUvE+OiYZSJbfJSYsFku+kXvH4SXLd41fJVrm0BPiD5OF6D1d6WDQsnRwjj+taU/zUIzuJqMbaKvMo9xhKyCOHOCpoYhsaHKSYjT6eqW/PMnboEDxNtGDxfh0NOpNUm7ChMteoq1waWnLmf2dp19Iz3uuRHDDw7LpvE0DoCOgcuu7Hmet2zoEAe78xuv42a165BIKfXS0xzXYngeuTrpY5AE6TwNCxqVjK72/40/DmwgjI4+IRKO8Bs7fAFXeiRs/WFzz4YXHbnI0bAAAAHElEQVR4nGOUKnb6P+3Nu0YGBgYGJhhj3/HoegCIdQoTs3jCuwAAAABJRU5ErkJggg=="))
        let image = try DecodedImage.decode(data: bytes)
        let frame = try #require(image.frames.first)
        try #require(frame.width == 3 && frame.height == 2)
        #expect(pixel(frame, 1, 0) == [199, 95, 40, 128])
        #expect(pixel(frame, 2, 1) == [128, 33, 143, 255])
    }

    @Test func webpAppliesClockwiseOrientation() throws {
        // A 3×2 lossless WebP carrying EXIF orientation 6.
        let bytes = try #require(Data(base64Encoded: "UklGRm4AAABXRUJQVlA4WAoAAAAYAAAAAgAAAQAAVlA4TC0AAAAvAkAAEBcgEEigg1xmIIFA4hH4OLOJBRO3aeT/xiAgSaZLywt818EpSiL6HwIARVhJRhoAAABNTQAqAAAACAABARIAAwAAAAEABgAAAAAAAA=="))
        let image = try DecodedImage.decode(data: bytes)
        let frame = try #require(image.frames.first)
        try #require(frame.width == 2 && frame.height == 3)
        #expect(pixel(frame, 0, 0) == [176, 95, 48, 128])
        #expect(pixel(frame, 1, 0) == [26, 115, 66, 255])
        #expect(pixel(frame, 0, 2) == [110, 38, 139, 255])
    }

    @Test func webpAnimationTransformsEveryCompositedFrame() throws {
        // Both frames use the wide-gamut profile and EXIF orientation 7 (transverse).
        let bytes = try #require(Data(base64Encoded: "UklGRgoDAABXRUJQVlA4WAoAAAA6AAAAAgAAAQAASUNDUDgCAAAAAAI4bGNtcwRAAABtbnRyUkdCIFhZWiAH6gALABEADgA7AA5hY3NwQVBQTAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA9tYAAQAAAADTLWxjbXMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAtkZXNjAAABCAAAADRjcHJ0AAABPAAAAEx3dHB0AAABiAAAABRjaGFkAAABnAAAACxyWFlaAAAByAAAABRiWFlaAAAB3AAAABRnWFlaAAAB8AAAABRyVFJDAAACBAAAABBnVFJDAAACBAAAABBiVFJDAAACBAAAABBjaHJtAAACFAAAACRtbHVjAAAAAAAAAAEAAAAMZW5VUwAAABgAAAAcAFIARwBCACAAYgB1AGkAbAB0AC0AaQBubWx1YwAAAAAAAAABAAAADGVuVVMAAAAwAAAAHABOAG8AIABjAG8AcAB5AHIAaQBnAGgAdAAsACAAdQBzAGUAIABmAHIAZQBlAGwAeVhZWiAAAAAAAAD21gABAAAAANMtc2YzMgAAAAAAAQxCAAAF3v//8yUAAAeTAAD9kP//+6H///2iAAAD3AAAwG5YWVogAAAAAAAAnBgAAE+lAAAE/FhZWiAAAAAAAAAmMQAAEC8AAL6bWFlaIAAAAAAAADSNAACgLAAAD5VwYXJhAAAAAAAAAAAAAjMAY2hybQAAAAAAAwAAAACj1wAAVHsAADXDAAC1wwAAJmYAAA9cQU5JTQYAAAAAAAAAAwBBTk1GQgAAAAAAAAAAAAIAAAEAAFAAAAJWUDhMKgAAAC8CQAAQFyAQSCTyG3JZgUAiGcV0IwoE0pBDJGssICh6zvToljYsSET/Q0FOTUYsAAAAAQAAAAAAAAAAAQAAjAAAAFZQOEwTAAAALwBAABAPMJ9jPn3zH/CYgIj+hwBFWElGIAAAAEV4aWYAAE1NACoAAAAIAAEBEgADAAAAAQAHAAAAAAAA"))
        let image = try DecodedImage.decode(data: bytes)
        try #require(image.frames.count == 2)
        #expect(image.loopCount == 3)
        #expect(image.frames.map { Int(($0.durationSeconds * 1000).rounded()) } == [80, 140])
        for frame in image.frames {
            try #require(frame.width == 2 && frame.height == 3)
            #expect(pixel(frame, 0, 1) == [199, 95, 40, 128])
            #expect(pixel(frame, 1, 2) == [0, 116, 60, 255])
        }
        #expect(pixel(image.frames[0], 0, 0) == [128, 33, 143, 255])
        #expect(pixel(image.frames[1], 0, 0) == [252, 160, 124, 255])
    }
}
#endif
