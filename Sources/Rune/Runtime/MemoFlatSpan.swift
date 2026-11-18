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

/// The authored root of an indexed virtual row can remain identical while its position,
/// clip and mount index change. Other memo roots may have new modifiers every frame.
final class MemoFlatRowRoot<State> {
    weak var source: Runtime<State>.CachedVirtualRow?
    let inherited: FlatMemoContext
    let childContext: FlatMemoContext
    let node: Runtime<State>.FlatNode
    let motion: NodeSpec
    let instant: Bool
    let clipsChildren: Bool

    init(source: Runtime<State>.CachedVirtualRow, inherited: FlatMemoContext, childContext: FlatMemoContext,
         node: Runtime<State>.FlatNode, motion: NodeSpec, instant: Bool) {
        self.source = source
        self.inherited = inherited
        self.childContext = childContext
        // A root element normally borrows its virtual list's entire sibling buffer.
        // Keep just the resolved element after the window advances.
        var snapshot = node
        snapshot.element.detachFromSiblings()
        self.node = snapshot
        self.motion = motion
        self.instant = instant
        let el = node.el
        clipsChildren = el.layout.clipOverflow || el.clipRadius != nil || el.clipCorners != nil
    }

    func append(to flat: inout [Runtime<State>.FlatNode], specs: inout [NodeSpec], instants: inout [Bool],
                parent: Int, localRect: MotionRect, origin: Vec2, unscrolled: Vec2, clip: MotionRect,
                fades: [EdgeFadeSpec], enclosing: Int?, vertical: Int?, horizontal: Int?) -> MotionRect {
        var current = node
        current.index = flat.count
        current.parentIndex = parent
        current.localRect = localRect
        current.targetRect = .fromXYWH(origin.x + localRect.x, origin.y + localRect.y, localRect.width, localRect.height)
        current.zoomedTargetRect = current.targetRect
        current.unscrolledRect = .fromXYWH(unscrolled.x + localRect.x, unscrolled.y + localRect.y, localRect.width, localRect.height)
        current.committedLayoutTarget = localRect.translated(flat[parent].committedLayoutTarget.origin)
        let bounds = current.unscrolledRect
        current.staticBounds = SIMD4(bounds.x, bounds.y, bounds.width, bounds.height)
        current.clipRect = clip
        current.activeClipFades = fades
        current.enclosingScrollIndex = enclosing
        current.enclosingVScrollIndex = vertical
        current.enclosingHScrollIndex = horizontal
        var spec = motion
        spec.rect = current.targetRect
        flat.append(current)
        specs.append(spec)
        instants.append(instant)
        return clipsChildren ? intersectRects(clip, current.targetRect) : clip
    }
}

/// One memo root's already flattened descendants. Root modifiers always run on the current
/// pass. Row positions, viewport clips, indices and enclosing scroll views can change.
final class MemoFlatSpan<State> {
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
    let matchesCaptureSpecs: Bool
    let clipsChildren: [Bool]
    // A retry or settle pass can measure a span without installing it in the runtime.
    // Only the commit that swapped in these nodes may certify their previous indices.
    private var appliedGeneration: UInt64?
    private var appliedStart = 0

    func markApplied(start: Int, generation: UInt64) {
        appliedStart = start
        appliedGeneration = generation
    }

    func appliedRange(at generation: UInt64) -> Range<Int>? {
        guard appliedGeneration == generation else { return nil }
        return appliedStart..<(appliedStart + nodes.count)
    }

