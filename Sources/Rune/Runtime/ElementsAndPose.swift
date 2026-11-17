import Foundation
import RuneMotion

/// What an element presents beyond its rect and opacity, as of the last frame (`Runtime.presentedPose`).
public struct Pose: Sendable, Equatable {
    public var rotation: Float
    public var scale: Float
    public var shadows: [Shadow]
    public var moving: Bool

    public init(rotation: Float, scale: Float, shadows: [Shadow], moving: Bool) {
        self.rotation = rotation
        self.scale = scale
        self.shadows = shadows
        self.moving = moving
    }
}

/// One presented element as `Runtime.motionElements(_:)` reports it (`motion_elements.rs`).
public struct MotionElement: Sendable, Equatable {
    public var id: NodeId
    public var parent: Int?
    public var rect: [Float]
    public var visible: [Float]
    public var opacity: Float
    public var scale: Float
    public var loopPhase: Float
    public var textHash: UInt64
    public var flags: UInt16

    public static let EXITING: UInt16 = 1
    public static let SCROLLING: UInt16 = 2
    public static let GROWING: UInt16 = 4
    public static let LIVE: UInt16 = 8
    public static let VIRTUAL: UInt16 = 16
    public static let TEXT: UInt16 = 32
    public static let LOOP: UInt16 = 64
    public static let PAINTS: UInt16 = 128

    public static let exiting: UInt16 = EXITING
    public static let scrolling: UInt16 = SCROLLING
    public static let growing: UInt16 = GROWING
    public static let live: UInt16 = LIVE
    public static let virtual: UInt16 = VIRTUAL
    public static let text: UInt16 = TEXT
    public static let loop: UInt16 = LOOP
    public static let paints: UInt16 = PAINTS

    public init(
        id: NodeId,
        parent: Int?,
        rect: [Float],
        visible: [Float],
        opacity: Float,
        scale: Float,
        loopPhase: Float,
        textHash: UInt64,
        flags: UInt16
    ) {
        self.id = id
        self.parent = parent
        self.rect = rect
        self.visible = visible
        self.opacity = opacity
        self.scale = scale
        self.loopPhase = loopPhase
        self.textHash = textHash
        self.flags = flags
    }

    public func isFlag(_ flag: UInt16) -> Bool {
        (flags & flag) != 0
    }

    public func `is`(_ flag: UInt16) -> Bool {
        (flags & flag) != 0
    }

    /// Fixed-cost hash of up to the first 64 and last 64 UTF-8 bytes; 0 for empty or secure text.
    public static func computeTextHash(_ text: String) -> UInt64 {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return 0 }
        var h: UInt64 = 0xcbf2_9ce4_8422_2325 ^ UInt64(bytes.count)
        func mix(_ slice: ArraySlice<UInt8>) {
            var idx = slice.startIndex
            while idx < slice.endIndex {
                let end = min(idx + 8, slice.endIndex)
                var word: UInt64 = 0
                for (shiftIdx, bIdx) in (idx..<end).enumerated() {
                    word |= UInt64(slice[bIdx]) << UInt64(shiftIdx * 8)
                }
                h = (h ^ word) &* 0x9e37_79b9_7f4a_7c15
                h = (h << 29) | (h >> 35)
                idx = end
            }
        }
        let head = min(bytes.count, 64)
        mix(bytes[0..<head])
        let tailStart = max(head, bytes.count - 64)
        if tailStart < bytes.count {
            mix(bytes[tailStart..<bytes.count])
        }
        return max(h, 1)
    }
}

internal struct PoseNodeSnapshot {
    var nodeId: NodeId
    var path: String
    var key: String?
    var rect: [Float]
    var opacity: Float
    var rotation: Float
    var scale: Float
    var shadows: [Shadow]
    var moving: Bool
}

