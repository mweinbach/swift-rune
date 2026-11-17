import Foundation

private let wasmKeepPages = 128
private let wasmInputOffset = wasmPageSize
private let wasmSlack = 96
private let wasmRecordsMode: UInt8 = 3

/// Syntax highlighter backed by upstream `@pierre/highlights` (`highlights.wasm`) for all 80
/// upstream languages, with a fallback spec lexer for Swift `.msl`.
public struct Highlighter: Sendable {
    private let pool = WasmPool()

    public init() {}

    /// Highlights `source` using the lexer for `language`.
    /// Returns ordered, non-overlapping UTF-8 byte-range spans. Empty for `.plain` or empty input.
    public func highlight(_ source: String, language: Language) -> [HighlightSpan] {
        guard language != .plain, !source.isEmpty else {
            return []
        }
        if language == .msl {
            var scanner = LexerScanner(source)
            if let spec = LanguageGrammarSpecs.spec(for: .msl) {
                LanguageGrammarSpecs.lex(&scanner, spec: spec, language: .msl)
            }
            return scanner.spans
        }
        return pool.highlight(source, language: language)
    }
}

/// Incremental streaming highlighter that carries the WASM lexers' state across newlines, matching
/// full `Highlighter.highlight` output while only lexing newly completed lines plus the active line.
public struct HighlightStream: Sendable {
    public let language: Language
    private var storage: StreamStorage?
    private var committedText: String = ""
    private var committedSpans: [HighlightSpan] = []

    public init(language: Language) {
        self.language = language
    }

    /// Returns `true` when `source` extends the previously committed prefix.
    public func continues(_ source: String) -> Bool {
        !committedText.isEmpty && source.utf8.starts(with: committedText.utf8)
    }

    /// Highlights `source`, carrying lexer state over completed lines when `source` extends them.
    public mutating func highlight(_ source: String) -> [HighlightSpan] {
        guard language != .plain, !source.isEmpty else {
            committedText = ""
            committedSpans = []
            storage = nil
            return []
        }

        if language == .msl {
            return lexMSLFallback(source)
        }

        if !continues(source) || storage == nil {
            committedText = ""
            committedSpans = []
            storage = StreamStorage()
        } else if !isKnownUniquelyReferenced(&storage) {
            storage = StreamStorage(copying: storage!)
        }

        guard let active = storage else { return [] }

        do {
            return try lexWasm(source, storage: active)
        } catch {
            committedText = ""
            committedSpans = []
            storage = nil
            return []
        }
    }

    private mutating func lexWasm(_ source: String, storage: StreamStorage) throws -> [HighlightSpan] {
        let linesByte = source.utf8.lastIndex(of: 0x0A).map { idx in
            source.utf8.distance(from: source.utf8.startIndex, to: idx) + 1
        } ?? 0

        let committedBytes = committedText.utf8.count
        if linesByte > committedBytes {
            let chunk = utf8Slice(source, from: committedBytes, to: linesByte)
            let records = try wasmRecords(
                storage.wasm,
                language: language,
                source: chunk,
                stream: committedBytes == 0
            )
            for span in spansFromRecords(chunk, records: records) {
                committedSpans.append(
                    HighlightSpan(
                        utf8Range: (span.utf8Range.lowerBound + committedBytes)..<(span.utf8Range.upperBound + committedBytes),
                        token: span.token
                    )
                )
            }
            committedText.append(chunk)
        }

        var out = committedSpans
        let totalBytes = source.utf8.count
        if linesByte < totalBytes {
            let tailWasm: WasmHighlightsModule
            if let existing = storage.tail {
                existing.copyFrom(storage.wasm)
                tailWasm = existing
            } else {
                let copy = WasmHighlightsModule(copying: storage.wasm)
                storage.tail = copy
                tailWasm = copy
            }
            let chunk = utf8Slice(source, from: linesByte, to: totalBytes)
            let records = try wasmRecords(
                tailWasm,
                language: language,
                source: chunk,
                stream: linesByte == 0
            )
            for span in spansFromRecords(chunk, records: records) {
                out.append(
                    HighlightSpan(
                        utf8Range: (span.utf8Range.lowerBound + linesByte)..<(span.utf8Range.upperBound + linesByte),
                        token: span.token
                    )
                )
            }
            if tailWasm.mem.count > wasmKeepPages * wasmPageSize {
                storage.tail = nil
            }
        }
        return out
    }

    private mutating func lexMSLFallback(_ source: String) -> [HighlightSpan] {
        if !continues(source) {
            committedText = ""
            committedSpans = []
        }
        let whole = Highlighter()
        let linesByte = source.utf8.lastIndex(of: 0x0A).map { idx in
            source.utf8.distance(from: source.utf8.startIndex, to: idx) + 1
        } ?? 0
        let committedBytes = committedText.utf8.count
        if linesByte > committedBytes {
            let chunk = utf8Slice(source, from: committedBytes, to: linesByte)
            for span in whole.highlight(chunk, language: .msl) {
                committedSpans.append(
                    HighlightSpan(
                        utf8Range: (span.utf8Range.lowerBound + committedBytes)..<(span.utf8Range.upperBound + committedBytes),
                        token: span.token
                    )
                )
            }
            committedText.append(chunk)
        }
        let tailStart = committedText.utf8.count
        let totalBytes = source.utf8.count
        if tailStart >= totalBytes {
            return committedSpans
        }
        let tail = utf8Slice(source, from: tailStart, to: totalBytes)
        var out = committedSpans
        for span in whole.highlight(tail, language: .msl) {
            out.append(
                HighlightSpan(
                    utf8Range: (span.utf8Range.lowerBound + tailStart)..<(span.utf8Range.upperBound + tailStart),
                    token: span.token
                )
            )
        }
        return out
    }
}

