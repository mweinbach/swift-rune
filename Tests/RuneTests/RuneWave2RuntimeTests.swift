import XCTest
@testable import Rune
import RuneMotion
import RuneRef

#if canImport(Metal)
import Metal
#endif

final class RuneWave2RuntimeTests: XCTestCase {

    // MARK: - 1. Rich Clipboard & Secret Pasteboard

    func testRichClipboardImageAndHTMLSanitization() {
        let cb = Clipboard(kind: .memory)
        let rgba = Data([
            255, 0, 0, 255,   0, 255, 0, 255,
            0, 0, 255, 255,   255, 255, 255, 255,
        ])
        let img = ClipboardImage.fromRGBA(width: 2, height: 2, rgba: rgba)
        XCTAssertNotNil(img)
        XCTAssertEqual(img?.width, 2)
        XCTAssertEqual(img?.height, 2)
        XCTAssertEqual(img?.decodeRGBA()?.count, 16)

        let dirtyHTML = #"<b>Hello</b><script>alert(1)</script><img src="x" onerror="steal()"><a href="javascript:void(0)">link</a>"#
        let payload = RichClipboardPayload(
            text: "Hello",
            html: dirtyHTML,
            rtf: "{\\rtf1 Hello}",
            image: img,
            files: [URL(fileURLWithPath: "/tmp/example.txt")],
            customPayloads: ["application/x-rune-node": Data("node-42".utf8)],
            isConcealed: false
        )
        cb.writeRich(payload)

        let read = cb.readRich(sanitizeUntrustedHTML: true)
        XCTAssertEqual(read.content.text, "Hello")
        XCTAssertEqual(read.content.rtf, "{\\rtf1 Hello}")
        XCTAssertEqual(read.image?.width, 2)
        XCTAssertEqual(read.files.count, 1)
        XCTAssertEqual(cb.readCustomPayload(type: "application/x-rune-node"), Data("node-42".utf8))
        let sanitized = read.content.html ?? ""
        XCTAssertTrue(sanitized.contains("<b>Hello</b>"))
        XCTAssertFalse(sanitized.contains("<script>"))
        XCTAssertFalse(sanitized.contains("onerror"))
        XCTAssertFalse(sanitized.contains("javascript:"))
    }

    func testSessionLockClearsOnlyTheCurrentSecret() {
        let board = Clipboard(kind: .memory)
        let original = board.writeSecret("original")
        let replacement = board.writeSecret("replacement")
        XCTAssertTrue(board.clearCurrentSecret())
        XCTAssertEqual(original.state, .replaced)
        XCTAssertEqual(replacement.state, .cleared)
        XCTAssertFalse(board.clearCurrentSecret())
        let new = board.writeSecret("new")
        board.writeText("keep")
        XCTAssertFalse(board.clearCurrentSecret())
        XCTAssertEqual(new.state, .replaced)
        XCTAssertEqual(board.readRich().content.text, "keep")
    }

    func testSecretClipboardLifecycle() {
        let cb = Clipboard(kind: .memory)
        let secret = cb.writeSecret("super-secret-token")
        XCTAssertEqual(secret.state, .holding)
        XCTAssertTrue(cb.readRich().isConcealed)
        XCTAssertTrue(secret.clearNow())
        XCTAssertEqual(secret.state, .cleared)
        XCTAssertEqual(cb.readRich().content.text, "")

        let secret2 = cb.writeSecret("another-token")
        XCTAssertEqual(secret2.state, .holding)
        cb.writeText("normal-text")
        XCTAssertEqual(secret2.state, .replaced)
        XCTAssertFalse(secret2.clearNow())
    }

    // MARK: - 2. Drag Out & File Drop

