import Foundation
import ImageIO
import Testing
@testable import Rune

@Suite("Platform Increment 6 Parity — Tooling CLI, Strip/Crop/Marks, Playground Host & Tx")
struct RunePlatformIncrement6Tests {

    @Test("ToolingArgs parses upstream --frames count, --out, --cols, multi --crop, mark:NAME offsets, --playground/--variant, and extraArgs")
    func toolingArgsUpstreamParsing() {
        let args = ToolingArgs.parse([
            "--frames", "12",
            "--out", "/tmp/rune-out",
            "--cols", "3",
            "--crop", "10,20,30,40",
            "--crop", "50,60,25,15",
            "--playground", "Timeline/Send",
            "--variant", "compact",
            "--whole-window",
            "--scroll-bars", "always",
            "--window", "inspector",
            "--list-windows",
            "--chrome",
            "--realtime",
            "--duration", "auto",
            "--at", "mark:done+0.25",
            "--start", "mark:begin-0.1",
            "positional-arg",
        ])
        #expect(args.frameCount == 12)
        #expect(args.framesDir == nil)
        #expect(args.outDir == "/tmp/rune-out")
        #expect(args.stripCols == 3)
        #expect(args.cropRects == [[10, 20, 30, 40], [50, 60, 25, 15]])
        #expect(args.hasPlayground == true)
        #expect(args.playgroundName == "Timeline/Send")
        #expect(args.playgroundVariant == "compact")
        #expect(args.wholeWindow == true)
        #expect(args.scrollBars == .always)
        #expect(args.windowName == "inspector")
        #expect(args.listWindows == true)
        #expect(args.chromeOverlay == true)
        #expect(args.realtime == true)
        #expect(args.durationAuto == true)
        #expect(args.atMark == ToolingMarkOffset(name: "done", offset: 0.25))
        #expect(args.startMark == ToolingMarkOffset(name: "begin", offset: -0.1))
        #expect(args.extraArgs == ["positional-arg"])
        #expect(args.isHeadlessRequested == true)

        // `--playground` followed immediately by another flag leaves playgroundName nil
        let barePg = ToolingArgs.parse(["--playground", "--dark"])
        #expect(barePg.hasPlayground == true)
        #expect(barePg.playgroundName == nil)
        #expect(barePg.darkOverride == true)

        // Legacy non-numeric `--frames DIR` still maps to `framesDir`
        let legacy = ToolingArgs.parse(["--frames", "/tmp/legacy-frames"])
        #expect(legacy.frameCount == nil)
        #expect(legacy.framesDir == "/tmp/legacy-frames")
    }

