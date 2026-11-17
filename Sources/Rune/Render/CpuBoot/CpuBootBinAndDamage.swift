import Foundation
#if canImport(simd)
import simd
#endif

/// Tile binning, layer planning, opaque culling, and tile damage hashing (`cpu_boot/bin.rs` + `cpu_boot/damage.rs`).
public enum CpuBootBin {
    public static let tileW: UInt32 = 64
    public static let tileH: UInt32 = 32
    public static let topLayer: UInt32 = UInt32.max

    public enum LayerShow: Sendable, Equatable {
        case hidden
        case flat
        case render
    }

    public struct PlannedLayer: Sendable, Equatable {
        public var begin: UInt32
        public var end: UInt32
        public var show: LayerShow
        public var bounds: SIMD4<Int32>
        public var additive: Bool
        public var hole: SIMD4<Float>
    }

    public struct Solid: Sendable, Equatable {
        public var edges: SIMD4<Float>
        public var radii: SIMD4<Float>
        public var inset: Float

        public func bands() -> (Float, Float) {
            let m = min((edges.z - edges.x) * 0.5, (edges.w - edges.y) * 0.5)
            func reach(_ r: Float) -> Float { r < 0 ? cornerExtent(min(-r, m)) : min(r, m) }
            let r0 = reach(radii.x)
            let r1 = reach(radii.y)
            let r2 = reach(radii.z)
            let r3 = reach(radii.w)
            return (max(max(r0, r1), inset), max(max(r3, r2), inset))
        }

        public func span(at y: Float) -> (Float, Float) {
            let top = y - edges.y
            let bottom = edges.w - y
            let t = inset
            if top < t || bottom < t { return emptySpan }
            let m = min((edges.z - edges.x) * 0.5, (edges.w - edges.y) * 0.5)
            func reach(_ r: Float) -> Float { r < 0 ? cornerExtent(min(-r, m)) : min(r, m) }
            let upper = y < (edges.y + edges.w) * 0.5
            let rl = upper ? reach(radii.x) : reach(radii.w)
            let rr = upper ? reach(radii.y) : reach(radii.z)
            let near = min(top, bottom)
            let a = edges.x + (near < rl ? max(rl, t) : t)
            let b = edges.z - (near < rr ? max(rr, t) : t)
            return (a, b)
        }
    }

    public static let emptySpan: (Float, Float) = (.infinity, -.infinity)

    @inline(__always)
    public static func intersect(_ a: (Float, Float), _ b: (Float, Float)) -> (Float, Float) {
        (max(a.0, b.0), min(a.1, b.1))
    }

    public static func clipSpan(_ clip: CpuBootShade.Clip, y: Float) -> (Float, Float) {
        let c = clip.rect
        let inset = clip.inset()
        if y < c.y + inset.y || y > c.w - inset.w { return emptySpan }
        let edges = (c.x + inset.x, c.z - inset.z)
        guard let radii = clip.radii else { return edges }
        return intersect(edges, Solid(edges: c, radii: radii, inset: 0.5).span(at: y))
    }

    public static func interior(_ i: RenderInstance) -> Solid? {
        let edges = SIMD4<Float>(i.rect.x, i.rect.y, i.rect.x + i.rect.z, i.rect.y + i.rect.w)
        let soft = max(i.params.z, 0.5)
        let bw = i.params.x
        if bw <= 0.0 {
            return Solid(edges: edges, radii: i.radii, inset: soft)
        }
        if i.params.y == KIND_RECT && CpuBootShade.hasSides(i) {
            let half = SIMD2<Float>(i.rect.z * 0.5, i.rect.w * 0.5)
            let center = SIMD2<Float>(i.rect.x + half.x, i.rect.y + half.y)
            let (c, ih, radii) = CpuBootShade.sidesInner(i, center: center, half: half)
            return Solid(edges: SIMD4<Float>(c.x - ih.x, c.y - ih.y, c.x + ih.x, c.y + ih.y), radii: radii, inset: soft)
        }
        return Solid(edges: edges, radii: i.radii, inset: soft + bw)
    }

    public static func opaqueBox(_ i: RenderInstance) -> Solid? {
        guard i.params.y == KIND_RECT && i.fill.w >= 1.0 else { return nil }
        return interior(i)
    }