internal struct RawPoseNodeData {
    var nodeId: NodeId
    var path: String
    var key: String?
    var anchorKey: String?
    var rotation: Float
    var scale: Float
    var shadows: [Shadow]
    var ownMoving: Bool
    var ownScrolling: Bool
    var ownGrowingRow: Bool
    var ownLiveIntent: UInt32
    var ownMotionLive: Bool
    var instantHoverGroupRule: Bool
    var loopActive: Bool
}

extension Runtime {
    private static var maxTrackedShadows: Int { 8 }

    @inline(__always)
    internal static func shadowGeomProp(_ index: Int) -> Prop<MotionRect> {
        Prop.custom(64 + UInt16(index * 2), .shape, name: "shadowGeom\(index)")
    }

    @inline(__always)
    internal static func shadowColorProp(_ index: Int) -> Prop<MotionColor> {
        Prop.custom(64 + UInt16(index * 2 + 1), .color, name: "shadowColor\(index)")
    }

    internal func syncShadowTracks(
        nodes: [FlatNode],
        prevNodes: [FlatNode],
        specs: [NodeSpec],
        at scaledNow: Double,
        cut: Bool,
        lands: Bool,
        prevMountedIds: Set<NodeId>
    ) {
        var prevShadowsById: [NodeId: [Shadow]] = [:]
        if !shadowTrackCounts.isEmpty {
            prevShadowsById.reserveCapacity(shadowTrackCounts.count)
            for pNode in prevNodes where shadowTrackCounts[pNode.nodeId] != nil {
                prevShadowsById[pNode.nodeId] = pNode.el.shadows
            }
        }
        for i in nodes.indices {
            let node = nodes[i]
            let nid = node.nodeId
            let count = min(node.el.shadows.count, Self.maxTrackedShadows)
            let prevCount = shadowTrackCounts[nid] ?? 0
            if count < prevCount {
                for k in count..<prevCount {
                    liveStore.remove(nid, Self.shadowGeomProp(k))
                    liveStore.remove(nid, Self.shadowColorProp(k))
                }
            }
            guard count > 0 else {
                shadowTrackCounts.removeValue(forKey: nid)
                continue
            }
            let paintSp = i < specs.count ? specs[i].paintSpring : nil
            let isFresh = !prevMountedIds.contains(nid)
            let prevShadows = prevShadowsById[nid]
            for k in 0..<count {
                let sh = node.el.shadows[k]
                let geom = MotionRect(left: sh.x, top: sh.y, right: sh.blur, bottom: sh.spread)
                let col = sh.color.motionColor
                let geomProp = Self.shadowGeomProp(k)
                let colProp = Self.shadowColorProp(k)
                let insetFlipped = (prevShadows != nil && k < prevShadows!.count)
                    ? (prevShadows![k].inset != sh.inset)
                    : false
                let shouldSnap = cut || lands || isFresh || paintSp == nil || !liveStore.has(nid, geomProp) || insetFlipped
                if shouldSnap {
                    liveStore.snap(nid, geomProp, to: geom)
                    liveStore.snap(nid, colProp, to: col)
                } else if let sp = paintSp {
                    liveStore.set(nid, geomProp, to: geom, anim: .spring(sp), at: scaledNow)
                    liveStore.set(nid, colProp, to: col, anim: .spring(sp), at: scaledNow)
                }
            }
            shadowTrackCounts[nid] = count
        }
    }

    internal func resolvedShadows(for nid: NodeId, authored: [Shadow]) -> [Shadow] {
        guard !authored.isEmpty else { return [] }
        return authored.enumerated().map { k, sh in
            guard k < Self.maxTrackedShadows else { return sh }
            let geomProp = Self.shadowGeomProp(k)
            let colProp = Self.shadowColorProp(k)
            var out = sh
            if let g = liveStore.get(nid, geomProp) {
                let settled = !liveStore.isMoving(nid, geomProp)
                    && abs(g.left - sh.x) < 1e-3
                    && abs(g.top - sh.y) < 1e-3
                    && abs(g.right - sh.blur) < 1e-3
                    && abs(g.bottom - sh.spread) < 1e-3
                if !settled {
                    out.x = g.left
                    out.y = g.top
                    out.blur = max(0, g.right)
                    out.spread = g.bottom
                }
            }
            if let mc = liveStore.get(nid, colProp) {
                let settled = !liveStore.isMoving(nid, colProp)
                    && abs(mc.r - sh.color.r) < 1e-3
                    && abs(mc.g - sh.color.g) < 1e-3
                    && abs(mc.b - sh.color.b) < 1e-3
                    && abs(mc.a - sh.color.a) < 1e-3
                if !settled {
                    out.color = Color(mc)
                }
            }
            return out
        }
    }