    @Test("HeadlessRunner executes --frames N, --out, --cols grid --strip, multi --crop, and extended --script events")
    func headlessRunnerFramesStripCropAndExtendedScript() throws {
        struct ScriptState {
            var openedUrls: [String] = []
            var reopenCount = 0
            var imeEvents: [String] = []
            var droppedFiles: [String] = []
        }

        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rune-inc6-\(UUID().uuidString)")
        let outDir = tmpRoot.appendingPathComponent("frames")
        let stripURL = tmpRoot.appendingPathComponent("strip.png")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let script = """
        [
          {"t": 0.01, "type": "mark", "name": "ready"},
          {"t": 0.02, "reopen": true},
          {"t": 0.03, "open_url": "https://rune.dev/docs"},
          {"t": 0.04, "type": "ime", "commit": "こんにちは"},
          {"t": 0.05, "paste": {"text": "Hello", "html": "<strong>Hello</strong>"}},
          {"t": 0.06, "drag_files": ["/tmp/demo.txt"], "x": 40, "y": 40},
          {"t": 0.07, "drop_files": ["/tmp/demo.txt"], "x": 40, "y": 40}
        ]
        """

        let app = App(title: "Inc6Script", size: Vec2(100, 80), state: ScriptState()) { _, _ in
            el().key("root").w(100).h(80).bg(Color(r: 0.2, g: 0.3, b: 0.8, a: 1))
        }
        .onReopen { s, _, _ in
            s.reopenCount += 1
            return true
        }
        .onOpenUrl { s, url, _ in
            s.openedUrls.append(url)
        }
        .onIme { s, ime, _ in
            if case .commit(let text) = ime {
                s.imeEvents.append(text)
            }
            return true
        }

        let args = ToolingArgs.parse([
            "--force-cpu",
            "--scale", "1",
            "--fps", "20",
            "--frames", "4",
            "--every", "1",
            "--cols", "2",
            "--crop", "0,0,20,10",
            "--crop", "10,10,20,15",
            "--out", outDir.path,
            "--strip", stripURL.path,
            "--script", script,
        ])

        let output = try HeadlessRunner.run(app, args: args)
        #expect(output.frameCount == 4)
        #expect(output.marks["ready"] == 0.01)

        // Two vertical crops (20x10 and 20x15 + 4px gap = 20x29) per frame
        #expect(output.finalFrame.width == 20)
        #expect(output.finalFrame.height == 29)

        let files = try FileManager.default.contentsOfDirectory(atPath: outDir.path).sorted()
        #expect(files == ["frame_0000.png", "frame_0001.png", "frame_0002.png", "frame_0003.png"])

        // 4 frames in 2x2 grid with 4px gutters: width = 20*2 + 4 = 44, height = 29*2 + 4 = 62
        let src = try #require(CGImageSourceCreateWithURL(stripURL as CFURL, nil))
        let cgImg = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(cgImg.width == 44)
        #expect(cgImg.height == 62)

        // Note: re-verify events dispatched across App hooks and AppSpec.onFileDrop via --at mark:ready+0.1
        var captured = ScriptState()
        let verifyApp = App(title: "VerifyEvents", size: Vec2(100, 80), state: ScriptState()) { s, _ in
            captured = s
            return el().w(100).h(80)
        }
        .onReopen { s, _, _ in s.reopenCount += 1; return true }
        .onOpenUrl { s, url, _ in s.openedUrls.append(url) }
        .onIme { s, ime, _ in
            if case .commit(let text) = ime { s.imeEvents.append(text) }
            return true
        }

        let verifyArgs = ToolingArgs.parse(["--force-cpu", "--script", script, "--at", "mark:ready+0.1"])
        _ = try HeadlessRunner.run(verifyApp, args: verifyArgs)
        #expect(captured.reopenCount == 1)
        #expect(captured.openedUrls == ["https://rune.dev/docs"])
        #expect(captured.imeEvents == ["こんにちは"])

        var dropped: [String] = []
        let dropSpec = AppSpec<ScriptState>(size: Vec2(100, 80), state: ScriptState()) { _, _ in
            el().w(100).h(80)
        }
        .onFileDrop { _, urls, _ in
            dropped.append(contentsOf: urls.map(\.path))
        }
        _ = try HeadlessRunner.run(dropSpec, args: verifyArgs)
        #expect(dropped == ["/tmp/demo.txt"])
    }

