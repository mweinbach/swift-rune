import Foundation
import RuneMotion

private enum WebAccessibilityJSONError: Error {
    case nonFiniteNumber
}

/// Direct UTF-8 JSON serializer for `WebAccessibilityPatch`. Matches Foundation's JSON
/// representation (`withoutEscapingSlashes`, shortest finite decimal / integer output,
/// strict non-finite rejection) without `JSONEncoder`'s per-field Codable overhead.
private struct WebAccessibilityJSONWriter: AccessibilityDumpFields {
    var bytes: [UInt8] = []
    private var needsComma = false

    init(capacity: Int = 0) {
        if capacity > 0 { bytes.reserveCapacity(capacity) }
    }

    mutating func beginObject() {
        bytes.append(0x7B) // {
        needsComma = false
    }

    mutating func endObject() {
        bytes.append(0x7D) // }
    }

    mutating func beginArray() {
        bytes.append(0x5B) // [
        needsComma = false
    }

    mutating func endArray() {
        bytes.append(0x5D) // ]
    }

    @inline(__always)
    mutating func writeCommaIfNeeded() {
        if needsComma { bytes.append(0x2C) } // ,
        needsComma = true
    }

    mutating func writeKey(_ key: String) {
        writeCommaIfNeeded()
        writeString(key)
        bytes.append(0x3A) // :
    }

    mutating func writeASCIIKey(_ key: StaticString) {
        writeCommaIfNeeded()
        bytes.append(0x22)
        key.withUTF8Buffer { bytes.append(contentsOf: $0) }
        bytes.append(0x22)
        bytes.append(0x3A)
    }

    mutating func writeFieldKey(_ field: AccessibilityDumpField) {
        writeCommaIfNeeded()
        bytes.append(0x22)
        bytes.append(contentsOf: field.rawValue.utf8)
        bytes.append(0x22)
        bytes.append(0x3A)
    }

    mutating func writeString(_ value: String) {
        bytes.append(0x22) // "
        var s = value
        s.withUTF8 { utf8 in
            var start = 0
            let count = utf8.count
            for i in 0..<count {
                let b = utf8[i]
                if b < 0x20 || b == 0x22 || b == 0x5C {
                    if i > start {
                        bytes.append(contentsOf: utf8[start..<i])
                    }
                    switch b {
                    case 0x22: bytes.append(0x5C); bytes.append(0x22) // \"
                    case 0x5C: bytes.append(0x5C); bytes.append(0x5C) // \\
                    case 0x08: bytes.append(0x5C); bytes.append(0x62) // \b
                    case 0x0C: bytes.append(0x5C); bytes.append(0x66) // \f
                    case 0x0A: bytes.append(0x5C); bytes.append(0x6E) // \n
                    case 0x0D: bytes.append(0x5C); bytes.append(0x72) // \r
                    case 0x09: bytes.append(0x5C); bytes.append(0x74) // \t
                    default:
                        let hex: (UInt8) -> UInt8 = { $0 < 10 ? 0x30 &+ $0 : 0x61 &+ ($0 &- 10) }
                        bytes.append(0x5C); bytes.append(0x75) // \u
                        bytes.append(0x30); bytes.append(0x30) // 00
                        bytes.append(hex(b >> 4)); bytes.append(hex(b & 0x0F))
                    }
                    start = i + 1
                }
            }
            if start < count {
                bytes.append(contentsOf: utf8[start..<count])
            }
        }
        bytes.append(0x22) // "
    }

    mutating func writeBool(_ value: Bool) {
        if value {
            bytes.append(contentsOf: [0x74, 0x72, 0x75, 0x65]) // true
        } else {
            bytes.append(contentsOf: [0x66, 0x61, 0x6C, 0x73, 0x65]) // false
        }
    }

    mutating func writeNull() {
        bytes.append(contentsOf: [0x6E, 0x75, 0x6C, 0x6C]) // null
    }

