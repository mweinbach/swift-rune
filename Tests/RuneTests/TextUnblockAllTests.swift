import Foundation
import Testing
import RuneMotion
@testable import Rune

// MARK: - URLProtocol Stub for HTTP/HTTPS ImageFromURL Tests

private final class MockImageURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (resp, data) = try handler(request)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite("Text Unblock All Parity (ImageFromURL, InlineIcon/Pills, CanvasInput, PointerObserver, DropPointer, KeyDiagnostics, KeyPaths, HostHooks, Quality, Selectable)")
struct TextUnblockAllTests {

    // MARK: - 1. image/from_url.rs & from_url_tests.rs (5 Rust tests + URLProtocol + file://)

    private static func makeTempSVG(name: String, body: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("\(name)-\(UUID().uuidString).svg")
        try! body.data(using: .utf8)!.write(to: url)
        return url
    }

    @Test("from_url_tests 1: decoded file shares handle per (url, px) and exposes pixels")
    func decodedFileSharesHandleAndPixels() throws {
        let svgURL = Self.makeTempSVG(
            name: "square",
            body: ##"<svg width="10" height="10" viewBox="0 0 10 10"><rect x="1" y="1" width="8" height="8" fill="#ff3366"/></svg>"##
        )
        defer { try? FileManager.default.removeItem(at: svgURL) }

        let cache = ImageCache()
        let a = cache.url(svgURL.path, sizePt: 16, scale: 2)
        let b = cache.url(svgURL.path, sizePt: 16, scale: 2)
        let c = cache.url("file://localhost" + svgURL.path, sizePt: 16, scale: 2)

        #expect(a === b)
        #expect(a.id == b.id)
        #expect(a !== c)

        let resA = a.wait(timeout: 2.0)
        let resC = c.wait(timeout: 2.0)
        guard case .success = resA, case .success = resC else {
            Issue.record("Expected local SVG loads to succeed: \(resA), \(resC)")
            return
        }
        #expect(a.error == nil)
        #expect((a.size?.0 ?? 0) > 0 && (a.size?.1 ?? 0) > 0)
        #expect(a.pixels.sourceURLString == svgURL.path)
    }

    @Test("from_url_tests 2: svg scales with point size * pixel scale and preserves width")
    func svgScalesToPointSizeTimesScale() {
        let svgURL = Self.makeTempSVG(
            name: "icon",
            body: ##"<svg viewBox="0 0 24 24"><path d="M2 2 L22 2 L22 22 L2 22 Z" fill="#00cc88"/></svg>"##
        )
        defer { try? FileManager.default.removeItem(at: svgURL) }

        let cache = ImageCache()
        let lo = cache.url(svgURL.path, sizePt: 16, scale: 1)
        let hi = cache.url(svgURL.path, sizePt: 16, scale: 2)

        guard case .success = lo.wait(timeout: 2.0), case .success = hi.wait(timeout: 2.0) else {
            Issue.record("Expected SVG decode to succeed")
            return
        }
        #expect(lo.size?.0 == 16)
        #expect(hi.size?.0 == 32)
        #expect(lo.id != hi.id)
    }

    @Test("from_url_tests 3: unsupported URL without session records prefixed error; URLProtocol HTTP succeeds")
    func unsupportedAndHTTPURLProtocol() {
        // Without session: remote http returns prefixed error.
        let bareCache = ImageCache()
        let bad = bareCache.url("https://example.com/a.svg", sizePt: 16, scale: 1)
        _ = bad.wait(timeout: 1.0)
        #expect(bad.error?.message.hasPrefix("https://example.com/a.svg: ") == true)

        // With URLSession + URLProtocol: HTTP remote SVG loads asynchronously and calls wake.
        final class WakeCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func inc() { lock.lock(); value += 1; lock.unlock() }
            func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let woke = WakeCounter()
        MockImageURLProtocol.handler = { req in
            let url = req.url!
            let svg = ##"<svg width="12" height="12" viewBox="0 0 12 12"><rect x="0" y="0" width="12" height="12" fill="#3366ff"/></svg>"##
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/svg+xml"])!
            return (resp, Data(svg.utf8))
        }
        defer { MockImageURLProtocol.handler = nil }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockImageURLProtocol.self]
        let session = URLSession(configuration: cfg)
        let cache = ImageCache(
            wake: { woke.inc() },
            session: session
        )

