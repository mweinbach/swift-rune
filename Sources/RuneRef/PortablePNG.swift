import Foundation

/// Pure-Swift RFC-2083 PNG encoder and decoder (8-bit RGBA, zlib/DEFLATE, scanline filters 0..4).
///
/// Used as the cross-platform PNG backend on Linux, Windows, Android, and WebAssembly/WASI,
/// and exposed publicly so tests on Apple platforms can also verify pure-Swift round-tripping
/// and scanline unfiltering directly.
public enum PortablePNG {
    public enum Error: Swift.Error, Sendable, Equatable, CustomStringConvertible {
        case invalidDimensions(width: Int, height: Int)
        case invalidPixelBufferCount(expected: Int, actual: Int)
        case invalidSignature
        case truncatedData
        case invalidChunkCRC(chunkType: String)
        case missingIHDR
        case missingIDAT
        case unsupportedFormat(bitDepth: UInt8, colorType: UInt8, interlace: UInt8)
        case invalidZlibHeader
        case invalidZlibChecksum
        case invalidDeflateStream(String)
        case invalidFilterType(UInt8)

        public var description: String {
            switch self {
            case .invalidDimensions(let w, let h):
                return "Invalid PNG dimensions \(w)x\(h)"
            case .invalidPixelBufferCount(let expected, let actual):
                return "Invalid RGBA buffer size: expected \(expected) bytes, got \(actual)"
            case .invalidSignature:
                return "Invalid PNG signature"
            case .truncatedData:
                return "Truncated PNG data"
            case .invalidChunkCRC(let type):
                return "Invalid CRC-32 for PNG chunk \(type)"
            case .missingIHDR:
                return "Missing PNG IHDR chunk"
            case .missingIDAT:
                return "Missing PNG IDAT chunk"
            case .unsupportedFormat(let bitDepth, let colorType, let interlace):
                return "Unsupported PNG format (bitDepth=\(bitDepth), colorType=\(colorType), interlace=\(interlace))"
            case .invalidZlibHeader:
                return "Invalid zlib header"
            case .invalidZlibChecksum:
                return "Invalid zlib Adler-32 checksum"
            case .invalidDeflateStream(let reason):
                return "Invalid DEFLATE stream: \(reason)"
            case .invalidFilterType(let filter):
                return "Invalid PNG scanline filter type \(filter)"
            }
        }
    }

    public struct DecodedImage: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let rgba: [UInt8]

