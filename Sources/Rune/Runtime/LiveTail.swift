import RuneMotion

/// Requests are scoped to one commit. Covered polls may contribute the same stack repeatedly.
internal struct LiveTailRequests {
    var inkByStack: [String: Bool] = [:]
    var rooms: [(stack: String, row: String, panel: String)] = []

    mutating func request(_ stack: String, ink: Bool) {
        inkByStack[stack] = ink || inkByStack[stack] == true
    }

    mutating func merge(_ other: Self) {
        for (stack, ink) in other.inkByStack { request(stack, ink: ink) }
        rooms.append(contentsOf: other.rooms)
    }
}

public extension Tx {
    /// Animate a live arrival at the pinned end of this virtual growth stack.
    mutating func growVisibleTail(_ stack: String) { liveTail.request(stack, ink: false) }

    /// Let visible rows crossing each other carry their paint and child exits with them.
    mutating func growVisibleTailWithInk(_ stack: String) { liveTail.request(stack, ink: true) }

    /// Move the common edge of the viewport and the named panel with a newly delivered row.
    mutating func growVisibleTailFrom(_ stack: String, row: String, panel: String) {
        growVisibleTail(stack)
        liveTail.rooms.append((stack, row, panel))
    }
}

internal struct LiveTailWindow {
    let visibleKeys: Set<String>
    let drawnKeys: Set<String>
    let quietMounts: Set<String>
    let ink: Bool
}

internal struct LiveTailLayoutNode<State> {
    let el: El<State>
    let path: String
    let parentIndex: Int?
    let localRect: MotionRect
    let targetRect: MotionRect
    let nodeId: NodeId
    let instant: Bool
}

extension Runtime {
    /// The first layout has natural row heights and the new panel/viewport edges. Inspect it
    /// before growth clamps it; the last frame still supplies the actual on-screen row faces.
    internal func prepareLiveTails(
        root: El<State>, solved: LayoutEngine.ResultNode, expansion: VirtualExpansionContext,
        previousLists: [String: RuntimeVirtualListState], now: Double
    ) {
        slice2State.liveTailWindows.removeAll(keepingCapacity: true)
        let requests = slice2State.activeLiveTail
        guard !previousLists.isEmpty, !expansion.listMeta.isEmpty else { return }
        var nodes: [LiveTailLayoutNode<State>] = []
        var byPath: [String: Int] = [:]
        typealias Item = (el: El<State>, result: LayoutEngine.ResultNode, path: String, parent: Int?, key: String?)
        var pending: [Item] = [(root, solved, root.keyId.map { "/@\($0)" } ?? "/0", nil, root.keyId)]
        while let item = pending.popLast() {
            let index = nodes.count
            let parent = item.parent.map { nodes[$0] }
            let local = item.result.layout.localRect
            let rect = local.translated(Vec2(parent?.targetRect.x ?? 0, parent?.targetRect.y ?? 0))
            let id = item.el.layoutAnim?.travel == .screen ? item.key.map { NodeId.hash("screen:@" + $0) } : nil
            nodes.append(.init(el: item.el, path: item.path, parentIndex: item.parent, localRect: local,
                               targetRect: rect, nodeId: id ?? NodeId.hash(item.path),
                               instant: item.el.hasInstantChanges || parent?.instant == true))
            byPath[item.path] = index
            var siblings: [String: Int] = [:]
            var children: [Item] = []
            for i in 0..<min(item.el.children.count, item.result.children.count) {
                let child = item.el.children[i]
                let (segment, key) = layoutPathSegment(keyId: child.keyId, siblingIndex: i, siblingKeysSeen: &siblings)
                children.append((child, item.result.children[i], item.path + "/" + segment, index, key))
            }
            pending.append(contentsOf: children.reversed())
        }

        for meta in expansion.listMeta {
            guard let i = byPath[meta.listPath], let p = byPath[meta.scrollPath], nodes[i].parentIndex == p,
                  !nodes[i].instant, let prior = previousLists[meta.listPath], let list = virtualLists[meta.listPath],
                  !list.nested, meta.stickBottom, wasPinnedToBottom.contains(meta.scrollPath),
                  let oldStack = growthStacks[meta.listPath], let oldIndex = nodeByPath[meta.listPath],
                  let oldView = nodeByPath[meta.scrollPath].map({ flatNodes[$0] }),
                  let oldViewRect = drawnRectByPath[meta.scrollPath],
                  abs(oldStack.width - nodes[i].localRect.width) <= 0.25, !oldStack.widthHold.defers(at: now)
            else { continue }
            let stack = nodes[i]
            let matches: (String) -> Bool = { selectsElementSelector($0, path: stack.path, key: stack.el.keyId) }
            let selectors = requests.inkByStack.keys.filter(matches)
            guard !selectors.isEmpty else { continue }
            let restOfViewport = nodes[(i + 1)...].prefix { ($0.parentIndex ?? -1) >= p }
            guard !restOfViewport.contains(where: { $0.parentIndex == p && $0.targetRect.bottom > stack.targetRect.bottom })
            else { continue }

            var drawn: Set<String> = []
            for n in flatNodes where n.parentIndex == oldIndex {
                guard let key = n.key, let r = drawnRectByPath[n.path], r.height > 0,
                      r.bottom > oldViewRect.top, r.top < oldViewRect.bottom else { continue }
                drawn.insert(key)
            }
            // A pinned list keeps its view when any key survives, including a key above
            // the viewport. Most deliveries keep a drawn row and need no full key scan.
            guard !drawn.isEmpty,
                  drawn.contains(where: { list.rowPlaces.index(of: $0) != nil }) ||
                    prior.lastKeys.contains(where: { list.rowPlaces.index(of: $0) != nil }) else { continue }
            let viewportHeight = nodes[p].localRect.height
            var space = viewportHeight - list.padBottom
            var visible: Set<String> = []
            let gap = virtualGapY(stack.el.layout)
            for key in list.lastKeys.reversed() {
                if space <= 0 { break }
                let h = list.rowHeight(forKey: key, estimated: meta.estimate)
                if h > 0 { visible.insert(key) }
                space -= h + gap
            }
            if abs(viewportHeight - oldView.targetRect.height) >= 1 / 64 {
                guard let room = requests.rooms.last(where: { matches($0.stack) }),
                      visible.contains(room.row), prior.rowPlaces.index(of: room.row) == nil,
                      stageTailHandoff(nodes: nodes, stack: i, viewport: p, row: room.row, panel: room.panel)
                else { continue }
            }
            let mounted = Set(prior.lastMountedSnapshot?.mountedKeys ?? [])
            slice2State.liveTailWindows[stack.path] = LiveTailWindow(
                visibleKeys: visible, drawnKeys: drawn,
                quietMounts: visible.filter { prior.rowPlaces.index(of: $0) != nil && !mounted.contains($0) },
                ink: selectors.contains { requests.inkByStack[$0] == true }
            )
        }
    }
}

