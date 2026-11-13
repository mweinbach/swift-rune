import Foundation
import simd

/// A layer's scope as recorded by the planning walk (`crates/rune/src/render/layers/plan.rs`).
public struct LayerPlanScope: Sendable, Equatable {
    public var begin: UInt32
    public var end: UInt32
    public var parent: Int?
    public var edges: SIMD4<Float>
    public var vis: SIMD4<Float>
    public var clip: SIMD4<Float>
    public var limit: SIMD4<Float>
    public var fade: SIMD4<UInt32>
    public var opacity: Float
    public var blend: RenderBlend
    public var blur: Float
    public var support: Float
    public var cache: (UInt64, UInt64)?
    public var planned: LayerPlanPlanned
    public var turn: (Float, SIMD2<Float>)?
    public var free: Bool
    public var frame: SIMD4<Float>
    public var hole: SIMD4<Float>

    public init(
        begin: UInt32,
        end: UInt32,
        parent: Int? = nil,
        edges: SIMD4<Float>,
        vis: SIMD4<Float>,
        clip: SIMD4<Float> = NO_CLIP,
        limit: SIMD4<Float> = NO_CLIP,
        fade: SIMD4<UInt32> = .zero,
        opacity: Float = 1.0,
        blend: RenderBlend = .sourceOver,
        blur: Float = 0.0,
        support: Float = 0.0,
        cache: (UInt64, UInt64)? = nil,
        planned: LayerPlanPlanned = .inline,
        turn: (Float, SIMD2<Float>)? = nil,
        free: Bool = false,
        frame: SIMD4<Float>? = nil,
        hole: SIMD4<Float> = .zero
    ) {
        self.begin = begin
        self.end = end
        self.parent = parent
        self.edges = edges
        self.vis = vis
        self.clip = clip
        self.limit = limit
        self.fade = fade
        self.opacity = opacity
        self.blend = blend
        self.blur = blur
        self.support = support
        self.cache = cache
        self.planned = planned
        self.turn = turn
        self.free = free
        self.frame = frame ?? edges
        self.hole = hole
    }

    public static func == (lhs: LayerPlanScope, rhs: LayerPlanScope) -> Bool {
        lhs.begin == rhs.begin &&
        lhs.end == rhs.end &&
        lhs.parent == rhs.parent &&
        lhs.edges == rhs.edges &&
        lhs.vis == rhs.vis &&
        lhs.clip == rhs.clip &&
        lhs.limit == rhs.limit &&
        lhs.fade == rhs.fade &&
        lhs.opacity == rhs.opacity &&
        lhs.blend == rhs.blend &&
        lhs.blur == rhs.blur &&
        lhs.support == rhs.support &&
        lhs.cache?.0 == rhs.cache?.0 &&
        lhs.cache?.1 == rhs.cache?.1 &&
        lhs.planned == rhs.planned &&
        lhs.turn?.0 == rhs.turn?.0 &&
        lhs.turn?.1 == rhs.turn?.1 &&
        lhs.free == rhs.free &&
        lhs.frame == rhs.frame &&
        lhs.hole == rhs.hole
    }
}

public enum LayerPlanPlanned: Sendable, Equatable {
    case hidden
    case covered
    case inline
}

public enum LayerDisposition: Sendable, Equatable {
    case skip
    case inline
    case render(rect: SIMD4<Float>, cache: (UInt64, UInt64)?)
    case cached(rect: SIMD4<Float>, cache: (UInt64, UInt64)?)

    public var rect: SIMD4<Float> {
        switch self {
        case .render(let r, _), .cached(let r, _):
            return r
        case .skip, .inline:
            return .zero
        }
    }

    public static func == (lhs: LayerDisposition, rhs: LayerDisposition) -> Bool {
        switch (lhs, rhs) {
        case (.skip, .skip), (.inline, .inline):
            return true
        case (.render(let lr, let lc), .render(let rr, let rc)):
            return lr == rr && lc?.0 == rc?.0 && lc?.1 == rc?.1
        case (.cached(let lr, let lc), .cached(let rr, let rc)):
            return lr == rr && lc?.0 == rc?.0 && lc?.1 == rc?.1
        default:
            return false
        }
    }
}

public struct LayerHeld: Sendable, Equatable {
    public var size: SIMD2<UInt32>
    public var bytes: UInt64
    public var cache: (UInt64, UInt64)?
    public var lastUsed: UInt64
    public var content: SIMD2<Float>

    public init(
        size: SIMD2<UInt32>,
        bytes: UInt64? = nil,
        cache: (UInt64, UInt64)? = nil,
        lastUsed: UInt64 = 0,
        content: SIMD2<Float> = .zero
    ) {
        self.size = size
        self.bytes = bytes ?? UInt64(size.x) * UInt64(size.y) * LayerPlannerConstants.bpp
        self.cache = cache
        self.lastUsed = lastUsed
        self.content = content
    }

