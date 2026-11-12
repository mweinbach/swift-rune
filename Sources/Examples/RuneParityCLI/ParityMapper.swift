import Foundation

/// Helper for running subprocesses (`git`, `cargo`, `xcrun`) and capturing stdout/stderr.
public enum ProcessRunner {
    public struct Output: Sendable, Equatable {
        public var exitCode: Int32
        public var stdout: String
        public var stderr: String
    }

    public static func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> Output {
        #if os(macOS) || os(Linux) || os(Windows)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        if let dir = currentDirectory {
            proc.currentDirectoryURL = dir
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        return Output(
            exitCode: proc.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
        #else
        let cmd = ([executable] + arguments).joined(separator: " ")
        throw ParityError.commandFailed(command: cmd, exitCode: -1, stderr: "Subprocess execution is unavailable on this platform")
        #endif
    }

    public static func runChecked(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> String {
        let out = try run(executable: executable, arguments: arguments, currentDirectory: currentDirectory)
        guard out.exitCode == 0 else {
            let cmd = ([executable] + arguments).joined(separator: " ")
            throw ParityError.commandFailed(command: cmd, exitCode: out.exitCode, stderr: out.stderr)
        }
        return out.stdout
    }
}

/// Summary of `pub` Rust symbol counts discovered during `status`.
public struct SymbolSummary: Codable, Sendable, Equatable {
    public var structs: Int
    public var enums: Int
    public var traits: Int
    public var functions: Int
    public var total: Int

    public init(structs: Int, enums: Int, traits: Int, functions: Int) {
        self.structs = structs
        self.enums = enums
        self.traits = traits
        self.functions = functions
        self.total = structs + enums + traits + functions
    }
}

/// Result of `rune-parity status`.
public struct ParityStatusReport: Codable, Sendable, Equatable {
    public var upstreamPath: String
    public var mapPath: String
    public var mappedCrates: Int
    public var mappedThemes: Int
    public var mappedExamples: Int
    public var totalRustFiles: Int
    public var totalWgslFiles: Int
    public var symbolSummary: SymbolSummary
    public var unmappedCrates: [String]
    public var unmappedThemes: [String]
    public var unmappedExamples: [String]
    public var unmappedFiles: [String]
    public var missingSwiftPaths: [String]
    public var passed: Bool

    public init(
        upstreamPath: String,
        mapPath: String,
        mappedCrates: Int,
        mappedThemes: Int,
        mappedExamples: Int,
        totalRustFiles: Int,
        totalWgslFiles: Int,
        symbolSummary: SymbolSummary,
        unmappedCrates: [String],
        unmappedThemes: [String],
        unmappedExamples: [String],
        unmappedFiles: [String],
        missingSwiftPaths: [String],
        passed: Bool
    ) {
        self.upstreamPath = upstreamPath
        self.mapPath = mapPath
        self.mappedCrates = mappedCrates
        self.mappedThemes = mappedThemes
        self.mappedExamples = mappedExamples
        self.totalRustFiles = totalRustFiles
        self.totalWgslFiles = totalWgslFiles
        self.symbolSummary = symbolSummary
        self.unmappedCrates = unmappedCrates
        self.unmappedThemes = unmappedThemes
        self.unmappedExamples = unmappedExamples
        self.unmappedFiles = unmappedFiles
        self.missingSwiftPaths = missingSwiftPaths
        self.passed = passed
    }
}

/// A single changed file from `git diff --name-status` mapped to its Swift target(s).
public struct MappedCommitChange: Codable, Sendable, Equatable {
    public var gitStatus: String
    public var upstreamFile: String
    public var swiftTarget: String?
    public var swiftFiles: [String]
    public var testCommand: String?
    public var mapped: Bool

    public init(
        gitStatus: String,
        upstreamFile: String,
        swiftTarget: String?,
        swiftFiles: [String],
        testCommand: String?,
        mapped: Bool
    ) {
        self.gitStatus = gitStatus
        self.upstreamFile = upstreamFile
        self.swiftTarget = swiftTarget
        self.swiftFiles = swiftFiles
        self.testCommand = testCommand
        self.mapped = mapped
    }
}

/// Result of `rune-parity diff-commits`.
public struct CommitDiffReport: Codable, Sendable, Equatable {
    public var since: String
    public var to: String
    public var commits: [String]
    public var changes: [MappedCommitChange]
    public var affectedTargets: [String]
    public var testCommands: [String]
    public var unmappedChanges: [String]

    public init(
        since: String,
        to: String,
        commits: [String],
        changes: [MappedCommitChange],
        affectedTargets: [String],
        testCommands: [String],
        unmappedChanges: [String]
    ) {
        self.since = since
        self.to = to
        self.commits = commits
        self.changes = changes
        self.affectedTargets = affectedTargets
        self.testCommands = testCommands
        self.unmappedChanges = unmappedChanges
    }
}

/// Loads `upstream-map.json` and `.upstream-sync.json`, runs parity `status` and `diff-commits`.
public enum ParityMapper {
    public static func loadMap(at url: URL) throws -> UpstreamMap {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ParityError.fileNotFound(url.path)
        }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(UpstreamMap.self, from: data)
        } catch {
            throw ParityError.invalidJSON("\(url.path): \(error)")
        }
    }

