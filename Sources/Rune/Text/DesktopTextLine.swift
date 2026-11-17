#if (os(Linux) || os(Windows) || os(Android)) && !canImport(CRuneDesktopText)
#error("Rune requires the CRuneDesktopText native font backend on this platform")
#endif
#if os(WASI) && RUNE_BROWSER_TEXT && !canImport(CRuneDesktopText)
#error("The Rune browser text bridge is missing from the WASI target dependencies")
#endif
#if canImport(CRuneDesktopText) && !canImport(CoreText)
import CRuneDesktopText
import Foundation

/// A shaped line retains its native font fallback, kerning and bidi layout until its masks
/// have been copied into the shared Rune glyph atlas. Atlas tiles can span many graphemes.
struct DesktopFont: Hashable {
    #if os(Windows)
    let chromiumMask: Bool
    let clearType: Bool
    #endif
    let family: String
    let mono: Bool
    let sizePx: Float
    let weight: Int32
    let italic: Bool
    let direction: Int32
    let language: String
    let features: String
    let variations: String
    // A newly registered font can change the fallback and its palette for the same family name.
    let settingsEpoch: UInt64

    init(style: TextStyle, span: TextSpan?, families: (sans: String, mono: String), language: String?, scale: Float) {
        #if os(Windows)
        clearType = style.fontSmoothing == .clearType
        chromiumMask = style.fontSmoothing == .directWrite || style.fontSmoothing == .clearType || style.fontSmoothing == .systemDefault
        #endif
        settingsEpoch = FontFamiliesRegistry.settingsEpoch
        mono = span?.monospace == true || style.family.isMonospace
        let requested = span?.monospace == true ? FontFamily.monospace : style.family
        let stack = requested.stack(sans: families.sans, mono: families.mono)
        let candidates = FontFamily.candidates(in: stack)
        #if os(Linux)
        // Pango separates families on every comma. Skip an unrepresentable literal
        // name so its fragments cannot match unrelated installed faces.
        family = candidates.filter { !$0.contains(",") }.joined(separator: ", ")
        #else
        family = stack
        #endif
        sizePx = (span?.size ?? style.size) * scale
        let requestedWeight = span?.weight ?? style.weight
        let declared = candidates.first.flatMap {
            FaceWeightsRegistry.declaredFace(in: TextSystem.faceWeights, family: $0, requestedWeight: requestedWeight)
        }
        let matchedWeight = declared?.weight ?? requestedWeight
        weight = Int32(matchedWeight.isFinite ? min(900, max(100, matchedWeight)) : 400)
        italic = span?.italic == true || style.italic
        direction = style.direction.map { $0 == .rtl ? 2 : 1 } ?? 0
        self.language = language ?? ""
        // Both CSS ('kern' 0) and HarfBuzz (kern=0) spellings are accepted by Rune.
        func settings(_ raw: String) -> [String] {
            raw.split(separator: ",").compactMap { item in
                let parts = item.split { $0.isWhitespace || $0 == "=" || $0 == "'" || $0 == "\"" }
                guard let tag = parts.first, tag.utf8.count == 4 else { return nil }
                let raw = parts.count > 1 ? String(parts[1]) : "1"
                let value = raw == "off" ? "0" : (raw == "on" ? "1" : raw)
                guard let numeric = Double(value), numeric.isFinite else { return nil }
                return "\(tag)=\(value)"
            }
        }
        features = settings(style.shapingFeatures(monospace: mono)).joined(separator: ",")
        var axes = settings(style.variations)
        if case .fixed(let points) = style.opticalSize, points.isFinite,
           !axes.contains(where: { $0.hasPrefix("opsz=") }) { axes.append("opsz=\(points)") }
        variations = axes.joined(separator: ",")
    }
}

struct DesktopMaskKey: Hashable {
    let text: TextUTF8Key
    let font: DesktopFont
    let x: Int
    let y: Int
    var phase = SIMD2<Int>.zero
    var sourceColumns: Range<Int>? = nil
    var inkOwner: Range<Int32>? = nil
    var outlineMode: FontSmoothing? = nil
    var inkBucket: UInt8 = 0
}

/// Native rasterizers return integer-aligned coverage. Carry a moving line's fractional
/// position in the atlas mask so native-size GPU quads can retain exact texel sampling.
private struct DesktopGlyphGlide {
    let whole: SIMD2<Int>
    let phase: SIMD2<Int>

    init(_ offset: Vec2, horizontalPhase: UInt8 = 0) {
        let quarters = SIMD2(Int(exactly: (offset.x * 4).rounded()) ?? 0,
                             Int(exactly: (offset.y * 4).rounded()) ?? 0)
        let x = (quarters.x & 3) * 15 + Int(horizontalPhase)
        whole = SIMD2((quarters.x >> 2) + x / 60, quarters.y >> 2)
        phase = SIMD2(x % 60, quarters.y & 3)
    }

    /// The source includes its neighbor on the left and/or top. Adjacent output tiles use
    /// the same samples on their shared edge, including when a ligature spans two cells.
    static func translate(_ source: [UInt8], width: Int, height: Int, channels: Int, phase: SIMD2<Int>,
                          x: Int, sourceColumns: Range<Int>?) -> [UInt8] {
        guard phase != .zero else { return source }
        let dx = phase.x == 0 ? 0 : channels
        let sourceStride = width * channels + dx
        let dy = phase.y == 0 ? 0 : sourceStride
        // An independently painted grapheme can sit inside a ligature. Discard its
        // neighbor's columns before filtering, including on the first and last tiles.
        var input = source
        if let sourceColumns {
            let left = x - (phase.x == 0 ? 0 : 1)
            let start = max(0, min(sourceStride, (sourceColumns.lowerBound - left) * channels))
            let end = max(0, min(sourceStride, (sourceColumns.upperBound - left) * channels))
            if start > 0 || end < sourceStride {
                for row in stride(from: 0, to: input.count, by: sourceStride) {
                    for i in 0..<start { input[row + i] = 0 }
                    for i in end..<sourceStride { input[row + i] = 0 }
                }
            }
        }
        // Sixtieths horizontally cover both the classic ppem-dependent pen and Skia
        // quarters. The moving vertical baseline uses four steps in either mode.
        let weights = ((60 - phase.x) * (4 - phase.y), phase.x * (4 - phase.y),
                       (60 - phase.x) * phase.y, phase.x * phase.y)
        var output = [UInt8](repeating: 0, count: width * height * channels)
        for y in 0..<height {
            var src = y * sourceStride + dy + dx
            var dst = y * width * channels
            for _ in 0..<(width * channels) {
                let sum = Int(input[src]) * weights.0 + Int(input[src - dx]) * weights.1
                    + Int(input[src - dy]) * weights.2 + Int(input[src - dx - dy]) * weights.3
                output[dst] = UInt8((sum + 120) / 240)
                src += 1
                dst += 1
            }
        }
        return output
    }
}

/// Tab stops are counted in the authored paragraph, before wrapping or inserting pill markers.
struct DesktopTabStops {
    fileprivate let columns: [Int: Int]

    init(_ text: String, start: Int = 0, monospace: (Int) -> Bool) {
        var widths: [Int: Int] = [:]
        if text.utf8.contains(9) {
            var column = 0, byte = start
            for scalar in text.unicodeScalars {
                let mono = monospace(byte)
                if scalar == "\t" {
                    let width = mono ? 4 - column % 4 : 1
                    widths[byte] = width
                    column = mono ? column + width : 0
                } else {
                    column = mono && !CharacterSet.newlines.contains(scalar) ? column + 1 : 0
                }
                byte += scalar.utf8.count
            }
        }
        columns = widths
    }
}

#if os(Linux) || os(Windows) || os(Android)
/// Coverage from the same shaped glyph and fractional pen survives virtual-row
/// remounts. The store lock serializes access, and its generation recycles IDs.
struct DesktopOutlineCoverageCache {
    struct Key: Hashable {
        let record, hint, coverage: UInt32
        let scale, radius: Float
        let pen: SIMD2<Float>
        let width, height: Int
    }
    private var generation: UInt64 = 0
    private var entries: [Key: [UInt8]] = [:]
    private var keys: [Key] = []
    private var oldest = 0
    private var bytes = 0

    mutating func pixels(_ key: Key, generation: UInt64, fill: () -> [UInt8]) -> [UInt8] {
        if generation != self.generation {
            self = Self()
            self.generation = generation
        }
        if let pixels = entries[key] { return pixels }
        let pixels = fill()
        let budget = 4 * 1024 * 1024
        guard pixels.count <= budget else { return pixels }
        while bytes + pixels.count > budget || entries.count >= 4096 {
            if let removed = entries.removeValue(forKey: keys[oldest]) { bytes -= removed.count }
            oldest += 1
        }
        if oldest >= 2048 {
            keys.removeFirst(oldest)
            oldest = 0
        }
        entries[key] = pixels
        keys.append(key)
        bytes += pixels.count
        return pixels
    }
}

