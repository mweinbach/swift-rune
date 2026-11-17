import Foundation
import Rune

/// Generates the sheets and glyph metadata consumed by upstream's text_quality tools.
/// swift run rune-text-quality OUT [FONT FAMILY [auto|on|off EMBOLDEN]]
@main
enum RuneTextQualityApp {
    static let samples = [
        "Hamburgefontsiv 0123456789",
        "The quick brown fox jumps over the lazy dog.",
        "Settings / Model / Working / Copy",
        "Il1 O0 rn m ffi fi fl -> != <=",
        "lHEximnoAVWgjpq",
    ]

    struct Experiment {
        let hint: String
        let embolden: Float
    }

    struct Row: Encodable {
        let size, top, advance: Float
        let text: String
        let glyphs: [TextQualityGlyph]
        let opsz: Float?

        enum CodingKeys: String, CodingKey { case size, top, advance, text, glyphs, opsz }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(size, forKey: .size)
            try c.encode(top, forKey: .top)
            try c.encode(Double(advance), forKey: .advance)
            try c.encode(text, forKey: .text)
            try c.encode(glyphs, forKey: .glyphs)
            try c.encode(opsz, forKey: .opsz)
        }
    }

    struct Sheet: Encodable {
        let font, family: String
        let scale: Float
        let width, height, fg, bg: Int
        let gamma: Float = 1
        let rows: [Row]
    }

    struct Phase: Encodable {
        let x: Float
        let instances: Int
    }

    /// Experimental masks live outside the production atlas. The Swift and Rust examples both
    /// pack a fresh mask for each positioned glyph, even when the same face and phase repeat.
    struct ExperimentAtlas {
        var page = R8Atlas(width: GlyphAtlas.atlasSize, height: GlyphAtlas.atlasSize)
        var x = 1, y = 1, rowHeight = 0

        mutating func pack(_ mask: TextQualityMask) throws -> RenderInstance {
            if x + mask.width + 1 >= page.width {
                x = 1
                y += rowHeight + 1
                rowHeight = 0
            }
            guard mask.width < page.width - 2, y + mask.height + 1 < page.height else {
                throw PixelCompareError.message("Experimental glyph atlas is full")
            }
            for row in 0..<mask.height {
                let src = row * mask.width
                let dst = (y + row) * page.width + x
                page.texels.replaceSubrange(dst..<(dst + mask.width), with: mask.bytes[src..<(src + mask.width)])
            }
            let instance = RenderInstance(rect: SIMD4(Float(mask.x), Float(mask.y), Float(mask.width), Float(mask.height)),
                fill: SIMD4(repeating: 1), params: SIMD4(0, KIND_GLYPH, 0, 1), uv: SIMD4(Float(x), Float(y), 0, 0))
            x += mask.width + 1
            rowHeight = max(rowHeight, mask.height)
            return instance
        }
    }

    static func run(_ args: [String]) throws {
        let usage = "Usage: rune-text-quality OUT [FONT [FAMILY [auto|on|off EMBOLDEN]]]"
        if args == ["--help"] || args == ["-h"] {
            print("""
            \(usage)
            Writes light/dark GPU sheets, raw coverage, fractional phase sweeps, and glyph geometry at 1× and 2×.
            FONT defaults to bundled Inter Regular. FAMILY defaults to Inter.
            RUNE_TEXT_OPSZ accepts point or legacy; the default uses automatic optical sizing.
            HINT and EMBOLDEN select an independent native raster experiment. Strength is in device pixels.
            """)
            return
        }
        guard let output = args.first, [1, 2, 3, 5].contains(args.count) else {
            throw PixelCompareError.message(usage)
        }
        let file = args.count > 1 ? URL(fileURLWithPath: args[1]) : DefaultFonts.fontURL(named: "Inter-Regular")
        guard let file = file?.standardizedFileURL.resolvingSymlinksInPath(),
              FileManager.default.isReadableFile(atPath: file.path) else {
            throw PixelCompareError.message("Cannot read the requested font")
        }
        let family = args.count > 2 ? args[2] : "Inter"
        let experiment: Experiment?
        if args.count == 5 {
            guard ["auto", "on", "off"].contains(args[3]), let strength = Float(args[4]), strength.isFinite else {
                throw PixelCompareError.message(usage)
            }
            experiment = Experiment(hint: args[3], embolden: strength)
        } else {
            experiment = nil
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let renderer = try OffscreenGPURenderer()
        let opsz = ProcessInfo.processInfo.environment["RUNE_TEXT_OPSZ"]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        for scale: Float in [1, 2] {
            let system = TextSystem()
            try system.setQualityFont(file: file, family: family)
            var packing: ExperimentAtlas? = experiment.map { _ in ExperimentAtlas() }
            func draw(_ shaped: ShapedText, at origin: SIMD2<Float>) throws -> [RenderInstance] {
                guard let experiment else {
                    return shaped.qualityInstances(origin: origin, scale: scale, atlas: system.glyphAtlas)
                }
                let hint = experiment.hint == "on" || (experiment.hint == "auto" && scale < 1.5)
                #if canImport(CoreText)
                let masks = shaped.qualityAppleExperiment(origin: origin, scale: scale, hint: hint, embolden: experiment.embolden)
                #elseif os(Linux) || os(Windows)
                let masks = try shaped.qualityDesktopExperiment(origin: origin, scale: scale, hint: hint, embolden: experiment.embolden)
                #else
                throw PixelCompareError.message("Experimental glyph masks require a desktop native rasterizer")
                #endif
                #if canImport(CoreText) || os(Linux) || os(Windows)
                return try masks.map { try packing!.pack($0) }
                #endif
            }
            func pages() -> [R8Atlas] { packing.map { [$0.page] } ?? system.glyphAtlas.atlases }

            let w = 800 * Int(scale), h = 1100 * Int(scale)
            var rows = [Row](), quads = [RenderInstance]()
            for size: Float in [11, 12, 13, 15, 24] {
                var style = TextStyle(size: size, weight: 400)
                if opsz == "point" { style.opticalSize = .fixed(size) }
                if opsz == "legacy" { style.opticalSize = .fontDefault }
                for sample in samples {
                    let origin = SIMD2(16 * scale, Float(8 + 42 * rows.count) * scale)
                    let shaped = system.shape(text: sample, style: style, maxWidth: nil, pixelScale: scale)
                    quads += try draw(shaped, at: origin)
                    rows.append(try Row(size: size, top: origin.y, advance: shaped.qualityAdvance, text: sample,
                        glyphs: shaped.qualityGlyphs(origin: origin, scale: scale), opsz: opsz == "legacy" ? nil : size))
                }
            }
            let suffix = "\(Int(scale))x"
            let sheetPages = pages()
            let revision = UInt64(scale) * 2
            for dark in [false, true] {
                let name = "\(dark ? "dark" : "light")-\(suffix)"
                let fg = dark ? 238 : 24, bg = dark ? 24 : 238
                let ink = linearGrey(fg)
                let tinted = quads.map { item in
                    var copy = item
                    copy.fill = ink
                    return copy
                }
                let frame = RenderFrame(width: w, height: h, clearColor: linearGrey(bg),
                    glyphs: sheetPages[0], glyphPages: sheetPages, glyphGeneration: revision, instances: tinted)
                try renderer.renderOffscreen(frame).writePNG(to: directory.appendingPathComponent("rune-\(name).png"))
                let sheet = Sheet(font: file.path, family: family, scale: scale, width: w, height: h, fg: fg, bg: bg, rows: rows)
                try encoder.encode(sheet).write(to: directory.appendingPathComponent("\(name).json"))
            }
            try coverage(width: w, height: h, quads: quads, pages: sheetPages)
                .writePNG(to: directory.appendingPathComponent("coverage-\(suffix).png"))

            let sweep = system.shape(text: "lHEximno", style: TextStyle(size: 13, weight: 400), maxWidth: nil, pixelScale: scale)
            var instances = [RenderInstance](), phases = [Phase]()
            for frame in 0..<128 {
                let x = 16 + Float(frame) / 64
                let line = try draw(sweep, at: SIMD2(x, Float(frame * 40 + 2)))
                instances += line
                phases.append(Phase(x: x, instances: line.count))
            }
            let phasePages = pages()
            let frame = RenderFrame(width: 320, height: 128 * 40, glyphs: phasePages[0],
                glyphPages: phasePages, glyphGeneration: revision + 1, instances: instances)
            try renderer.renderOffscreen(frame).writePNG(to: directory.appendingPathComponent("phases-\(suffix).png"))
            try encoder.encode(phases).write(to: directory.appendingPathComponent("phases-\(suffix).json"))
        }
    }

    static func linearGrey(_ value: Int) -> SIMD4<Float> {
        let channel = RefShader.srgbToLinear(Float(value) / 255)
        return SIMD4(channel, channel, channel, 1)
    }

    /// Copy even the transparent texels, in draw order, like text_quality.rs.
    static func coverage(width: Int, height: Int, quads: [RenderInstance], pages: [R8Atlas]) -> Frame {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        for q in quads {
            let page = pages[Int(q.params.z)]
            let dx = Int(q.rect.x), dy = Int(q.rect.y)
            let u = Int(q.uv.x), v = Int(q.uv.y)
            let x0 = max(0, -dx), x1 = min(Int(q.rect.z), width - dx, page.width - u)
            let y0 = max(0, -dy), y1 = min(Int(q.rect.w), height - dy, page.height - v)
            guard x0 < x1, y0 < y1 else { continue }
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let a = page.texels[(v + y) * page.width + u + x]
                    let dst = ((dy + y) * width + dx + x) * 4
                    pixels[dst] = a
                    pixels[dst + 1] = a
                    pixels[dst + 2] = a
                }
            }
        }
        return Frame(width: width, height: height, rgba: pixels)
    }

    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
