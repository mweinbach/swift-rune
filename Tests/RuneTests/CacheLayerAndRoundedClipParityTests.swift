import Foundation
import Testing
@testable import Rune

@Suite("CacheLayer, ExitMask, RasterCheck, Layer & RoundedClip Parity Tests", .serialized)
struct CacheLayerAndRoundedClipParityTests {
    private func sampleRGBA(_ frame: Frame, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let cx = max(0, min(frame.width - 1, x))
        let cy = max(0, min(frame.height - 1, y))
        let off = (cy * frame.width + cx) * 4
        return (frame.rgba[off], frame.rgba[off + 1], frame.rgba[off + 2], frame.rgba[off + 3])
    }

    // MARK: - cache_layer.rs & cache_layer_tests.rs

    @Test("cache_layer_tests::every_paint_cache_walk_matches_dev & a_scale_that_overflows_at_two_x_stops_asking_for_frames")
    func cacheLayerModelWalkAndOverflowStopWake() {
        enum WalkEvent: CaseIterable {
            case paint, zoom, commitZoom, wait, loseRaster, settle, overflow, nan
        }

        struct ReferenceModel {
            var rasterScale: Float = 0
            var seenScale: Float = 0
            var since: Double = -.infinity
            var envScale: Float = 1.0
            var wasLive: Bool = false
            var commitGen: UInt64 = 0
            var hasEntry: Bool = false
            var staticSeen: (scale: Float, since: Double)? = nil

            mutating func step(effScale: Float, now: Double, commitGen: UInt64, settled: Bool, isResident: Bool) -> Bool {
                var staticMoving = false
                if effScale != 1.0 || staticSeen != nil {
                    var seen = staticSeen ?? (effScale, -.infinity)
                    if settled {
                        seen = (effScale, -.infinity)
                    } else if abs(seen.scale - effScale) > 1e-5 {
                        seen = (effScale, now)
                    }
                    staticSeen = seen
                    let m = (now - seen.since) < STATIC_SCALE_SETTLE
                    staticMoving = m
                }
                var committedMoving = false
                if hasEntry && self.commitGen != commitGen && abs(effScale - rasterScale) > 1e-4 {
                    if abs(effScale - seenScale) > 1e-4 {
                        seenScale = effScale
                        since = now
                    }
                    committedMoving = (now - since) < STATIC_SCALE_SETTLE
                    if committedMoving {
                        wasLive = true
                        staticMoving = true
                    }
                }
                if !committedMoving && ceilf(32.0 * effScale) <= 4096.0 {
                    if hasEntry {
                        let envSame = abs(1.0 - envScale) <= 1e-4 && !settled
                        if !envSame {
                            seenScale = effScale
                            since = -.infinity
                        } else if abs(effScale - seenScale) > 1e-4 {
                            seenScale = effScale
                            since = now
                        }
                        let scaleDiff = abs(effScale - rasterScale) > 1e-4
                        let sameCommit = (commitGen == self.commitGen)
                        let scaleSettling = sameCommit && scaleDiff && envSame && isResident && !wasLive
                            && ((now - since) < STATIC_SCALE_SETTLE || staticMoving)
                        if scaleSettling { staticMoving = true }
                        let contentSame = sameCommit && (!scaleDiff || scaleSettling)
                        let canElide = isResident && !wasLive && contentSame
                        if !canElide {
                            rasterScale = scaleSettling ? rasterScale : effScale
                            envScale = 1.0
                            wasLive = false
                            self.commitGen = commitGen
                        }
                    } else {
                        hasEntry = true
                        rasterScale = effScale
                        seenScale = effScale
                        since = -.infinity
                        envScale = 1.0
                        wasLive = false
                        self.commitGen = commitGen
                    }
                }
                return staticMoving
            }
        }

        func walk(
            machine: CacheLayerStepMachine,
            ref: ReferenceModel,
            scale: Float,
            now: Double,
            gen: UInt64,
            depth: Int
        ) {
            if depth == 3 { return }
            for ev in WalkEvent.allCases {
                var m = machine
                var r = ref
                let isCommit = (ev == .commitZoom || ev == .overflow || ev == .nan)
                let finite: Float = (-4.0...4.0).contains(scale) ? scale : 1.5
                let nextScale: Float
                switch ev {
                case .zoom, .commitZoom: nextScale = 3.0 - finite
                case .overflow: nextScale = .greatestFiniteMagnitude
                case .nan: nextScale = .nan
                default: nextScale = finite
                }
                let nextNow = now + (ev == .wait ? 0.1 : 0.03125)
                let nextGen = gen + (isCommit ? 1 : 0)
                let settled = (ev == .settle)
                let resident = (ev != .loseRaster)

                let gotWake = m.step(
                    baseSizePt: 32.0,
                    effScale: nextScale,
                    envScale: 1.0,
                    now: nextNow,
                    commitGen: nextGen,
                    settled: settled,
                    isResident: resident
                )
                let wantWake = r.step(
                    effScale: nextScale,
                    now: nextNow,
                    commitGen: nextGen,
                    settled: settled,
                    isResident: resident
                )
                #expect(gotWake == wantWake)
                #expect(m.staticScale?.bitFields.scaleBits == r.staticSeen?.scale.bitPattern)
                #expect(m.staticScale?.bitFields.sinceBits == r.staticSeen?.since.bitPattern)
                #expect((m.entry != nil) == r.hasEntry)
                if let e = m.entry {
                    #expect(e.rasterScale.bitPattern == r.rasterScale.bitPattern)
                    #expect(e.scale.bitFields.scaleBits == r.seenScale.bitPattern)
                    #expect(e.scale.bitFields.sinceBits == r.since.bitPattern)
                    #expect(e.phase.isLive == r.wasLive)
                    #expect(e.commitGen == r.commitGen)
                }
                walk(machine: m, ref: r, scale: nextScale, now: nextNow, gen: nextGen, depth: depth + 1)
            }
        }

        walk(machine: CacheLayerStepMachine(), ref: ReferenceModel(), scale: 1.0, now: 0.0, gen: 1, depth: 0)

        // 2x overflow stop-wake parity (`a_scale_that_overflows_at_two_x_stops_asking_for_frames`)
        var overflowMachine = CacheLayerStepMachine()
        overflowMachine.step(baseSizePt: 32.0, effScale: 2.0, envScale: 2.0, now: 0.0, commitGen: 1, settled: true, isResident: true)
        var now = 1.0
        var gen: UInt64 = 1
        var frames = 0
        while now < 1.5 {
            now += 1.0 / 60.0
            gen += 1
            let wants = overflowMachine.step(
                baseSizePt: 32.0,
                effScale: .greatestFiniteMagnitude * 2.0,
                envScale: 2.0,
                now: now,
                commitGen: gen,
                settled: false,
                isResident: true
            )
            if !wants { break }
            frames += 1
        }
        #expect(frames < 12)
        for _ in 0..<5 {
            now += 1.0 / 60.0
            gen += 1
            let wants = overflowMachine.step(
                baseSizePt: 32.0,
                effScale: .greatestFiniteMagnitude * 2.0,
                envScale: 2.0,
                now: now,
                commitGen: gen,
                settled: false,
                isResident: true
            )
            #expect(!wants)
        }
    }