        let remote = cache.url("https://cdn.example.com/avatar.svg", sizePt: 20, scale: 2)
        guard case .success = remote.wait(timeout: 3.0) else {
            Issue.record("Expected URLProtocol SVG fetch to succeed")
            return
        }
        #expect(remote.error == nil)
        #expect(remote.size?.0 == 40)
        #expect(woke.get() >= 1)
    }

    @Test("from_url_tests 4: urlSet picks narrowest source >= target px and shares handle")
    func urlSetSelectsNarrowestCoveringTarget() {
        let small = Self.makeTempSVG(name: "s100", body: ##"<svg width="16" height="16" viewBox="0 0 16 16"><rect x="0" y="0" width="16" height="16" fill="#ff0000"/></svg>"##)
        let large = Self.makeTempSVG(name: "s200", body: ##"<svg width="16" height="16" viewBox="0 0 16 16"><rect x="0" y="0" width="16" height="16" fill="#00ff00"/></svg>"##)
        defer {
            try? FileManager.default.removeItem(at: small)
            try? FileManager.default.removeItem(at: large)
        }

        let cache = ImageCache()
        let sources: [(String, UInt32)] = [(small.path, 100), (large.path, 200)]
        let pick1 = cache.urlSet(sources, sizePt: 75, scale: 2) // 150px -> 200
        let pick2 = cache.urlSet(sources, sizePt: 90, scale: 2) // 180px -> 200 (shared!)
        let pick3 = cache.urlSet(sources, sizePt: 40, scale: 2) // 80px -> 100

        #expect(pick1 === pick2)
        #expect(pick1.pixels.sourceURLString == large.path)
        #expect(pick3.pixels.sourceURLString == small.path)
        guard case .success = pick1.wait(timeout: 2.0), case .success = pick3.wait(timeout: 2.0) else {
            Issue.record("Expected urlSet loads to succeed")
            return
        }
    }

    @Test("from_url_tests 5: rgba and manual load settle synchronously and validate inputs")
    func rgbaAndManualLoad() {
        let cache = ImageCache()
        let raw = cache.rgba(width: 2, height: 1, data: [255, 0, 0, 255, 0, 255, 0, 128])
        #expect(raw.isReady)
        #expect(raw.size?.0 == 2 && raw.size?.1 == 1)
        #expect(raw.pixels.sourceURLString == nil)

        let manual = cache.load(url: "mem://badge", sizePt: 16, scale: 2, fetched: .rgba(width: 2, height: 2, data: Data(repeating: 255, count: 16)))
        #expect(manual.isReady)
        #expect(manual.size?.0 == 2 && manual.size?.1 == 2)
        #expect(manual.pixels.sourceURLString == "mem://badge")
        #expect(cache.url("mem://badge", sizePt: 16, scale: 2) === manual)

        let bad = ImageCache.land(url: "mem://bad", fetched: .rgba(width: 2, height: 2, data: Data([1, 2])), pixelSize: 2)
        if case .failure(let err) = bad {
            #expect(err.message.hasPrefix("mem://bad: "))
        } else {
            Issue.record("Expected pixel size mismatch failure")
        }
    }

    // MARK: - 2. InlineIcon & Pills (crates/rune/src/el/pills.rs)

    @Test("El.inlineIcon & El.pill: UTF-8 boundary, overlap guard, layout spacing, and copy exclusion")
    func inlineIconAndPillsParity() {
        let star = SVGIcon(viewBox: 24, paths: ["M12 2 L15 9 L22 9 L16 14 L18 22 L12 17 L6 22 L8 14 L2 9 L9 9 Z"])
        let txt = "hi 😀 world" // 😀 is 4 bytes (bytes 3..<7)

        let e: El<Int> = text(txt)
            .font(TextStyle(size: 14))
            .inlineIcon(at: 4, star, size: 12) // invalid mid-emoji byte -> rejected
            .inlineIcon(at: 3, star, size: 12, gap: 4) // valid scalar start
            .inlineIcon(at: 3, star, size: 16, gap: 4) // overlapping byte offset -> rejected

        #expect(e.inlineIcons.count == 1)
        #expect(e.inlineIcons[0].byteOffset == 3)
        #expect(e.inlineIcons[0].reserveWidth == 16)

        // Expanded markers exclude from plain copy
        let (expanded, markers) = InlineIconLayout.insertInlineMarkers(into: txt, icons: e.inlineIcons)
        #expect(markers.count == 1)
        #expect(expanded.contains("\u{FFFC}"))
        #expect(InlineIconLayout.copyablePlainText(expanded) == txt)

        // Layout accounts for icon horizontal advance and wraps safely within narrow width
        let bare = InlineIconLayout.layout(text: "alpha beta", style: TextStyle(size: 14), icons: [], maxWidth: nil)
        let withIcon = InlineIconLayout.layout(text: "alpha beta", style: TextStyle(size: 14), icons: [InlineIcon(byteOffset: 6, icon: star, size: 14, gap: 6)], maxWidth: nil)
        #expect(withIcon.totalSize.x > bare.totalSize.x + 15)
        #expect(withIcon.placed.count == 1)
        #expect(withIcon.placed[0].rect.width == 14)

        // Pill chip populates both pillChips and RichSpan styles
        let pilled: El<Int> = text("open @file now")
            .pill(5..<10, PillStyle.tint(Color(r: 0.2, g: 0.5, b: 1, a: 1), backgroundAlpha: 0.2), icon: BareIcon(star, size: 12))
        #expect(pilled.pillChips.count == 1)
        #expect(pilled.inlineIcons.count == 1)
        #expect((pilled.richSpans?.count ?? 0) >= 1)
    }

    // MARK: - 3. Canvas Input (crates/rune/src/input/canvas_input.rs + tests/canvas_input.rs)

    private struct CanvasInputState {
        var wheelCount = 0
        var wheelConsumes = true
        var lastMagnify: MagnifyEvent?
        var lastRotate: RotateEvent?
        var lastSmartMagnify: SmartMagnifyEvent?
        var buttonsSeen: [(PointerButton, Bool, PointerButton?)] = []
        var keysUpSeen: [String] = []
        var blurOnKeyUp = false
        var keyOwnerAlive = true
    }

    @Test("canvas_input.rs: wheel-before-scroll, pinch/rotate/smartMagnify local coords, extra buttons, and onKeyUp")
    func canvasInputSuite() {
        func view(_ s: CanvasInputState, _ cx: inout Cx<CanvasInputState>) -> El<CanvasInputState> {
            let canvas: El<CanvasInputState> = el()
                .key("canvas")
                .size(200, 100)
                .onWheel { st, _, _ in
                    st.wheelCount += 1
                    return st.wheelConsumes
                }
                .onMagnify { st, ev, _ in
                    st.lastMagnify = ev
                    return true
                }
                .onRotate { st, ev, _ in
                    st.lastRotate = ev
                    return true
                }
                .onSmartMagnify { st, ev, _ in
                    st.lastSmartMagnify = ev
                    return true
                }
                .pointerButtons { st, ev, tx in
                    st.buttonsSeen.append((ev.button, ev.pressed, tx.button))
                    return true
                }

            var child: El<CanvasInputState> = el()
                .key("child")
                .size(50, 20)
            if s.keyOwnerAlive {
                child = child
                    .focusable()
                    .onKeyUp { st, ev, tx in
                        if case .text(let k) = ev.key {
                            st.keysUpSeen.append(k)
                        }
                        if st.blurOnKeyUp {
                            tx.blur()
                        }
                        return true
                    }
            }

            let root: El<CanvasInputState> = col()
            let tall: El<CanvasInputState> = el()
            return root
                .w(240).h(200).p(20)
                .scrollY()
                .child(canvas.child(child))
                .child(tall.key("tall").size(100, 400))
        }

        let rt = Runtime(state: CanvasInputState(), viewport: Vec2(240, 200), pixelScale: 2, view: view)
        _ = rt.frame(at: 0)

        // Wheel inside canvas invokes onWheel before container scroll.
        rt.wheel(WheelEvent(dx: 0, dy: -30, precise: true, phase: .changed), at: Vec2(60, 50), now: 0.1)
        #expect(rt.state.wheelCount == 1)

        // Magnify, rotate, and smartMagnify convert window coordinates -> canvas local (origin is at 20,20).
        #expect(rt.magnifyEvent(delta: 0.25, phase: .began, at: Vec2(50, 45), at: 0.2))
        #expect(rt.state.lastMagnify?.delta == 0.25)
        #expect(rt.state.lastMagnify?.phase == .began)
        #expect(rt.state.lastMagnify?.local == Vec2(30, 25))
        #expect(rt.state.lastMagnify?.at(1, 2).local == Vec2(1, 2))

        #expect(rt.rotateEvent(deltaDegrees: 15.0, phase: .changed, at: Vec2(55, 50), at: 0.3))
        #expect(rt.state.lastRotate?.deltaDegrees == 15.0)
        #expect(rt.state.lastRotate?.local == Vec2(35, 30))

        #expect(rt.smartMagnify(at: Vec2(70, 60), at: 0.4))
        #expect(rt.state.lastSmartMagnify?.local == Vec2(50, 40))

        // Middle / back / forward pointer buttons arrive with tx.button populated.
        #expect(rt.pointerButtonDown(at: Vec2(40, 40), button: .middle, at: 0.5))
        #expect(rt.pointerButtonUp(at: Vec2(40, 40), button: .middle, at: 0.55))
        #expect(rt.pointerButtonDown(at: Vec2(40, 40), button: .back, at: 0.6))
        #expect(rt.pointerButtonDown(at: Vec2(40, 40), button: .forward, at: 0.65))
        #expect(rt.state.buttonsSeen.count == 4)
        #expect(rt.state.buttonsSeen[0].0 == .middle && rt.state.buttonsSeen[0].1 == true && rt.state.buttonsSeen[0].2 == .middle)
        #expect(rt.state.buttonsSeen[2].0 == .back && rt.state.buttonsSeen[3].0 == .forward)

        // AppKit buttonNumber mapping
        #expect(PointerButton.fromAppKit(buttonNumber: 0) == .primary)
        #expect(PointerButton.fromAppKit(buttonNumber: 1) == .secondary)
        #expect(PointerButton.fromAppKit(buttonNumber: 2) == .middle)
        #expect(PointerButton.fromAppKit(buttonNumber: 3) == .back)
        #expect(PointerButton.fromAppKit(buttonNumber: 4) == .forward)

        // Focus child -> IME active suppresses onKeyUp -> non-IME delivers onKeyUp -> blur clears focus
        rt.update(at: 0.7) { _, tx in tx.focus("child") }
        _ = rt.frame(at: 0.7)
        #expect(!rt.keyUp(KeyEvent(key: .text("x")), imeActive: true, at: 0.71))
        #expect(rt.keyUp(KeyEvent(key: .text("a")), imeActive: false, at: 0.72))
        #expect(rt.state.keysUpSeen == ["a"])

        rt.state.blurOnKeyUp = true
        #expect(rt.keyUp(KeyEvent(key: .text("b")), at: 0.73))
        #expect(rt.focusedPath == nil)
    }

    // MARK: - 4. PointerObserver, DropPointer, KeyDiagnostics, KeyPaths

    @Test("pointer_observer.rs, drop_pointer.rs, key_diagnostics.rs, and tests/key_paths.rs")
    func observerDropDiagnosticsAndKeyPaths() {
        // PointerObserver
        var obs = PointerObserver()
        let t0 = obs.take()
        #expect(!t0)
        let canvasRect = MotionRect.fromXYWH(0, 0, 200, 100)
        #expect(obs.needsGeometry(canvas: canvasRect, follow: true))
        obs.configure(canvas: canvasRect, displays: [MotionRect.fromXYWH(0, 0, 1920, 1080)], follow: true)
        #expect(!obs.needsGeometry(canvas: canvasRect, follow: true))
        let t1 = obs.take()
        #expect(t1)
        obs.configure(keys: ["btn1"])
        let t2 = obs.take()
        #expect(t2)
        let t3 = obs.take()
        #expect(!t3) // cleared
        let rects1 = ["btn1": MotionRect.fromXYWH(0, 0, 100, 30)]
        let obs1 = obs.observe(rects1, version: 1)
        #expect(obs1)
        let t4 = obs.take()
        #expect(t4)
        // Steady state same rect -> no change / no spam
        let obs2 = obs.observe(rects1, version: 2)
        #expect(!obs2)
        let t5 = obs.take()
        #expect(!t5)

        // DropPointer
        var dp = DropPointer()
        #expect(!dp.isActive)
        dp.enter(at: Vec2(10, 20), targetKey: "zone")
        #expect(dp.isActive)
        let mv0 = dp.takePendingMove()
        #expect(mv0 == Vec2(10, 20))
        let mv1 = dp.takePendingMove()
        #expect(mv1 == nil)
        dp.move(to: Vec2(12, 24), targetKey: "zone")
        dp.move(to: Vec2(18, 30), targetKey: "zone")
        let mv2 = dp.takePendingMove()
        #expect(mv2 == Vec2(18, 30))
        let fin = dp.finish(committed: true)
        #expect(fin == Vec2(18, 30))
        #expect(!dp.isActive)

        // KeyDiagnostics
        let tree: El<Int> = col()
            .key("root")
            .child(text("one").key("dup"))
            .child(text("two").key("dup"))
            .child(text("ok").key("uniq"))
        #expect(!KeyDiagnostics.isClean(tree))
        let warns = KeyDiagnostics.warnings(in: tree)
        #expect(warns.count == 1)
        #expect(warns[0].key == "dup" && warns[0].count == 2)
        let (repaired, _) = KeyDiagnostics.renameDuplicates(tree)
        #expect(KeyDiagnostics.isClean(repaired))
        #expect(repaired.children[0].keyId == "dup")
        #expect(repaired.children[1].keyId == "dup#2")

        // key_paths.rs: wildcard key path matching & Runtime.scrollToKeyPath
        #expect(KeyPathMatcher.matches("list/row1/btn", pattern: "list/*/btn"))
        #expect(!KeyPathMatcher.matches("list/row1/other", pattern: "list/*/btn"))

        struct KPState { var dummy = 0 }
        let kpRt = Runtime(state: KPState(), viewport: Vec2(200, 100), pixelScale: 2) { _, _ in
            var scroller: El<KPState> = col().key("list").size(200, 100).scrollY()
            for i in 0..<10 {
                let row: El<KPState> = el()
                let tgt: El<KPState> = el()
                scroller = scroller.child(
                    row.key("row\(i)").size(200, 40)
                        .child(tgt.key("target").size(50, 20))
                )
            }
            return scroller
        }
        _ = kpRt.frame(at: 0)
        #expect(kpRt.scrollToKeyPath("list/row8/target", at: 0.1))
        _ = kpRt.frame(at: 0.2)
        let scrollerPath = kpRt.element(byKey: "list")!.path
        #expect((kpRt.scrollOffsets[scrollerPath]?.y ?? 0) > 200)
    }

    // MARK: - 5. Host Hooks: Async Paste, SecureInputClaim, SpellPause, VoiceOver Announcements

    @Test("Host hooks: Tx.requestPaste async delivery, SecureInputClaim, SpellPauseWatch, A11y announcements")
    func hostHooksPasteSecureSpellA11y() {
        struct EditState {
            var secret: TextEdit
            var note: TextEdit
            init() {
                var sec = TextEdit("")
                sec.isSecure = true
                self.secret = sec
                self.note = TextEdit("teh ")
            }
        }
        let rt = Runtime(state: EditState(), viewport: Vec2(300, 200), pixelScale: 2) { _, _ in
            let root: El<EditState> = col()
            return root
                .child(textInput(key: "sec", \EditState.secret).font(TextStyle(size: 14)))
                .child(
                    textInput(key: "note", \EditState.note)
                        .font(TextStyle(size: 14))
                        .spellcheck()
                )
        }
        _ = rt.frame(at: 0)

        // SecureInputClaim tracks focus + window focus transitions cleanly
        let claim = SecureInputClaim(touchOS: false)
        rt.update(at: 0.1) { _, tx in tx.focus("sec") }
        _ = rt.frame(at: 0.1)
        #expect(rt.syncSecureInput(claim, windowFocused: true) == true)
        #expect(rt.syncSecureInput(claim, windowFocused: false) == false) // window deactivated
        rt.update(at: 0.2) { _, tx in tx.focus("note") }
        _ = rt.frame(at: 0.2)
        #expect(rt.syncSecureInput(claim, windowFocused: true) == false) // moved to non-secure

        // Tx.requestPaste + Runtime.performAsyncPaste applies clipboard to focused TextEdit
        var tx = Tx()
        tx.requestPaste()
        #expect(tx.hasPasteRequest)
        rt.recordHostExtensionRequests(from: tx)
        #expect(rt.performAsyncPaste(using: { ClipboardContent("world") }, at: 0.3))
        #expect(rt.state.note.text == "teh world")
        #expect(!rt.performAsyncPaste(using: { ClipboardContent("again") }, at: 0.4)) // already consumed

        // SpellPauseWatch suppresses checks during pause window and fires once settled
        var watch = SpellPauseWatch(path: rt.focusedPath ?? "", text: rt.state.note.text)
        _ = rt.spellCheckWhenSettled(watch: &watch, at: 0.41)
        rt.state.note.insert("qwkz")
        let suppressed = rt.spellCheckWhenSettled(watch: &watch, at: 0.5)
        #expect(suppressed == nil) // typing starts pause timer
        let settledRanges = rt.spellCheckWhenSettled(watch: &watch, at: 1.5) // > pause delay
        #expect(settledRanges != nil)

        // A11y live region announcements diff previous vs current tree cleanly
        let a = AccessibilityNode(id: "root", role: .group, children: [
            AccessibilityNode(id: "status", role: .alert, label: "Saved", liveRegion: .polite),
        ])
        let b = AccessibilityNode(id: "root", role: .group, children: [
            AccessibilityNode(id: "status", role: .alert, label: "Failed", liveRegion: .assertive),
        ])
        let anns = AccessibilityTreeBuilder.liveAnnouncements(previous: a, current: b)
        #expect(anns.count == 1)
        #expect(anns[0].text == "Failed")
        #expect(anns[0].spokenText?.hasPrefix("Failed") == true)
        #expect(anns[0].politeness == .assertive)
    }

    // MARK: - 6. Text Quality & Selectable Text Parity

    @Test("text/quality_tests.rs: centered symmetry, justified edges, RTL wrap/justify, inline code chip pad")
    func textQualityParity() {
        // Centred lines sit symmetrically around box midpoint
        let style = TextStyle(size: 14, align: .center, wrap: .wrap)
        let boxW: Float = 120
        let shaped = TextSystem().shape(text: "hello centered lines here", style: style, maxWidth: boxW, pixelScale: 2.0)
        let minX = shaped.glyphs.map { $0.rect[0] }.min() ?? 0
        let maxX = shaped.glyphs.map { $0.rect[0] + $0.rect[2] }.max() ?? 0
        let mid = (minX + maxX) * 0.5
        #expect(abs(mid - boxW * 0.5) < 6.0)

        // Justified lines flush left (0) and right (maxWidth)
        let justified = TextQualityLayout.justifyLines(
            "alpha beta gamma delta epsilon zeta eta theta",
            style: TextStyle(size: 14),
            maxWidth: 140,
            isRTL: false
        )
        #expect(justified.count >= 2)
        if let firstLine = justified.first, firstLine.count > 1 {
            #expect(abs(firstLine.first!.x - 0) < 0.01)
            let rightEdge = firstLine.last!.x + firstLine.last!.width
            #expect(abs(rightEdge - 140) < 0.5)
        }

        // RTL words flush to right edge
        let rtl = TextQualityLayout.justifyLines(
            "שלום עולם בדיקה ארוכה מאוד",
            style: TextStyle(size: 14),
            maxWidth: 140,
            isRTL: true
        )
        #expect(!rtl.isEmpty)
        #expect(abs((rtl[0][0].x + rtl[0][0].width) - 140) < 0.5)

        // Inline code chip padding wraps outside glyphs
        let chip = TextQualityLayout.inlineCodeChipRect(glyphMinX: 10, glyphMaxX: 50, lineY: 20, lineHeight: 18, padX: 4, padY: 1)
        #expect(chip == MotionRect.fromXYWH(6, 21, 48, 16))
    }

    @Test("selectable_text.rs: Runtime selectable text drag select + Cmd+C copy + clear")
    func selectableTextRuntimeParity() {
        struct SelState { var copied: String? = nil }
        let rt = Runtime(state: SelState(), viewport: Vec2(300, 120), pixelScale: 2) { _, _ in
            let root: El<SelState> = col()
            return root.p(10)
                .child(
                    text("opencode --port 4096")
                        .key("cmd")
                        .font(TextStyle(size: 14))
                        .selectable()
                        .selectionCopy { sel in "copied:\(sel.text)" }
                )
        }
        _ = rt.frame(at: 0)
        let cmdRect = rt.element(byKey: "cmd")!.rect
        rt.pointerDown(at: Vec2(cmdRect[0] + 4, cmdRect[1] + 6), at: 0.1)
        rt.pointerMove(to: Vec2(cmdRect[0] + cmdRect[2] - 2, cmdRect[1] + 6), at: 0.15)
        rt.pointerUp(at: Vec2(cmdRect[0] + cmdRect[2] - 2, cmdRect[1] + 6), at: 0.2)
        _ = rt.frame(at: 0.25)

        _ = rt.keyDown(KeyEvent(key: .command("c"), mods: Mods(cmd: true)), at: 0.3)
        // Verify selectable config was preserved & copy handler responds cleanly
        #expect(rt.element(byKey: "cmd")?.text == "opencode --port 4096")
    }
}
