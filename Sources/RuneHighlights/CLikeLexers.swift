import Foundation

struct CLikeLexicon: Sendable {
    var controlKeywords: Set<String> = []
    var declarationKeywords: Set<String> = []
    var importKeywords: Set<String> = []
    var operatorKeywords: Set<String> = []
    var otherKeywords: Set<String> = []
    var booleans: Set<String> = ["true", "false"]
    var builtinConstants: Set<String> = ["null", "nil", "None"]
    var builtinTypes: Set<String> = []
    var specialVariables: Set<String> = ["self", "this", "super"]
    var hashComments: Bool = false
    var slashComments: Bool = true
    var nestedBlockComments: Bool = false
    var tripleDoubleQuotes: Bool = false
    var tripleSingleQuotes: Bool = false
    var backtickStrings: Bool = false
    var preprocessorHashes: Bool = false
    var atAttributes: Bool = false
    var rustAttributes: Bool = false
    var doubleBracketAttributes: Bool = false
    var singleQuoteAsString: Bool = false
    var jsxTags: Bool = false
    var regexLiterals: Bool = false

    func classify(_ ident: String, followedByParen: Bool, precededByDeclKeyword: Bool) -> HighlightToken.Kind {
        if controlKeywords.contains(ident) { return .keywordControl }
        if declarationKeywords.contains(ident) { return .keywordDeclaration }
        if importKeywords.contains(ident) { return .keywordImport }
        if operatorKeywords.contains(ident) { return .keywordOperator }
        if otherKeywords.contains(ident) { return .keyword }
        if booleans.contains(ident) { return .boolean }
        if builtinConstants.contains(ident) { return .constantBuiltin }
        if specialVariables.contains(ident) { return .variableSpecial }
        if builtinTypes.contains(ident) { return .typeBuiltin }
        if precededByDeclKeyword { return .functionDefinition }
        if followedByParen { return .function }
        if let first = ident.utf8.first, LexerScanner.isUpperASCII(first) {
            return .type
        }
        return .none
    }
}

enum CLikeLexers {
    static func lex(_ scanner: inout LexerScanner, language: Language) {
        let lexicon = lexicon(for: language)
        lexWith(lexicon, scanner: &scanner, language: language)
    }