    public static func == (lhs: LayerHeld, rhs: LayerHeld) -> Bool {
        lhs.size == rhs.size &&
        lhs.bytes == rhs.bytes &&
        lhs.cache?.0 == rhs.cache?.0 &&
        lhs.cache?.1 == rhs.cache?.1 &&
        lhs.lastUsed == rhs.lastUsed &&
        lhs.content == rhs.content
    }
}

public protocol LayerHeldDescribing {
    func held() -> LayerHeld
}

extension LayerHeld: LayerHeldDescribing {
    public func held() -> LayerHeld { self }
}

public enum LayerKept: Sendable, Equatable {
    case retained(Int)
    case spare(Int)
}

public enum LayerPoolMove: Sendable, Equatable {
    case park(Int)
    case set(slot: Int, from: LayerKept)
    case create(slot: Int, size: SIMD2<UInt32>)
    case unblur(Int)
    case drop(LayerKept)
}

public enum LayerPoolSource: Sendable, Equatable {
    case slot(Int)
    case retained(Int)
    case spare(Int)
    case new(SIMD2<UInt32>)
}

public enum LayerPlannerConstants {
    public static let warmCapacity: Int = 64
    public static let bpp: UInt64 = 8
    public static let spareBytes: UInt64 = UInt64(LayerPoolLimits.spareBudgetBytes)

    public static func rectOf(_ edges: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(edges.x, edges.y, max(0.0, edges.z - edges.x), max(0.0, edges.w - edges.y))
    }

    public static func bucketOf(_ bounds: SIMD4<Float>) -> (bucket: SIMD2<UInt32>, width: UInt32, height: UInt32) {
        let w = UInt32(max(0.0, bounds.z))
        let h = UInt32(max(0.0, bounds.w))
        let bw = ((w + 63) / 64) * 64
        let bh = ((h + 63) / 64) * 64
        return (SIMD2<UInt32>(bw, bh), w, h)
    }
}

public struct LayerPoolSnapshot<T: LayerHeldDescribing> {
    public var slots: [T?]
    public var retained: [T]
    public var spare: [T]

    public init(slots: [T?] = [], retained: [T] = [], spare: [T] = []) {
        self.slots = slots
        self.retained = retained
        self.spare = spare
    }

    func held(_ source: LayerPoolSource) -> LayerHeld {
        switch source {
        case .slot(let index):
            return slots[index]!.held()
        case .retained(let at):
            return retained[at].held()
        case .spare(let at):
            return spare[at].held()
        case .new(let size):
            return LayerHeld(size: size)
        }
    }
}

public struct LayerPoolView: @unchecked Sendable {
    public enum OwnerKind: Sendable, Equatable {
        case retained
        case spare
    }

    public let ownerKind: OwnerKind
    public var len: Int = 0
    public var moved: Bool = false
    public var order: [LayerPoolSource] = []
    public var visits: UInt64 = 0

    public init(ownerKind: OwnerKind) {
        self.ownerKind = ownerKind
    }

    private func own(_ index: Int) -> LayerPoolSource {
        switch ownerKind {
        case .retained: return .retained(index)
        case .spare: return .spare(index)
        }
    }

    public mutating func reset(_ len: Int) {
        self.len = len
        self.moved = false
        self.order.removeAll(keepingCapacity: true)
    }

    public func source(_ place: Int) -> LayerPoolSource {
        moved ? order[place] : own(place)
    }

    mutating func held<T: LayerHeldDescribing>(_ place: Int, pools: LayerPoolSnapshot<T>) -> LayerHeld {
        visits &+= 1
        return pools.held(source(place))
    }

    mutating func position<T: LayerHeldDescribing>(pools: LayerPoolSnapshot<T>, _ test: (LayerHeld) -> Bool) -> Int? {
        for place in 0..<len {
            if test(held(place, pools: pools)) {
                return place
            }
        }
        return nil
    }

    mutating func bytes<T: LayerHeldDescribing>(pools: LayerPoolSnapshot<T>) -> UInt64 {
        var total: UInt64 = 0
        for place in 0..<len {
            total += held(place, pools: pools).bytes
        }
        return total
    }

    mutating func oldest<T: LayerHeldDescribing>(pools: LayerPoolSnapshot<T>) -> Int {
        var bestPlace = 0
        var bestUsed = held(0, pools: pools).lastUsed
        for place in 1..<len {
            let used = held(place, pools: pools).lastUsed
            if used < bestUsed {
                bestUsed = used
                bestPlace = place
            }
        }
        return bestPlace
    }

    public mutating func ownOrder() {
        if moved { return }
        visits &+= UInt64(len)
        order.reserveCapacity(max(order.capacity, len))
        order.removeAll(keepingCapacity: true)
        for i in 0..<len {
            order.append(own(i))
        }
        moved = true
    }

