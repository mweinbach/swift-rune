import Foundation
import Testing
@testable import Rune
import RuneMotion
import RuneRef

@Suite("Flights & One-Snap Proof Parity (flights_tests.rs & one_snap.rs:506)")
struct FlightsAndOneSnapProofParityTests {

    private func matchingFillPrims(_ scene: RefScene, _ target: SIMD4<Float>) -> [Primitive] {
        scene.primitives.filter { p in
            p.kind == .roundedRect
                && abs(p.fill.x - target.x) < 0.01
                && abs(p.fill.y - target.y) < 0.01
                && abs(p.fill.z - target.z) < 0.01
        }
    }

    // MARK: - runtime/motion/flights_tests.rs (:39, :51, :85)

    @Test("flights_tests.rs:39 - a_waiting_launch_whose_destination_never_mounts_ends_by_its_answer")
    func waitingLaunchWhoseDestinationNeverMountsEndsByItsAnswer() {
        struct State {
            var showNowhere = false
            var tick = 0
        }
        let targetColor = Color.srgb(0.25, 0.55, 0.9)
        let rt = Runtime<State>(
            state: State(),
            viewport: Vec2(400, 300),
            pixelScale: 1.0
        ) { s, _ in
            var root: El<State> = col().size(400, 300)
                .child(text("hello").key("src-text").absolute(x: 240, y: 220).size(44, 16))
            if s.showNowhere {
                root = root.child(
                    row().child(text("hello"))
                        .key("nowhere")
                        .bg(targetColor)
                        .absolute(x: 20, y: 40)
                        .size(120, 36)
                )
            }
            return root
        }

        _ = rt.frame(at: 0.0)
        #expect(!rt.isAnimating)

        // Commit 1: ask for a launch to "nowhere", which does not mount.
        rt.update(at: 0.1) { s, tx in
            s.tick = 1
            tx.launch("src-text", to: "nowhere")
        }
        _ = rt.frame(at: 0.11)
        #expect(rt.launchedFlightIds.isEmpty, "missing destination never flies")

        // Commit 2: still absent -> pending attempt expires cleanly ("missed").
        rt.update(at: 0.2) { s, _ in s.tick = 2 }
        _ = rt.frame(at: 0.21)
        #expect(!rt.isAnimating)
        #expect(rt.launchedFlightIds.isEmpty)

        // Commit 3: mounting "nowhere" later must not start a stale flight from src-text.
        rt.update(at: 0.3) { s, _ in s.showNowhere = true }
        _ = rt.frame(at: 0.31)
        #expect(!rt.isAnimating, "an answer to a launch that is gone changes nothing")
        #expect(rt.launchedFlightIds.isEmpty)
        let landed = rt.element(byKey: "nowhere")
        #expect(landed != nil)
        if let rect = landed?.rect, rect.count >= 4 {
            #expect(abs(rect[0] - 20.0) < 0.5)
            #expect(abs(rect[1] - 40.0) < 0.5)
            #expect(abs(rect[2] - 120.0) < 0.5)
            #expect(abs(rect[3] - 36.0) < 0.5)
        }
    }

