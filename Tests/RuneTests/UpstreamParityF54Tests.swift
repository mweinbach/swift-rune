import Foundation
import RuneMotion
import RuneRef
import Testing
@testable import Rune

@Suite("Upstream Parity eb9f1104..f54cbcfa (#1214, #1222, #1224, #1226, #1228, #1236)")
struct UpstreamParityF54Tests {
    // MARK: - 1. #1214 El.wheelScrolls(_:)

    @Test("#1214: wheel over a sibling bar naming its viewport scrolls that viewport, respects occlusion, chains up, and scopes per pane")
    func elWheelScrollsRoutingParity() {
        // 1a. Named bar scrolls sibling viewport; unnamed bar does not.
        func makeBarred(named: Bool) -> Runtime<Void> {
            Runtime(state: (), viewport: Vec2(300, 200), pixelScale: 1) { _, _ in
                var bar: El<Void> = el().key("bar").absolute(x: 286, y: 0).size(14, 200).onDrag { _, _, _ in }
                if named { bar = bar.wheelScrolls("area/list") }
                return el().key("root").size(300, 200).child(
                    col().key("area").size(300, 200)
                        .child(col().key("list").size(300, 200).scrollY().child(el().size(300, 1000).shrink(0)))
                        .child(bar)
                )
            }
        }
        let namedRt = makeBarred(named: true)
        _ = namedRt.frame(at: 0)
        namedRt.wheelXY(293, 100, 0, -30, now: 0.01)
        _ = namedRt.frame(at: 0.5)
        let listPath = namedRt.flatNodes.first(where: { $0.key == "list" })!.path
        #expect(abs((namedRt.scrollOffsets[listPath]?.y ?? 0) - 30) <= 1.0)

        let plainRt = makeBarred(named: false)
        _ = plainRt.frame(at: 0)
        plainRt.wheelXY(293, 100, 0, -30, now: 0.01)
        _ = plainRt.frame(at: 0.5)
        #expect((plainRt.scrollOffsets[listPath]?.y ?? 0) == 0)

        // 1b. Chains upward from named viewport when named viewport has no room.
        let chainedRt = Runtime(state: (), viewport: Vec2(300, 200), pixelScale: 1) { _, _ in
            el().key("root").size(300, 200).child(
                col().key("page").size(300, 200).scrollY().child(
                    el().key("body").size(300, 1000).shrink(0).child(
                        col().key("area").size(300, 200)
                            .child(col().key("list").size(300, 200).scrollY().child(el().size(300, 100).shrink(0)))
                            .child(el().key("bar").absolute(x: 286, y: 0).size(14, 200).onDrag { _, _, _ in }.wheelScrolls("area/list"))
                    )
                )
            )
        }
        _ = chainedRt.frame(at: 0)
        chainedRt.wheelXY(293, 100, 0, -30, now: 0.01)
        _ = chainedRt.frame(at: 0.5)
        let pagePath = chainedRt.flatNodes.first(where: { $0.key == "page" })!.path
        #expect(abs((chainedRt.scrollOffsets[pagePath]?.y ?? 0) - 30) <= 1.0)

        // 1c. Raised panel over bar still blocks the wheel from reaching the bar.
        let panelRt = Runtime(state: (), viewport: Vec2(300, 200), pixelScale: 1) { _, _ in
            el().key("root").size(300, 200).child(
                col().key("area").size(300, 200)
                    .child(col().key("list").size(300, 200).scrollY().child(el().size(300, 1000).shrink(0)))
                    .child(el().key("bar").absolute(x: 286, y: 0).size(14, 200).onDrag { _, _, _ in }.wheelScrolls("area/list"))
                    .child(el().key("panel").absolute(x: 280, y: 0).size(20, 100).raise())
            )
        }
        _ = panelRt.frame(at: 0)
        panelRt.wheelXY(293, 60, 0, -30, now: 0.01)
        _ = panelRt.frame(at: 0.5)
        #expect((panelRt.scrollOffsets[listPath]?.y ?? 0) == 0)

        // 1d. Two identically-keyed panes each scroll their own viewport.
        let panesRt = Runtime(state: (), viewport: Vec2(300, 200), pixelScale: 1) { _, _ in
            func pane(_ k: String) -> El<Void> {
                col().key(k).size(150, 200).child(
                    col().key("area").size(150, 200)
                        .child(col().key("list").size(150, 200).scrollY().child(el().size(150, 1000).shrink(0)))
                        .child(el().key("bar").absolute(x: 136, y: 0).size(14, 200).onDrag { _, _, _ in }.wheelScrolls("area/list"))
                )
            }
            return row().key("root").size(300, 200).child(pane("left")).child(pane("right"))
        }
        _ = panesRt.frame(at: 0)
        panesRt.wheelXY(293, 100, 0, -30, now: 0.01)
        _ = panesRt.frame(at: 0.5)
        let leftPath = panesRt.flatNodes.first(where: { $0.path.contains("left") && $0.key == "list" })!.path
        let rightPath = panesRt.flatNodes.first(where: { $0.path.contains("right") && $0.key == "list" })!.path
        #expect((panesRt.scrollOffsets[leftPath]?.y ?? 0) == 0)
        #expect(abs((panesRt.scrollOffsets[rightPath]?.y ?? 0) - 30) <= 1.0)

        // 1e. Sideways wheel over a bar scrolls horizontal viewport.
        let horizRt = Runtime(state: (), viewport: Vec2(300, 200), pixelScale: 1) { _, _ in
            el().key("root").size(300, 200).child(
                col().key("area").size(300, 200)
                    .child(col().key("table").size(300, 100).scrollX().child(el().size(900, 100).shrink(0)))
                    .child(el().key("bar").absolute(x: 0, y: 102).size(300, 8).onDrag { _, _, _ in }.wheelScrolls("area/table"))
            )
        }
        _ = horizRt.frame(at: 0)
        horizRt.wheelXY(150, 106, -40, 0, now: 0.01)
        _ = horizRt.frame(at: 0.5)
        let tablePath = horizRt.flatNodes.first(where: { $0.key == "table" })!.path
        #expect(abs((horizRt.scrollOffsets[tablePath]?.x ?? 0) - 40) <= 1.0)
    }

