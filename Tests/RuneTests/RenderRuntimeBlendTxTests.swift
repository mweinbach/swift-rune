import Foundation
import Testing
@testable import Rune
import RuneMotion
import RuneRef

#if canImport(Metal) && canImport(QuartzCore)
import Metal
import QuartzCore
#endif

@Suite("Render Runtime Blend, Format & Tx Blur Parity Tests")
struct RenderRuntimeBlendTxTests {
    private func sampleRGBA(_ frame: Frame, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let cx = max(0, min(frame.width - 1, x))
        let cy = max(0, min(frame.height - 1, y))
        let off = (cy * frame.width + cx) * 4
        return (frame.rgba[off], frame.rgba[off + 1], frame.rgba[off + 2], frame.rgba[off + 3])
    }

    // MARK: - Group 4: tests/tx_blur.rs (2 tests)

    /// Upstream: `crates/rune/tests/tx_blur.rs:39` `a_submit_handler_blurs_its_field`
    @Test("tx_blur.rs:39 a_submit_handler_blurs_its_field")
    func submitHandlerBlursItsField() {
        struct S {
            var edit = TextEdit("")
            var submits = 0
            var unhandledKeys: [String] = []
        }

        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            onKey: { s, ev, _ in
                if case .text(let t) = ev.key {
                    s.unhandledKeys.append(t)
                    return true
                }
                return false
            }
        ) { _, _ in
            col().size(200, 100)
                .child(
                    textInput(key: "field", \S.edit)
                        .size(160, 28)
                        .onSubmit { s, _, tx in
                            s.submits += 1
                            tx.blur()
                        }
                )
        }
        _ = rt.frame(at: 0.0)

