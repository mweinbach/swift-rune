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
        var text = text
        return text.withUTF8 { bytes in
            guard !bytes.isEmpty else { return 0 }
            var h: UInt64 = 0xcbf2_9ce4_8422_2325 ^ UInt64(bytes.count)
            func mix(_ range: Range<Int>) {
                var idx = range.lowerBound
                while idx < range.upperBound {
                    let end = min(idx + 8, range.upperBound)
                    var word: UInt64 = 0
                    for i in idx..<end {
                        word |= UInt64(bytes[i]) << ((i - idx) * 8)
                    }
                    h = (h ^ word) &* 0x9e37_79b9_7f4a_7c15
                    h = (h << 29) | (h >> 35)
                    idx = end
                }
            }
            let head = min(bytes.count, 64)
            mix(0..<head)
            mix(max(head, bytes.count - 64)..<bytes.count)
            return max(h, 1)
        }
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
    var loopPhase: Double?
    var virtualExtent: Bool
    var revealing: Bool
}

/// Paint publishes rectangles, opacity and movement in ElementInfo. Retain only additional pose data.
internal struct NativeFrameInspection {
    var rawPoseByPath: [String: RawPoseNodeData]
    var landingHolds: Set<NodeId>
    var elementCount: Int
    var hasInheritedFlags: Bool
    var a11yMaterialized = true
    var inheritedFlagsMaterialized = false
    var materialized = false
}

private enum PoseVisit: UInt8 { case unseen, visiting, done }

private struct PoseInheritance {
    var moving = false
    var scrolling = false
    var growing = false
    var motionLive = false
    var intent: UInt32 = 0

    mutating func formUnion(_ other: Self) {
        moving = moving || other.moving
        scrolling = scrolling || other.scrolling
        growing = growing || other.growing
        motionLive = motionLive || other.motionLive
        intent |= other.intent
    }
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
        prevMountedIds: Dictionary<NodeId, Int>.Keys
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

    internal func movingGrowthPaintPaths() -> Set<String> {
        var paths: Set<String> = []
        for (key, row) in growthRows where row.track.moving {
            if let path = slice2State.growthRowPathByKey[key] {
                paths.insert(path)
            } else if let separator = key.firstIndex(of: ":") {
                paths.insert(String(key[key.index(after: separator)...]))
            }
        }
        return paths
    }

    internal func needsPaintPose(
        _ node: FlatNode, el: El<State>, rotation: Float, shadows: [Shadow], growing: Bool, inFlight: Bool
    ) -> Bool {
        if rotation != 0 || !shadows.isEmpty || el.anchor != nil || !el.liveBindings.isEmpty
            || el.groupOpacity != nil || !el.layout.scrollAxes.isEmpty || el.layoutAnim?.travel == .screen
            || growing || inFlight { return true }
        if (!loopRuntime.tracks.isEmpty && loopRuntime.tracks[node.nodeId] != nil)
            || (!activeVirtualPaths.isEmpty && activeVirtualPaths.contains(node.path))
            || (el.iconPayload != nil && scene.store.isMoving(node.nodeId, Props.ICON_TURN)) { return true }
        let extras = el.runtimeExtras
        return !extras.isEmpty && (extras["motionGate.motionIntent"] != nil
            || extras["motionGate.inGrowingRow"] != nil || extras["motionGate.revealing"] != nil)
    }

