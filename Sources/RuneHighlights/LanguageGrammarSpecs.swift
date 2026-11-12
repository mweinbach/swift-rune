import Foundation

/// Interpolation syntax inside string literals.
enum StringInterpolationKind: Sendable {
    case none
    case dollarBrace   // ${...} (JS, TS, Kotlin, Groovy, Scala, Bash, Nix, Terraform)
    case swiftParen    // \(...) (Swift)
    case hashBrace     // #{...} (Ruby, Elixir)
    case curlyBrace    // {...}  (Python f-strings, C# interpolated strings)
}

/// Declarative, table-driven grammar specification for a programming language.
struct LanguageGrammarSpec: Sendable {
    var controlKeywords: Set<String> = []
    var declarationKeywords: Set<String> = []
    var importKeywords: Set<String> = []
    var operatorKeywords: Set<String> = []
    var otherKeywords: Set<String> = []
    var booleans: Set<String> = ["true", "false"]
    var builtinConstants: Set<String> = ["null", "nil", "None"]
    var builtinTypes: Set<String> = []
    var builtinFunctions: Set<String> = []
    var specialVariables: Set<String> = ["self", "this", "super"]
    var caseInsensitiveKeywords: Bool = false

    // Comments
    var slashComments: Bool = true
    var nestedBlockComments: Bool = false
    var hashComments: Bool = false
    var dashComments: Bool = false
    var semicolonComments: Bool = false
    var percentComments: Bool = false
    var exclamationComments: Bool = false
    var customBlockComment: (start: String, end: String, nested: Bool)? = nil

    // Strings
    var doubleQuoteStrings: Bool = true
    var singleQuoteAsString: Bool = false
    var singleQuoteDoubleEscape: Bool = false
    var tripleDoubleQuotes: Bool = false
    var tripleSingleQuotes: Bool = false
    var backtickStrings: Bool = false
    var rustRawStrings: Bool = false
    var swiftRawStrings: Bool = false
    var cppRawStrings: Bool = false
    var csharpVerbatimStrings: Bool = false
    var pythonStringPrefixes: Bool = false
    var interpolation: StringInterpolationKind = .none

    // Attributes / Preprocessor / Specials
    var preprocessorHashes: Bool = false
    var atAttributes: Bool = false
    var zigAtBuiltins: Bool = false
    var rustAttributes: Bool = false
    var doubleBracketAttributes: Bool = false
    var nimPragmas: Bool = false
    var jsxTags: Bool = false
    var regexLiterals: Bool = false
    var rustLifetimes: Bool = false
    var dollarVariables: Bool = false
    var colonSymbols: Bool = false
    var bangMacroCalls: Bool = false

    func classify(
        _ ident: String,
        followedByParen: Bool,
        followedByBang: Bool,
        precededByDeclKeyword: Bool,
        precededByDot: Bool
    ) -> HighlightToken.Kind {
        let key = caseInsensitiveKeywords ? ident.lowercased() : ident

        if controlKeywords.contains(key) { return .keywordControl }
        if declarationKeywords.contains(key) { return .keywordDeclaration }
        if importKeywords.contains(key) { return .keywordImport }
        if operatorKeywords.contains(key) { return .keywordOperator }
        if otherKeywords.contains(key) { return .keyword }
        if booleans.contains(key) { return .boolean }
        if builtinConstants.contains(key) { return .constantBuiltin }
        if specialVariables.contains(key) { return .variableSpecial }
        if builtinTypes.contains(key) { return .typeBuiltin }
        if precededByDeclKeyword { return .functionDefinition }
        if followedByBang && bangMacroCalls { return .function }
        if followedByParen {
            if precededByDot { return .functionMethod }
            return .function
        }
        if builtinFunctions.contains(key) { return .function }
        if precededByDot { return .property }
        if ident.count >= 2, ident.utf8.allSatisfy({ LexerScanner.isUpperASCII($0) || LexerScanner.isDigit($0) || $0 == 0x5F }) {
            if ident.utf8.contains(where: { LexerScanner.isUpperASCII($0) }) {
                return .constant
            }
        }
        if let first = ident.utf8.first, LexerScanner.isUpperASCII(first) {
            return .type
        }
        return .none
    }
}

