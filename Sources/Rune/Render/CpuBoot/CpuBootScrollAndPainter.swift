import Foundation
#if canImport(simd)
import simd
#endif

/// Persistent worker pool (`cpu_boot/pool.rs`), scroll-row mover (`cpu_boot/scroll.rs`),
/// incremental `CpuPainter` (`cpu_boot/painter.rs`), and top-level `CpuBoot.paint` (`cpu_boot.rs`).
public final class CpuBootPool: @unchecked Sendable {
    #if os(WASI)
    public init(threads: Int) {}
    public var threads: Int { 1 }
    public func run(extra: Int, _ job: @Sendable () -> Void) { job() }
    #else
    private final class SharedState: @unchecked Sendable {
        let cond = NSCondition()
        var leaving = false
        var round: UInt64 = 0
        var wanted: Int = 0
        var running: Int = 0
        var currentJobPtr: UnsafePointer<@Sendable () -> Void>?

        func work(index k: Int) {
            var lastRound: UInt64 = 0
            while true {
                var jobPtr: UnsafePointer<@Sendable () -> Void>?
                cond.lock()
                while !leaving {
                    if round != lastRound, let ptr = currentJobPtr {
                        lastRound = round
                        if k <= wanted {
                            jobPtr = ptr
                            break
                        }
                    }
                    cond.wait()
                }
                let shouldLeave = leaving
                cond.unlock()
                if shouldLeave { return }

                jobPtr?.pointee()

                cond.lock()
                running -= 1
                if running == 0 {
                    cond.broadcast()
                }
                cond.unlock()
            }
        }
    }

    private let state = SharedState()
    private var workers: [Thread] = []

    public init(threads: Int) {
        let count = max(1, threads)
        let shared = self.state
        for k in 1..<count {
            let thread = Thread {
                shared.work(index: k)
            }
            thread.name = "rune-cpu-paint-\(k)"
            workers.append(thread)
            thread.start()
        }
    }

    deinit {
        state.cond.lock()
        state.leaving = true
        state.cond.broadcast()
        state.cond.unlock()
    }

    public var threads: Int { workers.count + 1 }

    public func run(extra: Int, _ job: @Sendable () -> Void) {
        let clampedExtra = min(max(0, extra), workers.count)
        if clampedExtra == 0 {
            job()
            return
        }
        withoutActuallyEscaping(job) { escapingJob in
            withUnsafePointer(to: escapingJob) { ptr in
                state.cond.lock()
                if state.running > 0 || state.leaving {
                    state.cond.unlock()
                    ptr.pointee()
                    return
                }
                state.round &+= 1
                state.wanted = clampedExtra
                state.running = clampedExtra
                state.currentJobPtr = ptr
                state.cond.broadcast()
                state.cond.unlock()

                ptr.pointee()

                state.cond.lock()
                while state.running > 0 {
                    state.cond.wait()
                }
                state.currentJobPtr = nil
                state.cond.unlock()
            }
        }
    }
    #endif
}

private struct PoolThreadsExec: CpuBootExec {
    let pool: CpuBootPool
    let extra: Int
    var threads: Int { extra + 1 }
    func run(_ job: @Sendable () -> Void) {
        pool.run(extra: extra, job)
    }
}

public enum CpuBootScroll {
    public struct Prev: Sendable {
        public let instances: [RenderInstance]
        public let bins: CpuBootBin.Bins
    }

    public struct Shift: Sendable {
        public let rect: [UInt32] // [x0, y0, x1, y1]
        public let dy: Int32
        public let clean: [Bool]
    }

    private static let rectYWord = 1
    private static let clipY0Word = 25
    private static let clipY1Word = 27

    private static func instanceWords(_ inst: RenderInstance) -> [UInt32] {
        var copy = inst
        return withUnsafeBytes(of: &copy) { raw in
            Array(raw.bindMemory(to: UInt32.self))
        }
    }

    private static func key(of inst: RenderInstance) -> UInt64 {
        let words = instanceWords(inst)
        var h: UInt64 = 0
        for (k, w) in words.enumerated() {
            if k == rectYWord || k == clipY0Word || k == clipY1Word { continue }
            h = ((h << 5 | h >> 59) ^ UInt64(w)) &* 0x517c_c1b7_2722_0a95
        }
        return h
    }

    private static func isMovable(_ kind: Float) -> Bool {
        let k = UInt32(kind)
        return (k <= 4) || (k >= 7 && k <= 11)
    }

