import Foundation

/// Luau require-by-string resolver and module loader with cycle detection and `.luaurc` aliases.
internal enum LuauRequire {
    static func install(into vm: LuauVM, compiled: CompiledSources) {
        final class LoadingChain: @unchecked Sendable {
            var stack: [String] = []
        }
        let loading = LoadingChain()

        vm.globals.rawSet("require", value: .nativeFunction(LuauNativeFunction(name: "require") { vm, thread, args in
            guard case .string(let target) = args.first else {
                throw LuauRuntimeError(value: .string("bad argument #1 to 'require' (string expected)"))
            }

            // 1. Built-in / host-registered modules (e.g. `@rune/ui`, `@rune/signal`, `@app/...`)
            if let builtin = vm.registeredModules[target] {
                return .values([builtin])
            }

            // Determine current chunk path from call frame (e.g. "@init.luau" or "@views/row.luau")
            let callerSource = thread.frames.last?.closure.proto.sourceName ?? compiled.entry
            let resolvedPath = try resolveModule(target: target, fromPath: callerSource, compiled: compiled)

            if let cached = vm.moduleCache[resolvedPath] {
                return .values([cached])
            }

            let runningEntry = thread.frames.contains {
                $0.closure.proto.sourceName == compiled.entry || $0.closure.proto.sourceName == "@\(compiled.entry)"
            }
            if loading.stack.contains(resolvedPath) || (resolvedPath == compiled.entry && runningEntry) {
                let prefix = (runningEntry && !loading.stack.contains(compiled.entry)) ? [compiled.entry] : []
                let chain = (prefix + loading.stack + [resolvedPath]).joined(separator: " -> ")
                throw LuauRuntimeError(value: .string("require cycle: \(chain)"))
            }

            guard let mod = compiled.module(resolvedPath) else {
                throw LuauRuntimeError(value: .string("module '\(target)' not found"))
            }

            loading.stack.append(resolvedPath)
            defer { loading.stack.removeLast() }

            let env = vm.isSandboxed ? vm.makeIsolatedEnv() : vm.defaultEnv
            let cl = LuauClosure(proto: mod.proto, upvalues: [], env: env)
            let results = try vm.call(closure: cl)
            if results.count != 1 {
                throw LuauRuntimeError(value: .string("module must return a single value"))
            }
            let exported = results[0]
            vm.moduleCache[resolvedPath] = exported
            return .values([exported])
        }))
    }

    static func runEntry(vm: LuauVM, compiled: CompiledSources) throws -> LuauValue {
        guard let mod = compiled.module(compiled.entry) else {
            throw ScriptError(kind: .missing, message: "no module \(compiled.entry)")
        }
        let cl = LuauClosure(proto: mod.proto, upvalues: [], env: vm.defaultEnv)
        let results = try vm.call(closure: cl)
        return results.first ?? .nil
    }

    private static func resolveModule(target: String, fromPath: String, compiled: CompiledSources) throws -> String {
        var components: [String]
        var isAboveFolder = false

        // Strip .luau if provided
        let cleanTarget = target.hasSuffix(".luau") ? String(target.dropLast(5)) : target

        if cleanTarget.hasPrefix("@self/") {
            let rest = String(cleanTarget.dropFirst("@self/".count))
            components = moduleSegments(for: fromPath)
            try applyRelative(rest, to: &components, isAboveFolder: &isAboveFolder, compiled: compiled)
        } else if cleanTarget == "@self" {
            components = moduleSegments(for: fromPath)
        } else if cleanTarget.hasPrefix("@") {
            // Alias lookup: `@alias/sub/path`
            let withoutAt = String(cleanTarget.dropFirst())
            let parts = withoutAt.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let aliasName = String(parts[0])
            let remainder = parts.count > 1 ? String(parts[1]) : ""

            let callerDir = parentSegments(for: fromPath)
            guard let (aliasTarget, aliasBaseDir) = findAlias(aliasName, startingAt: callerDir, compiled: compiled) else {
                throw LuauRuntimeError(value: .string("unknown require alias '@\(aliasName)'"))
            }

            if aliasTarget.hasPrefix("./") || aliasTarget.hasPrefix("../") || aliasTarget == "." || aliasTarget == ".." {
                components = aliasBaseDir ?? []
                isAboveFolder = (aliasBaseDir == nil)
                try applyRelative(aliasTarget, to: &components, isAboveFolder: &isAboveFolder, compiled: compiled)
            } else {
                throw LuauRuntimeError(value: .string("alias '@\(aliasName)' points outside script folder"))
            }
            if !remainder.isEmpty {
                try applyRelative(remainder, to: &components, isAboveFolder: &isAboveFolder, compiled: compiled)
            }
        } else if cleanTarget.hasPrefix("./") || cleanTarget.hasPrefix("../") || cleanTarget == "." || cleanTarget == ".." {
            // Relative to caller's parent directory (init.luau is at root, so its parent is above folder!)
            let callerSegs = moduleSegments(for: fromPath)
            if callerSegs.isEmpty {
                isAboveFolder = true
                components = []
            } else {
                components = Array(callerSegs.dropLast())
            }
            try applyRelative(cleanTarget, to: &components, isAboveFolder: &isAboveFolder, compiled: compiled)
        } else {
            throw LuauRuntimeError(value: .string("require path '\(target)' must start with './', '../', or '@'"))
        }

        if isAboveFolder {
            throw LuauRuntimeError(value: .string("require '\(target)' cannot reach outside the script folder"))
        }

        if components.isEmpty {
            if compiled.module(compiled.entry) != nil {
                return compiled.entry
            }
            throw LuauRuntimeError(value: .string("module '\(target)' not found"))
        }

        let base = components.joined(separator: "/")
        let candidates = ["\(base).luau", "\(base)/init.luau"].filter { compiled.module($0) != nil }
        if candidates.count == 1 {
            return candidates[0]
        } else if candidates.count > 1 {
            throw LuauRuntimeError(value: .string("ambiguous module '\(target)'"))
        }
        throw LuauRuntimeError(value: .string("module '\(target)' not found"))
    }