    @Test("flights_tests.rs:51 - a_launch_in_the_air_flies_at_its_own_size_until_its_flight_leaves")
    func launchInTheAirFliesAtItsOwnSizeUntilFlightLeaves() {
        struct State {
            var launched = false
        }
        let targetColor = Color.srgb(0.2, 0.45, 0.85)
        let rt = Runtime<State>(
            state: State(),
            viewport: Vec2(400, 300),
            pixelScale: 1.0
        ) { s, _ in
            var clipBox: El<State> = col().key("left-clip").absolute(x: 0, y: 0).size(160, 300).clip(true)
            if s.launched {
                clipBox = clipBox.child(
                    row().child(text("hello"))
                        .key("dst-launch")
                        .bg(targetColor)
                        .absolute(x: 20, y: 40)
                        .size(140, 48)
                )
            }
            return col().size(400, 300)
                .child(clipBox)
                .child(text("hello").key("src-text").absolute(x: 240, y: 220).size(44, 16))
        }

        _ = rt.frame(at: 0.0)
        #expect(!rt.isAnimating)

        rt.update(at: 0.1) { s, tx in
            s.launched = true
            tx.launch("src-text", to: "dst-launch")
        }
        let airScene = rt.frame(at: 0.12)
        #expect(rt.isAnimating)
        #expect(rt.launchedFlightIds.count == 1, "one flight in the air at dst-launch")

        let mid = rt.element(byKey: "dst-launch")
        #expect(mid != nil)
        if let rect = mid?.rect, rect.count >= 4 {
            // In the air near src (240, 220), keeping dst-launch's own 140x48 size rather than src's 44x16.
            #expect(rect[0] > 160.0)
            #expect(rect[1] > 45.0)
            #expect(abs(rect[2] - 140.0) < 0.5)
            #expect(abs(rect[3] - 48.0) < 0.5)
        }
        let targetFill = targetColor.simd4(srgb: rt.srgbBlend)
        let airPrims = matchingFillPrims(airScene, targetFill)
        #expect(airPrims.count == 1, "lifted once, not drawn twice")
        #expect(airPrims[0].clip == SIMD4<Float>(0, 0, 400, 300), "in the air, drawn outside every clip")

        // Keep step mid-flight before settling.
        let stillAirScene = rt.frame(at: 0.15)
        #expect(rt.isAnimating)
        #expect(rt.launchedFlightIds.count == 1)
        let stillAirPrims = matchingFillPrims(stillAirScene, targetFill)
        #expect(stillAirPrims.count == 1)
        #expect(stillAirPrims[0].clip == SIMD4<Float>(0, 0, 400, 300))

        // Landed: clip applies again and flight is gone.
        let landedScene = rt.frame(at: 2.0)
        #expect(!rt.isAnimating)
        #expect(rt.launchedFlightIds.isEmpty)
        let landedPrims = matchingFillPrims(landedScene, targetFill)
        #expect(landedPrims.count == 1)
        #expect(landedPrims[0].clip.z <= 160.5, "landed, it clips again")
    }