    public static func covers(_ solid: Solid?, clip: CpuBootShade.Clip, r: SIMD4<Float>) -> Bool {
        let x0 = r.x + 0.5
        let x1 = r.z - 0.5
        for y in [r.y + 0.5, r.w - 0.5] {
            let span: (Float, Float)
            if let s = solid {
                span = intersect(s.span(at: y), clipSpan(clip, y: y))
            } else {
                span = clipSpan(clip, y: y)
            }
            if !(span.0 <= x0 && span.1 >= x1) {
                return false
            }
        }
        return true
    }

    public static func pixelBounds(_ i: RenderInstance, width w: Int32, height h: Int32) -> SIMD4<Int32> {
        let kind = i.params.y
        if kind > 11.5 || kind == KIND_LAYER_END { return .zero }
        let kInt = Int(max(0, Int(kind.rounded())))
        let grow: Float
        switch kInt {
        case 1: grow = i.params.z * 3.0 + 1.0
        case 2: grow = 0.0
        case 3, 5...9: grow = 1.0
        default: grow = 1.0 + i.params.z * 2.0
        }

        var rect = i.rect
        if kind == KIND_GLYPH && i.params.x != 0.0 {
            let s = sinf(i.params.x)
            let c = cosf(i.params.x)
            let rw = abs(c) * rect.z + abs(s) * rect.w
            let rh = abs(s) * rect.z + abs(c) * rect.w
            rect = SIMD4<Float>(rect.x + (rect.z - rw) * 0.5 - 1.0, rect.y + (rect.w - rh) * 0.5 - 1.0, rw + 2.0, rh + 2.0)
        }
        var lo = SIMD2<Float>(rect.x - grow, rect.y - grow)
        var hi = SIMD2<Float>(lo.x + rect.z + 2.0 * grow, lo.y + rect.w + 2.0 * grow)
        if kind < 1.5 && i.uv.z < 0.0 {
            lo = SIMD2<Float>(max(lo.x, i.rect.x + i.uv.x), max(lo.y, i.rect.y + i.uv.y))
            hi = SIMD2<Float>(max(lo.x, min(hi.x, i.rect.x - i.uv.z)), max(lo.y, min(hi.y, i.rect.y + i.uv.w)))
        }
        func first(_ v: Float) -> Float { ceilf(v - 0.5) }
        let c = i.clip
        let x0 = max(0.0, max(first(lo.x), floorf(c.x - 0.5)))
        let y0 = max(0.0, max(first(lo.y), floorf(c.y - 0.5)))
        let x1 = min(Float(w), min(first(hi.x), ceilf(c.z + 0.5)))
        let y1 = min(Float(h), min(first(hi.y), ceilf(c.w + 0.5)))
        guard x1 > x0 && y1 > y0 else { return .zero }
        return SIMD4<Int32>(Int32(x0), Int32(y0), Int32(x1), Int32(y1))
    }

    public struct Bins: Sendable {
        public let cols: UInt32
        public let rows: UInt32
        public let start: [UInt32]
        public let index: [UInt32]
        public let bounds: [SIMD4<Int32>]
        public let covered: [Bool]
        public let within: [UInt32]
        public let blurs: [(UInt32, CpuBootBackdrop.Record)]
        public let quiet: [Bool]
        public let culled: Int
        public let layers: [PlannedLayer]
        public let scope: [UInt32: UInt32]

        public var tileCount: Int { Int(cols * rows) }
        public var totalBinned: Int { index.count }

        public func tile(_ t: Int) -> ArraySlice<UInt32> {
            let a = Int(start[t])
            let b = Int(start[t + 1])
            return index[a..<b]
        }