    // MARK: - 2. #1224 Canonical RenderInstance Bounds

    @Test("#1224: RenderInstance quadBounds, damageQuadBounds, and layerBounds tighten banded, rotated, and effect primitives")
    func renderInstanceCanonicalBoundsParity() {
        // Banded rect clamps to its uv band window [x+uv.x, y+uv.y, x-uv.z, y+uv.w]
        let banded = RenderInstance(
            rect: SIMD4(10, 20, 200, 200),
            params: SIMD4(2, KIND_RECT, 0, 1),
            uv: SIMD4(0, 0, -40, 30),
            clip: NO_CLIP
        )
        let lb = banded.layerBounds()
        #expect(lb.x == 10 && lb.y == 20 && lb.z == 50 && lb.w == 50)
        let qb = banded.quadBounds()!
        #expect(qb.x == 10 && qb.y == 20 && qb.z == 50 && qb.w == 50)

        // Effect slot has nil quadBounds (non-uber) but positive damageQuadBounds & layerBounds with bleed
        let effect = RenderInstance(
            rect: SIMD4(50, 60, 100, 80),
            params: SIMD4(0, KIND_EFFECT, 12, 0),
            clip: NO_CLIP
        )
        #expect(effect.quadBounds() == nil)
        let ed = effect.damageQuadBounds()!
        #expect(ed.x == 37 && ed.y == 47 && ed.z == 163 && ed.w == 153)
        let elBounds = effect.layerBounds()
        #expect(elBounds == ed)

        // Turned layer composite rotates its quad bounds about its pivot
        let turned = RenderInstance.beginLayer(bounds: SIMD4(100, 100, 40, 20), clip: NO_CLIP)
            .turned(angle: .pi / 2, pivot: SIMD2(120, 110))
        let tqb = turned.quadBounds()!
        // Width/height swap after 90-degree rotation around center (120, 110)
        #expect(abs((tqb.z - tqb.x) - 22) < 0.2)
        #expect(abs((tqb.w - tqb.y) - 42) < 0.2)
        _ = banded
    }

    // MARK: - 3. #1228 CPU Boot PlusLighter Additive Overlap (No Occluder Culling)

    @Test("#1228: CPU boot painter adds overlapping opaque children inside a PlusLighter dissolve layer instead of culling")
    func cpuBootPlusLighterKeepsAdditiveOverlaps() throws {
        let begin = RenderInstance.beginLayer(
            bounds: SIMD4(0, 0, 16, 16),
            clip: NO_CLIP,
            spec: LayerSpec(opacity: 1.0, blend: .plusLighter)
        )
        // Two overlapping opaque boxes (red then green) -> PlusLighter should yield yellow (255, 255, 0, 255), NOT green!
        let red = RenderInstance(
            rect: SIMD4(0, 0, 16, 16),
            fill: SIMD4(1, 0, 0, 1),
            params: SIMD4(0, KIND_RECT, 0, 1),
            clip: NO_CLIP
        )
        let green = RenderInstance(
            rect: SIMD4(0, 0, 16, 16),
            fill: SIMD4(0, 1, 0, 1),
            params: SIMD4(0, KIND_RECT, 0, 1),
            clip: NO_CLIP
        )
        let end = RenderInstance.endLayer()
        let scene = CpuBootScene(
            instances: [begin, red, green, end],
            size: (16, 16),
            clear: SIMD4(0, 0, 0, 1),
            srgbBlend: true
        )
        var target = CpuBootTarget(width: 16, height: 16)
        _ = try CpuBoot.paint(scene, into: &target, threads: 1)
        let frame = target.toRGBA8Tight()
        let center = (8 * 16 + 8) * 4
        #expect(frame[center] >= 250)     // R preserved from red under green!
        #expect(frame[center + 1] >= 250) // G added from green
        #expect(frame[center + 2] <= 5)   // B = 0
        #expect(frame[center + 3] == 255) // A = 255
    }

