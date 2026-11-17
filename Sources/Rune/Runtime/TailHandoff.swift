import RuneMotion

/// Presentation deltas at the edge a virtual list shares with a panel giving it room.
internal struct TailHandoff: Sendable {
    struct Frame: Sendable {
        var id: NodeId
        var target: MotionRect
        var dy: Float
        var dh: Float
    }

    struct Row: Sendable {
        var growthKey: String
        var from: Float
        var to: Float
    }

    var incomingKey: String
    var viewportPath: String
    var frames: [Frame]
    var rows: [Row]

    func progress(in growth: [String: RuntimeGrowthEntry]) -> (left: Float, rate: Float) {
        guard let track = growth[incomingKey]?.track, track.target > 0 else { return (0, 0) }
        return (min(1, max(0, 1 - track.h / track.target)), track.v / track.target)
    }
}

extension Runtime {
    /// Called while measuring the unconstrained tree, before the new layout replaces the old scene.
    internal func stageTailHandoff(
        nodes: [LiveTailLayoutNode<State>], stack: Int, viewport: Int, row: String, panel: String
    ) -> Bool {
        guard let panelIndex = nodes.firstIndex(where: {
            selectsElementSelector(panel, path: $0.path, key: $0.el.keyId)
        }) else { return false }
        let panelNode = nodes[panelIndex]
        let view = nodes[viewport]
        guard let oldView = mountedNode(view.nodeId)?.targetRect,
              let oldPanel = mountedNode(panelNode.nodeId)?.targetRect else { return false }
        let panelTarget = panelNode.targetRect
        let viewTarget = view.targetRect
        func close(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 1.0 / 64.0 }
        guard panelTarget.top > oldPanel.top,
              close(oldView.bottom, oldPanel.top), close(viewTarget.bottom, panelTarget.top),
              close(oldPanel.bottom, panelTarget.bottom),
              oldView.left == viewTarget.left, oldView.top == viewTarget.top, oldView.right == viewTarget.right,
              let arrival = nodes.first(where: { $0.parentIndex == stack && $0.el.keyId == row }),
              !scene.contains(arrival.nodeId) else { return false }

        func growthKey(_ node: LiveTailLayoutNode<State>) -> String {
            (node.el.foldGlideSpec == nil ? "growth:" : "fold:") + node.path
        }
        var ancestors = Set<Int>()
        for start in [viewport, panelIndex] {
            var cursor: Int? = start
            while let index = cursor, ancestors.insert(index).inserted {
                cursor = nodes[index].parentIndex
            }
        }
        var panelEnd = panelIndex + 1
        while panelEnd < nodes.count, let parent = nodes[panelEnd].parentIndex, parent >= panelIndex {
            panelEnd += 1
        }
        var frames: [TailHandoff.Frame] = []
        var rows: [TailHandoff.Row] = []
        for (index, node) in nodes.enumerated() {
            let fixedSibling = node.parentIndex == panelNode.parentIndex && mountedNode(node.nodeId)?.targetRect == node.targetRect
            if ancestors.contains(index) || (panelIndex..<panelEnd).contains(index) || fixedSibling,
               let old = scene.get(node.nodeId, Props.FRAME) {
                let dy = old.y - node.localRect.y
                let dh = old.height - node.localRect.height
                if dy != 0 || dh != 0 {
                    frames.append(.init(id: node.nodeId, target: node.localRect, dy: dy, dh: dh))
                }
            }
            if node.parentIndex == stack, node.nodeId != arrival.nodeId, node.el.isArrivesWhole, !node.el.isStreaming,
               let from = growthRows[growthKey(node)]?.track.h, from != node.localRect.height {
                rows.append(.init(growthKey: growthKey(node), from: from, to: node.localRect.height))
            }
        }
        guard growthStacks[nodes[stack].path] != nil else { return false }
        growthStacks[nodes[stack].path]?.tailHandoff = TailHandoff(
            incomingKey: growthKey(arrival), viewportPath: view.path, frames: frames, rows: rows
        )
        return true
    }

    /// Whole rows losing a footer share the incoming spring's fraction and rate before layout.
    internal func placeTailHandoffRows() {
        for stack in growthStacks.values {
            guard let handoff = stack.tailHandoff, !handoff.rows.isEmpty else { continue }
            let (left, rate) = handoff.progress(in: growthRows)
            for row in handoff.rows {
                guard var entry = growthRows[row.growthKey], entry.track.target == row.to else { continue }
                entry.track.h = row.to + (row.from - row.to) * left
                entry.track.v = (row.to - row.from) * rate
                growthRows[row.growthKey] = entry
            }
        }
    }

    /// Apply the same fraction to both sides of the seam before Scene produces this frame.
    internal func placeTailHandoffFrames() {
        for (path, stack) in growthStacks {
            guard let handoff = stack.tailHandoff else { continue }
            let left = handoff.progress(in: growthRows).left
            for frame in handoff.frames {
                guard let current = mountedNode(frame.id)?.localRect,
                      current.y == frame.target.y, current.height == frame.target.height else { continue }
                scene.set(frame.id, Props.FRAME, MotionRect.fromXYWH(
                    current.x, current.y + frame.dy * left, current.width, current.height + frame.dh * left
                ))
            }
            // Growing the row already accounts for this space in the pinned viewport.
            if slice2State.scrollSlacks[handoff.viewportPath] != nil {
                slice2State.scrollSlacks[handoff.viewportPath]?.follow = true
            }
            if left == 0 { growthStacks[path]?.tailHandoff = nil }
        }
    }
}