/// The interval index is built only for a line that actually draws vector text. A
/// native ink tile can cross cluster boundaries (italic overhangs, split ligatures).
private final class DesktopOutlineIndex {
    struct Region {
        let bytes: Range<Int32>
        let left, right, top, bottom: Float
        var maxRight: Float
    }

    struct Tile: Hashable {
        let bounds: SIMD4<Float>
        let owner: Range<Int32>?
        let smoothing: FontSmoothing
        let inkBucket: UInt8
    }

    private let lock = NSLock()
    private var cacheStore: UUID?
    private var cacheGeneration: UInt64 = 0
    private var groups: [Tile: TextOutlineGroup] = [:]
    struct Source {
        let key: OutlineStore.Key
        let anchor: SIMD2<Float>
        let intrinsic: Bool
        let cjk: Bool
    }
    private var sources: [Int32: Source] = [:]
    private var metricsByFace: [UInt64: MacOSHintMetrics?] = [:]

    func hintMetrics(for source: Source, region: Region, run: DesktopTextRun) -> MacOSHintMetrics? {
        guard source.intrinsic else { return nil }
        let face = source.key.font
        if let hit = lock.withLock({ metricsByFace[face] }) { return hit }
        let metrics = run.hintMetrics(at: region.bytes.lowerBound)
        lock.withLock { metricsByFace[face] = .some(metrics) }
        return metrics
    }

    func source(for region: Region, run: DesktopTextRun) -> Source {
        let byte = region.bytes.lowerBound
        if let source = lock.withLock({ sources[byte] }) { return source }
        let fallback = Source(key: OutlineStore.Key(font: id, index: UInt32.max, glyph: UInt32(byte)),
                              anchor: SIMD2(region.left, run.metrics.ascent), intrinsic: false, cjk: false)
        // Intrinsic curves are shared even when virtualized rows have different pens.
        let result = run.singleOutline(at: byte) ?? fallback
        lock.withLock { sources[byte] = result }
        return result
    }


    func group(for tile: Tile, store: OutlineStore) -> TextOutlineGroup? {
        lock.withLock {
            if cacheStore != store.storeID || cacheGeneration != store.generation {
                groups.removeAll(keepingCapacity: true)
                cacheStore = store.storeID
                cacheGeneration = store.generation
            }
            return groups[tile]
        }
    }

    func remember(_ group: TextOutlineGroup, for tile: Tile, store: OutlineStore) {
        lock.withLock {
            guard cacheStore == store.storeID && cacheGeneration == store.generation,
                  groups.count < 2048 else { return }
            groups[tile] = group
        }
    }

    private static let serialLock = NSLock()
    nonisolated(unsafe) private static var nextID: UInt64 = 0
    let id = serialLock.withLock {
        nextID &+= 1
        return nextID
    }
    let regions: [Region]

    init(_ run: DesktopTextRun) {
        var regions: [Region]
        if let native = run.outlineRegions() {
            regions = native
        } else {
            regions = []
            var byte: Int32 = 0
            for character in run.text {
                let next = byte + Int32(character.utf8.count)
                let range = byte..<next
                byte = next
                guard let view = run.ownedInk(range) else { continue }
                let m = view.metrics
                guard m.ink_width > 0 && m.ink_height > 0 else { continue }
                regions.append(Region(bytes: range, left: Float(m.ink_x),
                    right: Float(m.ink_x) + Float(m.ink_width), top: Float(m.ink_y),
                    bottom: Float(m.ink_y) + Float(m.ink_height), maxRight: 0))
            }
        }
        regions.sort { $0.left < $1.left }
        var right = -Float.infinity
        for i in regions.indices {
            right = max(right, regions[i].right)
            regions[i].maxRight = right
        }
        self.regions = regions
    }
}

private final class DesktopOutlineCommands {
    let anchor: SIMD2<Double>
    var commands: [OutlinePathCommand] = []

    init(anchor: SIMD2<Float>) { self.anchor = SIMD2<Double>(anchor) }

    func point(_ x: Float, _ y: Float) -> SIMD2<Double> {
        SIMD2(Double(x) - anchor.x, anchor.y - Double(y))
    }
}
#endif

private final class DesktopTextRun {
    struct InkPlanes {
        let mask: [UInt8]
        let color: [UInt8]
        let width, height: Int

        func hasMask(in columns: Range<Int>) -> Bool {
            for y in 0..<height {
                let start = y * width
                if mask[(start + columns.lowerBound)..<(start + columns.upperBound)].contains(where: { $0 != 0 }) {
                    return true
                }
            }
            return false
        }

        /// Crop the premultiplied sRGB tile to this grapheme's visual cell.
        func colorBitmap(in columns: Range<Int>) -> Data? {
            let count = columns.count
            var result = Data()
            for y in 0..<height {
                for x in columns {
                    let src = (y * width + x) * 4
                    let alpha = Int(color[src + 3])
                    if alpha == 0 { continue }
                    if result.isEmpty { result = Data(count: count * height * 4) }
                    let dst = (y * count + x - columns.lowerBound) * 4
                    for channel in 0..<4 { result[dst + channel] = color[src + channel] }
                }
            }
            return result.isEmpty ? nil : result
        }
    }

    let textKey: TextUTF8Key
    var text: String { textKey.source }
    let font: DesktopFont
    private let renderLock: NSLock
    let native: OpaquePointer
    let metrics: RuneDesktopLineMetrics
    let hasColor: Bool
    let inkOwner: Range<Int32>?
    private var lastOwnedInk: DesktopTextRun?
    #if os(Linux) || os(Windows) || os(Android)
    private var outlineIndex: DesktopOutlineIndex?
    #endif
    private let tabPadding: [(offset: Int, cumulative: Int)]
    private typealias ColorTile = (rect: SIMD4<Int>, phase: SIMD2<Int>, sourceColumns: Range<Int>?, planes: InkPlanes)
    // Mixed text can use one shifted grayscale tile and one whole-pixel emoji tile
    // for every cell in the same run. Keep both until the run moves to a new tile.
    private var lastColorTile: ColorTile?
    private var previousColorTile: ColorTile?

    var boxMetrics: (ascentPx: Float, descentPx: Float) {
        if metrics.font_ascent > 0 { return (metrics.font_ascent, metrics.font_descent) }
        return (metrics.ascent, metrics.descent)
    }

    init?(text authored: String, font: DesktopFont, start: Int = 0,
          marked: TextSystem.MarkedPillText? = nil, tabs: DesktopTabStops? = nil) {
        var text = marked?.text ?? authored
        var padding: [(offset: Int, cumulative: Int)] = []
        if let tabs, !tabs.columns.isEmpty, authored.utf8.contains(9) {
            // All font backends shape the same spaces. Map native positions back to the
            // single authored byte so clicking, selecting and copying still see one tab.
            let source = text.utf8
            var expanded: [UInt8] = []
            expanded.reserveCapacity(source.count)
            var cursor = source.startIndex, cursorOffset = 0, added = 0
            for (i, value) in authored.utf8.enumerated() where value == 9 {
                let offset = marked?.byteOffset(i) ?? i
                let index = source.index(cursor, offsetBy: offset - cursorOffset)
                expanded.append(contentsOf: source[cursor..<index])
                let width = tabs.columns[start + i] ?? 1
                expanded.append(contentsOf: repeatElement(UInt8(32), count: width))
                if width > 1 {
                    added += width - 1
                    padding.append((offset, added))
                }
                cursor = source.index(after: index)
                cursorOffset = offset + 1
            }
            expanded.append(contentsOf: source[cursor...])
            text = String(decoding: expanded, as: UTF8.self)
        }
        renderLock = NSLock()
        inkOwner = nil
        tabPadding = padding
        guard let length = Int32(exactly: text.utf8.count), font.sizePx.isFinite else { return nil }
        #if os(Windows)
        let result = rune_windows_line_create(text, length, font.family, font.sizePx,
            font.weight, font.italic ? 1 : 0, font.mono ? 1 : 0, font.direction, font.chromiumMask ? 1 : 0)
        #else
        let result = rune_desktop_line_create(text, length, font.family, font.sizePx,
            font.weight, font.italic ? 1 : 0, font.mono ? 1 : 0, font.direction)
        #endif
        guard let line = result else { return nil }
        self.textKey = TextUTF8Key(text)
        self.font = font
        native = line
        if !font.language.isEmpty || !font.features.isEmpty || !font.variations.isEmpty {
            rune_desktop_line_configure(line, font.language, font.features, font.variations)
        }
        metrics = rune_desktop_line_metrics(line)
        hasColor = rune_desktop_line_has_color(line) != 0
    }

    private init(native: OpaquePointer, source: DesktopTextRun, owner: Range<Int32>) {
        self.native = native
        renderLock = source.renderLock
        textKey = source.textKey
        font = source.font
        tabPadding = []
        inkOwner = owner
        metrics = rune_desktop_line_metrics(native)
        hasColor = rune_desktop_line_has_color(native) != 0
    }