        public static func build(for scene: CpuBootScene) -> Bins {
            let w = UInt32(max(0, scene.size.0))
            let h = UInt32(max(0, scene.size.1))
            let cols = (w + tileW - 1) / tileW
            let rows = (h + tileH - 1) / tileH
            let tiles = Int(cols * rows)

            var bounds = scene.instances.map { pixelBounds($0, width: Int32(w), height: Int32(h)) }
            let (layers, scope) = planLayers(scene.instances, viewport: (w, h))

            func cut(_ a: SIMD4<Int32>, _ b: SIMD4<Int32>) -> SIMD4<Int32> {
                let r = SIMD4<Int32>(max(a.x, b.x), max(a.y, b.y), min(a.z, b.z), min(a.w, b.w))
                return (r.z > r.x && r.w > r.y) ? r : .zero
            }

            var within = [UInt32](repeating: topLayer, count: scene.instances.count)
            var stack: [(SIMD4<Int32>, UInt32)] = []
            var n = 0
            while n < scene.instances.count {
                let inside = stack.last?.0
                within[n] = stack.last?.1 ?? topLayer
                if let p = scope[UInt32(n)] {
                    let l = layers[Int(p)]
                    if scene.instances[n].params.y == KIND_LAYER {
                        switch l.show {
                        case .hidden:
                            let endIdx = min(Int(l.end), bounds.count - 1)
                            if n <= endIdx {
                                for m in n...endIdx { bounds[m] = .zero }
                            }
                            n = Int(l.end) + 1
                            continue
                        case .flat:
                            bounds[n] = .zero
                        case .render:
                            bounds[n] = inside.map { cut(l.bounds, $0) } ?? l.bounds
                            stack.append((bounds[n], p))
                        }
                    } else if l.show == .render {
                        bounds[n] = stack.popLast()?.0 ?? .zero
                        within[n] = stack.last?.1 ?? topLayer
                    } else {
                        bounds[n] = .zero
                    }
                } else if let inside {
                    bounds[n] = cut(bounds[n], inside)
                }
                n += 1
            }

            var blurs: [(UInt32, CpuBootBackdrop.Record)] = []
            var quiet = [Bool](repeating: false, count: tiles)
            for (idx, inst) in scene.instances.enumerated() where inst.params.y == KIND_BACKDROP_BLUR {
                bounds[idx] = CpuBootBackdrop.bounds(inst, viewport: (w, h))
                if let rec = CpuBootBackdrop.plan(inst, viewport: (w, h)) {
                    for t in regionTiles(rec.region, cols: cols, rows: rows) {
                        quiet[t] = true
                    }
                    blurs.append((UInt32(idx), rec))
                }
            }

            var first = [UInt32](repeating: 0, count: tiles)
            for (idx, inst) in scene.instances.enumerated() {
                let b = bounds[idx]
                if b.z <= b.x || b.w <= b.y || within[idx] != topLayer { continue }
                guard let solid = opaqueBox(inst) else { continue }
                let clip = CpuBootShade.Clip.of(inst)
                let tx0 = (UInt32(b.x) + tileW - 1) / tileW
                let ty0 = (UInt32(b.y) + tileH - 1) / tileH
                let tx1 = min(UInt32(b.z) / tileW, cols)
                let ty1 = min(UInt32(b.w) / tileH, rows)
                if tx0 >= tx1 || ty0 >= ty1 { continue }
                for ty in ty0..<ty1 {
                    let y0 = Float(ty * tileH) + 0.5
                    let y1 = Float(min((ty + 1) * tileH, h)) - 0.5
                    let topSpan = intersect(solid.span(at: y0), clipSpan(clip, y: y0))
                    let botSpan = intersect(solid.span(at: y1), clipSpan(clip, y: y1))
                    for tx in tx0..<tx1 {
                        let tIdx = Int(ty * cols + tx)
                        if quiet[tIdx] { continue }
                        let x0 = Float(tx * tileW) + 0.5
                        let x1 = Float(min((tx + 1) * tileW, w)) - 0.5
                        if topSpan.0 <= x0 && topSpan.1 >= x1 && botSpan.0 <= x0 && botSpan.1 >= x1 {
                            first[tIdx] = UInt32(idx) + 1
                        }
                    }
                }
            }

            var count = [UInt32](repeating: 0, count: tiles + 1)
            var culled = 0
            func visitTiles(of idx: Int, _ fn: (Int) -> Void) {
                let b = bounds[idx]
                if b.z <= b.x || b.w <= b.y { return }
                let txStart = UInt32(b.x) / tileW
                let txEnd = (UInt32(b.z) + tileW - 1) / tileW
                let tyStart = UInt32(b.y) / tileH
                let tyEnd = (UInt32(b.w) + tileH - 1) / tileH
                for ty in tyStart..<tyEnd {
                    for tx in txStart..<txEnd {
                        fn(Int(ty * cols + tx))
                    }
                }
            }

            for idx in 0..<scene.instances.count {
                let idPlusOne = UInt32(idx) + 1
                visitTiles(of: idx) { t in
                    if idPlusOne >= first[t] {
                        count[t + 1] += 1
                    } else {
                        culled += 1
                    }
                }
            }
            for t in 0..<tiles {
                count[t + 1] += count[t]
            }

            var index = [UInt32](repeating: 0, count: Int(count[tiles]))
            var cursor = count
            for idx in 0..<scene.instances.count {
                let idPlusOne = UInt32(idx) + 1
                visitTiles(of: idx) { t in
                    if idPlusOne >= first[t] {
                        index[Int(cursor[t])] = UInt32(idx)
                        cursor[t] += 1
                    }
                }
            }

            return Bins(
                cols: cols,
                rows: rows,
                start: count,
                index: index,
                bounds: bounds,
                covered: first.map { $0 > 0 },
                within: within,
                blurs: blurs,
                quiet: quiet,
                culled: culled,
                layers: layers,
                scope: scope
            )
        }

