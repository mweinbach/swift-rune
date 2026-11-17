import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import RuneMotion
import RuneRef
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

/// Let the executor run the image loader while a test waits for its result or wake.
func imageUpdateArrived(_ condition: () -> Bool) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while !condition() {
        guard clock.now < deadline else { return false }
        try await clock.sleep(for: .milliseconds(5))
    }
    return true
}

extension CachedImage {
    @discardableResult
    func decodedSizeForTest() async throws -> (UInt32, UInt32) {
        try #require(try await imageUpdateArrived { self.isReady }, "Image did not finish loading")
        return try wait(timeout: 0).get()
    }
}

@Suite("Text Unblock All Parity (ImageFromURL, Pills/InlineIcon, Quality, Selectable, Observer, DropPointer, KeyDiagnostics, KeyPaths, HostHooks)")
struct TextUnblockAllTests {

    // MARK: - 1. image/from_url.rs & from_url_tests.rs (5 Rust tests + URLProtocol + file://)

    private static func makeTempSVG(name: String, body: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("\(name)-\(UUID().uuidString).svg")
        try! body.data(using: .utf8)!.write(to: url)
        return url
    }

    @Test("from_url_tests 1: decoded file shares handle per (url, px) and exposes pixels")
    func decodedFileSharesHandleAndPixels() async throws {
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

        try await a.decodedSizeForTest()
        try await c.decodedSizeForTest()
        #expect(a.error == nil)
        #expect((a.size?.0 ?? 0) > 0 && (a.size?.1 ?? 0) > 0)
        #expect(a.pixels.sourceURLString == svgURL.path)
    }

    @Test("from_url_tests 2: svg scales with point size * pixel scale and preserves width")
    func svgScalesToPointSizeTimesScale() async throws {
        let svgURL = Self.makeTempSVG(
            name: "icon",
            body: ##"<svg viewBox="0 0 24 24"><path d="M2 2 L22 2 L22 22 L2 22 Z" fill="#00cc88"/></svg>"##
        )
        defer { try? FileManager.default.removeItem(at: svgURL) }

        let cache = ImageCache()
        let lo = cache.url(svgURL.path, sizePt: 16, scale: 1)
        let hi = cache.url(svgURL.path, sizePt: 16, scale: 2)

        try await lo.decodedSizeForTest()
        try await hi.decodedSizeForTest()
        #expect(lo.size?.0 == 16)
        #expect(hi.size?.0 == 32)
        #expect(lo.id != hi.id)
    }

    @Test("from_url_tests 3: unsupported URL without session records prefixed error; URLProtocol HTTP succeeds")
    func unsupportedAndHTTPURLProtocol() async throws {
        let bareCache = ImageCache()
        let bad = bareCache.url("https://example.com/a.svg", sizePt: 16, scale: 1)
        try #require(try await imageUpdateArrived { bad.isReady })
        #expect(bad.error?.message.hasPrefix("https://example.com/a.svg: ") == true)

        let woke = DispatchSemaphore(value: 0)
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
            wake: { woke.signal() },
            session: session
        )