    func ownedInk(_ bytes: Range<Int32>) -> DesktopTextRun? {
        renderLock.withLock {
            if let cached = lastOwnedInk, cached.inkOwner == bytes { return cached }
            guard let ink = rune_desktop_line_extract_ink(native, bytes.lowerBound, bytes.upperBound) else { return nil }
            let run = DesktopTextRun(native: ink, source: self, owner: bytes)
            lastOwnedInk = run
            return run
        }
    }

    #if os(Linux) || os(Windows) || os(Android)
    func singleOutline(at byte: Int32) -> DesktopOutlineIndex.Source? {
        var font: UInt64 = 0, glyph: UInt32 = 0
        var x: Float = 0, y: Float = 0
        let flags = rune_desktop_line_outline_single(native, byte, &font, &glyph, &x, &y)
        guard flags != 0 else { return nil }
        return .init(key: .init(font: font, index: UInt32.max - 1, glyph: glyph),
                     anchor: SIMD2(x, y), intrinsic: true, cjk: flags & 2 != 0)
    }

    func hintMetrics(at owner: Int32) -> MacOSHintMetrics? {
        var values = [Double](repeating: 0, count: 5)
        let valid = values.withUnsafeMutableBufferPointer {
            rune_desktop_line_apple_hint_metrics(native, owner, $0.baseAddress)
        }
        guard valid != 0 else { return nil }
        return MacOSHintMetrics(upem: values[0], xHeight: values[1], capHeight: values[2],
                                maxY: values[3], stemHeight: values[4])
    }

    func outlineRegions() -> [DesktopOutlineIndex.Region]? {
        var bounds: [DesktopOutlineIndex.Region] = []
        let ok = renderLock.withLock {
            withUnsafeMutablePointer(to: &bounds) { records in
                rune_desktop_line_outline_regions(native, { state, byte, left, top, right, bottom in
                    guard let state else { return }
                    let result = state.assumingMemoryBound(to: [DesktopOutlineIndex.Region].self)
                    result.pointee.append(.init(bytes: byte..<(byte + 1), left: left, right: right,
                                                top: top, bottom: bottom, maxRight: 0))
                }, records)
            }
        }
        guard ok != 0 else { return nil }
        // Native clusters name their first UTF-8 byte. Extend to the next scalar
        // boundary before querying its outlines, including on JNI and DirectWrite.
        var bytes = text
        return bytes.withUTF8 { utf8 in
            for i in bounds.indices {
                let start = Int(bounds[i].bytes.lowerBound)
                guard start >= 0 && start < utf8.count else { return nil }
                var end = start + 1
                while end < utf8.count && utf8[end] & 0xC0 == 0x80 { end += 1 }
                let r = bounds[i]
                bounds[i] = .init(bytes: Int32(start)..<Int32(end), left: r.left, right: r.right,
                                  top: r.top, bottom: r.bottom, maxRight: r.maxRight)
            }
            return bounds
        }
    }

    private func vectorPath(anchor: SIMD2<Float>, look: Int32, intrinsicOwner: Int32? = nil) -> BuiltOutline? {
        let path = DesktopOutlineCommands(anchor: anchor)
        let emit: RuneOutlineEmit = { context, command, x1, y1, x2, y2, x3, y3 in
            guard let context else { return }
            let path = Unmanaged<DesktopOutlineCommands>.fromOpaque(context).takeUnretainedValue()
            switch command {
            case 0: path.commands.append(.moveTo(path.point(x1, y1)))
            case 1: path.commands.append(.lineTo(path.point(x1, y1)))
            case 2: path.commands.append(.quadTo(path.point(x1, y1), path.point(x2, y2)))
            case 3: path.commands.append(.curveTo(path.point(x1, y1), path.point(x2, y2), path.point(x3, y3)))
            case 4: path.commands.append(.close)
            default: break
            }
        }
        let exported = renderLock.withLock {
            let context = Unmanaged.passUnretained(path).toOpaque()
            #if os(Linux)
            return rune_linux_line_outline_fitted(native, intrinsicOwner ?? -1, font.sizePx, look, emit, context)
            #else
            if let intrinsicOwner {
                return rune_desktop_line_outline_unplaced(native, intrinsicOwner, emit, context)
            }
            return rune_desktop_line_outline(native, emit, context)
            #endif
        }
        guard exported != 0 else { return nil }
        return OutlineBuilder.build(commands: path.commands, upem: 1)
    }

    func outlineTile(x: Int, y: Int, width: Int, height: Int, phase: SIMD2<Int>,
                     owner: Range<Int32>?, smoothing: FontSmoothing, inkBucket: UInt8 = 0, atlas: GlyphAtlas) -> DesktopOutlineTile? {
        let bounds = SIMD4(Float(x) - Float(phase.x) / 60, Float(y) - Float(phase.y) / Float(GlyphAtlas.glidePhases),
                           Float(width), Float(height))
        guard let group = outlines(in: bounds, only: owner, smoothing: smoothing, inkBucket: inkBucket, atlas: atlas) else { return nil }
        return DesktopOutlineTile(group: group, width: width, height: height)
    }

    /// Composites only glyph bounds, retaining native fallback coverage on CPU-only renderers.
    func vectorMask(tile: DesktopOutlineTile, width: Int, height: Int, atlas: GlyphAtlas) -> [UInt8]? {
        return atlas.withOutlineStore { store in
            guard tile.generation == store.generation else { return nil }
            var result = [UInt8](repeating: 0, count: width * height)
            var writtenRight = [Int](repeating: 0, count: height)
            for part in tile.components {
                let b = part.rect
                let left = b.x, top = b.y, right = b.x + b.z, bottom = b.y + b.w
                let fill = part.fill
                let rowWidth = right - left
                let key = DesktopOutlineCoverageCache.Key(record: fill.record, hint: fill.hint, coverage: fill.coverage,
                    scale: fill.scale, radius: fill.radius, pen: fill.pen, width: rowWidth, height: bottom - top)
                let pixels = store.desktopCoverage.pixels(key, generation: store.generation) {
                    OutlineMaskFiller.fillMask(store: store, fill: fill, atX: 0, atY: 0,
                        width: UInt32(rowWidth), height: UInt32(bottom - top))
                }
                // Most of each letter lands on untouched texels. Only overhangs
                // or marks crossing earlier ink need per-pixel source-over.
                pixels.withUnsafeBufferPointer { source in
                    result.withUnsafeMutableBufferPointer { destination in
                        for row in top..<bottom {
                            let src = source.baseAddress! + (row - top) * rowWidth
                            let dst = destination.baseAddress! + row * width + left
                            let overlap = max(0, min(rowWidth, writtenRight[row] - left))
                            for col in 0..<overlap where src[col] != 0 {
                                let a = Int(src[col])
                                dst[col] = UInt8(a + (Int(dst[col]) * (255 - a) + 127) / 255)
                            }
                            if overlap < rowWidth {
                                (dst + overlap).update(from: src + overlap, count: rowWidth - overlap)
                            }
                            writtenRight[row] = max(writtenRight[row], right)
                        }
                    }
                }
            }
            return result
        }
    }