    func testDragItemAndRuntimeFileDrop() {
        let item = DragItem()
            .file(path: "/tmp/a.png")
            .text("a.png")
            .opaque(.white)
            .operation([.copy, .move])
            .allowWithinApp(true)
        XCTAssertEqual(item.files.count, 1)
        XCTAssertEqual(item.text, "a.png")
        XCTAssertTrue(item.withinApp)
        XCTAssertTrue(DragItem.pastThreshold(from: .zero, to: Vec2(5, 0)))
        XCTAssertFalse(DragItem.pastThreshold(from: .zero, to: Vec2(2, 2)))

        struct State {
            var events: [String] = []
        }
        let rt = Runtime<State>(
            state: State(),
            viewport: Vec2(400, 300),
            view: { _, _ in col() }
        )
        rt.onFileDrop = { state, phase, tx in
            switch phase {
            case .entered(let files, _):
                state.events.append("entered:\(files.count)")
            case .hovered(let at):
                state.events.append("hovered:\(Int(at.x))")
            case .dropped(let files, _):
                state.events.append("dropped:\(files.map(\.name).joined(separator: ","))")
                tx.dragOut(item)
            case .exited:
                state.events.append("exited")
            }
        }

        let f = DroppedFile(path: "/tmp/hello.txt", sizeBytes: 128)
        rt.fileDrop(.entered([f], at: Vec2(10, 20)), at: 0.1)
        XCTAssertTrue(rt.fileDropState.isHovering)
        rt.fileDrop(.hovered(at: Vec2(42, 20)), at: 0.2)
        XCTAssertTrue(rt.receiveFileDrop(.dropped([f], at: Vec2(42, 20)), at: 0.3))
        XCTAssertFalse(rt.fileDropState.isHovering)
        XCTAssertEqual(rt.fileDropState.lastDroppedFiles, [f])
        XCTAssertEqual(rt.fileDropState.lastDragOutItem, item)
        rt.fileDrop(.exited, at: 0.4)
        XCTAssertEqual(rt.state.events, ["entered:1", "hovered:42", "dropped:hello.txt", "exited"])
    }

    // MARK: - 3. FileDialog, UrlOpener, Menus, Tray, WindowManager, Prefs, Dirs, Quit