    @Test("PlaygroundHost findStory/openAt/variants/triggers/scenesFilter and Tx playground helpers match upstream")
    func playgroundHostAndTxHelpers() throws {
        struct PGState {
            var count = 0
            var note = ""
        }

        let host = PlaygroundHost<PGState>()
            .enabled(true)
            .bar(false)
            .startFolded(true)
            .groupOrder(["Timeline", "Lists"])
            .scenes { $0.contains("/") }
            .story(PlaygroundStory(path: "Timeline/Send Message") { s, _, _ in
                el().key("send-\(s.count)").w(100).h(40)
            })
            .variant("Timeline/Send Message", name: "Compact") { s in
                s.note = "compact"
            }
            .variant("Timeline/Send Message", name: "Expanded") { s in
                s.note = "expanded"
            }
            .trigger("Send Message", key: "R", label: "Reset") { s, _ in
                s.count = 0
            }
            .trigger("Timeline/Send Message", key: "a", label: "Add") { s, _ in
                s.count += 1
            }

        host.bindScenes([
            "hidden-root": { _, _ in },
            "Lists/Many Devices": { s, _ in s.count = 5 },
        ]) { _, _ in
            el().w(80).h(30)
        }

        // ScenesFilter excluded "hidden-root" and inserted "Lists/Many Devices"
        #expect(host.stories.map(\.path) == ["Lists/Many Devices", "Timeline/Send Message"])

        // Lookup by path, name, case-insensitive, and slug
        #expect(host.findStory(named: "Timeline/Send Message")?.path == "Timeline/Send Message")
        #expect(host.findStory(named: "send message")?.path == "Timeline/Send Message")
        #expect(host.findStory(named: "timeline-send-message")?.path == "Timeline/Send Message")
        #expect(host.findStory(named: "lists-many-devices")?.path == "Lists/Many Devices")

        // Unknown story throws descriptive PlaygroundLookupError
        #expect(throws: PlaygroundLookupError.unknownStory(name: "missing", available: ["Lists/Many Devices", "Timeline/Send Message"])) {
            try host.openAt(story: "missing")
        }

        // Variant lookup by name (case-insensitive) and 1-based index
        try host.openAt(story: "timeline-send-message", variant: "expanded")
        #expect(host.isOpen == true)
        #expect(host.currentVariant?.name == "Expanded")

        try host.openAt(story: "Send Message", variant: "1")
        #expect(host.currentVariant?.name == "Compact")

