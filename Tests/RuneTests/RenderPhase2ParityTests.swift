import Foundation
import Testing
@testable import Rune
import RuneRef
#if canImport(QuartzCore) && os(macOS)
import QuartzCore
import CoreGraphics
#endif

@Suite("Render Phase 2 Upstream Parity Tests (P2-20..P2-23)")
struct RenderPhase2ParityTests {
    // MARK: - P2-20 (#828): Ganesh icon rasterization

    @Test("SVG element opacity scales rasterized coverage proportionally")
    func opacityScalesElementCoverage() {
        let full = SVGIcon(
            viewBox: 24,
            body: #"<rect x="4" y="4" width="16" height="16" fill="black"/>"#
        )
        let half = SVGIcon(
            viewBox: 24,
            body: #"<rect x="4" y="4" width="16" height="16" fill="black" opacity="0.5"/>"#
        )
        let a = GlyphAtlas.rasterizeIconBitmap(full, pixelSize: 24)
        let b = GlyphAtlas.rasterizeIconBitmap(half, pixelSize: 24)
        #expect(a.count == 24 * 24)
        #expect(b.count == 24 * 24)
        let centerIdx = 12 * 24 + 12
        #expect(a[centerIdx] == 255)
        #expect(abs(Int(b[centerIdx]) - 128) <= 2)
    }

    @Test("stroke-opacity leaves fill coverage intact")
    func strokeOpacityLeavesFillAlone() {
        let icon = SVGIcon(
            viewBox: 24,
            body: #"<rect x="5" y="5" width="14" height="14" fill="black" fill-opacity="1" stroke="black" stroke-width="2" stroke-opacity="0.25"/>"#
        )
        let cov = GlyphAtlas.rasterizeIconBitmap(icon, pixelSize: 24)
        // Interior center should remain solid 255 from fill.
        #expect(cov[12 * 24 + 12] == 255)
        // Outer edge on stroke ring (x=4, y=12) should be ~0.25 alpha (~64), well below fill.
        let edge = cov[12 * 24 + 4]
        #expect(edge > 20 && edge <= 96)
    }

    @Test("Rect and rounded rect stroke produces hollow center and symmetric edges")
    func rectAndRoundRectStrokeSymmetry() {
        let icon = SVGIcon(
            viewBox: 24,
            body: #"<rect x="4" y="4" width="16" height="16" rx="3" fill="none" stroke="black" stroke-width="2"/>"#
        )
        let cov = GlyphAtlas.rasterizeIconBitmap(icon, pixelSize: 24)
        #expect(cov[12 * 24 + 12] == 0)
        // Top/bottom/left/right symmetry at mid-edges.
        let top = cov[4 * 24 + 12]
        let bottom = cov[19 * 24 + 12]
        let left = cov[12 * 24 + 4]
        let right = cov[12 * 24 + 19]
        #expect(top > 180)
        #expect(abs(Int(top) - Int(bottom)) <= 2)
        #expect(abs(Int(left) - Int(right)) <= 2)
    }

    @Test("Hairline and subpixel stroke widths scale coverage cleanly")
    func hairlineAndSubpixelStroke() {
        let hairline = SVGIcon(viewBox: 24, paths: ["M2 2 L22 22"], strokeWidth: 1.0)
        let thin = SVGIcon(viewBox: 24, paths: ["M2 2 L22 22"], strokeWidth: 0.4)
        let cov1 = GlyphAtlas.rasterizeIconBitmap(hairline, pixelSize: 24)
        let covThin = GlyphAtlas.rasterizeIconBitmap(thin, pixelSize: 24)
        let sum1 = cov1.reduce(0) { $0 + Int($1) }
        let sumThin = covThin.reduce(0) { $0 + Int($1) }
        #expect(sum1 > 0)
        #expect(sumThin > 0)
        #expect(sumThin < sum1)
    }