        public init(width: Int, height: Int, rgba: [UInt8]) {
            self.width = width
            self.height = height
            self.rgba = rgba
        }
    }

    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    // MARK: - Public API

    /// Encodes an 8-bit RGBA8 buffer as a valid RFC-2083 PNG.
    public static func encode(width: Int, height: Int, rgba: [UInt8]) throws -> Data {
        guard width > 0, height > 0 else {
            throw Error.invalidDimensions(width: width, height: height)
        }
        let expected = width * height * 4
        guard rgba.count == expected else {
            throw Error.invalidPixelBufferCount(expected: expected, actual: rgba.count)
        }

        // Build filtered scanlines (filter 0 = None, or 1 = Sub for better compressibility).
        let rowBytes = width * 4
        var scanlines = [UInt8]()
        scanlines.reserveCapacity(height * (1 + rowBytes))
        for y in 0..<height {
            let rowStart = y * rowBytes
            // Use filter 1 (Sub) for rows > 0 pixels wide to exercise and benefit from filtering,
            // or filter 0 (None). Let's use Sub (1) on odd rows and None (0) on even rows?
            // Actually Sub (1) on all rows is simple, fast, and deterministic.
            scanlines.append(1)
            for x in 0..<rowBytes {
                let raw = rgba[rowStart + x]
                let left: UInt8 = x >= 4 ? rgba[rowStart + x - 4] : 0
                scanlines.append(raw &- left)
            }
        }

        let zlibPayload = zlibCompress(scanlines)

        var out = Data()
        out.reserveCapacity(8 + 25 + 12 + zlibPayload.count + 12)
        out.append(contentsOf: signature)

        // IHDR
        var ihdr = [UInt8]()
        ihdr.reserveCapacity(13)
        appendUInt32BE(UInt32(width), to: &ihdr)
        appendUInt32BE(UInt32(height), to: &ihdr)
        ihdr.append(8) // bit depth: 8
        ihdr.append(6) // color type: RGBA
        ihdr.append(0) // compression method: deflate
        ihdr.append(0) // filter method: adaptive
        ihdr.append(0) // interlace method: none
        appendChunk(type: "IHDR", payload: ihdr, to: &out)

        // IDAT
        appendChunk(type: "IDAT", payload: zlibPayload, to: &out)

        // IEND
        appendChunk(type: "IEND", payload: [], to: &out)

        return out
    }

    /// Decodes an RFC-2083 PNG into an 8-bit RGBA8 buffer.
    public static func decode(_ data: Data) throws -> DecodedImage {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, Array(bytes[0..<8]) == signature else {
            throw Error.invalidSignature
        }

        var offset = 8
        var width = 0
        var height = 0
        var bitDepth: UInt8 = 0
        var colorType: UInt8 = 0
        var hasIHDR = false
        var palette: [UInt8] = []
        var transparency: [UInt8] = []
        var idatData = [UInt8]()

        while offset < bytes.count {
            guard offset + 12 <= bytes.count else {
                throw Error.truncatedData
            }
            let length = Int(readUInt32BE(bytes, at: offset))
            let typeBytes = bytes[(offset + 4)..<(offset + 8)]
            let chunkType = String(bytes: typeBytes, encoding: .ascii) ?? "????"
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + length
            guard payloadEnd + 4 <= bytes.count else {
                throw Error.truncatedData
            }
            let expectedCRC = readUInt32BE(bytes, at: payloadEnd)
            let actualCRC = crc32(bytes[(offset + 4)..<payloadEnd])
            guard expectedCRC == actualCRC else {
                throw Error.invalidChunkCRC(chunkType: chunkType)
            }

            let payload = Array(bytes[payloadStart..<payloadEnd])
            offset = payloadEnd + 4

            switch chunkType {
            case "IHDR":
                guard payload.count == 13 else {
                    throw Error.truncatedData
                }
                width = Int(readUInt32BE(payload, at: 0))
                height = Int(readUInt32BE(payload, at: 4))
                bitDepth = payload[8]
                colorType = payload[9]
                let compression = payload[10]
                let filter = payload[11]
                let interlace = payload[12]
                guard width > 0, height > 0 else {
                    throw Error.invalidDimensions(width: width, height: height)
                }
                guard compression == 0, filter == 0, interlace == 0, bitDepth == 8,
                      colorType == 0 || colorType == 2 || colorType == 3 || colorType == 4 || colorType == 6
                else {
                    throw Error.unsupportedFormat(bitDepth: bitDepth, colorType: colorType, interlace: interlace)
                }
                hasIHDR = true
            case "PLTE":
                palette = payload
            case "tRNS":
                transparency = payload
            case "IDAT":
                idatData.append(contentsOf: payload)
            case "IEND":
                offset = bytes.count
            default:
                break
            }
        }

        guard hasIHDR else { throw Error.missingIHDR }
        guard !idatData.isEmpty else { throw Error.missingIDAT }

        let decompressed = try zlibDecompress(idatData)
        let bpp: Int = switch colorType {
        case 0: 1
        case 2: 3
        case 3: 1
        case 4: 2
        case 6: 4
        default: 4
        }

        let rowBytes = width * bpp
        let expectedScanlineBytes = height * (1 + rowBytes)
        guard decompressed.count >= expectedScanlineBytes else {
            throw Error.truncatedData
        }

        var prevRow = [UInt8](repeating: 0, count: rowBytes)
        var rgba = [UInt8]()
        rgba.reserveCapacity(width * height * 4)

        for y in 0..<height {
            let scanlineStart = y * (1 + rowBytes)
            let filterType = decompressed[scanlineStart]
            let rawSlice = decompressed[(scanlineStart + 1)..<(scanlineStart + 1 + rowBytes)]
            let recon = try unfilterScanline(
                filterType: filterType,
                raw: rawSlice,
                prev: prevRow,
                bpp: bpp
            )

            switch colorType {
            case 6: // RGBA
                rgba.append(contentsOf: recon)
            case 2: // RGB
                for x in 0..<width {
                    let i = x * 3
                    rgba.append(recon[i])
                    rgba.append(recon[i + 1])
                    rgba.append(recon[i + 2])
                    rgba.append(255)
                }
            case 0: // Grayscale
                for x in 0..<width {
                    let g = recon[x]
                    rgba.append(g)
                    rgba.append(g)
                    rgba.append(g)
                    rgba.append(255)
                }
            case 4: // Grayscale + Alpha
                for x in 0..<width {
                    let g = recon[x * 2]
                    let a = recon[x * 2 + 1]
                    rgba.append(g)
                    rgba.append(g)
                    rgba.append(g)
                    rgba.append(a)
                }
            case 3: // Indexed palette
                for x in 0..<width {
                    let idx = Int(recon[x])
                    let pIdx = idx * 3
                    if pIdx + 2 < palette.count {
                        rgba.append(palette[pIdx])
                        rgba.append(palette[pIdx + 1])
                        rgba.append(palette[pIdx + 2])
                    } else {
                        rgba.append(contentsOf: [0, 0, 0])
                    }
                    rgba.append(idx < transparency.count ? transparency[idx] : 255)
                }
            default:
                break
            }

            prevRow = recon
        }

        return DecodedImage(width: width, height: height, rgba: rgba)
    }

    // MARK: - Scanline Unfiltering (RFC 2083 Section 6)

    /// Reconstructs one unfiltered PNG scanline for filter types `0..4`.
    public static func unfilterScanline(
        filterType: UInt8,
        raw: ArraySlice<UInt8>,
        prev: [UInt8],
        bpp: Int
    ) throws -> [UInt8] {
        let count = raw.count
        var recon = [UInt8](repeating: 0, count: count)
        let base = raw.startIndex

        switch filterType {
        case 0: // None
            for i in 0..<count {
                recon[i] = raw[base + i]
            }
        case 1: // Sub
            for i in 0..<count {
                let left: UInt8 = i >= bpp ? recon[i - bpp] : 0
                recon[i] = raw[base + i] &+ left
            }
        case 2: // Up
            for i in 0..<count {
                recon[i] = raw[base + i] &+ prev[i]
            }
        case 3: // Average
            for i in 0..<count {
                let left = Int(i >= bpp ? recon[i - bpp] : 0)
                let up = Int(prev[i])
                recon[i] = raw[base + i] &+ UInt8((left + up) >> 1)
            }
        case 4: // Paeth
            for i in 0..<count {
                let a = i >= bpp ? recon[i - bpp] : 0
                let b = prev[i]
                let c = i >= bpp ? prev[i - bpp] : 0
                recon[i] = raw[base + i] &+ paethPredictor(a, b, c)
            }
        default:
            throw Error.invalidFilterType(filterType)
        }
        return recon
    }

    @inline(__always)
    private static func paethPredictor(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8 {
        let ia = Int(a)
        let ib = Int(b)
        let ic = Int(c)
        let p = ia + ib - ic
        let pa = abs(p - ia)
        let pb = abs(p - ib)
        let pc = abs(p - ic)
        if pa <= pb && pa <= pc { return a }
        if pb <= pc { return b }
        return c
    }

    // MARK: - Chunk & Checksum Helpers

    private static func appendChunk(type: String, payload: [UInt8], to out: inout Data) {
        var header = [UInt8]()
        header.reserveCapacity(8)
        appendUInt32BE(UInt32(payload.count), to: &header)
        let typeBytes = Array(type.utf8)
        header.append(contentsOf: typeBytes)

        var crcInput = [UInt8]()
        crcInput.reserveCapacity(4 + payload.count)
        crcInput.append(contentsOf: typeBytes)
        crcInput.append(contentsOf: payload)
        let crc = crc32(crcInput[crcInput.startIndex..<crcInput.endIndex])

        out.append(contentsOf: header)
        out.append(contentsOf: payload)
        var crcBytes = [UInt8]()
        appendUInt32BE(crc, to: &crcBytes)
        out.append(contentsOf: crcBytes)
    }

    private static func appendUInt32BE(_ value: UInt32, to out: inout [UInt8]) {
        out.append(UInt8((value >> 24) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8(value & 0xFF))
    }

    private static func readUInt32BE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private static func crc32(_ slice: ArraySlice<UInt8>) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in slice {
            c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        let mod: UInt32 = 65521
        var s1: UInt32 = 1
        var s2: UInt32 = 0
        for b in bytes {
            s1 = (s1 + UInt32(b)) % mod
            s2 = (s2 + s1) % mod
        }
        return (s2 << 16) | s1
    }

    // MARK: - Zlib / DEFLATE Compression (RFC 1950 + RFC 1951 Stored Blocks)

    private static func zlibCompress(_ input: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        let maxBlock = 65535
        let blockCount = max(1, (input.count + maxBlock - 1) / maxBlock)
        out.reserveCapacity(2 + input.count + blockCount * 5 + 4)

        // Zlib header: CMF=0x78 (deflate, 32K window), FLG=0x01 (no dict, FCHECK valid: 0x7801 % 31 == 0)
        out.append(0x78)
        out.append(0x01)

        var offset = 0
        repeat {
            let remaining = input.count - offset
            let len = min(maxBlock, remaining)
            let isFinal: UInt8 = (offset + len >= input.count) ? 1 : 0
            // BFINAL = isFinal, BTYPE = 00 (stored)
            out.append(isFinal)
            let ulen = UInt16(len)
            let nlen = ~ulen
            out.append(UInt8(ulen & 0xFF))
            out.append(UInt8(ulen >> 8))
            out.append(UInt8(nlen & 0xFF))
            out.append(UInt8(nlen >> 8))
            if len > 0 {
                out.append(contentsOf: input[offset..<(offset + len)])
            }
            offset += len
        } while offset < input.count

        appendUInt32BE(adler32(input), to: &out)
        return out
    }

    // MARK: - Zlib / DEFLATE Decompression (RFC 1950 + RFC 1951)

    private static func zlibDecompress(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count >= 6 else {
            throw Error.invalidZlibHeader
        }
        let cmf = bytes[0]
        let flg = bytes[1]
        guard (cmf & 0x0F) == 8, ((UInt16(cmf) << 8) | UInt16(flg)) % 31 == 0 else {
            throw Error.invalidZlibHeader
        }
        guard (flg & 0x20) == 0 else {
            throw Error.invalidDeflateStream("preset dictionary not supported")
        }

        var reader = BitReader(bytes: bytes, byteOffset: 2)
        var output = [UInt8]()

        var bfinal = false
        while !bfinal {
            bfinal = try reader.readBits(1) == 1
            let btype = try reader.readBits(2)
            switch btype {
            case 0: // Stored
                reader.alignToByte()
                let len = try reader.readUInt16LE()
                let nlen = try reader.readUInt16LE()
                guard len == ~nlen else {
                    throw Error.invalidDeflateStream("stored block length mismatch")
                }
                let slice = try reader.readBytes(Int(len))
                output.append(contentsOf: slice)
            case 1: // Fixed Huffman
                try inflateBlock(
                    reader: &reader,
                    litTree: fixedLitTree,
                    distTree: fixedDistTree,
                    output: &output
                )
            case 2: // Dynamic Huffman
                let (litTree, distTree) = try readDynamicTrees(reader: &reader)
                try inflateBlock(
                    reader: &reader,
                    litTree: litTree,
                    distTree: distTree,
                    output: &output
                )
            default:
                throw Error.invalidDeflateStream("reserved block type 3")
            }
        }

        reader.alignToByte()
        guard reader.byteOffset + 4 <= bytes.count else {
            throw Error.invalidZlibChecksum
        }
        let expectedAdler = readUInt32BE(bytes, at: bytes.count - 4)
        let actualAdler = adler32(output)
        guard expectedAdler == actualAdler else {
            throw Error.invalidZlibChecksum
        }
        return output
    }

    private struct BitReader {
        let bytes: [UInt8]
        var byteOffset: Int
        var bitBuffer: UInt32 = 0
        var bitCount: Int = 0

        mutating func ensureBits(_ n: Int) throws {
            while bitCount < n {
                guard byteOffset < bytes.count else {
                    throw Error.invalidDeflateStream("unexpected end of input")
                }
                bitBuffer |= UInt32(bytes[byteOffset]) << bitCount
                byteOffset += 1
                bitCount += 8
            }
        }

        mutating func readBits(_ n: Int) throws -> Int {
            if n == 0 { return 0 }
            try ensureBits(n)
            let val = Int(bitBuffer & ((1 << n) - 1))
            bitBuffer >>= n
            bitCount -= n
            return val
        }

        mutating func readBit() throws -> Int {
            try ensureBits(1)
            let bit = Int(bitBuffer & 1)
            bitBuffer >>= 1
            bitCount -= 1
            return bit
        }

        mutating func alignToByte() {
            let discard = bitCount & 7
            bitBuffer >>= discard
            bitCount -= discard
            // Rewind unused whole bytes from bitBuffer back into byteOffset
            let wholeBytes = bitCount >> 3
            byteOffset -= wholeBytes
            bitBuffer = 0
            bitCount = 0
        }

        mutating func readUInt16LE() throws -> UInt16 {
            guard byteOffset + 2 <= bytes.count else {
                throw Error.invalidDeflateStream("unexpected end of stored block")
            }
            let val = UInt16(bytes[byteOffset]) | (UInt16(bytes[byteOffset + 1]) << 8)
            byteOffset += 2
            return val
        }

        mutating func readBytes(_ count: Int) throws -> ArraySlice<UInt8> {
            guard byteOffset + count <= bytes.count else {
                throw Error.invalidDeflateStream("unexpected end of stored payload")
            }
            let slice = bytes[byteOffset..<(byteOffset + count)]
            byteOffset += count
            return slice
        }
    }

    private struct HuffmanTree: Sendable {
        let counts: [Int]
        let symbols: [Int]

        init(lengths: [Int]) {
            var counts = [Int](repeating: 0, count: 16)
            for len in lengths where len > 0 {
                counts[len] += 1
            }
            var offsets = [Int](repeating: 0, count: 16)
            var total = 0
            for bits in 1...15 {
                offsets[bits] = total
                total += counts[bits]
            }
            var symbols = [Int](repeating: 0, count: total)
            for (sym, len) in lengths.enumerated() where len > 0 {
                symbols[offsets[len]] = sym
                offsets[len] += 1
            }
            self.counts = counts
            self.symbols = symbols
        }

        func decode(_ reader: inout BitReader) throws -> Int {
            var code = 0
            var first = 0
            var index = 0
            for len in 1...15 {
                code |= try reader.readBit()
                let count = counts[len]
                if code - count < first {
                    return symbols[index + (code - first)]
                }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw Error.invalidDeflateStream("invalid Huffman code")
        }
    }

    private static let fixedLitTree: HuffmanTree = {
        var lengths = [Int](repeating: 0, count: 288)
        for i in 0...143 { lengths[i] = 8 }
        for i in 144...255 { lengths[i] = 9 }
        for i in 256...279 { lengths[i] = 7 }
        for i in 280...287 { lengths[i] = 8 }
        return HuffmanTree(lengths: lengths)
    }()

    private static let fixedDistTree: HuffmanTree = {
        HuffmanTree(lengths: [Int](repeating: 5, count: 32))
    }()

    private static let codeLengthOrder = [
        16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15
    ]
    private static let lengthBases = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258
    ]
    private static let lengthExtra = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0
    ]
    private static let distBases = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193,
        12289, 16385, 24577
    ]
    private static let distExtra = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13
    ]

    private static func readDynamicTrees(reader: inout BitReader) throws -> (HuffmanTree, HuffmanTree) {
        let hlit = try reader.readBits(5) + 257
        let hdist = try reader.readBits(5) + 1
        let hclen = try reader.readBits(4) + 4

        var codeLengths = [Int](repeating: 0, count: 19)
        for i in 0..<hclen {
            codeLengths[codeLengthOrder[i]] = try reader.readBits(3)
        }
        let codeTree = HuffmanTree(lengths: codeLengths)

        var allLengths = [Int]()
        allLengths.reserveCapacity(hlit + hdist)
        while allLengths.count < hlit + hdist {
            let sym = try codeTree.decode(&reader)
            if sym < 16 {
                allLengths.append(sym)
            } else {
                let repeatCount: Int
                let value: Int
                if sym == 16 {
                    guard let last = allLengths.last else {
                        throw Error.invalidDeflateStream("repeat with no previous length")
                    }
                    value = last
                    repeatCount = try reader.readBits(2) + 3
                } else if sym == 17 {
                    value = 0
                    repeatCount = try reader.readBits(3) + 3
                } else {
                    value = 0
                    repeatCount = try reader.readBits(7) + 11
                }
                for _ in 0..<repeatCount {
                    allLengths.append(value)
                }
            }
        }

        let litLengths = Array(allLengths[0..<hlit])
        let distLengths = Array(allLengths[hlit..<(hlit + hdist)])
        return (HuffmanTree(lengths: litLengths), HuffmanTree(lengths: distLengths))
    }

    private static func inflateBlock(
        reader: inout BitReader,
        litTree: HuffmanTree,
        distTree: HuffmanTree,
        output: inout [UInt8]
    ) throws {
        while true {
            let sym = try litTree.decode(&reader)
            if sym < 256 {
                output.append(UInt8(sym))
            } else if sym == 256 {
                return
            } else {
                let lenIdx = sym - 257
                guard lenIdx >= 0, lenIdx < lengthBases.count else {
                    throw Error.invalidDeflateStream("invalid length symbol \(sym)")
                }
                let length = lengthBases[lenIdx] + (try reader.readBits(lengthExtra[lenIdx]))
                let distSym = try distTree.decode(&reader)
                guard distSym >= 0, distSym < distBases.count else {
                    throw Error.invalidDeflateStream("invalid distance symbol \(distSym)")
                }
                let distance = distBases[distSym] + (try reader.readBits(distExtra[distSym]))
                guard distance <= output.count else {
                    throw Error.invalidDeflateStream("distance \(distance) exceeds output size \(output.count)")
                }
                for _ in 0..<length {
                    output.append(output[output.count - distance])
                }
            }
        }
    }
}