    @discardableResult
    public mutating func swapRemove(_ place: Int) -> LayerPoolSource {
        ownOrder()
        len -= 1
        let removed = order[place]
        if place < order.count - 1 {
            order[place] = order[order.count - 1]
        }
        order.removeLast()
        return removed
    }

    public mutating func push(_ source: LayerPoolSource) {
        ownOrder()
        len += 1
        order.append(source)
    }
}

private func shrinkScratch<T>(_ scratch: inout [T], keep: Int, trigger: Int) {
    if scratch.capacity > trigger {
        var shrunk: [T] = []
        shrunk.reserveCapacity(keep)
        shrunk.append(contentsOf: scratch)
        scratch = shrunk
    }
}

public struct LayerPlanner: @unchecked Sendable {
    public var dispositions: [LayerDisposition] = []
    public var moves: [LayerPoolMove] = []
    public var slots: [LayerPoolSource?] = []
    public var kept: LayerPoolView = LayerPoolView(ownerKind: .retained)
    public var parked: LayerPoolView = LayerPoolView(ownerKind: .spare)
    public var settles: UInt64 = 0

    public init() {}

    public func capacities() -> [Int] {
        [
            dispositions.capacity,
            moves.capacity,
            slots.capacity,
            kept.order.capacity,
            parked.order.capacity,
        ]
    }

    public mutating func decide<T: LayerHeldDescribing>(
        plan: [LayerPlanScope],
        pools: LayerPoolSnapshot<T>,
        budget: UInt64,
        isolate: Bool,
        maxDim: UInt32
    ) {
        let bpp = LayerPlannerConstants.bpp
        dispositions.removeAll(keepingCapacity: true)
        dispositions.reserveCapacity(plan.count)
        for _ in 0..<plan.count { dispositions.append(.skip) }
        slots.removeAll(keepingCapacity: true)
        slots.reserveCapacity(pools.slots.count)
        for (index, item) in pools.slots.enumerated() {
            slots.append(item != nil ? .slot(index) : nil)
        }
        moves.removeAll(keepingCapacity: true)
        kept.reset(pools.retained.count)
        parked.reset(pools.spare.count)

        var active: UInt64 = 0
        // Claim resident cache hits first so existing on-screen caches never thrash under a tight budget.
        for (index, layer) in plan.enumerated() {
            let rect = LayerPlannerConstants.rectOf(layer.edges)
            if rect.z == 0 || rect.w == 0 || !isolate || layer.planned != .inline { continue }
            guard let cache = layer.cache else { continue }
            guard let at = kept.position(pools: pools, { $0.cache?.0 == cache.0 && $0.cache?.1 == cache.1 }) else { continue }
            let bytes = kept.held(at, pools: pools).bytes
            let over = active + bytes > budget
            if over && layer.begin + 1 < layer.end { continue }
            if !over { active += bytes }
            dispositions[index] = .cached(rect: rect, cache: over ? nil : cache)
            slots[index] = kept.swapRemove(at)
            moves.append(.set(slot: index, from: .retained(at)))
        }

        for (index, layer) in plan.enumerated() {
            if case .cached = dispositions[index] { continue }
            let rect = LayerPlannerConstants.rectOf(layer.edges)
            let parentDisp = layer.parent.map { dispositions[$0] }
            let parentBlocked: Bool = switch parentDisp {
            case .some(.skip), .some(.cached): true
            default: false
            }
            if layer.planned == .hidden || rect.z == 0 || rect.w == 0 || parentBlocked {
                dispositions[index] = .skip
                parkSlot(index, pools: pools)
                continue
            }
            if !isolate {
                dispositions[index] = .inline
                parkSlot(index, pools: pools)
                continue
            }

            var bounds = rect
            var b = LayerPlannerConstants.bucketOf(bounds)
            var cache: (UInt64, UInt64)? = nil
            if let reqCache = layer.cache {
                let previous = kept.position(pools: pools, { $0.cache?.0 == reqCache.0 })
                let needed = UInt64(b.bucket.x) * UInt64(b.bucket.y) * bpp
                if b.bucket.x <= maxDim && b.bucket.y <= maxDim && active + needed <= budget {
                    active += needed
                    cache = reqCache
                    if let at = previous {
                        parkSlot(index, pools: pools)
                        slots[index] = kept.swapRemove(at)
                        moves.append(.set(slot: index, from: .retained(at)))
                    } else {
                        trim(active: active, budget: budget, pools: pools)
                    }
                } else {
                    if let at = previous {
                        kept.swapRemove(at)
                        moves.append(.drop(.retained(at)))
                    }
                    bounds = LayerPlannerConstants.rectOf(layer.vis)
                    b = LayerPlannerConstants.bucketOf(bounds)
                }
            }

            let additiveParent = layer.parent.map { plan[$0].blend == .plusLighter } ?? false
            let scissorClip = layer.clip == NO_CLIP || (
                layer.fade == .zero &&
                abs(layer.clip.x - round(layer.clip.x)) < 1e-3 &&
                abs(layer.clip.y - round(layer.clip.y)) < 1e-3 &&
                abs(layer.clip.z - round(layer.clip.z)) < 1e-3 &&
                abs(layer.clip.w - round(layer.clip.w)) < 1e-3
            )
            if cache == nil &&
                layer.opacity == 1.0 &&
                layer.blend == .sourceOver &&
                !additiveParent &&
                layer.blur == 0.0 &&
                layer.fade.w == 0 &&
                scissorClip &&
                layer.turn == nil &&
                layer.hole.w == 0.0
            {
                dispositions[index] = .inline
                parkSlot(index, pools: pools)
                continue
            }

            dispositions[index] = .render(rect: bounds, cache: cache)
            let fits: Bool = if let source = slots[index] {
                {
                    let size = pools.held(source).size
                    return size.x >= b.width && size.y >= b.height && (
                        size == b.bucket ||
                        UInt64(size.x) * UInt64(size.y) <= 2 * UInt64(b.width) * UInt64(b.height)
                    )
                }()
            } else {
                false
            }

            if !fits {
                parkSlot(index, pools: pools)
                let spareAt = parked.position(pools: pools) { t in
                    let size = t.size
                    return size.x >= b.width && size.y >= b.height &&
                        UInt64(size.x) * UInt64(size.y) <= 2 * UInt64(max(b.width, 64)) * UInt64(max(b.height, 64))
                }
                if let at = spareAt {
                    slots[index] = parked.swapRemove(at)
                    moves.append(.set(slot: index, from: .spare(at)))
                } else {
                    slots[index] = .new(b.bucket)
                    moves.append(.create(slot: index, size: b.bucket))
                }
            }
            if layer.blur == 0.0 {
                moves.append(.unblur(index))
            }
        }
        trim(active: active, budget: budget, pools: pools)
    }