    init?(_ capture: FlatMemoCapture<State>, flat: [Node], specs: [NodeSpec], instants: [Bool],
          mountedScales: [Int: Anim<Vec2>?], stable: (NodeId) -> Bool) {
        let start = capture.root + 1
        var end = start
        var clips: [Bool] = []
        var hasFreshMount = false
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
            if mountedScales.index(forKey: end) != nil {
                hasFreshMount = true
            } else if !stable(node.nodeId) { return nil }
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
        var changedSpec = false
        var replaySpecs = Array(specs[start..<end])
        if hasFreshMount {
            for i in replaySpecs.indices {
                if let scale = mountedScales[start + i],
                   replaySpecs[i].scaleAnim != scale || replaySpecs[i].enterDelay != 0 {
                    changedSpec = true
                    replaySpecs[i].scaleAnim = scale
                    replaySpecs[i].enterDelay = 0
                }
            }
        }
        matchesCaptureSpecs = !changedSpec
        self.specs = replaySpecs
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
        let moved = flat[root].targetRect.origin != worldOrigin
        let movedUnscrolled = flat[root].unscrolledRect.origin != unscrolledOrigin
        let movedCommitted = flat[root].committedLayoutTarget.origin != committedOrigin
        let inheritedClipChanged = nodes[0].clipRect != clip
        let fadesChanged = !Self.sameBuffer(fades, nodes[0].activeClipFades) && fades != nodes[0].activeClipFades
        let viewportChanged = enclosing != nodes[0].enclosingScrollIndex
            || vertical != nodes[0].enclosingVScrollIndex || horizontal != nodes[0].enclosingHScrollIndex
        let scrollMembershipChanged = (enclosing == nil) != (nodes[0].enclosingScrollIndex == nil)
        let start = flat.count
        flat.append(contentsOf: nodes)
        currentSpecs.append(contentsOf: specs)
        currentInstants.append(contentsOf: instants)
        if shift == 0 && !moved && !movedUnscrolled && !movedCommitted && !inheritedClipChanged && !fadesChanged && !viewportChanged {
            for offset in nodes.indices {
                byPath[nodes[offset].path] = start + offset
                byId[nodes[offset].nodeId] = start + offset
            }
            return
        }

        // Relocate the appended snapshot in place. Scroll alone changes window coordinates;
        // the committed layout and the unscrolled geometry retain their independent origins.
        flat.withUnsafeMutableBufferPointer { output in
            currentSpecs.withUnsafeMutableBufferPointer { motion in
                for offset in nodes.indices {
                    let slot = start + offset
                    let parent = output[slot].parentIndex! + shift
                    let local = output[slot].localRect
                    if shift != 0 {
                        output[slot].index = slot
                        output[slot].parentIndex = parent
                    }
                    if moved {
                        let origin = output[parent].targetRect.origin
                        let rect = MotionRect.fromXYWH(origin.x + local.x, origin.y + local.y, local.width, local.height)
                        output[slot].targetRect = rect
                        output[slot].zoomedTargetRect = rect
                        motion[slot].rect = rect
                    }
                    if movedCommitted {
                        output[slot].committedLayoutTarget = local.translated(output[parent].committedLayoutTarget.origin)
                    }
                    if movedUnscrolled {
                        let origin = output[parent].unscrolledRect.origin
                        let rect = MotionRect.fromXYWH(origin.x + local.x, origin.y + local.y, local.width, local.height)
                        output[slot].unscrolledRect = rect
                        output[slot].staticBounds = SIMD4(rect.x, rect.y, rect.width, rect.height)
                    }
                    if moved || inheritedClipChanged {
                        if parent == root {
                            output[slot].clipRect = clip
                        } else if clipsChildren[parent - start] {
                            output[slot].clipRect = intersectRects(output[parent].clipRect, output[parent].targetRect)
                        } else {
                            output[slot].clipRect = output[parent].clipRect
                        }
                    }
                    if fadesChanged { output[slot].activeClipFades = fades }
                    if viewportChanged {
                        if scrollMembershipChanged {
                            output[slot].paintTraits = NativePaintTraits(output[slot].el, inScrollViewport: enclosing != nil)
                        }
                        output[slot].enclosingScrollIndex = enclosing
                        output[slot].enclosingVScrollIndex = vertical
                        output[slot].enclosingHScrollIndex = horizontal
                    }
                    byPath[output[slot].path] = slot
                    byId[output[slot].nodeId] = slot
                }
            }
        }
    }
}