    public static func plan(
        prev: Prev,
        scene: CpuBootScene,
        bins: CpuBootBin.Bins,
        exec: any CpuBootExec
    ) -> Shift? {
        let old = prev.instances
        @inline(__always)
        func isVoter(_ i: RenderInstance) -> Bool {
            i.params.y == KIND_GLYPH || i.params.y == KIND_RECT
        }

        var byKey: [(UInt64, UInt32)] = []
        byKey.reserveCapacity(old.count)
        for (m, inst) in old.enumerated() where isVoter(inst) {
            byKey.append((key(of: inst), UInt32(m)))
        }
        byKey.sort { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            return lhs.1 < rhs.1
        }

        struct VoteKey: Equatable {
            let dy: Int32
            let c0: UInt32
            let c1: UInt32
            let c2: UInt32
            let c3: UInt32
        }
        var votes: [(VoteKey, UInt32)] = []

        let sceneH = Float(scene.size.1)
        for inst in scene.instances where isVoter(inst) {
            let k = key(of: inst)
            var lo = 0
            var hi = byKey.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if byKey[mid].0 < k { lo = mid + 1 } else { hi = mid }
            }
            var bestDy: Float? = nil
            for idx in lo..<byKey.count {
                if byKey[idx].0 != k { break }
                let o = old[Int(byKey[idx].1)]
                if inst.clip != o.clip { continue }
                let dy = inst.rect.y - o.rect.y
                if dy.truncatingRemainder(dividingBy: 1.0) != 0.0 || fabsf(dy) >= sceneH { continue }
                if let current = bestDy {
                    if fabsf(dy) < fabsf(current) { bestDy = dy }
                } else {
                    bestDy = dy
                }
            }
            guard let dy = bestDy else { continue }
            let vk = VoteKey(
                dy: Int32(dy),
                c0: inst.clip.x.bitPattern,
                c1: inst.clip.y.bitPattern,
                c2: inst.clip.z.bitPattern,
                c3: inst.clip.w.bitPattern
            )
            if let existing = votes.firstIndex(where: { $0.0 == vk }) {
                votes[existing].1 += 1
            } else {
                votes.append((vk, 1))
            }
        }

        guard let topVote = votes.filter({ $0.0.dy != 0 }).max(by: { $0.1 < $1.1 }) else { return nil }
        let dy = topVote.0.dy
        let count = topVote.1
        let zeroVote = VoteKey(dy: 0, c0: topVote.0.c0, c1: topVote.0.c1, c2: topVote.0.c2, c3: topVote.0.c3)
        if count < 8 || votes.contains(where: { $0.0 == zeroVote && $0.1 >= count }) {
            return nil
        }

        let clip = SIMD4<Float>(
            Float(bitPattern: topVote.0.c0),
            Float(bitPattern: topVote.0.c1),
            Float(bitPattern: topVote.0.c2),
            Float(bitPattern: topVote.0.c3)
        )
        var probe = RenderInstance.zero
        probe.clip = clip
        let c = CpuBootShade.Clip.of(probe)
        let inset = c.inset()
        let w = Float(scene.size.0)
        let h = Float(scene.size.1)
        let whole = SIMD4<Float>(
            max(clip.x + inset.x, 0.0),
            max(clip.y + inset.y, 0.0),
            min(clip.z - inset.z, w),
            min(clip.w - inset.w, h)
        )
        let y0 = max(whole.y, whole.y + Float(dy))
        let y1 = min(whole.w, whole.w + Float(dy))
        let rx0 = UInt32(max(0, Int32(ceilf(whole.x - 0.5))))
        let ry0 = UInt32(max(0, Int32(ceilf(y0 - 0.5))))
        let rx1 = UInt32(max(0, Int32(floorf(whole.z - 0.5) + 1.0)))
        let ry1 = UInt32(max(0, Int32(floorf(y1 - 0.5) + 1.0)))
        if rx1 <= rx0 || ry1 <= ry0 { return nil }
        if prev.bins.cols != bins.cols { return nil }

        let tileCount = bins.tileCount
        final class CleanFlags: @unchecked Sendable {
            let lock = NSLock()
            var nextRow: UInt32 = 0
            var clean: [Bool]
            init(count: Int) {
                self.clean = [Bool](repeating: false, count: count)
            }
            func next(rows: UInt32) -> UInt32? {
                lock.lock()
                defer { lock.unlock() }
                if nextRow >= rows { return nil }
                let ty = nextRow
                nextRow += 1
                return ty
            }
        }
        let state = CleanFlags(count: tileCount)
        let rect = [rx0, ry0, rx1, ry1]
        let sw = UInt32(scene.size.0)
        let sh = UInt32(scene.size.1)

