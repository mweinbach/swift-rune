import Foundation
import Rune
import RuneMotion

// MARK: - 128-Bit Seeded Pair Hasher (`crates/rune-kit/src/markdown/memo.rs`)

/// Full 128-bit content/render digest produced by two independent SipHash-1-3 lanes seeded once
/// per process with independent random keys (no intermediate 64-bit reduction).
internal struct MarkdownDigest128: Sendable, Equatable, Hashable {
    let lo: UInt64
    let hi: UInt64

    @inline(__always)
    init(lo: UInt64, hi: UInt64) {
        self.lo = lo
        self.hi = hi
    }
}

/// One SipHash-1-3 state lane matching Rust's `DefaultHasher` algorithm.
private struct SipHash13Lane {
    private var v0: UInt64
    private var v1: UInt64
    private var v2: UInt64
    private var v3: UInt64
    private var buf: UInt64 = 0
    private var bufLen: Int = 0
    private var totalLen: UInt64 = 0

    @inline(__always)
    init(k0: UInt64, k1: UInt64) {
        v0 = k0 ^ 0x736f6d6570736575
        v1 = k1 ^ 0x646f72616e646f6d
        v2 = k0 ^ 0x6c7967656e657261
        v3 = k1 ^ 0x7465646279746573
    }

    @inline(__always)
    private static func rotl(_ x: UInt64, _ b: UInt64) -> UInt64 {
        (x << b) | (x >> (64 &- b))
    }

    @inline(__always)
    private mutating func sipRound() {
        v0 = v0 &+ v1
        v1 = Self.rotl(v1, 13)
        v1 ^= v0
        v0 = Self.rotl(v0, 32)
        v2 = v2 &+ v3
        v3 = Self.rotl(v3, 16)
        v3 ^= v2
        v0 = v0 &+ v3
        v3 = Self.rotl(v3, 21)
        v3 ^= v0
        v2 = v2 &+ v1
        v1 = Self.rotl(v1, 17)
        v1 ^= v2
        v2 = Self.rotl(v2, 32)
    }

    @inline(__always)
    private mutating func compress(_ m: UInt64) {
        v3 ^= m
        sipRound()
        v0 ^= m
    }

    @inline(__always)
    mutating func writeByte(_ byte: UInt8) {
        buf |= UInt64(byte) << UInt64(bufLen * 8)
        bufLen += 1
        totalLen &+= 1
        if bufLen == 8 {
            compress(buf)
            buf = 0
            bufLen = 0
        }
    }

    @inline(__always)
    mutating func writeUInt64(_ value: UInt64) {
        if bufLen == 0 {
            totalLen &+= 8
            compress(value)
            return
        }
        let shift = UInt64(bufLen * 8)
        let rem = 64 &- shift
        let word = buf | (value << shift)
        compress(word)
        buf = value >> rem
        totalLen &+= 8
    }

    @inline(__always)
    mutating func writeBytes(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard let base = bytes.baseAddress else { return }
        let count = bytes.count
        var i = 0
        if bufLen > 0 {
            while i < count && bufLen < 8 {
                buf |= UInt64(base[i]) << UInt64(bufLen * 8)
                bufLen += 1
                totalLen &+= 1
                i += 1
            }
            if bufLen == 8 {
                compress(buf)
                buf = 0
                bufLen = 0
            }
        }
        while i + 8 <= count {
            var word: UInt64 = 0
            word |= UInt64(base[i])
            word |= UInt64(base[i + 1]) << 8
            word |= UInt64(base[i + 2]) << 16
            word |= UInt64(base[i + 3]) << 24
            word |= UInt64(base[i + 4]) << 32
            word |= UInt64(base[i + 5]) << 40
            word |= UInt64(base[i + 6]) << 48
            word |= UInt64(base[i + 7]) << 56
            compress(word)
            totalLen &+= 8
            i += 8
        }
        while i < count {
            buf |= UInt64(base[i]) << UInt64(bufLen * 8)
            bufLen += 1
            totalLen &+= 1
            i += 1
        }
    }

    @inline(__always)
    func finalize() -> UInt64 {
        var copy = self
        let last = copy.buf | ((copy.totalLen & 0xff) << 56)
        copy.compress(last)
        copy.v2 ^= 0xff
        copy.sipRound()
        copy.sipRound()
        copy.sipRound()
        return copy.v0 ^ copy.v1 ^ copy.v2 ^ copy.v3
    }
}

private enum MarkdownHashSeeds {
    static let keys: (UInt64, UInt64, UInt64, UInt64) = (
        UInt64.random(in: .min ... .max),
        UInt64.random(in: .min ... .max),
        UInt64.random(in: .min ... .max),
        UInt64.random(in: .min ... .max)
    )
}

