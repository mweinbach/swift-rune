import Foundation

/// Sync state persisted in `.upstream-sync.json` at the repository root.
public struct UpstreamSyncState: Codable, Sendable, Equatable {
    public var upstreamRepo: String
    public var syncedCommit: String
    public var syncedCommitDate: String
    public var syncedCommitSubject: String
    public var syncedAt: String
    public var swiftTargets: Int
    public var swiftExecutables: Int

    public init(
        upstreamRepo: String,
        syncedCommit: String,
        syncedCommitDate: String,
        syncedCommitSubject: String,
        syncedAt: String,
        swiftTargets: Int,
        swiftExecutables: Int
    ) {
        self.upstreamRepo = upstreamRepo
        self.syncedCommit = syncedCommit
        self.syncedCommitDate = syncedCommitDate
        self.syncedCommitSubject = syncedCommitSubject
        self.syncedAt = syncedAt
        self.swiftTargets = swiftTargets
        self.swiftExecutables = swiftExecutables
    }
}

/// Mapping between an upstream Rust file and its corresponding Swift source file(s).
public struct ModuleMapping: Codable, Sendable, Equatable {
    public var upstream: String
    public var swift: [String]
    public var status: String?
    public var note: String?

    public init(upstream: String, swift: [String], status: String? = nil, note: String? = nil) {
        self.upstream = upstream
        self.swift = swift
        self.status = status
        self.note = note
    }
}

/// Optional parity summary metadata on a mapped crate.
public struct ParityCounts: Codable, Sendable, Equatable {
    public var files: String?
    public var pubSymbols: String?
    public var report: String?

    public init(files: String? = nil, pubSymbols: String? = nil, report: String? = nil) {
        self.files = files
        self.pubSymbols = pubSymbols
        self.report = report
    }
}

/// Mapping for an upstream Rust crate in `crates/*`.
public struct CrateMapping: Codable, Sendable, Equatable {
    public var upstreamPath: String
    public var swiftTarget: String?
    public var swiftPath: String?
    public var testTarget: String?
    public var status: String?
    public var note: String?
    public var parity: ParityCounts?
    public var swiftOnly: [String]?
    public var moduleMappings: [ModuleMapping]?

    public init(
        upstreamPath: String,
        swiftTarget: String?,
        swiftPath: String?,
        testTarget: String? = nil,
        status: String? = nil,
        note: String? = nil,
        parity: ParityCounts? = nil,
        swiftOnly: [String]? = nil,
        moduleMappings: [ModuleMapping]? = nil
    ) {
        self.upstreamPath = upstreamPath
        self.swiftTarget = swiftTarget
        self.swiftPath = swiftPath
        self.testTarget = testTarget
        self.status = status
        self.note = note
        self.parity = parity
        self.swiftOnly = swiftOnly
        self.moduleMappings = moduleMappings
    }
}

/// Mapping for an upstream theme in `themes/*`.
public struct ThemeMapping: Codable, Sendable, Equatable {
    public var upstreamPath: String
    public var swiftTarget: String
    public var swiftPath: String
    public var testTarget: String?
    public var status: String?
    public var note: String?
    public var swiftOnly: [String]?
    public var moduleMappings: [ModuleMapping]?

    public init(
        upstreamPath: String,
        swiftTarget: String,
        swiftPath: String,
        testTarget: String? = nil,
        status: String? = nil,
        note: String? = nil,
        swiftOnly: [String]? = nil,
        moduleMappings: [ModuleMapping]? = nil
    ) {
        self.upstreamPath = upstreamPath
        self.swiftTarget = swiftTarget
        self.swiftPath = swiftPath
        self.testTarget = testTarget
        self.status = status
        self.note = note
        self.swiftOnly = swiftOnly
        self.moduleMappings = moduleMappings
    }
}

/// Mapping for an upstream example in `examples/*`.
public struct ExampleMapping: Codable, Sendable, Equatable {
    public var upstreamName: String
    public var upstreamPath: String
    public var cargoPackage: String?
    public var swiftProduct: String
    public var swiftTarget: String
    public var swiftPath: String

    public init(
        upstreamName: String,
        upstreamPath: String,
        cargoPackage: String? = nil,
        swiftProduct: String,
        swiftTarget: String,
        swiftPath: String
    ) {
        self.upstreamName = upstreamName
        self.upstreamPath = upstreamPath
        self.cargoPackage = cargoPackage
        self.swiftProduct = swiftProduct
        self.swiftTarget = swiftTarget
        self.swiftPath = swiftPath
    }
}

/// Mapping for a crate-level example or extra binary target.
public struct CrateExampleMapping: Codable, Sendable, Equatable {
    public var upstreamPath: String
    public var status: String
    public var swiftTarget: String?
    public var note: String?

    public init(upstreamPath: String, status: String, swiftTarget: String? = nil, note: String? = nil) {
        self.upstreamPath = upstreamPath
        self.status = status
        self.swiftTarget = swiftTarget
        self.note = note
    }
}

/// Root schema of `.agents/skills/upstream-rune-sync/references/upstream-map.json`.
public struct UpstreamMap: Codable, Sendable, Equatable {
    public var version: Int
    public var upstreamRepo: String
    public var upstreamBranch: String?
    public var crates: [CrateMapping]
    public var themes: [ThemeMapping]?
    public var examples: [ExampleMapping]
    public var crateExamples: [CrateExampleMapping]?
    public var extraBins: [CrateExampleMapping]?
    public var swiftOnlyExecutables: [String]?

    public init(
        version: Int,
        upstreamRepo: String,
        upstreamBranch: String? = nil,
        crates: [CrateMapping],
        themes: [ThemeMapping]? = nil,
        examples: [ExampleMapping],
        crateExamples: [CrateExampleMapping]? = nil,
        extraBins: [CrateExampleMapping]? = nil,
        swiftOnlyExecutables: [String]? = nil
    ) {
        self.version = version
        self.upstreamRepo = upstreamRepo
        self.upstreamBranch = upstreamBranch
        self.crates = crates
        self.themes = themes
        self.examples = examples
        self.crateExamples = crateExamples
        self.extraBins = extraBins
        self.swiftOnlyExecutables = swiftOnlyExecutables
    }
}

/// Common errors thrown by `rune-parity` operations.
public enum ParityError: Error, CustomStringConvertible, Sendable {
    case invalidArguments(String)
    case fileNotFound(String)
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case invalidJSON(String)
    case missingExampleMapping(String)

    public var description: String {
        switch self {
        case .invalidArguments(let msg):
            return "Invalid arguments: \(msg)"
        case .fileNotFound(let path):
            return "File or directory not found: \(path)"
        case .commandFailed(let cmd, let code, let err):
            let trimmed = err.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Command failed (\(code)): \(cmd)\(trimmed.isEmpty ? "" : "\n\(trimmed)")"
        case .invalidJSON(let msg):
            return "Invalid JSON: \(msg)"
        case .missingExampleMapping(let name):
            return "Example '\(name)' not found in upstream-map.json"
        }
    }
}