    internal func paintPoseSpringing(for nid: NodeId, shadowCount: Int) -> Bool {
        if scene.store.isMoving(nid, Props.ICON_TURN) {
            return true
        }
        let tracked = min(shadowCount, Self.maxTrackedShadows)
        for k in 0..<tracked {
            if liveStore.isMoving(nid, Self.shadowGeomProp(k)) || liveStore.isMoving(nid, Self.shadowColorProp(k)) {
                return true
            }
        }
        return false
    }

    internal func computeOwnLiveIntent(el: El<State>) -> (bits: UInt32, motionLive: Bool) {
        var bits: UInt32 = (el.runtimeExtras["motionGate.motionIntent"] as? UInt16).map(UInt32.init) ?? 0
        var motionLive = false
        for b in el.liveBindings where b.spring == nil {
            switch b.target {
            case .offset:
                bits |= 1
                motionLive = true
            case .scale, .rect:
                bits |= 1 | 2
                motionLive = true
            case .opacity:
                bits |= 4
                motionLive = true
            case .blur, .trim, .fill, .textColor, .borderColor, .shadowColor, .gradientTop, .gradientBottom:
                break
            }
        }
        return (bits, motionLive)
    }

    internal func computeInstantHoverGroupRule(snap: FlatNode) -> Bool {
        guard snap.el.groupOpacity != nil else { return false }
        var cur = snap.parentIndex
        while let pIdx = cur, flatNodes.indices.contains(pIdx) {
            let candidate = flatNodes[pIdx]
            if candidate.el.hoverBg != nil || candidate.el.isHoverGroup {
                let hc = candidate.el.hoverMotionSpec ?? hoverCurvesById[candidate.nodeId]
                if let hc, case .instant = hc.enter.curve {
                    return true
                }
                if let hc, case .instant = hc.exit.curve {
                    return true
                }
                return false
            }
            cur = candidate.parentIndex
        }
        return false
    }

