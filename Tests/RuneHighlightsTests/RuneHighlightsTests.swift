import Foundation
import Testing
@testable import RuneHighlights

@Suite("RuneHighlights Tests")
struct RuneHighlightsTests {
    private func tokenKinds(for source: String, language: Language) -> [HighlightToken.Kind] {
        Highlighter().highlight(source, language: language).map(\.token.kind)
    }

    private func assertSpansValid(_ source: String, spans: [HighlightSpan]) {
        let byteCount = source.utf8.count
        var lastEnd = 0
        for span in spans {
            #expect(span.utf8Range.lowerBound >= lastEnd)
            #expect(span.utf8Range.upperBound <= byteCount)
            #expect(span.utf8Range.lowerBound < span.utf8Range.upperBound)
            #expect(span.token != .none)
            #expect(span.text(in: source) != nil)
            lastEnd = span.utf8Range.upperBound
        }
    }

    @Test func languageLookupAndAliases() {
        #expect(Language.fromName("rust") == .rust)
        #expect(Language.fromName("RS") == .rust)
        #expect(Language.fromName("swift") == .swift)
        #expect(Language.fromName("ts") == .typescript)
        #expect(Language.fromName("C++") == .cpp)
        #expect(Language.fromName("py") == .python)
        #expect(Language.fromName("yml") == .yaml)
        #expect(Language.fromName("metal") == .msl)
        #expect(Language.fromName("msl") == .msl)
        #expect(Language.fromName("wgsl") == .wgsl)
        #expect(Language.fromName("plain") == .plain)
        #expect(Language.all.count >= 80)
        #expect(Highlighter().highlight("hello", language: .plain).isEmpty)
    }

    @Test func themeParentFallbackResolution() {
        let theme = HighlightTheme.defaultLight
        let controlStyle = theme.style(for: HighlightToken(.keywordControl))
        let keywordStyle = theme.style(for: HighlightToken(.keyword))
        #expect(controlStyle != nil)
        #expect(controlStyle == keywordStyle)
        #expect(HighlightToken(.keywordControl).parent == HighlightToken(.keyword))
    }

    @Test func rustLexerHandlesCommentsRawStringsLifetimesAndMacros() {
        let src = """
        /// Doc comment
        #[derive(Debug)]
        fn greet<'a>(name: &'a str) -> usize {
            let s = r#"hello\\n"#;
            println!("hi {}", name);
            42u64
        }
        """
        let spans = Highlighter().highlight(src, language: .rust)
        assertSpansValid(src, spans: spans)
        let kinds = spans.map(\.token.kind)
        #expect(kinds.contains(.commentDoc))
        #expect(kinds.contains(.attribute))
        #expect(kinds.contains(.keywordDeclaration))
        #expect(kinds.contains(.functionDefinition))
        #expect(kinds.contains(.label))
        #expect(kinds.contains(.string))
        #expect(kinds.contains(.function))
        #expect(kinds.contains(.number))
    }

    @Test func swiftLexerHandlesMultilineStringsAttributesAndKeywords() {
        let src = """
        import Foundation

        @MainActor
        struct Counter: Sendable {
            var count: Int = 0
            mutating func increment() async {
                let msg = "val: \\(count)"
                if count > 0 { count += 1 }
            }
        }
        """
        let spans = Highlighter().highlight(src, language: .swift)
        assertSpansValid(src, spans: spans)
        let kinds = spans.map(\.token.kind)
        #expect(kinds.contains(.keywordImport))
        #expect(kinds.contains(.attribute))
        #expect(kinds.contains(.keywordDeclaration))
        #expect(kinds.contains(.typeBuiltin))
        #expect(kinds.contains(.functionDefinition))
        #expect(kinds.contains(.punctuationSpecial))
        #expect(kinds.contains(.variable))
        #expect(kinds.contains(.keywordControl))
    }

