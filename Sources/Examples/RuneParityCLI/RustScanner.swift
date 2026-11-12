import Foundation

/// Kind of public Rust declaration discovered by `RustScanner`.
public enum RustSymbolKind: String, Codable, Sendable, Equatable, CaseIterable {
    case `struct`
    case `enum`
    case trait
    case fn
}

/// A single `pub struct` / `pub enum` / `pub trait` / `pub fn` declaration in a `.rs` file.
public struct RustSymbol: Codable, Sendable, Equatable {
    public var kind: RustSymbolKind
    public var name: String
    public var file: String
    public var line: Int

    public init(kind: RustSymbolKind, name: String, file: String, line: Int) {
        self.kind = kind
        self.name = name
        self.file = file
        self.line = line
    }
}

/// Inventory of upstream Rust/WGSL files, crates, themes, examples, and public symbols.
public struct UpstreamScanResult: Codable, Sendable, Equatable {
    public var crates: [String]
    public var themes: [String]
    public var examples: [String]
    public var rustFiles: [String]
    public var wgslFiles: [String]
    public var symbols: [RustSymbol]

    public init(
        crates: [String],
        themes: [String],
        examples: [String],
        rustFiles: [String],
        wgslFiles: [String],
        symbols: [RustSymbol]
    ) {
        self.crates = crates
        self.themes = themes
        self.examples = examples
        self.rustFiles = rustFiles
        self.wgslFiles = wgslFiles
        self.symbols = symbols
    }
}

/// Scans an upstream `rune` checkout for crates, themes, examples, `.rs`/`.wgsl` files, and `pub` symbols.
public enum RustScanner {
    /// Scans `upstreamRoot` and returns sorted relative paths and extracted `pub` symbols.
    public static func scanUpstream(at upstreamRoot: URL) throws -> UpstreamScanResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: upstreamRoot.path) else {
            throw ParityError.fileNotFound(upstreamRoot.path)
        }

        let crates = discoverTopLevelDirs(under: upstreamRoot.appendingPathComponent("crates"), prefix: "crates")
        let themes = discoverTopLevelDirs(under: upstreamRoot.appendingPathComponent("themes"), prefix: "themes")
        let examples = discoverTopLevelDirs(under: upstreamRoot.appendingPathComponent("examples"), prefix: "examples")

        var rustFiles: [String] = []
        var wgslFiles: [String] = []
        var symbols: [RustSymbol] = []

        let rootPath = upstreamRoot.standardizedFileURL.path
        for section in ["crates", "themes", "examples"] {
            let sectionURL = upstreamRoot.appendingPathComponent(section)
            guard fm.fileExists(atPath: sectionURL.path) else { continue }
            guard let enumerator = fm.enumerator(
                at: sectionURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                let name = fileURL.lastPathComponent
                if name == "target" || name == ".git" || name == "node_modules" {
                    enumerator.skipDescendants()
                    continue
                }
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { continue }

                let relPath = relativePath(of: fileURL, fromRootPath: rootPath)
                let ext = fileURL.pathExtension.lowercased()
                if ext == "rs" {
                    rustFiles.append(relPath)
                    if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
                        symbols.append(contentsOf: scanSymbols(in: text, file: relPath))
                    }
                } else if ext == "wgsl" {
                    wgslFiles.append(relPath)
                }
            }
        }

        return UpstreamScanResult(
            crates: crates.sorted(),
            themes: themes.sorted(),
            examples: examples.sorted(),
            rustFiles: rustFiles.sorted(),
            wgslFiles: wgslFiles.sorted(),
            symbols: symbols
        )
    }

    /// Scans Rust source text for `pub struct`, `pub enum`, `pub trait`, and `pub fn` declarations.
    public static func scanSymbols(in source: String, file: String) -> [RustSymbol] {
        var result: [RustSymbol] = []
        var inBlockComment = false

        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (idx, rawLine) in lines.enumerated() {
            var line = String(rawLine)

            // Strip block comments naively while preserving line numbers.
            if inBlockComment {
                if let endRange = line.range(of: "*/") {
                    line = String(line[endRange.upperBound...])
                    inBlockComment = false
                } else {
                    continue
                }
            }
            while let startRange = line.range(of: "/*") {
                if let endRange = line.range(of: "*/", range: startRange.upperBound..<line.endIndex) {
                    line.removeSubrange(startRange.lowerBound..<endRange.upperBound)
                } else {
                    line.removeSubrange(startRange.lowerBound..<line.endIndex)
                    inBlockComment = true
                    break
                }
            }

            // Strip line comments.
            if let commentRange = line.range(of: "//") {
                line = String(line[..<commentRange.lowerBound])
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("pub ") || trimmed.hasPrefix("pub(") else { continue }
            // Only match crate-public/external `pub ` (skip `pub(crate)`, `pub(super)`, etc.).
            guard trimmed.hasPrefix("pub ") else { continue }

            if let (kind, name) = parsePubDeclaration(trimmed) {
                result.append(RustSymbol(kind: kind, name: name, file: file, line: idx + 1))
            }
        }
        return result
    }

    private static func parsePubDeclaration(_ trimmed: String) -> (RustSymbolKind, String)? {
        // Tokenize after "pub "
        let rest = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
        let tokens = rest.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return nil }

        var i = 0
        // Optional qualifiers before `fn` / `struct` / `enum` / `trait`
        let qualifiers: Set<String> = ["async", "unsafe", "const"]
        while i < tokens.count && qualifiers.contains(tokens[i]) {
            i += 1
        }
        // Handle `extern "C"`
        if i + 1 < tokens.count && tokens[i] == "extern" && tokens[i + 1].hasPrefix("\"") {
            i += 2
        } else if i < tokens.count && tokens[i] == "extern" {
            i += 1
        }

        guard i + 1 < tokens.count else { return nil }
        let keyword = tokens[i]
        let rawIdent = tokens[i + 1]

        let kind: RustSymbolKind
        switch keyword {
        case "struct": kind = .struct
        case "enum": kind = .enum
        case "trait": kind = .trait
        case "fn": kind = .fn
        default: return nil
        }

        let name = extractIdentifier(from: rawIdent)
        guard !name.isEmpty else { return nil }
        return (kind, name)
    }

    private static func extractIdentifier(from token: String) -> String {
        var ident = ""
        for ch in token {
            if ch.isLetter || ch.isNumber || ch == "_" {
                ident.append(ch)
            } else {
                break
            }
        }
        return ident
    }

    private static func discoverTopLevelDirs(under url: URL, prefix: String) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.compactMap { entry in
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { return nil }
            let name = entry.lastPathComponent
            if name == "target" || name == ".git" { return nil }
            return "\(prefix)/\(name)"
        }
    }

    private static func relativePath(of url: URL, fromRootPath rootPath: String) -> String {
        let full = url.standardizedFileURL.path
        if full.hasPrefix(rootPath + "/") {
            return String(full.dropFirst(rootPath.count + 1))
        }
        return full
    }
}