    internal func inspectPaintedNode(
        _ snap: FlatNode, el: El<State>, rotation: Float, scale: Float, shadows: [Shadow], liveShadowColor: Color?,
        spatialMoving: Bool, flightTarget: Bool, inFlight: Bool, growthMoving: Bool? = nil
    ) -> RawPoseNodeData {
        var nodeLoopPhase: Double?
        var ownLoopActive = false
        if let track = loopRuntime.tracks[snap.nodeId] {
            let nodeTime = scene.store.nodeTime(snap.nodeId)
            let sequence: Bool
            if case .sequence = el.loopingSpec?.kind { sequence = true } else { sequence = false }
            nodeLoopPhase = reducedMotion && !sequence ? 0 : track.phase(at: nodeTime)
            ownLoopActive = !reducedMotion && track.isActive(at: nodeTime)
        }
        let isOwnScrollGliding = !el.layout.scrollAxes.isEmpty
            && (scrollGlidingPaths.contains(snap.path) || scrollStore.isMoving(NodeId.hash("scroll:" + snap.path), Props.SCROLL))
        let isOwnScrollMoving = isOwnScrollGliding || (!el.layout.scrollAxes.isEmpty
            && (frameMovedScrollPaths.contains(snap.path) || slice2State.scrollModes[snap.path]?.hand.scrolling == true))
        let rowTrackMoving = growthMoving ?? (!growthRows.isEmpty && (growthRows["growth:\(snap.path)"]?.track.moving == true
            || growthRows["fold:\(snap.path)"]?.track.moving == true))
        let isOwnGrowthMoving = rowTrackMoving || ((el.runtimeExtras["motionGate.inGrowingRow"] as? Bool) ?? false)
        let nodeRevealing = flightTarget
            || ((el.runtimeExtras["motionGate.revealing"] as? Bool) ?? false)
        let ownPaintPoseMoving = paintPoseSpringing(for: snap.nodeId, shadowCount: shadows.count)
        let nodeOwnMoving = spatialMoving
            || ownPaintPoseMoving
            || ownLoopActive
            || inFlight
            || isOwnGrowthMoving
        let (ownLiveBits, ownMotionLive) = computeOwnLiveIntent(el: el)
        let isVirtualExt = activeVirtualPaths.contains(snap.path)
            && el.background.a == 0
            && el.borderWidth == 0
            && shadows.isEmpty
            && el.plainText == nil
            && el.richSpans == nil
            && el.liveText == nil
            && el.iconPayload == nil

        var paintedShadows = shadows
        if let liveShadowColor, !paintedShadows.isEmpty { paintedShadows[0].color = liveShadowColor }
        return RawPoseNodeData(
            nodeId: snap.nodeId,
            anchorKey: el.anchor?.key,
            rotation: rotation,
            scale: scale,
            shadows: paintedShadows,
            ownMoving: nodeOwnMoving || isOwnScrollGliding,
            ownScrolling: isOwnScrollMoving,
            ownGrowingRow: isOwnGrowthMoving,
            ownLiveIntent: ownLiveBits,
            ownMotionLive: ownMotionLive,
            instantHoverGroupRule: computeInstantHoverGroupRule(snap: snap),
            loopPhase: nodeLoopPhase,
            virtualExtent: isVirtualExt,
            revealing: nodeRevealing
        )
    }

