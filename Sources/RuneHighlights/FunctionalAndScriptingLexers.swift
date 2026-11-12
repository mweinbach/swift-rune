import Foundation

/// Lexers and grammar specifications for functional, scripting, and dynamic languages.
enum FunctionalAndScriptingLexers {
    static func lex(_ scanner: inout LexerScanner, language: Language) -> Bool {
        switch language {
        case .javascript:
            LanguageGrammarSpecs.lex(&scanner, spec: jsSpec(jsx: false, ts: false), language: language)
            return true
        case .jsx:
            LanguageGrammarSpecs.lex(&scanner, spec: jsSpec(jsx: true, ts: false), language: language)
            return true
        case .typescript:
            LanguageGrammarSpecs.lex(&scanner, spec: jsSpec(jsx: false, ts: true), language: language)
            return true
        case .tsx, .tsrx:
            LanguageGrammarSpecs.lex(&scanner, spec: jsSpec(jsx: true, ts: true), language: language)
            return true
        case .python:
            LanguageGrammarSpecs.lex(&scanner, spec: pythonSpec, language: language)
            return true
        case .ruby:
            lexRuby(&scanner)
            return true
        case .php:
            lexPHP(&scanner)
            return true
        case .lua:
            lexLua(&scanner)
            return true
        case .perl:
            LanguageGrammarSpecs.lex(&scanner, spec: perlSpec, language: language)
            return true
        case .r:
            LanguageGrammarSpecs.lex(&scanner, spec: rSpec, language: language)
            return true
        case .julia:
            LanguageGrammarSpecs.lex(&scanner, spec: juliaSpec, language: language)
            return true
        case .elixir:
            LanguageGrammarSpecs.lex(&scanner, spec: elixirSpec, language: language)
            return true
        case .erlang:
            LanguageGrammarSpecs.lex(&scanner, spec: erlangSpec, language: language)
            return true
        case .haskell:
            LanguageGrammarSpecs.lex(&scanner, spec: haskellSpec, language: language)
            return true
        case .elm:
            LanguageGrammarSpecs.lex(&scanner, spec: elmSpec, language: language)
            return true
        case .ocaml:
            LanguageGrammarSpecs.lex(&scanner, spec: ocamlSpec, language: language)
            return true
        case .fsharp:
            LanguageGrammarSpecs.lex(&scanner, spec: fsharpSpec, language: language)
            return true
        case .clojure:
            lexLispFamily(&scanner, isClojure: true)
            return true
        case .lisp:
            lexLispFamily(&scanner, isClojure: false)
            return true
        case .gleam:
            LanguageGrammarSpecs.lex(&scanner, spec: gleamSpec, language: language)
            return true
        case .powershell:
            LanguageGrammarSpecs.lex(&scanner, spec: powershellSpec, language: language)
            return true
        case .matlab:
            LanguageGrammarSpecs.lex(&scanner, spec: matlabSpec, language: language)
            return true
        case .bat:
            lexBatch(&scanner)
            return true
        default:
            return false
        }
    }

    // MARK: - Specs

    private static func jsSpec(jsx: Bool, ts: Bool) -> LanguageGrammarSpec {
        var decl: Set<String> = ["function", "class", "const", "let", "var", "async", "extends", "static", "get", "set"]
        var types: Set<String> = ["Array", "Object", "String", "Number", "Boolean", "Promise", "Map", "Set", "Date", "RegExp", "Error", "Symbol", "BigInt"]
        if ts {
            decl.formUnion(["interface", "type", "enum", "namespace", "declare", "abstract", "implements", "readonly", "public", "private", "protected", "override", "satisfies", "infer"])
            types.formUnion(["string", "number", "boolean", "any", "unknown", "never", "void", "object", "Record", "Partial", "Required", "Readonly", "Pick", "Omit"])
        }
        return LanguageGrammarSpec(
            controlKeywords: ["if", "else", "switch", "case", "default", "for", "while", "do", "break", "continue", "return", "try", "catch", "finally", "throw", "await", "yield"],
            declarationKeywords: decl,
            importKeywords: ["import", "export", "from", "as"],
            operatorKeywords: ["typeof", "instanceof", "in", "of", "new", "delete", "void", "keyof"],
            otherKeywords: ["debugger", "with"],
            booleans: ["true", "false"],
            builtinConstants: ["null", "undefined", "NaN", "Infinity"],
            builtinTypes: types,
            specialVariables: ["this", "super", "arguments"],
            backtickStrings: true,
            interpolation: .dollarBrace,
            atAttributes: true,
            jsxTags: jsx,
            regexLiterals: true
        )
    }