        private static func planLayers(_ instances: [RenderInstance], viewport: (UInt32, UInt32)) -> ([PlannedLayer], [UInt32: UInt32]) {
            struct Open {
                var at: Int
                var edges: SIMD4<Float>
                var clip: SIMD4<Float>
                var limit: SIMD4<Float>
                var cache: Bool
            }
            var plans: [PlannedLayer] = []
            var scope: [UInt32: UInt32] = [:]
            var open: [Open] = []

            for (idx, i) in instances.enumerated() {
                if i.params.y == KIND_LAYER {
                    let parent = open.last?.at
                    let limit: SIMD4<Float>
                    if let p = open.last {
                        limit = SIMD4<Float>(max(p.clip.x, p.limit.x), max(p.clip.y, p.limit.y), min(p.clip.z, p.limit.z), min(p.clip.w, p.limit.w))
                    } else {
                        limit = NO_CLIP
                    }
                    let opacity = min(max(i.fill.w, 0.0), 1.0)
                    let hidden = opacity == 0.0 || (parent.map { plans[$0].show == .hidden } ?? false)
                    let cache = i.params.w == 1.0
                    let additive = i.params.x == 1.0
                    let additiveParent = parent.map { plans[$0].additive } ?? false
                    let hole = cache ? SIMD4<Float>.zero : i.radii
                    let flat = !cache && opacity == 1.0 && !additive && !additiveParent && i.fade.w == 0 && i.clip == NO_CLIP && hole.w == 0.0
                    let show: LayerShow = hidden ? .hidden : (flat ? .flat : .render)
                    scope[UInt32(idx)] = UInt32(plans.count)
                    open.append(Open(
                        at: plans.count,
                        edges: SIMD4<Float>(i.rect.x, i.rect.y, i.rect.x + i.rect.z, i.rect.y + i.rect.w),
                        clip: i.clip,
                        limit: limit,
                        cache: cache
                    ))
                    plans.append(PlannedLayer(begin: UInt32(idx), end: 0, show: show, bounds: .zero, additive: additive, hole: hole))
                } else if i.params.y == KIND_LAYER_END {
                    guard let o = open.popLast() else { continue }
                    scope[UInt32(idx)] = UInt32(o.at)
                    let e = o.edges
                    let vis = SIMD4<Float>(
                        floorf(max(0.0, max(e.x, max(o.clip.x, o.limit.x)))),
                        floorf(max(0.0, max(e.y, max(o.clip.y, o.limit.y)))),
                        ceilf(min(Float(viewport.0), min(e.z, min(o.clip.z, o.limit.z)))),
                        ceilf(min(Float(viewport.1), min(e.w, min(o.clip.w, o.limit.w))))
                    )
                    let edges = o.cache
                        ? SIMD4<Float>(floorf(e.x), floorf(e.y), ceilf(e.z), ceilf(e.w))
                        : vis
                    plans[o.at].end = UInt32(idx)
                    let shown = SIMD4<Float>(max(0.0, edges.x), max(0.0, edges.y), min(Float(viewport.0), edges.z), min(Float(viewport.1), edges.w))
                    plans[o.at].bounds = SIMD4<Int32>(Int32(shown.x), Int32(shown.y), Int32(shown.z), Int32(shown.w))
                    if edges.z <= edges.x || edges.w <= edges.y || (o.cache && (vis.z <= vis.x || vis.w <= vis.y)) {
                        plans[o.at].show = .hidden
                    }
                    if !open.isEmpty && !open[open.count - 1].cache {
                        let pe = open[open.count - 1].edges
                        open[open.count - 1].edges = SIMD4<Float>(min(pe.x, edges.x), min(pe.y, edges.y), max(pe.z, edges.z), max(pe.w, edges.w))
                    }
                } else if !open.isEmpty && !open[open.count - 1].cache {
                    var rect = i.rect
                    if i.params.y == KIND_GLYPH && i.params.x != 0.0 {
                        let s = sinf(i.params.x)
                        let c = cosf(i.params.x)
                        let rw = abs(c) * rect.z + abs(s) * rect.w
                        let rh = abs(s) * rect.z + abs(c) * rect.w
                        rect = SIMD4<Float>(rect.x + (rect.z - rw) * 0.5, rect.y + (rect.w - rh) * 0.5, rw, rh)
                    }
                    let k = i.params.y
                    let grow: Float
                    if k == KIND_GLYPH { grow = 0.0 }
                    else if k == KIND_SHADOW { grow = i.params.z * 3.0 + 1.0 }
                    else if k == KIND_EFFECT { grow = i.params.z + 1.0 }
                    else if k == KIND_RECT || k == KIND_GRADIENT || k == KIND_DASHED || k == KIND_RADIAL { grow = 1.0 + i.params.z * 2.0 }
                    else { grow = 1.0 }
                    let add = SIMD4<Float>(
                        max(rect.x - grow, i.clip.x),
                        max(rect.y - grow, i.clip.y),
                        min(rect.x + rect.z + grow, i.clip.z),
                        min(rect.y + rect.w + grow, i.clip.w)
                    )
                    let pe = open[open.count - 1].edges
                    open[open.count - 1].edges = SIMD4<Float>(min(pe.x, add.x), min(pe.y, add.y), max(pe.z, add.z), max(pe.w, add.w))
                }
            }
            for o in open {
                plans[o.at].show = .hidden
            }
            return (plans, scope)
        }
    }