    internal func finalizeElementTreeSnapshots(
        infos: inout [ElementInfo],
        rawPoseByPath: [String: RawPoseNodeData],
        landingHolds: Set<NodeId>,
        nativeCount: Int? = nil, motionElements: Bool = true
    ) {
        let count = nativeCount ?? infos.count
        var infoIdxByPath: [String: Int] = [:]
        if nativeCount == nil {
            infoIdxByPath.reserveCapacity(count)
            for i in 0..<count { infoIdxByPath[infos[i].path] = i }
        }

        // Resolve step_up index: anchored target (`el.anchor?.key`) first, else DFS tree parent.
        var stepUpIdx = [Int?](repeating: nil, count: count)
        var treeParentIdx = [Int?](repeating: nil, count: count)
        for i in 0..<count {
            let info = infos[i]
            if nativeCount != nil {
                treeParentIdx[i] = info.parentIndex
            } else if let pid = info.parentIndex, flatNodes.indices.contains(pid),
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
                if let matchIdx = infos.prefix(count).firstIndex(where: {
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

        // Most parents precede their children. An anchor can target any later node or form a cycle.
        // Memoize each inclusive ancestor union once, including every member of an anchor cycle.
        var inherited = [PoseInheritance]()
        inherited.reserveCapacity(count)
        for info in infos.prefix(count) {
            let raw = rawPoseByPath[info.path]
            let landing = !landingHolds.isEmpty && landingHolds.contains(raw?.nodeId ?? NodeId.hash(info.path))
            inherited.append(PoseInheritance(
                moving: info.moving || raw?.ownMoving == true,
                scrolling: raw?.ownScrolling == true,
                growing: raw?.ownGrowingRow == true,
                motionLive: landing || raw?.ownMotionLive == true,
                intent: (raw?.ownLiveIntent ?? 0) | (landing ? 1 | 2 : 0)
                    | (raw?.instantHoverGroupRule == true ? 4 | 16 : 0)
            ))
        }
        var visit = [PoseVisit](repeating: .unseen, count: count)
        var chain: [Int] = []
        for i in 0..<count where visit[i] == .unseen {
            var cursor: Int? = i
            while let c = cursor, visit[c] == .unseen {
                visit[c] = .visiting
                chain.append(c)
                cursor = stepUpIdx[c]
            }
            var parent = PoseInheritance()
            if let c = cursor {
                if visit[c] == .done {
                    parent = inherited[c]
                } else {
                    for member in chain.reversed() {
                        parent.formUnion(inherited[member])
                        if member == c { break }
                    }
                }
            }
            while let member = chain.popLast() {
                parent.formUnion(inherited[member])
                inherited[member] = parent
                visit[member] = .done
            }
        }

        var nextPoseNodes: [PoseNodeSnapshot] = []
        var nextMotion: [MotionElement] = []
        if motionElements {
            nextPoseNodes.reserveCapacity(count)
            nextMotion.reserveCapacity(count)
        }

        for i in 0..<count {
            let motion = inherited[i]
            let parent = stepUpIdx[i].map { inherited[$0] }
            infos[i].moving = motion.moving
            infos[i].scrolling = parent?.scrolling == true
            infos[i].inGrowingRow = parent?.growing == true
            infos[i].liveIntent |= motion.intent
            guard motionElements else { continue }
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
                moving: info.moving
            ))

            var flags: UInt16 = 0
            if info.exiting { flags |= MotionElement.EXITING }
            if info.scrolling { flags |= MotionElement.SCROLLING }
            if info.inGrowingRow || info.revealing { flags |= MotionElement.GROWING }
            if motion.motionLive { flags |= MotionElement.LIVE }
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

        if motionElements {
            lastPoseNodes = nextPoseNodes
            lastMotionElements = nextMotion
        }
    }

    internal func invalidateNativeMotionElements() {
        nativeInspection?.materialized = false
    }

    internal func materializeNativeInspection(motionElements: Bool = true) {
        guard let snapshot = nativeInspection, !snapshot.materialized,
              motionElements || !snapshot.inheritedFlagsMaterialized else { return }
        finalizeElementTreeSnapshots(
            infos: &lastElements, rawPoseByPath: snapshot.rawPoseByPath,
            landingHolds: snapshot.landingHolds, nativeCount: snapshot.elementCount, motionElements: motionElements
        )
        for index in snapshot.elementCount..<lastElements.count {
            if let parent = lastElements[index].parentIndex, parent < snapshot.elementCount {
                lastElements[index].moving = lastElements[parent].moving
            }
        }
        nativeInspection?.inheritedFlagsMaterialized = true
        nativeInspection?.materialized = motionElements
    }

    private func nativeInfoIndex(_ selector: String, count: Int) -> Int? {
        let infos = lastElements.prefix(count)
        if !selector.utf8.contains(0x2f), let exact = infos.firstIndex(where: { matchesAuthoredKey($0.key, selector) }) {
            return exact
        }
        return infos.firstIndex { selectsElementSelector(selector, path: $0.path, key: $0.key) }
    }

    /// Drawn `[x, y, w, h]` in points and effective opacity (ancestors included) of the element
    /// matching `key`, exiting or not, as of the last frame (`elements.rs:406`).
    public func presented(_ key: String) -> (rect: [Float], opacity: Float)? {
        if let nativeInspection {
            guard let index = nativeInfoIndex(key, count: nativeInspection.elementCount) else { return nil }
            let info = lastElements[index]
            return (info.rect, info.opacity)
        }
        let exact = key.utf8.contains(0x2f) ? nil : lastPoseNodes.first { matchesAuthoredKey($0.key, key) }
        guard let matched = exact ?? lastPoseNodes.first(where: {
            selectsElementSelector(key, path: $0.path, key: $0.key)
        }) else { return nil }
        return (matched.rect, matched.opacity)
    }

    /// The presented rotation, scale, and shadows of the element matching `key`, exiting or not,
    /// as of the last frame, and whether any spring or decorative loop still moves them (`elements.rs:497`).
    public func presentedPose(_ key: String) -> Pose? {
        if let snapshot = nativeInspection, !snapshot.materialized {
            guard let index = nativeInfoIndex(key, count: snapshot.elementCount) else { return nil }
            let node = lastElements[index]
            let raw = snapshot.rawPoseByPath[node.path]
            var moving = node.moving || raw?.ownMoving == true
            if !moving && snapshot.hasInheritedFlags {
                var visited: Set<Int> = []
                var cursor: Int? = index
                while let i = cursor, visited.insert(i).inserted {
                    let info = lastElements[i]
                    let own = snapshot.rawPoseByPath[info.path]
                    if info.moving || own?.ownMoving == true {
                        moving = true
                        break
                    }
                    cursor = info.parentIndex
                    if let anchor = own?.anchorKey, let target = lastElements.prefix(snapshot.elementCount).firstIndex(where: {
                        !$0.exiting && selectsElementSelector(anchor, path: $0.path, key: $0.key)
                    }) { cursor = target }
                }
            }
            return Pose(rotation: raw?.rotation ?? 0, scale: node.scale, shadows: raw?.shadows ?? [], moving: moving)
        }
        let matched: PoseNodeSnapshot?
        if !key.utf8.contains(0x2f) {
            matched = lastPoseNodes.first(where: { matchesAuthoredKey($0.key, key) })
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
        materializeNativeInspection()
        out.removeAll(keepingCapacity: true)
        out.append(contentsOf: lastMotionElements)
    }

    /// Convenience returning a new array of the last frame's `MotionElement`s.
    public func motionElements() -> [MotionElement] {
        materializeNativeInspection()
        return lastMotionElements
    }

    /// Returns `(path, key)` for the element with `id`, as `ElementInfo.path` and `ElementInfo.key` (`motion_elements.rs:156`).
    public func elementPath(_ id: NodeId) -> (path: String, key: String?)? {
        if let n = mountedNode(id) {
            return (n.path, n.key)
        }
        if let n = exitingSnapshots[id] {
            return (n.path, n.key)
        }
        materializeNativeInspection()
        if let p = lastPoseNodes.first(where: { $0.nodeId == id }) {
            return (p.path, p.key)
        }
        return nil
    }

    // MARK: - Font Families (`runtime/font_families.rs`) & Event Log (`runtime/event_log.rs`)

    /// Switches the sans and monospace slots for this window. Other windows on this thread
    /// take up the choice on their next frame (`Runtime::set_font_families`).
    public func setFontFamilies(_ sans: String, _ mono: String) {
        if textSystem.chooseWindowFontFamilies(sans: sans, mono: mono) {
            invalidateFontFamilyLayout(at: currentTime)
        }
    }

    internal func invalidateFontFamilyLayout(at now: Double) {
        memo.clear()
        retainedLayout = RetainedLayoutCoordinator()
        dirtyCommit(at: now)
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