    mutating func writeInt(_ value: Int) {
        writeInt64(Int64(value))
    }

    mutating func writeInt64(_ value: Int64) {
        if value == 0 {
            bytes.append(0x30)
            return
        }
        var magnitude: UInt64
        if value < 0 {
            bytes.append(0x2D) // -
            magnitude = UInt64(bitPattern: 0 &- value)
        } else {
            magnitude = UInt64(value)
        }
        var digits = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                      UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                      UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                      UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        withUnsafeMutableBytes(of: &digits) { raw in
            var idx = 20
            while magnitude > 0 {
                idx -= 1
                raw[idx] = 0x30 &+ UInt8(magnitude % 10)
                magnitude /= 10
            }
            bytes.append(contentsOf: raw[idx..<20])
        }
    }

    mutating func writeDouble(_ raw: Double) throws(WebAccessibilityJSONError) {
        guard raw.isFinite else { throw .nonFiniteNumber }
        let value = raw == 0 ? 0.0 : raw
        if value >= -9_007_199_254_740_992.0 && value <= 9_007_199_254_740_992.0 && value.rounded(.towardZero) == value {
            writeInt64(Int64(value))
            return
        }
        // Fast path for exact tenths (rounded accessibility bounds and scroll coordinates).
        let scaled = value * 10.0
        if scaled >= -900_719_925_474_099.0 && scaled <= 900_719_925_474_099.0 {
            let nearest = scaled.rounded()
            if nearest / 10.0 == value {
                let tenth = Int64(nearest)
                if tenth < 0 { bytes.append(0x2D) }
                let absTenth = tenth < 0 ? UInt64(bitPattern: 0 &- tenth) : UInt64(tenth)
                writeInt64(Int64(absTenth / 10))
                let frac = UInt8(absTenth % 10)
                if frac != 0 {
                    bytes.append(0x2E) // .
                    bytes.append(0x30 &+ frac)
                }
                return
            }
        }
        bytes.append(contentsOf: String(value).utf8)
    }

    mutating func writeFloat(_ raw: Float) throws(WebAccessibilityJSONError) {
        guard raw.isFinite else { throw .nonFiniteNumber }
        #if canImport(ObjectiveC)
        try writeDouble(Double(raw))
        #else
        let value = raw == 0 ? Float(0) : raw
        if value >= -16_777_216.0 && value <= 16_777_216.0 && value.rounded(.towardZero) == value {
            writeInt64(Int64(value))
            return
        }
        let scaled = value * 10.0
        if scaled >= -1_677_721.0 && scaled <= 1_677_721.0 {
            let nearest = scaled.rounded()
            if nearest / 10.0 == value {
                let tenth = Int64(nearest)
                if tenth < 0 { bytes.append(0x2D) }
                let absTenth = tenth < 0 ? UInt64(bitPattern: 0 &- tenth) : UInt64(tenth)
                writeInt64(Int64(absTenth / 10))
                let frac = UInt8(absTenth % 10)
                if frac != 0 {
                    bytes.append(0x2E)
                    bytes.append(0x30 &+ frac)
                }
                return
            }
        }
        bytes.append(contentsOf: String(value).utf8)
        #endif
    }

    mutating func writeBounds(_ bounds: SIMD4<Float>) throws(WebAccessibilityJSONError) {
        bytes.append(0x5B) // [
        try writeFloat(bounds.x)
        bytes.append(0x2C)
        try writeFloat(bounds.y)
        bytes.append(0x2C)
        try writeFloat(bounds.z)
        bytes.append(0x2C)
        try writeFloat(bounds.w)
        bytes.append(0x5D) // ]
    }

    // MARK: - AccessibilityDumpFields

    mutating func set(_ field: AccessibilityDumpField, _ value: String) throws(WebAccessibilityJSONError) {
        writeFieldKey(field)
        writeString(value)
    }

    mutating func set(_ field: AccessibilityDumpField, _ value: Bool) throws(WebAccessibilityJSONError) {
        writeFieldKey(field)
        writeBool(value)
    }