/// Two independent 128-bit-keyed SipHash-1-3 lanes fed directly from hashed inputs
/// (`crates/rune-kit/src/markdown/memo.rs:PairHasher`).
internal struct MarkdownPairHasher {
    private var a: SipHash13Lane
    private var b: SipHash13Lane

    @inline(__always)
    init() {
        let k = MarkdownHashSeeds.keys
        a = SipHash13Lane(k0: k.0, k1: k.1)
        b = SipHash13Lane(k0: k.2, k1: k.3)
    }

    @inline(__always)
    mutating func writeByte(_ v: UInt8) {
        a.writeByte(v)
        b.writeByte(v)
    }

    @inline(__always)
    mutating func writeBool(_ v: Bool) {
        writeByte(v ? 1 : 0)
    }

    @inline(__always)
    mutating func writeUInt32(_ v: UInt32) {
        writeUInt64(UInt64(v))
    }

    @inline(__always)
    mutating func writeUInt64(_ v: UInt64) {
        a.writeUInt64(v)
        b.writeUInt64(v)
    }

    @inline(__always)
    mutating func writeInt(_ v: Int) {
        writeUInt64(UInt64(bitPattern: Int64(v)))
    }

    @inline(__always)
    mutating func writeFloat(_ v: Float) {
        writeUInt32(v.bitPattern)
    }

    @inline(__always)
    mutating func writeDouble(_ v: Double) {
        writeUInt64(v.bitPattern)
    }

    @inline(__always)
    mutating func writeDigest(_ d: MarkdownDigest128) {
        writeUInt64(d.lo)
        writeUInt64(d.hi)
    }

    @inline(__always)
    mutating func writeString(_ s: String) {
        var copy = s
        writeInt(copy.utf8.count)
        copy.withUTF8 { ptr in
            a.writeBytes(ptr)
            b.writeBytes(ptr)
        }
        writeByte(0xff)
    }

    @inline(__always)
    mutating func writeBytes(_ bytes: [UInt8]) {
        writeInt(bytes.count)
        bytes.withUnsafeBufferPointer { ptr in
            a.writeBytes(ptr)
            b.writeBytes(ptr)
        }
    }

    @inline(__always)
    mutating func writeOptionalString(_ s: String?) {
        if let s {
            writeByte(1)
            writeString(s)
        } else {
            writeByte(0)
        }
    }

    @inline(__always)
    mutating func writeColor(_ c: Color) {
        writeFloat(c.r)
        writeFloat(c.g)
        writeFloat(c.b)
        writeFloat(c.a)
    }

    @inline(__always)
    mutating func writeOptionalColor(_ c: Color?) {
        if let c {
            writeByte(1)
            writeColor(c)
        } else {
            writeByte(0)
        }
    }

    @inline(__always)
    mutating func writeOptionalFloat(_ f: Float?) {
        if let f {
            writeByte(1)
            writeFloat(f)
        } else {
            writeByte(0)
        }
    }

    @inline(__always)
    mutating func writeDirection(_ d: MarkdownDirection?) {
        switch d {
        case nil: writeByte(0)
        case .ltr: writeByte(1)
        case .rtl: writeByte(2)
        }
    }

    @inline(__always)
    mutating func writeAlign(_ align: MarkdownTableAlign) {
        switch align {
        case .start: writeByte(0)
        case .center: writeByte(1)
        case .end: writeByte(2)
        }
    }

    @inline(__always)
    mutating func writeFontFamily(_ family: FontFamily) {
        switch family {
        case .systemUI: writeByte(0)
        case .monospace: writeByte(1)
        case .systemMono: writeByte(2)
        case .custom(let name):
            writeByte(3)
            writeString(name)
        }
    }

    mutating func writeTextStyle(_ ts: TextStyle) {
        writeFloat(ts.size)
        writeFloat(ts.weight)
        writeOptionalFloat(ts.lineHeight)
        writeFloat(ts.letterSpacing)
        writeBool(ts.italic)
        writeFontFamily(ts.family)
        switch ts.align {
        case .leading: writeByte(0)
        case .center: writeByte(1)
        case .trailing: writeByte(2)
        case .justified: writeByte(3)
        }
        switch ts.wrap {
        case .wrap: writeByte(0)
        case .noWrap: writeByte(1)
        case .ellipsis: writeByte(2)
        }
        writeBool(ts.wrapAnywhere)
        writeString(ts.elide.rawValue)
        writeInt(ts.maxLines)
        writeBool(ts.exactLines)
        writeString(ts.fontSmoothing.rawValue)
        writeString(ts.variations)
        writeString(ts.features)
        switch ts.opticalSize {
        case .auto: writeByte(0)
        case .fontDefault: writeByte(1)
        case .fixed(let v):
            writeByte(2)
            writeFloat(v)
        }
        writeOptionalString(ts.direction?.rawValue)
    }

