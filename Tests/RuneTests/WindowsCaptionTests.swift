import Testing
@testable import Rune

@Suite("Windows custom titlebar")
struct WindowsCaptionTests {
    private func descendants(_ node: AccessibilityNode) -> [AccessibilityNode] {
        [node] + node.children.flatMap(descendants)
    }

    @Test func colorsAndGeometryAtFractionalDPIAndZoom() throws {
        let runtime = Runtime<Void>(state: (), viewport: Vec2(320, 96), pixelScale: 1.25) { _, cx in
            cx.zoom(2)
            cx.titlebarHeight(31.5)
            cx.captionColor(.black)
            return el().key("app").bg(.white)
        }
        runtime.syncWindowsCaption(TitlebarCaption(height: 24, mirrored: false, state: .hovered(.close)))
        let reference = try RuneRef.render(runtime.frame(at: 0))
        // 46 points become 58 pixels; the 13-pixel symbol is centered within each 58 × 39 box.
        #expect(reference.width == 400)
        #expect(reference.pixel(x: 253, y: 19) == SIMD4(0, 0, 0, 255))
        #expect(reference.pixel(x: 253, y: 18) == SIMD4(255, 255, 255, 255))
        #expect(reference.pixel(x: 341, y: 3) == SIMD4(255, 255, 255, 255))
        let close = reference.pixel(x: 342, y: 3)
        #expect(close.x >= 231 && close.y <= 20 && close.z <= 36 && close.w == 255)
        #expect(reference.pixel(x: 342, y: 38) == close)
        #expect(reference.pixel(x: 342, y: 39) == SIMD4(255, 255, 255, 255))
        let native = runtime.renderFrame(at: 0)
        #expect(native.width == reference.width)
        #if canImport(Metal) || canImport(CRuneOffscreenGL)
        let gpu = try OffscreenGPURenderer().renderOffscreen(native)
        for (x, y) in [(253, 19), (253, 18), (341, 3), (342, 3), (342, 38), (342, 39)] {
            let a = gpu.pixel(x: x, y: y), b = reference.pixel(x: x, y: y)
            for channel in 0..<4 { #expect(abs(Int(a[channel]) - Int(b[channel])) <= 1) }
        }
        #endif
    }

    @Test func mirroredButtonsRemainAvailableAboveAModal() throws {
        let rt = Runtime<Void>(state: (), viewport: Vec2(320, 96), pixelScale: 1.25) { _, _ in
            col().key("app").clip().offset(32, 12)
                .child(el().key("behind").size(20, 20).onClick { _ in })
                .child(el().key("dialog").modal().child(el().key("inside").size(24, 24).onClick { _ in }))
        }
        rt.syncWindowsCaption(TitlebarCaption(height: 32, mirrored: true, maximized: true,
                                              minimizable: false, state: .pressed(.close, over: false)))
        _ = rt.frame(at: 0)
        let close = try #require(rt.element(byKey: "rune-caption-close"))
        #expect(abs(close.rect[0]) < 0.001 && abs(close.rect[1]) < 0.001 && abs(close.rect[2] - 46.4) < 0.001)
        #expect(close.fill.a == 0)
        #expect(rt.windowChromeInsets() == ChromeInsets(leading: 46.4 * 3, height: 32))
        for snapshot in [rt.accessibilitySnapshot(), AccessibilityTreeBuilder.project(elements: rt.elements(),
                             focusedPath: nil, viewport: rt.viewport)] {
            let nodes = descendants(snapshot)
            #expect(nodes.contains { $0.id == "inside" })
            #expect(!nodes.contains { $0.id == "behind" })
            let buttons = nodes.filter { $0.id.hasPrefix("rune-caption-") }
            #expect(buttons.map(\.label) == ["Close", "Restore", "Minimize"])
            #expect(buttons.allSatisfy { !$0.isFocusable })
            #expect(buttons.first { $0.label == "Close" }?.actions.contains(.press) == true)
            #expect(buttons.first { $0.label == "Minimize" }?.isDisabled == true)
        }
        #expect(!rt.accessibilityAction("rune-caption-minimize", .press))
        #expect(!rt.minimizeRequested)
        #expect(rt.accessibilityAction("rune-caption-maximize", .press))
        #expect(rt.toggleMaximizedRequested)
        #expect(rt.accessibilityAction("rune-caption-close", .press))
        #expect(rt.closeWindowRequested)
    }

    @Test func fullscreenKeepsAppIdentityAndFixedWindowsReserveOnlyClose() throws {
        let rt = Runtime<Void>(state: (), viewport: Vec2(320, 96), pixelScale: 1) { _, _ in
            el().key("app")
        }
        var caption = TitlebarCaption(height: 30, mirrored: false, minimizable: false, maximizable: false)
        rt.syncWindowsCaption(caption)
        _ = rt.frame(at: 0)
        let path = try #require(rt.element(byKey: "app")).path
        #expect(rt.windowChromeInsets() == ChromeInsets(trailing: 46, height: 30))
        #expect(rt.element(byKey: "rune-caption-minimize") == nil)
        #expect(rt.element(byKey: "rune-caption-maximize") == nil)
        #expect(rt.element(byKey: "rune-caption-close")?.rect == [274, 0, 46, 30])
        caption.hidden = true
        rt.syncWindowsCaption(caption)
        _ = rt.frame(at: 1)
        #expect(rt.windowChromeInsets() == ChromeInsets(height: 30))
        #expect(rt.element(byKey: "app")?.path == path)
        #expect(rt.flatNodes.allSatisfy { $0.key != "rune-caption" })
        rt.syncWindowsCaption(nil)
        #expect(rt.windowChromeInsets() == .zero)
    }

    @Test func nativePressWashesAndRestoreSymbolTrackTheWindow() throws {
        let ink = Color(r: 0.1, g: 0.6, b: 0.2, a: 0.75)
        let red = Color(r: 0.8075, g: 0.0058, b: 0.0169)
        let cases: [(TitlebarCaptionState, Bool, Bool, Color, Color)] = [
            (.hovered(.minimize), false, true, ink.scaleAlpha(26.0 / 255), .transparent),
            (.pressed(.minimize, over: true), false, true, ink.scaleAlpha(51.0 / 255), .transparent),
            (.pressed(.minimize, over: false), false, true, .transparent, .transparent),
            (.hovered(.close), true, false, .transparent, red),
            (.pressed(.close, over: true), true, false, .transparent, red.alpha(152.0 / 255)),
            (.hovered(.minimize), true, false, .transparent, .transparent)
        ]
        for (state, maximized, minimizable, minFill, closeFill) in cases {
            let rt = Runtime<Void>(state: (), viewport: Vec2(180, 64), pixelScale: 1) { _, cx in
                cx.captionColor(ink)
                return el().bg(.white)
            }
            rt.syncWindowsCaption(TitlebarCaption(height: 32, mirrored: false, maximized: maximized,
                                                   minimizable: minimizable, state: state))
            _ = rt.renderFrame(at: 0)
            let min = try #require(rt.flatNodes.first { $0.key == "rune-caption-minimize" })
            let close = try #require(rt.flatNodes.first { $0.key == "rune-caption-close" })
            let max = try #require(rt.flatNodes.first { $0.key == "rune-caption-maximize" })
            #expect(min.el.background == minFill && close.el.background == closeFill)
            let expectedInk = minimizable ? ink : ink.scaleAlpha(92.0 / 255)
            let bar = try #require(min.el.children.first?.shapes.first?.ops.first)
            guard case .fill(_, let color) = bar else { Issue.record("Minimize glyph should be a filled bar"); return }
            #expect(color == expectedInk)
            let outline = try #require(max.el.children.first?.shapes.first?.ops)
            #expect(outline.count == (maximized ? 2 : 1))
            if maximized {
                guard case .stroke(_, let closed, _, _, _) = outline[1] else { Issue.record("Restore glyph should include a back outline"); return }
                #expect(!closed)
            }
        }
    }

    @Test func headlessWindowFollowsViewHeightAndDisplayScale() throws {
        let rt = Runtime<Float>(state: 32, viewport: Vec2(320, 96), pixelScale: 1) { height, cx in
            cx.titlebarHeight(height)
            return el().key("app")
        }
        rt.setHeadlessWindowsTitlebar(Titlebar(), borderless: false)
        _ = rt.frame(at: 0)
        #expect(rt.windowChromeInsets().height == 32)
        rt.update(at: 0.1) { height, tx in height = 42; tx.instant() }
        rt.setViewport(Vec2(320, 96), pixelScale: 1.25)
        _ = rt.frame(at: 0.1)
        #expect(rt.windowChromeInsets().height == 42)
        let close = try #require(rt.element(byKey: "rune-caption-close"))
        #expect(abs(close.target[2] - 46.4) < 0.001 && abs(close.target[3] - 42.4) < 0.001)
        rt.setHeadlessWindowsTitlebar(Titlebar(), borderless: true)
        _ = rt.frame(at: 1)
        #expect(rt.windowChromeInsets() == .zero)
        #expect(rt.flatNodes.allSatisfy { $0.key != TitlebarCaption.frameKey })
    }
}
