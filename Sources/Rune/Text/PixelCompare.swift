import Foundation
#if canImport(CoreText) && canImport(CoreGraphics)
import CoreText
import CoreGraphics
#endif
#if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
import ImageIO
import UniformTypeIdentifiers
#endif

// MARK: - Pixel Compare Harness (rune::text::pixel_compare)

/// Ink/paper color pair (`rune::text::pixel_compare::Pair`).
public struct PixelComparePair: Sendable, Equatable {
    public var name: String
    public var fg: String
    public var bg: String

    public init(name: String, fg: String, bg: String) {
        self.name = name
        self.fg = fg
        self.bg = bg
    }
}

/// Which font set a comparison sheet evaluates (`rune::text::pixel_compare::Set`).
public enum PixelCompareFontSet: String, Sendable, Equatable, CaseIterable {
    case inter
    case sf
    case mono

    public var dir: URL {
        switch self {
        case .inter: return PixelCompare.refsDir()
        case .sf: return PixelCompare.refsDir().appendingPathComponent("sf")
        case .mono: return PixelCompare.refsDir().appendingPathComponent("mono")
        }
    }

    public var displayName: String {
        switch self {
        case .inter: return "Inter"
        case .sf: return "San Francisco"
        case .mono: return "SF Mono"
        }
    }
}

/// Which CoreText rendering mode a reference sheet captures (`rune::text::pixel_compare::Reference`).
public enum PixelCompareReference: String, Sendable, Equatable {
    case smoothed
    case unsmoothed

    public static func forMode(_ mode: FontSmoothing) -> PixelCompareReference {
        mode.isEnabled ? .smoothed : .unsmoothed
    }

    public var prefix: String {
        switch self {
        case .smoothed: return ""
        case .unsmoothed: return "flat-"
        }
    }

    public var pairs: [PixelComparePair] {
        switch self {
        case .smoothed: return PixelCompare.pairs
        case .unsmoothed: return Array(PixelCompare.pairs.prefix(2))
        }
    }
}

/// One test case placed on a comparison sheet (`rune::text::pixel_compare::Case`).
public struct PixelCompareCase: Sendable, Equatable {
    public var name: String
    public var family: FontFamily
    public var weight: Float
    public var size: Float
    public var lineHeight: Float
    public var wrap: Float?
    public var text: String
    public var origin: SIMD2<Float>
    public var region: SIMD4<Float>
    public var wholeRegion: Bool

    public init(
        name: String,
        family: FontFamily,
        weight: Float,
        size: Float,
        lineHeight: Float,
        wrap: Float?,
        text: String,
        origin: SIMD2<Float>,
        region: SIMD4<Float>,
        wholeRegion: Bool
    ) {
        self.name = name
        self.family = family
        self.weight = weight
        self.size = size
        self.lineHeight = lineHeight
        self.wrap = wrap
        self.text = text
        self.origin = origin
        self.region = region
        self.wholeRegion = wholeRegion
    }

    public var fontRole: String {
        switch (family, weight >= 700.0) {
        case (.custom(PixelCompare.systemFontName), _): return "system"
        case (.monospace, _): return "mono"
        case (_, true): return "bold"
        default: return "regular"
        }
    }
}

/// Opaque RGB image buffer (`rune::text::pixel_compare::Image`).
public struct PixelCompareImage: Sendable, Equatable {
    public var width: UInt32
    public var height: UInt32
    public var rgb: [UInt8]

    public init(width: UInt32, height: UInt32, rgb: [UInt8]) {
        self.width = width
        self.height = height
        self.rgb = rgb
    }

    public func pixel(x: UInt32, y: UInt32) -> (UInt8, UInt8, UInt8) {
        let i = Int(y * width + x) * 3
        return (rgb[i], rgb[i + 1], rgb[i + 2])
    }

    public func green(x: Int, y: Int) -> UInt8? {
        guard x >= 0, y >= 0, x < Int(width), y < Int(height) else { return nil }
        return pixel(x: UInt32(x), y: UInt32(y)).1
    }