    mutating func writeShadow(_ sh: Shadow) {
        writeFloat(sh.x)
        writeFloat(sh.y)
        writeFloat(sh.blur)
        writeFloat(sh.spread)
        writeColor(sh.color)
        writeBool(sh.inset)
    }

    mutating func writeSVGIcon(_ ic: SVGIcon) {
        writeFloat(ic.viewBox)
        writeInt(ic.paths.count)
        for p in ic.paths { writeString(p) }
        writeOptionalFloat(ic.strokeWidth)
        writeOptionalString(ic.body)
    }

    mutating func writeSyntaxTheme(_ theme: SyntaxTheme) {
        writeInt(theme.colors.count)
        for c in theme.colors { writeColor(c) }
        writeInt(theme.weights.count)
        for w in theme.weights { writeOptionalFloat(w) }
    }

    mutating func writeStyle(_ s: MarkdownStyle) {
        writeColor(s.text)
        writeColor(s.muted)
        writeColor(s.accent)
        writeColor(s.linkUnderline)
        writeColor(s.codeBg)
        writeColor(s.codeBlockFill)
        writeColor(s.codeBlockBorder)
        writeColor(s.quoteRule)
        writeFloat(s.quote.width)
        writeFloat(s.quote.pad)
        writeOptionalColor(s.quote.text)
        writeColor(s.rule)
        writeTextStyle(s.body)
        writeInt(s.headings.count)
        for h in s.headings { writeTextStyle(h) }
        writeTextStyle(s.codeBlock)
        writeOptionalColor(s.codeText)
        writeOptionalColor(s.plainCodeText)
        if let sh = s.shell {
            writeByte(1)
            writeColor(sh.fill)
            writeColor(sh.border)
            writeColor(sh.text)
        } else {
            writeByte(0)
        }
        writeOptionalColor(s.linkHover)
        writeBool(s.listOutside)
        if let ln = s.listNested {
            writeByte(1)
            writeInt(ln.count)
            for v in ln { writeFloat(v) }
        } else {
            writeByte(0)
        }
        writeBool(s.tableAlign)
        writeFloat(s.inlineCodeScale)
        writeFloat(s.inlineCodeWeight)
        writeFloat(s.inlineCodePad)
        writeInt(s.codeBlockPad.count)
        for v in s.codeBlockPad { writeFloat(v) }
        writeFloat(s.listIndent)
        writeFloat(s.listGap)
        writeFloat(s.strongWeight)
        writeOptionalColor(s.tableOutline)
        writeColor(s.tableRule)
        writeColor(s.tableHeadFill)
        writeColor(s.tableHeadText)
        writeOptionalColor(s.tableHeadRule)
        writeOptionalFloat(s.tableHeadWeight)
        writeFloat(s.tableMinColumn)
        writeBool(s.tableTabular)
        if let tf = s.tableFont {
            writeByte(1)
            writeTextStyle(tf)
        } else {
            writeByte(0)
        }
        writeInt(s.tablePad.count)
        for v in s.tablePad { writeFloat(v) }
        writeBool(s.tableFlushLeft)
        if let tf = s.tableFrame {
            writeByte(1)
            writeColor(tf.fill)
            writeColor(tf.ring)
            writeFloat(tf.pad)
        } else {
            writeByte(0)
        }
        if let tb = s.tableBody {
            writeByte(1)
            writeColor(tb.fill)
            writeFloat(tb.radius)
            writeInt(tb.shadows.count)
            for sh in tb.shadows { writeShadow(sh) }
        } else {
            writeByte(0)
        }
        if let hp = s.tableHeadPad {
            writeByte(1)
            writeInt(hp.count)
            for v in hp { writeFloat(v) }
        } else {
            writeByte(0)
        }
        writeBool(s.tableFullWidth)
        writeInt(s.tableMargin.count)
        for v in s.tableMargin { writeFloat(v) }
        writeInt(s.codeMargin.count)
        for v in s.codeMargin { writeFloat(v) }
        if let tbar = s.tableBar {
            writeByte(1)
            writeInt(tbar.count)
            for c in tbar { writeColor(c) }
        } else {
            writeByte(0)
        }
        writeOptionalFloat(s.textWidth)
        writeFloat(s.wideFade)
        switch s.linkIcon {
        case nil: writeByte(0)
        case let .leading(g, sz):
            writeByte(1)
            writeFloat(g)
            writeFloat(sz)
        case let .trailing(g, sz):
            writeByte(2)
            writeFloat(g)
            writeFloat(sz)
        }
        writeColor(s.diffAdd)
        writeColor(s.diffRemove)
        writeColor(s.diffAddText)
        writeColor(s.diffRemoveText)
        writeInt(s.diffHues.count)
        for c in s.diffHues { writeColor(c) }
        writeColor(s.diffHunk)
        writeSyntaxTheme(s.syntax)
        writeBool(s.highlight)
        writeColor(s.selection)
        writeColor(s.highlightBg)
        writeOptionalColor(s.highlightFg)
        if let hr = s.highlightRing {
            writeByte(1)
            writeColor(hr.0)
            writeFloat(hr.1)
        } else {
            writeByte(0)
        }
        writeColor(s.highlightCurrentBg)
        writeOptionalColor(s.highlightCurrentFg)
        if let hcr = s.highlightCurrentRing {
            writeByte(1)
            writeColor(hcr.0)
            writeFloat(hcr.1)
        } else {
            writeByte(0)
        }
        writeColor(s.task.fillOn)
        writeColor(s.task.borderOn)
        writeColor(s.task.borderOff)
        writeColor(s.task.fillOff)
        writeColor(s.task.hover)
        writeColor(s.task.focusRing)
        writeColor(s.task.mark)
        writeSVGIcon(s.task.check)
        writeFloat(s.task.radius)
        writeFloat(s.task.motion.duration)
        writeFloat(s.task.motion.bounce)
        writeFloat(s.task.size)
        writeFloat(s.task.left)
        writeOptionalFloat(s.task.top)
        writeColor(s.diagram.text)
        writeColor(s.diagram.muted)
        writeColor(s.diagram.surface)
        writeColor(s.diagram.surfaceBorder)
        writeColor(s.diagram.nodeFill)
        writeColor(s.diagram.nodeBorder)
        writeColor(s.diagram.line)
        writeColor(s.diagram.clusterFill)
        writeColor(s.diagram.noteFill)
        writeColor(s.diagram.noteBorder)
        writeTextStyle(s.diagram.font)
        writeFloat(s.diagram.maxWidth)
        writeFloat(s.diagram.minScale)
        writeColor(s.diagram.hover)
        writeBool(s.diagram.hoverNeighbours)
    }

