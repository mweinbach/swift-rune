import Foundation
import Rune
import RuneHighlights

/// A kind of token in code, each with its own color in a `SyntaxTheme` (`rune_kit::syntax::Syntax`).
public enum Syntax: Int, CaseIterable, Sendable, Hashable {
    case keyword = 0
    case string = 1
    case number = 2
    case comment = 3
    case type = 4
    case function = 5
    case property = 6
    case punctuation = 7
    case inserted = 8
    case deleted = 9
    case parameter = 10
    case heading = 11
    case link = 12
    case `operator` = 13
    case regex = 14
    case attribute = 15
    case variable = 16

    public static let count = Syntax.allCases.count

    /// Whether the built-in `RuneHighlights` lexer recognizes `language` (excluding `plain`/`text`).
    public static func known(_ language: String) -> Bool {
        guard let lang = Language.fromName(language) else { return false }
        return lang != .plain
    }

    /// Maps a `RuneHighlights.HighlightToken` (or its parent capture name) to a `Syntax` kind.
    public static func kind(for token: HighlightToken) -> Syntax? {
        tokenTable[token.index]
    }

    /// Uncached built-in syntax highlighting via `RuneHighlights`, capped at 128 KiB and 32,768 spans.
    public static func builtin(language: String?, code: String) -> [SyntaxHighlight] {
        guard let language, let lang = Language.fromName(language), lang != .plain else {
            return []
        }
        let limitedCode = limitedSource(code)
        let spans = lexerState.tokens(language: lang, code: limitedCode)
        var out: [SyntaxHighlight] = []
        out.reserveCapacity(spans.count)

        for span in spans {
            guard let k = kind(for: span.token) else { continue }
            if let last = out.last,
               last.range.upperBound == span.utf8Range.lowerBound,
               case .kind(let prev) = last.paint,
               prev == k {
                out[out.count - 1].range = last.range.lowerBound..<span.utf8Range.upperBound
                continue
            }
            if out.count >= maxTokens { break }
            out.append(SyntaxHighlight(range: span.utf8Range, paint: .kind(k)))
        }
        return out
    }

    /// Cached built-in syntax highlighting.
    public static func highlight(language: String?, code: String) -> [SyntaxHighlight] {
        SyntaxHighlighter.builtin.highlight(language: language, code: code)
    }

    /// Returns the `RuneHighlights` language name for a file path (`syntax/paths.rs`).
    public static func langForPath(_ path: String) -> String? {
        let name: String
        if let sep = path.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            name = String(path[path.index(after: sep)...])
        } else {
            name = path
        }
        if name.isEmpty { return nil }