extension Runtime {
    /// Carry changes only inside previously drawn rows that cross, resize, or touch a crossing.
    func carryLiveTailInk(
        window: LiveTailWindow, rows: [Int], reorder: VirtualRowReorder,
        nodes: [FlatNode], specs: inout [NodeSpec]
    ) -> [ReorderedRowSlide] {
        var springs: [ReorderedRowSlide] = []
        for (ordinal, i) in rows.enumerated() {
            let row = nodes[i]
            guard let key = row.key, window.drawnKeys.contains(key), window.visibleKeys.contains(key) else { continue }
            let crosses = reorder.jump(for: row.nodeId) != 0
            let growth = growthRows[(row.el.foldGlideSpec == nil ? "growth:" : "fold:") + row.path]
            let shifts = crosses || (window.ink && growth?.track.moving == true)
            let joins = window.ink && [ordinal - 1, ordinal + 1].contains { neighbor in
                rows.indices.contains(neighbor) && reorder.jump(for: nodes[rows[neighbor]].nodeId) != 0
            }
            guard shifts || joins else { continue }
            var insetByParent: [Int: Float] = [:]
            var instantNodes: Set<Int> = []
            var springByNode: [Int: Spring] = [:]
            for j in i..<nodes.count {
                let node = nodes[j]
                guard j == i || (node.parentIndex ?? -1) >= i else { break }
                let el = node.el
                let parent = node.parentIndex
                if el.hasInstantChanges || (!el.hasAnimatedChanges && parent.map(instantNodes.contains) == true) {
                    instantNodes.insert(j)
                    continue
                }
                let spring = el.styleSpring ?? parent.flatMap { springByNode[$0] } ?? MotionTokens.DEFAULT
                springByNode[j] = spring
                let rides = window.ink && crosses
                if rides {
                    specs[j].styleSpring = spring
                    specs[j].colorSpring = spring
                    specs[j].paintSpring = spring
                    specs[j].opacityAnim = el.opacityMotionAnim ?? el.kitOpacityAnim
                    specs[j].offsetAnim = el.offsetMotionAnim
                    specs[j].rotateAnim = el.rotateMotionAnim
                    specs[j].scaleAnim = el.scaleMotionAnim
                    specs[j].animateOffset = true
                    if el.childExitTransition != nil { slice2State.liveTailExitParents.insert(node.nodeId) }
                } else if joins {
                    specs[j].cornerSpring = spring
                }

                guard shifts, j != i, let parent, !activeFlightIds.contains(node.nodeId),
                      !launchedFlightIds.contains(node.nodeId), scene.hasNode(node.nodeId) else { continue }
                if j == parent + 1, let old = scene.get(node.nodeId, Props.FRAME) {
                    let dy = old.y - node.localRect.y
                    if abs(dy) > 1.0 / 64.0 { insetByParent[parent] = dy }
                }
                guard let inset = insetByParent[parent] else { continue }
                let remaining = growth.map {
                    slice2State.liveContentSlides.follow(node: node.nodeId, row: row.nodeId, growth: $0.track, dy: inset)
                } ?? inset
                if abs(remaining) > 1.0 / 64.0 {
                    springs.append(ReorderedRowSlide(id: node.nodeId, jump: remaining, targetOffset: specs[j].offset,
                                                     spring: spring, prevOff: scene.get(node.nodeId, Props.OFFSET) ?? .zero,
                                                     prevVel: scene.store.velocity(node.nodeId, Props.OFFSET)))
                }
            }
        }
        return springs
    }
}
