import Foundation

/// Persisted Windfoil mask cache format (`RUNEMSK1`, format v2), bounded LRU-by-recency encode/decode,
/// font-identity hashing, and background save cadence machine (`rune::text::mask_cache`).
public struct MaskCache: Sendable, Equatable {
    /// Magic header (`"RUNEMSK1"`).
    public static let magic: [UInt8] = Array("RUNEMSK1".utf8)
    /// Binary format version.
    public static let format: UInt32 = 2
    /// Default serialized mask byte budget (1 MiB).
    public static let budget: Int = 1 << 20
    /// Seconds after the first frame before the first write.
    public static let settleInterval: TimeInterval = 3.0
    /// Seconds between subsequent writes when new masks are placed.
    public static let betweenInterval: TimeInterval = 30.0

    internal static let keyBytes = 40
    internal static let entryBytes = 56

    /// Stable cross-launch mask key (`rune::text::mask_cache::StableKey`).
    public struct StableKey: Hashable, Sendable, Equatable {
        public var font: UInt64
        public var index: UInt32
        public var glyph: UInt32
        public var size: UInt32
        public var coords: UInt64
        public var dilation: UInt32
        public var subpx: UInt8
        public var subpy: UInt8
        public var apple: UInt8
        public var skew: UInt8
        public var bold: Bool
        public var color: Bool

        public init(
            font: UInt64,
            index: UInt32 = 0,
            glyph: UInt32,
            size: UInt32,
            coords: UInt64 = 0,
            dilation: UInt32 = 0,
            subpx: UInt8 = 0,
            subpy: UInt8 = 0,
            apple: UInt8 = 0,
            skew: UInt8 = 0,
            bold: Bool = false,
            color: Bool = false
        ) {
            self.font = font
            self.index = index
            self.glyph = glyph
            self.size = size
            self.coords = coords
            self.dilation = dilation
            self.subpx = subpx
            self.subpy = subpy
            self.apple = apple
            self.skew = skew
            self.bold = bold
            self.color = color
        }

        internal func encode(into out: inout [UInt8]) {
            appendLE(font, to: &out)
            appendLE(coords, to: &out)
            appendLE(index, to: &out)
            appendLE(glyph, to: &out)
            appendLE(size, to: &out)
            appendLE(dilation, to: &out)
            out.append(subpx)
            out.append(subpy)
            out.append(apple)
            out.append(skew)
            out.append(bold ? 1 : 0)
            out.append(color ? 1 : 0)
            out.append(0)
            out.append(0)
        }

        internal static func decode(from slice: ArraySlice<UInt8>) -> StableKey? {
            guard slice.count >= keyBytes else { return nil }
            let base = slice.startIndex
            return StableKey(
                font: readU64LE(slice, at: base),
                index: readU32LE(slice, at: base + 16),
                glyph: readU32LE(slice, at: base + 20),
                size: readU32LE(slice, at: base + 24),
                coords: readU64LE(slice, at: base + 8),
                dilation: readU32LE(slice, at: base + 28),
                subpx: slice[base + 32],
                subpy: slice[base + 33],
                apple: slice[base + 34],
                skew: slice[base + 35],
                bold: slice[base + 36] != 0,
                color: slice[base + 37] != 0
            )
        }
    }

    /// Stored mask metadata and offset inside `data`.
    public struct Entry: Sendable, Equatable {
        public var width: UInt32
        public var height: UInt32
        public var left: Int32
        public var top: Int32
        public var lcd: Bool
        public var color: Bool
        public var offset: Int

        public var byteCount: Int {
            Int(width) * Int(height) * (color ? 4 : 1)
        }

        public init(
            width: UInt32,
            height: UInt32,
            left: Int32,
            top: Int32,
            lcd: Bool = false,
            color: Bool = false,
            offset: Int = 0
        ) {
            self.width = width
            self.height = height
            self.left = left
            self.top = top
            self.lcd = lcd
            self.color = color
            self.offset = offset
        }
    }