        var found = pathTable[name]
        if found == nil, let firstDot = name.firstIndex(of: ".") {
            let rest = String(name[name.index(after: firstDot)...])
            if rest.contains(".") {
                found = pathTable[rest]
            }
        }
        if found == nil, let lastDot = name.lastIndex(of: ".") {
            let ext = String(name[name.index(after: lastDot)...])
            found = pathTable[ext]
        }
        guard let resolved = found, !resolved.isEmpty else { return nil }
        return resolved
    }

    // MARK: - Internals

    fileprivate static let maxSourceBytes = 128 * 1024
    fileprivate static let maxTokens = 32 * 1024

    fileprivate static func limitedSource(_ code: String) -> String {
        let utf8 = code.utf8
        guard utf8.count > maxSourceBytes else { return code }
        let prefixEnd = utf8.index(utf8.startIndex, offsetBy: maxSourceBytes)
        if let nl = utf8[..<prefixEnd].lastIndex(of: 0x0A) {
            return String(decoding: utf8[..<nl], as: UTF8.self)
        }
        return ""
    }

    private static let lexerState = LexerState()

    private final class LexerState: @unchecked Sendable {
        private let lock = NSLock()
        private let whole = Highlighter()
        private var stream: HighlightStream?
        private var lastLang: Language?
        private var lastCode: String = ""

        func tokens(language: Language, code: String) -> [HighlightSpan] {
            lock.lock()
            defer { lock.unlock() }
            if var s = stream, s.language == language, s.continues(code) {
                let res = s.highlight(code)
                stream = s
                return res
            }
            if let prevLang = lastLang, prevLang == language, code.count > lastCode.count, code.hasPrefix(lastCode) {
                lastLang = nil
                lastCode = ""
                var s = HighlightStream(language: language)
                let res = s.highlight(code)
                stream = s
                return res
            }
            lastLang = language
            lastCode = code
            return whole.highlight(code, language: language)
        }
    }

    private static let kindMap: [String: Syntax?] = [
        "attribute": .attribute,
        "boolean": .number,
        "comment": .comment,
        "constant": .number,
        "constructor": .type,
        "diff.minus": .deleted,
        "diff.plus": .inserted,
        "embedded": nil,
        "emphasis": nil,
        "enum": .type,
        "function": .function,
        "hint": .comment,
        "keyword": .keyword,
        "keyword.operator": .operator,
        "label": .number,
        "link_text": .link,
        "link_uri": .keyword,
        "namespace": .number,
        "number": .number,
        "operator": .operator,
        "predictive": .comment,
        "preproc": .keyword,
        "primary": .link,
        "property": .property,
        "punctuation": .punctuation,
        "punctuation.special": .keyword,
        "selector": .keyword,
        "selector.class": .attribute,
        "selector.id": .function,
        "selector.pseudo": .operator,
        "string": .string,
        "string.escape": .number,
        "string.regex": .regex,
        "string.special": .number,
        "tag": .keyword,
        "tag.component.jsx": .type,
        "text": nil,
        "text.literal": .string,
        "title": .heading,
        "type": .type,
        "variable": .variable,
        "variable.parameter": .parameter,
        "variable.special": .number,
        "variant": .number,
    ]

    private static let tokenTable: [Syntax?] = {
        HighlightToken.all.map { token in
            var current: String? = token.name
            while let name = current {
                if let entry = kindMap[name] {
                    return entry
                }
                if let dot = name.lastIndex(of: ".") {
                    current = String(name[..<dot])
                } else {
                    current = nil
                }
            }
            return nil
        }
    }()

    private static let pathTable: [String: String] = [
        "1c": "", "Appraisals": "ruby", "BUCK": "python", "BUILD": "python", "Berksfile": "ruby",
        "Brewfile": "ruby", "CMakeLists.txt": "cmake", "CODEOWNERS": "", "COMMIT_EDITMSG": "git-commit", "Capfile": "ruby",
        "Dangerfile": "ruby", "Dockerfile": "dockerfile", "Gemfile": "ruby", "Guardfile": "ruby", "Makefile": "makefile",
        "P": "", "PACKAGE": "python", "R": "r", "Rakefile": "ruby", "Thorfile": "ruby",
        "Tiltfile": "python", "Vagrantfile": "ruby", "WORKSPACE": "python", "abap": "", "ada": "",
        "adb": "", "ado": "", "adoc": "", "ads": "", "apl": "",
        "applescript": "", "ara": "", "arb": "ruby", "as": "", "asciidoc": "",
        "asm": "asm", "astro": "astro", "awk": "", "bal": "", "bas": "",
        "bash": "zsh", "bat": "cmd", "bazel": "python", "be": "", "beancount": "",
        "bib": "", "bicep": "", "blade.php": "", "bsl": "", "builder": "ruby",
        "bxl": "python", "bzl": "python", "bzlmod": "python", "c": "c", "cairo": "",
        "cbl": "", "cc": "cpp", "cdc": "", "cfg": "", "cjs": "javascript",
        "cl": "lisp", "clar": "", "clj": "clojure", "cljc": "clojure", "cljs": "clojure",
        "cls": "tex", "cmake": "cmake", "cmd": "cmd", "cob": "", "cobol": "",
        "coffee": "", "component.html": "angular-html", "component.ts": "angular-ts", "conf": "", "config": "",
        "cpp": "cpp", "cql": "", "cr": "", "cs": "csharp", "cshtml": "",
        "css": "css", "csv": "", "cts": "typescript", "cue": "", "cxx": "cpp",
        "cyp": "", "cypher": "", "d": "", "dart": "dart", "dax": "",
        "desktop": "", "device": "", "diff": "diff", "dm": "", "do": "",
        "dockerfile": "dockerfile", "dta": "", "edge": "", "el": "emacs-lisp", "elm": "elm",
        "env": "", "erb": "", "erl": "erlang", "ex": "elixir", "exs": "elixir",
        "f": "fortran-fixed-form", "f03": "f03", "f08": "f08", "f18": "", "f77": "f77",
        "f90": "fortran-free-form", "f95": "fortran-free-form", "feature": "", "fish": "", "fnl": "",
        "for": "fortran-fixed-form", "frag": "glsl", "fs": "fsharp", "fsi": "fsharp", "fsx": "fsharp",
        "ftl": "", "fx": "hlsl", "gd": "gdscript", "gdshader": "gdshader", "gemspec": "ruby",
        "git-rebase-todo": "git-rebase", "gjs": "", "gleam": "gleam", "glsl": "glsl", "gnuplot": "",
        "go": "go", "gp": "", "gql": "graphql", "graphql": "graphql", "groovy": "groovy",
        "gs": "", "gts": "", "gvy": "groovy", "h": "objective-cpp", "hack": "",
        "haml": "", "handlebars": "", "hbs": "", "hcl": "hcl", "hh": "cpp",
        "hjson": "", "hlsl": "hlsl", "hpp": "cpp", "hrl": "erlang", "hs": "haskell",
        "htaccess": "", "htm": "html", "html": "html", "http": "", "hx": "",
        "hxml": "", "hy": "", "imba": "", "ini": "", "j2": "",
        "jade": "", "java": "java", "jbuilder": "ruby", "jinja": "", "jinja2": "",
        "jison": "", "jl": "julia", "js": "javascript", "json": "json", "json5": "json5",
        "jsonc": "jsonc", "jsonl": "jsonl", "jsonnet": "", "jssm": "", "jsx": "jsx",
        "kql": "", "kt": "kotlin", "kts": "kts", "lean": "", "less": "less",
        "lhs": "haskell", "libsonnet": "", "liquid": "", "lisp": "lisp", "lit": "",
        "ll": "", "log": "", "logo": "", "lsp": "lisp", "ltx": "tex",
        "lua": "lua", "luau": "", "m": "", "makefile": "makefile", "markdown": "markdown",
        "marko": "", "mat": "matlab", "md": "markdown", "mdc": "", "mdx": "mdx",
        "mediawiki": "", "mermaid": "", "mips": "", "mjs": "javascript", "mk": "makefile",
        "ml": "ocaml", "mli": "ocaml", "mll": "ocaml", "mly": "ocaml", "mm": "objective-cpp",
        "mmd": "", "mojo": "", "move": "", "mts": "typescript", "nar": "",
        "nb": "", "nf": "", "nim": "nim", "nimble": "nim", "nims": "nim",
        "nix": "nix", "nu": "", "odin": "", "p": "pascal", "p6": "",
        "pas": "pascal", "patch": "diff", "pcss": "", "php": "php", "phtml": "php",
        "pl": "", "pl6": "", "pls": "", "plt": "", "pm": "perl",
        "po": "", "podspec": "ruby", "polar": "", "pot": "", "potx": "",
        "pp": "", "pq": "", "pqm": "", "prisma": "", "pro": "",
        "properties": "", "proto": "protobuf", "ps1": "powershell", "psd1": "powershell", "psm1": "powershell",
        "pug": "", "purs": "", "py": "python", "pyi": "python", "pyw": "python",
        "ql": "", "qml": "", "qmldir": "", "qss": "", "r": "r",
        "rabl": "ruby", "rake": "ruby", "raku": "", "razor": "", "rb": "ruby",
        "rbw": "ruby", "reg": "", "regex": "", "rel": "", "res": "gdresource",
        "rest": "", "rkt": "", "rktl": "", "rq": "", "rs": "rust",
        "rst": "", "ru": "ruby", "s": "", "sas": "", "sass": "sass",
        "sc": "scala", "scala": "scala", "scm": "scheme", "scpt": "", "scss": "scss",
        "sdbl": "", "service": "", "sh": "zsh", "shader": "", "shadergraph": "",
        "sky": "python", "sld": "scheme", "socket": "", "sol": "solidity", "soy": "",
        "sparql": "", "spl": "", "sql": "sql", "ss": "scheme", "st": "",
        "star": "python", "sty": "tex", "styl": "", "stylus": "", "sv": "",
        "svelte": "svelte", "svh": "", "swift": "swift", "t": "perl", "talon": "",
        "tasl": "", "tcl": "", "templ": "", "tex": "tex", "tf": "tf",
        "tfvars": "tfvars", "timer": "", "toml": "toml", "tres": "gdresource", "trigger": "",
        "ts": "typescript", "tsp": "", "tsv": "", "tsx": "tsx", "ttl": "",
        "twig": "", "typ": "", "v": "", "vala": "", "vapi": "",
        "vb": "", "vbs": "", "vert": "glsl", "vh": "", "vhd": "",
        "vhdl": "", "vim": "", "vine.ts": "", "vue": "vue", "vv": "",
        "vy": "", "wasm": "wasm", "wat": "wasm", "wgsl": "wgsl", "wiki": "",
        "wit": "", "wl": "", "wy": "", "xml": "xml", "xsl": "",
        "xslt": "", "yaml": "yaml", "yml": "yml", "zig": "zig", "zs": "",
        "zsh": "zsh", "🔥": "",
    ]
}