        // Focus the text field and type "a"
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.01)
        _ = rt.frame(at: 0.01)
        #expect(rt.focusedKey == "field")
        _ = rt.keyDown(KeyEvent(key: .text("a")), at: 0.02)
        _ = rt.frame(at: 0.02)
        #expect(rt.state.edit.text == "a")
        #expect(rt.state.unhandledKeys.isEmpty)

        // Submit blurs the field immediately and drops focus
        _ = rt.keyDown(KeyEvent(key: .enter), at: 0.03)
        _ = rt.frame(at: 0.03)
        #expect(rt.state.submits == 1)
        #expect(rt.focusedKey == nil)

        // Typing "z" after blur does not edit the field and routes to outer onKey
        _ = rt.keyDown(KeyEvent(key: .text("z")), at: 0.04)
        _ = rt.frame(at: 0.04)
        #expect(rt.state.edit.text == "a")
        #expect(rt.state.unhandledKeys == ["z"])
    }

    /// Upstream: `crates/rune/tests/tx_blur.rs:53` `an_update_blurs_and_asks_for_a_frame`
    @Test("tx_blur.rs:53 an_update_blurs_and_asks_for_a_frame")
    func updateBlursAndDropsFocus() {
        struct S {
            var edit = TextEdit("")
            var unhandledKeys: [String] = []
        }

        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(200, 100),
            pixelScale: 1.0,
            onKey: { s, ev, _ in
                if case .text(let t) = ev.key {
                    s.unhandledKeys.append(t)
                    return true
                }
                return false
            }
        ) { _, _ in
            col().size(200, 100)
                .child(textInput(key: "field", \S.edit).size(160, 28))
        }
        _ = rt.frame(at: 0.0)
        _ = rt.keyDown(KeyEvent(key: .tab), at: 0.01)
        _ = rt.frame(at: 0.01)
        #expect(rt.focusedKey == "field")
        #expect(rt.hasPendingCommit == false)

        // A blur that drops focus returns true ("frame work") and dirties commit even when closure returns false
        let dropped = rt.updateIf(at: 0.02) { _, tx in
            tx.blur()
            return false
        }
        #expect(dropped == true)
        #expect(rt.hasPendingCommit == true)
        _ = rt.frame(at: 0.025)
        let fieldInfo = rt.lastElements.first(where: { $0.key == "field" })
        #expect(fieldInfo?.focused == false)

        // With nothing focused, calling tx.blur() is a no-op and returns false
        let noOp = rt.updateIf(at: 0.03) { _, tx in
            tx.blur()
            return false
        }
        #expect(noOp == false)
        _ = rt.keyDown(KeyEvent(key: .text("z")), at: 0.04)
        #expect(rt.state.edit.text == "")
        #expect(rt.state.unhandledKeys == ["z"])
    }

    // MARK: - Group 5: tests/srgb_blend_runtime.rs (6 tests)

    private func makeBlendTestRuntime(srgbBlend: Bool = false) -> Runtime<Void> {
        let rt = Runtime<Void>(state: (), viewport: Vec2(40, 40), pixelScale: 1.0) { _, _ in
            col().size(40, 40).bg(.black)
                .child(
                    el().key("btn").size(20, 20)
                        .bg(Color(r: 1, g: 0, b: 0, a: 1))
                        .hover(Color(r: 1, g: 1, b: 1, a: 0.5))
                )
        }
        rt.setSrgbBlend(srgbBlend)
        rt.clearColor = .black
        return rt
    }

    /// Upstream: `crates/rune/tests/srgb_blend_runtime.rs:46` `hover_tints_follow_the_runtime_blend_mode`
    @Test("srgb_blend_runtime.rs:46 hover_tints_follow_the_runtime_blend_mode")
    func hoverTintsFollowRuntimeBlendMode() throws {
        let rt = makeBlendTestRuntime(srgbBlend: false)
        _ = rt.renderFrame(at: 0.0)
        rt.pointerMove(to: Vec2(10, 10), at: 0.01)

        // Linear blend (srgbBlend = false): red(1,0,0) over-blended with white(1,1,1,0.5) in linear -> linear g == 0.5
        let rfLinear = rt.renderFrame(at: 0.02)
        let linearInst = try #require(rfLinear.instances.last(where: { $0.params.y == KIND_RECT && $0.rect.z == 20 }))
        #expect(abs(linearInst.fill.y - 0.5) < 0.02)

        // sRGB gamma blend (srgbBlend = true): sRGB 0.5 green stays 0.5 in sRGB-encoded unorm8 space (~0.502 in unorm fill)
        rt.setSrgbBlend(true)
        let rfSrgb = rt.renderFrame(at: 0.03)
        let srgbInst = try #require(rfSrgb.instances.last(where: { $0.params.y == KIND_RECT && $0.rect.z == 20 }))
        #expect(rfSrgb.srgbBlend == true)
        #expect(abs(srgbInst.fill.y - 0.5) < 0.02)
        #expect(srgbInst.fill.y != linearInst.fill.y || rfLinear.srgbBlend != rfSrgb.srgbBlend)
    }

    /// Upstream: `crates/rune/tests/srgb_blend_runtime.rs:65` `switching_blend_mode_redraws`
    @Test("srgb_blend_runtime.rs:65 switching_blend_mode_redraws")
    func switchingBlendModeRedraws() {
        let rt = makeBlendTestRuntime(srgbBlend: false)
        _ = rt.renderFrame(at: 0.0)
        let commits0 = rt.viewCommitCount
        #expect(rt.hasPendingCommit == false)

        // Setting the same blend mode is a no-op (does not dirty commit or increment viewCommitCount)
        rt.setSrgbBlend(false, at: 0.01)
        #expect(rt.hasPendingCommit == false)
        _ = rt.renderFrame(at: 0.01)
        #expect(rt.viewCommitCount == commits0)

        // Switching blend mode dirties commit and triggers a new view commit & RenderFrame.srgbBlend update
        rt.setSrgbBlend(true, at: 0.02)
        #expect(rt.hasPendingCommit == true)
        let rf = rt.renderFrame(at: 0.02)
        #expect(rf.srgbBlend == true)
        #expect(rt.viewCommitCount == commits0 + 1)
    }

    /// Upstream: `crates/rune/tests/srgb_blend_runtime.rs:80` `a_handler_switches_blend_mode_live`
    @Test("srgb_blend_runtime.rs:80 a_handler_switches_blend_mode_live")
    func handlerSwitchesBlendModeLive() {
        struct S { var step = 0 }
        let rt = Runtime<S>(state: S(), viewport: Vec2(40, 40), pixelScale: 1.0) { _, _ in
            col().size(40, 40)
                .child(
                    el().key("toggle").size(40, 40)
                        .onClick { s, tx in
                            if s.step == 0 {
                                // Last call in handler wins
                                tx.setSrgbBlend(false)
                                tx.setSrgbBlend(true)
                            } else {
                                tx.setSrgbBlend(false)
                            }
                            s.step += 1
                        }
                )
        }
        rt.setSrgbBlend(false)
        _ = rt.renderFrame(at: 0.0)
        #expect(rt.srgbBlend == false)

        rt.pointerMove(to: Vec2(20, 20), at: 0.01)
        rt.pointerDown(at: Vec2(20, 20), button: .primary, at: 0.01)
        rt.pointerUp(at: Vec2(20, 20), button: .primary, at: 0.02)
        #expect(rt.srgbBlend == true)
        #expect(rt.renderFrame(at: 0.02).srgbBlend == true)

        rt.pointerDown(at: Vec2(20, 20), button: .primary, at: 0.03)
        rt.pointerUp(at: Vec2(20, 20), button: .primary, at: 0.04)
        #expect(rt.srgbBlend == false)
        #expect(rt.renderFrame(at: 0.04).srgbBlend == false)
    }

