import Foundation
import Testing
@testable import Rune

@Suite("Monochrome SMIL SVG Icon Animation Tests")
struct SVGIconAnimTests {

    // MARK: - Helpers

    private static let pulseDot = SVGIcon(
        viewBox: 24,
        body: """
        <circle cx="12" cy="12" r="4" fill="currentColor">
          <animate attributeName="r" values="4;10;4" dur="1s" repeatCount="indefinite"/>
        </circle>
        """
    )

    private static let finiteFade = SVGIcon(
        viewBox: 24,
        body: """
        <rect x="4" y="4" width="16" height="16" fill="currentColor" opacity="0.2">
          <animate attributeName="opacity" from="0.2" to="1" dur="0.5s" fill="freeze"/>
        </rect>
        """
    )

    private static let flatHoldIcon = SVGIcon(
        viewBox: 24,
        body: """
        <circle cx="12" cy="12" r="8" fill="currentColor">
          <animate attributeName="opacity" values="0.2;0.2;1.0" keyTimes="0;0.5;1" dur="2s" repeatCount="indefinite"/>
        </circle>
        """
    )

    private static func readTilePixels(atlas: GlyphAtlas, entry: GlyphAtlas.Entry) -> [UInt8] {
        let px = entry.pixelSize.x
        let py = entry.pixelSize.y
        let page = Int(entry.page)
        guard let data = atlas.pageData(page) else { return [] }
        let stride = atlas.atlases[page].width
        var out: [UInt8] = []
        out.reserveCapacity(px * py)
        for row in 0..<py {
            let base = (entry.pixelOrigin.y + row) * stride + entry.pixelOrigin.x
            out.append(contentsOf: data[base..<(base + px)])
        }
        return out
    }

    private static func sumAlpha(_ bytes: [UInt8]) -> Int {
        bytes.reduce(0) { $0 + Int($1) }
    }

    // MARK: - 1. Classification & Multi-Colour Exclusion