/// What colors a highlighted UTF-8 byte range (`rune_kit::syntax::Paint`).
public enum SyntaxPaint: Sendable, Equatable, Hashable {
    case kind(Syntax)
    case color(Color)
}

/// A highlighted UTF-8 byte range of code (`rune_kit::syntax::Highlight`).
public struct SyntaxHighlight: Sendable, Equatable, Hashable {
    public var range: Range<Int>
    public var paint: SyntaxPaint

    public init(range: Range<Int>, paint: SyntaxPaint) {
        self.range = range
        self.paint = paint
    }
}

/// Cached syntax highlighter (`rune_kit::syntax::Highlighter`).
public struct SyntaxHighlighter: Sendable {
    private let fn: (@Sendable (String?, String) -> [SyntaxHighlight])?
    private var id: String

    public static let builtin = SyntaxHighlighter(builtinID: "builtin")

    private init(builtinID: String) {
        self.fn = nil
        self.id = builtinID
    }

    public init(id: String = "custom", _ fn: @escaping @Sendable (String?, String) -> [SyntaxHighlight]) {
        self.fn = fn
        self.id = "custom:\(id)"
    }

    public var isBuiltin: Bool { fn == nil }

    /// Separates cached output by an additional key (e.g. `"dark"` vs `"light"`).
    public func key(_ key: String) -> SyntaxHighlighter {
        var copy = self
        copy.id = "\(id)::\(key)"
        return copy
    }