    func outlines(in tile: SIMD4<Float>, only owner: Range<Int32>?, smoothing: FontSmoothing,
                  inkBucket: UInt8 = 0, atlas: GlyphAtlas) -> TextOutlineGroup? {
        #if os(Android)
        guard rune_android_text_outlines_available() != 0 else { return nil }
        #endif
        #if os(Windows) || os(Android)
        // Native design outlines omit the light-autohinted glyph shape. Keep the
        // platform's rasterized coverage for the modes that require fitted curves.
        guard smoothing != .hinted && smoothing != .hintedGpu else { return nil }
        #endif
        // A color cluster inside this tile refuses its outline below. Monochrome
        // clusters remain eligible even when the same shaped line contains emoji.
        guard tile.z > 0, tile.w > 0 else { return nil }
        let index: DesktopOutlineIndex
        if let existing = renderLock.withLock({ outlineIndex }) {
            index = existing
        } else {
            // Indexing snapshots shaped clusters, which also acquire the run lock.
            let candidate = DesktopOutlineIndex(self)
            index = renderLock.withLock {
                if let outlineIndex { return outlineIndex }
                outlineIndex = candidate
                return candidate
            }
        }
        let look: Int32
        #if os(Linux)
        switch smoothing {
        case .hinted, .hintedGpu: look = Int32(RUNE_LINUX_HINT_AUTO)
        case .windfoilChromium, .windfoilRgb: look = Int32(RUNE_LINUX_HINT_CHROMIUM)
        default: look = Int32(RUNE_LINUX_HINT_DESIGN)
        }
        #else
        look = 0
        #endif
        let size = SIMD2(tile.z, tile.w)
        let coverage: UInt32 = smoothing == .slug ? 1 : (smoothing == .windfoilRgb ? 2 : 0)
        let tileKey = DesktopOutlineIndex.Tile(bounds: tile, owner: owner, smoothing: smoothing, inkBucket: inkBucket)
        let reach: Float = smoothing == .windfoil ? 2 : 0
        return atlas.withOutlineStore { store -> TextOutlineGroup? in
            if let group = index.group(for: tileKey, store: store) { return group }
            let first = partitionPoint(index.regions) { $0.maxRight + reach <= tile.x }
            var glyphs: [TextOutlineGlyph] = []
            for region in index.regions[first...] {
                if region.left - reach >= tile.x + tile.z { break }
                if region.right + reach <= tile.x || region.top - reach >= tile.y + tile.w || region.bottom + reach <= tile.y { continue }
                if let owner, !owner.overlaps(region.bytes) { continue }
                let source = index.source(for: region, run: self)
                #if os(Windows) || os(Android)
                // At small sizes Rust uses the font's fitted CJK outline.
                if source.cjk && font.sizePx <= 24 { return nil }
                #endif
                var key = source.key
                key.hinted = UInt64(look)
                let found = store.glyph(key) {
                    if source.intrinsic {
                        return vectorPath(anchor: .zero, look: look, intrinsicOwner: region.bytes.lowerBound)
                    }
                    return ownedInk(region.bytes)?.vectorPath(anchor: source.anchor, look: look)
                }
                // Spaces have no region. A nonempty native mask without a vector
                // path (e.g. a bitmap-only face) must continue using the whole tile.
                guard case .outline(let entry) = found else { return nil }
                var pen = source.anchor - SIMD2(tile.x, tile.y)
                if source.intrinsic {
                    let whole = smoothing == .hinted || (source.cjk && font.sizePx <= 24 && smoothing != .hintedGpu)
                    pen.x = whole ? pen.x.rounded() : (pen.x * 4).rounded() / 4
                }
                let radius = smoothing == .windfoil
                    ? GlyphOutline.dilation(ppem: font.sizePx, inkBucket: inkBucket, ttHinted: source.cjk && font.sizePx <= 24) : 0
                var hint: UInt32 = 0
                if smoothing == .windfoil, !(source.cjk && font.sizePx <= 24), MacOSHinter.eligible(ppem: Double(font.sizePx)),
                   let metrics = index.hintMetrics(for: source, region: region, run: self),
                   let transform = MacOSHinter.autohint(metrics, ppem: Double(font.sizePx), d: radius) {
                    hint = store.hint(transform.values)
                }
                let outline = GlyphOutline(pen: pen, scale: 1,
                    zoom: 1, record: entry.record, hint: hint, radius: Float(radius), coverage: coverage)
                let bounds = outline.rect(bbox: entry.bbox)
                let left = max(0, bounds.x), top = max(0, bounds.y)
                let right = min(size.x, bounds.x + bounds.z), bottom = min(size.y, bounds.y + bounds.w)
                if right > left && bottom > top {
                    glyphs.append(TextOutlineGlyph(rect: SIMD4(left, top, right - left, bottom - top), outline: outline))
                }
            }
            guard !glyphs.isEmpty else { return nil }
            let group = TextOutlineGroup(size: size, glyphs: glyphs, smoothing: smoothing, generation: store.generation)
            index.remember(group, for: tileKey, store: store)
            return group
        }
    }
    #endif

    deinit { rune_desktop_line_destroy(native) }

    func maskEntry(key: DesktopMaskKey, size: SIMD2<Int>, owner: Range<Int32>?, cache: Bool, atlas: GlyphAtlas,
                   fallback: () -> [UInt8]?) -> GlyphAtlas.Entry? {
        var prepared: DesktopOutlineTile?
        func tile() -> DesktopOutlineTile? {
            #if os(Linux) || os(Windows) || os(Android)
            guard let mode = key.outlineMode else { return nil }
            if prepared == nil {
                prepared = outlineTile(x: key.x, y: key.y, width: size.x, height: size.y, phase: key.phase,
                                       owner: owner, smoothing: mode, inkBucket: key.inkBucket, atlas: atlas)
            }
            #endif
            return prepared
        }
        return atlas.desktopMask(key: cache ? key : nil, width: size.x, height: size.y, deferredTile: tile) {
            #if os(Linux) || os(Windows) || os(Android)
            if let tile = tile(), let bytes = vectorMask(tile: tile, width: size.x, height: size.y, atlas: atlas) { return bytes }
            #endif
            return fallback()
        }
    }

    func nativeByte(_ byte: Int) -> Int32 {
        guard !tabPadding.isEmpty else { return Int32(byte) }
        let count = partitionPoint(tabPadding) { $0.offset < byte }
        return Int32(byte + (count == 0 ? 0 : tabPadding[count - 1].cumulative))
    }

    func mask(x: Int, y: Int, width: Int, height: Int, phase: SIMD2<Int> = .zero, sourceColumns: Range<Int>? = nil) -> [UInt8]? {
        renderLock.lock()
        defer { renderLock.unlock() }
        let dx = phase.x == 0 ? 0 : 1, dy = phase.y == 0 ? 0 : 1
        var pixels = [UInt8](repeating: 0, count: (width + dx) * (height + dy))
        guard rune_desktop_line_mask(native, Int32(x - dx), Int32(y - dy), Int32(width + dx), Int32(height + dy), &pixels) != 0 else { return nil }
        return DesktopGlyphGlide.translate(pixels, width: width, height: height, channels: 1, phase: phase,
                                           x: x, sourceColumns: sourceColumns)
    }

    #if os(Windows)
    private weak var lastWindowsMask: WindowsGlyphMask?
    func windowsMask(bounds: SIMD4<Int32>, rect: SIMD4<Int>, phase: SIMD2<Int>, columns: Range<Int>?) -> WindowsGlyphMask {
        renderLock.withLock {
            if let tile = lastWindowsMask, tile.bounds == bounds, tile.rect == rect, tile.phase == phase, tile.columns == columns { return tile }
            let rgb: (() -> [UInt8]?)? = font.clearType ? { [self] in
                lcdMask(x: rect.x, y: rect.y, width: rect.z, height: rect.w, phase: phase, columns: columns)
            } : nil
            let tile = WindowsGlyphMask(bounds: bounds, rect: rect, phase: phase, columns: columns, rgb: rgb)
            lastWindowsMask = tile
            return tile
        }
    }

    private func lcdMask(x: Int, y: Int, width: Int, height: Int, phase: SIMD2<Int>, columns: Range<Int>?) -> [UInt8]? {
        renderLock.withLock {
            let dx = phase.x == 0 ? 0 : 1, dy = phase.y == 0 ? 0 : 1
            var rgb = [UInt8](repeating: 0, count: (width + dx) * (height + dy) * 3)
            guard rune_windows_line_lcd(native, Int32(x - dx), Int32(y - dy), Int32(width + dx), Int32(height + dy), &rgb) != 0 else { return nil }
            return DesktopGlyphGlide.translate(rgb, width: width, height: height, channels: 3, phase: phase, x: x, sourceColumns: columns)
        }
    }
    #endif

    func inkPlanes(x: Int, y: Int, width: Int, height: Int, phase: SIMD2<Int> = .zero, sourceColumns: Range<Int>? = nil) -> InkPlanes? {
        guard hasColor else { return nil }
        return renderLock.withLock {
            let rect = SIMD4(x, y, width, height)
            if let cached = lastColorTile, cached.rect == rect, cached.phase == phase, cached.sourceColumns == sourceColumns {
                return cached.planes
            }
            if let cached = previousColorTile, cached.rect == rect, cached.phase == phase, cached.sourceColumns == sourceColumns {
                previousColorTile = lastColorTile
                lastColorTile = cached
                return cached.planes
            }
            let dx = phase.x == 0 ? 0 : 1, dy = phase.y == 0 ? 0 : 1
            let w = Int32(width + dx), h = Int32(height + dy), left = Int32(x - dx), top = Int32(y - dy)
            var mask = [UInt8](repeating: 0, count: Int(w) * Int(h))
            var color = [UInt8](repeating: 0, count: mask.count * 4)
            guard rune_desktop_line_mask(native, left, top, w, h, &mask) != 0,
                  rune_desktop_line_color(native, left, top, w, h, &color) != 0 else {
                return nil
            }
            for pixel in stride(from: 0, to: color.count, by: 4) {
                let alpha = Int(color[pixel + 3])
                for i in pixel..<(pixel + 3) { color[i] = UInt8((Int(color[i]) * alpha + 127) / 255) }
            }
            let planes = InkPlanes(mask: DesktopGlyphGlide.translate(mask, width: width, height: height, channels: 1, phase: phase, x: x, sourceColumns: sourceColumns),
                                   color: DesktopGlyphGlide.translate(color, width: width, height: height, channels: 4, phase: phase, x: x, sourceColumns: sourceColumns),
                                   width: width, height: height)
            previousColorTile = lastColorTile
            lastColorTile = (rect, phase, sourceColumns, planes)
            return planes
        }
    }
}