    public static func readPNG(at url: URL) throws -> PixelCompareImage {
        #if canImport(ImageIO) && canImport(CoreGraphics)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PixelCompareError.message("failed to read PNG at \(url.path)")
        }
        let w = cgImage.width
        let h = cgImage.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rgba,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PixelCompareError.message("failed to allocate RGB readback context")
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        var rgb = [UInt8]()
        rgb.reserveCapacity(w * h * 3)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            rgb.append(rgba[i])
            rgb.append(rgba[i + 1])
            rgb.append(rgba[i + 2])
        }
        return PixelCompareImage(width: UInt32(w), height: UInt32(h), rgb: rgb)
        #else
        throw PixelCompareError.message("ImageIO unavailable on this platform")
        #endif
    }

    public func writePNG(to url: URL) throws {
        #if canImport(ImageIO) && canImport(CoreGraphics) && canImport(UniformTypeIdentifiers)
        var rgba = [UInt8]()
        rgba.reserveCapacity(Int(width * height) * 4)
        for i in stride(from: 0, to: rgb.count, by: 3) {
            rgba.append(rgb[i])
            rgba.append(rgb[i + 1])
            rgba.append(rgb[i + 2])
            rgba.append(255)
        }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cgImage = CGImage(
                width: Int(width),
                height: Int(height),
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: Int(width) * 4,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw PixelCompareError.message("failed to encode PNG for \(url.path)")
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw PixelCompareError.message("failed to finalize PNG at \(url.path)")
        }
        #else
        throw PixelCompareError.message("ImageIO unavailable on this platform")
        #endif
    }

    public func writeGreenPNG(to url: URL) throws {
        #if canImport(ImageIO) && canImport(CoreGraphics) && canImport(UniformTypeIdentifiers)
        var gray = [UInt8]()
        gray.reserveCapacity(Int(width * height))
        for i in stride(from: 0, to: rgb.count, by: 3) {
            gray.append(rgb[i + 1])
        }
        let space = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(gray) as CFData),
              let cgImage = CGImage(
                width: Int(width),
                height: Int(height),
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: Int(width),
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw PixelCompareError.message("failed to encode grayscale PNG for \(url.path)")
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw PixelCompareError.message("failed to finalize grayscale PNG at \(url.path)")
        }
        #else
        throw PixelCompareError.message("ImageIO unavailable on this platform")
        #endif
    }
}

public enum PixelCompareError: Error, CustomStringConvertible, Sendable {
    case message(String)
    public var description: String {
        switch self {
        case .message(let msg): return msg
        }
    }
}

/// Pixel difference stats (`rune::text::pixel_compare::Stats`).
public struct PixelCompareStats: Sendable, Equatable {
    public var pixels: UInt64 = 0
    public var differing: UInt64 = 0
    public var over8: UInt64 = 0
    public var max: UInt8 = 0
    public var absSum: Double = 0
    public var inkRune: Double = 0
    public var inkRef: Double = 0

    public init() {}

    public mutating func add(_ other: PixelCompareStats) {
        pixels += other.pixels
        differing += other.differing
        over8 += other.over8
        max = Swift.max(max, other.max)
        absSum += other.absSum
        inkRune += other.inkRune
        inkRef += other.inkRef
    }

    public var meanAbs: Double { absSum / Double(Swift.max(1, pixels)) }
    public var inkRatio: Double { inkRune / Swift.max(1.0, inkRef) }
    public var differingShare: Double { Double(differing) / Double(Swift.max(1, pixels)) }
    public var over8Share: Double { Double(over8) / Double(Swift.max(1, pixels)) }
}

public struct PixelCompareRow: Sendable, Equatable {
    public var pair: PixelComparePair
    public var scale: Float
    public var caseItem: PixelCompareCase
    public var stats: PixelCompareStats

    public init(pair: PixelComparePair, scale: Float, caseItem: PixelCompareCase, stats: PixelCompareStats) {
        self.pair = pair
        self.scale = scale
        self.caseItem = caseItem
        self.stats = stats
    }
}

public struct PixelCompareOptions: Sendable, Equatable {
    public var set: PixelCompareFontSet
    public var smoothing: FontSmoothing?
    public var srgbBlend: Bool?
    public var reference: PixelCompareReference?

    public init(
        set: PixelCompareFontSet,
        smoothing: FontSmoothing? = nil,
        srgbBlend: Bool? = nil,
        reference: PixelCompareReference? = nil
    ) {
        self.set = set
        self.smoothing = smoothing
        self.srgbBlend = srgbBlend
        self.reference = reference
    }

    public var effectiveSmoothing: FontSmoothing { smoothing ?? .systemDefault }
    public var effectiveSrgbBlend: Bool { srgbBlend ?? true }
    public var effectiveReference: PixelCompareReference { reference ?? .forMode(effectiveSmoothing) }
}

/// Renders sheets through Rune's `TextSystem` and live/on-disk CoreText sheets (`rune::text::pixel_compare::Harness`).
public final class PixelCompareHarness {
    public let textSystem: TextSystem

    public init(textSystem: TextSystem = TextSystem()) {
        self.textSystem = textSystem
    }

    private static func parseSrgbHex(_ hex: String, fallback: (Float, Float, Float)) -> (r: Float, g: Float, b: Float) {
        let s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard stripped.count == 6, let val = UInt32(stripped, radix: 16) else { return fallback }
        let r = Float((val >> 16) & 0xFF) / 255.0
        let g = Float((val >> 8) & 0xFF) / 255.0
        let b = Float(val & 0xFF) / 255.0
        return (r, g, b)
    }