    @Test func jsTsPythonGoCppLexersProduceExpectedTokens() {
        let tsSrc = "export async function load(url: string): Promise<number> { return 123; }"
        let tsKinds = tokenKinds(for: tsSrc, language: .typescript)
        #expect(tsKinds.contains(.keywordImport))
        #expect(tsKinds.contains(.keywordDeclaration))
        #expect(tsKinds.contains(.typeBuiltin))
        #expect(tsKinds.contains(.keywordControl))
        #expect(tsKinds.contains(.number))

        let pySrc = """
        @dataclass
        def add(a: int, b: int) -> int:
            # sum
            return a + b if True else None
        """
        let pyKinds = tokenKinds(for: pySrc, language: .python)
        #expect(pyKinds.contains(.attribute))
        #expect(pyKinds.contains(.keywordDeclaration))
        #expect(pyKinds.contains(.comment))
        #expect(pyKinds.contains(.boolean))
        #expect(pyKinds.contains(.constantBuiltin))

        let goSrc = "package main\nfunc main() { x := `raw`; _ = len(x) }"
        let goKinds = tokenKinds(for: goSrc, language: .go)
        #expect(goKinds.contains(.keywordDeclaration))
        #expect(goKinds.contains(.namespace))
        #expect(goKinds.contains(.functionDefinition))
        #expect(goKinds.contains(.string))

        let cppSrc = "#include <vector>\nconstexpr int N = 0x10;\nint* p = nullptr;"
        let cppKinds = tokenKinds(for: cppSrc, language: .cpp)
        #expect(cppKinds.contains(.preproc))
        #expect(cppKinds.contains(.typeBuiltin))
        #expect(cppKinds.contains(.number))
        #expect(cppKinds.contains(.constantBuiltin))
    }

    @Test func dataAndMarkupLexers() {
        let jsonSrc = #"{"name": "rune", "count": 3, "ok": true, "extra": null}"#
        let jsonKinds = tokenKinds(for: jsonSrc, language: .json)
        #expect(jsonKinds.contains(.propertyJSONKey))
        #expect(jsonKinds.contains(.string))
        #expect(jsonKinds.contains(.number))
        #expect(jsonKinds.contains(.boolean))
        #expect(jsonKinds.contains(.constantBuiltin))

        let tomlSrc = "[package]\nname = \"rune\"\nversion = 1\n"
        let tomlKinds = tokenKinds(for: tomlSrc, language: .toml)
        #expect(tomlKinds.contains(.punctuationBracket))
        #expect(tomlKinds.contains(.property))
        #expect(tomlKinds.contains(.string))
        #expect(tomlKinds.contains(.number))

        let yamlSrc = "---\nname: rune\nenabled: true\n- item\n"
        let yamlKinds = tokenKinds(for: yamlSrc, language: .yaml)
        #expect(yamlKinds.contains(.punctuationSpecial))
        #expect(yamlKinds.contains(.property))
        #expect(yamlKinds.contains(.boolean))
        #expect(yamlKinds.contains(.string))

        let mdSrc = "# Title\n**bold** and *italic* `code` [link](https://example.com)\n"
        let mdKinds = tokenKinds(for: mdSrc, language: .markdown)
        #expect(mdKinds.contains(.title))
        #expect(mdKinds.contains(.emphasisStrong))
        #expect(mdKinds.contains(.emphasis))
        #expect(mdKinds.contains(.textLiteral))
        #expect(mdKinds.contains(.linkText))
        #expect(mdKinds.contains(.linkURI))

        let bashSrc = "#!/bin/bash\nif [ -f \"$HOME/test\" ]; then echo $PATH; fi\n"
        let bashKinds = tokenKinds(for: bashSrc, language: .bash)
        #expect(bashKinds.contains(.comment))
        #expect(bashKinds.contains(.keywordControl))
        #expect(bashKinds.contains(.function))
        #expect(bashKinds.contains(.string))
        #expect(bashKinds.contains(.variable))

        let htmlSrc = "<!DOCTYPE html><!-- hi --><div class=\"card\">&amp;</div>"
        let htmlKinds = tokenKinds(for: htmlSrc, language: .html)
        #expect(htmlKinds.contains(.tagDoctype))
        #expect(htmlKinds.contains(.comment))
        #expect(htmlKinds.contains(.tag))
        #expect(htmlKinds.contains(.attribute))
        #expect(htmlKinds.contains(.stringSpecial))

        let cssSrc = ".btn:hover { color: #ff0000; padding: 12px; }"
        let cssKinds = tokenKinds(for: cssSrc, language: .css)
        #expect(cssKinds.contains(.selectorClass))
        #expect(cssKinds.contains(.selectorPseudo))
        #expect(cssKinds.contains(.property))
        #expect(cssKinds.contains(.number))

        let sqlSrc = "SELECT id, name FROM users WHERE active = TRUE LIMIT 10; -- query"
        let sqlKinds = tokenKinds(for: sqlSrc, language: .sql)
        #expect(sqlKinds.contains(.keyword))
        #expect(sqlKinds.contains(.boolean))
        #expect(sqlKinds.contains(.number))
        #expect(sqlKinds.contains(.comment))

        let wgslSrc = "@vertex fn vs_main(@location(0) pos: vec3<f32>) -> @builtin(position) vec4<f32> { return vec4(pos, 1.0); }"
        let wgslKinds = tokenKinds(for: wgslSrc, language: .wgsl)
        #expect(wgslKinds.contains(.attribute))
        #expect(wgslKinds.contains(.keywordDeclaration))
        #expect(wgslKinds.contains(.typeBuiltin))

        let mslSrc = "#include <metal_stdlib>\nkernel void k(device float4* out [[buffer(0)]]) {}"
        let mslKinds = tokenKinds(for: mslSrc, language: .msl)
        #expect(mslKinds.contains(.preproc))
        #expect(mslKinds.contains(.keyword))
        #expect(mslKinds.contains(.typeBuiltin))
        #expect(mslKinds.contains(.attribute))

        let diffSrc = "diff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n@@ -1,2 +1,2 @@\n-old\n+new\n"
        let diffKinds = tokenKinds(for: diffSrc, language: .diff)
        #expect(diffKinds.contains(.function))
        #expect(diffKinds.contains(.attribute))
        #expect(diffKinds.contains(.diffMinus))
        #expect(diffKinds.contains(.diffPlus))
    }