/// The paragraph strut and an inline element's own box use their declared faces, even if
/// a fallback face draws some of their text. Share these probes across wraps of one layout.
#if os(Linux) || os(Windows) || os(Android)
/// A shaped coverage tile can be painted several times with different foregrounds.
/// Preserve its native cluster and crop, then reuse the same curves and mask allocator at paint time.
final class DesktopGlyphInk: @unchecked Sendable {
    private let run: DesktopTextRun
    private let key: DesktopMaskKey
    private let size: SIMD2<Int>
    private let owner: Range<Int32>?
    private let columns, rows: Range<Int>

    fileprivate init(run: DesktopTextRun, key: DesktopMaskKey, size: SIMD2<Int>, owner: Range<Int32>?,
                     columns: Range<Int>, rows: Range<Int>) {
        self.run = run
        self.key = key
        self.size = size
        self.owner = owner
        self.columns = columns
        self.rows = rows
    }

    func resolve(_ source: PositionedGlyph, rect: SIMD4<Float>, bucket: UInt8, atlas: GlyphAtlas)
        -> (PositionedGlyph, SIMD4<Float>) {
        let bucket = GlyphAtlas.dilationBucket(bucket, ppem: key.font.sizePx)
        guard bucket != GlyphAtlas.dilationBucket(key.inkBucket, ppem: key.font.sizePx) else { return (source, rect) }
        var variant = key
        variant.inkBucket = bucket
        guard let entry = run.maskEntry(key: variant, size: size, owner: owner, cache: true, atlas: atlas, fallback: { nil }),
              let covered = atlas.desktopCoveredRows(of: entry, columns: columns) else { return (source, rect) }
        var glyph = source
        let du = (entry.uv.z - entry.uv.x) / Float(size.x)
        let dv = (entry.uv.w - entry.uv.y) / Float(size.y)
        glyph.uv = SIMD4(entry.uv.x + Float(columns.lowerBound) * du, entry.uv.y + Float(covered.lowerBound) * dv,
                         entry.uv.x + Float(columns.upperBound) * du, entry.uv.y + Float(covered.upperBound) * dv)
        glyph.atlasPage = entry.page
        let clipped = SIMD4(Float(key.x + columns.lowerBound) - Float(key.phase.x) / 60,
                            Float(key.y + covered.lowerBound) - Float(key.phase.y) / Float(GlyphAtlas.glidePhases),
                            Float(columns.count), Float(covered.count))
        glyph.outlineGroup = run.outlines(in: clipped, only: owner, smoothing: .windfoil, inkBucket: bucket, atlas: atlas)
        let pixel = rect.w / Float(rows.count)
        let offset = Float(covered.lowerBound - rows.lowerBound)
        return (glyph, SIMD4(rect.x, rect.y + offset * pixel, rect.z, Float(covered.count) * pixel))
    }
}
#endif

final class DesktopFaceBoxes {
    typealias Box = (ascentPx: Float, descentPx: Float)
    private var measured: [DesktopFont: Box] = [:]

    func box(for font: DesktopFont) -> Box? {
        if let box = measured[font] { return box }
        guard let box = DesktopTextRun(text: " ", font: font)?.boxMetrics else { return nil }
        measured[font] = box
        return box
    }
}

final class DesktopTextLine {
    struct MarkerPosition {
        let left: Float
        let width: Float
        let rtl: Bool
    }

    struct Cell {
        let character: Character
        let byte: Int
        let byteEnd: Int
        let advance: Float
        let left: Float
        let right: Float
        let caret: Float
        let isRTL: Bool
        let endCaret: Float
        fileprivate let run: DesktopTextRun
        fileprivate let nativeBytes: Range<Int32>
        fileprivate let localLeft, localRight: Float
    }

    let cells: [Int: Cell]
    let leadingMarkers: [Int: MarkerPosition]
    let trailingMarkers: [Int: MarkerPosition]
    let width: Float
    let baseline: Float
    let strutBaselinePx: Float
    /// Vertical extents relative to the baseline, taken from the native rasterizer's
    /// run metrics without allocating a mask. A line of spaces has an empty interval.
    fileprivate let inkTopPx, inkBottomPx: Float
    let strutAscentPt: Float
    let strutFontHeightPt: Float
    let glyphEndPt: Float
    let growth: (over: Float, under: Float)
    // Secret text may reuse tiles within this layout call, without inserting its contents
    // into the persistent atlas lookup. TextRun's persistent cell path uses cache == true.
    private var transientTiles: [DesktopMaskKey: GlyphAtlas.Entry] = [:]
    private let scale: Float
    private let smoothing: FontSmoothing

