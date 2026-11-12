import Foundation

/// A programming or markup language supported by `RuneHighlights`.
public struct Language: Sendable, Equatable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Plain text without a lexer (produces no tokens).
    public static let plain = Language(rawValue: 0)
    public static let angularHTML = Language(rawValue: 1)
    public static let asm = Language(rawValue: 2)
    public static let astro = Language(rawValue: 3)
    public static let bash = Language(rawValue: 4)
    public static let bat = Language(rawValue: 5)
    public static let c = Language(rawValue: 6)
    public static let c3 = Language(rawValue: 7)
    public static let clojure = Language(rawValue: 8)
    public static let cmake = Language(rawValue: 9)
    public static let cpp = Language(rawValue: 10)
    public static let csharp = Language(rawValue: 11)
    public static let css = Language(rawValue: 12)
    public static let cuda = Language(rawValue: 13)
    public static let dart = Language(rawValue: 14)
    public static let diff = Language(rawValue: 15)
    public static let dockerfile = Language(rawValue: 16)
    public static let elixir = Language(rawValue: 17)
    public static let elm = Language(rawValue: 18)
    public static let erlang = Language(rawValue: 19)
    public static let fortran = Language(rawValue: 20)
    public static let fortranFixedForm = Language(rawValue: 21)
    public static let fsharp = Language(rawValue: 22)
    public static let gdresource = Language(rawValue: 23)
    public static let gdscript = Language(rawValue: 24)
    public static let gdshader = Language(rawValue: 25)
    public static let gleam = Language(rawValue: 26)
    public static let glsl = Language(rawValue: 27)
    public static let go = Language(rawValue: 28)
    public static let graphql = Language(rawValue: 29)
    public static let groovy = Language(rawValue: 30)
    public static let haskell = Language(rawValue: 31)
    public static let hlsl = Language(rawValue: 32)
    public static let html = Language(rawValue: 33)
    public static let java = Language(rawValue: 34)
    public static let javascript = Language(rawValue: 35)
    public static let json = Language(rawValue: 36)
    public static let json5 = Language(rawValue: 37)
    public static let jsonl = Language(rawValue: 38)
    public static let jsx = Language(rawValue: 39)
    public static let julia = Language(rawValue: 40)
    public static let kotlin = Language(rawValue: 41)
    public static let latex = Language(rawValue: 42)
    public static let less = Language(rawValue: 43)
    public static let lisp = Language(rawValue: 44)
    public static let lua = Language(rawValue: 45)
    public static let makefile = Language(rawValue: 46)
    public static let markdown = Language(rawValue: 47)
    public static let matlab = Language(rawValue: 48)
    public static let mdx = Language(rawValue: 49)
    public static let nim = Language(rawValue: 50)
    public static let nix = Language(rawValue: 51)
    public static let objectiveC = Language(rawValue: 52)
    public static let ocaml = Language(rawValue: 53)
    public static let pascal = Language(rawValue: 54)
    public static let perl = Language(rawValue: 55)
    public static let php = Language(rawValue: 56)
    public static let powershell = Language(rawValue: 57)
    public static let proto = Language(rawValue: 58)
    public static let python = Language(rawValue: 59)
    public static let r = Language(rawValue: 60)
    public static let ruby = Language(rawValue: 61)
    public static let rust = Language(rawValue: 62)
    public static let sass = Language(rawValue: 63)
    public static let scala = Language(rawValue: 64)
    public static let scss = Language(rawValue: 65)
    public static let solidity = Language(rawValue: 66)
    public static let sql = Language(rawValue: 67)
    public static let svelte = Language(rawValue: 68)
    public static let swift = Language(rawValue: 69)
    public static let terraform = Language(rawValue: 70)
    public static let toml = Language(rawValue: 71)
    public static let typescript = Language(rawValue: 72)
    public static let tsrx = Language(rawValue: 73)
    public static let tsx = Language(rawValue: 74)
    public static let vue = Language(rawValue: 75)
    public static let wasm = Language(rawValue: 76)
    public static let wgsl = Language(rawValue: 77)
    public static let xml = Language(rawValue: 78)
    public static let yaml = Language(rawValue: 79)
    public static let zig = Language(rawValue: 80)
    public static let msl = Language(rawValue: 81)

    /// Canonical name for this language.
    public var name: String {
        let index = Int(rawValue)
        guard index < Self.names.count else { return "plain" }
        return Self.names[index]
    }

    /// Looks up a language by canonical name or alias, ignoring ASCII case.
    public static func fromName(_ name: String) -> Language? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let id = aliasTable[key] else { return nil }
        return Language(rawValue: id)
    }

    /// All languages with a lexer (excluding `.plain`).
    public static var all: [Language] {
        (1..<UInt8(names.count)).map(Language.init(rawValue:))
    }

    /// All supported name/alias pairs for languages with a lexer.
    public static var aliases: [(String, Language)] {
        aliasList.compactMap { pair in
            pair.1 == 0 ? nil : (pair.0, Language(rawValue: pair.1))
        }
    }

    private static let names: [String] = [
        "plain", "angular-html", "asm", "astro", "bash", "bat", "c", "c3",
        "clojure", "cmake", "cpp", "csharp", "css", "cuda", "dart", "diff",
        "dockerfile", "elixir", "elm", "erlang", "fortran", "fortran-fixed-form", "fsharp", "gdresource",
        "gdscript", "gdshader", "gleam", "glsl", "go", "graphql", "groovy", "haskell",
        "hlsl", "html", "java", "javascript", "json", "json5", "jsonl", "jsx",
        "julia", "kotlin", "latex", "less", "lisp", "lua", "makefile", "markdown",
        "matlab", "mdx", "nim", "nix", "objective-c", "ocaml", "pascal", "perl",
        "php", "powershell", "proto", "python", "r", "ruby", "rust", "sass",
        "scala", "scss", "solidity", "sql", "svelte", "swift", "terraform", "toml",
        "typescript", "tsrx", "tsx", "vue", "wasm", "wgsl", "xml", "yaml",
        "zig", "msl",
    ]

    private static let aliasList: [(String, UInt8)] = [
        ("angular-html", 1), ("angular-ts", 72), ("asm", 2), ("assembly", 2), ("astro", 3), ("bash", 4),
        ("bat", 5), ("batch", 5), ("batchfile", 5), ("c", 6), ("c#", 11), ("c++", 10),
        ("c3", 7), ("cc", 10), ("cjs", 35), ("cl", 44), ("clj", 8), ("cljc", 8),
        ("cljs", 8), ("clojure", 8), ("cmake", 9), ("cmd", 5), ("comp", 27), ("containerfile", 16),
        ("cpp", 10), ("cs", 11), ("csharp", 11), ("css", 12), ("cts", 72), ("cu", 13),
        ("cuda", 13), ("cuh", 13), ("cxx", 10), ("dart", 14), ("delphi", 54), ("diff", 15),
        ("docker", 16), ("dockerfile", 16), ("dos", 5), ("dpk", 54), ("dpr", 54), ("edn", 8),
        ("el", 44), ("elisp", 44), ("elixir", 17), ("elm", 18), ("emacs-lisp", 44), ("erl", 19),
        ("erlang", 19), ("ex", 17), ("exs", 17), ("f", 21), ("f#", 22), ("f03", 20),
        ("f08", 20), ("f77", 21), ("f90", 20), ("f95", 20), ("for", 21), ("fortran", 20),
        ("fortran-fixed-form", 21), ("fortran-free-form", 20), ("frag", 27), ("fs", 22), ("fsharp", 22), ("fsi", 22),
        ("fsx", 22), ("gd", 24), ("gdresource", 23), ("gdscript", 24), ("gdshader", 25), ("gdshaderinc", 25),
        ("geom", 27), ("git-commit", 15), ("git-rebase", 15), ("gleam", 26), ("glsl", 27), ("go", 28),
        ("godot-resource", 23), ("godot-shader", 25), ("golang", 28), ("gql", 29), ("gradle", 30), ("graphql", 29),
        ("groovy", 30), ("gsh", 30), ("gvy", 30), ("gy", 30), ("h", 6), ("haskell", 31),
        ("hcl", 70), ("hh", 10), ("hlsl", 32), ("hpp", 10), ("hrl", 19), ("hs", 31),
        ("htm", 33), ("html", 33), ("hxx", 10), ("java", 34), ("javascript", 35), ("jl", 40),
        ("js", 35), ("json", 36), ("json5", 37), ("jsonc", 36), ("jsonl", 38), ("jsx", 39),
        ("julia", 40), ("kotlin", 41), ("kt", 41), ("kts", 41), ("latex", 42), ("less", 43),
        ("lisp", 44), ("lpr", 54), ("lsp", 44), ("lua", 45), ("m", 52), ("make", 46),
        ("makefile", 46), ("markdown", 47), ("matlab", 48), ("md", 47), ("mdx", 49), ("metal", 81),
        ("mjs", 35), ("mk", 46), ("ml", 53), ("mli", 53), ("mm", 52), ("msl", 81),
        ("mts", 72), ("nim", 50), ("nix", 51), ("objc", 52), ("objcpp", 52), ("object-pascal", 54),
        ("objective-c", 52), ("objective-cpp", 52), ("objectivec", 52), ("objectpascal", 54), ("ocaml", 53),
        ("octave", 48), ("pas", 54), ("pascal", 54), ("patch", 15), ("perl", 55), ("php", 56),
        ("pl", 55), ("plain", 0), ("plaintext", 0), ("pm", 55), ("powershell", 57), ("pp", 54),
        ("proto", 58), ("protobuf", 58), ("ps", 57), ("ps1", 57), ("psd1", 57), ("psm1", 57),
        ("pwsh", 57), ("py", 59), ("python", 59), ("r", 60), ("rb", 61), ("rs", 62),
        ("rscript", 60), ("ruby", 61), ("rust", 62), ("s", 2), ("sass", 63), ("sbt", 64),
        ("sc", 64), ("scala", 64), ("scheme", 44), ("scm", 44), ("scss", 65), ("sh", 4),
        ("shell", 4), ("shellscript", 4), ("shellsession", 4), ("sol", 66), ("solidity", 66), ("sql", 67),
        ("svelte", 68), ("svg", 78), ("swift", 69), ("terraform", 70), ("tex", 42), ("text", 0),
        ("tf", 70), ("tfvars", 70), ("toml", 71), ("tres", 23), ("ts", 72), ("tscn", 23),
        ("tsrx", 73), ("tsx", 74), ("txt", 0), ("typescript", 72), ("vert", 27), ("vue", 75),
        ("wasm", 76), ("wat", 76), ("wgsl", 77), ("xml", 78), ("xsd", 78), ("yaml", 79),
        ("yml", 79), ("zig", 80), ("zon", 80), ("zsh", 4),
    ]

    private static let aliasTable: [String: UInt8] = Dictionary(uniqueKeysWithValues: aliasList)
}