    @Test("Conic oval, circle, and SVG elliptical arc rasterize via Ganesh paths")
    func conicArcAndOval() {
        let arcIcon = SVGIcon(
            viewBox: 24,
            body: #"<circle cx="12" cy="12" r="8" fill="none" stroke="black" stroke-width="2"/><path d="M6 12 A6 4 0 0 1 18 12" fill="none" stroke="black" stroke-width="2"/>"#
        )
        let cov = GlyphAtlas.rasterizeIconBitmap(arcIcon, pixelSize: 24)
        // Outer circle touches top mid (y=4, x=12) and inner arc passes near (y=8, x=12).
        #expect(cov[4 * 24 + 12] > 150)
        #expect(cov[8 * 24 + 12] > 100)
        // Center remains empty.
        #expect(cov[12 * 24 + 12] == 0)
    }

    @Test("fill-rule evenodd vs nonzero distinguishes concentric same-winding loops")
    func evenOddVsNonZeroFillRule() {
        let sameWinding = "M2 2 H22 V22 H2 Z M8 8 H16 V16 H8 Z"
        let nonZero = SVGIcon(
            viewBox: 24,
            body: #"<path d="\#(sameWinding)" fill="black" fill-rule="nonzero"/>"#
        )
        let evenOdd = SVGIcon(
            viewBox: 24,
            body: #"<path d="\#(sameWinding)" fill="black" fill-rule="evenodd"/>"#
        )
        let covNZ = GlyphAtlas.rasterizeIconBitmap(nonZero, pixelSize: 24)
        let covEO = GlyphAtlas.rasterizeIconBitmap(evenOdd, pixelSize: 24)
        #expect(covNZ[12 * 24 + 12] == 255)
        #expect(covEO[12 * 24 + 12] == 0)
        #expect(covEO[4 * 24 + 12] == 255)
    }

    @Test("Blink SVG number grammar and f64 90-degree rotation keep axis-aligned crispness")
    func blinkNumberAndF64RotateCrispness() {
        let icon = SVGIcon(
            viewBox: 24,
            body: #"<g transform="rotate(90 12 12)"><path d="M4.0.0h16v4H4z" fill="black"/></g>"#
        )
        let cov = GlyphAtlas.rasterizeIconBitmap(icon, pixelSize: 24)
        // Horizontal bar [4..20, 0..4] rotated 90 deg CW around (12, 12) -> vertical bar [20..24, 4..20].
        // Exact integer edges from f64 trig should give full 255 inside bar and 0 cleanly outside!
        #expect(cov[12 * 24 + 22] == 255)
        #expect(cov[12 * 24 + 19] == 0)
        #expect(cov[2 * 24 + 12] == 0)

        // Packed SVG blink_number path test (flag bits, negative signs, exponents without separators).
        let packed = GSVGPathParser.parse("M2.5.5l15-0e0v2h-15z")
        #expect(!packed.isEmpty)
    }

