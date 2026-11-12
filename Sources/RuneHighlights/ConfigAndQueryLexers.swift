import Foundation

/// Lexers and grammar specifications for configuration, build, infrastructure, query, and markup-adjacent languages.
enum ConfigAndQueryLexers {
    static func lex(_ scanner: inout LexerScanner, language: Language) -> Bool {
        switch language {
        case .dockerfile:
            lexDockerfile(&scanner)
            return true
        case .makefile:
            lexMakefile(&scanner)
            return true
        case .cmake:
            LanguageGrammarSpecs.lex(&scanner, spec: cmakeSpec, language: language)
            return true
        case .nix:
            LanguageGrammarSpecs.lex(&scanner, spec: nixSpec, language: language)
            return true
        case .terraform:
            LanguageGrammarSpecs.lex(&scanner, spec: terraformSpec, language: language)
            return true
        case .graphql:
            LanguageGrammarSpecs.lex(&scanner, spec: graphqlSpec, language: language)
            return true
        case .proto:
            LanguageGrammarSpecs.lex(&scanner, spec: protoSpec, language: language)
            return true
        case .gdresource:
            lexGDResource(&scanner)
            return true
        case .wasm:
            lexWasm(&scanner)
            return true
        case .latex:
            lexLaTeX(&scanner)
            return true
        case .asm:
            lexAssembly(&scanner)
            return true
        default:
            return false
        }
    }

    // MARK: - Specs