        exec.run {
            while let ty = state.next(rows: bins.rows) {
                for tx in 0..<bins.cols {
                    let t = Int(ty * bins.cols + tx)
                    let r = SIMD4<Int32>(
                        Int32(tx * CpuBootBin.tileW),
                        Int32(ty * CpuBootBin.tileH),
                        Int32(min((tx + 1) * CpuBootBin.tileW, sw)),
                        Int32(min((ty + 1) * CpuBootBin.tileH, sh))
                    )
                    if !bins.quiet[t] && tileMoved(prev: prev, scene: scene, bins: bins, tile: t, r: r, dy: dy) {
                        state.clean[t] = true
                    }
                }
            }
        }
        return Shift(rect: rect, dy: dy, clean: state.clean)
    }

    private static func tileMoved(
        prev: Prev,
        scene: CpuBootScene,
        bins: CpuBootBin.Bins,
        tile t: Int,
        r: SIMD4<Int32>,
        dy: Int32
    ) -> Bool {
        let back = SIMD4<Int32>(r.x, r.y - dy, r.z, r.w - dy)
        if back.y < 0 || back.w > Int32(scene.size.1) { return false }
        let ob = prev.bins
        let tx = UInt32(r.x) / CpuBootBin.tileW
        let oty = UInt32(back.y) / CpuBootBin.tileH
        let upper = ob.tile(Int(oty * ob.cols + tx))
        let lowerDiv = (UInt32(back.w) + CpuBootBin.tileH - 1) / CpuBootBin.tileH
        let lower: ArraySlice<UInt32> = (lowerDiv > oty + 1 && oty + 1 < ob.rows)
            ? ob.tile(Int((oty + 1) * ob.cols + tx))
            : []

        @inline(__always)
        func reaches(_ m: UInt32) -> Bool {
            let b = ob.bounds[Int(m)]
            return b.x < back.z && b.z > back.x && b.y < back.w && b.w > back.y
        }

        var a = upper.startIndex
        var b = lower.startIndex
        func nextOld() -> UInt32? {
            while true {
                let m: UInt32
                if a < upper.endIndex && b < lower.endIndex {
                    let x = upper[a]
                    let y = lower[b]
                    if x == y { a += 1; b += 1; m = x }
                    else if x < y { a += 1; m = x }
                    else { b += 1; m = y }
                } else if a < upper.endIndex {
                    m = upper[a]; a += 1
                } else if b < lower.endIndex {
                    m = lower[b]; b += 1
                } else {
                    return nil
                }
                if reaches(m) { return m }
            }
        }

        @inline(__always)
        func cut(_ a: SIMD4<Int32>, _ b: SIMD4<Int32>) -> SIMD4<Int32> {
            let c = SIMD4<Int32>(max(a.x, b.x), max(a.y, b.y), min(a.z, b.z), min(a.w, b.w))
            return (c.z > c.x && c.w > c.y) ? c : .zero
        }
        let both = SIMD4<Float>(
            Float(r.x),
            Float(min(r.y, back.y)),
            Float(r.z),
            Float(max(r.w, back.w))
        )
        for n in bins.tile(t) {
            guard let m = nextOld() else { return false }
            let newR = cut(bins.bounds[Int(n)], r)
            let oldR = cut(prev.bins.bounds[Int(m)], back)
            let shifted = SIMD4<Int32>(oldR.x, oldR.y &+ dy, oldR.z, oldR.w &+ dy)
            guard newR == shifted,
                  sameInstance(scene: scene, bins: bins, prev: prev, n: n, m: m, dy: dy, both: both) else {
                return false
            }
        }
        return nextOld() == nil
    }

    private static func sameInstance(
        scene: CpuBootScene,
        bins: CpuBootBin.Bins,
        prev: Prev,
        n: UInt32,
        m: UInt32,
        dy: Int32,
        both: SIMD4<Float>
    ) -> Bool {
        let a = scene.instances[Int(n)]
        let b = prev.instances[Int(m)]
        if !isMovable(a.params.y) { return false }
        let marker = a.params.y == KIND_LAYER || a.params.y == KIND_LAYER_END
        let wa = instanceWords(a)
        let wb = instanceWords(b)
        if wa == wb {
            if marker {
                return layerSame(bins: bins, prev: prev, n: n, m: m, dy: 0) && layerCovers(scene: scene, bins: bins, n: n, both: both)
            }
            return flatOver(a, both) || rowsAlike(a, both)
        }
        for k in 0..<32 where k != rectYWord && k != clipY0Word && k != clipY1Word {
            if wa[k] != wb[k] { return false }
        }
        if a.rect.y != b.rect.y + Float(dy) { return false }
        let clipMoved = a.clip.y == b.clip.y + Float(dy) && a.clip.w == b.clip.w + Float(dy)
        let clipKept = a.clip.y == b.clip.y && a.clip.w == b.clip.w && clipRowsAlike(CpuBootShade.Clip.of(a), both)
        if !clipMoved && !clipKept { return false }
        return !marker || layerSame(bins: bins, prev: prev, n: n, m: m, dy: dy)
    }

    private static func layerSame(bins: CpuBootBin.Bins, prev: Prev, n: UInt32, m: UInt32, dy: Int32) -> Bool {
        guard let p = bins.scope[n], let q = prev.bins.scope[m] else { return false }
        let l = bins.layers[Int(p)]
        let o = prev.bins.layers[Int(q)]
        return l.show == o.show
            && l.additive == o.additive
            && l.hole == o.hole
            && l.bounds == SIMD4<Int32>(o.bounds.x, o.bounds.y + dy, o.bounds.z, o.bounds.w + dy)
    }

    private static func layerCovers(scene: CpuBootScene, bins: CpuBootBin.Bins, n: UInt32, both: SIMD4<Float>) -> Bool {
        guard let p = bins.scope[n] else { return false }
        let l = bins.layers[Int(p)]
        if l.show != .render { return true }
        let begin = scene.instances[Int(l.begin)]
        return l.hole.w <= 0.0
            && Float(l.bounds.y) <= both.y
            && Float(l.bounds.w) >= both.w
            && clipRowsAlike(CpuBootShade.Clip.of(begin), both)
    }

    private static func rowsAlike(_ i: RenderInstance, _ r: SIMD4<Float>) -> Bool {
        let top = r.y + 0.5
        let bottom = r.w - 0.5
        func middle(_ margin: Float) -> Bool {
            top >= i.rect.y + margin && bottom <= i.rect.y + i.rect.w - margin
        }
        let reach = max(max(abs(i.radii.x), abs(i.radii.y)), max(abs(i.radii.z), abs(i.radii.w)))
        let kind = UInt32(i.params.y)
        let alike: Bool
        if kind == 0 {
            alike = !CpuBootShade.hasSides(i) && middle(reach + 4.0 * (max(i.params.x, 0.0) + max(i.params.z, 0.5)) + 4.0)
        } else if kind == 1 {
            if i.uv.z > 0.0 {
                alike = false
            } else {
                let halfX = i.rect.z * 0.5
                let halfY = i.rect.w * 0.5
                let corner = min(abs(i.radii.x), min(halfX, halfY))
                alike = middle(corner + 6.0 * max(i.params.z, 0.01) + 1.0)
            }
        } else {
            alike = false
        }
        return alike && clipRowsAlike(CpuBootShade.Clip.of(i), r)
    }

    private static func clipRowsAlike(_ c: CpuBootShade.Clip, _ r: SIMD4<Float>) -> Bool {
        let inset = c.inset()
        var top = inset.y
        var bottom = inset.w
        if let radii = c.radii {
            let (t, b) = CpuBootBin.Solid(edges: c.rect, radii: radii, inset: 0.5).bands()
            top = max(top, t + 1.0)
            bottom = max(bottom, b + 1.0)
        }
        return r.y + 0.5 >= c.rect.y + top && r.w - 0.5 <= c.rect.w - bottom
    }

    private static func flatOver(_ i: RenderInstance, _ r: SIMD4<Float>) -> Bool {
        guard i.params.y == KIND_RECT, let s = CpuBootBin.interior(i) else { return false }
        return CpuBootBin.covers(s, clip: CpuBootShade.Clip.of(i), r: r)
    }

    static func moveTiles(
        exec: any CpuBootExec,
        target: inout CpuBootTarget,
        size: (Int, Int),
        cols: UInt32,
        clean: [Bool],
        dy: Int32
    ) {
        let sw = UInt32(size.0)
        let sh = UInt32(size.1)
        let rows = (sh + CpuBootBin.tileH - 1) / CpuBootBin.tileH
        let stride = target.stride
        let len = target.pixels.count

        final class ColumnCounter: @unchecked Sendable {
            let lock = NSLock()
            var nextCol: UInt32 = 0
            func take(_ maxCols: UInt32) -> UInt32? {
                lock.lock()
                defer { lock.unlock() }
                if nextCol >= maxCols { return nil }
                let tx = nextCol
                nextCol += 1
                return tx
            }
        }
        let counter = ColumnCounter()
        target.pixels.withUnsafeMutableBufferPointer { buf in
            let rawBase = UInt(bitPattern: buf.baseAddress)
            exec.run {
                guard let base = UnsafeMutablePointer<UInt8>(bitPattern: rawBase) else { return }
                while let tx = counter.take(cols) {
                    let x0 = tx * CpuBootBin.tileW
                    let x1 = min((tx + 1) * CpuBootBin.tileW, sw)
                    let bytes = Int(x1 - x0) * 4
                    @inline(__always)
                    func copyRow(_ y: UInt32) {
                        let src = (Int(y) - Int(dy)) * stride + Int(x0) * 4
                        let dst = Int(y) * stride + Int(x0) * 4
                        precondition(src >= 0 && dst >= 0 && src + bytes <= len && dst + bytes <= len)
                        memcpy(base.advanced(by: dst), base.advanced(by: src), bytes)
                    }
                    @inline(__always)
                    func moved(_ ty: UInt32) -> Bool { clean[Int(ty * cols + tx)] }
                    if dy > 0 {
                        for ty in (0..<rows).reversed() where moved(ty) {
                            let y0 = ty * CpuBootBin.tileH
                            let y1 = min((ty + 1) * CpuBootBin.tileH, sh)
                            for y in (y0..<y1).reversed() { copyRow(y) }
                        }
                    } else {
                        for ty in 0..<rows where moved(ty) {
                            let y0 = ty * CpuBootBin.tileH
                            let y1 = min((ty + 1) * CpuBootBin.tileH, sh)
                            for y in y0..<y1 { copyRow(y) }
                        }
                    }
                }
            }
        }
    }
}