    @Test("flights_tests.rs:85 - a_launch_over_a_node_matched_unclipped_is_one_flight_that_stays_unclipped")
    func launchOverNodeMatchedUnclippedIsOneFlightThatStaysUnclipped() {
        struct State {
            var stage = 0
        }
        let sharedColor = Color.srgb(0.85, 0.35, 0.2)
        let rt = Runtime<State>(
            state: State(),
            viewport: Vec2(400, 300),
            pixelScale: 1.0
        ) { s, _ in
            var clipBox: El<State> = col().key("left-clip").absolute(x: 0, y: 0).size(160, 300).clip(true)
            if s.stage == 1 {
                clipBox = clipBox.child(
                    row().child(text("hello"))
                        .key("matched-dst-1")
                        .flightId("shared-card")
                        .bg(sharedColor)
                        .absolute(x: 20, y: 120)
                        .size(110, 32)
                )
            } else if s.stage == 2 {
                clipBox = clipBox.child(
                    row().child(text("hello"))
                        .key("matched-dst-2")
                        .flightId("shared-card")
                        .bg(sharedColor)
                        .absolute(x: 20, y: 40)
                        .size(120, 40)
                )
            }
            var root: El<State> = col().size(400, 300)
                .child(clipBox)
                .child(text("hello").key("src-text").absolute(x: 240, y: 220).size(44, 16))
            if s.stage == 0 {
                root = root.child(
                    row().child(text("hello"))
                        .key("matched-src")
                        .flightId("shared-card")
                        .bg(sharedColor)
                        .absolute(x: 240, y: 120)
                        .size(60, 24)
                )
            }
            return root
        }

        _ = rt.frame(at: 0.0)
        #expect(!rt.isAnimating)
        let targetFill = sharedColor.simd4(srgb: rt.srgbBlend)

        // Stage 1: unclipped matched flight + Tx.launch over the same node is one deduplicated unclipped flight.
        rt.update(at: 0.1) { s, tx in
            s.stage = 1
            tx.unclippedFlights()
            tx.launch("src-text", to: "matched-dst-1")
        }
        let mid1 = rt.frame(at: 0.12)
        #expect(rt.isAnimating)
        #expect(rt.launchedFlightIds.count == 1)
        let prims1 = matchingFillPrims(mid1, targetFill)
        #expect(prims1.count == 1, "matched entry gives way to launch; never drawn twice")
        #expect(prims1[0].clip == SIMD4<Float>(0, 0, 400, 300), "stays unclipped")

        // Stage 2 while stage 1 is in the air unclipped: launch over remounted unclipped matched node keeps one unclipped flight.
        rt.update(at: 0.14) { s, tx in
            s.stage = 2
            tx.unclippedFlights()
            tx.launch("src-text", to: "matched-dst-2")
        }
        let mid2 = rt.frame(at: 0.16)
        #expect(rt.isAnimating)
        #expect(rt.launchedFlightIds.count == 1)
        let prims2 = matchingFillPrims(mid2, targetFill)
        #expect(prims2.count == 1, "one flight per node, never beside it")
        #expect(prims2[0].clip == SIMD4<Float>(0, 0, 400, 300), "remains unclipped")

        // After settling, flight ends and clipping returns.
        let landed = rt.frame(at: 2.0)
        #expect(!rt.isAnimating)
        #expect(rt.launchedFlightIds.isEmpty)
        let landedPrims = matchingFillPrims(landed, targetFill)
        #expect(landedPrims.count == 1)
        #expect(landedPrims[0].clip.z <= 160.5, "gone with its flight")
    }

    // MARK: - runtime/tests/one_snap.rs:506 capture_one_snap_proof

    private static let ringIcon = SVGIcon(
        viewBox: 16.0,
        body: #"<circle cx="8" cy="8" r="6.5" stroke="currentColor" stroke-width="1.5" fill="none"/>"#
    )
    private static let discIcon = SVGIcon(
        viewBox: 16.0,
        body: #"<circle cx="8" cy="8" r="4" fill="currentColor"/>"#
    )

    private static func circlePoints(cx: Float, cy: Float, r: Float) -> [Vec2] {
        (0..<64).map { k in
            let a = Float.pi * 2.0 * Float(k) / 64.0
            return Vec2(cx + r * cos(a), cy + r * sin(a))
        }
    }

    private static func discShape(r: Float, color: Color) -> Shape {
        Shape.new().fill(circlePoints(cx: 8.0, cy: 8.0, r: r), color: color)
    }

    private static func channelMoments(_ frame: Frame, channel: Int) -> (SIMD2<Float>, Float) {
        var sum = 0.0
        var sx = 0.0
        var sy = 0.0
        let w = frame.width
        let h = frame.height
        for y in 0..<h {
            for x in 0..<w {
                let idx = (y * w + x) * 4
                let a = Double(frame.rgba[idx + 3]) / 255.0
                let v = (Double(frame.rgba[idx + channel]) / 255.0) * a
                if v > 0.0 {
                    sum += v
                    sx += v * (Double(x) + 0.5)
                    sy += v * (Double(y) + 0.5)
                }
            }
        }
        #expect(sum > 0.0, "channel \(channel) must have non-zero coverage")
        return (SIMD2<Float>(Float(sx / sum), Float(sy / sum)), Float(sum))
    }

