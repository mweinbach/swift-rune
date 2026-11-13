import Foundation
import RuneMotion
import simd

/// Paint-time whole-pixel snapping (`El::pixel_snap`), ported from
/// `crates/rune/src/runtime/paint/pixel_snap.rs`.
///
/// Layout and hit testing stay fractional; only where fills, borders, clips, and text
/// land on the device pixel grid snaps so adjacent boxes meet without seams and 1.1 pt
/// gaps stay crisp at fractional scales.
public enum PixelSnap {
    /// Frames a glide outlives its node's last paint (cached subtrees, removed nodes).
    static let keepFrames: UInt32 = 120

    /// Seconds a still scaled layer's correction to the grid takes to ease in.
    static let settleDuration: Double = 0.1

    private static let identityMap = SIMD4<Float>(1, 0, 1, 0)

    public struct Motion: Sendable, Equatable {
        public var by: SIMD4<Float>
        public var rest: SIMD4<Float>
        /// Scale at which `by` is drawn (`1` for unscaled rect, layer scale for drawn rect).
        public var k: Float

        public init(by: SIMD4<Float>, rest: SIMD4<Float>, k: Float = 1.0) {
            self.by = by
            self.rest = rest
            self.k = k
        }
    }

    public struct Rest: Sendable, Equatable {
        public var exact: SIMD4<Float>
        public var at: SIMD4<Float>

        public static let zero = Rest(exact: .zero, at: .zero)
    }

    public struct Parent: Sendable, Equatable {
        public var rest: Rest
        public var now: Rest
        public var left: SIMD4<Float>
    }

    public struct Inherit: Sendable, Equatable {
        /// `El.pixelSnap(false)` above, or a turn: this subtree draws at exact edges.
        public var off: Bool = false
        /// Translation in points from scrolls, sticky shifts, and growth rows above, which snaps as a whole.
        public var rigid: SIMD2<Float> = .zero
        /// Nearest scaled layer above or here (1-based index into current frame's layers, `0` = none).
        public var layer: UInt32 = 0
        /// Parent's edges for centring. `nil` when parent paints nothing or doesn't share rigid translation / plain grid.
        public var parent: Parent? = nil

        public init() {}
    }

    struct Glide: Sendable, Equatable {
        var rest: SIMD4<Float>
        var k: Float
        /// Resting edges in device px, less the rigid translation.
        var restPx: SIMD4<Float>
        var from: SIMD4<Float>
        var to: SIMD4<Float>
        var span: SIMD4<Float>
        var seen: UInt32
        var follow: SIMD4<Float>
        var parent: SIMD4<Float>

        func at(edge k: Int, to: Float, m: Float, follow: Float) -> Float {
            to + (from[k] - to) * left(edge: k, m: m, follow: follow)
        }

        func left(edge k: Int, m: Float, follow: Float) -> Float {
            if abs(span[k]) > 1.0 / 64.0 {
                return (m / span[k]).clamped(to: -1.0...1.0)
            }
            return follow
        }
    }

    enum LayerPhase: Sendable, Equatable {
        case moving(last: Double)
        case rest(since: Double)
    }

    struct Layer: Sendable, Equatable {
        var rect: SIMD4<Float>
        var seen: UInt32
        var phase: LayerPhase
        var out0: (rect: SIMD4<Float>, weight: Float)
        var out1: (rect: SIMD4<Float>, weight: Float)

        static func == (lhs: Layer, rhs: Layer) -> Bool {
            lhs.rect == rhs.rect && lhs.seen == rhs.seen && lhs.phase == rhs.phase
                && lhs.out0.rect == rhs.out0.rect && lhs.out0.weight == rhs.out0.weight
                && lhs.out1.rect == rhs.out1.rect && lhs.out1.weight == rhs.out1.weight
        }
    }

    struct LayerSnap: Sendable {
        var to: Float
        var near: Float
        var map0: SIMD4<Float>
        var w0: Float
        var map1: SIMD4<Float>
        var w1: Float
        var rigid: SIMD2<Float>

        static let none = LayerSnap(
            to: 0,
            near: 0,
            map0: PixelSnap.identityMap,
            w0: 0,
            map1: PixelSnap.identityMap,
            w1: 0,
            rigid: .zero
        )
    }

    public struct Glides: Sendable {
        var glides: [NodeId: Glide] = [:]
        var layers: [NodeId: Layer] = [:]
        var now: [LayerSnap] = []
        var frame: UInt32 = 0
        var t: Double = 0
        var size: SIMD2<Float> = .zero
        var easing: Bool = false

        public init() {}

