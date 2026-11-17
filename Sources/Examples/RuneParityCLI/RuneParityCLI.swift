import Foundation

@main
public struct RuneParityCLI {
    public static let defaultMapRelativePath = ".agents/skills/upstream-rune-sync/references/upstream-map.json"
    public static let defaultSyncRelativePath = ".upstream-sync.json"

    public static func main() {
        let exitCode = run(arguments: Array(CommandLine.arguments.dropFirst()))
        if exitCode != 0 {
            exit(exitCode)
        }
    }

    public static func run(arguments: [String]) -> Int32 {
        guard let first = arguments.first else {
            printTopLevelHelp()
            return 0
        }

        if first == "--help" || first == "-h" || first == "help" {
            printTopLevelHelp()
            return 0
        }

        let subcommand = first
        let rest = Array(arguments.dropFirst())
        if rest.contains("--help") || rest.contains("-h") {
            printSubcommandHelp(subcommand)
            return 0
        }

        do {
            switch subcommand {
            case "status":
                return try handleStatus(rest)
            case "diff-commits":
                return try handleDiffCommits(rest)
            case "compare-renders":
                return try handleCompareRenders(rest)
            case "record-sync":
                return try handleRecordSync(rest)
            default:
                FileHandle.standardError.write(Data("error: unknown subcommand '\(subcommand)'\n\n".utf8))
                printTopLevelHelp()
                return 2
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
    }

    // MARK: - Subcommands

    private static func handleStatus(_ args: [String]) throws -> Int32 {
        let parsed = try parseFlags(args)
        guard let upstream = parsed.values["--upstream"] else {
            throw ParityError.invalidArguments("status requires --upstream <path>")
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let swiftRoot = parsed.values["--swift-root"].map { URL(fileURLWithPath: $0) } ?? cwd
        let mapURL = parsed.values["--map"].map { URL(fileURLWithPath: $0) }
            ?? swiftRoot.appendingPathComponent(defaultMapRelativePath)

        let report = try ParityMapper.checkStatus(
            upstreamRoot: URL(fileURLWithPath: upstream),
            swiftRoot: swiftRoot,
            mapURL: mapURL
        )

        if parsed.flags.contains("--json") {
            try printJSON(report)
        } else {
            printStatusHuman(report)
        }
        return report.passed ? 0 : 1
    }

    private static func handleDiffCommits(_ args: [String]) throws -> Int32 {
        let parsed = try parseFlags(args)
        guard let upstream = parsed.values["--upstream"] else {
            throw ParityError.invalidArguments("diff-commits requires --upstream <path>")
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let swiftRoot = parsed.values["--swift-root"].map { URL(fileURLWithPath: $0) } ?? cwd
        let mapURL = parsed.values["--map"].map { URL(fileURLWithPath: $0) }
            ?? swiftRoot.appendingPathComponent(defaultMapRelativePath)
        let syncURL = parsed.values["--sync"].map { URL(fileURLWithPath: $0) }
            ?? swiftRoot.appendingPathComponent(defaultSyncRelativePath)

        let since = parsed.values["--since"]
        let to = parsed.values["--to"] ?? "HEAD"

        let report = try ParityMapper.diffCommits(
            upstreamRoot: URL(fileURLWithPath: upstream),
            mapURL: mapURL,
            syncURL: syncURL,
            since: since,
            to: to
        )

        if parsed.flags.contains("--json") {
            try printJSON(report)
        } else {
            printDiffCommitsHuman(report)
        }
        return 0
    }

    private static func handleCompareRenders(_ args: [String]) throws -> Int32 {
        let parsed = try parseFlags(args)
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let swiftRoot = parsed.values["--swift-root"].map { URL(fileURLWithPath: $0) } ?? cwd
        let mapURL = parsed.values["--map"].map { URL(fileURLWithPath: $0) }
            ?? swiftRoot.appendingPathComponent(defaultMapRelativePath)

        let tolerance = try parsed.values["--tolerance"].map { raw -> Int in
            guard let v = Int(raw), (0...255).contains(v) else {
                throw ParityError.invalidArguments("--tolerance must be an integer in 0...255")
            }
            return v
        } ?? 2

        let maxDiffPct = try parsed.values["--max-diff-pct"].map { raw -> Double in
            guard let v = Double(raw), v >= 0.0 else {
                throw ParityError.invalidArguments("--max-diff-pct must be >= 0")
            }
            return v
        } ?? 0.0

        let outDiffURL = parsed.values["--out-diff"].map { URL(fileURLWithPath: $0) }
        let scene = parsed.values["--scene"]
        let size = parsed.values["--size"]

        let report: CompareRendersReport
        if let upstream = parsed.values["--upstream"], let example = parsed.values["--example"] {
            report = try RenderComparator.runDifferentialExample(
                upstreamRoot: URL(fileURLWithPath: upstream),
                swiftRoot: swiftRoot,
                mapURL: mapURL,
                exampleName: example,
                scene: scene,
                size: size,
                outDiffPNG: outDiffURL,
                tolerance: tolerance,
                maxDiffPct: maxDiffPct
            )
        } else {
            let rustPNG = parsed.values["--rust-png"].map { URL(fileURLWithPath: $0) }
            let swiftPNG = parsed.values["--swift-png"].map { URL(fileURLWithPath: $0) }
            let rustTree = parsed.values["--rust-tree"].map { URL(fileURLWithPath: $0) }
            let swiftTree = parsed.values["--swift-tree"].map { URL(fileURLWithPath: $0) }

            let hasPNGPair = (rustPNG != nil && swiftPNG != nil)
            let hasTreePair = (rustTree != nil && swiftTree != nil)

            guard hasPNGPair || hasTreePair else {
                throw ParityError.invalidArguments(
                    "compare-renders requires (--upstream <path> --example <name>) or (--rust-png <p> --swift-png <p>) / (--rust-tree <p> --swift-tree <p>)"
                )
            }

            let imgDiff: ImageDiffReport?
            if let rPNG = rustPNG, let sPNG = swiftPNG {
                imgDiff = try RenderComparator.compareImages(
                    rustPNG: rPNG,
                    swiftPNG: sPNG,
                    outDiffPNG: outDiffURL,
                    tolerance: tolerance,
                    maxDiffPct: maxDiffPct
                )
            } else {
                imgDiff = nil
            }

            let treeDiff: TreeDiffReport?
            if let rTree = rustTree, let sTree = swiftTree {
                treeDiff = try RenderComparator.compareTrees(rustTreeURL: rTree, swiftTreeURL: sTree)
            } else {
                treeDiff = nil
            }

            let passed = (imgDiff?.passed ?? true) && (treeDiff?.passed ?? true)
            report = CompareRendersReport(
                example: parsed.values["--example"],
                scene: scene,
                imageDiff: imgDiff,
                treeDiff: treeDiff,
                passed: passed
            )
        }

        if parsed.flags.contains("--json") {
            try printJSON(report)
        } else {
            printCompareRendersHuman(report)
        }

        return report.passed ? 0 : 1
    }

    private static func handleRecordSync(_ args: [String]) throws -> Int32 {
        let parsed = try parseFlags(args)
        guard let upstream = parsed.values["--upstream"] else {
            throw ParityError.invalidArguments("record-sync requires --upstream <path>")
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let syncURL = parsed.values["--sync"].map { URL(fileURLWithPath: $0) }
            ?? cwd.appendingPathComponent(defaultSyncRelativePath)

        let state = try SyncRecorder.recordSync(
            upstreamRoot: URL(fileURLWithPath: upstream),
            syncURL: syncURL
        )

        if parsed.flags.contains("--json") {
            try printJSON(state)
        } else {
            print("Recorded upstream sync -> \(syncURL.path)")
            print("  commit : \(state.syncedCommit)")
            print("  date   : \(state.syncedCommitDate)")
            print("  subject: \(state.syncedCommitSubject)")
            print("  synced : \(state.syncedAt)")
        }
        return 0
    }

    // MARK: - Output Formatting

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }

    private static func printStatusHuman(_ r: ParityStatusReport) {
        print("rune-parity status")
        print("  upstream : \(r.upstreamPath)")
        print("  map      : \(r.mapPath)")
        print("  mapped   : \(r.mappedCrates) crates, \(r.mappedThemes) themes, \(r.mappedExamples) examples")
        print("  scanned  : \(r.totalRustFiles) .rs files, \(r.totalWgslFiles) .wgsl files")
        print("  pub syms : \(r.symbolSummary.total) (struct: \(r.symbolSummary.structs), enum: \(r.symbolSummary.enums), trait: \(r.symbolSummary.traits), fn: \(r.symbolSummary.functions))")
        if !r.unmappedCrates.isEmpty {
            print("  unmapped crates  : \(r.unmappedCrates.joined(separator: ", "))")
        }
        if !r.unmappedThemes.isEmpty {
            print("  unmapped themes  : \(r.unmappedThemes.joined(separator: ", "))")
        }
        if !r.unmappedExamples.isEmpty {
            print("  unmapped examples: \(r.unmappedExamples.joined(separator: ", "))")
        }
        if !r.unmappedFiles.isEmpty {
            print("  unmapped files   : \(r.unmappedFiles.joined(separator: ", "))")
        }
        if !r.missingSwiftPaths.isEmpty {
            print("  missing swift    : \(r.missingSwiftPaths.joined(separator: ", "))")
        }
        print("  result   : \(r.passed ? "PASS" : "FAIL")")
    }

    private static func printDiffCommitsHuman(_ r: CommitDiffReport) {
        print("rune-parity diff-commits (\(r.since)..\(r.to))")
        print("  commits (\(r.commits.count)):")
        for c in r.commits {
            print("    - \(c)")
        }
        print("  changed files (\(r.changes.count)):")
        for ch in r.changes {
            let target = ch.swiftTarget ?? "<unmapped>"
            let files = ch.swiftFiles.isEmpty ? "-" : ch.swiftFiles.joined(separator: ", ")
            print("    [\(ch.gitStatus)] \(ch.upstreamFile) -> \(target) (\(files))")
        }
        if !r.affectedTargets.isEmpty {
            print("  porting plan — affected targets: \(r.affectedTargets.joined(separator: ", "))")
        }
        if !r.testCommands.isEmpty {
            print("  recommended tests:")
            for cmd in r.testCommands {
                print("    \(cmd)")
            }
        }
        if !r.unmappedChanges.isEmpty {
            print("  unmapped upstream changes:")
            for f in r.unmappedChanges {
                print("    ! \(f)")
            }
        }
    }

    private static func printCompareRendersHuman(_ r: CompareRendersReport) {
        print("rune-parity compare-renders\(r.example.map { " (\($0))" } ?? "")")
        if let img = r.imageDiff {
            print("  image : \(img.rustWidth)x\(img.rustHeight) vs \(img.swiftWidth)x\(img.swiftHeight)")
            print("  diff  : \(img.differingPixels)/\(img.totalPixels) px (\(String(format: "%.4f", img.diffPct))%), maxDelta=\(img.maxChannelDelta), PSNR=\(String(format: "%.2f", img.psnr)) dB")
            if let wx = img.worstX, let wy = img.worstY {
                print("  worst : (\(wx), \(wy)) rust=\(img.worstRustRGBA ?? []) swift=\(img.worstSwiftRGBA ?? [])")
            }
            if let out = img.outDiffPath {
                print("  diffPNG: \(out)")
            }
        }
        if let tree = r.treeDiff {
            print("  tree  : rust=\(tree.rustNodeCount) nodes, swift=\(tree.swiftNodeCount) nodes, maxBBoxDelta=\(String(format: "%.2f", tree.maxBBoxDelta)), mismatches=\(tree.mismatchCount)")
        }
        print("  result: \(r.passed ? "PASS" : "FAIL")")
    }

    // MARK: - Argument Parsing & Help

    private struct ParsedFlags {
        var values: [String: String] = [:]
        var flags: Set<String> = []
    }

    private static func parseFlags(_ args: [String]) throws -> ParsedFlags {
        var out = ParsedFlags()
        let booleanFlags: Set<String> = ["--json", "--help", "-h"]
        var i = 0
        while i < args.count {
            let arg = args[i]
            if booleanFlags.contains(arg) {
                out.flags.insert(arg)
                i += 1
            } else if arg.hasPrefix("--") {
                guard i + 1 < args.count else {
                    throw ParityError.invalidArguments("Missing value for \(arg)")
                }
                out.values[arg] = args[i + 1]
                i += 2
            } else {
                throw ParityError.invalidArguments("Unexpected argument '\(arg)'")
            }
        }
        return out
    }

    private static func printTopLevelHelp() {
        print("""
        rune-parity — Upstream Rust vs Swift differential & sync parity CLI

        USAGE:
          rune-parity <subcommand> [options]

        SUBCOMMANDS:
          status           Verify upstream crates/files/themes/examples are mapped and exist in Swift
          diff-commits     Map upstream git commits since last sync to Swift targets & test commands
          compare-renders  Run differential PNG & layout-tree comparison (Rust vs Swift)
          record-sync      Record upstream HEAD commit metadata into .upstream-sync.json

        GLOBAL OPTIONS:
          --json           Emit machine-readable JSON output
          --help, -h       Show help
        """)
    }

    private static func printSubcommandHelp(_ subcommand: String) {
        switch subcommand {
        case "status":
            print("""
            USAGE: rune-parity status --upstream <path> [--map <path>] [--swift-root <path>] [--json]
            """)
        case "diff-commits":
            print("""
            USAGE: rune-parity diff-commits --upstream <path> [--since <sha>] [--to <ref>] [--map <path>] [--sync <path>] [--json]
            """)
        case "compare-renders":
            print("""
            USAGE: rune-parity compare-renders [--upstream <path> --example <name> | --rust-png <p> --swift-png <p>] [--rust-tree <p> --swift-tree <p>] [--scene <name>] [--size <WxH>] [--out-diff <diff.png>] [--tolerance <0..255>] [--max-diff-pct <double>] [--json]
            """)
        case "record-sync":
            print("""
            USAGE: rune-parity record-sync --upstream <path> [--sync <path>] [--json]
            """)
        default:
            printTopLevelHelp()
        }
    }
}