    mutating func set(_ field: AccessibilityDumpField, _ value: Int) throws(WebAccessibilityJSONError) {
        writeFieldKey(field)
        writeInt(value)
    }

    mutating func set(_ field: AccessibilityDumpField, _ value: Float) throws(WebAccessibilityJSONError) {
        writeFieldKey(field)
        try writeFloat(value)
    }

    mutating func set(_ field: AccessibilityDumpField, _ value: [String]) throws(WebAccessibilityJSONError) {
        writeFieldKey(field)
        bytes.append(0x5B)
        for i in value.indices {
            if i > 0 { bytes.append(0x2C) }
            writeString(value[i])
        }
        bytes.append(0x5D)
    }

    mutating func set(_ field: AccessibilityDumpField, _ value: [Double]) throws(WebAccessibilityJSONError) {
        writeFieldKey(field)
        bytes.append(0x5B)
        for i in value.indices {
            if i > 0 { bytes.append(0x2C) }
            try writeDouble(value[i])
        }
        bytes.append(0x5D)
    }

    mutating func set(_ field: AccessibilityDumpField, _ value: [Int]) throws(WebAccessibilityJSONError) {
        writeFieldKey(field)
        bytes.append(0x5B)
        for i in value.indices {
            if i > 0 { bytes.append(0x2C) }
            writeInt(value[i])
        }
        bytes.append(0x5D)
    }

    mutating func setRange(_ range: A11yRange) throws(WebAccessibilityJSONError) {
        writeFieldKey(.range)
        bytes.append(0x5B)
        try writeDouble(range.value)
        bytes.append(0x2C)
        try writeDouble(range.min)
        bytes.append(0x2C)
        try writeDouble(range.max)
        bytes.append(0x2C)
        if let step = range.step { try writeDouble(step) } else { writeNull() }
        bytes.append(0x5D)
    }

    mutating func setFont(_ font: WebDocumentAccessibilityNode.Font) throws(WebAccessibilityJSONError) {
        writeFieldKey(.font)
        let outerComma = needsComma
        beginObject()
        try font.write(to: &self)
        endObject()
        needsComma = outerComma
    }
}

private struct WebAccessibilityPatchNode {
    let semantic: AccessibilityNode
    let path: String
    let bounds: SIMD4<Float>

    func write(to writer: inout WebAccessibilityJSONWriter) throws(WebAccessibilityJSONError) {
        writer.beginObject()
        writer.writeFieldKey(.bounds)
        try writer.writeBounds(bounds)
        try AccessibilityDump.writeShallow(semantic, isRoot: false, forBrowser: true, syntheticPath: path, to: &writer)
        writer.endObject()
    }
}

/// Keep patch collections in their concrete types all the way to the encoder. The full
/// browser snapshot and announcements still share the ordinary Foundation dump schema.
struct WebAccessibilityPatch {
    var removed: [String]?
    var children: [String: [String]]?
    fileprivate var local: Bool?
    fileprivate var nodes: [WebAccessibilityPatchNode]?
    fileprivate var bounds: [String: SIMD4<Float>]?

    init(removed: [String]? = nil, children: [String: [String]]? = nil) {
        self.removed = removed
        self.children = children
    }