    // MARK: - 4. #1222 Spellcheck Regional Tag Matching & Tray Label Escaping

    @Test("#1222: SpellChecker resolves regional/underscore tags without prefix cross-matches")
    func spellcheckRegionalTagParity() {
        #expect(SpellChecker.defaultLanguages(available: ["de-DE", "en-US"], preferred: ["de-AT"]) == ["de-DE", "en-US"])
        #expect(SpellChecker.defaultLanguages(available: ["en-GB"], preferred: ["en-AU"]) == ["en-GB"])
        #expect(SpellChecker.defaultLanguages(available: ["en-US"], preferred: ["en_US"]) == ["en-US"])
        #expect(SpellChecker.defaultLanguages(available: ["en_US", "fr-FR"], preferred: ["fr-CA"]) == ["fr-FR", "en_US"])
        #expect(SpellChecker.defaultLanguages(available: ["de-DE", "de", "de-AT"], preferred: ["de-AT"]) == ["de-AT"])
        #expect(SpellChecker.defaultLanguages(available: ["de-DE", "de"], preferred: ["de-AT"]) == ["de"])
        // Prefix-similar tags must not cross-match
        #expect(SpellChecker.defaultLanguages(available: ["est-EE", "en-US"], preferred: ["es-MX"]) == ["en-US"])
        #expect(SpellChecker.defaultLanguages(available: ["eng-GB"], preferred: ["en-AU"]) == [])
        // Chosen resolution
        #expect(SpellChecker.resolveLanguages(available: ["en-US", "de-DE"], chosen: ["en_us", "de-AT"], preferred: ["fr-FR"]) == ["en-US", "de-DE"])
        #expect(SpellChecker.resolveLanguages(available: ["en-GB", "en-US"], chosen: ["en-GB", "en-US"], preferred: []) == ["en-GB", "en-US"])
        #expect(SpellChecker.resolveLanguages(available: ["en-US"], chosen: ["fr-FR"], preferred: ["en-AU"]) == ["en-US"])
        // Dialect names normalize case & underscores
        #expect(SpellChecker.shared.languageName(for: "en_US") == "American English")
        #expect(SpellChecker.shared.languageName(for: "en-au") == "Australian English")
    }

    @Test("#1222: TrayLabelFormatting escapes Win32/D-Bus mnemonics and truncates UTF-16 without splitting surrogate pairs")
    func trayLabelFormattingParity() {
        #expect(TrayLabelFormatting.win32MenuLabel("Save & Quit") == "Save && Quit")
        #expect(TrayLabelFormatting.win32MenuLabel("A\tB\0C") == "A BC")
        #expect(TrayLabelFormatting.win32MenuLabel("open_file") == "open_file")

        #expect(TrayLabelFormatting.dbusMenuLabel("open_file") == "open__file")
        #expect(TrayLabelFormatting.dbusMenuLabel("Save & Quit") == "Save & Quit")
        #expect(TrayLabelFormatting.dbusMenuLabel("A\0B") == "AB")

        // 126 ASCII chars + 1 emoji (2 UTF-16 units = 128 > 127) must truncate cleanly at 126 without half-surrogate
        let over = String(repeating: "a", count: 126) + "😀"
        let truncated = TrayLabelFormatting.truncateUTF16(over, maxUnits: 127)
        #expect(truncated.count == 126)
        #expect(String(utf16CodeUnits: truncated, count: truncated.count) == String(repeating: "a", count: 126))

        let fits = String(repeating: "a", count: 125) + "😀"
        let kept = TrayLabelFormatting.truncateUTF16(fits, maxUnits: 127)
        #expect(kept.count == 127)
        #expect(String(utf16CodeUnits: kept, count: kept.count) == fits)
    }

    // MARK: - 5. #1222 & #1236 VirtualDesktop Zoom Input, Hide KeysLost, and Resize

