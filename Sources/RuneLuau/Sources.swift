import Foundation

/// A script's files held in memory so it runs identically from disk or embedded strings.
public struct Sources: Sendable, Equatable {
    public static let entry = "init.luau"
    private static let configFiles: Set<String> = [".luaurc", ".config.luau"]

    private enum Input: Sendable, Equatable {
        case text(String)
        case embedded(code: Data, native: Bool)
    }

    private var inputs: [String: Input]
    public var files: [String: String] {
        var out: [String: String] = [:]
        for (path, input) in inputs {
            if case .text(let source) = input {
                out[path] = source
            }
        }
        return out
    }
    public private(set) var parentConfig: String?
    public private(set) var folder: String?
    public private(set) var entryOverride: String?

    public init() {
        self.inputs = [:]
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
        inputs[Self.normalize(path)] = .text(source)
    }

    /// Adds a built-in module by its original path without retaining source text (`Sources::with_embedded`).
    /// Stack traces use the supplied path and the line table from the bytecode.
    public func withEmbedded(_ path: String, _ code: Data, native: Bool = false) -> Sources {
        var copy = self
        copy.insertEmbedded(path, code, native: native)
        return copy
    }

    /// Adds or replaces a built-in module by its original path without retaining source text.
    public mutating func insertEmbedded(_ path: String, _ code: Data, native: Bool = false) {
        inputs[Self.normalize(path)] = .embedded(code: code, native: native)
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

    /// The text at `path`, if supplied as source rather than as an embedded module.
    public func get(_ path: String) -> String? {
        guard case .text(let source) = inputs[Self.normalize(path)] else { return nil }
        return source
    }

    public var paths: [String] {
        inputs.keys.sorted()
    }

    /// Reads every `.luau` file and `.luaurc` / `.config.luau` under `dir` recursively.
    public static func fromDir(_ dir: URL) throws -> Sources {
        var out = Sources()
        out.folder = dir.lastPathComponent
        let fm = FileManager.default
        let resolvedDir = dir.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = fm.enumerator(at: resolvedDir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return out
        }
        let rootPath = resolvedDir.path
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            if name.hasSuffix(".luau") || configFiles.contains(name) {
                let isRegular = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                guard isRegular else { continue }
                let fullPath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
                if fullPath.hasPrefix(rootPath) {
                    var rel = String(fullPath.dropFirst(rootPath.count))
                    if rel.hasPrefix("/") { rel.removeFirst() }
                    let content = try String(contentsOf: fileURL, encoding: .utf8)
                    out.insert(rel, content)
                }
            }
        }
        let parentLuaurc = resolvedDir.deletingLastPathComponent().appendingPathComponent(".luaurc")
        if let parentText = try? String(contentsOf: parentLuaurc, encoding: .utf8) {
            out.parentConfig = parentText
        }
        return out
    }

    public static func compileBytecode(_ source: String, name: String = Sources.entry) throws -> Data {
        let normName = normalize(name)
        do {
            let lexer = LuauLexer(source: source, name: normName)
            let tokens = try lexer.tokenize()
            let parser = LuauParser(tokens: tokens, sourceName: normName)
            let stmts = try parser.parseChunk()
            let compiler = LuauCompiler(sourceName: normName)
            let proto = try compiler.compile(stmts: stmts)
            return proto.encode()
        } catch let err as ScriptError {
            let msg = err.message.hasPrefix("\(normName):") ? err.message : "\(normName): \(err.message)"
            throw ScriptError(kind: err.kind, message: msg)
        } catch {
            let msg = "\(error)"
            let prefixed = msg.hasPrefix("\(normName):") ? msg : "\(normName): \(msg)"
            throw ScriptError(kind: .syntax, message: prefixed)
        }
    }

    /// Registers bytecode by the exact source text it was compiled from. Only the first call takes effect.
    public static func precompiled(_ entries: [(String, Data)]) {
        var map: [Data: Data] = [:]
        for (source, code) in entries where code.starts(with: LuauProto.bytecodeHeader) {
            map[Data(source.utf8)] = code
        }
        PrecompiledStore.shared.setOnce(map)
    }

