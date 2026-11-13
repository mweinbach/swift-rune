import Foundation

/// Parsed Apple Advanced Typography (`trak`) track-0 curve (`rune::text::trak::Trak`).
///
/// Maps optical point sizes to tracking units (`unitsPerEm`), matching CoreText's optical tracking
/// and computing any adjustment delta when an explicit optical size differs from rasterized pixel size.
public struct Trak: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var pointSize: Float
        public var units: Float

        public init(pointSize: Float, units: Float) {
            self.pointSize = pointSize
            self.units = units
        }
    }

    public var sizes: [Entry]
    public var unitsPerEm: Float

    public init(sizes: [Entry], unitsPerEm: Float) {
        self.sizes = sizes
        self.unitsPerEm = unitsPerEm
    }

    /// Reads the `trak` table from a raw SFNT / TTC font blob (`index` selects face in `.ttc`).
    public static func ofSFNT(_ data: Data, index: Int = 0) -> Trak? {
        guard index >= 0 else { return nil }
        return data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard bytes.count >= 12 else { return nil }

            let faceOffset: Int
            if readUInt32BE(bytes, at: 0) == 0x74746366 /* 'ttcf' */ {
                guard bytes.count >= 16 else { return nil }
                let numFonts = Int(readUInt32BE(bytes, at: 8))
                guard index < numFonts, 12 + index * 4 + 4 <= bytes.count else { return nil }
                faceOffset = Int(readUInt32BE(bytes, at: 12 + index * 4))
            } else {
                guard index == 0 else { return nil }
                faceOffset = 0
            }

            guard faceOffset >= 0, faceOffset + 12 <= bytes.count else { return nil }
            let numTables = Int(readUInt16BE(bytes, at: faceOffset + 4))
            guard faceOffset + 12 + numTables * 16 <= bytes.count else { return nil }

            var headOffset: Int?
            var headLength = 0
            var trakOffset: Int?
            var trakLength = 0

            for i in 0..<numTables {
                let rec = faceOffset + 12 + i * 16
                let tag = readUInt32BE(bytes, at: rec)
                let off = Int(readUInt32BE(bytes, at: rec + 8))
                let len = Int(readUInt32BE(bytes, at: rec + 12))
                if tag == 0x68656164 /* 'head' */ {
                    headOffset = off
                    headLength = len
                } else if tag == 0x7472616B /* 'trak' */ {
                    trakOffset = off
                    trakLength = len
                }
            }

            guard let hOff = headOffset, headLength >= 20, hOff + 20 <= bytes.count,
                  let tOff = trakOffset, trakLength > 0, tOff + trakLength <= bytes.count else {
                return nil
            }
            let upem = readUInt16BE(bytes, at: hOff + 18)
            return parse(data.subdata(in: tOff..<(tOff + trakLength)), unitsPerEm: upem)
        }
    }

    /// Parses a `trak` table slice (`rune::text::trak::Trak::parse`).
    public static func parse(_ table: Data, unitsPerEm: UInt16) -> Trak? {
        guard unitsPerEm != 0, table.count >= 12 else { return nil }
        return table.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            let version = readUInt32BE(b, at: 0)
            let format = readUInt16BE(b, at: 4)
            let horizOffset = Int(readUInt16BE(b, at: 6))
            guard version == 0x0001_0000, format == 0, horizOffset >= 12, horizOffset + 8 <= b.count else {
                return nil
            }
            let nTracks = Int(readUInt16BE(b, at: horizOffset))
            let nSizes = Int(readUInt16BE(b, at: horizOffset + 2))
            let sizeTableOffset = Int(readUInt32BE(b, at: horizOffset + 4))
            guard nTracks > 0, nSizes > 0 else { return nil }
            let (tracksEnd, tracksEndOF) = horizOffset.addingReportingOverflow(8)
            let (tableBytes, tableOF) = nTracks.multipliedReportingOverflow(by: 8)
            let (sizeBytes, sizeOF) = nSizes.multipliedReportingOverflow(by: 4)
            guard !tracksEndOF, !tableOF,
                  tracksEnd + tableBytes <= b.count,
                  !sizeOF,
                  sizeTableOffset <= b.count,
                  sizeBytes <= b.count - sizeTableOffset else {
                return nil
            }

            var sizes: [Float] = []
            sizes.reserveCapacity(nSizes)
            for i in 0..<nSizes {
                sizes.append(Float(readInt32BE(b, at: sizeTableOffset + i * 4)) / 65536.0)
            }

            struct TrackRec {
                var value: Float
                var offset: Int
            }
            var tracks: [TrackRec] = []
            tracks.reserveCapacity(nTracks)
            for i in 0..<nTracks {
                let off = horizOffset + 8 + i * 8
                let val = Float(readInt32BE(b, at: off)) / 65536.0
                let vOff = Int(readUInt16BE(b, at: off + 6))
                tracks.append(TrackRec(value: val, offset: vOff))
            }

            func trackValues(at offset: Int) -> [Float]? {
                let needed = nSizes * 2
                guard offset <= b.count, needed <= b.count - offset else { return nil }
                var out: [Float] = []
                out.reserveCapacity(nSizes)
                for i in 0..<nSizes {
                    out.append(Float(readInt16BE(b, at: offset + i * 2)))
                }
                return out
            }

            func interpolateTrackZero() -> [Float] {
                if let exact = tracks.first(where: { $0.value == 0.0 }) {
                    return trackValues(at: exact.offset) ?? [Float](repeating: 0, count: nSizes)
                }
                let below = tracks.enumerated().filter { $0.element.value < 0 }.max { $0.element.value < $1.element.value }
                let above = tracks.enumerated().filter { $0.element.value > 0 }.min { $0.element.value < $1.element.value }
                switch (below, above) {
                case let (lo?, hi?):
                    guard let a = trackValues(at: lo.element.offset),
                          let c = trackValues(at: hi.element.offset) else {
                        return [Float](repeating: 0, count: nSizes)
                    }
                    let denom = hi.element.value - lo.element.value
                    let t = denom == 0 ? 0 : (0.0 - lo.element.value) / denom
                    return zip(a, c).map { $0 + ($1 - $0) * t }
                case let (only?, nil), let (nil, only?):
                    return trackValues(at: only.element.offset) ?? [Float](repeating: 0, count: nSizes)
                case (nil, nil):
                    return [Float](repeating: 0, count: nSizes)
                }
            }

            let zeros = interpolateTrackZero()
            let pairs = zip(sizes, zeros).map { Entry(pointSize: $0, units: $1) }
            return Trak(sizes: pairs, unitsPerEm: Float(unitsPerEm))
        }
    }

    /// Interpolates tracking units at `pointSize` (`rune::text::trak::Trak::units`), clamping at ends.
    public func units(at pointSize: Float) -> Float {
        guard !sizes.isEmpty else { return 0 }
        if pointSize <= sizes[0].pointSize { return sizes[0].units }
        for i in 0..<(sizes.count - 1) {
            let a = sizes[i]
            let b = sizes[i + 1]
            if pointSize <= b.pointSize {
                let span = b.pointSize - a.pointSize
                if span == 0 { return a.units }
                let t = (pointSize - a.pointSize) / span
                return a.units + (b.units - a.units) * t
            }
        }
        return sizes[sizes.count - 1].units
    }

    /// Extra per-glyph tracking adjustment in device pixels (`rune::text::trak::Trak::spacing`).
    /// Moves CoreText-compatible tracking from `pixelSize` to `pointSize` when `enabled`, or strips it when disabled.
    public func spacing(pixelSize: Float, pointSize: Float, enabled: Bool) -> Float {
        guard unitsPerEm > 0 else { return 0 }
        let applied = units(at: pixelSize).rounded()
        let desired = enabled ? units(at: pointSize).truncatingTowardsZeroCompat() : 0.0
        return (desired - applied) * pixelSize / unitsPerEm
    }

    private static func readUInt16BE(_ b: UnsafeBufferPointer<UInt8>, at i: Int) -> UInt16 {
        (UInt16(b[i]) << 8) | UInt16(b[i + 1])
    }

    private static func readInt16BE(_ b: UnsafeBufferPointer<UInt8>, at i: Int) -> Int16 {
        Int16(bitPattern: readUInt16BE(b, at: i))
    }

    private static func readUInt32BE(_ b: UnsafeBufferPointer<UInt8>, at i: Int) -> UInt32 {
        (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16) | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
    }

    private static func readInt32BE(_ b: UnsafeBufferPointer<UInt8>, at i: Int) -> Int32 {
        Int32(bitPattern: readUInt32BE(b, at: i))
    }
}

private extension Float {
    func truncatingTowardsZeroCompat() -> Float {
        rounded(.towardZero)
    }
}

/// Thread-safe cache of `Trak` tables keyed by font blob identity and face index (`rune::text::trak::Traks`).
public final class TrakCache: @unchecked Sendable {
    private struct Key: Hashable {
        var fontHash: UInt64
        var index: Int
    }

    private let lock = NSLock()
    private var entries: [Key: Trak?] = [:]

    public init() {}

    public func trak(forFontData data: Data, index: Int = 0) -> Trak? {
        let key = Key(fontHash: GlyphAtlas.fontIdentityHash(data), index: index)
        lock.lock()
        if let hit = entries[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let parsed = Trak.ofSFNT(data, index: index)
        lock.lock()
        if entries.count > 256 {
            entries.removeAll(keepingCapacity: true)
        }
        entries[key] = parsed
        lock.unlock()
        return parsed
    }
}