    /// Input entry used when serializing a snapshot.
    public struct SnapshotEntry: Sendable, Equatable {
        public var key: StableKey
        public var width: UInt32
        public var height: UInt32
        public var left: Int32
        public var top: Int32
        public var lcd: Bool
        public var color: Bool
        public var bytes: [UInt8]

        public init(
            key: StableKey,
            width: UInt32,
            height: UInt32,
            left: Int32,
            top: Int32,
            lcd: Bool = false,
            color: Bool = false,
            bytes: [UInt8]
        ) {
            self.key = key
            self.width = width
            self.height = height
            self.left = left
            self.top = top
            self.lcd = lcd
            self.color = color
            self.bytes = bytes
        }
    }

    public private(set) var entries: [StableKey: Entry]
    public private(set) var order: [StableKey]
    public private(set) var data: [UInt8]
    public let hasColor: Bool

    public init() {
        self.entries = [:]
        self.order = []
        self.data = []
        self.hasColor = false
    }

    private init(entries: [StableKey: Entry], order: [StableKey], data: [UInt8], hasColor: Bool) {
        self.entries = entries
        self.order = order
        self.data = data
        self.hasColor = hasColor
    }

    /// Number of stored masks.
    public var count: Int { entries.count }

    /// Whether the cache has no entries.
    public var isEmpty: Bool { entries.isEmpty }

    /// Raw bytes for `key`, if stored.
    public func bytes(for key: StableKey) -> ArraySlice<UInt8>? {
        guard let e = entries[key] else { return nil }
        let end = e.offset + e.byteCount
        guard e.offset >= 0, end <= data.count else { return nil }
        return data[e.offset..<end]
    }

    /// Decodes `bytes` against `buildStamp()` (returns an empty cache when disabled or mismatched).
    public static func decode(_ bytes: [UInt8]) -> MaskCache {
        decode(bytes, stamp: buildStamp()) ?? MaskCache()
    }

    /// Decodes `bytes` against an explicit `stamp`, returning `nil` on header/stamp/length mismatch.
    public static func decode(_ bytes: [UInt8], stamp: UInt64?) -> MaskCache? {
        guard let stamp else { return nil }
        let headerSize = magic.count + 4 + 8 + 4
        guard bytes.count >= headerSize else { return nil }
        guard Array(bytes[0..<magic.count]) == magic else { return nil }
        let restOffset = magic.count
        guard readU32LE(bytes[...], at: restOffset) == format else { return nil }
        guard readU64LE(bytes[...], at: restOffset + 4) == stamp else { return nil }
        let count = Int(readU32LE(bytes[...], at: restOffset + 12))
        let tableStart = headerSize
        let tableEnd = tableStart + count * entryBytes
        guard tableEnd <= bytes.count else { return nil }

        var entries: [StableKey: Entry] = Dictionary(minimumCapacity: count)
        var order: [StableKey] = []
        order.reserveCapacity(count)

        var offset = 0
        for idx in 0..<count {
            let recStart = tableStart + idx * entryBytes
            guard let key = StableKey.decode(from: bytes[recStart..<(recStart + keyBytes)]) else {
                return nil
            }
            let metaBase = recStart + keyBytes
            let wl = readU32LE(bytes[...], at: metaBase)
            let h = readU32LE(bytes[...], at: metaBase + 4)
            let left = Int32(bitPattern: readU32LE(bytes[...], at: metaBase + 8))
            let top = Int32(bitPattern: readU32LE(bytes[...], at: metaBase + 12))
            let w = wl & 0x3FFF_FFFF
            let lcd = (wl >> 31) != 0
            let color = ((wl >> 30) & 1) != 0

            let entry = Entry(
                width: w,
                height: h,
                left: left,
                top: top,
                lcd: lcd,
                color: color,
                offset: offset
            )
            let byteCount = entry.byteCount
            guard byteCount >= 0 else { return nil }
            if entries[key] != nil {
                return nil
            }
            entries[key] = entry
            order.append(key)
            offset += byteCount
        }

        let payload = Array(bytes[tableEnd...])
        guard offset == payload.count else { return nil }
        let hasColor = entries.values.contains { $0.color }
        return MaskCache(entries: entries, order: order, data: payload, hasColor: hasColor)
    }