    internal func finalizeElementTreeSnapshots(
        infos: inout [ElementInfo],
        rawPoseByPath: [String: RawPoseNodeData]
    ) {
        let count = infos.count
        var infoIdxByPath: [String: Int] = Dictionary(minimumCapacity: count)
        for i in 0..<count {
            infoIdxByPath[infos[i].path] = i
        }

        // Resolve step_up index: anchored target (`el.anchor?.key`) first, else DFS tree parent.
        var stepUpIdx = [Int?](repeating: nil, count: count)
        var treeParentIdx = [Int?](repeating: nil, count: count)
        for i in 0..<count {
            let info = infos[i]
            if let pid = info.parentIndex, flatNodes.indices.contains(pid),
               let mappedParent = infoIdxByPath[flatNodes[pid].path],
               mappedParent != i {
                treeParentIdx[i] = mappedParent
            } else if let slash = info.path.lastIndex(of: "/"), slash > info.path.startIndex {
                let parentPath = String(info.path[..<slash])
                if let mappedParent = infoIdxByPath[parentPath], mappedParent != i {
                    treeParentIdx[i] = mappedParent
                }
            }
            if let anchorKey = rawPoseByPath[info.path]?.anchorKey {
                if let matchIdx = infos.firstIndex(where: {
                    !$0.exiting && selectsElementSelector(anchorKey, path: $0.path, key: $0.key)
                }) {
                    stepUpIdx[i] = matchIdx
                } else {
                    stepUpIdx[i] = treeParentIdx[i]
                }
            } else {
                stepUpIdx[i] = treeParentIdx[i]
            }
        }

        var effMoving = [Bool](repeating: false, count: count)
        var effScrolling = [Bool](repeating: false, count: count)
        var effGrowing = [Bool](repeating: false, count: count)
        var effLiveIntent = [UInt32](repeating: 0, count: count)
        var effMotionLive = [Bool](repeating: false, count: count)

        for i in 0..<count {
            let rawSelf = rawPoseByPath[infos[i].path]
            var moving = infos[i].moving || (rawSelf?.ownMoving ?? false)
            var scrolling = false
            var growing = false
            var intent = infos[i].liveIntent | (rawSelf?.ownLiveIntent ?? 0)
            var motionLive = (rawSelf?.ownMotionLive ?? false)
            if let nid = rawSelf?.nodeId, frameLandingHoldIds.contains(nid) {
                intent |= 1 | 2
                motionLive = true
            }
            if rawSelf?.instantHoverGroupRule == true {
                intent |= 4 | 16
            }

            var visited = Set<Int>()
            var cur = stepUpIdx[i]
            while let ancIdx = cur, !visited.contains(ancIdx) {
                visited.insert(ancIdx)
                let ancInfo = infos[ancIdx]
                let ancRaw = rawPoseByPath[ancInfo.path]
                if ancInfo.moving || (ancRaw?.ownMoving ?? false) { moving = true }
                if ancRaw?.ownScrolling == true { scrolling = true }
                if ancRaw?.ownGrowingRow == true { growing = true }
                if let ar = ancRaw {
                    intent |= ar.ownLiveIntent
                    if ar.ownMotionLive { motionLive = true }
                    if frameLandingHoldIds.contains(ar.nodeId) {
                        intent |= 1 | 2
                        motionLive = true
                    }
                    if ar.instantHoverGroupRule {
                        intent |= 4 | 16
                    }
                }
                cur = stepUpIdx[ancIdx]
            }

            effMoving[i] = moving
            effScrolling[i] = scrolling
            effGrowing[i] = growing
            effLiveIntent[i] = intent
            effMotionLive[i] = motionLive
            infos[i].moving = moving
            infos[i].scrolling = scrolling
            infos[i].inGrowingRow = growing
            infos[i].liveIntent = intent
        }

        var nextPoseNodes: [PoseNodeSnapshot] = []
        nextPoseNodes.reserveCapacity(count)
        var nextMotion: [MotionElement] = []
        nextMotion.reserveCapacity(count)

        for i in 0..<count {
            let info = infos[i]
            let raw = rawPoseByPath[info.path]
            let nid = raw?.nodeId ?? NodeId.hash(info.path)
            nextPoseNodes.append(PoseNodeSnapshot(
                nodeId: nid,
                path: info.path,
                key: info.key,
                rect: info.rect,
                opacity: info.opacity,
                rotation: raw?.rotation ?? 0,
                scale: raw?.scale ?? info.scale,
                shadows: raw?.shadows ?? [],
                moving: effMoving[i]
            ))

            var flags: UInt16 = 0
            if info.exiting { flags |= MotionElement.EXITING }
            if effScrolling[i] { flags |= MotionElement.SCROLLING }
            if effGrowing[i] || info.revealing { flags |= MotionElement.GROWING }
            if effMotionLive[i] { flags |= MotionElement.LIVE }
            if info.virtualExtent { flags |= MotionElement.VIRTUAL }
            if info.role == .text { flags |= MotionElement.TEXT }
            if info.loopPhase != nil { flags |= MotionElement.LOOP }
            let hash: UInt64
            if info.secure || info.text == nil {
                hash = 0
            } else {
                hash = MotionElement.computeTextHash(info.text!)
            }
            if info.fill.a > 0.01 || hash != 0 {
                flags |= MotionElement.PAINTS
            }
            nextMotion.append(MotionElement(
                id: nid,
                parent: treeParentIdx[i],
                rect: info.rect,
                visible: info.visible,
                opacity: info.opacity,
                scale: info.scale,
                loopPhase: info.loopPhase.map(Float.init) ?? Float.nan,
                textHash: hash,
                flags: flags
            ))
        }

        lastPoseNodes = nextPoseNodes
        lastMotionElements = nextMotion
        frameMovedScrollPaths.removeAll(keepingCapacity: true)
        frameLandingHoldIds.removeAll(keepingCapacity: true)
    }