/// Shared table-driven grammar engine and language specifications.
enum LanguageGrammarSpecs {
    static func lex(_ scanner: inout LexerScanner, spec: LanguageGrammarSpec, language: Language) {
        var expectFuncDef = false
        var canStartRegex = true
        var precededByDot = false

        while !scanner.isAtEnd {
            scanner.skipWhitespace()
            guard let b = scanner.peek() else { break }

            // 1. Custom block comment (e.g. (* *), {- -}, #[ ]#, %{ %})
            if let custom = spec.customBlockComment, scanner.startsWithASCII(custom.start) {
                scanCustomBlockComment(&scanner, startDelim: custom.start, endDelim: custom.end, nested: custom.nested)
                continue
            }

            // 2. Slash comments (//, ///, /* */)
            if spec.slashComments && scanner.startsWith("//") {
                let isDoc = scanner.startsWith("///") && !scanner.startsWith("////")
                scanner.scanLineComment(isDoc: isDoc)
                continue
            }
            if spec.slashComments && scanner.startsWith("/*") {
                scanner.scanBlockComment(nested: spec.nestedBlockComments)
                continue
            }

            // 3. Rust #[...] / #![...] attributes (before hashComments/preprocessor)
            if spec.rustAttributes && (scanner.startsWith("#[") || scanner.startsWith("#![")) {
                let start = scanner.index
                scanner.advance(scanner.startsWith("#![") ? 3 : 2)
                var depth = 1
                while !scanner.isAtEnd && depth > 0 {
                    if scanner.peek() == 0x5B { depth += 1 }
                    else if scanner.peek() == 0x5D { depth -= 1 }
                    scanner.advanceScalar()
                }
                scanner.emit(start..<scanner.index, .attribute)
                canStartRegex = false
                precededByDot = false
                continue
            }

            // 4. Hash / Dash / Semicolon / Percent / Exclamation comments
            if spec.hashComments && b == 0x23 /* # */ {
                let isDoc = scanner.startsWith("##") && !scanner.startsWith("###")
                scanner.scanLineComment(isDoc: isDoc)
                continue
            }
            if spec.dashComments && scanner.startsWith("--") {
                let isDoc = scanner.startsWith("---") && !scanner.startsWith("----")
                scanner.scanLineComment(isDoc: isDoc)
                continue
            }
            if spec.semicolonComments && b == 0x3B /* ; */ {
                let isDoc = scanner.startsWith(";;")
                scanner.scanLineComment(isDoc: isDoc)
                continue
            }
            if spec.percentComments && b == 0x25 /* % */ {
                scanner.scanLineComment(isDoc: false)
                continue
            }
            if spec.exclamationComments && b == 0x21 /* ! */ {
                scanner.scanLineComment(isDoc: false)
                continue
            }

            // 5. Preprocessor (#include, #define, #if, etc.)
            if spec.preprocessorHashes && b == 0x23 /* # */ {
                let start = scanner.index
                scanner.advance(1)
                scanner.skipHorizontalWhitespace()
                let _ = scanner.scanIdentifierRange()
                scanner.emit(start..<scanner.index, .preproc)
                canStartRegex = false
                precededByDot = false
                continue
            }

            // 6. C++ / MSL [[attribute]]
            if spec.doubleBracketAttributes && scanner.startsWith("[[") {
                let start = scanner.index
                scanner.advance(2)
                while !scanner.isAtEnd && !scanner.startsWith("]]") {
                    scanner.advanceScalar()
                }
                if scanner.startsWith("]]") { scanner.advance(2) }
                scanner.emit(start..<scanner.index, .attribute)
                canStartRegex = false
                precededByDot = false
                continue
            }

            // 7. Nim {.pragma.}
            if spec.nimPragmas && scanner.startsWith("{.") {
                let start = scanner.index
                scanner.advance(2)
                while !scanner.isAtEnd && !scanner.startsWith(".}") {
                    scanner.advanceScalar()
                }
                if scanner.startsWith(".}") { scanner.advance(2) }
                scanner.emit(start..<scanner.index, .attribute)
                canStartRegex = false
                precededByDot = false
                continue
            }

            // 8. Swift raw strings #"..."# / #"""..."""#
            if spec.swiftRawStrings && b == 0x23 /* # */ {
                if scanSwiftRawString(&scanner) {
                    canStartRegex = false
                    precededByDot = false
                    continue
                }
            }

            // 9. Rust raw strings r#"..."#, b"...", br#"..."#
            if spec.rustRawStrings && (b == 0x72 || b == 0x62) {
                if scanRustRawString(&scanner) {
                    canStartRegex = false
                    precededByDot = false
                    continue
                }
            }

            // 10. C++ raw strings R"delim(...)delim"
            if spec.cppRawStrings && b == 0x52 /* R */ && scanner.peek(1) == 0x22 /* " */ {
                if scanCppRawString(&scanner) {
                    canStartRegex = false
                    precededByDot = false
                    continue
                }
            }

            // 11. C# verbatim / interpolated strings @"...", $"...", $@"..."
            if spec.csharpVerbatimStrings {
                if (b == 0x40 && scanner.peek(1) == 0x22) ||
                   (b == 0x24 && scanner.peek(1) == 0x40 && scanner.peek(2) == 0x22) ||
                   (b == 0x40 && scanner.peek(1) == 0x24 && scanner.peek(2) == 0x22) {
                    let prefixLen = (b == 0x40 && scanner.peek(1) == 0x22) ? 1 : 2
                    let start = scanner.index
                    scanner.advance(prefixLen + 1)
                    while !scanner.isAtEnd {
                        if scanner.peek() == 0x22 {
                            scanner.advance(1)
                            if scanner.peek() == 0x22 {
                                scanner.advance(1) // escaped ""
                                continue
                            }
                            break
                        }
                        scanner.advanceScalar()
                    }
                    scanner.emit(start..<scanner.index, .string)
                    canStartRegex = false
                    precededByDot = false
                    continue
                }
                if b == 0x24 /* $ */ && scanner.peek(1) == 0x22 /* " */ {
                    scanner.advance(1)
                    scanInterpolatedString(&scanner, quote: 0x22, interpolation: .curlyBrace)
                    canStartRegex = false
                    precededByDot = false
                    continue
                }
            }

            // 12. Python prefixed strings f"...", r"...", b"...", u"...", fr"..."
            if spec.pythonStringPrefixes && isPythonStringPrefix(scanner) {
                let prefixLen = pythonStringPrefixLength(scanner)
                let isRaw = isPythonRawPrefix(scanner, length: prefixLen)
                let isFormatted = isPythonFormatPrefix(scanner, length: prefixLen)
                let prefixStart = scanner.index
                scanner.advance(prefixLen)
                scanner.emit(prefixStart..<scanner.index, .stringSpecial)
                let q = scanner.peek() ?? 0x22
                if scanner.peek(1) == q && scanner.peek(2) == q {
                    scanner.scanTripleQuotedString(quote: q, allowEscapes: !isRaw)
                } else if isFormatted {
                    scanInterpolatedString(&scanner, quote: q, interpolation: .curlyBrace, allowEscapes: !isRaw, multiline: false)
                } else {
                    scanner.scanQuotedString(quote: q, allowEscapes: !isRaw)
                }
                canStartRegex = false
                precededByDot = false
                continue
            }

            // 13. @attributes or Zig @builtins
            if b == 0x40 /* @ */ {
                if spec.zigAtBuiltins {
                    let start = scanner.index
                    scanner.advance(1)
                    let _ = scanner.scanIdentifierRange()
                    scanner.emit(start..<scanner.index, .function)
                    canStartRegex = false
                    precededByDot = false
                    continue
                }
                if spec.atAttributes {
                    let start = scanner.index
                    scanner.advance(1)
                    let _ = scanner.scanIdentifierRange()
                    scanner.emit(start..<scanner.index, .attribute)
                    canStartRegex = false
                    precededByDot = false
                    continue
                }
            }

            // 14. Triple-quoted strings
            if spec.tripleDoubleQuotes && scanner.startsWith("\"\"\"") {
                scanner.scanTripleQuotedString(quote: 0x22)
                canStartRegex = false
                precededByDot = false
                continue
            }
            if spec.tripleSingleQuotes && scanner.startsWith("'''") {
                scanner.scanTripleQuotedString(quote: 0x27)
                canStartRegex = false
                precededByDot = false
                continue
            }

            // 15. Double-quoted strings
            if spec.doubleQuoteStrings && b == 0x22 /* " */ {
                if spec.interpolation != .none {
                    scanInterpolatedString(&scanner, quote: 0x22, interpolation: spec.interpolation)
                } else {
                    scanner.scanQuotedString(quote: 0x22)
                }
                canStartRegex = false
                precededByDot = false
                continue
            }

            // 16. Backtick strings
            if spec.backtickStrings && b == 0x60 /* ` */ {
                let interp: StringInterpolationKind = (spec.interpolation == .dollarBrace) ? .dollarBrace : .none
                if interp != .none {
                    scanInterpolatedString(&scanner, quote: 0x60, interpolation: interp, multiline: true)
                } else {
                    scanner.scanQuotedString(quote: 0x60, allowEscapes: false, multiline: true)
                }
                canStartRegex = false
                precededByDot = false
                continue
            }

            // 17. Single quotes: string, Rust lifetime, or char literal
            if b == 0x27 /* ' */ {
                if spec.rustLifetimes {
                    scanRustCharOrLifetime(&scanner)
                } else if spec.singleQuoteAsString {
                    if spec.singleQuoteDoubleEscape {
                        scanDoubledSingleQuoteString(&scanner)
                    } else {
                        scanner.scanQuotedString(quote: 0x27)
                    }
                } else {
                    scanner.scanQuotedString(quote: 0x27, allowEscapes: true, multiline: false)
                }
                canStartRegex = false
                precededByDot = false
                continue
            }

            // 18. Regex literals (JS/TS/Ruby)
            if spec.regexLiterals && b == 0x2F /* / */ && canStartRegex && scanner.peek(1) != 0x2F && scanner.peek(1) != 0x2A {
                if scanRegexLiteral(&scanner) {
                    canStartRegex = false
                    precededByDot = false
                    continue
                }
            }

            // 19. JSX tags
            if spec.jsxTags && b == 0x3C /* < */ {
                if scanJSXTagStart(&scanner) {
                    canStartRegex = false
                    precededByDot = false
                    continue
                }
            }

            // 20. Dollar variables ($var, ${var})
            if spec.dollarVariables && b == 0x24 /* $ */ {
                let start = scanner.index
                scanner.advance(1)
                if scanner.peek() == 0x7B /* { */ {
                    scanner.advance(1)
                    let _ = scanner.scanIdentifierRange()
                    if scanner.peek() == 0x7D /* } */ { scanner.advance(1) }
                } else {
                    let _ = scanner.scanIdentifierRange()
                }
                scanner.emit(start..<scanner.index, .variableSpecial)
                canStartRegex = false
                precededByDot = false
                continue
            }

            // 21. Colon symbols (:sym)
            if spec.colonSymbols && b == 0x3A /* : */ && scanner.peek(1) != 0x3A,
               let next = scanner.peek(1), LexerScanner.isIdentStart(next) {
                let start = scanner.index
                scanner.advance(1)
                let _ = scanner.scanIdentifierRange()
                scanner.emit(start..<scanner.index, .stringSpecialSymbol)
                canStartRegex = false
                precededByDot = false
                continue
            }

            // 22. Numbers
            if LexerScanner.isDigit(b) || (b == 0x2E && scanner.peek(1).map(LexerScanner.isDigit) == true) {
                scanner.scanNumber()
                canStartRegex = false
                precededByDot = false
                continue
            }

            // 23. Identifiers & Keywords
            if LexerScanner.isIdentStart(b) {
                let range = scanner.scanIdentifierRange()
                let word = scanner.string(for: range)
                let nextNonWS = scanner.nextNonWhitespaceByte(from: scanner.index)
                let followedByParen = nextNonWS == 0x28 /* ( */
                let followedByBang = scanner.peek() == 0x21 /* ! */

                let kind = spec.classify(
                    word,
                    followedByParen: followedByParen,
                    followedByBang: followedByBang,
                    precededByDeclKeyword: expectFuncDef,
                    precededByDot: precededByDot
                )
                scanner.emit(range, kind)
                if followedByBang && spec.bangMacroCalls && kind == .function {
                    let bangStart = scanner.index
                    scanner.advance(1)
                    scanner.emit(bangStart..<scanner.index, .punctuationSpecial)
                }

                expectFuncDef = (word == "fn" || word == "func" || word == "function" || word == "def" || word == "sub" || word == "proc" || word == "fun")
                canStartRegex = (kind == .keywordControl || kind == .keywordOperator || kind == .keyword)
                precededByDot = false
                continue
            }

            // 24. Punctuation & Operators
            expectFuncDef = false
            if b == 0x28 || b == 0x29 || b == 0x5B || b == 0x5D || b == 0x7B || b == 0x7D {
                let start = scanner.index
                scanner.advance(1)
                scanner.emit(start..<scanner.index, .punctuationBracket)
                canStartRegex = (b == 0x28 || b == 0x5B || b == 0x7B)
                precededByDot = false
            } else if b == 0x2C || b == 0x3B || b == 0x2E || b == 0x3A {
                let start = scanner.index
                if b == 0x3A && scanner.peek(1) == 0x3A {
                    scanner.advance(2)
                    scanner.emit(start..<scanner.index, .punctuationDelimiter)
                } else {
                    scanner.advance(1)
                    scanner.emit(start..<scanner.index, .punctuationDelimiter)
                }
                canStartRegex = (b == 0x2C || b == 0x3B || b == 0x3A)
                precededByDot = (b == 0x2E)
            } else if isOperatorByte(b) {
                let start = scanner.index
                scanner.advance(1)
                while let next = scanner.peek(), isOperatorContinuation(first: b, next: next) {
                    scanner.advance(1)
                }
                scanner.emit(start..<scanner.index, .operator)
                canStartRegex = true
                precededByDot = false
            } else {
                scanner.advanceScalar()
                canStartRegex = false
                precededByDot = false
            }
        }
    }

