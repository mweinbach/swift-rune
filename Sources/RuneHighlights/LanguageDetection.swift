import Foundation

extension Language {
    /// Detects a language from a file path or filename (e.g., `"main.rs"`, `"/app/Dockerfile"`, `"CMakeLists.txt"`).
    public static func fromFilename(_ filename: String) -> Language? {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Extract basename (handling both `/` and `\` separators).
        let basename: String
        if let slash = trimmed.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            basename = String(trimmed[trimmed.index(after: slash)...])
        } else {
            basename = trimmed
        }
        guard !basename.isEmpty else { return nil }

        let lowerBase = basename.lowercased()

        // 1. Exact special filenames
        if let exact = exactFilenameMap[lowerBase] {
            return exact
        }

        // Prefix/suffix special filenames (e.g., Dockerfile.dev, Makefile.am, .env.local)
        if lowerBase.hasPrefix("dockerfile.") || lowerBase.hasPrefix("containerfile.") {
            return .dockerfile
        }
        if lowerBase.hasPrefix("makefile.") || lowerBase.hasPrefix("gnumakefile.") {
            return .makefile
        }
        if lowerBase.hasPrefix(".env.") || lowerBase == ".env" {
            return .bash
        }
        if lowerBase.hasSuffix(".d.ts") || lowerBase.hasSuffix(".d.mts") || lowerBase.hasSuffix(".d.cts") {
            return .typescript
        }
        if lowerBase.hasSuffix(".blade.php") {
            return .php
        }

        // 2. File extension
        if let dot = lowerBase.lastIndex(of: ".") {
            let ext = String(lowerBase[lowerBase.index(after: dot)...])
            if !ext.isEmpty {
                if let mapped = extensionMap[ext] {
                    return mapped
                }
                if let byAlias = Language.fromName(ext), byAlias != .plain {
                    return byAlias
                }
            }
        }

        return nil
    }

    /// Detects a language from a `#!` shebang line (e.g., `"#!/usr/bin/env python3"` or `"#!/bin/bash"`).
    public static func fromShebang(_ firstLine: String) -> Language? {
        var line = firstLine
        if line.hasPrefix("\u{FEFF}") {
            line.removeFirst()
        }
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("#!") else { return nil }

        let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }

        let parts = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = parts.first else { return nil }

        let commandName = basenameOfPath(first).lowercased()
        var interpreter = commandName

        // Handle `/usr/bin/env [-S] [VAR=val] interpreter ...`
        if commandName == "env" {
            var idx = 1
            while idx < parts.count {
                let arg = parts[idx]
                if arg.hasPrefix("-") || arg.contains("=") {
                    idx += 1
                    continue
                }
                interpreter = basenameOfPath(arg).lowercased()
                break
            }
        }

        return mapInterpreter(interpreter)
    }

    /// Detects a language from an optional filename and the source text (shebang, modeline, or header).
    public static func detect(filename: String? = nil, source: String) -> Language? {
        if let filename, let byName = fromFilename(filename) {
            return byName
        }

        // Inspect first line (strip optional UTF-8 BOM).
        var firstLine = ""
        if let newline = source.firstIndex(of: "\n") {
            firstLine = String(source[..<newline])
        } else {
            firstLine = source
        }
        if firstLine.hasPrefix("\u{FEFF}") {
            firstLine.removeFirst()
        }

        if let byShebang = fromShebang(firstLine) {
            return byShebang
        }

        if let byModeline = fromModeline(firstLine) {
            return byModeline
        }

        // Unambiguous file headers
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerPrefix = String(trimmed.prefix(64)).lowercased()
        if lowerPrefix.hasPrefix("<?xml") {
            return .xml
        }
        if lowerPrefix.hasPrefix("<?php") {
            return .php
        }
        if lowerPrefix.hasPrefix("<!doctype html") || lowerPrefix.hasPrefix("<html") {
            return .html
        }
        if trimmed.hasPrefix("diff --git ") {
            return .diff
        }

        return nil
    }

    // MARK: - Helpers

    private static func basenameOfPath(_ path: String) -> String {
        if let slash = path.lastIndex(of: "/") {
            return String(path[path.index(after: slash)...])
        }
        return path
    }

    private static func mapInterpreter(_ raw: String) -> Language? {
        if let direct = shebangInterpreterMap[raw] {
            return direct
        }
        // Strip trailing version numbers (e.g. python3.12 -> python, ruby3.2 -> ruby, lua5.4 -> lua)
        let stripped = raw.replacingOccurrences(
            of: #"[0-9]+(\.[0-9]+)*$"#,
            with: "",
            options: .regularExpression
        )
        if !stripped.isEmpty, let mapped = shebangInterpreterMap[stripped] {
            return mapped
        }
        return Language.fromName(stripped).flatMap { $0 == .plain ? nil : $0 }
    }

    private static func fromModeline(_ line: String) -> Language? {
        // Emacs: -*- mode: python -*- or -*- rust -*-
        if let start = line.range(of: "-*-"),
           let end = line.range(of: "-*-", range: start.upperBound..<line.endIndex) {
            let inner = line[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces)
            for part in inner.split(separator: ";") {
                let kv = part.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces).lowercased()
                }
                if kv.count == 2, kv[0] == "mode" || kv[0] == "filetype" || kv[0] == "ft" {
                    if let lang = Language.fromName(kv[1]), lang != .plain {
                        return lang
                    }
                } else if kv.count == 1, let lang = Language.fromName(kv[0]), lang != .plain {
                    return lang
                }
            }
        }