        public var isEasing: Bool { easing }

        public mutating func beginFrame(t: Double, size: SIMD2<Float>) {
            frame = frame &+ 1
            self.t = t
            self.size = size
            now.removeAll(keepingCapacity: true)
            easing = false
            let curFrame = frame
            if !glides.isEmpty {
                glides = glides.filter { (curFrame &- $0.value.seen) < PixelSnap.keepFrames }
            }
            if !layers.isEmpty {
                layers = layers.filter { (curFrame &- $0.value.seen) < PixelSnap.keepFrames }
            }
        }

        public mutating func layer(
            id: NodeId,
            r: SIMD4<Float>,
            unscaled: SIMD4<Float>,
            rigid: SIMD2<Float>,
            cached: Bool
        ) -> UInt32 {
            let cur = SIMD4<Float>(r[0] - rigid[0], r[1] - rigid[1], r[2] - rigid[0], r[3] - rigid[1])
            let tNow = self.t
            let curFrame = self.frame
            var l = layers[id] ?? Layer(
                rect: cur,
                seen: curFrame,
                phase: .rest(since: -.infinity),
                out0: (cur, 0),
                out1: (cur, 0)
            )
            func eased(_ since: Double) -> Float {
                let x: Float = cached ? 1.0 : Float(((tNow - since) / PixelSnap.settleDuration).clamped(to: 0.0...1.0))
                return x * x * (3.0 - 2.0 * x)
            }
            let to: Float
            if reach(affine(from: l.rect, to: cur), size: size) > 1.0 / 256.0 {
                if case .rest(let since) = l.phase {
                    let f = eased(since)
                    let a = (l.out0.rect, l.out0.weight * (1.0 - f))
                    let b = (l.out1.rect, l.out1.weight * (1.0 - f))
                    var outs = [(l.rect, f), a, b]
                    outs.sort { $0.1 > $1.1 }
                    l.out0 = outs[0]
                    l.out1 = outs[1]
                }
                l.rect = cur
                l.phase = .moving(last: tNow)
                to = 0.0
            } else {
                let since: Double
                switch l.phase {
                case .moving(let last): since = last
                case .rest(let s): since = s
                }
                l.phase = .rest(since: since)
                to = eased(since)
                if to == 1.0 {
                    l.out0 = (cur, 0)
                    l.out1 = (cur, 0)
                }
            }
            l.seen = curFrame
            layers[id] = l
            let m0 = l.out0.weight > 0 ? affine(from: cur, to: l.out0.rect) : PixelSnap.identityMap
            let w0 = l.out0.weight > 0 ? l.out0.weight * (1.0 - to) : 0
            let m1 = l.out1.weight > 0 ? affine(from: cur, to: l.out1.rect) : PixelSnap.identityMap
            let w1 = l.out1.weight > 0 ? l.out1.weight * (1.0 - to) : 0
            let near = ((1.0 - far(r, unscaled)) / (1.0 - 1.0 / 16.0)).clamped(to: 0.0...1.0)
            now.append(LayerSnap(to: to, near: near, map0: m0, w0: w0, map1: m1, w1: w1, rigid: rigid))
            return UInt32(now.count)
        }

        public mutating func atRest(
            id: NodeId,
            r: SIMD4<Float>,
            rigid: SIMD2<Float>,
            parent: Parent?
        ) -> (SIMD4<Float>, Parent?) {
            if let p = parent,
               p.left != .zero,
               (0..<2).contains(where: { a in
                   resting(p.rest, axis: a, range: (r[a] - rigid[a], r[a + 2] - rigid[a])) != nil
               }) {
                let (out, newParent) = glide(id: id, motion: Motion(by: .zero, rest: r, k: 1.0), r: r, rigid: rigid, parent: p)
                return (out, newParent)
            }
            if !glides.isEmpty {
                glides.removeValue(forKey: id)
            }
            let (out, rest) = PixelSnap.snap(r, motion: .zero, rigid: rigid, parent: parent?.rest) { _, c in c }
            return (out, Parent(rest: rest, now: rest, left: .zero))
        }