    /// Renders `cases` onto an opaque RGB buffer at `scale`, compositing `TextSystem` glyph masks
    /// over `pair.bg` using `pair.fg` (`srgbBlend` blends in sRGB byte space when true, linear when false).
    public func render(
        pair: PixelComparePair,
        scale: Float,
        srgbBlend: Bool,
        smoothing: FontSmoothing,
        cases: [PixelCompareCase],
        size: SIMD2<Float>
    ) -> PixelCompareImage {
        let fg = Self.parseSrgbHex(pair.fg, fallback: (0, 0, 0))
        let bg = Self.parseSrgbHex(pair.bg, fallback: (1, 1, 1))
        let w = max(1, Int(size.x * scale))
        let h = max(1, Int(size.y * scale))

        func toByte(_ c: Float) -> UInt8 { UInt8(clamping: Int((min(max(c, 0), 1) * 255.0).rounded())) }
        func srgbToLinear(_ c: Float) -> Float {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        func linearToSrgb(_ c: Float) -> Float {
            c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055
        }

        let bgR = srgbBlend ? bg.r : linearToSrgb(srgbToLinear(bg.r))
        let bgG = srgbBlend ? bg.g : linearToSrgb(srgbToLinear(bg.g))
        let bgB = srgbBlend ? bg.b : linearToSrgb(srgbToLinear(bg.b))
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        let b0 = toByte(bgR)
        let b1 = toByte(bgG)
        let b2 = toByte(bgB)
        for i in stride(from: 0, to: rgb.count, by: 3) {
            rgb[i] = b0
            rgb[i + 1] = b1
            rgb[i + 2] = b2
        }

        let fgLin = SIMD3<Float>(srgbToLinear(fg.r), srgbToLinear(fg.g), srgbToLinear(fg.b))
        let bgLin = SIMD3<Float>(srgbToLinear(bg.r), srgbToLinear(bg.g), srgbToLinear(bg.b))
        let atlas = textSystem.glyphAtlas

        for c in cases {
            var style = TextStyle(
                size: c.size,
                weight: c.weight,
                lineHeight: c.lineHeight,
                family: c.family,
                wrap: c.wrap != nil ? .wrap : .noWrap
            )
            style.fontSmoothing = smoothing
            let shaped = textSystem.shape(
                text: c.text,
                spans: nil,
                style: style,
                maxWidth: c.wrap,
                pixelScale: scale,
                emitGlyphs: true
            )
            let atlasW = atlas.atlas.width
            let atlasH = atlas.atlas.height
            let texels = atlas.atlas.texels
            let oxPx = c.origin.x * scale
            let oyPx = c.origin.y * scale

            for glyph in shaped.glyphs {
                let dstX0 = Int((oxPx + glyph.rect.x * scale).rounded())
                let dstY0 = Int((oyPx + glyph.rect.y * scale).rounded())
                let gw = max(0, Int((glyph.rect.z * scale).rounded()))
                let gh = max(0, Int((glyph.rect.w * scale).rounded()))
                guard gw > 0, gh > 0 else { continue }

                if let colorIndex = glyph.colorGlyphIndex, colorIndex != 0, let ce = textSystem.colorGlyph(colorIndex) {
                    for row in 0..<ce.pixelSize.y {
                        let dy = dstY0 + row
                        guard dy >= 0 && dy < h else { continue }
                        for col in 0..<ce.pixelSize.x {
                            let dx = dstX0 + col
                            guard dx >= 0 && dx < w else { continue }
                            let si = (row * ce.pixelSize.x + col) * 4
                            let a = Float(ce.rgba[si + 3]) / 255.0
                            guard a > 0 else { continue }
                            let di = (dy * w + dx) * 3
                            rgb[di] = toByte(Float(rgb[di]) / 255.0 * (1 - a) + Float(ce.rgba[si]) / 255.0)
                            rgb[di + 1] = toByte(Float(rgb[di + 1]) / 255.0 * (1 - a) + Float(ce.rgba[si + 1]) / 255.0)
                            rgb[di + 2] = toByte(Float(rgb[di + 2]) / 255.0 * (1 - a) + Float(ce.rgba[si + 2]) / 255.0)
                        }
                    }
                    continue
                }

                let srcX0 = Int((glyph.uv.x * Float(atlasW)).rounded())
                let srcY0 = Int((glyph.uv.y * Float(atlasH)).rounded())
                for row in 0..<gh {
                    let sy = srcY0 + row
                    let dy = dstY0 + row
                    guard sy >= 0, sy < atlasH, dy >= 0, dy < h else { continue }
                    for col in 0..<gw {
                        let sx = srcX0 + col
                        let dx = dstX0 + col
                        guard sx >= 0, sx < atlasW, dx >= 0, dx < w else { continue }
                        let cov = Float(texels[sy * atlasW + sx]) / 255.0
                        guard cov > 0 else { continue }
                        let di = (dy * w + dx) * 3
                        if srgbBlend {
                            rgb[di] = toByte(bg.r * (1 - cov) + fg.r * cov)
                            rgb[di + 1] = toByte(bg.g * (1 - cov) + fg.g * cov)
                            rgb[di + 2] = toByte(bg.b * (1 - cov) + fg.b * cov)
                        } else {
                            let outR = linearToSrgb(bgLin.x * (1 - cov) + fgLin.x * cov)
                            let outG = linearToSrgb(bgLin.y * (1 - cov) + fgLin.y * cov)
                            let outB = linearToSrgb(bgLin.z * (1 - cov) + fgLin.z * cov)
                            rgb[di] = toByte(outR)
                            rgb[di + 1] = toByte(outG)
                            rgb[di + 2] = toByte(outB)
                        }
                    }
                }
            }
        }
        return PixelCompareImage(width: UInt32(w), height: UInt32(h), rgb: rgb)
    }

    #if canImport(CoreText) && canImport(CoreGraphics)
    /// Generates an in-process CoreText reference sheet for comparison tests when static PNG files
    /// are not bundled in the repository.
    public func renderCoreTextReference(
        pair: PixelComparePair,
        scale: Float,
        reference: PixelCompareReference,
        cases: [PixelCompareCase],
        size: SIMD2<Float>
    ) -> PixelCompareImage {
        let fg = Self.parseSrgbHex(pair.fg, fallback: (0, 0, 0))
        let bg = Self.parseSrgbHex(pair.bg, fallback: (1, 1, 1))
        let w = max(1, Int(size.x * scale))
        let h = max(1, Int(size.y * scale))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rgba,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return PixelCompareImage(width: UInt32(w), height: UInt32(h), rgb: [UInt8](repeating: 0, count: w * h * 3))
        }
        let bgCG = CGColor(colorSpace: space, components: [CGFloat(bg.r), CGFloat(bg.g), CGFloat(bg.b), 1.0])!
        ctx.setFillColor(bgCG)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let smooth = (reference == .smoothed)
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(smooth)
        ctx.setShouldSmoothFonts(smooth)
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)