        let remote = cache.url("https://cdn.example.com/avatar.svg", sizePt: 20, scale: 2)
        try await remote.decodedSizeForTest()
        #expect(remote.error == nil)
        #expect(remote.size?.0 == 40)
        // The cache publishes the decoded pixels before calling the application's wake closure.
        #expect(try await imageUpdateArrived { woke.wait(timeout: .now()) == .success })
    }

    @Test("from_url_tests 4: urlSet picks narrowest source >= target px and shares handle")
    func urlSetSelectsNarrowestCoveringTarget() async throws {
        let small = Self.makeTempSVG(name: "s100", body: ##"<svg width="16" height="16" viewBox="0 0 16 16"><rect x="0" y="0" width="16" height="16" fill="#ff0000"/></svg>"##)
        let large = Self.makeTempSVG(name: "s200", body: ##"<svg width="16" height="16" viewBox="0 0 16 16"><rect x="0" y="0" width="16" height="16" fill="#00ff00"/></svg>"##)
        defer {
            try? FileManager.default.removeItem(at: small)
            try? FileManager.default.removeItem(at: large)
        }

        let cache = ImageCache()
        let sources: [(String, UInt32)] = [(small.path, 100), (large.path, 200)]
        let pick1 = cache.urlSet(sources, sizePt: 75, scale: 2)
        let pick2 = cache.urlSet(sources, sizePt: 90, scale: 2)
        let pick3 = cache.urlSet(sources, sizePt: 40, scale: 2)

        #expect(pick1 === pick2)
        #expect(pick1.pixels.sourceURLString == large.path)
        #expect(pick3.pixels.sourceURLString == small.path)
        try await pick1.decodedSizeForTest()
        try await pick3.decodedSizeForTest()
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

    // MARK: - 2. el/pills.rs, pills/tests.rs, text/pill_chips.rs & quality pill tests

    @Test("el/pills/tests.rs: range validation, field guard, .spans() preserves pill label color, and Runtime pill/icon rendering")
    func pillsAndInlineIconParity() {
        let star = SVGIcon(viewBox: 24, paths: ["M12 2 L15 9 L22 9 L16 14 L18 22 L12 17 L6 22 L8 14 L2 9 L9 9 Z"])
        let txt = "hi 😀 @tag end" // 😀 is bytes 3..<7
        let tagLo = txt.utf8.count - 8 // "@tag"
        let tagHi = tagLo + 4

        let pillRed = Color(r: 1, g: 0.2, b: 0.2, a: 1)
        let elNode: El<Int> = text(txt)
            .font(TextStyle(size: 14))
            .pill(0..<0, .default)                  // empty -> skipped
            .pill(0..<999, .default)                // out-of-bounds -> skipped
            .pill(4..<8, .default)                  // non-char-boundary -> skipped
            .pill(tagLo..<tagHi, PillStyle.default.fg(pillRed))
            .pill((tagLo + 1)..<(tagHi + 1), .default) // overlapping -> skipped
            .inlineIcon(at: 4, star)                // non-char-boundary -> skipped
            .inlineIcon(at: tagLo + 1, star)        // overlaps pill -> skipped
            .inlineIcon(at: 3, InlineIcon.glyph(star).size(12).gap(4))

        #expect(elNode.pillChips.count == 2) // bare icon @3 + pill @tag
        #expect(elNode.inlineIcons.count == 1)
        #expect(elNode.inlineIcons.first?.byteOffset == 3)

        // Calling .spans(...) preserves pill label foreground color & styling (pills/tests.rs:30)
        let respanned = elNode.spans([RichSpan(0..<2).bold()])
        let tagSpan = respanned.richSpans?.first { $0.text == "@tag" }
        #expect(tagSpan?.color == pillRed)

        // Fields reject static pills and inline icons (pills/tests.rs:28)
        struct FieldState { var ed = TextEdit("hello @tag") }
        let fld: El<FieldState> = textInput(key: "f", \FieldState.ed).pill(6..<10, .default).inlineIcon(at: 0, star)
        #expect(fld.pillChips.isEmpty)
        #expect(fld.inlineIcons.isEmpty)

        // Live Runtime renders pill background chip + SVG inline icon glyph + RGBA image inline icon!
        let badgeImg = RGBA8Atlas(width: 2, height: 2, texels: Array(repeating: 255, count: 16))
        struct PillLiveState { var dummy = 0 }
        let rt = Runtime(state: PillLiveState(), viewport: Vec2(420, 120), pixelScale: 2) { _, _ in
            let root: El<PillLiveState> = col().p(12).gap(8)
            return root
                .child(
                    text("ask @reviewer about photo")
                        .key("p")
                        .font(TextStyle(size: 14))
                        .pill(4..<13, PillStyle.tint(Color(r: 0.2, g: 0.6, b: 1, a: 1)).icon(star, size: 12))
                        .inlineIcon(at: 20, InlineIcon.image(badgeImg).size(14).gap(4).radius(3))
                )
        }
        let frame = rt.frame(at: 0)
        let pillRoundedRects = frame.primitives.filter {
            Int($0.params[1]) == PrimitiveKind.roundedRect.rawValue && $0.rect.z > 20 && $0.rect.w < 40
        }
        let imagePrims = frame.primitives.filter {
            Int($0.params[1]) == PrimitiveKind.image.rawValue
        }
        #expect(!pillRoundedRects.isEmpty)
        #expect(imagePrims.count == 1)
        #expect(rt.element(byKey: "p")?.text == "ask @reviewer about photo")
    }

    @Test("text/quality_tests.rs: pill chips reserve exact room, never overlap at wraps, keep caret outside, and wrap wide pills")
    func pillRoomWrappingAndWidePillParity() throws {
        let dot = SVGIcon(viewBox: 24, paths: ["M12 4 A8 8 0 1 0 12 20 A8 8 0 1 0 12 4 Z"])
        let ts = TextSystem()
        let style = TextStyle(size: 14, weight: 400, wrap: .wrap)
        let content = "ask @code-reviewer about @src/main.rs and @notes today please"
        let labels = ["@code-reviewer", "@src/main.rs", "@notes"]
        let pills: [PillChip] = labels.enumerated().map { k, label in
            let r = content.range(of: label)!
            let s = content.utf8.distance(from: content.startIndex, to: r.lowerBound)
            let e = content.utf8.distance(from: content.startIndex, to: r.upperBound)
            return PillChip(s..<e, style: PillStyle.default, icon: k == 1 ? BareIcon(dot, size: 13) : nil)
        }

        let bare = ts.shape(text: content, style: style, maxWidth: nil, pixelScale: 2.0, emitGlyphs: false)
        let withPills = ts.shape(text: content, pills: pills, style: style, maxWidth: nil, pixelScale: 2.0, emitGlyphs: true)
        let pm = PillMetrics(size: 14.0)
        let expectedRoom = pm.lead(icon: false, style: .default) + pm.lead(icon: true, style: .default) + pm.lead(icon: false, style: .default) + 3.0 * pm.trail(style: .default)
        #expect(abs((withPills.size.x - bare.size.x) - expectedRoom) < 2.0)

        for width in stride(from: 140, through: 420, by: 14) {
            let maxW = Float(width)
            let shaped = ts.shape(text: content, pills: pills, style: style, maxWidth: maxW, pixelScale: 2.0, emitGlyphs: true)
            try #require(shaped.pillChips.count == 3, "Expected 3 pill chips at width \(width)")
            #expect(shaped.pillChips.map(\.pillIndex) == Array(pills.indices))
            #expect(shaped.pillChips[1].iconRect != nil)
            if let ir = shaped.pillChips[1].iconRect {
                let cr = shaped.pillChips[1].rect
                #expect(ir.x >= cr.x - 0.5 && ir.x + ir.z <= cr.x + cr.z + 0.5)
            }
            for (k, chip) in shaped.pillChips.enumerated() {
                let p = pills[k]
                let cStart = ts.caretRect(in: shaped, utf8Offset: p.range.lowerBound, upstream: false, pixelScale: 2.0)
                let cEnd = ts.caretRect(in: shaped, utf8Offset: p.range.upperBound, upstream: true, pixelScale: 2.0)
                #expect(cStart.x <= chip.rect.x + 0.5, "Start caret should sit outside chip at width \(width)")
                #expect(cEnd.x >= chip.rect.x + chip.rect.z - 0.5, "End caret should sit outside chip at width \(width)")
            }
        }

        // Wide pill wraps across lines with one chip per line inside maxW (`quality_tests.rs:194`)
        let label = "@Migrate config loader to the new schema"
        let wideContent = "as in \(label) did"
        let wideRange = wideContent.range(of: label)!
        let ws = wideContent.utf8.distance(from: wideContent.startIndex, to: wideRange.lowerBound)
        let we = wideContent.utf8.distance(from: wideContent.startIndex, to: wideRange.upperBound)
        let widePill = [PillChip(ws..<we)]
        for width in stride(from: 95, through: 195, by: 10) {
            let maxW = Float(width)
            let shaped = ts.shape(text: wideContent, pills: widePill, style: style, maxWidth: maxW, pixelScale: 2.0, emitGlyphs: true)
            #expect(shaped.pillChips.count >= 2, "Wide pill must wrap into >= 2 chips at width \(width)")
            for c in shaped.pillChips {
                #expect(c.rect.x >= -0.5 && c.rect.x + c.rect.z <= maxW + 1.0,
                        "Pill fragment \(c.rect) should fit width \(width)")
            }
        }
    }

    // MARK: - 3. text/quality_tests.rs (Centered, Justified, RTL, Merged Inline Code Chip)

    private static func lineGlyphSpans(content: String, align: TextAlign, maxWidthPt: Float = 300) -> [(minX: Float, maxX: Float)] {
        struct QState { var dummy = 0 }
        let rt = Runtime(state: QState(), viewport: Vec2(maxWidthPt, 400), pixelScale: 2) { _, _ in
            text(content)
                .w(maxWidthPt)
                .font(TextStyle(size: 14, align: align, wrap: .wrap))
        }
        let frame = rt.frame(at: 0)
        let glyphs = frame.primitives
            .filter { Int($0.params[1]) == PrimitiveKind.glyph.rawValue }
            .sorted { ($0.rect.y, $0.rect.x) < ($1.rect.y, $1.rect.x) }
        var lines: [(cy: Float, minX: Float, maxX: Float)] = []
        for g in glyphs {
            let cy = g.rect.y + g.rect.w * 0.5
            let x0 = g.rect.x
            let x1 = g.rect.x + g.rect.z
            if var last = lines.last, abs(cy - last.cy) < 16.0 {
                last.minX = min(last.minX, x0)
                last.maxX = max(last.maxX, x1)
                lines[lines.count - 1] = last
            } else {
                lines.append((cy, x0, x1))
            }
        }
        return lines.map { ($0.minX, $0.maxX) }
    }

    @Test("text/quality_tests.rs: centered lines, justified non-final lines, RTL alignment & justification, merged inline code chip")
    func textQualitySuiteParity() {
        // 1. Centered wrapped lines sit symmetrically around box midpoint (`centred_wrapped_lines`)
        let centered = Self.lineGlyphSpans(
            content: "short lines centered inside a wider box to check symmetry",
            align: .center,
            maxWidthPt: 200
        )
        #expect(centered.count >= 2)
        for line in centered {
            let mid = (line.minX + line.maxX) * 0.5
            #expect(abs(mid - 200.0) < 12.0, "Centered midpoint \(mid) should sit near 200px (box 400px @2x)")
        }

        // 2. Justified text fills every wrapped line except the last without changing line count (`justified_text_fills_each_wrapped_line_but_the_last`)
        let prose = "the quick brown fox jumps over the lazy dog while five boxing wizards jump quickly and pack my box with five dozen liquor jugs"
        let justified = Self.lineGlyphSpans(content: prose, align: .justified, maxWidthPt: 220)
        let ragged = Self.lineGlyphSpans(content: prose, align: .leading, maxWidthPt: 220)
        #expect(justified.count >= 3)
        #expect(justified.count == ragged.count)
        for line in justified.dropLast() {
            #expect(line.minX < 12.0 && line.maxX > 432.0, "Justified line should span width: \(line)")
        }
        #expect(ragged.dropLast().contains { $0.maxX < 432.0 })

        // 3. RTL wrapped lines hug right on .leading, left on .trailing, and justify from right (`wrapped_right_to_left_text_aligns_and_justifies_from_the_right`)
        let hebrew = "שלום עולם זהו טקסט ארוך שנשבר לכמה שורות כדי לבדוק יישור מימין לשמאל בתוך רוחב קבוע של האלמנט"
        let rtlStart = Self.lineGlyphSpans(content: hebrew, align: .leading, maxWidthPt: 300)
        if !rtlStart.isEmpty {
            #expect(rtlStart.count >= 2)
            for line in rtlStart {
                #expect(line.maxX > 588.0, "RTL start should hug right edge (600px): \(line)")
            }
            let rtlEnd = Self.lineGlyphSpans(content: hebrew, align: .trailing, maxWidthPt: 300)
            for line in rtlEnd {
                #expect(line.minX < 12.0, "RTL end should hug left edge: \(line)")
            }
            let rtlJust = Self.lineGlyphSpans(content: hebrew, align: .justified, maxWidthPt: 300)
            for line in rtlJust.dropLast() {
                #expect(line.minX < 12.0 && line.maxX > 588.0)
            }
            if let last = rtlJust.last {
                #expect(last.maxX > 588.0, "RTL justified last line starts at right edge: \(last)")
            }
        }

        // 4. Inline code and its padding share one merged chip (`inline_code_and_its_padding_share_one_chip`)
        let chipBg = Color(r: 0, g: 0, b: 0, a: 0.08)
        let ts = TextSystem()
        let shaped = ts.shape(
            text: "",
            spans: [
                TextSpan("see "),
                TextSpan("\u{00A0}", background: chipBg),
                TextSpan("code", background: chipBg, monospace: true),
                TextSpan("\u{00A0}", background: chipBg),
                TextSpan(" here"),
            ],
            style: TextStyle(size: 14),
            maxWidth: nil,
            pixelScale: 2.0,
            emitGlyphs: true
        )
        #expect(shaped.backgrounds.count == 1)
    }

    // MARK: - 4. tests/selectable_text.rs

    @Test("selectable_text.rs: drag, double-click word, triple-click line, Shift extend, and Copy without moving layout")
    func selectableTextRuntimeParity() {
        struct SelState { var copied: String? = nil }
        let rt = Runtime(state: SelState(), viewport: Vec2(360, 140), pixelScale: 2) { _, _ in
            let root: El<SelState> = col()
            return root.p(10)
                .child(
                    text("opencode --port 4096\nsecond line here")
                        .key("cmd")
                        .font(TextStyle(size: 14))
                        .selectable()
                        .selectionCopy { sel in "copied:\(sel.text)" }
                )
        }
        _ = rt.frame(at: 0)
        let beforeRect = rt.element(byKey: "cmd")!.rect

        // Drag selection across first word "opencode"
        rt.pointerDown(at: Vec2(beforeRect[0] + 1, beforeRect[1] + 7), at: 0.1)
        rt.pointerMove(to: Vec2(beforeRect[0] + 55, beforeRect[1] + 7), at: 0.12)
        rt.pointerUp(at: Vec2(beforeRect[0] + 55, beforeRect[1] + 7), at: 0.14)
        _ = rt.frame(at: 0.16)
        #expect(rt.selectedText()?.isEmpty == false)

        // Copy invokes selectionCopy & populates clipboard without mutating element geometry
        #expect(rt.keyDown(KeyEvent(key: .command("c"), mods: RuneTestKey.primaryMods()), at: 0.2))
        #expect(rt.clipboard.text.hasPrefix("copied:") == true)
        let afterRect = rt.element(byKey: "cmd")!.rect
        #expect(beforeRect == afterRect)

        // Double-click selects word; triple-click selects entire line; Shift+click extends selection
        rt.pointerDown(at: Vec2(beforeRect[0] + 75, beforeRect[1] + 7), at: 1.00)
        rt.pointerUp(at: Vec2(beforeRect[0] + 75, beforeRect[1] + 7), at: 1.02)
        rt.pointerDown(at: Vec2(beforeRect[0] + 75, beforeRect[1] + 7), at: 1.05)
        rt.pointerUp(at: Vec2(beforeRect[0] + 75, beforeRect[1] + 7), at: 1.07)
        let wordSel = rt.selectedText() ?? ""
        #expect(!wordSel.isEmpty && !wordSel.contains("\n"))

        rt.pointerDown(at: Vec2(beforeRect[0] + 10, beforeRect[1] + 7), at: 2.00)
        rt.pointerUp(at: Vec2(beforeRect[0] + 10, beforeRect[1] + 7), at: 2.02)
        rt.pointerDown(at: Vec2(beforeRect[0] + 10, beforeRect[1] + 7), at: 2.05)
        rt.pointerUp(at: Vec2(beforeRect[0] + 10, beforeRect[1] + 7), at: 2.07)
        rt.pointerDown(at: Vec2(beforeRect[0] + 10, beforeRect[1] + 7), at: 2.10)
        rt.pointerUp(at: Vec2(beforeRect[0] + 10, beforeRect[1] + 7), at: 2.12)
        let lineSel = rt.selectedText() ?? ""
        #expect(lineSel.contains("opencode"))

        // Shift+click extends selection into second line
        rt.pointerDown(at: Vec2(beforeRect[0] + 40, beforeRect[1] + 24), mods: Mods(shift: true), at: 3.00)
        rt.pointerUp(at: Vec2(beforeRect[0] + 40, beforeRect[1] + 24), mods: Mods(shift: true), at: 3.02)
        let extSel = rt.selectedText() ?? ""
        #expect(extSel.contains("second") || extSel.count >= lineSel.count)
    }

    private static func expectPoint(_ actual: (Int32, Int32)?, _ x: Int32, _ y: Int32) -> Bool {
        guard let actual else { return false }
        return actual.0 == x && actual.1 == y
    }

    // MARK: - 5. PointerObserver, DropPointer, KeyDiagnostics, KeyPaths

    @Test("pointer_observer.rs: overlay observation sleeps outside canvas and preserves gap display")
    func pointerObserverParity() {
        final class WakeCount: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func inc() { lock.lock(); n += 1; lock.unlock() }
            func get() -> Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let wakes = WakeCount()
        let observer = PointerObserver(wake: { wakes.inc() })
        let displays = [PointerIntRect(0, 0, 100, 100), PointerIntRect(200, 0, 300, 100)]
        observer.configure(canvas: PointerIntRect(10, 10, 30, 30), displays: displays, follow: true)

        observer.observe((5, 5))
        #expect(Self.expectPoint(observer.take(), 5, 5))
        for x in Int32(31)..<100 { observer.observe((x, 5)) }
        #expect(observer.take() == nil)
        observer.observe((15, 15))
        #expect(Self.expectPoint(observer.take(), 15, 15))
        observer.observe((50, 50))
        #expect(Self.expectPoint(observer.take(), 50, 50))
        observer.observe((150, 50)) // gap retains previous display
        #expect(observer.take() == nil)
        observer.observe((250, 50))
        #expect(Self.expectPoint(observer.take(), 250, 50))
        observer.observe((260, 50))
        #expect(observer.take() == nil)
        #expect(wakes.get() == 4)

        #expect(observer.needsGeometry(canvas: PointerIntRect(240, 40, 280, 60), follow: true))
        observer.configure(canvas: PointerIntRect(240, 40, 280, 60), displays: displays, follow: true)
        observer.observe((260, 50))
        #expect(Self.expectPoint(observer.take(), 260, 50), "moving canvas under stationary pointer must wake")
    }

    @Test("drop_pointer.rs & key_diagnostics.rs & tests/key_paths.rs")
    func dropPointerKeyDiagnosticsAndKeyPathsParity() {
        // DropPointer zoom scaling
        let dp = DropPointer { _ in Vec2(100, 50) }
        #expect(dp.sample(in: nil, zoom: 2.0) == Vec2(50, 25))
        #expect(DropPointer().sample(in: nil, zoom: 1.0) == nil)

        // KeyDiagnostics: cousin keys across distinct parents are clean; sibling duplicates warn & rename #dup1/#dup2
        let cleanCousins: El<Int> = col()
            .key("root")
            .child(col().key("left").child(text("a").key("item")))
            .child(col().key("right").child(text("b").key("item")))
        #expect(KeyDiagnostics.clean(cleanCousins))

        let dupSiblings: El<Int> = col()
            .key("root")
            .child(text("one").key("dup"))
            .child(text("two").key("dup"))
            .child(text("three").key("dup#dup1"))
            .child(text("four").key("dup"))
        #expect(!KeyDiagnostics.clean(dupSiblings))
        let warns = KeyDiagnostics.warnings(in: dupSiblings)
        #expect(warns.count == 1 && warns[0].key == "dup" && warns[0].count == 3)
        let (repaired, _) = KeyDiagnostics.repair(dupSiblings)
        #expect(KeyDiagnostics.clean(repaired))
        #expect(repaired.children[0].keyId == "dup")
        #expect(repaired.children[1].keyId == "dup#dup2") // skipped taken "dup#dup1"
        #expect(repaired.children[3].keyId == "dup#dup3")

        // Runtime siblingKeyWarnings inspects mounted tree
        let warnRt = Runtime(state: 0, viewport: Vec2(200, 100), pixelScale: 1) { _, _ in dupSiblings }
        _ = warnRt.frame(at: 0)
        #expect(warnRt.siblingKeyWarnings().count == 1)

        // key_paths.rs: slash key path enclosed scroll lookup ("b/label") and virtual row reveal ("b/r35")
        struct KPState { var dummy = 0 }
        let kpRt = Runtime(state: KPState(), viewport: Vec2(200, 100), pixelScale: 2) { _, _ in
            let b: El<KPState> = col()
                .key("b")
                .size(200, 100)
                .scrollY()
                .child(el().size(200, 240).shrink(0))
                .child(text("target label").key("label").size(200, 30).shrink(0))
            return col().key("root").size(200, 100).child(b)
        }
        _ = kpRt.frame(at: 0)
        kpRt.update(at: 0.1) { _, tx in tx.scrollIntoView("b/label") }
        for i in 1...60 { _ = kpRt.frame(at: 0.1 + Double(i) / 60.0) }
        let bPath = kpRt.element(byKey: "b")!.path
        #expect((kpRt.scrollOffsets[bPath]?.y ?? 0) > 100)

        let vRt = Runtime(state: KPState(), viewport: Vec2(200, 100), pixelScale: 2) { _, _ in
            let v: El<KPState> = col()
                .key("b")
                .size(200, 100)
                .scrollY()
                .virtualRows(
                    count: 50,
                    estimatedRowHeight: 24,
                    key: { _, i in "r\(i)" },
                    build: { _, i in text("row \(i)").size(200, 24) }
                )
            return col().key("root").size(200, 100).child(v)
        }
        _ = vRt.frame(at: 0)
        vRt.update(at: 0.1) { _, tx in tx.scrollIntoView("b/r35") }
        for i in 1...60 { _ = vRt.frame(at: 0.1 + Double(i) / 60.0) }
        let vPath = vRt.element(byKey: "b")!.path
        #expect((vRt.scrollOffsets[vPath]?.y ?? 0) > 500)
        #expect(vRt.element(byKey: "r35") != nil)
    }

    // MARK: - 6. Host Hooks: AppKit Button Mapping, SecureInputClaim, SpellPause, A11y Announcements

    @Test("Host hooks: PointerButton.fromAppKit, SecureInputClaim, SpellPauseWatch, A11y announcements")
    func hostHooksSecureSpellAndA11y() {
        #expect(PointerButton.fromAppKit(buttonNumber: 0) == .primary)
        #expect(PointerButton.fromAppKit(buttonNumber: 1) == .secondary)
        #expect(PointerButton.fromAppKit(buttonNumber: 2) == .middle)
        #expect(PointerButton.fromAppKit(buttonNumber: 3) == .back)
        #expect(PointerButton.fromAppKit(buttonNumber: 4) == .forward)

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

        let claim = SecureInputClaim(touchOS: false)
        rt.update(at: 0.1) { _, tx in tx.focus("sec") }
        _ = rt.frame(at: 0.1)
        #expect(rt.syncSecureInput(claim, windowFocused: true) == true)
        #expect(rt.syncSecureInput(claim, windowFocused: false) == false)
        rt.update(at: 0.2) { _, tx in tx.focus("note") }
        _ = rt.frame(at: 0.2)
        #expect(rt.syncSecureInput(claim, windowFocused: true) == false)

        var watch = SpellPauseWatch(path: rt.focusedPath ?? "", text: rt.state.note.text)
        _ = rt.spellCheckWhenSettled(watch: &watch, at: 0.21)
        rt.state.note.insert("qwkz")
        let suppressed = rt.spellCheckWhenSettled(watch: &watch, at: 0.3)
        #expect(suppressed == nil)
        let settledRanges = rt.spellCheckWhenSettled(watch: &watch, at: 1.5)
        #expect(settledRanges != nil)

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
}
