// Ports `rune_kit::markdown::Rendered` (`crates/rune-kit/src/markdown/find.rs`, #960) and the
// table code-chip padding test of `crates/rune-kit/src/markdown/table.rs` (#495, #953).

/// The text each block of a document shows, as `MarkdownFind.find` searches it, with the map
/// from each back to the document's source bytes: a read of the parse Rune already keeps for
/// drawing (`MarkdownDocCache.shared.docCached`; the source is parsed and kept there if it isn't).
///
/// It owns its text and is `Sendable`, so a search over many documents can make one per document
/// once and run every query over them with `find(_:_:_:)`, on any thread, without parsing again.
/// `MarkdownRendered(src).find(src, q, case)` returns what `MarkdownFind.find(src, q, case)` does.
public struct MarkdownRendered: Sendable, Hashable {
    private var blocks: [MarkdownFind.Visible]

    /// An empty document's rendering.
    public init() {
        blocks = []
    }

    /// `src`'s rendered blocks, from the cached parse.
    public init(_ src: String) {
        let doc = MarkdownDocCache.shared.docCached(src, autolink: true)
        let srcBytes = Array(src.utf8)
        var out: [MarkdownFind.Visible] = []
        MarkdownFind.eachText(blocks: doc.blocks, maps: doc.maps) { text, map in
            if let vis = MarkdownFind.visible(srcBytes: srcBytes, text: text, map: map) {
                out.append(vis)
            }
        }
        blocks = out
    }

    /// Each block's visible text, in document order (matches never cross from one to the next).
    public func texts() -> [String] {
        blocks.map(\.text)
    }

    /// The source byte ranges `range` (UTF-8 bytes) of block `block`'s visible text covers,
    /// merged where they touch; empty when they name nothing in `src`. `src` is the source this
    /// was made from.
    public func sourceRanges(_ src: String, block: Int, range: Range<Int>) -> [Range<Int>] {
        guard block >= 0, block < blocks.count else { return [] }
        let vis = blocks[block]
        guard range.lowerBound >= 0, range.lowerBound < range.upperBound, range.upperBound <= vis.bytes.count else { return [] }
        var segIdx = 0
        return MarkdownFind.mapVisRange(srcBytes: Array(src.utf8), segs: vis.segs, segIdx: &segIdx, vRange: range)
    }

    /// `MarkdownFind.find` over these blocks: `src` is the source this was made from.
    public func find(_ src: String, _ query: String, _ caseSensitivity: MarkdownCase = .insensitive) -> [[Range<Int>]] {
        guard !src.isEmpty, !query.isEmpty else { return [] }
        let srcBytes = Array(src.utf8)
        var out: [[Range<Int>]] = []
        for vis in blocks {
            MarkdownFind.findInVisible(srcBytes: srcBytes, vis: vis, query: query, caseSensitivity: caseSensitivity, out: &out)
        }
        return out
    }
}

/// Which of a table cell's widths count inline code's end padding (`table.rs` `widths`).
///
/// Inline code's padding is white space set around it, which a line leaves out of its width
/// where it ends the line; a page counts an inline box's padding in the cell's widths.
enum MarkdownTableCodePad {
    /// `last`: the cell's max-content width (`natural`) adds `inline_code_pad`; `word`: its
    /// min-content width (`fit`) does.
    static func hits(_ inl: MarkdownInline) -> (last: Bool, word: Bool) {
        let bytes = Array(inl.text.utf8)
        let len = bytes.count
        func endsCode(_ end: Int) -> Bool {
            guard end < len else { return true }
            let rest = String(decoding: bytes[max(0, end)...], as: UTF8.self)
            return rest.unicodeScalars.first.map(\.properties.isWhitespace) ?? true
        }
        func inLink(_ a: Int, _ b: Int) -> Bool {
            inl.links.contains { $0.start <= a && b <= $0.end }
        }
        var last = false
        var word = false
        // The padding that closes a code span: a pad starting where code ends (not inside a link).
        for s in inl.spans where s.style == .codePad && inl.spans.contains(where: { $0.style == .code && $0.end == s.start && !inLink($0.start, $0.end) }) {
            last = last || s.end == len
            word = word || endsCode(s.end)
        }
        // Code that ends the cell lost its end padding with the line's trailing space
        // (`parser::trimmed_len`), but a page still counts it: the cell is as wide as the chip (#953).
        let ends = inl.spans.contains { $0.style == .code && $0.end >= len && !inLink($0.start, $0.end) }
        return (last || ends, word || ends)
    }
}