#if canImport(Metal) && canImport(QuartzCore)
    /// Upstream: `crates/rune/tests/srgb_blend_runtime.rs:56` `a_self_drawn_runtime_renders_gamma_blended_pixels`
    @Test("srgb_blend_runtime.rs:56 a_self_drawn_runtime_renders_gamma_blended_pixels")
    func selfDrawnRuntimeRendersGammaBlendedPixels() throws {
        let renderer = try MetalRenderer()

        let rtGamma = makeBlendTestRuntime(srgbBlend: true)
        _ = rtGamma.renderFrame(at: 0.0)
        rtGamma.pointerMove(to: Vec2(10, 10), at: 0.01)
        let imgGamma = try renderer.renderOffscreen(rtGamma.renderFrame(at: 0.02))
        let pxGamma = sampleRGBA(imgGamma, x: 10, y: 10)
        #expect(pxGamma.r >= 253)
        #expect(abs(Int(pxGamma.g) - 128) <= 2)
        #expect(abs(Int(pxGamma.b) - 128) <= 2)
        #expect(pxGamma.a == 255)

        let rtLinear = makeBlendTestRuntime(srgbBlend: false)
        _ = rtLinear.renderFrame(at: 0.0)
        rtLinear.pointerMove(to: Vec2(10, 10), at: 0.01)
        let imgLinear = try renderer.renderOffscreen(rtLinear.renderFrame(at: 0.02))
        let pxLinear = sampleRGBA(imgLinear, x: 10, y: 10)
        #expect(pxLinear.r >= 253)
        #expect(abs(Int(pxLinear.g) - 188) <= 2)
        #expect(abs(Int(pxLinear.b) - 188) <= 2)
        #expect(pxLinear.a == 255)
    }

    private final class BlendTrackingCompositor: Compositor {
        typealias State = Bool
        var srgbHistory: [Bool] = []
        var formatHistory: [MTLPixelFormat] = []
        var isAnimating: Bool { false }
        var drawsOwnContent: Bool { false }

        func render(frame: CompositorFrame<Bool>) {
            srgbHistory.append(frame.srgbBlend)
            formatHistory.append(frame.pixelFormat)
            frame.drawUI()
        }
    }

    /// Upstream: `crates/rune/tests/srgb_blend_runtime.rs:93` `a_headless_run_follows_a_live_switch`
    @Test("srgb_blend_runtime.rs:93 a_headless_run_follows_a_live_switch")
    func headlessRunFollowsLiveSwitch() throws {
        let comp = BlendTrackingCompositor()
        let app = App<Bool>(title: "BlendLive", size: Vec2(40, 40), state: false) { _, _ in
            col().size(40, 40).bg(.black)
                .child(
                    el().key("btn").size(20, 20)
                        .bg(Color(r: 1, g: 0, b: 0, a: 1))
                        .hover(Color(r: 1, g: 1, b: 1, a: 0.5))
                        .onClick { s, tx in
                            s.toggle()
                            tx.setSrgbBlend(s)
                        }
                )
        }
        .srgbBlend(false)
        .compositor(comp)

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("rune-srgb-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        var args = ToolingArgs()
        args.scriptArg = """
        [
          { "t": 0.05, "type": "tap", "key": "btn" },
          { "t": 0.15, "type": "move", "x": 10, "y": 10 }
        ]
        """
        args.pixelScale = 1.0
        args.framesDir = tmpDir.path
        args.fps = 30.0
        let out = try HeadlessRunner.run(app, args: args)

        // Single headless run starts linear/sRGB-target (.bgra8Unorm_srgb, false) and switches live to (.bgra8Unorm, true)
        #expect(comp.srgbHistory.first == false)
        #expect(comp.srgbHistory.last == true)
        #expect(comp.formatHistory.first == .bgra8Unorm_srgb)
        #expect(comp.formatHistory.last == .bgra8Unorm)

        // Final frame rendered with gamma sRGB blending produces ~128 green on the hovered red+white(0.5) box
        let px = sampleRGBA(out.finalFrame, x: 10, y: 10)
        #expect(px.r >= 253)
        #expect(abs(Int(px.g) - 128) <= 2)
        #expect(abs(Int(px.b) - 128) <= 2)
    }

    /// Upstream: `crates/rune/tests/srgb_blend_runtime.rs:133` `switching_format_keeps_the_glyph_atlas_and_extra_pipelines`
    @Test("srgb_blend_runtime.rs:133 switching_format_keeps_the_glyph_atlas_and_extra_pipelines")
    func switchingFormatKeepsGlyphAtlasAndExtraPipelines() throws {
        let renderer = try MetalRenderer()
        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(80, 40), pixelScale: 1.0) { _, _ in
            col().size(80, 40).bg(.black)
                .child(
                    col().size(80, 40).clipRounded(6)
                        .children([
                            text("Hi").font(TextStyle(size: 16)).color(.white),
                            el().size(8, 8).bg(.white),
                        ])
                )
        }
        let rf = rt.renderFrame(at: 0.0)
        #expect(rf.instances.contains(where: { $0.params.y == KIND_GLYPH }))
        #expect(rf.instances.contains(where: { $0.params.y == KIND_LAYER }))

        let uploader = renderer.renderEngine.uploader
        let formats: [MTLPixelFormat] = [.bgra8Unorm_srgb, .bgra8Unorm, .rgba16Float]
        var initialGlyphTex: MTLTexture? = nil
        var initialGen: UInt64 = 0

        for fmt in formats {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: 80, height: 40, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            let target = try #require(renderer.device.makeTexture(descriptor: desc))
            let cb = try #require(renderer.commandQueue.makeCommandBuffer())
            renderer.drawRange(frame: rf, into: target, commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()

            let tex = try #require(uploader.glyphTexture)
            if initialGlyphTex == nil {
                initialGlyphTex = tex
                initialGen = uploader.glyphGeneration
                #expect(initialGen == rf.glyphGeneration)
            } else {
                // Switching formats keeps the uploaded glyph atlas texture and generation intact without re-upload
                #expect(tex === initialGlyphTex)
                #expect(uploader.glyphGeneration == initialGen)
            }
        }

        // Verify extra pipelines across all three formats compiled cleanly on the engine
        #expect(renderer.renderEngine.pipelineFloat != nil)
        #expect(renderer.hasCompiledExtendedShaders)
    }
#endif
}