    // MARK: - Helper Scanners

    private static func scanCustomBlockComment(
        _ scanner: inout LexerScanner,
        startDelim: String,
        endDelim: String,
        nested: Bool
    ) {
        let start = scanner.index
        scanner.advance(startDelim.utf8.count)
        var depth = 1
        while !scanner.isAtEnd && depth > 0 {
            if nested && scanner.startsWithASCII(startDelim) {
                depth += 1
                scanner.advance(startDelim.utf8.count)
            } else if scanner.startsWithASCII(endDelim) {
                depth -= 1
                scanner.advance(endDelim.utf8.count)
            } else {
                scanner.advanceScalar()
            }
        }
        scanner.emit(start..<scanner.index, .comment)
    }

    private static func scanInterpolatedString(
        _ scanner: inout LexerScanner,
        quote: UInt8,
        interpolation: StringInterpolationKind,
        allowEscapes: Bool = true,
        multiline: Bool = false
    ) {
        var segStart = scanner.index
        scanner.advance(1) // opening quote
        while let b = scanner.peek() {
            if !multiline && b == 0x0A {
                break
            }
            if allowEscapes && b == 0x5C /* \ */ {
                if interpolation == .swiftParen && scanner.peek(1) == 0x28 /* ( */ {
                    scanner.emit(segStart..<scanner.index, .string)
                    let openStart = scanner.index
                    scanner.advance(2)
                    scanner.emit(openStart..<scanner.index, .punctuationSpecial)
                    scanBalancedParenInterpolation(&scanner)
                    segStart = scanner.index
                    continue
                }
                scanner.emit(segStart..<scanner.index, .string)
                let escStart = scanner.index
                scanner.advance(1)
                if !scanner.isAtEnd { scanner.advanceScalar() }
                scanner.emit(escStart..<scanner.index, .stringEscape)
                segStart = scanner.index
                continue
            }
            if interpolation == .dollarBrace && b == 0x24 && scanner.peek(1) == 0x7B {
                scanner.emit(segStart..<scanner.index, .string)
                let openStart = scanner.index
                scanner.advance(2)
                scanner.emit(openStart..<scanner.index, .punctuationSpecial)
                scanBalancedBraceInterpolation(&scanner)
                segStart = scanner.index
                continue
            }
            if interpolation == .hashBrace && b == 0x23 && scanner.peek(1) == 0x7B {
                scanner.emit(segStart..<scanner.index, .string)
                let openStart = scanner.index
                scanner.advance(2)
                scanner.emit(openStart..<scanner.index, .punctuationSpecial)
                scanBalancedBraceInterpolation(&scanner)
                segStart = scanner.index
                continue
            }
            if interpolation == .curlyBrace && b == 0x7B {
                if scanner.peek(1) == 0x7B {
                    // escaped {{
                    scanner.emit(segStart..<scanner.index, .string)
                    let escStart = scanner.index
                    scanner.advance(2)
                    scanner.emit(escStart..<scanner.index, .stringEscape)
                    segStart = scanner.index
                    continue
                }
                scanner.emit(segStart..<scanner.index, .string)
                let openStart = scanner.index
                scanner.advance(1)
                scanner.emit(openStart..<scanner.index, .punctuationSpecial)
                scanBalancedBraceInterpolation(&scanner)
                segStart = scanner.index
                continue
            }
            if b == quote {
                scanner.advance(1)
                break
            }
            scanner.advanceScalar()
        }
        scanner.emit(segStart..<scanner.index, .string)
    }

    private static func scanBalancedParenInterpolation(_ scanner: inout LexerScanner) {
        var depth = 1
        let exprStart = scanner.index
        while !scanner.isAtEnd && depth > 0 {
            guard let b = scanner.peek() else { break }
            if b == 0x28 { depth += 1; scanner.advance(1) }
            else if b == 0x29 {
                depth -= 1
                if depth == 0 {
                    if exprStart < scanner.index {
                        scanner.emit(exprStart..<scanner.index, .embedded)
                    }
                    let closeStart = scanner.index
                    scanner.advance(1)
                    scanner.emit(closeStart..<scanner.index, .punctuationSpecial)
                    return
                }
                scanner.advance(1)
            } else if b == 0x22 {
                scanner.scanQuotedString(quote: 0x22)
            } else {
                scanner.advanceScalar()
            }
        }
        if exprStart < scanner.index {
            scanner.emit(exprStart..<scanner.index, .embedded)
        }
    }

