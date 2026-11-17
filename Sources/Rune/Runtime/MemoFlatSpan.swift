import RuneMotion

/// Inputs consumed by descendant motion specs and text elision during flattening.
struct FlatMemoFrame: Equatable {
    let commit: TxCommit
    let cut: Bool
    let motion: MotionSource?
    let colorSpring: Spring?
    let reducedMotion: Bool
    let scale: Float
    let fontEpoch: UInt64
    let language: String?
    let smoothing: FontSmoothing
}

struct FlatMemoContext: Equatable {
    let frame: FlatMemoFrame
    let flow: Flow
    let directed: Bool
    let inert: Bool
    let z: Int
    let instant: Bool
    let row: ParityRowLayout
    let underFold: Bool
    let styleSpring: Spring?
}

struct FlatMemoCapture<State> {
    let owner: FlatMemoPaths<State>
    let root: Int
    let children: [LayoutEngine.ResultNode]
    let context: FlatMemoContext
}

/// One memo root's already flattened descendants. Root modifiers always run on the current
/// pass. Row positions, viewport clips, indices and enclosing scroll views can change.
struct MemoFlatSpan<State> {
    typealias Node = Runtime<State>.FlatNode
    let context: FlatMemoContext
    let children: [LayoutEngine.ResultNode]
    let rootIndex: Int
    let worldOrigin: Vec2
    let unscrolledOrigin: Vec2
    let committedOrigin: Vec2
    let nodes: [Node]
    let specs: [NodeSpec]
    let instants: [Bool]
    let clipsChildren: [Bool]

    init?(_ capture: FlatMemoCapture<State>, flat: [Node], specs: [NodeSpec], instants: [Bool],
          stable: (NodeId) -> Bool) {
        let start = capture.root + 1
        var end = start
        var clips: [Bool] = []
        while end < flat.count, let parent = flat[end].parentIndex, parent >= capture.root {
            let node = flat[end]
            let el = node.el
            // These elements have independent mutable state, side effects, or their own
            // coordinate system. Re-evaluate them through the ordinary flatten path.
            guard el.anchor == nil, el.layout.scrollAxes.isEmpty,
                  el.scale == Vec2(1, 1), el.offset == .zero, el.rotate == 0,
                  el.loopingSpec == nil, el.clipFade == nil, el.pressBg == nil,
                  el.flightId == nil, el.layoutAnim?.travel != .screen,
                  el.growthSpec == nil, el.foldGlideSpec == nil, el.virtualEstimate == nil else {
                capture.owner.allowsSpan = false
                return nil
            }
            guard stable(node.nodeId) else { return nil }
            clips.append(el.layout.clipOverflow || el.clipRadius != nil || el.clipCorners != nil)
            end += 1
        }
        guard end > start else { return nil }
        self.context = capture.context
        self.children = capture.children
        rootIndex = capture.root
        let parent = flat[capture.root]
        worldOrigin = parent.targetRect.origin
        unscrolledOrigin = parent.unscrolledRect.origin
        committedOrigin = parent.committedLayoutTarget.origin
        self.nodes = Array(flat[start..<end])
        self.specs = Array(specs[start..<end])
        self.instants = Array(instants[start..<end])
        clipsChildren = clips
    }

    private static func sameBuffer<T>(_ a: [T], _ b: [T]) -> Bool {
        a.count == b.count && a.withUnsafeBufferPointer { x in
            b.withUnsafeBufferPointer { x.baseAddress == $0.baseAddress }
        }
    }

    static func equalLayouts(_ lhs: [LayoutEngine.ResultNode], _ rhs: [LayoutEngine.ResultNode]) -> Bool {
        if sameBuffer(lhs, rhs) { return true }
        var pending = [(lhs, rhs)]
        while let (a, b) = pending.popLast() {
            guard a.count == b.count else { return false }
            for i in a.indices {
                guard a[i].layout == b[i].layout else { return false }
                if !sameBuffer(a[i].children, b[i].children) { pending.append((a[i].children, b[i].children)) }
            }
        }
        return true
    }

    func append(to flat: inout [Node], byPath: inout [String: Int], byId: inout [NodeId: Int],
                specs currentSpecs: inout [NodeSpec], instants currentInstants: inout [Bool],
                root: Int, clip: MotionRect, fades: [EdgeFadeSpec],
                enclosing: Int?, vertical: Int?, horizontal: Int?) {
        let shift = root - rootIndex
        let parent = flat[root]
        let first = nodes[0]
        if shift == 0, parent.targetRect.origin == worldOrigin,
           parent.unscrolledRect.origin == unscrolledOrigin, parent.committedLayoutTarget.origin == committedOrigin,
           first.clipRect == clip, Self.sameBuffer(fades, first.activeClipFades),
           first.enclosingScrollIndex == enclosing, first.enclosingVScrollIndex == vertical,
           first.enclosingHScrollIndex == horizontal {
            flat.append(contentsOf: nodes)
            currentSpecs.append(contentsOf: specs)
            currentInstants.append(contentsOf: instants)
            for node in nodes {
                byPath[node.path] = node.index
                byId[node.nodeId] = node.index
            }
            return
        }
        for i in nodes.indices {
            var node = nodes[i]
            let parentIndex = node.parentIndex! + shift
            let parent = flat[parentIndex]
            let local = node.localRect
            let target = MotionRect.fromXYWH(parent.targetRect.x + local.x, parent.targetRect.y + local.y,
                                               local.width, local.height)
            let unscrolled = MotionRect.fromXYWH(parent.unscrolledRect.x + local.x, parent.unscrolledRect.y + local.y,
                                                  local.width, local.height)
            node.index += shift
            node.parentIndex = parentIndex
            node.targetRect = target
            node.zoomedTargetRect = target
            node.committedLayoutTarget = local.translated(parent.committedLayoutTarget.origin)
            node.unscrolledRect = unscrolled
            node.staticBounds = SIMD4(unscrolled.x, unscrolled.y, unscrolled.width, unscrolled.height)
            if parentIndex == root { node.clipRect = clip }
            else if clipsChildren[parentIndex - root - 1] { node.clipRect = intersectRects(parent.clipRect, parent.targetRect) }
            else { node.clipRect = parent.clipRect }
            node.activeClipFades = fades
            node.enclosingScrollIndex = enclosing
            node.enclosingVScrollIndex = vertical
            node.enclosingHScrollIndex = horizontal
            flat.append(node)
            byPath[node.path] = node.index
            byId[node.nodeId] = node.index
            var spec = specs[i]
            spec.rect = target
            currentSpecs.append(spec)
        }
        currentInstants.append(contentsOf: instants)
    }
}