        let fgCG = CGColor(colorSpace: space, components: [CGFloat(fg.r), CGFloat(fg.g), CGFloat(fg.b), 1.0])!

        for c in cases {
            var style = TextStyle(size: c.size, weight: c.weight, lineHeight: c.lineHeight, family: c.family)
            style.fontSmoothing = smooth ? .on : .off
            let shaped = textSystem.shape(
                text: c.text,
                spans: nil,
                style: style,
                maxWidth: c.wrap,
                pixelScale: scale,
                emitGlyphs: false
            )
            let lhPt = style.resolvedLineHeight
            let baseFont = textSystem.resolveCTFont(style: style, pixelScale: scale)
            let ascentPx = Float(CTFontGetAscent(baseFont))
            let descentPx = Float(CTFontGetDescent(baseFont))
            let halfLeadingPx = (lhPt * scale - (ascentPx + descentPx)) * 0.5

            for (idx, rec) in shaped.lineStrings.enumerated() {
                guard let ctLine = rec.ctLine else { continue }
                let lineTopPx = c.origin.y * scale + Float(idx) * lhPt * scale
                let baselineDownPx = (lineTopPx + halfLeadingPx + ascentPx).rounded()
                let cgY = CGFloat(h) - CGFloat(baselineDownPx)
                let cgX = CGFloat(c.origin.x * scale + rec.originX * scale)
                ctx.saveGState()
                ctx.setFillColor(fgCG)
                ctx.textMatrix = .identity
                let runs = CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? []
                for run in runs {
                    let count = CTRunGetGlyphCount(run)
                    guard count > 0 else { continue }
                    let attrs = CTRunGetAttributes(run) as NSDictionary
                    let runFont = attrs[kCTFontAttributeName] as! CTFont
                    var glyphs = [CGGlyph](repeating: 0, count: count)
                    var positions = [CGPoint](repeating: .zero, count: count)
                    CTRunGetGlyphs(run, CFRangeMake(0, count), &glyphs)
                    CTRunGetPositions(run, CFRangeMake(0, count), &positions)
                    var adjusted = positions.map { CGPoint(x: cgX + $0.x, y: cgY + $0.y) }
                    CTFontDrawGlyphs(runFont, &glyphs, &adjusted, count, ctx)
                }
                ctx.restoreGState()
            }
        }

        var rgb = [UInt8]()
        rgb.reserveCapacity(w * h * 3)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            rgb.append(rgba[i])
            rgb.append(rgba[i + 1])
            rgb.append(rgba[i + 2])
        }
        return PixelCompareImage(width: UInt32(w), height: UInt32(h), rgb: rgb)
    }
    #endif
}