    private static func lexWith(
        _ lexicon: CLikeLexicon,
        scanner: inout LexerScanner,
        language: Language
    ) {
        var expectFuncDef = false
        var canStartRegex = true

        while !scanner.isAtEnd {
            scanner.skipWhitespace()
            guard let b = scanner.peek() else { break }

            // Comments
            if lexicon.slashComments && scanner.startsWith("//") {
                let isDoc = scanner.startsWith("///") && !scanner.startsWith("////")
                scanner.scanLineComment(isDoc: isDoc)
                continue
            }
            if lexicon.slashComments && scanner.startsWith("/*") {
                scanner.scanBlockComment(nested: lexicon.nestedBlockComments)
                continue
            }
            if lexicon.hashComments && b == 0x23 /* # */ {
                scanner.scanLineComment(isDoc: false)
                continue
            }

            // Preprocessor (#include, #define, #if, etc.)
            if lexicon.preprocessorHashes && b == 0x23 /* # */ {
                let start = scanner.index
                scanner.advance(1)
                let _ = scanner.scanIdentifierRange()
                scanner.emit(start..<scanner.index, .preproc)
                canStartRegex = false
                continue
            }

            // Rust #[...] / #![...] attributes
            if lexicon.rustAttributes && (scanner.startsWith("#[") || scanner.startsWith("#![")) {
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
                continue
            }

            // Metal [[attribute]]
            if lexicon.doubleBracketAttributes && scanner.startsWith("[[") {
                let start = scanner.index
                scanner.advance(2)
                while !scanner.isAtEnd && !scanner.startsWith("]]") {
                    scanner.advanceScalar()
                }
                if scanner.startsWith("]]") { scanner.advance(2) }
                scanner.emit(start..<scanner.index, .attribute)
                canStartRegex = false
                continue
            }

            // @attribute / @decorator
            if lexicon.atAttributes && b == 0x40 /* @ */ {
                let start = scanner.index
                scanner.advance(1)
                _ = scanner.scanIdentifierRange()
                scanner.emit(start..<scanner.index, .attribute)
                canStartRegex = false
                continue
            }

            // Triple-quoted strings
            if lexicon.tripleDoubleQuotes && scanner.startsWith("\"\"\"") {
                scanner.scanTripleQuotedString(quote: 0x22)
                canStartRegex = false
                continue
            }
            if lexicon.tripleSingleQuotes && scanner.startsWith("'''") {
                scanner.scanTripleQuotedString(quote: 0x27)
                canStartRegex = false
                continue
            }

            // Rust raw strings r#"..."# / r"..."
            if language == .rust && b == 0x72 /* r */ {
                if scanRustRawString(&scanner) {
                    canStartRegex = false
                    continue
                }
            }

            // Swift raw strings #"..."#
            if language == .swift && scanner.startsWith("#\"") {
                let start = scanner.index
                scanner.advance(2)
                while !scanner.isAtEnd && !scanner.startsWith("\"#") {
                    scanner.advanceScalar()
                }
                if scanner.startsWith("\"#") { scanner.advance(2) }
                scanner.emit(start..<scanner.index, .string)
                canStartRegex = false
                continue
            }

            // Python prefixed strings f"...", r"...", b"...", u"..."
            if language == .python,
               (b == 0x66 || b == 0x46 || b == 0x72 || b == 0x52 || b == 0x62 || b == 0x42 || b == 0x75 || b == 0x55),
               let next = scanner.peek(1), next == 0x22 || next == 0x27 {
                scanner.advance(1)
                if next == 0x22 && scanner.startsWith("\"\"\"") {
                    scanner.scanTripleQuotedString(quote: 0x22)
                } else if next == 0x27 && scanner.startsWith("'''") {
                    scanner.scanTripleQuotedString(quote: 0x27)
                } else {
                    scanner.scanQuotedString(quote: next, allowEscapes: b != 0x72 && b != 0x52)
                }
                canStartRegex = false
                continue
            }

            // Strings
            if b == 0x22 /* " */ {
                scanner.scanQuotedString(quote: 0x22, allowEscapes: true)
                canStartRegex = false
                continue
            }
            if b == 0x27 /* ' */ {
                if lexicon.singleQuoteAsString {
                    scanner.scanQuotedString(quote: 0x27, allowEscapes: true)
                } else if language == .rust {
                    scanRustCharOrLifetime(&scanner)
                } else {
                    scanner.scanQuotedString(quote: 0x27, allowEscapes: true)
                }
                canStartRegex = false
                continue
            }
            if lexicon.backtickStrings && b == 0x60 /* ` */ {
                scanner.scanQuotedString(
                    quote: 0x60,
                    allowEscapes: language != .go,
                    multiline: true,
                    emitEscapes: language != .go
                )
                canStartRegex = false
                continue
            }

            // JS/TS regex literal /.../flags
            if lexicon.regexLiterals && b == 0x2F /* / */ && canStartRegex && !scanner.startsWith("//") && !scanner.startsWith("/*") {
                if scanRegexLiteral(&scanner) {
                    canStartRegex = false
                    continue
                }
            }

            // JSX tag heuristic: <Component or <div or </
            if lexicon.jsxTags && b == 0x3C /* < */ {
                if let next = scanner.peek(1), (LexerScanner.isAlpha(next) || next == 0x2F || next == 0x3E) {
                    if scanJSXTagStart(&scanner) {
                        canStartRegex = false
                        continue
                    }
                }
            }

            // Numbers
            if LexerScanner.isDigit(b) || (b == 0x2E && scanner.peek(1).map(LexerScanner.isDigit) == true) {
                scanner.scanNumber()
                canStartRegex = false
                expectFuncDef = false
                continue
            }

            // Identifiers & Keywords
            if LexerScanner.isIdentStart(b) {
                let range = scanner.scanIdentifierRange()
                let word = scanner.string(for: range)

                // Rust macro invocation: ident!
                if language == .rust && scanner.peek() == 0x21 /* ! */ && scanner.peek(1) != 0x3D {
                    scanner.advance(1)
                    scanner.emit(range.lowerBound..<scanner.index, .function)
                    expectFuncDef = false
                    canStartRegex = false
                    continue
                }

                let nextByte = scanner.nextNonWhitespaceByte(from: scanner.index)
                let followedByParen = (nextByte == 0x28 /* ( */)
                let kind = lexicon.classify(word, followedByParen: followedByParen, precededByDeclKeyword: expectFuncDef)
                scanner.emit(range, kind)

                expectFuncDef = (word == "fn" || word == "func" || word == "def" || word == "function")
                canStartRegex = (word == "return" || word == "await" || word == "yield" || word == "typeof")
                continue
            }

            // Punctuation & Operators
            let start = scanner.index
            switch b {
            case 0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D: // () [] {}
                scanner.advance(1)
                scanner.emit(start..<scanner.index, .punctuationBracket)
                canStartRegex = (b == 0x28 || b == 0x5B || b == 0x7B)
            case 0x2C, 0x3A, 0x3B, 0x2E: // , : ; .
                scanner.advance(1)
                scanner.emit(start..<scanner.index, .punctuationDelimiter)
                canStartRegex = (b != 0x2E)
            case 0x2B, 0x2D, 0x2A, 0x2F, 0x25, 0x3D, 0x21, 0x3C, 0x3E, 0x26, 0x7C, 0x5E, 0x7E, 0x3F:
                scanner.advance(1)
                while let next = scanner.peek(),
                      next == 0x3D || next == 0x26 || next == 0x7C || next == 0x3E || next == 0x3C || next == 0x2B || next == 0x2D {
                    scanner.advance(1)
                }
                scanner.emit(start..<scanner.index, .operator)
                canStartRegex = true
            default:
                scanner.advanceScalar()
                canStartRegex = false
            }
            expectFuncDef = false
        }
    }