    func encodePacket(_ fields: [String: Any]) throws -> Data {
        #if canImport(ObjectiveC)
        // Darwin Foundation raises an Objective-C exception for nonfinite numbers.
        guard JSONSerialization.isValidJSONObject(fields) else { throw CocoaError(.propertyListWriteInvalid) }
        #endif
        guard removed != nil || children != nil || nodes != nil || bounds != nil || local != nil else {
            return try JSONSerialization.data(withJSONObject: fields)
        }
        let estimated = (nodes?.count ?? 0) * 192 + (bounds?.count ?? 0) * 64 + (removed?.count ?? 0) * 40 + (children?.count ?? 0) * 64 + 64
        var writer = WebAccessibilityJSONWriter(capacity: estimated)
        writer.beginObject()
        if let removed {
            writer.writeASCIIKey("removed")
            writer.bytes.append(0x5B)
            for i in removed.indices {
                if i > 0 { writer.bytes.append(0x2C) }
                writer.writeString(removed[i])
            }
            writer.bytes.append(0x5D)
        }
        if let children {
            writer.writeASCIIKey("children")
            writer.bytes.append(0x7B)
            var firstParent = true
            for (parent, list) in children {
                if !firstParent { writer.bytes.append(0x2C) }
                firstParent = false
                writer.writeString(parent)
                writer.bytes.append(0x3A)
                writer.bytes.append(0x5B)
                for i in list.indices {
                    if i > 0 { writer.bytes.append(0x2C) }
                    writer.writeString(list[i])
                }
                writer.bytes.append(0x5D)
            }
            writer.bytes.append(0x7D)
        }
        if let local {
            writer.writeASCIIKey("local")
            writer.writeBool(local)
        }
        if let nodes {
            writer.writeASCIIKey("nodes")
            writer.bytes.append(0x5B)
            for i in nodes.indices {
                if i > 0 { writer.bytes.append(0x2C) }
                try nodes[i].write(to: &writer)
            }
            writer.bytes.append(0x5D)
        }
        if let bounds {
            writer.writeASCIIKey("bounds")
            writer.bytes.append(0x7B)
            var firstBound = true
            for (path, rect) in bounds {
                if !firstBound { writer.bytes.append(0x2C) }
                firstBound = false
                writer.writeString(path)
                writer.bytes.append(0x3A)
                try writer.writeBounds(rect)
            }
            writer.bytes.append(0x7D)
        }
        writer.endObject()
        var result = Data(writer.bytes)
        guard !fields.isEmpty else { return result }
        let rest = try JSONSerialization.data(withJSONObject: fields, options: .withoutEscapingSlashes)
        result.removeLast() // Closing brace of the nonempty patch object.
        result.append(0x2C) // Comma between the two sets of members.
        result.append(rest.dropFirst()) // Skip the opening brace of the remaining object.
        return result
    }
}

/// Keeps a per-mount semantic mirror. A parent's movement carries its DOM children, so only
/// changes to their parent-relative bounds need to cross the WASM boundary.
final class WebAccessibilityProjection {
    private final class Entry {
        var semantic: AccessibilityNode
        var bounds: SIMD4<Float>
        var children: [String]
        var geometryRange: Range<Int> = 0..<0
        var visited: UInt64

        init(_ semantic: AccessibilityNode, bounds: SIMD4<Float>, children: [String], visited: UInt64) {
            self.semantic = semantic
            self.bounds = bounds
            self.children = children
            self.visited = visited
        }
    }

    private struct Geometry {
        var path: String
        var runtimeIndex: Int
        var parent: Int?
        var origin: SIMD2<Float>
        var bounds: SIMD4<Float>
        var scrolls: Bool
        var entry: Entry?
    }

    private var entries: [String: Entry] = [:]
    private var generation: UInt64 = 0
    private var geometry: [Geometry] = []
    private var previousGeometry: [Geometry] = []
    private var deferred: [String: (old: Range<Int>, root: Int, offsets: [Int])] = [:]
    private var lastWebRead: AccessibilityProjectionCache.ReadStamp?
    private var uniqueMirrorPaths = true
    private var flatCount = 0
    private var canUpdateGeometry = false
    private var rootPath: String?
    private var legacyPrevious: AccessibilityNode?
    private var viewport = Vec2.zero
    private var documentMode = false
    private var lastCommit: UInt64?
    private var lastLive: UInt64?
    private var lastFocus: String?
    private var lastLink: Int?
    private var lastScroll: [String: Vec2] = [:]
    private var moving = false
    private var lastBuild: Double = 0
    private var spokenCount: UInt32?
    private var patches = false