        // Vim: vim: set ft=rust: or vi: filetype=python
        let lower = line.lowercased()
        if lower.contains("vim:") || lower.contains("vi:") {
            for key in ["ft=", "filetype="] {
                if let range = lower.range(of: key) {
                    let rest = lower[range.upperBound...]
                    let token = rest.prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "+" || $0 == "#" })
                    if !token.isEmpty, let lang = Language.fromName(String(token)), lang != .plain {
                        return lang
                    }
                }
            }
        }

        return nil
    }

    private static let exactFilenameMap: [String: Language] = [
        "dockerfile": .dockerfile,
        "containerfile": .dockerfile,
        "makefile": .makefile,
        "gnumakefile": .makefile,
        "bsdmakefile": .makefile,
        "cmakelists.txt": .cmake,
        "gemfile": .ruby,
        "rakefile": .ruby,
        "podfile": .ruby,
        "fastfile": .ruby,
        "appfile": .ruby,
        "brewfile": .ruby,
        "vagrantfile": .ruby,
        "jenkinsfile": .groovy,
        "build.gradle": .groovy,
        "settings.gradle": .groovy,
        "package.swift": .swift,
        "cargo.toml": .toml,
        "cargo.lock": .toml,
        "pyproject.toml": .toml,
        "poetry.lock": .toml,
        "go.mod": .go,
        "go.sum": .plain,
        "tsconfig.json": .json,
        "jsconfig.json": .json,
        ".prettierrc": .json,
        ".eslintrc": .json,
        ".babelrc": .json,
        ".bashrc": .bash,
        ".bash_profile": .bash,
        ".bash_login": .bash,
        ".bash_logout": .bash,
        ".profile": .bash,
        ".zshrc": .bash,
        ".zprofile": .bash,
        ".zshenv": .bash,
        ".zlogin": .bash,
        ".zlogout": .bash,
        "commit_editmsg": .diff,
        "merge_msg": .diff,
        "git-rebase-todo": .diff,
        "flake.nix": .nix,
        "default.nix": .nix,
        "shell.nix": .nix,
        "terraform.tfvars": .terraform,
    ]

    private static let extensionMap: [String: Language] = [
        "c": .c,
        "h": .c,
        "cpp": .cpp,
        "cc": .cpp,
        "cxx": .cpp,
        "c++": .cpp,
        "hpp": .cpp,
        "hh": .cpp,
        "hxx": .cpp,
        "h++": .cpp,
        "c3": .c3,
        "cu": .cuda,
        "cuh": .cuda,
        "m": .objectiveC,
        "mm": .objectiveC,
        "rs": .rust,
        "swift": .swift,
        "go": .go,
        "zig": .zig,
        "zon": .zig,
        "nim": .nim,
        "nims": .nim,
        "java": .java,
        "kt": .kotlin,
        "kts": .kotlin,
        "scala": .scala,
        "sc": .scala,
        "sbt": .scala,
        "groovy": .groovy,
        "gradle": .groovy,
        "gvy": .groovy,
        "gy": .groovy,
        "gsh": .groovy,
        "cs": .csharp,
        "csx": .csharp,
        "fs": .fsharp,
        "fsi": .fsharp,
        "fsx": .fsharp,
        "dart": .dart,
        "sol": .solidity,
        "pas": .pascal,
        "pp": .pascal,
        "dpr": .pascal,
        "dpk": .pascal,
        "lpr": .pascal,
        "f": .fortranFixedForm,
        "f77": .fortranFixedForm,
        "for": .fortranFixedForm,
        "f90": .fortran,
        "f95": .fortran,
        "f03": .fortran,
        "f08": .fortran,
        "s": .asm,
        "asm": .asm,
        "nasm": .asm,
        "js": .javascript,
        "mjs": .javascript,
        "cjs": .javascript,
        "ts": .typescript,
        "mts": .typescript,
        "cts": .typescript,
        "jsx": .jsx,
        "tsx": .tsx,
        "tsrx": .tsrx,
        "py": .python,
        "pyi": .python,
        "pyw": .python,
        "rb": .ruby,
        "rake": .ruby,
        "gemspec": .ruby,
        "php": .php,
        "phtml": .php,
        "lua": .lua,
        "luau": .lua,
        "pl": .perl,
        "pm": .perl,
        "r": .r,
        "jl": .julia,
        "ex": .elixir,
        "exs": .elixir,
        "erl": .erlang,
        "hrl": .erlang,
        "hs": .haskell,
        "lhs": .haskell,
        "elm": .elm,
        "ml": .ocaml,
        "mli": .ocaml,
        "clj": .clojure,
        "cljs": .clojure,
        "cljc": .clojure,
        "edn": .clojure,
        "lisp": .lisp,
        "lsp": .lisp,
        "cl": .lisp,
        "el": .lisp,
        "scm": .lisp,
        "ss": .lisp,
        "rkt": .lisp,
        "gleam": .gleam,
        "ps1": .powershell,
        "psd1": .powershell,
        "psm1": .powershell,
        "sh": .bash,
        "bash": .bash,
        "zsh": .bash,
        "fish": .bash,
        "ksh": .bash,
        "bat": .bat,
        "cmd": .bat,
        "matlab": .matlab,
        "html": .html,
        "htm": .html,
        "xml": .xml,
        "xsd": .xml,
        "svg": .xml,
        "plist": .xml,
        "xhtml": .html,
        "css": .css,
        "scss": .scss,
        "sass": .sass,
        "less": .less,
        "vue": .vue,
        "svelte": .svelte,
        "astro": .astro,
        "md": .markdown,
        "markdown": .markdown,
        "mdx": .mdx,
        "tex": .latex,
        "latex": .latex,
        "sty": .latex,
        "cls": .latex,
        "json": .json,
        "jsonc": .json,
        "json5": .json5,
        "jsonl": .jsonl,
        "ndjson": .jsonl,
        "yaml": .yaml,
        "yml": .yaml,
        "toml": .toml,
        "nix": .nix,
        "tf": .terraform,
        "tfvars": .terraform,
        "hcl": .terraform,
        "sql": .sql,
        "gql": .graphql,
        "graphql": .graphql,
        "proto": .proto,
        "diff": .diff,
        "patch": .diff,
        "cmake": .cmake,
        "mk": .makefile,
        "mak": .makefile,
        "gd": .gdscript,
        "tres": .gdresource,
        "tscn": .gdresource,
        "gdshader": .gdshader,
        "gdshaderinc": .gdshader,
        "wgsl": .wgsl,
        "metal": .msl,
        "msl": .msl,
        "glsl": .glsl,
        "vert": .glsl,
        "frag": .glsl,
        "geom": .glsl,
        "comp": .glsl,
        "tesc": .glsl,
        "tese": .glsl,
        "hlsl": .hlsl,
        "fx": .hlsl,
        "wat": .wasm,
        "wast": .wasm,
        "txt": .plain,
    ]

    private static let shebangInterpreterMap: [String: Language] = [
        "sh": .bash,
        "bash": .bash,
        "zsh": .bash,
        "dash": .bash,
        "ash": .bash,
        "ksh": .bash,
        "fish": .bash,
        "python": .python,
        "python2": .python,
        "python3": .python,
        "pypy": .python,
        "pypy3": .python,
        "node": .javascript,
        "nodejs": .javascript,
        "deno": .typescript,
        "bun": .typescript,
        "ts-node": .typescript,
        "tsx": .typescript,
        "ruby": .ruby,
        "jruby": .ruby,
        "perl": .perl,
        "php": .php,
        "lua": .lua,
        "luajit": .lua,
        "luau": .lua,
        "pwsh": .powershell,
        "powershell": .powershell,
        "rscript": .r,
        "julia": .julia,
        "elixir": .elixir,
        "escript": .erlang,
        "runhaskell": .haskell,
        "runghc": .haskell,
        "ocaml": .ocaml,
        "swift": .swift,
        "make": .makefile,
        "gmake": .makefile,
    ]
}