    /// Encodes `items` followed by unseen `earlier` entries up to `budget`.
    public static func encode(
        stamp: UInt64,
        items: [SnapshotEntry],
        earlier: MaskCache? = nil,
        budget: Int = Self.budget
    ) -> [UInt8] {
        var table: [UInt8] = []
        var data: [UInt8] = []
        var seen: Set<StableKey> = []

        func add(
            key: StableKey,
            width: UInt32,
            height: UInt32,
            left: Int32,
            top: Int32,
            lcd: Bool,
            color: Bool,
            bytes: ArraySlice<UInt8>
        ) {
            guard data.count + bytes.count <= budget else { return }
            guard seen.insert(key).inserted else { return }
            key.encode(into: &table)
            let wFlags = width
                | (lcd ? (UInt32(1) << 31) : 0)
                | (color ? (UInt32(1) << 30) : 0)
            appendLE(wFlags, to: &table)
            appendLE(height, to: &table)
            appendLE(UInt32(bitPattern: left), to: &table)
            appendLE(UInt32(bitPattern: top), to: &table)
            data.append(contentsOf: bytes)
        }

        for item in items {
            let expectedLen = Int(item.width) * Int(item.height) * (item.color ? 4 : 1)
            guard item.bytes.count == expectedLen else { continue }
            add(
                key: item.key,
                width: item.width,
                height: item.height,
                left: item.left,
                top: item.top,
                lcd: item.lcd,
                color: item.color,
                bytes: item.bytes[...]
            )
        }

        if let earlier {
            for key in earlier.order {
                guard let e = earlier.entries[key], let slice = earlier.bytes(for: key) else { continue }
                add(
                    key: key,
                    width: e.width,
                    height: e.height,
                    left: e.left,
                    top: e.top,
                    lcd: e.lcd,
                    color: e.color,
                    bytes: slice
                )
            }
        }

        let count = UInt32(table.count / entryBytes)
        var out: [UInt8] = []
        out.reserveCapacity(magic.count + 16 + table.count + data.count)
        out.append(contentsOf: magic)
        appendLE(format, to: &out)
        appendLE(stamp, to: &out)
        appendLE(count, to: &out)
        out.append(contentsOf: table)
        out.append(contentsOf: data)
        return out
    }

    // MARK: - Process-Wide Handoff & Build Stamp

    private final class GlobalStorage: @unchecked Sendable {
        let lock = NSLock()
        var offered: MaskCache?
        var sink: (@Sendable ([UInt8]) -> Void)?
    }

    private static let global = GlobalStorage()

    /// Offers serialized mask bytes saved by an earlier launch.
    public static func offer(_ bytes: [UInt8]) {
        let decoded = decode(bytes)
        global.lock.lock()
        global.offered = decoded
        global.lock.unlock()
    }

    /// Returns the most recently offered cache, if any.
    public static func currentOffered() -> MaskCache? {
        global.lock.lock()
        defer { global.lock.unlock() }
        return global.offered
    }

    /// Registers the sink that receives serialized caches when a write triggers (first registration wins).
    public static func saveWith(_ sink: @escaping @Sendable ([UInt8]) -> Void) {
        global.lock.lock()
        if global.sink == nil {
            global.sink = sink
        }
        global.lock.unlock()
    }

    internal static func currentSink() -> (@Sendable ([UInt8]) -> Void)? {
        global.lock.lock()
        defer { global.lock.unlock() }
        return global.sink
    }