    public static func loadSyncState(at url: URL) throws -> UpstreamSyncState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ParityError.fileNotFound(url.path)
        }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(UpstreamSyncState.self, from: data)
        } catch {
            throw ParityError.invalidJSON("\(url.path): \(error)")
        }
    }

    public static func checkStatus(
        upstreamRoot: URL,
        swiftRoot: URL,
        mapURL: URL
    ) throws -> ParityStatusReport {
        let map = try loadMap(at: mapURL)
        let scan = try RustScanner.scanUpstream(at: upstreamRoot)
        let fm = FileManager.default

        let mappedCratePaths = Set(map.crates.map(\.upstreamPath))
        let mappedThemePaths = Set((map.themes ?? []).map(\.upstreamPath))
        let mappedExamplePaths = Set(map.examples.map(\.upstreamPath))

        let unmappedCrates = scan.crates.filter { !mappedCratePaths.contains($0) }
        let unmappedThemes = scan.themes.filter { !mappedThemePaths.contains($0) }
        let unmappedExamples = scan.examples.filter { !mappedExamplePaths.contains($0) }

        var missingSwiftPaths: [String] = []
        var unmappedFiles: [String] = []

        for crate in map.crates {
            if let swiftPath = crate.swiftPath {
                let swiftDir = swiftRoot.appendingPathComponent(swiftPath)
                if !fm.fileExists(atPath: swiftDir.path) {
                    missingSwiftPaths.append(swiftPath)
                }
            }
            for swiftFile in crate.swiftOnly ?? [] {
                let full = swiftRoot.appendingPathComponent(swiftFile)
                if !fm.fileExists(atPath: full.path) {
                    missingSwiftPaths.append(swiftFile)
                }
            }
            for mod in crate.moduleMappings ?? [] {
                for swiftFile in mod.swift {
                    let full = swiftRoot.appendingPathComponent(swiftFile)
                    if !fm.fileExists(atPath: full.path) {
                        missingSwiftPaths.append(swiftFile)
                    }
                }
            }
        }

        for theme in map.themes ?? [] {
            let swiftDir = swiftRoot.appendingPathComponent(theme.swiftPath)
            if !fm.fileExists(atPath: swiftDir.path) {
                missingSwiftPaths.append(theme.swiftPath)
            }
        }

        for example in map.examples {
            let swiftDir = swiftRoot.appendingPathComponent(example.swiftPath)
            if !fm.fileExists(atPath: swiftDir.path) {
                missingSwiftPaths.append(example.swiftPath)
            }
        }

        // Verify every discovered .rs and .wgsl file is covered.
        let allSourceFiles = (scan.rustFiles + scan.wgslFiles).sorted()
        for file in allSourceFiles {
            if let crate = map.crates.first(where: { file.hasPrefix($0.upstreamPath + "/") }) {
                if let modules = crate.moduleMappings, !modules.isEmpty {
                    let relToCrate = String(file.dropFirst(crate.upstreamPath.count + 1))
                    // moduleMappings cover crate library sources under src/ (not tests/, examples/, benches/, build.rs).
                    guard relToCrate.hasPrefix("src/") else { continue }
                    let covered = modules.contains { $0.upstream == relToCrate || $0.upstream == file }
                    if !covered {
                        unmappedFiles.append(file)
                    }
                }
            } else if map.themes?.contains(where: { file.hasPrefix($0.upstreamPath + "/") }) == true {
                continue
            } else if map.examples.contains(where: { file.hasPrefix($0.upstreamPath + "/") }) {
                continue
            } else {
                unmappedFiles.append(file)
            }
        }

        let structs = scan.symbols.filter { $0.kind == .struct }.count
        let enums = scan.symbols.filter { $0.kind == .enum }.count
        let traits = scan.symbols.filter { $0.kind == .trait }.count
        let fns = scan.symbols.filter { $0.kind == .fn }.count
        let summary = SymbolSummary(structs: structs, enums: enums, traits: traits, functions: fns)

        let uniqueMissing = Array(Set(missingSwiftPaths)).sorted()
        let uniqueUnmappedFiles = Array(Set(unmappedFiles)).sorted()
        let passed = unmappedCrates.isEmpty
            && unmappedThemes.isEmpty
            && unmappedExamples.isEmpty
            && uniqueUnmappedFiles.isEmpty
            && uniqueMissing.isEmpty

        return ParityStatusReport(
            upstreamPath: upstreamRoot.path,
            mapPath: mapURL.path,
            mappedCrates: map.crates.count,
            mappedThemes: map.themes?.count ?? 0,
            mappedExamples: map.examples.count,
            totalRustFiles: scan.rustFiles.count,
            totalWgslFiles: scan.wgslFiles.count,
            symbolSummary: summary,
            unmappedCrates: unmappedCrates,
            unmappedThemes: unmappedThemes,
            unmappedExamples: unmappedExamples,
            unmappedFiles: uniqueUnmappedFiles,
            missingSwiftPaths: uniqueMissing,
            passed: passed
        )
    }

    public static func diffCommits(
        upstreamRoot: URL,
        mapURL: URL,
        syncURL: URL,
        since: String?,
        to: String = "HEAD"
    ) throws -> CommitDiffReport {
        let map = try loadMap(at: mapURL)
        let resolvedSince: String
        if let explicit = since, !explicit.isEmpty {
            resolvedSince = explicit
        } else {
            let syncState = try loadSyncState(at: syncURL)
            resolvedSince = syncState.syncedCommit
        }

        let range = "\(resolvedSince)..\(to)"
        let logOut = try ProcessRunner.runChecked(
            executable: "/usr/bin/git",
            arguments: ["-C", upstreamRoot.path, "log", "--oneline", range]
        )
        let commits = logOut
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let diffOut = try ProcessRunner.runChecked(
            executable: "/usr/bin/git",
            arguments: ["-C", upstreamRoot.path, "diff", "--name-status", range]
        )

        var changes: [MappedCommitChange] = []
        var targetSet: Set<String> = []
        var testCmdSet: Set<String> = []
        var unmappedChanges: [String] = []

        for rawLine in diffOut.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: "\t", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { continue }
            let status = parts[0]
            // For renames (R100\told\tnew), take the destination path.
            let filePath = parts.last!

            let mapped = mapUpstreamFile(filePath, using: map)
            changes.append(MappedCommitChange(
                gitStatus: status,
                upstreamFile: filePath,
                swiftTarget: mapped.swiftTarget,
                swiftFiles: mapped.swiftFiles,
                testCommand: mapped.testCommand,
                mapped: mapped.mapped
            ))

            if let target = mapped.swiftTarget {
                targetSet.insert(target)
            }
            if let cmd = mapped.testCommand {
                testCmdSet.insert(cmd)
            }
            if !mapped.mapped && isTrackableFile(filePath) {
                unmappedChanges.append(filePath)
            }
        }

        return CommitDiffReport(
            since: resolvedSince,
            to: to,
            commits: commits,
            changes: changes,
            affectedTargets: targetSet.sorted(),
            testCommands: testCmdSet.sorted(),
            unmappedChanges: unmappedChanges.sorted()
        )
    }

    /// Maps a single upstream file path to its Swift target, Swift source files, and test command.
    public static func mapUpstreamFile(
        _ filePath: String,
        using map: UpstreamMap
    ) -> (swiftTarget: String?, swiftFiles: [String], testCommand: String?, mapped: Bool) {
        if let crate = map.crates.first(where: { filePath.hasPrefix($0.upstreamPath + "/") }) {
            let rel = String(filePath.dropFirst(crate.upstreamPath.count + 1))
            let testCmd = crate.testTarget.map { "xcrun swift test --filter \($0)" }
            if let mod = crate.moduleMappings?.first(where: { $0.upstream == rel || $0.upstream == filePath }) {
                return (crate.swiftTarget, mod.swift, testCmd, true)
            }
            return (crate.swiftTarget, crate.swiftPath.map { [$0] } ?? [], testCmd, true)
        }

        if let theme = map.themes?.first(where: { filePath.hasPrefix($0.upstreamPath + "/") }) {
            let testCmd = theme.testTarget.map { "xcrun swift test --filter \($0)" }
            return (theme.swiftTarget, [theme.swiftPath], testCmd, true)
        }

        if let example = map.examples.first(where: { filePath.hasPrefix($0.upstreamPath + "/") }) {
            return (example.swiftTarget, [example.swiftPath], nil, true)
        }

        return (nil, [], nil, false)
    }

    private static func isTrackableFile(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".rs")
            || lower.hasSuffix(".wgsl")
            || lower.hasPrefix("crates/")
            || lower.hasPrefix("themes/")
            || lower.hasPrefix("examples/")
    }
}