        public mutating func snapped(
            id: NodeId,
            motion: Motion?,
            r: SIMD4<Float>,
            unscaled: SIMD4<Float>,
            rigid: SIMD2<Float>,
            layer: UInt32,
            scale sc: Float,
            parent: Parent?
        ) -> (SIMD4<Float>, Parent?) {
            let l = (layer > 0 && Int(layer - 1) < now.count) ? now[Int(layer - 1)] : LayerSnap.none
            let weight: Float = layer == 0
                ? ((1.0 - far(r, unscaled)) / (1.0 - 1.0 / 16.0)).clamped(to: 0.0...1.0)
                : l.near
            var out = r
            let plain = (layer == 0) && (weight >= 1.0)
            let plainParent = plain ? parent : nil
            var rest: Parent? = nil
            if weight > 0 && l.to < 1.0 {
                let snappedRect: SIMD4<Float>
                let atParent: Parent?
                switch motion {
                case nil:
                    (snappedRect, atParent) = atRest(id: id, r: unscaled, rigid: rigid, parent: plainParent)
                case .some(let m) where l.to == 0.0:
                    let (gOut, gAt) = glide(id: id, motion: m, r: unscaled, rigid: rigid, parent: plainParent)
                    (snappedRect, atParent) = (gOut, gAt)
                case .some(let m):
                    (snappedRect, _) = PixelSnap.snap(unscaled, motion: m.by, rigid: rigid, parent: nil) { _, c in c }
                    atParent = nil
                }
                rest = plain ? atParent : nil
                for k in 0..<4 {
                    out[k] += (snappedRect[k] - r[k]) * weight * (1.0 - l.to)
                }
            }
            if layer == 0 {
                return (out, rest)
            }

            let lr = l.rigid
            let layerRigid = SIMD2<Float>(
                lr[0] + (rigid[0] - lr[0]) * sc,
                lr[1] + (rigid[1] - lr[1]) * sc
            )
            var leftAmt: Float = 0
            for (map, w) in [(l.map0, l.w0), (l.map1, l.w1)] {
                if w <= 0 || weight >= 1.0 { continue }
                var m = SIMD4<Float>.zero
                for k in 0..<4 {
                    let a = k % 2
                    m[k] = (r[k] - lr[a]) * map[a * 2] + map[a * 2 + 1] + lr[a]
                }
                let localW = w * (1.0 - weight) * (1.0 - far(r, m)).clamped(to: 0.0...1.0)
                let (at, _) = PixelSnap.snap(m, motion: .zero, rigid: layerRigid, parent: nil) { _, c in c }
                for k in 0..<4 {
                    let c = (at[k] - m[k]) * localW
                    out[k] += c
                    leftAmt = max(leftAmt, abs(c))
                }
            }

            let at: SIMD4<Float>
            switch motion {
            case .some(let m) where l.to > 0:
                let scaledMotion = Motion(by: m.by * sc, rest: m.rest, k: sc)
                at = glide(id: id, motion: scaledMotion, r: r, rigid: layerRigid, parent: nil).0
            case nil where l.to > 0:
                at = atRest(id: id, r: r, rigid: layerRigid, parent: nil).0
            default:
                at = PixelSnap.snap(r, motion: .zero, rigid: layerRigid, parent: nil) { _, c in c }.0
            }
            if l.to == 1.0 {
                return (at, nil)
            }
            for k in 0..<4 {
                out[k] += (at[k] - r[k]) * l.to
                leftAmt = max(leftAmt, abs(at[k] - r[k]) * (1.0 - l.to))
            }
            easing = easing || (leftAmt > 1.0 / 128.0)
            return (out, nil)
        }

        private mutating func glide(
            id: NodeId,
            motion m: Motion,
            r: SIMD4<Float>,
            rigid: SIMD2<Float>,
            parent: Parent?
        ) -> (SIMD4<Float>, Parent) {
            let free = SIMD4<Float>(r[0] - rigid[0], r[1] - rigid[1], r[2] - rigid[0], r[3] - rigid[1])
            let follow = parent?.left ?? .zero
            let parentRest = parent?.rest.exact ?? .zero
            var g: Glide
            if let existing = glides[id], existing.rest == m.rest, existing.k == m.k {
                g = existing
                if g.parent != parentRest {
                    for k in 0..<4 where abs(g.span[k]) <= 1.0 / 64.0 {
                        g.from[k] = g.at(edge: k, to: g.to[k], m: 0, follow: g.follow[k])
                    }
                }
            } else {
                let from: SIMD4<Float>
                if let prev = glides[id] {
                    from = SIMD4<Float>(
                        prev.at(edge: 0, to: prev.to[0], m: free[0] - prev.restPx[0], follow: prev.follow[0]),
                        prev.at(edge: 1, to: prev.to[1], m: free[1] - prev.restPx[1], follow: prev.follow[1]),
                        prev.at(edge: 2, to: prev.to[2], m: free[2] - prev.restPx[2], follow: prev.follow[2]),
                        prev.at(edge: 3, to: prev.to[3], m: free[3] - prev.restPx[3], follow: prev.follow[3])
                    )
                } else {
                    from = PixelSnap.start(r: r, rigid: rigid, parent: parent?.now)
                }
                let restPx = free - m.by
                g = Glide(
                    rest: m.rest,
                    k: m.k,
                    restPx: restPx,
                    from: from,
                    to: from,
                    span: m.by,
                    seen: 0,
                    follow: follow,
                    parent: parentRest
                )
            }

            let (out, rest) = PixelSnap.snap(r, motion: m.by, rigid: rigid, parent: parent?.rest) { k, c in
                g.to[k] = c
                return g.at(edge: k, to: c, m: m.by[k], follow: follow[k])
            }
            g.seen = frame
            g.follow = follow
            g.parent = parentRest
            glides[id] = g
            let shiftX = PixelSnap.roundHalfUp(rigid[0])
            let shiftY = PixelSnap.roundHalfUp(rigid[1])
            let now = Rest(
                exact: free,
                at: SIMD4<Float>(out[0] - shiftX, out[1] - shiftY, out[2] - shiftX, out[3] - shiftY)
            )
            let leftVec = SIMD4<Float>(
                g.left(edge: 0, m: m.by[0], follow: follow[0]),
                g.left(edge: 1, m: m.by[1], follow: follow[1]),
                g.left(edge: 2, m: m.by[2], follow: follow[2]),
                g.left(edge: 3, m: m.by[3], follow: follow[3])
            )
            return (out, Parent(rest: rest, now: now, left: leftVec))
        }
    }

