import Foundation
import Testing
@testable import Rune

@Suite("APNG animation frames")
struct AnimatedPNGTests {
    // A separate cyan poster precedes four frames on a 3×1 canvas. Frame two
    // blends translucent blue over red and restores the previous canvas. Frame
    // three replaces the last pixel with green and clears it after display.
    private let posterAnimation = """
        iVBORw0KGgoAAAANSUhEUgAAAAMAAAABCAYAAAAb4BS0AAAACGFjVEwAAAAEAAAAApLDB/wAAAAP
        SURBVHicY2D4//8/DAMANdcI+BE5ZMUAAAAaZmNUTAAAAAAAAAADAAAAAQAAAAAAAAAAAAgAAAAALkzR
        hgAAABJmZEFUAAAAAXicY/jPwPAfhgEm5gX7WZvwRwAAABpmY1RMAAAAAgAAAAEAAAABAAAAAQAA
        AAAADABkAgGJj0x2AAAAEWZkQVQAAAADeJxjYGD43wAAAoMBgM24twwAAAAaZmNUTAAAAAQAAAAB
        AAAAAQAAAAIAAAAAABEAZAEAOf1oawAAABFmZEFUAAAABXicY2D4z/AfAAQBAf8HKkNcAAAAGmZj
        VEwAAAAGAAAAAQAAAAEAAAAAAAAAAAAZAGQAAKVseMMAAAARZmRBVAAAAAd4nGP4/5+hAQAHfgJ/
        MowAawAAAABJRU5ErkJggg==
        """

    // The red default image is the first animated frame, followed by green.
    private let defaultImageAnimation = """
        iVBORw0KGgoAAAANSUhEUgAAAAMAAAABCAYAAAAb4BS0AAAACGFjVEwAAAACAAAAAPONk3AAAAAa
        ZmNUTAAAAAAAAAADAAAAAQAAAAAAAAAAABQAZAAAxILI+QAAAA5JREFUeJxj+M/A8B+GASbmBfth
        LF8IAAAAGmZjVEwAAAABAAAAAwAAAAEAAAAAAAAAAAAeAGQAABVBOowAAAAQZmRBVAAAAAJ4nGNg
        +I+AACPpBfuyvtZLAAAAAElFTkSuQmCC
        """

    @Test func posterExclusionAndFrameComposition() throws {
        let bytes = try #require(Data(base64Encoded: posterAnimation, options: .ignoreUnknownCharacters))
        let image = try #require(try AnimatedPNG.decodeIfAnimated(bytes, id: "poster", maxDimension: nil))
        #expect(image.id == "poster")
        #expect(image.width == 3 && image.height == 1)
        #expect(image.loopCount == 2)
        #expect(image.frames.map { Int(($0.durationSeconds * 1000).rounded()) } == [80, 120, 170, 250])

        // Full RGBA frames independently decoded with FFmpeg.
        let red: [UInt8] = [255, 0, 0, 255]
        let purple: [UInt8] = [127, 0, 128, 255]
        let green: [UInt8] = [0, 255, 0, 255]
        let yellow: [UInt8] = [255, 255, 0, 128]
        let clear: [UInt8] = [0, 0, 0, 0]
        let expected = [red + red + red, red + purple + red, red + red + green, yellow + red + clear]
        #expect(image.frames.map { Array($0.rgba) } == expected)
        #expect(image.mips.first?.rgba == Data(expected[0]))
    }

    @Test func defaultImageParticipatesAndAllFramesResize() throws {
        let bytes = try #require(Data(base64Encoded: defaultImageAnimation, options: .ignoreUnknownCharacters))
        let image = try #require(try AnimatedPNG.decodeIfAnimated(bytes, id: "two", maxDimension: 1))
        #expect(image.width == 1 && image.height == 1)
        #expect(image.loopCount == 0)
        #expect(image.frames.allSatisfy { $0.width == 1 && $0.height == 1 })
        #expect(image.frames.map { Array($0.rgba) } == [[255, 0, 0, 255], [0, 255, 0, 255]])
        #expect(image.frames.map { Int(($0.durationSeconds * 1000).rounded()) } == [200, 300])
    }

    @Test func compositingTwoTranslucentPixelsReturnsStraightRGBA() throws {
        let encoded = """
            iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACGFjVEwAAAACAAAAAYSKo+YAAAAa
            ZmNUTAAAAAAAAAABAAAAAQAAAAAAAAAAAAUAZAAA7bZwOgAAAA1JREFUeJxjYPjP0AAAA4IBgPLI
            P/oAAAAaZmNUTAAAAAEAAAABAAAAAQAAAAAAAAAAAAUAZAABAcKqeAAAABFmZEFUAAAAAnicY/jP
            wNAAAASBAYA/WWDJAAAAAElFTkSuQmCC
            """
        let bytes = try #require(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        let image = try #require(try AnimatedPNG.decodeIfAnimated(bytes, id: "over", maxDimension: nil))
        try #require(image.frames.count == 2)
        #expect(Array(image.frames[0].rgba) == [0, 255, 0, 128])
        let blended = Array(image.frames[1].rgba)
        try #require(blended.count == 4)
        // FFmpeg's integer compositor gives [170, 84, 0, 192].
        #expect(abs(Int(blended[0]) - 170) <= 1 && abs(Int(blended[1]) - 84) <= 1)
        #expect(blended[2] == 0 && blended[3] == 192)
    }

