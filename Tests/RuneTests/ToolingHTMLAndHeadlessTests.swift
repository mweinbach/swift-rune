import Foundation
import Testing
@testable import Rune
import RuneMotion
import RuneRef

#if canImport(Darwin)
import Darwin
#elseif os(Linux)
import Glibc
#endif

@Suite("ToolingHTML, HeadlessRun, Embed & SingleInstance Parity", .serialized)
struct ToolingHTMLAndHeadlessTests {

    private final class ScriptedIncomingGlue: IncomingURLGlue, @unchecked Sendable {
        private let lock = NSLock()
        private var elsewhere: Bool
        var installs = 0
        var removes = 0
        private var installResult: Bool

        init(elsewhere: Bool = false, installResult: Bool = true) {
            self.elsewhere = elsewhere
            self.installResult = installResult
        }

        func handledElsewhere() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return elsewhere
        }

        func install() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            installs += 1
            return installResult
        }

        func remove() {
            lock.lock()
            defer { lock.unlock() }
            removes += 1
        }
    }

    // MARK: - ToolingHTML + Web Static Export (html_tests.rs & web/export/tests.rs)

    @Test("ToolingHTML: template fill, escaping, and multi-width CSS media folding")
    func htmlEscapeFillAndMultiWidthExport() throws {
        let escaped = ToolingHTML.escape("<span>5 & \"six\" 'seven'</span>")
        #expect(escaped == "&lt;span&gt;5 &amp; &quot;six&quot; 'seven'&lt;/span&gt;")

        let spec = AppSpec<Int>(
            title: "HTML Test",
            size: Vec2(400, 300),
            state: 0,
            view: { _, cx in
                let cardWidth: Float = cx.viewport.x > 600 ? 320 : 180
                return col().size(400, 300).p(16).gap(8)
                    .child(text("Hello & Welcome"))
                    .child(
                        row().key("card").w(cardWidth).h(60)
                            .bg(Color(r: 0.2, g: 0.4, b: 0.8, a: 1))
                            .rounded(8)
                    )
            }
        )

        let res = try ToolingHTML.renderHTML(
            spec: spec,
            widths: [960, 400, 400],
            height: 300,
            scale: 1.0,
            dark: true,
            document: true
        )
        #expect(res.widths == [400, 960])
        #expect(res.elementCount >= 3)
        #expect(res.html.contains("Hello &amp; Welcome"))
        #expect(res.html.contains("data-rune-static"))
        #expect(res.html.contains("@media (min-width:960px)"))

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rune-html-test-\(UUID().uuidString)")
        let outFile = tmpDir.appendingPathComponent("out.html").path
        defer { try? FileManager.default.removeItem(atPath: tmpDir.path) }

        let written = try ToolingHTML.exportToFile(
            spec: spec,
            outputPath: outFile,
            widths: [320],
            document: false
        )
        #expect(written.widths == [320])
        let fileHTML = try String(contentsOfFile: outFile, encoding: .utf8)
        #expect(fileHTML.contains("Hello &amp; Welcome"))
    }

    @Test("web/export: media queries and image sizes preserve fractional viewport thresholds")
    func responsiveViewportPrecision() {
        let cases: [(Float, String)] = [
            (.leastNonzeroMagnitude, "0." + String(repeating: "0", count: 44) + "1"),
            (350.125, "350.125"),
            (Float(350.125).nextUp, "350.12503"),
            (45_956.5625, "45956.563"),
            (204_318.125, "204318.13"),
            (.greatestFiniteMagnitude, "34028235" + String(repeating: "0", count: 31)),
        ]
        for (width, expected) in cases {
            let image = ExportNode(path: "image", depth: 0, tag: "img", attrs: " srcset=\"photo 2x\"",
                                   decls: [.init("display", "block")], width: width, text: false)
            var base = image
            base.decls = []
            base.width = max(.leastNonzeroMagnitude, width / 2)
            let page = HTMLPageExporter.page([(base.width, [base]), (width, [image])])
            #expect(page.css.contains("@media (min-width:\(expected)px)"))
            #expect(page.body.contains("sizes=\"(min-width:\(expected)px) 100vw,100vw\""))
        }

        let image = ExportNode(path: "image", depth: 0, tag: "img", attrs: " srcset=\"photo 2x\"",
                               width: 1_234_567, text: false)
        #expect(HTMLPageExporter.page([(1, [image])]).body.contains("sizes=\"123456700vw\""))
    }

    @Test("web/export: inline spans, rich spans, and links export cleanly")
    func webExportTextRichAndLinks() throws {
        // 1. Inline spans inside rich keep a single <p> and no per-span <div/span> layout boxes
        // 2. Links keep words inside one <a href="...">
        let linkSpec = AppSpec<Int>(
            size: Vec2(480, 200),
            state: 0,
            view: { _, _ in
                col().wFull().hFull()
                    .child(
                        rich([
                            TextSpan("Read "),
                            TextSpan("bold", weight: 700),
                            TextSpan(" code", monospace: true),
                        ])
                    )
                    .child(
                        text("See docs here now")
                            .htmlLink(4..<13, "https://rune.dev/docs")
                    )
            }
        )
        let exported = try ToolingHTML.renderHTML(spec: linkSpec, widths: [480], height: 200, document: true)
        #expect(exported.html.contains("<span style=\"font-weight:700\">bold</span>"))
        #expect(exported.html.contains("<span style=\"font-family:var(--rune-mono)\"> code</span>"))
        #expect(exported.html.contains("<a href=\"https://rune.dev/docs\">docs here</a>"))
    }

    @Test("web/export: page mode allows text selection while buttons stay unselectable")
    func webExportPageModeSelectability() throws {
        let spec = AppSpec<Int>(
            size: Vec2(400, 200),
            state: 0,
            view: { _, _ in
                col().wFull().hFull()
                    .child(text("Selectable copy").key("copy"))
                    .child(
                        el().key("cta").htmlRole("button")
                            .child(text("Click me"))
                    )
                    .child(
                        el().key("btn-override").htmlRole("button")
                            .child(text("Copyable label").selectable())
                    )
            }
        )
        let res = try ToolingHTML.renderHTML(spec: spec, widths: [400], height: 200, document: true)
        #expect(res.html.contains("user-select:none"))
        #expect(res.html.contains("user-select:text"))
    }

    @Test("web/export: images emit <img> with alt/srcset/object-fit and shapes emit <svg> + radial gradient")
    func webExportImageAndSVGAndGradient() throws {
        var vp = VectorPath()
        vp.moveTo(0, 0)
        vp.lineTo(10, 0)
        vp.lineTo(10, 10)
        vp.close()
        let shape = Shape(path: vp, style: .fill(Color(r: 1, g: 0, b: 0, a: 1)), viewBox: Vec2(10, 10))

        let spec = AppSpec<Int>(
            size: Vec2(400, 300),
            state: 0,
            view: { _, _ in
                col().wFull().hFull()
                    .child(
                        el().key("hero").size(120, 80)
                            .label("Hero Photo")
                            .htmlImageSource(url: "hero.png", sourceSet: "hero@2x.png 2x", objectFit: .cover)
                    )
                    .child(
                        el().key("badge").size(40, 40)
                            .shape(shape)
                            .radialGradient(
                                center: Vec2(0.5, 0.5),
                                radius: Vec2(0.5, 0.5),
                                stops: [
                                    (0.0, Color(r: 1, g: 1, b: 1, a: 1)),
                                    (1.0, Color(r: 0, g: 0, b: 0, a: 1)),
                                ]
                            )
                    )
            }
        )
        let res = try ToolingHTML.renderHTML(spec: spec, widths: [400], height: 300, document: true)
        #expect(res.html.contains("<img"))
        #expect(res.html.contains("src=\"hero.png\" alt=\"Hero Photo\""))
        #expect(res.html.contains("srcset=\"hero@2x.png 2x\""))
        #expect(res.html.contains("object-fit:cover"))
        #expect(res.html.contains("<svg viewBox=\"0 0 10 10\""))
        #expect(res.html.contains("<path fill=\""))
        #expect(res.html.contains("radial-gradient("))
    }

    // MARK: - HeadlessRun & ToolingProcessArgs

    @Test("HeadlessRun: snapshots, windowsAt, marks, and scriptEnd match upstream")
    func headlessRunTracking() {
        defer { HeadlessRun.clearCurrent() }

        let run = HeadlessRun(
            scriptPath: "script.json",
            events: [
                HeadlessTimedEvent(t: 0.25, event: .mark("after_open")),
                HeadlessTimedEvent(t: 1.50, position: .relative(0.5, 0.5), event: .pointer(.down)),
            ],
            scale: 2.0,
            fps: 60.0,
            size: Vec2(800, 600),
            start: 0.0,
            frames: 90,
            end: 1.0
        )
        run.appendWindowFrame(HeadlessWindowFrame(t: 0.0, key: "main", frame: [0, 0, 800, 600], visible: true, focused: true))
        run.appendWindowFrame(HeadlessWindowFrame(t: 0.5, key: "main", frame: [0, 0, 800, 600], visible: true, focused: false))
        run.appendWindowFrame(HeadlessWindowFrame(t: 0.5, key: "aux", frame: [50, 50, 300, 200], visible: true, focused: true))
        run.appendWindowFrame(HeadlessWindowFrame(t: 1.0, key: "main", frame: [0, 0, 800, 600], visible: false, focused: false))

        let published = HeadlessRun.publish(run)
        #expect(HeadlessRun.current === published)

        let atZero = published.windowsAt(0.0)
        #expect(atZero.map(\.key) == ["main"])
        #expect(atZero.first?.focused == true)

        let atHalf = published.windowsAt(0.6)
        #expect(atHalf.count == 2)
        #expect(atHalf.first(where: { $0.key == "aux" })?.focused == true)

        #expect(published.marks().count == 1)
        #expect(published.mark("after_open") == 0.25)
        #expect(published.mark("missing") == nil)
        #expect(published.scriptEnd() == 1.50)

        HeadlessRun.clearCurrent()
        #expect(HeadlessRun.current == nil)
    }

    @Test("ToolingProcessArgs: splits known flags from app extra args")
    func toolingProcessArgsSplit() {
        defer { ToolingProcessArgs.resetForTesting() }

        let split = ToolingProcessArgs.parseSplit([
            "my-app", "--snap", "shot.png", "--cpu", "--gpu", "--custom-flag", "value", "--fps", "30", "positional",
        ])
        #expect(split.known.snapPath == "shot.png")
        #expect(split.known.requireGPU && !split.known.forceCPU)
        let cpu = ToolingArgs.parse(["my-app", "--gpu", "--cpu"])
        #expect(cpu.forceCPU && !cpu.requireGPU)
        #expect(split.known.fps == 30.0)
        #expect(split.extra == ["my-app", "--custom-flag", "value", "positional"])
        #expect(ToolingProcessArgs.isHeadless(argv: ["my-app", "--snap", "shot.png"]))
        #expect(!ToolingProcessArgs.isHeadless(argv: ["my-app", "--custom-flag"]))
    }

    // MARK: - Embed (platform/embed.rs)

    @Test("Embed: LayerHost attaches runtime headlessly, resizes, steps frames, and runs compositor")
    func embedLayerHostHeadless() throws {
        _ = EmbedPrewarm.prewarm()

        struct State { var count = 0 }
        let spec = AppSpec<State>(
            size: Vec2(320, 240),
            state: State(),
            view: { s, _ in
                col().size(320, 240).child(text("count=\(s.count)").key("lbl"))
            }
        )
        let host = try LayerHost(
            spec: spec,
            scale: 2.0,
            dark: true,
            config: EmbedHostConfig(transparentBackground: true, forwardScrollEvents: false, initialSize: Vec2(200, 120))
        )
        #expect(host.runtime.viewport == Vec2(200, 120))

        var compositorCalled = 0
        host.withCompositor { rt, _ in
            compositorCalled += 1
            return nil
        }

        let first = host.frame(at: 0.0)
        #expect(first.drew)
        #expect(compositorCalled == 1)

        let second = host.frame(at: 0.016)
        #expect(!second.drew)

        host.update { st, _ in st.count = 42 }
        host.resize(viewport: Vec2(400, 300), scale: 1.5)
        let third = host.frame(at: 0.032)
        #expect(third.drew)
        #expect(host.runtime.viewport == Vec2(400, 300))
        #expect(host.runtime.pixelScale == 1.5)
    }

    // MARK: - IncomingURLInbox & SingleInstance (open_url/incoming_tests.rs + instance.rs)

    @Test("open_url/incoming: all 7 launch & listener ordering scenarios match upstream")
    func incomingURLAllSevenScenarios() {
        final class Bag: @unchecked Sendable {
            private let lock = NSLock()
            var items: [String] = []
            func append(_ s: String) {
                lock.lock()
                items.append(s)
                lock.unlock()
            }
        }

        // 1. launch_links_reach_a_later_listener
        do {
            let inbox = IncomingURLInbox()
            let glue = ScriptedIncomingGlue()
            inbox.prepare(glue: glue)
            inbox.launched(["rune://one", "rune://two"])
            let got = Bag()
            let sub = inbox.listen(glue: glue) { got.append($0) }
            #expect(sub != nil)
            #expect(got.items == ["rune://one", "rune://two"])
            #expect(glue.installs == 1)
        }

        // 2. a_live_url_reaches_the_first_listener_before_launch_is_drained
        do {
            let inbox = IncomingURLInbox()
            let glue = ScriptedIncomingGlue()
            inbox.prepare(glue: glue)
            inbox.receive("rune://live")
            let got = Bag()
            let sub = inbox.listen(glue: glue) { got.append($0) }
            #expect(sub != nil)
            #expect(got.items == ["rune://live"])
        }

        // 3. simultaneous listeners: live URLs go to the first; only after sub1 cancels do URLs route to sub2
        do {
            let inbox = IncomingURLInbox()
            let glue = ScriptedIncomingGlue()
            inbox.prepare(glue: glue)
            inbox.launched([])
            let got1 = Bag()
            let got2 = Bag()
            let sub1 = inbox.listen(glue: glue) { got1.append($0) }
            let sub2 = inbox.listen(glue: glue) { got2.append($0) }
            #expect(sub1 != nil)
            #expect(sub2 != nil)
            #expect(glue.installs == 1)
            inbox.receive("rune://before-cancel")
            #expect(got1.items == ["rune://before-cancel"])
            #expect(got2.items.isEmpty)
            sub1?.cancel()
            inbox.receive("rune://after-cancel")
            #expect(got1.items == ["rune://before-cancel"])
            #expect(got2.items == ["rune://after-cancel"])
            sub2?.cancel()
        }

        // 4. dropping/cancelling the listener frees the slot for a replacement window
        do {
            let inbox = IncomingURLInbox()
            let glue = ScriptedIncomingGlue()
            inbox.prepare(glue: glue)
            inbox.launched([])
            let got1 = Bag()
            let sub1 = inbox.listen(glue: glue) { got1.append($0) }
            #expect(sub1 != nil)
            sub1?.cancel()
            let got2 = Bag()
            let sub2 = inbox.listen(glue: glue) { got2.append($0) }
            #expect(sub2 != nil)
            inbox.receive("rune://second-window")
            #expect(got2.items == ["rune://second-window"])
            sub2?.cancel()
        }

        // 5. settle_clears_unhandled_launches
        do {
            let inbox = IncomingURLInbox()
            let glue = ScriptedIncomingGlue()
            inbox.prepare(glue: glue)
            inbox.launched(["rune://unclaimed"])
            inbox.settle(glue: glue)
            #expect(glue.removes == 1)
            let got = Bag()
            let sub = inbox.listen(glue: glue) { got.append($0) }
            #expect(sub != nil)
            #expect(got.items.isEmpty)
        }

        // 6. a_live_url_buffered_earlier_is_delivered_when_launched_arrives
        do {
            let inbox = IncomingURLInbox()
            let glue = ScriptedIncomingGlue()
            inbox.prepare(glue: glue)
            inbox.receive("rune://early")
            inbox.launched(["rune://arg"])
            let got = Bag()
            let sub = inbox.listen(glue: glue) { got.append($0) }
            #expect(sub != nil)
            #expect(got.items == ["rune://arg", "rune://early"])
        }

        // 7. listener_dropped_clears_slot_and_settle_removes_glue
        do {
            let inbox = IncomingURLInbox()
            let glue = ScriptedIncomingGlue()
            inbox.prepare(glue: glue)
            inbox.launched([])
            let got = Bag()
            let sub = inbox.listen(glue: glue) { got.append($0) }
            #expect(sub != nil)
            sub?.cancel()
            inbox.settle(glue: glue)
            #expect(glue.removes == 1)
            inbox.receive("rune://after-settle")
            #expect(got.items.isEmpty)
        }

        // 8. open_url/incoming_tests.rs:50 - without a listener, settle drops launch links and removes handler
        do {
            let inbox = IncomingURLInbox()
            let glue = ScriptedIncomingGlue()
            inbox.prepare(glue: glue)
            inbox.receive("rune://kept")
            inbox.settle(glue: glue)
            #expect(glue.installs == 1 && glue.removes == 1)
            inbox.receive("rune://dropped")
            let late = Bag()
            let sub = inbox.listen(glue: glue) { late.append($0) }
            #expect(sub != nil)
            #expect(late.items.isEmpty)
            sub?.cancel()
        }

        // 9. open_url/incoming_tests.rs:121 - app's own handler stays unless a window installs the hook
        do {
            let inbox = IncomingURLInbox()
            let glue = ScriptedIncomingGlue(elsewhere: true)
            inbox.prepare(glue: glue)
            inbox.receive("rune://theirs")
            inbox.settle(glue: glue)
            #expect(glue.installs == 0 && glue.removes == 0)
            let got = Bag()
            let sub = inbox.listen(glue: glue) { got.append($0) }
            #expect(sub != nil)
            #expect(glue.installs == 1)
            #expect(got.items.isEmpty)
            sub?.cancel()
        }

        // 10. open_url/incoming_tests.rs:134 - a handler that cannot install listens to nothing
        do {
            let inbox = IncomingURLInbox()
            let refuse = ScriptedIncomingGlue(installResult: false)
            let got = Bag()
            #expect(inbox.listen(glue: refuse) { got.append($0) } == nil)
            inbox.receive("rune://dropped")
            #expect(got.items.isEmpty)
            let sub = inbox.listen(glue: ScriptedIncomingGlue()) { got.append($0) }
            #expect(sub != nil)
            sub?.cancel()
        }
    }

    @Test("SingleInstance: link filtering, handoff codec, and Unix domain socket forwarding")
    func singleInstanceHandoffAndLinks() throws {
        #expect(SingleInstance.isLink("https://example.com/open"))
        #expect(SingleInstance.isLink("rune://workspace"))
        #expect(!SingleInstance.isLink("--flag"))
        #expect(!SingleInstance.isLink("relative/path"))

        let args = ["rune://doc/1", "--reopen", "https://rune.dev"]
        let encoded = SingleInstance.encodeHandoffMessage(arguments: args)
        let decoded = SingleInstance.decodeHandoffMessage(encoded)
        #expect(decoded == args)
        let rawDecoded = SingleInstance.decodeHandoffArguments(Array("a\0b\0".utf8))
        #expect(rawDecoded == ["a", "b"])

        let badDecoded = SingleInstance.decodeHandoffMessage([0xFF, 0xFF, 0xFF, 0xFF])
        #expect(badDecoded == nil)
        let oversized = "rune://" + String(repeating: "x", count: SingleInstance.maxMessageBytes)
        #expect(SingleInstance.encodeHandoffMessage(arguments: [oversized]).isEmpty)
        #expect(SingleInstance.decodeHandoffMessage(Array(encoded.dropLast())) == nil)

        #if os(macOS) || os(Linux)
        // Use a short directory under /tmp so the Unix domain socket path stays < 104 bytes on macOS
        let dir = "/tmp/rsi-\(String(UUID().uuidString.prefix(8)))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            SingleInstance.release()
            try? FileManager.default.removeItem(atPath: dir)
        }
        let first = SingleInstance.claim(
            id: "rt",
            arguments: ["app"],
            baseDirectory: dir,
            forceUnixSocket: true
        )
        #expect(first == true)

        let relaunchLock = NSLock()
        nonisolated(unsafe) var relaunched = 0
        SingleInstance.onRelaunch {
            relaunchLock.lock()
            relaunched += 1
            relaunchLock.unlock()
            return true
        }
        // Calling claim a second time without links triggers onRelaunch on primary via Unix domain socket
        let second = SingleInstance.claim(
            id: "rt",
            arguments: ["--reopen"],
            baseDirectory: dir,
            forceUnixSocket: true
        )
        #expect(second == false)

        // Allow accept loop thread a moment to read the handoff packet
        Thread.sleep(forTimeInterval: 0.05)
        relaunchLock.lock()
        let count = relaunched
        relaunchLock.unlock()
        #expect(count >= 1)
        #endif
    }

    @Test("tooling/html_tests.rs: fills markers or head/body and defaultTemplate contains both markers")
    func toolingHtmlFillMarkersAndDefaultTemplate() {
        let marked = "<head><!-- rune:css --></head><body><nav></nav><!-- rune:body --></body>"
        #expect(
            ToolingHTML.fill(template: marked, css: ".a{}", body: "<main></main>")
                == "<head><style data-rune-static>.a{}</style></head><body><nav></nav><main></main></body>"
        )
        let plain = "<html><head><title>x</title></head><body class=\"k\"></body></html>"
        #expect(
            ToolingHTML.fill(template: plain, css: ".a{}", body: "<main></main>")
                == "<html><head><title>x</title><style data-rune-static>.a{}</style></head><body class=\"k\"><main></main></body></html>"
        )
        #expect(ToolingHTML.defaultTemplate.contains(ToolingHTML.cssMarker))
        #expect(ToolingHTML.defaultTemplate.contains(ToolingHTML.bodyMarker))
    }
}