    /// This build's link timestamp on Windows PE binaries; `nil` on platforms without an embedded PE stamp.
    public static func buildStamp() -> UInt64? {
        #if os(Windows)
        // PE COFF TimeDateStamp could be read on Windows; Swift target keeps nil unless PE stamp is available.
        return nil
        #else
        return nil
        #endif
    }

    /// Stable cross-launch font identity over length, leading/trailing 64 KiB, and `head` table when SFNT.
    public static func fontIdentity(_ bytes: [UInt8]) -> UInt64 {
        GlyphAtlas.fontIdentityHash(Data(bytes))
    }
}

/// Top-level convenience matching `rune::text::mask_cache::offer`.
public func offer(_ bytes: [UInt8]) {
    MaskCache.offer(bytes)
}

/// Top-level convenience matching `rune::text::mask_cache::save_with`.
public func saveWith(_ sink: @escaping @Sendable ([UInt8]) -> Void) {
    MaskCache.saveWith(sink)
}

/// Top-level convenience matching `rune::text::mask_cache::build_stamp`.
public func buildStamp() -> UInt64? {
    MaskCache.buildStamp()
}

/// Thread-safe boolean completion flag used by `MaskCacheSaving`.
public final class MaskCacheAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool

    public init(_ initial: Bool = false) {
        self.flag = initial
    }

    public func load() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    public func store(_ value: Bool) {
        lock.lock()
        flag = value
        lock.unlock()
    }
}

/// Explicit state machine scheduling when a `TextSystem` writes its glyph mask cache (`Saving`).
public enum MaskCacheSaving: Sendable {
    public enum Event: Sendable, Equatable {
        case frame(now: TimeInterval, placed: UInt64)
        case poll(now: TimeInterval, placed: UInt64)
    }

    public enum Effect: Sendable, Equatable {
        case write
        case wakeIn(TimeInterval)
    }

    case unstarted
    case settling(since: TimeInterval)
    case writing(done: MaskCacheAtomicFlag, placed: UInt64)
    case written(at: TimeInterval, placed: UInt64)

    public mutating func step(_ event: Event) -> [Effect] {
        let now: TimeInterval
        let placed: UInt64
        let isFrame: Bool
        switch event {
        case .frame(let t, let p):
            now = t
            placed = p
            isFrame = true
        case .poll(let t, let p):
            now = t
            placed = p
            isFrame = false
        }

        switch self {
        case .unstarted where isFrame:
            self = .settling(since: now)
            return [.wakeIn(MaskCache.settleInterval)]
        case .settling(let since) where now - since >= MaskCache.settleInterval:
            return [.write]
        case .writing(let done, let p) where done.load():
            self = .written(at: now, placed: p)
            return []
        case .written(let at, let p) where p != placed && now - at >= MaskCache.betweenInterval:
            return [.write]
        default:
            return []
        }
    }

    public mutating func markWriting(done: MaskCacheAtomicFlag, placed: UInt64) {
        self = .writing(done: done, placed: placed)
    }
}

// MARK: - Little-Endian Binary Helpers

private func appendLE(_ value: UInt32, to out: inout [UInt8]) {
    var v = value.littleEndian
    withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
}

private func appendLE(_ value: UInt64, to out: inout [UInt8]) {
    var v = value.littleEndian
    withUnsafeBytes(of: &v) { out.append(contentsOf: $0) }
}

private func readU32LE(_ bytes: ArraySlice<UInt8>, at index: Int) -> UInt32 {
    UInt32(bytes[index])
        | (UInt32(bytes[index + 1]) << 8)
        | (UInt32(bytes[index + 2]) << 16)
        | (UInt32(bytes[index + 3]) << 24)
}

private func readU64LE(_ bytes: ArraySlice<UInt8>, at index: Int) -> UInt64 {
    UInt64(readU32LE(bytes, at: index))
        | (UInt64(readU32LE(bytes, at: index + 4)) << 32)
}