    private static func percentile(_ values: [Float], _ q: Float) -> Float {
        precondition(!values.isEmpty)
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, max(0, Int((Float(sorted.count - 1) * q).rounded())))
        return sorted[idx]
    }

    @Test("one_snap.rs:506 - capture_one_snap_proof")
    func captureOneSnapProof() throws {
        let envDir = ProcessInfo.processInfo.environment["RUNE_ONE_SNAP_DUMP"]
        let dirURL: URL
        let removeAfter: Bool
        if let envDir, !envDir.isEmpty {
            dirURL = URL(fileURLWithPath: envDir, isDirectory: true)
            removeAfter = false
        } else {
            dirURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("rune-one-snap-proof-\(UUID().uuidString)", isDirectory: true)
            removeAfter = true
        }
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        defer {
            if removeAfter {
                try? FileManager.default.removeItem(at: dirURL)
            }
        }

        let renderer = try OffscreenGPURenderer()

        // 1. still_scaled & still_anchored (5x5 pixel-phase sweep)
        struct ScaledCase {
            var at: SIMD2<Float>
            var zoom: Float
            var anchored: Bool
            var onlyIconDisc: Bool
        }
        func scaledView(_ s: ScaledCase, _: inout Cx<ScaledCase>) -> El<ScaledCase> {
            let red = Color(r: 1, g: 0, b: 0, a: 1)
            let green = Color(r: 0, g: 1, b: 0, a: 1)
            let blue = Color(r: 0, g: 0, b: 1, a: 1)
            let badge: El<ScaledCase> = if s.onlyIconDisc {
                el().key("badge").size(16.0, 16.0)
                    .child(icon(Self.discIcon, size: 16.0).color(red).absolute(x: 0.0, y: 0.0))
            } else {
                el().key("badge").size(16.0, 16.0).bg(blue)
                    .child(icon(Self.ringIcon, size: 16.0).color(red).absolute(x: 0.0, y: 0.0))
                    .child(canvas(Self.discShape(r: 4.0, color: green)).size(16.0, 16.0).absolute(x: 0.0, y: 0.0))
            }
            if s.anchored {
                let page: El<ScaledCase> = col().key("page").size(120.0, 120.0)
                    .scale(s.zoom, s.zoom).origin(0.0, 0.0)
                    .child(el().key("anchor").absolute(x: 12.0 + s.at.x, y: 10.0 + s.at.y).size(24.0, 8.0))
                let pop: El<ScaledCase> = col().key("pop").p(6.0)
                    .bg(Color(r: 0, g: 0, b: 0.25, a: 1))
                    .child(badge)
                    .anchored("anchor", side: .bottom, align: .start, gap: 4.0)
                return col().size(160.0, 160.0).child(page).child(pop)
            } else {
                return col().size(160.0, 160.0).child(
                    col().key("scaled").size(100.0, 100.0)
                        .scale(s.zoom, s.zoom).origin(0.0, 0.0)
                        .child(badge.absolute(x: 14.0 + s.at.x, y: 14.0 + s.at.y))
                )
            }
        }

        var stillScaledErrs: [Float] = []
        var stillAnchoredErrs: [Float] = []
        var discIconArea: Float = 0.0
        var discShapeArea: Float = 0.0

        for anchored in [false, true] {
            for iy in 0..<5 {
                for ix in 0..<5 {
                    let at = SIMD2<Float>(Float(ix) * 0.21, Float(iy) * 0.21)
                    let rt = Runtime<ScaledCase>(
                        state: ScaledCase(at: at, zoom: 1.6, anchored: anchored, onlyIconDisc: false),
                        viewport: Vec2(160.0, 160.0),
                        pixelScale: 2.0,
                        systemDark: true,
                        view: scaledView
                    )
                    rt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
                    _ = rt.frame(at: 0.0)
                    let scene = rt.frame(at: 1.0 / 120.0)
                    let frame = try renderer.renderOffscreen(scene)
                    let (ci, _) = Self.channelMoments(frame, channel: 0)
                    let (cs, sArea) = Self.channelMoments(frame, channel: 1)
                    let dist = hypot(ci.x - cs.x, ci.y - cs.y)
                    if anchored {
                        stillAnchoredErrs.append(dist)
                    } else {
                        stillScaledErrs.append(dist)
                    }
                    if anchored && ix == 1 && iy == 2 {
                        discShapeArea = sArea
                        let rtDisc = Runtime<ScaledCase>(
                            state: ScaledCase(at: at, zoom: 1.6, anchored: true, onlyIconDisc: true),
                            viewport: Vec2(160.0, 160.0),
                            pixelScale: 2.0,
                            systemDark: true,
                            view: scaledView
                        )
                        rtDisc.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
                        _ = rtDisc.frame(at: 0.0)
                        let discScene = rtDisc.frame(at: 1.0 / 120.0)
                        let discFrame = try renderer.renderOffscreen(discScene)
                        discIconArea = Self.channelMoments(discFrame, channel: 0).1
                    }
                }
            }
        }

        // 2. moving (90 frames at 120 Hz)
        struct MovingCase {
            var at: SIMD2<Float>
            var zoom: Float
        }
        let moveRt = Runtime<MovingCase>(
            state: MovingCase(at: .zero, zoom: 1.6),
            viewport: Vec2(120.0, 120.0),
            pixelScale: 2.0,
            systemDark: true
        ) { s, _ in
            let sp = Spring(duration: 0.45, bounce: 0.0)
            let badge: El<MovingCase> = el().key("badge").size(16.0, 16.0).bg(Color(r: 0, g: 0, b: 1, a: 1))
                .offset(s.at.x, s.at.y).animate(sp)
                .child(icon(Self.ringIcon, size: 16.0).color(Color(r: 1, g: 0, b: 0, a: 1)).absolute(x: 0.0, y: 0.0))
                .child(canvas(Self.discShape(r: 4.0, color: Color(r: 0, g: 1, b: 0, a: 1))).size(16.0, 16.0).absolute(x: 0.0, y: 0.0))
            return col().size(120.0, 120.0).child(
                col().key("scaled").size(100.0, 100.0).scale(s.zoom, s.zoom).origin(0.0, 0.0)
                    .child(badge.absolute(x: 10.0, y: 10.0))
            )
        }
        moveRt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        var tMove = 0.0
        _ = moveRt.frame(at: tMove)
        tMove += 1.0 / 120.0
        _ = moveRt.frame(at: tMove)
        moveRt.update(at: tMove) { st, _ in st.at = SIMD2<Float>(17.35, 13.65) }
        var movingErrs: [Float] = []
        for _ in 0..<90 {
            tMove += 1.0 / 120.0
            let scene = moveRt.frame(at: tMove)
            let frame = try renderer.renderOffscreen(scene)
            let (ci, _) = Self.channelMoments(frame, channel: 0)
            let (cs, _) = Self.channelMoments(frame, channel: 1)
            movingErrs.append(hypot(ci.x - cs.x, ci.y - cs.y))
        }

        // 3. swap (60 frames at 120 Hz)
        struct SwapCase {
            var swapped: Bool
            var discR: Float
        }
        let swapRt = Runtime<SwapCase>(
            state: SwapCase(swapped: false, discR: 2.8),
            viewport: Vec2(160.0, 160.0),
            pixelScale: 2.0,
            systemDark: true
        ) { s, _ in
            let red = Color(r: 1, g: 0, b: 0, a: 1)
            let blue = Color(r: 0, g: 0, b: 1, a: 1)
            let page: El<SwapCase> = col().key("page").size(120.0, 120.0)
                .scale(1.6, 1.6).origin(0.0, 0.0)
                .child(el().key("anchor").absolute(x: 12.2, y: 10.35).size(24.0, 8.0))
            let indicator: El<SwapCase> = if s.swapped {
                el().key("badge").size(16.0, 16.0)
                    .child(icon(Self.ringIcon, size: 16.0).color(blue).absolute(x: 0.0, y: 0.0))
                    .child(icon(Self.discIcon, size: 16.0).color(red).absolute(x: 0.0, y: 0.0))
            } else {
                el().key("badge").size(16.0, 16.0)
                    .child(icon(Self.ringIcon, size: 16.0).color(blue).absolute(x: 0.0, y: 0.0))
                    .child(canvas(Self.discShape(r: s.discR, color: red)).size(16.0, 16.0).absolute(x: 0.0, y: 0.0))
            }
            let pop: El<SwapCase> = col().key("pop").p(6.15)
                .child(indicator)
                .anchored("anchor", side: .bottom, align: .start, gap: 4.1)
            return col().size(160.0, 160.0).child(page).child(pop)
        }
        swapRt.clearColor = Color(r: 0, g: 0, b: 0, a: 0)
        var tSwap = 0.0
        _ = swapRt.frame(at: tSwap)
        var swapCentres: [SIMD2<Float>] = []
        var swapAreas: [Float] = []
        for f in 0..<60 {
            let u = min(1.0, max(0.0, Float(f) / 30.0))
            let r: Float = 2.8 + (4.0 - 2.8) * (1.0 - pow(1.0 - u, 3.0))
            let swapped = f >= 36
            swapRt.update(at: tSwap) { st, _ in
                st.discR = r
                st.swapped = swapped
            }
            tSwap += 1.0 / 120.0
            let scene = swapRt.frame(at: tSwap)
            let frame = try renderer.renderOffscreen(scene)
            let (c, a) = Self.channelMoments(frame, channel: 0)
            swapCentres.append(c)
            swapAreas.append(a)
        }
        let swapStepErrs: [Float] = (0..<(swapCentres.count - 1)).map { i in
            hypot(swapCentres[i + 1].x - swapCentres[i].x, swapCentres[i + 1].y - swapCentres[i].y)
        }
        let swapJump = swapStepErrs[35]

        // 4. proof_view (210 frames at 80x80 @2x = 160x160 px + frame_000..frame_209.png)
        struct ProofScene {
            var at: SIMD2<Float>
            var zoom: Float
            var discR: Float
            var swapped: Bool
        }
        let proofRt = Runtime<ProofScene>(
            state: ProofScene(at: .zero, zoom: 1.0, discR: 2.6, swapped: false),
            viewport: Vec2(80.0, 80.0),
            pixelScale: 2.0,
            systemDark: true
        ) { s, _ in
            let accent = Color(r: 0.96, g: 0.28, b: 0.24, a: 1.0)
            let ringCol = Color(r: 0.92, g: 0.94, b: 0.98, a: 1.0)
            let cardBg = Color(r: 0.08, g: 0.09, b: 0.12, a: 1.0)
            let cardBorder = Color(r: 0.20, g: 0.23, b: 0.30, a: 1.0)

            let indicator: El<ProofScene> = if s.swapped {
                el().key("badge").size(16.0, 16.0)
                    .child(icon(Self.ringIcon, size: 16.0).color(ringCol).absolute(x: 0.0, y: 0.0))
                    .child(icon(Self.discIcon, size: 16.0).color(accent).absolute(x: 0.0, y: 0.0))
            } else {
                el().key("badge").size(16.0, 16.0)
                    .child(icon(Self.ringIcon, size: 16.0).color(ringCol).absolute(x: 0.0, y: 0.0))
                    .child(canvas(Self.discShape(r: s.discR, color: accent)).size(16.0, 16.0).absolute(x: 0.0, y: 0.0))
            }
            let page: El<ProofScene> = col().key("page").size(90.0, 90.0)
                .scale(s.zoom, s.zoom)
                .scaleMotion(Spring(duration: 0.42, bounce: 0.0))
                .origin(0.0, 0.0)
                .child(
                    el().key("anchor")
                        .absolute(x: 7.2, y: 4.35)
                        .offset(s.at.x, s.at.y)
                        .offsetMotion(Spring(duration: 0.55, bounce: 0.0))
                        .size(20.0, 4.0)
                )
            let pop: El<ProofScene> = row().key("pop")
                .p(7.15)
                .gap(6.0)
                .rounded(8.0)
                .bg(cardBg)
                .border(1.0, cardBorder)
                .child(indicator)
                .anchored("anchor", side: .bottom, align: .start, gap: 3.1)
            return col().size(80.0, 80.0).child(page).child(pop)
        }
        proofRt.clearColor = Color(r: 0.03, g: 0.035, b: 0.045, a: 1.0)
        var tProof = 0.0
        _ = proofRt.frame(at: tProof)
        for f in 0..<210 {
            proofRt.update(at: tProof) { s, _ in
                s.zoom = f >= 4 ? 1.6 : 1.0
                let u = min(1.0, max(0.0, Float(f - 4) / 56.0))
                s.discR = 2.6 + (4.0 - 2.6) * (1.0 - pow(1.0 - u, 3.0))
                s.swapped = (100..<150).contains(f) || f >= 185
                if f == 130 {
                    s.at = SIMD2<Float>(7.35, 6.65)
                }
            }
            tProof += 1.0 / 120.0
            let scene = proofRt.frame(at: tProof)
            let frame = try renderer.renderOffscreen(scene)
            let name = String(format: "frame_%03d.png", f)
            try frame.writePNG(to: dirURL.appendingPathComponent(name))
        }

        let report: [String: [String: Float]] = [
            "still_scaled": [
                "max_px": Self.percentile(stillScaledErrs, 1.0),
                "p95_px": Self.percentile(stillScaledErrs, 0.95),
                "median_px": Self.percentile(stillScaledErrs, 0.50),
            ],
            "still_anchored": [
                "max_px": Self.percentile(stillAnchoredErrs, 1.0),
                "p95_px": Self.percentile(stillAnchoredErrs, 0.95),
                "median_px": Self.percentile(stillAnchoredErrs, 0.50),
            ],
            "moving": [
                "max_px": Self.percentile(movingErrs, 1.0),
                "p95_px": Self.percentile(movingErrs, 0.95),
                "median_px": Self.percentile(movingErrs, 0.50),
            ],
            "swap": [
                "boundary_jump_px": swapJump,
                "max_step_px": Self.percentile(swapStepErrs, 1.0),
                "p95_step_px": Self.percentile(swapStepErrs, 0.95),
                "shape_area_px": swapAreas[35],
                "icon_area_px": swapAreas[36],
                "disc_shape_area_px": discShapeArea,
                "disc_icon_area_px": discIconArea,
            ],
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let metricsURL = dirURL.appendingPathComponent("metrics.json")
        try jsonData.write(to: metricsURL)

        // Validate captured proof artifacts and sub-pixel stability metrics.
        #expect(FileManager.default.fileExists(atPath: dirURL.appendingPathComponent("frame_000.png").path))
        #expect(FileManager.default.fileExists(atPath: dirURL.appendingPathComponent("frame_209.png").path))
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: metricsURL)) as? [String: [String: Any]]
        #expect(Set((parsed ?? [:]).keys) == Set(["still_scaled", "still_anchored", "moving", "swap"]))
        #expect((report["still_scaled"]?["max_px"] ?? .infinity) <= 0.25)
        #expect((report["still_anchored"]?["max_px"] ?? .infinity) <= 0.25)
        #expect((report["moving"]?["max_px"] ?? .infinity) <= 0.25)
        #expect(swapJump <= 0.25)
        #expect(abs(swapAreas[36] - swapAreas[35]) / swapAreas[35] < 0.02)
        #expect(abs(discIconArea - discShapeArea) / discShapeArea < 0.02)
    }
}