    init?(text: String, start: Int, style: TextStyle, families: (sans: String, mono: String), language: String?, scale: Float,
          faceBoxes: DesktopFaceBoxes = DesktopFaceBoxes(), cutsCodePadding: Bool = false,
          pillRanges: [Range<Int>] = [], tabs: DesktopTabStops? = nil, span: (Int) -> TextSpan?,
          stretch: (Character, Int) -> Float = { _, _ in 0 },
          extra: (Int, Int) -> (leading: Float, trailing: Float) = { _, _ in (0, 0) }) {
        guard !text.isEmpty else { return nil }
        self.scale = scale
        self.smoothing = style.fontSmoothing
        DefaultFonts.registerIfNeeded()
        // Keep spans with equal font settings together. Decoration and color boundaries
        // can then divide the same shaped ligature without changing its advance.
        var groups: [(start: Int, font: DesktopFont, text: String, inlineHeightPx: Float?)] = []
        var byte = start
        var lastSpan: TextSpan?
        let baseFont = DesktopFont(style: style, span: nil, families: families, language: language, scale: scale)
        let tabs = tabs ?? DesktopTabStops(text, start: start) { style.family.isMonospace || span($0)?.monospace == true }
        var font = baseFont
        let lineHeightPx = style.resolvedLineHeight * scale
        var inlineHeightPx: Float?
        for ch in text {
            let nextSpan = span(byte)
            if nextSpan != lastSpan {
                font = DesktopFont(style: style, span: nextSpan, families: families, language: language, scale: scale)
                inlineHeightPx = nil
                if let nextSpan, nextSpan.monospace || nextSpan.size != nil {
                    let isPadding = cutsCodePadding && !nextSpan.monospace
                        && (nextSpan.size ?? style.size) < style.size
                        && nextSpan.text.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
                    if !isPadding {
                        // Resolve relative line height at the authored point size, before the
                        // device scale can round the span size across a quantization boundary.
                        inlineHeightPx = nextSpan.size.map { lineHeightPx / style.size * $0 } ?? lineHeightPx
                    }
                }
                lastSpan = nextSpan
            }
            if groups.last?.font == font {
                groups[groups.count - 1].text.append(ch)
                if let inlineHeightPx { groups[groups.count - 1].inlineHeightPx = inlineHeightPx }
            } else {
                groups.append((byte, font, String(ch), inlineHeightPx))
            }
            byte += ch.utf8.count
        }
        // Resolve the paragraph's visual order before dividing it into font runs.
        // A change of weight or family in the middle of Hebrew in an English sentence
        // must not turn those two styled runs into independent LTR paragraphs.
        let isolateLabels = style.byParagraphStart != nil
        let marked = TextSystem.MarkedPillText(text, start: start, ranges: pillRanges, isolateLabels: isolateLabels, padding: extra)
        let hasMarkers = !(marked?.markers.isEmpty ?? true)
        let bidi = groups.count > 1 || hasMarkers ? DesktopTextRun(text: text, font: baseFont, start: start, marked: marked, tabs: tabs) : nil
        if hasMarkers && bidi == nil { return nil }
        struct PlacedCell {
            let character: Character
            let byte, end: Int
            let nativeBytes: Range<Int32>
            let left, right, advance, refLeft, refWidth, caret, endCaret: Float
            let run: DesktopTextRun
            let isRTL: Bool
        }
        var visual: [PlacedCell] = []
        var inkTop = Float.infinity, inkBottom = -Float.infinity
        var boxes: [(ascentPx: Float, descentPx: Float, lineHeightPx: Float)] = []
        for group in groups {
            let groupIsolates: TextSystem.MarkedPillText?
            if isolateLabels {
                groupIsolates = groups.count == 1 && !hasMarkers ? marked
                    : TextSystem.MarkedPillText(group.text, start: group.start, ranges: pillRanges)
            } else {
                groupIsolates = nil
            }
            guard let run = DesktopTextRun(text: group.text, font: group.font, start: group.start, marked: groupIsolates, tabs: tabs) else { return nil }
            let m = run.metrics
            if m.ink_height > 0, m.ink_width > 0 {
                let top = Float(m.ink_y) - m.ascent
                inkTop = min(inkTop, top)
                inkBottom = max(inkBottom, top + Float(m.ink_height))
            }
            if let inlineHeightPx = group.inlineHeightPx {
                let metrics = faceBoxes.box(for: group.font) ?? run.boxMetrics
                boxes.append((metrics.ascentPx, metrics.descentPx, inlineHeightPx))
            }
            var local = 0
            for ch in group.text {
                let end = local + ch.utf8.count
                let byte = group.start + local
                var left: Float = 0, advance: Float = 0
                let localByte = groupIsolates?.byteOffset(local) ?? local
                let nativeBytes = run.nativeByte(localByte)..<run.nativeByte(localByte + ch.utf8.count)
                var direction = rune_desktop_line_cell(run.native, nativeBytes.lowerBound, nativeBytes.upperBound, &left, &advance)
                let right = left + advance
                var refLeft = left, refWidth = advance
                if ch == "\t", let count = tabs.columns[byte] {
                    advance += Float(count - 1) * style.letterSpacing * scale
                }
                let reference = bidi ?? run
                let refByte = bidi == nil ? localByte : marked?.byteOffset(byte - start) ?? (byte - start)
                let refStart = reference.nativeByte(refByte), refEnd = reference.nativeByte(refByte + ch.utf8.count)
                if bidi != nil {
                    direction = rune_desktop_line_cell(reference.native, refStart, refEnd, &refLeft, &refWidth)
                }
                visual.append(PlacedCell(character: ch, byte: byte, end: group.start + end, nativeBytes: nativeBytes,
                    left: left, right: right, advance: advance, refLeft: refLeft, refWidth: refWidth,
                    caret: rune_desktop_line_caret(reference.native, refStart),
                    endCaret: rune_desktop_line_caret(reference.native, refEnd), run: run, isRTL: direction < 0))
                local = end
            }
        }
        inkTopPx = inkTop
        inkBottomPx = inkBottom
        guard let strut = faceBoxes.box(for: baseFont) else { return nil }
        strutAscentPt = strut.ascentPx / scale
        strutFontHeightPt = (strut.ascentPx + strut.descentPx) / scale
        strutBaselinePx = InlineCodeBox.quantizedBox(ascentPx: strut.ascentPx,
            descentPx: strut.descentPx, lineHeightPx: lineHeightPx).over
        growth = InlineCodeBox.lineGrowth(strut: strut, code: boxes, lineHeightPx: lineHeightPx)
        baseline = (strutBaselinePx + growth.over) / scale
        visual.sort { $0.refLeft == $1.refLeft ? $0.byte < $1.byte : $0.refLeft < $1.refLeft }
        // The native strong caret can lie on the opposite edge of a mixed-direction run.
        // Preserve that visual edge as the actual font widths and inline spacing are applied.
        var edges: [Int64: Float] = [:]
        var intervals: [(left: Float, right: Float)] = []
        func edge(_ x: Float) -> Int64 { Int64((Double(x) * 1024).rounded()) }
        var widthPt: Float = 0
        var leading: [Int: MarkerPosition] = [:]
        var trailing: [Int: MarkerPosition] = [:]
        var marks: [(marker: TextSystem.MarkedPillText.Marker, left: Float, width: Float, rtl: Bool)] = []
        if let bidi, let marked {
            for marker in marked.markers {
                var left: Float = 0, width: Float = 0
                let direction = rune_desktop_line_cell(bidi.native, bidi.nativeByte(marker.shapedByte),
                    bidi.nativeByte(marker.shapedByte + 3), &left, &width)
                marks.append((marker, left, width, direction < 0))
            }
            marks.sort { $0.left < $1.left }
        }
        var nextMark = 0
        func placeMarks(before x: Float) {
            while nextMark < marks.count, marks[nextMark].left + marks[nextMark].width / 2 <= x {
                let mark = marks[nextMark]
                let position = MarkerPosition(left: widthPt, width: mark.marker.width, rtl: mark.rtl)
                if mark.marker.isLeading { leading[mark.marker.authoredByte] = position }
                else { trailing[mark.marker.authoredByte] = position }
                edges[edge(mark.left)] = widthPt
                widthPt += mark.marker.width
                edges[edge(mark.left + mark.width)] = widthPt
                nextMark += 1
            }
        }
        var lastGlyphEdge: Float = 0
        for cell in visual {
            placeMarks(before: cell.refLeft + cell.refWidth / 2)
            let padding = hasMarkers ? (leading: Float(0), trailing: Float(0)) : extra(cell.byte, cell.end)
            let advance = cell.advance / scale + style.letterSpacing + stretch(cell.character, cell.byte)
            widthPt += cell.isRTL ? padding.trailing : padding.leading
            let left = widthPt
            lastGlyphEdge = max(lastGlyphEdge, left + advance)
            edges[edge(cell.refLeft)] = widthPt
            widthPt += advance + (cell.isRTL ? padding.leading : padding.trailing)
            intervals.append((left, widthPt))
            edges[edge(cell.refLeft + cell.refWidth)] = widthPt
        }
        placeMarks(before: .infinity)
        leadingMarkers = leading
        trailingMarkers = trailing
        var result: [Int: Cell] = [:]
        for (index, cell) in visual.enumerated() {
            let (left, right) = intervals[index]
            result[cell.byte] = Cell(character: cell.character, byte: cell.byte, byteEnd: cell.end,
                advance: cell.advance / scale, left: left, right: right, caret: edges[edge(cell.caret)] ?? left, isRTL: cell.isRTL,
                endCaret: edges[edge(cell.endCaret)] ?? (left + cell.advance / scale),
                run: cell.run, nativeBytes: cell.nativeBytes, localLeft: cell.left, localRight: cell.right)
        }
        cells = result
        width = widthPt
        glyphEndPt = lastGlyphEdge
    }

    /// Join the visual cells of each decorated run before adding its CSS padding. This keeps
    /// decorations aligned to native clusters and lets the widest run determine the merged box.
    func appendDecorations(spans: [(utf8Range: Range<Int>, span: TextSpan)], index: (Int) -> Int?,
                           originX: Float, baselinePx: Float, style: TextStyle,
                           backgrounds: inout [(SIMD4<Float>, Color)], underlines: inout [SIMD4<Float>],
                           strikethroughs: inout [SIMD4<Float>], underlineEnds: inout [Float]) {
        struct Fragment {
            let spanIndex: Int
            let run: DesktopTextRun
            let left: Float
            var right: Float
        }
        var fragments: [Fragment] = []
        for cell in cells.values.sorted(by: { ($0.left, $0.byte) < ($1.left, $1.byte) }) {
            guard let i = index(cell.byte) else { continue }
            let span = spans[i].span
            guard span.background != nil || span.underline || span.strikethrough else { continue }
            if let last = fragments.last, last.spanIndex == i, last.run === cell.run,
               abs(last.right - cell.left) < 0.01 {
                fragments[fragments.count - 1].right = max(last.right, cell.right)
            } else {
                fragments.append(Fragment(spanIndex: i, run: cell.run, left: cell.left, right: cell.right))
            }
        }
        var merged: [InlineCodeBox.RunBackground] = []
        var previous: Int?
        let thickness = max(1, style.size * 0.07)
        for f in fragments where f.right - f.left > 0.01 {
            let span = spans[f.spanIndex].span, metrics = f.run.boxMetrics
            if span.underline {
                let y = baselinePx / scale + max(1, style.size * 0.12)
                underlines.append(SIMD4(originX + f.left, y, f.right - f.left, thickness))
                underlineEnds.append(originX + glyphEndPt)
            }
            if span.strikethrough {
                let y = baselinePx / scale - strutAscentPt * 0.35
                strikethroughs.append(SIMD4(originX + f.left, y, f.right - f.left, thickness))
            }
            guard let color = span.background else { continue }
            let cap = f.run.metrics.cap_height
            let v = InlineCodeBox.backgroundVertical(baselinePx: baselinePx, mono: span.monospace,
                ascentPx: metrics.ascentPx, descentPx: metrics.descentPx, capHeightPx: cap > 0 ? cap : nil,
                fontSizePx: f.run.font.sizePx)
            let pad = span.pad * scale
            let left = ((originX + f.left) * scale - pad).rounded()
            let right = ((originX + f.right) * scale + pad).rounded()
            let rect = SIMD4(left, v.top, right - left, v.bottom - v.top)
            InlineCodeBox.appendMerging(.init(rect: rect, color: color), pad: pad, into: &merged, last: &previous)
        }
        backgrounds.append(contentsOf: merged.map { ($0.rect / scale, $0.color) })
    }

    private struct Tile {
        let key: DesktopMaskKey
        let width, height, left, right: Int
    }