    /// Registers bytecode by the exact source text it was compiled from. Only the first call takes effect.
    public static func precompiled(_ entries: [String: Data]) {
        precompiled(entries.map { ($0.key, $0.value) })
    }

    internal static func _resetPrecompiledForTests() {
        PrecompiledStore.shared.resetForTests()
    }

    public func compile() throws -> CompiledSources {
        try compileReusing(nil)
    }

    public func compileFrom(_ previous: CompiledSources) throws -> CompiledSources {
        try compileReusing(previous)
    }

    private func compileReusing(_ previous: CompiledSources?) throws -> CompiledSources {
        let entry = entryPath
        guard inputs[entry] != nil else {
            throw ScriptError(kind: .missing, message: "the script has no \(entry)")
        }
        var modules: [String: CompiledModule] = [:]
        var configs: [String: String] = [:]

        for path in inputs.keys.sorted() {
            guard let input = inputs[path] else { continue }
            let source: String
            switch input {
            case .text(let text):
                source = text
            case .embedded(let code, let native):
                guard let proto = LuauProto.decode(code, sourceName: path) else {
                    throw ScriptError(kind: .syntax, message: "\(path): invalid embedded bytecode")
                }
                modules[path] = CompiledModule(proto: proto, native: native, source: nil)
                continue
            }
            if !path.hasSuffix(".luau") || path.hasSuffix(".config.luau") {
                configs[path] = source
                continue
            }
            if let prev = previous?.modules[path], let oldSource = prev.source,
               oldSource.utf8.elementsEqual(source.utf8) {
                modules[path] = prev
                continue
            }
            if let precompiledData = PrecompiledStore.shared.lookup(source),
               let proto = LuauProto.decode(precompiledData, sourceName: path) {
                modules[path] = CompiledModule(proto: proto, native: Self.isNative(source), source: source)
                continue
            }
            do {
                let lexer = LuauLexer(source: source, name: path)
                let tokens = try lexer.tokenize()
                let parser = LuauParser(tokens: tokens, sourceName: path)
                let stmts = try parser.parseChunk()
                let compiler = LuauCompiler(sourceName: path)
                let proto = try compiler.compile(stmts: stmts)
                modules[path] = CompiledModule(proto: proto, native: Self.isNative(source), source: source)
            } catch let err as ScriptError {
                let msg = err.message.hasPrefix("\(path):") ? err.message : "\(path): \(err.message)"
                throw ScriptError(kind: err.kind, message: msg)
            } catch {
                let msg = "\(error)"
                let prefixed = msg.hasPrefix("\(path):") ? msg : "\(path): \(msg)"
                throw ScriptError(kind: .syntax, message: prefixed)
            }
        }

        return CompiledSources(
            modules: modules,
            configs: configs,
            parentConfig: parentConfig,
            folder: folder,
            entry: entry
        )
    }

    private static func isNative(_ source: String) -> Bool {
        for rawLine in source.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("--") {
                if line.hasPrefix("--!native") {
                    return true
                }
                continue
            }
            break
        }
        return false
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
    internal let native: Bool
    internal let source: String?

    internal init(proto: LuauProto, native: Bool = false, source: String?) {
        self.proto = proto
        self.native = native
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

private final class PrecompiledStore: @unchecked Sendable {
    static let shared = PrecompiledStore()
    private let lock = NSLock()
    private var entries: [Data: Data]?

    func setOnce(_ map: [Data: Data]) {
        lock.lock()
        defer { lock.unlock() }
        if entries == nil {
            entries = map
        }
    }

    func lookup(_ source: String) -> Data? {
        let table = lock.withLock { entries }
        return table?[Data(source.utf8)]
    }

    func resetForTests() {
        lock.lock()
        defer { lock.unlock() }
        entries = nil
    }
}