    private static func scanRustRawString(_ scanner: inout LexerScanner) -> Bool {
        var offset = 1
        var hashes = 0
        while scanner.peek(offset) == 0x23 {
            hashes += 1
            offset += 1
        }
        guard scanner.peek(offset) == 0x22 /* " */ else { return false }
        let start = scanner.index
        scanner.advance(offset + 1)
        while !scanner.isAtEnd {
            if scanner.peek() == 0x22 {
                var matched = true
                for i in 1...max(1, hashes) {
                    if hashes == 0 { break }
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

    private static func scanRustCharOrLifetime(_ scanner: inout LexerScanner) {
        let start = scanner.index
        scanner.advance(1) // '
        if scanner.peek() == 0x5C /* \ */ {
            scanner.advance(1)
            if !scanner.isAtEnd { scanner.advanceScalar() }
            if scanner.peek() == 0x27 { scanner.advance(1) }
            scanner.emit(start..<scanner.index, .string)
            return
        }
        // Check for 'c' character literal
        if !scanner.isAtEnd, scanner.peek(1) == 0x27 {
            scanner.advance(2)
            scanner.emit(start..<scanner.index, .string)
            return
        }
        // Lifetime 'a or 'static
        if let b = scanner.peek(), LexerScanner.isIdentStart(b) {
            _ = scanner.scanIdentifierRange()
            scanner.emit(start..<scanner.index, .label)
        }
    }

    private static func scanRegexLiteral(_ scanner: inout LexerScanner) -> Bool {
        let start = scanner.index
        var i = start + 1
        var inClass = false
        while i < scanner.bytes.count {
            let b = scanner.bytes[i]
            if b == 0x0A || b == 0x0D { return false }
            if b == 0x5C {
                i += 2
                continue
            }
            if b == 0x5B { inClass = true }
            else if b == 0x5D { inClass = false }
            else if b == 0x2F && !inClass {
                i += 1
                while i < scanner.bytes.count && LexerScanner.isAlpha(scanner.bytes[i]) {
                    i += 1
                }
                scanner.index = i
                scanner.emit(start..<i, .stringRegex)
                return true
            }
            i += 1
        }
        return false
    }

    private static func scanJSXTagStart(_ scanner: inout LexerScanner) -> Bool {
        let start = scanner.index
        scanner.advance(1) // <
        if scanner.peek() == 0x2F /* / */ {
            scanner.advance(1)
        }
        scanner.emit(start..<scanner.index, .punctuationBracketJSX)
        if let first = scanner.peek(), LexerScanner.isIdentStart(first) {
            let tagRange = scanner.scanIdentifierRange()
            let isComponent = LexerScanner.isUpperASCII(first)
            scanner.emit(tagRange, isComponent ? .tagComponentJSX : .tagJSX)
        }
        return true
    }

    static func lexicon(for language: Language) -> CLikeLexicon {
        switch language {
        case .rust:
            return CLikeLexicon(
                controlKeywords: ["if", "else", "match", "for", "while", "loop", "break", "continue", "return", "yield", "await"],
                declarationKeywords: ["fn", "struct", "enum", "trait", "impl", "type", "let", "const", "static", "mod", "macro_rules"],
                importKeywords: ["use", "extern", "crate"],
                operatorKeywords: ["as", "in", "ref", "move", "dyn", "where"],
                otherKeywords: ["pub", "mut", "unsafe", "async", "default", "box"],
                builtinConstants: ["None", "Some", "Ok", "Err"],
                builtinTypes: ["bool", "char", "str", "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128", "isize", "f32", "f64", "Self", "String", "Vec", "Option", "Result", "Box"],
                specialVariables: ["self"],
                nestedBlockComments: true,
                rustAttributes: true
            )
        case .swift:
            return CLikeLexicon(
                controlKeywords: ["if", "else", "guard", "switch", "case", "default", "for", "while", "repeat", "break", "continue", "return", "throw", "throws", "rethrows", "try", "catch", "do", "defer", "await", "fallthrough", "where"],
                declarationKeywords: ["func", "struct", "class", "enum", "actor", "protocol", "extension", "typealias", "associatedtype", "let", "var", "init", "deinit", "subscript", "operator", "precedencegroup", "macro"],
                importKeywords: ["import"],
                operatorKeywords: ["as", "is", "in"],
                otherKeywords: ["public", "private", "fileprivate", "internal", "package", "open", "static", "final", "override", "mutating", "nonmutating", "async", "weak", "unowned", "inout", "some", "any", "consuming", "borrowing", "nonisolated", "isolated", "convenience", "required", "lazy", "dynamic", "indirect", "get", "set", "willSet", "didSet"],
                builtinConstants: ["nil"],
                builtinTypes: ["Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Float", "Double", "Bool", "String", "Character", "Void", "Never", "Any", "AnyObject", "Self", "Array", "Dictionary", "Set", "Optional", "Result", "Error", "Sendable", "Equatable", "Hashable", "Codable"],
                specialVariables: ["self", "super"],
                nestedBlockComments: true,
                tripleDoubleQuotes: true,
                preprocessorHashes: true,
                atAttributes: true
            )
        case .javascript, .typescript, .jsx, .tsx, .tsrx:
            let isJSX = (language == .jsx || language == .tsx || language == .tsrx)
            return CLikeLexicon(
                controlKeywords: ["if", "else", "switch", "case", "default", "for", "while", "do", "break", "continue", "return", "throw", "try", "catch", "finally", "await", "yield"],
                declarationKeywords: ["function", "class", "interface", "type", "enum", "namespace", "const", "let", "var", "declare", "module"],
                importKeywords: ["import", "export", "from", "as", "require"],
                operatorKeywords: ["typeof", "instanceof", "in", "of", "keyof", "new", "delete", "void"],
                otherKeywords: ["async", "static", "public", "private", "protected", "readonly", "abstract", "implements", "extends", "override", "get", "set", "satisfies", "is"],
                builtinConstants: ["null", "undefined", "NaN", "Infinity"],
                builtinTypes: ["string", "number", "boolean", "bigint", "symbol", "object", "unknown", "never", "any", "void", "Promise", "Array", "Record", "Map", "Set"],
                specialVariables: ["this", "super", "arguments"],
                backtickStrings: true,
                atAttributes: true,
                singleQuoteAsString: true,
                jsxTags: isJSX,
                regexLiterals: true
            )
        case .python:
            return CLikeLexicon(
                controlKeywords: ["if", "elif", "else", "for", "while", "break", "continue", "return", "yield", "try", "except", "finally", "raise", "with", "match", "case", "pass", "assert", "await"],
                declarationKeywords: ["def", "class", "lambda", "global", "nonlocal"],
                importKeywords: ["import", "from", "as"],
                operatorKeywords: ["and", "or", "not", "in", "is", "del"],
                otherKeywords: ["async"],
                booleans: ["True", "False"],
                builtinConstants: ["None", "Ellipsis", "NotImplemented"],
                builtinTypes: ["int", "float", "str", "bool", "bytes", "list", "dict", "set", "tuple", "object", "type", "Exception"],
                specialVariables: ["self", "cls"],
                hashComments: true,
                slashComments: false,
                tripleDoubleQuotes: true,
                tripleSingleQuotes: true,
                atAttributes: true,
                singleQuoteAsString: true
            )
        case .go:
            return CLikeLexicon(
                controlKeywords: ["if", "else", "switch", "case", "default", "select", "for", "range", "break", "continue", "return", "goto", "fallthrough", "defer", "go"],
                declarationKeywords: ["func", "type", "struct", "interface", "var", "const", "map", "chan"],
                importKeywords: ["package", "import"],
                booleans: ["true", "false"],
                builtinConstants: ["nil", "iota"],
                builtinTypes: ["bool", "byte", "rune", "string", "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr", "float32", "float64", "complex64", "complex128", "error", "any"],
                backtickStrings: true
            )
        case .c, .cpp, .cuda, .objectiveC:
            return CLikeLexicon(
                controlKeywords: ["if", "else", "switch", "case", "default", "for", "while", "do", "break", "continue", "return", "goto", "try", "catch", "throw", "co_await", "co_yield", "co_return"],
                declarationKeywords: ["struct", "union", "enum", "class", "namespace", "template", "typename", "typedef", "using", "concept", "requires"],
                operatorKeywords: ["sizeof", "alignof", "new", "delete", "typeid", "static_cast", "dynamic_cast", "const_cast", "reinterpret_cast", "and", "or", "not"],
                otherKeywords: ["const", "constexpr", "consteval", "constinit", "volatile", "static", "extern", "inline", "virtual", "override", "final", "public", "private", "protected", "friend", "mutable", "explicit", "noexcept", "auto", "register"],
                builtinConstants: ["NULL", "nullptr"],
                builtinTypes: ["void", "bool", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "size_t", "ssize_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t"],
                specialVariables: ["this"],
                preprocessorHashes: true,
                atAttributes: language == .objectiveC
            )
        case .wgsl:
            return CLikeLexicon(
                controlKeywords: ["if", "else", "switch", "case", "default", "for", "while", "loop", "break", "continue", "return", "discard", "continuing"],
                declarationKeywords: ["fn", "struct", "var", "let", "const", "override", "alias", "enable", "diagnostic"],
                otherKeywords: ["uniform", "storage", "workgroup", "private", "function", "read", "write", "read_write"],
                builtinTypes: ["bool", "i32", "u32", "f32", "f16", "vec2", "vec3", "vec4", "mat2x2", "mat3x3", "mat4x4", "array", "ptr", "atomic", "sampler", "sampler_comparison", "texture_2d", "texture_3d", "texture_cube", "texture_storage_2d"],
                nestedBlockComments: true,
                atAttributes: true
            )
        case .msl:
            return CLikeLexicon(
                controlKeywords: ["if", "else", "switch", "case", "default", "for", "while", "do", "break", "continue", "return", "discard_fragment"],
                declarationKeywords: ["struct", "enum", "class", "namespace", "template", "typename", "typedef", "using"],
                otherKeywords: ["kernel", "vertex", "fragment", "constant", "device", "thread", "threadgroup", "threadgroup_imageblock", "ray_data", "object_data", "const", "constexpr", "static", "inline", "auto"],
                builtinConstants: ["nullptr"],
                builtinTypes: ["void", "bool", "char", "uchar", "short", "ushort", "int", "uint", "long", "ulong", "half", "float", "half2", "half3", "half4", "float2", "float3", "float4", "float2x2", "float3x3", "float4x4", "int2", "int3", "int4", "uint2", "uint3", "uint4", "texture2d", "texture3d", "texturecube", "depth2d", "sampler"],
                preprocessorHashes: true,
                doubleBracketAttributes: true
            )
        default:
            let useHash = [.ruby, .perl, .r, .elixir, .julia, .nim, .nix, .cmake, .makefile, .dockerfile, .terraform, .powershell].contains(language)
            return CLikeLexicon(
                controlKeywords: ["if", "else", "elif", "switch", "case", "default", "for", "while", "do", "break", "continue", "return", "try", "catch", "finally", "throw", "match", "when"],
                declarationKeywords: ["fn", "func", "fun", "function", "def", "class", "struct", "enum", "interface", "trait", "protocol", "type", "let", "var", "val", "const"],
                importKeywords: ["import", "export", "from", "use", "require", "include", "package", "module"],
                otherKeywords: ["pub", "public", "private", "protected", "static", "async", "await", "final", "override", "in", "as", "is"],
                builtinConstants: ["null", "nil", "None", "undefined"],
                hashComments: useHash,
                slashComments: !useHash || language == .nix || language == .terraform,
                atAttributes: true,
                singleQuoteAsString: true
            )
        }
    }
}