    @Test("Classifies static monochrome, animated monochrome, and static multi-colour icons")
    func iconClassificationAndMultiColorExclusion() throws {
        let ts = TextSystem()
        #expect(ts.hasAnimatedIcons == false)

        let staticPath = SVGIcon(viewBox: 24, paths: ["M4 4 H20 V20 H4 Z"], strokeWidth: nil)
        let staticBody = SVGIcon(viewBox: 24, body: #"<rect x="4" y="4" width="16" height="16"/>"#)
        let multiColorAnim = SVGIcon(
            viewBox: 24,
            body: """
            <circle cx="12" cy="12" r="8" fill="#ff3366">
              <animate attributeName="r" from="4" to="10" dur="1s" repeatCount="indefinite"/>
            </circle>
            """
        )

        #expect(staticPath.hasAnimation == false)
        #expect(staticPath.animDuration == nil)
        #expect(staticBody.hasAnimation == false)
        #expect(multiColorAnim.isColorIcon == true)
        #expect(multiColorAnim.hasAnimation == false)
        #expect(multiColorAnim.animDuration == nil)

        #expect(ts.iconKind(staticPath) == .mono)
        #expect(ts.iconKind(staticBody) == .mono)
        #expect(ts.iconKind(multiColorAnim) == .color)
        #expect(ts.isColorIcon(multiColorAnim) == true)
        #expect(ts.hasAnimatedIcons == false)

        // Multi-colour animated icons stay static via colorIcon and return nil from animatedIconQuad.
        #expect(ts.animatedIconQuad(multiColorAnim, pixelSize: 24, at: 0.25) == nil)
        let colorImg = try #require(ts.colorIcon(multiColorAnim, pixelSize: 24))
        #expect(colorImg.width == 24 && colorImg.height == 24)

        // Monochrome SMIL icon classifies as .animatedMono and activates hasAnimatedIcons.
        #expect(Self.pulseDot.hasAnimation == true)
        #expect(Self.pulseDot.animDuration == .infinity)
        #expect(Self.finiteFade.hasAnimation == true)
        #expect(Self.finiteFade.animDuration == 0.5)
        #expect(ts.iconKind(Self.pulseDot) == .animatedMono)
        #expect(ts.isColorIcon(Self.pulseDot) == false)
        #expect(ts.colorIcon(Self.pulseDot, pixelSize: 24) == nil)
        #expect(ts.hasAnimatedIcons == true)
        #expect(ts.iconAnimIsFinite(Self.pulseDot) == false)
        #expect(ts.iconAnimIsFinite(Self.finiteFade) == true)
    }

    @Test("Unsupported SMIL attributes and event-based begins fall back cleanly to staticOnly")
    func unsupportedSMILFallsBackToStatic() {
        let dashAnim = SVGIcon(
            viewBox: 24,
            body: """
            <rect x="4" y="4" width="16" height="16" stroke="currentColor" fill="none">
              <animate attributeName="stroke-dashoffset" from="0" to="10" dur="1s" repeatCount="indefinite"/>
            </rect>
            """
        )
        let clickBegin = SVGIcon(
            viewBox: 24,
            body: """
            <circle cx="12" cy="12" r="8">
              <animate attributeName="r" from="4" to="8" dur="1s" begin="click"/>
            </circle>
            """
        )
        let indefBegin = SVGIcon(
            viewBox: 24,
            body: """
            <circle cx="12" cy="12" r="8">
              <animate attributeName="r" from="4" to="8" dur="1s" begin="indefinite"/>
            </circle>
            """
        )

        #expect(SVGIconAnimParser.compile(dashAnim.body!, viewBox: 24) == .staticOnly)
        #expect(SVGIconAnimParser.compile(clickBegin.body!, viewBox: 24) == .staticOnly)
        #expect(SVGIconAnimParser.compile(indefBegin.body!, viewBox: 24) == .staticOnly)

        let ts = TextSystem()
        #expect(ts.iconKind(dashAnim) == .mono)
        #expect(ts.iconKind(clickBegin) == .mono)
        #expect(ts.hasAnimatedIcons == false)
        // Static fallback still renders the shape normally!
        let cov = GlyphAtlas.rasterizeIconBitmap(clickBegin, pixelSize: 24)
        #expect(Self.sumAlpha(cov) > 0)
    }

    // MARK: - 2. XML Scanner, Clock Parser & Hostile-Input Caps

    @Test("XML scanner handles comments, PIs, and '>' inside quoted attributes, and rejects DTD/CDATA/NUL/malformed XML")
    func xmlScannerEdgeCases() {
        let valid = """
        <?xml version="1.0"?>
        <!-- comment with > inside -->
        <g data-note="a > b" opacity='1'>
          <circle cx='12' cy='12' r='6'>
            <animate attributeName="r" values="4;8" dur="1s" repeatCount="indefinite"/>
          </circle>
        </g>
        """
        if case .animated(let plan) = SVGIconAnimParser.compile(valid, viewBox: 24) {
            #expect(plan.tracks.count == 1)
        } else {
            Issue.record("Expected valid XML with comments, PIs, and '>' in attributes to compile")
        }

        let dtd = #"<!DOCTYPE svg><circle cx="12" cy="12" r="6"><animate attributeName="r" from="4" to="8" dur="1s"/></circle>"#
        let cdata = #"<![CDATA[x]]><circle cx="12" cy="12" r="6"><animate attributeName="r" from="4" to="8" dur="1s"/></circle>"#
        let nul = "<circle cx=\"12\" cy=\"12\" r=\"6\">\u{0}<animate attributeName=\"r\" from=\"4\" to=\"8\" dur=\"1s\"/></circle>"
        let unclosed = #"<g><circle cx="12" cy="12" r="6"><animate attributeName="r" from="4" to="8" dur="1s"/></circle>"#
        let mismatched = #"<g><circle cx="12" cy="12" r="6"><animate attributeName="r" from="4" to="8" dur="1s"/></g></circle>"#

        for hostile in [dtd, cdata, nul, unclosed, mismatched] {
            #expect(SVGIconAnimParser.compile(hostile, viewBox: 24) == .rejected)
            // Failed animated SVGs must return empty coverage instead of falling back to static parser!
            let icon = SVGIcon(viewBox: 24, body: hostile)
            let cov = GlyphAtlas.rasterizeIconBitmap(icon, pixelSize: 24)
            #expect(Self.sumAlpha(cov) == 0)
        }
    }

    @Test("SMIL clock parser supports full clock syntax and rejects double signs and invalid ranges")
    func clockParsing() {
        #expect(SVGIconAnimParser.parseClock("500ms") == 0.5)
        #expect(SVGIconAnimParser.parseClock("1.5s") == 1.5)
        #expect(SVGIconAnimParser.parseClock("2.5") == 2.5)
        #expect(SVGIconAnimParser.parseClock("2min") == 120.0)
        #expect(SVGIconAnimParser.parseClock("1h") == 3600.0)
        #expect(SVGIconAnimParser.parseClock("01:30.5") == 90.5)
        #expect(SVGIconAnimParser.parseClock("01:02:03.25") == 3723.25)
        #expect(SVGIconAnimParser.parseClock("-0.25s") == -0.25)
        #expect(SVGIconAnimParser.parseClock("+250ms") == 0.25)

        // Double signs and invalid components rejected.
        #expect(SVGIconAnimParser.parseClock("--1s") == nil)
        #expect(SVGIconAnimParser.parseClock("+-1s") == nil)
        #expect(SVGIconAnimParser.parseClock("-+1s") == nil)
        #expect(SVGIconAnimParser.parseClock("- -1s") == nil)
        #expect(SVGIconAnimParser.parseClock("01:60") == nil)
        #expect(SVGIconAnimParser.parseClock("01:00:60") == nil)
        #expect(SVGIconAnimParser.parseClock("1:2:3:4") == nil)
        #expect(SVGIconAnimParser.parseClock("click") == nil)
        #expect(SVGIconAnimParser.parseClock("indefinite") == nil)
        #expect(SVGIconAnimParser.parseClock("NaN") == nil)
        #expect(SVGIconAnimParser.parseClock("inf") == nil)
    }

    @Test("Enforces hostile-input pre-allocation caps across size, depth, shapes, layers, keyframes, paths, and transforms")
    func hostileCapsEnforced() {
        // 1. Body > 32 KiB
        let bigBody = "<circle cx=\"12\" cy=\"12\" r=\"6\"><animate attributeName=\"r\" from=\"4\" to=\"8\" dur=\"1s\"/></circle>"
            + String(repeating: " ", count: SVGIconAnimLimits.maxSVGBytes)
        #expect(SVGIconAnimParser.compile(bigBody, viewBox: 24) == .rejected)
        #expect(Self.sumAlpha(GlyphAtlas.rasterizeIconBitmap(SVGIcon(viewBox: 24, body: bigBody), pixelSize: 24)) == 0)

        // 2. Depth > 16
        let deep = String(repeating: "<g>", count: 17)
            + #"<circle cx="12" cy="12" r="6"><animate attributeName="r" from="4" to="8" dur="1s"/></circle>"#
            + String(repeating: "</g>", count: 17)
        #expect(SVGIconAnimParser.compile(deep, viewBox: 24) == .rejected)

        // 3. Shapes > 64
        let manyShapes = String(repeating: #"<rect x="1" y="1" width="2" height="2"/>"#, count: 65)
            + #"<circle cx="12" cy="12" r="4"><animate attributeName="r" from="2" to="6" dur="1s"/></circle>"#
        #expect(SVGIconAnimParser.compile(manyShapes, viewBox: 24) == .rejected)

        // 4. Opacity layers > 8 (including animated opacity on <g>)
        let manyLayers = String(repeating: #"<g opacity="0.5">"#, count: 9)
            + #"<circle cx="12" cy="12" r="4"><animate attributeName="r" from="2" to="6" dur="1s"/></circle>"#
            + String(repeating: "</g>", count: 9)
        #expect(SVGIconAnimParser.compile(manyLayers, viewBox: 24) == .rejected)

        let nineAnimatedGroupLayers = (0..<9).map { _ in
            #"<g><rect x="2" y="2" width="4" height="4"/><animate attributeName="opacity" from="1" to="0.5" dur="1s"/></g>"#
        }.joined()
        #expect(SVGIconAnimParser.compile(nineAnimatedGroupLayers, viewBox: 24) == .rejected)

        // 5. Keyframes > 64 (and excessive semicolons)
        let tooManyKeys = (0..<65).map { String($0) }.joined(separator: ";")
        let keyframeBomb = #"<circle cx="12" cy="12" r="4"><animate attributeName="r" values="\#(tooManyKeys)" dur="1s"/></circle>"#
        #expect(SVGIconAnimParser.compile(keyframeBomb, viewBox: 24) == .staticOnly)

        // 6. Path coordinates > MAX_COORD (4096) rejected
        let hugePath = #"<path d="M0 0 L99999 0 L99999 99999 Z"><animate attributeName="opacity" from="0.2" to="1" dur="1s"/></path>"#
        #expect(SVGIconAnimParser.compile(hugePath, viewBox: 24) == .rejected)

        // 7. Transform ops > 8 or unsafe composed scale rejected
        let tooManyTransforms = #"<g transform="\#(String(repeating: "translate(1,0) ", count: 9))"><circle cx="12" cy="12" r="4"><animate attributeName="r" from="2" to="6" dur="1s"/></circle></g>"#
        #expect(SVGIconAnimParser.compile(tooManyTransforms, viewBox: 24) == .rejected)

        let runawayScale = #"<g transform="scale(32) scale(32)"><circle cx="12" cy="12" r="4"><animate attributeName="r" from="2" to="6" dur="1s"/></circle></g>"#
        #expect(SVGIconAnimParser.compile(runawayScale, viewBox: 24) == .rejected)
    }

    // MARK: - 3. SMIL Timing, Interpolation & Semantics

    @Test("Evaluates calcMode linear, discrete, spline, and paced accurately")
    func calcModesLinearDiscreteSplinePaced() throws {
        // Linear
        let linearSVG = #"<circle cx="12" cy="12" r="4"><animate attributeName="r" values="2;10" dur="1s"/></circle>"#
        guard case .animated(let linPlan) = SVGIconAnimParser.compile(linearSVG, viewBox: 24) else {
            Issue.record("linear failed"); return
        }
        let (linMid, linSt) = linPlan.tracks[0].sample(sampleT: 0.5, runtimeT: 0.5)
        #expect(abs((linMid?.v0 ?? 0) - 6.0) < 1e-4)
        #expect(linSt == .moving)

        // Discrete: holds value for [0, 0.5) and wakes at 0.5
        let discSVG = #"<circle cx="12" cy="12" r="4"><animate attributeName="r" values="2;10" calcMode="discrete" dur="2s" repeatCount="indefinite"/></circle>"#
        guard case .animated(let discPlan) = SVGIconAnimParser.compile(discSVG, viewBox: 24) else {
            Issue.record("discrete failed"); return
        }
        let (d0, d0St) = discPlan.tracks[0].sample(sampleT: 0.25, runtimeT: 0.25)
        #expect(d0?.v0 == 2.0)
        #expect(d0St == .waitingUntil(1.0))
        let (d1, d1St) = discPlan.tracks[0].sample(sampleT: 1.25, runtimeT: 1.25)
        #expect(d1?.v0 == 10.0)
        #expect(d1St == .waitingUntil(2.0))

        // Spline: ease-in (0.42, 0, 1, 1) is below 0.5 at u = 0.5
        let splineSVG = #"<circle cx="12" cy="12" r="4"><animate attributeName="r" values="0;10" calcMode="spline" keySplines="0.42 0 1 1" dur="1s"/></circle>"#
        guard case .animated(let splPlan) = SVGIconAnimParser.compile(splineSVG, viewBox: 24) else {
            Issue.record("spline failed"); return
        }
        let (spMid, _) = splPlan.tracks[0].sample(sampleT: 0.5, runtimeT: 0.5)
        let spVal = try #require(spMid?.v0)
        #expect(spVal > 2.5 && spVal < 4.0)

        // Paced: values="0;2;10" has total distance 10, so at u = 0.5 value must be 5.0 (ignoring keyTimes!).
        let pacedSVG = #"<circle cx="12" cy="12" r="4"><animate attributeName="r" values="0;2;10" keyTimes="0;0.9;1" calcMode="paced" dur="1s"/></circle>"#
        guard case .animated(let pacedPlan) = SVGIconAnimParser.compile(pacedSVG, viewBox: 24) else {
            Issue.record("paced failed"); return
        }
        let (pcMid, _) = pacedPlan.tracks[0].sample(sampleT: 0.5, runtimeT: 0.5)
        #expect(abs((pcMid?.v0 ?? 0) - 5.0) < 1e-4)
    }

    @Test("Supports fractional repeatCount freeze, remove, timed/indefinite <set>, and positive/negative begin")
    func repeatCountFreezeSetAndBegin() {
        // Fractional repeatCount="1.25" with fill="freeze" freezes at u = 0.25 -> value = 2.5
        let fracFreeze = #"<circle cx="12" cy="12" r="1"><animate attributeName="r" from="0" to="10" dur="1s" repeatCount="1.25" fill="freeze"/></circle>"#
        guard case .animated(let ffPlan) = SVGIconAnimParser.compile(fracFreeze, viewBox: 24) else {
            Issue.record("fracFreeze failed"); return
        }
        let (ffEnd, ffSt) = ffPlan.tracks[0].sample(sampleT: 2.0, runtimeT: 2.0)
        #expect(abs((ffEnd?.v0 ?? 0) - 2.5) < 1e-4)
        #expect(ffSt == .finished)

        // fill="remove" (default) reverts to nil after completion
        let removeAnim = #"<circle cx="12" cy="12" r="4"><animate attributeName="r" from="2" to="10" dur="1s"/></circle>"#
        guard case .animated(let remPlan) = SVGIconAnimParser.compile(removeAnim, viewBox: 24) else {
            Issue.record("removeAnim failed"); return
        }
        let (remEnd, remSt) = remPlan.tracks[0].sample(sampleT: 1.5, runtimeT: 1.5)
        #expect(remEnd == nil)
        #expect(remSt == .finished)

        // <set> without dur: waits until begin, then applies once and is immediately .finished!
        let indefSet = #"<circle cx="12" cy="12" r="4"><set attributeName="r" to="9" begin="0.5s"/></circle>"#
        guard case .animated(let setPlan) = SVGIconAnimParser.compile(indefSet, viewBox: 24) else {
            Issue.record("indefSet failed"); return
        }
        #expect(setPlan.hasIndefinite == false)
        let (sBefore, sBeforeSt) = setPlan.tracks[0].sample(sampleT: 0.1, runtimeT: 10.1)
        #expect(sBefore == nil)
        #expect(sBeforeSt == .waitingUntil(10.5))
        let (sAt, sAtSt) = setPlan.tracks[0].sample(sampleT: 0.5, runtimeT: 10.5)
        #expect(sAt?.v0 == 9.0)
        #expect(sAtSt == .finished)

        // <set> with finite dur="1s" and fill="remove": active during [0.5, 1.5), wakes at 1.5, then reverts
        let timedSet = #"<circle cx="12" cy="12" r="4"><set attributeName="r" to="9" begin="0.5s" dur="1s"/></circle>"#
        guard case .animated(let tsPlan) = SVGIconAnimParser.compile(timedSet, viewBox: 24) else {
            Issue.record("timedSet failed"); return
        }
        let (tsDuring, tsDuringSt) = tsPlan.tracks[0].sample(sampleT: 0.75, runtimeT: 5.75)
        #expect(tsDuring?.v0 == 9.0)
        #expect(tsDuringSt == .waitingUntil(6.5))
        let (tsAfter, tsAfterSt) = tsPlan.tracks[0].sample(sampleT: 1.5, runtimeT: 6.5)
        #expect(tsAfter == nil)
        #expect(tsAfterSt == .finished)

        // Negative begin starts mid-cycle at t = 0
        let negBegin = #"<circle cx="12" cy="12" r="4"><animate attributeName="r" from="0" to="10" begin="-0.5s" dur="1s" repeatCount="indefinite"/></circle>"#
        guard case .animated(let nbPlan) = SVGIconAnimParser.compile(negBegin, viewBox: 24) else {
            Issue.record("negBegin failed"); return
        }
        let (nbVal, _) = nbPlan.tracks[0].sample(sampleT: 0.0, runtimeT: 0.0)
        #expect(abs((nbVal?.v0 ?? 0) - 5.0) < 1e-4)
    }

    @Test("Supports by-only, to-only with inherited <g> paint, negative additive='sum', normalized scale, and per-track animateTransform")
    func additiveByToInheritedAndTransforms() throws {
        // 1. Signed negative by-only on radius (implicitly additive="sum"): 8 + (0 -> -6) = 8 -> 2
        let negBy = SVGIcon(
            viewBox: 24,
            body: #"<circle cx="12" cy="12" r="8" fill="currentColor"><animate attributeName="r" by="-6" dur="1s" fill="freeze"/></circle>"#
        )
        let ts = TextSystem()
        #expect(ts.iconKind(negBy) == .animatedMono)
        let bigStart = try #require(ts.animatedIcons.renderCoverage(negBy, pixelSize: 24, at: 0.0))
        let smallEnd = try #require(ts.animatedIcons.renderCoverage(negBy, pixelSize: 24, at: 1.0))
        #expect(Self.sumAlpha(bigStart.coverage) > Self.sumAlpha(smallEnd.coverage) * 4)

        // 2. by-only scale: (1, 1) -> (1 + bx, 1 + by), NOT (0, 0) -> (bx, by)
        let byScale = #"<rect x="6" y="6" width="12" height="12"><animateTransform attributeName="transform" type="scale" by="1" dur="1s"/></rect>"#
        guard case .animated(let bsPlan) = SVGIconAnimParser.compile(byScale, viewBox: 24) else {
            Issue.record("byScale failed"); return
        }
        #expect(bsPlan.tracks[0].additiveSum == true)
        #expect(bsPlan.tracks[0].values[0].v0 == 1.0 && bsPlan.tracks[0].values[0].v1 == 1.0)
        #expect(bsPlan.tracks[0].values[1].v0 == 2.0 && bsPlan.tracks[0].values[1].v1 == 2.0)

        // 3. Normalized 1-arg / 2-arg scale: values="1; 2 1" keeps sy == 1.0 at all times
        let mixedScale = #"<rect x="6" y="6" width="12" height="12"><animateTransform attributeName="transform" type="scale" values="1; 2 1" dur="1s"/></rect>"#
        guard case .animated(let msPlan) = SVGIconAnimParser.compile(mixedScale, viewBox: 24) else {
            Issue.record("mixedScale failed"); return
        }
        let (msMid, _) = msPlan.tracks[0].sample(sampleT: 0.5, runtimeT: 0.5)
        #expect(abs((msMid?.v0 ?? 0) - 1.5) < 1e-4)
        #expect(abs((msMid?.v1 ?? 0) - 1.0) < 1e-4)

        // 4. Inherited <g> stroke-width used as base for `to`-only animation
        let inheritedStroke = """
        <g stroke="currentColor" stroke-width="6" fill="none">
          <line x1="4" y1="12" x2="20" y2="12">
            <animate attributeName="stroke-width" to="2" dur="1s" fill="freeze"/>
          </line>
        </g>
        """
        guard case .animated(let isPlan) = SVGIconAnimParser.compile(inheritedStroke, viewBox: 24) else {
            Issue.record("inheritedStroke failed"); return
        }
        #expect(isPlan.tracks[0].values[0].v0 == 6.0)
        #expect(isPlan.tracks[0].values[1].v0 == 2.0)

        // 5. Per-track additive="replace" vs additive="sum" on <animateTransform>
        let stackedTransforms = SVGIcon(
            viewBox: 24,
            body: """
            <rect x="0" y="0" width="6" height="6" fill="currentColor" transform="translate(10 10)">
              <animateTransform attributeName="transform" type="translate" from="0 0" to="0 0" dur="1s" additive="replace" fill="freeze"/>
              <animateTransform attributeName="transform" type="translate" from="2 2" to="14 2" dur="1s" additive="sum" fill="freeze"/>
            </rect>
            """
        )
        #expect(ts.iconKind(stackedTransforms) == .animatedMono)
        let stStart = try #require(ts.animatedIcons.renderCoverage(stackedTransforms, pixelSize: 24, at: 0.0))
        let stEnd = try #require(ts.animatedIcons.renderCoverage(stackedTransforms, pixelSize: 24, at: 1.0))
        // At t = 0: rect is at (2, 2)-(8, 8) (replace discarded base translate(10, 10), sum added (2, 2)).
        #expect(stStart.coverage[4 * 24 + 4] > 200)
        #expect(stStart.coverage[4 * 24 + 16] == 0)
        // At t = 1: rect moved right to (14, 2)-(20, 8).
        #expect(stEnd.coverage[4 * 24 + 4] == 0)
        #expect(stEnd.coverage[4 * 24 + 16] > 200)
    }

    @Test("Renders all shape primitives including non-uniform <rect rx ry>, <ellipse>, <polygon>, <path>, and group opacity layers")
    func shapePrimitivesAndGroupOpacity() throws {
        let richShapes = SVGIcon(
            viewBox: 24,
            body: """
            <g opacity="1">
              <animate attributeName="opacity" from="1" to="0.5" dur="1s" fill="freeze"/>
              <rect x="2" y="2" width="10" height="8" rx="4" ry="1" fill="currentColor"/>
              <ellipse cx="18" cy="6" rx="4" ry="2" fill="currentColor"/>
              <polygon points="2,14 10,14 6,22" fill="currentColor"/>
              <polyline points="12,14 20,14 20,22" stroke="currentColor" stroke-width="2" fill="none"/>
              <path d="M12 20 L18 20" stroke="currentColor" stroke-width="2" fill="none"/>
            </g>
            """
        )
        let ts = TextSystem()
        #expect(ts.iconKind(richShapes) == .animatedMono)
        let t0 = try #require(ts.animatedIcons.renderCoverage(richShapes, pixelSize: 24, at: 0.0))
        let t1 = try #require(ts.animatedIcons.renderCoverage(richShapes, pixelSize: 24, at: 1.0))
        let sum0 = Self.sumAlpha(t0.coverage)
        let sum1 = Self.sumAlpha(t1.coverage)
        #expect(sum0 > 0)
        // Group opacity dropped from 1.0 to 0.5, so total alpha should be roughly half.
        #expect(abs(Double(sum1) / Double(sum0) - 0.5) < 0.08)
    }

    // MARK: - 4. Flat-Hold Sleep, Pixel-Change Probing & Reduced Motion

    @Test("Flat holds return WaitingUntil end of hold and slow motion probes ahead to next quantized pixel change")
    func flatHoldAndPixelChangeProbing() throws {
        let ts = TextSystem()
        // Flat hold: opacity stays 0.2 from t = 0.0 to t = 1.0 (keyTimes="0;0.5;1" dur="2s").
        let qHold = try #require(ts.animatedIconQuad(Self.flatHoldIcon, pixelSize: 24, at: 0.1))
        guard case .waitingUntil(let wake) = qHold.state else {
            Issue.record("Expected flat hold to sleep with .waitingUntil, got \(qHold.state)")
            return
        }
        #expect(abs(wake - 1.0) < 1e-4)

        // Calling again during the flat hold reuses the slot without re-rasterizing or flipping UV.
        let qHold2 = try #require(ts.animatedIconQuad(Self.flatHoldIcon, pixelSize: 24, at: 0.5))
        #expect(qHold2.entry.uv == qHold.entry.uv)
        #expect(qHold2.changed == false)

        // Very slow opacity fade (0.5 -> 0.52 over 60s): quantized 8-bit pixels do not change for > 0.4s,
        // so forward probing skips all 12 steps (0.4s) rather than waking at 33.3ms!
        let verySlow = SVGIcon(
            viewBox: 24,
            body: #"<rect x="4" y="4" width="16" height="16"><animate attributeName="opacity" from="0.5" to="0.52" dur="60s" repeatCount="indefinite"/></rect>"#
        )
        let qSlow = try #require(ts.animatedIconQuad(verySlow, pixelSize: 16, at: 0.0))
        guard case .waitingUntil(let slowWake) = qSlow.state else {
            Issue.record("Expected slow animation to pace via .waitingUntil, got \(qSlow.state)")
            return
        }
        #expect(slowWake >= 0.39)
    }

    @Test("Reduced-motion static rasterization matches animated t = 0 resting frame pixel-for-pixel")
    func reducedMotionMatchesRestingFrame() throws {
        let ts = TextSystem()
        let staticCov = GlyphAtlas.rasterizeIconBitmap(Self.pulseDot, pixelSize: 24)
        let animQuad = try #require(ts.animatedIconQuad(Self.pulseDot, pixelSize: 24, at: 0.0))
        let animCov = Self.readTilePixels(atlas: ts.glyphAtlas, entry: animQuad.entry)
        #expect(staticCov == animCov)
        #expect(Self.sumAlpha(staticCov) > 0)
    }

    // MARK: - 5. Double-Buffered Glyph Atlas Tiles, Upload Gen, Eviction & In-Place Boundary

    @Test("Double-buffered tiles keep 1px transparent apron, flip UV only on pixel change, and reuse without leaking atlas slots")
    func doubleBufferedTileFlipAndApron() throws {
        let atlas = GlyphAtlas(width: 256, height: 256)
        let ts = TextSystem(glyphAtlas: atlas)

        let q0 = try #require(ts.animatedIconQuad(Self.pulseDot, pixelSize: 24, at: 0.0))
        #expect(q0.changed == true)
        #expect(ts.iconAnimSlotsReady(Self.pulseDot, pixelSize: 24) == true)
        let rasterizedAfterInit = atlas.rasterized
        // Both slots pre-allocated during initial full paint (2 slots).
        #expect(rasterizedAfterInit == 2)

        // Verify 1-texel transparent apron around (pixelOrigin.x, pixelOrigin.y, 24, 24).
        let pageData = try #require(atlas.pageData(Int(q0.entry.page)))
        let stride = atlas.atlases[Int(q0.entry.page)].width
        let ix = q0.entry.pixelOrigin.x
        let iy = q0.entry.pixelOrigin.y
        for c in (ix - 1)...(ix + 24) {
            #expect(pageData[(iy - 1) * stride + c] == 0)
            #expect(pageData[(iy + 24) * stride + c] == 0)
        }
        for r in 0..<24 {
            #expect(pageData[(iy + r) * stride + (ix - 1)] == 0)
            #expect(pageData[(iy + r) * stride + (ix + 24)] == 0)
        }

        // Same timestamp reuses slot 0 with changed == false.
        let q0Same = try #require(ts.animatedIconQuad(Self.pulseDot, pixelSize: 24, at: 0.0))
        #expect(q0Same.entry.uv == q0.entry.uv)
        #expect(q0Same.changed == false)

        // Advance to t = 0.25 (larger radius): flips to slot 1 with DIFFERENT UV and NO new atlas allocation!
        let q1 = try #require(ts.animatedIconQuad(Self.pulseDot, pixelSize: 24, at: 0.25))
        #expect(q1.changed == true)
        #expect(q1.entry.uv != q0.entry.uv)
        #expect(atlas.rasterized == rasterizedAfterInit)

        // Advance to t = 0.5 (peak radius): flips back to slot 0 UV!
        let q2 = try #require(ts.animatedIconQuad(Self.pulseDot, pixelSize: 24, at: 0.5))
        #expect(q2.changed == true)
        #expect(q2.entry.uv == q0.entry.uv)
        #expect(atlas.rasterized == rasterizedAfterInit)

        // Partial damage: framePages patch covers only the updated tile band, not the whole 256x256 page.
        _ = atlas.framePages()
        let q3 = try #require(ts.animatedIconQuad(Self.pulseDot, pixelSize: 24, at: 0.75))
        #expect(q3.changed == true)
        let snap = atlas.framePages()
        let patch = try #require(snap.patches[Int(q3.entry.page)])
        let patchW = patch.edges.z - patch.edges.x
        let patchH = patch.edges.w - patch.edges.y
        #expect(patchW == 28 && patchH == 28) // px + 2 apron + 2 gutter = 28
    }

    @Test("Missed drawable uploadGen overwrites current slot in place without flipping onto on-screen slot")
    func missedDrawableUploadGenProtection() throws {
        let atlas = GlyphAtlas(width: 256, height: 256)
        let ts = TextSystem(glyphAtlas: atlas)

        // Prime uploadGen >= 1 as a live renderer does.
        atlas.rowsUploaded(page: 0, rows: (0, 1))

        // Frame 1 writes slot 0 at uploadGen == 1.
        let f1 = try #require(ts.animatedIconQuad(Self.pulseDot, pixelSize: 24, at: 0.0))
        #expect(f1.changed == true)
        // Renderer uploads frame 1 -> uploadGen becomes 2.
        atlas.rowsUploaded(page: 0, rows: (0, 32))

        // Frame 2 writes slot 1 at uploadGen == 2 (UV flips away from on-screen slot 0).
        let f2 = try #require(ts.animatedIconQuad(Self.pulseDot, pixelSize: 24, at: 0.25))
        #expect(f2.changed == true)
        #expect(f2.entry.uv != f1.entry.uv)

        // Suppose Frame 2 MISSED its drawable (no rowsUploaded call, uploadGen is still 2!).
        // Frame 3 must overwrite slot 1 IN PLACE (keeping f2.entry.uv) rather than overwriting slot 0!
        let f3 = try #require(ts.animatedIconQuad(Self.pulseDot, pixelSize: 24, at: 0.5))
        #expect(f3.changed == true)
        #expect(f3.entry.uv == f2.entry.uv)

        // Same timestamp again while still pending upload still reports changed == true.
        let f3Dup = try #require(ts.animatedIconQuad(Self.pulseDot, pixelSize: 24, at: 0.5))
        #expect(f3Dup.entry.uv == f2.entry.uv)
        #expect(f3Dup.changed == true)

        // Now renderer uploads -> uploadGen becomes 3 -> Frame 4 flips cleanly back to slot 0!
        atlas.rowsUploaded(page: 0, rows: (0, 32))
        let f4 = try #require(ts.animatedIconQuad(Self.pulseDot, pixelSize: 24, at: 0.75))
        #expect(f4.changed == true)
        #expect(f4.entry.uv == f1.entry.uv)
    }

    @Test("In-place loop step updates tiles without allocating or evicting, and eviction invalidates stale page generations")
    func inPlaceBoundaryAndPageGenEviction() throws {
        let atlas = GlyphAtlas(width: 256, height: 256)
        let ts = TextSystem(glyphAtlas: atlas)

        // Before initial full paint, slots are not ready and in-place refuses to allocate.
        #expect(ts.iconKind(Self.pulseDot) == .animatedMono)
        #expect(ts.iconAnimSlotsReady(Self.pulseDot, pixelSize: 24) == false)
        #expect(ts.animatedIconQuadInPlace(Self.pulseDot, pixelSize: 24, at: 0.0) == nil)
        #expect(atlas.rasterized == 0)

        // Full paint pre-allocates both slots.
        let q0 = try #require(ts.animatedIconQuad(Self.pulseDot, pixelSize: 24, at: 0.0))
        #expect(ts.iconAnimSlotsReady(Self.pulseDot, pixelSize: 24) == true)
        let rasterBefore = atlas.rasterized
        let resetsBefore = atlas.resets

        // Loop-step in-place update flips to slot 1 with zero allocation and zero eviction.
        let q1 = try #require(ts.animatedIconQuadInPlace(Self.pulseDot, pixelSize: 24, at: 0.5))
        #expect(q1.changed == true)
        #expect(q1.entry.uv != q0.entry.uv)
        #expect(atlas.rasterized == rasterBefore)
        #expect(atlas.resets == resetsBefore)

        // Evicting the slot's page bumps pageGen -> slotsReady becomes false and in-place returns nil.
        let oldGen = atlas.pageGen(q0.entry.page)
        atlas.evictPage(Int(q0.entry.page))
        #expect(atlas.pageGen(q0.entry.page) > oldGen)
        #expect(ts.iconAnimSlotsReady(Self.pulseDot, pixelSize: 24) == false)
        #expect(ts.animatedIconQuadInPlace(Self.pulseDot, pixelSize: 24, at: 0.75) == nil)

        // Next full paint recovers cleanly by re-allocating.
        let q2 = try #require(ts.animatedIconQuad(Self.pulseDot, pixelSize: 24, at: 0.75))
        #expect(q2.changed == true)
        #expect(atlas.pageGen(q2.entry.page) > oldGen)
    }

    @Test("Popped and recreated overflow pages never collide with stale bordered slot handles")
    func overflowPagePopAndRecreateEpochMonotonic() throws {
        // Small atlas so placing 20x20 masks quickly fills pages 0, 1, and spills to overflow page 2.
        let atlas = GlyphAtlas(width: 48, height: 48)
        let dummy = [UInt8](repeating: 255, count: 20 * 20)
        // Fill pages 0 and 1, then allocate on page 2.
        var slots: [GlyphAtlas.BorderedSlot] = []
        for _ in 0..<20 {
            if let s = atlas.putBordered(px: 20, coverage: dummy) {
                slots.append(s)
            }
        }
        guard let page2Slot = slots.first(where: { $0.page == 2 }) else {
            Issue.record("Expected allocation on overflow page 2 (pageCount=\(atlas.pageCount))")
            return
        }
        let genOnPage2 = page2Slot.pageGen
        #expect(atlas.pageGen(2) == genOnPage2)

        // Advance two idle frames so overflow page 2 is evicted and popped.
        atlas.beginFrame()
        atlas.beginFrame()
        #expect(atlas.pageCount == 2)
        #expect(atlas.pageGen(2) == 0)
        #expect(atlas.writeBordered(slot: page2Slot, px: 20, coverage: dummy) == false)

        // Recreate overflow page 2: its new epoch must be strictly greater than `genOnPage2`.
        var recreatedPage2: GlyphAtlas.BorderedSlot? = nil
        for _ in 0..<20 {
            if let s = atlas.putBordered(px: 20, coverage: dummy), s.page == 2 {
                recreatedPage2 = s
                break
            }
        }
        let fresh = try #require(recreatedPage2)
        #expect(fresh.pageGen > genOnPage2)
        // Stale handle from the old page 2 is STILL rejected!
        #expect(atlas.writeBordered(slot: page2Slot, px: 20, coverage: dummy) == false)
        // Fresh handle succeeds!
        #expect(atlas.writeBordered(slot: fresh, px: 20, coverage: dummy) == true)
    }

    @Test("Finite animations isolate per-node mount time and finish cleanly, while indefinite icons share lockstep slots")
    func finiteMountTimeAndIndefiniteLockstep() throws {
        let ts = TextSystem()

        // Finite fade (0.5s): node 1 mounted at t=1.0, node 2 mounted at t=1.4 -> different scopeIDs & alpha at t=1.4!
        let n1 = try #require(ts.animatedIconQuad(Self.finiteFade, pixelSize: 24, at: 1.4, mountTime: 1.0, scopeID: 1))
        let n2 = try #require(ts.animatedIconQuad(Self.finiteFade, pixelSize: 24, at: 1.4, mountTime: 1.4, scopeID: 2))
        #expect(n1.entry.uv != n2.entry.uv)
        let pix1 = Self.readTilePixels(atlas: ts.glyphAtlas, entry: n1.entry)
        let pix2 = Self.readTilePixels(atlas: ts.glyphAtlas, entry: n2.entry)
        #expect(Self.sumAlpha(pix1) > Self.sumAlpha(pix2) * 2)

        // At t = 1.6: node 1 (elapsed 0.6s >= 0.5s) is finished, node 2 (elapsed 0.2s) is still live!
        #expect(ts.iconAnimLive(Self.finiteFade, at: 1.6, mountTime: 1.0) == false)
        #expect(ts.iconAnimLive(Self.finiteFade, at: 1.6, mountTime: 1.4) == true)
        let n1Done = try #require(ts.animatedIconQuad(Self.finiteFade, pixelSize: 24, at: 1.6, mountTime: 1.0, scopeID: 1))
        #expect(n1Done.state == .finished)

        // Indefinite icon shares the exact same lockstep slot across different scopeIDs!
        let a = try #require(ts.animatedIconQuad(Self.pulseDot, pixelSize: 24, at: 0.2, scopeID: 100))
        let b = try #require(ts.animatedIconQuad(Self.pulseDot, pixelSize: 24, at: 0.2, scopeID: 200))
        #expect(a.entry.uv == b.entry.uv)
        #expect(b.changed == false)
    }

    @Test("Mirrored facing flips animated coverage horizontally and inline pill helpers detect live animated icons")
    func mirroredFacingAndInlinePillHooks() throws {
        let asymAnim = SVGIcon(
            viewBox: 16,
            body: """
            <rect x="1" y="2" width="4" height="12" fill="currentColor">
              <animate attributeName="opacity" from="0.5" to="1.0" dur="1s" repeatCount="indefinite"/>
            </rect>
            """
        )
        let ts = TextSystem()
        let ltr = try #require(ts.animatedIconQuad(asymAnim, pixelSize: 16, mirrored: false, at: 0.5))
        let rtl = try #require(ts.animatedIconQuad(asymAnim, pixelSize: 16, mirrored: true, at: 0.5))
        let ltrPix = Self.readTilePixels(atlas: ts.glyphAtlas, entry: ltr.entry)
        let rtlPix = Self.readTilePixels(atlas: ts.glyphAtlas, entry: rtl.entry)
        let row = 8
        #expect(ltrPix[row * 16 + 2] > 100)
        #expect(rtlPix[row * 16 + 13] == ltrPix[row * 16 + 2])
        #expect(rtlPix[row * 16 + 2] == 0)

        // Pill liveness check and emitInlineIcon interception hook.
        let pill = PillChip(0..<4, style: PillStyle.default.icon(Self.finiteFade, size: 12))
        #expect(ts.iconKind(Self.finiteFade) == .animatedMono)
        #expect(ts.hasLiveAnimatedIcon(in: [pill], at: 0.2, mountTime: { _ in 0.0 }) == true)
        #expect(ts.hasLiveAnimatedIcon(in: [pill], at: 1.0, mountTime: { _ in 0.0 }) == false)

        let shaped = ts.shape(text: "Load task", spans: nil, pills: [pill], style: .body, maxWidth: nil, pixelScale: 1.0, emitGlyphs: false)
        var interceptedIcons = 0
        var prims: [Primitive] = []
        ts.emitTextDecorationsAndPills(
            shaped: shaped,
            textOriginX: 0,
            textOriginY: 0,
            scaleVec: Vec2(1, 1),
            pxScale: 1.0,
            defaultTextColor: .white,
            localAlpha: 1.0,
            srgbBlend: false,
            devClip: SIMD4(0, 0, 200, 200),
            rot: 0,
            insertImage: { _ in ImageAtlasRegion(page: 0, edges: .zero) },
            emitInlineIcon: { svg, px, _, _, outPrims in
                if ts.iconKind(svg) == .animatedMono,
                   let aq = ts.animatedIconQuad(svg, pixelSize: px, at: 0.2, mountTime: 0.0, scopeID: 7) {
                    interceptedIcons += 1
                    outPrims.append(.glyph(rect: aq.rect, uv: aq.entry.uv, color: SIMD4(1, 1, 1, 1), gamma: 1.0, clip: .zero))
                    return true
                }
                return false
            },
            into: &prims
        )
        #expect(interceptedIcons == 1)
    }

    @Test("Runtime schedules wakes, paints animated SVG icons, and supports in-place cycle tick (#1291)")
    func runtimePacesAnimatedIconAndFlipsTilesInPlace() throws {
        struct Empty {}
        let rt = Runtime(state: Empty(), viewport: Vec2(120, 120), pixelScale: 1.0, reducedMotion: false) { _, _ in
            row().sizeFull().child(icon(Self.pulseDot, size: 24).color(.white))
        }
        var frame = rt.renderFrame(at: 0.0)
        #expect(rt.animatedIconsShown == true)
        #expect(rt.cyclePaint.iconSlots.count == 1)
        let wake = try #require(rt.nextWakeDeadline(after: 0.0))
        #expect(wake > 0.0 && wake <= 0.5)
        let glyphBefore = try #require(frame.instances.first { $0.params.y == KIND_GLYPH })
        let serial = rt.cyclePaint.serial
        let commit = rt.viewCommitCount
        let ticked = rt.paintCycleTick(frame: &frame, serial: serial, commit: commit, at: wake + 0.05)
        #expect(ticked == true)
        let glyphAfter = try #require(frame.instances.first { $0.params.y == KIND_GLYPH })
        #expect(glyphAfter.uv != glyphBefore.uv)
        #expect(AnimSource.names(AnimSource.iconAnim) == ["icon-anim"])
    }

    @Test("Runtime holds reduced-motion animated SVG icon at t=0 with zero scheduled wakes (#1291)")
    func runtimeReducedMotionHoldsStaticFirstFrame() {
        struct Empty {}
        let rt = Runtime(state: Empty(), viewport: Vec2(120, 120), pixelScale: 1.0, reducedMotion: true) { _, _ in
            row().sizeFull().child(icon(Self.pulseDot, size: 24).color(.white))
        }
        _ = rt.renderFrame(at: 0.0)
        #expect(rt.isAnimating == false)
        #expect(rt.animatedIconsShown == false)
        #expect(rt.cyclePaint.iconSlots.isEmpty)
        #expect(rt.nextWakeDeadline(after: 0.0) == nil)
    }

    @Test("Runtime finite animated SVG icon wakes while live and sleeps cleanly once finished (#1291)")
    func runtimeFiniteAnimatedIconFinishesAndSleeps() throws {
        struct Empty {}
        let rt = Runtime(state: Empty(), viewport: Vec2(120, 120), pixelScale: 1.0, reducedMotion: false) { _, _ in
            row().sizeFull().cache().child(icon(Self.finiteFade, size: 24).color(.white))
        }
        let frame0 = rt.renderFrame(at: 0.0)
        #expect(rt.animatedIconsShown == true)
        #expect(rt.nextWakeDeadline(after: 0.0) != nil)
        #expect(frame0.elidedLayers.isEmpty)

        _ = rt.renderFrame(at: 1.0)
        #expect(rt.animatedIconsShown == false)
        #expect(rt.isAnimating == false)
        #expect(rt.nextWakeDeadline(after: 1.0) == nil)
    }
}