    private static func scanBalancedBraceInterpolation(_ scanner: inout LexerScanner) {
        var depth = 1
        let exprStart = scanner.index
        while !scanner.isAtEnd && depth > 0 {
            guard let b = scanner.peek() else { break }
            if b == 0x7B { depth += 1; scanner.advance(1) }
            else if b == 0x7D {
                depth -= 1
                if depth == 0 {
                    if exprStart < scanner.index {
                        scanner.emit(exprStart..<scanner.index, .embedded)
                    }
                    let closeStart = scanner.index
                    scanner.advance(1)
                    scanner.emit(closeStart..<scanner.index, .punctuationSpecial)
                    return
                }
                scanner.advance(1)
            } else if b == 0x22 {
                scanner.scanQuotedString(quote: 0x22)
            } else {
                scanner.advanceScalar()
            }
        }
        if exprStart < scanner.index {
            scanner.emit(exprStart..<scanner.index, .embedded)
        }
    }

    private static func scanSwiftRawString(_ scanner: inout LexerScanner) -> Bool {
        var hashes = 0
        while scanner.peek(hashes) == 0x23 {
            hashes += 1
        }
        guard scanner.peek(hashes) == 0x22 else { return false }
        let start = scanner.index
        scanner.advance(hashes)
        let isTriple = scanner.peek(1) == 0x22 && scanner.peek(2) == 0x22
        scanner.advance(isTriple ? 3 : 1)
        let quoteCount = isTriple ? 3 : 1
        while !scanner.isAtEnd {
            if !isTriple && scanner.peek() == 0x0A { break }
            var matched = true
            for i in 0..<quoteCount where scanner.peek(i) != 0x22 {
                matched = false
                break
            }
            if matched {
                var endHashes = true
                for i in 0..<hashes where scanner.peek(quoteCount + i) != 0x23 {
                    endHashes = false
                    break
                }
                if endHashes {
                    scanner.advance(quoteCount + hashes)
                    break
                }
            }
            scanner.advanceScalar()
        }
        scanner.emit(start..<scanner.index, .string)
        return true
    }

    private static func scanRustRawString(_ scanner: inout LexerScanner) -> Bool {
        var offset = 0
        if scanner.peek() == 0x62 /* b */ { offset += 1 }
        if scanner.peek(offset) == 0x72 /* r */ {
            offset += 1
            var hashes = 0
            while scanner.peek(offset + hashes) == 0x23 {
                hashes += 1
            }
            guard scanner.peek(offset + hashes) == 0x22 else { return false }
            let start = scanner.index
            scanner.advance(offset + hashes + 1)
            while !scanner.isAtEnd {
                if scanner.peek() == 0x22 {
                    var matched = true
                    for i in 1...max(1, hashes) where hashes > 0 {
                        if scanner.peek(i) != 0x23 {
                            matched = false
                            break
                        }
                    }
                    if matched {
                        scanner.advance(1 + hashes)
                        break
                    }
                }
                scanner.advanceScalar()
            }
            scanner.emit(start..<scanner.index, .string)
            return true
        }
        if offset == 1 && scanner.peek(1) == 0x22 {
            scanner.advance(1)
            scanner.scanQuotedString(quote: 0x22)
            return true
        }
        return false
    }

    private static func scanCppRawString(_ scanner: inout LexerScanner) -> Bool {
        let start = scanner.index
        scanner.advance(2) // R"
        var delim: [UInt8] = []
        while let b = scanner.peek(), b != 0x28 /* ( */ {
            if b == 0x0A || delim.count > 16 {
                scanner.index = start
                return false
            }
            delim.append(b)
            scanner.advance(1)
        }
        guard scanner.peek() == 0x28 else {
            scanner.index = start
            return false
        }
        scanner.advance(1)
        while !scanner.isAtEnd {
            if scanner.peek() == 0x29 /* ) */ {
                var matched = true
                for (i, d) in delim.enumerated() {
                    if scanner.peek(1 + i) != d {
                        matched = false
                        break
                    }
                }
                if matched && scanner.peek(1 + delim.count) == 0x22 /* " */ {
                    scanner.advance(2 + delim.count)
                    break
                }
            }
            scanner.advanceScalar()
        }
        scanner.emit(start..<scanner.index, .string)
        return true
    }

    private static func scanDoubledSingleQuoteString(_ scanner: inout LexerScanner) {
        let start = scanner.index
        scanner.advance(1)
        while let b = scanner.peek() {
            if b == 0x0A { break }
            if b == 0x27 {
                scanner.advance(1)
                if scanner.peek() == 0x27 {
                    scanner.advance(1)
                    continue
                }
                break
            }
            scanner.advanceScalar()
        }
        scanner.emit(start..<scanner.index, .string)
    }

    private static func scanRustCharOrLifetime(_ scanner: inout LexerScanner) {
        let start = scanner.index
        scanner.advance(1)
        if scanner.peek() == 0x5C {
            scanner.advance(1)
            if !scanner.isAtEnd { scanner.advanceScalar() }
            if scanner.peek() == 0x27 { scanner.advance(1) }
            scanner.emit(start..<scanner.index, .string)
            return
        }
        if scanner.peek(1) == 0x27 {
            scanner.advanceScalar()
            scanner.advance(1)
            scanner.emit(start..<scanner.index, .string)
            return
        }
        let _ = scanner.scanIdentifierRange()
        scanner.emit(start..<scanner.index, .label)
    }

    private static func scanRegexLiteral(_ scanner: inout LexerScanner) -> Bool {
        let start = scanner.index
        scanner.advance(1)
        var inCharClass = false
        while let b = scanner.peek() {
            if b == 0x0A {
                scanner.index = start
                return false
            }
            if b == 0x5C {
                scanner.advance(1)
                if !scanner.isAtEnd && scanner.peek() != 0x0A {
                    scanner.advanceScalar()
                }
                continue
            }
            if b == 0x5B { inCharClass = true }
            else if b == 0x5D { inCharClass = false }
            else if b == 0x2F && !inCharClass {
                scanner.advance(1)
                while let flag = scanner.peek(), LexerScanner.isAlpha(flag) {
                    scanner.advance(1)
                }
                scanner.emit(start..<scanner.index, .stringRegex)
                return true
            }
            scanner.advanceScalar()
        }
        scanner.index = start
        return false
    }

    private static func scanJSXTagStart(_ scanner: inout LexerScanner) -> Bool {
        let start = scanner.index
        var offset = 1
        if scanner.peek(offset) == 0x2F { offset += 1 }
        guard let first = scanner.peek(offset), LexerScanner.isIdentStart(first) else {
            return false
        }
        scanner.advance(offset)
        let nameRange = scanner.scanIdentifierRange()
        let tagName = scanner.string(for: nameRange)
        let isComponent = tagName.utf8.first.map(LexerScanner.isUpperASCII) ?? false

        scanner.emit(start..<(start + offset), .punctuationBracketJSX)
        scanner.emit(nameRange, isComponent ? .tagComponentJSX : .tagJSX)
        return true
    }

    private static func isPythonStringPrefix(_ scanner: LexerScanner) -> Bool {
        let b0 = scanner.peek(0) ?? 0
        let b1 = scanner.peek(1) ?? 0
        let b2 = scanner.peek(2) ?? 0
        let isPrefixChar: (UInt8) -> Bool = {
            $0 == 0x66 || $0 == 0x46 || $0 == 0x72 || $0 == 0x52 ||
            $0 == 0x62 || $0 == 0x42 || $0 == 0x75 || $0 == 0x55
        }
        if isPrefixChar(b0) && (b1 == 0x22 || b1 == 0x27) { return true }
        if isPrefixChar(b0) && isPrefixChar(b1) && (b2 == 0x22 || b2 == 0x27) { return true }
        return false
    }

    private static func pythonStringPrefixLength(_ scanner: LexerScanner) -> Int {
        let b1 = scanner.peek(1) ?? 0
        return (b1 == 0x22 || b1 == 0x27) ? 1 : 2
    }

