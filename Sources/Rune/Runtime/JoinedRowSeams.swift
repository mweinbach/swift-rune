import RuneMotion

extension El {
    /// Names the visible face of a complete growth row. During a live reorder,
    /// consecutive faces travel together until the row between them reaches the seam.
    public func joinedRowFace(_ key: String) -> Self {
        var result = self
        result.joinedRowFaceKey = key
        return result
    }
}

/// Remembers an authored edge fade beneath a temporary growth reveal.
struct GrowthReveal: Sendable {
    var authoredClip: Bool
    var authoredFade: SIMD4<Float>?
}

struct JoinedRowSeam {
    struct Face {
        var row: NodeId
        var ink: NodeId
        var height: Float
    }

    enum Boundary {
        case joined(rawFrom: Float)
        case opening(between: NodeId)
    }

    var top: Face
    var bottom: Face
    var from: Float
    var raw: Float
    var boundary: Boundary
}

extension Runtime {
    func updateJoinedRowSeams(
        stack: FlatNode, nodes: [FlatNode], rows: [Int], oldOrder: [NodeId],
        reorder: VirtualRowReorder, reset: Bool
    ) {
        if reset {
            slice2State.joinedRowSeams.removeValue(forKey: stack.nodeId)
        }
        guard oldOrder != rows.map({ nodes[$0].nodeId }) else { return }
        let oldSeams = slice2State.joinedRowSeams.removeValue(forKey: stack.nodeId) ?? []
        guard !reset, let window = slice2State.liveTailWindows[stack.path],
              !reorder.jumps.isEmpty || !oldSeams.isEmpty else { return }

        var seams: [JoinedRowSeam] = []
        var previous: (offset: Int, face: JoinedRowSeam.Face, edge: Float)?
        for (offset, i) in rows.enumerated() {
            let row = nodes[i]
            guard let key = row.el.joinedRowFaceKey else { continue }
            let faceIndex = nodes.indices[i...]
                .prefix(while: { $0 == i || (nodes[$0].parentIndex ?? -1) >= i })
                .first { nodes[$0].path == key || selectsElementSelector(key, path: nodes[$0].path, key: nodes[$0].key) }
            guard row.el.isArrivesWhole, !row.el.isStreaming, !row.el.hasInstantChanges,
                  let rowKey = row.key, window.visibleKeys.contains(rowKey), window.drawnKeys.contains(rowKey),
                  let j = faceIndex,
                  let drawn = drawnRectByPath[nodes[j].path],
                  drawn.height > 0, abs(drawn.height - nodes[j].localRect.height) < 0.1 else {
                previous = nil
                continue
            }
            let face = JoinedRowSeam.Face(row: row.nodeId, ink: nodes[j].nodeId, height: nodes[j].localRect.height)
            defer { previous = (offset, face, drawn.bottom) }
            guard let previous else { continue }
            let top = previous.face
            let joined = previous.offset + 1 == offset
            let wasJoined = zip(oldOrder, oldOrder.dropFirst()).contains { $0 == top.row && $1 == face.row }
            let retained = oldSeams.first { $0.top.row == top.row && $0.bottom.row == face.row }
            guard joined || wasJoined || retained != nil,
                  retained != nil || reorder.jump(for: top.row) != 0 || reorder.jump(for: face.row) != 0 else { continue }

            let from = drawn.top - previous.edge
            let raw = retained?.raw ?? from
            let boundary: JoinedRowSeam.Boundary = joined
                ? .joined(rawFrom: raw) : .opening(between: nodes[rows[previous.offset + 1]].nodeId)
            seams.append(JoinedRowSeam(top: top, bottom: face, from: from, raw: raw, boundary: boundary))
        }
        if !seams.isEmpty { slice2State.joinedRowSeams[stack.nodeId] = seams }
    }

    /// Adjusts the world-space frame shared by hit testing, inspection, and both paint paths.
    /// Adjust trailing faces first so a run shares one seam through all its rows.
    func placeJoinedRows(in frame: inout FrameOutput) {
        slice2State.joinedRowsWithoutRevealMask.removeAll(keepingCapacity: true)
        guard !slice2State.joinedRowSeams.isEmpty else { return }
        var offsets: [NodeId: Float] = [:]
        for (stackID, var seams) in slice2State.joinedRowSeams {
            guard let stack = nodeById[stackID] else {
                slice2State.joinedRowSeams.removeValue(forKey: stackID)
                continue
            }
            var moving = false
            for index in seams.indices.reversed() {
                let seam = seams[index]
                guard let a = nodeById[seam.top.ink], let b = nodeById[seam.bottom.ink],
                      a.localRect.height == seam.top.height, b.localRect.height == seam.bottom.height,
                      let upper = frame.byId[a.nodeId]?.rect, let lower = frame.byId[b.nodeId]?.rect else { continue }
                let end = upper.top + (offsets[seam.top.row] ?? 0) + a.localRect.height
                let raw = lower.top + (offsets[seam.bottom.row] ?? 0) - end
                let goal = b.targetRect.top - a.targetRect.bottom
                let want: Float
                switch seam.boundary {
                case let .joined(rawFrom):
                    let left = abs(rawFrom - goal) < 0.01 ? 0 : min(1, max(0, (raw - goal) / (rawFrom - goal)))
                    want = goal + (seam.from - goal) * left
                case let .opening(between):
                    guard let k = nodeById[between], let rect = frame.byId[between]?.rect else { continue }
                    let depth = k.targetRect.bottom - a.targetRect.bottom
                    let t = min(1, max(0, (rect.bottom + (offsets[between] ?? 0) - end) / max(1, depth)))
                    want = seam.from + (raw - seam.from) * t * t * (3 - 2 * t)
                }
                seams[index].raw = raw
                offsets[seam.top.row, default: 0] += raw - want
                for id in [seam.top.row, seam.bottom.row] {
                    guard let row = nodeById[id] else { continue }
                    let track = growthRows["growth:\(row.path)"]?.track
                    if track?.whole == true && track?.linearEdge == true {
                        slice2State.joinedRowsWithoutRevealMask.insert(id)
                    }
                    moving = moving || scene.store.isAnimating(id, Props.OFFSET) || track?.moving == true
                }
            }
            if moving || growthStacks[stack.path]?.runs.isEmpty == false {
                slice2State.joinedRowSeams[stackID] = seams
            } else {
                slice2State.joinedRowSeams.removeValue(forKey: stackID)
            }
        }

        applyRowShifts(offsets, in: &frame)
    }

    /// Offsets are local to a row; the scene publishes world coordinates for every descendant.
    func applyRowShifts(_ rowOffsets: [NodeId: Float], in frame: inout FrameOutput) {
        guard !rowOffsets.isEmpty else { return }
        var offsets = rowOffsets
        var changedIDs = Set(frame.changed.map(\.id))
        for i in frame.nodes.indices {
            var node = frame.nodes[i]
            let dy = (offsets[node.id] ?? 0) + (node.parent.flatMap { offsets[$0] } ?? 0)
            if dy == 0 {
                offsets.removeValue(forKey: node.id)
                continue
            }
            offsets[node.id] = dy
            let delta = Vec2(0, dy)
            node.rect = node.rect.offsetBy(delta)
            node.revealClip = node.revealClip?.offsetBy(delta)
            frame.nodes[i] = node
            frame.byId[node.id] = node
            if lastFrameOutput?.byId[node.id] != node { changedIDs.insert(node.id) }
        }
        if !changedIDs.isEmpty {
            frame.changed = frame.nodes.filter { changedIDs.contains($0.id) }
        }
    }
}