    // Rich paragraph paint divides line tiles at style/cell boundaries. An isolated
    // shaped cluster already contains only its owned glyphs, including overhangs.
    private func visitTiles(for cell: Cell, size: SIMD2<Int>, phase: SIMD2<Int> = .zero, owned: DesktopTextRun? = nil, isolateCell: Bool = false, _ body: (Tile) -> Void) {
        let run = owned ?? cell.run, m = run.metrics
        // A sufficiently bright Windfoil glyph can grow outside its platform ink bounds.
        let outset = smoothing == .windfoil && !run.hasColor ? 2 : 0
        let inkLeft = Int(m.ink_x) - outset, inkTop = Int(m.ink_y) - outset
        guard m.ink_width > 0, m.ink_height > 0 else { return }
        let nativeRight = Int(m.ink_x) + Int(m.ink_width) + outset
        let inkRight = nativeRight + (phase.x == 0 ? 0 : 1)
        let inkBottom = Int(m.ink_y) + Int(m.ink_height) + outset + (phase.y == 0 ? 0 : 1)
        let x0 = owned != nil || cell.localLeft < 0.01 ? inkLeft : max(inkLeft, Int(cell.localLeft.rounded()))
        let end = cell.localRight
        let lastCell = owned != nil || end > m.advance - 0.01
        var x1 = lastCell ? inkRight : min(inkRight, Int(end.rounded()))
        var sourceColumns: Range<Int>?
        if isolateCell && owned == nil && phase.x != 0 {
            let right = lastCell ? nativeRight : min(nativeRight, Int(end.rounded()))
            guard x0 < right else { return }
            sourceColumns = x0..<right
            x1 = right + 1
        }
        guard x0 < x1, inkTop < inkBottom else { return }
        let firstTile = sourceColumns != nil ? x0 : inkLeft + (x0 - inkLeft) / size.x * size.x
        let tileRight = sourceColumns != nil ? x1 : inkRight
        for x in stride(from: firstTile, to: x1, by: size.x) {
            let w = min(size.x, tileRight - x)
            for y in stride(from: inkTop, to: inkBottom, by: size.y) {
                let key = DesktopMaskKey(text: run.textKey, font: run.font, x: x, y: y,
                                         phase: phase, sourceColumns: sourceColumns, inkOwner: run.inkOwner)
                body(Tile(key: key, width: w, height: min(size.y, inkBottom - y),
                          left: max(x0, x), right: min(x1, x + w)))
            }
        }
    }

    /// Native shaping already placed and kerned the glyphs within the run. Only its
    /// translation into the layout (including justification and inline padding) is external.
    func hasVisibleInk(in window: TextRasterWindow?, baselinePx: Float, glide: Vec2) -> Bool {
        guard let window else { return true }
        let phase = DesktopGlyphGlide(glide)
        let top = (baselinePx + inkTopPx + Float(phase.whole.y)) / scale
        let bottom = (baselinePx + inkBottomPx + Float(phase.whole.y + (phase.phase.y == 0 ? 0 : 1))) / scale
        return inkTopPx < inkBottomPx && window.intersects(top, bottom)
    }

    func runOriginPx(for cell: Cell, originX: Float) -> Float {
        (originX + cell.left) * scale - cell.localLeft
    }

    #if os(Linux) || os(Windows) || os(Android)
    func outlineGroup(for glyph: PositionedGlyph, cell: Cell, originX: Float, baselineY: Float,
                      glide: Vec2, isolated: Bool, atlas: GlyphAtlas) -> TextOutlineGroup? {
        guard smoothing.isOutlineMode, glyph.uv != .zero else { return nil }
        let rect = glyph.rect * scale
        let run = cell.run
        let tile = SIMD4(rect.x - runOriginPx(for: cell, originX: originX) - glide.x,
            rect.y - baselineY * scale + run.metrics.ascent - glide.y, rect.z, rect.w)
        return run.outlines(in: tile, only: isolated ? cell.nativeBytes : nil, smoothing: smoothing, atlas: atlas)
    }
    #endif

    func glyphs(for cell: Cell, originX: Float, baselineY: Float, color: Color?,
                atlas: GlyphAtlas, cache: Bool, glidePx: Vec2 = .zero,
                restingXPx: Float? = nil, utf8Offset: Int? = nil, isolateCell: Bool = false,
                rasterWindow: TextRasterWindow? = nil) -> [PositionedGlyph] {
        let owned = isolateCell ? cell.run.ownedInk(cell.nativeBytes) : nil
        let run = owned ?? cell.run
        var quads: [PositionedGlyph] = []
        let localX = runOriginPx(for: cell, originX: originX)
        var maskX = localX, colorX = localX
        let colorGlide = DesktopGlyphGlide(glidePx)
        var maskGlide = colorGlide
        if let restingXPx {
            let absolute = restingXPx + localX
            let (pixel, phase) = TextBoxGeometry.glyphPen(at: absolute, ppem: run.font.sizePx, glide: glidePx.x, smoothing: smoothing)
            maskX = pixel - restingXPx
            maskGlide = DesktopGlyphGlide(Vec2(0, glidePx.y), horizontalPhase: phase)
            colorX = absolute.rounded() - restingXPx
        }
        func emit(_ glide: DesktopGlyphGlide, x: Float, mask: Bool, colorInk: Bool) {
            visitTiles(for: cell, size: atlas.desktopTileSize, phase: glide.phase, owned: owned, isolateCell: isolateCell) { tile in
                var key = tile.key
                #if os(Linux) || os(Windows) || os(Android)
                if cache && smoothing.isOutlineMode {
                    key.outlineMode = smoothing
                }
                #endif
                let rect = SIMD4((x + Float(tile.left + glide.whole.x)) / scale,
                    baselineY + (Float(key.y + glide.whole.y) - run.metrics.ascent) / scale,
                    Float(tile.right - tile.left) / scale, Float(tile.height) / scale)
                if let rasterWindow, !rasterWindow.intersects(rect.y, rect.y + rect.w) { return }
                let planes = run.inkPlanes(x: key.x, y: key.y, width: tile.width, height: tile.height,
                                                phase: glide.phase, sourceColumns: key.sourceColumns)
                let columns = (tile.left - key.x)..<(tile.right - key.x)
                let drawMask = mask && (planes?.hasMask(in: columns) ?? true)
                let existing = cache ? nil : transientTiles[key]
                let dimensions = SIMD2(tile.width, tile.height)
                if drawMask, let entry = existing ?? cell.run.maskEntry(key: key, size: dimensions, owner: owned?.inkOwner,
                                                                        cache: cache, atlas: atlas, fallback: {
                        return planes?.mask ?? run.mask(x: key.x, y: key.y, width: tile.width, height: tile.height,
                                                      phase: glide.phase, sourceColumns: key.sourceColumns)
                    }) {
                    if !cache { transientTiles[key] = entry }
                    if let rows = atlas.desktopCoveredRows(of: entry, columns: columns) {
                        let du = (entry.uv.z - entry.uv.x) / Float(tile.width)
                        let dv = (entry.uv.w - entry.uv.y) / Float(tile.height)
                        let uv = SIMD4(entry.uv.x + Float(columns.lowerBound) * du, entry.uv.y + Float(rows.lowerBound) * dv,
                                       entry.uv.x + Float(columns.upperBound) * du, entry.uv.y + Float(rows.upperBound) * dv)
                        var ink = rect
                        ink.y += Float(rows.lowerBound) / scale
                        ink.w = Float(rows.count) / scale
                        var glyph = PositionedGlyph(rect: ink, uv: uv, color: color, atlasPage: entry.page, utf8Offset: utf8Offset ?? cell.byte)
                        glyph.maskShiftY = Float(glide.phase.y) / Float(GlyphAtlas.glidePhases)
                        #if os(Linux) || os(Windows) || os(Android)
                        if key.outlineMode == .windfoil {
                            glyph.desktopInk = DesktopGlyphInk(run: cell.run, key: key, size: dimensions, owner: owned?.inkOwner,
                                                               columns: columns, rows: rows)
                        }
                        #endif
                        #if os(Windows)
                        if run.font.chromiumMask {
                            let bounds = SIMD4(Int32(entry.pixelOrigin.x), Int32(entry.pixelOrigin.y), Int32(tile.width), Int32(tile.height))
                            glyph.windowsMask = run.windowsMask(bounds: bounds, rect: SIMD4(key.x, key.y, tile.width, tile.height),
                                                                phase: glide.phase, columns: key.sourceColumns)
                        }
                        #endif
                        if rasterWindow?.intersects(ink.y, ink.y + ink.w) ?? true {
                            quads.append(glyph)
                        }
                    }
                }
                if colorInk, let planes {
                    let cropKey = DesktopMaskKey(text: key.text, font: key.font, x: tile.left, y: key.y,
                                                 phase: glide.phase, sourceColumns: key.sourceColumns, inkOwner: key.inkOwner)
                    if let bitmap = atlas.desktopColor(key: cache ? cropKey : nil, width: columns.count, height: tile.height,
                                                       bitmap: { planes.colorBitmap(in: columns) }) {
                        quads.append(PositionedGlyph(rect: rect, colorGlyph: bitmap, color: color, utf8Offset: utf8Offset ?? cell.byte))
                    }
                }
            }
        }
        let split = run.hasColor && (maskX != colorX || maskGlide.phase != colorGlide.phase || maskGlide.whole != colorGlide.whole)
        emit(maskGlide, x: maskX, mask: true, colorInk: !split)
        if split { emit(colorGlide, x: colorX, mask: false, colorInk: true) }
        return quads
    }

