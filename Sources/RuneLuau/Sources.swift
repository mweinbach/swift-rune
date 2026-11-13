import Foundation

/// A script's files held in memory so it runs identically from disk or embedded strings.
public struct Sources: Sendable, Equatable {
    public static let entry = "init.luau"
    private static let configFiles: Set<String> = [".luaurc", ".config.luau"]

    public private(set) var files: [String: String]
    public private(set) var parentConfig: String?
    public private(set) var folder: String?
    public private(set) var entryOverride: String?

    public init() {
        self.files = [:]
    }

    public static func single(_ source: String) -> Sources {
        Sources().with(entry, source)
    }

    public func with(_ path: String, _ source: String) -> Sources {
        var copy = self
        copy.insert(path, source)
        return copy
    }

    public mutating func insert(_ path: String, _ source: String) {
        files[Self.normalize(path)] = source
    }

    public func parentConfig(_ luaurc: String) -> Sources {
        var copy = self
        copy.parentConfig = luaurc
        return copy
    }

    public func entry(_ path: String) -> Sources {
        var copy = self
        copy.entryOverride = Self.normalize(path)
        return copy
    }

    public var entryPath: String {
        entryOverride ?? Self.entry
    }

    public func folder(_ name: String) -> Sources {
        var copy = self
        copy.folder = name
        return copy
    }

    public func get(_ path: String) -> String? {
        files[Self.normalize(path)]
    }

    public var paths: [String] {
        files.keys.sorted()
    }

    /// Reads every `.luau` file and `.luaurc` / `.config.luau` under `dir` recursively.
    public static func fromDir(_ dir: URL) throws -> Sources {
        var out = Sources()
        out.folder = dir.lastPathComponent
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return out
        }
        let rootPath = dir.standardizedFileURL.path
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            if name.hasSuffix(".luau") || configFiles.contains(name) {
                let fullPath = fileURL.standardizedFileURL.path
                if fullPath.hasPrefix(rootPath) {
                    var rel = String(fullPath.dropFirst(rootPath.count))
                    if rel.hasPrefix("/") { rel.removeFirst() }
                    let content = try String(contentsOf: fileURL, encoding: .utf8)
                    out.insert(rel, content)
                }
            }
        }
        let parentLuaurc = dir.deletingLastPathComponent().appendingPathComponent(".luaurc")
        if let parentText = try? String(contentsOf: parentLuaurc, encoding: .utf8) {
            out.parentConfig = parentText
        }
        return out
    }

    public func compile() throws -> CompiledSources {
        try compileReusing(nil)
    }

    public func compileFrom(_ previous: CompiledSources) throws -> CompiledSources {
        try compileReusing(previous)
    }

    private func compileReusing(_ previous: CompiledSources?) throws -> CompiledSources {
        let entry = entryPath
        guard files[entry] != nil else {
            throw ScriptError(kind: .missing, message: "the script has no \(entry)")
        }
        var modules: [String: CompiledModule] = [:]
        var configs: [String: String] = [:]

        for path in files.keys.sorted() {
            guard let source = files[path] else { continue }
            if !path.hasSuffix(".luau") || path.hasSuffix(".config.luau") {
                configs[path] = source
                continue
            }
            if let prev = previous?.modules[path], prev.source == source {
                modules[path] = prev
                continue
            }
            let lexer = LuauLexer(source: source, name: path)
            let tokens = try lexer.tokenize()
            let parser = LuauParser(tokens: tokens, sourceName: path)
            let stmts = try parser.parseChunk()
            let compiler = LuauCompiler(sourceName: path)
            let proto = try compiler.compile(stmts: stmts)
            modules[path] = CompiledModule(proto: proto, source: source)
        }

        return CompiledSources(
            modules: modules,
            configs: configs,
            parentConfig: parentConfig,
            folder: folder,
            entry: entry
        )
    }

    private static func normalize(_ path: String) -> String {
        var s = path.replacingOccurrences(of: "\\", with: "/")
        while s.hasPrefix("./") { s.removeFirst(2) }
        while s.hasPrefix("/") { s.removeFirst() }
        return s
    }
}

public final class CompiledModule: @unchecked Sendable {
    internal let proto: LuauProto
    internal let source: String

    internal init(proto: LuauProto, source: String) {
        self.proto = proto
        self.source = source
    }
}

public final class CompiledSources: @unchecked Sendable {
    internal let modules: [String: CompiledModule]
    internal let configs: [String: String]
    internal let parentConfig: String?
    internal let folder: String?
    internal let entry: String

    internal init(
        modules: [String: CompiledModule],
        configs: [String: String],
        parentConfig: String?,
        folder: String?,
        entry: String
    ) {
        self.modules = modules
        self.configs = configs
        self.parentConfig = parentConfig
        self.folder = folder
        self.entry = entry
    }

    internal func module(_ path: String) -> CompiledModule? {
        modules[path]
    }

    internal func isDir(_ dir: String) -> Bool {
        if dir.isEmpty { return true }
        let prefix = "\(dir)/"
        return modules.keys.contains(where: { $0.hasPrefix(prefix) })
            || configs.keys.contains(where: { $0.hasPrefix(prefix) })
    }

    internal func config(dir: String?) -> String? {
        guard let dir else { return parentConfig }
        for name in [".luaurc", ".config.luau"] {
            let p = dir.isEmpty ? name : "\(dir)/\(name)"
            if let text = configs[p] { return text }
        }
        return nil
    }
}