/// Incremental live CPU painter (`cpu_boot::CpuPainter`).
public final class CpuPainter {
    private static let maxRects = 8
    private static let tilesPerThread = 24
    private static let minScrollTiles = 16
    private static let recolouredMax = 256

    private struct SceneFlags: Equatable {
        let lcd: Bool
        let srgbBlend: Bool
        let nativeSurfaces: Bool
        let compositor: Bool
        let smoothing: FontSmoothing?
        let hasOutlines: Bool
        let outlines: CpuBootScene.OutlineVersion?
        let half: HalfRounding
    }

    private let pool: CpuBootPool
    private var hashes: [UInt64] = []
    private var nextHashes: [UInt64] = []
    private var each: [CpuBootDamage.InstanceHash] = []
    private var size: (Int, Int) = (0, 0)
    private var stride: Int = 0
    private var dirty: [UInt32] = []
    private var prev: CpuBootScroll.Prev? = nil
    private var resets: Int = 0
    private var flags: SceneFlags? = nil
    private var clear: SIMD4<Float>?
    private var atlas = CpuBootAtlasDamage()
    private var changed: [UInt32] = []
    private var marked: [Bool] = []

    public init(threads: Int = 4) {
        self.pool = CpuBootPool(threads: threads)
    }

    func attachMasks(to atlas: GlyphAtlas) { atlas.fillMasks(on: pool) }