    mutating func writeHighlight(_ hl: MarkdownHighlight) {
        writeOptionalColor(hl.bg)
        writeOptionalColor(hl.fg)
        writeOptionalColor(hl.ringColor)
        writeOptionalFloat(hl.ringWidth)
        writeBool(hl.current)
        writeOptionalString(hl.key)
    }

    mutating func writeInline(_ inl: MarkdownInline) {
        writeString(inl.text)
        writeInt(inl.spans.count)
        for sp in inl.spans {
            writeInt(sp.start)
            writeInt(sp.end)
            switch sp.style {
            case .strong: writeByte(0)
            case .em: writeByte(1)
            case .strike: writeByte(2)
            case .code: writeByte(3)
            case .codePad: writeByte(4)
            case .link: writeByte(5)
            }
        }
        writeInt(inl.links.count)
        for lk in inl.links {
            writeInt(lk.start)
            writeInt(lk.end)
            writeString(lk.url)
        }
    }

    mutating func writeSpanMap(_ m: MarkdownSpanMap) {
        writeInt(m.segments.count)
        for seg in m.segments {
            writeInt(seg.src.lowerBound)
            writeInt(seg.src.upperBound)
            writeInt(seg.out.lowerBound)
            writeInt(seg.out.upperBound)
        }
    }

    mutating func writeBlockMap(_ root: MarkdownBlockMap) {
        enum Step {
            case map(MarkdownBlockMap)
            case len(Int)
        }
        var stack: [Step] = [.map(root)]
        while let step = stack.popLast() {
            switch step {
            case .len(let n):
                writeInt(n)
            case .map(let m):
                switch m {
                case .none:
                    writeByte(0)
                case .inline(let s):
                    writeByte(1)
                    writeSpanMap(s)
                case .code(let s):
                    writeByte(2)
                    writeSpanMap(s)
                case .list(let items):
                    writeByte(3)
                    writeInt(items.count)
                    for item in items.reversed() {
                        for b in item.reversed() { stack.append(.map(b)) }
                        stack.append(.len(item.count))
                    }
                case .quote(let inner):
                    writeByte(4)
                    writeInt(inner.count)
                    for b in inner.reversed() { stack.append(.map(b)) }
                case let .table(head, rows):
                    writeByte(5)
                    writeInt(head.count)
                    for s in head { writeSpanMap(s) }
                    writeInt(rows.count)
                    for row in rows {
                        writeInt(row.count)
                        for s in row { writeSpanMap(s) }
                    }
                case let .deepTail(lines, map):
                    writeByte(6)
                    writeInt(lines)
                    writeSpanMap(map)
                }
            }
        }
    }