    func testScriptedFileDialog() throws {
        let dialog = FileDialog.scripted([
            ScriptedFileDialog(kind: .open, urls: [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")]),
            ScriptedFileDialog(kind: .save, url: nil),
            ScriptedFileDialog(kind: .folder, url: URL(fileURLWithPath: "/tmp")),
        ])
        let opened = try dialog.runScripted(kind: .open, options: FileDialogOptions(allowsMultipleSelection: true))
        XCTAssertEqual(opened?.count, 2)
        let saved = try dialog.runScripted(kind: .save)
        XCTAssertNil(saved)
        let folder = try dialog.runScripted(kind: .folder)
        XCTAssertEqual(folder?.first?.path, "/tmp")
        XCTAssertThrowsError(try dialog.runScripted(kind: .open))
    }

    func testUrlOpenerValidationAndHeadlessQueue() throws {
        let opener = UrlOpener(headless: true)
        XCTAssertEqual(try opener.open("  HTTPS://example.com/path?a=1 "), "https://example.com/path?a=1")
        XCTAssertEqual(try opener.open("mailto:hi@example.com"), "mailto:hi@example.com")
        XCTAssertEqual(opener.takeRequests().count, 2)
        XCTAssertTrue(opener.takeRequests().isEmpty)

        XCTAssertThrowsError(try UrlOpener.validate(""))
        XCTAssertThrowsError(try UrlOpener.validate("javascript:alert(1)"))
        XCTAssertThrowsError(try UrlOpener.validate("file:///etc/passwd"))
        XCTAssertThrowsError(try UrlOpener.validate("https://bad host.com"))
    }

    func testPopupAndNativeMenu() throws {
        var menu = PopupMenu()
        menu.addItem(PopupMenuItem(id: "copy", title: "Copy", keyEquivalent: "c", symbolName: "doc.on.doc"))
        menu.addSeparator()
        var sub = PopupMenu()
        sub.addItem(PopupMenuItem(id: "dark", title: "Dark Mode", checked: true))
        menu.addSubmenu(title: "Theme", menu: sub)
        XCTAssertEqual(menu.findItem(id: "dark")?.checked, true)

        #if os(macOS)
        let nsMenuCount = MainActor.assumeIsolated { menu.buildNSMenu().items.count }
        XCTAssertEqual(nsMenuCount, 3)
        #endif

        struct AppState { var count = 0 }
        let bar = NativeMenuBar<AppState>(items: [
            NativeMenuItem(id: "inc", title: "Increment", location: .named("Edit")) { s, _ in s.count += 1 },
            NativeMenuItem(id: "dis", title: "Disabled", enabled: false) { s, _ in s.count += 10 },
        ])
        var s = AppState()
        var tx = Tx()
        try bar.dispatch(id: "inc", state: &s, tx: &tx)
        XCTAssertEqual(s.count, 1)
        XCTAssertThrowsError(try bar.dispatch(id: "dis", state: &s, tx: &tx))
        XCTAssertThrowsError(try bar.dispatch(id: "missing", state: &s, tx: &tx))
    }

    func testTrayWindowManagerDirsPrefsAndQuitMachine() throws {
        final class EventLog: @unchecked Sendable {
            let lock = NSLock()
            var events: [TrayEvent] = []
            func append(_ e: TrayEvent) { lock.lock(); events.append(e); lock.unlock() }
        }
        let log = EventLog()
        let tray = SystemTray(spec: TraySpec(id: "com.rune.test", title: "Rune", menu: [.action(id: "quit", label: "Quit")])) {
            log.append($0)
        }
        tray.showHeadless()
        tray.setTooltip("Three tasks")
        tray.setMenu([.separator, .action(id: "quit", label: "Quit")])
        XCTAssertEqual(tray.spec.tooltip, "Three tasks")
        XCTAssertEqual(tray.spec.menu, [.separator, .action(id: "quit", label: "Quit")])
        tray.simulateEvent(.activate(token: nil))
        tray.simulateEvent(.menu("quit"))
        XCTAssertEqual(log.events, [.activate(token: nil), .menu("quit")])

        let wm = WindowManager()
        wm.open(WindowSpec(id: "main", title: "Main"))
        wm.open(WindowSpec(id: "prefs", title: "Prefs"))
        XCTAssertEqual(wm.focusedWindowId, "prefs")
        wm.focus(id: "main")
        XCTAssertEqual(wm.focusedWindowId, "main")
        wm.setTaskbar(TaskbarState(progress: .busy, badgeCount: 3, badgeDescription: "3 jobs"), for: "main")
        XCTAssertEqual(wm.state(for: "main")?.taskbar.badgeCount, 3)
        wm.close(id: "main")
        XCTAssertEqual(wm.openWindows().count, 1)

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("rune-wave2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let dirs = AppDirs.rooted(at: tmpDir, appId: "com.rune/app")
        XCTAssertEqual(dirs.id, "com.rune_app")
        XCTAssertTrue(dirs.config.path.hasSuffix("config/com.rune_app"))

        let prefsURL = tmpDir.appendingPathComponent("prefs.json")
        let prefs = Prefs.at(prefsURL)
        try prefs.set("fontSize", value: 15)
        try prefs.set("theme", value: "dark")
        let reloaded = Prefs.at(prefsURL)
        XCTAssertEqual(reloaded.get("fontSize", as: Int.self), 15)
        XCTAssertEqual(reloaded.get("theme", as: String.self), "dark")

        let (q1, e1) = QuitMachine.step(.running, event: .start(ending: false, after: .relaunch))
        XCTAssertEqual(e1, [.runHooks])
        let (q2, _) = QuitMachine.step(q1, event: .hooksRan)
        let (q3, e3) = QuitMachine.step(q2, event: .exited)
        XCTAssertEqual(q3, .done)
        XCTAssertEqual(e3, [.relaunch])

        let jl = JumpList()
            .task(JumpItem(title: "New Window", argument: "--new"))
            .category("Recent", items: [JumpItem(title: "Notes", argument: "rune://notes")])
        XCTAssertEqual(jl.tasks.count, 1)
        XCTAssertEqual(jl.categories.count, 1)
    }

    // MARK: - 4. Image Pipeline & LRU Cache

    func testImageDecodeMipChainAnimationAndLRUCache() async throws {
        let w = 4, h = 4
        var rgba = Data(count: w * h * 4)
        for i in 0..<(w * h) {
            rgba[i * 4 + 0] = 200
            rgba[i * 4 + 1] = 100
            rgba[i * 4 + 2] = 50
            rgba[i * 4 + 3] = 255
        }
        let png = try XCTUnwrap(ClipboardImage.encodeRGBAAsPNG(width: w, height: h, rgba: rgba))
        let pool = ImageDecodePool(capacityBytes: 512)
        let decoded = try await pool.decode(data: png, key: "tile-1")
        XCTAssertEqual(decoded.width, 4)
        XCTAssertEqual(decoded.height, 4)
        XCTAssertEqual(decoded.mips.count, 3) // 4x4, 2x2, 1x1
        XCTAssertEqual(decoded.mips.last?.width, 1)

        // Cache hit
        _ = try await pool.decode(data: png, key: "tile-1")
        XCTAssertEqual(pool.hitCount, 1)

        // Animation frame selection
        let f0 = AnimatedImageFrame(width: 2, height: 2, rgba: Data(count: 16), durationSeconds: 0.1)
        let f1 = AnimatedImageFrame(width: 2, height: 2, rgba: Data(repeating: 255, count: 16), durationSeconds: 0.2)
        let anim = DecodedImage(id: "anim", width: 2, height: 2, mips: [], frames: [f0, f1])
        XCTAssertTrue(anim.isAnimated)
        XCTAssertEqual(anim.frame(at: 0.05)?.rgba, f0.rgba)
        XCTAssertEqual(anim.frame(at: 0.15)?.rgba, f1.rgba)
        XCTAssertEqual(anim.frame(at: 0.35)?.rgba, f0.rgba)

        #if canImport(Metal)
        if let dev = MTLCreateSystemDefaultDevice() {
            let tex = ImageDecodePool.makeTexture(device: dev, image: decoded)
            XCTAssertNotNil(tex)
            XCTAssertEqual(tex?.mipmapLevelCount, 3)
        }
        #endif
    }

    // MARK: - 5. Video Pipeline

    func testSyntheticVideoPlayerPlaybackAndMetalUpload() {
        let player = VideoPlayer(source: .synthetic(pattern: .colorBars, width: 32, height: 24, fps: 30, durationSeconds: 2.0))
        XCTAssertEqual(player.state, .ready)
        XCTAssertEqual(player.naturalSize, Vec2(32, 24))
        player.setLooping(true)
        player.play()
        XCTAssertEqual(player.state, .playing)

        let f1 = player.advance(by: 0.5)
        XCTAssertEqual(f1?.width, 32)
        XCTAssertEqual(f1?.height, 24)
        XCTAssertEqual(f1?.rgba.count, 32 * 24 * 4)
        XCTAssertEqual(player.timecodeString, "00:00:00:15")

        // Loop wrap
        let _ = player.advance(by: 2.0)
        XCTAssertEqual(player.state, .playing)
        XCTAssertEqual(player.currentTime, 0.5, accuracy: 0.001)

        player.pause()
        XCTAssertEqual(player.state, .paused)

        #if canImport(Metal)
        if let dev = MTLCreateSystemDefaultDevice(), let frame = f1 {
            let tex = VideoPlayer.uploadToTexture(device: dev, frame: frame)
            XCTAssertNotNil(tex)
            XCTAssertEqual(tex?.width, 32)
        }
        #endif
    }

    // MARK: - 6. Metal Extended Shaders (Backdrop Composite, Outline, Springs Compute)

    func testMetalExtendedShadersAndSpringCompute() throws {
        #if canImport(Metal)
        guard let dev = MTLCreateSystemDefaultDevice() else {
            return
        }
        let renderer = try MetalRenderer(device: dev)
        XCTAssertTrue(renderer.hasCompiledExtendedShaders)

        let nodes = [
            MetalRenderer.GPUSpringNode(
                x: MetalRenderer.GPUSpringTrack(goal: 120, kind: 0),
                y: MetalRenderer.GPUSpringTrack(abcd: SIMD4<Float>(50, 0, 0, 0), rates: SIMD2<Float>(8, 12), goal: 200, kind: 1, start: .zero, duration: 5.0),
                opacity: MetalRenderer.GPUSpringTrack(goal: 0.75, kind: 0)
            ),
        ]
        let out = renderer.evaluateSpringsOnGPU(nodes, timeSeconds: 0.25)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].x, 120, accuracy: 0.01)
        XCTAssertEqual(out[0].z, 0.75, accuracy: 0.01)
        XCTAssertGreaterThan(out[0].y, 190)
        XCTAssertLessThan(out[0].y, 210)
        #endif
    }

    // MARK: - 7. Recorder, Rewind, HotWatcher, ColdBox & Playground

    func testAudioRecorderFlightRecorderAndRewindScrubber() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("rune-rec-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let wavURL = tmpDir.appendingPathComponent("take1.wav")

        let rec = AudioRecorder(fakeMicrophone: FakeMicrophone(sampleRate: 16_000, frequencyHz: 440, amplitude: 0.5))
        rec.start(outputURL: wavURL, format: .wav)
        rec.advanceHeadless(deltaSeconds: 0.25)
        XCTAssertGreaterThan(rec.level.rms, 0.1)
        let result = try rec.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
        XCTAssertGreaterThan(result.sizeBytes, 44)

        let flight = FlightRecorder()
        flight.record(kind: "pointerDown", at: 0.1, payload: ["button": "primary"])
        flight.record(kind: "keyDown", at: 0.2, payload: ["key": "enter"])
        let jsonData = try flight.exportJSON()
        let imported = try FlightRecorder.importJSON(jsonData)
        XCTAssertEqual(imported.events.count, 2)

        let rewind = RewindRecorder(windowSeconds: 10.0)
        rewind.recordFrame(at: 0.0, elements: [
            RewindElementSnapshot(key: "card", rect: MotionRect(left: 0, top: 0, right: 100, bottom: 50), opacity: 1.0),
        ])
        rewind.recordFrame(at: 0.5, elements: [
            RewindElementSnapshot(key: "card", rect: MotionRect(left: 20, top: 0, right: 120, bottom: 50), opacity: 0.5),
        ])
        let scrubber = RewindScrubber()
        scrubber.open(rewind)
        XCTAssertTrue(scrubber.isOpen)
        XCTAssertEqual(scrubber.currentFrameIndex, 1)
        scrubber.stepBackward()
        XCTAssertEqual(scrubber.currentFrameIndex, 0)
        let clip = try XCTUnwrap(scrubber.clip)
        XCTAssertEqual(clip.changes(atFrame: 1).count, 1)
        XCTAssertEqual(clip.track(forKey: "card").count, 2)
        let clipRoundtrip = try RewindClip.importJSON(try clip.exportJSON())
        XCTAssertEqual(clipRoundtrip, clip)
        scrubber.close(resuming: rewind)
        XCTAssertFalse(rewind.isPaused)
    }

    func testHotWatcherColdBoxAndPlaygroundHost() throws {
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("rune-hot-\(UUID().uuidString).txt")
        try Data("v1".utf8).write(to: tmpFile)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let exp = expectation(description: "HotWatcher file change")
        exp.assertForOverFulfill = false
        let watcher = HotWatcher()
        XCTAssertTrue(watcher.watch(path: tmpFile) { _ in
            exp.fulfill()
        })
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            try? Data("v2".utf8).write(to: tmpFile)
        }
        wait(for: [exp], timeout: 2.0)
        watcher.stop()

        var box = ColdBox<[Int]> { [] }
        XCTAssertTrue(box.isEmpty)
        let boxCopy = box
        box.mutate { $0.append(42) }
        XCTAssertFalse(box.isEmpty)
        XCTAssertEqual(box.value, [42])
        XCTAssertEqual(boxCopy.value, [])

        struct DemoState { var label: String }
        let pg = PlaygroundHost<DemoState>()
            .knob(.toggle(id: "dense", label: "Dense", defaultValue: true))
            .viewportPresets([.compact, .wide])
            .story(PlaygroundStory(path: "Cards/Summary") { state, controls, _ in
                let h: Float = controls.bool("dense") ? 40 : 80
                return el().w(200).h(h).child(text(state.label))
            })
        pg.open()
        XCTAssertTrue(pg.isOpen)
        XCTAssertEqual(pg.filteredStories().first?.slug, "cards-summary")
        let matrix = pg.evaluateSceneMatrix { DemoState(label: "OK") }
        XCTAssertEqual(matrix.count, 2)
        XCTAssertEqual(matrix[0].presetName, "Compact")
        XCTAssertEqual(matrix[1].presetName, "Wide")

        let overlay = OverlayHandle(spec: OverlaySpec(
            name: "hud",
            size: Vec2(220, 44),
            makeState: { "Recording" },
            view: { s, _ in text(s) }
        ))
        XCTAssertFalse(overlay.isVisible)
        overlay.show()
        XCTAssertTrue(overlay.isVisible)
        overlay.update { $0 = "Paused" }
        XCTAssertEqual(overlay.readState { $0 }, "Paused")
        overlay.hide()
        XCTAssertFalse(overlay.isVisible)

        let rt = Runtime(state: DemoState(label: "Web"), viewport: Vec2(320, 200)) { s, _ in
            el().w(100).h(40).bg(.srgb(0.2, 0.4, 0.8)).child(text(s.label))
        }
        let scene = rt.frame(at: 0)
        let html = try WebSceneExporter.exportHTML(title: "Rune Web", scene: scene)
        XCTAssertTrue(html.contains("RUNE_SCENE"))
        XCTAssertTrue(html.contains("<canvas id=\"rune\""))
    }
}