    private static func moduleSegments(for path: String) -> [String] {
        var clean = path
        if clean.hasPrefix("@") { clean.removeFirst() }
        if clean.hasSuffix(".luau") { clean = String(clean.dropLast(5)) }
        var segs = clean.split(separator: "/").map(String.init)
        if segs.last == "init" {
            segs.removeLast()
        }
        return segs
    }

    private static func parentSegments(for path: String) -> [String] {
        let segs = moduleSegments(for: path)
        return segs.isEmpty ? [] : Array(segs.dropLast())
    }

    private static func applyRelative(
        _ rel: String,
        to components: inout [String],
        isAboveFolder: inout Bool,
        compiled: CompiledSources
    ) throws {
        for seg in rel.split(separator: "/", omittingEmptySubsequences: true) {
            let s = String(seg)
            if s == "." {
                continue
            } else if s == ".." {
                if isAboveFolder {
                    throw LuauRuntimeError(value: .string("cannot navigate above script folder"))
                } else if components.isEmpty {
                    isAboveFolder = true
                } else {
                    components.removeLast()
                }
            } else {
                if isAboveFolder {
                    if compiled.folder == s {
                        isAboveFolder = false
                        components = []
                    } else {
                        throw LuauRuntimeError(value: .string("cannot reach '\(s)' outside script folder"))
                    }
                } else {
                    components.append(s)
                }
            }
        }
    }

    private static func findAlias(_ name: String, startingAt dir: [String], compiled: CompiledSources) -> (String, [String]?)? {
        var cur = dir
        while true {
            let dirStr = cur.joined(separator: "/")
            if let cfg = compiled.config(dir: dirStr), let target = parseAlias(name, fromConfig: cfg) {
                return (target, cur)
            }
            if cur.isEmpty { break }
            cur.removeLast()
        }
        if let parentCfg = compiled.parentConfig, let target = parseAlias(name, fromConfig: parentCfg) {
            return (target, nil)
        }
        return nil
    }

    private static func parseAlias(_ name: String, fromConfig text: String) -> String? {
        if let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let aliases = json["aliases"] as? [String: Any],
               let raw = aliases[name] as? String {
                return raw
            }
            if let luau = json["luau"] as? [String: Any],
               let aliases = luau["aliases"] as? [String: Any],
               let raw = aliases[name] as? String {
                return raw
            }
        }
        // `.config.luau` returns `{ luau = { aliases = { ... } } }` or `{ aliases = { ... } }`.
        let cfgVM = LuauVM()
        cfgVM.sandbox()
        let armed = cfgVM.watchdog.arm(timeLimit: .milliseconds(50))
        defer { armed.disarm() }
        if let results = try? cfgVM.eval(text, name: ".config.luau"),
           case .table(let root) = results.first {
            let aliasesVal: LuauValue = {
                if case .table(let luauTbl) = root.rawGet("luau") {
                    let a = luauTbl.rawGet("aliases")
                    if !a.isNil { return a }
                }
                return root.rawGet("aliases")
            }()
            if case .table(let aliases) = aliasesVal,
               case .string(let raw) = aliases.rawGet(name) {
                return raw
            }
        }
        return nil
    }
}