        #expect(throws: PlaygroundLookupError.unknownVariant(name: "bogus", story: "Timeline/Send Message", available: ["Compact", "Expanded"])) {
            try host.openAt(story: "Send Message", variant: "bogus")
        }

        // Tx.openPlaygroundAt, Tx.playgroundTrigger, Tx.replayPlayground flow through Runtime
        let rt = Runtime<PGState>(
            state: PGState(count: 9, note: ""),
            viewport: Vec2(200, 120),
            view: { _, _ in el().w(100).h(50) }
        )
        rt.playgroundHost = host
        host.close()

        rt.update(at: 0.1) { _, tx in
            tx.openPlaygroundAt("timeline-send-message", variant: "2")
            tx.playgroundTrigger("a")
            tx.replayPlayground()
        }
        #expect(host.isOpen == true)
        #expect(host.selectedStoryPath == "Timeline/Send Message")
        #expect(host.currentVariant?.name == "Expanded")
        #expect(host.replayCount == 1)
        // Added 1 on 'a', then reset to 0 by 'r' on replay
        #expect(rt.state.count == 0)
        #expect(rt.takePlaygroundRequests().count == 3)
    }

    @Test("Tooling mark resolution preserves hyphenated mark names, --duration auto reaches end mark, and --playground applies variant & propagates errors")
    func markResolutionDurationAutoAndPlaygroundCliParity() throws {
        struct PGCliState {
            var width: Float = 20
        }

        // 1. Hyphenated mark name `step-1` and `step-1+0.1`
        let script = """
        [
          {"t": 0.15, "type": "mark", "name": "step-1"},
          {"t": 0.30, "type": "mark", "name": "end"}
        ]
        """
        let spec = AppSpec<PGCliState>(size: Vec2(80, 60), state: PGCliState()) { s, _ in
            el().key("box").w(s.width).h(20)
        }
        let step1Args = ToolingArgs.parse(["--force-cpu", "--fps", "20", "--script", script, "--at", "mark:step-1"])
        let step1Out = try HeadlessRunner.run(spec, args: step1Args)
        #expect(step1Out.marks["step-1"] == 0.15)
        let step1Tree = String(decoding: step1Out.treeJSON, as: UTF8.self)
        #expect(step1Tree.contains("\"t\" : 0.15") || step1Tree.contains("\"t\":0.15"))

        let offsetArgs = ToolingArgs.parse(["--force-cpu", "--fps", "20", "--script", script, "--at", "mark:step-1+0.1"])
        let offsetOut = try HeadlessRunner.run(spec, args: offsetArgs)
        let offsetTree = String(decoding: offsetOut.treeJSON, as: UTF8.self)
        #expect(offsetTree.contains("\"t\" : 0.25") || offsetTree.contains("\"t\":0.25"))

        #expect(throws: ToolingError.unknownMark(name: "missing", known: ["end", "step-1"])) {
            _ = try HeadlessRunner.run(
                spec,
                args: ToolingArgs.parse(["--force-cpu", "--script", script, "--at", "mark:missing"])
            )
        }

        // 2. `--duration auto` stops at `marks["end"]` (0.30 s @ 20 fps -> frames 0..6 = 7 frames), not premature idle break
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rune-inc6-fixes-\(UUID().uuidString)")
        let autoDir = tmpRoot.appendingPathComponent("auto-frames")
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let autoArgs = ToolingArgs.parse([
            "--force-cpu",
            "--fps", "20",
            "--duration", "auto",
            "--script", script,
            "--out", autoDir.path,
        ])
        let autoOut = try HeadlessRunner.run(spec, args: autoArgs)
        #expect(autoOut.frameCount == 7)
        let autoFiles = try FileManager.default.contentsOfDirectory(atPath: autoDir.path).sorted()
        #expect(autoFiles.count == 7)

        // 3. `--playground` / `--variant` propagates errors and applies selected variant state
        let host = PlaygroundHost<PGCliState>()
            .enabled(true)
            .story(PlaygroundStory(path: "Slide") { s, _, _ in
                el().key("puck").w(s.width).h(20).bg(Color(r: 0.9, g: 0.2, b: 0.2, a: 1))
            })
            .variant("Slide", name: "Small") { $0.width = 20 }
            .variant("Slide", name: "Big") { $0.width = 48 }

        let pgApp = App(title: "PG", size: Vec2(120, 80), state: PGCliState()) { _, _ in
            el().w(120).h(80)
        }
        .playground(host)

        #expect(throws: PlaygroundLookupError.unknownStory(name: "Nope", available: ["Slide"])) {
            _ = try HeadlessRunner.run(
                pgApp,
                args: ToolingArgs.parse(["--force-cpu", "--playground", "Nope"])
            )
        }
        #expect(throws: PlaygroundLookupError.unknownVariant(name: "Huge", story: "Slide", available: ["Small", "Big"])) {
            _ = try HeadlessRunner.run(
                pgApp,
                args: ToolingArgs.parse(["--force-cpu", "--playground", "Slide", "--variant", "Huge"])
            )
        }

        let bigSnap = tmpRoot.appendingPathComponent("big.png")
        let bigOut = try HeadlessRunner.run(
            pgApp,
            args: ToolingArgs.parse([
                "--force-cpu",
                "--scale", "2",
                "--playground", "Slide",
                "--variant", "Big",
                "--crop", "puck",
                "--snap", bigSnap.path,
            ])
        )
        #expect(bigOut.finalFrame.width == 96)
        #expect(bigOut.finalFrame.height == 40)
    }

    @Test("HeadlessRunner executes --list-windows, --window, --trace, --chrome, --realtime, and --video")
    func headlessRunnerListWindowsTraceChromeRealtimeAndVideo() throws {
        struct WinState {
            var readyFired = false
        }

        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rune-inc6-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        // `--list-windows` and `--window KEY` across multi-window specs
        let mainWin = AppWindowSpec(
            key: "main",
            app: AppSpec(title: "Main", size: Vec2(100, 60), state: WinState()) { _, _ in
                el().key("main-root").w(100).h(60)
            }
        ).boxed()
        let inspectorWin = AppWindowSpec(
            key: "inspector",
            app: AppSpec(title: "Inspector", size: Vec2(140, 90), state: WinState()) { _, _ in
                el().key("inspector-root").w(140).h(90)
            }
        ).boxed()

        let listOut = try RuneMultiWindow.runHeadless(
            [mainWin, inspectorWin],
            args: ToolingArgs.parse(["--list-windows"])
        )
        #expect(listOut.windowKeys == ["main", "inspector"])

        let winOut = try RuneMultiWindow.runHeadless(
            [mainWin, inspectorWin],
            args: ToolingArgs.parse(["--force-cpu", "--scale", "1", "--window", "inspector"])
        )
        #expect(winOut.windowKeys == ["inspector"])
        #expect(winOut.finalFrame.width == 140)
        #expect(winOut.finalFrame.height == 90)

        #expect(throws: MultiWindowError.unknownWindow(key: "ghost", available: ["main", "inspector"])) {
            _ = try RuneMultiWindow.runHeadless(
                [mainWin, inspectorWin],
                args: ToolingArgs.parse(["--force-cpu", "--window", "ghost"])
            )
        }

        // `--trace`, `--chrome`, and `--realtime`
        final class ReadyBox: @unchecked Sendable {
            var count = 0
        }
        let readyBox = ReadyBox()
        let traceURL = tmpRoot.appendingPathComponent("motion.jsonl")
        let chromeSnapURL = tmpRoot.appendingPathComponent("chrome.png")

        let chromeApp = App(title: "ChromeApp", size: Vec2(160, 80), state: WinState()) { _, _ in
            el().key("root").w(160).h(80).bg(Color(r: 0.1, g: 0.1, b: 0.12, a: 1))
                .child(el().key("overlap-btn").role(.button).w(90).h(26).bg(Color(r: 0.2, g: 0.3, b: 0.5, a: 1)))
        }
        .chrome(.default)
        .onReady { _ in
            readyBox.count += 1
        }

        let traceOut = try HeadlessRunner.run(
            chromeApp,
            args: ToolingArgs.parse([
                "--force-cpu",
                "--scale", "1",
                "--fps", "20",
                "--frames", "2",
                "--trace", traceURL.path,
                "--chrome",
                "--realtime",
                "--snap", chromeSnapURL.path,
            ])
        )
        #expect(readyBox.count == 1)
        #expect(traceOut.tracePath == traceURL.path)
        #expect(traceOut.chromeOverlaps.contains("overlap-btn"))
        let traceText = try String(contentsOf: traceURL, encoding: .utf8)
        let traceLines = traceText.split(separator: "\n")
        #expect(traceLines.count == 3)
        #expect(traceLines[0].contains("\"type\":\"header\""))
        #expect(traceLines[1].contains("\"overlap-btn\""))

        // `--video` rejects unsupported containers and encodes `.mp4` when `ffmpeg` is available
        let gifURL = tmpRoot.appendingPathComponent("bad.gif")
        #expect(throws: ToolingError.unsupportedVideoContainer(ext: "gif")) {
            _ = try HeadlessRunner.run(
                chromeApp,
                args: ToolingArgs.parse(["--force-cpu", "--frames", "2", "--video", gifURL.path])
            )
        }

        let hasFFmpeg = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .contains { FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: String($0)).appendingPathComponent("ffmpeg").path) }
        if hasFFmpeg {
            let mp4URL = tmpRoot.appendingPathComponent("out.mp4")
            let vidOut = try HeadlessRunner.run(
                chromeApp,
                args: ToolingArgs.parse([
                    "--force-cpu",
                    "--scale", "1",
                    "--fps", "20",
                    "--frames", "3",
                    "--video", mp4URL.path,
                ])
            )
            #expect(vidOut.videoPath == mp4URL.path)
            #expect(vidOut.frameCount == 3)
            let attrs = try FileManager.default.attributesOfItem(atPath: mp4URL.path)
            #expect((attrs[.size] as? Int ?? 0) > 0)
        }
    }
}