    mutating func writeLinkStyle(_ style: MarkdownLinkStyle?) {
        guard let style else {
            writeByte(0)
            return
        }
        writeByte(1)
        writeOptionalColor(style.color)
        writeBool(style.underline)
        writeOptionalFloat(style.weight)
        writeOptionalColor(style.bg)
        writeOptionalColor(style.hoverColor)
        writeOptionalColor(style.hoverBg)
    }

    mutating func writeRGBA8Atlas(_ atlas: RGBA8Atlas?) {
        guard let atlas else {
            writeByte(0)
            return
        }
        writeByte(1)
        writeInt(atlas.width)
        writeInt(atlas.height)
        writeBytes(atlas.texels)
    }

    @inline(__always)
    func finish128() -> MarkdownDigest128 {
        MarkdownDigest128(lo: a.finalize(), hi: b.finalize())
    }
}

// MARK: - Precomputed Parse-Time 128-Bit Digests & Bidi Directions (`PreBlock` / `PreItem` / `PreTable` / `PreRow`)

internal enum MarkdownPreFlags {
    static let hasCode: UInt8 = 1 << 0
    static let hasMermaid: UInt8 = 1 << 1
    static let hasImage: UInt8 = 1 << 2
    static let hasQuote: UInt8 = 1 << 3
    static let hasOpenTable: UInt8 = 1 << 4
    static let hasInlineCode: UInt8 = 1 << 5
}

internal struct MarkdownPreRow: Sendable {
    let digest: MarkdownDigest128
    let flags: UInt8
    let links: [String]

    func heapBytes() -> Int {
        var total = 0
        for u in links {
            total += MemoryLayout<String>.stride + u.utf8.count
        }
        return total
    }
}

internal struct MarkdownPreTable: Sendable {
    let head: MarkdownPreRow
    let rows: [MarkdownPreRow]
}

internal struct MarkdownPreItem: Sendable {
    let digest: MarkdownDigest128
    let flags: UInt8
    let links: [String]
    let srcN: UInt32
    let taskN: UInt32
    let dir: MarkdownDirection?
    let inner: [MarkdownPreBlock]
}

/// Reference-counted precomputed 128-bit digest + direction metadata for one `MarkdownDocBlock`,
/// shared across incremental stream extensions without copying settled subtrees (`PreBlock`).
internal final class MarkdownPreBlock: @unchecked Sendable {
    let digest: MarkdownDigest128
    let flags: UInt8
    let links: [String]
    let srcN: UInt32
    let taskN: UInt32
    let dir: MarkdownDirection?
    private var _items: [MarkdownPreItem]
    private var _inner: [MarkdownPreBlock]
    let table: MarkdownPreTable?

    var items: [MarkdownPreItem] { _items }
    var inner: [MarkdownPreBlock] { _inner }

    init(
        digest: MarkdownDigest128,
        flags: UInt8,
        links: [String],
        srcN: UInt32,
        taskN: UInt32,
        dir: MarkdownDirection?,
        items: [MarkdownPreItem] = [],
        inner: [MarkdownPreBlock] = [],
        table: MarkdownPreTable? = nil
    ) {
        self.digest = digest
        self.flags = flags
        self.links = links
        self.srcN = srcN
        self.taskN = taskN
        self.dir = dir
        self._items = items
        self._inner = inner
        self.table = table
    }

    deinit {
        // Drain deep quote/list chains iteratively so releasing a 510-deep tree uses O(1) stack.
        guard !_inner.isEmpty || !_items.isEmpty else { return }
        var nodes = _inner
        var pendingItems = _items
        _inner = []
        _items = []
        while !nodes.isEmpty || !pendingItems.isEmpty {
            while let item = pendingItems.popLast() {
                nodes.append(contentsOf: item.inner)
            }
            while var node = nodes.popLast() {
                if isKnownUniquelyReferenced(&node) {
                    if !node._inner.isEmpty {
                        nodes.append(contentsOf: node._inner)
                        node._inner = []
                    }
                    if !node._items.isEmpty {
                        pendingItems.append(contentsOf: node._items)
                        node._items = []
                    }
                }
            }
        }
    }

    /// Iteratively counts heap bytes owned beneath this block (`O(1)` call stack) for the parse
    /// cache byte budget (`PreBlock::heap_bytes`).
    func heapBytes() -> Int {
        let blockSize = 112
        let itemSize = MemoryLayout<MarkdownPreItem>.stride
        let rowSize = MemoryLayout<MarkdownPreRow>.stride
        let strSize = MemoryLayout<String>.stride
        var total = 0
        var stack: [(MarkdownPreBlock, Bool)] = [(self, false)]
        while let (pb, countRef) = stack.popLast() {
            if countRef { total += blockSize }
            let ownUrls = pb.items.isEmpty && pb.inner.isEmpty && pb.table == nil
            total += pb.links.count * strSize
            if ownUrls {
                for u in pb.links { total += u.utf8.count }
            }
            for it in pb.items {
                total += itemSize + it.links.count * strSize
                for c in it.inner { stack.append((c, true)) }
            }
            for c in pb.inner { stack.append((c, true)) }
            if let t = pb.table {
                total += MemoryLayout<MarkdownPreTable>.stride + t.head.heapBytes() + t.rows.count * rowSize
                for r in t.rows { total += r.heapBytes() }
            }
        }
        return total
    }
}