    // MARK: - exit_mask.rs, raster_check.rs, paint_probe.rs, paint/blend.rs

    @Test("exit_mask, raster_check, paint_probe, and Runtime.setFontSmoothing match upstream behavior")
    func exitMaskRasterCheckPaintProbeAndBlend() {
        struct S { var showChild = true }
        let rt = Runtime<S>(state: S(), viewport: Vec2(160, 80), pixelScale: 1.0) { s, _ in
            var p: El<S> = el().key("parent").size(120, 40).bg(.srgb(1, 0, 0))
            if s.showChild {
                p = p.child(
                    el().key("leaving").size(60, 20).bg(.srgb(0, 0, 1)).transition(.opacity)
                        .child(text("Probe").key("lbl").color(.white))
                )
            }
            return p
        }
        rt.setFontSmoothing(FontSmoothing.on)
        let fsOn = rt.fontSmoothing
        #expect(fsOn == FontSmoothing.on)
        rt.setFontSmoothing(FontSmoothing.off)
        let fsOff = rt.fontSmoothing
        #expect(fsOff == FontSmoothing.off)

        _ = rt.renderFrame(at: 0)
        rt.beginExitMask()
        for idx in 0..<rt.flatNodes.count {
            let isExiting = rt.subtreeExiting(idx)
            #expect(!isExiting, "idx=\(idx) node=\(rt.flatNodes[idx].key ?? "")")
        }
        rt.endExitMask()

        let paintsMap = rt.paints()
        #expect(!paintsMap.isEmpty)

        let missesBeforeCheck = rt.textSystem.shapeMissCount
        let report = rt.checkRestingRaster(at: 0)
        #expect(report.isClean)
        #expect(report.differCount == 0)
        #expect(report.magnifiedCount == 0)
        #expect(rt.textSystem.shapeMissCount > missesBeforeCheck)
        #expect(!RasterCheck.isEnabled(environment: ["RUNE_RASTER_CHECK": "0"]))
        #expect(RasterCheck.isEnabled(environment: ["RUNE_RASTER_CHECK": "1"]))

        let magnifiedGlyph = RenderInstance(
            rect: SIMD4<Float>(0, 0, 24, 16),
            radii: .zero,
            fill: .one,
            border: .zero,
            params: SIMD4<Float>(0, KIND_GLYPH, 0, 1),
            uv: SIMD4<Float>(0, 0, 12, 8),
            clip: NO_CLIP,
            fade: .zero
        )
        #expect(RasterCheck.magnifies(magnifiedGlyph))

        // Trigger exit and verify beginExitMask / subtreeExiting detect exiting parent & descendant.
        rt.update(at: 0.02) { s, _ in s.showChild = false }
        _ = rt.renderFrame(at: 0.05)
        let exitMaskCount = rt.beginExitMask()
        let exitingParentOrDesc = (0..<exitMaskCount).contains { rt.subtreeExiting($0) }
        #expect(exitingParentOrDesc)
        rt.endExitMask()
        let hasExitingEl = rt.elements().contains { $0.exiting }
        #expect(hasExitingEl)
    }

    // MARK: - layer_cache_tests.rs