    @Test func streamingHighlighterMatchesFullHighlight() {
        let full = """
        func add(_ a: Int, _ b: Int) -> Int {
            return a + b
        }
        """
        var stream = HighlightStream(language: .swift)
        let part1 = "func add(_ a: Int, _ b: Int) -> Int {\n    ret"
        let s1 = stream.highlight(part1)
        #expect(s1 == Highlighter().highlight(part1, language: .swift))

        let s2 = stream.highlight(full)
        #expect(stream.continues(full))
        #expect(s2 == Highlighter().highlight(full, language: .swift))

        // Non-continuing input resets cleanly
        let other = "let y = 42"
        #expect(!stream.continues(other))
        #expect(stream.highlight(other) == Highlighter().highlight(other, language: .swift))
    }

    @Test func filenameShebangAndModelineDetection() {
        #expect(Language.fromFilename("src/main.rs") == .rust)
        #expect(Language.fromFilename("/app/Dockerfile") == .dockerfile)
        #expect(Language.fromFilename("Dockerfile.prod") == .dockerfile)
        #expect(Language.fromFilename("GNUmakefile") == .makefile)
        #expect(Language.fromFilename("CMakeLists.txt") == .cmake)
        #expect(Language.fromFilename("Package.swift") == .swift)
        #expect(Language.fromFilename("types.d.ts") == .typescript)
        #expect(Language.fromFilename("shader.metal") == .msl)
        #expect(Language.fromFilename("scene.tscn") == .gdresource)
        #expect(Language.fromFilename("main.tf") == .terraform)
        #expect(Language.fromFilename("flake.nix") == .nix)
        #expect(Language.fromFilename(".zshrc") == .bash)

        #expect(Language.fromShebang("#!/usr/bin/env python3") == .python)
        #expect(Language.fromShebang("#!/usr/bin/env -S deno run") == .typescript)
        #expect(Language.fromShebang("#!/bin/bash") == .bash)
        #expect(Language.fromShebang("#!/usr/bin/env ruby3.2") == .ruby)
        #expect(Language.fromShebang("#!/usr/bin/env pwsh") == .powershell)
        #expect(Language.fromShebang("not a shebang") == nil)

        #expect(Language.detect(filename: "foo.zig", source: "const x = 1;") == .zig)
        #expect(Language.detect(source: "#!/usr/bin/env lua5.4\nprint(1)") == .lua)
        #expect(Language.detect(source: "// -*- mode: rust -*-\nfn main() {}") == .rust)
        #expect(Language.detect(source: "# vim: set ft=elixir:\ndefmodule A do end") == .elixir)
        #expect(Language.detect(source: "<?xml version=\"1.0\"?><root/>") == .xml)
        #expect(Language.detect(source: "<?php echo 1;") == .php)
        #expect(Language.detect(source: "<!DOCTYPE html><html></html>") == .html)
        #expect(Language.detect(source: "diff --git a/a b/a") == .diff)
    }