public enum PixelCompare {
    public static let pairs: [PixelComparePair] = [
        PixelComparePair(name: "light", fg: "#1d1e22", bg: "#fcfcfb"),
        PixelComparePair(name: "dark", fg: "#e6e6e6", bg: "#1d1e22"),
        PixelComparePair(name: "white", fg: "#fcfcfb", bg: "#1d1e22"),
        PixelComparePair(name: "blue", fg: "#296d9a", bg: "#fcfcfb"),
    ]
    public static let scales: [Float] = [1.0, 2.0]
    public static let sizes: [Float] = [9.0, 11.0, 13.0, 16.0, 20.0, 24.0, 32.0]
    public static let sample = "IHT\u{2014}/AVSog@8 Hamburgefonstiv"
    public static let monoSample = "It doesn't look like it; illicit 1111 mmmm @@ -33,3 +33,4 @@"
    public static let monoParagraph = "diff --git a/Welcome.md b/Welcome.md --- a/Welcome.md +++ b/Welcome.md @@ -33,3 +33,4 @@ $1 + 1$ It doesn't look like it +*Italics work though!* iiiiiiii llllllll mmmmmmmm"
    public static let paragraph = "The quick brown fox jumps over the lazy dog. AV To Wa Ty Yo LT fi fl ffi office flour 0123456789 ($4.50, 87%) \u{2014} \"quoted\" & semicolons; colons: question? Incomprehensibilities and HYPERVENTILATION."
    public static let sheetWidth: Float = 640.0
    public static let rowX: Float = 16.0
    public static let paragraphHeight: Float = 130.0
    public static let systemFontName = "System Font"

    public static func cases(for set: PixelCompareFontSet) -> [PixelCompareCase] {
        let text = set == .mono ? monoSample : sample
        let family: FontFamily
        let rows: [(String, Float, Float)]
        switch set {
        case .inter:
            family = .systemUI
            var r: [(String, Float, Float)] = []
            for (w, label) in [(Float(400.0), "regular"), (Float(700.0), "bold")] {
                for s in sizes { r.append((label, w, s)) }
            }
            rows = r
        case .sf:
            family = .custom(systemFontName)
            rows = [("sf regular", 400.0, 16.0), ("sf bold", 700.0, 16.0), ("sf bold", 700.0, 28.0), ("sf bold", 700.0, 32.0)]
        case .mono:
            family = .monospace
            rows = [11.0, 12.0, 13.0, 13.5, 14.0, 16.0].map { ("mono", 400.0, $0) }
        }

        var out: [PixelCompareCase] = []
        var y: Float = 4.0
        for (font, weight, size) in rows {
            let height = ceil(size * 1.25) + 6.0
            out.append(PixelCompareCase(
                name: "\(font) \(size)",
                family: family,
                weight: weight,
                size: size,
                lineHeight: 0,
                wrap: nil,
                text: text,
                origin: SIMD2<Float>(rowX, y + 3.0),
                region: SIMD4<Float>(0, y, sheetWidth, height),
                wholeRegion: false
            ))
            y += height
        }
        let top = ceil(y) + 4.0
        out.append(paragraphCase(family: family, top: top))
        return out
    }

    public static func paragraphCase(family: FontFamily, top: Float) -> PixelCompareCase {
        if family == .monospace {
            return PixelCompareCase(
                name: "mono paragraph 13.5/22",
                family: family,
                weight: 400.0,
                size: 13.5,
                lineHeight: 22.0,
                wrap: 567.0,
                text: monoParagraph,
                origin: SIMD2<Float>(49.0, top + 40.0),
                region: SIMD4<Float>(0, top + 30.0, sheetWidth, 90.0),
                wholeRegion: true
            )
        }
        return PixelCompareCase(
            name: family == .systemUI ? "paragraph 16/26" : "sf paragraph 16/26",
            family: family,
            weight: 400.0,
            size: 16.0,
            lineHeight: 26.0,
            wrap: 567.0,
            text: paragraph,
            origin: SIMD2<Float>(49.0, top + 40.0),
            region: SIMD4<Float>(0, top + 30.0, sheetWidth, 90.0),
            wholeRegion: true
        )
    }

    public static func sheetHeight(for set: PixelCompareFontSet) -> Float {
        guard let last = cases(for: set).last else { return paragraphHeight }
        return last.region[1] - 30.0 + paragraphHeight
    }