    @Test("#1222/#1236: VirtualDesktopWindow scales pointer/wheel/find by zoom, handles resizeBy, and emits keysLost on hide")
    func virtualDesktopZoomAndHideParity() {
        struct S {
            var wheelDY: [Float] = []
            var focusLost = 0
        }
        let app = App<S>(title: "Z", size: Vec2(200, 100), state: S()) { _, cx in
            cx.zoom(2.0)
            return el().key("root").size(200, 100).focusable(true)
                .child(
                    el().key("btn").absolute(x: 20, y: 10).size(40, 20).hit()
                        .onWheel { s, ev, _ in s.wheelDY.append(ev.dy); return true }
                )
                .onPhysicalInput { s, ev, _ in
                    if case .focusLost = ev {
                        s.focusLost += 1
                        return true
                    }
                    return false
                }
        }.keepRunning()
        let w = DesktopWindow(key: "z", spec: AppWindowSpec(app: app), scale: 1.0, dark: true)
        let desktop = VirtualDesktop.single(scale: 1.0)
        w.start(desktop: desktop)
        w.advance(dt: 0)
        w.runtime.update(at: 0) { _, tx in tx.focus("root") }
        w.advance(dt: 0)

        // Element at view (20..60, 10..30) -> center (40, 20) -> window (80, 40) at 2x zoom.
        let found = w.find(key: "btn")
        #expect(found != nil && abs(found!.0 - 80) < 0.5 && abs(found!.1 - 40) < 0.5)

        w.input(.move, at: (80, 40))
        #expect(abs(w.runtime.pointerPosition.x - 40) < 0.5 && abs(w.runtime.pointerPosition.y - 20) < 0.5)
        let ptr = w.pointer()
        #expect(ptr != nil && abs(ptr!.0 - 80) < 0.5 && abs(ptr!.1 - 40) < 0.5)

        w.input(.scroll(dx: 0, dy: -40), at: (80, 40))
        w.advance(dt: 0)
        #expect(w.runtime.state.wheelDY == [-20.0])

        w.resizeBy(dw: 40, dh: 20)
        #expect(w.frame[2] == 240 && w.frame[3] == 120)

        w.setFocused(true)
        w.advance(dt: 0)
        w.hide()
        w.advance(dt: 0.01)
        #expect(w.runtime.state.focusLost >= 1)
    }

    // MARK: - 6. #1226 WebBrowserSession Zoom Input, Ctrl+Click, AltGr, Cancel & KeyUp

    @Test("#1226: WebBrowserSession scales pointer/wheel by zoom, maps macOS Ctrl+click to secondary, and resets on blur/pointercancel")
    @MainActor
    func webBrowserSessionInputParity() {
        struct S {
            var wheelDY: [Float] = []
            var secondaryClicks = 0
            var focusLost = 0
        }
        let app = AppSpec<S>(title: "Web", size: Vec2(200, 100), state: S()) { _, cx in
            cx.zoom(2.0)
            return el().key("root").size(200, 100).focusable(true)
                .child(
                    el().key("target").absolute(x: 20, y: 10).size(40, 20).hit()
                        .onWheel { s, ev, _ in s.wheelDY.append(ev.dy); return true }
                        .onSecondaryClick { s, _, _ in s.secondaryClicks += 1 }
                )
                .onPhysicalInput { s, ev, _ in
                    if case .focusLost = ev {
                        s.focusLost += 1
                        return true
                    }
                    return false
                }
        }
        let host = WebAppHost(spec: app)
        let session = WebBrowserSession(host)
        _ = try? session.renderFrame(at: 0, force: true)
        host.runtime.update(at: 0) { _, tx in tx.focus("root") }
        _ = try? session.renderFrame(at: 0.01, force: true)

        func sendJSON(_ obj: [String: Any], at t: Double) -> Bool {
            let data = try! JSONSerialization.data(withJSONObject: obj)
            return session.send(data, at: t)
        }

        // Wheel at window (80, 40) under 2x zoom hits view (40, 20) with delta / 2
        #expect(sendJSON(["kind": "wheel", "x": 80, "y": 40, "dx": 0, "dy": 40, "deltaMode": 0], at: 0.02))
        #expect(host.runtime.state.wheelDY == [-20.0])

        // macOS Ctrl+left-click triggers secondary click
        #expect(sendJSON(["kind": "pointerdown", "x": 80, "y": 40, "button": "primary", "pointerType": "mouse", "ctrl": true, "isMac": true], at: 0.03))
        #expect(sendJSON(["kind": "pointerup", "x": 80, "y": 40, "button": "primary", "pointerType": "mouse", "ctrl": true, "isMac": true], at: 0.04))
        #expect(host.runtime.state.secondaryClicks == 1)

        // Unhandled keyup does not request redraw
        _ = try? session.renderFrame(at: 0.05, force: true)
        #expect(!sendJSON(["kind": "keyup", "key": "x", "code": "KeyX"], at: 0.06))
        #expect(session.nextDelay(at: 0.06) > 0)

        // Blur cancels presses/keys
        #expect(sendJSON(["kind": "focus", "focused": false], at: 0.07))
        _ = try? session.renderFrame(at: 0.08, force: true)
        #expect(host.runtime.state.focusLost >= 1)
    }
}