    private static func isPythonRawPrefix(_ scanner: LexerScanner, length: Int) -> Bool {
        for i in 0..<length {
            let b = scanner.peek(i) ?? 0
            if b == 0x72 || b == 0x52 { return true }
        }
        return false
    }

    private static func isPythonFormatPrefix(_ scanner: LexerScanner, length: Int) -> Bool {
        for i in 0..<length {
            let b = scanner.peek(i) ?? 0
            if b == 0x66 || b == 0x46 { return true }
        }
        return false
    }

    private static func isOperatorByte(_ b: UInt8) -> Bool {
        switch b {
        case 0x2B, 0x2D, 0x2A, 0x2F, 0x25, 0x3D, 0x21, 0x3C, 0x3E, 0x26, 0x7C, 0x5E, 0x7E, 0x3F:
            return true
        default:
            return false
        }
    }

    private static func isOperatorContinuation(first: UInt8, next: UInt8) -> Bool {
        switch (first, next) {
        case (0x3D, 0x3D), (0x21, 0x3D), (0x3C, 0x3D), (0x3E, 0x3D),
             (0x2B, 0x3D), (0x2D, 0x3D), (0x2A, 0x3D), (0x2F, 0x3D),
             (0x25, 0x3D), (0x26, 0x26), (0x7C, 0x7C), (0x2D, 0x3E),
             (0x3D, 0x3E), (0x3C, 0x3C), (0x3E, 0x3E), (0x3F, 0x3F),
             (0x7C, 0x3E), (0x3A, 0x3D), (0x2B, 0x2B), (0x2D, 0x2D),
             (0x2A, 0x2A), (0x2F, 0x2F), (0x3C, 0x2D):
            return true
        default:
            return false
        }
    }

    // MARK: - Specs for Systems, JVM, .NET, Mobile, Shaders

    static func spec(for language: Language) -> LanguageGrammarSpec? {
        switch language {
        case .rust: return rustSpec
        case .swift: return swiftSpec
        case .c: return cSpec
        case .cpp: return cppSpec
        case .c3: return c3Spec
        case .cuda: return cudaSpec
        case .objectiveC: return objectiveCSpec
        case .go: return goSpec
        case .zig: return zigSpec
        case .nim: return nimSpec
        case .java: return javaSpec
        case .kotlin: return kotlinSpec
        case .scala: return scalaSpec
        case .groovy: return groovySpec
        case .csharp: return csharpSpec
        case .dart: return dartSpec
        case .solidity: return soliditySpec
        case .pascal: return pascalSpec
        case .fortran, .fortranFixedForm: return fortranSpec
        case .wgsl: return wgslSpec
        case .msl: return mslSpec
        case .glsl: return glslSpec
        case .hlsl: return hlslSpec
        case .gdshader: return gdshaderSpec
        case .gdscript: return gdscriptSpec
        default: return nil
        }
    }

    // MARK: Individual Language Specs

