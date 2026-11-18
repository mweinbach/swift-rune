import Foundation
import RuneMotion

/// Encode the path collections with their concrete Swift types. Foundation handles all
/// strings in both JSON objects, including escaping, before their members are joined.
struct WebAccessibilityPaths: Encodable {
    var removed: [String]?
    var children: [String: [String]]?

    func encodePacket(_ fields: [String: Any]) throws -> Data {
        #if canImport(ObjectiveC)
        // Darwin Foundation raises an Objective-C exception for nonfinite numbers.
        guard JSONSerialization.isValidJSONObject(fields) else { throw CocoaError(.propertyListWriteInvalid) }
        #endif
        guard removed != nil || children != nil else {
            return try JSONSerialization.data(withJSONObject: fields)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        var result = try encoder.encode(self)
        guard !fields.isEmpty else { return result }
        let rest = try JSONSerialization.data(withJSONObject: fields, options: .withoutEscapingSlashes)
        result.removeLast() // Closing brace of the nonempty path object.
        result.append(0x2C) // Comma between the two sets of members.
        result.append(rest.dropFirst()) // Skip the opening brace of the remaining object.
        return result
    }
}

/// Keeps a per-mount semantic mirror. A parent's movement carries its DOM children, so only
/// changes to their parent-relative bounds need to cross the WASM boundary.
final class WebAccessibilityProjection {
    private struct Entry {
        var semantic: AccessibilityNode
        var bounds: SIMD4<Float>
        var children: [String]
    }

    private struct Geometry {
        var path: String
        var runtimeIndex: Int
        var parent: Int?
        var origin: SIMD2<Float>
        var bounds: SIMD4<Float>
        var scrolls: Bool
    }