    public static func regionTiles(_ reg: SIMD4<Float>, cols: UInt32, rows: UInt32) -> [Int] {
        let tx0 = UInt32(max(0, reg.x)) / tileW
        let tx1 = min((UInt32(max(0, ceilf(reg.z))) + tileW - 1) / tileW, cols)
        let ty0 = UInt32(max(0, reg.y)) / tileH
        let ty1 = min((UInt32(max(0, ceilf(reg.w))) + tileH - 1) / tileH, rows)
        if tx0 >= tx1 || ty0 >= ty1 { return [] }
        var out: [Int] = []
        for ty in ty0..<ty1 {
            for tx in tx0..<tx1 {
                out.append(Int(ty * cols + tx))
            }
        }
        return out
    }
}

// MARK: - Damage Hashing & Dirty Rect Merging (`cpu_boot/damage.rs`)

public enum CpuBootDamage {
    public struct InstanceHash: Sendable, Equatable {
        public let full: UInt64
        public let bounds: SIMD4<Int32>
        public let flat: SIMD4<Int32> // whole-pixel rect painted in one flat colour
        public let solid: Bool
        fileprivate let flatColor: UInt64
    }

    @inline(__always)
    private static func mixHash(_ h: UInt64, _ word: UInt32) -> UInt64 {
        (((h << 5) | (h >> 59)) ^ UInt64(word)) &* 0x517c_c1b7_2722_0a95
    }

    public static func hashWords(of inst: RenderInstance) -> UInt64 {
        var copy = inst
        return withUnsafeBytes(of: &copy) { raw in
            let words = raw.bindMemory(to: UInt32.self)
            var h: UInt64 = 0
            for w in words {
                h = ((h << 5 | h >> 59) ^ UInt64(w)) &* 0x517c_c1b7_2722_0a95
            }
            return h
        }
    }

    public static func hashInstance(_ scene: CpuBootScene, bins: CpuBootBin.Bins, index: Int) -> InstanceHash {
        var atlas = CpuBootAtlasDamage()
        _ = atlas.update(scene)
        return hashInstance(scene, bins: bins, index: index, atlas: &atlas)
    }