private final class WasmPool: @unchecked Sendable {
    private let lock = NSLock()
    private var wasm: WasmHighlightsModule?

    func highlight(_ source: String, language: Language) -> [HighlightSpan] {
        lock.lock()
        defer { lock.unlock() }
        let module = wasm ?? WasmHighlightsModule()
        wasm = nil
        do {
            let records = try wasmRecords(module, language: language, source: source, stream: nil)
            if module.mem.count <= wasmKeepPages * wasmPageSize {
                wasm = module
            }
            return spansFromRecords(source, records: records)
        } catch {
            wasm = nil
            return []
        }
    }
}

private final class StreamStorage: @unchecked Sendable {
    var wasm: WasmHighlightsModule
    var tail: WasmHighlightsModule?

    init() {
        self.wasm = WasmHighlightsModule()
        self.tail = nil
    }

    init(copying other: StreamStorage) {
        self.wasm = WasmHighlightsModule(copying: other.wasm)
        self.tail = nil
    }
}

private func readU32LE(_ mem: [UInt8], _ at: Int) -> UInt32 {
    UInt32(mem[at])
        | (UInt32(mem[at + 1]) << 8)
        | (UInt32(mem[at + 2]) << 16)
        | (UInt32(mem[at + 3]) << 24)
}

private func utf8Slice(_ source: String, from: Int, to: Int) -> String {
    let utf8 = source.utf8
    let start = utf8.index(utf8.startIndex, offsetBy: from)
    let end = utf8.index(utf8.startIndex, offsetBy: to)
    return String(source[start..<end])
}

private func wasmRecords(
    _ wasm: WasmHighlightsModule,
    language: Language,
    source: String,
    stream: Bool?
) throws -> [UInt32] {
    let utf8 = Array(source.utf8)
    let len = utf8.count
    let pagesNeeded = 1 + (len + wasmSlack + wasmPageSize - 1) / wasmPageSize
    let need = pagesNeeded * wasmPageSize
    if wasm.mem.count < need {
        wasm.mem.append(contentsOf: repeatElement(0 as UInt8, count: need - wasm.mem.count))
    }
    wasm.mem.replaceSubrange(wasmInputOffset..<(wasmInputOffset + len), with: utf8)
    wasm.mem[wasmInputOffset + len] = 0
    wasm.mem[0] = language.rawValue
    wasm.mem[1] = wasmRecordsMode
    let ulen = UInt32(truncatingIfNeeded: len)
    wasm.mem[2] = UInt8(truncatingIfNeeded: ulen)
    wasm.mem[3] = UInt8(truncatingIfNeeded: ulen >> 8)
    wasm.mem[4] = UInt8(truncatingIfNeeded: ulen >> 16)
    wasm.mem[5] = UInt8(truncatingIfNeeded: ulen >> 24)

    switch stream {
    case nil:
        try wasm.highlight()
    case let first?:
        try wasm.highlightStream(first ? 1 : 0)
    }

    let at = Int(readU32LE(wasm.mem, 6))
    let byteLen = Int(readU32LE(wasm.mem, 10))
    guard at + byteLen <= wasm.mem.count else {
        try trap()
    }
    let count = byteLen / 4
    var out: [UInt32] = []
    out.reserveCapacity(count)
    for i in 0..<count {
        out.append(readU32LE(wasm.mem, at + i * 4))
    }
    return out
}

private struct Utf16Cursor {
    private let scalars: String.UnicodeScalarView
    private var index: String.UnicodeScalarView.Index
    private var byteOffset: Int = 0
    private var unitOffset: Int = 0

    init(_ source: String) {
        self.scalars = source.unicodeScalars
        self.index = source.unicodeScalars.startIndex
    }

    mutating func byteAt(_ targetUnit: Int) -> Int {
        if targetUnit < unitOffset {
            index = scalars.startIndex
            byteOffset = 0
            unitOffset = 0
        }
        while index < scalars.endIndex && unitOffset < targetUnit {
            let scalar = scalars[index]
            unitOffset += scalar.utf16.count
            byteOffset += scalar.utf8.count
            index = scalars.index(after: index)
        }
        return byteOffset
    }
}

private func spansFromRecords(_ source: String, records: [UInt32]) -> [HighlightSpan] {
    var out: [HighlightSpan] = []
    out.reserveCapacity(records.count / 2)
    var cursor = Utf16Cursor(source)
    var start = 0
    var i = 0
    while i + 1 < records.count {
        let endUnit = Int(records[i])
        let ty = records[i + 1]
        i += 2
        if ty == UInt32.max {
            start = cursor.byteAt(endUnit)
            continue
        }
        let endByte = cursor.byteAt(endUnit)
        if ty != 0, endByte > start, ty < UInt32(UInt8.max),
           let kind = HighlightToken.Kind(rawValue: UInt8(ty))
        {
            out.append(HighlightSpan(utf8Range: start..<endByte, token: HighlightToken(kind)))
        }
        start = endByte
    }
    return out
}