    public func highlight(language: String?, code: String) -> [SyntaxHighlight] {
        let limited = Syntax.limitedSource(code)
        let cacheKey = CacheKey(id: id, language: language, code: limited)
        if let hit = Self.cache.get(cacheKey) {
            return hit
        }
        let result: [SyntaxHighlight]
        if let fn {
            result = Self.tidy(fn(language, limited), source: limited)
        } else {
            result = Syntax.builtin(language: language, code: limited)
        }
        let estimatedBytes = limited.utf8.count + result.count * MemoryLayout<SyntaxHighlight>.stride + 96
        Self.cache.insert(cacheKey, value: result, bytes: estimatedBytes)
        return result
    }

    private struct CacheKey: Hashable, Sendable {
        let id: String
        let language: String?
        let code: String
    }

    private static let cache = BudgetCache<CacheKey, [SyntaxHighlight]>(limitBytes: 4 << 20)

    private static func tidy(_ input: [SyntaxHighlight], source: String) -> [SyntaxHighlight] {
        let utf8 = source.utf8
        let totalBytes = utf8.count
        var valid = input.filter { item in
            guard item.range.lowerBound >= 0,
                  item.range.lowerBound < item.range.upperBound,
                  item.range.upperBound <= totalBytes else { return false }
            let startIdx = utf8.index(utf8.startIndex, offsetBy: item.range.lowerBound)
            let endIdx = utf8.index(utf8.startIndex, offsetBy: item.range.upperBound)
            return startIdx.samePosition(in: source) != nil && endIdx.samePosition(in: source) != nil
        }
        valid.sort { $0.range.lowerBound < $1.range.lowerBound }
        var out: [SyntaxHighlight] = []
        var last = 0
        for item in valid {
            if item.range.lowerBound >= last {
                out.append(item)
                last = item.range.upperBound
                if out.count >= 32 * 1024 { break }
            }
        }
        return out
    }
}