    static func hashInstance(_ scene: CpuBootScene, bins: CpuBootBin.Bins, index: Int,
                             atlas: inout CpuBootAtlasDamage) -> InstanceHash {
        let inst = scene.instances[index]
        var h = hashWords(of: inst)
        if inst.params.y == KIND_IMAGE || inst.params.y == KIND_GLYPH {
            let texels = atlas.sample(inst)
            h = mixHash(mixHash(h, UInt32(truncatingIfNeeded: texels)), UInt32(truncatingIfNeeded: texels >> 32))
            if inst.params.y == KIND_GLYPH { h = mixHash(h, UInt32(truncatingIfNeeded: scene.atlasResets)) }
        }
        if let p = bins.scope[UInt32(index)] {
            let l = bins.layers[Int(p)]
            h = mixHash(h, UInt32(truncatingIfNeeded: l.bounds.x))
            h = mixHash(h, UInt32(truncatingIfNeeded: l.bounds.y))
            h = mixHash(h, UInt32(truncatingIfNeeded: l.bounds.z))
            h = mixHash(h, UInt32(truncatingIfNeeded: l.bounds.w))
            h = mixHash(h, l.additive ? 1 : 0)
        }
        let b = bins.bounds[index]
        var flat = SIMD4<Int32>.zero
        var solid = false
        var flatColor: UInt64 = 0
        if inst.params.y == KIND_RECT, let s = CpuBootBin.interior(inst) {
            let clip = CpuBootShade.Clip.of(inst)
            let (top, bot) = s.bands()
            let inset = clip.inset()
            let clipBands = clip.radii.map { CpuBootBin.Solid(edges: clip.rect, radii: $0, inset: 0.5).bands() }
            let fx0 = ceilf(max(s.edges.x + s.inset, clip.rect.x + inset.x) - 0.5)
            let fy0 = ceilf(max(s.edges.y + top, clip.rect.y + max(inset.y, clipBands?.0 ?? 0)) - 0.5)
            let fx1 = floorf(min(s.edges.z - s.inset, clip.rect.z - inset.z) - 0.5) + 1.0
            let fy1 = floorf(min(s.edges.w - bot, clip.rect.w - max(inset.w, clipBands?.1 ?? 0)) - 0.5) + 1.0
            let ix0 = max(b.x, Int32(fx0))
            let iy0 = max(b.y, Int32(fy0))
            let ix1 = min(b.z, Int32(fx1))
            let iy1 = min(b.w, Int32(fy1))
            if ix1 > ix0 && iy1 > iy0 {
                flat = SIMD4<Int32>(ix0, iy0, ix1, iy1)
                solid = inst.fill.w >= 1.0 && bins.within[index] == CpuBootBin.topLayer
                flatColor = mixHash(mixHash(mixHash(mixHash(0x5a5a, inst.fill.x.bitPattern),
                                                     inst.fill.y.bitPattern), inst.fill.z.bitPattern), inst.fill.w.bitPattern)
            }
        }
        return InstanceHash(full: h, bounds: b, flat: flat, solid: solid, flatColor: flatColor)
    }

    public static func rehashTile(scene: CpuBootScene, bins: CpuBootBin.Bins, each: [InstanceHash], tile: Int) -> UInt64 {
        let tx = UInt32(tile) % bins.cols
        let ty = UInt32(tile) / bins.cols
        let rx0 = Int32(tx * CpuBootBin.tileW)
        let ry0 = Int32(ty * CpuBootBin.tileH)
        let rx1 = Int32(min((tx + 1) * CpuBootBin.tileW, UInt32(scene.size.0)))
        let ry1 = Int32(min((ty + 1) * CpuBootBin.tileH, UInt32(scene.size.1)))
        var h = mixHash(mixHash(0, scene.clear.x.bitPattern), scene.clear.y.bitPattern)
        h = mixHash(mixHash(h, scene.clear.z.bitPattern), scene.clear.w.bitPattern)
        // Binning already discarded every draw behind a fully covering opaque box.
        if bins.covered[tile] { h = 0 }
        h = mixHash(h, bins.quiet[tile] ? 1 : 0)
        for n in bins.tile(tile) {
            let ih = each[Int(n)]
            let flat = ih.flat.x <= rx0 && ih.flat.y <= ry0 && ih.flat.z >= rx1 && ih.flat.w >= ry1
            let token = flat ? ih.flatColor : ih.full
            h = ((h << 7 | h >> 57) ^ token) &* 0x517c_c1b7_2722_0a95
        }
        return h
    }