    private var entries: [String: Entry] = [:]
    private var geometry: [Geometry] = []
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
        if var entry = entries[path] {
            entry.semantic.scrollX = x
            entry.semantic.webDocument?.scrollX = x
            entries[path] = entry
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
        var paths = WebAccessibilityPaths()
        if spoken.count != spokenCount, let words = spoken.words {
            packet["announcement"] = ["text": words.text, "live": words.politeness.rawValue]
        }
        guard changed || !packet.isEmpty else { return nil }

        if !changed && patches {
            spokenCount = spoken.count
            return try? JSONSerialization.data(withJSONObject: packet)
        }
        if patches && !reset && lastCommit == commit && lastLive == live && lastFocus == focused && lastLink == link &&
            doc == nil && canUpdateGeometry && flatCount == runtime.flatNodes.count,
           let positions = geometryDelta(runtime) {
            packet.merge(positions) { _, new in new }
        } else {
            var root = runtime.accessibilitySnapshot()
            doc?.project(&root)
            let path = root.runtimePath ?? root.id
            if !patches {
                if reset || root != legacyPrevious || !packet.isEmpty {
                    packet["root"] = AccessibilityDump.dictionary(from: root, isRoot: true, forBrowser: true)
                }
                legacyPrevious = root
            } else if reset || rootPath != path {
                _ = delta(root, runtime: runtime, replace: true, paths: &paths)
                packet["root"] = AccessibilityDump.dictionary(from: root, isRoot: true, forBrowser: true)
            } else {
                packet.merge(delta(root, runtime: runtime, replace: false, paths: &paths)) { _, new in new }
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
        guard !packet.isEmpty else { return nil }
        do {
            return try paths.encodePacket(packet)
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
    private func geometryDelta<State>(_ runtime: Runtime<State>) -> [String: Any]? {
        // A virtual refill can replace mounted nodes; reproject their semantics if that happens.
        for record in geometry where runtime.flatNodes[record.runtimeIndex].path != record.path { return nil }
        var bounds: [String: [Float]] = [:]
        var nodes: [[String: Any]] = []
        for index in geometry.indices {
            let record = geometry[index]
            let path = record.path
            let frame = runtime.presentedRectByPath[path] ?? runtime.flatNodes[record.runtimeIndex].targetRect
            let rect = roundedBounds(frame)
            let parent = record.parent.map { geometry[$0].origin } ?? .zero
            let local = rect - SIMD4(parent.x, parent.y, 0, 0)
            geometry[index].origin = SIMD2(rect.x, rect.y)
            let moved = local != record.bounds
            if moved {
                geometry[index].bounds = local
                entries[path]?.bounds = local
            }
            if record.scrolls, var entry = entries[path] {
                let offset = runtime.scrollOffsets[path] ?? .zero
                let maximum = runtime.scrollMaxExtents[path]?.y
                if entry.semantic.scrollX != offset.x || entry.semantic.scrollY != offset.y ||
                    entry.semantic.scrollYMax != maximum {
                    entry.semantic.scrollX = offset.x
                    entry.semantic.scrollY = offset.y
                    entry.semantic.scrollYMax = maximum
                    entries[path] = entry
                    nodes.append(shallowDictionary(entry.semantic, path: path, bounds: local))
                    continue
                }
            }
            if moved { bounds[path] = [local.x, local.y, local.z, local.w] }
        }
        var packet: [String: Any] = [:]
        if !bounds.isEmpty { packet["bounds"] = bounds }
        if !nodes.isEmpty { packet["nodes"] = nodes }
        if !packet.isEmpty { packet["local"] = true }
        return packet
    }

    private func shallowDictionary(_ semantic: AccessibilityNode, path: String, bounds: SIMD4<Float>) -> [String: Any] {
        var result = AccessibilityDump.dictionary(from: semantic, isRoot: false, forBrowser: true, syntheticPath: path)
        result["bounds"] = [bounds.x, bounds.y, bounds.z, bounds.w]
        return result
    }

    private func delta<State>(_ root: AccessibilityNode, runtime: Runtime<State>, replace: Bool, paths: inout WebAccessibilityPaths) -> [String: Any] {
        var nodes: [[String: Any]] = []
        var bounds: [String: [Float]] = [:]
        var children: [String: [String]] = [:]
        var next: [String: Entry] = [:]
        next.reserveCapacity(entries.count)
        geometry.removeAll(keepingCapacity: true)
        flatCount = runtime.flatNodes.count
        canUpdateGeometry = true

        func visit(_ node: AccessibilityNode, path: String, parent: Int?, parentOrigin: SIMD2<Float>) {
            // The full snapshot rounds absolute positions to tenths before positioning a child.
            // Use the same rounding order so nested motion cannot drift by a tenth on each level.
            let rect = roundedBounds(node.frame)
            let local = rect - SIMD4(parentOrigin.x, parentOrigin.y, 0, 0)
            let geometryIndex = geometry.count
            if let realPath = node.runtimePath, let flat = runtime.nodeByPath[realPath] {
                geometry.append(Geometry(path: realPath, runtimeIndex: flat, parent: parent, origin: SIMD2(rect.x, rect.y),
                                         bounds: local, scrolls: node.scrollY != nil))
            } else {
                canUpdateGeometry = false
            }
            var shallow = node
            shallow.label = AccessibilityDump.resolvedName(for: node)
            shallow.children = []
            shallow.frame = .zero
            var paths: [String] = []
            paths.reserveCapacity(node.children.count)
            for (index, child) in node.children.enumerated() {
                let id = child.runtimePath ?? "\(path)#a11y-\(index)"
                paths.append(id)
                visit(child, path: id, parent: geometryIndex, parentOrigin: SIMD2(rect.x, rect.y))
            }
            if !replace {
                let prior = entries[path]
                if prior?.semantic != shallow {
                    nodes.append(shallowDictionary(shallow, path: path, bounds: local))
                } else if prior?.bounds != local {
                    bounds[path] = [local.x, local.y, local.z, local.w]
                }
                if prior?.children != paths && (prior != nil || !paths.isEmpty) { children[path] = paths }
            }
            next[path] = Entry(semantic: shallow, bounds: local, children: paths)
        }
        visit(root, path: root.runtimePath ?? root.id, parent: nil, parentOrigin: .zero)
        var packet: [String: Any] = [:]
        if !replace {
            let removed = entries.keys.filter { next[$0] == nil }
            if !removed.isEmpty { paths.removed = removed }
            if !children.isEmpty { paths.children = children }
            if !nodes.isEmpty { packet["nodes"] = nodes }
            if !bounds.isEmpty { packet["bounds"] = bounds }
            if !packet.isEmpty || !removed.isEmpty || !children.isEmpty { packet["local"] = true }
        }
        entries = next
        return packet
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
