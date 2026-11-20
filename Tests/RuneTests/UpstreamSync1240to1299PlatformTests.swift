import Foundation
import Testing
@testable import Rune
#if canImport(Metal)
@preconcurrency import Metal
#endif

@Suite("Upstream Sync #1240–#1299 (Shaders, Overlays, Web, Prefs, GPU, PerfWarn)", .serialized)
struct UpstreamSync1240to1299PlatformTests {

    // MARK: - 1. #1289 & #1299: Exact Fragment Pixel Centres & CsdCorners

    @Test("#1289/#1299: Metal shaders compile cleanly and evaluate shapes/backdrop at exact pixel centres")
    func metalShadersExactPixelCentresAndCompile() throws {
        // Verify RenderShaders.shaderMSL only reads interpolated `i.p` for rotated glyphs.
        let shaderLines = RenderShaders.shaderMSL.split(separator: "\n")
        let fragmentStart = try #require(shaderLines.firstIndex(where: { $0.contains("rune_fragment(") || $0.contains("fragment float4 fs(") }))
        let fragmentBody = shaderLines[fragmentStart...]
        let interpolatedPUsages = fragmentBody.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && trimmed.contains("i.p") && !trimmed.contains("i.pos") && !trimmed.contains("i.params")
        }
        #expect(interpolatedPUsages.count == 1, "Only rotated glyph sampling may read interpolated i.p")
        #expect(interpolatedPUsages.first?.contains("select(screen, i.p, rotated)") == true)