    private static let rustSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "else", "match", "for", "while", "loop", "break", "continue", "return", "yield", "await"],
        declarationKeywords: ["fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl", "type", "pub", "async", "unsafe", "extern", "macro_rules"],
        importKeywords: ["use", "mod", "crate"],
        operatorKeywords: ["as", "in", "where", "dyn", "ref", "move"],
        otherKeywords: ["default", "raw"],
        booleans: ["true", "false"],
        builtinConstants: ["Some", "None", "Ok", "Err"],
        builtinTypes: ["bool", "char", "str", "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128", "isize", "f32", "f64", "String", "Vec", "Option", "Result", "Box", "Rc", "Arc", "Self"],
        specialVariables: ["self", "Self"],
        nestedBlockComments: true,
        rustRawStrings: true,
        rustAttributes: true,
        rustLifetimes: true,
        bangMacroCalls: true
    )

    private static let swiftSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "else", "switch", "case", "default", "for", "while", "repeat", "break", "continue", "return", "throw", "throws", "rethrows", "try", "catch", "do", "guard", "defer", "where", "await", "fallthrough"],
        declarationKeywords: ["func", "let", "var", "struct", "class", "enum", "protocol", "extension", "typealias", "associatedtype", "init", "deinit", "subscript", "operator", "precedencegroup", "actor", "macro", "public", "private", "fileprivate", "internal", "open", "static", "final", "override", "mutating", "nonmutating", "async", "weak", "unowned", "lazy", "inout", "consuming", "borrowing", "nonisolated", "isolated"],
        importKeywords: ["import"],
        operatorKeywords: ["as", "is", "in", "some", "any"],
        otherKeywords: ["get", "set", "willSet", "didSet", "convenience", "required", "dynamic", "optional", "indirect"],
        booleans: ["true", "false"],
        builtinConstants: ["nil"],
        builtinTypes: ["Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Float", "Double", "Bool", "String", "Character", "Array", "Dictionary", "Set", "Optional", "Result", "Error", "Void", "Never", "Any", "AnyObject", "Sendable", "Self"],
        specialVariables: ["self", "Self", "super"],
        nestedBlockComments: true,
        tripleDoubleQuotes: true,
        swiftRawStrings: true,
        interpolation: .swiftParen,
        preprocessorHashes: true,
        atAttributes: true
    )

    private static let cSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "else", "switch", "case", "default", "for", "while", "do", "break", "continue", "return", "goto"],
        declarationKeywords: ["struct", "enum", "union", "typedef", "static", "extern", "inline", "const", "volatile", "restrict", "register", "auto", "signed", "unsigned"],
        importKeywords: [],
        operatorKeywords: ["sizeof", "_Alignof"],
        otherKeywords: ["_Atomic", "_Bool", "_Complex", "_Generic", "_Noreturn", "_Static_assert", "_Thread_local"],
        booleans: ["true", "false"],
        builtinConstants: ["NULL", "stdin", "stdout", "stderr"],
        builtinTypes: ["void", "char", "short", "int", "long", "float", "double", "bool", "size_t", "ssize_t", "ptrdiff_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "FILE"],
        specialVariables: [],
        preprocessorHashes: true
    )

    private static let cppSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "else", "switch", "case", "default", "for", "while", "do", "break", "continue", "return", "goto", "try", "catch", "throw", "co_await", "co_return", "co_yield"],
        declarationKeywords: ["class", "struct", "enum", "union", "namespace", "template", "typename", "using", "typedef", "constexpr", "consteval", "constinit", "const", "static", "extern", "inline", "virtual", "override", "final", "explicit", "friend", "mutable", "volatile", "public", "private", "protected", "concept", "requires", "auto", "decltype", "noexcept"],
        importKeywords: ["import", "module", "export"],
        operatorKeywords: ["sizeof", "alignof", "typeid", "new", "delete", "and", "or", "not", "xor", "bitand", "bitor", "compl"],
        otherKeywords: ["static_cast", "dynamic_cast", "const_cast", "reinterpret_cast", "static_assert"],
        booleans: ["true", "false"],
        builtinConstants: ["nullptr", "NULL"],
        builtinTypes: ["void", "bool", "char", "wchar_t", "char8_t", "char16_t", "char32_t", "short", "int", "long", "float", "double", "signed", "unsigned", "size_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "string", "vector", "map", "unordered_map", "set", "optional", "variant", "unique_ptr", "shared_ptr", "span", "string_view"],
        specialVariables: ["this"],
        cppRawStrings: true,
        preprocessorHashes: true,
        doubleBracketAttributes: true
    )

    private static let c3Spec = LanguageGrammarSpec(
        controlKeywords: ["if", "else", "switch", "case", "default", "for", "foreach", "foreach_r", "while", "do", "break", "continue", "return", "nextcase", "defer", "try", "catch"],
        declarationKeywords: ["fn", "macro", "struct", "union", "enum", "bitstruct", "fault", "interface", "def", "distinct", "const", "var", "static", "extern", "inline", "local", "tlocal"],
        importKeywords: ["import", "module"],
        operatorKeywords: ["sizeof", "alignof", "offsetof", "lengthof"],
        otherKeywords: ["asm", "assert", "any"],
        booleans: ["true", "false"],
        builtinConstants: ["null"],
        builtinTypes: ["void", "bool", "char", "ichar", "short", "ushort", "int", "uint", "long", "ulong", "int128", "uint128", "float", "double", "float16", "float128", "isz", "usz", "iptr", "uptr", "anyfault", "typeid", "String"],
        specialVariables: ["self"],
        nestedBlockComments: true,
        atAttributes: true
    )

    private static let cudaSpec = LanguageGrammarSpec(
        controlKeywords: cppSpec.controlKeywords,
        declarationKeywords: cppSpec.declarationKeywords.union(["__global__", "__device__", "__host__", "__shared__", "__constant__", "__managed__", "__restrict__", "__noinline__", "__forceinline__"]),
        importKeywords: cppSpec.importKeywords,
        operatorKeywords: cppSpec.operatorKeywords,
        otherKeywords: cppSpec.otherKeywords,
        booleans: ["true", "false"],
        builtinConstants: ["nullptr", "NULL", "threadIdx", "blockIdx", "blockDim", "gridDim", "warpSize"],
        builtinTypes: cppSpec.builtinTypes.union(["dim3", "float2", "float3", "float4", "int2", "int3", "int4", "cudaError_t", "cudaStream_t"]),
        specialVariables: ["this"],
        cppRawStrings: true,
        preprocessorHashes: true,
        doubleBracketAttributes: true
    )

    private static let objectiveCSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "else", "switch", "case", "default", "for", "while", "do", "break", "continue", "return", "goto", "@try", "@catch", "@finally", "@throw", "@synchronized", "@autoreleasepool"],
        declarationKeywords: ["struct", "enum", "union", "typedef", "static", "extern", "inline", "const", "volatile", "@interface", "@implementation", "@protocol", "@end", "@property", "@synthesize", "@dynamic", "@class", "@public", "@private", "@protected", "@package", "@optional", "@required", "nonatomic", "atomic", "strong", "weak", "copy", "assign", "readonly", "readwrite", "nullable", "nonnull"],
        importKeywords: ["@import"],
        operatorKeywords: ["sizeof", "@selector", "@encode", "@available"],
        otherKeywords: ["in", "out", "inout", "bycopy", "byref", "oneway"],
        booleans: ["YES", "NO", "true", "false"],
        builtinConstants: ["nil", "Nil", "NULL", "NSNotFound"],
        builtinTypes: ["void", "id", "Class", "SEL", "IMP", "BOOL", "NSInteger", "NSUInteger", "CGFloat", "NSString", "NSArray", "NSDictionary", "NSSet", "NSNumber", "NSObject", "NSError", "char", "short", "int", "long", "float", "double"],
        specialVariables: ["self", "super"],
        preprocessorHashes: true,
        atAttributes: true
    )

    private static let goSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "else", "switch", "case", "default", "for", "range", "break", "continue", "return", "goto", "select", "defer", "go", "fallthrough"],
        declarationKeywords: ["func", "var", "const", "type", "struct", "interface", "map", "chan"],
        importKeywords: ["import", "package"],
        operatorKeywords: [],
        otherKeywords: [],
        booleans: ["true", "false"],
        builtinConstants: ["nil", "iota"],
        builtinTypes: ["bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int", "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr", "any", "comparable"],
        builtinFunctions: ["append", "cap", "clear", "close", "complex", "copy", "delete", "imag", "len", "make", "max", "min", "new", "panic", "print", "println", "real", "recover"],
        specialVariables: [],
        backtickStrings: true
    )

    private static let zigSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "else", "switch", "for", "while", "break", "continue", "return", "defer", "errdefer", "try", "catch", "orelse", "resume", "suspend", "nosuspend", "await", "async"],
        declarationKeywords: ["fn", "const", "var", "struct", "enum", "union", "error", "pub", "extern", "export", "inline", "noinline", "comptime", "packed", "align", "threadlocal", "volatile", "allowzero", "anytype", "test"],
        importKeywords: ["usingnamespace"],
        operatorKeywords: ["and", "or"],
        otherKeywords: ["asm", "unreachable", "linksection", "callconv", "noalias"],
        booleans: ["true", "false"],
        builtinConstants: ["null", "undefined"],
        builtinTypes: ["bool", "void", "noreturn", "type", "anyerror", "anyframe", "anyopaque", "comptime_int", "comptime_float", "usize", "isize", "f16", "f32", "f64", "f80", "f128", "u8", "u16", "u32", "u64", "u128", "i8", "i16", "i32", "i64", "i128", "c_char", "c_short", "c_ushort", "c_int", "c_uint", "c_long", "c_ulong"],
        specialVariables: [],
        zigAtBuiltins: true
    )

    private static let nimSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "elif", "else", "case", "of", "for", "while", "break", "continue", "return", "yield", "try", "except", "finally", "raise", "defer", "when", "block"],
        declarationKeywords: ["proc", "func", "method", "iterator", "converter", "template", "macro", "let", "var", "const", "type", "object", "enum", "tuple", "concept", "distinct", "ref", "ptr", "static", "mixin", "bind"],
        importKeywords: ["import", "from", "export", "include"],
        operatorKeywords: ["and", "or", "not", "xor", "shl", "shr", "div", "mod", "in", "notin", "is", "isnot", "as", "addr", "cast"],
        otherKeywords: ["do", "discard", "asm", "using", "nil"],
        booleans: ["true", "false", "on", "off"],
        builtinConstants: ["nil"],
        builtinTypes: ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "float", "float32", "float64", "bool", "char", "string", "cstring", "seq", "array", "openArray", "set", "Table", "Option", "Result", "void", "auto", "any"],
        specialVariables: ["result"],
        slashComments: false,
        hashComments: true,
        customBlockComment: (start: "#[", end: "]#", nested: true),
        tripleDoubleQuotes: true,
        nimPragmas: true
    )

    private static let javaSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "else", "switch", "case", "default", "for", "while", "do", "break", "continue", "return", "try", "catch", "finally", "throw", "throws", "yield", "when"],
        declarationKeywords: ["class", "interface", "enum", "record", "extends", "implements", "public", "private", "protected", "static", "final", "abstract", "synchronized", "volatile", "transient", "native", "strictfp", "sealed", "non-sealed", "permits", "var", "void"],
        importKeywords: ["import", "package", "module", "requires", "exports", "opens", "uses", "provides"],
        operatorKeywords: ["new", "instanceof"],
        otherKeywords: ["assert"],
        booleans: ["true", "false"],
        builtinConstants: ["null"],
        builtinTypes: ["boolean", "byte", "short", "int", "long", "char", "float", "double", "String", "Object", "Integer", "Long", "Double", "Boolean", "List", "Map", "Set", "Optional"],
        specialVariables: ["this", "super"],
        tripleDoubleQuotes: true,
        atAttributes: true
    )

    private static let kotlinSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "else", "when", "for", "while", "do", "break", "continue", "return", "try", "catch", "finally", "throw"],
        declarationKeywords: ["fun", "val", "var", "class", "interface", "object", "enum", "data", "sealed", "value", "inline", "noinline", "crossinline", "reified", "open", "final", "abstract", "override", "private", "protected", "public", "internal", "companion", "init", "constructor", "typealias", "suspend", "tailrec", "operator", "infix", "external", "expect", "actual", "lateinit", "const", "vararg", "out", "in"],
        importKeywords: ["import", "package"],
        operatorKeywords: ["as", "is", "in", "by", "where"],
        otherKeywords: ["get", "set", "field", "delegate"],
        booleans: ["true", "false"],
        builtinConstants: ["null", "Unit", "Nothing"],
        builtinTypes: ["Boolean", "Byte", "Short", "Int", "Long", "Float", "Double", "Char", "String", "Any", "List", "MutableList", "Map", "MutableMap", "Set", "MutableSet", "Pair", "Triple", "Result", "Sequence"],
        specialVariables: ["this", "super", "it"],
        nestedBlockComments: true,
        tripleDoubleQuotes: true,
        interpolation: .dollarBrace,
        atAttributes: true
    )

    private static let scalaSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "then", "else", "match", "case", "for", "while", "do", "yield", "return", "try", "catch", "finally", "throw"],
        declarationKeywords: ["def", "val", "var", "lazy", "class", "trait", "object", "enum", "type", "given", "using", "extension", "derives", "export", "extends", "with", "override", "abstract", "final", "sealed", "implicit", "private", "protected", "inline", "opaque", "transparent", "open"],
        importKeywords: ["import", "package"],
        operatorKeywords: ["new", "as"],
        otherKeywords: ["macro"],
        booleans: ["true", "false"],
        builtinConstants: ["null", "None", "Nil"],
        builtinTypes: ["Boolean", "Byte", "Short", "Int", "Long", "Float", "Double", "Char", "String", "Unit", "Any", "AnyVal", "AnyRef", "Nothing", "Option", "Some", "Either", "Try", "Future", "List", "Seq", "Vector", "Map", "Set"],
        specialVariables: ["this", "super"],
        nestedBlockComments: true,
        tripleDoubleQuotes: true,
        interpolation: .dollarBrace,
        atAttributes: true
    )

    private static let groovySpec = LanguageGrammarSpec(
        controlKeywords: ["if", "else", "switch", "case", "default", "for", "while", "do", "break", "continue", "return", "try", "catch", "finally", "throw"],
        declarationKeywords: ["def", "class", "interface", "trait", "enum", "extends", "implements", "public", "private", "protected", "static", "final", "abstract", "synchronized", "transient", "volatile", "void", "var"],
        importKeywords: ["import", "package"],
        operatorKeywords: ["as", "in", "instanceof", "new"],
        otherKeywords: ["assert"],
        booleans: ["true", "false"],
        builtinConstants: ["null"],
        builtinTypes: ["boolean", "byte", "short", "int", "long", "char", "float", "double", "String", "Object", "List", "Map", "Set", "Closure"],
        specialVariables: ["this", "super", "it"],
        singleQuoteAsString: true,
        tripleDoubleQuotes: true,
        tripleSingleQuotes: true,
        interpolation: .dollarBrace,
        atAttributes: true
    )

    private static let csharpSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "else", "switch", "case", "default", "for", "foreach", "while", "do", "break", "continue", "return", "yield", "goto", "try", "catch", "finally", "throw", "when", "await"],
        declarationKeywords: ["class", "struct", "interface", "enum", "record", "delegate", "event", "namespace", "var", "const", "readonly", "static", "public", "private", "protected", "internal", "virtual", "override", "abstract", "sealed", "partial", "async", "unsafe", "extern", "volatile", "fixed", "ref", "out", "in", "params", "required", "init"],
        importKeywords: ["using"],
        operatorKeywords: ["as", "is", "new", "typeof", "sizeof", "nameof", "stackalloc", "checked", "unchecked", "and", "or", "not"],
        otherKeywords: ["get", "set", "add", "remove", "value", "where", "select", "from", "orderby", "group", "into", "join", "let", "lock"],
        booleans: ["true", "false"],
        builtinConstants: ["null", "default"],
        builtinTypes: ["bool", "byte", "sbyte", "char", "decimal", "double", "float", "int", "uint", "nint", "nuint", "long", "ulong", "short", "ushort", "object", "string", "dynamic", "void", "Task", "ValueTask", "List", "Dictionary", "IEnumerable", "Span"],
        specialVariables: ["this", "base"],
        tripleDoubleQuotes: true,
        csharpVerbatimStrings: true,
        preprocessorHashes: true
    )

    private static let dartSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "else", "switch", "case", "default", "for", "while", "do", "break", "continue", "return", "try", "on", "catch", "finally", "throw", "rethrow", "await", "yield", "assert"],
        declarationKeywords: ["class", "mixin", "enum", "extension", "typedef", "var", "final", "const", "late", "static", "abstract", "sealed", "base", "interface", "final", "async", "sync", "factory", "operator", "external", "covariant", "required", "void"],
        importKeywords: ["import", "export", "library", "part", "show", "hide", "deferred"],
        operatorKeywords: ["as", "is", "new"],
        otherKeywords: ["extends", "implements", "with", "get", "set"],
        booleans: ["true", "false"],
        builtinConstants: ["null"],
        builtinTypes: ["int", "double", "num", "bool", "String", "List", "Map", "Set", "Object", "dynamic", "Never", "Future", "Stream", "Iterable", "Duration", "DateTime"],
        specialVariables: ["this", "super"],
        singleQuoteAsString: true,
        tripleDoubleQuotes: true,
        tripleSingleQuotes: true,
        interpolation: .dollarBrace,
        atAttributes: true
    )

    private static let soliditySpec = LanguageGrammarSpec(
        controlKeywords: ["if", "else", "for", "while", "do", "break", "continue", "return", "try", "catch", "revert", "require", "assert"],
        declarationKeywords: ["pragma", "contract", "interface", "library", "struct", "enum", "function", "modifier", "event", "error", "constructor", "fallback", "receive", "mapping", "type", "using", "public", "private", "internal", "external", "pure", "view", "payable", "virtual", "override", "abstract", "immutable", "constant", "indexed", "memory", "storage", "calldata"],
        importKeywords: ["import", "from", "as"],
        operatorKeywords: ["new", "delete", "is"],
        otherKeywords: ["emit", "unchecked", "assembly", "returns"],
        booleans: ["true", "false"],
        builtinConstants: ["wei", "gwei", "ether", "seconds", "minutes", "hours", "days", "weeks"],
        builtinTypes: ["bool", "string", "bytes", "address", "uint", "int", "uint8", "uint16", "uint32", "uint64", "uint128", "uint256", "int8", "int16", "int32", "int64", "int128", "int256", "bytes1", "bytes4", "bytes32"],
        specialVariables: ["msg", "block", "tx", "this", "super"]
    )

    private static let pascalSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "then", "else", "case", "of", "for", "to", "downto", "while", "do", "repeat", "until", "break", "continue", "exit", "try", "except", "finally", "raise", "with", "goto"],
        declarationKeywords: ["program", "unit", "library", "procedure", "function", "constructor", "destructor", "property", "type", "var", "const", "resourcestring", "class", "record", "object", "interface", "array", "set", "file", "begin", "end", "public", "private", "protected", "published", "virtual", "override", "abstract", "inline", "overload", "static", "out", "packed"],
        importKeywords: ["uses", "implementation", "initialization", "finalization"],
        operatorKeywords: ["and", "or", "not", "xor", "div", "mod", "shl", "shr", "in", "is", "as"],
        otherKeywords: ["inherited", "nil"],
        booleans: ["true", "false"],
        builtinConstants: ["nil"],
        builtinTypes: ["integer", "cardinal", "int64", "uint64", "byte", "word", "dword", "boolean", "char", "string", "ansistring", "unicodestring", "real", "double", "single", "extended", "pointer", "tobject"],
        specialVariables: ["self", "result"],
        caseInsensitiveKeywords: true,
        slashComments: true,
        customBlockComment: (start: "(*", end: "*)", nested: false),
        doubleQuoteStrings: false,
        singleQuoteAsString: true,
        singleQuoteDoubleEscape: true
    )

    private static let fortranSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "then", "else", "elseif", "endif", "select", "case", "default", "do", "enddo", "while", "cycle", "exit", "return", "stop", "goto", "where", "elsewhere", "forall"],
        declarationKeywords: ["program", "end", "module", "submodule", "subroutine", "function", "interface", "type", "class", "implicit", "none", "parameter", "allocatable", "pointer", "target", "intent", "in", "out", "inout", "optional", "save", "public", "private", "pure", "elemental", "recursive", "dimension", "contains", "data", "common"],
        importKeywords: ["use", "only", "include", "import"],
        operatorKeywords: [],
        otherKeywords: ["call", "allocate", "deallocate", "nullify", "print", "read", "write", "open", "close"],
        booleans: [".true.", ".false."],
        builtinConstants: [],
        builtinTypes: ["integer", "real", "double", "precision", "complex", "logical", "character"],
        specialVariables: [],
        caseInsensitiveKeywords: true,
        slashComments: false,
        exclamationComments: true,
        singleQuoteAsString: true,
        singleQuoteDoubleEscape: true
    )

    private static let wgslSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "else", "switch", "case", "default", "for", "while", "loop", "continuing", "break", "continue", "return", "discard"],
        declarationKeywords: ["fn", "let", "var", "const", "override", "struct", "alias", "enable", "requires", "diagnostic"],
        importKeywords: [],
        operatorKeywords: [],
        otherKeywords: ["uniform", "storage", "workgroup", "private", "function", "read", "write", "read_write"],
        booleans: ["true", "false"],
        builtinConstants: [],
        builtinTypes: ["bool", "i32", "u32", "f32", "f16", "vec2", "vec3", "vec4", "mat2x2", "mat3x3", "mat4x4", "array", "ptr", "atomic", "sampler", "sampler_comparison", "texture_1d", "texture_2d", "texture_3d", "texture_cube", "vec2f", "vec3f", "vec4f", "vec2i", "vec3i", "vec4i", "vec2u", "vec3u", "vec4u", "mat4x4f"],
        specialVariables: [],
        nestedBlockComments: true,
        atAttributes: true
    )

    private static let mslSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "else", "switch", "case", "default", "for", "while", "do", "break", "continue", "return", "discard_fragment"],
        declarationKeywords: ["kernel", "vertex", "fragment", "mesh", "object", "struct", "class", "enum", "namespace", "using", "typedef", "const", "static", "inline", "constexpr"],
        importKeywords: [],
        operatorKeywords: ["sizeof", "alignof"],
        otherKeywords: ["constant", "device", "thread", "threadgroup", "threadgroup_imageblock", "ray_data", "object_data"],
        booleans: ["true", "false"],
        builtinConstants: ["nullptr", "NULL"],
        builtinTypes: ["void", "bool", "char", "uchar", "short", "ushort", "int", "uint", "long", "ulong", "half", "float", "float2", "float3", "float4", "half2", "half3", "half4", "int2", "int3", "int4", "uint2", "uint3", "uint4", "float2x2", "float3x3", "float4x4", "texture2d", "texture3d", "texturecube", "sampler", "metal"],
        specialVariables: ["this"],
        preprocessorHashes: true,
        doubleBracketAttributes: true
    )

    private static let glslSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "else", "switch", "case", "default", "for", "while", "do", "break", "continue", "return", "discard"],
        declarationKeywords: ["struct", "layout", "in", "out", "inout", "uniform", "buffer", "shared", "const", "flat", "smooth", "noperspective", "centroid", "sample", "invariant", "precise", "highp", "mediump", "lowp", "precision", "subroutine"],
        importKeywords: [],
        operatorKeywords: [],
        otherKeywords: [],
        booleans: ["true", "false"],
        builtinConstants: ["gl_Position", "gl_FragCoord", "gl_VertexID", "gl_InstanceID", "gl_GlobalInvocationID", "gl_LocalInvocationID", "gl_WorkGroupID"],
        builtinTypes: ["void", "bool", "int", "uint", "float", "double", "vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4", "uvec2", "uvec3", "uvec4", "bvec2", "bvec3", "bvec4", "mat2", "mat3", "mat4", "sampler2D", "sampler3D", "samplerCube", "image2D"],
        specialVariables: [],
        preprocessorHashes: true
    )

    private static let hlslSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "else", "switch", "case", "default", "for", "while", "do", "break", "continue", "return", "discard"],
        declarationKeywords: ["struct", "cbuffer", "tbuffer", "register", "packoffset", "in", "out", "inout", "uniform", "const", "static", "extern", "inline", "groupshared", "nointerpolation", "linear", "centroid", "noperspective", "sample", "row_major", "column_major", "typedef", "namespace"],
        importKeywords: [],
        operatorKeywords: [],
        otherKeywords: ["technique", "pass", "compile"],
        booleans: ["true", "false"],
        builtinConstants: ["NULL"],
        builtinTypes: ["void", "bool", "int", "uint", "dword", "half", "float", "double", "min16float", "float2", "float3", "float4", "half2", "half3", "half4", "int2", "int3", "int4", "uint2", "uint3", "uint4", "float2x2", "float3x3", "float4x4", "matrix", "vector", "Texture2D", "Texture3D", "TextureCube", "RWTexture2D", "SamplerState", "StructuredBuffer", "RWStructuredBuffer"],
        specialVariables: [],
        preprocessorHashes: true,
        doubleBracketAttributes: true
    )

    private static let gdshaderSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "else", "switch", "case", "default", "for", "while", "do", "break", "continue", "return", "discard"],
        declarationKeywords: ["shader_type", "render_mode", "struct", "uniform", "varying", "const", "in", "out", "inout", "flat", "smooth", "lowp", "mediump", "highp", "group_uniforms", "global", "instance"],
        importKeywords: [],
        operatorKeywords: [],
        otherKeywords: ["hint_range", "hint_color", "source_color", "filter_linear", "repeat_enable"],
        booleans: ["true", "false"],
        builtinConstants: ["PI", "TAU", "E", "FRAGCOORD", "UV", "VERTEX", "NORMAL", "COLOR", "ALBEDO", "TIME"],
        builtinTypes: ["void", "bool", "int", "uint", "float", "vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4", "uvec2", "uvec3", "uvec4", "bvec2", "bvec3", "bvec4", "mat2", "mat3", "mat4", "sampler2D", "sampler3D", "samplerCube"],
        specialVariables: [],
        preprocessorHashes: true
    )

    private static let gdscriptSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "elif", "else", "for", "while", "match", "break", "continue", "return", "pass", "await", "yield"],
        declarationKeywords: ["func", "var", "const", "enum", "class", "class_name", "extends", "signal", "static", "tool"],
        importKeywords: ["preload", "load"],
        operatorKeywords: ["and", "or", "not", "in", "is", "as"],
        otherKeywords: ["breakpoint", "assert"],
        booleans: ["true", "false"],
        builtinConstants: ["null", "PI", "TAU", "INF", "NAN"],
        builtinTypes: ["bool", "int", "float", "String", "Vector2", "Vector2i", "Vector3", "Vector3i", "Vector4", "Color", "Rect2", "Transform2D", "Transform3D", "Basis", "Quaternion", "Array", "Dictionary", "Node", "Node2D", "Node3D", "Resource", "Variant", "void"],
        specialVariables: ["self", "super"],
        slashComments: false,
        hashComments: true,
        singleQuoteAsString: true,
        tripleDoubleQuotes: true,
        tripleSingleQuotes: true,
        atAttributes: true
    )
}