    func enablePatches() {
        patches = true
        legacyPrevious = nil
        lastCommit = nil
    }

    /// The page already moved this DOM scroller. Ignore only its echoed X offset; programmatic
    /// scrolls and any independent Y movement still update the mirror.
    func acknowledgeDocumentScroll(_ path: String, x: Float) {
        guard patches, documentMode, entries[path] != nil else { return }
        var cached = lastScroll[path] ?? .zero
        cached.x = x
        lastScroll[path] = cached
        if let entry = entries[path] {
            entry.semantic.scrollX = x
            entry.semantic.webDocument?.scrollX = x
        }
    }

    /// An app defers initial DOM creation until idle. During continuous scrolling, geometry-only
    /// updates follow at most every 150 ms. The host makes one final pull after scrolling stops.
    func deferredPull<State>(_ runtime: Runtime<State>) -> Int {
        guard patches, !runtime.isPageMode, runtime.focusedPath == lastFocus, runtime.focusedLinkIndex == lastLink,
              runtime.a11yAnnouncement.count == (spokenCount ?? 0) else { return 0 }
        guard let lastCommit else { return -2 }
        let elapsed = runtime.currentTime - lastBuild
        if lastCommit == runtime.commitCount, lastLive == runtime.accessibilityLiveRevision,
           viewport == runtime.viewport, lastScroll != runtime.scrollOffsets,
           elapsed >= 0, elapsed < 0.15 { return -1 }
        return 0
    }

    func update<State>(_ runtime: Runtime<State>) -> Data? {
        let doc = WebAccessibilityDocument(runtime)
        let size = doc.map { Vec2($0.width, $0.height) } ?? runtime.viewport
        let reset = lastCommit == nil || viewport != size || documentMode != (doc != nil)
        let commit = runtime.commitCount
        let live = runtime.accessibilityLiveRevision
        let focused = runtime.focusedPath
        let link = runtime.focusedLinkIndex
        let animating = runtime.isAnimating
        let now = runtime.currentTime
        // Follow ongoing motion at the upstream 100 ms cadence, including its final settled pose.
        let follow = animating != moving || (animating && (now < lastBuild || now - lastBuild >= 0.1))
        let changed = reset || lastCommit != commit || lastLive != live || lastFocus != focused || lastLink != link ||
            lastScroll != runtime.scrollOffsets || follow
        let spoken = runtime.a11yAnnouncement
        var packet: [String: Any] = [:]
        var patch = WebAccessibilityPatch()
        if spoken.count != spokenCount, let words = spoken.words {
            packet["announcement"] = ["text": words.text, "live": words.politeness.rawValue]
        }
        guard changed || !packet.isEmpty else { return nil }

        if !changed && patches {
            spokenCount = spoken.count
            return try? JSONSerialization.data(withJSONObject: packet)
        }
        let geometryOnly = patches && !reset && lastCommit == commit && lastLive == live &&
            lastFocus == focused && lastLink == link && doc == nil && canUpdateGeometry &&
            flatCount == runtime.flatNodes.count && geometryDelta(runtime, patch: &patch)
        if !geometryOnly {
            deferred.removeAll(keepingCapacity: true)
            let reuse = patches && !reset && doc == nil && lastFocus == focused && lastLink == link &&
                uniqueMirrorPaths && !geometry.isEmpty && !runtime.virtualLists.isEmpty && runtime.linkBoxesByPath.isEmpty &&
                lastWebRead != nil &&
                lastWebRead == runtime.accessibilityProjectionCache?.completedRead
            var root = runtime.accessibilitySnapshot(securePaths: [], deferredBranch: reuse ? { path, base, previousRoot, offsets in
                guard let bounds = self.entries[path]?.geometryRange, bounds.count == offsets.count,
                      bounds.upperBound <= self.geometry.count else { return false }
                // A presentational ancestor can promote or omit part of a subtree. Only
                // reuse its mirror when the last publication contains exactly these raw slots.
                let old = self.geometry[bounds]
                if !zip(old, offsets).allSatisfy({ record, offset in record.runtimeIndex == previousRoot + offset }) {
                    // More than one accessibility update can observe the same mounted layout.
                    // Its old physical indices may differ from the preceding layout's span.
                    for (record, offset) in zip(old, offsets) {
                        let currentPath = runtime.flatNodes[base + offset].path
                        guard record.path.utf8.elementsEqual(currentPath.utf8) else { return false }
                    }
                }
                self.deferred[path] = (bounds, base, offsets)
                return true
            } : nil)
            let path = root.runtimePath ?? root.id
            if path != rootPath && !deferred.isEmpty {
                deferred.removeAll(keepingCapacity: true)
                root = runtime.accessibilitySnapshot()
            }
            doc?.project(&root)
            lastWebRead = runtime.accessibilityProjectionCache?.completedRead
            if !patches {
                if reset || root != legacyPrevious || !packet.isEmpty {
                    packet["root"] = AccessibilityDump.dictionary(from: root, isRoot: true, forBrowser: true)
                }
                legacyPrevious = root
            } else if reset || rootPath != path {
                delta(root, runtime: runtime, replace: true, patch: &patch)
                packet["root"] = AccessibilityDump.dictionary(from: root, isRoot: true, forBrowser: true)
            } else {
                delta(root, runtime: runtime, replace: false, patch: &patch)
            }
            rootPath = path
        }
        if packet["root"] != nil {
            packet["width"] = size.x
            packet["height"] = size.y
            if doc != nil { packet["document"] = true }
        }
        viewport = size
        documentMode = doc != nil
        lastCommit = commit
        lastLive = live
        lastFocus = focused
        lastLink = link
        lastScroll = runtime.scrollOffsets
        moving = animating
        lastBuild = now
        spokenCount = spoken.count
        guard !packet.isEmpty || patch.local != nil else { return nil }
        do {
            return try patch.encodePacket(packet)
        } catch {
            // The next pull must start from a complete snapshot after a failed transfer.
            lastCommit = nil
            return nil
        }
    }

