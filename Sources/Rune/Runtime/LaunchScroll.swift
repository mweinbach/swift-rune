import RuneMotion

/// A flight starts in the window coordinates of its source and acquires the scroll of
/// its destination as it lands. Re-aiming folds the outstanding scroll into the new path.
internal struct LaunchScroll {
    var origin: Vec2
    var last: Vec2
    var layoutTarget: MotionRect?
    var ancestorOrigins: [NodeId: Vec2] = [:]
    var folded = Vec2.zero
    var foldedAt = Vec2.zero

    init(_ origin: Vec2) {
        self.origin = origin
        last = origin
    }

    func correction(at current: Vec2, travel: Vec2) -> Vec2 {
        func axis(_ offset: Float, _ start: Float, _ previous: Float, _ at: Float, _ progress: Float) -> Float {
            let remaining = 1 - progress
            return (offset - start) * remaining + (at > 1e-4 ? previous * min(max(remaining / at, 0), 1) : 0)
        }
        return Vec2(
            axis(current.x, origin.x, folded.x, foldedAt.x, travel.x),
            axis(current.y, origin.y, folded.y, foldedAt.y, travel.y)
        )
    }

    mutating func fold(at travel: Vec2) {
        folded = correction(at: last, travel: travel)
        foldedAt = Vec2(1 - travel.x, 1 - travel.y)
        origin = last
    }
}

extension Runtime {
    internal func presentLaunchedRowHeights(in frame: inout FrameOutput) {
        guard !launchScrollById.isEmpty else { return }
        var heights: [NodeId: Float] = [:]
        for id in launchScrollById.keys {
            guard let node = mountedNode(id) else { continue }
            let key = node.el.foldGlideSpec != nil ? "fold:\(node.path)" : "growth:\(node.path)"
            if let entry = growthRows[key] { heights[id] = max(0, entry.track.h) }
        }
        guard !heights.isEmpty else { return }
        var changed = Set(frame.changed.map(\.id))
        for i in frame.nodes.indices {
            let id = frame.nodes[i].id
            guard let height = heights[id] else { continue }
            frame.nodes[i].rect.bottom = frame.nodes[i].rect.top + height
            frame.byId[id] = frame.nodes[i]
            if frame.nodes[i] != lastFrameOutput?.byId[id] { changed.insert(id) }
        }
        frame.changed = frame.nodes.filter { changed.contains($0.id) }
    }

    internal func foldLaunchScroll(_ id: NodeId) {
        guard let travel = scene.get(id, Props.TRAVEL) else { return }
        launchScrollById[id]?.fold(at: travel)
    }

    private func scrollInWindow(_ offset: Vec2, scale: Vec2, turn: Turn?) -> Vec2 {
        let x = offset.x * scale.x
        let y = offset.y * scale.y
        guard let turn else { return Vec2(x, y) }
        return Vec2(turn.a * x + turn.b * y, turn.c * x + turn.d * y)
    }

    internal func launchTakeoffScroll(for node: FlatNode, in nodes: [FlatNode]) -> Vec2 {
        var sum = Vec2.zero
        var parent = node.parentIndex
        while let i = parent {
            let ancestor = nodes[i]
            if !ancestor.el.layout.scrollAxes.isEmpty,
               let info = lastElements.first(where: { $0.path == ancestor.path && !$0.exiting }),
               info.scrolled.count == 2 {
                let v = scrollInWindow(Vec2(info.scrolled[0], info.scrolled[1]),
                                       scale: presentedScaleByPath[ancestor.path] ?? Vec2(1, 1),
                                       turn: hitGeometryByPath[ancestor.path]?.turn)
                sum.x += v.x
                sum.y += v.y
            }
            parent = ancestor.parentIndex
        }
        return sum
    }

    internal func makeCarriedScrollCache() -> [Vec2?] {
        guard !scrollOffsets.isEmpty, launchScrollById.isEmpty, !hasActiveExitingNodes else { return [] }
        // A stale offset can outlive the element which introduced its scrolling axes.
        // Preserve its ancestry semantics until the next commit clears it.
        for path in scrollOffsets.keys {
            guard let i = nodeByPath[path], !flatNodes[i].el.layout.scrollAxes.isEmpty else { return [] }
        }
        return Array(repeating: nil, count: flatNodes.count)
    }

    internal func carriedScroll(for node: FlatNode, scales: [String: Vec2], cache: inout [Vec2?],
                                turn: (String) -> Turn?) -> Vec2 {
        // Descendants of the same nearest scroll viewport have the same inner-to-outer sum,
        // including the presentation scale and turn of every enclosing viewport.
        if !cache.isEmpty, flatNodes.indices.contains(node.index), flatNodes[node.index].nodeId == node.nodeId {
            guard let viewport = node.enclosingScrollIndex else { return .zero }
            if let value = cache[viewport] { return value }
            let value = uncachedCarriedScroll(for: node, scales: scales, turn: turn)
            // Raised or reparented content can precede the authored scroll ancestors in
            // presentation order. Their scales and turns become available during this paint.
            var ancestor: Int? = viewport
            while let i = ancestor {
                guard scales[flatNodes[i].path] != nil else { return value }
                ancestor = flatNodes[i].enclosingScrollIndex
            }
            cache[viewport] = value
            return value
        }
        return uncachedCarriedScroll(for: node, scales: scales, turn: turn)
    }

    private func uncachedCarriedScroll(for node: FlatNode, scales: [String: Vec2], turn: (String) -> Turn?) -> Vec2 {
        let hasLaunches = !launchScrollById.isEmpty
        guard hasLaunches || !scrollOffsets.isEmpty else { return .zero }
        var sum = Vec2.zero
        var launches: [(id: NodeId, inner: Vec2)] = []
        var current: FlatNode? = node
        while let item = current {
            if item.nodeId != node.nodeId, var offset = scrollOffsets[item.path] {
                offset.y += slice2State.scrollExtraYByPath[item.path] ?? 0
                let v = scrollInWindow(offset, scale: scales[item.path] ?? Vec2(1, 1), turn: turn(item.path))
                sum.x += v.x
                sum.y += v.y
            }
            if hasLaunches, launchScrollById[item.nodeId] != nil {
                launches.append((item.nodeId, sum))
            }
            current = item.parentIndex.flatMap { flatNodes.indices.contains($0) ? flatNodes[$0] : nil }
        }
        var carried = sum
        for (id, inner) in launches {
            guard let travel = scene.get(id, Props.TRAVEL), var launch = launchScrollById[id] else { continue }
            launch.last = Vec2(sum.x - inner.x, sum.y - inner.y)
            let fix = launch.correction(at: launch.last, travel: travel)
            carried.x -= fix.x
            carried.y -= fix.y
            launchScrollById[id] = launch
        }
        return carried
    }
}