    #if os(Linux) || os(Windows)
    @Test func nativeCodecHandles16BitAnimationThroughPublicDecoder() throws {
        let encoded = """
            iVBORw0KGgoAAAANSUhEUgAAAAEAAAABEAYAAABPhRjKAAAACGFjVEwAAAACAAAAA2qEwsoAAAAa
            ZmNUTAAAAAAAAAABAAAAAQAAAAAAAAAAAA8AZAAApwZomwAAABBJREFUeJxj+P+fAQj+/wcAEfcD
            /aREqcQAAAAaZmNUTAAAAAEAAAABAAAAAQAAAAAAAAAAAA8AZAAAPHWCTwAAABJmZEFUAAAAAnic
            Y2AAgv9AAAAJ/wP9/0mEIQAAAABJRU5ErkJggg==
            """
        let bytes = try #require(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        let image = try DecodedImage.decode(data: bytes, id: "16-bit")
        #expect(image.frames.map { Array($0.rgba) } == [[255, 0, 0, 255], [0, 0, 255, 255]])
        #expect(image.loopCount == 3)
    }

    @Test func embeddedProfileConvertsPatchesToSRGBBeforeBlending() throws {
        // First pixel in the source profile is (26,115,66). Little CMS maps it
        // to (0,116,60) in sRGB. The half-transparent patch maps to (199,95,40).
        let encoded = """
            iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAABaGlDQ1BJQ0MgUHJvZmlsZQAAeJx1kTtLA0EUhU8e
            EiEhKqSwsEihqRJ8JIIQC41FmqAhRlCx2Uw2ibC7LrsbJPgHbARBrEzhA3+CrQg29oI24g+wEgQbDesZV0wQc4eZ
            +3GYM9x7B/DPaUK3gwuAbjhWKZ+Lr29sxkMvCGMEUWQRVYRtLhaLBfSN9wf4ZL5Pybf63/s3wlXVFoBvkJwRpuWQ
            58mFXceUvE+OiYZSJbfJSYsFku+kXvH4SXLd41fJVrm0BPiD5OF6D1d6WDQsnRwjj+taU/zUIzuJqMbaKvMo9xhK
            yCOHOCpoYhsaHKSYjT6eqW/PMnboEDxNtGDxfh0NOpNUm7ChMteoq1waWnLmf2dp19Iz3uuRHDDw7LpvE0DoCOgc
            uu7Hmet2zoEAe78xuv42a165BIKfXS0xzXYngeuTrpY5AE6TwNCxqVjK72/40/DmwgjI4+IRKO8Bs7fAFXeiRs/W
            Fzz4YXHbnI0bAAAACGFjVEwAAAACAAAAAYSKo+YAAAAaZmNUTAAAAAAAAAADAAAAAgAAAAAAAAAAAA8AZAAAws8E
            EwAAABxJREFUeJxjlCp2+j/tzbtGBgYGBiYYY9/x6HoAiHUKE7N4wrsAAAAaZmNUTAAAAAEAAAABAAAAAQAAAAAA
            AAAAAA8AZAABS3Ky2QAAABFmZEFUAAAAAnicY9gQb9AAAATCAcDM12rYAAAAAElFTkSuQmCC
            """
        let bytes = try #require(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        let image = try DecodedImage.decode(data: bytes, id: "profile")
        try #require(image.frames.count == 2)
        let expected = [[0, 116, 60, 255], [100, 105, 50, 255]]
        for (frame, pixel) in zip(image.frames, expected) {
            #expect(zip(frame.rgba.prefix(4), pixel).allSatisfy { abs(Int($0) - $1) <= 2 })
        }
    }
    #endif

    @Test func rejectsInvalidAnimationAndDefersStillImages() throws {
        let still = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAMAAAABCAYAAAAb4BS0AAAADklEQVR4nGP4z8DwH4YBJuYF+2EsXwgAAAAASUVORK5CYII="))
        #expect(try AnimatedPNG.decodeIfAnimated(still, id: "still", maxDimension: nil) == nil)

        let bytes = try #require(Data(base64Encoded: posterAnimation, options: .ignoreUnknownCharacters))
        #expect(throws: (any Error).self) {
            _ = try AnimatedPNG.decodeIfAnimated(Data(bytes.dropLast(6)), id: "truncated", maxDimension: nil)
        }

        let type = Data("fcTL".utf8)
        let first = try #require(bytes.range(of: type))
        var invalidCRC = bytes
        invalidCRC[first.upperBound + 26] ^= 1
        #expect(throws: (any Error).self) {
            _ = try AnimatedPNG.decodeIfAnimated(invalidCRC, id: "crc", maxDimension: nil)
        }

        let firstPayload = try #require(bytes.range(of: Data("fdAT".utf8))).upperBound
        var skippedSequence = bytes
        skippedSequence[firstPayload + 3] = 99 // This fdAT must follow fcTL number zero.
        skippedSequence.replaceSubrange((firstPayload + 18)..<(firstPayload + 22), with: [0xb3, 0x23, 0x04, 0x35])
        #expect(throws: (any Error).self) {
            _ = try AnimatedPNG.decodeIfAnimated(skippedSequence, id: "sequence", maxDimension: nil)
        }

        let second = try #require(bytes.range(of: type, in: first.upperBound..<bytes.endIndex))
        let control = second.upperBound
        var outOfBounds = bytes
        outOfBounds[control + 15] = 3 // x = 3, width = 1 on a three-pixel-wide canvas.
        outOfBounds.replaceSubrange((control + 26)..<(control + 30), with: [0xd1, 0xe3, 0xf5, 0xb7])
        #expect(throws: (any Error).self) {
            _ = try AnimatedPNG.decodeIfAnimated(outOfBounds, id: "outside", maxDimension: nil)
        }
    }
}