    // MARK: - Core Snapping Helpers

    /// Converts a point coordinate to the 1/64 device-pixel grid (`snap_px` in `build.rs`).
    @inline(__always)
    public static func snapPx(_ pt: Float, scale: Float) -> Float {
        (pt * scale * 64.0).rounded(.toNearestOrAwayFromZero) / 64.0
    }

    @inline(__always)
    public static func edgesPx(_ rect: MotionRect, scale: Float) -> SIMD4<Float> {
        SIMD4<Float>(
            snapPx(rect.left, scale: scale),
            snapPx(rect.top, scale: scale),
            snapPx(rect.right, scale: scale),
            snapPx(rect.bottom, scale: scale)
        )
    }

    /// Quantizes device px value onto 1/64 px grid (`(v * 64).round() / 64`).
    @inline(__always)
    public static func grid64(_ v: Float) -> Float {
        (v * 64.0).rounded(.toNearestOrAwayFromZero) / 64.0
    }

    /// Rounds half up on the device grid (`(v + 0.5).floor()`).
    @inline(__always)
    public static func roundHalfUp(_ v: Float) -> Float {
        (v + 0.5).rounded(.down)
    }

    /// How far a gliding box's top/left (device px) sits from its nearest whole pixel.
    @inline(__always)
    public static func textGlide(_ top: Float) -> Float {
        let g = top - top.rounded(.toNearestOrAwayFromZero)
        return abs(g) < 1.0 / 64.0 ? 0.0 : g
    }

    /// Chromium CSS border/outline snapping (`pixel_snap::line_width`):
    /// under 1 px -> 1 px; above 1 px -> `(abs(w) + 1/64).floor().max(1)`, preserving sign and 0.
    @inline(__always)
    public static func lineWidth(_ w: Float) -> Float {
        if w == 0.0 || !w.isFinite {
            return w
        }
        return copysign(max(1.0, (abs(w) + 1.0 / 64.0).rounded(.down)), w)
    }

    /// Motion toward `rest` (`pixel_snap::motion`).
    public static func motion(
        rect: MotionRect,
        rest: MotionRect?,
        scale s: Float,
        anchored: Bool,
        growthRow: Bool
    ) -> Motion? {
        guard !anchored, let rest else { return nil }
        let a = SIMD4<Float>(rect.left, rect.top, rect.right, rect.bottom)
        let b = SIMD4<Float>(rest.left, rest.top, rest.right, rest.bottom)
        var by = (a - b) * s
        if growthRow {
            by[3] = by[1]
        }
        return Motion(by: by, rest: b, k: 1.0)
    }

    /// Whether a box paints a visible fill/border/gradient that its children's gaps show against.
    public static func frames<State>(
        _ el: El<State>,
        effectiveFill: Color? = nil,
        effectiveBorder: Color? = nil
    ) -> Bool {
        let fillAlpha = (effectiveFill ?? el.background).a
        let borderColorAlpha = (effectiveBorder ?? el.borderColor).a
        let hasBorder = (el.borderWidth > 0 || el.borderSides != nil) && borderColorAlpha > 0
        return fillAlpha > 0
            || (el.hoverBg?.a ?? 0) > 0
            || (el.pressBg?.a ?? 0) > 0
            || el.gradient != nil
            || hasBorder
    }