    public func forget() {
        hashes.removeAll()
        prev = nil
        flags = nil
        clear = nil
        atlas = CpuBootAtlasDamage()
    }

    private func sceneFlags(_ scene: CpuBootScene) -> SceneFlags {
        SceneFlags(
            lcd: scene.lcd,
            srgbBlend: scene.srgbBlend,
            nativeSurfaces: scene.nativeSurfaces,
            compositor: scene.compositor,
            smoothing: scene.smoothing,
            hasOutlines: scene.outlines != nil,
            outlines: scene.outlineVersion,
            half: scene.half
        )
    }

    public func paint(_ scene: CpuBootScene, into target: inout CpuBootTarget) throws -> CpuBootPainted {
        try CpuBoot.checkTarget(scene: scene, target: target)
        let start = RuneExecutionContext.uptimeNanoseconds

        let currentFlags = sceneFlags(scene)
        let sameInstances = matchesPreviousInstances(scene.instances)
        // A GPU-only frame never reached the target. Keep the last accepted atlas and tile hashes.
        if flags != currentFlags || !sameInstances, let why = scene.needsGpu() { throw why }
        let atlasChanged = atlas.update(scene)
        let sameClear = clear == scene.clear
        if flags == currentFlags, sameClear,
           let fast = tryRecoloured(scene, target: &target, start: start, atlasChanged: atlasChanged,
                                    sameInstances: sameInstances) {
            return fast
        }
        if flags != currentFlags { hashes.removeAll(keepingCapacity: true) }
        flags = currentFlags
        clear = scene.clear

        let bins = CpuBootBin.Bins.build(for: scene)
        let binned = RuneExecutionContext.uptimeNanoseconds

        each.removeAll(keepingCapacity: true)
        each.reserveCapacity(scene.instances.count)
        for n in 0..<scene.instances.count {
            each.append(CpuBootDamage.hashInstance(scene, bins: bins, index: n, atlas: &atlas))
        }
        nextHashes.removeAll(keepingCapacity: true)
        nextHashes.reserveCapacity(bins.tileCount)
        for t in 0..<bins.tileCount {
            nextHashes.append(CpuBootDamage.rehashTile(scene: scene, bins: bins, each: each, tile: t))
        }

        if stride != target.stride {
            hashes.removeAll()
        }
        dirty.removeAll(keepingCapacity: true)
        let all = hashes.isEmpty
        let resized = size != scene.size
        let oldSize = size
        let ocols = (UInt32(max(0, oldSize.0)) + CpuBootBin.tileW - 1) / CpuBootBin.tileW

        func whole(_ tx: UInt32, _ ty: UInt32, _ s: (Int, Int)) -> Bool {
            Int((tx + 1) * CpuBootBin.tileW) <= s.0 && Int((ty + 1) * CpuBootBin.tileH) <= s.1
        }
        func before(_ t: Int) -> UInt64? {
            if all { return nil }
            if !resized { return hashes[t] }
            let tx = UInt32(t) % bins.cols
            let ty = UInt32(t) / bins.cols
            guard whole(tx, ty, oldSize) && whole(tx, ty, scene.size) else { return nil }
            return hashes[Int(ty * ocols + tx)]
        }
        func hashChanged(_ t: Int) -> Bool { before(t) != nextHashes[t] }

        var redo = [Bool](repeating: false, count: nextHashes.count)
        for (_, rec) in bins.blurs {
            let regTiles = CpuBootBin.regionTiles(rec.region, cols: bins.cols, rows: bins.rows)
            if all || regTiles.contains(where: hashChanged) {
                for t in regTiles { redo[t] = true }
            }
        }
        func isChanged(_ t: Int) -> Bool { redo[t] || hashChanged(t) }
        let byHash = (0..<nextHashes.count).reduce(0) { $0 + (isChanged($1) ? 1 : 0) }

        let planning = RuneExecutionContext.uptimeNanoseconds
        let candidateShift: CpuBootScroll.Shift?
        if all || resized || atlasChanged || resets != scene.atlasResets || !sameClear || byHash < Self.minScrollTiles {
            candidateShift = nil
        } else if let prev {
            candidateShift = CpuBootScroll.plan(
                prev: prev,
                scene: scene,
                bins: bins,
                exec: PoolThreadsExec(pool: pool, extra: max(0, pool.threads - 1))
            )
        } else {
            candidateShift = nil
        }

        func touched(_ s: CpuBootScroll.Shift, _ t: Int) -> Bool {
            let tx = UInt32(t) % bins.cols
            let ty = UInt32(t) / bins.cols
            return tx * CpuBootBin.tileW < s.rect[2]
                && (tx + 1) * CpuBootBin.tileW > s.rect[0]
                && ty * CpuBootBin.tileH < s.rect[3]
                && (ty + 1) * CpuBootBin.tileH > s.rect[1]
        }
        func isDirty(_ s: CpuBootScroll.Shift?, _ t: Int) -> Bool {
            if let s, touched(s, t) {
                return bins.quiet[t] || !s.clean[t]
            }
            return isChanged(t)
        }

        let shift = candidateShift.flatMap { s in
            let count = (0..<nextHashes.count).reduce(0) { $0 + (isDirty(s, $1) ? 1 : 0) }
            return count < byHash ? s : nil
        }

        let moving = RuneExecutionContext.uptimeNanoseconds
        if let shift {
            let cleanCount = shift.clean.reduce(0) { $0 + ($1 ? 1 : 0) }
            let movers = min(cleanCount / Self.tilesPerThread, max(0, pool.threads - 1))
            CpuBootScroll.moveTiles(
                exec: PoolThreadsExec(pool: pool, extra: movers),
                target: &target,
                size: scene.size,
                cols: bins.cols,
                clean: shift.clean,
                dy: shift.dy
            )
        }
        let moved = RuneExecutionContext.uptimeNanoseconds

        for t in 0..<nextHashes.count where isDirty(shift, t) {
            dirty.append(UInt32(t))
        }
        swap(&hashes, &nextHashes)
        size = scene.size
        stride = target.stride
        resets = scene.atlasResets

        let hashed = RuneExecutionContext.uptimeNanoseconds
        let extra = min(dirty.count / Self.tilesPerThread, max(0, pool.threads - 1))
        var report = CpuBootRaster.run(
            scene: scene,
            bins: bins,
            target: &target,
            tiles: dirty,
            exec: PoolThreadsExec(pool: pool, extra: extra),
            wide: PoolThreadsExec(pool: pool, extra: max(0, pool.threads - 1))
        )
        let done = RuneExecutionContext.uptimeNanoseconds
        report.binNs = binned &- start
        report.rasterNs = done &- hashed
        report.totalNs = done &- start
        report.tiles = bins.tileCount
        report.binned = bins.totalBinned
        report.culled = bins.culled

        var rects = CpuBootDamage.rects(dirtyTiles: dirty, cols: bins.cols, size: scene.size, maxRects: Self.maxRects)
        if let shift {
            CpuBootDamage.add(shift.rect, to: &rects, maxRects: Self.maxRects)
        }
        let scrolled: (Int32, Int)? = shift.map { ($0.dy, Int($0.rect[1])) }
        prev = CpuBootScroll.Prev(instances: scene.instances, bins: bins)

        return CpuBootPainted(
            dirtyTiles: dirty.count,
            tiles: report.tiles,
            rects: rects,
            scrolled: scrolled,
            scrolledRect: shift?.rect,
            hashNs: hashed &- binned,
            planNs: moving &- planning,
            moveNs: moved &- moving,
            report: report
        )
    }