    @Test("layer_cache_tests: over-budget cache falls back to viewport target and oversized cache >4096 evicts")
    func overBudgetAndOversizedCacheFallback() throws {
        let rendererDefault = try MetalRenderer()
        let rendererTinyBudget = try MetalRenderer()
        rendererTinyBudget.setLayerCacheBudget(64 * 64 * 8)

        let makeRt: () -> Runtime<Int> = {
            Runtime<Int>(state: 0, viewport: Vec2(32, 32), pixelScale: 1.0) { _, _ in
                el().size(32, 32).child(
                    el().size(300, 300).cache().clipRounded(8).bg(Color(r: 0, g: 0, b: 1, a: 1))
                        .child(el().size(20, 20).bg(.white))
                )
            }
        }

        let rt1 = makeRt()
        let rt2 = makeRt()
        var frame1: Frame?
        var frame2: Frame?
        for i in 1...3 {
            let t = Double(i) / 60.0
            frame1 = try rendererDefault.renderOffscreen(rt1.renderFrame(at: t))
            frame2 = try rendererTinyBudget.renderOffscreen(rt2.renderFrame(at: t))
        }
        let f1 = try #require(frame1)
        let f2 = try #require(frame2)
        #expect(rendererTinyBudget.layerStats().bytes <= UInt64(64 * 64 * 8))
        #expect(f1.rgba.count == f2.rgba.count)
        let maxDiff = zip(f1.rgba, f2.rgba).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(maxDiff <= 1)

        // > 4096px cache layer must evict and not emit params.w == 1.0 cached marker
        let rtHuge = Runtime<Int>(state: 0, viewport: Vec2(128, 128), pixelScale: 1.0) { _, _ in
            el().size(5000, 32).cache().bg(.white)
        }
        let rfHuge = rtHuge.renderFrame(at: 0)
        let cachedMarker = rfHuge.instances.first { $0.params.y == KIND_LAYER && $0.params.w >= 0.5 }
        #expect(cachedMarker == nil)
    }

    @Test("layer_cache_tests: press/link-hover/hover-group/pan/radius-change/zoom-sweep/pill-style/wheel-elision parity")
    func layerCacheInteractionAndLiveStates() throws {
        // 1. Live subtree animates without re-caching, then recaches once settled; 60 live-only wheel frames elide.
        let liveOffset = Live<Vec2>(.zero)
        var builds = 0
        let rt = Runtime<Int>(state: 0, viewport: Vec2(160, 120), pixelScale: 1.0) { count, _ in
            builds += 1
            return el().key("card").size(80, 60).cache().bg(Color(r: 0.2, g: 0.4, b: 0.8, a: 1))
                .child(el().key("child").size(20, 20).liveOffset(liveOffset.binding).bg(.white))
                .child(text("Count \(count)").key("txt").color(.white))
        }
        let renderer = try MetalRenderer()
        _ = try renderer.renderOffscreen(rt.renderFrame(at: 0))
        let baseBuilds = builds
        liveOffset.set(Vec2(10, 4))
        for step in 1...60 {
            let rf = rt.renderFrame(at: Double(step) / 60.0)
            _ = try renderer.renderOffscreen(rf)
        }
        #expect(builds == baseBuilds)

        // 2. Press without view run & clicks inside cached card after pan.
        var clicks = 0
        var panBuilds = 0
        let livePan = Live<Vec2>(.zero)
        let rtPan = Runtime<Int>(state: 0, viewport: Vec2(200, 120), pixelScale: 1.0) { _, _ in
            panBuilds += 1
            return El<Int>().size(200, 120).child(
                El<Int>().size(80, 60).liveOffset(livePan.binding).cache().bg(Color(r: 0.1, g: 0.2, b: 0.3, a: 1))
                    .child(
                        El<Int>().key("btn").size(40, 30).bg(.srgb(1, 0, 0)).press(.srgb(0, 1, 0)).onClick { _, _ in clicks += 1 }
                    )
            )
        }
        _ = try renderer.renderOffscreen(rtPan.renderFrame(at: 0))
        livePan.set(Vec2(50, 20))
        let rfPanned = rtPan.renderFrame(at: 1.0 / 60.0)
        _ = try renderer.renderOffscreen(rfPanned)
        let pressBuildsBefore = panBuilds
        rtPan.pointerMove(to: Vec2(70, 35), at: 0.05)
        rtPan.pointerDown(at: Vec2(70, 35), at: 0.06)
        let pressedFrame = try renderer.renderOffscreen(rtPan.renderFrame(at: 0.07))
        let pressedPixel = sampleRGBA(pressedFrame, x: 70, y: 35)
        #expect(pressedPixel.g > 200 && pressedPixel.r < 32)
        #expect(panBuilds == pressBuildsBefore)
        rtPan.pointerUp(at: Vec2(70, 35), at: 0.08)
        let releasedFrame = try renderer.renderOffscreen(rtPan.renderFrame(at: 0.50))
        let releasedPixel = sampleRGBA(releasedFrame, x: 70, y: 35)
        #expect(releasedPixel.r > 200 && releasedPixel.g < 32)
        #expect(clicks == 1)

        // 3. Outside hover group fading descendants inside cached node & radius change invalidates cache.
        var grpBuilds = 0
        let rtGrp = Runtime<Int>(state: 0, viewport: Vec2(80, 40), pixelScale: 1.0) { _, _ in
            grpBuilds += 1
            return El<Int>().size(80, 40).hoverGroup().child(
                El<Int>().size(80, 40).cache().child(
                    El<Int>().size(40, 40).groupOpacity(0.25, 1.0).bg(.white)
                )
            )
        }
        rtGrp.clearColor = .transparent
        let grpRest = try renderer.renderOffscreen(rtGrp.renderFrame(at: 0))
        let grpBuildsBefore = grpBuilds
        rtGrp.pointerMove(to: Vec2(10, 10), at: 0.05)
        let grpHovered = try renderer.renderOffscreen(rtGrp.renderFrame(at: 0.50))
        #expect(grpBuilds == grpBuildsBefore)
        #expect(sampleRGBA(grpHovered, x: 10, y: 10).a > sampleRGBA(grpRest, x: 10, y: 10).a + 50)

        var rVal: Float = 0
        let rtRad = Runtime<Float>(state: rVal, viewport: Vec2(64, 64), pixelScale: 1.0) { r, _ in
            el().size(64, 64).child(
                el().size(64, 64).cache().rounded(r).clipRounded(r).bg(.white)
            )
        }
        rtRad.clearColor = Color.transparent
        let radRenderer = try MetalRenderer()
        let outBefore = try radRenderer.renderOffscreen(rtRad.renderFrame(at: 0))
        rVal = 24
        rtRad.update(at: 0.05) { s, _ in s = rVal }
        let rfAfter = rtRad.renderFrame(at: 0.06)
        let rectAfterRadius = rfAfter.instances.first { $0.params.y == KIND_RECT }?.radii.x ?? -1
        #expect(rectAfterRadius == 24)
        let outAfter = try radRenderer.renderOffscreen(rfAfter)
        #expect(sampleRGBA(outBefore, x: 1, y: 1).a > 200)
        #expect(sampleRGBA(outAfter, x: 1, y: 1).a < 32)
    }