    @Test func functionalAndScriptingLanguages() {
        let rubySrc = "# comment\ndef greet(name)\n  puts \"hi #{name}\" + :ok.to_s\nend"
        let rubyKinds = tokenKinds(for: rubySrc, language: .ruby)
        #expect(rubyKinds.contains(.comment))
        #expect(rubyKinds.contains(.keywordDeclaration))
        #expect(rubyKinds.contains(.functionDefinition))
        #expect(rubyKinds.contains(.stringSpecialSymbol))

        let haskellSrc = "{- nested {- block -} -}\nmodule Main where\nmain :: IO ()\nmain = if True then putStrLn \"hi\" else pure ()"
        let haskellKinds = tokenKinds(for: haskellSrc, language: .haskell)
        #expect(haskellKinds.contains(.comment))
        #expect(haskellKinds.contains(.keywordImport))
        #expect(haskellKinds.contains(.boolean))
        #expect(haskellKinds.contains(.string))

        let elixirSrc = "# elixir\ndefmodule App do\n  @doc \"hi\"\n  def run(x), do: {:ok, x}\nend"
        let elixirKinds = tokenKinds(for: elixirSrc, language: .elixir)
        #expect(elixirKinds.contains(.comment))
        #expect(elixirKinds.contains(.keywordDeclaration))
        #expect(elixirKinds.contains(.attribute))
        #expect(elixirKinds.contains(.stringSpecialSymbol))

        let cljSrc = ";; clojure\n(defn add [a b] (+ a b) :done)"
        let cljKinds = tokenKinds(for: cljSrc, language: .clojure)
        #expect(cljKinds.contains(.comment))
        #expect(cljKinds.contains(.keywordDeclaration))
        #expect(cljKinds.contains(.stringSpecialSymbol))
        #expect(cljKinds.contains(.punctuationBracket))

        let ocamlSrc = "(* outer (* inner *) *)\nlet rec fact n = if n <= 1 then 1 else n * fact (n - 1)"
        let ocamlKinds = tokenKinds(for: ocamlSrc, language: .ocaml)
        #expect(ocamlKinds.contains(.comment))
        #expect(ocamlKinds.contains(.keywordDeclaration))
        #expect(ocamlKinds.contains(.keywordControl))
        #expect(ocamlKinds.contains(.number))

        let luaSrc = "--[[ block ]]\nlocal function hi() return \"ok\" end"
        let luaKinds = tokenKinds(for: luaSrc, language: .lua)
        #expect(luaKinds.contains(.comment))
        #expect(luaKinds.contains(.keywordDeclaration))
        #expect(luaKinds.contains(.keywordControl))
        #expect(luaKinds.contains(.string))

        let psSrc = "<# help #>\nfunction Get-Item { if ($true) { return $null } }"
        let psKinds = tokenKinds(for: psSrc, language: .powershell)
        #expect(psKinds.contains(.comment))
        #expect(psKinds.contains(.keywordDeclaration))
        #expect(psKinds.contains(.keywordControl))
    }

    @Test func configInfraQueryAndSystemsLanguages() {
        let dockerSrc = "# app\nFROM alpine:3.19 AS builder\nWORKDIR /app\nRUN echo $HOME"
        let dockerKinds = tokenKinds(for: dockerSrc, language: .dockerfile)
        #expect(dockerKinds.contains(.comment))
        #expect(dockerKinds.contains(.keyword))
        #expect(dockerKinds.contains(.function))
        #expect(dockerKinds.contains(.variable))

        let makeSrc = "# build\nall: main.o\n\t$(CC) -o app main.o"
        let makeKinds = tokenKinds(for: makeSrc, language: .makefile)
        #expect(makeKinds.contains(.comment))
        #expect(makeKinds.contains(.function))
        #expect(makeKinds.contains(.variable))

        let tfSrc = "resource \"aws_s3_bucket\" \"b\" {\n  bucket = \"my-bucket-${var.env}\"\n  force_destroy = true\n}"
        let tfKinds = tokenKinds(for: tfSrc, language: .terraform)
        #expect(tfKinds.contains(.keywordDeclaration))
        #expect(tfKinds.contains(.string))
        #expect(tfKinds.contains(.boolean))

        let gqlSrc = "# query\ntype User { id: ID! name: String }\nquery GetUser($id: ID!) { user(id: $id) { name } }"
        let gqlKinds = tokenKinds(for: gqlSrc, language: .graphql)
        #expect(gqlKinds.contains(.comment))
        #expect(gqlKinds.contains(.keyword))
        #expect(gqlKinds.contains(.typeBuiltin))
        #expect(gqlKinds.contains(.variableParameter))

        let protoSrc = "syntax = \"proto3\";\npackage rune;\nmessage Item { repeated string tags = 1; }"
        let protoKinds = tokenKinds(for: protoSrc, language: .proto)
        #expect(protoKinds.contains(.keywordDeclaration))
        #expect(protoKinds.contains(.namespace))
        #expect(protoKinds.contains(.typeBuiltin))
        #expect(protoKinds.contains(.number))

        let zigSrc = "const std = @import(\"std\");\npub fn main() void { var x: u32 = 10; }"
        let zigKinds = tokenKinds(for: zigSrc, language: .zig)
        #expect(zigKinds.contains(.keywordDeclaration))
        #expect(zigKinds.contains(.functionDefinition))
        #expect(zigKinds.contains(.typeBuiltin))
        #expect(zigKinds.contains(.number))

        let asmSrc = "; entry\n.global _start\n_start:\n  mov rax, 60\n  syscall"
        let asmKinds = tokenKinds(for: asmSrc, language: .asm)
        #expect(asmKinds.contains(.comment))
        #expect(asmKinds.contains(.preproc))
        #expect(asmKinds.contains(.label))
        #expect(asmKinds.contains(.keyword))
        #expect(asmKinds.contains(.variableSpecial))
    }