    public mutating func settle(len: Int, retained: Int, spare: Int) {
        settles &+= 1
        moves.removeAll(keepingCapacity: true)
        slots.removeAll(keepingCapacity: true)
        kept.reset(0)
        parked.reset(0)
        if len == 0 {
            dispositions.removeAll(keepingCapacity: true)
        }
        // Reserve 32 when small so Swift's malloc_good_size rounding keeps Array.capacity <= 64 (warmCapacity).
        let smallReserve = LayerPlannerConstants.warmCapacity / 2
        let trigger = max(len, LayerPlannerConstants.warmCapacity) * 2
        let keep = len <= smallReserve ? smallReserve : max(len, LayerPlannerConstants.warmCapacity)
        shrinkScratch(&dispositions, keep: keep, trigger: trigger)
        shrinkScratch(&moves, keep: keep, trigger: trigger)
        shrinkScratch(&slots, keep: keep, trigger: trigger)
        let keptKeep = retained <= smallReserve ? smallReserve : max(retained, LayerPlannerConstants.warmCapacity)
        let keptTrigger = max(retained, LayerPlannerConstants.warmCapacity) * 2
        shrinkScratch(&kept.order, keep: keptKeep, trigger: keptTrigger)
        let parkedKeep = spare <= smallReserve ? smallReserve : max(spare, LayerPlannerConstants.warmCapacity)
        let parkedTrigger = max(spare, LayerPlannerConstants.warmCapacity) * 2
        shrinkScratch(&parked.order, keep: parkedKeep, trigger: parkedTrigger)
    }

    private mutating func parkSlot<T: LayerHeldDescribing>(_ index: Int, pools: LayerPoolSnapshot<T>) {
        guard let source = slots[index] else { return }
        slots[index] = nil
        moves.append(.park(index))
        parked.push(source)
        var totalBytes = parked.bytes(pools: pools)
        while totalBytes > LayerPlannerConstants.spareBytes {
            let oldest = parked.oldest(pools: pools)
            totalBytes -= parked.held(oldest, pools: pools).bytes
            parked.swapRemove(oldest)
            moves.append(.drop(.spare(oldest)))
        }
    }

    private mutating func trim<T: LayerHeldDescribing>(active: UInt64, budget: UInt64, pools: LayerPoolSnapshot<T>) {
        let available = budget >= active ? (budget - active) : 0
        var totalBytes = kept.bytes(pools: pools)
        while totalBytes > available {
            let oldest = kept.oldest(pools: pools)
            totalBytes -= kept.held(oldest, pools: pools).bytes
            kept.swapRemove(oldest)
            moves.append(.drop(.retained(oldest)))
        }
    }
}
