import Foundation

/// Zero-dependency syntax highlighter producing Zed-compatible `HighlightSpan`s.
public struct Highlighter: Sendable {
    public init() {}

    /// Highlights `source` using the lexer for `language`.
    /// Returns ordered, non-overlapping UTF-8 byte-range spans. Empty for `.plain` or empty input.
    public func highlight(_ source: String, language: Language) -> [HighlightSpan] {
        guard language != .plain, !source.isEmpty else {
            return []
        }
        var scanner = LexerScanner(source)
        switch language {
        case .json, .jsonl:
            MarkupDataLexers.lexJSON(&scanner, allowComments: false)
        case .json5:
            MarkupDataLexers.lexJSON(&scanner, allowComments: true)
        case .toml:
            MarkupDataLexers.lexTOML(&scanner)
        case .yaml:
            MarkupDataLexers.lexYAML(&scanner)
        case .markdown, .mdx:
            MarkupDataLexers.lexMarkdown(&scanner)
        case .bash:
            MarkupDataLexers.lexBash(&scanner)
        case .html, .xml, .angularHTML, .astro, .svelte, .vue:
            MarkupDataLexers.lexHTML(&scanner)
        case .css, .scss, .sass, .less:
            MarkupDataLexers.lexCSS(&scanner, allowLineComments: language != .css)
        case .sql:
            MarkupDataLexers.lexSQL(&scanner)
        case .diff:
            MarkupDataLexers.lexDiff(&scanner)
        default:
            if FunctionalAndScriptingLexers.lex(&scanner, language: language) {
                break
            }
            if ConfigAndQueryLexers.lex(&scanner, language: language) {
                break
            }
            if let spec = LanguageGrammarSpecs.spec(for: language) {
                LanguageGrammarSpecs.lex(&scanner, spec: spec, language: language)
                break
            }
            CLikeLexers.lex(&scanner, language: language)
        }
        return scanner.spans
    }
}

/// Incremental streaming highlighter that caches completed lines and re-lexes only appended text.
public struct HighlightStream: Sendable {
    public let language: Language
    private let highlighter = Highlighter()
    private var committedText: String = ""
    private var committedSpans: [HighlightSpan] = []

    public init(language: Language) {
        self.language = language
    }

    /// Returns `true` when `source` extends the previously committed prefix.
    public func continues(_ source: String) -> Bool {
        !committedText.isEmpty && source.hasPrefix(committedText)
    }

    /// Highlights `source`, reusing cached spans for unchanged leading lines when possible.
    public mutating func highlight(_ source: String) -> [HighlightSpan] {
        guard language != .plain, !source.isEmpty else {
            committedText = ""
            committedSpans = []
            return []
        }

        if !continues(source) {
            committedText = ""
            committedSpans = []
        }

        let lastNewlineByte: Int? = source.utf8.lastIndex(of: 0x0A).map { idx in
            source.utf8.distance(from: source.utf8.startIndex, to: idx) + 1
        }

        let committedBytes = committedText.utf8.count
        if let splitByte = lastNewlineByte, splitByte > committedBytes {
            let chunkStart = source.utf8.index(source.utf8.startIndex, offsetBy: committedBytes)
            let chunkEnd = source.utf8.index(source.utf8.startIndex, offsetBy: splitByte)
            let chunk = String(source[chunkStart..<chunkEnd])
            let chunkSpans = highlighter.highlight(chunk, language: language)
            for span in chunkSpans {
                committedSpans.append(
                    HighlightSpan(
                        utf8Range: (span.utf8Range.lowerBound + committedBytes)..<(span.utf8Range.upperBound + committedBytes),
                        token: span.token
                    )
                )
            }
            committedText.append(chunk)
        }

        let tailStartByte = committedText.utf8.count
        let totalBytes = source.utf8.count
        if tailStartByte >= totalBytes {
            return committedSpans
        }

        let tailStartIndex = source.utf8.index(source.utf8.startIndex, offsetBy: tailStartByte)
        let tail = String(source[tailStartIndex...])
        var result = committedSpans
        for span in highlighter.highlight(tail, language: language) {
            result.append(
                HighlightSpan(
                    utf8Range: (span.utf8Range.lowerBound + tailStartByte)..<(span.utf8Range.upperBound + tailStartByte),
                    token: span.token
                )
            )
        }
        return result
    }
}