internal enum MarkdownMemoMeta {
    static func sourceCount(_ root: MarkdownDocBlock) -> Int {
        var n = 0
        var stack: [MarkdownDocBlock] = [root]
        while let b = stack.popLast() {
            switch b {
            case .code, .mermaid:
                n += 1
            case let .list(_, items):
                for item in items { stack.append(contentsOf: item) }
            case let .quote(inner):
                stack.append(contentsOf: inner)
            default:
                break
            }
        }
        return n
    }

    static func taskCount(_ root: MarkdownDocBlock) -> Int {
        var n = 0
        var stack: [MarkdownDocBlock] = [root]
        while let b = stack.popLast() {
            switch b {
            case let .list(_, items):
                n += items.count
                for item in items { stack.append(contentsOf: item) }
            case let .quote(inner):
                stack.append(contentsOf: inner)
            default:
                break
            }
        }
        return n
    }

    private static func scanInline(
        _ inl: MarkdownInline,
        into h: inout MarkdownPairHasher,
        flags: inout UInt8,
        links: inout [String]
    ) {
        h.writeByte(0)
        h.writeInline(inl)
        if inl.spans.contains(where: { $0.style == .code }) {
            flags |= MarkdownPreFlags.hasInlineCode
        }
        for lk in inl.links {
            links.append(lk.url)
        }
    }

    private static func precomputeRow(_ cells: [MarkdownInline]) -> MarkdownPreRow {
        var h = MarkdownPairHasher()
        h.writeInt(cells.count)
        var flags: UInt8 = 0
        var links: [String] = []
        for c in cells {
            scanInline(c, into: &h, flags: &flags, links: &links)
        }
        return MarkdownPreRow(digest: h.finish128(), flags: flags, links: links)
    }

    static func rebuildQuoteMeta(_ inner: [MarkdownPreBlock]) -> MarkdownPreBlock {
        var h = MarkdownPairHasher()
        h.writeByte(8)
        h.writeInt(inner.count)
        var flags: UInt8 = MarkdownPreFlags.hasQuote
        var links: [String] = []
        var srcN: UInt32 = 0
        var taskN: UInt32 = 0
        var dir: MarkdownDirection? = nil
        for cp in inner {
            h.writeDigest(cp.digest)
            flags |= cp.flags
            links.append(contentsOf: cp.links)
            srcN &+= cp.srcN
            taskN &+= cp.taskN
            if dir == nil { dir = cp.dir }
        }
        return MarkdownPreBlock(
            digest: h.finish128(),
            flags: flags,
            links: links,
            srcN: srcN,
            taskN: taskN,
            dir: dir,
            inner: inner
        )
    }

    static func rebuildItemMeta(_ children: [MarkdownPreBlock]) -> MarkdownPreItem {
        var ih = MarkdownPairHasher()
        ih.writeInt(children.count)
        var flags: UInt8 = 0
        var links: [String] = []
        var srcN: UInt32 = 0
        var taskN: UInt32 = 0
        var dir: MarkdownDirection? = nil
        for cp in children {
            ih.writeDigest(cp.digest)
            flags |= cp.flags
            links.append(contentsOf: cp.links)
            srcN &+= cp.srcN
            taskN &+= cp.taskN
            if dir == nil { dir = cp.dir }
        }
        return MarkdownPreItem(
            digest: ih.finish128(),
            flags: flags,
            links: links,
            srcN: srcN,
            taskN: taskN,
            dir: dir,
            inner: children
        )
    }

    static func rebuildListMeta(start: UInt64?, items: [MarkdownPreItem]) -> MarkdownPreBlock {
        var h = MarkdownPairHasher()
        h.writeByte(9)
        if let s = start {
            h.writeByte(1)
            h.writeUInt64(s)
        } else {
            h.writeByte(0)
        }
        h.writeInt(items.count)
        var flags: UInt8 = 0
        var links: [String] = []
        var srcN: UInt32 = 0
        var taskN: UInt32 = UInt32(items.count)
        var dir: MarkdownDirection? = nil
        for it in items {
            h.writeDigest(it.digest)
            flags |= it.flags
            links.append(contentsOf: it.links)
            srcN &+= it.srcN
            taskN &+= it.taskN
            if dir == nil { dir = it.dir }
        }
        return MarkdownPreBlock(
            digest: h.finish128(),
            flags: flags,
            links: links,
            srcN: srcN,
            taskN: taskN,
            dir: dir,
            items: items
        )
    }