/// Color and optional weight per `Syntax` kind (`rune_kit::syntax::SyntaxTheme`).
public struct SyntaxTheme: Sendable, Equatable, Hashable {
    public var colors: [Color]
    public var weights: [Float?]

    public init(colors: [Color], weights: [Float?] = Array(repeating: nil, count: Syntax.count)) {
        self.colors = colors
        self.weights = weights
    }

    public static func fromKit(_ kit: Kit) -> SyntaxTheme {
        let c = kit.c
        let textL = c.textBase.toLanes()[0]
        let (l, chroma): (Float, Float) = kit.dark
            ? ((textL - 0.16).clamped(to: 0.62...0.84), 0.10)
            : ((textL + 0.30).clamped(to: 0.38...0.52), 0.12)
        func paint(_ hue: Float) -> Color { oklch(l, chroma, hue) }

        var colors = Array(repeating: c.textBase, count: Syntax.count)
        colors[Syntax.keyword.rawValue] = paint(305)
        colors[Syntax.string.rawValue] = paint(145)
        colors[Syntax.number.rawValue] = paint(60)
        colors[Syntax.comment.rawValue] = c.textMuted.mix(with: c.textFaint, t: 0.4)
        colors[Syntax.type.rawValue] = paint(195)
        colors[Syntax.function.rawValue] = paint(255)
        colors[Syntax.property.rawValue] = paint(15)
        colors[Syntax.punctuation.rawValue] = c.textMuted
        colors[Syntax.inserted.rawValue] = c.success.icon
        colors[Syntax.deleted.rawValue] = c.danger.icon
        colors[Syntax.heading.rawValue] = paint(335)
        colors[Syntax.link.rawValue] = paint(225)
        colors[Syntax.operator.rawValue] = c.textMuted.mix(with: c.textBase, t: 0.5)
        colors[Syntax.regex.rawValue] = paint(170)
        colors[Syntax.attribute.rawValue] = paint(40)
        colors[Syntax.variable.rawValue] = c.textBase.mix(with: c.textContrast, t: 0.25)
        return SyntaxTheme(colors: colors)
    }

    public static func neutral(dark: Bool) -> SyntaxTheme {
        fromKit(Kit.neutral(dark: dark))
    }

    public func color(for kind: Syntax) -> Color {
        colors[kind.rawValue]
    }

    public func with(_ kind: Syntax, _ color: Color) -> SyntaxTheme {
        var copy = self
        copy.colors[kind.rawValue] = color
        return copy
    }

    public func withWeight(_ kind: Syntax, _ weight: Float) -> SyntaxTheme {
        var copy = self
        copy.weights[kind.rawValue] = weight.clamped(to: 1...1000)
        return copy
    }

    public func weight(for kind: Syntax) -> Float? {
        weights[kind.rawValue]
    }

    public func paint(_ p: SyntaxPaint) -> Color {
        switch p {
        case .kind(let k): color(for: k)
        case .color(let c): c
        }
    }