        // Verify RenderShaders.backdropCompositeMSL removed interpolated `p` and uses `i.pos.xy + i.origin`.
        #expect(!RenderShaders.backdropCompositeMSL.contains("float2 p;"))
        #expect(!RenderShaders.backdropCompositeMSL.contains("o.p ="))
        let bcompLines = RenderShaders.backdropCompositeMSL.split(separator: "\n")
        let bcompPUsages = bcompLines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && trimmed.contains("i.p") && !trimmed.contains("i.pos") && !trimmed.contains("i.params")
        }
        #expect(bcompPUsages.isEmpty, "backdropCompositeMSL must not read interpolated i.p")
        #expect(RenderShaders.backdropCompositeMSL.contains("float2 origin [[flat]];"))
        #expect(RenderShaders.backdropCompositeMSL.contains("float2 screen = i.pos.xy + i.origin;"))

        #if canImport(Metal)
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let uber = try device.makeLibrary(source: RenderShaders.shaderMSL, options: nil)
        #expect(uber.functionNames.contains("vs"))
        #expect(uber.functionNames.contains("vs_springs"))
        #expect(uber.functionNames.contains("fs"))

        let windfoil = try device.makeLibrary(source: RenderShaders.windfoilMSL(dualSource: false), options: nil)
        #expect(windfoil.functionNames.contains("fs_windfoil"))

        let windfoilDual = try device.makeLibrary(source: RenderShaders.windfoilMSL(dualSource: true), options: nil)
        #expect(windfoilDual.functionNames.contains("fs_windfoil"))

        let backdrop = try device.makeLibrary(source: RenderShaders.backdropCompositeMSL, options: nil)
        #expect(backdrop.functionNames.contains("backdrop_composite_vs"))
        #expect(backdrop.functionNames.contains("backdrop_composite_fs"))

        let csd = try device.makeLibrary(source: CsdCorners.mslSource, options: nil)
        #expect(csd.functionNames.contains("csd_corners_vs"))
        #expect(csd.functionNames.contains("csd_corners_fs"))

        // Live GPU render check with runtime-compiled MSL (rounded rect + backdrop blur).
        let renderer = try MetalRenderer(device: device)
        let clip = SIMD4<Float>(0, 0, 64, 64)
        let instances: [RenderInstance] = [
            RenderInstance(rect: SIMD4(0, 0, 64, 64), fill: SIMD4(1, 0, 0, 1), params: SIMD4(0, KIND_RECT, 0, 1), clip: clip),
            RenderInstance(rect: SIMD4(8, 8, 48, 48), radii: SIMD4(repeating: 6), fill: SIMD4(0, 0, 0, 0.8), params: SIMD4(8, KIND_BACKDROP_BLUR, 0, 1), clip: clip),
        ]
        let frame = RenderFrame(width: 64, height: 64, srgbBlend: true, clearColor: SIMD4(0, 0, 0, 1), instances: instances)
        let rendered = try renderer.renderOffscreen(frame)
        #expect(rendered.width == 64 && rendered.height == 64)
        // Top-left corner pixel (0, 0) must have exact full red coverage (255, 0, 0, 255).
        #expect(rendered.rgba[0] == 255 && rendered.rgba[1] == 0 && rendered.rgba[2] == 0 && rendered.rgba[3] == 255)
        // Centre pixel (32, 32) inside blurred backdrop over red must remain solid red (255, 0, 0, 255).
        let mid = (32 * 64 + 32) * 4
        #expect(rendered.rgba[mid] == 255 && rendered.rgba[mid + 3] == 255)
        #endif
    }

    @Test("#1289/#1299: GLSL frame.frag, common_frame.frag, and WebGPU rune-frame.wgsl use exact pixel centres")
    func glslAndWebGPUShadersUseExactPixelCentres() throws {
        let bundle = Bundle.module

        if let url = bundle.url(forResource: "frame", withExtension: "frag", subdirectory: "GL")
            ?? bundle.resourceURL?.appendingPathComponent("GL/frame.frag"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            let mainIdx = try #require(text.range(of: "void main()"))
            let body = text[mainIdx.lowerBound...]
            let vPointLines = body.split(separator: "\n").filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.hasPrefix("//") && t.contains("vPoint")
            }
            #expect(vPointLines.count == 1, "GLSL frame.frag must use vPoint only for rotated glyphs")
            #expect(vPointLines.first?.contains("rotated ? vPoint : screen") == true)
        }

        if let url = bundle.url(forResource: "common_frame", withExtension: "frag", subdirectory: "GL")
            ?? bundle.resourceURL?.appendingPathComponent("GL/common_frame.frag"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            let mainIdx = try #require(text.range(of: "void main()"))
            let body = text[mainIdx.lowerBound...]
            #expect(!body.contains("vPoint"), "GLSL common_frame.frag must evaluate rects at exact screen pixel centres")
            #expect(body.contains("screen - (vRect.xy + h)"))
        }

        if let url = bundle.url(forResource: "rune-frame", withExtension: "wgsl", subdirectory: "Web")
            ?? bundle.resourceURL?.appendingPathComponent("Web/rune-frame.wgsl"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            let fsIdx = try #require(text.range(of: "fn fs("))
            let body = text[fsIdx.lowerBound...]
            let pLines = body.split(separator: "\n").filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.hasPrefix("//") && t.contains("i.p") && !t.contains("i.pos") && !t.contains("i.params")
            }
            #expect(pLines.count == 1, "WebGPU rune-frame.wgsl must use i.p only for rotated glyphs")
            #expect(pLines.first?.contains("select(screen, i.p, rotated)") == true)
        }
    }

    @Test("#1299: CsdCorners passes flat device-pixel arc centres and measures from exact pixel centres")
    func csdCornersFlatCentreAndExactPixelDistance() {
        let corners = CsdCorners(radiusPt: 10, scale: 2, sizePx: (100, 80))
        let verts = corners.vertices()
        #expect(verts.count == 12)

        // First 6 vertices: bottom-left corner arc centre is (20, 60) in top-down device pixels.
        for v in verts[0..<6] {
            #expect(v.centreX == 20)
            #expect(v.centreY == 60)
            #expect(v.radius == 20)
        }
        // Second 6 vertices: bottom-right corner arc centre is (80, 60) in top-down device pixels.
        for v in verts[6..<12] {
            #expect(v.centreX == 80)
            #expect(v.centreY == 60)
            #expect(v.radius == 20)
        }

        // Exact pixel-centre evaluation.
        #expect(CsdCorners.outsideFraction(pixelX: 20, pixelY: 60, centreX: 20, centreY: 60, radiusPx: 20) == 0)
        #expect(CsdCorners.outsideFraction(pixelX: 0.5, pixelY: 60, centreX: 20, centreY: 60, radiusPx: 20) == 0)
        #expect(abs(CsdCorners.outsideFraction(pixelX: 0, pixelY: 60, centreX: 20, centreY: 60, radiusPx: 20) - 0.5) < 1e-4)
        #expect(CsdCorners.outsideFraction(pixelX: 0.5, pixelY: 79.5, centreX: 20, centreY: 60, radiusPx: 20) == 1)

        // Shaders use flat centre and exact fragment position.
        #expect(CsdCorners.wgslSource.contains("@location(0) @interpolate(flat) centre: vec2<f32>"))
        #expect(CsdCorners.wgslSource.contains("length(frag.at.xy - frag.centre)"))
        #expect(CsdCorners.glslFragmentSource.contains("flat in vec2 v_centre;"))
        #expect(CsdCorners.glslFragmentSource.contains("length(pixel - v_centre)"))
        #expect(CsdCorners.mslSource.contains("float2 centre [[flat]];"))
        #expect(CsdCorners.mslSource.contains("length(frag.at.xy - frag.centre)"))
    }

    // MARK: - 2. #1240 & #1249: Overlay Keyboard Focus & Clipboard Single-Step

    @Test("#1240: OverlayKeys policy agrees across macOS, layer-shell, X11, Windows, and XWayland")
    func overlayKeysPolicyParity() {
        #expect(!OverlayKeys.canTakeKeys(.none))
        #expect(OverlayKeys.canTakeKeys(.onDemand))
        #expect(OverlayKeys.canTakeKeys(.nonActivating))
        #expect(OverlayKeys.canTakeKeys(.activating))

        #expect(OverlayKeys.keysSupport(.none, focuser: true) == .unsupported)
        #expect(OverlayKeys.keysSupport(.onDemand, focuser: true) == .supported)
        #expect(OverlayKeys.keysSupport(.onDemand, focuser: false) == .unsupported)
        #expect(OverlayKeys.keysSupport(.activating, focuser: true) == .supported)

        for policy in [OverlayKeyPolicy.none, .onDemand] {
            let wants = (policy == .onDemand)
            #expect(OverlayKeys.canTakeKeys(policy) == wants)
            #expect((OverlayKeys.keysSupport(policy, focuser: true) == .supported) == wants)
            #expect(OverlayKeys.layerShellSupportsKeys(policy: policy, protocolVersion: 4, hasKeyboard: true) == wants)
            #expect(!OverlayKeys.layerShellSupportsKeys(policy: policy, protocolVersion: 3, hasKeyboard: true))
            #expect(OverlayKeys.xwaylandAllowed(input: .none, keyPolicy: policy, optIn: true) == !wants)
        }
    }

    #if os(macOS)
    @Test("#1240: macOS overlay reports nonactivatingKeys by KeyPolicy (None -> Unsupported, OnDemand -> Supported)")
    @MainActor
    func macOSOverlayCapabilitiesFollowKeyPolicy() {
        let noneHost = RuneOverlayMacOSHost<Int>(
            size: Vec2(120, 40),
            placement: OverlayGeometry.Placement(size: Vec2(120, 40)),
            options: OverlayOptions(keyPolicy: .none),
            releaseWhenHidden: false
        )
        #expect(noneHost.capabilities.nonactivatingKeys == .unsupported)

        let onDemandHost = RuneOverlayMacOSHost<Int>(
            size: Vec2(120, 40),
            placement: OverlayGeometry.Placement(size: Vec2(120, 40)),
            options: OverlayOptions(keyPolicy: .onDemand),
            releaseWhenHidden: false
        )
        #expect(onDemandHost.capabilities.nonactivatingKeys == .supported)

        onDemandHost.updatePlacement(
            OverlayGeometry.Placement(size: Vec2(120, 40)),
            options: OverlayOptions(keyPolicy: .none)
        )
        #expect(onDemandHost.capabilities.nonactivatingKeys == .unsupported)
    }
    #endif

    @Test("#1240: Windows overlay popup menu hands foreground back regardless of KeyPolicy")
    func windowsOverlayPopupMenuHandsBackForeground() {
        let owner: UInt = 1
        let other: UInt = 2
        let third: UInt = 3
        #expect(WindowsPopupFocus.handsBack(isOverlay: true, previous: other, owner: owner, foreground: owner))
        #expect(!WindowsPopupFocus.handsBack(isOverlay: false, previous: other, owner: owner, foreground: owner))
        #expect(!WindowsPopupFocus.handsBack(isOverlay: true, previous: owner, owner: owner, foreground: owner))
        #expect(!WindowsPopupFocus.handsBack(isOverlay: true, previous: 0, owner: owner, foreground: owner))
        #expect(!WindowsPopupFocus.handsBack(isOverlay: true, previous: other, owner: owner, foreground: third))
    }

    @Test("#1249: Clipboard receive marks shown/fading overlay dirty without advancing, and advances frameless overlays")
    func clipboardReceiveMarksShownDirtyAndAdvancesFrameless() {
        struct State {
            var polls: Int = 0
            var pasted: [String] = []
        }

        let rt = Runtime<State>(
            state: State(),
            viewport: Vec2(100, 40),
            pixelScale: 1,
            view: { s, _ in
                el()
                    .onPaste { state, text, _ in state.pasted.append(text) }
                    .child(text("\(s.pasted.count)").key("count"))
            }
        )
        _ = rt.frame(at: 0)

        var dirty = false
        let advance: (Runtime<State>, Double) -> Void = { runtime, now in
            runtime.state.polls += 1
            _ = runtime.frame(at: now)
        }

        // 1. No pending clipboard reply leaves a clean shown overlay untouched.
        var presence = OverlayPresence.shown(occluded: false)
        #expect(!presence.isFrameless)
        let (polls0, commits0) = (rt.state.polls, rt.commitCount)
        let noneAction = OverlayClipboardSync.receiveDue(
            runtime: rt, presence: presence, dirty: &dirty, at: 0.1,
            receive: { _ in false }, advance: advance
        )
        #expect(noneAction == .none)
        #expect(!dirty)
        #expect(rt.state.polls == polls0)
        #expect(rt.commitCount == commits0)

        // 2. Shown (non-frameless): receiving clipboard reply marks dirty and waits for next drawn frame.
        let shownAction = OverlayClipboardSync.receiveDue(
            runtime: rt, presence: presence, dirty: &dirty, at: 0.2,
            receive: { runtime in runtime.paste("shown"); return true },
            advance: advance
        )
        #expect(shownAction == .deferToNextFrame)
        #expect(dirty)
        #expect(rt.state.polls == polls0, "shown overlay must not advance poll outside draw")
        #expect(rt.commitCount == commits0, "shown overlay must not commit outside draw")
        #expect(rt.state.pasted.isEmpty, "paste handler must wait for the drawn frame")
        advance(rt, 0.2)
        #expect(rt.state.polls == polls0 + 1)
        #expect(rt.state.pasted == ["shown"])

        // 3. Fading out (still drawing, non-frameless): also leaves stepping to drawn frame.
        presence = .fadingOut(until: 10.0, length: 1.0, occluded: false)
        #expect(!presence.isFrameless)
        dirty = false
        let (polls1, commits1) = (rt.state.polls, rt.commitCount)
        let fadingAction = OverlayClipboardSync.receiveDue(
            runtime: rt, presence: presence, dirty: &dirty, at: 0.3,
            receive: { runtime in runtime.paste("fading"); return true },
            advance: advance
        )
        #expect(fadingAction == .deferToNextFrame)
        #expect(dirty)
        #expect(rt.state.polls == polls1)
        #expect(rt.commitCount == commits1)
        #expect(rt.state.pasted == ["shown"])
        advance(rt, 0.3)
        #expect(rt.state.pasted == ["shown", "fading"])

        // 4. Hidden (frameless): advances immediately so reply delivers without a frame.
        presence = .initial
        #expect(presence.isFrameless)
        dirty = false
        let polls2 = rt.state.polls
        let hiddenAction = OverlayClipboardSync.receiveDue(
            runtime: rt, presence: presence, dirty: &dirty, at: 0.4,
            receive: { runtime in runtime.paste("hidden"); return true },
            advance: advance
        )
        #expect(hiddenAction == .advanceImmediately)
        #expect(dirty)
        #expect(rt.state.polls == polls2 + 1)
        #expect(rt.state.pasted == ["shown", "fading", "hidden"])

        // 5. Shown but occluded (frameless): advances immediately since no frame draws while covered.
        presence = .shown(occluded: true)
        #expect(presence.isFrameless)
        dirty = false
        let polls3 = rt.state.polls
        let occludedAction = OverlayClipboardSync.receiveDue(
            runtime: rt, presence: presence, dirty: &dirty, at: 0.5,
            receive: { runtime in runtime.paste("occluded"); return true },
            advance: advance
        )
        #expect(occludedAction == .advanceImmediately)
        #expect(dirty)
        #expect(rt.state.polls == polls3 + 1)
        #expect(rt.state.pasted == ["shown", "fading", "hidden", "occluded"])
    }

    // MARK: - 3. #1253: Web Host Step & RTL page_scroll_x Normalization

    @Test("#1253: WebMath gate, acquire, miss, and post-step reblend policies")
    func webMathGateAcquireMissAndReblendPolicies() {
        // Gate
        #expect(WebMath.webFrameGate(suspended: true, draw: .gpu) == .skip)
        #expect(WebMath.webFrameGate(suspended: true, draw: .cpu) == .skip)
        #expect(WebMath.webFrameGate(suspended: false, draw: .contextLost) == .skip)
        #expect(WebMath.webFrameGate(suspended: false, draw: .moving) == .skip)
        #expect(WebMath.webFrameGate(suspended: false, draw: .handingOver(waitingForGpu: true)) == .skip)
        #expect(WebMath.webFrameGate(suspended: false, draw: .handingOver(waitingForGpu: false)) == .draw)
        #expect(WebMath.webFrameGate(suspended: false, draw: .cpu) == .draw)
        #expect(WebMath.webFrameGate(suspended: false, draw: .gpu) == .draw)

        // Acquire & miss
        #expect(WebMath.webAcquireAction(status: .ready, retriesLeft: 1) == .useTexture)
        #expect(WebMath.webAcquireAction(status: .timeout, retriesLeft: 1) == .miss(.timeout))
        #expect(WebMath.webAcquireAction(status: .occluded, retriesLeft: 1) == .miss(.occluded))
        #expect(WebMath.webAcquireAction(status: .outdatedOrLost, retriesLeft: 1) == .reconfigureAndRetry)
        #expect(WebMath.webAcquireAction(status: .outdatedOrLost, retriesLeft: 0) == .miss(.unconfigured))
        #expect(WebMath.webAcquireAction(status: .validation, retriesLeft: 1) == .miss(.unconfigured))

        #expect(WebMath.webMissAction(.unconfigured) == .fatal)
        #expect(WebMath.webMissAction(.occluded) == .coveredOnly)
        #expect(WebMath.webMissAction(.timeout) == .retryNextFrame)
        #expect(WebMath.webMissAction(.outdated) == .retryNextFrame)

        // Post-step reblend
        #expect(WebMath.shouldPostStepReblend(rendererSRGB: true, rtSRGB: false, reblendTried: nil))
        #expect(!WebMath.shouldPostStepReblend(rendererSRGB: true, rtSRGB: false, reblendTried: false))
        #expect(!WebMath.shouldPostStepReblend(rendererSRGB: true, rtSRGB: true, reblendTried: nil))
    }

    @Test("#1253: RTL page_scroll_x normalizes all browser models and round-trips cleanly")
    func rtlScrollXNormalizesAllModelsAndRoundTrips() {
        let maxScroll: Float = 400.0

        // LTR: identity clamped to [0, max].
        for model in WebMath.RtlScrollModel.allCases {
            #expect(WebMath.scrollXFromDOM(scrollLeft: 0, maxScroll: maxScroll, rtl: false, model: model) == 0)
            #expect(WebMath.scrollXFromDOM(scrollLeft: 120, maxScroll: maxScroll, rtl: false, model: model) == 120)
            #expect(WebMath.scrollXFromDOM(scrollLeft: 400, maxScroll: maxScroll, rtl: false, model: model) == 400)
            #expect(WebMath.scrollXFromDOM(scrollLeft: -25, maxScroll: maxScroll, rtl: false, model: model) == 0)
            #expect(WebMath.scrollXFromDOM(scrollLeft: 430, maxScroll: maxScroll, rtl: false, model: model) == 400)
            #expect(WebMath.scrollXToDOM(offset: 120, maxScroll: maxScroll, rtl: false, model: model) == 120)
        }

        // RTL Negative (CSSOM View standard): 0 at start, -max at end.
        #expect(WebMath.scrollXFromDOM(scrollLeft: 0, maxScroll: maxScroll, rtl: true, model: .negative) == 0)
        #expect(WebMath.scrollXFromDOM(scrollLeft: -80, maxScroll: maxScroll, rtl: true, model: .negative) == 80)
        #expect(WebMath.scrollXFromDOM(scrollLeft: -400, maxScroll: maxScroll, rtl: true, model: .negative) == 400)
        #expect(WebMath.scrollXFromDOM(scrollLeft: 20, maxScroll: maxScroll, rtl: true, model: .negative) == 0)
        #expect(WebMath.scrollXFromDOM(scrollLeft: -425, maxScroll: maxScroll, rtl: true, model: .negative) == 400)
        let domZero = WebMath.scrollXToDOM(offset: 0, maxScroll: maxScroll, rtl: true, model: .negative)
        #expect(domZero == 0)
        #expect(domZero.sign == .plus, "start offset writes +0.0, not -0.0")
        #expect(WebMath.scrollXToDOM(offset: 80, maxScroll: maxScroll, rtl: true, model: .negative) == -80)
        #expect(WebMath.scrollXToDOM(offset: 400, maxScroll: maxScroll, rtl: true, model: .negative) == -400)

        // RTL Reverse (legacy Edge/IE): 0 at start, +max at end.
        #expect(WebMath.scrollXFromDOM(scrollLeft: 0, maxScroll: maxScroll, rtl: true, model: .reverse) == 0)
        #expect(WebMath.scrollXFromDOM(scrollLeft: 80, maxScroll: maxScroll, rtl: true, model: .reverse) == 80)
        #expect(WebMath.scrollXFromDOM(scrollLeft: 400, maxScroll: maxScroll, rtl: true, model: .reverse) == 400)
        #expect(WebMath.scrollXFromDOM(scrollLeft: -15, maxScroll: maxScroll, rtl: true, model: .reverse) == 0)
        #expect(WebMath.scrollXFromDOM(scrollLeft: 420, maxScroll: maxScroll, rtl: true, model: .reverse) == 400)
        #expect(WebMath.scrollXToDOM(offset: 0, maxScroll: maxScroll, rtl: true, model: .reverse) == 0)
        #expect(WebMath.scrollXToDOM(offset: 80, maxScroll: maxScroll, rtl: true, model: .reverse) == 80)
        #expect(WebMath.scrollXToDOM(offset: 400, maxScroll: maxScroll, rtl: true, model: .reverse) == 400)

        // RTL Default (legacy Blink/WebKit): +max at start, 0 at end.
        #expect(WebMath.scrollXFromDOM(scrollLeft: 400, maxScroll: maxScroll, rtl: true, model: .default) == 0)
        #expect(WebMath.scrollXFromDOM(scrollLeft: 320, maxScroll: maxScroll, rtl: true, model: .default) == 80)
        #expect(WebMath.scrollXFromDOM(scrollLeft: 0, maxScroll: maxScroll, rtl: true, model: .default) == 400)
        #expect(WebMath.scrollXFromDOM(scrollLeft: 430, maxScroll: maxScroll, rtl: true, model: .default) == 0)
        #expect(WebMath.scrollXFromDOM(scrollLeft: -20, maxScroll: maxScroll, rtl: true, model: .default) == 400)
        #expect(WebMath.scrollXToDOM(offset: 0, maxScroll: maxScroll, rtl: true, model: .default) == 400)
        #expect(WebMath.scrollXToDOM(offset: 80, maxScroll: maxScroll, rtl: true, model: .default) == 320)
        #expect(WebMath.scrollXToDOM(offset: 400, maxScroll: maxScroll, rtl: true, model: .default) == 0)

        // Round-trip & non-finite safety across all combinations.
        for rtl in [false, true] {
            for model in WebMath.RtlScrollModel.allCases {
                for offset: Float in [0, 0.5, 80, 199.75, 400] {
                    let dom = WebMath.scrollXToDOM(offset: offset, maxScroll: maxScroll, rtl: rtl, model: model)
                    let back = WebMath.scrollXFromDOM(scrollLeft: dom, maxScroll: maxScroll, rtl: rtl, model: model)
                    #expect(abs(back - offset) < 1e-4)
                }
                #expect(WebMath.scrollXFromDOM(scrollLeft: .nan, maxScroll: maxScroll, rtl: rtl, model: model) == 0)
                #expect(WebMath.scrollXFromDOM(scrollLeft: .infinity, maxScroll: maxScroll, rtl: rtl, model: model) == 0)
                #expect(WebMath.scrollXToDOM(offset: .nan, maxScroll: maxScroll, rtl: rtl, model: model) == 0)
                #expect(WebMath.scrollXToDOM(offset: 100, maxScroll: 0, rtl: rtl, model: model) == 0)
                #expect(WebMath.scrollXFromDOM(scrollLeft: -100, maxScroll: 0, rtl: rtl, model: model) == 0)
            }
        }
    }

    @Test("#1253: WebHostStep drives acquire-before-step, recovery, post-step reblend, handover, and abort")
    func webHostStepSequencerParity() {
        enum MockDrawable { case cpu, gpu(UInt32) }
        enum MockPrepared { case cpu, handover(gpu: UInt32?), gpu(UInt32) }

        struct MockWebHost: WebHostStep.Host {
            var suspended = false
            var draw: WebMath.WebDrawKind
            var handoverBuilt = false
            var fullRedraw = true
            var forceCycleTick = false
            var rendererSRGB = true
            var rtSRGB = true
            var switchBlendDuringStep: Bool? = nil
            var reblendSupportsLinear = true
            var acquires: [WebMath.WebAcquireStatus] = []
            var nextTex: UInt32 = 1
            var reblendTried: Bool? = nil
            var simulateNativeSurface = false
            var fatalError: String? = nil
            var redrawRequested = 0
            var reconfigures = 0
            var handoverGpuAcquired = 0
            var coveredWakes = 0
            var presentedCount = 0
            var log: [String] = []

            mutating func acquireGpuTex() -> Result<UInt32, WebMath.WebMissed> {
                var retries: UInt8 = 1
                while true {
                    let status = acquires.isEmpty ? .ready : acquires.removeFirst()
                    switch WebMath.webAcquireAction(status: status, retriesLeft: retries) {
                    case .useTexture:
                        let id = nextTex
                        nextTex += 1
                        return .success(id)
                    case .reconfigureAndRetry:
                        reconfigures += 1
                        log.append("reconfigure")
                        retries -= 1
                    case let .miss(missed):
                        return .failure(missed)
                    }
                }
            }

            mutating func gate() -> WebMath.WebFrameGate {
                reblendTried = nil
                fatalError = nil
                let g = WebMath.webFrameGate(suspended: suspended, draw: draw)
                log.append(g == .skip ? "gate:skip" : "gate:draw")
                return g
            }

            func needsReblend() -> Bool {
                draw == .gpu && rendererSRGB != rtSRGB
            }

            mutating func reblend() -> Bool {
                reblendTried = rtSRGB
                log.append("reblend")
                rendererSRGB = (rtSRGB || reblendSupportsLinear) ? rtSRGB : true
                return true
            }

            mutating func acquire() -> WebHostStep.Acquire<MockDrawable> {
                switch draw {
                case .gpu:
                    switch acquireGpuTex() {
                    case let .success(id):
                        log.append("acquire:gpu")
                        return .ready(.gpu(id))
                    case let .failure(m):
                        log.append("acquire:missed")
                        return .missed(m)
                    }
                case .cpu, .handingOver:
                    log.append("acquire:cpu")
                    return .ready(.cpu)
                case .contextLost, .moving:
                    return .missed(.unconfigured)
                }
            }

            mutating func stepRuntime() -> WebHostStep.StepInfo {
                log.append("step")
                let full = fullRedraw
                fullRedraw = false
                if !full && draw == .gpu && forceCycleTick {
                    log.append("step:cycle_tick")
                }
                if let next = switchBlendDuringStep {
                    switchBlendDuringStep = nil
                    rtSRGB = next
                }
                return WebHostStep.StepInfo(runtimeAnimating: false, animating: false, dt: 1.0 / 60.0)
            }

            mutating func postStepCheck(_ info: inout WebHostStep.StepInfo) -> WebHostStep.PostStepCheck {
                if draw == .gpu && WebMath.shouldPostStepReblend(rendererSRGB: rendererSRGB, rtSRGB: rtSRGB, reblendTried: reblendTried) {
                    log.append("post:reblend")
                    return .reacquire(.reblend)
                }
                return .keep
            }

            mutating func prepareReacquire(_ reason: WebHostStep.ReacquireReason, _ info: inout WebHostStep.StepInfo) -> Bool {
                reason == .reblend ? reblend() : true
            }

            mutating func onMissed(_ missed: WebMath.WebMissed, stepped: Bool) {
                switch WebMath.webMissAction(missed) {
                case .fatal:
                    log.append("missed:fatal")
                    fatalError = "WebGPU canvas acquisition failed"
                case .coveredOnly:
                    log.append("missed:occluded")
                    if !stepped { coveredWakes += 1 }
                case .retryNextFrame:
                    log.append("missed:retry")
                    if !stepped { coveredWakes += 1 }
                    redrawRequested += 1
                }
            }

            mutating func syncAfterStep(_ info: inout WebHostStep.StepInfo) {
                log.append("sync")
                if simulateNativeSurface {
                    fatalError = "native video surfaces are unsupported on web"
                }
            }

            mutating func prepareRender(_ drawable: MockDrawable, _ info: inout WebHostStep.StepInfo) -> WebHostStep.RenderPrep<MockPrepared> {
                if fatalError != nil {
                    log.append("prepare:abort")
                    return .abort
                }
                switch (draw, drawable) {
                case (.cpu, .cpu):
                    log.append("prepare:cpu")
                    return .ready(.cpu)
                case (.handingOver, .cpu):
                    let gpu: UInt32?
                    if handoverBuilt {
                        handoverGpuAcquired += 1
                        gpu = try? acquireGpuTex().get()
                    } else {
                        gpu = nil
                    }
                    log.append(gpu != nil ? "prepare:handover_gpu" : "prepare:handover_cpu")
                    return .ready(.handover(gpu: gpu))
                case (.gpu, .gpu(let id)):
                    log.append("prepare:gpu")
                    return .ready(.gpu(id))
                default:
                    return .abort
                }
            }

            mutating func render(_ prepared: inout MockPrepared, _ info: WebHostStep.StepInfo) -> Bool {
                log.append("render")
                return false
            }

            mutating func submitAndPresent(_ prepared: MockPrepared, _ info: WebHostStep.StepInfo) -> Double {
                log.append("present")
                return 0.016
            }

            mutating func recordPresentation(submitted: Double, info: WebHostStep.StepInfo) {
                presentedCount += 1
            }

            mutating func settle(submitted: Double, info: WebHostStep.StepInfo) {
                log.append("settle")
            }
        }

        // 1. Normal GPU frame acquires before step and records presentation.
        var gpu = MockWebHost(draw: .gpu)
        #expect(WebHostStep.run(&gpu) == .presented)
        #expect(gpu.log == ["gate:draw", "acquire:gpu", "step", "sync", "prepare:gpu", "render", "present", "settle"])
        #expect(gpu.presentedCount == 1)

        // 2. Transient timeout -> covered wake + redraw, not fatal; occluded -> covered wake only;
        //    single outdated -> reconfigure + retry -> present; double lost -> fatal.
        var recovery = MockWebHost(draw: .gpu)
        recovery.acquires = [.timeout]
        #expect(WebHostStep.run(&recovery) == .missed)
        #expect(recovery.coveredWakes == 1 && recovery.redrawRequested == 1 && recovery.fatalError == nil)
        #expect(recovery.fullRedraw, "missed acquire before step preserves fullRedraw")

        recovery.acquires = [.occluded]
        #expect(WebHostStep.run(&recovery) == .missed)
        #expect(recovery.coveredWakes == 2 && recovery.redrawRequested == 1 && recovery.fatalError == nil)

        recovery.acquires = [.outdatedOrLost, .ready]
        #expect(WebHostStep.run(&recovery) == .presented)
        #expect(recovery.reconfigures == 1 && recovery.fatalError == nil)

        recovery.acquires = [.outdatedOrLost, .outdatedOrLost]
        #expect(WebHostStep.run(&recovery) == .missed)
        #expect(recovery.reconfigures == 2 && recovery.fatalError == "WebGPU canvas acquisition failed")

        // 3. Post-step reblend reacquires once; WebGL2 without sRGB twin does NOT loop.
        var reblendHost = MockWebHost(draw: .gpu)
        reblendHost.switchBlendDuringStep = false
        #expect(WebHostStep.run(&reblendHost) == .presented)
        #expect(reblendHost.log == [
            "gate:draw", "acquire:gpu", "step", "post:reblend", "reblend", "acquire:gpu",
            "sync", "prepare:gpu", "render", "present", "settle",
        ])

        reblendHost.log.removeAll()
        reblendHost.rendererSRGB = true
        reblendHost.reblendSupportsLinear = false
        #expect(WebHostStep.run(&reblendHost) == .presented)
        #expect(reblendHost.log == [
            "gate:draw", "reblend", "acquire:gpu", "step", "sync", "prepare:gpu", "render", "present", "settle",
        ])

        // 4. Handover, skipped gate states, and native surface abort.
        var handover = MockWebHost(draw: .handingOver(waitingForGpu: false))
        #expect(WebHostStep.run(&handover) == .presented)
        #expect(handover.handoverGpuAcquired == 0 && handover.log.contains("prepare:handover_cpu"))

        handover.log.removeAll()
        handover.handoverBuilt = true
        #expect(WebHostStep.run(&handover) == .presented)
        #expect(handover.handoverGpuAcquired == 1)

        handover.log.removeAll()
        handover.draw = .handingOver(waitingForGpu: true)
        #expect(WebHostStep.run(&handover) == .skipped)
        #expect(handover.log == ["gate:skip"])

        handover.log.removeAll()
        handover.draw = .contextLost
        #expect(WebHostStep.run(&handover) == .skipped)

        var cpu = MockWebHost(draw: .cpu)
        cpu.simulateNativeSurface = true
        #expect(WebHostStep.run(&cpu) == .aborted)
        #expect(cpu.log == ["gate:draw", "acquire:cpu", "step", "sync", "prepare:abort"])
    }

    @Test("#1253: WebAccessibilityDocument and WebBrowserSession propagate RTL direction for horizontal scrollers")
    @MainActor
    func webDocumentAndSessionTrackRtlScrollX() throws {
        let spec = AppSpec<Void>(title: "RTL Scroll", size: Vec2(300, 120), state: ()) { _, _ in
            row().key("rtl-strip").dir(.rtl).size(200, 40).scrollX()
                .child(text("مرحبا بالعالم").size(600, 40).shrink(0))
        }
        let host = WebAppHost(spec: spec, config: WebAppConfig(webDocument: true))
        let session = WebBrowserSession(host)
        session.enableAccessibilityPatches()
        _ = try session.renderFrame(at: 0)

        let doc = try #require(WebAccessibilityDocument(host.runtime))
        var tree = host.runtime.accessibilitySnapshot()
        doc.project(&tree)
        func find(_ id: String, in node: AccessibilityNode) -> AccessibilityNode? {
            if node.id == id { return node }
            for c in node.children { if let hit = find(id, in: c) { return hit } }
            return nil
        }
        let strip = try #require(find("rtl-strip", in: tree))
        #expect(strip.webDocument?.rtl == true)

        let path = try #require(strip.runtimePath)
        let firstData = try #require(session.takeScrollX())
        let firstList = try #require(JSONSerialization.jsonObject(with: firstData) as? [[String: Any]])
        #expect(firstList.count == 1)
        #expect(firstList[0]["path"] as? String == path)
        #expect(firstList[0]["rtl"] as? Bool == true)
        #expect((firstList[0]["x"] as? NSNumber)?.floatValue == 0)

        // Browser-originated logical scroll does not echo back on takeScrollX().
        let event = try JSONSerialization.data(withJSONObject: ["kind": "pageScrollX", "key": path, "x": 85])
        #expect(session.send(event, at: 0.1))
        #expect(host.runtime.scrollOffset(forKey: "rtl-strip").x == 85)
        #expect(session.takeScrollX() == nil)

        // Programmatic scroll DOES emit an update with rtl = true.
        #expect(host.runtime.setPageScrollX(path, x: 140))
        let nextData = try #require(session.takeScrollX())
        let nextList = try #require(JSONSerialization.jsonObject(with: nextData) as? [[String: Any]])
        #expect(nextList.count == 1)
        #expect((nextList[0]["x"] as? NSNumber)?.floatValue == 140)
        #expect(nextList[0]["rtl"] as? Bool == true)
    }

    // MARK: - 4. #1284: Prefs Windows Atomic Replace Retry

    @Test("#1284: Prefs retries Windows atomic replace up to 6 times (<=31 ms) on transient sharing conflicts only")
    func prefsWindowsAtomicReplaceRetryPolicy() throws {
        #expect(Prefs.windowsReplaceDelaysMs == [0, 1, 2, 4, 8, 16])
        #expect(Prefs.windowsReplaceDelaysMs.reduce(0, +) == 31)

        // Succeeds after transient ERROR_ACCESS_DENIED (5) and ERROR_SHARING_VIOLATION (32).
        var sleeps: [UInt32] = []
        var responses: [UInt32] = [5, 32, 13, 0]
        let okCode = Prefs.renameReplaceWithRetry(sleep: { sleeps.append($0) }) {
            responses.removeFirst()
        }
        #expect(okCode == 0)
        #expect(sleeps == [0, 1, 2])

        // Non-transient error (e.g. ERROR_FILE_NOT_FOUND = 2) fails immediately with 0 retries.
        var nonTransientSleeps: [UInt32] = []
        var attempts = 0
        let permCode = Prefs.renameReplaceWithRetry(sleep: { nonTransientSleeps.append($0) }) {
            attempts += 1
            return 2
        }
        #expect(permCode == 2)
        #expect(attempts == 1)
        #expect(nonTransientSleeps.isEmpty)

        // Persistent ERROR_SHARING_VIOLATION exhausts 6 retries (7 attempts) and returns error.
        var exhaustedSleeps: [UInt32] = []
        var exhaustedAttempts = 0
        let failCode = Prefs.renameReplaceWithRetry(sleep: { exhaustedSleeps.append($0) }) {
            exhaustedAttempts += 1
            return 32
        }
        #expect(failCode == 32)
        #expect(exhaustedAttempts == 7)
        #expect(exhaustedSleeps == [0, 1, 2, 4, 8, 16])

        // Live disk round-trip leaves no temp files behind.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rune-prefs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("prefs.json")
        let prefs = Prefs.at(file)
        try prefs.set("theme", value: "dark")
        try prefs.set("theme", value: "light")
        #expect(Prefs.at(file).get("theme", as: String.self) == "light")
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(entries == ["prefs.json"])
    }

    // MARK: - 5. #1286: GPU Adapter Picking & Logging

    @Test("#1286: Offscreen/test picks primary display GPU, WGPU_ADAPTER_NAME is final, and RUNE_GPU_LOG=1 logs every pick")
    func gpuAdapterPickingAndLoggingParity() {
        #expect(GpuPickReason.windowGpu.descriptionText == "the GPU a window would get (it drives the primary display)")

        let igpu = GpuAdapterCandidate(
            name: "Intel UHD Graphics",
            backend: "Dx12",
            deviceType: "IntegratedGpu",
            isLowPower: true,
            isPrimaryDisplay: false
        )
        let dgpu = GpuAdapterCandidate(
            name: "NVIDIA GeForce RTX 4090",
            backend: "Dx12",
            deviceType: "DiscreteGpu",
            isLowPower: false,
            isPrimaryDisplay: true
        )
        let warp = GpuAdapterCandidate(
            name: "Microsoft Basic Render Driver",
            backend: "Dx12",
            deviceType: "Cpu",
            isLowPower: true,
            isPrimaryDisplay: false,
            isSoftware: true
        )
        let candidates = [igpu, dgpu, warp]

        // 1. Offscreen / test work takes the primary display GPU (reason: .windowGpu).
        let offscreen = GpuAdapterPicker.pick(candidates: candidates, presented: false, env: [:])
        #expect(offscreen == .success(GpuPickOutcome(index: 1, reason: .windowGpu, hardwareCount: 2)))

        // 2. Presented work takes the primary display GPU (reason: .display).
        let presented = GpuAdapterPicker.pick(candidates: candidates, presented: true, env: [:])
        #expect(presented == .success(GpuPickOutcome(index: 1, reason: .display, hardwareCount: 2)))

        // 3. When no display GPU exists, falls back to lowest power hardware GPU.
        var headlessIg = igpu; headlessIg.isPrimaryDisplay = false
        var headlessDg = dgpu; headlessDg.isPrimaryDisplay = false
        let headless = GpuAdapterPicker.pick(candidates: [headlessDg, headlessIg, warp], presented: false, env: [:])
        #expect(headless == .success(GpuPickOutcome(index: 1, reason: .lowPower, hardwareCount: 2)))

        // 4. WGPU_ADAPTER_NAME finds software adapters (WARP) and is final on miss.
        let warpPick = GpuAdapterPicker.pick(candidates: candidates, presented: true, env: ["WGPU_ADAPTER_NAME": "basic render"])
        #expect(warpPick == .success(GpuPickOutcome(index: 2, reason: .envName, hardwareCount: 3)))

        let missingPick = GpuAdapterPicker.pick(candidates: candidates, presented: true, env: ["WGPU_ADAPTER_NAME": "nonexistent-gpu"])
        if case let .failure(err) = missingPick {
            #expect(err.description.contains("WGPU_ADAPTER_NAME"))
            #expect(GpuAdapterPicker.formatFailure(err.description).hasPrefix("rune: no GPU: "))
        } else {
            Issue.record("WGPU_ADAPTER_NAME must fail instead of falling through to another GPU")
        }

        // 5. Logging: RUNE_GPU_LOG=1 prints EVERY pick; without it, multi-GPU prints first pick once.
        let logger = GpuPickLogger()
        var logged: [String] = []
        for _ in 0..<3 {
            logger.logPick(
                name: dgpu.name, backendLabel: "wgpu", backend: "Dx12", deviceType: "DiscreteGpu",
                reason: .windowGpu, adapterCount: 2, env: ["RUNE_GPU_LOG": "1"]
            ) { logged.append($0) }
        }
        #expect(logged.count == 3, "RUNE_GPU_LOG=1 must log every adapter pick")
        #expect(logged.allSatisfy { $0.contains("the GPU a window would get (it drives the primary display)") })

        let multiLogger = GpuPickLogger()
        var multiLogged: [String] = []
        for _ in 0..<3 {
            multiLogger.logPick(
                name: dgpu.name, backendLabel: "wgpu", backend: "Dx12", deviceType: "DiscreteGpu",
                reason: .display, adapterCount: 2, env: [:]
            ) { multiLogged.append($0) }
        }
        #expect(multiLogged.count == 1, "Without RUNE_GPU_LOG, multi-GPU logs only the first pick once")

        let singleLogger = GpuPickLogger()
        var singleLogged: [String] = []
        singleLogger.logPick(
            name: igpu.name, backendLabel: "Metal", backend: "Metal", deviceType: "IntegratedGpu",
            reason: .windowGpu, adapterCount: 1, env: [:]
        ) { singleLogged.append($0) }
        #expect(singleLogged.isEmpty)

        #if canImport(Metal)
        // Live MetalAdapterPicker: bogus WGPU_ADAPTER_NAME fails and logs failure; RUNE_GPU_LOG=1 logs every pick.
        let liveLogger = GpuPickLogger()
        var liveLines: [String] = []
        let failLive = MetalAdapterPicker.pick(env: ["WGPU_ADAPTER_NAME": "__NO_SUCH_METAL_GPU__"], logger: liveLogger) {
            liveLines.append($0)
        }
        if case .failure = failLive {
            #expect(liveLines.count == 1 && liveLines[0].hasPrefix("rune: no GPU:"))
        } else {
            Issue.record("MetalAdapterPicker.pick must fail when WGPU_ADAPTER_NAME matches no GPU")
        }

        liveLines.removeAll()
        let ok1 = MetalAdapterPicker.pick(displayID: nil, env: ["RUNE_GPU_LOG": "1"], logger: liveLogger) { liveLines.append($0) }
        let ok2 = MetalAdapterPicker.pick(displayID: nil, env: ["RUNE_GPU_LOG": "1"], logger: liveLogger) { liveLines.append($0) }
        if case .success = ok1, case .success = ok2 {
            #expect(liveLines.count == 2, "RUNE_GPU_LOG=1 must log every MetalAdapterPicker.pick call")
        }
        #endif
    }

    // MARK: - 6. #1283: PerfWarn.warm()

    @Test("#1283: PerfWarn.warm() initializes RUNE_PERF_WARN cache safely up front")
    func perfWarnWarmInitializesCache() {
        PerfWarn.warm()
        PerfWarn.warm()
        // Calling warm() must leave PerfWarn operational.
        PerfWarn.resetForTesting()
        defer { PerfWarn.resetForTesting() }
        PerfWarn.testEnabledOverride = true
        PerfWarn.warnOnce(site: "warm-test-site") { "warmed" }
        let lines = PerfWarn.takeTestLog(resetSites: true)
        #expect(lines.count == 1 && lines[0].contains("warmed"))
    }
}