    /// Drawn `[x, y, w, h]` in points and effective opacity (ancestors included) of the element
    /// matching `key`, exiting or not, as of the last frame (`elements.rs:406`).
    public func presented(_ key: String) -> (rect: [Float], opacity: Float)? {
        if !key.contains("/"), let exact = lastPoseNodes.first(where: { $0.key == key }) {
            return (exact.rect, exact.opacity)
        }
        guard let matched = lastPoseNodes.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) }) else {
            return nil
        }
        return (matched.rect, matched.opacity)
    }

    /// The presented rotation, scale, and shadows of the element matching `key`, exiting or not,
    /// as of the last frame, and whether any spring or decorative loop still moves them (`elements.rs:497`).
    public func presentedPose(_ key: String) -> Pose? {
        let matched: PoseNodeSnapshot?
        if !key.contains("/") {
            matched = lastPoseNodes.first(where: { $0.key == key })
                ?? lastPoseNodes.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) })
        } else {
            matched = lastPoseNodes.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) })
        }
        guard let snap = matched else { return nil }
        return Pose(
            rotation: snap.rotation,
            scale: snap.scale,
            shadows: snap.shadows,
            moving: snap.moving
        )
    }

    /// Fills `out` with the presented `MotionElement`s of the last frame in tree order,
    /// preserving `out`'s existing capacity (`motion_elements.rs:78`).
    public func motionElements(_ out: inout [MotionElement]) {
        out.removeAll(keepingCapacity: true)
        out.append(contentsOf: lastMotionElements)
    }

    /// Convenience returning a new array of the last frame's `MotionElement`s.
    public func motionElements() -> [MotionElement] {
        lastMotionElements
    }

    /// Returns `(path, key)` for the element with `id`, as `ElementInfo.path` and `ElementInfo.key` (`motion_elements.rs:156`).
    public func elementPath(_ id: NodeId) -> (path: String, key: String?)? {
        if let n = nodeById[id] {
            return (n.path, n.key)
        }
        if let n = exitingSnapshots[id] {
            return (n.path, n.key)
        }
        if let p = lastPoseNodes.first(where: { $0.nodeId == id }) {
            return (p.path, p.key)
        }
        return nil
    }

    // MARK: - Font Families (`runtime/font_families.rs`) & Event Log (`runtime/event_log.rs`)

    /// Switches `.systemUI` (`sans`) and `.monospace` (`mono`) font family slots (`Runtime::set_font_families`).
    public func setFontFamilies(_ sans: String, _ mono: String) {
        if textSystem.setFamilies(sans: sans, mono: mono) {
            memo.clear()
            retainedLayout = RetainedLayoutCoordinator()
            dirtyCommit(at: currentTime)
        }
    }

    /// Current sans and mono font family slot strings (`Runtime::font_families`).
    public var fontFamilies: (sans: String, mono: String) {
        textSystem.families()
    }

    /// Records a diagnostic event marker when `recordEvents || traceChannels != nil` (`runtime/event_log.rs`).
    internal func logEvent(_ event: @autoclosure () -> String) {
        guard recordEvents || traceChannels != nil || inputMachines.traceChannelsActive else { return }
        RuntimeEventLog.push(&events, event())
    }
}

extension Tx {
    /// Queues switching the runtime's `.systemUI` (`sans`) and `.monospace` (`mono`) font family slots (`Tx::set_font_families`).
    public mutating func setFontFamilies(_ sans: String, _ mono: String) {
        runtimeActions["fontFamilies"] = (sans, mono)
    }
}