    @Test("IconSwapRegistry.iconCoveragePlaced applies subpixel origin float rounding on convex paths")
    func iconCoveragePlacedSubpixelShift() {
        let icon = SVGIcon(viewBox: 24, body: #"<path d="M3 4 L21 7 L17 20 Z" fill="black"/>"#)
        let c0 = IconSwapRegistry.iconCoveragePlaced(icon: icon, pixelSize: 24, origin: .zero)
        let cSub = IconSwapRegistry.iconCoveragePlaced(icon: icon, pixelSize: 24, origin: SIMD2<Float>(0.37, 0.19))
        #expect(c0.count == 24 * 24 && cSub.count == 24 * 24)
        #expect(c0[10 * 24 + 12] == 255 && cSub[10 * 24 + 12] == 255)
        // Diagonal/convex edge coordinates are shifted by origin during 256x edge snapping and shifted back,
        // so interior remains identical while edge pixels remain valid anti-aliased coverage.
        var maxDiff = 0
        for i in 0..<(24 * 24) {
            maxDiff = max(maxDiff, abs(Int(c0[i]) - Int(cSub[i])))
        }
        #expect(maxDiff <= 3)
    }

    // MARK: - P2-21 (#902): Metal surface keeps sRGB color space across resize

    #if canImport(QuartzCore) && os(macOS)
    @Test("MacOSMetalLayerSurface preserves sRGB colorspace across reconfigure and resize")
    @MainActor
    func metalLayerPreservesSRGBAcrossResize() {
        let host = CALayer()
        let metal = CAMetalLayer()
        host.addSublayer(metal)
        MacOSMetalLayerSurface.pinContentsTopLeft(metal)
        let expected = CGColorSpace(name: CGColorSpace.sRGB)
        #expect(metal.colorspace?.name == expected?.name)

        // Simulate window resize / scale reconfigure.
        metal.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        metal.drawableSize = CGSize(width: 1280, height: 960)
        metal.contentsScale = 2.0
        MacOSMetalLayerSurface.pinContentsTopLeft(metal)
        #expect(metal.colorspace?.name == expected?.name)
    }
    #endif

    // MARK: - P2-22 (#872): Offscreen text glyph culling (uncached vs cached/rotated)

    @Test("Offscreen text lines are culled by window bounds unless cached or rotated")
    @MainActor
    func offscreenTextLinesCulledUnlessCachedOrRotated() {
        struct State: Sendable {
            var cacheTree = false
            var rotateAngle: Float = 0
            var blurRadius: Float = 0
        }

        let lines = (0..<40).map { "Line \($0): viewport window culling check" }.joined(separator: "\n")
        let makeRt: (Bool, Float, Float) -> Runtime<State> = { cached, angle, blur in
            Runtime<State>(state: State(cacheTree: cached, rotateAngle: angle, blurRadius: blur), viewport: Vec2(320, 120)) { s, _ in
                var label: El<State> = text(lines).font(TextStyle(size: 14))
                if s.blurRadius > 0 {
                    label = label.blur(s.blurRadius)
                }
                if s.rotateAngle != 0 && s.blurRadius > 0 {
                    label = label.rotate(s.rotateAngle)
                }
                var textNode: El<State> = el()
                    .w(300)
                    .child(label)
                if s.rotateAngle != 0 && s.blurRadius == 0 {
                    textNode = textNode.rotate(s.rotateAngle)
                }
                var rootNode: El<State> = el()
                    .size(320, 120)
                    .child(textNode)
                if s.cacheTree {
                    rootNode = rootNode.cache(true)
                }
                return rootNode
            }
        }

        let uncached = makeRt(false, 0, 0)
        let uncachedRef = uncached.frame(at: 0)
        let uncachedRender = uncached.renderFrame(at: 0)

        let cached = makeRt(true, 0, 0)
        let cachedRender = cached.renderFrame(at: 0)

        let rotated = makeRt(false, 0.2, 0)
        let rotatedRef = rotated.frame(at: 0)
        let rotatedRender = rotated.renderFrame(at: 0)

        let blurredRotated = makeRt(false, 0.2, 2)
        let blurredRotatedRef = blurredRotated.frame(at: 0)
        let blurredRotatedRender = blurredRotated.renderFrame(at: 0)

        let refGlyphCount: (RefScene) -> Int = { scene in
            scene.primitives.filter { $0.params.y == Float(PrimitiveKind.glyph.rawValue) }.count
        }
        let renderGlyphCount: (RenderFrame) -> Int = { rf in
            rf.instances.filter { $0.params.y == KIND_GLYPH }.count
        }

        let uncachedRefCount = refGlyphCount(uncachedRef)
        let rotatedRefCount = refGlyphCount(rotatedRef)
        let blurredRotatedRefCount = refGlyphCount(blurredRotatedRef)
        #expect(uncachedRefCount > 0)
        #expect(uncachedRefCount < rotatedRefCount / 2)
        #expect(blurredRotatedRefCount == rotatedRefCount)

        let uncachedRenderCount = renderGlyphCount(uncachedRender)
        let cachedRenderCount = renderGlyphCount(cachedRender)
        let rotatedRenderCount = renderGlyphCount(rotatedRender)
        let blurredRotatedRenderCount = renderGlyphCount(blurredRotatedRender)
        #expect(uncachedRenderCount > 0)
        #expect(uncachedRenderCount < cachedRenderCount / 2)
        #expect(uncachedRenderCount < rotatedRenderCount / 2)
        #expect(blurredRotatedRenderCount == rotatedRenderCount)

        // All emitted uncached glyphs should lie within window height + filter/line band pad.
        let maxRefY = uncachedRef.primitives
            .filter { $0.params.y == Float(PrimitiveKind.glyph.rawValue) }
            .map { $0.rect.y }
            .max() ?? 0
        #expect(maxRefY <= Float(uncachedRef.height) + 64)
    }

    // MARK: - P2-23 (#920): Static max_texture_dim in layer pool & planner

    @Test("LayerPoolLimits exposes static maxDimension and planner honors maxDim")
    func layerPoolMaxDimensionConstantAndPlanner() {
        #expect(LayerPoolLimits.maxDimension == 4096)

        struct DummyHeld: LayerHeldDescribing {
            let size: SIMD2<UInt32>
            let cache: (UInt64, UInt64)?
            func held() -> LayerHeld { LayerHeld(size: size, cache: cache) }
        }

        var planner = LayerPlanner()
        let oversized = LayerPlanScope(
            begin: 0,
            end: 1,
            edges: SIMD4<Float>(0, 0, 5000, 300),
            vis: SIMD4<Float>(0, 0, 400, 300),
            opacity: 0.5,
            cache: (1, 1)
        )
        let fits = LayerPlanScope(
            begin: 1,
            end: 2,
            edges: SIMD4<Float>(0, 0, 400, 300),
            vis: SIMD4<Float>(0, 0, 400, 300),
            opacity: 0.5,
            cache: (2, 2)
        )
        let pools = LayerPoolSnapshot<DummyHeld>(slots: [nil, nil], retained: [], spare: [])
        planner.decide(
            plan: [oversized, fits],
            pools: pools,
            budget: 64 * 1024 * 1024,
            isolate: true,
            maxDim: UInt32(LayerPoolLimits.maxDimension)
        )
        #expect(planner.dispositions.count == 2)
        if case .render(let rect, let cache) = planner.dispositions[0] {
            #expect(cache == nil)
            #expect(rect.z == 400)
        } else {
            Issue.record("Expected layer disposition .render, got \(planner.dispositions[0])")
        }
        if case .render(_, let cache) = planner.dispositions[1] {
            #expect(cache?.0 == 2)
        } else {
            Issue.record("Expected cached-eligible layer disposition .render, got \(planner.dispositions[1])")
        }
        let maxAllocX = planner.moves.compactMap { move -> UInt32? in
            if case .create(_, let size) = move { return size.x }
            return nil
        }.max() ?? 0
        #expect(maxAllocX > 0 && maxAllocX <= UInt32(LayerPoolLimits.maxDimension))
    }

    @Test("Ganesh 20px masks match upstream Rust FNV-1a golden hashes for kit-search and kit-eye")
    func ganeshGoldenHashesForSearchAndEye20px() {
        func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
            bytes.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { h, a in
                (h ^ UInt64(a)) &* 0x100_0000_01b3
            }
        }
        let searchIcon = SVGIcon(
            viewBox: 16,
            body: #"<path d="M14 14L10.3454 10.3454M6.88889 11.7778C9.58889 11.7778 11.7778 9.58889 11.7778 6.88889C11.7778 4.18889 9.58889 2 6.88889 2C4.18889 2 2 4.18889 2 6.88889C2 9.58889 4.18889 11.7778 6.88889 11.7778Z" stroke="currentColor"/>"#
        )
        let eyeBodyIcon = SVGIcon(
            viewBox: 16,
            body: #"<path d="M1 8s2.5-4.5 7-4.5S15 8 15 8s-2.5 4.5-7 4.5S1 8 1 8Z" stroke="currentColor" stroke-linejoin="round"/><circle cx="8" cy="8" r="2" stroke="currentColor"/>"#
        )
        let searchCov = GaneshIcon.coverageAt(searchIcon, pixelSize: 20, drawnSize: 20, origin: .zero)
        let eyeCov = GaneshIcon.coverageAt(eyeBodyIcon, pixelSize: 20, drawnSize: 20, origin: .zero)
        #expect(fnv1a64(searchCov) == 0xc209_122e_34e9_7651)
        #expect(fnv1a64(eyeCov) == 0x2adc_49d3_a5e7_d89a)
    }
}