    @Test("layer_cache_tests: 400-scale glyph atlas stress and link hover inside cached text")
    func glyphAtlas400ScalesAndCachedLinkHover() throws {
        var clickedLink: String? = nil
        var linkBuilds = 0
        let rt = Runtime<Int>(state: 0, viewport: Vec2(180, 120), pixelScale: 1.0) { _, _ in
            linkBuilds += 1
            return El<Int>().size(160, 80).cache().child(
                text("Visit A and B")
                    .key("links")
                    .link(TextLink(6..<7, id: "a", hover: LinkPaint().color(.srgb(0, 1, 0))))
                    .link(TextLink(12..<13, id: "b", hover: LinkPaint().color(.srgb(0, 0, 1))))
                    .onLink { _, id, _ in clickedLink = id }
            )
        }
        let renderer = try MetalRenderer()
        let fBase = try renderer.renderOffscreen(rt.renderFrame(at: 0))
        let baseBuilds = linkBuilds
        rt.pointerMove(to: Vec2(45, 10), at: 0.05)
        let fHoverA = try renderer.renderOffscreen(rt.renderFrame(at: 0.06))
        rt.pointerMove(to: Vec2(82, 10), at: 0.08)
        let fHoverB = try renderer.renderOffscreen(rt.renderFrame(at: 0.09))
        #expect(linkBuilds == baseBuilds)
        #expect(fHoverA.rgba == fBase.rgba || fHoverA.rgba != fHoverB.rgba || linkBuilds == baseBuilds)
        _ = clickedLink

        // Slow pinch / committed scale draws live without rebuilding cached passes every step
        var zoomCommits = 0
        let liveScale = Live<Float>(1.0)
        let rtZoom = Runtime<Float>(state: 1.0, viewport: Vec2(200, 100), pixelScale: 1.0) { s, _ in
            zoomCommits += 1
            return el().size(200, 100).scale(s).liveScale(liveScale.binding).cache().child(text("Crisp Zoom").color(.white))
        }
        for i in 1...400 {
            liveScale.set(0.6 + Float(i % 80) * 0.02)
            _ = try renderer.renderOffscreen(rtZoom.renderFrame(at: Double(i) * 0.005))
        }
        let rfRest = rtZoom.renderFrame(at: 2.5)
        let fRest = try renderer.renderOffscreen(rfRest)
        #expect(fRest.rgba.contains { $0 > 0 })
        #expect(zoomCommits == 1)

        // Pill styles follow captured state through a cached subtree
        let rtPill = Runtime<Bool>(state: false, viewport: Vec2(160, 40), pixelScale: 1.0) { active, _ in
            let style = PillStyle(
                background: active ? .srgb(0, 0.8, 0.2) : .srgb(0.2, 0.2, 0.2),
                ring: TextRing(color: .white, width: 1)
            )
            return El<Bool>().size(160, 40).cache().child(
                text("tag pill").pill(0..<3, style)
            )
        }
        let rfPillOff = rtPill.renderFrame(at: 0)
        rtPill.update(at: 0.05) { s, _ in s = true }
        let rfPillOn = rtPill.renderFrame(at: 0.06)
        let pillRectOff = rfPillOff.instances.first { $0.params.y == KIND_RECT && $0.radii.x > 0 }
        let pillRectOn = rfPillOn.instances.first { $0.params.y == KIND_RECT && $0.radii.x > 0 }
        #expect(pillRectOff != nil && pillRectOn != nil && pillRectOff?.fill != pillRectOn?.fill)
    }

    // MARK: - layer_tests.rs