    private func roundedBounds(_ frame: MotionRect) -> SIMD4<Float> {
        let xywh = SIMD4(frame.x, frame.y, frame.width, frame.height)
        return (xywh * 10).rounded(.toNearestOrAwayFromZero) / 10
    }

    /// Scrolling and motion between commits change presented geometry while leaving the committed
    /// roles, labels, relations and child order intact. Synthesized terminal/link children use the
    /// complete semantic projection because their bounds also depend on their text geometry.
    private func geometryDelta<State>(_ runtime: Runtime<State>, patch: inout WebAccessibilityPatch) -> Bool {
        // A virtual refill can replace mounted nodes; reproject their semantics if that happens.
        for record in geometry where runtime.flatNodes[record.runtimeIndex].path != record.path { return false }
        var bounds: [String: SIMD4<Float>] = [:]
        var nodes: [WebAccessibilityPatchNode] = []
        let presented = runtime.presentedRectByPath
        let slots = presented.indexedValues(at: runtime.layoutCommitGen)
        for index in geometry.indices {
            let record = geometry[index]
            let path = record.path
            let indexInMount = record.runtimeIndex
            let frame: MotionRect
            if let slots {
                frame = slots[indexInMount] ?? runtime.flatNodes[indexInMount].targetRect
            } else {
                frame = presented[path] ?? runtime.flatNodes[indexInMount].targetRect
            }
            let rect = roundedBounds(frame)
            let parent = record.parent.map { geometry[$0].origin } ?? .zero
            let local = rect - SIMD4(parent.x, parent.y, 0, 0)
            geometry[index].origin = SIMD2(rect.x, rect.y)
            let moved = local != record.bounds
            if moved {
                geometry[index].bounds = local
                record.entry?.bounds = local
            }
            if record.scrolls, let entry = record.entry {
                let offset = runtime.scrollOffsets[path] ?? .zero
                let maximum = runtime.scrollMaxExtents[path]?.y
                if entry.semantic.scrollX != offset.x || entry.semantic.scrollY != offset.y ||
                    entry.semantic.scrollYMax != maximum {
                    entry.semantic.scrollX = offset.x
                    entry.semantic.scrollY = offset.y
                    entry.semantic.scrollYMax = maximum
                    nodes.append(WebAccessibilityPatchNode(semantic: entry.semantic, path: path, bounds: local))
                    continue
                }
            }
            if moved { bounds[path] = local }
        }
        if !bounds.isEmpty { patch.bounds = bounds }
        if !nodes.isEmpty { patch.nodes = nodes }
        if !bounds.isEmpty || !nodes.isEmpty { patch.local = true }
        return true
    }