    /// Precomputes `rootBlock`'s 128-bit digest + direction tree iteratively (`O(1)` call stack
    /// up to 511 nested container levels).
    static func precomputeBlock(_ rootBlock: MarkdownDocBlock, map rootMap: MarkdownBlockMap?) -> MarkdownPreBlock {
        enum Step {
            case enter(MarkdownDocBlock, MarkdownBlockMap?)
            case finishQuote(Int)
            case finishItem(Int)
            case finishList(UInt64?, Int)
        }
        var vals: [MarkdownPreBlock] = []
        var itemsStack: [MarkdownPreItem] = []
        var stack: [Step] = [.enter(rootBlock, rootMap)]

        while let step = stack.popLast() {
            switch step {
            case let .enter(b, mapOpt):
                switch b {
                case let .quote(inner):
                    let innerMaps: [MarkdownBlockMap] = if case let .quote(m) = mapOpt { m } else { [] }
                    stack.append(.finishQuote(inner.count))
                    for i in stride(from: inner.count - 1, through: 0, by: -1) {
                        stack.append(.enter(inner[i], i < innerMaps.count ? innerMaps[i] : nil))
                    }
                case let .list(start, items):
                    let itemMaps: [[MarkdownBlockMap]] = if case let .list(m) = mapOpt { m } else { [] }
                    stack.append(.finishList(start, items.count))
                    for k in stride(from: items.count - 1, through: 0, by: -1) {
                        let item = items[k]
                        let imap = k < itemMaps.count ? itemMaps[k] : []
                        stack.append(.finishItem(item.count))
                        for j in stride(from: item.count - 1, through: 0, by: -1) {
                            stack.append(.enter(item[j], j < imap.count ? imap[j] : nil))
                        }
                    }
                default:
                    var h = MarkdownPairHasher()
                    var flags: UInt8 = 0
                    var links: [String] = []
                    var table: MarkdownPreTable? = nil
                    var srcN: UInt32 = 0
                    var dir: MarkdownDirection? = nil

                    switch (b, mapOpt) {
                    case let (.para(inl), .deepTail(lines, _)):
                        h.writeByte(11)
                        h.writeInt(lines)
                        h.writeString(inl.text)
                        dir = MarkdownBidi.inlineDirection(inl)
                    case let (.para(inl), _):
                        h.writeByte(1)
                        scanInline(inl, into: &h, flags: &flags, links: &links)
                        dir = MarkdownBidi.inlineDirection(inl)
                    case let (.heading(level, inl), _):
                        h.writeByte(2)
                        h.writeInt(level)
                        scanInline(inl, into: &h, flags: &flags, links: &links)
                        dir = MarkdownBidi.inlineDirection(inl)
                    case let (.code(code), _):
                        flags |= MarkdownPreFlags.hasCode
                        srcN = 1
                        h.writeByte(3)
                        h.writeString(code)
                    case let (.diff(src), _):
                        h.writeByte(4)
                        h.writeString(src)
                    case let (.mermaid(src), _):
                        flags |= MarkdownPreFlags.hasMermaid
                        srcN = 1
                        h.writeByte(5)
                        h.writeString(src)
                    case (.rule, _):
                        h.writeByte(6)
                    case let (.image(src, alt, title), _):
                        flags |= MarkdownPreFlags.hasImage
                        h.writeByte(7)
                        h.writeString(src)
                        h.writeString(alt)
                        h.writeString(title)
                    case let (.table(t), _):
                        if t.open { flags |= MarkdownPreFlags.hasOpenTable }
                        h.writeByte(10)
                        h.writeBool(t.open)
                        h.writeInt(t.align.count)
                        h.writeInt(t.head.count)
                        h.writeInt(t.rows.count)
                        for a in t.align { h.writeAlign(a) }
                        let head = precomputeRow(t.head)
                        h.writeDigest(head.digest)
                        flags |= head.flags
                        links.append(contentsOf: head.links)
                        var rows: [MarkdownPreRow] = []
                        rows.reserveCapacity(t.rows.count)
                        for r in t.rows {
                            let pr = precomputeRow(r)
                            h.writeDigest(pr.digest)
                            flags |= pr.flags
                            links.append(contentsOf: pr.links)
                            rows.append(pr)
                        }
                        table = MarkdownPreTable(head: head, rows: rows)
                        dir = MarkdownBidi.tableDirection(t)
                    case (.quote, _), (.list, _):
                        preconditionFailure("Containers handled above")
                    }

                    vals.append(MarkdownPreBlock(
                        digest: h.finish128(),
                        flags: flags,
                        links: links,
                        srcN: srcN,
                        taskN: 0,
                        dir: dir,
                        table: table
                    ))
                }
            case .finishQuote(let n):
                let startIdx = vals.count - n
                let children = Array(vals[startIdx...])
                vals.removeSubrange(startIdx...)
                vals.append(rebuildQuoteMeta(children))
            case .finishItem(let n):
                let startIdx = vals.count - n
                let children = Array(vals[startIdx...])
                vals.removeSubrange(startIdx...)
                itemsStack.append(rebuildItemMeta(children))
            case let .finishList(start, n):
                let startIdx = itemsStack.count - n
                let items = Array(itemsStack[startIdx...])
                itemsStack.removeSubrange(startIdx...)
                vals.append(rebuildListMeta(start: start, items: items))
            }
        }
        return vals.popLast()!
    }