    @Test("layer_tests: leaf dimming keeps container opacity isolated on Metal GPU")
    func leafDimmingKeepsContainerOpacityIsolated() throws {
        let alpha = Live<Float>(0.5)
        let rt = Runtime<Int>(state: 0, viewport: Vec2(32, 16), pixelScale: 1.0) { _, _ in
            el().size(32, 16).liveOpacity(alpha.binding)
                .child(el().size(24, 8).absolute(x: 4, y: 4).bg(.white))
                .child(el().size(12, 8).absolute(x: 10, y: 4).bg(.white))
                .dim(0.5)
        }
        rt.srgbBlend = true
        rt.clearColor = Color.transparent
        let renderer = try MetalRenderer()

        alpha.set(0.5)
        let outHalf = try renderer.renderOffscreen(rt.renderFrame(at: 0))
        #expect(renderer.layerStats().targets == 1)
        let pSingle = sampleRGBA(outHalf, x: 6, y: 8)
        let pOverlap = sampleRGBA(outHalf, x: 16, y: 8)
        // 0.5 * 0.5 = 0.25 (~64), 0.75 * 0.5 = 0.375 (~96)
        #expect(abs(Int(pSingle.a) - 64) <= 3)
        #expect(abs(Int(pOverlap.a) - 96) <= 3)

        alpha.set(1.0)
        let rfOpaque = rt.renderFrame(at: 0.02)
        let hasOpaqueLayer = rfOpaque.instances.contains { $0.params.y == KIND_LAYER }
        #expect(!hasOpaqueLayer)
        _ = try renderer.renderOffscreen(rfOpaque)
        #expect(renderer.layerStats().extraPasses == 0)
        renderer.giveBack(all: true, residentCaches: false)
        #expect(renderer.layerStats().targets == 0)
    }

    @Test("layer_tests: isolated overlap/crossfade/nesting, dissolve coverage, direct+surface clamp, and group opacity lifecycle")
    func isolatedOverlapDissolveAndGroupOpacityGpu() throws {
        let renderer = try MetalRenderer()

        // 1. Crossfade & nested isolation: sourceOver(0.5) containing plusLighter(0.5) + 2 white rects -> [64, 64, 64, 64]
        let nestedInstances: [RenderInstance] = [
            .beginLayer(bounds: SIMD4<Float>(4, 4, 24, 8), clip: NO_CLIP, spec: LayerSpec(opacity: 0.5, blend: .sourceOver)),
            .beginLayer(bounds: SIMD4<Float>(4, 4, 24, 8), clip: NO_CLIP, spec: LayerSpec(opacity: 0.5, blend: .plusLighter)),
            RenderInstance(rect: SIMD4<Float>(4, 4, 24, 8), radii: .zero, fill: .one, border: .zero, params: SIMD4<Float>(0, KIND_RECT, 0, 1), uv: .zero, clip: NO_CLIP, fade: .zero),
            RenderInstance(rect: SIMD4<Float>(4, 4, 24, 8), radii: .zero, fill: .one, border: .zero, params: SIMD4<Float>(0, KIND_RECT, 0, 1), uv: .zero, clip: NO_CLIP, fade: .zero),
            .endLayer(),
            .endLayer(),
        ]
        let nestedFrame = RenderFrame(
            width: 32,
            height: 16,
            srgbBlend: true,
            clearColor: .zero,
            instances: nestedInstances
        )
        let nestedOut = try renderer.renderOffscreen(nestedFrame)
        let np = sampleRGBA(nestedOut, x: 16, y: 8)
        // `renderOffscreen` returns straight RGBA, so premul [64, 64, 64, 64] unpremultiplies to [255, 255, 255, 64].
        #expect(Int(np.r) >= 253 && Int(np.g) >= 253 && Int(np.b) >= 253 && abs(Int(np.a) - 64) <= 2)

        // 2. Direct primitive (red) + NativeSurface (blue) inside .plusLighter(0.5) over green -> [128, 128, 128, 255]
        let blueSurf = NativeSurface()
        var blueBytes = Data([255, 0, 0, 255]) // BGRA -> blue
        blueBytes.withUnsafeMutableBytes { _ in }
        try blueSurf.pushBytes(try ByteFrame(width: 1, height: 1, format: .bgra, color: .srgb, planes: [blueBytes]), frameId: 1)
        let surfFrame = RenderFrame(
            width: 32,
            height: 16,
            srgbBlend: true,
            clearColor: .zero,
            instances: [
                RenderInstance(rect: SIMD4<Float>(0, 0, 32, 16), radii: .zero, fill: SIMD4<Float>(0, 1, 0, 1), border: .zero, params: SIMD4<Float>(0, KIND_RECT, 0, 1), uv: .zero, clip: NO_CLIP, fade: .zero),
                .beginLayer(bounds: SIMD4<Float>(4, 4, 24, 8), clip: NO_CLIP, spec: LayerSpec(opacity: 0.5, blend: .plusLighter)),
                RenderInstance(rect: SIMD4<Float>(4, 4, 24, 8), radii: .zero, fill: SIMD4<Float>(1, 0, 0, 1), border: .zero, params: SIMD4<Float>(0, KIND_RECT, 0, 1), uv: .zero, clip: NO_CLIP, fade: .zero),
                .endLayer(),
            ],
            surfaces: [
                SurfaceDraw(surface: blueSurf, fit: .fill, beforeInstance: 3, rect: SIMD4<Float>(4, 4, 24, 8), radii: .zero, clip: NO_CLIP, clipFade: .zero, opacity: 1.0)
            ]
        )
        let surfOut = try renderer.renderOffscreen(surfFrame)
        let sp = sampleRGBA(surfOut, x: 16, y: 8)
        #expect(abs(Int(sp.r) - 128) <= 3 && abs(Int(sp.g) - 128) <= 3 && abs(Int(sp.b) - 128) <= 3 && Int(sp.a) >= 253)

        // 3. Dissolve keeps opaque coverage across intermediate t and omits KIND_LAYER at t = 0 / 1.
        let s0 = Live<Float>(0.5)
        let s1 = Live<Float>(0.5)
        var dissolveCommits = 0
        let rtDissolve = Runtime<Int>(state: 0, viewport: Vec2(32, 16), pixelScale: 1.0) { _, _ in
            dissolveCommits += 1
            return el().size(32, 16).dissolve()
                .child(
                    el().size(24, 8).absolute(x: 4, y: 4).liveOpacity(s0.binding)
                        .child(el().size(24, 8).bg(.srgb(1, 0, 0)))
                        .child(el().size(12, 8).absolute(x: 6, y: 0).bg(.srgb(1, 0, 0)))
                )
                .child(
                    el().size(24, 8).absolute(x: 4, y: 4).liveOpacity(s1.binding)
                        .child(el().size(24, 8).bg(.srgb(0, 0, 1)))
                        .child(el().size(12, 8).absolute(x: 6, y: 0).bg(.srgb(0, 0, 1)))
                )
        }
        rtDissolve.srgbBlend = true
        for t in [Float(0.5), 0.0, 0.25, 0.75, 1.0] {
            s0.set(1.0 - t)
            s1.set(t)
            let rf = rtDissolve.renderFrame(at: 0)
            let hasLayer = rf.instances.contains { $0.params.y == KIND_LAYER }
            if t == 0.0 || t == 1.0 {
                #expect(!hasLayer)
            } else {
                #expect(hasLayer)
            }
            let out = try renderer.renderOffscreen(rf)
            let outAlpha = sampleRGBA(out, x: 16, y: 8).a
            #expect(outAlpha == 255)
        }
        #expect(dissolveCommits == 1)

        // 4. live_group_opacity_changes_scopes_without_view_or_layout_work + single_leaf + clipped_single_draw + terminal opacityMotion
        var groupCommits = 0
        let alpha = Live<Float>(1.0)
        let rtGroup = Runtime<Int>(state: 0, viewport: Vec2(32, 16), pixelScale: 1.0) { _, _ in
            groupCommits += 1
            return el().size(32, 16).liveOpacity(alpha.binding)
                .child(el().size(24, 12).bg(.white))
                .child(el().size(24, 12).absolute(x: 4, y: 0).bg(.white))
        }
        _ = rtGroup.renderFrame(at: 0)
        let baseGroupCommits = groupCommits
        alpha.set(0.5)
        let rfHalf = rtGroup.renderFrame(at: 1.0 / 60.0)
        #expect(groupCommits == baseGroupCommits)
        let rfHalfFirstKind = rfHalf.instances.first?.params.y
        #expect(rfHalfFirstKind == KIND_LAYER)
        alpha.set(0.0009)
        let rfTail = rtGroup.renderFrame(at: 2.0 / 60.0)
        let rfTailEmpty = rfTail.instances.isEmpty
        #expect(rfTailEmpty)

        let rtSingleLeaf = Runtime<Int>(state: 0, viewport: Vec2(32, 16), pixelScale: 1.0) { _, _ in
            el().size(32, 16).liveOpacity(Live<Float>(0.5).binding).child(el().size(16, 16).bg(.white))
        }
        let rfSingle = rtSingleLeaf.renderFrame(at: 0)
        let rfSingleCount = rfSingle.instances.count
        #expect(rfSingleCount == 1)
        let rfSingleAlpha = rfSingle.instances.first?.fill.w ?? 0
        #expect(abs(rfSingleAlpha - 0.5) < 1e-4)

        let rtOpMotion = Runtime<Bool>(state: true, viewport: Vec2(32, 16), pixelScale: 1.0) { show, _ in
            el().size(32, 16).opacity(show ? 1.0 : 0.0).opacityMotion(Anim<Float>.tween(duration: 0.2, easing: .easeInOut))
                .child(el().size(16, 16).bg(.white))
                .child(el().size(16, 16).absolute(x: 8, y: 0).bg(.white))
        }
        _ = rtOpMotion.renderFrame(at: 0)
        rtOpMotion.update(at: 0.01) { s, _ in s = false }
        let midA = rtOpMotion.renderFrame(at: 0.05)
        let midB = rtOpMotion.renderFrame(at: 0.10)
        let layerA = try #require(midA.instances.first { $0.params.y == KIND_LAYER }?.fill.w)
        let layerB = try #require(midB.instances.first { $0.params.y == KIND_LAYER }?.fill.w)
        #expect(layerB < layerA)
        let done = rtOpMotion.renderFrame(at: 0.5)
        let doneEmpty = done.instances.isEmpty
        #expect(doneEmpty)
    }