    /// Converts `highlights` over `code` into `Rune.TextSpan` slices for `El.richText(...)`.
    public func spans(
        for code: String,
        highlights: [SyntaxHighlight],
        defaultColor: Color? = nil,
        monospace: Bool = true
    ) -> [TextSpan] {
        guard !code.isEmpty else { return [] }
        let utf8 = code.utf8
        let total = utf8.count
        var result: [TextSpan] = []
        var cursor = 0

        for h in highlights {
            let start = max(cursor, min(h.range.lowerBound, total))
            let end = max(start, min(h.range.upperBound, total))
            if start > cursor {
                let plain = sliceUTF8(code, from: cursor, to: start)
                if !plain.isEmpty {
                    result.append(TextSpan(plain, color: defaultColor, monospace: monospace))
                }
            }
            if end > start {
                let text = sliceUTF8(code, from: start, to: end)
                if !text.isEmpty {
                    let w: Float? = if case .kind(let k) = h.paint { weight(for: k) } else { nil }
                    let isItalic: Bool = if case .kind(.comment) = h.paint { true } else { false }
                    result.append(TextSpan(text, color: paint(h.paint), weight: w, italic: isItalic, monospace: monospace))
                }
            }
            cursor = end
        }

        if cursor < total {
            let tail = sliceUTF8(code, from: cursor, to: total)
            if !tail.isEmpty {
                result.append(TextSpan(tail, color: defaultColor, monospace: monospace))
            }
        }
        return result
    }

    private func sliceUTF8(_ source: String, from startByte: Int, to endByte: Int) -> String {
        let utf8 = source.utf8
        guard let s = utf8.index(utf8.startIndex, offsetBy: startByte, limitedBy: utf8.endIndex),
              let e = utf8.index(utf8.startIndex, offsetBy: endByte, limitedBy: utf8.endIndex) else {
            return ""
        }
        return String(decoding: utf8[s..<e], as: UTF8.self)
    }
}

extension Kit {
    /// Syntax-highlighted code block and optional line-numbered viewer powered by `RuneHighlights`.
    public func codeBlock<State>(
        key: String = "code-block",
        code: String,
        language: String? = nil,
        showLineNumbers: Bool = true,
        lineSelection: LineSelection? = nil,
        highlighter: SyntaxHighlighter = .builtin,
        theme: SyntaxTheme? = nil
    ) -> El<State> {
        let resolvedTheme = theme ?? SyntaxTheme.fromKit(self)
        let lines = code.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let lineCount = max(1, lines.count)
        let gutterWidth = Float(max(2, String(lineCount).count) * 8 + 16)

        var header: El<State> = row()
            .justifyBetween()
            .itemsCenter()
            .px(12)
            .py(6)
            .bg(c.layer02)
            .borderSides(bottom: 1.0, color: c.borderMuted)

        if let language, !language.isEmpty {
            header = header.child(
                text(language.lowercased()).font(ty.smallMedium).color(c.textMuted)
            )
        } else {
            header = header.child(
                text("code").font(ty.small).color(c.textFaint)
            )
        }
        header = header.child(
            text("\(lineCount) \(lineCount == 1 ? "line" : "lines")").font(ty.small).color(c.textFaint)
        )

        var body: El<State> = col()
            .wFull()
            .py(6)

        for (idx, lineText) in lines.enumerated() {
            let lineNum = idx + 1
            let selected = lineSelection?.contains(lineNum) ?? false
            let lineHighlights = highlighter.highlight(language: language, code: lineText)
            let spans = resolvedTheme.spans(for: lineText, highlights: lineHighlights, defaultColor: c.textBase, monospace: true)

            var lineRow: El<State> = row()
                .key("\(key)-line-\(lineNum)")
                .wFull()
                .px(10)
                .py(1)
                .itemsCenter()
            if selected {
                lineRow = lineRow.bg(c.bgAccent.alpha(0.16))
            }

            if showLineNumbers {
                lineRow = lineRow.child(
                    el()
                        .w(gutterWidth)
                        .pr(10)
                        .justifyEnd()
                        .child(text("\(lineNum)").font(ty.mono).size(11).color(selected ? c.textAccent : c.textFaint))
                )
            }

            if spans.isEmpty {
                lineRow = lineRow.child(text(" ").font(ty.mono).color(c.textBase))
            } else {
                lineRow = lineRow.child(
                    rich(spans)
                        .font(ty.mono)
                        .color(c.textBase)
                        .grow(1)
                        .minW(0)
                )
            }
            body = body.child(lineRow)
        }

        return col()
            .key(key)
            .wFull()
            .rounded(radius.md)
            .bg(c.layer01)
            .border(1.0, c.borderMuted)
            .clip(true)
            .child(header)
            .child(body)
    }
}
