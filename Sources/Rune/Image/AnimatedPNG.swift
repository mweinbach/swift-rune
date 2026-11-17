import Foundation
import RuneRef

/// Composites PNG Third Edition animation frames into straight RGBA canvases for Rune's image atlas.
internal enum AnimatedPNG {
    private static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

    static func decodeIfAnimated(_ data: Data, id: String, maxDimension: Int?) throws -> DecodedImage? {
        guard data.starts(with: signature) else { return nil }
        // Inspect chunk headers before copying pixel data. A static PNG goes directly to its usual decoder.
        let animated = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            var i = signature.count
            while raw.count - i >= 12 {
                let type = read32(raw, i + 4)
                if type == 0x6163544c { return true } // acTL
                if type == 0x49444154 || type == 0x49454e44 { return false } // IDAT or IEND
                guard let n = Int(exactly: read32(raw, i)), n <= raw.count - i - 12 else { return false }
                i += 12 + n
            }
            return false
        }
        guard animated else { return nil }
        var parser = Parser(maxDimension: maxDimension)
        return try parser.decode(Array(data), id: id)
    }

    private static func read32<B: RandomAccessCollection>(_ b: B, _ i: Int) -> UInt32
        where B.Element == UInt8, B.Index == Int {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    private struct Patch {
        var x, y, width, height: Int
        var delay: Double
        var dispose, blend: UInt8
        var usesDefaultImage: Bool
        var hasPixels = false
        var idatChunks = Data()
    }

    private struct Parser {
        let maxDimension: Int?
        private var header: [UInt8] = []
        private var inherited = Data()
        private var hasICCProfile = false
        private var width = 0, height = 0
        private var outWidth = 0, outHeight = 0
        private var canvas = Data()
        private var patch: Patch?
        private var frames: [AnimatedImageFrame] = []
        private var frameCount = 0, plays = 0
        private var finishedFrames = 0
        private var firstFrameOnly = false
        private var nextSequence: UInt64 = 0
        private var sawIDAT = false

        init(maxDimension: Int?) { self.maxDimension = maxDimension }

        mutating func decode(_ bytes: [UInt8], id: String) throws -> DecodedImage {
            var i = signature.count
            var previous = ""
            while bytes.count - i >= 12 {
                guard let n = Int(exactly: read32(bytes, i)), n <= bytes.count - i - 12 else {
                    throw PortablePNG.Error.truncatedData
                }
                let type = String(decoding: bytes[(i + 4)..<(i + 8)], as: UTF8.self)
                let start = i + 8, end = start + n
                guard PortablePNG.crc32(bytes[(i + 4)..<end]) == read32(bytes, end) else {
                    throw PortablePNG.Error.invalidChunkCRC(chunkType: type)
                }
                guard !header.isEmpty || type == "IHDR" else { throw PortablePNG.Error.missingIHDR }
                switch type {
                case "IHDR":
                    guard i == signature.count, n == 13 else { throw ImageError("Invalid APNG header") }
                    header = Array(bytes[start..<end])
                    let w = read32(bytes, start), h = read32(bytes, start + 4)
                    let limit = UInt32(LinearMipGenerator.maxDecodeDimension)
                    guard w > 0, w <= limit, h > 0, h <= limit else {
                        throw ImageError("APNG canvas dimensions exceed the image limit")
                    }
                    width = Int(w)
                    height = Int(h)
                    (outWidth, outHeight) = ImageThumbnail.size(width: width, height: height, maxDimension: maxDimension)
                case "acTL":
                    guard frameCount == 0, !sawIDAT, n == 8,
                          let count = Int(exactly: read32(bytes, start)), count > 0,
                          let frameCost = DecodedImage.animationStorage(width: UInt32(outWidth), height: UInt32(outHeight)) else {
                        throw ImageError("Invalid APNG animation control")
                    }
                    frameCount = count
                    firstFrameOnly = UInt64(count) > UInt64(LinearMipGenerator.maxDecodedBytes) /
                        (frameCost + UInt64(MemoryLayout<AnimatedImageFrame>.stride))
                    plays = Int(clamping: read32(bytes, start + 4))
                case "fcTL":
                    guard n == 26, frameCount > 0 else { throw ImageError("Invalid APNG frame control") }
                    try checkSequence(bytes, start)
                    try finishPatch()
                    guard finishedFrames < frameCount else { throw ImageError("Extra APNG frame") }
                    let w = read32(bytes, start + 4), h = read32(bytes, start + 8)
                    let x = read32(bytes, start + 12), y = read32(bytes, start + 16)
                    guard w > 0, h > 0, w <= width, h <= height, x <= UInt32(width) - w,
                          y <= UInt32(height) - h, bytes[start + 24] <= 2, bytes[start + 25] <= 1 else {
                        throw ImageError("Invalid APNG frame rectangle or composition mode")
                    }
                    if !sawIDAT && (w != width || h != height || x != 0 || y != 0) {
                        throw ImageError("APNG default frame must cover the canvas")
                    }
                    let num = Int(bytes[start + 20]) * 256 + Int(bytes[start + 21])
                    let den = Int(bytes[start + 22]) * 256 + Int(bytes[start + 23])
                    patch = Patch(x: Int(x), y: Int(y), width: Int(w), height: Int(h),
                                  delay: Double(num) / Double(den == 0 ? 100 : den),
                                  dispose: bytes[start + 24], blend: bytes[start + 25],
                                  usesDefaultImage: !sawIDAT)
                case "IDAT":
                    guard frameCount > 0, !sawIDAT || previous == "IDAT" else {
                        throw ImageError("Unexpected APNG default image data")
                    }
                    sawIDAT = true
                    // IDAT before the first fcTL is a separate poster, outside the animation.
                    appendPixels(bytes[start..<end])
                case "fdAT":
                    guard sawIDAT, patch?.usesDefaultImage == false, n >= 4 else {
                        throw ImageError("Unexpected APNG frame data")
                    }
                    try checkSequence(bytes, start)
                    appendPixels(bytes[(start + 4)..<end])
                case "IEND":
                    guard n == 0, sawIDAT else { throw ImageError("Invalid APNG end") }
                    try finishPatch()
                    guard finishedFrames == frameCount, let first = frames.first else {
                        throw ImageError("APNG frame count differs from its header")
                    }
                    return DecodedImage(id: id, width: first.width, height: first.height,
                                        mips: DecodedImage.generateMipChain(width: first.width, height: first.height, rgba: first.rgba),
                                        frames: frames, loopCount: plays)
                case "PLTE", "tRNS", "gAMA", "cHRM", "sRGB", "iCCP", "sBIT", "cICP":
                    guard !sawIDAT else { throw ImageError("Late APNG image metadata") }
                    inherited.append(contentsOf: bytes[i..<(end + 4)])
                    if type == "iCCP" { hasICCProfile = true }
                default:
                    if bytes[i + 4] & 32 == 0 { throw ImageError("Unknown critical APNG chunk \(type)") }
                }
                previous = type
                i = end + 4
            }
            throw PortablePNG.Error.truncatedData
        }

        private mutating func checkSequence(_ bytes: [UInt8], _ start: Int) throws {
            guard UInt64(read32(bytes, start)) == nextSequence else { throw ImageError("APNG frame chunks are out of order") }
            nextSequence += 1
        }

        private mutating func appendPixels(_ payload: ArraySlice<UInt8>) {
            guard patch != nil, !payload.isEmpty else { return }
            patch?.hasPixels = true
            guard !firstFrameOnly || finishedFrames == 0 else { return }
            // IDAT chunks all share one zlib stream. Splitting the stream here
            // bounds the scratch space used to calculate each new chunk's CRC.
            var offset = payload.startIndex
            while offset < payload.endIndex {
                let length = min(1 << 20, payload.endIndex - offset)
                let end = offset + length
                PortablePNG.appendChunk(type: "IDAT", payload: Array(payload[offset..<end]), to: &patch!.idatChunks)
                offset = end
            }
        }

        private mutating func finishPatch() throws {
            guard let current = patch else { return }
            patch = nil
            guard current.hasPixels else { throw ImageError("APNG frame is missing its pixel data") }
            finishedFrames += 1
            if firstFrameOnly && finishedFrames > 1 { return }
            var ihdr = header
            for (start, size) in [(0, current.width), (4, current.height)] {
                var value = UInt32(size).bigEndian
                withUnsafeBytes(of: &value) { ihdr.replaceSubrange(start..<(start + 4), with: $0) }
            }
            var png = Data(signature)
            PortablePNG.appendChunk(type: "IHDR", payload: ihdr, to: &png)
            png.append(inherited)
            png.append(current.idatChunks)
            PortablePNG.appendChunk(type: "IEND", payload: [], to: &png)
            let pixels = try decodePixels(png, width: current.width, height: current.height)
            if canvas.isEmpty { canvas = Data(count: width * height * 4) }
            let prior = current.dispose == 2 ? canvas : nil
            AnimatedPNG.composite(pixels, patch: current, width: width, canvas: &canvas)
            frames.append(AnimatedImageFrame(decodedWidth: UInt32(outWidth), height: UInt32(outHeight),
                                             rgba: ImageThumbnail.resize(canvas, width: width, height: height, to: (outWidth, outHeight)),
                                             durationSeconds: current.delay))
            if let prior {
                canvas = prior
            } else if current.dispose == 1 {
                for y in current.y..<(current.y + current.height) {
                    let start = (y * width + current.x) * 4
                    canvas.resetBytes(in: start..<(start + current.width * 4))
                }
            }
        }

        private func decodePixels(_ png: Data, width: Int, height: Int) throws -> Data {
            // Native decoders handle ICC-to-sRGB conversion, interlacing, and
            // packed/16-bit samples before the patch is blended into the canvas.
            #if canImport(CRuneDesktopImages)
            if hasICCProfile || header[8] != 8 || header[12] != 0 {
                let decoded = try DesktopImageCodec.decode(png, id: "", maxDimension: nil)
                guard let first = decoded.frames.first, first.width == width, first.height == height else {
                    throw ImageError("APNG decoder returned a different frame size")
                }
                return first.rgba
            }
            #endif
            let decoded = try PortablePNG.decode(png, maxDimension: LinearMipGenerator.maxDecodeDimension)
            return Data(decoded.rgba)
        }
    }

    private static func composite(_ pixels: Data, patch: Patch, width: Int, canvas: inout Data) {
        canvas.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            pixels.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                for y in 0..<patch.height {
                    let row = (patch.y + y) * width * 4 + patch.x * 4
                    let source = y * patch.width * 4
                    if patch.blend == 0 {
                        dst.baseAddress!.advanced(by: row).copyMemory(from: src.baseAddress!.advanced(by: source), byteCount: patch.width * 4)
                        continue
                    }
                    for x in 0..<patch.width {
                        let s = source + x * 4, d = row + x * 4
                        let sa = Int(src[s + 3]), da = Int(dst[d + 3])
                        if sa == 0 { continue }
                        let remainder = da * (255 - sa)
                        let alpha = sa * 255 + remainder
                        for c in 0..<3 {
                            let value = Int(src[s + c]) * sa * 255 + Int(dst[d + c]) * remainder
                            dst[d + c] = UInt8((value + alpha / 2) / alpha)
                        }
                        dst[d + 3] = UInt8((alpha + 127) / 255)
                    }
                }
            }
        }
    }
}