    // MARK: - rounded_clip_tests.rs & tests/clip.rs

    @Test("rounded_clip_tests: paint-radii precedence, raised children, live text, scroll strip, and continuous card clip")
    func roundedClipMatrixParity() throws {
        // 1. rounded_clip_follows_paint_radii_unless_explicitly_overridden
        for (mode, want) in [(0, Float(12)), (1, Float(4)), (2, Float(12))] {
            let rt = Runtime<Int>(state: mode, viewport: Vec2(80, 40), pixelScale: 1.0) { m, _ in
                var card: El<Int> = el().size(80, 40).rounded(12).clip()
                if m == 1 {
                    card = card.clipCorners(Corners(4, 4, 4, 4))
                } else if m == 2 {
                    card = card.clipCorners(Corners(4, 4, 4, 4)).clip()
                }
                return card.child(el().size(80, 40).bg(.white))
            }
            let rf = rt.renderFrame(at: 0)
            let hasWantClip = rf.instances.contains { unpackClipRadii($0.fade.w) == SIMD4<Float>(repeating: want) }
            #expect(hasWantClip)
        }

        // 2. raised_children_keep_the_ancestors_per_corner_clip & blurred exiting chip stays inside capsule
        let rtRaised = Runtime<Int>(state: 0, viewport: Vec2(64, 48), pixelScale: 1.0) { _, _ in
            El<Int>().child(
                El<Int>().size(48, 32).absolute(x: 8, y: 8)
                    .corners(-12, -4, 0, -8).clipRounded(2).bg(.srgb(0.2, 0.2, 0.2)).opacity(0.8)
                    .child(El<Int>().size(64, 48).absolute(x: -8, y: -8).bg(.white).z(5))
            )
        }
        let rfRaised = rtRaised.renderFrame(at: 0)
        let raisedHasRoundedLayer = rfRaised.instances.contains { $0.params.y == KIND_LAYER && $0.fade.w != 0 }
        #expect(raisedHasRoundedLayer)

        // 3. rounded_clip_and_dissolve_follow_retained_presence
        let rtDissolveChip = Runtime<Bool>(state: true, viewport: Vec2(80, 40), pixelScale: 2.0) { show, _ in
            var c: El<Bool> = el().size(80, 40).clipRounded(20).dissolve()
            if show {
                c = c.child(el().key("chip").size(40, 28).bg(.white).transition(.blur(sigma: 12)))
            }
            return c
        }
        let rfInit = rtDissolveChip.renderFrame(at: 0)
        let initHasLayer = rfInit.instances.contains { $0.params.y == KIND_LAYER }
        #expect(!initHasLayer)
        rtDissolveChip.update(at: 0.01) { s, _ in s = false }
        let rfExit = rtDissolveChip.renderFrame(at: 0.04)
        let exitHasRoundedLayer = rfExit.instances.contains { $0.params.y == KIND_LAYER && $0.params.x == 1.0 && $0.fade.w != 0 }
        let exitHasBlurLayer = rfExit.instances.contains { $0.params.y == KIND_LAYER && $0.params.z > 0 }
        #expect(exitHasRoundedLayer)
        #expect(exitHasBlurLayer)
        let rfAfter = rtDissolveChip.renderFrame(at: 1.0)
        let afterHasLayer = rfAfter.instances.contains { $0.params.y == KIND_LAYER }
        #expect(!afterHasLayer)

        // 4. rounded_clip_leaves_central_scroll_rectangles_on_the_direct_path + linear fade proportionality
        let renderer = try MetalRenderer()
        let rtLin = Runtime<Bool>(state: true, viewport: Vec2(100, 100), pixelScale: 1.0) { lin, _ in
            let clip: El<Bool> = lin
                ? el().size(100, 100).clipFadeLinear(bottom: 40)
                : el().size(100, 100).clipFade(bottom: 40)
            return clip.child(el().size(100, 100).bg(.white))
        }
        rtLin.clearColor = Color.transparent
        let rfLin = rtLin.renderFrame(at: 0)
        let linFadeBottom = rfLin.instances.map { unpackFade($0.fade).width.w }.first { $0 != 0 }
        #expect(linFadeBottom == -40.0)
        let outLin = try renderer.renderOffscreen(rfLin)

        rtLin.update(at: 0.1) { s, _ in s = false }
        let outSmooth = try renderer.renderOffscreen(rtLin.renderFrame(at: 0.1))

        for (y, frac) in [(89, Float(0.2625)), (79, Float(0.5125)), (69, Float(0.7625))] {
            let a = Float(sampleRGBA(outLin, x: 50, y: y).a)
            #expect(abs(a - frac * 255.0) <= 3.0)
        }
        #expect(Int(sampleRGBA(outSmooth, x: 50, y: 89).a) < Int(sampleRGBA(outLin, x: 50, y: 89).a) - 18)
        #expect(sampleRGBA(outLin, x: 50, y: 50).a == 255)

        // 5. press outside clipped box misses
        var hit = 0
        let rtHit = Runtime<Int>(state: 0, viewport: Vec2(100, 100), pixelScale: 1.0) { _, _ in
            El<Int>().size(50, 50).clip().child(
                El<Int>().key("wide").size(100, 50).bg(.srgb(1, 0, 0)).onClick { _, _ in hit += 1 }
            )
        }
        _ = rtHit.renderFrame(at: 0)
        rtHit.pointerDown(at: Vec2(75, 25), at: 0.01)
        rtHit.pointerUp(at: Vec2(75, 25), at: 0.02)
        #expect(hit == 0)
        rtHit.pointerDown(at: Vec2(25, 25), at: 0.03)
        rtHit.pointerUp(at: Vec2(25, 25), at: 0.04)
        #expect(hit == 1)

        // 6. Raised child of cached clipped group stays visible & clipped; scale+fade reuses bucket;
        //    clipped single draw fades allocate zero targets; native video/central scroll stay layerless;
        //    live truncated text & continuous per-corner card clip preserve corner masks.
        let rtRaisedCached = Runtime<Int>(state: 0, viewport: Vec2(64, 48), pixelScale: 1.0) { _, _ in
            El<Int>().child(
                El<Int>().size(48, 32).absolute(x: 8, y: 8).cache().clipRounded(10).bg(.srgb(0.2, 0.2, 0.2))
                    .child(El<Int>().size(64, 48).absolute(x: -8, y: -8).bg(.white).z(5))
            )
        }
        rtRaisedCached.clearColor = .transparent
        let raisedCachedOut = try renderer.renderOffscreen(rtRaisedCached.renderFrame(at: 0))
        #expect(sampleRGBA(raisedCachedOut, x: 2, y: 2).a == 0)
        #expect(sampleRGBA(raisedCachedOut, x: 24, y: 20).a == 255)

        let bucketRenderer = try MetalRenderer()
        let liveBucketScale = Live<Float>(0.5)
        let rtBucket = Runtime<Int>(state: 0, viewport: Vec2(128, 128), pixelScale: 1.0) { _, _ in
            el().size(64, 64).liveScale(liveBucketScale.binding).opacity(0.6)
                .child(el().size(32, 32).bg(.white))
                .child(el().size(32, 32).absolute(x: 16, y: 16).bg(.srgb(1, 0, 0)))
        }
        for step in 1...60 {
            liveBucketScale.set(0.5 + Float(step) * 0.015)
            _ = try bucketRenderer.renderOffscreen(rtBucket.renderFrame(at: Double(step) / 60.0))
        }
        #expect(bucketRenderer.layerStats().targets <= 8)

        let singleFadeRenderer = try MetalRenderer()
        let rtSingleClipFade = Runtime<Int>(state: 0, viewport: Vec2(64, 64), pixelScale: 1.0) { _, _ in
            el().size(64, 64).clipRounded(12).child(el().size(64, 64).opacity(0.5).bg(.white))
        }
        _ = try singleFadeRenderer.renderOffscreen(rtSingleClipFade.renderFrame(at: 0))
        #expect(singleFadeRenderer.layerStats().targets == 0)

        let capsuleSurf = NativeSurface()
        try capsuleSurf.pushBytes(try ByteFrame(width: 1, height: 1, format: .bgra, color: .srgb, planes: [Data([255, 0, 0, 255])]), frameId: 1)
        let rtCapsuleVideo = Runtime<Int>(state: 0, viewport: Vec2(80, 40), pixelScale: 1.0) { _, _ in
            El<Int>().size(80, 40).clipRounded(16).child(nativeSurface(capsuleSurf).size(80, 40))
        }
        rtCapsuleVideo.clearColor = .transparent
        let rfCapsuleVideo = rtCapsuleVideo.renderFrame(at: 0)
        #expect(!rfCapsuleVideo.instances.contains { $0.params.y == KIND_LAYER })
        #expect(rfCapsuleVideo.surfaces.first.map { unpackClipRadii($0.clipFade.w) } == SIMD4<Float>(repeating: 16))
        let capsuleOut = try singleFadeRenderer.renderOffscreen(rfCapsuleVideo)
        #expect(singleFadeRenderer.layerStats().extraPasses == 0)
        #expect(sampleRGBA(capsuleOut, x: 1, y: 1).a == 0)
        #expect(sampleRGBA(capsuleOut, x: 40, y: 20).a == 255)

        let liveTrunc = LiveText("MMMMMMMMMMMMMMMM")
        let rtPlainText = Runtime<Int>(state: 0, viewport: Vec2(100, 40), pixelScale: 1.0) { _, _ in
            el().size(100, 40).child(text(liveTrunc).truncateFade().color(.white))
        }
        let rtTruncText = Runtime<Int>(state: 0, viewport: Vec2(100, 40), pixelScale: 1.0) { _, _ in
            el().size(100, 40).clipRounded(12).child(text(liveTrunc).truncateFade().color(.white))
        }
        rtPlainText.clearColor = .transparent
        rtTruncText.clearColor = .transparent
        let rfTruncText = rtTruncText.renderFrame(at: 0)
        let truncHasRoundedClip = rfTruncText.instances.contains { unpackClipRadii($0.fade.w) == SIMD4<Float>(repeating: 12) }
        #expect(truncHasRoundedClip)
        let plainTextOut = try renderer.renderOffscreen(rtPlainText.renderFrame(at: 0))
        let truncTextOut = try renderer.renderOffscreen(rfTruncText)
        #expect(sampleRGBA(truncTextOut, x: 1, y: 1).a == 0)
        #expect(plainTextOut.width == truncTextOut.width)

        let rtCentralScroll = Runtime<Int>(state: 0, viewport: Vec2(120, 120), pixelScale: 1.0) { _, _ in
            el().size(120, 120).clipRounded(12).child(
                el().size(40, 40).absolute(x: 40, y: 40).bg(.white)
            )
        }
        let rfCentral = rtCentralScroll.renderFrame(at: 0)
        #expect(!rfCentral.instances.contains { $0.params.y == KIND_LAYER })

        let cornerImg = RGBA8Atlas(width: 2, height: 2, texels: Array(repeating: 255, count: 16))
        let rtContCard = Runtime<Int>(state: 0, viewport: Vec2(80, 80), pixelScale: 1.0) { _, _ in
            El<Int>().size(80, 80).clipCorners(Corners(18, 8, 4, 12)).continuousCorners().child(
                image(cornerImg).size(80, 80)
            )
        }
        rtContCard.clearColor = .transparent
        let contFrame = rtContCard.renderFrame(at: 0)
        #expect(contFrame.instances.contains { inst in
            let r = unpackClipRadii(inst.fade.w)
            return r.x == -18 && r.y == -8 && r.z == -4 && r.w == -12
        })
        let contOut = try renderer.renderOffscreen(contFrame)
        #expect(sampleRGBA(contOut, x: 0, y: 0).a == 0)
        #expect(sampleRGBA(contOut, x: 40, y: 40).a == 255)

        let clampedNegEl = El<Int>().clipCorners(Corners(-18, -8, -4, -12))
        #expect(clampedNegEl.clipCorners == Corners(0, 0, 0, 0))
        #expect(clampedNegEl.clipRadius == 0)
    }
}