    public static func rects(dirtyTiles: [UInt32], cols: UInt32, size: (Int, Int), maxRects: Int) -> [[UInt32]] {
        guard !dirtyTiles.isEmpty, cols > 0, maxRects > 0 else { return [] }
        var runs: [[UInt32]] = []
        var index = 0
        while index < dirtyTiles.count {
            let first = dirtyTiles[index]
            let row = first / cols
            var last = first
            index += 1
            while index < dirtyTiles.count, dirtyTiles[index] == last + 1, dirtyTiles[index] / cols == row {
                last += 1
                index += 1
            }
            let x0 = (first % cols) * CpuBootBin.tileW
            let x1 = min((last % cols + 1) * CpuBootBin.tileW, UInt32(size.0))
            let y0 = row * CpuBootBin.tileH
            let y1 = min((row + 1) * CpuBootBin.tileH, UInt32(size.1))
            if let previous = runs.lastIndex(where: { $0[0] == x0 && $0[2] == x1 && $0[3] == y0 }) {
                runs[previous][3] = y1
            } else {
                runs.append([x0, y0, x1, y1])
            }
        }
        merge(&runs, maxRects: maxRects)
        return runs
    }

    /// A retained scroll moves pixels outside the freshly rasterized tiles; the canvas needs them too.
    static func add(_ rect: [UInt32], to rects: inout [[UInt32]], maxRects: Int) {
        rects.append(rect)
        merge(&rects, maxRects: maxRects)
    }

    private struct Nearest {
        var index: Int = .max
        var cost: UInt64 = .max

        mutating func consider(_ candidate: Int, cost: UInt64) {
            if cost < self.cost || (cost == self.cost && candidate < index) {
                index = candidate
                self.cost = cost
            }
        }
    }

    private typealias Bounds = SIMD4<UInt32>

    private static func enclosing(_ a: Bounds, _ b: Bounds) -> Bounds {
        Bounds(min(a.x, b.x), min(a.y, b.y), max(a.z, b.z), max(a.w, b.w))
    }

    private static func area(_ b: Bounds) -> UInt64 {
        UInt64(b.z - b.x) * UInt64(b.w - b.y)
    }

    private static func waste(_ a: Bounds, _ b: Bounds) -> UInt64 {
        let combined = area(enclosing(a, b))
        let covered = area(a) + area(b)
        return combined > covered ? combined - covered : 0
    }

    private static func nearest(after i: Int, in bounds: [Bounds]) -> Nearest {
        var result = Nearest()
        for j in (i + 1)..<bounds.count {
            result.consider(j, cost: waste(bounds[i], bounds[j]))
            if result.cost == 0 { break }
        }
        return result
    }

    /// Preserve Rust's least-waste pair and tie order without rescanning every possible
    /// pair after each merge. Only two slots change: the union and the moved last rectangle.
    private static func merge(_ rects: inout [[UInt32]], maxRects: Int) {
        guard rects.count > maxRects else { return }
        var boxes = rects.map { Bounds($0[0], $0[1], $0[2], $0[3]) }
        var candidates = boxes.indices.map { nearest(after: $0, in: boxes) }
        while boxes.count > maxRects {
            var first = 0
            for i in 1..<(boxes.count - 1) where candidates[i].cost < candidates[first].cost {
                first = i
                if candidates[i].cost == 0 { break }
            }
            let second = candidates[first].index, last = boxes.count - 1
            boxes[first] = enclosing(boxes[first], boxes[second])
            boxes.swapAt(second, last)
            boxes.removeLast()
            candidates.removeLast()
            for i in boxes.indices {
                let old = candidates[i].index
                if i == first || i == second || old == first || old == second || old == last {
                    candidates[i] = nearest(after: i, in: boxes)
                } else {
                    if i < first {
                        candidates[i].consider(first, cost: waste(boxes[i], boxes[first]))
                    }
                    if i < second && second < boxes.count {
                        candidates[i].consider(second, cost: waste(boxes[i], boxes[second]))
                    }
                }
            }
        }
        rects = boxes.map { [$0.x, $0.y, $0.z, $0.w] }
    }
}