    /// Edge-based pixel snapping (`pixel_snap::snap`).
    public static func snap(
        _ r: SIMD4<Float>,
        motion: SIMD4<Float>,
        rigid: SIMD2<Float>,
        parent: Rest?,
        ease: (Int, Float) -> Float
    ) -> (SIMD4<Float>, Rest) {
        var out = r
        var rest = Rest.zero
        for axis in 0..<2 {
            let a = axis
            let b = axis + 2
            let restA = grid64(r[a] - motion[a] - rigid[axis])
            let restB = grid64(r[b] - motion[b] - rigid[axis])
            rest.exact[a] = restA
            rest.exact[b] = restB
            rest.at[a] = restA
            rest.at[b] = restB
            if restB - restA < 0.5 {
                continue
            }
            let shift = roundHalfUp(rigid[axis])
            let lo: Float
            let hi: Float
            if let parent, let centred = resting(parent, axis: axis, range: (restA, restB)) {
                (lo, hi) = centred
            } else {
                lo = roundHalfUp(restA)
                hi = max(roundHalfUp(restB), lo + 1.0)
            }
            rest.at[a] = lo
            rest.at[b] = hi
            for (k, rEdge, atEdge) in [(a, restA, lo), (b, restB, hi)] {
                let c = atEdge - rEdge
                let eased = ease(k, c)
                out[k] = (eased == c ? atEdge : rEdge + eased) + shift + motion[k]
            }
        }
        return (out, rest)
    }

    private static func start(r: SIMD4<Float>, rigid: SIMD2<Float>, parent: Rest?) -> SIMD4<Float> {
        var now = SIMD4<Float>.zero
        _ = snap(r, motion: .zero, rigid: rigid, parent: nil) { k, c in
            now[k] = c
            return c
        }
        guard let p = parent else { return now }
        for axis in 0..<2 {
            let a = axis
            let b = axis + 2
            let ra = r[a] - rigid[axis]
            let rb = r[b] - rigid[axis]
            if rb - ra < 0.5 { continue }
            if let (lo, hi) = centred(p, edges: (a, b), range: (ra, rb), slack: 1.0) {
                let w = 1.0 - abs((ra - p.exact[a]) - (p.exact[b] - rb))
                now[a] += (lo - ra - now[a]) * w
                now[b] += (hi - rb - now[b]) * w
            }
        }
        return now
    }

    private static func resting(_ parent: Rest, axis: Int, range: (Float, Float)) -> (Float, Float)? {
        let a = axis
        let b = axis + 2
        if parent.at[a].truncatingRemainder(dividingBy: 1.0) != 0.0
            || parent.at[b].truncatingRemainder(dividingBy: 1.0) != 0.0 {
            return nil
        }
        return centred(parent, edges: (a, b), range: range, slack: 1.0 / 16.0)
    }

    private static func centred(
        _ parent: Rest,
        edges: (Int, Int),
        range: (Float, Float),
        slack: Float
    ) -> (Float, Float)? {
        let (a, b) = edges
        let (ra, rb) = range
        let (pa, pb) = (parent.exact[a], parent.exact[b])
        let (qa, qb) = (parent.at[a], parent.at[b])
        if abs((ra - pa) - (pb - rb)) >= slack {
            return nil
        }
        let gap = roundHalfUp((qb - qa - (rb - ra)) / 2.0)
        return (qb - qa - 2.0 * gap >= 1.0) ? (qa + gap, qb - gap) : nil
    }

    private static func far(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
        max(
            max(abs(a[0] - b[0]), abs(a[1] - b[1])),
            max(abs(a[2] - b[2]), abs(a[3] - b[3]))
        )
    }

    private static func affine(from: SIMD4<Float>, to: SIMD4<Float>) -> SIMD4<Float> {
        var map = identityMap
        for a in 0..<2 {
            let w = from[a + 2] - from[a]
            let toW = to[a + 2] - to[a]
            let k: Float = abs(w) > 1e-3 ? (toW / w) : 1.0
            map[a * 2] = k
            map[a * 2 + 1] = to[a] - from[a] * k
        }
        return map
    }

    private static func reach(_ map: SIMD4<Float>, size: SIMD2<Float>) -> Float {
        let m0 = max(abs(map[1]), abs((map[0] - 1.0) * size[0] + map[1]))
        let m1 = max(abs(map[3]), abs((map[2] - 1.0) * size[1] + map[3]))
        return max(m0, m1)
    }
}
