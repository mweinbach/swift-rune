import Foundation
import Testing
@testable import RuneParityCLI
@testable import RuneRef

@Suite("RuneParityCLI & Upstream Parity Tests")
struct RuneParityTests {
    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rune-parity-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    #if os(macOS) || os(Linux)
    @Test("A verbose build can emit diagnostics before its first stdout line")
    func largeDiagnosticsDoNotBlockTheChild() throws {
        let output = try ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "head -c 262144 /dev/zero >&2 && printf done"]
        )
        #expect(output.exitCode == 0)
        #expect(output.stdout == "done")
        #expect(output.stderr.utf8.count == 262_144)
    }
    #endif

    @Test("RustScanner extracts pub struct, enum, trait, fn and skips comments and pub(crate)")
    func rustSymbolScanning() {
        let source = """
        // pub struct IgnoredInLineComment { a: i32 }
        /*
        pub enum IgnoredInBlockComment { A, B }
        */
        pub(crate) fn internal_helper() {}
        pub struct SpringConfig {
            pub stiffness: f32,
        }
        pub enum EaseCurve { Linear, Cubic }
        pub trait Renderable {
            fn draw(&self);
        }
        pub fn evaluate_spring(t: f32) -> f32 { t }
        pub async fn load_asset(path: &str) {}
        pub unsafe fn raw_ptr() {}
        """

        let symbols = RustScanner.scanSymbols(in: source, file: "crates/rune-motion/src/spring.rs")
        #expect(symbols.count == 6)
        #expect(symbols[0] == RustSymbol(kind: .struct, name: "SpringConfig", file: "crates/rune-motion/src/spring.rs", line: 6))
        #expect(symbols[1] == RustSymbol(kind: .enum, name: "EaseCurve", file: "crates/rune-motion/src/spring.rs", line: 9))
        #expect(symbols[2] == RustSymbol(kind: .trait, name: "Renderable", file: "crates/rune-motion/src/spring.rs", line: 10))
        #expect(symbols[3] == RustSymbol(kind: .fn, name: "evaluate_spring", file: "crates/rune-motion/src/spring.rs", line: 13))
        #expect(symbols[4] == RustSymbol(kind: .fn, name: "load_asset", file: "crates/rune-motion/src/spring.rs", line: 14))
        #expect(symbols[5] == RustSymbol(kind: .fn, name: "raw_ptr", file: "crates/rune-motion/src/spring.rs", line: 15))
    }

    @Test("ParityMapper status validates mapped crates, themes, examples, WGSL, and Swift paths")
    func statusValidation() throws {
        let root = try makeTempDir("status")
        defer { try? FileManager.default.removeItem(at: root) }

        let upstream = root.appendingPathComponent("upstream")
        let swiftRoot = root.appendingPathComponent("swift")
        let fm = FileManager.default

        // Create upstream structure
        try fm.createDirectory(at: upstream.appendingPathComponent("crates/rune-motion/src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: upstream.appendingPathComponent("themes/opencode"), withIntermediateDirectories: true)
        try fm.createDirectory(at: upstream.appendingPathComponent("examples/hello"), withIntermediateDirectories: true)
        try "pub struct Spring {}".write(to: upstream.appendingPathComponent("crates/rune-motion/src/spring.rs"), atomically: true, encoding: .utf8)
        try "@fragment fn fs_main() {}".write(to: upstream.appendingPathComponent("crates/rune-motion/src/blur.wgsl"), atomically: true, encoding: .utf8)
        try "pub fn theme() {}".write(to: upstream.appendingPathComponent("themes/opencode/lib.rs"), atomically: true, encoding: .utf8)
        try "fn main() {}".write(to: upstream.appendingPathComponent("examples/hello/main.rs"), atomically: true, encoding: .utf8)

        // Create matching Swift paths
        try fm.createDirectory(at: swiftRoot.appendingPathComponent("Sources/RuneMotion"), withIntermediateDirectories: true)
        try fm.createDirectory(at: swiftRoot.appendingPathComponent("Sources/OpenCodeTheme"), withIntermediateDirectories: true)
        try fm.createDirectory(at: swiftRoot.appendingPathComponent("Sources/Examples/RuneHello"), withIntermediateDirectories: true)
        try "// spring".write(to: swiftRoot.appendingPathComponent("Sources/RuneMotion/Spring.swift"), atomically: true, encoding: .utf8)
        try "// blur".write(to: swiftRoot.appendingPathComponent("Sources/RuneMotion/Blur.metal"), atomically: true, encoding: .utf8)

        let map = UpstreamMap(
            version: 1,
            upstreamRepo: "https://github.com/anomalyco/rune",
            crates: [
                CrateMapping(
                    upstreamPath: "crates/rune-motion",
                    swiftTarget: "RuneMotion",
                    swiftPath: "Sources/RuneMotion",
                    testTarget: "RuneMotionTests",
                    status: "done",
                    moduleMappings: [
                        ModuleMapping(upstream: "src/spring.rs", swift: ["Sources/RuneMotion/Spring.swift"]),
                        ModuleMapping(upstream: "src/blur.wgsl", swift: ["Sources/RuneMotion/Blur.metal"]),
                    ]
                )
            ],
            themes: [
                ThemeMapping(
                    upstreamPath: "themes/opencode",
                    swiftTarget: "OpenCodeTheme",
                    swiftPath: "Sources/OpenCodeTheme",
                    testTarget: "OpenCodeThemeTests"
                )
            ],
            examples: [
                ExampleMapping(
                    upstreamName: "hello",
                    upstreamPath: "examples/hello",
                    cargoPackage: "hello",
                    swiftProduct: "rune-hello",
                    swiftTarget: "RuneHello",
                    swiftPath: "Sources/Examples/RuneHello"
                )
            ]
        )

        let mapURL = root.appendingPathComponent("upstream-map.json")
        try JSONEncoder().encode(map).write(to: mapURL)

        let passReport = try ParityMapper.checkStatus(upstreamRoot: upstream, swiftRoot: swiftRoot, mapURL: mapURL)
        #expect(passReport.passed)
        #expect(passReport.totalRustFiles == 3)
        #expect(passReport.totalWgslFiles == 1)
        #expect(passReport.symbolSummary.structs == 1)
        #expect(passReport.symbolSummary.functions == 1)
        #expect(passReport.unmappedCrates.isEmpty)
        #expect(passReport.unmappedFiles.isEmpty)
        #expect(passReport.missingSwiftPaths.isEmpty)

        // Add an unmapped crate and an unmapped .rs file inside rune-motion
        try fm.createDirectory(at: upstream.appendingPathComponent("crates/rune-new"), withIntermediateDirectories: true)
        try "pub fn extra() {}".write(to: upstream.appendingPathComponent("crates/rune-motion/src/extra.rs"), atomically: true, encoding: .utf8)

        let failReport = try ParityMapper.checkStatus(upstreamRoot: upstream, swiftRoot: swiftRoot, mapURL: mapURL)
        #expect(!failReport.passed)
        #expect(failReport.unmappedCrates == ["crates/rune-new"])
        #expect(failReport.unmappedFiles == ["crates/rune-motion/src/extra.rs"])
    }

    @Test("diff-commits maps git commits since temp .upstream-sync.json to Swift targets and test commands")
    func commitDiffMappingAgainstTempGitRepo() throws {
        let root = try makeTempDir("gitdiff")
        defer { try? FileManager.default.removeItem(at: root) }

        let upstream = root.appendingPathComponent("upstream")
        try FileManager.default.createDirectory(at: upstream.appendingPathComponent("crates/rune-motion/src"), withIntermediateDirectories: true)

        func git(_ args: String...) throws -> String {
            try ProcessRunner.runChecked(executable: "/usr/bin/git", arguments: ["-C", upstream.path] + args)
        }

        _ = try git("init")
        _ = try git("config", "user.email", "parity@example.com")
        _ = try git("config", "user.name", "Parity Bot")

        let springFile = upstream.appendingPathComponent("crates/rune-motion/src/spring.rs")
        try "pub struct Spring { pub v: f32 }".write(to: springFile, atomically: true, encoding: .utf8)
        _ = try git("add", ".")
        _ = try git("commit", "-m", "initial spring")

        let syncURL = root.appendingPathComponent(".upstream-sync.json")
        let recorded = try SyncRecorder.recordSync(upstreamRoot: upstream, syncURL: syncURL)
        #expect(recorded.syncedCommitSubject == "initial spring")

        // Second commit modifies spring.rs
        try "pub struct Spring { pub v: f32, pub damping: f32 }".write(to: springFile, atomically: true, encoding: .utf8)
        _ = try git("add", ".")
        _ = try git("commit", "-m", "add damping to spring")

        let map = UpstreamMap(
            version: 1,
            upstreamRepo: "https://github.com/anomalyco/rune",
            crates: [
                CrateMapping(
                    upstreamPath: "crates/rune-motion",
                    swiftTarget: "RuneMotion",
                    swiftPath: "Sources/RuneMotion",
                    testTarget: "RuneMotionTests",
                    status: "done",
                    moduleMappings: [
                        ModuleMapping(upstream: "src/spring.rs", swift: ["Sources/RuneMotion/Spring.swift"])
                    ]
                )
            ],
            themes: nil,
            examples: []
        )
        let mapURL = root.appendingPathComponent("upstream-map.json")
        try JSONEncoder().encode(map).write(to: mapURL)

        let report = try ParityMapper.diffCommits(
            upstreamRoot: upstream,
            mapURL: mapURL,
            syncURL: syncURL,
            since: nil,
            to: "HEAD"
        )

        #expect(report.since == recorded.syncedCommit)
        #expect(report.commits.count == 1)
        #expect(report.commits[0].contains("add damping to spring"))
        #expect(report.changes.count == 1)
        #expect(report.changes[0].swiftTarget == "RuneMotion")
        #expect(report.changes[0].swiftFiles == ["Sources/RuneMotion/Spring.swift"])
        #expect(report.changes[0].testCommand == "xcrun swift test --filter RuneMotionTests")
        #expect(report.affectedTargets == ["RuneMotion"])
        #expect(report.testCommands == ["xcrun swift test --filter RuneMotionTests"])
    }

    @Test("compareTrees detects matching trees and reports node count and bbox deltas")
    func layoutTreeComparison() throws {
        let root = try makeTempDir("trees")
        defer { try? FileManager.default.removeItem(at: root) }

        let rustJSON = """
        {
          "key": "root",
          "rect": { "x": 0, "y": 0, "w": 460, "h": 300 },
          "children": [
            { "key": "sw", "rect": { "x": 210, "y": 139, "w": 40, "h": 22 } }
          ]
        }
        """
        let swiftMatchJSON = """
        {
          "key": "root",
          "rect": { "x": 0, "y": 0, "w": 460, "h": 300 },
          "children": [
            { "key": "sw", "rect": { "x": 210.5, "y": 139, "w": 40, "h": 22 } }
          ]
        }
        """
        let swiftDriftJSON = """
        {
          "key": "root",
          "rect": { "x": 0, "y": 0, "w": 460, "h": 300 },
          "children": [
            { "key": "sw", "rect": { "x": 218, "y": 139, "w": 40, "h": 22 } }
          ]
        }
        """

        let rustURL = root.appendingPathComponent("rust-tree.json")
        let matchURL = root.appendingPathComponent("swift-match.json")
        let driftURL = root.appendingPathComponent("swift-drift.json")
        try rustJSON.write(to: rustURL, atomically: true, encoding: .utf8)
        try swiftMatchJSON.write(to: matchURL, atomically: true, encoding: .utf8)
        try swiftDriftJSON.write(to: driftURL, atomically: true, encoding: .utf8)

        let passReport = try RenderComparator.compareTrees(rustTreeURL: rustURL, swiftTreeURL: matchURL, bboxTolerance: 1.0)
        #expect(passReport.passed)
        #expect(passReport.rustNodeCount == 2)
        #expect(passReport.swiftNodeCount == 2)
        #expect(passReport.maxBBoxDelta == 0.5)

        let failReport = try RenderComparator.compareTrees(rustTreeURL: rustURL, swiftTreeURL: driftURL, bboxTolerance: 1.0)
        #expect(!failReport.passed)
        #expect(failReport.mismatchCount == 1)
        #expect(failReport.mismatches[0].dx == 8.0)

        // Real `--tree` format with top-level "elements" array and "rect": [x, y, w, h]
        let realElementsJSON = """
        {
          "elements": [
            { "key": "root", "rect": [0, 0, 460, 300] },
            { "key": "sw", "rect": [210, 139, 40, 22] }
          ]
        }
        """
        let realElementsDriftJSON = """
        {
          "elements": [
            { "key": "root", "rect": [0, 0, 460, 300] },
            { "key": "sw", "rect": [215, 139, 40, 22] }
          ]
        }
        """
        let realURL1 = root.appendingPathComponent("real1.json")
        let realURL2 = root.appendingPathComponent("real2.json")
        try realElementsJSON.write(to: realURL1, atomically: true, encoding: .utf8)
        try realElementsDriftJSON.write(to: realURL2, atomically: true, encoding: .utf8)

        let realMatch = try RenderComparator.compareTrees(rustTreeURL: realURL1, swiftTreeURL: realURL1, bboxTolerance: 1.0)
        #expect(realMatch.passed)
        #expect(realMatch.rustNodeCount == 2)
        #expect(realMatch.swiftNodeCount == 2)

        let realDrift = try RenderComparator.compareTrees(rustTreeURL: realURL1, swiftTreeURL: realURL2, bboxTolerance: 1.0)
        #expect(!realDrift.passed)
        #expect(realDrift.mismatchCount == 1)
        #expect(realDrift.mismatches[0].dx == 5.0)
    }

    @Test("compareImages uses RuneRef PNG diffing and writes highlighted visual diff PNG")
    func pngDiffAndVisualOutput() throws {
        let root = try makeTempDir("pngs")
        defer { try? FileManager.default.removeItem(at: root) }

        let w = 16
        let h = 16
        var rustBytes = Array<UInt8>(repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: rustBytes.count, by: 4) {
            rustBytes[i] = 40
            rustBytes[i + 1] = 80
            rustBytes[i + 2] = 160
            rustBytes[i + 3] = 255
        }
        var swiftBytes = rustBytes
        // Modify pixel (5, 7)
        let diffIdx = (7 * w + 5) * 4
        swiftBytes[diffIdx] = 220
        swiftBytes[diffIdx + 1] = 80
        swiftBytes[diffIdx + 2] = 160
        swiftBytes[diffIdx + 3] = 255

        let rustPNG = root.appendingPathComponent("rust.png")
        let swiftIdenticalPNG = root.appendingPathComponent("swift-ok.png")
        let swiftDiffPNG = root.appendingPathComponent("swift-diff.png")
        let outDiffPNG = root.appendingPathComponent("out-diff.png")

        try Frame(width: w, height: h, rgba: rustBytes).writePNG(to: rustPNG)
        try Frame(width: w, height: h, rgba: rustBytes).writePNG(to: swiftIdenticalPNG)
        try Frame(width: w, height: h, rgba: swiftBytes).writePNG(to: swiftDiffPNG)

        let okReport = try RenderComparator.compareImages(
            rustPNG: rustPNG,
            swiftPNG: swiftIdenticalPNG,
            outDiffPNG: nil,
            tolerance: 2,
            maxDiffPct: 0.0
        )
        #expect(okReport.passed)
        #expect(okReport.differingPixels == 0)
        #expect(okReport.psnr == 999.0)

        let diffReport = try RenderComparator.compareImages(
            rustPNG: rustPNG,
            swiftPNG: swiftDiffPNG,
            outDiffPNG: outDiffPNG,
            tolerance: 2,
            maxDiffPct: 0.0
        )
        #expect(!diffReport.passed)
        #expect(diffReport.differingPixels == 1)
        #expect(diffReport.maxChannelDelta == 180)
        #expect(diffReport.worstX == 5)
        #expect(diffReport.worstY == 7)
        #expect(FileManager.default.fileExists(atPath: outDiffPNG.path))

        let diffFrame = try Frame.fromPNG(data: Data(contentsOf: outDiffPNG))
        #expect(diffFrame.width == w)
        #expect(diffFrame.height == h)
        let highlighted = diffFrame.pixel(x: 5, y: 7)
        #expect(highlighted.x > 150) // magenta-red highlight
    }

    @Test("CLI help and invalid subcommand exit codes")
    func cliEntrypoint() {
        #expect(RuneParityCLI.run(arguments: ["--help"]) == 0)
        #expect(RuneParityCLI.run(arguments: ["status", "--help"]) == 0)
        #expect(RuneParityCLI.run(arguments: ["unknown-cmd"]) == 2)
        #expect(RuneParityCLI.run(arguments: ["status"]) == 1)
    }

    @Test("fetch_upstream.sh fetches local bare git repo on dev branch without network")
    func fetchUpstreamScriptAgainstLocalBareRepo() throws {
        let root = try makeTempDir("fetch-upstream")
        defer { try? FileManager.default.removeItem(at: root) }

        let bareRepo = root.appendingPathComponent("bare.git")
        let seedRepo = root.appendingPathComponent("seed")
        let upstreamClone = root.appendingPathComponent("upstream")

        func git(_ args: [String]) throws -> String {
            try ProcessRunner.runChecked(executable: "/usr/bin/git", arguments: args)
        }

        _ = try git(["init", "--bare", "-b", "dev", bareRepo.path])
        _ = try git(["clone", bareRepo.path, seedRepo.path])
        _ = try git(["-C", seedRepo.path, "checkout", "-B", "dev"])
        _ = try git(["-C", seedRepo.path, "config", "user.email", "parity@example.com"])
        _ = try git(["-C", seedRepo.path, "config", "user.name", "Parity Bot"])

        let markerFile = seedRepo.appendingPathComponent("README.md")
        try "initial upstream\n".write(to: markerFile, atomically: true, encoding: .utf8)
        _ = try git(["-C", seedRepo.path, "add", "."])
        _ = try git(["-C", seedRepo.path, "commit", "-m", "initial dev commit"])
        _ = try git(["-C", seedRepo.path, "push", "-u", "origin", "dev"])
        _ = try git(["-C", bareRepo.path, "symbolic-ref", "HEAD", "refs/heads/dev"])
        let firstSHA = try git(["-C", seedRepo.path, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try git(["clone", "--branch", "dev", bareRepo.path, upstreamClone.path])

        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".agents/skills/upstream-rune-sync/scripts/fetch_upstream.sh")

        let syncFileURL = root.appendingPathComponent(".upstream-sync.json")
        let syncJSON = """
        {
          "upstreamRepo": "\(bareRepo.path)",
          "syncedCommit": "\(firstSHA)",
          "syncedCommitDate": "2026-11-12T00:00:00Z",
          "syncedCommitSubject": "initial dev commit"
        }
        """
        try syncJSON.write(to: syncFileURL, atomically: true, encoding: .utf8)

        func runFetch(_ args: [String]) throws -> ProcessRunner.Output {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [scriptURL.path] + args
            var env = ProcessInfo.processInfo.environment
            env["SYNC_FILE"] = syncFileURL.path
            proc.environment = env
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            try proc.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return ProcessRunner.Output(
                exitCode: proc.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        }

        // 1. Local --upstream check without fetch reports UP TO DATE at firstSHA.
        let initialOut = try runFetch(["--upstream", upstreamClone.path])
        #expect(initialOut.exitCode == 0)
        #expect(initialOut.stdout.contains("Upstream HEAD: \(firstSHA)"))
        #expect(initialOut.stdout.contains("UP TO DATE (0 commits ahead)"))

        // 2. Push a new commit to bare repo on dev, then run --upstream ... --fetch --branch dev.
        try "second upstream\n".write(to: markerFile, atomically: true, encoding: .utf8)
        _ = try git(["-C", seedRepo.path, "add", "."])
        _ = try git(["-C", seedRepo.path, "commit", "-m", "second dev commit"])
        _ = try git(["-C", seedRepo.path, "push", "origin", "dev"])
        let secondSHA = try git(["-C", seedRepo.path, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)

        let fetchOut = try runFetch(["--upstream", upstreamClone.path, "--fetch", "--branch", "dev"])
        #expect(fetchOut.exitCode == 0)
        #expect(fetchOut.stdout.contains("Upstream HEAD: \(secondSHA)"))
        #expect(fetchOut.stdout.contains("1 commit(s) ahead of syncedCommit"))
        #expect(fetchOut.stdout.contains("second dev commit"))

        // 3. Invalid --upstream path fails cleanly with exit code 1.
        let missingOut = try runFetch(["--upstream", root.appendingPathComponent("missing").path])
        #expect(missingOut.exitCode == 1)
        #expect(missingOut.stderr.contains("not a git repository"))
    }
}
