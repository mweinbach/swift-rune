import Foundation
import Testing
@testable import RuneKit
@testable import Rune

@Suite("RuneKit ImageZoom, Preview & Stage Parity Tests (Increment 2)")
struct ImageZoomParityTests {
    private struct PreviewApp {
        var zoom = ImageZoom()
        var open = true
    }

    private func makePreviewRuntime(withExitTransition: Bool = false) -> Runtime<PreviewApp> {
        let rt = Runtime<PreviewApp>(state: PreviewApp(), viewport: Vec2(1000, 700)) { app, _ in
            let root: El<PreviewApp> = el().wFull().hFull()
            guard app.open else { return root }
            let picture: El<PreviewApp> = el().key("picture")
            let preview = Preview(\PreviewApp.zoom, natural: Vec2(800, 600), image: picture)
                .onClose { s, _ in s.open = false }
                .build(app.zoom, kit: Kit.neutral(dark: true), window: Vec2(1000, 700))
            let animated = withExitTransition
                ? preview.animate(Tok.Motion.SNAPPY).transition(Transition(insertion: .identity, removal: TransitionEffect(zeroOpacity: 0)))
                : preview
            return root.child(animated)
        }
        rt.frame(at: 0)
        return rt
    }

    @Test("escape_on_a_zoomed_image_fits_it_before_closing (tests/image_zoom.rs)")
    func escapeOnZoomedImageFitsBeforeClosing() {
        let rt = makePreviewRuntime()
        var tx = Tx()
        _ = rt.state.zoom.measure(window: Vec2(1000, 700), natural: Vec2(800, 600))
        rt.state.zoom.zoomIn(tx: &tx, now: 0)
        rt.markNeedsCommit()
        rt.frame(at: 0)
        // Focus preview via click on image center (not backdrop!)
        rt.pointerDown(at: Vec2(500, 350), at: 0)
        rt.pointerUp(at: Vec2(500, 350), at: 0)
        rt.frame(at: 0)
        #expect(rt.state.open)
        #expect(rt.state.zoom.ownsEscape)

        _ = rt.keyDown(KeyEvent(key: .escape), at: 0.016)
        rt.frame(at: 0.016)
        #expect(rt.state.open && !rt.state.zoom.ownsEscape, "the first Escape fits")

        _ = rt.keyDown(KeyEvent(key: .escape), at: 0.032)
        rt.frame(at: 0.032)
        #expect(!rt.state.open, "the second Escape closes")
    }

    @Test("closing_mid_glide_still_animates_the_close (tests/image_zoom.rs)")
    func closingMidGlideStillAnimatesClose() {
        let rt = makePreviewRuntime(withExitTransition: true)
        var tx = Tx()
        _ = rt.state.zoom.measure(window: Vec2(1000, 700), natural: Vec2(800, 600))
        var t = 0.0
        rt.state.zoom.zoomIn(tx: &tx, now: t)
        for _ in 0..<2 {
            t += 1.0 / 60.0
            _ = rt.state.zoom.poll(now: t, tx: &tx)
        }
        rt.markNeedsCommit()
        rt.frame(at: t)
        rt.pointerDown(at: Vec2(500, 350), at: t)
        rt.pointerUp(at: Vec2(500, 350), at: t)
        rt.frame(at: t)
        #expect(rt.state.open)
        #expect(rt.state.zoom.isZoomed)

        t += 1.0 / 60.0
        _ = rt.keyDown(KeyEvent(key: .escape), at: t)
        rt.frame(at: t)
        #expect(rt.state.open, "first Escape fits without closing")
        for _ in 0..<3 {
            t += 1.0 / 60.0
            var pollTx = Tx()
            _ = rt.state.zoom.poll(now: t, tx: &pollTx)
            rt.markNeedsCommit()
            rt.frame(at: t)
        }
        #expect(rt.state.zoom.isGliding)
        t += 1.0 / 60.0
        _ = rt.keyDown(KeyEvent(key: .escape), at: t)
        rt.frame(at: t)
        #expect(!rt.state.open, "the second Escape closes mid-glide")
        let leaving = rt.element(byKey: ImageZoomKeys.preview)
        #expect(leaving?.exiting == true)
    }

    @Test("ImageZoom gesture machine: backdrop click, moved pan suppression, glide lifecycle & follow")
    func imageZoomGestureMachine() {
        var state = ImageZoomMachineState.default

        // Backdrop press & release without moving closes
        #expect(imageZoomStep(&state, .pointerDown(onBody: true, onBackdrop: true, zoomed: false, at: Vec2(10, 10))) == [])
        #expect(imageZoomStep(&state, .pointerUp) == [])
        #expect(imageZoomStep(&state, .click(onBackdrop: true)) == [.close])
        #expect(state == .still(.idle))

        // Zoomed pan that moved suppresses backdrop close even on backdrop release
        #expect(imageZoomStep(&state, .pointerDown(onBody: true, onBackdrop: true, zoomed: true, at: Vec2(10, 10))) == [])
        #expect(state.isDragging)
        #expect(imageZoomStep(&state, .pointerMoved(at: Vec2(25, 18))) == [.pan(Vec2(15, 8))])
        #expect(imageZoomStep(&state, .pointerUp) == [])
        #expect(imageZoomStep(&state, .click(onBackdrop: true)) == [])
        #expect(!state.isDragging)

        // GlideStart emits .frames once; repeated GlideStart does not re-emit .frames
        #expect(imageZoomStep(&state, .glideStart(now: 1.0)) == [.frames])
        #expect(imageZoomStep(&state, .glideStart(now: 1.05)) == [])
        #expect(imageZoomStep(&state, .glideSettled(zoomed: true)) == [])
        #expect(state == .still(.idle))

        // Follow snaps out of gliding immediately
        _ = imageZoomStep(&state, .glideStart(now: 2.0))
        _ = imageZoomStep(&state, .follow(zoomed: false))
        #expect(state == .still(.idle))
    }