    private static let pythonSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "elif", "else", "for", "while", "break", "continue", "return", "yield", "try", "except", "finally", "raise", "with", "match", "case", "pass", "await"],
        declarationKeywords: ["def", "class", "lambda", "async", "global", "nonlocal"],
        importKeywords: ["import", "from", "as"],
        operatorKeywords: ["and", "or", "not", "in", "is"],
        otherKeywords: ["assert", "del"],
        booleans: ["True", "False"],
        builtinConstants: ["None", "NotImplemented", "Ellipsis"],
        builtinTypes: ["int", "float", "str", "bool", "bytes", "list", "dict", "set", "tuple", "frozenset", "object", "type", "Any", "Optional", "Union", "List", "Dict"],
        builtinFunctions: ["print", "len", "range", "enumerate", "zip", "map", "filter", "sorted", "reversed", "sum", "min", "max", "abs", "isinstance", "issubclass", "hasattr", "getattr", "setattr", "open", "super"],
        specialVariables: ["self", "cls"],
        slashComments: false,
        hashComments: true,
        singleQuoteAsString: true,
        tripleDoubleQuotes: true,
        tripleSingleQuotes: true,
        pythonStringPrefixes: true,
        atAttributes: true
    )

    private static let perlSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "elsif", "else", "unless", "while", "until", "for", "foreach", "last", "next", "redo", "return", "goto", "die", "warn", "eval"],
        declarationKeywords: ["sub", "my", "our", "local", "state", "package"],
        importKeywords: ["use", "require", "no"],
        operatorKeywords: ["and", "or", "not", "xor", "eq", "ne", "lt", "gt", "le", "ge", "cmp"],
        otherKeywords: ["do", "BEGIN", "END"],
        booleans: [],
        builtinConstants: ["undef", "STDIN", "STDOUT", "STDERR"],
        builtinTypes: [],
        builtinFunctions: ["print", "say", "printf", "sprintf", "chomp", "chop", "split", "join", "push", "pop", "shift", "unshift", "map", "grep", "sort", "keys", "values", "exists", "delete", "defined", "length", "substr", "open", "close"],
        specialVariables: [],
        slashComments: false,
        hashComments: true,
        customBlockComment: (start: "=pod", end: "=cut", nested: false),
        singleQuoteAsString: true,
        regexLiterals: true,
        dollarVariables: true
    )

    private static let rSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "else", "for", "in", "while", "repeat", "break", "next", "return"],
        declarationKeywords: ["function"],
        importKeywords: ["library", "require", "source"],
        operatorKeywords: [],
        otherKeywords: [],
        booleans: ["TRUE", "FALSE", "T", "F"],
        builtinConstants: ["NULL", "NA", "NA_integer_", "NA_real_", "NA_complex_", "NA_character_", "Inf", "NaN", "pi", "LETTERS", "letters"],
        builtinTypes: ["numeric", "integer", "character", "logical", "complex", "raw", "list", "data.frame", "matrix", "factor", "vector"],
        builtinFunctions: ["c", "print", "cat", "paste", "paste0", "length", "nrow", "ncol", "dim", "summary", "str", "head", "tail", "lapply", "sapply", "apply", "mean", "sum", "min", "max"],
        specialVariables: [],
        slashComments: false,
        hashComments: true,
        singleQuoteAsString: true
    )

    private static let juliaSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "elseif", "else", "for", "while", "break", "continue", "return", "try", "catch", "finally", "throw", "begin", "end", "do"],
        declarationKeywords: ["function", "macro", "struct", "mutable", "abstract", "primitive", "type", "module", "baremodule", "let", "const", "local", "global", "quote"],
        importKeywords: ["using", "import", "export", "include"],
        operatorKeywords: ["in", "isa", "where"],
        otherKeywords: [],
        booleans: ["true", "false"],
        builtinConstants: ["nothing", "missing", "Inf", "Inf64", "NaN", "NaN64", "pi", "im"],
        builtinTypes: ["Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Float16", "Float32", "Float64", "Bool", "Char", "String", "Symbol", "Vector", "Matrix", "Array", "Dict", "Set", "Tuple", "NamedTuple", "Any", "Nothing"],
        specialVariables: [],
        slashComments: false,
        hashComments: true,
        customBlockComment: (start: "#=", end: "=#", nested: true),
        tripleDoubleQuotes: true,
        backtickStrings: true,
        interpolation: .dollarBrace,
        atAttributes: true,
        colonSymbols: true
    )

    private static let elixirSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "unless", "else", "case", "cond", "with", "for", "try", "rescue", "catch", "after", "raise", "throw", "receive", "do", "end", "when"],
        declarationKeywords: ["def", "defp", "defmodule", "defstruct", "defimpl", "defprotocol", "defmacro", "defmacrop", "defdelegate", "defguard", "defexception", "fn"],
        importKeywords: ["alias", "import", "require", "use"],
        operatorKeywords: ["and", "or", "not", "in"],
        otherKeywords: [],
        booleans: ["true", "false"],
        builtinConstants: ["nil"],
        builtinTypes: ["String", "Integer", "Float", "List", "Map", "Tuple", "Keyword", "Enum", "Stream", "Atom", "Regex", "Range", "Task", "Agent", "GenServer"],
        specialVariables: ["__MODULE__", "__DIR__", "__FILE__", "__ENV__"],
        slashComments: false,
        hashComments: true,
        singleQuoteAsString: true,
        tripleDoubleQuotes: true,
        interpolation: .hashBrace,
        atAttributes: true,
        colonSymbols: true
    )

    private static let erlangSpec = LanguageGrammarSpec(
        controlKeywords: ["case", "of", "if", "receive", "after", "try", "catch", "throw", "when", "end", "begin"],
        declarationKeywords: ["fun", "record", "spec", "type", "opaque", "export", "export_type", "module", "behaviour", "behavior", "define"],
        importKeywords: ["import", "include", "include_lib"],
        operatorKeywords: ["and", "or", "xor", "not", "andalso", "orelse", "band", "bor", "bxor", "bnot", "bsl", "bsr", "div", "rem"],
        otherKeywords: [],
        booleans: ["true", "false"],
        builtinConstants: ["ok", "error", "undefined"],
        builtinTypes: ["integer", "float", "atom", "binary", "bitstring", "list", "tuple", "map", "pid", "port", "reference", "boolean", "string", "term", "any"],
        specialVariables: [],
        slashComments: false,
        percentComments: true
    )

    private static let haskellSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "then", "else", "case", "of", "do", "let", "in", "where"],
        declarationKeywords: ["data", "newtype", "type", "class", "instance", "deriving", "default", "infix", "infixl", "infixr", "foreign"],
        importKeywords: ["module", "import", "qualified", "as", "hiding", "export"],
        operatorKeywords: [],
        otherKeywords: ["forall", "mdo", "rec", "proc"],
        booleans: ["True", "False"],
        builtinConstants: ["Nothing", "Just", "Left", "Right", "LT", "EQ", "GT"],
        builtinTypes: ["Int", "Integer", "Float", "Double", "Bool", "Char", "String", "Maybe", "Either", "IO", "Ordering", "Show", "Eq", "Ord", "Functor", "Applicative", "Monad", "Foldable", "Traversable"],
        specialVariables: [],
        slashComments: false,
        dashComments: true,
        customBlockComment: (start: "{-", end: "-}", nested: true)
    )

    private static let elmSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "then", "else", "case", "of", "let", "in"],
        declarationKeywords: ["type", "alias", "port", "infix"],
        importKeywords: ["module", "import", "exposing", "as"],
        operatorKeywords: [],
        otherKeywords: ["where"],
        booleans: ["True", "False"],
        builtinConstants: ["Nothing", "Just", "Ok", "Err", "LT", "EQ", "GT"],
        builtinTypes: ["Int", "Float", "Bool", "Char", "String", "List", "Maybe", "Result", "Cmd", "Sub", "Html", "Attribute", "Dict", "Set", "Array"],
        specialVariables: [],
        slashComments: false,
        dashComments: true,
        customBlockComment: (start: "{-", end: "-}", nested: true),
        tripleDoubleQuotes: true
    )

    private static let ocamlSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "then", "else", "match", "with", "when", "try", "for", "to", "downto", "while", "do", "done", "begin", "end"],
        declarationKeywords: ["let", "rec", "in", "and", "fun", "function", "type", "of", "module", "struct", "sig", "val", "exception", "class", "object", "method", "inherit", "initializer", "mutable", "private", "virtual", "external"],
        importKeywords: ["open", "include"],
        operatorKeywords: ["as", "asr", "land", "lor", "lsl", "lsr", "lxor", "mod", "or", "not"],
        otherKeywords: ["ref", "raise", "assert", "lazy"],
        booleans: ["true", "false"],
        builtinConstants: ["None", "Some", "Ok", "Error"],
        builtinTypes: ["int", "float", "bool", "char", "string", "bytes", "unit", "list", "array", "option", "result", "exn"],
        specialVariables: ["self"],
        slashComments: false,
        customBlockComment: (start: "(*", end: "*)", nested: true)
    )

    private static let fsharpSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "then", "elif", "else", "match", "with", "when", "try", "finally", "for", "to", "downto", "while", "do", "done", "yield", "return", "select"],
        declarationKeywords: ["let", "rec", "and", "in", "fun", "function", "type", "of", "module", "namespace", "val", "member", "static", "abstract", "override", "default", "interface", "inherit", "mutable", "inline", "private", "public", "internal", "async", "task"],
        importKeywords: ["open"],
        operatorKeywords: ["as", "upcast", "downcast", "not", "and", "or"],
        otherKeywords: ["new", "null", "use", "assert", "lazy"],
        booleans: ["true", "false"],
        builtinConstants: ["null", "None", "Some", "Ok", "Error"],
        builtinTypes: ["int", "int64", "float", "float32", "decimal", "bool", "char", "string", "unit", "obj", "list", "seq", "array", "option", "Result", "Async", "Task", "Map", "Set"],
        specialVariables: ["this", "base"],
        slashComments: true,
        customBlockComment: (start: "(*", end: "*)", nested: true),
        tripleDoubleQuotes: true
    )

    private static let gleamSpec = LanguageGrammarSpec(
        controlKeywords: ["case", "if", "use"],
        declarationKeywords: ["fn", "let", "const", "type", "opaque", "pub"],
        importKeywords: ["import", "as"],
        operatorKeywords: [],
        otherKeywords: ["todo", "panic", "echo", "assert"],
        booleans: ["True", "False"],
        builtinConstants: ["Nil", "Ok", "Error", "Some", "None"],
        builtinTypes: ["Int", "Float", "String", "Bool", "BitArray", "List", "Result", "Option"],
        specialVariables: [],
        atAttributes: true
    )

    private static let powershellSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "elseif", "else", "switch", "for", "foreach", "while", "do", "until", "break", "continue", "return", "try", "catch", "finally", "throw", "trap"],
        declarationKeywords: ["function", "filter", "workflow", "class", "enum", "param", "begin", "process", "end", "dynamicparam"],
        importKeywords: ["using", "import-module"],
        operatorKeywords: [],
        otherKeywords: ["in"],
        booleans: ["$true", "$false"],
        builtinConstants: ["$null"],
        builtinTypes: ["int", "long", "string", "char", "bool", "byte", "double", "decimal", "array", "hashtable", "psobject", "void"],
        specialVariables: ["$_", "$PSItem", "$this"],
        caseInsensitiveKeywords: true,
        slashComments: false,
        hashComments: true,
        customBlockComment: (start: "<#", end: "#>", nested: false),
        singleQuoteAsString: true,
        dollarVariables: true
    )

    private static let matlabSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "elseif", "else", "switch", "case", "otherwise", "for", "parfor", "while", "break", "continue", "return", "try", "catch", "end"],
        declarationKeywords: ["function", "classdef", "properties", "methods", "events", "enumeration", "global", "persistent"],
        importKeywords: ["import"],
        operatorKeywords: [],
        otherKeywords: [],
        booleans: ["true", "false"],
        builtinConstants: ["pi", "inf", "Inf", "nan", "NaN", "eps", "i", "j"],
        builtinTypes: ["double", "single", "int8", "int16", "int32", "int64", "uint8", "uint16", "uint32", "uint64", "logical", "char", "string", "cell", "struct", "table"],
        specialVariables: [],
        slashComments: false,
        percentComments: true,
        customBlockComment: (start: "%{", end: "%}", nested: false),
        singleQuoteAsString: true,
        singleQuoteDoubleEscape: true
    )

    // MARK: - Custom Functional & Scripting Lexers

    private static func lexRuby(_ scanner: inout LexerScanner) {
        let control: Set<String> = ["if", "elsif", "else", "unless", "case", "when", "for", "while", "until", "break", "next", "redo", "retry", "return", "yield", "begin", "rescue", "ensure", "raise", "end", "do", "then"]
        let decl: Set<String> = ["def", "class", "module", "alias", "undef", "attr_reader", "attr_writer", "attr_accessor", "private", "protected", "public"]
        let imports: Set<String> = ["require", "require_relative", "include", "extend", "prepend", "load"]
        let opKw: Set<String> = ["and", "or", "not", "in", "defined?"]
        let bools: Set<String> = ["true", "false"]
        let consts: Set<String> = ["nil"]
        let specials: Set<String> = ["self", "super", "__FILE__", "__LINE__", "__ENCODING__"]

        var expectFuncDef = false
        while !scanner.isAtEnd {
            scanner.skipWhitespace()
            guard let b = scanner.peek() else { break }

            if scanner.startsWith("=begin") {
                let start = scanner.index
                while !scanner.isAtEnd && !scanner.startsWith("=end") {
                    scanner.advanceScalar()
                }
                if scanner.startsWith("=end") { scanner.advanceToLineEnd() }
                scanner.emit(start..<scanner.index, .comment)
                continue
            }
            if b == 0x23 /* # */ {
                scanner.scanLineComment()
                continue
            }
            if b == 0x22 /* " */ {
                // Double quoted with #{...} interpolation
                var segStart = scanner.index
                scanner.advance(1)
                while let ch = scanner.peek(), ch != 0x0A {
                    if ch == 0x5C {
                        scanner.emit(segStart..<scanner.index, .string)
                        let esc = scanner.index
                        scanner.advance(1)
                        if !scanner.isAtEnd { scanner.advanceScalar() }
                        scanner.emit(esc..<scanner.index, .stringEscape)
                        segStart = scanner.index
                        continue
                    }
                    if ch == 0x23 && scanner.peek(1) == 0x7B {
                        scanner.emit(segStart..<scanner.index, .string)
                        let open = scanner.index
                        scanner.advance(2)
                        scanner.emit(open..<scanner.index, .punctuationSpecial)
                        let exprStart = scanner.index
                        var depth = 1
                        while !scanner.isAtEnd && depth > 0 {
                            if scanner.peek() == 0x7B { depth += 1; scanner.advance(1) }
                            else if scanner.peek() == 0x7D {
                                depth -= 1
                                if depth == 0 {
                                    if exprStart < scanner.index { scanner.emit(exprStart..<scanner.index, .embedded) }
                                    let close = scanner.index
                                    scanner.advance(1)
                                    scanner.emit(close..<scanner.index, .punctuationSpecial)
                                    break
                                }
                                scanner.advance(1)
                            } else {
                                scanner.advanceScalar()
                            }
                        }
                        segStart = scanner.index
                        continue
                    }
                    if ch == 0x22 { scanner.advance(1); break }
                    scanner.advanceScalar()
                }
                scanner.emit(segStart..<scanner.index, .string)
                expectFuncDef = false
                continue
            }
            if b == 0x27 /* ' */ {
                scanner.scanQuotedString(quote: 0x27)
                expectFuncDef = false
                continue
            }
            // Symbols :foo
            if b == 0x3A && scanner.peek(1) != 0x3A, let next = scanner.peek(1), LexerScanner.isIdentStart(next) {
                let start = scanner.index
                scanner.advance(1)
                let _ = scanner.scanIdentifierRange()
                scanner.emit(start..<scanner.index, .stringSpecialSymbol)
                expectFuncDef = false
                continue
            }
            // @ivar, @@cvar, $gvar
            if b == 0x40 || b == 0x24 {
                let start = scanner.index
                scanner.advance(1)
                if b == 0x40 && scanner.peek() == 0x40 { scanner.advance(1) }
                let _ = scanner.scanIdentifierRange()
                scanner.emit(start..<scanner.index, .variableSpecial)
                expectFuncDef = false
                continue
            }
            if LexerScanner.isDigit(b) {
                scanner.scanNumber()
                expectFuncDef = false
                continue
            }
            if LexerScanner.isIdentStart(b) {
                let range = scanner.scanIdentifierRange()
                if scanner.peek() == 0x3F || scanner.peek() == 0x21 {
                    scanner.advance(1)
                }
                let fullRange = range.lowerBound..<scanner.index
                let word = scanner.string(for: fullRange)
                let kind: HighlightToken.Kind
                if control.contains(word) { kind = .keywordControl }
                else if decl.contains(word) { kind = .keywordDeclaration }
                else if imports.contains(word) { kind = .keywordImport }
                else if opKw.contains(word) { kind = .keywordOperator }
                else if bools.contains(word) { kind = .boolean }
                else if consts.contains(word) { kind = .constantBuiltin }
                else if specials.contains(word) { kind = .variableSpecial }
                else if expectFuncDef { kind = .functionDefinition }
                else if scanner.nextNonWhitespaceByte(from: scanner.index) == 0x28 { kind = .function }
                else if let first = word.utf8.first, LexerScanner.isUpperASCII(first) { kind = .type }
                else { kind = .none }
                scanner.emit(fullRange, kind)
                expectFuncDef = (word == "def")
                continue
            }
            expectFuncDef = false
            scanner.advanceScalar()
        }
    }

    private static func lexPHP(_ scanner: inout LexerScanner) {
        let control: Set<String> = ["if", "elseif", "else", "endif", "switch", "case", "default", "endswitch", "match", "for", "foreach", "endfor", "endforeach", "while", "endwhile", "do", "break", "continue", "return", "try", "catch", "finally", "throw", "yield", "goto"]
        let decl: Set<String> = ["function", "fn", "class", "interface", "trait", "enum", "extends", "implements", "namespace", "const", "var", "public", "private", "protected", "static", "final", "abstract", "readonly"]
        let imports: Set<String> = ["use", "require", "require_once", "include", "include_once"]
        let opKw: Set<String> = ["and", "or", "xor", "instanceof", "new", "clone", "as"]
        let types: Set<String> = ["int", "float", "string", "bool", "array", "object", "callable", "iterable", "void", "never", "mixed", "self", "static", "parent"]

        var expectFuncDef = false
        while !scanner.isAtEnd {
            scanner.skipWhitespace()
            guard let b = scanner.peek() else { break }

            if scanner.startsWith("<?php") || scanner.startsWith("<?=") {
                let start = scanner.index
                scanner.advance(scanner.startsWith("<?php") ? 5 : 3)
                scanner.emit(start..<scanner.index, .preproc)
                continue
            }
            if scanner.startsWith("?>") {
                let start = scanner.index
                scanner.advance(2)
                scanner.emit(start..<scanner.index, .preproc)
                continue
            }
            if scanner.startsWith("//") {
                scanner.scanLineComment()
                continue
            }
            if b == 0x23 /* # */ {
                if scanner.startsWith("#[") {
                    let start = scanner.index
                    scanner.advance(2)
                    while !scanner.isAtEnd && scanner.peek() != 0x5D { scanner.advanceScalar() }
                    if scanner.peek() == 0x5D { scanner.advance(1) }
                    scanner.emit(start..<scanner.index, .attribute)
                } else {
                    scanner.scanLineComment()
                }
                continue
            }
            if scanner.startsWith("/*") {
                scanner.scanBlockComment()
                continue
            }
            if b == 0x22 || b == 0x27 {
                scanner.scanQuotedString(quote: b, multiline: true)
                expectFuncDef = false
                continue
            }
            if b == 0x24 /* $ */ {
                let start = scanner.index
                scanner.advance(1)
                let _ = scanner.scanIdentifierRange()
                let name = scanner.string(for: start..<scanner.index)
                scanner.emit(start..<scanner.index, name == "$this" ? .variableSpecial : .variable)
                expectFuncDef = false
                continue
            }
            if LexerScanner.isDigit(b) {
                scanner.scanNumber()
                expectFuncDef = false
                continue
            }
            if LexerScanner.isIdentStart(b) {
                let range = scanner.scanIdentifierRange()
                let word = scanner.string(for: range)
                let lower = word.lowercased()
                let kind: HighlightToken.Kind
                if control.contains(lower) { kind = .keywordControl }
                else if decl.contains(lower) { kind = .keywordDeclaration }
                else if imports.contains(lower) { kind = .keywordImport }
                else if opKw.contains(lower) { kind = .keywordOperator }
                else if lower == "true" || lower == "false" { kind = .boolean }
                else if lower == "null" { kind = .constantBuiltin }
                else if types.contains(lower) { kind = .typeBuiltin }
                else if expectFuncDef { kind = .functionDefinition }
                else if scanner.nextNonWhitespaceByte(from: scanner.index) == 0x28 { kind = .function }
                else if let first = word.utf8.first, LexerScanner.isUpperASCII(first) { kind = .type }
                else { kind = .none }
                scanner.emit(range, kind)
                expectFuncDef = (lower == "function")
                continue
            }
            expectFuncDef = false
            scanner.advanceScalar()
        }
    }

    private static func lexLua(_ scanner: inout LexerScanner) {
        let control: Set<String> = ["if", "then", "elseif", "else", "for", "in", "while", "repeat", "until", "do", "end", "break", "return", "goto"]
        let decl: Set<String> = ["local", "function"]
        let opKw: Set<String> = ["and", "or", "not"]
        let builtins: Set<String> = ["print", "pairs", "ipairs", "next", "type", "tonumber", "tostring", "require", "pcall", "xpcall", "error", "assert", "select", "setmetatable", "getmetatable"]

        var expectFuncDef = false
        while !scanner.isAtEnd {
            scanner.skipWhitespace()
            guard let b = scanner.peek() else { break }

            if scanner.startsWith("--[[") {
                let start = scanner.index
                scanner.advance(4)
                while !scanner.isAtEnd && !scanner.startsWith("]]") {
                    scanner.advanceScalar()
                }
                if scanner.startsWith("]]") { scanner.advance(2) }
                scanner.emit(start..<scanner.index, .comment)
                continue
            }
            if scanner.startsWith("--") {
                scanner.scanLineComment()
                continue
            }
            if scanner.startsWith("[[") {
                let start = scanner.index
                scanner.advance(2)
                while !scanner.isAtEnd && !scanner.startsWith("]]") {
                    scanner.advanceScalar()
                }
                if scanner.startsWith("]]") { scanner.advance(2) }
                scanner.emit(start..<scanner.index, .string)
                expectFuncDef = false
                continue
            }
            if b == 0x22 || b == 0x27 {
                scanner.scanQuotedString(quote: b)
                expectFuncDef = false
                continue
            }
            if LexerScanner.isDigit(b) {
                scanner.scanNumber()
                expectFuncDef = false
                continue
            }
            if LexerScanner.isIdentStart(b) {
                let range = scanner.scanIdentifierRange()
                let word = scanner.string(for: range)
                let kind: HighlightToken.Kind
                if control.contains(word) { kind = .keywordControl }
                else if decl.contains(word) { kind = .keywordDeclaration }
                else if opKw.contains(word) { kind = .keywordOperator }
                else if word == "true" || word == "false" { kind = .boolean }
                else if word == "nil" { kind = .constantBuiltin }
                else if word == "self" { kind = .variableSpecial }
                else if expectFuncDef { kind = .functionDefinition }
                else if scanner.nextNonWhitespaceByte(from: scanner.index) == 0x28 { kind = .function }
                else if builtins.contains(word) { kind = .function }
                else { kind = .none }
                scanner.emit(range, kind)
                expectFuncDef = (word == "function")
                continue
            }
            expectFuncDef = false
            scanner.advanceScalar()
        }
    }

    private static func lexLispFamily(_ scanner: inout LexerScanner, isClojure: Bool) {
        let control: Set<String> = ["if", "when", "unless", "cond", "case", "do", "loop", "recur", "for", "doseq", "dotimes", "try", "catch", "finally", "throw", "and", "or", "not", "begin", "lambda"]
        let decl: Set<String> = ["def", "defn", "defn-", "defmacro", "defmulti", "defmethod", "defprotocol", "defrecord", "deftype", "defstruct", "defun", "defvar", "defparameter", "defconst", "define", "let", "let*", "letrec", "fn", "ns"]
        let imports: Set<String> = ["require", "use", "import", "refer", "load"]

        var afterOpenParen = false
        while !scanner.isAtEnd {
            scanner.skipWhitespace()
            guard let b = scanner.peek() else { break }

            if b == 0x3B /* ; */ {
                let isDoc = scanner.startsWith(";;")
                scanner.scanLineComment(isDoc: isDoc)
                continue
            }
            if scanner.startsWith("#|") {
                let start = scanner.index
                scanner.advance(2)
                var depth = 1
                while !scanner.isAtEnd && depth > 0 {
                    if scanner.startsWith("#|") { depth += 1; scanner.advance(2) }
                    else if scanner.startsWith("|#") { depth -= 1; scanner.advance(2) }
                    else { scanner.advanceScalar() }
                }
                scanner.emit(start..<scanner.index, .comment)
                continue
            }
            if b == 0x22 /* " */ {
                scanner.scanQuotedString(quote: 0x22, multiline: true)
                afterOpenParen = false
                continue
            }
            if isClojure && b == 0x3A /* : */ {
                let start = scanner.index
                scanner.advance(1)
                while let ch = scanner.peek(), isLispSymbolChar(ch) { scanner.advance(1) }
                scanner.emit(start..<scanner.index, .stringSpecialSymbol)
                afterOpenParen = false
                continue
            }
            if b == 0x28 || b == 0x29 || b == 0x5B || b == 0x5D || b == 0x7B || b == 0x7D {
                let start = scanner.index
                scanner.advance(1)
                scanner.emit(start..<scanner.index, .punctuationBracket)
                afterOpenParen = (b == 0x28)
                continue
            }
            if LexerScanner.isDigit(b) || (b == 0x2D && scanner.peek(1).map(LexerScanner.isDigit) == true) {
                if b == 0x2D { scanner.advance(1) }
                scanner.scanNumber()
                afterOpenParen = false
                continue
            }
            if isLispSymbolStart(b) {
                let start = scanner.index
                while let ch = scanner.peek(), isLispSymbolChar(ch) {
                    scanner.advance(1)
                }
                let range = start..<scanner.index
                let word = scanner.string(for: range)
                let kind: HighlightToken.Kind
                if control.contains(word) { kind = .keywordControl }
                else if decl.contains(word) { kind = .keywordDeclaration }
                else if imports.contains(word) { kind = .keywordImport }
                else if word == "true" || word == "false" || word == "#t" || word == "#f" || word == "t" { kind = .boolean }
                else if word == "nil" { kind = .constantBuiltin }
                else if afterOpenParen { kind = .function }
                else { kind = .none }
                scanner.emit(range, kind)
                afterOpenParen = false
                continue
            }
            afterOpenParen = false
            scanner.advanceScalar()
        }
    }

    private static func lexBatch(_ scanner: inout LexerScanner) {
        let control: Set<String> = ["if", "else", "for", "in", "do", "goto", "call", "exit"]
        let keywords: Set<String> = ["echo", "set", "setlocal", "endlocal", "cd", "dir", "copy", "del", "move", "mkdir", "rmdir", "type", "pause", "shift", "defined", "exist", "not", "equ", "neq", "lss", "leq", "gtr", "geq"]

        while !scanner.isAtEnd {
            scanner.skipWhitespace()
            guard let b = scanner.peek() else { break }

            if scanner.startsWith("::") {
                scanner.scanLineComment()
                continue
            }
            if b == 0x25 /* % */ {
                let start = scanner.index
                scanner.advance(1)
                while let ch = scanner.peek(), ch != 0x0A && ch != 0x25 && ch != 0x20 {
                    scanner.advance(1)
                }
                if scanner.peek() == 0x25 { scanner.advance(1) }
                scanner.emit(start..<scanner.index, .variableSpecial)
                continue
            }
            if b == 0x22 /* " */ {
                scanner.scanQuotedString(quote: 0x22, allowEscapes: false)
                continue
            }
            if LexerScanner.isDigit(b) {
                scanner.scanNumber()
                continue
            }
            if LexerScanner.isIdentStart(b) {
                let range = scanner.scanIdentifierRange()
                let word = scanner.string(for: range).lowercased()
                if word == "rem" {
                    scanner.advanceToLineEnd()
                    scanner.emit(range.lowerBound..<scanner.index, .comment)
                    continue
                }
                if control.contains(word) { scanner.emit(range, .keywordControl) }
                else if keywords.contains(word) { scanner.emit(range, .keyword) }
                else if word == "off" || word == "on" { scanner.emit(range, .boolean) }
                continue
            }
            scanner.advanceScalar()
        }
    }

    private static func isLispSymbolStart(_ b: UInt8) -> Bool {
        LexerScanner.isIdentStart(b) || b == 0x2B || b == 0x2D || b == 0x2A || b == 0x2F || b == 0x3D || b == 0x3C || b == 0x3E || b == 0x3F || b == 0x21 || b == 0x23
    }

    private static func isLispSymbolChar(_ b: UInt8) -> Bool {
        isLispSymbolStart(b) || LexerScanner.isDigit(b) || b == 0x2E || b == 0x3A
    }
}
