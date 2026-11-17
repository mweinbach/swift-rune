import Foundation
import Rune

@main
public enum RuneCoretextCompareApp {
    public struct CLIOptions: Sendable, Equatable {
        public enum Command: Sendable, Equatable {
            case compare
            case shot(String, pairName: String)
            case exportDir(String)
            case packDir(String)
        }

        public var command: Command = .compare
        public var set: PixelCompareFontSet = .inter
        public var smoothing: FontSmoothing? = nil
        public var srgbBlend: Bool? = nil
        public var reference: PixelCompareReference? = nil
        public var outDir: String? = nil

        public init(
            command: Command = .compare,
            set: PixelCompareFontSet = .inter,
            smoothing: FontSmoothing? = nil,
            srgbBlend: Bool? = nil,
            reference: PixelCompareReference? = nil,
            outDir: String? = nil
        ) {
            self.command = command
            self.set = set
            self.smoothing = smoothing
            self.srgbBlend = srgbBlend
            self.reference = reference
            self.outDir = outDir
        }

        public var pixelCompareOptions: PixelCompareOptions {
            PixelCompareOptions(set: set, smoothing: smoothing, srgbBlend: srgbBlend, reference: reference)
        }
    }

    public static func parseCLI(_ args: [String]) throws -> CLIOptions {
        func flag(_ name: String) -> String? {
            guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
            return args[idx + 1]
        }

        var opts = CLIOptions()
        if let rawSmooth = flag("--smoothing") {
            switch rawSmooth {
            case "on": opts.smoothing = .on
            case "off": opts.smoothing = .off
            default: throw PixelCompareError.message("--smoothing \(rawSmooth): on or off")
            }
        }
        if let rawBlend = flag("--blend") {
            switch rawBlend {
            case "srgb": opts.srgbBlend = true
            case "linear": opts.srgbBlend = false
            default: throw PixelCompareError.message("--blend \(rawBlend): srgb or linear")
            }
        }

        switch args.first {
        case "export":
            guard args.count >= 2 else { throw PixelCompareError.message("export DIR") }
            opts.command = .exportDir(args[1])
            return opts
        case "pack":
            guard args.count >= 2 else { throw PixelCompareError.message("pack DIR") }
            opts.command = .packDir(args[1])
            return opts
        case "shot":
            guard args.count >= 2 else { throw PixelCompareError.message("shot SHOT.png") }
            opts.command = .shot(args[1], pairName: flag("--pair") ?? "light")
            return opts
        default:
            break
        }

        switch flag("--set") {
        case nil, "inter": opts.set = .inter
        case "sf": opts.set = .sf
        case "mono": opts.set = .mono
        case let other?: throw PixelCompareError.message("--set \(other): inter, sf or mono")
        }

        if let against = flag("--against") {
            opts.reference = (against == "unsmoothed") ? .unsmoothed : .smoothed
        }
        opts.outDir = flag("--out")
        return opts
    }

    public static func execute(_ opts: CLIOptions, useLiveReferenceOnMacOS: Bool = true) throws -> String {
        switch opts.command {
        case .exportDir(let dir):
            return try runExport(to: URL(fileURLWithPath: dir))
        case .packDir(let dir):
            return try runPack(from: URL(fileURLWithPath: dir))
        case .shot(let shotPath, let pairName):
            let shot = try PixelCompareImage.readPNG(at: URL(fileURLWithPath: shotPath))
            guard let pair = PixelCompare.pairs.first(where: { $0.name == pairName }) else {
                throw PixelCompareError.message("--pair: light, dark, white or blue")
            }
            let mode = opts.smoothing ?? .off
            let (offset, s) = try PixelCompare.compareShot(
                shot,
                pair: pair,
                smoothing: mode,
                srgbBlend: opts.srgbBlend ?? true
            )
            return String(
                format: "%@ vs %@: shift (%d, %d) px  differ %.2f%%  >8 %.2f%%  max %u  meanabs %.3f  ink %.3f",
                mode.rawValue,
                shotPath,
                offset.0,
                offset.1,
                100.0 * s.differingShare,
                100.0 * s.over8Share,
                s.max,
                s.meanAbs,
                s.inkRatio
            )
        case .compare:
            let pcOpts = opts.pixelCompareOptions
            let outURL = opts.outDir.map { URL(fileURLWithPath: $0) }
            let rows = try PixelCompare.run(options: pcOpts, useLiveReferenceOnMacOS: useLiveReferenceOnMacOS) { pair, scale, rune, reference in
                guard let dir = outURL else { return }
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? rune.writePNG(to: dir.appendingPathComponent("rune-\(pair.name)-\(scale)x.png"))
                try? PixelCompare.heatmap(rune: rune, reference: reference)
                    .writePNG(to: dir.appendingPathComponent("heat-\(pair.name)-\(scale)x.png"))
            }
            return PixelCompare.table(options: pcOpts, rows: rows)
        }
    }

    public static func runExport(to dir: URL) throws -> String {
        var exported: [String] = []
        for (set, name) in [(PixelCompareFontSet.inter, "inter"), (.sf, "sf"), (.mono, "mono")] {
            let sub = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            for scale in PixelCompare.scales {
                let json = PixelCompare.exportJSON(for: set, scale: scale)
                let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
                let fileURL = sub.appendingPathComponent("cases-\(scale)x.json")
                try data.write(to: fileURL)
                exported.append(fileURL.path)
            }
        }
        return exported.joined(separator: "\n")
    }

    public static func runPack(from dir: URL) throws -> String {
        var packed: [String] = []
        for (set, name) in [(PixelCompareFontSet.inter, "inter"), (.sf, "sf"), (.mono, "mono")] {
            let sub = dir.appendingPathComponent(name)
            guard let entries = try? FileManager.default.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil) else {
                continue
            }
            try FileManager.default.createDirectory(at: set.dir, withIntermediateDirectories: true)
            for path in entries where path.pathExtension.lowercased() == "png" {
                let image = try PixelCompareImage.readPNG(at: path)
                let dest = set.dir.appendingPathComponent(path.lastPathComponent)
                try image.writeGreenPNG(to: dest)
                packed.append(dest.path)
            }
            let layoutPath = set.dir.appendingPathComponent("layout.txt")
            try Data(PixelCompare.layoutFile(for: set).utf8).write(to: layoutPath)
        }
        return packed.joined(separator: "\n")
    }

    /// Headless tooling helper so `--tree` / `--snap` inspection works without launching a window.
    public static func makeSummaryApp(reportText: String? = nil) -> App<String> {
        let summary = reportText ?? ((try? execute(CLIOptions())) ?? "coretext_compare: unavailable")
        return App<String>(
            "CoreText Compare",
            size: Vec2(720, 480),
            init: { summary },
            view: { s, _ in
                col()
                    .key("coretext-compare")
                    .sizeFull()
                    .p(16)
                    .bg(Color(r: 0.04, g: 0.05, b: 0.07, a: 1.0))
                    .child(text(s).font(TextStyle(size: 11.0, weight: 400.0, family: .monospace)).color(.white))
            }
        )
    }

    @MainActor
    public static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let parsed = ToolingArgs.parse(args)
        if parsed.isHeadlessRequested {
            try RuneApp.run(makeSummaryApp(), arguments: args)
            return
        }
        do {
            let opts = try parseCLI(args)
            let output = try execute(opts, useLiveReferenceOnMacOS: true)
            if !output.isEmpty {
                print(output)
            }
        } catch {
            RuneStandardIO.error("\(error)\n")
            Foundation.exit(1)
        }
    }
}