    @Test func all81LanguagesProduceValidSpans() {
        let samples: [Language: String] = [
            .angularHTML: "<div *ngIf=\"ok\">{{ title }}</div>",
            .asm: "; asm\nmov rax, 1",
            .astro: "---\nconst title = \"Hi\";\n---\n<h1>{title}</h1>",
            .bash: "echo \"hello $USER\"",
            .bat: "@echo off\nREM test\nif %X%==1 echo ok",
            .c: "int main(void) { return 0; }",
            .c3: "fn int main() { return 0; }",
            .clojure: "(defn f [x] (+ x 1))",
            .cmake: "cmake_minimum_required(VERSION 3.20)\nproject(Rune)",
            .cpp: "int main() { return 0; }",
            .csharp: "public class C { public int X => 1; }",
            .css: "body { color: red; }",
            .cuda: "__global__ void k(float* p) { p[0] = 1.0f; }",
            .dart: "void main() { print('hi'); }",
            .diff: "+added\n-removed\n",
            .dockerfile: "FROM scratch\nCOPY . /app",
            .elixir: "defmodule A do def f, do: :ok end",
            .elm: "module Main exposing (main)\nmain = 1",
            .erlang: "-module(a).\nstart() -> ok.",
            .fortran: "program p\n  integer :: x = 1\nend program p",
            .fortranFixedForm: "      INTEGER X\n      X = 1\n      END",
            .fsharp: "let x = if true then 1 else 0",
            .gdresource: "[gd_resource type=\"Theme\" format=3]\n[resource]\nval = 1",
            .gdscript: "extends Node\nfunc _ready(): pass",
            .gdshader: "shader_type canvas_item;\nvoid fragment() { COLOR = vec4(1.0); }",
            .gleam: "pub fn main() { let x = 1 }",
            .glsl: "void main() { gl_Position = vec4(1.0); }",
            .go: "package main\nfunc main() { x := 1 }",
            .graphql: "type Query { ok: Boolean }",
            .groovy: "def x = \"hi ${name}\"",
            .haskell: "main = if True then 1 else 0",
            .hlsl: "float4 main() : SV_Target { return float4(1.0, 0.0, 0.0, 1.0); }",
            .html: "<div>hello</div>",
            .java: "public class Main { public static void main(String[] args) {} }",
            .javascript: "const x = 1;",
            .json: "{\"a\": 1}",
            .json5: "{ // c\n a: 1 }",
            .jsonl: "{\"a\": 1}\n{\"b\": 2}",
            .jsx: "const el = <Card title=\"hi\" />;",
            .julia: "function f(x) return x + 1 end",
            .kotlin: "fun main() { val x = 1 }",
            .latex: "\\section{Intro}\n% note\n$x + y$",
            .less: "@color: #fff; .a { color: @color; }",
            .lisp: "(defun f (x) (+ x 1))",
            .lua: "local x = 1",
            .makefile: "all:\n\techo ok",
            .markdown: "# Heading\n*em*",
            .matlab: "function y = f(x)\n  y = x + 1;\nend",
            .mdx: "# Title\n<Box />",
            .nim: "proc f(x: int): int = x + 1",
            .nix: "let x = 1; in x",
            .objectiveC: "@interface A : NSObject\n@end",
            .ocaml: "let x = 1 in x + 2",
            .pascal: "program P; begin WriteLn('hi'); end.",
            .perl: "my $x = 1; print $x;",
            .php: "<?php $x = 1; echo $x;",
            .powershell: "$x = 1; if ($true) { Write-Output $x }",
            .proto: "syntax = \"proto3\"; message M { int32 id = 1; }",
            .python: "def f(x: int) -> int:\n    return x + 1",
            .r: "x <- c(1, 2, 3)",
            .ruby: "def f(x); x + 1; end",
            .rust: "fn main() { let x = 1; }",
            .sass: "$c: red\n.a\n  color: $c",
            .scala: "object Main { val x: Int = 1 }",
            .scss: "$c: #fff; .a { color: $c; }",
            .solidity: "contract C { uint256 public x = 1; }",
            .sql: "SELECT 1;",
            .svelte: "<script>let x = 1;</script><p>{x}</p>",
            .swift: "let x = 1",
            .terraform: "resource \"null_resource\" \"a\" {}",
            .toml: "name = \"rune\"",
            .typescript: "const x: number = 1;",
            .tsrx: "export function View() { return <div />; }",
            .tsx: "const el: JSX.Element = <App />;",
            .vue: "<template><div>hi</div></template>",
            .wasm: "(module (func (result i32) (i32.const 1)))",
            .wgsl: "fn main() -> @location(0) vec4<f32> { return vec4(1.0); }",
            .xml: "<root id=\"1\"/>",
            .yaml: "key: value",
            .zig: "const x: u32 = 1;",
            .msl: "kernel void k() {}",
        ]

        #expect(samples.count == Language.all.count)
        let highlighter = Highlighter()
        for lang in Language.all {
            let src = samples[lang]!
            let spans = highlighter.highlight(src, language: lang)
            assertSpansValid(src, spans: spans)
            #expect(!spans.isEmpty, "Expected non-empty spans for \(lang.name)")
        }
    }