    private func delta<State>(_ root: AccessibilityNode, runtime: Runtime<State>, replace: Bool, patch: inout WebAccessibilityPatch) {
        var nodes: [WebAccessibilityPatchNode] = []
        var bounds: [String: SIMD4<Float>] = [:]
        var children: [String: [String]] = [:]
        var visitedCount = 0
        generation &+= 1
        let generation = self.generation
        swap(&geometry, &previousGeometry)
        geometry.removeAll(keepingCapacity: true)
        flatCount = runtime.flatNodes.count
        canUpdateGeometry = true
        let presented = runtime.presentedRectByPath
        let slots = presented.indexedValues(at: runtime.layoutCommitGen)
        @inline(__always) func currentRect(_ flat: Int, path: String) -> MotionRect {
            if let slots { return slots[flat] ?? runtime.flatNodes[flat].targetRect }
            return presented[path] ?? runtime.flatNodes[flat].targetRect
        }

        func copyBranch(_ branch: (old: Range<Int>, root: Int, offsets: [Int]), parent: Int?, origin: SIMD2<Float>) {
            let source = branch.old.lowerBound
            let shift = geometry.count - source
            for i in branch.old {
                var record = previousGeometry[i]
                let flat = branch.root + branch.offsets[i - source]
                record.runtimeIndex = flat
                record.parent = i == source ? parent : record.parent.map { $0 + shift }
                let frame = currentRect(flat, path: record.path)
                let rect = roundedBounds(frame)
                let inherited = i == source ? origin : record.parent.map { geometry[$0].origin } ?? .zero
                let local = rect - SIMD4(inherited.x, inherited.y, 0, 0)
                record.origin = SIMD2(rect.x, rect.y)
                record.bounds = local
                geometry.append(record)
                // Only complete real-node geometry is eligible for branch reuse.
                let entry = record.entry!
                entry.visited = generation
                if entry.bounds != local { bounds[record.path] = local }
                entry.bounds = local
                entry.geometryRange = (entry.geometryRange.lowerBound + shift)..<(entry.geometryRange.upperBound + shift)
            }
        }

        func visit(_ node: AccessibilityNode, path: String, parent: Int?, parentOrigin: SIMD2<Float>) {
            // The full snapshot rounds absolute positions to tenths before positioning a child.
            // Use the same rounding order so nested motion cannot drift by a tenth on each level.
            // An authored key can coincide with a generated link or terminal path.
            // A synthesized or already visited occurrence follows normal delta ordering.
            if let branch = deferred[path], node.runtimePath != nil, !node.children.isEmpty,
               previousGeometry[branch.old].allSatisfy({ $0.entry?.visited != generation }) {
                copyBranch(branch, parent: parent, origin: parentOrigin)
                visitedCount += branch.old.count
                return
            }
            visitedCount += 1
            let flat = node.runtimePath.flatMap { runtime.nodeByPath[$0] }
            // If a newly named parent promotes a reused group's children into its
            // own semantic order, the children still carry this frame's actual bounds.
            var frame = node.frame
            if !deferred.isEmpty, let flat {
                frame = currentRect(flat, path: path)
            }
            let rect = roundedBounds(frame)
            let local = rect - SIMD4(parentOrigin.x, parentOrigin.y, 0, 0)
            let geometryIndex = geometry.count
            if let realPath = node.runtimePath, let flat {
                geometry.append(Geometry(path: realPath, runtimeIndex: flat, parent: parent, origin: SIMD2(rect.x, rect.y),
                                         bounds: local, scrolls: node.scrollY != nil))
            } else {
                canUpdateGeometry = false
            }
            var shallow = node
            shallow.label = AccessibilityDump.resolvedName(for: node)
            shallow.children = []
            shallow.frame = .zero
            let prior = entries[path]
            let previousChildren = prior?.children ?? []
            // Most children keep their position when virtual rows cross the viewport.
            // Only allocate a replacement order after seeing the first different path.
            var changedChildren: [String]? = nil
            if previousChildren.count != node.children.count {
                changedChildren = []
                changedChildren?.reserveCapacity(node.children.count)
            }
            for (index, child) in node.children.enumerated() {
                let id = child.runtimePath ?? "\(path)#a11y-\(index)"
                if changedChildren == nil && id != previousChildren[index] {
                    changedChildren = Array(previousChildren.prefix(index))
                    changedChildren?.reserveCapacity(node.children.count)
                }
                changedChildren?.append(id)
                visit(child, path: id, parent: geometryIndex, parentOrigin: SIMD2(rect.x, rect.y))
            }
            let entry: Entry
            if let prior {
                entry = prior
                prior.visited = generation
                if prior.semantic != shallow {
                    prior.semantic = shallow
                    if !replace { nodes.append(WebAccessibilityPatchNode(semantic: shallow, path: path, bounds: local)) }
                } else if !replace && prior.bounds != local {
                    bounds[path] = local
                }
                prior.bounds = local
                if let changedChildren {
                    prior.children = changedChildren
                    if !replace { children[path] = changedChildren }
                }
            } else {
                let order = changedChildren ?? []
                entry = Entry(shallow, bounds: local, children: order, visited: generation)
                entries[path] = entry
                if !replace {
                    nodes.append(WebAccessibilityPatchNode(semantic: shallow, path: path, bounds: local))
                    if !order.isEmpty { children[path] = order }
                }
            }
            entry.geometryRange = geometryIndex..<geometry.count
            if flat != nil { geometry[geometryIndex].entry = entry }
        }
        visit(root, path: root.runtimePath ?? root.id, parent: nil, parentOrigin: .zero)
        previousGeometry.removeAll(keepingCapacity: true)
        deferred.removeAll(keepingCapacity: true)
        let removed = entries.compactMap { path, entry in entry.visited == generation ? nil : path }
        for path in removed { entries.removeValue(forKey: path) }
        uniqueMirrorPaths = visitedCount == entries.count
        if !replace {
            if !removed.isEmpty { patch.removed = removed }
            if !children.isEmpty { patch.children = children }
            if !nodes.isEmpty { patch.nodes = nodes }
            if !bounds.isEmpty { patch.bounds = bounds }
            if !bounds.isEmpty || !nodes.isEmpty || !removed.isEmpty || !children.isEmpty { patch.local = true }
        }
    }
}

#if os(WASI)
@MainActor @_cdecl("rune_web_enable_accessibility_patches")
func runeWebEnableAccessibilityPatches() { RuneWebReactor.session?.enableAccessibilityPatches() }

@MainActor @_cdecl("rune_web_accessibility")
func runeWebAccessibility() -> Int {
    let delay = RuneWebReactor.session?.deferredAccessibility() ?? 0
    return delay == 0 ? runeWebFlushAccessibility() : delay
}

@MainActor @_cdecl("rune_web_flush_accessibility")
func runeWebFlushAccessibility() -> Int {
    guard let data = RuneWebReactor.session?.takeAccessibility(),
          let bytes = RuneWebReactor.reserve(data.count) else { return 0 }
    data.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: data.count)
    return data.count
}
#endif