    public static func refsDir() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/coretext")
    }

    public static func fontPaths() -> [URL] {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return [
            cwd.appendingPathComponent("assets/Inter-Regular.ttf"),
            refsDir().appendingPathComponent("Inter-Bold-subset.ttf"),
        ]
    }

    public static func systemFontPath() -> URL? {
        #if os(macOS)
        return systemFontFiles(matching: ["sfnsttf"]).first
        #else
        return nil
        #endif
    }

    public static func systemMonoPath() -> URL? {
        #if os(macOS)
        return systemFontFiles(matching: ["sfnsmono"]).first { !$0.path.lowercased().contains("italic") }
        #else
        return nil
        #endif
    }

    private static func systemFontFiles(matching tokens: [String]) -> [URL] {
        let dirs = ["/System/Library/Fonts", "/System/Library/Fonts/Supplemental"]
        let fm = FileManager.default
        var matches: [URL] = []
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in items {
                let lower = name.lowercased().filter { $0.isLetter || $0.isNumber }
                if tokens.contains(where: { lower.contains($0) }) {
                    matches.append(URL(fileURLWithPath: dir).appendingPathComponent(name))
                }
            }
        }
        return matches.sorted { $0.path < $1.path }
    }

    public static func available(set: PixelCompareFontSet) throws {
        if set == .sf && systemFontPath() == nil {
            throw PixelCompareError.message("no system font (SFNS) on this machine")
        }
        if set == .mono && systemMonoPath() == nil {
            throw PixelCompareError.message("no SF Mono (SFNSMono) on this machine")
        }
        let layoutURL = set.dir.appendingPathComponent("layout.txt")
        guard let have = try? String(contentsOf: layoutURL, encoding: .utf8) else {
            throw PixelCompareError.message("no \(set.displayName) references in \(set.dir.path)")
        }
        let want = layoutFile(for: set)
        if have != want {
            throw PixelCompareError.message("\(set.displayName) references are stale")
        }
    }

    public static func layoutDigest(for set: PixelCompareFontSet, scale: Float) -> String {
        let textSystem = TextSystem()
        var hash: UInt64 = 0xcbf29ce484222325
        @inline(__always) func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        func mixU32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { for b in $0 { mix(b) } }
        }
        for c in cases(for: set) {
            let style = TextStyle(size: c.size, weight: c.weight, lineHeight: c.lineHeight, family: c.family)
            let shaped = textSystem.shape(text: c.text, spans: nil, style: style, maxWidth: c.wrap, pixelScale: scale, emitGlyphs: true)
            for g in shaped.glyphs {
                mixU32(g.rect.x.bitPattern)
                mixU32(g.rect.y.bitPattern)
                mixU32(g.rect.z.bitPattern)
                mixU32(g.rect.w.bitPattern)
            }
        }
        return String(format: "%016llx", hash)
    }

    public static func layoutFile(for set: PixelCompareFontSet) -> String {
        scales.map { "\($0)x \(layoutDigest(for: set, scale: $0))\n" }.joined()
    }

    public static func exportJSON(for set: PixelCompareFontSet, scale: Float) -> [String: Any] {
        let textSystem = TextSystem()
        let fonts = fontPaths().map(\.path)
        let rows: [[String: Any]] = cases(for: set).map { c in
            let style = TextStyle(size: c.size, weight: c.weight, lineHeight: c.lineHeight, family: c.family)
            let shaped = textSystem.shape(text: c.text, spans: nil, style: style, maxWidth: c.wrap, pixelScale: scale, emitGlyphs: true)
            let glyphs = shaped.glyphs.map { [Double($0.rect.x), Double($0.rect.y), Double($0.rect.z), Double($0.rect.w)] }
            return [
                "name": c.name,
                "font": c.fontRole,
                "size": c.size,
                "weight": c.weight,
                "opsz": c.size,
                "glyphs": glyphs,
            ]
        }
        let sheets: [[String: Any]] = [PixelCompareReference.smoothed, .unsmoothed].flatMap { r in
            r.pairs.map { p in
                [
                    "file": "\(r.prefix)\(p.name)-\(scale)x.png",
                    "smooth": r == .smoothed,
                    "fg": p.fg,
                    "bg": p.bg,
                ]
            }
        }
        return [
            "scale": scale,
            "width": Int(sheetWidth * scale),
            "height": Int(sheetHeight(for: set) * scale),
            "fonts": [
                "regular": fonts[0],
                "bold": fonts[1],
                "system": systemFontPath()?.path as Any,
                "mono": systemMonoPath()?.path as Any,
            ],
            "sheets": sheets,
            "cases": rows,
        ]
    }

    public static func referencePath(set: PixelCompareFontSet, reference: PixelCompareReference, pair: PixelComparePair, scale: Float) -> URL {
        set.dir.appendingPathComponent("\(reference.prefix)\(pair.name)-\(scale)x.png")
    }

    public static func statsIn(
        rune: PixelCompareImage,
        reference: PixelCompareImage,
        rect: [UInt32],
        shift: (Int, Int) = (0, 0)
    ) -> PixelCompareStats {
        let paperRune = rune.pixel(x: 0, y: 0).1
        let paperRef = reference.pixel(x: 0, y: 0).1
        var s = PixelCompareStats()
        let x0 = rect[0], y0 = rect[1], x1 = rect[2], y1 = rect[3]
        guard x1 > x0, y1 > y0 else { return s }
        for y in y0..<y1 {
            for x in x0..<x1 {
                let a = rune.green(x: Int(x) - shift.0, y: Int(y) - shift.1) ?? paperRune
                let b = reference.pixel(x: x, y: y).1
                let d = a >= b ? a - b : b - a
                s.pixels += 1
                if d > 0 { s.differing += 1 }
                if d > 8 { s.over8 += 1 }
                if d > s.max { s.max = d }
                s.absSum += Double(d)
                s.inkRune += Double(a >= paperRune ? a - paperRune : paperRune - a)
                s.inkRef += Double(b >= paperRef ? b - paperRef : paperRef - b)
            }
        }
        return s
    }

    public static func inkBounds(images: [PixelCompareImage], rect: [UInt32]) -> [UInt32]? {
        var loX = UInt32.max
        var loY = UInt32.max
        var hiX: UInt32 = 0
        var hiY: UInt32 = 0
        let x0 = rect[0], y0 = rect[1], x1 = rect[2], y1 = rect[3]
        for img in images {
            let paper = img.pixel(x: 0, y: 0).1
            for y in y0..<min(y1, img.height) {
                for x in x0..<min(x1, img.width) {
                    if img.pixel(x: x, y: y).1 != paper {
                        loX = min(loX, x)
                        loY = min(loY, y)
                        hiX = max(hiX, x + 1)
                        hiY = max(hiY, y + 1)
                    }
                }
            }
        }
        guard hiX > 0 else { return nil }
        return [
            max(x0, loX > 0 ? loX - 1 : 0),
            max(y0, loY > 0 ? loY - 1 : 0),
            min(x1, hiX + 1),
            min(y1, hiY + 1),
        ]
    }

    public static func compare(
        rune: PixelCompareImage,
        reference: PixelCompareImage,
        caseItem: PixelCompareCase,
        scale: Float
    ) -> PixelCompareStats {
        let rx = UInt32((caseItem.region[0] * scale).rounded())
        let ry = UInt32((caseItem.region[1] * scale).rounded())
        let rw = UInt32((caseItem.region[2] * scale).rounded())
        let rh = UInt32((caseItem.region[3] * scale).rounded())
        let region = [rx, ry, min(rx + rw, rune.width), min(ry + rh, rune.height)]
        let rect = caseItem.wholeRegion ? region : inkBounds(images: [rune, reference], rect: region)
        guard let rect else { return PixelCompareStats() }
        return statsIn(rune: rune, reference: reference, rect: rect)
    }

    /// Compares Rune's glyph rasterizer + blend against CoreText reference sheets (reads PNG files
    /// when `available(set:)` succeeds; falls back on macOS to live CoreText `CTFontDrawGlyphs`
    /// sheet generation when `useLiveReferenceOnMacOS` is true).
    public static func run(
        options: PixelCompareOptions,
        useLiveReferenceOnMacOS: Bool = false,
        keep: (PixelComparePair, Float, PixelCompareImage, PixelCompareImage) -> Void = { _, _, _, _ in }
    ) throws -> [PixelCompareRow] {
        var useDiskRefs = true
        do {
            try available(set: options.set)
        } catch {
            #if canImport(CoreText) && canImport(CoreGraphics)
            if !useLiveReferenceOnMacOS {
                throw error
            }
            useDiskRefs = false
            #else
            throw error
            #endif
        }

        let allCases = cases(for: options.set)
        let harness = PixelCompareHarness()
        let sheetSize = SIMD2<Float>(sheetWidth, sheetHeight(for: options.set))
        var rows: [PixelCompareRow] = []

        for scale in scales {
            for pair in options.effectiveReference.pairs {
                let reference: PixelCompareImage
                if useDiskRefs {
                    reference = try PixelCompareImage.readPNG(
                        at: referencePath(set: options.set, reference: options.effectiveReference, pair: pair, scale: scale)
                    )
                } else {
                    #if canImport(CoreText) && canImport(CoreGraphics)
                    reference = harness.renderCoreTextReference(
                        pair: pair,
                        scale: scale,
                        reference: options.effectiveReference,
                        cases: allCases,
                        size: sheetSize
                    )
                    #else
                    throw PixelCompareError.message("CoreText unavailable")
                    #endif
                }
                let rune = harness.render(
                    pair: pair,
                    scale: scale,
                    srgbBlend: options.effectiveSrgbBlend,
                    smoothing: options.effectiveSmoothing,
                    cases: allCases,
                    size: sheetSize
                )
                guard rune.width == reference.width && rune.height == reference.height else {
                    throw PixelCompareError.message("\(pair.name) \(scale)x: size mismatch \(rune.width)x\(rune.height) vs \(reference.width)x\(reference.height)")
                }
                keep(pair, scale, rune, reference)
                for c in allCases {
                    let stats = compare(rune: rune, reference: reference, caseItem: c, scale: scale)
                    rows.append(PixelCompareRow(pair: pair, scale: scale, caseItem: c, stats: stats))
                }
            }
        }
        return rows
    }

    public static func paragraphStats(rows: [PixelCompareRow], pair: String, scale: Float) -> PixelCompareStats? {
        rows.first { $0.pair.name == pair && $0.scale == scale && $0.caseItem.wholeRegion }?.stats
    }

    public static func pooledStats(rows: [PixelCompareRow], pair: String, scale: Float) -> PixelCompareStats {
        var total = PixelCompareStats()
        for r in rows where r.pair.name == pair && r.scale == scale && !r.caseItem.wholeRegion {
            total.add(r.stats)
        }
        return total
    }

    public static func table(options: PixelCompareOptions, rows: [PixelCompareRow]) -> String {
        let against = options.effectiveReference == .smoothed ? "smoothing on" : "smoothing off"
        let blend = options.effectiveSrgbBlend ? "sRGB" : "linear"
        var out = "\(options.set.displayName): Rune \(options.effectiveSmoothing.rawValue) (\(blend) blending) vs CoreText with \(against)\n"
        let head = "case                           differ       >8  max  meanabs     ink\n"
        func appendLine(_ label: String, _ s: PixelCompareStats) {
            out += String(
                format: "%-28s %7.2f%% %7.2f%% %4u %8.3f %7.3f\n",
                (label as NSString).utf8String!,
                100.0 * s.differingShare,
                100.0 * s.over8Share,
                s.max,
                s.meanAbs,
                s.inkRatio
            )
        }
        for scale in scales {
            for pair in options.effectiveReference.pairs {
                out += "\n\(pair.name) (\(pair.fg) on \(pair.bg)), \(scale)x\n"
                out += head
                for r in rows where r.pair.name == pair.name && r.scale == scale {
                    appendLine(r.caseItem.name, r.stats)
                }
            }
        }
        out += "\nsummary: paragraph (report band) and all sample rows pooled\n"
        out += head
        for scale in scales.reversed() {
            for pair in options.effectiveReference.pairs {
                if let p = paragraphStats(rows: rows, pair: pair.name, scale: scale) {
                    appendLine("\(pair.name) \(scale)x paragraph", p)
                }
                appendLine("\(pair.name) \(scale)x rows", pooledStats(rows: rows, pair: pair.name, scale: scale))
            }
        }
        return out
    }

    public static func compareShot(
        _ shot: PixelCompareImage,
        pair: PixelComparePair,
        smoothing: FontSmoothing,
        srgbBlend: Bool
    ) throws -> (offset: (Int, Int), stats: PixelCompareStats) {
        let scale: Float = 2.0
        let harness = PixelCompareHarness()
        let pCase = paragraphCase(family: .systemUI, top: 0)
        let rune = harness.render(
            pair: pair,
            scale: scale,
            srgbBlend: srgbBlend,
            smoothing: smoothing,
            cases: [pCase],
            size: SIMD2<Float>(Float(shot.width) / scale, Float(shot.height) / scale)
        )
        let all = [UInt32(0), 0, shot.width, shot.height]
        guard let bounds = inkBounds(images: [shot, shot], rect: all) else {
            throw PixelCompareError.message("no ink in screenshot")
        }
        let band = [0, bounds[1], shot.width, bounds[3]]
        var bestOffset = (0, 0)
        var bestStats: PixelCompareStats? = nil
        for dy in -120...120 {
            for dx in -4...4 {
                let s = statsIn(rune: rune, reference: shot, rect: band, shift: (dx, dy))
                if let prev = bestStats {
                    if s.meanAbs < prev.meanAbs {
                        bestOffset = (dx, dy)
                        bestStats = s
                    }
                } else {
                    bestOffset = (dx, dy)
                    bestStats = s
                }
            }
        }
        guard let bestStats else {
            throw PixelCompareError.message("nothing compared")
        }
        return (bestOffset, bestStats)
    }

    public static func heatmap(rune: PixelCompareImage, reference: PixelCompareImage) -> PixelCompareImage {
        let paperRune = Int(rune.pixel(x: 0, y: 0).1)
        let paperRef = Int(reference.pixel(x: 0, y: 0).1)
        var out = [UInt8]()
        out.reserveCapacity(rune.rgb.count)
        let count = min(rune.rgb.count, reference.rgb.count)
        for i in stride(from: 0, to: count, by: 3) {
            let a = Int(rune.rgb[i + 1])
            let b = Int(reference.rgb[i + 1])
            let ia = abs(a - paperRune)
            let ib = abs(b - paperRef)
            let k = UInt8(clamping: abs(ib - ia) * 4)
            if a == b {
                let g = UInt8(clamping: 252 - ia / 4)
                out.append(g)
                out.append(g)
                out.append(g)
            } else if ib > ia {
                out.append(255)
                out.append(255 &- k)
                out.append(255 &- k)
            } else {
                out.append(255 &- k)
                out.append(255 &- k)
                out.append(255)
            }
        }
        return PixelCompareImage(width: rune.width, height: rune.height, rgb: out)
    }
}