    static func precomputeBlocks(_ blocks: [MarkdownDocBlock], maps: [MarkdownBlockMap]) -> [MarkdownPreBlock] {
        blocks.enumerated().map { idx, blk in
            precomputeBlock(blk, map: idx < maps.count ? maps[idx] : nil)
        }
    }
}

// MARK: - Per-Row & Per-Table Column Width Caches (`crates/rune-kit/src/markdown/table.rs`, #1130)

internal struct MarkdownTableColumns: Sendable {
    let natural: [Float]
    let min: [Float]
    let fit: [Float]
}

internal struct MarkdownTableRowWidths: Sendable {
    let natural: [Float]
    let fit: [Float]
}

internal final class MarkdownTableWidthCaches: @unchecked Sendable {
    private static let widthsBytes: Int = 1 << 20
    private static let rowWidthsBytes: Int = 512 << 10

    static var shared: MarkdownTableWidthCaches {
        runeExecutionLocal(forKey: "rune.kit.markdownTableWidths", create: MarkdownTableWidthCaches.init)
    }

    let widths: BudgetCache<MarkdownDigest128, MarkdownTableColumns>
    let rowWidths: BudgetCache<MarkdownDigest128, MarkdownTableRowWidths>

    init() {
        widths = BudgetCache(limitBytes: Self.widthsBytes)
        rowWidths = BudgetCache(limitBytes: Self.rowWidthsBytes)
    }

    func reset() {
        widths.clear()
        rowWidths.clear()
    }
}

// MARK: - Build & Row-Measurement Telemetry Counters (`block_builds` / `reset_block_builds`)

private final class MarkdownBuildCounters: @unchecked Sendable {
    static var shared: MarkdownBuildCounters {
        runeExecutionLocal(forKey: "rune.kit.markdownBuildCounters", create: MarkdownBuildCounters.init)
    }

    private let lock = NSLock()
    private var _blockBuilds: Int = 0
    private var _tableRowMeasurements: Int = 0

    func noteBlockBuild() {
        lock.lock()
        _blockBuilds += 1
        lock.unlock()
    }

    func blockBuilds() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return _blockBuilds
    }

    func resetBlockBuilds() {
        lock.lock()
        _blockBuilds = 0
        lock.unlock()
    }

    func noteTableRowMeasurement() {
        lock.lock()
        _tableRowMeasurements += 1
        lock.unlock()
    }

    func tableRowMeasurements() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return _tableRowMeasurements
    }

    func resetTableRowMeasurements() {
        lock.lock()
        _tableRowMeasurements = 0
        lock.unlock()
    }
}

extension Markdown {
    /// Cumulative number of cache-miss settled block/item/code-card/table-row subtree builds on
    /// this execution context (`rune_kit::markdown::block_builds`, #1130).
    public static var blockBuilds: Int {
        MarkdownBuildCounters.shared.blockBuilds()
    }

    /// Resets `Markdown.blockBuilds` to zero (`rune_kit::markdown::reset_block_builds`, #1130).
    public static func resetBlockBuilds() {
        MarkdownBuildCounters.shared.resetBlockBuilds()
    }

    /// Cumulative number of table row width measurements (`TextMeasure.contentWidths` passes) on
    /// this execution context (tracks `ROW_WIDTHS` cache misses, #1130).
    public static var tableRowMeasurements: Int {
        MarkdownBuildCounters.shared.tableRowMeasurements()
    }

    /// Resets `Markdown.tableRowMeasurements` and clears `WIDTHS` / `ROW_WIDTHS` caches.
    public static func resetTableWidthCaches() {
        MarkdownBuildCounters.shared.resetTableRowMeasurements()
        MarkdownTableWidthCaches.shared.reset()
    }

    internal static func noteBlockBuild() {
        MarkdownBuildCounters.shared.noteBlockBuild()
    }

    internal static func noteTableRowMeasurement() {
        MarkdownBuildCounters.shared.noteTableRowMeasurement()
    }
}