    private func matchesPreviousInstances(_ instances: [RenderInstance]) -> Bool {
        guard let previous = prev?.instances, instances.count == previous.count else { return false }
        return instances.withUnsafeBytes { lhs in
            previous.withUnsafeBytes { rhs in
                lhs.isEmpty || lhs.baseAddress == rhs.baseAddress || memcmp(lhs.baseAddress!, rhs.baseAddress!, lhs.count) == 0
            }
        }
    }

    private func tryRecoloured(
        _ scene: CpuBootScene,
        target: inout CpuBootTarget,
        start: UInt64,
        atlasChanged: Bool,
        sameInstances: Bool
    ) -> CpuBootPainted? {
        guard let prev else { return nil }
        if hashes.isEmpty
            || size != scene.size
            || stride != target.stride
            || prev.instances.count != scene.instances.count
            || resets != scene.atlasResets {
            return nil
        }

        if !atlasChanged && sameInstances {
            let elapsed = RuneExecutionContext.uptimeNanoseconds &- start
            var report = CpuBootReport()
            report.totalNs = elapsed
            report.tiles = prev.bins.tileCount
            return CpuBootPainted(
                dirtyTiles: 0,
                tiles: report.tiles,
                rects: [],
                scrolled: nil,
                hashNs: elapsed,
                planNs: 0,
                moveNs: 0,
                report: report
            )
        }

        changed.removeAll(keepingCapacity: true)
        for n in 0..<scene.instances.count {
            let newInst = scene.instances[n]
            let oldInst = prev.instances[n]
            var newCopy = newInst
            var oldCopy = oldInst
            let instEqual = withUnsafeBytes(of: &newCopy) { a in
                withUnsafeBytes(of: &oldCopy) { b in
                    memcmp(a.baseAddress!, b.baseAddress!, MemoryLayout<RenderInstance>.size) == 0
                }
            }
            let sampled = newInst.params.y == KIND_IMAGE || newInst.params.y == KIND_GLYPH
            let same = instEqual && !(sampled && atlasChanged
                && CpuBootDamage.hashInstance(scene, bins: prev.bins, index: n, atlas: &atlas) != each[n])
            if same { continue }
            if changed.count == Self.recolouredMax || !isRecolour(newInst, oldInst) {
                return nil
            }
            changed.append(UInt32(n))
        }

        let bins = prev.bins
        let tiles = bins.tileCount
        marked = [Bool](repeating: false, count: tiles)
        for n in changed {
            let b = bins.bounds[Int(n)]
            if b.z <= b.x || b.w <= b.y { continue }
            let tx0 = UInt32(max(0, b.x)) / CpuBootBin.tileW
            let tx1 = min((UInt32(max(0, b.z)) + CpuBootBin.tileW - 1) / CpuBootBin.tileW, bins.cols)
            let ty0 = UInt32(max(0, b.y)) / CpuBootBin.tileH
            let ty1 = min((UInt32(max(0, b.w)) + CpuBootBin.tileH - 1) / CpuBootBin.tileH, bins.rows)
            for ty in ty0..<ty1 {
                for tx in tx0..<tx1 {
                    marked[Int(ty * bins.cols + tx)] = true
                }
            }
        }
        for (_, rec) in bins.blurs {
            let regTiles = CpuBootBin.regionTiles(rec.region, cols: bins.cols, rows: bins.rows)
            if regTiles.contains(where: { marked[$0] }) {
                for t in regTiles { marked[t] = true }
            }
        }
        dirty.removeAll(keepingCapacity: true)
        for t in 0..<tiles where marked[t] {
            dirty.append(UInt32(t))
        }
        for n in changed {
            let idx = Int(n)
            each[idx] = CpuBootDamage.hashInstance(scene, bins: bins, index: idx, atlas: &atlas)
        }
        self.prev = CpuBootScroll.Prev(instances: scene.instances, bins: bins)
        for t in dirty {
            hashes[Int(t)] = CpuBootDamage.rehashTile(scene: scene, bins: bins, each: each, tile: Int(t))
        }
        let hashed = RuneExecutionContext.uptimeNanoseconds
        let extra = min(dirty.count / Self.tilesPerThread, max(0, pool.threads - 1))
        var report: CpuBootReport
        if dirty.isEmpty {
            report = CpuBootReport()
        } else {
            report = CpuBootRaster.run(
                scene: scene,
                bins: bins,
                target: &target,
                tiles: dirty,
                exec: PoolThreadsExec(pool: pool, extra: extra),
                wide: PoolThreadsExec(pool: pool, extra: max(0, pool.threads - 1))
            )
        }
        let done = RuneExecutionContext.uptimeNanoseconds
        report.rasterNs = done &- hashed
        report.totalNs = done &- start
        report.tiles = tiles
        let rects = CpuBootDamage.rects(dirtyTiles: dirty, cols: bins.cols, size: scene.size, maxRects: Self.maxRects)
        return CpuBootPainted(
            dirtyTiles: dirty.count,
            tiles: tiles,
            rects: rects,
            scrolled: nil,
            hashNs: hashed &- start,
            planNs: 0,
            moveNs: 0,
            report: report
        )
    }