    @Test("ImageZoom level, detail double-click, keys, reducedMotion & poll convergence")
    func imageZoomControlsAndReducedMotion() {
        var zoom = ImageZoom()
        let (body, fitted) = zoom.measure(window: Vec2(1000, 700), natural: Vec2(1600, 1200))
        #expect(body[2] > 0 && fitted.x > 0 && fitted.y > 0)
        let r = zoom.imageRect(body: body, fitted: fitted)
        #expect(r[2] == fitted.x && r[3] == fitted.y)
        #expect(zoom.level == UInt32((zoom.fitRatio * 100).rounded()))

        var tx = Tx()
        // Double-click detail zooms toward 100% (or 2x)
        zoom.detail(at: .zero, tx: &tx, now: 0)
        #expect(zoom.isGliding)
        #expect(zoom.ownsEscape)
        var t = 0.0
        for _ in 0..<60 {
            t += 1.0 / 60.0
            if !zoom.poll(now: t, tx: &tx) { break }
        }
        #expect(!zoom.isGliding)
        #expect(zoom.level == 100)

        // Keyboard shortcuts: Cmd+=, Cmd+-, 0
        let otherModifier = KeyPlatform.current == .mac ? Mods(ctrl: true) : Mods(logo: true)
        #expect(zoom.handleKey(KeyEvent(key: .command("+"), mods: otherModifier), tx: &tx, now: t) == nil)
        #expect(zoom.handleKey(KeyEvent(key: .command("+"), mods: RuneKitTestKey.primaryMods()), tx: &tx, now: t) == false)
        #expect(zoom.glide.goal.scale > 1.0)
        #expect(zoom.handleKey(KeyEvent(key: .text("0")), tx: &tx, now: t) == false)
        #expect(!zoom.ownsEscape)

        // Reduced motion snaps without entering gliding
        var rm = ImageZoom(reducedMotion: true)
        _ = rm.measure(window: Vec2(1000, 700), natural: Vec2(1600, 1200))
        rm.zoomIn(tx: &tx, now: 0)
        #expect(!rm.isGliding)
        #expect(rm.isZoomed)
    }

    @Test("StageZoom, stageStep drag threshold, and Stage view build")
    func stageZoomAndControls() {
        var g = StageGesture.idle
        #expect(stageStep(&g, .click) == [.toggle])

        // Below 3px threshold stays unmoved -> click still toggles
        _ = stageStep(&g, .pointerDown(zoomed: true, at: Vec2(100, 100)))
        #expect(stageStep(&g, .pointerMoved(at: Vec2(101, 101))) == [])
        _ = stageStep(&g, .pointerUp)
        #expect(g == .idle)

        // Above 3px threshold pans -> PointerUp sets suppressClick -> Click is absorbed
        _ = stageStep(&g, .pointerDown(zoomed: true, at: Vec2(100, 100)))
        #expect(stageStep(&g, .pointerMoved(at: Vec2(105, 100))) == [.pan(Vec2(5, 0))])
        _ = stageStep(&g, .pointerUp)
        #expect(g == .suppressClick)
        #expect(stageStep(&g, .click) == [])
        #expect(g == .idle)

        // StageZoom grows flag & zoom bounds
        var sz = StageZoom()
        sz.measure(size: Vec2(800, 600), natural: Vec2(200, 100), grows: false)
        #expect(sz.fit == 1.0)
        sz.measure(size: Vec2(800, 600), natural: Vec2(200, 100), grows: true)
        #expect(sz.fit > 1.0)

        var tx = Tx()
        sz.zoomBy(1.25, tx: &tx)
        #expect(sz.isZoomed)
        sz.reset(tx: &tx)
        #expect(!sz.isZoomed)

        struct StageApp { var stage = StageZoom() }
        let rt = Runtime<StageApp>(state: StageApp(), viewport: Vec2(800, 600)) { app, _ in
            Stage(\StageApp.stage, natural: Vec2(400, 300), image: el().key("pic"))
                .build(app.stage, kit: Kit.neutral(dark: true), size: Vec2(800, 600))
        }
        rt.frame(at: 0)
        #expect(rt.element(byKey: "artifact-stage") != nil)
        #expect(rt.element(byKey: "preview-controls") != nil)
        #expect(rt.element(byKey: "stage-zoom-in") != nil)
        #expect(rt.element(byKey: "stage-zoom-out") != nil)
        #expect(rt.element(byKey: "stage-fit") != nil)

        // Preview controlsTransition + backdrop click when zoomed
        let previewRt = makePreviewRuntime()
        _ = previewRt.state.zoom.measure(window: Vec2(1000, 700), natural: Vec2(800, 600))
        var zoomTx = Tx()
        previewRt.state.zoom.follow(ZoomView(scale: 1.5, x: 0, y: 0), tx: &zoomTx)
        let built = Preview(\PreviewApp.zoom, natural: Vec2(800, 600), image: el().key("p"))
            .controlsTransition(.opacity)
            .build(previewRt.state.zoom, kit: Kit.neutral(dark: true), window: Vec2(1000, 700))
        #expect(built.children.count >= 2)
        // Backdrop click outside image closes even when zoomed (onDragEnd false must not swallow backdropPress)
        previewRt.pointerDown(at: Vec2(10, 10), at: 0.1)
        previewRt.pointerUp(at: Vec2(10, 10), at: 0.1)
        previewRt.frame(at: 0.1)
        #expect(!previewRt.state.open)
    }
}