    @Test func utf8MultibyteSafety() {
        let src = """
        // 日本語コメント 🚀
        let greeting = "こんにちは 🌍 \\(name)"
        let π = 3.14
        """
        let spans = Highlighter().highlight(src, language: .swift)
        assertSpansValid(src, spans: spans)
        #expect(spans.contains { $0.token.kind == .comment })
        #expect(spans.contains { $0.token.kind == .string })
        #expect(spans.contains { $0.token.kind == .number && $0.text(in: src) == "3.14" })
        #expect(spans.contains { $0.token.kind == .variable && $0.text(in: src)?.trimmingCharacters(in: .whitespaces) == "π" })
    }

    @Test func wasmStreamKeepsStateAcrossMultilineCommentsAndStrings() {
        let rustSrc = """
        /* open comment
        let fake_keyword = 42;
        still inside comment */
        fn after() -> u32 { 7 }
        """
        let full = Highlighter().highlight(rustSrc, language: .rust)
        assertSpansValid(rustSrc, spans: full)

        // Line 2 ("let fake_keyword = 42;") MUST stay a .comment both in whole-file and streamed modes.
        let fakeLineSpans = full.filter { ($0.text(in: rustSrc) ?? "").contains("fake_keyword") }
        #expect(!fakeLineSpans.isEmpty)
        #expect(fakeLineSpans.allSatisfy { $0.token.kind == .comment })

        var stream = HighlightStream(language: .rust)
        var acc = ""
        for ch in rustSrc {
            acc.append(ch)
            let streamed = stream.highlight(acc)
            #expect(streamed == Highlighter().highlight(acc, language: .rust))
        }

        let pySrc = """
        x = \"\"\"
        def fake():
            return 1
        \"\"\"
        def real():
            return 2
        """
        var pyStream = HighlightStream(language: .python)
        var pyAcc = ""
        for line in pySrc.split(separator: "\n", omittingEmptySubsequences: false) {
            if !pyAcc.isEmpty { pyAcc.append("\n") }
            pyAcc.append(contentsOf: line)
            #expect(pyStream.highlight(pyAcc) == Highlighter().highlight(pyAcc, language: .python))
        }
        #expect(HighlightToken.all.count == 73)
    }
}