    private func isRecolour(_ newInst: RenderInstance, _ oldInst: RenderInstance) -> Bool {
        let kind = newInst.params.y
        if kind == KIND_LAYER || kind == KIND_LAYER_END || kind == KIND_BACKDROP_BLUR || kind == KIND_EFFECT {
            return false
        }
        let k = UInt32(kind)
        let borderChanges = (k == 0 || k == 4 || k == 10 || k == 11)
        let shadingWChanges = (k == 0 || k == 2)
        var nc = newInst
        var oc = oldInst
        let sameWords = withUnsafeBytes(of: &nc) { ra in
            withUnsafeBytes(of: &oc) { rb in
                let a = ra.bindMemory(to: UInt32.self)
                let b = rb.bindMemory(to: UInt32.self)
                for idx in 0..<32 {
                    if idx >= 8 && idx < 12 { continue }
                    if idx >= 12 && idx < 16 && borderChanges { continue }
                    if idx == 19 && shadingWChanges { continue }
                    if a[idx] != b[idx] { return false }
                }
                return true
            }
        }
        return sameWords && CpuBootBin.opaqueBox(newInst) == CpuBootBin.opaqueBox(oldInst)
    }
}

/// Top-level one-shot CPU boot entry point (`cpu_boot::paint`).
public enum CpuBoot {
    public static func checkTarget(scene: CpuBootScene, target: CpuBootTarget) throws {
        if target.width != scene.size.0
            || target.height != scene.size.1
            || target.stride < scene.size.0 * 4
            || (scene.size.1 > 0 && target.pixels.count < scene.size.1 * target.stride) {
            throw NeedsGpu.target
        }
    }

    public static func paint(
        _ scene: CpuBootScene,
        into target: inout CpuBootTarget,
        threads: Int = 1
    ) throws -> CpuBootReport {
        try checkTarget(scene: scene, target: target)
        if let why = scene.needsGpu() {
            throw why
        }
        let started = RuneExecutionContext.uptimeNanoseconds
        let bins = CpuBootBin.Bins.build(for: scene)
        let binned = RuneExecutionContext.uptimeNanoseconds
        let exec = CpuBootSpawnExec(threads)
        let allTiles = (0..<UInt32(bins.tileCount)).map { $0 }
        var report = CpuBootRaster.run(
            scene: scene,
            bins: bins,
            target: &target,
            tiles: allTiles,
            exec: exec,
            wide: exec
        )
        let done = RuneExecutionContext.uptimeNanoseconds
        report.binNs = binned &- started
        report.rasterNs = done &- binned
        report.totalNs = done &- started
        report.tiles = bins.tileCount
        report.binned = bins.totalBinned
        report.culled = bins.culled
        return report
    }
}