    private static let cmakeSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "elseif", "else", "endif", "foreach", "endforeach", "while", "endwhile", "break", "continue", "return"],
        declarationKeywords: ["function", "endfunction", "macro", "endmacro", "project", "cmake_minimum_required", "set", "unset", "option", "add_executable", "add_library", "add_subdirectory", "add_custom_target", "add_custom_command", "target_link_libraries", "target_include_directories", "target_compile_definitions", "target_compile_options", "install", "message"],
        importKeywords: ["include", "find_package", "find_library", "find_path", "find_program"],
        operatorKeywords: ["and", "or", "not", "equal", "strequal", "matches", "exists", "is_directory", "defined", "target"],
        otherKeywords: ["public", "private", "interface", "required", "quiet", "properties"],
        booleans: ["on", "off", "true", "false", "yes", "no"],
        builtinConstants: [],
        builtinTypes: [],
        specialVariables: [],
        caseInsensitiveKeywords: true,
        slashComments: false,
        hashComments: true,
        customBlockComment: (start: "#[[", end: "]]", nested: false),
        dollarVariables: true
    )

    private static let nixSpec = LanguageGrammarSpec(
        controlKeywords: ["if", "then", "else", "assert"],
        declarationKeywords: ["let", "in", "with", "rec", "inherit"],
        importKeywords: ["import"],
        operatorKeywords: [],
        otherKeywords: [],
        booleans: ["true", "false"],
        builtinConstants: ["null"],
        builtinTypes: [],
        builtinFunctions: ["builtins", "derivation", "fetchurl", "fetchTarball", "fetchFromGitHub", "map", "filter", "foldl'", "attrNames", "attrValues", "toString"],
        specialVariables: [],
        slashComments: true,
        hashComments: true,
        interpolation: .dollarBrace
    )

    private static let terraformSpec = LanguageGrammarSpec(
        controlKeywords: ["for", "in", "if", "else", "endif", "endfor"],
        declarationKeywords: ["resource", "data", "variable", "output", "locals", "module", "provider", "terraform", "backend", "required_providers", "provisioner", "lifecycle", "dynamic", "content"],
        importKeywords: ["source"],
        operatorKeywords: [],
        otherKeywords: ["count", "for_each", "depends_on", "default", "description", "type", "sensitive", "nullable", "validation", "condition", "error_message"],
        booleans: ["true", "false"],
        builtinConstants: ["null"],
        builtinTypes: ["string", "number", "bool", "list", "set", "map", "object", "tuple", "any"],
        builtinFunctions: ["var", "local", "each", "self", "path", "lookup", "merge", "concat", "flatten", "coalesce", "format", "join", "split", "jsonencode", "jsondecode", "file", "templatefile", "toset", "tolist", "tomap"],
        specialVariables: [],
        slashComments: true,
        hashComments: true,
        interpolation: .dollarBrace
    )

    private static let graphqlSpec = LanguageGrammarSpec(
        controlKeywords: [],
        declarationKeywords: ["type", "interface", "union", "enum", "input", "scalar", "schema", "extend", "query", "mutation", "subscription", "fragment", "directive", "repeatable"],
        importKeywords: [],
        operatorKeywords: ["on", "implements"],
        otherKeywords: [],
        booleans: ["true", "false"],
        builtinConstants: ["null"],
        builtinTypes: ["Int", "Float", "String", "Boolean", "ID"],
        specialVariables: [],
        slashComments: false,
        hashComments: true,
        tripleDoubleQuotes: true,
        atAttributes: true,
        dollarVariables: true
    )

    private static let protoSpec = LanguageGrammarSpec(
        controlKeywords: [],
        declarationKeywords: ["syntax", "edition", "message", "enum", "service", "rpc", "returns", "oneof", "map", "repeated", "optional", "required", "reserved", "extensions", "extend", "option", "stream"],
        importKeywords: ["import", "package", "public", "weak"],
        operatorKeywords: ["to", "max"],
        otherKeywords: [],
        booleans: ["true", "false"],
        builtinConstants: [],
        builtinTypes: ["double", "float", "int32", "int64", "uint32", "uint64", "sint32", "sint64", "fixed32", "fixed64", "sfixed32", "sfixed64", "bool", "string", "bytes"],
        specialVariables: []
    )

    // MARK: - Custom Config & Query Lexers

    private static func lexDockerfile(_ scanner: inout LexerScanner) {
        let instructions: Set<String> = [
            "from", "run", "cmd", "label", "maintainer", "expose", "env", "add", "copy",
            "entrypoint", "volume", "user", "workdir", "arg", "onbuild", "stopsignal",
            "healthcheck", "shell"
        ]
        var atLineStart = true

        while !scanner.isAtEnd {
            guard let b = scanner.peek() else { break }
            if b == 0x0A {
                scanner.advance(1)
                atLineStart = true
                continue
            }
            if b == 0x20 || b == 0x09 || b == 0x0D {
                scanner.skipHorizontalWhitespace()
                continue
            }
            if b == 0x23 /* # */ {
                scanner.scanLineComment()
                atLineStart = false
                continue
            }
            if b == 0x22 || b == 0x27 {
                scanner.scanQuotedString(quote: b)
                atLineStart = false
                continue
            }
            if b == 0x24 /* $ */ {
                let start = scanner.index
                scanner.advance(1)
                if scanner.peek() == 0x7B {
                    scanner.advance(1)
                    let _ = scanner.scanIdentifierRange()
                    if scanner.peek() == 0x7D { scanner.advance(1) }
                } else {
                    let _ = scanner.scanIdentifierRange()
                }
                scanner.emit(start..<scanner.index, .variableSpecial)
                atLineStart = false
                continue
            }
            if atLineStart && LexerScanner.isIdentStart(b) {
                let range = scanner.scanIdentifierRange()
                let word = scanner.string(for: range).lowercased()
                if instructions.contains(word) {
                    scanner.emit(range, .keyword)
                }
                atLineStart = false
                continue
            }
            if LexerScanner.isIdentStart(b) {
                let range = scanner.scanIdentifierRange()
                let word = scanner.string(for: range).lowercased()
                if word == "as" {
                    scanner.emit(range, .keywordOperator)
                }
                atLineStart = false
                continue
            }
            atLineStart = false
            scanner.advanceScalar()
        }
    }

    private static func lexMakefile(_ scanner: inout LexerScanner) {
        let directives: Set<String> = ["ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "include", "-include", "sinclude", "export", "unexport", "override", "define", "endef", "vpath"]
        var atLineStart = true

        while !scanner.isAtEnd {
            guard let b = scanner.peek() else { break }
            if b == 0x0A {
                scanner.advance(1)
                atLineStart = true
                continue
            }
            if b == 0x20 || b == 0x09 || b == 0x0D {
                scanner.skipHorizontalWhitespace()
                continue
            }
            if b == 0x23 /* # */ {
                scanner.scanLineComment()
                atLineStart = false
                continue
            }
            if b == 0x24 /* $ */ {
                let start = scanner.index
                scanner.advance(1)
                if let open = scanner.peek(), open == 0x28 || open == 0x7B {
                    let close: UInt8 = open == 0x28 ? 0x29 : 0x7D
                    scanner.advance(1)
                    while let ch = scanner.peek(), ch != 0x0A && ch != close {
                        scanner.advanceScalar()
                    }
                    if scanner.peek() == close { scanner.advance(1) }
                } else {
                    scanner.advanceScalar()
                }
                scanner.emit(start..<scanner.index, .variableSpecial)
                atLineStart = false
                continue
            }
            if b == 0x22 || b == 0x27 {
                scanner.scanQuotedString(quote: b)
                atLineStart = false
                continue
            }
            if atLineStart && (LexerScanner.isIdentStart(b) || b == 0x2E) {
                let start = scanner.index
                while let ch = scanner.peek(), LexerScanner.isIdentContinue(ch) || ch == 0x2D || ch == 0x2E || ch == 0x2F {
                    scanner.advance(1)
                }
                let range = start..<scanner.index
                let word = scanner.string(for: range)
                if directives.contains(word) {
                    scanner.emit(range, word.contains("include") ? .keywordImport : .keywordControl)
                } else if scanner.peek() == 0x3A /* : */ && scanner.peek(1) != 0x3D {
                    scanner.emit(range, .functionDefinition)
                } else {
                    scanner.skipHorizontalWhitespace()
                    if scanner.peek() == 0x3D || scanner.startsWith(":=") || scanner.startsWith("?=") || scanner.startsWith("+=") {
                        scanner.emit(range, .property)
                    }
                }
                atLineStart = false
                continue
            }
            atLineStart = false
            scanner.advanceScalar()
        }
    }

    private static func lexGDResource(_ scanner: inout LexerScanner) {
        while !scanner.isAtEnd {
            scanner.skipWhitespace()
            guard let b = scanner.peek() else { break }

            if b == 0x3B /* ; */ {
                scanner.scanLineComment()
                continue
            }
            if b == 0x5B /* [ */ {
                let start = scanner.index
                scanner.advance(1)
                let headerRange = scanner.scanIdentifierRange()
                scanner.emit(start..<headerRange.lowerBound, .punctuationBracket)
                scanner.emit(headerRange, .title)
                continue
            }
            if b == 0x5D /* ] */ {
                let start = scanner.index
                scanner.advance(1)
                scanner.emit(start..<scanner.index, .punctuationBracket)
                continue
            }
            if b == 0x22 /* " */ {
                scanner.scanQuotedString(quote: 0x22, multiline: true)
                continue
            }
            if LexerScanner.isDigit(b) || (b == 0x2D && scanner.peek(1).map(LexerScanner.isDigit) == true) {
                if b == 0x2D { scanner.advance(1) }
                scanner.scanNumber()
                continue
            }
            if LexerScanner.isIdentStart(b) {
                let range = scanner.scanIdentifierRange()
                let word = scanner.string(for: range)
                if word == "true" || word == "false" {
                    scanner.emit(range, .boolean)
                } else if word == "null" {
                    scanner.emit(range, .constantBuiltin)
                } else if scanner.peek() == 0x28 {
                    scanner.emit(range, .constructor)
                } else {
                    scanner.skipHorizontalWhitespace()
                    if scanner.peek() == 0x3D {
                        scanner.emit(range, .property)
                    } else if let first = word.utf8.first, LexerScanner.isUpperASCII(first) {
                        scanner.emit(range, .type)
                    }
                }
                continue
            }
            scanner.advanceScalar()
        }
    }

    private static func lexWasm(_ scanner: inout LexerScanner) {
        let keywords: Set<String> = [
            "module", "func", "param", "result", "local", "global", "memory", "table", "elem", "data",
            "type", "import", "export", "start", "offset", "mut", "block", "loop", "if", "then", "else",
            "end", "br", "br_if", "br_table", "return", "call", "call_indirect", "drop", "select",
            "local.get", "local.set", "local.tee", "global.get", "global.set",
            "i32.load", "i64.load", "f32.load", "f64.load", "i32.store", "i64.store",
            "i32.const", "i64.const", "f32.const", "f64.const",
            "i32.add", "i32.sub", "i32.mul", "i64.add", "i64.sub", "i64.mul"
        ]
        let types: Set<String> = ["i32", "i64", "f32", "f64", "v128", "funcref", "externref"]

        while !scanner.isAtEnd {
            scanner.skipWhitespace()
            guard let b = scanner.peek() else { break }

            if scanner.startsWith(";;") {
                scanner.scanLineComment()
                continue
            }
            if scanner.startsWith("(;") {
                let start = scanner.index
                scanner.advance(2)
                var depth = 1
                while !scanner.isAtEnd && depth > 0 {
                    if scanner.startsWith("(;") { depth += 1; scanner.advance(2) }
                    else if scanner.startsWith(";)") { depth -= 1; scanner.advance(2) }
                    else { scanner.advanceScalar() }
                }
                scanner.emit(start..<scanner.index, .comment)
                continue
            }
            if b == 0x22 /* " */ {
                scanner.scanQuotedString(quote: 0x22)
                continue
            }
            if b == 0x24 /* $ */ {
                let start = scanner.index
                scanner.advance(1)
                while let ch = scanner.peek(), LexerScanner.isIdentContinue(ch) || ch == 0x2E || ch == 0x2D {
                    scanner.advance(1)
                }
                scanner.emit(start..<scanner.index, .variable)
                continue
            }
            if b == 0x28 || b == 0x29 {
                let start = scanner.index
                scanner.advance(1)
                scanner.emit(start..<scanner.index, .punctuationBracket)
                continue
            }
            if LexerScanner.isDigit(b) || (b == 0x2D && scanner.peek(1).map(LexerScanner.isDigit) == true) {
                if b == 0x2D { scanner.advance(1) }
                scanner.scanNumber()
                continue
            }
            if LexerScanner.isIdentStart(b) {
                let start = scanner.index
                while let ch = scanner.peek(), LexerScanner.isIdentContinue(ch) || ch == 0x2E || ch == 0x5F {
                    scanner.advance(1)
                }
                let range = start..<scanner.index
                let word = scanner.string(for: range)
                if types.contains(word) { scanner.emit(range, .typeBuiltin) }
                else if keywords.contains(word) { scanner.emit(range, .keyword) }
                else if word.contains(".") { scanner.emit(range, .function) }
                continue
            }
            scanner.advanceScalar()
        }
    }

    private static func lexLaTeX(_ scanner: inout LexerScanner) {
        let sectionCmds: Set<String> = ["part", "chapter", "section", "subsection", "subsubsection", "paragraph", "title", "author"]
        let envCmds: Set<String> = ["begin", "end", "documentclass", "usepackage", "include", "input", "bibliography"]

        while !scanner.isAtEnd {
            scanner.skipWhitespace()
            guard let b = scanner.peek() else { break }

            if b == 0x25 /* % */ {
                scanner.scanLineComment()
                continue
            }
            if b == 0x5C /* \ */ {
                let start = scanner.index
                scanner.advance(1)
                if let next = scanner.peek(), LexerScanner.isAlpha(next) {
                    let nameRange = scanner.scanIdentifierRange()
                    let name = scanner.string(for: nameRange)
                    if sectionCmds.contains(name) {
                        scanner.emit(start..<scanner.index, .title)
                    } else if envCmds.contains(name) {
                        scanner.emit(start..<scanner.index, .keywordControl)
                    } else {
                        scanner.emit(start..<scanner.index, .function)
                    }
                } else if !scanner.isAtEnd {
                    scanner.advanceScalar()
                    scanner.emit(start..<scanner.index, .stringEscape)
                }
                continue
            }
            if b == 0x24 /* $ */ {
                let start = scanner.index
                scanner.advance(1)
                if scanner.peek() == 0x24 { scanner.advance(1) }
                scanner.emit(start..<scanner.index, .punctuationSpecial)
                continue
            }
            if b == 0x7B || b == 0x7D || b == 0x5B || b == 0x5D {
                let start = scanner.index
                scanner.advance(1)
                scanner.emit(start..<scanner.index, .punctuationBracket)
                continue
            }
            scanner.advanceScalar()
        }
    }

    private static func lexAssembly(_ scanner: inout LexerScanner) {
        let directives: Set<String> = ["section", "global", "globl", "extern", "text", "data", "bss", "rodata", "align", "balign", "p2align", "byte", "word", "long", "quad", "ascii", "asciz", "string", "equ", "set", "macro", "endm", "db", "dw", "dd", "dq", "resb", "resw", "resd", "resq", "bits", "default"]
        let registers: Set<String> = [
            "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp", "rip",
            "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
            "eax", "ebx", "ecx", "edx", "esi", "edi", "ebp", "esp",
            "ax", "bx", "cx", "dx", "al", "bl", "cl", "dl", "ah", "bh", "ch", "dh",
            "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15",
            "w0", "w1", "w2", "w3", "w4", "w5", "w6", "w7", "sp", "lr", "pc", "xzr", "wzr"
        ]
        let instructions: Set<String> = [
            "mov", "movz", "movk", "lea", "add", "sub", "mul", "imul", "div", "idiv", "inc", "dec",
            "and", "or", "xor", "not", "shl", "shr", "sar", "cmp", "test", "jmp", "je", "jne", "jz", "jnz",
            "jg", "jge", "jl", "jle", "ja", "jb", "call", "ret", "push", "pop", "syscall", "int", "nop",
            "ldr", "str", "ldp", "stp", "adr", "adrp", "b", "bl", "blr", "br", "cbz", "cbnz", "svc"
        ]

        while !scanner.isAtEnd {
            scanner.skipWhitespace()
            guard let b = scanner.peek() else { break }

            if b == 0x3B /* ; */ || scanner.startsWith("//") {
                scanner.scanLineComment()
                continue
            }
            if scanner.startsWith("/*") {
                scanner.scanBlockComment()
                continue
            }
            if b == 0x23 /* # */ {
                let start = scanner.index
                scanner.advance(1)
                if let next = scanner.peek(), LexerScanner.isDigit(next) {
                    scanner.scanNumber()
                } else {
                    scanner.advanceToLineEnd()
                    scanner.emit(start..<scanner.index, .comment)
                }
                continue
            }
            if b == 0x22 || b == 0x27 {
                scanner.scanQuotedString(quote: b)
                continue
            }
            if b == 0x2E /* . */ {
                let start = scanner.index
                scanner.advance(1)
                let _ = scanner.scanIdentifierRange()
                let name = scanner.string(for: (start + 1)..<scanner.index).lowercased()
                if directives.contains(name) {
                    scanner.emit(start..<scanner.index, .preproc)
                } else if scanner.peek() == 0x3A {
                    scanner.advance(1)
                    scanner.emit(start..<scanner.index, .label)
                }
                continue
            }
            if b == 0x25 /* % */ {
                let start = scanner.index
                scanner.advance(1)
                let _ = scanner.scanIdentifierRange()
                scanner.emit(start..<scanner.index, .variableSpecial)
                continue
            }
            if LexerScanner.isDigit(b) {
                scanner.scanNumber()
                continue
            }
            if LexerScanner.isIdentStart(b) {
                let range = scanner.scanIdentifierRange()
                let word = scanner.string(for: range).lowercased()
                if scanner.peek() == 0x3A /* : */ {
                    scanner.advance(1)
                    scanner.emit(range.lowerBound..<scanner.index, .label)
                } else if registers.contains(word) {
                    scanner.emit(range, .variableSpecial)
                } else if instructions.contains(word) {
                    scanner.emit(range, .keyword)
                } else if directives.contains(word) {
                    scanner.emit(range, .preproc)
                }
                continue
            }
            scanner.advanceScalar()
        }
    }
}