    /// Measures the exact masks used for painting, without populating a renderer's atlas.
    func addInk(to ink: inout TextInkAccumulator, originYPx: Float) {
        var lastKey: DesktopMaskKey?
        var coverage: [UInt8] = []
        var colors: [UInt8] = []
        for cell in cells.values.sorted(by: { $0.left < $1.left }) {
            visitTiles(for: cell, size: SIMD2(256, 128)) { tile in
                let key = tile.key
                if key != lastKey {
                    let planes = cell.run.inkPlanes(x: key.x, y: key.y, width: tile.width, height: tile.height)
                    coverage = planes?.mask ?? cell.run.mask(x: key.x, y: key.y, width: tile.width, height: tile.height) ?? []
                    colors = planes?.color ?? []
                    lastKey = key
                }
                guard !coverage.isEmpty else { return }
                let xOrigin = cell.left * scale - cell.localLeft
                let yOrigin = originYPx + baseline * scale - cell.run.metrics.ascent + Float(key.y)
                for y in 0..<tile.height {
                    for x in tile.left..<tile.right {
                        let index = y * tile.width + (x - key.x)
                        let mask = Float(coverage[index]) / 255
                        let colorAlpha = colors.isEmpty ? 0 : Float(colors[index * 4 + 3]) / 255
                        let alpha = mask + colorAlpha * (1 - mask)
                        if alpha > 0 { ink.add(x: xOrigin + Float(x), y: yOrigin + Float(y), alpha: alpha) }
                    }
                }
            }
        }
    }
}

/// An index of the actual ink in a measured paragraph. Prefix/suffix extrema remain
/// sorted even when the ascenders of a later line cross several earlier lines.
final class DesktopRasterLayout {
    private let fragments: [DesktopTextLine?]
    private let maxBottomsPx: [Float]
    private let minTopsPx: [Float]

    init?(shaped: ShapedText, paragraph: ShapedText.DesktopParagraph) {
        let count = shaped.portableLines.count
        guard count > 0, shaped.lineBaselinesPx.count == count,
              paragraph.fragments.count == count, paragraph.ranges.count == count else { return nil }
        var bottoms: [Float] = [], tops: [Float] = []
        bottoms.reserveCapacity(count)
        tops.reserveCapacity(count)
        for i in 0..<count {
            let record = shaped.portableLines[i]
            let native = paragraph.fragments[i]
            guard paragraph.ranges[i] == record.utf8Start..<(record.utf8Start + record.text.utf8.count),
                  native != nil || record.text.isEmpty else { return nil }
            let baseline = shaped.lineBaselinesPx[i]
            tops.append(baseline + (native?.inkTopPx ?? .infinity))
            bottoms.append(max(bottoms.last ?? -.infinity, baseline + (native?.inkBottomPx ?? -.infinity)))
        }
        if count > 1 {
            for i in stride(from: count - 2, through: 0, by: -1) { tops[i] = min(tops[i], tops[i + 1]) }
        }
        fragments = paragraph.fragments
        minTopsPx = tops
        maxBottomsPx = bottoms
    }

    func paint(_ measured: ShapedText, in window: TextRasterWindow, scale: Float, glide: Vec2,
               atlas: GlyphAtlas) -> ShapedText {
        let phase = DesktopGlyphGlide(glide)
        let lower = window.lowerY * scale - Float(phase.whole.y + (phase.phase.y == 0 ? 0 : 1))
        let upper = window.upperY * scale - Float(phase.whole.y)
        let first = partitionPoint(maxBottomsPx) { $0 <= lower }
        let last = max(first, partitionPoint(minTopsPx) { $0 < upper })
        var glyphs: [PositionedGlyph] = []
        var ranges = Array(repeating: 0..<0, count: fragments.count)
        let resting = DesktopRestingText(glide: glide, cache: true, rasterWindow: window)
        for i in first..<last {
            let start = glyphs.count
            let baseline = measured.lineBaselinesPx[i]
            if let line = fragments[i], line.hasVisibleInk(in: window, baselinePx: baseline, glide: glide) {
                let record = measured.portableLines[i]
                var byte = record.utf8Start
                for ch in record.text {
                    if let cell = line.cells[byte] {
                        glyphs += line.glyphs(for: cell, originX: record.originX, baselineY: baseline / scale,
                                              color: nil, atlas: atlas, cache: true, glidePx: glide, rasterWindow: window)
                    }
                    byte += ch.utf8.count
                }
                resting.add(.init(native: line, originX: record.originX, baselineY: baseline / scale, colors: [:]), at: i)
            }
            ranges[i] = start..<glyphs.count
        }
        if !glyphs.isEmpty {
            let end = glyphs.count..<glyphs.count
            for i in last..<ranges.count { ranges[i] = end }
        }
        var result = measured
        result.glyphs = glyphs
        result.lineGlyphRanges = ranges
        result.desktopRestingText = resting
        return result
    }
}

/// Retains the native shaped runs so painting at a new absolute pen can choose another
/// coverage mask without laying out the paragraph again.
final class DesktopRestingText {
    struct Line {
        let native: DesktopTextLine
        let originX, baselineY: Float
        let colors: [Int: Color]
        var sourceByteOffset: Int? = nil
    }

    private var lines: [Int: Line] = [:]
    private var hasFractionalRun = false
    private var minRunX = Float.infinity, maxRunX = -Float.infinity
    private let glide: Vec2
    private let cache: Bool
    private let lock = NSLock()
    private var last: (x: Float, glyphs: [PositionedGlyph], ranges: [Range<Int>], pages: Set<UInt16>, resets: UInt64)?

    private let rasterWindow: TextRasterWindow?

    init(glide: Vec2, cache: Bool, rasterWindow: TextRasterWindow? = nil) {
        self.rasterWindow = rasterWindow
        self.glide = glide
        self.cache = cache
    }

    var retainedGlyphBytes: Int {
        lock.withLock { (last?.glyphs.count ?? 0) * MemoryLayout<PositionedGlyph>.stride }
    }

    func add(_ line: Line, at index: Int) {
        lines[index] = line
        func record(_ cell: DesktopTextLine.Cell) {
            let pen = line.native.runOriginPx(for: cell, originX: line.originX)
            minRunX = min(minRunX, pen)
            maxRunX = max(maxRunX, pen)
            if abs(pen - pen.rounded()) > 1e-5 { hasFractionalRun = true }
        }
        if let offset = line.sourceByteOffset, let cell = line.native.cells[offset] {
            record(cell)
        } else {
            for cell in line.native.cells.values { record(cell) }
        }
    }

    #if os(Linux) || os(Windows) || os(Android)
    func outlineGroup(for glyph: PositionedGlyph, line index: Int, shaped: ShapedText,
                      atlas: GlyphAtlas) -> TextOutlineGroup? {
        guard cache, let line = lines[index],
              let cell = line.native.cells[glyph.utf8Offset + (line.sourceByteOffset ?? 0)] else { return nil }
        return line.native.outlineGroup(for: glyph, cell: cell, originX: line.originX, baselineY: line.baselineY,
            glide: glide, isolated: line.sourceByteOffset != nil, atlas: atlas)
    }
    #endif

    func place(_ shaped: inout ShapedText, at origin: Float, atlas: GlyphAtlas) -> Bool {
        guard !lines.isEmpty, origin.isFinite, origin != origin.rounded() || hasFractionalRun else { return false }
        // Labels a whole number of pixels apart share the same local quads. Preserve the
        // sign of every pen for ties, which Rune rounds away from zero.
        let fraction = origin - floorf(origin)
        let x: Float
        if origin + minRunX >= 0 {
            x = fraction + max(0, ceilf(-minRunX))
        } else if origin + maxRunX < 0 {
            x = fraction - max(1, ceilf(maxRunX) + 1)
        } else {
            x = origin
        }
        return lock.withLock {
            if let last, last.x == x, atlas.retainPages(last.pages, since: last.resets) {
                shaped.glyphs = last.glyphs
                shaped.lineGlyphRanges = last.ranges
                return true
            }
            var glyphs: [PositionedGlyph] = [], ranges: [Range<Int>] = []
            glyphs.reserveCapacity(shaped.glyphs.count)
            for (index, original) in shaped.lineGlyphRanges.enumerated() {
                let start = glyphs.count
                if let line = lines[index] {
                    let record = shaped.portableLines[index]
                    var byte = record.utf8Start
                    for character in record.text {
                        let sourceByte = byte + (line.sourceByteOffset ?? 0)
                        if let cell = line.native.cells[sourceByte] {
                            glyphs += line.native.glyphs(for: cell, originX: line.originX, baselineY: line.baselineY,
                                color: line.colors[byte], atlas: atlas, cache: cache, glidePx: glide,
                                restingXPx: x, utf8Offset: byte, isolateCell: line.sourceByteOffset != nil,
                                rasterWindow: rasterWindow)
                        }
                        byte += character.utf8.count
                    }
                } else {
                    glyphs += shaped.glyphs[original]
                }
                ranges.append(start..<glyphs.count)
            }
            if cache {
                let pages = Set(glyphs.filter { $0.uv != .zero }.map(\.atlasPage))
                last = (x, glyphs, ranges, pages, atlas.resets)
            }
            shaped.glyphs = glyphs
            shaped.lineGlyphRanges = ranges
            return true
        }
    }
}
#endif
